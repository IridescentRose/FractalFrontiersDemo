const std = @import("std");

pub const Color = enum {
    blue,
    cyan,
    green,
    purple,
    yellow,
};

pub const Zone = struct {
    pub const Options = struct {
        name: []const u8,
        src: std.builtin.SourceLocation,
        color: Color,
    };

    pub fn begin(options: Options) Zone {
        _ = options;
        return .{};
    }

    pub fn end(_: Zone) void {}
};

pub fn frameMarkStart(name: []const u8) void {
    _ = name;
}

pub fn frameMarkEnd(name: []const u8) void {
    _ = name;
}
