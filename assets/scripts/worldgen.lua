-- ---------------------------------------------------------------------------
-- worldgen.lua — генерация мира «The Boat»: остров посреди океана.
--
-- Мир НЕ хранится поблочно. Хранится только карта высот (одна запись на
-- колонку, ~9 тысяч чисел), а сам блок вычисляется на лету из высоты и слоя:
-- «выше высоты — воздух или вода, верхний блок — трава/песок, ниже — земля,
-- ещё ниже — камень». Это на два порядка меньше памяти, чем таблица из полутора
-- миллионов ячеек, и ровно поэтому мир можно сделать большим, оставаясь в Lua.
-- Всё, что в схему «колонка + слои» не укладывается (деревья, руда, обломки
-- корабля), досыпается ПОВЕРХ — в тот же оверлей правок, что и постройки
-- игрока (см. voxel.lua).
--
-- Шум — свой, на целочисленном хэше: math.random зависит от состояния
-- генератора и посева где-то ещё, а мир по одному и тому же seed обязан
-- получаться идентичным (на этом держится и автопрогон в CI, и «загрузить тот
-- же мир завтра»).
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"

local Worldgen = {}

-- --- Детерминированный хэш и шум -------------------------------------------
local MOD = 2147483647

-- Целочисленный хэш трёх координат в [0,1). Только сложение/умножение/остаток:
-- никаких sin и никакой плавающей точки — результат побитово одинаков на любой
-- машине, а значит один seed везде даёт один мир.
local function ihash(a, b, c)
    local n = (a * 73856093 + b * 19349663 + c * 83492791) % MOD
    n = (n * 1103515245 + 12345) % MOD
    n = (n * 1103515245 + 12345) % MOD
    return n / MOD
end

local function lerp(a, b, t) return a + (b - a) * t end
local function smooth(t) return t * t * (3.0 - 2.0 * t) end

-- Шум значений: решётка случайных чисел + сглаженная интерполяция между ними.
local function valueNoise(x, z, freq, seed)
    local fx, fz = x * freq, z * freq
    local x0, z0 = math.floor(fx), math.floor(fz)
    local tx, tz = smooth(fx - x0), smooth(fz - z0)
    local v00 = ihash(x0,     z0,     seed)
    local v10 = ihash(x0 + 1, z0,     seed)
    local v01 = ihash(x0,     z0 + 1, seed)
    local v11 = ihash(x0 + 1, z0 + 1, seed)
    return lerp(lerp(v00, v10, tx), lerp(v01, v11, tx), tz)
end

-- Сумма октав: крупные холмы + средние складки + мелкая рябь.
local function fbm(x, z, seed)
    local amp, freq, sum, norm = 1.0, 1.0 / 26.0, 0.0, 0.0
    for o = 1, 4 do
        sum = sum + valueNoise(x, z, freq, seed + o * 101) * amp
        norm = norm + amp
        amp = amp * 0.5
        freq = freq * 2.0
    end
    return sum / norm
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- --- Поле мира --------------------------------------------------------------
local Field = {}
Field.__index = Field

function Field:ColumnIndex(x, z) return z * self.sizeX + x end

function Field:HeightAt(x, z)
    if x < 0 or z < 0 or x >= self.sizeX or z >= self.sizeZ then return 0 end
    return self.height[self:ColumnIndex(x, z)]
end

function Field:TopAt(x, z)
    if x < 0 or z < 0 or x >= self.sizeX or z >= self.sizeZ then return Blocks.AIR end
    return self.top[self:ColumnIndex(x, z)]
end

