-- ---------------------------------------------------------------------------
-- survival.lua — сытость, жажда, тепло и смена суток.
--
-- Выживание здесь НЕ давит. Шкалы убывают за десятки минут, пустая шкала не
-- убивает, а замедляет и гасит краски; смерти в игре нет вовсе. Это осознанный
-- выбор жанра: игра про то, чтобы сидеть на палубе и смотреть на воду, а
-- таймер под ложечкой такому занятию мешает. Шкалы нужны не как угроза, а как
-- повод время от времени вставать и что-то делать.
--
-- Сутки — здесь же, потому что это тоже правило игры, а не эффект: ночью
-- холодно без фонаря, а закат — то, ради чего стоит доплыть до вечера. Модуль
-- правит солнце, ambient, туман сцены и цвет воды через GetLighting()/Ocean.
-- ---------------------------------------------------------------------------
local Ocean = require "ocean"

local S = {}

S.MAX_FOOD  = 100.0
S.MAX_WATER = 100.0
S.MAX_WARM  = 100.0

S.food  = 82.0
S.water = 74.0
S.warm  = 100.0
S.rested = 0.0    -- «уют»: копится, когда просто стоишь и смотришь на море

-- Сутки идут 8 минут: достаточно, чтобы закат случался в каждую сессию, и не
-- настолько быстро, чтобы день мелькал.
S.DAY_LENGTH = 480.0
S.time = 0.36     -- начинаем поздним утром, когда солнце уже высоко

local FOOD_RATE  = 0.32   -- ед/мин в покое -> около 40 минут от полной до нуля
local WATER_RATE = 0.45
local WARM_LOSS  = 8.0    -- ед/мин ночью без огня: около 12 минут до нуля
local WARM_GAIN  = 24.0   -- ед/мин у фонаря и днём

local hooks, ship

function S.Init(deps)
    hooks = deps.hooks or {}
    ship = deps.ship
    if deps.dayLength then S.DAY_LENGTH = deps.dayLength end
end

function S.Clock()
    local hours = S.time * 24.0
    local h = math.floor(hours)
    local m = math.floor((hours - h) * 60.0)
    return string.format("%02d:%02d", h, m)
end

function S.IsNight() return S.time < 0.22 or S.time > 0.85 end

function S.Feed(v) S.food = math.min(S.MAX_FOOD, S.food + v) end
function S.Drink(v) S.water = math.min(S.MAX_WATER, S.water + v) end

-- Насколько игроку сейчас хорошо: 0 — вымотан, 1 — полный порядок. По этому
-- числу гаснут краски и замедляется шаг — вместо полоски здоровья и смерти.
function S.Wellbeing()
    local f = S.food / S.MAX_FOOD
    local w = S.water / S.MAX_WATER
    local t = S.warm / S.MAX_WARM
    return math.min(f, math.min(w, t))
end

-- Рядом ли зажжённый фонарь (тепло). Фонари редки, список короткий.
local function nearWarmth(px, py, pz, lanterns)
    for _, l in ipairs(lanterns) do
        local dx, dy, dz = l[1] - px, l[2] - py, l[3] - pz
        if dx * dx + dy * dy + dz * dz < 36.0 then return true end
    end
    return false
end

function S.Update(dt, player, input, lanterns)
    S.time = (S.time + dt / S.DAY_LENGTH) % 1.0
    S.UpdateSky()

    local minutes = dt / 60.0
    local active = math.abs(input.moveF) > 0.01 or math.abs(input.moveR) > 0.01
    S.food = math.max(0.0, S.food - FOOD_RATE * minutes * (active and 1.5 or 1.0))
    S.water = math.max(0.0, S.water - WATER_RATE * minutes * (active and 1.4 or 1.0))

    -- Тепло: ночью без огня и в воде уходит, у фонаря и днём возвращается.
    -- Возвращается втрое быстрее, чем уходит: зайти погреться должно быть
    -- делом полминуты, а не отдельным занятием на вечер.
    local cold = (S.IsNight() and not nearWarmth(player.pos.x, player.pos.y, player.pos.z, lanterns))
                 or player.overboard
    if cold then
        S.warm = math.max(0.0, S.warm - WARM_LOSS * minutes)
    else
        S.warm = math.min(S.MAX_WARM, S.warm + WARM_GAIN * minutes)
    end

    -- Уют копится, когда игрок стоит на палубе и никуда не бежит. Ни на что не
    -- влияет механически — это счётчик того, ради чего игра сделана.
    if not active and not player.overboard then
        S.rested = S.rested + dt
    end

    if hooks.OnLowNeed then
        if S.food < 15.0 or S.water < 15.0 then hooks.OnLowNeed(S.food, S.water) end
    end
