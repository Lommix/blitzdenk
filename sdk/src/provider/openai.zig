const std = @import("std");
const types = @import("../types.zig");
const model = @import("../model.zig");
const auth = @import("../auth.zig");
const errors = @import("../errors.zig");
const jsonx = @import("jsonx.zig");
const log = std.log.scoped(.openai_provider);

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

        const response = try jsonx.postWithRetry(alloc, io, client, url, body, headers, max_retries, requestOptions(params));
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
        const body = try jsonx.buildChatRequest(alloc, self.model_id, params, true);
        const headers = try self.authHeaders(alloc, params.headers);
        const url = try std.fmt.allocPrint(alloc, "{s}/chat/completions", .{self.base_url});

        const request_options = requestOptions(params);
        var live = LiveStream{ .alloc = alloc, .sctx = sctx, .options = request_options };
        const sse_text = try jsonx.postSseWithRetry(alloc, io, client, url, body, headers, max_retries, request_options, &live, emitLiveEvent);
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
        const response = try jsonx.postWithRetry(alloc, io, client, url, w.written(), headers, max_retries, .{ .timeout_ms = params.timeout_ms, .cancellation = params.cancellation });
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
        const response = try jsonx.postWithRetry(alloc, io, client, url, w.written(), headers, max_retries, .{ .timeout_ms = params.timeout_ms, .cancellation = params.cancellation });
        return parseImageResponse(alloc, response);
    }
};

fn requestOptions(params: model.GenerateParams) jsonx.RequestOptions {
    return .{
        .timeout_ms = params.timeout_ms,
        .cancellation = params.cancellation,
        .on_provider_error = params.on_provider_error,
        .on_provider_error_ctx = params.on_provider_error_ctx,
    };
}

fn aspectRatioSize(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "1:1")) return "1024x1024";
    if (std.mem.eql(u8, value, "2:3")) return "1024x1536";
    if (std.mem.eql(u8, value, "3:2")) return "1536x1024";
    return "";
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
                        if (result.reasoning.len == 0) {
                            if (msg.object.get("reasoning")) |c| {
                                if (c == .string) result.reasoning = try a.dupe(u8, c.string);
                            }
                        }
                        if (msg.object.get("reasoning_details")) |details| {
                            if (details == .array) result.reasoning_signature = try std.json.Stringify.valueAlloc(a, details, .{});
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
                                    if (!isValidToolCall(a, id, name, input)) {
                                        jsonx.logDroppedToolCall(log, id, name, input);
                                        continue;
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
    usage.input_tokens -|= usage.cache_read_tokens;
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
    var reasoning_details: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (reasoning_details.items) |detail| a.free(detail);
        reasoning_details.deinit(a);
    }
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
        if (choice.object.get("message")) |message| {
            if (message == .object) {
                if (message.object.get("tool_calls")) |tool_calls| {
                    if (tool_calls == .array) try applyCompleteToolCalls(a, &calls, tool_calls.array.items);
                }
            }
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
        if (delta.object.get("reasoning_details")) |details| {
            if (details == .array) {
                for (details.array.items) |detail| {
                    try reasoning_details.append(a, try std.json.Stringify.valueAlloc(a, detail, .{}));
                }
            }
        }
        if (delta.object.get("tool_calls")) |tcs| {
            if (tcs == .array) {
                for (tcs.array.items) |tc| {
                    if (tc != .object) continue;
                    const index: usize = blk: {
                        const v = tc.object.get("index") orelse break :blk if (calls.items.len == 0) 0 else calls.items.len - 1;
                        break :blk if (v == .integer) @intCast(v.integer) else if (calls.items.len == 0) 0 else calls.items.len - 1;
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
                                calls.items[index].input = if (isJsonObject(a, old) and isJsonObject(a, v.string))
                                    try a.dupe(u8, v.string)
                                else
                                    try std.mem.concat(a, u8, &.{ old, v.string });
                                if (old.len > 0) a.free(old);
                                sctx.send(.{ .type = .tool_call_delta, .text = v.string });
                            }
                        }
                    }
                }
            }
        }
    }

    try normalizeTaggedReasoning(a, &text, &reasoning);
    result.text = try text.toOwnedSlice(a);
    result.reasoning = try reasoning.toOwnedSlice(a);
    if (reasoning_details.items.len > 0) result.reasoning_signature = try encodeJsonArray(a, reasoning_details.items);
    for (reasoning_details.items) |detail| a.free(detail);
    reasoning_details.deinit(a);
    reasoning_details = .empty;
    var valid_calls: std.ArrayList(types.ToolCall) = .empty;
    errdefer valid_calls.deinit(a);
    for (calls.items) |tc| {
        if (isValidToolCall(a, tc.id, tc.name, tc.input)) {
            sctx.send(.{ .type = .tool_call, .tool_call_id = tc.id, .tool_name = tc.name, .tool_input = tc.input });
            try valid_calls.append(a, tc);
        } else {
            jsonx.logDroppedToolCall(log, tc.id, tc.name, tc.input);
            a.free(tc.id);
            a.free(tc.name);
            a.free(tc.input);
        }
    }
    calls.deinit(a);
    calls = .empty;
    result.tool_calls = try valid_calls.toOwnedSlice(a);
    return result;
}

