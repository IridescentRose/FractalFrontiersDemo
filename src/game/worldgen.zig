const std = @import("std");
const Chunk = @import("chunk.zig");
const util = @import("../core/util.zig");
const c = @import("consts.zig");
const znoise = @import("znoise");
const world = @import("world.zig");
const blocks = @import("blocks.zig");

var gen = znoise.FnlGenerator{
    .seed = 1337,
    .frequency = 0.25,
    .noise_type = .perlin,
    .rotation_type3 = .none,
    .fractal_type = .fbm,
    .octaves = 3,
    .lacunarity = 2.0,
    .gain = 0.5,
    .weighted_strength = 0.0,
    .ping_pong_strength = 2.0,
    .cellular_distance_func = .euclideansq,
    .cellular_return_type = .distance,
    .cellular_jitter_mod = 1.0,
    .domain_warp_type = .opensimplex2,
    .domain_warp_amp = 1.0,
};

pub fn init(s: u64) !void {
    gen.seed = @truncate(@as(i64, @bitCast(s)));
}
pub fn deinit() void {}

fn fbm(x: f64, z: f64) f64 {
    return gen.noise2(@floatCast(x), @floatCast(z)); // Normalize to [0, 1]
}

fn clamp(value: f64, min: f64, max: f64) f64 {
    if (value < min) return min;
    if (value > max) return max;
    return value;
}

pub fn height_at(x: f64, z: f64) f64 {
    const scaleBase = 0.001;
    const scaleDetail = 0.01;
    const scale = 0.001;

    const warp = fbm(x * 0.01, z * 0.01) * 20.0;
    const warpedBase = fbm((x + warp) * scale, (z + warp) * scale);

    const base = fbm(x * scaleBase + warpedBase, z * scaleBase + warpedBase);
    const ridged = 1.0 - @abs(fbm(x * 0.002 + warpedBase, z * 0.002 + warpedBase));
    const detail = fbm(x * scaleDetail + warpedBase, z * scaleDetail + warpedBase);

    const valleyMask = clamp(1.0 - @abs(fbm(x * 0.0005, z * 0.0005)), 0.0, 1.0);
    const erosion = std.math.pow(f64, valleyMask, 1.5);

    // Weight & combine
    const weighted = base * 40.0 // base terrain scale
    + ridged * 30.0 * erosion // mountain sharpness
    + detail * 5.0; // micro variation

    return weighted * 6.0 + 168.0; // scale and offset to fit in the world
}

const WATER_LEVEL = 256.0;

pub fn fillPlace(chunk: Chunk, internal_location: [3]usize, stencil: *const blocks.Stencil) void {
    for (0..c.SUB_BLOCKS_PER_BLOCK) |z| {
        for (0..c.SUB_BLOCKS_PER_BLOCK) |y| {
            for (0..c.SUB_BLOCKS_PER_BLOCK) |x| {
                const location = [_]usize{
                    internal_location[0] * c.SUB_BLOCKS_PER_BLOCK + x,
                    internal_location[1] * c.SUB_BLOCKS_PER_BLOCK + y,
                    internal_location[2] * c.SUB_BLOCKS_PER_BLOCK + z,
                };

                const idx = Chunk.get_index(location);
                const stidx = blocks.stencil_index(location);
                if (world.blocks[chunk.offset + idx].material != .Air) continue; // Don't overwrite existing blocks
                world.blocks[chunk.offset + idx] = stencil[stidx];
            }
        }
    }
}

