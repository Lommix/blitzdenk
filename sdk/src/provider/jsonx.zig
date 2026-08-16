const std = @import("std");
const model = @import("../model.zig");
const types = @import("../types.zig");
const errors = @import("../errors.zig");

pub fn buildChatRequest(
    a: std.mem.Allocator,
    model_id: []const u8,
    params: model.GenerateParams,
    stream: bool,
) ![]const u8 {
    var w = std.Io.Writer.Allocating.init(a);
    defer w.deinit();
    var s: std.json.Stringify = .{ .writer = &w.writer };

    try s.beginObject();
    try s.objectField("model");
    try s.write(model_id);
    if (params.system.len > 0) {
        try s.beginObject();
        try s.objectField("role");
        try s.write("system");
        try s.objectField("content");
        try s.write(params.system);
        try s.endObject();
    }
    try s.objectField("messages");
    try s.beginArray();
    for (params.messages) |msg| {
        if (msg.role == .tool) {
            for (msg.parts()) |part| {
                const result = switch (part) {
                    .tool_result => |result| result,
                    else => continue,
                };
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
    if (stream) {
        try s.objectField("stream");
        try s.write(true);
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
        .reasoning => |reasoning| {
            try s.beginObject();
            try s.objectField("type");
            try s.write("text");
            try s.objectField("text");
            try s.write(reasoning.text);
            try s.endObject();
        },
        .file, .tool_call, .tool_result => {},
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

pub const HttpError = error{
    ApiError,
    ContextOverflow,
    NetworkError,
    OutOfMemory,
};

const Response = struct {
    status: std.http.Status,
    body: []u8,
};

pub fn postWithRetry(
    a: std.mem.Allocator,
    io: std.Io,
    client: ?*std.http.Client,
    url: []const u8,
    body: []const u8,
    headers: []const std.http.Header,
    max_retries: u32,
    timeout_ms: ?u64,
) ![]u8 {
    var attempt: u32 = 0;
    while (true) {
        const response = try postTimed(a, io, client, url, body, headers, timeout_ms);
        if (@intFromEnum(response.status) < 400) return response.body;
        if (!isRetryableStatus(response.status) or attempt >= max_retries) {
            defer a.free(response.body);
            return classifyError(response.body);
        }
        a.free(response.body);
        try sleepBackoff(io, attempt);
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
    timeout_ms: ?u64,
    event_ctx: ?*anyopaque,
    on_event: *const fn (?*anyopaque, []const u8) anyerror!void,
) ![]u8 {
    var attempt: u32 = 0;
    while (true) {
        const response = try postSseTimed(a, io, client, url, body, headers, timeout_ms, event_ctx, on_event);
        if (@intFromEnum(response.status) < 400) return response.body;
        if (!isRetryableStatus(response.status) or attempt >= max_retries) return classifyError(response.body);
        try sleepBackoff(io, attempt);
        attempt += 1;
    }
}

fn sleepBackoff(io: std.Io, attempt: u32) !void {
    const base_ms: u64 = 2000 * (@as(u64, 1) << @intCast(@min(attempt, 5)));
    const capped = @min(base_ms, 60_000);
    std.Io.sleep(io, .fromMilliseconds(@intCast(capped)), .awake) catch {};
}

fn isRetryableStatus(status: std.http.Status) bool {
    return status == .too_many_requests or @intFromEnum(status) >= 500;
}

fn classifyError(body: []const u8) HttpError {
    return if (errors.isOverflow(body)) error.ContextOverflow else error.ApiError;
}

fn timeoutTask(io: std.Io, timeout_ms: u64) void {
    std.Io.sleep(io, .fromMilliseconds(@intCast(timeout_ms)), .awake) catch {};
}

fn postTimed(
    a: std.mem.Allocator,
    io: std.Io,
    client: ?*std.http.Client,
    url: []const u8,
    body: []const u8,
    headers: []const std.http.Header,
    timeout_ms: ?u64,
) !Response {
    const timeout = timeout_ms orelse return post(a, io, client, url, body, headers);
    const Selection = union(enum) {
        response: anyerror!Response,
        timeout: void,
    };
    var buffer: [2]Selection = undefined;
    var select = std.Io.Select(Selection).init(io, &buffer);
    select.async(.response, post, .{ a, io, client, url, body, headers });
    select.async(.timeout, timeoutTask, .{ io, timeout });
    switch (try select.await()) {
        .response => |response| {
            select.cancelDiscard();
            return response;
        },
        .timeout => {
            select.cancelDiscard();
            return error.Timeout;
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

    var redirect_buf: [8 * 1024]u8 = undefined;
    var out = std.Io.Writer.Allocating.init(a);
    defer out.deinit();

    const result = c.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .redirect_buffer = &redirect_buf,
        .response_writer = &out.writer,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = headers,
    }) catch return error.NetworkError;

    return .{ .status = result.status, .body = try a.dupe(u8, out.written()) };
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
                if (data.len > 0 and !std.mem.eql(u8, data, "[DONE]")) try on_event(event_ctx, data);
            }
            try pending.replaceRange(a, 0, end + 1, "");
        }
    }

    return .{ .status = status, .body = try output.toOwnedSlice(a) };
}

fn postSseTimed(
    a: std.mem.Allocator,
    io: std.Io,
    client: ?*std.http.Client,
    url: []const u8,
    body: []const u8,
    headers: []const std.http.Header,
    timeout_ms: ?u64,
    event_ctx: ?*anyopaque,
    on_event: *const fn (?*anyopaque, []const u8) anyerror!void,
) !Response {
    const timeout = timeout_ms orelse return postSse(a, io, client, url, body, headers, event_ctx, on_event);
    const Selection = union(enum) {
        response: anyerror!Response,
        timeout: void,
    };
    var buffer: [2]Selection = undefined;
    var select = std.Io.Select(Selection).init(io, &buffer);
    select.async(.response, postSse, .{ a, io, client, url, body, headers, event_ctx, on_event });
    select.async(.timeout, timeoutTask, .{ io, timeout });
    switch (try select.await()) {
        .response => |response| {
            select.cancelDiscard();
            return response;
        },
        .timeout => {
            select.cancelDiscard();
            return error.Timeout;
        },
    }
}

test "retryable statuses" {
    try std.testing.expect(isRetryableStatus(.too_many_requests));
    try std.testing.expect(isRetryableStatus(.internal_server_error));
    try std.testing.expect(!isRetryableStatus(.bad_request));
    try std.testing.expect(!isRetryableStatus(.unauthorized));
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
