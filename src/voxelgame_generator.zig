//! Build entry point for the voxelgame generator shared library.
//! The module root must be `src/` so Voxelgame.zig can import the world code,
//! which forces the export functions to be analyzed and emitted.
const Voxelgame = @import("world/generators/Voxelgame.zig");

pub export fn voxelgame_generator_force_exports() void {
    _ = Voxelgame.generator_info;
    _ = Voxelgame.generator_config_default;
    _ = Voxelgame.generator_config_from_zon;
    _ = Voxelgame.generator_config_set_seeds;
    _ = Voxelgame.generator_create;
    _ = Voxelgame.generator_get_source;
}
