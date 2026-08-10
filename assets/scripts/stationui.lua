-- ---------------------------------------------------------------------------
-- stationui.lua — экраны рабочих мест: печка, верстак, сундук.
--
-- Три экрана в одном файле, потому что они собраны из одних и тех же частей:
-- карточка, сетка ячеек, панель инвентаря снизу, подсказка под курсором. Разное
-- у них только верхнее поле — три ячейки со шкалой у печки, сетка рецептов у
-- верстака, двадцать семь мест у сундука.
--
-- ИНВЕНТАРЬ ВНИЗУ КАЖДОГО. Не «чтобы было как в майнкрафте»: вещи надо
-- перекладывать МЕЖДУ инвентарём и рабочим местом, а перетаскивать можно
-- только между тем, что видно одновременно. Экран сундука без инвентаря — это
-- список того, что в сундуке лежит, и ничего больше.
--
-- Открыт всегда ОДИН экран: держать открытыми сундук и печку сразу незачем, а
-- один экран означает один владелец курсора и одно место, куда возвращается
-- вещь при закрытии.
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"
local U = require "ui"
local Icons = require "blockicons"
local Slots = require "slots"
local St = require "stations"

local SUI = {}

local SLOT = 50
local GAP = 5
local INV_COLS = 9

local Inv
local onMessage = function() end

-- Открытое место: {kind, x, y, z, state}. nil — все экраны закрыты.
local open = nil

-- Собранные экраны. Строятся ОДИН РАЗ при старте, а не по открытию: сборка
-- экрана — это десятки сущностей сцены, и делать её в момент нажатия E значит
-- ронять кадр ровно в тот момент, когда игрок чего-то ждёт.
local screens = {}
local tipRoot
local tooltip

-- --- Общие части --------------------------------------------------------------

local function paintSlot(iconObj, countObj, id, n)
    U.SlotIcon(iconObj, id, Blocks, Icons)
    if countObj then
        countObj:GetUI().Text = (id and n and n > 1) and tostring(n) or ""
    end
end

-- Сетка ячеек. Раскладывает ДВИЖОК (sage.ui.SetLayout): скрипт говорит «по
-- столько в ряд с таким зазором», а куда встанет каждая — считает раскладка.
local function grid(parent, name, x, y, cols, count, prefix, firstIndex)
    local rows = math.ceil(count / cols)
    local w = cols * SLOT + (cols - 1) * GAP
    local h = rows * SLOT + (rows - 1) * GAP
    local box = U.Panel(parent, name, UIAnchor.TopLeft, x, y, w, h)
    sage.ui.SetLayout(box, {dir = "grid", columns = cols, spacing = GAP,
                            padding = 0.0, stretch = false})
    local views = {}
    for i = 1, count do
        local index = (firstIndex or 1) + i - 1
        local obj, icon, cnt = U.Slot(box, name .. " " .. i, UIAnchor.TopLeft, 0, 0, SLOT,
                                      Slots.Action(prefix, index))
        views[index] = {obj = obj, icon = icon, count = cnt}
    end
    return views, w, h
end

-- Панель инвентаря игрока: трюм сеткой и хотбар отдельной строкой под ним.
-- Одна и та же во всех трёх экранах — и это те же самые ячейки, что в игре,
-- поэтому перетаскивание между рабочим местом и рукой ничего особенного не
-- требует.
local function inventoryPanel(card, y)
    U.Caption(card, "Inv Caption", UIAnchor.TopLeft, 20, y - 20, 300, "Трюм")
    local hold = grid(card, "Inv Hold", 20, y, INV_COLS, Inv.HOLD, "inv", Inv.HOTBAR + 1)
    local rows = math.ceil(Inv.HOLD / INV_COLS)
    local holdH = rows * SLOT + (rows - 1) * GAP

    local handY = y + holdH + 14
    local hand = grid(card, "Inv Hand", 20, handY, Inv.HOTBAR, Inv.HOTBAR, "inv", 1)

    local views = {}
    for k, v in pairs(hold) do views[k] = v end
    for k, v in pairs(hand) do views[k] = v end
    return views, handY + SLOT
end

local function invGridWidth() return INV_COLS * SLOT + (INV_COLS - 1) * GAP end

