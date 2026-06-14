const std = @import("std");

// ---------------------------------------------------------------------------
// HTML to Markdown converter
pub fn htmlToMarkdown(allocator: std.mem.Allocator, html: []const u8) ![]const u8 {
    var allocating = std.Io.Writer.Allocating.init(allocator);
    const w = &allocating.writer;
    const source = selectContentRoot(html) orelse html;

    const HtmlState = enum { text, tag_open, tag_name, tag_body, comment, attr_quoted };

    var state: HtmlState = .text;
    var tag_buf: [64]u8 = undefined;
    var tag_len: usize = 0;
    var is_closing: bool = false;

    var attr_buf: [2048]u8 = undefined;
    var attr_len: usize = 0;
    var capture_attrs: bool = false;
    var attr_quote: u8 = 0;

    var entity_buf: [16]u8 = undefined;
    var entity_len: usize = 0;
    var in_entity: bool = false;

    var skip_tag: ?TagId = null;
    var skip_depth: usize = 0;

    // Comment detection: after `<!`, track `--` to enter comment mode
    var comment_dashes: usize = 0;

    var last_was_space: bool = true;
    var last_was_newline: bool = true;
    var in_pre: bool = false;
    var in_code: bool = false;
    var in_table_cell: bool = false;
    var table_cell_count: usize = 0;
    var link_stack = LinkStack{};

    for (source) |c| {
        // Entity sub-state (can trigger inside .text)
        if (in_entity) {
            if (c == ';') {
                const decoded = decodeEntity(entity_buf[0..entity_len]);
                if (decoded) |ch| {
                    if (!in_pre and !in_code and ch == ' ') {
                        if (!last_was_space) {
                            try w.writeByte(' ');
                            last_was_space = true;
                        }
                    } else {
                        try w.writeByte(ch);
                        if (ch == '\n') {
                            last_was_space = true;
                            last_was_newline = true;
                        } else {
                            last_was_space = (ch == ' ');
                            last_was_newline = false;
                        }
                    }
                }
                in_entity = false;
                continue;
            } else if (c == '<' or isWhitespace(c)) {
                // Malformed entity — abandon, reprocess char
                in_entity = false;
                // Fall through to normal state processing below
            } else if (entity_len < entity_buf.len) {
                entity_buf[entity_len] = c;
                entity_len += 1;
                continue;
            } else {
                in_entity = false;
            }
            if (in_entity) continue;
        }

        switch (state) {
            .text => switch (c) {
                '<' => {
                    state = .tag_open;
                    tag_len = 0;
                    attr_len = 0;
                    is_closing = false;
                    capture_attrs = false;
                    comment_dashes = 0;
                },
                '&' => {
                    if (skip_tag != null) continue;
                    in_entity = true;
                    entity_len = 0;
                },
                else => {
                    if (skip_tag != null) continue;
                    if (in_pre or in_code) {
                        try w.writeByte(c);
                        if (c == '\n') {
                            last_was_space = true;
                            last_was_newline = true;
                        } else {
                            last_was_space = isWhitespace(c);
                            last_was_newline = false;
                        }
                    } else if (isWhitespace(c)) {
                        if (!last_was_space) {
                            try w.writeByte(' ');
                            last_was_space = true;
                        }
                    } else {
                        try w.writeByte(c);
                        last_was_space = false;
                        last_was_newline = false;
                    }
                },
            },
            .tag_open => {
                if (c == '/') {
                    is_closing = true;
                    state = .tag_name;
                } else if (c == '!') {
                    comment_dashes = 0;
                    state = .tag_body; // might become .comment if we see `--`
                } else if (c == '?') {
                    state = .tag_body;
                } else if (isAlpha(c)) {
                    tag_buf[0] = toLower(c);
                    tag_len = 1;
                    state = .tag_name;
                } else {
                    state = .tag_body;
                }
            },
            .tag_name => {
                if (isTagNameChar(c)) {
                    if (tag_len < tag_buf.len) {
                        tag_buf[tag_len] = toLower(c);
                        tag_len += 1;
                    }
                } else {
                    const tag_id = identifyTag(tag_buf[0..tag_len]);
                    if (c == '>') {
                        try applyTag(w, tag_id, is_closing, &.{}, &skip_tag, &skip_depth, &last_was_space, &last_was_newline, &in_pre, &in_code, &in_table_cell, &table_cell_count, &link_stack);
                        state = .text;
                    } else {
                        capture_attrs = !is_closing and (tag_id == .a or tag_id == .img);
                        if (capture_attrs and isWhitespace(c)) {
                            // skip leading space
                        } else if (capture_attrs) {
                            attr_buf[0] = c;
                            attr_len = 1;
                        }
                        state = .tag_body;
                    }
                }
            },
            .tag_body => {
                // Detect HTML comment start: `<!` followed by `--`
                if (comment_dashes < 2 and tag_len == 0 and !is_closing) {
                    if (c == '-') {
                        comment_dashes += 1;
                        if (comment_dashes == 2) {
                            state = .comment;
                            comment_dashes = 0;
                            continue;
                        }
                        continue;
                    } else {
                        comment_dashes = 0;
                    }
                }

                // Track quoted attributes so `>` inside quotes doesn't end tag
                if (c == '"' or c == '\'') {
                    attr_quote = c;
                    if (capture_attrs and attr_len < attr_buf.len) {
                        attr_buf[attr_len] = c;
                        attr_len += 1;
                    }
                    state = .attr_quoted;
                } else if (c == '>') {
                    const tag_id = identifyTag(tag_buf[0..tag_len]);
                    try applyTag(w, tag_id, is_closing, attr_buf[0..attr_len], &skip_tag, &skip_depth, &last_was_space, &last_was_newline, &in_pre, &in_code, &in_table_cell, &table_cell_count, &link_stack);
                    state = .text;
                } else if (capture_attrs and attr_len < attr_buf.len) {
                    attr_buf[attr_len] = c;
                    attr_len += 1;
                }
            },
            .attr_quoted => {
                if (c == attr_quote) {
                    if (capture_attrs and attr_len < attr_buf.len) {
                        attr_buf[attr_len] = c;
                        attr_len += 1;
                    }
                    state = .tag_body;
                } else if (capture_attrs and attr_len < attr_buf.len) {
                    attr_buf[attr_len] = c;
                    attr_len += 1;
                }
            },
            .comment => {
                // Wait for `-->` to close comment
                if (c == '-') {
                    comment_dashes += 1;
                } else if (c == '>' and comment_dashes >= 2) {
                    comment_dashes = 0;
                    state = .text;
                } else {
                    comment_dashes = 0;
                }
            },
        }
    }

    normalizeMarkdownBuffer(w);
    if (w.end > 0) try w.writeByte('\n');

    return allocating.toOwnedSlice();
}

