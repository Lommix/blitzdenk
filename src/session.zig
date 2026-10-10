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
    main_metadata: ?WireAgent = null,
    archived_ids: []const u32 = &.{},
    archived_agents: []const WireAgent = &.{},
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

pub const ToolState = enum { pending, succeeded, failed, interrupted };

pub const WireToolStatus = struct {
    state: ToolState = .pending,
    agent: ?u32 = null,
    call_id: []const u8,
    ansi: []const u8 = "",
    is_error: ?bool = null,
    child: ?u32 = null,
};

pub fn encodeChat(history: []const sdk.Message, alloc: std.mem.Allocator) ![]const WireMessage {
    var out: std.ArrayList(WireMessage) = .empty;
    for (history) |message| {
        if (isReminder(message)) continue;
        try out.append(alloc, try encodeMessage(alloc, message));
    }
    return out.toOwnedSlice(alloc);
}

/// Renders styled lines back to an ANSI string — the same representation
/// `App.setToolStatus` consumes via `Text.fromAnsi`.
pub fn linesToAnsi(lines: []const r.tui.Line, alloc: std.mem.Allocator) ![]const u8 {
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

pub fn applySaveState(a: *app.App, save: *const SaveState) !void {
    a.journal_restoring = true;
    defer a.journal_restoring = false;
    const alloc = a.sessionAlloc();
    for (save.archived_ids) |packed_id| {
        const id = r.AgentId.unpack(packed_id);
        if (id.index >= r.agent_registry.max_agents) continue;
        a.registry.slots[id.index].generation = @max(a.registry.slots[id.index].generation, id.generation);
    }
    for (save.archived_agents) |*entry| {
        const id: r.AgentId = .unpack(entry.id);
        if (id.index >= r.agent_registry.max_agents) continue;
        try a.rememberAgentMetadata(id, entry.name, entry.task_description);
    }
    var restored: std.ArrayList(r.AgentId) = .empty;
    errdefer for (restored.items) |id| a.registry.release(id);
    if (save.main_metadata) |entry| {
        try restoreSubAgent(a, &entry, alloc);
        try restored.append(alloc, .unpack(entry.id));
    } else if (save.main_agent) |id| {
        const entry = WireAgent{ .id = id, .name = a.context_factory.agentName(.general), .cwd = a.cwd, .clean = save.clean, .chat = save.chat };
        try restoreSubAgent(a, &entry, alloc);
        try restored.append(alloc, .unpack(id));
    }
    for (save.agents) |*entry| {
        try restoreSubAgent(a, entry, alloc);
        try restored.append(alloc, .unpack(entry.id));
    }
    for (save.timeline) |entry| try a.appendTimelineEntry(alloc, entry);
    for (save.tool_status) |status| {
        const packed_id = status.agent orelse save.main_agent orelse continue;
        const id: r.AgentId = .unpack(packed_id);
        if (id.index >= r.agent_registry.max_agents) continue;
        try a.setToolStatus(id, status.call_id, status.ansi);
        if (status.is_error) |failed| try a.setToolResult(id, status.call_id, failed);
        if (status.child) |child| try a.setToolChild(id, status.call_id, .unpack(child));
        const guard = a.tool_status_entries.lock(a.io);
        if (guard.ptr.getAgent(id)) |agent_status| if (agent_status.entries.getPtr(status.call_id)) |entry| {
            entry.interrupted = status.state == .interrupted;
        };
        guard.unlock();
    }
    a.main_agent_id = if (save.main_agent) |id| .unpack(id) else null;
    if (a.main_agent_id) |id| a.registry.pin(id);
    a.dirty = true;
    a.running = false;
}

pub fn bindJournal(a: *app.App) void {
    for (&a.registry.slots, 0..) |*slot, index| {
        if (slot.agent) |*agent| {
            agent.journal = a.session_store;
            agent.journal_id = (r.AgentId{ .index = @intCast(index), .generation = slot.generation }).pack();
        }
    }
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
    agent.reported_task_done = true;
    a.registry.slots[id.index].state.store(.complete, .release);
}

fn setRestoredChat(agent: *r.agent.Agent, chat: []const WireMessage, alloc: std.mem.Allocator) !void {
    const messages = try alloc.alloc(sdk.Message, chat.len);
    for (chat, messages) |wire, *message| message.* = try decodeMessage(alloc, wire);
    try agent.setMessages(messages);
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
        self.a.journal_restoring = false;
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
        if (messages.len > 0) try agent.setMessages(messages);
        try self.a.configureAgent(id, agent);
        return id;
    }
};

