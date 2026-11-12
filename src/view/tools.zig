const std = @import("std");
const r = @import("../root.zig");
const App = r.app.App;
const text_utils = r.tui.text_utils;
const blocks = @import("blocks.zig");
const timeline = @import("timeline.zig");

fn appendToolImage(
    app: *App,
    arena: std.mem.Allocator,
    p: *r.tui.Paragraph,
    images: *std.ArrayList(blocks.ToolInlineImage),
    agent_id: r.AgentId,
    call_id: []const u8,
    source_url: ?[]const u8,
    rail: []const u8,
    rail_style: r.tui.Style,
    inner_w: u16,
) !void {
    if (!app.kitty_graphics or !app.flags.inline_images) return;
    const entry = app.inline_images.find(agent_id, call_id) orelse blk: {
        const data_url = source_url orelse return;
        break :blk app.inline_images.request(app.gpa, agent_id, call_id, data_url, &app.inline_images_ready) orelse return;
    };
    if (entry.state.load(.acquire) != .ready) {
        const data_url = if (entry.data_url.len > 0) entry.data_url else source_url orelse "";
        if (data_url.len > 0) {
            _ = app.inline_images.request(app.gpa, agent_id, call_id, data_url, &app.inline_images_ready);
        }
    }
    if (entry.state.load(.acquire) != .ready or entry.img == null) return;
    const col: u16 = @intCast(r.tui.widgets.displayCols(rail) + 4);
    const available = inner_w -| p.padding.left -| p.padding.right -| col;
    if (available == 0) return;
    const m = r.inline_images.Store.metrics(entry, app.cell_px, available);
    if (m.rows == 0 or m.cols == 0) return;
    entry.frame_pinned = true;
    try images.append(arena, .{ .entry = entry, .row = p.lines.items.len, .col = col, .cols = m.cols, .rows = m.rows });
    for (0..m.rows) |row| {
        var line = r.tui.Line{};
        try line.pushText(arena, rail, rail_style);
        try line.pushText(arena, if (row == 0) "  └ " else "    ", .{ .fg = app.theme.muted });
        try p.lines.append(arena, line);
    }
}

/// Rail position of a call nested under a bash/read run summary row.
pub const RunRail = enum { none, mid, last };

/// A call of a tool group block, with its rail when it sits under a run summary.
pub const GroupCall = struct {
    call: r.app.TimelinePart.ToolCallEntry,
    rail: RunRail = .none,
};

pub fn appendToolGroup(
    arena: std.mem.Allocator,
    out: *std.ArrayList(blocks.RenderParagraphItem),
    total: *usize,
    app: *App,
    calls: *std.ArrayList(GroupCall),
    inner_w: u16,
    live: bool,
) !void {
    if (calls.items.len == 0) return;
    std.mem.reverse(GroupCall, calls.items);
    var para = try buildToolGroupParagraph(app, arena, calls.items, inner_w);
    if (live) para.live_calls = arena.dupe(GroupCall, calls.items) catch null;
    try out.append(arena, para);
    total.* += para.h;
    blocks.collapseToolPadding(out, total);
    calls.clearRetainingCapacity();
}

fn appendRail(arena: std.mem.Allocator, out: *std.ArrayList(u8), prefix: []const bool, connector: []const u8) !void {
    try out.append(arena, ' ');
    for (prefix) |continues| {
        try out.appendSlice(arena, if (continues) r.tui.icon.box_v else " ");
        try out.append(arena, ' ');
    }
    try out.appendSlice(arena, connector);
    try out.append(arena, ' ');
}

