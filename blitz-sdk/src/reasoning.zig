const std = @import("std");

const payload_keys = [_][]const u8{ "text", "summary", "data" };

const Block = struct {
    value: std.json.Value,
    payloads: [payload_keys.len]std.ArrayList(u8) = @splat(.empty),
};

fn isUnset(value: std.json.Value) bool {
    return value == .null or (value == .string and value.string.len == 0);
}

fn equalField(a: std.json.Value, b: std.json.Value, key: []const u8) bool {
    const left = a.object.get(key) orelse return true;
    const right = b.object.get(key) orelse return true;
    if (left == .null or right == .null) return true;
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .string => |value| std.mem.eql(u8, value, right.string) or (std.mem.eql(u8, key, "id") and (value.len == 0 or right.string.len == 0)),
        .integer => |value| value == right.integer,
        else => false,
    };
}

fn sameBlock(a: std.json.Value, b: std.json.Value) bool {
    if (a != .object or b != .object) return false;
    if (!a.object.contains("index") or !b.object.contains("index")) {
        const left = a.object.get("id") orelse return false;
        const right = b.object.get("id") orelse return false;
        if (left != .string or right != .string or left.string.len == 0) return false;
        if (!std.mem.eql(u8, left.string, right.string)) return false;
    }
    for ([_][]const u8{ "type", "index", "id", "format" }) |key| {
        if (!equalField(a, b, key)) return false;
    }
    return true;
}

pub fn normalizeDetails(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '[') return alloc.dupe(u8, raw);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return alloc.dupe(u8, raw),
    };
    defer parsed.deinit();
    if (parsed.value != .array or parsed.value.array.items.len < 2) return alloc.dupe(u8, raw);
    const scratch = parsed.arena.allocator();
    var blocks: std.ArrayList(Block) = .empty;
    for (parsed.value.array.items) |value| {
        var index: usize = blocks.items.len;
        for (blocks.items, 0..) |block, i| {
            if (sameBlock(block.value, value)) {
                index = i;
                break;
            }
        }
        if (index == blocks.items.len) try blocks.append(scratch, .{ .value = value });
        const block = &blocks.items[index];
        if (value != .object) continue;
        var fields = value.object.iterator();
        while (fields.next()) |field| {
            var payload = false;
            for (payload_keys, 0..) |key, i| {
                if (!std.mem.eql(u8, key, field.key_ptr.*)) continue;
                payload = true;
                if (field.value_ptr.* == .string) try block.payloads[i].appendSlice(scratch, field.value_ptr.string);
                break;
            }
            if (payload) continue;
            const current = block.value.object.get(field.key_ptr.*);
            if (current != null and !isUnset(current.?)) continue;
            if (isUnset(field.value_ptr.*)) continue;
            try block.value.object.put(scratch, field.key_ptr.*, field.value_ptr.*);
        }
    }
    var values: std.ArrayList(std.json.Value) = .empty;
    for (blocks.items) |*block| {
        if (block.value == .object) for (payload_keys, 0..) |key, i| {
            if (block.payloads[i].items.len == 0) continue;
            try block.value.object.put(scratch, key, .{ .string = block.payloads[i].items });
        };
        try values.append(scratch, block.value);
    }
    return std.json.Stringify.valueAlloc(alloc, values.items, .{});
}

pub fn textFromDetails(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return alloc.dupe(u8, ""),
    };
    defer parsed.deinit();
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    if (parsed.value == .array) for (parsed.value.array.items) |value| {
        if (value != .object) continue;
        for (payload_keys[0..2]) |key| {
            if (value.object.get(key)) |field| {
                if (field == .string) try text.appendSlice(alloc, field.string);
            }
        }
    };
    return text.toOwnedSlice(alloc);
}

