const std = @import("std");
const gfx = @import("../../gfx/gfx.zig");
const world = @import("../world.zig");
const util = @import("../../core/util.zig");
const zm = @import("zmath");

const State = @import("../../core/State.zig");
const Self = @This();

var last_time: i64 = 0;
fn init(ctx: *anyopaque) anyerror!void {
    _ = ctx;
    gfx.set_deferred(true);
    try world.init(@bitCast(util.microTimestamp()));
    last_time = util.microTimestamp();
}

fn deinit(ctx: *anyopaque) void {
    _ = ctx;
    gfx.set_deferred(false);
    world.deinit();
}

fn update(ctx: *anyopaque) anyerror!void {
    _ = ctx;
    const dt = util.microTimestamp() - last_time;
    last_time = util.microTimestamp();
    try world.update(@as(f32, @floatFromInt(dt)) / std.time.us_per_s);
}

fn sun_dir_simple(t: f32) zm.Vec {
    const PI: f32 = 3.14159265358979323846;
    const max_alt: f32 = std.math.degreesToRadians(75.0);
    const alt = zm.sin(2.0 * PI * (t - 0.25)) * max_alt;
    const az = (PI * 0.5) + 2.0 * PI * t;
    return zm.normalize3(zm.Vec{
        zm.sin(az) * zm.cos(alt),
        zm.sin(alt),
        zm.cos(az) * zm.cos(alt),
        0.0,
    });
}

var frame: u32 = 0;
fn draw(ctx: *anyopaque, shadow: bool) anyerror!void {
    _ = ctx;
    gfx.clear_color(0, 0, 0, 1);
    gfx.clear(shadow);

    const t = @as(f32, @floatFromInt(world.tick % 24000)) / 24000.0;

    // dir points from world to the sun (light points along -dir)
    const is_day = (t >= 0.25 and t <= 0.75); // Zig uses 'and'
    const sunDir = sun_dir_simple(t);
    const moonDir = zm.normalize3(-sunDir); // ≈ opposite of sun

    const dir = -(if (is_day) sunDir else moonDir);

    // Pick a stable up
    const worldUp = zm.Vec{ 0, 1, 0, 0 };
    const altUp = zm.Vec{ 0, 0, 1, 0 };
    const up_ws = if (@abs(dir[1]) > 0.9) altUp else worldUp; // threshold ~ cos(25°)

    const center_ws = zm.Vec{ world.player.camera.target[0], world.player.camera.target[1], world.player.camera.target[2], 1.0 };
    const shadow_dist: f32 = 32.0;

    const light_pos = center_ws - dir * @as(zm.Vec, @splat(shadow_dist));

    const light_view = zm.lookAtRh(light_pos, center_ws, up_ws);

    const half = 32.0;
    const nearL = 1.0;
    const farL = 200.0;
    const light_proj = zm.orthographicOffCenterRhGl(-half, half, -half, half, nearL, farL);

    world.light_pv_row = zm.mul(light_view, light_proj);
    gfx.shader.set_shadow_proj(world.light_pv_row);

    world.draw(shadow);
    frame += 1;

    gfx.shader.use_comp_shader();
    gfx.shader.set_comp_resolution();
    gfx.shader.set_comp_inv_proj(zm.inverse(world.player.camera.get_projection_matrix()));
    gfx.shader.set_comp_inv_view(zm.inverse(world.player.camera.get_view_matrix()));
    gfx.shader.set_comp_proj(world.player.camera.get_projection_matrix());
    gfx.shader.set_comp_view(world.player.camera.get_view_matrix());
    gfx.shader.set_comp_is_raining(world.weather.is_raining);
    gfx.shader.set_comp_time(t);
    gfx.shader.set_comp_frame(@intCast(frame));
    gfx.shader.set_comp_fog_color(zm.Vec{ 0.5, 0.6, 0.7, 1 });
    gfx.shader.set_comp_fog_density(0.1);

    gfx.shader.set_comp_camera_pos(zm.Vec{ world.player.camera.target[0], world.player.camera.target[1], world.player.camera.target[2], 1.0 });
}

pub fn state(self: *Self) State {
    return .{ .ptr = self, .tab = .{
        .init = init,
        .deinit = deinit,
        .draw = draw,
        .update = update,
    } };
}
