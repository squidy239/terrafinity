---
name: style-review
description: Review Zig code in the project against the project's coding guidelines from AGENTS.md. Covers naming conventions, code quality, patterns, and anti-patterns. Iterates review → fix → re-review until clean.
---

# Style Review (Iterate Until Clean)

When the user asks for a code review, a guideline check, or wants to know if their code follows Terrafinity conventions, follow this procedure.

The `AGENTS.md` file lives at the project root. Resolve its path once and pass it to every sub-agent as `{AGENTS_PATH}`.

## Process

Run an **iterate-until-clean** loop with up to 3 iterations. Each iteration:

1. **Review** — 3 sub-agents in parallel, each checking one section of AGENTS.md against all target files.
2. **Synthesize** — compile findings. If zero violations, skip to final verification.
3. **Fix** — one sub-agent per file with violations, all in parallel (disjoint write sets).
4. **Build** — `zig build`. Fix build errors before re-reviewing.
5. **Repeat** — go back to step 1.

Stop when zero violations are found, or after 5 iterations (report remaining violations).

## Step 1: Determine Target Files

If the user names specific files, use those. Otherwise discover all project `.zig` source files (POSIX-compatible):

```
find src -name '*.zig' ! -path '*/test*'
```

Only review files under `src/`. Skip `zig-out/`, `zig-cache/`, `.zvm/`.

If the file count exceeds ~30, partition files into batches and spawn one sub-agent per phase per batch (e.g. 3 phases × 2 batches = 6 review sub-agents). Each sub-agent should receive at most 15 files.

## Comment Rules

When reviewing or fixing code, enforce these comment standards, and ensure EACH comment checks all boxes in the comment rules.

- **No decorative characters.** No dashes, equals signs, asterisks, or other characters used as separators or borders. No ASCII art. No banner comments. A comment is plain text.
- **Keep comments short.** One or two plain English sentences. If you need a paragraph, the code is too complex.
- **When to comment:** comments MUST explain _why_ behind a non-obvious decision, flag `TODO` items, or document genuinely confusing logic that absolutely cannot be clarified through renaming or restructuring.
- **What to flag:** comments that state the obvious (`// increment i`), decorative cruft (`// =====`), or ASCII art (`// /\_/\  meow`).
- **Doc comments (`///`):** expected on public functions when the name is not self-explanatory. They must follow the same rules: no decorative characters, no banners, plain and direct.

```zig
// ✗ WRONG — decorative cruft
// ==========================================
// INITIALIZATION PHASE
// ==========================================

// ✗ WRONG — ASCII art
// /\_/\  meow

// ✗ WRONG — stating the obvious
// increment i by 1
i += 1;

// ✓ CORRECT — explains why
// The order matters here: upstream expects sorted keys.
std.sort.insertion(Key, keys, {}, Key.lessThan);

// ✓ CORRECT — TODO marker
// TODO: replace with arena allocation once the allocator is threaded through.

// ✓ CORRECT — doc comment on a public declaration
/// Returns the number of active connections, or 0 if the pool is uninitialized.
pub fn activeConnectionCount(self: *const Pool) u32 {
```

## Step 2: Iterative Review-Fix Loop

### 2a. Review (3 sub-agents in parallel)

Spawn three sub-agents simultaneously. Each reads its assigned section of AGENTS.md and reviews all target files.

Each sub-agent returns violations as **pipe-delimited lines** (`|` as field separator). The ISSUE and FIX fields may contain spaces but must not contain `|` characters.

```
VIOLATION|<file path>|<symbol or location>|<short rule name>|<what is wrong>|<suggested fix>
```

If none, output `NO VIOLATIONS`.

The `symbol or location` field names the function, struct, variable, or other identifier involved — this survives line-shifting during the fix phase and lets fixers locate the code by name rather than stale line numbers.

#### Phase 1: Naming Conventions & Comments

> Read `{AGENTS_PATH}` from the heading `# Codebase Naming Conventions & Guidelines` through the end of `## Comments` (stop before `## Quick Reference Cheat Sheet`).
>
> Review the provided files for violations of every rule in those sections, including the comment rules listed above under `## Comment Rules` in this skill.
>
> Output one pipe-delimited line per violation, or `NO VIOLATIONS`.

#### Phase 2: Structure and Control Flow

