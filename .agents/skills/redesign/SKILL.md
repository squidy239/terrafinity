---
name: redesign
description: Improve design and architecture by removing unneeded and shared state - delete derived or duplicated state, separate state into single-responsibility types, shrink state lifetimes, give shared mutable state a single owner, make illegal states unrepresentable, replace data structures with ones that fit the access pattern, and make public APIs smaller and harder to misuse - without raising net token or node count. The higher-level partner of `simplify` (simplify improves the implementation inside a design; redesign changes the design). Invoke on files or a directory with an optional time budget (e.g. `src/world 2h`). Use when asked to redesign, re-architect, improve the design or architecture, untangle or decouple a system, remove shared or global state, reduce locking, pick a better data structure, or when a system has too many fields, flags, caches, locks, or sources of truth - even if the user only says the code "feels tangled".
---

# Redesign

`simplify` keeps the design and makes the code that implements it smaller. `redesign` changes the design: what state exists, who owns it, how long it lives, what structure holds it, and the public API through which other code uses it. A good redesign deletes whole categories of code (locks, sync paths, invalidation, null checks, bookkeeping) because the state those lines protected no longer exists.

Priority order:

1. **Correctness** — observable behavior is unchanged, including under concurrency, OOM, and cancellation.
2. **Less and separated state** — fewer pieces of mutable state, fewer of them shared, shorter lifetimes, one source of truth per fact, and each type owning the state of one responsibility.
3. **Fitting data structures** — the structure matches how the data is actually read and written.
4. **Size** — the net token count and the net node count of the touched files must not rise (hard rule, see Measuring).
5. **Performance** — no hot path gets more than ~5% slower in ReleaseFast.

Do not do simplify's job here. Renames, comment rewrites, guard clauses, and std replacements are side effects at most; the unit of work is a state, structure, or public API change. Recommend a `simplify` pass on the touched files in the final report.

## Invocation

`redesign <files or dir> [time]`

- With no target, use the files changed in `git status`.
- The time budget follows the `simplify` skill's Invocation rules exactly (strict, measured with `date +%s`, no early stop, reserve for final verification). When candidates run out before the reserve, rescan with the next angle in Deeper Passes.
- Without a budget, run until the adversarial check finds no candidate that the rules allow.

## What counts as state

State is any value that persists between two points where code reads it: struct fields, globals and file-level `var`s, `threadlocal`s, caches, flags, counters, refcounts, locks and atomics (they exist only because state is shared), heap containers, and copies or mirrors of a value held elsewhere. A value that one function computes and consumes is not state.

Shared state is state that more than one function, task, or thread writes, or that one writes while another reads. It is the costliest kind: every reader must know every writer's rules.

## The moves

Ranked by how much they usually remove. Each move names what to look for and what proves it safe.

1. **Delete derived state.** A field that can be computed from other fields (a cached count, an `is_empty` flag, a min/max, a "dirty" bit that mirrors a comparison) is a second source of truth that can disagree. Compute it where it is read. Keep a cache only with a ReleaseFast benchmark that shows it matters, and then keep exactly one writer for it.
2. **Collapse duplicated sources of truth.** The same fact stored in two places (a set plus a per-item flag, a hash map plus a list of the same keys, a mirror copy for another thread) needs sync code and drifts. Keep one; derive or look up the other.
3. **Shrink lifetimes.** Move state to the shortest scope that needs it: a struct field read and written only inside one call becomes a local; a long-lived field used only during setup becomes an `init` parameter; scratch memory that persists only for reuse becomes a caller-owned buffer passed in. A field whose value is valid only in some phases is a lifetime bug waiting to happen.
4. **Give shared mutable state one owner.** When several tasks write the same state under a lock, make one task own it and let the others send it messages or results (a completion queue, a recorded op list). The owner then uses plain values: the locks, atomics, and lock-order rules go away. `ChunkStreamer.pass` owning the clipmap with tasks reporting through `completions`, and the upload drain recording `Publication` ops for `publishPending` to apply, are the pattern in this repo.
5. **Separate state by responsibility.** A struct whose fields fall into groups that different functions read and write (streaming state next to render state next to input state) is several types sharing one name, and every method can touch every group. Split it so each type owns one responsibility and its fields, and each function takes only the part it uses. Find the groups from the state map: fields that are always read and written together form one type; a field read by both groups is the interface between them and goes to the group that writes it. A type whose name needs "and", or whose methods each touch a different subset of its fields, fails single responsibility. Split only along real groups; a split that makes two types pass the same fields back and forth has the boundary in the wrong place.
6. **Move state to the code that uses it.** A field on a big coordinator struct that only one subsystem reads belongs in that subsystem (commit d51ffc1 moved physics state from `Game` to `Player`). Pass dependencies in explicitly instead of reaching through a shared context or a global.
7. **Make illegal states unrepresentable.** A bool plus an optional that must agree, several flags of which only some combinations are valid, or a sentinel value meaning "not set" become one tagged union, one enum, or an `EnumSet`. Each removed combination is a branch nobody has to write or test.
8. **Replace the data structure.** Read every access site and ask what structure those operations want:
   - hash map with dense or bounded integer keys → array, slab, or ring indexed by the key; hash map over an enum → `std.enums.EnumArray`/`EnumMap`
   - hash map tracking a moving window of positions → a fixed-size ring or clipmap with wrap-around indexing (commit 4a4b0a8 replaced a loaded-or-meshed hash map with `ChunkClipmap`)
   - pointer graph or pointers into growing arrays → flat arrays plus `u32`/`u16` handles (AGENTS.md "Handles over pointers")
   - set of small integers or flags → `std.bit_set` or `EnumSet`
   - list kept sorted for one lookup, or scanned for membership → the structure that answers that lookup directly
   - per-item lock or refcount where items are owned by one task → drop the lock and refcount
   - shared mutable structure read by many and written rarely → an immutable snapshot swapped in whole (the `publishPending` swap, not a stolen slice)
