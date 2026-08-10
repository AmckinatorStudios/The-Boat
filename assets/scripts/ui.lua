-- ---------------------------------------------------------------------------
-- ui.lua — кирпичики, из которых собраны все экраны игры.
--
-- Экранов в игре шесть (худ, инвентарь, верстак, печка, сундук, меню), и до
-- этого модуля каждый из них заводил свою палитру, свою функцию «создать
-- элемент» и свои представления о том, как выглядит кнопка. Разъезжались они
-- мгновенно: карточка худа была на восьми пикселях скругления, карточка
-- верстака — на двенадцати, и заметить это можно было только поставив их рядом.
--
-- Здесь один набор понятий: ЭКРАН (корень во весь кадр), КАРТОЧКА (подложка),
-- СЛОТ (квадрат с предметом), КНОПКА, НАДПИСЬ, ПОДСКАЗКА. Всё остальное — из
-- них.
--
-- --- СТИЛЬ: ПЛОСКО -----------------------------------------------------------
--
-- Ни теней, ни градиентов, ни скруглений сверх двух пикселей. Это не мода, а
-- решение по существу: интерфейс здесь всегда лежит поверх ЖИВОЙ воды, которая
-- сама по себе пёстрая и подвижная. Мягкая тень под карточкой на такой подложке
-- читается как грязь, градиент спорит с закатом, а толстое скругление съедает
-- сетку слотов — квадраты перестают выглядеть сеткой. Плоский прямоугольник с
-- честной заливкой и волосяной рамкой не спорит ни с чем и одинаково читается
-- в полдень и в темноте.
--
-- Разделение простое: ФОРМУ даёт заливка, ГРАНИЦУ — рамка в один пиксель,
-- ВАЖНОСТЬ — цвет, и ничего больше. Если элемент надо выделить, он становится
-- ярче или получает акцентную рамку; он не приподнимается и не отбрасывает
-- тень.
--
-- Ни одной картинки на диске: значки — векторные иконки движка
-- (sage.ui.IconNames), цвета — числа ниже.
-- ---------------------------------------------------------------------------
local U = {}

-- --- Палитра ----------------------------------------------------------------
-- Холодная тёмная подложка не спорит с водой, а всё, на что надо смотреть, —
-- тёплое. Плотность подложки выше, чем была: без тени и градиента отделять
-- панель от фона теперь нечем, кроме самой заливки.
U.INK      = {0.06, 0.08, 0.11}   -- подложка панелей
U.SURFACE  = {0.11, 0.13, 0.17}   -- слот, кнопка: на тон светлее подложки
U.LINE     = {0.32, 0.36, 0.42}   -- волосяная рамка
U.AMBER    = {0.99, 0.82, 0.48}   -- акцент: выбранное, доступное, важное
U.TEXT     = {0.95, 0.94, 0.90}
U.MUTED    = {0.60, 0.66, 0.72}
U.ALARM    = {0.96, 0.45, 0.35}
U.GOOD     = {0.55, 0.82, 0.55}

-- Скругление на весь интерфейс. Два пикселя — это «не острый угол», а не
-- «кнопка-таблетка»: одно число здесь избавляет от спора о скруглении в
-- каждом экране.
U.ROUND = 2.0

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
    e.Rounding = U.ROUND
    e.TextScale = 1.2
    -- Выравнивание задаём ЯВНО: у надписи движка по умолчанию центр, и подпись
    -- рядом со значком уезжала бы от него на середину элемента.
    e.TextCentered = false
    e.TextColor = U.C(U.TEXT)
    e.IconColor = U.C(U.TEXT)
    return obj, e
end

-- Карточка: подложка экрана. Плотная заливка и волосяная рамка — этого
-- достаточно, чтобы отделить её от воды, и ничего лишнего сверх этого нет.
function U.Card(parent, name, anchor, x, y, w, h)
    local obj, e = U.Panel(parent, name, anchor, x, y, w, h)
    e.Color = U.C(U.INK, 0.94)
    e.BorderThickness = 1.0
    e.BorderColor = U.C(U.LINE, 0.85)
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

