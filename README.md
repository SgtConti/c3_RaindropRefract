# Raindrop Refraction

Construct 3 effect addon for procedural falling raindrop refraction. It supports both WebGL and WebGPU and is intended for object or layer use.

## Addon ID

`sgtconti_raindrop_refract`

## Features

- Procedural falling drops; no texture dependency.
- Many small round beads, fewer pear-shaped runners and rare larger drops.
- Gravity-aligned wet tracks behind runners, with restrained width and curvature variation. In wind, tracks lean against the drift by wind over fall.
- No random per-drop rotation; drop orientation remains consistent with gravity.
- Every bead is its own lens: refractive power, edge softness, rim and highlight placement all vary per drop.
- Fogged glass: the view is blurred by condensation everywhere except where drops sit or have run, so tracks read as clear channels wiped through the haze.
- Optional dew: static condensation beads clinging to the glass, each a small lens holding its own patch clear. Runners sweep them out of their path.
- Adjustable density, size, speed, speed variation, randomness, wind, refraction strength, fog, dew, blur LOD, seed, drop variation, smear amount and an events-driven clock.
- Background sampling for refracted scene content.
- Uses layout-space coordinates so drops follow layer scrolling, and keep their look under layer zoom and on high-DPI displays.

## Parameters

| Parameter | Description |
|---|---|
| Density | How much of the glass carries drops. 100% fills about one drop cell in three; the default 22% fills about one cell in fourteen. |
| Size | Drop cell size in layout pixels; values below 14 are clamped for the cell. Larger values give larger drops and a slightly faster fall. Changing it while running re-rolls every drop. |
| Speed | Fall speed multiplier. Sets the speed of the fastest drops. Changing it while running makes every drop jump; drive Time from events for smooth control. |
| Randomness | Amount of slow side-to-side sway on each drop. 1 is a subtle wobble, 0 removes the sway. Drop placement is always random. |
| Wind X | Horizontal wind drift in layout pixels per second. Tracks lean against the drift. Changing it while running makes every drop jump. |
| Strength | How much of the refracted image shows through each drop. 0 leaves only the rims and highlights; 100% shows the full lens. |
| Blur LOD | WebGPU only: mip level used for the lens sample. Has no effect on textures without mipmaps, which includes layers and pre-drawn objects. On WebGL it only scales the lens offset by up to 8%. |
| Seed | Offsets the random pattern. |
| Drop variation | Natural variation in bead size, roundness and vertical pear-shaped runners. Optical variation between drops is always on. |
| Smear | Amount and reach of soft, gravity-aligned wet tracks behind moving drops. Slower drops trail less. |
| Speed variation | Spread of fall speeds between columns of drops. Rates only go below Speed, never above; at 100% the slowest columns run at about a third of Speed. `0` makes every drop fall at the same rate. |
| Fog | Condensation haze on the glass. The view is blurred everywhere except where drops sit or have run, so tracks read as clear channels. `0` disables the blur entirely and costs nothing. |
| Dew | Static condensation beads clinging to the glass. They do not fall, hold their own patch clear of the fog, and are swept away where drops sit or have run. |
| Time | Clock the rain runs on, in seconds. `-1` uses the runtime clock. Set it from events every tick (parameter index 13) to pause, slow or speed the rain smoothly; Speed, Wind X and Size jump when changed while running, Time does not. |

## Suggested layer setup

Apply the effect to a transparent layer above the scene to refract everything beneath that layer. A few things to know:

- The scene beneath should be opaque. Like every background-blending effect, the output is composited over the background again, so semi-transparent content on a transparent layout background reads more opaque under the glass.
- Anything placed on the effect layer itself is treated as part of the scene behind the glass: it is fogged and refracted too. Put HUD or overlay objects on a layer above.
- Construct does not allow background-blending effects on the layout itself, so put it on a layer or an object. On an object it covers the object's whole bounding box, transparent pixels included.
- Rotated layers are not supported: the drop field does not turn with the layer angle.
- Drops, tracks, lens strength and fog radius are all in layout pixels, so the look holds under layer zoom, fullscreen scaling and high-DPI displays.

## Driving the clock from events

Drop positions are a function of the clock, so changing Speed, Wind X or Size while the game runs makes every drop jump to where it would have been at the new rate. To pause the rain, slow it with the game's time scale, or ramp its speed smoothly, leave Speed alone and supply the clock yourself: keep a variable, add `dt` times whatever factor you want each tick, and set the effect's **Time** parameter to it. In the *Set effect parameter* action, Time is parameter index 13 (zero-based, the last one). At its default of `-1` the effect uses the runtime clock. Time is also the one parameter that tweens correctly on a timeline; start it at `0` rather than tweening up from `-1`, since crossing `0` switches from the runtime clock to your own and the drops jump once.