-- Блок «первозданного» мира — без правок игрока и без растительности.
-- Горячий путь: зовётся из каждого луча кирки и каждой проверки столкновения,
-- поэтому здесь только арифметика, никаких таблиц кроме карты высот.
function Field:BaseAt(x, y, z)
    if y < 0 or y >= self.sizeY then return Blocks.AIR end
    if x < 0 or z < 0 or x >= self.sizeX or z >= self.sizeZ then return Blocks.AIR end
    if y == 0 then return Blocks.STONE end -- дно мира: не даём прокопать в пустоту

    local i = self:ColumnIndex(x, z)
    local h = self.height[i]
    if y > h then
        if y <= self.seaLevel then return Blocks.WATER end
        return Blocks.AIR
    end
    if y == h then return self.top[i] end
    if y >= h - 3 then
        -- Под пляжем — песок, под травой — земля: срез берега должен выглядеть
        -- как берег, а не как трава на камне.
        return (self.top[i] == Blocks.SAND) and Blocks.SAND or Blocks.DIRT
    end
    return Blocks.STONE
end

-- --- Построение -------------------------------------------------------------
--
-- cfg: { sizeX, sizeY, sizeZ, seaLevel, seed }
function Worldgen.Build(cfg)
    local field = setmetatable({}, Field)
    field.sizeX, field.sizeY, field.sizeZ = cfg.sizeX, cfg.sizeY, cfg.sizeZ
    field.seaLevel = cfg.seaLevel
    field.seed = cfg.seed
    field.height = {}
    field.top = {}

    local cx, cz = cfg.sizeX * 0.5, cfg.sizeZ * 0.5
    local islandRadius = math.min(cfg.sizeX, cfg.sizeZ) * 0.42

    for z = 0, cfg.sizeZ - 1 do
        for x = 0, cfg.sizeX - 1 do
            -- Маска острова: суша в середине, к краю карты — открытая вода.
            -- Без неё «остров» упирался бы в границу мира отвесной стеной.
            local dx, dz = x - cx, z - cz
            local dist = math.sqrt(dx * dx + dz * dz) / islandRadius
            local mask = clamp(1.25 - dist, 0.0, 1.0)
            mask = mask * mask * (3.0 - 2.0 * mask)

            local h = 3.0 + fbm(x, z, cfg.seed) * 30.0 * mask + mask * 6.0
            h = math.floor(clamp(h, 1, cfg.sizeY - 8))

            local top
            if h <= cfg.seaLevel then
                top = Blocks.SAND                  -- дно и мелководье
            elseif h <= cfg.seaLevel + 2 then
                top = Blocks.SAND                  -- пляж
            elseif h >= cfg.seaLevel + 16 then
                top = Blocks.STONE                 -- голая вершина
            else
                top = Blocks.GRASS
            end

            local i = z * cfg.sizeX + x
            field.height[i] = h
            field.top[i] = top
        end
    end

    -- --- Берег кораблекрушения: ровная площадка, с которой начинается игра ---
    -- Ровный старт — не украшательство: на склоне первые же шаги игрока (и
    -- автопрогона в CI) упирались бы в подъёмы, и «работает ли игра» зависело
    -- бы от того, куда лёг шум.
    local beach = {x0 = 38, x1 = 58, z0 = 60, z1 = 80, h = cfg.seaLevel + 1}
    for z = beach.z0, beach.z1 do
        for x = beach.x0, beach.x1 do
            if x >= 0 and z >= 0 and x < cfg.sizeX and z < cfg.sizeZ then
                local i = z * cfg.sizeX + x
                field.height[i] = beach.h
                field.top[i] = Blocks.SAND
            end
        end
    end
    field.beach = beach
    -- Точка высадки выбрана так, чтобы первый же кадр рассказывал игру: обломки
    -- корабля впереди-справа, размеченный причал дальше по курсу, за ним море.
    field.spawn = {x = 48, y = beach.h + 1, z = 64}
    -- Причал: размеченный участок у самой воды, куда собирается лодка.
    -- 4x2 клетки — ровно столько досок, сколько успевает добыть игрок за первый
    -- игровой день; корпус больше превращал бы финал в рутину.
    field.dock = {x0 = 45, x1 = 48, z0 = 77, z1 = 78, y = beach.h + 1}
    -- Деревья на стартовом пляже — на фиксированных местах: первые доски игрок
    -- (и автопрогон) должен получить гарантированно, а не «если повезёт с шумом».
    field.beachTrees = {
        {x = 42, z = 64}, {x = 54, z = 64}, {x = 41, z = 72},
        {x = 55, z = 72}, {x = 44, z = 62}, {x = 52, z = 62},
    }
    return field
