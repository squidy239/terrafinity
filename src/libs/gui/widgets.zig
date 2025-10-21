const gui = @import("gui.zig");
const glfw = @import("glfw");

const SliderOptions = struct {
    centerPos: gui.Element.Position,
    size: gui.Element.Size,
    ///a pointer to a float that will be updated with the sliders value from 0 to 1
    slideAmountPtr: *f32,
    slideBarBackground: gui.Element.ElementBackground,
    sliderScrollerBackground: gui.Element.ElementBackground,
    //TODO onSlide

    fn OnHover(element: *gui.Element, mouse_pos: [2]f64, window: *glfw.Window, toggle: bool) void {
        _ = mouse_pos;
        _ = window;
        _ = toggle;
        _ = element;
    }
};

var c: [1]gui.Element.CreationOptions = undefined;
///returns the creation options for a slider, childrenBuffer must remain unchanger until Init is called
pub fn Slider(options: SliderOptions, childrenBuffer: *[1]gui.Element.CreationOptions) gui.Element.CreationOptions { //TODO widgets
    _ = childrenBuffer;
    c[0] = .{
        .position = .{ .x = .{ .xPercent = 50 }, .y = .{ .yPercent = 50 } },
        .size = .{
            .width = .{ .xPercent = 50 },
            .height = .{ .yPercent = 50 },
        },
        .elementBackground = options.sliderScrollerBackground,
        .children = null,
        // .onHover = SliderOptions.OnHover,
    };
    return .{
        .position = options.centerPos,
        .size = options.size,
        .elementBackground = options.slideBarBackground,
        //  .onHover = SliderOptions.OnHover,
        .children = &c,
    };
}
