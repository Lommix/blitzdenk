const std = @import("std");
const widgets = @import("widgets.zig");
const cell = @import("cell.zig");
const icon = @import("icon.zig");

const Line = widgets.Line;
const Style = cell.Style;

pub const Theme = struct {
    text: Style = .{ .fg = .bright_white },
    strong: Style = .{ .fg = .bright_white, .modifier = .{ .bold = true } },
    muted: Style = .{ .fg = .bright_black },
    border: Style = .{ .fg = .bright_white },
    edge: Style = .{ .fg = .bright_white },
    accent: Style = .{ .fg = .yellow },
};

pub const Options = struct {
    width: u16 = 80,
    theme: Theme = .{},
    max_node_width: u16 = 48,
    max_height: usize = 4096,
    max_cells: usize = 2 * 1024 * 1024,
};

const G_HDASH: u21 = cp(icon.box_h);
const G_VDASH: u21 = cp(icon.box_v);
const G_HHEAVY: u21 = cp(icon.double_box_h);
const G_VHEAVY: u21 = cp(icon.double_box_v);
const G_CROSS: u21 = cp(icon.box_cross);
const G_T_DOWN: u21 = cp(icon.box_t_down);
const G_T_UP: u21 = cp(icon.box_t_up);
const G_T_RIGHT: u21 = cp(icon.box_t_right);
const G_T_LEFT: u21 = cp(icon.box_t_left);
const G_DCROSS: u21 = cp(icon.double_box_cross);
const G_DT_DOWN: u21 = cp(icon.double_box_t_down);
const G_DT_UP: u21 = cp(icon.double_box_t_up);
const G_DT_RIGHT: u21 = cp(icon.double_box_t_right);
const G_DT_LEFT: u21 = cp(icon.double_box_t_left);
const G_ARROW_R: u21 = cp("▶");
const G_ARROW_L: u21 = cp("◀");
const G_ARROW_D: u21 = cp("▼");
const G_ARROW_U: u21 = cp("▲");
const G_DOTTED_H: u21 = cp("┄");
const G_DOTTED_V: u21 = cp("┆");

fn cp(comptime s: []const u8) u21 {
    return std.unicode.utf8Decode(s) catch unreachable;
}

const DiagramKind = enum { flow, sequence, class, state, er, none };

pub fn render(alloc: std.mem.Allocator, width: u16, source: []const u8, out: *std.ArrayList(Line)) !void {
    try renderWithOptions(alloc, alloc, source, out, .{ .width = width });
}

pub fn renderWithOptions(gpa: std.mem.Allocator, alloc: std.mem.Allocator, source: []const u8, out: *std.ArrayList(Line), options: Options) !void {
    const src = std.mem.trim(u8, source, " \t\r\n");
    if (src.len == 0) return;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const scratch = arena.allocator();
    switch (detectKind(src)) {
        .flow => try renderFlowchart(scratch, alloc, src, out, options, null),
        .sequence => try renderSequence(scratch, alloc, src, out, options),
        .class => try renderClass(scratch, alloc, src, out, options),
        .state => try renderState(scratch, alloc, src, out, options),
        .er => try renderEr(scratch, alloc, src, out, options),
        .none => try renderFallback(alloc, src, out, options.theme.muted),
    }
}

fn detectKind(src: []const u8) DiagramKind {
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        const word = firstWord(line);
        if (std.ascii.eqlIgnoreCase(word, "graph") or std.ascii.eqlIgnoreCase(word, "flowchart")) return .flow;
        if (std.ascii.eqlIgnoreCase(word, "sequenceDiagram")) return .sequence;
        if (std.ascii.eqlIgnoreCase(word, "classDiagram")) return .class;
        if (std.ascii.eqlIgnoreCase(word, "stateDiagram") or std.ascii.eqlIgnoreCase(word, "stateDiagram-v2")) return .state;
        if (std.ascii.eqlIgnoreCase(word, "erDiagram")) return .er;
        return .none;
    }
    return .none;
}

fn firstWord(line: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    return it.next() orelse "";
}

fn widthOf(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

fn breakTagLen(text: []const u8, start: usize) ?usize {
    const forms = [_][]const u8{ "<br />", "<br/>", "<br>" };
    for (forms) |form| {
        if (start + form.len <= text.len and std.ascii.eqlIgnoreCase(text[start .. start + form.len], form)) return form.len;
    }
    return null;
}

fn wrapText(alloc: std.mem.Allocator, text: []const u8, max_cols: usize) ![]const []const u8 {
    var lines = std.ArrayList([]const u8).empty;
    const limit = @max(1, max_cols);
    var start: usize = 0;
    while (start < text.len) {
        while (start < text.len and (text[start] == ' ' or text[start] == '\t')) start += 1;
        if (start >= text.len) break;
        if (text[start] == '\n') {
            try lines.append(alloc, "");
            start += 1;
            continue;
        }
        var i = start;
        var cols: usize = 0;
        var last_break: ?usize = null;
        var forced_break: usize = 0;
        while (i < text.len and text[i] != '\n' and cols < limit) {
            if (breakTagLen(text, i)) |len| {
                forced_break = len;
                break;
            }
            const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (text[i] == ' ' or text[i] == '\t') last_break = i;
            i += @min(len, text.len - i);
            cols += 1;
        }
        var end = i;
        if (forced_break == 0 and i < text.len and text[i] != '\n' and last_break != null and last_break.? > start) end = last_break.?;
        const line = std.mem.trim(u8, text[start..end], " \t");
        if (line.len > 0) try lines.append(alloc, line);
        if (forced_break > 0) {
            start = i + forced_break;
        } else if (i < text.len and text[i] == '\n') {
            start = i + 1;
        } else if (end < i) {
            start = end + 1;
        } else {
            start = i;
        }
    }
    if (lines.items.len == 0) try lines.append(alloc, "");
    return lines.toOwnedSlice(alloc);
}

fn maxLineWidth(lines: []const []const u8) usize {
    var width: usize = 0;
    for (lines) |line| width = @max(width, widthOf(line));
    return width;
}

fn wrapNodeText(alloc: std.mem.Allocator, text: []const u8, max_cols: usize, shape: Shape, header_lines: ?*usize) ![]const []const u8 {
    if (shape != .compartmented) {
        if (header_lines) |count| count.* = 0;
        return wrapText(alloc, text, max_cols);
    }

    var lines = std.ArrayList([]const u8).empty;
    var parts = std.mem.splitScalar(u8, text, '|');
    var first = true;
    while (parts.next()) |part| {
        const wrapped = try wrapText(alloc, std.mem.trim(u8, part, " \t"), max_cols);
        try lines.appendSlice(alloc, wrapped);
        if (first) {
            if (header_lines) |count| count.* = wrapped.len;
            first = false;
        }
    }
    return lines.toOwnedSlice(alloc);
}

fn putTextLines(c: *Canvas, x: isize, y: isize, lines: []const []const u8, style: Style) void {
    for (lines, 0..) |line, index| putText(c, x, y + @as(isize, @intCast(index)), line, @intCast(widthOf(line)), style);
}

const CanvasCell = struct {
    ch: u21 = ' ',
    style: Style = .{},
};

const Canvas = struct {
    alloc: std.mem.Allocator,
    w: usize,
    h: usize,
    cells: []CanvasCell,
    theme: Theme,

    fn init(alloc: std.mem.Allocator, w: usize, h: usize, options: Options) !Canvas {
        if (h > options.max_height) return error.DiagramTooLarge;
        const cells_len = std.math.mul(usize, w, h) catch return error.DiagramTooLarge;
        if (cells_len > options.max_cells) return error.DiagramTooLarge;
        const cells = try alloc.alloc(CanvasCell, cells_len);
        for (cells) |*c| c.* = .{};
        return .{ .alloc = alloc, .w = w, .h = h, .cells = cells, .theme = options.theme };
    }

    fn deinit(self: *Canvas) void {
        self.alloc.free(self.cells);
    }

    fn put(self: *Canvas, x: isize, y: isize, ch: u21, style: Style) void {
        if (x < 0 or y < 0) return;
        const ux: usize = @intCast(x);
        const uy: usize = @intCast(y);
        if (ux >= self.w or uy >= self.h) return;
        self.cells[uy * self.w + ux] = .{ .ch = ch, .style = style };
    }
};

fn drawHLine(c: *Canvas, x0: isize, x1: isize, y: isize, ch: u21, style: Style) void {
    var x = @min(x0, x1);
    const xe = @max(x0, x1);
    while (x <= xe) : (x += 1) c.put(x, y, ch, style);
}

fn drawVLine(c: *Canvas, x: isize, y0: isize, y1: isize, ch: u21, style: Style) void {
    var y = @min(y0, y1);
    const ye = @max(y0, y1);
    while (y <= ye) : (y += 1) c.put(x, y, ch, style);
}

fn putText(c: *Canvas, x: isize, y: isize, text: []const u8, max_cols: isize, style: Style) void {
    var col: isize = 0;
    var i: usize = 0;
    while (i < text.len and col < max_cols) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch break;
        if (i + len > text.len) break;
        const ch = std.unicode.utf8Decode(text[i..][0..len]) catch break;
        i += len;
        c.put(x + col, y, ch, style);
        col += 1;
    }
}

fn putTextCentered(c: *Canvas, center_x: isize, y: isize, text: []const u8, style: Style) void {
    const w = widthOf(text);
    if (w == 0) return;
    putText(c, center_x - @as(isize, @intCast(w / 2)), y, text, @intCast(w), style);
}

fn putTextPaddedH(c: *Canvas, x: isize, y: isize, text: []const u8, style: Style, line_ch: u21, line_style: Style) void {
    const w: isize = @intCast(widthOf(text));
    if (w == 0) return;
    putText(c, x, y, text, w, style);
    c.put(x - 1, y, line_ch, line_style);
    c.put(x + w, y, line_ch, line_style);
}

fn putTextCenteredPaddedV(c: *Canvas, center_x: isize, y: isize, text: []const u8, style: Style, line_ch: u21, line_style: Style) void {
    const w: isize = @intCast(widthOf(text));
    if (w == 0) return;
    putText(c, center_x - @divTrunc(w, 2), y, text, w, style);
    c.put(center_x, y - 1, line_ch, line_style);
    c.put(center_x, y + 1, line_ch, line_style);
}

fn isLineJoint(ch: u21) bool {
    return switch (ch) {
        G_HDASH,
        G_VDASH,
        G_HHEAVY,
        G_VHEAVY,
        G_CROSS,
        G_T_DOWN,
        G_T_UP,
        G_T_RIGHT,
        G_T_LEFT,
        G_DCROSS,
        G_DT_DOWN,
        G_DT_UP,
        G_DT_RIGHT,
        G_DT_LEFT,
        => true,
        else => false,
    };
}

fn connectsUp(ch: u21) bool {
    return switch (ch) {
        G_VDASH,
        G_CROSS,
        G_T_UP,
        G_T_RIGHT,
        G_T_LEFT,
        G_VHEAVY,
        G_DCROSS,
        G_DT_UP,
        G_DT_RIGHT,
        G_DT_LEFT,
        => true,
        else => false,
    } or ch == cp(icon.box_bl) or ch == cp(icon.box_br) or
        ch == cp("╰") or ch == cp("╯") or
        ch == cp(icon.double_box_bl) or ch == cp(icon.double_box_br);
}

