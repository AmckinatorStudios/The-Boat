-- ---------------------------------------------------------------------------
-- craft.lua — трюм и верстак: экран, на котором видно, что у тебя есть и что из
-- этого можно сделать.
--
-- ЧТО БЫЛО ДО НЕГО. Крафт делался клавишами 1…8, и каждая означала рецепт,
-- записанный только в README: «4 — фонарь: 2 обломка + 2 пластика». Игра про
-- неспешную возню с мусором требовала помнить восемь номеров наизусть и
-- сообщала о нехватке материалов лишь ПОСЛЕ нажатия — то есть единственным
-- способом узнать рецепт было попробовать. Ни увидеть, что лежит в трюме
-- (кроме трёх счётчиков в углу), ни понять, чего не хватает до фонаря, было
-- нельзя.
--
-- КАК СДЕЛАНО. Как в играх про блоки: экран открывается по TAB, мышь
-- освобождается, наверху — трюм ячейками, ниже — рецепты ячейками, под ними
-- строка про тот рецепт, на который сейчас смотришь: из чего он и чего для
-- него не хватает. Щелчок по рецепту делает предмет. Мир при этом продолжает
-- жить: волна качает лодку, мусор плывёт мимо — верстак не ставит игру на
-- паузу, потому что в игре, из которой нельзя проиграть, пауза ради крафта
-- ничего не защищает.
--
-- Сетки раскладывает ДВИЖОК (sage.ui.SetLayout): скрипт задаёт «сетка по
-- восемь в ряд с зазором шесть» и создаёт слоты, а куда каждый встанет,
-- считает раскладка. Раньше эта арифметика жила в скрипте и повторялась в
-- каждом месте, где есть ряд одинаковых ячеек.
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"
local U = require "ui"

local C = {}

local HOLD_COLS, HOLD_ROWS = 8, 3
local SLOT = 54
local GAP = 6
local GRID_W = HOLD_COLS * SLOT + (HOLD_COLS - 1) * GAP

local root, window
local holdSlots = {}     -- {obj, icon, count}
local recipeSlots = {}   -- {obj, icon, count, recipe}
local footer
local open = false

local Inv
local onMessage = function() end

-- --- Сборка -----------------------------------------------------------------
function C.Build(deps)
    Inv = deps.inventory
    onMessage = deps.onMessage or onMessage

    -- Экран поверх худа (order = 20), но под меню (order = 40): порядок между
    -- корнями задаёт холст, а не удача с порядком создания сущностей.
    root = U.Screen("Craft Screen", 20)
    root:GetUI().Visible = false

    -- Затемнение во весь кадр. Растяжением, а не размером в пикселях: иначе при
    -- смене разрешения окна по краям остаются светлые полосы.
    local _, dim = U.Panel(root, "Craft Dim", UIAnchor.TopLeft, 0, 0, 10, 10)
    dim.Stretch = UIStretch.Both
    dim.Color = Vec4(0.02, 0.03, 0.06, 0.62)
    dim.Rounding = 0.0

    local cardH = 424
    local cardW = GRID_W + 40
    window = U.Card(root, "Craft Window", UIAnchor.Center, 0, 0, cardW, cardH)

    local _, title = U.Label(window, "Craft Title", UIAnchor.TopLeft, 20, 16, 300, 24,
                             "Трюм и верстак", 1.7)
    title.Icon = "hammer"
    title.IconColor = U.C(U.AMBER)
    title.PadX = 4.0

    local _, hint = U.Label(window, "Craft Hint", UIAnchor.TopRight, 20, 20, 220, 20,
                            "TAB — закрыть", 1.1)
    hint.TextColor = U.C(U.MUTED, 0.9)

    local _, holdCap = U.Label(window, "Hold Caption", UIAnchor.TopLeft, 20, 50, 300, 18,
                               "Что в трюме", 1.15)
    holdCap.TextColor = U.C(U.MUTED)

    -- Трюм: сетка ячеек фиксированного размера. Ячейки пустуют, а не исчезают:
    -- предмет, которого стало ноль, не должен утаскивать за собой соседей на
    -- новые места — иначе каждый подобранный обломок перетасовывает весь трюм.
    local holdBox = U.Panel(window, "Hold Grid", UIAnchor.TopLeft, 20, 74,
                            GRID_W, HOLD_ROWS * SLOT + (HOLD_ROWS - 1) * GAP)
    sage.ui.SetLayout(holdBox, {dir = "grid", columns = HOLD_COLS, spacing = GAP,
                                padding = 0.0, stretch = false})
    for i = 1, HOLD_COLS * HOLD_ROWS do
        local obj, icon, count = U.Slot(holdBox, "Hold " .. i, UIAnchor.TopLeft, 0, 0, SLOT,
                                        "hold:" .. i)
        holdSlots[i] = {obj = obj, icon = icon, count = count}
    end

    local recipesTop = 74 + HOLD_ROWS * SLOT + (HOLD_ROWS - 1) * GAP + 22
    local _, craftCap = U.Label(window, "Craft Caption", UIAnchor.TopLeft, 20, recipesTop - 22,
                                300, 18, "Что можно собрать", 1.15)
    craftCap.TextColor = U.C(U.MUTED)

    local recipeBox = U.Panel(window, "Recipe Grid", UIAnchor.TopLeft, 20, recipesTop,
                              GRID_W, SLOT)
    sage.ui.SetLayout(recipeBox, {dir = "grid", columns = HOLD_COLS, spacing = GAP,
                                  padding = 0.0, stretch = false})
    for i, recipe in ipairs(Inv.recipes) do
        local obj, icon, count = U.Slot(recipeBox, "Recipe " .. i, UIAnchor.TopLeft, 0, 0, SLOT,
                                        "craft:" .. recipe.id)
        icon:GetUI().Icon = Blocks.Icon(recipe.give[1])
        count:GetUI().Text = "x" .. recipe.give[2]
        recipeSlots[i] = {obj = obj, icon = icon, count = count, recipe = recipe}
    end

    -- Строка под сеткой: из чего рецепт и чего не хватает. Одна на все восемь,
    -- а не подпись под каждым: восемь описаний одновременно — это стена текста,
    -- а нужно всегда одно — про то, на что смотришь.
    local footerObj, footerE = U.Label(window, "Craft Footer", UIAnchor.BottomLeft, 20, 16,
                                       GRID_W, 22, "", 1.25)
    footerE.PadX = 4.0
    footer = footerObj
