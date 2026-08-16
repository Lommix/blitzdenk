const std = @import("std");

pub fn schemaFrom(comptime T: type) []const u8 {
    return comptime schemaType(T);
}

fn schemaType(comptime T: type) []const u8 {
    const info = @typeInfo(T);
    return switch (info) {
        .optional => |optional| "{\"anyOf\":[" ++ schemaType(optional.child) ++ ",{\"type\":\"null\"}]}",
        .bool => "{\"type\":\"boolean\"}",
        .int, .comptime_int => "{\"type\":\"integer\"}",
        .float, .comptime_float => "{\"type\":\"number\"}",
        .@"enum" => blk: {
            comptime var result: []const u8 = "{\"type\":\"string\",\"enum\":[";
            inline for (info.@"enum".fields, 0..) |f, i| {
                if (i > 0) result = result ++ ",";
                result = result ++ "\"" ++ f.name ++ "\"";
            }
            break :blk result ++ "]}";
        },
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8)
                "{\"type\":\"string\"}"
            else
                "{\"type\":\"array\",\"items\":" ++ schemaType(p.child) ++ "}",
            else => "{\"type\":\"string\"}",
        },
        .array => |array| "{\"type\":\"array\",\"items\":" ++ schemaType(array.child) ++ "}",
        .@"struct" => |struct_info| blk: {
            if (struct_info.is_tuple) {
                comptime var result: []const u8 = "{\"type\":\"array\",\"prefixItems\":[";
                inline for (struct_info.fields, 0..) |field, i| {
                    if (i > 0) result = result ++ ",";
                    result = result ++ schemaType(field.type);
                }
                break :blk result ++ "]}";
            }
            comptime var result: []const u8 = "{\"type\":\"object\",\"properties\":{";
            inline for (struct_info.fields, 0..) |field, i| {
                if (i > 0) result = result ++ ",";
                result = result ++ "\"" ++ jsonName(T, field) ++ "\":" ++ fieldSchema(T, field);
            }
            result = result ++ "},\"required\":[";
            inline for (struct_info.fields, 0..) |field, i| {
                if (i > 0) result = result ++ ",";
                result = result ++ "\"" ++ jsonName(T, field) ++ "\"";
            }
            break :blk result ++ "],\"additionalProperties\":false}";
        },
        else => "{}",
    };
}

fn fieldSchema(
    comptime T: type,
    comptime field: std.builtin.Type.StructField,
) []const u8 {
    if (comptime schemaTag(T, field)) |tag| {
        comptime var result: []const u8 = "{";
        if (tag.description) |d| {
            result = result ++ "\"description\":\"" ++ d ++ "\",";
        }
        if (tag.enum_vals) |vals| {
            result = result ++ "\"type\":\"string\",\"enum\":[";
            comptime var first = true;
            comptime var it = std.mem.splitScalar(u8, vals, '|');
            inline while (comptime it.next()) |v| {
                if (!first) result = result ++ ",";
                first = false;
                result = result ++ "\"" ++ v ++ "\"";
            }
            return result ++ "]}";
        }
        const base = schemaType(field.type);
        return result ++ base[1..];
    }
    return schemaType(field.type);
}

fn jsonName(comptime T: type, comptime field: std.builtin.Type.StructField) []const u8 {
    if (comptime fieldHasDecl(T, field.name)) {
        const decl = @field(T, field.name ++ "_json");
        return decl;
    }
    return field.name;
}

fn fieldHasDecl(comptime T: type, comptime name: []const u8) bool {
    if (!@hasDecl(T, name ++ "_json")) return false;
    return true;
}

const TagInfo = struct {
    description: ?[]const u8 = null,
    enum_vals: ?[]const u8 = null,
};

fn schemaTag(comptime T: type, comptime field: std.builtin.Type.StructField) ?TagInfo {
    if (comptime std.mem.eql(u8, field.name, "_schema_tags")) return null;
    if (!@hasDecl(T, "_schema_tags")) return null;
    const tags = T._schema_tags;
    inline for (tags) |entry| {
        if (comptime std.mem.eql(u8, entry[0], field.name)) {
            return TagInfo{
                .description = entry[1],
                .enum_vals = entry[2],
            };
        }
    }
    return null;
}

test "schema from struct" {
    const Person = struct {
        pub const _schema_tags = .{
            .{ "name", "The person name", null },
        };
        name: []const u8,
        age: u32,
    };
    const s = schemaFrom(Person);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"integer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"required\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "The person name") != null);
}

test "schema optional and slice" {
    const T = struct {
        tags: []const []const u8,
        note: ?[]const u8 = null,
    };
    const s = schemaFrom(T);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"array\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"null\"") != null);
}
