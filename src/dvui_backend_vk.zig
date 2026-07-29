const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const wio = @import("wio");
const vk = @import("vk");
const vk_renderer = @import("dvui_vk_renderer");

pub const kind: dvui.enums.Backend = .custom;

io: std.Io,
window: wio.Window,
size_natural: dvui.Size.Natural,
size_physical: dvui.Size.Physical,
arena: std.mem.Allocator = undefined,
mod: dvui.enums.Mod = .none,
touch: [10]dvui.Point = @splat(.{ .x = std.math.inf(f32), .y = std.math.inf(f32) }),

renderer: ?vk_renderer = null,
renderer_gpa: ?std.mem.Allocator = null,
cmd_buffer: vk.CommandBuffer = .null_handle,
framebuffer_extent: vk.Extent2D = .{ .width = 0, .height = 0 },

pub fn initVulkan(back: *@This(), dev: vk.DeviceProxy, pdev: vk.PhysicalDevice, memory: vk_renderer.VkMemory, queue: vk.Queue, cmd_pool: vk.CommandPool, gpa: std.mem.Allocator, max_frames: u32, swapchain_format: vk.Format) !void {
    back.renderer_gpa = gpa;
    back.renderer = try vk_renderer.init(gpa, .{
        .dev = dev,
        .pdev = pdev,
        .memory = memory,
        .render_pass = .{ .dynamic = .{
            .color_attachment_count = 1,
            .view_mask = 0,
            .p_color_attachment_formats = (&swapchain_format)[0..1].ptr,
            .depth_attachment_format = .undefined,
            .stencil_attachment_format = .undefined,
        } },
        .queue = queue,
        .comamnd_pool = cmd_pool,
        .max_frames_in_flight = max_frames,
    });
}

pub fn setCommandBuffer(back: *@This(), cmd: vk.CommandBuffer, extent: vk.Extent2D) void {
    back.cmd_buffer = cmd;
    back.framebuffer_extent = extent;
}

pub fn getRenderer(back: *@This()) *vk_renderer {
    return &(back.renderer orelse unreachable);
}

pub const InitOptions = struct {
    io: std.Io,
    window: wio.Window,
    size: wio.Size = .{ .width = 640, .height = 480 },
    framebuffer: wio.Size = .{ .width = 640, .height = 480 },
};

pub fn init(options: InitOptions) !@This() {
    dvui.io = options.io;
    return .{
        .io = options.io,
        .window = options.window,
        .size_natural = .{ .w = @floatFromInt(options.size.width), .h = @floatFromInt(options.size.height) },
        .size_physical = .{ .w = @floatFromInt(options.framebuffer.width), .h = @floatFromInt(options.framebuffer.height) },
    };
}

pub fn deinit(back: *@This()) void {
    const gpa = back.renderer_gpa orelse return;
    const r = &(back.renderer orelse return);
    r.deinit(gpa);
    back.renderer = null;
}

pub fn nanoTime(self: *@This()) i128 {
    const ret = std.Io.Clock.boot.now(self.io);
    return ret.nanoseconds;
}

pub fn sleep(_: *@This(), ns: u64) void {
    std.time.sleep(ns);
}

pub fn begin(self: *@This(), arena: std.mem.Allocator) !void {
    self.arena = arena;
    if (self.cmd_buffer != .null_handle) {
        const r = self.getRenderer();
        r.begin(arena, .{ .w = @floatFromInt(self.framebuffer_extent.width), .h = @floatFromInt(self.framebuffer_extent.height) });
    }
}

pub fn beginFrame(self: *@This()) void {
    if (self.cmd_buffer != .null_handle) {
        const r = self.getRenderer();
        r.beginFrame(self.cmd_buffer, self.framebuffer_extent);
    }
}

pub fn end(self: *@This()) !void {
    _ = self;
}

pub fn pixelSize(self: *@This()) dvui.Size.Physical {
    return self.size_physical;
}

pub fn windowSize(self: *@This()) dvui.Size.Natural {
    return self.size_natural;
}

pub fn contentScale(_: *@This()) f32 {
    return 1;
}

pub fn clipboardText(self: *@This()) ![]const u8 {
    return self.window.getClipboardText(self.arena) orelse "";
}

pub fn clipboardTextSet(self: *@This(), text: []const u8) !void {
    self.window.setClipboardText(text);
}

