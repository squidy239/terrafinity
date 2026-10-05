---
name: concurrency-io
description: Async tasks, locks, and upload/drain protocols (std.Io futures, bucket locks, admission mutex, drain-record vs publish-apply split, lock orders). Use when touching background tasks, staging/upload paths, the entity registry, or any code taking std.Io or a mutex.
---

# Concurrency & Io

A wrong order or a held lock here deadlocks or races; every rule below cost a real debugging session. AGENTS.md `# Zig Toolchain` (std.Io guide) and `# Concurrency` are the source of truth — this skill is the pre-flight checklist.

## Futures and cancellation

- `io.concurrent` (fallible) / `io.async` (infallible); `future.await(io)` retrieves, `future.cancel(io)` cancels. Defer-cancel immediately after creating a task so cleanup runs.
- Never block the frame on a running background pass. The drain pattern is poll-and-reap: if a pass is running, skip; else `await` the finished future, then re-dispatch. `error.Canceled` is a normal teardown signal, not a bug.
- `Group` for fan-out of functions, `Batch` for batched operations (e.g. file reads). Teardown cancels + awaits futures before draining queues.

## Locks

- Mutexes suspend via the runtime: `lock(io)`, `tryLock()` for non-blocking probes, `unlock(io)`.
- `ConcurrentHashMap`: `get` releases the shard lock before returning — never read-modify-write through it. Compound sequences use `getBucket(key)` plus explicit `bucket.lock`, one bucket at a time, never nested.
- Fixed lock orders, never reversed: `retire_mutex` → `retired_meshes_mutex`; `scheduler_mutex` → cache shard lock.

## Upload admission (MeshUploader)

- `reserveUpload` acquires everything (command pool, both staging slices via `StagingRing.allocPair`, both face regions) atomically under `admission_mutex`. Any thread holding upload resources past that point is fully provisioned and non-blocking to `submitBatch`.
- Never add acquisition after `reserveUpload` in the `addMesh` path. Hold-and-wait reintroduces the deadlock: the staging ring retires FIFO and stalls at the first unbound entry, so a slice held by a blocked thread wedges the ring permanently.

## Drain-record vs publish-apply split

Before editing `ChunkRenderer.zig`'s retire/publish path, read AGENTS.md `# Concurrency, Vulkan & GPU` → **"Async drain vs. the candidate buffer's GPU-idle window"** and keep this checklist true:

- [ ] Background drains only _record_ `Publication` ops under `retire_mutex`; the frame thread applies them in `publishPending`.
- [ ] `retire_mutex` is never held across the apply — swap the whole list out under the lock, apply lock-free. Stealing a slice is a memory-safety bug (`clearRetainingCapacity` keeps the buffer; the drain task's next appends overwrite it mid-iteration).
- [ ] `publishPending` touches `persistent.mapped` only inside the GPU-idle window `beginFrame`'s timeline throttle proves (between `beginFrame` and the first recorded cull). A background task cannot self-gate this.
- [ ] Lock order `retire_mutex` → `retired_meshes_mutex`, never reversed; `retired_meshes` keeps its own mutex because its appends race the drain sweep.
- [ ] Any apply that mutates both `persistent` (map) and a list reserves all capacity first, then mutates infallibly (`ensureUnusedCapacity` → `...AssumeCapacity`), so a mid-op OOM cannot leave half-updated state.

## Verification

- `zig build` plus `-Dtest_filter` for the touched area; the concurrent fuzz pattern in AGENTS.md (producer-plans/workers-execute, `MemoryDependency` + toggling `Run`, never-reuse bump allocator) for new concurrent paths.
- Contention shows up as long Tracy zones (`*_lock*`, `getPlayerPos`) — rank by self time (`-e`), not total. See the `profile-tracy` skill.
- Gates per the `verify-change` skill; play-test when the path is user-visible.
