-- ---------------------------------------------------------------------------
-- game.lua — точка входа «The Boat». Висит на сущности World в main.sage.
--
-- Обязанностей четыре: собрать игру из модулей и связать их хуками, объявить
-- раскладку, держать состояние экранов (меню, верстак, игра) и раз в кадр
-- прокрутить цикл в понятном порядке. Порядок важен: сперва вода (она задаёт
-- высоту всему), затем корабль (он на ней качается), затем игрок (он стоит на
-- корабле), затем мусор и интерфейс.
--
-- Ни строчки C++: бесконечный океан с волнами, корабль как сетка блоков,
-- плавучий мусор на настоящей физике движка, стройка, крафт, шкалы, смена
-- суток, меню и сохранения — всё это скрипты поверх обычного ECS.
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"
local Ocean  = require "ocean"
local Ship   = require "ship"
local P      = require "player"
local Debris = require "debris"
local S      = require "survival"
local Inv    = require "inventory"
local HUD    = require "hud"
local Craft  = require "craft"
local Menu   = require "menu"

local autopilot = nil
local started = false
local statusTimer = 0.0
local purifyTimer = 0.0
local fishTimer = 0.0
local lanterns = {}     -- мировые координаты фонарей (тепло + свет)
local nets = {}         -- мировые координаты сетей (притягивают мусор)
local structureDirty = true
local saveSlot = "main"
local slotNamed = false  -- слот задан снаружи (--save=имя), а не выбран игрой
local startLook = nil   -- {yaw, pitch} из --look, если задан
local startAt = nil     -- {x, y, z} из --at, если задан
local autoSaveTimer = 0.0
local daysPassed = 0.0
-- Версия формата прогресса. Растёт при ЛОМАЮЩЕМ изменении: добавление поля её
-- не двигает, старые сохранения читаются без него как раньше.
--
-- 2 — в прогрессе появились поза игрока и прожитые дни. Сохранения версии 1
-- читаются по-прежнему: недостающие поля просто остаются начальными.
local SAVE_VERSION = 2
-- Автосохранение раз в полминуты. Не по событию «поставил блок»: в этой игре
-- блоки ставят пачками, и запись на каждый означала бы сотни записей в минуту.
-- Выход из игры сохраняет отдельно и сразу (см. OnQuit) — автосохранение
-- страхует от выключения питания, а не заменяет сохранение при выходе.
local AUTOSAVE_EVERY = 30.0

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
    BindAction("Flashlight",   "L")   -- фонарь: L, рядом с остальными действиями
    -- Цифры выбирают СЛОТ, как в любой игре про блоки. Раньше они запускали
    -- крафт, и «нажми 6, чтобы получить опреснитель» было единственным
    -- интерфейсом крафта — теперь крафт живёт на верстаке (TAB).
    for i = 1, Inv.HOTBAR do BindAction("Slot " .. i, tostring(i)) end
    BindAction("Inventory",    {"TAB", "I"})
    BindAction("Menu",         "ESCAPE")
end

-- --- Ввод -------------------------------------------------------------------
local MOUSE_SENS = 0.11

