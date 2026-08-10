-- ---------------------------------------------------------------------------
-- stations.lua — рабочие места на палубе: печка, верстак, сундук.
--
-- ЧТО ЭТО МЕНЯЕТ В ИГРЕ. До этого весь крафт жил в одном экране по TAB, и
-- «собрать» значило нажать на рецепт из воздуха. Теперь у дела есть МЕСТО:
-- верстак надо построить и подойти к нему, печку — построить, растопить и
-- дождаться, сундук — поставить туда, где ты хочешь держать вещи. Ровно как в
-- играх про блоки, и ровно по той же причине: место превращает список действий
-- в обжитую палубу.
--
-- ЧТО ЗДЕСЬ ЛЕЖИТ. Только СОСТОЯНИЕ и ПРАВИЛА: что в печке лежит, сколько ей
-- гореть, что во что переплавляется, что в сундуке. Экраны — в stationui.lua:
-- печка обязана топиться и с закрытым экраном, а значит логика не может жить
-- внутри интерфейса.
--
-- ГДЕ ЭТО ЖИВЁТ. Состояние привязано к КЛЕТКЕ корабля, а не к сущности: блок
-- корабля — это число в таблице (см. ship.lua), сущности под ним пересобираются
-- при каждой перестройке палубы, и вешать на них содержимое сундука значило бы
-- терять его при постановке соседней доски.
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"

local St = {}

-- Сундук на 27 мест — три ряда по девять. Не больше: сундук должен кончаться,
-- иначе он превращается в свалку, и второй ставить незачем.
St.CHEST_SLOTS = 27

-- Печка. Три ячейки, как в играх про блоки: что жарим, чем топим, что вышло.
St.SMELT_TIME = 9.0     -- секунд на одну штуку при горящей печке

-- Что во что превращается в печке. Данные, а не код: добавить рецепт — строчка.
St.smelting = {
    [Blocks.FISH]    = {give = Blocks.COOKED,   n = 1},
    [Blocks.SEAWEED] = {give = Blocks.DRIED,    n = 1},
    -- Обломки в уголь: единственный способ получить хорошее топливо, и он же
    -- ответ на вопрос «куда девать двадцатую доску с воды».
    [Blocks.SCRAP]   = {give = Blocks.CHARCOAL, n = 1},
}

-- Состояние по клетке. Ключ — строка "x,y,z": числовой ключ пришлось бы считать
-- из границ корабля, а границы меняются (см. Ship.Snapshot о том же).
local cells = {}

local function key(x, y, z) return x .. "," .. y .. "," .. z end

local function makeState(kind)
    if kind == "furnace" then
        return {kind = "furnace", input = nil, fuel = nil, output = nil,
                burn = 0.0, burnMax = 0.0, progress = 0.0}
    elseif kind == "chest" then
        return {kind = "chest", slots = {}}
    end
    return {kind = kind}
end

-- Состояние клетки; создаётся при первом обращении. Так постройка и загрузка
-- не обязаны ничего заводить заранее: печка, поставленная минуту назад, и
-- печка из сохранения ведут себя одинаково.
function St.At(x, y, z, kind)
    local k = key(x, y, z)
    local s = cells[k]
    if s == nil and kind then
        s = makeState(kind)
        cells[k] = s
    end
    return s
end

function St.Forget(x, y, z) cells[key(x, y, z)] = nil end

-- --- Стопки ------------------------------------------------------------------
--
-- Стопка здесь — та же {id, n}, что и в инвентаре, и правила слияния те же.
-- Отдельные функции, а не заимствование из inventory.lua, потому что там они
-- работают с ЕГО массивом ячеек, а здесь ячейка — поле таблицы.
local STACK = 99

local function stackAdd(dst, id, n)
    if dst == nil then return {id = id, n = math.min(n, STACK)}, n - math.min(n, STACK) end
    if dst.id ~= id then return dst, n end
    local room = STACK - dst.n
    local put = math.min(room, n)
    dst.n = dst.n + put
    return dst, n - put
end

-- Влезет ли туда столько. Нужно ДО того, как печка потратит топливо: сжечь
-- доску и выбросить результат хуже, чем не начать плавку.
local function fits(dst, id, n)
    if dst == nil then return true end
    return dst.id == id and dst.n + n <= STACK
end

