const std = @import("std");
const model = @import("../model.zig");
const types = @import("../types.zig");
const auth = @import("../auth.zig");
const jsonx = @import("jsonx.zig");

pub const default_base_url = "https://api.anthropic.com/v1";
pub const api_key_env = "ANTHROPIC_API_KEY";
pub const api_version = "2023-06-01";

pub const Options = struct {
    api_key: ?[]const u8 = null,
    base_url: []const u8 = default_base_url,
    headers: []const std.http.Header = &.{},
    env: auth.Env = .{},
    rate_limit: u32 = 0,
};

pub const Chat = struct {
    model_id: []const u8,
    api_key: []const u8,
    base_url: []const u8,
    extra_headers: []const std.http.Header,
    rate_limit: u32,

    pub fn init(alloc: std.mem.Allocator, model_id: []const u8, opts: Options) !Chat {
        const key = opts.api_key orelse auth.resolveKey(opts.env, api_key_env) orelse "";
        return .{
            .model_id = try alloc.dupe(u8, model_id),
            .api_key = try alloc.dupe(u8, key),
            .base_url = try alloc.dupe(u8, opts.base_url),
            .extra_headers = try auth.cloneHeaders(alloc, opts.headers),
            .rate_limit = opts.rate_limit,
        };
    }

    pub fn deinit(self: *Chat, alloc: std.mem.Allocator) void {
        alloc.free(self.model_id);
        alloc.free(self.api_key);
        alloc.free(self.base_url);
        auth.freeHeaders(alloc, self.extra_headers);
    }

    pub fn languageModel(self: *Chat) model.LanguageModel {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = model.ModelVTable{
        .model_id = modelId,
        .generate = generate,
        .stream = stream,
    };

    fn modelId(ctx: *anyopaque) []const u8 {
        const self: *Chat = @ptrCast(@alignCast(ctx));
        return self.model_id;
    }

    fn authHeaders(self: *Chat, a: std.mem.Allocator, request_headers: []const std.http.Header) ![]std.http.Header {
        var headers: std.ArrayList(std.http.Header) = .empty;
        defer headers.deinit(a);
        if (self.api_key.len > 0) {
            try headers.append(a, try auth.apiKeyHeader(a, self.api_key));
        }
        try headers.append(a, .{ .name = "anthropic-version", .value = api_version });
        try auth.appendHeaders(a, &headers, self.extra_headers);
        try auth.appendHeaders(a, &headers, request_headers);
        return auth.ownHeaders(a, headers.items);
    }

    fn generate(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        io: std.Io,
        params: model.GenerateParams,
        client: ?*std.http.Client,
        max_retries: u32,
    ) anyerror!*model.GenerateResult {
        const self: *Chat = @ptrCast(@alignCast(ctx));

        const body = try buildRequest(alloc, self.model_id, params, false);
        defer alloc.free(body);
        const headers = try self.authHeaders(alloc, params.headers);
        defer auth.freeHeaders(alloc, headers);
        const url = try std.fmt.allocPrint(alloc, "{s}/messages", .{self.base_url});
        defer alloc.free(url);
        const response = try jsonx.postWithRetry(alloc, io, client, url, body, headers, max_retries, requestOptions(self, params));
        defer alloc.free(response);
        return parseResponse(alloc, response);
    }

    fn stream(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        io: std.Io,
        params: model.GenerateParams,
        client: ?*std.http.Client,
        max_retries: u32,
        sctx: *model.StreamContext,
    ) anyerror!*model.GenerateResult {
        const self: *Chat = @ptrCast(@alignCast(ctx));
        const body = try buildRequest(alloc, self.model_id, params, true);
        const headers = try self.authHeaders(alloc, params.headers);
        const url = try std.fmt.allocPrint(alloc, "{s}/messages", .{self.base_url});
        const request_options = requestOptions(self, params);
        var live = LiveStream{ .alloc = alloc, .sctx = sctx, .options = request_options };
        const sse_text = try jsonx.postSseWithRetry(alloc, io, client, url, body, headers, max_retries, request_options, &live, emitLiveEvent);
        var final_ctx = model.StreamContext{ .emit = emitFinalTool, .emit_ctx = sctx };
        return parseStream(alloc, sse_text, &final_ctx);
    }
};

fn requestOptions(self: *const Chat, params: model.GenerateParams) jsonx.RequestOptions {
    return .{
        .timeout_ms = params.timeout_ms,
        .cancellation = params.cancellation,
        .on_provider_error = params.on_provider_error,
        .on_provider_error_ctx = params.on_provider_error_ctx,
        .rate_limit = self.rate_limit,
        .rate_limit_url = self.base_url,
    };
}

const LiveStream = struct {
    alloc: std.mem.Allocator,
    sctx: *model.StreamContext,
    options: jsonx.RequestOptions,
};

fn emitLive(ctx: ?*anyopaque, chunk: types.StreamChunk) void {
    const sctx: *model.StreamContext = @ptrCast(@alignCast(ctx.?));
    if (chunk.type != .tool_call) sctx.send(chunk);
}

fn emitFinalTool(ctx: ?*anyopaque, chunk: types.StreamChunk) void {
    const sctx: *model.StreamContext = @ptrCast(@alignCast(ctx.?));
    if (chunk.type == .tool_call) sctx.send(chunk);
}

fn emitLiveEvent(ctx: ?*anyopaque, data: []const u8) !void {
    const live: *LiveStream = @ptrCast(@alignCast(ctx.?));
    if (jsonx.reportStreamError(live.alloc, live.options, data)) |err| return err;
    const event = try std.fmt.allocPrint(live.alloc, "data: {s}\n", .{data});
    var event_ctx = model.StreamContext{ .emit = emitLive, .emit_ctx = live.sctx };
    _ = try parseStream(live.alloc, event, &event_ctx);
}

fn buildRequest(
    a: std.mem.Allocator,
    model_id: []const u8,
    params: model.GenerateParams,
    stream: bool,
) ![]const u8 {
    var invalid_calls: std.StringHashMapUnmanaged(void) = .empty;
    defer invalid_calls.deinit(a);
    for (params.messages) |msg| {
        for (msg.parts()) |part| switch (part) {
            .tool_call => |call| if (!isJsonObject(a, call.input)) try invalid_calls.put(a, call.id, {}),
            else => {},
        };
    }

    var w = std.Io.Writer.Allocating.init(a);
    defer w.deinit();
    var s: std.json.Stringify = .{ .writer = &w.writer };

    try s.beginObject();
    try s.objectField("model");
    try s.write(model_id);

    if (params.system.len > 0) {
        try s.objectField("system");
        if (params.prompt_caching) {
            try s.beginArray();
            try s.beginObject();
            try s.objectField("type");
            try s.write("text");
            try s.objectField("text");
            try s.write(params.system);
            try writeCacheControl(&s, params.cache_ttl);
            try s.endObject();
            try s.endArray();
        } else {
            try s.write(params.system);
        }
    }

    try s.objectField("messages");
    try s.beginArray();
    for (params.messages, 0..) |msg, i| {
        if (msg.role == .system or msg.role == .developer) continue;
        if (!hasContent(msg, &invalid_calls)) continue;
        try s.beginObject();
        try s.objectField("role");
        try s.write(if (msg.role == .assistant) "assistant" else "user");
        try s.objectField("content");
        try writeContent(&s, msg, &invalid_calls, params.prompt_caching and i + 1 == params.messages.len, params.cache_ttl);
        try s.endObject();
    }
    try s.endArray();

    try s.objectField("max_tokens");
    try s.write(if (params.max_output_tokens > 0) params.max_output_tokens else 4096);

    if (params.temperature) |t| {
        try s.objectField("temperature");
        try s.write(t);
    }
    if (params.top_p) |t| {
        try s.objectField("top_p");
        try s.write(t);
    }
    if (params.top_k) |t| {
        try s.objectField("top_k");
        try s.write(t);
    }
    if (params.stop_sequences.len > 0) {
        try s.objectField("stop_sequences");
        try s.write(params.stop_sequences);
    }

    if (params.tools.len > 0) {
        try s.objectField("tools");
        try s.beginArray();
        for (params.tools, 0..) |tool, i| {
            try s.beginObject();
            try s.objectField("name");
            try s.write(tool.name);
            try s.objectField("description");
            try s.write(tool.description);
            try s.objectField("input_schema");
            try jsonx.writeRaw(&s, tool.input_schema);
            if (params.prompt_caching and i + 1 == params.tools.len) try writeCacheControl(&s, params.cache_ttl);
            try s.endObject();
        }
        try s.endArray();
    }

    switch (params.tool_choice) {
        .auto => {},
        .none => {
            try s.objectField("tool_choice");
            try s.beginObject();
            try s.objectField("type");
            try s.write("none");
            try s.endObject();
        },
        .required => {
            try s.objectField("tool_choice");
            try s.beginObject();
            try s.objectField("type");
            try s.write("any");
            try s.endObject();
        },
        .tool => |name| {
            try s.objectField("tool_choice");
            try s.beginObject();
            try s.objectField("type");
            try s.write("tool");
            try s.objectField("name");
            try s.write(name);
            try s.endObject();
        },
    }
    if (params.response_format) |format| {
        try s.objectField("output_config");
        try s.beginObject();
        try s.objectField("format");
        try s.beginObject();
        try s.objectField("type");
        try s.write("json_schema");
        try s.objectField("schema");
        try jsonx.writeRaw(&s, format.schema);
        try s.endObject();
        try s.endObject();
    }
    try jsonx.writeProviderOptions(&s, params.provider_options);

    try s.objectField("stream");
    try s.write(stream);
    try s.endObject();
    return w.toOwnedSlice();
}

fn writeCacheControl(s: *std.json.Stringify, ttl: ?[]const u8) !void {
    try s.objectField("cache_control");
    try s.beginObject();
    try s.objectField("type");
    try s.write("ephemeral");
    if (ttl) |value| {
        try s.objectField("ttl");
        try s.write(value);
    }
    try s.endObject();
}

fn writeContent(s: *std.json.Stringify, msg: types.Message, invalid_calls: *const std.StringHashMapUnmanaged(void), cache: bool, ttl: ?[]const u8) !void {
    const last = lastContentIndex(msg, invalid_calls);
    try s.beginArray();
    for (msg.parts(), 0..) |part, i| {
        switch (part) {
            .text => |text| {
                try s.beginObject();
                try s.objectField("type");
                try s.write("text");
                try s.objectField("text");
                try s.write(text);
                if (cache and last == i) try writeCacheControl(s, ttl);
                try s.endObject();
            },
            .tool_call => |call| {
                if (invalid_calls.contains(call.id)) continue;
                try s.beginObject();
                try s.objectField("type");
                try s.write("tool_use");
                try s.objectField("id");
                try s.write(call.id);
                try s.objectField("name");
                try s.write(call.name);
                try s.objectField("input");
                try jsonx.writeRaw(s, call.input);
                if (cache and last == i) try writeCacheControl(s, ttl);
                try s.endObject();
            },
            .tool_result => |result| {
                if (invalid_calls.contains(result.id)) continue;
                try s.beginObject();
                try s.objectField("type");
                try s.write("tool_result");
                try s.objectField("tool_use_id");
                try s.write(result.id);
                try s.objectField("content");
                try s.write(result.output);
                if (result.is_error or std.mem.startsWith(u8, result.output, "error:")) {
                    try s.objectField("is_error");
                    try s.write(true);
                }
                if (cache and last == i) try writeCacheControl(s, ttl);
                try s.endObject();
            },
            .reasoning => |reasoning| {
                try s.beginObject();
                try s.objectField("type");
                try s.write("thinking");
                try s.objectField("thinking");
                try s.write(reasoning.text);
                try s.objectField("signature");
                try s.write(reasoning.signature);
                if (cache and last == i) try writeCacheControl(s, ttl);
                try s.endObject();
            },
            else => {},
        }
    }
    try s.endArray();
}

fn isJsonObject(a: std.mem.Allocator, value: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, a, value, .{}) catch return false;
    defer parsed.deinit();
    return parsed.value == .object;
}

