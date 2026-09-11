---
name: prune
description: Scan the codebase for unused or dead sections, then review candidates one at a time with the user and fix each accepted item (inline when trivial, otherwise in a fire-and-forget subagent). Use when asked to find unused code, run a dead code scan, prune, or find what can be deleted.
---

# Prune

Find unused code, confirm reachability, then delete it or wire it up with the user's approval. Correctness first: a false "unused" report that deletes live code is worse than missing a candidate. Never `git stash`, `git commit`, or `git checkout`.

## Scan Protocol

### File level

A `.zig` file is unreachable iff no other `.zig` file `@import`s it and neither `build.zig` nor `src/generator_root.zig` references it. `@import` is the only way to name a decl in Zig, so the import closure from every root is a complete reachability test at file granularity.

Roots:

- `src/main.zig` — the exe root, and the test root module (`build.zig` builds `b.addTest` from the `root_module` whose `root_source_file` is `src/main.zig`).
- `src/generator_root.zig` — the generator shared-library root. `build.zig`'s `GeneratorKind` / `generator_sources` compiles it once per plugin (`terrain`, `voxelgame`, `planet`, `sponge`, `fractal`), so each generator is a second root.

Enumerate `.zig` files with `glob`, then grep each file's name across `.zig` sources. A file with zero importers and no `build.zig` / `generator_root.zig` mention is a candidate.

### Symbol level

For each candidate file or decl, read the importers' bodies, not just their declaration lists. `pub const X = @import("Y.zig");` in `main.zig` reaches `Y`; whether a specific decl inside `Y` is used requires reading the bodies that touch `X`. Record which files were inspected and what each check ruled out. State residual uncertainty explicitly ("read A, B, C; did not inspect D because …") rather than claiming certainty.

The cheap way to enumerate candidates: extract every `fn` / `const` declaration name per file, count each name's occurrences across the whole corpus (add `build.zig` and every vendored `zig-pkg` source — backend interfaces such as dvui's and Tracy's root declarations live there), and report names whose only occurrence is the definition. Then read each hit's context before believing it. The same sweep with struct-field patterns finds never-read fields; expect more false positives there.

## False-Positive Traps

Check every one before reporting a candidate. Each has produced a real false positive in this repo.

- **`refAllDecls`:** `test { std.testing.refAllDecls(@This()); }` compiles every decl; it does not use them. A decl referenced only there is still unused.
- **Exports and the plugin ABI:** `pub export` / `@export`, and the `generator_api_vtable` path (`comptime { _ = Generator.generator_api_vtable; }` in `generator_root.zig`). Exported symbols are reached by name at runtime through the vtable, invisible to import analysis; the vtable entries are the plugin ABI.
- **Comptime reflection:** `@typeInfo`, `std.meta.fields`, `inline for` over fields (`generator_api.fromTree` / `fromStruct` walk `std.meta.fields(T)` driven by `field_specs`). Fields and decls reached only this way are used.
- **Config / zon-parsed fields:** `field_specs` entries, `Config.zon`, `config/generator.zon`, `materials.zon`, `Trees/*.zon`, and `std.zon.parse`. A field absent from code but present in a saved `.zon` is load-bearing for config compat.
- **GPU layouts and offset asserts:** `ShadowParams`, `SkyParams`, `PushConstants`, `CullCount`, `Mesher.Face`, std430/std140 packing, the `//!`-style bit layouts in `shadow/face_decode.glsl`, and the `comptime { if (@offsetOf(...) != ...) @compileError(...); }` blocks. A field can exist solely to hold bits or an offset the shader reads — `Mesher.Face.x_length`/`y_length` are always zero in Zig yet are decoded by the vertex and shadow shaders as "extent 1", so they are layout, not dead code.
- **C-ABI / `extern struct`:** types crossing the generator boundary (`generator_api.Spec`, `ConfigTree`, vtable structs) are ABI, not code.
- **Third-party root declarations:** the Tracy package reads `@hasDecl(root, "tracy_impl")` and `root.tracy_options` from `src/main.zig`; deleting those silently disables Tracy. The dvui package names its backend methods by comptime field lookup, so every method in `src/dvui_backend_wio.zig` it names is live even with zero in-repo callers.
- **Re-exports in `src/main.zig`:** e.g. `pub const Chunk = @import("world/Chunk.zig");`. The test root module is `main.zig`, so deleting a re-export can silently drop a file's tests from `zig build test` while `zig build` still passes. Trace re-exports to test reachability before removing.

## One-at-a-Time Review

Present exactly one candidate per turn. Never batch candidates into one question — the answer on one may change the next.

Each candidate report contains:

- **Kind** — unused file / unused decl / stale duplicate / superseded path / unwired feature.
- **Location** — `path:line`.
- **Size** — line or byte count.
- **Evidence** — the grep and read results that support the candidate.
- **Reachability check** — which roots and importer bodies were inspected, and what was not.
- **Deletion risk** — what breaks if the candidate is actually live (which false-positive trap applies).

Then ask with the question tool, offering 2–3 concrete options: **delete**, **keep**, **wire up**. Do not ask whether to continue; the next candidate follows the answer.

## Fix Execution

Do trivial fixes inline. A small, mechanical, single-file edit — deleting an unreferenced decl, alias, or field, dropping a stale import, converting an obviously unused helper into a test in the shape of an existing one — is done by the reviewer itself with the edit tool, gates included, in the same turn. Spawning a subagent for it wastes a round trip and a context window.

Spawn a subagent when the accepted item needs investigation, cross-file work, or runtime verification: wiring an orphaned feature into the build and plugin registration, routing many call sites through a wrapper, rewriting a module's API surface, or any change whose acceptance requires running the game.

Each subagent brief is self-contained (the subagent has no conversation history):

- **Target** — exact files and symbols.
- **Change** — what to add or remove, and the surrounding pattern to follow.
- **Acceptance** — the observable result; no project-wide commands.

Never batch multiple accepted items into one subagent.

### Shared registration files

`build.zig`, `src/generator_root.zig`, and `src/main.zig` are registration points that several subagents may touch at once. Require:

- one small additive edit per subagent (a single entry, not a rewrite of the surrounding list);
- a re-read of the file after writing, confirming the entry survived any sibling write;
- a final integration check by the main thread across every edited registration file.

## Verification Gates

Per fix:

1. `zig fmt .`
2. `zig build` — exit 0.
3. Play test when the change is user-visible: `export VK_LOADER_LAYERS_ENABLE="*validation" && zig build run -Dtest_play=5`.

Only one game instance may run at a time: every instance rewrites `./generators/` at startup, and a concurrent `dlopen` of a half-written plugin segfaults or logs `failed to load generator ...: FileNotFound`. Run play tests with exclusive access (or from a private `cwd`), and retry once if plugin loading fails.

Never `git stash` or `git commit`. Revert mistakes with the edit tool.

## Delete vs Wire Up

- **Wire up** a complete, tested feature: register it in the build (`GeneratorKind` + `generator_sources` in `build.zig`, an `@import` arm in `generator_root.zig`) or the plugin vtable. An unwired-but-finished feature is a bug, not dead code.
- **Delete** a stale duplicate or an already-superseded path: a second implementation the build no longer selects, or a helper replaced by an existing one.
- **Route through existing wrappers** when a helper is unused only because call sites inline it: `Chunk` exposes `addAndLockShared` / `releaseAndUnlockShared` next to raw `ref_count` + `encoding_lock` sequences, and the accepted fix is to make the call sites use them.

Report per accepted item: deleted or wired, with the gate results.
