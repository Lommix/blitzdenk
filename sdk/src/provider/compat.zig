const std = @import("std");
const model = @import("../model.zig");
const auth = @import("../auth.zig");
const openai = @import("openai.zig");
const jsonx = @import("jsonx.zig");
const types = @import("../types.zig");

pub const base_url_env = "COMPAT_BASE_URL";

pub const Options = struct {
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    headers: []const std.http.Header = &.{},
    env: auth.Env = .{},
};

pub const Chat = struct {
    model_id: []const u8,
    api_key: []const u8,
    base_url: []const u8,
    extra_headers: []const std.http.Header,

    pub fn init(alloc: std.mem.Allocator, model_id: []const u8, opts: Options) !Chat {
        const base = opts.base_url orelse auth.resolveKey(opts.env, base_url_env) orelse "";
        const key = opts.api_key orelse auth.resolveKey(opts.env, "COMPAT_API_KEY") orelse "";
        return .{
            .model_id = try alloc.dupe(u8, model_id),
            .api_key = try alloc.dupe(u8, key),
            .base_url = try alloc.dupe(u8, base),
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

        const body = try jsonx.buildChatRequest(alloc, self.model_id, params, false);
        defer alloc.free(body);
        const headers = try self.authHeaders(alloc, params.headers);
        defer auth.freeHeaders(alloc, headers);
        const url = try std.fmt.allocPrint(alloc, "{s}/chat/completions", .{self.base_url});
        defer alloc.free(url);
        const response = try jsonx.postWithRetry(alloc, io, client, url, body, headers, max_retries, params.timeout_ms);
        defer alloc.free(response);
        return openai.parseChatResponse(alloc, response);
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

        const body = try jsonx.buildChatRequest(stream_alloc, self.model_id, params, true);
        const headers = try self.authHeaders(stream_alloc, params.headers);
        const url = try std.fmt.allocPrint(stream_alloc, "{s}/chat/completions", .{self.base_url});
        var live = LiveStream{ .alloc = stream_alloc, .sctx = sctx };
        const sse_text = try jsonx.postSseWithRetry(stream_alloc, io, client, url, body, headers, max_retries, params.timeout_ms, &live, emitLiveEvent);
        var final_ctx = model.StreamContext{ .emit = emitFinalTool, .emit_ctx = sctx };
        return openai.parseChatStream(alloc, sse_text, &final_ctx);
    }

    fn embedFn(
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
        const url = try std.fmt.allocPrint(alloc, "{s}/embeddings", .{self.base_url});
        const response = try jsonx.postWithRetry(alloc, io, client, url, w.written(), headers, max_retries, params.timeout_ms);
        return openai.parseEmbedResponse(alloc, response);
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
    _ = try openai.parseChatStream(live.alloc, event, &event_ctx);
}
