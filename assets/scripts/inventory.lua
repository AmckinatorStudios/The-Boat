-- ---------------------------------------------------------------------------
-- inventory.lua — что лежит в трюме и во что это превращается.
--
-- Рецепты — данные, а не код: «что тратим» и «что даём». Добавить крафт значит
-- дописать строку, а не ветку в функцию. Хотбар держит только СТАВИМЫЕ блоки,
-- припасы и еда живут в общем списке — раскладывать сыр и доски по разным
-- ящикам в игре про уют незачем.
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"

local Inv = {}

local counts = {}

Inv.hotbar = Blocks.hotbar
Inv.selected = 1

-- Рецепты — данные, а не код. Клавиш у них больше нет: крафт переехал на
-- верстак (см. craft.lua), где видно, что из чего делается и чего не хватает.
-- Восемь номеров, которые надо было помнить наизусть, были не интерфейсом, а
-- его отсутствием: игра сообщала «нажми 6», а что такое 6 — не сообщала нигде,
-- кроме таблицы в README.
Inv.recipes = {
    {id = "plank",    name = "Доска",
     cost = {{Blocks.SCRAP, 2}},                       give = {Blocks.PLANK, 1}},
    {id = "rail",     name = "Леер",
     cost = {{Blocks.SCRAP, 1}, {Blocks.ROPE, 1}},     give = {Blocks.RAIL, 2}},
    {id = "wall",     name = "Стена",
     cost = {{Blocks.SCRAP, 3}},                       give = {Blocks.WALL, 2}},
    {id = "lantern",  name = "Фонарь",
     cost = {{Blocks.SCRAP, 2}, {Blocks.PLASTIC, 2}},  give = {Blocks.LANTERN, 1}},
    {id = "net",      name = "Сеть",
     cost = {{Blocks.ROPE, 3}, {Blocks.PLASTIC, 1}},   give = {Blocks.NET, 1}},
    {id = "purifier", name = "Опреснитель",
     cost = {{Blocks.PLASTIC, 3}, {Blocks.SCRAP, 2}},  give = {Blocks.PURIFIER, 1}},
    {id = "rod",      name = "Удочка",
     cost = {{Blocks.SCRAP, 1}, {Blocks.ROPE, 2}},     give = {Blocks.ROD, 1}},
    {id = "sail",     name = "Парус",
     cost = {{Blocks.CLOTH, 3}, {Blocks.ROPE, 1}},     give = {Blocks.SAIL, 1}},
}

function Inv.Count(id) return counts[id] or 0 end

function Inv.Add(id, n)
    if id == nil or id == Blocks.AIR then return end
    counts[id] = (counts[id] or 0) + (n or 1)
end

function Inv.Remove(id, n)
    n = n or 1
    local have = counts[id] or 0
    if have < n then return false end
    counts[id] = have - n
    return true
end

function Inv.AddLoot(loot)
    for _, entry in ipairs(loot) do Inv.Add(entry[1], entry[2]) end
end

function Inv.Has(id, n) return (counts[id] or 0) >= (n or 1) end

function Inv.SelectedBlock() return Inv.hotbar[Inv.selected] end

function Inv.Select(slot)
    if slot >= 1 and slot <= #Inv.hotbar then Inv.selected = slot end
end

function Inv.Cycle(delta)
    local n = #Inv.hotbar
    Inv.selected = ((Inv.selected - 1 + delta) % n) + 1
end

function Inv.FindRecipe(id)
    for _, r in ipairs(Inv.recipes) do
        if r.id == id then return r end
    end
    return nil
end

function Inv.CanCraft(recipe)
    for _, c in ipairs(recipe.cost) do
        if Inv.Count(c[1]) < c[2] then return false end
    end
    return true
end

