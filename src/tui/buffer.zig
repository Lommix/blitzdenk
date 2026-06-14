const std = @import("std");
const cell_mod = @import("cell.zig");
const rect_mod = @import("rect.zig");

pub const Cell = cell_mod.Cell;
pub const Style = cell_mod.Style;
pub const Rect = rect_mod.Rect;

pub const Buffer = struct {
    rect: Rect,
    cells: []Cell,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, rect: Rect) !Buffer {
        const len = @as(usize, rect.width) * @as(usize, rect.height);
        const cells = try allocator.alloc(Cell, len);
        @memset(cells, Cell{});
        return .{ .rect = rect, .cells = cells, .allocator = allocator };
    }

    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.cells);
    }

    pub fn resize(self: *Buffer, rect: Rect) !void {
        const len = @as(usize, rect.width) * @as(usize, rect.height);
        self.allocator.free(self.cells);
        self.cells = try self.allocator.alloc(Cell, len);
        self.rect = rect;
        self.clear();
    }

    pub fn clear(self: *Buffer) void {
        @memset(self.cells, Cell{});
    }

    fn indexOf(self: *const Buffer, x: u16, y: u16) ?usize {
        if (x < self.rect.x or y < self.rect.y) return null;
        const col = x - self.rect.x;
        const row = y - self.rect.y;
        if (col >= self.rect.width or row >= self.rect.height) return null;
        return @as(usize, row) * @as(usize, self.rect.width) + @as(usize, col);
    }

    pub fn get(self: *const Buffer, x: u16, y: u16) Cell {
        const idx = self.indexOf(x, y) orelse return Cell{};
        return self.cells[idx];
    }

    pub fn set(self: *Buffer, x: u16, y: u16, c: Cell) void {
        const idx = self.indexOf(x, y) orelse return;
        self.cells[idx].char = c.char;
        self.cells[idx].style.modifier = c.style.modifier;
        self.cells[idx].style.fg = c.style.fg;
        if (c.style.bg != .reset) {
            self.cells[idx].style.bg = c.style.bg;
        }
    }

    pub fn setStyle(self: *Buffer, rect: Rect, style: Style) void {
        var y = rect.y;
        while (y < rect.y +| rect.height) : (y += 1) {
            var x = rect.x;
            while (x < rect.x +| rect.width) : (x += 1) {
                if (self.indexOf(x, y)) |idx| {
                    self.cells[idx].style = style;
                }
            }
        }
    }

    pub fn setString(self: *Buffer, x: u16, y: u16, string: []const u8, style: Style) void {
        self.setStringMax(x, y, string, style, std.math.maxInt(u16));
    }

    pub fn setStringMax(self: *Buffer, x: u16, y: u16, string: []const u8, style: Style, max_width: u16) void {
        var col: u16 = 0;
        var i: usize = 0;
        while (i < string.len) {
            if (col >= max_width) break;
            const len = std.unicode.utf8ByteSequenceLength(string[i]) catch break;
            if (i + len > string.len) break;
            const cp = std.unicode.utf8Decode(string[i..][0..len]) catch break;
            i += len;
            // Skip control characters (newlines, tabs, etc.) — they corrupt terminal positioning
            if (cp < 0x20 or cp == 0x7F) continue;
            self.set(x +| col, y, .{ .char = cp, .style = style });
            col +|= 1;
        }
    }

    pub fn fill(self: *Buffer, rect: Rect, c: Cell) void {
        var y = rect.y;
        while (y < rect.y +| rect.height) : (y += 1) {
            var x = rect.x;
            while (x < rect.x +| rect.width) : (x += 1) {
                self.set(x, y, c);
            }
        }
    }

    pub const DiffEntry = struct {
        x: u16,
        y: u16,
        cell: Cell,
    };

    pub fn diff(self: *const Buffer, previous: *const Buffer) DiffIterator {
        return .{ .current = self, .previous = previous, .pos = 0 };
    }

    pub const DiffIterator = struct {
        current: *const Buffer,
        previous: *const Buffer,
        pos: usize,

        pub fn next(self: *DiffIterator) ?DiffEntry {
            const len = self.current.cells.len;
            while (self.pos < len) {
                const i = self.pos;
                self.pos += 1;
                const cur = self.current.cells[i];
                const prev = if (i < self.previous.cells.len) self.previous.cells[i] else Cell{};
                if (!cur.eql(prev)) {
                    const col: u16 = @intCast(i % @as(usize, self.current.rect.width));
                    const row: u16 = @intCast(i / @as(usize, self.current.rect.width));
                    return .{
                        .x = self.current.rect.x + col,
                        .y = self.current.rect.y + row,
                        .cell = cur,
                    };
                }
            }
            return null;
        }
    };
};

// -- Tests --

test "buffer set and get" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, .{ .width = 10, .height = 5 });
    defer buf.deinit();

    buf.set(3, 2, .{ .char = 'X' });
    const c = buf.get(3, 2);
    try std.testing.expectEqual(@as(u21, 'X'), c.char);
}

test "buffer out of bounds clips" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, .{ .width = 5, .height = 5 });
    defer buf.deinit();

    // Should not crash
    buf.set(100, 100, .{ .char = 'X' });
    const c = buf.get(100, 100);
    try std.testing.expectEqual(@as(u21, ' '), c.char);
}

test "buffer setString" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator, .{ .width = 20, .height = 1 });
    defer buf.deinit();

    buf.setString(0, 0, "Hello", .{});
    try std.testing.expectEqual(@as(u21, 'H'), buf.get(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'o'), buf.get(4, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), buf.get(5, 0).char);
}

test "buffer diff" {
    const allocator = std.testing.allocator;
    var a = try Buffer.init(allocator, .{ .width = 3, .height = 1 });
    defer a.deinit();
    var b = try Buffer.init(allocator, .{ .width = 3, .height = 1 });
    defer b.deinit();

    b.set(1, 0, .{ .char = 'X' });

    var it = b.diff(&a);
    const entry = it.next().?;
    try std.testing.expectEqual(@as(u16, 1), entry.x);
    try std.testing.expectEqual(@as(u21, 'X'), entry.cell.char);
    try std.testing.expectEqual(@as(?Buffer.DiffEntry, null), it.next());
}
