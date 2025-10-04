const std = @import("std");
const zigimg = @import("zigimg");
const gl = @import("gl");
const Block = @import("root").Block;
threadlocal var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;

///must be run in a valid opengl context
pub fn loadTextureArray(textures_path: std.fs.Dir, allocator: std.mem.Allocator) !c_uint {
    const keyword = ".png";
    const texture_count = try countFiles(textures_path, keyword);
    if (texture_count == 0) return error.NoTexturesFound;
    const resolution = try allSquares(textures_path, keyword);
    var textureArray = try allocator.alloc(zigimg.Image, texture_count);
    defer {
        for (textureArray) |*img| {
            img.deinit(allocator);
        }
        allocator.free(textureArray);
    }
    std.debug.print("count: {any}, resolution: {any}\n", .{ texture_count, resolution });
    var it = std.fs.Dir.iterate(textures_path);
    var i: usize = 0;
    while (try it.next()) |image| {
        switch (image.kind) {
            .file => {
                if (image.kind == .file and ((std.mem.indexOf(u8, image.name, keyword) != null))) {
                    std.debug.assert(i < texture_count);
                    var loadedImg = try zigimg.Image.fromFile(allocator, try textures_path.openFile(image.name, .{}), &read_buffer);
                    try loadedImg.convert(allocator, .rgba32);
                    std.debug.assert(loadedImg.width == resolution[0] and loadedImg.height == resolution[1]);
                    const blockName = image.name[0 .. std.mem.indexOfScalar(u8, image.name, '.') orelse image.name.len];
                    const blockType = std.meta.stringToEnum(Block, blockName);
                    if (blockType == null) {
                        std.log.warn("Invalid block type: {s}\n", .{blockName});
                        continue;
                    }
                    std.debug.print("loaded tex: {any}\n", .{blockType.?});
                    const index = @intFromEnum(blockType.?) - Block.invisibleBlocksAmount;
                    if (index >= texture_count) {
                        std.log.err("Texture index out of bounds: {d}\n", .{index});
                        return error.NotEnoughTextures;
                    }
                    textureArray[index] = loadedImg;
                    i += 1;
                }
            },
            else => {},
        }
    }
    if (i != texture_count) {
        std.log.err("Not enough textures loaded\n", .{});
        return error.NotEnoughTextures;
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
    gl.TexImage3D(gl.TEXTURE_2D_ARRAY, 0, gl.RGBA, @intCast(resolution[0]), @intCast(resolution[1]), @intCast(texture_count), 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    for (0..texture_count) |itt| {
        gl.TexSubImage3D(gl.TEXTURE_2D_ARRAY, 0, 0, 0, @intCast(itt), @intCast(resolution[0]), @intCast(resolution[1]), 1, gl.RGBA, gl.UNSIGNED_BYTE, @ptrCast(textureArray[itt].rawBytes()));
    }
    gl.GenerateMipmap(gl.TEXTURE_2D_ARRAY);
    gl.BindTexture(gl.TEXTURE_2D_ARRAY, 0);
    return gltexarrayid;
}

fn allSquares(textures_path: std.fs.Dir, keyword: ?[]const u8) ![2]usize {
    var it1 = std.fs.Dir.iterate(textures_path);
    var resolution: ?[2]usize = null;
    while (try it1.next()) |image| {
        if (image.kind == .file and (keyword == null or (std.mem.indexOf(u8, image.name, keyword.?) != null))) {
            const cres = try getResolution(try textures_path.openFile(image.name, .{}));
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
        if (image.kind == .file and (keyword == null or (std.mem.indexOf(u8, image.name, keyword.?) != null))) count += 1;
    }
    return count;
}

fn getResolution(texture: std.fs.File) ![2]usize {
    var fbuf: [1000000]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fbuf);
    const alloc = fba.allocator();
    var img = try zigimg.Image.fromFile(alloc, texture, &read_buffer);
    defer img.deinit(alloc);
    return [2]usize{ img.width, img.height };
}
