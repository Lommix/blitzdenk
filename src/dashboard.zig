const std = @import("std");
const r = @import("root.zig");

const HEADER_ART =
    \\██████╗ ██╗     ██╗████████╗███████╗██████╗ ███████╗███╗   ██╗██╗  ██╗
    \\██╔══██╗██║     ██║╚══██╔══╝╚══███╔╝██╔══██╗██╔════╝████╗  ██║██║ ██╔╝
    \\██████╔╝██║     ██║   ██║     ███╔╝ ██║  ██║█████╗  ██╔██╗ ██║█████╔╝
    \\██╔══██╗██║     ██║   ██║    ███╔╝  ██║  ██║██╔══╝  ██║╚██╗██║██╔═██╗
    \\██████╔╝███████╗██║   ██║   ███████╗██████╔╝███████╗██║ ╚████║██║  ██╗
    \\╚═════╝ ╚══════╝╚═╝   ╚═╝   ╚══════╝╚═════╝ ╚══════╝╚═╝  ╚═══╝╚═╝  ╚═╝
;

pub var start_ns: i128 = 0;
var startup_ms: ?i64 = null;

fn startupMs(io: std.Io) i64 {
    if (startup_ms == null) {
        const now_ns: i128 = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        startup_ms = @intCast(@divTrunc(now_ns - start_ns, std.time.ns_per_ms));
    }
    return startup_ms.?;
}

pub fn build_header(frame: usize, base_color: r.tui.Color, alloc: std.mem.Allocator, out: *std.ArrayList(r.tui.Line)) !void {
    const base = base_color.toRgb();
    var line_iter = std.mem.splitAny(u8, HEADER_ART, "\n");
    while (line_iter.next()) |line_text| {
        var l = r.tui.Line{};
        var col: u16 = 0;
        var i: usize = 0;
        while (i < line_text.len) {
            const len = std.unicode.utf8ByteSequenceLength(line_text[i]) catch break;
            if (i + len > line_text.len) break;
            const cp = std.unicode.utf8Decode(line_text[i..][0..len]) catch break;
            i += len;
            if (cp < 0x20 or cp == 0x7F) continue;

            const wave_pos = (frame / 2) % 85;
            const dx = if (col >= wave_pos) col - wave_pos else wave_pos - col;
            const t: u16 = @intCast(@min(dx, 10));
            const blend: u8 = if (t >= 10) 0 else @intCast((10 - t) * 25);
            const fg = r.tui.Color{ .rgb = .{
                .r = lightenChannel(base.r, blend),
                .g = lightenChannel(base.g, blend),
                .b = lightenChannel(base.b, blend),
            } };

            try l.pushSpan(alloc, .{
                .content = line_text[i - len ..][0..len],
                .style = .{ .fg = fg },
            });

            col +|= 1;
        }
        try out.append(alloc, l);
    }
}

const bind_cols = 3;

const BindCell = struct { key_str: []const u8, name: []const u8 };

fn formatBindKey(alloc: std.mem.Allocator, key: r.tui.Key) ![]const u8 {
    var buf: [16]u8 = undefined;
    return alloc.dupe(u8, r.keys.formatKey(key, &buf));
}

