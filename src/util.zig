const std = @import("std");

/// Low-value scratch; wiped automatically when the system reboots.
pub const TMP_DIR = "/tmp/blitzdenk";

pub fn cacheDir(alloc: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    const xdg = env.get("XDG_CACHE_HOME") orelse "";
    const root = if (xdg.len > 0) xdg else blk: {
        const home = env.get("HOME") orelse return error.NoHomeFound;
        break :blk try std.fmt.allocPrint(alloc, "{s}/.cache", .{home});
    };
    return std.fmt.allocPrint(alloc, "{s}/blitzdenk", .{root});
}

pub fn stateDir(alloc: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    const xdg = env.get("XDG_STATE_HOME") orelse "";
    if (xdg.len > 0 and std.fs.path.isAbsolute(xdg))
        return std.fmt.allocPrint(alloc, "{s}/blitzdenk", .{xdg});
    const home = env.get("HOME") orelse return error.NoHomeFound;
    if (!std.fs.path.isAbsolute(home)) return error.NoHomeFound;
    return std.fmt.allocPrint(alloc, "{s}/.local/state/blitzdenk", .{home});
}

pub fn dataDir(alloc: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    const xdg = env.get("XDG_DATA_HOME") orelse "";
    if (xdg.len > 0 and std.fs.path.isAbsolute(xdg))
        return std.fmt.allocPrint(alloc, "{s}/blitzdenk", .{xdg});
    const home = env.get("HOME") orelse return error.NoHomeFound;
    if (!std.fs.path.isAbsolute(home)) return error.NoHomeFound;
    return std.fmt.allocPrint(alloc, "{s}/.local/share/blitzdenk", .{home});
}

pub fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}

/// Owned copy of `text`, ill-formed UTF-8 replaced with U+FFFD.
pub fn sanitizeUtf8(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    if (std.unicode.utf8ValidateSlice(text)) return alloc.dupe(u8, text);
    return std.fmt.allocPrint(alloc, "{f}", .{std.unicode.fmtUtf8(text)});
}

///Mostly clones `T`. passthrough for function ptr and anything opaque.
pub fn deepClone(comptime T: type, value: T, alloc: std.mem.Allocator) !T {
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .comptime_int, .comptime_float, .@"enum", .void, .null, .undefined, .error_set => value,
        .optional => |opt| if (value) |v| try deepClone(opt.child, v, alloc) else null,
        .array => |arr| blk: {
            var out: T = undefined;
            for (value, 0..) |item, i| out[i] = try deepClone(arr.child, item, alloc);
            break :blk out;
        },
        .@"struct" => |s| blk: {
            var out: T = undefined;
            inline for (s.field_names, s.field_types) |field_name, FieldType| {
                @field(out, field_name) = try deepClone(FieldType, @field(value, field_name), alloc);
            }
            break :blk out;
        },
        .@"union" => |u| blk: {
            const Tag = u.tag_type orelse @compileError("deepClone requires tagged union: " ++ @typeName(T));
            switch (@as(Tag, value)) {
                inline else => |tag| {
                    const F = @FieldType(T, @tagName(tag));
                    const cloned = try deepClone(F, @field(value, @tagName(tag)), alloc);
                    break :blk @unionInit(T, @tagName(tag), cloned);
                },
            }
        },
        .pointer => |p| switch (p.size) {
            .one => blk: {
                if (p.child == anyopaque) break :blk value;
                if (@typeInfo(p.child) == .@"fn") break :blk value;
                const dst = try alloc.create(p.child);
                dst.* = try deepClone(p.child, value.*, alloc);
                break :blk dst;
            },
            .slice => blk: {
                const dst = try alloc.alloc(p.child, value.len);
                for (value, 0..) |item, i| dst[i] = try deepClone(p.child, item, alloc);
                break :blk dst;
            },
            else => @compileError("deepClone unsupported pointer size: " ++ @typeName(T)),
        },

        else => @compileError("deepClone unsupported type: " ++ @typeName(T)),
    };
}

test "state dir honors XDG_STATE_HOME and falls back to HOME" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try env.put("XDG_STATE_HOME", "/x/state");
    const xdg = try stateDir(std.testing.allocator, &env);
    defer std.testing.allocator.free(xdg);
    try std.testing.expectEqualStrings("/x/state/blitzdenk", xdg);

    try env.put("XDG_STATE_HOME", "relative/state");
    try env.put("HOME", "/home/u");
    const home = try stateDir(std.testing.allocator, &env);
    defer std.testing.allocator.free(home);
    try std.testing.expectEqualStrings("/home/u/.local/state/blitzdenk", home);

    try env.put("HOME", "relative/home");
    try std.testing.expectError(error.NoHomeFound, stateDir(std.testing.allocator, &env));
}

test "data dir honors XDG_DATA_HOME and falls back to HOME" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try env.put("XDG_DATA_HOME", "/x/data");
    const xdg = try dataDir(std.testing.allocator, &env);
    defer std.testing.allocator.free(xdg);
    try std.testing.expectEqualStrings("/x/data/blitzdenk", xdg);

    try env.put("XDG_DATA_HOME", "");
    try env.put("HOME", "/home/u");
    const home = try dataDir(std.testing.allocator, &env);
    defer std.testing.allocator.free(home);
    try std.testing.expectEqualStrings("/home/u/.local/share/blitzdenk", home);
}
