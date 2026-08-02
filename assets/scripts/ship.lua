-- ---------------------------------------------------------------------------
-- ship.lua — корабль: сетка блоков, качка на волне, ломать и строить.
--
-- Корабль живёт в СВОИХ координатах, а не в мировых. Каждый блок — дочерняя
-- сущность корневой «Ship», и в мир его переводит движок, перемножая матрицы
-- иерархии. Поэтому качка стоит ровно одну правку трансформа корня в кадр:
-- поднять и накренить сотню досок по отдельности было бы в сто раз дороже и
-- сразу разъехалось бы — палуба перестала бы быть палубой.
--
-- Из того же следует главное правило: столкновения, луч кирки и установка
-- блоков считаются в КОРАБЕЛЬНЫХ координатах. Игрок хранит свою позицию тоже
-- в них — он стоит на палубе, а не в мире, — и в мир переводится только для
-- рендера и для вопросов к воде. Иначе каждая волна дёргала бы игрока сквозь
-- палубу: пол уехал вверх, а игрок остался.
--
-- Сетка маленькая и разреженная (сотни блоков, не миллионы), поэтому никаких
-- чанков и прогрузки: обычная таблица «ключ ячейки -> блок» и сущность на
-- каждый видимый блок.
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"
local Ocean = require "ocean"

local Ship = {}

Ship.MIN_X, Ship.MAX_X = -14, 14
Ship.MIN_Y, Ship.MAX_Y = 0, 8
Ship.MIN_Z, Ship.MAX_Z = -16, 16

local AIR = Blocks.AIR
local floor, abs, max, min = math.floor, math.abs, math.max, math.min

local cells = {}     -- ключ -> id блока
local tiles = {}     -- ключ -> сущность
local tileId = {}    -- ключ -> id, из которого сделана сущность
local lights = {}    -- ключ -> сущность-источник света (фонари)
local root            -- корневая сущность корабля (её и качает)
local blockCount = 0

-- Положение и крен корабля в мире — читают игрок, мусор и звук.
Ship.pos = {x = 0.0, y = Ocean.SEA_LEVEL, z = 0.0}
Ship.roll, Ship.pitch = 0.0, 0.0
Ship.drift = 0.0        -- пройдено метров (счётчик пути)
-- Лодка идёт БЫСТРЕЕ течения — иначе она никогда не догнала бы плывущий по
-- нему мусор, и собирать было бы нечего. Паруса добавляют к этому запасу.
Ship.speed = 1.2        -- базовая скорость, блоков/с
Ship.sails = 0          -- поднятых парусов: прибавка к скорости

local SPAN_X = Ship.MAX_X - Ship.MIN_X + 1
local SPAN_Y = Ship.MAX_Y - Ship.MIN_Y + 1

local function key(x, y, z)
    return ((z - Ship.MIN_Z) * SPAN_Y + (y - Ship.MIN_Y)) * SPAN_X + (x - Ship.MIN_X)
end

local function inBounds(x, y, z)
    return x >= Ship.MIN_X and x <= Ship.MAX_X
       and y >= Ship.MIN_Y and y <= Ship.MAX_Y
       and z >= Ship.MIN_Z and z <= Ship.MAX_Z
end

function Ship.Get(x, y, z)
    if not inBounds(x, y, z) then return AIR end
    return cells[key(x, y, z)] or AIR
end

local Get = Ship.Get

function Ship.IsSolid(x, y, z) return Blocks.IsSolid(Get(x, y, z)) end

-- --- Сущности блоков --------------------------------------------------------
local function exposed(x, y, z)
    if not Blocks.IsOpaque(Get(x + 1, y, z)) then return true end
    if not Blocks.IsOpaque(Get(x - 1, y, z)) then return true end
    if not Blocks.IsOpaque(Get(x, y + 1, z)) then return true end
    if not Blocks.IsOpaque(Get(x, y - 1, z)) then return true end
    if not Blocks.IsOpaque(Get(x, y, z + 1)) then return true end
    if not Blocks.IsOpaque(Get(x, y, z - 1)) then return true end
    return false
end

