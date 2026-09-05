# Agent Guide

## Commands

Use these full commands without modification after each change and ensure the play test runs without errors:

- normal build: `zig build`
- run and open to menu: `zig build run`
- run and open to a game: `export VK_LOADER_LAYERS_ENABLE="*validation" && zig build run -Dtest_play=[number of seconds to run, 5-10 is a good default for a short test]`
- format code: `zig fmt .`

Do not git stash or commit, it can mess up git history.

## Running tests

- `zig build test -Dtest_filter="substring"` (wired in build.zig via `b.addTest(.{ .filters })`) runs only matching tests at compile time; the full suite has pre-existing crashes (wio/wayland) in headless environments.
- `-Dtest_filter` only sees tests from files reachable in the module import graph. A new `.zig` file with tests is invisible until something reachable from `main.zig` references it (e.g. `pub const Csm = @import(...)` in Renderer.zig, or a field type like `shadow: Csm.ShadowConfig` in RenderOptions forces its analysis).
- Due to a zig issue `zig test` always seems to output exit code 1, you can ignore it unless it says which test failed.
- glslc `#include` dependencies must be registered as build inputs: glslc resolves `#include "shadow.glsl"` internally, but the Zig build graph only knows inputs declared with `addFileArg`/`addFileInput`. An unregistered include does NOT invalidate the glslc cache, so the SPIR-V goes stale while Zig source (e.g. `ShadowParams` layout) recompiles — a silent layout mismatch (no shadows). Symptom: the `.spv` mtime predates your edit and `spirv-dis` shows old member offsets. Fix: `frag_cmd.addFileArg(b.path("src/Renderer/vulkan/chunk_renderer/fragshader.frag"));` plus `frag_cmd.addFileInput(b.path("src/Renderer/vulkan/shadow/shadow.glsl"));` (`addFileInput` tracks without appending to argv). Verify std430 offsets after layout changes with `spirv-dis <spv> | grep "OpMemberDecorate %ShadowParamsBuffer"` against the Zig `@offsetOf` asserts.

## Verify before writing

When a scout or audit proposes a change, independently verify its claim before implementing it: grep callers including vendored deps, check framework dispatch and call order, prove ordering or equivalence, or write a ~10-line scratch test on this toolchain. A claim without its check goes back.

## Adding to this file

Whenever you learn something new that would fit well here and be useful in the future, add it to this file. Keep it tight: state the rule once, compress instances, drop anything that restates a rule already written.

# Naming, Style & Code Quality

Core philosophy: **meaning dictates casing**. Code must be self-documenting and elegant — structure, names, and logic communicate intent without external explanation.

## Comments

Comments must be simple and unobtrusive. Use them sparingly: the _why_ behind a non-obvious decision, `TODO` items, or logic that cannot be clarified by renaming. Never decorative characters, ASCII art, or banner separators. One or two plain sentences; a paragraph means the code is too complex. Doc comments (`///`) are expected on public declarations, same plain style.

```zig
// ✗ WRONG — stating the obvious
// increment i by 1
i += 1;

// ✓ CORRECT — explains why
// The order matters here: upstream expects sorted keys.
std.sort.insertion(Key, keys, {}, Key.lessThan);
```

## Naming quick reference

| Element                          | Casing Convention        | Example                                                                  |
| :------------------------------- | :----------------------- | :----------------------------------------------------------------------- |
| **Variables**                    | `snake_case`             | `model_weights`, `is_active`                                             |
| **Functions (Standard)**         | `camelCase`              | `trainModel(data: Dataset, epochs: u32)`, `parseData(input: []const u8)` |
| **Functions (Returns `type`)**   | `PascalCase` (TitleCase) | `CreateGraphNode(comptime T: type)`                                      |
| **Types & Aliases**              | `PascalCase` (TitleCase) | `NeuralNetwork`, `Dataset`                                               |
| **Namespaces** (0-field structs) | `snake_case`             | `math_utils`, `tensor_ops`                                               |
| **Files (Types)**                | `PascalCase` (TitleCase) | `AttentionLayer.zig`                                                     |
| **Files (Namespaces)**           | `snake_case`             | `matrix_helpers.zig`                                                     |
| **Directories**                  | `snake_case`             | `data_loaders/`, `utils/`                                                |

