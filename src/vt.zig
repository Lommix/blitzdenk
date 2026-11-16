//! Minimal terminal emulator for background jobs. Feeds raw pty bytes into a
//! character grid so a reader sees what a user would see: carriage returns,
//! cursor moves, erases and scroll regions all apply. Rows that scroll off the
//! top of the main screen are kept as scrollback text. Styles are dropped.
const std = @import("std");

pub const DEFAULT_COLS = 200;
pub const DEFAULT_ROWS = 50;
const TAB_WIDTH = 8;
const MAX_PARAMS = 16;
pub const MAX_REPLY = 256;
const REPLACEMENT: u21 = 0xFFFD;

const Grid = struct {
    cells: []u21,
    wrapped: []bool,

    fn init(alloc: std.mem.Allocator, cols: usize, rows: usize) !Grid {
        const cells = try alloc.alloc(u21, cols * rows);
        errdefer alloc.free(cells);
        const wrapped = try alloc.alloc(bool, rows);
        @memset(cells, 0);
        @memset(wrapped, false);
        return .{ .cells = cells, .wrapped = wrapped };
    }

    fn deinit(self: Grid, alloc: std.mem.Allocator) void {
        alloc.free(self.cells);
        alloc.free(self.wrapped);
    }
};

const Cursor = struct {
    row: usize = 0,
    col: usize = 0,
    pending_wrap: bool = false,
};

const Mode = enum { ground, escape, escape_intermediate, csi, osc, osc_escape, string, string_escape };

pub const Snapshot = struct {
    text: []u8,
    dropped_lines: usize,
};

