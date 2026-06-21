const std = @import("std");
const util = @import("../core/util.zig");
const assert = std.debug.assert;
const Chunk = @import("chunk.zig");
const worldgen = @import("worldgen.zig");
const world = @import("world.zig");
const c = @import("consts.zig");

const GenJob = struct {
    pos: [2]isize, // Chunk Position
};

const Job = union(enum) {
    GenerateChunk: GenJob,
    // SpreadFire, SaveChunk, etc.
};

var initialized: bool = false;
pub var job_mutex = util.Mutex{};
pub var job_queue: std.ArrayList(Job) = .empty;

pub var thread_list: std.ArrayList(std.Thread) = undefined;
var running = true;

pub fn init() !void {
    assert(!initialized);

    job_queue = .empty;
    initialized = true;
    assert(initialized);

    thread_list = std.ArrayList(std.Thread).empty;

    // At least one thread
    const thread_count = @max(2, try std.Thread.getCpuCount()) - 1;
    for (0..thread_count) |_| {
        try thread_list.append(util.allocator(), try std.Thread.spawn(.{}, worker_thread, .{}));
    }
}

fn worker_thread() void {
    while (running) {
        if (job_queue.items.len == 0) {
            std.Io.sleep(util.io(), .{ .nanoseconds = std.time.ns_per_ms }, .awake) catch {};
            continue;
        }

        job_mutex.lock();
        if (job_queue.items.len == 0) {
            job_mutex.unlock();
            std.Io.sleep(util.io(), .{ .nanoseconds = std.time.ns_per_ms }, .awake) catch {};
            continue;
        }
        const job = job_queue.orderedRemove(0);
        job_mutex.unlock();

        switch (job) {
            .GenerateChunk => |gen| {
                world.chunkMapWriteLock.lock();
                var chunk = world.chunkMap.get(gen.pos) orelse {
                    world.chunkMapWriteLock.unlock();
                    continue;
                };
                world.chunkMapWriteLock.unlock();

                @memset(world.blocks[chunk.offset .. chunk.offset + c.CHUNK_SUBVOXEL_SIZE], .{ .material = .Air, .color = [_]u8{ 0, 0, 0 } });
                const locs = worldgen.fill(chunk, gen.pos) catch |err| {
                    std.debug.print("Error generating chunk at {any}: {}\n", .{ gen.pos, err });
                    continue;
                };

                chunk.load(gen.pos);

                world.chunkMapWriteLock.lock();
                world.chunkMap.put(util.allocator(), gen.pos, .{
                    .offset = chunk.offset,
                    .size = chunk.size,
                    .populated = true,
                    .uploaded = false,
                    .tree_locs = locs,
                    .edits = chunk.edits,
                }) catch |err| {
                    std.debug.print("Error updating chunk map for {any}: {}\n", .{ gen.pos, err });
                    world.chunkMapWriteLock.unlock();
                };
                world.chunkMapWriteLock.unlock();

                world.inflight_chunk_mutex.lock();
                defer world.inflight_chunk_mutex.unlock();

                for (world.inflight_chunk_list.items, 0..) |i, chk| {
                    if (i[0] == gen.pos[0] and i[1] == gen.pos[1]) {
                        // Remove from inflight list
                        _ = world.inflight_chunk_list.swapRemove(chk);
                        break;
                    }
                }
            },
        }
    }
}

pub fn deinit() void {
    assert(initialized);

    running = false;

    // Wait for all threads to finish
    for (thread_list.items) |thread| {
        _ = thread.join();
    }

    {
        job_mutex.lock();
        defer job_mutex.unlock();
        job_queue.deinit(util.allocator());
    }

    initialized = false;
    thread_list.deinit(util.allocator());
    assert(!initialized);
}
