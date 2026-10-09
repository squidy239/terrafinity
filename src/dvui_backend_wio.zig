const std = @import("std");
const builtin = @import("builtin");

const dvui = @import("dvui");
const vk = @import("vk");
const vk_renderer = @import("dvui_vulkan_renderer");
const wio = @import("wio");

pub const kind: dvui.enums.Backend = .custom;

io: std.Io,
window: wio.Window,
size_natural: dvui.Size.Natural,
size_physical: dvui.Size.Physical,
arena: std.mem.Allocator = undefined,
mod: dvui.enums.Mod = .none,
touch: [10]dvui.Point = @splat(.{ .x = std.math.inf(f32), .y = std.math.inf(f32) }),

renderer: vk_renderer,
device: vk.DeviceProxy,
/// The command buffer and extent of the current frame. It is null outside `beginFrame` and the caller's reset.
target: ?Target = null,
prepass_cmd: ?vk.CommandBuffer = null,

pub const Target = struct {
    cmd_buffer: vk.CommandBuffer,
    extent: vk.Extent2D,
};

pub const InitOptions = struct {
    io: std.Io,
    window: wio.Window,
    size: wio.Size = .{ .width = 640, .height = 480 },
    framebuffer: wio.Size = .{ .width = 640, .height = 480 },
    gpa: std.mem.Allocator,
    dev: vk.DeviceProxy,
    memory: vk_renderer.VkMemory,
    max_frames: u32,
    swapchain_format: vk.Format,
    queue_family_index: u32,
};

pub fn init(options: InitOptions) !@This() {
    dvui.io = options.io;
    return .{
        .io = options.io,
        .window = options.window,
        .size_natural = convertSize(dvui.Size.Natural, options.size),
        .size_physical = convertSize(dvui.Size.Physical, options.framebuffer),
        .device = options.dev,
        .renderer = try vk_renderer.init(options.gpa, .{
            .dev = options.dev,
            .gpu_allocator = .{ .builtin = options.memory },
            .render_pass = .{ .dynamic = .{
                .info = .{
                    .color_attachment_count = 1,
                    .view_mask = 0,
                    .p_color_attachment_formats = (&options.swapchain_format)[0..1].ptr,
                    .depth_attachment_format = .undefined,
                    .stencil_attachment_format = .undefined,
                },
            } },
            .graphics_queue_family_index = options.queue_family_index,
            .max_frames_in_flight = options.max_frames,
        }),
    };
}

pub fn deinit(back: *@This()) void {
    back.device.deviceWaitIdle() catch |err| {
        std.log.err("DVUI Vulkan renderer could not wait for device idle: {}", .{err});
    };
    back.renderer.deinit();
}

pub fn nanoTime(self: *@This()) i128 {
    return std.Io.Clock.boot.now(self.io).nanoseconds;
}

pub fn sleep(self: *@This(), ns: u64) void {
    self.io.sleep(.fromNanoseconds(ns), .awake) catch {};
}

pub fn begin(self: *@This(), arena: std.mem.Allocator) !void {
    self.arena = arena;
    if (self.target) |target| {
        try self.renderer.beginWithSize(arena, .{ .w = @floatFromInt(target.extent.width), .h = @floatFromInt(target.extent.height) });
    }
}

/// Records the UI into `target` until the caller resets `target` to null.
pub fn beginFrame(self: *@This(), target: Target) void {
    self.target = target;
    self.renderer.beginFrame(target.cmd_buffer, target.extent) catch |err| @panic(@errorName(err));
}

pub fn end(self: *@This()) !void {
    const recorded = self.renderer.endFrame() catch |err| {
        std.log.err("DVUI Vulkan renderer failed to end frame: {}", .{err});
        return error.BackendError;
    };
    self.prepass_cmd = recorded.prepass;
}

