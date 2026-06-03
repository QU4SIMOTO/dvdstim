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

const logo_image_bytes = @embedFile("logo.jpg");

const App = struct {
    width: u32 = 0,
    height: u32 = 0,
    logo: Image,
    configured: bool = false,
    display: *c.struct_wl_display,
    registry: ?*c.struct_wl_registry,
    compositor: ?*c.wl_compositor = null,
    shm: ?*c.wl_shm = null,
    layer_shell: ?*c.zwlr_layer_shell_v1 = null,
    surface: ?*c.struct_wl_surface = null,
    layer_surface: ?*c.struct_zwlr_layer_surface_v1 = null,
    buffer: ?Buffer = null,
    logo_x: u32 = 0,
    logo_y: u32 = 0,

    pub fn init(logo: Image) !App {
        const display = c.wl_display_connect(null) orelse return error.DisplayConnect;
        errdefer c.wl_display_disconnect(display);

        const registry = c.wl_display_get_registry(display) orelse return error.RegistryConnect;

        return .{ .logo = logo, .display = display, .registry = registry };
    }

    pub fn deinit(self: *App) void {
        if (self.buffer) |*b| b.deinit();
        c.zwlr_layer_surface_v1_destroy(self.layer_surface);
        c.wl_surface_destroy(self.surface);
        c.wl_registry_destroy(self.registry);
        c.wl_display_disconnect(self.display);
    }

    pub fn setup(self: *App) !void {
        try self.addListeners();
        try self.configure();
        try self.createBuffers();
    }

    pub fn update(self: *App) !void {
        self.logo_x += 5;
    }

    pub fn render(self: *App) !void {
        self.clear();
        self.drawLogo();
    }

    pub fn present(self: *App) !void {
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

    fn addListeners(self: *App) !void {
        if (c.wl_registry_add_listener(self.registry, &registry_listener, self) != 0) return error.RegistryListener;
        if (c.wl_display_roundtrip(self.display) == -1) return error.DisplayRoundTrip;
        if (self.compositor == null or self.shm == null or self.layer_shell == null) {
            return error.Globals;
        }
    }

    fn configure(self: *App) !void {
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

    fn createBuffers(self: *App) !void {
        self.buffer = try Buffer.init(self.width, self.height, self.shm.?);
    }

    fn drawLogo(self: *App) void {
        const fb = self.buffer.?.pixels;
        const logo = self.logo.pixels;

        const fb_w = self.width;
        const logo_w = self.logo.width;

        for (0..self.logo.height) |y| {
            for (0..self.logo.width) |x| {
                const fb_index = (y + self.logo_y) * fb_w + (x + self.logo_x);
                const logo_index = y * logo_w + x;

                fb[fb_index] = logo[logo_index];
            }
        }
    }

    fn clear(self: *App) void {
        const fb = self.buffer.?.pixels;
        for (fb) |*p| {
            p.* = 0x00000000;
        }
    }
};

const Buffer = struct {
    buffer: *c.struct_wl_buffer,
    pool: *c.struct_wl_shm_pool,
    data: []align(std.heap.page_size_min) u8,
    pixels: []u32,

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

        return .{ .buffer = buffer, .pool = pool, .data = data, .pixels = pixels };
    }

    fn deinit(self: *Buffer) void {
        c.wl_buffer_destroy(self.buffer);
        c.wl_shm_pool_destroy(self.pool);
        posix.munmap(self.data);
    }
};

fn registryGlobalHandler(ctx: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface_c: [*c]const u8, _: u32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));

    const interface = std.mem.span(interface_c);

    if (registry) |r| {
        if (std.mem.eql(u8, interface, "wl_compositor")) {
            app.compositor = @ptrCast(c.wl_registry_bind(r, name, &c.wl_compositor_interface, 3));
        } else if (std.mem.eql(u8, interface, "wl_shm")) {
            app.shm = @ptrCast(c.wl_registry_bind(r, name, &c.wl_shm_interface, 1));
        } else if (std.mem.eql(u8, interface, "zwlr_layer_shell_v1")) {
            app.layer_shell = @ptrCast(c.wl_registry_bind(r, name, &c.zwlr_layer_shell_v1_interface, 1));
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

    const next = c.wl_surface_frame(app.surface);
    if (c.wl_callback_add_listener(next, &frame_listener, app) != 0) {
        std.log.err("adding frame listener callback", .{});
    }

    app.present() catch |e| {
        std.log.err("Present error {any}", .{e});
    };
}

fn layerConfigure(ctx: ?*anyopaque, layer_surface: ?*c.zwlr_layer_surface_v1, serial: u32, w: u32, h: u32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    app.width = w;
    app.height = h;
    app.configured = true;

    c.zwlr_layer_surface_v1_ack_configure(layer_surface, serial);
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

const Image = struct {
    alloc: Allocator,
    width: u32,
    height: u32,
    channels: u32,
    pixels: []u32,

    pub fn from_bytes(alloc: Allocator, bytes: []const u8) !Image {
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

        const width: u32 = @intCast(width_c);
        const height: u32 = @intCast(height_c);
        const pixel_count: usize = width * height;

        const pixels = try alloc.alloc(u32, pixel_count);

        const src = @as([*]u8, @ptrCast(pixels_c))[0 .. pixel_count * 4];

        for (pixels, 0..) |*dst, i| {
            const base = i * 4;

            const r = src[base + 0];
            const g = src[base + 1];
            const b = src[base + 2];
            const a = src[base + 3];

            dst.* =
                (@as(u32, a) << 24) |
                (@as(u32, r) << 16) |
                (@as(u32, g) << 8) |
                @as(u32, b);
        }

        stbi.stbi_image_free(pixels_c);

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

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    var logo = try Image.from_bytes(alloc, logo_image_bytes[0..logo_image_bytes.len :0]);
    defer logo.deinit();

    var app = try App.init(logo);
    defer app.deinit();

    try app.setup();
    try app.update();
    try app.render();

    const cb = c.wl_surface_frame(app.surface);
    _ = c.wl_callback_add_listener(cb, &frame_listener, &app);
    try app.present();

    while (c.wl_display_dispatch(app.display) != -1) {}
}
