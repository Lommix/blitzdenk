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
            inline for (s.fields) |f| {
                @field(out, f.name) = try deepClone(f.type, @field(value, f.name), alloc);
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
