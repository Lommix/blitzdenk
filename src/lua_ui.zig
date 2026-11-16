//! `blitz.ui`: Lua bindings for the retained scene in `view/scene.zig`.
//! Constructors return node handles; handles mutate the Zig-owned tree and
//! never draw. Main VM only: tool and event VMs get dead handles.
const std = @import("std");
const r = @import("root.zig");
const c = r.c;
const lua = r.lua;
const scene = r.view.scene;
const Scene = scene.Scene;
const Id = scene.Id;
const LuaType = lua.LuaType;

const NODE_META = "blitz.ui.node";

const Failure = ?[*:0]const u8;

threadlocal var failure_text: [192]u8 = undefined;

fn fail(comptime fmt: []const u8, args: anytype) [*:0]const u8 {
    const text = std.fmt.bufPrint(failure_text[0 .. failure_text.len - 1], "ui: " ++ fmt, args) catch return "ui: invalid arguments";
    failure_text[text.len] = 0;
    return @ptrCast(text.ptr);
}

fn sceneOf(L: *c.lua_State) ?*Scene {
    const vm = lua.fromState(L) orelse return null;
    if (vm.is_tool_vm) return null;
    const a = vm.app orelse return null;
    return &a.scene;
}

fn pushHandle(L: *c.lua_State, id: Id) c_int {
    const memory = c.lua_newuserdatauv(L, @sizeOf(Id), 0) orelse return 0;
    const handle: *Id = @ptrCast(@alignCast(memory));
    handle.* = id;
    c.luaL_setmetatable(L, NODE_META);
    return 1;
}

fn readHandle(L: *c.lua_State, idx: c_int) ?Id {
    const memory = c.luaL_testudata(L, idx, NODE_META) orelse return null;
    const handle: *Id = @ptrCast(@alignCast(memory));
    return handle.*;
}

fn unrefReleased(L: *c.lua_State, sc: *Scene) void {
    sc.lock();
    var released = sc.released_refs;
    sc.released_refs = .empty;
    sc.unlock();
    defer released.deinit(sc.gpa);
    for (released.items) |ref| c.luaL_unref(L, c.LUA_REGISTRYINDEX, ref);
}

fn finish(L: *c.lua_State, sc: *Scene, failure: Failure, results: c_int) c_int {
    unrefReleased(L, sc);
    if (failure) |message| {
        _ = c.luaL_error(L, "%s", message);
        return 0;
    }
    return results;
}

fn stringAt(L: *c.lua_State, idx: c_int) ?[]const u8 {
    if (c.lua_type(L, idx) != c.LUA_TSTRING) return null;
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, idx, &len) orelse return null;
    return ptr[0..len];
}

fn cellsAt(L: *c.lua_State, idx: c_int) ?u16 {
    if (c.lua_type(L, idx) != c.LUA_TNUMBER) return null;
    const value = c.lua_tointegerx(L, idx, null);
    if (value < 0 or value > scene.MAX_CELLS) return null;
    return @intCast(value);
}

fn boolAt(L: *c.lua_State, idx: c_int) ?bool {
    if (c.lua_type(L, idx) != c.LUA_TBOOLEAN) return null;
    return c.lua_toboolean(L, idx) != 0;
}

fn sizeAt(L: *c.lua_State, idx: c_int) ?scene.Size {
    if (cellsAt(L, idx)) |cells| return .{ .cells = cells };
    const name = stringAt(L, idx) orelse return null;
    if (std.mem.eql(u8, name, "fit")) return .fit;
    if (std.mem.eql(u8, name, "fill")) return .fill;
    if (std.mem.eql(u8, name, "auto")) return .auto;
    return null;
}

fn colorAt(L: *c.lua_State, idx: c_int) ?scene.ColorRef {
    if (c.lua_type(L, idx) == c.LUA_TBOOLEAN and c.lua_toboolean(L, idx) == 0) return .none;
    return scene.ColorRef.parse(stringAt(L, idx) orelse return null);
}

const StyleKey = enum { fg, bg, bold, dim, italic, underline, reverse, strikethrough };

fn applyStyleKey(L: *c.lua_State, key: StyleKey, style: *scene.StyleRef) bool {
    switch (key) {
        .fg => style.fg = colorAt(L, -1) orelse return false,
        .bg => style.bg = colorAt(L, -1) orelse return false,
        inline else => |tag| @field(style.modifier, @tagName(tag)) = boolAt(L, -1) orelse return false,
    }
    return true;
}

