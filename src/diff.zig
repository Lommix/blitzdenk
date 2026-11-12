const std = @import("std");
const r = @import("root.zig");

fn pushDiffLine(out: *std.ArrayList(r.tui.DiffLine), alloc: std.mem.Allocator, line: r.tui.DiffLine) void {
    const owned_content = alloc.dupe(u8, line.content) catch return;
    out.append(alloc, .{
        .kind = line.kind,
        .line_number = line.line_number,
        .content = owned_content,
    }) catch return;
}

pub fn emitDiffLines(out: *std.ArrayList(r.tui.DiffLine), snap: r.permissions.ToolDiff, alloc: std.mem.Allocator) void {
    if (snap.before) |before| {
        const old_lines = splitLinesAlloc(before, alloc) orelse return;
        const new_lines = splitLinesAlloc(snap.after, alloc) orelse return;
        emitMyersDiff(out, old_lines, new_lines, alloc);
    } else {
        var new_iter = std.mem.splitScalar(u8, snap.after, '\n');
        var ln: u32 = 1;
        while (new_iter.next()) |line| {
            pushDiffLine(out, alloc, .{ .kind = .addition, .line_number = ln, .content = line });
            ln += 1;
        }
    }
}

/// Myers' O(ND) shortest edit script with context collapsing. Old-file line
/// numbers are 1-based.
fn emitMyersDiff(
    out: *std.ArrayList(r.tui.DiffLine),
    old_lines: []const []const u8,
    new_lines: []const []const u8,
    alloc: std.mem.Allocator,
) void {
    const ops = myersDiff(old_lines, new_lines, alloc) orelse {
        for (old_lines, 0..) |line, i| {
            pushDiffLine(out, alloc, .{ .kind = .deletion, .line_number = @as(u32, @intCast(i)) + 1, .content = line });
        }
        for (new_lines) |line| {
            pushDiffLine(out, alloc, .{ .kind = .addition, .content = line });
        }
        return;
    };

    if (ops.len == 0) return;

    const ctx_radius = 3;

    const visible = alloc.alloc(bool, ops.len) catch {
        emitAllOps(out, ops, alloc);
        return;
    };
    @memset(visible, false);

    for (ops, 0..) |op, idx| {
        if (op != .keep) {
            const start = if (idx >= ctx_radius) idx - ctx_radius else 0;
            const end = @min(idx + ctx_radius + 1, ops.len);
            @memset(visible[start..end], true);
        }
    }

    var old_ln: u32 = 0;
    var in_gap = false;
    var emitted_any = false;
    for (ops, 0..) |op, idx| {
        if (!visible[idx]) {
            if (op == .keep or op == .delete) old_ln += 1;
            in_gap = true;
            continue;
        }

        if (in_gap and emitted_any) {
            pushDiffLine(out, alloc, .{ .kind = .header, .content = "..." });
        }
        in_gap = false;
        emitted_any = true;

        switch (op) {
            .keep => |content| {
                pushDiffLine(out, alloc, .{ .kind = .context, .line_number = old_ln + 1, .content = content });
                old_ln += 1;
            },
            .delete => |content| {
                pushDiffLine(out, alloc, .{ .kind = .deletion, .line_number = old_ln + 1, .content = content });
                old_ln += 1;
            },
            .insert => |content| {
                pushDiffLine(out, alloc, .{ .kind = .addition, .content = content });
            },
        }
    }
}

fn emitAllOps(out: *std.ArrayList(r.tui.DiffLine), ops: []const DiffOp, alloc: std.mem.Allocator) void {
    var old_ln: u32 = 0;
    for (ops) |op| {
        switch (op) {
            .keep => |content| {
                pushDiffLine(out, alloc, .{ .kind = .context, .line_number = old_ln + 1, .content = content });
                old_ln += 1;
            },
            .delete => |content| {
                pushDiffLine(out, alloc, .{ .kind = .deletion, .line_number = old_ln + 1, .content = content });
                old_ln += 1;
            },
            .insert => |content| {
                pushDiffLine(out, alloc, .{ .kind = .addition, .content = content });
            },
        }
    }
}

pub fn splitLinesAlloc(text: []const u8, alloc: std.mem.Allocator) ?[]const []const u8 {
    // Count lines first
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next() != null) count += 1;

    const buf = alloc.alloc([]const u8, count) catch return null;
    var i: usize = 0;
    var iter2 = std.mem.splitScalar(u8, text, '\n');
    while (iter2.next()) |line| {
        buf[i] = line;
        i += 1;
    }
    return buf[0..i];
}

