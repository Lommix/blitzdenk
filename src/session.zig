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

fn decodeMessages(alloc: std.mem.Allocator, json: []const u8) !agent_run.OwnedMessages {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();
    const parsed = try std.json.parseFromSlice([]const WireMessage, scratch, json, .{ .ignore_unknown_fields = true });
    const messages = try scratch.alloc(sdk.Message, parsed.value.len);
    for (parsed.value, messages) |wire, *message| message.* = try decodeMessage(scratch, wire);
    return agent_run.OwnedMessages.clone(alloc, messages);
}

fn encodeMessages(alloc: std.mem.Allocator, messages: []const sdk.Message, writer: *std.Io.Writer) !void {
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
        .text => |text| try parts.append(alloc, .{ .text = try util.sanitizeUtf8(alloc, text) }),
        .reasoning => |reasoning| try parts.append(alloc, .{ .thinking = .{
            .text = try util.sanitizeUtf8(alloc, reasoning.text),
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
                .content = try util.sanitizeUtf8(alloc, result.output),
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
    /// Packed id of the main agent at save time. `tool_status.agent == null`
    /// entries belong to it; on apply both those entries and the chat_render
    /// tool_call stamps carrying this id are re-keyed to the fresh id.
    main_agent: ?u32 = null,
    /// Rich per-call status lines (styled label + result flag + child link)
    /// so restored call blocks don't degrade to the plain tool name.
    /// `agent == null` entries belong to the main agent; child agents keep
    /// their packed id.
    tool_status: []const WireToolStatus = &.{},
};

pub const WireToolStatus = struct {
    agent: ?u32 = null,
    call_id: []const u8,
    ansi: []const u8 = "",
    is_error: ?bool = null,
    child: ?u32 = null,
};

test "encodeMessage replaces invalid UTF-8 so saved sessions stay loadable" {
    const messages = [_]sdk.Message{
        .{ .role = .tool, .content = &.{
            .{ .tool_result = .{ .id = "c1", .name = "search", .output = "\xe5\x8f\xe5..." } },
        } },
    };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try encodeMessages(std.testing.allocator, &messages, &output.writer);
    const parsed = try std.json.parseFromSlice([]const WireMessage, std.testing.allocator, output.written(), .{});
    defer parsed.deinit();
    const content = parsed.value[0].parts[0].tool_result.content;
    try std.testing.expectStringEndsWith(content, "...");
    try std.testing.expect(std.unicode.utf8ValidateSlice(content));
}

/// Encodes the current session into a `SaveState`; `alloc` must outlive the
/// returned value (callers typically use an arena). Reminders are skipped.
pub fn buildSaveState(a: *app.App, agent: *const r.agent.Agent, alloc: std.mem.Allocator) !SaveState {
    var out: std.ArrayList(WireMessage) = .empty;
    for (agent.history()) |message| {
        if (isReminder(message)) continue;
        try out.append(alloc, try encodeMessage(alloc, message));
    }
    return .{
        .chat = out.items,
        .chat_render = a.chat_entries.items,
        .main_agent = if (a.main_agent_id) |main| main.pack() else null,
        .tool_status = try encodeToolStatus(a, alloc),
    };
}

/// Serializes the tool status table. The main agent's entries are stored with
/// `agent == null` (its id changes across apply); child agents keep their
/// packed id. Entries whose ANSI text is empty and that carry no flags are
/// skipped — the plain tool_name fallback is equivalent for those.
fn encodeToolStatus(a: *app.App, alloc: std.mem.Allocator) ![]const WireToolStatus {
    const main_pack = a.main_agent_id orelse return &.{};
    var out: std.ArrayList(WireToolStatus) = .empty;
    const g = a.tool_status_entries.lock(a.io);
    defer g.unlock();
    for (&g.ptr.agents, 0..) |*status_agent, index| {
        if (status_agent.entries.count() == 0) continue;
        const id = r.AgentId{ .index = @intCast(index), .generation = status_agent.generation };
        const agent_key: ?u32 = if (id.pack() == main_pack.pack()) null else id.pack();
        var it = status_agent.entries.iterator();
        while (it.next()) |slot| {
            const entry = slot.value_ptr.*;
            if (entry.lines.items.len == 0 and entry.is_error == null and entry.child_id == null) continue;
            try out.append(alloc, .{
                .agent = agent_key,
                .call_id = slot.key_ptr.*,
                .ansi = try linesToAnsi(entry.lines.items, alloc),
                .is_error = entry.is_error,
                .child = if (entry.child_id) |child| child.pack() else null,
            });
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Renders styled lines back to an ANSI string — the same representation
/// `App.setToolStatus` consumes via `Text.fromAnsi`.
fn linesToAnsi(lines: []const r.tui.Line, alloc: std.mem.Allocator) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var prev_style: ?r.tui.Style = null;
    for (lines, 0..) |line, line_idx| {
        if (line_idx > 0) try out.writer.writeByte('\n');
        for (line.spans.items) |span| {
            if (prev_style == null or !prev_style.?.eql(span.style)) {
                try span.style.writeAnsi(&out.writer);
                prev_style = span.style;
            }
            try out.writer.writeAll(span.content);
        }
    }
    return out.toOwnedSlice();
}

pub fn isReminderText(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "<system-reminder>");
}

fn isReminder(message: sdk.Message) bool {
    return message.role == .user and isReminderText(message.text());
}

/// Applies an already-parsed snapshot onto the app: rebuilds the main agent
/// from `save.chat` and replays the rendered chat entries.
pub fn applySaveState(a: *app.App, save: *const SaveState) !void {
    const session_alloc = a.sessionAlloc();

    const id = a.registry.reserve() orelse return error.RegistryFull;
    errdefer a.registry.releaseReservation(id);
    const model_config = switch (a.context_factory.buildAgentApiConfig(.general, &a.config, a.exec_pool.env)) {
        .config => |config| config,
        .diagnostic => return error.InvalidProviderConfiguration,
    };
    const agent = try a.registry.activate(id, model_config, .{ .identity = .{
        .type_idx = @intFromEnum(r.ContextFactory.AgentType.general),
        .name = a.context_factory.agentName(.general),
        .cwd = a.cwd,
    }, .context_limit = a.default_context_limit });
    errdefer a.registry.release(id);
    try a.configureAgent(id, agent);

    const messages = try session_alloc.alloc(sdk.Message, save.chat.len);
    for (save.chat, messages) |wire, *message| message.* = try decodeMessage(session_alloc, wire);
    try agent.setMessages(messages);

    // Re-key restored tool_call stamps: the main agent's id changed across
    // the save/load boundary, and the renderer looks statuses up by the id
    // embedded in the chat entry. Child ids are kept as-is — the per-slot
    // generation reset in setToolStatus/setToolChild makes their old-gen
    // lookups match again.
    for (save.chat_render) |*entry| {
        for (entry.parts) |*part| switch (part.*) {
            .tool_call => |*call| {
                if (save.main_agent) |main| {
                    if (call.agent_id.pack() == main) call.agent_id = id;
                }
            },
            else => {},
        };
        try a.appendChatEntry(session_alloc, entry.*);
    }

    // Restore rich call-block status, keyed to the fresh agent ids.
    for (save.tool_status) |status| {
        const agent_id: r.AgentId = if (status.agent) |packed_id| .unpack(packed_id) else id;
        if (agent_id.index >= r.agent_registry.max_agents) continue;
        if (status.ansi.len > 0) a.setToolStatus(agent_id, status.call_id, status.ansi) catch {};
        if (status.is_error) |is_error| a.setToolResult(agent_id, status.call_id, is_error) catch {};
        if (status.child) |child| a.setToolChild(agent_id, status.call_id, .unpack(child)) catch {};
    }

    a.main_agent_id = id;
    a.registry.pin(id);
    a.registry.slots[id.index].state.store(.complete, .release);
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

test "tool status roundtrips through WireToolStatus with re-keyed main agent" {
    const testing = std.testing;

    // linesToAnsi -> fromAnsi preserves styled multi-line content.
    var line = r.tui.Line{};
    defer line.deinit(testing.allocator);
    try line.pushSpan(testing.allocator, .{ .content = "MCP fetch", .style = .{ .fg = .blue, .modifier = .{ .bold = true } } });
    try line.pushSpan(testing.allocator, .{ .content = " 2 T/s", .style = .{ .fg = .cyan } });
    var second = r.tui.Line{};
    defer second.deinit(testing.allocator);
    try second.pushSpan(testing.allocator, .{ .content = "running", .style = .{ .fg = .green } });
    const lines = [_]r.tui.Line{ line, second };

    const ansi = try linesToAnsi(&lines, testing.allocator);
    defer testing.allocator.free(ansi);
    var reparsed = try r.tui.Text.fromAnsi(testing.allocator, ansi);
    defer reparsed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), reparsed.lines.items.len);
    try testing.expectEqualStrings("MCP fetch", reparsed.lines.items[0].spans.items[0].content);
    try testing.expect(reparsed.lines.items[0].spans.items[0].style.modifier.bold);
    try testing.expectEqualStrings("running", reparsed.lines.items[1].spans.items[0].content);

    // SaveState JSON roundtrip keeps all fields.
    const save = SaveState{
        .chat = &.{},
        .chat_render = &.{},
        .tool_status = &.{
            .{ .call_id = "call_1", .ansi = ansi, .is_error = false },
            blk: {
                const agent: r.AgentId = .{ .index = 3, .generation = 7 };
                const child: r.AgentId = .{ .index = 4, .generation = 1 };
                break :blk WireToolStatus{ .agent = agent.pack(), .call_id = "call_2", .child = child.pack() };
            },
        },
    };
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try std.json.Stringify.value(save, .{}, &output.writer);
    const parsed = try std.json.parseFromSlice(SaveState, testing.allocator, output.written(), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.tool_status.len);
    try testing.expect(parsed.value.tool_status[0].agent == null);
    try testing.expectEqual(false, parsed.value.tool_status[0].is_error.?);
    try testing.expectEqualStrings("call_2", parsed.value.tool_status[1].call_id);
    try testing.expectEqual((r.AgentId{ .index = 3, .generation = 7 }).pack(), parsed.value.tool_status[1].agent.?);
    try testing.expectEqual((r.AgentId{ .index = 4, .generation = 1 }).pack(), parsed.value.tool_status[1].child.?);
}