Detailed rules: non-type/non-namespace/non-callable identifiers are `snake_case` (locals, fields, args, constants). Types and aliases are `PascalCase`, no underscores. Standard callables are `camelCase`; callables returning a `type` are `PascalCase`. Zero-field structs used only as function containers are namespaces and use `snake_case`. Acronyms are treated as normal words — never fully capitalized (`parseHttp`, `JsonParser`, `io_stream`, `fetchApiData`; not `parseHTTP`, `JSONParser`). Files map to structural intent: top-level fields means a type (`PascalCase`); functions/constants only means a namespace (`snake_case`). Directories are always `snake_case`.

## Structural hygiene and function size

- **Single responsibility:** one thing per function; conjunctions in the name/description mean it does too much. If a body needs visual dividers or heavy blank-line padding between phases, split it into private helpers. A body that does not fit on one screen without scrolling is a refactor candidate.
- **Minimal signatures:** group related args into a context struct instead of a long argument list.

## Control flow

- **Guard clauses, flat hierarchy:** early returns over nesting; the happy path runs down the left side.
- **Fail fast:** handle errors immediately, never swallow with empty catches; unrecoverable failure fails loudly.
- **Inlining:** let the compiler decide, except to change stack-frame count for debugging, to force comptime-ness to propagate, or when real measurements demand it. `inline` restricts the compiler and can harm size, compile speed, and runtime.

## State and mutation

- Declare variables in the deepest scope of use, as close to first use as possible. Never rely on hidden state; a mutating function's name and signature must make that obvious. Bind magic numbers/literals to named constants.
- **Minimize unsafe casts:** `bitcast` is safer and has fewer footguns than `ptrcast`/`aligncast`. `ptrcast` is almost never right — only for things like casting to/from opaque pointers.
- **Never use `std.mem.zeroes`:** it bypasses field defaults, so adding a non-zero default or field later silently changes every zeroed site. Prefer `.{}` with defaulted fields, `@splat(0)` for arrays, or a named `fn zeroed() T` constructor.
- **Initialize before use; prefer optionals over undefined.** An optional set to undefined cannot be null-checked.

## Capture syntax over index variables

Prefer captures (`|variable|`) over indexing; they remove off-by-one/out-of-bounds risk. Zip parallel arrays with multi-captures; mutate with `|*item|`. Only use a numeric index when the index itself is meaningful (bit positions, matrix dims, index-taking APIs) — then use the `, 0..` capture, never `for (0..x.len)`. `if (maybe_value) |value|` unwraps without a `.?` failure point.

```zig
// ✗ WRONG
for (0..count) |i| {
    arr[i] = f(others[i]);
}

// ✓ CORRECT — zip with captures
for (arr, others[0..count]) |*dest, src| {
    dest.* = f(src);
}
```

**Rule:** writing `for (0..x.len) |i|` means asking whether the elements can be captured directly.

## Array literals: `: Type = .{vals}`

Annotate the binding, don't repeat the type in the literal: `const formats: [2]vk.Format = .{ .r16g16b16a16_sfloat, .r16g16b16a16_sfloat };` instead of `[_]vk.Format{...}`.

# Zig 0.16.0 Toolchain Facts

## `std.Io` quick guide

I/O is an interface: anything that can block or introduce nondeterminism takes an `Io` instance.

- **`Future(T)`:** `io.async(func, args)` (infallible) or `io.concurrent(func, args)` (allocates, can fail); `future.await(io)` retrieves; `future.cancel(io)` cancels. Defer-cancel right after creating a task so cleanup runs: `defer if (file_task.cancel(io)) |file| file.close(io) else |_| {};`.
- **`Group`:** `var group: std.Io.Group = .init;`, `group.async(io, func, args)`, `group.await(io)`.
- **`Batch`:** lower-level grouping of concurrent operations (e.g. batched file reads), not functions.
- Subsystems take `Io` directly: `std.Io.Dir`/`std.Io.File` (`file.close(io)`), `std.Io.net`, `std.process.spawn(io, options)`, `std.Io.Timestamp.now(io)`.
- Mutexes suspend via the runtime: `lock(io)`, `tryLock()` (non-blocking, returns bool), `unlock(io)`.
- Canceled operations return `error.Canceled`.

