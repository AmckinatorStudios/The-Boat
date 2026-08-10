-- ---------------------------------------------------------------------------
-- hand.lua — правая рука в кадре и то, что в ней.
--
-- ЗАЧЕМ ОНА. Вид от первого лица без рук — это камера, летающая над палубой:
-- игрок бьёт по доске, доска ломается, но БИТЬ нечем, и удар не читается как
-- удар. Рука решает три вещи разом: показывает, что сейчас в руке (выбранный
-- слот перестаёт быть только цифрой в углу экрана), даёт удару и установке
-- блока видимое движение, и привязывает камеру к телу — с ней качка палубы
-- ощущается качкой, а не дрожанием картинки.
--
-- УСТРОЙСТВО. Три куба, дочерние КАМЕРЕ: предплечье, кулак и предмет. Дочерние
-- — значит их не надо доворачивать за взглядом вручную: иерархия движка уже
-- умеет это делать, и рука не отстаёт от камеры ни на кадр.
--
-- Оба куба помечены CastShadows = false и InReflections = false. Это не
-- украшение: без первого рука кладёт на палубу тень парящего в воздухе
-- предплечья ровно посреди кадра, без второго — та же рука без хозяина
-- плавает в отражении воды. Обе поломки видны сразу и лечатся только со
-- стороны движка (см. RenderComponents.h).
-- ---------------------------------------------------------------------------
local Blocks = require "blocks"

local H = {}

local arm, fist, item
local cam
local swing = 0.0        -- 0..1: где сейчас замах
local swingHold = false  -- держим удар (ломаем блок) или это одиночный тычок
local sway = 0.0         -- фаза покачивания на ходу
local shownItem = nil    -- что в руке сейчас нарисовано (чтобы не пересоздавать меш)
local visible = true

-- Кожа. Не «телесный цвет из палитры»: игра нарисована плоскими цветами без
-- текстур, и рука обязана быть такой же — иначе она выглядит вставкой из
-- другой игры.
local SKIN = {0.80, 0.60, 0.44}
local SLEEVE = {0.34, 0.40, 0.47}

local function cube(name, parent, color)
    local obj = SpawnObject(name)
    SetMeshCube(obj)
    obj.Color = Vec3(color[1], color[2], color[3])
    obj:SetParent(parent)
    local r = obj:GetRenderer()
    r.CastShadows = false
    r.InReflections = false
    return obj
end

function H.Build(camera)
    cam = camera
    -- Рукав и кулак — два куба, а не один: одна вытянутая коробка читается
    -- палкой, а перелом на запястье превращает её в руку с двух пикселей.
    arm = cube("Hand Arm", cam, SLEEVE)
    fist = cube("Hand Fist", cam, SKIN)
    item = cube("Hand Item", cam, {1, 1, 1})
    SetMeshNone(item)   -- пустая рука: предмета нет
    H.Apply(0.0)
end

function H.SetVisible(v)
    if visible == v then return end
    visible = v
    -- Прячем снятием геометрии, а не масштабом в ноль: нулевой масштаб — это
    -- вырожденная матрица, из которой нормали выходят нулевой длины.
    if visible then
        SetMeshCube(arm); SetMeshCube(fist)
        shownItem = nil  -- предмет вернёт Update, если он есть
    else
        SetMeshNone(arm); SetMeshNone(fist); SetMeshNone(item)
        shownItem = nil
    end
end

-- Удар: одиночный тычок (поставить блок, подобрать багром) или удержание
-- (ломаем блок). Разница видна: тычок отыгрывается один раз и затухает,
-- удержание качает руку, пока держат кнопку.
function H.Swing(hold)
    if hold then
        swingHold = true
        if swing <= 0.0 then swing = 0.01 end
    else
        swingHold = false
        swing = 1.0
    end
end

function H.StopSwing() swingHold = false end