const TagId = enum {
    h1,
    h2,
    h3,
    h4,
    h5,
    h6,
    p,
    div,
    br,
    hr,
    strong,
    b,
    em,
    i,
    code,
    pre,
    li,
    ol,
    ul,
    a,
    img,
    blockquote,
    table,
    thead,
    tbody,
    tfoot,
    tr,
    th,
    td,
    caption,
    dl,
    dt,
    dd,
    // skipped content tags
    script,
    style,
    nav,
    head,
    svg,
    footer,
    header,
    form,
    noscript,
    template,
    button,
    article,
    main,
    section,
    aside,
    span,
    unknown,
};

fn identifyTag(name: []const u8) TagId {
    const map = .{
        .{ "h1", TagId.h1 },                 .{ "h2", TagId.h2 },           .{ "h3", TagId.h3 },
        .{ "h4", TagId.h4 },                 .{ "h5", TagId.h5 },           .{ "h6", TagId.h6 },
        .{ "p", TagId.p },                   .{ "div", TagId.div },         .{ "br", TagId.br },
        .{ "hr", TagId.hr },                 .{ "strong", TagId.strong },   .{ "b", TagId.b },
        .{ "em", TagId.em },                 .{ "i", TagId.i },             .{ "code", TagId.code },
        .{ "pre", TagId.pre },               .{ "li", TagId.li },           .{ "ol", TagId.ol },
        .{ "ul", TagId.ul },                 .{ "a", TagId.a },             .{ "img", TagId.img },
        .{ "blockquote", TagId.blockquote }, .{ "script", TagId.script },   .{ "style", TagId.style },
        .{ "table", TagId.table },           .{ "thead", TagId.thead },     .{ "tbody", TagId.tbody },
        .{ "tfoot", TagId.tfoot },           .{ "tr", TagId.tr },           .{ "th", TagId.th },
        .{ "td", TagId.td },                 .{ "caption", TagId.caption }, .{ "nav", TagId.nav },
        .{ "dl", TagId.dl },                 .{ "dt", TagId.dt },           .{ "dd", TagId.dd },
        .{ "head", TagId.head },             .{ "svg", TagId.svg },         .{ "footer", TagId.footer },
        .{ "header", TagId.header },         .{ "form", TagId.form },       .{ "noscript", TagId.noscript },
        .{ "template", TagId.template },     .{ "button", TagId.button },   .{ "article", TagId.article },
        .{ "main", TagId.main },             .{ "section", TagId.section }, .{ "aside", TagId.aside },
        .{ "span", TagId.span },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return .unknown;
}

fn applyTag(
    w: anytype,
    tag: TagId,
    is_closing: bool,
    attrs: []const u8,
    skip_tag: *?TagId,
    skip_depth: *usize,
    last_was_space: *bool,
    last_was_newline: *bool,
    in_pre: *bool,
    in_code: *bool,
    in_table_cell: *bool,
    table_cell_count: *usize,
    link_stack: *LinkStack,
) !void {
    if (skip_tag.*) |st| {
        if (tag == st and !is_closing) {
            skip_depth.* += 1;
        } else if (tag == st and is_closing) {
            if (skip_depth.* == 0) skip_tag.* = null else skip_depth.* -= 1;
        }
        return;
    }
    if (!is_closing) {
        switch (tag) {
            .script, .style, .nav, .head, .svg, .footer, .form, .noscript, .template, .button => {
                skip_tag.* = tag;
                skip_depth.* = 0;
                return;
            },
            else => {},
        }
    }
    if (in_table_cell.*) {
        switch (tag) {
            .p, .div => {
                if (is_closing) try writeInlineSpace(w, last_was_space, last_was_newline);
                return;
            },
            .br => {
                try writeInlineSpace(w, last_was_space, last_was_newline);
                return;
            },
            else => {},
        }
    }
    switch (tag) {
        .h1 => if (!is_closing) {
            try ensureNewline(w, last_was_newline);
            try w.writeAll("# ");
            last_was_space.* = false;
        } else {
            try w.writeByte('\n');
            last_was_newline.* = true;
            last_was_space.* = true;
        },
        .h2 => if (!is_closing) {
            try ensureNewline(w, last_was_newline);
            try w.writeAll("## ");
            last_was_space.* = false;
        } else {
            try w.writeByte('\n');
            last_was_newline.* = true;
            last_was_space.* = true;
        },
        .h3 => if (!is_closing) {
            try ensureNewline(w, last_was_newline);
            try w.writeAll("### ");
            last_was_space.* = false;
        } else {
            try w.writeByte('\n');
            last_was_newline.* = true;
            last_was_space.* = true;
        },
        .h4 => if (!is_closing) {
            try ensureNewline(w, last_was_newline);
            try w.writeAll("#### ");
            last_was_space.* = false;
        } else {
            try w.writeByte('\n');
            last_was_newline.* = true;
            last_was_space.* = true;
        },
        .h5 => if (!is_closing) {
            try ensureNewline(w, last_was_newline);
            try w.writeAll("##### ");
            last_was_space.* = false;
        } else {
            try w.writeByte('\n');
            last_was_newline.* = true;
            last_was_space.* = true;
        },
        .h6 => if (!is_closing) {
            try ensureNewline(w, last_was_newline);
            try w.writeAll("###### ");
            last_was_space.* = false;
        } else {
            try w.writeByte('\n');
            last_was_newline.* = true;
            last_was_space.* = true;
        },
        .p, .div => {
            try ensureNewline(w, last_was_newline);
            if (is_closing) {
                try w.writeByte('\n');
                last_was_newline.* = true;
            }
            last_was_space.* = true;
        },
        .br => {
            try w.writeByte('\n');
            last_was_newline.* = true;
            last_was_space.* = true;
        },
        .hr => {
            try ensureNewline(w, last_was_newline);
            try w.writeAll("---\n");
            last_was_newline.* = true;
            last_was_space.* = true;
        },
        .strong, .b => {
            try w.writeAll("**");
            last_was_space.* = false;
        },
        .em, .i => {
            try w.writeByte('*');
            last_was_space.* = false;
        },
        .code => {
            if (in_pre.*) return;
            try w.writeByte('`');
            if (!is_closing) in_code.* = true else in_code.* = false;
            last_was_space.* = false;
        },
        .pre => if (!is_closing) {
            try ensureNewline(w, last_was_newline);
            try w.writeAll("```\n");
            in_pre.* = true;
            last_was_newline.* = true;
            last_was_space.* = true;
        } else {
            try ensureNewline(w, last_was_newline);
            try w.writeAll("```\n");
            in_pre.* = false;
            last_was_newline.* = true;
            last_was_space.* = true;
        },
        .li => if (!is_closing) {
            try ensureNewline(w, last_was_newline);
            try w.writeAll("- ");
            last_was_space.* = false;
        },
        .blockquote => if (!is_closing) {
            try ensureNewline(w, last_was_newline);
            try w.writeAll("> ");
            last_was_space.* = false;
        },
        .a => if (!is_closing) {
            link_stack.push(extractAttr(attrs, "href"));
            try w.writeByte('[');
            last_was_space.* = false;
        } else {
            const href = link_stack.pop();
            try w.writeAll("](");
            try w.writeAll(href orelse "#");
            try w.writeByte(')');
            last_was_space.* = false;
        },
        .img => {
            const alt = extractAttr(attrs, "alt") orelse "";
            const src = extractAttr(attrs, "src") orelse "";
            try w.writeAll("![");
            try w.writeAll(alt);
            try w.writeAll("](");
            try w.writeAll(src);
            try w.writeByte(')');
            last_was_space.* = false;
        },
        .table => {
            try ensureNewline(w, last_was_newline);
            table_cell_count.* = 0;
            last_was_space.* = true;
        },
        .thead, .tbody, .tfoot => {
            try ensureNewline(w, last_was_newline);
            table_cell_count.* = 0;
            last_was_space.* = true;
        },
        .caption => if (!is_closing) {
            try ensureNewline(w, last_was_newline);
            last_was_space.* = true;
        } else {
            try ensureNewline(w, last_was_newline);
            last_was_space.* = true;
        },
        .tr => if (!is_closing) {
            try ensureNewline(w, last_was_newline);
            table_cell_count.* = 0;
            last_was_space.* = true;
        } else {
            trimTrailingHorizontalWhitespace(w);
            try ensureNewline(w, last_was_newline);
            table_cell_count.* = 0;
            last_was_space.* = true;
        },
        .th, .td => if (!is_closing) {
            trimTrailingHorizontalWhitespace(w);
            if (table_cell_count.* > 0) {
                try w.writeAll(" | ");
                last_was_newline.* = false;
            }
            table_cell_count.* += 1;
            in_table_cell.* = true;
            last_was_space.* = true;
        } else {
            trimTrailingHorizontalWhitespace(w);
            in_table_cell.* = false;
            last_was_space.* = true;
        },
        .ol, .ul => {
            try ensureNewline(w, last_was_newline);
            last_was_space.* = true;
        },
        .dl => {
            try ensureNewline(w, last_was_newline);
            last_was_space.* = true;
        },
        .dt, .dd => {
            if (!is_closing) {
                try ensureNewline(w, last_was_newline);
            } else {
                try ensureNewline(w, last_was_newline);
            }
            last_was_space.* = true;
        },
        .header, .article, .main, .section, .aside, .span => {},
        .script, .style, .nav, .head, .svg, .footer, .form, .noscript, .template, .button => {},
        .unknown => {},
    }
}

fn ensureNewline(w: anytype, last_was_newline: *bool) !void {
    if (!last_was_newline.*) {
        trimTrailingHorizontalWhitespace(w);
        try w.writeByte('\n');
        last_was_newline.* = true;
    }
}

fn trimTrailingHorizontalWhitespace(w: anytype) void {
    while (w.end > 0 and isHorizontalWhitespace(w.buffer[w.end - 1])) {
        w.end -= 1;
    }
}

fn writeInlineSpace(w: anytype, last_was_space: *bool, last_was_newline: *bool) !void {
    if (!last_was_space.* and !last_was_newline.*) {
        try w.writeByte(' ');
        last_was_space.* = true;
    }
}

fn normalizeMarkdownBuffer(w: anytype) void {
    const src = w.buffer[0..w.end];
    var read: usize = 0;
    var write: usize = 0;
    var pending_blank = false;
    var wrote_line = false;
    var in_fence = false;

    while (read < src.len) {
        const line_start = read;
        while (read < src.len and src[read] != '\n') : (read += 1) {}
        var line = src[line_start..read];
        if (read < src.len and src[read] == '\n') read += 1;

        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        if (in_fence) {
            if (wrote_line) {
                w.buffer[write] = '\n';
                write += 1;
            }
            std.mem.copyForwards(u8, w.buffer[write..], line);
            write += line.len;

            const fence_line = std.mem.trim(u8, line, " \t");
            if (std.mem.startsWith(u8, fence_line, "```")) in_fence = false;
            wrote_line = true;
            pending_blank = false;
            continue;
        }

        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) {
            if (wrote_line) pending_blank = true;
            continue;
        }

        if (wrote_line) {
            w.buffer[write] = '\n';
            write += 1;
            if (pending_blank) {
                w.buffer[write] = '\n';
                write += 1;
            }
        }
        std.mem.copyForwards(u8, w.buffer[write..], trimmed);
        write += trimmed.len;

        if (std.mem.startsWith(u8, trimmed, "```")) in_fence = true;
        wrote_line = true;
        pending_blank = false;
    }

    w.end = write;
}