fn readStyleTable(L: *c.lua_State, idx: c_int, style: *scene.StyleRef) Failure {
    const table = c.lua_absindex(L, idx);
    c.lua_pushnil(L);
    while (c.lua_next(L, table) != 0) : (c.lua_pop(L, 1)) {
        if (c.lua_type(L, -2) != c.LUA_TSTRING) continue;
        const name = stringAt(L, -2).?;
        const key = std.meta.stringToEnum(StyleKey, name) orelse return fail("unknown style key '{s}'", .{name});
        if (!applyStyleKey(L, key, style)) return fail("invalid value for '{s}'", .{name});
    }
    return null;
}

fn appendText(sc: *Scene, spans: *std.ArrayList(scene.TextSpan), text: []const u8, style: scene.StyleRef, continues_line: bool) !void {
    var pieces = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (pieces.next()) |piece| {
        const owned = try sc.gpa.dupe(u8, piece);
        errdefer sc.gpa.free(owned);
        try spans.append(sc.gpa, .{
            .text = owned,
            .style = style,
            .starts_line = !(first and continues_line),
        });
        first = false;
    }
}

fn freeSpanList(sc: *Scene, spans: *std.ArrayList(scene.TextSpan)) void {
    for (spans.items) |span| sc.gpa.free(span.text);
    spans.deinit(sc.gpa);
}

fn readSpans(L: *c.lua_State, sc: *Scene, id: Id, table: c_int, count: usize) Failure {
    var spans: std.ArrayList(scene.TextSpan) = .empty;
    var position: usize = 1;
    while (position <= count) : (position += 1) {
        _ = c.lua_rawgeti(L, table, @intCast(position));
        defer c.lua_pop(L, 1);
        var style: scene.StyleRef = .{};
        var text: ?[]const u8 = stringAt(L, -1);
        var pushed_text = false;
        if (text == null and c.lua_type(L, -1) == c.LUA_TTABLE) {
            if (readSpanStyle(L, &style)) |message| {
                freeSpanList(sc, &spans);
                return message;
            }
            _ = c.lua_rawgeti(L, -1, 1);
            pushed_text = true;
            text = stringAt(L, -1);
        }
        defer if (pushed_text) c.lua_pop(L, 1);
        const content = text orelse {
            freeSpanList(sc, &spans);
            return "ui: text content must be strings or span tables { text, fg = ... }";
        };
        appendText(sc, &spans, content, style, position > 1) catch {
            freeSpanList(sc, &spans);
            return "ui: out of memory";
        };
    }
    const owned = spans.toOwnedSlice(sc.gpa) catch {
        freeSpanList(sc, &spans);
        return "ui: out of memory";
    };
    sc.setSpans(id, owned);
    return null;
}

fn readSpanStyle(L: *c.lua_State, style: *scene.StyleRef) Failure {
    const table = c.lua_absindex(L, -1);
    c.lua_pushnil(L);
    while (c.lua_next(L, table) != 0) : (c.lua_pop(L, 1)) {
        if (c.lua_type(L, -2) != c.LUA_TSTRING) continue;
        const name = stringAt(L, -2).?;
        const key = std.meta.stringToEnum(StyleKey, name) orelse return fail("unknown span key '{s}'", .{name});
        if (!applyStyleKey(L, key, style)) return fail("invalid value for '{s}'", .{name});
    }
    return null;
}

fn setPlainText(sc: *Scene, id: Id, text: []const u8) Failure {
    var spans: std.ArrayList(scene.TextSpan) = .empty;
    appendText(sc, &spans, text, .{}, true) catch {
        freeSpanList(sc, &spans);
        return "ui: out of memory";
    };
    const owned = spans.toOwnedSlice(sc.gpa) catch {
        freeSpanList(sc, &spans);
        return "ui: out of memory";
    };
    sc.setSpans(id, owned);
    return null;
}

