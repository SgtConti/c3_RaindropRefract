// Raindrop Refraction (WebGL)
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif

varying vec2 vTex;
uniform sampler2D samplerFront;
uniform sampler2D samplerBack;
uniform vec2 srcStart;
uniform vec2 srcEnd;
uniform vec2 srcOriginStart;
uniform vec2 srcOriginEnd;
uniform vec2 destStart;
uniform vec2 destEnd;
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
uniform float uSpeedVar;
uniform float uFog;
uniform float uDew;
uniform float uTime;

const float TAU = 6.28318530718;
// Hash inputs are folded into [-HASH_WRAP/2, HASH_WRAP/2) before hashing.
// The fold is an exact identity inside that range, so the layout is
// unchanged there; beyond it (cell rows after a long fall, large Seeds) the
// raw input would have lost the low bits the hash depends on.
const float HASH_WRAP = 16384.0;
// cos and sin of the golden angle 2.39996323. Each blur tap direction is the
// previous one rotated by this, which replaces a cos/sin pair per tap.
const vec2 GOLDEN = vec2(-0.73736888, 0.67549029);

// Layout position of a texture coordinate, and the texture coordinates per
// layout unit that go with it. One decision covers both, so drop positions
// and the offsets applied to them always share a unit system.
//
// The ratio is the derivative of the position mapping. It is not pixelSize:
// under layer zoom, on high-DPI displays and with fullscreen scaling one
// layout pixel spans several texels, and on the WebGL renderer the texture
// rectangle runs the opposite way to layout y, so the y component here is
// negative. Converting offsets with pixelSize left every lens un-inverted and
// squashed vertically on WebGL, and weakened it on any zoomed or high-DPI view.
//
// That negative y span is also what broke versions before 1.4.1 on WebGL:
// they divided by max(span, 1e-6), which clamped it to +1e-6 and sent the
// field coordinate to ~1e8, where every pixel hashed as its own cell and the
// effect rendered as single-pixel static. The degenerate-rectangle fallback
// below is a backstop that is probably never taken; it keeps the look right
// in texel units at the cost of not tracking layer scrolling.
vec2 c3Layout(vec2 uv, out vec2 uvPerLayout){
    vec2 srcSpan = srcOriginEnd - srcOriginStart;
    vec2 layoutSpan = layoutEnd - layoutStart;
    if (abs(srcSpan.x) > 1e-5 && abs(srcSpan.y) > 1e-5
        && abs(layoutSpan.x) > 1e-3 && abs(layoutSpan.y) > 1e-3){
        vec2 p = mix(layoutStart, layoutEnd, (uv - srcOriginStart) / srcSpan);
        if (max(abs(p.x), abs(p.y)) < 1.0e7){
            uvPerLayout = srcSpan / layoutSpan;
            return p;
        }
    }
    // WebGL texture y runs upward, layout y runs downward: flip so rain
    // still falls on this path, with the matching orientation in the ratio.
    uvPerLayout = vec2(pixelSize.x, -pixelSize.y);
    return vec2(uv.x, 1.0 - uv.y) / max(pixelSize, vec2(1e-6));
}

// Background coordinate for a foreground coordinate. The SDK places the
// background in the destStart..destEnd rectangle, matching the foreground's
// srcStart..srcEnd. For a layer the two coincide, so this is the identity;
// for an object it is what makes the background land under the object. The
// map is affine, so offset and blurred samples go through it unchanged, and
// like the foreground read they are then held inside the rectangle, which
// is what the SDK's own clamp helper exists for.
vec2 c3BackUv(vec2 uv){
    vec2 s = srcEnd - srcStart;
    vec2 t = destEnd - destStart;
    if (abs(s.x) > 1e-5 && abs(s.y) > 1e-5 && abs(t.x) > 1e-5 && abs(t.y) > 1e-5){
        vec2 p = mix(destStart, destEnd, (uv - srcStart) / s);
        return clamp(p, min(destStart, destEnd), max(destStart, destEnd));
    }
    return uv;
}

