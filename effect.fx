// Raindrop Refraction (WebGL 1 GLSL ES 1.0)
// Inspired by the provided Shadertoy shader: layered grid drops using sin() fields.
// Features: density, size(px), speed, randomness, wind X, anisotropic trails (grow as drops fall), subtle chromatic refraction.
// Designed to work as a Layer effect: blends-background + must-predraw.

precision mediump float;

varying vec2 vTex;

uniform sampler2D samplerFront;
uniform sampler2D samplerBack;

uniform vec2 srcOriginStart;
uniform vec2 srcOriginEnd;
uniform vec2 pixelSize;
uniform float seconds;

// Params
uniform float uDensity;     // 0..1
uniform float uSize;        // pixels
uniform float uSpeed;
uniform float uRandomMag;
uniform float uWindX;       // -1..1-ish
uniform float uStrength;
uniform float uBlurLod;
uniform float uSeed;

// Shadertoy-like rand/noise (value noise returning vec2)
vec2 rand2(vec2 c){
    mat2 m = mat2(12.9898, 0.16180, 78.233, 0.31415);
    return fract(sin(m * c) * vec2(43758.5453, 14142.1));
}

vec2 noise2(vec2 p){
    vec2 co = floor(p);
    vec2 mu = fract(p);
    mu = 3.0*mu*mu - 2.0*mu*mu*mu;
    vec2 a = rand2(co + vec2(0.0,0.0));
    vec2 b = rand2(co + vec2(1.0,0.0));
    vec2 c = rand2(co + vec2(0.0,1.0));
    vec2 d = rand2(co + vec2(1.0,1.0));
    return mix(mix(a,b,mu.x), mix(c,d,mu.x), mu.y);
}

// poor-man blur (5 taps)
vec4 blur5(sampler2D s, vec2 uv, float radiusPx)
{
    vec2 o = pixelSize * radiusPx;
    vec4 c = texture2D(s, uv) * 0.36;
    c += texture2D(s, uv + vec2( o.x, 0.0)) * 0.16;
    c += texture2D(s, uv + vec2(-o.x, 0.0)) * 0.16;
    c += texture2D(s, uv + vec2(0.0,  o.y)) * 0.16;
    c += texture2D(s, uv + vec2(0.0, -o.y)) * 0.16;
    return c;
}


float c3_round(float x) { return floor(x + 0.5); }
vec2 c3_round(vec2 x) { return floor(x + 0.5); }
vec3 c3_round(vec3 x) { return floor(x + 0.5); }
vec4 c3_round(vec4 x) { return floor(x + 0.5); }

