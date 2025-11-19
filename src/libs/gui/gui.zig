const std = @import("std");
const zigimg = @import("root").zigimg;

const gl = @import("gl");
const glfw = @import("glfw");
pub const Text = @import("text/text.zig");
pub const Widgets = @import("widgets.zig");
var guiShaderProgram: c_uint = undefined;
var guiElementPositionLocation: c_int = undefined;
var guiElementSizeLocation: c_int = undefined;
var guiElementColorLocation: c_int = undefined;
var upper_left_location: c_int = undefined;
var width_height_location: c_int = undefined;
var corner_radii_location: c_int = undefined;

var vertexArray: c_uint = undefined;
var elementBuffer: c_uint = undefined;
var arrayBuffer: c_uint = undefined;
var defaultFont: Text.Font = undefined;
var isinit: bool = false;

//all element types must be the same
pub const SizeUnit = struct {
    ///a percent of the container's width
    xPercent: f32 = 0,
    ///a percent of the container's height
    yPercent: f32 = 0,
    pixels: f32 = 0,
    millimeters: f32 = 0,
    ///a unit of font size
    point: f32 = 0,
    ///converts and adds the units, x and y percent get normilized to the container range. if it is null 0 to 100 is used
    ///if viewport_millimeters is null millimeters and point units cannot be used
    ///axis that the units are being converted for, 0 for x and 1 for y
    pub fn as(self: @This(), viewport_pixels: [2]f32, viewport_millimeters: ?[2]f32, containerRange: ?[2][2]f32, axis: u1, unit: Units) f32 {
        //common unit is width percent
        var percents: [2]f32 = @splat(0.0);
        const container_range = if (containerRange) |range| range else [2][2]f32{ [2]f32{ 0, 100 }, [2]f32{ 0, 100 } };
        inline for (std.meta.fields(@This())) |field| {
            const fieldData = @field(self, field.name);
            if (std.mem.eql(u8, field.name, "xPercent")) percents[0] += NormilizeInRange(fieldData, 0, 100, container_range[0][0], container_range[0][1]);
            if (std.mem.eql(u8, field.name, "yPercent")) percents[1] += NormilizeInRange(fieldData, 0, 100, container_range[1][0], container_range[1][1]);
            if (std.mem.eql(u8, field.name, "pixels")) percents[axis] += pixelsToPercent(fieldData, viewport_pixels[1]);
            if (std.mem.eql(u8, field.name, "millimeters")) percents[axis] += millimetersToPercent(fieldData, (viewport_millimeters orelse unreachable)[axis]);
            if (std.mem.eql(u8, field.name, "point")) percents[axis] += pointToPercent(fieldData, (viewport_millimeters orelse unreachable)[axis]);
        }

        return switch (unit) {
            .xPercent => percents[0] + yPercentToxPercent(percents[1], viewport_pixels),
            .yPercent => percents[1] + xPercentToyPercent(percents[0], viewport_pixels),
            .pixels => pixelsFromPercent(percents[1], viewport_pixels[1]) + pixelsFromPercent(percents[0], viewport_pixels[0]),
            .milimeters => millimetersFromPercent(percents[1], (viewport_millimeters orelse unreachable)[1]) + millimetersFromPercent(percents[0], (viewport_millimeters orelse unreachable)[0]),
            .point => pointFromPercent(percents[1], (viewport_millimeters orelse unreachable)[1]) + pointFromPercent(percents[0], (viewport_millimeters orelse unreachable)[0]),
        };
    }

    fn xPercentToyPercent(xPercent: f32, container_dimensions: [2]f32) f32 {
        return 100 * ((pixelsFromPercent(xPercent, container_dimensions[0]) / container_dimensions[1]));
    }
    fn yPercentToxPercent(yPercent: f32, container_dimensions: [2]f32) f32 {
        return 100 * ((pixelsFromPercent(yPercent, container_dimensions[1]) / container_dimensions[0]));
    }
    fn pixelsToPercent(pixels: f32, container_dimension: f32) f32 {
        return 100 * (pixels / container_dimension);
    }
    fn pixelsFromPercent(percent: f32, container_dimension: f32) f32 {
        return percent * (0.01 * container_dimension);
    }
    fn millimetersToPercent(millimeters: f32, container_millimeters: f32) f32 {
        return 100 * (millimeters / container_millimeters);
    }
    fn millimetersFromPercent(percent: f32, container_millimeters: f32) f32 {
        return percent * (0.01 * container_millimeters); //having the parentheses maintaines precision
    }
    fn pointToPercent(point: f32, container_millimeters: f32) f32 {
        const container_points = container_millimeters * 2.8346456693; //points per mm
        return point / container_points;
    }
    fn pointFromPercent(percent: f32, container_millimeters: f32) f32 {
        const container_points = container_millimeters * 2.8346456693; //points per mm
        return percent * (0.01 * container_points);
    }
    const Units = enum {
        xPercent,
        yPercent,
        pixels,
        milimeters,
        point,
    };
};

