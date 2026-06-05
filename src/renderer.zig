const std = @import("std");
const Image = @import("image.zig");
const FrameBuffer = @import("wayland.zig").FrameBuffer;
const Rect = @import("wayland.zig").Rect;

pub const Colour = enum(u32) {
    red = 0xFF0000,
    green = 0x00FF00,
    blue = 0x0000FF,
    yellow = 0xFFFF00,
    magenta = 0xFF00FF,
    aqua = 0x00FFFF,

    fn next(self: Colour) Colour {
        return switch (self) {
            .red => .green,
            .green => .blue,
            .blue => .yellow,
            .yellow => .magenta,
            .magenta => .aqua,
            .aqua => .red,
        };
    }
};

pub const Effect = union(enum) {
    solid: Colour,
    pulse: Colour,
    sparkle: Colour,
    scanlines: Colour,
    aberration: Colour,
    wave: Colour,
    shine: Colour,
    gradient: Colour,
    glitch: Colour,
    neon: Colour,
    dissolve: Colour,
    melt: Colour,
    vhs: Colour,
    pixelated,
    rainbow,
    strobe,
    hue_cycle,
    plasma,
    radial,
    conic,
    fire,

    pub fn cycle(self: *Effect) void {
        switch (self.*) {
            .solid, .pulse, .sparkle, .scanlines, .aberration, .wave, .shine, .gradient, .glitch, .neon, .dissolve, .melt, .vhs => |*col| col.* = col.next(),
            else => {},
        }
    }

    pub fn setColour(self: *Effect, value: Colour) void {
        switch (self.*) {
            .solid, .pulse, .sparkle, .scanlines, .aberration, .wave, .shine, .gradient, .glitch, .neon, .dissolve, .melt, .vhs => |*col| col.* = value,
            else => {},
        }
    }

};

pub const EffectCtx = struct {
    phase: f32,
    rand: std.Random,
};

