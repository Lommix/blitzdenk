//! Retained UI scene: a Zig-owned node tree that Lua builds and mutates.
//! Measure, layout, draw and hit testing run here without entering Lua;
//! the timeline, composer and Lua error strip are native leaves of the tree.
const std = @import("std");
const r = @import("../root.zig");
const tui = r.tui;
const Theme = r.app.Theme;

pub const MAX_NODES: u32 = 4096;
pub const MAX_DEPTH: u16 = 32;
pub const MAX_CELLS: u16 = 4096;
pub const UNBOUNDED: u16 = std.math.maxInt(u16);
pub const MIN_MAIN_COLS: u16 = 40;
pub const MIN_TIMELINE_ROWS: u16 = 6;
pub const MIN_CONTENT_ROWS: u16 = MIN_TIMELINE_ROWS + 4;
pub const NO_REF: c_int = r.c.LUA_NOREF;

pub const SLOT_LEFT = "left";
pub const SLOT_RIGHT = "right";
pub const SLOT_BETWEEN = "between";
pub const SLOT_BELOW = "below";

pub const Id = extern struct {
    index: u32,
    gen: u32,

    pub const none: Id = .{ .index = std.math.maxInt(u32), .gen = 0 };

    pub fn eql(self: Id, other: Id) bool {
        return self.index == other.index and self.gen == other.gen;
    }

    pub fn isNone(self: Id) bool {
        return self.index == none.index;
    }
};

pub const Kind = enum { box, text, spacer, canvas, native };
pub const Native = enum { lua_error, timeline, composer };
pub const Dir = enum { row, column };
pub const Align = enum { stretch, start, center, end };

pub const Size = union(enum) {
    auto,
    fit,
    fill,
    cells: u16,
};

pub const ThemeColor = std.meta.FieldEnum(Theme);

pub const ColorRef = union(enum) {
    none,
    theme: ThemeColor,
    fixed: tui.Color,

    pub fn parse(str: []const u8) ?ColorRef {
        if (str.len == 0) return null;
        if (str[0] == '#') return .{ .fixed = tui.Color.parseStrHex(str) catch return null };
        const field = std.meta.stringToEnum(ThemeColor, str) orelse return null;
        return .{ .theme = field };
    }

    pub fn resolve(self: ColorRef, theme: *const Theme) ?tui.Color {
        return switch (self) {
            .none => null,
            .fixed => |color| color,
            .theme => |field| switch (field) {
                inline else => |tag| @field(theme.*, @tagName(tag)),
            },
        };
    }
};

pub const StyleRef = struct {
    fg: ColorRef = .none,
    bg: ColorRef = .none,
    modifier: tui.Modifier = .{},
};

pub const TextSpan = struct {
    text: []const u8,
    style: StyleRef = .{},
    starts_line: bool = false,
};

pub const Padding = struct {
    top: u16 = 0,
    right: u16 = 0,
    bottom: u16 = 0,
    left: u16 = 0,
};

pub const Node = struct {
    gen: u32 = 0,
    alive: bool = false,
    kind: Kind = .box,
    native: Native = .timeline,
    parent: ?u32 = null,
    children: std.ArrayList(u32) = .empty,
    slot_name: []const u8 = "",

    hidden: bool = false,
    width: Size = .auto,
    height: Size = .auto,
    grow: u16 = 0,
    min_width: u16 = 0,
    min_height: u16 = 0,
    max_width: u16 = UNBOUNDED,
    max_height: u16 = UNBOUNDED,
    shrink: bool = false,
    collapsible: bool = false,
    fixed: bool = false,
    reserve: u16 = 0,

    dir: Dir = .column,
    gap: u16 = 0,
    padding: Padding = .{},
    border: bool = false,
    border_color: ColorRef = .none,
    title: []const u8 = "",
    cross_align: Align = .stretch,

    style: StyleRef = .{},
    pressed_style: ?StyleRef = null,

    spans: []TextSpan = &.{},
    wrap: bool = false,

    on_click: c_int = NO_REF,
    draw_ref: c_int = NO_REF,
    key: ?tui.Key = null,
    disabled: bool = false,

    rect: tui.Rect = .{},
    laid_out: bool = false,
    native_measure: ?NativeMeasure = null,

    const NativeMeasure = struct { width: u16, height: u16 };

    fn mainSize(self: *const Node, dir: Dir) Size {
        return if (dir == .row) self.width else self.height;
    }

    fn crossSize(self: *const Node, dir: Dir) Size {
        return if (dir == .row) self.height else self.width;
    }

    fn flexWeight(self: *const Node, dir: Dir) u16 {
        if (self.grow > 0) return self.grow;
        const spec = self.mainSize(dir);
        if (spec == .fill) return 1;
        if (self.kind == .spacer and spec == .auto) return 1;
        return 0;
    }

    fn mainFloor(self: *const Node, dir: Dir) u16 {
        const min = if (dir == .row) self.min_width else self.min_height;
        return @max(min, self.reserve);
    }

    fn lineCount(self: *const Node) u16 {
        var lines: u16 = 0;
        for (self.spans, 0..) |span, index| {
            if (index == 0 or span.starts_line) lines +|= 1;
        }
        return lines;
    }

    fn widestLine(self: *const Node) u16 {
        var widest: usize = 0;
        var current: usize = 0;
        for (self.spans, 0..) |span, index| {
            if (index != 0 and span.starts_line) {
                widest = @max(widest, current);
                current = 0;
            }
            current += tui.widgets.displayCols(span.text);
        }
        widest = @max(widest, current);
        return @intCast(@min(widest, UNBOUNDED));
    }
};

