const std = @import("std");
const r = @import("root.zig");
const mermaid = @import("mermaid.zig");

// ── Syntax highlighting tables ──

const Entry = struct {
    keywords: []const []const u8,
    expressions: []const []const u8,
};

const LANG_ALIASES = std.StaticStringMap([]const u8).initComptime(.{
    .{ "zg", "zig" },
    .{ "rs", "rust" },
    .{ "py", "python" },
    .{ "javascript", "js" },
    .{ "mjs", "js" },
    .{ "cjs", "js" },
    .{ "typescript", "ts" },
    .{ "tsx", "ts" },
    .{ "golang", "go" },
    .{ "h", "c" },
    .{ "cpp", "c" },
    .{ "luau", "lua" },
    .{ "odn", "odin" },
});

const LANGS = std.StaticStringMap(Entry).initComptime(.{
    .{ "zig", Entry{
        .keywords = &.{ "fn", "struct", "enum", "union", "const", "var", "pub", "return", "comptime", "import", "defer", "errdefer", "test", "usingnamespace", "extern", "export", "packed", "inline", "noinline", "align", "linksection", "threadlocal", "allowzero", "volatile" },
        .expressions = &.{ "if", "else", "while", "for", "switch", "try", "catch", "and", "or", "orelse", "unreachable", "break", "continue" },
    } },
    .{ "rust", Entry{
        .keywords = &.{ "fn", "struct", "enum", "impl", "trait", "pub", "let", "mut", "const", "use", "mod", "return", "self", "Self", "where", "type", "static", "extern", "crate" },
        .expressions = &.{ "if", "else", "while", "for", "match", "loop", "break", "continue", "as", "in" },
    } },
    .{ "python", Entry{
        .keywords = &.{ "def", "class", "import", "from", "as", "pass", "return", "lambda", "global", "nonlocal", "with", "yield", "async", "await" },
        .expressions = &.{ "if", "elif", "else", "while", "for", "try", "except", "finally", "raise", "in", "not", "and", "or", "is" },
    } },
    .{ "js", Entry{
        .keywords = &.{ "function", "class", "const", "let", "var", "return", "import", "export", "default", "new", "this", "typeof", "instanceof", "async", "await", "yield" },
        .expressions = &.{ "if", "else", "while", "for", "switch", "case", "break", "continue", "try", "catch", "finally", "throw", "in", "of" },
    } },
    .{ "ts", Entry{
        .keywords = &.{ "function", "class", "const", "let", "var", "return", "import", "export", "default", "new", "this", "typeof", "instanceof", "async", "await", "yield", "type", "interface", "enum", "namespace" },
        .expressions = &.{ "if", "else", "while", "for", "switch", "case", "break", "continue", "try", "catch", "finally", "throw", "in", "of" },
    } },
    .{ "go", Entry{
        .keywords = &.{ "func", "package", "import", "var", "const", "type", "struct", "interface", "map", "chan", "return", "defer", "go" },
        .expressions = &.{ "if", "else", "for", "switch", "case", "break", "continue", "select", "range" },
    } },
    .{ "c", Entry{
        .keywords = &.{ "int", "char", "short", "long", "float", "double", "void", "struct", "union", "enum", "typedef", "static", "extern", "const", "volatile", "return", "sizeof" },
        .expressions = &.{ "if", "else", "while", "for", "switch", "case", "break", "continue", "goto", "do" },
    } },
    .{ "lua", Entry{
        .keywords = &.{ "function", "local", "end", "return", "nil", "true", "false", "self", "require", "module" },
        .expressions = &.{ "if", "then", "else", "elseif", "while", "for", "do", "repeat", "until", "break", "in", "and", "or", "not" },
    } },
    .{ "odin", Entry{
        .keywords = &.{ "package", "import", "proc", "struct", "union", "enum", "bit_set", "bit_field", "distinct", "using", "return", "defer", "when", "where", "map", "matrix", "dynamic", "context", "foreign" },
        .expressions = &.{ "if", "else", "for", "switch", "case", "break", "continue", "fallthrough", "do", "in", "not_in", "or_else", "or_return" },
    } },
});

fn findEntry(lang: []const u8) ?Entry {
    const canon = LANG_ALIASES.get(lang) orelse lang;
    return LANGS.get(canon);
}

fn matchWord(list: []const []const u8, word: []const u8) bool {
    for (list) |k| if (std.mem.eql(u8, k, word)) return true;
    return false;
}

pub const HighlightTheme = struct {
    heading: r.Style = .{ .fg = .bright_cyan, .modifier = .{ .bold = true } },
    bold: r.Style = .{ .modifier = .{ .bold = true } },
    italic: r.Style = .{ .modifier = .{ .italic = true } },
    inline_code: r.Style = .{ .fg = .bright_yellow },
    code_default: r.Style = .{ .fg = .bright_white },
    code_keyword: r.Style = .{ .fg = .yellow, .modifier = .{ .bold = true } },
    code_expression: r.Style = .{ .fg = .blue },
    code_string: r.Style = .{ .fg = .green },
    code_number: r.Style = .{ .fg = .yellow },
    code_comment: r.Style = .{ .fg = .{ .rgb = .{ .b = 100, .g = 100, .r = 100 } }, .modifier = .{ .italic = true } },
    list_marker: r.Style = .{ .fg = .cyan },
    quote: r.Style = .{ .fg = .bright_cyan, .modifier = .{ .italic = true } },
    hr: r.Style = .{ .fg = .bright_cyan },
    plain: r.Style = .{},
    mermaid: mermaid.Theme = .{},
};

