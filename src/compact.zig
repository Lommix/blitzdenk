const std = @import("std");
const sdk = @import("blitz-sdk");
const agent_run = @import("agent_run.zig");
const models = @import("models");

pub const SUMMARY_SYSTEM_PROMPT =
    \\You are a context summarization assistant. Your task is to read a conversation between a user and an AI assistant, then produce a structured summary following the exact format specified.
    \\
    \\Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.
    \\
;

pub const SUMMARIZATION_PROMPT =
    \\The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.
    \\
    \\Use this EXACT format:
    \\
    \\## Goal
    \\[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]
    \\
    \\## Constraints & Preferences
    \\- [Any constraints, preferences, or requirements mentioned by user]
    \\- [Or "(none)" if none were mentioned]
    \\
    \\## Progress
    \\### Done
    \\- [x] [Completed tasks/changes]
    \\
    \\### In Progress
    \\- [ ] [Current work]
    \\
    \\### Blocked
    \\- [Issues preventing progress, if any]
    \\
    \\## Key Decisions
    \\- **[Decision]**: [Brief rationale]
    \\
    \\## Next Steps
    \\1. [Ordered list of what should happen next]
    \\
    \\## Critical Context
    \\- [Any data, examples, or references needed to continue]
    \\- [Or "(none)" if not applicable]
    \\
    \\Keep each section concise. Preserve exact file paths, function names, and error messages.
    \\
;

pub const SUMMARY_PREFIX =
    \\Another agent started to solve this problem and produced a summary of its thinking process.
    \\You also have access to the state of the tools that were used by that agent.
    \\Use this to build on the work that has already been done and avoid duplicating work.
    \\Here is the summary produced by the other language model, use the information in this summary to assist with your own analysis:
    \\
;

pub const KEEP_RECENT_TOKENS: u64 = 20_000;
pub const TOOL_RESULT_MAX_CHARS: usize = 2000;
pub const RESERVE_TOKENS: u64 = 16_384;
pub const TIMEOUT_MS: u64 = 5 * 60_000;

pub const Reason = enum {
    auto,
    external,
};

pub const State = struct {
    requested: bool = false,
    reason: Reason = .auto,
    estimated_input_tokens: u64 = 0,
    last_compacted_message_count: usize = 0,
    last_compacted_estimate: u64 = 0,
    must_progress_past_message_count: usize = 0,
    continue_after: bool = true,
    completed_continue_after: ?bool = null,

    pub fn request(self: *State, reason: Reason) void {
        self.requested = true;
        self.reason = reason;
    }

    pub fn resetInFlight(self: *State) void {
        self.estimated_input_tokens = 0;
        self.continue_after = true;
    }

    pub fn shouldStart(self: *const State, message_count: usize, estimate: u64, context_limit: u64) bool {
        if (self.must_progress_past_message_count != 0 and message_count <= self.must_progress_past_message_count) return false;
        if (self.requested) return true;
        if (message_count <= 3) return false;
        if (self.last_compacted_message_count == message_count and self.last_compacted_estimate >= autoCompactLimit(context_limit)) return false;
        return estimate >= autoCompactLimit(context_limit);
    }
};

pub const Outcome = struct {
    messages: agent_run.OwnedMessages,
    usage: sdk.Usage,

    pub fn deinit(self: *Outcome) void {
        self.messages.deinit();
        self.* = undefined;
    }
};

pub const Task = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    model: *models.Model,
    tools: []const sdk.Tool,
    messages: []const sdk.Message,
    cancellation: sdk.CancellationToken = .{},
    finished: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(void) = null,
    result: ?Outcome = null,
    failure: ?anyerror = null,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, model: *models.Model, tools: []const sdk.Tool, messages: []const sdk.Message) Task {
        return .{ .alloc = alloc, .io = io, .model = model, .tools = tools, .messages = messages };
    }

    pub fn start(self: *Task) void {
        self.finished.store(false, .release);
        self.future = std.Io.async(self.io, run, .{self});
    }

    pub fn isFinished(self: *const Task) bool {
        return self.finished.load(.acquire);
    }

    pub fn cancel(self: *Task) void {
        self.cancellation.cancel(self.io);
    }

    pub fn wait(self: *Task) void {
        if (self.future) |*future| future.await(self.io);
        self.future = null;
    }

    pub fn takeOutcome(self: *Task) ?Outcome {
        self.wait();
        const result = self.result;
        self.result = null;
        return result;
    }

    pub fn deinit(self: *Task) void {
        self.cancel();
        self.wait();
        if (self.result) |*result| result.deinit();
        self.* = undefined;
    }

    fn run(self: *Task) void {
        defer self.finished.store(true, .release);
        self.result = switch (self.model.*) {
            .response => |*model| compactResponses(self.alloc, self.io, model, self.tools, self.messages, &self.cancellation),
            inline else => |*model| compactOrdinary(self.alloc, self.io, model.languageModel(), self.messages, &self.cancellation),
        } catch |err| {
            self.failure = err;
            return;
        };
    }
};

