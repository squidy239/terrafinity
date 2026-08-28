---
name: profile-tracy
description: Build with Tracy instrumentation (-Dtracy) and Capture/inspect a profiling session. Use when asked to profile, trace, or measure frame times, zones, or performance of the game.
---

# Profile with Tracy

Build the game as a Tracy client, run a session, and inspect it. The Tracy tools are Windows binaries in `~/Downloads` and run under wine.

## Build

```
zig build -Dtracy
```

- `ReleaseFast` is recommended but not required: Debug timing is dominated by safety checks and missing inlining, so numbers do not represent real frame costs. `-Dtracy` alone leaves optimize at the default (Debug).
- The client listens on TCP 127.0.0.1:8086 (Tracy default). `on_demand = true` in src/main.zig means the game runs normally with no profiler overhead until a tool attaches.
- Existing zones cover the frame loop (`frame`, `frameMark` in src/Game.zig), meshing (`GenMeshAndAdd`, `addChunk`, `addMesh`), chunk generation (`mark_subtree*`, generator zones), Vulkan submit/present (`submitFrame`, `queueSubmit2`, `present`), entity updates, UI draw.

## Run

Interactive session:

```
zig build run -Dtracy -Doptimize=ReleaseFast
```

Unattended fixed-length session:

```
zig build run -Dtracy -Doptimize=ReleaseFast -Dtest_play=10
```

`-Dtest_play=<seconds>` loads straight into a world (skipping the menu) and exits cleanly after that many seconds.

Never set `VK_LOADER_LAYERS_ENABLE="*validation"` for profiling runs; validation layers massively distort timings. They are for correctness tests only.

Long-running processes (the game, the wine GUI) must be launched via hub start or an async bash call, never as blocking foreground commands.

### Debug-mode caveat

This project explicitly enables `VK_LAYER_KHRONOS_validation` in `VulkanContext.init` for Debug builds, so merely omitting `VK_LOADER_LAYERS_ENABLE` does not produce an unvalidated run. For a Debug Tracy smoke test, disable the loader layer explicitly and verify the game log does not contain `Enabling Vulkan validation layer`:

```
VK_LOADER_LAYERS_DISABLE=VK_LAYER_KHRONOS_validation zig build run -Dtracy -Doptimize=Debug -Dtest_play=10
```

If the loader does not support `VK_LOADER_LAYERS_DISABLE`, use `-Doptimize=ReleaseFast` for performance measurements or add a project-level validation toggle before profiling. Never compare Debug timings with ReleaseFast timings as if they were equivalent.

## Capture

GUI viewer:

```
wine ~/Downloads/tracy-profiler.exe
```

Start it while the game is running, then Connect and pick the client at 127.0.0.1:8086.

Headless capture (for scripted analysis):

```
wine ~/Downloads/tracy-capture.exe -o /tmp/terrafinity.tracy -f -s <seconds>
```

Capture waits for the client to appear, so when scripting start capture first, then launch the game. With `-Dtest_play=N`, budget roughly N+5 seconds of capture so the tail of the session is not cut off. When the game exits, the capture finalizes on its own. Confirm that the `.tracy` file exists and that the capture log reports `Saving trace... done!` before exporting it. An `Instrumentation failure` is fatal to the capture: Tracy may save a partial trace and terminate collection while the game continues running. Do not use a trace after that message for timing conclusions; preserve the log and investigate allocator/lifetime instrumentation before trusting any statistics.

For a detached smoke test, keep separate logs and start capture before the client:

```
nohup wine ~/Downloads/tracy-capture.exe -o /tmp/terrafinity.tracy -f -s 16 >/tmp/terrafinity-tracy-capture.log 2>&1 &
nohup env VK_LOADER_LAYERS_DISABLE=VK_LAYER_KHRONOS_validation zig build run -Dtracy -Doptimize=Debug -Dtest_play=10 >/tmp/terrafinity-tracy-game.log 2>&1 &
```

Extract zone statistics without opening the GUI:

```
wine ~/Downloads/tracy-csvexport.exe [-f <zone name>] [-e] /tmp/terrafinity.tracy
```

Useful flags: `-f <zone name>` filters by zone name, `-e` reports self time instead of total time, `-u` reports every individual CPU zone event instead of aggregated statistics.

## Reading results

- Compare mean/median against the frame budget before drawing conclusions; single-frame spikes during startup chunk generation are normal.
- Prefer self time (`-e`) when ranking hot zones; total time double-counts nested zones.
- Lock waits show up as long zones like `addMesh_lock_batch`, `submitBatch_lock`, or `getPlayerPos`; those indicate contention, not compute cost.
- Exclude startup, swapchain recreation, and world-loading spikes when estimating steady-state frame cost. Use `-e` first, then inspect total time for parent zones only after accounting for nested-zone double counting.
- Record the build mode, validation-layer state, Tracy capture duration, and game log alongside each trace. Reject captures with `Instrumentation failure`, especially if the reported time span is shorter than the requested session. A trace captured with Debug safety checks or Vulkan validation is useful for finding behavior and contention, but not for production frame-budget conclusions.
