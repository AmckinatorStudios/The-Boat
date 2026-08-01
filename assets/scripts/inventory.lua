-- ---------------------------------------------------------------------------
-- inventory.lua — что игрок несёт в руках и во что это можно переделать.
--
-- Инвентарь намеренно плоский: «id блока -> сколько штук». Отдельных предметов
-- (не-блоков) в игре нет — ягоды это куст, парус это блок паруса, — и пока это
-- так, любая более богатая модель была бы обобщением ради обобщения.
--
-- Крафт описан данными, а не кодом: рецепт — это «что тратим» и «что даём».
-- Добавить рецепт значит дописать строку в таблицу, а не ветку в функцию.
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"

local Inv = {}

local counts = {}

-- Хотбар: что можно поставить/съесть, в порядке слотов.
Inv.hotbar = {
    Blocks.PLANK, Blocks.LOG, Blocks.SAIL,
    Blocks.SAND, Blocks.STONE, Blocks.CAMPFIRE,
}
Inv.selected = 1

Inv.recipes = {
    {
        id = "planks", name = "Доски", key = "Craft Planks",
        cost = {{Blocks.LOG, 1}}, give = {Blocks.PLANK, 4},
    },
    {
        id = "sail", name = "Парус", key = "Craft Sail",
        cost = {{Blocks.LEAVES, 4}}, give = {Blocks.SAIL, 1},
    },
    {
        id = "campfire", name = "Костёр", key = "Craft Campfire",
        cost = {{Blocks.PLANK, 2}, {Blocks.STONE, 1}}, give = {Blocks.CAMPFIRE, 1},
    },
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

function Inv.Total()
    local sum = 0
    for _, n in pairs(counts) do sum = sum + n end
    return sum
end

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

-- Возвращает true и рецепт при успехе, иначе false и причину — вызывающий сам
-- решает, показать это сообщением на HUD или промолчать.
function Inv.Craft(recipe)
    if not Inv.CanCraft(recipe) then
        local missing = {}
        for _, c in ipairs(recipe.cost) do
            local lack = c[2] - Inv.Count(c[1])
            if lack > 0 then missing[#missing + 1] = Blocks.Name(c[1]) .. " x" .. lack end
        end
        return false, "Не хватает: " .. table.concat(missing, ", ")
    end
    for _, c in ipairs(recipe.cost) do Inv.Remove(c[1], c[2]) end
    Inv.Add(recipe.give[1], recipe.give[2])
    return true, recipe.name .. " x" .. recipe.give[2]
end

-- Еда: ягоды с кустов. Возвращает true, если было что съесть.
function Inv.EatBerries()
    return Inv.Remove(Blocks.BUSH, 1)
end

function Inv.Reset()
    counts = {}
    Inv.selected = 1
end

return Inv
