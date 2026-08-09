-- ---------------------------------------------------------------------------
-- ui.lua — кирпичики, из которых собраны все экраны игры.
--
-- Экранов в игре три (худ, верстак, меню), и до этого модуля каждый из них
-- заводил свою палитру, свою функцию «создать элемент» и свои представления о
-- том, как выглядит кнопка. Разъезжались они мгновенно: карточка худа была на
-- восьми пикселях скругления, карточка верстака — на двенадцати, и заметить
-- это можно было только поставив их рядом.
--
-- Здесь один набор понятий: ЭКРАН (корень во весь кадр), КАРТОЧКА (подложка),
-- СЛОТ (квадрат с предметом), КНОПКА, НАДПИСЬ. Всё остальное — из них.
--
-- Ни одной картинки на диске: значки — векторные иконки движка
-- (sage.ui.IconNames), цвета — числа ниже.
-- ---------------------------------------------------------------------------
local U = {}

-- --- Палитра ----------------------------------------------------------------
-- Ночное стекло с тёплым акцентом: холодная тёмная подложка не спорит с водой,
-- а всё, на что надо смотреть, — тёплое.
U.INK      = {0.05, 0.08, 0.13}
U.INK_DEEP = {0.02, 0.03, 0.06}
U.AMBER    = {0.99, 0.82, 0.48}
U.TEXT     = {0.95, 0.94, 0.90}
U.MUTED    = {0.62, 0.68, 0.75}
U.ALARM    = {0.96, 0.45, 0.35}
U.GOOD     = {0.55, 0.82, 0.55}

function U.C(rgb, a) return Vec4(rgb[1], rgb[2], rgb[3], a or 1.0) end

-- --- Экран ------------------------------------------------------------------
--
-- Корень во весь кадр: под ним живёт всё содержимое экрана, и спрятать экран
-- целиком — это одно поле Visible на нём, а не обход детей.
--
-- Порядок между экранами задаёт холст (order): худ под верстаком, верстак под
-- меню. Раньше это решал порядок создания сущностей — то есть ничего не решал.
function U.Screen(name, order)
    local obj = SpawnObject(name)
    SetMeshNone(obj)
    local e = obj:AddUI()
    e.Anchor = UIAnchor.TopLeft
    e.Offset = Vec2(0, 0)
    e.Stretch = UIStretch.Both
    e.Color = Vec4(0, 0, 0, 0)
    sage.ui.SetCanvas(obj, {order = order or 0})
    return obj, e
end

-- --- Элементы ---------------------------------------------------------------
--
-- У всех одна сигнатура: родитель, имя, якорь, смещение, размер. Имя видно в
-- иерархии редактора — по нему экран разбирают глазами, не читая скрипт.
local function base(parent, name, anchor, x, y, w, h)
    local obj = SpawnObject(name)
    SetMeshNone(obj)
    local e = obj:AddUI()
    e.Anchor = anchor or UIAnchor.TopLeft
    e.Offset = Vec2(x, y)
    e.Size = Vec2(w, h)
    if parent then obj:SetParent(parent) end
    return obj, e
end

function U.Panel(parent, name, anchor, x, y, w, h)
    local obj, e = base(parent, name, anchor, x, y, w, h)
    e.Type = UIKind.Panel
    e.Color = Vec4(0, 0, 0, 0)
    e.Rounding = 8.0
    e.TextScale = 1.2
    -- Выравнивание задаём ЯВНО: у надписи движка по умолчанию центр, и подпись
    -- рядом со значком уезжала бы от него на середину элемента.
    e.TextCentered = false
    e.TextColor = U.C(U.TEXT)
    e.IconColor = U.C(U.TEXT)
    return obj, e
end

-- Карточка: подложка с градиентом и мягкой тенью. Без неё панель сливается с
-- морем, и любой текст на пёстрой воде читается плохо.
function U.Card(parent, name, anchor, x, y, w, h)
    local obj, e = U.Panel(parent, name, anchor, x, y, w, h)
    e.Rounding = 14.0
    e.Color = U.C(U.INK, 0.62)
    e.GradientColor = U.C(U.INK_DEEP, 0.5)
    e.ShadowSize = 18.0
    e.BorderThickness = 1.0
    e.BorderColor = Vec4(1, 1, 1, 0.07)
    return obj, e
end

function U.Label(parent, name, anchor, x, y, w, h, text, scale)
    local obj, e = base(parent, name, anchor, x, y, w, h)
    e.Type = UIKind.Label
    e.Text = text or ""
    e.TextScale = scale or 1.2
    e.TextCentered = false
    e.TextColor = U.C(U.TEXT)
    return obj, e
end

function U.Icon(parent, name, anchor, x, y, size, icon, color)
    local obj, e = base(parent, name, anchor, x, y, size, size)
    e.Type = UIKind.Icon
    e.Icon = icon
    e.IconColor = color or U.C(U.TEXT)
    return obj, e
end

function U.Bar(parent, name, anchor, x, y, w, h, color)
    local obj, e = base(parent, name, anchor, x, y, w, h)
    e.Type = UIKind.Bar
    e.Rounding = h * 0.5
    e.Color = Vec4(0, 0, 0, 0.34)
    e.BarFillColor = color or U.C(U.AMBER)
    e.Value = 1.0
    return obj, e
end

-- Кнопка: панель, которая ловит мышь и знает своё ИМЯ ДЕЙСТВИЯ. Игра потом
-- спрашивает «что нажали» именем (sage.ui.ClickedAction), а не номером
-- сущности — номер меняется при каждой пересборке экрана.
function U.Button(parent, name, anchor, x, y, w, h, text, action, icon)
    local obj, e = U.Panel(parent, name, anchor, x, y, w, h)
    e.Rounding = 12.0
    e.Color = U.C(U.INK, 0.78)
    e.GradientColor = U.C(U.INK_DEEP, 0.72)
    e.BorderThickness = 1.5
    e.BorderColor = U.C(U.AMBER, 0.35)
    e.ShadowSize = 14.0
    e.Text = text or ""
    e.TextScale = 1.5
    e.TextCentered = true
    e.TextColor = U.C(U.TEXT)
    e.Icon = icon or ""
    e.IconColor = U.C(U.AMBER)
    e.Interactive = true
    e.Action = action
    return obj, e
end

-- Квадратный слот под предмет: подложка + значок + счётчик. Один и тот же и в
-- хотбаре, и в трюме, и в списке рецептов — иначе «предмет» выглядел бы в трёх
-- местах по-разному, хотя это одна и та же вещь.
-- Возвращает ТРИ сущности — сам слот, его значок и счётчик, — потому что
-- обновлять их придётся каждую по-своему: рамку слота, цвет значка и текст
-- счётчика. Искать детей по имени каждый кадр было бы поиском того, что мы
-- только что создали.
function U.Slot(parent, name, anchor, x, y, size, action)
    local obj, e = U.Panel(parent, name, anchor, x, y, size, size)
    e.Rounding = 12.0
    e.Color = U.C(U.INK, 0.55)
    e.GradientColor = U.C(U.INK_DEEP, 0.62)
    e.BorderThickness = 1.5
    e.BorderColor = Vec4(1, 1, 1, 0.10)
    e.ShadowSize = 10.0
    if action then
        e.Interactive = true
        e.Action = action
    end

    local iconObj = U.Icon(obj, name .. " Icon", UIAnchor.Center, 0, -4, size * 0.52, "crate")
    local countObj, count = U.Label(obj, name .. " Count", UIAnchor.BottomCenter, 0, 5,
                                    size, 13, "", 1.1)
    count.TextCentered = true
    return obj, iconObj, countObj
end

return U
