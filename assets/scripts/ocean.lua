-- ---------------------------------------------------------------------------
-- ocean.lua — бесконечный океан: волны, пена, горизонт.
--
-- Океан здесь не объект и не меш, а ФУНКЦИЯ высоты от точки и времени. Всё
-- остальное — корабль, мусор, игрок — спрашивает у неё «какая тут вода» и
-- живёт своей жизнью. Это и делает мир бесконечным: хранить нечего, за краем
-- карты ничего не кончается, потому что карты нет.
--
-- Видимая вода — сетка плиток вокруг игрока. Плитки не создаются и не удаляются
-- при движении: их ровно столько, сколько нужно на видимый круг, и они
-- ПЕРЕИСПОЛЬЗУЮТСЯ, переезжая на другой край сетки, когда лодку сносит течением.
-- Так на бесконечном океане живёт постоянное число сущностей.
--
-- ФОРМУ волны рисует СВОЙ ШЕЙДЕР (assets/shaders/water.*), а не скрипт. Раньше
-- скрипт двигал каждую плитку целиком, и море выходило ступенчатым: два метра
-- поверхности поднимались одним куском. Шейдер шевелит вершины, поэтому вода
-- гладкая, у неё есть пена на гребнях и прозрачность — при том же числе
-- объектов и том же одном draw call'е на всю воду.
--
-- Скрипт всё равно знает высоту волны — но уже не ради картинки, а ради физики:
-- по ней качается лодка и плавает мусор. Формула в ocean.lua и в water.vert одна
-- и та же, и расходиться им нельзя.
-- ---------------------------------------------------------------------------
local Ocean = {}

local WATER = "assets/materials/water.sagemat"

Ocean.SEA_LEVEL = 0.55      -- высота спокойной воды в мире
-- Плитка крупная (4 блока) намеренно: форму волны рисует шейдер по вершинам, а
-- мелкую рябь — по пикселям, поэтому дробить воду на мелкие квадраты больше
-- незачем. Зато при том же числе сущностей океан виден вдвое дальше — а
-- дальность здесь и есть главное, что отличает «море» от «лужи до тумана».
Ocean.TILE = 4.0            -- сторона плитки воды в блоках
Ocean.RADIUS = 26           -- радиус сетки в плитках (видимый океан ~208 блоков)
Ocean.CURRENT = {x = 0.0, z = -1.0} -- куда сносит мир мимо лодки (нормализован)

-- Три волны с разными периодами и направлениями. Три — минимум, при котором
-- рисунок на воде перестаёт читаться как повторяющаяся синусоида.
local W = {
    {ax = 0.185, az = 0.055, w = 0.95, a = 0.17},
    {ax = -0.065, az = 0.155, w = -0.72, a = 0.14},
    {ax = 0.043, az = 0.037, w = 0.41, a = 0.22},
}

local sin, cos, floor, sqrt, min, max = math.sin, math.cos, math.floor, math.sqrt, math.min, math.max

local time = 0.0
local tiles = {}        -- сущности плиток
local tileCell = {}     -- на какой ячейке сетки сейчас стоит плитка {cx, cz}
local originX, originZ = 0, 0 -- центр сетки в ячейках
local calmColor = {0.055, 0.185, 0.285}
local crestColor = {0.30, 0.56, 0.62}

-- Высота воды в точке. Горячий путь: спрашивают и лодка, и каждый обломок,
-- и каждая плитка каждый кадр.
function Ocean.Height(x, z)
    local h = 0.0
    for i = 1, 3 do
        local w = W[i]
        h = h + sin(x * w.ax + z * w.az + time * w.w) * w.a
    end
    return Ocean.SEA_LEVEL + h
end

-- Наклон поверхности в точке — по нему кренит лодку и разворачивает мусор.
-- Считается конечной разностью: аналитическая производная тут ничего не даёт,
-- а шаг в полметра как раз сглаживает мелкую рябь, на которую качаться не надо.
function Ocean.Slope(x, z)
    local d = 0.5
    local hx = Ocean.Height(x + d, z) - Ocean.Height(x - d, z)
    local hz = Ocean.Height(x, z + d) - Ocean.Height(x, z - d)
    return hx / (2 * d), hz / (2 * d)
