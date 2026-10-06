---
name: simplify
description: Bring code to the best possible quality while keeping all functionality - simplify it and make it follow every AGENTS.md guideline (naming, comments, toolchain facts, footguns, project patterns, test conventions). Invoke on the files you just wrote, or on a directory, with an optional time budget (e.g. `src/world 2h`); without a budget it runs until the target is fully simplified and guideline-clean. Use after writing code, and when asked to simplify, refactor, clean up, review style, or check code against the guidelines.
---

# Simplify

Bring code to the best possible quality while preserving all functionality: simpler, and compliant with every AGENTS.md guideline. The priority order is:

1. **Correctness** — never change observable behavior
2. **Guideline compliance** — every rule in AGENTS.md (principle 8)
3. **Readability** — simpler must mean easier to understand, not terser for its own sake
4. **Simplicity** — fewer branches, shallower nesting, smaller functions
5. **Performance** — do not sacrifice speed for simplicity

**Fix, do not report.** When a principle or a guideline applies, rewrite the code; never just note it. The only findings that go into the report unfixed are behavior-changing bugs (see below), cross-slice renames, and items that need human judgment.

**Bugs found along the way.** Simplifying often exposes a bug, usually through a name that does not match its value. If the bug only affects diagnostic output that no program parses (benchmark printouts, log text, test messages), fix it in the same edit and flag it in the report. Any other bug changes observable behavior: leave the code as it is and report it with its location and evidence.

## Invocation

`simplify <files or dir> [time]`

- `<files or dir>` — the files just written, or a target directory. Every code file under it is in scope, not just Zig. With no target, use the files changed in `git status`.
- `[time]` — optional budget such as `45m`, `2h`, or `1h30m`.

Record the start with `date +%s` and, when a budget is given, the deadline. Check the clock before starting each round.

- **With a time budget:** keep running rounds until the budget has elapsed; there is no early exit. Reserve the last ~10% of the budget (at least 10 minutes) for the final verification, and do not start a round that the previous round's duration says cannot finish before that reserve. When every slice reports DONE before the deadline, keep going with deeper rounds (see Round Types), each with a new angle, until the reserve begins. A deeper round that finds nothing does not end the run; pick the next angle.
- **Small targets:** when the whole target is one slice of a few hundred lines, run the rounds yourself instead of spawning sub-agents, and still run the adversarial check as a separate sub-agent so a fresh reader judges the result.
- **Without a time budget:** run rounds until every slice's adversarial check reports DONE. There is no round cap. A slice that goes two consecutive rounds without lowering its net token count while still drawing findings is marked stuck, dropped from later rounds, and listed in the final report with its open findings — those need human judgment.

## Work Partitioning

Partition the target into slices once, before the first round, and keep them stable across rounds:

- **Group by independent system:** files that import each other or form one subsystem (a renderer pass, the entity registry, one generator, a lib) belong together. Use the directory structure and `@import` graph to find the boundaries.
- **Size by lines:** aim for roughly 1000 lines per slice (`wc -l`). Merge small related files into one slice; never split a file across slices. A single file over ~1000 lines is its own slice.
- **One sub-agent per slice per round.** Slices are disjoint, so sub-agents never edit the same file. Follow the `fanout-orchestrate` skill for running them in parallel.
- **Slice boundaries are API boundaries:** a sub-agent may change a `pub` declaration's signature only when every caller is inside its own slice (grep the whole repo, including `build.zig`, to confirm). Otherwise it keeps the signature and simplifies behind it. One exception: a file rename required by the AGENTS.md casing rules may update the `@import` path strings outside the slice, because nothing else changes there. It deletes a `pub` declaration only when a whole-repo grep finds no use outside its own file and inlining it into its in-file users is simpler; it reports each deletion. A `pub` declaration with no users at all is a prune candidate, listed in the report and left in place.

## Simplification Principles

Include these principles verbatim in every simplify sub-agent prompt and in every adversarial checker prompt, together with the resolved path of the project's `AGENTS.md` (principle 8). Every change must preserve observable behavior.

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

### 5. Prefer the Language and the Standard Library

Hand-written code that duplicates a builtin or a std function is extra code to read and to trust. Before keeping a helper, loop, or per-axis expression, ask whether the language or std already does it, and grep the installed std for the operation (`grep -rn "pub fn " ~/.zvm/0.17.0/lib/std/<area>`).