-- Заголовок раздела внутри карточки. Отдельной функцией, потому что таких
-- подписей в игре теперь десяток, и «приглушённый текст на 1.15» повторялся бы
-- в каждом экране своим числом.
function U.Caption(parent, name, anchor, x, y, w, text)
    local obj, e = U.Label(parent, name, anchor, x, y, w, 18, text, 1.15)
    e.TextColor = U.C(U.MUTED)
    return obj, e
end

function U.Icon(parent, name, anchor, x, y, size, icon, color)
    local obj, e = base(parent, name, anchor, x, y, size, size)
    e.Type = UIKind.Icon
    e.Icon = icon
    e.IconColor = color or U.C(U.TEXT)
    return obj, e
end

-- Иконка предмета в слоте: объёмная картинка, если движок её уже снял, иначе
-- плоский значок. Одно место на весь интерфейс — иначе верстак и худ разошлись
-- бы в том, как показывают один и тот же предмет.
--
-- Пустой слот остаётся ПУСТЫМ: бледный значок в пустой ячейке врёт, будто
-- предмет как бы есть.
function U.SlotIcon(iconObj, id, blocks, icons)
    if iconObj == nil or not iconObj:Valid() then return end
    local e = iconObj:GetUI()
    if id == nil then
        e.Type = UIKind.Icon
        e.Icon = ""
        sage.ui.ClearImage(iconObj)
        return
    end
    local path = icons and icons.Path(id) or nil
    if path then
        e.Type = UIKind.Image
        e.Icon = ""
        e.Color = Vec4(1, 1, 1, 1)
        sage.ui.SetImage(iconObj, path)
    else
        e.Type = UIKind.Icon
        sage.ui.ClearImage(iconObj)
        e.Icon = blocks.Icon(id)
        local c = blocks.Color(id)
        e.IconColor = Vec4(c.x, c.y, c.z, 1.0)
    end
end

-- Шкала. Прямоугольная: скруглённый жёлоб при высоте в десять пикселей
-- превращается в капсулу, и заполнение читается хуже, чем в прямом жёлобе.
function U.Bar(parent, name, anchor, x, y, w, h, color)
    local obj, e = base(parent, name, anchor, x, y, w, h)
    e.Type = UIKind.Bar
    e.Rounding = 0.0
    e.Color = Vec4(0, 0, 0, 0.45)
    e.BarFillColor = color or U.C(U.AMBER)
    e.Value = 1.0
    return obj, e
end

-- Кнопка: панель, которая ловит мышь и знает своё ИМЯ ДЕЙСТВИЯ. Игра потом
-- спрашивает «что нажали» именем (sage.ui.ClickedAction), а не номером
-- сущности — номер меняется при каждой пересборке экрана.
function U.Button(parent, name, anchor, x, y, w, h, text, action, icon)
    local obj, e = U.Panel(parent, name, anchor, x, y, w, h)
    e.Color = U.C(U.SURFACE, 0.95)
    e.BorderThickness = 1.0
    e.BorderColor = U.C(U.AMBER, 0.45)
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
-- хотбаре, и в трюме, и в сундуке, и в печке, и в списке рецептов — иначе
-- «предмет» выглядел бы в пяти местах по-разному, хотя это одна и та же вещь.
-- Возвращает ТРИ сущности — сам слот, его значок и счётчик, — потому что
-- обновлять их придётся каждую по-своему: рамку слота, цвет значка и текст
-- счётчика. Искать детей по имени каждый кадр было бы поиском того, что мы
-- только что создали.
function U.Slot(parent, name, anchor, x, y, size, action)
    local obj, e = U.Panel(parent, name, anchor, x, y, size, size)
    e.Color = U.C(U.SURFACE, 0.95)
    e.BorderThickness = 1.0
    e.BorderColor = U.C(U.LINE, 0.7)
    if action then
        e.Interactive = true
        e.Action = action
    end

    local iconObj = U.Icon(obj, name .. " Icon", UIAnchor.Center, 0, -4, size * 0.52, "crate")
    local countObj, count = U.Label(obj, name .. " Count", UIAnchor.BottomRight, 4, 3,
                                    size, 13, "", 1.1)
    count.TextCentered = false
    return obj, iconObj, countObj
