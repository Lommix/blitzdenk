//! Render entry point: `State` holds every render-only cache, and `render`
//! renders the scene with its native timeline, composer and Lua error nodes,
//! then chrome and inline images, into one buffer.
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
pub const scene = @import("scene.zig");
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
    /// Flipped folds: first call ids of expanded tool runs, and keys of edit
    /// diffs toggled away from the `show_diffs` default; session allocated.
    tool_runs_expanded: std.StringHashMapUnmanaged(void) = .empty,
    /// Fold rows drawn last frame, hit-tested by mouse clicks.
    tool_run_hits: std.ArrayList(tool_runs.ToolRunHit) = .empty,
    composer_area: r.tui.Rect = .{},
    composer_progress_h: u16 = 0,

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
    if (renderFrameSnapshot(app, buf)) {
        underlineImageTokens(buf);
        if (app.image_viewer) |*viewer| r.image_view.render(viewer, app.theme, area, buf);
        if (app.view.frame_snapshot_resize_gen) |gen| app.view.frame_snapshot_resize_seen = gen.*;
        return;
    }
    renderCore(app, area, buf);
    chrome.drawLuaCanvases(app, buf);
    composer.renderCompletionPopup(app, app.arena_frame.allocator(), app.view.composer_area, app.view.composer_progress_h, buf);
    underlineImageTokens(buf);
    if (app.image_viewer) |*viewer| r.image_view.render(viewer, app.theme, area, buf);
    if (app.view.frame_snapshot_resize_gen) |gen| app.view.frame_snapshot_resize_seen = gen.*;
}

fn renderFrameSnapshot(app: *App, buf: *r.tui.Buffer) bool {
    if (!frameSnapshotUsable(app, buf)) return false;
    const snap = app.view.frame_snapshot.?;

    @memcpy(buf.cells, snap.cells);

    app.mu.lockUncancelable(app.io);
    _ = app.arena_frame.reset(.free_all);
    const frame_alloc = app.arena_frame.allocator();
    repaintFrameSnapshotTools(app, frame_alloc, buf);
    if (app.view.composer_area.width > 0 and app.view.composer_area.height > 0) {
        const progress_line = chrome.mainProgressLine(app, frame_alloc);
        composer.renderInputWidget(app, frame_alloc, app.view.composer_area, app.view.composer_progress_h, progress_line, buf);
    }
    app.mu.unlock(app.io);

    chrome.drawLuaCanvases(app, buf);
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

pub fn recordFrameSnapshotTool(app: *App, calls: []const tools.GroupCall, p: r.tui.Paragraph, rect: r.tui.Rect, inner_w: u16) void {
    const start = app.view.frame_snapshot_calls.items.len;
    app.view.frame_snapshot_calls.appendSlice(app.gpa, calls) catch {
        app.view.frame_snapshot_valid = false;
        return;
    };
    app.view.frame_snapshot_tools.append(app.gpa, .{
        .calls_start = start,
        .calls_len = calls.len,
        .inner_w = inner_w,
        .padding = p.padding,
        .scroll_offset = p.scroll_offset,
        .rect = rect,
    }) catch {
        app.view.frame_snapshot_valid = false;
    };
}

const NativeHost = struct {
    app: *App,
    alloc: std.mem.Allocator,
    progress_line: ?r.tui.Line,
    progress_h: u16,
    scrollbar_reserved: u16,
    welcome: ?r.tui.Paragraph = null,
    stack: ?timeline.TimelineStack = null,

    fn measure(ptr: *anyopaque, native: scene.Native, width: u16, max_height: u16) u16 {
        const host: *NativeHost = @ptrCast(@alignCast(ptr));
        return switch (native) {
            .lua_error => chrome.luaErrorHeight(host.app, host.alloc, width, max_height) catch 0,
            .composer => layout.inputHeight(host.app, host.alloc, .{ .width = width, .height = max_height }) +| host.progress_h,
            .timeline => host.measureTimeline(width, max_height),
        };
    }

    fn draw(ptr: *anyopaque, native: scene.Native, rect: r.tui.Rect, buf: *r.tui.Buffer) void {
        const host: *NativeHost = @ptrCast(@alignCast(ptr));
        const app = host.app;
        switch (native) {
            .lua_error => {
                buf.fill(rect, .{ .style = .{ .bg = app.theme.overlay } });
                chrome.renderLuaError(app, host.alloc, rect, buf) catch |err| {
                    log.err("lua error render failed with {any}", .{err});
                };
            },
            .composer => {
                app.view.composer_area = rect;
                app.view.composer_progress_h = host.progress_h;
                composer.renderInputWidget(app, host.alloc, rect, host.progress_h, host.progress_line, buf);
            },
            .timeline => host.drawTimeline(rect, buf),
        }
    }

    fn measureTimeline(host: *NativeHost, width: u16, max_height: u16) u16 {
        const app = host.app;
        var content_height: usize = 0;
        if (app.timeline.items.len == 0 and !app.isMainAgentCompacting()) {
            var welcome = r.tui.Paragraph{
                .padding = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
                .wrap = false,
            };
            r.dash.build_info(app, &welcome.lines) catch {};
            content_height = welcome.totalHeightLong(width);
            host.welcome = welcome;
        } else {
            const content_width = width -| host.scrollbar_reserved;
            host.stack = timeline.buildTimelineStack(app, host.alloc, content_width, max_height) catch |err| blk: {
                log.err("timeline build failed with {any}", .{err});
                break :blk null;
            };
            if (host.stack != null and host.stack.?.pinned_shift) {
                const stale = host.stack;
                host.stack = timeline.buildTimelineStack(app, host.alloc, content_width, max_height) catch stale;
            }
            if (host.stack) |stack| {
                content_height = stack.total -| stack.scroll_offset;
                app.view.scrollbar_reserved = if (stack.overflow and width > timeline.scrollbar_strip_width) timeline.scrollbar_strip_width else 0;
            }
        }
        return @intCast(@min(content_height, @as(usize, max_height)));
    }

    fn drawTimeline(host: *NativeHost, rect: r.tui.Rect, buf: *r.tui.Buffer) void {
        const app = host.app;
        buf.fill(rect, .{ .style = .{ .bg = app.theme.overlay } });
        if (host.welcome) |welcome| {
            welcome.renderSimple(host.alloc, rect, buf);
            return;
        }
        const stack = host.stack orelse return;
        const content_area: r.tui.Rect = .{
            .x = rect.x,
            .y = rect.y,
            .width = rect.width -| host.scrollbar_reserved,
            .height = rect.height,
        };
        timeline.renderTimelineStack(app, stack, content_area, buf);
        if (stack.overflow and host.scrollbar_reserved == timeline.scrollbar_strip_width) {
            timeline.renderTimelineScrollbar(app, stack, content_area, buf);
        }
    }
};

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
    app.view.scrollbar_track = .{};
    app.view.scrollbar_max = 0;
    app.view.composer_area = .{};
    app.view.composer_progress_h = 0;

    const progress_line: ?r.tui.Line = chrome.mainProgressLine(app, frame_alloc);
    var host = NativeHost{
        .app = app,
        .alloc = frame_alloc,
        .progress_line = progress_line,
        .progress_h = if (progress_line != null) 1 else 0,
        .scrollbar_reserved = app.view.scrollbar_reserved,
    };
    const frame = scene.Frame{
        .theme = &app.theme,
        .arena = frame_alloc,
        .buf = buf,
        .host = &host,
        .measureNative = NativeHost.measure,
        .drawNative = NativeHost.draw,
    };
    app.scene.render(&frame, area);

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
