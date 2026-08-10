-- ---------------------------------------------------------------------------
-- inventory.lua — что лежит в трюме, в каком порядке и во что превращается.
--
-- ЧТО ЗДЕСЬ ПЕРЕДЕЛАНО И ПОЧЕМУ. Раньше инвентарь был счётчиком «сколько чего
-- есть» (id -> число), а хотбар — жёстким списком из шести видов блоков,
-- заведённым в коде. Из этого следовало сразу три неправды:
--
--   * игра начиналась не с пустыми руками: шесть слотов уже были заняты
--     досками, леерами и фонарём, которых у игрока нет. Пустая ячейка
--     показывала бледный значок предмета, которого в трюме ноль, — то есть
--     врала о том, что он там как бы есть;
--   * переложить вещь было некуда и незачем: порядок слотов задан кодом, и
--     игрок в нём ничего не решает;
--   * «сколько досок» и «в каком слоте доски» были разными вопросами, на
--     которые отвечали разные структуры.
--
-- Теперь инвентарь — это СЛОТЫ, как в играх про блоки: массив ячеек, в каждой
-- стопка {id, n} или пусто. Первые шесть — хотбар (то, что в руке), остальные
-- — трюм. Одна и та же ячейка, один и тот же способ её взять и положить, а
-- значит перетаскивание работает и внутри трюма, и между трюмом и хотбаром без
-- единого частного случая.
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"

local Inv = {}

-- Шесть в хотбаре — по числу цифр, которыми его берут. Двадцать четыре в трюме
-- — три ряда по восемь на верстаке; больше некуда положить на экране, а меньше
-- кончается быстрее, чем игрок доплывёт до опреснителя.
Inv.HOTBAR = 6
Inv.HOLD = 24
Inv.SIZE = Inv.HOTBAR + Inv.HOLD
-- Предел стопки. Не «бесконечность»: тысяча обломков в одной ячейке
-- превращает трюм в один счётчик, и раскладывать становится нечего.
Inv.STACK = 99

-- slots[i] = {id = ..., n = ...} или nil (пусто).
local slots = {}

Inv.selected = 1