fn hasContent(msg: types.Message, invalid_calls: *const std.StringHashMapUnmanaged(void)) bool {
    return lastContentIndex(msg, invalid_calls) != null;
}

fn lastContentIndex(msg: types.Message, invalid_calls: *const std.StringHashMapUnmanaged(void)) ?usize {
    var index = msg.parts().len;
    while (index > 0) {
        index -= 1;
        switch (msg.parts()[index]) {
            .tool_call => |call| if (!invalid_calls.contains(call.id)) return index,
            .tool_result => |result| if (!invalid_calls.contains(result.id)) return index,
            .text, .reasoning => return index,
            else => {},
        }
    }
    return null;
}

fn parseResponse(a: std.mem.Allocator, body: []const u8) !*model.GenerateResult {
    var parsed = std.json.parseFromSlice(std.json.Value, a, body, .{}) catch return error.InvalidResponse;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;

    const result = try a.create(model.GenerateResult);
    errdefer {
        result.deinit(a);
        a.destroy(result);
    }
    result.* = .{};

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(a);
    var reasoning: std.ArrayList(u8) = .empty;
    errdefer reasoning.deinit(a);
    var calls: std.ArrayList(types.ToolCall) = .empty;
    errdefer {
        for (calls.items) |tc| {
            a.free(tc.id);
            a.free(tc.name);
            a.free(tc.input);
        }
        calls.deinit(a);
    }

    if (root.object.get("content")) |content| {
        if (content == .array) {
            for (content.array.items) |block| {
                if (block != .object) continue;
                const btype = block.object.get("type") orelse continue;
                if (btype != .string) continue;
                if (std.mem.eql(u8, btype.string, "text")) {
                    if (block.object.get("text")) |t| {
                        if (t == .string) try text.appendSlice(a, t.string);
                    }
                } else if (std.mem.eql(u8, btype.string, "thinking")) {
                    if (block.object.get("thinking")) |t| {
                        if (t == .string) try reasoning.appendSlice(a, t.string);
                    }
                    if (block.object.get("signature")) |signature| {
                        if (signature == .string) {
                            a.free(result.reasoning_signature);
                            result.reasoning_signature = try a.dupe(u8, signature.string);
                        }
                    }
                } else if (std.mem.eql(u8, btype.string, "tool_use")) {
                    var id: []const u8 = "";
                    var name: []const u8 = "";
                    if (block.object.get("id")) |v| {
                        if (v == .string) id = v.string;
                    }
                    if (block.object.get("name")) |v| {
                        if (v == .string) name = v.string;
                    }
                    const input = if (block.object.get("input")) |v|
                        (std.json.Stringify.valueAlloc(a, v, .{}) catch "")
                    else
                        "";
                    try calls.append(a, .{
                        .id = try a.dupe(u8, id),
                        .name = try a.dupe(u8, name),
                        .input = input,
                    });
                }
            }
        }
    }
    result.text = try text.toOwnedSlice(a);
    result.reasoning = try reasoning.toOwnedSlice(a);
    result.tool_calls = try calls.toOwnedSlice(a);

    if (root.object.get("stop_reason")) |sr| {
        if (sr == .string) result.finish_reason = mapFinish(sr.string);
    }
    result.usage = parseUsage(root);
    if (root.object.get("id")) |v| {
        if (v == .string) result.response.id = try a.dupe(u8, v.string);
    }
    if (root.object.get("model")) |v| {
        if (v == .string) result.response.model = try a.dupe(u8, v.string);
    }
    return result;
}

