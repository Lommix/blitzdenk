const std = @import("std");
const exec = @import("exec");
const artifact = @import("../artifact.zig");

pub const MAX_DISPLAY_BYTES = 32 * 1024;
pub const MAX_DISPLAY_LINES = 2000;
pub const MAX_IMAGE_BYTES = 4 * 1024 * 1024;
pub const MAX_IMAGE_BASE64_BYTES = ((MAX_IMAGE_BYTES + 2) / 3) * 4;
pub const DISPLAY_CAP_TEXT = std.fmt.comptimePrint("{d} lines or {d}KB", .{ MAX_DISPLAY_LINES, @divTrunc(MAX_DISPLAY_BYTES, 1024) });
pub const CAP_MARKER = "[Truncated: result exceeds the display cap]";

pub fn truncateOutputToOwned(
    alloc: std.mem.Allocator,
    output: []const u8,
    max_bytes: usize,
    max_lines: usize,
) []const u8 {
    return truncateOutputToOwnedSpill(alloc, output, max_bytes, max_lines, null);
}

/// Truncate `output` to its tail (last `max_lines` lines, last `max_bytes`
/// bytes — whichever binds first), with an optional spill locator embedded in
/// the notice. `spill_locator` points at a file (or null) holding the full output.
/// The returned text fits within both caps, including the notice.
pub fn truncateOutputToOwnedSpill(
    alloc: std.mem.Allocator,
    output: []const u8,
    max_bytes: usize,
    max_lines: usize,
    spill_locator: ?[]const u8,
) []const u8 {
    const total_lines = countLines(output);
    if (output.len <= max_bytes and total_lines <= max_lines) {
        const sanitized = ensureValidUtf8(alloc, output);
        if (!isOversized(sanitized, max_bytes, max_lines)) return sanitized;
        const ret = truncateOutputToOwnedSpill(alloc, sanitized, max_bytes, max_lines, spill_locator);
        if (ret.ptr != sanitized.ptr) alloc.free(sanitized);
        return ret;
    }
    if (max_bytes == 0 or max_lines == 0) return "";

    const notice_reserve = if (spill_locator) |path| path.len + 512 else 512;
    const byte_budget = max_bytes -| notice_reserve;
    const line_budget = max_lines -| 2;

    const cut = collectLinesBack(output, byte_budget, line_budget);
    const tail = output[cut.start..];
    const kept = countLines(tail);

    var cap_buf: [64]u8 = undefined;
    const kb = @divTrunc(max_bytes, 1024);
    const cap_text = if (cut.byte_bound and cut.line_bound)
        std.fmt.bufPrint(&cap_buf, "{d}-line and {d}KB caps", .{ max_lines, kb }) catch "caps"
    else if (cut.byte_bound)
        std.fmt.bufPrint(&cap_buf, "{d}KB cap", .{kb}) catch "cap"
    else
        std.fmt.bufPrint(&cap_buf, "{d}-line cap", .{max_lines}) catch "cap";

    const notice = if (spill_locator) |path|
        std.fmt.allocPrint(
            alloc,
            "[Truncated: kept tail {d} of {d} lines ({s}). Full result saved at: {s} — call read with offset/limit to page through it.]",
            .{ kept, total_lines, cap_text, path },
        ) catch return output
    else
        std.fmt.allocPrint(
            alloc,
            "[Truncated: kept tail {d} of {d} lines ({s})]",
            .{ kept, total_lines, cap_text },
        ) catch return output;
    var notice_owned = true;
    defer if (notice_owned) alloc.free(notice);

    const raw = if (tail.len == 0)
        std.fmt.allocPrint(alloc, "{s}", .{notice}) catch return output
    else
        std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ tail, notice }) catch return output;
    const sanitized = ensureValidUtf8(alloc, raw);
    if (sanitized.ptr != raw.ptr) alloc.free(raw);
    if (isOversized(sanitized, max_bytes, max_lines)) {
        alloc.free(sanitized);
        if (!isOversized(notice, max_bytes, max_lines)) {
            notice_owned = false;
            return notice;
        }
        return "";
    }
    return sanitized;
}

