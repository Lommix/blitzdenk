const std = @import("std");
const r = @import("../root.zig");
const App = r.app.App;
const log = std.log.scoped(.view);

pub const blocks = @import("blocks.zig");
pub const chrome = @import("chrome.zig");
pub const completion = @import("completion.zig");
pub const composer = @import("composer.zig");
pub const layout = @import("layout.zig");
pub const permission = @import("permission.zig");
pub const timeline = @import("timeline.zig");
pub const tool_runs = @import("tool_runs.zig");
pub const tools = @import("tools.zig");
pub const wizard = @import("wizard.zig");

/// Render-only state owned by the view layer.
pub const State = struct {
    arena_timeline_render: std.heap.ArenaAllocator,
    scroll_offset: usize = 0,
    scroll_total: usize = 0,
    scroll_total_width: u16 = 0,
    auto_scroll: bool = true,
    scrollbar_dragging: bool = false,
    scrollbar_grab: u16 = 0,
    scrollbar_drag_max: usize = 0,
    scrollbar_track: r.tui.Rect = .{},
    scrollbar_max: usize = 0,
    scrollbar_reserved: u16 = 0,
    /// Per timeline entry; see `timeline.EntrySlot`.
    entry_cache: std.ArrayList(?timeline.EntrySlot) = .empty,
    entry_layout: ?timeline.LayoutKey = null,
    entry_content: ?timeline.ContentKey = null,
    frame_snapshot: ?*const r.tui.Buffer = null,
    frame_snapshot_valid: bool = false,
    frame_snapshot_blocked: bool = false,
    frame_snapshot_resize_gen: ?*const u64 = null,
    frame_snapshot_resize_seen: u64 = 0,
    frame_snapshot_tools: std.ArrayList(FrameSnapshotTool) = .empty,
    frame_snapshot_calls: std.ArrayList(tools.GroupCall) = .empty,
    /// First call ids of expanded bash/read runs; session allocated.
    tool_runs_expanded: std.StringHashMapUnmanaged(void) = .empty,
    /// Summary rows drawn last frame, hit-tested by mouse clicks.
    tool_run_hits: std.ArrayList(tool_runs.ToolRunHit) = .empty,
    widget_layout_cache: layout.WidgetLayout = .{},
    widget_layout_valid: bool = false,
    widget_frame_panels: [r.lua.MAX_LUA_WIDGETS]layout.WidgetPanelSlot = @splat(.{}),
    widget_frame_panels_len: usize = 0,
    widget_frame_input_area: r.tui.Rect = .{},
    widget_frame_progress_h: u16 = 0,

    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        self.arena_timeline_render.deinit();
        self.entry_cache.deinit(gpa);
        self.frame_snapshot_tools.deinit(gpa);
        self.frame_snapshot_calls.deinit(gpa);
        self.clearRunHits(gpa);
        self.tool_run_hits.deinit(gpa);
    }

    pub fn clearRunHits(self: *State, gpa: std.mem.Allocator) void {
        for (self.tool_run_hits.items) |hit| gpa.free(hit.run.id);
        self.tool_run_hits.clearRetainingCapacity();
    }

    /// Drop cached layouts from timeline entry `idx` on. Their blocks stay
    /// in the render arena until the next full invalidation.
    pub fn invalidateFrom(self: *State, idx: usize) void {
        if (self.entry_cache.items.len > idx) self.entry_cache.shrinkRetainingCapacity(idx);
    }

    pub fn invalidateRenderCache(self: *State) void {
        self.entry_cache.clearRetainingCapacity();
        self.entry_layout = null;
        self.entry_content = null;
        _ = self.arena_timeline_render.reset(.free_all);
    }
};

pub fn render(app: *App, area: r.tui.Rect, buf: *r.tui.Buffer) void {
    chrome.refreshLuaStatusBar(app);
    if (renderFrameSnapshot(app, area, buf)) {
        underlineImageTokens(buf);
        if (app.image_viewer) |*viewer| r.image_view.render(viewer, app.theme, area, buf);
        if (app.view.frame_snapshot_resize_gen) |gen| app.view.frame_snapshot_resize_seen = gen.*;
        return;
    }
    chrome.refreshLuaWidgets(app, area, buf);
    renderCore(app, area, buf);
    chrome.drawLuaPanels(app, buf);
    composer.renderCompletionPopup(app, app.arena_frame.allocator(), app.view.widget_frame_input_area, app.view.widget_frame_progress_h, buf);
    underlineImageTokens(buf);
    if (app.image_viewer) |*viewer| r.image_view.render(viewer, app.theme, area, buf);
    if (app.view.frame_snapshot_resize_gen) |gen| app.view.frame_snapshot_resize_seen = gen.*;
}

