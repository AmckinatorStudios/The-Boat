-- ---------------------------------------------------------------------------
-- voxel.lua — воксельное ядро игры. Целиком на Lua, поверх обычного ECS движка.
--
-- Движок SAGE ничего не знает про воксели: у него есть сущности с мешем,
-- цветом и трансформом. Весь «майнкрафт» — здесь:
--
--   ХРАНЕНИЕ. Первозданный мир считается на лету из карты высот (worldgen.lua),
--   а всё, что от него отличается — деревья, руда, постройки и ямы игрока —
--   лежит в оверлее правок. Одна таблица на весь мир вместо полутора миллионов
--   ячеек: 96x48x96 в лоб не влезли бы ни по памяти, ни по времени генерации.
--
--   РЕНДЕР. Сущность движка рождается только для блока, у которого есть хоть
--   одна открытая грань, и только внутри радиуса прогрузки вокруг игрока.
--   Закопанный камень не существует для рендера вовсе — иначе на экране жили бы
--   сотни тысяч кубов вместо пары тысяч. Куб у всех блоков один и тот же меш,
--   поэтому движок рисует всю землю пачкой инстансов (см. ecs/RenderBatch).
--
--   ПРОГРУЗКА. Мир нарезан на чанки 8x8; при движении игрока дальние чанки
--   отдают свои сущности, ближние забирают. За кадр строится ограниченное число
--   чанков — иначе первый шаг игрока стоил бы секундной паузы.
--
--   ЛУЧ И СТОЛКНОВЕНИЯ. Кирка бьёт лучом (DDA по сетке), игрок сталкивается с
--   миром коробкой — обе задачи решаются прямыми запросами к Get, без
--   физического движка: физика движка знает про тела, а не про 40 тысяч кубов.
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"
local Worldgen = require "worldgen"

local V = {}

V.SIZE_X, V.SIZE_Y, V.SIZE_Z = 96, 48, 96
V.SEA_LEVEL = 14
V.CHUNK = 8
-- Радиус прогрузки в чанках: 4 -> 9x9 чанков и гарантированные 32 блока обзора
-- в любую сторону. Цена — около девяти тысяч сущностей вместо шести, но все они
-- делят один меш куба и уходят на видеокарту пачками инстансов, так что растёт
-- в основном заполнение экрана, а не число вызовов отрисовки.
V.VIEW_CHUNKS = 4

-- Дальность прогрузки в БЛОКАХ. По ней настраивается туман (см. survival.lua):
-- мир должен таять в дымке ровно там, где кончается прогруженное, иначе виден
-- обрыв «карта закончилась».
function V.ViewDistance() return V.VIEW_CHUNKS * V.CHUNK end

-- Дальность прогрузки — единственная настройка, которой имеет смысл платить за
-- картинку: на слабой машине ставим меньше, на сильной больше (--view=4).
function V.SetViewChunks(n)
    V.VIEW_CHUNKS = math.max(1, math.min(8, math.floor(n)))
end

local AIR = Blocks.AIR
local WATER = Blocks.WATER

local field        -- поле мира из worldgen (карта высот + BaseAt)
local edits = {}   -- оверлей правок: blockKey -> id (в т.ч. AIR — «выкопано»)
local tiles = {}   -- blockKey -> GameObject видимого блока
local tileId = {}  -- blockKey -> id, из которого сущность сделана
local loaded = {}  -- chunkKey -> true, если чанк сейчас прогружен
local editsInChunk = {} -- chunkKey -> { blockKey -> true }: правки вне слоя рельефа
local pending = {} -- очередь чанков на постройку
local pendingSet = {}

local SX, SY, SZ = V.SIZE_X, V.SIZE_Y, V.SIZE_Z
local SEA = V.SEA_LEVEL
local CH = V.CHUNK

local stats = {spawned = 0, removed = 0, live = 0}

local floor = math.floor
local abs = math.abs

local function key(x, y, z) return (y * SZ + z) * SX + x end
local function chunkKey(cx, cz) return cz * 4096 + cx end

-- --- Доступ к блокам --------------------------------------------------------

-- Только оверлей — без рельефа. Нужен генератору, чтобы не сажать листву
-- поверх уже поставленного бревна.
function V.GetRaw(x, y, z)
    return edits[key(x, y, z)]
end

-- Записать в оверлей БЕЗ обновления рендера (генерация мира: сущностей ещё нет).
function V.SetRaw(x, y, z, id)
    if x < 0 or y < 0 or z < 0 or x >= SX or y >= SY or z >= SZ then return end
    local k = key(x, y, z)
    edits[k] = id
    local ck = chunkKey(floor(x / CH), floor(z / CH))
    local bucket = editsInChunk[ck]
    if not bucket then bucket = {}; editsInChunk[ck] = bucket end
    bucket[k] = true