/// Streaming markdown renderer. Feed bytes with `feed`, then drain with `next`
/// to get fully wrapped, styled lines at the configured width. `finish()`
/// flushes any trailing partial block.
pub const MarkdownStreamRenderer = struct {
    const Self = @This();

    pub const Mode = enum { markdown, code };

    const Result = union(enum) {
        span: r.Span,
        need_bytes,
        done,
    };

    alloc: std.mem.Allocator,
    gpa: std.mem.Allocator,
    width: u16,
    buffer: std.ArrayList(u8) = .empty,
    cursor: usize = 0, // parsed up to here
    mode: Mode = .markdown,
    theme: HighlightTheme = .{},
    mermaid_options: mermaid.Options = .{},
    done: bool = false,
    /// true once `finish()` is called — treat EOF as valid terminator for blocks.
    eof: bool = false,
    /// within a markdown line: position at line start (for block-level tokens) or mid-line.
    at_line_start: bool = true,
    /// owned copy of code block's lang tag — buffer may realloc so we can't slice it.
    code_lang_buf: [32]u8 = undefined,
    code_lang_len: u8 = 0,
    /// true while consuming the body of a heading or blockquote line.
    in_block: bool = false,
    /// style applied to plain runs inside the current block line.
    block_style: r.Style = .{},
    in_list: bool = false,
    list_indent: [16]u8 = undefined,
    list_indent_len: u8 = 0,
    pending_list_marker: bool = false,
    current: r.Line = .{},
    table_lines: std.ArrayList(r.Line) = .empty,
    pending: std.ArrayList(r.Line) = .empty,
    out_cursor: usize = 0,
    skip_newline: bool = false,

    pub fn init(alloc: std.mem.Allocator, width: u16) Self {
        return .{ .alloc = alloc, .gpa = alloc, .width = width, .mermaid_options = .{ .width = width } };
    }

    pub fn initWithTheme(alloc: std.mem.Allocator, width: u16, theme: HighlightTheme) Self {
        return .{ .alloc = alloc, .gpa = alloc, .width = width, .theme = theme, .mermaid_options = .{ .width = width, .theme = theme.mermaid } };
    }

    pub fn initWithOptions(gpa: std.mem.Allocator, alloc: std.mem.Allocator, width: u16, theme: HighlightTheme, options: mermaid.Options) Self {
        var mermaid_options = options;
        mermaid_options.width = width;
        mermaid_options.theme = theme.mermaid;
        return .{ .alloc = alloc, .gpa = gpa, .width = width, .theme = theme, .mermaid_options = mermaid_options };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit(self.alloc);
        if (self.current.spans.items.len > 0) self.current.deinit(self.alloc);
        for (self.table_lines.items) |*ln| ln.deinit(self.alloc);
        self.table_lines.deinit(self.alloc);
        var i = self.out_cursor;
        while (i < self.pending.items.len) : (i += 1) {
            self.pending.items[i].deinit(self.alloc);
        }
        self.pending.deinit(self.alloc);
    }

    /// Hand the internal byte buffer to the caller. After this, `deinit` is a
    /// no-op on the buffer, so previously-emitted span slices stay valid for
    /// as long as the returned ArrayList lives. Caller must eventually
    /// `.deinit(alloc)` it (same allocator used at `init`).
    pub fn detachBuffer(self: *Self) std.ArrayList(u8) {
        const out = self.buffer;
        self.buffer = .empty;
        return out;
    }

    pub fn feed(self: *Self, src: []const u8) !void {
        try self.buffer.appendSlice(self.alloc, src);
    }

    /// Mark end of input. Subsequent `next` may flush any remaining bytes.
    pub fn finish(self: *Self) void {
        self.eof = true;
    }

    pub fn next(self: *Self) !?r.Line {
        if (self.out_cursor < self.pending.items.len) {
            const line = self.pending.items[self.out_cursor];
            self.out_cursor += 1;
            return line;
        }
        if (self.done) return null;

        while (true) {
            switch (try self.consumeSpan()) {
                .done => {
                    self.done = true;
                    try self.flushCurrent();
                    try self.flushTable();
                    break;
                },
                .need_bytes => break,
                .span => |s| try self.onSpan(s),
            }
        }

        if (self.out_cursor < self.pending.items.len) {
            const line = self.pending.items[self.out_cursor];
            self.out_cursor += 1;
            return line;
        }
        return null;
    }

    fn onSpan(self: *Self, s: r.Span) !void {
        if (s.kind == .heading_h1 or s.kind == .heading_h2) {
            try self.flushCurrent();
            try self.flushTable();
            try self.emitHeadingLine(s);
            self.skip_newline = true;
            return;
        }
        if (s.kind == .horizontal_rule) {
            try self.flushCurrent();
            try self.flushTable();
            try self.emitHrLine(s);
            self.skip_newline = true;
            return;
        }
        if (std.mem.eql(u8, s.content, "\n")) {
            if (self.skip_newline) {
                self.skip_newline = false;
            } else {
                const had_content = self.current.spans.items.len > 0;
                try self.flushCurrent();
                if (!had_content) try self.pending.append(self.alloc, .{});
            }
            return;
        }
        try self.current.pushSpan(self.alloc, s);
    }

    fn flushCurrent(self: *Self) !void {
        if (self.current.spans.items.len == 0) return;
        const line = self.current;
        self.current = .{};
        try self.commitLine(line);
    }

    fn commitLine(self: *Self, line: r.Line) !void {
        if (r.widgets.tableLineKind(&line) != null) {
            var table_line = line;
            errdefer table_line.deinit(self.alloc);
            try self.table_lines.append(self.alloc, table_line);
            return;
        }
        try self.flushTable();
        var src = line;
        defer src.deinit(self.alloc);
        if (self.width == 0) {
            try cloneLineInto(self.alloc, &src, &self.pending);
        } else {
            try wrapLineInto(self.alloc, &src, self.width, &self.pending);
        }
    }

    fn flushTable(self: *Self) !void {
        if (self.table_lines.items.len == 0) return;
        const lines = self.table_lines.items;
        defer {
            for (self.table_lines.items) |*ln| ln.deinit(self.alloc);
            self.table_lines.clearRetainingCapacity();
        }
        if (self.width > 0 and lines.len >= 2 and r.widgets.tableLineKind(&lines[0]) == .row and r.widgets.tableLineKind(&lines[1]) == .separator) {
            try r.widgets.appendTableRows(self.alloc, lines, self.width, &self.pending);
            return;
        }
        for (lines) |*ln| {
            if (self.width == 0) try cloneLineInto(self.alloc, ln, &self.pending) else try wrapLineInto(self.alloc, ln, self.width, &self.pending);
        }
    }

    fn emitHeadingLine(self: *Self, span: r.Span) !void {
        const fill: u8 = if (span.kind == .heading_h1) '=' else '-';
        const sep = if (fill == '=') "====" else "----";
        const w: usize = self.width;

        var line = r.Line{ .style = span.style };
        errdefer line.deinit(self.alloc);
        try line.pushSpan(self.alloc, .{ .content = sep, .style = span.style });
        try line.pushSpan(self.alloc, span);
        try line.pushSpan(self.alloc, .{ .content = sep, .style = span.style });

        const used: usize = 8 + span.widthCols();
        if (w > used) {
            const fill_len = w - used;
            const fill_buf = try self.alloc.alloc(u8, fill_len);
            defer self.alloc.free(fill_buf);
            @memset(fill_buf, fill);
            try line.pushSpan(self.alloc, .{ .content = fill_buf, .style = span.style });
        }

        try self.pending.append(self.alloc, line);
    }

    fn emitHrLine(self: *Self, span: r.Span) !void {
        const w: usize = if (self.width == 0) 64 else self.width;

        var line = r.Line{ .style = span.style };
        errdefer line.deinit(self.alloc);
        const buf = try self.alloc.alloc(u8, w * 3);
        defer self.alloc.free(buf);
        for (0..w) |i| {
            buf[i * 3] = 0xE2;
            buf[i * 3 + 1] = 0x94;
            buf[i * 3 + 2] = 0x80;
        }
        try line.pushSpan(self.alloc, .{ .content = buf, .style = span.style });
        try self.pending.append(self.alloc, line);
    }

    fn consumeSpan(self: *Self) !Result {
        if (self.done) return .done;

        const buf = self.buffer.items;
        if (self.cursor >= buf.len) {
            if (self.eof) {
                self.done = true;
                return .done;
            }
            return .need_bytes;
        }

        switch (self.mode) {
            .markdown => return self.consumeMarkdown(),
            .code => return self.consumeCode(),
        }
    }

    // ── Markdown mode ──────────────────────────────────────────────────────

    fn consumeMarkdown(self: *Self) !Result {
        const buf = self.buffer.items;

        if (self.pending_list_marker) {
            self.pending_list_marker = false;
            return self.consumeListMarker();
        }

        if (self.at_line_start) {
            // Need a full line (or EOF) to decide block-level structure.
            const line_end = std.mem.indexOfScalarPos(u8, buf, self.cursor, '\n') orelse {
                if (!self.eof) return .need_bytes;
                const line = buf[self.cursor..];
                if (listMarkerAtLineStart(line)) |info| return self.startListItem(line, info);
                if (self.tryListContinuation(line)) |res| return res;
                if (line.len > 0 and line[0] == '#') {
                    var depth: usize = 0;
                    while (depth < line.len and depth < 6 and line[depth] == '#') depth += 1;
                    if (depth < line.len and line[depth] == ' ') return self.startHeading(line, buf.len, depth);
                }
                if (line.len >= 2 and line[0] == '>' and line[1] == ' ') return self.startQuote();
                if (isTableSeparatorLine(line)) {
                    self.cursor = buf.len;
                    self.at_line_start = true;
                    return .{ .span = .{ .content = line, .style = self.theme.hr, .kind = .table_separator } };
                }
                if (isTableRowLine(line)) {
                    self.cursor = buf.len;
                    self.at_line_start = true;
                    return .{ .span = .{ .content = line, .style = self.theme.plain, .kind = .table_row } };
                }
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len >= 3 and (allSameChar(trimmed, '-') or allSameChar(trimmed, '*') or allSameChar(trimmed, '_'))) {
                    self.cursor = buf.len;
                    self.at_line_start = true;
                    return .{ .span = .{ .content = line, .style = self.theme.hr, .kind = .horizontal_rule } };
                }
                return self.emitInlineRun(buf.len);
            };

            const line = buf[self.cursor..line_end];
            if (listMarkerAtLineStart(line)) |info| return self.startListItem(line, info);
            if (self.tryListContinuation(line)) |res| return res;

            if (isMermaidFenceLine(line)) return self.consumeMermaidBlock(line_end);

            // Fenced code block opener: ```lang
            if (std.mem.startsWith(u8, line, "```")) {
                const lang = std.mem.trim(u8, line[3..], " \t\r");
                const n = @min(lang.len, self.code_lang_buf.len);
                @memcpy(self.code_lang_buf[0..n], lang[0..n]);
                self.code_lang_len = @intCast(n);
                self.mode = .code;
                self.cursor = line_end + 1;
                self.at_line_start = true;
                // preserve the newline so the caller splits the preceding line from the code block
                return .{ .span = .{ .content = "\n", .style = self.theme.plain } };
            }

            // Horizontal rule: ---, ***, ___ (or more) alone on line.
            // Advance cursor *up to* (not past) the trailing '\n' so the next
            // consume() sees an empty line and emits the line break naturally.
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len >= 3 and (allSameChar(trimmed, '-') or allSameChar(trimmed, '*') or allSameChar(trimmed, '_'))) {
                self.cursor = line_end;
                self.at_line_start = true;
                return .{ .span = .{ .content = line, .style = self.theme.hr, .kind = .horizontal_rule } };
            }

            if (isTableSeparatorLine(line)) {
                self.cursor = line_end;
                self.at_line_start = true;
                return .{ .span = .{ .content = line, .style = self.theme.hr, .kind = .table_separator } };
            }

            if (isTableRowLine(line)) {
                self.cursor = line_end;
                self.at_line_start = true;
                return .{ .span = .{ .content = line, .style = self.theme.plain, .kind = .table_row } };
            }

            // Heading: # ... ######
            if (line.len > 0 and line[0] == '#') {
                var depth: usize = 0;
                while (depth < line.len and depth < 6 and line[depth] == '#') depth += 1;
                if (depth < line.len and line[depth] == ' ') return self.startHeading(line, line_end, depth);
            }

            // Blockquote: > text
            if (line.len >= 2 and line[0] == '>' and line[1] == ' ') return self.startQuote();

            // Empty line
            if (line.len == 0) {
                self.cursor = line_end + 1;
                self.at_line_start = true;
                return .{ .span = .{ .content = "\n", .style = self.theme.plain } };
            }

            self.at_line_start = false;
            return self.consumeInline();
        }

        return self.consumeInline();
    }

    fn consumeMermaidBlock(self: *Self, opener_line_end: usize) !Result {
        const buf = self.buffer.items;
        const content_start = opener_line_end + 1;
        var pos = content_start;
        var content_end: usize = buf.len;
        var found = false;

        while (pos < buf.len) {
            const nl = std.mem.indexOfScalarPos(u8, buf, pos, '\n') orelse buf.len;
            const line = buf[pos..nl];
            if (isClosingFenceLine(line)) {
                content_end = pos;
                found = true;
                break;
            }
            if (nl == buf.len) break;
            pos = nl + 1;
        }

        if (!found and !self.eof) return .need_bytes;
        if (!found) content_end = buf.len;

        const close_line_end = if (found)
            std.mem.indexOfScalarPos(u8, buf, content_end, '\n') orelse buf.len
        else
            buf.len;
        self.cursor = if (close_line_end < buf.len) close_line_end + 1 else buf.len;
        self.at_line_start = true;

        try self.flushCurrent();
        try self.flushTable();
        self.renderMermaid(buf[content_start..content_end]) catch |err| switch (err) {
            error.DiagramTooLarge => try self.appendRawMermaid(buf[content_start..content_end]),
            else => return err,
        };
        return .{ .span = .{ .content = "\n", .style = self.theme.plain } };
    }

    fn renderMermaid(self: *Self, source: []const u8) !void {
        var out: std.ArrayList(r.Line) = .empty;
        defer out.deinit(self.alloc);
        errdefer for (out.items) |*line| line.deinit(self.alloc);
        try mermaid.renderWithOptions(self.gpa, self.alloc, source, &out, self.mermaid_options);
        try self.pending.ensureUnusedCapacity(self.alloc, out.items.len);
        for (out.items) |line| self.pending.appendAssumeCapacity(line);
        out.items.len = 0;
    }

    fn appendRawMermaid(self: *Self, source: []const u8) !void {
        var it = std.mem.splitScalar(u8, source, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            var l = r.Line{};
            errdefer l.deinit(self.alloc);
            try l.pushSpan(self.alloc, .{ .content = line, .style = self.theme.mermaid.muted });
            try self.pending.append(self.alloc, l);
        }
    }

    fn startHeading(self: *Self, line: []const u8, line_end: usize, depth: usize) Result {
        if (depth <= 2) {
            self.cursor = line_end;
            self.at_line_start = true;
            return .{ .span = .{
                .content = line[depth + 1 ..],
                .style = self.theme.heading,
                .kind = if (depth == 1) .heading_h1 else .heading_h2,
            } };
        }
        self.cursor += depth + 1;
        self.at_line_start = false;
        self.in_block = true;
        self.block_style = .{ .fg = self.theme.heading.fg };
        return self.consumeInline();
    }

    fn startQuote(self: *Self) Result {
        self.cursor += 2;
        self.at_line_start = false;
        self.in_block = true;
        self.block_style = self.theme.quote;
        return .{ .span = .{ .content = "  │ ", .style = self.block_style } };
    }

    fn startListIndent(self: *Self, width: usize) void {
        const n = @min(width, self.list_indent.len);
        @memset(self.list_indent[0..n], ' ');
        self.list_indent_len = @intCast(n);
        self.in_list = true;
    }

    const ListMarkerInfo = struct {
        lead: usize,
        marker: usize,
        marker_cols: usize,
    };

    fn listMarkerAtLineStart(line: []const u8) ?ListMarkerInfo {
        var lead: usize = 0;
        while (lead < line.len and line[lead] == ' ') lead += 1;
        const rest = line[lead..];

        if (rest.len >= 2 and (rest[0] == '-' or rest[0] == '*') and rest[1] == ' ') {
            return .{ .lead = lead, .marker = 2, .marker_cols = 2 };
        }

        var i: usize = 0;
        while (i < rest.len and std.ascii.isDigit(rest[i])) i += 1;
        if (i > 0 and i + 1 < rest.len and rest[i] == '.' and rest[i + 1] == ' ') {
            return .{ .lead = lead, .marker = i + 2, .marker_cols = i + 2 };
        }

        return null;
    }

    fn markerContent(line: []const u8, info: ListMarkerInfo) []const u8 {
        const m = line[info.lead .. info.lead + info.marker];
        if (m.len >= 1 and (m[0] == '-' or m[0] == '*')) return "• ";
        return m;
    }

    fn startListItem(self: *Self, line: []const u8, info: ListMarkerInfo) Result {
        self.startListIndent(info.lead + info.marker_cols);
        if (info.lead > 0) {
            self.cursor += info.lead;
            self.at_line_start = false;
            self.pending_list_marker = true;
            return .{ .span = .{ .content = line[0..info.lead], .style = self.theme.plain } };
        }
        self.cursor += info.marker;
        self.at_line_start = false;
        return .{ .span = .{ .content = markerContent(line, info), .style = self.theme.list_marker } };
    }

    fn consumeListMarker(self: *Self) Result {
        const buf = self.buffer.items;
        const line = buf[self.cursor..];
        const info = listMarkerAtLineStart(line) orelse {
            self.at_line_start = false;
            return .{ .span = .{ .content = "", .style = self.theme.plain } };
        };
        self.cursor += info.marker;
        self.at_line_start = false;
        return .{ .span = .{ .content = markerContent(line, info), .style = self.theme.list_marker } };
    }

    fn tryListContinuation(self: *Self, line: []const u8) ?Result {
        if (!self.in_list) return null;
        if (self.listLineStartsNewBlock(line)) {
            self.in_list = false;
            self.list_indent_len = 0;
            return null;
        }

        var lead: usize = 0;
        while (lead < line.len and (line[lead] == ' ' or line[lead] == '\t')) lead += 1;
        self.cursor += lead;
        self.at_line_start = false;
        return .{ .span = .{ .content = self.list_indent[0..self.list_indent_len], .style = self.theme.plain } };
    }

    fn listLineStartsNewBlock(self: *const Self, line: []const u8) bool {
        _ = self;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) return true;
        if (line.len > 0 and line[0] == '#') {
            var depth: usize = 0;
            while (depth < line.len and depth < 6 and line[depth] == '#') depth += 1;
            if (depth < line.len and line[depth] == ' ') return true;
        }
        if (line.len >= 2 and line[0] == '>' and line[1] == ' ') return true;
        if (std.mem.startsWith(u8, line, "```")) return true;
        if (trimmed.len >= 3 and (allSameChar(trimmed, '-') or allSameChar(trimmed, '*') or allSameChar(trimmed, '_'))) return true;
        if (isTableSeparatorLine(line) or isTableRowLine(line)) return true;
        return false;
    }

    /// Emit the next inline segment (plain run up to next emphasis marker,
    /// or a styled run if we're sitting on a marker).
    fn consumeInline(self: *Self) Result {
        const buf = self.buffer.items;
        const cur = self.cursor;
        if (cur >= buf.len) {
            if (self.eof) {
                self.done = true;
                return .done;
            }
            return .need_bytes;
        }

        // End of line → emit newline, reset at_line_start for next block-level decision.
        if (buf[cur] == '\n') {
            self.in_block = false;
            self.block_style = .{};
            self.cursor = cur + 1;
            self.at_line_start = true;
            return .{ .span = .{ .content = "\n", .style = self.theme.plain } };
        }

        // Try emphasis at current position.
        if (self.tryEmphasis(cur)) |res| return res;

        const plain_style = if (self.in_block) self.block_style else self.theme.plain;

        // Scan plain run until next emphasis marker or newline.
        var end = cur;
        while (end < buf.len) : (end += 1) {
            const c = buf[end];
            if (c == '\n') break;
            if (c == '*' or c == '_' or c == '`') {
                // only break if this really opens a styled span
                if (self.peekEmphasis(end)) break;
            }
        }

        if (end == cur) {
            // Marker that didn't match — emit as single literal char to make progress.
            self.cursor = cur + 1;
            return .{ .span = .{ .content = buf[cur .. cur + 1], .style = plain_style } };
        }

        const slice = buf[cur..end];
        self.cursor = end;
        return .{ .span = .{ .content = slice, .style = plain_style } };
    }

    const EmphasisKind = enum { code, bold, italic };
    const EmphasisHit = struct {
        kind: EmphasisKind,
        open_len: usize, // bytes of the opening marker (1 or 2)
        close: usize, // index of first byte of the closing marker
    };

    /// Pure matcher: if `pos` begins an emphasis span that closes on the same
    /// line, return the hit. No state change. Used by both the committing
    /// (`tryEmphasis`) and peeking path of the plain-run scanner.
    fn matchEmphasis(self: *const Self, pos: usize) ?EmphasisHit {
        const buf = self.buffer.items;
        if (pos >= buf.len) return null;
        const c = buf[pos];

        if (c == '`') {
            const close = std.mem.indexOfScalarPos(u8, buf, pos + 1, '`') orelse return null;
            const nl = std.mem.indexOfScalarPos(u8, buf, pos + 1, '\n');
            if (nl) |n| if (n < close) return null;
            return .{ .kind = .code, .open_len = 1, .close = close };
        }
        if (c == '*' and pos + 1 < buf.len and buf[pos + 1] == '*') {
            const close = findDouble(buf, pos + 2, '*') orelse return null;
            const nl = std.mem.indexOfScalarPos(u8, buf, pos + 2, '\n');
            if (nl) |n| if (n < close) return null;
            return .{ .kind = .bold, .open_len = 2, .close = close };
        }
        if (c == '*' or c == '_') {
            const close = std.mem.indexOfScalarPos(u8, buf, pos + 1, c) orelse return null;
            if (close == pos + 1) return null; // empty
            const nl = std.mem.indexOfScalarPos(u8, buf, pos + 1, '\n');
            if (nl) |n| if (n < close) return null;
            return .{ .kind = .italic, .open_len = 1, .close = close };
        }
        return null;
    }

    /// Committing: consume the matched emphasis and produce its styled span.
    fn tryEmphasis(self: *Self, pos: usize) ?Result {
        const hit = self.matchEmphasis(pos) orelse return null;
        const buf = self.buffer.items;
        var style = switch (hit.kind) {
            .code => self.theme.inline_code,
            .bold => self.theme.bold,
            .italic => self.theme.italic,
        };
        if (self.in_block) style.fg = self.block_style.fg;
        self.cursor = hit.close + hit.open_len;
        return .{ .span = .{ .content = buf[pos + hit.open_len .. hit.close], .style = style } };
    }

    /// Peek without committing — used by the plain-run scanner to know when to stop.
    fn peekEmphasis(self: *const Self, pos: usize) bool {
        return self.matchEmphasis(pos) != null;
    }

    /// Fallback path when EOF hits mid-line: emit rest as plain span then done.
    fn emitInlineRun(self: *Self, end: usize) Result {
        const buf = self.buffer.items;
        if (self.cursor >= end) {
            self.done = true;
            return .done;
        }
        const slice = buf[self.cursor..end];
        self.cursor = end;
        const style = if (self.in_block) self.block_style else self.theme.plain;
        return .{ .span = .{ .content = slice, .style = style } };
    }

    // ── Code mode ──────────────────────────────────────────────────────────

    fn consumeCode(self: *Self) Result {
        const buf = self.buffer.items;
        if (self.cursor >= buf.len) {
            if (self.eof) {
                self.done = true;
                return .done;
            }
            return .need_bytes;
        }

        // Newline inside code block → emit \n.
        if (buf[self.cursor] == '\n') {
            self.cursor += 1;
            self.at_line_start = true;
            return .{ .span = .{ .content = "\n", .style = self.theme.code_default } };
        }

        // Closing fence: line starts with ```
        if (self.at_line_start and
            self.cursor + 3 <= buf.len and
            std.mem.eql(u8, buf[self.cursor..][0..3], "```"))
        {
            const line_end = std.mem.indexOfScalarPos(u8, buf, self.cursor, '\n') orelse buf.len;
            self.cursor = if (line_end < buf.len) line_end + 1 else line_end;
            self.mode = .markdown;
            self.code_lang_len = 0;
            self.at_line_start = true;
            // preserve newline separating the code block from the next markdown block
            return .{ .span = .{ .content = "\n", .style = self.theme.plain } };
        }
        self.at_line_start = false;

        return self.consumeCodeToken();
    }

    fn consumeCodeToken(self: *Self) Result {
        const buf = self.buffer.items;
        const start = self.cursor;
        const c = buf[start];

        // String literal: "..." or '...'
        if (c == '"' or c == '\'') {
            var i = start + 1;
            while (i < buf.len and buf[i] != c and buf[i] != '\n') : (i += 1) {
                if (buf[i] == '\\' and i + 1 < buf.len) i += 1;
            }
            if (i < buf.len and buf[i] == c) i += 1;
            self.cursor = i;
            return .{ .span = .{ .content = buf[start..i], .style = self.theme.code_string } };
        }

        // Line comment: // or #
        if (c == '/' and start + 1 < buf.len and buf[start + 1] == '/') {
            const line_end = std.mem.indexOfScalarPos(u8, buf, start, '\n') orelse buf.len;
            self.cursor = line_end;
            return .{ .span = .{ .content = buf[start..line_end], .style = self.theme.code_comment } };
        }
        if (c == '#' and isShellOrPyLang(self.codeLang())) {
            const line_end = std.mem.indexOfScalarPos(u8, buf, start, '\n') orelse buf.len;
            self.cursor = line_end;
            return .{ .span = .{ .content = buf[start..line_end], .style = self.theme.code_comment } };
        }

        // Number literal
        if (std.ascii.isDigit(c)) {
            var i = start;
            while (i < buf.len and (std.ascii.isDigit(buf[i]) or buf[i] == '.' or buf[i] == '_' or
                buf[i] == 'x' or buf[i] == 'X' or buf[i] == 'o' or buf[i] == 'b' or
                (buf[i] >= 'a' and buf[i] <= 'f') or (buf[i] >= 'A' and buf[i] <= 'F'))) : (i += 1)
            {}
            self.cursor = i;
            return .{ .span = .{ .content = buf[start..i], .style = self.theme.code_number } };
        }

        // Identifier / keyword
        if (isIdentStart(c)) {
            var i = start + 1;
            while (i < buf.len and isIdentCont(buf[i])) : (i += 1) {}
            self.cursor = i;
            const word = buf[start..i];
            const style = self.classifyCodeWord(word);
            return .{ .span = .{ .content = word, .style = style } };
        }

        // Punctuation / whitespace — emit single byte as default.
        self.cursor = start + 1;
        return .{ .span = .{ .content = buf[start .. start + 1], .style = self.theme.code_default } };
    }

    fn classifyCodeWord(self: *Self, word: []const u8) r.Style {
        const entry = findEntry(self.codeLang()) orelse return self.theme.code_default;
        if (matchWord(entry.keywords, word)) return self.theme.code_keyword;
        if (matchWord(entry.expressions, word)) return self.theme.code_expression;
        return self.theme.code_default;
    }

    fn codeLang(self: *const Self) []const u8 {
        return self.code_lang_buf[0..self.code_lang_len];
    }
};