pub fn autoCompactLimit(context_limit: u64) u64 {
    return context_limit -| RESERVE_TOKENS;
}

pub fn estimateNextRequestTokens(model_id: []const u8, tools: []const sdk.Tool, messages: []const sdk.Message) u64 {
    var bytes: u64 = model_id.len;
    for (tools) |tool| {
        bytes += tool.name.len;
        bytes += tool.description.len;
        bytes += tool.input_schema.len;
    }
    for (messages) |message| bytes += messageBytes(message);
    return approxTokens(bytes);
}

pub fn computeCutIndex(messages: []const sdk.Message) usize {
    var accumulated: u64 = 0;
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        const message = messages[i];
        if (message.role == .system or isSummaryMessage(message)) continue;
        accumulated += approxTokens(messageBytes(message));
        if (accumulated < KEEP_RECENT_TOKENS) continue;
        var cut = i;
        while (cut < messages.len) : (cut += 1) {
            if (isCutPoint(messages[cut])) return cut;
        }
        return 0;
    }
    return 0;
}

pub fn buildCompactPrompt(alloc: std.mem.Allocator, messages: []const sdk.Message, cut_index: usize) ![]const sdk.Message {
    var transcript: std.Io.Writer.Allocating = .init(alloc);
    errdefer transcript.deinit();
    try transcript.writer.writeAll("<conversation>\n");
    for (messages[0..cut_index]) |message| {
        if (message.role == .system) continue;
        try writeMessageForSummary(&transcript.writer, message);
        try transcript.writer.writeAll("\n\n");
    }
    try transcript.writer.writeAll("</conversation>\n\n");
    try transcript.writer.writeAll(SUMMARIZATION_PROMPT);
    const text = try transcript.toOwnedSlice();
    const prompt = try alloc.alloc(sdk.Message, 2);
    prompt[0] = sdk.SystemMessage(SUMMARY_SYSTEM_PROMPT);
    prompt[1] = sdk.UserMessage(text);
    return prompt;
}

pub fn installSummary(alloc: std.mem.Allocator, messages: []const sdk.Message, summary: []const u8) !agent_run.OwnedMessages {
    const cut_index = computeCutIndex(messages);
    var next: std.ArrayList(sdk.Message) = .empty;
    defer next.deinit(alloc);
    if (findSystemMessage(messages)) |system| try next.append(alloc, system);
    for (messages[cut_index..]) |message| {
        if (message.role != .system) try next.append(alloc, message);
    }
    const summary_text = try std.fmt.allocPrint(alloc, "{s}\n{s}", .{ SUMMARY_PREFIX, summary });
    defer alloc.free(summary_text);
    try next.append(alloc, sdk.UserMessage(summary_text));
    return agent_run.OwnedMessages.clone(alloc, next.items);
}

pub fn installResponseParts(alloc: std.mem.Allocator, messages: []const sdk.Message, parts: []const sdk.Part) !agent_run.OwnedMessages {
    var next: std.ArrayList(sdk.Message) = .empty;
    defer next.deinit(alloc);
    if (findSystemMessage(messages)) |system| try next.append(alloc, system);
    try next.append(alloc, .{ .role = .assistant, .content = parts });
    return agent_run.OwnedMessages.clone(alloc, next.items);
}

pub fn compactOrdinary(
    alloc: std.mem.Allocator,
    io: std.Io,
    model: sdk.LanguageModel,
    messages: []const sdk.Message,
    cancellation: ?*sdk.CancellationToken,
) !Outcome {
    const cut_index = computeCutIndex(messages);
    if (cut_index == 0) return error.NothingToCompact;
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const prompt = try buildCompactPrompt(scratch.allocator(), messages, cut_index);
    const result = try sdk.complete(scratch.allocator(), io, model, .{
        .system = SUMMARY_SYSTEM_PROMPT,
        .messages = prompt[1..],
        .max_steps = 1,
        .timeout_ms = TIMEOUT_MS,
        .cancellation = cancellation,
    });
    const summary = if (result.text.len > 0) result.text else summaryFromMessages(result.messages);
    return .{
        .messages = try installSummary(alloc, messages, if (summary.len > 0) summary else "(no summary available)"),
        .usage = result.total_usage,
    };
}

