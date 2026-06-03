const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("xdg-shell-client-protocol.h");
    @cInclude("wlr-layer-shell-unstable-v1-client-protocol.h");
});
const stbi = @cImport({
    @cInclude("stb_image.h");
});

const logo_image_bytes = @embedFile("dvd-logo.png");

const FrameBuffer = struct { width: u32, height: u32, stride: usize, pixels: []u32 };

const Wayland = struct {
    alloc: Allocator,
    display: *c.wl_display,
    registry: *c.struct_wl_registry,
    width: u32 = 0,
    height: u32 = 0,
    compositor: ?*c.wl_compositor = null,
    surface: ?*c.wl_surface = null,
    shm: ?*c.wl_shm = null,
    layer_shell: ?*c.zwlr_layer_shell_v1 = null,
    layer_surface: ?*c.struct_zwlr_layer_surface_v1 = null,
    buffer: ?Buffer = null,
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
        if (self.buffer) |*b| b.deinit();
        if (self.layer_surface) |l| c.zwlr_layer_surface_v1_destroy(l);
        if (self.surface) |s| c.wl_surface_destroy(s);
        c.wl_registry_destroy(self.registry);
        c.wl_display_disconnect(self.display);
        self.alloc.destroy(self);
    }

    pub fn present(
        self: *Wayland,
    ) void {
        c.wl_surface_attach(self.surface, self.buffer.?.buffer, 0, 0);
        c.wl_surface_damage(
            self.surface,
            0,
            0,
            @intCast(self.width),
            @intCast(self.height),
        );
        c.wl_surface_commit(self.surface);
    }

    pub fn frameBuffer(self: *Wayland) FrameBuffer {
        const buffer = self.buffer.?;
        return .{
            .width = self.width,
            .height = self.height,
            .stride = buffer.stride,
            .pixels = buffer.pixels,
        };
    }

    fn bindGlobals(self: *Wayland) !void {
        if (c.wl_registry_add_listener(self.registry, &registry_listener, self) != 0) return error.RegistryListener;
        if (c.wl_display_roundtrip(self.display) == -1) return error.DisplayRoundTrip;
        if (self.compositor == null or self.shm == null or self.layer_shell == null) {
            return error.Globals;
        }
    }

    fn createSurface(self: *Wayland) !void {
        self.surface = c.wl_compositor_create_surface(self.compositor);

        self.layer_surface =
            c.zwlr_layer_shell_v1_get_layer_surface(self.layer_shell, self.surface, null, c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "dvd-logo");

        if (c.zwlr_layer_surface_v1_add_listener(self.layer_surface, &layer_listener, self) != 0) return error.AddSurfaceListener;

        c.zwlr_layer_surface_v1_set_anchor(self.layer_surface, c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);

        c.zwlr_layer_surface_v1_set_size(self.layer_surface, 0, 0);

        const region =
            c.wl_compositor_create_region(self.compositor);

        c.wl_surface_set_input_region(self.surface, region);
        c.wl_region_destroy(region);
        c.wl_surface_commit(self.surface);

        while (!self.configured) {
            if (c.wl_display_dispatch(self.display) == -1) return error.DisplayDispatch;
        }
    }

    fn createBuffers(self: *Wayland) !void {
        self.buffer = try Buffer.init(self.width, self.height, self.shm.?);
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
        x: i32 = 0,
        dx: i32 = 3,
        y: i32 = 0,
        dy: i32 = 3,
        colour: Colour = Colour.red,
    };
    logo: Logo = .{},
    clear_colour: u32 = 0x00000000,
};

const App = struct {
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
        const max_x = @as(i32, @intCast(self.platform.width)) - @as(i32, @intCast(self.logo.width));
        const max_y = @as(i32, @intCast(self.platform.height)) - @as(i32, @intCast(self.logo.height));

        const next_x = self.state.logo.x + self.state.logo.dx;

        if (next_x > max_x or next_x < 0) {
            self.state.logo.dx *= -1;
            self.state.logo.colour = self.state.logo.colour.next();
        } else self.state.logo.x = next_x;

        const next_y = self.state.logo.y + self.state.logo.dy;

        if (next_y > max_y or next_y < 0) {
            self.state.logo.dy *= -1;
            self.state.logo.colour = self.state.logo.colour.next();
        } else self.state.logo.y = next_y;
    }

    pub fn present(self: *App) !void {
        self.platform.present();
    }

    pub fn render(self: *App) !void {
        const fb = self.platform.frameBuffer();
        Renderer.clear(fb.pixels, self.state.clear_colour);
        Renderer.drawLogo(fb, &self.logo, @intCast(self.state.logo.x), @intCast(self.state.logo.y), @intFromEnum(self.state.logo.colour));
    }
};

const Buffer = struct {
    buffer: *c.struct_wl_buffer,
    pool: *c.struct_wl_shm_pool,
    data: []align(std.heap.page_size_min) u8,
    pixels: []u32,
    stride: usize,

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
};