pub fn openUrl(_: *@This(), url: []const u8, _: bool) !void {
    wio.openUri(url);
}

pub fn preferredColorScheme(_: *@This()) ?dvui.enums.ColorScheme {
    return null;
}

pub fn prefersReducedMotion(_: *@This()) bool {
    return false;
}

pub fn refresh(_: *@This()) void {
    wio.cancelWait();
}

pub fn native(self: *@This(), _: *dvui.Window) dvui.Window.Native {
    return switch (builtin.os.tag) {
        .windows => .{ .hwnd = self.window.backend.window },
        .macos => .{ .cocoa_window = self.window.backend.window },
        else => {},
    };
}

pub fn waitEventTimeout(_: *@This(), timeout_us: u32) void {
    if (timeout_us == std.math.maxInt(u32)) {
        wio.wait(.{});
    } else {
        wio.wait(.{ .timeout_ns = @as(u64, timeout_us) * std.time.ns_per_us });
    }
}

pub fn setTextInputRect(self: *@This(), maybe_rect: ?dvui.Rect.Natural) void {
    if (maybe_rect) |rect| {
        self.window.enableTextInput(.{ .cursor = .{ .x = std.math.lossyCast(u16, rect.x), .y = std.math.lossyCast(u16, rect.y) } });
    } else {
        self.window.disableTextInput();
    }
}

pub fn setCursor(self: *@This(), cursor: dvui.enums.Cursor) void {
    self.window.setCursor(switch (cursor) {
        .arrow => .default,
        .ibeam => .text,
        .wait => .wait,
        .wait_arrow => .progress,
        .crosshair => .crosshair,
        .arrow_nw_se => .nwse_resize,
        .arrow_ne_sw => .nesw_resize,
        .arrow_w_e => .ew_resize,
        .arrow_n_s => .ns_resize,
        .arrow_all => .move,
        .bad => .not_allowed,
        .hand => .pointer,
        .hidden => .none,
    });
}

pub fn addEvent(self: *@This(), win: *dvui.Window, event: wio.Event) !bool {
    switch (event) {
        .close => {
            try win.addEventWindow(.{ .action = .close });
            return false;
        },
        .modifiers => |modifiers| {
            if (modifiers.shift) self.mod.combine(.lshift);
            if (modifiers.control) self.mod.combine(.lcontrol);
            if (modifiers.alt) self.mod.combine(.lalt);
            return false;
        },
        .unfocused => {
            self.mod = .none;
            return false;
        },
        .size_logical => |size| {
            self.size_natural = .{ .w = @floatFromInt(size.width), .h = @floatFromInt(size.height) };
            return false;
        },
        .size_physical => |size| {
            self.size_physical = .{ .w = @floatFromInt(size.width), .h = @floatFromInt(size.height) };
            return false;
        },
        .char => |char| {
            var utf8: [4]u8 = undefined;
            const len = try std.unicode.utf8Encode(char, &utf8);
            return try win.addEventText(.{ .text = utf8[0..len] });
        },
        .button_press, .button_release => |button| {
            const maybe_mouse: ?dvui.enums.Button = switch (button) {
                .mouse_left => .left,
                .mouse_right => .right,
                .mouse_middle => .middle,
                .mouse_back => .four,
                .mouse_forward => .five,
                else => null,
            };
            if (maybe_mouse) |mouse| {
                return try win.addEventMouseButton(mouse, if (event == .button_press) .press else .release);
            }
            const mod: dvui.enums.Mod = switch (button) {
                .left_control, .right_control => .lcontrol,
                .left_shift, .right_shift => .lshift,
                .left_alt, .right_alt => .lalt,
                .left_gui => .lcommand,
                .right_gui => .rcommand,
                else => .none,
            };
            if (mod != .none) {
                if (event == .button_press) {
                    self.mod.combine(mod);
                } else {
                    self.mod.unset(mod);
                }
            }
            return try win.addEventKey(.{
                .code = buttonToDvuiKey(button),
                .action = if (event == .button_press) .down else .up,
                .mod = self.mod,
            });
        },
        .button_repeat => |button| return try win.addEventKey(.{
            .code = buttonToDvuiKey(button),
            .action = .repeat,
            .mod = self.mod,
        }),
        .mouse => |mouse| {
            const x: f32 = @floatFromInt(mouse.x);
            const y: f32 = @floatFromInt(mouse.y);
            const scale = self.pixelSize().w / self.windowSize().w;
            return try win.addEventMouseMotion(.{ .pt = .{ .x = x * scale, .y = y * scale } });
        },
        .scroll_vertical => |ticks| return try win.addEventMouseWheel(-ticks * dvui.scroll_speed, .vertical, null),
        .scroll_horizontal => |ticks| return try win.addEventMouseWheel(-ticks * dvui.scroll_speed, .horizontal, null),
        .touch => |touch| {
            const button = touchIdToDvuiButton(touch.id) orelse return false;
            const xnorm = @as(f32, @floatFromInt(touch.x)) / self.size_natural.w;
            const ynorm = @as(f32, @floatFromInt(touch.y)) / self.size_natural.h;
            const old = &self.touch[touch.id];
            if (std.math.isInf(old.x)) {
                old.* = .{ .x = xnorm, .y = ynorm };
                return try win.addEventPointer(.{ .button = button, .action = .press, .xynorm = .{ .x = xnorm, .y = ynorm } });
            } else {
                const dxnorm = old.x - xnorm;
                const dynorm = old.y - ynorm;
                old.* = .{ .x = xnorm, .y = ynorm };
                return try win.addEventTouchMotion(button, xnorm, ynorm, dxnorm, dynorm);
            }
        },
        .touch_end => |touch| {
            const button = touchIdToDvuiButton(touch.id) orelse return false;
            const xynorm = self.touch[touch.id];
            self.touch[touch.id] = .{ .x = std.math.inf(f32), .y = std.math.inf(f32) };
            return try win.addEventPointer(.{ .button = button, .action = .release, .xynorm = xynorm });
        },
        else => return false,
    }
}