local function destroyTile(k)
    local obj = tiles[k]
    if obj then
        obj:Destroy()
        tiles[k] = nil
        tileId[k] = nil
    end
    local lamp = lights[k]
    if lamp then
        lamp:Destroy()
        lights[k] = nil
    end
end

-- Лёгкий разнобой оттенка по координатам: сотня одинаковых досок сливается в
-- заливку, а палуба должна читаться досками.
local function plankShade(id, x, y, z)
    local c = Blocks.Color(id)
    local n = ((x * 7 + z * 13 + y * 5) % 11) / 11.0
    local t = 0.92 + 0.13 * n
    return c.x * t, c.y * t, c.z * t
end

local function refreshCell(x, y, z)
    if not inBounds(x, y, z) then return end
    local k = key(x, y, z)
    local id = Get(x, y, z)

    if id == AIR or not exposed(x, y, z) then destroyTile(k); return end
    if tileId[k] == id then return end
    destroyTile(k)

    local obj = SpawnObject("Deck")
    SetMeshCube(obj)
    local t = obj.Transform
    t.Position = Vec3(x + 0.5, y + 0.5, z + 0.5)
    -- Леер и сеть — тонкие: сплошной куб на краю палубы превратил бы борт в
    -- стену и закрыл бы вид на воду, ради которого игрок здесь и находится.
    if id == Blocks.RAIL then
        -- Тонкая сторона — ПОПЕРЁК линии ограждения, а не всегда по Z. Иначе
        -- вдоль бортов (они идут по Z) леер разваливается на отдельные бруски
        -- с просветами между ними вместо сплошного поручня.
        local alongZ = Get(x, y, z + 1) == Blocks.RAIL or Get(x, y, z - 1) == Blocks.RAIL
        if alongZ then t.Scale = Vec3(0.16, 0.55, 1.0)
        else t.Scale = Vec3(1.0, 0.55, 0.16) end
    elseif id == Blocks.NET then
        t.Scale = Vec3(0.94, 0.1, 0.94)
    elseif id == Blocks.SAIL then
        t.Scale = Vec3(0.12, 0.98, 0.98)
    end
    local r, g, b = plankShade(id, x, y, z)
    obj.Color = Vec3(r, g, b)
    obj:SetParent(root)
    tiles[k] = obj
    tileId[k] = id

    -- Фонарь — настоящий источник света движка, а не просто жёлтый куб: ночью
    -- он должен освещать палубу вокруг себя.
    if Blocks.IsLight(id) then
        local lamp = SpawnObject("Lantern Light")
        SetMeshNone(lamp)
        lamp.Transform.Position = Vec3(x + 0.5, y + 0.9, z + 0.5)
        local lc = lamp:AddLight()
        lc.Kind = LightType.Point
        lc.Color = Vec3(1.0, 0.78, 0.45)
        lc.Intensity = 2.2
        lc.Range = 9.0
        lamp:SetParent(root)
        lights[k] = lamp
    end
end

-- --- Изменение корабля ------------------------------------------------------
function Ship.SetBlock(x, y, z, id, quiet)
    if not inBounds(x, y, z) then return false end
    local k = key(x, y, z)
    local was = cells[k] or AIR
    if id == AIR then cells[k] = nil else cells[k] = id end
    if was == AIR and id ~= AIR then blockCount = blockCount + 1
    elseif was ~= AIR and id == AIR then blockCount = blockCount - 1 end

    if quiet then return true end
    refreshCell(x, y, z)
    refreshCell(x + 1, y, z); refreshCell(x - 1, y, z)
    refreshCell(x, y + 1, z); refreshCell(x, y - 1, z)
    refreshCell(x, y, z + 1); refreshCell(x, y, z - 1)
    return true
end

function Ship.BreakBlock(x, y, z)
    local id = Get(x, y, z)
    if id == AIR or Blocks.Hardness(id) == nil then return nil end
    Ship.SetBlock(x, y, z, AIR)
    if id == Blocks.SAIL then Ship.sails = max(0, Ship.sails - 1) end
    return id
end

