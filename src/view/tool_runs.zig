const std = @import("std");
const r = @import("../root.zig");
const App = r.app.App;
const blocks = @import("blocks.zig");
const timeline = @import("timeline.zig");

/// Expand or collapse the bash/read run whose summary row sits at (x, y).
pub fn toggleToolRunAt(self: *App, x: u16, y: u16) bool {
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    for (self.view.tool_run_hits.items) |hit| {
        if (!hit.rect.contains(x, y)) continue;
        toggleRun(self, hit.run);
        return true;
    }
    return false;
}

/// Flip `run` between collapsed and expanded and drop cached layouts from its
/// first entry on. Expanding leaves follow mode so the pinned scroll path
/// keeps the summary row in place while the earlier calls open below it; a
/// collapse shrinks the offset back and resumes following once it reaches 0.
pub fn toggleRun(app: *App, run: ToolRun) void {
    const expanded = &app.view.tool_runs_expanded;
    if (!expanded.remove(run.id)) {
        // Run ids of the streaming entry live in the preview arena, which a
        // flush resets; the key must outlive it.
        const key = app.sessionAlloc().dupe(u8, run.id) catch return;
        expanded.put(app.sessionAlloc(), key, {}) catch return;
        if (app.view.auto_scroll) {
            app.view.auto_scroll = false;
            app.view.scroll_offset = 0;
        }
    }
    app.view.invalidateFrom(run.entry);
    app.dirty = true;
}

pub const ToolRunHit = struct {
    rect: r.tui.Rect,
    /// `run.id` is owned by `State.tool_run_hits`: a flush may free the source
    /// between the frame that drew the row and the click.
    run: ToolRun,
};

/// Calls a collapsed bash/read run keeps visible, newest last.
const tool_run_visible = 3;

fn isRunTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "bash") or std.mem.eql(u8, name, "read");
}

/// Consecutive bash/read calls across timeline entries. Visible text, role
/// headers, shown thinking or diffs, and any other tool break a run.
pub const ToolRun = struct {
    /// Call id of the first call; keys `tool_runs_expanded` and click hits.
    id: []const u8,
    /// Timeline index of the entry holding the first call.
    entry: usize,
    len: u32 = 0,
    expanded: bool = false,

    /// Run position of the summary row; null when the run never collapses.
    pub fn anchor(self: ToolRun) ?u32 {
        if (self.len <= tool_run_visible) return null;
        return if (self.expanded) 0 else self.len - tool_run_visible;
    }
};

pub const RunSlot = struct {
    pub const none = std.math.maxInt(u32);
    run: u32 = none,
    pos: u32 = 0,
};

/// Per-frame run layout over the timeline plus the streaming entry. `slots`
/// holds one slot per tool call in part order; `entry_start` indexes it per
/// entry. `forEntry` narrows `slots` to one entry and drops `entry_start`.
pub const ToolRuns = struct {
    runs: []const ToolRun = &.{},
    slots: []const RunSlot = &.{},
    entry_start: []const u32 = &.{},
    /// First entry of the run still open at the stream tail. Entries from
    /// here on change as the run grows, so they bypass the render caches.
    open_entry: usize = std.math.maxInt(usize),

    pub fn forEntry(self: ToolRuns, idx: usize) ToolRuns {
        if (idx + 1 >= self.entry_start.len) return .{};
        return .{ .runs = self.runs, .slots = self.slots[self.entry_start[idx]..self.entry_start[idx + 1]] };
    }
};

pub fn computeToolRuns(
    alloc: std.mem.Allocator,
    entries: []const r.app.TimelineEntry,
    tail: ?r.app.TimelineEntry,
    expanded: *const std.StringHashMapUnmanaged(void),
    flags: r.app.AppFlags,
) !ToolRuns {
    var runs: std.ArrayList(ToolRun) = .empty;
    var slots: std.ArrayList(RunSlot) = .empty;
    const count = entries.len + @intFromBool(tail != null);
    const entry_start = try alloc.alloc(u32, count + 1);
    var open: ?u32 = null;
    var open_entry: usize = std.math.maxInt(usize);
    for (0..count) |idx| {
        const entry = if (idx < entries.len) entries[idx] else tail.?;
        entry_start[idx] = @intCast(slots.items.len);
        // The role header renders above every part of the entry.
        if (entry.role != .agent or r.app.timelineEntryUserText(entry) != null) open = null;
        for (entry.parts) |part| switch (part) {
            .tool_call => |call| {
                if (!isRunTool(call.tool_name)) {
                    open = null;
                    try slots.append(alloc, .{});
                    continue;
                }
                if (open == null) {
                    open = @intCast(runs.items.len);
                    open_entry = idx;
                    try runs.append(alloc, .{ .id = call.call_id, .entry = idx, .expanded = expanded.contains(call.call_id) });
                }
                const run = &runs.items[open.?];
                try slots.append(alloc, .{ .run = open.?, .pos = run.len });
                run.len += 1;
            },
            .message, .plain_text => open = null,
            .thinking => if (flags.show_thinking) {
                open = null;
            },
            .diff => if (flags.show_diffs) {
                open = null;
            },
        };
    }
    entry_start[count] = @intCast(slots.items.len);
    return .{
        .runs = runs.items,
        .slots = slots.items,
        .entry_start = entry_start,
        .open_entry = if (open != null) open_entry else std.math.maxInt(usize),
    };
}

