//! Timeline block paragraphs: one `tui.Paragraph` per timeline entry, typed block
//! metadata for tool groups, agent calls and edits, and the padding seams between blocks.
const std = @import("std");
const r = @import("../root.zig");
const App = r.app.App;
const tool_runs = @import("tool_runs.zig");
const tools = @import("tools.zig");

pub const RenderParagraphItem = struct {
    p: r.tui.Paragraph,
    h: usize,
    kind: Kind,

    pub const Kind = union(enum) {
        user_message,
        agent_message,
        tool_group: ToolGroup,
        agent_call: ToolGroup,
        edit: Edit,

        pub fn isTool(self: Kind) bool {
            return switch (self) {
                .tool_group => true,
                .edit => |edit| edit.toggle != null,
                .user_message, .agent_message, .agent_call => false,
            };
        }

        pub fn toggle(self: Kind) ?tool_runs.ToolRun {
            return switch (self) {
                .tool_group => |group| group.toggle,
                .edit => |edit| edit.toggle,
                .user_message, .agent_message, .agent_call => null,
            };
        }
    };

    pub const ToolGroup = struct {
        live_calls: ?[]const tools.GroupCall = null,
        inline_images: []const ToolInlineImage = &.{},
        toggle: ?tool_runs.ToolRun = null,
    };

    pub const Edit = struct {
        toggle: ?tool_runs.ToolRun = null,
    };
};

pub const ToolInlineImage = struct {
    entry: *r.inline_images.Entry,
    row: usize,
    col: u16,
    cols: u16,
    rows: u16,
};

/// Rows a padded block pads above and below its content; see `seam`.
pub const tool_pad: u16 = 1;

pub const tool_padding: r.tui.Padding = .{ .left = 2, .right = 1, .top = tool_pad, .bottom = tool_pad };

pub const message_padding: r.tui.Padding = .{ .left = 2, .top = tool_pad, .bottom = tool_pad };

pub const Edge = enum { empty, tool, agent_call, message, other };

pub fn edge(item: RenderParagraphItem, top: bool) Edge {
    if (item.kind.isTool()) return .tool;
    if (item.kind == .agent_call) return .agent_call;
    const pad = if (top) item.p.padding.top else item.p.padding.bottom;
    return if (pad > 0) .message else .other;
}

/// Rows saved where the top of `lower` meets the bottom of `upper`. Stacked
/// tool blocks drop both pads; blocks sharing a background share one pad;
/// a message next to a tool block keeps both, one row per background.
pub fn seam(lower: Edge, upper: Edge) usize {
    if (lower == .tool and upper == .tool) return 2 * @as(usize, tool_pad);
    const tools_bg = (lower == .tool or lower == .agent_call) and (upper == .tool or upper == .agent_call);
    return if (tools_bg or (lower == .message and upper == .message)) tool_pad else 0;
}

/// Drop the facing padding `seam` saves between the last two stack items,
/// keeping `total` in sync.
pub fn collapsePadding(out: *std.ArrayList(RenderParagraphItem), total: *usize) void {
    if (out.items.len < 2) return;
    const prev = &out.items[out.items.len - 2];
    const next = &out.items[out.items.len - 1];
    const saved = seam(edge(prev.*, true), edge(next.*, false));
    if (saved == 0) return;
    // Padded blocks carry no border, so padding rows are part of `h` one to one.
    dropTopPadding(prev, total);
    if (saved > tool_pad) {
        next.h -= next.p.padding.bottom;
        total.* -= next.p.padding.bottom;
        next.p.padding.bottom = 0;
    }
}

fn dropTopPadding(item: *RenderParagraphItem, total: *usize) void {
    item.h -= item.p.padding.top;
    total.* -= item.p.padding.top;
    item.p.padding.top = 0;
}

