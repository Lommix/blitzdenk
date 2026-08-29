const std = @import("std");
const r = @import("root.zig");
const AgentId = r.AgentId;

pub const AppEvent = union(enum) {
    session_reset,
    agent_created: struct { id: AgentId, name: []const u8, depth: u16 },
    agent_started: AgentId,
    agent_complete: AgentId,
    agent_failed: struct { id: AgentId, err: []const u8 },
    agent_cancelled: AgentId,
    compaction_started: AgentId,
    compaction_complete: AgentId,
    user_message_sent: []const u8,
    mcp_tools_reloaded,
};

pub const AppEventTag = @typeInfo(AppEvent).@"union".tag_type.?;

pub const Listener = struct {
    func_ref: c_int,
};

pub const EventBus = struct {
    listener: std.AutoHashMapUnmanaged(AppEventTag, std.ArrayList(Listener)) = .{},
    listener_mu: std.Io.Mutex = .init,

    pub fn emit(self: *EventBus, app: *r.app.App, event: AppEvent) void {
        self.listener_mu.lockUncancelable(app.io);
        const listeners = self.listener.get(event) orelse {
            self.listener_mu.unlock(app.io);
            return;
        };
        const snapshot = app.gpa.dupe(Listener, listeners.items) catch {
            self.listener_mu.unlock(app.io);
            return;
        };
        self.listener_mu.unlock(app.io);
        defer app.gpa.free(snapshot);

        app.lua_vm.vm_mu.lockUncancelable(app.io);
        defer app.lua_vm.vm_mu.unlock(app.io);

        for (snapshot) |ln| {
            switch (event) {
                .session_reset, .mcp_tools_reloaded => app.lua_vm.invokeLuaFunctionNoArgs(ln.func_ref),
                .agent_created => |payload| app.lua_vm.invokeLuaFunction(ln.func_ref, payload),
                .agent_started, .agent_complete, .agent_cancelled, .compaction_started, .compaction_complete => |id| app.lua_vm.invokeLuaFunction(ln.func_ref, .{ .id = id }),
                .agent_failed => |payload| app.lua_vm.invokeLuaFunction(ln.func_ref, payload),
                .user_message_sent => |text| app.lua_vm.invokeLuaFunction(ln.func_ref, .{ .text = text }),
            }
        }
    }

    pub fn addLuaListener(self: *EventBus, alloc: std.mem.Allocator, io: std.Io, event_type: AppEventTag, func_ref: c_int) !void {
        self.listener_mu.lockUncancelable(io);
        defer self.listener_mu.unlock(io);
        const res = try self.listener.getOrPut(alloc, event_type);
        if (!res.found_existing) {
            res.value_ptr.* = .empty;
            try res.value_ptr.append(alloc, .{ .func_ref = func_ref });
            return;
        }

        for (res.value_ptr.items) |s| if (s.func_ref == func_ref) return;
        try res.value_ptr.append(alloc, .{ .func_ref = func_ref });
    }

    pub fn clear(self: *EventBus, alloc: std.mem.Allocator, io: std.Io) void {
        self.listener_mu.lockUncancelable(io);
        defer self.listener_mu.unlock(io);
        var it = self.listener.valueIterator();
        while (it.next()) |list| list.deinit(alloc);
        self.listener.deinit(alloc);
        self.listener = .{};
    }
};
