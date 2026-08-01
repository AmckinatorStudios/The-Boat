-- ---------------------------------------------------------------------------
-- blocks.lua — реестр типов блоков мира.
--
-- Единственное место, где описано, что такое «песок» или «бревно»: цвет, можно
-- ли сквозь него пройти, сколько секунд его ломать, что из него падает. Всё
-- остальное (генерация, рендер, инвентарь, крафт) читает мир ЧЕРЕЗ этот реестр
-- и про конкретные блоки ничего не знает — добавить новый блок значит дописать
-- сюда строчку, а не править пять файлов.
--
-- Модуль движка: подключается через require (см. ScriptEngine::AddScriptSearchPath).
-- ---------------------------------------------------------------------------
local Blocks = {}

Blocks.AIR      = 0
Blocks.WATER    = 1
Blocks.SAND     = 2
Blocks.DIRT     = 3
Blocks.GRASS    = 4
Blocks.STONE    = 5
Blocks.LOG      = 6
Blocks.LEAVES   = 7
Blocks.PLANK    = 8
Blocks.IRON     = 9
Blocks.BUSH     = 10
Blocks.CAMPFIRE = 11
Blocks.SAIL     = 12

-- solid   — держит игрока и останавливает луч кирки
-- opaque  — закрывает соседа: невидимые грани не порождают сущностей рендера
-- liquid  — в нём плавают и тонут
-- hard    — секунд ломать голыми руками (nil — неразрушим)
-- drop    — что попадает в инвентарь (по умолчанию — сам блок)
local D = {
    [Blocks.WATER]    = {name = "Вода",    color = {0.16, 0.38, 0.62}, solid = false, opaque = false, liquid = true},
    [Blocks.SAND]     = {name = "Песок",   color = {0.85, 0.78, 0.55}, solid = true,  opaque = true,  hard = 0.5},
    [Blocks.DIRT]     = {name = "Земля",   color = {0.45, 0.33, 0.22}, solid = true,  opaque = true,  hard = 0.6},
    [Blocks.GRASS]    = {name = "Трава",   color = {0.32, 0.55, 0.26}, solid = true,  opaque = true,  hard = 0.6,
                         drop = Blocks.DIRT},
    [Blocks.STONE]    = {name = "Камень",  color = {0.46, 0.46, 0.49}, solid = true,  opaque = true,  hard = 1.6},
    [Blocks.LOG]      = {name = "Бревно",  color = {0.42, 0.29, 0.16}, solid = true,  opaque = true,  hard = 1.0},
    [Blocks.LEAVES]   = {name = "Листва",  color = {0.24, 0.47, 0.22}, solid = true,  opaque = true,  hard = 0.25},
    [Blocks.PLANK]    = {name = "Доска",   color = {0.72, 0.55, 0.33}, solid = true,  opaque = true,  hard = 0.8},
    [Blocks.IRON]     = {name = "Руда",    color = {0.62, 0.52, 0.42}, solid = true,  opaque = true,  hard = 2.6},
    [Blocks.BUSH]     = {name = "Куст",    color = {0.55, 0.24, 0.30}, solid = false, opaque = false, hard = 0.15},
    [Blocks.CAMPFIRE] = {name = "Костёр",  color = {0.85, 0.42, 0.16}, solid = true,  opaque = true,  hard = 0.4},
    [Blocks.SAIL]     = {name = "Парус",   color = {0.88, 0.86, 0.80}, solid = true,  opaque = true,  hard = 0.4},
}

-- Воздух описан отдельно: у него нет ни цвета, ни прочности, и попытка
-- обратиться к его полям — почти всегда ошибка в вызывающем коде, а не
-- «пустой блок». Пусть падает громко, а не тихо возвращает nil-цвет.
local AIR_DEF = {name = "Воздух", solid = false, opaque = false}

function Blocks.Def(id)
    if id == Blocks.AIR then return AIR_DEF end
    return D[id]
end

function Blocks.Name(id)
    local d = Blocks.Def(id)
    return d and d.name or "?"
end

function Blocks.IsSolid(id)
    local d = D[id]
    return d ~= nil and d.solid == true
end

function Blocks.IsOpaque(id)
    local d = D[id]
    return d ~= nil and d.opaque == true
end

function Blocks.IsLiquid(id)
    local d = D[id]
    return d ~= nil and d.liquid == true
end

-- Секунд на разрушение голыми руками; nil — блок не ломается вовсе.
function Blocks.Hardness(id)
    local d = D[id]
    return d and d.hard
end

-- Что попадёт в инвентарь при разрушении (трава даёт землю, остальное — себя).
function Blocks.Drop(id)
    local d = D[id]
    if not d then return nil end
    return d.drop or id
end

function Blocks.Color(id)
    local d = Blocks.Def(id)
    if not d or not d.color then return Vec3(1, 0, 1) end -- кричащая «нет текстуры»
    return Vec3(d.color[1], d.color[2], d.color[3])
end

-- Блоки, которые можно СТАВИТЬ из хотбара (вода и костёр ставятся особо).
Blocks.placeable = {
    Blocks.PLANK, Blocks.SAND, Blocks.DIRT, Blocks.STONE, Blocks.LOG, Blocks.CAMPFIRE, Blocks.SAIL,
}

return Blocks