pub fn textInputRect(self: *@This(), rect: ?dvui.Rect.Natural) void {
    if (rect) |r| {
        self.window.enableTextInput(.{ .cursor = .{ .x = std.math.lossyCast(u16, r.x), .y = std.math.lossyCast(u16, r.y) } });
    } else {
        self.window.disableTextInput();
    }
}

pub fn renderPresent(_: *@This()) void {}

// Rendering methods (called by dvui.Backend when render_backend.kind == .default)

pub fn drawClippedTriangles(self: *@This(), texture: ?dvui.Texture, vtx: []const dvui.Vertex, idx: []const dvui.Vertex.Index, clipr: ?dvui.Rect.Physical) !void {
    const r = self.getRenderer();
    r.drawClippedTriangles(texture, vtx, idx, clipr);
}

pub fn textureCreate(self: *@This(), pixels: [*]const u8, options: dvui.Texture.CreateOptions) !dvui.Texture {
    const r = self.getRenderer();
    return r.textureCreate(pixels, options);
}

pub fn textureUpdate(_: *@This(), _: dvui.Texture, _: [*]const u8) !void {
    return error.NotImplemented;
}

pub fn textureDestroy(self: *@This(), texture: dvui.Texture) void {
    const r = self.getRenderer();
    r.textureDestroy(texture);
}

pub fn textureCreateTarget(self: *@This(), options: dvui.Texture.CreateOptions) !dvui.TextureTarget {
    const r = self.getRenderer();
    return r.textureCreateTarget(options);
}

pub fn textureReadTarget(_: *@This(), _: dvui.TextureTarget, _: [*]u8) !void {
    return error.NotImplemented;
}

pub fn textureClearTarget(_: *@This(), _: dvui.Texture.Target) void {}

pub fn textureDestroyTarget(self: *@This(), texture: dvui.Texture.Target) void {
    const r = self.getRenderer();
    r.textureDestroy(.{
        .ptr = texture.ptr,
        .width = texture.width,
        .height = texture.height,
        .format = texture.format,
        .interpolation = texture.interpolation,
        .wrap_u = texture.wrap_u,
        .wrap_v = texture.wrap_v,
    });
}

pub fn textureFromTarget(_: *@This(), target: dvui.TextureTarget) dvui.Texture {
    return .{
        .ptr = target.ptr,
        .width = target.width,
        .height = target.height,
        .format = target.format,
        .interpolation = target.interpolation,
        .wrap_u = target.wrap_u,
        .wrap_v = target.wrap_v,
    };
}