## Pointer safety patterns

**Comptime alignment and `@embedFile`.** `@embedFile` returns `*const [N:0]u8` with alignment 1. `@alignCast` on it must be applied to the original comptime-known pointer: a non-inline helper taking `[]const u8` loses the alignment metadata and panics at runtime. Cast at the call site (`.p_code = @ptrCast(@alignCast(spv.ptr))`) or in an `inline fn` the compiler fully resolves at comptime.

**Single-item slices.** When a C API expects a many-pointer (`[*]T`/`[]T`) to one element, use `(&x)[0..1]` — never `@ptrCast(&x)` (suppresses type checking) or `&[1]T{x}` (anonymous temporary). Never declare a `[1]` array just to smuggle one value into a many-pointer; use a scalar plus `(&x)[0..1]`, and write directly into the destination (`(&sets[i])[0..1]`) instead of bouncing through a local. For real arrays use `arr[0..n]` (mutable `[]T`; add `.ptr` when the field wants `?[*]const T`), never `@ptrCast(&arr)` / `@ptrCast(&arr[0])`. Exceptions: `p_next` chains (need `@ptrCast` to `*const c_void`) and output params (`&x` for `*T`).

## Toolchain footguns (Zig 0.16.0, x86_64)

- **`std.atomic.Value(i128)` fails codegen in Debug** (`genSetReg called with a value larger than dst_reg`; a one-line store reproduces it). Never pad non-power-of-2 atomics (i96 timestamps) to i128; guard the plain integer with a lock or truncate to i64. Note dead code hides such bugs: uninstantiated functions are never analyzed.
- **Never `@splat` a runtime bool into a bool vector** (miscompiles on `@Vector(32, bool)` in Debug — silent lane garbage, caught only against a scalar reference). Splat a comptime bool or build the mask from a vector comparison (`bh_v <= @as(@Vector(N, i32), @splat(sea_level))`). Integer splats and comptime bool splats are fine; `@select` chains are safest for combining masks; verify bit-identical output against a scalar reference.
- **`@typeInfo` has no `.slice` variant** — slices are `.pointer` with `Pointer.size == .slice`.
- **`std.meta.eql` compares slices by pointer identity**, not content. Deep slice comparison must be hand-written.
- **`std.Io.Writer` has a field named `end`** (usize), so `writer.end()` exists only on file writers, not bare `std.Io.Writer`.
- **`std.zon.parse.free` crashes on comptime-backed defaults** (e.g. slices into `@embedFile` data). Parse into a throwaway `std.heap.ArenaAllocator` and discard the arena instead of freeing field-by-field.

# Concurrency, Vulkan & GPU

## Mesh upload backpressure: all-or-nothing reservation under an admission mutex

`MeshUploader.reserveUpload` acquires everything an upload needs (command pool, both staging slices via `StagingRing.allocPair`, both face regions) atomically under `admission_mutex`. Invariant: any thread holding upload resources outside that section is fully provisioned and on a non-blocking path to `submitBatch`, so flush-and-wait backpressure always waits on GPU progress, never on another blocked CPU thread. Never add acquisition after `reserveUpload` in the `addMesh` path — hold-and-wait reintroduces the deadlock (the staging ring retires FIFO and stops at the first unbound entry, so an unbound slice held by a blocked thread wedges the ring permanently).

## Async drain vs. the candidate buffer's GPU-idle window

The upload drain (`submitBatch` + `retireCompletedUploads` + `processRetired`) runs on a background task dispatched per frame via a `restartFuture`-style poll (`drain_is_running` + `drain_future`; the frame reaps a finished pass with `future.await` inside the `if (!running)` branch, then re-dispatches with `io.concurrent(...) catch io.async(...)` — never waiting on a running pass). The frame's draw then calls `publishPending` to apply the recorded scene effects.

