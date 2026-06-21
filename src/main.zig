const std = @import("std");
const app = @import("core/app.zig");
const MenuState = @import("game/states/MenuState.zig");
const GameState = @import("game/states/GameState.zig");

// Shim
pub fn main(init: std.process.Init) !void {
    var state: MenuState = undefined;

    try app.init(init.io, state.state());
    defer app.deinit();

    try app.event_loop();
}
