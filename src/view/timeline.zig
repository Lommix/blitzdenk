const std = @import("std");
const r = @import("../root.zig");
const App = r.app.App;
const blocks = @import("blocks.zig");
const tool_runs = @import("tool_runs.zig");
const tools = @import("tools.zig");
const view = @import("root.zig");

pub fn handleScrollbarMouse(self: *App, m: r.tui.Terminal.Mouse) bool {
    if (m.button != .left) {
        if (self.view.scrollbar_dragging and m.action != .move) self.view.scrollbar_dragging = false;
        return false;
    }
    if (self.view.scrollbar_track.height == 0) {
        self.view.scrollbar_dragging = false;
        return false;
    }
    if (!self.view.scrollbar_dragging) {
        if (m.action != .press) return false;
        if (!self.view.scrollbar_track.contains(m.x, m.y)) return false;
        const offset: usize = if (self.view.auto_scroll) 0 else self.view.scroll_offset;
        const met = scrollbarMetrics(self.view.scrollbar_max, self.view.scrollbar_track.height, offset);
        const nob_top = self.view.scrollbar_track.y + met.nob_top;
        const on_nob = m.y >= nob_top and m.y < nob_top + met.nob_h;
        self.view.scrollbar_grab = if (on_nob) m.y - nob_top else met.nob_h / 2;
        self.view.scrollbar_drag_max = self.view.scrollbar_max;
        self.view.scrollbar_dragging = true;
        if (!on_nob) dragScrollbarTo(self, m.y);
        return true;
    }
    switch (m.action) {
        .press => {
            if (!self.view.scrollbar_track.contains(m.x, m.y)) {
                self.view.scrollbar_dragging = false;
                return false;
            }
            return true;
        },
        .move => {
            dragScrollbarTo(self, m.y);
            return true;
        },
        .release => {
            self.view.scrollbar_dragging = false;
            return true;
        },
    }
}

fn dragScrollbarTo(self: *App, pointer_y: u16) void {
    const max_offset = self.view.scrollbar_drag_max;
    if (max_offset == 0) return;
    const v: usize = self.view.scrollbar_track.height;
    const nob_h: usize = scrollbarNobHeight(max_offset, self.view.scrollbar_track.height);
    const span = @max(v -| nob_h, 1);
    const rel_raw: isize = @as(isize, pointer_y) - @as(isize, self.view.scrollbar_track.y) - @as(isize, self.view.scrollbar_grab);
    const rel: usize = @intCast(@min(@max(rel_raw, 0), @as(isize, @intCast(span))));
    const offset = max_offset -| (rel * max_offset + span / 2) / span;
    self.view.scroll_offset = offset;
    self.view.auto_scroll = offset == 0;
    self.dirty = true;
}

pub const TimelineStack = struct {
    items: std.ArrayList(blocks.RenderParagraphItem) = .empty,
    total: usize = 0,
    full_total: usize = 0,
    scroll_offset: usize = 0,
    overflow: bool = false,
    /// The scroll offset moved to pin the view; the caller rebuilds with it.
    pinned_shift: bool = false,
};

/// Facing edge of an entry's block stack, for tool block seams.
pub const Edge = enum { empty, tool, other };

/// One timeline entry as last measured. `h` excludes seams to neighbouring
/// entries. In the cache, `items` holds prewrapped blocks once the entry is
/// cacheable; `entryLayout` also returns freshly built blocks in it.
pub const EntrySlot = struct {
    h: usize,
    top: Edge,
    bottom: Edge,
    items: ?[]blocks.RenderParagraphItem = null,
};

/// Inputs every cached height depends on.
pub const LayoutKey = struct {
    width: u16,
    show_thinking: bool,
    show_diffs: bool,
    inline_images: bool,
    has_agent: bool,
    cell_px: r.tui.kitty.CellPixels,
    image_gen: u64,
};

/// Inputs cached blocks depend on beyond layout: tool results come from history.
pub const ContentKey = struct {
    agent_key: ?u32,
    history_gen: u64,
};

pub fn callChildrenReady(app: *App, call: r.app.TimelinePart.ToolCallEntry, cacheable: bool) bool {
    const statuses = app.tool_status_entries.lock(app.io);
    defer statuses.unlock();
    const status_agent = statuses.ptr.getAgent(call.agent_id) orelse return true;
    const entry = status_agent.entries.getPtr(call.call_id) orelse return true;
    for (entry.child_ids.items) |child| {
        if (cacheable) {
            if (app.registry.state(child) != null) return false;
        } else if (!app.registry.subtreeDone(child)) return false;
    }
    return true;
}

