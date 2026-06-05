const std = @import("std");
const c = @import("c");

const Allocator = std.mem.Allocator;

const Self = @This();

alloc: Allocator,
width: u32,
height: u32,
channels: u32,
pixels: []u32,

pub const Bounds = struct { w: u32, h: u32 };

pub const Config = struct { bounds: Bounds = .{ .w = 128, .h = 128 } };

pub fn fromBytes(alloc: Allocator, bytes: []const u8, config: Config) !Self {
    const bounds = config.bounds;
    std.debug.assert(bounds.w > 0 and bounds.h > 0);

    var width_c: c_int = 0;
    var height_c: c_int = 0;
    var channels: c_int = 0;

    const pixels_c = c.stbi_load_from_memory(
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
    defer c.stbi_image_free(pixels_c);

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

    const div_w = (crop_w + bounds.w - 1) / bounds.w;
    const div_h = (crop_h + bounds.h - 1) / bounds.h;
    const div = @max(@max(div_w, div_h), 1);
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

pub fn deinit(self: *Self) void {
    self.alloc.free(self.pixels);
}
