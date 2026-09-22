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
    speedVar: f32,
    fog: f32,
    dew: f32,
    time: f32
};
%%SHADERPARAMS_BINDING%% var<uniform> shaderParams: ShaderParams;

const TAU: f32 = 6.28318530718;
// Hash inputs are folded into [-HASH_WRAP/2, HASH_WRAP/2) before hashing.
// The fold is an exact identity inside that range, so the layout is
// unchanged there; beyond it (cell rows after a long fall, large Seeds) the
// raw input would have lost the low bits the hash depends on.
const HASH_WRAP: f32 = 16384.0;
// cos and sin of the golden angle 2.39996323. Each blur tap direction is the
// previous one rotated by this, which replaces a cos/sin pair per tap.
const GOLDEN: vec2<f32> = vec2<f32>(-0.73736888, 0.67549029);

// Layout position with the same guard as the WebGL shader: a degenerate
// source or layout rectangle would make Construct's helper divide by zero,
// so fall back to texel coordinates in that case.
fn rainLayoutPos(uv: vec2<f32>, pixelSize: vec2<f32>) -> vec2<f32> {
    let srcSpan = c3Params.srcOriginEnd - c3Params.srcOriginStart;
    let layoutSpan = c3Params.layoutEnd - c3Params.layoutStart;
    if (abs(srcSpan.x) > 1e-5 && abs(srcSpan.y) > 1e-5
        && (abs(layoutSpan.x) > 1e-3 || abs(layoutSpan.y) > 1e-3)) {
        let p = c3_getLayoutPos(uv);
        if (max(abs(p.x), abs(p.y)) < 1.0e7) {
            return p;
        }
    }
    return uv / max(pixelSize, vec2<f32>(1e-6));
}

// Texture coordinates per layout unit: the derivative of the mapping
// c3_getLayoutPos inverts. Drop bends and the fog radius are measured in
// layout pixels and this is what carries them into texture coordinates. It
// is not pixelSize: under layer zoom, on high-DPI displays and with
// fullscreen scaling one layout pixel spans several texels. Converting with
// pixelSize weakened the lens on any zoomed or high-DPI view.
fn rainUvPerLayout(pixelSize: vec2<f32>) -> vec2<f32> {
    let srcSpan = c3Params.srcOriginEnd - c3Params.srcOriginStart;
    let layoutSpan = c3Params.layoutEnd - c3Params.layoutStart;
    if (abs(srcSpan.x) > 1e-5 && abs(srcSpan.y) > 1e-5
        && abs(layoutSpan.x) > 1e-3 && abs(layoutSpan.y) > 1e-3) {
        let r = srcSpan / layoutSpan;
        // Half the texture per layout pixel is already absurd; treat anything
        // beyond it as a degenerate rectangle.
        if (max(abs(r.x), abs(r.y)) < 0.5) {
            return r;
        }
    }
    return pixelSize;
}

// Background coordinate for a foreground coordinate. The SDK places the
// background in the destStart..destEnd rectangle, matching the foreground's
// srcStart..srcEnd. For a layer the two coincide, so this is the identity;
// for an object it is what makes the background land under the object. The
// map is affine, so offset and blurred samples go through it unchanged.
fn rainBackUv(uv: vec2<f32>) -> vec2<f32> {
    let s = c3Params.srcEnd - c3Params.srcStart;
    let t = c3Params.destEnd - c3Params.destStart;
    if (abs(s.x) > 1e-5 && abs(s.y) > 1e-5 && abs(t.x) > 1e-5 && abs(t.y) > 1e-5) {
        return mix(c3Params.destStart, c3Params.destEnd, (uv - c3Params.srcStart) / s);
    }
    return uv;
}