fn timelineEntrySettled(app: *App, entry: r.app.TimelineEntry) bool {
    for (entry.parts) |part| switch (part) {
        .tool_call => |call| {
            const agent = app.registry.get(call.agent_id) orelse return false;
            if (tools.findToolResult(agent, call.call_id) == null) return false;
            if (!callChildrenReady(app, call, false)) return false;
        },
        else => {},
    };
    return true;
}

fn entryRenderCacheable(app: *App, entry: r.app.TimelineEntry, inner_w: u16) bool {
    if (inner_w == 0) return false;
    for (entry.parts) |part| switch (part) {
        .tool_call => |call| {
            const agent = app.registry.get(call.agent_id) orelse return false;
            if (tools.findToolResult(agent, call.call_id) == null) return false;
            if (!callChildrenReady(app, call, true)) return false;
        },
        else => {},
    };
    return true;
}

/// Drop slots whose keys changed, and slots of the open bash/read run: those
/// change as the run grows, and may predate an undo that reopened the run.
fn syncEntryCache(app: *App, inner_w: u16, maybe_agent: ?*r.agent.Agent, open_entry: usize) void {
    const v = &app.view;
    const layout: LayoutKey = .{
        .width = inner_w,
        .show_thinking = app.flags.show_thinking,
        .show_diffs = app.flags.show_diffs,
        .inline_images = app.flags.inline_images,
        .has_agent = maybe_agent != null,
        .cell_px = app.cell_px,
        .image_gen = app.inline_images.eviction_gen,
    };
    const content: ContentKey = .{
        .agent_key = if (maybe_agent != null) app.main_agent_id.?.pack() else null,
        .history_gen = if (maybe_agent) |agent| agent.history_gen else 0,
    };
    if (!std.meta.eql(v.entry_layout, layout)) {
        v.invalidateRenderCache();
    } else if (!std.meta.eql(v.entry_content, content)) {
        for (v.entry_cache.items) |*slot| {
            if (slot.*) |*s| s.items = null;
        }
        _ = v.arena_timeline_render.reset(.free_all);
    }
    v.entry_layout = layout;
    v.entry_content = content;
    const keep = @min(app.timeline.items.len, open_entry);
    if (v.entry_cache.items.len > keep) v.entry_cache.shrinkRetainingCapacity(keep);
}

fn edgeOf(items: []const blocks.RenderParagraphItem, top: bool) Edge {
    if (items.len == 0) return .empty;
    // Items are bottom-up: the last item is the top block.
    const item = if (top) items[items.len - 1] else items[0];
    return if (item.is_tool_block) .tool else .other;
}

/// Measure timeline entry `idx`, building its blocks when `need_items` or no
/// height is cached. Settled entries keep their height; cacheable entries
/// built for display also keep their prewrapped blocks. The returned slot
/// carries the built blocks even when the cache keeps only the height.
fn entryLayout(
    app: *App,
    alloc: std.mem.Allocator,
    idx: usize,
    inner_w: u16,
    runs: tool_runs.ToolRuns,
    need_items: bool,
) !EntrySlot {
    const cache = &app.view.entry_cache;
    if (idx < cache.items.len) if (cache.items[idx]) |slot| {
        if (slot.items != null or !need_items) return slot;
    };
    const entry = app.timeline.items[idx];
    const cacheable = need_items and idx < runs.open_entry and entryRenderCacheable(app, entry, inner_w);
    const build_alloc = if (cacheable) app.view.arena_timeline_render.allocator() else alloc;
    var scratch: std.ArrayList(blocks.RenderParagraphItem) = .empty;
    var h: usize = 0;
    try blocks.buildTimelineEntryParagraph(build_alloc, &scratch, &h, app, entry, inner_w, need_items and !cacheable, runs.forEntry(idx));
    var slot: EntrySlot = .{ .h = h, .top = edgeOf(scratch.items, true), .bottom = edgeOf(scratch.items, false), .items = scratch.items };
    var kept = slot;
    const wrapped_h: ?usize = if (cacheable) prewrapItems(build_alloc, scratch.items, inner_w) else null;
    if (wrapped_h) |total| {
        slot.h = total;
        kept = slot;
    } else if (idx < runs.open_entry and timelineEntrySettled(app, entry)) {
        kept.items = null;
    } else return slot;
    while (cache.items.len <= idx) cache.append(app.gpa, null) catch return slot;
    cache.items[idx] = kept;
    return slot;
}

