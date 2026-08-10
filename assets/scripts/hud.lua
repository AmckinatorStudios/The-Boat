-- ---------------------------------------------------------------------------
-- hud.lua — то немногое, что видно на экране во время игры.
--
-- ПРАВИЛО ЭТОГО ЭКРАНА: на нём нет ничего, кроме того, без чего нельзя играть.
-- Игра про то, чтобы смотреть на воду, и всё, что закрывает воду, обязано
-- доказать своё право там находиться.
--
-- До этой правки на экране постоянно висели две карточки: шкалы слева и
-- «судовой журнал» справа — время, пройденный путь, число блоков корабля,
-- число плавающего мусора и три счётчика трюма. Одиннадцать чисел, из которых
-- в игре не нужно НИ ОДНО: путь и число блоков ни на что не влияют, а сколько
-- в трюме верёвки — вопрос, который возникает ровно в момент крафта, и место
-- ответу на него на верстаке (см. craft.lua), а не в углу экрана поверх заката.
--
-- Осталось: прицел, три шкалы, панель предметов, часы и то, что говорит с
-- игроком по делу — подсказка под прицелом и сообщение. Слов почти нет: игра
-- говорит значками.
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"
local Inv = require "inventory"
local U = require "ui"

local H = {}

local root
local els = {}
local messageTimer = 0.0
local pickTimer = 0.0      -- сколько ещё показывать имя выбранного предмета
local lastSelected = 0
local lastSelectedId = nil

local function keep(name, obj) els[name] = obj end

local function ui(name)
    local obj = els[name]
    if obj == nil or not obj:Valid() then return nil end
    return obj:GetUI()
end

-- Шкалы: сыт, напоён, согрет. Больше в игре про уют не нужно.
local VITALS = {
    {"Food",  "food",  {0.92, 0.72, 0.36}, 0.20},
    {"Water", "drop",  {0.42, 0.74, 0.94}, 0.20},
    {"Warm",  "flame", {0.96, 0.56, 0.36}, 0.25},
}

local SLOT, SLOT_GAP = 58, 8