fn connectsDown(ch: u21) bool {
    return switch (ch) {
        G_VDASH,
        G_CROSS,
        G_T_DOWN,
        G_T_RIGHT,
        G_T_LEFT,
        G_VHEAVY,
        G_DCROSS,
        G_DT_DOWN,
        G_DT_RIGHT,
        G_DT_LEFT,
        => true,
        else => false,
    } or ch == cp(icon.box_tl) or ch == cp(icon.box_tr) or
        ch == cp("╭") or ch == cp("╮") or
        ch == cp(icon.double_box_tl) or ch == cp(icon.double_box_tr);
}

fn connectsLeft(ch: u21) bool {
    return switch (ch) {
        G_HDASH,
        G_CROSS,
        G_T_DOWN,
        G_T_UP,
        G_T_LEFT,
        G_HHEAVY,
        G_DCROSS,
        G_DT_DOWN,
        G_DT_UP,
        G_DT_LEFT,
        => true,
        else => false,
    } or ch == cp(icon.box_tr) or ch == cp(icon.box_br) or
        ch == cp("╮") or ch == cp("╯") or
        ch == cp(icon.double_box_tr) or ch == cp(icon.double_box_br);
}

fn connectsRight(ch: u21) bool {
    return switch (ch) {
        G_HDASH,
        G_CROSS,
        G_T_DOWN,
        G_T_UP,
        G_T_RIGHT,
        G_HHEAVY,
        G_DCROSS,
        G_DT_DOWN,
        G_DT_UP,
        G_DT_RIGHT,
        => true,
        else => false,
    } or ch == cp(icon.box_tl) or ch == cp(icon.box_bl) or
        ch == cp("╭") or ch == cp("╰") or
        ch == cp(icon.double_box_tl) or ch == cp(icon.double_box_bl);
}

fn isDoubleGlyph(ch: u21) bool {
    return switch (ch) {
        G_HHEAVY,
        G_VHEAVY,
        G_DCROSS,
        G_DT_DOWN,
        G_DT_UP,
        G_DT_RIGHT,
        G_DT_LEFT,
        => true,
        else => false,
    };
}

fn singleJunction(up: bool, down: bool, left: bool, right: bool) u21 {
    if (up and down and left and right) return G_CROSS;
    if (up and down and right) return G_T_RIGHT;
    if (up and down and left) return G_T_LEFT;
    if (left and right and down) return G_T_DOWN;
    if (left and right and up) return G_T_UP;
    if (up and down) return G_VDASH;
    if (left and right) return G_HDASH;
    if (up and right) return cp(icon.box_bl);
    if (up and left) return cp(icon.box_br);
    if (down and right) return cp(icon.box_tl);
    if (down and left) return cp(icon.box_tr);
    if (up or down) return G_VDASH;
    if (left or right) return G_HDASH;
    return ' ';
}

fn doubleJunction(up: bool, down: bool, left: bool, right: bool) u21 {
    if (up and down and left and right) return G_DCROSS;
    if (up and down and right) return G_DT_RIGHT;
    if (up and down and left) return G_DT_LEFT;
    if (left and right and down) return G_DT_DOWN;
    if (left and right and up) return G_DT_UP;
    if (up and down) return G_VHEAVY;
    if (left and right) return G_HHEAVY;
    if (up and right) return cp(icon.double_box_bl);
    if (up and left) return cp(icon.double_box_br);
    if (down and right) return cp(icon.double_box_tl);
    if (down and left) return cp(icon.double_box_tr);
    if (up or down) return G_VHEAVY;
    if (left or right) return G_HHEAVY;
    return ' ';
}

fn fixJunctions(c: *Canvas) void {
    for (0..c.h) |y| {
        for (0..c.w) |x| {
            const idx = y * c.w + x;
            const ch = c.cells[idx].ch;
            if (!isLineJoint(ch)) continue;
            const up = y > 0 and connectsDown(c.cells[(y - 1) * c.w + x].ch);
            const down = y + 1 < c.h and connectsUp(c.cells[(y + 1) * c.w + x].ch);
            const left = x > 0 and connectsRight(c.cells[y * c.w + x - 1].ch);
            const right = x + 1 < c.w and connectsLeft(c.cells[y * c.w + x + 1].ch);
            const connections = @as(u3, @intFromBool(up)) + @as(u3, @intFromBool(down)) + @as(u3, @intFromBool(left)) + @as(u3, @intFromBool(right));
            if (connections < 2) continue;
            c.cells[idx].ch = if (isDoubleGlyph(ch)) doubleJunction(up, down, left, right) else singleJunction(up, down, left, right);
        }
    }
}

fn canvasToLines(c: *const Canvas, alloc: std.mem.Allocator, limit_width: usize, out: *std.ArrayList(Line)) !void {
    const w = if (limit_width == 0) c.w else @min(c.w, limit_width);
    for (0..c.h) |y| {
        var line = Line{};
        errdefer line.deinit(alloc);
        var row_width = w;
        while (row_width > 0) {
            const cell_value = c.cells[y * c.w + row_width - 1];
            if (cell_value.ch != ' ' or !cell_value.style.eql(.{})) break;
            row_width -= 1;
        }
        var x: usize = 0;
        while (x < row_width) {
            const style = c.cells[y * c.w + x].style;
            var end = x;
            while (end < row_width and c.cells[y * c.w + end].style.eql(style)) end += 1;
            const run_len = end - x;
            const buf = try alloc.alloc(u8, std.math.mul(usize, run_len, 4) catch return error.DiagramTooLarge);
            defer alloc.free(buf);
            var n: usize = 0;
            for (x..end) |cx| {
                var tmp: [4]u8 = undefined;
                const ch = c.cells[y * c.w + cx].ch;
                const len = std.unicode.utf8Encode(ch, &tmp) catch 1;
                if (n + len > buf.len) break;
                @memcpy(buf[n..][0..len], tmp[0..len]);
                n += len;
            }
            try line.pushSpan(alloc, .{ .content = buf[0..n], .style = style });
            x = end;
        }
        try out.append(alloc, line);
    }
}

const Dir = enum { td, bt, lr, rl };
const Shape = enum { rect, rounded, compartmented };
const EdgeKind = enum { solid, dotted, thick, line };

const Node = struct {
    id: []const u8,
    label: []const u8,
    shape: Shape = .rect,
    width: usize = 0,
    height: usize = 3,
    lines: []const []const u8 = &.{},
    header_lines: usize = 0,
    layer: usize = 0,
    left: isize = 0,
    top: isize = 0,
    center_x: isize = 0,
    center_y: isize = 0,
};

const Edge = struct {
    from: usize,
    to: usize,
    kind: EdgeKind,
    label: ?[]const u8 = null,
    label_lines: []const []const u8 = &.{},
};

const NodeRef = struct {
    id: []const u8,
    label: []const u8,
    shape: Shape,
};

const ArrowHit = struct {
    pos: usize,
    len: usize,
    kind: EdgeKind,
};

const LabelSep = struct {
    pos: usize,
    len: usize,
};

fn renderFlowchart(alloc: std.mem.Allocator, output_alloc: std.mem.Allocator, src: []const u8, out: *std.ArrayList(Line), options: Options, force_shape: ?Shape) !void {
    const width = options.width;
    var nodes = std.ArrayList(Node).empty;
    defer nodes.deinit(alloc);
    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(alloc);
    var ids = std.StringHashMap(usize).init(alloc);
    defer ids.deinit();

    var dir: Dir = .td;
    var first = true;
    var in_subgraph = false;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (first) {
            dir = detectDir(line);
            first = false;
            continue;
        }
        if (std.ascii.indexOfIgnoreCase(line, "subgraph") == 0) {
            in_subgraph = true;
            continue;
        }
        if (in_subgraph) {
            if (std.ascii.indexOfIgnoreCase(line, "end") == 0) in_subgraph = false;
            continue;
        }
        try processGraphLine(alloc, line, &nodes, &edges, &ids);
    }

    if (nodes.items.len == 0) return renderFallback(output_alloc, src, out, options.theme.muted);
    if (force_shape) |shape| {
        for (nodes.items) |*node| node.shape = shape;
    }

    for (nodes.items) |*n| {
        const initial_lines = try wrapNodeText(alloc, n.label, @as(usize, @max(5, options.max_node_width)) -| 4, n.shape, null);
        n.width = @max(5, maxLineWidth(initial_lines) +| 4);
    }
    const edge_label_width = @max(1, @min(@as(usize, @max(5, options.max_node_width)), if (width > 4) width - 4 else 1));
    for (edges.items) |*edge| {
        if (edge.label) |label| edge.label_lines = try wrapText(alloc, label, edge_label_width);
    }

    const layout = try layoutFlow(alloc, nodes.items, edges.items, dir, width);
    const canvas_w = if (width == 0) layout.max_x else @as(usize, width);
    var c = try Canvas.init(alloc, canvas_w, layout.max_y, options);
    defer c.deinit();

    for (edges.items) |e| drawFlowEdgeLine(&c, e, nodes.items, dir, edgeStyle(&c, e.kind));
    for (edges.items) |e| drawFlowEdgeLabel(&c, e, nodes.items, dir);
    for (nodes.items) |*n| drawFlowNode(&c, n);
    fixJunctions(&c);
    for (edges.items) |e| drawFlowEdgeArrow(&c, e, nodes.items, dir, edgeStyle(&c, e.kind));

    try canvasToLines(&c, output_alloc, width, out);
}

fn detectDir(line: []const u8) Dir {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    _ = it.next() orelse return .td;
    const dir = it.next() orelse return .td;
    if (std.ascii.eqlIgnoreCase(dir, "TB") or std.ascii.eqlIgnoreCase(dir, "TD")) return .td;
    if (std.ascii.eqlIgnoreCase(dir, "BT")) return .bt;
    if (std.ascii.eqlIgnoreCase(dir, "LR")) return .lr;
    if (std.ascii.eqlIgnoreCase(dir, "RL")) return .rl;
    return .td;
}

fn processGraphLine(alloc: std.mem.Allocator, line: []const u8, nodes: *std.ArrayList(Node), edges: *std.ArrayList(Edge), ids: *std.StringHashMap(usize)) !void {
    var s = std.mem.trim(u8, line, " \t\r");
    while (s.len > 0) {
        const end = findStatementEnd(s);
        const stmt = std.mem.trim(u8, s[0..end], " \t\r");
        if (stmt.len > 0) try parseGraphStatement(alloc, stmt, nodes, edges, ids);
        if (end >= s.len) break;
        s = std.mem.trimStart(u8, s[end + 1 ..], " \t\r");
    }
}

fn findStatementEnd(s: []const u8) usize {
    var depth: usize = 0;
    var quote: ?u8 = null;
    for (s, 0..) |ch, i| {
        if (quote) |q| {
            if (ch == q) quote = null;
            continue;
        }
        switch (ch) {
            '"', '\'' => quote = ch,
            '[', '(', '{' => depth += 1,
            ']', ')', '}' => {
                if (depth > 0) depth -= 1;
            },
            ';' => if (depth == 0) return i,
            else => {},
        }
    }
    return s.len;
}

fn parseGraphStatement(alloc: std.mem.Allocator, stmt: []const u8, nodes: *std.ArrayList(Node), edges: *std.ArrayList(Edge), ids: *std.StringHashMap(usize)) !void {
    if (findArrow(stmt)) |arrow| {
        try parseEdge(alloc, stmt, arrow, nodes, edges, ids);
        return;
    }
    const ref = parseNodeRef(stmt);
    if (ref.id.len > 0) _ = try getOrAddNode(alloc, nodes, ids, ref.id, ref.label, ref.shape);
}