fn prewrapItems(arena: std.mem.Allocator, items: []blocks.RenderParagraphItem, inner_w: u16) ?usize {
    var total: usize = 0;
    for (items) |*item| {
        if (!item.p.prewrap(arena, inner_w)) return null;
        item.h = item.p.totalHeightLong(inner_w);
        total += item.h;
    }
    return total;
}

pub fn appendEntryRenderItems(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(blocks.RenderParagraphItem),
    total: *usize,
    items: []const blocks.RenderParagraphItem,
) !void {
    for (items) |item| {
        try out.append(alloc, item);
        total.* += item.h;
        blocks.collapseToolPadding(out, total);
    }
}

pub fn buildTimelineStack(app: *App, alloc: std.mem.Allocator, inner_w: u16, inner_h: u16) !TimelineStack {
    var s = TimelineStack{};
    const maybe_agent: ?*r.agent.Agent = if (app.main_agent_id) |id| app.registry.get(id) else null;
    const runs = try tool_runs.computeToolRuns(alloc, app.timeline.items, app.streaming_entry, &app.view.tool_runs_expanded, app.flags);
    syncEntryCache(app, inner_w, maybe_agent, runs.open_entry);

    var scroll_offset_usize: usize = if (app.view.auto_scroll) 0 else app.view.scroll_offset;
    const target: usize = @as(usize, inner_h) +| scroll_offset_usize;

    // Failed agent path
    if (app.main_agent_id) |id| {
        const slot = &app.registry.slots[id.index];
        if (slot.state.load(.acquire) == .failed) {
            const detail = if (slot.agent.?.last_error) |err| @errorName(err) else null;

            var para = r.tui.Paragraph{};
            try para.appendLineSpan(alloc, &.{
                .{ .content = "ERROR: ", .style = .{ .fg = app.theme.warn, .modifier = .{ .bold = true } } },
                .{ .content = "Press Ctrl+R to retry", .style = .{ .fg = app.theme.muted } },
            });

            if (detail) |txt| {
                try para.appendText(alloc, txt, .{ .fg = app.theme.warn, .modifier = .{ .italic = true } });
            }
            const h = para.totalHeightLong(inner_w);
            try s.items.append(alloc, .{ .p = para, .h = h });
            s.total += h;
        }
    }

    // build in reverse
    var i = app.timeline.items.len;

    // TODO: Add propose preview
    // preview diff
    if (app.active_permission) |perm| {
        if (perm.payload == .diff) {
            var parts = try alloc.alloc(r.app.TimelinePart, 1);
            parts[0] = try r.app.diffTimelinePart(alloc, perm.payload.diff);
            try blocks.buildTimelineEntryParagraph(alloc, &s.items, &s.total, app, .{
                .role = .agent,
                .parts = parts,
            }, inner_w, true, .{});
        }
    }

    if (app.streaming_entry) |entry| {
        try blocks.buildTimelineEntryParagraph(alloc, &s.items, &s.total, app, entry, inner_w, true, runs.forEntry(app.timeline.items.len));
    }

    while (i > 0 and s.total < target) {
        i -= 1;
        const entry = app.timeline.items[i];
        if (maybe_agent == null and entry.role != .system) continue;
        const slot = try entryLayout(app, alloc, i, inner_w, runs, true);
        try appendEntryRenderItems(alloc, &s.items, &s.total, slot.items orelse &.{});
    }

    // Rows above the walked window, top-down, with seams between entries.
    var hidden: usize = 0;
    var above: Edge = .empty;
    for (0..i) |idx| {
        const entry = app.timeline.items[idx];
        if (maybe_agent == null and entry.role != .system) continue;
        const slot = entryLayout(app, alloc, idx, inner_w, runs, false) catch break;
        if (slot.top == .empty) continue;
        hidden += slot.h -| blocks.toolSeam(slot.top == .tool, above == .tool);
        above = slot.bottom;
    }
    s.full_total = s.total +| hidden;

    if (i > 0 and s.items.items.len > 0) {
        const walked_top_tool = s.items.items[s.items.items.len - 1].is_tool_block;
        s.full_total -|= blocks.toolSeam(walked_top_tool, above == .tool);
    }

    const max_scroll: usize = s.full_total -| inner_h;
    if (app.view.scroll_total_width != inner_w) {
        app.view.scroll_total_width = inner_w;
    } else if (!app.view.auto_scroll and !app.view.scrollbar_dragging and s.full_total != app.view.scroll_total) {
        // Keep the viewed rows still while content below them grows or
        // shrinks: streamed output, run folds, expands and collapses.
        if (s.full_total > app.view.scroll_total) {
            app.view.scroll_offset +|= s.full_total - app.view.scroll_total;
        } else {
            app.view.scroll_offset -|= app.view.scroll_total - s.full_total;
            if (app.view.scroll_offset == 0) app.view.auto_scroll = true;
        }
        scroll_offset_usize = if (app.view.auto_scroll) 0 else app.view.scroll_offset;
        s.pinned_shift = true;
    }
    app.view.scroll_total = s.full_total;

    if (scroll_offset_usize > max_scroll) {
        scroll_offset_usize = max_scroll;
        app.view.scroll_offset = max_scroll;
        if (max_scroll == 0) app.view.auto_scroll = true;
    }

    s.scroll_offset = scroll_offset_usize;
    s.overflow = s.full_total > inner_h;
    return s;
}