pub fn buildToolGroupParagraph(
    app: *App,
    arena: std.mem.Allocator,
    calls: []const GroupCall,
    inner_w: u16,
) !blocks.RenderParagraphItem {
    var p = r.tui.Paragraph{ .wrap = false };
    var images: std.ArrayList(blocks.ToolInlineImage) = .empty;

    p.style.bg = app.theme.bg;
    p.padding = .all(blocks.tool_pad);

    const statuses = app.tool_status_entries.lock(app.io);
    defer statuses.unlock();

    for (calls) |group_call| {
        const call = group_call.call;
        const agent = app.registry.get(call.agent_id);
        var line = r.tui.Line{};
        // Calls under a run summary hang off its rail like sub-agent rows.
        const rail_style: r.tui.Style = .{ .fg = app.theme.muted };
        const head_rail: []const u8 = switch (group_call.rail) {
            .none => "",
            .mid => " " ++ r.tui.icon.box_t_right ++ " ",
            .last => " " ++ r.tui.icon.box_bl ++ " ",
        };
        const cont_rail: []const u8 = switch (group_call.rail) {
            .none => "",
            .mid => " " ++ r.tui.icon.box_v ++ " ",
            .last => "   ",
        };
        const child_prefix: []const bool = switch (group_call.rail) {
            .none => &.{},
            .mid => &.{true},
            .last => &.{false},
        };
        if (head_rail.len > 0) try line.pushSpan(arena, .{ .content = head_rail, .style = rail_style });

        const status = if (statuses.ptr.getAgent(call.agent_id)) |status_agent| status_agent.entries.getPtr(call.call_id) else null;
        const history_result = if (agent) |value| findToolHistory(value, call.call_id) else null;
        const status_image_url = if (status) |entry| if (entry.image_url.len > 0) entry.image_url else null else null;
        const image_url = if (history_result) |value| value.image_url else status_image_url;
        const live_result: ?r.sdk.ToolResult = if (history_result) |value| value.result else null;
        const is_error = if (live_result) |result| result.is_error else if (status) |entry| entry.is_error else null;
        if (is_error) |failed| {
            if (failed) {
                try line.pushSpan(arena, .{ .content = r.tui.icon.fail, .style = .{ .fg = app.theme.err, .modifier = .{ .bold = true } } });
            } else {
                try line.pushSpan(arena, .{ .content = r.tui.icon.ok, .style = .{ .fg = app.theme.ok, .modifier = .{ .bold = true } } });
            }
        } else {
            try line.pushSpan(arena, .{ .content = text_utils.spinnerDots(app.frame_count), .style = .{ .fg = app.theme.text } });
        }

        try line.pushSpan(arena, .{ .content = " " });
        if (status) |entry| {
            if (entry.interrupted) try line.pushSpan(arena, .{ .content = "interrupted ", .style = .{ .fg = app.theme.err } });
            if (entry.lines.items.len > 0) {
                line.style = entry.lines.items[0].style;
                for (entry.lines.items[0].spans.items) |span| try line.pushSpan(arena, span);
            } else {
                try line.pushSpan(arena, .{ .content = call.tool_name, .style = .{ .fg = app.theme.text_hl, .modifier = .{ .bold = true } } });
            }

            if (childCount(entry.*) == 1) {
                if (onlyChildId(entry.*)) |only| try pushChildActivity(app, arena, &line, only);
            }
        } else {
            try line.pushSpan(arena, .{ .content = call.tool_name, .style = .{ .fg = app.theme.text_hl, .modifier = .{ .bold = true } } });
        }
        try p.lines.append(arena, line);

        if (status) |entry| {
            if (entry.lines.items.len > 1) {
                for (entry.lines.items[1..]) |status_line| {
                    var extra = r.tui.Line{ .style = status_line.style };
                    if (cont_rail.len > 0) try extra.pushSpan(arena, .{ .content = cont_rail, .style = rail_style });
                    try extra.pushSpan(arena, .{ .content = "  " });
                    for (status_line.spans.items) |span| try extra.pushSpan(arena, span);
                    try p.lines.append(arena, extra);
                }
            }

            try appendToolImage(app, arena, &p, &images, call.agent_id, call.call_id, image_url, cont_rail, rail_style, inner_w);

            var rail_nodes: std.ArrayList(RailNode) = .empty;
            try appendChildRailBlocks(arena, statuses.ptr, app.registry, .{ .fg = app.theme.muted }, entry, child_prefix, 0, &rail_nodes);

            for (rail_nodes.items) |node| {
                var nested = r.tui.Line{ .style = node.line.style };
                const connector = node.connector();
                var rail: std.ArrayList(u8) = .empty;
                try appendRail(arena, &rail, node.prefix, connector);
                try nested.pushSpan(arena, .{ .content = rail.items });
                for (node.line.spans.items) |span| try nested.pushSpan(arena, span);
                if (node.entry_start) {
                    if (node.child_id) |node_child_id| try pushChildActivity(app, arena, &nested, node_child_id);
                }
                try p.lines.append(arena, nested);
                if (node.image_call_id) |call_id| {
                    var image_rail: std.ArrayList(u8) = .empty;
                    try appendRail(arena, &image_rail, node.prefix, if (node.continues) r.tui.icon.box_v else " ");
                    const node_history = if (app.registry.get(node.agent_id)) |node_agent| findToolHistory(node_agent, call_id) else null;
                    const node_status_image_url = if (statuses.ptr.getAgent(node.agent_id)) |node_status_agent| if (node_status_agent.entries.getPtr(call_id)) |node_entry| if (node_entry.image_url.len > 0) node_entry.image_url else null else null else null;
                    const node_image_url = if (node_history) |value| value.image_url else node_status_image_url;
                    try appendToolImage(app, arena, &p, &images, node.agent_id, call_id, node_image_url, image_rail.items, node.line.style, inner_w);
                }
            }
        } else {
            try appendToolImage(app, arena, &p, &images, call.agent_id, call.call_id, image_url, cont_rail, rail_style, inner_w);
        }
    }

    return .{
        .h = p.totalHeightLong(inner_w),
        .p = p,
        .is_tool_block = true,
        .inline_images = images.items,
    };
}