const LinkStack = struct {
    const max_depth = 32;
    const max_href_len = 2048;
    const Item = struct {
        href_buf: [max_href_len]u8 = undefined,
        href_len: usize = 0,
        has_href: bool = false,
    };

    items: [max_depth]Item = undefined,
    len: usize = 0,
    overflow: usize = 0,

    fn push(self: *LinkStack, href: ?[]const u8) void {
        if (self.len >= max_depth) {
            self.overflow += 1;
            return;
        }
        var item = Item{};
        if (href) |value| {
            item.href_len = @min(value.len, max_href_len);
            @memcpy(item.href_buf[0..item.href_len], value[0..item.href_len]);
            item.has_href = true;
        }
        self.items[self.len] = item;
        self.len += 1;
    }

    fn pop(self: *LinkStack) ?[]const u8 {
        if (self.overflow > 0) {
            self.overflow -= 1;
            return null;
        }
        if (self.len == 0) return null;
        self.len -= 1;
        const item = &self.items[self.len];
        if (!item.has_href) return null;
        return item.href_buf[0..item.href_len];
    }
};

fn selectContentRoot(html: []const u8) ?[]const u8 {
    if (findElementRange(html, "main")) |range| return range;
    if (findElementRange(html, "article")) |range| return range;
    if (findElementWithAttrValue(html, "role", "main")) |range| return range;
    return null;
}