fn mapFinish(reason: []const u8) types.FinishReason {
    if (std.mem.eql(u8, reason, "end_turn")) return .stop;
    if (std.mem.eql(u8, reason, "tool_use")) return .tool_calls;
    if (std.mem.eql(u8, reason, "max_tokens")) return .length;
    if (std.mem.eql(u8, reason, "stop_sequence")) return .stop;
    return .other;
}

fn parseUsage(root: std.json.Value) types.Usage {
    var usage = types.Usage{};
    const u = root.object.get("usage") orelse return usage;
    if (u != .object) return usage;
    if (u.object.get("input_tokens")) |v| {
        if (v == .integer) usage.input_tokens = @intCast(v.integer);
    }
    if (u.object.get("output_tokens")) |v| {
        if (v == .integer) usage.output_tokens = @intCast(v.integer);
    }
    if (u.object.get("cache_read_input_tokens")) |v| {
        if (v == .integer) usage.cache_read_tokens = @intCast(v.integer);
    }
    if (u.object.get("cache_creation_input_tokens")) |v| {
        if (v == .integer) usage.cache_write_tokens = @intCast(v.integer);
    }
    usage.total_tokens = usage.input_tokens + usage.cache_read_tokens + usage.cache_write_tokens + usage.output_tokens;
    return usage;
}