fn findArrow(s: []const u8) ?ArrowHit {
    const candidates = [_]struct { needle: []const u8, kind: EdgeKind }{
        .{ .needle = "-.->", .kind = .dotted },
        .{ .needle = "==>", .kind = .thick },
        .{ .needle = "-->", .kind = .solid },
        .{ .needle = "---", .kind = .line },
    };
    var best: ?ArrowHit = null;
    for (candidates) |cand| {
        if (std.mem.indexOf(u8, s, cand.needle)) |pos| {
            if (best == null or pos < best.?.pos) {
                best = .{ .pos = pos, .len = cand.needle.len, .kind = cand.kind };
            }
        }
    }
    return best;
}

fn parseEdge(alloc: std.mem.Allocator, stmt: []const u8, arrow: ArrowHit, nodes: *std.ArrayList(Node), edges: *std.ArrayList(Edge), ids: *std.StringHashMap(usize)) !void {
    var left = std.mem.trim(u8, stmt[0..arrow.pos], " \t");
    var right = std.mem.trim(u8, stmt[arrow.pos + arrow.len ..], " \t");
    var label: ?[]const u8 = null;

    if (findLabelSeparator(left)) |sep| {
        label = std.mem.trim(u8, left[sep.pos + sep.len ..], " \t");
        left = std.mem.trim(u8, left[0..sep.pos], " \t");
    }

    const lref = parseNodeRef(left);
    if (lref.id.len == 0) return;
    const from = try getOrAddNode(alloc, nodes, ids, lref.id, lref.label, lref.shape);

    if (right.len > 0 and right[0] == '|') {
        if (std.mem.indexOfScalarPos(u8, right, 1, '|')) |close| {
            if (label == null) label = std.mem.trim(u8, right[1..close], " \t");
            right = std.mem.trim(u8, right[close + 1 ..], " \t");
        }
    }

    if (findArrow(right)) |next| {
        const rref = parseNodeRef(right[0..next.pos]);
        if (rref.id.len == 0) return;
        const to = try getOrAddNode(alloc, nodes, ids, rref.id, rref.label, rref.shape);
        try edges.append(alloc, .{ .from = from, .to = to, .kind = arrow.kind, .label = label });
        try parseEdge(alloc, right, next, nodes, edges, ids);
        return;
    }

    if (std.mem.indexOfScalar(u8, right, '&')) |amp| {
        right = std.mem.trim(u8, right[0..amp], " \t");
    }

    const rref = parseNodeRef(right);
    if (rref.id.len == 0) return;
    const to = try getOrAddNode(alloc, nodes, ids, rref.id, rref.label, rref.shape);
    try edges.append(alloc, .{ .from = from, .to = to, .kind = arrow.kind, .label = label });
}

fn findLabelSeparator(s: []const u8) ?LabelSep {
    var best: ?LabelSep = null;
    const seps = [_][]const u8{ "--", "-." };
    for (seps) |sep| {
        if (std.mem.indexOf(u8, s, sep)) |pos| {
            if (best == null or pos < best.?.pos) best = .{ .pos = pos, .len = sep.len };
        }
    }
    return best;
}

fn parseNodeRef(s: []const u8) NodeRef {
    const t = std.mem.trim(u8, s, " \t\r");
    if (t.len == 0) return .{ .id = "", .label = "", .shape = .rect };

    var i: usize = 0;
    while (i < t.len and !isShapeOpen(t[i])) i += 1;
    const id = std.mem.trim(u8, t[0..i], " \t");
    if (id.len == 0) return .{ .id = "", .label = "", .shape = .rect };

    if (i >= t.len) return .{ .id = id, .label = id, .shape = .rect };

    switch (t[i]) {
        '[' => return .{ .id = id, .label = extractDelimited(t, i, '[', ']', id), .shape = .rect },
        '(' => {
            if (i + 1 < t.len and t[i + 1] == '(') {
                return .{ .id = id, .label = extractDelimited(t, i + 1, '(', ')', id), .shape = .rounded };
            }
            return .{ .id = id, .label = extractDelimited(t, i, '(', ')', id), .shape = .rounded };
        },
        '{' => return .{ .id = id, .label = extractDelimited(t, i, '{', '}', id), .shape = .rounded },
        '>' => return .{ .id = id, .label = extractDelimited(t, i, '>', ']', id), .shape = .rounded },
        '/' => return .{ .id = id, .label = extractDelimited(t, i, '/', '/', id), .shape = .rect },
        else => return .{ .id = id, .label = id, .shape = .rect },
    }
}

fn isShapeOpen(ch: u8) bool {
    return ch == '[' or ch == '(' or ch == '{' or ch == '>' or ch == '/';
}

fn extractDelimited(s: []const u8, open_idx: usize, open_c: u8, close_c: u8, fallback: []const u8) []const u8 {
    if (open_idx >= s.len) return fallback;
    var depth: usize = 0;
    const start = open_idx + 1;
    var i = open_idx;
    while (i < s.len) : (i += 1) {
        if (s[i] == open_c) {
            depth += 1;
        } else if (s[i] == close_c) {
            if (depth > 0) depth -= 1;
            if (depth == 0) {
                const label = std.mem.trim(u8, s[start..i], " \t");
                return if (label.len > 0) label else fallback;
            }
        }
    }
    return fallback;
}

fn getOrAddNode(alloc: std.mem.Allocator, nodes: *std.ArrayList(Node), ids: *std.StringHashMap(usize), id: []const u8, label: []const u8, shape: Shape) !usize {
    if (ids.get(id)) |idx| {
        const node = &nodes.items[idx];
        if (label.len > 0 and !std.mem.eql(u8, label, id)) node.label = label;
        if (node.shape == .rect and shape != .rect) node.shape = shape;
        return idx;
    }
    const idx = nodes.items.len;
    try ids.put(id, idx);
    try nodes.append(alloc, .{ .id = id, .label = if (label.len > 0) label else id, .shape = shape });
    return idx;
}

const Layout = struct {
    max_x: usize,
    max_y: usize,
};

const FLOW_CROSS_GAP: isize = 6;
const FLOW_MIN_CROSS_GAP: isize = 2;
const FLOW_MAIN_GAP: isize = 10;

fn crossPos(node: *const Node, vertical: bool) isize {
    return if (vertical) node.center_x else node.center_y;
}

fn crossExtent(node: *const Node, vertical: bool) isize {
    return @intCast(if (vertical) node.width else node.height);
}

fn setCross(node: *Node, vertical: bool, pos: isize, extent: isize) void {
    if (vertical) {
        node.left = pos;
        node.center_x = pos + @divTrunc(extent, 2);
    } else {
        node.top = pos;
        node.center_y = pos + @divTrunc(extent, 2);
    }
}

fn shiftCross(node: *Node, vertical: bool, delta: isize) void {
    if (vertical) {
        node.left += delta;
        node.center_x += delta;
    } else {
        node.top += delta;
        node.center_y += delta;
    }
}

fn predAverage(nodes: []const Node, edges: []const Edge, idx: usize, vertical: bool) ?isize {
    var sum: isize = 0;
    var count: usize = 0;
    for (edges) |e| {
        if (e.to == idx and nodes[e.from].layer < nodes[idx].layer) {
            sum += crossPos(&nodes[e.from], vertical);
            count += 1;
        }
    }
    if (count == 0) return null;
    return @divTrunc(sum, @as(isize, @intCast(count)));
}

fn assignCrossPositions(alloc: std.mem.Allocator, nodes: []Node, edges: []const Edge, layer_nodes: []std.ArrayList(usize), vertical: bool, available: isize) !void {
    const n = nodes.len;
    const desired = try alloc.alloc(isize, n);
    defer alloc.free(desired);

    const SortCtx = struct {
        desired: []const isize,
        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            if (ctx.desired[a] != ctx.desired[b]) return ctx.desired[a] < ctx.desired[b];
            return a < b;
        }
    };

    for (layer_nodes, 0..) |*list, L| {
        if (list.items.len == 0) continue;
        var anchor_sum: isize = 0;
        var anchor_count: usize = 0;
        for (list.items) |idx| {
            if (L == 0) {
                desired[idx] = @as(isize, @intCast(idx)) * 1000;
            } else if (predAverage(nodes, edges, idx, vertical)) |avg| {
                desired[idx] = avg;
                anchor_sum += avg;
                anchor_count += 1;
            } else {
                desired[idx] = std.math.maxInt(isize) / 2 + @as(isize, @intCast(idx));
            }
        }

        std.mem.sort(usize, list.items, SortCtx{ .desired = desired }, SortCtx.lessThan);

        var extents: isize = 0;
        for (list.items) |idx| extents += crossExtent(&nodes[idx], vertical);
        const gaps: isize = @intCast(list.items.len - 1);
        const gap = if (gaps == 0)
            FLOW_CROSS_GAP
        else
            @max(FLOW_MIN_CROSS_GAP, @min(FLOW_CROSS_GAP, @divTrunc(available - extents, gaps)));
        var total: isize = 0;
        for (list.items) |idx| total += crossExtent(&nodes[idx], vertical);
        total += gaps * gap;

        var start: isize = 2;
        if (L != 0 and anchor_count > 0) {
            const mean = @divTrunc(anchor_sum, @as(isize, @intCast(anchor_count)));
            start = mean - @divTrunc(total, 2);
        }

        var pos = start;
        for (list.items) |idx| {
            const ext = crossExtent(&nodes[idx], vertical);
            setCross(&nodes[idx], vertical, pos, ext);
            pos += ext + gap;
        }
    }
}

