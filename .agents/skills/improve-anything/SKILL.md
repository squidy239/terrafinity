---
name: improve-anything
description: Pick and execute one open-ended codebase improvement. Covers simplifying for AGENTS.md compliance, benchmarked optimization, minimal bug fixes, agent tooling upgrades, online research into ideas.md, and triaging ideas.md by benefit-to-effort ratio. Use when asked to improve anything, find something to work on, or do general improvement.
---

# Improve Anything

## Pick a Mode

If the user names a mode, do that. Otherwise scout briefly (a few greps/reads, no deep dives) and pick the mode with the clearest evidence of value. Prefer a small finished win over an ambitious start. Do not repeat the mode of the immediately previous run if another mode has a credible candidate.
Never `git stash`, `git commit`, or `git checkout`. Revert mistakes with the edit tool, never with git.

1. **simplify** — one overcomplex spot brought into AGENTS.md compliance.
2. **optimize** — one hotspot sped up, proven by a benchmark.
3. **debug** — one real bug fixed as simply as possible.
4. **tooling** — one upgrade to agent skills, AGENTS.md, or this skill.
5. **research** — one online investigation appended to ideas.md.
6. **triage** — ideas.md sorted and pruned by benefit-to-effort ratio.
7. **regressions** — scan recent commits for line-count/complexity regressions and minimize them.

## Mode Procedures

### 1. Simplify

Walk code sequentially until you find code that is overcomplex or violates AGENTS.md. Fix one spot: extract a helper, flatten nesting with guard clauses, narrow variable scope, or remove dead code. Follow the `simplify` and `style-review` skills for the actual rewrite discipline. Verify with `zig fmt .`, `zig build`, and `zig build run -Dtest_play=5` with validation layers enabled per AGENTS.md.

### 2. Optimize

Find one hotspot (profiler, frame-time observation, or obvious algorithmic waste). Write a small throwaway benchmark first and record the before time. Make the change, record the after time, keep it only if it is faster. Never trade correctness for speed. Verify with `zig build` and the throwaway benchmark; delete the benchmark before finishing unless it defends a genuinely uncertain edge case per AGENTS.md test policy.

### 3. Debug

Find one real bug (crash, validation error, wrong behavior). Reproduce it first, fix it in the source at the simplest layer, then confirm the reproduction no longer triggers. Keep a regression test only where a plausible bug would fail it; otherwise use a throwaway script and report it.

### 4. Tooling

Make one improvement to `.agents/skills/`, `AGENTS.md`, or this skill: something learned that would have saved time this session. Keep AGENTS.md uncrowded; one sharp section beats three vague ones. Verify by re-reading the edited file and confirming the new instruction is actionable without extra context.

### 5. Research

Pick one open question (optimization, algorithm, Vulkan pattern). Research it online, preferring primary sources, and append one entry to `ideas.md`: what it is, why it fits this project, and links. Do not implement it; do not reorder the file. Verify the entry is a few lines, not an essay.

### 6. Triage

Read all of `ideas.md`, merge duplicates, delete what is done or no longer applicable, and sort the rest by benefit-to-easiness ratio (highest first). Keep each entry to a line or two. Verify the file reads top-down from most to least worthwhile.

### 7. Regressions

Diff recent commits against their parents for added lines and complexity (nesting, helpers, config surface). For each regression: delete or narrow it, keeping behavior identical; final net line count must be neutral or negative — bank deletions first if fixes add lines. Verify with `zig fmt .`, `zig build`, and scoped tests.

## Rules

- One mode per run. State the chosen mode and why in one sentence at the start.
- Never `git stash`, `git commit`, or `git checkout`.
- End with what changed, the evidence (build/test/benchmark output or entry added), and the best candidate for the next run.
