const std = @import("std");
const Block = @import("../main.zig").Block;

const gl = @import("gl");
const zigimg = @import("zigimg");

///must be run in a valid opengl context
pub fn loadTextureArray(textures_path: std.fs.Dir, allocator: std.mem.Allocator) !c_uint {
    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    const keyword = ".png";
    const resolution = try allSquares(textures_path, keyword);
    const missing_texture_pixels = try allocator.alloc(u8, resolution[0] * resolution[1] * 3);
    defer allocator.free(missing_texture_pixels);
    std.crypto.random.bytes(missing_texture_pixels);
    const missing_texture = try zigimg.Image.fromRawPixelsOwned(resolution[0], resolution[1], missing_texture_pixels, .rgb24);

    var textureArray = try allocator.alloc(?zigimg.Image, @typeInfo(Block).@"enum".fields.len);
    @memset(textureArray, null);
    defer {
        for (textureArray) |*img| {
            if (img.* == null) continue;
            img.*.?.deinit(allocator);
        }
        allocator.free(textureArray);
    }
    std.debug.print("texture resolution: {any}\n", .{resolution});
    var it = std.fs.Dir.iterate(textures_path);
    var i: usize = 0;
    while (try it.next()) |image| {
        switch (image.kind) {
            .file => {
                if (image.kind == .file and ((std.mem.indexOf(u8, image.name, keyword) != null))) {
                    std.debug.assert(i < textureArray.len); //should never happen because invalid textures are skipped
                    var loadedImg = try zigimg.Image.fromFile(allocator, try textures_path.openFile(image.name, .{}), &read_buffer);
                    errdefer loadedImg.deinit(allocator);
                    try loadedImg.convert(allocator, .rgba32);
                    if (loadedImg.width != resolution[0] or loadedImg.height != resolution[1]) return error.InvalidTextureResolution;
                    const blockName = image.name[0 .. std.mem.indexOfScalar(u8, image.name, '.') orelse image.name.len];
                    const blockType = std.meta.stringToEnum(Block, blockName);
                    if (blockType == null) {
                        std.log.warn("Invalid block type: {s}\n", .{blockName});
                        loadedImg.deinit(allocator);
                        continue;
                    }
                    std.debug.print("loaded texture: {any}\n", .{blockType.?});
                    const index = @intFromEnum(blockType.?);
                    std.debug.assert(index < textureArray.len);
                    textureArray[index] = loadedImg;
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
    gl.TexImage3D(gl.TEXTURE_2D_ARRAY, 0, gl.RGBA, @intCast(resolution[0]), @intCast(resolution[1]), @intCast(textureArray.len), 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    for (0..textureArray.len) |itt| {
        const textureData = (textureArray[itt] orelse missing_texture).rawBytes();
        gl.TexSubImage3D(gl.TEXTURE_2D_ARRAY, 0, 0, 0, @intCast(itt), @intCast(resolution[0]), @intCast(resolution[1]), 1, if (textureArray[itt] != null) gl.RGBA else gl.RGB, gl.UNSIGNED_BYTE, @ptrCast(textureData));
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
    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var fbuf: [100000]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fbuf);
    const alloc = fba.allocator();
    var img = try zigimg.Image.fromFile(alloc, texture, &read_buffer);
    defer img.deinit(alloc);
    return [2]usize{ img.width, img.height };
}
