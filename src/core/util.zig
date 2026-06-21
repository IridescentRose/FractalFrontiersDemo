const std = @import("std");
const assert = std.debug.assert;
const GPA = std.heap.DebugAllocator(.{});

var initialized = false;
var gpa: GPA = undefined;
var process_io: std.Io = undefined;

pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(process_io);
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(process_io);
    }
};

pub fn init(init_io: std.Io) void {
    assert(!initialized);

    gpa = GPA{};
    process_io = init_io;
    initialized = true;

    assert(initialized);
}

pub fn deinit() void {
    assert(initialized);

    _ = gpa.deinit();
    initialized = false;

    assert(!initialized);
}

pub fn allocator() std.mem.Allocator {
    assert(initialized);

    return gpa.allocator();
}

pub fn io() std.Io {
    assert(initialized);

    return process_io;
}

pub fn readFileAlloc(path: []const u8, max_bytes: usize) ![]u8 {
    assert(initialized);

    var file = try std.Io.Dir.cwd().openFile(process_io, path, .{});
    defer file.close(process_io);

    const stat = try file.stat(process_io);
    if (stat.size > max_bytes) return error.FileTooBig;

    const buf = try allocator().alloc(u8, @intCast(stat.size));
    const len = try file.readPositionalAll(process_io, buf, 0);
    return buf[0..len];
}

pub fn writeFile(path: []const u8, bytes: []const u8) !void {
    assert(initialized);

    var file = try std.Io.Dir.cwd().createFile(process_io, path, .{ .truncate = true });
    defer file.close(process_io);

    try file.writeStreamingAll(process_io, bytes);
}

pub fn makeDir(path: []const u8) !void {
    assert(initialized);
    try std.Io.Dir.cwd().createDir(process_io, path, .default_dir);
}

pub fn ctx_to_self(comptime T: type, ptr: *anyopaque) *T {
    return @ptrCast(@alignCast(ptr));
}

pub fn nanoTimestamp() i64 {
    assert(initialized);
    return @intCast(std.Io.Clock.awake.now(process_io).nanoseconds);
}

pub fn microTimestamp() i64 {
    assert(initialized);
    return std.Io.Clock.awake.now(process_io).toMicroseconds();
}

pub fn milliTimestamp() i64 {
    assert(initialized);
    return std.Io.Clock.awake.now(process_io).toMilliseconds();
}