-- Куда поставить руку в этом кадре. Вынесено отдельно, потому что зовётся и из
-- Build (первый кадр рука обязана уже стоять на месте, а не появиться в начале
-- координат), и из Update.
function H.Apply(bob)
    if arm == nil or not arm:Valid() then return end

    -- Замах: рука уходит назад-вниз и возвращается. Синус даёт мягкий вход и
    -- выход — линейное движение читается как рывок.
    local s = math.sin(swing * math.pi)
    local dz = s * 0.16          -- к себе
    local dy = -s * 0.10         -- вниз
    local pitch = -s * 42.0      -- и разворот кисти

    -- Покачивание на ходу: та же фаза, что у камеры (её считает player.lua),
    -- но вдвое мельче — рука качается меньше, чем голова, иначе кадр «плывёт».
    local swayX = math.sin(sway) * 0.012
    local swayY = math.abs(math.cos(sway)) * 0.010 + bob * 0.35

    -- Предплечье лежит НА ЛИНИИ от правого нижнего угла кадра к кулаку, и
    -- поворот здесь не подобран на глаз, а посчитан из этой линии: движок
    -- собирает поворот как Rx*Ry*Rz, поэтому направление «вдоль -Z» после
    -- поворота — это (-cos(p)·sin(y), sin(p), -cos(p)·cos(y)), те же формулы,
    -- которыми считается взгляд игрока. Иначе рука и кулак разъезжаются, и
    -- между ними видна щель.
    local ax = arm.Transform
    ax.Position = Vec3(0.54 + swayX, -0.39 + swayY + dy, -0.68 + dz)
    ax.Rotation = Vec3(22.0 + pitch, 27.0, 0.0)
    ax.Scale = Vec3(0.13, 0.13, 0.58)

    local fx = fist.Transform
    fx.Position = Vec3(0.42 + swayX, -0.27 + swayY + dy * 1.2, -0.92 + dz * 1.2)
    fx.Rotation = Vec3(10.0 + pitch, 27.0, 0.0)
    fx.Scale = Vec3(0.17, 0.16, 0.17)

    local ix = item.Transform
    ix.Position = Vec3(0.44 + swayX, -0.20 + swayY + dy * 1.3, -1.02 + dz * 1.3)
    ix.Rotation = Vec3(-16.0 + pitch, 28.0, 12.0)
    ix.Scale = Vec3(0.17, 0.17, 0.17)
end

function H.Update(dt, P, Inv)
    if arm == nil or not arm:Valid() then return end

    -- Фаза покачивания идёт только на ходу и по земле: в воздухе и стоя рука
    -- должна замереть, иначе игрок «дышит» стоя на месте.
    local moving = P.onGround and (math.abs(P.vel.x) + math.abs(P.vel.z)) > 0.4
    if moving then sway = sway + dt * 7.0 else sway = sway * (1.0 - math.min(1.0, dt * 6.0)) end

    if swingHold then
        -- Пока держим — качаем по кругу.
        swing = (swing + dt * 3.2) % 1.0
    elseif swing > 0.0 then
        swing = math.max(0.0, swing - dt * 3.6)
    end

    if visible then
        -- Предмет в руке. Меш переключаем ТОЛЬКО при смене: SetMeshCube каждый
        -- кадр — это назначение ресурса шестьдесят раз в секунду ради того, что
        -- меняется раз в минуту.
        local id = Inv.SelectedBlock()
        if id ~= shownItem then
            shownItem = id
            if id then
                SetMeshCube(item)
                local c = Blocks.Color(id)
                item.Color = Vec3(c.x, c.y, c.z)
                local r = item:GetRenderer()
                r.CastShadows = false
                r.InReflections = false
                -- Фонарь и в руке светится: он и на палубе источник света.
                if Blocks.IsLight(id) then
                    r.Emissive = Vec3(1.0, 0.72, 0.34)
                    r.EmissiveStrength = 1.6
                else
                    r.Emissive = Vec3(0, 0, 0)
                end
            else
                SetMeshNone(item)
            end
        end
    end

    H.Apply(P.bob)
end

return H
