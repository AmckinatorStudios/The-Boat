// Освещение — движковое: директива подставляет тот же PBR-блок, которым движок
// рисует всё остальное. Свой шейдер нужен воде ради ФОРМЫ волны и пены, а не
// ради своей модели света: копия BRDF немедленно разошлась бы с оригиналом, и
// вода перестала бы совпадать по свету с палубой, на которой стоит игрок.
#version 330 core
in vec3 FragPos;
in vec3 Normal;
in vec3 vColor;
in float vAlpha;
in float vCrest;
in float vFade;
out vec4 FragColor;

uniform bool uLightmapEnabled;
uniform sampler2D uLightmap;

// Цвет воды приходит ПАРАМЕТРАМИ МАТЕРИАЛА, а не цветом сущности: назначенный
// материал заменяет собой Color сущности (EffectiveColor в движке), да и одно
// число на всю воду честнее двух тысяч одинаковых. Игра меняет их по времени
// суток — закат красит море, а не только небо.
uniform vec3  uDeepColor;    // цвет впадины (спокойная вода)
uniform vec3  uCrestColor;   // цвет гребня
uniform vec3  uFoamColor;    // цвет пены на верхушках
uniform float uFoamSharp;    // насколько узкая полоса пены
uniform float uRipple;       // сила мелкой ряби (наклон нормали)
uniform float uOpacity;
uniform float uTime;
uniform float uReflectDistort; // насколько рябь ломает отражение (в долях экрана)

#include <sage_pbr>

// Рябь считается ЗДЕСЬ, а не в вершинах: плитка воды — два треугольника на
// четыре метра, и волна с метровым периодом в вершинах превратилась бы в шум.
// В высоту рябь не идёт намеренно — высоту знает и ocean.lua, по ней качается
// лодка, и трясти корабль сантиметровой рябью незачем.
vec2 rippleSlope(vec2 p, float t) {
    return vec2(cos(p.x * 1.7 + t * 1.3) * sin(p.y * 0.9 - t * 0.7)
              + cos(p.x * 3.1 - t * 0.9) * 0.4,
                cos(p.y * 1.5 - t * 1.1) * sin(p.x * 1.1 + t * 0.6)
              + cos(p.y * 2.7 + t * 1.2) * 0.4);
}

void main() {
    vec3 N = normalize(Normal);
    // Рябь наклоняет нормаль поверхности, но не трогает борта плитки.
    N = normalize(N + vec3(rippleSlope(FragPos.xz, uTime) * uRipple * vFade, 0.0).xzy);

    // Цвет воды — от впадины к гребню.
    float crest = clamp(vCrest * 0.5 + 0.5, 0.0, 1.0);
    vec3 albedo = mix(uDeepColor, uCrestColor, crest);

    // Пена на самых верхушках: узкая полоса, иначе море становится молочным.
    float foam = smoothstep(uFoamSharp, 1.0, crest);
    albedo = mix(albedo, uFoamColor, foam * 0.4);

    // ТЕНЬ НА ВОДЕ. Освещение движка тень уже учитывает — но у воды почти
    // чёрное альбедо, и вклад прямого солнца в её цвет мал: корабль стоял в
    // море без тени, будто висел над ним. Гасим и собственный цвет воды, и
    // зеркало: настоящая тень на воде видна как раз тем, что в ней пропадает
    // блик неба, а не тем, что вода «темнеет краской».
    float sunShadow = uShadowsEnabled ? SunShadow(FragPos, N, normalize(-uSunDir)) : 0.0;
    albedo *= mix(1.0, 0.66, sunShadow);

    // Отладочные виды движка работают и на воде. Без этого половина кадра (а
    // здесь это океан) оставалась бы обычной в любом режиме разбора, и по
    // картинке нельзя было бы сказать, что видно, а что просто не поддержано.
    if (uShadingMode != 0) {
        vec4 dbg;
        if (DebugShade(uShadingMode, N, FragPos, albedo, 0.0, 0.08, 1.0, vec3(0.0),
                       sunShadow, dbg)) {
            FragColor = vec4(dbg.rgb, 1.0);
            return;
        }
    }

    vec3 V = normalize(uViewPos - FragPos);
    float fresnel = pow(1.0 - clamp(dot(N, V), 0.0, 1.0), 5.0);

    // Отражение. Раньше здесь стояла подмешка цвета неба по Френелю — заглушка,
    // которая давала лишь «вода светлеет к горизонту». Теперь отражается
    // НАСТОЯЩАЯ сцена: корабль, мусор, парус. Плоское отражение снято зеркально
    // относительно уровня моря, читается по экранной позиции и ломается той же
    // рябью, что наклоняет нормаль, — иначе отражение было бы стеклянно ровным
    // на волнующейся воде.
    //
    // Смещение считается от НАКЛОНА, а не от высоты волны: сдвиг отражения — это
    // то, куда «уехал» отражённый луч, а уезжает он именно из-за наклона.
    vec2 distort = rippleSlope(FragPos.xz, uTime) * uRipple * uReflectDistort * vFade;
    vec3 planar = SamplePlanar(distort);
    float planarWeight = uPlanarEnabled ? 1.0 : 0.0;
    // На гребнях с пеной отражение гасим: пена рассеивает свет, и зеркало на
    // ней выглядит как плёнка масла.
    planarWeight *= 1.0 - foam * 0.7;
    planarWeight *= 1.0 - sunShadow * 0.45;

    vec3 indirect = uLightmapEnabled ? texture(uLightmap, vec2(0.0)).rgb
                                     : DefaultIndirect(FragPos, N);
    vec3 lit = ShadePBRplanar(N, FragPos, albedo, 0.0, mix(0.05, 0.30, 1.0 - crest), 1.0, indirect,
                              planar, planarWeight);

    // Прозрачность растёт к гребню: тонкая вершина волны просвечивает, толща
    // впадины — нет.
    float alpha = clamp(vAlpha + foam * 0.2 + fresnel * 0.18, 0.0, 1.0);
    FragColor = vec4(lit, alpha);
}