// ── helpers ──

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentCont(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isShellOrPyLang(lang: []const u8) bool {
    return std.mem.eql(u8, lang, "py") or std.mem.eql(u8, lang, "python") or
        std.mem.eql(u8, lang, "sh") or std.mem.eql(u8, lang, "bash") or
        std.mem.eql(u8, lang, "fish") or std.mem.eql(u8, lang, "zsh");
}

fn allSameChar(s: []const u8, ch: u8) bool {
    for (s) |c| if (c != ch) return false;
    return s.len > 0;
}

fn isMermaidFenceLine(line: []const u8) bool {
    const t = std.mem.trimStart(u8, line, " \t");
    const needle = "```mermaid";
    if (!std.ascii.startsWithIgnoreCase(t, needle)) return false;
    return t.len == needle.len or t[needle.len] == ' ' or t[needle.len] == '\t';
}

fn isClosingFenceLine(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len < 3) return false;
    for (t) |ch| if (ch != '`') return false;
    return true;
}

fn isTableRowLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return false;
    return std.mem.count(u8, trimmed, "|") >= 2;
}

fn isTableSeparatorLine(line: []const u8) bool {
    if (!isTableRowLine(line)) return false;
    var cells = splitTableCells(line);
    var count: usize = 0;
    while (cells.next()) |cell_raw| {
        const cell = std.mem.trim(u8, cell_raw, " \t\r");
        if (!isTableSeparatorCell(cell)) return false;
        count += 1;
    }
    return count > 0;
}