9. **Replace mutation with values.** A function that mutates a field so a later call can read it becomes a function that returns the value. A multi-step init that leaves an object half-built between steps becomes one function that returns the finished value.
10. **Improve the public API.** Read every caller and reshape the API to what they need. Make it hard to misuse: a call order that callers must remember (`begin`/`end`, `lock` then `get`) becomes one call or a returned value that ends the sequence; arguments that must agree become one type; a raw field that callers reach into becomes a function, or the field's state moves to the caller that owns it. Make it smaller: merge functions that every caller calls together, remove `pub` from declarations no other file uses, and remove parameters that every caller passes the same way. Return results instead of filling out-params when callers do not supply the buffer. Every caller changes in the same edit (see "The call-site span moves together"). An API that is wider than its current callers on purpose, such as a plugin interface (`generator_api`) or a capability kept for a future feature, follows "Do not narrow capability to current use".

## Rules

- **Prove every removal.** Before removing a lock, an atomic, or a refcount, list every reader and writer (grep the whole repo, including `zig-pkg/` and `build.zig`) and the task or thread each runs on, and show they are now ordered. Before deleting derived state, show every write site of its inputs. Follow AGENTS.md "Verify before writing": a claim without its check does not go in.
- **Respect documented designs, or rewrite them.** AGENTS.md sections (Concurrency, Chunk streaming, Entity update scheduler, Mesh upload backpressure) record invariants that past bugs paid for. A redesign may replace one only when the new design keeps the property the invariant protects (no deadlock, no GPU read race, no half-updated state on OOM). When it does, update that AGENTS.md section in the same change, so the doc never describes a design that is gone.
- **Keep OOM and cancel safety.** A new structure follows "reserve first, then mutate infallibly", and a task that reports through a queue still pushes exactly once.
- **One redesign at a time.** Apply, measure, and verify one candidate before starting the next. Two half-finished redesigns in one tree make failures impossible to attribute.
- **The call-site span moves together.** A redesign changes every caller of the API it reshapes, across any number of files; there are no slice boundaries. If the span is too large to finish and verify in the remaining time, report the candidate instead of starting it.
- **Do not narrow capability to current use.** Fit the structure to the access pattern, not to today's values. Never trade away a capability the design deliberately offers just because no caller uses it yet: a runtime-growable inventory stays growable even if every inventory today has the same size; an `Allocator` parameter, a generic, a tagged union with one live variant, a reserved field, or a resizable container stays as it is. Removing such a capability makes the next feature a redesign. If you see signs that a structure was built with a future feature in mind (a capability no caller exercises, a TODO, an AGENTS.md or `ideas.md` entry, a doc comment, a field or variant that is set but not yet read), do not change it. Write it down as a **deferred question**: the location, the change you would make, what it would remove, and the evidence of intent. Then continue with the other candidates. Do not stop to ask during the run.
- **Do not narrow the design to today's values.** Removing state must not remove flexibility: a runtime size does not become a comptime constant, a per-instance value (a body's gravity) does not become a global, and a general type does not take on one caller's concern (an inventory does not own the player's selected slot). Remove the sharing and the duplication, not the generality.
- **Do not add layers.** A redesign must not introduce an interface, a generic, a manager type, or an indirection that has one implementation. Fewer moving parts is the goal; a new abstraction is more state about state.
- **Never `git stash`, `commit`, `checkout`, or `reset`.** Revert a failed redesign with the edit tool.

