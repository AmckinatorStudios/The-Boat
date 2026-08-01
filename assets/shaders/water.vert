// Вода «Лодки»: волна считается В ШЕЙДЕРЕ, на вершину, а не в скрипте на плитку.
//
// Раньше высоту каждой плитки двигал Lua, поэтому волна была ступенчатой: два
// метра плитки поднимались целиком, и море выглядело шахматной доской. Здесь
// вершины одной плитки живут своей жизнью, и поверхность становится гладкой —
// при том же числе объектов на сцене и без единого лишнего draw call'а.
#version 330 core
layout (location = 0) in vec3 aPos;
layout (location = 1) in vec3 aNormal;
layout (location = 4) in vec4 iM0;
layout (location = 5) in vec4 iM1;
layout (location = 6) in vec4 iM2;
layout (location = 7) in vec4 iM3;
layout (location = 8) in vec3 iColor;
layout (location = 9) in float iMetallic;
layout (location = 10) in float iRoughness;
layout (location = 12) in float iAlpha;

uniform mat4 uView;
uniform mat4 uProjection;
uniform float uTime;
uniform float uWaveHeight;   // амплитуда суммарной волны, метры
uniform float uWaveFade;     // радиус затухания волн вокруг лодки, метры
uniform vec3  uFocus;        // центр затухания (позиция лодки)

out vec3 FragPos;
out vec3 Normal;
out vec3 vColor;
out float vAlpha;
out float vCrest;   // -1 впадина ... +1 гребень: по нему фрагмент красит пену
out float vFade;    // 1 у лодки ... 0 у горизонта: затухание волн и ряби

// Те же три синусоиды, что знает игра (ocean.lua): скрипту высота нужна для
// физики и качки, шейдеру — для картинки, и расходиться им нельзя.
float waveAt(vec2 p, float t) {
    return sin(p.x * 0.185 + p.y * 0.055 + t * 0.95) * 0.17
         + sin(p.x * -0.065 + p.y * 0.155 - t * 0.72) * 0.14
         + sin(p.x * 0.043 + p.y * 0.037 + t * 0.41) * 0.22;
}

void main() {
    mat4 model = mat4(iM0, iM1, iM2, iM3);
    vec4 world = model * vec4(aPos, 1.0);

    // Затухание к горизонту — как в скрипте: вдали качка мельче пикселя, и
    // считать её значит платить за то, чего не видно.
    float d = length(world.xz - uFocus.xz);
    float fade = clamp(1.0 - d / max(uWaveFade, 1.0), 0.0, 1.0);
    fade = fade * fade * (3.0 - 2.0 * fade);

    float h = waveAt(world.xz, uTime) * (uWaveHeight / 0.53) * fade;
    // Поднимаем ВСЕ верхние вершины плитки, а не только верхнюю грань: у куба
    // грани не делят вершины, и если двигать одну верхнюю грань, боковые стенки
    // остаются на месте — по всему морю расходятся щели ровно в амплитуду
    // волны. Признак «верхняя вершина» — знак aPos.y (куб идёт от -0.5 до 0.5),
    // а не нормаль: у боковой грани нормаль горизонтальна.
    float up = step(0.0, aPos.y);
    world.y += h * up;

    // Нормаль по волне нужна только настоящей ПОВЕРХНОСТИ — у боковых стенок
    // она своя, геометрическая.
    float top = step(0.5, aNormal.y);

    // Нормаль поверхности — из наклона волны (конечные разности): без неё вода
    // остаётся плоско освещённой, и весь рельеф пропадает.
    //
    // Мелкая рябь живёт во ФРАГМЕНТНОМ шейдере (vFade — её затухание): плитка
    // воды — два треугольника на четыре метра, и рябь с метровым периодом в
    // вершинах превратилась бы в шум, а не в рябь.
    float e = 0.6;
    float hx = (waveAt(world.xz + vec2(e, 0.0), uTime) - waveAt(world.xz - vec2(e, 0.0), uTime)) * fade;
    float hz = (waveAt(world.xz + vec2(0.0, e), uTime) - waveAt(world.xz - vec2(0.0, e), uTime)) * fade;
    float k = uWaveHeight / 0.53;
    vec3 n = normalize(vec3(-hx * k, 2.0 * e, -hz * k));
    Normal = mix(transpose(inverse(mat3(model))) * aNormal, n, top);
    vFade = fade;

    FragPos = world.xyz;
    vColor = iColor;
    vAlpha = iAlpha;
    vCrest = clamp(h / max(uWaveHeight, 0.001), -1.0, 1.0);
    gl_Position = uProjection * uView * world;
}
