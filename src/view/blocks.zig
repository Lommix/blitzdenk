const std = @import("std");
const r = @import("../root.zig");
const App = r.app.App;
const tool_runs = @import("tool_runs.zig");
const tools = @import("tools.zig");

pub const RenderParagraphItem = struct {
    p: r.tui.Paragraph,
    h: usize,
    is_tool_block: bool = false,
    live_calls: ?[]const tools.GroupCall = null,
    inline_images: []const ToolInlineImage = &.{},
    /// Summary row of a bash/read run; clicking it toggles the run.
    toggle_run: ?tool_runs.ToolRun = null,
};

pub const ToolInlineImage = struct {
    entry: *r.inline_images.Entry,
    row: usize,
    col: u16,
    cols: u16,
    rows: u16,
};

/// Rows a tool block pads above and below its content. Stacked tool blocks
/// drop the facing pads so they read as one block.
pub const tool_pad: u16 = 1;

/// Rows saved where a tool block sits directly on another tool block.
pub fn toolSeam(lower_is_tool: bool, upper_is_tool: bool) usize {
    return if (lower_is_tool and upper_is_tool) 2 * @as(usize, tool_pad) else 0;
}

/// Zero the facing padding between the last two stack items when both are tool
/// blocks, keeping `total` in sync. Tool groups and run summary rows set
/// `is_tool_block`.
pub fn collapseToolPadding(out: *std.ArrayList(RenderParagraphItem), total: *usize) void {
    if (out.items.len < 2) return;
    const prev = &out.items[out.items.len - 2];
    const next = &out.items[out.items.len - 1];
    if (!prev.is_tool_block or !next.is_tool_block) return;
    // Tool blocks carry no border, so padding rows are part of `h` one to one.
    prev.h -= prev.p.padding.top;
    next.h -= next.p.padding.bottom;
    total.* -= @as(usize, prev.p.padding.top) + next.p.padding.bottom;
    prev.p.padding.top = 0;
    next.p.padding.bottom = 0;
}

/// Build one r.tui.Paragraph per TimelineEntry. Allocations live in `arena`; do not
/// deinit the result. All paragraphs use `reverse = true` so the timeline-area
/// caller can stack them bottom-up.
pub fn buildTimelineEntryParagraph(
    arena: std.mem.Allocator,
    out: *std.ArrayList(RenderParagraphItem),
    total: *usize,
    app: *App,
    entry: r.app.TimelineEntry,
    inner_w: u16,
    live_tool_blocks: bool,
    runs: tool_runs.ToolRuns,
) !void {
    // var buf: [255]u8 = undefined;

    var header_para = r.tui.Paragraph{};
    var header_line = r.tui.Line{};

    var has_text = false;

    // Header last so it renders on top (stack is bottom-up)
    var tool_call_list = std.ArrayList(tools.GroupCall).empty;
    // Run slots match tool calls in part order; walk them backwards too.
    var slot_i = runs.slots.len;

    for (0..entry.parts.len) |i| {
        const part = entry.parts[entry.parts.len - i - 1];
        switch (part) {
            .tool_call => |call| {
                const slot: tool_runs.RunSlot = if (slot_i > 0) blk: {
                    slot_i -= 1;
                    break :blk runs.slots[slot_i];
                } else .{};
                const run = if (slot.run != tool_runs.RunSlot.none) runs.runs[slot.run] else null;
                const anchor = if (run) |value| value.anchor() else null;
                if (anchor) |a| if (slot.pos < a) continue;
                const rail: tools.RunRail = if (anchor == null) .none else if (slot.pos + 1 == run.?.len) .last else .mid;
                try tool_call_list.append(arena, .{ .call = call, .rail = rail });
                if (anchor != null and anchor.? == slot.pos) {
                    try tools.appendToolGroup(arena, out, total, app, &tool_call_list, inner_w, live_tool_blocks);
                    try tool_runs.appendRunSummary(arena, out, total, app, run.?, inner_w);
                }
            },
            else => {
                try tools.appendToolGroup(arena, out, total, app, &tool_call_list, inner_w, live_tool_blocks);
                switch (part) {
                    .thinking => |text| {
                        if (app.flags.show_thinking) {
                            var p = r.tui.Paragraph{};
                            try p.appendText(arena, text, .{ .fg = app.theme.muted });
                            const h = p.totalHeightLong(inner_w);
                            try out.append(arena, .{ .p = p, .h = h });
                            total.* += h;
                        }
                    },
                    .message => |text| {
                        has_text = true;
                        var p = r.tui.Paragraph{};
                        try appendMarkdownText(&p, app.gpa, arena, text, inner_w, app.theme);
                        const h = p.totalHeightLong(inner_w);
                        try out.append(arena, .{ .p = p, .h = h });
                        total.* += h;
                    },
                    .plain_text => |text| {
                        has_text = true;
                        var p = r.tui.Paragraph{};
                        try p.appendText(arena, text, .{ .fg = app.theme.text });
                        const h = p.totalHeightLong(inner_w);
                        try out.append(arena, .{ .p = p, .h = h });
                        total.* += h;
                    },
                    .diff => |diff| {
                        if (app.flags.show_diffs) {
                            const p = buildDiffParagraph(arena, app, diff);
                            const h = p.totalHeightLong(inner_w);
                            try out.append(arena, .{ .p = p, .h = h });
                            total.* += h;
                        }
                    },
                    .tool_call => unreachable,
                }
            },
        }
    }

    try tools.appendToolGroup(arena, out, total, app, &tool_call_list, inner_w, live_tool_blocks);

    const show_header = entry.role != .agent or has_text;
    if (show_header) {
        const role_text: []const u8 = switch (entry.role) {
            .user => "❯ you:",
            .agent => "❯ blitz:",
            .system => "❯ system:",
        };

        const role_color: r.tui.Color = switch (entry.role) {
            .user => app.theme.role_user,
            .agent => app.theme.role_agent,
            .system => app.theme.role_system,
        };

        try header_line.pushSpan(arena, .{ .content = role_text, .style = .{ .modifier = .{ .bold = true }, .fg = role_color } });
        try header_para.lines.append(arena, header_line);
        try out.append(arena, .{ .p = header_para, .h = 1 });
        total.* += 1;
    }
}