test "reasoning fragments merge by block and retain encrypted replay data" {
    const alloc = std.testing.allocator;
    const raw =
        \\[{"type":"reasoning.text","index":0,"text":"Hello","format":"unknown"},
        \\ {"type":"reasoning.encrypted","index":1,"id":"secret","data":"abc"},
        \\ {"type":"reasoning.text","index":0,"text":" world"},
        \\ {"type":"reasoning.encrypted","index":1,"data":"def"},
        \\ {"type":"reasoning.text","index":2,"text":"Separate"}]
    ;
    const normalized = try normalizeDetails(alloc, raw);
    defer alloc.free(normalized);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, normalized, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 3), parsed.value.array.items.len);
    try std.testing.expectEqualStrings("Hello world", parsed.value.array.items[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("abcdef", parsed.value.array.items[1].object.get("data").?.string);
    try std.testing.expectEqualStrings("secret", parsed.value.array.items[1].object.get("id").?.string);
    const text = try textFromDetails(alloc, normalized);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("Hello worldSeparate", text);
    const again = try normalizeDetails(alloc, normalized);
    defer alloc.free(again);
    try std.testing.expectEqualStrings(normalized, again);
}

test "late signature fills a null placeholder" {
    const alloc = std.testing.allocator;
    const normalized = try normalizeDetails(alloc,
        \\[{"type":"reasoning.text","text":"Let","signature":null,"index":0},
        \\ {"type":"reasoning.text","text":" me think.","index":0},
        \\ {"type":"reasoning.text","signature":"Et8BCmUIDxgC","index":0}]
    );
    defer alloc.free(normalized);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, normalized, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    const block = parsed.value.array.items[0].object;
    try std.testing.expectEqualStrings("Let me think.", block.get("text").?.string);
    try std.testing.expectEqualStrings("Et8BCmUIDxgC", block.get("signature").?.string);
}

test "null id merges with a late id and signature" {
    const alloc = std.testing.allocator;
    const normalized = try normalizeDetails(alloc,
        \\[{"type":"reasoning.text","text":"Let","id":null,"index":0},
        \\ {"type":"reasoning.text","text":" me","id":"r1","index":0},
        \\ {"type":"reasoning.text","signature":"SIG","id":"r1","index":0}]
    );
    defer alloc.free(normalized);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, normalized, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    const block = parsed.value.array.items[0].object;
    try std.testing.expectEqualStrings("Let me", block.get("text").?.string);
    try std.testing.expectEqualStrings("r1", block.get("id").?.string);
    try std.testing.expectEqualStrings("SIG", block.get("signature").?.string);
}

test "payload is written when the first fragment omits the key" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { raw: []const u8, key: []const u8, expected: []const u8 }{
        .{ .raw = "[{\"type\":\"reasoning.text\",\"index\":0},{\"type\":\"reasoning.text\",\"index\":0,\"text\":\"hello\"}]", .key = "text", .expected = "hello" },
        .{ .raw = "[{\"type\":\"reasoning.summary\",\"index\":0},{\"type\":\"reasoning.summary\",\"index\":0,\"summary\":\"plan\"}]", .key = "summary", .expected = "plan" },
        .{ .raw = "[{\"type\":\"reasoning.encrypted\",\"index\":0},{\"type\":\"reasoning.encrypted\",\"index\":0,\"data\":\"abc\"}]", .key = "data", .expected = "abc" },
        .{ .raw = "[{\"type\":\"reasoning.text\",\"index\":0,\"text\":null},{\"type\":\"reasoning.text\",\"index\":0,\"text\":\"hi\"}]", .key = "text", .expected = "hi" },
    };
    for (cases) |case| {
        const normalized = try normalizeDetails(alloc, case.raw);
        defer alloc.free(normalized);
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, normalized, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
        try std.testing.expectEqualStrings(case.expected, parsed.value.array.items[0].object.get(case.key).?.string);
    }
}

test "opaque signatures and unidentified blocks are preserved" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "opaque-signature", "[not-json" }) |raw| {
        const normalized = try normalizeDetails(alloc, raw);
        defer alloc.free(normalized);
        try std.testing.expectEqualStrings(raw, normalized);
    }
    const normalized = try normalizeDetails(alloc, "[{\"type\":\"reasoning.text\",\"text\":\"one\"},{\"type\":\"reasoning.text\",\"text\":\"two\"}]");
    defer alloc.free(normalized);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, normalized, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
}

pub fn providerBytes(raw: []const u8) u64 {
    var buffer: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), raw);
    defer scanner.deinit();
    const result = valueBytes(&scanner, scanner.next() catch return raw.len, 0) catch return raw.len;
    if ((scanner.next() catch return raw.len) != .end_of_document) return raw.len;
    return result;
}

fn valueBytes(scanner: *std.json.Scanner, first: std.json.Token, depth: usize) anyerror!u64 {
    if (depth > 64) return error.ExcessiveDepth;
    var bytes: u64 = 0;
    switch (first) {
        .object_begin => {
            while (true) {
                const key = try scanner.next();
                if (key == .object_end) return bytes;
                if (key != .string) return error.InvalidKey;
                var skip = false;
                for ([_][]const u8{ "encrypted_content", "signature", "data", "id", "type", "format", "index", "status" }) |metadata| {
                    if (std.mem.eql(u8, key.string, metadata)) {
                        skip = true;
                        break;
                    }
                }
                if (skip) {
                    try scanner.skipValue();
                } else {
                    bytes += try valueBytes(scanner, try scanner.next(), depth + 1);
                }
            }
        },
        .array_begin => {
            while (true) {
                const value = try scanner.next();
                if (value == .array_end) return bytes;
                bytes += try valueBytes(scanner, value, depth + 1);
            }
        },
        .string => |value| return value.len,
        .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => {
            var token = first;
            while (true) {
                switch (token) {
                    .string => |value| return bytes + value.len,
                    .partial_string => |value| bytes += value.len,
                    inline .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => |value| bytes += value.len,
                    else => return error.InvalidString,
                }
                token = try scanner.next();
            }
        },
        .number => |value| return value.len,
        .true, .false, .null => return 4,
        else => return error.InvalidValue,
    }
}

test "provider replay metadata counts visible content without encrypted payloads" {
    try std.testing.expectEqual(@as(u64, 7), providerBytes("{\"type\":\"reasoning\",\"encrypted_content\":\"large-opaque-payload\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"visible\"}]}"));
    try std.testing.expectEqual(@as(u64, 7), providerBytes("{\"type\":\"message\",\"content\":[{\"text\":\"hello\\n!\"}]}"));
    try std.testing.expectEqual(@as(u64, 3), providerBytes("raw"));
}