pub fn renderTimelineStack(app: *App, s: TimelineStack, area: r.tui.Rect, buf: *r.tui.Buffer) void {
    if (area.width == 0 or area.height == 0) return;

    const alloc = app.arena_frame.allocator();
    const inner_w: u16 = area.width;
    const inner_h: u16 = area.height;
    const scroll_offset_usize: usize = s.scroll_offset;

    // Render bottom-up. anchor_y is the row JUST BELOW the next paragraph's
    // bottom border. When the stack does not fill the area, anchor below the
    // last visible row instead of the area bottom — keeps short timelines top-aligned
    // and lets paragraphs grow downward until they hit the input.
    const viewport_top: i128 = area.y;
    const viewport_bottom: i128 = @as(i128, area.y) + @as(i128, inner_h);
    const fill_bottom: usize = @min(s.total, @as(usize, inner_h));
    var anchor_y: i128 = @as(i128, area.y) + @as(i128, @intCast(fill_bottom)) + @as(i128, @intCast(scroll_offset_usize));

    for (s.items.items) |e| {
        const item_bottom = anchor_y;
        const item_top = item_bottom - @as(i128, @intCast(e.h));
        defer anchor_y = item_top;

        if (item_bottom <= viewport_top) break;
        if (item_top >= viewport_bottom) continue;

        const visible_top = @max(item_top, viewport_top);
        const visible_bottom = @min(item_bottom, viewport_bottom);
        if (visible_top >= visible_bottom) continue;

        var p = e.p;
        if (p.reverse) {
            p.scroll_offset = @intCast(item_bottom - visible_bottom);
        } else if (e.is_tool_block) {
            const skip: usize = @intCast(visible_top - item_top);
            p.scroll_offset +|= skip -| p.padding.top;
            p.padding.top -|= @intCast(@min(skip, p.padding.top));
            const cut_bottom: usize = @intCast(item_bottom - visible_bottom);
            p.padding.bottom -|= @intCast(@min(cut_bottom, p.padding.bottom));
        } else {
            p.scroll_offset +|= @intCast(visible_top - item_top);
        }

        const sub: r.tui.Rect = .{
            .x = area.x,
            .y = @intCast(visible_top),
            .width = inner_w,
            .height = @intCast(visible_bottom - visible_top),
        };
        if (e.toggle_run) |run| {
            if (app.gpa.dupe(u8, run.id)) |owned| {
                var hit_run = run;
                hit_run.id = owned;
                app.view.tool_run_hits.append(app.gpa, .{ .rect = sub, .run = hit_run }) catch app.gpa.free(owned);
            } else |_| {}
        }
        if (e.live_calls != null) {
            var recorded = e;
            recorded.p = p;
            view.recordFrameSnapshotTool(app, recorded, sub, inner_w);
        }
        recordToolInlinePlacements(app, e.inline_images, p, sub);
        p.render(alloc, sub, area, buf);
    }
}

fn recordToolInlinePlacements(app: *App, images: []const blocks.ToolInlineImage, p: r.tui.Paragraph, area: r.tui.Rect) void {
    const content_top: i128 = @as(i128, area.y) + p.padding.top;
    const content_bottom: i128 = @as(i128, area.y) + area.height - p.padding.bottom;
    for (images) |img| {
        const top = content_top + @as(i128, @intCast(img.row)) - @as(i128, @intCast(p.scroll_offset));
        const bottom = top + img.rows;
        const visible_top = @max(top, content_top);
        const visible_bottom = @min(bottom, content_bottom);
        if (visible_top >= visible_bottom) continue;
        recordInlinePlacement(app, img.entry, img.cols, area.x +| p.padding.left +| img.col, img.rows, top, visible_top, visible_bottom);
    }
}