// ── Myers Diff ──

pub const DiffOp = union(enum) {
    keep: []const u8,
    delete: []const u8,
    insert: []const u8,
};

/// Myers O(ND) diff. Returns null on allocation failure.
pub fn myersDiff(old: []const []const u8, new: []const []const u8, alloc: std.mem.Allocator) ?[]const DiffOp {
    const n = old.len;
    const m = new.len;
    const max_d = n + m;
    if (max_d == 0) return alloc.alloc(DiffOp, 0) catch null;

    // V array indexed by k in [-max_d..max_d], offset so k=0 is at index max_d
    const v_size = 2 * max_d + 1;

    // Store V snapshots for each d to reconstruct the path
    const vs = alloc.alloc([]usize, max_d + 1) catch return null;

    const v_buf = alloc.alloc(usize, v_size) catch return null;
    // Initialize with 0
    @memset(v_buf, 0);

    const offset: isize = @intCast(max_d);

    var ses_len: usize = 0;

    outer: for (0..max_d + 1) |d| {
        const d_i: isize = @intCast(d);
        var k: isize = -d_i;
        while (k <= d_i) : (k += 2) {
            const k_idx: usize = @intCast(k + offset);

            var x: usize = undefined;
            if (k == -d_i or (k != d_i and v_buf[@intCast(k - 1 + offset)] < v_buf[@intCast(k + 1 + offset)])) {
                x = v_buf[@intCast(k + 1 + offset)]; // move down (insert)
            } else {
                x = v_buf[@intCast(k - 1 + offset)] + 1; // move right (delete)
            }

            var y: usize = @intCast(@as(isize, @intCast(x)) - k);

            // Follow diagonal (matching lines)
            while (x < n and y < m and std.mem.eql(u8, old[x], new[y])) {
                x += 1;
                y += 1;
            }

            v_buf[k_idx] = x;

            if (x >= n and y >= m) {
                ses_len = d;
                // Snapshot after this step completes
                vs[d] = alloc.dupe(usize, v_buf) catch return null;
                break :outer;
            }
        }
        // Snapshot V after processing step d
        vs[d] = alloc.dupe(usize, v_buf) catch return null;
    }

    // Backtrack to build edit script
    const result = alloc.alloc(DiffOp, n + m) catch return null;
    var result_len: usize = 0;

    var cx: isize = @intCast(n);
    var cy: isize = @intCast(m);

    var d_i: isize = @intCast(ses_len);
    while (d_i > 0) : (d_i -= 1) {
        const d_u: usize = @intCast(d_i);
        const v_prev = vs[d_u - 1];
        const ck: isize = cx - cy;

        const is_insert = (ck == -d_i or (ck != d_i and v_prev[@intCast(ck - 1 + offset)] < v_prev[@intCast(ck + 1 + offset)]));

        const prev_k: isize = if (is_insert) ck + 1 else ck - 1;
        const prev_end_x: isize = @intCast(v_prev[@intCast(prev_k + offset)]);
        const prev_end_y: isize = prev_end_x - prev_k;

        // After the edit move, we land here and then slide diagonally to (cx, cy)
        var mid_x: isize = undefined;
        var mid_y: isize = undefined;
        if (is_insert) {
            // Insert: move down from (prev_end_x, prev_end_y) to (prev_end_x, prev_end_y + 1)
            mid_x = prev_end_x;
            mid_y = prev_end_y + 1;
        } else {
            // Delete: move right from (prev_end_x, prev_end_y) to (prev_end_x + 1, prev_end_y)
            mid_x = prev_end_x + 1;
            mid_y = prev_end_y;
        }

        // Emit diagonal (keep) from (cx, cy) back to (mid_x, mid_y)
        while (cx > mid_x and cy > mid_y) {
            cx -= 1;
            cy -= 1;
            result[result_len] = .{ .keep = old[@intCast(cx)] };
            result_len += 1;
        }

        // Emit the edit
        if (is_insert) {
            cy -= 1;
            result[result_len] = .{ .insert = new[@intCast(cy)] };
            result_len += 1;
        } else {
            cx -= 1;
            result[result_len] = .{ .delete = old[@intCast(cx)] };
            result_len += 1;
        }
    }

    // Remaining diagonal at d=0
    while (cx > 0 and cy > 0) {
        cx -= 1;
        cy -= 1;
        result[result_len] = .{ .keep = old[@intCast(cx)] };
        result_len += 1;
    }

    // Reverse the result (we built it backwards)
    const ops = result[0..result_len];
    std.mem.reverse(DiffOp, ops);
    return ops;
}
