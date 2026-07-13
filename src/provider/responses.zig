const std = @import("std");
const Allocator = std.mem.Allocator;
const adapter = @import("adapter.zig");
const http = @import("http.zig");
const log = std.log.scoped(.responses_stream);

pub const Config = adapter.Config;

fn writeJson(w: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, w);
}

fn writeField(w: *std.Io.Writer, first: *bool, name: []const u8, value: anytype) !void {
    if (!first.*) try w.writeByte(',');
    first.* = false;
    try writeJson(w, name);
    try w.writeByte(':');
    try writeJson(w, value);
}

fn writeInputItem(w: *std.Io.Writer, first: *bool, raw: []const u8) !void {
    if (!first.*) try w.writeByte(',');
    first.* = false;
    try w.writeAll(raw);
}

fn roleName(role: adapter.Role) []const u8 {
    return switch (role) {
        .system => "system",
        .user => "user",
        .agent => "assistant",
    };
}

fn writeMessageItem(allocator: Allocator, w: *std.Io.Writer, first: *bool, msg: adapter.Message) !void {
    var has_content = false;
    for (msg.parts) |part| switch (part) {
        .text, .image => has_content = true,
        else => {},
    };
    if (!has_content) return;

    if (!first.*) try w.writeByte(',');
    first.* = false;
    try w.writeAll("{\"type\":\"message\",\"role\":");
    try writeJson(w, roleName(msg.role));
    try w.writeAll(",\"content\":[");
    var content_first = true;
    for (msg.parts) |part| switch (part) {
        .text => |text| {
            if (!content_first) try w.writeByte(',');
            content_first = false;
            try w.writeAll("{\"type\":");
            try writeJson(w, if (msg.role == .agent) "output_text" else "input_text");
            try w.writeAll(",\"text\":");
            try writeJson(w, text);
            try w.writeByte('}');
        },
        .image => |image| {
            if (!content_first) try w.writeByte(',');
            content_first = false;
            try w.writeAll("{\"type\":\"input_image\",\"image_url\":");
            const url = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ image.media_type, image.data });
            defer allocator.free(url);
            try writeJson(w, url);
            try w.writeByte('}');
        },
        else => {},
    };
    try w.writeAll("]}");
}

fn writeGeneratedItems(allocator: Allocator, w: *std.Io.Writer, first: *bool, msg: adapter.Message) !void {
    try writeMessageItem(allocator, w, first, msg);
    for (msg.parts) |part| switch (part) {
        .tool_call => |call| {
            if (!first.*) try w.writeByte(',');
            first.* = false;
            try w.writeAll("{\"type\":\"function_call\",\"call_id\":");
            try writeJson(w, call.id);
            try w.writeAll(",\"name\":");
            try writeJson(w, call.name);
            try w.writeAll(",\"arguments\":");
            try writeJson(w, call.arguments);
            try w.writeByte('}');
        },
        .tool_result => |result| {
            if (!first.*) try w.writeByte(',');
            first.* = false;
            try w.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
            try writeJson(w, result.call_id);
            try w.writeAll(",\"output\":");
            try writeJson(w, result.content);
            try w.writeByte('}');
        },
        else => {},
    };
}

fn writeTools(w: *std.Io.Writer, chat: *const adapter.Chat) !void {
    try w.writeByte('[');
    for (chat.tools.items, 0..) |tool, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"type\":\"function\",\"name\":");
        try writeJson(w, tool.name);
        try w.writeAll(",\"description\":");
        try writeJson(w, tool.description);
        try w.writeAll(",\"parameters\":");
        try w.writeAll(tool.parameters_schema);
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

