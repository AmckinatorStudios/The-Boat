-- ---------------------------------------------------------------------------
-- player.lua — игрок от первого лица на палубе.
--
-- Ключевое отличие от «игрока на земле»: позиция хранится в КОРАБЕЛЬНЫХ
-- координатах. Палуба качается на волне, и если бы игрок жил в мировых, каждая
-- волна отрывала бы его от пола — доски уехали вверх, а он остался. В
-- корабельных же он просто стоит, а в мир его переводит та же матрица, что и
-- саму палубу (см. Ship.LocalToWorld).
--
-- За бортом координаты становятся мировыми: там нет палубы, есть вода, и
-- плавание считается относительно волны. Переход туда-обратно — единственное
-- место, где две системы координат встречаются.
--
-- Про камеру: рыскание живёт на теле, тангаж — на дочерней камере. Движок
-- собирает поворот как Rx*Ry*Rz, то есть тангаж в МИРОВЫХ осях, и одной
-- сущностью горизонт кренило бы при повороте. Иерархия даёт правильный
-- порядок (Ry * Rx) даром.
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"
local Ocean = require "ocean"
local Ship = require "ship"
local Hand = require "hand"

local P = {}

local HALF_W   = 0.3
local HEIGHT   = 1.75
local EYE      = 1.6
local GRAVITY  = -22.0
local JUMP_V   = 7.4
local WALK     = 3.6      -- спокойный шаг: игра про то, чтобы никуда не спешить
local SPRINT   = 5.4
local SWIM     = 2.6
local SWIM_UP  = 2.8
local ACCEL_G  = 13.0
local ACCEL_A  = 3.0
local REACH    = 5.0
local MAX_PITCH = 89.0

local Inv, hooks
local body, cam

P.pos = {x = 0.0, y = 1.0, z = -1.0}   -- корабельные координаты (или мировые в воде)
P.vel = {x = 0.0, y = 0.0, z = 0.0}
P.yaw, P.pitch = 0.0, 0.0
P.onGround = false
P.overboard = false      -- за бортом: координаты мировые, вокруг вода
P.target = nil           -- блок палубы под прицелом
P.aimDebris = nil        -- обломок под прицелом (важнее блока)
P.breakProgress = 0.0
P.breakTarget = nil
P.bob = 0.0

local function rad(d) return d * math.pi / 180.0 end

function P.Forward()
    local cp = math.cos(rad(P.pitch))
    return -cp * math.sin(rad(P.yaw)), math.sin(rad(P.pitch)), -cp * math.cos(rad(P.yaw))
end

function P.ForwardFlat() return -math.sin(rad(P.yaw)), 0.0, -math.cos(rad(P.yaw)) end
function P.RightFlat() return math.cos(rad(P.yaw)), 0.0, -math.sin(rad(P.yaw)) end

-- Глаз в МИРОВЫХ координатах — им целятся в мусор и его слушает звук.
function P.WorldEye()
    if P.overboard then
        return P.pos.x, P.pos.y + EYE, P.pos.z
    end
    return Ship.LocalToWorld(P.pos.x, P.pos.y + EYE, P.pos.z)
end

function P.WorldPos()
    if P.overboard then return P.pos.x, P.pos.y, P.pos.z end
    return Ship.LocalToWorld(P.pos.x, P.pos.y, P.pos.z)
end

