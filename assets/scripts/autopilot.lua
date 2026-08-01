-- ---------------------------------------------------------------------------
-- autopilot.lua — игрок-автомат: проходит игру от высадки до отплытия сам.
--
-- Запускается флагом --autopilot=1 (см. LaunchArg движка) и нужен ровно для
-- одного: проверять игру НА САМОЙ ИГРЕ, без человека за мышью. В CI нет ни
-- мыши, ни клавиатуры, поэтому единственный способ узнать, что мир строится,
-- кирка ломает, крафт считает, а лодка достраивается — прожить всё это.
--
-- Ключевое: автопилот НЕ трогает мир напрямую и не телепортируется. Он
-- заполняет ту же таблицу намерений, что человек заполняет мышью и WASD, и
-- отдаёт её player.lua. Всё, что он проходит, пройдёт и человек — иначе
-- проверялся бы двойник игры, а не игра.
--
-- Каждый шаг под сторожевым таймером: зависший автопилот должен ронять прогон
-- с внятной строкой в логе, а не молча крутиться до таймаута CI.
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"

local A = {}

local V, P, Inv, Boat, log

local state = "wood"
local stateTime = 0.0
local target = nil          -- {x,y,z} блок, который сейчас добываем
local blacklist = {}        -- "x,y,z" -> сколько ещё игнорировать
local stuckTimer = 0.0
local lastPos = {x = 0, z = 0}
local buildQueue = nil
local aimYaw, aimPitch = 0.0, 0.0
local done = false

A.NEED_LOGS = 2      -- 2 бревна -> 8 досок: ровно корпус лодки
A.NEED_LEAVES = 8    -- 8 листьев -> 2 паруса

local STATE_LIMIT = {
    wood = 90.0, leaves = 90.0, craft = 5.0, build = 120.0, sail = 20.0,
}

local function keyOf(b) return b.x .. "," .. b.y .. "," .. b.z end

local function setState(next)
    log(string.format("THEBOAT: autopilot -> %s (после %.1f c)", next, stateTime))
    state = next
    stateTime = 0.0
    target = nil
    buildQueue = nil
end

function A.Init(deps)
    V, P, Inv, Boat = deps.voxel, deps.player, deps.inventory, deps.boat
    log = deps.log
    lastPos.x, lastPos.z = P.pos.x, P.pos.z
    log("THEBOAT: autopilot enabled")
end

-- Пустая таблица намерений: дальше шаги её заполняют.
local function blankInput()
    return {
        moveF = 0.0, moveR = 0.0, jump = false, sprint = false, crouch = false,
        lookX = 0.0, lookY = 0.0,
        breakHeld = false, placePressed = false, usePressed = false, hotbar = nil,
    }
end

-- Идти к точке в плоскости XZ. Возвращает оставшееся расстояние.
local function walkTo(input, tx, tz, dt)
    local dx, dz = tx - P.pos.x, tz - P.pos.z
    local dist = math.sqrt(dx * dx + dz * dz)
    if dist < 0.05 then return dist end
    local yaw = math.deg(math.atan(-dx, -dz))
    P.SetLook(yaw, 0.0)
    input.moveF = 1.0

    -- Застряли (упёрлись в дерево/обрыв) — подпрыгнуть и качнуться в сторону.
    -- Автопрыжок в player.lua берёт ступеньку в блок, всё остальное — сюда.
    local moved = math.abs(P.pos.x - lastPos.x) + math.abs(P.pos.z - lastPos.z)
    if moved < 0.02 then
        stuckTimer = stuckTimer + dt
        if stuckTimer > 0.35 then
            input.jump = true
            input.moveR = (math.floor(stateTime * 2.0) % 2 == 0) and 1.0 or -1.0
        end
    else
        stuckTimer = 0.0
    end
    lastPos.x, lastPos.z = P.pos.x, P.pos.z
    return dist
end

-- На какое расстояние подходить, чтобы блок оказался в досягаемости кирки.
local function approachDistance(b)
    local ey = P.pos.y + P.EYE_HEIGHT
    local dy = (b.y + 0.5) - ey
    local room = (P.REACH - 0.7) ^ 2 - dy * dy
    if room <= 1.0 then return 1.1 end
    return math.max(1.1, math.min(2.4, math.sqrt(room)))