-- --- Печка --------------------------------------------------------------------
--
-- Порядок в кадре ровно такой, как ждёт глаз: сперва топливо (горит ли печка),
-- потом плавка (движется ли шкала). Обратный порядок дал бы кадр задержки между
-- «подложил доску» и «пошло дело», и на девятисекундной плавке это заметно.
local function tickFurnace(s, dt)
    local recipe = s.input and St.smelting[s.input.id] or nil
    local canWork = recipe ~= nil and fits(s.output, recipe.give, recipe.n)

    -- Топливо тратится ТОЛЬКО когда есть что плавить. Печка, сжигающая доски
    -- впустую, — самая обидная мелочь этого механизма: игрок отходит на минуту
    -- и возвращается к пустой печке и пустому ящику дров.
    if s.burn <= 0.0 and canWork and s.fuel then
        local seconds = Blocks.Fuel(s.fuel.id)
        if seconds then
            s.fuel.n = s.fuel.n - 1
            if s.fuel.n <= 0 then s.fuel = nil end
            s.burn = seconds
            s.burnMax = seconds
        end
    end

    if s.burn > 0.0 then
        s.burn = math.max(0.0, s.burn - dt)
    end

    if not canWork then
        -- Вынули заготовку посреди плавки — прогресс сбрасывается. Не
        -- «замирает»: подложив другую рыбу, игрок иначе получал бы её
        -- дожаренной с чужого прогресса.
        s.progress = 0.0
        return
    end

    if s.burn <= 0.0 then
        -- Печка гаснет — начатое медленно откатывается, а не стоит вечно.
        s.progress = math.max(0.0, s.progress - dt * 0.5)
        return
    end

    s.progress = s.progress + dt
    if s.progress < St.SMELT_TIME then return end

    s.progress = 0.0
    s.input.n = s.input.n - 1
    if s.input.n <= 0 then s.input = nil end
    s.output = (stackAdd(s.output, recipe.give, recipe.n))
end

-- Горит ли печка прямо сейчас — по этому свету у неё пляшет огонёк на палубе.
function St.IsBurning(x, y, z)
    local s = cells[key(x, y, z)]
    return s ~= nil and s.kind == "furnace" and s.burn > 0.0
end

-- Все печки тикают КАЖДЫЙ кадр, открыт их экран или нет. Иначе печка
-- превращалась бы в кнопку «получить результат»: подошёл, открыл, подождал.
-- Смысл печки ровно в обратном — поставить и уйти заниматься другим.
function St.Update(dt)
    for _, s in pairs(cells) do
        if s.kind == "furnace" then tickFurnace(s, dt) end
    end
end

-- --- Сундук -------------------------------------------------------------------
function St.ChestSlot(s, i) return s.slots[i] end

function St.SetChestSlot(s, i, stack)
    if i < 1 or i > St.CHEST_SLOTS then return end
    if stack == nil or (stack.n or 0) <= 0 then s.slots[i] = nil
    else s.slots[i] = {id = stack.id, n = stack.n} end
end

-- --- Разрушение ----------------------------------------------------------------
--
-- Сломали рабочее место — содержимое возвращается игроку, а не исчезает.
-- Возвращает список стопок, которые НЕ поместились в инвентарь: решать, что с
-- ними делать (сообщение, отказ ломать), — дело игры, а не этого модуля.
function St.Drain(x, y, z, addToInventory)
    local s = cells[key(x, y, z)]
    if s == nil then return {} end
    local lost = {}
    local function give(stack)
        if stack == nil then return end
        local left = addToInventory(stack.id, stack.n)
        if left > 0 then lost[#lost + 1] = {id = stack.id, n = left} end
    end
    if s.kind == "furnace" then
        give(s.input); give(s.fuel); give(s.output)
    elseif s.kind == "chest" then
        for i = 1, St.CHEST_SLOTS do give(s.slots[i]) end
    end
    cells[key(x, y, z)] = nil
    return lost
end

-- --- Сохранение -----------------------------------------------------------------
--
-- Пишем координаты, а не ключ, по той же причине, что и корабль: ключ — это
-- строка, собранная кодом, и её формат однажды поменяется.
local function packStack(s) return s and {s.id, s.n} or nil end
local function unpackStack(t)
    if type(t) ~= "table" or #t < 2 then return nil end
    return {id = t[1], n = t[2]}
end

function St.Snapshot()
    local out = {}
    for k, s in pairs(cells) do
        local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
        if x then
            local e = {x = tonumber(x), y = tonumber(y), z = tonumber(z), kind = s.kind}
            if s.kind == "furnace" then
                e.input = packStack(s.input)
                e.fuel = packStack(s.fuel)
                e.output = packStack(s.output)
                e.burn = s.burn
                e.burnMax = s.burnMax
                e.progress = s.progress
            elseif s.kind == "chest" then
                local items = {}
                for i = 1, St.CHEST_SLOTS do
                    local st = s.slots[i]
                    if st then items[#items + 1] = {i, st.id, st.n} end
                end
                e.items = items
            end
            out[#out + 1] = e
        end
    end
    return out
end

function St.Restore(list)
    cells = {}
    if type(list) ~= "table" then return end
    for _, e in ipairs(list) do
        if e.kind and e.x then
            local s = makeState(e.kind)
            if e.kind == "furnace" then
                s.input = unpackStack(e.input)
                s.fuel = unpackStack(e.fuel)
                s.output = unpackStack(e.output)
                s.burn = e.burn or 0.0
                s.burnMax = e.burnMax or 0.0
                s.progress = e.progress or 0.0
            elseif e.kind == "chest" then
                for _, it in ipairs(e.items or {}) do
                    if #it >= 3 then s.slots[it[1]] = {id = it[2], n = it[3]} end
                end
            end
            cells[key(e.x, e.y, e.z)] = s
        end
    end
end

function St.Reset() cells = {} end

return St