fn readChildren(L: *c.lua_State, sc: *Scene, id: Id, table: c_int, count: usize) Failure {
    var wanted: std.ArrayList(Id) = .empty;
    defer wanted.deinit(sc.gpa);
    var position: usize = 1;
    while (position <= count) : (position += 1) {
        _ = c.lua_rawgeti(L, table, @intCast(position));
        defer c.lua_pop(L, 1);
        const child = readHandle(L, -1) orelse return "ui: box children must be ui nodes";
        if (sc.get(child) == null) return "ui: child node was removed";
        wanted.append(sc.gpa, child) catch return "ui: out of memory";
    }

    const node = sc.get(id) orelse return null;
    var stale: std.ArrayList(Id) = .empty;
    defer stale.deinit(sc.gpa);
    for (node.children.items) |existing| {
        var kept = false;
        for (wanted.items) |child| {
            if (child.index == existing) kept = true;
        }
        if (!kept) stale.append(sc.gpa, .{ .index = existing, .gen = sc.nodes.items[existing].gen }) catch return "ui: out of memory";
    }
    for (stale.items) |child| sc.destroy(child);
    for (wanted.items, 0..) |child, index| {
        sc.attach(id, child, index) catch |err| return attachFailure(err);
    }
    return null;
}

fn attachFailure(err: anyerror) [*:0]const u8 {
    return switch (err) {
        error.DeadNode => "ui: node was removed",
        error.NotAContainer => "ui: only boxes hold children",
        error.Cycle => "ui: a node cannot contain itself",
        error.TooDeep => "ui: tree is nested too deep",
        else => "ui: out of memory",
    };
}

const Prop = enum {
    width,
    height,
    grow,
    min_width,
    min_height,
    max_width,
    max_height,
    hidden,
    dir,
    gap,
    padding,
    border,
    title,
    @"align",
    fg,
    bg,
    bold,
    dim,
    italic,
    underline,
    reverse,
    strikethrough,
    wrap,
    on_click,
    key,
    disabled,
    pressed,
    draw,
    label,
};

fn readPadding(L: *c.lua_State, padding: *scene.Padding) bool {
    if (cellsAt(L, -1)) |cells| {
        padding.* = .{ .top = cells, .right = cells, .bottom = cells, .left = cells };
        return true;
    }
    if (c.lua_type(L, -1) != c.LUA_TTABLE) return false;
    const table = c.lua_absindex(L, -1);
    var out = scene.Padding{};
    inline for (.{ "x", "y", "top", "right", "bottom", "left" }) |side| {
        const kind = c.lua_getfield(L, table, side);
        defer c.lua_pop(L, 1);
        if (kind != c.LUA_TNIL) {
            const cells = cellsAt(L, -1) orelse return false;
            if (comptime std.mem.eql(u8, side, "x")) {
                out.left = cells;
                out.right = cells;
            } else if (comptime std.mem.eql(u8, side, "y")) {
                out.top = cells;
                out.bottom = cells;
            } else {
                @field(out, side) = cells;
            }
        }
    }
    padding.* = out;
    return true;
}

fn readCallback(L: *c.lua_State, sc: *Scene, slot: *c_int) bool {
    switch (c.lua_type(L, -1)) {
        c.LUA_TFUNCTION => {
            c.lua_pushvalue(L, -1);
            sc.setRef(slot, c.luaL_ref(L, c.LUA_REGISTRYINDEX));
            return true;
        },
        c.LUA_TBOOLEAN => {
            if (c.lua_toboolean(L, -1) != 0) return false;
            sc.setRef(slot, scene.NO_REF);
            return true;
        },
        else => return false,
    }
}

fn setLabel(sc: *Scene, id: Id, text: []const u8) Failure {
    if (sc.firstChild(id)) |child| {
        if (sc.get(child).?.kind == .text) return setPlainText(sc, child, text);
    }
    const child = sc.create(.text) catch return "ui: too many nodes";
    if (setPlainText(sc, child, text)) |message| {
        sc.destroy(child);
        return message;
    }
    sc.attach(id, child, 0) catch |err| {
        sc.destroy(child);
        return attachFailure(err);
    };
    return null;
}

