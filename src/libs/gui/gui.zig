const std = @import("std");
const gl = @import("gl");
const glfw = @import("glfw");
const zigimg = @import("root").zigimg;
const text = @import("text.zig");
var guiShaderProgram: c_uint = undefined;
var guiElementPositionLocation: c_int = undefined;
var guiElementSizeLocation: c_int = undefined;
var guiElementColorLocation: c_int = undefined;
var vertexArray: c_uint = undefined;
var elementBuffer: c_uint = undefined;
var arrayBuffer: c_uint = undefined;
var isinit: bool = false;

pub const Element = struct {
    allocator: std.mem.Allocator,
    screen_dimensions: [2]u32,
    width: f32,
    height: f32,
    pos: @Vector(2, f32),
    options: Options,
    children: ?[]Element,
    parent: ?*Element,
    isinit: bool = false,
    ///a position on the screen, x and y can be between 0 and 100
    pub const Position = struct {
        xPercent: f32 = 0.0,
        yPercent: f32 = 0.0,
        xPixels: f32 = 0.0,
        yPixels: f32 = 0.0,
    };

    pub const Size = struct {
        widthPercent: f32 = 0.0,
        heightPercent: f32 = 0.0,
        widthPixels: f32 = 0.0,
        heightPixels: f32 = 0.0,
    };

    pub const ElementBackground = union(enum) {
        solid: @Vector(4, f32),
    };

    pub const Options = struct {
        ///the position of the element. all units are added together
        position: Position = .{ .xPercent = 50, .yPercent = 50 },
        ///the size of the element. all units are added together
        size: Size = .{ .widthPercent = 100, .heightPercent = 100 },
        Background: ElementBackground = .{ .solid = .{ 1.0, 1.0, 1.0, 1.0 } },
        ///if this is false the element and its children will not be drawn and onHover and onDraw will not be called
        Visible: bool = true,
        ///onclick can be made by checking mouse status in this function. [2]f64 is mousePos from 0.0 to 1.0.
        ///last bool is false if it is being called after drawing so the options can be reset if needed
        ///update must be called after any modifications to the element
        onHover: ?*const fn (*Element, [2]f64, *glfw.Window, bool) void = null,
        ///gets called before drawing before onHover
        ///update must be called after any modifications to the element
        onDraw: ?*const fn (*Element, *glfw.Window) void = null,
    };
    ///if the element has children InitChildren must be called after this. children are copied with the allocator
    pub fn create(allocator: std.mem.Allocator, screen_dimensions: [2]u32, options: Options, children: ?[]const Element) !Element {
        return Element{
            .allocator = allocator,
            .screen_dimensions = screen_dimensions,
            .width = undefined,
            .height = undefined,
            .pos = undefined,
            .options = options,
            .children = if (children != null) try allocator.dupe(Element, children.?) else null,
            .parent = null,
            .isinit = false,
        };
    }
    //msut be called after creation on outermost element
    pub fn init(self: *@This()) void {
        std.debug.assert(!self.isinit);
        self.update(self.screen_dimensions);
        if (self.children) |children| {
            for (children) |*child| {
                child.parent = self;
                child.init();
            }
        }

        self.isinit = true;
    }

    ///requires a valid opengl context
    pub fn Draw(self: *@This(), screen_dimensions: [2]u32, window: *glfw.Window) void {
        std.debug.assert(self.isinit);
        std.debug.assert(isinit);
        if (!self.options.Visible) return;
        if (self.options.onDraw) |onDraw| onDraw(self, window);
        const screen_dimensions_float = @Vector(2, f64){ @floatFromInt(screen_dimensions[0]), @floatFromInt(screen_dimensions[1]) };
        var cursorPos = window.getCursorPos();
        cursorPos[0] = @min(@max(cursorPos[0], 0), screen_dimensions_float[0]);
        cursorPos[1] = @abs(screen_dimensions_float[1] - @min(@max(cursorPos[1], 0), screen_dimensions_float[1]));
        cursorPos = @Vector(2, f64){ cursorPos[0] / (screen_dimensions_float[0]), cursorPos[1] / (screen_dimensions_float[1]) };
        const bottomCorner = @Vector(2, f32){ self.pos[0] - (self.width * 0.5), self.pos[1] - (self.height * 0.5) };
        const topCorner = @Vector(2, f32){ self.pos[0] + (self.width * 0.5), self.pos[1] + (self.height * 0.5) };
        const inBottom = bottomCorner[0] < cursorPos[0] and bottomCorner[1] < cursorPos[1];
        const inTop = topCorner[0] > cursorPos[0] and topCorner[1] > cursorPos[1];

        if (inBottom and inTop and self.options.onHover != null) {
            self.options.onHover.?(self, cursorPos, window, true);
        }
        const cf = gl.IsEnabled(gl.CULL_FACE) != 0;
        const dt = gl.IsEnabled(gl.DEPTH_TEST) != 0;
        const bl = gl.IsEnabled(gl.BLEND) != 0;
        var blendSrc: c_uint = undefined;
        gl.GetIntegerv(gl.SRC_ALPHA, @ptrCast(&blendSrc));
        gl.Disable(gl.CULL_FACE);
        gl.Disable(gl.DEPTH_TEST);
        gl.Enable(gl.BLEND);
        gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
        defer if (cf) gl.Enable(gl.CULL_FACE);
        defer if (dt) gl.Enable(gl.DEPTH_TEST);
        defer if (!bl) gl.Disable(gl.BLEND);
        defer if (blendSrc != gl.ONE_MINUS_SRC_ALPHA) gl.BlendFunc(gl.SRC_ALPHA, blendSrc);
        gl.UseProgram(guiShaderProgram);
        gl.BindVertexArray(vertexArray);
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, elementBuffer);
        const glPos = [2]f32{ @mulAdd(f32, self.pos[0], 2, -1), @mulAdd(f32, self.pos[1], 2, -1) }; //convert the 0-1 coords to -1 to 1
        gl.Uniform2f(guiElementPositionLocation, glPos[0], glPos[1]);
        gl.Uniform2f(guiElementSizeLocation, self.width, self.height);
        if (self.options.Background == .solid)
            gl.Uniform4f(guiElementColorLocation, self.options.Background.solid[0], self.options.Background.solid[1], self.options.Background.solid[2], self.options.Background.solid[3]);
        gl.DrawElements(gl.TRIANGLES, 6, gl.UNSIGNED_INT, 0);
        if (screen_dimensions[0] != self.screen_dimensions[0] or screen_dimensions[1] != self.screen_dimensions[1]) {
            self.update(screen_dimensions);
        }
        if (inBottom and inTop and self.options.onHover != null) {
            self.options.onHover.?(self, cursorPos, window, false);
        }
        // var buf: [100]u8 = undefined;
        //const p = std.fmt.bufPrint(&buf, "screen dimentions: {any}", .{screen_dimensions}) catch unreachable;
        //text.RenderText(0, p, -1.0, 0.5, 0.0005, [3]f32{ 1, 0, 0.4 }) catch |err| std.debug.panic("err: {any}\n", .{err});
        if (self.children) |children| {
            for (children) |*child| {
                child.Draw(screen_dimensions, window);
            }
        }
    }
    ///requires a valid opengl context
    pub fn update(self: *@This(), screen_dimensions: [2]u32) void {
        self.screen_dimensions = screen_dimensions;
        var width: f32 = 0.0;
        width += self.options.size.widthPercent / 100.0;

        var height: f32 = 0.0;
        height += self.options.size.heightPercent / 100.0;
        var posx = self.options.position.xPercent / 100;
        var posy = self.options.position.yPercent / 100;
        if (self.parent) |parent| {
            posx = NormilizeInRange(posx, 0, 1, parent.pos[0] - (parent.width * 0.5), parent.pos[0] + (parent.width * 0.5));
            posy = NormilizeInRange(posy, 0, 1, parent.pos[1] - (parent.height * 0.5), parent.pos[1] + (parent.height * 0.5));
            width = NormilizeInRange(width, 0, 1, 0, parent.width);
            height = NormilizeInRange(height, 0, 1, 0, parent.height);
        }
        width += self.options.size.widthPixels / @as(f32, @floatFromInt(screen_dimensions[0]));
        height += self.options.size.heightPixels / @as(f32, @floatFromInt(screen_dimensions[1]));
        posx += (self.options.position.xPixels / @as(f32, @floatFromInt(screen_dimensions[0])));
        posy += (self.options.position.yPixels / @as(f32, @floatFromInt(screen_dimensions[1])));
        self.width = width;
        self.height = height;
        self.pos = [2]f32{ posx, posy };
    }
    ///frees element's children
    pub fn deinit(self: *@This()) void {
        std.debug.assert(self.isinit);
        if (self.children) |children| {
            for (children) |*child| {
                child.deinit();
            }
            self.allocator.free(children);
        }
        self.children = null;
    }
};