function H.Build()
    root = U.Screen("HUD", 0)

    -- --- Прицел: четыре штриха вокруг пустого центра. Точка в середине
    -- закрывала бы ровно то, во что целишься.
    local marks = {{0, -8, 2, 6}, {0, 8, 2, 6}, {-8, 0, 6, 2}, {8, 0, 6, 2}}
    for i, m in ipairs(marks) do
        local _, e = U.Panel(root, "Aim " .. i, UIAnchor.Center, m[1], m[2], m[3], m[4])
        e.Color = Vec4(1.0, 1.0, 1.0, 0.5)
        e.Rounding = 1.0
    end
    -- Кольцо вокруг прицела — единственный ответ «в это можно ткнуть»; горит,
    -- только когда под прицелом действительно что-то есть.
    local ringObj, ring = U.Panel(root, "Aim Ring", UIAnchor.Center, 0, 0, 30, 30)
    ring.Rounding = 15.0
    ring.BorderThickness = 1.5
    ring.BorderColor = U.C(U.AMBER, 0.75)
    ring.Visible = false
    keep("Aim Ring", ringObj)

    -- --- Шкалы. БЕЗ КАРТОЧКИ ПОД НИМИ: подложка нужна тексту, а полосе со
    -- своим тёмным жёлобом — нет, и три шкалы на карточке выглядели приборной
    -- панелью там, где хватает трёх полосок у самого края.
    for i, v in ipairs(VITALS) do
        -- Смещение у нижнего якоря отсчитывается ВВЕРХ, поэтому первая шкала
        -- списка оказывается самой верхней: сытость, вода, тепло сверху вниз.
        local y = 16 + (#VITALS - i) * 22
        keep(v[1] .. " Icon",
             U.Icon(root, v[1] .. " Icon", UIAnchor.BottomLeft, 18, y, 16, v[2], U.C(v[3])))
        local barObj, bar = U.Bar(root, v[1] .. " Bar", UIAnchor.BottomLeft, 40, y + 3, 116, 10,
                                  U.C(v[3], 0.96))
        bar.ShadowSize = 8.0
        keep(v[1] .. " Bar", barObj)
    end

    -- --- Панель предметов: квадратные слоты со значком и счётчиком.
    -- Номеров на слотах нет: цифра на каждом — шесть подписей ради того, что
    -- запоминается с первого нажатия.
    local total = Inv.HOTBAR * SLOT + (Inv.HOTBAR - 1) * SLOT_GAP
    for i = 1, Inv.HOTBAR do
        local x = -total * 0.5 + (i - 1) * (SLOT + SLOT_GAP) + SLOT * 0.5
        local slotObj, iconObj, countObj =
            U.Slot(root, "Slot " .. i, UIAnchor.BottomCenter, x, 18, SLOT)
        keep("Slot " .. i, slotObj)
        keep("Slot " .. i .. " Icon", iconObj)
        keep("Slot " .. i .. " Count", countObj)
    end

    -- Имя выбранного предмета — над панелью, гаснет само: подпись под каждым
    -- слотом одновременно превратила бы панель в стену текста.
    local pickObj, pick = U.Label(root, "Pick", UIAnchor.BottomCenter, 0, 18 + SLOT + 10, 320, 18,
                                  "", 1.3)
    pick.TextCentered = true
    pick.TextColor = U.C(U.AMBER, 0.0)
    keep("Pick", pickObj)

    -- --- Часы: единственное число, которое игре есть смысл показывать
    -- постоянно. Закат — то, ради чего стоит доплыть до вечера, и знать,
    -- сколько до него осталось, — это про планы, а не про статистику.
    local clockObj, clock = U.Label(root, "Clock", UIAnchor.TopRight, 20, 18, 78, 22, "", 1.35)
    clock.Icon = "sun"
    clock.IconColor = U.C(U.AMBER)
    clock.PadX = 6.0
    keep("Clock", clockObj)

    -- --- Сообщение и подсказка ---------------------------------------------
    -- Обе — «таблетки» с автошириной: короткое «Плыви к лодке» не должно
    -- болтаться в панели, растянутой под самую длинную фразу игры.
    local msgObj, msg = U.Panel(root, "Message", UIAnchor.TopCenter, 0, 56, 200, 30)
    msg.Rounding = 15.0
    msg.AutoWidth = true
    msg.PadX = 14.0
    msg.Color = U.C(U.INK, 0.0)
    msg.GradientColor = U.C(U.INK_DEEP, 0.0)
    msg.TextScale = 1.45
    msg.TextColor = U.C(U.TEXT, 0.0)
    msg.IconColor = U.C(U.AMBER, 0.0)
    keep("Message", msgObj)

    local promptObj, prompt = U.Panel(root, "Prompt", UIAnchor.Center, 0, 54, 200, 28)
    prompt.Rounding = 14.0
    prompt.AutoWidth = true
    prompt.PadX = 12.0
    prompt.Color = U.C(U.INK, 0.0)
    prompt.GradientColor = U.C(U.INK_DEEP, 0.0)
    prompt.TextScale = 1.25
    prompt.TextColor = U.C(U.TEXT, 0.0)
    prompt.IconColor = U.C(U.TEXT, 0.0)
    keep("Prompt", promptObj)

    -- Полоса разбора — прямо под прицелом, узкая и без подложки: она живёт
    -- полсекунды, карточка под ней успела бы только мигнуть.
    local barObj, bar = U.Bar(root, "Break Bar", UIAnchor.Center, 0, 30, 108, 6, U.C(U.AMBER, 0.95))
    bar.Value = 0.0
    bar.Visible = false
    keep("Break Bar", barObj)
end

-- Спрятать худ целиком — одним полем на корне. Нужно меню и верстаку: поверх
-- открытого экрана прицел и шкалы только мешают.
function H.SetVisible(visible)
    if root ~= nil and root:Valid() then root:GetUI().Visible = visible end
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
    if value >= low then return U.C(base, 0.96) end
    local t = math.max(0.0, value / low)
    return Vec4(base[1] + (U.ALARM[1] - base[1]) * (1 - t),
                base[2] + (U.ALARM[2] - base[2]) * (1 - t),
                base[3] + (U.ALARM[3] - base[3]) * (1 - t), 0.98)
end

local function setPill(e, text, icon, alpha, iconColor)
    if not e then return end
    e.Text = text
    e.Icon = text ~= "" and (icon or "") or ""
    e.Color = U.C(U.INK, 0.62 * alpha)
    e.GradientColor = U.C(U.INK_DEEP, 0.5 * alpha)
    e.ShadowSize = alpha > 0.05 and 12.0 or 0.0
    e.TextColor = U.C(U.TEXT, alpha)
    e.IconColor = iconColor and Vec4(iconColor.x, iconColor.y, iconColor.z, alpha)
                            or U.C(U.AMBER, alpha)
end

function H.Update(dt, S, P, Inv)
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
        if icon then icon.IconColor = U.C(v[3], 0.45 + 0.55 * math.min(1.0, value * 1.6)) end
    end

    for i = 1, Inv.HOTBAR do
        local slot = ui("Slot " .. i)
        local icon = ui("Slot " .. i .. " Icon")
        local count = ui("Slot " .. i .. " Count")
        local id = Inv.SlotId(i)
        local have = Inv.SlotCount(i)
        local selected = (i == Inv.selected)
        if slot then
            -- Выбранный слот приподнят и обведён тёплым: рамка одна не читается
            -- на светлой воде, а сдвиг виден боковым зрением.
            slot.Offset = Vec2(slot.Offset.x, selected and 26 or 18)
            slot.BorderColor = selected and U.C(U.AMBER, 0.95) or Vec4(1, 1, 1, 0.10)
            slot.BorderThickness = selected and 2.0 or 1.5
            slot.Color = selected and U.C(U.AMBER, 0.16) or U.C(U.INK, 0.55)
            slot.GradientColor = selected and U.C(U.INK, 0.66) or U.C(U.INK_DEEP, 0.62)
        end
        if icon then
            -- ПУСТАЯ ЯЧЕЙКА ПУСТА. Раньше здесь висел бледный значок предмета,
            -- закреплённого за слотом, — но закреплять больше нечего: слот
            -- держит то, что в него положили, а не то, что решил код. Бледный
            -- значок в пустой ячейке вдобавок врал, будто предмет как бы есть.
            icon.Icon = id and Blocks.Icon(id) or ""
            if id then
                local c = Blocks.Color(id)
                icon.IconColor = Vec4(c.x, c.y, c.z, 1.0)
            end
        end
        if count then count.Text = have > 1 and tostring(have) or "" end
    end

    -- Имя выбранного предмета всплывает на секунду после переключения.
    local selectedId = Inv.SelectedBlock()
    if Inv.selected ~= lastSelected or selectedId ~= lastSelectedId then
        lastSelected = Inv.selected
        lastSelectedId = selectedId
        pickTimer = selectedId and 1.6 or 0.0
        local p = ui("Pick")
        if p then p.Text = selectedId and Blocks.Name(selectedId) or "" end
    end
    local pick = ui("Pick")
    if pick then
        pickTimer = math.max(0.0, pickTimer - dt)
        pick.TextColor = U.C(U.AMBER, math.min(1.0, pickTimer * 2.0))
    end

    local clock = ui("Clock")
    if clock then
        clock.Text = S.Clock()
        clock.Icon = S.IsNight() and "moon" or "sun"
        clock.IconColor = S.IsNight() and Vec4(0.72, 0.80, 0.95, 0.95) or U.C(U.AMBER)
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
