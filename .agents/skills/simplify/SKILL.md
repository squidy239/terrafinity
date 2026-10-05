---
name: simplify
description: Simplify code while maintaining all functionality. Invoked with a target directory and an optional time budget (e.g. `src/world 2h`); with a budget it keeps simplifying until the time is up, without one it runs until the target is fully simplified. Covers structural hygiene, control flow simplification, and state and mutation minimization. Use when asked to simplify, refactor, or clean up code.
---

# Simplify

Simplify code while preserving all functionality. The priority order is:

1. **Correctness** — never change observable behavior
2. **Readability** — simpler must mean easier to understand, not terser for its own sake
3. **Simplicity** — fewer branches, shallower nesting, smaller functions
4. **Performance** — do not sacrifice speed for simplicity

**This is not a review skill.** Do not report violations, do not flag naming issues, do not check style. Actively rewrite code to be simpler. If a simplification principle can be applied, apply it directly — don't just note it.

## Invocation

`simplify <dir> [time]`

- `<dir>` — the target directory (or file). Every code file under it is in scope, not just Zig.
- `[time]` — optional budget such as `45m`, `2h`, or `1h30m`.

Record the start with `date +%s` and, when a budget is given, the deadline. Check the clock before starting each round.

- **With a time budget:** keep running rounds until the deadline. Reserve the last ~10% of the budget (at least 10 minutes) for the final verification, and do not start a round that the previous round's duration says cannot finish before that reserve. When every slice reports DONE before the deadline, keep going with deeper rounds (see Round Types) rather than stopping. The only early exit is a full deeper round over every slice that yields zero net token reduction; report that the target is exhausted and how much time was left.
- **Without a time budget:** run rounds until every slice's adversarial check reports DONE. There is no round cap. A slice that goes two consecutive rounds without lowering its net token count while still drawing findings is marked stuck, dropped from later rounds, and listed in the final report with its open findings — those need human judgment.

## Work Partitioning

Partition the target into slices once, before the first round, and keep them stable across rounds:

- **Group by independent system:** files that import each other or form one subsystem (a renderer pass, the entity registry, one generator, a lib) belong together. Use the directory structure and `@import` graph to find the boundaries.
- **Size by lines:** aim for roughly 1000 lines per slice (`wc -l`). Merge small related files into one slice; never split a file across slices. A single file over ~1000 lines is its own slice.
- **One sub-agent per slice per round.** Slices are disjoint, so sub-agents never edit the same file. Follow the `fanout-orchestrate` skill for running them in parallel.
- **Slice boundaries are API boundaries:** a sub-agent may change a `pub` declaration's signature only when every caller is inside its own slice (grep the whole repo, including `build.zig`, to confirm). Otherwise it keeps the signature and simplifies behind it.

## Simplification Principles

Include these principles verbatim in every simplify sub-agent prompt and in every adversarial checker prompt. Every change must preserve observable behavior.

### 1. Structural Hygiene

**Single Responsibility:** Split functions that do more than one thing. If a function's name or description contains conjunctions ("and", "or"), it is likely doing too much.

**Visual Chunking:** If a function requires visual dividers or heavy blank-line padding to separate different phases of internal logic, break it into smaller, private helper functions.

**Function Length:** If a function body cannot fit comfortably on one screen without scrolling (~60 lines), refactor it.

**Parameter Limits:** Group many related arguments into a dedicated context struct. Prefer `processUserData(context: UserContext)` over `processUserData(name: []const u8, age: u8, id: u32, is_active: bool)`.

### 2. Control Flow

**Guard Clauses and Flat Hierarchy:** Replace deeply nested conditionals with early returns and guard clauses. The primary "happy path" should run straight down the left side at the lowest possible indentation level.

### 3. State and Mutation

**Proximity of State:** Move variable declarations to the deepest scope where they are used, as close to their first usage as possible.

**Constants Over Magic Values:** Replace magic numbers and hardcoded string literals with named constants.

**Undefined Over Dummy Values:** When a value is always overwritten before any read, declare it `= undefined`, never a dummy zero or random filler. `undefined` signifies "no defined value" and lets safety-checked builds catch a missed write; a plausible placeholder hides that bug.

### 4. Preserve Load-Bearing Differences

Do not extract a shared helper just because two blocks look similar. When the difference is load-bearing for correctness, keeping them separate is the simpler, safer form; a parameterized helper that unifies them hides the invariant and can silently apply one site's rule to the other. In `Mesher.zig`, the uniform `addSideFaces` and the grid `addGridFaces` both greedily merge lane runs, but `addSideFaces` must never merge water (per-face shader displacement), so it carries a `block != water` condition the grid path does not. Extracting one helper across both would tempt a future caller to drop that condition. Pattern: if two blocks differ by a condition required for correctness at one site, leave them apart rather than add a parameter.

### 5. Prefer the Standard Library

Replace hand-written code with a `std` function or type when one does the same job: searching and comparing (`std.mem.find*`, `eql`, `startsWith`), sorting (`std.sort`), formatting (`std.mem.print`, `allocator.print`), containers (`std.ArrayList`, hash maps, `std.enums.EnumArray`/`EnumSet`/`EnumMap`, `std.bit_set`), allocators (`std.heap.BufferFirstAllocator`, `ArenaAllocator`), math (`std.math.clamp`, `cast`, `divCeil`), and local copies of std types. Check the signature in the installed toolchain (`~/.zvm/0.17.0/lib/std`) before using it, never from memory. Replace only when the std version has the same behavior on every input the code sees, including edge cases, error sets, and allocation. Keep the hand-written version when it is measurably faster on a hot path or carries a load-bearing difference (principle 4), and leave a one-line comment saying why.

