const std = @import("std");

const r = @import("root.zig");
const app = @import("app.zig");
const util = @import("util.zig");
const sdk = @import("blitz-sdk");
const models = @import("models");
const agent_run = @import("agent_run.zig");

const log = std.log.scoped(.session);

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
    timeline: []const app.TimelineEntry,
    /// Packed id of the main agent at save time. `tool_status.agent == null`
    /// entries belong to it; on apply both those entries and the timeline
    /// tool_call stamps carrying this id are re-keyed to the fresh id.
    main_agent: ?u32 = null,
    clean: bool = false,
    /// Rich per-call status lines (styled label + result flag + child link)
    /// so restored call blocks don't degrade to the plain tool name.
    /// `agent == null` entries belong to the main agent; child agents keep
    /// their packed id.
    tool_status: []const WireToolStatus = &.{},
    agents: []const WireAgent = &.{},
};

pub const WireAgent = struct {
    id: u32,
    type_idx: u8 = 0,
    name: []const u8 = "",
    task_description: []const u8 = "",
    parent: ?u32 = null,
    depth: u16 = 0,
    cwd: []const u8 = "",
    background: bool = false,
    clean: bool = false,
    chat: []const WireMessage = &.{},
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
    return .{
        .chat = try encodeChat(agent.history(), alloc),
        .timeline = a.timeline.items,
        .main_agent = if (a.main_agent_id) |main| main.pack() else null,
        .clean = agent.clean,
        .tool_status = try encodeToolStatus(a, alloc),
        .agents = try encodeAgents(a, alloc),
    };
}

fn encodeChat(history: []const sdk.Message, alloc: std.mem.Allocator) ![]const WireMessage {
    var out: std.ArrayList(WireMessage) = .empty;
    for (history) |message| {
        if (isReminder(message)) continue;
        try out.append(alloc, try encodeMessage(alloc, message));
    }
    return out.toOwnedSlice(alloc);
}

