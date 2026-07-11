# Agent Guide

## Commands
Use these full commands without modification after each change and ensure the play test runs without errors:

- normal build: `zig build`
- run and open to menu: `zig build run`
- run and open to a game: `export VK_LAYER_ENABLES=VK_VALIDATION_FEATURE_ENABLE_GPU_ASSISTED_EXT && export VK_VALIDATION_VALIDATE_SYNC=1 && zig build run -Dtest_play=[number of seconds to run, 5-10 is a good default for a short test]`
- run and open a game with thread sanitizer, this should be used instead of the regular test play when it works (not on nvidia drivers, test to see): `export VK_LAYER_ENABLES=VK_VALIDATION_FEATURE_ENABLE_GPU_ASSISTED_EXT && export VK_VALIDATION_VALIDATE_SYNC=1 && TSAN_OPTIONS="suppressions=tsan_suppressions.txt" zig build run -Dtest_play=10 -Dsanitize_thread=Normal`
- format code: `zig fmt .`

# Codebase Naming Conventions & Guidelines

This document outlines the strict naming conventions and core principles for this project. To maintain a clean, predictable, and highly readable codebase, we follow a precise set of rules primarily inspired by Zig's ecosystem.

When in doubt, rely on the core philosophy: **Meaning dictates casing.**

---

## Core Philosophy: Simplicity & Self-Documenting Code

- **Code must be self-documenting:** The structure, variable names, and logic should clearly communicate intent without relying on external explanations.
- **Comments are a last resort:** Only add comments when absolutely necessary to explain the *why* behind a non-obvious decision, complex algorithm, or temporary hack. Do not use comments to explain *what* the code is doing.
- **Prioritize elegance:** Code should be as simple and elegant as possible. Avoid clever tricks in favor of readable, straightforward implementations.

---

## Quick Reference Cheat Sheet

| Element | Casing Convention | Example |
| :--- | :--- | :--- |
| **Variables** | `snake_case` | `model_weights`, `is_active` |
| **Functions (Standard)** | `camelCase` | `trainModel(data: Dataset, epochs: u32)`, `parseData(input: []const u8)` |
| **Functions (Returns `type`)** | `PascalCase` (TitleCase) | `CreateGraphNode(comptime T: type)` |
| **Types & Aliases** | `PascalCase` (TitleCase) | `NeuralNetwork`, `Dataset` |
| **Namespaces** (0-field structs) | `snake_case` | `math_utils`, `tensor_ops` |
| **Files (Types)** | `PascalCase` (TitleCase) | `AttentionLayer.zig` |
| **Files (Namespaces)** | `snake_case` | `matrix_helpers.zig` |
| **Directories** | `snake_case` | `data_loaders/`, `utils/` |

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
- **Standard Callables:** If a function or method performs an action and returns a value, struct, or primitive, it must use **`camelCase`**. (*Examples:* `calculateLoss(predictions: Tensor, targets: Tensor)`, `forwardPass(input: Tensor)`, `optimizeWeights(learning_rate: f32)`)
- **Type-Generating Callables:** If a function or method is called to generate and return a `type`, it must use **`PascalCase`**. This signals to the reader that invoking this function resolves to a type definition. (*Examples:* `LinearLayer(comptime T: type)`, `CustomDataset(comptime T: type)`)

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
- **Types (Structs with fields):** If the file contains top-level fields (state/data), it represents a type and must use **`PascalCase`**. (*Example:* `ModelCheckpoint.zig`, `DataPipeline.zig`)
- **Namespaces (No fields):** If the file contains only functions, constants, or declarations (no top-level fields), it is a namespace and must use **`snake_case`**. (*Example:* `gpu_allocator.zig`, `math_constants.zig`)
- **Directories:** All directories must strictly use **`snake_case`**. (*Example:* `natural_language_processing/`, `core_engine/`)

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

# Modify this file with things you learned or changes you think would be beneficial
- Whenever you learn something new that would fit well here and be useful in the future, add it to this file. Try not to make it crowded, but extend it with stuff that would be helpful. You can add new sections or modify it with new information or tips.
