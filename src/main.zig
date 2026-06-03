const std = @import("std");
const c = @import("c");
const Image = @import("image.zig");

const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const logo_image_bytes = @embedFile("dvd-logo.png");

const FrameBuffer = struct { width: u32, height: u32, stride: usize, pixels: []u32 };

const Wayland = struct {
    const registry_listener: c.wl_registry_listener = .{
        .global = &registryGlobalHandler,
        .global_remove = &registryGlobalRemoveHandler,
    };
    const layer_listener: c.zwlr_layer_surface_v1_listener = .{
        .configure = &layerConfigure,
        .closed = null,
    };

    const Globals = struct {
        compositor: ?*c.wl_compositor = null,
        shm: ?*c.wl_shm = null,
        layer_shell: ?*c.zwlr_layer_shell_v1 = null,
    };

    alloc: Allocator,
    display: *c.wl_display,
    registry: *c.struct_wl_registry,
    width: u32 = 0,
    height: u32 = 0,
    globals: Globals,
    surface: ?*c.wl_surface = null,
    layer_surface: ?*c.struct_zwlr_layer_surface_v1 = null,
    buffers: [2]Buffer = undefined,
    configured: bool = false,

    pub fn init(alloc: Allocator) !*Wayland {
        const display = c.wl_display_connect(null) orelse return error.DisplayConnect;
        errdefer c.wl_display_disconnect(display);

        const registry = c.wl_display_get_registry(display) orelse return error.RegistryConnect;
        errdefer c.wl_registry_destroy(registry);

        const wayland = try alloc.create(Wayland);
        errdefer alloc.destroy(wayland);

        wayland.* = .{
            .alloc = alloc,
            .display = display,
            .registry = registry,
            .globals = .{},
        };

        try wayland.bindGlobals();

        try wayland.createSurface();
        errdefer {
            if (wayland.layer_surface) |l| c.zwlr_layer_surface_v1_destroy(l);
            if (wayland.surface) |s| c.wl_surface_destroy(s);
        }

        try wayland.createBuffers();

        return wayland;
    }

    pub fn deinit(self: *Wayland) void {
        for (&self.buffers) |*b| b.deinit();
        if (self.layer_surface) |l| c.zwlr_layer_surface_v1_destroy(l);
        if (self.surface) |s| c.wl_surface_destroy(s);
        c.wl_registry_destroy(self.registry);
        c.wl_display_disconnect(self.display);
        self.alloc.destroy(self);
    }

    pub fn present(self: *Wayland, buf: *Buffer, x: i32, y: i32, w: i32, h: i32) void {
        c.wl_surface_attach(self.surface, buf.buffer, 0, 0);
        buf.busy = true;

        c.wl_surface_damage_buffer(self.surface, x, y, w, h);
        c.wl_surface_commit(self.surface);
    }

    pub fn frameBuffer(self: *Wayland, buf: *Buffer) FrameBuffer {
        return .{
            .width = self.width,
            .height = self.height,
            .stride = buf.stride,
            .pixels = buf.pixels,
        };
    }

    pub fn commit(self: *Wayland) void {
        c.wl_surface_commit(self.surface);
    }

    pub fn getFreeBuffer(self: *Wayland) ?*Buffer {
        for (&self.buffers) |*b| if (!b.busy) return b;
        return null;
    }

    fn bindGlobals(self: *Wayland) !void {
        if (c.wl_registry_add_listener(self.registry, &registry_listener, &self.globals) != 0) return error.RegistryListener;
        if (c.wl_display_roundtrip(self.display) == -1) return error.DisplayRoundTrip;
        if (self.globals.compositor == null or self.globals.shm == null or self.globals.layer_shell == null) {
            return error.Globals;
        }
    }

    fn createSurface(self: *Wayland) !void {
        self.surface = c.wl_compositor_create_surface(self.globals.compositor);

        self.layer_surface =
            c.zwlr_layer_shell_v1_get_layer_surface(self.globals.layer_shell, self.surface, null, c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "dvd-logo");

        if (c.zwlr_layer_surface_v1_add_listener(self.layer_surface, &layer_listener, self) != 0) return error.AddSurfaceListener;

        c.zwlr_layer_surface_v1_set_anchor(self.layer_surface, c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);

        c.zwlr_layer_surface_v1_set_size(self.layer_surface, 0, 0);

        const region =
            c.wl_compositor_create_region(self.globals.compositor);

        c.wl_surface_set_input_region(self.surface, region);
        c.wl_region_destroy(region);
        c.wl_surface_commit(self.surface);

        while (!self.configured) {
            if (c.wl_display_dispatch(self.display) == -1) return error.DisplayDispatch;
        }
    }

    fn createBuffers(self: *Wayland) !void {
        self.buffers[0] = try Buffer.init(self.width, self.height, self.globals.shm.?);
        errdefer self.buffers[0].deinit();
        if (c.wl_buffer_add_listener(self.buffers[0].buffer, &Buffer.buffer_listener, &self.buffers[0]) != 0) return error.AddBufferListener;

        self.buffers[1] = try Buffer.init(self.width, self.height, self.globals.shm.?);
        errdefer self.buffers[1].deinit();
        if (c.wl_buffer_add_listener(self.buffers[1].buffer, &Buffer.buffer_listener, &self.buffers[1]) != 0) return error.AddBufferListener;
    }

    fn layerConfigure(ctx: ?*anyopaque, layer_surface: ?*c.zwlr_layer_surface_v1, serial: u32, w: u32, h: u32) callconv(.c) void {
        const wayland: *Wayland = @ptrCast(@alignCast(ctx.?));
        wayland.width = w;
        wayland.height = h;
        wayland.configured = true;

        c.zwlr_layer_surface_v1_ack_configure(layer_surface, serial);
    }

    fn registryGlobalHandler(ctx: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface_c: [*c]const u8, _: u32) callconv(.c) void {
        const globals: *Wayland.Globals = @ptrCast(@alignCast(ctx.?));

        const interface = std.mem.span(interface_c);

        if (registry) |r| {
            if (std.mem.eql(u8, interface, "wl_compositor")) {
                globals.compositor = @ptrCast(c.wl_registry_bind(r, name, &c.wl_compositor_interface, 4));
            } else if (std.mem.eql(u8, interface, "wl_shm")) {
                globals.shm = @ptrCast(c.wl_registry_bind(r, name, &c.wl_shm_interface, 1));
            } else if (std.mem.eql(u8, interface, "zwlr_layer_shell_v1")) {
                globals.layer_shell = @ptrCast(c.wl_registry_bind(r, name, &c.zwlr_layer_shell_v1_interface, 1));
            }
        } else {
            std.log.err("Invalid registry", .{});
        }
    }

    fn registryGlobalRemoveHandler(_: ?*anyopaque, _: ?*c.wl_registry, name: u32) callconv(.c) void {
        std.debug.print("removed: {d}\n", .{name});
    }
};