fn encodeAgents(a: *app.App, alloc: std.mem.Allocator) ![]const WireAgent {
    var out: std.ArrayList(WireAgent) = .empty;
    for (&a.registry.slots, 0..) |*slot, index| {
        switch (slot.state.load(.acquire)) {
            .free, .reserved => continue,
            .active, .complete, .failed => {},
        }
        const agent = if (slot.agent) |*value| value else continue;
        const id = r.AgentId{ .index = @intCast(index), .generation = slot.generation };
        if (a.main_agent_id) |main| {
            if (id.pack() == main.pack()) continue;
        }
        const chat = try encodeChat(agent.history(), alloc);
        if (chat.len == 0) continue;
        try out.append(alloc, .{
            .id = id.pack(),
            .type_idx = agent.type_idx,
            .name = agent.name,
            .task_description = agent.task_description,
            .parent = agent.parent,
            .depth = agent.depth,
            .cwd = agent.cwd,
            .background = agent.background,
            .clean = agent.clean,
            .chat = chat,
        });
    }
    return out.toOwnedSlice(alloc);
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
/// from `save.chat` and replays the rendered timeline entries.
pub fn applySaveState(a: *app.App, save: *const SaveState) !void {
    const session_alloc = a.sessionAlloc();

    const main_id = try restoreMain(a, save, session_alloc);
    var restored: std.ArrayList(u32) = .empty;
    errdefer {
        a.registry.release(main_id);
        for (restored.items) |packed_id| {
            if (packed_id == main_id.pack()) continue;
            a.registry.release(r.AgentId.unpack(packed_id));
        }
    }

    for (save.agents) |*entry| {
        restoreSubAgent(a, entry, session_alloc) catch |err| {
            log.warn("session agent {d} not restored: {s}", .{ entry.id, @errorName(err) });
            continue;
        };
        try restored.append(session_alloc, entry.id);
    }
    nullMissingParents(a, main_id, save);

    // Re-key restored tool_call stamps: the main agent's id changed across
    // the save/load boundary, and the renderer looks statuses up by the id
    // embedded in the timeline entry. Child ids are kept as-is — the per-slot
    // generation reset in setToolStatus/setToolChild makes their old-gen
    // lookups match again.
    for (save.timeline) |*entry| {
        for (entry.parts) |*part| switch (part.*) {
            .tool_call => |*call| {
                if (save.main_agent) |main| {
                    if (call.agent_id.pack() == main) call.agent_id = main_id;
                }
            },
            else => {},
        };
        try a.appendTimelineEntry(session_alloc, entry.*);
    }

    // Restore rich call-block status, keyed to the fresh agent ids.
    for (save.tool_status) |status| {
        const agent_id: r.AgentId = if (status.agent) |packed_id| .unpack(packed_id) else main_id;
        if (agent_id.index >= r.agent_registry.max_agents) continue;
        if (status.ansi.len > 0) a.setToolStatus(agent_id, status.call_id, status.ansi) catch {};
        if (status.is_error) |is_error| a.setToolResult(agent_id, status.call_id, is_error) catch {};
        if (status.child) |child| a.setToolChild(agent_id, status.call_id, .unpack(child)) catch {};
    }

    a.main_agent_id = main_id;
    a.registry.pin(main_id);
    a.registry.slots[main_id.index].state.store(.complete, .release);
    a.dirty = true;
    a.running = false;
}

fn restoreMain(a: *app.App, save: *const SaveState, alloc: std.mem.Allocator) !r.AgentId {
    const options: r.agent.InitOptions = .{ .identity = .{
        .type_idx = @intFromEnum(r.ContextFactory.AgentType.general),
        .name = a.context_factory.agentName(.general),
        .cwd = a.cwd,
        .clean = save.clean,
    }, .context_limit = a.default_context_limit };
    const model_config = try mainModelConfig(a);
    const Claimed = struct { id: r.AgentId, agent: *r.agent.Agent };
    const claimed: Claimed = if (save.main_agent) |packed_main| claimed: {
        const id = r.AgentId.unpack(packed_main);
        break :claimed .{ .id = id, .agent = try a.registry.restoreAt(id, model_config, options) };
    } else claimed: {
        const id = a.registry.reserve(null) orelse return error.RegistryFull;
        errdefer a.registry.releaseReservation(id);
        break :claimed .{ .id = id, .agent = try a.registry.activate(id, model_config, options) };
    };
    errdefer a.registry.release(claimed.id);
    try a.configureAgent(claimed.id, claimed.agent);
    try setRestoredChat(claimed.agent, save.chat, alloc);
    return claimed.id;
}

fn mainModelConfig(a: *app.App) !models.Config {
    return switch (a.context_factory.buildAgentApiConfig(.general, &a.config, a.exec_pool.env)) {
        .config => |config| config,
        .diagnostic => error.InvalidProviderConfiguration,
    };
}

fn restoreSubAgent(a: *app.App, entry: *const WireAgent, alloc: std.mem.Allocator) !void {
    if (entry.type_idx > std.math.maxInt(u6)) return error.UnknownAgentType;
    const model_config = switch (a.context_factory.buildAgentApiConfig(@enumFromInt(@as(u6, @intCast(entry.type_idx))), &a.config, a.exec_pool.env)) {
        .config => |config| config,
        .diagnostic => return error.InvalidProviderConfiguration,
    };
    const id = r.AgentId.unpack(entry.id);
    const agent = try a.registry.restoreAt(id, model_config, .{ .identity = .{
        .type_idx = entry.type_idx,
        .name = entry.name,
        .task_description = entry.task_description,
        .parent = entry.parent,
        .depth = @min(entry.depth, r.agent_registry.max_agents),
        .cwd = entry.cwd,
        .clean = entry.clean,
    }, .context_limit = a.default_context_limit });
    errdefer a.registry.release(id);
    agent.background = entry.background;
    try setRestoredChat(agent, entry.chat, alloc);
    try a.configureAgent(id, agent);
    a.registry.slots[id.index].state.store(.complete, .release);
}

fn setRestoredChat(agent: *r.agent.Agent, chat: []const WireMessage, alloc: std.mem.Allocator) !void {
    const messages = try alloc.alloc(sdk.Message, chat.len);
    for (chat, messages) |wire, *message| message.* = try decodeMessage(alloc, wire);
    try agent.setMessages(messages);
}

fn nullMissingParents(a: *app.App, main_id: r.AgentId, save: *const SaveState) void {
    const main_pack = main_id.pack();
    for (save.agents) |*entry| {
        const id = r.AgentId.unpack(entry.id);
        const agent = a.registry.get(id) orelse continue;
        defer a.registry.slots[id.index].parent = agent.parent;
        const parent = agent.parent orelse continue;
        if (parent == main_pack) continue;
        const parent_agent = a.registry.get(r.AgentId.unpack(parent)) orelse {
            agent.parent = null;
            continue;
        };
        if (parent_agent.depth >= agent.depth) agent.parent = null;
    }
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
        .timeline = &.{},
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

const SessionTestRig = struct {
    io_state: std.Io.Threaded,
    env: std.process.Environ.Map,
    pool: r.exec.CmdPool,
    factory: r.ContextFactory,
    registry: r.agent_registry.Registry,
    cfg: r.config.BlitzdenkCfg,
    a: app.App,

    fn init(self: *SessionTestRig) !void {
        self.io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
        const io = self.io_state.io();
        self.env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
        self.pool = r.exec.CmdPool.init(std.testing.allocator, io, &self.env);
        self.factory = .{
            .alloc = std.testing.allocator,
            .prompt_arena = std.heap.ArenaAllocator.init(std.testing.allocator),
            .capability_arena = std.heap.ArenaAllocator.init(std.testing.allocator),
            .io = io,
            .config_dir = null,
            .skill_dir = null,
        };
        self.factory.resetDefs();
        self.cfg = .{};
        _ = self.cfg.reserveProvider("http://localhost:8080/v1", "", "").?;
        const provider = self.cfg.commitProvider();
        const model = try self.cfg.addModel(.{ .name = "local-model", .provider = provider });
        try self.factory.setAgentModel(&self.cfg, .general, model);
        self.registry = r.agent_registry.Registry.init(std.testing.allocator, io);

        self.a = undefined;
        self.a.io = io;
        self.a.gpa = std.testing.allocator;
        self.a.arena_session = .init(std.testing.allocator);
        self.a.arena_streaming_preview = .init(std.testing.allocator);
        self.a.arena_streaming_snapshot = .init(std.testing.allocator);
        self.a.registry = &self.registry;
        self.a.context_factory = &self.factory;
        self.a.config = self.cfg;
        self.a.exec_pool = &self.pool;
        self.a.cwd = "/tmp/blitzdenk-persist";
        self.a.default_context_limit = app.CONTEXT_LIMIT;
        self.a.lua_reload_generation = .init(0);
        self.a.timeline = .empty;
        self.a.tool_status_entries = .{};
        self.a.pending_diffs = .{};
        self.a.streaming_entry = null;
        self.a.main_agent_id = null;
        self.a.event_bus = .{};
        self.a.session_store = null;
        self.a.dirty = false;
        self.a.running = false;
    }

    fn deinit(self: *SessionTestRig) void {
        self.registry.deinit();
        self.pool.deinit();
        self.env.deinit();
        self.factory.prompt_arena.deinit();
        self.factory.capability_arena.deinit();
        self.a.arena_session.deinit();
        self.a.arena_streaming_preview.deinit();
        self.a.arena_streaming_snapshot.deinit();
        self.io_state.deinit();
    }

    fn spawn(self: *SessionTestRig, name: []const u8, task: []const u8, parent: ?r.AgentId, background: bool, messages: []const sdk.Message) !r.AgentId {
        const model_config = switch (self.factory.buildAgentApiConfig(.general, &self.cfg, self.pool.env)) {
            .config => |config| config,
            .diagnostic => return error.InvalidProviderConfiguration,
        };
        const id = self.registry.reserve(parent) orelse return error.RegistryFull;
        const agent = try self.registry.activate(id, model_config, .{ .identity = .{
            .type_idx = @intFromEnum(r.ContextFactory.AgentType.general),
            .name = name,
            .task_description = task,
            .parent = if (parent) |p| p.pack() else null,
            .depth = if (parent != null) 1 else 0,
            .cwd = self.a.cwd,
        }, .context_limit = self.a.default_context_limit });
        agent.background = background;
        try self.a.configureAgent(id, agent);
        if (messages.len > 0) try agent.setMessages(messages);
        return id;
    }
};

test "sub-agents survive a checkpoint, journal round-trip, and resume with frozen ids" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = std.Io.Dir{ .handle = tmp.dir.handle };

    var rig: SessionTestRig = undefined;
    try rig.init();
    defer rig.deinit();

    const main_id = try rig.spawn("main", "", null, false, &.{
        sdk.UserMessage("plan the work"),
        sdk.AssistantMessage("spawning helpers"),
    });
    rig.a.main_agent_id = main_id;
    rig.registry.pin(main_id);
    rig.registry.slots[main_id.index].state.store(.complete, .release);

    const child_id = try rig.spawn("child", "fix the bug", main_id, false, &.{
        sdk.UserMessage("fix the bug"),
        sdk.AssistantMessage("done fixing"),
    });
    const bg_id = try rig.spawn("scout", "watch the logs", null, true, &.{
        sdk.UserMessage("watch the logs"),
        sdk.AssistantMessage("log stable"),
    });
    _ = try rig.spawn("empty", "", null, false, &.{});

    const alloc = rig.a.sessionAlloc();
    const parts = try alloc.alloc(app.TimelinePart, 1);
    parts[0] = .{ .tool_call = .{
        .agent_id = child_id,
        .call_id = "call_spawn_child",
        .tool_name = "agent",
    } };
    try rig.a.appendTimelineEntry(alloc, .{ .role = .agent, .parts = parts });
    try rig.a.setToolStatus(child_id, "call_spawn_child", "agent tool line");

    var store = r.session_store.Store{ .io = rig.a.io, .gpa = testing.allocator, .base = base };
    defer store.deinit();
    try store.create("/tmp/project");
    rig.a.session_store = &store;
    rig.a.checkpoint();
    try testing.expect(store.file_name != null);

    var load_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer load_arena.deinit();
    const loaded = (try r.session_store.load(load_arena.allocator(), rig.a.io, base, store.file_name.?)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), loaded.save.agents.len);

    var resumed: SessionTestRig = undefined;
    try resumed.init();
    defer resumed.deinit();
    try applySaveState(&resumed.a, &loaded.save);

    try testing.expectEqual(main_id, resumed.a.main_agent_id.?);
    const main = resumed.registry.get(main_id).?;
    try testing.expectEqual(@as(usize, 2), main.history().len);
    try testing.expectEqualStrings("plan the work", main.history()[0].text());
    try testing.expectEqualStrings("spawning helpers", main.history()[1].text());

    try testing.expectEqual(child_id.generation, resumed.registry.slots[child_id.index].generation);
    const child = resumed.registry.get(child_id).?;
    try testing.expectEqualStrings("child", child.name);
    try testing.expectEqualStrings("fix the bug", child.task_description);
    try testing.expectEqual(main_id.pack(), child.parent.?);
    try testing.expectEqual(child.parent, resumed.registry.slots[child_id.index].parent);
    try testing.expectEqual(@as(u16, 1), child.depth);
    try testing.expectEqualStrings(rig.a.cwd, child.cwd);
    try testing.expect(!child.background);
    try testing.expectEqual(@as(usize, 2), child.history().len);
    try testing.expectEqualStrings("done fixing", child.history()[1].text());
    try testing.expectEqual(r.agent_registry.SlotState.complete, resumed.registry.state(child_id).?);
    try testing.expectEqual(r.agent.Status.idle, child.status);
    try testing.expect(child.task == null);
    try testing.expectEqual(@as(usize, 0), child.queued_messages.items.len);
    try testing.expect(!resumed.registry.slots[child_id.index].pinned);

    const bg = resumed.registry.get(bg_id).?;
    try testing.expect(bg.background);
    try testing.expect(bg.parent == null);
    try testing.expectEqualStrings("log stable", bg.history()[1].text());

    try testing.expectEqual(@as(usize, 1), resumed.a.timeline.items.len);
    try testing.expectEqual(child_id, resumed.a.timeline.items[0].parts[0].tool_call.agent_id);
    try testing.expect(resumed.a.tool_status_entries.value.agents[child_id.index].entries.get("call_spawn_child") != null);

    const Fixture = struct {
        fn discard(_: ?*anyopaque, _: agent_run.Event) void {}
    };
    try child.queueMessages(&.{sdk.UserMessage("wake up")});
    try resumed.registry.run(child_id, .{ .max_steps = 0 });
    try testing.expectEqual(r.agent_registry.SlotState.active, resumed.registry.state(child_id).?);
    while (resumed.registry.state(child_id) == .active) {
        _ = resumed.registry.drain(child_id, 64, null, Fixture.discard);
        _ = resumed.registry.reap(child_id);
        if (resumed.registry.state(child_id) == .active) try std.Io.sleep(resumed.a.io, .fromMilliseconds(1), .awake);
    }
}