end

function V.Get(x, y, z)
    if x < 0 or y < 0 or z < 0 or x >= SX or y >= SY or z >= SZ then return AIR end
    local e = edits[key(x, y, z)]
    if e ~= nil then return e end
    return field:BaseAt(x, y, z)
end

local Get = V.Get

function V.IsSolid(x, y, z) return Blocks.IsSolid(Get(x, y, z)) end
function V.IsLiquid(x, y, z) return Blocks.IsLiquid(Get(x, y, z)) end
function V.HeightAt(x, z) return field:HeightAt(x, z) end
function V.Spawn() return field.spawn end
function V.Dock() return field.dock end
function V.Beach() return field.beach end

-- --- Видимость и сущности блоков -------------------------------------------

-- Блок виден, если хоть одна из шести граней смотрит в неплотный сосед.
local function exposed(x, y, z)
    if not Blocks.IsOpaque(Get(x + 1, y, z)) then return true end
    if not Blocks.IsOpaque(Get(x - 1, y, z)) then return true end
    if not Blocks.IsOpaque(Get(x, y + 1, z)) then return true end
    if not Blocks.IsOpaque(Get(x, y - 1, z)) then return true end
    if not Blocks.IsOpaque(Get(x, y, z + 1)) then return true end
    if not Blocks.IsOpaque(Get(x, y, z - 1)) then return true end
    return false
end

-- Воду рисуем только по поверхности: толща океана всё равно не видна, а
-- сущностей на неё уходит больше, чем на весь остров.
local function wantsTile(x, y, z, id)
    if id == AIR then return false end
    if id == WATER then return Get(x, y + 1, z) == AIR end
    return exposed(x, y, z)
end

-- Лёгкий разброс оттенка по координатам: одинаковые кубы одного цвета
-- сливаются в плоскую заливку, а мир должен читаться рельефом.
local function shade(id, x, y, z)
    local c = Blocks.Color(id)
    local t = 0.90 + 0.14 * Worldgen.Hash(x, z, y * 31 + 5)
    return Vec3(c.x * t, c.y * t, c.z * t)
end

local function destroyTile(k)
    local obj = tiles[k]
    if obj then
        obj:Destroy()
        tiles[k] = nil
        tileId[k] = nil
        stats.removed = stats.removed + 1
        stats.live = stats.live - 1
    end
end

-- Приводит сущность одной ячейки в соответствие с содержимым мира.
-- Идемпотентна: вызывать можно сколько угодно раз, лишней работы не будет.
local function refreshCell(x, y, z)
    if x < 0 or y < 0 or z < 0 or x >= SX or y >= SY or z >= SZ then return end
    local ck = chunkKey(floor(x / CH), floor(z / CH))
    local k = key(x, y, z)
    if not loaded[ck] then destroyTile(k); return end

    local id = Get(x, y, z)
    if not wantsTile(x, y, z, id) then destroyTile(k); return end

    if tileId[k] == id then return end -- уже стоит нужный блок
    destroyTile(k)

    local obj = SpawnObject("Blk")
    SetMeshCube(obj)
    local t = obj.Transform
    t.Position = Vec3(x + 0.5, y + 0.5, z + 0.5)
    if id == WATER then
        -- Вода чуть ниже полного куба: берег должен выглядеть берегом, а не
        -- ступенькой того же уровня, что и песок.
        t.Scale = Vec3(1.0, 0.86, 1.0)
        t.Position = Vec3(x + 0.5, y + 0.43, z + 0.5)
    end
    obj.Color = shade(id, x, y, z)
    tiles[k] = obj
    tileId[k] = id
    stats.spawned = stats.spawned + 1
    stats.live = stats.live + 1
end

V.RefreshCell = refreshCell

-- Диапазон высот, который вообще может быть виден в колонке: от самого низкого
-- соседа (обрыв показывает свой срез) до кроны деревьев/построек над землёй.
-- Перебирать всю колонку от дна до неба — 48 проверок вместо десяти.
local function columnRange(x, z)
    local h = field:HeightAt(x, z)
    local low = h
    local n = field:HeightAt(x + 1, z); if n < low then low = n end
    n = field:HeightAt(x - 1, z);       if n < low then low = n end
    n = field:HeightAt(x, z + 1);       if n < low then low = n end
    n = field:HeightAt(x, z - 1);       if n < low then low = n end
    local y0 = low - 1
    if y0 < 1 then y0 = 1 end
    local y1 = h + 8
    if y1 < SEA + 1 then y1 = SEA + 1 end
    if y1 >= SY then y1 = SY - 1 end
    return y0, y1