fn isJsonObject(a: std.mem.Allocator, value: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, a, value, .{}) catch return false;
    defer parsed.deinit();
    return parsed.value == .object;
}

fn normalizeTaggedReasoning(a: std.mem.Allocator, text: *std.ArrayList(u8), reasoning: *std.ArrayList(u8)) !void {
    const combined = try std.mem.concat(a, u8, &.{ reasoning.items, text.items });
    defer a.free(combined);
    const tags = [_]struct { open: []const u8, close: []const u8 }{
        .{ .open = "<think>", .close = "</think>" },
        .{ .open = "<thinking>", .close = "</thinking>" },
    };
    for (tags) |tag| {
        const open = std.mem.indexOf(u8, combined, tag.open) orelse continue;
        const content_start = open + tag.open.len;
        const close_offset = std.mem.indexOf(u8, combined[content_start..], tag.close) orelse continue;
        const close = content_start + close_offset;
        reasoning.clearRetainingCapacity();
        try reasoning.appendSlice(a, combined[content_start..close]);
        text.clearRetainingCapacity();
        try text.appendSlice(a, combined[0..open]);
        try text.appendSlice(a, combined[close + tag.close.len ..]);
        return;
    }
}

fn applyCompleteToolCalls(a: std.mem.Allocator, calls: *std.ArrayList(types.ToolCall), values: []const std.json.Value) !void {
    for (values) |value| {
        if (value != .object) continue;
        const id = stringField(value, "id") orelse "";
        const function = value.object.get("function") orelse continue;
        if (function != .object) continue;
        const name = stringField(function, "name") orelse "";
        const input = stringField(function, "arguments") orelse "";
        var index: ?usize = null;
        for (calls.items, 0..) |call, i| {
            if (id.len > 0 and std.mem.eql(u8, call.id, id)) {
                index = i;
                break;
            }
        }
        try calls.ensureUnusedCapacity(a, 1);
        const complete: types.ToolCall = blk: {
            const owned_id = try a.dupe(u8, id);
            errdefer a.free(owned_id);
            const owned_name = try a.dupe(u8, name);
            errdefer a.free(owned_name);
            const owned_input = try a.dupe(u8, input);
            break :blk .{ .id = owned_id, .name = owned_name, .input = owned_input };
        };
        if (index) |i| {
            a.free(calls.items[i].id);
            a.free(calls.items[i].name);
            a.free(calls.items[i].input);
            calls.items[i] = complete;
        } else {
            calls.appendAssumeCapacity(complete);
        }
    }
}

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return if (field == .string) field.string else null;
}

fn isValidToolCall(a: std.mem.Allocator, id: []const u8, name: []const u8, input: []const u8) bool {
    return id.len > 0 and name.len > 0 and isJsonObject(a, input);
}

fn encodeJsonArray(a: std.mem.Allocator, values: []const []const u8) ![]const u8 {
    var w = std.Io.Writer.Allocating.init(a);
    defer w.deinit();
    try w.writer.writeByte('[');
    for (values, 0..) |value, i| {
        if (i > 0) try w.writer.writeByte(',');
        try w.writer.writeAll(value);
    }
    try w.writer.writeByte(']');
    return w.toOwnedSlice();
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

fn discardChunk(_: ?*anyopaque, _: types.StreamChunk) void {}

test "stream preserves parallel tool calls and replaces resent arguments" {
    const body =
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_grep","function":{"name":"grep","arguments":"{\"pattern\":\""}},{"index":1,"id":"call_read","function":{"name":"read","arguments":"{\"path\":\""}}]}}]}
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"report\"}"}},{"index":1,"function":{"arguments":"src/report.zig\"}"}}]}}]}
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"pattern\":\"report\",\"case\":true}"}}]}}]}
        \\data: [DONE]
    ;
    var stream = model.StreamContext{ .emit = discardChunk };
    const result = try parseChatStream(std.testing.allocator, body, &stream);
    defer {
        result.deinit(std.testing.allocator);
        std.testing.allocator.destroy(result);
    }
    try std.testing.expectEqual(@as(usize, 2), result.tool_calls.len);
    try std.testing.expectEqualStrings("call_grep", result.tool_calls[0].id);
    try std.testing.expectEqualStrings("{\"pattern\":\"report\",\"case\":true}", result.tool_calls[0].input);
    try std.testing.expectEqualStrings("call_read", result.tool_calls[1].id);
    try std.testing.expectEqualStrings("{\"path\":\"src/report.zig\"}", result.tool_calls[1].input);
}

