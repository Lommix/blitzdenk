const std = @import("std");

pub const Role = enum {
    system,
    developer,
    user,
    assistant,
    tool,

    pub fn string(self: Role) []const u8 {
        return switch (self) {
            .system => "system",
            .developer => "developer",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
    }

    pub fn fromString(s: []const u8) ?Role {
        const map = std.StaticStringMap(Role).initComptime(.{
            .{ "system", .system },
            .{ "developer", .developer },
            .{ "user", .user },
            .{ "assistant", .assistant },
            .{ "tool", .tool },
        });
        return map.get(s);
    }
};

pub const PartType = enum {
    text,
    reasoning,
    image,
    tool_call,
    tool_result,
    file,
};

pub const Part = struct {
    type: PartType,

    text: []const u8 = "",

    url: []const u8 = "",
    media_type: []const u8 = "",
    filename: []const u8 = "",
    detail: []const u8 = "",

    tool_call_id: []const u8 = "",
    tool_name: []const u8 = "",
    tool_input: []const u8 = "",
    tool_output: []const u8 = "",

    signature: []const u8 = "",
    cache_control: []const u8 = "",
    is_error: bool = false,

    pub fn textPart(text: []const u8) Part {
        return .{ .type = .text, .text = text };
    }

    pub fn reasoningPart(text: []const u8, signature: []const u8) Part {
        return .{ .type = .reasoning, .text = text, .signature = signature };
    }

    pub fn imagePart(url: []const u8, media_type: []const u8) Part {
        return .{ .type = .image, .url = url, .media_type = media_type };
    }

    pub fn toolCallPart(id: []const u8, name: []const u8, input: []const u8) Part {
        return .{
            .type = .tool_call,
            .tool_call_id = id,
            .tool_name = name,
            .tool_input = input,
        };
    }

    pub fn toolResultPart(id: []const u8, name: []const u8, output: []const u8) Part {
        return .{
            .type = .tool_result,
            .tool_call_id = id,
            .tool_name = name,
            .tool_output = output,
        };
    }

    pub fn filePart(url: []const u8, media_type: []const u8, filename: []const u8) Part {
        return .{ .type = .file, .url = url, .media_type = media_type, .filename = filename };
    }
};

pub const Message = struct {
    role: Role,
    content: []const Part = &.{},
    single: ?Part = null,

    pub fn parts(self: *const Message) []const Part {
        if (self.single != null) return @as(*const [1]Part, @ptrCast(&self.single.?));
        return self.content;
    }

    pub fn text(self: Message) []const u8 {
        for (self.parts()) |p| {
            if (p.type == .text) return p.text;
        }
        return "";
    }
};

pub fn SystemMessage(text: []const u8) Message {
    return .{ .role = .system, .single = Part.textPart(text) };
}

pub fn UserMessage(text: []const u8) Message {
    return .{ .role = .user, .single = Part.textPart(text) };
}

pub fn AssistantMessage(text: []const u8) Message {
    return .{ .role = .assistant, .single = Part.textPart(text) };
}

pub fn DeveloperMessage(text: []const u8) Message {
    return .{ .role = .developer, .single = Part.textPart(text) };
}

pub fn ToolMessage(call_id: []const u8, tool_name: []const u8, output: []const u8) Message {
    return .{
        .role = .tool,
        .single = Part.toolResultPart(call_id, tool_name, output),
    };
}

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    input: []const u8,
};

pub const ToolResult = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    output: []const u8,
    is_error: bool = false,
};

pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    total_tokens: u64 = 0,
    reasoning_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,

    pub fn add(self: *Usage, other: Usage) void {
        self.input_tokens += other.input_tokens;
        self.output_tokens += other.output_tokens;
        self.total_tokens += other.total_tokens;
        self.reasoning_tokens += other.reasoning_tokens;
        self.cache_read_tokens += other.cache_read_tokens;
        self.cache_write_tokens += other.cache_write_tokens;
    }
};

pub const FinishReason = enum {
    stop,
    tool_calls,
    length,
    content_filter,
    err,
    other,

    pub fn string(self: FinishReason) []const u8 {
        return switch (self) {
            .stop => "stop",
            .tool_calls => "tool-calls",
            .length => "length",
            .content_filter => "content_filter",
            .err => "error",
            .other => "other",
        };
    }
};

pub const StreamChunkType = enum {
    text,
    reasoning,
    tool_call,
    tool_call_delta,
    tool_call_streaming_start,
    tool_result,
    step_finish,
    finish,
    err,
};

pub const StreamChunk = struct {
    type: StreamChunkType,

    text: []const u8 = "",
    tool_call_id: []const u8 = "",
    tool_name: []const u8 = "",
    tool_input: []const u8 = "",
    tool_output: []const u8 = "",
    number: usize = 0,

    finish_reason: ?FinishReason = null,
    usage: ?Usage = null,
    response: ?ResponseMetadata = null,
    err: ?anyerror = null,
};

pub const ResponseMetadata = struct {
    id: []const u8 = "",
    model: []const u8 = "",
};