// Foreground reads away from the current pixel stay inside the rectangle the
// object was drawn into. For a layer that is the whole view, so nothing
// changes; for an object it stops the lens and the fog taps reading whatever
// the intermediate surface holds beyond the object's edge.
fn rainClampFront(uv: vec2<f32>) -> vec2<f32> {
    let lo = min(c3Params.srcOriginStart, c3Params.srcOriginEnd);
    let hi = max(c3Params.srcOriginStart, c3Params.srcOriginEnd);
    if (hi.x - lo.x > 1e-5 && hi.y - lo.y > 1e-5) {
        return clamp(uv, lo, hi);
    }
    return uv;
}

fn hashFold(q: vec2<f32>) -> vec2<f32> {
    return q - HASH_WRAP * floor((q + vec2<f32>(HASH_WRAP * 0.5)) / HASH_WRAP);
}

fn hash12(q: vec2<f32>) -> f32 {
    let p = hashFold(q);
    var p3 = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    p3 = p3 + dot(p3, p3.yzx + vec3<f32>(33.33));
    return fract((p3.x + p3.y) * p3.z);
}

// Canonical form uses three different constants. With a single scalar, p3.x
// and p3.z are both derived from p.x and stay equal, which measurably worsens
// the 2D uniformity of the pair (chi-square over an 8x8 grid: 90 vs 71 for an
// ideal of ~63). Cheap to fix, so the drop layout gets the better distribution.
fn hash22(q: vec2<f32>) -> vec2<f32> {
    let p = hashFold(q);
    var p3 = fract(vec3<f32>(p.x, p.y, p.x) * vec3<f32>(0.1031, 0.1030, 0.0973));
    p3 = p3 + dot(p3, p3.yzx + vec3<f32>(33.33));
    return fract((p3.xx + p3.yz) * p3.zy);
}

fn safeNormalize(v: vec2<f32>) -> vec2<f32> {
    return v * inverseSqrt(max(dot(v, v), 1e-8));
}

// lod is only ever non-zero for the lens sample: Blur LOD is documented as
// softening the refracted image, not the whole window.
fn sampleBase(uv: vec2<f32>, lod: f32) -> vec4<f32> {
    let front = textureSampleLevel(
        textureFront,
        samplerFront,
        rainClampFront(uv),
        lod
    );
    let back = textureSampleLevel(
        textureBack,
        samplerBack,
        rainBackUv(uv),
        lod
    );
    return front + back * (1.0 - front.a);
}

struct DropAcc {
    mask: f32,
    bend: vec2<f32>,
    shine: f32,
    wipe: f32,
};

// Disc blur on a golden-angle spiral. This is the fogged glass: without it a
// drop is just a lens over an already-sharp scene, which is why drops read as
// a minor detail rather than as water on a window.
fn sampleBlur(uv: vec2<f32>, radius: vec2<f32>, jitter: f32) -> vec4<f32> {
    var acc = sampleBase(uv, 0.0);
    var dir = vec2<f32>(cos(jitter), sin(jitter));
    for (var i: i32 = 1; i < 20; i = i + 1) {
        dir = vec2<f32>(dir.x * GOLDEN.x - dir.y * GOLDEN.y,
                        dir.x * GOLDEN.y + dir.y * GOLDEN.x);
        acc = acc + sampleBase(uv + dir * (sqrt(f32(i) / 19.0) * radius), 0.0);
    }
    return acc / 20.0;
}

