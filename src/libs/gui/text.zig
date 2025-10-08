const std = @import("std");
const TrueType = @import("TrueType");
const gl = @import("gl");
///hashmap of diffrent fonts
var fonts: ?std.AutoHashMap(u32, Font) = null;
var fontID: u32 = 0;
var isinit: bool = false;
//
var textShaderProgram: c_uint = undefined;
var textColorLocation: c_int = undefined;
var vertexArray: c_uint = undefined;
var elementBuffer: c_uint = undefined;
var arrayBuffer: c_uint = undefined;
//

///requires a valid opengl context
pub fn init() void { //TODO deinit and unload font
    std.debug.assert(!isinit);
    const vertex_shader_source = @embedFile("TextVertexShader.vert");
    const fragment_shader_source = @embedFile("TextFragmentShader.frag");
    const vertex_shader = gl.CreateShader(gl.VERTEX_SHADER);
    gl.ShaderSource(vertex_shader, 1, @ptrCast(&vertex_shader_source), null);
    gl.CompileShader(vertex_shader);

    const fragment_shader = gl.CreateShader(gl.FRAGMENT_SHADER);
    gl.ShaderSource(fragment_shader, 1, @ptrCast(&fragment_shader_source), null);
    gl.CompileShader(fragment_shader);

    const shader_program = gl.CreateProgram();
    gl.AttachShader(shader_program, vertex_shader);
    gl.AttachShader(shader_program, fragment_shader);
    gl.LinkProgram(shader_program);
    var elinkstatus: c_int = undefined;
    gl.GetProgramiv(shader_program, gl.LINK_STATUS, @ptrCast(&elinkstatus));
    if (elinkstatus == gl.FALSE) {
        var vsbuffer: [1000]u8 = undefined;
        var fsbuffer: [1000]u8 = undefined;
        var plog: [1000]u8 = undefined;
        gl.GetShaderInfoLog(vertex_shader, 1000, null, &vsbuffer);
        gl.GetShaderInfoLog(fragment_shader, 1000, null, &fsbuffer);
        gl.GetProgramInfoLog(shader_program, 1000, null, &plog);
        std.debug.panic("{s}\n\n{s}\n\n{s}", .{ vsbuffer, fsbuffer, plog });
    }
    gl.DeleteShader(vertex_shader);
    gl.DeleteShader(fragment_shader);

    textShaderProgram = shader_program;

    textColorLocation = gl.GetUniformLocation(shader_program, "textColor");
    LoadFacebuffer();

    isinit = true;
}

fn LoadFacebuffer() void {
    gl.GenVertexArrays(1, @ptrCast(&vertexArray));
    gl.BindVertexArray(vertexArray);

    gl.GenBuffers(1, @ptrCast(&arrayBuffer));
    gl.BindBuffer(gl.ARRAY_BUFFER, arrayBuffer);
    gl.BufferData(gl.ARRAY_BUFFER, @sizeOf(f32) * 6 * 4, null, gl.DYNAMIC_DRAW);

    gl.EnableVertexAttribArray(0);
    gl.VertexAttribPointer(0, 4, gl.FLOAT, gl.FALSE, 4 * @sizeOf(f32), 0);
}

