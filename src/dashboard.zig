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
    .{ "c+g", "toggle permission" },
    .{ "esc", "cancel" },
    .{ "c+n", "clear" },
    .{ "c+c", "quit" },
    .{ "c+u", "scroll up" },
    .{ "c+d", "scroll down" },
    .{ "c+t", "show thinking" },
};

pub fn build_header(frame: usize, alloc: std.mem.Allocator, out: *std.ArrayList(r.tui.Line)) !void {
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
                .r = blend,
                .g = 200 +| blend / 5,
                .b = 200 +| blend / 5,
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
    try build_header(app.frame_count, app.arena_frame.allocator(), out);
    const alloc = app.arena_frame.allocator();

    try out.append(
        alloc,
        try r.tui.Line.new(alloc,
            \\├[github.com/lommix/blitzdenk ............................... v{s}
            \\
        , .{r.VERSION}, .{ .fg = app.theme.muted }),
    );

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
    try line.pushSpanPrint(alloc, "{s}", .{app.cwd}, .{ .fg = app.theme.info, .modifier = .{ .bold = true } });
    try out.append(alloc, line);

    {
        var skill_count: usize = 0;
        if (app.context_factory.skill_dir) |skill_dir| {
            var it = skill_dir.iterate();
            while (true) {
                const entry = it.next(app.io) catch break orelse break;
                if (std.mem.endsWith(u8, entry.name, ".md")) {
                    skill_count += 1;
                }
            }
        }

        var l = r.tui.Line{};
        try l.pushSpan(alloc, .{ .content = "├[context:  ", .style = .{ .fg = app.theme.muted } });
        try l.pushSpanPrint(alloc, "skills: {}", .{skill_count}, .{ .fg = app.theme.info });
        try l.pushSpanPrint(alloc, "  mcp: {}", .{app.lua_vm.mcp_entries.items.len}, .{ .fg = app.theme.info });
        try l.pushSpanPrint(alloc, "  lsp: {}", .{app.lua_vm.lsp_entries.items.len}, .{ .fg = app.theme.info });
        try out.append(alloc, l);
    }

    try out.append(alloc, try r.tui.Line.new(alloc, "│", .{}, .{ .fg = app.theme.muted }));
    try out.append(alloc, try r.tui.Line.new(alloc, "│ Agents", .{}, .{ .fg = app.theme.muted }));

    for (0..app.context_factory.agent_counter) |agent_idx| {
        const ag_type: r.ContextFactory.AgentType = @enumFromInt(agent_idx);
        const def = app.context_factory.agents.get(ag_type) orelse continue;

        const model = def.model orelse continue;

        var l = r.tui.Line{};
        try l.pushSpan(alloc, .{ .content = "├[", .style = .{ .fg = app.theme.muted } });
        try l.pushSpanPrint(alloc, "{s: <8} ", .{def.name}, .{ .fg = app.theme.muted, .modifier = .{ .bold = true } });
        try l.pushSpanPrint(alloc, "{s: <28} ", .{model.name}, .{ .fg = app.theme.info });
        try l.pushSpanPrint(alloc, "@{s} ", .{@tagName(model.effort)}, .{ .fg = app.theme.text });
        try out.append(alloc, l);
    }

    try out.append(alloc, try r.tui.Line.new(alloc, "│", .{}, .{ .fg = app.theme.muted }));
    try out.append(alloc, try r.tui.Line.new(
        alloc,
        "└[default: {s} ",
        .{app.config.default_model.getName()},
        .{ .fg = app.theme.muted },
    ));
}