-- Подложка экрана: затемнение во весь кадр и карточка по центру.
local function makeScreen(name, order, cardW, cardH, title, icon)
    local root = U.Screen(name, order)
    root:GetUI().Visible = false

    local _, dim = U.Panel(root, name .. " Dim", UIAnchor.TopLeft, 0, 0, 10, 10)
    dim.Stretch = UIStretch.Both
    dim.Color = Vec4(0.02, 0.03, 0.05, 0.70)
    dim.Rounding = 0.0

    local card = U.Card(root, name .. " Card", UIAnchor.Center, 0, 0, cardW, cardH)
    local _, cap = U.Label(card, name .. " Title", UIAnchor.TopLeft, 20, 16, 320, 24, title, 1.7)
    cap.Icon = icon
    cap.IconColor = U.C(U.AMBER)
    cap.PadX = 4.0

    local _, hint = U.Label(card, name .. " Hint", UIAnchor.TopRight, 20, 20, 240, 20,
                            "перетаскивай мышью   ·   ESC — закрыть", 1.1)
    hint.TextColor = U.C(U.MUTED, 0.9)
    hint.TextCentered = false

    return root, card
end

-- --- Печка ---------------------------------------------------------------------
--
-- Три ячейки в столбик и шкала между ними — раскладка из игр про блоки, и она
-- здесь не подражание: сверху то, что кладут, снизу топливо, сбоку результат, и
-- стрелка между ними показывает, куда всё едет. По одной картинке видно, что
-- печка делает, без единого слова.
local function buildFurnace()
    -- Столбик «что жарим — огонь — топливо» слева, результат справа, между ними
    -- шкала. Все координаты считаются ОТ него, а не подобраны: стоило один раз
    -- поставить инвентарь на глазок, и подпись «Трюм» легла поверх ячейки
    -- топлива.
    local left, top = 20, 58
    local inputY = top
    local flameY = top + SLOT + 5
    local fuelY = flameY + 20
    local middle = (inputY + fuelY + SLOT) * 0.5   -- середина столбика
    local invY = fuelY + SLOT + 46

    local cardW = invGridWidth() + 40
    local rows = math.ceil(Inv.HOLD / INV_COLS)
    local cardH = invY + rows * SLOT + (rows - 1) * GAP + 14 + SLOT + 26

    local root, card = makeScreen("Furnace Screen", 22, cardW, cardH, "Печка", "flame")

    local inputObj, inputIcon, inputCount =
        U.Slot(card, "Furnace Input", UIAnchor.TopLeft, left, inputY, SLOT,
               Slots.Action("furnace", "input"))
    local fuelObj, fuelIcon, fuelCount =
        U.Slot(card, "Furnace Fuel", UIAnchor.TopLeft, left, fuelY, SLOT,
               Slots.Action("furnace", "fuel"))

    -- Огонёк между ячейками: он и есть ответ на вопрос «горит ли». Яркостью, а
    -- не шкалой: шкала движка заполняется слева направо, а огонь между двумя
    -- ячейками стоит вертикально, и горизонтальная полоска на его месте
    -- читалась бы как что угодно, только не как огонь.
    local _, flame = U.Icon(card, "Furnace Flame", UIAnchor.TopLeft,
                            left + SLOT * 0.5 - 8, flameY, 16, "flame",
                            U.C({1.0, 0.62, 0.25}, 0.0))

    -- Шкала плавки: горизонтальная стрелка вправо, к результату.
    local _, arrow = U.Bar(card, "Furnace Progress", UIAnchor.TopLeft,
                           left + SLOT + 20, middle - 5, 86, 10, U.C(U.AMBER))
    arrow.Value = 0.0

    local outObj, outIcon, outCount =
        U.Slot(card, "Furnace Output", UIAnchor.TopLeft, left + SLOT + 126, middle - SLOT * 0.5,
               SLOT, Slots.Action("furnace", "output"))

    U.Caption(card, "Furnace In Cap", UIAnchor.TopLeft, left + SLOT + 12, inputY + 4, 200,
              "что жарим")
    U.Caption(card, "Furnace Fuel Cap", UIAnchor.TopLeft, left + SLOT + 12, fuelY + SLOT - 22,
              200, "топливо")
    U.Caption(card, "Furnace Out Cap", UIAnchor.TopLeft, left + SLOT + 126, middle + SLOT * 0.5 + 6,
              200, "готово")

    local _, note = U.Label(card, "Furnace Note", UIAnchor.TopLeft, left + SLOT + 220, inputY + 4,
                            340, 18, "", 1.15)
    note.TextColor = U.C(U.MUTED)

    local invViews = inventoryPanel(card, invY)

    screens.furnace = {
        root = root,
        views = {input = {obj = inputObj, icon = inputIcon, count = inputCount},
                 fuel = {obj = fuelObj, icon = fuelIcon, count = fuelCount},
                 output = {obj = outObj, icon = outIcon, count = outCount}},
        inv = invViews, flame = flame, arrow = arrow, note = note,
    }
