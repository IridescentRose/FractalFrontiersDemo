const std = @import("std");
const assert = std.debug.assert;
const util = @import("../../core/util.zig");
const components = @import("components.zig");
const gfx = @import("../../gfx/gfx.zig");
const c = @import("../consts.zig");
const mm = @import("../model_manager.zig");

pub var loaded = false;

pub const Entity = struct {
    id: u32,

    pub fn do_physics(self: Entity, dt: f32) void {
        const can_do_physics = storage.mask.items[self.id].velocity and storage.mask.items[self.id].aabb and storage.mask.items[self.id].transform and storage.mask.items[self.id].on_ground;
        if (!can_do_physics) return;

        const vel = self.get_ptr(.velocity);
        const on_ground_ptr = self.get_ptr(.on_ground);

        const max_move_per_step: f32 = 0.45 / @as(f32, c.SUB_BLOCKS_PER_BLOCK);

        const mx = @abs(vel[0]) * dt;
        const my = @abs(vel[1]) * dt;
        const mz = @abs(vel[2]) * dt;
        const max_disp = @max(mx, @max(my, mz));
        const step_f32 = max_disp / max_move_per_step;
        const steps_i32 = if (max_disp <= max_move_per_step) 1 else @as(i32, @intFromFloat(@ceil(step_f32)));
        const steps: i32 = @max(steps_i32, 1);
        const sub_dt: f32 = dt / @as(f32, @floatFromInt(steps));

        var i: i32 = 0;
        while (i < steps) : (i += 1) {
            var vel_array = [_]f32{ vel[0], vel[1], vel[2] };
            var new_pos = [_]f32{
                self.get(.transform).pos[0] + vel[0] * sub_dt,
                self.get(.transform).pos[1] + vel[1] * sub_dt,
                self.get(.transform).pos[2] + vel[2] * sub_dt,
            };

            self.get(.aabb).collide_aabb_with_world(&new_pos, &vel_array, on_ground_ptr);
            vel.* = vel_array;
            self.get_ptr(.transform).pos = new_pos;
        }
    }

    pub const MAX_ENTITY_DRAW_DISTANCE = 40.0; // Maximum distance to draw entities
    pub fn draw(self: Entity, shadow: bool, center: [3]f32) void {
        const can_draw = storage.mask.items[self.id].model and storage.mask.items[self.id].transform;
        if (!can_draw) return;

        const pos = self.get(.transform).pos;
        const delta = [_]f32{
            pos[0] - center[0],
            pos[1] - center[1],
            pos[2] - center[2],
        };

        if (delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2] > MAX_ENTITY_DRAW_DISTANCE * MAX_ENTITY_DRAW_DISTANCE) {
            return; // Too far away to draw
        }

        if (shadow) {
            gfx.shader.use_shadow_shader();
            gfx.shader.set_shadow_model(self.get(.transform).get_matrix());
            var model = mm.get_model(self.get(.model));
            model.draw();
        } else {
            gfx.shader.use_render_shader();
            gfx.shader.set_model(self.get(.transform).get_matrix());
            var model = mm.get_model(self.get(.model));
            model.draw();
        }
    }

    pub fn get(entity: Entity, comptime comp_type: ComponentType) ComponentTypes[@intFromEnum(comp_type)] {
        return get_ptr(entity, comp_type).*;
    }

    pub fn get_ptr(entity: Entity, comptime comp_type: ComponentType) *ComponentTypes[@intFromEnum(comp_type)] {
        assert(initialized);
        // std.debug.print("ID: {}\n", .{entity.id});
        assert(entity.id < storage.transform.items.len);

        return &@field(storage, @tagName(comp_type)).items[entity.id];
    }

    pub fn add_component(entity: Entity, comptime comp_type: ComponentType, component: ComponentTypes[@intFromEnum(comp_type)]) !void {
        assert(initialized);
        assert(entity.id < storage.transform.items.len);

        const id = entity.id;

        @field(storage, @tagName(comp_type)).items[id] = component;
        @field(storage.mask.items[id], @tagName(comp_type)) = true;
    }
};