pub const Renderer = struct {
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

    pub fn draw(effect: Effect, fb: FrameBuffer, logo: *const Image, x: u32, y: u32, ctx: EffectCtx) void {
        switch (effect) {
            .solid => |col| drawLogo(fb, logo, x, y, @intFromEnum(col)),
            .pixelated => drawPixelated(fb, logo, x, y, ctx.rand),
            .rainbow => drawRainbow(fb, logo, x, y, ctx.phase),
            .pulse => |col| drawPulse(fb, logo, x, y, @intFromEnum(col), ctx.phase),
            .strobe => drawStrobe(fb, logo, x, y, ctx.phase),
            .hue_cycle => drawHueCycle(fb, logo, x, y, ctx.phase),
            .sparkle => |col| drawSparkle(fb, logo, x, y, @intFromEnum(col), ctx.rand),
            .plasma => drawPlasma(fb, logo, x, y, ctx.phase),
            .radial => drawRadial(fb, logo, x, y, ctx.phase),
            .scanlines => |col| drawScanlines(fb, logo, x, y, @intFromEnum(col), ctx.phase),
            .aberration => |col| drawAberration(fb, logo, x, y, @intFromEnum(col)),
            .wave => |col| drawWave(fb, logo, x, y, @intFromEnum(col), ctx.phase),
            .shine => |col| drawShine(fb, logo, x, y, @intFromEnum(col), ctx.phase),
            .gradient => |col| drawGradient(fb, logo, x, y, @intFromEnum(col), @intFromEnum(col.next()), ctx.phase),
            .glitch => |col| drawGlitch(fb, logo, x, y, @intFromEnum(col), ctx.rand),
            .neon => |col| drawNeon(fb, logo, x, y, @intFromEnum(col), ctx.phase),
            .dissolve => |col| drawDissolve(fb, logo, x, y, @intFromEnum(col), ctx.phase),
            .melt => |col| drawMelt(fb, logo, x, y, @intFromEnum(col), ctx.phase),
            .vhs => |col| drawVhs(fb, logo, x, y, @intFromEnum(col), ctx.phase, ctx.rand),
            .conic => drawConic(fb, logo, x, y, ctx.phase),
            .fire => drawFire(fb, logo, x, y, ctx.phase, ctx.rand),
        }
    }

    fn drawPixelated(
        fb: FrameBuffer,
        logo: *const Image,
        x_off: u32,
        y_off: u32,
        rand: std.Random,
    ) void {
        const clump = 8;
        const row_stride = fb.stride / 4;

        var by: usize = 0;
        while (by < logo.height) : (by += clump) {
            var bx: usize = 0;
            while (bx < logo.width) : (bx += clump) {
                const cr = @as(f32, @floatFromInt(rand.int(u8)));
                const cg = @as(f32, @floatFromInt(rand.int(u8)));
                const cb = @as(f32, @floatFromInt(rand.int(u8)));

                for (by..@min(by + clump, logo.height)) |y| {
                    for (bx..@min(bx + clump, logo.width)) |x| {
                        const fb_i = (y + y_off) * row_stride + (x + x_off);
                        const logo_i = y * logo.width + x;

                        const a = logo.pixels[logo_i] >> 24;
                        const af = @as(f32, @floatFromInt(a)) / 255.0;

                        const r = @as(u32, @intFromFloat(cr * af));
                        const g = @as(u32, @intFromFloat(cg * af));
                        const b = @as(u32, @intFromFloat(cb * af));

                        fb.pixels[fb_i] = (a << 24) | (r << 16) | (g << 8) | b;
                    }
                }
            }
        }
    }

    fn hueRgb(h: f32) [3]f32 {
        const cc = 255.0;
        const xx = (1.0 - @abs(@mod(h / 60.0, 2.0) - 1.0)) * 255.0;
        if (h < 60.0) return .{ cc, xx, 0 };
        if (h < 120.0) return .{ xx, cc, 0 };
        if (h < 180.0) return .{ 0, cc, xx };
        if (h < 240.0) return .{ 0, xx, cc };
        if (h < 300.0) return .{ xx, 0, cc };
        return .{ cc, 0, xx };
    }

    fn drawRainbow(
        fb: FrameBuffer,
        logo: *const Image,
        x_off: u32,
        y_off: u32,
        phase: f32,
    ) void {
        const row_stride = fb.stride / 4;
        const scale = 360.0 / @as(f32, @floatFromInt(logo.width));

        for (0..logo.height) |y| {
            for (0..logo.width) |x| {
                const fb_i = (y + y_off) * row_stride + (x + x_off);
                const logo_i = y * logo.width + x;

                const a = logo.pixels[logo_i] >> 24;
                const af = @as(f32, @floatFromInt(a)) / 255.0;

                const hue = @mod(@as(f32, @floatFromInt(x)) * scale + phase, 360.0);
                const rgb = hueRgb(hue);

                const r = @as(u32, @intFromFloat(rgb[0] * af));
                const g = @as(u32, @intFromFloat(rgb[1] * af));
                const b = @as(u32, @intFromFloat(rgb[2] * af));

                fb.pixels[fb_i] = (a << 24) | (r << 16) | (g << 8) | b;
            }
        }
    }

    fn drawPulse(fb: FrameBuffer, logo: *const Image, x_off: u32, y_off: u32, tint: u32, phase: f32) void {
        const b = 0.5 + 0.5 * @sin(phase * std.math.pi / 180.0);
        const tr = @as(u32, @intFromFloat(@as(f32, @floatFromInt((tint >> 16) & 0xFF)) * b));
        const tg = @as(u32, @intFromFloat(@as(f32, @floatFromInt((tint >> 8) & 0xFF)) * b));
        const tb = @as(u32, @intFromFloat(@as(f32, @floatFromInt(tint & 0xFF)) * b));
        drawLogo(fb, logo, x_off, y_off, (tr << 16) | (tg << 8) | tb);
    }

    fn drawStrobe(fb: FrameBuffer, logo: *const Image, x_off: u32, y_off: u32, phase: f32) void {
        const tint: u32 = if (@mod(phase, 48.0) < 24.0) 0xFFFFFF else 0x000000;
        drawLogo(fb, logo, x_off, y_off, tint);
    }

    fn drawHueCycle(fb: FrameBuffer, logo: *const Image, x_off: u32, y_off: u32, phase: f32) void {
        const rgb = hueRgb(@mod(phase, 360.0));
        const tint = (@as(u32, @intFromFloat(rgb[0])) << 16) | (@as(u32, @intFromFloat(rgb[1])) << 8) | @as(u32, @intFromFloat(rgb[2]));
        drawLogo(fb, logo, x_off, y_off, tint);
    }

    fn drawSparkle(fb: FrameBuffer, logo: *const Image, x_off: u32, y_off: u32, tint: u32, rand: std.Random) void {
        const tr = @as(f32, @floatFromInt((tint >> 16) & 0xFF));
        const tg = @as(f32, @floatFromInt((tint >> 8) & 0xFF));
        const tb = @as(f32, @floatFromInt(tint & 0xFF));
        const row_stride = fb.stride / 4;

        for (0..logo.height) |y| {
            for (0..logo.width) |x| {
                const fb_i = (y + y_off) * row_stride + (x + x_off);
                const logo_i = y * logo.width + x;

                const a = logo.pixels[logo_i] >> 24;
                const af = @as(f32, @floatFromInt(a)) / 255.0;

                const lit = rand.int(u8) < 12;
                const r = @as(u32, @intFromFloat((if (lit) 255.0 else tr) * af));
                const g = @as(u32, @intFromFloat((if (lit) 255.0 else tg) * af));
                const b = @as(u32, @intFromFloat((if (lit) 255.0 else tb) * af));

                fb.pixels[fb_i] = (a << 24) | (r << 16) | (g << 8) | b;
            }
        }
    }

    fn drawPlasma(fb: FrameBuffer, logo: *const Image, x_off: u32, y_off: u32, phase: f32) void {
        const row_stride = fb.stride / 4;
        const pr = phase * std.math.pi / 180.0;

        for (0..logo.height) |y| {
            const fy = @as(f32, @floatFromInt(y));
            for (0..logo.width) |x| {
                const fb_i = (y + y_off) * row_stride + (x + x_off);
                const logo_i = y * logo.width + x;

                const a = logo.pixels[logo_i] >> 24;
                const af = @as(f32, @floatFromInt(a)) / 255.0;

                const fx = @as(f32, @floatFromInt(x));
                const v = @sin(fx * 0.15) + @sin(fy * 0.15) + @sin((fx + fy) * 0.08 + pr);
                const hue = @mod((v + 3.0) / 6.0 * 360.0 + phase, 360.0);
                const rgb = hueRgb(hue);

                const r = @as(u32, @intFromFloat(rgb[0] * af));
                const g = @as(u32, @intFromFloat(rgb[1] * af));
                const b = @as(u32, @intFromFloat(rgb[2] * af));

                fb.pixels[fb_i] = (a << 24) | (r << 16) | (g << 8) | b;
            }
        }
    }

    fn drawRadial(fb: FrameBuffer, logo: *const Image, x_off: u32, y_off: u32, phase: f32) void {
        const row_stride = fb.stride / 4;
        const cx = @as(f32, @floatFromInt(logo.width)) / 2.0;
        const cy = @as(f32, @floatFromInt(logo.height)) / 2.0;

        for (0..logo.height) |y| {
            const dy = @as(f32, @floatFromInt(y)) - cy;
            for (0..logo.width) |x| {
                const fb_i = (y + y_off) * row_stride + (x + x_off);
                const logo_i = y * logo.width + x;

                const a = logo.pixels[logo_i] >> 24;
                const af = @as(f32, @floatFromInt(a)) / 255.0;

                const dx = @as(f32, @floatFromInt(x)) - cx;
                const d = @sqrt(dx * dx + dy * dy);
                const hue = @mod(d * 4.0 + phase, 360.0);
                const rgb = hueRgb(hue);

                const r = @as(u32, @intFromFloat(rgb[0] * af));
                const g = @as(u32, @intFromFloat(rgb[1] * af));
                const b = @as(u32, @intFromFloat(rgb[2] * af));

                fb.pixels[fb_i] = (a << 24) | (r << 16) | (g << 8) | b;
            }
        }
    }

    fn drawScanlines(fb: FrameBuffer, logo: *const Image, x_off: u32, y_off: u32, tint: u32, phase: f32) void {
        const tr = @as(f32, @floatFromInt((tint >> 16) & 0xFF));
        const tg = @as(f32, @floatFromInt((tint >> 8) & 0xFF));
        const tb = @as(f32, @floatFromInt(tint & 0xFF));
        const row_stride = fb.stride / 4;
        const scroll = @as(usize, @intFromFloat(phase / 12.0));

        for (0..logo.height) |y| {
            const f: f32 = if (@mod(y + scroll, 4) < 2) 1.0 else 0.25;
            for (0..logo.width) |x| {
                const fb_i = (y + y_off) * row_stride + (x + x_off);
                const logo_i = y * logo.width + x;

                const a = logo.pixels[logo_i] >> 24;
                const af = @as(f32, @floatFromInt(a)) / 255.0 * f;

                const r = @as(u32, @intFromFloat(tr * af));
                const g = @as(u32, @intFromFloat(tg * af));
                const b = @as(u32, @intFromFloat(tb * af));

                fb.pixels[fb_i] = (a << 24) | (r << 16) | (g << 8) | b;
            }
        }
    }

    fn alphaAt(logo: *const Image, sx: i32, y: usize, w: i32) f32 {
        if (sx < 0 or sx >= w) return 0.0;
        const logo_i = y * logo.width + @as(usize, @intCast(sx));
        return @as(f32, @floatFromInt(logo.pixels[logo_i] >> 24)) / 255.0;
    }

    fn drawAberration(fb: FrameBuffer, logo: *const Image, x_off: u32, y_off: u32, tint: u32) void {
        const tr = @as(f32, @floatFromInt((tint >> 16) & 0xFF));
        const tg = @as(f32, @floatFromInt((tint >> 8) & 0xFF));
        const tb = @as(f32, @floatFromInt(tint & 0xFF));
        const shift = 3;
        const row_stride = fb.stride / 4;
        const w = @as(i32, @intCast(logo.width));

        for (0..logo.height) |y| {
            for (0..logo.width) |x| {
                const fb_i = (y + y_off) * row_stride + (x + x_off);
                const xi = @as(i32, @intCast(x));

                const ar = alphaAt(logo, xi - shift, y, w);
                const ag = alphaAt(logo, xi, y, w);
                const ab = alphaAt(logo, xi + shift, y, w);

                const r = @as(u32, @intFromFloat(tr * ar));
                const g = @as(u32, @intFromFloat(tg * ag));
                const b = @as(u32, @intFromFloat(tb * ab));
                const a = @as(u32, @intFromFloat(@max(ar, @max(ag, ab)) * 255.0));

                fb.pixels[fb_i] = (a << 24) | (r << 16) | (g << 8) | b;
            }
        }
    }

    fn drawWave(fb: FrameBuffer, logo: *const Image, x_off: u32, y_off: u32, tint: u32, phase: f32) void {
        const tr = @as(f32, @floatFromInt((tint >> 16) & 0xFF));
        const tg = @as(f32, @floatFromInt((tint >> 8) & 0xFF));
        const tb = @as(f32, @floatFromInt(tint & 0xFF));
        const row_stride = fb.stride / 4;
        const w = @as(i32, @intCast(logo.width));
        const pr = phase * std.math.pi / 180.0;

        for (0..logo.height) |y| {
            const soff = @as(i32, @intFromFloat(@sin(@as(f32, @floatFromInt(y)) * 0.3 + pr) * 4.0));
            for (0..logo.width) |x| {
                const fb_i = (y + y_off) * row_stride + (x + x_off);
                const af = alphaAt(logo, @as(i32, @intCast(x)) + soff, y, w);

                const r = @as(u32, @intFromFloat(tr * af));
                const g = @as(u32, @intFromFloat(tg * af));
                const b = @as(u32, @intFromFloat(tb * af));
                const a = @as(u32, @intFromFloat(af * 255.0));

                fb.pixels[fb_i] = (a << 24) | (r << 16) | (g << 8) | b;
            }
        }
    }

    fn alphaXY(logo: *const Image, sx: i32, sy: i32, w: i32, h: i32) f32 {
        if (sx < 0 or sx >= w or sy < 0 or sy >= h) return 0.0;
        const logo_i = @as(usize, @intCast(sy)) * logo.width + @as(usize, @intCast(sx));
        return @as(f32, @floatFromInt(logo.pixels[logo_i] >> 24)) / 255.0;
    }

    fn drawConic(fb: FrameBuffer, logo: *const Image, x_off: u32, y_off: u32, phase: f32) void {
        const row_stride = fb.stride / 4;
        const cx = @as(f32, @floatFromInt(logo.width)) / 2.0;
        const cy = @as(f32, @floatFromInt(logo.height)) / 2.0;

        for (0..logo.height) |y| {
            const dy = @as(f32, @floatFromInt(y)) - cy;
            for (0..logo.width) |x| {
                const fb_i = (y + y_off) * row_stride + (x + x_off);
                const logo_i = y * logo.width + x;

                const a = logo.pixels[logo_i] >> 24;
                const af = @as(f32, @floatFromInt(a)) / 255.0;

                const dx = @as(f32, @floatFromInt(x)) - cx;
                const ang = std.math.atan2(dy, dx) * 180.0 / std.math.pi + 180.0;
                const hue = @mod(ang + phase, 360.0);
                const rgb = hueRgb(hue);

                const r = @as(u32, @intFromFloat(rgb[0] * af));
                const g = @as(u32, @intFromFloat(rgb[1] * af));
                const b = @as(u32, @intFromFloat(rgb[2] * af));

                fb.pixels[fb_i] = (a << 24) | (r << 16) | (g << 8) | b;
            }
        }
    }

    fn drawShine(fb: FrameBuffer, logo: *const Image, x_off: u32, y_off: u32, tint: u32, phase: f32) void {
        const tr = @as(f32, @floatFromInt((tint >> 16) & 0xFF));
        const tg = @as(f32, @floatFromInt((tint >> 8) & 0xFF));
        const tb = @as(f32, @floatFromInt(tint & 0xFF));
        const row_stride = fb.stride / 4;
        const fwidth = @as(f32, @floatFromInt(logo.width));
        const sweep = @mod(phase / 360.0, 1.0) * fwidth;
        const band = fwidth * 0.18;

        for (0..logo.height) |y| {
            for (0..logo.width) |x| {
                const fb_i = (y + y_off) * row_stride + (x + x_off);
                const logo_i = y * logo.width + x;

                const a = logo.pixels[logo_i] >> 24;
                const af = @as(f32, @floatFromInt(a)) / 255.0;

                const d = @abs(@as(f32, @floatFromInt(x)) - sweep);
                const hl = @max(0.0, 1.0 - d / band);

                const r = @as(u32, @intFromFloat((tr + (255.0 - tr) * hl) * af));
                const g = @as(u32, @intFromFloat((tg + (255.0 - tg) * hl) * af));
                const b = @as(u32, @intFromFloat((tb + (255.0 - tb) * hl) * af));

                fb.pixels[fb_i] = (a << 24) | (r << 16) | (g << 8) | b;
            }
        }
    }

    fn drawGradient(fb: FrameBuffer, logo: *const Image, x_off: u32, y_off: u32, tint_a: u32, tint_b: u32, phase: f32) void {
        const ar = @as(f32, @floatFromInt((tint_a >> 16) & 0xFF));
        const ag = @as(f32, @floatFromInt((tint_a >> 8) & 0xFF));
        const ab = @as(f32, @floatFromInt(tint_a & 0xFF));
        const br = @as(f32, @floatFromInt((tint_b >> 16) & 0xFF));
        const bg = @as(f32, @floatFromInt((tint_b >> 8) & 0xFF));
        const bb = @as(f32, @floatFromInt(tint_b & 0xFF));
        const row_stride = fb.stride / 4;
        const fwidth = @as(f32, @floatFromInt(logo.width));

        for (0..logo.height) |y| {
            for (0..logo.width) |x| {
                const fb_i = (y + y_off) * row_stride + (x + x_off);
                const logo_i = y * logo.width + x;

                const a = logo.pixels[logo_i] >> 24;
                const af = @as(f32, @floatFromInt(a)) / 255.0;

                const tpos = @mod(@as(f32, @floatFromInt(x)) / fwidth + phase / 360.0, 1.0);
                const t = @abs(2.0 * tpos - 1.0);

                const r = @as(u32, @intFromFloat((ar + (br - ar) * t) * af));
                const g = @as(u32, @intFromFloat((ag + (bg - ag) * t) * af));
                const b = @as(u32, @intFromFloat((ab + (bb - ab) * t) * af));

                fb.pixels[fb_i] = (a << 24) | (r << 16) | (g << 8) | b;
            }
        }
    }

    fn drawFire(fb: FrameBuffer, logo: *const Image, x_off: u32, y_off: u32, phase: f32, rand: std.Random) void {
        const row_stride = fb.stride / 4;
        const fheight = @as(f32, @floatFromInt(logo.height));
        const pr = phase * std.math.pi / 180.0;

        for (0..logo.height) |y| {
            const fy = @as(f32, @floatFromInt(y));
            const base = 1.0 - fy / fheight + 0.12 * @sin(fy * 0.5 - pr);
            for (0..logo.width) |x| {
                const fx = @as(f32, @floatFromInt(x));
                const fb_i = (y + y_off) * row_stride + (x + x_off);
                const logo_i = y * logo.width + x;

                const a = logo.pixels[logo_i] >> 24;
                const af = @as(f32, @floatFromInt(a)) / 255.0;

                const flick = 0.5 + 0.3 * @sin(fx * 0.6 + pr * 2.0) + 0.2 * @sin(fx * 0.21 - pr * 3.7);
                const jitter = @as(f32, @floatFromInt(rand.int(u8))) / 255.0;
                const heat = @max(0.0, @min(1.0, base * (0.55 + 0.4 * flick + 0.1 * jitter)));

                const r = @as(u32, @intFromFloat(@min(255.0, heat * 2.0 * 255.0) * af));
                const g = @as(u32, @intFromFloat(@max(0.0, @min(255.0, (heat * 2.0 - 0.6) * 255.0)) * af));
                const b = @as(u32, @intFromFloat(@max(0.0, @min(255.0, (heat * 3.0 - 2.2) * 255.0)) * af));

                fb.pixels[fb_i] = (a << 24) | (r << 16) | (g << 8) | b;
            }
        }
    }

    fn drawGlitch(fb: FrameBuffer, logo: *const Image, x_off: u32, y_off: u32, tint: u32, rand: std.Random) void {
        const tr = @as(f32, @floatFromInt((tint >> 16) & 0xFF));
        const tg = @as(f32, @floatFromInt((tint >> 8) & 0xFF));
        const tb = @as(f32, @floatFromInt(tint & 0xFF));
        const row_stride = fb.stride / 4;
        const w = @as(i32, @intCast(logo.width));
        const band = 6;

        var by: usize = 0;
        while (by < logo.height) : (by += band) {
            const soff = rand.intRangeAtMost(i32, -8, 8);
            for (by..@min(by + band, logo.height)) |y| {
                for (0..logo.width) |x| {
                    const fb_i = (y + y_off) * row_stride + (x + x_off);
                    const af = alphaAt(logo, @as(i32, @intCast(x)) + soff, y, w);

                    const r = @as(u32, @intFromFloat(tr * af));
                    const g = @as(u32, @intFromFloat(tg * af));
                    const b = @as(u32, @intFromFloat(tb * af));
                    const a = @as(u32, @intFromFloat(af * 255.0));

                    fb.pixels[fb_i] = (a << 24) | (r << 16) | (g << 8) | b;
                }
            }
        }
    }

    fn drawNeon(fb: FrameBuffer, logo: *const Image, x_off: u32, y_off: u32, tint: u32, phase: f32) void {
        const tr = @as(f32, @floatFromInt((tint >> 16) & 0xFF));
        const tg = @as(f32, @floatFromInt((tint >> 8) & 0xFF));
        const tb = @as(f32, @floatFromInt(tint & 0xFF));
        const row_stride = fb.stride / 4;
        const w = @as(i32, @intCast(logo.width));
        const h = @as(i32, @intCast(logo.height));
        const pulse = 0.6 + 0.4 * @sin(phase * std.math.pi / 180.0);

        for (0..logo.height) |y| {
            const yi = @as(i32, @intCast(y));
            for (0..logo.width) |x| {
                const fb_i = (y + y_off) * row_stride + (x + x_off);
                const xi = @as(i32, @intCast(x));

                const here = alphaXY(logo, xi, yi, w, h);
                const minn = @min(
                    @min(alphaXY(logo, xi - 1, yi, w, h), alphaXY(logo, xi + 1, yi, w, h)),
                    @min(alphaXY(logo, xi, yi - 1, w, h), alphaXY(logo, xi, yi + 1, w, h)),
                );
                const edge = @max(0.0, here - minn) * pulse;
                const base = here * 0.25;

                const r = @as(u32, @intFromFloat(@min(255.0, tr * base + 255.0 * edge)));
                const g = @as(u32, @intFromFloat(@min(255.0, tg * base + 255.0 * edge)));
                const b = @as(u32, @intFromFloat(@min(255.0, tb * base + 255.0 * edge)));
                const a = @as(u32, @intFromFloat(here * 255.0));

                fb.pixels[fb_i] = (a << 24) | (r << 16) | (g << 8) | b;
            }
        }
    }

    fn drawDissolve(fb: FrameBuffer, logo: *const Image, x_off: u32, y_off: u32, tint: u32, phase: f32) void {
        const tr = @as(f32, @floatFromInt((tint >> 16) & 0xFF));
        const tg = @as(f32, @floatFromInt((tint >> 8) & 0xFF));
        const tb = @as(f32, @floatFromInt(tint & 0xFF));
        const row_stride = fb.stride / 4;

        for (0..logo.height) |y| {
            for (0..logo.width) |x| {
                const fb_i = (y + y_off) * row_stride + (x + x_off);
                const logo_i = y * logo.width + x;

                const a = logo.pixels[logo_i] >> 24;
                const thr = @as(f32, @floatFromInt((x * 131 + y * 57) % 360));

                if (@mod(thr + phase, 360.0) < 200.0) {
                    const af = @as(f32, @floatFromInt(a)) / 255.0;
                    const r = @as(u32, @intFromFloat(tr * af));
                    const g = @as(u32, @intFromFloat(tg * af));
                    const b = @as(u32, @intFromFloat(tb * af));
                    fb.pixels[fb_i] = (a << 24) | (r << 16) | (g << 8) | b;
                } else {
                    fb.pixels[fb_i] = 0;
                }
            }
        }
    }

    fn drawMelt(fb: FrameBuffer, logo: *const Image, x_off: u32, y_off: u32, tint: u32, phase: f32) void {
        const tr = @as(f32, @floatFromInt((tint >> 16) & 0xFF));
        const tg = @as(f32, @floatFromInt((tint >> 8) & 0xFF));
        const tb = @as(f32, @floatFromInt(tint & 0xFF));
        const row_stride = fb.stride / 4;
        const w = @as(i32, @intCast(logo.width));
        const h = @as(i32, @intCast(logo.height));
        const fheight = @as(f32, @floatFromInt(logo.height));
        const tri = 1.0 - @abs(phase / 180.0 - 1.0);

        for (0..logo.width) |x| {
            const fx = @as(f32, @floatFromInt(x));
            const drip = (0.5 + 0.5 * @sin(fx * 0.4)) * tri * fheight * 0.6;
            const doff = @as(i32, @intFromFloat(drip));
            for (0..logo.height) |y| {
                const fb_i = (y + y_off) * row_stride + (x + x_off);
                const af = alphaXY(logo, @as(i32, @intCast(x)), @as(i32, @intCast(y)) - doff, w, h);

                const r = @as(u32, @intFromFloat(tr * af));
                const g = @as(u32, @intFromFloat(tg * af));
                const b = @as(u32, @intFromFloat(tb * af));
                const a = @as(u32, @intFromFloat(af * 255.0));

                fb.pixels[fb_i] = (a << 24) | (r << 16) | (g << 8) | b;
            }
        }
    }

    fn drawVhs(fb: FrameBuffer, logo: *const Image, x_off: u32, y_off: u32, tint: u32, phase: f32, rand: std.Random) void {
        const tr = @as(f32, @floatFromInt((tint >> 16) & 0xFF));
        const tg = @as(f32, @floatFromInt((tint >> 8) & 0xFF));
        const tb = @as(f32, @floatFromInt(tint & 0xFF));
        const row_stride = fb.stride / 4;
        const w = @as(i32, @intCast(logo.width));
        const scroll = @as(usize, @intFromFloat(phase / 8.0));

        for (0..logo.height) |y| {
            const jit = rand.intRangeAtMost(i32, -2, 2);
            const f: f32 = if (@mod(y + scroll, 3) == 0) 0.4 else 1.0;
            for (0..logo.width) |x| {
                const fb_i = (y + y_off) * row_stride + (x + x_off);
                const xi = @as(i32, @intCast(x)) + jit;

                const sr = alphaAt(logo, xi + 1, y, w);
                const sg = alphaAt(logo, xi, y, w);
                const sb = alphaAt(logo, xi - 1, y, w);

                const r = @as(u32, @intFromFloat(tr * sr * f));
                const g = @as(u32, @intFromFloat(tg * sg * f));
                const b = @as(u32, @intFromFloat(tb * sb * f));
                const a = @as(u32, @intFromFloat(@max(sr, @max(sg, sb)) * 255.0));

                fb.pixels[fb_i] = (a << 24) | (r << 16) | (g << 8) | b;
            }
        }
    }

    pub fn clearRect(fb: FrameBuffer, rect: Rect, colour: u32) void {
        const row_stride = fb.stride / 4;
        for (rect.y..rect.y + rect.h) |y| {
            const start = y * row_stride + rect.x;
            for (fb.pixels[start .. start + rect.w]) |*p| p.* = colour;
        }
    }
};