The split exists because the cull shader reads `scene.persistent.buffer` every frame, and CPU writes to `persistent.mapped` (`writeCandidate`/`markInactive`/`releaseCandidate`/`growPersistentCandidates`) are only safe when no GPU command can be reading it. `beginFrame`'s timeline throttle (waits `frame_number - max_frames_in_flight + 1`) proves the GPU idle for the graphics queue, so the frame thread's window between `beginFrame` and the first recorded cull is the only sound place to touch candidates — a background task cannot self-gate this. The drain task therefore only _records_ cheap `Publication` ops (`retire`/`remove`/`free_index`) into a list guarded by `retire_mutex`; `publishPending` (frame thread) applies them (`allocIndex`/`writeCandidate`/`fetchPut`/`markInactive`/`releaseCandidate`/`enqueueRetiredMesh` plus index-pool frees). Worker-thread flush drains (`flushUploads`, full-queue `pushPendingUpload`) record publications the same way. Teardown cancels + awaits the drain future before draining queues.

`publishPending` must NOT hold `retire_mutex` while applying (the drain task can hold it for the whole pass — the frame would stall). Swap the whole `ArrayList` out under the mutex (`std.mem.swap(...)` with a frame-private scratch) and apply lock-free. Stealing a _slice_ is a memory-safety bug: `clearRetainingCapacity` keeps the backing buffer, so the drain task's next appends overwrite the slice mid-iteration (`switch on corrupt value` panic). `retired_meshes` appends from the apply step race the drain task's `processRetired` sweep, so that list has its own `retired_meshes_mutex`. Lock order: `retire_mutex` → `retired_meshes_mutex`, never reversed.

## Entity update queue (EntityRegistry)

The registry never iterates its cache: `update` and `deinit` walk a dynamically-sized `ArrayList` of live entity ids and look each up by uuid (the `SetAssociativeCache` iterator walks every slot, so per-frame cost must not depend on cache capacity). Queue (authoritative, deliberately uncapped — can exceed cache slots) → cache (bounded resident tier) → eviction spills the victim through the `save` flag on unload. An evicted entity leaves a stale id that the pass drops on lookup miss — no cross-structure cleanup; until a load path reloads evicted entities, the steady-state live set is bounded by cache eviction. Lock order: `queue_mutex` before any cache shard lock, never after.

## Per-frame fence wait

In a multi-buffered loop, wait for only the current frame's fence: `_ = try self.dev.waitForFences((&self.in_flight_fences[current_frame])[0..1], .true, timeout);` then `resetFences` on the same slot. Waiting for all fences over-constrains frame N+1 on every prior submission and can hang — especially after swapchain recreation, where new fences are created signaled and a wait-all loop can block on a previous cycle's unsignaled fence.

## Handling persistent VK_SUBOPTIMAL_KHR

`VK_SUBOPTIMAL_KHR` is usable; recreating may improve compatibility, but some variable-extent platforms keep returning it after a valid replacement is installed. Guard against an infinite loop: let the first suboptimal result request recreation, suppress duplicates until an explicit physical-size/configuration change resets the guard. `VK_ERROR_OUT_OF_DATE_KHR` is still handled unconditionally.

## Validation-layer false positives (safe to ignore)

- **MangoHud + sync validation:** MangoHud's injected `vkCmdBeginRenderPass` issues `VK_ATTACHMENT_LOAD_OP_LOAD` without a proper execution dependency on the app's prior transitions to `VK_IMAGE_LAYOUT_PRESENT_SRC_KHR`, producing `SYNC-HAZARD-READ-AFTER-WRITE`. Ignore messages containing `0xe4d96472` and `vkCmdBeginRenderPass` — MangoHud bugs, not app bugs.
- **`deviceWaitIdle` + timeline semaphores:** mixing `vkDeviceWaitIdle` with timeline-semaphore sync (e.g. buffer capacity reallocations) confuses the validation layer into `SYNC-HAZARD-WRITE-RACING-WRITE` on `vkQueueSubmit2`. Ignore messages containing `0x743c6069` when a timeline semaphore and `deviceWaitIdle` are involved.

