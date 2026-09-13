const std = @import("std");
const r = @import("root.zig");
const App = r.app.App;
const TimelinePart = r.app.TimelinePart;

const bench_width: u16 = 120;
const bench_height: u16 = 40;
const settled_entry_count: usize = 200;
const measured_frames: usize = 400;

fn nowNs(io: std.Io) i128 {
    return @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds);
}

const user_markdown_head =
    \\## Release notes
    \\The pipeline now streams parts as they arrive.
    \\
    \\- tokens flush every 40ms
    \\- tool calls render inline
    \\- errors keep the full body
    \\
    \\```zig
    \\const event = try drainNext(io, queue);
    \\if (event == .text) preview.append(event.text);
    \\```
    \\
    \\Ship it when the bench stays under budget.
;

const agent_markdown =
    \\Done. Changed `src/app.zig` to flush the preview on `.step`:
    \\
    \\1. preview arena reset per step
    \\2. streaming entry rebuilt from parts
    \\3. settled entries cached by width
    \\
    \\No regressions in `make test`.
;

fn buildTranscript(app: *App, agent: *r.agent.Agent, arena: std.mem.Allocator) !void {
    var history: std.ArrayList(r.sdk.Message) = .empty;

    for (0..settled_entry_count) |i| {
        const call_id = try std.fmt.allocPrint(arena, "call_{d}", .{i});
        const user_text = try std.fmt.allocPrint(arena, "{s}\n\npass {d}: verify the numbers hold.", .{ user_markdown_head, i });
        if (i % 2 == 0) {
            const parts = try arena.alloc(TimelinePart, 1);
            parts[0] = .{ .message = user_text };
            try app.appendTimelineEntry(app.sessionAlloc(), .{ .role = .user, .parts = parts });
            continue;
        }
        const tool_name: []const u8 = if (i % 4 == 1) "bash" else "edit";
        const input = try std.fmt.allocPrint(arena, "{{\"cmd\": \"make test {d}\"}}", .{i});
        const assistant_parts = try arena.dupe(r.sdk.Part, &.{
            r.sdk.Part.toolCallPart(call_id, tool_name, input),
            r.sdk.Part.textPart(agent_markdown),
        });
        try history.append(arena, .{ .role = .assistant, .content = assistant_parts });
        const output = try std.fmt.allocPrint(arena, "ok {d}\ncompiled\n0 failed", .{i});
        const result_parts = try arena.dupe(r.sdk.Part, &.{r.sdk.Part.toolResultPart(call_id, tool_name, output)});
        try history.append(arena, .{ .role = .tool, .content = result_parts });

        const parts = try arena.alloc(TimelinePart, 2);
        parts[0] = .{ .tool_call = .{ .agent_id = app.main_agent_id.?, .call_id = call_id, .tool_name = tool_name } };
        parts[1] = .{ .message = agent_markdown };
        try app.appendTimelineEntry(app.sessionAlloc(), .{ .role = .agent, .parts = parts });
    }

    try agent.setMessages(history.items);

    const running_parts = try app.sessionAlloc().alloc(TimelinePart, 1);
    running_parts[0] = .{ .tool_call = .{
        .agent_id = app.main_agent_id.?,
        .call_id = "call_running",
        .tool_name = "bash",
    } };
    try app.appendTimelineEntry(app.sessionAlloc(), .{ .role = .agent, .parts = running_parts });
}

fn runScenario(app: *App, buf: *r.tui.Buffer, previous: *r.tui.Buffer, dirty: bool, io: std.Io) u64 {
    const start = nowNs(io);
    for (0..measured_frames) |_| {
        app.dirty = dirty;
        buf.clear();
        App.render(app, buf.rect, buf);
        app.frame_count +%= 1;
        app.dirty = false;
        @memcpy(previous.cells, buf.cells);
    }
    const end = nowNs(io);
    return @intCast(end - start);
}

fn printLine(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    const out = std.Io.File.stdout();
    var buf: [512]u8 = undefined;
    var w = out.writerStreaming(io, &buf);
    w.interface.print(fmt ++ "\n", args) catch return;
    w.interface.flush() catch {};
}

