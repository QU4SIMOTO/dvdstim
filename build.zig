const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const stb = b.dependency("stb", .{});

    const protocols = scanProtocols(b, &.{
        .{ .name = "xdg-shell", .xml = "protocols/xdg-shell.xml" },
        .{ .name = "wlr-layer-shell-unstable-v1", .xml = "protocols/wlr-layer-shell-unstable-v1.xml" },
    });

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate_c.addIncludePath(protocols.headers);
    translate_c.addIncludePath(stb.path(""));

    const exe = b.addExecutable(.{ .name = "dvdstim", .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true }) });

    exe.root_module.addImport("c", translate_c.createModule());

    for (protocols.sources) |source| {
        exe.root_module.addCSourceFile(.{ .file = source });
    }
    exe.root_module.addCSourceFile(.{ .file = b.path("src/stb_image.c") });
    exe.root_module.addIncludePath(stb.path(""));

    exe.root_module.linkSystemLibrary("wayland-client", .{});

    exe.root_module.addAnonymousImport("dvd-logo", .{ .root_source_file = b.path("assets/dvd-logo.png") });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());
}

const Protocol = struct {
    name: []const u8,
    xml: []const u8,
};

const ScannedProtocols = struct {
    headers: std.Build.LazyPath,
    sources: []const std.Build.LazyPath,
};

fn scanProtocols(b: *std.Build, protocols: []const Protocol) ScannedProtocols {
    const headers = b.addWriteFiles();
    const sources = b.allocator.alloc(std.Build.LazyPath, protocols.len) catch @panic("OOM");

    for (protocols, sources) |protocol, *source| {
        const header_cmd = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
        header_cmd.addFileArg(b.path(protocol.xml));
        const header = header_cmd.addOutputFileArg(b.fmt("{s}-client-protocol.h", .{protocol.name}));
        _ = headers.addCopyFile(header, b.fmt("{s}-client-protocol.h", .{protocol.name}));

        const code_cmd = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        code_cmd.addFileArg(b.path(protocol.xml));
        source.* = code_cmd.addOutputFileArg(b.fmt("{s}-protocol.c", .{protocol.name}));
    }

    return .{ .headers = headers.getDirectory(), .sources = sources };
}