## OIT volume term invariants (transparent_frag.frag / composite_frag.frag)

The water volume integrates in a reference frame: each face adds `density * absorption * (bg - frag)` entering and subtracts it exiting, so thickness only survives if entry and exit faces integrate against the same background distance. Rules:

- Sky pixels hold cleared depth 0.0, whose linearization `near / depth` is infinite — both faces of a pair saturate the same clamp and cancel to zero, so water against sky would show no volume. `sky_dist` (256) substitutes the reference only for those pixels. Real backgrounds must never be clamped: volumes sit up to ~100,000 blocks away, and clamping erases every volume past the clamp. `sky_dist_max` (2048) clamps sky-referenced distances symmetrically so distant sky pairs cancel cleanly instead of leaving f16 quantization noise. The surface term's gate uses the unclamped value so water past `sky_dist` keeps its fresnel surface.
- Pair precision is bounded by f16 quantization: thickness survives only past ~1/1024 of the write magnitude. Finite backgrounds write ~the local segment (far oceans correct at any distance); the sky reference writes ~max(sky_dist, z) (sky-backed volumes exact to roughly a thousand blocks, clean zero beyond). Stacked saturated faces can overflow the f16 sum to Inf, so the composite gates scatter on `td_scalar < 65504`.
- Absorption must stay position-independent (`1 - volume_color`, no light term) — entry/exit faces sample light at different points, so light-dependent absorption leaves a cancelation residue. Day/night scatter is applied in the composite via `OitCompositor.volumeScatterLight`.
- Thickness is ray length, not eye-Z difference: multiply by the slant `length(frag_pos) / fragment_depth` (off-axis pixels at 90° FOV otherwise undercount by up to ~0.58x).

`near_plane` must match core.zig's projection near (0.01); the `near / depth` linearization assumes the infinite reverse-Z projection. Known gap: inside water, rays have an exit face but no entry face, so net optical depth is negative and clamps to zero (no underwater tint) — needs a virtual entry term in the composite or raymarched volumes.

## Matrix layout for GLSL push/params (CSM gotcha)

zm matrices store translation in the **last column of each row** (`v · M`, row-vector). `@bitCast(zm.data)` into `[16]f32` handed to GLSL as `mat4` makes `M * v` compute `v · M_zm` — fine for an origin-eye camera view (last column `(0,0,0,1)`, `w` stays 1), but a light/projection matrix with a non-origin eye gets a huge projective `w` term and is silently wrong. Build light view-projection **directly in GLSL column-major layout** (translation in the 4th column, bottom row `(0,0,0,1)`, so `w == 1`):

```
flat[i*4+j] = M[i][j];   // column-major GLSL: M[c][r] = flat[c*4+r]
row0: (s.x/r, u.x/r, f.x/fnf, 0)
row1: (s.y/r, u.y/r, f.y/fnf, 0)
row2: (s.z/r, u.z/r, f.z/fnf, 0)
row3: (s·t/r, u·t/r, (f·t - near)/fnf, 1)
```

`s,u,f` = light basis, `r` = box half-extent, `fnf = far - near`, `t = view_pos - center`. Vulkan NDC depth is `[0,1]` — near maps to 0, far to 1, no OpenGL `z * 0.5 + 0.5` conversion on shadow depth. Verify with a CPU helper `out[i] = sum_j flat[j*4+i]·v[j]` against ground-truth light-space coordinates (the Csm tests do this). zm's `lookAtRH`/`orthographicRH` compose in the opposite product order to a column-vector mental model; prefer building these matrices by hand.

# Worldgen & Terrain

## Runevision erosion filter (Terrain.zig + libs/phacelle.zig + libs/erosion.zig)