fn report(label: []const u8, total_ns: u64, io: std.Io) void {
    const per_frame: f64 = @as(f64, @floatFromInt(total_ns)) / measured_frames;
    const frames_per_s: f64 = std.time.ns_per_s / per_frame;
    printLine(io, "{s:<18} {d:>10.0} ns/frame  {d:>8.0} frames/s", .{ label, per_frame, frames_per_s });
}

pub fn main(init: std.process.Init) !void {
    var io_state = std.Io.Threaded.init(init.gpa, .{
        .stack_size = 2 * 1024 * 1024,
        .async_limit = .unlimited,
        .concurrent_limit = .unlimited,
        .argv0 = .init(init.minimal.args),
        .environ = init.minimal.environ,
    });
    defer io_state.deinit();
    const io = io_state.io();
    const gpa = init.gpa;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const work_dir = try std.fmt.allocPrint(arena, "/tmp/blitzdenk-bench-{d}", .{std.c.getpid()});
    std.Io.Dir.cwd().createDirPath(io, work_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, work_dir) catch {};
    _ = std.c.chdir(try arena.dupeZ(u8, work_dir));

    const context_factory = try r.ContextFactory.init(gpa, io, work_dir, work_dir);
    var app = try App.init(io, gpa, context_factory, work_dir);
    var registry = r.agent_registry.Registry.init(gpa, io);
    var exec_pool = r.exec.CmdPool.init(gpa, io, init.environ_map);
    app.registry = &registry;
    app.exec_pool = &exec_pool;
    defer {
        app.cancelPermissions(null);
        registry.cancelAll();
        r.artifact.cleanup(&exec_pool);
        app.deinit();
        registry.deinit();
        exec_pool.deinit();
    }

    app.reset();
    const agent_id = registry.reserve().?;
    const agent = try registry.activate(agent_id, .{
        .api_key = "bench",
        .model = "bench-model",
        .base_url = "https://bench.invalid/v1",
        .provider = .{ .openai = .{} },
    }, .{});
    app.main_agent_id = agent_id;
    app.running = true;

    try buildTranscript(&app, agent, arena);
    try app.input_buffer.appendSlice(app.sessionAlloc(), "explain the render fast path\nand show the bench numbers");

    var buf = try r.tui.Buffer.init(gpa, .{ .x = 0, .y = 0, .width = bench_width, .height = bench_height });
    defer buf.deinit();
    var previous = try r.tui.Buffer.init(gpa, buf.rect);
    defer previous.deinit();
    app.frame_snapshot = &previous;

    printLine(io, "render bench  {d}x{d}  {d} settled entries + 1 running tool block", .{ bench_width, bench_height, settled_entry_count });

    const structural_ns = runScenario(&app, &buf, &previous, true, io);
    const animation_ns = runScenario(&app, &buf, &previous, false, io);
    report("structural frame", structural_ns, io);
    report("animation frame", animation_ns, io);
    if (animation_ns >= structural_ns) return error.FastPathNotFaster;

    var live_row: ?u16 = null;
    var row: u16 = 0;
    while (row < buf.rect.height) : (row += 1) {
        var col: u16 = 0;
        while (col < buf.rect.width) : (col += 1) {
            const ch = buf.get(col, row).char;
            if (ch >= 0x2800 and ch <= 0x28FF) live_row = row;
        }
    }
    if (live_row == null) {
        printLine(io, "no spinner found on screen", .{});
        return error.NoSpinnerOnScreen;
    }

    var glyphs_seen: [8]u21 = @splat(0);
    var glyphs_count: usize = 0;
    for (0..24) |_| {
        buf.clear();
        App.render(&app, buf.rect, &buf);
        app.frame_count +%= 1;
        app.dirty = false;
        @memcpy(previous.cells, buf.cells);
        var col2: u16 = 0;
        while (col2 < buf.rect.width) : (col2 += 1) {
            const ch = buf.get(col2, live_row.?).char;
            if (ch < 0x2800 or ch > 0x28FF) continue;
            var known = false;
            for (glyphs_seen[0..glyphs_count]) |g| {
                if (g == ch) known = true;
            }
            if (!known and glyphs_count < glyphs_seen.len) {
                glyphs_seen[glyphs_count] = ch;
                glyphs_count += 1;
            }
        }
    }
    if (glyphs_count < 3) {
        printLine(io, "spinner frozen on the fast path ({d} glyphs seen)", .{glyphs_count});
        return error.SpinnerFrozen;
    }
}