pub fn textureFromTargetTemp(self: *@This(), target: dvui.TextureTarget) !dvui.Texture {
    return self.textureFromTarget(target);
}

pub fn renderTarget(_: *@This(), _: ?dvui.TextureTarget) !void {
    return error.NotImplemented;
}

fn touchIdToDvuiButton(id: u8) ?dvui.enums.Button {
    return switch (id) {
        0 => .touch0,
        1 => .touch1,
        2 => .touch2,
        3 => .touch3,
        4 => .touch4,
        5 => .touch5,
        6 => .touch6,
        7 => .touch7,
        8 => .touch8,
        9 => .touch9,
        else => null,
    };
}

fn buttonToDvuiKey(button: wio.Button) dvui.enums.Key {
    return switch (button) {
        .mouse_left, .mouse_right, .mouse_middle, .mouse_back, .mouse_forward => unreachable,
        .a => .a,
        .b => .b,
        .c => .c,
        .d => .d,
        .e => .e,
        .f => .f,
        .g => .g,
        .h => .h,
        .i => .i,
        .j => .j,
        .k => .k,
        .l => .l,
        .m => .m,
        .n => .n,
        .o => .o,
        .p => .p,
        .q => .q,
        .r => .r,
        .s => .s,
        .t => .t,
        .u => .u,
        .v => .v,
        .w => .w,
        .x => .x,
        .y => .y,
        .z => .z,
        .@"1" => .one,
        .@"2" => .two,
        .@"3" => .three,
        .@"4" => .four,
        .@"5" => .five,
        .@"6" => .six,
        .@"7" => .seven,
        .@"8" => .eight,
        .@"9" => .nine,
        .@"0" => .zero,
        .enter => .enter,
        .escape => .escape,
        .backspace => .backspace,
        .tab => .tab,
        .space => .space,
        .minus => .minus,
        .equals => .equal,
        .left_bracket => .left_bracket,
        .right_bracket => .right_bracket,
        .backslash => .backslash,
        .semicolon => .semicolon,
        .apostrophe => .apostrophe,
        .grave => .grave,
        .comma => .comma,
        .dot => .period,
        .slash => .slash,
        .caps_lock => .caps_lock,
        .f1 => .f1,
        .f2 => .f2,
        .f3 => .f3,
        .f4 => .f4,
        .f5 => .f5,
        .f6 => .f6,
        .f7 => .f7,
        .f8 => .f8,
        .f9 => .f9,
        .f10 => .f10,
        .f11 => .f11,
        .f12 => .f12,
        .print_screen => .print,
        .scroll_lock => .scroll_lock,
        .pause => .pause,
        .insert => .insert,
        .home => .home,
        .page_up => .page_up,
        .delete => .delete,
        .end => .end,
        .page_down => .page_down,
        .right => .right,
        .left => .left,
        .down => .down,
        .up => .up,
        .num_lock => .num_lock,
        .kp_slash => .kp_divide,
        .kp_star => .kp_multiply,
        .kp_minus => .kp_subtract,
        .kp_plus => .kp_add,
        .kp_enter => .kp_enter,
        .kp_1 => .kp_1,
        .kp_2 => .kp_2,
        .kp_3 => .kp_3,
        .kp_4 => .kp_4,
        .kp_5 => .kp_5,
        .kp_6 => .kp_6,
        .kp_7 => .kp_7,
        .kp_8 => .kp_8,
        .kp_9 => .kp_9,
        .kp_0 => .kp_0,
        .kp_dot => .kp_decimal,
        .iso_backslash => .backslash,
        .application => .menu,
        .kp_equals => .kp_equal,
        .f13 => .f13,
        .f14 => .f14,
        .f15 => .f15,
        .f16 => .f16,
        .f17 => .f17,
        .f18 => .f18,
        .f19 => .f19,
        .f20 => .f20,
        .f21 => .f21,
        .f22 => .f22,
        .f23 => .f23,
        .f24 => .f24,
        .left_control => .left_control,
        .left_shift => .left_shift,
        .left_alt => .left_alt,
        .left_gui => .left_command,
        .right_control => .right_control,
        .right_shift => .right_shift,
        .right_alt => .right_alt,
        .right_gui => .right_command,
        .kp_comma, .international1, .international2, .international3, .international4, .international5, .lang1, .lang2 => .unknown,
    };
}
