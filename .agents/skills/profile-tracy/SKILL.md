---
name: profile-tracy
description: Build with Tracy instrumentation (-Dtracy -Doptimize=ReleaseFast) and capture/inspect a profiling session. Use when asked to profile, trace, or measure frame times, zones, or performance of the game.
---

# Profile with Tracy

Build the game as a Tracy client, run a session, and inspect it. The Tracy tools are Windows binaries in `~/Downloads` and run under wine.

## Build

```
zig build -Dtracy -Doptimize=ReleaseFast
```

- `ReleaseFast` is mandatory: Debug timing is dominated by safety checks and missing inlining, so numbers do not represent real frame costs. `-Dtracy` alone leaves optimize at the default (Debug).
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

Capture waits for the client to appear, so when scripting start capture first, then launch the game. With `-Dtest_play=N`, budget roughly N+5 seconds of capture so the tail of the session is not cut off. When the game exits, the capture finalizes on its own.

Extract zone statistics without opening the GUI:

```
wine ~/Downloads/tracy-csvexport.exe [-f <zone name>] [-e] /tmp/terrafinity.tracy
```

Useful flags: `-f <zone name>` filters by zone name, `-e` reports self time instead of total time, `-u` reports every individual CPU zone event instead of aggregated statistics.

## Reading results

- Compare mean/median against the frame budget before drawing conclusions; single-frame spikes during startup chunk generation are normal.
- Prefer self time (`-e`) when ranking hot zones; total time double-counts nested zones.
- Lock waits show up as long zones like `addMesh_lock_batch`, `submitBatch_lock`, or `getPlayerPos`; those indicate contention, not compute cost.
