-- ---------------------------------------------------------------------------
-- player.lua — игрок от первого лица: ходьба, прыжок, плавание, столкновения с
-- вокселями, добыча и установка блоков.
--
-- Про камеру. Движок собирает поворот сущности как Rx*Ry*Rz, то есть тангаж
-- применяется В МИРОВЫХ осях — для вида от первого лица это даёт эффект
-- «наклонённого горизонта» при повороте. Поэтому игрок — ДВЕ сущности:
-- тело хранит рыскание, дочерняя камера — тангаж, а движок перемножает их
-- матрицы в правильном порядке (Ry * Rx). Иерархия сцены делает ровно то, что
-- в других движках приходится делать вручную кватернионом.
--
-- Про столкновения. Игрок — коробка, мир — сетка; проверка идёт по осям
-- раздельно (X, потом Z, потом Y). Разделение по осям — не микрооптимизация:
-- именно оно даёт скольжение вдоль стены вместо залипания в угол.
--
-- Ввод модуль НЕ читает сам: он получает уже собранную таблицу намерений. Так
-- один и тот же код движения обслуживает и человека за мышью, и автопрогон в
-- CI (см. autopilot.lua) — проверяется настоящий игрок, а не его двойник.
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"

local P = {}

-- Габариты и физика. Значения подобраны под блок 1x1x1: игрок чуть ниже двух
-- блоков, проходит в проём высотой 2 и запрыгивает ровно на один блок.
local HALF_W   = 0.3
local HEIGHT   = 1.8
local EYE      = 1.62
local GRAVITY  = -26.0
local JUMP_V   = 8.6     -- высота прыжка v^2/2g ≈ 1.42 блока
local WALK     = 4.3
local SPRINT   = 6.0
local SWIM     = 3.2
local WATER_G  = -6.0
local SWIM_UP  = 3.4
local ACCEL_G  = 12.0    -- отзывчивость на земле
local ACCEL_A  = 2.5     -- в воздухе управляемость хуже
local REACH    = 5.0
local MAX_PITCH = 89.0

local V, Inv, hooks

P.pos = {x = 0, y = 0, z = 0}
P.vel = {x = 0, y = 0, z = 0}
P.yaw, P.pitch = 0.0, 0.0
P.onGround = false
P.inWater = false
P.headInWater = false
P.fallDistance = 0.0
P.target = nil        -- блок под прицелом (для HUD и подсветки)
P.breakProgress = 0.0
P.alive = true

local body, cam

local function rad(d) return d * math.pi / 180.0 end

-- Направление взгляда, согласованное с порядком поворотов движка (см. шапку).
function P.Forward()
    local cp = math.cos(rad(P.pitch))
    return -cp * math.sin(rad(P.yaw)), math.sin(rad(P.pitch)), -cp * math.cos(rad(P.yaw))
end

function P.ForwardFlat()
    return -math.sin(rad(P.yaw)), 0.0, -math.cos(rad(P.yaw))
end

function P.RightFlat()
    return math.cos(rad(P.yaw)), 0.0, -math.sin(rad(P.yaw))
end

function P.EyePosition()
    return P.pos.x, P.pos.y + EYE, P.pos.z
end

local function boxBlockedAt(x, y, z)
    return V.BoxBlocked(x - HALF_W, y, z - HALF_W, x + HALF_W, y + HEIGHT, z + HALF_W)
end

function P.Init(deps)
    V = deps.voxel
    Inv = deps.inventory
    hooks = deps.hooks or {}

    body = FindObject("Player")
    cam = FindObject("Player Camera")
    if body == nil or cam == nil then
        error("player.lua: в сцене нет сущностей 'Player' и/или 'Player Camera'")
    end

    local s = V.Spawn()
    P.pos.x, P.pos.y, P.pos.z = s.x + 0.5, s.y, s.z + 0.5
    -- Спавн строго над твердью: если пляж почему-то оказался ниже, поднимаем
    -- игрока, а не роняем его сквозь мир на первом же кадре.
    while boxBlockedAt(P.pos.x, P.pos.y, P.pos.z) and P.pos.y < V.SIZE_Y - 3 do
        P.pos.y = P.pos.y + 1
    end
    P.yaw, P.pitch = 180.0, -8.0 -- лицом к океану (на юг, +Z)

    local ct = cam.Transform
    ct.Position = Vec3(0.0, EYE, 0.0)
    P.Apply()
