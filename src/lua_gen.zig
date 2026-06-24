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

    try writeTableDefsForClass(w, lua.Blitz, &emitted_table_defs);
    try writeClass(w, lua.Blitz);
    try w.print("---@type {s}\nblitz = {{}}\n", .{className(lua.Blitz)});

    const file = try std.Io.Dir.cwd().createFile(init.io, "src/blitz_defs.lua", .{ .truncate = true });
    try file.writeStreamingAll(init.io, w.toArrayList().items);
}

fn writeClass(w: *std.Io.Writer, comptime T: type) !void {
    const info = @typeInfo(T).@"struct";

    try w.print("---@class {s}\n", .{className(T)});

    inline for (info.fields) |field| {
        try w.print("---@field {s} {s}\n", .{ field.name, className(field.type) });
    }

    inline for (info.decls) |decl| {
        if (decl.name[0] == '_') continue;
        const value = @field(T, decl.name);
        switch (@typeInfo(@TypeOf(value))) {
            .@"fn", .type => {},
            else => try w.print("---@field {s} {s}\n", .{ decl.name, luaType(@TypeOf(value)) }),
        }
    }

    if (@hasDecl(T, "_function_defs")) {
        inline for (T._function_defs) |def| {
            try writeFunctionField(w, T, def);
        }
    }

    try w.writeByte('\n');

    inline for (info.fields) |field| {
        try writeClass(w, field.type);
    }
}

fn writeTableDefsForClass(w: *std.Io.Writer, comptime T: type, emitted_table_defs: *std.StringHashMap(void)) !void {
    const info = @typeInfo(T).@"struct";

    if (@hasDecl(T, "_function_defs")) {
        inline for (T._function_defs) |def| {
            const args_info = @typeInfo(@TypeOf(def.args)).@"struct";
            inline for (args_info.fields) |field| {
                try writeTableDef(w, argType(@field(def.args, field.name)), emitted_table_defs);
            }
            if (@TypeOf(def.ret) != @TypeOf(null)) try writeTableDef(w, def.ret, emitted_table_defs);
        }
    }

    inline for (info.fields) |field| {
        try writeTableDefsForClass(w, field.type, emitted_table_defs);
    }
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
                try w.print("---@field {s}{s} {s}\n", .{
                    field.name,
                    if (field.optional) "?" else "",
                    luaTypeName(field.ty),
                });
            }
            try w.writeByte('\n');
        },
        .raw => {},
        .raw_refs => |raw| inline for (raw.refs) |ref| {
            try writeTableDef(w, ref, emitted_table_defs);
        },
        else => {},
    }
}

fn className(comptime T: type) []const u8 {
    const name = @typeName(T);
    return if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| name[i + 1 ..] else name;
}

fn writeFunctionField(w: *std.Io.Writer, comptime T: type, comptime def: anytype) !void {
    const name = comptime functionName(T, def.fn_ptr);

    try writeDoc(w, def.desc);
    try w.print("---@field {s} fun(", .{name});

    const args_info = @typeInfo(@TypeOf(def.args)).@"struct";
    inline for (args_info.fields, 0..) |field, i| {
        const arg = @field(def.args, field.name);
        if (i > 0) try w.writeAll(", ");
        try w.print("{s}{s}: {s}", .{
            argName(arg),
            if (argOptional(arg)) "?" else "",
            luaTypeName(argType(arg)),
        });
    }

    if (@TypeOf(def.ret) != @TypeOf(null)) {
        try w.print("): {s}\n", .{luaTypeName(def.ret)});
    } else {
        try w.writeAll(")\n");
    }
}

fn argName(comptime arg: anytype) []const u8 {
    return if (@hasField(@TypeOf(arg), "name")) arg.name else @field(arg, "0");
}

fn argType(comptime arg: anytype) lua.LuaType {
    return if (@hasField(@TypeOf(arg), "ty")) arg.ty else @field(arg, "1");
}

fn argOptional(comptime arg: anytype) bool {
    return if (@hasField(@TypeOf(arg), "optional")) arg.optional else false;
}

fn functionName(comptime T: type, comptime fn_ptr: anytype) []const u8 {
    inline for (@typeInfo(T).@"struct".decls) |decl| {
        if (decl.name[0] == '_') continue;
        const value = @field(T, decl.name);
        if (@TypeOf(value) == @TypeOf(fn_ptr) and value == fn_ptr) return decl.name;
    }
    @compileError("missing Lua function decl for " ++ @typeName(@TypeOf(fn_ptr)));
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

fn luaType(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .bool => "boolean",
        .comptime_int, .int, .@"enum" => "integer",
        .comptime_float, .float => "number",
        .void, .null => "nil",
        .pointer => |ptr| if (ptr.size == .slice and ptr.child == u8) "string" else "table",
        .array => "table",
        .@"struct" => "table",
        .optional => |opt| luaType(opt.child) ++ "|nil",
        else => "any",
    };
}
