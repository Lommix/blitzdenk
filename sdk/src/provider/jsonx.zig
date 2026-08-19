const std = @import("std");
const model = @import("../model.zig");
const types = @import("../types.zig");
const errors = @import("../errors.zig");
const opts_mod = @import("../options.zig");
const rate_limiter = @import("../rate_limit.zig");

pub fn buildChatRequest(
    a: std.mem.Allocator,
    model_id: []const u8,
    params: model.GenerateParams,
    stream: bool,
) ![]const u8 {
    var invalid_calls: std.StringHashMapUnmanaged(void) = .empty;
    defer invalid_calls.deinit(a);
    for (params.messages) |msg| {
        for (msg.parts()) |part| switch (part) {
            .tool_call => |call| if (!isValidJsonObject(a, call.input)) try invalid_calls.put(a, call.id, {}),
            else => {},
        };
    }

    var w = std.Io.Writer.Allocating.init(a);
    defer w.deinit();
    var s: std.json.Stringify = .{ .writer = &w.writer };

    try s.beginObject();
    try s.objectField("model");
    try s.write(model_id);
    try s.objectField("messages");
    try s.beginArray();
    if (params.system.len > 0) {
        try s.beginObject();
        try s.objectField("role");
        try s.write("system");
        try s.objectField("content");
        try s.write(params.system);
        try s.endObject();
    }
    for (params.messages) |msg| {
        if (msg.role == .tool) {
            for (msg.parts()) |part| {
                const result = switch (part) {
                    .tool_result => |result| result,
                    else => continue,
                };
                if (invalid_calls.contains(result.id)) continue;
                try s.beginObject();
                try s.objectField("role");
                try s.write("tool");
                try s.objectField("tool_call_id");
                try s.write(result.id);
                try s.objectField("content");
                try s.write(result.output);
                try s.endObject();
            }
            continue;
        }
        try s.beginObject();
        try s.objectField("role");
        try s.write(msg.role.string());
        try s.objectField("content");
        try s.beginArray();
        for (msg.parts()) |part| {
            switch (part) {
                .tool_call, .tool_result => {},
                else => try writePart(&s, part),
            }
        }
        try s.endArray();
        if (msg.role == .assistant) {
            var has_calls = false;
            for (msg.parts()) |part| {
                switch (part) {
                    .tool_call => has_calls = true,
                    else => {},
                }
            }
            if (has_calls) {
                try s.objectField("tool_calls");
                try s.beginArray();
                for (msg.parts()) |part| {
                    const call = switch (part) {
                        .tool_call => |call| call,
                        else => continue,
                    };
                    if (invalid_calls.contains(call.id)) continue;
                    try s.beginObject();
                    try s.objectField("id");
                    try s.write(call.id);
                    try s.objectField("type");
                    try s.write("function");
                    try s.objectField("function");
                    try s.beginObject();
                    try s.objectField("name");
                    try s.write(call.name);
                    try s.objectField("arguments");
                    try s.write(call.input);
                    try s.endObject();
                    try s.endObject();
                }
                try s.endArray();
            }
            var reasoning_text: std.ArrayList(u8) = .empty;
            defer reasoning_text.deinit(a);
            var reasoning_signature: []const u8 = "";
            for (msg.parts()) |part| switch (part) {
                .reasoning => |reasoning| {
                    try reasoning_text.appendSlice(a, reasoning.text);
                    if (reasoning.signature.len > 0) reasoning_signature = reasoning.signature;
                },
                else => {},
            };
            if (std.ascii.indexOfIgnoreCase(model_id, "deepseek") != null) {
                try s.objectField("reasoning_content");
                try s.write(reasoning_text.items);
            } else if (reasoning_signature.len > 0) {
                try s.objectField("reasoning_details");
                try writeRaw(&s, reasoning_signature);
            }
        }
        try s.endObject();
    }
    try s.endArray();

    if (params.tools.len > 0) {
        try s.objectField("tools");
        try s.beginArray();
        for (params.tools) |tool| {
            try s.beginObject();
            try s.objectField("type");
            try s.write("function");
            try s.objectField("function");
            try s.beginObject();
            try s.objectField("name");
            try s.write(tool.name);
            try s.objectField("description");
            try s.write(tool.description);
            try s.objectField("parameters");
            try writeRaw(&s, tool.input_schema);
            try s.endObject();
            try s.endObject();
        }
        try s.endArray();
    }

    if (params.max_output_tokens > 0) {
        try s.objectField("max_tokens");
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
    if (params.frequency_penalty) |t| {
        try s.objectField("frequency_penalty");
        try s.write(t);
    }
    if (params.presence_penalty) |t| {
        try s.objectField("presence_penalty");
        try s.write(t);
    }
    if (params.stop_sequences.len > 0) {
        try s.objectField("stop");
        try s.write(params.stop_sequences);
    }
    if (params.seed) |value| {
        try s.objectField("seed");
        try s.write(value);
    }
    try writeToolChoice(&s, params.tool_choice);
    if (params.response_format) |format| {
        try s.objectField("response_format");
        try s.beginObject();
        try s.objectField("type");
        try s.write("json_schema");
        try s.objectField("json_schema");
        try s.beginObject();
        try s.objectField("name");
        try s.write(format.name);
        try s.objectField("strict");
        try s.write(true);
        try s.objectField("schema");
        try writeRaw(&s, format.schema);
        try s.endObject();
        try s.endObject();
    }
    if (params.prompt_caching) {
        if (params.cache_ttl) |value| {
            try s.objectField("prompt_cache_retention");
            try s.write(value);
        }
    }
    try writeProviderOptions(&s, params.provider_options);
    try s.objectField("stream");
    try s.write(stream);
    if (stream) {
        try s.objectField("stream_options");
        try s.beginObject();
        try s.objectField("include_usage");
        try s.write(true);
        try s.endObject();
    }
    try s.endObject();
    return w.toOwnedSlice();
}

fn writePart(s: *std.json.Stringify, part: types.Part) !void {
    switch (part) {
        .text => |text| {
            try s.beginObject();
            try s.objectField("type");
            try s.write("text");
            try s.objectField("text");
            try s.write(text);
            try s.endObject();
        },
        .image => |image| {
            try s.beginObject();
            try s.objectField("type");
            try s.write("image_url");
            try s.objectField("image_url");
            try s.beginObject();
            try s.objectField("url");
            try s.write(image.url);
            if (image.detail.len > 0) {
                try s.objectField("detail");
                try s.write(image.detail);
            }
            try s.endObject();
            try s.endObject();
        },
        .file, .provider_data, .reasoning, .tool_call, .tool_result => {},
    }
}

fn writeToolChoice(s: *std.json.Stringify, choice: @import("../options.zig").ToolChoice) !void {
    switch (choice) {
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
            try s.objectField("function");
            try s.beginObject();
            try s.objectField("name");
            try s.write(name);
            try s.endObject();
            try s.endObject();
        },
    }
}

