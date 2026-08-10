-- ---------------------------------------------------------------------------
-- craft.lua — трюм, руки и верстак: экран, на котором видно, что у тебя есть,
-- где оно лежит и что из этого можно сделать.
--
-- ЧТО БЫЛО ДО НЕГО. Крафт делался клавишами 1…8, и каждая означала рецепт,
-- записанный только в README: «4 — фонарь: 2 обломка + 2 пластика». Игра про
-- неспешную возню с мусором требовала помнить восемь номеров наизусть и
-- сообщала о нехватке материалов лишь ПОСЛЕ нажатия — то есть единственным
-- способом узнать рецепт было попробовать.
--
-- КАК СДЕЛАНО. Как в играх про блоки: TAB освобождает мышь и показывает трюм
-- ячейками, под ним — то, что в руках (тот самый хотбар), ниже — рецепты. Вещи
-- ПЕРЕТАСКИВАЮТСЯ: нажал на ячейку — стопка «в курсоре», отпустил над другой —
-- легла туда; одинаковые складываются, разные меняются местами. Порядок в
-- инвентаре — решение игрока, и это единственный способ его принять.
--
-- Мир при этом продолжает жить: волна качает лодку, мусор плывёт мимо —
-- верстак не ставит игру на паузу, потому что в игре, из которой нельзя
-- проиграть, пауза ради крафта ничего не защищает.
--
-- Сетки раскладывает ДВИЖОК (sage.ui.SetLayout): скрипт задаёт «сетка по
-- восемь в ряд с зазором шесть» и создаёт слоты, а куда каждый встанет,
-- считает раскладка.
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"
local U = require "ui"
local Icons = require "blockicons"

local C = {}

local HOLD_COLS, HOLD_ROWS = 8, 3
local SLOT = 54
local GAP = 6
local GRID_W = HOLD_COLS * SLOT + (HOLD_COLS - 1) * GAP

local root, window
local slotViews = {}     -- номер ячейки инвентаря -> {obj, icon, count}
local recipeSlots = {}   -- {obj, icon, count, recipe}
local footer
local ghost, ghostIcon, ghostCount   -- стопка «в курсоре»
local open = false

-- Что сейчас несут в курсоре и откуда взяли. dragFrom нужен, чтобы отличить
-- ЩЕЛЧОК (взял и держу) от ПЕРЕТАСКИВАНИЯ (взял, довёл, отпустил): и то и
-- другое начинается одинаково, а кончается по-разному.
local held = nil
local dragFrom = nil

local Inv
local onMessage = function() end

-- --- Сборка -----------------------------------------------------------------
local function makeSlot(parent, index, name)
    local obj, icon, count = U.Slot(parent, name, UIAnchor.TopLeft, 0, 0, SLOT, "slot:" .. index)
    slotViews[index] = {obj = obj, icon = icon, count = count}
    return obj