pub fn compactResponses(
    alloc: std.mem.Allocator,
    io: std.Io,
    model: *sdk.responses.Chat,
    tools: []const sdk.Tool,
    messages: []const sdk.Message,
    cancellation: ?*sdk.CancellationToken,
) !Outcome {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const result = try model.compact(scratch.allocator(), io, .{
        .messages = messages,
        .tools = tools,
        .timeout_ms = TIMEOUT_MS,
        .cancellation = cancellation,
    }, null, 2);
    return .{
        .messages = try installResponseParts(alloc, messages, result.parts),
        .usage = result.usage,
    };
}

fn messageBytes(message: sdk.Message) u64 {
    var bytes: u64 = message.role.string().len + 8;
    for (message.parts()) |part| bytes += partBytes(part);
    return bytes;
}

fn partBytes(part: sdk.Part) u64 {
    return switch (part) {
        .text => |text| text.len,
        .reasoning => |reasoning| reasoning.text.len + reasoning.signature.len,
        .image => |image| image.url.len + image.media_type.len + image.detail.len,
        .tool_call => |call| call.id.len + call.name.len + call.input.len,
        .tool_result => |result| result.id.len + result.name.len + result.output.len + 16,
        .file => |file| file.url.len + file.media_type.len + file.filename.len,
        .provider_data => |data| data.provider.len + data.data.len,
    };
}

fn approxTokens(bytes: u64) u64 {
    return @max(1, (bytes + 2) / 3);
}

fn isCutPoint(message: sdk.Message) bool {
    if (message.role == .system or message.role == .tool or isSummaryMessage(message)) return false;
    return true;
}

fn isSummaryMessage(message: sdk.Message) bool {
    for (message.parts()) |part| switch (part) {
        .text => |text| if (std.mem.startsWith(u8, text, SUMMARY_PREFIX)) return true,
        else => {},
    };
    return false;
}

fn findSystemMessage(messages: []const sdk.Message) ?sdk.Message {
    for (messages) |message| if (message.role == .system) return message;
    return null;
}

fn summaryFromMessages(messages: []const sdk.Message) []const u8 {
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        if (messages[i].role != .assistant) continue;
        for (messages[i].parts()) |part| switch (part) {
            .text => |text| if (text.len > 0) return text,
            else => {},
        };
    }
    return "";
}

fn writeMessageForSummary(writer: *std.Io.Writer, message: sdk.Message) !void {
    switch (message.role) {
        .system, .developer => {},
        .user => for (message.parts()) |part| switch (part) {
            .text => |text| {
                if (text.len == 0) continue;
                try writer.writeAll("[User]: ");
                try writer.writeAll(text);
                try writer.writeByte('\n');
            },
            .image => |image| try writer.print("[Image {s}, {d} bytes]\n", .{ image.media_type, image.url.len }),
            .file => |file| try writer.print("[File {s}, {s}]\n", .{ file.filename, file.media_type }),
            else => {},
        },
        .assistant => for (message.parts()) |part| switch (part) {
            .reasoning => |reasoning| {
                if (reasoning.text.len == 0) continue;
                try writer.writeAll("[Assistant thinking]: ");
                try writer.writeAll(reasoning.text);
                try writer.writeByte('\n');
            },
            .text => |text| {
                if (text.len == 0) continue;
                try writer.writeAll("[Assistant]: ");
                try writer.writeAll(text);
                try writer.writeByte('\n');
            },
            .tool_call => |call| try writer.print("[Assistant tool calls]: {s}({s})\n", .{ call.name, call.input }),
            else => {},
        },
        .tool => for (message.parts()) |part| switch (part) {
            .tool_result => |result| try writeToolResult(writer, result),
            else => {},
        },
    }
}

fn writeToolResult(writer: *std.Io.Writer, result: anytype) !void {
    try writer.print("[Tool result {s}{s}]: ", .{ result.name, if (result.is_error) " error" else "" });
    if (result.output.len <= TOOL_RESULT_MAX_CHARS) {
        try writer.writeAll(result.output);
    } else {
        try writer.writeAll(result.output[0..TOOL_RESULT_MAX_CHARS]);
        try writer.print("\n\n[... {d} more characters truncated]", .{result.output.len - TOOL_RESULT_MAX_CHARS});
    }
    try writer.writeByte('\n');
}