function P.Init(deps)
    Inv = deps.inventory
    hooks = deps.hooks or {}

    body = FindObject("Player")
    cam = FindObject("Player Camera")
    if body == nil or cam == nil then
        error("player.lua: в сцене нет сущностей 'Player' и/или 'Player Camera'")
    end
    cam.Transform.Position = Vec3(0.0, EYE, 0.0)

    -- Встаём на НОСУ, лицом вперёд: первое, что видит игрок, — открытое море
    -- до горизонта, а не мачта в упор и не стена каюты. (Нос смотрит в +Z, а
    -- рыскание 0 — это взгляд в -Z, поэтому 180.)
    P.pos.x, P.pos.y, P.pos.z = 0.0, 1.0, 5.0
    P.yaw, P.pitch = 180.0, -3.0

    -- Фонарик. Прожектор ДОЧЕРНИЙ камере, а не отдельная сущность, которую
    -- пришлось бы каждый кадр доворачивать вслед за взглядом: иерархия уже
    -- умеет это делать, и луч не отстаёт от камеры ни на кадр.
    --
    -- Выключен на старте: игра начинается днём, и включённый фонарь при солнце
    -- выглядит поломкой, а не возможностью.
    P.flashlight = FindObject("Flashlight")
    if P.flashlight == nil then
        P.flashlight = SpawnObject("Flashlight")
        P.flashlight:SetParent(cam)
    end
    if not P.flashlight:HasLight() then P.flashlight:AddLight() end
    local L = P.flashlight:GetLight()
    L.Kind = LightType.Spot
    L.Color = Vec3(1.0, 0.94, 0.80)   -- тёплый, как лампа накаливания
    L.Range = 26.0
    L.InnerConeDeg = 13.0
    L.OuterConeDeg = 26.0
    L.Intensity = 0.0                 -- 0 = выключен
    -- Чуть ниже и правее глаз: фонарь в руке, а не во лбу. Свет из точки взгляда
    -- не даёт теней на том, во что смотришь, и сцена выглядит плоской.
    P.flashlight.Transform.Position = Vec3(0.18, -0.16, 0.0)
    P.flashlightOn = false

    -- Контроллер персонажа движка со СВОИМ миром: твердь — воксельная палуба
    -- корабля (см. moveOnDeck). Высота шага 0.6 — как в майнкрафте: на леер и
    -- полублок всходят шагом, на целый блок надо прыгать. Больше нельзя: с
    -- шагом в блок игрок «зашагивает» на стену любой высоты.
    sage.physics.SetCharacterShape(body, {
        radius = HALF_W, height = HEIGHT, step = 0.6, mass = 70.0,
    })
    sage.physics.SetCharacterWorld(body, function(x0, y0, z0, x1, y1, z1)
        return Ship.BoxBlocked(x0, y0, z0, x1, y1, z1)
    end)

    -- Рука в кадре. Дочерняя камере, как и фонарик, и по той же причине: за
    -- взглядом её доворачивает иерархия, а не скрипт (см. hand.lua).
    Hand.Build(cam)

    P.Apply()
end

-- Фонарик: включить/выключить. Возвращает новое состояние.
function P.ToggleFlashlight()
    if P.flashlight == nil then return false end
    P.flashlightOn = not P.flashlightOn
    P.flashlight:GetLight().Intensity = P.flashlightOn and 2.4 or 0.0
    return P.flashlightOn
end

function P.Apply()
    local wx, wy, wz = P.WorldPos()
    local bt = body.Transform
    local p = bt.Position
    p.x, p.y, p.z = wx, wy + P.bob, wz
    bt.Rotation.y = P.yaw

    local cr = cam.Transform.Rotation
    cr.x = P.pitch
    -- Лёгкий крен камеры вслед за кораблём: полный кренит горизонт и укачивает,
    -- нулевой убивает ощущение лодки. Треть — то, на чём это читается и не мешает.
    cr.z = P.overboard and 0.0 or (Ship.roll * 0.3)
end

function P.SetLook(yaw, pitch)
    P.yaw = yaw % 360.0
    P.pitch = math.max(-MAX_PITCH, math.min(MAX_PITCH, pitch))
end

function P.LookAnglesTo(tx, ty, tz)
    local ex, ey, ez = P.WorldEye()
    local dx, dy, dz = tx - ex, ty - ey, tz - ez
    local flat = math.sqrt(dx * dx + dz * dz)
    return math.deg(math.atan(-dx, -dz)), math.deg(math.atan(dy, flat))
end

-- --- Переход палуба <-> вода ------------------------------------------------
local function goOverboard()
    if P.overboard then return end
    local wx, wy, wz = P.WorldPos()
    P.pos.x, P.pos.y, P.pos.z = wx, wy, wz
    P.vel.x, P.vel.y, P.vel.z = 0, 0, 0
    P.overboard = true
    if hooks.OnOverboard then hooks.OnOverboard() end
end

local function climbAboard()
    if not P.overboard then return end
    -- Обратный перевод: мир -> корабль. Крен мал, поэтому обратную матрицу не
    -- строим — вычесть положение корпуса достаточно, а полблока погрешности на
    -- краю палубы съедает подъём на ступеньку.
    P.pos.x = P.pos.x - Ship.pos.x
    P.pos.y = P.pos.y - Ship.pos.y
    P.pos.z = P.pos.z - Ship.pos.z
    P.vel.x, P.vel.y, P.vel.z = 0, 0, 0
    P.overboard = false
    if hooks.OnAboard then hooks.OnAboard() end
end

P.ClimbAboard = climbAboard

