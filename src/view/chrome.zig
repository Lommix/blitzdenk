const std = @import("std");
const r = @import("../root.zig");
const ct = @import("ctime");
const App = r.app.App;
const text_utils = r.tui.text_utils;
const layout = @import("layout.zig");

fn notificationTime(sent_ms: i64, out: *[8]u8) []const u8 {
    const seconds: std.c.time_t = @intCast(@divTrunc(sent_ms, std.time.ms_per_s));
    var tm: ct.struct_tm = undefined;
    if (ct.localtime_r(&seconds, &tm) == null) return out[0..0];
    const hour: u32 = @intCast(tm.tm_hour);
    const minute: u32 = @intCast(tm.tm_min);
    const second: u32 = @intCast(tm.tm_sec);
    return std.fmt.bufPrint(out, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hour, minute, second }) catch out[0..0];
}

pub fn renderNotifications(app: *App, arena: std.mem.Allocator, full_area: r.tui.Rect, buf: *r.tui.Buffer) void {
    const notif_w: u16 = @min(full_area.width / 3, 40);
    if (notif_w < 4) return;

    var skip = app.notifications.visibleCount() -| r.app.Notifications.MAX_VISIBLE;
    var y = full_area.y;
    const max_y = full_area.y +| full_area.height;
    var rendered: usize = 0;
    var iter = app.notifications.iter();
    while (iter.next()) |entry| {
        if (rendered >= r.app.Notifications.MAX_VISIBLE or y >= max_y) break;
        if (skip > 0) {
            skip -= 1;
            continue;
        }

        switch (entry.*) {
            .used => |en| {
                var para = r.tui.Paragraph{
                    .border = .single,
                    .style = .{ .fg = app.theme.border, .bg = app.theme.overlay_dark },
                    .padding = .{ .left = 1, .right = 1, .top = 0, .bottom = 0 },
                };
                var l = r.tui.Line{};
                l.pushText(arena, en.msg, .{ .fg = app.theme.text }) catch {};
                para.lines.append(arena, l) catch {};

                const total_h = para.totalHeight(notif_w);
                if (total_h == 0) continue;

                const slide_t = 1.0 - @min(en.alive / r.app.Notifications.SLIDE_SECONDS, 1.0);
                const slide: u16 = @intFromFloat(slide_t * slide_t * @as(f32, @floatFromInt(notif_w)));

                const area = r.tui.Rect{
                    .x = full_area.x +| full_area.width -| notif_w +| slide,
                    .y = y,
                    .width = notif_w,
                    .height = @min(total_h, max_y -| y),
                };
                para.renderSimple(arena, area, buf);

                if (area.width >= 10) {
                    var time_buf: [8]u8 = undefined;
                    const stamp = notificationTime(en.sent_ms, &time_buf);
                    buf.setStringMax(area.x +| 1, area.y, stamp, .{ .fg = app.theme.info, .bg = app.theme.overlay_dark }, area.width -| 2);
                }

                y +|= total_h +| 1;
                rendered += 1;
            },
            else => {},
        }
    }
}

pub fn renderStatusBar(app: *App, area: r.tui.Rect, buf: *r.tui.Buffer) void {
    if (app.input_mode == .wizard) return;
    const alloc = app.arena_frame.allocator();
    var line = statusBarLine(app, alloc) catch return;
    line.render(area.x, area.y, area.width, buf);
}

fn statusBarLine(app: *App, alloc: std.mem.Allocator) !r.tui.Line {
    if (app.lua_status_bar_enabled and app.lua_status_bar_cache_len > 0) {
        const parsed = try r.tui.Text.fromAnsi(alloc, app.lua_status_bar_cache[0..app.lua_status_bar_cache_len]);
        if (parsed.lines.items.len > 0) {
            var line = parsed.lines.items[0];
            line.style = .{ .fg = app.theme.muted };
            return line;
        }
        return .{};
    }

    const ctx_pct: u8 = @intFromFloat(@min(app.contextPercent(), 100));
    var status_buf: [256]u8 = undefined;
    var in_buf: [16]u8 = undefined;
    var out_buf: [16]u8 = undefined;
    var cache_buf: [16]u8 = undefined;
    const usage = app.registry.usage();
    const status = std.fmt.bufPrint(
        &status_buf,
        "IN:{s} OUT:{s} CACHE:{s} | CTX:{d}% {s}",
        .{
            formatTokenCount(&in_buf, usage.input_tokens),
            formatTokenCount(&out_buf, usage.output_tokens),
            formatTokenCount(&cache_buf, usage.cache_read_tokens + usage.cache_write_tokens),
            ctx_pct,
            switch (app.flags.approval_mode) {
                .strict => "| APPROVAL",
                .default => "",
            },
        },
    ) catch " ?? ";
    return r.tui.Line.new(alloc, "{s}", .{status}, .{ .fg = app.theme.muted });
}