fn applyProp(L: *c.lua_State, sc: *Scene, id: Id, prop: Prop) bool {
    const node = sc.get(id) orelse return true;
    switch (prop) {
        .width => node.width = sizeAt(L, -1) orelse return false,
        .height => node.height = sizeAt(L, -1) orelse return false,
        .grow => node.grow = cellsAt(L, -1) orelse return false,
        .min_width => node.min_width = cellsAt(L, -1) orelse return false,
        .min_height => node.min_height = cellsAt(L, -1) orelse return false,
        .max_width => node.max_width = cellsAt(L, -1) orelse return false,
        .max_height => node.max_height = cellsAt(L, -1) orelse return false,
        .hidden => node.hidden = boolAt(L, -1) orelse return false,
        .dir => node.dir = std.meta.stringToEnum(scene.Dir, stringAt(L, -1) orelse return false) orelse return false,
        .gap => node.gap = cellsAt(L, -1) orelse return false,
        .padding => return readPadding(L, &node.padding),
        .border => {
            if (boolAt(L, -1)) |enabled| {
                node.border = enabled;
            } else {
                node.border_color = colorAt(L, -1) orelse return false;
                node.border = true;
            }
        },
        .title => sc.setTitle(id, stringAt(L, -1) orelse return false) catch return false,
        .@"align" => node.cross_align = std.meta.stringToEnum(scene.Align, stringAt(L, -1) orelse return false) orelse return false,
        .fg => return applyStyleKey(L, .fg, &node.style),
        .bg => return applyStyleKey(L, .bg, &node.style),
        .bold => return applyStyleKey(L, .bold, &node.style),
        .dim => return applyStyleKey(L, .dim, &node.style),
        .italic => return applyStyleKey(L, .italic, &node.style),
        .underline => return applyStyleKey(L, .underline, &node.style),
        .reverse => return applyStyleKey(L, .reverse, &node.style),
        .strikethrough => return applyStyleKey(L, .strikethrough, &node.style),
        .wrap => node.wrap = boolAt(L, -1) orelse return false,
        .on_click => return readCallback(L, sc, &node.on_click),
        .draw => return readCallback(L, sc, &node.draw_ref),
        .key => {
            if (boolAt(L, -1)) |enabled| {
                if (enabled) return false;
                node.key = null;
            } else {
                node.key = r.keys.parseKeyString(stringAt(L, -1) orelse return false) orelse return false;
            }
        },
        .disabled => node.disabled = boolAt(L, -1) orelse return false,
        .pressed => {
            if (boolAt(L, -1)) |enabled| {
                if (enabled) return false;
                node.pressed_style = null;
            } else {
                if (c.lua_type(L, -1) != c.LUA_TTABLE) return false;
                var style: scene.StyleRef = .{};
                if (readStyleTable(L, -1, &style) != null) return false;
                node.pressed_style = style;
            }
        },
        .label => return setLabel(sc, id, stringAt(L, -1) orelse return false) == null,
    }
    return true;
}

fn applyProps(L: *c.lua_State, sc: *Scene, id: Id, idx: c_int) Failure {
    const node = sc.get(id) orelse return null;
    const kind = node.kind;
    const table = c.lua_absindex(L, idx);
    if (stringAt(L, table)) |text| {
        if (kind != .text) return "ui: only text nodes take a plain string";
        return setPlainText(sc, id, text);
    }
    if (c.lua_type(L, table) != c.LUA_TTABLE) return "ui: expected a props table";

    const count: usize = @intCast(c.lua_rawlen(L, table));
    if (count > 0) {
        const failure = switch (kind) {
            .box => readChildren(L, sc, id, table, count),
            .text => readSpans(L, sc, id, table, count),
            else => "ui: this node takes no array content",
        };
        if (failure) |message| return message;
    }

    c.lua_pushnil(L);
    while (c.lua_next(L, table) != 0) : (c.lua_pop(L, 1)) {
        if (c.lua_type(L, -2) != c.LUA_TSTRING) continue;
        const name = stringAt(L, -2).?;
        const prop = std.meta.stringToEnum(Prop, name) orelse return fail("unknown prop '{s}'", .{name});
        if (!applyProp(L, sc, id, prop)) return fail("invalid value for '{s}'", .{name});
    }
    sc.touch();
    return null;
}