end

local function buildChunk(cx, cz)
    local ck = chunkKey(cx, cz)
    loaded[ck] = true
    local bx, bz = cx * CH, cz * CH
    for z = bz, bz + CH - 1 do
        for x = bx, bx + CH - 1 do
            if x < SX and z < SZ then
                local y0, y1 = columnRange(x, z)
                for y = y0, y1 do refreshCell(x, y, z) end
            end
        end
    end
    -- Правки (деревья, руда, постройки) живут вне слоя рельефа — их ячейки
    -- перебираем поимённо, иначе пришлось бы сканировать колонку целиком.
    local bucket = editsInChunk[ck]
    if bucket then
        for k in pairs(bucket) do
            local x = k % SX
            local rest = (k - x) / SX
            local z = rest % SZ
            local y = (rest - z) / SZ
            refreshCell(x, y, z)
        end
    end
end

local function releaseChunk(cx, cz)
    local ck = chunkKey(cx, cz)
    if not loaded[ck] then return end
    loaded[ck] = nil
    local bx, bz = cx * CH, cz * CH
    -- Сущности ищем по тем же ключам, что и создавали: чанк маленький, а
    -- отдельный список на чанк — ещё одна структура, которую надо чинить при
    -- каждой правке мира.
    for z = bz, bz + CH - 1 do
        for x = bx, bx + CH - 1 do
            for y = 0, SY - 1 do
                local k = key(x, y, z)
                if tiles[k] then destroyTile(k) end
            end
        end
    end
end

