-- ---------------------------------------------------------------------------
-- hud.lua — интерфейс игры, собранный СКРИПТОМ из UI-компонентов движка.
--
-- Ни один элемент не расставлен в редакторе руками: панели, полосы и подписи
-- создаются здесь как обычные сущности сцены с UIElementComponent. Это не поза
-- ради чистоты — хотбар зависит от содержимого инвентаря, а он у игры свой,
-- так что «нарисовать заранее» всё равно не вышло бы.
--
-- Якоря и размеры — в пикселях от края экрана (см. UIAnchor движка): интерфейс
-- сам держится за свои углы при любом размере окна и одинаково выглядит в
-- панели Game редактора и в собранной игре.
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"

local H = {}

local els = {}          -- имя -> GameObject
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
    ui.Rounding = 4.0
    ui.Color = Vec4(0.05, 0.06, 0.09, 0.55)
    ui.TextScale = 1.6
    ui.TextColor = Vec4(0.95, 0.95, 0.92, 1.0)
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

    -- Прицел: две перекладины вместо квадрата — точка в центре экрана должна
    -- оставаться видимой, а не закрашиваться.
    local _, cx = newElement("Crosshair H", UIKind.Panel, UIAnchor.Center, 0, 0, 14, 2)
    cx.Color = Vec4(1.0, 1.0, 1.0, 0.75)
    cx.Rounding = 0.0
    local _, cy = newElement("Crosshair V", UIKind.Panel, UIAnchor.Center, 0, 0, 2, 14)
    cy.Color = Vec4(1.0, 1.0, 1.0, 0.75)
    cy.Rounding = 0.0

    -- Шкалы состояния — левый нижний угол.
    local bars = {
        {"Health",  0.86, 0.26, 0.24, 0},
        {"Hunger",  0.85, 0.62, 0.24, 22},
        {"Stamina", 0.45, 0.72, 0.90, 44},
        {"Oxygen",  0.35, 0.78, 0.95, 66},
    }
    for _, b in ipairs(bars) do
        local _, e = newElement(b[1] .. " Bar", UIKind.Bar, UIAnchor.BottomLeft,
                                18, 96 - b[5], 190, 16)
        e.BarFillColor = Vec4(b[2], b[3], b[4], 1.0)
        e.Color = Vec4(0.0, 0.0, 0.0, 0.5)
        e.Rounding = 7.0
        e.Value = 1.0
        e.Text = b[1]
        e.TextScale = 1.2
        e.TextCentered = true
    end
    -- Кислород показываем только под водой: постоянная полная полоса
    -- «сколько я не тону» — шум, а не информация.
    ui("Oxygen Bar").Visible = false

    -- Хотбар — снизу по центру, слот на каждый ставимый блок.
    local Inv = H.inventory
    local slotW, gap = 74, 6
    local total = #Inv.hotbar * slotW + (#Inv.hotbar - 1) * gap
    for i = 1, #Inv.hotbar do
        local x = -total * 0.5 + (i - 1) * (slotW + gap) + slotW * 0.5
        local _, e = newElement("Slot " .. i, UIKind.Panel, UIAnchor.BottomCenter,
                                x, 18, slotW, 46)
        e.Rounding = 6.0
        e.BorderThickness = 2.0
        e.BorderColor = Vec4(0.25, 0.25, 0.28, 0.8)
        e.TextScale = 1.2
        e.TextCentered = true
    end

    -- Задача, часы и сообщения.
    local _, obj = newElement("Objective", UIKind.Panel, UIAnchor.TopRight, 16, 16, 310, 78)
    obj.TextCentered = false
    obj.TextScale = 1.3
    obj.Text = ""

    local _, msg = newElement("Message", UIKind.Label, UIAnchor.TopCenter, 0, 78, 560, 30)
    msg.Color = Vec4(0.0, 0.0, 0.0, 0.0)
    msg.TextScale = 1.7
    msg.Text = ""

    local _, hit = newElement("Break Bar", UIKind.Bar, UIAnchor.Center, 0, 48, 130, 10)
    hit.BarFillColor = Vec4(0.92, 0.92, 0.88, 0.95)
    hit.Color = Vec4(0.0, 0.0, 0.0, 0.45)
    hit.Value = 0.0
    hit.Visible = false

    local _, look = newElement("Looking At", UIKind.Label, UIAnchor.Center, 0, 68, 320, 24)
    look.Color = Vec4(0.0, 0.0, 0.0, 0.0)
    look.TextScale = 1.2
    look.Text = ""

    -- Все элементы — дети HUD: удалить интерфейс можно одной сущностью, и в
    -- иерархии редактора он не размазан по корню сцены.
    for name, obj2 in pairs(els) do
        if name ~= "HUD" then obj2:SetParent(root) end
    end
end

function H.Message(text, seconds)
    local m = ui("Message")
    if m then m.Text = text end
    messageTimer = seconds or 3.0
end

function H.Update(dt, S, P, Inv, Boat)
    local h = ui("Health Bar")
    if h then
        h.Value = S.health / S.MAX_HEALTH
        h.Text = string.format("Здоровье %d", math.floor(S.health + 0.5))
    end
    local hu = ui("Hunger Bar")
    if hu then
        hu.Value = S.hunger / S.MAX_HUNGER
        hu.Text = string.format("Сытость %d", math.floor(S.hunger + 0.5))
    end
    local st = ui("Stamina Bar")
    if st then
        st.Value = S.stamina / S.MAX_STAMINA
        st.Text = "Силы"
    end
    local ox = ui("Oxygen Bar")
    if ox then
        ox.Visible = P.headInWater or S.oxygen < S.MAX_OXYGEN - 0.01
        ox.Value = S.oxygen / S.MAX_OXYGEN
        ox.Text = "Воздух"
    end

    for i = 1, #Inv.hotbar do
        local slot = ui("Slot " .. i)
        if slot then
            local id = Inv.hotbar[i]
            slot.Text = Blocks.Name(id) .. "\n" .. Inv.Count(id)
            if i == Inv.selected then
                slot.BorderColor = Vec4(0.98, 0.85, 0.35, 1.0)
                slot.Color = Vec4(0.16, 0.16, 0.10, 0.75)
            else
                slot.BorderColor = Vec4(0.25, 0.25, 0.28, 0.8)
                slot.Color = Vec4(0.05, 0.06, 0.09, 0.55)
            end
        end
    end

    local obj = ui("Objective")
    if obj then
        obj.Text = string.format("%s  %s\nЛодка: %d/%d досок, %d/%d парусов\n%s",
            S.Clock(), S.IsNight() and "ночь" or "день",
            Boat.planks, Boat.needPlanks, Boat.sails, Boat.needSails,
            Boat.ready and "Лодка готова! Нажми E у причала" or "Собери лодку на причале")
    end

    -- Полоса добычи и подпись под прицелом появляются только по делу.
    local bb = ui("Break Bar")
    local la = ui("Looking At")
    if P.target then
        local hard = Blocks.Hardness(P.target.id)
        if la then la.Text = Blocks.Name(P.target.id) end
        if bb then
            bb.Visible = P.breakProgress > 0.0 and hard ~= nil
            bb.Value = hard and math.min(1.0, P.breakProgress / hard) or 0.0
        end
    else
        if la then la.Text = "" end
        if bb then bb.Visible = false end
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