end

-- --- Небо, солнце и цвет воды ----------------------------------------------
local function mix(a, b, t) return a + (b - a) * t end
local function mix3(a, b, t)
    return {mix(a[1], b[1], t), mix(a[2], b[2], t), mix(a[3], b[3], t)}
end

-- Палитры времени суток. Держим их таблицей, а не формулой: закат — главный
-- кадр этой игры, и подбирать его удобнее числами, чем коэффициентами.
local NIGHT = {sky = {0.04, 0.07, 0.16}, fog = {0.06, 0.09, 0.18},
               sun = {0.32, 0.40, 0.72}, sea = {0.015, 0.045, 0.105}, crest = {0.08, 0.18, 0.30}}
local DAWN  = {sky = {0.92, 0.52, 0.36}, fog = {0.93, 0.60, 0.44},
               sun = {1.00, 0.58, 0.32}, sea = {0.07, 0.11, 0.22}, crest = {0.78, 0.44, 0.34}}
local DAY   = {sky = {0.26, 0.58, 0.94}, fog = {0.44, 0.70, 0.95},
               sun = {1.00, 0.97, 0.88}, sea = {0.020, 0.145, 0.275}, crest = {0.22, 0.66, 0.74}}
local DUSK  = {sky = {0.98, 0.46, 0.26}, fog = {0.97, 0.50, 0.30},
               sun = {1.00, 0.50, 0.24}, sea = {0.09, 0.10, 0.22}, crest = {0.88, 0.46, 0.30}}

local function blendPalette(a, b, k)
    return {
        sky = mix3(a.sky, b.sky, k), fog = mix3(a.fog, b.fog, k),
        sun = mix3(a.sun, b.sun, k), sea = mix3(a.sea, b.sea, k),
        crest = mix3(a.crest, b.crest, k),
    }
end

local function palette(t)
    -- ночь | рассвет | день | закат | ночь — с плавными переходами между ними
    if t < 0.18 then return NIGHT
    elseif t < 0.26 then return blendPalette(NIGHT, DAWN, (t - 0.18) / 0.08)
    elseif t < 0.36 then return blendPalette(DAWN, DAY, (t - 0.26) / 0.10)
    elseif t < 0.74 then return DAY
    elseif t < 0.84 then return blendPalette(DAY, DUSK, (t - 0.74) / 0.10)
    elseif t < 0.94 then return blendPalette(DUSK, NIGHT, (t - 0.84) / 0.10)
    else return NIGHT end
end

function S.UpdateSky()
    local L = GetLighting()
    local pal = palette(S.time)

    local ang = (S.time - 0.25) * 2.0 * math.pi
    local sy = math.sin(ang)
    local sx = math.cos(ang)
    L.Sun.Direction = Vec3(-sx * 0.7 - 0.2, -math.max(0.12, sy), -0.4)

    local day = math.max(0.0, math.min(1.0, sy * 1.8 + 0.3))
    L.Sun.Intensity = mix(0.22, 1.55, day)
    L.Sun.Color = Vec3(pal.sun[1], pal.sun[2], pal.sun[3])

    -- Ambient ночью держим ощутимо выше нуля: в кромешной темноте на лодке
    -- посреди океана не уютно, а страшно, и это не та игра. Днём, наоборот,
    -- держим его НИЗКО: сильный рассеянный свет ровно засвечивает все грани, и
    -- кубы теряют объём — палуба превращается в бежевое пятно.
    L.AmbientStrength = mix(0.26, 0.30, day)
    L.SkyColor = Vec3(pal.sky[1], pal.sky[2], pal.sky[3])
    L.GroundColor = Vec3(pal.sea[1] * 2.2, pal.sea[2] * 2.0, pal.sea[3] * 1.8)

    -- Купол неба красим той же палитрой: закат должен быть НА НЕБЕ, а не
    -- только в отсветах на воде и парусе.
    L.Skybox.Enabled = true
    L.Skybox.TopColor = Vec3(pal.sky[1] * 0.75, pal.sky[2] * 0.82, pal.sky[3])
    L.Skybox.HorizonColor = Vec3(pal.fog[1], pal.fog[2], pal.fog[3])

    L.Fog.Enabled = true
    L.Fog.Color = Vec3(pal.fog[1], pal.fog[2], pal.fog[3])
    -- Туман кончается там же, где кончается сетка воды: горизонт должен таять,
    -- а не обрываться. Он же и делает океан «бесконечным» на глаз.
    local view = Ocean.RADIUS * Ocean.TILE
    L.Fog.Start = view * 0.42
    L.Fog.End = view * 0.95

    Ocean.SetMood(pal.sea, pal.crest)
end

return S
