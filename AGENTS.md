# Agent Guide

## Commands

Use these full commands without modification after each change and ensure the play test runs without errors:

- normal build: `zig build`
- run and open to menu: `zig build run`
- run and open to a game: `export VK_LOADER_LAYERS_ENABLE="*validation" && zig build run -Dtest_play=[number of seconds to run, 5-10 is a good default for a short test]`
- format code: `zig fmt .`

Important:
Do not git stash or commit, it can mess up git history.

# Codebase Naming Conventions & Guidelines

This document outlines the strict naming conventions and core principles for this project. To maintain a clean, predictable, and highly readable codebase, we follow a precise set of rules primarily inspired by Zig's ecosystem.

When in doubt, rely on the core philosophy: **Meaning dictates casing.**

---

## Core Philosophy: Simplicity & Self-Documenting Code

- **Code must be self-documenting:** The structure, variable names, and logic should clearly communicate intent without relying on external explanations.
- **Prioritize elegance:** Code should be as simple and elegant as possible. Avoid clever tricks in favor of readable, straightforward implementations.

---

## Comments

Comments must be simple and unobtrusive. They exist to clarify, not to decorate.

- **When to comment:** Use comments sparingly. They are appropriate for explaining _why_ behind a non-obvious decision, flagging `TODO` items, or documenting a genuinely confusing piece of logic that cannot be clarified through renaming or restructuring.
- **Never use decorative characters:** No ASCII art, no dashes or equals signs used as separators, no box-drawing, no banner comments. A comment is plain text.
- **Keep them simple:** One or two plain English sentences. If you need a paragraph, the code is too complex.
- **Doc comments (`///`):** Doc comments are the exception — they are expected on public declarations. They must still follow the same style rules: no decorative characters, no banners, plain and direct.

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

---

## Quick Reference Cheat Sheet

| Element                          | Casing Convention        | Example                                                                  |
| :------------------------------- | :----------------------- | :----------------------------------------------------------------------- |
| **Variables**                    | `snake_case`             | `model_weights`, `is_active`                                             |
| **Functions (Standard)**         | `camelCase`              | `trainModel(data: Dataset, epochs: u32)`, `parseData(input: []const u8)` |
| **Functions (Returns `type`)**   | `PascalCase` (TitleCase) | `CreateGraphNode(comptime T: type)`                                      |
| **Types & Aliases**              | `PascalCase` (TitleCase) | `NeuralNetwork`, `Dataset`                                               |
| **Namespaces** (0-field structs) | `snake_case`             | `math_utils`, `tensor_ops`                                               |
| **Files (Types)**                | `PascalCase` (TitleCase) | `AttentionLayer.zig`                                                     |
| **Files (Namespaces)**           | `snake_case`             | `matrix_helpers.zig`                                                     |
| **Directories**                  | `snake_case`             | `data_loaders/`, `utils/`                                                |

---

## Detailed Rules & Specifications

### Variables and General Identifiers

If an identifier is not a type, a namespace, or a callable, it must use **`snake_case`**.

- **Rule:** All lowercase letters, with words separated by underscores.
- **Applies to:** Local variables, struct fields, constants (unless an established convention dictates otherwise), and function arguments.
- **Examples:** `learning_rate`, `batch_size`, `input_tensor`.

### Types and Type Aliases

Any defined type or alias must use **`PascalCase`** (referred to in Zig as TitleCase).

- **Rule:** The first letter of every word is capitalized. No underscores.
- **Applies to:** Structs, enums, unions, and type aliases.
- **Examples:** `InferenceEngine`, `TransformerBlock`, `F1Score`.

### Callables (Functions and Methods)

The naming of a callable depends entirely on its return type.

- **Standard Callables:** If a function or method performs an action and returns a value, struct, or primitive, it must use **`camelCase`**. (_Examples:_ `calculateLoss(predictions: Tensor, targets: Tensor)`, `forwardPass(input: Tensor)`, `optimizeWeights(learning_rate: f32)`)
- **Type-Generating Callables:** If a function or method is called to generate and return a `type`, it must use **`PascalCase`**. This signals to the reader that invoking this function resolves to a type definition. (_Examples:_ `LinearLayer(comptime T: type)`, `CustomDataset(comptime T: type)`)

### Namespaces

