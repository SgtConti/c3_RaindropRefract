// Raindrop Refraction (WebGPU WGSL)
// Inspired by provided Shadertoy shader: layered grid drops using sin() fields.
// Features: density, size(px), speed, randomness, wind X, anisotropic trails, subtle chromatic refraction.

%%FRAGMENTINPUT_STRUCT%%
%%FRAGMENTOUTPUT_STRUCT%%
%%C3PARAMS_STRUCT%%
%%C3_UTILITY_FUNCTIONS%%

struct ShaderParams {
    density   : f32,
    size      : f32,   // pixels
    speed     : f32,
    randomMag : f32,
    windX     : f32,
    strength  : f32,
    blurLod   : f32,
    seed      : f32
};

%%SAMPLERFRONT_BINDING%% var samplerFront : sampler;
%%TEXTUREFRONT_BINDING%% var textureFront : texture_2d<f32>;
%%SAMPLERBACK_BINDING%% var samplerBack : sampler;
%%TEXTUREBACK_BINDING%% var textureBack : texture_2d<f32>;
%%SHADERPARAMS_BINDING%% var<uniform> shaderParams : ShaderParams;

fn rand2(c: vec2<f32>) -> vec2<f32> {
    // mat2 mul (12.9898 .16180; 78.233 .31415)
    let mc = vec2<f32>(12.9898 * c.x + 0.16180 * c.y,
                       78.233  * c.x + 0.31415 * c.y);
    return fract(sin(mc) * vec2<f32>(43758.5453, 14142.1));
}

fn noise2(p: vec2<f32>) -> vec2<f32> {
    let co = floor(p);
    var mu = fract(p);
    mu = 3.0 * mu * mu - 2.0 * mu * mu * mu;

    let a = rand2(co + vec2<f32>(0.0, 0.0));
    let b = rand2(co + vec2<f32>(1.0, 0.0));
    let c = rand2(co + vec2<f32>(0.0, 1.0));
    let d = rand2(co + vec2<f32>(1.0, 1.0));

    return mix(mix(a, b, mu.x), mix(c, d, mu.x), mu.y);
}

fn blur5Front(uv: vec2<f32>, radiusPx: f32) -> vec4<f32> {
    let texDim = vec2<f32>(textureDimensions(textureFront));
    let px = 1.0 / texDim;
    let o = px * radiusPx;

    var c = textureSample(textureFront, samplerFront, uv) * 0.36;
    c += textureSample(textureFront, samplerFront, uv + vec2<f32>( o.x, 0.0)) * 0.16;
    c += textureSample(textureFront, samplerFront, uv + vec2<f32>(-o.x, 0.0)) * 0.16;
    c += textureSample(textureFront, samplerFront, uv + vec2<f32>(0.0,  o.y)) * 0.16;
    c += textureSample(textureFront, samplerFront, uv + vec2<f32>(0.0, -o.y)) * 0.16;
    return c;
}

fn blur5Back(uv: vec2<f32>, radiusPx: f32) -> vec4<f32> {
    let texDim = vec2<f32>(textureDimensions(textureBack));
    let px = 1.0 / texDim;
    let o = px * radiusPx;

    var c = textureSample(textureBack, samplerBack, uv) * 0.36;
    c += textureSample(textureBack, samplerBack, uv + vec2<f32>( o.x, 0.0)) * 0.16;
    c += textureSample(textureBack, samplerBack, uv + vec2<f32>(-o.x, 0.0)) * 0.16;
    c += textureSample(textureBack, samplerBack, uv + vec2<f32>(0.0,  o.y)) * 0.16;
    c += textureSample(textureBack, samplerBack, uv + vec2<f32>(0.0, -o.y)) * 0.16;
    return c;
}

