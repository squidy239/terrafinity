const std = @import("std");

const gl = @import("gl");
const zigimg = @import("zigimg");

const Block = @import("../../main.zig").Block;

// TODO: redo this

/// Must be run in a valid OpenGL context.
pub fn loadTextureArray(io: std.Io, textures_path: std.Io.Dir, allocator: std.mem.Allocator) !c_uint {
    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    const keyword = ".png";
    const resolution = try allSquares(io, allocator, textures_path, keyword);
    const missing_texture_pixels = try allocator.alloc(u8, resolution[0] * resolution[1] * 3);
    defer allocator.free(missing_texture_pixels);
    io.random(missing_texture_pixels);
    const missing_texture = try zigimg.Image.fromRawPixelsOwned(resolution[0], resolution[1], missing_texture_pixels, .rgb24);

    var textures: std.enums.EnumMap(Block, zigimg.Image) = .init(.{});
    defer {
        var it = textures.iterator();
        while (it.next()) |img| {
            img.value.deinit(allocator);
        }
    }
    std.log.info("texture resolution: {any}\n", .{resolution});
    var dir_it = std.Io.Dir.iterate(textures_path);
    var texture_index: usize = 0;
    while (try dir_it.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                if (std.mem.find(u8, entry.name, keyword) != null) {
                    std.debug.assert(texture_index < textures.values.len); // should never happen because invalid textures are skipped
                    var loaded_img = try zigimg.Image.fromFile(allocator, io, try textures_path.openFile(io, entry.name, .{}), &read_buffer);
                    errdefer loaded_img.deinit(allocator);
                    try loaded_img.convert(allocator, .rgba32);
                    if (loaded_img.width != resolution[0] or loaded_img.height != resolution[1]) return error.InvalidTextureResolution;
                    const block_name = entry.name[0 .. std.mem.findScalar(u8, entry.name, '.') orelse entry.name.len];
                    const block_type = std.meta.stringToEnum(Block, block_name);
                    if (block_type == null) {
                        std.log.warn("Invalid block type: {s}\n", .{block_name});
                        loaded_img.deinit(allocator);
                        continue;
                    }
                    std.log.debug("loaded texture: {any}\n", .{block_type.?});
                    textures.put(block_type.?, loaded_img);
                    texture_index += 1;
                }
            },
            else => {},
        }
    }
    var gl_tex_array_id: c_uint = undefined;
    gl.GenTextures(1, @ptrCast(&gl_tex_array_id));
    gl.ActiveTexture(gl.TEXTURE0);
    gl.BindTexture(gl.TEXTURE_2D_ARRAY, gl_tex_array_id);
    gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
    gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_S, gl.REPEAT);
    gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_T, gl.REPEAT);
    gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_R, gl.CLAMP_TO_EDGE);
    gl.TexImage3D(gl.TEXTURE_2D_ARRAY, 0, gl.RGBA, @intCast(resolution[0]), @intCast(resolution[1]), @intCast(textures.values.len), 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    const indexer = std.enums.EnumIndexer(Block);
    for (0..textures.values.len) |tex_idx| {
        const block_type = indexer.keyForIndex(tex_idx);
        const texture = textures.get(block_type) orelse missing_texture;
        gl.TexSubImage3D(
            gl.TEXTURE_2D_ARRAY,
            0,
            0,
            0,
            @intCast(tex_idx),
            @intCast(resolution[0]),
            @intCast(resolution[1]),
            1,
            gl.RGBA,
            gl.UNSIGNED_BYTE,
            texture.rawBytes().ptr,
        );
    }
    gl.GenerateMipmap(gl.TEXTURE_2D_ARRAY);
    gl.BindTexture(gl.TEXTURE_2D_ARRAY, 0);
    return gl_tex_array_id;
}

fn allSquares(io: std.Io, allocator: std.mem.Allocator, textures_path: std.Io.Dir, keyword: ?[]const u8) ![2]usize {
    var dir_it = std.Io.Dir.iterate(textures_path);
    var resolution: ?[2]usize = null;
    while (try dir_it.next(io)) |entry| {
        if (entry.kind == .file and (keyword == null or (std.mem.find(u8, entry.name, keyword.?) != null))) {
            const cres = try getResolution(io, allocator, try textures_path.openFile(io, entry.name, .{}));
            if (resolution == null) {
                resolution = cres;
            } else {
                if (resolution.?[0] != cres[0] or resolution.?[1] != cres[1]) {
                    return error.InconsistentTextureResolution;
                }
            }
        }
    }
    if (resolution.?[0] != resolution.?[1]) return error.TexturesNotSquare;
    return resolution.?;
}

fn countFiles(textures_path: std.fs.Dir, keyword: ?[]const u8) !u32 {
    var dir_it = std.fs.Dir.iterate(textures_path);
    var count: u32 = 0;
    while (try dir_it.next()) |entry| {
        if (entry.kind == .file and (keyword == null or (std.mem.find(u8, entry.name, keyword.?) != null))) count += 1;
    }
    return count;
}

fn getResolution(io: std.Io, allocator: std.mem.Allocator, texture: std.Io.File) ![2]usize {
    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var img = try zigimg.Image.fromFile(allocator, io, texture, &read_buffer);
    defer img.deinit(allocator);
    return [2]usize{ img.width, img.height };
}
