// Raindrop Refraction (WebGL)
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif

varying vec2 vTex;
uniform sampler2D samplerFront;
uniform sampler2D samplerBack;
uniform vec2 srcOriginStart;
uniform vec2 srcOriginEnd;
uniform vec2 layoutStart;
uniform vec2 layoutEnd;
uniform vec2 pixelSize;
uniform float seconds;
uniform float uDensity;
uniform float uSize;
uniform float uSpeed;
uniform float uRandomMag;
uniform float uWindX;
uniform float uStrength;
uniform float uBlurLod;
uniform float uSeed;
uniform float uVariation;
uniform float uSmear;

const float TAU = 6.28318530718;

float hash12(vec2 p){
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Canonical form uses three different constants. With a single scalar, p3.x
// and p3.z are both derived from p.x and stay equal, which measurably worsens
// the 2D uniformity of the pair (chi-square over an 8x8 grid: 90 vs 71 for an
// ideal of ~63). Cheap to fix, so the drop layout gets the better distribution.
vec2 hash22(vec2 p){
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

vec2 safeNormalize(vec2 v){
    return v * inversesqrt(max(dot(v, v), 1e-8));
}

vec4 sampleBase(vec2 uv){
    vec4 front = texture2D(samplerFront, uv);
    vec4 back = texture2D(samplerBack, uv);
    return front + back * (1.0 - front.a);
}

void addDrop(
    vec2 id,
    vec2 f,
    inout float mask,
    inout vec2 normal,
    inout float shine
){
    float density = clamp(uDensity, 0.0, 1.0);
    float variation = clamp(uVariation, 0.0, 1.0);
    float smearAmount = clamp(uSmear, 0.0, 1.0);

    // Bail out before any drop maths runs. The occupancy test was previously
    // only applied to the result, so empty cells still paid for three hashes,
    // five sines and a dozen smoothsteps. At the default density only about
    // 7% of cells hold a drop, so this is where nearly all the cost was.
    if (hash12(id + vec2(uSeed * 17.0)) > density * 0.33)
        return;

    vec2 h0 = hash22(id + vec2(uSeed * 3.1));
    vec2 h1 = hash22(id.yx + vec2(19.7, 7.3) + vec2(uSeed * 5.7));
    vec2 h2 = hash22(id + vec2(41.2, 13.9) + vec2(uSeed * 11.3));

    vec2 center = h0 - 0.5;
    center.x += sin(
        seconds * mix(0.45, 0.85, h1.x) + h2.y * TAU
    ) * 0.035 * uRandomMag;

    vec2 d = f - center;
    float sizeKey = h1.y * h1.y;
    float runner = smoothstep(0.54, 0.84, h2.x)
        * smoothstep(0.24, 0.62, sizeKey);
    float sx = mix(0.105, 0.31, sizeKey);
    float sy = sx * mix(0.92, 1.34, h0.y);
    sx *= mix(1.0, 0.88, runner * variation);
    sy *= mix(1.0, mix(1.35, 1.82, h1.x), runner * variation);

    float yUnit = clamp(d.y / max(sy, 0.01), -1.0, 1.0);
    float sideScale = 1.0
        + yUnit * mix(0.06, 0.19, runner) * variation;
    float centerBend = (h2.y - 0.5) * 0.032
        * (1.0 - abs(yUnit)) * variation;
    vec2 bodyUv = vec2(
        (d.x - centerBend) / max(sx * sideScale, 0.01),
        d.y / max(sy, 0.01)
    );
    float surface = 1.0 + variation * (
        sin(bodyUv.y * 4.0 + h0.x * TAU) * 0.018
        + sin((bodyUv.x - bodyUv.y) * 6.0 + h2.y * TAU) * 0.012
    );
    float bodyDist = length(bodyUv) / max(surface, 0.90);
    float body = 1.0 - smoothstep(0.70, 1.0, bodyDist);

    float smearClass = max(
        runner,
        smoothstep(0.72, 0.96, h0.x)
            * smoothstep(0.38, 0.68, sizeKey) * 0.45
    );
    float trailLength = mix(0.12, 1.34, smearClass)
        * mix(0.25, 1.15, smearAmount);
    // A drop two cells below can be as close as 1.0 cell, and only the -1..1
    // neighbourhood is sampled. Capping the reach here keeps long tracks a
    // consistent length instead of letting them truncate on cell alignment.
    trailLength = min(trailLength, 1.0 - sy * 0.18);
    float behind = -d.y - sy * 0.18;
    float trailProgress = clamp(
        behind / max(trailLength, 0.01),
        0.0,
        1.0
    );
    float trailGate = smoothstep(-0.03, 0.04, behind)
        * (1.0 - smoothstep(0.80, 1.0, trailProgress));
    float curve = clamp(uWindX * 0.0015, -0.05, 0.05)
        * trailProgress;
    curve += (h0.x - 0.5) * 0.025
        * trailProgress * variation;
    curve += sin(trailProgress * TAU + h2.y * TAU)
        * 0.015 * trailProgress * variation;
    float trailX = d.x - curve;
    float widthAtY = max(
        0.018,
        mix(sx * 0.40, 0.018, trailProgress)
    );
    widthAtY *= 1.0 + sin(
        trailProgress * mix(8.0, 13.0, h1.x) + h0.y * TAU
    ) * 0.10 * variation;
    float trailCore = 1.0 - smoothstep(
        widthAtY * 0.22,
        widthAtY,
        abs(trailX)
    );
    float wetFilm = 1.0 - smoothstep(
        widthAtY,
        widthAtY * 2.15,
        abs(trailX)
    );
    float trailWeight = mix(0.055, 0.58, smearClass)
        * smearAmount;
    float trail = trailGate
        * (trailCore * 0.78 + wetFilm * 0.16)
        * trailWeight;

    float a = max(body, trail);
    mask = max(mask, a);

    vec2 bodyNormal = safeNormalize(vec2(
        (d.x - centerBend) / max(sx * sx, 0.001),
        d.y / max(sy * sy, 0.001)
    ));
    vec2 trailNormal = safeNormalize(vec2(
        trailX / max(widthAtY * widthAtY, 0.001),
        -0.08
    ));
    vec2 dropNormal = bodyNormal * body + trailNormal * trail;
    normal += safeNormalize(dropNormal)
        * max(body, trail) * mix(0.78, 1.18, sizeKey);

    float rim = smoothstep(0.58, 0.84, bodyDist)
        * (1.0 - smoothstep(0.89, 1.03, bodyDist));
    float glint = 1.0 - smoothstep(
        0.07,
        0.24,
        length(bodyUv - vec2(-0.34, -0.34))
    );
    shine = max(
        shine,
        body * (rim * 0.34 + glint * 0.72)
    );
}

void main(void){
    vec2 n = (vTex - srcOriginStart) / max(srcOriginEnd - srcOriginStart, vec2(1e-6));
    vec2 layoutPos = mix(layoutStart, layoutEnd, n);
    float cell = max(14.0, uSize);
    vec2 p = layoutPos + vec2(uSeed * 137.0, uSeed * 73.0);
    p.x -= seconds * uWindX;
    p.y -= seconds * (130.0 + uSize * 0.8) * uSpeed;
    vec2 g = floor(p / cell);
    vec2 f = fract(p / cell) - 0.5;
    float mask = 0.0;
    vec2 normal = vec2(0.0);
    float shine = 0.0;

    for (int oy = -1; oy <= 1; oy++){
        for (int ox = -1; ox <= 1; ox++){
            vec2 offset = vec2(float(ox), float(oy));
            addDrop(g + offset, f - offset, mask, normal, shine);
        }
    }

    // Kept so uBlurLod stays referenced: an unused uniform is stripped by the
    // compiler and its location lookup would come back null. WebGL 1 has no
    // fragment-stage LOD sampling, so Blur LOD only blurs on WebGPU.
    float lodBoost = 1.0 + 0.02 * clamp(uBlurLod, 0.0, 4.0);
    normal *= pixelSize * (8.0 + uSize * 0.18)
        * clamp(uStrength, 0.0, 1.0) * lodBoost;
    vec4 base = sampleBase(vTex);
    vec4 refr = sampleBase(vTex + normal);
    float m = clamp(mask, 0.0, 1.0);
    vec3 rgb = mix(base.rgb, refr.rgb, m);
    rgb += vec3(shine * 0.075 + m * 0.010);
    gl_FragColor = vec4(rgb, max(base.a, m * 0.2));
}