fn layoutFlow(alloc: std.mem.Allocator, nodes: []Node, edges: []const Edge, dir: Dir, width: u16) !Layout {
    const n = nodes.len;
    const indegree = try alloc.alloc(usize, n);
    defer alloc.free(indegree);
    @memset(indegree, 0);
    for (edges) |e| indegree[e.to] += 1;

    var queue = std.ArrayList(usize).empty;
    defer queue.deinit(alloc);
    var topo = std.ArrayList(usize).empty;
    defer topo.deinit(alloc);
    for (0..n) |i| if (indegree[i] == 0) try queue.append(alloc, i);

    while (queue.pop()) |u| {
        try topo.append(alloc, u);
        for (edges) |e| {
            if (e.from == u) {
                indegree[e.to] -= 1;
                if (indegree[e.to] == 0) try queue.append(alloc, e.to);
            }
        }
    }

    if (topo.items.len == n) {
        const layers = try alloc.alloc(usize, n);
        defer alloc.free(layers);
        @memset(layers, 0);
        for (topo.items) |u| {
            for (edges) |e| {
                if (e.from == u and layers[e.to] < layers[u] + 1) layers[e.to] = layers[u] + 1;
            }
        }
        for (nodes, 0..) |*node, i| node.layer = layers[i];
    } else {
        for (nodes, 0..) |*node, i| node.layer = i;
    }

    var max_layer: usize = 0;
    for (nodes) |node| max_layer = @max(max_layer, node.layer);
    const vertical = dir == .td or dir == .bt;
    var main_gap = FLOW_MAIN_GAP;
    if (!vertical and max_layer > 0) {
        for (edges) |edge| {
            if (edge.label_lines.len > 0) main_gap = @max(main_gap, @as(isize, @intCast(maxLineWidth(edge.label_lines) + 4)));
        }
        const min_nodes = (max_layer + 1) * 5 + 4;
        const max_gap = if (width > min_nodes) (width - min_nodes) / max_layer else 2;
        main_gap = @min(main_gap, @max(2, @as(isize, @intCast(max_gap))));
    }

    const layer_nodes = try alloc.alloc(std.ArrayList(usize), max_layer + 1);
    defer {
        for (layer_nodes) |*l| l.deinit(alloc);
        alloc.free(layer_nodes);
    }
    for (layer_nodes) |*l| l.* = .empty;
    for (nodes, 0..) |node, i| try layer_nodes[node.layer].append(alloc, i);

    if (vertical) {
        const available: usize = if (width > 4) width - 4 else 1;
        for (layer_nodes) |list| {
            if (list.items.len < 2) continue;
            var total: usize = (list.items.len - 1) * @as(usize, @intCast(FLOW_MIN_CROSS_GAP));
            for (list.items) |idx| total += nodes[idx].width;
            if (total > available) {
                const gap_total = (list.items.len - 1) * @as(usize, @intCast(FLOW_MIN_CROSS_GAP));
                const share = @max(5, if (available > gap_total) (available - gap_total) / list.items.len else 5);
                for (list.items) |idx| nodes[idx].width = @min(nodes[idx].width, share);
            }
        }
    }

    const layer_widths = try alloc.alloc(usize, max_layer + 1);
    defer alloc.free(layer_widths);
    @memset(layer_widths, 0);
    for (nodes) |node| layer_widths[node.layer] = @max(layer_widths[node.layer], node.width);
    if (!vertical) {
        const gaps = max_layer * @as(usize, @intCast(main_gap));
        const available: usize = if (width > gaps + 4) width - gaps - 4 else 5 * (max_layer + 1);
        var total: usize = gaps;
        for (layer_widths) |layer_width| total += layer_width;
        if (total + 4 > width) {
            const share = @max(5, available / (max_layer + 1));
            for (nodes) |*node| node.width = @min(node.width, share);
            @memset(layer_widths, 0);
            for (nodes) |node| layer_widths[node.layer] = @max(layer_widths[node.layer], node.width);
        }
    }

    const layer_heights = try alloc.alloc(usize, max_layer + 1);
    defer alloc.free(layer_heights);
    @memset(layer_heights, 0);
    for (nodes) |*node| {
        node.lines = try wrapNodeText(alloc, node.label, node.width -| 4, node.shape, &node.header_lines);
        const separator: usize = @intFromBool(node.shape == .compartmented and node.lines.len > node.header_lines);
        node.height = @max(3, node.lines.len + 2 + separator);
        layer_heights[node.layer] = @max(layer_heights[node.layer], node.height);
    }

    if (vertical) {
        var layer_gap: usize = 4;
        for (edges) |edge| layer_gap = @max(layer_gap, edge.label_lines.len + 2);
        var layer_axis: isize = 2;
        for (layer_nodes, 0..) |*list, layer| {
            if (list.items.len == 0) continue;
            if (layer > 0) layer_axis += @as(isize, @intCast(layer_heights[layer - 1] + layer_gap));
            for (list.items) |idx| {
                const node = &nodes[idx];
                node.top = layer_axis;
                node.center_y = node.top + @as(isize, @intCast(node.height / 2));
            }
        }
    } else {
        var layer_axis: isize = 2;
        for (layer_nodes, 0..) |*list, L| {
            if (list.items.len == 0) continue;
            if (L > 0) layer_axis += @as(isize, @intCast(layer_widths[L - 1])) + main_gap;
            const mw = layer_widths[L];
            for (list.items) |idx| {
                const node = &nodes[idx];
                node.center_x = layer_axis + @as(isize, @intCast(mw / 2));
                node.left = node.center_x - @as(isize, @intCast(node.width / 2));
            }
        }
    }

    const available = @max(1, @as(isize, @intCast(width)) - 4);
    try assignCrossPositions(alloc, nodes, edges, layer_nodes, vertical, available);

    var min_cross: isize = 0;
    for (nodes) |*node| {
        min_cross = @min(min_cross, if (vertical) node.left else node.top);
    }
    if (min_cross < 2) {
        const delta = 2 - min_cross;
        for (nodes) |*node| shiftCross(node, vertical, delta);
    }

    if (vertical) {
        var right: isize = 0;
        for (nodes) |node| right = @max(right, nodeRight(&node));
        const used = right + 3;
        const target: isize = @intCast(width);
        if (used < target) {
            const delta = @divTrunc(target - used, 2);
            for (nodes) |*node| shiftCross(node, true, delta);
        }
    }

    var max_x: isize = 2;
    var max_y: isize = 2;
    for (nodes) |node| {
        max_x = @max(max_x, node.left + @as(isize, @intCast(node.width)) + 2);
        max_y = @max(max_y, node.top + @as(isize, @intCast(node.height)) + 2);
    }
    return .{ .max_x = @intCast(max_x), .max_y = @intCast(max_y) };
}

fn edgeStyle(c: *const Canvas, kind: EdgeKind) Style {
    return switch (kind) {
        .solid => c.theme.edge,
        .dotted => c.theme.muted,
        .thick => c.theme.edge,
        .line => c.theme.edge,
    };
}

fn edgeGlyphs(kind: EdgeKind) struct { h: u21, v: u21 } {
    return switch (kind) {
        .solid, .line => .{ .h = G_HDASH, .v = G_VDASH },
        .dotted => .{ .h = G_DOTTED_H, .v = G_DOTTED_V },
        .thick => .{ .h = G_HHEAVY, .v = G_VHEAVY },
    };
}

fn nodeRight(n: *const Node) isize {
    return n.left + @as(isize, @intCast(n.width)) - 1;
}

fn nodeBottom(n: *const Node) isize {
    return n.top + @as(isize, @intCast(n.height)) - 1;
}

fn nodeTop(n: *const Node) isize {
    return n.top;
}

fn nodeLeft(n: *const Node) isize {
    return n.left;
}

fn edgeBend(s: *const Node, t: *const Node, vertical: bool) isize {
    if (vertical) return if (t.layer > s.layer) nodeBottom(s) + 2 else nodeTop(s) - 2;
    return if (t.layer > s.layer) nodeRight(s) + 2 else nodeLeft(s) - 2;
}

fn drawFlowEdgeLine(c: *Canvas, e: Edge, nodes: []const Node, dir: Dir, style: Style) void {
    const s = &nodes[e.from];
    const t = &nodes[e.to];
    const g = edgeGlyphs(e.kind);
    const vertical = dir == .td or dir == .bt;

    if (e.from == e.to) {
        drawHLine(c, nodeLeft(s) - 3, nodeLeft(s) - 2, s.center_y, g.h, style);
        return;
    }

    if (vertical) {
        if (t.layer == s.layer) {
            if (t.center_x > s.center_x) {
                drawHLine(c, nodeRight(s), nodeLeft(t) - 1, s.center_y, g.h, style);
            } else if (t.center_x < s.center_x) {
                drawHLine(c, nodeRight(t), nodeLeft(s) - 1, s.center_y, g.h, style);
            }
        } else if (t.layer > s.layer) {
            const ymid = edgeBend(s, t, true);
            drawVLine(c, s.center_x, nodeBottom(s), ymid, g.v, style);
            drawHLine(c, s.center_x, t.center_x, ymid, g.h, style);
            drawVLine(c, t.center_x, ymid, nodeTop(t) - 1, g.v, style);
        } else {
            const ymid = edgeBend(s, t, true);
            drawVLine(c, s.center_x, ymid, nodeTop(s), g.v, style);
            drawHLine(c, s.center_x, t.center_x, ymid, g.h, style);
            drawVLine(c, t.center_x, nodeBottom(t) + 1, ymid, g.v, style);
        }
    } else {
        if (t.layer == s.layer) {
            if (t.center_y > s.center_y) {
                drawVLine(c, s.center_x, nodeBottom(s), nodeTop(t) - 1, g.v, style);
            } else if (t.center_y < s.center_y) {
                drawVLine(c, s.center_x, nodeBottom(t), nodeTop(s) - 1, g.v, style);
            }
        } else if (t.layer > s.layer) {
            const xmid = edgeBend(s, t, false);
            drawHLine(c, nodeRight(s), xmid, s.center_y, g.h, style);
            drawVLine(c, xmid, s.center_y, t.center_y, g.v, style);
            drawHLine(c, xmid, nodeLeft(t) - 1, t.center_y, g.h, style);
        } else {
            const xmid = edgeBend(s, t, false);
            drawHLine(c, xmid, nodeLeft(s), s.center_y, g.h, style);
            drawVLine(c, xmid, s.center_y, t.center_y, g.v, style);
            drawHLine(c, nodeRight(t) + 1, xmid, t.center_y, g.h, style);
        }
    }
}

fn drawFlowEdgeArrow(c: *Canvas, e: Edge, nodes: []const Node, dir: Dir, style: Style) void {
    if (e.kind == .line) return;
    const s = &nodes[e.from];
    const t = &nodes[e.to];
    const vertical = dir == .td or dir == .bt;

    if (e.from == e.to) {
        c.put(nodeLeft(s) - 1, s.center_y, G_ARROW_R, style);
        return;
    }

    if (vertical) {
        if (t.layer == s.layer) {
            if (t.center_x > s.center_x) {
                c.put(nodeLeft(t) - 1, t.center_y, G_ARROW_R, style);
            } else if (t.center_x < s.center_x) {
                c.put(nodeRight(t) + 1, t.center_y, G_ARROW_L, style);
            }
        } else if (t.layer > s.layer) {
            c.put(t.center_x, nodeTop(t) - 1, G_ARROW_D, style);
        } else {
            c.put(t.center_x, nodeBottom(t) + 1, G_ARROW_U, style);
        }
    } else {
        if (t.layer == s.layer) {
            if (t.center_y > s.center_y) {
                c.put(t.center_x, nodeTop(t) - 1, G_ARROW_D, style);
            } else if (t.center_y < s.center_y) {
                c.put(t.center_x, nodeBottom(t) + 1, G_ARROW_U, style);
            }
        } else if (t.layer > s.layer) {
            c.put(nodeLeft(t) - 1, t.center_y, G_ARROW_R, style);
        } else {
            c.put(nodeRight(t) + 1, t.center_y, G_ARROW_L, style);
        }
    }
}

fn drawFlowEdgeLabel(c: *Canvas, e: Edge, nodes: []const Node, dir: Dir) void {
    const lines = e.label_lines;
    if (lines.len == 0) return;
    const s = &nodes[e.from];
    const t = &nodes[e.to];
    const vertical = dir == .td or dir == .bt;
    const g = edgeGlyphs(e.kind);
    const line_style = edgeStyle(c, e.kind);
    const width: isize = @intCast(maxLineWidth(lines));

    if (e.from == e.to) {
        putTextLines(c, nodeLeft(s) - 4 - width, s.center_y, lines, c.theme.accent);
        return;
    }

    if (vertical) {
        if (t.layer == s.layer) {
            const mid = @divTrunc(s.center_x + t.center_x, 2);
            const x = mid - @divTrunc(width, 2);
            putTextPaddedH(c, x, s.center_y, lines[0], c.theme.accent, g.h, line_style);
            if (lines.len > 1) putTextLines(c, x, s.center_y + 1, lines[1..], c.theme.accent);
        } else if (t.layer > s.layer) {
            const x = if (t.center_x < s.center_x) t.center_x - width - 1 else t.center_x + 2;
            putTextLines(c, x, nodeBottom(s) + 2, lines, c.theme.accent);
        } else {
            const x = if (t.center_x < s.center_x) t.center_x - width - 1 else t.center_x + 2;
            putTextLines(c, x, nodeTop(s) - 1 - @as(isize, @intCast(lines.len)), lines, c.theme.accent);
        }
    } else {
        if (t.layer == s.layer) {
            const mid = @divTrunc(s.center_y + t.center_y, 2);
            const y = mid - @divTrunc(@as(isize, @intCast(lines.len)), 2);
            putTextLines(c, s.center_x + 1, y, lines, c.theme.accent);
        } else if (t.layer > s.layer) {
            const x = edgeBend(s, t, false) + 2;
            putTextPaddedH(c, x, t.center_y, lines[0], c.theme.accent, g.h, line_style);
            if (lines.len > 1) putTextLines(c, x, t.center_y + 1, lines[1..], c.theme.accent);
        } else {
            const x = edgeBend(s, t, false) - width - 1;
            putTextPaddedH(c, x, t.center_y, lines[0], c.theme.accent, g.h, line_style);
            if (lines.len > 1) putTextLines(c, x, t.center_y + 1, lines[1..], c.theme.accent);
        }
    }
}

