const std = @import("std");
const types = @import("../types.zig");
const model = @import("../model.zig");
const auth = @import("../auth.zig");
const errors = @import("../errors.zig");
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
        .embed = embedFn,
        .image = imageFn,
    };

    fn modelId(ctx: *anyopaque) []const u8 {
        const self: *Chat = @ptrCast(@alignCast(ctx));
        return self.model_id;
    }

    fn authHeaders(self: *Chat, alloc: std.mem.Allocator, request_headers: []const std.http.Header) ![]std.http.Header {
        var headers: std.ArrayList(std.http.Header) = .empty;
        defer headers.deinit(alloc);
        if (self.api_key.len > 0) {
            try headers.append(alloc, try auth.bearerHeader(alloc, self.api_key));
        }
        try auth.appendHeaders(alloc, &headers, self.extra_headers);
        try auth.appendHeaders(alloc, &headers, request_headers);
        return auth.ownHeaders(alloc, headers.items);
    }

    pub fn generate(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        io: std.Io,
        params: model.GenerateParams,
        client: ?*std.http.Client,
        max_retries: u32,
    ) anyerror!*model.GenerateResult {
        const self: *Chat = @ptrCast(@alignCast(ctx));

        const body = try jsonx.buildChatRequest(alloc, self.model_id, params, false);
        defer alloc.free(body);
        const headers = try self.authHeaders(alloc, params.headers);
        defer auth.freeHeaders(alloc, headers);
        const url = try std.fmt.allocPrint(alloc, "{s}/chat/completions", .{self.base_url});
        defer alloc.free(url);

        const response = try jsonx.postWithRetry(alloc, io, client, url, body, headers, max_retries, params.timeout_ms);
        defer alloc.free(response);
        return parseChatResponse(alloc, response);
    }

    pub fn stream(
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

        const body = try jsonx.buildChatRequest(stream_alloc, self.model_id, params, true);
        const headers = try self.authHeaders(stream_alloc, params.headers);
        const url = try std.fmt.allocPrint(stream_alloc, "{s}/chat/completions", .{self.base_url});

        var live = LiveStream{ .alloc = stream_alloc, .sctx = sctx };
        const sse_text = try jsonx.postSseWithRetry(stream_alloc, io, client, url, body, headers, max_retries, params.timeout_ms, &live, emitLiveEvent);
        var final_ctx = model.StreamContext{ .emit = emitFinalTool, .emit_ctx = sctx };
        return parseChatStream(alloc, sse_text, &final_ctx);
    }

    pub fn embedFn(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        io: std.Io,
        params: model.EmbedParams,
        client: ?*std.http.Client,
        max_retries: u32,
    ) anyerror!*types.EmbedResult {
        const self: *Chat = @ptrCast(@alignCast(ctx));

        var w = std.Io.Writer.Allocating.init(alloc);
        defer w.deinit();
        var s: std.json.Stringify = .{ .writer = &w.writer };
        try s.beginObject();
        try s.objectField("model");
        try s.write(self.model_id);
        try s.objectField("input");
        try s.beginArray();
        for (params.values) |v| try s.write(v);
        try s.endArray();
        try jsonx.writeProviderOptions(&s, params.provider_options);
        try s.endObject();

        const headers = try self.authHeaders(alloc, params.headers);
        defer auth.freeHeaders(alloc, headers);
        const url = try std.fmt.allocPrint(alloc, "{s}/embeddings", .{self.base_url});
        defer alloc.free(url);
        const response = try jsonx.postWithRetry(alloc, io, client, url, w.written(), headers, max_retries, params.timeout_ms);
        defer alloc.free(response);
        return parseEmbedResponse(alloc, response);
    }

    pub fn imageFn(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        io: std.Io,
        params: model.ImageParams,
        client: ?*std.http.Client,
        max_retries: u32,
    ) anyerror!*types.ImageResult {
        const self: *Chat = @ptrCast(@alignCast(ctx));

        var w = std.Io.Writer.Allocating.init(alloc);
        defer w.deinit();
        var s: std.json.Stringify = .{ .writer = &w.writer };
        try s.beginObject();
        try s.objectField("model");
        try s.write(self.model_id);
        try s.objectField("prompt");
        try s.write(params.prompt);
        try s.objectField("n");
        try s.write(params.n);
        const size = if (params.size.len > 0) params.size else aspectRatioSize(params.aspect_ratio);
        if (size.len > 0) {
            try s.objectField("size");
            try s.write(size);
        }
        try jsonx.writeProviderOptions(&s, params.provider_options);
        try s.endObject();

        const headers = try self.authHeaders(alloc, params.headers);
        const url = try std.fmt.allocPrint(alloc, "{s}/images/generations", .{self.base_url});
        const response = try jsonx.postWithRetry(alloc, io, client, url, w.written(), headers, max_retries, params.timeout_ms);
        return parseImageResponse(alloc, response);
    }
};