pub fn writeProviderOptions(s: *std.json.Stringify, value: ?std.json.Value) !void {
    const options = value orelse return;
    if (options != .object) return;
    var it = options.object.iterator();
    while (it.next()) |entry| {
        try s.objectField(entry.key_ptr.*);
        try s.write(entry.value_ptr.*);
    }
}

pub fn writeRaw(s: *std.json.Stringify, value: []const u8) !void {
    try s.beginWriteRaw();
    try s.writer.writeAll(value);
    s.endWriteRaw();
}

fn isValidJsonObject(a: std.mem.Allocator, value: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, a, value, .{}) catch return false;
    defer parsed.deinit();
    return parsed.value == .object;
}

pub const HttpError = error{
    ApiError,
    RateLimited,
    ContextOverflow,
    NetworkError,
    OutOfMemory,
};

const Response = struct {
    status: std.http.Status,
    body: []u8,
    retry_after_ms: ?u64 = null,
};

pub const RequestOptions = struct {
    timeout_ms: ?u64 = null,
    cancellation: ?*opts_mod.CancellationToken = null,
    on_provider_error: ?*const fn (ctx: ?*anyopaque, info: opts_mod.ProviderErrorInfo) void = null,
    on_provider_error_ctx: ?*anyopaque = null,
    rate_limit: u32 = 0,
    rate_limit_url: []const u8 = "",
};