const rail_depth_cap = r.agent_registry.max_agents;

const rail_recent_entries = 3;

const RailNode = struct {
    line: r.tui.Line,
    entry_start: bool,
    child_id: ?r.AgentId,
    prefix: []const bool,
    agent_id: r.AgentId,
    image_call_id: ?[]const u8 = null,
    continues: bool = false,

    fn connector(self: RailNode) []const u8 {
        if (self.entry_start) return if (self.continues) r.tui.icon.box_t_right else r.tui.icon.box_bl;
        return if (self.continues) r.tui.icon.box_v else " ";
    }
};

fn appendChildRailBlocks(
    arena: std.mem.Allocator,
    store: *r.app.ToolStatusStore,
    registry: *r.agent_registry.Registry,
    muted_style: r.tui.Style,
    entry: *r.app.ToolStatusEntry,
    prefix: []const bool,
    depth: u32,
    out: *std.ArrayList(RailNode),
) anyerror!void {
    if (depth >= rail_depth_cap) return;
    const children = entry.child_ids.items;
    if (children.len == 1) {
        try walkAgentRail(arena, store, registry, muted_style, children[0], prefix, depth, out);
        return;
    }
    for (children, 0..) |child, index| {
        const continues = index + 1 < children.len;
        var anchor = r.tui.Line{};
        try anchor.pushSpan(arena, .{ .content = try railChildLabel(arena, store, registry, child), .style = muted_style });
        try out.append(arena, .{
            .line = anchor,
            .entry_start = true,
            .child_id = child,
            .prefix = prefix,
            .agent_id = child,
            .continues = continues,
        });
        const child_prefix = try extendRailPrefix(arena, prefix, continues);
        try walkAgentRail(arena, store, registry, muted_style, child, child_prefix, depth + 1, out);
    }
}

fn extendRailPrefix(arena: std.mem.Allocator, prefix: []const bool, continues: bool) ![]const bool {
    const child_prefix = try arena.alloc(bool, prefix.len + 1);
    @memcpy(child_prefix[0..prefix.len], prefix);
    child_prefix[prefix.len] = continues;
    return child_prefix;
}

fn childCount(entry: r.app.ToolStatusEntry) usize {
    return entry.child_ids.items.len;
}

fn onlyChildId(entry: r.app.ToolStatusEntry) ?r.AgentId {
    return if (entry.child_ids.items.len == 1) entry.child_ids.items[0] else null;
}

fn anyChildLive(registry: *r.agent_registry.Registry, entry: r.app.ToolStatusEntry) bool {
    for (entry.child_ids.items) |child| {
        if (!registry.subtreeDone(child)) return true;
    }
    return false;
}