test "retained agents and display survive journal replay with stable ids" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = std.Io.Dir{ .handle = tmp.dir.handle };

    var rig: SessionTestRig = undefined;
    try rig.init();
    defer rig.deinit();

    var store = r.session_store.Store{ .io = rig.a.io, .gpa = testing.allocator, .base = base };
    defer store.deinit();
    try store.create("/tmp/project");
    rig.a.session_store = &store;

    const main_id = try rig.spawn("main", "", null, false, &.{
        sdk.UserMessage("plan the work"),
        sdk.AssistantMessage("spawning helpers"),
    });
    try rig.a.selectMainAgent(main_id);
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

    rig.a.checkpoint();
    try testing.expect(store.file_name != null);

    var load_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer load_arena.deinit();
    const loaded = (try r.session_store.load(load_arena.allocator(), rig.a.io, base, store.file_name.?)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), loaded.save.agents.len);

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

test "resumed agents stay idle and reap without background completion notices" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = std.Io.Dir{ .handle = tmp.dir.handle };

    var rig: SessionTestRig = undefined;
    try rig.init();
    defer rig.deinit();

    var store = r.session_store.Store{ .io = rig.a.io, .gpa = testing.allocator, .base = base };
    defer store.deinit();
    try store.create("/tmp/project");
    rig.a.session_store = &store;

    const main_id = try rig.spawn("main", "", null, false, &.{
        sdk.UserMessage("plan the work"),
        sdk.AssistantMessage("spawning helpers"),
    });
    try rig.a.selectMainAgent(main_id);
    rig.registry.pin(main_id);
    rig.registry.slots[main_id.index].state.store(.complete, .release);

    const bg_id = try rig.spawn("scout", "watch the logs", main_id, true, &.{
        sdk.UserMessage("watch the logs"),
        sdk.AssistantMessage("log stable"),
    });

    rig.a.checkpoint();
    try testing.expect(store.file_name != null);

    var load_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer load_arena.deinit();
    const loaded = (try r.session_store.load(load_arena.allocator(), rig.a.io, base, store.file_name.?)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), loaded.save.agents.len);

    var resumed: SessionTestRig = undefined;
    try resumed.init();
    defer resumed.deinit();
    try applySaveState(&resumed.a, &loaded.save);

    const main = resumed.registry.get(main_id).?;
    const bg = resumed.registry.get(bg_id).?;
    try testing.expect(main.reported_task_done);
    try testing.expect(bg.reported_task_done);
    try testing.expectEqual(r.agent_registry.SlotState.complete, resumed.registry.state(main_id).?);
    try testing.expectEqual(r.agent_registry.SlotState.complete, resumed.registry.state(bg_id).?);
    try testing.expect(!resumed.a.running);
    try testing.expectEqual(@as(usize, 0), main.queued_messages.items.len);
    try testing.expect(main.task == null);

    const timeline_len = resumed.a.timeline.items.len;
    try resumed.a.handleReapedAgent(bg_id);
    try resumed.a.handleReapedAgent(main_id);
    try testing.expectEqual(@as(u32, 0), resumed.registry.countActive());
    try testing.expectEqual(r.agent_registry.SlotState.complete, resumed.registry.state(main_id).?);
    try testing.expectEqual(@as(usize, 0), main.queued_messages.items.len);
    try testing.expect(!resumed.a.running);
    try testing.expectEqual(timeline_len, resumed.a.timeline.items.len);

    const Fixture = struct {
        fn discard(_: ?*anyopaque, _: agent_run.Event) void {}
    };
    try resumed.registry.run(main_id, .{ .max_steps = 0 });
    try testing.expect(!main.reported_task_done);
    try testing.expectEqual(r.agent_registry.SlotState.active, resumed.registry.state(main_id).?);
    while (resumed.registry.state(main_id) == .active) {
        _ = resumed.registry.drain(main_id, 64, null, Fixture.discard);
        _ = resumed.registry.reap(main_id);
        if (resumed.registry.state(main_id) == .active) try std.Io.sleep(resumed.a.io, .fromMilliseconds(1), .awake);
    }
}

