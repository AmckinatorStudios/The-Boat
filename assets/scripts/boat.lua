-- ---------------------------------------------------------------------------
-- boat.lua — цель игры: собрать на причале плот и уплыть с острова.
--
-- Лодка — не отдельная сущность с полоской прогресса, а НАСТОЯЩИЕ блоки,
-- поставленные игроком в размеченном месте: корпус из досок и паруса над ним.
-- Поэтому «прогресс постройки» ниоткуда не берётся — он каждый кадр
-- пересчитывается из мира. Сломал доску — прогресс упал; это честно и не
-- требует ни одного дополнительного состояния, которое могло бы разъехаться
-- с тем, что игрок видит перед собой.
--
-- Пустые клетки причала подсвечены полупризрачными плитами: без разметки
-- «поставь доски вон туда» превращается в угадайку.
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"

local B = {}

B.needPlanks = 8
B.needSails = 2
B.planks = 0
B.sails = 0
B.ready = false
B.escaped = false   -- отдали швартовы, идёт финальная сцена
B.finished = false  -- финальная сцена доиграла, игра пройдена

local V, hooks
local dock
local markers = {}   -- ключ клетки -> сущность-подсказка
local recount = 0.0
local escapeTimer = 0.0

local function cellKey(x, z) return z * 1024 + x end

function B.Init(deps)
    V = deps.voxel
    hooks = deps.hooks or {}
    dock = V.Dock()
    B.center = {
        x = (dock.x0 + dock.x1) * 0.5 + 0.5,
        y = dock.y,
        z = (dock.z0 + dock.z1) * 0.5 + 0.5,
    }
    B.Recount()
end

function B.InDock(px, py, pz)
    return px >= dock.x0 - 1.0 and px <= dock.x1 + 2.0
       and pz >= dock.z0 - 1.0 and pz <= dock.z1 + 2.0
       and py >= dock.y - 2.0 and py <= dock.y + 4.0
end

local function updateMarker(x, z, filled)
    local k = cellKey(x, z)
    local obj = markers[k]
    if filled then
        if obj then obj:Destroy(); markers[k] = nil end
        return
    end
    if obj and obj:Valid() then return end
    local m = SpawnObject("Dock Marker")
    SetMeshCube(m)
    local t = m.Transform
    t.Position = Vec3(x + 0.5, dock.y + 0.05, z + 0.5)
    t.Scale = Vec3(0.92, 0.08, 0.92)
    m.Color = Vec3(0.95, 0.78, 0.25)
    markers[k] = m
end

function B.Recount()
    local planks, sails = 0, 0
    for z = dock.z0, dock.z1 do
        for x = dock.x0, dock.x1 do
            local filled = V.Get(x, dock.y, z) == Blocks.PLANK
            if filled then planks = planks + 1 end
            updateMarker(x, z, filled)
            for y = dock.y + 1, dock.y + 3 do
                if V.Get(x, y, z) == Blocks.SAIL then sails = sails + 1 end
            end
        end
    end
    B.planks, B.sails = planks, sails

    local nowReady = planks >= B.needPlanks and sails >= B.needSails
    if nowReady ~= B.ready then
        B.ready = nowReady
        if hooks.OnReadyChanged then hooks.OnReadyChanged(nowReady) end
    end
end

-- Отплытие: игрока плавно уносит в открытое море, управление отдано сцене.
-- Через SAIL_TIME движение прекращается — финальный кадр должен ЗАМЕРЕТЬ на
-- виде острова с воды, а не уезжать бесконечно за край мира, унося с собой всю
-- прогрузку (мир позади выгружается, и в кадре не остаётся ничего).
local SAIL_TIME = 6.0

local function sailAway(dt, P)
    if B.finished then return end
    escapeTimer = escapeTimer + dt
    if escapeTimer <= SAIL_TIME then
        P.pos.z = P.pos.z + 3.2 * dt
        P.pos.y = V.SEA_LEVEL + 1.4
        P.vel.x, P.vel.y, P.vel.z = 0, 0, 0
        P.SetLook(0.0, 4.0) -- оглянуться на остров, с которого ушёл
        P.Apply()
    else
        B.finished = true
        if hooks.OnEscaped then hooks.OnEscaped() end
    end
end

function B.Update(dt, P, input)
    if B.escaped then
        sailAway(dt, P)
        return
    end

    -- Пересчёт раз в четверть секунды: постройка идёт блоками, а не кадрами.
    recount = recount - dt
    if recount <= 0.0 then
        recount = 0.25
        B.Recount()
    end

    if input.usePressed and B.ready and B.InDock(P.pos.x, P.pos.y, P.pos.z) then
        B.escaped = true
        escapeTimer = 0.0
        -- Подсказки больше не нужны — причал опустел, лодка уходит.
        for k, m in pairs(markers) do
            if m:Valid() then m:Destroy() end
            markers[k] = nil
        end
        if hooks.OnSetSail then hooks.OnSetSail() end
    end
end

return B