var initialized = false;

pub const EntityKind = enum(u8) {
    none = 0,
    player = 1,
    visitor = 2,
    tomato = 3,
    dragoon_builder = 4,
    dragoon_farmer = 5,
    dragoon_lumberjack = 6,
};

pub const ComponentType = enum(u8) {
    mask = 0,
    kind = 1,
    transform = 2,
    model = 3,
    aabb = 4,
    velocity = 5,
    on_ground = 6,
    health = 7,
    timer = 8,
    ai_state = 9,
    home_pos = 10,
    target_pos = 11,
    inventory = 12,
};

const ComponentTypes = [_]type{
    Mask,
    EntityKind,
    components.TransformComponent,
    components.ModelComponent,
    components.AABBComponent,
    components.VelocityComponent,
    components.OnGroundComponent,
    components.HealthComponent,
    i64,
    usize,
    [3]isize,
    [3]isize,
    components.InventoryComponent,
};

pub const Mask = packed struct(u32) {
    kind: bool = true, // By default, all entities have a kind.
    transform: bool = false,
    model: bool = false,
    aabb: bool = false,
    velocity: bool = false,
    on_ground: bool = false,
    health: bool = false,
    timer: bool = false,
    ai_state: bool = false,
    home_pos: bool = false,
    target_pos: bool = false,
    inventory: bool = false,
    reserved: u20 = 0,
};

const Storage = struct {
    mask: std.ArrayList(Mask),
    kind: std.ArrayList(EntityKind),
    transform: std.ArrayList(components.TransformComponent),
    model: std.ArrayList(components.ModelComponent),
    aabb: std.ArrayList(components.AABBComponent),
    velocity: std.ArrayList(components.VelocityComponent),
    on_ground: std.ArrayList(components.OnGroundComponent),
    health: std.ArrayList(components.HealthComponent),
    timer: std.ArrayList(i64),
    ai_state: std.ArrayList(usize),
    home_pos: std.ArrayList([3]isize),
    target_pos: std.ArrayList([3]isize),
    inventory: std.ArrayList(components.InventoryComponent),
    active_entities: std.ArrayList(Entity),
};

pub var storage: Storage = undefined;

pub fn save_entities() !void {
    assert(initialized);
}

pub fn load_entities() !void {
    assert(initialized);
}

pub fn init() !void {
    assert(!initialized);

    inline for (std.meta.fields(ComponentType), 0..) |c_type, i| {
        @field(storage, c_type.name) = try std.ArrayList(ComponentTypes[i]).initCapacity(util.allocator(), 32);
    }
    storage.active_entities = try std.ArrayList(Entity).initCapacity(util.allocator(), 32);

    initialized = true;

    load_entities() catch |err| {
        std.debug.print("Failed to load entities: {}\n", .{err});
    };

    assert(initialized);
}

pub fn deinit() void {
    assert(initialized);

    save_entities() catch |err| {
        std.debug.print("Failed to save entities: {}\n", .{err});
    };

    inline for (std.meta.fields(ComponentType)) |c_type| {
        @field(storage, c_type.name).deinit(util.allocator());
    }
    storage.active_entities.deinit(util.allocator());
    initialized = false;
    assert(!initialized);
}

pub fn create_entity(kind: EntityKind) !Entity {
    assert(initialized);

    const id = @as(u32, @intCast(storage.transform.items.len));
    inline for (std.meta.fields(ComponentType)) |c_type| {
        try @field(storage, c_type.name).append(util.allocator(), undefined);
    }
    try storage.active_entities.append(util.allocator(), Entity{ .id = id });
    storage.kind.items[id] = kind;
    storage.mask.items[id] = Mask{ .kind = true }; // Kind is always set.

    return .{
        .id = id,
    };
}