fn isTableSeparatorCell(cell: []const u8) bool {
    if (cell.len < 3) return false;
    var dashes: usize = 0;
    for (cell, 0..) |c, i| switch (c) {
        '-' => dashes += 1,
        ':' => if (i != 0 and i != cell.len - 1) return false,
        else => return false,
    };
    return dashes >= 3;
}

const TableCellIter = struct {
    text: []const u8,
    pos: usize,
    end: usize,

    fn next(self: *TableCellIter) ?[]const u8 {
        if (self.pos > self.end) return null;
        const start = self.pos;
        const next_bar = std.mem.indexOfScalarPos(u8, self.text, start, '|') orelse self.end;
        self.pos = next_bar + 1;
        return self.text[start..next_bar];
    }
};

fn splitTableCells(line: []const u8) TableCellIter {
    var start: usize = 0;
    var end: usize = line.len;
    while (start < end and (line[start] == ' ' or line[start] == '\t')) start += 1;
    if (start < end and line[start] == '|') start += 1;
    while (end > start and (line[end - 1] == ' ' or line[end - 1] == '\t' or line[end - 1] == '\r')) end -= 1;
    if (end > start and line[end - 1] == '|') end -= 1;
    return .{ .text = line, .pos = start, .end = end };
}

/// Find the next occurrence of `cc` (a doubled char) starting at `from`.
fn findDouble(buf: []const u8, from: usize, c: u8) ?usize {
    var i = from;
    while (i + 1 < buf.len) : (i += 1) {
        if (buf[i] == c and buf[i + 1] == c) return i;
    }
    return null;
}

