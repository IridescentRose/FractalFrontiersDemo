const std = @import("std");
const ecs = @import("../../entity/ecs.zig");
const components = @import("../../entity/components.zig");
const zm = @import("zmath");
const c = @import("../../consts.zig");
const world = @import("../../world.zig");
const schematic = @import("../../town/schematic.zig");
const audio = @import("../../../audio/audio.zig");
const util = @import("../../../core/util.zig");

const TERMINAL_VELOCITY = -10.0; // Max fall speed cap
const GRAVITY = -9.8; // Downward accel applied each frame
const MOVE_SPEED = 1.0; // Horizontal move speed when "moving"

const AI_IDLE: i32 = 0;
const AI_SLEEP: i32 = 1;
const AI_SEEK_UNBUILT: i32 = 2;
const AI_BUILD_CLEAR: i32 = 3;
const AI_BUILD_PLACE: i32 = 4;
const AI_RETURN: i32 = 5;

pub fn create(position: [3]f32, rotation: [3]f32, home_pos: [3]isize, model: components.ModelComponent) !ecs.Entity {
    const entity = try ecs.create_entity(.dragoon_builder);

    // Core
    try entity.add_component(.transform, components.TransformComponent.new());
    try entity.add_component(.model, model);
    try entity.add_component(.aabb, .{ .aabb_size = [_]f32{ 0.125, 0.125, 0.125 }, .can_step = true });
    try entity.add_component(.velocity, @splat(0));
    try entity.add_component(.on_ground, false);
    try entity.add_component(.health, 10);

    // AI / Timing
    try entity.add_component(.timer, util.milliTimestamp() + std.time.ms_per_s * 1);
    try entity.add_component(.ai_state, AI_IDLE); // start wandering/idle by default
    try entity.add_component(.home_pos, home_pos);
    try entity.add_component(.target_pos, [_]isize{ 0, 0, 0 });

    // Initial Pos
    const transform = entity.get_ptr(.transform);
    transform.pos = position;
    transform.rot = rotation;
    transform.scale = @splat(1.0 / 5.0);
    transform.size = [_]f32{ 20.0, -4.01, 20.0 }; // visual size for model

    return entity;
}

