const std = @import("std");
const r = @import("root.zig");
const prv = @import("provider");
const apt = prv.adapter;
const tc = prv.tool;
const Allocator = std.mem.Allocator;

// Todo list state lives on the agent (prv.agent.TodoList). Re-export for callers.
pub const TodoState = prv.agent.TodoState;
pub const Todo = prv.agent.Todo;
pub const TodoList = prv.agent.TodoList;

// ── Tool Definitions ─────────────────────────────────────────────────
pub const CreateTodoTool = tc.Tool{
    .def = .{
        .name = "create_todo",
        .description =
        \\Use this tool to create a structured todo list for your current coding session. This helps you track progress, organize complex todos, and demonstrate thoroughness to the user.
        \\It also helps the user understand the progress of the todo and overall progress of their requests.
        \\
        \\## When to Use This Tool
        \\
        \\Use this tool proactively in these scenarios:
        \\
        \\- Complex multi-step todos - When a todo requires 3 or more distinct steps or actions
        \\- Non-trivial and complex todos - Todos that require careful planning or multiple operations
        \\- Plan mode - When using plan mode, create a todo list to track the work
        \\- User explicitly requests todo list - When the user directly asks you to use the todo list
        \\- User provides multiple todos - When users provide a list of things to be done (numbered or comma-separated)
        \\- After receiving new instructions - Immediately capture user requirements as todos
        \\- When you start working on a todo - Mark it as in_progress BEFORE beginning work
        \\- After completing a todo - Mark it as completed and add any new follow-up todos discovered during implementation
        \\
        \\## When NOT to Use This Tool
        \\
        \\Skip using this tool when:
        \\- There is only a single, straightforward todo
        \\- The todo is trivial and tracking it provides no organizational benefit
        \\- The todo can be completed in less than 3 trivial steps
        \\- The todo is purely conversational or informational
        \\
        \\NOTE that you should not use this tool if there is only one trivial todo to do. In this case you are better off just doing the todo directly.
        \\
        \\All todos are created with status \`pending\`.
        \\
        ,
        .parameters_schema =
        \\{"type":"object","properties":{
        \\  "subject": {"type": "string", "description":"A brief, actionable title in imperative form"},
        \\  "description":{"type":"string","description":"What needs to be done"}
        \\},"required":["description", "subject"]}
        ,
    },
    .func = &createTodo,
};

pub const GetTodoTool = tc.Tool{
    .def = .{
        .name = "get_todo",
        .description = "Get a todo by ID from your todo list.",
        .parameters_schema =
        \\{"type":"object","properties":{"id":{"type":"integer","description":"Todo ID"}},"required":["id"]}
        ,
    },
    .func = &getTodo,
};

pub const ListTodosTool = tc.Tool{
    .def = .{
        .name = "list_todos",
        .description = "List all todos in your todo list.",
        .parameters_schema =
        \\{"type":"object","properties":{},"required":[]}
        ,
    },
    .func = &listTodos,
};

pub const UpdateTodoStateTool = tc.Tool{
    .def = .{
        .name = "update_todo_state",
        .description = "Update the state of a todo",
        .parameters_schema =
        \\{"type":"object","properties":{"id":{"type":"integer","description":"Todo ID"},"state":{"type":"string","enum":["pending","in_progress","done"],"description":"New state"}},"required":["id","state"]}
        ,
    },
    .func = &updateTodoState,
};

// ── Tool Implementations ─────────────────────────────────────────────

fn createTodo(ctx: tc.ToolContext, call: apt.ToolCall) apt.ToolResult {
    const args = r.parseArgs(struct { subject: []const u8, description: []const u8 }, ctx.alloc, call) orelse
        return r.errResult(call, "invalid arguments: expected {\"description\": \"...\"}");

    r.setToolStatusPrint(ctx, call, "new todo {s}", .{args.subject});

    const subject = ctx.alloc.dupe(u8, args.subject) catch
        return r.errResult(call, "out of memory");
    const description = ctx.alloc.dupe(u8, args.description) catch
        return r.errResult(call, "out of memory");

    const id = blk: {
        const g = ctx.agent().todo_list.lock(ctx.io);
        defer g.unlock();
        if (g.ptr.count >= TodoList.max_todos)
            return r.errResult(call, "todo list full (max 64 todos)");

        const tid = g.ptr.next_id;
        g.ptr.next_id += 1;
        g.ptr.todos[g.ptr.count] = .{
            .id = tid,
            .subject = subject,
            .description = description,
            .state = .pending,
        };
        g.ptr.count += 1;
        break :blk tid;
    };

    const msg = std.fmt.allocPrint(ctx.alloc, "Todo created with ID {d}", .{id}) catch
        return r.errResult(call, "out of memory");

    return r.okResult(call, msg);
}

fn getTodo(ctx: tc.ToolContext, call: apt.ToolCall) apt.ToolResult {
    const args = r.parseArgs(struct { id: u32 }, ctx.alloc, call) orelse
        return r.errResult(call, "invalid arguments: expected {\"id\": <number>}");

    const snap = blk: {
        const g = ctx.agent().todo_list.lock(ctx.io);
        defer g.unlock();
        const todo = g.ptr.findById(args.id) orelse
            return r.errResult(call, "todo not found");
        break :blk Todo{
            .id = todo.id,
            .subject = ctx.alloc.dupe(u8, todo.subject) catch
                return r.errResult(call, "out of memory"),
            .description = ctx.alloc.dupe(u8, todo.description) catch
                return r.errResult(call, "out of memory"),
            .state = todo.state,
        };
    };

    r.setToolStatusPrint(ctx, call, "get todo: {s}", .{snap.subject});

    const msg = std.fmt.allocPrint(ctx.alloc, "Todo {d}: [{s}] subject: {s}\n description: {s}", .{
        snap.id, snap.state.toString(), snap.subject, snap.description,
    }) catch return r.errResult(call, "out of memory");

    return r.okResult(call, msg);
}

fn listTodos(ctx: tc.ToolContext, call: apt.ToolCall) apt.ToolResult {
    // Snapshot todos under lock so we can render outside it.
    const snap = blk: {
        const g = ctx.agent().todo_list.lock(ctx.io);
        defer g.unlock();
        if (g.ptr.count == 0) break :blk &[_]Todo{};
        const buf = ctx.alloc.alloc(Todo, g.ptr.count) catch
            return r.errResult(call, "out of memory");
        for (g.ptr.todos[0..g.ptr.count], 0..) |t, i| {
            buf[i] = .{
                .id = t.id,
                .subject = ctx.alloc.dupe(u8, t.subject) catch
                    return r.errResult(call, "out of memory"),
                .description = ctx.alloc.dupe(u8, t.description) catch
                    return r.errResult(call, "out of memory"),
                .state = t.state,
            };
        }
        break :blk @as([]const Todo, buf);
    };

    if (snap.len == 0) return r.okResult(call, "No todos.");

    const spans = ctx.alloc.alloc(r.tui.Span, 1 + snap.len * 2) catch
        return r.errResult(call, "out of memory");
    const lines = ctx.alloc.alloc([]const r.tui.Span, 1 + snap.len) catch
        return r.errResult(call, "out of memory");
    spans[0] = .{ .content = "list todos" };
    lines[0] = spans[0..1];
    for (snap, 0..) |todo, i| {
        const start = 1 + i * 2;
        spans[start] = .{
            .content = todo.state.icon(),
            .style = .{ .fg = switch (todo.state) {
                .pending => .white,
                .in_progress => .yellow,
                .done => .green,
            } },
        };
        spans[start + 1] = .{
            .content = std.fmt.allocPrint(ctx.alloc, " {s}", .{todo.subject}) catch todo.subject,
        };
        lines[i + 1] = spans[start .. start + 2];
    }
    r.setToolStatusParagraph(ctx, call, lines) catch {};

    var allocating = std.Io.Writer.Allocating.init(ctx.alloc);
    for (snap) |todo| {
        allocating.writer.print("{d}. [{s}] subject: {s}\n", .{
            todo.id, todo.state.toString(), todo.subject,
        }) catch return r.errResult(call, "out of memory");
    }

    return r.okResult(call, allocating.written());
}

fn updateTodoState(ctx: tc.ToolContext, call: apt.ToolCall) apt.ToolResult {
    const args = r.parseArgs(struct { id: u32, state: []const u8 }, ctx.alloc, call) orelse
        return r.errResult(call, "invalid arguments: expected {\"id\": <number>, \"state\": \"...\"}");

    const new_state = TodoState.fromString(args.state) orelse
        return r.errResult(call, "invalid state: must be pending, in_progress, or done");

    const snap = blk: {
        const g = ctx.agent().todo_list.lock(ctx.io);
        defer g.unlock();
        const todo = g.ptr.findById(args.id) orelse
            return r.errResult(call, "todo not found");
        todo.state = new_state;
        break :blk .{
            .id = todo.id,
            .subject = ctx.alloc.dupe(u8, todo.subject) catch
                return r.errResult(call, "out of memory"),
            .state = todo.state,
        };
    };

    r.setToolStatusPrint(ctx, call, "update todo {s} {s}", .{ snap.state.icon(), snap.subject });

    const msg = std.fmt.allocPrint(ctx.alloc, "Todo {d} state updated to {s}", .{
        snap.id, new_state.toString(),
    }) catch return r.errResult(call, "out of memory");

    return r.okResult(call, msg);
}

fn updateTodoDetail(ctx: tc.ToolContext, call: apt.ToolCall) apt.ToolResult {
    const args = r.parseArgs(struct { id: u32, description: []const u8 }, ctx.alloc, call) orelse
        return r.errResult(call, "invalid arguments: expected {\"id\": <number>, \"description\": \"...\"}");

    const new_desc = ctx.alloc.dupe(u8, args.description) catch
        return r.errResult(call, "out of memory");

    const id = blk: {
        const g = ctx.agent().todo_list.lock(ctx.io);
        defer g.unlock();
        const todo = g.ptr.findById(args.id) orelse
            return r.errResult(call, "todo not found");
        todo.description = new_desc;
        break :blk todo.id;
    };

    const msg = std.fmt.allocPrint(ctx.alloc, "Todo {d} description updated", .{id}) catch
        return r.errResult(call, "out of memory");

    return r.okResult(call, msg);
}