test "SizeUnit" {
    const wsize = SizeUnit{ .yPercent = 0, .xPercent = 100, .pixels = 0 };
    const hsize = SizeUnit{ .yPercent = 50, .xPercent = 0, .pixels = 0 };

    try std.testing.expectEqual(wsize.as(.{ 100, 200 }, .{ 100, 200 }, null, 1, .yPercent), 50);
    try std.testing.expectEqual(hsize.as(.{ 100, 200 }, .{ 100, 200 }, null, 0, .xPercent), 200);
    try std.testing.expectEqual(wsize.as(.{ 100, 200 }, .{ 100, 200 }, null, 0, .milimeters), 100);

    const size = SizeUnit{ .yPercent = 0, .xPercent = 0, .pixels = 200 };
    try std.testing.expectEqual(size.as(.{ 200, 100 }, .{ 100, 200 }, null, 1, .yPercent), 200);
    try std.testing.expectEqual(size.as(.{ 100, 200 }, .{ 100, 200 }, null, 0, .milimeters), 100);

    const mmsize = SizeUnit{ .yPercent = 0, .xPercent = 0, .pixels = 0, .millimeters = 10 };
    try std.testing.expectEqual(mmsize.as(.{ 100, 100 }, .{ 100, 100 }, null, 0, .xPercent), 10);
    try std.testing.expectEqual(mmsize.as(.{ 200, 100 }, .{ 200, 100 }, null, 0, .xPercent), 5);
    try std.testing.expectEqual(mmsize.as(.{ 200, 100 }, .{ 200, 100 }, null, 1, .yPercent), 10);
    try std.testing.expectEqual(mmsize.as(.{ 200, 100 }, .{ 200, 200 }, null, 1, .yPercent), 5);

    try std.testing.expectEqual(mmsize.as(.{ 100, 100 }, .{ 100, 100 }, null, 0, .pixels), 10);
    try std.testing.expectEqual(mmsize.as(.{ 100, 100 }, .{ 100, 100 }, null, 0, .point), 28.346455);
}