pub fn update(self: ecs.Entity, dt: f32) void {
    // Pre-requisites guard clausse
    const mask = self.get(.mask);
    const can_update = mask.transform and mask.velocity and mask.on_ground;
    if (!can_update) return;

    // World coordinate guard
    const curr_pos = [_]isize{
        @intFromFloat(self.get(.transform).pos[0]),
        @intFromFloat(@max(@min(self.get(.transform).pos[1], 62.0), 0)), // clamp Y to world height
        @intFromFloat(self.get(.transform).pos[2]),
    };
    if (!world.is_in_world([_]isize{
        curr_pos[0] * c.SUB_BLOCKS_PER_BLOCK,
        curr_pos[1] * c.SUB_BLOCKS_PER_BLOCK,
        curr_pos[2] * c.SUB_BLOCKS_PER_BLOCK,
    })) return;

    // Timer -- the internal "think" rate of the dragoon
    const time = self.get_ptr(.timer);
    var updated = false;
    if (util.milliTimestamp() >= time.*) {
        if (self.get(.ai_state) == AI_IDLE) {
            // Next decision scheduled in 3 seconds.
            time.* = util.milliTimestamp() + std.time.ms_per_s * 3;
        } else {
            // Next decision scheduled in 0.5 seconds.
            time.* = util.milliTimestamp() + (std.time.ms_per_s / 2);
        }
        updated = true;
    }

    // Various useful pointers
    var velocity = self.get_ptr(.velocity);
    const transform = self.get_ptr(.transform);
    const ai_state_ptr = self.get_ptr(.ai_state);
    const ai_state: usize = ai_state_ptr.*;

    // Day/Night Gate
    const daytime = world.tick % 24000;
    const is_sleep_time = (daytime <= 6000 or daytime >= 18000);

    // Always Gravity
    velocity[1] += GRAVITY * dt;

    blk: switch (ai_state) {
        // Idle Wander
        AI_IDLE => {
            if (is_sleep_time) {
                // Behavior: stand still at night
                velocity[0] = 0.0;
                velocity[2] = 0.0;
            } else {
                // Behavior: randomize horizontal direction on timer ticks
                // Seed RNG from timer + entity id to avoid constant changes
                var rng = std.Random.DefaultPrng.init(@as(u64, @bitCast(time.*)) + self.id);

                const size: f32 = @floatFromInt(std.math.maxInt(i16));
                const x: f32 = @floatFromInt(rng.random().intRangeAtMost(i16, std.math.minInt(i16), std.math.maxInt(i16)));
                const z: f32 = @floatFromInt(rng.random().intRangeAtMost(i16, std.math.minInt(i16), std.math.maxInt(i16)));

                // Raw random components
                velocity[0] = x / size;
                velocity[2] = z / size;

                // Ensure non-zero horizontal movement
                if (velocity[0] == 0.0 and velocity[2] == 0.0) {
                    velocity[0] = 1.0;
                    velocity[2] = 1.0;
                }

                // Normalize to MOVE_SPEED (so large RNG spikes don't change speed)
                const THRESHOLD: f32 = 0.1;
                if (velocity[0] * velocity[0] + velocity[2] * velocity[2] > THRESHOLD * THRESHOLD) {
                    const norm = zm.normalize3([_]f32{ velocity[0], 0.0, velocity[2], 0.0 }) *
                        @as(@Vector(4, f32), @splat(MOVE_SPEED));
                    velocity[0] = norm[0];
                    velocity[2] = norm[2];

                    // Face movement direction
                    transform.rot[1] = std.math.radiansToDegrees(std.math.atan2(velocity[0], velocity[2])) + 180.0;
                }

                // Find building site
                for (0..world.town.building_count) |i| {
                    const building = world.town.buildings[i];
                    if (!building.is_built) {
                        ai_state_ptr.* = AI_SEEK_UNBUILT;
                        self.get_ptr(.target_pos).* = building.position;
                        self.get_ptr(.target_pos)[1] = @intCast(i);
                        return;
                    }
                }
            }
        },

        // ------------------------------
        // SEEK UNBUILT (future hook)
        // ------------------------------
        AI_SEEK_UNBUILT => {
            if (is_sleep_time) return;
            const target_pos = self.get_ptr(.target_pos);
            const dx = @as(f32, @floatFromInt(target_pos[0])) - transform.pos[0];
            const dz = @as(f32, @floatFromInt(target_pos[2])) - transform.pos[2];
            const dist = std.math.sqrt(dx * dx + dz * dz);

            if (dist < 1.5) {
                ai_state_ptr.* = AI_BUILD_CLEAR;
                continue :blk ai_state_ptr.*;
            } else {
                // Move towards the tree
                velocity[0] = dx;
                velocity[2] = dz;
            }

            // Normalize to MOVE_SPEED (so large RNG spikes don't change speed)
            const THRESHOLD: f32 = 0.1;
            if (velocity[0] * velocity[0] + velocity[2] * velocity[2] > THRESHOLD * THRESHOLD) {
                const norm = zm.normalize3([_]f32{ velocity[0], 0.0, velocity[2], 0.0 }) *
                    @as(@Vector(4, f32), @splat(MOVE_SPEED));
                velocity[0] = norm[0];
                velocity[2] = norm[2];

                // Face movement direction
                transform.rot[1] = std.math.radiansToDegrees(std.math.atan2(velocity[0], velocity[2])) + 180.0;
            }
        },

        // ------------------------------
        // BUILD (future hook)
        // ------------------------------
        AI_BUILD_CLEAR => {
            if (is_sleep_time) return;
            velocity[0] = 0;
            velocity[2] = 0;
            if (!updated) return;

            const building_idx: usize = @intCast(self.get_ptr(.target_pos)[1]);
            const building = world.town.buildings[building_idx];
            const size = schematic.schematics[@intFromEnum(building.kind)].size;

            const min: [3]isize = [_]isize{
                building.position[0] - @divTrunc(size[0], 2) - 1,
                building.position[1] + 1,
                building.position[2] - @divTrunc(size[2], 2) - 1,
            };

            const max: [3]isize = [_]isize{
                building.position[0] + @divTrunc(size[0], 2) + 1,
                building.position[1] + size[1] + 1,
                building.position[2] + @divTrunc(size[2], 2) + 1,
            };

            var y: isize = min[1];
            while (y < max[1]) : (y += 1) {
                var z: isize = min[2];
                while (z < max[2]) : (z += 1) {
                    var x: isize = min[0];
                    while (x < max[0]) : (x += 1) {
                        if (!world.only_contained_in_block(.Air, [_]isize{ x, y, z })) {
                            _ = world.place_block(.Air, [_]isize{ x, y, z });

                            audio.play_sfx_at_position("assets/sfx/plop.mp3", [_]f32{ @floatFromInt(x), @floatFromInt(y), @floatFromInt(z) }) catch unreachable;
                            return;
                        }
                    }
                }
            }

            ai_state_ptr.* = AI_BUILD_PLACE;
            continue :blk ai_state_ptr.*; // Go to place schematic
        },

        AI_BUILD_PLACE => {
            if (is_sleep_time) return;
            velocity[0] = 0;
            velocity[2] = 0;
            if (!updated) return;

            const building_idx: usize = @intCast(self.get_ptr(.target_pos)[1]);
            const building = world.town.buildings[building_idx];
            const size = schematic.schematics[@intFromEnum(building.kind)].size;

            const min: [3]isize = [_]isize{
                building.position[0] - @divTrunc(size[0], 2) - 1,
                building.position[1],
                building.position[2] - @divTrunc(size[2], 2) - 1,
            };

            var curr_progress: usize = 0;
            for (0..size[1]) |y| {
                for (0..size[2]) |z| {
                    for (0..size[0]) |x| {
                        curr_progress += 1;
                        if (curr_progress < world.town.buildings[building_idx].progress) continue;
                        const block_idx = schematic.schematics[@intFromEnum(building.kind)].index([_]usize{ x, y, z });
                        const block_type = schematic.schematics[@intFromEnum(building.kind)].blocks[block_idx];
                        const r_block_type = if (block_type == 20) 8 else block_type; // Replace air with water
                        if (r_block_type != 0) {
                            if (world.town.inventory.get_total_material(r_block_type) > 512) {
                                _ = world.town.inventory.remove_count_inventory(.{ .material = r_block_type, .count = if (r_block_type == 8) 32 else 512 });
                                world.town.buildings[building_idx].progress += 1;
                                // Place the block
                                _ = world.place_block(@enumFromInt(block_type), [_]isize{ min[0] + @as(isize, @intCast(x)), min[1] + @as(isize, @intCast(y)), min[2] + @as(isize, @intCast(z)) });
                            }
                            return;
                        }
                    }
                }
            }

            // We're done
            ai_state_ptr.* = AI_RETURN;
            world.town.buildings[building_idx].is_built = true;
            continue :blk ai_state_ptr.*; // Go to place schematic
        },

        // ------------------------------
        // RETURN HOME (future hook)
        // ------------------------------
        AI_RETURN => {
            const home = self.get(.home_pos);
            const dx = @as(f32, @floatFromInt(home[0])) - transform.pos[0];
            const dz = @as(f32, @floatFromInt(home[2])) - transform.pos[2];
            const dist = std.math.sqrt(dx * dx + dz * dz);

            if (dist < 1.5) {
                ai_state_ptr.* = AI_IDLE;
                continue :blk ai_state_ptr.*;
            } else {
                // Move towards the home position
                velocity[0] = dx;
                velocity[2] = dz;
            }

            // Normalize to MOVE_SPEED (so large RNG spikes don't change speed)
            const THRESHOLD: f32 = 0.1;
            if (velocity[0] * velocity[0] + velocity[2] * velocity[2] > THRESHOLD * THRESHOLD) {
                const norm = zm.normalize3([_]f32{ velocity[0], 0.0, velocity[2], 0.0 }) *
                    @as(@Vector(4, f32), @splat(MOVE_SPEED));
                velocity[0] = norm[0];
                velocity[2] = norm[2];

                // Face movement direction
                transform.rot[1] = std.math.radiansToDegrees(std.math.atan2(velocity[0], velocity[2])) + 180.0;
            }
        },

        // Basically idle, fallback
        else => {},
    }

    // Terminal Velocity
    if (velocity[1] < TERMINAL_VELOCITY) velocity[1] = TERMINAL_VELOCITY;
}