const HtmlTag = struct {
    start: usize,
    end: usize,
    name: []const u8,
    attrs: []const u8,
    closing: bool,
    self_closing: bool,
};

fn findElementRange(html: []const u8, wanted_name: []const u8) ?[]const u8 {
    var idx: usize = 0;
    while (nextTag(html, &idx)) |open_tag| {
        if (open_tag.closing or open_tag.self_closing or !eqlIgnoreAsciiCase(open_tag.name, wanted_name)) continue;

        var depth: usize = 1;
        var scan = open_tag.end;
        while (nextTag(html, &scan)) |tag| {
            if (!eqlIgnoreAsciiCase(tag.name, wanted_name)) continue;
            if (tag.closing) {
                depth -= 1;
                if (depth == 0) return html[open_tag.end..tag.start];
            } else if (!tag.self_closing) {
                depth += 1;
            }
        }
        return html[open_tag.end..];
    }
    return null;
}

fn findElementWithAttrValue(html: []const u8, attr_name: []const u8, attr_value: []const u8) ?[]const u8 {
    var idx: usize = 0;
    while (nextTag(html, &idx)) |open_tag| {
        if (open_tag.closing or open_tag.self_closing) continue;
        const value = extractAttr(open_tag.attrs, attr_name) orelse continue;
        if (!eqlIgnoreAsciiCase(value, attr_value)) continue;
        return findElementRangeAt(html, open_tag);
    }
    return null;
}