pub const Element = struct {
    allocator: std.mem.Allocator,
    viewport_pixels: [2]f32,
    viewport_millimeters: [2]f32,
    width: f32,
    height: f32,
    pos: @Vector(2, f32),
    options: Options,
    children: ?[]Element,
    onHoverArgs: ?*anyopaque,
    parent: ?*Element,
    customData: ?[]u8,
    isinit: bool = false,
    ///a position on the screen, x and y can be between 0 and 100
    pub const Position = struct {
        x: SizeUnit = .{},
        y: SizeUnit = .{},
    };

    pub const Size = struct {
        width: SizeUnit = .{},
        height: SizeUnit = .{},
    };

    pub const ElementBackground = union(enum) {
        solid: @Vector(4, f32),
    };
    pub const TextOptions = struct {
        ///text that will be in the center of the box, create() makes a copy of this when the element is created
        text: []const u8,
        ///the color of the text if it exists
        textColor: [4]f32 = [4]f32{ 0.0, 0.0, 0.0, 1.0 },
        ///uses the default font if this is null
        font: ?*Text.Font = null,
        scale: @FieldType(Text.Text, "scale"),
        startPosition: Position = .{ .x = .{ .xPercent = 0 }, .y = .{ .yPercent = 0 } },
    };
    pub const CreationOptions = struct {
        textOptions: ?TextOptions = null,
        elementBackground: ElementBackground = .{ .solid = .{ 1.0, 1.0, 1.0, 1.0 } },

        position: Position = .{ .x = .{ .xPercent = 50 }, .y = .{ .yPercent = 50 } },
        ///the size of the element. all units are added together
        size: Size = .{ .width = .{ .xPercent = 100 }, .height = .{ .yPercent = 100 } },
        ///if this is false the element and its children will not be drawn and onHover and onDraw will not be called
        Visible: bool = true,
        ///onclick can be made by checking mouse status in this function. [2]f64 is mousePos from 0.0 to 1.0.
        ///last bool is false if it is being called after drawing so the options can be reset if needed
        ///update must be called after any modifications to the element
        onHover: ?*const fn (*Element, [2]f64, *glfw.Window, bool) void = null,

        onHoverArgs: ?*anyopaque = null,

        ///gets called before drawing before onHover
        ///update must be called after any modifications to the element
        onDraw: ?*const fn (*Element, [2]f64, *glfw.Window) void = null,

        ///gets called when the element is initialized
        onInit: ?*const fn (*Element) void = null,

        children: ?[]const CreationOptions = null,

        ///top=left, top=right, bottom=right, bottom=left
        cornerPixelRadii: [4]SizeUnit = @splat(.{}),

        ///the length of the customData, it can be set with onInit
        customDataLen: ?usize = null,

        pub fn CountChildren(self: *const CreationOptions, isChild: bool) usize {
            var count: usize = 0;
            if (self.children) |children| {
                for (children) |_| {
                    count += 1;
                }
            }
            return count + @intFromBool(isChild);
        }
    };

    const Options = struct {
        ///the position of the element. all units are added together
        position: Position = .{ .x = .{ .xPercent = 50 }, .y = .{ .yPercent = 50 } },
        ///the size of the element. all units are added together
        size: Size = .{ .width = .{ .xPercent = 100 }, .height = .{ .yPercent = 100 } },
        ///if this is false the element and its children will not be drawn and onHover and onDraw will not be called
        Visible: bool = true,
        ///onclick can be made by checking mouse status in this function. [2]f64 is mousePos from 0.0 to 1.0. relative to the element
        ///last bool is false if it is being called after drawing so the options can be reset if needed
        ///update must be called after any modifications to the element
        onHover: ?*const fn (*Element, [2]f64, *glfw.Window, bool) void = null,
        ///gets called before drawing before onHover
        ///update must be called after any modifications to the element
        onDraw: ?*const fn (*Element, [2]f64, *glfw.Window) void = null,

        onInit: ?*const fn (*Element) void = null,

        elementBackground: ElementBackground,
        text: ?Text.Text,
        textStartPosition: ?Position,
        ///top=left, top=right, bottom=right, bottom=left
        cornerPixelRadii: [4]SizeUnit = @splat(.{}),
    };
    ///the allocator must remain valid for the lifetime of the element
    ///init must be called after creating the outermost Element
    pub fn create(allocator: std.mem.Allocator, creationOptions: CreationOptions) !Element {
        var elementText: ?Text.Text = null;
        if (creationOptions.textOptions != null) {
            elementText = Text.Text{
                .allocator = allocator,
                .color = creationOptions.textOptions.?.textColor,
                .font = creationOptions.textOptions.?.font orelse &defaultFont,
                .text = null,
                .scale = creationOptions.textOptions.?.scale,
                .startX = undefined, //these get set by updateText
                .startY = undefined,
                .vertexArray = null,
                .arrayBuffer = null,
                .oldScreenDimensions = null,
                .textChanged = true,
                .lineSpacing = 1.0,
            };
            elementText.?.init();
            try elementText.?.SetText(creationOptions.textOptions.?.text);
        }

        const childrenCount = creationOptions.CountChildren(false);
        const children: ?[]Element = if (childrenCount > 0) try allocator.alloc(Element, childrenCount) else null;
        errdefer if (children) |childrenn| allocator.free(childrenn);
        if (creationOptions.children) |childrenOptions| {
            std.debug.assert(childrenCount > 0);
            for (childrenOptions, 0..) |childOptions, i| {
                errdefer for (children.?[0..i]) |*child| child.deinit();
                children.?[i] = try Element.create(allocator, childOptions);
            }
        }
        return Element{
            .allocator = allocator,
            .viewport_pixels = undefined,
            .width = undefined,
            .height = undefined,
            .pos = undefined,
            .viewport_millimeters = undefined,
            .customData = if (creationOptions.customDataLen) |len| try allocator.alloc(u8, len) else null,
            .onHoverArgs = creationOptions.onHoverArgs,
            .options = .{
                .Visible = creationOptions.Visible,
                .onHover = creationOptions.onHover,
                .onDraw = creationOptions.onDraw,
                .onInit = creationOptions.onInit,
                .position = creationOptions.position,
                .size = creationOptions.size,
                .elementBackground = creationOptions.elementBackground,
                .text = elementText,
                .textStartPosition = if (creationOptions.textOptions == null) null else creationOptions.textOptions.?.startPosition,
                .cornerPixelRadii = creationOptions.cornerPixelRadii,
            },
            .children = children,
            .parent = null,
            .isinit = false,
        };
    }
    //msut be called after creation on outermost element
    pub fn init(self: *@This(), viewport_pixels: [2]f32, viewport_millimeters: [2]f32) void {
        std.debug.assert(!self.isinit);
        self.viewport_millimeters = viewport_millimeters;
        self.viewport_pixels = viewport_pixels;
        if (self.options.onInit) |onInit| {
            onInit(self);
        }
        self.update();
        self.updateText();
        if (self.children) |children| {
            for (children) |*child| {
                child.parent = self;
                child.init(viewport_pixels, viewport_millimeters);
            }
        }

        self.isinit = true;
    }

    ///requires a valid opengl context, screen_dimentions MUST be multiplyed by fractional scailing
    pub fn Draw(self: *@This(), viewport_pixels: [2]f32, viewport_millimeters: [2]f32, window: *glfw.Window) void { //TODO only have creation options, gl_clipdistance, and element matricies for rotation or projection
        std.debug.assert(self.isinit);
        std.debug.assert(isinit);
        if (!self.options.Visible) return;
        if (viewport_pixels[0] != self.viewport_pixels[0] or viewport_pixels[1] != self.viewport_pixels[1] or viewport_millimeters[0] != self.viewport_millimeters[0] or viewport_millimeters[1] != self.viewport_millimeters[1]) {
            self.viewport_pixels = viewport_pixels;
            self.viewport_millimeters = viewport_millimeters;
            self.update();
        }
        const viewport_pixels_float = @Vector(2, f64){ @floatCast(viewport_pixels[0]), @floatCast(viewport_pixels[1]) };
        //
        var cursorPos = window.getCursorPos() * @as(@Vector(2, f64), @floatCast(@as(@Vector(2, f32), window.getContentScale())));
        cursorPos[0] = @min(@max(cursorPos[0], 0), viewport_pixels_float[0]);
        cursorPos[1] = @abs(viewport_pixels_float[1] - @min(@max(cursorPos[1], 0), viewport_pixels_float[1]));
        cursorPos = @Vector(2, f64){ cursorPos[0] / (viewport_pixels_float[0]), cursorPos[1] / (viewport_pixels_float[1]) };
        const bottomCorner = @Vector(2, f32){ self.pos[0] - (self.width * 0.5), self.pos[1] - (self.height * 0.5) };
        const topCorner = @Vector(2, f32){ self.pos[0] + (self.width * 0.5), self.pos[1] + (self.height * 0.5) };
        const inBottom = bottomCorner[0] < cursorPos[0] and bottomCorner[1] < cursorPos[1];
        const inTop = topCorner[0] > cursorPos[0] and topCorner[1] > cursorPos[1];
        const relativeCursorPos = NormilizeInRange(cursorPos, @Vector(2, f64){ self.pos[0] - (self.width * 0.5), self.pos[1] - (self.height * 0.5) }, @Vector(2, f64){ self.pos[0] + (self.width * 0.5), self.pos[1] + (self.height * 0.5) }, @Vector(2, f64){ 0, 0 }, @Vector(2, f64){ 1, 1 });
        if (self.options.onDraw) |onDraw| onDraw(self, relativeCursorPos, window);

        const mouseOverElement: bool = inBottom and inTop and self.options.onHover != null;
        if (mouseOverElement) {
            self.options.onHover.?(self, relativeCursorPos, window, true);
        }
        //
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
        //
        gl.UseProgram(guiShaderProgram);
        gl.BindVertexArray(vertexArray);
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, elementBuffer);
        const glPos = [2]f32{ @mulAdd(f32, self.pos[0], 2, -1), @mulAdd(f32, self.pos[1], 2, -1) }; //convert the 0-1 coords to -1 to 1
        gl.Uniform2f(guiElementPositionLocation, glPos[0], glPos[1]);
        gl.Uniform2f(guiElementSizeLocation, self.width, self.height);

        // Convert normalized 0–1 coordinates to pixels
        const pixelX = self.pos[0] * @as(f32, @floatCast(viewport_pixels_float[0]));
        const pixelY = self.pos[1] * @as(f32, @floatCast(viewport_pixels_float[1]));
        const pixelWidth = self.width * @as(f32, @floatCast(viewport_pixels_float[0]));
        const pixelHeight = self.height * @as(f32, @floatCast(viewport_pixels_float[1]));

        // top-left corner = center - half-size (Y flipped to match OpenGL’s bottom-left origin)
        const upper_left_x = pixelX - pixelWidth * 0.5;
        const upper_left_y = pixelY + pixelHeight * 0.5;

        gl.Uniform2f(upper_left_location, upper_left_x, upper_left_y);
        gl.Uniform2f(width_height_location, pixelWidth, pixelHeight);
        gl.Uniform4f(corner_radii_location, self.options.cornerPixelRadii[0].as(self.viewport_pixels, self.viewport_millimeters, null, 0, .pixels), self.options.cornerPixelRadii[1].as(self.viewport_pixels, self.viewport_millimeters, null, 0, .pixels), self.options.cornerPixelRadii[2].as(self.viewport_pixels, self.viewport_millimeters, null, 0, .pixels), self.options.cornerPixelRadii[3].as(self.viewport_pixels, self.viewport_millimeters, null, 0, .pixels));

        if (self.options.elementBackground == .solid)
            gl.Uniform4f(guiElementColorLocation, self.options.elementBackground.solid[0], self.options.elementBackground.solid[1], self.options.elementBackground.solid[2], self.options.elementBackground.solid[3]);
        gl.DrawElements(gl.TRIANGLES, 6, gl.UNSIGNED_INT, 0);

        if (self.options.text != null) {
            self.options.text.?.render(viewport_pixels);
        }
        if (mouseOverElement) {
            self.options.onHover.?(self, relativeCursorPos, window, false);
        }

        if (self.children) |children| {
            for (children) |*child| {
                child.Draw(viewport_pixels, viewport_millimeters, window);
            }
        }
    }
    ///requires a valid opengl context
    pub fn update(self: *@This()) void {
        var sizeRange: [2][2]f32 = .{
            .{ 0, 100 },
            .{ 0, 100 },
        };

        var posRangeX: [2][2]f32 = .{ //must have x and y becuause a 0 coord for the other axis can get normilised, TODO find a better solution
            .{ 0, 100 },
            .{ 0, 100 },
        };

        var posRangeY: [2][2]f32 = .{
            .{ 0, 100 },
            .{ 0, 100 },
        };
        if (self.parent) |parent| {
            sizeRange = .{
                .{ 0, parent.width * 100 },
                .{ 0, parent.height * 100 },
            };
            posRangeX = .{
                .{ 100 * (parent.pos[0] - (parent.width * 0.5)), 100 * (parent.pos[0] + (parent.width * 0.5)) },
                .{ 0, 100 },
            };
            posRangeY = .{
                .{ 0, 100 },
                .{ 100 * (parent.pos[1] - (parent.height * 0.5)), 100 * (parent.pos[1] + (parent.height * 0.5)) },
            };
        }
        self.width = 0.01 * self.options.size.width.as(self.viewport_pixels, self.viewport_millimeters, sizeRange, 0, .xPercent);
        self.height = 0.01 * self.options.size.height.as(self.viewport_pixels, self.viewport_millimeters, sizeRange, 1, .yPercent);
        self.pos[0] = 0.01 * self.options.position.x.as(self.viewport_pixels, self.viewport_millimeters, posRangeX, 0, .xPercent);
        self.pos[1] = 0.01 * self.options.position.y.as(self.viewport_pixels, self.viewport_millimeters, posRangeY, 1, .yPercent);
        updateText(self);
    }

    fn updateText(self: *@This()) void {
        if (self.options.text == null or self.options.textStartPosition == null) return;
        var startX = self.options.textStartPosition.?.x.xPercent / 100;
        var startY = self.options.textStartPosition.?.y.yPercent / 100;

        startX = NormilizeInRange(startX, 0, 1, self.pos[0] - (self.width * 0.5), self.pos[0] + (self.width * 0.5));
        startY = NormilizeInRange(startY, 0, 1, self.pos[1] - (self.height * 0.5), self.pos[1] + (self.height * 0.5));

        startX += (self.options.textStartPosition.?.x.pixels / (self.viewport_pixels[0]));
        startY += (self.options.textStartPosition.?.y.pixels / (self.viewport_pixels[1]));

        startX = (startX * 2) - 1;
        startY = (startY * 2) - 1;

        self.options.text.?.startX = startX;
        self.options.text.?.startY = startY;
    }

    pub fn deinit(self: *@This()) void {
        std.debug.assert(self.isinit);
        if (self.children) |children| {
            for (children) |*child| {
                child.deinit();
            }
            self.allocator.free(children);
        }
        if (self.options.text != null) self.options.text.?.deinit();
        if (self.customData) |data| self.allocator.free(data);
        self.children = null;
    }
};