pub fn postWithRetry(
    a: std.mem.Allocator,
    io: std.Io,
    client: ?*std.http.Client,
    url: []const u8,
    body: []const u8,
    headers: []const std.http.Header,
    max_retries: u32,
    options: RequestOptions,
) ![]u8 {
    try rate_limiter.acquire(io, options.rate_limit_url, options.rate_limit, options.cancellation);
    var attempt: u32 = 0;
    while (true) {
        if (options.cancellation) |token| try token.check();
        const response = try postTimed(a, io, client, url, body, headers, options.timeout_ms, options.cancellation);
        if (@intFromEnum(response.status) < 400) return response.body;
        if (!isRetryableStatus(response.status) or attempt >= max_retries) {
            defer a.free(response.body);
            return reportError(a, response, options);
        }
        if (notifyError(a, response, options, true, attempt + 1) == error.OutOfMemory) return error.OutOfMemory;
        const retry_after_ms = response.retry_after_ms;
        a.free(response.body);
        try sleepBackoff(io, attempt, retry_after_ms, options.cancellation);
        attempt += 1;
    }
}

pub fn postSseWithRetry(
    a: std.mem.Allocator,
    io: std.Io,
    client: ?*std.http.Client,
    url: []const u8,
    body: []const u8,
    headers: []const std.http.Header,
    max_retries: u32,
    options: RequestOptions,
    event_ctx: ?*anyopaque,
    on_event: *const fn (?*anyopaque, []const u8) anyerror!void,
) ![]u8 {
    try rate_limiter.acquire(io, options.rate_limit_url, options.rate_limit, options.cancellation);
    var attempt: u32 = 0;
    while (true) {
        if (options.cancellation) |token| try token.check();
        const response = try postSseTimed(a, io, client, url, body, headers, options.timeout_ms, options.cancellation, event_ctx, on_event);
        if (@intFromEnum(response.status) < 400) return response.body;
        if (!isRetryableStatus(response.status) or attempt >= max_retries) {
            defer a.free(response.body);
            return reportError(a, response, options);
        }
        if (notifyError(a, response, options, true, attempt + 1) == error.OutOfMemory) return error.OutOfMemory;
        const retry_after_ms = response.retry_after_ms;
        a.free(response.body);
        try sleepBackoff(io, attempt, retry_after_ms, options.cancellation);
        attempt += 1;
    }
}

fn sleepBackoff(io: std.Io, attempt: u32, retry_after_ms: ?u64, cancellation: ?*opts_mod.CancellationToken) !void {
    const base_ms: u64 = 2000 * (@as(u64, 1) << @intCast(@min(attempt, 5)));
    const capped = @min(retry_after_ms orelse base_ms, 60_000);
    try opts_mod.sleepCancellable(io, capped, cancellation);
}

fn isRetryableStatus(status: std.http.Status) bool {
    return status == .too_many_requests or @intFromEnum(status) >= 500;
}

fn reportError(a: std.mem.Allocator, response: Response, options: RequestOptions) HttpError {
    return notifyError(a, response, options, false, 0);
}