end

-- --- Растительность и руда --------------------------------------------------
--
-- Пишется в ОВЕРЛЕЙ вокселя (V.SetRaw) — туда же, куда потом лягут постройки
-- игрока. Так «природа» и «постройки» ломаются, ставятся и сохраняются одним
-- и тем же кодом, вместо отдельной ветки «это дерево, его трогать нельзя».
local function plantTree(V, field, x, z, height)
    local h = field:HeightAt(x, z)
    if h <= field.seaLevel then return false end -- в воде деревья не растут
    for y = h + 1, h + height do
        V.SetRaw(x, y, z, Blocks.LOG)
    end
    local crown = h + height
    for dy = -1, 2 do
        local r = (dy == 2) and 1 or 2
        for dz = -r, r do
            for dx = -r, r do
                -- Углы кроны выкусываем — иначе шапка выходит кубической.
                if not (math.abs(dx) == r and math.abs(dz) == r and r > 1) then
                    if not (dx == 0 and dz == 0 and dy < 2) then
                        local ly = crown + dy
                        if V.GetRaw(x + dx, ly, z + dz) == nil then
                            V.SetRaw(x + dx, ly, z + dz, Blocks.LEAVES)
                        end
                    end
                end
            end
        end
    end
    return true
end

function Worldgen.Decorate(field, V)
    local seed = field.seed
    local trees, bushes, ore = 0, 0, 0

    -- Пальмы стартового пляжа — по фиксированным местам.
    for i, t in ipairs(field.beachTrees) do
        if plantTree(V, field, t.x, t.z, 4 + (i % 2)) then trees = trees + 1 end
    end

    for z = 2, field.sizeZ - 3 do
        for x = 2, field.sizeX - 3 do
            local top = field:TopAt(x, z)
            local h = field:HeightAt(x, z)
            local inBeach = x >= field.beach.x0 and x <= field.beach.x1 and
                            z >= field.beach.z0 and z <= field.beach.z1
            if top == Blocks.GRASS and not inBeach then
                local r = ihash(x, z, seed + 7)
                if r > 0.988 then
                    if plantTree(V, field, x, z, 4 + math.floor(ihash(x, z, seed + 11) * 3)) then
                        trees = trees + 1
                    end
                elseif r > 0.965 then
                    V.SetRaw(x, h + 1, z, Blocks.BUSH)
                    bushes = bushes + 1
                end
            end
            -- Руда — жилами в камне у поверхности: под гору лезть не обязательно,
            -- но и под ноги она не сыплется.
            if h > field.seaLevel + 4 and ihash(x, z, seed + 23) > 0.985 then
                local y = h - 4 - math.floor(ihash(x, z, seed + 29) * 3)
                if y > 1 then
                    for dy = 0, 1 do
                        for dx = 0, 1 do
                            V.SetRaw(x + dx, y + dy, z, Blocks.IRON)
                            ore = ore + 1
                        end
                    end
                end
            end
        end
    end

    -- Обломки корабля у точки высадки: несколько досок, с которых начинается
    -- и сюжет, и первый инструмент.
    local wreck = {
        {50, 0, 69}, {51, 0, 69}, {52, 0, 69}, {50, 1, 69},
        {52, 1, 70}, {51, 0, 70}, {53, 0, 70},
    }
    local base = field.beach.h
    for _, w in ipairs(wreck) do
        V.SetRaw(w[1], base + 1 + w[2], w[3], Blocks.PLANK)
    end

    return {trees = trees, bushes = bushes, ore = ore}
end

Worldgen.Hash = ihash

return Worldgen