fn push(arena: std.mem.Allocator, out: *std.ArrayList(RenderParagraphItem), total: *usize, p: r.tui.Paragraph, kind: RenderParagraphItem.Kind, inner_w: u16) !void {
    const h = p.totalHeightLong(inner_w);
    try out.append(arena, .{ .p = p, .h = h, .kind = kind });
    total.* += h;
    collapsePadding(out, total);
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

    var header_para = r.tui.Paragraph{ .padding = .{ .left = message_padding.left, .top = message_padding.top } };
    const first_item = out.items.len;
    var header_line = r.tui.Line{};

    var has_text = false;
    var has_handoff = false;

    // Header last so it renders on top (stack is bottom-up)
    var tool_call_list = std.ArrayList(tools.GroupCall).empty;
    // Run slots match tool calls in part order; walk them backwards too.
    var slot_i = runs.slots.len;

    const text_kind: RenderParagraphItem.Kind = if (entry.role == .user) .user_message else .agent_message;

    for (0..entry.parts.len) |i| {
        const part = entry.parts[entry.parts.len - i - 1];
        switch (part) {
            .tool_call => |call| {
                const slot: tool_runs.RunSlot = if (slot_i > 0) blk: {
                    slot_i -= 1;
                    break :blk runs.slots[slot_i];
                } else .{};
                if (slot.agent) {
                    try tools.appendToolGroup(arena, out, total, app, &tool_call_list, inner_w, live_tool_blocks);
                    const solo = [_]tools.GroupCall{.{ .call = call }};
                    var item = try tools.buildToolGroupParagraph(app, arena, &solo, inner_w);
                    var group = item.kind.tool_group;
                    if (live_tool_blocks) group.live_calls = arena.dupe(tools.GroupCall, &solo) catch null;
                    item.kind = .{ .agent_call = group };
                    try out.append(arena, item);
                    total.* += item.h;
                    continue;
                }
                if (runs.hasDiff(call.call_id)) {
                    try tools.appendToolGroup(arena, out, total, app, &tool_call_list, inner_w, live_tool_blocks);
                    try appendEditBlocks(arena, out, total, app, call, runs, inner_w);
                    continue;
                }
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
                            var p = r.tui.Paragraph{ .padding = message_padding };
                            try p.appendText(arena, text, .{ .fg = app.theme.muted });
                            try push(arena, out, total, p, text_kind, inner_w);
                        }
                    },
                    .message => |text| {
                        has_text = true;
                        var p = r.tui.Paragraph{ .padding = message_padding };
                        try appendMarkdownText(&p, app.gpa, arena, text, inner_w -| message_padding.left, app.theme);
                        try push(arena, out, total, p, text_kind, inner_w);
                    },
                    .plain_text => |text| {
                        has_text = true;
                        var p = r.tui.Paragraph{ .padding = message_padding };
                        try p.appendText(arena, text, .{ .fg = app.theme.text });
                        try push(arena, out, total, p, text_kind, inner_w);
                    },
                    .diff => |diff| {
                        if (app.flags.show_diffs and diff.call_id.len == 0) {
                            const p = buildDiffParagraph(arena, app, diff);
                            try push(arena, out, total, p, .{ .edit = .{} }, inner_w);
                        }
                    },
                    .handoff => |text| {
                        has_handoff = true;
                        try appendHandoffBlocks(arena, out, total, app, text, runs.entry, inner_w);
                    },
                    .tool_call => unreachable,
                }
            },
        }
    }

    try tools.appendToolGroup(arena, out, total, app, &tool_call_list, inner_w, live_tool_blocks);

    const show_header = (entry.role != .agent or has_text) and !has_handoff;
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
        if (out.items.len > first_item) {
            const below = &out.items[out.items.len - 1];
            if (below.kind == .user_message or below.kind == .agent_message) dropTopPadding(below, total);
        }
        try push(arena, out, total, header_para, text_kind, inner_w);
    }
}