fn construct(L: *c.lua_State, kind: scene.Kind, button: bool) c_int {
    const sc = sceneOf(L) orelse return pushHandle(L, .none);
    var failure: Failure = null;
    var id: Id = .none;
    {
        sc.lock();
        defer sc.unlock();
        if (sc.create(kind)) |created| {
            id = created;
            if (button) applyButtonDefaults(sc.get(id).?);
            if (c.lua_type(L, 1) > c.LUA_TNIL) failure = applyProps(L, sc, id, 1);
            if (failure != null) sc.destroy(id);
        } else |_| {
            failure = "ui: too many nodes";
        }
    }
    if (failure != null) return finish(L, sc, failure, 0);
    return finish(L, sc, null, pushHandle(L, id));
}

fn applyButtonDefaults(node: *scene.Node) void {
    node.dir = .row;
    node.padding = .{ .left = 1, .right = 1 };
    node.width = .fit;
    node.height = .fit;
    node.style = .{ .fg = .{ .theme = .text_hl }, .bg = .{ .theme = .border } };
    node.pressed_style = .{ .fg = .{ .theme = .bg }, .bg = .{ .theme = .info } };
}

fn luaBox(L: ?*c.lua_State) callconv(.c) c_int {
    return construct(L.?, .box, false);
}

fn luaText(L: ?*c.lua_State) callconv(.c) c_int {
    return construct(L.?, .text, false);
}

fn luaSpacer(L: ?*c.lua_State) callconv(.c) c_int {
    return construct(L.?, .spacer, false);
}

fn luaCanvas(L: ?*c.lua_State) callconv(.c) c_int {
    return construct(L.?, .canvas, false);
}

fn luaButton(L: ?*c.lua_State) callconv(.c) c_int {
    return construct(L.?, .box, true);
}

fn luaMount(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const sc = sceneOf(state) orelse {
        c.lua_settop(state, 2);
        return 1;
    };
    var failure: Failure = null;
    {
        sc.lock();
        defer sc.unlock();
        failure = mount(state, sc);
    }
    c.lua_settop(state, 2);
    return finish(state, sc, failure, 1);
}

fn mount(L: *c.lua_State, sc: *Scene) Failure {
    const name = stringAt(L, 1) orelse return "ui.mount: slot name expected";
    const node = readHandle(L, 2) orelse return "ui.mount: ui node expected";
    const slot = sc.findSlot(name) orelse return fail("unknown slot '{s}'", .{name});
    sc.attach(slot, node, null) catch |err| return attachFailure(err);
    return null;
}

fn luaRedraw(L: ?*c.lua_State) callconv(.c) c_int {
    const a = lua.getAppFromRegistry(L.?) orelse return 0;
    a.lua_redraw.store(true, .release);
    return 0;
}

const Method = enum { set, add, remove, clear, show, hide };

fn method(L: *c.lua_State, comptime which: Method) c_int {
    const id = readHandle(L, 1) orelse {
        _ = c.luaL_error(L, "ui node expected as self; call methods with ':'");
        return 0;
    };
    c.lua_settop(L, 3);
    const sc = sceneOf(L) orelse {
        c.lua_settop(L, 1);
        return 1;
    };
    var failure: Failure = null;
    {
        sc.lock();
        defer sc.unlock();
        if (sc.get(id)) |node| switch (which) {
            .set => failure = applyProps(L, sc, id, 2),
            .add => failure = addChild(L, sc, id),
            .remove => sc.destroy(id),
            .clear => sc.clearChildren(id),
            .show, .hide => {
                node.hidden = which == .hide;
                sc.touch();
            },
        };
    }
    c.lua_settop(L, 1);
    return finish(L, sc, failure, 1);
}

fn addChild(L: *c.lua_State, sc: *Scene, id: Id) Failure {
    const child = readHandle(L, 2) orelse return "ui: add expects a ui node";
    var position: ?usize = null;
    if (c.lua_type(L, 3) == c.LUA_TNUMBER) {
        const index = c.lua_tointegerx(L, 3, null);
        if (index < 1) return "ui: add index starts at 1";
        position = @intCast(index - 1);
    }
    sc.attach(id, child, position) catch |err| return attachFailure(err);
    return null;
}

fn luaNodeSet(L: ?*c.lua_State) callconv(.c) c_int {
    return method(L.?, .set);
}

fn luaNodeAdd(L: ?*c.lua_State) callconv(.c) c_int {
    return method(L.?, .add);
}

fn luaNodeRemove(L: ?*c.lua_State) callconv(.c) c_int {
    return method(L.?, .remove);
}