fn findElementRangeAt(html: []const u8, open_tag: HtmlTag) ?[]const u8 {
    var depth: usize = 1;
    var scan = open_tag.end;
    while (nextTag(html, &scan)) |tag| {
        if (!eqlIgnoreAsciiCase(tag.name, open_tag.name)) continue;
        if (tag.closing) {
            depth -= 1;
            if (depth == 0) return html[open_tag.end..tag.start];
        } else if (!tag.self_closing) {
            depth += 1;
        }
    }
    return html[open_tag.end..];
}

fn nextTag(html: []const u8, idx: *usize) ?HtmlTag {
    while (idx.* < html.len) {
        const start = std.mem.indexOfScalarPos(u8, html, idx.*, '<') orelse {
            idx.* = html.len;
            return null;
        };
        var cursor = start + 1;
        if (cursor >= html.len) {
            idx.* = html.len;
            return null;
        }
        if (html[cursor] == '!' or html[cursor] == '?') {
            idx.* = findTagEnd(html, cursor + 1) orelse html.len;
            continue;
        }

        var closing = false;
        if (html[cursor] == '/') {
            closing = true;
            cursor += 1;
        }
        while (cursor < html.len and isWhitespace(html[cursor])) : (cursor += 1) {}
        const name_start = cursor;
        while (cursor < html.len and isTagNameChar(html[cursor])) : (cursor += 1) {}
        if (name_start == cursor) {
            idx.* = cursor;
            continue;
        }

        const tag_end = findTagEnd(html, cursor) orelse {
            idx.* = html.len;
            return null;
        };
        idx.* = tag_end + 1;
        return HtmlTag{
            .start = start,
            .end = tag_end + 1,
            .name = html[name_start..cursor],
            .attrs = html[cursor..tag_end],
            .closing = closing,
            .self_closing = isSelfClosingTag(html[cursor..tag_end]),
        };
    }
    return null;
}