- **Vector idioms:** per-component code on a `@Vector` (`v[0] ... v[1] ... v[2]`, `inline for (0..3)`) usually collapses to one vector expression plus `@reduce(.And/.Or/.Min/.Max/.Add, ...)`. Remember the IEEE rules when you fold checks: every comparison with NaN is false, so `@abs(x) < limit` already rejects NaN and infinity.
- **Std replacements:** replace hand-written code with a `std` function or type when one does the same job, for example a hand-rolled random generator with `std.Random`, or a hand-written search with `std.mem.find*`. More areas: searching and comparing (`std.mem.find*`, `eql`, `startsWith`), sorting (`std.sort`), formatting (`std.mem.print`, `allocator.print`), containers (`std.ArrayList`, hash maps, `std.enums.EnumArray`/`EnumSet`/`EnumMap`, `std.bit_set`), allocators (`std.heap.BufferFirstAllocator`, `ArenaAllocator`), math (`std.math.clamp`, `cast`, `divCeil`), and local copies of std types. Check the signature in the installed toolchain (`~/.zvm/0.17.0/lib/std`) before using it, never from memory. Replace only when the std version has the same behavior on every input the code sees, including edge cases, error sets, and allocation. Keep the hand-written version when it is measurably faster on a hot path or carries a load-bearing difference (principle 4), and leave a one-line comment saying why.

### 6. Names and Comments in ASD-STE100

Apply the `asd-ste100` skill (`.agents/skills/asd-ste100/SKILL.md`) to every identifier and comment the slice touches; use strict mode for doc comments, log strings, and error messages, and STE-flavored mode for other comments.

- **One word, one meaning:** one concept gets one name across the slice. Rename synonyms (`chunk_pos`/`chunk_coord`/`cpos` for the same thing) to the single clearest name. Names stay inside the AGENTS.md casing rules.
- **Names say what the thing is:** no vague nouns (`data`, `info`, `handle`, `manager`) where a specific noun exists, and no abbreviations a reader must decode.
- **Comments:** active voice, simple tenses, short sentences, no hedges or marketing words. Delete comments that restate the code; keep and sharpen the ones that give the reason. A comment is one or two plain sentences; a paragraph means the code is too complex. No decorative characters, separators, banners, or ASCII art.
- **Comments must be true:** a short, plain comment can still be wrong. Check every comment and doc comment against the code it describes and against its real consumer: a stated reason the code never acts on, a performance or memory claim the code contradicts, or a range or contract the code does not implement is a finding to fix, not a cosmetic nit. For example, a comment that justifies skipping `.air` above `if (block == .null) continue;` names a distinction the code never makes.
- **Doc comments:** every `pub` declaration gets a `///` doc comment in strict STE, unless its name already says everything.
- **Moved code gets a real name:** a helper that moves from an inline struct to file scope loses its context, so `next`/`unit`/`run` become names that say what they produce (`nextRandom`, `randomUnit`).
- Run `.agents/skills/simplify/scripts/lint-comments.sh <files>` for a mechanical first pass. It lints only comment text, with real file line numbers; running `ste-lint.py` on a source file lints the code and reports every `;` as a violation.
- Renaming a `pub` declaration follows the slice-boundary rule; when callers sit outside the slice, keep the name.

### 7. Tests Stay Independent

Tests are in scope, but a simpler test must not be a weaker test. A differential or property test is only worth something because its reference ("oracle") is computed independently of the code under test. Never replace a test's own check with a call to the function it tests, even when the two look identical; that turns the test into a tautology. Incidental test data may change freely: switching a test's random generator to `std.Random` changes which cases run but keeps the coverage, so it is fine. Coverage itself may not shrink — keep every case class (edge cases, degenerate inputs, failure paths).

### 8. Follow Every AGENTS.md Guideline

Read the project's `AGENTS.md` completely and make the slice comply with every rule that applies to it. Walk it section by section so nothing is skipped:

