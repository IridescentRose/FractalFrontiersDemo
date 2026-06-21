const std = @import("std");
const ecs = @import("../entity/ecs.zig");
const components = @import("../entity/components.zig");
const zm = @import("zmath");
const c = @import("../consts.zig");
const world = @import("../world.zig");
const audio = @import("../../audio/audio.zig");
const util = @import("../../core/util.zig");

const TERMINAL_VELOCITY = -50.0; // Max fall speed cap
const GRAVITY = -32; // Downward accel applied each frame
const MOVE_SPEED = 3.0; // Horizontal move speed when "moving"

const AI_SEEKING_TOWN: i32 = 0;
const AI_IDLE: i32 = 1;
const AI_RUNNING_PLAYER: i32 = 2;

pub fn create(position: [3]f32, rotation: [3]f32, model: components.ModelComponent) !ecs.Entity {
    const entity = try ecs.create_entity(.tomato);

    // Core
    try entity.add_component(.transform, components.TransformComponent.new());
    try entity.add_component(.model, model);
    try entity.add_component(.aabb, .{ .aabb_size = [_]f32{ 0.125, 0.125, 0.125 }, .can_step = true });
    try entity.add_component(.velocity, @splat(0));
    try entity.add_component(.on_ground, false);
    try entity.add_component(.health, 10);

    // AI / Timing
    try entity.add_component(.timer, util.milliTimestamp() + std.time.ms_per_s * 1);
    try entity.add_component(.ai_state, AI_IDLE); // start trying to find town
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

            if (world.town.created and is_sleep_time) {
                ai_state_ptr.* = AI_SEEKING_TOWN;
                continue :blk ai_state_ptr.*;
            }
        },

        AI_SEEKING_TOWN => {
            if (!world.town.created) return;
            if (!is_sleep_time) {
                ai_state_ptr.* = AI_IDLE;
                continue :blk ai_state_ptr.*;
            }

            self.get_ptr(.home_pos).* = [_]isize{
                @intFromFloat(world.town.town_center[0]),
                @intFromFloat(world.town.town_center[1]),
                @intFromFloat(world.town.town_center[2]),
            };

            const player = world.player.entity.get(.transform).pos;
            const pdx = player[0] - transform.pos[0];
            const pdz = player[2] - transform.pos[2];
            const pdist = std.math.sqrt(pdx * pdx + pdz * pdz);

            if (pdist < 10.0) {
                // Move away from player!
                velocity[0] = -pdx;
                velocity[2] = -pdz;
            } else {
                const home = self.get(.home_pos);
                const dx = @as(f32, @floatFromInt(home[0])) - transform.pos[0];
                const dz = @as(f32, @floatFromInt(home[2])) - transform.pos[2];
                const dist = std.math.sqrt(dx * dx + dz * dz);

                if (dist < 1.5) {
                    audio.play_sfx_at_position("assets/mob/tomato.mp3", transform.pos) catch unreachable;
                    // EXPLODE
                    world.explode(transform.pos, 4);
                    world.player.entity.get_ptr(.health).* -|= 4;
                    // Teleport out of sim dist
                    transform.pos = [_]f32{ 0, 0, 0 };
                } else {
                    // Move towards the home position
                    velocity[0] = dx;
                    velocity[2] = dz;
                }
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