- **Units (all normalized):** `p` into `erosionFilter` is the noise-grid base coordinate _divided_ by `erosion_scale` (multiplying makes gullies coarser than the relief). Height input is raw `shaped` (≈[-1,1]). On the way out the base field takes the asymmetric envelope `|bounds| * scale` (continuous through zero), but deltas must not: local-`|bounds|` conversion doubles them at the shoreline and cliffs every crossing gully. Both deltas convert with symmetric `max(|min|, |max|) * scale` (both flow through `composeErodedHeight`), so relief matches on land and under water; both amplitudes stay normalized so saved configs keep magnitude. Downhill slope is the negated central-difference gradient of `shaped` at +/- one sample spacing.
- **Cell size is a locked ratio:** inside `phacelleNoise` the phase ramps at `cell_scale * TAU` per unit cell, and octave `freq` scales stripe frequency and cell grid together (unit cells in `p * freq` space) — doubling frequency halves cells automatically, no per-octave tuning. `cell_scale` is a unitless ratio on the `erosion_scale` master.
- **Load-bearing order:** each octave steers off the `gully` slope accumulated by the previous octave (`State.apply`); `side *= -freq` is the chain rule for the caller's `p * freq` scaling plus the downhill sign flip. `side` carries `norm_dir_perp * cell_scale * TAU`; the caller scales it by the octave `freq` exactly once.
- **Mask chain:** `mask = powInv(mask, detail) * new_mask`, `powInv(x, p) = x^(1/p)` (detail < 1 crushes older masks onto steep slopes; `powInv(0)` latches closed, flats stay uncarved). `smoothStart(t, smoothing)` must guard `smoothing <= 0` and return a step (`crease_rounding = 0` would divide by zero). Per-octave `new_mask` gates on the _wave's_ slope (`|sin|`); the first-octave seed is the terrain steepness mask (next bullet).
- **Peak/valley preservation (steepness fade):** octave sampling stays absolute in world space; flats are protected by the mask alone. First-octave mask seeds with inverted-quadratic `1 - (1 - steepness)^2` (closed on flats, 3/4 open at half steepness), so on flat ground every octave lerps to the previous target (zero on the first) and the delta is exactly 0. `fade_slope` is the steepness of fully-open mask. Steepness comes from a wide-stencil average (`fadeSteepness`), not the per-sample gradient, or fine-noise flicker strobes the mask between neighbors. `fade_slope <= 0` disables the fade.
- **LOD consistency:** effective octaves = `max(1, erosion_octaves -| level)` (`Params.erosionFilterParams`); octaves stay absolute in world space. The level-1 vs box-filtered level-0 test tolerance covers the gradient-resampling shift (e doubles per level) plus the coarser fade stencil moving the per-sample mask: 40% of `filter_strength / (1 - gain) * gully_weight` plus 128 blocks fixed slack.
- **Hash deviation:** the reference's `fract` cell jitter loses precision far from origin; `phacelle.zig` uses `fastnoise.hash2D`/`hash2DVec` with low/high 16 bits mapped to [-0.5, 0.5]. Exact at ±100,000-block coordinates.
- **Benchmark (Debug, Xeon):** base `genTerrainHeight` ≈ 540 µs/chunk; with filter ≈ 6.4 ms/chunk (~12x the base pipeline). Gradient stage ≈ 4 extra batched warp+noise fills; Phacelle's 16 cells × 4 octaves of transcendentals dominate. Done levers: polynomial `exp(-2d^2)` weight (`bellWeight`, ~3e-7), LOD octave drop, `@Vector(16, f32)` cell loop.
- **Build-stable direction:** `grad_x`/`grad_z` were `undefined` and `addGradientSamples`' first pass reads them (`grad_row + shaped*k`) — uninitialized stack content is build-dependent, so ReleaseFast vs Debug rotated the whole gully pattern. Fixes: zero-init accumulators, `@mulAdd` so accumulation cannot FMA-contract differently per build, blend the seeded direction toward the assumed-slope direction below the 1e-4 gradient noise floor (`gradient_floor` in `erosion.zig`), since fastnoise fills run `@setFloatMode(.optimized)` and are never bit-stable across build modes. FP reassociation anywhere in this pipeline changes the terrain bit pattern; keep operation order when refactoring.
- **Config compat:** `erosion_strength` stays in `Params` with `.skip = true` in `field_specs` (superseded `erosion_fade_altitude` follows the same pattern). See Config compat below for the declaration-default and `InvalidConfig` rules.