-- Чего не хватает на рецепт — строкой. Нужна и верстаку (подсказка под
-- рецептом), и сообщению в худе: считать её в двух местах значило бы однажды
-- разойтись в том, что именно игра называет нехваткой.
function Inv.Missing(recipe)
    local missing = {}
    for _, c in ipairs(recipe.cost) do
        local lack = c[2] - Inv.Count(c[1])
        if lack > 0 then missing[#missing + 1] = Blocks.Name(c[1]) .. " x" .. lack end
    end
    if #missing == 0 then return nil end
    return table.concat(missing, ", ")
end

function Inv.Craft(recipe)
    local missing = Inv.Missing(recipe)
    if missing then return false, "Не хватает: " .. missing end
    for _, c in ipairs(recipe.cost) do Inv.Remove(c[1], c[2]) end
    Inv.Add(recipe.give[1], recipe.give[2])
    return true, recipe.name .. " x" .. recipe.give[2]
end

-- Съесть что-нибудь: перебор идёт от самого сытного, чтобы «поесть» не
-- превращалось в выбор блюда из меню.
function Inv.EatBest()
    local best, bestVal = nil, 0
    for _, id in ipairs({Blocks.FISH, Blocks.SEAWEED}) do
        local food = Blocks.Food(id)
        if food and Inv.Count(id) > 0 and food > bestVal then best, bestVal = id, food end
    end
    if not best then return nil end
    Inv.Remove(best, 1)
    return best, bestVal
end

function Inv.DrinkBest()
    if Inv.Count(Blocks.WATER) > 0 then
        Inv.Remove(Blocks.WATER, 1)
        return Blocks.WATER, Blocks.Drink(Blocks.WATER)
    end
    return nil
end

-- Что игрок несёт — для строки состояния и автопрогона.
function Inv.Summary()
    return string.format("обломки=%d верёвка=%d пластик=%d ткань=%d доска=%d еда=%d вода=%d",
        Inv.Count(Blocks.SCRAP), Inv.Count(Blocks.ROPE), Inv.Count(Blocks.PLASTIC),
        Inv.Count(Blocks.CLOTH), Inv.Count(Blocks.PLANK),
        Inv.Count(Blocks.FISH) + Inv.Count(Blocks.SEAWEED), Inv.Count(Blocks.WATER))
end

-- Что лежит в трюме — списком, в ОДНОМ И ТОМ ЖЕ порядке от кадра к кадру.
--
-- Порядок здесь важнее, чем кажется: трюм показан сеткой слотов, и если
-- обходить counts через pairs, предметы будут прыгать между ячейками при
-- каждом обновлении — таблица Lua порядка не обещает. Поэтому идём по
-- объявленному порядку предметов.
local ORDER = {
    Blocks.SCRAP, Blocks.ROPE, Blocks.CLOTH, Blocks.PLASTIC,
    Blocks.PLANK, Blocks.RAIL, Blocks.WALL, Blocks.LANTERN,
    Blocks.NET, Blocks.PURIFIER, Blocks.SAIL, Blocks.ROD,
    Blocks.FISH, Blocks.SEAWEED, Blocks.WATER,
    Blocks.BEAM, Blocks.ROOF, Blocks.MAST, Blocks.BARREL, Blocks.CRATE,
    Blocks.PLANTER,
}

function Inv.Items()
    local out = {}
    for _, id in ipairs(ORDER) do
        local n = counts[id] or 0
        if n > 0 then out[#out + 1] = {id, n} end
    end
    return out
end

-- Новая игра: трюм пуст, выбран первый слот. Отдельной функцией, а не
-- «counts = {}» по месту: counts локальна, и без неё сброс пришлось бы делать
-- перезагрузкой всей игры.
function Inv.Reset()
    counts = {}
    Inv.selected = 1
end

-- Инвентарь целиком: что и сколько лежит, плюс выбранный слот.
function Inv.Snapshot()
    local items = {}
    for id, n in pairs(counts) do
        if n > 0 then items[#items + 1] = {id, n} end
    end
    return {items = items, selected = Inv.selected}
end

function Inv.Restore(data)
    if type(data) ~= "table" then return end
    counts = {}
    for _, e in ipairs(data.items or {}) do
        if #e >= 2 then counts[e[1]] = e[2] end
    end
    if data.selected then Inv.Select(data.selected) end
end

return Inv