fn strWidth(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

fn buildBindLines(
    alloc: std.mem.Allocator,
    theme: r.app.Theme,
    cells: []const BindCell,
    out: *std.ArrayList(r.tui.Line),
) !void {
    var key_w = [bind_cols]usize{ 0, 0, 0 };
    var name_w = [bind_cols]usize{ 0, 0, 0 };
    for (cells, 0..) |cell, i| {
        const col = i % bind_cols;
        key_w[col] = @max(key_w[col], strWidth(cell.key_str));
        name_w[col] = @max(name_w[col], strWidth(cell.name));
    }

    for (cells, 0..) |cell, i| {
        const col = i % bind_cols;
        if (col == 0) try out.append(alloc, r.tui.Line{});
        const l = &out.items[out.items.len - 1];
        if (col != 0) try l.pushSpan(alloc, .{ .content = " ", .style = .{ .fg = theme.muted } });
        const prefix: []const u8 = if (col == 0) "├[" else "[";
        try l.pushSpan(alloc, .{ .content = prefix, .style = .{ .fg = theme.muted } });
        try pushPadded(l, alloc, cell.key_str, key_w[col], .{ .fg = theme.info });
        try l.pushSpan(alloc, .{ .content = "] ", .style = .{ .fg = theme.muted } });
        const is_last_cell = col + 1 == bind_cols or i + 1 == cells.len;
        try pushPadded(l, alloc, cell.name, if (is_last_cell) 0 else name_w[col], .{ .fg = theme.muted });
    }
}

fn pushPadded(l: *r.tui.Line, alloc: std.mem.Allocator, text: []const u8, width: usize, style: r.tui.Style) !void {
    try l.pushSpanPrint(alloc, "{s}", .{text}, style);
    const pad = width -| strWidth(text);
    if (pad > 0) try l.pushSpanPrint(alloc, "{s: <[1]}", .{ "", pad }, style);
}

pub fn build_info(app: *r.app.App, out: *std.ArrayList(r.tui.Line)) !void {
    try build_header(app.frame_count, app.theme.info, app.arena_frame.allocator(), out);
    const alloc = app.arena_frame.allocator();

    try out.append(
        alloc,
        try r.tui.Line.new(alloc,
            \\├[github.com/lommix/blitzdenk ................... v{s}  startup {d}ms
            \\
        , .{ r.VERSION, startupMs(app.io) }, .{ .fg = app.theme.muted }),
    );

    if (app.availableUpdateVersion()) |version| {
        try out.append(
            alloc,
            try r.tui.Line.new(alloc, "├[update {s} available, run 'blitz update'", .{version}, .{ .fg = app.theme.warn }),
        );
    }

    try out.append(alloc, try r.tui.Line.new(alloc, "│", .{}, .{ .fg = app.theme.muted }));

    {
        var cells: std.ArrayList(BindCell) = .empty;
        for (app.keymap.custom.items) |bind| {
            try cells.append(alloc, .{
                .key_str = try formatBindKey(alloc, bind.key),
                .name = if (bind.description.len > 0) bind.description else r.keys.actionName(bind.action),
            });
        }
        for (r.keys.KeyMap.defaults) |bind| {
            switch (bind.action) {
                .cursor_left, .cursor_right, .cursor_up, .cursor_down => continue,
                else => {},
            }
            try cells.append(alloc, .{
                .key_str = try formatBindKey(alloc, bind.key),
                .name = if (bind.description.len > 0) bind.description else r.keys.actionName(bind.action),
            });
        }
        try buildBindLines(alloc, app.theme, cells.items, out);
    }

    try out.append(alloc, try r.tui.Line.new(alloc, "│", .{}, .{ .fg = app.theme.muted }));

    var line = r.tui.Line{};
    try line.pushSpan(alloc, .{ .content = "├[cwd: ", .style = .{ .fg = app.theme.muted } });

    if (app.exec_pool.ssh_target) |tar| {
        try line.pushSpan(alloc, .{ .content = "SSH-ON", .style = .{ .fg = app.theme.warn, .modifier = .{ .bold = true } } });
        try line.pushSpanPrint(alloc, " {s}@{s}:{s}", .{ tar.user, tar.host, tar.cwd }, .{ .fg = app.theme.info, .modifier = .{ .bold = true } });
    } else {
        try line.pushSpanPrint(alloc, "{s}", .{app.cwd}, .{ .fg = app.theme.info, .modifier = .{ .bold = true } });
    }

    try out.append(alloc, line);

    {
        const skill_count = app.context_factory.skills.entries.items.len;
        const sys_size: usize = app.context_factory.general_prompt_size;
        var sys_buf: [16]u8 = undefined;

        var l = r.tui.Line{};
        try l.pushSpan(alloc, .{ .content = "├[context:  ", .style = .{ .fg = app.theme.muted } });
        try l.pushSpanPrint(alloc, "skills: {}", .{skill_count}, .{ .fg = app.theme.info });
        try l.pushSpanPrint(alloc, "  mcp: {}", .{app.lua_vm.mcp_entries.items.len}, .{ .fg = app.theme.info });
        try l.pushSpanPrint(alloc, "  sys-prompt: {s}", .{formatSize(&sys_buf, sys_size)}, .{ .fg = app.theme.info });
        try out.append(alloc, l);
    }

    var header_shown = false;

    var last_idx: ?usize = null;
    for (0..app.context_factory.agent_counter) |agent_idx| {
        const ag_type: r.ContextFactory.AgentType = @enumFromInt(agent_idx);
        const def = app.context_factory.agents.get(ag_type) orelse continue;
        if (def.model == null) continue;
        last_idx = agent_idx;
    }

    for (0..app.context_factory.agent_counter) |agent_idx| {
        const ag_type: r.ContextFactory.AgentType = @enumFromInt(agent_idx);
        const def = app.context_factory.agents.get(ag_type) orelse continue;
        const model = def.model orelse continue;

        if (!header_shown) {
            try out.append(alloc, try r.tui.Line.new(alloc, "│", .{}, .{ .fg = app.theme.muted }));
            try out.append(alloc, try r.tui.Line.new(alloc, "│ Agents", .{}, .{ .fg = app.theme.muted }));
            header_shown = true;
        }

        var l = r.tui.Line{};
        try l.pushSpan(alloc, .{ .content = if (last_idx == agent_idx) "└[" else "├[", .style = .{ .fg = app.theme.muted } });
        try l.pushSpanPrint(alloc, "{s: <12} ", .{def.name}, .{ .fg = app.theme.muted, .modifier = .{ .bold = true } });
        const model_name = if (app.config.getModel(model.model)) |m| m.getName() else "unknown";
        try l.pushSpanPrint(alloc, "{s: <28} ", .{model_name}, .{ .fg = app.theme.info });
        try l.pushSpanPrint(alloc, "@{s} ", .{@tagName(model.effort)}, .{ .fg = app.theme.text });
        try out.append(alloc, l);
    }
}

fn lightenChannel(channel: u8, blend: u8) u8 {
    const c: u16 = channel;
    const b: u16 = blend;
    return @intCast(c + b * (255 - c) / 255);
}

fn formatSize(dest: []u8, count: usize) []const u8 {
    if (count < 1000) {
        return std.fmt.bufPrint(dest, "{d}b", .{count}) catch "0b";
    } else if (count < 1_000_000) {
        const k = @as(f64, @floatFromInt(count)) / 1000.0;
        return std.fmt.bufPrint(dest, "{d:.1}kb", .{k}) catch "0kb";
    } else if (count < 1_000_000_000) {
        const m = @as(f64, @floatFromInt(count)) / 1_000_000.0;
        return std.fmt.bufPrint(dest, "{d:.1}mb", .{m}) catch "0mb";
    } else {
        const g = @as(f64, @floatFromInt(count)) / 1_000_000_000.0;
        return std.fmt.bufPrint(dest, "{d:.1}gb", .{g}) catch "0gb";
    }
}

test "formatSize" {
    const Case = struct { count: usize, expect: []const u8 };
    const cases = [_]Case{
        .{ .count = 0, .expect = "0b" },
        .{ .count = 512, .expect = "512b" },
        .{ .count = 999, .expect = "999b" },
        .{ .count = 1000, .expect = "1.0kb" },
        .{ .count = 6300, .expect = "6.3kb" },
        .{ .count = 120_000, .expect = "120.0kb" },
        .{ .count = 1_500_000, .expect = "1.5mb" },
    };
    var buf: [32]u8 = undefined;
    for (cases) |c| {
        try std.testing.expectEqualStrings(c.expect, formatSize(&buf, c.count));
    }
}

fn lineText(buf: []u8, line: *const r.tui.Line) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    for (line.spans.items) |span| try w.writeAll(span.content);
    return w.buffered();
}

test "bind table renders three aligned cells per row" {
    const a = std.testing.allocator;
    var out: std.ArrayList(r.tui.Line) = .empty;
    defer out.deinit(a);
    defer for (out.items) |*l| l.deinit(a);
    const cells = [_]BindCell{
        .{ .key_str = "↑", .name = "up" },
        .{ .key_str = "c+c", .name = "quit" },
        .{ .key_str = "esc", .name = "cancel" },
        .{ .key_str = "tab", .name = "cmp next" },
    };
    try buildBindLines(a, .default, &cells, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "├[↑  ] up       [c+c] quit [esc] cancel",
        try lineText(&buf, &out.items[0]),
    );
    try std.testing.expectEqualStrings("├[tab] cmp next", try lineText(&buf, &out.items[1]));
}

test "bind table single row pads all but the last name" {
    const a = std.testing.allocator;
    var out: std.ArrayList(r.tui.Line) = .empty;
    defer out.deinit(a);
    defer for (out.items) |*l| l.deinit(a);
    const cells = [_]BindCell{
        .{ .key_str = "c+u", .name = "scroll up" },
        .{ .key_str = "c+d", .name = "scroll down" },
    };
    try buildBindLines(a, .default, &cells, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("├[c+u] scroll up [c+d] scroll down", try lineText(&buf, &out.items[0]));
}
