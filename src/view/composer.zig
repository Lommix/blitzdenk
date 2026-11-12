const std = @import("std");
const r = @import("../root.zig");
const App = r.app.App;
const chrome = @import("chrome.zig");
const completion = @import("completion.zig");
const permission = @import("permission.zig");
const wizard = @import("wizard.zig");

pub const WIDGET_PAD_X: u16 = 2;

const COMPOSER_PROMPT: []const u8 = "❯";

const FieldStyle = struct {
    prompt: []const u8,
    prompt_style: r.tui.Style = .{},
    text: r.tui.Style,
    mask: ?u8 = null,
};

pub fn modePrompt(mode: *const r.app.InputMode) []const u8 {
    return switch (mode.*) {
        .wizard => "  ",
        else => COMPOSER_PROMPT,
    };
}

pub fn modePromptCols(mode: *const r.app.InputMode) u16 {
    return promptCols(modePrompt(mode));
}

pub fn inputContentWidth(widget_width: u16) u16 {
    return widget_width -| (WIDGET_PAD_X * 2);
}

pub fn inputTextWidth(area_width: u16, prompt_cols: u16) u16 {
    return area_width -| prompt_cols;
}

pub fn promptCols(prompt: []const u8) u16 {
    return @intCast(@min(completion.textWidthCols(prompt), @as(usize, std.math.maxInt(u16))));
}

pub fn fieldTextStyle(app: *App) r.tui.Style {
    return .{ .fg = app.theme.text_hl };
}

pub fn renderCompletionPopup(app: *App, frame_alloc: std.mem.Allocator, input_area: r.tui.Rect, progress_h: u16, buf: *r.tui.Buffer) void {
    if (app.input_mode == .text and app.input_mode.text.completion_open) {
        const completions = completion.activeCompletions(app, frame_alloc, app.input.slice(), app.input.cursor);
        if (completions.len > 0) {
            var max_width: usize = 0;
            for (completions.items[0..completions.len]) |cmp| {
                const width = completion.textWidthCols(cmp.text) + 1 + completion.descriptionWidth(cmp.description);
                if (width > max_width) max_width = width;
            }

            var p = r.tui.Paragraph{};
            p.style.bg = app.theme.overlay;

            const visible = 8;
            const selected = @min(app.input_mode.text.completion_selected, completions.len - 1);
            const start = if (selected >= visible) selected + 1 - visible else 0;
            const end = @min(completions.len, start + visible);
            for (completions.items[start..end], 0..) |cmp, i| {
                const sel = start + i == selected;
                const cmd_style: r.tui.Style = .{ .fg = app.theme.text, .modifier = .{ .bold = true, .reverse = sel } };
                const desc_style: r.tui.Style = if (sel) cmd_style else .{ .fg = app.theme.muted };
                var line = r.tui.Line{};
                line.pushText(frame_alloc, cmp.text, cmd_style) catch {};
                if (cmp.description) |desc| {
                    line.pushText(frame_alloc, " ", desc_style) catch {};
                    line.pushText(frame_alloc, desc, desc_style) catch {};
                }
                p.lines.append(frame_alloc, line) catch {};
            }

            if (p.lines.items.len > 0) {
                const cols = modePromptCols(&app.input_mode);
                const text_origin: r.tui.Rect = .{
                    .x = input_area.x +| WIDGET_PAD_X +| cols,
                    .y = input_area.y +| 1 +| progress_h,
                    .width = inputTextWidth(inputContentWidth(input_area.width), cols),
                    .height = 1,
                };
                const anchor = completionAnchor(app, frame_alloc, text_origin.width);

                const height: u16 = @intCast(p.lines.items.len);
                const completion_area = r.tui.Rect{
                    .x = text_origin.x +| @as(u16, @intCast(@min(anchor.col, @as(usize, text_origin.width)))),
                    .y = text_origin.y +| @as(u16, @intCast(@min(anchor.row, @as(usize, std.math.maxInt(u16))))) -| height,
                    .width = @intCast(@min(max_width, std.math.maxInt(u16))),
                    .height = height,
                };
                p.renderSimple(frame_alloc, completion_area, buf);
            }
        }
    }
}

