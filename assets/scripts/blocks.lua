-- ---------------------------------------------------------------------------
-- blocks.lua — реестр всего, что игрок может держать в руках или поставить на
-- палубу: блоки корабля и предметы (припасы, еда, вода).
--
-- Блок и предмет — одна таблица, а не две. Разница между ними ровно одна:
-- у блока есть поле place (его можно поставить), у предмета нет. Разводить их
-- по разным реестрам значило бы дублировать имена, цвета и всю работу с
-- инвентарём ради одного булева поля.
-- ---------------------------------------------------------------------------
local Blocks = {}

-- --- Блоки корабля (ставятся на палубу) ------------------------------------
Blocks.AIR      = 0
Blocks.PLANK    = 1   -- палуба
Blocks.BEAM     = 2   -- балка/борт
Blocks.RAIL     = 3   -- леер по краю палубы
Blocks.WALL     = 4   -- стена каюты
Blocks.ROOF     = 5   -- крыша
Blocks.MAST     = 6   -- мачта
Blocks.SAIL     = 7   -- парус
Blocks.BARREL   = 8   -- бочка (декор/хранение)
Blocks.CRATE    = 9   -- ящик
Blocks.LANTERN  = 10  -- фонарь: светит ночью
Blocks.PURIFIER = 11  -- опреснитель: делает пресную воду
Blocks.NET      = 12  -- сеть-уловитель: сама притягивает мусор
Blocks.PLANTER  = 13  -- грядка

-- --- Предметы (только в инвентаре) -----------------------------------------
Blocks.SCRAP    = 20  -- доски и щепа с воды
Blocks.ROPE     = 21
Blocks.CLOTH    = 22
Blocks.PLASTIC  = 23
Blocks.FISH     = 24
Blocks.SEAWEED  = 25
Blocks.WATER    = 26  -- пресная вода
Blocks.ROD      = 27  -- удочка (инструмент)

-- icon — имя векторной иконки движка (sage::ui::IconNames). Здесь, а не в
-- худе: иконка описывает ПРЕДМЕТ, ровно как его имя и цвет, и должна ехать
-- вместе с ними — иначе новый блок придётся заводить в двух местах.
local D = {
    -- solid — держит игрока (леер тоже: он ограждение, сквозь него не ходят,
    -- иначе борта не спасают от падения за борт); opaque — закрывает грань
    -- соседа, и вот этого леер как раз не делает: сквозь него видно воду.
    [Blocks.PLANK]    = {name = "Доска",       icon = "plank",    color = {0.74, 0.49, 0.25}, solid = true,  opaque = true,  hard = 0.55, place = true},
    [Blocks.BEAM]     = {name = "Балка",       icon = "log",      color = {0.42, 0.26, 0.14}, solid = true,  opaque = true,  hard = 0.9,  place = true},
    [Blocks.RAIL]     = {name = "Леер",        icon = "rail",     color = {0.56, 0.35, 0.18}, solid = true,  opaque = false, hard = 0.35, place = true},
    [Blocks.WALL]     = {name = "Стена",       icon = "wall",     color = {0.82, 0.66, 0.42}, solid = true,  opaque = true,  hard = 0.7,  place = true},
    [Blocks.ROOF]     = {name = "Крыша",       icon = "wall",     color = {0.46, 0.22, 0.17}, solid = true,  opaque = true,  hard = 0.7,  place = true},
    [Blocks.MAST]     = {name = "Мачта",       icon = "log",      color = {0.38, 0.23, 0.12}, solid = true,  opaque = true,  hard = 1.1,  place = true},
    [Blocks.SAIL]     = {name = "Парус",       icon = "sail",     color = {0.97, 0.94, 0.86}, solid = true,  opaque = true,  hard = 0.4,  place = true},
    [Blocks.BARREL]   = {name = "Бочка",       icon = "barrel",   color = {0.52, 0.30, 0.15}, solid = true,  opaque = true,  hard = 0.6,  place = true},
    [Blocks.CRATE]    = {name = "Ящик",        icon = "crate",    color = {0.70, 0.53, 0.27}, solid = true,  opaque = true,  hard = 0.6,  place = true},
    [Blocks.LANTERN]  = {name = "Фонарь",      icon = "lantern",  color = {1.00, 0.78, 0.42}, solid = true,  opaque = false, hard = 0.4,  place = true, light = true},
    [Blocks.PURIFIER] = {name = "Опреснитель", icon = "purifier", color = {0.55, 0.62, 0.66}, solid = true,  opaque = true,  hard = 0.8,  place = true},
    [Blocks.NET]      = {name = "Сеть",        icon = "net",      color = {0.72, 0.70, 0.52}, solid = true,  opaque = false, hard = 0.35, place = true},
    [Blocks.PLANTER]  = {name = "Грядка",      icon = "leaf",     color = {0.30, 0.42, 0.24}, solid = true,  opaque = true,  hard = 0.5,  place = true},

    -- предметы
    [Blocks.SCRAP]    = {name = "Обломки",     icon = "plank",    color = {0.60, 0.44, 0.28}},
    [Blocks.ROPE]     = {name = "Верёвка",     icon = "rope",     color = {0.78, 0.70, 0.48}},
    [Blocks.CLOTH]    = {name = "Ткань",       icon = "cloth",    color = {0.88, 0.86, 0.80}},
    [Blocks.PLASTIC]  = {name = "Пластик",     icon = "plastic",  color = {0.62, 0.78, 0.80}},
    [Blocks.FISH]     = {name = "Рыба",        icon = "fish",     color = {0.68, 0.74, 0.80}, food = 30.0},
    [Blocks.SEAWEED]  = {name = "Водоросли",   icon = "leaf",     color = {0.30, 0.52, 0.32}, food = 12.0},
    [Blocks.WATER]    = {name = "Вода",        icon = "drop",     color = {0.55, 0.80, 0.92}, drink = 35.0},
    [Blocks.ROD]      = {name = "Удочка",      icon = "rod",      color = {0.72, 0.62, 0.40}, tool = true},
}

local AIR_DEF = {name = "Пусто", icon = "cross", solid = false, opaque = false}

function Blocks.Def(id)
    if id == Blocks.AIR then return AIR_DEF end
    return D[id]
end

function Blocks.Name(id)
    local d = Blocks.Def(id)
    return d and d.name or "?"
end

function Blocks.Icon(id)
    local d = Blocks.Def(id)
    return d and d.icon or "crate"
end

function Blocks.IsSolid(id)
    local d = D[id]
    return d ~= nil and d.solid == true
end

function Blocks.IsOpaque(id)
    local d = D[id]
    return d ~= nil and d.opaque == true
end

function Blocks.IsPlaceable(id)
    local d = D[id]
    return d ~= nil and d.place == true
end

function Blocks.IsLight(id)
    local d = D[id]
    return d ~= nil and d.light == true
end

function Blocks.Hardness(id)
    local d = D[id]
    return d and d.hard
end

function Blocks.Food(id)
    local d = D[id]
    return d and d.food
end

function Blocks.Drink(id)
    local d = D[id]
    return d and d.drink
end

function Blocks.Color(id)
    local d = Blocks.Def(id)
    if not d or not d.color then return Vec3(1, 0, 1) end
    return Vec3(d.color[1], d.color[2], d.color[3])
end

-- Что кладут в хотбар по умолчанию — в порядке слотов.
Blocks.hotbar = {
    Blocks.PLANK, Blocks.RAIL, Blocks.WALL,
    Blocks.LANTERN, Blocks.NET, Blocks.PURIFIER,
}

return Blocks
