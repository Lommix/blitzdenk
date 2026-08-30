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

// TODO: load keybindings
const keybinds = .{
    .{ "esc", "cancel" },
    .{ "c+c", "quit" },
    .{ "c+u", "scroll up" },
    .{ "c+d", "scroll down" },
};

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
        const bind_count = keybinds.len;
        inline for (0..bind_count / 2) |row| {
            const left = row * 2;
            const right = left + 1;
            const bind0 = keybinds[left];
            const bind1 = keybinds[right];

            var l = r.tui.Line{};
            try l.pushSpan(alloc, .{ .content = "├[", .style = .{ .fg = app.theme.muted } });
            try l.pushSpanPrint(alloc, "{s}", .{bind0.@"0"}, .{ .fg = app.theme.info });
            try l.pushSpan(alloc, .{ .content = "] ", .style = .{ .fg = app.theme.muted } });
            try l.pushSpanPrint(alloc, "{s: <22}", .{bind0.@"1"}, .{ .fg = app.theme.muted });

            try l.pushSpan(alloc, .{ .content = "[", .style = .{ .fg = app.theme.muted } });
            try l.pushSpanPrint(alloc, "{s}", .{bind1.@"0"}, .{ .fg = app.theme.info });
            try l.pushSpan(alloc, .{ .content = "] ", .style = .{ .fg = app.theme.muted } });
            try l.pushSpanPrint(alloc, "{s}", .{bind1.@"1"}, .{ .fg = app.theme.muted });

            try out.append(alloc, l);
        }

        if (bind_count % 2 != 0) {
            const bind0 = keybinds[bind_count - 1];
            var l = r.tui.Line{};
            try l.pushSpan(alloc, .{ .content = "├[", .style = .{ .fg = app.theme.muted } });
            try l.pushSpanPrint(alloc, "{s}", .{bind0.@"0"}, .{ .fg = app.theme.info });
            try l.pushSpan(alloc, .{ .content = "] ", .style = .{ .fg = app.theme.muted } });
            try l.pushSpanPrint(alloc, "{s}", .{bind0.@"1"}, .{ .fg = app.theme.muted });
            try out.append(alloc, l);
        }
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