fn notifyError(a: std.mem.Allocator, response: Response, options: RequestOptions, will_retry: bool, attempt: u32) HttpError {
    var payload = errors.classify(a, response.status, response.body);
    defer switch (payload) {
        .api => |value| a.free(value.message),
        .context_overflow => |value| a.free(value.message),
        .network => {},
    };
    switch (payload) {
        .api => |*value| value.retry_after_ms = response.retry_after_ms,
        else => {},
    }
    if (options.on_provider_error) |callback| callback(options.on_provider_error_ctx, switch (payload) {
        .api => |value| .{
            .status_code = value.status_code,
            .response_body = value.response_body,
            .is_retryable = value.is_retryable,
            .retry_after_ms = value.retry_after_ms,
            .will_retry = will_retry,
            .attempt = attempt,
        },
        .context_overflow => |value| .{
            .status_code = @intFromEnum(response.status),
            .response_body = value.response_body,
            .is_retryable = false,
            .context_overflow = true,
            .will_retry = will_retry,
            .attempt = attempt,
        },
        .network => unreachable,
    });
    return switch (payload) {
        .context_overflow => error.ContextOverflow,
        .api => if (response.status == .too_many_requests) error.RateLimited else error.ApiError,
        .network => error.NetworkError,
    };
}

pub fn reportStreamError(a: std.mem.Allocator, options: RequestOptions, body: []const u8) ?HttpError {
    var parsed = std.json.parseFromSlice(std.json.Value, a, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const event_type = blk: {
        const value = parsed.value.object.get("type") orelse break :blk "";
        break :blk if (value == .string) value.string else "";
    };
    const failed = parsed.value.object.get("error") != null or
        std.mem.eql(u8, event_type, "error") or
        std.mem.eql(u8, event_type, "response.failed") or
        std.mem.eql(u8, event_type, "response.incomplete");
    if (!failed) return null;
    const context_overflow = errors.isOverflow(body);
    const retryable = std.ascii.indexOfIgnoreCase(body, "rate_limit") != null or
        std.ascii.indexOfIgnoreCase(body, "overloaded") != null or
        std.ascii.indexOfIgnoreCase(body, "unavailable") != null;
    if (options.on_provider_error) |callback| callback(options.on_provider_error_ctx, .{
        .status_code = 0,
        .response_body = body,
        .is_retryable = retryable,
        .context_overflow = context_overflow,
    });
    if (context_overflow) return error.ContextOverflow;
    return if (std.ascii.indexOfIgnoreCase(body, "rate_limit") != null) error.RateLimited else error.ApiError;
}

fn timeoutTask(io: std.Io, timeout_ms: u64, done: *std.atomic.Value(bool)) void {
    defer done.store(true, .release);
    std.Io.sleep(io, .fromMilliseconds(@intCast(timeout_ms)), .awake) catch {};
}

fn postTask(a: std.mem.Allocator, io: std.Io, client: ?*std.http.Client, url: []const u8, body: []const u8, headers: []const std.http.Header, done: *std.atomic.Value(bool)) !Response {
    defer done.store(true, .release);
    return post(a, io, client, url, body, headers);
}

fn postTimed(
    a: std.mem.Allocator,
    io: std.Io,
    client: ?*std.http.Client,
    url: []const u8,
    body: []const u8,
    headers: []const std.http.Header,
    timeout_ms: ?u64,
    cancellation: ?*opts_mod.CancellationToken,
) !Response {
    if (timeout_ms == null and cancellation == null) return post(a, io, client, url, body, headers);
    const Selection = union(enum) {
        response: anyerror!Response,
        timeout: void,
        canceled: void,
    };
    var buffer: [3]Selection = undefined;
    var select = std.Io.Select(Selection).init(io, &buffer);
    var done = std.atomic.Value(bool).init(false);
    select.async(.response, postTask, .{ a, io, client, url, body, headers, &done });
    if (timeout_ms) |timeout| select.async(.timeout, timeoutTask, .{ io, timeout, &done });
    if (cancellation) |token| select.async(.canceled, opts_mod.CancellationToken.waitUntilDone, .{ token, &done, io });
    switch (try select.await()) {
        .response => |response| {
            select.cancelDiscard();
            return response;
        },
        .timeout => {
            select.cancelDiscard();
            return error.Timeout;
        },
        .canceled => {
            select.cancelDiscard();
            return error.Canceled;
        },
    }
}

fn ensureClient(a: std.mem.Allocator, io: std.Io, client: ?*std.http.Client) !*std.http.Client {
    if (client) |c| return c;
    const c = try a.create(std.http.Client);
    c.* = .{ .allocator = a, .io = io };
    return c;
}

fn post(
    a: std.mem.Allocator,
    io: std.Io,
    client: ?*std.http.Client,
    url: []const u8,
    body: []const u8,
    headers: []const std.http.Header,
) !Response {
    var owned_client = false;
    const c = client orelse blk: {
        const created = try ensureClient(a, io, null);
        owned_client = true;
        break :blk created;
    };
    defer if (owned_client) {
        c.deinit();
        a.destroy(c);
    };

    const uri = std.Uri.parse(url) catch return error.NetworkError;
    var req = c.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .omit,
        },
        .extra_headers = headers,
    }) catch return error.NetworkError;
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    var request_body = req.sendBodyUnflushed(&.{}) catch return error.NetworkError;
    request_body.writer.writeAll(body) catch return error.NetworkError;
    request_body.end() catch return error.NetworkError;
    req.connection.?.flush() catch return error.NetworkError;

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return error.NetworkError;
    const status = response.head.status;
    const retry_after_ms = retryAfterMs(response.head);
    const reader = response.reader(&.{});
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(a);
    var scratch: [16 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&scratch);
    while (true) {
        writer.end = 0;
        _ = reader.stream(&writer, .limited(scratch.len)) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return error.NetworkError,
            error.WriteFailed => unreachable,
        };
        try output.appendSlice(a, scratch[0..writer.end]);
    }

    return .{ .status = status, .body = try output.toOwnedSlice(a), .retry_after_ms = retry_after_ms };
}