end

-- Переносит состояние игрока в сущности сцены. Отдельной функцией, потому что
-- звать её надо и после телепорта/респавна, а не только в конце кадра.
function P.Apply()
    local bt = body.Transform
    bt.Position = Vec3(P.pos.x, P.pos.y, P.pos.z)
    bt.Rotation = Vec3(0.0, P.yaw, 0.0)
    cam.Transform.Rotation = Vec3(P.pitch, 0.0, 0.0)
end

-- Прямая установка взгляда. Нужна не только автопрогону: так же работают
-- катсцены и «повернуть игрока к говорящему» — мышь для этого не годится.
function P.SetLook(yaw, pitch)
    P.yaw = yaw % 360.0
    P.pitch = math.max(-MAX_PITCH, math.min(MAX_PITCH, pitch))
end

-- Куда смотреть, чтобы прицел попал в точку мира (градусы рыскания/тангажа).
function P.LookAnglesTo(tx, ty, tz)
    local ex, ey, ez = P.EyePosition()
    local dx, dy, dz = tx - ex, ty - ey, tz - ez
    local flat = math.sqrt(dx * dx + dz * dz)
    local yaw = math.deg(math.atan(-dx, -dz))
    local pitch = math.deg(math.atan(dy, flat))
    return yaw, pitch
end

function P.Teleport(x, y, z)
    P.pos.x, P.pos.y, P.pos.z = x, y, z
    P.vel.x, P.vel.y, P.vel.z = 0, 0, 0
    P.fallDistance = 0
    P.Apply()
end

-- --- Движение ---------------------------------------------------------------
local function moveAxis(axis, amount)
    if amount == 0.0 then return false end
    local p = P.pos
    local old = p[axis]
    p[axis] = old + amount
    if boxBlockedAt(p.x, p.y, p.z) then
        p[axis] = old
        return true -- упёрлись
    end
    return false
end

local function updateMovement(dt, input)
    local p, v = P.pos, P.vel

    P.inWater = V.BoxInLiquid(p.x - HALF_W, p.y, p.z - HALF_W,
                              p.x + HALF_W, p.y + HEIGHT * 0.5, p.z + HALF_W)
    P.headInWater = V.IsLiquid(math.floor(p.x), math.floor(p.y + EYE), math.floor(p.z))

    -- Желаемое направление в плоскости XZ.
    local fx, _, fz = P.ForwardFlat()
    local rx, _, rz = P.RightFlat()
    local wx = fx * input.moveF + rx * input.moveR
    local wz = fz * input.moveF + rz * input.moveR
    local wlen = math.sqrt(wx * wx + wz * wz)
    if wlen > 0.0001 then wx, wz = wx / wlen, wz / wlen end

    local speed = WALK
    if P.inWater then speed = SWIM
    elseif input.sprint and input.moveF > 0 then speed = SPRINT end
    if input.crouch and not P.inWater then speed = speed * 0.4 end

    local accel = (P.onGround or P.inWater) and ACCEL_G or ACCEL_A
    local blend = math.min(1.0, accel * dt)
    v.x = v.x + (wx * speed - v.x) * blend
    v.z = v.z + (wz * speed - v.z) * blend

    -- Вертикаль: в воде — вязкое всплытие, на суше — обычная гравитация.
    if P.inWater then
        v.y = v.y + WATER_G * dt
        if input.jump then v.y = SWIM_UP end
        v.y = v.y * (1.0 - math.min(1.0, 3.0 * dt))
        P.fallDistance = 0.0
    else
        if input.jump and P.onGround then
            v.y = JUMP_V
            P.onGround = false
        end
        v.y = v.y + GRAVITY * dt
        if v.y < -60.0 then v.y = -60.0 end
    end

    -- Горизонталь: X и Z по отдельности — так игрок скользит вдоль стены.
    local hitX = moveAxis("x", v.x * dt)
    local hitZ = moveAxis("z", v.z * dt)

    -- Автопрыжок на ступеньку в один блок. Без него любой берег и любая
    -- лестница из блоков требовали бы ручного прыжка на каждый шаг.
    if (hitX or hitZ) and P.onGround and not P.inWater and wlen > 0.0001 then
        local stepUp = 1.02
        local savedY = p.y
        p.y = p.y + stepUp
        if not boxBlockedAt(p.x, p.y, p.z) then
            local sx = moveAxis("x", v.x * dt)
            local sz = moveAxis("z", v.z * dt)
            if sx and sz then p.y = savedY else P.onGround = false end
        else
            p.y = savedY
        end
    end
    if hitX then v.x = 0.0 end
    if hitZ then v.z = 0.0 end

    -- Вертикаль и опора.
    local dy = v.y * dt
    local before = p.y
    p.y = before + dy
    if boxBlockedAt(p.x, p.y, p.z) then
        p.y = before
        if dy < 0.0 then
            -- Приземление: сначала сообщаем о падении, потом гасим счётчик.
            if P.fallDistance > 3.0 and hooks.OnFall then hooks.OnFall(P.fallDistance) end
            P.fallDistance = 0.0
            P.onGround = true
        end
        v.y = 0.0
    else
        P.onGround = false
        if dy < 0.0 then P.fallDistance = P.fallDistance - dy end
    end

    -- Границы мира: за карту не выпускаем (там нет ни блоков, ни дна).
    p.x = math.max(1.0, math.min(V.SIZE_X - 1.0, p.x))
    p.z = math.max(1.0, math.min(V.SIZE_Z - 1.0, p.z))
    if p.y < 0.0 then p.y = 0.0; v.y = 0.0 end