fn findTagEnd(html: []const u8, start: usize) ?usize {
    var idx = start;
    var quote: u8 = 0;
    while (idx < html.len) : (idx += 1) {
        const c = html[idx];
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '>') {
            return idx;
        }
    }
    return null;
}

fn isSelfClosingTag(body: []const u8) bool {
    var idx = body.len;
    while (idx > 0 and isWhitespace(body[idx - 1])) : (idx -= 1) {}
    return idx > 0 and body[idx - 1] == '/';
}

fn extractAttr(attrs: []const u8, name: []const u8) ?[]const u8 {
    var idx: usize = 0;
    while (idx < attrs.len) {
        while (idx < attrs.len and (isWhitespace(attrs[idx]) or attrs[idx] == '/')) : (idx += 1) {}
        const key_start = idx;
        while (idx < attrs.len and isAttrNameChar(attrs[idx])) : (idx += 1) {}
        if (key_start == idx) {
            idx += 1;
            continue;
        }
        const key = attrs[key_start..idx];
        while (idx < attrs.len and isWhitespace(attrs[idx])) : (idx += 1) {}
        if (idx >= attrs.len or attrs[idx] != '=') continue;
        idx += 1;
        while (idx < attrs.len and isWhitespace(attrs[idx])) : (idx += 1) {}
        if (idx >= attrs.len) return null;

        const value: []const u8 = value: {
            const quote = attrs[idx];
            if (quote == '"' or quote == '\'') {
                idx += 1;
                const value_start = idx;
                while (idx < attrs.len and attrs[idx] != quote) : (idx += 1) {}
                const out = attrs[value_start..idx];
                if (idx < attrs.len) idx += 1;
                break :value out;
            }

            const value_start = idx;
            while (idx < attrs.len and !isWhitespace(attrs[idx]) and attrs[idx] != '>') : (idx += 1) {}
            break :value attrs[value_start..idx];
        };
        if (eqlIgnoreAsciiCase(key, name)) return value;
    }
    return null;
}

fn decodeEntity(name: []const u8) ?u8 {
    if (std.mem.eql(u8, name, "amp")) return '&';
    if (std.mem.eql(u8, name, "lt")) return '<';
    if (std.mem.eql(u8, name, "gt")) return '>';
    if (std.mem.eql(u8, name, "quot")) return '"';
    if (std.mem.eql(u8, name, "apos")) return '\'';
    if (std.mem.eql(u8, name, "nbsp")) return ' ';
    if (name.len > 1 and name[0] == '#') {
        if (name[1] == 'x' or name[1] == 'X') return std.fmt.parseInt(u8, name[2..], 16) catch return null;
        return std.fmt.parseInt(u8, name[1..], 10) catch return null;
    }
    return null;
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}
fn isHorizontalWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}
fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}
fn isAlphaNum(c: u8) bool {
    return isAlpha(c) or (c >= '0' and c <= '9');
}
fn isTagNameChar(c: u8) bool {
    return isAlphaNum(c) or c == '-';
}
fn isAttrNameChar(c: u8) bool {
    return isAlphaNum(c) or c == '-' or c == '_' or c == ':' or c == '.';
}
fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
fn eqlIgnoreAsciiCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (toLower(ac) != toLower(bc)) return false;
    }
    return true;
}

