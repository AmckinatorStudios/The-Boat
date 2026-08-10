-- ---------------------------------------------------------------------------
-- slots.lua — перекладывание вещей мышью. Одно на всю игру.
--
-- ЗАЧЕМ ОТДЕЛЬНЫЙ МОДУЛЬ. Ячейки со стопками теперь в четырёх экранах: трюм,
-- верстак, печка, сундук. Перетаскивание — это не «нажали на ячейку»: щелчок и
-- перенос начинаются одинаково и различаются только тем, где кнопку отпустили,
-- плюс между ними надо рисовать вещь под курсором и не потерять её, если экран
-- закрыли с полным курсором. Написать это четыре раза значит получить четыре
-- разных ответа на вопрос «что будет, если бросить стопку мимо ячейки».
--
-- КАК УСТРОЕНО. Экран объявляет ПРОСТРАНСТВО ячеек: имя-приставку и две
-- функции — прочитать ячейку и записать её. Дальше модуль сам разбирает имена
-- действий («inv:12», «chest:5», «furnace:fuel»), решает, что это было —
-- щелчок или перенос, — и складывает стопки по одним и тем же правилам:
-- одинаковые сливаются, разные меняются местами.
--
-- Правило слияния ОДНО на всю игру, и это главное, ради чего модуль есть:
-- иначе в сундуке стопки складывались бы, а в печке менялись местами, и
-- объяснить это игроку было бы нечем.
-- ---------------------------------------------------------------------------
local U = require "ui"

local S = {}

S.STACK = 99

-- Зарегистрированные пространства: приставка -> {get, set, capacity}.
local spaces = {}

-- Что несут в курсоре и откуда взяли. from нужен, чтобы отличить ЩЕЛЧОК (взял
-- и держу) от ПЕРЕНОСА (взял, довёл, отпустил).
local held = nil
local from = nil

local ghost, ghostIcon, ghostCount
local paint                    -- как рисовать стопку в ячейке (задаёт игра)

-- --- Настройка ----------------------------------------------------------------

-- root — корень экрана, поверх которого едет вещь под курсором. Один на игру:
-- курсор один, и вещь в нём одна.
function S.Init(root, size, paintFn)
    ghost, ghostIcon, ghostCount = U.Slot(root, "Drag Ghost", UIAnchor.TopLeft, 0, 0, size)
    local g = ghost:GetUI()
    g.Color = U.C(U.AMBER, 0.18)
    g.BorderColor = U.C(U.AMBER, 0.85)
    g.Visible = false
    paint = paintFn
end

-- get(index) -> {id, n} или nil; set(index, stack).
-- Индекс приходит СТРОКОЙ: у инвентаря он номер, у печки — «fuel». Разбирать
-- его — дело того, кто пространство завёл.
function S.Space(prefix, get, set)
    spaces[prefix] = {get = get, set = set}
end

-- Имя действия для ячейки. Через функцию, а не строкой в каждом экране: формат
-- имени знает только этот модуль, и он же его разбирает.
function S.Action(prefix, index) return prefix .. ":" .. tostring(index) end

local function parse(action)
    if action == nil or action == "" then return nil end
    local prefix, index = action:match("^([%a]+):(.+)$")
    if prefix == nil or spaces[prefix] == nil then return nil end
    return spaces[prefix], index
end

-- --- Правила ------------------------------------------------------------------
local function take(space, index)
    local s = space.get(index)
    if s == nil then return nil end
    space.set(index, nil)
    return {id = s.id, n = s.n}
end

-- Положить то, что в курсоре: пустая ячейка — просто ложится, такая же —
-- складывается, чужая — меняются местами.
local function put(space, index)
    if held == nil then return end
    local there = space.get(index)
    if there == nil then
        space.set(index, held)
        held = nil
        return
    end
    if there.id == held.id then
        local room = S.STACK - there.n
        local n = math.min(room, held.n)
        if n > 0 then
            space.set(index, {id = there.id, n = there.n + n})
            held.n = held.n - n
            if held.n <= 0 then held = nil end
        end
        return
    end
    space.set(index, held)
    held = {id = there.id, n = there.n}
end

-- --- Кадр ---------------------------------------------------------------------

-- Возвращает имя действия под курсором — экраны показывают по нему подсказку и
-- не спрашивают его у движка второй раз.
function S.Update()
    local pressed = sage.ui.PressedAction()
    local pSpace, pIndex = parse(pressed)
    if pSpace then
        if held == nil then
            held = take(pSpace, pIndex)
            from = held and pressed or nil
        else
            put(pSpace, pIndex)
            from = nil
        end
    end

    local released = sage.ui.ReleasedAction()
    local rSpace, rIndex = parse(released)
    if rSpace and held ~= nil and from ~= nil then
        -- Отпустили над ДРУГОЙ ячейкой — это перенос. Над той же самой —
        -- обычный щелчок: вещь остаётся в курсоре, и её кладут вторым щелчком.
        if released ~= from then put(rSpace, rIndex) end
        from = nil
    end

    local g = ghost and ghost:GetUI() or nil
    if g then
        if held then
            local c = sage.ui.Cursor()
            g.Visible = c.x >= 0.0
            g.Offset = Vec2(c.x - g.Size.x * 0.5, c.y - g.Size.y * 0.5)
            if paint then paint(ghostIcon, ghostCount, held.id, held.n) end
        else
            g.Visible = false
        end
    end

    return sage.ui.HoveredAction()
end

function S.Held() return held end

-- Экран закрыли с полным курсором — вещь надо кому-то отдать. Тому, кто закрыл:
-- его инвентарь единственное место, которое точно ещё существует (сундук могли
-- закрыть, потому что его ломают).
function S.ReturnHeld(addToInventory)
    if held == nil then return end
    addToInventory(held.id, held.n)
    held, from = nil, nil
    if ghost then ghost:GetUI().Visible = false end
end

return S
