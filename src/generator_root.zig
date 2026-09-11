//! Build entry point for every generator shared library; one compile per generator via the `generator_select` option.
//! The root sits at `src/` so generators can use `..` relative imports for world code.
const select = @import("generator_select");

const Generator = switch (select.generator) {
    .terrain => @import("world/generators/Terrain.zig"),
    .planet => @import("world/generators/Planet.zig"),
    .voxelgame => @import("world/generators/Voxelgame.zig"),
    .fractal => @import("world/generators/Fractal.zig"),
    .sponge => @import("world/generators/Sponge.zig"),
};

comptime {
    _ = Generator.generator_api_vtable;
}
