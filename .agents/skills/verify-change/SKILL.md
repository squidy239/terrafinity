---
name: verify-change
description: Which gates to run at a change checkpoint (format, build, filtered vs full tests, play test, Tracy). Use to pick the cheapest sufficient verification without gating every micro-edit.
---

# Verify Change

Run the cheapest gates that prove the change. Full commands live in AGENTS.md `## Commands`; this skill picks which ones apply.

Run them at a checkpoint, not after every micro-edit: batch related edits and verify once when a feature or fix is complete, or before reporting back on a group of edits. Re-running the gates per tiny edit wastes time and budget.

## Always (at a checkpoint)

1. `zig fmt .`
2. `zig build` — exit 0.

## Tests

- Touched area first: `zig build test -Dtest_filter="substring"` (substring over the fully-qualified `module.file.test.name`; name tests so they are filterable — unnamed `test {}` blocks always run and cannot be filtered).
- Full suite where the environment supports it: `zig build test --summary all`. Headless environments hit the pre-existing wio/wayland crash — there, `zig build` plus filtered tests for the touched areas stand in for the suite; never treat the headless crash as your regression without evidence.
- Reachability gates every build: `zig build` and `zig build test` compile only the import closure of a root (`main.zig`, `generator_root.zig`, `build.zig`). An unreferenced `.zig` file — kept but orphaned, or new and not yet wired in — is never compiled, so a syntax error or stale decl passes all gates and its tests stay invisible to `-Dtest_filter`. `zig ast-check <file>` catches source-only errors; reference it from a reachable root for a full type check.
- Bare `zig test` can exit 1 on success (toolchain quirk): all-OK output means pass; `error:`, `compile test ... N errors`, or failed build steps mean real failure.

## Play test (user-visible changes only)

`export VK_LOADER_LAYERS_ENABLE="*validation" && zig build run -Dtest_play=5` (5–10 s). Run it when the change can show on screen or in behavior: rendering, shaders, worldgen output, gameplay, UI, generators, persistence. Skip it for docs/comments/skills/`ideas.md`-only changes — nothing executes.

- One game instance at a time: every startup rewrites `./generators/` and a concurrent `dlopen` of a half-written plugin segfaults or logs `failed to load generator ...: FileNotFound`. Use exclusive access (or a private `cwd`); retry once on plugin-load failure before believing it.

## Performance changes

Never profile with validation layers (they distort timings; correctness runs only). See the `profile-tracy` skill: `-Dtracy`, ReleaseFast preferred, never compare Debug numbers with ReleaseFast numbers.

## Non-code changes

Skills, `AGENTS.md`, `ideas.md`: re-read the edited file and confirm the new instruction is actionable without extra context. No build, no tests.