-- Рецепты — данные, а не код.
--
-- basic — доступен голыми руками, то есть прямо в трюме по TAB. Всё остальное
-- собирают на ВЕРСТАКЕ (см. stationui.lua), и это не бюрократия: верстак —
-- первая вещь, ради которой игрок идёт что-то строить, и если бы с рук делалось
-- всё, строить его было бы незачем. Список basic намеренно короткий и ведёт
-- ровно к нему: доска, а из досок — верстак.
Inv.recipes = {
    {id = "plank",    name = "Доска",      basic = true,
     cost = {{Blocks.SCRAP, 2}},                       give = {Blocks.PLANK, 1}},
    {id = "bench",    name = "Верстак",    basic = true,
     cost = {{Blocks.PLANK, 4}},                       give = {Blocks.BENCH, 1}},
    {id = "rail",     name = "Леер",
     cost = {{Blocks.SCRAP, 1}, {Blocks.ROPE, 1}},     give = {Blocks.RAIL, 2}},
    {id = "wall",     name = "Стена",
     cost = {{Blocks.SCRAP, 3}},                       give = {Blocks.WALL, 2}},
    {id = "furnace",  name = "Печка",
     cost = {{Blocks.SCRAP, 6}, {Blocks.PLASTIC, 1}},  give = {Blocks.FURNACE, 1}},
    {id = "chest",    name = "Сундук",
     cost = {{Blocks.PLANK, 5}},                       give = {Blocks.CHEST, 1}},
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

-- --- Ячейки ------------------------------------------------------------------
function Inv.Slot(i) return slots[i] end
function Inv.SlotId(i) return slots[i] and slots[i].id or nil end
function Inv.SlotCount(i) return slots[i] and slots[i].n or 0 end

-- Положить стопку в ячейку как есть (используется перетаскиванием).
function Inv.SetSlot(i, stack)
    if i < 1 or i > Inv.SIZE then return end
    if stack == nil or (stack.n or 0) <= 0 then slots[i] = nil
    else slots[i] = {id = stack.id, n = stack.n} end
end

-- Сколько всего такого предмета во всех ячейках. Именно всего: рецепту всё
-- равно, в скольких стопках лежат его три верёвки.
function Inv.Count(id)
    local n = 0
    for i = 1, Inv.SIZE do
        local s = slots[i]
        if s and s.id == id then n = n + s.n end
    end
    return n
end

function Inv.Has(id, n) return Inv.Count(id) >= (n or 1) end

-- Добавить предметы. Сначала в НАЧАТЫЕ стопки того же вида, потом в первую
-- пустую ячейку — и хотбар раньше трюма: первые находки должны оказаться под
-- рукой, а не в глубине инвентаря, который игрок ещё не открывал.
--
-- Возвращает, сколько НЕ поместилось: инвентарь конечен, и молча выбрасывать
-- лишнее нельзя — игра обязана сказать, что трюм полон.
function Inv.Add(id, n)
    if id == nil or id == Blocks.AIR then return 0 end
    n = n or 1
    for i = 1, Inv.SIZE do
        local s = slots[i]
        if s and s.id == id and s.n < Inv.STACK then
            local room = Inv.STACK - s.n
            local put = math.min(room, n)
            s.n = s.n + put
            n = n - put
            if n <= 0 then return 0 end
        end
    end
    for i = 1, Inv.SIZE do
        if slots[i] == nil then
            local put = math.min(Inv.STACK, n)
            slots[i] = {id = id, n = put}
            n = n - put
            if n <= 0 then return 0 end
        end
    end
    return n
end

function Inv.Remove(id, n)
    n = n or 1
    if Inv.Count(id) < n then return false end
    -- С конца: сперва тратим то, что лежит в глубине трюма, и хотбар остаётся
    -- полным дольше. Иначе доска исчезает из руки, пока в трюме лежит ещё
    -- двадцать таких же.
    for i = Inv.SIZE, 1, -1 do
        local s = slots[i]
        if s and s.id == id then
            local take = math.min(s.n, n)
            s.n = s.n - take
            n = n - take
            if s.n <= 0 then slots[i] = nil end
            if n <= 0 then return true end
        end
    end
    return true
end

-- Взять из КОНКРЕТНОЙ ячейки: так тратит поставленный блок рука.
function Inv.RemoveFromSlot(i, n)
    local s = slots[i]
    if not s then return false end
    n = math.min(n or 1, s.n)
    s.n = s.n - n
    if s.n <= 0 then slots[i] = nil end
    return true
end

function Inv.AddLoot(loot)
    local lost = 0
    for _, entry in ipairs(loot) do lost = lost + Inv.Add(entry[1], entry[2]) end
    return lost
end

-- --- Хотбар ------------------------------------------------------------------
function Inv.SelectedBlock() return Inv.SlotId(Inv.selected) end

function Inv.Select(slot)
    if slot >= 1 and slot <= Inv.HOTBAR then Inv.selected = slot end
end

function Inv.Cycle(delta)
    Inv.selected = ((Inv.selected - 1 + delta) % Inv.HOTBAR) + 1
end

-- Выбрать хотбар-ячейку с этим предметом. Нужно и игроку (взять доску), и
-- автопрогону: он «берёт в руку» ровно так же, а не подменяет поле.
function Inv.SelectItem(id)
    for i = 1, Inv.HOTBAR do
        if slots[i] and slots[i].id == id then
            Inv.selected = i
            return true
        end
    end
    return false
end

-- --- Перекладывание ----------------------------------------------------------
--
-- Одна операция на всё перетаскивание: стопки одного вида сливаются, разного —
-- меняются местами. Больше в игре про уют не нужно: делить стопку правой
-- кнопкой — это интерфейс для складов, а не для лодки.
function Inv.MoveStack(from, to)
    if from == to or from < 1 or to < 1 or from > Inv.SIZE or to > Inv.SIZE then return false end
    local a, b = slots[from], slots[to]
    if a == nil then return false end
    if b ~= nil and b.id == a.id then
        local room = Inv.STACK - b.n
        if room <= 0 then return false end
        local put = math.min(room, a.n)
        b.n = b.n + put
        a.n = a.n - put
        if a.n <= 0 then slots[from] = nil end
        return true
    end
    slots[from], slots[to] = b, a
    return true
end

-- --- Крафт --------------------------------------------------------------------
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
    local lost = Inv.Add(recipe.give[1], recipe.give[2])
    if lost > 0 then
        -- Класть некуда — возвращаем потраченное. Съесть материалы и не отдать
        -- предмет хуже, чем просто отказать.
        for _, c in ipairs(recipe.cost) do Inv.Add(c[1], c[2]) end
        return false, "Трюм полон"
    end
    return true, recipe.name .. " x" .. recipe.give[2]
end

-- Съесть что-нибудь: перебор идёт от самого сытного, чтобы «поесть» не
-- превращалось в выбор блюда из меню.
function Inv.EatBest()
    local best, bestVal = nil, 0
    for _, id in ipairs({Blocks.COOKED, Blocks.FISH, Blocks.DRIED, Blocks.SEAWEED}) do
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

-- Новая игра: пустые руки и пустой трюм. Именно пустые — игра начинается с
-- того, что смотреть вокруг нечего, кроме воды, и ловить нечего, кроме мусора.
function Inv.Reset()
    slots = {}
    Inv.selected = 1
end

-- --- Сохранение ---------------------------------------------------------------
--
-- Пишем НОМЕР ячейки вместе со стопкой: порядок в инвентаре — это решение
-- игрока (он его сам разложил), и терять его при выходе так же обидно, как
-- терять сами предметы.
function Inv.Snapshot()
    local out = {}
    for i = 1, Inv.SIZE do
        local s = slots[i]
        if s then out[#out + 1] = {i, s.id, s.n} end
    end
    return {slots = out, selected = Inv.selected}
end

function Inv.Restore(data)
    if type(data) ~= "table" then return end
    slots = {}
    for _, e in ipairs(data.slots or {}) do
        if #e >= 3 then Inv.SetSlot(e[1], {id = e[2], n = e[3]}) end
    end
    -- Сохранения ДО ячеек хранили плоский список {id, сколько}: раскладываем
    -- его по свободным местам. Иначе переход на слоты означал бы «все старые
    -- партии начинают с пустым трюмом», то есть тихую потерю прогресса.
    for _, e in ipairs(data.items or {}) do
        if #e >= 2 then Inv.Add(e[1], e[2]) end
    end
    if data.selected then Inv.Select(data.selected) end
end

return Inv
