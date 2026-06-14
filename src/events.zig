const std = @import("std");
const r = @import("root.zig");
const AgentId = r.prv.Swarm.AgentId;
const Role = r.prv.adapter.Role;

/// Events emitted by the app, swarm, and agent subsystems. The AppEvent
/// union is the single source of truth — any code that needs to react to
/// system state changes (e.g. Lua callbacks, logging, status-bar updates)
/// should dispatch from a central `onEvent` call.
pub const AppEvent = union(enum) {
    // ── App lifecycle ────────────────────────────────────────────
    session_reset,
    mode_changed: u8,
    // ── Agent lifecycle (swarm) ──────────────────────────────────
    agent_created: struct { id: AgentId, type_idx: u8, depth: u16 },
    agent_started: struct { id: AgentId },
    agent_complete: struct { id: AgentId },
    agent_failed: struct { id: AgentId, err: ?anyerror },
    agent_cancelled: struct { id: AgentId },
    agent_released: struct { id: AgentId },
    // ── Streaming ────────────────────────────────────────────────
    agent_streaming_start: struct { id: AgentId },
    agent_streaming_delta: struct { id: AgentId },
    agent_streaming_finish: struct { id: AgentId },
    // ── Compaction ───────────────────────────────────────────────
    compaction_started: struct { id: AgentId },
    compaction_complete: struct { id: AgentId },
    // ── Tool calls ───────────────────────────────────────────────
    tool_call_started: struct { agent_id: AgentId, call_id: []const u8, name: []const u8 },
    tool_call_complete: struct { agent_id: AgentId, call_id: []const u8, name: []const u8, is_error: bool },
    // ── Broadcast ────────────────────────────────────────────────
    agent_broadcast: struct { id: AgentId, role: Role },
    // ── Permissions ──────────────────────────────────────────────
    //NOTE: maybe later
    // permission_requested: struct { call_id: []const u8, level: PermissionLevel },
    // permission_resolved: struct { call_id: []const u8, state: PermissionState },
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
    zig: *const fn (app: *r.app.App, ev: *anyopaque) anyerror!void,
    lua: c_int,
};

pub const EventBus = struct {
    listner: std.AutoHashMapUnmanaged(AppEventTag, std.ArrayList(Listner)) = .{},
    pub fn run(self: *const EventBus, app: *r.app.App, event: AppEvent) !void {
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