@fragment
fn main(input: FragmentInput) -> FragmentOutput {
    let front = textureSample(textureFront, samplerFront, input.fragUV);
    let back  = textureSample(textureBack, samplerBack, input.fragUV);
    let base  = front + back * (1.0 - front.a);

    let u = c3_srcOriginToNorm(input.fragUV);

    let t = c3Params.seconds * shaderParams.speed;

    let disp = noise2(((u * 0.1) + vec2<f32>(shaderParams.seed, shaderParams.seed)) * 200.0);

    let frontBase = blur5Front(input.fragUV, max(0.0, shaderParams.blurLod) * 1.2);
    let backBase  = blur5Back(input.fragUV, max(0.0, shaderParams.blurLod) * 1.2);

    let radiusPx = clamp(shaderParams.size, 1.0, 256.0);
    let sizeScale = radiusPx / 64.0;

    let texDim = vec2<f32>(textureDimensions(textureFront));
    // Wind drift
    let wind = (shaderParams.windX * 0.06) * t + 0.01 * sin(t * 0.7 + shaderParams.seed * 9.1);

    var offAcc = vec2<f32>(0.0, 0.0);
    var wAcc = 0.0;
    

    // Fixed 4-layer loop (uniform control flow)
    for (var ir: i32 = 4; ir >= 1; ir = ir - 1) {
    let r = f32(ir);

    let K: i32 = 26;

    let radiusUvBase = (radiusPx / texDim.y) * (0.80 + 0.22 * (5.0 - r));

    for (var i: i32 = 0; i < K; i = i + 1) {
        let fi = f32(i) + r * 91.0;

        let rr  = rand2(vec2<f32>(fi + shaderParams.seed * 19.7, fi + 3.1));
        let rr2 = rand2(vec2<f32>(fi + shaderParams.seed * 77.1, fi + 11.3));
        let rr3 = rand2(vec2<f32>(fi + shaderParams.seed * 13.9, fi + 47.7));

        let h  = rr.x;
        let h2 = rr2.y;
        let h3 = rr3.x;

        let spawn = vec2<f32>(
            rand2(vec2<f32>(fi + 1.0, fi + 2.0)).x,
            rand2(vec2<f32>(fi + 3.0, fi + 4.0)).y
        );

        let fall  = (0.06 + 0.24 * h2) * shaderParams.speed; // DOWN (+Y)
        let drift = (shaderParams.windX * 0.06) * (0.55 + 0.90 * h3);

        let wob = (rand2(vec2<f32>(fi + 9.0, fi + 10.0)).x - 0.5) * 0.06 * shaderParams.randomMag;
        let wobX = sin(t * 1.7 + fi * 4.1) * wob;

        // Screen-drop behavior approximation (no persistence available in single-pass):
// - start stuck/slow then accelerate ("run")
let rate = (0.10 + 0.65 * h3);
let lt = fract(t * rate + h2);
let stick = 1.0 - smoothstep(0.18, 0.38, lt);
let run = smoothstep(0.25, 0.55, lt);

let merge = step(h, 0.18 * shaderParams.randomMag);
let fallMul = mix(0.30, 1.45, merge);
let driftMul = mix(0.55, 1.10, merge);

let yMove = fall * fallMul * (0.02 * lt * stick + (run * run) * lt);
let xMove = (drift * driftMul) * t + wobX * (0.35 + 0.65 * stick) * mix(1.0, 0.35, run);

let posRaw = spawn + vec2<f32>(xMove, yMove);
        let pos = fract(posRaw);
        // Fade near wrap edges to hide teleport/repositioning
        let edgeWrap = min(min(pos.x, 1.0 - pos.x), min(pos.y, 1.0 - pos.y));
        let edgeFade = smoothstep(0.05, 0.18, edgeWrap);

        let keep = step(h, clamp(shaderParams.density, 0.0, 1.0) * (0.42 + 0.16 * (5.0 - r)));

        var duv = u - pos;
        duv = duv - floor(duv + vec2<f32>(0.5, 0.5));

        let rad = radiusUvBase * (0.75 + 0.65 * h2);

        // --- Drop shape (more variance, no vertical smear) ---
let v0 = rr2.x;
let v1 = rr3.y;

let localRad = rad * mix(0.55, 1.55, v1) * mix(1.0, 1.55, merge);
let ax = mix(0.70, 1.45, v0);
let ay = mix(0.55, 1.35, v1);

let ang = (v0 - 0.5) * 0.9;
let ca = cos(ang);
let sa = sin(ang);
let rot = mat2x2<f32>(ca, -sa, sa, ca);

var duvR = rot * duv;
        // Small fluid-like warp (no state) to avoid rigid shapes
        let flow = noise2((u * 0.35 + vec2<f32>(0.0, t * 0.02)) * 140.0 + vec2<f32>(fi * 0.09, fi * 0.13)) - 0.5;
        duvR = duvR + flow * localRad * (0.20 + 0.55 * shaderParams.randomMag) * mix(1.0, 0.35, run);
duvR.y = duvR.y + (v1 - 0.5) * localRad * 0.20;

let duvE = vec2<f32>(duvR.x * ax, duvR.y * ay);

let bodyD = length(duvE) - localRad;
var body = 1.0 - smoothstep(0.0, localRad * 0.55, bodyD);

let n2 = noise2((u * 0.22 + vec2<f32>(0.0, t * 0.012)) * 170.0 + vec2<f32>(fi * 0.17, fi * 0.13)) - 0.5;
let wobStr = mix(0.08, 0.45, v0) * localRad;
let edge = 1.0 - smoothstep(0.0, localRad * 0.85, abs(bodyD) + n2.x * wobStr);
body = body * mix(0.78, 1.22, edge);

let life = fract(t * (0.05 + 0.26 * h3) + h2 + v0 * 0.71);
let fade = smoothstep(0.00, 0.16, life) * (1.0 - smoothstep(mix(0.55, 0.80, v1), 1.00, life));

let thick = clamp(body, 0.0, 1.0);
let a = keep * fade * thick * edgeFade;

let w = a * (0.72 + 0.24 * (5.0 - r));

// Normal for refraction: gradient of rotated ellipse (reduces axis bias)
let gradR = vec2<f32>(duvR.x * ax * ax, duvR.y * ay * ay);
var grad = vec2<f32>(ca * gradR.x + sa * gradR.y,
                     -sa * gradR.x + ca * gradR.y);
grad = normalize(grad + vec2<f32>(1e-5, 1e-5));
let nrm = normalize(vec3<f32>(-grad.x, -grad.y, 1.25));

let L = normalize(vec3<f32>(0.28, -0.22, 1.0));
let specPow = mix(18.0, 40.0, v0);
let spec = pow(clamp(dot(nrm, L), 0.0, 1.0), specPow);
let shade = spec * mix(0.08, 0.18, v1) - thick * mix(0.015, 0.05, v0);let amp = (0.022 * shaderParams.strength) * (localRad / max(radiusUvBase, 1e-6)) * mix(0.75, 1.35, thick) * mix(0.75, 1.30, v1);

let trailBias = vec2<f32>(0.0, 0.0);
let off = nrm.xy * amp + trailBias;


offAcc = offAcc + off * w;
        wAcc = wAcc + w;
    }
}

let wLin = max(wAcc, 0.0);
    let w = 1.0 - exp(-wLin * 1.25);
    let off = offAcc / max(wLin, 1e-5);

    // Chromatic refraction (very subtle RGB split)
let cs = 0.08;
let offR = off * (1.0 + cs);
let offB = off * (1.0 - cs);

// Refract BACKGROUND (other layers)
let bR = textureSample(textureBack, samplerBack, input.fragUV - offR);
let bG = textureSample(textureBack, samplerBack, input.fragUV - off);
let bB = textureSample(textureBack, samplerBack, input.fragUV - offB);
let refrBack = vec4<f32>(bR.r, bG.g, bB.b, 1.0);
let wetBack = mix(backBase, refrBack, 0.90);

// Optional subtle wobble of the layer itself (keeps effect visible even on opaque pixels)
let fR = textureSample(textureFront, samplerFront, input.fragUV - offR);
let fG = textureSample(textureFront, samplerFront, input.fragUV - off);
let fB = textureSample(textureFront, samplerFront, input.fragUV - offB);
let refrFront = vec4<f32>(fR.r, fG.g, fB.b, fG.a);
let wetFront = mix(frontBase, refrFront, 0.65);
let front2 = mix(front, wetFront, w * 0.10);

// Composite: front over refracted background
let refrBase = front2 + wetBack * (1.0 - front2.a);

var outCol = mix(base, refrBase, w);
    // Ensure droplets are visible on transparent layers: give drop areas non-zero alpha
    outCol.a = max(front.a, base.a);
    

    var output: FragmentOutput;
    output.color = outCol;
    return output;
}