fn postSse(
    a: std.mem.Allocator,
    io: std.Io,
    client: ?*std.http.Client,
    url: []const u8,
    body: []const u8,
    headers: []const std.http.Header,
    event_ctx: ?*anyopaque,
    on_event: *const fn (?*anyopaque, []const u8) anyerror!void,
) !Response {
    const h = try a.alloc(std.http.Header, headers.len + 1);
    defer a.free(h);
    @memcpy(h[0..headers.len], headers);
    h[headers.len] = .{ .name = "Accept", .value = "text/event-stream" };

    var owned_client = false;
    const c = client orelse blk: {
        const created = try ensureClient(a, io, null);
        owned_client = true;
        break :blk created;
    };
    defer if (owned_client) {
        c.deinit();
        a.destroy(c);
    };

    const uri = std.Uri.parse(url) catch return error.NetworkError;
    var req = c.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .omit,
        },
        .extra_headers = h,
    }) catch return error.NetworkError;
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    var request_body = req.sendBodyUnflushed(&.{}) catch return error.NetworkError;
    request_body.writer.writeAll(body) catch return error.NetworkError;
    request_body.end() catch return error.NetworkError;
    req.connection.?.flush() catch return error.NetworkError;

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return error.NetworkError;
    const status = response.head.status;
    const retry_after_ms = retryAfterMs(response.head);
    const reader = response.reader(&.{});
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(a);
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(a);
    var scratch: [16 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&scratch);

    while (true) {
        writer.end = 0;
        _ = reader.stream(&writer, .limited(scratch.len)) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return error.NetworkError,
            error.WriteFailed => unreachable,
        };
        if (writer.end == 0) continue;
        const chunk = scratch[0..writer.end];
        try output.appendSlice(a, chunk);
        if (@intFromEnum(status) >= 400) continue;
        try pending.appendSlice(a, chunk);
        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |end| {
            const line = std.mem.trimEnd(u8, pending.items[0..end], "\r");
            if (std.mem.startsWith(u8, line, "data:")) {
                const data = std.mem.trim(u8, line["data:".len..], " ");
                if (std.mem.eql(u8, data, "[DONE]")) return .{ .status = status, .body = try output.toOwnedSlice(a), .retry_after_ms = retry_after_ms };
                if (data.len > 0) try on_event(event_ctx, data);
            }
            try pending.replaceRange(a, 0, end + 1, "");
        }
    }

    return .{ .status = status, .body = try output.toOwnedSlice(a), .retry_after_ms = retry_after_ms };
}

