-- ---------------------------------------------------------------------------
-- game.lua — точка входа «The Boat». Висит на сущности World в main.sage.
--
-- Обязанностей три: собрать игру из модулей и связать их хуками, объявить
-- раскладку и раз в кадр прокрутить цикл в понятном порядке. Порядок важен:
-- сперва вода (она задаёт высоту всему), затем корабль (он на ней качается),
-- затем игрок (он стоит на корабле), затем мусор и интерфейс.
--
-- Ни строчки C++: бесконечный океан с волнами, корабль как сетка блоков,
-- плавучий мусор на настоящей физике движка, стройка, крафт, шкалы и смена
-- суток — всё это скрипты поверх обычного ECS.
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"
local Ocean  = require "ocean"
local Ship   = require "ship"
local P      = require "player"
local Debris = require "debris"
local S      = require "survival"
local Inv    = require "inventory"
local HUD    = require "hud"

local autopilot = nil
local started = false
local statusTimer = 0.0
local purifyTimer = 0.0
local fishTimer = 0.0
local lanterns = {}     -- мировые координаты фонарей (тепло + свет)
local nets = {}         -- мировые координаты сетей (притягивают мусор)
local structureDirty = true

-- --- Раскладка --------------------------------------------------------------
local function bindControls()
    BindAction("Move Forward", {"W", "UP"})
    BindAction("Move Back",    {"S", "DOWN"})
    BindAction("Move Left",    {"A", "LEFT"})
    BindAction("Move Right",   {"D", "RIGHT"})
    BindAction("Jump",         "SPACE")
    BindAction("Sprint",       "LEFT_CONTROL")
    BindAction("Crouch",       "LEFT_SHIFT")
    BindAction("Break",        "MOUSE_LEFT")
    BindAction("Place",        "MOUSE_RIGHT")
    BindAction("Use",          "E")
    BindAction("Eat",          "F")
    BindAction("Drink",        "G")
    BindAction("Fish",         "R")
    for i = 1, 8 do BindAction("Craft " .. i, tostring(i)) end
    BindAction("Slot Next",    "TAB")
end

-- --- Ввод -------------------------------------------------------------------
local MOUSE_SENS = 0.11

local function blankInput()
    return {
        moveF = 0.0, moveR = 0.0, jump = false, sprint = false, crouch = false,
        lookX = 0.0, lookY = 0.0,
        breakHeld = false, placePressed = false, usePressed = false,
        eatPressed = false, drinkPressed = false, fishPressed = false,
        craft = nil, cycleSlot = false,
    }
end

local function readInput()
    local input = blankInput()
    if IsActionDown("Move Forward") then input.moveF = input.moveF + 1.0 end
    if IsActionDown("Move Back")    then input.moveF = input.moveF - 1.0 end
    if IsActionDown("Move Right")   then input.moveR = input.moveR + 1.0 end
    if IsActionDown("Move Left")    then input.moveR = input.moveR - 1.0 end
    input.jump = IsActionDown("Jump")
    input.sprint = IsActionDown("Sprint")
    input.crouch = IsActionDown("Crouch")
    input.breakHeld = IsActionDown("Break")
    input.placePressed = WasActionPressed("Place")
    input.usePressed = WasActionPressed("Use")
    input.eatPressed = WasActionPressed("Eat")
    input.drinkPressed = WasActionPressed("Drink")
    input.fishPressed = WasActionPressed("Fish")
    input.cycleSlot = WasActionPressed("Slot Next")

    if IsMouseCaptured() then
        local d = GetMouseDelta()
        input.lookX = d.x * MOUSE_SENS
        input.lookY = d.y * MOUSE_SENS
    end
    local scroll = GetScrollDelta()
    if scroll ~= 0 then Inv.Cycle(scroll) end
    for i = 1, #Inv.recipes do
        if WasActionPressed("Craft " .. i) then input.craft = i end
    end
    return input
end

-- --- Хуки между модулями ----------------------------------------------------
local function splash(wx, wy, wz, color, count)
    local cfg = ParticlePresets.WaterSplash()
    cfg.StartColor = Vec4(color.x, color.y, color.z, 0.95)
    cfg.EndColor = Vec4(color.x * 0.7, color.y * 0.8, color.z, 0.0)
    EmitParticles(cfg, Vec3(wx, wy, wz), count or 12)
