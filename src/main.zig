const std = @import("std");
const Image = @import("image.zig");
const App = @import("app.zig");
const Config = @import("config.zig");

const logo_image_bytes = @embedFile("dvd-logo");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    var config: Config = .{};
    config.parseArgs(init.minimal.args) catch std.process.exit(1);

    var logo = try Image.fromBytes(alloc, logo_image_bytes[0..logo_image_bytes.len :0], config.image);
    defer logo.deinit();

    var application = try App.init(
        alloc,
        init.io,
        config.app,
        &logo,
    );
    defer application.deinit();

    try application.update();
    if (application.wayland.getFreeBuffer()) |buf| {
        try application.render(buf);

        try application.wayland.requestFrame(&App.frame_listener, &application);

        try application.present(buf);
    }

    while (application.wayland.dispatch()) {}
}