test "stream continues tool arguments without an index" {
    const body =
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read","arguments":"{\"path\":\""}}]}}]}
        \\data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"src/main.zig\"}"}}]}}]}
    ;
    var stream = model.StreamContext{ .emit = discardChunk };
    const result = try parseChatStream(std.testing.allocator, body, &stream);
    defer {
        result.deinit(std.testing.allocator);
        std.testing.allocator.destroy(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try std.testing.expectEqualStrings("{\"path\":\"src/main.zig\"}", result.tool_calls[0].input);
}

test "stream preserves complete JSON fragments inside tool arguments" {
    const body =
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"edit","arguments":"{\"patch\":\"before "}}]}}]}
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{}"}}]}}]}
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":" after\"}"}}]}}]}
    ;
    var stream = model.StreamContext{ .emit = discardChunk };
    const result = try parseChatStream(std.testing.allocator, body, &stream);
    defer {
        result.deinit(std.testing.allocator);
        std.testing.allocator.destroy(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try std.testing.expectEqualStrings("{\"patch\":\"before {} after\"}", result.tool_calls[0].input);
}

test "stream filters malformed tool calls" {
    const body =
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_bad","function":{"name":"grep","arguments":"{\"pattern\":\"foo\""}},{"index":1,"id":"call_ok","function":{"name":"read","arguments":"{\"path\":\"src/main.zig\"}"}}]}}]}
        \\data: [DONE]
    ;
    var stream = model.StreamContext{ .emit = discardChunk };
    const result = try parseChatStream(std.testing.allocator, body, &stream);
    defer {
        result.deinit(std.testing.allocator);
        std.testing.allocator.destroy(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try std.testing.expectEqualStrings("call_ok", result.tool_calls[0].id);
}

test "stream deduplicates complete final tool calls" {
    const body =
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read","arguments":"{\"path\":\""}}]}}]}
        \\data: {"choices":[{"message":{"role":"assistant","tool_calls":[{"id":"call_1","function":{"name":"read","arguments":"{\"path\":\"src/main.zig\"}"}}]},"finish_reason":"tool_calls"}]}
        \\data: [DONE]
    ;
    var stream = model.StreamContext{ .emit = discardChunk };
    const result = try parseChatStream(std.testing.allocator, body, &stream);
    defer {
        result.deinit(std.testing.allocator);
        std.testing.allocator.destroy(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try std.testing.expectEqualStrings("{\"path\":\"src/main.zig\"}", result.tool_calls[0].input);
}

test "reasoning details survive response replay" {
    const body =
        \\data: {"choices":[{"delta":{"reasoning_content":"think","reasoning_details":[{"type":"reasoning.text","text":"think"}]}}]}
        \\data: {"choices":[{"delta":{"reasoning_content":"more","reasoning_details":[{"type":"reasoning.text","text":"more"}],"content":"answer"},"finish_reason":"stop"}]}
        \\data: [DONE]
    ;
    var stream = model.StreamContext{ .emit = discardChunk };
    const result = try parseChatStream(std.testing.allocator, body, &stream);
    defer {
        result.deinit(std.testing.allocator);
        std.testing.allocator.destroy(result);
    }
    try std.testing.expectEqualStrings("thinkmore", result.reasoning);
    try std.testing.expectEqualStrings("[{\"type\":\"reasoning.text\",\"text\":\"think\"},{\"type\":\"reasoning.text\",\"text\":\"more\"}]", result.reasoning_signature);
}

test "stream keeps tagged reasoning across schema fields" {
    const body =
        \\data: {"choices":[{"delta":{"reasoning_content":"<thin"}}]}
        \\data: {"choices":[{"delta":{"reasoning_content":"king>private "}}]}
        \\data: {"choices":[{"delta":{"content":"tail</thin"}}]}
        \\data: {"choices":[{"delta":{"content":"king>answer"}}]}
    ;
    var stream = model.StreamContext{ .emit = discardChunk };
    const result = try parseChatStream(std.testing.allocator, body, &stream);
    defer {
        result.deinit(std.testing.allocator);
        std.testing.allocator.destroy(result);
    }
    try std.testing.expectEqualStrings("private tail", result.reasoning);
    try std.testing.expectEqualStrings("answer", result.text);
}