fn appendEditBlocks(
    arena: std.mem.Allocator,
    out: *std.ArrayList(RenderParagraphItem),
    total: *usize,
    app: *App,
    call: r.app.TimelinePart.ToolCallEntry,
    runs: tool_runs.ToolRuns,
    inner_w: u16,
) !void {
    const theme = app.theme;
    const bold: @FieldType(r.tui.Style, "modifier") = .{ .bold = true };
    var n = runs.diffs.len;
    while (n > 0) {
        n -= 1;
        const diff = runs.diffs[n];
        if (!std.mem.eql(u8, diff.call_id, call.call_id)) continue;
        const id = try std.fmt.allocPrint(arena, "{s}#{d}", .{ call.call_id, n });
        const open = app.flags.show_diffs != app.view.tool_runs_expanded.contains(id);
        if (open) {
            const p = buildDiffParagraph(arena, app, diff);
            const h = p.totalHeightLong(inner_w);
            try out.append(arena, .{ .p = p, .h = h, .kind = .{ .edit = .{} } });
            total.* += h;
        }

        var p = r.tui.Paragraph{ .wrap = false, .padding = tool_padding };
        p.style.bg = theme.bg;
        if (open) p.padding.bottom = 0;
        const path = if (app.cwd.len > 0) try std.mem.replaceOwned(u8, arena, diff.path, app.cwd, ".") else diff.path;
        try p.appendLineSpan(arena, &.{
            .{ .content = r.tui.icon.ok, .style = .{ .fg = theme.ok, .modifier = bold } },
            .{ .content = " " },
            .{ .content = call.tool_name, .style = .{ .fg = theme.text_hl, .modifier = bold } },
            .{ .content = " " },
            .{ .content = path, .style = .{ .fg = theme.muted } },
        });

        var stat: r.tools.DiffStat = .{};
        for (diff.diff_lines) |line| switch (line.kind) {
            .addition => stat.insertions += 1,
            .deletion => stat.deletions += 1,
            .context, .header => {},
        };
        var fold = r.tui.Line{};
        try fold.pushSpan(arena, .{ .content = " " ++ r.tui.icon.box_bl ++ (if (open) " ▾ " else " ▸ "), .style = .{ .fg = theme.muted } });
        if (stat.insertions > 0) try fold.pushSpanPrint(arena, "+{d} ", .{stat.insertions}, .{ .fg = theme.diff_add, .modifier = bold });
        if (stat.deletions > 0) try fold.pushSpanPrint(arena, "-{d} ", .{stat.deletions}, .{ .fg = theme.diff_remove, .modifier = bold });
        if (stat.total() == 0) try fold.pushSpan(arena, .{ .content = "0 ", .style = .{ .fg = theme.muted } });
        try fold.pushSpan(arena, .{ .content = "lines", .style = .{ .fg = theme.muted } });
        try p.lines.append(arena, fold);

        const h = p.totalHeightLong(inner_w);
        try out.append(arena, .{ .p = p, .h = h, .kind = .{ .edit = .{ .toggle = .{ .id = id, .entry = runs.entry, .expanded = open } } } });
        total.* += h;
        collapsePadding(out, total);
    }
}

fn appendHandoffBlocks(
    arena: std.mem.Allocator,
    out: *std.ArrayList(RenderParagraphItem),
    total: *usize,
    app: *App,
    text: []const u8,
    entry: usize,
    inner_w: u16,
) !void {
    const theme = app.theme;
    const bold: @FieldType(r.tui.Style, "modifier") = .{ .bold = true };
    const id = try std.fmt.allocPrint(arena, "handoff#{d}", .{entry});
    const open = app.view.tool_runs_expanded.contains(id);
    if (open) {
        var body: r.tui.Paragraph = .{
            .border = .single,
            .sides = .left_only,
            .padding = .{ .left = 1 },
            .style = .{ .fg = theme.border, .bg = theme.diff_surface },
        };
        try appendMarkdownText(&body, app.gpa, arena, text, inner_w -| 2, theme);
        const h = body.totalHeightLong(inner_w);
        try out.append(arena, .{ .p = body, .h = h, .kind = .{ .edit = .{} } });
        total.* += h;
    }

    var p = r.tui.Paragraph{ .wrap = false, .padding = tool_padding };
    p.style.bg = theme.bg;
    if (open) p.padding.bottom = 0;
    try p.appendLineSpan(arena, &.{
        .{ .content = r.tui.icon.ok, .style = .{ .fg = theme.ok, .modifier = bold } },
        .{ .content = " " },
        .{ .content = "compact", .style = .{ .fg = theme.text_hl, .modifier = bold } },
        .{ .content = " handoff", .style = .{ .fg = theme.muted } },
    });
    var fold = r.tui.Line{};
    try fold.pushSpan(arena, .{ .content = " " ++ r.tui.icon.box_bl ++ (if (open) " ▾ " else " ▸ "), .style = .{ .fg = theme.muted } });
    try fold.pushSpanPrint(arena, "{d} lines", .{std.mem.count(u8, text, "\n") + 1}, .{ .fg = theme.muted });
    try p.lines.append(arena, fold);

    const h = p.totalHeightLong(inner_w);
    try out.append(arena, .{ .p = p, .h = h, .kind = .{ .edit = .{ .toggle = .{ .id = id, .entry = entry, .expanded = open } } } });
    total.* += h;
    collapsePadding(out, total);
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
