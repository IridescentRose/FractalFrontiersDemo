const std = @import("std");
const assert = std.debug.assert;
const util = @import("util.zig");
const window = @import("../gfx/window.zig");
const ui = @import("../gfx/ui.zig");
const sdl3 = @import("sdl3");

var initialized = false;

pub const InputCallbackFn = *const fn (ctx: *anyopaque, down: bool) void;

pub const InputCallback = struct {
    cb: InputCallbackFn,
    ctx: *anyopaque,
};

const KeyCBMap = std.AutoArrayHashMapUnmanaged(sdl3.Scancode, InputCallback);
const MouseCBMap = std.AutoArrayHashMapUnmanaged(sdl3.mouse.Button, InputCallback);
const MousePosition = @Vector(2, f32);

var keyMap: KeyCBMap = undefined;
var mbMap: MouseCBMap = undefined;

const MouseRelativeFn = *const fn (ctx: *anyopaque, dx: f32, dy: f32) void;

pub const MouseRelativeCallback = struct {
    cb: MouseRelativeFn,
    ctx: *anyopaque,
};

pub var mouse_relative_handle: ?MouseRelativeCallback = null;

pub var scroll_pos: isize = 0;

pub fn init() void {
    assert(!initialized);

    keyMap = .empty;
    mbMap = .empty;

    initialized = true;
    assert(initialized);
}

pub fn get_mouse_position() MousePosition {
    const win_w: f32 = @floatFromInt(window.get_width() catch 0);
    const win_h: f32 = @floatFromInt(window.get_height() catch 0);

    const state = sdl3.mouse.getState();
    return MousePosition{ state[1] / win_w * ui.UI_RESOLUTION[0], (win_h - state[2]) / win_h * ui.UI_RESOLUTION[1] };
}

pub fn register_key_callback(key: sdl3.Scancode, cb: InputCallback) !void {
    assert(initialized);

    try keyMap.put(util.allocator(), key, cb);
}

pub fn get_key_callback(key: sdl3.Scancode) ?InputCallback {
    return keyMap.get(key);
}

pub fn unregister_key_callback(key: sdl3.Scancode) void {
    _ = keyMap.orderedRemove(key);
}

pub fn register_mouse_callback(mb: sdl3.mouse.Button, cb: InputCallback) !void {
    assert(initialized);

    try mbMap.put(util.allocator(), mb, cb);
}

pub fn get_mouse_callback(mb: sdl3.mouse.Button) ?InputCallback {
    return mbMap.get(mb);
}

pub fn unregister_mouse_callback(mb: sdl3.mouse.Button) void {
    _ = mbMap.orderedRemove(mb);
}

pub fn deinit() void {
    assert(initialized);

    keyMap.deinit(util.allocator());
    mbMap.deinit(util.allocator());

    initialized = false;
    assert(!initialized);
}
