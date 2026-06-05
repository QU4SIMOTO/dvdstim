const std = @import("std");
const App = @import("app.zig");
const Image = @import("image.zig");

app: App.Config = .{},
image: Image.Config = .{},

const Self = @This();

pub fn parseArgs(self: *Self, args: std.process.Args) !void {
    var it: std.process.Args.Iterator = .init(args);
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            std.process.exit(0);
        }
        const key, const value = std.mem.cut(u8, arg, "=") orelse {
            std.debug.print("expected key=value, got '{s}'\n\n", .{arg});
            printUsage();
            return error.InvalidArg;
        };
        set(Self, self, key, value) catch |err| {
            std.debug.print("invalid argument '{s}': {s}\n\n", .{ arg, @errorName(err) });
            printUsage();
            return err;
        };
    }
}

pub fn printUsage() void {
    std.debug.print("{s}", .{comptime usageText()});
}

fn usageText() []const u8 {
    comptime {
        var s: []const u8 = "usage: dvdstim [key=value ...]\n\n" ++ fieldsText(Self, "");
        for (unionTypes(Self)) |U| {
            s = s ++ "\n" ++ shortName(U) ++ ": " ++ fieldNames(U) ++ "\n";
            if (payloadType(U)) |P|
                s = s ++ "  (payloaded variants take an optional :" ++ shortName(P) ++ ", default " ++
                    std.meta.fields(P)[0].name ++ "; e.g. " ++ std.meta.fields(U)[0].name ++ ":" ++
                    std.meta.fields(P)[0].name ++ ")\n" ++ shortName(P) ++ ": " ++ fieldNames(P) ++ "\n";
        }
        return s;
    }
}

fn fieldsText(comptime T: type, comptime prefix: []const u8) []const u8 {
    comptime {
        var s: []const u8 = "";
        for (std.meta.fields(T)) |f| {
            const path = if (prefix.len == 0) f.name else prefix ++ "." ++ f.name;
            s = s ++ switch (@typeInfo(f.type)) {
                .@"struct" => fieldsText(f.type, path),
                .bool => "  " ++ path ++ "=<true|false>\n",
                .@"enum" => "  " ++ path ++ "=<" ++ fieldNames(f.type) ++ ">\n",
                .@"union" => "  " ++ path ++ "=<" ++ shortName(f.type) ++ ">\n",
                else => "  " ++ path ++ "=<" ++ @typeName(f.type) ++ ">\n",
            };
        }
        return s;
    }
}

fn shortName(comptime T: type) []const u8 {
    comptime {
        const full = @typeName(T);
        const start = if (std.mem.lastIndexOfScalar(u8, full, '.')) |i| i + 1 else 0;
        var out: []const u8 = "";
        for (full[start..]) |ch| out = out ++ &[_]u8{std.ascii.toLower(ch)};
        return out;
    }
}

fn fieldNames(comptime T: type) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (std.meta.fields(T), 0..) |f, i| out = out ++ (if (i == 0) "" else "|") ++ f.name;
        return out;
    }
}

fn payloadType(comptime U: type) ?type {
    comptime {
        var found: ?type = null;
        for (std.meta.fields(U)) |f| {
            if (f.type == void) continue;
            if (found) |p| {
                if (p != f.type) return null;
            } else found = f.type;
        }
        return found;
    }
}

fn appendUnique(comptime list: []const type, comptime T: type) []const type {
    comptime {
        for (list) |x| if (x == T) return list;
        return list ++ &[_]type{T};
    }
}

fn unionTypes(comptime T: type) []const type {
    comptime {
        var list: []const type = &.{};
        for (std.meta.fields(T)) |f| switch (@typeInfo(f.type)) {
            .@"struct" => for (unionTypes(f.type)) |u| {
                list = appendUnique(list, u);
            },
            .@"union" => list = appendUnique(list, f.type),
            else => {},
        };
        return list;
    }
}

fn set(comptime T: type, ptr: *T, key: []const u8, val: []const u8) !void {
    const dot = std.mem.indexOfScalar(u8, key, '.');
    const head = if (dot) |d| key[0..d] else key;
    inline for (std.meta.fields(T)) |f| {
        if (std.mem.eql(u8, head, f.name)) {
            switch (@typeInfo(f.type)) {
                .@"struct" => {
                    const d = dot orelse return error.MissingSubkey;
                    return set(f.type, &@field(ptr.*, f.name), key[d + 1 ..], val);
                },
                else => {
                    if (dot != null) return error.NotAStruct;
                    @field(ptr.*, f.name) = try parseValue(f.type, val);
                    return;
                },
            }
        }
    }
    return error.UnknownArg;
}

fn parseValue(comptime T: type, str: []const u8) !T {
    return switch (@typeInfo(T)) {
        .int => try std.fmt.parseInt(T, str, 0),
        .float => try std.fmt.parseFloat(T, str),
        .bool => std.mem.eql(u8, str, "true"),
        .@"enum" => std.meta.stringToEnum(T, str) orelse error.BadEnum,
        .@"union" => {
            const tag = std.mem.sliceTo(str, ':');
            const rest = if (std.mem.indexOfScalar(u8, str, ':')) |i| str[i + 1 ..] else null;
            inline for (std.meta.fields(T)) |uf| {
                if (std.mem.eql(u8, tag, uf.name)) {
                    if (uf.type == void) return @unionInit(T, uf.name, {});
                    const payload = if (rest) |r| try parseValue(uf.type, r) else defaultValue(uf.type);
                    return @unionInit(T, uf.name, payload);
                }
            }
            return error.BadVariant;
        },
        else => @compileError("CLI: unsupported field type " ++ @typeName(T)),
    };
}

fn defaultValue(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .@"enum" => @field(T, std.meta.fields(T)[0].name),
        .int, .float => 0,
        .bool => false,
        else => @compileError("CLI: no default for " ++ @typeName(T)),
    };
}
