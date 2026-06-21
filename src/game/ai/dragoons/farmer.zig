const std = @import("std");
const ecs = @import("../../entity/ecs.zig");
const components = @import("../../entity/components.zig");
const zm = @import("zmath");
const c = @import("../../consts.zig");
const world = @import("../../world.zig");
const audio = @import("../../../audio/audio.zig");
const util = @import("../../../core/util.zig");

const TERMINAL_VELOCITY = -10.0; // Max fall speed cap
const GRAVITY = -9.8; // Downward accel applied each frame
const MOVE_SPEED = 1.0; // Horizontal move speed when "moving"

const AI_IDLE: i32 = 0;
const AI_SLEEP: i32 = 1;
const AI_SEEK_LAND: i32 = 2;
const AI_TILL: i32 = 3;
const AI_PLANT: i32 = 4;
const AI_HARVEST: i32 = 5;
const AI_RETURN: i32 = 6;

var has_grown: bool = false;

pub fn create(position: [3]f32, rotation: [3]f32, home_pos: [3]isize, model: components.ModelComponent) !ecs.Entity {
    const entity = try ecs.create_entity(.dragoon_farmer);

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
    var updated = false;
    const time = self.get_ptr(.timer);
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

                if (world.town.farm_loc) |loc| {
                    ai_state_ptr.* = AI_SEEK_LAND; // Switch to seeking land if farm exists
                    self.get_ptr(.target_pos).* = [_]isize{ @intFromFloat(loc[0]), @intFromFloat(loc[1]), @intFromFloat(loc[2]) };
                    continue :blk ai_state_ptr.*; // Skip to next state
                }
            }
        },

        // ------------------------------
        // SEEK LAND (future hook)
        // ------------------------------
        AI_SEEK_LAND => {
            if (is_sleep_time) return;
            const target_pos = self.get_ptr(.target_pos);
            const dx = @as(f32, @floatFromInt(target_pos[0])) - transform.pos[0];
            const dz = @as(f32, @floatFromInt(target_pos[2])) - transform.pos[2];
            const dist = std.math.sqrt(dx * dx + dz * dz);

            if (dist < 1.5) {
                ai_state_ptr.* = AI_TILL;

                // Adds average tree worth of logs
                _ = world.town.inventory.add_item_inventory(.{
                    .material = 8,
                    .count = 2500,
                });
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
        // TILL LAND (future hook)
        // ------------------------------
        AI_TILL => {
            if (is_sleep_time) return;
            velocity[0] = 0;
            velocity[2] = 0;

            const target_pos = self.get_ptr(.target_pos);
            const minPos = [_]isize{ target_pos[0] - 7, target_pos[1] - 1, target_pos[2] - 7 };
            const maxPos = [_]isize{ target_pos[0] + 7, target_pos[1] + 1, target_pos[2] + 7 };

            var mined_something = false;

            // DEBUG: Speed up
            for (0..16) |_| {
                var y = maxPos[1];
                while (y >= minPos[1]) : (y -|= 1) {
                    var z = minPos[2];
                    var succeeded = false;
                    while (z < maxPos[2]) : (z += 1) {
                        var x = minPos[0];
                        while (x < maxPos[0]) : (x += 1) {
                            succeeded = succeeded or world.break_only_in_block(.Log, [_]isize{ x, y, z });
                            succeeded = succeeded or world.break_only_in_block(.Leaf, [_]isize{ x, y, z });
                            succeeded = succeeded or world.break_only_in_block(.Charcoal, [_]isize{ x, y, z });
                            succeeded = succeeded or world.break_only_in_block(.Ash, [_]isize{ x, y, z });
                            succeeded = succeeded or world.break_only_in_block(.Grass, [_]isize{ x, y, z });
                        }
                    }

                    mined_something = succeeded or mined_something;
                    if (succeeded) break;
                }
            }

            audio.play_sfx_at_position("assets/sfx/plop.mp3", [_]f32{ @floatFromInt(target_pos[0]), @floatFromInt(target_pos[1]), @floatFromInt(target_pos[2]) }) catch unreachable;

            if (!mined_something) {
                // Go to return home
                ai_state_ptr.* = AI_PLANT;
                continue :blk ai_state_ptr.*;
            }
        },

        AI_PLANT => {
            if (is_sleep_time) return;
            velocity[0] = 0;
            velocity[2] = 0;

            const target_pos = self.get_ptr(.target_pos);
            const minPos = [_]isize{ target_pos[0] - 7, target_pos[1], target_pos[2] - 7 };
            const maxPos = [_]isize{ target_pos[0] + 7, target_pos[1] + 1, target_pos[2] + 7 };

            var mined_something = false;

            if (!updated) return;

            var y = minPos[1];
            while (y < maxPos[1]) : (y += 1) {
                var z = minPos[2];
                var succeeded = false;
                while (z < maxPos[2]) : (z += 1) {
                    var x = minPos[0];
                    while (x < maxPos[0]) : (x += 1) {
                        if (!world.contained_in_block(.Crop, [_]isize{ x, y, z }))
                            succeeded = succeeded or world.place_block(.Crop, [_]isize{ x, y, z });
                    }
                }

                mined_something = succeeded or mined_something;
                if (succeeded) break;
            }

            audio.play_sfx_at_position("assets/sfx/plop.mp3", [_]f32{ @floatFromInt(target_pos[0]), @floatFromInt(target_pos[1]), @floatFromInt(target_pos[2]) }) catch unreachable;

            if (!mined_something) {
                // Go to return home
                ai_state_ptr.* = AI_HARVEST;
                has_grown = false;
                continue :blk ai_state_ptr.*;
            }
        },

        AI_HARVEST => {
            velocity[0] = 0.0;
            velocity[1] = 0.0;

            if (is_sleep_time) {
                has_grown = true;
                return;
            }

            if (!has_grown) return;

            const target_pos = self.get_ptr(.target_pos);
            const minPos = [_]isize{ target_pos[0] - 7, target_pos[1] - 1, target_pos[2] - 7 };
            const maxPos = [_]isize{ target_pos[0] + 7, target_pos[1] + 1, target_pos[2] + 7 };

            var mined_something = false;

            // DEBUG: Speed up
            for (0..16) |_| {
                var y = maxPos[1];
                while (y >= minPos[1]) : (y -|= 1) {
                    var z = minPos[2];
                    var succeeded = false;
                    while (z < maxPos[2]) : (z += 1) {
                        var x = minPos[0];
                        while (x < maxPos[0]) : (x += 1) {
                            succeeded = succeeded or world.break_only_in_block(.Log, [_]isize{ x, y, z });
                            succeeded = succeeded or world.break_only_in_block(.Leaf, [_]isize{ x, y, z });
                            succeeded = succeeded or world.break_only_in_block(.Charcoal, [_]isize{ x, y, z });
                            succeeded = succeeded or world.break_only_in_block(.Ash, [_]isize{ x, y, z });
                            succeeded = succeeded or world.break_only_in_block(.Grass, [_]isize{ x, y, z });
                            succeeded = succeeded or world.break_only_in_block(.Crop, [_]isize{ x, y, z });
                        }
                    }

                    mined_something = succeeded or mined_something;
                    if (succeeded) break;
                }
            }

            audio.play_sfx_at_position("assets/sfx/plop.mp3", [_]f32{ @floatFromInt(target_pos[0]), @floatFromInt(target_pos[1]), @floatFromInt(target_pos[2]) }) catch unreachable;

            if (!mined_something) {
                // Go to return home
                ai_state_ptr.* = AI_RETURN;
                continue :blk ai_state_ptr.*;
            }
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

                _ = world.town.inventory.add_item_inventory(.{
                    .material = 260,
                    .count = 2500,
                });
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
