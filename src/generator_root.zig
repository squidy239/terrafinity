//! Build entry point for every generator shared library.
//! The module root must live at `src/` so the generator files under
//! `src/world/generators/` can use `..` relative imports for the world code.
//! `build.zig` compiles this same file once per generator, distinguishing them
//! with a `generator_select` option; the comptime switch selects which
//! generator to analyze. Each generator's own `comptime { @export(...) }`
//! block then emits its vtable into the resulting `.generator` library.
const select = @import("generator_select");

const Generator = switch (select.generator) {
    .terrain => @import("world/generators/Terrain.zig"),
    .planet => @import("world/generators/Planet.zig"),
    .voxelgame => @import("world/generators/Voxelgame.zig"),
};

comptime {
    _ = Generator.generator_api_vtable;
}