If a struct has **zero fields** and is strictly used as a container for related functions (never meant to be instantiated), it is considered a namespace.

- **Rule:** Namespaces must use **`snake_case`**.
- **Examples:** `activation_functions`, `string_utils`.

### Acronyms and Initialisms

Acronyms, initialisms, and proper nouns are subject to standard capitalization rules just like any normal English word. **Do not fully capitalize acronyms.** Even two-letter acronyms follow this rule.

- **Rule:** Treat acronyms as a single word with only the first letter capitalized (in PascalCase/camelCase) or all lowercase (in snake_case).
- **Correct:** `parseHttp(request: []const u8)`, `JsonParser`, `io_stream`, `fetchApiData(url: []const u8)`
- **Incorrect:** `parseHTTP(request: []const u8)`, `JSONParser`, `IO_stream`, `fetchAPIData(url: []const u8)`

### Files and Directories

File names map directly to the structural intent of the file contents. In this ecosystem, a file is implicitly a struct.

- **Types (Structs with fields):** If the file contains top-level fields (state/data), it represents a type and must use **`PascalCase`**. (_Example:_ `ModelCheckpoint.zig`, `DataPipeline.zig`)
- **Namespaces (No fields):** If the file contains only functions, constants, or declarations (no top-level fields), it is a namespace and must use **`snake_case`**. (_Example:_ `gpu_allocator.zig`, `math_constants.zig`)
- **Directories:** All directories must strictly use **`snake_case`**. (_Example:_ `natural_language_processing/`, `core_engine/`)

---

# Zig 0.16.0: Quick `std.Io` Guide

I/O is an Interface. Anything that potentially blocks control flow or introduces nondeterminism requires an `Io` instance to operate.

## Core Concurrency Primitives

`std.Io` uses task-level abstractions for handling concurrency natively.

- **`Future(T)`:** Represents an asynchronous function call.
  - Create with `io.async(func: anytype, args: anytype)` (infallible) or `io.concurrent(func: anytype, args: anytype)` (allocates, can fail).
  - Retrieve the result using `future.await(io: std.Io)`.
  - Cancel ongoing work using `future.cancel(io: std.Io)`.
- **`Group`:** Manages multiple tasks that share a lifetime.
  - Create with `var group: std.Io.Group = .init;`.
  - Spawn tasks with `group.async(io: std.Io, func: anytype, args: anytype)`.
  - Wait for all to finish with `group.await(io: std.Io)`.
- **`Batch`:** A lower-level abstraction for grouping concurrent operations rather than functions (e.g., executing multiple file reads at once).

## Handling Cancelation Gracefully

When an operation is canceled, the I/O operation will return `error.Canceled`. It is standard practice to defer the cancelation of a task immediately after creating it to ensure cleanup.

```zig
var file_task = io.async(std.Io.Dir.openFile, .{ .cwd(), io, "hello.txt", .{} });
defer if (file_task.cancel(io)) |file| file.close(io) else |_| {};

const file = try file_task.await(io);
```

## Standard I/O Subsystem Operations

Standard library systems utilize the `Io` interface directly. Function signatures explicitly require `std.Io`.

- **Filesystem:** Uses `std.Io.Dir` and `std.Io.File`. Closing files requires the context: `file.close(io: std.Io)`.
- **Networking:** Uses `std.Io.net` for all socket and connection operations.
- **Process Management:** Spawning processes requires I/O context: `std.process.spawn(io: std.Io, options: std.process.SpawnOptions)`.
- **Time:** Retrieving current timestamps uses `std.Io.Timestamp.now(io: std.Io)`.

## Mutex Functions

Synchronization primitives integrate directly with the `std.Io` interface so that blocking operations suspend the task/thread efficiently based on the active I/O runtime.

- **`lock(io: std.Io)`**: Acquires the lock, blocking/suspending the current execution context until it becomes available.
- **`tryLock()`**: Attempts to acquire the lock without blocking. Returns a boolean indicating success.
- **`unlock(io: std.Io)`**: Releases the lock.

# Code Simplicity and Quality Standards

Maintaining a high-quality codebase requires strict adherence to structural hygiene, readability, and predictable logic. Code should read linearly and plainly.

## Structural Hygiene and Function Size