pub fn appendRunSummary(
    arena: std.mem.Allocator,
    out: *std.ArrayList(blocks.RenderParagraphItem),
    total: *usize,
    app: *App,
    run: ToolRun,
    inner_w: u16,
) !void {
    var p = r.tui.Paragraph{ .wrap = false, .padding = .all(blocks.tool_pad) };
    p.style.bg = app.theme.bg;
    var line = r.tui.Line{};
    const style: r.tui.Style = .{ .fg = app.theme.muted };
    if (run.expanded) {
        try line.pushSpanPrint(arena, "▾ {d} calls", .{run.len}, style);
    } else {
        try line.pushSpanPrint(arena, "▸ {d} earlier calls", .{run.len - tool_run_visible}, style);
    }
    try p.lines.append(arena, line);
    const h = p.totalHeightLong(inner_w);
    try out.append(arena, .{ .p = p, .h = h, .is_tool_block = true, .toggle_run = run });
    total.* += h;
    blocks.collapseToolPadding(out, total);
}

fn runTestStack(app: *App, alloc: std.mem.Allocator, entries: []const r.app.TimelineEntry) ![]const []const u8 {
    const runs = try computeToolRuns(alloc, entries, null, &app.view.tool_runs_expanded, app.flags);
    var items: std.ArrayList(blocks.RenderParagraphItem) = .empty;
    var total: usize = 0;
    var i = entries.len;
    while (i > 0) {
        i -= 1;
        var scratch: std.ArrayList(blocks.RenderParagraphItem) = .empty;
        var delta: usize = 0;
        try blocks.buildTimelineEntryParagraph(alloc, &scratch, &delta, app, entries[i], 40, false, runs.forEntry(i));
        try timeline.appendEntryRenderItems(alloc, &items, &total, scratch.items);
    }
    var buf = try r.tui.Buffer.init(std.testing.allocator, .{ .width = 40, .height = 30 });
    defer buf.deinit();
    app.view.clearRunHits(app.gpa);
    timeline.renderTimelineStack(app, .{ .items = items, .total = total }, .{ .width = 40, .height = 30 }, &buf);

    // Text of every line, top-down.
    var out: std.ArrayList([]const u8) = .empty;
    var k = items.items.len;
    while (k > 0) {
        k -= 1;
        for (items.items[k].p.lines.items) |line| {
            var text: std.ArrayList(u8) = .empty;
            for (line.spans.items) |span| try text.appendSlice(alloc, span.content);
            try out.append(alloc, text.items);
        }
    }
    return out.items;
}

