# Raindrop Refraction

Construct 3 effect addon for procedural falling raindrop refraction. It supports both WebGL and WebGPU and is intended for object or layer use.

## Addon ID

`sgtconti_raindrop_refract`

## Features

- Procedural falling drops; no texture dependency.
- Many small round beads, fewer pear-shaped runners and rare larger drops.
- Gravity-aligned wet tracks behind runners, with restrained width and curvature variation.
- No random per-drop rotation; drop orientation remains consistent with gravity.
- Refractive rims and small upper highlights for a wet-window look.
- Adjustable density, size, speed, randomness, wind, refraction strength, blur LOD, seed, drop variation and smear amount.
- Background sampling for refracted scene content.
- Uses layout-space coordinates so drops follow layer scrolling.

## Parameters

| Parameter | Description |
|---|---|
| Density | Chance of raindrops per cell. |
| Size | Approximate drop cell size in pixels. |
| Speed | Fall speed multiplier. |
| Randomness | Random position jitter and wobble amount. |
| Wind X | Horizontal wind drift in pixels per second. |
| Strength | Refraction strength. |
| Blur LOD | Texture LOD used for the refracted sample in WebGPU. |
| Seed | Offsets the random pattern. |
| Drop Variation | Natural variation in bead size, roundness and vertical pear-shaped runners. |
| Smear | Amount and reach of soft, gravity-aligned wet tracks behind moving drops. Slower drops trail less. |
| Speed variation | Spread of individual drop fall speeds. Drops vary downwards from Speed, never above it. `0` makes every drop fall at the same rate. |

## Suggested layer setup

Apply the effect to a transparent layer above the scene to refract everything beneath that layer.

## Performance

The effect is fill-rate bound, so cost scales with the on-screen area it covers.

- **Density** is the main cost control. Each pixel tests a 3×3 block of drop cells, and only cells that actually hold a drop run the full drop maths.
- **Speed variation** is nearly free. It costs three extra hashes per pixel, not three extra grids of drops.
- **Size** sets the cell size, not the cost per pixel. Smaller values mean more cells cross a given area, so more of them are occupied at the same Density.
- **Blur LOD** only blurs on WebGPU. WebGL 1 has no fragment-stage LOD sampling, so on WebGL it just nudges refraction strength very slightly.

## Changes in 1.2.0

**Drops no longer all fall at the same rate.** Previously the whole drop grid translated as one block, so every drop moved in lockstep. Each column of cells now falls at its own rate, controlled by the new **Speed variation** parameter. Rates only ever go *below* **Speed**, never above, so raising the spread slows part of the rain rather than speeding the rest up — at 100% the slowest columns run at about a third of **Speed**. Wet tracks scale with the rate too, so a slow, clinging drop trails less than a running one. Set **Speed variation** to `0` for the old uniform behaviour.

Two smaller fixes:

- **Long wet tracks no longer truncate.** A track could reach further than the 3×3 cell window that gets sampled, so its far end appeared or vanished depending on how the drop happened to line up with the cell grid. Track reach is now capped to what the window covers, which makes long tracks a consistent length. The longest tracks are somewhat shorter than before as a result.
- **Drop layout is reshuffled.** `hash22` used one constant where it needs three, which left the two returned components sharing a source and measurably worsened their joint distribution. Fixing it changes which cells hold drops, so an existing scene will have its drops in different places. Use **Seed** if you want to hunt for a particular arrangement.
