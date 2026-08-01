-- ---------------------------------------------------------------------------
-- survival.lua — выживание: здоровье, голод, выносливость, кислород, холод и
-- смена суток.
--
-- Все шкалы сведены в один модуль намеренно: они не независимы. Голод гасит
-- восстановление здоровья, бег ест выносливость, ночь без костра отнимает
-- здоровье, вода отнимает кислород. Разложенные по «системам», эти правила
-- пришлось бы связывать через события ради связей, которые проще держать рядом.
--
-- Смена суток тоже здесь, а не в отдельном «освещении»: ночь — это ИГРОВОЕ
-- правило (холод, темнота, спешка достроить лодку), а не эффект. Модуль правит
-- солнце, ambient и туман сцены напрямую через GetLighting().
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"

local S = {}

S.MAX_HEALTH  = 20.0
S.MAX_HUNGER  = 20.0
S.MAX_STAMINA = 100.0
S.MAX_OXYGEN  = 10.0

S.health  = S.MAX_HEALTH
S.hunger  = S.MAX_HUNGER
S.stamina = S.MAX_STAMINA
S.oxygen  = S.MAX_OXYGEN
S.warm    = true
S.dead    = false
S.deaths  = 0

-- Сутки. 4 минуты — компромисс: успеть сделать что-то осмысленное за день и
-- всё-таки увидеть ночь за одну сессию.
S.DAY_LENGTH = 240.0
-- Начинаем в позднее утро, а не на рассвете. На рассвете солнце идёт вскользь,
-- освещённость горизонтальных поверхностей падает почти до одного ambient, и
-- первое, что видит игрок, — тускло-серый пляж. Пусть первый кадр будет светлым.
S.time = 0.36

local HUNGER_RATE   = 0.055  -- ед/с в покое
local HUNGER_SPRINT = 0.10
local STAMINA_DRAIN = 14.0
local STAMINA_REGEN = 9.0
local REGEN_RATE    = 0.5
local STARVE_RATE   = 0.45
local DROWN_RATE    = 2.0
local COLD_RATE     = 0.30
local CAMPFIRE_R    = 5

local V, hooks

function S.Init(deps)
    V = deps.voxel
    hooks = deps.hooks or {}
    if deps.dayLength then S.DAY_LENGTH = deps.dayLength end
end

-- Часы игрового мира: 0.0 — полночь, 0.5 — полдень.
function S.Clock()
    local hours = S.time * 24.0
    local h = math.floor(hours)
    local m = math.floor((hours - h) * 60.0)
    return string.format("%02d:%02d", h, m)
end

function S.IsNight()
    return S.time < 0.22 or S.time > 0.80
end

function S.Damage(amount, cause)
    if S.dead or amount <= 0 then return end
    S.health = math.max(0.0, S.health - amount)
    if hooks.OnDamage then hooks.OnDamage(amount, cause) end
    if S.health <= 0.0 then
        S.dead = true
        S.deaths = S.deaths + 1
        if hooks.OnDeath then hooks.OnDeath(cause) end
    end
end

function S.Heal(amount)
    S.health = math.min(S.MAX_HEALTH, S.health + amount)
end

function S.Feed(amount)
    S.hunger = math.min(S.MAX_HUNGER, S.hunger + amount)
end

function S.Respawn()
    S.health = S.MAX_HEALTH
    S.hunger = math.max(6.0, S.hunger)
    S.stamina = S.MAX_STAMINA
    S.oxygen = S.MAX_OXYGEN
    S.dead = false
end

-- Рядом ли костёр. Куб 11x11x5 вокруг игрока — 605 проверок, вызывается раз в
-- полсекунды (см. S.Update), а не каждый кадр.
local function nearCampfire(px, py, pz)
    local x0, y0, z0 = math.floor(px), math.floor(py), math.floor(pz)
    for y = y0 - 2, y0 + 2 do
        for z = z0 - CAMPFIRE_R, z0 + CAMPFIRE_R do
            for x = x0 - CAMPFIRE_R, x0 + CAMPFIRE_R do
                if V.Get(x, y, z) == Blocks.CAMPFIRE then return true end
            end
        end
    end
    return false
end

local warmthTimer = 0.0