fn railChildLabel(arena: std.mem.Allocator, store: *r.app.ToolStatusStore, registry: *r.agent_registry.Registry, child_id: r.AgentId) ![]const u8 {
    const child = registry.get(child_id);
    const archived = store.getAgent(child_id);
    const name = if (child) |agent| agent.name else if (archived) |agent| agent.name else "";
    const task = if (child) |agent| agent.task_description else if (archived) |agent| agent.task_description else "";
    const label = if (name.len > 0) name else try std.fmt.allocPrint(arena, "agent {d}", .{child_id.pack()});
    return if (task.len > 0) try std.fmt.allocPrint(arena, "{s} -> {s}", .{ label, task }) else label;
}

fn pushChildActivity(app: *App, arena: std.mem.Allocator, line: *r.tui.Line, child_id: r.AgentId) !void {
    const child = app.registry.get(child_id) orelse return;
    const activity = child.activity;
    if (activity != .idle) {
        try line.pushSpan(arena, .{ .content = switch (activity) {
            .idle => "",
            .thinking => "  thinking",
            .processing => "  processing",
            .writing => "  writing",
            .calling => "  calling",
            .retrying => "  retrying",
        }, .style = .{ .fg = app.theme.muted } });
        try line.pushSpan(arena, .{ .content = " " });
        try line.pushSpan(arena, .{ .content = text_utils.spinnerBar(app.frame_count), .style = .{ .fg = app.theme.muted } });
    }
    if (child.tokens_per_second > 0) {
        try line.pushSpan(arena, .{ .content = "  " });
        line.pushSpanPrint(arena, "{d}", .{@as(u32, @intFromFloat(child.tokens_per_second))}, .{ .fg = app.theme.text, .modifier = .{ .bold = true } }) catch {};
        line.pushSpanPrint(arena, " T/s", .{}, .{ .fg = app.theme.info }) catch {};
    }
}

fn walkAgentRail(
    arena: std.mem.Allocator,
    store: *r.app.ToolStatusStore,
    registry: *r.agent_registry.Registry,
    muted_style: r.tui.Style,
    agent_id: r.AgentId,
    prefix: []const bool,
    depth: u32,
    out: *std.ArrayList(RailNode),
) !void {
    if (depth >= rail_depth_cap) return;
    if (agent_id.index >= r.agent_registry.max_agents) return;
    const agent_status = store.getAgent(agent_id) orelse return;

    const Candidate = struct { entry: *r.app.ToolStatusEntry, call_id: []const u8, anchored: bool };
    var candidates: std.ArrayList(Candidate) = .empty;
    var recent_count: usize = 0;
    var it = agent_status.entries.iterator();
    while (it.next()) |kv| {
        const entry = kv.value_ptr;
        const anchored = anyChildLive(registry, entry.*);
        const image_entry = entry.has_image or agent_status.image_calls.contains(kv.key_ptr.*);
        if (!anchored and entry.lines.items.len == 0 and !image_entry and childCount(entry.*) == 0) continue;
        if (!anchored) recent_count += 1;
        try candidates.append(arena, .{ .entry = entry, .call_id = kv.key_ptr.*, .anchored = anchored });
    }
    var skip = recent_count -| rail_recent_entries;
    var visible: std.ArrayList(Candidate) = .empty;
    for (candidates.items) |candidate| {
        if (!candidate.anchored and skip > 0) {
            skip -= 1;
            continue;
        }
        try visible.append(arena, candidate);
    }

    for (visible.items, 0..) |candidate, vi| {
        const tool_entry = candidate.entry;
        const continues = vi + 1 < visible.items.len;
        const child_prefix = try extendRailPrefix(arena, prefix, continues);

        for (tool_entry.lines.items, 0..) |entry_line, li| {
            try out.append(arena, .{
                .line = entry_line,
                .entry_start = li == 0,
                .child_id = onlyChildId(tool_entry.*),
                .prefix = prefix,
                .agent_id = agent_id,
                .image_call_id = if (li + 1 == tool_entry.lines.items.len) candidate.call_id else null,
                .continues = continues,
            });
        }
        if (tool_entry.lines.items.len == 0) {
            var anchor = r.tui.Line{};
            if (onlyChildId(tool_entry.*)) |child_id| {
                try anchor.pushSpan(arena, .{ .content = try railChildLabel(arena, store, registry, child_id), .style = muted_style });
            } else {
                try anchor.pushSpan(arena, .{ .content = candidate.call_id, .style = muted_style });
            }
            try out.append(arena, .{
                .line = anchor,
                .entry_start = true,
                .child_id = onlyChildId(tool_entry.*),
                .prefix = prefix,
                .agent_id = agent_id,
                .image_call_id = candidate.call_id,
                .continues = continues,
            });
        }
        try appendChildRailBlocks(arena, store, registry, muted_style, tool_entry, child_prefix, depth + 1, out);
    }
}