pub const Source = struct {
    id: []const u8 = "",
    type: []const u8 = "",
    url: []const u8 = "",
    title: []const u8 = "",
    start_index: usize = 0,
    end_index: usize = 0,
};

pub const StepResult = struct {
    number: usize,
    text: []const u8 = "",
    reasoning: []const u8 = "",
    tool_calls: []const ToolCall = &.{},
    tool_results: []const ToolResult = &.{},
    finish_reason: FinishReason = .other,
    usage: Usage = .{},
    response: ResponseMetadata = .{},
};

pub const TextResult = struct {
    text: []const u8 = "",
    reasoning: []const u8 = "",
    tool_calls: []const ToolCall = &.{},
    steps: []const StepResult = &.{},
    total_usage: Usage = .{},
    finish_reason: FinishReason = .other,
    response: ResponseMetadata = .{},
    sources: []const Source = &.{},
    steps_exhausted: bool = false,
    messages: []const Message = &.{},

    pub fn deinit(self: *TextResult, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
        alloc.free(self.reasoning);
        alloc.free(self.tool_calls);
        for (self.steps) |step| {
            alloc.free(step.tool_calls);
            alloc.free(step.tool_results);
            alloc.free(step.response.id);
            alloc.free(step.response.model);
        }
        alloc.free(self.steps);
        alloc.free(self.response.id);
        alloc.free(self.response.model);
        for (self.messages) |msg| freeMessage(alloc, msg);
        alloc.free(self.messages);
        self.* = .{};
    }
};

pub fn freePart(alloc: std.mem.Allocator, part: Part) void {
    alloc.free(part.text);
    alloc.free(part.url);
    alloc.free(part.media_type);
    alloc.free(part.filename);
    alloc.free(part.detail);
    alloc.free(part.tool_call_id);
    alloc.free(part.tool_name);
    alloc.free(part.tool_input);
    alloc.free(part.tool_output);
    alloc.free(part.signature);
    alloc.free(part.cache_control);
}

pub fn freeMessage(alloc: std.mem.Allocator, msg: Message) void {
    for (msg.parts()) |part| freePart(alloc, part);
    alloc.free(msg.content);
}

pub fn ObjectResult(comptime T: type) type {
    return struct {
        object: T,
        usage: Usage = .{},
        finish_reason: FinishReason = .other,
        response: ResponseMetadata = .{},
        steps: usize = 1,
        arena: std.heap.ArenaAllocator,

        pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            alloc.free(self.response.id);
            alloc.free(self.response.model);
            self.response = .{};
            self.arena.deinit();
        }
    };
}

pub const EmbedResult = struct {
    embeddings: []const []const f64 = &.{},
    usage: Usage = .{},

    pub fn deinit(self: *EmbedResult, alloc: std.mem.Allocator) void {
        for (self.embeddings) |embedding| alloc.free(embedding);
        alloc.free(self.embeddings);
        self.* = .{};
    }
};

pub const ImageData = struct {
    data: []const u8,
    media_type: []const u8,
};

pub const ImageResult = struct {
    images: []const ImageData = &.{},
    usage: Usage = .{},

    pub fn deinit(self: *ImageResult, alloc: std.mem.Allocator) void {
        for (self.images) |image| {
            alloc.free(image.data);
            alloc.free(image.media_type);
        }
        alloc.free(self.images);
        self.* = .{};
    }
};

pub const ToolExecuteFn = *const fn (ctx: ?*anyopaque, input: []const u8) anyerror![]const u8;

pub const Tool = struct {
    name: []const u8,
    description: []const u8 = "",
    input_schema: []const u8 = "{}",
    execute: ?ToolExecuteFn = null,
    execute_ctx: ?*anyopaque = null,

    pub fn run(self: Tool, input: []const u8) anyerror![]const u8 {
        const exec = self.execute orelse return error.ToolHasNoExecute;
        return exec(self.execute_ctx, input);
    }
};

pub const ResponseFormat = struct {
    name: []const u8 = "response",
    schema: []const u8,
};

test "message builders" {
    const m = UserMessage("hi");
    try std.testing.expectEqual(Role.user, m.role);
    try std.testing.expectEqualStrings("hi", m.text());

    const t = ToolMessage("call_1", "weather", "sunny");
    try std.testing.expectEqual(Role.tool, t.role);
    try std.testing.expectEqualStrings("call_1", t.parts()[0].tool_call_id);

    const d = DeveloperMessage("dev");
    try std.testing.expectEqual(Role.developer, d.role);
}

test "usage accumulate" {
    var u = Usage{ .input_tokens = 10, .output_tokens = 5, .total_tokens = 15 };
    u.add(.{ .input_tokens = 3, .output_tokens = 2, .total_tokens = 5 });
    try std.testing.expectEqual(@as(u64, 13), u.input_tokens);
    try std.testing.expectEqual(@as(u64, 7), u.output_tokens);
    try std.testing.expectEqual(@as(u64, 20), u.total_tokens);
}

test "role roundtrip" {
    try std.testing.expectEqual(Role.assistant, Role.fromString("assistant").?);
    try std.testing.expect(Role.fromString("nope") == null);
}
