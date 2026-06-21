const sdl3 = @import("sdl3");
const std = @import("std");
const assert = std.debug.assert;

pub var window: sdl3.video.Window = undefined;
var initialized = false;

pub fn init(width: u32, height: u32, title: [:0]const u8) !void {
    assert(!initialized);

    window = try sdl3.video.Window.init(title, width, height, .{
        .input_focus = true,
        .mouse_capture = true,
        .open_gl = true,
        .resizable = false,
    });

    initialized = true;
    assert(initialized);
}

pub fn deinit() void {
    assert(initialized);

    window.deinit();
    initialized = false;
    assert(!initialized);
}

pub fn draw() !void {
    assert(initialized);
    _ = sdl3.c.SDL_GL_SwapWindow(window.value);
}

pub fn context() sdl3.c.SDL_GLContext {
    assert(initialized);
    return sdl3.c.SDL_GL_CreateContext(window.value);
}

pub fn set_title(title: [:0]const u8) !void {
    assert(initialized);
    window.setTitle(title);
}

pub fn get_width() !usize {
    assert(initialized);
    return (try window.getSize())[0];
}

pub fn get_height() !usize {
    assert(initialized);
    return (try window.getSize())[1];
}

pub fn set_relative(mode: bool) !void {
    assert(initialized);

    try sdl3.mouse.setWindowRelativeMode(window, mode);

    if (mode == false) {
        sdl3.mouse.warpInWindow(window, @floatFromInt(try get_width() / 2), @floatFromInt(try get_height() / 2));
    }
}