end

-- Навестись на блок и проверить лучом, что под прицелом НУЖНАЯ ПОРОДА.
--
-- Именно порода, а не конкретная ячейка. Крона дерева — два десятка одинаковых
-- листьев вплотную: луч, пущенный в выбранный лист, регулярно упирается в
-- соседний, и требование «попасть ровно в этот блок» превращало добычу в
-- бесконечное «отойти-подойти-промахнуться». Нам нужен лист, а не конкретный
-- лист — что попалось под прицел, то и рубим.
local function aimAt(b, blockId)
    aimYaw, aimPitch = P.LookAnglesTo(b.x + 0.5, b.y + 0.5, b.z + 0.5)
    P.SetLook(aimYaw, aimPitch)
    local t = P.target
    if t == nil then return false end
    return V.Get(t.x, t.y, t.z) == blockId
end

-- --- Добыча -----------------------------------------------------------------
local function gather(input, dt, blockId, needCount)
    if Inv.Count(blockId) >= needCount then return true end

    if target and V.Get(target.x, target.y, target.z) ~= blockId then target = nil end
    if not target then
        -- Блоки, до которых уже не дотянулись, отсеиваем прямо в поиске —
        -- иначе автопилот вечно выбирал бы один и тот же недостижимый лист.
        local found = V.FindNearest(blockId, math.floor(P.pos.x), math.floor(P.pos.y + 1),
                                    math.floor(P.pos.z), 14, 8,
                                    function(x, y, z)
                                        return blacklist[x .. "," .. y .. "," .. z] ~= nil
                                    end)
        if not found then
            log("THEBOAT: autopilot не нашёл " .. Blocks.Name(blockId) .. " поблизости")
            return false
        end
        target = found
        target.tries = 0.0
    end

    local dx, dz = (target.x + 0.5) - P.pos.x, (target.z + 0.5) - P.pos.z
    local flat = math.sqrt(dx * dx + dz * dz)
    if flat > approachDistance(target) then
        walkTo(input, target.x + 0.5, target.z + 0.5, dt)
        return false
    end

    if aimAt(target, blockId) then
        input.breakHeld = true
        target.tries = 0.0
    else
        -- Не видим цель (закрыта соседним блоком) — чуть отойти и попробовать
        -- снова; после секунды безуспешных попыток забыть про этот блок.
        target.tries = (target.tries or 0.0) + dt
        input.moveF = -0.6
        if target.tries > 1.0 then
            blacklist[keyOf(target)] = 8.0
            target = nil
        end
    end
    return false
end