fn retryAfterMs(head: std.http.Client.Response.Head) ?u64 {
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "retry-after")) continue;
        const seconds = std.fmt.parseUnsigned(u64, std.mem.trim(u8, header.value, " \t"), 10) catch return null;
        return std.math.mul(u64, seconds, 1000) catch std.math.maxInt(u64);
    }
    return null;
}

fn postSseTimed(
    a: std.mem.Allocator,
    io: std.Io,
    client: ?*std.http.Client,
    url: []const u8,
    body: []const u8,
    headers: []const std.http.Header,
    timeout_ms: ?u64,
    cancellation: ?*opts_mod.CancellationToken,
    event_ctx: ?*anyopaque,
    on_event: *const fn (?*anyopaque, []const u8) anyerror!void,
) !Response {
    if (timeout_ms == null and cancellation == null) return postSse(a, io, client, url, body, headers, event_ctx, on_event);
    const Selection = union(enum) {
        response: anyerror!Response,
        timeout: void,
        canceled: void,
    };
    var buffer: [3]Selection = undefined;
    var select = std.Io.Select(Selection).init(io, &buffer);
    var done = std.atomic.Value(bool).init(false);
    select.async(.response, postSseTask, .{ a, io, client, url, body, headers, event_ctx, on_event, &done });
    if (timeout_ms) |timeout| select.async(.timeout, timeoutTask, .{ io, timeout, &done });
    if (cancellation) |token| select.async(.canceled, opts_mod.CancellationToken.waitUntilDone, .{ token, &done, io });
    switch (try select.await()) {
        .response => |response| {
            select.cancelDiscard();
            return response;
        },
        .timeout => {
            select.cancelDiscard();
            return error.Timeout;
        },
        .canceled => {
            select.cancelDiscard();
            return error.Canceled;
        },
    }
}

fn postSseTask(a: std.mem.Allocator, io: std.Io, client: ?*std.http.Client, url: []const u8, body: []const u8, headers: []const std.http.Header, event_ctx: ?*anyopaque, on_event: *const fn (?*anyopaque, []const u8) anyerror!void, done: *std.atomic.Value(bool)) !Response {
    defer done.store(true, .release);
    return postSse(a, io, client, url, body, headers, event_ctx, on_event);
}

test "retryable statuses" {
    try std.testing.expect(isRetryableStatus(.too_many_requests));
    try std.testing.expect(isRetryableStatus(.internal_server_error));
    try std.testing.expect(!isRetryableStatus(.bad_request));
    try std.testing.expect(!isRetryableStatus(.unauthorized));
}

test "provider errors retain body rate classification and retry delay" {
    const Capture = struct {
        called: bool = false,
        body_matches: bool = false,
        status_code: u16 = 0,
        retryable: bool = false,
        retry_after_ms: ?u64 = null,
        will_retry: bool = false,
        attempt: u32 = 0,

        fn receive(ctx: ?*anyopaque, info: opts_mod.ProviderErrorInfo) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.called = true;
            self.body_matches = std.mem.eql(u8, info.response_body, "{\"error\":{\"message\":\"slow down\"}}");
            self.status_code = info.status_code;
            self.retryable = info.is_retryable;
            self.retry_after_ms = info.retry_after_ms;
            self.will_retry = info.will_retry;
            self.attempt = info.attempt;
        }
    };
    var capture = Capture{};
    var body = "{\"error\":{\"message\":\"slow down\"}}".*;
    const err = reportError(std.testing.allocator, .{
        .status = .too_many_requests,
        .body = &body,
        .retry_after_ms = 3000,
    }, .{
        .on_provider_error = Capture.receive,
        .on_provider_error_ctx = &capture,
    });
    try std.testing.expectEqual(error.RateLimited, err);
    try std.testing.expect(capture.called);
    try std.testing.expect(capture.body_matches);
    try std.testing.expectEqual(@as(u16, 429), capture.status_code);
    try std.testing.expect(capture.retryable);
    try std.testing.expectEqual(@as(?u64, 3000), capture.retry_after_ms);
    var retry_body = "{\"error\":{\"message\":\"slow down\"}}".*;
    try std.testing.expectEqual(error.RateLimited, notifyError(std.testing.allocator, .{
        .status = .too_many_requests,
        .body = &retry_body,
        .retry_after_ms = 3000,
    }, .{
        .on_provider_error = Capture.receive,
        .on_provider_error_ctx = &capture,
    }, true, 2));
    try std.testing.expect(capture.will_retry);
    try std.testing.expectEqual(@as(u32, 2), capture.attempt);
}