function Ship.PlaceBlock(x, y, z, id)
    if Get(x, y, z) ~= AIR then return false end
    -- Строить можно только рядом с уже существующим блоком: корабль — цельная
    -- конструкция, а не доски, висящие сами по себе над водой.
    local touching = Get(x + 1, y, z) ~= AIR or Get(x - 1, y, z) ~= AIR
                  or Get(x, y + 1, z) ~= AIR or Get(x, y - 1, z) ~= AIR
                  or Get(x, y, z + 1) ~= AIR or Get(x, y, z - 1) ~= AIR
    if not touching then return false end
    if not Ship.SetBlock(x, y, z, id) then return false end
    if id == Blocks.SAIL then Ship.sails = Ship.sails + 1 end
    return true
end

-- --- Луч и столкновения (всё в корабельных координатах) ---------------------
function Ship.Raycast(ox, oy, oz, dx, dy, dz, maxDist)
    local x, y, z = floor(ox), floor(oy), floor(oz)
    local stepX = (dx > 0) and 1 or -1
    local stepY = (dy > 0) and 1 or -1
    local stepZ = (dz > 0) and 1 or -1
    local INF = math.huge
    local tMaxX, tMaxY, tMaxZ = INF, INF, INF
    local tDeltaX, tDeltaY, tDeltaZ = INF, INF, INF
    if dx ~= 0 then tDeltaX = abs(1.0 / dx); tMaxX = ((dx > 0) and (x + 1 - ox) or (x - ox)) / dx end
    if dy ~= 0 then tDeltaY = abs(1.0 / dy); tMaxY = ((dy > 0) and (y + 1 - oy) or (y - oy)) / dy end
    if dz ~= 0 then tDeltaZ = abs(1.0 / dz); tMaxZ = ((dz > 0) and (z + 1 - oz) or (z - oz)) / dz end

    local px, py, pz = x, y, z
    local t = 0.0
    for _ = 1, 96 do
        local id = Get(x, y, z)
        if id ~= AIR then
            return {x = x, y = y, z = z, px = px, py = py, pz = pz, id = id, dist = t}
        end
        px, py, pz = x, y, z
        if tMaxX < tMaxY and tMaxX < tMaxZ then
            x = x + stepX; t = tMaxX; tMaxX = tMaxX + tDeltaX
        elseif tMaxY < tMaxZ then
            y = y + stepY; t = tMaxY; tMaxY = tMaxY + tDeltaY
        else
            z = z + stepZ; t = tMaxZ; tMaxZ = tMaxZ + tDeltaZ
        end
        if t > maxDist then return nil end
    end
    return nil
end

function Ship.BoxBlocked(minX, minY, minZ, maxX, maxY, maxZ)
    for y = floor(minY), floor(maxY) do
        for z = floor(minZ), floor(maxZ) do
            for x = floor(minX), floor(maxX) do
                if Blocks.IsSolid(Get(x, y, z)) then return true end
            end
        end
    end
    return false
end

-- Есть ли палуба под точкой (для подсказок и для мусора, чтобы не заплывал внутрь).
function Ship.Footprint(x, z)
    for y = Ship.MIN_Y, Ship.MAX_Y do
        if Get(floor(x), y, floor(z)) ~= AIR then return true end
    end
    return false
end

