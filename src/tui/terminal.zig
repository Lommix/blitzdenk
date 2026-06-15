const std = @import("std");
const posix = std.posix;
const buffer_mod = @import("buffer.zig");
const cell_mod = @import("cell.zig");
const rect_mod = @import("rect.zig");

pub const Buffer = buffer_mod.Buffer;
pub const Cell = cell_mod.Cell;
pub const Style = cell_mod.Style;
pub const Rect = rect_mod.Rect;

pub fn RingQueue(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buf: [capacity]T = undefined,
        head: usize = 0,
        tail: usize = 0,
        len: usize = 0,

        pub fn push(self: *Self, item: T) void {
            if (self.len == capacity) return;
            self.buf[self.tail] = item;
            self.tail = (self.tail + 1) % capacity;
            self.len += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            const item = self.buf[self.head];
            self.head = (self.head + 1) % capacity;
            self.len -= 1;
            return item;
        }
    };
}

pub const Terminal = struct {
    current: Buffer,
    previous: Buffer,
    original_termios: posix.termios,
    stdout: std.Io.File,
    io: std.Io,
    allocator: std.mem.Allocator,
    input_queue: RingQueue(Event, 64) = .{},
    last_size: Rect,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Terminal {
        const stdout = std.Io.File.stdout();
        const fd = stdout.handle;

        // Save original termios
        const original = try posix.tcgetattr(fd);

        // Enable raw mode
        var raw = original;
        // Input: disable break signal, CR->NL, parity, strip, flow control
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        // Output: disable post-processing
        raw.oflag.OPOST = false;
        // Control: 8-bit chars
        raw.cflag.CSIZE = .CS8;
        // Local: disable echo, canonical mode, signals, extended
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        // Read returns after 1 byte, no timeout
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;

        try posix.tcsetattr(fd, .FLUSH, raw);

        const rect = getSize(fd);

        var current = try Buffer.init(allocator, rect);
        var previous = try Buffer.init(allocator, rect);
        current.clear();
        previous.clear();

        // Enter alternate screen + hide cursor
        var buf: [64]u8 = undefined;
        var w = stdout.writerStreaming(io, &buf);
        w.interface.writeAll("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[?1006h\x1b[?2004h") catch {};
        w.interface.flush() catch {};

        return .{
            .current = current,
            .previous = previous,
            .original_termios = original,
            .stdout = stdout,
            .io = io,
            .allocator = allocator,
            .last_size = rect,
        };
    }

    pub fn deinit(self: *Terminal) void {
        // Show cursor + leave alternate screen
        var buf: [64]u8 = undefined;
        var w = self.stdout.writerStreaming(self.io, &buf);
        w.interface.writeAll("\x1b[?2004l\x1b[?1000l\x1b[?1006l\x1b[?25h\x1b[?1049l") catch {};
        w.interface.flush() catch {};

        // Restore original termios
        posix.tcsetattr(self.stdout.handle, .FLUSH, self.original_termios) catch {};

        self.current.deinit();
        self.previous.deinit();
    }

    fn getSize(fd: posix.fd_t) Rect {
        var wsz: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const rc = std.c.ioctl(fd, posix.T.IOCGWINSZ, &wsz);
        if (rc >= 0 and wsz.col > 0 and wsz.row > 0) {
            return .{ .x = 0, .y = 0, .width = @max(10, wsz.col), .height = @max(4, wsz.row) };
        }
        return .{ .x = 0, .y = 0, .width = 80, .height = 24 };
    }

    pub fn size(self: *Terminal) Rect {
        return getSize(self.stdout.handle);
    }

    /// Draw a frame. Calls render_fn to populate the buffer, then flushes only changed cells.
    pub fn draw(self: *Terminal, render_fn: *const fn (area: Rect, buf: *Buffer) void) !void {
        // Check for resize
        const rect = self.size();
        if (rect.width == 0 or rect.height == 0) return;
        if (rect.width != self.current.rect.width or rect.height != self.current.rect.height) {
            try self.current.resize(rect);
            try self.previous.resize(rect);
            // Clear terminal so stale content from the old layout is removed
            var clr_buf: [16]u8 = undefined;
            var clr_w = self.stdout.writerStreaming(self.io, &clr_buf);
            clr_w.interface.writeAll("\x1b[2J") catch {};
            clr_w.interface.flush() catch {};
        }

        self.current.clear();
        render_fn(rect, &self.current);
        try self.flush();

        // Swap: copy current into previous (length-safe in case of mid-frame resize)
        const copy_len = @min(self.previous.cells.len, self.current.cells.len);
        @memcpy(self.previous.cells[0..copy_len], self.current.cells[0..copy_len]);
    }

    /// Draw with a context value (avoids needing globals).
    pub fn drawWith(self: *Terminal, ctx: anytype, comptime render_fn: fn (@TypeOf(ctx), Rect, *Buffer) void) !void {
        const rect = self.size();
        if (rect.width == 0 or rect.height == 0) return;
        if (rect.width != self.current.rect.width or rect.height != self.current.rect.height) {
            try self.current.resize(rect);
            try self.previous.resize(rect);
            // Clear terminal so stale content from the old layout is removed
            var clr_buf: [16]u8 = undefined;
            var clr_w = self.stdout.writerStreaming(self.io, &clr_buf);
            clr_w.interface.writeAll("\x1b[2J") catch {};
            clr_w.interface.flush() catch {};
        }

        self.current.clear();
        render_fn(ctx, rect, &self.current);
        try self.flush();

        // Length-safe copy in case of mid-frame resize
        const copy_len = @min(self.previous.cells.len, self.current.cells.len);
        @memcpy(self.previous.cells[0..copy_len], self.current.cells[0..copy_len]);
    }

    pub const Modifiers = packed struct(u8) {
        ctrl: bool = false,
        alt: bool = false,
        shift: bool = false,
        _pad: u5 = 0,
    };

    pub const KeyCode = union(enum) {
        char: u8,
        enter,
        backspace,
        tab,
        esc,
        arrow_up,
        arrow_down,
        arrow_left,
        arrow_right,
        home,
        end,
        page_up,
        page_down,
        insert,
        delete,
        f1,
        f2,
        f3,
        f4,
        f5,
        f6,
        f7,
        f8,
        f9,
        f10,
        f11,
        f12,
    };

    pub const Key = struct {
        code: KeyCode,
        mods: Modifiers = .{},
        text: [4]u8 = @splat(0),
        text_len: u3 = 0,

        pub fn textSlice(self: *const Key) []const u8 {
            return self.text[0..self.text_len];
        }

        pub fn eql(self: Key, other: Key) bool {
            if (@as(std.meta.Tag(KeyCode), self.code) != @as(std.meta.Tag(KeyCode), other.code)) return false;
            switch (self.code) {
                .char => |c| if (c != other.code.char) return false,
                else => {},
            }
            return @as(u8, @bitCast(self.mods)) == @as(u8, @bitCast(other.mods));
        }
    };

    pub const Event = union(enum) {
        key: Key,
        paste: []const u8,
        wheel_up,
        wheel_down,
        resize: Rect,
        none,
    };

    fn decodeModParam(m: u8) Modifiers {
        // xterm modifier encoding: value = 1 + bitfield(shift=1, alt=2, ctrl=4, meta=8)
        if (m == 0) return .{};
        const bits = m - 1;
        return .{
            .shift = (bits & 0b001) != 0,
            .alt = (bits & 0b010) != 0,
            .ctrl = (bits & 0b100) != 0,
        };
    }

    fn keycodeForCsiLetter(c: u8) ?KeyCode {
        return switch (c) {
            'A' => .arrow_up,
            'B' => .arrow_down,
            'C' => .arrow_right,
            'D' => .arrow_left,
            'H' => .home,
            'F' => .end,
            'P' => .f1,
            'Q' => .f2,
            'R' => .f3,
            'S' => .f4,
            else => null,
        };
    }

    fn keycodeForTilde(n: u16) ?KeyCode {
        return switch (n) {
            2 => .insert,
            3 => .delete,
            5 => .page_up,
            6 => .page_down,
            11 => .f1,
            12 => .f2,
            13 => .f3,
            14 => .f4,
            15 => .f5,
            17 => .f6,
            18 => .f7,
            19 => .f8,
            20 => .f9,
            21 => .f10,
            23 => .f11,
            24 => .f12,
            else => null,
        };
    }

    var paste_buf: [1024]u8 = undefined;

    /// Poll stdin and enqueue all parsed events into the ring queue.
    pub fn pollAndEnqueue(self: *Terminal, timeout_ms: i32) void {
        const cur = self.size();
        if (cur.width != self.last_size.width or cur.height != self.last_size.height) {
            self.last_size = cur;
            self.input_queue.push(.{ .resize = cur });
        }

        const stdin_fd = std.Io.File.stdin().handle;
        var fds = [_]posix.pollfd{.{
            .fd = stdin_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};

        const ready = posix.poll(&fds, timeout_ms) catch return;
        if (ready == 0) return;

        var buf: [256]u8 = undefined;
        const n = posix.read(stdin_fd, &buf) catch return;
        if (n == 0) return;

        self.parseAndEnqueue(buf[0..n]);
    }

    /// Pop the next buffered event. Returns `.none` when the queue is empty.
    pub fn nextEvent(self: *Terminal) Event {
        return self.input_queue.pop() orelse .none;
    }

    fn pushKey(self: *Terminal, code: KeyCode, mods: Modifiers) void {
        var key = Key{ .code = code, .mods = mods };
        switch (code) {
            .char => |c| {
                key.text[0] = c;
                key.text_len = 1;
            },
            else => {},
        }
        self.input_queue.push(.{ .key = key });
    }

    fn pushKeyUtf8(self: *Terminal, cp: u21, mods: Modifiers) void {
        var key = Key{ .code = .{ .char = 0 }, .mods = mods };
        const len = std.unicode.utf8Encode(cp, &key.text) catch return;
        key.text_len = @intCast(len);
        self.input_queue.push(.{ .key = key });
    }

    /// Parse all events from a byte slice and push them onto the input queue.
    fn parseAndEnqueue(self: *Terminal, data: []const u8) void {
        var i: usize = 0;
        while (i < data.len) {
            // Bracket paste start: ESC [ 2 0 0 ~
            if (i + 6 <= data.len and data[i] == 0x1B and data[i + 1] == '[' and
                data[i + 2] == '2' and data[i + 3] == '0' and data[i + 4] == '0' and data[i + 5] == '~')
            {
                const event = readPaste(data[i + 6 ..]);
                self.input_queue.push(event);
                return; // paste consumes the rest
            }

            // SGR mouse: ESC [ <
            if (i + 4 <= data.len and data[i] == 0x1B and data[i + 1] == '[' and data[i + 2] == '<') {
                var j = i + 3;
                while (j < data.len and data[j] >= '0' and data[j] <= '9') : (j += 1) {}
                if (j >= data.len or data[j] != ';') {
                    i = j;
                    continue;
                }
                const btn = std.fmt.parseInt(u8, data[i + 3 .. j], 10) catch {
                    i = j;
                    continue;
                };
                while (j < data.len and data[j] != 'M' and data[j] != 'm') : (j += 1) {}
                if (j >= data.len) {
                    i = j;
                    continue;
                }
                j += 1; // consume 'M'/'m'
                if (btn == 64) self.input_queue.push(.wheel_up);
                if (btn == 65) self.input_queue.push(.wheel_down);
                i = j;
                continue;
            }

            // CSI sequences: ESC [ ...
            if (i + 2 <= data.len and data[i] == 0x1B and data[i + 1] == '[') {
                var j = i + 2;
                // collect params: digits and ';' (no intermediates handled)
                const params_start = j;
                while (j < data.len and ((data[j] >= '0' and data[j] <= '9') or data[j] == ';')) : (j += 1) {}
                if (j >= data.len) {
                    // incomplete — drop
                    i = data.len;
                    continue;
                }
                const final = data[j];
                const params = data[params_start..j];
                j += 1; // consume final byte

                if (final == '~') {
                    // ESC [ n ~ or ESC [ n ; m ~
                    var sc = std.mem.splitScalar(u8, params, ';');
                    const num_s = sc.next() orelse "";
                    const mod_s = sc.next();
                    const n = std.fmt.parseInt(u16, num_s, 10) catch {
                        i = j;
                        continue;
                    };
                    const m: u8 = if (mod_s) |s| (std.fmt.parseInt(u8, s, 10) catch 1) else 1;
                    if (keycodeForTilde(n)) |code| self.pushKey(code, decodeModParam(m));
                    i = j;
                    continue;
                }

                if (keycodeForCsiLetter(final)) |code| {
                    // ESC [ <letter> or ESC [ 1 ; m <letter>
                    var mods: Modifiers = .{};
                    if (params.len > 0) {
                        var sc = std.mem.splitScalar(u8, params, ';');
                        _ = sc.next(); // skip leading param (usually "1")
                        if (sc.next()) |mod_s| {
                            const m = std.fmt.parseInt(u8, mod_s, 10) catch 1;
                            mods = decodeModParam(m);
                        }
                    }
                    self.pushKey(code, mods);
                    i = j;
                    continue;
                }

                // unknown CSI — drop
                i = j;
                continue;
            }

            // SS3: ESC O <letter> for f1..f4
            if (i + 3 <= data.len and data[i] == 0x1B and data[i + 1] == 'O') {
                if (keycodeForCsiLetter(data[i + 2])) |code| self.pushKey(code, .{});
                i += 3;
                continue;
            }

            // Alt + printable: ESC <byte> or ESC <multi-byte UTF-8>
            if (i + 2 <= data.len and data[i] == 0x1B) {
                // Try multi-byte UTF-8 after ESC
                if (data[i + 1] >= 0xC0) {
                    const len = std.unicode.utf8ByteSequenceLength(data[i + 1]) catch {
                        i += 2;
                        continue;
                    };
                    if (i + 1 + len <= data.len) {
                        const cp = std.unicode.utf8Decode(data[i + 1 ..][0..len]) catch {
                            i += 2;
                            continue;
                        };
                        self.pushKeyUtf8(cp, .{ .alt = true });
                        i += 1 + len;
                        continue;
                    }
                }
                const b = data[i + 1];
                if (b >= 0x20 and b <= 0x7E) {
                    self.pushKey(.{ .char = b }, .{ .alt = true });
                    i += 2;
                    continue;
                }
                // unknown ESC + control — drop
                i += 2;
                continue;
            }

            // Lone ESC at end of buffer
            if (data[i] == 0x1B) {
                self.pushKey(.esc, .{});
                i += 1;
                continue;
            }

            // Multi-byte UTF-8 (0xC0+ is start of 2/3/4-byte sequence)
            if (data[i] >= 0xC0) {
                const len = std.unicode.utf8ByteSequenceLength(data[i]) catch {
                    i += 1;
                    continue;
                };
                if (i + len > data.len) {
                    i = data.len;
                    continue;
                }
                const cp = std.unicode.utf8Decode(data[i..][0..len]) catch {
                    i += 1;
                    continue;
                };
                self.pushKeyUtf8(cp, .{});
                i += len;
                continue;
            }

            // Single-byte events
            const b = data[i];
            switch (b) {
                0x0D => self.pushKey(.enter, .{}),
                0x09 => self.pushKey(.tab, .{}),
                0x7F => self.pushKey(.backspace, .{}),
                0x01...0x08, 0x0A...0x0C, 0x0E...0x1A => {
                    // ctrl+<letter>; map 0x01 -> 'a' .. 0x1A -> 'z'
                    self.pushKey(.{ .char = 'a' + b - 1 }, .{ .ctrl = true });
                },
                0x20...0x7E => self.pushKey(.{ .char = b }, .{}),
                else => {},
            }
            i += 1;
        }
    }

    /// Read paste content until bracket paste end sequence ESC [ 2 0 1 ~
    fn readPaste(initial: []const u8) Event {
        const end_seq = "\x1b[201~";
        var paste_len: usize = 0;

        for (initial) |b| {
            if (paste_len >= paste_buf.len) break;
            paste_buf[paste_len] = b;
            paste_len += 1;
        }

        // Check if end sequence was already in the initial data
        if (paste_len >= end_seq.len) {
            if (std.mem.eql(u8, paste_buf[paste_len - end_seq.len .. paste_len], end_seq)) {
                paste_len -= end_seq.len;
                return .{ .paste = paste_buf[0..paste_len] };
            }
        }

        const stdin_fd = std.Io.File.stdin().handle;
        while (paste_len < paste_buf.len) {
            var read_buf: [256]u8 = undefined;
            const nr = posix.read(stdin_fd, &read_buf) catch break;
            if (nr == 0) break;
            for (read_buf[0..nr]) |b| {
                if (paste_len >= paste_buf.len) break;
                paste_buf[paste_len] = b;
                paste_len += 1;
            }
            if (paste_len >= end_seq.len) {
                if (std.mem.eql(u8, paste_buf[paste_len - end_seq.len .. paste_len], end_seq)) {
                    paste_len -= end_seq.len;
                    return .{ .paste = paste_buf[0..paste_len] };
                }
            }
        }

        if (paste_len >= end_seq.len and std.mem.eql(u8, paste_buf[paste_len - end_seq.len .. paste_len], end_seq)) {
            paste_len -= end_seq.len;
        }
        return .{ .paste = paste_buf[0..paste_len] };
    }

    fn flush(self: *Terminal) !void {
        var write_buf: [8192]u8 = undefined;
        var w = self.stdout.writerStreaming(self.io, &write_buf);
        const writer = &w.interface;

        var last_x: u16 = 0xFFFF;
        var last_y: u16 = 0xFFFF;
        var last_style: ?Style = null;

        var it = self.current.diff(&self.previous);
        while (it.next()) |entry| {
            // Move cursor if not contiguous
            if (entry.y != last_y or entry.x != last_x + 1) {
                // ANSI cursor position is 1-based
                try writer.print("\x1b[{d};{d}H", .{ @as(u32, entry.y) + 1, @as(u32, entry.x) + 1 });
            }

            // Apply style if changed
            if (last_style == null or !entry.cell.style.eql(last_style.?)) {
                try entry.cell.style.writeAnsi(writer);
                last_style = entry.cell.style;
            }

            // Write the character (skip control chars that corrupt terminal positioning)
            const ch = entry.cell.char;
            if (ch < 0x20 or ch == 0x7F) {
                try writer.writeAll(" ");
            } else {
                var encode_buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(ch, &encode_buf) catch 1;
                try writer.writeAll(encode_buf[0..len]);
            }

            last_x = entry.x;
            last_y = entry.y;
        }

        // Reset style at end of frame
        try writer.writeAll("\x1b[0m");
        try writer.flush();
    }
};