const ToolHistoryResult = struct {
    result: r.sdk.ToolResult,
    image_url: ?[]const u8 = null,
};

fn findToolHistory(agent: *r.agent.Agent, call_id: []const u8) ?ToolHistoryResult {
    var i = agent.history().len;
    while (i > 0) {
        i -= 1;
        const msg = agent.history()[i];
        const parts = msg.parts();
        for (parts, 0..) |part, part_index| switch (part) {
            .tool_result => |res| {
                if (!std.mem.eql(u8, res.id, call_id)) continue;
                const image = if (part_index + 1 < parts.len) switch (parts[part_index + 1]) {
                    .image => |img| if (std.mem.startsWith(u8, img.url, "data:")) r.sdk.ToolImage{ .url = img.url, .media_type = img.media_type } else null,
                    else => null,
                } else null;
                return .{
                    .result = .{
                        .tool_call_id = res.id,
                        .tool_name = res.name,
                        .output = res.output,
                        .is_error = res.is_error,
                        .exit_loop = res.exit_loop,
                        .image = image,
                    },
                    .image_url = if (image) |value| value.url else null,
                };
            },
            else => {},
        };
    }
    return null;
}

pub fn findToolResult(agent: *r.agent.Agent, call_id: []const u8) ?r.sdk.ToolResult {
    return if (findToolHistory(agent, call_id)) |history| history.result else null;
}