fn drawFlowNode(c: *Canvas, n: *const Node) void {
    const w: isize = @intCast(n.width);
    const left = n.left;
    const top = n.top;
    const right = left + w - 1;
    const bottom = top + @as(isize, @intCast(n.height)) - 1;

    const Corners = struct { tl: u21, tr: u21, bl: u21, br: u21 };
    const corners: Corners = switch (n.shape) {
        .rounded => .{ .tl = cp("╭"), .tr = cp("╮"), .bl = cp("╰"), .br = cp("╯") },
        .rect, .compartmented => .{ .tl = cp("┌"), .tr = cp("┐"), .bl = cp("└"), .br = cp("┘") },
    };

    c.put(left, top, corners.tl, c.theme.border);
    c.put(right, top, corners.tr, c.theme.border);
    drawHLine(c, left + 1, right - 1, top, G_HDASH, c.theme.border);
    c.put(left, bottom, corners.bl, c.theme.border);
    c.put(right, bottom, corners.br, c.theme.border);
    drawHLine(c, left + 1, right - 1, bottom, G_HDASH, c.theme.border);
    var row = top + 1;
    while (row < bottom) : (row += 1) {
        c.put(left, row, G_VDASH, c.theme.border);
        c.put(right, row, G_VDASH, c.theme.border);
    }

    const separated = n.shape == .compartmented and n.lines.len > n.header_lines;
    if (separated) {
        const separator_y = top + 1 + @as(isize, @intCast(n.header_lines));
        c.put(left, separator_y, G_T_RIGHT, c.theme.border);
        c.put(right, separator_y, G_T_LEFT, c.theme.border);
        drawHLine(c, left + 1, right - 1, separator_y, G_HDASH, c.theme.border);
    }

    const inner = w - 4;
    for (n.lines, 0..) |text, index| {
        const tw = @min(@as(isize, @intCast(widthOf(text))), inner);
        const header = n.shape != .compartmented or index < n.header_lines;
        const x = if (header) left + 2 + @divTrunc(inner - tw, 2) else left + 2;
        const y = top + 1 + @as(isize, @intCast(index)) + @intFromBool(separated and !header);
        if (tw > 0) putText(c, x, y, text, tw, if (header) c.theme.strong else c.theme.text);
    }
}

const SeqParticipant = struct {
    id: []const u8,
    label: []const u8,
};

const SeqMsgKind = enum { solid_filled, solid_open, dashed_filled, dashed_open };

const SeqMsg = struct {
    from: usize,
    to: usize,
    kind: SeqMsgKind,
    label: []const u8,
    height: usize = 3,
    lines: []const []const u8 = &.{},
};

const SeqNoteKind = enum { over, left, right };

const SeqNote = struct {
    kind: SeqNoteKind,
    a: usize,
    b: usize,
    label: []const u8,
    width: usize = 5,
    height: usize = 3,
    lines: []const []const u8 = &.{},
};

const SeqItem = union(enum) {
    msg: SeqMsg,
    note: SeqNote,
};

const SeqArrow = struct {
    pos: usize,
    len: usize,
    kind: SeqMsgKind,
};

fn renderSequence(alloc: std.mem.Allocator, output_alloc: std.mem.Allocator, src: []const u8, out: *std.ArrayList(Line), options: Options) !void {
    const width = options.width;
    var parts = std.ArrayList(SeqParticipant).empty;
    defer parts.deinit(alloc);
    var items = std.ArrayList(SeqItem).empty;
    defer items.deinit(alloc);
    var ids = std.StringHashMap(usize).init(alloc);
    defer ids.deinit();

    var first = true;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (first) {
            first = false;
            continue;
        }
        if (line.len > 0 and line[line.len - 1] == ';') line = std.mem.trimEnd(u8, line[0 .. line.len - 1], " \t");
        if (startsWithWord(line, "participant")) {
            try parseSeqParticipant(alloc, std.mem.trim(u8, line["participant".len..], " \t"), &parts, &ids);
        } else if (startsWithWord(line, "actor")) {
            try parseSeqParticipant(alloc, std.mem.trim(u8, line["actor".len..], " \t"), &parts, &ids);
        } else if (std.mem.startsWith(u8, line, "Note ")) {
            try parseSeqNote(alloc, line, &parts, &ids, &items);
        } else {
            try parseSeqMessage(alloc, line, &parts, &ids, &items);
        }
    }

    if (parts.items.len == 0) return renderFallback(output_alloc, src, out, options.theme.muted);

    for (parts.items) |*p| {
        if (p.label.len == 0) p.label = p.id;
    }
    const n = parts.items.len;

    const col_widths = try alloc.alloc(isize, n);
    defer alloc.free(col_widths);
    var header_total: isize = 0;
    for (parts.items, 0..) |p, i| {
        const initial_lines = try wrapText(alloc, p.label, @as(usize, @max(5, options.max_node_width)) -| 4);
        col_widths[i] = @intCast(@max(5, maxLineWidth(initial_lines) +| 4));
        header_total += col_widths[i];
    }
    const gap_count: isize = @intCast(n - 1);
    const usable = @max(1, @as(isize, @intCast(width)) - 4);
    if (header_total + gap_count * 3 > usable) {
        const share = @max(5, @divTrunc(usable - gap_count * 3, @as(isize, @intCast(n))));
        header_total = 0;
        for (col_widths) |*col_width| {
            col_width.* = @min(col_width.*, share);
            header_total += col_width.*;
        }
    }
    const col_gap: isize = if (gap_count == 0) 0 else @max(3, @min(16, @divTrunc(usable - header_total, gap_count)));
    const diagram_width = header_total + gap_count * col_gap;
    const start_x: isize = @max(2, @divTrunc(@as(isize, @intCast(width)) - diagram_width, 2));

    const centers = try alloc.alloc(isize, n);
    defer alloc.free(centers);
    const header_lines = try alloc.alloc([]const []const u8, n);
    defer alloc.free(header_lines);
    var header_height: usize = 3;
    var next_x = start_x;
    for (0..n) |i| {
        centers[i] = next_x + @divTrunc(col_widths[i], 2);
        header_lines[i] = try wrapText(alloc, parts.items[i].label, @intCast(@max(1, col_widths[i] - 4)));
        header_height = @max(header_height, header_lines[i].len + 2);
        next_x += col_widths[i] + col_gap;
    }

    var canvas_w: isize = @max(@as(isize, @intCast(width)), next_x + 2);
    var item_height: usize = 0;
    for (items.items) |*item| switch (item.*) {
        .note => |*nt| {
            const initial_lines = try wrapText(alloc, nt.label, @as(usize, @max(5, options.max_node_width)) -| 4);
            nt.width = @max(5, maxLineWidth(initial_lines) +| 4);
            if (width > 0 and nt.kind != .over) {
                const anchor: usize = @intCast(@max(0, centers[nt.a]));
                const available = if (nt.kind == .right) @as(usize, width) -| (anchor +| 2) else anchor -| 2;
                nt.width = @min(nt.width, @max(5, available));
            }
            const inner_width = switch (nt.kind) {
                .over => blk: {
                    const left_index = @min(nt.a, nt.b);
                    const right_index = @max(nt.a, nt.b);
                    const left = centers[left_index] - @divTrunc(col_widths[left_index], 2);
                    const right = centers[right_index] + @divTrunc(col_widths[right_index], 2);
                    break :blk @as(usize, @intCast(@max(1, right - left - 3)));
                },
                .left, .right => nt.width -| 4,
            };
            nt.lines = try wrapText(alloc, nt.label, inner_width);
            nt.height = @max(3, nt.lines.len + 2);
            item_height = std.math.add(usize, item_height, nt.height) catch return error.DiagramTooLarge;
            const r = switch (nt.kind) {
                .over => blk: {
                    const right_index = @max(nt.a, nt.b);
                    break :blk centers[right_index] + @divTrunc(col_widths[right_index], 2);
                },
                .right => centers[nt.a] + @as(isize, @intCast(nt.width)) + 3,
                .left => centers[nt.a],
            };
            canvas_w = @max(canvas_w, r + 2);
        },
        .msg => |*msg| {
            const span = if (msg.from == msg.to)
                @as(usize, @max(5, options.max_node_width))
            else
                @max(1, @as(usize, @intCast(@abs(centers[msg.to] - centers[msg.from]))) -| 4);
            msg.lines = try wrapText(alloc, msg.label, span);
            msg.height = @max(3, msg.lines.len + 2);
            item_height = std.math.add(usize, item_height, msg.height) catch return error.DiagramTooLarge;
        },
    };
    const canvas_h = std.math.add(usize, header_height + 2, item_height) catch return error.DiagramTooLarge;
    if (width > 0) canvas_w = @min(canvas_w, width);
    var c = try Canvas.init(alloc, @intCast(canvas_w), canvas_h, options);
    defer c.deinit();

    for (0..n) |i| drawVLine(&c, centers[i], @intCast(header_height), @as(isize, @intCast(canvas_h)) - 1, G_VDASH, c.theme.muted);

    for (parts.items, 0..) |*p, i| {
        _ = p;
        const left = centers[i] - @divTrunc(col_widths[i], 2);
        drawSeqHeader(&c, left, 0, col_widths[i], @intCast(header_height), header_lines[i]);
    }

    var y: isize = @intCast(header_height + 1);
    for (items.items) |item| {
        switch (item) {
            .msg => |m| {
                drawSeqMessage(&c, centers, m, y);
                y += @intCast(m.height);
            },
            .note => |nt| {
                drawSeqNote(&c, centers, col_widths, nt, y);
                y += @intCast(nt.height);
            },
        }
    }

    fixJunctions(&c);
    try canvasToLines(&c, output_alloc, width, out);
}

fn startsWithWord(line: []const u8, word: []const u8) bool {
    if (!std.mem.startsWith(u8, line, word)) return false;
    if (line.len == word.len) return true;
    return line[word.len] == ' ' or line[word.len] == '\t';
}

fn parseSeqParticipant(alloc: std.mem.Allocator, rest: []const u8, parts: *std.ArrayList(SeqParticipant), ids: *std.StringHashMap(usize)) !void {
    var id: []const u8 = rest;
    var label: []const u8 = rest;
    if (std.mem.indexOf(u8, rest, " as ")) |pos| {
        id = std.mem.trim(u8, rest[0..pos], " \t");
        label = std.mem.trim(u8, rest[pos + 4 ..], " \t");
    }
    _ = try getOrAddSeqParticipant(alloc, parts, ids, id, label);
}

fn getOrAddSeqParticipant(alloc: std.mem.Allocator, parts: *std.ArrayList(SeqParticipant), ids: *std.StringHashMap(usize), id: []const u8, label: []const u8) !usize {
    if (ids.get(id)) |idx| {
        if (parts.items[idx].label.len == 0 and label.len > 0) parts.items[idx].label = label;
        return idx;
    }
    const idx = parts.items.len;
    try ids.put(id, idx);
    try parts.append(alloc, .{ .id = id, .label = if (label.len > 0) label else id });
    return idx;
}

