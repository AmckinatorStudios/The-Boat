-- ---------------------------------------------------------------------------
-- hud.lua — интерфейс, собранный скриптом из UI-компонентов движка.
--
-- Правило этого интерфейса: НЕ мешать смотреть на воду и говорить иконками.
-- Слов на экране почти нет — три шкалы со значками у левого нижнего угла,
-- панель предметов по центру, судовой журнал справа сверху. Всё на карточках
-- с мягкой тенью и вертикальным градиентом: без них панель сливается с морем,
-- и любой текст на пёстрой воде читается плохо.
--
-- Ни одной картинки на диске: значки — векторные иконки движка
-- (sage::ui::IconNames), имя иконки предмет несёт сам (Blocks.Icon).
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"

local H = {}

local els = {}
local rootless = {}        -- элементы без родителя: их подхватывает корень HUD
local messageTimer = 0.0
local pickTimer = 0.0      -- сколько ещё показывать имя выбранного предмета
local lastSelected = 0
local root

-- --- Палитра ---------------------------------------------------------------
-- Ночное стекло с тёплым акцентом: холодная тёмная подложка не спорит с водой,
-- а всё, на что надо смотреть (выбранный слот, подсказка), тёплое.
local INK       = {0.05, 0.08, 0.13}
local INK_DEEP  = {0.02, 0.03, 0.06}
local AMBER     = {0.99, 0.82, 0.48}
local TEXT      = {0.95, 0.94, 0.90}
local MUTED     = {0.68, 0.73, 0.79}
local ALARM     = {0.96, 0.45, 0.35}

local function C(rgb, a) return Vec4(rgb[1], rgb[2], rgb[3], a or 1.0) end

-- --- Сборка элементов ------------------------------------------------------

