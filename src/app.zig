const std = @import("std");
const c = @import("c");
const Allocator = std.mem.Allocator;
const Image = @import("image.zig");
const Wayland = @import("wayland.zig").Wayland;
const Buffer = @import("wayland.zig").Buffer;
const renderer = @import("renderer.zig");
const Renderer = renderer.Renderer;
const Effect = renderer.Effect;
const Colour = renderer.Colour;

const Self = @This();

io: std.Io,
logo: *const Image,
wayland: *Wayland,
state: State,

const Vec2 = @Vector(2, i32);

const State = struct {
    const Logo = struct {
        const speed: i32 = 3;
        pos: Vec2 = .{ 0, 0 },
        pre: Vec2 = .{ 0, 0 },
        vel: Vec2 = .{ speed, speed },
    };
    logo: Logo = .{},
    clear_colour: u32 = 0x00000000,
    hit_corner: bool = false,
    bounce_effect: Effect = .{ .solid = .red },
    corner_effect: Effect = .rainbow,
    phase: f32 = 0,
};

pub const frame_listener: c.wl_callback_listener = .{ .done = &frameDone };

pub fn init(alloc: Allocator, logo: *const Image, io: std.Io) !Self {
    const wayland = try Wayland.init(alloc);
    const rng: std.Random.IoSource = .{ .io = io };
    const rand = rng.interface();

    const max_x = @as(i32, @intCast(wayland.width)) - @as(i32, @intCast(logo.width)) - 1;
    const max_y = @as(i32, @intCast(wayland.height)) - @as(i32, @intCast(logo.height)) - 1;
    std.debug.assert(max_x >= 1 and max_y >= 1);
    const pos: Vec2 = .{ rand.intRangeAtMost(i32, 1, max_x), rand.intRangeAtMost(i32, 1, max_y) };

    const speed = State.Logo.speed;
    const vel: Vec2 = .{
        if (rand.boolean()) speed else -speed,
        if (rand.boolean()) speed else -speed,
    };

    const colour = rand.enumValue(Colour);

    var state: State = .{ .logo = .{ .pos = pos, .vel = vel } };
    state.bounce_effect.setColour(colour);

    return .{
        .io = io,
        .logo = logo,
        .wayland = wayland,
        .state = state,
    };
}

pub fn deinit(self: *Self) void {
    self.wayland.deinit();
}

pub fn update(self: *Self) !void {
    self.state.phase = @mod(self.state.phase + 4.0, 360.0);
    if (self.state.hit_corner) {
        return;
    }
    self.state.logo.pre = self.state.logo.pos;

    const max_x = @as(i32, @intCast(self.wayland.width)) - @as(i32, @intCast(self.logo.width));
    const max_y = @as(i32, @intCast(self.wayland.height)) - @as(i32, @intCast(self.logo.height));

    const next = self.state.logo.pos + self.state.logo.vel;

    const hit_x = next[0] > max_x or next[0] < 0;
    const hit_y = next[1] > max_y or next[1] < 0;

    if (hit_x and hit_y) {
        self.state.hit_corner = true;
        if (self.state.bounce_effect.colour()) |col| self.state.corner_effect.setColour(col);
        return;
    }

    if (hit_x) {
        self.state.logo.vel[0] *= -1;
        self.state.bounce_effect.cycle();
    } else self.state.logo.pos[0] = next[0];

    if (hit_y) {
        self.state.logo.vel[1] *= -1;
        self.state.bounce_effect.cycle();
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

    if (buf.last_logo) |rect| Renderer.clearRect(fb, rect, self.state.clear_colour);

    const x: u32 = @intCast(self.state.logo.pos[0]);
    const y: u32 = @intCast(self.state.logo.pos[1]);

    const effect = if (self.state.hit_corner) self.state.corner_effect else self.state.bounce_effect;
    const src: std.Random.IoSource = .{ .io = self.io };
    Renderer.draw(effect, fb, self.logo, x, y, .{
        .phase = self.state.phase,
        .rand = src.interface(),
    });

    buf.last_logo = .{ .x = x, .y = y, .w = self.logo.width, .h = self.logo.height };
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