fn renderFrameSnapshot(app: *App, area: r.tui.Rect, buf: *r.tui.Buffer) bool {
    if (!frameSnapshotUsable(app, buf)) return false;
    const snap = app.view.frame_snapshot.?;

    @memcpy(buf.cells, snap.cells);
    chrome.refreshLuaWidgets(app, area, buf);

    app.mu.lockUncancelable(app.io);
    _ = app.arena_frame.reset(.free_all);
    const frame_alloc = app.arena_frame.allocator();
    repaintFrameSnapshotTools(app, frame_alloc, buf);
    if (app.view.widget_frame_input_area.width > 0 and app.view.widget_frame_input_area.height > 0) {
        const progress_line = chrome.mainProgressLine(app, frame_alloc);
        composer.renderInputWidget(app, frame_alloc, app.view.widget_frame_input_area, app.view.widget_frame_progress_h, progress_line, buf);
    }
    app.mu.unlock(app.io);

    chrome.drawLuaPanels(app, buf);
    return true;
}

fn frameSnapshotUsable(app: *App, buf: *const r.tui.Buffer) bool {
    if (app.timeline.items.len == 0) return false;
    if (app.dirty or !app.view.frame_snapshot_valid or app.view.frame_snapshot_blocked) return false;
    const snap = app.view.frame_snapshot orelse return false;
    if (snap.rect.width != buf.rect.width or snap.rect.height != buf.rect.height) return false;
    if (app.view.frame_snapshot_resize_gen) |gen| {
        if (gen.* != app.view.frame_snapshot_resize_seen) return false;
    }
    if (app.notifications.hasVisible()) return false;
    if (app.inline_placements.items.len > 0 and app.view.frame_snapshot_tools.items.len > 0) return false;
    const now_ns: i128 = @intCast(std.Io.Clock.Timestamp.now(app.io, .awake).raw.nanoseconds);
    return !app.lua_vm.errorAlive(now_ns);
}

fn repaintFrameSnapshotTools(app: *App, alloc: std.mem.Allocator, buf: *r.tui.Buffer) void {
    const calls = app.view.frame_snapshot_calls.items;
    for (app.view.frame_snapshot_tools.items) |tool| {
        const item = tools.buildToolGroupParagraph(app, alloc, calls[tool.calls_start..][0..tool.calls_len], tool.inner_w) catch {
            app.view.frame_snapshot_valid = false;
            continue;
        };
        var p = item.p;
        p.padding = tool.padding;
        p.scroll_offset = tool.scroll_offset;
        p.render(alloc, tool.rect, tool.rect, buf);
    }
}

pub fn recordFrameSnapshotTool(app: *App, item: blocks.RenderParagraphItem, rect: r.tui.Rect, inner_w: u16) void {
    const calls = item.live_calls orelse return;
    const start = app.view.frame_snapshot_calls.items.len;
    app.view.frame_snapshot_calls.appendSlice(app.gpa, calls) catch {
        app.view.frame_snapshot_valid = false;
        return;
    };
    app.view.frame_snapshot_tools.append(app.gpa, .{
        .calls_start = start,
        .calls_len = calls.len,
        .inner_w = inner_w,
        .padding = item.p.padding,
        .scroll_offset = item.p.scroll_offset,
        .rect = rect,
    }) catch {
        app.view.frame_snapshot_valid = false;
    };
}