fn recordInlinePlacement(
    app: *App,
    entry: *r.inline_images.Entry,
    cols: u16,
    x: u16,
    full_rows: usize,
    item_top: i128,
    visible_top: i128,
    visible_bottom: i128,
) void {
    if (entry.state.load(.acquire) != .ready) return;
    const img = entry.img orelse return;
    if (cols == 0 or full_rows == 0 or img.width == 0 or img.height == 0) return;
    const skip: u64 = @intCast(@max(0, visible_top - item_top));
    const vis: u64 = @intCast(@max(0, visible_bottom - visible_top));
    if (vis == 0 or skip >= full_rows) return;
    const src_y: u32 = @intCast(@as(u64, img.height) * skip / full_rows);
    var src_h: u32 = @intCast(@as(u64, img.height) * vis / full_rows);
    src_h = @max(1, @min(src_h, img.height - src_y));
    app.inline_placements.append(app.gpa, .{
        .entry = entry,
        .rect = .{
            .x = x,
            .y = @intCast(@max(0, visible_top)),
            .width = cols,
            .height = @intCast(@min(vis, std.math.maxInt(u16))),
        },
        .src = .{ .x = 0, .y = src_y, .w = img.width, .h = src_h },
    }) catch {};
}

pub const scrollbar_strip_width: u16 = 3;

const ScrollbarMetrics = struct { nob_top: u16, nob_h: u16 };

fn scrollbarNobHeight(max_offset: usize, viewport: u16) u16 {
    const v: usize = viewport;
    if (v == 0) return 0;
    const total = v +| max_offset;
    return @intCast(@min(v, @max(@as(usize, 1), v * v / total)));
}

fn scrollbarMetrics(max_offset: usize, viewport: u16, offset: usize) ScrollbarMetrics {
    const v: usize = viewport;
    if (v == 0 or max_offset == 0) return .{ .nob_top = 0, .nob_h = 0 };
    const nob_h: usize = scrollbarNobHeight(max_offset, viewport);
    const span = v - nob_h;
    const off = @min(offset, max_offset);
    const nob_top = (max_offset - off) * span / max_offset;
    return .{ .nob_top = @intCast(nob_top), .nob_h = @intCast(nob_h) };
}

pub fn renderTimelineScrollbar(app: *App, cs: TimelineStack, content_area: r.tui.Rect, buf: *r.tui.Buffer) void {
    const viewport: usize = content_area.height;
    if (content_area.width == 0 or viewport == 0 or !cs.overflow) return;
    const live_max = cs.full_total -| viewport;
    const max_offset: usize = if (app.view.scrollbar_dragging) app.view.scrollbar_drag_max else live_max;
    const met = scrollbarMetrics(max_offset, content_area.height, cs.scroll_offset);

    const track_x = content_area.x + content_area.width + 1;
    const track_style: r.tui.Style = .{ .fg = app.theme.muted, .modifier = .{ .dim = true } };
    var row: u16 = 0;
    while (row < content_area.height) : (row += 1) {
        buf.set(track_x, content_area.y + row, .{ .char = '│', .style = track_style });
    }
    const nob_style: r.tui.Style = .{ .fg = app.theme.info, .modifier = .{ .bold = true } };
    var nob_row: u16 = 0;
    while (nob_row < met.nob_h) : (nob_row += 1) {
        buf.set(track_x, content_area.y + met.nob_top + nob_row, .{ .char = '█', .style = nob_style });
    }

    app.view.scrollbar_track = .{
        .x = content_area.x + content_area.width,
        .y = content_area.y,
        .width = scrollbar_strip_width,
        .height = content_area.height,
    };
    app.view.scrollbar_max = live_max;
}

