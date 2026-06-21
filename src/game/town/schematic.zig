const std = @import("std");
const assert = std.debug.assert;
const util = @import("../../core/util.zig");
const Inventory = @import("../inventory.zig").Inventory;

pub const Schematic = struct {
    version: u8,
    size: [3]u32,
    blocks: []u8,

    pub fn index(self: *const Schematic, position: [3]usize) usize {
        assert(position[0] < self.size[0]);
        assert(position[1] < self.size[1]);
        assert(position[2] < self.size[2]);
        // ((Y * size_Z) + Z) * size_X + X
        return ((position[1] * self.size[2]) + position[2]) * self.size[0] + position[0];
    }

    pub fn cost(self: *const Schematic, kind: u8, progress: usize, necessary_materials: *[5]Inventory.Slot) void {
        var unique_count: usize = 0;

        var curr_progress: usize = 0;
        for (0..self.size[1]) |y| {
            for (0..self.size[2]) |z| {
                for (0..self.size[0]) |x| {
                    curr_progress += 1;
                    if (curr_progress < progress) continue;

                    const block_idx = schematics[kind].index([_]usize{ x, y, z });
                    const block_type = if (schematics[kind].blocks[block_idx] == 20) 8 else schematics[kind].blocks[block_idx];
                    if (block_type != 0) {
                        for (0..unique_count) |i| {
                            if (necessary_materials[i].material == block_type) {
                                necessary_materials[i].count += 1;
                                break;
                            }
                        } else {
                            necessary_materials[unique_count].material = block_type;
                            necessary_materials[unique_count].count = 1;
                            unique_count += 1;
                        }
                    }
                }
            }
        }

        for (0..5) |i| {
            if (necessary_materials[i].material == 8) {
                necessary_materials[i].count = necessary_materials[i].count / 16;
                break;
            }
        }
    }
};

pub var schematics: [16]Schematic = undefined;
var arena: std.heap.ArenaAllocator = undefined;

pub fn init() !void {
    arena = std.heap.ArenaAllocator.init(util.allocator());
    schematics[0] = try load_from_json("assets/schema/townhall.json");
    schematics[1] = try load_from_json("assets/schema/path.json");
    schematics[2] = try load_from_json("assets/schema/barricade.json");
    schematics[3] = try load_from_json("assets/schema/house.json");
}

pub fn deinit() void {
    arena.deinit();
}

pub fn load_from_json(path: []const u8) !Schematic {
    const data = try util.readFileAlloc(path, 16384);
    defer util.allocator().free(data);

    const parsed = try std.json.parseFromSlice(Schematic, arena.allocator(), data, .{});
    // defer parsed.deinit();
    const schematic = parsed.value;

    return schematic;
}