pub fn renderInputWidget(app: *App, arena: std.mem.Allocator, area: r.tui.Rect, progress_h: u16, progress_line: ?r.tui.Line, buf: *r.tui.Buffer) void {
    buf.fill(area, .{ .style = .{ .bg = app.theme.overlay_dark } });

    // 1-row top/bottom padding, 2-column left/right padding.
    const content: r.tui.Rect = .{
        .x = area.x +| WIDGET_PAD_X,
        .y = area.y +| 1,
        .width = inputContentWidth(area.width),
        .height = area.height -| 2,
    };
    if (content.width == 0 or content.height == 0) return;

    if (progress_line) |l| {
        l.render(content.x, content.y, content.width, buf);
    }

    const input_area: r.tui.Rect = .{
        .x = content.x,
        .y = content.y +| progress_h,
        .width = content.width,
        .height = content.height -| progress_h -| 1,
    };
    const status_area: r.tui.Rect = .{
        .x = content.x,
        .y = content.y +| content.height -| 1,
        .width = content.width,
        .height = 1,
    };

    switch (app.input_mode) {
        .text => renderInputContent(app, arena, input_area, buf),
        .perm_select, .perm_message => permission.renderPermissionContent(app, arena, input_area, buf),
        .wizard => wizard.renderWizardContent(app, arena, input_area, buf),
        .session_picker => wizard.renderSessionPickerContent(app, arena, input_area, buf),
    }

    chrome.renderStatusBar(app, status_area, buf);
}

pub fn renderFieldWidget(
    app: *App,
    arena: std.mem.Allocator,
    text: []const u8,
    cursor: usize,
    area: r.tui.Rect,
    st: FieldStyle,
    buf: *r.tui.Buffer,
) void {
    const prompt_cols = promptCols(st.prompt);
    const text_width = inputTextWidth(area.width, prompt_cols);
    if (area.height == 0 or text_width == 0) return;

    var l = r.tui.input_layout.layout(arena, text, cursor, text_width, st.text, .{ .fg = app.theme.text_hl, .bg = app.theme.muted }, st.mask) catch return;
    defer l.deinit(arena);

    var para: r.tui.Paragraph = .{
        .border = .none,
        .wrap = false,
        .padding = .{ .left = prompt_cols },
    };
    para.lines.appendSlice(arena, l.rows.items) catch return;
    para.scroll_offset = if (l.cursor.row < area.height) 0 else l.cursor.row - area.height + 1;

    const draw_area: r.tui.Rect = .{
        .x = area.x,
        .y = area.y,
        .width = prompt_cols +| text_width +| 1,
        .height = area.height,
    };
    para.render(arena, draw_area, area, buf);
    buf.setStringMax(area.x, area.y, st.prompt, st.prompt_style, area.width);
}

fn renderInputContent(app: *App, arena: std.mem.Allocator, area: r.tui.Rect, buf: *r.tui.Buffer) void {
    const display = app.displayInput(arena);
    renderFieldWidget(app, arena, display.text, display.cursor, area, .{
        .prompt = COMPOSER_PROMPT,
        .prompt_style = .{ .fg = app.theme.muted },
        .text = fieldTextStyle(app),
    }, buf);
    if (app.screenshot_buf != null) {
        buf.setString(area.x, area.y, r.tui.icon.eye, .{ .fg = app.theme.ok });
    }
}

fn completionAnchor(app: *App, arena: std.mem.Allocator, width: u16) r.tui.input_layout.Pos {
    const display = app.displayInput(arena);
    var l = r.tui.input_layout.layout(arena, display.text, display.cursor, width, .{}, .{}, null) catch return .{};
    defer l.deinit(arena);
    return r.tui.input_layout.visualPos(&l, r.completion.tokenAt(display.text, display.cursor).start);
}