fn wrapLineInto(alloc: std.mem.Allocator, src: *const r.Line, width: usize, out: *std.ArrayList(r.Line)) !void {
    const indent = r.widgets.listMarkerIndent(src) orelse r.widgets.blockquoteIndent(src) orelse 0;
    if (indent > 0 and width > indent) try r.widgets.wrapLineIndented(alloc, src, width, indent, out) else try r.wrapLine(alloc, src, width, out);
}

fn cloneLineInto(alloc: std.mem.Allocator, src: *const r.Line, out: *std.ArrayList(r.Line)) !void {
    var copy = r.Line{ .style = src.style };
    errdefer copy.deinit(alloc);
    for (src.spans.items) |span| try copy.pushSpan(alloc, span);
    try out.append(alloc, copy);
}

// ── Tests ──

fn collectPlain(spans: []const r.Span, alloc: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (spans) |s| try out.appendSlice(alloc, s.content);
    return out.toOwnedSlice(alloc);
}

test "markdown: plain paragraph" {
    const alloc = std.testing.allocator;
    var hl = MarkdownStreamRenderer.init(alloc, 200);
    defer hl.deinit();

    try hl.feed("hello world\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (try hl.consumeSpan()) {
        .span => |s| try got.append(alloc, s),
        .need_bytes => unreachable,
        .done => break,
    };

    const joined = try collectPlain(got.items, alloc);
    defer alloc.free(joined);
    try std.testing.expectEqualStrings("hello world\n", joined);
}

