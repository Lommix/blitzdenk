const std = @import("std");
const model = @import("../model.zig");
const types = @import("../types.zig");
const auth = @import("../auth.zig");
const jsonx = @import("jsonx.zig");

pub const default_base_url = "https://api.openai.com/v1";
pub const api_key_env = "OPENAI_API_KEY";

pub const Options = struct {
    api_key: ?[]const u8 = null,
    base_url: []const u8 = default_base_url,
    headers: []const std.http.Header = &.{},
    env: auth.Env = .{},
};

pub const Chat = struct {
    model_id: []const u8,
    api_key: []const u8,
    base_url: []const u8,
    extra_headers: []const std.http.Header,

    pub fn init(alloc: std.mem.Allocator, model_id: []const u8, opts: Options) !Chat {
        const key = opts.api_key orelse auth.resolveKey(opts.env, api_key_env) orelse "";
        return .{
            .model_id = try alloc.dupe(u8, model_id),
            .api_key = try alloc.dupe(u8, key),
            .base_url = try alloc.dupe(u8, opts.base_url),
            .extra_headers = try auth.cloneHeaders(alloc, opts.headers),
        };
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
            try headers.append(a, try auth.bearerHeader(a, self.api_key));
        }
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

        const body = try buildRequest(alloc, self, params, false);
        defer alloc.free(body);
        const headers = try self.authHeaders(alloc, params.headers);
        defer auth.freeHeaders(alloc, headers);
        const url = try std.fmt.allocPrint(alloc, "{s}/responses", .{self.base_url});
        defer alloc.free(url);
        const response = try jsonx.postWithRetry(alloc, io, client, url, body, headers, max_retries, params.timeout_ms);
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
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const stream_alloc = arena.allocator();

        const body = try buildRequest(stream_alloc, self, params, true);
        const headers = try self.authHeaders(stream_alloc, params.headers);
        const url = try std.fmt.allocPrint(stream_alloc, "{s}/responses", .{self.base_url});
        var live = LiveStream{ .alloc = stream_alloc, .sctx = sctx };
        const sse_text = try jsonx.postSseWithRetry(stream_alloc, io, client, url, body, headers, max_retries, params.timeout_ms, &live, emitLiveEvent);
        var final_ctx = model.StreamContext{ .emit = emitFinalTool, .emit_ctx = sctx };
        return parseStream(alloc, sse_text, &final_ctx);
    }
};

const LiveStream = struct {
    alloc: std.mem.Allocator,
    sctx: *model.StreamContext,
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
    const event = try std.fmt.allocPrint(live.alloc, "data: {s}\n", .{data});
    var event_ctx = model.StreamContext{ .emit = emitLive, .emit_ctx = live.sctx };
    _ = try parseStream(live.alloc, event, &event_ctx);
}

