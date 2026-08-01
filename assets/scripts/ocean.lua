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
-- Волны считаются только вблизи. Дальше десятка метров качка мельче пикселя, и
-- гонять по ней тысячи плиток каждый кадр — платить за то, чего не видно;
-- амплитуда плавно гаснет к горизонту, поэтому границы «тут волны, тут нет»
-- не видно тоже.
-- ---------------------------------------------------------------------------
local Ocean = {}

Ocean.SEA_LEVEL = 0.55      -- высота спокойной воды в мире
Ocean.TILE = 2.0            -- сторона плитки воды в блоках
Ocean.RADIUS = 26           -- радиус сетки в плитках (видимый океан ~104 блока)
Ocean.WAVE_RADIUS = 12.0    -- в плитках: дальше волны гаснут
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
    p.y = Ocean.SEA_LEVEL - 0.5 * Ocean.TILE * 0.35
end

function Ocean.Build()
    local n = Ocean.RADIUS * 2 + 1
    for j = -Ocean.RADIUS, Ocean.RADIUS do
        for i = -Ocean.RADIUS, Ocean.RADIUS do
            local obj = SpawnObject("Sea")
            SetMeshCube(obj)
            local t = obj.Transform
            -- Плитка — плоский параллелепипед, а не плоскость: у воды должна
            -- быть толщина, иначе с уровня палубы она читается как бумажный лист.
            t.Scale = Vec3(Ocean.TILE, Ocean.TILE * 0.35, Ocean.TILE)
            obj.Color = Vec3(calmColor[1], calmColor[2], calmColor[3])
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

-- Один кадр океана: сдвинуть время, перецентровать сетку, покачать и
-- перекрасить ближние плитки.
function Ocean.Update(dt, px, pz)
    time = time + dt
    recenter(px, pz)

    local waveR = Ocean.WAVE_RADIUS
    local waveR2 = waveR * waveR
    local ri = floor(waveR)
    for j = -ri, ri do
        for i = -ri, ri do
            local d2 = i * i + j * j
            if d2 <= waveR2 then
                local idx = tileIndex(i, j)
                local obj = tiles[idx]
                if obj ~= nil then
                    local cell = tileCell[idx]
                    local wx = cell[1] * Ocean.TILE + Ocean.TILE * 0.5
                    local wz = cell[2] * Ocean.TILE + Ocean.TILE * 0.5
                    -- Затухание к краю круга волн: без него на воде был бы
                    -- виден ровный круг «здесь качает, здесь нет».
                    local fade = 1.0 - sqrt(d2) / waveR
                    fade = fade * fade * (3.0 - 2.0 * fade)
                    local h = Ocean.Height(wx, wz) - Ocean.SEA_LEVEL
                    local p = obj.Transform.Position
                    p.y = Ocean.SEA_LEVEL + h * fade - 0.5 * Ocean.TILE * 0.35

                    -- Гребни светлее и зеленее впадин — по этому перепаду глаз
                    -- и читает объём воды; на плоской заливке моря не видно.
                    local k = max(0.0, min(1.0, (h / 0.42) * 0.5 + 0.5)) * fade
                    local c = obj.Color
                    c.x = calmColor[1] + (crestColor[1] - calmColor[1]) * k
                    c.y = calmColor[2] + (crestColor[2] - calmColor[2]) * k
                    c.z = calmColor[3] + (crestColor[3] - calmColor[3]) * k
                end
            end
        end
    end
end

-- Цвет воды подстраивается под время суток (закат красит море, а не только
-- небо). Зовётся редко — из смены суток, а не каждый кадр.
function Ocean.SetMood(calm, crest)
    calmColor = calm
    crestColor = crest
end

function Ocean.TileCount() return (Ocean.RADIUS * 2 + 1) ^ 2 end

return Ocean
