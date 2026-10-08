# Agent Guide

## Workflow

Use these commands without modification:

- build: `zig build`
- format: `zig fmt .` (it aborts on vendored `zig-pkg/` sources that still use the removed `**`; when it does, run `zig fmt` on the touched files and do not edit `zig-pkg/` to fix it)
- measure size: `zig fmt --check --complexity <files or dirs>` prints per-file `tokens=`/`nodes=` (AST nodes) and a total to stderr without modifying files. Counts ignore formatting, so net token count (not line count) is the hard requirement for "simpler/smaller" in the simplify, prune, and improve-anything skills; node count is informational.
- run to the menu: `zig build run`
- run into a game: `export VK_LOADER_LAYERS_ENABLE="*validation" && zig build run -Dtest_play=[seconds, 5-10 is a good default]`
- tests: `zig build test --summary all`, or scoped with `-Dtest_filter="substring"` (see Testing)

Do not gate every micro-edit. Batch related edits and run the gates the `verify-change` skill selects at a checkpoint (a feature or fix is complete, or before reporting back): always `zig fmt .` + `zig build`, tests per environment, and the play test only when the change is user-visible.

Do not git stash, commit, checkout, or reset; read-only git (`diff`, `log`, `status`) is fine.

**Verify before writing.** When a scout or audit proposes a change, independently verify its claim before implementing it: grep callers including vendored deps, check framework dispatch and call order, prove ordering or equivalence, or write a ~10-line scratch test on this toolchain. A claim without its check goes back.

**Adding to this file.** Whenever you learn something useful for the future, add it here. State each rule once in the section it belongs to, compress instances, and drop anything that restates an existing rule.

## Skills and logs

Repo skills live in `.agents/skills/`; the trigger list decides, not guesswork. `concurrency-io`: background tasks, locks, upload/staging, entity registry, `Io`. `generator-plugin`: generators, `generator_api`, config trees, config editor UI. `verify-change`: which gates to run at a checkpoint. `profile-tracy`: frame times, zones, contention. `prune`: dead-code scan, one candidate per turn. `debate`: competing designs. `fanout-orchestrate`: parallel workers. `simplify`: run on newly written code to simplify it and enforce every guideline in this file. `redesign`: remove unneeded or shared state and pick better data structures without raising token or node count; the design-level partner of `simplify`. `improve-anything`: open-ended improvement modes. `asd-ste100`: disambiguating agent-consumed English.

`ideas.md` is an append-only research log plus periodic triage: `research` mode appends one short entry with links and never reorders; `triage` mode merges duplicates, drops done items, and sorts by benefit-to-effort.

# Naming, Style & Code Quality

Core philosophy: **meaning dictates casing**. Code must be self-documenting — structure, names, and logic communicate intent without external explanation.

## Naming

| Element                          | Casing                   | Example                                     |
| :------------------------------- | :----------------------- | :------------------------------------------ |
| **Variables, fields, constants** | `snake_case`             | `model_weights`, `is_active`                |
| **Functions**                    | `camelCase`              | `parseData(input: []const u8)`              |
| **Functions returning `type`**   | `PascalCase`             | `CreateGraphNode(comptime T: type)`         |
| **Types & aliases**              | `PascalCase`             | `NeuralNetwork`, `Dataset`                  |
| **Namespaces** (0-field structs) | `snake_case`             | `math_utils`, `tensor_ops`                  |
| **Files**                        | type: `PascalCase`, namespace: `snake_case` | `AttentionLayer.zig`, `matrix_helpers.zig` |
| **Directories**                  | `snake_case`             | `data_loaders/`                             |

Acronyms are normal words, never fully capitalized (`parseHttp`, `JsonParser`, `io_stream`). A file with top-level fields is a type; functions/constants only make it a namespace.

## Comments

Use comments sparingly: the _why_ behind a non-obvious decision, `TODO` items, or logic that cannot be clarified by renaming. One or two plain sentences; a paragraph means the code is too complex. No decorative characters, ASCII art, or banner separators. Doc comments (`///`) are expected on public declarations, same plain style.

