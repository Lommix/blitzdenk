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

pub fn escapeMarkup(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (text) |c| switch (c) {
        '&' => try out.appendSlice(alloc, "&amp;"),
        '<' => try out.appendSlice(alloc, "&lt;"),
        '>' => try out.appendSlice(alloc, "&gt;"),
        else => try out.append(alloc, c),
    };
    return out.toOwnedSlice(alloc);
}

pub fn utf8Prefix(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

pub fn expandHomePath(path: []const u8, home: []const u8, buf: []u8) []const u8 {
    if (home.len == 0 or home[0] != '/') return path;
    if (std.mem.eql(u8, path, "~")) return home;
    if (std.mem.startsWith(u8, path, "~/"))
        return std.fmt.bufPrint(buf, "{s}{s}", .{ home, path[1..] }) catch path;
    return path;
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

test "expand home path" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/home/u", expandHomePath("~", "/home/u", &buf));
    try std.testing.expectEqualStrings("/home/u/proj", expandHomePath("~/proj", "/home/u", &buf));
    try std.testing.expectEqualStrings("~user/x", expandHomePath("~user/x", "/home/u", &buf));
    try std.testing.expectEqualStrings("~/x", expandHomePath("~/x", "", &buf));
}
