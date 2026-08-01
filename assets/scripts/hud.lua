-- ---------------------------------------------------------------------------
-- hud.lua — интерфейс, собранный скриптом из UI-компонентов движка.
--
-- Правило этого интерфейса: НЕ мешать смотреть на воду. Поэтому шкал три, а не
-- шесть; они прижаты в угол и подсвечиваются только когда есть о чём сказать;
-- прицел — четыре чёрточки вокруг пустого центра; подсказки появляются по делу
-- и уходят сами. Всё, что можно не показывать постоянно, не показывается.
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"

local H = {}

local els = {}
local messageTimer = 0.0
local root

local function newElement(name, kind, anchor, offx, offy, w, h)
    local obj = SpawnObject(name)
    SetMeshNone(obj)
    local ui = obj:AddUI()
    ui.Type = kind
    ui.Anchor = anchor
    ui.Offset = Vec2(offx, offy)
    ui.Size = Vec2(w, h)
    ui.Rounding = 5.0
    ui.Color = Vec4(0.04, 0.06, 0.10, 0.42)
    ui.TextScale = 1.5
    ui.TextColor = Vec4(0.96, 0.95, 0.92, 1.0)
    els[name] = obj
    return obj, ui
end

local function ui(name)
    local obj = els[name]
    if obj == nil or not obj:Valid() then return nil end
    return obj:GetUI()
end

function H.Build()
    root = SpawnObject("HUD")
    SetMeshNone(root)

    -- Прицел: четыре штриха вокруг пустого центра. Точка в середине экрана
    -- закрывала бы ровно то, во что целишься.
    local marks = {{0, -9, 2, 7}, {0, 9, 2, 7}, {-9, 0, 7, 2}, {9, 0, 7, 2}}
    for i, m in ipairs(marks) do
        local _, e = newElement("Aim " .. i, UIKind.Panel, UIAnchor.Center, m[1], m[2], m[3], m[4])
        e.Color = Vec4(1.0, 1.0, 1.0, 0.55)
        e.Rounding = 1.0
    end

    -- Три шкалы: сыт, напоён, согрет. Больше в игре про уют не нужно.
    local bars = {
        {"Food",  "Сытость", 0.86, 0.66, 0.32, 0},
        {"Water", "Жажда",   0.38, 0.70, 0.92, 22},
        {"Warm",  "Тепло",   0.94, 0.52, 0.34, 44},
    }
    for _, b in ipairs(bars) do
        local _, e = newElement(b[1] .. " Bar", UIKind.Bar, UIAnchor.BottomLeft,
                                18, 74 - b[6], 176, 16)
        e.BarFillColor = Vec4(b[3], b[4], b[5], 0.95)
        e.Color = Vec4(0.0, 0.0, 0.0, 0.38)
        e.Rounding = 7.0
        e.Value = 1.0
        e.Text = b[2]
        e.TextScale = 1.15
        e.TextCentered = true
    end

    local slotW, gap = 78, 6
    local total = #Blocks.hotbar * slotW + (#Blocks.hotbar - 1) * gap
    for i = 1, #Blocks.hotbar do
        local x = -total * 0.5 + (i - 1) * (slotW + gap) + slotW * 0.5
        local _, e = newElement("Slot " .. i, UIKind.Panel, UIAnchor.BottomCenter,
                                x, 16, slotW, 44)
        e.Rounding = 6.0
        e.BorderThickness = 2.0
        e.BorderColor = Vec4(0.28, 0.28, 0.30, 0.7)
        e.TextScale = 1.15
        e.TextCentered = true
    end

    local _, journal = newElement("Journal", UIKind.Panel, UIAnchor.TopRight, 16, 16, 292, 92)
    journal.TextCentered = false
    journal.TextScale = 1.25
    journal.Text = ""

    local _, msg = newElement("Message", UIKind.Label, UIAnchor.TopCenter, 0, 74, 620, 28)
    msg.Color = Vec4(0.0, 0.0, 0.0, 0.0)
    msg.TextScale = 1.6

    local _, prompt = newElement("Prompt", UIKind.Label, UIAnchor.Center, 0, 62, 400, 24)
    prompt.Color = Vec4(0.0, 0.0, 0.0, 0.0)
    prompt.TextScale = 1.25

    local _, bar = newElement("Break Bar", UIKind.Bar, UIAnchor.Center, 0, 40, 120, 8)
    bar.BarFillColor = Vec4(0.95, 0.93, 0.88, 0.95)
    bar.Color = Vec4(0.0, 0.0, 0.0, 0.35)
    bar.Value = 0.0
    bar.Visible = false

    for name, obj in pairs(els) do
        if name ~= "HUD" then obj:SetParent(root) end
    end