fn buildRequest(
    a: std.mem.Allocator,
    chat: *Chat,
    params: model.GenerateParams,
    stream: bool,
) ![]const u8 {
    var w = std.Io.Writer.Allocating.init(a);
    defer w.deinit();
    var s: std.json.Stringify = .{ .writer = &w.writer };

    try s.beginObject();
    try s.objectField("model");
    try s.write(chat.model_id);

    if (params.system.len > 0) {
        try s.objectField("instructions");
        try s.write(params.system);
    }

    try s.objectField("input");
    try s.beginArray();
    for (params.messages) |msg| {
        if (msg.role == .system) continue;
        if (msg.role == .tool) {
            for (msg.parts()) |part| {
                const result = switch (part) {
                    .tool_result => |result| result,
                    else => continue,
                };
                try s.beginObject();
                try s.objectField("type");
                try s.write("function_call_output");
                try s.objectField("call_id");
                try s.write(result.id);
                try s.objectField("output");
                try s.write(result.output);
                try s.endObject();
            }
            continue;
        }
        if (msg.text().len > 0) {
            try s.beginObject();
            try s.objectField("role");
            try s.write(msg.role.string());
            try s.objectField("content");
            try s.write(msg.text());
            try s.endObject();
        }
        if (msg.role == .assistant) {
            for (msg.parts()) |part| {
                const call = switch (part) {
                    .tool_call => |call| call,
                    else => continue,
                };
                try s.beginObject();
                try s.objectField("type");
                try s.write("function_call");
                try s.objectField("call_id");
                try s.write(call.id);
                try s.objectField("name");
                try s.write(call.name);
                try s.objectField("arguments");
                try s.write(call.input);
                try s.endObject();
            }
        }
    }
    try s.endArray();

    if (params.tools.len > 0) {
        try s.objectField("tools");
        try s.beginArray();
        for (params.tools) |tool| {
            try s.beginObject();
            try s.objectField("type");
            try s.write("function");
            try s.objectField("name");
            try s.write(tool.name);
            try s.objectField("description");
            try s.write(tool.description);
            try s.objectField("parameters");
            try jsonx.writeRaw(&s, tool.input_schema);
            try s.endObject();
        }
        try s.endArray();
    }

    if (params.max_output_tokens > 0) {
        try s.objectField("max_output_tokens");
        try s.write(params.max_output_tokens);
    }
    if (params.temperature) |t| {
        try s.objectField("temperature");
        try s.write(t);
    }
    if (params.top_p) |t| {
        try s.objectField("top_p");
        try s.write(t);
    }
    switch (params.tool_choice) {
        .auto => {},
        .none => {
            try s.objectField("tool_choice");
            try s.write("none");
        },
        .required => {
            try s.objectField("tool_choice");
            try s.write("required");
        },
        .tool => |name| {
            try s.objectField("tool_choice");
            try s.beginObject();
            try s.objectField("type");
            try s.write("function");
            try s.objectField("name");
            try s.write(name);
            try s.endObject();
        },
    }
    if (params.response_format) |format| {
        try s.objectField("text");
        try s.beginObject();
        try s.objectField("format");
        try s.beginObject();
        try s.objectField("type");
        try s.write("json_schema");
        try s.objectField("name");
        try s.write(format.name);
        try s.objectField("strict");
        try s.write(true);
        try s.objectField("schema");
        try jsonx.writeRaw(&s, format.schema);
        try s.endObject();
        try s.endObject();
    }
    if (params.prompt_caching) {
        if (params.cache_ttl) |value| {
            try s.objectField("prompt_cache_retention");
            try s.write(value);
        }
    }
    try jsonx.writeProviderOptions(&s, params.provider_options);
    if (stream) {
        try s.objectField("stream");
        try s.write(true);
    }
    try s.endObject();
    return w.toOwnedSlice();
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

    if (root.object.get("output")) |output| {
        if (output == .array) {
            for (output.array.items) |item| {
                if (item != .object) continue;
                const itype = item.object.get("type") orelse continue;
                if (itype != .string) continue;
                if (std.mem.eql(u8, itype.string, "message")) {
                    if (item.object.get("content")) |content| {
                        if (content == .array) {
                            for (content.array.items) |c| {
                                if (c != .object) continue;
                                const ctype = c.object.get("type") orelse continue;
                                if (ctype == .string and std.mem.eql(u8, ctype.string, "output_text")) {
                                    if (c.object.get("text")) |t| {
                                        if (t == .string) try text.appendSlice(a, t.string);
                                    }
                                }
                            }
                        }
                    }
                } else if (std.mem.eql(u8, itype.string, "reasoning")) {
                    if (item.object.get("summary")) |summary| {
                        if (summary == .array) {
                            for (summary.array.items) |sv| {
                                if (sv == .object) {
                                    if (sv.object.get("text")) |t| {
                                        if (t == .string) try reasoning.appendSlice(a, t.string);
                                    }
                                }
                            }
                        }
                    }
                } else if (std.mem.eql(u8, itype.string, "function_call")) {
                    var id: []const u8 = "";
                    var name: []const u8 = "";
                    var input: []const u8 = "";
                    if (item.object.get("call_id")) |v| {
                        if (v == .string) id = v.string;
                    }
                    if (item.object.get("name")) |v| {
                        if (v == .string) name = v.string;
                    }
                    if (item.object.get("arguments")) |v| {
                        if (v == .string) input = v.string;
                    }
                    try calls.append(a, .{
                        .id = try a.dupe(u8, id),
                        .name = try a.dupe(u8, name),
                        .input = try a.dupe(u8, input),
                    });
                }
            }
        }
    }
    result.text = try text.toOwnedSlice(a);
    result.reasoning = try reasoning.toOwnedSlice(a);
    result.tool_calls = try calls.toOwnedSlice(a);

    if (root.object.get("id")) |v| {
        if (v == .string) result.response.id = try a.dupe(u8, v.string);
    }
    if (root.object.get("model")) |v| {
        if (v == .string) result.response.model = try a.dupe(u8, v.string);
    }
    if (root.object.get("usage")) |_| {
        result.usage = parseUsage(root);
    }
    if (root.object.get("status")) |v| {
        if (v == .string) {
            if (std.mem.eql(u8, v.string, "incomplete")) result.finish_reason = .length;
            if (std.mem.eql(u8, v.string, "completed")) result.finish_reason = if (calls.items.len > 0) .tool_calls else .stop;
        }
    }
    return result;
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
    if (u.object.get("output_tokens_details")) |d| {
        if (d == .object) {
            if (d.object.get("reasoning_tokens")) |v| {
                if (v == .integer) usage.reasoning_tokens = @intCast(v.integer);
            }
        }
    }
    if (u.object.get("input_tokens_details")) |d| {
        if (d == .object) {
            if (d.object.get("cached_tokens")) |v| {
                if (v == .integer) usage.cache_read_tokens = @intCast(v.integer);
            }
        }
    }
    usage.total_tokens = usage.input_tokens + usage.output_tokens;
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

        if (std.mem.eql(u8, etype.string, "response.output_text.delta")) {
            if (event.object.get("delta")) |d| {
                if (d == .string and d.string.len > 0) {
                    try text.appendSlice(a, d.string);
                    sctx.send(.{ .type = .text, .text = d.string });
                }
            }
        } else if (std.mem.eql(u8, etype.string, "response.output_item.done")) {
            const item = event.object.get("item") orelse continue;
            if (item == .object) {
                const itype = item.object.get("type") orelse continue;
                if (itype == .string and std.mem.eql(u8, itype.string, "function_call")) {
                    var id: []const u8 = "";
                    var name: []const u8 = "";
                    var input: []const u8 = "";
                    if (item.object.get("call_id")) |v| {
                        if (v == .string) id = v.string;
                    }
                    if (item.object.get("name")) |v| {
                        if (v == .string) name = v.string;
                    }
                    if (item.object.get("arguments")) |v| {
                        if (v == .string) input = v.string;
                    }
                    try calls.append(a, .{
                        .id = try a.dupe(u8, id),
                        .name = try a.dupe(u8, name),
                        .input = try a.dupe(u8, input),
                    });
                }
            }
        } else if (std.mem.eql(u8, etype.string, "response.completed")) {
            const response = event.object.get("response") orelse continue;
            if (response == .object) {
                result.usage = parseUsage(response);
                if (response.object.get("status")) |v| {
                    if (v == .string) {
                        if (std.mem.eql(u8, v.string, "incomplete")) result.finish_reason = .length;
                        if (std.mem.eql(u8, v.string, "completed")) {
                            result.finish_reason = if (calls.items.len > 0) .tool_calls else .stop;
                        }
                    }
                }
            }
        }
    }

    result.text = try text.toOwnedSlice(a);
    for (calls.items) |tc| {
        sctx.send(.{ .type = .tool_call, .tool_call_id = tc.id, .tool_name = tc.name, .tool_input = tc.input });
    }
    result.tool_calls = try calls.toOwnedSlice(a);
    return result;
}

test "function continuation and structured output request" {
    var chat = Chat{
        .model_id = "gpt-test",
        .api_key = "",
        .base_url = "",
        .extra_headers = &.{},
    };
    const messages = [_]types.Message{
        .{ .role = .assistant, .content = &.{types.Part.toolCallPart("call_1", "weather", "{\"city\":\"Paris\"}")} },
        types.ToolMessage("call_1", "weather", "sunny"),
    };
    const body = try buildRequest(std.testing.allocator, &chat, .{
        .messages = &messages,
        .response_format = .{ .name = "answer", .schema = "{\"type\":\"object\"}" },
    }, false);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"function_call\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"function_call_output\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"format\":{\"type\":\"json_schema\"") != null);
}
