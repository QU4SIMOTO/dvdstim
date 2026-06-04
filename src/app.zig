const std = @import("std");
const c = @import("c");
const Allocator = std.mem.Allocator;
const Image = @import("image.zig");
const Wayland = @import("wayland.zig").Wayland;
const Buffer = @import("wayland.zig").Buffer;
const FrameBuffer = @import("wayland.zig").FrameBuffer;

const Self = @This();

logo: *const Image,
wayland: *Wayland,
state: State,

const Vec2 = @Vector(2, i32);

const Renderer = struct {
    fn drawLogo(fb: FrameBuffer, logo: *const Image, x_off: u32, y_off: u32, tint: u32) void {
        const tr = (tint >> 16) & 0xFF;
        const tg = (tint >> 8) & 0xFF;
        const tb = tint & 0xFF;

        const row_stride = fb.stride / 4;

        for (0..logo.height) |y| {
            for (0..logo.width) |x| {
                const fb_i = (y + y_off) * row_stride + (x + x_off);
                const logo_i = y * logo.width + x;

                const a = logo.pixels[logo_i] >> 24;
                const af = @as(f32, @floatFromInt(a)) / 255.0;

                const r = @as(u32, @intFromFloat(@as(f32, @floatFromInt(tr)) * af));
                const g = @as(u32, @intFromFloat(@as(f32, @floatFromInt(tg)) * af));
                const b = @as(u32, @intFromFloat(@as(f32, @floatFromInt(tb)) * af));

                fb.pixels[fb_i] = (a << 24) | (r << 16) | (g << 8) | b;
            }
        }
    }

    fn clear(pixels: []u32, colour: u32) void {
        for (pixels) |*p| p.* = colour;
    }
};

const State = struct {
    const Logo = struct {
        const Colour = enum(u32) {
            pub fn next(self: Colour) Colour {
                return switch (self) {
                    .red => .green,
                    .green => .blue,
                    .blue => .yellow,
                    .yellow => .magenta,
                    .magenta => .aqua,
                    .aqua => .red,
                };
            }
            red = 0xFF0000,
            green = 0x00FF00,
            blue = 0x0000FF,
            yellow = 0xFFFF00,
            magenta = 0xFF00FF,
            aqua = 0x00FFFF,
        };
        pos: Vec2 = .{ 0, 0 },
        pre: Vec2 = .{ 0, 0 },
        vel: Vec2 = .{ 3, 3 },
        colour: Colour = Colour.red,
    };
    logo: Logo = .{},
    clear_colour: u32 = 0x00000000,
};

pub const frame_listener: c.wl_callback_listener = .{ .done = &frameDone };

pub fn init(alloc: Allocator, logo: *const Image) !Self {
    const wayland = try Wayland.init(alloc);

    return .{ .logo = logo, .wayland = wayland, .state = .{} };
}

pub fn deinit(self: *Self) void {
    self.wayland.deinit();
}

pub fn update(self: *Self) !void {
    self.state.logo.pre = self.state.logo.pos;

    const max_x = @as(i32, @intCast(self.wayland.width)) - @as(i32, @intCast(self.logo.width));
    const max_y = @as(i32, @intCast(self.wayland.height)) - @as(i32, @intCast(self.logo.height));

    const next = self.state.logo.pos + self.state.logo.vel;

    if (next[0] > max_x or next[0] < 0) {
        self.state.logo.vel[0] *= -1;
        self.state.logo.colour = self.state.logo.colour.next();
    } else self.state.logo.pos[0] = next[0];

    if (next[1] > max_y or next[1] < 0) {
        self.state.logo.vel[1] *= -1;
        self.state.logo.colour = self.state.logo.colour.next();
    } else self.state.logo.pos[1] = next[1];
}

pub fn present(self: *Self, buf: *Buffer) !void {
    const lo = @min(self.state.logo.pos, self.state.logo.pre);
    const dims: @Vector(2, u32) = .{ self.logo.width, self.logo.height };
    const size: Vec2 = @intCast(@abs(self.state.logo.pos - self.state.logo.pre) + dims);

    self.wayland.present(buf, lo[0], lo[1], size[0], size[1]);
}

pub fn render(self: *Self, buf: *Buffer) !void {
    const fb = self.wayland.frameBuffer(buf);
    Renderer.clear(fb.pixels, self.state.clear_colour);
    Renderer.drawLogo(fb, self.logo, @intCast(self.state.logo.pos[0]), @intCast(self.state.logo.pos[1]), @intFromEnum(self.state.logo.colour));
}

fn frameDone(ctx: ?*anyopaque, _: ?*c.wl_callback, _: u32) callconv(.c) void {
    const app: *Self = @ptrCast(@alignCast(ctx.?));

    app.wayland.requestFrame(&frame_listener, app) catch |e| {
        std.log.err("Adding frame listener callback {any}", .{e});
    };

    if (app.wayland.getFreeBuffer()) |buf| {
        app.update() catch |e| {
            std.log.err("Update error {any}", .{e});
        };

        app.render(buf) catch |e| {
            std.log.err("Render error {any}", .{e});
        };

        app.present(buf) catch |e| {
            std.log.err("Present error {any}", .{e});
        };
    } else {
        app.wayland.commit();
    }
}