end

function Ocean.Time() return time end

-- --- Сетка плиток -----------------------------------------------------------
local function tileIndex(i, j) return (j + Ocean.RADIUS) * (Ocean.RADIUS * 2 + 1) + (i + Ocean.RADIUS) + 1 end

local function placeTile(idx, cx, cz)
    local obj = tiles[idx]
    if obj == nil then return end
    tileCell[idx] = {cx, cz}
    local t = obj.Transform
    local p = t.Position
    p.x = cx * Ocean.TILE + Ocean.TILE * 0.5
    p.z = cz * Ocean.TILE + Ocean.TILE * 0.5
    p.y = Ocean.SEA_LEVEL
end

function Ocean.Build()
    local n = Ocean.RADIUS * 2 + 1
    for j = -Ocean.RADIUS, Ocean.RADIUS do
        for i = -Ocean.RADIUS, Ocean.RADIUS do
            local obj = SpawnObject("Sea")
            -- Плитка — ПЛОСКОСТЬ. Раньше был плоский ящик: пока волну двигал
            -- скрипт, толщина скрывала ступеньки между плитками. Теперь волну
            -- гнёт шейдер, поверхность непрерывна, а у прозрачного ящика сквозь
            -- крышку просвечивают боковые стенки соседей — по всему морю идёт
            -- сетка. У плоскости стенок нет.
            SetMeshPlane(obj)
            local t = obj.Transform
            t.Scale = Vec3(Ocean.TILE, 1.0, Ocean.TILE)
            -- Общий материал со своим шейдером: батчинг сохраняется, все плитки
            -- по-прежнему уходят на видеокарту одной пачкой.
            -- Прозрачность несёт МАТЕРИАЛ, а не сущность: одно число на всю
            -- воду, а не 2809 одинаковых.
            SetMaterial(obj, WATER)
            local idx = tileIndex(i, j)
            tiles[idx] = obj
            placeTile(idx, i, j)
        end
    end
    return n * n
end

-- Перецентровать сетку на точку: плитки, уехавшие за край, переносятся на
-- противоположный. Число сущностей не меняется — океан «бесконечен» именно так.
local function recenter(px, pz)
    local ncx = floor(px / Ocean.TILE)
    local ncz = floor(pz / Ocean.TILE)
    if ncx == originX and ncz == originZ then return end
    originX, originZ = ncx, ncz
    for j = -Ocean.RADIUS, Ocean.RADIUS do
        for i = -Ocean.RADIUS, Ocean.RADIUS do
            local idx = tileIndex(i, j)
            placeTile(idx, originX + i, originZ + j)
        end
    end
end

-- Один кадр океана: сдвинуть время и перецентровать сетку. Волну считает шейдер
-- (uTime приходит от движка), поэтому цикл по тысячам плиток каждый кадр больше
-- не нужен вовсе — раньше он и был главной ценой воды.
function Ocean.Update(dt, px, pz)
    time = time + dt
    recenter(px, pz)
    -- Центр затухания волн едет за лодкой: у шейдера нет способа узнать, где
    -- она, иначе как параметром.
    SetMaterialParam(WATER, "uFocus", Vec3(px, 0.0, pz))
end

-- Цвет воды подстраивается под время суток (закат красит море, а не только
-- небо). Это ДВА параметра общего материала, а не 2809 покрашенных сущностей:
-- назначенный материал всё равно заменяет собой цвет сущности, да и перебирать
-- ради смены оттенка весь океан незачем.
function Ocean.SetMood(calm, crest)
    calmColor, crestColor = calm, crest
    SetMaterialParam(WATER, "uDeepColor", Vec3(calm[1], calm[2], calm[3]))
    SetMaterialParam(WATER, "uCrestColor", Vec3(crest[1], crest[2], crest[3]))
end

function Ocean.TileCount() return (Ocean.RADIUS * 2 + 1) ^ 2 end

return Ocean
