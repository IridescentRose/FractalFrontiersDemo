const std = @import("std");
const sdl3 = @import("sdl3");
const State = @import("State.zig");
const sm = @import("statemachine.zig");
const input = @import("input.zig");
const util = @import("util.zig");
const gfx = @import("../gfx/gfx.zig");
const audio = @import("../audio/audio.zig");
pub const tracy = @import("tracy");

pub var running = true;

const init_flags = sdl3.InitFlags{
    .video = true,
    .audio = true,
};

const Config = struct {
    width: u32,
    height: u32,
    vsync: bool,
    fps: u32,
};

var config = Config{
    .width = 1280,
    .height = 720,
    .vsync = true,
    .fps = 60,
};

pub var doIntro = false;

fn parse_config() !void {
    const buf = try util.readFileAlloc("config.txt", 1024);
    defer util.allocator().free(buf);

    var lines = std.mem.splitScalar(u8, buf, '\n');

    while (lines.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len == 0) continue;

        var parts = std.mem.splitScalar(u8, trimmed_line, '=');
        const key = std.mem.trim(u8, parts.first(), " \t");
        if (parts.next()) |value| {
            const intval = try std.fmt.parseInt(u32, std.mem.trim(u8, value, " \t\r"), 10);
            if (std.mem.eql(u8, key, "vsync")) {
                config.vsync = intval != 0;
            } else if (std.mem.eql(u8, key, "fps")) {
                config.fps = intval;
            } else if (std.mem.eql(u8, key, "width")) {
                config.width = intval;
            } else if (std.mem.eql(u8, key, "height")) {
                config.height = intval;
            } else if (std.mem.eql(u8, key, "intro")) {
                doIntro = intval != 0;
            }
        }
    }
}

var can_quit = true;
pub var quit_cb: ?*const fn () void = null;
pub fn set_quit(enabled: bool) void {
    can_quit = enabled;
}

pub fn init(io: std.Io, state: State) !void {
    util.init(io);

    parse_config() catch |err| {
        std.debug.print("Failed to parse config: {}\n", .{err});
        // Continue with default config
        std.debug.print("Using default config: width={}, height={}, vsync={}, fps={}\n", .{
            config.width, config.height, config.vsync, config.fps,
        });
    };

    try sdl3.init(init_flags);
    input.init();
    try gfx.init(config.width, config.height, "Fractal Frontiers");

    try audio.init();

    try sm.init(state);
}

pub fn deinit() void {
    sm.deinit();

    audio.deinit();
    gfx.deinit();

    sdl3.quit(init_flags);
    sdl3.shutdown();

    input.deinit();
    util.deinit();
}

fn handle_updates() void {
    const zone = tracy.Zone.begin(.{
        .name = "Event Polling",
        .src = @src(),
        .color = .green,
    });
    defer zone.end();

    while (sdl3.events.poll()) |event| {
        switch (event) {
            .quit, .terminating => if (can_quit) {
                running = false;
            } else if (quit_cb) |cb| {
                cb();
            },
            .key_down, .key_up => |t| {
                if (t.scancode != null) {
                    if (input.get_key_callback(t.scancode.?)) |cbd| {
                        cbd.cb(cbd.ctx, t.down);
                    }
                }
            },
            .mouse_button_down, .mouse_button_up => |t| {
                if (input.get_mouse_callback(t.button)) |cbd| {
                    cbd.cb(cbd.ctx, t.down);
                }
            },
            .mouse_motion => |t| {
                if (input.mouse_relative_handle) |h| {
                    h.cb(h.ctx, t.x_rel, t.y_rel);
                }
            },
            .mouse_wheel => |t| {
                input.scroll_pos -= @intFromFloat(t.scroll_y);

                const SCROLL_MAX = 10; // Arbitrary limit for scroll position
                const SCROLL_MIN = -5; // Arbitrary limit for scroll position
                input.scroll_pos = std.math.clamp(input.scroll_pos, SCROLL_MIN, SCROLL_MAX);
            },
            else => {
                // std.debug.print("Received unknown event! {any}\n", .{event});
            },
        }
    }
}

pub fn event_loop() !void {
    const frame_rate = config.fps;
    const frame_time_ns = std.time.ns_per_s / frame_rate;

    var next_frame_start = util.nanoTimestamp() + frame_time_ns;

    var fps: usize = 0;
    var second_timer = util.nanoTimestamp() + std.time.ns_per_s;

    while (running) {
        tracy.frameMarkStart("event_loop");
        defer tracy.frameMarkEnd("event_loop");

        const now = util.nanoTimestamp();

        audio.update();
        handle_updates();

        if (util.nanoTimestamp() > second_timer) {
            std.debug.print("FPS: {}\n", .{fps});
            fps = 0;
            second_timer = util.nanoTimestamp() + std.time.ns_per_s;
        }
        fps += 1;

        if (now < next_frame_start and config.vsync) {
            // Poll for events
            var new_time = util.nanoTimestamp();
            while (new_time < next_frame_start) {
                new_time = util.nanoTimestamp();
                handle_updates();

                // This doesn't guarantee a stable frame rate, but it helps prevent busy-waiting
                std.Io.sleep(util.io(), .{ .nanoseconds = std.time.ns_per_ms }, .awake) catch {};
            }
        }

        // Simulation update w/ input
        try sm.update();

        // Shadow pass
        // Build draw list
        try sm.draw(true);

        // Commit to GPU and render to screen
        try gfx.finalize(true);

        // Render pass
        // Build draw list
        try sm.draw(false);

        // Commit to GPU and render to screen
        try gfx.finalize(false);

        next_frame_start += frame_time_ns;

        const drift_limit_ns = frame_time_ns * 2;
        const curr_time = util.nanoTimestamp();

        if (curr_time > next_frame_start + drift_limit_ns) {
            next_frame_start = curr_time;

            if (config.vsync) {
                std.debug.print("Fell 2 frames behind!\n", .{});
            }
        }
    }
}