fn serialize(allocator: Allocator, chat: *const adapter.Chat, config: Config, mode: adapter.CompletionMode, is_compact: bool) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    const w = &buf.writer;
    try w.writeByte('{');
    var first = true;
    try writeField(w, &first, "model", config.model);

    if (!first) try w.writeByte(',');
    first = false;
    try w.writeAll("\"input\":[");
    var input_first = true;
    for (chat.messages.items) |msg| {
        if (msg.role == .system) continue;
        if (msg.provider_items.len > 0) {
            for (msg.provider_items) |item| try writeInputItem(w, &input_first, item);
        } else {
            try writeGeneratedItems(allocator, w, &input_first, msg);
        }
    }
    try w.writeByte(']');

    var instructions: std.Io.Writer.Allocating = .init(allocator);
    defer instructions.deinit();
    for (chat.messages.items) |msg| {
        if (msg.role != .system) continue;
        for (msg.parts) |part| switch (part) {
            .text => |text| {
                if (instructions.writer.end > 0) try instructions.writer.writeByte('\n');
                try instructions.writer.writeAll(text);
            },
            else => {},
        };
    }
    if (instructions.writer.end > 0) try writeField(w, &first, "instructions", instructions.written());

    if (chat.tools.items.len > 0) {
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("\"tools\":");
        try writeTools(w, chat);
    }

    if (!is_compact) {
        try writeField(w, &first, "stream", mode == .streaming);
        try writeField(w, &first, "store", false);
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("\"include\":[\"reasoning.encrypted_content\"]");
        const rc = switch (config.provider) {
            .response => |value| value,
            else => return error.InvalidProvider,
        };
        if (rc.max_output_tokens) |value| try writeField(w, &first, "max_output_tokens", value);
        if (rc.temperature) |value| try writeField(w, &first, "temperature", value);
        if (rc.top_p) |value| try writeField(w, &first, "top_p", value);
        if (config.reasoning_effort) |effort| {
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("\"reasoning\":{\"effort\":");
            try writeJson(w, @tagName(effort));
            try w.writeAll(",\"summary\":\"auto\"}");
        }
    }
    try w.writeByte('}');
    return buf.toOwnedSlice();
}

pub fn serializeRequest(allocator: Allocator, chat: *const adapter.Chat, config: Config, mode: adapter.CompletionMode) ![]u8 {
    return serialize(allocator, chat, config, mode, false);
}

pub fn serializeCompactRequest(allocator: Allocator, chat: *const adapter.Chat, config: Config) ![]u8 {
    return serialize(allocator, chat, config, .blocking, true);
}

fn fetch(pool: *http.RequestPool, scratch: Allocator, url: []const u8, payload: []const u8, config: Config, options: adapter.CompletionOptions) !http.RequestPool.RequestHandle {
    const auth = try std.fmt.allocPrint(scratch, "Bearer {s}", .{config.api_key});
    defer scratch.free(auth);
    if (options.session_id) |sid| return pool.fetch(url, .POST, payload, &.{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Authorization", .value = auth },
        .{ .name = "x-session-affinity", .value = sid },
    }, options.timeout_ms);
    return pool.fetch(url, .POST, payload, &.{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Authorization", .value = auth },
    }, options.timeout_ms);
}

pub fn complete(pool: *http.RequestPool, scratch: Allocator, chat: *const adapter.Chat, config: Config, options: adapter.CompletionOptions) !http.RequestPool.RequestHandle {
    const payload = try serializeRequest(scratch, chat, config, options.mode);
    defer scratch.free(payload);
    const url = try std.fmt.allocPrint(scratch, "{s}/responses", .{config.base_url});
    defer scratch.free(url);
    return fetch(pool, scratch, url, payload, config, options);
}

pub fn compact(pool: *http.RequestPool, scratch: Allocator, chat: *const adapter.Chat, config: Config, options: adapter.CompletionOptions) !http.RequestPool.RequestHandle {
    const payload = try serializeCompactRequest(scratch, chat, config);
    defer scratch.free(payload);
    const url = try std.fmt.allocPrint(scratch, "{s}/responses/compact", .{config.base_url});
    defer scratch.free(url);
    return fetch(pool, scratch, url, payload, config, options);
}

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return if (field == .string) field.string else null;
}

fn numberField(value: std.json.Value, name: []const u8) u64 {
    if (value != .object) return 0;
    const field = value.object.get(name) orelse return 0;
    return switch (field) {
        .integer => |v| @intCast(@max(0, v)),
        .float => |v| @intFromFloat(@max(0, v)),
        else => 0,
    };
}

fn usageFrom(value: std.json.Value) ?adapter.TokenUsage {
    if (value != .object) return null;
    const usage = value.object.get("usage") orelse return null;
    const input = numberField(usage, "input_tokens");
    var cached: u64 = 0;
    if (usage == .object) {
        if (usage.object.get("input_tokens_details")) |details| cached = numberField(details, "cached_tokens");
    }
    return .{ .input_tokens = input -| cached, .output_tokens = numberField(usage, "output_tokens"), .cached_tokens = cached };
}

