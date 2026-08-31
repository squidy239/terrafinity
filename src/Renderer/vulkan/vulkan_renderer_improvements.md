# Voxel Blocklight Baking (design note)

Unimplemented plan for CPU-baked chunk-local blocklight.

## Architecture (chosen)

- **Sun:** unchanged (directional `sun_day` term). No CSM.
- **Blocklights:** baked **sparse chunk-local 3D light bricks** on the **CPU**, uploaded through the existing transfer-queue uploader, sampled **once per fragment** from a growable 3D texture pool. No per-face/per-vertex light data, no runtime shadow maps.

## Data layout

- `ChunkSize = 32`, brick sample spacing `4`, phase `2`, so texel `t` ↔ block offset `4t − 2` (span `−2..38`, one-sample halo). `brick_size = 11`, `brick_byte_size = 11³·8` RGBA16F (~10.6 KB).
- Brick pool = a **3D texture** `(11, 11, layers)` in `r16g16b16a16_sfloat`, **`.general` layout permanently**, one layer = one chunk. Layers recycled via a free list gated on the graphics timeline. Sampled as `sampler3D` with `uv.xy` clamped to `[1/11, 9/11]` and `w = layer` (glslang rejects `sampler3DArray`).