end

-- --- Открыть/закрыть --------------------------------------------------------
function C.IsOpen() return open end

-- Курсор мыши этот модуль НЕ трогает, хотя на верстаке он и нужен: экранов,
-- которым нужен курсор, в игре два (верстак и меню), и если каждый начнёт
-- захватывать и отпускать мышь сам, то закрытие одного поверх другого вернёт
-- обзор посреди открытого экрана. Режим ввода — один на игру, и владелец у
-- него один (см. applyCursor в game.lua).
function C.SetOpen(value)
    open = value
    if root ~= nil and root:Valid() then root:GetUI().Visible = open end
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

function C.CraftIndex(index)
    return C.CraftRecipe(Inv.recipes[index])
end

function C.CraftById(id)
    return C.CraftRecipe(Inv.FindRecipe(id))
end

-- --- Кадр -------------------------------------------------------------------
local function describe(recipe)
    local parts = {}
    for _, c in ipairs(recipe.cost) do
        parts[#parts + 1] = Blocks.Name(c[1]) .. " x" .. c[2]
    end
    -- Стрелка «←» в шрифте игры отсутствует и рисуется пустым местом: список
    -- глифов в атласе не резиновый, и вместо охоты за символом проще написать
    -- словом.
    return recipe.name .. " ×" .. recipe.give[2] .. "   из:  " .. table.concat(parts, " + ")
end

function C.Update(dt)
    if not open then return end

    -- Трюм: сколько чего лежит.
    local items = Inv.Items()
    for i, slot in ipairs(holdSlots) do
        local entry = items[i]
        local icon, count = slot.icon:GetUI(), slot.count:GetUI()
        if entry then
            local color = Blocks.Color(entry[1])
            icon.Icon = Blocks.Icon(entry[1])
            icon.IconColor = Vec4(color.x, color.y, color.z, 1.0)
            count.Text = tostring(entry[2])
        else
            -- Пустая ячейка — пустая, а не «предмет с нулём»: ноль в углу
            -- ячейки читается как «есть, но кончился», чего в трюме не бывает.
            icon.Icon = ""
            count.Text = ""
        end
    end

    -- Рецепты: доступные горят, недоступные бледнеют. Это ровно та подсказка,
    -- которой не было: до неё «хватает ли на фонарь» проверялось нажатием.
    for _, slot in ipairs(recipeSlots) do
        local can = Inv.CanCraft(slot.recipe)
        local e = slot.obj:GetUI()
        local color = Blocks.Color(slot.recipe.give[1])
        slot.icon:GetUI().IconColor = Vec4(color.x, color.y, color.z, can and 1.0 or 0.30)
        slot.count:GetUI().TextColor = U.C(U.TEXT, can and 0.92 or 0.35)
        e.BorderColor = can and U.C(U.AMBER, 0.55) or Vec4(1, 1, 1, 0.08)
        e.Color = can and U.C(U.AMBER, 0.10) or U.C(U.INK, 0.55)
    end

    -- Что под курсором. Наведение читаем у движка по ИМЕНИ действия: спрашивать
    -- у каждой из тридцати с лишним ячеек «ты под курсором?» — тридцать
    -- вопросов ради одного ответа.
    local hovered = sage.ui.HoveredAction()
    local text, color = nil, U.C(U.MUTED, 0.95)
    if hovered:sub(1, 6) == "craft:" then
        local recipe = Inv.FindRecipe(hovered:sub(7))
        if recipe then
            text = describe(recipe)
            local missing = Inv.Missing(recipe)
            if missing then
                text = text .. "   —  не хватает: " .. missing
                color = U.C(U.ALARM, 0.95)
            else
                color = U.C(U.GOOD, 0.95)
            end
        end
    elseif hovered:sub(1, 5) == "hold:" then
        local entry = items[tonumber(hovered:sub(6)) or 0]
        if entry then text = Blocks.Name(entry[1]) .. " — " .. entry[2] .. " шт." end
    end
    if text == nil then
        text = "Наведи на ячейку, щёлкни по рецепту — соберётся один предмет"
    end
    local f = footer:GetUI()
    f.Text = text
    f.TextColor = color

    -- Щелчок. Только по рецепту: трюм тут показывают, а не перекладывают —
    -- раскладывать доски по ячейкам в игре про уют незачем.
    local clicked = sage.ui.ClickedAction()
    if clicked:sub(1, 6) == "craft:" then
        C.CraftById(clicked:sub(7))
    end
end

return C