test "stream error events retain provider bodies" {
    const Capture = struct {
        body_matches: bool = false,
        retryable: bool = false,

        fn receive(ctx: ?*anyopaque, info: opts_mod.ProviderErrorInfo) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.body_matches = std.mem.indexOf(u8, info.response_body, "model unavailable") != null;
            self.retryable = info.is_retryable;
        }
    };
    var capture = Capture{};
    const err = reportStreamError(std.testing.allocator, .{
        .on_provider_error = Capture.receive,
        .on_provider_error_ctx = &capture,
    }, "{\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"model unavailable\"}}}");
    try std.testing.expectEqual(error.ApiError, err.?);
    try std.testing.expect(capture.body_matches);
    try std.testing.expect(capture.retryable);
}

test "stream context overflow events retain their classification" {
    const Capture = struct {
        context_overflow: bool = false,

        fn receive(ctx: ?*anyopaque, info: opts_mod.ProviderErrorInfo) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.context_overflow = info.context_overflow;
        }
    };
    var capture = Capture{};
    const err = reportStreamError(std.testing.allocator, .{
        .on_provider_error = Capture.receive,
        .on_provider_error_ctx = &capture,
    }, "{\"type\":\"response.failed\",\"error\":{\"message\":\"maximum context length is 4096 tokens\"}}");
    try std.testing.expectEqual(error.ContextOverflow, err.?);
    try std.testing.expect(capture.context_overflow);
}

test "cancellation interrupts retry waits" {
    const Fixture = struct {
        fn cancel(token: *opts_mod.CancellationToken, io: std.Io) void {
            std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
            token.cancel(io);
        }
    };
    var token = opts_mod.CancellationToken{};
    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = io_state.io();
    var cancel = std.Io.async(io, Fixture.cancel, .{ &token, io });
    defer cancel.cancel(io);
    try std.testing.expectError(error.Canceled, sleepBackoff(io, 0, null, &token));
}

test "cancellation interrupts HTTP reads" {
    const Fixture = struct {
        fn hang(server: *std.Io.net.Server, io: std.Io) void {
            var stream = server.accept(io) catch return;
            defer stream.close(io);
            std.Io.sleep(io, .fromSeconds(60), .awake) catch {};
        }

        fn cancel(token: *opts_mod.CancellationToken, io: std.Io) void {
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
            token.cancel(io);
        }
    };
    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = io_state.io();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    var hanging = std.Io.async(io, Fixture.hang, .{ &server, io });
    defer hanging.cancel(io);
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
    defer std.testing.allocator.free(url);
    var token = opts_mod.CancellationToken{};
    var cancel = std.Io.async(io, Fixture.cancel, .{ &token, io });
    defer cancel.cancel(io);
    try std.testing.expectError(error.Canceled, postWithRetry(std.testing.allocator, io, null, url, "{}", &.{}, 0, .{ .cancellation = &token }));
}

