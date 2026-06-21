const std = @import("std");
const gfx = @import("../../gfx/gfx.zig");
const ui = @import("../../gfx/ui.zig");
const input = @import("../../core/input.zig");
const sm = @import("../../core/statemachine.zig");
const GameState = @import("GameState.zig");
const audio = @import("../../audio//audio.zig");
const app = @import("../../core/app.zig");
const util = @import("../../core/util.zig");

const State = @import("../../core/State.zig");
const Self = @This();

var game_state: GameState = undefined;
var clicked_continue: bool = false;
var continued_audio: bool = false;
var wait_until: i64 = 0;

fn on_quit() void {
    clicked_continue = true;
}

fn init(ctx: *anyopaque) anyerror!void {
    _ = ctx;
    try audio.play_sfx_at_position("assets/intro/intro1.mp3", [_]f32{ 0, 0, 0 });
    app.set_quit(false);
    app.quit_cb = on_quit;
    wait_until = util.milliTimestamp() + 30000; // Wait for 30 seconds
}

fn deinit(ctx: *anyopaque) void {
    _ = ctx;
    ui.clear_sprites();
    app.set_quit(true);
}

fn update(ctx: *anyopaque) anyerror!void {
    _ = ctx;

    if (clicked_continue and !continued_audio and util.milliTimestamp() > wait_until) {
        continued_audio = true;
        try audio.play_sfx_at_position("assets/intro/intro2.mp3", [_]f32{ 0, 0, 0 });
        wait_until = util.milliTimestamp() + 25000; // Wait for another 25 seconds
    }

    if (clicked_continue and continued_audio and util.milliTimestamp() > wait_until) {
        // Transition to the game state
        sm.transition(game_state.state()) catch unreachable;
    }
}

fn draw(ctx: *anyopaque, shadow: bool) anyerror!void {
    _ = ctx;
    gfx.clear_color(0, 0, 0, 1);
    gfx.clear(shadow);

    if (!shadow)
        try ui.update();
}

pub fn state(self: *Self) State {
    return .{ .ptr = self, .tab = .{
        .init = init,
        .deinit = deinit,
        .draw = draw,
        .update = update,
    } };
}