-- --- Движение ---------------------------------------------------------------
-- Вытолкнуть игрока, если он оказался ВНУТРИ геометрии. Так бывает: палуба
-- перестраивается прямо под ногами, и блок можно поставить туда, где стоишь.
-- Застрявший навсегда игрок — худшее, что может случиться в игре, из которой
-- нельзя проиграть, поэтому выход есть всегда: сперва вверх, а если и там
-- сплошняк — на нос, на свободное место.
-- Ходьба по палубе идёт КОНТРОЛЛЕРОМ ПЕРСОНАЖА ДВИЖКА (sage.physics), а не
-- своими руками.
--
-- Мир корабля в физике не лежит и лежать не должен: палуба — воксельная сетка,
-- собранная этим же скриптом, и она качается вместе с корпусом, то есть живёт
-- в корабельных координатах. Заводить на каждый кубик кинематическое тело
-- значило бы держать тысячу тел и двигать их все каждый кадр.
--
-- Поэтому контроллеру отдан НАШ мир: движок спрашивает «занят ли этот объём»,
-- отвечает Ship.BoxBlocked, а всю ходьбу — упор в стену, скольжение вдоль
-- борта, ступеньку, опору, выталкивание из тверди — ведёт движок. Здесь
-- остаются только правила игры: разгон, бег, приседание, прыжок и тяготение.
--
-- Раньше всё это было написано здесь, и здесь же жил баг: «ступенька»
-- поднимала игрока на блок и оставляла наверху, ничего не проверив, — держа W
-- у отвесной стены, он взбирался на любую высоту. У движка подъём ограничен
-- высотой шага, свободой над головой и обязательной посадкой на опору.
local function moveOnDeck(dt, input)
    local p, v = P.pos, P.vel

    local fx, _, fz = P.ForwardFlat()
    local rx, _, rz = P.RightFlat()
    local wx = fx * input.moveF + rx * input.moveR
    local wz = fz * input.moveF + rz * input.moveR
    local wlen = math.sqrt(wx * wx + wz * wz)
    if wlen > 0.0001 then wx, wz = wx / wlen, wz / wlen end

    local speed = WALK
    if input.sprint and input.moveF > 0 then speed = SPRINT end
    if input.crouch then speed = speed * 0.45 end

    local accel = P.onGround and ACCEL_G or ACCEL_A
    local blend = math.min(1.0, accel * dt)
    v.x = v.x + (wx * speed - v.x) * blend
    v.z = v.z + (wz * speed - v.z) * blend

    if input.jump and P.onGround then v.y = JUMP_V end
    v.y = v.y + GRAVITY * dt
    if v.y < -40.0 then v.y = -40.0 end

    -- Контроллер работает в КОРАБЕЛЬНЫХ координатах: и позиция, и запрос
    -- тверди — в них. Движку всё равно, в какой системе считать, — он ни разу
    -- не обращается к «низу мира» иначе как через переданную скорость.
    sage.physics.SetCharacterPosition(body, Vec3(p.x, p.y, p.z))
    sage.physics.MoveCharacter(body, Vec3(v.x, v.y, v.z), dt)
    local st = sage.physics.CharacterState(body)

    p.x, p.y, p.z = st.position.x, st.position.y, st.position.z
    v.x, v.y, v.z = st.velocity.x, st.velocity.y, st.velocity.z
    P.onGround = st.grounded

    -- Шаг за борт: под ногами нет корабля и мы ниже палубы — за борт.
    local wx2, wy2, wz2 = Ship.LocalToWorld(p.x, p.y, p.z)
    if wy2 < Ocean.Height(wx2, wz2) - 0.35 then goOverboard() end

    -- Покачивание камеры на ходу. Мелочь, ради которой палуба ощущается палубой.
    local moving = P.onGround and (math.abs(v.x) + math.abs(v.z)) > 0.4
    local targetBob = moving and math.sin(Ocean.Time() * 9.0) * 0.045 or 0.0
    P.bob = P.bob + (targetBob - P.bob) * math.min(1.0, dt * 8.0)
end

