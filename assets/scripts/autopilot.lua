-- ---------------------------------------------------------------------------
-- autopilot.lua — игрок-автомат: живёт на лодке сам.
--
-- В игре про уют нет победы, поэтому автопилоту нечего «пройти». Его задача
-- другая: за один прогон ТРОНУТЬ каждую систему — подобрать мусор багром,
-- скрафтить из него доску, достроить палубу, разобрать блок обратно, поесть,
-- поставить фонарь, — и оставить в логе следы, по которым CI поймёт, что всё
-- это действительно случилось, а не просто не упало.
--
-- Как и раньше, автопилот не трогает мир напрямую: он заполняет ту же таблицу
-- намерений, что человек заполняет мышью и клавишами. Что проходит он, пройдёт
-- и человек.
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"
local Ocean = require "ocean"

local A = {}

local Ship, P, Inv, Debris, S, log

local state = "gather"
local stateTime = 0.0
local totalTime = 0.0
local done = false
local flashlightWasOn = false   -- состояние фонарика ДО нажатия L (см. состояние "flashlight")
local target = nil
local built, dismantled = 0, 0
local checklist = {gather = false, craft = false, build = false,
                   dismantle = false, eat = false, lantern = false,
                   flashlight = false}

A.NEED_SCRAP = 8
A.NEED_BUILD = 4
A.NEED_PLASTIC = 2

local STATE_LIMIT = {
    gather = 180.0, craft = 8.0, build = 90.0, dismantle = 45.0,
    lantern = 60.0, idle = 1e9,
}

local function setState(next)
    log(string.format("THEBOAT: autopilot -> %s (после %.1f c)", next, stateTime))
    state = next
    stateTime = 0.0
    target = nil
end

function A.Init(deps)
    Ship, P, Inv, Debris, S = deps.ship, deps.player, deps.inventory, deps.debris, deps.survival
    log = deps.log
    log("THEBOAT: autopilot enabled")
end

local function blankInput()
    return {
        moveF = 0.0, moveR = 0.0, jump = false, sprint = false, crouch = false,
        lookX = 0.0, lookY = 0.0,
        breakHeld = false, placePressed = false, usePressed = false,
        eatPressed = false, drinkPressed = false, fishPressed = false,
        craft = nil,
    }
end

-- Идти к точке в КОРАБЕЛЬНЫХ координатах (палуба — единственное, где автопилот
-- ходит; за борт он не лезет специально).
--
-- Палуба — не пустая площадка: посреди неё стоит мачта, по бортам леера, на
-- корме каюта. Прямая линия к цели регулярно упирается в одно из этого, поэтому
-- у ходьбы есть простейший объезд: не сдвинулись за треть секунды — шагаем
-- боком, чередуя сторону. Полноценный поиск пути на площадке в тридцать клеток
-- был бы из пушки по воробьям.
local lastPos = {x = 0.0, z = 0.0}
local stuckTimer = 0.0
local stuckSide = 1.0

local frameDt = 1.0 / 60.0

local function walkTo(input, tx, tz)
    local dx, dz = tx - P.pos.x, tz - P.pos.z
    local dist = math.sqrt(dx * dx + dz * dz)
    if dist < 0.25 then
        stuckTimer = 0.0
        return dist
    end

    -- Идём ПО ОДНОЙ ОСИ ЗА РАЗ: сначала выравниваемся по X, потом по Z. По
    -- прямой к цели путь регулярно проходит впритирку к мачте, и игрок шириной
    -- в 0.6 блока задевает её углом; по осям же он встаёт ровно в середину
    -- своего ряда клеток и проходит мимо. Настоящий поиск пути на площадке в
    -- три десятка клеток был бы из пушки по воробьям.
    local gx, gz
    if math.abs(dx) > 0.3 then gx, gz = dx, 0.0 else gx, gz = 0.0, dz end
    P.SetLook(math.deg(math.atan(-gx, -gz)), 0.0)
    input.moveF = 1.0

    -- Всё-таки упёрлись (ящик, бочка, надстройка) — шагаем боком, меняя сторону
    -- не чаще раза в пару секунд: частая смена оставляет бота топтаться на месте.
    local moved = math.abs(P.pos.x - lastPos.x) + math.abs(P.pos.z - lastPos.z)
    lastPos.x, lastPos.z = P.pos.x, P.pos.z
    if moved < 0.004 then
        stuckTimer = stuckTimer + frameDt
        if stuckTimer > 0.4 then
            input.moveR = stuckSide
            input.jump = true
            if stuckTimer > 2.4 then
                stuckSide = -stuckSide
                stuckTimer = 0.4
            end
        end
    else
        stuckTimer = 0.0
    end
    return dist