```zig
// ✗ WRONG — stating the obvious
// increment i by 1
i += 1;

// ✓ CORRECT — explains why
// The order matters here: upstream expects sorted keys.
std.sort.insertion(Key, keys, {}, Key.lessThan);
```

## Structure and control flow

- **Single responsibility:** one thing per function; conjunctions in the name mean it does too much. A body that needs visual dividers, or does not fit on one screen, should be split into private helpers.
- **Minimal signatures:** group related args into a context struct instead of a long argument list.
- **Guard clauses:** early returns over nesting; the happy path runs down the left side.
- **Fail fast:** handle or propagate errors; unrecoverable failure fails loudly. `catch {}` only for operations whose failure does not matter (e.g. `yield`). An error that cannot occur (`Canceled` in an uncancelable block, a `std.mem.print` that cannot practically overflow) takes `catch unreachable`, never `catch {}`.
- **Inlining:** let the compiler decide, except to change stack-frame count for debugging, to force comptime-ness to propagate, or when measurements demand it.

## State and mutation

- **Float precision is not sacred:** reordering or reassociating float math, and results that differ by a few ULPs or lose a little precision, are acceptable unless the code documents an exactness requirement (such as the erosion pipeline's build-stability rule).
- Declare variables in the deepest scope, close to first use. Never rely on hidden state; a mutating function's name and signature must make that obvious. Bind magic numbers to named constants.
- **Minimize unsafe casts:** `@bitCast` over `@ptrCast`/`@alignCast`; `@ptrCast` is almost only for opaque pointers.
- **Never use `std.mem.zeroes`:** it bypasses field defaults, so a later non-zero default silently changes every zeroed site. Use `.{}` with defaulted fields, `@splat(0)`, or a named `fn zeroed() T`.
- **Initialize before use; prefer optionals over undefined.** An optional set to undefined cannot be null-checked. A value always overwritten before any read (scratch buffer, out-param) is `= undefined`, so safety-checked builds catch a missed write; never substitute a plausible dummy value that hides that bug.
- **Handles over pointers in hot structures:** relations live in flat arrays referenced by compact integer handles (`u32`/`u16`), not raw pointers — denser, cache-friendly, immune to realloc invalidation, and snapshot by plain copy. Pointers are for out-params, `p_next` chains, and C APIs.
- **Reserve first, then mutate infallibly:** a mutation touching two or more structures reserves all capacity up front (`ensureUnusedCapacity`), then inserts with `...AssumeCapacity`. A mid-operation OOM must never leave half-updated state.
- **Intern repeated strings/ids:** one flat byte buffer plus a table mapping slice to index; compare by handle.

## Idioms

- **`std.enums` containers** for enum-keyed data instead of hash maps or bool bags: `EnumMap` (sparse), `EnumSet` (flags), `EnumArray` (dense). Iterating an enum's `@typeInfo(E).@"enum".field_names` plus an `EnumSet` of active states replaces ad-hoc bool clusters and stays exhaustive.
- **Captures over indexing:** zip parallel arrays with multi-captures, mutate with `|*item|`, unwrap with `if (maybe) |value|`. Use a numeric index only when it is meaningful, via the `, 0..` capture — never `for (0..x.len) |i|`.
- **Array literals:** annotate the binding instead of repeating the type: `const formats: [2]vk.Format = .{ .r16g16b16a16_sfloat, .r16g16b16a16_sfloat };`.

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

# Zig Toolchain

The project targets Zig 0.17.

## Changes in 0.17

- Reflection is parallel arrays: `@typeInfo(T).@"struct"`/`.@"enum"` expose `field_names`/`field_types`/`field_attrs`/`field_values`, zipped with `inline for (info.field_names, info.field_types) |name, F|`; `std.meta.fields` is gone and `Fn.params` is `param_types`. `field_values` are `comptime_int`, so loops over them must be comptime.
- `std.builtin` is `std.lang`; optimize modes are lowercase (`.debug`, `.safe`, `.fast`, `.small`).
- `@Type` is replaced by `@Enum`/`@Struct`/`@Union`/`@Fn`/`@Pointer`/`@Int`, which take parallel arrays (`@Enum(TagInt, .exhaustive, &names, &values)`).
- The `**` array repeat is gone: use `@splat` (`@as([N]u32, @splat(0))` to concatenate).
- Extern structs cannot hold `@Vector`; GPU-mirrored vec4s are `[4]f32 align(16)`, which keeps std430 offsets.
- `std.zon.parse.fromSlice(T, .{ .gpa, .arena, .source, .diagnostics })`: results go to `arena` (discard it whole, never free field-by-field), scratch to `gpa`; call `diagnostics.log(name)` on `error.ParseZon`.
- Renamed std APIs: `std.mem.print` (was `fmt.bufPrint`), `allocator.print` (`fmt.allocPrint`), `std.mem.find*` (`indexOf*`), `std.ArrayList` (`ArrayListUnmanaged`), `std.Io.Dir.path` (`fs.path`), `std.heap.SafeAllocator` (`DebugAllocator`), `std.heap.BufferFirstAllocator`, `@memmove` (`mem.copyForwards`); default-initialized hash maps use `.empty`.
- `zig-pkg/` holds local 0.17 patches (SDL2 `build.zig` sysroot, dvui's Vulkan renderer) that a refetch or cache wipe discards.

## `std.Io`

Anything that can block or introduce nondeterminism takes an `Io` instance.

- **`Future(T)`:** `io.async(func, args)` (infallible) or `io.concurrent(func, args)` (can fail); `future.await(io)` retrieves, `future.cancel(io)` cancels. Defer-cancel right after creating a task: `defer if (file_task.cancel(io)) |file| file.close(io) else |_| {};`.
- **`Group`:** `var group: std.Io.Group = .init;`, `group.async(io, func, args)`, `group.await(io)`. **`Batch`** groups concurrent operations (e.g. batched file reads), not functions.
- Subsystems take `Io` directly: `std.Io.Dir`/`File` (`file.close(io)`), `std.Io.net`, `std.process.spawn(io, ...)`, `std.Io.Timestamp.now(io)`, `io.sleep(duration, clock)`.
- Mutexes suspend via the runtime: `lock(io)`, `tryLock()`, `unlock(io)`. Canceled operations return `error.Canceled`.

## Pointer safety

- **`@embedFile` alignment:** it returns `*const [N:0]u8` with alignment 1; `@alignCast` must apply to the original comptime-known pointer. A non-inline helper taking `[]const u8` loses the metadata and panics at runtime — cast at the call site (`.p_code = @ptrCast(@alignCast(spv.ptr))`) or in an `inline fn`.
- **Single-item slices:** pass one value as a many-pointer with `(&x)[0..1]`, writing directly into the destination (`(&sets[i])[0..1]`) — never `@ptrCast(&x)`, `&[1]T{x}`, or a `[1]` array. Real arrays use `arr[0..n]` (add `.ptr` for `?[*]const T`). Exceptions: `p_next` chains (`@ptrCast`) and `*T` output params.

## Footguns

- **`std.atomic.Value(i128)` fails codegen in Debug** (seen on 0.16). Never pad non-power-of-2 atomics (i96 timestamps) to i128; lock the plain integer or truncate to i64.
- **`@bitCast` to or from a nested array inside any generic function segfaults the 0.17 compiler in ReleaseFast and ReleaseSafe** (Debug compiles, so a Debug-only gate misses it). This includes a call site like `Interp.init(@bitCast(flat))` inside a `comptime`-parameterized function. Always reinterpret with `std.mem.bytesAsValue(T, std.mem.asBytes(&x)).*`.
- **Never `@splat` a runtime bool into a bool vector** (silent lane garbage in Debug on 0.16). Splat a comptime bool or build the mask from a vector comparison; verify against a scalar reference.
- **Dead code hides bugs:** uninstantiated functions are never analyzed, so a removed API can survive in an uncalled function.
- **`@typeInfo` has no `.slice`:** slices are `.pointer` with `size == .slice`.
- **`std.meta.eql` compares slices by pointer identity**, not content.
- **`std.Io.Writer` has a field named `end`**, so `writer.end()` exists only on file writers.

# Build & Testing

## Build

- **glslc `#include`s must be registered as build inputs.** glslc resolves includes internally, but an include the Zig build graph doesn't know about never invalidates the glslc cache, so the SPIR-V goes stale while Zig layouts recompile — a silent mismatch (e.g. no shadows; the `.spv` mtime predates your edit). Register it: `frag_cmd.addFileArg(b.path(".../fragshader.frag"));` plus `frag_cmd.addFileInput(b.path(".../shadow.glsl"));`. After layout changes, check `spirv-dis <spv> | grep "OpMemberDecorate %ShadowParamsBuffer"` against the Zig `@offsetOf` asserts.

## Running tests

- The full suite has pre-existing wio/wayland crashes in headless environments; there, use `zig build` plus `-Dtest_filter` for the touched areas. Never substitute a filter for the suite where the suite runs.
- `-Dtest_filter` substring-matches the fully-qualified name (`module.file.test.name`) and only sees files reachable from `main.zig`'s import graph — a new file's tests are invisible until something reachable references it. Unnamed `test {}` blocks always run; name a test that must be filterable.
- A test that writes to stdout (benchmarks) makes `zig build test` report a failed command on success: ignore a failed-step summary with no `error:` and no failing test.

## Writing tests

Write few tests: just enough to cover real failure modes, not restatements of the implementation. Every file gets a `refAllDecls` test. Fallible allocation paths that must survive OOM get one `std.testing.checkAllAllocationFailures` each:

```zig
fn stagingRingAllocDeinit(alloc: std.mem.Allocator) !void {
    var ring = try StagingRing.init(alloc, alloc, 16);
    ring.deinit(alloc);
}

test "StagingRing checkAllAllocationFailures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, stagingRingAllocDeinit, .{});
}
```

**Noise vector-vs-scalar tolerance:** vectorized noise/warp paths match their scalar counterparts bit-exact in Debug but differ ~1 ULP in ReleaseFast. Use `expectApproxEqAbs(expected, actual, 1e-5)` — never `expectEqual`, never relative tolerance (values near zero explode it).

## Fuzz tests

Fuzz with `std.testing.fuzz` + `std.testing.Smith` when the input space is too large to enumerate (meshing, chunk encoding, allocator internals). Callbacks find crashes — never `try std.testing.expect*` inside them; use `std.debug.assert`/`@panic`. Always clean up with `defer` (leaks accumulate across runs). Put `@disableInstrumentation()` in allocators/fakes so the fuzzer tracks the code under test. Write single-threaded first; add multi-threaded only for thread-safe code.

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

Context-rich form (allocator/Io/state passed in a struct):

```zig
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

- **`fuzzerMake*` helpers** live on the type so every test can use them, and randomly choose a representation (grid vs uniform encoding) so the fuzzer explores all paths.
- **Weighted generation:** `smith.valueWeighted` biases toward edge cases; `smith.boolWeighted(31, 1)` gives ~3% OOM. Weights multiply within a call; comment the intent.
- **Concurrent fuzz tests:** the main callback pre-generates all ops, parameters, and OOM sequences; workers grab op indexes by atomic CAS. Coordinate with `MemoryDependency` (`std.Io.Event` + `?[]u8`; producer `set`s, consumer `get`s via `waitUncancelable`) and a toggling packed-struct `Run` (`io.futexWait`/`futexWake`; main flips and waits for `running` to reach zero). Fake backing allocators never reuse memory (atomic bump fill), fill new memory with a pattern verified on free/resize/remap, and set up once outside `std.testing.fuzz`.

# Concurrency

## ConcurrentHashMap compound ops

`Bucket.get` releases the shard lock before returning, so never read-modify-write through it. For locked compound sequences use `getBucket(key)` plus explicit `bucket.lock` / `bucket.hash_map` access, holding one bucket lock at a time and never nesting.

## Mesh upload backpressure

`MeshUploader.reserveUpload` acquires everything an upload needs (command pool, both staging slices via `StagingRing.allocPair`, both face regions) atomically under `admission_mutex`. Invariant: any thread holding upload resources outside that section is fully provisioned and on a non-blocking path to `submitBatch`, so flush-and-wait backpressure always waits on GPU progress, never on another blocked CPU thread. Never add acquisition after `reserveUpload` in the `addMesh` path — hold-and-wait reintroduces the deadlock (the staging ring retires FIFO and stops at the first unbound entry, so an unbound slice held by a blocked thread wedges the ring permanently).

## Async drain vs. the candidate buffer's GPU-idle window

The upload drain (`submitBatch` + `retireCompletedUploads` + `processRetired`) runs on a background task dispatched per frame via a `restartFuture`-style poll (`drain_is_running` + `drain_future`; the frame reaps a finished pass with `future.await` inside the `if (!running)` branch, then re-dispatches with `io.concurrent(...) catch io.async(...)` — never waiting on a running pass). The frame's draw then calls `publishPending` to apply the recorded scene effects.

The cull shader reads `scene.persistent.buffer` every frame, so CPU writes to `persistent.mapped` (`writeCandidate`/`markInactive`/`releaseCandidate`/`growPersistentCandidates`) are only safe when no GPU command can be reading it. `beginFrame`'s timeline throttle (waits `frame_number - max_frames_in_flight + 1`) proves the graphics queue idle, so the frame thread's window between `beginFrame` and the first recorded cull is the only sound place to touch candidates — a background task cannot self-gate this. The drain task therefore only _records_ cheap `Publication` ops (`retire`/`remove`/`free_index`) under `retire_mutex`; `publishPending` (frame thread) applies them. Worker-thread flush drains (`flushUploads`, full-queue `pushPendingUpload`) record the same way. Teardown cancels + awaits the drain future before draining queues.

`publishPending` must NOT hold `retire_mutex` while applying (the drain task can hold it for a whole pass). Swap the whole `ArrayList` out under the mutex (`std.mem.swap` with a frame-private scratch) and apply lock-free. Stealing a _slice_ is a memory-safety bug: `clearRetainingCapacity` keeps the backing buffer, so the drain task's next appends overwrite it mid-iteration. `retired_meshes` has its own `retired_meshes_mutex` because apply-step appends race the drain's `processRetired` sweep. Lock order: `retire_mutex` → `retired_meshes_mutex`.

## Chunk streaming (ChunkStreamer + ChunkClipmap)

- **Single owner:** only `Game.streamPass` calls `ChunkStreamer.pass`, and `stream_is_running` keeps passes from overlapping, so the clipmap's cells are plain values. The frame starts a short pass when `completions.pending` is set or `stream_poll_ms` passed. Never make streaming a long-lived task: `Io.Threaded` counts it against the async limit, so it steals a chunk-load worker, and a saturated pool then runs loads inline on the dispatcher. Never read clipmap state from a task or the editor callback. Each pass runs with cancellation blocked, because a canceled pass would drop the completions it took and strand their loads in flight; a pass error goes to `deferred_error`.
- **Reserve before dispatch:** every task's completion slot is reserved (`completions.reserve`) before the task starts, so its `defer push` cannot fail, even during cancel. A dispatched task must push exactly once.
- **Evict before claim:** `recenter` evicts every level's leaving slab under the old centers first, so coverage bubbles through the windows it was counted in, then moves the centers. A window position's parent always lies in the parent window, so `setCoverage` unwraps parent lookups; the streamer fuzz test panics if that breaks.
- **Work scales with the change:** recentering walks the rows of the old window or keep box but only visits `window(old) \ window(new)` and `keep(new) \ keep(old)`; only a settings change (debounced 300 ms) or a teleport touches the whole window. An active chunk evicted past the margin (`lingering_margin`) keeps its mesh in the `detached` set, which has no cells; `unloadDetached` hands it back to its slot if it re-enters the window, and otherwise drops it once an in-window ancestor is active or it is past `detached_reach`. A late load result for a detached position keeps its mesh.

## Entity update scheduler (EntityRegistry)

- **Slots:** `spawn` reserves a timer-slab slot before the cache insert; the slab grows lazily, bounded by the cache, so growth fails only with OutOfMemory before any cache mutation. Every resident entity owns exactly one slot (the tests check `usedSlots() == count()`), and `deinit` walks the slab as the census. A slot's `link` (free, parked, overflow, wheel bucket) and `claim` (idle, in flight, or in flight with a recorded re-arm) are tagged unions, so contradictory flag combinations cannot exist.
- **Timers:** a 1024-bucket × 1ms wheel plus an overflow chain; `drain` detaches bounded batches (≤64 per splice, ≤64 splices) and runs each due entity once. `cascadeOverflowLocked` is skipped until `overflow_next_ns` reaches the horizon.
- **Continuations:** `UpdateContext.reschedule`/`delete` record on the in-flight claim and `settleClaim` applies them after the update returns; a re-arm stamps the current `drain_seq`, so zero delay waits for the next pass. An update error ends the pass (the rest of the batch is re-armed) and propagates: `Canceled` unwinds, any other error is fatal.
- **Eviction:** returns the displaced value under the shard lock; the caller frees its slot and unloads it after release. Freeing an in-flight slot is safe because the victim's claim misses the lookup and no-ops on settle (uuid check).
- **Pinned entities:** an entity the caller must keep resident is held by reference (eviction requires refcount 1) and driven with `updateNow`, never scheduled or deleted — the player runs on the frame lane. The frame thread is the player's only owner, so its fields are plain values: a task gets copies taken on that thread (`Item.UseContext`), and stream passes and load tasks read only the published `Game.player_block`.
- **Deletion:** `markDeleted` never postpones the reap past the 5ms retry window, and the reap check shares the shard lock with the cache removal, so a concurrent `getAndAddRef` lands either before (no reap) or after (miss).
- **Ids:** `Entity.Handle` is a 64-bit random id per spawn; a collision fails the spawn loudly (`error.EntityUuidExists`). Stale-claim rejection only needs the id to change on slot reuse.
- Lock order: `scheduler_mutex` before any cache shard lock.

# Vulkan & Rendering

## vulkan-zig handles and flags

Dispatchable handles (`Instance`, `PhysicalDevice`, `Device`, `Queue`, `CommandBuffer`) are non-null pointers, so "no handle" is `?vk.CommandBuffer = null`; non-dispatchable handles keep `.null_handle`. Flag fields have no `_bit` suffix (`.transfer_dst`, `.@"1"`).

## Frame sync and presentation

- **Per-frame fence wait:** wait for only the current frame's fence, `waitForFences((&self.in_flight_fences[current_frame])[0..1], .true, timeout)`, then `resetFences` on the same slot. Waiting for all fences over-constrains the next frame and can hang after swapchain recreation (new fences start signaled).
- **Persistent `VK_SUBOPTIMAL_KHR`:** some variable-extent platforms keep returning it after a valid recreation. Let the first suboptimal result request recreation and suppress duplicates until a physical-size/configuration change resets the guard. `VK_ERROR_OUT_OF_DATE_KHR` is always handled.

## Validation-layer false positives

- **MangoHud:** its injected `vkCmdBeginRenderPass` loads without a dependency on the app's transition to `PRESENT_SRC_KHR`. Ignore `SYNC-HAZARD-READ-AFTER-WRITE` messages containing `0xe4d96472` and `vkCmdBeginRenderPass`.
- **`deviceWaitIdle` + timeline semaphores:** mixing them confuses the layer into `SYNC-HAZARD-WRITE-RACING-WRITE` on `vkQueueSubmit2`. Ignore messages containing `0x743c6069` in that situation.

## OIT volume term (transparent_frag.frag / composite_frag.frag)

The water volume integrates in a reference frame: each face adds `density * absorption * (bg - frag)` entering and subtracts it exiting, so thickness only survives if entry and exit faces integrate against the same background distance.

- Sky pixels hold cleared depth 0.0, whose linearization `near / depth` is infinite, so a pair would cancel to zero. `sky_dist` (256) substitutes the reference only for those pixels. Never clamp real backgrounds: volumes sit up to ~100,000 blocks away. `sky_dist_max` (2048) clamps sky-referenced distances symmetrically so distant sky pairs cancel cleanly. The surface term's gate uses the unclamped value so water past `sky_dist` keeps its fresnel surface.
- Precision is bounded by f16 quantization (~1/1024 of the write magnitude): finite backgrounds write ~the local segment (correct at any distance); sky-backed volumes are exact to roughly a thousand blocks. Stacked saturated faces can overflow to Inf, so the composite gates scatter on `td_scalar < 65504`.
- Absorption stays position-independent (`1 - volume_color`, no light term), since entry/exit faces sample light at different points. Day/night scatter is applied in the composite via `OitCompositor.volumeScatterLight`.
- Thickness is ray length: multiply by the slant `length(frag_pos) / fragment_depth` (off-axis pixels otherwise undercount by up to ~0.58x).
- `near_plane` must match core.zig's projection near (0.01); the linearization assumes infinite reverse-Z. Known gap: inside water, rays have no entry face, so net optical depth clamps to zero (no underwater tint).

## Matrix layout for GLSL push/params (CSM)

zm matrices are row-vector (`v · M`, translation in the last column of each row). Bit-casting `zm.data` into a GLSL `mat4` is fine for an origin-eye camera view, but a light/projection matrix with a non-origin eye gets a huge projective `w` and is silently wrong. Build light view-projection **directly in GLSL column-major layout** (`w == 1`):

```
flat[i*4+j] = M[i][j];   // column-major GLSL: M[c][r] = flat[c*4+r]
row0: (s.x/r, u.x/r, f.x/fnf, 0)
row1: (s.y/r, u.y/r, f.y/fnf, 0)
row2: (s.z/r, u.z/r, f.z/fnf, 0)
row3: (s·t/r, u·t/r, (f·t - near)/fnf, 1)
```

`s,u,f` = light basis, `r` = box half-extent, `fnf = far - near`, `t = view_pos - center`. Vulkan NDC depth is `[0,1]`, with no OpenGL `z * 0.5 + 0.5`. Verify with a CPU helper `out[i] = sum_j flat[j*4+i]·v[j]` against ground truth (the Csm tests do this). Prefer building these matrices by hand over zm's `lookAtRH`/`orthographicRH`.

# Worldgen & Terrain

## Runevision erosion filter (Terrain.zig + libs/phacelle.zig + libs/erosion.zig)

- **Units (all normalized):** `p` into `erosionFilter` is the noise-grid base coordinate _divided_ by `erosion_scale`. Height input is raw `shaped` (≈[-1,1]). The base field takes the asymmetric envelope `|bounds| * scale`, but deltas must not (it doubles them at the shoreline): both deltas convert with symmetric `max(|min|, |max|) * scale` through `composeErodedHeight`, and amplitudes stay normalized so saved configs keep magnitude. Downhill slope is the negated central-difference gradient of `shaped` at ±one sample spacing.
- **Cell size is a locked ratio:** inside `phacelleNoise` the phase ramps at `cell_scale * TAU` per unit cell, and octave `freq` scales stripe frequency and cell grid together — no per-octave tuning. `cell_scale` is a unitless ratio on `erosion_scale`.
- **Load-bearing order:** each octave steers off the `gully` slope accumulated by the previous one (`State.apply`); `side *= -freq` is the chain rule for the caller's `p * freq` scaling plus the downhill sign flip, applied exactly once.
- **Mask chain:** `mask = powInv(mask, detail) * new_mask` with `powInv(x, p) = x^(1/p)` (`powInv(0)` latches closed, so flats stay uncarved). `smoothStart(t, smoothing)` must return a step for `smoothing <= 0`. Per-octave `new_mask` gates on the wave's slope (`|sin|`).
- **Steepness fade:** the first-octave mask seeds with `1 - (1 - steepness)^2`, so flat ground has exactly zero delta. `fade_slope` is the steepness of a fully open mask; `<= 0` disables the fade. Steepness comes from a wide-stencil average (`fadeSteepness`), or fine-noise flicker strobes the mask.
- **LOD consistency:** effective octaves = `max(1, erosion_octaves -| level)`; octaves stay absolute in world space. The level-1 vs box-filtered level-0 test tolerance is 40% of `filter_strength / (1 - gain) * gully_weight` plus 128 blocks.
- **Hashing:** the reference's `fract` cell jitter loses precision far from origin; `phacelle.zig` uses `fastnoise.hash2D`/`hash2DVec`, exact at ±100,000 blocks.
- **Cost (Debug, Xeon):** base `genTerrainHeight` ≈ 540 µs/chunk, with filter ≈ 6.4 ms/chunk; Phacelle's 16 cells × 4 octaves of transcendentals dominate. Done levers: polynomial `bellWeight`, LOD octave drop, `@Vector(16, f32)` cell loop.
- **Build stability:** gradient accumulators are zero-initialized and use `@mulAdd` so no build mode contracts them differently, and the seeded direction blends toward the assumed slope below the 1e-4 noise floor (`gradient_floor`), because fastnoise fills run `@setFloatMode(.optimized)`. Any FP reassociation in this pipeline changes the terrain; keep operation order when refactoring.

## JitteredGrid placement (Planet generator)

- `getStructure` only finds a structure from positions **at or below** it, and negative cells fail the in-range check silently. Shift the grid by a large positive constant so every used cell index is positive.
- Querying position = `cell` with `scale == box_size` lands on the cell origin, reducing the check to `jitter < scale` — the O(1) "which structure owns this cell" lookup.
- Clamp the structure position inside its cell (`clamp(jitter, radius, box_size - radius)`) so a whole sphere stays in its owning cell and is found from every side.

## Noise

- **`Noise.invert`** negates values at the entry points (`genNoise2D`/`genNoise3D`, `fillGridDispatch`), so every grid fill flips. Domain warp is a displacement, not a value: warp-only uses ignore the toggle, and never invert the warp instead. The field lives on the shared `Noise` struct, so every generator's noise group gets the checkbox; old configs parse via the declaration default.
- **`terrain_noise_balance`** crossfades in `shapedRow` (0 = continental only, 1 = mountain only) before `height_power`. It replaced an additive `(large + b*small)/(1+b)` blend, so an old value `b` maps to `b/(1+b)`. Surface detail, erosion, and caves apply at any balance.

# Config, Persistence, Plugins & UI

## Config compat

`std.zon.parse` only tolerates missing fields that carry a **declaration default**, so every `Params` field keeps one (`.default` is just `Params{}`) or old saved configs break. Superseded fields stay declared with `.skip = true` in `field_specs` (`erosion_strength`, `erosion_fade_altitude`). `loadConfig` returns `error.InvalidConfig` instead of falling back, so a broken config fails loudly without being overwritten.

## Clearing RocksDB chunk storage

Clear persisted chunks through the open database: a `WriteBatch` range tombstone per chunk column family, then flush both families. Stop background saves and finish the final save first; never remove the database directory while RocksDB owns it.

## Generator shared libraries

Generators are shared libraries loaded with `std.DynLib`. The exe embeds each built `.so` (`addAnonymousImport` + `@embedFile`) and writes it into `generators/` at startup.

- **C ABI:** `export`/`@export` need a machine calling convention and cannot take auto-layout structs by value (`Allocator`, `Io`, slices, error unions). Export one `extern struct` vtable of function pointers (`@export(&vtable, .{ .name = "..." })`); pointers cross as data and host and plugins share one compiler. Return nullable pointers (`?*T`, null = failure) instead of error unions.
- **Module scope:** a module's import scope is its root file's directory, so one shared root `src/generator_root.zig` is compiled once per generator, selected by a `generator_select` options module. Add a generator with a `.kind` arm in `build.zig`'s `GeneratorKind` plus an `@import` arm in `generator_root.zig`.
- **Config metadata:** `Spec` presentation fields (`label`, `description`) are borrowed from the loaded library, so keep it loaded while its config tree is used; keys, values, and choice entries are owned by the config allocator. Changing shared config-tree layouts bumps `generator_api.ApiVersion` (minor for additions, major for breaks) and rebuilds every plugin.

## dvui

- `dvui.Window.end` calls `backend.setCursor` and `backend.textInputRect` every frame (`manage_backend`); never call them from the main loop.
- Widget ids collide when one `@src()` line runs for several params: pass `.id_extra`. Derive config widget ids from the stable parameter path, not traversal order.
- `dvui.dropdown` and other `*T` choice widgets write the selection in place during the draw call, so capture `const previous = my_choice;` before drawing and compare against `previous`.
