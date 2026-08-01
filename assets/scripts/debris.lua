-- ---------------------------------------------------------------------------
-- debris.lua — плавучий мусор: бочки, ящики, брёвна, водоросли, буи.
--
-- Это единственное в игре, что живёт НАСТОЯЩЕЙ физикой движка: у каждого
-- обломка есть RigidBody и коллайдер, их считает Jolt. Скрипт не двигает их
-- руками — он прикладывает силы, которых у физического движка нет, потому что
-- воды в нём не существует:
--
--   ВЫТАЛКИВАНИЕ — чем глубже предмет утоплен относительно волны над ним, тем
--   сильнее его выпихивает вверх; сила пружинная, поэтому бочка не выстреливает
--   из воды, а качается около поверхности.
--   ВЯЗКОСТЬ — под водой скорость гасится: без неё пружина раскачала бы предмет
--   до бесконечной амплитуды за десяток секунд.
--   ТЕЧЕНИЕ — сносит мусор мимо лодки, давая игроку окно, чтобы его подобрать.
--   ОТТАЛКИВАНИЕ ОТ КОРПУСА — блоки корабля физике неизвестны (это сетка, а не
--   тела), поэтому бочки проплывали бы сквозь палубу; лёгкий толчок в сторону
--   разводит их вокруг лодки.
--
-- Спавн — кольцом выше по течению, снятие — когда унесло за корму. Живых
-- обломков всегда не больше LIMIT: океан бесконечный, память нет.
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"
local Ocean = require "ocean"
local Ship = require "ship"

local D = {}

D.LIMIT = 22
D.SPAWN_EVERY = 1.6      -- секунд между попытками спавна
D.SPAWN_RING = 20.0      -- на каком расстоянии рождается — ПО КУРСУ лодки
D.SPAWN_SPREAD = 7.0     -- разброс вбок от курса
D.DESPAWN = 32.0         -- на каком исчезает
D.REACH = 8.0            -- дальность багра
D.CURRENT_SPEED = 0.7    -- с какой скоростью течение несёт сам мусор

-- Виды мусора: во что превращается при подборе и как выглядит на воде.
local KINDS = {
    {id = "barrel",   name = "Бочка",       color = {0.52, 0.35, 0.22}, size = {0.8, 0.9, 0.8},
     loot = {{Blocks.SCRAP, 2}, {Blocks.PLASTIC, 1}}, weight = 3},
    {id = "crate",    name = "Ящик",        color = {0.66, 0.52, 0.32}, size = {0.9, 0.7, 0.9},
     loot = {{Blocks.SCRAP, 3}, {Blocks.ROPE, 1}}, weight = 3},
    {id = "log",      name = "Бревно",      color = {0.42, 0.30, 0.20}, size = {1.6, 0.5, 0.5},
     loot = {{Blocks.SCRAP, 4}}, weight = 4},
    {id = "weed",     name = "Водоросли",   color = {0.26, 0.46, 0.28}, size = {1.0, 0.22, 1.0},
     loot = {{Blocks.SEAWEED, 2}}, weight = 5},
    {id = "buoy",     name = "Буй",         color = {0.85, 0.42, 0.30}, size = {0.6, 0.6, 0.6},
     loot = {{Blocks.PLASTIC, 2}, {Blocks.ROPE, 1}}, weight = 3},
    {id = "bundle",   name = "Тюк",         color = {0.80, 0.76, 0.66}, size = {0.8, 0.6, 0.8},
     loot = {{Blocks.CLOTH, 2}, {Blocks.ROPE, 1}}, weight = 2},
}

local totalWeight = 0
for _, k in ipairs(KINDS) do totalWeight = totalWeight + k.weight end

local items = {}       -- живые обломки: {obj, kind, ...}
local spawnTimer = 0.0
local rng = 1
local hooks = {}
local collected = 0

local sqrt, abs, max, min, floor = math.sqrt, math.abs, math.max, math.min, math.floor