end

-- --- Сбор мусора багром -----------------------------------------------------
--
-- Целиться нужно в МИРОВЫХ координатах: мусор плавает в океане, а игрок стоит
-- на качающейся палубе, и общая у них только мировая система.
--
-- ВАЖНО про порядок: направление взгляда — оно же направление ходьбы. Если
-- сперва позвать walkTo (он ставит moveF = 1 и смотрит на точку палубы), а
-- потом навести взгляд на мусор, игрок пойдёт НА МУСОР — то есть за борт. Так
-- что сначала доходим, и только на месте поднимаем багор.
local function gather(input, dt)
    -- Ловим не «сколько-нибудь», а ровно то, что нужно дальше по плану: доски
    -- на пристройку и пластик на фонарь. Иначе прогон доходил бы до фонаря с
    -- пустыми руками и молча его пропускал — то есть не проверял бы свет.
    if Inv.Count(Blocks.SCRAP) >= A.NEED_SCRAP
       and Inv.Count(Blocks.PLASTIC) >= A.NEED_PLASTIC then return true end

    -- Ближайший к лодке обломок: ищем каждый кадр, он движется.
    local ex, ey, ez = P.WorldEye()
    local best, bestD = nil, 1e9
    for _, it in ipairs(Debris.Items()) do
        if it.obj:Valid() then
            local p = it.obj.Transform.Position
            local dx, dy, dz = p.x - ex, p.y - ey, p.z - ez
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if d < bestD then best, bestD = it, d end
        end
    end
    if best == nil then return false end

    -- Встать у того борта, к которому он ближе, и смотреть на него.
    local p = best.obj.Transform.Position
    local lx = p.x - Ship.pos.x
    local lz = p.z - Ship.pos.z
    -- Держимся в границах палубы: за борт автопилот не лезет специально.
    local standX = math.max(-1.5, math.min(1.5, lx))
    local standZ = math.max(-2.0, math.min(5.2, lz))
    if walkTo(input, standX, standZ) >= 0.45 then return false end

    -- Дошли: останавливаемся, наводимся, багрим.
    input.moveF, input.moveR = 0.0, 0.0
    P.SetLook(P.LookAnglesTo(p.x, p.y, p.z))
    if bestD < Debris.REACH * 0.92 and P.aimDebris ~= nil then
        input.usePressed = true
    end
    return false
end

-- --- Стройка ----------------------------------------------------------------
--
-- Достраиваем палубу вперёд по носу: там свободно, и результат виден с любого
-- места. Целимся в верхнюю грань соседней доски — блок встаёт в пустую ячейку
-- перед той, в которую упёрся луч.
local function nextBuildCell()
    for z = 8, 11 do
        for x = -1, 1 do
            if Ship.Get(x, 0, z) == Blocks.AIR and Ship.Get(x, 0, z - 1) ~= Blocks.AIR then
                return {x = x, y = 0, z = z}
            end
        end
    end
    return nil
end

local function build(input, dt)
    if built >= A.NEED_BUILD then return true end
    if Inv.Count(Blocks.PLANK) <= 0 then return true end -- доски кончились: не тупик

    local cell = nextBuildCell()
    if cell == nil then return true end

    -- Взять доску в руку. Ячейки инвентаря больше не закреплены за видами
    -- блоков — доска лежит там, куда её положил Add, — поэтому спрашиваем
    -- инвентарь, а не перебираем список видов.
    Inv.SelectItem(Blocks.PLANK)

    -- Крадучись у самого борта: полным шагом бот проскакивает край носа по
    -- инерции и оказывается в воде — вместо стройки начинается заплыв.
    input.crouch = true

    -- Встаём у самого края палубы и целимся В ВОДУ на месте будущей доски —
    -- тем же жестом, каким её настилает человек (см. placementCell в player.lua).
    -- Идём в ЦЕНТР клетки (cell.x + 0.5), а не в её индекс: игрок шириной в
    -- 0.6 блока, поставленный на границу клеток, задевает соседнюю — и упирается
    -- в леер вместо того, чтобы дойти до края.
    if walkTo(input, cell.x + 0.5, cell.z - 1.1) > 0.4 then return false end

    -- На месте — стоим и кладём доску. Шаг вперёд одновременно со взглядом в
    -- воду означал бы шаг в воду.
    input.moveF, input.moveR = 0.0, 0.0
    local tx, ty, tz = Ship.LocalToWorld(cell.x + 0.5, 1.0, cell.z + 0.5)
    P.SetLook(P.LookAnglesTo(tx, ty, tz))
    input.placePressed = true
    return false