fn aspectRatioSize(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "1:1")) return "1024x1024";
    if (std.mem.eql(u8, value, "2:3")) return "1024x1536";
    if (std.mem.eql(u8, value, "3:2")) return "1536x1024";
    return "";
}

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
    _ = try parseChatStream(live.alloc, event, &event_ctx);
}

pub fn parseChatResponse(a: std.mem.Allocator, body: []const u8) !*model.GenerateResult {
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

    if (root.object.get("choices")) |choices| {
        if (choices == .array and choices.array.items.len > 0) {
            const choice = choices.array.items[0];
            if (choice == .object) {
                if (choice.object.get("message")) |msg| {
                    if (msg == .object) {
                        if (msg.object.get("content")) |c| {
                            if (c == .string) result.text = try a.dupe(u8, c.string);
                        }
                        if (msg.object.get("reasoning_content")) |c| {
                            if (c == .string) result.reasoning = try a.dupe(u8, c.string);
                        }
                        if (msg.object.get("tool_calls")) |tcs| {
                            if (tcs == .array) {
                                var calls: std.ArrayList(types.ToolCall) = .empty;
                                for (tcs.array.items) |tc| {
                                    if (tc != .object) continue;
                                    var id: []const u8 = "";
                                    var name: []const u8 = "";
                                    var input: []const u8 = "";
                                    if (tc.object.get("id")) |v| {
                                        if (v == .string) id = v.string;
                                    }
                                    if (tc.object.get("function")) |f| {
                                        if (f == .object) {
                                            if (f.object.get("name")) |v| {
                                                if (v == .string) name = v.string;
                                            }
                                            if (f.object.get("arguments")) |v| {
                                                if (v == .string) input = v.string;
                                            }
                                        }
                                    }
                                    try calls.append(a, .{
                                        .id = try a.dupe(u8, id),
                                        .name = try a.dupe(u8, name),
                                        .input = try a.dupe(u8, input),
                                    });
                                }
                                result.tool_calls = try calls.toOwnedSlice(a);
                            }
                        }
                    }
                }
                if (choice.object.get("finish_reason")) |fr| {
                    if (fr == .string) result.finish_reason = mapFinish(fr.string);
                }
            }
        }
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

pub fn mapFinish(reason: []const u8) types.FinishReason {
    if (std.mem.eql(u8, reason, "stop")) return .stop;
    if (std.mem.eql(u8, reason, "tool_calls") or std.mem.eql(u8, reason, "function_call")) return .tool_calls;
    if (std.mem.eql(u8, reason, "length")) return .length;
    if (std.mem.eql(u8, reason, "content_filter")) return .content_filter;
    return .other;
}

pub fn parseUsage(root: std.json.Value) types.Usage {
    var usage = types.Usage{};
    const u = root.object.get("usage") orelse return usage;
    if (u != .object) return usage;
    if (u.object.get("prompt_tokens")) |v| {
        if (v == .integer) usage.input_tokens = @intCast(v.integer);
    }
    if (u.object.get("completion_tokens")) |v| {
        if (v == .integer) usage.output_tokens = @intCast(v.integer);
    }
    if (u.object.get("total_tokens")) |v| {
        if (v == .integer) usage.total_tokens = @intCast(v.integer);
    }
    if (u.object.get("prompt_tokens_details")) |d| {
        if (d == .object) {
            if (d.object.get("cached_tokens")) |v| {
                if (v == .integer) usage.cache_read_tokens = @intCast(v.integer);
            }
        }
    }
    return usage;
}

pub fn parseChatStream(a: std.mem.Allocator, sse_text: []const u8, sctx: *model.StreamContext) !*model.GenerateResult {
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

    var it = std.mem.splitSequence(u8, sse_text, "\n");
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const data = std.mem.trim(u8, line["data:".len..], " ");
        if (std.mem.eql(u8, data, "[DONE]")) break;
        if (data.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch continue;
        defer parsed.deinit();
        const chunk = parsed.value;
        if (chunk != .object) continue;

        if (chunk.object.get("usage")) |u| {
            if (u == .object) {
                result.usage = parseUsage(chunk);
                if (u.object.get("completion_tokens_details")) |d| {
                    if (d == .object) {
                        if (d.object.get("reasoning_tokens")) |v| {
                            if (v == .integer) result.usage.reasoning_tokens = @intCast(v.integer);
                        }
                    }
                }
            }
        }

        const choices = chunk.object.get("choices") orelse continue;
        if (choices != .array or choices.array.items.len == 0) continue;
        const choice = choices.array.items[0];
        if (choice != .object) continue;

        if (choice.object.get("finish_reason")) |fr| {
            if (fr == .string) result.finish_reason = mapFinish(fr.string);
        }
        const delta = choice.object.get("delta") orelse continue;
        if (delta != .object) continue;

        if (delta.object.get("content")) |c| {
            if (c == .string and c.string.len > 0) {
                try text.appendSlice(a, c.string);
                sctx.send(.{ .type = .text, .text = c.string });
            }
        }
        if (delta.object.get("reasoning_content")) |c| {
            if (c == .string and c.string.len > 0) {
                try reasoning.appendSlice(a, c.string);
                sctx.send(.{ .type = .reasoning, .text = c.string });
            }
        }
        if (delta.object.get("tool_calls")) |tcs| {
            if (tcs == .array) {
                for (tcs.array.items) |tc| {
                    if (tc != .object) continue;
                    const index: usize = blk: {
                        const v = tc.object.get("index") orelse break :blk 0;
                        break :blk if (v == .integer) @intCast(v.integer) else 0;
                    };
                    var fn_obj: ?std.json.Value = null;
                    if (tc.object.get("function")) |f| {
                        if (f == .object) fn_obj = f;
                    }
                    while (calls.items.len <= index) {
                        try calls.append(a, .{ .id = "", .name = "", .input = "" });
                    }
                    if (tc.object.get("id")) |v| {
                        if (v == .string and v.string.len > 0 and calls.items[index].id.len == 0) {
                            calls.items[index].id = try a.dupe(u8, v.string);
                            sctx.send(.{
                                .type = .tool_call_streaming_start,
                                .tool_call_id = calls.items[index].id,
                            });
                        }
                    }
                    if (fn_obj) |f| {
                        if (f.object.get("name")) |v| {
                            if (v == .string and v.string.len > 0 and calls.items[index].name.len == 0) {
                                calls.items[index].name = try a.dupe(u8, v.string);
                            }
                        }
                        if (f.object.get("arguments")) |v| {
                            if (v == .string and v.string.len > 0) {
                                const old = calls.items[index].input;
                                calls.items[index].input = try std.mem.concat(a, u8, &.{ old, v.string });
                                if (old.len > 0) a.free(old);
                                sctx.send(.{ .type = .tool_call_delta, .text = v.string });
                            }
                        }
                    }
                }
            }
        }
    }

    result.text = try text.toOwnedSlice(a);
    result.reasoning = try reasoning.toOwnedSlice(a);
    for (calls.items) |tc| {
        if (tc.id.len > 0) {
            sctx.send(.{ .type = .tool_call, .tool_call_id = tc.id, .tool_name = tc.name, .tool_input = tc.input });
        }
    }
    result.tool_calls = try calls.toOwnedSlice(a);
    return result;
}

pub fn parseEmbedResponse(a: std.mem.Allocator, body: []const u8) !*types.EmbedResult {
    var parsed = std.json.parseFromSlice(std.json.Value, a, body, .{}) catch return error.InvalidResponse;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;

    const result = try a.create(types.EmbedResult);
    result.* = .{};

    var list: std.ArrayList([]const f64) = .empty;
    if (root.object.get("data")) |data| {
        if (data == .array) {
            for (data.array.items) |item| {
                if (item != .object) continue;
                const emb = item.object.get("embedding") orelse continue;
                if (emb != .array) continue;
                const vec = try a.alloc(f64, emb.array.items.len);
                for (emb.array.items, 0..) |v, i| {
                    vec[i] = if (v == .float) v.float else 0;
                }
                try list.append(a, vec);
            }
        }
    }
    result.embeddings = try list.toOwnedSlice(a);
    result.usage = parseUsage(root);
    return result;
}

pub fn parseImageResponse(a: std.mem.Allocator, body: []const u8) !*types.ImageResult {
    var parsed = std.json.parseFromSlice(std.json.Value, a, body, .{}) catch return error.InvalidResponse;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;

    const result = try a.create(types.ImageResult);
    errdefer {
        result.deinit(a);
        a.destroy(result);
    }
    result.* = .{};

    var list: std.ArrayList(types.ImageData) = .empty;
    errdefer {
        for (list.items) |img| {
            a.free(img.data);
            a.free(img.media_type);
        }
        list.deinit(a);
    }
    if (root.object.get("data")) |data| {
        if (data == .array) {
            for (data.array.items) |item| {
                if (item != .object) continue;
                const b64 = item.object.get("b64_json") orelse continue;
                if (b64 != .string) continue;
                const media = try a.dupe(u8, "image/png");
                errdefer a.free(media);
                const decoder = std.base64.standard.Decoder;
                const size = try decoder.calcSizeForSlice(b64.string);
                const buf = try a.alloc(u8, size);
                errdefer a.free(buf);
                try decoder.decode(buf, b64.string);
                try list.append(a, .{ .data = buf, .media_type = media });
            }
        }
    }
    result.images = try list.toOwnedSlice(a);
    return result;
}
