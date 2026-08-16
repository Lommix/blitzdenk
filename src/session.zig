const std = @import("std");

const r = @import("root.zig");
const app = @import("app.zig");
const util = @import("util.zig");
const sdk = @import("blitz-sdk");
const agent_run = @import("agent_run.zig");

pub const WireRole = enum { system, user, agent };

pub const WireImage = struct {
    media_type: []const u8,
    data: []const u8,
};

pub const WirePart = union(enum) {
    text: []const u8,
    thinking: struct {
        text: []const u8,
        signature: ?[]const u8 = null,
    },
    image: WireImage,
    tool_call: struct {
        id: []const u8,
        name: []const u8,
        arguments: []const u8,
    },
    tool_result: struct {
        call_id: []const u8,
        name: []const u8,
        content: []const u8,
        image: ?WireImage = null,
        is_error: bool = false,
        exit_loop: bool = false,
        comp_strat: enum { truncate, keep, summarize } = .truncate,
    },
};

pub const WireMessage = struct {
    role: WireRole,
    parts: []const WirePart,
    provider_items: []const []const u8 = &.{},
    flags: struct {
        allow_export: bool = true,
    } = .{},
    time_ms: i64 = 0,
};

pub fn decodeMessages(alloc: std.mem.Allocator, json: []const u8) !agent_run.OwnedMessages {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();
    const parsed = try std.json.parseFromSlice([]const WireMessage, scratch, json, .{ .ignore_unknown_fields = true });
    const messages = try scratch.alloc(sdk.Message, parsed.value.len);
    for (parsed.value, messages) |wire, *message| message.* = try decodeMessage(scratch, wire);
    return agent_run.OwnedMessages.clone(alloc, messages);
}

pub fn encodeMessages(alloc: std.mem.Allocator, messages: []const sdk.Message, writer: *std.Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();
    const wire = try scratch.alloc(WireMessage, messages.len);
    for (messages, wire) |message, *output| output.* = try encodeMessage(scratch, message);
    try std.json.Stringify.value(wire, .{}, writer);
}

fn decodeMessage(alloc: std.mem.Allocator, wire: WireMessage) !sdk.Message {
    var parts: std.ArrayList(sdk.Part) = .empty;
    for (wire.parts) |part| switch (part) {
        .text => |text| try parts.append(alloc, .{ .text = text }),
        .thinking => |thinking| try parts.append(alloc, .{ .reasoning = .{
            .text = thinking.text,
            .signature = thinking.signature orelse "",
        } }),
        .image => |image| try parts.append(alloc, .{ .image = .{
            .url = try std.fmt.allocPrint(alloc, "data:{s};base64,{s}", .{ image.media_type, image.data }),
            .media_type = image.media_type,
        } }),
        .tool_call => |call| try parts.append(alloc, .{ .tool_call = .{
            .id = call.id,
            .name = call.name,
            .input = call.arguments,
        } }),
        .tool_result => |result| {
            try parts.append(alloc, .{ .tool_result = .{
                .id = result.call_id,
                .name = result.name,
                .output = result.content,
                .is_error = result.is_error,
                .exit_loop = result.exit_loop,
            } });
            if (result.image) |image| try parts.append(alloc, .{ .image = .{
                .url = try std.fmt.allocPrint(alloc, "data:{s};base64,{s}", .{ image.media_type, image.data }),
                .media_type = image.media_type,
            } });
        },
    };
    for (wire.provider_items) |item| try parts.append(alloc, .{ .provider_data = .{
        .provider = "openai.responses",
        .data = item,
    } });
    return .{
        .role = switch (wire.role) {
            .system => .system,
            .user => if (hasToolResult(parts.items)) .tool else .user,
            .agent => .assistant,
        },
        .content = try parts.toOwnedSlice(alloc),
    };
}

fn hasToolResult(parts: []const sdk.Part) bool {
    for (parts) |part| if (part == .tool_result) return true;
    return false;
}