end

-- --- Разбор собственной палубы ---------------------------------------------
--
-- Ломать начинаем, как только нужный блок оказался ПОД ПРИЦЕЛОМ, а не когда
-- дошли до заданной точки. Расстояние и так ограничено длиной луча, а порог по
-- дистанции давал ровно то, что и должен был: игрок топтался вокруг него, кирка
-- то включалась, то выключалась, и прогресс разрушения обнулялся каждый кадр.
local function dismantle(input, dt)
    if dismantled >= 1 then return true end
    -- Берём леер на борту: разбирать пол под собой — плохая идея и для
    -- автопилота, и для человека.
    local cell = nil
    for z = 0, 4 do
        if Ship.Get(3, 1, z) == Blocks.RAIL then cell = {x = 3, y = 1, z = z} break end
    end
    if cell == nil then return true end

    local wx, wy, wz = Ship.LocalToWorld(cell.x + 0.5, cell.y + 0.5, cell.z + 0.5)
    local t = P.target
    if t and t.x == cell.x and t.y == cell.y and t.z == cell.z then
        input.moveF, input.moveR = 0.0, 0.0
        P.SetLook(P.LookAnglesTo(wx, wy, wz))
        input.breakHeld = true
        return false
    end

    -- Не видим цель — подходим и смотрим на неё (стоя, а не на ходу).
    if walkTo(input, cell.x - 1.5, cell.z + 0.5) < 1.2 then
        input.moveF, input.moveR = 0.0, 0.0
        P.SetLook(P.LookAnglesTo(wx, wy, wz))
    end
    return false
end

-- --- Фонарь -----------------------------------------------------------------
local function placeLantern(input, dt)
    if Inv.Count(Blocks.LANTERN) <= 0 then
        if Inv.CanCraft(Inv.FindRecipe("lantern")) then
            input.craft = 4
            return false
        end
        return true -- нет материалов: не повод считать прогон сломанным
    end
    Inv.SelectItem(Blocks.LANTERN)

    local cell = nil
    for z = -1, 3 do
        if Ship.Get(-2, 1, z) == Blocks.AIR and Ship.Get(-2, 0, z) ~= Blocks.AIR then
            cell = {x = -2, y = 1, z = z}
            break
        end
    end
    if cell == nil then return true end

    if walkTo(input, cell.x + 1.6, cell.z + 0.5) > 0.7 then return false end
    input.moveF, input.moveR = 0.0, 0.0
    local sx, sy, sz = Ship.LocalToWorld(cell.x + 0.5, cell.y, cell.z + 0.5)
    P.SetLook(P.LookAnglesTo(sx, sy, sz))
    local t = P.target
    if t and t.px == cell.x and t.py == cell.y and t.pz == cell.z then
        input.placePressed = true
    end
    return false
end

