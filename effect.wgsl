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
    seed: f32,
    variation: f32,
    smear: f32,
    speedVar: f32
};
%%SHADERPARAMS_BINDING%% var<uniform> shaderParams: ShaderParams;

const TAU: f32 = 6.28318530718;

fn hash12(p: vec2<f32>) -> f32 {
    var p3 = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    p3 = p3 + dot(p3, p3.yzx + vec3<f32>(33.33));
    return fract((p3.x + p3.y) * p3.z);
}

// Canonical form uses three different constants. With a single scalar, p3.x
// and p3.z are both derived from p.x and stay equal, which measurably worsens
// the 2D uniformity of the pair (chi-square over an 8x8 grid: 90 vs 71 for an
// ideal of ~63). Cheap to fix, so the drop layout gets the better distribution.
fn hash22(p: vec2<f32>) -> vec2<f32> {
    var p3 = fract(vec3<f32>(p.x, p.y, p.x) * vec3<f32>(0.1031, 0.1030, 0.0973));
    p3 = p3 + dot(p3, p3.yzx + vec3<f32>(33.33));
    return fract((p3.xx + p3.yz) * p3.zy);
}

fn safeNormalize(v: vec2<f32>) -> vec2<f32> {
    return v * inverseSqrt(max(dot(v, v), 1e-8));
}

fn sampleBase(uv: vec2<f32>) -> vec4<f32> {
    let front = textureSampleLevel(
        textureFront,
        samplerFront,
        uv,
        shaderParams.blurLod
    );
    let back = textureSampleLevel(
        textureBack,
        samplerBack,
        uv,
        shaderParams.blurLod
    );
    return front + back * (1.0 - front.a);
}