pub fn refreshLuaStatusBar(app: *App) void {
    if (!app.lua_status_bar_enabled) return;
    if (app.input_mode == .wizard) return;
    if (app.lua_vm.vm_mu.tryLock()) {
        defer app.lua_vm.vm_mu.unlock(app.io);
        if (app.lua_vm.renderStatusBar(&app.lua_status_bar_cache)) |status| {
            app.lua_status_bar_cache_len = status.len;
        }
    }
}

fn drawLuaWidget(app: *App, vm: *r.lua.LuaVm, entry_index: usize, rect: r.tui.Rect, buf: *r.tui.Buffer) void {
    const entry = &vm.widget_entries[entry_index];
    if (!entry.alive or entry.hidden) return;
    const err_len = r.lua.invokeWidgetRender(vm, entry, rect, buf, &app.theme, app.frame_count, &app.widget_error_msgs[entry_index]);
    app.widget_error_lens[entry_index] = err_len;
}

pub fn refreshLuaWidgets(app: *App, area: r.tui.Rect, buf: *r.tui.Buffer) void {
    const vm = app.lua_vm;
    if (vm.widget_count == 0) {
        app.view.widget_layout_valid = false;
        return;
    }
    for (&app.widget_error_lens) |*l| l.* = 0;
    if (!vm.vm_mu.tryLock()) return;
    defer vm.vm_mu.unlock(app.io);

    const wl = layout.computeWidgetLayout(vm, area);
    app.view.widget_layout_cache = wl;
    app.view.widget_layout_valid = true;
    const bg_cell = r.tui.Cell{ .style = .{ .bg = app.theme.overlay } };

    if (wl.left) |rect| {
        buf.fill(rect, bg_cell);
        drawLuaWidget(app, vm, wl.left_index, rect, buf);
    }
    if (wl.right) |rect| {
        buf.fill(rect, bg_cell);
        drawLuaWidget(app, vm, wl.right_index, rect, buf);
    }
}

pub fn drawLuaPanels(app: *App, buf: *r.tui.Buffer) void {
    if (app.view.widget_frame_panels_len == 0) return;
    const vm = app.lua_vm;
    if (!vm.vm_mu.tryLock()) return;
    defer vm.vm_mu.unlock(app.io);
    for (app.view.widget_frame_panels[0..app.view.widget_frame_panels_len]) |slot| {
        drawLuaWidget(app, vm, slot.entry_index, slot.rect, buf);
        drawWidgetError(app, slot.entry_index, slot.rect, buf);
    }
}

fn drawWidgetError(app: *App, entry_index: usize, rect: r.tui.Rect, buf: *r.tui.Buffer) void {
    const err_len = app.widget_error_lens[entry_index];
    if (err_len == 0) return;
    const msg = app.widget_error_msgs[entry_index][0..err_len];
    var line_it = std.mem.splitScalar(u8, msg, '\n');
    var row: u16 = 0;
    while (line_it.next()) |line_text| {
        if (row >= rect.height) break;
        buf.setStringMax(rect.x, rect.y +| row, line_text, .{ .fg = app.theme.err }, rect.width);
        row += 1;
    }
}

pub fn renderWidgetErrors(app: *App, wl: *const layout.WidgetLayout, buf: *r.tui.Buffer) void {
    if (wl.left) |rect| drawWidgetError(app, wl.left_index, rect, buf);
    if (wl.right) |rect| drawWidgetError(app, wl.right_index, rect, buf);
}