/// True when `output` would be truncated by the given caps (matches
/// truncateOutputToOwnedSpill's entry condition). Callers gate spill-file
/// writes on this.
pub fn isOversized(output: []const u8, max_bytes: usize, max_lines: usize) bool {
    return output.len > max_bytes or countLines(output) > max_lines;
}

pub fn writeSpillFile(pool: *exec.CmdPool, alloc: std.mem.Allocator, tag: []const u8, content: []const u8) ?[]const u8 {
    const basename = std.fmt.allocPrint(alloc, "blitz-spill-{s}.txt", .{tag}) catch return null;
    defer alloc.free(basename);
    return artifact.write(pool, alloc, basename, content) catch null;
}

pub fn capOutput(pool: *exec.CmdPool, alloc: std.mem.Allocator, tag: []const u8, output: []const u8) []const u8 {
    if (!isOversized(output, MAX_DISPLAY_BYTES, MAX_DISPLAY_LINES)) return output;
    const spill = writeSpillFile(pool, alloc, tag, output);
    defer if (spill) |path| alloc.free(path);
    const capped = truncateOutputToOwnedSpill(alloc, output, MAX_DISPLAY_BYTES, MAX_DISPLAY_LINES, spill);
    if (!isOversized(capped, MAX_DISPLAY_BYTES, MAX_DISPLAY_LINES)) return capped;
    if (capped.ptr != output.ptr) alloc.free(capped);
    return alloc.dupe(u8, CAP_MARKER) catch output;
}

/// Collect trailing lines from the end of `output`: the last `max_lines`
/// lines (matching `countLines` semantics), byte-clamped to `max_bytes` from
/// the end, then advanced to a line boundary. `byte_bound` reports whether
/// the byte clamp actually cut the kept tail.
const TailCut = struct { start: usize, line_bound: bool, byte_bound: bool };

fn collectLinesBack(output: []const u8, max_bytes: usize, max_lines: usize) TailCut {
    const total = countLines(output);
    const line_bound = total > max_lines;
    var line_start: usize = 0;
    if (line_bound) {
        const target_line = total - max_lines; // 0-based index of first kept line
        var line_idx: usize = 0;
        var i: usize = 0;
        while (i < output.len and line_idx < target_line) : (i += 1) {
            if (output[i] == '\n') {
                line_idx += 1;
                line_start = i + 1;
            }
        }
    }
    if (output.len - line_start <= max_bytes)
        return .{ .start = line_start, .line_bound = line_bound, .byte_bound = false };
    const floor = output.len - max_bytes;
    var tail_start = utf8Floor(output, floor);
    if (tail_start == 0) tail_start = floor;
    if (output[tail_start - 1] != '\n') {
        if (std.mem.indexOfScalarPos(u8, output, tail_start, '\n')) |nl| tail_start = nl + 1;
    }
    if (tail_start < line_start) tail_start = line_start;
    return .{ .start = tail_start, .line_bound = line_bound, .byte_bound = true };
}

/// Walk end back so it never splits a multi-byte UTF-8 sequence.
fn utf8Floor(s: []const u8, end: usize) usize {
    var i = @min(end, s.len);
    if (i == s.len) return i;
    while (i > 0 and (s[i] & 0xC0) == 0x80) : (i -= 1) {}
    return i;
}

/// Return `raw` if already valid UTF-8; otherwise owned lossy copy (U+FFFD).
fn ensureValidUtf8(alloc: std.mem.Allocator, raw: []const u8) []const u8 {
    if (std.unicode.utf8ValidateSlice(raw)) return raw;
    return std.fmt.allocPrint(alloc, "{f}", .{std.unicode.fmtUtf8(raw)}) catch raw;
}

pub fn countLines(output: []const u8) usize {
    var lines: usize = 0;
    var pos: usize = 0;
    while (pos < output.len) {
        lines += 1;
        if (std.mem.indexOfScalar(u8, output[pos..], '\n')) |nl| {
            pos += nl + 1;
        } else {
            break;
        }
    }
    return lines;
}
