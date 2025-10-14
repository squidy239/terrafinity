const std = @import("std");
const TrueType = @import("TrueType");
const gl = @import("gl");
const ztracy = @import("root").ztracy;
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

pub fn deinit() void {
    std.debug.assert(isinit);
    gl.DeleteVertexArrays(1, @ptrCast(&vertexArray));
    gl.DeleteBuffers(1, @ptrCast(&arrayBuffer));
    gl.DeleteProgram(textShaderProgram);
    isinit = false;
}

fn LoadFacebuffer() void {
    gl.GenVertexArrays(1, @ptrCast(&vertexArray));
    gl.BindVertexArray(vertexArray);

    gl.GenBuffers(1, @ptrCast(&arrayBuffer));
    gl.BindBuffer(gl.ARRAY_BUFFER, arrayBuffer);
    gl.BufferData(gl.ARRAY_BUFFER, @sizeOf(f32) * 6 * 2, null, gl.DYNAMIC_DRAW);

    gl.EnableVertexAttribArray(0);
    gl.VertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, 2 * @sizeOf(f32), 0);
}

pub const Font = struct {
    fontisinit: bool,
    font: TrueType.stbtt_fontinfo,
    scale: f32,
    characters: std.AutoHashMap(u32, Character), //TODO use a Cache

    const Character = struct {
        width: c_int,
        height: c_int,
        xoff: c_int,
        yoff: c_int,
        texture: c_uint,
        x1: c_int,
        x2: c_int,
        y1: c_int,
        y2: c_int,
        advanceWidth: c_int,
        leftSideBearing: c_int,
    };
    ///loads and saves a font
    ///must be called in a valid opengl context
    ///loadRanges it the ranges of charactors to load, if it is null this will load the first 256 unicode charactors
    pub fn load(fontBytes: []const u8, pixelHeight: f32, loadRanges: ?[][2]u32, allocator: std.mem.Allocator) !@This() {
        std.debug.assert(isinit);
        var font: @This() = undefined;
        if (TrueType.stbtt_InitFont(&font.font, @ptrCast(fontBytes), 0) == 0) return error.FontLoading;
        const scale = TrueType.stbtt_ScaleForPixelHeight(&font.font, pixelHeight);
        font.scale = scale;
        font.characters = .init(allocator);
        gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1);
        std.log.debug("font has {d} glyphs...\n", .{font.font.numGlyphs});
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        const defaultRange = [_][2]u32{
            .{ 0, 256 },
        };
        const ranges = loadRanges orelse defaultRange[0..];
        for (ranges) |range| {
            for (range[0]..range[1]) |codepoint| { //load first 256 glyphs
                _ = try LoadGlyph(&font, @intCast(codepoint));
            }
        }
        font.fontisinit = true;
        return font;
    }

    pub fn LoadGlyph(self: *@This(), codepoint: c_int) !Character {
        var width: c_int = undefined;
        var height: c_int = undefined;
        var xoff: c_int = undefined;
        var yoff: c_int = undefined;
        var cx1: c_int = undefined;
        var cx2: c_int = undefined;
        var cy1: c_int = undefined;
        var cy2: c_int = undefined;
        var advanceWidth: c_int = undefined;
        var leftSideBearing: c_int = undefined;
        const index = TrueType.stbtt_FindGlyphIndex(&self.font, @intCast(codepoint));
        TrueType.stbtt_GetGlyphBitmapBox(&self.font, index, self.scale, self.scale, &cx1, &cy1, &cx2, &cy2);
        TrueType.stbtt_GetGlyphHMetrics(&self.font, index, @ptrCast(&advanceWidth), @ptrCast(&leftSideBearing));
        const bitmap = TrueType.stbtt_GetGlyphBitmap(&self.font, self.scale, self.scale, index, &width, &height, &xoff, &yoff);
        defer TrueType.stbtt_FreeBitmap(bitmap, null);
        var char: Character = .{
            .width = width,
            .height = height,
            .xoff = xoff,
            .yoff = yoff,
            .texture = undefined,
            .x1 = cx1,
            .x2 = cx2,
            .y1 = cy1,
            .y2 = cy2,
            .advanceWidth = advanceWidth,
            .leftSideBearing = leftSideBearing,
        };
        gl.GenTextures(1, @ptrCast(@constCast(&char.texture)));
        gl.BindTexture(gl.TEXTURE_2D, char.texture);
        gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RED, width, height, 0, gl.RED, gl.UNSIGNED_BYTE, bitmap);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        try self.characters.put(@intCast(codepoint), char);
        return char;
    }

    ///must be called in a valid opengl context
    pub fn deinit(self: *@This()) void {
        std.debug.assert(self.fontisinit);
        var charit = self.characters.valueIterator();
        while (charit.next()) |char| {
            gl.DeleteTextures(1, @ptrCast(&char.texture));
        }
        self.characters.deinit();
        self.fontisinit = false;
    }
};

