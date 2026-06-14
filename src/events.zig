const std = @import("std");
const prv = @import("provider");
const Swarm = prv.Swarm;
const Agent = prv.agent.Agent;
const App = @import("app.zig").App;

/// Events emitted by the app, swarm, and agent subsystems. The AppEvent
/// union is the single source of truth — any code that needs to react to
/// system state changes (e.g. Lua callbacks, logging, status-bar updates)
/// should dispatch from a central `onEvent` call.
pub const AppEvent = union(enum) {
    // ── App lifecycle ────────────────────────────────────────────
    session_reset,
    mode_changed: u8,
    // ── Agent lifecycle (swarm) ──────────────────────────────────
    agent_created: struct { id: Swarm.AgentId, type_idx: u8, depth: u16 },
    agent_started: struct { id: Swarm.AgentId },
    agent_complete: struct { id: Swarm.AgentId },
    agent_failed: struct { id: Swarm.AgentId, err: ?anyerror },
    agent_cancelled: struct { id: Swarm.AgentId },
    agent_released: struct { id: Swarm.AgentId },
    // ── Streaming ────────────────────────────────────────────────
    agent_streaming_start: struct { id: Swarm.AgentId },
    agent_streaming_delta: struct { id: Swarm.AgentId },
    agent_streaming_finish: struct { id: Swarm.AgentId },
    // ── Compaction ───────────────────────────────────────────────
    compaction_started: struct { id: Swarm.AgentId },
    compaction_complete: struct { id: Swarm.AgentId },
    // ── Tool calls ───────────────────────────────────────────────
    tool_call_started: struct { agent_id: Swarm.AgentId, call_id: []const u8, name: []const u8 },
    tool_call_complete: struct { agent_id: Swarm.AgentId, call_id: []const u8, name: []const u8, is_error: bool },
    // ── Broadcast ────────────────────────────────────────────────
    agent_broadcast: struct { id: Swarm.AgentId, role: prv.adapter.Role },
    // ── Permissions ──────────────────────────────────────────────
    permission_requested: struct { call_id: []const u8, level: Swarm.PermissionLevel },
    permission_resolved: struct { call_id: []const u8, state: Swarm.PermissionState },
    // ── User input ───────────────────────────────────────────────
    user_message_sent: []const u8,
    // ── Lua ──────────────────────────────────────────────────────
    lua_error: []const u8,
    lua_hot_reload,
    // ── MCP ──────────────────────────────────────────────────────
    mcp_tools_reloaded,
};

pub const AppEventTag = @typeInfo(AppEvent).@"union".tag_type.?;

pub const Listner = union(enum) {
    zig: *const fn (app: *App, ev: *anyopaque) anyerror!void,
    lua: c_int,
};

pub const EventBus = struct {
    listner: std.AutoHashMapUnmanaged(AppEventTag, std.ArrayList(Listner)) = .{},
    pub fn run(self: *const EventBus, app: *App, event: AppEvent) !void {
        const listners = self.listner.get(event) orelse return;
        for (listners.items) |entry| {
            switch (entry) {
                .zig => |func| try func(app, event),
                .lua => |func_id| {
                    _ = func_id; // autofix
                    @panic("not yet implemented");
                },
            }
        }
    }
};