fn parseSeqMessage(alloc: std.mem.Allocator, line: []const u8, parts: *std.ArrayList(SeqParticipant), ids: *std.StringHashMap(usize), items: *std.ArrayList(SeqItem)) !void {
    const arrow = findSeqArrow(line) orelse return;
    const left = std.mem.trim(u8, line[0..arrow.pos], " \t");
    var right = std.mem.trim(u8, line[arrow.pos + arrow.len ..], " \t");
    var label: []const u8 = "";
    if (std.mem.indexOfScalar(u8, right, ':')) |ci| {
        label = std.mem.trim(u8, right[ci + 1 ..], " \t");
        right = std.mem.trim(u8, right[0..ci], " \t");
    }
    if (left.len == 0 or right.len == 0) return;
    const from = try getOrAddSeqParticipant(alloc, parts, ids, left, left);
    const to = try getOrAddSeqParticipant(alloc, parts, ids, right, right);
    try items.append(alloc, .{ .msg = .{ .from = from, .to = to, .kind = arrow.kind, .label = label } });
}

fn findSeqArrow(s: []const u8) ?SeqArrow {
    const candidates = [_]struct { needle: []const u8, kind: SeqMsgKind }{
        .{ .needle = "-->>", .kind = .dashed_filled },
        .{ .needle = "->>", .kind = .solid_filled },
        .{ .needle = "-->", .kind = .dashed_open },
        .{ .needle = "->", .kind = .solid_open },
    };
    var best: ?SeqArrow = null;
    for (candidates) |cand| {
        if (std.mem.indexOf(u8, s, cand.needle)) |pos| {
            if (best == null or pos < best.?.pos) {
                best = .{ .pos = pos, .len = cand.needle.len, .kind = cand.kind };
            }
        }
    }
    return best;
}

fn parseSeqNote(alloc: std.mem.Allocator, line: []const u8, parts: *std.ArrayList(SeqParticipant), ids: *std.StringHashMap(usize), items: *std.ArrayList(SeqItem)) !void {
    if (std.mem.startsWith(u8, line, "Note over ")) {
        const rest = line["Note over ".len..];
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
        const plist = std.mem.trim(u8, rest[0..colon], " \t");
        const label = std.mem.trim(u8, rest[@min(colon + 1, rest.len)..], " \t");
        var it = std.mem.splitScalar(u8, plist, ',');
        var idxs = std.ArrayList(usize).empty;
        defer idxs.deinit(alloc);
        while (it.next()) |p| {
            const id = std.mem.trim(u8, p, " \t");
            if (id.len == 0) continue;
            try idxs.append(alloc, try getOrAddSeqParticipant(alloc, parts, ids, id, id));
        }
        if (idxs.items.len == 0) return;
        const a = idxs.items[0];
        const b = idxs.items[idxs.items.len - 1];
        try items.append(alloc, .{ .note = .{ .kind = .over, .a = a, .b = b, .label = label } });
        return;
    }

    if (std.mem.startsWith(u8, line, "Note left of ") or std.mem.startsWith(u8, line, "Note right of ")) {
        const kind: SeqNoteKind = if (std.mem.startsWith(u8, line, "Note left of ")) .left else .right;
        const prefix = if (kind == .left) "Note left of " else "Note right of ";
        const rest = line[prefix.len..];
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
        const id = std.mem.trim(u8, rest[0..colon], " \t");
        const label = std.mem.trim(u8, rest[@min(colon + 1, rest.len)..], " \t");
        if (id.len == 0) return;
        const idx = try getOrAddSeqParticipant(alloc, parts, ids, id, id);
        try items.append(alloc, .{ .note = .{ .kind = kind, .a = idx, .b = idx, .label = label } });
    }
}

fn drawSeqHeader(c: *Canvas, left: isize, top: isize, width: isize, height: isize, lines: []const []const u8) void {
    const right = left + width - 1;
    const bottom = top + height - 1;
    c.put(left, top, cp("┌"), c.theme.border);
    c.put(right, top, cp("┐"), c.theme.border);
    drawHLine(c, left + 1, right - 1, top, G_HDASH, c.theme.border);
    c.put(left, bottom, cp("└"), c.theme.border);
    c.put(right, bottom, cp("┘"), c.theme.border);
    drawHLine(c, left + 1, right - 1, bottom, G_HDASH, c.theme.border);
    var row = top + 1;
    while (row < bottom) : (row += 1) {
        c.put(left, row, G_VDASH, c.theme.border);
        c.put(right, row, G_VDASH, c.theme.border);
    }
    const inner = width - 4;
    for (lines, 0..) |line, index| {
        const tw = @min(@as(isize, @intCast(widthOf(line))), inner);
        if (tw > 0) putText(c, left + 2 + @divTrunc(inner - tw, 2), top + 1 + @as(isize, @intCast(index)), line, tw, c.theme.strong);
    }
}

fn drawSeqMessage(c: *Canvas, centers: []const isize, m: SeqMsg, y: isize) void {
    const sx = centers[m.from];
    const tx = centers[m.to];
    const line_y = y + @as(isize, @intCast(@max(1, m.lines.len)));
    const filled = m.kind == .solid_filled or m.kind == .dashed_filled;
    const line_ch: u21 = if (m.kind == .dashed_filled or m.kind == .dashed_open) G_DOTTED_H else G_HDASH;
    const arrow_ch: u21 = if (filled) (if (sx < tx) G_ARROW_R else G_ARROW_L) else (if (sx < tx) '>' else '<');

    if (m.from == m.to) {
        drawHLine(c, sx - 3, sx - 1, line_y, line_ch, c.theme.edge);
        c.put(sx, line_y, if (filled) G_ARROW_R else '>', c.theme.strong);
        putTextLines(c, sx + 2, y, m.lines, c.theme.text);
        return;
    }

    const left = @min(sx, tx);
    const right = @max(sx, tx);
    if (sx < tx) {
        drawHLine(c, left, right - 2, line_y, line_ch, c.theme.edge);
        c.put(right - 1, line_y, arrow_ch, c.theme.strong);
    } else {
        drawHLine(c, left + 2, right, line_y, line_ch, c.theme.edge);
        c.put(left + 1, line_y, arrow_ch, c.theme.strong);
    }
    if (m.lines.len > 0) {
        const mid = @divTrunc(sx + tx, 2);
        const space = @max(0, right - left - 4);
        for (m.lines, 0..) |line, index| {
            const w = @min(@as(isize, @intCast(widthOf(line))), space);
            putText(c, mid - @divTrunc(w, 2), y + @as(isize, @intCast(index)), line, w, c.theme.text);
        }
    }
}

fn drawSeqNote(c: *Canvas, centers: []const isize, col_widths: []const isize, nt: SeqNote, y: isize) void {
    var l: isize = 0;
    var r: isize = 0;
    switch (nt.kind) {
        .over => {
            const left_index = @min(nt.a, nt.b);
            const right_index = @max(nt.a, nt.b);
            l = centers[left_index] - @divTrunc(col_widths[left_index], 2);
            r = centers[right_index] + @divTrunc(col_widths[right_index], 2);
        },
        .left => {
            const note_width: isize = @intCast(nt.width);
            l = centers[nt.a] - note_width - 2;
            r = centers[nt.a] - 2;
        },
        .right => {
            l = centers[nt.a] + 2;
            r = l + @as(isize, @intCast(nt.width)) - 1;
        },
    }
    if (l < 0) l = 0;
    if (r >= @as(isize, @intCast(c.w))) r = @as(isize, @intCast(c.w)) - 1;
    if (r <= l) return;
    c.put(l, y, cp("╭"), c.theme.border);
    c.put(r, y, cp("╮"), c.theme.border);
    drawHLine(c, l + 1, r - 1, y, G_HDASH, c.theme.border);
    const bottom = y + @as(isize, @intCast(nt.height)) - 1;
    var row = y + 1;
    while (row < bottom) : (row += 1) {
        c.put(l, row, G_VDASH, c.theme.border);
        c.put(r, row, G_VDASH, c.theme.border);
    }
    c.put(l, bottom, cp("╰"), c.theme.border);
    c.put(r, bottom, cp("╯"), c.theme.border);
    drawHLine(c, l + 1, r - 1, bottom, G_HDASH, c.theme.border);
    for (nt.lines, 0..) |line, index| putText(c, l + 2, y + 1 + @as(isize, @intCast(index)), line, r - l - 3, c.theme.accent);
}

fn appendFlowEdge(alloc: std.mem.Allocator, graph: *std.ArrayList(u8), left: []const u8, right: []const u8, label: []const u8) !void {
    try graph.appendSlice(alloc, left);
    if (label.len > 0) {
        try graph.appendSlice(alloc, " -- ");
        try graph.appendSlice(alloc, label);
        try graph.appendSlice(alloc, " --> ");
    } else {
        try graph.appendSlice(alloc, " --> ");
    }
    try graph.appendSlice(alloc, right);
    try graph.append(alloc, '\n');
}

fn stateEndpoint(endpoint: []const u8, start: bool) []const u8 {
    const t = std.mem.trim(u8, endpoint, " \t");
    if (std.mem.eql(u8, t, "[*]")) return if (start) "__start((Start))" else "__end((End))";
    return t;
}

fn renderState(alloc: std.mem.Allocator, output_alloc: std.mem.Allocator, src: []const u8, out: *std.ArrayList(Line), options: Options) !void {
    var graph = std.ArrayList(u8).empty;
    defer graph.deinit(alloc);
    var declarations = std.ArrayList(u8).empty;
    defer declarations.deinit(alloc);
    try graph.appendSlice(alloc, "flowchart TD\n");
    var first = true;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (first) {
            first = false;
            continue;
        }
        if (std.mem.eql(u8, line, "direction LR") or std.mem.eql(u8, line, "direction RL")) {
            graph.items[10] = line["direction ".len];
            graph.items[11] = line["direction ".len + 1];
            continue;
        }
        if (startsWithWord(line, "state")) {
            const rest = std.mem.trim(u8, line["state".len..], " \t");
            if (rest.len > 2 and rest[0] == '"') {
                const quote = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse continue;
                const label = rest[1..quote];
                const after = std.mem.trim(u8, rest[quote + 1 ..], " \t");
                if (std.mem.startsWith(u8, after, "as ")) {
                    try declarations.appendSlice(alloc, std.mem.trim(u8, after[3..], " \t"));
                    try declarations.append(alloc, '[');
                    try declarations.appendSlice(alloc, label);
                    try declarations.appendSlice(alloc, "]\n");
                }
            } else if (rest.len > 0 and std.mem.indexOfScalar(u8, rest, '{') == null) {
                try declarations.appendSlice(alloc, rest);
                try declarations.append(alloc, '[');
                try declarations.appendSlice(alloc, rest);
                try declarations.appendSlice(alloc, "]\n");
            }
            continue;
        }
        const arrow = std.mem.indexOf(u8, line, "-->") orelse continue;
        const left = stateEndpoint(line[0..arrow], true);
        const rhs = std.mem.trim(u8, line[arrow + 3 ..], " \t");
        const colon = std.mem.indexOfScalar(u8, rhs, ':');
        const right = stateEndpoint(if (colon) |pos| rhs[0..pos] else rhs, false);
        const label = if (colon) |pos| std.mem.trim(u8, rhs[pos + 1 ..], " \t") else "";
        try appendFlowEdge(alloc, &graph, left, right, label);
    }
    try graph.appendSlice(alloc, declarations.items);
    if (graph.items.len == "flowchart TD\n".len) return renderFallback(output_alloc, src, out, options.theme.muted);
    try renderFlowchart(alloc, output_alloc, graph.items, out, options, null);
}