- **Single Responsibility:** A function must do exactly one thing. If a function contains conjunctions in its name or its description, it is likely doing too much.
- **Visual Chunking and Length:** If a function requires visual dividers or heavy blank-line padding to separate different phases of internal logic, it is violating the single responsibility principle. Break long functions into smaller, private helper functions. If a function's body cannot fit comfortably on a single monitor screen without scrolling, it is an immediate candidate for refactoring.
- **Parameter Limits:** Keep function signatures minimal. If a function requires a large list of arguments, group related arguments into a dedicated struct to pass as a single context parameter. Prefer `processUserData(context: UserContext)` over `processUserData(name: []const u8, age: u8, id: u32, is_active: bool)`.

## Control Flow

- **Guard Clauses and Flat Hierarchy:** Deep nesting is a design failure. Always prefer early returns and guard clauses over nested conditional blocks. The primary "happy path" of a function should sit at the lowest possible level of indentation, running straight down the left side of the screen.
- **Fail Fast:** Handle errors immediately. Do not silently swallow errors with empty catch blocks. If a failure state is unrecoverable, fail fast and loudly rather than propagating bad state further through the system.
- **Inline Functions:** From the zig docs: It is generally better to let the compiler decide when to inline a function, except for these scenarios:

- To change how many stack frames are in the call stack, for debugging purposes.
- To force comptime-ness of the arguments to propagate to the return value of the function, as in the above example.
- Real world performance measurements demand it.
- Note that inline actually restricts what the compiler is allowed to do. This can harm binary size, compilation speed, and even runtime performance.

## State and Mutation

- **Proximity of State:** Declare variables in the deepest scope where they are used, as close to their first usage as possible. Do not declare a variable in an outer scope if it is only consumed in a nested block; this reduces the reader's mental stack by narrowing the variable's lifetime and proving it has no effect on the code outside that block.
- **Explicit Over Implicit:** Never rely on hidden state or side effects. If a function mutates state, its name and signature must make that glaringly obvious.
- **Constants Over Magic Values:** Avoid magic numbers or hardcoded string literals entirely. Bind them to properly named constants at the top of the file or within a dedicated namespace.
- **Minimize Unsafe Casts:** Avoid things like ptrcast and aligncast if you can. Bitcast is safer and has less footguns so only ptrcast if their is a good reason. Ptrcasts are ALMOST NEVER the right solution, only use them for things like casting to/from opaque pointers.

### Use Capture Syntax Over Index Variables

Prefer capture syntax (`|variable|`) over index variables in `for` loops. Captures eliminate off-by-one errors, out-of-bounds risk, and make the loop's intent obvious.

**Bad — index variable to index into arrays:**

```zig
for (0..items.len) |i| {
    doSomething(items[i]);
}
```

**Good — direct element capture:**

```zig
for (items) |item| {
    doSomething(item);
}
```

**Bad — index to mutate:**

```zig
for (0..items.len) |i| {
    items[i] = generate();
}
```

**Good — pointer capture for mutation:**

```zig
for (items) |*item| {
    item.* = generate();
}
```

**Bad — indexing into parallel arrays:**

```zig
for (0..count) |i| {
    arr[i] = f(others[i]);
}
```

**Good — zip parallel arrays with captures:**

```zig
for (arr, others[0..count]) |*dest, src| {
    dest.* = f(src);
}
```

**Good — multiple captured arrays:**

```zig
for (buffers, mapped, offsets) |*buf, *map, *off| {
    buf.* = new_buf;
    map.* = new_map;
    off.* = new_off;
}
```

**When you genuinely need an index** (e.g. calling an API that takes an index), use the `, 0..` capture instead of a range loop:

```zig
for (items, 0..) |item, i| {
    externalApi(items[i], i);
}
```

**`if` captures** unwrap optionals without introducing a `.?` failure point:

```zig
if (maybe_value) |value| {
    // value is the unwrapped type, no .? needed
}
```

**Rule:** If you find yourself writing `for (0..x.len) |i|`, ask whether you can capture the elements directly. Index variables should only appear when the numeric index itself is meaningful (e.g. bit positions, matrix dimensions, or API callbacks).

- **Watch Out for Undefined:** Always initialize variables before using them, and avoid values that it is easy to forget are undefined. For example, you can not check a optional set as undefined to see if it is null. Use optionals instead of undefined where possible.

