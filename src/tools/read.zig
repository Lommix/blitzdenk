const prv = @import("provider");
const r = @import("root.zig");
const std = @import("std");

const MAX_DISPLAY_BYTES = 64 * 1024;
const MAX_DISPLAY_LINES = 3000;

pub const ReadTool = prv.tool.Tool{
    .def = .{
        .name = "read",
        .description = "Read the contents of a file. Output is truncated to" ++ std.fmt.comptimePrint("{d} lines or {d} KB", .{ MAX_DISPLAY_LINES, @divTrunc(MAX_DISPLAY_BYTES, 1024) }) ++
            \\(whichever is hit first). Use offset/limit for large files. When you need the full file, continue with offset until complete.\n" ++
            \\OUTPUT FORMAT: each line is prefixed with `<right-aligned line number><TAB>`, e.g. `   42\\tcode`. The number+tab is display only and is NOT part of the file. " ++
            \\When using oldText for the edit tool, strip the prefix and use the raw line content exactly (preserve original tabs/spaces verbatim, no line numbers)."
        ,
        .parameters_schema =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\      "path": {"type": "string", "description": "Path to the file to read (relative to cwd or absolute)"},
        \\      "offset": {"type": "number", "description": "Line number to start reading from (1-indexed)"},
        \\      "limit": {"type": "number", "description": "Maximum number of lines to read"}
        \\  },
        \\  "required": ["path"]
        \\}
        ,
    },
    .func = &run,
};

pub const Stat = prv.agent.FileStat;
pub const FileStats = prv.agent.FileStats;

fn run(ctx: prv.tool.ToolContext, call: prv.adapter.ToolCall) prv.adapter.ToolResult {
    const Args = struct {
        path: []const u8,
        offset: ?u64 = null,
        limit: ?u64 = null,
    };

    const args = std.json.parseFromSliceLeaky(Args, ctx.alloc, call.arguments, .{
        .ignore_unknown_fields = true,
    }) catch return r.errResult(call, "invalid JSON arguments: expected {\"path\": \"...\"}");

    if (args.path.len == 0) return r.errResult(call, "path is empty");

    // Inspect a background task spawned by bash run_in_background.
    // Snapshot the matching handle under lock, then drop the lock before
    // poll/format work.
    const BgMatch = struct { handle: prv.exec.CmdPool.Handle, idx: usize };
    const bg_match: ?BgMatch = blk: {
        const g = ctx.agent().bg_tasks.tryLock(ctx.io) orelse break :blk null;
        defer g.unlock();
        const items = g.ptr.list.items;
        for (0..items.len) |i| {
            const rev = items.len - i - 1;
            if (std.mem.eql(u8, items[rev].path, args.path))
                break :blk .{ .handle = items[rev].handle, .idx = rev };
        }
        break :blk null;
    };

    if (bg_match) |m| {
        ctx.updateToolStatus(call, "(Reading Process) {s}", .{args.path});
        if (ctx.swarm.exec.poll(m.handle)) |res| {
            defer ctx.swarm.exec.release(m.handle);
            {
                const g = ctx.agent().bg_tasks.lock(ctx.io);
                defer g.unlock();
                // Re-find — index may have shifted under us.
                const items = g.ptr.list.items;
                for (0..items.len) |i| {
                    if (items[i].handle == m.handle) {
                        _ = g.ptr.list.swapRemove(i);
                        break;
                    }
                }
            }
            const content = std.fmt.allocPrint(ctx.alloc,
                \\Command process finished. Final result:
                \\
                \\Stdout:
                \\{s}
                \\
                \\Stderr:
                \\{s}
            , .{ res.stdout, res.stderr }) catch "failed to read command pipe";
            return r.okResult(call, r.truncateOutput(ctx.alloc, content, MAX_DISPLAY_BYTES, MAX_DISPLAY_LINES));
        }
        const slot = &ctx.swarm.exec.slots[@intFromEnum(m.handle)];
        const content = std.fmt.allocPrint(ctx.alloc,
            \\Command process is running
            \\
            \\Stdout:
            \\{s}
            \\
            \\Stderr:
            \\{s}
        , .{ slot.stdout.items, slot.stderr.items }) catch "failed to read command pipe";
        return r.okResult(call, r.truncateOutput(ctx.alloc, content, MAX_DISPLAY_BYTES, MAX_DISPLAY_LINES));
    }

    const resolved = std.fs.path.resolve(ctx.alloc, &.{ ctx.cwd, args.path }) catch
        return r.errResult(call, "failed to resolve path");

    const full_read = args.offset == null and args.limit == null;

    if (args.limit) |l| {
        ctx.updateToolStatus(call, "(Read) {s} ({d} lines)", .{ args.path, l });
    } else {
        ctx.updateToolStatus(call, "(Read) {s}", .{args.path});
    }

    // Stat for mtime first so we can short-circuit unchanged re-reads.
    const stat_res = ctx.swarm.exec.runAndWait(.{ .argv = &.{ "stat", "-c", "%Y", resolved } }) catch
        return r.errResult(call, "failed to stat file");
    defer ctx.swarm.exec.alloc.free(stat_res.stdout);
    defer ctx.swarm.exec.alloc.free(stat_res.stderr);

    if (stat_res.ty != .success) {
        const msg = if (stat_res.stderr.len > 0)
            ctx.alloc.dupe(u8, stat_res.stderr) catch "stat failed"
        else
            "stat failed";
        return r.errResult(call, msg);
    }

    const trimmed = std.mem.trim(u8, stat_res.stdout, " \t\r\n");
    const mtime = std.fmt.parseInt(i64, trimmed, 10) catch return r.errResult(call, "failed to parse mtime stat");

    {
        const g = ctx.agent().file_stats.lock(ctx.io);
        defer g.unlock();
        const look = g.ptr.getOrPut(ctx.alloc, resolved) catch return r.errResult(call, "oom");
        if (look.found_existing and full_read and mtime <= look.value_ptr.last_read) {
            return r.okResult(call, "File unchanged since last read. The content from the earlier Read tool_result in this conversation is still current — refer to that instead of re-reading.");
        }
        if (!look.found_existing) {
            look.value_ptr.* = .{ .last_read = mtime, .last_write = 0 };
        } else {
            look.value_ptr.last_read = mtime;
        }
    }

    if (ctx.isCanceled()) return r.errResult(call, "canceled");

    // Read with cat -n for line numbering, sliced by offset/limit.
    const start_line: u64 = if (args.offset) |o| (if (o > 0) o else 1) else 1;
    const max_lines: u64 = if (args.limit) |l| l else MAX_DISPLAY_LINES;
    const command = std.fmt.allocPrint(ctx.alloc, "cat -n '{s}' | tail -n +{d} | head -n {d}", .{
        resolved, start_line, max_lines,
    }) catch return r.errResult(call, "out of memory");

    const read_res = ctx.swarm.exec.runAndWait(.{ .argv = &.{ "/bin/sh", "-c", command } }) catch
        return r.errResult(call, "failed to read file");
    defer ctx.swarm.exec.alloc.free(read_res.stdout);
    defer ctx.swarm.exec.alloc.free(read_res.stderr);

    const out = read_res.toOwned(ctx.alloc) catch return r.errResult(call, "oom");
    return r.okResult(call, r.truncateOutput(ctx.alloc, out, MAX_DISPLAY_BYTES, MAX_DISPLAY_LINES));
}