fn classEndpoint(text: []const u8) []const u8 {
    var t = std.mem.trim(u8, text, " \t");
    if (t.len > 0 and t[0] == '"') {
        if (std.mem.indexOfScalarPos(u8, t, 1, '"')) |quote| t = std.mem.trim(u8, t[quote + 1 ..], " \t");
    }
    if (std.mem.indexOfScalar(u8, t, ' ')) |space| t = t[0..space];
    return t;
}

fn renderClass(alloc: std.mem.Allocator, output_alloc: std.mem.Allocator, src: []const u8, out: *std.ArrayList(Line), options: Options) !void {
    var graph = std.ArrayList(u8).empty;
    defer graph.deinit(alloc);
    try graph.appendSlice(alloc, "flowchart LR\n");
    const relations = [_][]const u8{ "<|--", "--|>", "*--", "o--", "--> ", "-->", "..>", "..|>", "--" };
    var first = true;
    var depth: usize = 0;
    var class_open = false;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (first) {
            first = false;
            continue;
        }
        if (std.mem.eql(u8, line, "}")) {
            if (depth > 0) {
                depth -= 1;
                if (class_open) {
                    try graph.appendSlice(alloc, "]\n");
                    class_open = false;
                }
            }
            continue;
        }
        if (depth > 0) {
            try graph.appendSlice(alloc, " | ");
            try graph.appendSlice(alloc, line);
            continue;
        }
        if (startsWithWord(line, "class")) {
            var name = std.mem.trim(u8, line["class".len..], " \t{");
            if (std.mem.indexOfScalar(u8, name, ' ')) |space| name = name[0..space];
            if (name.len > 0) {
                try graph.appendSlice(alloc, name);
                try graph.append(alloc, '[');
                try graph.appendSlice(alloc, name);
                if (std.mem.indexOfScalar(u8, line, '{') == null) try graph.appendSlice(alloc, "]\n");
            }
            if (std.mem.indexOfScalar(u8, line, '{') != null) {
                depth += 1;
                class_open = true;
            }
            continue;
        }
        if (std.mem.indexOfScalar(u8, line, ':')) |colon_pos| {
            if (std.mem.indexOf(u8, line, "--") == null and std.mem.indexOf(u8, line, "..") == null) {
                const name = std.mem.trim(u8, line[0..colon_pos], " \t");
                const member = std.mem.trim(u8, line[colon_pos + 1 ..], " \t");
                if (name.len > 0 and member.len > 0) {
                    try graph.appendSlice(alloc, name);
                    try graph.append(alloc, '[');
                    try graph.appendSlice(alloc, name);
                    try graph.appendSlice(alloc, " | ");
                    try graph.appendSlice(alloc, member);
                    try graph.appendSlice(alloc, "]\n");
                }
                continue;
            }
        }
        var hit_pos: ?usize = null;
        var hit_len: usize = 0;
        for (relations) |relation| {
            if (std.mem.indexOf(u8, line, relation)) |pos| {
                if (hit_pos == null or pos < hit_pos.?) {
                    hit_pos = pos;
                    hit_len = relation.len;
                }
            }
        }
        const pos = hit_pos orelse continue;
        const left = classEndpoint(line[0..pos]);
        const rhs = std.mem.trim(u8, line[pos + hit_len ..], " \t");
        const colon = std.mem.indexOfScalar(u8, rhs, ':');
        const right = classEndpoint(if (colon) |ci| rhs[0..ci] else rhs);
        const label = if (colon) |ci| std.mem.trim(u8, rhs[ci + 1 ..], " \t") else "";
        if (left.len > 0 and right.len > 0) try appendFlowEdge(alloc, &graph, left, right, label);
    }
    if (graph.items.len == "flowchart LR\n".len) return renderFallback(output_alloc, src, out, options.theme.muted);
    try renderFlowchart(alloc, output_alloc, graph.items, out, options, .compartmented);
}

fn renderEr(alloc: std.mem.Allocator, output_alloc: std.mem.Allocator, src: []const u8, out: *std.ArrayList(Line), options: Options) !void {
    var graph = std.ArrayList(u8).empty;
    defer graph.deinit(alloc);
    try graph.appendSlice(alloc, "flowchart LR\n");
    var first = true;
    var entity_open = false;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%%")) continue;
        if (first) {
            first = false;
            continue;
        }
        if (entity_open) {
            if (std.mem.eql(u8, line, "}")) {
                try graph.appendSlice(alloc, "]\n");
                entity_open = false;
            } else {
                try graph.appendSlice(alloc, " | ");
                try graph.appendSlice(alloc, line);
            }
            continue;
        }
        if (std.mem.endsWith(u8, line, "{")) {
            const name = std.mem.trim(u8, line[0 .. line.len - 1], " \t");
            if (name.len > 0) {
                try graph.appendSlice(alloc, name);
                try graph.append(alloc, '[');
                try graph.appendSlice(alloc, name);
                entity_open = true;
            }
            continue;
        }
        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        const left = tokens.next() orelse continue;
        const relation = tokens.next() orelse continue;
        const right = tokens.next() orelse continue;
        const dash = std.mem.indexOf(u8, relation, "--") orelse continue;
        const colon = std.mem.indexOfScalar(u8, line, ':');
        const label = if (colon) |pos| std.mem.trim(u8, line[pos + 1 ..], " \t\"") else "";
        const relation_label = try std.fmt.allocPrint(alloc, "{s} {s} {s}", .{ relation[0..dash], label, relation[dash + 2 ..] });
        defer alloc.free(relation_label);
        try appendFlowEdge(alloc, &graph, left, right, std.mem.trim(u8, relation_label, " \t"));
    }
    if (entity_open) try graph.appendSlice(alloc, "]\n");
    if (graph.items.len == "flowchart LR\n".len) return renderFallback(output_alloc, src, out, options.theme.muted);
    try renderFlowchart(alloc, output_alloc, graph.items, out, options, .compartmented);
}

fn renderFallback(alloc: std.mem.Allocator, src: []const u8, out: *std.ArrayList(Line), style: Style) !void {
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        var l = Line{};
        errdefer l.deinit(alloc);
        try l.pushSpan(alloc, .{ .content = line, .style = style });
        try out.append(alloc, l);
    }
}

fn deinitLines(alloc: std.mem.Allocator, lines: *std.ArrayList(Line)) void {
    for (lines.items) |*line| line.deinit(alloc);
    lines.deinit(alloc);
}

test "mermaid flowchart renders node labels" {
    const alloc = std.testing.allocator;
    var out = std.ArrayList(Line).empty;
    defer deinitLines(alloc, &out);

    try render(alloc, 40,
        \\graph TD
        \\A[Start] --> B[End]
        \\
    , &out);

    try std.testing.expect(out.items.len >= 3);
    var found_start = false;
    var found_end = false;
    for (out.items) |*l| {
        for (l.spans.items) |s| {
            if (std.mem.indexOf(u8, s.content, "Start") != null) found_start = true;
            if (std.mem.indexOf(u8, s.content, "End") != null) found_end = true;
        }
    }
    try std.testing.expect(found_start);
    try std.testing.expect(found_end);
}

test "mermaid sequence renders participants" {
    const alloc = std.testing.allocator;
    var out = std.ArrayList(Line).empty;
    defer deinitLines(alloc, &out);

    try render(alloc, 60,
        \\sequenceDiagram
        \\participant A as Alice
        \\participant B as Bob
        \\A->>B: Hello
        \\
    , &out);

    var found_alice = false;
    var found_bob = false;
    for (out.items) |*l| {
        for (l.spans.items) |s| {
            if (std.mem.indexOf(u8, s.content, "Alice") != null) found_alice = true;
            if (std.mem.indexOf(u8, s.content, "Bob") != null) found_bob = true;
        }
    }
    try std.testing.expect(found_alice);
    try std.testing.expect(found_bob);
}

test "mermaid sequence renders note over reversed participants" {
    const alloc = std.testing.allocator;
    var out = std.ArrayList(Line).empty;
    defer deinitLines(alloc, &out);

    try render(alloc, 60,
        \\sequenceDiagram
        \\participant A as Alice
        \\participant B as Bob
        \\Note over B,A: Reverse span
        \\
    , &out);

    var found_note = false;
    for (out.items) |*line| {
        for (line.spans.items) |span| {
            if (std.mem.indexOf(u8, span.content, "Reverse span") != null) found_note = true;
        }
    }
    try std.testing.expect(found_note);
}

test "mermaid sequence note layouts handle narrow widths" {
    const alloc = std.testing.allocator;
    const source =
        \\sequenceDiagram
        \\participant A as Alice
        \\participant B as Bob
        \\Note over B,A: Reverse span
        \\Note over A,A: Single span
        \\Note left of A: Left note
        \\Note right of B: Right note
        \\B-->>A: Reply
        \\
    ;

    for ([_]u16{ 1, 2, 4, 5, 8, 16, 40 }) |width| {
        var out = std.ArrayList(Line).empty;
        defer deinitLines(alloc, &out);

        try render(alloc, width, source, &out);
        for (out.items) |*line| {
            var joined = std.ArrayList(u8).empty;
            defer joined.deinit(alloc);
            for (line.spans.items) |span| try joined.appendSlice(alloc, span.content);
            try std.testing.expect(widthOf(joined.items) <= width);
        }
    }
}

test "mermaid unsupported falls back to raw text" {
    const alloc = std.testing.allocator;
    var out = std.ArrayList(Line).empty;
    defer deinitLines(alloc, &out);

    try render(alloc, 40,
        \\gantt
        \\Task: 1d
        \\
    , &out);

    var found = false;
    for (out.items) |*line| for (line.spans.items) |span| {
        if (std.mem.indexOf(u8, span.content, "gantt") != null) found = true;
    };
    try std.testing.expect(found);
}

test "mermaid flowchart renders self loop" {
    const alloc = std.testing.allocator;
    var out = std.ArrayList(Line).empty;
    defer deinitLines(alloc, &out);

    try render(alloc, 40,
        \\graph TD
        \\A[Retry] --> A
        \\
    , &out);

    var found_arrow = false;
    for (out.items) |*l| {
        for (l.spans.items) |s| {
            if (std.mem.indexOf(u8, s.content, "▶") != null) found_arrow = true;
        }
    }
    try std.testing.expect(found_arrow);
}

test "mermaid flowchart renders chained edges" {
    const alloc = std.testing.allocator;
    var out = std.ArrayList(Line).empty;
    defer deinitLines(alloc, &out);

    try render(alloc, 60,
        \\graph TD
        \\A[One] --> B[Two] --> C[Three]
        \\
    , &out);

    var found_three = false;
    for (out.items) |*l| {
        for (l.spans.items) |s| {
            if (std.mem.indexOf(u8, s.content, "Three") != null) found_three = true;
        }
    }
    try std.testing.expect(found_three);
}

test "mermaid flowchart spaces sibling nodes horizontally" {
    const alloc = std.testing.allocator;
    var out = std.ArrayList(Line).empty;
    defer deinitLines(alloc, &out);

    try render(alloc, 80,
        \\graph TD
        \\A[Start] --> B{Go?}
        \\B -- No --> C[Show error]
        \\B -- Yes --> D[Process data]
        \\
    , &out);

    var found = false;
    for (out.items) |*l| {
        var joined = std.ArrayList(u8).empty;
        defer joined.deinit(alloc);
        for (l.spans.items) |s| try joined.appendSlice(alloc, s.content);
        const a = std.mem.indexOf(u8, joined.items, "Show error") orelse continue;
        const b = std.mem.indexOf(u8, joined.items, "Process data") orelse continue;
        if (b < a) continue;
        const gap = b - (a + "Show error".len);
        try std.testing.expect(gap >= 6);
        found = true;
        break;
    }
    try std.testing.expect(found);
}

