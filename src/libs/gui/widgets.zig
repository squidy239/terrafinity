const gui = @import("gui.zig");
const glfw = @import("glfw");
const std = @import("std");

pub const SlideData = struct {
    sliderPos: f32 = 0,
    lastSliderPos: f32 = 0,
    clickedLastDraw: [2]bool = @splat(false),
    isClicked: bool = false,
    onSlide:?*const fn(slider: *gui.Element, slideData: *const SlideData, window: *glfw.Window) void = null,
};

const SliderOptions = struct {
    centerPos: gui.Element.Position = .{ .x = .{ .xPercent = 50 }, .y = .{ .yPercent = 50 } },
    size: gui.Element.Size = .{ .width = .{ .xPercent = 50 }, .height = .{ .yPercent = 100 } },
    ///a pointer to a float that will be updated with the sliders value from 0 to 1

    slideBarBackground: gui.Element.ElementBackground = .{ .solid = .{ 0.8, 0.3, 0.3, 1 } },
    sliderScrollerBackground: gui.Element.ElementBackground = .{ .solid = .{ 0.3, 0.8, 0.3, 1 } },
    
    onSlide:?fn(slider: *gui.Element, slideData: SlideData, window: *glfw.Window) void = null,
    
    scrollerStartPos: gui.Element.Position = .{ .x = .{ .xPercent = 50 }, .y = .{ .yPercent = 50 } },
    
    scrollerSize: gui.Element.Size =  .{
        .width = .{ .xPercent = 80 },
        .height = .{ .yPercent = 10 },
    },
    fn OnHover(element: *gui.Element, mousePos: [2]f64, window: *glfw.Window, toggle: bool) void {
        _ = mousePos;
        if(toggle and window.getMouseButton(glfw.MouseButton.left) == glfw.Action.press) {
            const slideData:*SlideData  = @ptrCast(@alignCast(element.customData.?));
            if (slideData.clickedLastDraw[0] == false) {
                slideData.isClicked = true;
                  }
        }
    }

    fn OnDrawY(element: *gui.Element, mousePos: [2]f64, window: *glfw.Window) void {
        const slideData:*SlideData  = @ptrCast(@alignCast(element.customData.?));
        slideData.clickedLastDraw[0] = slideData.clickedLastDraw[1];
        slideData.clickedLastDraw[1] = window.getMouseButton(glfw.MouseButton.left) == glfw.Action.press;
        slideData.isClicked = slideData.isClicked and window.getMouseButton(glfw.MouseButton.left) == glfw.Action.press;
        std.debug.print("cld: {any}\n", .{slideData.isClicked});

        if(slideData.isClicked) {
            const scrollerHalfHeight = element.children.?[0].options.size.height.as(element.viewport_pixels, element.viewport_millimeters, null, 1, .yPercent) * 0.01 * 0.5;
            const sliderPos:f32 = @floatCast(@min(1 - (scrollerHalfHeight),@max(0 + (scrollerHalfHeight),mousePos[1])));
            element.children.?[0].options.position.y.yPercent =  100 * sliderPos;
            slideData.sliderPos = gui.NormilizeInRange(sliderPos, 0 + scrollerHalfHeight, 1 - scrollerHalfHeight, 0, 1);
            element.children.?[0].update();
            if(slideData.lastSliderPos != slideData.sliderPos and slideData.onSlide != null) {
                slideData.onSlide.?(element, slideData, window);
            }
            slideData.lastSliderPos = slideData.sliderPos;
        }
    }
    
    fn OnDrawX(element: *gui.Element, mousePos: [2]f64, window: *glfw.Window) void {
        const slideData:*SlideData  = @ptrCast(@alignCast(element.customData.?));
        slideData.clickedLastDraw[0] = slideData.clickedLastDraw[1];
        slideData.clickedLastDraw[1] = window.getMouseButton(glfw.MouseButton.left) == glfw.Action.press;
        slideData.isClicked = slideData.isClicked and window.getMouseButton(glfw.MouseButton.left) == glfw.Action.press;

        if(slideData.isClicked) {
            const scrollerHalfWidth = element.children.?[0].options.size.width.as(element.viewport_pixels, element.viewport_millimeters, null, 0, .xPercent) * 0.01 * 0.5;
            const sliderPos:f32 = @floatCast(@min(1 - (scrollerHalfWidth),@max(0 + (scrollerHalfWidth),mousePos[0])));
            element.children.?[0].options.position.x.xPercent =  100 * sliderPos;
            slideData.sliderPos = gui.NormilizeInRange(sliderPos, 0 + scrollerHalfWidth, 1 - scrollerHalfWidth, 0, 1);
            element.children.?[0].update();
            if(slideData.lastSliderPos != slideData.sliderPos and slideData.onSlide != null) {
                slideData.onSlide.?(element, slideData, window);
            }
            slideData.lastSliderPos = slideData.sliderPos;
        }
    }
    
    
    fn OnInit(element: *gui.Element) void {
        const b = SlideData{};
        @memcpy(element.customData.?, @as([]const u8, @ptrCast(&b)));
    }
};

///returns the creation options for a slider, childrenBuffer must remain unchanger until Init is called
///function must be comptime if childrenBuffer is null
pub fn Slider(options: SliderOptions, childrenBuffer: ?*[1]gui.Element.CreationOptions, axis: enum(u1) {x = 0,y = 1}) gui.Element.CreationOptions { //TODO widgets
    std.debug.assert((!@inComptime() and childrenBuffer != null) or childrenBuffer == null );
    const childrenData:[1]gui.Element.CreationOptions = .{.{
        .position = options.scrollerStartPos,
        .size = options.scrollerSize,
        .cornerPixelRadii = @splat(.{.pixels = 15}),
        .elementBackground = options.sliderScrollerBackground,
        .children = null,
        
    }};
    if(childrenBuffer != null) {
    childrenBuffer.?[0] = childrenData[0];
    }
    return .{
        .cornerPixelRadii = @splat(.{.pixels = 15}),
        .position = options.centerPos,
        .size = options.size,
        .elementBackground = options.slideBarBackground,
        .onHover = SliderOptions.OnHover,
        .onInit = SliderOptions.OnInit,
        .onDraw = if(axis == .x) SliderOptions.OnDrawX else SliderOptions.OnDrawY,
        .customDataLen = @sizeOf(SlideData),
        .children = childrenBuffer orelse &childrenData,
    };
}