const Image = struct {
    alloc: Allocator,
    width: u32,
    height: u32,
    channels: u32,
    pixels: []u32,

    pub fn from_bytes(alloc: Allocator, bytes: []const u8, scale: u32) !Image {
        var width_c: c_int = 0;
        var height_c: c_int = 0;
        var channels: c_int = 0;

        const pixels_c = stbi.stbi_load_from_memory(
            bytes.ptr,
            @intCast(bytes.len),
            &width_c,
            &height_c,
            &channels,
            4,
        ) orelse return error.ImageLoadFailed;

        const src_width: u32 = @intCast(width_c);
        const src_height: u32 = @intCast(height_c);

        const src = @as([*]u8, @ptrCast(pixels_c))[0 .. @as(usize, src_width) * src_height * 4];
        defer stbi.stbi_image_free(pixels_c);

        var min_x: u32 = src_width;
        var min_y: u32 = src_height;
        var max_x: u32 = 0;
        var max_y: u32 = 0;
        for (0..src_height) |y| {
            for (0..src_width) |x| {
                const a = src[(y * src_width + x) * 4 + 3];
                if (a == 0) continue;
                if (x < min_x) min_x = @intCast(x);
                if (x > max_x) max_x = @intCast(x);
                if (y < min_y) min_y = @intCast(y);
                if (y > max_y) max_y = @intCast(y);
            }
        }
        if (max_x < min_x or max_y < min_y) return error.ImageTransparent;

        const crop_w = max_x - min_x + 1;
        const crop_h = max_y - min_y + 1;

        const div = if (scale == 0) 1 else scale;
        const width = @max(crop_w / div, 1);
        const height = @max(crop_h / div, 1);
        const pixels = try alloc.alloc(u32, @as(usize, width) * height);

        for (0..height) |y| {
            for (0..width) |x| {
                const sx = min_x + @as(u32, @intCast(x)) * div;
                const sy = min_y + @as(u32, @intCast(y)) * div;
                const base = (sy * src_width + sx) * 4;

                const r = src[base + 0];
                const g = src[base + 1];
                const b = src[base + 2];
                const a = src[base + 3];

                const af = @as(f32, a) / 255.0;
                const r2 = @as(u32, @intFromFloat(@as(f32, r) * af));
                const g2 = @as(u32, @intFromFloat(@as(f32, g) * af));
                const b2 = @as(u32, @intFromFloat(@as(f32, b) * af));

                pixels[y * width + x] =
                    (@as(u32, a) << 24) |
                    (r2 << 16) |
                    (g2 << 8) |
                    b2;
            }
        }

        return .{
            .alloc = alloc,
            .width = width,
            .height = height,
            .channels = @intCast(4),
            .pixels = pixels,
        };
    }

    pub fn deinit(self: *Image) void {
        self.alloc.free(self.pixels);
    }
};

fn registryGlobalHandler(ctx: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface_c: [*c]const u8, _: u32) callconv(.c) void {
    const wayland: *Wayland = @ptrCast(@alignCast(ctx.?));

    const interface = std.mem.span(interface_c);

    if (registry) |r| {
        if (std.mem.eql(u8, interface, "wl_compositor")) {
            wayland.compositor = @ptrCast(c.wl_registry_bind(r, name, &c.wl_compositor_interface, 3));
        } else if (std.mem.eql(u8, interface, "wl_shm")) {
            wayland.shm = @ptrCast(c.wl_registry_bind(r, name, &c.wl_shm_interface, 1));
        } else if (std.mem.eql(u8, interface, "zwlr_layer_shell_v1")) {
            wayland.layer_shell = @ptrCast(c.wl_registry_bind(r, name, &c.zwlr_layer_shell_v1_interface, 1));
        }
    } else {
        std.log.err("Invalid registry", .{});
    }
}

fn registryGlobalRemoveHandler(_: ?*anyopaque, _: ?*c.wl_registry, name: u32) callconv(.c) void {
    std.debug.print("removed: {d}\n", .{name});
}

fn frameDone(ctx: ?*anyopaque, cb: ?*c.wl_callback, _: u32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    c.wl_callback_destroy(cb);

    app.update() catch |e| {
        std.log.err("Update error {any}", .{e});
    };

    app.render() catch |e| {
        std.log.err("Render error {any}", .{e});
    };

    const next = c.wl_surface_frame(app.platform.surface);
    if (c.wl_callback_add_listener(next, &frame_listener, app) != 0) {
        std.log.err("adding frame listener callback", .{});
    }

    app.present() catch |e| {
        std.log.err("Present error {any}", .{e});
    };
}

fn layerConfigure(ctx: ?*anyopaque, layer_surface: ?*c.zwlr_layer_surface_v1, serial: u32, w: u32, h: u32) callconv(.c) void {
    const wayland: *Wayland = @ptrCast(@alignCast(ctx.?));
    wayland.width = w;
    wayland.height = h;
    wayland.configured = true;

    c.zwlr_layer_surface_v1_ack_configure(layer_surface, serial);
}

fn bufferRelease(_: ?*anyopaque, buffer: ?*c.wl_buffer) callconv(.c) void {
    _ = buffer;
}

const registry_listener: c.wl_registry_listener = .{
    .global = &registryGlobalHandler,
    .global_remove = &registryGlobalRemoveHandler,
};
const layer_listener: c.zwlr_layer_surface_v1_listener = .{
    .configure = &layerConfigure,
    .closed = null,
};
const frame_listener: c.wl_callback_listener = .{ .done = &frameDone };
const buffer_listener: c.wl_buffer_listener = .{
    .release = &bufferRelease,
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    var logo = try Image.from_bytes(alloc, logo_image_bytes[0..logo_image_bytes.len :0], 8);
    defer logo.deinit();

    var app = try App.init(alloc, logo);
    defer app.deinit();

    try app.update();
    try app.render();

    const cb = c.wl_surface_frame(app.platform.surface);
    _ = c.wl_callback_add_listener(cb, &frame_listener, &app);
    try app.present();

    while (c.wl_display_dispatch(app.platform.display) != -1) {}
}