test "sequential bash and read calls collapse to the newest three and expand on click" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    var registry = r.agent_registry.Registry.init(gpa, std.testing.io);
    defer registry.deinit();
    var app: App = undefined;
    app.io = std.testing.io;
    app.gpa = gpa;
    app.mu = .init;
    app.registry = &registry;
    app.theme = .default;
    app.flags = .{};
    app.frame_count = 0;
    app.kitty_graphics = false;
    app.dirty = false;
    app.view.auto_scroll = true;
    app.view.scroll_offset = 0;
    app.tool_status_entries = .{};
    app.view.tool_runs_expanded = .empty;
    app.view.tool_run_hits = .empty;
    defer app.view.tool_run_hits.deinit(gpa);
    defer app.view.clearRunHits(gpa);
    app.view.entry_cache = .empty;
    app.view.entry_layout = null;
    app.view.entry_content = null;
    defer app.view.entry_cache.deinit(gpa);
    app.inline_placements = .empty;
    app.arena_frame = .init(gpa);
    defer app.arena_frame.deinit();
    app.arena_session = .init(gpa);
    defer app.arena_session.deinit();
    app.view.arena_timeline_render = .init(gpa);
    defer app.view.arena_timeline_render.deinit();

    const id = r.AgentId{ .index = 0, .generation = 0 };
    const statuses = try app.tool_status_entries.value.forWrite(alloc, id);
    const calls = [_][2][]const u8{
        .{ "c1", "bash" }, .{ "c2", "read" }, .{ "c3", "bash" }, .{ "c4", "bash" },
        .{ "c5", "bash" }, .{ "c6", "edit" }, .{ "c7", "bash" },
    };
    var parts: [calls.len]r.app.TimelinePart = undefined;
    for (calls, 0..) |c, n| {
        var entry = r.app.ToolStatusEntry{ .is_error = false };
        try entry.lines.append(alloc, try r.tui.Line.new(alloc, "{s}", .{c[0]}, .{}));
        if (std.mem.eql(u8, c[0], "c3")) try entry.lines.append(alloc, try r.tui.Line.new(alloc, "more", .{}, .{}));
        try statuses.entries.put(alloc, c[0], entry);
        parts[n] = .{ .tool_call = .{ .agent_id = id, .call_id = c[0], .tool_name = c[1] } };
    }
    var user_parts = [_]r.app.TimelinePart{.{ .plain_text = "go" }};
    var think_parts = [_]r.app.TimelinePart{ .{ .thinking = "hmm" }, parts[1] };
    const entries = [_]r.app.TimelineEntry{
        .{ .role = .user, .parts = &user_parts },
        .{ .role = .agent, .parts = parts[0..1] },
        .{ .role = .agent, .parts = &think_parts },
        .{ .role = .agent, .parts = parts[2..4] },
        .{ .role = .agent, .parts = parts[4..5] },
        .{ .role = .agent, .parts = parts[5..6] },
        .{ .role = .agent, .parts = parts[6..7] },
    };

    const runs = try computeToolRuns(alloc, &entries, null, &app.view.tool_runs_expanded, app.flags);
    try std.testing.expectEqual(@as(usize, 2), runs.runs.len);
    try std.testing.expectEqual(@as(u32, 5), runs.runs[0].len);
    try std.testing.expectEqual(@as(u32, 1), runs.runs[1].len);
    try std.testing.expectEqual(@as(usize, 6), runs.open_entry);

    app.flags.show_thinking = true;
    const split = try computeToolRuns(alloc, &entries, null, &app.view.tool_runs_expanded, app.flags);
    try std.testing.expectEqual(@as(usize, 3), split.runs.len);
    try std.testing.expectEqual(@as(u32, 4), split.runs[1].len);
    app.flags.show_thinking = false;

    const collapsed = try runTestStack(&app, alloc, &entries);
    const ok = r.tui.icon.ok ++ " ";
    const mid = " ├ " ++ ok;
    const last = " └ " ++ ok;
    const want_collapsed = [_][]const u8{ "❯ you:", "go", "▸ 2 earlier calls", mid ++ "c3", " │   more", mid ++ "c4", last ++ "c5", ok ++ "c6", ok ++ "c7" };
    try std.testing.expectEqual(want_collapsed.len, collapsed.len);
    for (want_collapsed, collapsed) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expectEqual(@as(usize, 1), app.view.tool_run_hits.items.len);

    const hit = app.view.tool_run_hits.items[0].rect;
    try std.testing.expect(!toggleToolRunAt(&app, hit.x, hit.y +| hit.height));
    try std.testing.expect(toggleToolRunAt(&app, hit.x, hit.y));
    try std.testing.expect(app.view.tool_runs_expanded.contains("c1"));
    try std.testing.expect(!app.view.auto_scroll);
    const expanded = try runTestStack(&app, alloc, &entries);
    const want_expanded = [_][]const u8{ "❯ you:", "go", "▾ 5 calls", mid ++ "c1", mid ++ "c2", mid ++ "c3", " │   more", mid ++ "c4", last ++ "c5", ok ++ "c6", ok ++ "c7" };
    try std.testing.expectEqual(want_expanded.len, expanded.len);
    for (want_expanded, expanded) |want, got| try std.testing.expectEqualStrings(want, got);

    const again = app.view.tool_run_hits.items[0].rect;
    try std.testing.expect(toggleToolRunAt(&app, again.x, again.y));
    try std.testing.expect(!app.view.tool_runs_expanded.contains("c1"));

    // A run that starts in the streaming entry carries a preview-arena id; a
    // flush frees it between the frame that drew the row and the click.
    var preview = std.heap.ArenaAllocator.init(gpa);
    defer preview.deinit();
    const streamed = try preview.allocator().dupe(u8, "c1");
    parts[0].tool_call.call_id = streamed;
    _ = try runTestStack(&app, alloc, &entries);
    @memset(streamed, 'x');
    const stale = app.view.tool_run_hits.items[0].rect;
    try std.testing.expect(toggleToolRunAt(&app, stale.x, stale.y));
    app.view.clearRunHits(gpa);
    try std.testing.expect(app.view.tool_runs_expanded.contains("c1"));
}
