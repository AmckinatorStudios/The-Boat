-- ---------------------------------------------------------------------------
-- game.lua — точка входа игры «The Boat». Висит на сущности World в main.sage;
-- всё остальное движок вызывает уже отсюда.
--
-- Здесь три обязанности и ни одной больше:
--   1. Собрать игру из модулей (воксели, игрок, выживание, инвентарь, HUD,
--      лодка) и связать их между собой через хуки, а не через общие глобальные
--      переменные.
--   2. Объявить раскладку управления (BindAction) — раскладка игры живёт в
--      игре, движок о ней не знает.
--   3. Раз в кадр собрать намерения игрока (или автопилота) в одну таблицу и
--      прокрутить игровой цикл в понятном порядке.
--
-- Ни строчки C++: воксельный мир, обзор от первого лица, добыча, крафт, шкалы
-- выживания, смена суток и интерфейс — всё это скрипты поверх обычного ECS.
-- ---------------------------------------------------------------------------
local Blocks    = require "blocks"
local V         = require "voxel"
local P         = require "player"
local S         = require "survival"
local Inv       = require "inventory"
local HUD       = require "hud"
local Boat      = require "boat"

local autopilot = nil
local started = false
local statusTimer = 0.0
local reportedWin = false

-- --- Раскладка --------------------------------------------------------------
local function bindControls()
    BindAction("Move Forward",  {"W", "UP"})
    BindAction("Move Back",     {"S", "DOWN"})
    BindAction("Move Left",     {"A", "LEFT"})
    BindAction("Move Right",    {"D", "RIGHT"})
    BindAction("Jump",          "SPACE")
    BindAction("Sprint",        "LEFT_CONTROL")
    BindAction("Crouch",        "LEFT_SHIFT")
    BindAction("Break",         "MOUSE_LEFT")
    BindAction("Place",         "MOUSE_RIGHT")
    BindAction("Use",           "E")
    BindAction("Eat",           "F")
    BindAction("Craft Planks",  "C")
    BindAction("Craft Sail",    "V")
    BindAction("Craft Campfire", "B")
    for i = 1, 6 do BindAction("Slot " .. i, tostring(i)) end
end

-- --- Ввод -------------------------------------------------------------------
local MOUSE_SENS = 0.11

local function readInput()
    local input = {
        moveF = 0.0, moveR = 0.0, jump = false, sprint = false, crouch = false,
        lookX = 0.0, lookY = 0.0,
        breakHeld = false, placePressed = false, usePressed = false, hotbar = nil,
    }
    if IsActionDown("Move Forward") then input.moveF = input.moveF + 1.0 end
    if IsActionDown("Move Back")    then input.moveF = input.moveF - 1.0 end
    if IsActionDown("Move Right")   then input.moveR = input.moveR + 1.0 end
    if IsActionDown("Move Left")    then input.moveR = input.moveR - 1.0 end
    input.jump = IsActionDown("Jump")
    input.sprint = IsActionDown("Sprint") and S.stamina > 1.0
    input.crouch = IsActionDown("Crouch")
    input.breakHeld = IsActionDown("Break")
    input.placePressed = WasActionPressed("Place")
    input.usePressed = WasActionPressed("Use")

    -- Обзор — только при захваченном курсоре: иначе игрок, вернувший курсор,
    -- крутил бы камеру каждым движением мыши по рабочему столу.
    if IsMouseCaptured() then
        local d = GetMouseDelta()
        input.lookX = d.x * MOUSE_SENS
        input.lookY = d.y * MOUSE_SENS
    end

    local scroll = GetScrollDelta()
    if scroll ~= 0 then Inv.Cycle(scroll) end
    for i = 1, #Inv.hotbar do
        if WasActionPressed("Slot " .. i) then input.hotbar = i end
    end
    return input
end

-- --- Хуки между модулями ----------------------------------------------------
local function onBreak(x, y, z, id, drop)
    -- Осколки цвета самого блока: пресет движка берём как основу и
    -- перекрашиваем — песок должен сыпаться песком, а камень камнем.
    local cfg = ParticlePresets.BlockBreak()
    local c = Blocks.Color(id)
    cfg.StartColor = Vec4(c.x, c.y, c.z, 1.0)
    cfg.EndColor = Vec4(c.x * 0.6, c.y * 0.6, c.z * 0.6, 0.0)
    EmitParticles(cfg, Vec3(x + 0.5, y + 0.5, z + 0.5), 14)
    HUD.Message("+1 " .. Blocks.Name(drop), 1.2)
end

local function onPlace(x, y, z, id)
    if id == Blocks.CAMPFIRE then
        local name = "campfire:" .. x .. ":" .. y .. ":" .. z
        CreateParticleStream(name, ParticlePresets.StoveEmbers(), Vec3(x + 0.5, y + 1.0, z + 0.5))
        SetParticleStreamActive(name, true) -- струи создаются выключенными
    end
end

local function onFall(distance)
    local damage = (distance - 3.0) * 2.2
    if damage > 0.0 then
        S.Damage(damage, "падение")
        HUD.Message(string.format("Падение: -%.0f", damage), 2.0)
    end
end