pub fn takePrepass(self: *@This()) ?vk.CommandBuffer {
    const prepass = self.prepass_cmd;
    self.prepass_cmd = null;
    return prepass;
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

const ClipboardResult = struct {
    allocator: std.mem.Allocator,
    text: ?[]const u8 = null,
};

fn clipboardTextCallback(data: ?*anyopaque, text: []const u8) void {
    const result: *ClipboardResult = @ptrCast(@alignCast(data.?));
    result.text = result.allocator.dupe(u8, text) catch null;
}

pub fn clipboardText(self: *@This()) ![]const u8 {
    var result = ClipboardResult{ .allocator = self.arena };
    self.window.getClipboardText(clipboardTextCallback, &result);
    return result.text orelse "";
}

pub fn clipboardTextSet(self: *@This(), text: []const u8) !void {
    self.window.setClipboardText(text);
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
            self.size_natural = convertSize(dvui.Size.Natural, size);
            return false;
        },
        .size_physical => |size| {
            self.size_physical = convertSize(dvui.Size.Physical, size);
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
            if (event == .button_press) self.mod.combine(mod) else self.mod.unset(mod);
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
        .scroll_vertical, .scroll_horizontal => |ticks| return try win.addEventMouseWheel(-ticks * dvui.scroll_speed, if (event == .scroll_vertical) .vertical else .horizontal, null),
        .touch => |touch| {
            const button = touchIdToDvuiButton(touch.id) orelse return false;
            const xnorm = @as(f32, @floatFromInt(touch.x)) / self.size_natural.w;
            const ynorm = @as(f32, @floatFromInt(touch.y)) / self.size_natural.h;
            const old = self.touch[touch.id];
            self.touch[touch.id] = .{ .x = xnorm, .y = ynorm };
            if (std.math.isInf(old.x)) {
                return try win.addEventPointer(.{ .button = button, .action = .press, .xynorm = self.touch[touch.id] });
            }
            return try win.addEventTouchMotion(button, xnorm, ynorm, old.x - xnorm, old.y - ynorm);
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
        self.window.enableTextInput(.{ .cursor = .{ .x = @trunc(r.x), .y = @trunc(r.y) } });
    } else {
        self.window.disableTextInput();
    }
}

pub fn renderPresent(_: *@This()) void {}

pub fn drawClippedTriangles(self: *@This(), texture: ?dvui.Texture, vtx: []const dvui.Vertex, idx: []const dvui.Vertex.Index, clipr: ?dvui.Rect.Physical) !void {
    if (self.target == null) return;
    try self.renderer.drawClippedTriangles(self.size_physical, texture, vtx, idx, clipr);
}

pub fn textureCreate(self: *@This(), pixels: [*]const u8, options: dvui.Texture.CreateOptions) !dvui.Texture {
    return self.renderer.textureCreate(pixels, options);
}

pub fn textureUpdate(_: *@This(), _: dvui.Texture, _: [*]const u8) !void {
    return error.NotImplemented;
}

pub fn textureDestroy(self: *@This(), texture: dvui.Texture) void {
    self.renderer.textureDestroy(texture);
}

pub fn textureCreateTarget(self: *@This(), options: dvui.Texture.CreateOptions) !dvui.TextureTarget {
    return self.renderer.textureCreateTarget(options);
}

pub fn textureReadTarget(_: *@This(), _: dvui.TextureTarget, _: [*]u8) !void {
    return error.NotImplemented;
}

pub fn textureClearTarget(_: *@This(), _: dvui.Texture.Target) void {}

pub fn textureDestroyTarget(self: *@This(), texture: dvui.Texture.Target) void {
    self.renderer.textureDestroy(self.textureFromTarget(texture));
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

fn convertSize(comptime Size: type, size: wio.Size) Size {
    return .{ .w = @floatFromInt(size.width), .h = @floatFromInt(size.height) };
}

fn touchIdToDvuiButton(id: u8) ?dvui.enums.Button {
    if (id > 9) return null;
    // dvui declares touch0 through touch9 in order.
    return @fromBackingInt(@intCast(@backingInt(dvui.enums.Button.touch0) + id));
}

fn buttonToDvuiKey(button: wio.Button) dvui.enums.Key {
    return switch (button) {
        .mouse_left, .mouse_right, .mouse_middle, .mouse_back, .mouse_forward => unreachable,
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
        .equals => .equal,
        .dot => .period,
        .print_screen => .print,
        .kp_slash => .kp_divide,
        .kp_star => .kp_multiply,
        .kp_minus => .kp_subtract,
        .kp_plus => .kp_add,
        .kp_dot => .kp_decimal,
        .iso_backslash => .backslash,
        .application => .menu,
        .kp_equals => .kp_equal,
        .left_gui => .left_command,
        .right_gui => .right_command,
        .kp_comma, .international1, .international2, .international3, .international4, .international5, .lang1, .lang2 => .unknown,
        // Every other button has a dvui key with the same name.
        inline else => |same_name| @field(dvui.enums.Key, @tagName(same_name)),
    };
}

test {
    std.testing.refAllDecls(@This());
}