///requires a valid opengl context
pub fn init(allocator: std.mem.Allocator) void {
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
    upper_left_location = gl.GetUniformLocation(shader_program, "upper_left");
    width_height_location = gl.GetUniformLocation(shader_program, "width_height");
    corner_radii_location = gl.GetUniformLocation(shader_program, "corner_radii");
    LoadFacebuffer();
    Text.init();
    defaultFont = Text.Font.load(@embedFile("GoNotoCurrent-Regular.ttf"), 256, null, allocator) catch |err| std.debug.panic("err: {any}\n", .{err});
    isinit = true;
}

pub fn deinit() void {
    std.debug.assert(isinit);
    gl.DeleteProgram(guiShaderProgram);
    gl.DeleteBuffers(1, @ptrCast(&arrayBuffer));
    gl.DeleteBuffers(1, @ptrCast(&elementBuffer));
    gl.DeleteVertexArrays(1, @ptrCast(&vertexArray));
    defaultFont.deinit();
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

pub fn NormilizeInRange(num: anytype, oldLowerBound: anytype, oldUpperBound: anytype, newLowerBound: anytype, newUpperBound: anytype) @TypeOf(num, oldLowerBound, oldUpperBound, newLowerBound, newUpperBound) {
    return (num - oldLowerBound) / (oldUpperBound - oldLowerBound) * (newUpperBound - newLowerBound) + newLowerBound;
}
