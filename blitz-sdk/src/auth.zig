const std = @import("std");
const builtin = @import("builtin");

pub const Env = struct {
    map: ?*const std.process.Environ.Map = null,

    pub fn get(self: Env, key: []const u8) ?[]const u8 {
        if (self.map) |m| return m.get(key);
        if (comptime builtin.link_libc and builtin.os.tag != .windows) {
            const environ = std.process.Environ{
                .block = .{ .slice = std.mem.span(std.c.environ) },
            };
            return environ.getPosix(key);
        }
        return null;
    }
};

pub fn resolveKey(env: Env, env_var: []const u8) ?[]const u8 {
    const value = env.get(env_var) orelse return null;
    if (value.len == 0) return null;
    return value;
}

pub fn bearerHeader(alloc: std.mem.Allocator, key: []const u8) !std.http.Header {
    return .{
        .name = try alloc.dupe(u8, "Authorization"),
        .value = try std.fmt.allocPrint(alloc, "Bearer {s}", .{key}),
    };
}

pub fn apiKeyHeader(alloc: std.mem.Allocator, key: []const u8) !std.http.Header {
    return .{
        .name = try alloc.dupe(u8, "x-api-key"),
        .value = try alloc.dupe(u8, key),
    };
}

pub fn cloneHeaders(alloc: std.mem.Allocator, headers: []const std.http.Header) ![]const std.http.Header {
    const result = try alloc.alloc(std.http.Header, headers.len);
    for (headers, result) |header, *dest| {
        dest.* = .{
            .name = try alloc.dupe(u8, header.name),
            .value = try alloc.dupe(u8, header.value),
        };
    }
    return result;
}

pub fn ownHeaders(alloc: std.mem.Allocator, headers: []const std.http.Header) ![]std.http.Header {
    const result = try alloc.alloc(std.http.Header, headers.len);
    var owned: usize = 0;
    errdefer freeHeaders(alloc, result[0..owned]);
    for (headers, result) |header, *dest| {
        dest.* = .{
            .name = try alloc.dupe(u8, header.name),
            .value = try alloc.dupe(u8, header.value),
        };
        owned += 1;
    }
    return result;
}

pub fn freeHeaders(alloc: std.mem.Allocator, headers: []const std.http.Header) void {
    for (headers) |header| {
        alloc.free(header.name);
        alloc.free(header.value);
    }
    alloc.free(headers);
}

pub fn appendHeaders(
    alloc: std.mem.Allocator,
    list: *std.ArrayList(std.http.Header),
    headers: []const std.http.Header,
) !void {
    for (headers) |header| try list.append(alloc, header);
}

test "resolve from injected map" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("OPENAI_API_KEY", "sk-test");

    const env = Env{ .map = &env_map };
    try std.testing.expectEqualStrings("sk-test", resolveKey(env, "OPENAI_API_KEY").?);
    try std.testing.expect(resolveKey(env, "MISSING") == null);
}