const JournalModel = struct {
    fragment_ready: std.Io.Event = .unset,
    accept_response: std.Io.Event = .unset,
    tool_started: std.Io.Event = .unset,
    finish_tool: std.Io.Event = .unset,
    calls: usize = 0,

    fn modelId(_: *anyopaque) []const u8 {
        return "journal-test";
    }

    fn generate(ctx: *anyopaque, alloc: std.mem.Allocator, _: std.Io, _: sdk.model.GenerateParams, _: ?*std.http.Client, _: u32) !*sdk.model.GenerateResult {
        const self: *JournalModel = @ptrCast(@alignCast(ctx));
        const result = try alloc.create(sdk.model.GenerateResult);
        self.calls += 1;
        if (self.calls == 1) {
            const calls = try alloc.alloc(sdk.ToolCall, 1);
            calls[0] = .{ .id = try alloc.dupe(u8, "call"), .name = try alloc.dupe(u8, "wait"), .input = try alloc.dupe(u8, "{}") };
            result.* = .{ .text = try alloc.dupe(u8, "accepted assistant"), .tool_calls = calls, .finish_reason = .tool_calls };
        } else {
            result.* = .{ .text = try alloc.dupe(u8, "final answer"), .finish_reason = .stop };
        }
        return result;
    }

    fn stream(ctx: *anyopaque, alloc: std.mem.Allocator, io: std.Io, params: sdk.model.GenerateParams, client: ?*std.http.Client, retries: u32, streaming: *sdk.model.StreamContext) !*sdk.model.GenerateResult {
        const self: *JournalModel = @ptrCast(@alignCast(ctx));
        if (self.calls == 0) {
            streaming.send(.{ .type = .text, .text = "uncommitted fragment" });
            self.fragment_ready.set(io);
            try self.accept_response.wait(io);
        }
        return generate(ctx, alloc, io, params, client, retries);
    }

    fn execute(ctx: ?*anyopaque, _: std.mem.Allocator, io: std.Io, _: sdk.ToolCall) !sdk.ToolOutput {
        const self: *JournalModel = @ptrCast(@alignCast(ctx.?));
        self.tool_started.set(io);
        try self.finish_tool.wait(io);
        return .{ .content = "tool finished" };
    }

    fn discard(_: ?*anyopaque, _: agent_run.Event) void {}

    const vtable = sdk.model.ModelVTable{ .model_id = modelId, .generate = generate, .stream = stream };
};

test "assistant archive and display publish during a running tool and final answer publishes once" {
    try exerciseJournalRun(false);
}

test "live cancellation archives completed assistant and resets unfinished model exchange" {
    try exerciseJournalRun(true);
}