// Foreground reads away from the current pixel stay inside the rectangle the
// object was drawn into. For a layer that is the whole view, so nothing
// changes; for an object it stops the lens and the fog taps reading whatever
// the intermediate surface holds beyond the object's edge.
vec2 c3ClampFront(vec2 uv){
    vec2 lo = min(srcOriginStart, srcOriginEnd);
    vec2 hi = max(srcOriginStart, srcOriginEnd);
    if (hi.x - lo.x > 1e-5 && hi.y - lo.y > 1e-5)
        return clamp(uv, lo, hi);
    return uv;
}

vec2 hashFold(vec2 q){
    return q - HASH_WRAP * floor((q + HASH_WRAP * 0.5) / HASH_WRAP);
}

float hash12(vec2 q){
    vec2 p = hashFold(q);
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Canonical form uses three different constants. With a single scalar, p3.x
// and p3.z are both derived from p.x and stay equal, which measurably worsens
// the 2D uniformity of the pair (chi-square over an 8x8 grid: 90 vs 71 for an
// ideal of ~63). Cheap to fix, so the drop layout gets the better distribution.
vec2 hash22(vec2 q){
    vec2 p = hashFold(q);
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

vec2 safeNormalize(vec2 v){
    return v * inversesqrt(max(dot(v, v), 1e-8));
}

vec4 sampleBase(vec2 uv){
    vec4 front = texture2D(samplerFront, c3ClampFront(uv));
    vec4 back = texture2D(samplerBack, c3BackUv(uv));
    return front + back * (1.0 - front.a);
}

// Disc blur on a golden-angle spiral. This is the fogged glass: without it a
// drop is just a lens over an already-sharp scene, which is why drops read as
// a minor detail rather than as water on a window.
vec4 sampleBlur(vec2 uv, vec2 radius, float jitter){
    vec4 acc = sampleBase(uv);
    vec2 dir = vec2(cos(jitter), sin(jitter));
    for (int i = 1; i < 20; i++){
        dir = vec2(dir.x * GOLDEN.x - dir.y * GOLDEN.y,
                   dir.x * GOLDEN.y + dir.y * GOLDEN.x);
        acc += sampleBase(uv + dir * (sqrt(float(i) / 19.0) * radius));
    }
    return acc / 20.0;
}

// Static condensation beads. They do not fall and carry no track; they sit on
// the glass as little lenses and hold their patch clear of the fog.
void addDew(
    vec2 id,
    vec2 f,
    float dewDensity,
    float unitScale,
    float swept,
    inout float mask,
    inout vec2 bend,
    inout float shine,
    inout float wipe
){
    // A bead's centre lies within a third of a cell of the cell centre and
    // its radius is at most 0.4, so beyond 0.75 it is exactly zero. Skip the
    // hash there; that is most of the eight neighbouring cells.
    if (abs(f.x) >= 0.75 || abs(f.y) >= 0.75)
        return;
    if (hash12(id + vec2(uSeed * 13.0 + 4.7)) > dewDensity)
        return;

    vec2 g0 = hash22(id + vec2(uSeed * 3.7));
    vec2 c = (g0 - 0.5) * 0.66;
    vec2 d = f - c;
    // Beyond the largest radius the body is exactly zero, so the second hash
    // is only paid for pixels the bead can touch.
    if (dot(d, d) >= 0.1681)
        return;
    vec2 g1 = hash22(id.yx + vec2(23.1, 9.9) + vec2(uSeed * 7.1));

    float r = mix(0.14, 0.40, g1.x * g1.x);
    float dist = length(d) / max(r, 0.01);
    float body = 1.0 - smoothstep(mix(0.55, 0.85, g1.y), 1.0, dist);
    // A runner sweeps the condensation out of its path, and a bead under a
    // drop has merged into it, so beads fade wherever water is or has just
    // run. Without this a bead kept its own lens inside a track and under a
    // drop head, which read as a second, off-centre bulge in the image.
    body *= 1.0 - swept;
    if (body <= 0.0)
        return;

    // Same lens rule as the falling drops, kept clear of power 1.
    float lensPower = mix(1.6, 3.0, g0.y);
    bend += -d * (lensPower * body * unitScale);

    float rim = smoothstep(0.55, 0.86, dist)
        * (1.0 - smoothstep(0.90, 1.06, dist));
    vec2 glintPos = vec2(-0.30, -0.30) + (g1 - 0.5) * 0.5;
    float glint = 1.0 - smoothstep(
        0.06,
        mix(0.14, 0.30, g0.x),
        length(d / max(r, 0.01) - glintPos)
    );
    shine = max(shine, body * (rim * 0.26 + glint * mix(0.35, 0.95, g1.y)));
    mask = max(mask, body);
    wipe = max(wipe, body);
}

void addDrop(
    vec2 id,
    vec2 f,
    float cellDensity,
    float speedFactor,
    float t,
    inout float mask,
    inout vec2 bend,
    inout float shine,
    inout float wipe
){
    // A drop reaches at most half a cell sideways, 0.8 of a cell below its
    // centre (the body) and one cell above it (the track), and its centre
    // sits within half a cell of the cell centre plus the sway. Pixels
    // further out than that get exactly zero from every term below, so they
    // can skip even the occupancy hash.
    float sway = 0.035 * abs(uRandomMag);
    if (abs(f.x) >= 1.0 + sway || f.y >= 1.3)
        return;

    // Bail out before any drop maths runs. The occupancy test was previously
    // only applied to the result, so empty cells still paid for three hashes,
    // five sines and a dozen smoothsteps. At the default density only about
    // 7% of cells hold a drop, so this is where nearly all the cost was.
    if (hash12(id + vec2(uSeed * 17.0)) > cellDensity)
        return;

    vec2 h0 = hash22(id + vec2(uSeed * 3.1));
    vec2 h1 = hash22(id.yx + vec2(19.7, 7.3) + vec2(uSeed * 5.7));
    vec2 h2 = hash22(id + vec2(41.2, 13.9) + vec2(uSeed * 11.3));

    vec2 center = h0 - 0.5;
    center.x += sin(
        t * mix(0.45, 0.85, h1.x) + h2.y * TAU
    ) * 0.035 * uRandomMag;

    vec2 d = f - center;
    // The same reach, now measured from the drop's actual centre. Every
    // body, track and wipe term is identically zero outside this box, so
    // returning here changes nothing downstream; it just means only pixels
    // the drop can touch pay for the optics and the rest of the maths.
    if (abs(d.x) >= 0.5 || d.y >= 0.8 || d.y <= -1.0)
        return;

    // Optical properties get their own entropy. These two only run for cells
    // that actually hold a drop and pixels the drop reaches.
    vec2 h3 = hash22(id.yx + vec2(7.7, 53.1) + vec2(uSeed * 23.9));
    vec2 h4 = hash22(id + vec2(67.3, 29.5) + vec2(uSeed * 31.7));

    float variation = clamp(uVariation, 0.0, 1.0);
    // A slow, clinging drop leaves a shorter and fainter track than one that is
    // running. Without this a slow column would trail like a fast one.
    float smearAmount = clamp(uSmear, 0.0, 1.0) * mix(0.35, 1.0, speedFactor);

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
    // Per-drop edge softness: some beads sit crisp on the glass, others read as
    // flatter, half-wetted smears.
    float body = 1.0 - smoothstep(mix(0.52, 0.86, h3.x), 1.0, bodyDist);

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
    // The track is where the drop has been. The field drifts with the wind
    // at uWindX layout px/s while the drop falls at its own rate, so a drop
    // blown to the right leaves its track up and to the left, leaning by
    // wind over fall. The old form leaned the track with the wind, downwind,
    // by a fixed 0.0015 per px/s capped at 0.05 whatever the fall rate. The
    // clamp keeps the track and its wipe band inside the reach box above; the
    // fall rate keeps its sign so a negative Speed leans the other way.
    float fallRate = (130.0 + uSize * 0.8) * uSpeed * speedFactor;
    float fallDiv = fallRate >= 0.0 ? max(fallRate, 1.0) : min(fallRate, -1.0);
    float lean = clamp(-uWindX / fallDiv, -0.35, 0.35);
    float curve = lean * max(behind, 0.0);
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
    // Where water is or has just been, the glass is wiped clear of fog. This is
    // deliberately wider and softer than the visible track: the drop clears a
    // band, it does not only clear the bright core of its own trail.
    wipe = max(wipe, max(
        body,
        trailGate * (1.0 - smoothstep(widthAtY * 1.5, widthAtY * 3.0, abs(trailX)))
    ));

    vec2 bodyNormal = safeNormalize(vec2(
        (d.x - centerBend) / max(sx * sx, 0.001),
        d.y / max(sy * sy, 0.001)
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
    float lensPower = mix(1.45, 3.1, h3.x);
    vec2 lensVec = -vec2(d.x - centerBend, d.y) * lensPower;
    // Toward the rim the surface turns steep, so hand over to an edge bend.
    vec2 edgeVec = bodyNormal * mix(0.06, 0.22, sizeKey);
    float edgeMix = smoothstep(0.40, 0.98, bodyDist);
    vec2 bodyBend = mix(lensVec, lensVec * 0.30 + edgeVec, edgeMix);

    // Sideways bend across the track. This was a normalised vector whose x
    // term saturated within a fraction of a pixel of the centre line, so the
    // sample position flipped sign across the middle of every track and left
    // a seam down it. A clamped ramp reaches the same value at half the core
    // width and passes smoothly through the centre.
    vec2 trailNormal = vec2(
        clamp(trailX / (0.5 * widthAtY), -1.0, 1.0),
        -0.08
    );
    bend += bodyBend * body + trailNormal * (trail * 0.16);

    // Rim and highlight were fixed constants, so every bead carried the same
    // ring and the same specular dot in the same relative spot. Both now vary.
    float rimIn = mix(0.50, 0.68, h4.x);
    float rim = smoothstep(rimIn, rimIn + mix(0.14, 0.30, h3.y), bodyDist)
        * (1.0 - smoothstep(0.90, 1.04, bodyDist));
    vec2 glintPos = vec2(-0.34, -0.34)
        + (vec2(h3.y, h4.y) - 0.5) * 0.5;
    float glintR = mix(0.10, 0.30, h4.y);
    float glint = 1.0 - smoothstep(
        glintR * 0.3,
        glintR,
        length(bodyUv - glintPos)
    );
    shine = max(
        shine,
        body * (
            rim * mix(0.18, 0.46, h4.x)
            + glint * mix(0.30, 0.95, h3.x)
        )
    );
}

void main(void){
    vec2 uvPerLayout;
    vec2 layoutPos = c3Layout(vTex, uvPerLayout);
    float cell = max(14.0, uSize);
    // Time lets events own the clock: at -1 (the default) the runtime clock
    // is used; any value from 0 up is a clock the project advances itself,
    // so it can pause, slow or speed the rain without every drop jumping.
    float t = uTime < 0.0 ? seconds : uTime;
    vec2 lp = layoutPos + vec2(uSeed * 137.0, uSeed * 73.0);
    lp.x -= t * uWindX;
    float baseFall = (130.0 + uSize * 0.8) * uSpeed;
    float spread = clamp(uSpeedVar, 0.0, 1.0);
    float dens = clamp(uDensity, 0.0, 1.0) * 0.33;

    float gx = floor(lp.x / cell);
    float fx = fract(lp.x / cell) - 0.5;
    float mask = 0.0;
    vec2 bend = vec2(0.0);
    float shine = 0.0;
    float wipe = 0.0;

    // Each column of cells falls at its own rate, only ever slower than Speed,
    // so raising the spread slows part of the rain instead of speeding the rest
    // up. The rate is keyed to the drop's own column rather than the pixel's,
    // so neighbouring pixels always agree on where a drop is and no seam forms
    // at column edges. Cost is three extra hashes, not three extra grids.
    for (int ox = -1; ox <= 1; ox++){
        float colId = gx + float(ox);
        float colRate = mix(
            1.0,
            mix(0.34, 1.0, hash12(vec2(colId, 91.7) + uSeed)),
            spread
        );
        float py = lp.y - t * baseFall * colRate;
        float gy = floor(py / cell);
        float fy = fract(py / cell) - 0.5;

        for (int oy = -1; oy <= 1; oy++){
            addDrop(
                vec2(colId, gy + float(oy)),
                vec2(fx - float(ox), fy - float(oy)),
                dens, colRate, t,
                mask, bend, shine, wipe
            );
        }
    }

    // Condensation sits still on the glass, so it uses the layout position
    // directly with no fall and no wind drift, on its own finer grid. It is
    // told how much the falling water has wiped this pixel, so beads do not
    // survive inside a track or under a drop.
    float dew = clamp(uDew, 0.0, 1.0);
    if (dew > 0.002){
        float swept = clamp(wipe, 0.0, 1.0);
        float dcell = cell * 0.30;
        vec2 dp = layoutPos + vec2(uSeed * 211.0, uSeed * 97.0);
        vec2 dg = floor(dp / dcell);
        vec2 df = fract(dp / dcell) - 0.5;
        for (int oy = -1; oy <= 1; oy++){
            for (int ox = -1; ox <= 1; ox++){
                vec2 o = vec2(float(ox), float(oy));
                addDew(
                    dg + o, df - o,
                    dew * 0.75, 0.30, swept,
                    mask, bend, shine, wipe
                );
            }
        }
    }

    float lodBoost = 1.0 + 0.02 * clamp(uBlurLod, 0.0, 4.0);
    // bend is in cell units, so scale by the cell size to reach layout pixels
    // and by uvPerLayout to reach texture coords. Strength deliberately does
    // NOT scale this: it would scale the lens power with it, and any drop
    // whose power passed through 1 on the way down would collapse to a flat
    // disc. Strength blends the refracted image instead, which has the same
    // end points and keeps every drop a proper lens at every setting.
    vec2 offset = bend * cell * uvPerLayout * lodBoost;
    float m = clamp(mask, 0.0, 1.0);

    // Fogged glass. The window is blurred everywhere except where water is or
    // has run, so drops and their tracks read as clear channels through
    // condensation rather than as lenses over an already-sharp scene. Fog at 0
    // skips the whole tap loop and costs nothing.
    float fogAmt = clamp(uFog, 0.0, 1.0);
    vec4 base;
    if (fogAmt > 0.002){
        float clearness = clamp(wipe, 0.0, 1.0);
        // The radius is in layout pixels, converted like the lens offset so
        // the haze keeps its proportion to the drops under zoom and on
        // high-DPI displays. It is capped in texels so the 20-tap disc never
        // spreads thin enough to show its taps, and keeps the orientation
        // sign so the tap spiral lies the same way on both renderers.
        vec2 radius = sign(uvPerLayout)
            * min(abs(uvPerLayout) * (fogAmt * 11.0), pixelSize * 16.0)
            * (1.0 - clearness);
        // Rotate the tap spiral per pixel so the disc's undersampling shows up
        // as dither rather than as rings. Interleaved gradient noise is used
        // rather than a hash because its pattern is far finer grained, which
        // matters on hard edges where disc variance is highest.
        vec2 px = floor(vTex / max(pixelSize, vec2(1e-6)));
        float jitter = fract(52.9829189
            * fract(0.06711056 * px.x + 0.00583715 * px.y)) * TAU;
        base = sampleBlur(vTex, radius, jitter);
    } else {
        base = sampleBase(vTex);
    }

    // The lens sample stays sharp: looking through a bead you see a clear,
    // inverted image, not the fogged film around it. Where there is no water
    // the offset is zero and the blend weight is zero, so skip the fetch.
    vec4 refr = base;
    if (m > 0.0)
        refr = sampleBase(vTex + offset);
    float w = m * clamp(uStrength, 0.0, 1.0);
    float glow = shine * 0.075 + m * 0.010;
    vec3 rgb = mix(base.rgb, refr.rgb, w) + vec3(glow);
    // Premultiplied output: alpha follows the same blend as the colour, plus
    // the light the highlights add. When both samples are opaque, which is
    // every pixel over an opaque scene, that is 1 as it was; over nothing,
    // drops now vanish apart from their glints instead of leaving a faint
    // grey disc, and a lens looking past an edge shows what it refracts.
    gl_FragColor = vec4(rgb, min(1.0, mix(base.a, refr.a, w) + glow));
}
