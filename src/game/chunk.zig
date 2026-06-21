const std = @import("std");
const c = @import("consts.zig");
const world = @import("world.zig");

pub const AtomKind = enum(u8) {
    Air = 0,
    Dirt = 1,
    Stone = 2,
    Grass = 4,
    Sand = 5,
    StillWater = 6,
    Leaf = 7,
    Log = 8,
    Bedrock = 13,
    TownBlock = 14,
    FarmBlock = 15,
    Crop = 19,
    Path = 16,
    Fence = 17,
    Home = 18,
    Plank = 20,

    // TODO: These need to have stencils
    Charcoal = 12,
    Water = 3,
    Fire = 9,
    Ember = 10,
    Ash = 11,
};

pub const Atom = struct {
    material: AtomKind,
    color: [3]u8,

    comptime {
        if (@sizeOf(Atom) != 4) {
            @compileError("Atom struct size must be 4 bytes");
        }
    }
};

// Simulation data for active atoms (e.g. falling sand)
pub const AtomData = struct {
    coord: AtomCoord,
    moves: u8,
};

pub const AtomCoord = [3]isize;

offset: u32,
size: u32 = c.CHUNK_SUBVOXEL_SIZE,
populated: bool = false,
uploaded: bool = false,
edits: std.AutoArrayHashMapUnmanaged(usize, Atom),
tree_locs: [256][2]usize = @splat(@as([2]usize, @splat(0))),

pub fn get_index(coord: [3]usize) usize {
    return (coord[1] * c.CHUNK_SUB_BLOCKS + coord[2]) * c.CHUNK_SUB_BLOCKS + coord[0];
}

pub fn save(self: *@This(), coord: [2]isize) void {
    _ = self;
    _ = coord;
}

pub fn load(self: *@This(), coord: [2]isize) void {
    _ = self;
    _ = coord;
}