-- --- Прогрузка вокруг игрока ------------------------------------------------
function V.UpdateStreaming(px, pz, budget)
    local pcx, pcz = floor(px / CH), floor(pz / CH)
    local r = V.VIEW_CHUNKS

    -- Отдать дальние чанки. Идём по прогруженным, а не по всей карте.
    local drop = nil
    for ck in pairs(loaded) do
        local cx = ck % 4096
        local cz = (ck - cx) / 4096
        if abs(cx - pcx) > r or abs(cz - pcz) > r then
            drop = drop or {}
            drop[#drop + 1] = {cx, cz}
        end
    end
    if drop then
        for _, c in ipairs(drop) do releaseChunk(c[1], c[2]) end
    end

    -- Набрать ближние. Ближе к игроку — раньше: мир должен появляться из-под
    -- ног наружу, а не пятнами на горизонте.
    for ring = 0, r do
        for cz = pcz - ring, pcz + ring do
            for cx = pcx - ring, pcx + ring do
                if abs(cx - pcx) == ring or abs(cz - pcz) == ring then
                    local ck = chunkKey(cx, cz)
                    if cx >= 0 and cz >= 0 and cx * CH < SX and cz * CH < SZ
                       and not loaded[ck] and not pendingSet[ck] then
                        pending[#pending + 1] = {cx, cz}
                        pendingSet[ck] = true
                    end
                end
            end
        end
    end

    local built = 0
    while built < budget and #pending > 0 do
        local c = table.remove(pending, 1)
        pendingSet[chunkKey(c[1], c[2])] = nil
        buildChunk(c[1], c[2])
        built = built + 1
    end
    return built, #pending
end

-- Прогрузить всё вокруг точки разом (старт игры: мир должен быть готов до
-- первого кадра, а не собираться на глазах у игрока).
function V.PreloadAround(px, pz)
    local guard = 0
    repeat
        local _, left = V.UpdateStreaming(px, pz, 8)
        guard = guard + 1
    until left == 0 or guard > 200
end

-- --- Изменение мира ---------------------------------------------------------
function V.SetBlock(x, y, z, id)
    if x < 0 or y < 1 or z < 0 or x >= SX or y >= SY or z >= SZ then return false end
    V.SetRaw(x, y, z, id)
    refreshCell(x, y, z)
    -- Соседи могли открыть или закрыть грань — их сущности тоже пересобираем.
    refreshCell(x + 1, y, z); refreshCell(x - 1, y, z)
    refreshCell(x, y + 1, z); refreshCell(x, y - 1, z)
    refreshCell(x, y, z + 1); refreshCell(x, y, z - 1)
    return true
end

-- Разрушение: под уровнем моря дыра сразу заполняется водой, если рядом вода.
-- Без этого в океане оставались бы висящие пузыри воздуха.
function V.BreakBlock(x, y, z)
    local id = Get(x, y, z)
    if id == AIR or Blocks.Hardness(id) == nil then return nil end
    local fill = AIR
    if y <= SEA then
        if V.IsLiquid(x + 1, y, z) or V.IsLiquid(x - 1, y, z) or
           V.IsLiquid(x, y, z + 1) or V.IsLiquid(x, y, z - 1) or
           V.IsLiquid(x, y + 1, z) then
            fill = WATER
        end
    end
    V.SetBlock(x, y, z, fill)
    return Blocks.Drop(id)
end

function V.PlaceBlock(x, y, z, id)
    local cur = Get(x, y, z)
    if cur ~= AIR and not Blocks.IsLiquid(cur) then return false end
    return V.SetBlock(x, y, z, id)
end

-- --- Луч кирки (DDA по сетке) ----------------------------------------------
--
-- Возвращает таблицу с координатами задетого блока, координатами ПОСЛЕДНЕЙ
-- пустой ячейки перед ним (туда ставится новый блок) и дистанцией; nil — луч
-- ушёл в небо.
function V.Raycast(ox, oy, oz, dx, dy, dz, maxDist)
    local x, y, z = floor(ox), floor(oy), floor(oz)
    local stepX = (dx > 0) and 1 or -1
    local stepY = (dy > 0) and 1 or -1
    local stepZ = (dz > 0) and 1 or -1

    local INF = math.huge
    local tMaxX, tMaxY, tMaxZ = INF, INF, INF
    local tDeltaX, tDeltaY, tDeltaZ = INF, INF, INF
    if dx ~= 0 then
        tDeltaX = abs(1.0 / dx)
        tMaxX = ((dx > 0) and (x + 1 - ox) or (x - ox)) / dx
    end
    if dy ~= 0 then
        tDeltaY = abs(1.0 / dy)
        tMaxY = ((dy > 0) and (y + 1 - oy) or (y - oy)) / dy
    end
    if dz ~= 0 then
        tDeltaZ = abs(1.0 / dz)
        tMaxZ = ((dz > 0) and (z + 1 - oz) or (z - oz)) / dz
    end

    local px, py, pz = x, y, z
    local t = 0.0
    for _ = 1, 256 do
        local id = Get(x, y, z)
        if id ~= AIR and not Blocks.IsLiquid(id) then
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
        if y < 0 or y >= SY then return nil end
    end
    return nil
end

-- --- Столкновения коробкой --------------------------------------------------
function V.BoxBlocked(minX, minY, minZ, maxX, maxY, maxZ)
    local x0, x1 = floor(minX), floor(maxX)
    local y0, y1 = floor(minY), floor(maxY)
    local z0, z1 = floor(minZ), floor(maxZ)
    for y = y0, y1 do
        for z = z0, z1 do
            for x = x0, x1 do
                if Blocks.IsSolid(Get(x, y, z)) then return true end
            end
        end
    end
    return false
end

-- Есть ли жидкость в коробке (плавание, кислород).
function V.BoxInLiquid(minX, minY, minZ, maxX, maxY, maxZ)
    for y = floor(minY), floor(maxY) do
        for z = floor(minZ), floor(maxZ) do
            for x = floor(minX), floor(maxX) do
                if Blocks.IsLiquid(Get(x, y, z)) then return true end
            end
        end
    end
    return false
end

-- --- Инициализация ----------------------------------------------------------
function V.Init(seed)
    field = Worldgen.Build{
        sizeX = SX, sizeY = SY, sizeZ = SZ,
        seaLevel = SEA, seed = seed,
    }
    local decor = Worldgen.Decorate(field, V)
    return field, decor
end

function V.Stats()
    return stats.live, stats.spawned, stats.removed
end

-- Ближайший блок данного типа. Радиусы по горизонтали и вертикали заданы
-- отдельно: искать дерево имеет смысл в широком круге, но на пару блоков вверх —
-- перебирать всю высоту мира значит перебрать вчетверо больше пустого воздуха.
-- reject(x,y,z) — необязательный фильтр: вернув true, исключает кандидата
-- (так вызывающий пропускает блоки, до которых уже пробовал дотянуться).
function V.FindNearest(id, cx, cy, cz, radius, vradius, reject)
    vradius = vradius or radius
    local best, bestD = nil, (radius * radius * 2 + vradius * vradius) + 1
    for y = cy - vradius, cy + vradius do
        for z = cz - radius, cz + radius do
            for x = cx - radius, cx + radius do
                if Get(x, y, z) == id and not (reject and reject(x, y, z)) then
                    local dx, dy, dz = x - cx, y - cy, z - cz
                    local d = dx * dx + dy * dy + dz * dz
                    if d < bestD then best = {x = x, y = y, z = z}; bestD = d end
                end
            end
        end
    end
    return best
end

return V