local function newElement(name, kind, anchor, offx, offy, w, h, parent)
    local obj = SpawnObject(name)
    SetMeshNone(obj)
    local ui = obj:AddUI()
    ui.Type = kind
    ui.Anchor = anchor
    ui.Offset = Vec2(offx, offy)
    ui.Size = Vec2(w, h)
    ui.Rounding = 8.0
    ui.Color = Vec4(0, 0, 0, 0)
    ui.TextScale = 1.3
    ui.TextColor = C(TEXT)
    ui.TextCentered = false
    ui.IconColor = C(TEXT)
    els[name] = obj
    if parent then obj:SetParent(parent) else rootless[#rootless + 1] = obj end
    return obj, ui
end

-- Карточка: подложка с градиентом и тенью. Всё, что живёт на экране постоянно,
-- сидит на такой — одинаковая «глубина» у всех углов интерфейса.
local function newCard(name, anchor, offx, offy, w, h)
    local obj, e = newElement(name, UIKind.Panel, anchor, offx, offy, w, h)
    e.Rounding = 14.0
    e.Color = C(INK, 0.56)
    e.GradientColor = C(INK_DEEP, 0.44)
    e.ShadowSize = 18.0
    e.BorderThickness = 1.0
    e.BorderColor = Vec4(1.0, 1.0, 1.0, 0.07)
    return obj, e
end

-- Строка «иконка + текст» внутри карточки: панель без заливки, движок сам
-- ставит иконку у левого края и сдвигает текст за неё.
local function newRow(name, parent, x, y, w, h, icon)
    local obj, e = newElement(name, UIKind.Panel, UIAnchor.TopLeft, x, y, w, h, parent)
    e.Icon = icon
    e.IconColor = C(MUTED)
    e.TextScale = 1.2
    e.TextColor = C(TEXT, 0.92)
    e.PadX = 7.0
    return obj, e
end

local function ui(name)
    local obj = els[name]
    if obj == nil or not obj:Valid() then return nil end
    return obj:GetUI()
end

local VITALS = {
    {"Food",  "food",  {0.92, 0.72, 0.36}, 0.20},
    {"Water", "drop",  {0.42, 0.74, 0.94}, 0.20},
    {"Warm",  "flame", {0.96, 0.56, 0.36}, 0.25},
}

local SLOT, SLOT_GAP = 64, 8

function H.Build()
    root = SpawnObject("HUD")
    SetMeshNone(root)

    -- --- Прицел: четыре штриха вокруг пустого центра. Точка в середине
    -- закрывала бы ровно то, во что целишься.
    local marks = {{0, -8, 2, 6}, {0, 8, 2, 6}, {-8, 0, 6, 2}, {8, 0, 6, 2}}
    for i, m in ipairs(marks) do
        local _, e = newElement("Aim " .. i, UIKind.Panel, UIAnchor.Center, m[1], m[2], m[3], m[4])
        e.Color = Vec4(1.0, 1.0, 1.0, 0.5)
        e.Rounding = 1.0
    end
    -- Кольцо вокруг прицела — единственный ответ «в это можно ткнуть»; горит,
    -- только когда под прицелом действительно что-то есть.
    local _, ring = newElement("Aim Ring", UIKind.Panel, UIAnchor.Center, 0, 0, 30, 30)
    ring.Color = Vec4(0, 0, 0, 0)
    ring.Rounding = 15.0
    ring.BorderThickness = 1.5
    ring.BorderColor = C(AMBER, 0.75)
    ring.Visible = false

    -- --- Шкалы: сыт, напоён, согрет. Больше в игре про уют не нужно.
    local vitalsCard = newCard("Vitals", UIAnchor.BottomLeft, 16, 16, 248, 98)
    for i, v in ipairs(VITALS) do
        local y = 12 + (i - 1) * 26
        local _, icon = newElement(v[1] .. " Icon", UIKind.Icon, UIAnchor.TopLeft,
                                   12, y, 20, 20, vitalsCard)
        icon.Icon = v[2]
        icon.IconColor = C(v[3])

        local _, bar = newElement(v[1] .. " Bar", UIKind.Bar, UIAnchor.TopLeft,
                                  40, y + 3, 196, 14, vitalsCard)
        bar.Rounding = 7.0
        bar.Color = Vec4(0, 0, 0, 0.34)
        bar.BarFillColor = C(v[3], 0.96)
        bar.Value = 1.0
    end

    -- --- Панель предметов: квадратные слоты со значком предмета и счётчиком.
    local total = #Blocks.hotbar * SLOT + (#Blocks.hotbar - 1) * SLOT_GAP
    for i = 1, #Blocks.hotbar do
        local x = -total * 0.5 + (i - 1) * (SLOT + SLOT_GAP) + SLOT * 0.5
        local slotObj, slot = newElement("Slot " .. i, UIKind.Panel, UIAnchor.BottomCenter,
                                         x, 18, SLOT, SLOT)
        slot.Rounding = 12.0
        slot.Color = C(INK, 0.52)
        slot.GradientColor = C(INK_DEEP, 0.62)
        slot.BorderThickness = 1.5
        slot.BorderColor = Vec4(1.0, 1.0, 1.0, 0.10)
        slot.ShadowSize = 12.0

        local _, icon = newElement("Slot Icon " .. i, UIKind.Icon, UIAnchor.Center,
                                   0, -5, 32, 32, slotObj)
        icon.Icon = Blocks.Icon(Blocks.hotbar[i])
        icon.IconColor = Vec4(1, 1, 1, 1)

        -- Номер слота — бледной цифрой в углу: клавиша, которой он берётся.
        local _, num = newElement("Slot Num " .. i, UIKind.Label, UIAnchor.TopLeft,
                                  7, 4, 14, 12, slotObj)
        num.Text = tostring(i)
        num.TextScale = 0.95
        num.TextColor = C(MUTED, 0.55)

        local _, count = newElement("Slot Count " .. i, UIKind.Label, UIAnchor.BottomCenter,
                                    0, 5, SLOT, 13, slotObj)
        count.TextCentered = true
        count.TextScale = 1.1
        count.TextColor = C(TEXT, 0.9)
    end

    -- Имя выбранного предмета — над панелью, гаснет само: подпись под каждым
    -- слотом одновременно превратила бы панель в стену текста.
    local _, pick = newElement("Pick", UIKind.Label, UIAnchor.BottomCenter, 0, 18 + SLOT + 10, 320, 18)
    pick.TextCentered = true
    pick.TextScale = 1.3
    pick.TextColor = C(AMBER, 0.0)

    -- --- Судовой журнал: время, пройденный путь, корабль, трюм.
    -- Строки высокие (24 px) не ради воздуха: иконка внутри строки — квадрат в
    -- её высоту, и на двадцати пикселях компас и лодка схлопываются в кляксу.
    local journal = newCard("Journal", UIAnchor.TopRight, 16, 16, 258, 128)
    local _, clock = newRow("Row Clock", journal, 8, 10, 240, 24, "clock")
    clock.TextScale = 1.3
    clock.TextColor = C(TEXT)
    local _, phase = newElement("Row Phase", UIKind.Icon, UIAnchor.TopRight, 10, 12, 22, 22, journal)
    phase.Icon = "sun"
    phase.IconColor = C(AMBER)

    newRow("Row Drift", journal, 8, 38, 240, 24, "compass")
    newRow("Row Ship", journal, 8, 66, 240, 24, "boat")

    -- Трюм — три значка с числами в ряд: это опись, а не предложение.
    local hold = {{"Hold Scrap", Blocks.SCRAP}, {"Hold Rope", Blocks.ROPE},
                  {"Hold Plastic", Blocks.PLASTIC}}
    for i, h in ipairs(hold) do
        local _, e = newRow(h[1], journal, 8 + (i - 1) * 80, 94, 76, 24, Blocks.Icon(h[2]))
        e.IconColor = Blocks.Color(h[2])
        e.TextScale = 1.15
    end

    -- --- Сообщение и подсказка -------------------------------------------
    -- Обе — «таблетки» с автошириной: короткое «Плыви к лодке» не должно
    -- болтаться в панели, растянутой под самую длинную фразу игры.
    local _, msg = newElement("Message", UIKind.Panel, UIAnchor.TopCenter, 0, 64, 200, 30)
    msg.Rounding = 15.0
    msg.AutoWidth = true
    msg.PadX = 14.0
    msg.Color = C(INK, 0.0)
    msg.GradientColor = C(INK_DEEP, 0.0)
    msg.ShadowSize = 0.0
    msg.TextScale = 1.45
    msg.TextColor = C(TEXT, 0.0)
    msg.Icon = ""
    msg.IconColor = C(AMBER)

    local _, prompt = newElement("Prompt", UIKind.Panel, UIAnchor.Center, 0, 54, 200, 28)
    prompt.Rounding = 14.0
    prompt.AutoWidth = true
    prompt.PadX = 12.0
    prompt.Color = C(INK, 0.0)
    prompt.GradientColor = C(INK_DEEP, 0.0)
    prompt.TextScale = 1.25
    prompt.TextColor = C(TEXT, 0.0)
    prompt.IconColor = C(TEXT, 0.0)

    -- Полоса разбора — прямо под прицелом, узкая и без подложки: она живёт
    -- полсекунды, карточка под ней успела бы только мигнуть.
    local _, bar = newElement("Break Bar", UIKind.Bar, UIAnchor.Center, 0, 30, 108, 6)
    bar.Rounding = 3.0
    bar.BarFillColor = C(AMBER, 0.95)
    bar.Color = Vec4(0.0, 0.0, 0.0, 0.4)
    bar.Value = 0.0
    bar.Visible = false

    -- Всё, что не легло в карточку, вешаем на корень — одна сущность прячет
    -- или показывает весь интерфейс разом.
    for _, obj in ipairs(rootless) do obj:SetParent(root) end
end

function H.Message(text, seconds, icon)
    local m = ui("Message")
    if m then
        m.Text = text
        m.Icon = icon or "warn"
    end
    messageTimer = seconds or 3.0
end

-- Цвет шкалы: спокойный, пока есть запас, тревожный — когда его почти нет.
-- Постоянный красный в углу — это тревога, а игра сделана ровно про её
-- отсутствие.
local function vitalColor(value, low, base)
    if value >= low then return C(base, 0.96) end
    local t = math.max(0.0, value / low)
    return Vec4(base[1] + (ALARM[1] - base[1]) * (1 - t),
                base[2] + (ALARM[2] - base[2]) * (1 - t),
                base[3] + (ALARM[3] - base[3]) * (1 - t), 0.98)
end

local function setPill(e, text, icon, alpha, iconColor)
    if not e then return end
    e.Text = text
    e.Icon = text ~= "" and (icon or "") or ""
    e.Color = C(INK, 0.62 * alpha)
    e.GradientColor = C(INK_DEEP, 0.5 * alpha)
    e.ShadowSize = alpha > 0.05 and 12.0 or 0.0
    e.TextColor = C(TEXT, alpha)
    e.IconColor = iconColor and Vec4(iconColor.x, iconColor.y, iconColor.z, alpha)
                            or C(AMBER, alpha)
end

-- Разряды тысяч: «1 240 м» читается с одного взгляда, «1240 м» — нет.
local function grouped(n)
    local s = string.format("%.0f", n)
    local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
    return (out:gsub("^%s+", ""))
end

function H.Update(dt, S, P, Inv, Debris, Ship)
    local values = {S.food / S.MAX_FOOD, S.water / S.MAX_WATER, S.warm / S.MAX_WARM}
    for i, v in ipairs(VITALS) do
        local bar = ui(v[1] .. " Bar")
        local icon = ui(v[1] .. " Icon")
        local value = values[i]
        if bar then
            bar.Value = value
            bar.BarFillColor = vitalColor(value, v[4], v[3])
        end
        -- Значок гаснет вместе со шкалой: полупустая полоса и яркий значок
        -- рядом с ней говорят разное.
        if icon then icon.IconColor = C(v[3], 0.45 + 0.55 * math.min(1.0, value * 1.6)) end
    end

    for i = 1, #Blocks.hotbar do
        local slot = ui("Slot " .. i)
        local icon = ui("Slot Icon " .. i)
        local count = ui("Slot Count " .. i)
        local id = Blocks.hotbar[i]
        local have = Inv.Count(id)
        local selected = (i == Inv.selected)
        if slot then
            -- Выбранный слот приподнят и обведён тёплым: рамка одна не читается
            -- на светлой воде, а сдвиг виден боковым зрением.
            slot.Offset = Vec2(slot.Offset.x, selected and 26 or 18)
            slot.BorderColor = selected and C(AMBER, 0.95) or Vec4(1, 1, 1, 0.10)
            slot.BorderThickness = selected and 2.0 or 1.5
            slot.Color = selected and C(AMBER, 0.16) or C(INK, 0.52)
            slot.GradientColor = selected and C(INK, 0.66) or C(INK_DEEP, 0.62)
            slot.ShadowSize = selected and 18.0 or 12.0
        end
        if icon then
            -- Пустой слот показан бледным значком, а не пустотой: место в
            -- панели закреплено за предметом, даже когда его нет.
            local c = Blocks.Color(id)
            local a = have > 0 and 1.0 or 0.28
            icon.IconColor = Vec4(c.x, c.y, c.z, a)
        end
        if count then
            count.Text = have > 0 and tostring(have) or ""
            count.TextColor = C(TEXT, 0.9)
        end
    end

    -- Имя выбранного предмета всплывает на секунду после переключения.
    if Inv.selected ~= lastSelected then
        lastSelected = Inv.selected
        pickTimer = 1.6
        local p = ui("Pick")
        if p then p.Text = Blocks.Name(Inv.SelectedBlock()) end
    end
    local pick = ui("Pick")
    if pick then
        pickTimer = math.max(0.0, pickTimer - dt)
        pick.TextColor = C(AMBER, math.min(1.0, pickTimer * 2.0))
    end

    local clock = ui("Row Clock")
    if clock then clock.Text = S.Clock() end
    local phase = ui("Row Phase")
    if phase then
        phase.Icon = S.IsNight() and "moon" or "sun"
        phase.IconColor = S.IsNight() and Vec4(0.72, 0.80, 0.95, 0.95) or C(AMBER)
    end
    local drift = ui("Row Drift")
    if drift then drift.Text = grouped(Ship.drift) .. " м" end
    local ship = ui("Row Ship")
    if ship then
        ship.Text = string.format("%d блоков  ·  мусор %d", Ship.BlockCount(), Debris.Count())
    end
    local hold = {{"Hold Scrap", Blocks.SCRAP}, {"Hold Rope", Blocks.ROPE},
                  {"Hold Plastic", Blocks.PLASTIC}}
    for _, h in ipairs(hold) do
        local e = ui(h[1])
        if e then
            local n = Inv.Count(h[2])
            e.Text = tostring(n)
            local c = Blocks.Color(h[2])
            e.IconColor = Vec4(c.x, c.y, c.z, n > 0 and 1.0 or 0.35)
            e.TextColor = C(TEXT, n > 0 and 0.92 or 0.45)
        end
    end

    -- Подсказка под прицелом: что перед тобой и что с этим можно сделать.
    local prompt = ui("Prompt")
    local ring = ui("Aim Ring")
    local aimed = false
    if prompt then
        if P.aimDebris then
            setPill(prompt, P.aimDebris.kind.name .. "   E подобрать", "hook", 1.0)
            aimed = true
        elseif P.target then
            local c = Blocks.Color(P.target.id)
            setPill(prompt, Blocks.Name(P.target.id) .. "   ЛКМ разобрать",
                    Blocks.Icon(P.target.id), 1.0, c)
            aimed = true
        elseif P.overboard then
            setPill(prompt, "Плыви к лодке", "boat", 1.0)
        else
            setPill(prompt, "", nil, 0.0)
        end
    end
    if ring then ring.Visible = aimed end

    local bar = ui("Break Bar")
    if bar then
        local hard = P.target and Blocks.Hardness(P.target.id)
        bar.Visible = P.breakProgress > 0.0 and hard ~= nil
        bar.Value = hard and math.min(1.0, P.breakProgress / hard) or 0.0
    end

    local m = ui("Message")
    if m then
        if messageTimer > 0.0 then
            messageTimer = messageTimer - dt
            -- Гаснет последние полсекунды, а не пропадает кадром.
            setPill(m, m.Text, m.Icon, math.min(1.0, messageTimer * 2.0))
        else
            setPill(m, "", nil, 0.0)
        end
    end
end

return H
