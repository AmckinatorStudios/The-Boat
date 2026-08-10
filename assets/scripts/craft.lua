-- ---------------------------------------------------------------------------
-- craft.lua — трюм и руки: экран, на котором видно, что у тебя есть и где оно
-- лежит.
--
-- ЧТО БЫЛО ДО НЕГО. Крафт делался клавишами 1…8, и каждая означала рецепт,
-- записанный только в README: «4 — фонарь: 2 обломка + 2 пластика». Игра про
-- неспешную возню с мусором требовала помнить восемь номеров наизусть и
-- сообщала о нехватке материалов лишь ПОСЛЕ нажатия — то есть единственным
-- способом узнать рецепт было попробовать.
--
-- КАК СДЕЛАНО. Как в играх про блоки: TAB освобождает мышь и показывает трюм
-- ячейками, под ним — то, что в руках (тот самый хотбар). Вещи
-- ПЕРЕТАСКИВАЮТСЯ: нажал на ячейку — стопка «в курсоре», отпустил над другой —
-- легла туда; одинаковые складываются, разные меняются местами. Порядок в
-- инвентаре — решение игрока, и это единственный способ его принять.
--
-- ЧТО ОТСЮДА УЕХАЛО. Полный список рецептов теперь на ВЕРСТАКЕ (stationui.lua).
-- Здесь остались только те, что делаются голыми руками, — доска и сам верстак.
-- Иначе строить верстак было бы незачем: он бы ничего не добавлял.
--
-- Мир при этом продолжает жить: волна качает лодку, мусор плывёт мимо — трюм
-- не ставит игру на паузу, потому что в игре, из которой нельзя проиграть,
-- пауза ради крафта ничего не защищает.
--
-- Сетки раскладывает ДВИЖОК (sage.ui.SetLayout): скрипт задаёт «сетка по
-- восемь в ряд с зазором шесть» и создаёт слоты, а куда каждый встанет,
-- считает раскладка. Перетаскивание — общее на все экраны игры (slots.lua).
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"
local U = require "ui"
local Icons = require "blockicons"
local Slots = require "slots"
local SUI = require "stationui"

local C = {}

local HOLD_COLS, HOLD_ROWS = 8, 3
local SLOT = 54
local GAP = 6
local GRID_W = HOLD_COLS * SLOT + (HOLD_COLS - 1) * GAP

local root, window
local slotViews = {}     -- номер ячейки инвентаря -> {obj, icon, count}
local recipeSlots = {}   -- {obj, icon, count, recipe}
local open = false

local Inv
local onMessage = function() end

-- --- Сборка -----------------------------------------------------------------
local function makeSlot(parent, index, name)
    local obj, icon, count = U.Slot(parent, name, UIAnchor.TopLeft, 0, 0, SLOT,
                                    Slots.Action("inv", index))
    slotViews[index] = {obj = obj, icon = icon, count = count}
    return obj
end

