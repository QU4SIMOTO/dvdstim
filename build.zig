const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate_c.addIncludePath(b.path("protocols"));
    translate_c.addIncludePath(b.path("vendor"));

    const exe = b.addExecutable(.{ .name = "dvdstim", .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true }) });

    exe.root_module.addImport("c", translate_c.createModule());

    exe.root_module.addCSourceFile(.{ .file = b.path("protocols/xdg-shell-client-protocol.c") });
    exe.root_module.addCSourceFile(.{ .file = b.path("protocols/wlr-layer-shell-unstable-v1-protocol.c") });
    exe.root_module.addCSourceFile(.{ .file = b.path("vendor/stb_image.c") });

    exe.root_module.linkSystemLibrary("wayland-client", .{});

    exe.root_module.addAnonymousImport("dvd-logo", .{ .root_source_file = b.path("assets/dvd-logo.png") });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());
}