fn stringifyOwned(arena: Allocator, value: std.json.Value) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(arena);
    try writeJson(&buf.writer, value);
    return buf.toOwnedSlice();
}

fn appendPartsFromItem(arena: Allocator, parts: *std.ArrayList(adapter.ContentPart), item: std.json.Value) !void {
    const kind = stringField(item, "type") orelse return;
    if (std.mem.eql(u8, kind, "function_call")) {
        const args = stringField(item, "arguments") orelse "{}";
        try parts.append(arena, .{ .tool_call = .{
            .id = try arena.dupe(u8, stringField(item, "call_id") orelse stringField(item, "id") orelse ""),
            .name = try arena.dupe(u8, stringField(item, "name") orelse ""),
            .arguments = try arena.dupe(u8, args),
        } });
        return;
    }
    if (!std.mem.eql(u8, kind, "message") or item != .object) return;
    const content = item.object.get("content") orelse return;
    if (content != .array) return;
    for (content.array.items) |entry| {
        const entry_kind = stringField(entry, "type") orelse continue;
        const text = stringField(entry, "text") orelse continue;
        if (std.mem.eql(u8, entry_kind, "output_text")) try parts.append(arena, .{ .text = try arena.dupe(u8, text) });
    }
}

fn parseResult(arena: Allocator, body: []const u8) !adapter.ResponseResult {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if (parsed.value != .object) return error.EmptyResponse;
    const output = parsed.value.object.get("output") orelse return error.EmptyResponse;
    if (output != .array) return error.EmptyResponse;
    var parts: std.ArrayList(adapter.ContentPart) = .empty;
    var items: std.ArrayList([]const u8) = .empty;
    for (output.array.items) |item| {
        try items.append(arena, try stringifyOwned(arena, item));
        try appendPartsFromItem(arena, &parts, item);
    }
    return .{ .message = .{
        .role = .agent,
        .parts = try parts.toOwnedSlice(arena),
        .provider_items = try items.toOwnedSlice(arena),
    }, .usage = usageFrom(parsed.value) };
}

pub fn parseResponse(arena: Allocator, body: []const u8) !adapter.ResponseResult {
    return parseResult(arena, body);
}

pub const CompactResult = struct {
    items: []const []const u8,
    usage: ?adapter.TokenUsage,
};

pub fn parseCompactResponse(arena: Allocator, body: []const u8) !CompactResult {
    const result = try parseResult(arena, body);
    if (result.message.provider_items.len == 0) return error.EmptyResponse;
    return .{ .items = result.message.provider_items, .usage = result.usage };
}