-- --- Постройка лодки --------------------------------------------------------
--
-- Ставим от дальнего края к ближнему: луч к ближней клетке не должен проходить
-- сквозь уже поставленную доску.
local function buildPlan()
    local d = V.Dock()
    local plan = {}
    for z = d.z1, d.z0, -1 do
        for x = d.x0, d.x1 do
            plan[#plan + 1] = {x = x, y = d.y, z = z, id = Blocks.PLANK}
        end
    end
    -- Мачты — на ДАЛЬНЕМ ряду: поставленные на ближнем, они замуровали бы
    -- вход на собственную лодку (парус — такой же твёрдый блок, как доска).
    plan[#plan + 1] = {x = d.x0 + 1, y = d.y + 1, z = d.z1, id = Blocks.SAIL}
    plan[#plan + 1] = {x = d.x0 + 2, y = d.y + 1, z = d.z1, id = Blocks.SAIL}
    -- Место, с которого достаёт до всех клеток причала и откуда ничего не
    -- загораживает обзор.
    plan.stand = {x = (d.x0 + d.x1) * 0.5 + 0.5, z = d.z0 - 2.5}
    return plan
end

local function build(input, dt)
    if not buildQueue then buildQueue = buildPlan() end

    -- Дошли ли до места сборки.
    local st = buildQueue.stand
    local dx, dz = st.x - P.pos.x, st.z - P.pos.z
    if math.sqrt(dx * dx + dz * dz) > 0.45 then
        walkTo(input, st.x, st.z, dt)
        return false
    end

    -- Первая клетка плана, которая ещё не заполнена.
    local cell = nil
    for _, c in ipairs(buildQueue) do
        if V.Get(c.x, c.y, c.z) ~= c.id then cell = c; break end
    end
    if cell == nil then return true end

    if Inv.Count(cell.id) <= 0 then
        log("THEBOAT: autopilot: кончился " .. Blocks.Name(cell.id))
        return false
    end
    -- Выбрать нужный слот хотбара — как игрок клавишей.
    for i, id in ipairs(Inv.hotbar) do
        if id == cell.id then input.hotbar = i end
    end

    -- Целимся в ОПОРУ под клеткой: блок ставится в пустую ячейку перед той,
    -- в которую упёрся луч.
    local support = {x = cell.x, y = cell.y - 1, z = cell.z}
    aimYaw, aimPitch = P.LookAnglesTo(cell.x + 0.5, cell.y + 0.0, cell.z + 0.5)
    P.SetLook(aimYaw, aimPitch)
    local t = P.target
    if t and t.x == support.x and t.y == support.y and t.z == support.z
       and t.px == cell.x and t.py == cell.y and t.pz == cell.z then
        input.placePressed = true
    end
    return false
end

-- --- Кадр автопилота --------------------------------------------------------
function A.Update(dt)
    local input = blankInput()
    if done then return input end

    stateTime = stateTime + dt
    for k, v in pairs(blacklist) do
        local left = v - dt
        if left <= 0.0 then blacklist[k] = nil else blacklist[k] = left end
    end

    local limit = STATE_LIMIT[state]
    if limit and stateTime > limit then
        log(string.format("THEBOAT: FAIL autopilot застрял в состоянии '%s' (%.0f c)", state, stateTime))
        done = true
        return input
    end

    if state == "wood" then
        if gather(input, dt, Blocks.LOG, A.NEED_LOGS) then
            log("THEBOAT: собрано брёвен: " .. Inv.Count(Blocks.LOG))
            setState("leaves")
        end

    elseif state == "leaves" then
        if gather(input, dt, Blocks.LEAVES, A.NEED_LEAVES) then
            log("THEBOAT: собрано листьев: " .. Inv.Count(Blocks.LEAVES))
            setState("craft")
        end

    elseif state == "craft" then
        local planks = Inv.FindRecipe("planks")
        while Inv.Count(Blocks.PLANK) < Boat.needPlanks and Inv.CanCraft(planks) do
            Inv.Craft(planks)
        end
        local sail = Inv.FindRecipe("sail")
        while Inv.Count(Blocks.SAIL) < Boat.needSails and Inv.CanCraft(sail) do
            Inv.Craft(sail)
        end
        log(string.format("THEBOAT: скрафчено досок %d, парусов %d",
                          Inv.Count(Blocks.PLANK), Inv.Count(Blocks.SAIL)))
        if Inv.Count(Blocks.PLANK) < Boat.needPlanks or Inv.Count(Blocks.SAIL) < Boat.needSails then
            log("THEBOAT: FAIL не хватило материалов на лодку")
            done = true
        else
            setState("build")
        end

    elseif state == "build" then
        if build(input, dt) then
            log(string.format("THEBOAT: лодка собрана: %d досок, %d парусов", Boat.planks, Boat.sails))
            setState("sail")
        end

    elseif state == "sail" then
        -- Готовность лодки пересчитывается раз в четверть секунды — сразу после
        -- последней доски она ещё «не готова». Просим пересчёт явно, а сдаёмся
        -- только по сторожевому таймеру, а не по первому же кадру.
        if not Boat.ready then Boat.Recount() end
        if not Boat.ready then
            if stateTime > 2.0 then
                log("THEBOAT: FAIL лодка не считается готовой: " ..
                    Boat.planks .. "/" .. Boat.needPlanks .. " досок, " ..
                    Boat.sails .. "/" .. Boat.needSails .. " парусов")
                done = true
            end
        elseif Boat.escaped then
            done = true
        elseif Boat.InDock(P.pos.x, P.pos.y, P.pos.z) then
            -- Условие отплытия — то же, что для человека: стоять на причале и
            -- нажать «использовать». Никаких поблажек автопилоту.
            input.usePressed = true
        else
            local c = Boat.center
            walkTo(input, c.x, c.z, dt)
        end
    end

    return input
end

function A.Done() return done end
function A.State() return state end

return A