test "SDK compaction estimates messages and tools" {
    const estimate = estimateNextRequestTokens("model", &.{.{
        .name = "read",
        .description = "Read a file",
        .input_schema = "{\"type\":\"object\"}",
    }}, &.{sdk.UserMessage("hello")});
    try std.testing.expect(estimate > 1);
}

test "SDK compaction never cuts at a tool result" {
    const big = "x" ** 40_000;
    const messages = [_]sdk.Message{
        sdk.SystemMessage("system"),
        sdk.UserMessage(big),
        .{ .role = .assistant, .single = .{ .tool_call = .{ .id = "c1", .name = "read", .input = "{}" } } },
        sdk.ToolMessage("c1", "read", big),
        sdk.UserMessage("recent instruction"),
    };
    try std.testing.expectEqual(@as(usize, 1), computeCutIndex(&messages));
}

test "SDK compaction prompt preserves structured transcript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const messages = [_]sdk.Message{
        sdk.SystemMessage("agent system prompt"),
        sdk.UserMessage("hello"),
        .{ .role = .assistant, .content = &.{
            .{ .reasoning = .{ .text = "hmm", .signature = "" } },
            .{ .tool_call = .{ .id = "c1", .name = "read", .input = "{\"path\":\"x\"}" } },
        } },
        sdk.ToolMessage("c1", "read", "output"),
    };
    const prompt = try buildCompactPrompt(arena.allocator(), &messages, messages.len);
    try std.testing.expectEqualStrings(SUMMARY_SYSTEM_PROMPT, prompt[0].text());
    const text = prompt[1].text();
    try std.testing.expect(std.mem.indexOf(u8, text, "## Goal") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[User]: hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[Assistant thinking]: hmm") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[Assistant tool calls]: read") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[Tool result read]: output") != null);
}

test "SDK compaction installs summaries and response parts" {
    const messages = [_]sdk.Message{ sdk.SystemMessage("system"), sdk.UserMessage("keep") };
    var summary = try installSummary(std.testing.allocator, &messages, "summary");
    defer summary.deinit();
    try std.testing.expectEqual(@as(usize, 3), summary.messages.len);
    try std.testing.expect(std.mem.endsWith(u8, summary.messages[2].text(), "summary"));

    const parts = [_]sdk.Part{.{ .provider_data = .{ .provider = "openai.responses", .data = "opaque" } }};
    var response = try installResponseParts(std.testing.allocator, &messages, &parts);
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 2), response.messages.len);
    try std.testing.expectEqualStrings("opaque", response.messages[1].parts()[0].provider_data.data);
}

test "ordinary SDK compaction generates and installs a summary" {
    const Fixture = struct {
        fn modelId(_: *anyopaque) []const u8 {
            return "fake";
        }

        fn generate(_: *anyopaque, alloc: std.mem.Allocator, _: std.Io, params: sdk.model.GenerateParams, _: ?*std.http.Client, _: u32) anyerror!*sdk.model.GenerateResult {
            try std.testing.expectEqualStrings(SUMMARY_SYSTEM_PROMPT, params.system);
            try std.testing.expectEqual(@as(usize, 1), params.messages.len);
            const result = try alloc.create(sdk.model.GenerateResult);
            result.* = .{ .text = try alloc.dupe(u8, "generated summary"), .finish_reason = .stop, .usage = .{ .input_tokens = 10, .output_tokens = 2, .total_tokens = 12 } };
            return result;
        }

        fn stream(ctx: *anyopaque, alloc: std.mem.Allocator, io: std.Io, params: sdk.model.GenerateParams, client: ?*std.http.Client, retries: u32, _: *sdk.model.StreamContext) anyerror!*sdk.model.GenerateResult {
            return generate(ctx, alloc, io, params, client, retries);
        }
    };

    const big = "x" ** 70_000;
    const messages = [_]sdk.Message{ sdk.SystemMessage("system"), sdk.UserMessage(big), sdk.UserMessage("recent") };
    var fixture: u8 = 0;
    const vtable = sdk.model.ModelVTable{ .model_id = Fixture.modelId, .generate = Fixture.generate, .stream = Fixture.stream };
    var outcome = try compactOrdinary(std.testing.allocator, std.testing.io, .{ .ctx = &fixture, .vtable = &vtable }, &messages, null);
    defer outcome.deinit();
    try std.testing.expectEqual(@as(u64, 12), outcome.usage.total_tokens);
    try std.testing.expect(std.mem.endsWith(u8, outcome.messages.messages[outcome.messages.messages.len - 1].text(), "generated summary"));
}
