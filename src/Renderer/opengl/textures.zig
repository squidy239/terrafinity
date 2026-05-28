const std = @import("std");

const gl = @import("gl");
const zigimg = @import("zigimg");

const Block = @import("../../main.zig").Block;

//TODO redo this

///must be run in a valid opengl context
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
    var it = std.Io.Dir.iterate(textures_path);
    var i: usize = 0;
    while (try it.next(io)) |image| {
        switch (image.kind) {
            .file => {
                if (image.kind == .file and ((std.mem.find(u8, image.name, keyword) != null))) {
                    std.debug.assert(i < textures.values.len); //should never happen because invalid textures are skipped
                    var loadedImg = try zigimg.Image.fromFile(allocator, io, try textures_path.openFile(io, image.name, .{}), &read_buffer);
                    errdefer loadedImg.deinit(allocator);
                    try loadedImg.convert(allocator, .rgba32);
                    if (loadedImg.width != resolution[0] or loadedImg.height != resolution[1]) return error.InvalidTextureResolution;
                    const blockName = image.name[0 .. std.mem.findScalar(u8, image.name, '.') orelse image.name.len];
                    const blockType = std.meta.stringToEnum(Block, blockName);
                    if (blockType == null) {
                        std.log.warn("Invalid block type: {s}\n", .{blockName});
                        loadedImg.deinit(allocator);
                        continue;
                    }
                    std.log.debug("loaded texture: {any}\n", .{blockType.?});
                    textures.put(blockType.?, loadedImg);
                    i += 1;
                }
            },
            else => {},
        }
    }
    var gltexarrayid: c_uint = undefined;
    gl.GenTextures(1, @ptrCast(&gltexarrayid));
    gl.ActiveTexture(gl.TEXTURE0);
    gl.BindTexture(gl.TEXTURE_2D_ARRAY, gltexarrayid);
    gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
    gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_S, gl.REPEAT);
    gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_T, gl.REPEAT);
    gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_R, gl.CLAMP_TO_EDGE);
    gl.TexImage3D(gl.TEXTURE_2D_ARRAY, 0, gl.RGBA, @intCast(resolution[0]), @intCast(resolution[1]), @intCast(textures.values.len), 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    const indexer = std.enums.EnumIndexer(Block);
    for (0..textures.values.len) |itt| {
        const blockType = indexer.keyForIndex(itt);
        const texture = textures.get(blockType) orelse missing_texture;
        gl.TexSubImage3D(
            gl.TEXTURE_2D_ARRAY,
            0,
            0,
            0,
            @intCast(itt),
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
    return gltexarrayid;
}

fn allSquares(io: std.Io, allocator: std.mem.Allocator, textures_path: std.Io.Dir, keyword: ?[]const u8) ![2]usize {
    var it1 = std.Io.Dir.iterate(textures_path);
    var resolution: ?[2]usize = null;
    while (try it1.next(io)) |image| {
        if (image.kind == .file and (keyword == null or (std.mem.find(u8, image.name, keyword.?) != null))) {
            const cres = try getResolution(io, allocator, try textures_path.openFile(io, image.name, .{}));
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
    var it = std.fs.Dir.iterate(textures_path);
    var count: u32 = 0;
    while (try it.next()) |image| {
        if (image.kind == .file and (keyword == null or (std.mem.find(u8, image.name, keyword.?) != null))) count += 1;
    }
    return count;
}

fn getResolution(io: std.Io, allocator: std.mem.Allocator, texture: std.Io.File) ![2]usize {
    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var img = try zigimg.Image.fromFile(allocator, io, texture, &read_buffer);
    defer img.deinit(allocator);
    return [2]usize{ img.width, img.height };
}
