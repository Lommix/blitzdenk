const std = @import("std");
const lua = @import("lua.zig");

pub fn main(init: std.process.Init) !void {
    var alloc_writer = std.Io.Writer.Allocating.init(init.arena.allocator());
    var w = &alloc_writer.writer;
    var emitted_table_defs = std.StringHashMap(void).init(init.arena.allocator());

    try w.writeAll(
        \\---Blitz Lua meta file
        \\---@meta
        \\
    );

    try writeTableDef(w, lua.Blitz, &emitted_table_defs);
    try w.print("---@type {s}\nblitz = {{}}\n", .{className(lua.Blitz)});

    const file = try std.Io.Dir.cwd().createFile(init.io, "src/blitz_defs.lua", .{ .truncate = true });
    try file.writeStreamingAll(init.io, w.toArrayList().items);
}

fn writeTableDef(w: *std.Io.Writer, comptime ty: lua.LuaType, emitted_table_defs: *std.StringHashMap(void)) !void {
    switch (ty) {
        .table_def => |def| {
            if (emitted_table_defs.contains(def.name)) return;
            try emitted_table_defs.put(def.name, {});
            inline for (def.fields) |field| {
                try writeTableDef(w, field.ty, emitted_table_defs);
            }
            try w.print("---@class {s}\n", .{def.name});
            inline for (def.fields) |field| {
                if (field.desc) |doc| try writeDoc(w, doc);
                try writeField(w, field);
            }
            try w.writeByte('\n');
        },
        .raw => {},
        .raw_refs => |raw| inline for (raw.refs) |ref| {
            try writeTableDef(w, ref, emitted_table_defs);
        },
        .function => |func| {
            inline for (func.args) |arg| try writeTableDef(w, arg.ty, emitted_table_defs);
            if (func.ret) |ret| try writeTableDef(w, ret.*, emitted_table_defs);
        },
        else => {},
    }
}

fn className(comptime ty: lua.LuaType) []const u8 {
    return switch (ty) {
        .table_def => |def| def.name,
        else => luaTypeName(ty),
    };
}

fn writeField(w: *std.Io.Writer, comptime field: lua.LuaType.Field) !void {
    switch (field.ty) {
        .function => |func| {
            try w.print("---@field {s}{s} fun(", .{ field.name, if (field.optional) "?" else "" });
            inline for (func.args, 0..) |arg, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("{s}{s}: {s}", .{
                    arg.name,
                    if (arg.optional) "?" else "",
                    luaTypeName(arg.ty),
                });
            }
            if (func.ret) |ret| {
                try w.print("): {s}\n", .{luaTypeName(ret.*)});
            } else {
                try w.writeAll(")\n");
            }
        },
        else => try w.print("---@field {s}{s} {s}\n", .{
            field.name,
            if (field.optional) "?" else "",
            luaTypeName(field.ty),
        }),
    }
}

fn writeDoc(w: *std.Io.Writer, doc: []const u8) !void {
    var it = std.mem.splitScalar(u8, doc, '\n');
    while (it.next()) |line| try w.print("---{s}\n", .{line});
}

fn luaTypeName(comptime ty: lua.LuaType) []const u8 {
    return switch (ty) {
        .raw => |raw| raw,
        .raw_refs => |raw| raw.text,
        .nil => "nil",
        .boolean => "boolean",
        .integer => "integer",
        .number => "number",
        .string => "string",
        .table => "table",
        .table_def => |def| def.name,
        .function => "function",
        .userdata => "userdata",
        .thread => "thread",
        .any => "any",
    };
}