fn luaNodeClear(L: ?*c.lua_State) callconv(.c) c_int {
    return method(L.?, .clear);
}

fn luaNodeShow(L: ?*c.lua_State) callconv(.c) c_int {
    return method(L.?, .show);
}

fn luaNodeHide(L: ?*c.lua_State) callconv(.c) c_int {
    return method(L.?, .hide);
}

fn luaNodeGc(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const id = readHandle(state, 1) orelse return 0;
    const sc = sceneOf(state) orelse return 0;
    sc.orphan(id);
    return 0;
}

pub fn registerNodeMeta(L: *c.lua_State) void {
    if (c.luaL_newmetatable(L, NODE_META) != 0) {
        c.lua_createtable(L, 0, 6);
        inline for (.{
            .{ "set", &luaNodeSet },
            .{ "add", &luaNodeAdd },
            .{ "remove", &luaNodeRemove },
            .{ "clear", &luaNodeClear },
            .{ "show", &luaNodeShow },
            .{ "hide", &luaNodeHide },
        }) |binding| {
            c.lua_pushcfunction(L, binding[1]);
            c.lua_setfield(L, -2, binding[0]);
        }
        c.lua_setfield(L, -2, "__index");
        c.lua_pushcfunction(L, &luaNodeGc);
        c.lua_setfield(L, -2, "__gc");
    }
    c.lua_pop(L, 1);
}

const ColorDesc = "'#RRGGBB' or a theme color name (bg, overlay, muted, text, info, ok, warn, err, ...)";

const span_style_fields = [_]LuaType.Field{
    .{ .name = "fg", .ty = LuaType.string, .optional = true, .desc = "text color: " ++ ColorDesc },
    .{ .name = "bg", .ty = LuaType.string, .optional = true, .desc = "background color, inherited by children" },
    .{ .name = "bold", .ty = LuaType.boolean, .optional = true },
    .{ .name = "dim", .ty = LuaType.boolean, .optional = true },
    .{ .name = "italic", .ty = LuaType.boolean, .optional = true },
    .{ .name = "underline", .ty = LuaType.boolean, .optional = true },
    .{ .name = "reverse", .ty = LuaType.boolean, .optional = true },
    .{ .name = "strikethrough", .ty = LuaType.boolean, .optional = true },
};

const UiStyleDef = LuaType{ .table_def = .{ .name = "BlitzUiStyle", .fields = &span_style_fields } };

const UiSpanDef = LuaType{ .table_def = .{
    .name = "BlitzUiSpan",
    .fields = &([_]LuaType.Field{
        .{ .name = "[1]", .ty = LuaType.string, .desc = "span text, newlines start a new line" },
    } ++ span_style_fields),
} };

const UiPaddingDef = LuaType{ .table_def = .{ .name = "BlitzUiPadding", .fields = &.{
    .{ .name = "x", .ty = LuaType.integer, .optional = true, .desc = "left and right" },
    .{ .name = "y", .ty = LuaType.integer, .optional = true, .desc = "top and bottom" },
    .{ .name = "top", .ty = LuaType.integer, .optional = true },
    .{ .name = "right", .ty = LuaType.integer, .optional = true },
    .{ .name = "bottom", .ty = LuaType.integer, .optional = true },
    .{ .name = "left", .ty = LuaType.integer, .optional = true },
} } };

const UiCanvasBufDef = LuaType{ .table_def = .{ .name = "BlitzUiCanvasBuf", .fields = &.{
    .{ .name = "width", .ty = LuaType.integer, .desc = "canvas width in cells" },
    .{ .name = "height", .ty = LuaType.integer, .desc = "canvas height in cells" },
    .{ .name = "set", .ty = LuaType{ .raw = "fun(x: integer, y: integer, text: string)" }, .desc = "write text at canvas-relative coords, clipped to the canvas, theme text color" },
    .{ .name = "set_color", .ty = LuaType{ .raw = "fun(x: integer, y: integer, text: string, color: string)" }, .desc = "write text with a foreground color" },
    .{ .name = "fill", .ty = LuaType{ .raw = "fun(x: integer, y: integer, w: integer, h: integer, color: string)" }, .desc = "solid background fill" },
    .{ .name = "rect", .ty = LuaType{ .raw = "fun(x: integer, y: integer, w: integer, h: integer, color: string)" }, .desc = "one cell thick background outline" },
    .{ .name = "box", .ty = LuaType{ .raw = "fun(x: integer, y: integer, w: integer, h: integer, color: string)" }, .desc = "unicode line border in foreground color" },
} } };