fn renderCore(app: *App, area: r.tui.Rect, buf: *r.tui.Buffer) void {
    app.mu.lockUncancelable(app.io);
    defer app.mu.unlock(app.io);
    if (app.inline_images_ready.swap(false, .acq_rel)) {
        app.view.invalidateRenderCache();
    }
    _ = app.arena_frame.reset(.free_all);
    const frame_alloc = app.arena_frame.allocator();
    app.view.frame_snapshot_tools.clearRetainingCapacity();
    app.view.frame_snapshot_calls.clearRetainingCapacity();
    app.inline_placements.clearRetainingCapacity();
    app.view.clearRunHits(app.gpa);
    for (app.inline_images.entries.items) |entry| entry.frame_pinned = false;
    app.inline_images.prune(app.gpa);
    app.view.frame_snapshot_valid = true;

    var widget_layout_fallback = layout.WidgetLayout{ .area = area, .main = area };
    const cache_matches_area = app.view.widget_layout_valid and
        app.view.widget_layout_cache.area.width == area.width and
        app.view.widget_layout_cache.area.height == area.height;
    const wl: *const layout.WidgetLayout = if (cache_matches_area) &app.view.widget_layout_cache else &widget_layout_fallback;
    const main_area = wl.main;

    const input_height = layout.inputHeight(app, frame_alloc, main_area);

    // Timeline fills the screen; input + status stick right after the
    // timeline
    // content (or to the viewport bottom once it overflows). Each status
    // line lives inside the input footer: the main-agent status on the top
    // row, the statusbar on the row above the bottom padding.
    const _combined_area, _ =
        r.tui.Col(main_area, .{
            r.tui.Constr.fill, // timeline + status
            r.tui.Constr{ .fixed = input_height }, // input + status footer
        });

    const lua_error_height = chrome.luaErrorHeight(app, frame_alloc, _combined_area.width, _combined_area.height) catch 0;
    const _lua_error_area, const _timeline_status_area =
        r.tui.Col(_combined_area, .{
            r.tui.Constr{ .fixed = lua_error_height },
            r.tui.Constr.fill,
        });

    const progress_line: ?r.tui.Line = chrome.mainProgressLine(app, frame_alloc);
    const progress_h: u16 = if (progress_line != null) 1 else 0;
    const footer_h: u16 = input_height +| progress_h;
    const panels_visible =
        (_timeline_status_area.height -| progress_h -| wl.panels_total_height) >= layout.WIDGET_MIN_TIMELINE_ROWS and
        (wl.panels_total_height +| footer_h) <= main_area.height;
    const between_h: u16 = if (panels_visible) wl.between_total_height else 0;
    const below_h: u16 = if (panels_visible) wl.below_total_height else 0;

    // Build the content first so the viewport only renders as much as needed.
    const is_welcome = app.timeline.items.len == 0 and !app.isMainAgentCompacting();
    var welcome_p: ?r.tui.Paragraph = null;
    var timeline_stack: ?timeline.TimelineStack = null;
    var content_end_h: usize = 0;
    const scrollbar_reserved: u16 = app.view.scrollbar_reserved;

    const timeline_h: u16 = blk: {
        const viewport_h = _timeline_status_area.height -| progress_h -| between_h;
        const pinned_h = (main_area.y +| main_area.height) -| footer_h -| below_h -| between_h -| _timeline_status_area.y;
        break :blk @min(viewport_h, pinned_h);
    };

    if (is_welcome) {
        var wp = r.tui.Paragraph{
            .padding = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
            .wrap = false,
        };
        r.dash.build_info(app, &wp.lines) catch {};
        content_end_h = wp.totalHeightLong(_timeline_status_area.width);
        welcome_p = wp;
    } else {
        timeline_stack = timeline.buildTimelineStack(app, frame_alloc, _timeline_status_area.width -| scrollbar_reserved, timeline_h) catch |err| blk: {
            log.err("timeline build failed with {any}", .{err});
            break :blk null;
        };
        if (timeline_stack != null and timeline_stack.?.pinned_shift) {
            const stale = timeline_stack;
            timeline_stack = timeline.buildTimelineStack(app, frame_alloc, _timeline_status_area.width -| scrollbar_reserved, timeline_h) catch stale;
        }
        if (timeline_stack) |cs| content_end_h = cs.total -| cs.scroll_offset;
    }
    app.view.scrollbar_track = .{};
    app.view.scrollbar_max = 0;

    // Input sits right after the timeline content; once content fills the
    // viewport it pins to the bottom and stays sticky. The footer includes
    // the main-agent status row on top of the input widget. Between panels
    // push the floating footer past the timeline content, below panels reserve
    // rows under the pinned footer.
    const max_footer_y: u16 = (main_area.y +| main_area.height) -| footer_h -| below_h;
    const content_cap: u16 = @intCast(@min(content_end_h, @as(usize, timeline_h)));
    const footer_y: u16 = @min(
        _timeline_status_area.y +| content_cap +| between_h,
        max_footer_y,
    );
    const _input_area: r.tui.Rect = .{
        .x = main_area.x,
        .y = footer_y,
        .width = main_area.width,
        .height = footer_h,
    };

    app.view.widget_frame_input_area = _input_area;
    app.view.widget_frame_progress_h = progress_h;
    app.view.widget_frame_panels_len = 0;
    if (panels_visible) {
        layout.anchorWidgetPanels(wl, footer_y, footer_h, &app.view.widget_frame_panels);
        app.view.widget_frame_panels_len = wl.panels_len;
    }

    // Paint the background only over the used region; the rest stays
    // terminal default so unused viewport space is not rendered.
    const used_bottom: u16 = @min(footer_y +| footer_h +| below_h, main_area.y +| main_area.height);
    buf.fill(.{
        .x = main_area.x,
        .y = main_area.y,
        .width = main_area.width,
        .height = used_bottom -| main_area.y,
    }, .{ .style = .{ .bg = app.theme.overlay } });

    chrome.renderLuaError(app, frame_alloc, _lua_error_area, buf) catch |err| {
        log.err("lua error render failed with {any}", .{err});
    };

    const _timeline_area: r.tui.Rect = .{
        .x = _timeline_status_area.x,
        .y = _timeline_status_area.y,
        .width = _timeline_status_area.width,
        .height = timeline_h,
    };

    if (welcome_p) |wp| {
        const welcome_area: r.tui.Rect = .{
            .x = _timeline_area.x,
            .y = _timeline_area.y,
            .width = _timeline_area.width,
            .height = content_cap,
        };
        wp.renderSimple(frame_alloc, welcome_area, buf);
    } else if (timeline_stack) |cs| {
        const content_area: r.tui.Rect = .{
            .x = _timeline_area.x,
            .y = _timeline_area.y,
            .width = _timeline_area.width -| scrollbar_reserved,
            .height = _timeline_area.height,
        };
        timeline.renderTimelineStack(app, cs, content_area, buf);
        app.view.scrollbar_reserved = if (cs.overflow and _timeline_status_area.width > timeline.scrollbar_strip_width) timeline.scrollbar_strip_width else 0;
        if (cs.overflow and scrollbar_reserved == timeline.scrollbar_strip_width) {
            timeline.renderTimelineScrollbar(app, cs, content_area, buf);
        }
    }
    for (app.inline_images.entries.items) |entry| {
        if (!entry.frame_pinned) continue;
        var placed = false;
        for (app.inline_placements.items) |placement| {
            if (placement.entry == entry) {
                placed = true;
                break;
            }
        }
        if (!placed) entry.frame_pinned = false;
    }

    // Input/Permission: a single overlay_dark block hosting the main-agent
    // progress, the input content, and the statusbar.
    composer.renderInputWidget(app, frame_alloc, _input_area, progress_h, progress_line, buf);

    chrome.renderWidgetErrors(app, wl, buf);

    // Notifications
    chrome.renderNotifications(app, frame_alloc, area, buf);
}