pub const CanvasDraw = struct {
    id: Id,
    rect: tui.Rect,
    bg: tui.Color,
};

pub const Frame = struct {
    theme: *const Theme,
    arena: std.mem.Allocator,
    buf: *tui.Buffer,
    host: *anyopaque,
    measureNative: *const fn (host: *anyopaque, native: Native, width: u16, max_height: u16) u16,
    drawNative: *const fn (host: *anyopaque, native: Native, rect: tui.Rect, buf: *tui.Buffer) void,
};

const Extent = struct {
    w: u16 = 0,
    h: u16 = 0,

    fn main(self: Extent, dir: Dir) u16 {
        return if (dir == .row) self.w else self.h;
    }

    fn cross(self: Extent, dir: Dir) u16 {
        return if (dir == .row) self.h else self.w;
    }
};

const Inherit = struct {
    fg: ?tui.Color = null,
    bg: tui.Color = .reset,
};

pub const Scene = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mu: std.Io.Mutex = .init,
    nodes: std.ArrayList(Node) = .empty,
    free_indices: std.ArrayList(u32) = .empty,
    live_count: u32 = 0,
    root: Id = .none,
    content: Id = .none,
    lua_error: Id = .none,
    timeline: Id = .none,
    composer: Id = .none,
    pressed: Id = .none,
    clicks: std.ArrayList(Id) = .empty,
    clicks_pending: std.atomic.Value(bool) = .init(false),
    released_refs: std.ArrayList(c_int) = .empty,
    canvas_draws: std.ArrayList(CanvasDraw) = .empty,
    orphan_mu: std.Io.Mutex = .init,
    orphans: std.ArrayList(Id) = .empty,
    changed: std.atomic.Value(bool) = .init(false),

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !Scene {
        var self = Scene{ .gpa = gpa, .io = io };
        errdefer self.deinit();
        try self.buildBase();
        return self;
    }

    pub fn deinit(self: *Scene) void {
        self.destroyAll();
        self.nodes.deinit(self.gpa);
        self.free_indices.deinit(self.gpa);
        self.clicks.deinit(self.gpa);
        self.released_refs.deinit(self.gpa);
        self.canvas_draws.deinit(self.gpa);
        self.orphans.deinit(self.gpa);
    }

    pub fn lock(self: *Scene) void {
        self.mu.lockUncancelable(self.io);
        self.collectOrphans();
    }

    pub fn unlock(self: *Scene) void {
        self.mu.unlock(self.io);
    }

    pub fn reset(self: *Scene) !void {
        self.lock();
        defer self.unlock();
        self.destroyAll();
        self.released_refs.clearRetainingCapacity();
        self.clicks.clearRetainingCapacity();
        self.clicks_pending.store(false, .release);
        self.canvas_draws.clearRetainingCapacity();
        self.pressed = .none;
        try self.buildBase();
        self.touch();
    }

    pub fn touch(self: *Scene) void {
        self.changed.store(true, .release);
    }

    pub fn orphan(self: *Scene, id: Id) void {
        self.orphan_mu.lockUncancelable(self.io);
        defer self.orphan_mu.unlock(self.io);
        self.orphans.append(self.gpa, id) catch {};
    }

    fn collectOrphans(self: *Scene) void {
        self.orphan_mu.lockUncancelable(self.io);
        var pending = self.orphans;
        self.orphans = .empty;
        self.orphan_mu.unlock(self.io);
        defer pending.deinit(self.gpa);
        for (pending.items) |id| {
            const node = self.get(id) orelse continue;
            if (node.parent != null or node.fixed) continue;
            self.destroy(id);
        }
    }

    fn destroyAll(self: *Scene) void {
        for (self.nodes.items, 0..) |*node, index| {
            if (!node.alive) continue;
            node.parent = null;
            node.children.clearRetainingCapacity();
            self.release(@intCast(index));
        }
        self.root = .none;
        self.content = .none;
        self.lua_error = .none;
        self.timeline = .none;
        self.composer = .none;
    }

    fn buildBase(self: *Scene) !void {
        self.root = try self.create(.box);
        self.get(self.root).?.fixed = true;
        self.lua_error = try self.createNative(.lua_error);
        self.timeline = try self.createNative(.timeline);
        self.get(self.timeline).?.reserve = MIN_TIMELINE_ROWS;
        self.composer = try self.createNative(.composer);
        self.get(self.composer).?.shrink = false;
        try self.attach(self.root, self.lua_error, null);
        const content = try self.buildDefaultContent();
        try self.attach(self.root, content, null);
        self.content = content;
    }

    fn buildDefaultContent(self: *Scene) !Id {
        const content = try self.create(.box);
        errdefer self.destroy(content);
        self.get(content).?.dir = .row;

        const left = try self.create(.box);
        try self.attach(content, left, null);
        try self.makeSlot(left, SLOT_LEFT);
        self.get(left).?.dir = .row;

        const main = try self.create(.box);
        try self.attach(content, main, null);
        const main_node = self.get(main).?;
        main_node.grow = 1;
        main_node.reserve = MIN_MAIN_COLS;

        const right = try self.create(.box);
        try self.attach(content, right, null);
        try self.makeSlot(right, SLOT_RIGHT);
        self.get(right).?.dir = .row;

        try self.attach(main, self.timeline, null);
        const between = try self.create(.box);
        try self.attach(main, between, null);
        try self.makeSlot(between, SLOT_BETWEEN);
        try self.attach(main, self.composer, null);
        const below = try self.create(.box);
        try self.attach(main, below, null);
        try self.makeSlot(below, SLOT_BELOW);
        return content;
    }

    pub fn makeSlot(self: *Scene, id: Id, name: []const u8) !void {
        try self.setSlotName(id, name);
        const node = self.get(id) orelse return;
        node.collapsible = true;
        node.style.bg = .{ .theme = .overlay };
    }

    pub fn setSlotName(self: *Scene, id: Id, name: []const u8) !void {
        const node = self.get(id) orelse return;
        const owned = try self.gpa.dupe(u8, name);
        self.gpa.free(node.slot_name);
        node.slot_name = owned;
        self.touch();
    }

    fn createNative(self: *Scene, native: Native) !Id {
        const id = try self.create(.native);
        const node = self.get(id).?;
        node.native = native;
        node.shrink = true;
        node.fixed = true;
        return id;
    }

    fn contains(self: *Scene, ancestor: Id, id: Id) bool {
        if (self.get(ancestor) == null or self.get(id) == null) return false;
        var cursor: ?u32 = id.index;
        while (cursor) |index| : (cursor = self.nodes.items[index].parent) {
            if (index == ancestor.index) return true;
        }
        return false;
    }

    fn hostsNatives(self: *Scene, id: Id) bool {
        return self.contains(id, self.timeline) and self.contains(id, self.composer);
    }

    pub fn setContent(self: *Scene, new: Id) !void {
        const node = self.get(new) orelse return error.DeadNode;
        if (node.kind != .box) return error.NotAContainer;
        if (node.fixed) return error.Cycle;
        if (new.eql(self.content)) return;
        if (!self.contains(new, self.timeline)) return error.MissingTimeline;
        if (!self.contains(new, self.composer)) return error.MissingComposer;

        const old = self.content;
        try self.migrateSlots(old, new);
        try self.attach(self.root, new, null);
        self.content = new;
        if (self.get(old) != null and !self.contains(new, old)) self.destroy(old);
        self.touch();
    }

    pub fn restoreDefault(self: *Scene) !void {
        const content = try self.buildDefaultContent();
        errdefer self.destroy(content);
        try self.setContent(content);
    }

    fn migrateSlots(self: *Scene, old: Id, new: Id) !void {
        if (self.get(old) == null) return;
        var named: std.ArrayList(u32) = .empty;
        defer named.deinit(self.gpa);
        try self.collectSlots(old.index, &named);
        for (named.items) |slot_index| {
            const slot = self.idOf(slot_index);
            if (self.contains(new, slot)) continue;
            const target = self.findSlotIn(new.index, self.nodes.items[slot_index].slot_name) orelse continue;
            const moving = try self.gpa.dupe(u32, self.nodes.items[slot_index].children.items);
            defer self.gpa.free(moving);
            for (moving) |child| try self.attach(target, self.idOf(child), null);
        }
    }

    fn collectSlots(self: *Scene, index: u32, out: *std.ArrayList(u32)) !void {
        const node = &self.nodes.items[index];
        if (node.slot_name.len > 0) try out.append(self.gpa, index);
        for (node.children.items) |child| try self.collectSlots(child, out);
    }

    fn findSlotIn(self: *Scene, index: u32, name: []const u8) ?Id {
        const node = &self.nodes.items[index];
        if (node.slot_name.len > 0 and std.mem.eql(u8, node.slot_name, name)) return self.idOf(index);
        for (node.children.items) |child| {
            if (self.findSlotIn(child, name)) |found| return found;
        }
        return null;
    }

    pub fn create(self: *Scene, kind: Kind) !Id {
        if (self.live_count >= MAX_NODES) return error.TooManyNodes;
        const index: u32 = if (self.free_indices.pop()) |free| free else blk: {
            try self.nodes.append(self.gpa, .{});
            break :blk @intCast(self.nodes.items.len - 1);
        };
        const node = &self.nodes.items[index];
        const gen = node.gen +% 1;
        node.* = .{ .gen = gen, .alive = true, .kind = kind };
        self.live_count += 1;
        return .{ .index = index, .gen = gen };
    }

    pub fn get(self: *Scene, id: Id) ?*Node {
        if (id.index >= self.nodes.items.len) return null;
        const node = &self.nodes.items[id.index];
        if (!node.alive or node.gen != id.gen) return null;
        return node;
    }

    fn idOf(self: *Scene, index: u32) Id {
        return .{ .index = index, .gen = self.nodes.items[index].gen };
    }

    pub fn destroy(self: *Scene, id: Id) void {
        const node = self.get(id) orelse return;
        self.detachIndex(id.index);
        if (!node.fixed) self.destroySubtree(id.index);
        self.touch();
    }

    fn destroySubtree(self: *Scene, index: u32) void {
        self.dropChildren(index);
        self.release(index);
    }

    fn dropChildren(self: *Scene, index: u32) void {
        var children = self.nodes.items[index].children;
        self.nodes.items[index].children = .empty;
        defer children.deinit(self.gpa);
        for (children.items) |child| {
            self.nodes.items[child].parent = null;
            if (!self.nodes.items[child].fixed) self.destroySubtree(child);
        }
    }

    fn release(self: *Scene, index: u32) void {
        const node = &self.nodes.items[index];
        if (node.on_click != NO_REF) self.released_refs.append(self.gpa, node.on_click) catch {};
        if (node.draw_ref != NO_REF) self.released_refs.append(self.gpa, node.draw_ref) catch {};
        self.freeSpans(node.spans);
        self.gpa.free(node.title);
        self.gpa.free(node.slot_name);
        node.children.deinit(self.gpa);
        if (self.pressed.index == index) self.pressed = .none;
        const gen = node.gen;
        node.* = .{ .gen = gen, .alive = false };
        self.live_count -= 1;
        self.free_indices.append(self.gpa, index) catch {};
    }

    fn freeSpans(self: *Scene, spans: []TextSpan) void {
        for (spans) |span| self.gpa.free(span.text);
        self.gpa.free(spans);
    }

    fn detachIndex(self: *Scene, index: u32) void {
        const node = &self.nodes.items[index];
        const parent_index = node.parent orelse return;
        const parent = &self.nodes.items[parent_index];
        if (std.mem.indexOfScalar(u32, parent.children.items, index)) |position| {
            _ = parent.children.orderedRemove(position);
        }
        node.parent = null;
    }

    pub fn attach(self: *Scene, parent_id: Id, child_id: Id, position: ?usize) !void {
        const parent = self.get(parent_id) orelse return error.DeadNode;
        _ = self.get(child_id) orelse return error.DeadNode;
        if (parent.kind != .box) return error.NotAContainer;
        if (child_id.eql(self.root)) return error.Cycle;
        if (child_id.eql(self.lua_error) and !parent_id.eql(self.root)) return error.Cycle;

        var depth: u16 = 1;
        var cursor: ?u32 = parent_id.index;
        while (cursor) |index| : (cursor = self.nodes.items[index].parent) {
            if (index == child_id.index) return error.Cycle;
            depth += 1;
        }
        if (depth > MAX_DEPTH) return error.TooDeep;

        self.detachIndex(child_id.index);
        const siblings = &self.nodes.items[parent_id.index].children;
        const at = @min(position orelse siblings.items.len, siblings.items.len);
        try siblings.insert(self.gpa, at, child_id.index);
        self.nodes.items[child_id.index].parent = parent_id.index;
        self.touch();
    }

    pub fn clearChildren(self: *Scene, id: Id) void {
        if (self.get(id) == null) return;
        self.dropChildren(id.index);
        self.touch();
    }

    pub fn firstChild(self: *Scene, id: Id) ?Id {
        const node = self.get(id) orelse return null;
        if (node.children.items.len == 0) return null;
        return self.idOf(node.children.items[0]);
    }

    pub fn findSlot(self: *Scene, name: []const u8) ?Id {
        if (name.len == 0 or self.get(self.content) == null) return null;
        return self.findSlotIn(self.content.index, name);
    }

    pub fn setSpans(self: *Scene, id: Id, spans: []TextSpan) void {
        const node = self.get(id) orelse {
            self.freeSpans(spans);
            return;
        };
        self.freeSpans(node.spans);
        node.spans = spans;
        self.touch();
    }

    pub fn setTitle(self: *Scene, id: Id, title: []const u8) !void {
        const node = self.get(id) orelse return;
        const owned = try self.gpa.dupe(u8, title);
        self.gpa.free(node.title);
        node.title = owned;
        self.touch();
    }

    pub fn setRef(self: *Scene, slot: *c_int, ref: c_int) void {
        if (slot.* != NO_REF) self.released_refs.append(self.gpa, slot.*) catch {};
        slot.* = ref;
        self.touch();
    }

    pub fn press(self: *Scene, x: u16, y: u16) bool {
        self.lock();
        defer self.unlock();
        const target = self.clickableAt(x, y) orelse return false;
        self.pressed = target;
        self.touch();
        return true;
    }

    pub fn isPressing(self: *Scene) bool {
        self.lock();
        defer self.unlock();
        return !self.pressed.isNone();
    }

    pub fn releasePress(self: *Scene, x: u16, y: u16) bool {
        self.lock();
        defer self.unlock();
        if (self.pressed.isNone()) return false;
        const pressed = self.pressed;
        self.pressed = .none;
        self.touch();
        const target = self.clickableAt(x, y) orelse return true;
        if (target.eql(pressed)) self.queueClick(pressed);
        return true;
    }

    pub fn keyPress(self: *Scene, key: tui.Key) bool {
        self.lock();
        defer self.unlock();
        for (self.nodes.items, 0..) |*node, index| {
            if (!node.alive or !node.laid_out or node.disabled or node.on_click == NO_REF) continue;
            const bound = node.key orelse continue;
            if (!bound.eql(key)) continue;
            self.queueClick(self.idOf(@intCast(index)));
            return true;
        }
        return false;
    }

    fn queueClick(self: *Scene, id: Id) void {
        self.clicks.append(self.gpa, id) catch return;
        self.clicks_pending.store(true, .release);
    }

    pub fn popClickRef(self: *Scene) ?c_int {
        self.lock();
        defer self.unlock();
        while (self.clicks.items.len > 0) {
            const id = self.clicks.orderedRemove(0);
            const node = self.get(id) orelse continue;
            if (node.on_click == NO_REF or node.disabled) continue;
            return node.on_click;
        }
        self.clicks_pending.store(false, .release);
        return null;
    }

    fn clickableAt(self: *Scene, x: u16, y: u16) ?Id {
        if (self.get(self.root) == null) return null;
        return self.clickableIn(self.root.index, x, y);
    }

    fn clickableIn(self: *Scene, index: u32, x: u16, y: u16) ?Id {
        const node = &self.nodes.items[index];
        if (!node.laid_out or !node.rect.contains(x, y)) return null;
        var position = node.children.items.len;
        while (position > 0) {
            position -= 1;
            if (self.clickableIn(node.children.items[position], x, y)) |hit| return hit;
        }
        if (node.on_click == NO_REF or node.disabled) return null;
        return self.idOf(index);
    }

    pub fn render(self: *Scene, frame: *const Frame, area: tui.Rect) void {
        self.lock();
        defer self.unlock();
        self.canvas_draws.clearRetainingCapacity();
        for (self.nodes.items) |*node| {
            node.laid_out = false;
            node.rect = .{};
            node.native_measure = null;
        }
        if (!self.hostsNatives(self.content)) self.restoreDefault() catch return;
        const root = self.get(self.root) orelse return;
        root.rect = area;
        root.laid_out = area.width > 0 and area.height > 0;
        const strip_height = self.measure(frame, self.lua_error.index, area.width, area.height -| MIN_CONTENT_ROWS, 1).h;
        self.layout(frame, self.lua_error.index, .{
            .x = area.x,
            .y = area.y,
            .width = area.width,
            .height = strip_height,
        }, 1);
        self.layout(frame, self.content.index, .{
            .x = area.x,
            .y = area.y +| strip_height,
            .width = area.width,
            .height = area.height - strip_height,
        }, 1);
        self.draw(frame, self.lua_error.index, .{}, 1);
        self.draw(frame, self.content.index, .{}, 1);
    }

    fn isVacant(self: *Scene, index: u32) bool {
        const node = &self.nodes.items[index];
        if (!node.alive or node.hidden) return true;
        if (node.kind != .box) return false;
        if (node.border or node.width == .cells or node.height == .cells) return false;
        for (node.children.items) |child| {
            if (!self.isVacant(child)) return false;
        }
        return true;
    }

    fn insets(node: *const Node) Padding {
        const edge: u16 = if (node.border) 1 else 0;
        return .{
            .top = node.padding.top +| edge,
            .right = node.padding.right +| edge,
            .bottom = node.padding.bottom +| edge,
            .left = node.padding.left +| edge,
        };
    }

    fn measure(self: *Scene, frame: *const Frame, index: u32, avail_w: u16, avail_h: u16, depth: u16) Extent {
        if (depth > MAX_DEPTH) return .{};
        const node = &self.nodes.items[index];
        var limit_w = @min(avail_w, node.max_width);
        var limit_h = @min(avail_h, node.max_height);
        if (node.width == .cells) limit_w = @min(limit_w, node.width.cells);
        if (node.height == .cells) limit_h = @min(limit_h, node.height.cells);

        var out: Extent = switch (node.kind) {
            .spacer, .canvas => .{},
            .native => .{ .w = limit_w, .h = self.measureNative(frame, node, limit_w, limit_h) },
            .text => measureText(frame, node, limit_w),
            .box => self.measureBox(frame, index, limit_w, limit_h, depth),
        };
        if (node.width == .cells) out.w = node.width.cells;
        if (node.height == .cells) out.h = node.height.cells;
        out.w = @min(@max(out.w, node.min_width), node.max_width);
        out.h = @min(@max(out.h, node.min_height), node.max_height);
        return out;
    }

    fn measureNative(self: *Scene, frame: *const Frame, node: *Node, width: u16, max_height: u16) u16 {
        _ = self;
        if (node.native_measure) |cached| {
            if (cached.width == width) return cached.height;
        }
        const height = @min(frame.measureNative(frame.host, node.native, width, max_height), max_height);
        node.native_measure = .{ .width = width, .height = height };
        return height;
    }

    fn measureText(frame: *const Frame, node: *const Node, avail_w: u16) Extent {
        const width = @min(node.widestLine(), avail_w);
        if (!node.wrap or width == 0) return .{ .w = width, .h = node.lineCount() };
        const paragraph = buildParagraph(frame, node, .{}) catch return .{ .w = width, .h = node.lineCount() };
        return .{ .w = width, .h = paragraph.totalHeight(width) };
    }

    fn measureBox(self: *Scene, frame: *const Frame, index: u32, avail_w: u16, avail_h: u16, depth: u16) Extent {
        const node = &self.nodes.items[index];
        const inset = insets(node);
        const inner_w = avail_w -| inset.left -| inset.right;
        const inner_h = avail_h -| inset.top -| inset.bottom;
        var main_total: u32 = 0;
        var cross_max: u16 = 0;
        var counted: u32 = 0;
        for (node.children.items) |child_index| {
            if (self.isVacant(child_index)) continue;
            const child = &self.nodes.items[child_index];
            const extent = self.measure(frame, child_index, inner_w, inner_h, depth + 1);
            const flexible = child.flexWeight(node.dir) > 0;
            main_total += if (flexible) child.mainFloor(node.dir) else extent.main(node.dir);
            cross_max = @max(cross_max, extent.cross(node.dir));
            counted += 1;
        }
        if (counted > 1) main_total += @as(u32, node.gap) * (counted - 1);
        const main: u16 = @intCast(@min(main_total, UNBOUNDED));
        const content: Extent = if (node.dir == .row) .{ .w = main, .h = cross_max } else .{ .w = cross_max, .h = main };
        return .{
            .w = content.w +| inset.left +| inset.right,
            .h = content.h +| inset.top +| inset.bottom,
        };
    }

    const Item = struct {
        index: u32,
        mode: enum { fixed, deferred, flexible },
        main: u16 = 0,
        cross_natural: ?u16 = null,
        weight: u16 = 0,
        active: bool = true,
    };

    fn layout(self: *Scene, frame: *const Frame, index: u32, rect: tui.Rect, depth: u16) void {
        const node = &self.nodes.items[index];
        node.rect = rect;
        node.laid_out = rect.width > 0 and rect.height > 0;
        if (node.laid_out and node.kind == .native) _ = self.measureNative(frame, node, rect.width, rect.height);
        if (!node.laid_out or node.kind != .box or depth > MAX_DEPTH) return;

        const inset = insets(node);
        const inner = tui.Rect{
            .x = rect.x +| inset.left,
            .y = rect.y +| inset.top,
            .width = rect.width -| inset.left -| inset.right,
            .height = rect.height -| inset.top -| inset.bottom,
        };
        const dir = node.dir;
        const gap = node.gap;
        const cross_align = node.cross_align;
        const inner_main = if (dir == .row) inner.width else inner.height;
        const inner_cross = if (dir == .row) inner.height else inner.width;
        const child_indices = frame.arena.dupe(u32, node.children.items) catch return;

        var items = std.ArrayList(Item).initCapacity(frame.arena, child_indices.len) catch return;
        for (child_indices) |child_index| {
            if (self.isVacant(child_index)) continue;
            const child = &self.nodes.items[child_index];
            const weight = child.flexWeight(dir);
            var item = Item{ .index = child_index, .mode = .fixed, .weight = weight };
            if (weight > 0) {
                item.mode = .flexible;
            } else if (child.shrink) {
                item.mode = .deferred;
            } else {
                const extent = self.measureChild(frame, child_index, dir, inner_main, inner_cross, depth);
                item.main = extent.main(dir);
                item.cross_natural = extent.cross(dir);
            }
            items.appendAssumeCapacity(item);
        }

        var used: u32 = 0;
        while (true) {
            used = 0;
            var reserved: u32 = 0;
            var active_count: u32 = 0;
            for (items.items) |item| {
                if (!item.active) continue;
                active_count += 1;
                if (item.mode == .fixed) used += item.main else reserved += self.nodes.items[item.index].mainFloor(dir);
            }
            if (active_count > 1) used += @as(u32, gap) * (active_count - 1);
            if (used + reserved <= inner_main) break;
            var dropped = false;
            var position = items.items.len;
            while (position > 0) {
                position -= 1;
                const item = &items.items[position];
                if (!item.active or !self.nodes.items[item.index].collapsible) continue;
                item.active = false;
                dropped = true;
                break;
            }
            if (!dropped) break;
        }

        var remaining: u16 = inner_main -| @as(u16, @intCast(@min(used, UNBOUNDED)));
        for (items.items) |*item| {
            if (!item.active or item.mode != .deferred) continue;
            const extent = self.measureChild(frame, item.index, dir, remaining, inner_cross, depth);
            item.main = @min(extent.main(dir), remaining);
            item.cross_natural = extent.cross(dir);
            remaining -= item.main;
        }

        var total_weight: u32 = 0;
        var last_flexible: ?usize = null;
        for (items.items, 0..) |item, position| {
            if (!item.active or item.mode != .flexible) continue;
            total_weight += item.weight;
            last_flexible = position;
        }
        var distributed: u16 = 0;
        for (items.items, 0..) |*item, position| {
            if (!item.active or item.mode != .flexible) continue;
            const child = &self.nodes.items[item.index];
            const share: u16 = if (position == last_flexible.?)
                remaining - distributed
            else
                @intCast(@as(u32, remaining) * item.weight / total_weight);
            distributed += share;
            const ceiling = if (dir == .row) child.max_width else child.max_height;
            item.main = @min(share, ceiling);
        }

        const main_start = if (dir == .row) inner.x else inner.y;
        const cross_start = if (dir == .row) inner.y else inner.x;
        const main_end = main_start +| inner_main;
        var cursor = main_start;
        for (items.items) |*item| {
            if (!item.active) continue;
            const child = &self.nodes.items[item.index];
            const main = @min(item.main, main_end -| cursor);
            const stretched = switch (child.crossSize(dir)) {
                .fill => true,
                .auto => cross_align == .stretch,
                .fit, .cells => false,
            };
            const cross: u16 = if (stretched) inner_cross else blk: {
                const natural = item.cross_natural orelse self.measureChild(frame, item.index, dir, main, inner_cross, depth).cross(dir);
                break :blk @min(natural, inner_cross);
            };
            const slack = inner_cross - cross;
            const offset: u16 = switch (cross_align) {
                .stretch, .start => 0,
                .center => slack / 2,
                .end => slack,
            };
            const child_rect: tui.Rect = if (dir == .row)
                .{ .x = cursor, .y = cross_start +| offset, .width = main, .height = cross }
            else
                .{ .x = cross_start +| offset, .y = cursor, .width = cross, .height = main };
            self.layout(frame, item.index, child_rect, depth + 1);
            cursor = cursor +| main +| gap;
        }
    }

    fn measureChild(self: *Scene, frame: *const Frame, index: u32, dir: Dir, avail_main: u16, avail_cross: u16, depth: u16) Extent {
        return if (dir == .row)
            self.measure(frame, index, avail_main, avail_cross, depth + 1)
        else
            self.measure(frame, index, avail_cross, avail_main, depth + 1);
    }

    fn draw(self: *Scene, frame: *const Frame, index: u32, inherited: Inherit, depth: u16) void {
        const node = &self.nodes.items[index];
        if (!node.laid_out or depth > MAX_DEPTH) return;
        const rect = node.rect;

        var style = node.style;
        if (self.pressed.index == index and self.pressed.gen == node.gen) {
            if (node.pressed_style) |pressed| {
                if (pressed.fg != .none) style.fg = pressed.fg;
                if (pressed.bg != .none) style.bg = pressed.bg;
                style.modifier = pressed.modifier;
            }
        }
        var context = inherited;
        const own_bg = style.bg.resolve(frame.theme);
        if (own_bg) |bg| context.bg = bg;
        if (style.fg.resolve(frame.theme)) |fg| context.fg = fg;
        if (node.disabled) context.fg = frame.theme.muted;

        switch (node.kind) {
            .box => {
                if (own_bg != null) frame.buf.fill(rect, .{ .style = .{ .bg = context.bg } });
                if (node.border) drawBorder(frame, node, rect, context);
                const children = frame.arena.dupe(u32, node.children.items) catch return;
                for (children) |child| self.draw(frame, child, context, depth + 1);
            },
            .text => drawText(frame, node, rect, style, context),
            .spacer => if (own_bg != null) frame.buf.fill(rect, .{ .style = .{ .bg = context.bg } }),
            .canvas => self.canvas_draws.append(self.gpa, .{
                .id = self.idOf(index),
                .rect = rect,
                .bg = context.bg,
            }) catch {},
            .native => frame.drawNative(frame.host, node.native, rect, frame.buf),
        }
    }

    fn drawBorder(frame: *const Frame, node: *const Node, rect: tui.Rect, context: Inherit) void {
        const color = node.border_color.resolve(frame.theme) orelse frame.theme.border;
        const block = tui.Block{
            .style = .{ .bg = context.bg },
            .border_style = .{ .fg = color, .bg = context.bg },
        };
        block.render(rect, frame.buf);
        if (node.title.len == 0 or rect.width < 5) return;
        const title_style: tui.Style = .{ .fg = context.fg orelse frame.theme.info, .bg = context.bg };
        const max_cols = rect.width - 4;
        frame.buf.setStringMax(rect.x + 1, rect.y, " ", title_style, 1);
        frame.buf.setStringMax(rect.x + 2, rect.y, node.title, title_style, max_cols);
        const title_cols: u16 = @intCast(@min(tui.widgets.displayCols(node.title), max_cols));
        frame.buf.setStringMax(rect.x + 2 + title_cols, rect.y, " ", title_style, 1);
    }

    fn buildParagraph(frame: *const Frame, node: *const Node, context: Inherit) !tui.Paragraph {
        const base_fg = context.fg orelse frame.theme.text;
        var paragraph = tui.Paragraph{ .wrap = node.wrap, .style = .{ .bg = context.bg } };
        var line = tui.Line{};
        for (node.spans, 0..) |span, index| {
            if (index != 0 and span.starts_line) {
                try paragraph.lines.append(frame.arena, line);
                line = .{};
            }
            const modifier: tui.Modifier = @bitCast(@as(u8, @bitCast(node.style.modifier)) | @as(u8, @bitCast(span.style.modifier)));
            try line.pushSpan(frame.arena, .{
                .content = span.text,
                .style = .{
                    .fg = span.style.fg.resolve(frame.theme) orelse base_fg,
                    .bg = span.style.bg.resolve(frame.theme) orelse context.bg,
                    .modifier = modifier,
                },
            });
        }
        if (node.spans.len > 0) try paragraph.lines.append(frame.arena, line);
        return paragraph;
    }

    fn drawText(frame: *const Frame, node: *const Node, rect: tui.Rect, style: StyleRef, context: Inherit) void {
        if (style.bg != .none) frame.buf.fill(rect, .{ .style = .{ .bg = context.bg } });
        const paragraph = buildParagraph(frame, node, context) catch return;
        paragraph.renderSimple(frame.arena, rect, frame.buf);
        if (node.wrap) return;
        const last_col = rect.x + rect.width - 1;
        for (paragraph.lines.items, 0..) |*line, row| {
            if (row >= rect.height) break;
            if (line.widthCols() <= rect.width) continue;
            const y = rect.y + @as(u16, @intCast(row));
            var cell = frame.buf.get(last_col, y);
            cell.char = '…';
            frame.buf.set(last_col, y, cell);
        }
    }
};