const SizeType = LuaType{ .raw = "integer|\"fit\"|\"fill\"" };

const UiPropsDef = LuaType{ .table_def = .{
    .name = "BlitzUiProps",
    .fields = &([_]LuaType.Field{
        .{ .name = "[integer]", .ty = LuaType{ .raw_refs = .{ .text = "BlitzUiNode|BlitzUiSpan|string", .refs = &.{UiSpanDef} } }, .desc = "array part: child nodes of a box, or the content of a text node as strings and spans. On set it replaces the previous children or content; children left out are removed" },
        .{ .name = "width", .ty = SizeType, .optional = true, .desc = "cells, 'fit' the content, or 'fill' the parent. Unset: fit along the parent's direction, stretch across it" },
        .{ .name = "height", .ty = SizeType, .optional = true, .desc = "cells, 'fit' or 'fill', like width" },
        .{ .name = "grow", .ty = LuaType.integer, .optional = true, .desc = "share of the parent's free space along its direction; 0 keeps the fitted size" },
        .{ .name = "min_width", .ty = LuaType.integer, .optional = true },
        .{ .name = "min_height", .ty = LuaType.integer, .optional = true },
        .{ .name = "max_width", .ty = LuaType.integer, .optional = true },
        .{ .name = "max_height", .ty = LuaType.integer, .optional = true },
        .{ .name = "hidden", .ty = LuaType.boolean, .optional = true, .desc = "a hidden node takes no space" },
        .{ .name = "dir", .ty = LuaType{ .raw = "\"row\"|\"column\"" }, .optional = true, .desc = "box: direction children are laid out in, default 'column'" },
        .{ .name = "gap", .ty = LuaType.integer, .optional = true, .desc = "box: cells between children" },
        .{ .name = "padding", .ty = LuaType{ .raw_refs = .{ .text = "integer|BlitzUiPadding", .refs = &.{UiPaddingDef} } }, .optional = true, .desc = "box: cells between the edge and the children" },
        .{ .name = "border", .ty = LuaType{ .raw = "boolean|string" }, .optional = true, .desc = "box: true for a border in the theme border color, or a color" },
        .{ .name = "title", .ty = LuaType.string, .optional = true, .desc = "box: text on the top border" },
        .{ .name = "align", .ty = LuaType{ .raw = "\"stretch\"|\"start\"|\"center\"|\"end\"" }, .optional = true, .desc = "box: placement of children across the direction, default 'stretch'" },
        .{ .name = "wrap", .ty = LuaType.boolean, .optional = true, .desc = "text: wrap at the node width; unwrapped text is cut with an ellipsis" },
        .{ .name = "label", .ty = LuaType.string, .optional = true, .desc = "box: text of the first child, created when missing. The label of a button" },
        .{ .name = "on_click", .ty = LuaType{ .raw = "fun()|false" }, .optional = true, .desc = "runs after a left click on the node, on the main thread in the main VM. false removes it" },
        .{ .name = "key", .ty = LuaType{ .raw = "string|false" }, .optional = true, .desc = "key combo such as '<C-a>' that triggers on_click while the node is on screen. Wins over blitz.bind" },
        .{ .name = "disabled", .ty = LuaType.boolean, .optional = true, .desc = "ignore clicks and keys, draw muted" },
        .{ .name = "pressed", .ty = LuaType{ .raw_refs = .{ .text = "BlitzUiStyle|false", .refs = &.{UiStyleDef} } }, .optional = true, .desc = "style while the mouse button is held on the node" },
        .{ .name = "draw", .ty = LuaType{ .raw_refs = .{ .text = "fun(buf: BlitzUiCanvasBuf, frame: integer)|false", .refs = &.{UiCanvasBufDef} } }, .optional = true, .desc = "canvas: draw callback, runs on every drawn frame. A callback that errors is removed" },
    } ++ span_style_fields),
} };

const NodeMethod = LuaType{ .raw = "fun(self: BlitzUiNode): BlitzUiNode" };