test "tool images follow their calls, crop to the viewport, and follow recursive rail visibility" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    var registry = r.agent_registry.Registry.init(gpa, std.testing.io);
    defer registry.deinit();
    var app: App = undefined;
    app.io = std.testing.io;
    app.gpa = gpa;
    app.registry = &registry;
    app.session_store = null;
    app.theme = .default;
    app.flags = .{};
    app.frame_count = 0;
    app.kitty_graphics = true;
    app.cell_px = .{ .w = 10, .h = 20 };
    app.tool_status_entries = .{};
    app.inline_images = .{};
    app.inline_placements = .empty;
    defer app.inline_placements.deinit(gpa);
    app.arena_frame = .init(gpa);
    defer app.arena_frame.deinit();
    const parent_id = r.AgentId{ .index = 0, .generation = 0 };
    const child_id = r.AgentId{ .index = 1, .generation = 0 };
    const grandchild_id = r.AgentId{ .index = 2, .generation = 0 };
    var pixels: [0]u8 = .{};
    var image = r.inline_images.Entry{
        .agent_id = parent_id,
        .call_id = "screenshot",
        .kitty_id = 1,
        .img = .{ .width = 80, .height = 80, .pixels = &pixels },
        .state = .init(.ready),
    };
    try app.inline_images.entries.append(alloc, &image);
    const calls = [_]GroupCall{
        .{ .call = .{ .agent_id = parent_id, .call_id = "screenshot", .tool_name = "browser_screenshot" } },
        .{ .call = .{ .agent_id = parent_id, .call_id = "next", .tool_name = "bash" } },
    };
    const item = try buildToolGroupParagraph(&app, alloc, &calls, 40);
    try std.testing.expectEqual(@as(usize, 1), item.inline_images.len);
    try std.testing.expectEqual(@as(usize, 1), item.inline_images[0].row);
    try std.testing.expectEqual(@as(usize, 8), item.h);
    var stack = timeline.TimelineStack{ .total = item.h };
    try stack.items.append(alloc, item);
    var buf = try r.tui.Buffer.init(gpa, .{ .width = 80, .height = 30 });
    defer buf.deinit();
    const area = r.tui.Rect{ .x = 10, .y = 3, .width = 40, .height = 20 };
    timeline.renderTimelineStack(&app, stack, area, &buf);
    try std.testing.expectEqual(@as(u21, '└'), buf.get(13, 5).char);
    try std.testing.expectEqual(@as(u21, 'b'), buf.get(13, 9).char);
    try std.testing.expectEqual(@as(usize, 1), app.inline_placements.items.len);
    try std.testing.expectEqual(r.tui.Rect{ .x = 15, .y = 5, .width = 8, .height = 4 }, app.inline_placements.items[0].rect);

    app.inline_placements.clearRetainingCapacity();
    timeline.renderTimelineStack(&app, stack, .{ .x = 10, .y = 3, .width = 40, .height = 3 }, &buf);
    try std.testing.expectEqual(@as(usize, 1), app.inline_placements.items.len);
    try std.testing.expectEqual(r.tui.Rect{ .x = 15, .y = 3, .width = 8, .height = 1 }, app.inline_placements.items[0].rect);
    try std.testing.expectEqual(@as(u32, 60), app.inline_placements.items[0].src.y);
    try std.testing.expectEqual(@as(u32, 20), app.inline_placements.items[0].src.h);

    app.inline_placements.clearRetainingCapacity();
    stack.scroll_offset = 5;
    timeline.renderTimelineStack(&app, stack, .{ .x = 10, .y = 3, .width = 40, .height = 3 }, &buf);
    try std.testing.expectEqual(r.tui.Rect{ .x = 15, .y = 5, .width = 8, .height = 1 }, app.inline_placements.items[0].rect);
    try std.testing.expectEqual(@as(u32, 0), app.inline_placements.items[0].src.y);
    try std.testing.expectEqual(@as(u32, 20), app.inline_placements.items[0].src.h);

    var nested_pixels: [0]u8 = .{};
    var nested_image = r.inline_images.Entry{
        .agent_id = grandchild_id,
        .call_id = "screenshot",
        .kitty_id = 2,
        .img = .{ .width = 80, .height = 80, .pixels = &nested_pixels },
        .state = .init(.ready),
    };
    try app.inline_images.entries.append(alloc, &nested_image);
    const statuses = &app.tool_status_entries.value;
    const parent = try statuses.forWrite(alloc, parent_id);
    var launch_entry = r.app.ToolStatusEntry{};
    try launch_entry.child_ids.append(alloc, child_id);
    try parent.entries.put(alloc, "launch", launch_entry);
    const child = try statuses.forWrite(alloc, child_id);
    var child_entry = r.app.ToolStatusEntry{};
    try child_entry.child_ids.append(alloc, grandchild_id);
    try child_entry.lines.append(alloc, try r.tui.Line.new(alloc, "spawn", .{}, .{}));
    try child.entries.put(alloc, "spawn", child_entry);
    const grandchild = try statuses.forWrite(alloc, grandchild_id);
    for ([_][]const u8{ "screenshot", "after1", "after2" }) |call_id| {
        var entry = r.app.ToolStatusEntry{};
        try entry.lines.append(alloc, try r.tui.Line.new(alloc, "{s}", .{call_id}, .{}));
        try grandchild.entries.put(alloc, call_id, entry);
    }
    const launch = [_]GroupCall{.{ .call = .{ .agent_id = parent_id, .call_id = "launch", .tool_name = "start" } }};
    const nested = try buildToolGroupParagraph(&app, alloc, &launch, 40);
    try std.testing.expectEqual(@as(usize, 1), nested.inline_images.len);
    try std.testing.expectEqual(@as(u16, 9), nested.inline_images[0].col);
    stack = .{ .total = nested.h };
    try stack.items.append(alloc, nested);
    app.inline_placements.clearRetainingCapacity();
    buf.clear();
    timeline.renderTimelineStack(&app, stack, area, &buf);
    const nested_placement = app.inline_placements.items[0];
    try std.testing.expectEqual(@as(u16, 20), nested_placement.rect.x);
    try std.testing.expectEqual(@as(u21, '└'), buf.get(18, nested_placement.rect.y).char);
    try std.testing.expectEqual(@as(u21, '│'), buf.get(14, nested_placement.rect.y).char);

    var after = r.app.ToolStatusEntry{};
    try after.lines.append(alloc, try r.tui.Line.new(alloc, "after3", .{}, .{}));
    try grandchild.entries.put(alloc, "after3", after);
    const expired = try buildToolGroupParagraph(&app, alloc, &launch, 40);
    try std.testing.expectEqual(@as(usize, 0), expired.inline_images.len);
    stack = .{ .total = expired.h };
    try stack.items.append(alloc, expired);
    app.inline_placements.clearRetainingCapacity();
    timeline.renderTimelineStack(&app, stack, area, &buf);
    try std.testing.expectEqual(@as(usize, 0), app.inline_placements.items.len);

    const narrow = try buildToolGroupParagraph(&app, alloc, &calls, 6);
    try std.testing.expectEqual(@as(usize, 0), narrow.inline_images.len);
    app.flags.inline_images = false;
    const disabled = try buildToolGroupParagraph(&app, alloc, &calls, 40);
    try std.testing.expectEqual(@as(usize, 0), disabled.inline_images.len);
}