test "legacy journal without agents and main_agent still resumes" {
    const testing = std.testing;
    var rig: SessionTestRig = undefined;
    try rig.init();
    defer rig.deinit();

    const legacy_json =
        \\{"chat":[{"role":"user","parts":[{"text":"legacy prompt"}]}],"timeline":[]}
    ;
    const parsed = try std.json.parseFromSlice(SaveState, testing.allocator, legacy_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.agents.len);
    try testing.expect(parsed.value.main_agent == null);

    try applySaveState(&rig.a, &parsed.value);

    try testing.expect(rig.a.main_agent_id != null);
    const agent = rig.registry.get(rig.a.main_agent_id.?).?;
    try testing.expectEqual(@as(usize, 1), agent.history().len);
    try testing.expectEqualStrings("legacy prompt", agent.history()[0].text());
}

test "occupied and out-of-range agent entries are skipped while the rest restore" {
    const testing = std.testing;
    var rig: SessionTestRig = undefined;
    try rig.init();
    defer rig.deinit();

    const squatter_id = try rig.spawn("squatter", "", null, false, &.{});

    const main_chat = [_]WireMessage{.{ .role = .user, .parts = &.{.{ .text = "main" }} }};
    const agent_chat = [_]WireMessage{.{ .role = .user, .parts = &.{.{ .text = "work" }} }};
    const agents = [_]WireAgent{
        .{ .id = (r.AgentId{ .index = squatter_id.index, .generation = 90 }).pack(), .name = "squatted", .cwd = "/x", .chat = &agent_chat },
        .{ .id = (r.AgentId{ .index = 200, .generation = 1 }).pack(), .name = "far", .cwd = "/x", .chat = &agent_chat },
        .{ .id = (r.AgentId{ .index = 7, .generation = 3 }).pack(), .name = "kept", .cwd = "/x", .chat = &agent_chat },
    };
    const save = SaveState{
        .chat = &main_chat,
        .timeline = &.{},
        .main_agent = (r.AgentId{ .index = 3, .generation = 2 }).pack(),
        .agents = &agents,
    };
    try applySaveState(&rig.a, &save);

    try testing.expectEqual(@as(u16, 3), rig.a.main_agent_id.?.index);
    try testing.expectEqual(@as(u16, 2), rig.a.main_agent_id.?.generation);
    const kept_id = r.AgentId{ .index = 7, .generation = 3 };
    const kept = rig.registry.get(kept_id) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("work", kept.history()[0].text());
    try testing.expect(rig.registry.get(.{ .index = squatter_id.index, .generation = 90 }) == null);
    try testing.expect(rig.registry.get(squatter_id) != null);
}

test "agents with empty history are not persisted" {
    const testing = std.testing;
    var rig: SessionTestRig = undefined;
    try rig.init();
    defer rig.deinit();

    const main_id = try rig.spawn("main", "", null, false, &.{sdk.UserMessage("hello")});
    rig.a.main_agent_id = main_id;
    rig.registry.pin(main_id);
    _ = try rig.spawn("child", "task", main_id, false, &.{sdk.UserMessage("child work")});
    _ = try rig.spawn("empty", "", null, false, &.{});

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const save = try buildSaveState(&rig.a, rig.a.mainAgent().?, arena.allocator());
    try testing.expectEqual(@as(usize, 1), save.agents.len);
    try testing.expectEqualStrings("child", save.agents[0].name);
    try testing.expectEqual(main_id.pack(), save.agents[0].parent.?);
}