fn underlineImageTokens(buf: *r.tui.Buffer) void {
    const w = buf.rect.width;
    const h = buf.rect.height;
    if (w == 0 or h == 0) return;
    var token: [512]u8 = undefined;
    var y: u16 = 0;
    while (y < h) : (y += 1) {
        var x: u16 = 0;
        while (x < w) {
            const start_cell = buf.get(buf.rect.x + x, buf.rect.y + y);
            if (start_cell.char == ' ') {
                x += 1;
                continue;
            }
            const token_start = x;
            var len: usize = 0;
            while (x < w) : (x += 1) {
                const cell = buf.get(buf.rect.x + x, buf.rect.y + y);
                if (cell.char == ' ') break;
                if (len + 4 > token.len) {
                    while (x < w and buf.get(buf.rect.x + x, buf.rect.y + y).char != ' ') x += 1;
                    break;
                }
                const n = std.unicode.utf8Encode(cell.char, token[len..]) catch {
                    continue;
                };
                len += n;
            }
            if (len > 4 and r.image_view.hasImageExtension(token[0..len])) {
                var ux = token_start;
                while (ux < x) : (ux += 1) {
                    var cell = buf.get(buf.rect.x + ux, buf.rect.y + y);
                    cell.style.modifier.underline = true;
                    buf.set(buf.rect.x + ux, buf.rect.y + y, cell);
                }
            }
        }
    }
}

pub const FrameSnapshotTool = struct {
    calls_start: usize,
    calls_len: usize,
    inner_w: u16,
    padding: r.tui.Padding,
    scroll_offset: usize,
    rect: r.tui.Rect,
};

test "long image token scan advances" {
    var buf = try r.tui.Buffer.init(std.testing.allocator, .{ .width = 600, .height = 1 });
    defer buf.deinit();
    var text: [600]u8 = undefined;
    @memset(&text, 'a');
    @memcpy(text[596..], ".png");
    buf.setString(0, 0, &text, .{});
    underlineImageTokens(&buf);
    try std.testing.expect(!buf.get(0, 0).style.modifier.underline);
}
