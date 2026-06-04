const std = @import("std");
const Image = @import("image.zig");
const App = @import("app.zig");

const logo_image_bytes = @embedFile("dvd-logo");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    var logo = try Image.fromBytes(alloc, logo_image_bytes[0..logo_image_bytes.len :0], 8);
    defer logo.deinit();

    var application = try App.init(alloc, &logo, init.io);
    defer application.deinit();

    try application.update();
    if (application.wayland.getFreeBuffer()) |buf| {
        try application.render(buf);

        try application.wayland.requestFrame(&App.frame_listener, &application);

        try application.present(buf);
    }

    while (application.wayland.dispatch()) {}
}