pub const StreamState = struct {
    arena: Allocator,
    buf: std.ArrayList(u8) = .empty,
    text: std.ArrayList(u8) = .empty,
    thinking: std.ArrayList(u8) = .empty,
    items: std.ArrayList([]const u8) = .empty,
    calls: std.ArrayList(adapter.ToolCall) = .empty,
    pending: std.ArrayList(adapter.Delta) = .empty,
    pending_cursor: usize = 0,
    usage: ?adapter.TokenUsage = null,
    done: bool = false,
    finish_pending: bool = false,

    pub fn init(arena: Allocator) StreamState {
        return .{ .arena = arena };
    }

    pub fn next(self: *StreamState, pool: *http.RequestPool, handle: http.RequestPool.RequestHandle, arena: Allocator) !?adapter.Delta {
        while (true) {
            if (self.pending_cursor < self.pending.items.len) {
                const delta = self.pending.items[self.pending_cursor];
                self.pending_cursor += 1;
                return delta;
            }
            if (self.finish_pending) {
                self.finish_pending = false;
                self.done = true;
                return .finish;
            }
            if (self.done) return null;
            if (try self.drainLine(arena)) |delta| return delta;
            if (try pool.nextChunk(handle)) |chunk| {
                defer pool.dropChunk(chunk);
                try self.buf.appendSlice(arena, chunk);
                continue;
            }
            if (pool.isStreamDone(handle)) {
                self.finish_pending = true;
                continue;
            }
            return error.WouldBlock;
        }
    }

    fn drainLine(self: *StreamState, arena: Allocator) !?adapter.Delta {
        while (true) {
            const nl = std.mem.indexOfScalar(u8, self.buf.items, '\n') orelse return null;
            const line = try arena.dupe(u8, std.mem.trimEnd(u8, self.buf.items[0..nl], "\r"));
            const rest = self.buf.items[nl + 1 ..];
            std.mem.copyForwards(u8, self.buf.items[0..rest.len], rest);
            self.buf.items.len = rest.len;
            if (!std.mem.startsWith(u8, line, "data:")) continue;
            const payload = std.mem.trimStart(u8, line[5..], " ");
            if (std.mem.eql(u8, payload, "[DONE]")) {
                self.finish_pending = true;
                continue;
            }
            const parsed = std.json.parseFromSlice(std.json.Value, arena, payload, .{ .allocate = .alloc_always }) catch |err| {
                log.debug("sse parse failed: {s}", .{@errorName(err)});
                continue;
            };
            defer parsed.deinit();
            if (try self.applyEvent(arena, parsed.value)) |delta| return delta;
        }
    }

    fn applyEvent(self: *StreamState, arena: Allocator, event: std.json.Value) !?adapter.Delta {
        const kind = stringField(event, "type") orelse return null;
        if (std.mem.eql(u8, kind, "response.output_text.delta")) {
            const delta = stringField(event, "delta") orelse return null;
            try self.text.appendSlice(arena, delta);
            return .{ .text_chunk = try arena.dupe(u8, delta) };
        }
        if (std.mem.eql(u8, kind, "response.reasoning_summary_text.delta")) {
            const delta = stringField(event, "delta") orelse return null;
            try self.thinking.appendSlice(arena, delta);
            return .{ .thinking_chunk = try arena.dupe(u8, delta) };
        }
        if (std.mem.eql(u8, kind, "response.function_call_arguments.delta")) {
            const delta = stringField(event, "delta") orelse return null;
            return .{ .tool_input_delta = .{
                .call_id = try arena.dupe(u8, stringField(event, "item_id") orelse ""),
                .json_fragment = try arena.dupe(u8, delta),
            } };
        }
        if (std.mem.eql(u8, kind, "response.output_item.added") and event == .object) {
            const item = event.object.get("item") orelse return null;
            if (std.mem.eql(u8, stringField(item, "type") orelse "", "function_call")) return .{ .tool_call_start = .{
                .id = try arena.dupe(u8, stringField(item, "call_id") orelse stringField(item, "id") orelse ""),
                .name = try arena.dupe(u8, stringField(item, "name") orelse ""),
                .arguments = "",
            } };
        }
        if (std.mem.eql(u8, kind, "response.output_item.done") and event == .object) {
            const item = event.object.get("item") orelse return null;
            try self.items.append(arena, try stringifyOwned(arena, item));
            if (std.mem.eql(u8, stringField(item, "type") orelse "", "function_call")) try self.calls.append(arena, .{
                .id = try arena.dupe(u8, stringField(item, "call_id") orelse stringField(item, "id") orelse ""),
                .name = try arena.dupe(u8, stringField(item, "name") orelse ""),
                .arguments = try arena.dupe(u8, stringField(item, "arguments") orelse "{}"),
            });
            return null;
        }
        if (std.mem.eql(u8, kind, "response.completed")) {
            self.usage = usageFrom(event.object.get("response") orelse event);
            if (self.usage) |usage| try self.pending.append(arena, .{ .usage = usage });
            self.finish_pending = true;
            return null;
        }
        if (std.mem.eql(u8, kind, "response.failed") or std.mem.eql(u8, kind, "response.incomplete")) {
            return .{ .provider_error = try stringifyOwned(arena, event) };
        }
        return null;
    }

    pub fn finalize(self: *StreamState, arena: Allocator) !adapter.ResponseResult {
        var parts: std.ArrayList(adapter.ContentPart) = .empty;
        if (self.thinking.items.len > 0) try parts.append(arena, .{ .thinking = .{ .text = try arena.dupe(u8, self.thinking.items) } });
        if (self.text.items.len > 0) try parts.append(arena, .{ .text = try arena.dupe(u8, self.text.items) });
        for (self.calls.items) |call| try parts.append(arena, .{ .tool_call = .{
            .id = try arena.dupe(u8, call.id),
            .name = try arena.dupe(u8, call.name),
            .arguments = try arena.dupe(u8, call.arguments),
        } });
        if (parts.items.len == 0 and self.items.items.len == 0) return error.EmptyResponse;
        const raw = try arena.alloc([]const u8, self.items.items.len);
        for (self.items.items, 0..) |item, i| raw[i] = try arena.dupe(u8, item);
        return .{ .message = .{
            .role = .agent,
            .parts = try parts.toOwnedSlice(arena),
            .provider_items = raw,
        }, .usage = self.usage };
    }
};