fn encodeMessage(alloc: std.mem.Allocator, message: sdk.Message) !WireMessage {
    var parts: std.ArrayList(WirePart) = .empty;
    var provider_items: std.ArrayList([]const u8) = .empty;
    const source = message.parts();
    var i: usize = 0;
    while (i < source.len) : (i += 1) switch (source[i]) {
        .text => |text| try parts.append(alloc, .{ .text = text }),
        .reasoning => |reasoning| try parts.append(alloc, .{ .thinking = .{
            .text = reasoning.text,
            .signature = if (reasoning.signature.len > 0) reasoning.signature else null,
        } }),
        .image => |image| try parts.append(alloc, .{ .image = try encodeImage(image) }),
        .tool_call => |call| try parts.append(alloc, .{ .tool_call = .{
            .id = call.id,
            .name = call.name,
            .arguments = call.input,
        } }),
        .tool_result => |result| {
            var image: ?WireImage = null;
            if (i + 1 < source.len and source[i + 1] == .image) {
                image = try encodeImage(source[i + 1].image);
                i += 1;
            }
            try parts.append(alloc, .{ .tool_result = .{
                .call_id = result.id,
                .name = result.name,
                .content = result.output,
                .image = image,
                .is_error = result.is_error,
                .exit_loop = result.exit_loop,
            } });
        },
        .file => |file| try parts.append(alloc, .{ .text = try std.fmt.allocPrint(alloc, "[File {s}, {s}: {s}]", .{ file.filename, file.media_type, file.url }) }),
        .provider_data => |data| if (std.mem.eql(u8, data.provider, "openai.responses")) try provider_items.append(alloc, data.data),
    };
    return .{
        .role = switch (message.role) {
            .system, .developer => .system,
            .user, .tool => .user,
            .assistant => .agent,
        },
        .parts = try parts.toOwnedSlice(alloc),
        .provider_items = try provider_items.toOwnedSlice(alloc),
    };
}

fn encodeImage(image: anytype) !WireImage {
    const prefix = "data:";
    if (!std.mem.startsWith(u8, image.url, prefix)) return error.UnsupportedSessionImageUrl;
    const separator = std.mem.indexOf(u8, image.url, ";base64,") orelse return error.UnsupportedSessionImageUrl;
    return .{
        .media_type = image.url[prefix.len..separator],
        .data = image.url[separator + ";base64,".len ..],
    };
}

pub const SaveState = struct {
    chat: []const WireMessage,
    chat_render: []const app.ChatEntry,
};