## Comptime Pointer Alignment and `@embedFile`

`@embedFile` returns `*const [N:0]u8` with **alignment 1**. This matters when the data requires higher alignment (e.g. SPIR-V shaders need 4-byte alignment for `[*]const u32`).

**The rule:** `@alignCast` on an `@embedFile` pointer **must** be applied to the original comptime-known pointer, not to a function parameter. If you extract the cast into a helper function that accepts `[]const u8`, the comptime alignment information is lost and `@alignCast` will **panic at runtime**.

```zig
// ✗ WRONG — alignment info lost through function parameter
fn createModule(code: []const u8) vk.ShaderModuleCreateInfo {
    return .{ .p_code = @ptrCast(@alignCast(code.ptr)) }; // RUNTIME PANIC
}
const spv: []const u8 = @embedFile("shader");
_ = createModule(spv);

// ✓ CORRECT — inline keeps comptime-known pointer
inline fn createModule(code: []const u8) vk.ShaderModuleCreateInfo {
    return .{ .p_code = @ptrCast(@alignCast(code.ptr)) }; // OK if caller inlines
}

// ✓ CORRECT — cast at the call site, not in a helper
const module = try dev.createShaderModule(&.{
    .p_code = @ptrCast(@alignCast(spv.ptr)),
}, null);
```

**Takeaway:** When `@embedFile` data needs alignment casts, perform the cast at the call site or in an `inline` function that the compiler can fully resolve at comptime. Non-inline helper functions that accept `[]const u8` parameters will lose the alignment metadata.

## Single-Item Slice Pattern (`(&x)[0..1]`)

When a Vulkan (or other C) API expects a many-pointer (`[*]T` or `[]T`) to a single element, prefer `(&x)[0..1]` over two common anti-patterns:

- **`@ptrCast(&x)`** — unsafe; suppresses type checking and can hide errors
- **`&[1]T{x}`** — verbose; creates an anonymous temporary array

The `(&x)[0..1]` syntax is safe, concise, and makes the intent ("this pointer represents exactly one element") explicit.

```zig
const foo: Foo = .{ .x = 1 };

// ✓ CORRECT — single-item slice from pointer
.p_single_foo = (&foo)[0..1];

// ✗ WRONG — unsafe cast
.p_single_foo = @ptrCast(&foo);

// ✗ WRONG — verbose anonymous array
.p_single_foo = &[1]Foo{foo};
```

For actual multi-element arrays, use `array[0..n]` instead of `@ptrCast(&array)` or `@ptrCast(&array[0])`:

```zig
var arr: [4]Foo = undefined;

// ✓ CORRECT — many-pointer from array
.p_arr = arr[0..count].ptr;

// ✓ ALSO CORRECT — slice form (when field accepts a slice)
.p_arr = arr[0..count];

// ✗ WRONG — unsafe cast
.p_arr = @ptrCast(&arr);

// ✗ WRONG — pointer to first element
.p_arr = @ptrCast(&arr[0]);
```

Note: For `var` (mutable) arrays, the slice `arr[0..n]` is `[]T` (mutable). If the field expects `?[*]const T`, use `.ptr` to get `[*]T` which coerces to `?[*]const T`. For `const` arrays or single-item `(&x)[0..1]` the slice is already `[]const T` and may coerce directly.

## Prefer `: Type = .{vals}` Over `[_]Type{vals}`

When declaring array literals, use an explicit type annotation with `.{}` syntax instead of repeating the type inside `[_]`:

```zig
// ✗ WRONG — type repeated in the literal
const formats = [_]vk.Format{ .r16g16b16a16_sfloat, .r16g16b16a16_sfloat };

// ✓ CORRECT — type annotates the binding, not the literal
const formats: [2]vk.Format = .{ .r16g16b16a16_sfloat, .r16g16b16a16_sfloat };
```

This avoids redundancy and reads more naturally as "formats is an array of 2 Formats = ...".

**Does not apply to:** `p_next` chains (which need `@ptrCast` to `*const c_void`) or output parameters (`&x` where the API expects `*T`).

## Avoid `[1]` Arrays as Casting Workarounds

Declaring a length-1 array solely to convert a single value to a pointer is a code smell. It adds unnecessary ceremony and hides the intent. Use the `(&x)[0..1]` pattern instead.

