---
name: simplify
description: Simplify code while maintaining all functionality. Covers structural hygiene, control flow simplification, and state and mutation minimization. Use when asked to simplify, refactor, or clean up code.
---

# Simplify

Simplify code while preserving all functionality. The priority order is:

1. **Correctness** — never change observable behavior
2. **Readability** — simpler must mean easier to understand, not terser for its own sake
3. **Simplicity** — fewer branches, shallower nesting, smaller functions
4. **Performance** — do not sacrifice speed for simplicity

**This is not a review skill.** Do not report violations, do not flag naming issues, do not check style. Actively rewrite code to be simpler. If a simplification principle can be applied, apply it directly — don't just note it.

Stop after at most 3 passes, or when the adversarial check reports DONE — whichever comes first.

## Work Partitioning

Files are the unit of work:

- Spawn one sub-agent per file that needs simplification.
- Each sub-agent receives the file path and the simplification principles (sections 1–3 below), reads the file itself, and edits it directly with the edit tool.
- Sub-agents operate on disjoint files, so there are no merge conflicts.

## Simplification Principles

Include these principles verbatim in every simplify sub-agent prompt and in the adversarial checker prompt. Every change must preserve observable behavior.

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

## Iterative Process

This skill runs at most 3 passes, then reports what remains:

### Step 1: Simplify Pass

Spawn one sub-agent per file (disjoint files only, per the `fanout-orchestrate` skill). Do it to all code files provided, not just zig. Each sub-agent edits its file directly with the edit tool and returns a brief summary. Each sub-agent's prompt must include:

- The file path
- The complete Simplification Principles above (sections 1–3 verbatim)
- Simplifications MUST reduce net line count, not increase it
- The instruction: "Edit this file to be simpler using the principles. Use precise, targeted edits. Return a brief summary of what you changed."
- Skip gates, formatters, and tests; the orchestrator verifies once at the end.

### Step 2: Format

Run `zig fmt .` so formatting differences don't clutter later passes.

### Step 3: Build Check

Run `zig build`. If it fails, fix the errors and retry from step 2.

### Step 4: Unit Tests

Run the `verify-change` skill's test gate (filtered tests for touched areas; full suite where the environment supports it — never the crashing headless full suite as proof). If any test fails, fix the regression and retry from step 2.

### Step 5: Play Test

Only when the simplification touches a user-visible path: `export VK_LOADER_LAYERS_ENABLE="*validation" && zig build run -Dtest_play=5`. If it fails, fix and retry from step 2.

### Step 6: Adversarial Check

Spawn a sub-agent whose sole job is to find remaining simplifications. Its prompt must include:

- The full file contents of every file modified in this pass
- The complete Simplification Principles above (sections 1–3 verbatim)

Its instructions:

> You are an adversarial checker. Your job is to argue that the simplified code can be simplified further. Review the provided files against the simplification principles included below.
>
> If you find ANY remaining opportunity, respond with a table:
>
> | File | Line or function | Principle violated | Suggested change |
> |------|-----------------|--------------------|-------------------|
> | ...  | ...              | ...                 | ...                |
>
> If you cannot find any simplification that wouldn't harm readability, performance, or correctness, respond with exactly "DONE" and nothing else.

### Step 7: Loop or Finish

- If the adversary responds with a table of findings and fewer than 3 passes have run, feed those findings into the next simplify pass (go back to step 1). The parent agent reads the table and includes specific findings in the simplify sub-agent prompts so they target those remaining issues.
- If the adversary responds with "DONE", the process is complete.
- After 3 passes with findings still open, stop and report the remainder — some issues need human judgment.

## Final Verification

After the loop ends, run the `verify-change` skill gates:

- `zig fmt .`
- `zig build`
- the test gate (filtered tests for touched areas; full suite where the environment supports it)
- the play test only when a user-visible path changed
