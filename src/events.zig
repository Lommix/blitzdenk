const std = @import("std");
const r = @import("root.zig");
const AgentId = r.prv.Swarm.AgentId;
const Role = r.prv.adapter.Role;

/// Events emitted by the app, swarm, and agent subsystems. The AppEvent
/// union is the single source of truth — any code that needs to react to
/// system state changes (e.g. Lua callbacks, logging, status-bar updates)
/// should dispatch from a central `onEvent` call.
pub const AppEvent = union(enum) {
    session_reset,
    mode_changed: u8, // done
    agent_created: struct { id: AgentId, type_idx: u8, depth: u16 },
    agent_started: AgentId,
    agent_complete: AgentId, // done
    agent_failed: struct { id: AgentId, err: []const u8 },
    agent_cancelled: struct { id: AgentId },
    compaction_started: struct { id: AgentId }, // done
    compaction_complete: struct { id: AgentId },
    // TODO: emit from agent.zig — needs event bus accessible from Agent
    tool_call_started: struct { agent_id: AgentId, call_id: []const u8, name: []const u8 },
    // TODO: emit from agent.zig — needs event bus accessible from Agent
    tool_call_complete: struct { agent_id: AgentId, call_id: []const u8, name: []const u8, is_error: bool },
    // TODO: emit from swarm.zig recordBroadcast — needs event bus threaded through Swarm
    agent_broadcast: struct { id: AgentId, role: Role },
    // TODO: emit from swarm.zig requestPermission — needs event bus threaded through Swarm
    permission_requested: struct { call_id: ?[]const u8, level: r.prv.Swarm.PermissionLevel },
    // TODO: emit from swarm.zig resolvePermission — needs event bus threaded through Swarm
    permission_resolved: struct { call_id: ?[]const u8, state: r.prv.Swarm.PermissionState },
    user_message_sent: []const u8,
    mcp_tools_reloaded,
};

pub const AppEventTag = @typeInfo(AppEvent).@"union".tag_type.?;

pub const Listner = struct {
    func_ref: c_int,
};

pub const EventBus = struct {
    listner: std.AutoHashMapUnmanaged(AppEventTag, std.ArrayList(Listner)) = .{},
    pub fn emit(self: *const EventBus, app: *r.app.App, event: AppEvent) !void {
        const listners = self.listner.get(event) orelse return;
        for (listners.items) |en| {
            // TODO: can explode, need new redesign of async lua
            // try app.lua_vm.vm_mu.lock(app.context_factory.io);
            // defer app.lua_vm.vm_mu.unlock(app.context_factory.io);

            switch (event) {
                .session_reset => app.lua_vm.invokeLuaFunction(en.func_ref, {}),
                .mode_changed => |mode_id| app.lua_vm.invokeLuaFunction(en.func_ref, mode_id),
                .agent_created => |ev| app.lua_vm.invokeLuaFunction(en.func_ref, ev),
                .agent_started => |ev| app.lua_vm.invokeLuaFunction(en.func_ref, ev),
                .agent_complete => |ev| app.lua_vm.invokeLuaFunction(en.func_ref, ev),
                .agent_failed => |ev| app.lua_vm.invokeLuaFunction(en.func_ref, ev),
                .agent_cancelled => |ev| app.lua_vm.invokeLuaFunction(en.func_ref, ev),
                .compaction_started => |ev| app.lua_vm.invokeLuaFunction(en.func_ref, ev),
                .compaction_complete => |ev| app.lua_vm.invokeLuaFunction(en.func_ref, ev),
                .tool_call_started => |ev| app.lua_vm.invokeLuaFunction(en.func_ref, ev),
                .tool_call_complete => |ev| app.lua_vm.invokeLuaFunction(en.func_ref, ev),
                .agent_broadcast => |ev| app.lua_vm.invokeLuaFunction(en.func_ref, ev),
                // .permission_requested => |ev| app.lua_vm.invokeLuaFunction(en.func_ref, ev),
                // .permission_resolved => |ev| app.lua_vm.invokeLuaFunction(en.func_ref, ev),
                .user_message_sent => |msg| app.lua_vm.invokeLuaFunction(en.func_ref, msg),
                .mcp_tools_reloaded => app.lua_vm.invokeLuaFunction(en.func_ref, {}),
                else => {},
            }
        }
    }

    pub fn addLuaListener(self: *EventBus, alloc: std.mem.Allocator, event_type: AppEventTag, func_ref: c_int) !void {
        const res = try self.listner.getOrPut(alloc, event_type);
        if (!res.found_existing) {
            res.value_ptr.* = .empty;
            try res.value_ptr.append(alloc, .{ .func_ref = func_ref });
            return;
        }

        for (res.value_ptr.items) |s| if (s.func_ref == func_ref) return;
        try res.value_ptr.append(alloc, .{ .func_ref = func_ref });
    }
};
