const std = @import("std");
const r = @import("root.zig");
const prv = @import("provider");
const apt = prv.adapter;
const tc = prv.tool;
const Allocator = std.mem.Allocator;

// Task list state lives on the agent (prv.agent.TaskList). Re-export for callers.
pub const TaskState = prv.agent.TaskState;
pub const Task = prv.agent.Task;
pub const TaskList = prv.agent.TaskList;

// ── Tool Definitions ─────────────────────────────────────────────────
pub const CreateTaskTool = tc.Tool{
    .def = .{
        .name = "create_task",
        .description =
        \\Use this tool to create a structured task list for your current coding session. This helps you track progress, organize complex tasks, and demonstrate thoroughness to the user.
        \\It also helps the user understand the progress of the task and overall progress of their requests.
        \\
        \\## When to Use This Tool
        \\
        \\Use this tool proactively in these scenarios:
        \\
        \\- Complex multi-step tasks - When a task requires 3 or more distinct steps or actions
        \\- Non-trivial and complex tasks - Tasks that require careful planning or multiple operations${teammateContext}
        \\- Plan mode - When using plan mode, create a task list to track the work
        \\- User explicitly requests todo list - When the user directly asks you to use the todo list
        \\- User provides multiple tasks - When users provide a list of things to be done (numbered or comma-separated)
        \\- After receiving new instructions - Immediately capture user requirements as tasks
        \\- When you start working on a task - Mark it as in_progress BEFORE beginning work
        \\- After completing a task - Mark it as completed and add any new follow-up tasks discovered during implementation
        \\
        \\## When NOT to Use This Tool
        \\
        \\Skip using this tool when:
        \\- There is only a single, straightforward task
        \\- The task is trivial and tracking it provides no organizational benefit
        \\- The task can be completed in less than 3 trivial steps
        \\- The task is purely conversational or informational
        \\
        \\NOTE that you should not use this tool if there is only one trivial task to do. In this case you are better off just doing the task directly.
        \\
        \\All tasks are created with status \`pending\`.
        \\
        ,
        .parameters_schema =
        \\{"type":"object","properties":{
        \\  "subject": {"type": "string", "description":"A brief, actionable title in imperative form"},
        \\  "description":{"type":"string","description":"What needs to be done"}
        \\},"required":["description", "subject"]}
        ,
    },
    .func = &createTask,
};

pub const GetTaskTool = tc.Tool{
    .def = .{
        .name = "get_task",
        .description = "Get a task by ID from your task list.",
        .parameters_schema =
        \\{"type":"object","properties":{"id":{"type":"integer","description":"Task ID"}},"required":["id"]}
        ,
    },
    .func = &getTask,
};

pub const ListTasksTool = tc.Tool{
    .def = .{
        .name = "list_tasks",
        .description = "List all tasks in your task list.",
        .parameters_schema =
        \\{"type":"object","properties":{},"required":[]}
        ,
    },
    .func = &listTasks,
};

pub const UpdateTaskStateTool = tc.Tool{
    .def = .{
        .name = "update_task_state",
        .description = "Update the state of a task",
        .parameters_schema =
        \\{"type":"object","properties":{"id":{"type":"integer","description":"Task ID"},"state":{"type":"string","enum":["pending","in_progress","done"],"description":"New state"}},"required":["id","state"]}
        ,
    },
    .func = &updateTaskState,
};

// ── Tool Implementations ─────────────────────────────────────────────

fn createTask(ctx: tc.ToolContext, call: apt.ToolCall) apt.ToolResult {
    const args = r.parseArgs(struct { subject: []const u8, description: []const u8 }, ctx.alloc, call) orelse
        return r.errResult(call, "invalid arguments: expected {\"description\": \"...\"}");

    ctx.updateToolStatus(call, "new task {s}", .{args.subject});

    const subject = ctx.alloc.dupe(u8, args.subject) catch
        return r.errResult(call, "out of memory");
    const description = ctx.alloc.dupe(u8, args.description) catch
        return r.errResult(call, "out of memory");

    const id = blk: {
        const g = ctx.agent().task_list.lock(ctx.io);
        defer g.unlock();
        if (g.ptr.count >= TaskList.max_tasks)
            return r.errResult(call, "task list full (max 64 tasks)");

        const tid = g.ptr.next_id;
        g.ptr.next_id += 1;
        g.ptr.tasks[g.ptr.count] = .{
            .id = tid,
            .subject = subject,
            .description = description,
            .state = .pending,
        };
        g.ptr.count += 1;
        break :blk tid;
    };

    const msg = std.fmt.allocPrint(ctx.alloc, "Task created with ID {d}", .{id}) catch
        return r.errResult(call, "out of memory");

    return r.okResult(call, msg);
}

fn getTask(ctx: tc.ToolContext, call: apt.ToolCall) apt.ToolResult {
    const args = r.parseArgs(struct { id: u32 }, ctx.alloc, call) orelse
        return r.errResult(call, "invalid arguments: expected {\"id\": <number>}");

    const snap = blk: {
        const g = ctx.agent().task_list.lock(ctx.io);
        defer g.unlock();
        const task = g.ptr.findById(args.id) orelse
            return r.errResult(call, "task not found");
        break :blk Task{
            .id = task.id,
            .subject = ctx.alloc.dupe(u8, task.subject) catch
                return r.errResult(call, "out of memory"),
            .description = ctx.alloc.dupe(u8, task.description) catch
                return r.errResult(call, "out of memory"),
            .state = task.state,
        };
    };

    ctx.updateToolStatus(call, "get task: {s}", .{snap.subject});

    const msg = std.fmt.allocPrint(ctx.alloc, "Task {d}: [{s}] subject: {s}\n description: {s}", .{
        snap.id, snap.state.toString(), snap.subject, snap.description,
    }) catch return r.errResult(call, "out of memory");

    return r.okResult(call, msg);
}

fn listTasks(ctx: tc.ToolContext, call: apt.ToolCall) apt.ToolResult {
    // Snapshot tasks under lock so we can render outside it.
    const snap = blk: {
        const g = ctx.agent().task_list.lock(ctx.io);
        defer g.unlock();
        if (g.ptr.count == 0) break :blk &[_]Task{};
        const buf = ctx.alloc.alloc(Task, g.ptr.count) catch
            return r.errResult(call, "out of memory");
        for (g.ptr.tasks[0..g.ptr.count], 0..) |t, i| {
            buf[i] = .{
                .id = t.id,
                .subject = ctx.alloc.dupe(u8, t.subject) catch
                    return r.errResult(call, "out of memory"),
                .description = ctx.alloc.dupe(u8, t.description) catch
                    return r.errResult(call, "out of memory"),
                .state = t.state,
            };
        }
        break :blk @as([]const Task, buf);
    };

    if (snap.len == 0) return r.okResult(call, "No tasks.");

    ctx.updateToolStatus(call, "list tasks ..", .{});

    for (snap) |task| {
        const text = std.fmt.allocPrint(ctx.alloc, "{s} {s}", .{ task.state.icon(), task.subject }) catch "task";
        ctx.appendToolLog(call, text);
    }

    var allocating = std.Io.Writer.Allocating.init(ctx.alloc);
    for (snap) |task| {
        allocating.writer.print("{d}. [{s}] subject: {s}\n", .{
            task.id, task.state.toString(), task.subject,
        }) catch return r.errResult(call, "out of memory");
    }

    return r.okResult(call, allocating.written());
}

fn updateTaskState(ctx: tc.ToolContext, call: apt.ToolCall) apt.ToolResult {
    const args = r.parseArgs(struct { id: u32, state: []const u8 }, ctx.alloc, call) orelse
        return r.errResult(call, "invalid arguments: expected {\"id\": <number>, \"state\": \"...\"}");

    const new_state = TaskState.fromString(args.state) orelse
        return r.errResult(call, "invalid state: must be pending, in_progress, or done");

    const snap = blk: {
        const g = ctx.agent().task_list.lock(ctx.io);
        defer g.unlock();
        const task = g.ptr.findById(args.id) orelse
            return r.errResult(call, "task not found");
        task.state = new_state;
        break :blk .{
            .id = task.id,
            .subject = ctx.alloc.dupe(u8, task.subject) catch
                return r.errResult(call, "out of memory"),
            .state = task.state,
        };
    };

    ctx.updateToolStatus(call, "update task {s} {s}", .{ snap.state.icon(), snap.subject });

    const msg = std.fmt.allocPrint(ctx.alloc, "Task {d} state updated to {s}", .{
        snap.id, new_state.toString(),
    }) catch return r.errResult(call, "out of memory");

    return r.okResult(call, msg);
}

fn updateTaskDetail(ctx: tc.ToolContext, call: apt.ToolCall) apt.ToolResult {
    const args = r.parseArgs(struct { id: u32, description: []const u8 }, ctx.alloc, call) orelse
        return r.errResult(call, "invalid arguments: expected {\"id\": <number>, \"description\": \"...\"}");

    const new_desc = ctx.alloc.dupe(u8, args.description) catch
        return r.errResult(call, "out of memory");

    const id = blk: {
        const g = ctx.agent().task_list.lock(ctx.io);
        defer g.unlock();
        const task = g.ptr.findById(args.id) orelse
            return r.errResult(call, "task not found");
        task.description = new_desc;
        break :blk task.id;
    };

    const msg = std.fmt.allocPrint(ctx.alloc, "Task {d} description updated", .{id}) catch
        return r.errResult(call, "out of memory");

    return r.okResult(call, msg);
}