fn blendTo(from: r.tui.Color, to: r.tui.Color, t: f64) r.tui.Color {
    if (t >= 1) return to;
    const a = from.toRgb();
    const b = to.toRgb();
    const ch = struct {
        fn mix(x: u8, y: u8, k: f64) u8 {
            const xf: f64 = @floatFromInt(x);
            const yf: f64 = @floatFromInt(y);
            return @intFromFloat(@round(xf + (yf - xf) * k));
        }
    }.mix;
    return .{ .rgb = .{ .r = ch(a.r, b.r, t), .g = ch(a.g, b.g, t), .b = ch(a.b, b.b, t) } };
}

fn luaErrorStyle(app: *App, now_ns: i128) r.tui.Style {
    const remain = app.lua_vm.last_error_until_ns -| now_ns;
    if (remain >= r.lua.LUA_ERROR_FADE_NS) return .{ .fg = app.theme.on_err, .bg = app.theme.err };
    const span: f64 = @floatFromInt(r.lua.LUA_ERROR_FADE_NS);
    const left: f64 = @floatFromInt(@max(remain, 0));
    const t = 1 - left / span;
    return .{
        .fg = blendTo(app.theme.on_err, app.theme.bg, t),
        .bg = blendTo(app.theme.err, app.theme.bg, t),
    };
}

fn luaErrorParagraph(arena: std.mem.Allocator, msg: []const u8, style: r.tui.Style) !r.tui.Paragraph {
    var p: r.tui.Paragraph = .{ .style = style };
    try p.appendText(arena, msg, style);
    return p;
}

pub fn luaErrorHeight(app: *App, arena: std.mem.Allocator, width: u16, max_height: u16) !u16 {
    const now_ns = std.Io.Clock.Timestamp.now(app.io, .awake).raw.nanoseconds;
    if (!app.lua_vm.errorAlive(now_ns)) return 0;
    const msg = app.lua_vm.getLastError();
    if (msg.len == 0 or width == 0 or max_height == 0) return 0;

    var p = try luaErrorParagraph(arena, msg, luaErrorStyle(app, now_ns));
    return @min(p.totalHeight(width), max_height);
}

pub fn renderLuaError(app: *App, arena: std.mem.Allocator, area: r.tui.Rect, buf: *r.tui.Buffer) !void {
    if (area.width == 0 or area.height == 0) return;
    const now_ns = std.Io.Clock.Timestamp.now(app.io, .awake).raw.nanoseconds;
    if (!app.lua_vm.errorAlive(now_ns)) return;
    const msg = app.lua_vm.getLastError();
    if (msg.len == 0) return;

    var p = try luaErrorParagraph(arena, msg, luaErrorStyle(app, now_ns));
    p.renderSimple(arena, area, buf);
}

