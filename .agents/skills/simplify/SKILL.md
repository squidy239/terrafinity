---
name: simplify
description: Simplify Zig code while maintaining all functionality. Covers structural hygiene, control flow simplification, and state and mutation minimization. Use when asked to simplify, refactor, or clean up code.
---

# Simplify

Simplify code while preserving all functionality. The priority order is:

1. **Correctness** — never change observable behavior
2. **Readability** — simpler must mean easier to understand, not terser for its own sake
3. **Simplicity** — fewer branches, shallower nesting, smaller functions
4. **Performance** — do not sacrifice speed for simplicity

**This is not a review skill.** Do not report violations, do not flag naming issues, do not check style. Actively rewrite code to be simpler. If a simplification principle can be applied, apply it directly — don't just note it.

Stop only when no further simplifications remain that would improve the code without harming readability, performance, or correctness.

## Work Partitioning

Files are the unit of work:

- Spawn one sub-agent per file that needs simplification.
- Each sub-agent receives the **full file contents** and the simplification principles (sections 1–3 below). It returns the complete rewritten file content.
- Sub-agents operate on disjoint files, so there are no merge conflicts. The parent agent writes each returned content back to its file.

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

## Iterative Process

This skill runs in a loop until no further simplifications remain:

### Step 1: Simplify Pass

Spawn one sub-agent per file. Each sub-agent's prompt must include:

- The file path
- The complete Simplification Principles above (sections 1–3 verbatim)
- Simplifications MUST reduce net line count, not increase it
- The instruction: "Edit this file to be simpler using the principles. Use percise, targeted edits. Return a brief summary of what you changed."

Each sub-agent returns the rewritten file. Write each result back to its file.

### Step 2: Format

Run `zig fmt .` so formatting differences don't clutter later passes.

### Step 3: Build Check

Run `zig build`. If it fails, fix the errors and retry from step 2.

### Step 4: Unit Tests

Run `zig build test`. If any test fails, fix the regression and retry from step 2.

### Step 5: Play Test

Run `export VK_LOADER_LAYERS_ENABLE="*validation" && zig build run -Dtest_play=5`. If it fails, fix and retry from step 2.

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

- If the adversary responds with a table of findings, feed those findings into the next simplify pass (go back to step 1). The parent agent reads the table and includes specific findings in the simplify sub-agent prompts so they target those remaining issues.
- If the adversary responds with "DONE", the process is complete.

## Final Verification

After the adversarial sub-agent says "DONE", run a final verification:

- `zig fmt .`
- `zig build`
- `zig build test`
- `export VK_LOADER_LAYERS_ENABLE="*validation" && zig build run -Dtest_play=5`