end

function H.Message(text, seconds)
    local m = ui("Message")
    if m then m.Text = text end
    messageTimer = seconds or 3.0
end

local function needColor(value, low)
    -- Шкала подсвечивается, только когда близка к нулю: постоянный красный
    -- цвет в углу — это тревога, а игра сделана ровно про её отсутствие.
    if value < low then return Vec4(0.95, 0.42, 0.32, 1.0) end
    return nil
end

function H.Update(dt, S, P, Inv, Debris, Ship)
    local bars = {
        {"Food Bar", S.food / S.MAX_FOOD, "Сытость", 0.20},
        {"Water Bar", S.water / S.MAX_WATER, "Жажда", 0.20},
        {"Warm Bar", S.warm / S.MAX_WARM, "Тепло", 0.25},
    }
    for _, b in ipairs(bars) do
        local e = ui(b[1])
        if e then
            e.Value = b[2]
            e.Text = b[3]
            local warn = needColor(b[2], b[4])
            if warn then e.BarFillColor = warn end
        end
    end

    for i = 1, #Blocks.hotbar do
        local slot = ui("Slot " .. i)
        if slot then
            local id = Blocks.hotbar[i]
            slot.Text = Blocks.Name(id) .. "\n" .. Inv.Count(id)
            if i == Inv.selected then
                slot.BorderColor = Vec4(0.98, 0.86, 0.48, 1.0)
                slot.Color = Vec4(0.14, 0.13, 0.09, 0.62)
            else
                slot.BorderColor = Vec4(0.28, 0.28, 0.30, 0.7)
                slot.Color = Vec4(0.04, 0.06, 0.10, 0.42)
            end
        end
    end

    local j = ui("Journal")
    if j then
        j.Text = string.format("%s  %s\nПройдено: %.0f м\nВ трюме: обломки %d, верёвка %d, пластик %d\nНа палубе: %d блоков, мусора рядом: %d",
            S.Clock(), S.IsNight() and "ночь" or "день", Ship.drift,
            Inv.Count(Blocks.SCRAP), Inv.Count(Blocks.ROPE), Inv.Count(Blocks.PLASTIC),
            Ship.BlockCount(), Debris.Count())
    end

    -- Подсказка под прицелом: что перед тобой и что с этим можно сделать.
    local prompt = ui("Prompt")
    local bar = ui("Break Bar")
    if prompt then
        if P.aimDebris then
            prompt.Text = P.aimDebris.kind.name .. "   [E] подобрать"
        elseif P.target then
            prompt.Text = Blocks.Name(P.target.id) .. "   [ЛКМ] разобрать"
        elseif P.overboard then
            prompt.Text = "Плыви к лодке"
        else
            prompt.Text = ""
        end
    end
    if bar then
        local hard = P.target and Blocks.Hardness(P.target.id)
        bar.Visible = P.breakProgress > 0.0 and hard ~= nil
        bar.Value = hard and math.min(1.0, P.breakProgress / hard) or 0.0
    end

    if messageTimer > 0.0 then
        messageTimer = messageTimer - dt
        if messageTimer <= 0.0 then
            local m = ui("Message")
            if m then m.Text = "" end
        end
    end
end

return H