function C.Build(deps)
    Inv = deps.inventory
    onMessage = deps.onMessage or onMessage

    -- Только то, что делается руками. Остальное — на верстаке.
    local basic = {}
    for _, r in ipairs(Inv.recipes) do
        if r.basic then basic[#basic + 1] = r end
    end

    -- Экран поверх худа (order = 20), но под меню (order = 40): порядок между
    -- корнями задаёт холст, а не удача с порядком создания сущностей.
    root = U.Screen("Craft Screen", 20)
    root:GetUI().Visible = false

    -- Затемнение во весь кадр. Растяжением, а не размером в пикселях: иначе при
    -- смене разрешения окна по краям остаются светлые полосы.
    local _, dim = U.Panel(root, "Craft Dim", UIAnchor.TopLeft, 0, 0, 10, 10)
    dim.Stretch = UIStretch.Both
    dim.Color = Vec4(0.02, 0.03, 0.05, 0.70)
    dim.Rounding = 0.0

    local holdTop = 74
    local holdH = HOLD_ROWS * SLOT + (HOLD_ROWS - 1) * GAP
    local handTop = holdTop + holdH + 32
    local craftTop = handTop + SLOT + 34
    local cardH = craftTop + SLOT + 30
    local cardW = GRID_W + 40

    window = U.Card(root, "Craft Window", UIAnchor.Center, 0, 0, cardW, cardH)

    local _, title = U.Label(window, "Craft Title", UIAnchor.TopLeft, 20, 16, 300, 24,
                             "Трюм", 1.7)
    title.Icon = "crate"
    title.IconColor = U.C(U.AMBER)
    title.PadX = 4.0

    local _, hint = U.Label(window, "Craft Hint", UIAnchor.TopRight, 20, 20, 260, 20,
                            "перетаскивай мышью   ·   TAB — закрыть", 1.1)
    hint.TextColor = U.C(U.MUTED, 0.9)

    U.Caption(window, "Hold Caption", UIAnchor.TopLeft, 20, 50, 300, "Трюм")

    -- Трюм: сетка ячеек фиксированного размера. Ячейки пустуют, а не исчезают:
    -- место в инвентаре закреплено за тем, что игрок туда положил.
    local holdBox = U.Panel(window, "Hold Grid", UIAnchor.TopLeft, 20, holdTop, GRID_W, holdH)
    sage.ui.SetLayout(holdBox, {dir = "grid", columns = HOLD_COLS, spacing = GAP,
                                padding = 0.0, stretch = false})
    for k = 1, Inv.HOLD do
        makeSlot(holdBox, Inv.HOTBAR + k, "Hold " .. k)
    end

    -- Хотбар — ТЕ ЖЕ САМЫЕ ячейки, что и внизу экрана в игре, и перетаскивать
    -- между ним и трюмом можно ровно потому, что разницы между ними нет.
    U.Caption(window, "Hand Caption", UIAnchor.TopLeft, 20, handTop - 24, 300, "В руках")

    local handW = Inv.HOTBAR * SLOT + (Inv.HOTBAR - 1) * GAP
    local handBox = U.Panel(window, "Hand Grid", UIAnchor.TopLeft,
                            20 + (GRID_W - handW) * 0.5, handTop, handW, SLOT)
    sage.ui.SetLayout(handBox, {dir = "grid", columns = Inv.HOTBAR, spacing = GAP,
                                padding = 0.0, stretch = false})
    for i = 1, Inv.HOTBAR do
        makeSlot(handBox, i, "Hand Slot " .. i)
    end

    U.Caption(window, "Craft Caption", UIAnchor.TopLeft, 20, craftTop - 24, 400,
              "Голыми руками   ·   остальное — на верстаке")

    local recipeBox = U.Panel(window, "Recipe Grid", UIAnchor.TopLeft, 20, craftTop, GRID_W, SLOT)
    sage.ui.SetLayout(recipeBox, {dir = "grid", columns = HOLD_COLS, spacing = GAP,
                                  padding = 0.0, stretch = false})
    for i, recipe in ipairs(basic) do
        local obj, icon, count = U.Slot(recipeBox, "Recipe " .. i, UIAnchor.TopLeft, 0, 0, SLOT,
                                        "craft:" .. recipe.id)
        U.SlotIcon(icon, recipe.give[1], Blocks, Icons)
        count:GetUI().Text = "x" .. recipe.give[2]
        recipeSlots[i] = {obj = obj, icon = icon, count = count, recipe = recipe}
    end
end

-- --- Открыть/закрыть --------------------------------------------------------
function C.IsOpen() return open end

-- Курсор мыши этот модуль НЕ трогает, хотя на этом экране он и нужен: экранов,
-- которым нужен курсор, в игре несколько, и если каждый начнёт захватывать и
-- отпускать мышь сам, то закрытие одного поверх другого вернёт обзор посреди
-- открытого экрана. Режим ввода — один на игру, и владелец у него один (см.
-- applyCursor в game.lua).
function C.SetOpen(value)
    open = value
    if root ~= nil and root:Valid() then root:GetUI().Visible = open end
    if not open then
        -- Закрыли экран, не выпустив вещь из курсора. Возвращаем её в трюм:
        -- место всегда есть — стопка только что была в одной из ячеек.
        Slots.ReturnHeld(function(id, n) return Inv.Add(id, n) end)
        local tip = SUI.Tip()
        if tip then tip.Hide() end
    end
end

function C.Toggle() C.SetOpen(not open) end

-- --- Крафт ------------------------------------------------------------------
--
-- ОДИН путь на всех: и щелчок по ячейке, и автопилот в CI приходят сюда.
-- Раньше у автопилота был свой вызов Inv.Craft, и он проверял не то, чем
-- пользуется человек, — а значит, не проверял ничего.
function C.CraftRecipe(recipe)
    if recipe == nil then return false end
    local ok, text = Inv.Craft(recipe)
    onMessage(text, ok and 2.0 or 2.6, ok and "check" or "warn")
    return ok
end

function C.CraftById(id)
    return C.CraftRecipe(Inv.FindRecipe(id))
end

-- --- Кадр -------------------------------------------------------------------
local function paintSlot(view, id, count)
    U.SlotIcon(view.icon, id, Blocks, Icons)
    view.count:GetUI().Text = (id and count > 1) and tostring(count) or ""
end

function C.Update(dt)
    if not open then return end

    for index, view in pairs(slotViews) do
        paintSlot(view, Inv.SlotId(index), Inv.SlotCount(index))
        -- Ячейка «в руках» помечена тёплой рамкой и здесь: игрок должен видеть,
        -- куда именно ляжет вещь, которую он кладёт в хотбар.
        U.MarkSlot(view.obj:GetUI(), index == Inv.selected)
    end

    -- Рецепты: доступные горят, недоступные бледнеют. Это ровно та подсказка,
    -- которой не было: до неё «хватает ли на доску» проверялось нажатием.
    for _, slot in ipairs(recipeSlots) do
        local can = Inv.CanCraft(slot.recipe)
        local e = slot.obj:GetUI()
        local ie = slot.icon:GetUI()
        -- Недоступный рецепт гасится: у объёмной иконки — прозрачностью
        -- картинки, у плоского значка — цветом значка.
        if ie.Type == UIKind.Image then
            ie.Color = Vec4(1, 1, 1, can and 1.0 or 0.32)
        else
            local color = Blocks.Color(slot.recipe.give[1])
            ie.IconColor = Vec4(color.x, color.y, color.z, can and 1.0 or 0.30)
        end
        slot.count:GetUI().TextColor = U.C(U.TEXT, can and 0.92 or 0.35)
        e.BorderColor = can and U.C(U.AMBER, 0.55) or U.C(U.LINE, 0.5)
        e.Color = can and U.C(U.AMBER, 0.10) or U.C(U.SURFACE, 0.95)
    end

    -- Мышь: перетаскивание и стопка в курсоре — общий модуль (slots.lua). Он же
    -- возвращает, что сейчас под курсором, — спрашивать это у движка второй раз
    -- значит получить два ответа на один вопрос.
    local hovered = Slots.Update()

    local tip = SUI.Tip()
    if tip then
        local title, note, color = nil, nil, nil
        if hovered:sub(1, 6) == "craft:" then
            local recipe = Inv.FindRecipe(hovered:sub(7))
            if recipe then
                local parts = {}
                for _, c in ipairs(recipe.cost) do
                    parts[#parts + 1] = Blocks.Name(c[1]) .. " x" .. c[2]
                end
                title = recipe.name .. "   x" .. recipe.give[2]
                note = "из: " .. table.concat(parts, " + ")
                local missing = Inv.Missing(recipe)
                if missing then
                    note = note .. "   —  не хватает: " .. missing
                    color = U.C(U.ALARM)
                else
                    color = U.C(U.GOOD)
                end
            end
        else
            local index = hovered:match("^inv:(%d+)$")
            local stack = index and Inv.Slot(tonumber(index)) or nil
            if stack then title, note = SUI.DescribeItem(stack.id, stack.n) end
        end
        if title then tip.Show(title, note, color) else tip.Hide() end
    end

    -- Щелчок по рецепту. Только по нему: ячейки заняты перетаскиванием.
    local clicked = sage.ui.ClickedAction()
    if clicked:sub(1, 6) == "craft:" then
        C.CraftById(clicked:sub(7))
    end
end

return C