test "empty anchored tool entries carry their image call id" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var registry = r.agent_registry.Registry.init(alloc, std.testing.io);
    defer registry.deinit();
    var statuses = r.app.ToolStatusStore{};
    const parent_id = r.AgentId{ .index = 0, .generation = 0 };
    const child_id = r.AgentId{ .index = 1, .generation = 0 };
    registry.slots[child_id.index].state.store(.reserved, .release);
    const parent = try statuses.forWrite(arena.allocator(), parent_id);
    var entry = r.app.ToolStatusEntry{};
    try entry.child_ids.append(arena.allocator(), child_id);
    try parent.entries.put(arena.allocator(), "empty-image", entry);

    var nodes: std.ArrayList(RailNode) = .empty;
    try walkAgentRail(arena.allocator(), &statuses, &registry, .{}, parent_id, &.{}, 0, &nodes);
    try std.testing.expectEqual(@as(usize, 1), nodes.items.len);
    try std.testing.expectEqualStrings("empty-image", nodes.items[0].image_call_id.?);
}

test "finished image-only tool entries stay in the recursive rail" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var registry = r.agent_registry.Registry.init(alloc, std.testing.io);
    defer registry.deinit();
    var statuses = r.app.ToolStatusStore{};
    const agent_id = r.AgentId{ .index = 1, .generation = 0 };
    registry.slots[agent_id.index].state.store(.complete, .release);
    const agent = try statuses.forWrite(arena.allocator(), agent_id);
    const entry = r.app.ToolStatusEntry{ .has_image = true };
    try agent.entries.put(arena.allocator(), "image-only", entry);

    var nodes: std.ArrayList(RailNode) = .empty;
    try walkAgentRail(arena.allocator(), &statuses, &registry, .{}, agent_id, &.{}, 0, &nodes);
    try std.testing.expectEqual(@as(usize, 1), nodes.items.len);
    try std.testing.expectEqualStrings("image-only", nodes.items[0].image_call_id.?);
}

test "archived tool status rehydrates an evicted image source" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var registry = r.agent_registry.Registry.init(gpa, std.testing.io);
    defer registry.deinit();
    var app: App = undefined;
    app.io = std.testing.io;
    app.gpa = gpa;
    app.registry = &registry;
    app.session_store = null;
    app.theme = .default;
    app.flags = .{};
    app.frame_count = 0;
    app.kitty_graphics = true;
    app.cell_px = .{ .w = 10, .h = 20 };
    app.tool_status_entries = .{};
    app.inline_images = .{};
    app.arena_session = .init(gpa);
    defer app.arena_session.deinit();
    defer app.inline_images.deinit(gpa);

    const agent_id = r.AgentId{ .index = 1, .generation = 0 };
    const call_id = "archived-image";
    const source = "data:image/png;base64,source";
    try app.markToolImageUrl(agent_id, call_id, source);
    try app.setToolStatus(agent_id, call_id, "");
    const calls = [_]GroupCall{.{ .call = .{ .agent_id = agent_id, .call_id = call_id, .tool_name = "screenshot" } }};
    _ = try buildToolGroupParagraph(&app, arena.allocator(), &calls, 40);

    const entry = app.inline_images.find(agent_id, call_id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(source, entry.data_url);
}