end

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

    local holdTop = 74
    local holdH = HOLD_ROWS * SLOT + (HOLD_ROWS - 1) * GAP
    local handTop = holdTop + holdH + 32
    local craftTop = handTop + SLOT + 34
    local cardH = craftTop + SLOT + 56
    local cardW = GRID_W + 40

    window = U.Card(root, "Craft Window", UIAnchor.Center, 0, 0, cardW, cardH)

    local _, title = U.Label(window, "Craft Title", UIAnchor.TopLeft, 20, 16, 300, 24,
                             "Трюм и верстак", 1.7)
    title.Icon = "hammer"
    title.IconColor = U.C(U.AMBER)
    title.PadX = 4.0

    local _, hint = U.Label(window, "Craft Hint", UIAnchor.TopRight, 20, 20, 260, 20,
                            "перетаскивай мышью   ·   TAB — закрыть", 1.1)
    hint.TextColor = U.C(U.MUTED, 0.9)

    local _, holdCap = U.Label(window, "Hold Caption", UIAnchor.TopLeft, 20, 50, 300, 18,
                               "Трюм", 1.15)
    holdCap.TextColor = U.C(U.MUTED)

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
    local _, handCap = U.Label(window, "Hand Caption", UIAnchor.TopLeft, 20, handTop - 24,
                               300, 18, "В руках", 1.15)
    handCap.TextColor = U.C(U.MUTED)

    local handW = Inv.HOTBAR * SLOT + (Inv.HOTBAR - 1) * GAP
    local handBox = U.Panel(window, "Hand Grid", UIAnchor.TopLeft,
                            20 + (GRID_W - handW) * 0.5, handTop, handW, SLOT)
    sage.ui.SetLayout(handBox, {dir = "grid", columns = Inv.HOTBAR, spacing = GAP,
                                padding = 0.0, stretch = false})
    for i = 1, Inv.HOTBAR do
        makeSlot(handBox, i, "Hand Slot " .. i)
    end

    local _, craftCap = U.Label(window, "Craft Caption", UIAnchor.TopLeft, 20, craftTop - 24,
                                300, 18, "Что можно собрать", 1.15)
    craftCap.TextColor = U.C(U.MUTED)

    local recipeBox = U.Panel(window, "Recipe Grid", UIAnchor.TopLeft, 20, craftTop, GRID_W, SLOT)
    sage.ui.SetLayout(recipeBox, {dir = "grid", columns = HOLD_COLS, spacing = GAP,
                                  padding = 0.0, stretch = false})
    for i, recipe in ipairs(Inv.recipes) do
        local obj, icon, count = U.Slot(recipeBox, "Recipe " .. i, UIAnchor.TopLeft, 0, 0, SLOT,
                                        "craft:" .. recipe.id)
        U.SlotIcon(icon, recipe.give[1], Blocks, Icons)
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

    -- Стопка «в курсоре». Живёт на КОРНЕ экрана, а не в окне: её место —
    -- под мышью, а мышь ходит по всему кадру. И она не ловит мышь сама
    -- (Interactive не ставим) — иначе перетаскиваемая вещь закрывала бы собой
    -- ту ячейку, в которую её несут.
    ghost, ghostIcon, ghostCount = U.Slot(root, "Drag Ghost", UIAnchor.TopLeft, 0, 0, SLOT)
    local g = ghost:GetUI()
    g.Color = U.C(U.AMBER, 0.18)
    g.BorderColor = U.C(U.AMBER, 0.85)
    g.ShadowSize = 16.0
    g.Visible = false
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
    if not open and held then
        -- Закрыли экран, не выпустив вещь из курсора. Возвращаем её в трюм:
        -- место всегда есть — стопка только что была в одной из ячеек.
        Inv.Add(held.id, held.n)
        held, dragFrom = nil, nil
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

function C.CraftIndex(index)
    return C.CraftRecipe(Inv.recipes[index])
end

function C.CraftById(id)
    return C.CraftRecipe(Inv.FindRecipe(id))
end

-- --- Перетаскивание ----------------------------------------------------------
local function takeFrom(index)
    local s = Inv.Slot(index)
    if not s then return nil end
    local stack = {id = s.id, n = s.n}
    Inv.SetSlot(index, nil)
    return stack
end

-- Положить то, что в курсоре, в ячейку: пустая — просто ложится, такая же —
-- складывается, чужая — меняются местами.
local function putInto(index)
    if held == nil then return end
    local there = Inv.Slot(index)
    if there == nil then
        Inv.SetSlot(index, held)
        held = nil
        return
    end
    if there.id == held.id then
        local room = Inv.STACK - there.n
        local put = math.min(room, held.n)
        if put > 0 then
            Inv.SetSlot(index, {id = there.id, n = there.n + put})
            held.n = held.n - put
            if held.n <= 0 then held = nil end
        end
        return
    end
    -- Обмен: чужая стопка уезжает в курсор, наша — в ячейку.
    Inv.SetSlot(index, held)
    held = {id = there.id, n = there.n}
end

local function slotIndexOf(action)
    if action:sub(1, 5) ~= "slot:" then return nil end
    return tonumber(action:sub(6))
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

local function paintSlot(view, id, count)
    local num = view.count:GetUI()
    U.SlotIcon(view.icon, id, Blocks, Icons)
    num.Text = (id and count > 1) and tostring(count) or ""
end

