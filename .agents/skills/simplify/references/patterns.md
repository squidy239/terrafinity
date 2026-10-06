# Simplify pattern catalog

Read this during the survey step. Each entry is "look for X, do Y, because Z". These came from real runs on this codebase; the reason matters more than the example, so apply the idea, not the literal text.

## Where the gains hide

- **Test, benchmark, and helper code get the same depth as library code.** Earlier runs simplified the library carefully and skimmed the tests, leaving the largest wins behind. Walk every test, benchmark, and test helper with the full catalog below.
- **A helper whose only job is a workaround** (an optimizer sink, a manual string builder, a hand-written counter) usually has a std function built for that exact purpose. Ask "what is this helper *for*?" before asking how to shorten it. Example: a `firstScalar` helper feeding a `sink` accumulator becomes `std.mem.doNotOptimizeAway(value)` — and the std version is also more correct, because it keeps the *whole* value alive instead of one element.
- **Stale attributes.** `@setFloatMode`, `inline`, `comptime`, `align`, and `noinline` outlive the code they were for. Check what each still affects: `@setFloatMode` applies only to float operations written in its own scope, so it does nothing once those operations move into a called function such as `std.math.lerp`. Remove what does nothing; keep `inline` only with a benchmark that shows it matters, per AGENTS.md. "I cannot prove it is dead" is not a reason to keep it: prove it. Read where the float operations are written, and compare ReleaseFast benchmarks with and without the attribute (best of several runs). Unchanged numbers mean it goes.
- **A new helper that is a scalar copy of an existing one** (`pointLerpData` beside `computeAxisLerpData`) adds tokens. Inline the scalar math at its single call site or reuse the existing helper.
- **Duplicated computations of the same quantity** (several `product`/`count`/`stride` loops, a `volume` block recomputing a type's existing constant) collapse into one comptime helper or reuse of the existing declaration.

## Std and language replacements

- A helper that formats debug or benchmark output → delete it and use a std format verb (`{any}` prints arrays and tuples). This changes the exact text, which is fine only for output no program parses. Check this before shortening such a helper.
- Manual comptime string building that must stay (buffers, `@memcpy`, position counters) → `std.fmt.comptimePrint` plus `++`.
- `Clock.Timestamp.now` + `durationTo(.now(...))` or `untilNow(io)` + `.raw.toNanoseconds()` → `std.Io.Timestamp` with `start.untilNow(io, clock).nanoseconds`. Any `.raw.toNanoseconds()` chain is the long form. Check for `untilNow`/`since`-style methods before subtracting timestamps by hand.
- Unit-conversion literals (`1000.0`, `1e6`, `1e9`) → `std.time.ns_per_us`, `ns_per_ms`, `ns_per_s`; they name the unit.
- `@as(f64, @floatFromInt(x))` where `x` is comptime-known → use `x` directly; comptime integers coerce to floats exactly. Making a value comptime often deletes its casts.
- Per-component vector code → one vector expression plus `@reduce` (see principle 5).
- Arithmetic idioms → `std.math`: `@mulAdd(f, b - a, a)` is `std.math.lerp(a, b, f)`, which also accepts vectors. Grep `std/math.zig` for the formula before keeping it inline.
- A recursive fill over nested arrays of one scalar type → loop over the rows directly, or one flat loop over `std.mem.bytesAsSlice(Float, std.mem.asBytes(&grid))`.
- Comptime tables computed in floats and then cast back (`@intFromFloat`/`@floatFromInt` round trips) → integer math (`i * (size - 1) / count`, `% count`). It is exact and needs no casts.
- `product`/stride tables written as loops with index ranges → one `fn product(comptime sizes: []const usize) usize` called on slices (`dims[1..]`, `dims[0..axis]`). An empty slice gives 1, so the edge cases need no branch. `@reduce(.Mul, ...)` does not work here: zero-length vectors do not compile.
- Nested types built with a decrementing `while` → `for (1..N) |i| T = [counts[N - i]]T;` (wraps `counts[N-1]` first, so `counts[1]` ends outermost, the same order as the `while`) or `for (sizes[1..]) |size|` when the first size must end innermost. Check the nesting order with a one-line `@compileLog(T)` or a test instead of rejecting the rewrite.
- A named struct type used only as one function's return type → an inline `struct { ... }` return type.
- `Type.init(...)` / `std.X.now(...)` where the result type is known → decl literals (`.init(...)`, `.now(...)`).

## Signatures and data shape

- **Match the API to what callers hold.** Grep the callers before simplifying a constructor. If every caller converts its data before the call (`Interp.init(@bitCast(flat))` into a nested `Grid`) and the callee converts it back (`collectRows`), take the callers' form directly. That deletes the nested type, its builder, and the conversion, and the callers do not change.
- **Store the form the hot path reads.** A field stored as `@Vector` but indexed as an array everywhere else (`const row: [n]Float = self.cells[i]`) should be stored as an array; each read site loses its conversion.
- **A private helper with one caller** (`rowIndex` used only by `at`, `at` used only by `sample`) folds into that caller.
- **A parameter every caller passes the same value** (always `f32`, always one `io`), or that is really a property of the callee (an iteration count) → move it into the callee. Shorter signatures, and the value often becomes comptime, which removes casts.
- **Arrays packed and then sliced apart** (`.{ 4, 4, 32, 32 }` read as `cfg[0..2]`, `cfg[2..4]`) → a table of structured entries (`.{ .{ 4, 4 }, .{ 32, 32 } }`), with a one-line comment naming the fields when they are not named.
- **Loops that differ only in arity or type** → one `inline for` over a table, deriving the arity from the data (`shape[0].len`).

## Tests

- **Tests cover the shapes callers use.** Grep the callers: if production calls a generic with 2D shapes and every test is 3D, add the missing shapes. Also cover the degenerate legal inputs the code has branches for (N == 1, a single lane, sizes that are not powers of two, downsampling). This adds tokens and is a guideline fix, exempt from the token rule.
- **Loops that walk a nested result to compare it** → one recursive walker that takes the shape from the value's type (`@typeInfo(@TypeOf(x)) == .vector` ends the recursion). Pass it a reference that has a `sample(t)`-style method, so a differential test and an analytic test (a small struct with the formula) share it.
- **Several near-identical test calls over shapes** → `inline for` over a tuple of the instantiated types, with a type-level declaration (such as `Coordinates`) for the per-shape values.
- **Hard-coded divisors and loop bounds** that restate the shape (`/ 16.0`, `for (0..5)`) → derive them from the data, or loop with captures over the value itself.
- **Index loops** (`for (0..n) |i| a[i] = ...`, `inline for (0..len) |i|`) break AGENTS.md's captures rule in tests as much as in library code.

## Performance traps

- **A by-value capture of a large array copies it.** `for (&out, self.big_array) |*o, item|` copies the whole array first; capture `&self.big_array` and `|*item|`. This cost ~20% on a 32^3 grid.
- **Benchmark hot paths in ReleaseFast before and after** (best of several runs, one compiled binary, run repeatedly). A smaller form that is slower is not simpler; revert it or note the cost.

## Names that hide bugs

- **One word, one meaning across the file.** Watch for a field and a local that share a word with different meanings (`cells` holding control points beside `cell` meaning the lower grid index), and a parameter, a type, and a function that share a stem (`samples` counts, `Samples` type, `sample` function). Rename until each word names one thing.

- For every derived quantity, re-derive its unit from the code and compare it with its name. `samples_per_pass = iterations * volume` is really the *total* sample count — and that misname hid a printout that labeled the total time as "per pass". A name that does not match its value is a bug report waiting to happen.

## Do not trade these for tokens

- **Type safety.** Byte reinterpretation is allowed only where Zig guarantees the layout: nested arrays of one element type, or an array of vectors viewed as a flat array of the same vectors. Prefer `std.mem.bytesAsValue`/`bytesAsSlice` over `@ptrCast`, and over `@bitCast` of nested arrays in generic code, which crashes the compiler in ReleaseFast (see AGENTS.md footguns). Never reinterpret structs, padded vectors as arrays, or types whose layout Zig leaves unspecified. Better still, change the data shape so no cast is needed (see "Signatures and data shape").
- **Public API with outside users.** Keep every `pub` declaration that something outside its file uses or that has no users at all (a prune candidate). A `pub` declaration used only inside its own file may be inlined and deleted; report it.

Float operation order is *not* on this list. Reordering, reassociating, or fusing float operations is fine, and so are results that differ by a few ULPs or lose a little precision. Only code that documents an exactness requirement (a comment, an AGENTS.md note such as the erosion pipeline's build-stability rule, or a test with a tight or exact tolerance) keeps its exact operation order.

## Verification habits

- For numeric code, write a scratch differential test (outside the repo, e.g. `/tmp/<name>/`) that imports the old version (`git show HEAD:<path>`) and the new one and compares outputs over random and edge inputs in Debug and ReleaseFast. Compare floats with a small relative-plus-absolute tolerance unless the code documents an exactness requirement; a large difference is a real bug, a few ULPs is not.
- After changing a benchmark's sink or loop, compare ReleaseFast timings with and without an extra `doNotOptimizeAway(&input)` per pass. Identical numbers prove the work was not hoisted out of the loop.