local function swim(dt, input)
    local p, v = P.pos, P.vel
    local surface = Ocean.Height(p.x, p.z)

    local fx, _, fz = P.ForwardFlat()
    local rx, _, rz = P.RightFlat()
    local wx = fx * input.moveF + rx * input.moveR
    local wz = fz * input.moveF + rz * input.moveR
    local wlen = math.sqrt(wx * wx + wz * wz)
    if wlen > 0.0001 then wx, wz = wx / wlen, wz / wlen end

    v.x = v.x + (wx * SWIM - v.x) * math.min(1.0, 4.0 * dt)
    v.z = v.z + (wz * SWIM - v.z) * math.min(1.0, 4.0 * dt)

    -- Выталкивание к поверхности: утонуть в этой игре нельзя, можно только
    -- промокнуть. Тонущий игрок — это паника, а игра про обратное.
    local depth = surface - (p.y + HEIGHT * 0.6)
    v.y = v.y + depth * 14.0 * dt - 2.0 * dt
    if input.jump then v.y = v.y + SWIM_UP * dt * 4.0 end
    v.y = v.y - v.y * math.min(1.0, 3.0 * dt)

    p.x = p.x + v.x * dt
    p.y = p.y + v.y * dt
    p.z = p.z + v.z * dt

    P.onGround = false
    P.bob = 0.0

    -- Забраться назад. Проверять «есть ли блок ровно там, где я» бесполезно:
    -- пловец висит в воде НИЖЕ палубы, и в его собственной ячейке корабля нет
    -- по определению. Правильный вопрос другой — оказался ли он в ГОРИЗОНТАЛЬНЫХ
    -- границах корпуса; если да, значит он у самого борта и должен вылезти
    -- наверх. Иначе выбраться из воды было бы нельзя вообще.
    local lx = math.floor(p.x - Ship.pos.x)
    local lz = math.floor(p.z - Ship.pos.z)
    -- Ищем САМУЮ НИЗКУЮ площадку, на которой помещается человек, а не самый
    -- высокий блок в колонке. Иначе пловец, подплывший к мачте или к каюте,
    -- телепортировался бы на клотик или на крышу — вылезать из воды надо на
    -- палубу.
    local topY = nil
    for y = Ship.MIN_Y, Ship.MAX_Y do
        if Ship.IsSolid(lx, y, lz)
           and not Ship.IsSolid(lx, y + 1, lz) and not Ship.IsSolid(lx, y + 2, lz) then
            topY = y
            break
        end
    end
    -- Влезть можно только на НИЗКИЙ край — палубу или леер. На стену каюты в
    -- три блока из воды не подтягиваются: пловец, доплывший до кормы, иначе
    -- телепортировался бы на крышу, и вылезать «на борт» означало бы оказаться
    -- на верхотуре в двух шагах от того места, куда он плыл.
    if topY ~= nil and topY <= 1 then
        climbAboard()
        P.pos.x, P.pos.z = lx + 0.5, lz + 0.5
        P.pos.y = topY + 1.0
        P.onGround = true
    end
end

-- --- Кирка и стройка --------------------------------------------------------
-- Куда встанет блок. Два случая, и второй — не мелочь, а единственный способ
-- расширить палубу.
--
-- Луч попал в блок — новый встаёт в пустую ячейку ПЕРЕД ним, как в любой
-- воксельной игре. Но пристроить доску вбок от края палубы так нельзя в
-- принципе: чтобы луч вошёл в наружную грань крайней доски, целиться нужно
-- снаружи, то есть с воды, а игрок стоит на палубе. Поэтому второй случай:
-- луч не встретил ничего и ушёл в воду — берём точку, где он пересекает
-- плоскость палубы, и ставим туда, если рядом есть корабль. Это ровно тот
-- жест, которого ждёшь: «щёлкнуть по воде у борта, чтобы настелить доску».
local function placementCell(hit, ox, oy, oz, dx, dy, dz)
    if hit then return hit.px, hit.py, hit.pz end
    if dy >= -0.05 then return nil end -- смотрим вверх/вдоль: воды не достанем

    local deckTop = 1.0 -- верх слоя палубы (блок ячейки y=0 занимает 0..1)
    local t = (deckTop - oy) / dy
    if t <= 0.0 or t > REACH then return nil end
    return math.floor(ox + dx * t), 0, math.floor(oz + dz * t)
end