## Requirements

- WebGL: the fragment shader needs `highp` float precision, which every WebGL 2 capable GPU provides. On 2010-era mobile GPUs without it the hash-based drop layout cannot be computed and the effect renders wrongly.
- WebGPU: a Construct release with WGSL effect support.

## Installing

Download the `.c3addon` from the repository's Releases page, which the CI workflow publishes for every `v*` tag. In Construct 3 open Menu, View, Addon manager, Install new addon, choose the file and restart the editor.

## Performance

The effect is fill-rate bound, so cost scales with the on-screen area it covers. The figures below are relative, measured in an offline WebGL harness on one GPU at default settings; real cost depends on resolution and the area the effect covers.

- **Fog** is the most expensive control by far. Above `0` every pixel takes 20 blur taps on a disc of up to 11 layout pixels, each tap reading the foreground and the background, so 40 texture fetches. Measured at roughly +67% over Fog `0`, flat across the whole range since the tap count does not change with the radius. At `0` the loop is skipped entirely.
- **Dew** measured at roughly +37% when on before 1.5.0. It is a second 3x3 grid of cells; since 1.5.0 cells a bead cannot reach skip even the occupancy hash, so expect less.
- **Density** is the main cost control for the falling drops. Each pixel tests a 3x3 block of drop cells, and only cells that hold a drop and can actually reach the pixel run the drop maths.
- **Speed variation** is nearly free. It costs three extra hashes per pixel, not three extra grids of drops.
- **Size** sets the cell size, not the cost per pixel. Smaller values mean more cells cross a given area, so more of them are occupied at the same Density.
- **Blur LOD** only affects the lens sample on WebGPU, and only if the textures have mipmaps, which layers and pre-drawn objects do not. On WebGL it just scales the lens offset by up to 8%.

## Changes in 1.5.0

**WebGL beads are now real lenses.** Construct's WebGL renderer supplies its texture rectangles with y running the opposite way to layout y (the SDK documents this, and the 1.4.1 fix tripped over exactly that flipped span). The lens offset was added in layout orientation, so on WebGL every bead mirrored the scene sideways but showed it upright and squashed vertically instead of inverting it. Offsets are now converted with the texture-per-layout ratio taken from the same rectangles that place the drops, which carries the sign. WebGPU was already right and is unchanged. **Existing WebGL projects will look different inside the beads.**

**Zoom and high-DPI displays.** The same conversion puts lens strength and fog radius in layout pixels. Previously they were in texels, so at 2x layer zoom or on a 2x display the beads kept their size but lost half their optical power, which put a third of them below power 1, the flat-disc collapse 1.3.0 was written to avoid. At 1x the magnitudes are unchanged, so WebGPU output is identical and WebGL differs only by the sign fix above. The fog disc is capped at 16 texels so the 20 taps never spread thin, and it now lies the same way on both renderers.

**Tracks lean the right way in wind.** With Wind X set, the drop field drifts with the wind while the track was drawn leaning with it, downwind, by a fixed amount unrelated to the fall rate. The track is where the drop has been, so it now leans against the drift by wind over fall, and slower columns lean more. Only projects with a non-zero Wind X change.

**Time parameter.** Drop position is a closed form of the clock, so changing Speed, Wind X or Size while running made every drop jump, and the rain could not be paused. The new **Time** parameter lets events supply the clock; see *Driving the clock from events*. Speed, Wind X, Size, Seed and Blur LOD are no longer flagged as interpolatable, since tweening them jumps rather than blends. Projects saved before 1.5.0 should pick up Time at its default of `-1` when opened with the new version; if the rain stands still after upgrading, set Time to `-1`.

**Dew is swept by runners.** Beads no longer survive inside a track or under a drop head, where they added a second, off-centre lens to the image. Only projects with Dew above `0` change.

**Track centre seam.** The sideways bend across a track used a normalised vector that saturated within a fraction of a pixel of the centre line, so the sample position flipped sign down the middle of every track. It is now a smooth ramp; a band up to the core width wide at the top of each track changes, plus a sub-pixel vertical shift along its length.

**Cheaper, with identical output.** Cells a drop cannot reach now skip all drop maths including the occupancy hash, dew cells likewise, and the WebGL lens sample is skipped where there is no water. The fog spiral rotates a vector per tap instead of calling `cos` and `sin`, which replaces 38 in-loop `cos` and `sin` calls per fogged pixel with one pair and changes a few pixels per frame by one 8-bit level.

**Long runs and large seeds.** Hash inputs are folded into a fixed range so cell rows after hours of fall, and large Seed values, keep full float precision instead of collapsing into repeats. The fold is an exact identity inside the range, so the layout is unchanged for seeds up to a little over 230 and for the first 40 minutes or so at default settings; beyond that a project sees a reshuffle relative to 1.4.1.

