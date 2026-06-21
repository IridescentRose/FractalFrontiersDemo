const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdl3dep = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
    });
    const zmath = b.dependency("zmath", .{
        .target = target,
        .optimize = optimize,
        .enable_cross_platform_determinism = true,
    });
    const znoise = b.dependency("znoise", .{
        .target = target,
        .optimize = optimize,
    });
    const tracy = b.createModule(.{
        .root_source_file = b.path("src/core/tracy.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "DokiJam25",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{
                .name = "sdl3",
                .module = sdl3dep.module("sdl3"),
            }, .{
                .name = "zmath",
                .module = zmath.module("root"),
            }, .{
                .name = "znoise",
                .module = znoise.module("root"),
            }, .{
                .name = "tracy",
                .module = tracy,
            } },
        }),
    });

    // exe.subsystem = .Windows;
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/stbi/stbi.c"),
        .flags = &[_][]const u8{"-g"},
        .language = .c,
    });
    exe.root_module.addIncludePath(b.path("src/stbi/"));
    exe.root_module.link_libc = true;
    exe.root_module.linkLibrary(znoise.artifact("FastNoiseLite"));

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
