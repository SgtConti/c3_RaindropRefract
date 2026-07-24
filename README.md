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
| Smear | Amount and reach of soft, gravity-aligned wet tracks behind moving drops. |

## Suggested layer setup

Apply the effect to a transparent layer above the scene to refract everything beneath that layer.