-- --- Стартовый корабль ------------------------------------------------------
--
-- «Скромный корабль»: палуба с сужающимся носом, борта, каюта на корме, мачта
-- с парусом, пара бочек. Ровно столько, чтобы было где стоять и что переделывать.
local function buildStarterShip()
    local set = function(x, y, z, id) Ship.SetBlock(x, y, z, id, true) end

    for z = -6, 7 do
        -- Нос сужается к z = 7: прямоугольный плот выглядит плотом, а не кораблём.
        local halfW = 3
        if z >= 5 then halfW = 2 end
        if z >= 7 then halfW = 1 end
        for x = -halfW, halfW do
            set(x, 0, z, Blocks.PLANK)
        end
    end
    -- Борта. Нос (z = 7) НАМЕРЕННО открыт: это и место, где стоят и смотрят
    -- вперёд, и единственный край, от которого палубу можно достроить — леер
    -- поперёк носа перекрывал бы луч и вместе с ним всю пристройку.
    for z = -6, 6 do
        local halfW = 3
        if z >= 5 then halfW = 2 end
        set(-halfW, 1, z, Blocks.RAIL)
        set(halfW, 1, z, Blocks.RAIL)
    end
    for x = -3, 3 do set(x, 1, -6, Blocks.RAIL) end

    -- Каюта на корме: три стены, дверной проём и крыша. Каюта УЖЕ палубы и
    -- сдвинута к левому борту — вдоль правого остаётся проход на корму. Каюта
    -- во всю ширину отрезала бы кормовую полосу от остального корабля: попав
    -- туда (например, вылезая из воды), выйти было бы уже нельзя.
    for x = -2, 1 do
        for z = -5, -3 do
            local edge = (x == -2 or x == 1 or z == -5)
            if edge then
                set(x, 1, z, Blocks.WALL)
                set(x, 2, z, Blocks.WALL)
            end
            set(x, 3, z, Blocks.ROOF)
        end
    end
    set(0, 1, -3, AIR); set(0, 2, -3, AIR) -- проём в каюту

    -- Мачта с парусом. Парус начинается с y=3: голова игрока (рост 1.75 от
    -- палубы на y=1) достаёт до 2.75, и полотнище ниже пришлось бы обходить
    -- вместо того, чтобы просто пройти под мачтой.
    for y = 1, 5 do set(0, y, 3, Blocks.MAST) end
    for y = 3, 4 do
        for z = 1, 5 do
            if z ~= 3 then set(0, y, z, Blocks.SAIL) end
        end
    end
    Ship.sails = 8

    -- Быт: бочка, ящик, фонарь у каюты.
    set(2, 1, -1, Blocks.BARREL)
    set(-2, 1, 0, Blocks.CRATE)
    set(1, 1, -3, Blocks.LANTERN)
end

function Ship.Init()
    root = SpawnObject("Ship")
    SetMeshNone(root)
    buildStarterShip()
    -- Сущности строим ПОСЛЕ того, как выложена вся сетка: иначе каждый блок
    -- пересобирал бы соседей, которых ещё нет, и половина граней осталась бы
    -- лишней — сотни невидимых кубов внутри корпуса.
    for k, _ in pairs(cells) do
        local x = k % SPAN_X + Ship.MIN_X
        local rest = (k - (k % SPAN_X)) / SPAN_X
        local y = rest % SPAN_Y + Ship.MIN_Y
        local z = (rest - (rest % SPAN_Y)) / SPAN_Y + Ship.MIN_Z
        refreshCell(x, y, z)
    end
    return blockCount
end

-- --- Качка ------------------------------------------------------------------
-- Пока игрок за бортом, лодка ложится в дрейф. Иначе она уходит от пловца
-- почти с его собственной скоростью, и одно неудачное движение у борта стоит
-- корабля насовсем — в игре, которая обещает, что проиграть в ней нельзя.
Ship.waiting = false

function Ship.Update(dt)
    -- Корабль сносит течением: мир бесконечен, поэтому «плывём» — это движение
    -- лодки по воде, а не подмена мира под ней.
    local speed = Ship.speed + Ship.sails * 0.08
    if Ship.waiting then speed = speed * 0.12 end
    Ship.pos.x = Ship.pos.x + Ocean.CURRENT.x * speed * dt
    Ship.pos.z = Ship.pos.z + Ocean.CURRENT.z * speed * dt
    Ship.drift = Ship.drift + speed * dt

    -- Высота — по воде под серединой корпуса, крен — по наклону волны.
    -- Сглаживаем: корпус тяжёлый, он не повторяет рябь один в один.
    local targetY = Ocean.Height(Ship.pos.x, Ship.pos.z)
    Ship.pos.y = Ship.pos.y + (targetY - Ship.pos.y) * min(1.0, dt * 3.2)

    local sx, sz = Ocean.Slope(Ship.pos.x, Ship.pos.z)
    local targetRoll = max(-7.0, min(7.0, -sx * 60.0))
    local targetPitch = max(-7.0, min(7.0, sz * 60.0))
    Ship.roll = Ship.roll + (targetRoll - Ship.roll) * min(1.0, dt * 2.4)
    Ship.pitch = Ship.pitch + (targetPitch - Ship.pitch) * min(1.0, dt * 2.4)

    if root ~= nil and root:Valid() then
        local t = root.Transform
        local p = t.Position
        p.x, p.y, p.z = Ship.pos.x, Ship.pos.y, Ship.pos.z
        local r = t.Rotation
        r.x, r.z = Ship.pitch, Ship.roll
    end