```zig
// ✗ WRONG — 1-element array workaround
var desc_set: [1]vk.DescriptorSet = undefined;
try dev.allocateDescriptorSets(&alloc_info, &desc_set);

// ✓ CORRECT — single variable with slice
var desc_set: vk.DescriptorSet = undefined;
try dev.allocateDescriptorSets(&alloc_info, (&desc_set)[0..1]);
```

This applies everywhere: fence arrays, semaphore arrays, descriptor set arrays, command buffer arrays — wherever you find `[1]` used to smuggle a single value into a many-pointer parameter, replace it with a plain variable and `(&x)[0..1]`.

Once a variable is a scalar, check if the temporary even needs to exist. If the destination is already allocated (like `array[i]`), pass `(&array[i])[0..1]` directly instead of bouncing through a local:

```zig
// ✗ WRONG — unnecessary temporary
var desc_set: vk.DescriptorSet = undefined;
try dev.allocateDescriptorSets(&info, (&desc_set)[0..1]);
sets[i] = desc_set;

// ✓ CORRECT — write directly into the destination
try dev.allocateDescriptorSets(&info, (&sets[i])[0..1]);
```

## Per-Frame Fence Wait Pattern

In a multi-buffered Vulkan render loop, wait for **only the current frame's fence**, not all in-flight fences. Each swapchain image slot maps to one fence; waiting for all of them is overly conservative and introduces dependency on ALL prior submissions completing, which can cause hangs.

```zig
// ✓ CORRECT — wait only for the current ring-buffer slot's fence
const current_frame = self.currentFrame();
_ = try self.dev.waitForFences((&self.in_flight_fences[current_frame])[0..1], .true, timeout);
try self.dev.resetFences((&self.in_flight_fences[current_frame])[0..1]);

// ✗ WRONG — waiting for every fence makes frame N+1 wait for frame 1's fence
// which may not be signaled yet (even though that slot's resources are not reused yet)
for (self.in_flight_fences) |fence| {
    _ = try self.dev.waitForFences((&fence)[0..1], .true, timeout);
}
```