> Read `{AGENTS_PATH}` from the heading `# Code Simplicity and Quality Standards` through the end of `### Use Capture Syntax Over Index Variables` (stop before `## Comptime Pointer Alignment and \`@embedFile\``).
>
> Review the provided files for violations of every rule in that section.
>
> Output one pipe-delimited line per violation, or `NO VIOLATIONS`.

#### Phase 3: Patterns and Anti-Patterns

> Read `{AGENTS_PATH}` from the heading `## Comptime Pointer Alignment and \`@embedFile\`` through the end of `## Per-Frame Fence Wait Pattern` (stop before `# Modify this file`).
>
> Review the provided files for violations of every rule in that section.
>
> Output one pipe-delimited line per violation, or `NO VIOLATIONS`.

### 2b. Synthesize

Parse sub-agent outputs by splitting on `|`. Build a per-iteration report:

```
## Iteration N

### Naming Conventions & Comments (Phase 1)
(N violations, or "No violations found")

### Structure and Control Flow (Phase 2)
...

### Patterns and Anti-Patterns (Phase 3)
...

### Summary — Total violations: N
```

**Testing conventions (AGENTS.md from `## Testing` onward) are scoped to test files and not reviewed.** If the user provides test files explicitly, review them against that section separately.

**If all three phases return zero violations:** skip to Step 3.

**If violations remain and this is iteration 5:** stop. Report remaining violations — some issues require human judgment.

### 2c. Fix (one sub-agent per file)

Group violations by file. For each file with violations, spawn a fixer sub-agent. All fixers run in parallel.

> Read `{AGENTS_PATH}` for the complete coding standards, and follow the comment rules in this skill.
>
> **File to fix:** `<file path>`
>
> **Violations (pipe-delimited, one per line):**
> ```
> VIOLATION|<file>|<symbol>|<rule>|<issue>|<suggested fix>
> ```
>
> **Instructions:**
> 1. Read the file.
> 2. Apply ALL fixes. Make minimal changes — do not refactor unrelated code. Locate code by the `<symbol>` field; line numbers from the original review are stale, so search for the symbol name.
> 3. **Do not rename public symbols that have callers in other files.** If a fix would require cross-file changes, skip it and note it as deferred with the reason `cross-file`.
> 4. > Attempt to have as close to net neutral or negitive line count changes as possible with your changes.
> 5. If a fix renames a symbol that is only used within this file, update all call sites within the file.
> 5. Run `zig fmt` on the file after editing.
> 6. Output: `FIXED: <file> — N violations fixed` or `PARTIAL: <file> — N fixed, M deferred (<reason>)`.

Cross-file renames are forbidden in the fix phase. This guarantees the build check in 2d will pass (barring other errors). Violations that require cross-file changes appear as deferred and are re-flagged in the next review iteration with fully updated symbol information.

### 2d. Build Check

Run `zig build`. If it fails, fix the build errors, re-run until passing, then continue to the next iteration.

## Step 3: Final Verification

When the loop exits clean:

1. `zig build`
2. `zig fmt .`
3. If the user requested a play test: `export VK_LOADER_LAYERS_ENABLE="*validation" && zig build run -Dtest_play=5`

Review the git diff for the file and ensure it is close to net neutral or negative line count changes.
Never use `git checkout` or `git reset` to modify the file, only edit the file directly.

Report:

```
# Terrafinity Guideline Review — COMPLETE

## Files Reviewed
(list)

## Iterations
N iteration(s): (per-iteration violation counts)

## Final Status
✅ All violations fixed
✅ Build passes
✅ Play test passes (if run)
```

## Important Rules

- Resolve `AGENTS_PATH` once. Pass it to every sub-agent — never hardcode an absolute path.
- Reference AGENTS.md sections by heading names, not line numbers. Line numbers drift as the file is edited.
- Review sub-agents run in parallel. Fixer sub-agents run in parallel (disjoint files).
- Fixers locate code by symbol name, not line number. Use `grep` or search within the file.
- Fixers must not rename public symbols used in other files. Defer those to the next review iteration.
- Max 5 iterations. Remaining violations after 5 are reported — some issues need human judgment.
- Build errors block progress; fix them immediately before re-reviewing.
- Violations use `|` delimiters. `ISSUE` and `FIX` fields must not contain `|`.
- If the file count exceeds ~30, partition into batches of ≤15 files each.