end

-- Корабельная точка -> мировая. Крен учитывается ТЕМ ЖЕ порядком поворотов,
-- каким движок собирает матрицу корня (Rx * Ry * Rz, Ry здесь ноль). Иначе
-- игрок стоял бы горизонтально, пока палуба под ним кренится: на краю борта
-- расхождение доходит до трети блока — ноги в воздухе или колени в досках.
function Ship.LocalToWorld(x, y, z)
    local cr = math.cos(math.rad(Ship.roll))
    local sr = math.sin(math.rad(Ship.roll))
    local x1, y1, z1 = x * cr - y * sr, x * sr + y * cr, z
    local cp = math.cos(math.rad(Ship.pitch))
    local sp = math.sin(math.rad(Ship.pitch))
    local x2, y2, z2 = x1, y1 * cp - z1 * sp, y1 * sp + z1 * cp
    return Ship.pos.x + x2, Ship.pos.y + y2, Ship.pos.z + z2
end

Ship.ToWorld = Ship.LocalToWorld

-- Мировое НАПРАВЛЕНИЕ -> корабельное (обратный поворот, без переноса).
-- Нужно всему, что целится: игрок смотрит в мире, а сетка блоков живёт в
-- координатах корпуса, и на крене в семь градусов луч промахивается по блоку
-- уже с двух метров.
function Ship.WorldDirToLocal(dx, dy, dz)
    local cp = math.cos(math.rad(-Ship.pitch))
    local sp = math.sin(math.rad(-Ship.pitch))
    local x1, y1, z1 = dx, dy * cp - dz * sp, dy * sp + dz * cp
    local cr = math.cos(math.rad(-Ship.roll))
    local sr = math.sin(math.rad(-Ship.roll))
    return x1 * cr - y1 * sr, x1 * sr + y1 * cr, z1
end

-- Сколько на корабле блоков данного вида. Нужно и игре (сколько парусов,
-- фонарей, опреснителей), и проверкам: «поставил фонарь» честно подтверждается
-- только тем, что фонарь есть в сетке, а не тем, что он пропал из рук.
function Ship.CountBlocks(id)
    local n = 0
    for _, v in pairs(cells) do
        if v == id then n = n + 1 end
    end
    return n
end

function Ship.Root() return root end
function Ship.BlockCount() return blockCount end

-- --- Сохранение постройки ---------------------------------------------------
--
-- Лодка — это то, ради чего в игру и заходят: она собирается часами и обязана
-- пережить выход. Пишем ПЛОСКИЙ список {x, y, z, id}, а не карту ключей: ключ
-- считается из границ, а границы — величина кода, и стоит их однажды
-- поменять, как все старые сохранения молча съедут на несколько блоков.
-- Координаты в файле переживают такую правку, ключ — нет.
function Ship.Snapshot()
    local out = {}
    for z = Ship.MIN_Z, Ship.MAX_Z do
        for y = Ship.MIN_Y, Ship.MAX_Y do
            for x = Ship.MIN_X, Ship.MAX_X do
                local id = cells[key(x, y, z)]
                if id and id ~= AIR then
                    out[#out + 1] = {x, y, z, id}
                end
            end
        end
    end
    return out
end

function Ship.Restore(list)
    if type(list) ~= "table" then return 0 end
    -- Снимаем то, что уже стоит: загрузка обязана ЗАМЕНИТЬ лодку, а не
    -- достроить её поверх начальной — иначе после каждой загрузки на палубе
    -- копятся блоки из стартового плота.
    for z = Ship.MIN_Z, Ship.MAX_Z do
        for y = Ship.MIN_Y, Ship.MAX_Y do
            for x = Ship.MIN_X, Ship.MAX_X do
                if cells[key(x, y, z)] then Ship.SetBlock(x, y, z, AIR, true) end
            end
        end
    end
    local placed = 0
    for _, b in ipairs(list) do
        if #b >= 4 then
            Ship.SetBlock(b[1], b[2], b[3], b[4], true)
            placed = placed + 1
        end
    end
    return placed
end

return Ship