///requires a valid opengl context
pub fn init() void {
    std.debug.assert(!isinit);
    const vertex_shader_source = @embedFile("GuiVertexShader.vert");
    const fragment_shader_source = @embedFile("GuiFragmentShader.frag");
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

    guiShaderProgram = shader_program;

    guiElementPositionLocation = gl.GetUniformLocation(shader_program, "position");
    guiElementSizeLocation = gl.GetUniformLocation(shader_program, "size");
    guiElementColorLocation = gl.GetUniformLocation(shader_program, "color");
    LoadFacebuffer();
    //  text.init();

    // _ = text.loadFont(@embedFile("GoNotoCurrent-Regular.ttf"), 256, std.heap.c_allocator) catch |err| std.debug.panic("err: {any}\n", .{err});
    isinit = true;
}

pub fn deinit() void {
    std.debug.assert(isinit);
    gl.DeleteProgram(guiShaderProgram);
    gl.DeleteBuffers(1, @ptrCast(&arrayBuffer));
    gl.DeleteBuffers(1, @ptrCast(&elementBuffer));
    gl.DeleteVertexArrays(1, @ptrCast(&vertexArray));
    isinit = false;
}

fn LoadFacebuffer() void {
    const vertices = [_]f32{
        -1.0, -1.0, // bottom left corner
        -1.0, 1.0, // top left corner
        1.0, 1.0, // top right corner
        1.0, -1.0,
    }; // bottom right corner

    const indices = [_]u32{
        0, 1, 2, // first triangle (bottom left - top left - top right)
        0, 2, 3,
    };

    gl.GenVertexArrays(1, @ptrCast(&vertexArray));
    gl.BindVertexArray(vertexArray);

    gl.GenBuffers(1, @ptrCast(&elementBuffer));
    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, elementBuffer);
    gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, @sizeOf(u32) * indices.len, &indices, gl.STATIC_DRAW);

    gl.GenBuffers(1, @ptrCast(&arrayBuffer));
    gl.BindBuffer(gl.ARRAY_BUFFER, arrayBuffer);
    gl.BufferData(gl.ARRAY_BUFFER, @sizeOf(f32) * vertices.len, &vertices, gl.STATIC_DRAW);

    gl.VertexAttribPointer(0, 2, gl.FLOAT, 0, 2 * @sizeOf(f32), 0);
    gl.EnableVertexAttribArray(0);
}

fn NormilizeInRange(num: anytype, oldLowerBound: anytype, oldUpperBound: anytype, newLowerBound: anytype, newUpperBound: anytype) @TypeOf(num, oldLowerBound, oldUpperBound, newLowerBound, newUpperBound) {
    switch (@typeInfo(@TypeOf(num, oldLowerBound, oldUpperBound, newLowerBound, newUpperBound))) {
        .float => return (num - oldLowerBound) / (oldUpperBound - oldLowerBound) * (newUpperBound - newLowerBound) + newLowerBound,
        else => unreachable,
    }
}