local function blankInput()
    return {
        moveF = 0.0, moveR = 0.0, jump = false, sprint = false, crouch = false,
        lookX = 0.0, lookY = 0.0,
        breakHeld = false, placePressed = false, usePressed = false,
        flashlightPressed = false,
        eatPressed = false, drinkPressed = false, fishPressed = false,
        craft = nil,
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
    input.flashlightPressed = WasActionPressed("Flashlight")

    if IsMouseCaptured() then
        local d = GetMouseDelta()
        input.lookX = d.x * MOUSE_SENS
        input.lookY = d.y * MOUSE_SENS
    end
    local scroll = GetScrollDelta()
    if scroll ~= 0 then Inv.Cycle(scroll) end
    for i = 1, Inv.HOTBAR do
        if WasActionPressed("Slot " .. i) then Inv.Select(i) end
    end
    return input
end

-- --- Режим ввода ------------------------------------------------------------
--
-- Курсор — ОДИН на игру, и владелец у него один. Экранов, которым нужна мышь,
-- два (верстак и меню), и если бы каждый захватывал и отпускал её сам, закрытие
-- одного поверх другого возвращало бы обзор посреди открытого экрана.
local function applyCursor()
    SetMouseCaptured(not (Menu.IsOpen() or Craft.IsOpen()))
end

-- Худ и рука прячутся вместе: и то и другое — «интерфейс игры», и поверх
-- открытого меню они мешают одинаково.
local function setHudVisible(visible)
    HUD.SetVisible(visible)
    P.SetHandVisible(visible)
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
    HUD.Message(name .. ": " .. table.concat(parts, ", "), 2.2, "bag")
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
    HUD.Message("Разобрано: " .. Blocks.Name(id), 1.6, Blocks.Icon(id))
    structureDirty = true
    if autopilot then autopilot.NoteBroken() end
end

local function onPlace(x, y, z, id)
    structureDirty = true
    if id == Blocks.LANTERN then HUD.Message("Фонарь зажжён", 2.0, "lantern") end
    if autopilot then autopilot.NotePlaced() end
end

local function onOverboard()
    HUD.Message("За бортом! Плыви к лодке", 3.5, "wave")
    local wx, wy, wz = P.WorldPos()
    splash(wx, wy, wz, Vec3(0.6, 0.8, 0.9), 24)
end

local function onAboard()
    HUD.Message("Снова на палубе", 2.0, "boat")
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

-- --- Сохранение -------------------------------------------------------------
--
-- Прогресс, а не сцена: расстановка объектов уровня одинакова у всех игроков и
-- живёт в .sage рядом с игрой, а вот построенная лодка, инвентарь, поза игрока
-- и время суток принадлежат одному человеку. Пишется в пользовательский
-- каталог, через временный файл с переименованием — падение посреди записи не
-- должно уносить предыдущее сохранение.
local function saveProgress()
    if not started then return false end
    return sage.save.Write(saveSlot or "main", {
        ship      = Ship.Snapshot(),
        inventory = Inv.Snapshot(),
        survival  = S.Snapshot(),
        player    = P.Snapshot(),
        drift     = Ship.drift,
        days      = math.floor(daysPassed),
    }, SAVE_VERSION)
end

-- Имя оставлено глобальным: на него ссылались снаружи (проверки, консоль).
function SaveProgress() return saveProgress() end

local function loadProgress(slot)
    local saved = sage.save.Read(slot)
    if not saved then return nil end
    local blocks = Ship.Restore(saved.ship)
    Inv.Restore(saved.inventory)
    S.Restore(saved.survival)
    P.Restore(saved.player)
    if saved.drift then Ship.drift = saved.drift end
    daysPassed = saved.days or 0.0
    structureDirty = true
    log(("THEBOAT: загружено сохранение '%s' (%d блоков, день %d)"):format(
        slot, blocks, math.floor(daysPassed) + 1))
    return blocks
end

-- Новая игра: стартовый плот, пустой трюм, позднее утро.
--
-- Прежнее сохранение стирается ЗДЕСЬ, а не молча перезаписывается первым
-- автосохранением: «Новая игра» и так означает, что прошлой партии больше нет,
-- и оставлять её на диске ещё полминуты — значит обещать возврат, которого не
-- будет.
local function newGame()
    sage.save.Delete(saveSlot)
    local blocks = Ship.Reset()
    Inv.Reset()
    S.Reset()
    P.Reset()
    daysPassed = 0.0
    autoSaveTimer = 0.0
    fishTimer = 0.0
    purifyTimer = 0.0
    structureDirty = true
    log(("THEBOAT: новая игра (%d блоков)"):format(blocks))
end

-- --- Старт ------------------------------------------------------------------
function OnStart(entity)
    -- Считается ОДИН раз и в самом начале: от него зависят и запуск автопилота,
    -- и то, показывать ли заглавное меню.
    local autopilotWanted = LaunchFlag("autopilot")
    local seed = tonumber(LaunchArg("seed") or "") or 20240517
    log("THEBOAT: старт, seed=" .. seed)

    -- Время суток можно задать снаружи (--time=0.82 — закат). Нужно и для
    -- скриншотов, и чтобы проверять ночные механики, не досиживая до ночи.
    local t0 = tonumber(LaunchArg("time") or "")
    if t0 then S.time = t0 % 1.0 end

    -- Куда смотреть на старте (--look=0 — на нос корабля, --look=180,20 — в
    -- небо за кормой). Ровно та же нужда, что и у --time: снять скриншот
    -- конкретного места или проверить ночную механику, не крутя мышью вручную.
    local lookArg = LaunchArg("look")
    if lookArg then
        local ly, lp = lookArg:match("^([^,]+),(.+)$")
        startLook = {tonumber(ly or lookArg) or 0.0, tonumber(lp) or 0.0}
    end
    -- И откуда смотреть (--at=x,y,z в координатах лодки). Пара к --look: без
    -- неё в кадр не попадает ничего, что стоит за мачтой, — а игрок всегда
    -- начинает ровно перед ней.
    local atArg = LaunchArg("at")
    if atArg then
        local ax, ay, az = atArg:match("^([^,]+),([^,]+),(.+)$")
        if ax then startAt = {tonumber(ax) or 0.0, tonumber(ay) or 1.0, tonumber(az) or 0.0} end
    end

    bindControls()

    -- Меню у игры своё (см. menu.lua), поэтому встроенное меню паузы плеера
    -- выключаем: иначе ESC перехватывал бы плеер и до игры не доходил вовсе.
    sage.game.SetPauseMenu(false)

    local tiles = Ocean.Build()
    local blocks = Ship.Init()
    log(string.format("THEBOAT: океан %d плиток, корабль %d блоков", tiles, blocks))

    -- Отражения. Небо отражается всем — палубой, бочками, мокрыми досками; а
    -- вода вдобавок получает ЗЕРКАЛЬНОЕ отражение сцены относительно уровня
    -- моря, и в ней видно сам корабль, парус и плавающий мусор.
    --
    -- Плоскость берётся по спокойной воде, а не по волне: она в сцене одна на
    -- проход, а волна у каждой плитки своя. Расхождение съедает та же рябь,
    -- которой отражение и ломается, — на глаз оно незаметно, а честное
    -- отражение по каждой волне стоило бы прохода геометрии на волну.
    sage.reflect.SetEnabled(true)
    sage.reflect.SetWater(Ocean.SEA_LEVEL)
    sage.reflect.SetPlanarScale(0.5)

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
    Craft.Build{inventory = Inv, onMessage = HUD.Message}
    Menu.Build{
        HasSave = function() return sage.save.Exists(saveSlot) end,
        Subtitle = function()
            -- День берём из САМОГО сохранения, а не из счётчика в памяти: в
            -- заглавном меню партия ещё не загружена, и счётчик показал бы
            -- «день 1» для любой сохранённой лодки.
            local saved = sage.save.Read(saveSlot)
            if not saved then return "Океан во все стороны. Земли нет." end
            return ("Есть сохранение — день %d"):format(math.floor(saved.days or 0) + 1)
        end,
    }
    purifierCount = rescanStructures()
    structureDirty = false

    -- Первый кадр океан должен быть уже на волне, а не плоским листом.
    Ocean.Update(0.0, Ship.pos.x, Ship.pos.z)
    Ship.Update(0.0)
    S.UpdateSky()

    if autopilotWanted then
        autopilot = require "autopilot"
        autopilot.Init{ship = Ship, player = P, inventory = Inv, debris = Debris,
                       survival = S, log = log}
    end

    -- Слот прогресса. Автопрогон играет с ЧИСТОГО листа и в свой слот.
    --
    -- Иначе проверка перестаёт быть проверкой: второй запуск продолжал бы
    -- партию первого, лодка была бы уже построена, и «автопилот прожил день»
    -- означало бы «автопилот доиграл чужую партию». Ровно на этом --check и
    -- сломался, как только появились сохранения.
    saveSlot = LaunchArg("save") or (autopilotWanted and "autopilot" or "main")
    slotNamed = LaunchArg("save") ~= nil

    started = true

    -- Каким экраном открыться (--screen=craft|menu|game). Та же нужда, что у
    -- --look и --time: снять кадр верстака или меню, не нажимая ничего руками,
    -- и проверить, что экран собирается, — прогоном без человека.
    local screenArg = LaunchArg("screen")

    if autopilotWanted then
        -- Автопрогон меню не открывает: он проверяет игру, а не экран запуска,
        -- и ждать от него щелчка по «Новая игра» значило бы либо учить его
        -- мыши, либо остановить CI на первом же кадре.
        HUD.Message("Океан во все стороны. Лови, что несёт течением.", 7.0, "compass")
    elseif screenArg == "craft" or screenArg == "game" then
        -- «Сразу играть», минуя меню: прогресс при этом всё равно грузится —
        -- пропуск экрана запуска не должен незаметно означать новую партию.
        if loadProgress(saveSlot) then
            HUD.Message(("Продолжаем. День %d."):format(math.floor(daysPassed) + 1), 5.0,
                        "compass")
        else
            HUD.Message("Океан во все стороны. Лови, что несёт течением.", 7.0, "compass")
        end
        if screenArg == "craft" then Craft.SetOpen(true) end
    else
        -- Заглавное меню. Мир за ним уже построен и живёт: игра про воду не
        -- должна начинаться с чёрного экрана со списком кнопок.
        --
        -- И смотрит камера ВДОЛЬ ПАЛУБЫ, а не туда, куда встанет игрок: с носа
        -- вперёд видно только пустое море, и заглавный экран игры про лодку
        -- получался без лодки. Поза сменится при первом же выборе в меню —
        -- «Продолжить» вернёт сохранённую, «Новая игра» поставит на нос.
        P.pos.x, P.pos.y, P.pos.z = 14.0, 2.2, 13.0
        P.SetLook(56.0, -4.0)
        P.Apply()
        Menu.Open("title")
        setHudVisible(false)
    end
    applyCursor()

    -- ПОСЛЕ всего: --look/--at — это явное указание снаружи, и оно должно быть
    -- последним словом. Те же две строки стоят и после «Продолжить» в меню:
    -- загрузка возвращает сохранённую позу, и без них ключи с командной строки
    -- молча ничего не значили бы в самом частом случае — при продолжении игры.
    if startAt then P.pos.x, P.pos.y, P.pos.z = startAt[1], startAt[2], startAt[3] end
    if startLook then P.SetLook(startLook[1], startLook[2]) end

    log("THEBOAT: READY")
end

-- --- Выход ------------------------------------------------------------------
--
-- Движок зовёт этот хук на ЛЮБОМ пути выхода: кнопка меню, крестик окна, Stop в
-- редакторе. До его появления игра теряла всё, что случилось после последнего
-- автосохранения, и теряла молча — с точки зрения человека «игра не сохранила
-- последние двадцать минут».
function OnQuit()
    if not started then return end
    -- Автопрогон свой слот НЕ бережёт: следующий запуск обязан начинать с
    -- чистого листа, иначе «автопилот прожил день» превращается в «автопилот
    -- доиграл чужую партию». Но если слот назван снаружи (--save=имя), человек
    -- просит записать именно туда — этим и проверяют сохранение прогоном.
    if autopilot and not slotNamed then return end
    if saveProgress() then log("THEBOAT: прогресс сохранён при выходе") end
end

-- --- Действия, не относящиеся к движению ------------------------------------
local function handleActions(dt, input)
    -- Намерение «скрафтить» осталось ради автопилота: он играет теми же
    -- намерениями, что человек — мышью. Путь при этом ОДИН и тот же (Craft),
    -- иначе прогон проверял бы не то, чем пользуются люди.
    if input.craft then Craft.CraftIndex(input.craft) end

    if input.eatPressed then
        local id, value = Inv.EatBest()
        if id then
            S.Feed(value)
            HUD.Message(Blocks.Name(id) .. ": сытость +" .. math.floor(value), 2.0, Blocks.Icon(id))
        else
            HUD.Message("Нечего есть — лови рыбу или собирай водоросли", 2.4, "food")
        end
    end

    if input.drinkPressed then
        local id, value = Inv.DrinkBest()
        if id then
            S.Drink(value)
            HUD.Message("Пресная вода: жажда +" .. math.floor(value), 2.0, "drop")
        else
            HUD.Message("Нет пресной воды — нужен опреснитель", 2.4, "purifier")
        end
    end

    -- Фонарик (L). Ночью на палубе без него не видно, куда ставишь блок, а
    -- ставить блоки — основное занятие; днём он просто не нужен и выключен.
    if input.flashlightPressed then
        local on = P.ToggleFlashlight()
        HUD.Message(on and "Фонарик включён" or "Фонарик выключен", 1.4, "lamp")
    end

    -- Рыбалка: удочка + стоять у борта. Ждать приходится — это и есть занятие.
    if input.fishPressed then
        if not Inv.Has(Blocks.ROD) then
            HUD.Message("Нужна удочка — собери её на верстаке (TAB)", 2.4, "rod")
        elseif fishTimer > 0.0 then
            HUD.Message(string.format("Клюёт... %.0f с", fishTimer), 1.5, "hook")
        else
            fishTimer = 7.0
            HUD.Message("Закинул удочку", 2.0, "rod")
        end
    end
    if fishTimer > 0.0 then
        fishTimer = fishTimer - dt
        if fishTimer <= 0.0 then
            Inv.Add(Blocks.FISH, 1)
            HUD.Message("Поймана рыба!", 2.5, "fish")
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

-- --- Экраны -----------------------------------------------------------------
local function startPlaying()
    Menu.Close()
    Craft.SetOpen(false)
    setHudVisible(true)
    applyCursor()
end

-- Что нажали в меню. Возврат true означает «кадр на этом закончен»: мир под
-- открытым меню не тикает, и продолжать цикл незачем.
local function handleMenu(dt)
    local action = Menu.Update(dt)
    if action == nil then return end

    if action == "continue" then
        if Menu.State() == "title" then
            if loadProgress(saveSlot) then
                HUD.Message(("Продолжаем. День %d."):format(math.floor(daysPassed) + 1),
                            5.0, "compass")
            end
            -- --look/--at сильнее сохранённой позы: это указание снаружи.
            if startAt then P.pos.x, P.pos.y, P.pos.z = startAt[1], startAt[2], startAt[3] end
            if startLook then P.SetLook(startLook[1], startLook[2]) end
        end
        startPlaying()

    elseif action == "new" then
        newGame()
        startPlaying()
        HUD.Message("Океан во все стороны. Лови, что несёт течением.", 7.0, "compass")

    elseif action == "save" then
        if saveProgress() then HUD.Message("Прогресс сохранён", 2.0, "save")
        else HUD.Message("Не удалось сохранить — смотри лог", 3.0, "warn") end

    elseif action == "quit" then
        -- Сохраняет сам движок через OnQuit; здесь только просьба выйти.
        sage.game.Quit()
    end
end

-- ESC и TAB работают всегда, в любом экране: клавиша «назад» не должна
-- зависеть от того, что открыто, — иначе из верстака в меню приходится
-- выбираться в два приёма и угадывать, в каком ты сейчас.
local function handleScreenKeys()
    if WasActionPressed("Inventory") then
        if Menu.IsOpen() then
            -- Из меню верстак не открываем: сперва вернись в игру.
        else
            Craft.Toggle()
            setHudVisible(not Craft.IsOpen())
            applyCursor()
        end
    end

    if WasActionPressed("Menu") then
        if Craft.IsOpen() then
            Craft.SetOpen(false)
            setHudVisible(true)
        elseif Menu.State() == "pause" then
            Menu.Close()
            setHudVisible(true)
        elseif Menu.State() == "title" then
            -- В заглавном меню ESC не значит ничего: выйти из него можно
            -- только выбрав, что делать. «Отмена» здесь отменяла бы запуск.
        else
            Menu.Open("pause")
            setHudVisible(false)
        end
        applyCursor()
    end
end

-- --- Кадр -------------------------------------------------------------------
function OnUpdate(entity, dt)
    if not started then return end
    if dt > 0.1 then dt = 0.1 end

    if autopilot == nil then handleScreenKeys() end

    -- В МЕНЮ ПАУЗЫ мир стоит: ни волна, ни голод, ни течение. Пауза, в которой
    -- продолжает капать жажда, — не пауза.
    --
    -- Останавливаем сами, а не через sage.game.Pause: пауза движка не тикает и
    -- скрипты тоже, вместе с этим самым меню, и нажать в нём было бы нечего.
    if Menu.State() == "pause" then
        handleMenu(dt)
        return
    end

    -- А в ЗАГЛАВНОМ меню мир живёт: волна качает лодку, мусор плывёт мимо. Это
    -- не украшение — это то, ради чего игру запускают, и показать его лучше
    -- сразу, чем после нажатия кнопки. Не идут только время суток, шкалы и сам
    -- игрок: партия ещё не начата.
    local inTitle = Menu.State() == "title"

    local input
    if autopilot then input = autopilot.Update(dt)
    elseif inTitle or Craft.IsOpen() then input = blankInput()
    else input = readInput() end

    -- Порядок: вода -> корабль -> игрок -> мусор. Каждый следующий стоит на
    -- предыдущем, и перестановка мест ломает ровно то, что от неё зависит.
    Ship.waiting = P.overboard
    Ocean.Update(dt, Ship.pos.x, Ship.pos.z)
    Ship.Update(dt)
    if not inTitle then
        P.Update(dt, input)
        Debris.Update(dt)
        if #nets > 0 then Debris.NetPull(nets, dt) end

        handleActions(dt, input)
        S.Update(dt, P, input, lanterns)
        daysPassed = daysPassed + dt / S.DAY_LENGTH

        -- Автосохранение. По таймеру, а не по событию «поставил блок»: блоки в
        -- этой игре ставят пачками, и запись на каждый означала бы сотни
        -- записей в минуту вместо двух.
        autoSaveTimer = autoSaveTimer + dt
        if autoSaveTimer >= AUTOSAVE_EVERY then
            autoSaveTimer = 0.0
            saveProgress()
        end
    else
        Debris.Update(dt)
        handleMenu(dt)
    end

    if structureDirty then
        purifierCount = rescanStructures()
        structureDirty = false
    end

    Craft.Update(dt)
    HUD.Update(dt, S, P, Inv)

    if inTitle then return end

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