## Measuring

Record `zig fmt --check --complexity <files>` (tokens and nodes) for every file a candidate will touch before editing it. After the redesign, the union of touched files must have net tokens ≤ before **and** net nodes ≤ before. A deleted file counts its before counts; a new file counts zero before. There are no exemptions: when the redesign needs new code (a required `refAllDecls` test for a new file, a tagged union declaration), bank deletions first. If the counts rise, shrink the redesign or revert it.

Also keep a **state census** of the target: mutable fields, file-level `var`s and `threadlocal`s, locks, atomics, and heap containers. Take it in the survey and again at the end. The census is the measure of progress; the token rule is only the guardrail.

## Workflow

### 1. Survey

Read every file in the target completely and the AGENTS.md sections for the systems it touches. Then write the **state map**, one row per piece of state:

| State | Kind (field, global, cache, lock, ...) | Responsibility | Writers (function, task/thread) | Readers | Lifetime | Derivable from? | Shared? |

Fill every column with evidence from the code, not from names. Rows that are derivable, duplicated, shared, or longer-lived than their uses are the candidates.

### 2. Rank candidates

For each candidate, write: the move (from the list above), the state it removes, the files in its call-site span, the expected token and node change, the risk (what breaks if the proof is wrong), and the proof it needs. Rank by state removed per unit of risk. Drop candidates that cannot meet the size rule. Move any candidate that would narrow an unused but deliberate capability to the deferred questions (see Rules).

### 3. Apply

Take the top candidate. Record before counts, prove the claim, make the change with targeted edits, run `zig fmt --check --ast-check --complexity <files>`, and check the size rule. Then run the `verify-change` gates: `zig fmt .`, `zig build`, the test gate for the touched areas, the touched tests in ReleaseFast (0.17 miscompiles only show there), a ReleaseFast before/after benchmark when a hot path changed, and the play test only when the change is user-visible. Fix or revert before moving on.

For several independent candidates with disjoint call-site spans, dispatch one worker per candidate under the `fanout-orchestrate` rules. Give each worker the state map rows, the move, the proof required, the rules above, and its file list; workers skip gates and the orchestrator verifies the union.

### 4. Adversarial check

After each applied redesign (or each fanout wave), spawn a fresh sub-agent with the touched files, the before and after state map rows, and the rules above:

> You are an adversarial checker for a design change. First, try to break it: find an interleaving, an OOM point, a cancellation, or an input where the new design behaves differently from the old one, and check that every removed lock, atomic, refcount, or field was truly unneeded. Second, find state the change left behind: fields, flags, caches, or containers in these files that are still derivable, duplicated, shared, or longer-lived than their uses. Report each problem as `file:line — problem — evidence`. If the change is correct and you find no remaining candidate, respond with exactly "DONE".

A correctness finding is fixed or the redesign is reverted. Remaining-state findings go back into the candidate list.

### Deeper Passes

When the candidate list is empty and budget remains, rescan the target with one angle at a time, cycling: locks and atomics (why does each exist?); fields written in only one function; containers keyed by integers or enums; optionals and bools that travel together; field groups on the biggest struct in the target (which methods touch which fields?); every mirror or copy sent between threads; init and deinit order (what is half-built in between?); each `pub` declaration (who calls it, and what do callers have to remember to call it correctly?).

## Report

- start, deadline (when budgeted), and finish times
- each applied redesign: the move, the state removed, the proof, files touched, tokens and nodes before → after
- the state census before → after
- reverted or rejected candidates with the reason, and candidates too large for the remaining time
- AGENTS.md sections rewritten
- gate results, and a recommendation to run `simplify` on the touched files

### Deferred questions

After all other work and the report are done, ask the user about each deferred question in one message (use `AskUserQuestion` when it is available, up to four per call). For each one, give the location, the proposed change, what it would remove, and the evidence that it may be meant for a future feature. Apply a change only when the user approves it, and then run the Apply and verification steps for it.