const Renderer = struct {
    fn drawLogo(fb: FrameBuffer, logo: *Image, x_off: u32, y_off: u32, tint: u32) void {
        const tr = (tint >> 16) & 0xFF;
        const tg = (tint >> 8) & 0xFF;
        const tb = tint & 0xFF;

        for (0..logo.pixels.len / logo.width) |y| {
            for (0..logo.width) |x| {
                const row_stride = fb.stride / 4;
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

const Vec2 = @Vector(2, i32);

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

const Buffer = struct {
    const buffer_listener: c.wl_buffer_listener = .{
        .release = &bufferRelease,
    };

    buffer: *c.struct_wl_buffer,
    pool: *c.struct_wl_shm_pool,
    data: []align(std.heap.page_size_min) u8,
    pixels: []u32,
    stride: usize,
    busy: bool = false,

    fn init(width: u32, height: u32, shm: *c.wl_shm) !Buffer {
        const stride: usize = width * 4;
        const size: usize = stride * height;
        const fd = try posix.memfd_create("overlay", 0);

        defer _ = linux.close(fd);

        if (linux.ftruncate(fd, @as(i64, @intCast(size))) != 0)
            return error.FTruncate;

        const data = try posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer posix.munmap(data);

        const pixels: []u32 = @as([*]align(4) u32, @ptrCast(data))[0 .. width * height];

        for (0..pixels.len) |i| {
            pixels[i] = 0x11000000;
        }

        const pool = c.wl_shm_create_pool(shm, fd, @intCast(size)) orelse return error.CreatePool;
        errdefer c.wl_shm_pool_destroy(pool);

        const buffer = c.wl_shm_pool_create_buffer(
            pool,
            0,
            @as(i32, @intCast(width)),
            @as(i32, @intCast(height)),
            @as(i32, @intCast(stride)),
            c.WL_SHM_FORMAT_ARGB8888,
        ) orelse return error.CreateBuffer;

        return .{ .buffer = buffer, .pool = pool, .data = data, .pixels = pixels, .stride = stride };
    }

    fn deinit(self: *Buffer) void {
        c.wl_buffer_destroy(self.buffer);
        c.wl_shm_pool_destroy(self.pool);
        posix.munmap(self.data);
    }

    fn bufferRelease(ctx: ?*anyopaque, _: ?*c.wl_buffer) callconv(.c) void {
        const self: *Buffer = @ptrCast(@alignCast(ctx));
        self.busy = false;
    }
};

const App = struct {
    const frame_listener: c.wl_callback_listener = .{ .done = &frameDone };

    logo: Image,
    platform: *Wayland,
    state: State,

    pub fn init(alloc: Allocator, logo: Image) !App {
        const platform = try Wayland.init(alloc);

        return .{ .logo = logo, .platform = platform, .state = .{} };
    }

    pub fn deinit(self: *App) void {
        self.platform.deinit();
    }

    pub fn update(self: *App) !void {
        self.state.logo.pre = self.state.logo.pos;

        const max_x = @as(i32, @intCast(self.platform.width)) - @as(i32, @intCast(self.logo.width));
        const max_y = @as(i32, @intCast(self.platform.height)) - @as(i32, @intCast(self.logo.height));

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

    pub fn present(self: *App, buf: *Buffer) !void {
        const lo = @min(self.state.logo.pos, self.state.logo.pre);
        const dims: @Vector(2, u32) = .{ self.logo.width, self.logo.height };
        const size: Vec2 = @intCast(@abs(self.state.logo.pos - self.state.logo.pre) + dims);

        self.platform.present(buf, lo[0], lo[1], size[0], size[1]);
    }

    pub fn render(self: *App, buf: *Buffer) !void {
        const fb = self.platform.frameBuffer(buf);
        Renderer.clear(fb.pixels, self.state.clear_colour);
        Renderer.drawLogo(fb, &self.logo, @intCast(self.state.logo.pos[0]), @intCast(self.state.logo.pos[1]), @intFromEnum(self.state.logo.colour));
    }

    fn frameDone(ctx: ?*anyopaque, cb: ?*c.wl_callback, _: u32) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        c.wl_callback_destroy(cb);

        const next = c.wl_surface_frame(app.platform.surface);
        if (c.wl_callback_add_listener(next, &frame_listener, app) != 0) {
            std.log.err("Adding frame listener callback", .{});
        }

        if (app.platform.getFreeBuffer()) |buf| {
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
            app.platform.commit();
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    var logo = try Image.fromBytes(alloc, logo_image_bytes[0..logo_image_bytes.len :0], 8);
    defer logo.deinit();

    var app = try App.init(alloc, logo);
    defer app.deinit();

    try app.update();
    if (app.platform.getFreeBuffer()) |buf| {
        try app.render(buf);

        const cb = c.wl_surface_frame(app.platform.surface);
        _ = c.wl_callback_add_listener(cb, &App.frame_listener, &app);

        try app.present(buf);
    }

    while (c.wl_display_dispatch(app.platform.display) != -1) {}
}