end

-- Обычный и выделенный вид слота. Двумя строками в одном месте, потому что
-- «выделено» встречается в четырёх экранах, и разъехаться им нельзя.
function U.MarkSlot(e, selected)
    if not e then return end
    e.BorderColor = selected and U.C(U.AMBER, 0.95) or U.C(U.LINE, 0.7)
    e.Color = selected and U.C(U.AMBER, 0.14) or U.C(U.SURFACE, 0.95)
end

-- --- Подсказка под курсором --------------------------------------------------
--
-- Плашка, которая едет за мышью и объясняет, на что игрок смотрит. Нужна ровно
-- потому, что предметы в игре показаны ЗНАЧКАМИ: пока их было шесть, значок и
-- был именем, а с печкой, сундуком и топливом угадывать по картинке
-- «пластик это или ткань» стало нельзя.
--
-- Живёт на КОРНЕ экрана, а не в окне: её место под мышью, а мышь ходит по
-- всему кадру. Мышь она не ловит (Interactive не ставим) — иначе подсказка
-- закрывала бы собой то, о чём рассказывает.
--
-- Возвращает объект с методами Show/Hide: экрану не нужно знать, из чего она
-- собрана.
function U.Tooltip(root, name)
    local obj, panel = U.Panel(root, name or "Tooltip", UIAnchor.TopLeft, 0, 0, 220, 30)
    panel.Color = U.C(U.INK, 0.97)
    panel.BorderThickness = 1.0
    panel.BorderColor = U.C(U.LINE, 0.9)
    panel.Visible = false

    local _, title = U.Label(obj, (name or "Tooltip") .. " Title", UIAnchor.TopLeft, 10, 7,
                             200, 18, "", 1.35)
    local _, note = U.Label(obj, (name or "Tooltip") .. " Note", UIAnchor.TopLeft, 10, 27,
                            200, 16, "", 1.1)
    note.TextColor = U.C(U.MUTED)

    local T = {}

    -- text — что это, note — чем оно полезно (может быть nil).
    function T.Show(text, note2, color)
        if text == nil or text == "" then
            T.Hide()
            return
        end
        local c = sage.ui.Cursor()
        if c.x < 0.0 then
            T.Hide()
            return
        end
        title.Text = text
        title.TextColor = color or U.C(U.TEXT)
        note.Text = note2 or ""

        -- Ширина по самой длинной строке. Считаем по числу символов: точной
        -- ширины текста скрипту неоткуда взять, а плашка, растянутая под
        -- предполагаемый максимум, выглядит пустой при коротком имени.
        local chars = math.max(#text, #(note2 or ""))
        local w = math.max(120, math.min(360, 20 + chars * 7))
        local h = (note2 and note2 ~= "") and 46 or 28
        panel.Size = Vec2(w, h)

        -- Плашка стоит СПРАВА-СНИЗУ от курсора и отпрыгивает от краёв кадра:
        -- у нижней строки слотов место справа-снизу как раз кончается, и
        -- подсказка уезжала бы за экран ровно там, где она нужнее всего.
        local screen = sage.ui.ScreenSize()
        local x, y = c.x + 16, c.y + 18
        if x + w > screen.x - 8 then x = c.x - w - 12 end
        if y + h > screen.y - 8 then y = c.y - h - 12 end
        panel.Offset = Vec2(x, y)
        panel.Visible = true
    end

    function T.Hide() panel.Visible = false end

    return T
end

return U