local function interact(dt, input)
    local ex, ey, ez = P.WorldEye()
    local dx, dy, dz = P.Forward()

    -- Мусор важнее палубы: багор — основной жест игры, и промахиваться им по
    -- собственной доске обиднее, чем не попасть по доске.
    P.aimDebris = hooks.AimDebris and hooks.AimDebris(ex, ey, ez, dx, dy, dz) or nil

    -- Луч по сетке идёт в КОРАБЕЛЬНЫХ координатах, а смотрит игрок в мировых:
    -- направление нужно повернуть обратно на крен корпуса, иначе на волне
    -- прицел уезжает с блока уже на паре метров.
    local ldx, ldy, ldz = Ship.WorldDirToLocal(dx, dy, dz)
    local hit = nil
    if not P.overboard then
        hit = Ship.Raycast(P.pos.x, P.pos.y + EYE, P.pos.z, ldx, ldy, ldz, REACH)
    end
    P.target = hit

    if input.usePressed and P.aimDebris and hooks.CollectDebris then
        hooks.CollectDebris(P.aimDebris)
        P.aimDebris = nil
        Hand.Swing(false)   -- багром машут один раз, а не непрерывно
        return
    end

    if hit and input.breakHeld then
        if P.breakTarget and (P.breakTarget.x ~= hit.x or P.breakTarget.y ~= hit.y
                              or P.breakTarget.z ~= hit.z) then
            P.breakProgress = 0.0
        end
        P.breakTarget = {x = hit.x, y = hit.y, z = hit.z}
        local hardness = Blocks.Hardness(hit.id)
        if hardness then
            Hand.Swing(true)   -- пока ломаем — рука качается
            P.breakProgress = P.breakProgress + dt
            if P.breakProgress >= hardness then
                P.breakProgress = 0.0
                local got = Ship.BreakBlock(hit.x, hit.y, hit.z)
                if got and hooks.OnBreak then hooks.OnBreak(hit.x, hit.y, hit.z, got) end
            end
        end
    else
        P.breakProgress = 0.0
        P.breakTarget = nil
        Hand.StopSwing()
    end

    if input.placePressed and not P.overboard then
        -- Ставится то, что В РУКЕ, и тратится ИМЕННО ОНО: раньше блок
        -- списывался «из общего запаса» (Inv.Remove по виду), и стопка в руке
        -- могла остаться нетронутой, пока таяла другая в трюме.
        local slot = Inv.selected
        local id = Inv.SlotId(slot)
        local bx, by, bz = placementCell(hit, P.pos.x, P.pos.y + EYE, P.pos.z, ldx, ldy, ldz)
        if bx and id and Blocks.IsPlaceable(id) then
            local p = P.pos
            local intersects = not (bx + 1 <= p.x - HALF_W or bx >= p.x + HALF_W or
                                    bz + 1 <= p.z - HALF_W or bz >= p.z + HALF_W or
                                    by + 1 <= p.y or by >= p.y + HEIGHT)
            if not intersects and Ship.PlaceBlock(bx, by, bz, id) then
                Inv.RemoveFromSlot(slot, 1)
                Hand.Swing(false)
                if hooks.OnPlace then hooks.OnPlace(bx, by, bz, id) end
            end
        end
    end
end

-- --- Поза: сохранение и сброс ----------------------------------------------
--
-- Где стоял и куда смотрел — часть прогресса, а не мелочь оформления. Без неё
-- загрузка ставила игрока на нос лицом вперёд, кто бы и где бы ни вышел из
-- игры: человек закрывал её сидя в каюте у фонаря, а возвращался на ветреный
-- нос — и первым делом шёл обратно.
function P.Snapshot()
    return {x = P.pos.x, y = P.pos.y, z = P.pos.z,
            yaw = P.yaw, pitch = P.pitch, overboard = P.overboard}
end

function P.Restore(d)
    if type(d) ~= "table" then return end
    if d.x and d.y and d.z then P.pos.x, P.pos.y, P.pos.z = d.x, d.y, d.z end
    P.vel.x, P.vel.y, P.vel.z = 0, 0, 0
    -- Координаты игрока — корабельные, ПОКА он на палубе, и мировые за бортом
    -- (см. заголовок файла). Восстановить одну позицию и забыть про этот флаг
    -- значит поставить пловца в те же числа, но в другой системе координат:
    -- он оказался бы внутри корпуса или в километре от лодки.
    P.overboard = d.overboard == true
    if d.yaw then P.SetLook(d.yaw, d.pitch or P.pitch) end
    P.Apply()
end

-- Новая игра: снова на носу, лицом в открытое море.
function P.Reset()
    P.pos.x, P.pos.y, P.pos.z = 0.0, 1.0, 5.0
    P.vel.x, P.vel.y, P.vel.z = 0, 0, 0
    P.yaw, P.pitch = 180.0, -3.0
    P.overboard = false
    P.onGround = false
    P.breakProgress = 0.0
    P.breakTarget = nil
    P.target = nil
    P.aimDebris = nil
    if P.flashlight ~= nil and P.flashlight:Valid() and P.flashlightOn then P.ToggleFlashlight() end
    P.Apply()
end

function P.Update(dt, input)
    P.yaw = (P.yaw - input.lookX) % 360.0
    P.pitch = math.max(-MAX_PITCH, math.min(MAX_PITCH, P.pitch + input.lookY))

    if P.overboard then swim(dt, input) else moveOnDeck(dt, input) end
    interact(dt, input)
    Hand.Update(dt, P, Inv)
    P.Apply()
end

-- Руку прячут вместе с худом: поверх открытого меню или верстака она мешает
-- ровно так же, как прицел.
function P.SetHandVisible(visible) Hand.SetVisible(visible) end

P.EYE_HEIGHT = EYE
P.REACH = REACH

return P
