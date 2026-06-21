const std = @import("std");
const assert = std.debug.assert;
const tracy = @import("tracy");

var initialized: bool = false;

pub const Sound = struct {
    playing: bool = false,

    pub fn destroy(_: *Sound) void {}

    pub fn setPosition(_: *Sound, _: [3]f32) void {}

    pub fn start(self: *Sound) !void {
        self.playing = true;
    }

    pub fn stop(self: *Sound) !void {
        self.playing = false;
    }

    pub fn isPlaying(self: *const Sound) bool {
        return self.playing;
    }
};

pub const Clip = struct {
    sound: Sound,

    pub fn load_from_file(path: [:0]const u8, stream: bool, spatial: bool) !Clip {
        _ = path;
        _ = stream;
        _ = spatial;
        return .{ .sound = .{} };
    }

    pub fn deinit(self: *Clip) void {
        self.sound.destroy();
    }

    pub fn set_position(self: *Clip, pos: [3]f32) void {
        self.sound.setPosition(pos);
    }

    pub fn start(self: *Clip) !void {
        try self.sound.start();
    }
};

pub fn set_listener_position(pos: [3]f32) void {
    _ = pos;
}

pub fn set_listener_direction(dir: [3]f32) void {
    _ = dir;
}

// Function to play SFX at a specific position with spatialization
pub fn play_sfx_at_position(path: [:0]const u8, pos: [3]f32) !void {
    _ = path;
    _ = pos;
}

pub fn play_sfx_no_position(path: [:0]const u8) !void {
    _ = path;
}

pub fn init() !void {
    assert(!initialized);

    set_listener_position([_]f32{ 0.0, 0.0, 0.0 });
    set_listener_direction([_]f32{ 0.0, 0.0, 1.0 });

    initialized = true;
    assert(initialized);
}

pub fn deinit() void {
    assert(initialized);

    initialized = false;
    assert(!initialized);
}

pub fn update() void {
    const zone = tracy.Zone.begin(.{
        .name = "Audio Update",
        .src = @src(),
        .color = .blue,
    });
    defer zone.end();
}
