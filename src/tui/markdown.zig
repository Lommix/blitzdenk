const std = @import("std");
const r = @import("root.zig");

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
};

/// Streaming markdown highlighter. Feed bytes with `feed`, then drain with
/// `consume` until it returns `.need_bytes` or `.done`. `finish()` flushes any
/// trailing partial block.
///
/// Span slices returned by `consume` reference the internal buffer and are
/// valid until the next `feed` or `deinit`. Caller must copy out the content
/// before feeding more bytes.
pub const MarkdownStreamingHighlighter = struct {
    const Self = @This();

    pub const Mode = enum { markdown, code };

    pub const Result = union(enum) {
        span: r.Span,
        need_bytes,
        done,
    };

    alloc: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    cursor: usize = 0, // parsed up to here
    mode: Mode = .markdown,
    theme: HighlightTheme = .{},
    done: bool = false,
    /// true once `finish()` is called — treat EOF as valid terminator for blocks.
    eof: bool = false,
    /// within a markdown line: position at line start (for block-level tokens) or mid-line.
    at_line_start: bool = true,
    /// owned copy of code block's lang tag — buffer may realloc so we can't slice it.
    code_lang_buf: [32]u8 = undefined,
    code_lang_len: u8 = 0,

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit(self.alloc);
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

    /// Mark end of input. Subsequent `consume` may flush any remaining bytes.
    pub fn finish(self: *Self) void {
        self.eof = true;
    }

    pub fn consume(self: *Self) Result {
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

    fn consumeMarkdown(self: *Self) Result {
        const buf = self.buffer.items;

        if (self.at_line_start) {
            // Need a full line (or EOF) to decide block-level structure.
            const line_end = std.mem.indexOfScalarPos(u8, buf, self.cursor, '\n') orelse {
                if (!self.eof) return .need_bytes;
                const line = buf[self.cursor..];
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
                return self.emitInlineRun(buf.len);
            };

            const line = buf[self.cursor..line_end];

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

            // Horizontal rule: --- (or more) alone on line.
            // Advance cursor *up to* (not past) the trailing '\n' so the next
            // consume() sees an empty line and emits the line break naturally.
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len >= 3 and allSameChar(trimmed, '-')) {
                self.cursor = line_end;
                self.at_line_start = true;
                const dashes = "────────────────────────────────────────────────────────────────";
                return .{ .span = .{ .content = dashes, .style = self.theme.hr } };
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
                if (depth < line.len and line[depth] == ' ') {
                    // emit heading prefix span ("# ", "## ", etc.) then inline remainder.
                    const prefix = line[0 .. depth + 1];
                    self.cursor += prefix.len;
                    self.at_line_start = false;
                    return .{ .span = .{ .content = prefix, .style = self.theme.heading } };
                }
            }

            // Blockquote: > text
            if (line.len >= 2 and line[0] == '>' and line[1] == ' ') {
                self.cursor += 2;
                self.at_line_start = false;
                return .{ .span = .{ .content = "│ ", .style = self.theme.quote } };
            }

            // Bullet list: "- " or "* "
            if (line.len >= 2 and (line[0] == '-' or line[0] == '*') and line[1] == ' ') {
                self.cursor += 2;
                self.at_line_start = false;
                return .{ .span = .{ .content = "• ", .style = self.theme.list_marker } };
            }

            // Numbered list: "N. " or "NN. "
            {
                var i: usize = 0;
                while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
                if (i > 0 and i + 1 < line.len and line[i] == '.' and line[i + 1] == ' ') {
                    const prefix = line[0 .. i + 2];
                    self.cursor += prefix.len;
                    self.at_line_start = false;
                    return .{ .span = .{ .content = prefix, .style = self.theme.list_marker } };
                }
            }

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
            self.cursor = cur + 1;
            self.at_line_start = true;
            return .{ .span = .{ .content = "\n", .style = self.theme.plain } };
        }

        // Try emphasis at current position.
        if (self.tryEmphasis(cur)) |res| return res;

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
            return .{ .span = .{ .content = buf[cur .. cur + 1], .style = self.theme.plain } };
        }

        const slice = buf[cur..end];
        self.cursor = end;
        return .{ .span = .{ .content = slice, .style = self.theme.plain } };
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
        const style = switch (hit.kind) {
            .code => self.theme.inline_code,
            .bold => self.theme.bold,
            .italic => self.theme.italic,
        };
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
        return .{ .span = .{ .content = slice, .style = self.theme.plain } };
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

// ── Tests ──

fn collectPlain(spans: []const r.Span, alloc: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (spans) |s| try out.appendSlice(alloc, s.content);
    return out.toOwnedSlice(alloc);
}

test "markdown: plain paragraph" {
    const alloc = std.testing.allocator;
    var hl = MarkdownStreamingHighlighter.init(alloc);
    defer hl.deinit();

    try hl.feed("hello world\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (hl.consume()) {
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
    var hl = MarkdownStreamingHighlighter.init(alloc);
    defer hl.deinit();

    try hl.feed("pre **bold** post\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (hl.consume()) {
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
    var hl = MarkdownStreamingHighlighter.init(alloc);
    defer hl.deinit();

    try hl.feed("## Title\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (hl.consume()) {
        .span => |s| try got.append(alloc, s),
        .need_bytes => unreachable,
        .done => break,
    };

    // first span: "## " with heading style
    try std.testing.expect(got.items.len >= 2);
    try std.testing.expectEqualStrings("## ", got.items[0].content);
    try std.testing.expect(got.items[0].style.modifier.bold);
}

test "markdown: fenced zig code highlights keywords" {
    const alloc = std.testing.allocator;
    var hl = MarkdownStreamingHighlighter.init(alloc);
    defer hl.deinit();

    try hl.feed("```zig\nfn foo() void {}\n```\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (hl.consume()) {
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
    var hl = MarkdownStreamingHighlighter.init(alloc);
    defer hl.deinit();

    try hl.feed("- apple\n- pear\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (hl.consume()) {
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

test "markdown: code fence preserves surrounding lines" {
    const alloc = std.testing.allocator;
    var hl = MarkdownStreamingHighlighter.init(alloc);
    defer hl.deinit();

    try hl.feed("prose\n```zig\nfn foo() void {}\n```\ntail\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (hl.consume()) {
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
    var hl = MarkdownStreamingHighlighter.init(alloc);
    defer hl.deinit();

    try hl.feed("```zig\nfn a() void {}\n```\n## Rust\n```rust\nfn b() {}\n```\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (hl.consume()) {
        .span => |s| try got.append(alloc, s),
        .need_bytes => unreachable,
        .done => break,
    };

    // Heading prefix "## " must appear (proves we exited code mode).
    var saw_heading = false;
    // Fence markers must never appear as literal content.
    var saw_fence = false;
    for (got.items) |s| {
        if (std.mem.eql(u8, s.content, "## ")) saw_heading = true;
        if (std.mem.indexOf(u8, s.content, "```") != null) saw_fence = true;
    }
    try std.testing.expect(saw_heading);
    try std.testing.expect(!saw_fence);
}

test "markdown: partial input returns need_bytes then completes" {
    const alloc = std.testing.allocator;
    var hl = MarkdownStreamingHighlighter.init(alloc);
    defer hl.deinit();

    // Feed partial line (no newline yet).
    try hl.feed("hello **wor");

    // should yield need_bytes on at_line_start peek (no \n available)
    const first = hl.consume();
    try std.testing.expect(first == .need_bytes);

    // Feed rest.
    try hl.feed("ld**\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (hl.consume()) {
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
    var hl = MarkdownStreamingHighlighter.init(alloc);
    defer hl.deinit();

    try hl.feed("```zig\n\tfn x() void {}\n```\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (hl.consume()) {
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
    var hl = MarkdownStreamingHighlighter.init(alloc);
    defer hl.deinit();

    try hl.feed("a\n---\nb\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (hl.consume()) {
        .span => |s| try got.append(alloc, s),
        .need_bytes => unreachable,
        .done => break,
    };

    // The HR span precedes a standalone "\n" span (from the empty-line path
    // that replaces the old pending_newline mechanism).
    const theme: HighlightTheme = .{};
    var hr_idx: ?usize = null;
    for (got.items, 0..) |s, i| {
        if (std.meta.eql(s.style.fg, theme.hr.fg) and s.content.len > 3) {
            hr_idx = i;
            break;
        }
    }
    try std.testing.expect(hr_idx != null);
    try std.testing.expect(hr_idx.? + 1 < got.items.len);
    try std.testing.expectEqualStrings("\n", got.items[hr_idx.? + 1].content);
}

test "markdown: table rows are tagged" {
    const alloc = std.testing.allocator;
    var hl = MarkdownStreamingHighlighter.init(alloc);
    defer hl.deinit();

    try hl.feed("| Name | Value |\n| :--- | ---: |\n| a | 1 |\n");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (hl.consume()) {
        .span => |s| try got.append(alloc, s),
        .need_bytes => unreachable,
        .done => break,
    };

    var rows: usize = 0;
    var seps: usize = 0;
    for (got.items) |s| switch (s.kind) {
        .table_row => rows += 1,
        .table_separator => seps += 1,
        .text => {},
    };
    try std.testing.expectEqual(@as(usize, 2), rows);
    try std.testing.expectEqual(@as(usize, 1), seps);
}

test "markdown: final table row without newline is tagged" {
    const alloc = std.testing.allocator;
    var hl = MarkdownStreamingHighlighter.init(alloc);
    defer hl.deinit();

    try hl.feed("| Name | Value |\n| --- | --- |\n| a | 1 |");
    hl.finish();

    var got: std.ArrayList(r.Span) = .empty;
    defer got.deinit(alloc);
    while (true) switch (hl.consume()) {
        .span => |s| try got.append(alloc, s),
        .need_bytes => unreachable,
        .done => break,
    };

    try std.testing.expect(got.items.len > 0);
    try std.testing.expectEqual(r.Span.Kind.table_row, got.items[got.items.len - 1].kind);
}