test "responses request uses stateless streaming API" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var chat: adapter.Chat = .{};
    try chat.addMessage(arena, .system, &.{.{ .text = "be useful" }});
    try chat.addMessage(arena, .user, &.{.{ .text = "hello" }});
    const cfg: Config = .{ .api_key = "key", .model = "gpt-test", .base_url = "https://api.openai.com/v1", .provider = .{ .response = .{ .max_output_tokens = 123 } } };
    const payload = try serializeRequest(testing.allocator, &chat, cfg, .streaming);
    defer testing.allocator.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    try testing.expect(std.mem.indexOf(u8, payload, "\"stream\":true") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"store\":false") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "reasoning.encrypted_content") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"max_output_tokens\":123") != null);
}

test "responses stream surfaces failed event payload" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, "{\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"model unavailable\"}}}", .{});
    defer parsed.deinit();
    var stream = StreamState.init(arena);
    const delta = (try stream.applyEvent(arena, parsed.value)) orelse return error.TestUnexpectedResult;

    switch (delta) {
        .provider_error => |body| try testing.expect(std.mem.indexOf(u8, body, "model unavailable") != null),
        else => return error.TestUnexpectedResult,
    }
}

test "responses request replays canonical provider items" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var chat: adapter.Chat = .{};
    try chat.messages.append(arena, .{
        .role = .agent,
        .parts = try arena.dupe(adapter.ContentPart, &.{.{ .text = "display copy" }}),
        .provider_items = try arena.dupe([]const u8, &.{"{\"type\":\"compaction\",\"encrypted_content\":\"opaque\"}"}),
    });
    const cfg: Config = .{ .api_key = "key", .model = "gpt-test", .base_url = "https://api.openai.com/v1", .provider = .{ .response = .{} } };
    const payload = try serializeCompactRequest(testing.allocator, &chat, cfg);
    defer testing.allocator.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    try testing.expect(std.mem.indexOf(u8, payload, "encrypted_content") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "display copy") == null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"stream\"") == null);
}

test "responses blocking output preserves canonical items" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const result = try parseResponse(arena_state.allocator(),
        \\{"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi"}]}],"usage":{"input_tokens":9,"output_tokens":2,"input_tokens_details":{"cached_tokens":4}}}
    );
    try testing.expectEqualStrings("hi", result.message.parts[0].text);
    try testing.expectEqual(@as(usize, 1), result.message.provider_items.len);
    try testing.expectEqual(@as(u64, 5), result.usage.?.input_tokens);
    try testing.expectEqual(@as(u64, 4), result.usage.?.cached_tokens);
}

test "responses stream aggregates text tools usage and raw items" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stream = StreamState.init(arena);

    const events = [_][]const u8{
        "{\"type\":\"response.output_text.delta\",\"delta\":\"hello\"}",
        "{\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"think\"}",
        "{\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"hello\"}]}}",
        "{\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"read\",\"arguments\":\"{}\"}}",
        "{\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":10,\"output_tokens\":3}}}",
    };
    for (events) |json| {
        const parsed = try std.json.parseFromSlice(std.json.Value, arena, json, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        _ = try stream.applyEvent(arena, parsed.value);
    }
    const result = try stream.finalize(arena);
    try testing.expectEqualStrings("think", result.message.parts[0].thinking.text);
    try testing.expectEqualStrings("hello", result.message.parts[1].text);
    try testing.expectEqualStrings("call_1", result.message.parts[2].tool_call.id);
    try testing.expectEqual(@as(usize, 2), result.message.provider_items.len);
    try testing.expectEqual(@as(u64, 10), result.usage.?.input_tokens);
}