fn parseStream(a: std.mem.Allocator, sse_text: []const u8, sctx: *model.StreamContext) !*model.GenerateResult {
    const result = try a.create(model.GenerateResult);
    errdefer {
        result.deinit(a);
        a.destroy(result);
    }
    result.* = .{};

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(a);
    var reasoning: std.ArrayList(u8) = .empty;
    errdefer reasoning.deinit(a);
    var reasoning_signature: []const u8 = "";
    errdefer a.free(reasoning_signature);
    var calls: std.ArrayList(types.ToolCall) = .empty;
    errdefer {
        for (calls.items) |tc| {
            a.free(tc.id);
            a.free(tc.name);
            a.free(tc.input);
        }
        calls.deinit(a);
    }

    var it = std.mem.splitScalar(u8, sse_text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const data = std.mem.trim(u8, line["data:".len..], " ");
        if (data.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch continue;
        defer parsed.deinit();
        const event = parsed.value;
        if (event != .object) continue;

        const etype = event.object.get("type") orelse continue;
        if (etype != .string) continue;

        if (std.mem.eql(u8, etype.string, "content_block_start")) {
            const block = event.object.get("content_block") orelse continue;
            if (block == .object) {
                const btype = block.object.get("type") orelse continue;
                if (btype == .string and std.mem.eql(u8, btype.string, "tool_use")) {
                    var id: []const u8 = "";
                    var name: []const u8 = "";
                    if (block.object.get("id")) |v| {
                        if (v == .string) id = v.string;
                    }
                    if (block.object.get("name")) |v| {
                        if (v == .string) name = v.string;
                    }
                    var input: []const u8 = "";
                    if (block.object.get("input")) |value| {
                        if (value == .object and value.object.count() > 0) input = try std.json.Stringify.valueAlloc(a, value, .{});
                    }
                    try calls.append(a, .{ .id = try a.dupe(u8, id), .name = try a.dupe(u8, name), .input = input });
                    sctx.send(.{ .type = .tool_call_streaming_start, .tool_call_id = id });
                }
            }
        } else if (std.mem.eql(u8, etype.string, "content_block_delta")) {
            const delta = event.object.get("delta") orelse continue;
            if (delta != .object) continue;
            const dtype = delta.object.get("type") orelse continue;
            if (dtype != .string) continue;
            if (std.mem.eql(u8, dtype.string, "text_delta")) {
                if (delta.object.get("text")) |t| {
                    if (t == .string and t.string.len > 0) {
                        try text.appendSlice(a, t.string);
                        sctx.send(.{ .type = .text, .text = t.string });
                    }
                }
            } else if (std.mem.eql(u8, dtype.string, "thinking_delta")) {
                if (delta.object.get("thinking")) |t| {
                    if (t == .string and t.string.len > 0) {
                        try reasoning.appendSlice(a, t.string);
                        sctx.send(.{ .type = .reasoning, .text = t.string });
                    }
                }
            } else if (std.mem.eql(u8, dtype.string, "signature_delta")) {
                if (delta.object.get("signature")) |signature| {
                    if (signature == .string) {
                        const old = reasoning_signature;
                        reasoning_signature = try std.mem.concat(a, u8, &.{ old, signature.string });
                        a.free(old);
                    }
                }
            } else if (std.mem.eql(u8, dtype.string, "input_json_delta")) {
                if (delta.object.get("partial_json")) |t| {
                    if (t == .string and t.string.len > 0 and calls.items.len > 0) {
                        const last = &calls.items[calls.items.len - 1];
                        const old = last.input;
                        last.input = try std.mem.concat(a, u8, &.{ old, t.string });
                        if (old.len > 0) a.free(old);
                        sctx.send(.{ .type = .tool_call_delta, .text = t.string });
                    }
                }
            }
        } else if (std.mem.eql(u8, etype.string, "message_delta")) {
            const delta = event.object.get("delta") orelse continue;
            if (delta == .object) {
                if (delta.object.get("stop_reason")) |sr| {
                    if (sr == .string) result.finish_reason = mapFinish(sr.string);
                }
            }
            if (event.object.get("usage")) |u| {
                if (u == .object) result.usage = parseUsage(event);
            }
        } else if (std.mem.eql(u8, etype.string, "message_start")) {
            const message = event.object.get("message") orelse continue;
            if (message == .object) {
                if (message.object.get("id")) |v| {
                    if (v == .string) result.response.id = try a.dupe(u8, v.string);
                }
                if (message.object.get("model")) |v| {
                    if (v == .string) result.response.model = try a.dupe(u8, v.string);
                }
                if (message.object.get("usage")) |_| {
                    result.usage = parseUsage(message);
                }
            }
        }
    }

    result.text = try text.toOwnedSlice(a);
    result.reasoning = try reasoning.toOwnedSlice(a);
    result.reasoning_signature = reasoning_signature;
    reasoning_signature = "";
    for (calls.items) |tc| {
        sctx.send(.{ .type = .tool_call, .tool_call_id = tc.id, .tool_name = tc.name, .tool_input = tc.input });
    }
    result.tool_calls = try calls.toOwnedSlice(a);
    return result;
}

test "tool continuation and structured output request" {
    const messages = [_]types.Message{
        .{ .role = .assistant, .content = &.{types.Part.toolCallPart("toolu_1", "weather", "{\"city\":\"Paris\"}")} },
        types.ToolMessage("toolu_1", "weather", "sunny"),
    };
    const body = try buildRequest(std.testing.allocator, "claude-test", .{
        .messages = &messages,
        .response_format = .{ .name = "answer", .schema = "{\"type\":\"object\"}" },
    }, false);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"tool_use\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"tool_result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"output_config\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":false") != null);
}

test "request filters malformed calls and preserves cache control" {
    const messages = [_]types.Message{
        .{ .role = .assistant, .content = &.{
            types.Part.toolCallPart("toolu_bad", "grep", "{\"pattern\":\"foo\""),
            types.Part.toolCallPart("toolu_ok", "read", "{\"path\":\"src/main.zig\"}"),
        } },
        .{ .role = .tool, .content = &.{
            types.Part.toolResultPart("toolu_bad", "grep", "bad"),
            types.Part.toolResultPart("toolu_ok", "read", "contents"),
        } },
    };
    const tools = [_]types.Tool{.{ .name = "read", .input_schema = "{\"type\":\"object\"}" }};
    const body = try buildRequest(std.testing.allocator, "claude-test", .{
        .messages = &messages,
        .tools = &tools,
        .system = "system",
        .prompt_caching = true,
    }, false);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "toolu_ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "toolu_bad") == null);
    var count: usize = 0;
    var rest = body;
    while (std.mem.indexOf(u8, rest, "cache_control")) |index| {
        count += 1;
        rest = rest[index + "cache_control".len ..];
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "thinking signatures survive blocking and streaming responses" {
    const blocking = try parseResponse(std.testing.allocator,
        \\{"content":[{"type":"thinking","thinking":"plan","signature":"sig"}],"stop_reason":"end_turn"}
    );
    defer {
        blocking.deinit(std.testing.allocator);
        std.testing.allocator.destroy(blocking);
    }
    try std.testing.expectEqualStrings("plan", blocking.reasoning);
    try std.testing.expectEqualStrings("sig", blocking.reasoning_signature);

    const streamed =
        \\data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"plan"}}
        \\data: {"type":"content_block_delta","delta":{"type":"signature_delta","signature":"sig"}}
    ;
    var stream = model.StreamContext{ .emit = discardChunk };
    const result = try parseStream(std.testing.allocator, streamed, &stream);
    defer {
        result.deinit(std.testing.allocator);
        std.testing.allocator.destroy(result);
    }
    try std.testing.expectEqualStrings("plan", result.reasoning);
    try std.testing.expectEqualStrings("sig", result.reasoning_signature);
}

test "stream seeds tool input from content block start" {
    const body =
        \\data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"read","input":{"file_path":"src/main.zig"}}}
    ;
    var stream = model.StreamContext{ .emit = discardChunk };
    const result = try parseStream(std.testing.allocator, body, &stream);
    defer {
        result.deinit(std.testing.allocator);
        std.testing.allocator.destroy(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try std.testing.expectEqualStrings("{\"file_path\":\"src/main.zig\"}", result.tool_calls[0].input);
}

fn discardChunk(_: ?*anyopaque, _: types.StreamChunk) void {}