### 6. Names and Comments in ASD-STE100

Apply the `asd-ste100` skill (`.agents/skills/asd-ste100/SKILL.md`) to every identifier and comment the slice touches; use strict mode for doc comments, log strings, and error messages, and STE-flavored mode for other comments.

- **One word, one meaning:** one concept gets one name across the slice. Rename synonyms (`chunk_pos`/`chunk_coord`/`cpos` for the same thing) to the single clearest name. Names stay inside the AGENTS.md casing rules.
- **Names say what the thing is:** no vague nouns (`data`, `info`, `handle`, `manager`) where a specific noun exists, and no abbreviations a reader must decode.
- **Comments:** active voice, simple tenses, short sentences, no hedges or marketing words. Delete comments that restate the code; keep and sharpen the ones that give the reason.
- `.agents/skills/asd-ste100/scripts/ste-lint.py <file>` gives a mechanical first pass over comment text.
- Renaming a `pub` declaration follows the slice-boundary rule; when callers sit outside the slice, keep the name.

## Measuring Complexity

`zig fmt --check --complexity <files or dirs>` prints `tokens=N nodes=M` (AST nodes) per file plus a total, on stderr as `info:` lines, without modifying files (plain `zig fmt --complexity` also reformats in place). Counts are per file and ignore formatting and line wrapping, so they cannot be gamed by joining lines. Net token count is the size metric; node count is informational.

- Record every target file's token count before the first round.
- A slice's round must lower its net token count. If it does not, revert or redo that slice's edits. Line count and node count are not requirements.
- Exception: renames and comment rewrites (principle 6) do not change token counts, because an identifier is one token and comments are not tokens. A round whose only edits are names and comments passes when its token count does not rise.
- Lower counts are necessary, not sufficient: readability and the load-bearing-differences rule still win over a smaller number.

## Round Types

- **Standard round:** the simplify sub-agent applies the principles to its slice, prioritizing any findings the slice's previous adversarial check reported.
- **Deeper round** (time budget only, after every slice has reported DONE): give each sub-agent a fresh angle on its slice — duplication across the slice's files, helpers and wrappers that no longer earn their keep, types or config surface that can be narrowed, and the slice's highest-token functions. Run a fresh adversarial check afterwards as usual.

## Round Loop

### Step 1: Simplify

Spawn one sub-agent per active slice. Each sub-agent's prompt must include:

- The slice's file paths and the files' current token counts
- The complete Simplification Principles above (sections 1–6 verbatim)
- The slice's open findings from its last adversarial check, if any
- The round type and, for a deeper round, its angle
- The rule that simplifications MUST lower the slice's net token count, measured with `zig fmt --check --complexity <files>` before and after, and that this is the only hard size requirement (name- and comment-only edits must just not raise it)
- The slice-boundary rule for `pub` signatures
- The instruction: "Edit these files to be simpler using the principles. Use precise, targeted edits with the edit tool. Return a brief summary of what you changed and the token counts before and after."
- Skip build gates and tests; the orchestrator verifies after the round.

### Step 2: Format and Build

Run `zig fmt .`, then `zig build`. If the build fails, fix the errors (or revert the offending slice's edits) and rebuild.

### Step 3: Tests

Run the `verify-change` skill's test gate (filtered tests for touched areas; full suite where the environment supports it — never the crashing headless full suite as proof). Fix or revert any regression before continuing.

### Step 4: Play Test

Only when the round touched a user-visible path: `export VK_LOADER_LAYERS_ENABLE="*validation" && zig build run -Dtest_play=5`. Fix or revert any failure.

### Step 5: Measure

Run `zig fmt --check --complexity` on each slice. Revert or redo any slice whose net token count did not drop (or rose, for a name- and comment-only round), and log each slice's count after the round.

### Step 6: Adversarial Check

Spawn one adversarial sub-agent per slice changed this round, in parallel. Each prompt must include the slice's full file contents and the complete Simplification Principles (sections 1–6 verbatim), with these instructions:

> You are an adversarial checker. Your job is to argue that the simplified code can be simplified further. Review the provided files against the simplification principles included below.
>
> If you find ANY remaining opportunity, respond with a table:
>
> | File | Line or function | Principle violated | Suggested change |
> |------|-----------------|--------------------|-------------------|
> | ...  | ...              | ...                 | ...                |
>
> If you cannot find any simplification that wouldn't harm readability, performance, or correctness, respond with exactly "DONE" and nothing else.

A slice with findings stays active for the next round; a slice that reports DONE is finished (until a deeper round, when a time budget remains).

### Step 7: Continue or Finish

Check the clock and the slice states against the Invocation rules, then either start the next round or move to Final Verification.

## Final Verification

Run the `verify-change` skill gates:

- `zig fmt .`
- `zig build`
- the test gate (filtered tests for touched areas; full suite where the environment supports it)
- the play test only when a user-visible path changed
- `zig fmt --check --complexity <dir>`, compared against the counts recorded before the first round

Report:

- the elapsed time, and the remaining budget if one was given
- the number of rounds run and the slices used
- the token totals before → after, overall and per slice
- the stuck slices, with their open findings