function C.Update(dt)
    if not open then return end

    for index, view in pairs(slotViews) do
        paintSlot(view, Inv.SlotId(index), Inv.SlotCount(index))
        -- Ячейка «в руках» помечена тёплой рамкой и на верстаке: игрок должен
        -- видеть, куда именно ляжет вещь, которую он кладёт в хотбар.
        local e = view.obj:GetUI()
        if index == Inv.selected then
            e.BorderColor = U.C(U.AMBER, 0.9)
            e.BorderThickness = 2.0
        else
            e.BorderColor = Vec4(1, 1, 1, 0.10)
            e.BorderThickness = 1.5
        end
    end

    -- Рецепты: доступные горят, недоступные бледнеют. Это ровно та подсказка,
    -- которой не было: до неё «хватает ли на фонарь» проверялось нажатием.
    for _, slot in ipairs(recipeSlots) do
        local can = Inv.CanCraft(slot.recipe)
        local e = slot.obj:GetUI()
        local color = Blocks.Color(slot.recipe.give[1])
        local ie = slot.icon:GetUI()
        -- Недоступный рецепт гасится: у объёмной иконки — прозрачностью
        -- картинки, у плоского значка — цветом значка.
        if ie.Type == UIKind.Image then
            ie.Color = Vec4(1, 1, 1, can and 1.0 or 0.32)
        else
            ie.IconColor = Vec4(color.x, color.y, color.z, can and 1.0 or 0.30)
        end
        slot.count:GetUI().TextColor = U.C(U.TEXT, can and 0.92 or 0.35)
        e.BorderColor = can and U.C(U.AMBER, 0.55) or Vec4(1, 1, 1, 0.08)
        e.Color = can and U.C(U.AMBER, 0.10) or U.C(U.INK, 0.55)
    end

    -- --- Мышь ---------------------------------------------------------------
    --
    -- Нажатие и отпускание РАЗДЕЛЕНЫ (sage.ui.PressedAction / ReleasedAction), и
    -- это ровно то, что делает перетаскивание возможным: щелчок — нажал и
    -- отпустил на одной ячейке, перенос — на разных, а по одному «щёлкнули»
    -- их не различить.
    local pressed = sage.ui.PressedAction()
    local pressedSlot = slotIndexOf(pressed)
    if pressedSlot then
        if held == nil then
            held = takeFrom(pressedSlot)
            dragFrom = held and pressedSlot or nil
        else
            putInto(pressedSlot)
            dragFrom = nil
        end
    end

    local releasedSlot = slotIndexOf(sage.ui.ReleasedAction())
    if releasedSlot and held ~= nil and dragFrom ~= nil then
        -- Отпустили над ДРУГОЙ ячейкой — это перенос. Над той же самой —
        -- обычный щелчок: вещь остаётся в курсоре, и её кладут вторым щелчком.
        if releasedSlot ~= dragFrom then putInto(releasedSlot) end
        dragFrom = nil
    end

    -- Стопка в курсоре едет за мышью. Точку берём у движка: у окна свои
    -- координаты, у кадра свои, у холста свой масштаб — сложить их в скрипте
    -- значило бы повторить перевод, который уже сделан один раз.
    local g = ghost:GetUI()
    if held then
        local c = sage.ui.Cursor()
        g.Visible = c.x >= 0.0
        g.Offset = Vec2(c.x - SLOT * 0.5, c.y - SLOT * 0.5)
        paintSlot({icon = ghostIcon, count = ghostCount}, held.id, held.n)
    else
        g.Visible = false
    end

    -- Что под курсором. Наведение читаем у движка по ИМЕНИ действия: спрашивать
    -- у каждой из сорока ячеек «ты под курсором?» — сорок вопросов ради одного
    -- ответа.
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
    else
        local index = slotIndexOf(hovered)
        local id = index and Inv.SlotId(index)
        if id then text = Blocks.Name(id) .. " — " .. Inv.SlotCount(index) .. " шт." end
    end
    if text == nil then
        text = held and "Отпусти над ячейкой — вещь ляжет туда"
               or "Тащи вещи мышью, щёлкни по рецепту — соберётся один предмет"
    end
    local f = footer:GetUI()
    f.Text = text
    f.TextColor = color

    -- Щелчок по рецепту. Только по нему: ячейки заняты перетаскиванием.
    local clicked = sage.ui.ClickedAction()
    if clicked:sub(1, 6) == "craft:" then
        C.CraftById(clicked:sub(7))
    end
end

return C
