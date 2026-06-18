const std = @import("std");

const r = @import("root.zig");
const app = @import("app.zig");
const prv = @import("provider");
const util = @import("util.zig");

pub fn genSessionId(buf: []u8) !void {
    _ = buf; // autofix
}

pub const SaveState = struct {
    chat: []const prv.adapter.Message,
    chat_render: []const app.ChatEntry,
};

pub fn saveSession(a: *const app.App, w: *std.Io.Writer) !void {
    const agent = a.mainAgent() orelse return error.NoActiveSessionToSave;
    const save = SaveState{
        .chat = agent.chat.messages.items[0..],
        .chat_render = a.chat_entries.items,
    };

    try std.json.Stringify.value(save, .{}, w);
    try w.flush();
}

pub fn loadSession(a: *app.App, w: *std.Io.Reader) !void {
    const alloc = a.appAlloc();
    const session_alloc = a.sessionAlloc();

    a.reset();

    // Parse JSON from reader
    var json_reader = std.json.Reader.init(alloc, w);
    defer json_reader.deinit();

    const parsed = try std.json.parseFromTokenSource(SaveState, alloc, &json_reader, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const save = parsed.value;

    // Create new agent to hold restored chat
    const id = try a.swarm.newAgent(
        .max,
        null,
        @intFromEnum(r.ContextFactory.AgentType.general),
        @intFromEnum(a.mode),
    );

    const agent = a.swarm.getAgent(id).?;
    try a.configureAgent(agent);

    agent.chat.messages.clearRetainingCapacity();

    // Restore internal chat into agent's arena (app-alloc lifetime)

    for (save.chat) |msg| {
        try agent.chat.messages.append(
            agent.arena.allocator(),
            try msg.clone(agent.arena.allocator()),
        );
    }

    // Restore render chat entries into session arena (freed on next reset)
    for (save.chat_render) |entry| {
        const cloned = try util.deepClone(app.ChatEntry, entry, session_alloc);
        try a.chat_entries.append(session_alloc, cloned);
    }

    a.main_agent_id = id;
    a.dirty = true;
}
