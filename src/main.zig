const std = @import("std");
const Image = @import("image.zig");
const app = @import("app.zig");

const App = app.App;

const logo_image_bytes = @embedFile("dvd-logo");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    var logo = try Image.fromBytes(alloc, logo_image_bytes[0..logo_image_bytes.len :0], 8);
    defer logo.deinit();

    var application = try App.init(alloc, &logo);
    defer application.deinit();

    try application.update();
    if (application.platform.getFreeBuffer()) |buf| {
        try application.render(buf);

        try application.platform.requestFrame(&App.frame_listener, &application);

        try application.present(buf);
    }

    while (application.platform.dispatch()) {}
}