## JitteredGrid placement (Planet generator)

- `JitteredGrid.getStructure` only finds a structure from positions **at or below** it (`structure_pos >= pos_in_box`), and for negative cells the structure position itself goes negative so the in-range check always fails — negative-coordinate queries silently return null. Shift the grid by a large positive constant so every used cell index is positive.
- `level` scales the query position by `2^level` (`real_position = scale * position`). Querying position = `cell` with `scale == box_size` lands on the cell origin (`pos_in_box == 0`), reducing the in-range check to `jitter < scale` — always true when `inner_box_size < box_size`. This is the O(1) "which structure owns this cell" trick.
- A sphere with a one-sided found region can never be found from all sides. Clamp the structure position inside its cell (`clamp(jitter, radius, box_size - radius)`) so the whole sphere stays in the owning cell; every block then finds it through its own cell.

# Config, Persistence & Plugins

## Config compat

`std.zon.parse` only tolerates missing fields that carry a **declaration default**, so every `Params` field keeps its default in the declaration (`.default` is just `Params{}`) or old saved configs break. `loadConfig` returns `error.InvalidConfig` instead of falling back, so a broken config fails loudly without being overwritten. Any field added to `Params` must keep a declaration default. Superseded fields are kept with `.skip = true` in `field_specs` (`erosion_strength`, `erosion_fade_altitude`).

## Clearing RocksDB chunk storage

Clear persisted chunks through RocksDB while the database is open, using a `WriteBatch` range tombstone per chunk column family and flushing both families afterward. Stop background saves and finish the final save before clearing; never remove the database directory from the filesystem while RocksDB owns it.

## Generator shared libraries (DLL plugins)

Generators are shared libraries loaded at runtime with `std.DynLib` (real dlopen on this libc-linked Linux build). The exe embeds the built `.so` (via `addAnonymousImport` + `@embedFile`, same as the shaders) and writes it into `generators/` at startup.

**C-ABI export rules (Zig 0.16):** `pub export fn` / `@export` require a machine calling convention and cannot take auto-layout structs by value (`std.mem.Allocator`, `std.Io`, slices, error-union returns). Everything crossing the boundary must be a pointer, nullable pointer, or primitive. The working pattern: export a single `extern struct` vtable of function pointers (`@export(&vtable, .{ .name = "..." })`) — function pointers cross as data with Zig's native calling convention, identical on both sides since host and generators share one compiler. Error unions cannot be exported; use nullable-pointer returns (`?*T`, null = failure).

**Module scope:** a module's import scope is its `root_source_file`'s directory, so a generator under `src/world/generators/` cannot be the `.so` root (its `../` imports escape the module path). One shared root `src/generator_root.zig` sits at `src/` level; `build.zig` compiles it once per generator, selecting via a `generator_select` options module and comptime switch, and each generator's `comptime { @export(...) }` block emits its `generator_api` vtable. No per-generator shims — add a generator with a `.kind` arm in `build.zig`'s `GeneratorKind` plus a `@import` arm in `generator_root.zig`.

**Config UI metadata:** `generator_api.Spec` presentation fields (`label`, `description`) are borrowed from the loaded generator library, while config keys/values/choice entries are owned by the config allocator — keep the library loaded as long as its config tree is used. Changes to shared config-tree layouts require incrementing `generator_api.ApiVersion` and rebuilding every plugin. Derive config widget IDs from the stable parameter path, not traversal order (order-derived IDs shift when an array is edited and widget state lands on the wrong field).

## Editor UI (dvui)

Widget ids collide when the same `@src()` line runs for multiple params — pass `.id_extra` per param. `dvui.dropdown` (and other `*T` choice widgets) write the selected index into the pointed-to value **in place during the draw call**: never guard a post-draw action with `if (index == my_choice_var)` after passing `&my_choice_var` as `.choice` — the variable was already mutated, so the guard always fires and the action is skipped. Capture `const previous = my_choice_var;` first and compare against `previous`.

# Testing

## Allocation failure testing