end

local function onCollectDebris(it)
    local loot, name = Debris.Collect(it)
    if not loot then return end
    Inv.AddLoot(loot)
    local parts = {}
    for _, entry in ipairs(loot) do
        parts[#parts + 1] = Blocks.Name(entry[1]) .. " x" .. entry[2]
    end
    HUD.Message(name .. ": " .. table.concat(parts, ", "), 2.2)
end

local function onBreak(x, y, z, id)
    local wx, wy, wz = Ship.LocalToWorld(x + 0.5, y + 0.5, z + 0.5)
    local cfg = ParticlePresets.BlockBreak()
    local c = Blocks.Color(id)
    cfg.StartColor = Vec4(c.x, c.y, c.z, 1.0)
    cfg.EndColor = Vec4(c.x * 0.6, c.y * 0.6, c.z * 0.6, 0.0)
    EmitParticles(cfg, Vec3(wx, wy, wz), 12)
    -- Разобранный блок возвращается материалом: разбирать свой корабль — такой
    -- же законный способ добыть доску, как выловить её из воды.
    Inv.Add(id, 1)
    HUD.Message("Разобрано: " .. Blocks.Name(id), 1.6)
    structureDirty = true
    if autopilot then autopilot.NoteBroken() end
end

local function onPlace(x, y, z, id)
    structureDirty = true
    if id == Blocks.LANTERN then HUD.Message("Фонарь зажжён", 2.0) end
    if autopilot then autopilot.NotePlaced() end
end

local function onOverboard()
    HUD.Message("За бортом! Плыви к лодке", 3.5)
    local wx, wy, wz = P.WorldPos()
    splash(wx, wy, wz, Vec3(0.6, 0.8, 0.9), 24)
end

local function onAboard()
    HUD.Message("Снова на палубе", 2.0)
end

-- Пересчитать «инфраструктуру» палубы: где фонари (тепло/свет), где сети
-- (притягивают мусор), где опреснители. Считается только после перестройки —
-- каждый кадр перебирать всю сетку незачем.
local function rescanStructures()
    lanterns, nets = {}, {}
    local purifiers = 0
    for x = Ship.MIN_X, Ship.MAX_X do
        for z = Ship.MIN_Z, Ship.MAX_Z do
            for y = Ship.MIN_Y, Ship.MAX_Y do
                local id = Ship.Get(x, y, z)
                if id == Blocks.LANTERN then
                    lanterns[#lanterns + 1] = {x + 0.5, y + 0.5, z + 0.5}
                elseif id == Blocks.NET then
                    local wx, wy, wz = Ship.LocalToWorld(x + 0.5, y + 0.5, z + 0.5)
                    nets[#nets + 1] = {wx, wy, wz}
                elseif id == Blocks.PURIFIER then
                    purifiers = purifiers + 1
                end
            end
        end
    end
    return purifiers
end

local purifierCount = 0

-- --- Старт ------------------------------------------------------------------
function OnStart(entity)
    local seed = tonumber(LaunchArg("seed") or "") or 20240517
    log("THEBOAT: старт, seed=" .. seed)

    -- Время суток можно задать снаружи (--time=0.82 — закат). Нужно и для
    -- скриншотов, и чтобы проверять ночные механики, не досиживая до ночи.
    local t0 = tonumber(LaunchArg("time") or "")
    if t0 then S.time = t0 % 1.0 end

    bindControls()
    SetMouseCaptured(true)

    local tiles = Ocean.Build()
    local blocks = Ship.Init()
    log(string.format("THEBOAT: океан %d плиток, корабль %d блоков", tiles, blocks))

    P.Init{
        inventory = Inv,
        hooks = {
            OnBreak = onBreak, OnPlace = onPlace,
            OnOverboard = onOverboard, OnAboard = onAboard,
            AimDebris = function(...) return Debris.Aim(...) end,
            CollectDebris = onCollectDebris,
        },
    }
    Debris.Init{seed = seed}
    S.Init{ship = Ship}

    HUD.Build()
    HUD.Message("Океан во все стороны. Лови, что несёт течением.", 7.0)
    purifierCount = rescanStructures()
    structureDirty = false

    -- Первый кадр океан должен быть уже на волне, а не плоским листом.
    Ocean.Update(0.0, Ship.pos.x, Ship.pos.z)
    Ship.Update(0.0)
    S.UpdateSky()

    if LaunchFlag("autopilot") then
        autopilot = require "autopilot"
        autopilot.Init{ship = Ship, player = P, inventory = Inv, debris = Debris,
                       survival = S, log = log}
    end

    started = true
    log("THEBOAT: READY")
end

-- --- Действия, не относящиеся к движению ------------------------------------
local function handleActions(dt, input)
    if input.cycleSlot then Inv.Cycle(1) end

    if input.craft then
        local recipe = Inv.recipes[input.craft]
        if recipe then
            local ok, text = Inv.Craft(recipe)
            HUD.Message(text, 2.2)
        end
    end

    if input.eatPressed then
        local id, value = Inv.EatBest()
        if id then
            S.Feed(value)
            HUD.Message(Blocks.Name(id) .. ": сытость +" .. math.floor(value), 2.0)
        else
            HUD.Message("Нечего есть — лови рыбу или собирай водоросли", 2.4)
        end
    end

    if input.drinkPressed then
        local id, value = Inv.DrinkBest()
        if id then
            S.Drink(value)
            HUD.Message("Пресная вода: жажда +" .. math.floor(value), 2.0)
        else
            HUD.Message("Нет пресной воды — нужен опреснитель", 2.4)
        end
    end

    -- Рыбалка: удочка + стоять у борта. Ждать приходится — это и есть занятие.
    if input.fishPressed then
        if not Inv.Has(Blocks.ROD) then
            HUD.Message("Нужна удочка (крафт 7)", 2.4)
        elseif fishTimer > 0.0 then
            HUD.Message(string.format("Клюёт... %.0f с", fishTimer), 1.5)
        else
            fishTimer = 7.0
            HUD.Message("Закинул удочку", 2.0)
        end
    end
    if fishTimer > 0.0 then
        fishTimer = fishTimer - dt
        if fishTimer <= 0.0 then
            Inv.Add(Blocks.FISH, 1)
            HUD.Message("Поймана рыба!", 2.5)
            local wx, wy, wz = P.WorldPos()
            splash(wx, wy - 0.5, wz, Vec3(0.7, 0.85, 0.95), 14)
        end
    end

    -- Опреснитель работает сам, пока стоит на палубе.
    if purifierCount > 0 then
        purifyTimer = purifyTimer + dt * purifierCount
        if purifyTimer >= 18.0 then
            purifyTimer = 0.0
            Inv.Add(Blocks.WATER, 1)
        end
    end
end

-- --- Кадр -------------------------------------------------------------------
function OnUpdate(entity, dt)
    if not started then return end
    if dt > 0.1 then dt = 0.1 end

    local input
    if autopilot then input = autopilot.Update(dt) else input = readInput() end

    -- Порядок: вода -> корабль -> игрок -> мусор. Каждый следующий стоит на
    -- предыдущем, и перестановка мест ломает ровно то, что от неё зависит.
    Ship.waiting = P.overboard
    Ocean.Update(dt, Ship.pos.x, Ship.pos.z)
    Ship.Update(dt)
    P.Update(dt, input)
    Debris.Update(dt)
    if #nets > 0 then Debris.NetPull(nets, dt) end

    handleActions(dt, input)
    S.Update(dt, P, input, lanterns)

    if structureDirty then
        purifierCount = rescanStructures()
        structureDirty = false
    end

    HUD.Update(dt, S, P, Inv, Debris, Ship)

    statusTimer = statusTimer - dt
    if statusTimer <= 0.0 then
        statusTimer = 5.0
        log(string.format("THEBOAT: t=%s путь=%.0f поз=(%.1f %.1f %.1f)%s палуба=%d " ..
                          "мусор=%d(собрано %d) сыт=%.0f вода=%.0f тепло=%.0f %s%s",
            S.Clock(), Ship.drift, P.pos.x, P.pos.y, P.pos.z,
            P.overboard and " ЗАБОРТ" or "", Ship.BlockCount(),
            Debris.Count(), Debris.Collected(),
            S.food, S.water, S.warm, Inv.Summary(),
            autopilot and (" [" .. autopilot.State() .. "]") or ""))
    end
end