**Sampling follows the SDK.** The background is read through the source-to-destination rectangle mapping the SDK documents for background-blending effects (the identity for a layer), reads away from the current pixel are held inside the object's rectangle on both textures, and output alpha follows the same blend as the colour plus the highlight light. Identical for a layer over an opaque scene; on an object the background now lands under the object and reads beyond its edge are clamped, so object projects change near the object's edges and wherever the background rectangle differs from the foreground one. Over nothing, drops now vanish apart from their glints instead of leaving a faint grey disc. On WebGPU, Blur LOD now applies only to the lens sample as documented, not to every sample.

**Smaller items.** Drop positions and the unit conversion for offsets now come from one decision, so they cannot fall back separately; the texel-coordinate fallback for a degenerate rectangle falls the right way on WebGL and WebGPU has the same guard (though the 1.4.1 static was the flipped WebGL rectangle itself, so the fallback is probably never taken). The store category is now Distortion. Parameter descriptions were corrected: Density's scale, speed variation being per column, Randomness being a sway rather than placement jitter, and Size's floor. CI validates the manifest, shaders and strings against each other and publishes a GitHub release for every `v*` tag.

## Changes in 1.4.1

**Fixes single-pixel static on the WebGL renderer.** Construct supplies the source and layout rectangles as uniforms, and when either arrived degenerate the old code divided by its `1e-6` epsilon guard instead. That sent the field coordinate to about `1e8`, where neighbouring pixels land thousands of drop cells apart, so every pixel hashed as its own cell and produced isolated single-pixel drops. It now falls back to texel coordinates, which renders correctly but does not track layer scrolling. WebGPU was never affected, because it uses Construct's own `c3_getLayoutPos()`. The same change also fixes a flipped source rectangle, which `max()` had been clamping to `+1e-6`. With a healthy rectangle the output is bit-identical to 1.4.0.

## Changes in 1.4.0

**Fogged glass, with drops wiping it clear.** This is the change that makes drops read as water on a window rather than as lenses sitting on an already-sharp scene. The background is blurred by a condensation haze, and drops plus the band each drop has run through hold their patch sharp — so tracks appear as clear channels through the fog. Controlled by the new **Fog** parameter, default 40%.

**Dew.** A new **Dew** parameter adds static condensation beads that cling to the glass. They do not fall, carry no tracks, and each holds its own patch clear of the fog. Default 0.

Both have real cost, so both have genuine off switches: **Fog** at `0` skips the blur loop and produces a frame identical to 1.3.0, and **Dew** at `0` skips its grid.

**Existing projects will look different**, because Fog defaults to 40%. Set **Fog** to `0` to get exactly the previous appearance.

## Changes in 1.3.0

**Drops are now individually distinct.** Previously the refraction vector was normalised before use, so every bead displaced the background by the same amount with the same falloff — a radial smear rather than a lens, identical on every drop. The rim thresholds and the specular highlight position were also hard-coded constants, so every bead carried the same ring and the same dot in the same relative spot.

Each drop now samples the scene mirrored and magnified about its own centre, which is what a real bead does, with refractive power varying per drop. Edge softness, rim position, rim width, rim brightness, highlight position, highlight size and highlight brightness all vary per drop as well. Cost is about 2.7%: two extra hashes, and only for cells that actually hold a drop.

**Strength changed meaning slightly.** It used to scale the refraction offset, which also scaled the lens power — any drop whose effective power passed through 1 on the way down collapsed into a flat disc of one colour, and at the default Strength that hit a real share of drops. Strength now blends the refracted image instead. Both end points behave as before and the response is linear across the range, but a given Strength value will look a little different than it did.

## Changes in 1.2.0

**Drops no longer all fall at the same rate.** Previously the whole drop grid translated as one block, so every drop moved in lockstep. Each column of cells now falls at its own rate, controlled by the new **Speed variation** parameter. Rates only ever go *below* **Speed**, never above, so raising the spread slows part of the rain rather than speeding the rest up — at 100% the slowest columns run at about a third of **Speed**. Wet tracks scale with the rate too, so a slow, clinging drop trails less than a running one. Set **Speed variation** to `0` for the old uniform behaviour.

Two smaller fixes:

- **Long wet tracks no longer truncate.** A track could reach further than the 3×3 cell window that gets sampled, so its far end appeared or vanished depending on how the drop happened to line up with the cell grid. Track reach is now capped to what the window covers, which makes long tracks a consistent length. The longest tracks are somewhat shorter than before as a result.
- **Drop layout is reshuffled.** `hash22` used one constant where it needs three, which left the two returned components sharing a source and measurably worsened their joint distribution. Fixing it changes which cells hold drops, so an existing scene will have its drops in different places. Use **Seed** if you want to hunt for a particular arrangement.