Cover allocation-performing functions with `std.testing.checkAllAllocationFailures` — it exhaustively fails each allocation point to prove `OutOfMemory` handling and leak-free error paths. The test fn takes only an allocator (plus `std.Io` in the args tuple when needed), allocates, operates, and cleans up via `defer`.

```zig
fn stagingRingAllocDeinit(alloc: std.mem.Allocator) !void {
    var ring = try StagingRing.init(alloc, alloc, 16);
    ring.deinit(alloc);
}

test "StagingRing checkAllAllocationFailures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, stagingRingAllocDeinit, .{});
}
```

## Noise vector-vs-scalar tolerance

Vectorized noise/warp paths vs their scalar counterparts (`fillGrid2D`/`fillNoise2DGrid`/`fillWarp2DGrid` vs `genNoise2D`/`domainWarp2D`) match bit-exact in Debug but differ ~1 ULP in ReleaseFast (wider vector ops reassociate/FMA-contract differently than the N=1 path). Use `std.testing.expectApproxEqAbs(expected, actual, 1e-5)`, never `expectEqual` — and never relative tolerance, since values near zero explode the relative error of a 1e-8 absolute difference.

## Fuzz tests

Fuzz with `std.testing.fuzz` + `std.testing.Smith` when the input space is too large to enumerate (meshing, chunk encoding, allocator internals). Fuzz callbacks find crashes/panics — never `try std.testing.expect*` inside them; use `std.debug.assert`/`@panic` or let the code crash. Always clean up with `defer` (leaks accumulate across runs and hide bugs). `@disableInstrumentation()` in allocators/fakes used by fuzz tests, so the fuzzer tracks the code under test, not allocator branches. Write single-threaded first (deterministic, fast, catches most bugs); add multi-threaded only for thread-safe code.

Simple (void context) and context-rich (allocator/Io/state) forms:

```zig
test "FuzzMesh" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(_: void, smith: *std.testing.Smith) !void {
    var grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = undefined;
    const main_grid: Chunk.Encoding = .fuzzerMakeEncoding(&grid, smith);
    const neighbor_faces: [6]Chunk.Encoding.Face = smith.value([6]Chunk.Encoding.Face);

    var alist: std.ArrayList(Face) = .empty;
    defer alist.deinit(std.testing.allocator);

    try Mesher.mesh(std.testing.allocator, main_grid, &neighbor_faces, &alist, &alist);
}
```

```zig
const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    world: *World,
};

fn fuzzChunkLoad(context: Context, smith: *std.testing.Smith) !void {
    var generator: FuzzGenerator = try .init(smith);
    context.world.chunk_sources = .{ generator.getSource(), null, null, null };

    const test_chunk = try context.world.loadChunk(
        context.io, context.allocator,
        .{ .level = smith.value(i32), .position = smith.value(@Vector(3, i32)) },
        smith.value(bool),
    );
    test_chunk.release();
}
```

**`fuzzerMake*` helpers** live on the type (not the test) so every test can use them: randomly choose a representation (e.g. grid vs uniform encoding) so the fuzzer explores all paths without the test knowing the variant.

**Weighted generation:** `smith.valueWeighted` biases toward edge cases (e.g. alignments ≤ 16 at high weight plus rare max-alignment overflow; `smith.boolWeighted(31, 1)` for ~3% OOM rates). Weights are multiplicative within a call; comment the intent.

**Concurrent fuzz tests** use a producer-plans/workers-execute model: the main callback pre-generates all ops, parameters, and OOM failure sequences (boolean arrays consumed via atomic index), spawns workers that grab op indexes with atomic CAS, and coordinates with two primitives — `MemoryDependency` (`std.Io.Event` + `?[]u8` result; producer `set`s, consumer `get`s via `waitUncancelable`) for producer-consumer sequencing, and a toggling packed-struct `Run` (`io.futexWait`/`futexWake`, main thread flips and waits for `running` to reach zero) for batch coordination. Fake backing allocators never reuse memory (fill-pointer bump; atomic fill for multi-threaded) to catch use-after-free, fill new memory with a splat pattern and verify on free/resize/remap, and keep fuzz callbacks fast (setup once outside `std.testing.fuzz`).