pub const Screen = struct {
    alloc: std.mem.Allocator,
    cols: usize,
    rows: usize,
    main: Grid,
    alt: Grid,
    on_alt: bool = false,
    cursor: Cursor = .{},
    saved: Cursor = .{},
    saved_before_alt: Cursor = .{},
    scroll_top: usize = 0,
    scroll_bottom: usize,

    history: std.ArrayList(u8) = .empty,
    history_cap: usize,
    history_dropped_lines: usize = 0,

    reply_buf: [MAX_REPLY]u8 = undefined,
    reply_len: usize = 0,

    mode: Mode = .ground,
    utf8_cp: u21 = 0,
    utf8_left: u3 = 0,
    params: [MAX_PARAMS]u32 = @splat(0),
    param_count: usize = 0,
    private_marker: u8 = 0,
    has_intermediate: bool = false,

    pub fn init(alloc: std.mem.Allocator, cols: usize, rows: usize, history_cap: usize) !Screen {
        const main = try Grid.init(alloc, cols, rows);
        errdefer main.deinit(alloc);
        const alt = try Grid.init(alloc, cols, rows);
        return .{
            .alloc = alloc,
            .cols = cols,
            .rows = rows,
            .main = main,
            .alt = alt,
            .scroll_bottom = rows - 1,
            .history_cap = history_cap,
        };
    }

    pub fn deinit(self: *Screen) void {
        self.main.deinit(self.alloc);
        self.alt.deinit(self.alloc);
        self.history.deinit(self.alloc);
    }

    /// Bytes the terminal answers with, such as cursor position reports. Valid
    /// until the next `feed`; call `clearReplies` after writing them back.
    pub fn replies(self: *const Screen) []const u8 {
        return self.reply_buf[0..self.reply_len];
    }

    pub fn clearReplies(self: *Screen) void {
        self.reply_len = 0;
    }

    pub fn feed(self: *Screen, bytes: []const u8) void {
        for (bytes) |byte| self.feedByte(byte);
    }

    /// Scrollback followed by the visible rows with trailing blank rows dropped.
    /// Lines that wrapped at the right edge are joined into one logical line.
    pub fn snapshot(self: *const Screen, alloc: std.mem.Allocator) !Snapshot {
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(alloc);
        try text.appendSlice(alloc, self.history.items);

        const grid = self.activeGrid();
        var last_used: ?usize = null;
        for (0..self.rows) |row| {
            if (self.rowLength(grid, row) > 0) last_used = row;
        }
        if (last_used) |last| {
            for (0..last + 1) |row| {
                try self.appendRow(alloc, &text, grid, row);
                if (row < last and !grid.wrapped[row]) try text.append(alloc, '\n');
            }
        }
        return .{ .text = try text.toOwnedSlice(alloc), .dropped_lines = self.history_dropped_lines };
    }

    fn activeGrid(self: *const Screen) Grid {
        return if (self.on_alt) self.alt else self.main;
    }

    fn rowSlice(self: *const Screen, grid: Grid, row: usize) []u21 {
        return grid.cells[row * self.cols ..][0..self.cols];
    }

    fn rowLength(self: *const Screen, grid: Grid, row: usize) usize {
        const cells = self.rowSlice(grid, row);
        var len = cells.len;
        while (len > 0 and (cells[len - 1] == 0 or cells[len - 1] == ' ')) len -= 1;
        return len;
    }

    fn appendRow(self: *const Screen, alloc: std.mem.Allocator, out: *std.ArrayList(u8), grid: Grid, row: usize) !void {
        const cells = self.rowSlice(grid, row)[0..self.rowLength(grid, row)];
        for (cells) |cp| {
            const point: u21 = if (cp == 0) ' ' else cp;
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(point, &buf) catch continue;
            try out.appendSlice(alloc, buf[0..len]);
        }
    }

    fn feedByte(self: *Screen, byte: u8) void {
        if (byte == 0x18 or byte == 0x1a) {
            self.mode = .ground;
            return;
        }
        switch (self.mode) {
            .ground => self.ground(byte),
            .escape => self.escape(byte),
            .escape_intermediate => self.mode = if (byte >= 0x20 and byte <= 0x2f) .escape_intermediate else .ground,
            .csi => self.csi(byte),
            .osc => switch (byte) {
                0x07 => self.mode = .ground,
                0x1b => self.mode = .osc_escape,
                else => {},
            },
            .osc_escape => self.mode = if (byte == '\\') .ground else .osc,
            .string => if (byte == 0x1b) {
                self.mode = .string_escape;
            },
            .string_escape => self.mode = if (byte == '\\') .ground else .string,
        }
    }

    fn ground(self: *Screen, byte: u8) void {
        if (self.utf8_left > 0) {
            if (byte & 0xc0 == 0x80) {
                self.utf8_cp = (self.utf8_cp << 6) | (byte & 0x3f);
                self.utf8_left -= 1;
                if (self.utf8_left == 0) self.print(self.utf8_cp);
                return;
            }
            self.utf8_left = 0;
            self.print(REPLACEMENT);
        }
        switch (byte) {
            0x08 => {
                self.cursor.col -|= 1;
                self.cursor.pending_wrap = false;
            },
            0x09 => {
                const next = (self.cursor.col / TAB_WIDTH + 1) * TAB_WIDTH;
                self.cursor.col = @min(next, self.cols - 1);
                self.cursor.pending_wrap = false;
            },
            0x0a, 0x0b, 0x0c => self.lineFeed(),
            0x0d => {
                self.cursor.col = 0;
                self.cursor.pending_wrap = false;
            },
            0x1b => self.mode = .escape,
            0x20...0x7e => self.print(byte),
            0xc2...0xdf => self.startUtf8(byte & 0x1f, 1),
            0xe0...0xef => self.startUtf8(byte & 0x0f, 2),
            0xf0...0xf4 => self.startUtf8(byte & 0x07, 3),
            0x80...0xc1, 0xf5...0xff => self.print(REPLACEMENT),
            else => {},
        }
    }

    fn startUtf8(self: *Screen, initial: u8, follow: u3) void {
        self.utf8_cp = initial;
        self.utf8_left = follow;
    }

    fn escape(self: *Screen, byte: u8) void {
        self.mode = .ground;
        switch (byte) {
            '[' => {
                self.mode = .csi;
                self.params = @splat(0);
                self.param_count = 0;
                self.private_marker = 0;
                self.has_intermediate = false;
            },
            ']' => self.mode = .osc,
            'P', 'X', '^', '_' => self.mode = .string,
            0x20...0x2f => self.mode = .escape_intermediate,
            '7' => self.saved = self.cursor,
            '8' => self.cursor = self.saved,
            'D' => self.lineFeed(),
            'E' => {
                self.cursor.col = 0;
                self.lineFeed();
            },
            'M' => {
                if (self.cursor.row == self.scroll_top) {
                    self.scrollDown(1);
                } else {
                    self.cursor.row -|= 1;
                }
                self.cursor.pending_wrap = false;
            },
            'c' => self.reset(),
            else => {},
        }
    }

    fn reset(self: *Screen) void {
        @memset(self.main.cells, 0);
        @memset(self.main.wrapped, false);
        @memset(self.alt.cells, 0);
        @memset(self.alt.wrapped, false);
        self.on_alt = false;
        self.cursor = .{};
        self.saved = .{};
        self.scroll_top = 0;
        self.scroll_bottom = self.rows - 1;
        self.history.clearRetainingCapacity();
        self.history_dropped_lines = 0;
    }

    fn csi(self: *Screen, byte: u8) void {
        switch (byte) {
            '0'...'9' => {
                if (self.param_count == 0) self.param_count = 1;
                if (self.param_count <= MAX_PARAMS) {
                    const slot = &self.params[self.param_count - 1];
                    slot.* = @min(slot.* *| 10 +| (byte - '0'), 65535);
                }
            },
            ';', ':' => {
                if (self.param_count == 0) self.param_count = 1;
                self.param_count = @min(self.param_count + 1, MAX_PARAMS + 1);
            },
            '<'...'?' => self.private_marker = byte,
            0x20...0x2f => self.has_intermediate = true,
            0x40...0x7e => {
                self.mode = .ground;
                if (!self.has_intermediate) self.dispatchCsi(byte);
            },
            else => self.mode = .ground,
        }
    }

    fn param(self: *const Screen, index: usize, default: usize) usize {
        if (index >= self.param_count or index >= MAX_PARAMS) return default;
        const value = self.params[index];
        return if (value == 0) default else value;
    }

    fn dispatchCsi(self: *Screen, final: u8) void {
        const cur = &self.cursor;
        cur.pending_wrap = false;
        if (self.private_marker == '?') {
            switch (final) {
                'h' => self.setPrivateMode(true),
                'l' => self.setPrivateMode(false),
                else => {},
            }
            return;
        }
        if (self.private_marker != 0) {
            if (final == 'c') self.reply("\x1b[>0;0;0c");
            return;
        }
        const n = self.param(0, 1);
        switch (final) {
            'A' => cur.row = self.clampUp(cur.row, n),
            'B', 'e' => cur.row = self.clampDown(cur.row, n),
            'C', 'a' => cur.col = @min(cur.col +| n, self.cols - 1),
            'D' => cur.col -|= n,
            'E' => {
                cur.row = self.clampDown(cur.row, n);
                cur.col = 0;
            },
            'F' => {
                cur.row = self.clampUp(cur.row, n);
                cur.col = 0;
            },
            'G', '`' => cur.col = @min(n - 1, self.cols - 1),
            'H', 'f' => {
                cur.row = @min(self.param(0, 1) - 1, self.rows - 1);
                cur.col = @min(self.param(1, 1) - 1, self.cols - 1);
            },
            'd' => cur.row = @min(n - 1, self.rows - 1),
            'J' => self.eraseDisplay(self.paramOrZero(0)),
            'K' => self.eraseLine(self.paramOrZero(0)),
            'L' => self.insertLines(n),
            'M' => self.deleteLines(n),
            '@' => self.insertChars(n),
            'P' => self.deleteChars(n),
            'X' => self.eraseChars(n),
            'S' => self.scrollUp(n),
            'T' => if (self.param_count <= 1) self.scrollDown(n),
            'r' => self.setScrollRegion(),
            's' => self.saved = self.cursor,
            'u' => self.cursor = self.saved,
            'n' => if (self.paramOrZero(0) == 6) self.replyPosition(),
            'c' => if (self.paramOrZero(0) == 0) self.reply("\x1b[?1;2c"),
            else => {},
        }
    }

    fn paramOrZero(self: *const Screen, index: usize) usize {
        if (index >= self.param_count or index >= MAX_PARAMS) return 0;
        return self.params[index];
    }

    fn clampUp(self: *const Screen, row: usize, n: usize) usize {
        const floor = if (row >= self.scroll_top) self.scroll_top else 0;
        return @max(row -| n, floor);
    }

    fn clampDown(self: *const Screen, row: usize, n: usize) usize {
        const ceiling = if (row <= self.scroll_bottom) self.scroll_bottom else self.rows - 1;
        return @min(row +| n, ceiling);
    }

    fn setPrivateMode(self: *Screen, enable: bool) void {
        for (0..@min(self.param_count, MAX_PARAMS)) |i| {
            switch (self.params[i]) {
                47, 1047 => self.switchScreen(enable, false),
                1049 => self.switchScreen(enable, true),
                else => {},
            }
        }
    }

    fn switchScreen(self: *Screen, to_alt: bool, save_cursor: bool) void {
        if (to_alt == self.on_alt) return;
        if (to_alt) {
            if (save_cursor) self.saved_before_alt = self.cursor;
            @memset(self.alt.cells, 0);
            @memset(self.alt.wrapped, false);
            self.on_alt = true;
            return;
        }
        self.on_alt = false;
        if (save_cursor) self.cursor = self.saved_before_alt;
    }

    fn setScrollRegion(self: *Screen) void {
        const top = self.param(0, 1) - 1;
        const bottom = @min(self.param(1, self.rows) - 1, self.rows - 1);
        if (top >= bottom) return;
        self.scroll_top = top;
        self.scroll_bottom = bottom;
        self.cursor = .{};
    }

    fn reply(self: *Screen, bytes: []const u8) void {
        if (self.reply_len + bytes.len > MAX_REPLY) return;
        @memcpy(self.reply_buf[self.reply_len..][0..bytes.len], bytes);
        self.reply_len += bytes.len;
    }

    fn replyPosition(self: *Screen) void {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{ self.cursor.row + 1, self.cursor.col + 1 }) catch return;
        self.reply(text);
    }

    fn print(self: *Screen, cp: u21) void {
        const grid = self.activeGrid();
        if (self.cursor.pending_wrap) {
            grid.wrapped[self.cursor.row] = true;
            self.cursor.col = 0;
            self.lineFeed();
        }
        grid.cells[self.cursor.row * self.cols + self.cursor.col] = cp;
        if (self.cursor.col + 1 >= self.cols) {
            self.cursor.pending_wrap = true;
        } else {
            self.cursor.col += 1;
        }
    }

    fn lineFeed(self: *Screen) void {
        self.cursor.pending_wrap = false;
        if (self.cursor.row == self.scroll_bottom) {
            self.scrollUp(1);
        } else if (self.cursor.row + 1 < self.rows) {
            self.cursor.row += 1;
        }
    }

    fn scrollUp(self: *Screen, count: usize) void {
        const grid = self.activeGrid();
        const keeps_history = !self.on_alt and self.scroll_top == 0;
        for (0..@min(count, self.scroll_bottom - self.scroll_top + 1)) |_| {
            if (keeps_history) self.pushHistory(grid, 0);
            self.shiftRows(grid, self.scroll_top, self.scroll_bottom, .up);
        }
    }

    fn scrollDown(self: *Screen, count: usize) void {
        const grid = self.activeGrid();
        for (0..@min(count, self.scroll_bottom - self.scroll_top + 1)) |_| {
            self.shiftRows(grid, self.scroll_top, self.scroll_bottom, .down);
        }
    }

    const Direction = enum { up, down };

    fn shiftRows(self: *Screen, grid: Grid, top: usize, bottom: usize, direction: Direction) void {
        const cols = self.cols;
        switch (direction) {
            .up => {
                std.mem.copyForwards(u21, grid.cells[top * cols .. bottom * cols], grid.cells[(top + 1) * cols .. (bottom + 1) * cols]);
                std.mem.copyForwards(bool, grid.wrapped[top..bottom], grid.wrapped[top + 1 .. bottom + 1]);
                self.clearRow(grid, bottom);
            },
            .down => {
                std.mem.copyBackwards(u21, grid.cells[(top + 1) * cols .. (bottom + 1) * cols], grid.cells[top * cols .. bottom * cols]);
                std.mem.copyBackwards(bool, grid.wrapped[top + 1 .. bottom + 1], grid.wrapped[top..bottom]);
                self.clearRow(grid, top);
            },
        }
    }

    fn clearRow(self: *Screen, grid: Grid, row: usize) void {
        @memset(self.rowSlice(grid, row), 0);
        grid.wrapped[row] = false;
    }

    fn pushHistory(self: *Screen, grid: Grid, row: usize) void {
        self.appendRow(self.alloc, &self.history, grid, row) catch return;
        if (!grid.wrapped[row]) self.history.append(self.alloc, '\n') catch return;
        self.trimHistory();
    }

    fn trimHistory(self: *Screen) void {
        const items = self.history.items;
        const slack = self.history_cap / 4;
        if (items.len <= self.history_cap + slack) return;
        var drop = items.len - self.history_cap;
        if (std.mem.indexOfScalarPos(u8, items, drop, '\n')) |newline| drop = newline + 1;
        self.history_dropped_lines += std.mem.count(u8, items[0..drop], "\n");
        const remaining = items.len - drop;
        std.mem.copyForwards(u8, items[0..remaining], items[drop..]);
        self.history.items.len = remaining;
    }

    fn eraseCells(self: *Screen, row: usize, from: usize, to: usize) void {
        if (from >= to) return;
        @memset(self.rowSlice(self.activeGrid(), row)[from..to], 0);
    }

    fn eraseLine(self: *Screen, mode: usize) void {
        const row = self.cursor.row;
        const col = self.cursor.col;
        switch (mode) {
            0 => self.eraseCells(row, col, self.cols),
            1 => self.eraseCells(row, 0, col + 1),
            2 => self.clearRow(self.activeGrid(), row),
            else => {},
        }
        if (mode != 1) self.activeGrid().wrapped[row] = false;
    }

    fn eraseDisplay(self: *Screen, mode: usize) void {
        const grid = self.activeGrid();
        const row = self.cursor.row;
        switch (mode) {
            0 => {
                self.eraseLine(0);
                for (row + 1..self.rows) |r| self.clearRow(grid, r);
            },
            1 => {
                for (0..row) |r| self.clearRow(grid, r);
                self.eraseLine(1);
            },
            2 => for (0..self.rows) |r| self.clearRow(grid, r),
            3 => {
                self.history.clearRetainingCapacity();
                self.history_dropped_lines = 0;
            },
            else => {},
        }
    }

    fn insertLines(self: *Screen, count: usize) void {
        const row = self.cursor.row;
        if (row < self.scroll_top or row > self.scroll_bottom) return;
        const grid = self.activeGrid();
        for (0..@min(count, self.scroll_bottom - row + 1)) |_| self.shiftRows(grid, row, self.scroll_bottom, .down);
        self.cursor.col = 0;
    }

    fn deleteLines(self: *Screen, count: usize) void {
        const row = self.cursor.row;
        if (row < self.scroll_top or row > self.scroll_bottom) return;
        const grid = self.activeGrid();
        for (0..@min(count, self.scroll_bottom - row + 1)) |_| self.shiftRows(grid, row, self.scroll_bottom, .up);
        self.cursor.col = 0;
    }

    fn insertChars(self: *Screen, count: usize) void {
        const cells = self.rowSlice(self.activeGrid(), self.cursor.row);
        const col = self.cursor.col;
        const shift = @min(count, cells.len - col);
        std.mem.copyBackwards(u21, cells[col + shift ..], cells[col .. cells.len - shift]);
        @memset(cells[col .. col + shift], 0);
    }

    fn deleteChars(self: *Screen, count: usize) void {
        const cells = self.rowSlice(self.activeGrid(), self.cursor.row);
        const col = self.cursor.col;
        const shift = @min(count, cells.len - col);
        std.mem.copyForwards(u21, cells[col .. cells.len - shift], cells[col + shift ..]);
        @memset(cells[cells.len - shift ..], 0);
    }

    fn eraseChars(self: *Screen, count: usize) void {
        self.eraseCells(self.cursor.row, self.cursor.col, @min(self.cursor.col +| count, self.cols));
    }
};