test "markdown: bold inside sentence" {
    const alloc = std.testing.allocator;
    var hl = MarkdownStreamRenderer.init(alloc, 200);
    defer hl.deinit();

    try hl.feed("pre **bold** post\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (try hl.consumeSpan()) {
        .span => |s| try got.append(alloc, s),
        .need_bytes => unreachable,
        .done => break,
    };

    var found_bold = false;
    for (got.items) |s| {
        if (s.style.modifier.bold and std.mem.eql(u8, s.content, "bold")) found_bold = true;
    }
    try std.testing.expect(found_bold);
}

test "markdown: heading" {
    const alloc = std.testing.allocator;
    var hl = MarkdownStreamRenderer.init(alloc, 200);
    defer hl.deinit();

    try hl.feed("## Title\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (try hl.consumeSpan()) {
        .span => |s| try got.append(alloc, s),
        .need_bytes => unreachable,
        .done => break,
    };

    // H2 heading emits its title as a tagged span; the renderer decorates it.
    try std.testing.expect(got.items.len >= 2);
    try std.testing.expectEqualStrings("Title", got.items[0].content);
    try std.testing.expectEqual(r.Span.Kind.heading_h2, got.items[0].kind);
    try std.testing.expect(got.items[0].style.modifier.bold);
}

test "markdown: heading levels decorate and color" {
    const alloc = std.testing.allocator;
    var hl = MarkdownStreamRenderer.init(alloc, 200);
    defer hl.deinit();

    try hl.feed("# One\n### Three\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (try hl.consumeSpan()) {
        .span => |s| try got.append(alloc, s),
        .need_bytes => unreachable,
        .done => break,
    };

    const joined = try collectPlain(got.items, alloc);
    defer alloc.free(joined);
    try std.testing.expectEqualStrings("One\nThree\n", joined);

    var h1_bold = false;
    var h3_bold = false;
    var h3_colored = false;
    for (got.items) |s| {
        if (std.mem.eql(u8, s.content, "One") and s.kind == .heading_h1 and s.style.modifier.bold) h1_bold = true;
        if (std.mem.eql(u8, s.content, "Three")) {
            h3_bold = s.style.modifier.bold;
            h3_colored = s.style.fg != .reset;
        }
    }
    try std.testing.expect(h1_bold);
    try std.testing.expect(!h3_bold);
    try std.testing.expect(h3_colored);
}

test "markdown: blockquote indents with border and color" {
    const alloc = std.testing.allocator;
    var hl = MarkdownStreamRenderer.init(alloc, 200);
    defer hl.deinit();

    try hl.feed("> *quoted*\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (try hl.consumeSpan()) {
        .span => |s| try got.append(alloc, s),
        .need_bytes => unreachable,
        .done => break,
    };

    const joined = try collectPlain(got.items, alloc);
    defer alloc.free(joined);
    try std.testing.expectEqualStrings("  │ quoted\n", joined);

    const theme: HighlightTheme = .{};
    var saw_border = false;
    var saw_colored_body = false;
    for (got.items) |s| {
        if (std.mem.eql(u8, s.content, "  │ ") and std.meta.eql(s.style.fg, theme.quote.fg)) saw_border = true;
        if (std.mem.eql(u8, s.content, "quoted") and std.meta.eql(s.style.fg, theme.quote.fg)) saw_colored_body = true;
    }
    try std.testing.expect(saw_border);
    try std.testing.expect(saw_colored_body);
}

test "markdown: fenced zig code highlights keywords" {
    const alloc = std.testing.allocator;
    var hl = MarkdownStreamRenderer.init(alloc, 200);
    defer hl.deinit();

    try hl.feed("```zig\nfn foo() void {}\n```\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (try hl.consumeSpan()) {
        .span => |s| try got.append(alloc, s),
        .need_bytes => unreachable,
        .done => break,
    };

    // expect "fn" to be styled as keyword (fg magenta, bold)
    var found_fn = false;
    for (got.items) |s| {
        if (std.mem.eql(u8, s.content, "fn") and s.style.modifier.bold) found_fn = true;
    }
    try std.testing.expect(found_fn);
}

test "markdown: bullet list" {
    const alloc = std.testing.allocator;
    var hl = MarkdownStreamRenderer.init(alloc, 200);
    defer hl.deinit();

    try hl.feed("- apple\n- pear\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (try hl.consumeSpan()) {
        .span => |s| try got.append(alloc, s),
        .need_bytes => unreachable,
        .done => break,
    };

    var bullets: usize = 0;
    for (got.items) |s| {
        if (std.mem.eql(u8, s.content, "• ")) bullets += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), bullets);
}

test "markdown: list continuation carries indentation" {
    const alloc = std.testing.allocator;
    var hl = MarkdownStreamRenderer.init(alloc, 200);
    defer hl.deinit();

    try hl.feed("- foo\nbar\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (try hl.consumeSpan()) {
        .span => |s| try got.append(alloc, s),
        .need_bytes => unreachable,
        .done => break,
    };

    const joined = try collectPlain(got.items, alloc);
    defer alloc.free(joined);
    try std.testing.expectEqualStrings("• foo\n  bar\n", joined);

    var saw_indent = false;
    for (got.items) |s| {
        if (std.mem.eql(u8, s.content, "  ")) saw_indent = true;
    }
    try std.testing.expect(saw_indent);
}

test "markdown: numbered list continuation carries indentation" {
    const alloc = std.testing.allocator;
    var hl = MarkdownStreamRenderer.init(alloc, 200);
    defer hl.deinit();

    try hl.feed("1. foo\nbar\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (try hl.consumeSpan()) {
        .span => |s| try got.append(alloc, s),
        .need_bytes => unreachable,
        .done => break,
    };

    const joined = try collectPlain(got.items, alloc);
    defer alloc.free(joined);
    try std.testing.expectEqualStrings("1. foo\n   bar\n", joined);
}

test "markdown: nested bullet list keeps indentation" {
    const alloc = std.testing.allocator;
    var hl = MarkdownStreamRenderer.init(alloc, 200);
    defer hl.deinit();

    try hl.feed("- parent\n  - child\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (try hl.consumeSpan()) {
        .span => |s| try got.append(alloc, s),
        .need_bytes => unreachable,
        .done => break,
    };

    const joined = try collectPlain(got.items, alloc);
    defer alloc.free(joined);
    try std.testing.expectEqualStrings("• parent\n  • child\n", joined);
}