test "hidden rows match the fully walked stack across tool seams and collapsed runs" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    var registry = r.agent_registry.Registry.init(gpa, std.testing.io);
    defer registry.deinit();
    const id = registry.reserve(null).?;
    const agent = try registry.activate(id, .{
        .api_key = "key",
        .model = "model",
        .base_url = "https://example.com/v1",
        .params = .{ .openai = .{} },
    }, .{ .identity = .{ .name = "main", .cwd = "/tmp" } });

    var app: App = undefined;
    app.io = std.testing.io;
    app.gpa = gpa;
    app.mu = .init;
    app.registry = &registry;
    app.main_agent_id = id;
    app.theme = .default;
    app.flags = .{};
    app.frame_count = 0;
    app.kitty_graphics = false;
    app.cell_px = .{};
    app.inline_images = .{};
    app.streaming_entry = null;
    app.active_permission = null;
    app.tool_status_entries = .{};
    app.view = .{ .arena_timeline_render = .init(gpa) };
    defer app.view.deinit(gpa);
    app.arena_session = .init(gpa);
    defer app.arena_session.deinit();
    app.dirty = false;

    const calls = [_][2][]const u8{
        .{ "a1", "bash" }, .{ "a2", "bash" }, .{ "a3", "read" }, .{ "a4", "bash" },
        .{ "e1", "edit" }, .{ "e2", "edit" }, .{ "b1", "bash" },
    };
    var history: std.ArrayList(r.sdk.Message) = .empty;
    var parts: [calls.len]r.app.TimelinePart = undefined;
    for (calls, 0..) |c, n| {
        try history.append(alloc, .{ .role = .assistant, .content = try alloc.dupe(r.sdk.Part, &.{r.sdk.Part.toolCallPart(c[0], c[1], "{}")}) });
        try history.append(alloc, .{ .role = .tool, .content = try alloc.dupe(r.sdk.Part, &.{r.sdk.Part.toolResultPart(c[0], c[1], "ok")}) });
        parts[n] = .{ .tool_call = .{ .agent_id = id, .call_id = c[0], .tool_name = c[1] } };
    }
    try agent.setMessages(history.items);
    var user = [_]r.app.TimelinePart{.{ .plain_text = "go" }};
    var done = [_]r.app.TimelinePart{.{ .plain_text = "done" }};
    var edit_text = [_]r.app.TimelinePart{ parts[5], .{ .plain_text = "edited" } };
    const entries = [_]r.app.TimelineEntry{
        .{ .role = .user, .parts = &user },
        .{ .role = .agent, .parts = parts[0..1] },
        .{ .role = .agent, .parts = parts[1..2] },
        .{ .role = .agent, .parts = parts[2..3] },
        .{ .role = .agent, .parts = parts[3..4] },
        .{ .role = .agent, .parts = parts[4..5] },
        .{ .role = .agent, .parts = &done },
        .{ .role = .user, .parts = &user },
        .{ .role = .agent, .parts = &edit_text },
        .{ .role = .agent, .parts = parts[6..7] },
    };
    app.timeline = .empty;
    try app.timeline.appendSlice(alloc, &entries);

    const run = (try tool_runs.computeToolRuns(alloc, app.timeline.items, null, &app.view.tool_runs_expanded, app.flags)).runs[0];
    try std.testing.expectEqualStrings("a1", run.id);
    var totals: [2]usize = undefined;
    for (0..2) |expanded| {
        if (expanded == 1) tool_runs.toggleRun(&app, run);
        for (0..2) |_| { // second pass reads the entry cache
            app.view.auto_scroll = true;
            app.view.scroll_offset = 0;
            const full = try buildTimelineStack(&app, alloc, 40, 1000);
            try std.testing.expectEqual(full.total, full.full_total);
            for ([_]u16{ 1, 3, 7, 12 }) |h| {
                const part = try buildTimelineStack(&app, alloc, 40, h);
                try std.testing.expectEqual(full.full_total, part.full_total);
            }
            totals[expanded] = full.full_total;
        }
    }
    try std.testing.expect(totals[1] > totals[0]);
    try std.testing.expect(app.view.entry_cache.items.len > 0);

    // From follow mode, expanding pins the rows on screen; collapsing again
    // shrinks the offset back to 0 and resumes following.
    tool_runs.toggleRun(&app, run);
    app.view.auto_scroll = true;
    app.view.scroll_offset = 0;
    _ = try buildTimelineStack(&app, alloc, 40, 3);
    tool_runs.toggleRun(&app, run);
    try std.testing.expect(!app.view.auto_scroll);
    const opened = try buildTimelineStack(&app, alloc, 40, 3);
    try std.testing.expect(opened.pinned_shift);
    try std.testing.expectEqual(totals[1] - totals[0], app.view.scroll_offset);
    tool_runs.toggleRun(&app, run);
    const closed = try buildTimelineStack(&app, alloc, 40, 3);
    try std.testing.expect(closed.pinned_shift);
    try std.testing.expectEqual(@as(usize, 0), app.view.scroll_offset);
    try std.testing.expect(app.view.auto_scroll);
}