local function onDeath(cause)
    log("THEBOAT: игрок погиб (" .. cause .. ")")
    HUD.Message("Ты погиб: " .. cause .. ". Возвращение на берег...", 4.0)
    Schedule(2.0, function()
        S.Respawn()
        local s = V.Spawn()
        P.Teleport(s.x + 0.5, s.y, s.z + 0.5)
        P.alive = true
    end)
    P.alive = false
end

local function onSetSail()
    log("THEBOAT: BOAT LAUNCHED")
    HUD.Message("Отдать швартовы!", 5.0)
end

local function onEscaped()
    if reportedWin then return end
    reportedWin = true
    log("THEBOAT: ESCAPED — игра пройдена")
    HUD.Message("Ты уплыл с острова. Конец.", 60.0)
end

local function onReadyChanged(ready)
    if ready then
        log("THEBOAT: BOAT COMPLETE")
        HUD.Message("Лодка готова! Встань на причал и нажми E", 6.0)
    end
end

-- --- Старт ------------------------------------------------------------------
function OnStart(entity)
    local seed = tonumber(LaunchArg("seed") or "") or 20240517
    -- Дальность прогрузки — из параметров запуска (--view=2 на слабой машине,
    -- --view=4 на сильной): это единственная настройка, которой стоит платить
    -- за картинку, и менять её должен игрок, а не правка скрипта.
    local view = tonumber(LaunchArg("view") or "")
    if view then V.SetViewChunks(view) end
    log("THEBOAT: старт, seed=" .. seed .. ", дальность прогрузки " ..
        V.ViewDistance() .. " блоков")

    bindControls()
    -- Курсор захватываем сразу: игра от первого лица. ESC вернёт его (движок).
    SetMouseCaptured(true)

    local _, decor = V.Init(seed)
    log(string.format("THEBOAT: мир %dx%dx%d, море на y=%d, деревьев %d, кустов %d, руды %d",
        V.SIZE_X, V.SIZE_Y, V.SIZE_Z, V.SEA_LEVEL, decor.trees, decor.bushes, decor.ore))

    P.Init{voxel = V, inventory = Inv, hooks = {OnBreak = onBreak, OnPlace = onPlace, OnFall = onFall}}
    S.Init{voxel = V, hooks = {OnDeath = onDeath}}
    Boat.Init{voxel = V, hooks = {OnSetSail = onSetSail, OnEscaped = onEscaped,
                                  OnReadyChanged = onReadyChanged}}

    HUD.inventory = Inv
    HUD.Build()
    HUD.Message("Ты выжил в кораблекрушении. Собери лодку и уплыви.", 8.0)

    -- Мир вокруг точки высадки строим ДО первого кадра: игрок не должен
    -- смотреть, как из воздуха проявляется остров, на котором он стоит.
    V.PreloadAround(P.pos.x, P.pos.z)
    local live = V.Stats()
    log("THEBOAT: мир прогружен, видимых блоков: " .. live)

    if LaunchFlag("autopilot") then
        autopilot = require "autopilot"
        autopilot.Init{voxel = V, player = P, inventory = Inv, boat = Boat, log = log}
    end

    started = true
    log("THEBOAT: READY")
end

-- --- Кадр -------------------------------------------------------------------
function OnUpdate(entity, dt)
    if not started then return end
    -- Ограничитель шага: после подвисания (загрузка чанков, окно свернули) один
    -- огромный dt протащил бы игрока сквозь стену за один кадр.
    if dt > 0.1 then dt = 0.1 end

    local input
    if autopilot then
        input = autopilot.Update(dt)
    else
        input = readInput()
    end

    if input.hotbar then Inv.Select(input.hotbar) end

    if P.alive and not Boat.escaped then
        P.Update(dt, input)
    end
    S.Update(dt, P, input)
    Boat.Update(dt, P, input)

    -- Прогрузка мира вокруг игрока: по чанку за кадр, чтобы шаг за границу
    -- чанка не стоил кадровой паузы.
    V.UpdateStreaming(P.pos.x, P.pos.z, 1)

    -- Действия, не относящиеся к движению.
    if not autopilot then
        if WasActionPressed("Eat") then
            if Inv.EatBerries() then
                S.Feed(5.0)
                HUD.Message("Ягоды: +5 сытости", 2.0)
            else
                HUD.Message("Нет ягод — ищи кусты", 2.0)
            end
        end
        for _, recipe in ipairs(Inv.recipes) do
            if WasActionPressed(recipe.key) then
                local ok, text = Inv.Craft(recipe)
                HUD.Message(text, 2.5)
            end
        end
    end

    HUD.Update(dt, S, P, Inv, Boat)

    -- Строка состояния раз в 5 секунд: по ней читается и живой прогон, и лог
    -- headless-прогона в CI.
    statusTimer = statusTimer - dt
    if statusTimer <= 0.0 then
        statusTimer = 5.0
        local live = V.Stats()
        log(string.format("THEBOAT: t=%s pos=(%.1f %.1f %.1f) hp=%.0f food=%.0f блоков=%d " ..
                          "бревно=%d доска=%d парус=%d лодка=%d/%d%s",
            S.Clock(), P.pos.x, P.pos.y, P.pos.z, S.health, S.hunger, live,
            Inv.Count(Blocks.LOG), Inv.Count(Blocks.PLANK), Inv.Count(Blocks.SAIL),
            Boat.planks, Boat.needPlanks,
            autopilot and (" [" .. autopilot.State() .. "]") or ""))
    end
end