test "sibling agent rails preserve ancestry through multiline tools images and empty agents" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    var registry = r.agent_registry.Registry.init(gpa, std.testing.io);
    defer registry.deinit();
    var app: App = undefined;
    app.io = std.testing.io;
    app.gpa = gpa;
    app.registry = &registry;
    app.session_store = null;
    app.journal_restoring = false;
    app.arena_session = .init(gpa);
    defer app.arena_session.deinit();
    app.tool_status_entries = .{};
    app.theme = .default;
    app.frame_count = 0;
    app.flags = .{};
    app.kitty_graphics = true;
    app.cell_px = .{ .w = 10, .h = 20 };
    app.inline_images = .{};
    const parent = registry.reserve(null).?;
    var children: [4]r.AgentId = undefined;
    for (&children, [_][]const u8{ "alpha", "beta", "gamma", "delta" }) |*child, name| {
        child.* = registry.reserve(parent).?;
        try app.rememberAgentMetadata(child.*, name, "");
        try app.addToolChild(parent, "launch", child.*);
    }
    const grandchild = registry.reserve(children[0]).?;
    try app.setToolStatus(parent, "launch", "codemode");
    try app.setToolResult(parent, "launch", false);
    try app.setToolStatus(children[0], "first", "first\nmore");
    try app.setToolStatus(children[0], "spawn", "spawn");
    try app.addToolChild(children[0], "spawn", grandchild);
    try app.setToolStatus(grandchild, "work", "grandchild work");
    try app.setToolStatus(children[2], "image", "screenshot");
    try app.setToolStatus(children[3], "tail", "tail\ncontinued");
    var pixels: [0]u8 = .{};
    var image = r.inline_images.Entry{
        .agent_id = children[2],
        .call_id = "image",
        .kitty_id = 1,
        .img = .{ .width = 80, .height = 80, .pixels = &pixels },
        .state = .init(.ready),
    };
    try app.inline_images.entries.append(alloc, &image);
    const calls = [_]GroupCall{.{ .call = .{ .agent_id = parent, .call_id = "launch", .tool_name = "codemode" } }};
    const item = try buildToolGroupParagraph(&app, alloc, &calls, 80);
    const expected = [_][]const u8{
        " ├ alpha",
        " │ ├ first",
        " │ │ more",
        " │ └ spawn",
        " │   └ grandchild work",
        " ├ beta",
        " ├ gamma",
        " │ └ screenshot",
        " │     └ ",
        " │       ",
        " │       ",
        " │       ",
        " └ delta",
        "   └ tail",
        "     continued",
    };
    try std.testing.expectEqual(expected.len + 1, item.p.lines.items.len);
    for (item.p.lines.items[1..], expected) |line, wanted| {
        var actual: std.ArrayList(u8) = .empty;
        for (line.spans.items) |span| try actual.appendSlice(alloc, span.content);
        try std.testing.expectEqualStrings(wanted, actual.items);
    }
    try std.testing.expectEqual(@as(usize, 1), item.inline_images.len);
    try std.testing.expectEqual(@as(usize, 9), item.inline_images[0].row);
    try std.testing.expectEqual(@as(u16, 9), item.inline_images[0].col);
    try std.testing.expect(!timeline.callChildrenReady(&app, calls[0].call, false));
    try std.testing.expect(!timeline.callChildrenReady(&app, calls[0].call, true));
    for (children) |child| registry.releaseReservation(child);
    registry.releaseReservation(grandchild);
    try std.testing.expect(timeline.callChildrenReady(&app, calls[0].call, false));
    try std.testing.expect(timeline.callChildrenReady(&app, calls[0].call, true));
    const restored = try buildToolGroupParagraph(&app, alloc, &calls, 80);
    try std.testing.expectEqual(item.p.lines.items.len, restored.p.lines.items.len);
}