// Static condensation beads. They do not fall and carry no track; they sit on
// the glass as little lenses and hold their patch clear of the fog.
fn addDew(
    id: vec2<f32>,
    f: vec2<f32>,
    dewDensity: f32,
    unitScale: f32,
    swept: f32,
    acc0: DropAcc
) -> DropAcc {
    var acc = acc0;
    // A bead's centre lies within a third of a cell of the cell centre and
    // its radius is at most 0.4, so beyond 0.75 it is exactly zero. Skip the
    // hash there; that is most of the eight neighbouring cells.
    if (abs(f.x) >= 0.75 || abs(f.y) >= 0.75) {
        return acc;
    }
    if (hash12(id + vec2<f32>(shaderParams.seed * 13.0 + 4.7)) > dewDensity) {
        return acc;
    }

    let g0 = hash22(id + vec2<f32>(shaderParams.seed * 3.7));
    let c = (g0 - vec2<f32>(0.5)) * 0.66;
    let d = f - c;
    // Beyond the largest radius the body is exactly zero, so the second hash
    // is only paid for pixels the bead can touch.
    if (dot(d, d) >= 0.1681) {
        return acc;
    }
    let g1 = hash22(id.yx + vec2<f32>(23.1, 9.9) + vec2<f32>(shaderParams.seed * 7.1));

    let r = mix(0.14, 0.40, g1.x * g1.x);
    let dist = length(d) / max(r, 0.01);
    var body = 1.0 - smoothstep(mix(0.55, 0.85, g1.y), 1.0, dist);
    // A runner sweeps the condensation out of its path, and a bead under a
    // drop has merged into it, so beads fade wherever water is or has just
    // run. Without this a bead kept its own lens inside a track and under a
    // drop head, which read as a second, off-centre bulge in the image.
    body = body * (1.0 - swept);
    if (body <= 0.0) {
        return acc;
    }

    // Same lens rule as the falling drops, kept clear of power 1.
    let lensPower = mix(1.6, 3.0, g0.y);
    acc.bend = acc.bend - d * (lensPower * body * unitScale);

    let rim = smoothstep(0.55, 0.86, dist)
        * (1.0 - smoothstep(0.90, 1.06, dist));
    let glintPos = vec2<f32>(-0.30, -0.30) + (g1 - vec2<f32>(0.5)) * 0.5;
    let glint = 1.0 - smoothstep(
        0.06,
        mix(0.14, 0.30, g0.x),
        length(d / max(r, 0.01) - glintPos)
    );
    acc.shine = max(acc.shine, body * (rim * 0.26 + glint * mix(0.35, 0.95, g1.y)));
    acc.mask = max(acc.mask, body);
    acc.wipe = max(acc.wipe, body);
    return acc;
}

