const std = @import("std");
const exec = @import("exec");
const AgentId = @import("agent-id").AgentId;

pub const BackgroundTask = struct {
    handle: exec.CmdPool.Handle,
    command: []const u8,
};

pub const BackgroundTaskList = struct {
    list: std.ArrayList(BackgroundTask) = .empty,
};

pub const BackgroundAgentStatus = enum { running, complete, failed };

pub const BackgroundAgent = struct {
    agent_id: AgentId,
    description: []const u8,
    status: BackgroundAgentStatus,
};

pub const BackgroundAgentList = struct {
    list: std.ArrayList(BackgroundAgent) = .empty,
};

pub const TodoState = enum {
    pending,
    in_progress,
    done,

    pub fn fromString(value: []const u8) ?TodoState {
        return std.meta.stringToEnum(TodoState, value);
    }

    pub fn toString(self: TodoState) []const u8 {
        return @tagName(self);
    }

    pub fn icon(self: TodoState) []const u8 {
        return switch (self) {
            .pending => "[ ]",
            .in_progress => "[~]",
            .done => "[x]",
        };
    }
};

pub const Todo = struct {
    id: u32,
    subject: []const u8,
    description: []const u8,
    state: TodoState,
};

pub const TodoList = struct {
    pub const max_todos = 64;
    todos: [max_todos]Todo = undefined,
    count: usize = 0,
    next_id: u32 = 1,

    pub fn findById(self: *TodoList, id: u32) ?*Todo {
        for (self.todos[0..self.count]) |*todo| {
            if (todo.id == id) return todo;
        }
        return null;
    }
};

pub fn Guard(comptime T: type) type {
    return struct {
        ptr: *T,
        mutex: *std.Io.Mutex,
        io: std.Io,

        pub fn unlock(self: @This()) void {
            self.mutex.unlock(self.io);
        }
    };
}

pub fn Locked(comptime T: type) type {
    return struct {
        const Self = @This();
        value: T = if (@hasDecl(T, "empty")) .empty else .{},
        mutex: std.Io.Mutex = .init,

        pub fn lock(self: *Self, io: std.Io) Guard(T) {
            self.mutex.lockUncancelable(io);
            return .{ .ptr = &self.value, .mutex = &self.mutex, .io = io };
        }

        pub fn tryLock(self: *Self, io: std.Io) ?Guard(T) {
            if (!self.mutex.tryLock()) return null;
            return .{ .ptr = &self.value, .mutex = &self.mutex, .io = io };
        }
    };
}

pub const ToolDisplay = struct {
    content: []const u8,
    child: ?AgentId = null,
};