-- Свой генератор: мир и так детерминирован по seed, и мусор должен быть таким же
-- — иначе автопрогон в CI перестал бы быть воспроизводимым.
local function rand()
    rng = (rng * 1103515245 + 12345) % 2147483648
    return rng / 2147483648
end

function D.Init(deps)
    hooks = deps.hooks or {}
    rng = (deps.seed or 1) % 2147483647
    if rng <= 0 then rng = 1 end
end

local function pickKind()
    local r = rand() * totalWeight
    for _, k in ipairs(KINDS) do
        r = r - k.weight
        if r <= 0 then return k end
    end
    return KINDS[1]
end

local function spawnOne()
    local kind = pickKind()
    -- Рождаем ПО КУРСУ лодки, а не выше по течению. Мусор тоже несёт течением,
    -- но лодка под парусом идёт быстрее него — значит, она мусор ДОГОНЯЕТ.
    -- Спавн за кормой (первое, что приходит в голову от слова «течение»)
    -- означал бы, что игрок уходит от собственной добычи и не встретит ни
    -- одного обломка за всю игру.
    local spread = (rand() - 0.5) * 2.0 * D.SPAWN_SPREAD
    local cx, cz = Ocean.CURRENT.x, Ocean.CURRENT.z
    local px = Ship.pos.x + cx * D.SPAWN_RING - cz * spread
    local pz = Ship.pos.z + cz * D.SPAWN_RING + cx * spread

    local obj = SpawnObject("Flotsam")
    SetMeshCube(obj)
    local t = obj.Transform
    t.Position = Vec3(px, Ocean.Height(px, pz), pz)
    t.Rotation = Vec3(0, rand() * 360.0, 0)
    t.Scale = Vec3(kind.size[1], kind.size[2], kind.size[3])
    local c = kind.color
    local tint = 0.9 + rand() * 0.2
    obj.Color = Vec3(c[1] * tint, c[2] * tint, c[3] * tint)

    -- Физика движка: тело создаётся само на ближайшем шаге симуляции
    -- (PhysicsScene сверяет состав сцены каждый кадр).
    local rb = obj:AddRigidBody()
    rb.Type = BodyType.Dynamic
    rb.Mass = 8.0
    rb.Friction = 0.6
    rb.Restitution = 0.05
    local col = obj:AddCollider()
    col.Shape = ColliderShape.Box
    col.HalfExtents = Vec3(0.5, 0.5, 0.5)

    items[#items + 1] = {obj = obj, kind = kind, age = 0.0, spin = (rand() - 0.5) * 26.0}
end

-- Один обломок: выталкивание, вязкость, течение, обход корпуса.
local function updateItem(it, dt)
    local obj = it.obj
    if not obj:Valid() then return false end
    local p = obj.Transform.Position
    local px, py, pz = p.x, p.y, p.z

    local surface = Ocean.Height(px, pz)
    local depth = surface - py            -- >0 — утоплен
    local v = GetVelocity(obj)

    local vx, vy, vz = v.x, v.y, v.z
    if depth > -0.6 then
        -- Пружина к поверхности + гашение вертикали. Гравитацию отдельно не
        -- вычитаем: её каждый шаг прикладывает сам Jolt, и равновесие пружины
        -- наступает там, где она её уравновешивает — предмет садится в воду
        -- примерно на седьмую часть блока, то есть плавает, а не тонет и не
        -- выпрыгивает. Гашение подобрано так, чтобы он успокаивался за пару
        -- качков, а не звенел до бесконечности.
        local buoy = min(depth, 1.2) * 60.0
        vy = vy + buoy * dt
        vy = vy - vy * min(1.0, 4.5 * dt)
        -- Горизонталь: тянем к скорости течения, а не толкаем — иначе мусор
        -- разгонялся бы неограниченно за минуту дрейфа.
        local cs = D.CURRENT_SPEED
        vx = vx + (Ocean.CURRENT.x * cs - vx) * min(1.0, 1.6 * dt)
        vz = vz + (Ocean.CURRENT.z * cs - vz) * min(1.0, 1.6 * dt)

        -- Обход корпуса: физика о палубе не знает, развести приходится вручную.
        -- Радиус чуть больше половины ширины лодки — ровно чтобы обломок обошёл
        -- борт, а не шарахался от неё за пределы досягаемости багра.
        local lx, lz = px - Ship.pos.x, pz - Ship.pos.z
        local dist = sqrt(lx * lx + lz * lz)
        if dist < 4.5 and dist > 0.01 then
            local push = (4.5 - dist) * 1.2
            vx = vx + (lx / dist) * push * dt
            vz = vz + (lz / dist) * push * dt
        end
    end
    SetVelocity(obj, Vec3(vx, vy, vz))

    -- Медленное вращение на волне — статичный куб на воде выглядит приклеенным.
    obj.Transform.Rotation.y = obj.Transform.Rotation.y + it.spin * dt

    it.age = it.age + dt
    local dx, dz = px - Ship.pos.x, pz - Ship.pos.z
    if sqrt(dx * dx + dz * dz) > D.DESPAWN then
        obj:Destroy()
        return false
    end
    return true
end

function D.Update(dt)
    spawnTimer = spawnTimer - dt
    if spawnTimer <= 0.0 then
        spawnTimer = D.SPAWN_EVERY
        if #items < D.LIMIT then spawnOne() end
    end

    local alive = 0
    for i = 1, #items do
        local it = items[i]
        if updateItem(it, dt) then
            alive = alive + 1
            items[alive] = it
        end
    end
    for i = #items, alive + 1, -1 do items[i] = nil end
end

-- Ближайший обломок под прицелом: не строгий луч, а конус — багром целятся
-- в качающийся на волне предмет, и требовать попадания в центр было бы
-- издевательством, а не уютом.
function D.Aim(ex, ey, ez, dx, dy, dz)
    local best, bestScore = nil, 0.86
    for _, it in ipairs(items) do
        local obj = it.obj
        if obj:Valid() then
            local p = obj.Transform.Position
            local vx, vy, vz = p.x - ex, p.y - ey, p.z - ez
            local dist = sqrt(vx * vx + vy * vy + vz * vz)
            if dist > 0.2 and dist < D.REACH then
                local dot = (vx * dx + vy * dy + vz * dz) / dist
                if dot > bestScore then best, bestScore = it, dot end
            end
        end
    end
    return best
end

function D.Collect(it)
    if it == nil or not it.obj:Valid() then return nil end
    local p = it.obj.Transform.Position
    local wx, wy, wz = p.x, p.y, p.z
    it.obj:Destroy()
    for i, other in ipairs(items) do
        if other == it then table.remove(items, i) break end
    end
    collected = collected + 1
    if hooks.OnCollect then hooks.OnCollect(it.kind, wx, wy, wz) end
    return it.kind.loot, it.kind.name
end

-- Сеть на палубе сама подтягивает проплывающий рядом мусор — ради неё игрок
-- её и строит: сидеть с багром весь день не уютно.
function D.NetPull(netPositions, dt)
    if #netPositions == 0 then return end
    for _, it in ipairs(items) do
        local obj = it.obj
        if obj:Valid() then
            local p = obj.Transform.Position
            for _, np in ipairs(netPositions) do
                local dx, dz = np[1] - p.x, np[3] - p.z
                local d = sqrt(dx * dx + dz * dz)
                if d < 9.0 and d > 0.2 then
                    local v = GetVelocity(obj)
                    local pull = 1.4 * dt
                    SetVelocity(obj, Vec3(v.x + dx / d * pull, v.y, v.z + dz / d * pull))
                    break
                end
            end
        end
    end
end

function D.Count() return #items end
function D.Collected() return collected end

-- Живые обломки списком. Нужен автопилоту: он выбирает цель так же, как это
-- делает глазами человек, и подглядывать в физический мир для этого не должен.
function D.Items() return items end

return D