fn addDrop(
    id: vec2<f32>,
    f: vec2<f32>,
    cellDensity: f32,
    speedFactor: f32,
    t: f32,
    acc0: DropAcc
) -> DropAcc {
    var acc = acc0;
    // A drop reaches at most half a cell sideways, 0.8 of a cell below its
    // centre (the body) and one cell above it (the track), and its centre
    // sits within half a cell of the cell centre plus the sway. Pixels
    // further out than that get exactly zero from every term below, so they
    // can skip even the occupancy hash.
    let sway = 0.035 * abs(shaderParams.randomMag);
    if (abs(f.x) >= 1.0 + sway || f.y >= 1.3) {
        return acc;
    }

    // Bail out before any drop maths runs. The occupancy test was previously
    // only applied to the result, so empty cells still paid for three hashes,
    // five sines and a dozen smoothsteps. At the default density only about
    // 7% of cells hold a drop, so this is where nearly all the cost was.
    if (hash12(id + vec2<f32>(shaderParams.seed * 17.0)) > cellDensity) {
        return acc;
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

    var center = h0 - vec2<f32>(0.5);
    center.x = center.x
        + sin(
            t * mix(0.45, 0.85, h1.x)
                + h2.y * TAU
        ) * 0.035 * shaderParams.randomMag;

    let d = f - center;
    // The same reach, now measured from the drop's actual centre. Every
    // body, track and wipe term is identically zero outside this box, so
    // returning here changes nothing downstream; it just means only pixels
    // the drop can touch pay for the optics and the rest of the maths.
    if (abs(d.x) >= 0.5 || d.y >= 0.8 || d.y <= -1.0) {
        return acc;
    }

    // Optical properties get their own entropy. These two only run for cells
    // that actually hold a drop and pixels the drop reaches.
    let h3 = hash22(
        id.yx + vec2<f32>(7.7, 53.1)
            + vec2<f32>(shaderParams.seed * 23.9)
    );
    let h4 = hash22(
        id + vec2<f32>(67.3, 29.5)
            + vec2<f32>(shaderParams.seed * 31.7)
    );

    let variation = clamp(shaderParams.variation, 0.0, 1.0);
    // A slow, clinging drop leaves a shorter and fainter track than one that is
    // running. Without this a slow column would trail like a fast one.
    let smearAmount = clamp(shaderParams.smear, 0.0, 1.0)
        * mix(0.35, 1.0, speedFactor);

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
    // The track is where the drop has been. The field drifts with the wind
    // at windX layout px/s while the drop falls at its own rate, so a drop
    // blown to the right leaves its track up and to the left, leaning by
    // wind over fall. The old form leaned the track into the wind, by a
    // fixed 0.0015 per px/s capped at 0.05 whatever the fall rate. The clamp
    // keeps the track and its wipe band inside the reach box above.
    let fallRate = (130.0 + shaderParams.size * 0.8) * shaderParams.speed * speedFactor;
    let lean = clamp(-shaderParams.windX / max(abs(fallRate), 1.0), -0.35, 0.35);
    var curve = lean * max(behind, 0.0);
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
    // Sideways bend across the track. This was a normalised vector whose x
    // term saturated within a fraction of a pixel of the centre line, so the
    // sample position flipped sign across the middle of every track and left
    // a seam down it. A clamped ramp reaches the same value at half the core
    // width and passes smoothly through the centre.
    let trailNormal = vec2<f32>(
        clamp(trailX / (0.5 * widthAtY), -1.0, 1.0),
        -0.08
    );
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
    acc.mask = max(acc.mask, a);
    acc.bend = acc.bend + addedBend;
    acc.shine = max(acc.shine, addedShine);
    // Where water is or has just been, the glass is wiped clear of fog. This is
    // deliberately wider and softer than the visible track: the drop clears a
    // band, it does not only clear the bright core of its own trail.
    acc.wipe = max(acc.wipe, max(
        body,
        trailGate * (1.0 - smoothstep(widthAtY * 1.5, widthAtY * 3.0, abs(trailX)))
    ));
    return acc;
}

@fragment
fn main(input: FragmentInput) -> FragmentOutput {
    let dimU = textureDimensions(textureFront);
    let pixelSize = 1.0 / max(
        vec2<f32>(f32(dimU.x), f32(dimU.y)),
        vec2<f32>(1.0)
    );
    let layoutPos = rainLayoutPos(input.fragUV, pixelSize);
    let uvPerLayout = rainUvPerLayout(pixelSize);
    // Time lets events own the clock: at -1 (the default) the runtime clock
    // is used; any value from 0 up is a clock the project advances itself,
    // so it can pause, slow or speed the rain without every drop jumping.
    let t = select(shaderParams.time, c3Params.seconds, shaderParams.time < 0.0);
    var lp = layoutPos
        + vec2<f32>(
            shaderParams.seed * 137.0,
            shaderParams.seed * 73.0
        );
    lp.x = lp.x - t * shaderParams.windX;
    let cell = max(14.0, shaderParams.size);
    let baseFall = (130.0 + shaderParams.size * 0.8) * shaderParams.speed;
    let spread = clamp(shaderParams.speedVar, 0.0, 1.0);
    let dens = clamp(shaderParams.density, 0.0, 1.0) * 0.33;

    let gx = floor(lp.x / cell);
    let fx = fract(lp.x / cell) - 0.5;
    var acc: DropAcc;
    acc.mask = 0.0;
    acc.bend = vec2<f32>(0.0);
    acc.shine = 0.0;
    acc.wipe = 0.0;

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
        let py = lp.y - t * baseFall * colRate;
        let gy = floor(py / cell);
        let fy = fract(py / cell) - 0.5;

        for (var oy: i32 = -1; oy <= 1; oy = oy + 1) {
            acc = addDrop(
                vec2<f32>(colId, gy + f32(oy)),
                vec2<f32>(fx - f32(ox), fy - f32(oy)),
                dens, colRate, t,
                acc
            );
        }
    }

    // Condensation sits still on the glass, so it uses the layout position
    // directly with no fall and no wind drift, on its own finer grid. It is
    // told how much the falling water has wiped this pixel, so beads do not
    // survive inside a track or under a drop.
    let dew = clamp(shaderParams.dew, 0.0, 1.0);
    if (dew > 0.002) {
        let swept = clamp(acc.wipe, 0.0, 1.0);
        let dcell = cell * 0.30;
        let dp = layoutPos
            + vec2<f32>(shaderParams.seed * 211.0, shaderParams.seed * 97.0);
        let dg = floor(dp / dcell);
        let df = fract(dp / dcell) - vec2<f32>(0.5);
        for (var oy: i32 = -1; oy <= 1; oy = oy + 1) {
            for (var ox: i32 = -1; ox <= 1; ox = ox + 1) {
                let o = vec2<f32>(f32(ox), f32(oy));
                acc = addDew(dg + o, df - o, dew * 0.75, 0.30, swept, acc);
            }
        }
    }

    // acc.bend is in cell units, so scale by the cell size to reach layout
    // pixels and by uvPerLayout to reach texture coords. Strength deliberately
    // does NOT scale this: it would scale the lens power with it, and any drop
    // whose power passed through 1 on the way down would collapse to a flat
    // disc. Strength blends the refracted image instead, which has the same
    // end points and keeps every drop a proper lens at every setting.
    let offset = acc.bend * cell * uvPerLayout;
    let m = clamp(acc.mask, 0.0, 1.0);

    // Fogged glass. The window is blurred everywhere except where water is or
    // has run, so drops and their tracks read as clear channels through
    // condensation rather than as lenses over an already-sharp scene. Fog at 0
    // skips the whole tap loop and costs nothing.
    let fogAmt = clamp(shaderParams.fog, 0.0, 1.0);
    var base: vec4<f32>;
    if (fogAmt > 0.002) {
        let clearness = clamp(acc.wipe, 0.0, 1.0);
        // The radius is in layout pixels, converted like the lens offset so
        // the haze keeps its proportion to the drops under zoom and on
        // high-DPI displays. It is capped in texels so the 20-tap disc never
        // spreads thin enough to show its taps.
        let radius = min(abs(uvPerLayout) * (fogAmt * 11.0), pixelSize * 16.0)
            * (1.0 - clearness);
        // Rotate the tap spiral per pixel so the disc's undersampling shows up
        // as dither rather than as rings. Interleaved gradient noise is used
        // rather than a hash because its pattern is far finer grained, which
        // matters on hard edges where disc variance is highest.
        let px = floor(input.fragUV / max(pixelSize, vec2<f32>(1e-6)));
        let jitter = fract(52.9829189
            * fract(0.06711056 * px.x + 0.00583715 * px.y)) * TAU;
        base = sampleBlur(input.fragUV, radius, jitter);
    } else {
        base = sampleBase(input.fragUV, 0.0);
    }

    // The lens sample stays sharp: looking through a bead you see a clear,
    // inverted image, not the fogged film around it. Where there is no water
    // the offset is zero and the blend weight is zero, so skip the fetch.
    var refr = base;
    if (m > 0.0) {
        refr = sampleBase(input.fragUV + offset, shaderParams.blurLod);
    }
    let w = m * clamp(shaderParams.strength, 0.0, 1.0);
    let glow = acc.shine * 0.075 + m * 0.010;
    let rgb = mix(base.rgb, refr.rgb, w) + vec3<f32>(glow);
    // Premultiplied output: alpha follows the same blend as the colour, plus
    // the light the highlights add. Over an opaque scene that is 1, as it
    // was; over nothing, drops now vanish apart from their glints instead of
    // leaving a faint grey disc.
    var output: FragmentOutput;
    output.color = vec4<f32>(rgb, min(1.0, mix(base.a, refr.a, w) + glow));
    return output;
}