const UiNodeDef = LuaType{ .table_def = .{ .name = "BlitzUiNode", .fields = &.{
    .{ .name = "set", .ty = LuaType{ .raw_refs = .{ .text = "fun(self: BlitzUiNode, props: BlitzUiProps|string): BlitzUiNode", .refs = &.{UiPropsDef} } }, .desc = "Merge props into the node. Only the given keys change. A text node also takes a plain string." },
    .{ .name = "add", .ty = LuaType{ .raw = "fun(self: BlitzUiNode, child: BlitzUiNode, index?: integer): BlitzUiNode" }, .desc = "Append a child to a box, or insert it at a 1-based index. A child that already has a parent moves." },
    .{ .name = "remove", .ty = NodeMethod, .desc = "Remove the node and everything below it for good. Its handles go dead; calls on a dead handle do nothing." },
    .{ .name = "clear", .ty = NodeMethod, .desc = "Remove every child of a box." },
    .{ .name = "show", .ty = NodeMethod, .desc = "Make a hidden node visible again." },
    .{ .name = "hide", .ty = NodeMethod, .desc = "Hide the node; its space returns to the layout." },
} } };

fn constructor(comptime fn_ptr: c.lua_CFunction) LuaType {
    return .{ .function = .{
        .args = &.{.{ .name = "props", .ty = UiPropsDef, .optional = true }},
        .ret = &UiNodeDef,
        .fn_ptr = fn_ptr,
    } };
}

pub const BlitzUi = LuaType{ .table_def = .{ .name = "BlitzUi", .fields = &.{
    .{
        .name = "box",
        .desc =
        \\Create a container. Children go in the array part and are laid
        \\out along dir. The scene is retained: Zig measures, lays out
        \\and draws it every frame without calling Lua, so build the tree
        \\once and change it with node:set, node:add and node:remove from
        \\hooks, binds and callbacks. A node that is neither mounted nor
        \\held by a handle is collected. Main VM only: in tool and
        \\listener VMs every constructor returns a dead handle.
        ,
        .ty = constructor(luaBox),
    },
    .{
        .name = "text",
        .desc =
        \\Create a text node. The array part is the content: strings and
        \\spans such as { "failed", fg = "err", bold = true }. Style keys
        \\on the node apply to every span. ui.text("plain") works too.
        ,
        .ty = LuaType{ .function = .{
            .args = &.{.{ .name = "props", .ty = LuaType{ .raw_refs = .{ .text = "BlitzUiProps|string", .refs = &.{UiPropsDef} } } }},
            .ret = &UiNodeDef,
            .fn_ptr = luaText,
        } },
    },
    .{
        .name = "spacer",
        .desc = "Create an empty node that takes the free space of its parent along the parent's direction.",
        .ty = constructor(luaSpacer),
    },
    .{
        .name = "button",
        .desc =
        \\Create a clickable box with a label, padding and a pressed
        \\style. Takes label, on_click and key plus every box prop.
        ,
        .ty = constructor(luaButton),
    },
    .{
        .name = "canvas",
        .desc =
        \\Create a node drawn by Lua through its draw callback. The only
        \\node that calls Lua per frame; give it a width and height or
        \\grow. A frame is skipped while another thread holds the main VM.
        ,
        .ty = constructor(luaCanvas),
    },
    .{
        .name = "mount",
        .desc =
        \\Put a node on screen in a named slot and return it. Slots:
        \\'left' and 'right' are full height columns beside the main
        \\column, 'between' sits between timeline and input, 'below'
        \\under the input. Nodes of one slot stack in mount order. The
        \\side slots give way while the main column would drop below 40
        \\columns, 'below' and then 'between' while the timeline would
        \\drop below 6 rows. node:remove() unmounts.
        ,
        .ty = LuaType{ .function = .{
            .args = &.{
                .{ .name = "slot", .ty = LuaType{ .raw = "\"left\"|\"right\"|\"between\"|\"below\"" } },
                .{ .name = "node", .ty = UiNodeDef },
            },
            .ret = &UiNodeDef,
            .fn_ptr = luaMount,
        } },
    },
    .{
        .name = "redraw",
        .desc = "Request a frame on the next loop tick. Node changes redraw on their own; canvas animations call this while the app is idle.",
        .ty = LuaType{ .function = .{ .fn_ptr = luaRedraw } },
    },
} } };
