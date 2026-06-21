const std = @import("std");
const gfx = @import("../../gfx/gfx.zig");
const ui = @import("../../gfx/ui.zig");
const input = @import("../../core/input.zig");
const sm = @import("../../core/statemachine.zig");
const GameState = @import("GameState.zig");
const IntroState = @import("IntroState.zig");
const app = @import("../../core/app.zig");
const util = @import("../../core/util.zig");

const State = @import("../../core/State.zig");
const Self = @This();

var bg_texture: u32 = 0;
var logo_texture: u32 = 0;
var button_texture: u32 = 0;
var button_hover_texture: u32 = 0;
var has_save = true;

var game_state: GameState = undefined;
var intro_state: IntroState = undefined;

fn click(ctx: *anyopaque, down: bool) void {
    _ = ctx;

    if (down) {
        const width: f32 = ui.UI_RESOLUTION[0];
        const height: f32 = ui.UI_RESOLUTION[1];

        const mouse_position = input.get_mouse_position();

        const button_width: f32 = 96 * 7;
        const button_height: f32 = 12 * 7;

        if (mouse_position[0] > (width / 2 - button_width / 2) and
            mouse_position[0] < (width / 2 + button_width / 2) and
            mouse_position[1] > (height / 2 - button_height / 2 - 100) and
            mouse_position[1] < (height / 2 + button_height / 2 - 100))
        {
            if (has_save or !app.doIntro) {
                // Continue game
                sm.transition(game_state.state()) catch unreachable;
            } else {
                // Start new game
                sm.transition(intro_state.state()) catch unreachable;
            }
        }
    }
}

fn init(ctx: *anyopaque) anyerror!void {
    _ = ctx;
    bg_texture = try ui.load_ui_texture("assets/ui/menu_bg.png");
    logo_texture = try ui.load_ui_texture("assets/ui/main_logo.png");
    button_texture = try ui.load_ui_texture("assets/ui/button.png");
    button_hover_texture = try ui.load_ui_texture("assets/ui/button_hover.png");

    try input.register_mouse_callback(.left, .{
        .cb = click,
        .ctx = &game_state,
    });

    var dir = std.Io.Dir.cwd().openDir(util.io(), "world", .{}) catch |err| {
        if (err == error.FileNotFound) {
            has_save = false;
            return;
        } else {
            return err;
        }
    };
    defer dir.close(util.io());

    // TODO: Check for specific files to verify it's a valid save
    has_save = true;
}

fn deinit(ctx: *anyopaque) void {
    _ = ctx;
    ui.clear_sprites();
}

fn update(ctx: *anyopaque) anyerror!void {
    _ = ctx;

    const width: f32 = ui.UI_RESOLUTION[0];
    const height: f32 = ui.UI_RESOLUTION[1];

    ui.clear_sprites();
    try ui.add_sprite(.{
        .color = [_]u8{ 255, 255, 255, 255 },
        .offset = [_]f32{ width / 2, height / 2, 1 },
        .scale = [_]f32{ width, height },
        .tex_id = bg_texture,
    });

    const logo_width: f32 = 54 * 12;
    const logo_height: f32 = 17 * 12;
    try ui.add_sprite(.{
        .color = [_]u8{ 255, 255, 255, 255 },
        .offset = [_]f32{ width / 2, height - 128, 2 },
        .scale = [_]f32{ logo_width, logo_height },
        .tex_id = logo_texture,
    });

    const button_width: f32 = 96 * 7;
    const button_height: f32 = 12 * 7;

    const mouse_position = input.get_mouse_position();

    var text_color = [_]u8{ 255, 255, 255, 255 };
    var tex_id: u32 = button_texture;

    if (mouse_position[0] > (width / 2 - button_width / 2) and
        mouse_position[0] < (width / 2 + button_width / 2) and
        mouse_position[1] > (height / 2 - button_height / 2 - 100) and
        mouse_position[1] < (height / 2 + button_height / 2 - 100))
    {
        tex_id = button_hover_texture;
        text_color = [_]u8{ 255, 255, 80, 255 }; // Yellow color for hover effect
    }

    try ui.add_sprite(.{
        .color = [_]u8{ 168, 168, 168, 255 },
        .offset = [_]f32{ width / 2, height / 2 - 100, 3 },
        .scale = [_]f32{ button_width, button_height },
        .tex_id = tex_id,
    });

    try ui.add_text(if (!has_save) "Start Game" else "Continue Game", [_]f32{ width / 2, height / 2 - 6 - 100 }, text_color, 4, 2, .Center);
    try ui.add_text("Ver 1", [_]f32{ width - 12, 16 }, [_]u8{ 255, 255, 255, 255 }, 4, 1, .Right);
    try ui.add_text("Built With Love", [_]f32{ 12, 16 + 36 }, [_]u8{ 255, 255, 255, 255 }, 4, 1, .Left);
    try ui.add_text("And A Cup Of Coffee", [_]f32{ 12, 16 }, [_]u8{ 255, 255, 255, 255 }, 4, 1, .Left);
}

fn draw(ctx: *anyopaque, shadow: bool) anyerror!void {
    _ = ctx;
    gfx.clear_color(1, 1, 1, 1);
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
