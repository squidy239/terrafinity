//! Build entry point for the terrain generator shared library.
//! The module root must be `src/` so Terrain.zig can import the world code,
//! which forces the export functions to be analyzed and emitted.
const Terrain = @import("world/generators/Terrain.zig");

pub export fn terrain_generator_force_exports() void {
    _ = Terrain.generator_info;
    _ = Terrain.generator_config_default;
    _ = Terrain.generator_config_from_zon;
    _ = Terrain.generator_config_set_seeds;
    _ = Terrain.generator_create;
    _ = Terrain.generator_get_source;
}