end

-- --- Взаимодействие с миром -------------------------------------------------
local function updateInteraction(dt, input)
    local ex, ey, ez = P.EyePosition()
    local dx, dy, dz = P.Forward()
    local hit = V.Raycast(ex, ey, ez, dx, dy, dz, REACH)
    P.target = hit

    if not hit then
        P.breakProgress = 0.0
    elseif input.breakHeld then
        -- Прогресс привязан к КОНКРЕТНОМУ блоку: перевёл прицел — начал заново.
        if P.breakTarget ~= nil and (P.breakTarget.x ~= hit.x or P.breakTarget.y ~= hit.y
                                     or P.breakTarget.z ~= hit.z) then
            P.breakProgress = 0.0
        end
        P.breakTarget = {x = hit.x, y = hit.y, z = hit.z}
        local hardness = Blocks.Hardness(hit.id)
        if hardness then
            P.breakProgress = P.breakProgress + dt
            if P.breakProgress >= hardness then
                P.breakProgress = 0.0
                local drop = V.BreakBlock(hit.x, hit.y, hit.z)
                if drop then
                    Inv.Add(drop, 1)
                    if hooks.OnBreak then hooks.OnBreak(hit.x, hit.y, hit.z, hit.id, drop) end
                end
            end
        end
    else
        P.breakProgress = 0.0
        P.breakTarget = nil
    end

    if input.placePressed and hit then
        local id = Inv.SelectedBlock()
        if id and Inv.Count(id) > 0 then
            local bx, by, bz = hit.px, hit.py, hit.pz
            -- В себя блок не ставим: иначе игрок замуровывается в собственной
            -- голове и остаётся в твёрдом теле навсегда.
            local p = P.pos
            local intersects = not (bx + 1 <= p.x - HALF_W or bx >= p.x + HALF_W or
                                    bz + 1 <= p.z - HALF_W or bz >= p.z + HALF_W or
                                    by + 1 <= p.y or by >= p.y + HEIGHT)
            if not intersects and V.PlaceBlock(bx, by, bz, id) then
                Inv.Remove(id, 1)
                if hooks.OnPlace then hooks.OnPlace(bx, by, bz, id) end
            end
        end
    end
end

function P.Update(dt, input)
    if not P.alive then return end

    P.yaw = (P.yaw - input.lookX) % 360.0
    P.pitch = math.max(-MAX_PITCH, math.min(MAX_PITCH, P.pitch + input.lookY))

    updateMovement(dt, input)
    updateInteraction(dt, input)
    P.Apply()
end

P.EYE_HEIGHT = EYE
P.REACH = REACH

return P
