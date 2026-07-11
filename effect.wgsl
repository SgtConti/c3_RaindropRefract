// Raindrop Refraction (WGSL)
%%FRAGMENTINPUT_STRUCT%%
%%FRAGMENTOUTPUT_STRUCT%%
%%C3PARAMS_STRUCT%%
%%C3_UTILITY_FUNCTIONS%%

%%SAMPLERFRONT_BINDING%% var samplerFront: sampler;
%%TEXTUREFRONT_BINDING%% var textureFront: texture_2d<f32>;
%%SAMPLERBACK_BINDING%% var samplerBack: sampler;
%%TEXTUREBACK_BINDING%% var textureBack: texture_2d<f32>;

struct ShaderParams {
    density: f32,
    size: f32,
    speed: f32,
    randomMag: f32,
    windX: f32,
    strength: f32,
    blurLod: f32,
    seed: f32
};
%%SHADERPARAMS_BINDING%% var<uniform> shaderParams: ShaderParams;

fn hash12(p: vec2<f32>) -> f32 {
    var p3 = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    p3 = p3 + dot(p3, p3.yzx + vec3<f32>(33.33));
    return fract((p3.x + p3.y) * p3.z);
}
fn hash22(p: vec2<f32>) -> vec2<f32> {
    var p3 = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    p3 = p3 + dot(p3, p3.yzx + vec3<f32>(33.33));
    return fract((p3.xx + p3.yz) * p3.zy);
}
fn sampleBase(uv: vec2<f32>) -> vec4<f32> {
    let front = textureSampleLevel(textureFront, samplerFront, uv, shaderParams.blurLod);
    let back = textureSampleLevel(textureBack, samplerBack, uv, shaderParams.blurLod);
    return front + back * (1.0 - front.a);
}
fn addDrop(id: vec2<f32>, f: vec2<f32>, mask0: f32, normal0: vec2<f32>) -> vec3<f32> {
    let dropOn = select(0.0, 1.0, hash12(id + vec2<f32>(shaderParams.seed * 17.0)) <= clamp(shaderParams.density, 0.0, 1.0) * 0.33);
    let h = hash22(id + vec2<f32>(shaderParams.seed * 3.1));
    var center = h - vec2<f32>(0.5);
    center.x = center.x + sin(c3Params.seconds * 1.7 + h.y * 6.28318) * 0.10 * shaderParams.randomMag;
    let d = f - center;
    let sx = 0.20 + 0.18 * h.x;
    let sy = 0.65 + 0.50 * h.y;
    let body = 1.0 - smoothstep(0.2, 1.0, length(vec2<f32>(d.x / sx, d.y / sy)));
    let trailX = 1.0 - smoothstep(0.0, 0.18, abs(d.x));
    let trailY = 1.0 - smoothstep(-0.4, 1.5, d.y);
    let trail = trailX * trailY * smoothstep(-0.25, 0.25, d.y);
    let a = dropOn * max(body, trail * 0.42);
    let n = a * normalize(vec2<f32>(d.x / max(sx, 0.01), d.y / max(sy, 0.01)) + vec2<f32>(0.0001));
    return vec3<f32>(max(mask0, a), normal0.x + n.x, normal0.y + n.y);
}

@fragment
fn main(input: FragmentInput) -> FragmentOutput {
    let dimU = textureDimensions(textureFront);
    let pixelSize = 1.0 / max(vec2<f32>(f32(dimU.x), f32(dimU.y)), vec2<f32>(1.0));
    var p = c3_getLayoutPos(input.fragUV) + vec2<f32>(shaderParams.seed * 137.0, shaderParams.seed * 73.0);
    p.x = p.x - c3Params.seconds * shaderParams.windX;
    p.y = p.y - c3Params.seconds * (130.0 + shaderParams.size * 0.8) * shaderParams.speed;
    let cell = max(14.0, shaderParams.size);
    let g = floor(p / cell);
    let f = fract(p / cell) - vec2<f32>(0.5);
    var mask = 0.0;
    var normal = vec2<f32>(0.0);
    for (var oy: i32 = -1; oy <= 1; oy = oy + 1) {
        for (var ox: i32 = -1; ox <= 1; ox = ox + 1) {
            let r = addDrop(g + vec2<f32>(f32(ox), f32(oy)), f - vec2<f32>(f32(ox), f32(oy)), mask, normal);
            mask = r.x;
            normal = r.yz;
        }
    }
    normal = normal * pixelSize * (8.0 + shaderParams.size * 0.18) * clamp(shaderParams.strength, 0.0, 1.0);
    let base = sampleBase(input.fragUV);
    let refr = sampleBase(input.fragUV + normal);
    var output: FragmentOutput;
    let m = clamp(mask, 0.0, 1.0);
    output.color = vec4<f32>(mix(base.rgb, refr.rgb, m) + vec3<f32>(m * 0.035), max(base.a, m * 0.2));
    return output;
}