fn exerciseJournalRun(cancel: bool) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rig: SessionTestRig = undefined;
    try rig.init();
    defer rig.deinit();
    var store = r.session_store.Store{ .io = rig.a.io, .gpa = std.testing.allocator, .base = .{ .handle = tmp.dir.handle } };
    defer store.deinit();
    try store.create("/project");
    rig.a.session_store = &store;
    const id = try rig.spawn("main", "", null, false, &.{});
    try rig.a.selectMainAgent(id);
    var fixture = JournalModel{};
    const agent = rig.registry.get(id).?;
    agent.lifetime.reminder = null;
    const tools = [_]sdk.Tool{.{ .name = "wait", .execute = JournalModel.execute, .execute_ctx = &fixture }};
    agent.tools = &tools;
    try agent.startModel(.{ .ctx = &fixture, .vtable = &JournalModel.vtable }, .{ .prompt = "work", .max_steps = 2 });
    defer agent.cancelAndWait();
    try fixture.fragment_ready.wait(rig.a.io);
    try store.flush();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const streaming = (try r.session_store.load(arena.allocator(), rig.a.io, store.base, store.file_name.?)).?;
    try std.testing.expectEqual(@as(usize, 1), streaming.save.chat.len);
    try std.testing.expectEqual(@as(usize, 0), streaming.save.timeline.len);
    try std.testing.expect(store.holdsChat());
    fixture.accept_response.set(rig.a.io);
    try fixture.tool_started.wait(rig.a.io);
    rig.a.journalFlush();
    const in_tool = (try r.session_store.load(arena.allocator(), rig.a.io, store.base, store.file_name.?)).?;
    try std.testing.expectEqual(@as(usize, 1), in_tool.save.timeline.len);
    try std.testing.expectEqualStrings("accepted assistant", in_tool.save.timeline[0].parts[0].message);
    try std.testing.expectEqual(@as(usize, 1), in_tool.save.chat.len);
    try std.testing.expectEqual(@as(usize, 2), in_tool.repairs.len);
    try std.testing.expect(!agent.task.?.isFinished());
    if (cancel) {
        agent.cancelAndWait();
        try std.testing.expectEqual(@as(usize, 1), agent.history().len);
    } else {
        fixture.finish_tool.set(rig.a.io);
        agent.task.?.wait();
        while (agent.drain(64, null, JournalModel.discard) != 0) {}
        try std.testing.expect(agent.reap());
    }
    rig.a.checkpoint();
    const completed = (try r.session_store.load(arena.allocator(), rig.a.io, store.base, store.file_name.?)).?;
    try std.testing.expect(completed.problem == null);
    try std.testing.expectEqual(@as(usize, 0), completed.repairs.len);
    try std.testing.expectEqual(@as(usize, if (cancel) 1 else 4), completed.save.chat.len);
    try std.testing.expectEqual(@as(usize, if (cancel) 1 else 2), completed.save.timeline.len);
    if (cancel) {
        try std.testing.expectEqual(ToolState.interrupted, completed.save.tool_status[0].state);
    } else {
        try std.testing.expectEqualStrings("final answer", completed.save.chat[3].parts[0].text);
    }
    const size = store.offset;
    rig.a.checkpoint();
    try std.testing.expectEqual(size, store.offset);
}

test "removed agents retain historical links without occupying restored slots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rig: SessionTestRig = undefined;
    try rig.init();
    defer rig.deinit();
    var store = r.session_store.Store{ .io = rig.a.io, .gpa = std.testing.allocator, .base = .{ .handle = tmp.dir.handle } };
    defer store.deinit();
    try store.create("/project");
    rig.a.session_store = &store;
    var first: ?r.AgentId = null;
    for (0..r.agent_registry.max_agents + 3) |_| {
        const id = try rig.spawn("archived", "task", null, false, &.{sdk.UserMessage("old")});
        if (first == null) first = id;
        try rig.a.setToolStatus(id, "call", "old label");
        rig.registry.release(id);
    }
    const current = try rig.spawn("current", "", null, false, &.{sdk.UserMessage("new")});
    try rig.a.selectMainAgent(current);
    try rig.a.setToolStatus(current, "call", "new label");
    try rig.a.setToolChild(current, "call", first.?);
    rig.a.checkpoint();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loaded = (try r.session_store.load(arena.allocator(), rig.a.io, store.base, store.file_name.?)).?;
    try std.testing.expect(loaded.problem == null);
    try std.testing.expectEqual(@as(usize, r.agent_registry.max_agents + 3), loaded.save.archived_agents.len);
    var resumed: SessionTestRig = undefined;
    try resumed.init();
    defer resumed.deinit();
    try applySaveState(&resumed.a, &loaded.save);
    try std.testing.expect(resumed.registry.get(first.?) == null);
    try std.testing.expectEqual(current, resumed.a.main_agent_id.?);
    const statuses = resumed.a.tool_status_entries.lock(resumed.a.io);
    defer statuses.unlock();
    const archived = statuses.ptr.getAgent(first.?).?;
    try std.testing.expectEqualStrings("archived", archived.name);
    try std.testing.expect(archived.entries.contains("call"));
    const retained = statuses.ptr.getAgent(current).?;
    try std.testing.expectEqualStrings("current", retained.name);
    try std.testing.expectEqual(first.?, retained.entries.get("call").?.child_id.?);
    const next = resumed.registry.reserve(null).?;
    defer resumed.registry.releaseReservation(next);
    try std.testing.expect(next.pack() != first.?.pack());
}
