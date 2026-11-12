const std = @import("std");
const r = @import("../root.zig");
const App = r.app.App;
const text_utils = r.tui.text_utils;
const composer = @import("composer.zig");

const PERM_FIELD_PROMPT: []const u8 = "> ";

const PERM_FIELD_MAX_ROWS: u16 = 10;

/// Column of the call/diff message field, under the `>` of the option rows.
const PERM_FIELD_LABEL_COLS: u16 = 7;

fn permMessageDisplay(app: *App, arena: std.mem.Allocator) ?r.clipboard.Display {
    const pm = switch (app.input_mode) {
        .perm_message => |*pm| pm,
        else => return null,
    };
    return r.clipboard.toDisplay(arena, pm.field.slice(), pm.field.cursor) catch
        .{ .text = pm.field.slice(), .cursor = pm.field.cursor };
}

/// Text columns of the permission message field inside a dialog of
/// `inner_width`: row indent, the call/diff label column, the prompt.
pub fn permFieldTextWidth(app: *App, inner_width: u16) u16 {
    const label_cols: u16 = if (app.askSession() != null) 0 else PERM_FIELD_LABEL_COLS;
    return composer.inputTextWidth(inner_width -| 1 -| label_cols, composer.promptCols(PERM_FIELD_PROMPT));
}

/// Wrapped rows of the open permission message field; null while no field
/// is open.
pub fn permFieldRows(app: *App, arena: std.mem.Allocator, inner_width: u16) ?u16 {
    const display = permMessageDisplay(app, arena) orelse return null;
    const counted = r.tui.input_layout.rowCount(arena, display.text, permFieldTextWidth(app, inner_width)) catch 1;
    return @intCast(std.math.clamp(counted, 1, PERM_FIELD_MAX_ROWS));
}

/// Draw the open permission message field into its dialog row.
fn renderPermField(app: *App, arena: std.mem.Allocator, area: r.tui.Rect, buf: *r.tui.Buffer) void {
    const display = permMessageDisplay(app, arena) orelse return;
    composer.renderFieldWidget(app, arena, display.text, display.cursor, area, .{
        .prompt = PERM_FIELD_PROMPT,
        .prompt_style = .{ .fg = app.theme.text },
        .text = composer.fieldTextStyle(app),
    }, buf);
    if (app.screenshot_buf != null) {
        buf.setString(area.x +| area.width -| 6, area.y, "[IMG]", .{ .fg = app.theme.ok });
    }
}

fn currentSelection(app: *App) u8 {
    return switch (app.input_mode) {
        .perm_select => |ps| ps.selected,
        else => 0,
    };
}

pub fn renderPermissionContent(app: *App, arena: std.mem.Allocator, area: r.tui.Rect, buf: *r.tui.Buffer) void {
    const block: r.tui.Block = .{
        .style = .{ .fg = app.theme.warn },
        .borders = .{ .bottom = true, .left = true, .right = true },
    };

    block.render(area, buf);
    const inner = block.innerArea(area);
    if (inner.width == 0 or inner.height == 0) return;

    const field_rows = permFieldRows(app, arena, inner.width);
    const entry = app.active_permission orelse {
        _ = app.active_selection orelse return;
        renderAskWidget(app, arena, inner, field_rows, buf);
        return;
    };

    if (entry.payload == .ask) {
        renderAskWidget(app, arena, inner, field_rows, buf);
        return;
    }

    var header_buf: [256]u8 = undefined;
    const header_line: []const u8 = switch (entry.payload) {
        .call => |p| p.description,
        .diff => |p| blk: {
            const n = std.fmt.bufPrint(&header_buf, "edit: {s}", .{p.path}) catch "edit";
            break :blk n;
        },
        .ask => unreachable,
    };

    const width = inner.width -| 1;
    const header_rows = text_utils.wrappedRowCount(header_line, width);
    _ = text_utils.renderWrappedText(buf, header_line, inner.x + 1, inner.y, width, header_rows, 0, .{ .fg = app.theme.warn });

    const labels = [3][]const u8{ "allow?  yes", "        no", "        enter message" };
    const labels_sel = [3][]const u8{ "allow? >yes", "       >no", "       >enter message" };

    const cur_sel = currentSelection(app);
    const bottom = inner.y +| inner.height;
    for (0..labels.len) |i| {
        const y = inner.y + header_rows + @as(u16, @intCast(i));
        if (y >= bottom) break;
        if (field_rows != null and i == labels.len - 1) {
            renderPermField(app, arena, .{
                .x = inner.x + 1 + PERM_FIELD_LABEL_COLS,
                .y = y,
                .width = inner.width -| 1 -| PERM_FIELD_LABEL_COLS,
                .height = @min(field_rows.?, bottom -| y),
            }, buf);
            break;
        }
        const selected = field_rows == null and cur_sel == @as(u8, @intCast(i));
        const style: r.tui.Style = .{ .fg = app.theme.text, .modifier = .{ .reverse = selected } };
        const label = if (selected) labels_sel[i] else labels[i];
        buf.setStringMax(inner.x + 1, y, label, style, inner.width -| 1);
    }
}

fn renderAskWidget(app: *App, arena: std.mem.Allocator, inner: r.tui.Rect, field_rows: ?u16, buf: *r.tui.Buffer) void {
    const s = app.askSession() orelse return;
    const field_area = r.ask_session.render(s, .{
        .accent = app.theme.info,
        .muted = app.theme.muted,
        .text = app.theme.text,
    }, inner, field_rows, buf) orelse return;
    renderPermField(app, arena, field_area, buf);
}

pub fn askPermissionInputHeight(app: *App, area_width: u16, area_height: u16, field_rows: ?u16) u16 {
    const s = app.askSession() orelse return 9;
    return r.ask_session.widgetHeight(s.questions, area_width, area_height, field_rows);
}