end

-- --- Сундук ---------------------------------------------------------------------
local function buildChest()
    local chestRows = math.ceil(St.CHEST_SLOTS / INV_COLS)
    local chestH = chestRows * SLOT + (chestRows - 1) * GAP
    local invY = 72 + chestH + 40
    local cardW = invGridWidth() + 40
    local rows = math.ceil(Inv.HOLD / INV_COLS)
    local cardH = invY + rows * SLOT + (rows - 1) * GAP + 14 + SLOT + 30

    local root, card = makeScreen("Chest Screen", 23, cardW, cardH, "Сундук", "crate")
    U.Caption(card, "Chest Caption", UIAnchor.TopLeft, 20, 52, 300, "В сундуке")
    local views = grid(card, "Chest Grid", 20, 72, INV_COLS, St.CHEST_SLOTS, "chest", 1)
    local invViews = inventoryPanel(card, invY)

    screens.chest = {root = root, views = views, inv = invViews}
end

-- --- Верстак ----------------------------------------------------------------------
--
-- Тот же список рецептов, что раньше висел в трюме, но теперь у него есть
-- место. В трюме остались только самые простые рецепты (см. craft.lua): всё
-- остальное собирают здесь — за это верстак и строят.
local function buildBench()
    local recipes = {}
    for _, r in ipairs(Inv.recipes) do
        if not r.basic then recipes[#recipes + 1] = r end
    end

    local cols = INV_COLS
    local rrows = math.max(1, math.ceil(#recipes / cols))
    local recipesH = rrows * SLOT + (rrows - 1) * GAP
    local invY = 72 + recipesH + 46
    local cardW = invGridWidth() + 40
    local rows = math.ceil(Inv.HOLD / INV_COLS)
    local cardH = invY + rows * SLOT + (rows - 1) * GAP + 14 + SLOT + 30

    local root, card = makeScreen("Bench Screen", 24, cardW, cardH, "Верстак", "hammer")
    U.Caption(card, "Bench Caption", UIAnchor.TopLeft, 20, 52, 300, "Что можно собрать")

    local box = U.Panel(card, "Bench Grid", UIAnchor.TopLeft, 20, 72,
                        cols * SLOT + (cols - 1) * GAP, recipesH)
    sage.ui.SetLayout(box, {dir = "grid", columns = cols, spacing = GAP,
                            padding = 0.0, stretch = false})

    local slots = {}
    for i, recipe in ipairs(recipes) do
        local obj, icon, count = U.Slot(box, "Bench Recipe " .. i, UIAnchor.TopLeft, 0, 0, SLOT,
                                        "craft:" .. recipe.id)
        U.SlotIcon(icon, recipe.give[1], Blocks, Icons)
        count:GetUI().Text = "x" .. recipe.give[2]
        slots[i] = {obj = obj, icon = icon, count = count, recipe = recipe}
    end

    local invViews = inventoryPanel(card, invY)
    screens.bench = {root = root, recipes = slots, inv = invViews}
end

-- --- Сборка -----------------------------------------------------------------------
function SUI.Build(deps)
    Inv = deps.inventory
    onMessage = deps.onMessage or onMessage

    -- Пространства ячеек. Инвентарь общий на все экраны: он один, и «положить
    -- рыбу из трюма в печку» это перенос между двумя пространствами, а не
    -- особый случай.
    Slots.Space("inv",
        function(i) return Inv.Slot(tonumber(i)) end,
        function(i, s) Inv.SetSlot(tonumber(i), s) end)

    Slots.Space("chest",
        function(i)
            if open == nil or open.kind ~= "chest" then return nil end
            return St.ChestSlot(open.state, tonumber(i))
        end,
        function(i, s)
            if open == nil or open.kind ~= "chest" then return end
            St.SetChestSlot(open.state, tonumber(i), s)
        end)

    Slots.Space("furnace",
        function(field)
            if open == nil or open.kind ~= "furnace" then return nil end
            return open.state[field]
        end,
        function(field, s)
            if open == nil or open.kind ~= "furnace" then return end
            -- В ячейку топлива кладут только то, что горит, а в ячейку
            -- результата не кладут вовсе: она отдаёт, а не принимает. Без этого
            -- печку можно было бы «заправить» рыбой и получить непонятно что.
            if field == "fuel" and s and Blocks.Fuel(s.id) == nil then return end
            if field == "output" and s ~= nil then return end
            open.state[field] = s and {id = s.id, n = s.n} or nil
        end)

    buildFurnace()
    buildChest()
    buildBench()

    -- Подсказка живёт на СВОЁМ корне поверх всех экранов. На корне сундука она
    -- была бы видна только в сундуке — а спрашивают «что это?» одинаково во
    -- всех трёх местах, да и в трюме тоже (см. SUI.Tip).
    tipRoot = U.Screen("Tooltip Layer", 50)
    tooltip = U.Tooltip(tipRoot, "Item Tooltip")
end

-- --- Открыть/закрыть ----------------------------------------------------------------
function SUI.IsOpen() return open ~= nil end
function SUI.Kind() return open and open.kind or nil end

function SUI.Open(kind, x, y, z)
    if screens[kind] == nil then return false end
    SUI.Close()
    open = {kind = kind, x = x, y = y, z = z, state = St.At(x, y, z, kind)}
    screens[kind].root:GetUI().Visible = true
    return true
end

function SUI.Close()
    if open == nil then return end
    -- Вещь из курсора возвращается в трюм: рабочее место могли закрыть потому,
    -- что его ломают, и класть её обратно туда было бы возвратом в никуда.
    Slots.ReturnHeld(function(id, n) return Inv.Add(id, n) end)
    screens[open.kind].root:GetUI().Visible = false
    if tooltip then tooltip.Hide() end
    open = nil
end

-- --- Подсказка ------------------------------------------------------------------------
--
-- Что игрок сейчас видит под мышью, словами. Значок отвечает «это что-то
-- съедобное», а сколько в нём сытости и годится ли оно в печку — нет.
local function describeItem(id, n)
    if id == nil then return nil end
    local parts = {}
    local food = Blocks.Food(id)
    local drink = Blocks.Drink(id)
    local fuel = Blocks.Fuel(id)
    local hard = Blocks.Hardness(id)
    if food then parts[#parts + 1] = string.format("сытость +%d", math.floor(food)) end
    if drink then parts[#parts + 1] = string.format("жажда +%d", math.floor(drink)) end
    if fuel then parts[#parts + 1] = string.format("горит %d с", math.floor(fuel)) end
    if St.smelting[id] then
        parts[#parts + 1] = "в печке -> " .. Blocks.Name(St.smelting[id].give)
    end
    if Blocks.IsPlaceable(id) and hard then parts[#parts + 1] = "ставится на палубу" end

    local about = Blocks.About(id)
    local note = about
    if #parts > 0 then
        note = about and (about .. "   ·   " .. table.concat(parts, "   ·   "))
               or table.concat(parts, "   ·   ")
    end
    local title = Blocks.Name(id)
    if n and n > 1 then title = title .. "   x" .. n end
    return title, note
end

SUI.DescribeItem = describeItem

-- Та же плашка для трюма (craft.lua): подсказка в игре одна, и заводить вторую
-- значило бы получить два разных ответа на один вопрос.
function SUI.Tip() return tooltip end

-- --- Кадр --------------------------------------------------------------------------
local function paintViews(views, getStack)
    for index, view in pairs(views) do
        local s = getStack(index)
        paintSlot(view.icon, view.count, s and s.id or nil, s and s.n or nil)
    end
end

function SUI.Update(dt)
    if open == nil then return end
    local screen = screens[open.kind]
    local state = open.state

    paintViews(screen.inv, function(i) return Inv.Slot(i) end)
    for index, view in pairs(screen.inv) do
        U.MarkSlot(view.obj:GetUI(), index == Inv.selected)
    end

    if open.kind == "furnace" then
        for field, view in pairs(screen.views) do
            local s = state[field]
            paintSlot(view.icon, view.count, s and s.id or nil, s and s.n or nil)
        end
        local left = state.burnMax > 0.0 and (state.burn / state.burnMax) or 0.0
        screen.flame.IconColor = Vec4(1.0, 0.62, 0.25, 0.15 + 0.85 * left)
        screen.arrow.Value = math.min(1.0, state.progress / St.SMELT_TIME)

        -- Строка о том, чего печке не хватает. Печка, которая просто не
        -- работает, — самое частое «игра сломалась»: причин ровно три, и
        -- назвать их дешевле, чем заставлять угадывать.
        local recipe = state.input and St.smelting[state.input.id] or nil
        local text
        if state.input == nil then text = "Положи сверху то, что жарим или плавим."
        elseif recipe == nil then text = Blocks.Name(state.input.id) .. " в печке ни во что не превращается."
        elseif state.burn <= 0.0 and state.fuel == nil then text = "Нужно топливо: доски, обломки, уголь."
        elseif state.burn > 0.0 then text = "Горит."
        else text = "Топливо кончилось." end
        screen.note.Text = text

    elseif open.kind == "chest" then
        paintViews(screen.views, function(i) return St.ChestSlot(state, i) end)

    elseif open.kind == "bench" then
        for _, slot in ipairs(screen.recipes) do
            local can = Inv.CanCraft(slot.recipe)
            local e = slot.obj:GetUI()
            local ie = slot.icon:GetUI()
            if ie.Type == UIKind.Image then
                ie.Color = Vec4(1, 1, 1, can and 1.0 or 0.32)
            else
                local c = Blocks.Color(slot.recipe.give[1])
                ie.IconColor = Vec4(c.x, c.y, c.z, can and 1.0 or 0.30)
            end
            slot.count:GetUI().TextColor = U.C(U.TEXT, can and 0.92 or 0.35)
            e.BorderColor = can and U.C(U.AMBER, 0.55) or U.C(U.LINE, 0.5)
            e.Color = can and U.C(U.AMBER, 0.10) or U.C(U.SURFACE, 0.95)
        end
    end

    local hovered = Slots.Update()

    local title, note, color = nil, nil, nil
    if hovered:sub(1, 6) == "craft:" then
        local recipe = Inv.FindRecipe(hovered:sub(7))
        if recipe then
            local parts = {}
            for _, c in ipairs(recipe.cost) do
                parts[#parts + 1] = Blocks.Name(c[1]) .. " x" .. c[2]
            end
            title = recipe.name .. "   x" .. recipe.give[2]
            local missing = Inv.Missing(recipe)
            note = "из: " .. table.concat(parts, " + ")
            if missing then
                note = note .. "   —  не хватает: " .. missing
                color = U.C(U.ALARM)
            else
                color = U.C(U.GOOD)
            end
        end
    else
        local prefix, index = hovered:match("^([%a]+):(.+)$")
        local stack
        if prefix == "inv" then stack = Inv.Slot(tonumber(index))
        elseif prefix == "chest" and open.kind == "chest" then
            stack = St.ChestSlot(state, tonumber(index))
        elseif prefix == "furnace" and open.kind == "furnace" then
            stack = state[index]
        end
        if stack then title, note = describeItem(stack.id, stack.n) end
    end

    if title then
        tooltip.Show(title, note, color)
    else
        tooltip.Hide()
    end

    local clicked = sage.ui.ClickedAction()
    if clicked:sub(1, 6) == "craft:" then
        local recipe = Inv.FindRecipe(clicked:sub(7))
        if recipe then
            local ok, text = Inv.Craft(recipe)
            onMessage(text, ok and 2.0 or 2.6, ok and "check" or "warn")
        end
    end
end

return SUI