pub fn saveSession(a: *const app.App, w: *std.Io.Writer) !void {
    const agent = a.mainAgent() orelse return error.NoActiveSessionToSave;

    var arena = std.heap.ArenaAllocator.init(a.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    var out: std.ArrayList(WireMessage) = .empty;
    for (agent.history()) |message| {
        if (isReminder(message)) continue;
        try out.append(alloc, try encodeMessage(alloc, message));
    }

    const save = SaveState{
        .chat = out.items,
        .chat_render = a.chat_entries.items,
    };

    try std.json.Stringify.value(save, .{}, w);
    try w.flush();
}

fn isReminder(message: sdk.Message) bool {
    return message.role == .user and std.mem.startsWith(u8, message.text(), "<system-reminder>");
}

pub fn loadSession(a: *app.App, w: *std.Io.Reader) !void {
    const alloc = a.appAlloc();
    const session_alloc = a.sessionAlloc();

    a.reset();

    var json_reader = std.json.Reader.init(alloc, w);
    defer json_reader.deinit();

    const parsed = try std.json.parseFromTokenSource(SaveState, alloc, &json_reader, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const save = parsed.value;

    const id = a.registry.reserve() orelse return error.RegistryFull;
    errdefer a.registry.releaseReservation(id);
    const model_config = switch (a.context_factory.buildAgentApiConfig(.general, &a.config, a.exec_pool.env)) {
        .config => |config| config,
        .diagnostic => return error.InvalidProviderConfiguration,
    };
    const agent = try a.registry.activate(id, model_config, .{ .identity = .{
        .type_idx = @intFromEnum(r.ContextFactory.AgentType.general),
        .mode_idx = @intFromEnum(a.mode),
        .name = a.context_factory.agentName(.general),
        .cwd = a.cwd,
    }, .context_limit = a.default_context_limit });
    errdefer a.registry.release(id);
    try a.configureAgent(id, agent);

    const messages = try session_alloc.alloc(sdk.Message, save.chat.len);
    for (save.chat, messages) |wire, *message| message.* = try decodeMessage(session_alloc, wire);
    try agent.setMessages(messages);

    for (save.chat_render) |entry| {
        const cloned = try util.deepClone(app.ChatEntry, entry, session_alloc);
        try a.appendChatEntry(session_alloc, cloned);
    }

    a.main_agent_id = id;
    a.dirty = true;
    a.running = false;
}

test "old session messages decode into SDK history" {
    const json =
        \\[
        \\  {"role":"system","parts":[{"text":"system"}],"flags":{"allow_export":true},"time_ms":1},
        \\  {"role":"agent","parts":[{"thinking":{"text":"reason","signature":"sig"}},{"tool_call":{"id":"c1","name":"read","arguments":"{}"}}],"provider_items":["{\"type\":\"reasoning\"}"]},
        \\  {"role":"user","parts":[{"tool_result":{"call_id":"c1","name":"read","content":"done","is_error":false,"exit_loop":true,"comp_strat":"keep","image":{"media_type":"image/png","data":"aW1n"}}}]}
        \\]
    ;
    var messages = try decodeMessages(std.testing.allocator, json);
    defer messages.deinit();
    try std.testing.expectEqual(@as(usize, 3), messages.messages.len);
    try std.testing.expectEqual(sdk.Role.system, messages.messages[0].role);
    try std.testing.expectEqual(sdk.Role.assistant, messages.messages[1].role);
    try std.testing.expectEqual(sdk.Role.tool, messages.messages[2].role);
    try std.testing.expectEqualStrings("reason", messages.messages[1].parts()[0].reasoning.text);
    try std.testing.expectEqualStrings("{}", messages.messages[1].parts()[1].tool_call.input);
    try std.testing.expectEqualStrings("{\"type\":\"reasoning\"}", messages.messages[1].parts()[2].provider_data.data);
    try std.testing.expect(messages.messages[2].parts()[0].tool_result.exit_loop);
    try std.testing.expectEqualStrings("data:image/png;base64,aW1n", messages.messages[2].parts()[1].image.url);
}

test "SDK history encodes with the old session message layout" {
    const messages = [_]sdk.Message{
        sdk.SystemMessage("system"),
        .{ .role = .assistant, .content = &.{
            .{ .reasoning = .{ .text = "reason", .signature = "sig" } },
            .{ .tool_call = .{ .id = "c1", .name = "read", .input = "{}" } },
            .{ .provider_data = .{ .provider = "openai.responses", .data = "opaque" } },
        } },
        .{ .role = .tool, .content = &.{
            .{ .tool_result = .{ .id = "c1", .name = "read", .output = "done", .exit_loop = true } },
            .{ .image = .{ .url = "data:image/png;base64,aW1n", .media_type = "image/png" } },
        } },
    };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try encodeMessages(std.testing.allocator, &messages, &output.writer);
    const parsed = try std.json.parseFromSlice([]const WireMessage, std.testing.allocator, output.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(WireRole.agent, parsed.value[1].role);
    try std.testing.expectEqualStrings("{}", parsed.value[1].parts[1].tool_call.arguments);
    try std.testing.expectEqualStrings("opaque", parsed.value[1].provider_items[0]);
    try std.testing.expectEqual(WireRole.user, parsed.value[2].role);
    try std.testing.expectEqualStrings("aW1n", parsed.value[2].parts[0].tool_result.image.?.data);
}