///loads and saves a font. allocations must remain until all fonts are deinited
pub fn loadFont(fontBytes: []const u8, pixelHeight: f32, allocator: std.mem.Allocator) !u32 {
    std.debug.assert(isinit);
    var font: Font = undefined;
    if (TrueType.stbtt_InitFont(&font.font, @ptrCast(fontBytes), 0) == 0) return error.FontLoading;
    const scale = TrueType.stbtt_ScaleForPixelHeight(&font.font, pixelHeight);
    font.characters = .init(allocator);
    gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1);
    std.log.debug("font has {d} glyphs...\n", .{font.font.numGlyphs});
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    for (0..256) |index| { //load first 256 glyphs
        var width: c_int = undefined;
        var height: c_int = undefined;
        var xoff: c_int = undefined;
        var yoff: c_int = undefined;

        const bitmap = TrueType.stbtt_GetCodepointBitmap(&font.font, scale, scale, @intCast(index), &width, &height, &xoff, &yoff);
        defer TrueType.stbtt_FreeBitmap(bitmap, null);
        const char: Character = .{
            .width = width,
            .height = height,
            .xoff = xoff,
            .yoff = yoff,
            .texture = undefined,
        };
        gl.GenTextures(1, @ptrCast(@constCast(&char.texture)));
        gl.BindTexture(gl.TEXTURE_2D, char.texture);
        gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RED, width, height, 0, gl.RED, gl.UNSIGNED_BYTE, bitmap);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        std.debug.print("char: {any}\n", .{char});
        try font.characters.put(@intCast(index), char);
    }
    if (fonts == null) fonts = std.AutoHashMap(u32, Font).init(allocator);
    try fonts.?.put(fontID, font);
    fontID += 1;
    return fontID - 1; //-1 to get the id used
}

const Character = struct {
    width: c_int,
    height: c_int,
    xoff: c_int,
    yoff: c_int,
    texture: c_uint,
};
const Font = struct {
    font: TrueType.stbtt_fontinfo,
    characters: std.AutoHashMap(u32, Character),
};

pub fn RenderText(fontid: u32, text: []const u8, startx: f32, y: f32, scale: f32, color: [3]f32) !void {
    // activate corresponding render state
    gl.UseProgram(textShaderProgram);
    gl.Uniform3f(textColorLocation, color[0], color[1], color[2]);
    gl.BindVertexArray(vertexArray);
    const font = fonts.?.get(fontid) orelse return error.NoFontFound;
    // iterate through all characters
    var x: f32 = startx;
    for (0..text.len) |i| {
        //     const nextchar = if (i < text.len - 1) TrueType.stbtt_FindGlyphIndex(&font.font, @intCast(text[i + 1])) else null;
        const ch = font.characters.get(@intCast(text[i])) orelse return error.NoChar; //TODO UTF-8 and dont panic if char is not found
        const xpos: f32 = x + @as(f32, @floatFromInt(ch.xoff)) * scale;
        const ypos: f32 = y - @as(f32, @floatFromInt((ch.height - ch.yoff))) * scale;

        const w: f32 = @as(f32, @floatFromInt(ch.width)) * scale;
        const h: f32 = @as(f32, @floatFromInt(ch.height)) * scale;
        // update VBO for each character
        const vertices: [6][4]f32 = .{
            .{ xpos, ypos + h, 0.0, 0.0 },
            .{ xpos, ypos, 0.0, 1.0 },
            .{ xpos + w, ypos, 1.0, 1.0 },

            .{ xpos, ypos + h, 0.0, 0.0 },
            .{ xpos + w, ypos, 1.0, 1.0 },
            .{ xpos + w, ypos + h, 1.0, 0.0 },
        };

        // render glyph texture over quad
        gl.BindTexture(gl.TEXTURE_2D, ch.texture);
        // update content of VBO memory
        gl.BindBuffer(gl.ARRAY_BUFFER, arrayBuffer);
        gl.BufferSubData(gl.ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
        gl.BindBuffer(gl.ARRAY_BUFFER, 0);
        // render quad
        gl.DrawArrays(gl.TRIANGLES, 0, 6);
        // now advance cursors for next glyph (note that advance is number of 1/64 pixels)
        var advanceWidth: c_int = undefined;
        var leftSideBearing: c_int = undefined;
        TrueType.stbtt_GetCodepointHMetrics(&font.font, text[i], @ptrCast(&advanceWidth), @ptrCast(&leftSideBearing));
        std.debug.print("adv: {any}\n", .{advanceWidth});
        x += @as(f32, @floatFromInt(advanceWidth >> 4)) * scale; //TODO fix everything

    }
    gl.BindVertexArray(0);
    gl.BindTexture(gl.TEXTURE_2D, 0);
}