test "mermaid sequence spaces participant columns" {
    const alloc = std.testing.allocator;
    var out = std.ArrayList(Line).empty;
    defer deinitLines(alloc, &out);

    try render(alloc, 60,
        \\sequenceDiagram
        \\participant A as Alice
        \\participant B as Bob
        \\
    , &out);

    var found = false;
    for (out.items) |*l| {
        var joined = std.ArrayList(u8).empty;
        defer joined.deinit(alloc);
        for (l.spans.items) |s| try joined.appendSlice(alloc, s.content);
        const close = std.mem.indexOf(u8, joined.items, "┐") orelse continue;
        const open = std.mem.indexOfPos(u8, joined.items, close + 1, "┌") orelse continue;
        try std.testing.expect(open >= close + 4);
        found = true;
        break;
    }
    try std.testing.expect(found);
}

test "mermaid nodes preserve horizontal padding at narrow widths" {
    const alloc = std.testing.allocator;
    var out = std.ArrayList(Line).empty;
    defer deinitLines(alloc, &out);

    try render(alloc, 30,
        \\flowchart TD
        \\A[Start] --> B{Choose}
        \\B --> C[First option]
        \\B --> D[Second option]
        \\
    , &out);

    var found_padding = false;
    var found_wrapped = false;
    var found_junction = false;
    for (out.items) |*line| {
        var joined = std.ArrayList(u8).empty;
        defer joined.deinit(alloc);
        for (line.spans.items) |span| try joined.appendSlice(alloc, span.content);
        try std.testing.expect(widthOf(joined.items) <= 30);
        if (std.mem.indexOf(u8, joined.items, "│  First   │") != null) found_padding = true;
        if (std.mem.indexOf(u8, joined.items, "│  option  │") != null) found_wrapped = true;
        if (std.mem.indexOf(u8, joined.items, "┴") != null) found_junction = true;
    }
    try std.testing.expect(found_padding);
    try std.testing.expect(found_wrapped);
    try std.testing.expect(found_junction);
}

test "mermaid flowchart joins node borders and places horizontal labels on edges" {
    const alloc = std.testing.allocator;
    var out = std.ArrayList(Line).empty;
    defer deinitLines(alloc, &out);

    try render(alloc, 80,
        \\flowchart LR
        \\A[Agent] -- owns --> J[Job]
        \\A -- polls --> S[Session]
        \\M[Model] -- polls --> S
        \\
    , &out);

    var text = std.ArrayList(u8).empty;
    defer text.deinit(alloc);
    for (out.items) |*line| {
        for (line.spans.items) |span| try text.appendSlice(alloc, span.content);
        try text.append(alloc, '\n');
    }
    try std.testing.expect(std.mem.indexOf(u8, text.items, "│ Agent ├─┤") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "┌─owns────▶┤ Job │") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "├─polls─▶┤ Session │") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "│ Model ├─┘") != null);
}

test "mermaid sequence separates message text from arrows" {
    const alloc = std.testing.allocator;
    var out = std.ArrayList(Line).empty;
    defer deinitLines(alloc, &out);

    try render(alloc, 40,
        \\sequenceDiagram
        \\participant U as User
        \\participant A as Application
        \\U->>A: Click login
        \\
    , &out);

    var found_label = false;
    for (out.items) |*line| {
        var joined = std.ArrayList(u8).empty;
        defer joined.deinit(alloc);
        for (line.spans.items) |span| try joined.appendSlice(alloc, span.content);
        try std.testing.expect(widthOf(joined.items) <= 40);
        if (std.mem.indexOf(u8, joined.items, "Click login") != null) {
            try std.testing.expect(std.mem.indexOf(u8, joined.items, "─") == null);
            found_label = true;
        }
    }
    try std.testing.expect(found_label);
}

test "mermaid class renders compartmented boxes and relationships" {
    const alloc = std.testing.allocator;
    var out = std.ArrayList(Line).empty;
    defer deinitLines(alloc, &out);

    try render(alloc, 80,
        \\classDiagram
        \\class Animal {
        \\+String name
        \\+move()
        \\}
        \\Animal <|-- Duck
        \\
    , &out);

    var header_row: ?usize = null;
    var separator_row: ?usize = null;
    var member_row: ?usize = null;
    var found_duck = false;
    for (out.items, 0..) |*line, row| {
        const text = try widgets.lineText(alloc, line);
        defer alloc.free(text);
        if (std.mem.indexOf(u8, text, "Animal") != null) header_row = row;
        if (std.mem.indexOf(u8, text, "▶") == null and std.mem.indexOf(u8, text, "├") != null and std.mem.indexOf(u8, text, "┤") != null) separator_row = row;
        if (std.mem.indexOf(u8, text, "+String name") != null) member_row = row;
        if (std.mem.indexOf(u8, text, "Duck") != null) found_duck = true;
    }
    try std.testing.expect(header_row != null and separator_row != null and member_row != null and found_duck);
    try std.testing.expect(header_row.? < separator_row.? and separator_row.? < member_row.?);
}

test "mermaid state renders endpoints transitions and labels" {
    const alloc = std.testing.allocator;
    var out = std.ArrayList(Line).empty;
    defer deinitLines(alloc, &out);

    try render(alloc, 50,
        \\stateDiagram-v2
        \\[*] --> Idle
        \\Idle --> Running : start
        \\Running --> [*]
        \\
    , &out);

    var found_start = false;
    var found_running = false;
    var found_label = false;
    for (out.items) |*line| for (line.spans.items) |span| {
        if (std.mem.indexOf(u8, span.content, "Start") != null) found_start = true;
        if (std.mem.indexOf(u8, span.content, "Running") != null) found_running = true;
        if (std.mem.indexOf(u8, span.content, "start") != null) found_label = true;
    };
    try std.testing.expect(found_start and found_running and found_label);
}

test "mermaid er renders compartmented entities and cardinalities" {
    const alloc = std.testing.allocator;
    var out = std.ArrayList(Line).empty;
    defer deinitLines(alloc, &out);
    try render(alloc, 100,
        \\erDiagram
        \\CUSTOMER ||--o{ ORDER : places
        \\CUSTOMER {
        \\string name PK
        \\}
        \\
    , &out);
    var entity_row: ?usize = null;
    var separator_row: ?usize = null;
    var attribute_row: ?usize = null;
    var cardinality = false;
    for (out.items, 0..) |*line, row| {
        const text = try widgets.lineText(alloc, line);
        defer alloc.free(text);
        if (std.mem.indexOf(u8, text, "CUSTOMER") != null) entity_row = row;
        if (std.mem.indexOf(u8, text, "├") != null and std.mem.indexOf(u8, text, "┤") != null) separator_row = row;
        if (std.mem.indexOf(u8, text, "string name") != null) attribute_row = row;
        if (std.mem.indexOf(u8, text, "|| places o{") != null) cardinality = true;
    }
    try std.testing.expect(entity_row != null and separator_row != null and attribute_row != null and cardinality);
    try std.testing.expect(entity_row.? < separator_row.? and separator_row.? < attribute_row.?);
}

test "mermaid wraps long node labels without dropping text" {
    const alloc = std.testing.allocator;
    var out = std.ArrayList(Line).empty;
    defer deinitLines(alloc, &out);

    try renderWithOptions(alloc, alloc,
        \\flowchart TD
        \\A[Alpha beta gamma delta epsilon zeta eta theta]
        \\
    , &out, .{ .width = 32, .max_node_width = 16 });

    var text = std.ArrayList(u8).empty;
    defer text.deinit(alloc);
    for (out.items) |*line| {
        for (line.spans.items) |span| try text.appendSlice(alloc, span.content);
        try text.append(alloc, '\n');
    }
    for ([_][]const u8{ "Alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta" }) |word| {
        try std.testing.expect(std.mem.indexOf(u8, text.items, word) != null);
    }
}

test "mermaid treats br tags as label line breaks" {
    const alloc = std.testing.allocator;
    var out = std.ArrayList(Line).empty;
    defer deinitLines(alloc, &out);

    try render(alloc, 48,
        \\flowchart TD
        \\A[First<br/>Second] -- edge one<BR />edge two --> B[End]
        \\
    , &out);

    var text = std.ArrayList(u8).empty;
    defer text.deinit(alloc);
    for (out.items) |*line| {
        for (line.spans.items) |span| try text.appendSlice(alloc, span.content);
        try text.append(alloc, '\n');
    }
    for ([_][]const u8{ "First", "Second", "edge one", "edge two" }) |part| {
        try std.testing.expect(std.mem.indexOf(u8, text.items, part) != null);
    }
    try std.testing.expect(std.ascii.indexOfIgnoreCase(text.items, "<br") == null);
}

test "mermaid wraps sequence participant labels" {
    const alloc = std.testing.allocator;
    var out = std.ArrayList(Line).empty;
    defer deinitLines(alloc, &out);

    try render(alloc, 32,
        \\sequenceDiagram
        \\participant A as Long participant display name
        \\A->>A: ping<br>returns
        \\Note right of A: Every note<br />word remains visible
        \\
    , &out);

    var text = std.ArrayList(u8).empty;
    defer text.deinit(alloc);
    for (out.items) |*line| for (line.spans.items) |span| try text.appendSlice(alloc, span.content);
    for ([_][]const u8{ "Long", "participant", "display", "name", "ping", "returns", "Every", "note", "word", "remains", "visible" }) |word| {
        try std.testing.expect(std.mem.indexOf(u8, text.items, word) != null);
    }
    try std.testing.expect(std.ascii.indexOfIgnoreCase(text.items, "<br") == null);
}

test "mermaid state declarations render without transitions" {
    const alloc = std.testing.allocator;
    var out = std.ArrayList(Line).empty;
    defer deinitLines(alloc, &out);

    try render(alloc, 32, "stateDiagram-v2\nstate Idle\n", &out);
    var found = false;
    for (out.items) |*line| for (line.spans.items) |span| {
        if (std.mem.indexOf(u8, span.content, "Idle") != null) found = true;
    };
    try std.testing.expect(found);
}

test "mermaid options apply shared colors and dotted glyphs" {
    const alloc = std.testing.allocator;
    var out = std.ArrayList(Line).empty;
    defer deinitLines(alloc, &out);

    try renderWithOptions(alloc, alloc, "flowchart TD\nA[Alpha] -.-> B[Beta]\n", &out, .{
        .width = 32,
        .theme = .{ .strong = .{ .fg = .red } },
    });
    var found_color = false;
    var found_dotted = false;
    for (out.items) |*line| for (line.spans.items) |span| {
        if (std.mem.indexOf(u8, span.content, "Alpha") != null and span.style.fg.eql(.red)) found_color = true;
        if (std.mem.indexOf(u8, span.content, "┆") != null or std.mem.indexOf(u8, span.content, "┄") != null) found_dotted = true;
    };
    try std.testing.expect(found_color);
    try std.testing.expect(found_dotted);
}

fn renderAllocationFailureCase(alloc: std.mem.Allocator) !void {
    var out = std.ArrayList(Line).empty;
    defer deinitLines(alloc, &out);
    try renderWithOptions(alloc, alloc, "flowchart TD\nA[Alpha beta gamma delta] --> B[Beta]\n", &out, .{ .width = 32, .max_node_width = 12 });
}

test "mermaid render cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, renderAllocationFailureCase, .{});
}
