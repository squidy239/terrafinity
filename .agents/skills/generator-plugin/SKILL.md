---
name: generator-plugin
description: Runtime generator shared libraries (C-ABI vtable, generator_root module scope, adding a generator, ApiVersion bumps, config-tree ownership, widget IDs). Use when adding a generator, touching generator_api, generator config trees, or the config editor UI.
---

# Generator Plugins

Generators are `.so` plugins built from one shared root and `dlopen`ed at runtime (libc-linked Linux build). The exe embeds each built `.so` and writes it into `generators/` at startup — so only one game instance may run at a time (concurrent startup rewrites half-written plugins; `dlopen` segfaults or logs `failed to load generator ...: FileNotFound`).

## C-ABI boundary

- `pub export fn` / `@export` need a machine calling convention and cannot take auto-layout structs by value (`Allocator`, `Io`, slices, error unions). Everything crossing is a pointer, nullable pointer, or primitive.
- Pattern: one exported `extern struct` vtable of function pointers (`@export(&vtable, .{ .name = ... })`). Pointers cross as data with the native Zig convention, identical on both sides under one compiler. Errors cross as nullable pointers (`?*T`, null = failure).
- Types crossing the boundary (`generator_api.Spec`, `ConfigTree`, vtable structs) are ABI: never reshape without bumping `generator_api.ApiVersion` (minor for backward-compatible additions, major for breaking) and rebuilding every plugin.

## Module scope and registration

- A module's import scope is its root file's directory, so no per-generator root under `src/world/generators/`. One shared root `src/generator_root.zig` compiles once per generator, selected via the `generator_select` options module + comptime switch; each generator's `comptime { @export(...) }` block emits its vtable.
- Adding a generator = one `.kind` arm in `build.zig` (`GeneratorKind` + `generator_sources`) plus one `@import` arm in `generator_root.zig`. No per-generator shims. An unwired-but-finished generator is a bug, not dead code — register it.

## Config trees and editor UI

- `Spec` presentation fields (`label`, `description`) are borrowed from the loaded library; config keys/values/choice entries are owned by the config allocator. Keep the library loaded as long as its config tree is used.
- Every `Params` field keeps a declaration default (`.default` is `Params{}`) or old saved configs break; `loadConfig` returns `error.InvalidConfig` loudly instead of falling back. Superseded fields stay with `.skip = true` in `field_specs`.
- Widget IDs derive from the stable parameter path, never traversal order; pass `.id_extra` per param when one `@src()` line draws many. `dvui.dropdown` and other `*T` choice widgets mutate the pointed-to value during draw — capture `previous` first, never guard on the post-draw value.

## Verification

- Gates per the `verify-change` skill. Startup loads every generator, so a play test covers registration; use exclusive access (or a private `cwd`) to avoid the `./generators/` race.