pub const Text = struct {
    allocator: std.mem.Allocator,
    font: *Font,
    color: [4]f32,
    scale: union(enum) {
        ///an absolute unit of text size
        absolute: f32,
        ///a unit of text size relative to the screen height
        relative: f32,
    },
    lineSpacing: f32 = 1.0,
    ///text is UTF-8 encoded, must be owned by the Text's allocator
    text: ?[]u8,
    ///the Y position of the bottom of the first line of the text
    startY: f32,
    startX: f32,
    ///copies the input text, TODO calculates line breaks
    pub fn SetText(self: *@This(), text: []const u8) !void {
        const oldText = self.text;
        self.text = try self.allocator.dupe(u8, text);
        if (oldText != null) self.allocator.free(oldText.?);
    }

    pub fn free(self: *@This()) void {
        self.allocator.free(self.text orelse return);
    }

    pub fn RenderText(self: *@This(), screen_dimensions: [2]u32) void {
        const drawText = ztracy.ZoneNC(@src(), "DrawText", 24342);
        defer drawText.End();
        if (self.text == null) return;
        gl.UseProgram(textShaderProgram);
        gl.Uniform4f(textColorLocation, self.color[0], self.color[1], self.color[2], self.color[3]);
        gl.BindVertexArray(vertexArray);
        const font = self.font;
        std.debug.assert(font.fontisinit);

        var x: f32 = self.startX;
        var y: f32 = self.startY;
        const hw = @as(f32, @floatFromInt(screen_dimensions[1])) / @as(f32, @floatFromInt(screen_dimensions[0]));
        const textScale: f32 = switch (self.scale) {
            .absolute => 0.01 * (self.scale.absolute / @as(f32, @floatFromInt(screen_dimensions[1]))),
            .relative => 0.0001 * self.scale.relative,
        };
        var textIter = std.unicode.Utf8Iterator{
            .bytes = self.text.?,
            .i = 0,
        };
        
        while (textIter.nextCodepoint()) |codepoint| {
            const ch = font.characters.get(@intCast(codepoint)) orelse font.LoadGlyph(@intCast(codepoint)) catch |err| {
                std.debug.panic("err loading charactor: {any}\n", .{err});
            };
            //handle whitespace
            switch (codepoint) {
                '\n' => {
                    x = self.startX;
                    y -= font.scale * textScale * 1000.0 * self.lineSpacing;
                    continue;
                },
                '\t' => {
                    //advance 4 spaces
                    x += @as(f32, @floatFromInt(ch.advanceWidth)) * font.scale * textScale * hw * 4;
                    continue;
                },
                '\r' => {
                    x = self.startX;
                    continue;
                },
                else => {},
            }

            const xpos: f32 = x + @as(f32, @floatFromInt(ch.xoff)) * textScale * hw;
            const ypos: f32 = y - (@as(f32, @floatFromInt(ch.yoff + ch.y2 - ch.y1)) * textScale);

            const w: f32 = @as(f32, @floatFromInt(ch.width)) * textScale * hw;
            const h: f32 = @as(f32, @floatFromInt(ch.height)) * textScale;

            const next_codepoint = std.mem.bytesToValue(u21, textIter.peek(1));
            const kernAdvance = TrueType.stbtt_GetCodepointKernAdvance(&font.font, codepoint, next_codepoint);

            DrawCharacter(xpos, ypos, w, h, ch.texture);
            x += @as(f32, @floatFromInt(ch.advanceWidth + kernAdvance)) * font.scale * textScale * hw;
        }
        gl.BindVertexArray(0);
        gl.BindTexture(gl.TEXTURE_2D, 0);
    }

    fn DrawCharacter(xpos: f32, ypos: f32, w: f32, h: f32, texture: c_uint) void {
        const vertices: [6][2]f32 = .{
            .{ xpos, ypos + h},
            .{ xpos, ypos},
            .{ xpos + w, ypos},

            .{ xpos, ypos + h},
            .{ xpos + w, ypos},
            .{ xpos + w, ypos + h},
        };
        

        // render glyph texture over quad
        gl.BindTexture(gl.TEXTURE_2D, texture);
        gl.BindBuffer(gl.ARRAY_BUFFER, arrayBuffer);
        gl.BufferSubData(gl.ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
        gl.BindBuffer(gl.ARRAY_BUFFER, 0);
        // render quad
        gl.DrawArrays(gl.TRIANGLES, 0, 6);
    }
};