- **Naming, Style & Code Quality:** casing table, acronyms, comments, structure and control flow, state and mutation, idioms (captures over indexing, `std.enums` containers, annotated array literals).
- **Zig Toolchain:** the 0.17 API changes, `std.Io`, pointer safety, and every footgun.
- **Project patterns** for the systems the slice touches: concurrency, Vulkan and rendering, worldgen and terrain, config, persistence, plugins, and UI.
- **Writing tests:** every file has a `refAllDecls` test, each fallible allocation path that must survive OOM has one `checkAllAllocationFailures` test, and tolerances follow the stated rules.

A guideline fix may raise the token count (a missing `refAllDecls` test, a required doc comment, an assert that makes a contract explicit). List those edits separately in the report; they are exempt from the token rule.

## Measuring Complexity

`zig fmt --check --complexity <files or dirs>` prints `tokens=N nodes=M` (AST nodes) per file plus a total, on stderr as `info:` lines, without modifying files (plain `zig fmt --complexity` also reformats in place). Counts are per file and ignore formatting and line wrapping, so they cannot be gamed by joining lines. Net token count is the size metric; node count is informational.

- Record every target file's token count before the first round.
- A slice's round must lower its net token count. If it does not, revert or redo that slice's edits. Line count and node count are not requirements.
- Exception: renames and comment rewrites (principle 6) do not change token counts, because an identifier is one token and comments are not tokens. A round whose only edits are names and comments passes when its token count does not rise.
- Exception: guideline fixes (principle 8) are measured apart. Subtract their tokens before applying the rule, and list them in the report.
- Lower counts are necessary, not sufficient: readability and the load-bearing-differences rule still win over a smaller number.

## Round Types

- **Standard round:** the simplify sub-agent applies the principles to its slice, prioritizing any findings the slice's previous adversarial check reported.
- **Deeper round** (time budget only, after every slice has reported DONE): give each sub-agent a fresh angle on its slice, taking the next unused one from this list and cycling when it runs out: duplication across the slice's files; helpers and wrappers that no longer earn their keep; the API shape against how its callers actually use it; types or config surface that can be narrowed; the std and builtin sweep from principle 5 redone from scratch; every comment checked against the code; test coverage against the shapes callers use; ReleaseFast benchmarks of the hot paths; the slice's highest-token functions. Run a fresh adversarial check afterwards as usual.

## Round Loop

### Step 1: Simplify

Spawn one sub-agent per active slice. Each sub-agent's prompt must include:

- The slice's file paths and the files' current token counts
- The complete Simplification Principles above (sections 1–8 verbatim) and the resolved `AGENTS.md` path
- The working method below
- The slice's open findings from its last adversarial check, if any
- The round type and, for a deeper round, its angle
- The rule that simplifications MUST lower the slice's net token count, measured with `zig fmt --check --complexity <files>` before and after, and that this is the only hard size requirement (name- and comment-only edits must just not raise it)
- The slice-boundary rule for `pub` signatures
- The instruction: "Edit these files to be simpler and fully compliant with AGENTS.md, using the principles and the working method. Use precise, targeted edits with the edit tool."
- Skip `zig build` and tests; the orchestrator verifies after the round.

**Working method** (include verbatim):

