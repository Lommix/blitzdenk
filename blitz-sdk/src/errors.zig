const std = @import("std");

pub const APIError = struct {
    message: []const u8,
    status_code: u16,
    is_retryable: bool,
    response_body: []const u8 = "",
    retry_after_ms: ?u64 = null,
};

pub const ContextOverflowError = struct {
    message: []const u8,
    response_body: []const u8 = "",
};

pub const SdkError = error{
    NetworkError,
    OutOfMemory,
};

pub const ErrorPayload = union(enum) {
    api: APIError,
    context_overflow: ContextOverflowError,
    network: void,

    pub fn isRetryable(self: ErrorPayload) bool {
        return switch (self) {
            .api => |a| a.is_retryable,
            .context_overflow => false,
            .network => true,
        };
    }
};

const overflow_patterns = [_][]const u8{
    "prompt is too long",
    "input is too long for requested model",
    "exceeds the context window",
    "input token count",
    "maximum prompt length is",
    "reduce the length of the messages",
    "maximum context length is",
    "exceeds the limit of",
    "exceeds the available context size",
    "greater than the context length",
    "context window exceeds limit",
    "exceeded model token limit",
    "context_length_exceeded",
    "context length exceeded",
};

pub fn isOverflow(message: []const u8) bool {
    for (overflow_patterns) |p| {
        if (std.ascii.indexOfIgnoreCase(message, p) != null) return true;
    }
    return false;
}

pub fn classify(
    alloc: std.mem.Allocator,
    status: std.http.Status,
    body: []const u8,
) ErrorPayload {
    const msg = extractMessage(alloc, body) orelse
        std.fmt.allocPrint(alloc, "{d} {s}", .{ @intFromEnum(status), status.phrase() orelse "" }) catch "api error";
    if (isOverflow(msg)) {
        return .{ .context_overflow = .{ .message = msg, .response_body = body } };
    }
    const retryable = switch (status) {
        .too_many_requests, .service_unavailable => true,
        else => @intFromEnum(status) >= 500,
    };
    return .{ .api = .{
        .message = msg,
        .status_code = @intFromEnum(status),
        .is_retryable = retryable,
        .response_body = body,
    } };
}

fn extractMessage(alloc: std.mem.Allocator, body: []const u8) ?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return null;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return null;
    if (root.object.get("error")) |err_v| {
        switch (err_v) {
            .object => {
                if (err_v.object.get("message")) |m| {
                    if (m == .string and m.string.len > 0) return alloc.dupe(u8, m.string) catch null;
                }
            },
            .string => return alloc.dupe(u8, err_v.string) catch null,
            else => {},
        }
    }
    if (root.object.get("message")) |m| {
        if (m == .string and m.string.len > 0) return alloc.dupe(u8, m.string) catch null;
    }
    return null;
}

test "isOverflow patterns" {
    try std.testing.expect(isOverflow("Prompt is too long: 200000 tokens"));
    try std.testing.expect(isOverflow("this model's maximum context length is 4096 tokens"));
    try std.testing.expect(!isOverflow("invalid api key"));
}

test "classification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const e = classify(a, .too_many_requests, "{}");
    try std.testing.expect(e == .api);
    try std.testing.expect(e.api.is_retryable);

    const e400 = classify(a, .bad_request, "{}");
    try std.testing.expect(!e400.api.is_retryable);

    const overflow = classify(a, .bad_request,
        \\{"error":{"message":"prompt is too long"}}
    );
    try std.testing.expect(overflow == .context_overflow);
}