function S.Update(dt, player, input)
    S.time = (S.time + dt / S.DAY_LENGTH) % 1.0
    S.UpdateSky()

    if S.dead then return end

    -- Голод: бег дороже шага, стояние на месте почти бесплатно.
    local moving = math.abs(input.moveF) > 0.01 or math.abs(input.moveR) > 0.01
    local sprinting = input.sprint and input.moveF > 0 and S.stamina > 0.0
    local rate = HUNGER_RATE * (moving and 1.0 or 0.55)
    if sprinting then rate = HUNGER_SPRINT end
    S.hunger = math.max(0.0, S.hunger - rate * dt)

    -- Выносливость: тратится на бег, возвращается на ходьбе и в покое.
    if sprinting then
        S.stamina = math.max(0.0, S.stamina - STAMINA_DRAIN * dt)
    else
        S.stamina = math.min(S.MAX_STAMINA, S.stamina + STAMINA_REGEN * dt)
    end

    -- Кислород: под водой убывает, на воздухе возвращается быстро.
    if player.headInWater then
        S.oxygen = math.max(0.0, S.oxygen - dt)
        if S.oxygen <= 0.0 then S.Damage(DROWN_RATE * dt, "утонул") end
    else
        S.oxygen = math.min(S.MAX_OXYGEN, S.oxygen + dt * 3.0)
    end

    -- Холод ночью. Проверку костра делаем раз в полсекунды: перебирать сотни
    -- ячеек каждый кадр ради шкалы, которая меняется на 0.3 в секунду, незачем.
    warmthTimer = warmthTimer - dt
    if warmthTimer <= 0.0 then
        warmthTimer = 0.5
        S.warm = (not S.IsNight()) or nearCampfire(player.pos.x, player.pos.y, player.pos.z)
    end
    if S.IsNight() and not S.warm then
        S.Damage(COLD_RATE * dt, "замёрз")
    end

    if S.hunger <= 0.0 then
        S.Damage(STARVE_RATE * dt, "голод")
    elseif S.hunger > 12.0 and S.warm and S.oxygen > 0.0 then
        S.Heal(REGEN_RATE * dt)
    end
end

-- --- Небо и солнце ----------------------------------------------------------
local function mix(a, b, t) return a + (b - a) * t end

-- Солнце ходит по дуге, а вместе с ним — цвет неба, сила ambient и туман.
-- Правится ТА ЖЕ структура освещения сцены, что редактор показывает в панели
-- Lighting: день-ночь — это не отдельная система, а анимация настроек сцены.
function S.UpdateSky()
    local L = GetLighting()

    local ang = (S.time - 0.25) * 2.0 * math.pi
    local sy = math.sin(ang)
    local sx = math.cos(ang)
    L.Sun.Direction = Vec3(-sx * 0.6 - 0.25, -math.max(0.08, sy), -0.35)

    -- day: 0 глухая ночь ... 1 полдень
    local day = math.max(0.0, math.min(1.0, sy * 1.6 + 0.25))
    local dusk = math.max(0.0, 1.0 - math.abs(sy) * 3.0) * (day > 0.02 and 1.0 or 0.0)

    L.Sun.Intensity = mix(0.05, 1.15, day)
    L.Sun.Color = Vec3(mix(0.55, 1.0, day), mix(0.55, 0.96, day) - dusk * 0.15,
                       mix(0.85, 0.86, day) - dusk * 0.35)

    L.AmbientStrength = mix(0.12, 0.42, day)
    L.SkyColor = Vec3(mix(0.05, 0.52, day) + dusk * 0.25,
                      mix(0.07, 0.68, day),
                      mix(0.16, 0.92, day))
    L.GroundColor = Vec3(mix(0.03, 0.24, day), mix(0.04, 0.22, day), mix(0.07, 0.19, day))

    L.Fog.Enabled = true
    L.Fog.Color = Vec3(mix(0.06, 0.62, day) + dusk * 0.2,
                       mix(0.08, 0.72, day),
                       mix(0.16, 0.86, day))
    -- Туман привязан к ДАЛЬНОСТИ ПРОГРУЗКИ, а не к красивому числу. Мир
    -- существует только внутри радиуса чанков вокруг игрока; если дымка
    -- начинается дальше этого радиуса, игрок видит не горизонт, а обрыв, за
    -- которым честно ничего нет. Ночью горизонт дополнительно поджимаем.
    -- Конец тумана — чуть ближе границы прогрузки (0.95), чтобы к обрыву мира
    -- дымка успела стать непрозрачной. Начало — с половины дистанции: раньше
    -- туман съедал ближний план и остров выглядел выцветшим.
    local view = V.ViewDistance()
    L.Fog.Start = view * mix(0.28, 0.52, day)
    L.Fog.End = view * mix(0.70, 0.95, day)
end

function S.Reset()
    S.health, S.hunger = S.MAX_HEALTH, S.MAX_HUNGER
    S.stamina, S.oxygen = S.MAX_STAMINA, S.MAX_OXYGEN
    S.dead = false
end

return S
