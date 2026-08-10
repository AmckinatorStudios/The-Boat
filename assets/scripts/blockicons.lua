-- ---------------------------------------------------------------------------
-- blockicons.lua — объёмные иконки предметов вместо плоских значков.
--
-- Каждый блок снимается движком в свою картинку: кубик, повёрнутый как в
-- майнкрафте (три грани разом), при боковом свете. Дальше эта картинка
-- показывается в слоте инвентаря обычным изображением интерфейса.
--
-- Зачем так, а не набором нарисованных значков. Блоков в игре под два десятка, и
-- каждый — цветной куб; рисовать под них четырнадцать спрайтов значит завести
-- вторую копию палитры, которая разъедется с первой при первой же правке
-- цвета. Здесь иконка берётся из ТОГО ЖЕ определения блока, что и сам блок на
-- палубе: перекрасили доску — перекрасилась и её иконка.
--
-- Заодно это проверка рендер-текстур движка на настоящей задаче: съёмка идёт
-- по одному разу на блок (Continuous = false), а не каждый кадр.
--
-- УСТРОЙСТВО. Сцена-стенд лежит далеко под миром: там стоят кубики, по кубику
-- на блок, и рядом с каждым — камера, снимающая только его. Под миром, а не
-- рядом с кораблём, ровно затем, чтобы в кадр иконки не попало ни море, ни
-- палуба: ортогональная камера с ближней и дальней плоскостями в несколько
-- метров не видит вообще ничего, кроме своего кубика.
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"

local I = {}

-- Куда спрятать стенд. Достаточно глубоко, чтобы туда не доставали ни волны,
-- ни мусор, ни игрок, упавший за борт.
local STAGE_Y = -1000.0
local STEP = 8.0        -- расстояние между кубиками стенда
local SIZE = 96         -- сторона картинки в пикселях

-- Направление на камеру: три грани куба видно разом, верхняя — светлее всех.
-- Те же пропорции, что у иконок майнкрафта: поворот вниз около 30° и разворот
-- на 45°.
local VIEW = Vec3(1.0, 0.82, 1.0)

local built = {}   -- id -> true

local function iconName(id) return "blk" .. tostring(id) end

-- Все идентификаторы, которым нужна иконка: и блоки, и предметы.
local function everyId()
    local ids = {}
    for _, id in ipairs({Blocks.PLANK, Blocks.BEAM, Blocks.RAIL, Blocks.WALL, Blocks.ROOF,
                         Blocks.MAST, Blocks.SAIL, Blocks.BARREL, Blocks.CRATE, Blocks.LANTERN,
                         Blocks.PURIFIER, Blocks.NET, Blocks.PLANTER,
                         Blocks.FURNACE, Blocks.BENCH, Blocks.CHEST,
                         Blocks.SCRAP, Blocks.ROPE, Blocks.CLOTH, Blocks.PLASTIC,
                         Blocks.FISH, Blocks.SEAWEED, Blocks.WATER, Blocks.ROD,
                         Blocks.CHARCOAL, Blocks.COOKED, Blocks.DRIED}) do
        if id then ids[#ids + 1] = id end
    end
    return ids
end

function I.Build()
    local n = 0
    for _, id in ipairs(everyId()) do
        if not built[id] then
            local at = Vec3(n * STEP, STAGE_Y, 0.0)

            local cube = SpawnObject("Icon " .. tostring(id))
            SetMeshCube(cube)
            local c = Blocks.Color(id)
            cube.Color = Vec3(c.x, c.y, c.z)
            cube.Transform.Position = at
            cube.Transform.Rotation = Vec3(0, 0, 0)
            local r = cube:GetRenderer()
            -- Кубик стенда не участвует ни в тенях, ни в отражениях: тень от
            -- него легла бы в никуда, а в отражении воды он всплыл бы посреди
            -- моря — оба дефекта видно сразу, а искать их пришлось бы долго.
            r.CastShadows = false
            r.InReflections = false
            if Blocks.IsLight(id) then
                r.Emissive = Vec3(1.0, 0.72, 0.34)
                r.EmissiveStrength = 1.2
            elseif id == Blocks.FURNACE then
                -- Печка на иконке светится устьем: без этого её кубик серый и
                -- в ряду ящиков не отличается от камня.
                r.Emissive = Vec3(1.0, 0.45, 0.15)
                r.EmissiveStrength = 0.5
            end

            local cam = SpawnObject("Icon Cam " .. tostring(id))
            cam.Transform.Position = Vec3(at.x + VIEW.x * 3.0, at.y + VIEW.y * 3.0,
                                          at.z + VIEW.z * 3.0)
            sage.rt.Attach(cam, {
                name = iconName(id),
                width = SIZE, height = SIZE,
                ortho = true,
                -- Чуть больше половины диагонали куба: кубик занимает кадр
                -- почти целиком, но углы не срезаются.
                size = 0.80,
                near = 0.5, far = 8.0,
                look = at,
                clear = Vec4(0, 0, 0, 0),   -- прозрачный фон
                continuous = false,
                -- Своё ровное освещение: иконка обязана читаться и в полдень,
                -- и ночью, а с солнцем сцены половина значков к вечеру
                -- становится чёрными квадратами.
                studio = true,
            })

            built[id] = true
            n = n + 1
        end
    end
    return n
end

-- Путь для интерфейса. nil — иконки нет, вызывающий покажет плоский значок.
function I.Path(id)
    if id == nil or not built[id] then return nil end
    local name = iconName(id)
    if not sage.rt.Ready(name) then return nil end
    return "rt:" .. name
end

return I