fn buildDiffParagraph(arena: std.mem.Allocator, app: *App, d: r.app.TimelinePart.DiffEntry) r.tui.Paragraph {
    const theme = app.theme;
    var p: r.tui.Paragraph = .{
        .border = .single,
        .sides = .left_only,
        .reverse = true,
        .style = .{ .fg = theme.border, .bg = theme.diff_surface },
    };

    var header_line = r.tui.Line{};
    header_line.pushSpan(arena, .{ .content = "file: ", .style = .{ .fg = theme.muted, .modifier = .{ .bold = true } } }) catch {};
    header_line.pushSpan(arena, .{ .content = d.path, .style = .{ .fg = theme.info } }) catch {};
    p.lines.append(arena, header_line) catch {};

    for (d.diff_lines) |dl| {
        const dl_info: struct { prefix: []const u8, style: r.tui.Style, bg: r.tui.Color } = switch (dl.kind) {
            .deletion => .{ .prefix = "- ", .style = .{ .fg = theme.diff_remove }, .bg = theme.diff_surface },
            .addition => .{ .prefix = "+ ", .style = .{ .fg = theme.diff_add }, .bg = theme.diff_surface },
            .context => .{ .prefix = "  ", .style = .{ .fg = theme.text }, .bg = theme.diff_surface },
            .header => .{ .prefix = "@ ", .style = .{ .fg = theme.info, .modifier = .{ .bold = true } }, .bg = .reset },
        };
        const num_str = if (dl.line_number) |n|
            std.fmt.allocPrint(arena, "{d:>4} ", .{n}) catch "     "
        else
            "     ";

        var src: r.tui.Line = .{ .style = .{ .bg = dl_info.bg } };
        src.pushText(arena, num_str, .{ .fg = theme.muted, .bg = dl_info.bg }) catch {};
        src.pushSpan(arena, .{ .content = dl_info.prefix, .style = dl_info.style }) catch {};
        src.pushSpan(arena, .{ .content = dl.content, .style = dl_info.style }) catch {};
        p.lines.append(arena, src) catch break;
    }
    return p;
}

fn markdownTheme(theme: r.app.Theme) r.tui.HighlightTheme {
    return .{
        .heading = .{ .fg = theme.info, .modifier = .{ .bold = true } },
        .bold = .{ .fg = theme.text, .modifier = .{ .bold = true } },
        .italic = .{ .fg = theme.text, .modifier = .{ .italic = true } },
        .inline_code = .{ .fg = theme.warn },
        .code_default = .{ .fg = theme.text_hl },
        .code_keyword = .{ .fg = theme.warn, .modifier = .{ .bold = true } },
        .code_expression = .{ .fg = theme.info },
        .code_string = .{ .fg = theme.ok },
        .code_number = .{ .fg = theme.warn },
        .code_comment = .{ .fg = theme.muted, .modifier = .{ .italic = true } },
        .list_marker = .{ .fg = theme.info },
        .quote = .{ .fg = theme.info, .modifier = .{ .italic = true } },
        .hr = .{ .fg = theme.info },
        .plain = .{ .fg = theme.text },
        .table_border = .{ .fg = theme.border },
        .table_text = .{ .fg = theme.text },
        .table_header = .{ .fg = theme.text_hl, .modifier = .{ .bold = true } },
        .mermaid = .{
            .text = .{ .fg = theme.text },
            .strong = .{ .fg = theme.text_hl, .modifier = .{ .bold = true } },
            .muted = .{ .fg = theme.muted },
            .border = .{ .fg = theme.border },
            .edge = .{ .fg = theme.border },
            .accent = .{ .fg = theme.info },
        },
    };
}

fn appendMarkdownText(p: *r.tui.Paragraph, gpa: std.mem.Allocator, arena: std.mem.Allocator, raw: []const u8, width: u16, theme: r.app.Theme) !void {
    if (raw.len == 0) return;
    const md_theme = markdownTheme(theme);
    var renderer = r.tui.MarkdownStreamRenderer.initWithOptions(gpa, arena, width, md_theme, .{});
    defer renderer.deinit();
    try renderer.feed(raw);
    renderer.finish();
    if (width > 0) p.wrap = false;
    while (try renderer.next()) |line| {
        try p.lines.append(arena, line);
    }
}
