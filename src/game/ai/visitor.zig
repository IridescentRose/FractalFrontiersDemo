const std = @import("std");
const ecs = @import("../entity/ecs.zig");
const components = @import("../entity/components.zig");
const zm = @import("zmath");
const c = @import("../consts.zig");
const world = @import("../world.zig");
const audio = @import("../../audio/audio.zig");
const util = @import("../../core/util.zig");

const TERMINAL_VELOCITY = -10.0; // Max fall speed cap
const GRAVITY = -9.8; // Downward accel applied each frame
const MOVE_SPEED = 1.0; // Horizontal move speed when "moving"

const AI_SEEKING_PLAYER: i32 = 0;
const AI_SEEKING_HOME: i32 = 2;
const AI_IDLE: i32 = 1;

pub fn create(position: [3]f32, rotation: [3]f32, home_pos: [3]isize, model: components.ModelComponent) !ecs.Entity {
    const entity = try ecs.create_entity(.visitor);

    // Core
    try entity.add_component(.transform, components.TransformComponent.new());
    try entity.add_component(.model, model);
    try entity.add_component(.aabb, .{ .aabb_size = [_]f32{ 0.125, 0.125, 0.125 }, .can_step = true });
    try entity.add_component(.velocity, @splat(0));
    try entity.add_component(.on_ground, false);
    try entity.add_component(.health, 10);

    // AI / Timing
    try entity.add_component(.timer, util.milliTimestamp() + std.time.ms_per_s * 1);
    try entity.add_component(.ai_state, AI_SEEKING_PLAYER); // start trying to find player
    try entity.add_component(.home_pos, home_pos);
    try entity.add_component(.target_pos, [_]isize{ 0, 0, 0 });

    // Initial Pos
    const transform = entity.get_ptr(.transform);
    transform.pos = position;
    transform.rot = rotation;
    transform.scale = @splat(1.0 / 10.0);
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
        // Next decision scheduled in 3 seconds.
        time.* = util.milliTimestamp() + std.time.ms_per_s * 3;
        updated = true; // We updated the timer, so we can change behavior
    }

    // Behavior: randomize horizontal direction on timer ticks
    // Seed RNG from timer + entity id to avoid constant changes
    var rng = std.Random.DefaultPrng.init(@as(u64, @bitCast(time.*)) + self.id);

    // Various useful pointers
    var velocity = self.get_ptr(.velocity);
    const transform = self.get_ptr(.transform);
    const ai_state_ptr = self.get_ptr(.ai_state);

    // Day/Night Gate
    const daytime = world.tick % 24000;
    const is_sleep_time = (daytime <= 6000 or daytime >= 18000);

    // Always Gravity
    velocity[1] += GRAVITY * dt;

    blk: switch (ai_state_ptr.*) {
        // Idle Wander
        AI_IDLE => {
            if (is_sleep_time) {
                // Behavior: stand still at night
                velocity[0] = 0.0;
                velocity[2] = 0.0;
            } else {
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
            }
        },

        AI_SEEKING_PLAYER => {
            if (is_sleep_time) return;
            const target_pos = world.player.entity.get_ptr(.transform).pos;
            const dx = target_pos[0] - transform.pos[0];
            const dz = target_pos[2] - transform.pos[2];
            const dist = std.math.sqrt(dx * dx + dz * dz);

            if (dist < 1.5) {
                // TODO: Play sfx, give rewards
                const model = @intFromEnum(self.get(.model));

                switch (model) {
                    5 => {
                        // Mint gives you boba tea
                        _ = world.player.entity.get_ptr(.inventory).add_item_inventory(.{
                            .material = 260,
                            .count = 16,
                        });

                        audio.play_sfx_at_position("assets/mob/mint.mp3", transform.pos) catch unreachable;
                    },
                    6 => {
                        // Dooby Gives you 2 stack wood, 1 stack stone
                        _ = world.player.entity.get_ptr(.inventory).add_item_inventory(.{
                            .material = 8,
                            .count = 64000,
                        });
                        _ = world.player.entity.get_ptr(.inventory).add_item_inventory(.{
                            .material = 8,
                            .count = 64000,
                        });
                        _ = world.player.entity.get_ptr(.inventory).add_item_inventory(.{
                            .material = 2,
                            .count = 64000,
                        });
                        audio.play_sfx_at_position("assets/mob/dooby.mp3", transform.pos) catch unreachable;
                    },
                    7 => {
                        // Nimi gives you suspicious stew
                        _ = world.player.entity.get_ptr(.inventory).add_item_inventory(.{
                            .material = 261,
                            .count = 32,
                        });
                        audio.play_sfx_at_position("assets/mob/nimi.mp3", transform.pos) catch unreachable;
                    },
                    8 => {
                        // Chibi gives you pipe bomb
                        _ = world.player.entity.get_ptr(.inventory).add_item_inventory(.{
                            .material = 262,
                            .count = 64,
                        });
                        audio.play_sfx_at_position("assets/mob/chibi.mp3", transform.pos) catch unreachable;
                    },
                    else => {},
                }

                ai_state_ptr.* = AI_SEEKING_HOME;
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

        AI_SEEKING_HOME => {
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
        else => {},
    }

    // Terminal Velocity
    if (velocity[1] < TERMINAL_VELOCITY) velocity[1] = TERMINAL_VELOCITY;
}