pub fn fill(chunk: Chunk, location: [2]isize) ![256][2]usize {
    const blocks_per_chunk = c.CHUNK_SUB_BLOCKS;

    var heightmap = std.ArrayList(f32).empty;
    defer heightmap.deinit(util.allocator());
    for (0..c.CHUNK_SUB_BLOCKS) |z| {
        for (0..c.CHUNK_SUB_BLOCKS) |x| {
            const ix: isize = @intCast(x);
            const iz: isize = @intCast(z);

            const world_x = ix + location[0] * blocks_per_chunk;
            const world_z = iz + location[1] * blocks_per_chunk;
            try heightmap.append(util.allocator(), @floatCast(height_at(@floatFromInt(world_x), @floatFromInt(world_z))));
        }
    }

    var count: usize = 0;
    for (0..c.CHUNK_SUB_BLOCKS * c.VERTICAL_CHUNKS) |y| {
        for (0..c.CHUNK_SUB_BLOCKS) |z| {
            for (0..c.CHUNK_SUB_BLOCKS) |x| {
                count += 1;
                const h = heightmap.items[z * c.CHUNK_SUB_BLOCKS + x];

                const yf = @as(f64, @floatFromInt(y));

                const pos = [_]usize{ x, y, z };

                const idx = Chunk.get_index(pos);
                const stidx = blocks.stencil_index(pos);

                var atom_kind: Chunk.AtomKind = .Air;

                if (y < 16) {
                    atom_kind = .Bedrock;
                } else if (yf < h - 12.0) {
                    atom_kind = .Stone;
                } else if (yf < h - 2.0) {
                    atom_kind = if (h < WATER_LEVEL) .Sand else .Dirt;
                } else if (yf < h) {
                    atom_kind =
                        if (h < WATER_LEVEL + 6.0)
                            .Sand
                        else if (h < WATER_LEVEL + 7.0)
                            .Dirt
                        else
                            .Grass;
                } else if (yf <= WATER_LEVEL) {
                    atom_kind = .StillWater;
                }

                if (atom_kind != .Air) {
                    world.blocks[chunk.offset + idx] = blocks.registry[@intFromEnum(atom_kind)][stidx];
                }
            }
        }
    }

    const loc_hash: isize = @truncate(location[0] * 31 + location[1] * 17);
    var prng = std.Random.DefaultPrng.init(@bitCast(loc_hash));
    const foliage_density = 0.01; // Chance of patch per (x,z)

    // TODO: Fix the bug where foliage and trees generate outside the chunk bounds
    // (happens when x or z is near the edge of the chunk)
    for (0..c.CHUNK_SUB_BLOCKS) |z| {
        for (0..c.CHUNK_SUB_BLOCKS) |x| {
            if (prng.random().float(f32) < foliage_density) {
                const h = heightmap.items[z * c.CHUNK_SUB_BLOCKS + x];
                const surface_y: usize = @intFromFloat(h);

                const idx = Chunk.get_index([_]usize{ x, surface_y, z });
                if (world.blocks[chunk.offset + idx].material != .Grass) continue; // Only place foliage on grass

                if (h > WATER_LEVEL + 2.0) {
                    const patch_type = prng.random().uintLessThan(u32, 16); // 0: tallgrass, 1: bush

                    const patch_size = 1 + prng.random().uintLessThan(u32, 3); // size 1 to 3

                    for (0..patch_size) |_| {
                        // Try placing around (x, z) with slight offsets

                        if (patch_type != 0) {
                            for (0..3) |sy| {
                                const dx = @min(c.CHUNK_SUB_BLOCKS - 1, (x + prng.random().uintLessThan(u32, 2)));
                                const dz = @min(c.CHUNK_SUB_BLOCKS - 1, (z + prng.random().uintLessThan(u32, 2)));
                                const dy = surface_y + 1 + sy; // Place foliage one block above ground
                                const pos = [_]usize{ dx, dy, dz };

                                const in_idx = Chunk.get_index(pos);
                                const stidx = blocks.stencil_index(pos);
                                world.blocks[chunk.offset + in_idx] = blocks.registry[@intFromEnum(Chunk.AtomKind.Grass)][stidx];
                            }
                        } else {
                            for (0..36) |_| {
                                for (0..7) |sy| {
                                    const dx = @max(@min(c.CHUNK_SUB_BLOCKS - 2, (x + prng.random().uintLessThan(u32, 8))), 2);
                                    const dz = @max(@min(c.CHUNK_SUB_BLOCKS - 2, (z + prng.random().uintLessThan(u32, 8))), 2);
                                    const dy = surface_y + 1 + sy; // Place foliage one block above ground

                                    const pos = [_]usize{ dx, dy, dz };

                                    const in_idx = Chunk.get_index(pos);
                                    const stidx = blocks.stencil_index(pos);
                                    world.blocks[chunk.offset + in_idx] = blocks.registry[@intFromEnum(Chunk.AtomKind.Leaf)][stidx];
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    var locs = chunk.tree_locs;
    var tree_count: usize = 0;
    for (0..c.CHUNK_BLOCKS) |z| {
        for (0..c.CHUNK_BLOCKS) |x| {
            // Try placing trees
            if (prng.random().float(f32) < 0.0075) {
                locs[tree_count] = [_]usize{ x, z };
                tree_count += 1;
                const h = heightmap.items[(z * c.SUB_BLOCKS_PER_BLOCK) * c.CHUNK_SUB_BLOCKS + (x * c.SUB_BLOCKS_PER_BLOCK)] - 1.0;

                // Check we aren't on water or sand
                if (h < WATER_LEVEL + 6.0) continue; // Don't place trees on water or sand

                // Place a tree
                // Random height between 4 and 7
                const tree_height = 4 + prng.random().uintLessThan(u32, 4) + 1;

                for (0..tree_height) |dy| {
                    const trunk_x = x;
                    const trunk_z = z;
                    const trunk_y = @as(usize, @intFromFloat(h)) / c.SUB_BLOCKS_PER_BLOCK + dy;

                    if (dy < tree_height - 1) {
                        fillPlace(chunk, [_]usize{ trunk_x, trunk_y, trunk_z }, &blocks.registry[@intFromEnum(Chunk.AtomKind.Log)]);
                        if (dy > tree_height / 2 - 1) {
                            // Place leaves
                            for (0..5) |lz| {
                                for (0..5) |lx| {
                                    // Skip corners to make it more round
                                    if (lx == 0 and lz == 0) continue;
                                    if (lx == 0 and lz == 4) continue;
                                    if (lx == 4 and lz == 0) continue;
                                    if (lx == 4 and lz == 4) continue;

                                    // If the current leaf block breaks the chunk boundary, skip it
                                    if (@as(isize, @intCast(trunk_x)) + @as(isize, @intCast(lx)) - 2 >= c.CHUNK_SUB_BLOCKS) continue;
                                    if (@as(isize, @intCast(trunk_z)) + @as(isize, @intCast(lz)) - 2 >= c.CHUNK_SUB_BLOCKS) continue;
                                    if (@as(isize, @intCast(trunk_x)) + @as(isize, @intCast(lx)) - 2 < 0) continue;
                                    if (@as(isize, @intCast(trunk_z)) + @as(isize, @intCast(lz)) - 2 < 0) continue;

                                    fillPlace(chunk, [_]usize{ trunk_x + lx - 2, trunk_y, trunk_z + lz - 2 }, &blocks.registry[@intFromEnum(Chunk.AtomKind.Leaf)]);
                                }
                            }
                        }
                    } else {
                        // Cap the top
                        for (0..3) |lz| {
                            for (0..3) |lx| {
                                if (@as(isize, @intCast(trunk_x)) + @as(isize, @intCast(lx)) - 1 >= c.CHUNK_SUB_BLOCKS) continue;
                                if (@as(isize, @intCast(trunk_z)) + @as(isize, @intCast(lz)) - 1 >= c.CHUNK_SUB_BLOCKS) continue;
                                if (@as(isize, @intCast(trunk_x)) + @as(isize, @intCast(lx)) - 1 < 0) continue;
                                if (@as(isize, @intCast(trunk_z)) + @as(isize, @intCast(lz)) - 1 < 0) continue;

                                const leaf_x = trunk_x + lx - 1;
                                const leaf_z = trunk_z + lz - 1;
                                const leaf_y = trunk_y;

                                fillPlace(chunk, [_]usize{ leaf_x, leaf_y, leaf_z }, &blocks.registry[@intFromEnum(Chunk.AtomKind.Leaf)]);
                            }
                        }
                    }
                }
            }
        }
    }

    return locs;
}