test "SSE done marker ends a response without waiting for connection close" {
    const Fixture = struct {
        fn serve(server: *std.Io.net.Server, io: std.Io) void {
            var stream = server.accept(io) catch return;
            defer stream.close(io);
            var buffer: [1024]u8 = undefined;
            var writer = stream.writer(io, &buffer);
            writer.interface.writeAll(
                "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n" ++
                    "d\r\ndata: hello\n\n\r\n" ++
                    "e\r\ndata: [DONE]\n\n\r\n",
            ) catch return;
            writer.interface.flush() catch return;
            std.Io.sleep(io, .fromSeconds(60), .awake) catch {};
        }

        fn receive(ctx: ?*anyopaque, data: []const u8) !void {
            const seen: *bool = @ptrCast(@alignCast(ctx.?));
            seen.* = std.mem.eql(u8, data, "hello");
        }
    };
    var io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
    const io = io_state.io();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    var serving = std.Io.async(io, Fixture.serve, .{ &server, io });
    defer serving.cancel(io);
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
    defer std.testing.allocator.free(url);
    var seen = false;
    const response = try postSseTimed(std.testing.allocator, io, null, url, "{}", &.{}, 100, null, &seen, Fixture.receive);
    defer std.testing.allocator.free(response.body);
    try std.testing.expect(seen);
}

test "chat request places system prompt in messages" {
    const messages = [_]types.Message{
        types.UserMessage("prompt"),
        types.UserMessage("<system-reminder>cwd</system-reminder>"),
    };
    const body = try buildChatRequest(std.testing.allocator, "gpt-test", .{
        .system = "instructions",
        .messages = &messages,
    }, true);
    defer std.testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const request_messages = parsed.value.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), request_messages.len);
    try std.testing.expectEqualStrings("system", request_messages[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("instructions", request_messages[0].object.get("content").?.string);
}

test "chat tool messages use OpenAI fields" {
    const messages = [_]types.Message{
        .{ .role = .assistant, .content = &.{types.Part.toolCallPart("call_1", "weather", "{\"city\":\"Paris\"}")} },
        types.ToolMessage("call_1", "weather", "sunny"),
    };
    const body = try buildChatRequest(std.testing.allocator, "gpt-test", .{ .messages = &messages }, false);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_calls\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_call_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"tool_call\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":false") != null);
}

test "chat structured output and tool choice" {
    const body = try buildChatRequest(std.testing.allocator, "gpt-test", .{
        .tool_choice = .{ .tool = "weather" },
        .response_format = .{ .name = "answer", .schema = "{\"type\":\"object\"}" },
    }, false);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"response_format\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"weather\"") != null);
}

test "chat skips malformed tool calls and paired results" {
    const messages = [_]types.Message{
        .{ .role = .assistant, .content = &.{
            types.Part.toolCallPart("call_bad", "grep", "{\"pattern\":\"foo\""),
            types.Part.toolCallPart("call_ok", "read", "{\"path\":\"src/main.zig\"}"),
        } },
        .{ .role = .tool, .content = &.{
            types.Part.toolResultPart("call_bad", "grep", "bad"),
            types.Part.toolResultPart("call_ok", "read", "contents"),
        } },
    };
    const body = try buildChatRequest(std.testing.allocator, "gpt-test", .{ .messages = &messages }, false);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "call_ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "call_bad") == null);
}

test "chat replays provider reasoning fields" {
    const messages = [_]types.Message{.{ .role = .assistant, .content = &.{
        types.Part.reasoningPart("inspect the file", "[{\"type\":\"reasoning.text\",\"text\":\"inspect\"}]"),
        types.Part.textPart("done"),
    } }};
    const deepseek = try buildChatRequest(std.testing.allocator, "Vendor/DeepSeek-V4-Pro", .{ .messages = &messages }, false);
    defer std.testing.allocator.free(deepseek);
    try std.testing.expect(std.mem.indexOf(u8, deepseek, "\"reasoning_content\":\"inspect the file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, deepseek, "reasoning_details") == null);

    const other = try buildChatRequest(std.testing.allocator, "qwen3-thinking", .{ .messages = &messages }, false);
    defer std.testing.allocator.free(other);
    try std.testing.expect(std.mem.indexOf(u8, other, "\"reasoning_details\":[{\"type\":\"reasoning.text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, other, "reasoning_content") == null);
}