test "markdown: code fence preserves surrounding lines" {
    const alloc = std.testing.allocator;
    var hl = MarkdownStreamRenderer.init(alloc, 200);
    defer hl.deinit();

    try hl.feed("prose\n```zig\nfn foo() void {}\n```\ntail\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (try hl.consumeSpan()) {
        .span => |s| try got.append(alloc, s),
        .need_bytes => unreachable,
        .done => break,
    };

    // Count "\n" spans — expect at least 5 (after prose, after opener, after fn, after closer, after tail).
    var nl_count: usize = 0;
    for (got.items) |s| {
        if (std.mem.eql(u8, s.content, "\n")) nl_count += 1;
    }
    try std.testing.expect(nl_count >= 5);

    // "prose" and "tail" must both appear as spans.
    var saw_prose = false;
    var saw_tail = false;
    for (got.items) |s| {
        if (std.mem.eql(u8, s.content, "prose")) saw_prose = true;
        if (std.mem.eql(u8, s.content, "tail")) saw_tail = true;
    }
    try std.testing.expect(saw_prose);
    try std.testing.expect(saw_tail);
}

test "markdown: multiple fenced blocks close properly" {
    const alloc = std.testing.allocator;
    var hl = MarkdownStreamRenderer.init(alloc, 200);
    defer hl.deinit();

    try hl.feed("```zig\nfn a() void {}\n```\n## Rust\n```rust\nfn b() {}\n```\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (try hl.consumeSpan()) {
        .span => |s| try got.append(alloc, s),
        .need_bytes => unreachable,
        .done => break,
    };

    // H2 heading span must appear (proves we exited code mode).
    var saw_heading = false;
    // Fence markers must never appear as literal content.
    var saw_fence = false;
    for (got.items) |s| {
        if (std.mem.eql(u8, s.content, "Rust") and s.kind == .heading_h2) saw_heading = true;
        if (std.mem.indexOf(u8, s.content, "```") != null) saw_fence = true;
    }
    try std.testing.expect(saw_heading);
    try std.testing.expect(!saw_fence);
}

test "markdown: partial input returns need_bytes then completes" {
    const alloc = std.testing.allocator;
    var hl = MarkdownStreamRenderer.init(alloc, 200);
    defer hl.deinit();

    // Feed partial line (no newline yet).
    try hl.feed("hello **wor");

    // should yield need_bytes on at_line_start peek (no \n available)
    const first = try hl.consumeSpan();
    try std.testing.expect(first == .need_bytes);

    // Feed rest.
    try hl.feed("ld**\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (try hl.consumeSpan()) {
        .span => |s| try got.append(alloc, s),
        .need_bytes => break, // no more bytes — shouldn't happen after finish
        .done => break,
    };

    var found_bold = false;
    for (got.items) |s| {
        if (s.style.modifier.bold and std.mem.eql(u8, s.content, "world")) found_bold = true;
    }
    try std.testing.expect(found_bold);
}

test "markdown: tab bytes survive code block (expanded at render time)" {
    const alloc = std.testing.allocator;
    var hl = MarkdownStreamRenderer.init(alloc, 200);
    defer hl.deinit();

    try hl.feed("```zig\n\tfn x() void {}\n```\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (try hl.consumeSpan()) {
        .span => |s| try got.append(alloc, s),
        .need_bytes => unreachable,
        .done => break,
    };

    // Indentation must be preserved as a literal \t in the emitted spans —
    // the widget renderer expands it to spaces; highlighter must not drop it.
    var saw_tab = false;
    for (got.items) |s| {
        if (std.mem.indexOfScalar(u8, s.content, '\t') != null) saw_tab = true;
    }
    try std.testing.expect(saw_tab);
}

test "markdown: horizontal rule emits dashes then newline" {
    const alloc = std.testing.allocator;
    const markers = [_][]const u8{ "---", "***", "___" };
    for (markers) |marker| {
        var hl = MarkdownStreamRenderer.init(alloc, 200);
        defer hl.deinit();

        const input = try std.fmt.allocPrint(alloc, "a\n{s}\nb\n", .{marker});
        defer alloc.free(input);
        try hl.feed(input);
        hl.finish();

        var got: std.ArrayList(r.Span) = .empty;
        defer got.deinit(alloc);
        while (true) switch (try hl.consumeSpan()) {
            .span => |s| try got.append(alloc, s),
            .need_bytes => unreachable,
            .done => break,
        };

        // The HR span precedes a standalone "\n" span (from the empty-line path
        // that replaces the old pending_newline mechanism).
        var hr_idx: ?usize = null;
        for (got.items, 0..) |s, i| {
            if (s.kind == .horizontal_rule) {
                hr_idx = i;
                break;
            }
        }
        try std.testing.expect(hr_idx != null);
        try std.testing.expect(hr_idx.? + 1 < got.items.len);
        try std.testing.expectEqualStrings("\n", got.items[hr_idx.? + 1].content);
    }
}

test "markdown: table rows are tagged" {
    const alloc = std.testing.allocator;
    var hl = MarkdownStreamRenderer.init(alloc, 200);
    defer hl.deinit();

    try hl.feed("| Name | Value |\n| :--- | ---: |\n| a | 1 |\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (try hl.consumeSpan()) {
        .span => |s| try got.append(alloc, s),
        .need_bytes => unreachable,
        .done => break,
    };

    var rows: usize = 0;
    var seps: usize = 0;
    for (got.items) |s| switch (s.kind) {
        .table_row => rows += 1,
        .table_separator => seps += 1,
        .text, .heading_h1, .heading_h2, .horizontal_rule => {},
    };
    try std.testing.expectEqual(@as(usize, 2), rows);
    try std.testing.expectEqual(@as(usize, 1), seps);
}

test "markdown: final table row without newline is tagged" {
    const alloc = std.testing.allocator;
    var hl = MarkdownStreamRenderer.init(alloc, 200);
    defer hl.deinit();

    try hl.feed("| Name | Value |\n| --- | --- |\n| a | 1 |");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (try hl.consumeSpan()) {
        .span => |s| try got.append(alloc, s),
        .need_bytes => unreachable,
        .done => break,
    };

    try std.testing.expect(got.items.len > 0);
    try std.testing.expectEqual(r.Span.Kind.table_row, got.items[got.items.len - 1].kind);
}

fn drainLines(rdr: *MarkdownStreamRenderer, alloc: std.mem.Allocator) !std.ArrayList(r.Line) {
    var out: std.ArrayList(r.Line) = .empty;
    errdefer {
        for (out.items) |*l| l.deinit(alloc);
        out.deinit(alloc);
    }
    while (try rdr.next()) |line| try out.append(alloc, line);
    return out;
}

test "renderer: plain paragraph wraps to width" {
    const alloc = std.testing.allocator;
    var renderer = MarkdownStreamRenderer.init(alloc, 11);
    defer renderer.deinit();
    try renderer.feed("hello world foo bar baz\n");
    renderer.finish();

    var lines = try drainLines(&renderer, alloc);
    defer {
        for (lines.items) |*l| l.deinit(alloc);
        lines.deinit(alloc);
    }

    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    const first = try r.widgets.lineText(alloc, &lines.items[0]);
    defer alloc.free(first);
    const second = try r.widgets.lineText(alloc, &lines.items[1]);
    defer alloc.free(second);
    try std.testing.expectEqualStrings("hello world", first);
    try std.testing.expectEqualStrings("foo bar baz", second);
}