-- --- Кадр -------------------------------------------------------------------
function A.Update(dt)
    local input = blankInput()
    if done then
        -- Прогон закончен: автопилот просто стоит на палубе и смотрит на воду.
        -- Это буквально то, ради чего игра сделана, и заодно даёт CI кадры,
        -- на которых видно живой мир, а не суетящегося бота.
        P.SetLook(200.0, -4.0)
        return input
    end

    frameDt = dt
    stateTime = stateTime + dt
    totalTime = totalTime + dt

    -- Оказались за бортом — плывём к лодке и лезем обратно. Отдельным
    -- состоянием это не делаем: упасть в воду можно из любого занятия, и
    -- возвращение на палубу — не этап плана, а то, что прерывает любой этап.
    if P.overboard then
        -- Плывём не к середине лодки, а к НОСУ: над серединой стоят каюта и
        -- мачта, и подтянувшись там, вылезешь на крышу вместо палубы.
        local bx, by, bz = Ship.LocalToWorld(0.0, 1.0, 5.0)
        local dx, dz = bx - P.pos.x, bz - P.pos.z
        P.SetLook(math.deg(math.atan(-dx, -dz)), 0.0)
        input.moveF = 1.0
        input.jump = true
        stateTime = stateTime - dt -- время в воде состоянию не засчитываем
        return input
    end

    local limit = STATE_LIMIT[state]
    if limit and stateTime > limit then
        -- Печатаем не только «застрял», но и ЧЕМ он был занят: без позиции,
        -- прицела и содержимого рук строка в логе CI не отличает «не дошёл» от
        -- «дошёл, но не за что зацепиться».
        local t = P.target
        log(string.format("THEBOAT: FAIL autopilot застрял в '%s' (%.0f c) pos=(%.2f,%.2f,%.2f) " ..
                          "заборт=%s прицел=%s доска=%d фонарь=%d",
            state, stateTime, P.pos.x, P.pos.y, P.pos.z, tostring(P.overboard),
            t and (t.x .. "," .. t.y .. "," .. t.z) or "нет",
            Inv.Count(Blocks.PLANK), Inv.Count(Blocks.LANTERN)))
        done = true
        return input
    end

    -- Есть и пить автопилот успевает между делом, как и человек.
    if S.food < 55.0 and (Inv.Count(Blocks.FISH) > 0 or Inv.Count(Blocks.SEAWEED) > 0) then
        input.eatPressed = true
        checklist.eat = true
    end

    if state == "gather" then
        if gather(input, dt) then
            checklist.gather = true
            log("THEBOAT: собрано обломков: " .. Inv.Count(Blocks.SCRAP) ..
                ", всего выловлено предметов: " .. Debris.Collected())
            setState("craft")
        end

    elseif state == "craft" then
        local plank = Inv.FindRecipe("plank")
        while Inv.Count(Blocks.PLANK) < A.NEED_BUILD and Inv.CanCraft(plank) do
            Inv.Craft(plank)
        end
        checklist.craft = Inv.Count(Blocks.PLANK) > 0
        log("THEBOAT: скрафчено досок: " .. Inv.Count(Blocks.PLANK))
        if not checklist.craft then
            log("THEBOAT: FAIL из обломков не вышло ни одной доски")
            done = true
        else
            setState("build")
        end

    elseif state == "build" then
        if build(input, dt) then
            checklist.build = built > 0
            log("THEBOAT: достроено блоков палубы: " .. built ..
                ", палуба теперь " .. Ship.BlockCount() .. " блоков")
            setState("dismantle")
        end

    elseif state == "dismantle" then
        if dismantle(input, dt) then
            checklist.dismantle = dismantled > 0
            log("THEBOAT: разобрано блоков корабля: " .. dismantled)
            setState("lantern")
        end

    elseif state == "lantern" then
        if placeLantern(input, dt) then
            checklist.lantern = Ship.CountBlocks(Blocks.LANTERN) >= 2
            -- Фонарик — тем же способом, что и человек: намерением, а не
            -- прямым вызовом. Иначе прогон проверял бы функцию, а не клавишу.
            input.flashlightPressed = true
            flashlightWasOn = P.flashlightOn
            setState("flashlight")
        end

    -- Отдельный шаг, а не хвост предыдущего: намерение «нажал L» разбирает
    -- игра, и разбирает ПОСЛЕ автопилота — значит и результат виден только на
    -- следующем кадре. Раньше здесь стоял ещё и прямой вызов
    -- P.ToggleFlashlight(), и он всё ломал дважды: фонарик переключался два
    -- раза (то есть возвращался в исходное состояние), а проверка `~= nil`
    -- была верна всегда — функция не возвращает nil никогда, — то есть не
    -- проверяла ничего.
    elseif state == "flashlight" then
        checklist.flashlight = (P.flashlightOn ~= flashlightWasOn)
        log("THEBOAT: фонарик переключён, включён=" .. tostring(P.flashlightOn))
        log("THEBOAT: фонарей на палубе: " .. Ship.CountBlocks(Blocks.LANTERN))
        -- Итог прогона: что из систем реально сработало.
        local ok = checklist.gather and checklist.craft and checklist.build
                   and checklist.dismantle and checklist.lantern
                   and checklist.flashlight
        log(string.format("THEBOAT: LIVING ABOARD — выловлено %d, палуба %d блоков, путь %.0f м",
            Debris.Collected(), Ship.BlockCount(), Ship.drift))
        if ok then log("THEBOAT: ROUTINE OK") else log("THEBOAT: FAIL не все действия удались") end
        setState("idle")
        done = true
    end

    return input
end

-- Счётчики ведёт игра через эти хуки — автопилот не подглядывает в мир напрямую.
function A.NotePlaced() built = built + 1 end
function A.NoteBroken() dismantled = dismantled + 1 end

function A.Done() return done end
function A.State() return state end

return A
