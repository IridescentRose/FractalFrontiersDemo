const std = @import("std");
const gfx = @import("../gfx/gfx.zig");
const util = @import("../core/util.zig");
const c = @import("consts.zig");
const world = @import("world.zig");
const Transform = @import("../gfx/transform.zig").Transform;
const Self = @This();
const gl = @import("../gfx/gl.zig");

pub const ParticleKind = enum(u8) {
    Water,
};

pub const Particle = struct {
    kind: ParticleKind,
    pos: [3]f32,
    color: [3]u8,
    vel: [3]f32,
    lifetime: u16,
};

mesh: gfx.Mesh,
transform: Transform,
particles: std.ArrayList(Particle),

pub fn new() !Self {
    var res: Self = .{
        .mesh = try gfx.Mesh.new(),
        .transform = Transform.new(),
        .particles = std.ArrayList(Particle).empty,
    };

    try res.mesh.vertices.appendSlice(util.allocator(), &c.top_face);
    try res.mesh.indices.appendSlice(util.allocator(), &[_]u32{ 0, 1, 2, 2, 3, 0 });

    res.transform.pos = [_]f32{ 0, -8, 0 };
    res.mesh.update();

    return res;
}

pub fn add_particle(self: *Self, particle: Particle) !void {
    try self.particles.append(util.allocator(), particle);
}

pub fn deinit(self: *Self) void {
    self.mesh.deinit();
    self.particles.deinit(util.allocator());
}

var count: usize = 0;
pub fn update(self: *Self, dt: f32) !void {
    self.mesh.instances.clearAndFree(util.allocator());

    if (self.particles.items.len == 0) {
        return;
    }

    for (self.particles.items) |*particle| {
        if (particle.lifetime == 0) continue;

        particle.lifetime -= 1;
        if (particle.lifetime > 0) {
            try self.mesh.instances.append(util.allocator(), gfx.Mesh.Instance{
                .vert = [_]f32{ particle.pos[0], particle.pos[1], particle.pos[2] },
                .col = [_]u8{ particle.color[0], particle.color[1], particle.color[2], 2 },
            });

            const final_pos = [_]f32{
                particle.pos[0] + particle.vel[0] * dt,
                particle.pos[1] + particle.vel[1] * dt,
                particle.pos[2] + particle.vel[2] * dt,
            };

            var curr_pos = particle.pos;

            const STEPS = 256;
            const step_size = 1.0 / @as(f32, @floatFromInt(STEPS));
            for (0..STEPS) |_| {
                curr_pos[0] += (final_pos[0] - curr_pos[0]) * step_size;
                curr_pos[1] += (final_pos[1] - curr_pos[1]) * step_size;
                curr_pos[2] += (final_pos[2] - curr_pos[2]) * step_size;

                const subvoxel_coord = [_]isize{
                    @intFromFloat(curr_pos[0] * c.SUB_BLOCKS_PER_BLOCK),
                    @intFromFloat(curr_pos[1] * c.SUB_BLOCKS_PER_BLOCK),
                    @intFromFloat(curr_pos[2] * c.SUB_BLOCKS_PER_BLOCK),
                };

                if (world.get_voxel(subvoxel_coord) != .Air) {
                    particle.lifetime = 1;

                    if (particle.kind == .Water) {
                        count += 1;
                        if (count % 500 != 0) continue;

                        const adjusted_subvoxel_coord = [_]isize{
                            subvoxel_coord[0],
                            subvoxel_coord[1] + 5, // Rain falls from above
                            subvoxel_coord[2],
                        };

                        if (world.set_voxel(adjusted_subvoxel_coord, .{ .material = .Water, .color = [_]u8{ 0x46, 0x67, 0xC3 } })) {
                            try world.active_atoms.append(util.allocator(), .{
                                .coord = adjusted_subvoxel_coord,
                                .moves = 255, // Water particles can move around a bit
                            });
                        } else @panic("Failed to set voxel");
                    }

                    break;
                }
            }

            particle.pos = curr_pos;
        }
    }

    var i: usize = self.particles.items.len - 1;
    while (i > 0) : (i -= 1) {
        if (self.particles.items[i].lifetime == 0) {
            _ = self.particles.swapRemove(i);
        }
    }

    if (self.particles.items.len != 0 and self.particles.items[0].lifetime == 0) {
        _ = self.particles.orderedRemove(0);
    }

    self.mesh.update();
}

pub fn draw(self: *Self) void {
    if (self.mesh.indices.items.len != 0) {
        gfx.shader.use_particle_shader();
        gfx.shader.set_part_projview(world.player.camera.get_projview_matrix());
        gfx.shader.set_part_yaw(std.math.degreesToRadians(-world.player.camera.yaw + 90.0));
        gfx.shader.set_part_pitch(std.math.degreesToRadians(0));
        self.transform.scale = [_]f32{ 0.125, 3.5, 0.125 };
        gfx.shader.set_part_model(self.transform.get_matrix());

        self.mesh.draw();
    }
}
