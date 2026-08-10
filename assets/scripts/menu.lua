-- ---------------------------------------------------------------------------
-- menu.lua — меню игры: то, с чего игра начинается и куда возвращается по ESC.
--
-- ЧЕГО НЕ БЫЛО. Игра начиналась сразу с палубы, а ESC был клавишей движка:
-- первый раз он отпускал курсор, второй — закрывал окно. Ни начать заново, ни
-- сохраниться нарочно, ни выйти, зная, что прогресс записан, было нельзя.
-- «Продолжить» из прошлой партии происходило само и молча.
--
-- Здесь два состояния одного экрана. ЗАГЛАВНОЕ меню — при запуске: мир за ним
-- уже живёт (волна качает лодку, мусор плывёт мимо), потому что показывать
-- игру про воду на чёрном фоне — значит прятать ровно то, ради чего в неё
-- заходят. МЕНЮ ПАУЗЫ — по ESC во время игры, с сохранением и выходом.
--
-- Мир на время меню замирает НЕ ЧЕРЕЗ sage.game.Pause: пауза движка
-- останавливает и скрипты тоже, а вместе с ними — само это меню, и нажать в
-- нём было бы нечего. Что именно замирает, решает игровой цикл (см. game.lua).
-- ---------------------------------------------------------------------------
local U = require "ui"

local M = {}

local root, title, subtitle, hint
local buttons = {}      -- имя действия -> {obj, e}
local state = nil       -- nil | "title" | "pause"
local hooks = {}

local BTN_W, BTN_H, BTN_GAP = 300, 54, 12

-- Что показывать в каждом состоянии. Порядок — сверху вниз; кнопки, которых в
-- списке нет, прячутся целиком, поэтому дыр в столбце не бывает.
local LAYOUT = {
    title = {"continue", "new", "quit"},
    pause = {"continue", "save", "new", "quit"},
}

local CAPTION = {
    continue = {"Продолжить", "play"},
    new      = {"Новая игра", "plus"},
    save     = {"Сохранить", "save"},
    quit     = {"Выйти", "exit"},
}

-- В паузе выход сперва сохраняет, и кнопка об этом говорит прямо: «Выйти» без
-- уточнения — это вопрос «а сохранится ли?», который человек задаёт себе ровно
-- в тот момент, когда ответа уже не узнать.
local QUIT_CAPTION = {title = "Выйти", pause = "Сохранить и выйти"}

function M.Build(deps)
    hooks = deps or {}

    -- Поверх всего остального (order = 40): меню обязано быть выше и худа, и
    -- верстака — иначе «Выйти» окажется под ячейкой инвентаря.
    root = U.Screen("Menu Screen", 40)
    root:GetUI().Visible = false

    local _, dim = U.Panel(root, "Menu Dim", UIAnchor.TopLeft, 0, 0, 10, 10)
    dim.Stretch = UIStretch.Both
    dim.Color = Vec4(0.02, 0.03, 0.06, 0.55)
    dim.Rounding = 0.0

    local _, t = U.Label(root, "Menu Title", UIAnchor.Center, 0, -170, 520, 54, "The Boat", 4.0)
    t.TextCentered = true
    t.TextColor = U.C(U.AMBER)
    title = t

    local _, s = U.Label(root, "Menu Subtitle", UIAnchor.Center, 0, -120, 520, 24, "", 1.3)
    s.TextCentered = true
    s.TextColor = U.C(U.MUTED)
    subtitle = s

    for i, name in ipairs({"continue", "new", "save", "quit"}) do
        local caption = CAPTION[name]
        local obj, e = U.Button(root, "Menu " .. name, UIAnchor.Center, 0, 0, BTN_W, BTN_H,
                                caption[1], "menu:" .. name, caption[2])
        -- Значок в кнопке — размером с букву, а не с саму кнопку: по умолчанию
        -- он занимает всю её высоту и спорит с подписью за внимание.
        e.IconSize = 22.0
        e.Visible = false
        buttons[name] = {obj = obj, e = e}
    end

    -- Раскладка внизу: игра почти без слов на экране, и единственное место, где
    -- про клавиши сказано прямо, — здесь.
    local _, h = U.Label(root, "Menu Hint", UIAnchor.BottomCenter, 0, 28, 900, 22, "", 1.15)
    h.TextCentered = true
    h.TextColor = U.C(U.MUTED, 0.85)
    hint = h
end

function M.IsOpen() return state ~= nil end
function M.State() return state end

function M.Open(which)
    state = which
    local list = LAYOUT[which] or {}
    -- Кнопки расставляем сами, а не раскладкой: у состояний разный набор, и
    -- спрятанный ребёнок оставил бы в столбце пустое место ровно там, где его
    -- быть не должно.
    local total = #list * BTN_H + (#list - 1) * BTN_GAP
    for _, entry in pairs(buttons) do entry.e.Visible = false end
    for i, name in ipairs(list) do
        local entry = buttons[name]
        if entry then
            entry.e.Visible = true
            entry.e.Offset = Vec2(0, -total * 0.5 + (i - 1) * (BTN_H + BTN_GAP) + BTN_H * 0.5 - 20)
        end
    end

    -- «Продолжить» в заглавном меню значит «загрузить сохранение», и если
    -- сохранения нет — кнопке нечего делать. Выключенная, а не спрятанная:
    -- так видно, что продолжение вообще бывает.
    local resume = buttons.continue
    if resume then
        local available = which ~= "title" or (hooks.HasSave and hooks.HasSave())
        resume.e.Enabled = available and true or false
    end

    local quit = buttons.quit
    if quit then quit.e.Text = QUIT_CAPTION[which] or "Выйти" end

    -- Заголовок и подпись — НАД столбцом кнопок, а не по фиксированным числам:
    -- кнопок в паузе на одну больше, столбец выше, и подпись, поставленная
    -- «на 120 вверх», оказывалась ровно под первой кнопкой. Видно этого не
    -- было: она рисуется раньше и молча уходила под неё.
    local top = -total * 0.5 - 20
    subtitle.Offset = Vec2(0, top - 26)
    title.Offset = Vec2(0, top - 76)

    title.Visible = (which == "title")
    subtitle.Text = which == "title" and (hooks.Subtitle and hooks.Subtitle() or "")
                    or "Пауза"
    hint.Text = which == "title"
                and ("WASD — идти   ·   мышь — смотреть   ·   E — багор   ·   " ..
                     "ЛКМ/ПКМ — разобрать и поставить   ·   TAB — верстак   ·   ESC — меню")
                or "ESC — вернуться в игру"
    root:GetUI().Visible = true
    SetMouseCaptured(false)
end

function M.Close()
    state = nil
    if root ~= nil and root:Valid() then root:GetUI().Visible = false end
end

-- Что нажали за кадр. Возвращает имя действия ("continue", "new", "save",
-- "quit") или nil — решение принимает игровой цикл, а не меню: закрывать ли
-- экран, начинать ли заново и что при этом сохранить, знает он.
function M.Update(dt)
    if state == nil then return nil end
    local clicked = sage.ui.ClickedAction()
    if clicked:sub(1, 5) ~= "menu:" then return nil end
    local action = clicked:sub(6)
    if action == "continue" then
        local entry = buttons.continue
        -- Выключенная кнопка мышь не ловит, но проверка стоит и здесь: щелчок
        -- по «Продолжить» без сохранения не должен начинать пустую партию.
        if entry and not entry.e.Enabled then return nil end
    end
    return action
end

return M