1. **Survey before editing.** Read every file in the slice completely, then read `.agents/skills/simplify/references/patterns.md` and the project's `AGENTS.md`. Grep every caller of each `pub` declaration across the repo and note how they use it. Then write the **survey checklist**: one line for every principle, every pattern-catalog entry, and every AGENTS.md section, each marked either with the locations where it applies or with `n/a: <reason>`. No entry may be skipped, and "not applicable" needs a reason a reader can check. Earlier runs read the catalog and then applied a handful of entries from memory; the checklist exists to stop that. Walk the principles, the pattern catalog, and the AGENTS.md sections one by one, over library code *and* over every test, benchmark, and test helper, and list each opportunity with its location and a rough token saving. Test and benchmark code is where earlier runs left the most behind. A first pass that only notices the most visible duplication misses most of the gain.
2. **Apply the largest safe wins first.** Skip any change whose equivalence you cannot argue.
3. **Argue equivalence for every change.** Name the inputs where the old and new code could differ — NaN and infinity, integer overflow, rounding, empty inputs, error sets, allocation and failure paths, iteration order — and say why they agree. If they differ, do not make the change. Floats are the exception: reordered, reassociated, or fused float math that differs by a few ULPs or loses a little precision counts as equivalent, unless the code documents an exactness requirement. For numeric code, back the argument with a scratch differential test against the old version (see the catalog's verification habits).
4. **Names and comments pass.** Comments do not count as tokens, so the token metric never rewards this step; that is why it is a separate step rather than something to fit in. After the code edits, run `.agents/skills/simplify/scripts/lint-comments.sh <files>` and fix every finding in the slice's comments (rewrite, split, or delete the comment), then check identifiers against principle 6. Re-run the lint until the remaining findings are ones you can justify (for example a quoted identifier the linter misreads).
5. **Self-check cheaply.** Run `zig fmt --check --ast-check --complexity <files>` after editing; it catches syntax errors and unused variables and reports the new token counts without a full build.
6. **Report** the survey checklist with each entry's outcome (applied, left with a reason, or n/a with a reason), then a table — change, principle, tokens saved, equivalence argument — then the guideline fixes with their token cost, the slice's token counts before and after, the comment-lint finding counts before and after, the opportunities you found but left alone, with the reason, the bugs you found (fixed or reported, per the bug rule), and unused `pub` declarations as prune candidates.

### Step 2: Format and Build

Run `zig fmt .`, then `zig build`. If the build fails, fix the errors (or revert the offending slice's edits) and rebuild.

### Step 3: Tests

Run the `verify-change` skill's test gate (filtered tests for touched areas; full suite where the environment supports it — never the crashing headless full suite as proof). Fix or revert any regression before continuing.

Then compile and run the touched files' tests in ReleaseFast too (`zig test -OReleaseFast <file>` for a self-contained file, otherwise the filtered `zig build test` with `-Doptimize=ReleaseFast`). The 0.17 compiler has crashes and miscompiles that only appear in ReleaseFast, and a Debug-only gate passes them.

When the slice has benchmarks or hot paths, compare ReleaseFast timings before and after the round: build one binary per version, run each several times, and compare the best runs. Revert or redo any change that makes a case more than ~5% slower.

### Step 4: Play Test

Only when the round touched a user-visible path: `export VK_LOADER_LAYERS_ENABLE="*validation" && zig build run -Dtest_play=5`. Fix or revert any failure.

### Step 5: Measure

Run `zig fmt --check --complexity` on each slice. Revert or redo any slice whose net token count did not drop (or rose, for a name- and comment-only round), and log each slice's count after the round.

### Step 6: Adversarial Check

Spawn one adversarial sub-agent per slice changed this round, in parallel. Each prompt must include the slice's full file contents, the complete Simplification Principles (sections 1–8 verbatim), the resolved `AGENTS.md` path, the path of `references/patterns.md`, and the round's survey checklist, with these instructions:

> You are an adversarial checker. Your job is to argue that the code can be simplified further or still breaks a guideline. Review the provided files against the simplification principles included below, every entry of the pattern catalog, and every section of the AGENTS.md file at the given path, and check that every comment is true to the code. Audit the survey checklist: re-check every entry it marked `n/a` or left open, and report each one whose reason does not hold.
>
> If you find ANY remaining opportunity, respond with a table:
>
> | File | Line or function | Principle violated | Suggested change |
> |------|-----------------|--------------------|-------------------|
> | ...  | ...              | ...                 | ...                |
>
> If you cannot find any guideline violation, and no simplification that wouldn't harm readability, performance, or correctness, respond with exactly "DONE" and nothing else.

A slice with findings stays active for the next round; a slice that reports DONE is finished (until a deeper round, when a time budget remains).

### Step 7: Continue or Finish

Check the clock and the slice states against the Invocation rules, then either start the next round or move to Final Verification.

## Final Verification

Run the `verify-change` skill gates:

- `zig fmt .`
- `zig build`
- the test gate (filtered tests for touched areas; full suite where the environment supports it)
- the touched files' tests compiled and run in ReleaseFast, and the benchmark comparison against the counts recorded before the first round
- the play test only when a user-visible path changed
- `zig fmt --check --complexity <dir>`, compared against the counts recorded before the first round

Report:

- the elapsed time, and the remaining budget if one was given
- the number of rounds run and the slices used
- the token totals before → after, overall and per slice
- the guideline fixes made, and any guideline findings left open with the reason (cross-slice rename, human judgment)
- the stuck slices, with their open findings