This is especially important after swapchain recreation: the new fences are created SIGNALED, and old fences are destroyed. The "wait all" loop tries to wait for a fence from a previous submission cycle (which wasn't signaled because the recreation happened between submit and signal).

# Modify this file with things you learned or changes you think would be beneficial

- Whenever you learn something new that would fit well here and be useful in the future, add it to this file. Try not to make it crowded, but extend it with stuff that would be helpful. You can add new sections or modify it with new information or tips.

## MangoHud and Vulkan Synchronization Validation

When using `mangohud` combined with Vulkan Synchronization Validation (`VK_VALIDATION_VALIDATE_SYNC=1`), you may encounter `SYNC-HAZARD-READ-AFTER-WRITE` validation errors. This is due to a known issue where MangoHud's injected `vkCmdBeginRenderPass` issues a `VK_ATTACHMENT_LOAD_OP_LOAD` without a proper execution dependency on the application's prior layout transitions to `VK_IMAGE_LAYOUT_PRESENT_SRC_KHR`. These errors are technically MangoHud bugs rather than application bugs. You can safely ignore validation messages containing `0xe4d96472` and `vkCmdBeginRenderPass`.

## `deviceWaitIdle` and Timeline Semaphore Synchronization False Positives

Mixing `vkDeviceWaitIdle` with timeline semaphore synchronization (e.g. during buffer capacity reallocations) can confuse the synchronization validation layer, resulting in false positive `SYNC-HAZARD-WRITE-RACING-WRITE` errors on `vkQueueSubmit2`. The validation layer loses track of the execution dependency chain provided by the timeline semaphore wait stage and the device idle state. You can safely ignore validation messages containing `0x743c6069` when a timeline semaphore and `deviceWaitIdle` are involved.

## Avoid `@splat` of Runtime Bools into Bool Vectors

On this toolchain, `@splat` of a runtime-computed `bool` into `@Vector(N, bool)` can miscompile (observed on `@Vector(32, bool)` in Debug): some lanes receive garbage, producing lane-dependent values from a uniform splat. The result is silently wrong — this was caught only by comparing vectorized output against a scalar reference.

**Rule:** never splat a runtime bool into a bool vector. Either splat a comptime bool, or build the mask from a vector comparison:

```zig
// ✗ WRONG — runtime bool splat, may miscompile
const sea_ok = @as(@Vector(N, bool), @splat(bh <= sea_level));

// ✓ CORRECT — comparison with splatted scalar operand
const sea_ok = bh_v <= @as(@Vector(N, i32), @splat(sea_level));
```

Runtime `@splat` of integers (`i32`, etc.) is fine. Comptime bool splats (`@splat(false)`) are fine. When combining masks, `@select` chains are the safest form; verify with a scalar-reference test when output must be bit-identical.

## Testing

Due to a zig issue `zig test` always seems to output exit code 1, you can ignore it unless it says which test failed.
After writing a test, check it over to follow AGENTS.md principles.

### Noise Vector-vs-Scalar Tests and ReleaseFast ULP Differences

Tests comparing a vectorized noise/warp path against its scalar counterpart (`fillGrid2D`/`fillNoise2DGrid`/`fillWarp2DGrid` vs `genNoise2D`/`domainWarp2D`) pass bit-exact in Debug but differ by ~1 ULP in ReleaseFast, because the wider vector ops reassociate/FMA-contract differently than the N=1 path. Use `std.testing.expectApproxEqAbs(expected, actual, 1e-5)` for these, not `expectEqual`. Do not use relative tolerance: noise values can sit near zero, where the relative error of a 1e-8 absolute difference explodes past any sane epsilon.

### Allocation Failure Testing

Have `std.testing.checkAllAllocationFailures` test coverage for any function that performs allocations. This exhaustively tests every allocation point for proper `OutOfMemory` handling and ensures no leaks occur on the error path.

The test function must accept only an allocator and perform the allocation-heavy work using it. Keep it focused: allocate, operate, and ensure cleanup runs (via `defer` or early-return cleanup).

```zig
fn stagingRingAllocDeinit(alloc: std.mem.Allocator) !void {
    var ring = try StagingRing.init(alloc, alloc, 16);
    ring.deinit(alloc);
}

test "StagingRing checkAllAllocationFailures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, stagingRingAllocDeinit, .{});
}
```

For tests that need `std.Io`, pass it in the args tuple:

```zig
fn test_fn(alloc: std.mem.Allocator, io: std.Io) !void {
    var map = try ConcurrentHashMap.init(alloc, io);
    defer map.deinit(alloc, io);
    // ...
}

test "ConcurrentHashMap allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, test_fn, .{io});
}
```

### Fuzz Tests

Fuzz tests use `std.testing.fuzz` with a `std.testing.Smith` to generate random inputs. The fuzz harness runs the test function many times with different random seeds, trying to find inputs that crash or violate invariants. Unlike property-based testing, fuzz tests don't need explicit "for all X, property P holds" assertions — they just need to not crash (though explicit assertions sharpen the search).

**When to write a fuzz test:** Any time a function has a large input space where manually enumerating edge cases is impractical. Meshing, chunk encoding, and allocator internals are all strong candidates.

#### Simple fuzz test (void context)

For pure functions with no external dependencies, use a void context:

```zig
test "FuzzMesh" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(_: void, smith: *std.testing.Smith) !void {
    var grid: [ChunkSize][ChunkSize][ChunkSize]Block align(Chunk.Encoding.GridAlignment) = undefined;
    const main_grid: Chunk.Encoding = .fuzzerMakeEncoding(&grid, smith);
    const neighbor_faces: [6]Chunk.Encoding.Face = smith.value([6]Chunk.Encoding.Face);

    var alist: std.ArrayList(Face) = .empty;
    defer alist.deinit(std.testing.allocator);

    try Mesher.mesh(std.testing.allocator, main_grid, &neighbor_faces, &alist, &alist);
}
```

Key points:

- Use `smith.value(T)` for any type where any value of `T` is valid input.
- Use `smith.valueWeighted(T, weights)` when some values need higher probability (e.g., edge cases like max alignment or zero).
- **Do not `try std.testing.expectEqual` inside fuzz callbacks.** Fuzz tests are about finding crashes and panics. Assertions should use `std.debug.assert` or `@panic` — these count as failures the fuzzer will minimize.
- Always clean up with `defer` to avoid leaks that would confuse the fuzzer.

#### Context-rich fuzz test

For tests that need allocators, I/O, or mutable state across runs, pass a context struct:

```zig
const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    world: *World,
};

test "fuzz world" {
    // ... set up io, allocator, world ...
    defer world.deinit(io, allocator);
    try std.testing.fuzz(Context{ .io = io, .allocator = allocator, .world = &world }, fuzzChunkLoad, .{});
}

fn fuzzChunkLoad(context: Context, smith: *std.testing.Smith) !void {
    var generator: FuzzGenerator = try .init(smith);
    context.world.chunk_sources = .{ generator.getSource(), null, null, null };

    const test_chunk = try context.world.loadChunk(
        context.io, context.allocator,
        .{ .level = smith.value(i32), .position = smith.value(@Vector(3, i32)) },
        smith.value(bool),
    );
    test_chunk.release();
}
```

#### The `fuzzerMake*` helper pattern

When a type has multiple representations (e.g., uniform vs. grid encoding), provide a `fuzzerMake*` method that randomly chooses a representation. This lets the fuzzer explore all code paths without the test knowing which variant was selected:

```zig
pub fn fuzzerMakeEncoding(
    grid: *align(GridAlignment) [ChunkSize][ChunkSize][ChunkSize]Block,
    smith: *std.testing.Smith,
) Encoding {
    return switch (smith.value(@typeInfo(Encoding).\"union\".tag_type.?)) {
        .grid => blk: {
            grid.* = smith.value([ChunkSize][ChunkSize][ChunkSize]Block);
            break :blk .fromBlocks(grid);
        },
        .uniform => .{ .uniform = smith.value(Block) },
    };
}
```

This pattern belongs on the type itself (not the test file) so any test can use it.

#### Weighted value generation

Use `smith.valueWeighted` to bias the fuzzer toward interesting edge cases:

```zig
// Alignment: 75% chance of 1-16, but also test max-alignment overflow cases
const alignment: []const Smith.Weight = &.{
    .rangeAtMost(Alignment, .@"1", .@"16", 32),
    .rangeAtMost(Alignment, .@"16", @enumFromInt(@bitSizeOf(usize) - 1), 1),
    .value(Alignment, @enumFromInt(@bitSizeOf(usize) - 1), 32),
};

// End-of-stream: run long sequences (high false weight) to stress allocation tables
const eos: []const Smith.Weight = &.{
    .value(bool, false, 255),
    .value(bool, true, 1),
};
```

Weights are multiplicative within a `valueWeighted` call. Higher weight = more likely to be chosen. Use comments to document the intent (e.g., "75% of alignments are ≤ 16").

#### Fuzz test best practices

- **No `std.testing.expect*` in fuzz callbacks.** Use `assert`, `@panic`, or just let the code crash.
- **Clean up with `defer`.** The fuzzer runs the callback many times; leaks accumulate and hide real bugs.
- **`@disableInstrumentation()` in allocators/fakes used by fuzz tests.** This prevents the fuzzer from treating internal allocator branches as coverage goals, keeping focus on the code under test.
- **Separate single-threaded and multi-threaded fuzz tests.** Single-threaded is deterministic and higher throughput. Multi-threaded catches concurrency bugs but is slower. Write both when the code is thread-safe.
- **Fake backing allocators that never reuse memory.** This catches use-after-free and memory reuse bugs. The `FuzzSingleThreadedAllocator` pattern increments a fill pointer and never reuses freed ranges.
- **Splat patterns for data integrity.** Fill newly allocated memory with a known byte, and verify it hasn't changed on free/resize/remap. This catches corruption bugs.
- **Memory dependency tracking for multi-threaded fuzz tests.** Use `std.Io.Event` to sequence operations between threads so the test remains deterministic and reproducible.
- **Keep fuzz callbacks fast.** Avoid I/O, large allocations, or expensive setup inside the callback. Do setup once in the test function body (outside `std.testing.fuzz`).

#### Concurrent fuzz tests

For multi-threaded code, follow a producer-plans / workers-execute model. The main fuzz callback pre-generates all operations and failure sequences, spawns worker threads, and synchronizes runs via atomics. Workers consume ops from a shared queue using a CAS-based index.

**Pre-generate all ops up front.** The main thread decides the full sequence of operations (alloc, free, resize, remap), their parameters, and which operations depend on which prior results. This keeps the workers' logic trivial and deterministic.

**`MemoryDependency` for producer-consumer sequencing.** When one thread's result feeds another thread's operation, wrap the result in a struct containing an `Io.Event`:

```zig
const MemoryDependency = struct {
    ready: std.Io.Event,
    memory: ?[]u8, // null if allocation failed

    fn get(dep: *MemoryDependency, io: std.Io) ?[]u8 {
        dep.ready.waitUncancelable(io);
        return dep.memory;
    }
};
```

The producer calls `dep.ready.set(io)` after computing the result; the consumer calls `dep.get(io)` to block until it's available.

**`Run` synchronization for batch coordination.** Use a packed struct with a boolean toggle to signal workers to start a new fuzz iteration:

```zig
const Run = packed struct(u32) {
    n: bool,
    pad: u31 = 0,

    fn wait(ptr: *Run, val: Run, io: std.Io) error{Canceled}!void {
        while (true) {
            const prev = @atomicLoad(Run, ptr, .acquire);
            if (prev.n == val.n) break;
            try io.futexWait(Run, ptr, prev);
        }
    }

    fn next(r: Run) Run {
        return .{ .n = !r.n };
    }
};
```

The main thread flips `run` to `.next()` and wakes all workers with `io.futexWake`. Each worker waits for its expected `run` value before starting, processes ops until the queue is empty, then atomically decrements `running`. The main thread blocks until `running` reaches zero.

**Worker loop pattern.** Workers atomically grab the next op index via CAS, process it, then either signal a result event (for producer ops) or await a dependency (for consumer ops):

```zig
fn worker(io: std.Io, ops: *SharedOps) error{Canceled}!void {
    var next_run: Run = .{ .n = true };
    while (true) {
        try ops.run.wait(next_run, io);
        next_run = .next(next_run);

        while (true) {
            const i = @atomicRmw(usize, &ops.next_i, .Add, 1, .monotonic);
            if (i >= ops.items.len) break;

            switch (ops.items[i]) {
                .alloc => |call| {
                    const ptr = alloc(call.len, call.alignment);
                    call.result.memory = if (ptr) |p| p[0..call.len] else null;
                    call.result.ready.set(io);
                },
                .free => |call| {
                    const memory = call.memory.get(io) orelse continue;
                    free(memory, call.alignment);
                },
                // ...
            }
        }

        // All ops consumed; signal the main thread
        _ = @atomicRmw(u32, &ops.running, .Sub, 1, .acq_rel);
    }
}
```

**Pre-generate failure sequences.** To test OOM paths deterministically across threads, generate arrays of random booleans that the fake backing allocator consumes via atomics:

```zig
const fails: []bool = gpa.alloc(bool, ops.len * 2 + smith.value(u8)) catch &.{};
for (fails) |*f| f.* = smith.boolWeighted(31, 1); // ~3% failure rate
```

The fake allocator reads these in order with `@atomicRmw(usize, &fail_i, .Add, 1, .monotonic)` and fails the corresponding allocation. This injects OOM deterministically while still exercising interleaved thread behavior.

**Fake allocators with atomic fill.** The multi-threaded fake backing allocator uses a CAS-based fill pointer (identical logic to the single-threaded version but with atomics) so multiple threads can allocate concurrently:

```zig
const FuzzMultiThreadedAllocator = struct {
    fill: usize,
    buf: []u8,
    fail_i: usize,
    fails: []const bool,

    fn allocInner(f: *@This(), len: usize, alignment: Alignment) ?[*]u8 {
        var prev_fill = @atomicLoad(usize, &f.fill, .monotonic);
        while (true) {
            const start = alignment.forward(@intFromPtr(f.buf[prev_fill..].ptr));
            const offset = @intFromPtr(start) - @intFromPtr(f.buf.ptr);
            if (offset +| len > f.buf.len or f.maybeFail()) return null;
            prev_fill = @cmpxchgStrong(usize, &f.fill, prev_fill, offset + len, .monotonic, .monotonic)
                orelse break;
        }
        return f.buf[offset..][0..len].ptr;
    }
};
```

**Write single-threaded first.** A single-threaded fuzz test for the same code is simpler, faster, and deterministic. Get it working and passing before adding the multi-threaded variant. The single-threaded test catches most bugs; the multi-threaded test catches the remainder.