fn addDrop(
    id: vec2<f32>,
    f: vec2<f32>,
    cellDensity: f32,
    speedFactor: f32,
    mask0: f32,
    bend0: vec2<f32>,
    shine0: f32
) -> vec4<f32> {
    let variation = clamp(shaderParams.variation, 0.0, 1.0);
    // A slow, clinging drop leaves a shorter and fainter track than one that is
    // running. Without this a slow column would trail like a fast one.
    let smearAmount = clamp(shaderParams.smear, 0.0, 1.0)
        * mix(0.35, 1.0, speedFactor);

    // Bail out before any drop maths runs. The occupancy test was previously
    // only applied to the result, so empty cells still paid for three hashes,
    // five sines and a dozen smoothsteps. At the default density only about
    // 7% of cells hold a drop, so this is where nearly all the cost was.
    if (hash12(id + vec2<f32>(shaderParams.seed * 17.0)) > cellDensity) {
        return vec4<f32>(mask0, bend0.x, bend0.y, shine0);
    }

    let h0 = hash22(id + vec2<f32>(shaderParams.seed * 3.1));
    let h1 = hash22(
        id.yx + vec2<f32>(19.7, 7.3)
            + vec2<f32>(shaderParams.seed * 5.7)
    );
    let h2 = hash22(
        id + vec2<f32>(41.2, 13.9)
            + vec2<f32>(shaderParams.seed * 11.3)
    );
    // Optical properties get their own entropy. These two only run for cells
    // that actually hold a drop, so they cost about 1.3 hashes per pixel.
    let h3 = hash22(
        id.yx + vec2<f32>(7.7, 53.1)
            + vec2<f32>(shaderParams.seed * 23.9)
    );
    let h4 = hash22(
        id + vec2<f32>(67.3, 29.5)
            + vec2<f32>(shaderParams.seed * 31.7)
    );

    var center = h0 - vec2<f32>(0.5);
    center.x = center.x
        + sin(
            c3Params.seconds * mix(0.45, 0.85, h1.x)
                + h2.y * TAU
        ) * 0.035 * shaderParams.randomMag;

    let d = f - center;
    let sizeKey = h1.y * h1.y;
    let runner = smoothstep(0.54, 0.84, h2.x)
        * smoothstep(0.24, 0.62, sizeKey);
    var sx = mix(0.105, 0.31, sizeKey);
    var sy = sx * mix(0.92, 1.34, h0.y);
    sx = sx * mix(1.0, 0.88, runner * variation);
    sy = sy * mix(
        1.0,
        mix(1.35, 1.82, h1.x),
        runner * variation
    );

    let yUnit = clamp(d.y / max(sy, 0.01), -1.0, 1.0);
    let sideScale = 1.0
        + yUnit * mix(0.06, 0.19, runner) * variation;
    let centerBend = (h2.y - 0.5) * 0.032
        * (1.0 - abs(yUnit)) * variation;
    let bodyUv = vec2<f32>(
        (d.x - centerBend) / max(sx * sideScale, 0.01),
        d.y / max(sy, 0.01)
    );
    let surface = 1.0 + variation * (
        sin(bodyUv.y * 4.0 + h0.x * TAU) * 0.018
        + sin((bodyUv.x - bodyUv.y) * 6.0 + h2.y * TAU) * 0.012
    );
    let bodyDist = length(bodyUv) / max(surface, 0.90);
    // Per-drop edge softness: some beads sit crisp on the glass, others read as
    // flatter, half-wetted smears.
    let body = 1.0 - smoothstep(mix(0.52, 0.86, h3.x), 1.0, bodyDist);

    let smearClass = max(
        runner,
        smoothstep(0.72, 0.96, h0.x)
            * smoothstep(0.38, 0.68, sizeKey) * 0.45
    );
    // A drop two cells below can be as close as 1.0 cell, and only the -1..1
    // neighbourhood is sampled. Capping the reach here keeps long tracks a
    // consistent length instead of letting them truncate on cell alignment.
    let trailLength = min(
        mix(0.12, 1.34, smearClass) * mix(0.25, 1.15, smearAmount),
        1.0 - sy * 0.18
    );
    let behind = -d.y - sy * 0.18;
    let trailProgress = clamp(
        behind / max(trailLength, 0.01),
        0.0,
        1.0
    );
    let trailGate = smoothstep(-0.03, 0.04, behind)
        * (1.0 - smoothstep(0.80, 1.0, trailProgress));
    var curve = clamp(shaderParams.windX * 0.0015, -0.05, 0.05)
        * trailProgress;
    curve = curve + (h0.x - 0.5) * 0.025
        * trailProgress * variation;
    curve = curve
        + sin(trailProgress * TAU + h2.y * TAU)
            * 0.015 * trailProgress * variation;
    let trailX = d.x - curve;
    var widthAtY = max(
        0.018,
        mix(sx * 0.40, 0.018, trailProgress)
    );
    widthAtY = widthAtY * (
        1.0 + sin(
            trailProgress * mix(8.0, 13.0, h1.x) + h0.y * TAU
        ) * 0.10 * variation
    );
    let trailCore = 1.0 - smoothstep(
        widthAtY * 0.22,
        widthAtY,
        abs(trailX)
    );
    let wetFilm = 1.0 - smoothstep(
        widthAtY,
        widthAtY * 2.15,
        abs(trailX)
    );
    let trailWeight = mix(0.055, 0.58, smearClass)
        * smearAmount;
    let trail = trailGate
        * (trailCore * 0.78 + wetFilm * 0.16)
        * trailWeight;

    let a = max(body, trail);
    let bodyNormal = safeNormalize(vec2<f32>(
        (d.x - centerBend) / max(sx * sx, 0.001),
        d.y / max(sy * sy, 0.001)
    ));
    let trailNormal = safeNormalize(vec2<f32>(
        trailX / max(widthAtY * widthAtY, 0.001),
        -0.08
    ));
    // A bead is a lens, not a smudge: it samples the scene mirrored and
    // magnified about its own centre. The previous code normalised this
    // vector, so every drop bent the background by an identical amount and
    // they all read the same. Offsetting by -d instead keeps the magnitude
    // proportional to distance from the centre, which is what inverts the
    // image, and refractive power varies per drop so no two beads match.
    // The drop samples at centre + (1-power)*d, so power 2 is exact inversion,
    // and the range is kept clear of 1 where every ray would collapse onto the
    // centre and the bead would flatten into a disc of one colour.
    let lensPower = mix(1.45, 3.1, h3.x);
    let lensVec = -vec2<f32>(d.x - centerBend, d.y) * lensPower;
    // Toward the rim the surface turns steep, so hand over to an edge bend.
    let edgeVec = bodyNormal * mix(0.06, 0.22, sizeKey);
    let edgeMix = smoothstep(0.40, 0.98, bodyDist);
    let bodyBend = mix(lensVec, lensVec * 0.30 + edgeVec, edgeMix);
    let addedBend = bodyBend * body + trailNormal * (trail * 0.16);

    // Rim and highlight were fixed constants, so every bead carried the same
    // ring and the same specular dot in the same relative spot. Both now vary.
    let rimIn = mix(0.50, 0.68, h4.x);
    let rim = smoothstep(rimIn, rimIn + mix(0.14, 0.30, h3.y), bodyDist)
        * (1.0 - smoothstep(0.90, 1.04, bodyDist));
    let glintPos = vec2<f32>(-0.34, -0.34)
        + (vec2<f32>(h3.y, h4.y) - vec2<f32>(0.5)) * 0.5;
    let glintR = mix(0.10, 0.30, h4.y);
    let glint = 1.0 - smoothstep(
        glintR * 0.3,
        glintR,
        length(bodyUv - glintPos)
    );
    let addedShine = body
        * (rim * mix(0.18, 0.46, h4.x) + glint * mix(0.30, 0.95, h3.x));
    return vec4<f32>(
        max(mask0, a),
        bend0.x + addedBend.x,
        bend0.y + addedBend.y,
        max(shine0, addedShine)
    );
}