test "renderer: blank lines are preserved" {
    const alloc = std.testing.allocator;
    var renderer = MarkdownStreamRenderer.init(alloc, 200);
    defer renderer.deinit();
    try renderer.feed("a\n\nb\n");
    renderer.finish();

    var lines = try drainLines(&renderer, alloc);
    defer {
        for (lines.items) |*l| l.deinit(alloc);
        lines.deinit(alloc);
    }

    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqual(@as(usize, 0), lines.items[1].spans.items.len);
}

test "renderer: list wrap keeps indentation" {
    const alloc = std.testing.allocator;
    var renderer = MarkdownStreamRenderer.init(alloc, 11);
    defer renderer.deinit();
    try renderer.feed("- hello world foo bar baz\n");
    renderer.finish();

    var lines = try drainLines(&renderer, alloc);
    defer {
        for (lines.items) |*l| l.deinit(alloc);
        lines.deinit(alloc);
    }

    try std.testing.expect(lines.items.len > 1);
    try std.testing.expectEqualStrings("  ", lines.items[1].spans.items[0].content);
}

test "renderer: blockquote wrap keeps indentation" {
    const alloc = std.testing.allocator;
    var renderer = MarkdownStreamRenderer.init(alloc, 11);
    defer renderer.deinit();
    try renderer.feed("> hello world foo bar baz\n");
    renderer.finish();

    var lines = try drainLines(&renderer, alloc);
    defer {
        for (lines.items) |*l| l.deinit(alloc);
        lines.deinit(alloc);
    }

    try std.testing.expect(lines.items.len > 1);
    try std.testing.expectEqualStrings("    ", lines.items[1].spans.items[0].content);
}

test "renderer: table renders full width" {
    const alloc = std.testing.allocator;
    var renderer = MarkdownStreamRenderer.init(alloc, 20);
    defer renderer.deinit();
    try renderer.feed("| Name | Value |\n| --- | --- |\n| a | 1 |\n");
    renderer.finish();

    var lines = try drainLines(&renderer, alloc);
    defer {
        for (lines.items) |*l| l.deinit(alloc);
        lines.deinit(alloc);
    }

    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    const header = try r.widgets.lineText(alloc, &lines.items[0]);
    defer alloc.free(header);
    try std.testing.expectEqualStrings("│ Name    │ Value  │", header);

    const rule = try r.widgets.lineText(alloc, &lines.items[1]);
    defer alloc.free(rule);
    var want_rule: [60]u8 = undefined;
    var ri: usize = 0;
    while (ri < want_rule.len) : (ri += 3) {
        want_rule[ri] = 0xE2;
        want_rule[ri + 1] = 0x94;
        want_rule[ri + 2] = 0x80;
    }
    try std.testing.expectEqualStrings(want_rule[0..], rule);

    const body = try r.widgets.lineText(alloc, &lines.items[2]);
    defer alloc.free(body);
    try std.testing.expectEqualStrings("│ a       │ 1      │", body);
}

test "renderer: horizontal rule fills width" {
    const alloc = std.testing.allocator;
    var renderer = MarkdownStreamRenderer.init(alloc, 20);
    defer renderer.deinit();
    try renderer.feed("---\n");
    renderer.finish();

    var lines = try drainLines(&renderer, alloc);
    defer {
        for (lines.items) |*l| l.deinit(alloc);
        lines.deinit(alloc);
    }

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    const rule = try r.widgets.lineText(alloc, &lines.items[0]);
    defer alloc.free(rule);
    var want: [60]u8 = undefined;
    var i: usize = 0;
    while (i < want.len) : (i += 3) {
        want[i] = 0xE2;
        want[i + 1] = 0x94;
        want[i + 2] = 0x80;
    }
    try std.testing.expectEqualStrings(want[0..], rule);
}

test "renderer: mermaid fence renders diagram instead of raw fence" {
    const alloc = std.testing.allocator;
    var renderer = MarkdownStreamRenderer.init(alloc, 40);
    defer renderer.deinit();
    try renderer.feed("before\n```mermaid\ngraph TD\nA[Alpha] --> B[Beta]\n```\nafter\n");
    renderer.finish();

    var lines = try drainLines(&renderer, alloc);
    defer {
        for (lines.items) |*l| l.deinit(alloc);
        lines.deinit(alloc);
    }

    var saw_before = false;
    var saw_after = false;
    var saw_alpha = false;
    var saw_raw_fence = false;
    for (lines.items) |*l| {
        const text = try r.widgets.lineText(alloc, l);
        defer alloc.free(text);
        if (std.mem.indexOf(u8, text, "before") != null) saw_before = true;
        if (std.mem.indexOf(u8, text, "after") != null) saw_after = true;
        if (std.mem.indexOf(u8, text, "Alpha") != null) saw_alpha = true;
        if (std.mem.indexOf(u8, text, "```mermaid") != null) saw_raw_fence = true;
    }
    try std.testing.expect(saw_before);
    try std.testing.expect(saw_after);
    try std.testing.expect(saw_alpha);
    try std.testing.expect(!saw_raw_fence);
}

test "mermaid fence detection requires word boundary" {
    try std.testing.expect(isMermaidFenceLine("```mermaid"));
    try std.testing.expect(isMermaidFenceLine(" ```mermaid "));
    try std.testing.expect(!isMermaidFenceLine("```mermaidjs"));
    try std.testing.expect(!isMermaidFenceLine("```mermaid_viz"));
    try std.testing.expect(isClosingFenceLine(" ``` "));
    try std.testing.expect(isClosingFenceLine("````"));
    try std.testing.expect(!isClosingFenceLine("```not-a-close"));
}

test "renderer: table flushes before mermaid diagram" {
    const alloc = std.testing.allocator;
    var renderer = MarkdownStreamRenderer.init(alloc, 40);
    defer renderer.deinit();
    try renderer.feed("| Name |\n|---|\n| row |\n```mermaid\ngraph TD\nA[Alpha] --> B[Beta]\n```\n");
    renderer.finish();

    var lines = try drainLines(&renderer, alloc);
    defer {
        for (lines.items) |*l| l.deinit(alloc);
        lines.deinit(alloc);
    }

    var name_idx: ?usize = null;
    var alpha_idx: ?usize = null;
    for (lines.items, 0..) |*l, i| {
        const text = try r.widgets.lineText(alloc, l);
        defer alloc.free(text);
        if (name_idx == null and std.mem.indexOf(u8, text, "Name") != null) name_idx = i;
        if (alpha_idx == null and std.mem.indexOf(u8, text, "Alpha") != null) alpha_idx = i;
    }
    try std.testing.expect(name_idx != null);
    try std.testing.expect(alpha_idx != null);
    try std.testing.expect(name_idx.? < alpha_idx.?);
}

fn markdownMermaidAllocationFailureCase(alloc: std.mem.Allocator) !void {
    var renderer = MarkdownStreamRenderer.init(alloc, 32);
    defer renderer.deinit();
    try renderer.feed("before\n```mermaid\nflowchart TD\nA[Alpha beta gamma] --> B[Beta]\n```\nafter\n");
    renderer.finish();
    while (try renderer.next()) |value| {
        var line = value;
        line.deinit(alloc);
    }
}

test "renderer: mermaid ownership survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, markdownMermaidAllocationFailureCase, .{});
}