test "html to markdown includes table cell content" {
    const html =
        \\<table>
        \\  <tr><th>Name</th><th>Role</th></tr>
        \\  <tr><td>Ada</td><td>Compiler engineer</td></tr>
        \\</table>
    ;

    const got = try htmlToMarkdown(std.testing.allocator, html);
    defer std.testing.allocator.free(got);

    try std.testing.expectEqualStrings(
        "Name | Role\nAda | Compiler engineer\n",
        got,
    );
}

test "html to markdown keeps block content inside table cells on the row" {
    const html =
        \\<table><tr>
        \\  <td><p>Ada</p><p>Lovelace</p></td>
        \\  <td><div>Notes</div></td>
        \\</tr></table>
    ;

    const got = try htmlToMarkdown(std.testing.allocator, html);
    defer std.testing.allocator.free(got);

    try std.testing.expectEqualStrings(
        "Ada Lovelace | Notes\n",
        got,
    );
}

test "html to markdown compacts blank lines and trims whitespace" {
    const html =
        \\<main>
        \\  <div>
        \\    <p>  First   paragraph  </p>
        \\
        \\
        \\    <div>
        \\      <p>Second&nbsp;&nbsp;paragraph</p>
        \\    </div>
        \\  </div>
        \\</main>
    ;

    const got = try htmlToMarkdown(std.testing.allocator, html);
    defer std.testing.allocator.free(got);

    try std.testing.expectEqualStrings(
        "First paragraph\n\nSecond paragraph\n",
        got,
    );
}

test "html to markdown preserves pre whitespace while compacting outside" {
    const html =
        \\<p>Before</p>
        \\<pre>  one
        \\
        \\    two</pre>
        \\<p>After</p>
    ;

    const got = try htmlToMarkdown(std.testing.allocator, html);
    defer std.testing.allocator.free(got);

    try std.testing.expectEqualStrings(
        "Before\n\n```\n  one\n\n    two\n```\nAfter\n",
        got,
    );
}

test "html to markdown keeps href from opening anchor through nested tags" {
    const html =
        \\<p>Read <a class="external" href="/docs/WebSocket"><code>WebSocket()</code></a> now.</p>
    ;

    const got = try htmlToMarkdown(std.testing.allocator, html);
    defer std.testing.allocator.free(got);

    try std.testing.expectEqualStrings(
        "Read [`WebSocket()`](/docs/WebSocket) now.\n",
        got,
    );
}

test "html to markdown treats custom elements as transparent containers" {
    const html =
        \\<main>
        \\  <x-doc-card data-state="a > b">
        \\    <p>Custom <a href="/target">content</a> survives.</p>
        \\  </x-doc-card>
        \\</main>
    ;

    const got = try htmlToMarkdown(std.testing.allocator, html);
    defer std.testing.allocator.free(got);

    try std.testing.expectEqualStrings(
        "Custom [content](/target) survives.\n",
        got,
    );
}

test "html to markdown prefers semantic main content over page chrome" {
    const html =
        \\<html><body>
        \\  <header><p>Navigation</p></header>
        \\  <main><article><h1>Article</h1><p>Main body.</p></article></main>
        \\  <footer><p>Footer</p></footer>
        \\</body></html>
    ;

    const got = try htmlToMarkdown(std.testing.allocator, html);
    defer std.testing.allocator.free(got);

    try std.testing.expectEqualStrings(
        "# Article\nMain body.\n",
        got,
    );
}

test "html to markdown preserves pre code blocks without inline code ticks" {
    const html =
        \\<pre><code>const socket = new WebSocket("ws://localhost:8080");
        \\socket.send("Hello Server!");</code></pre>
    ;

    const got = try htmlToMarkdown(std.testing.allocator, html);
    defer std.testing.allocator.free(got);

    try std.testing.expectEqualStrings(
        "```\nconst socket = new WebSocket(\"ws://localhost:8080\");\nsocket.send(\"Hello Server!\");\n```\n",
        got,
    );
}