void main(void)
{
    // normalized coords in source rect
    vec2 u = (vTex - srcOriginStart) / (srcOriginEnd - srcOriginStart);

    // base compositing (premultiplied over)
    vec4 front = texture2D(samplerFront, vTex);
    vec4 back  = texture2D(samplerBack, vTex);
    vec4 base  = front + back * (1.0 - front.a);

    float t = seconds * uSpeed;

    // displacement noise (smooth)
    vec2 v = (u * 0.1) + uSeed;
    vec2 disp = noise2(v * 200.0);

    // blur baseline like textureLod
    vec4 frontBase = blur5(samplerFront, vTex, max(0.0, uBlurLod) * 1.2);
    vec4 backBase  = blur5(samplerBack,  vTex, max(0.0, uBlurLod) * 1.2);

    // size in pixels -> uv scale
    float radiusPx = clamp(uSize, 1.0, 256.0);
    float sizeScale = radiusPx / 64.0;

    // accumulate offsets and coverage (branchless)
    vec2 offAcc = vec2(0.0);
    float wAcc = 0.0;
    

    // Wind: constant horizontal drift + slight oscillation
    float wind = (uWindX * 0.06) * t + 0.01 * sin(t * 0.7 + uSeed * 9.1);

    // 4 layers like reference (r = 4..1)
    for (int ir = 4; ir >= 1; --ir)
    {
        float r = float(ir);

        // Particle-style drops: no tiled cell identity => avoids wrap/teleport artifacts.
        const int K = 26;

        float radiusUvBase = (radiusPx * pixelSize.y) * (0.80 + 0.22 * (5.0 - r));

        for (int i = 0; i < K; ++i)
        {
            float fi = float(i) + r * 91.0;

            vec2 rr  = rand2(vec2(fi + uSeed * 19.7, fi + 3.1));
            vec2 rr2 = rand2(vec2(fi + uSeed * 77.1, fi + 11.3));
            vec2 rr3 = rand2(vec2(fi + uSeed * 13.9, fi + 47.7));

            float h  = rr.x;
            float h2 = rr2.y;
            float h3 = rr3.x;

            vec2 spawn = vec2(rand2(vec2(fi + 1.0, fi + 2.0)).x,
                              rand2(vec2(fi + 3.0, fi + 4.0)).y);

            float fall  = (0.06 + 0.24 * h2) * uSpeed;     // DOWN (+Y)
            float drift = (uWindX * 0.06) * (0.55 + 0.90 * h3);

            float wob = (rand2(vec2(fi + 9.0, fi + 10.0)).x - 0.5) * 0.06 * uRandomMag;
            float wobX = sin(t * 1.7 + fi * 4.1) * wob;

            // Screen-drop behavior approximation (no persistence available in single-pass):
// - start "stuck"/slow
// - then accelerate downward ("run")
float rate = (0.10 + 0.65 * h3);
float lt = fract(t * rate + h2);               // per-drop life phase [0..1)
float stick = 1.0 - smoothstep(0.18, 0.38, lt); // 1 early, 0 later
float run = smoothstep(0.25, 0.55, lt);         // 0 early, 1 later

// optional "merge": some drops become larger runners
float merge = step(h, 0.18 * uRandomMag);
float fallMul = mix(0.30, 1.45, merge);
float driftMul = mix(0.55, 1.10, merge);

float yMove = fall * fallMul * (0.02 * lt * stick + (run * run) * lt);
float xMove = (drift * driftMul) * t + wobX * (0.35 + 0.65 * stick) * mix(1.0, 0.35, run);

vec2 posRaw = spawn + vec2(xMove, yMove);
            vec2 pos = fract(posRaw);
            // Fade near wrap edges to hide teleport/repositioning
            float edgeWrap = min(min(pos.x, 1.0 - pos.x), min(pos.y, 1.0 - pos.y));
            float edgeFade = smoothstep(0.05, 0.18, edgeWrap);

            float keep = step(h, clamp(uDensity, 0.0, 1.0) * (0.42 + 0.16 * (5.0 - r)));

            vec2 duv = u - pos;
            duv = duv - floor(duv + vec2(0.5));

            float rad = radiusUvBase * (0.75 + 0.65 * h2);

            // --- Drop shape (more variance, no vertical smear) ---
float v0 = rr2.x;
float v1 = rr3.y;

// Stronger per-drop variance
float localRad = rad * mix(0.55, 1.55, v1) * mix(1.0, 1.55, merge);
float ax = mix(0.70, 1.45, v0);   // ellipse X
float ay = mix(0.55, 1.35, v1);   // ellipse Y

// slight random rotation so shapes aren't aligned
float ang = (v0 - 0.5) * 0.9;
float ca = cos(ang), sa = sin(ang);
mat2 rot = mat2(ca, -sa, sa, ca);

// teardrop-ish asymmetry: shift head upward/downward a bit
vec2 duvR = rot * duv;
            // Small fluid-like warp (no state) to avoid rigid shapes
            vec2 flow = noise2((u * 0.35 + vec2(0.0, t * 0.02)) * 140.0 + vec2(fi * 0.09, fi * 0.13)) - 0.5;
            duvR += flow * localRad * (0.20 + 0.55 * uRandomMag) * mix(1.0, 0.35, run);
duvR.y += (v1 - 0.5) * localRad * 0.20;

vec2 duvE = vec2(duvR.x * ax, duvR.y * ay);

float bodyD = length(duvE) - localRad;
float body = 1.0 - smoothstep(0.0, localRad * 0.55, bodyD);

// Edge wobble varies per-drop (breaks "stamped" look)
vec2 n2 = noise2((u * 0.22 + vec2(0.0, t * 0.012)) * 170.0 + vec2(fi * 0.17, fi * 0.13)) - 0.5;
float wobStr = mix(0.08, 0.45, v0) * localRad;
float edge = 1.0 - smoothstep(0.0, localRad * 0.85, abs(bodyD) + n2.x * wobStr);
body *= mix(0.78, 1.22, edge);

// Lifetime fade (varies per-drop)
float life = fract(t * (0.05 + 0.26 * h3) + h2 + v0 * 0.71);
float fade = smoothstep(0.00, 0.16, life) * (1.0 - smoothstep(mix(0.55, 0.80, v1), 1.00, life));

float thick = clamp(body, 0.0, 1.0);
float a = keep * fade * thick * edgeFade;

float w = a * (0.72 + 0.24 * (5.0 - r));

// Normal for refraction: compute from ellipse space, then rotate back
// Normal for refraction: gradient of rotated ellipse (reduces axis bias)
vec2 gradR = vec2(duvR.x * ax * ax, duvR.y * ay * ay);
vec2 grad = vec2(ca * gradR.x + sa * gradR.y,
                 -sa * gradR.x + ca * gradR.y);
grad = normalize(grad + vec2(1e-5));
vec3 nrm = normalize(vec3(-grad.x, -grad.y, 1.25));

// subtle highlight/shadow (varies per drop)
vec3 L = normalize(vec3(0.28, -0.22, 1.0));
float specPow = mix(18.0, 40.0, v0);
float spec = pow(clamp(dot(nrm, L), 0.0, 1.0), specPow);
float shade = spec * mix(0.08, 0.18, v1) - thick * mix(0.015, 0.05, v0);float amp = (0.022 * uStrength) * (localRad / max(radiusUvBase, 1e-6)) * mix(0.75, 1.35, thick) * mix(0.75, 1.30, v1);

// No trail bias (removes "stilk")
vec2 trailBias = vec2(0.0);
vec2 off = nrm.xy * amp + trailBias;


offAcc += off * w;
            wAcc += w;
        }
    }

float wLin = max(wAcc, 0.0);
    float w = 1.0 - exp(-wLin * 1.25);
    vec2 off = offAcc / max(wLin, 1e-5);

    // Chromatic refraction (very subtle RGB split)
    float cs = 0.08;
    vec2 offR = off * (1.0 + cs);
    vec2 offB = off * (1.0 - cs);

    // Refract BACKGROUND (other layers)
    vec4 bR = texture2D(samplerBack, vTex - offR);
    vec4 bG = texture2D(samplerBack, vTex - off);
    vec4 bB = texture2D(samplerBack, vTex - offB);
    vec4 refrBack = vec4(bR.r, bG.g, bB.b, 1.0);

    vec4 wetBack = mix(backBase, refrBack, 0.90);

    // Optional subtle wobble of the layer itself (keeps effect visible even on opaque pixels)
    vec4 fR = texture2D(samplerFront, vTex - offR);
    vec4 fG = texture2D(samplerFront, vTex - off);
    vec4 fB = texture2D(samplerFront, vTex - offB);
    vec4 refrFront = vec4(fR.r, fG.g, fB.b, fG.a);
    vec4 wetFront = mix(frontBase, refrFront, 0.65);
    front = mix(front, wetFront, w * 0.10);

    // Composite: front over refracted background
    vec4 refrBase = front + wetBack * (1.0 - front.a);

    vec4 outCol = mix(base, refrBase, w);
    // Ensure droplets are visible on transparent layers
    outCol.a = max(front.a, base.a);
    
    gl_FragColor = outCol;
}