pub fn mainProgressLine(app: *App, alloc: std.mem.Allocator) ?r.tui.Line {
    const aid = app.main_agent_id orelse return null;
    const slot = &app.registry.slots[aid.index];
    const state = slot.state.load(.acquire);
    if (state != .active and state != .complete and state != .failed) return null;

    const agent = if (slot.agent) |*value| value else return null;
    const active_agent_count = app.registry.countActive();
    const job_count = app.jobs_running;
    const waiting = !agent.isBusy() and (active_agent_count > 0 or job_count > 0);
    const secs = app.sessionRunSecs();

    const hl: r.tui.Style = .{ .fg = app.theme.text, .modifier = .{ .bold = true } };
    const info: r.tui.Style = .{ .fg = app.theme.info };

    var dur_buf: [32]u8 = undefined;
    const dur = formatDuration(&dur_buf, secs);

    var l = r.tui.Line{};
    if (state == .active and !waiting) {
        const spinner_str = text_utils.spinnerDots(app.frame_count);
        if (agent.status == .compacting) {
            l.pushSpanPrint(alloc, "{s} compacting", .{spinner_str}, info) catch {};
            return l;
        }

        l.pushSpanPrint(alloc, "{s} (", .{spinner_str}, info) catch {};
        l.pushSpanPrint(alloc, "{s}", .{dur}, hl) catch {};
        l.pushSpanPrint(alloc, ")", .{}, info) catch {};

        const state_str: []const u8 = switch (agent.activity) {
            .idle => "",
            .processing => "processing",
            .thinking => "thinking",
            .writing => "writing",
            .calling => "calling",
            .retrying => "retrying",
        };

        if (active_agent_count > 1 or job_count > 0) {
            l.pushSpanPrint(alloc, " (", .{}, info) catch {};
            pushRunCounts(&l, alloc, active_agent_count -| 1, " background agents", job_count, hl, info);
            l.pushSpanPrint(alloc, ")", .{}, info) catch {};
        }

        if (agent.tokens_per_second > 0) {
            l.pushSpanPrint(alloc, " ", .{}, info) catch {};
            pushGradientWave(&l, alloc, "consuming tokens", app.theme.text_hl, app.theme.info, app.frame_count);
            l.pushSpanPrint(alloc, " at ", .{}, info) catch {};
            l.pushSpanPrint(alloc, "{d} t/s", .{@as(u32, @intFromFloat(agent.tokens_per_second))}, hl) catch {};
            if (state_str.len > 0) {
                l.pushSpanPrint(alloc, " while ", .{}, info) catch {};
            }
        } else if (state_str.len > 0) {
            l.pushSpanPrint(alloc, " ", .{}, info) catch {};
        }

        if (agent.activity == .processing) {
            pushGradientWave(&l, alloc, state_str, app.theme.text_hl, app.theme.info, app.frame_count);
        } else if (state_str.len > 0) {
            l.pushSpanPrint(alloc, "{s}", .{state_str}, hl) catch {};
        }
    } else if (waiting and (state == .active or state == .complete)) {
        pushGradientWave(&l, alloc, "waiting", app.theme.text_hl, app.theme.info, app.frame_count);
        l.pushSpanPrint(alloc, " for ", .{}, info) catch {};
        pushRunCounts(&l, alloc, active_agent_count -| @as(u32, if (state == .active) 1 else 0), " agents", job_count, hl, info);
        l.pushSpanPrint(alloc, " (", .{}, info) catch {};
        l.pushSpanPrint(alloc, "{s}", .{dur}, hl) catch {};
        l.pushSpanPrint(alloc, ")", .{}, info) catch {};
    } else {
        const label = if (state == .complete) "Done" else "Failed";
        l.pushSpanPrint(alloc, "{s} ({s})", .{ label, dur }, info) catch {};
    }
    return l;
}

/// "N <agent_label>, M jobs", leaving out a zero count.
fn pushRunCounts(line: *r.tui.Line, alloc: std.mem.Allocator, agents: u32, agent_label: []const u8, jobs: u32, hl: r.tui.Style, info: r.tui.Style) void {
    if (agents > 0) {
        line.pushSpanPrint(alloc, "{d}", .{agents}, hl) catch {};
        line.pushSpanPrint(alloc, "{s}", .{agent_label}, info) catch {};
    }
    if (jobs == 0) return;
    if (agents > 0) line.pushSpanPrint(alloc, ", ", .{}, info) catch {};
    line.pushSpanPrint(alloc, "{d}", .{jobs}, hl) catch {};
    line.pushSpanPrint(alloc, "{s}", .{if (jobs == 1) " job" else " jobs"}, info) catch {};
}

fn pushGradientWave(line: *r.tui.Line, alloc: std.mem.Allocator, text: []const u8, from_color: r.tui.Color, to_color: r.tui.Color, frame_count: usize) void {
    var wave = text_utils.gradientWave(text, from_color, to_color, frame_count);
    while (wave.next()) |chunk| {
        line.pushSpan(alloc, .{ .content = chunk.text, .style = .{ .fg = chunk.color, .modifier = .{ .bold = true } } }) catch {};
    }
}

fn formatDuration(buf: []u8, secs: u32) []const u8 {
    if (secs >= 60)
        return std.fmt.bufPrint(buf, "{d}m {d}s", .{ secs / 60, secs % 60 }) catch "…";
    return std.fmt.bufPrint(buf, "{d}s", .{secs}) catch "…";
}

fn formatTokenCount(dest: []u8, count: u64) []const u8 {
    if (count < 1000) {
        return std.fmt.bufPrint(dest, "{d}", .{count}) catch "0";
    } else if (count < 1_000_000) {
        const k = @as(f64, @floatFromInt(count)) / 1000.0;
        return std.fmt.bufPrint(dest, "{d:.1}k", .{k}) catch "0k";
    } else {
        const m = @as(f64, @floatFromInt(count)) / 1_000_000.0;
        return std.fmt.bufPrint(dest, "{d:.1}M", .{m}) catch "0M";
    }
}
