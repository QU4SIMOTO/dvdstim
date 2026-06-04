const std = @import("std");
const c = @import("c");

const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

pub const FrameBuffer = struct { width: u32, height: u32, stride: usize, pixels: []u32 };

pub const Buffer = struct {
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
        const self: *Buffer = @ptrCast(@alignCast(ctx.?));
        self.busy = false;
    }
};

pub const Wayland = struct {
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
    frame_cb: ?*c.struct_wl_callback = null,

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
        if (self.frame_cb) |cb| c.wl_callback_destroy(cb);
        for (&self.buffers) |*b| b.deinit();
        if (self.layer_surface) |l| c.zwlr_layer_surface_v1_destroy(l);
        if (self.surface) |s| c.wl_surface_destroy(s);
        if (self.globals.layer_shell) |l| c.wl_proxy_destroy(@ptrCast(l));
        if (self.globals.shm) |s| c.wl_proxy_destroy(@ptrCast(s));
        if (self.globals.compositor) |comp| c.wl_proxy_destroy(@ptrCast(comp));
        c.wl_registry_destroy(self.registry);
        c.wl_display_disconnect(self.display);
        self.alloc.destroy(self);
    }

    pub fn dispatch(self: *Wayland) bool {
        return c.wl_display_dispatch(self.display) != -1;
    }

    pub fn requestFrame(self: *Wayland, listener: *const c.wl_callback_listener, ctx: ?*anyopaque) !void {
        if (self.frame_cb) |old| c.wl_callback_destroy(old);
        self.frame_cb = null;
        const cb = c.wl_surface_frame(self.surface) orelse return error.RequestFrame;
        if (c.wl_callback_add_listener(cb, listener, ctx) != 0) {
            c.wl_callback_destroy(cb);
            return error.AddFrameListener;
        }
        self.frame_cb = cb;
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
            c.zwlr_layer_shell_v1_get_layer_surface(self.globals.layer_shell, self.surface, null, c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "dvdstim");

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
        std.log.debug("removed: {d}", .{name});
    }
};
