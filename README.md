# Raindrop Refraction

Construct 3 effect addon for procedural falling raindrop refraction. It supports both WebGL and WebGPU and is intended for object or layer use.

## Addon ID

`sgtconti_raindrop_refract`

## Features

- Procedural falling drops; no texture dependency.
- Adjustable density, size, speed, randomness, wind, refraction strength, blur LOD and seed.
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

## Suggested layer setup

Apply the effect to a transparent layer above the scene to refract everything beneath that layer.