@fragment
fn main(input: FragmentInput) -> FragmentOutput {
    let dimU = textureDimensions(textureFront);
    let pixelSize = 1.0 / max(
        vec2<f32>(f32(dimU.x), f32(dimU.y)),
        vec2<f32>(1.0)
    );
    var lp = c3_getLayoutPos(input.fragUV)
        + vec2<f32>(
            shaderParams.seed * 137.0,
            shaderParams.seed * 73.0
        );
    lp.x = lp.x - c3Params.seconds * shaderParams.windX;
    let cell = max(14.0, shaderParams.size);
    let baseFall = (130.0 + shaderParams.size * 0.8) * shaderParams.speed;
    let spread = clamp(shaderParams.speedVar, 0.0, 1.0);
    let dens = clamp(shaderParams.density, 0.0, 1.0) * 0.33;

    let gx = floor(lp.x / cell);
    let fx = fract(lp.x / cell) - 0.5;
    var acc = vec4<f32>(0.0);

    // Each column of cells falls at its own rate, only ever slower than Speed,
    // so raising the spread slows part of the rain instead of speeding the rest
    // up. The rate is keyed to the drop's own column rather than the pixel's,
    // so neighbouring pixels always agree on where a drop is and no seam forms
    // at column edges. Cost is three extra hashes, not three extra grids.
    for (var ox: i32 = -1; ox <= 1; ox = ox + 1) {
        let colId = gx + f32(ox);
        let colRate = mix(
            1.0,
            mix(0.34, 1.0, hash12(vec2<f32>(colId, 91.7) + vec2<f32>(shaderParams.seed))),
            spread
        );
        let py = lp.y - c3Params.seconds * baseFall * colRate;
        let gy = floor(py / cell);
        let fy = fract(py / cell) - 0.5;

        for (var oy: i32 = -1; oy <= 1; oy = oy + 1) {
            acc = addDrop(
                vec2<f32>(colId, gy + f32(oy)),
                vec2<f32>(fx - f32(ox), fy - f32(oy)),
                dens, colRate,
                acc.x, acc.yz, acc.w
            );
        }
    }

    let mask = acc.x;
    let shine = acc.w;
    // acc.yz is in cell units, so scale by the cell size to reach pixels and by
    // pixelSize to reach texture coords. Strength deliberately does NOT scale
    // this: it would scale the lens power with it, and any drop whose power
    // passed through 1 on the way down would collapse to a flat disc. Strength
    // blends the refracted image instead, which has the same end points and
    // keeps every drop a proper lens at every setting.
    let offset = acc.yz * cell * pixelSize;
    let base = sampleBase(input.fragUV);
    let m = clamp(mask, 0.0, 1.0);
    // Skip the refracted fetch where there is no drop. sampleBase takes an
    // explicit LOD, so this is safe in non-uniform control flow.
    var refracted = base.rgb;
    if (m > 0.0) {
        refracted = mix(
            base.rgb,
            sampleBase(input.fragUV + offset).rgb,
            m * clamp(shaderParams.strength, 0.0, 1.0)
        );
    }
    let rgb = refracted + vec3<f32>(shine * 0.075 + m * 0.010);
    var output: FragmentOutput;
    output.color = vec4<f32>(rgb, max(base.a, m * 0.2));
    return output;
}
