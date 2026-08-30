const std = @import("std");
const builtin = @import("builtin");
const app = @import("app.zig");
const c = @import("c");
const Allocator = std.mem.Allocator;
const tui = @import("tui/root.zig");
const keys = @import("keys.zig");
const tl = @import("tools/root.zig");
const log = std.log.scoped(.lua);
const r = @import("root.zig");
const lua_state = @import("lua_state.zig");
const lua = @This();

fn hookLog(comptime level: std.log.Level, comptime fmt: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    switch (level) {
        .err => log.err(fmt, args),
        .warn => log.warn(fmt, args),
        else => log.info(fmt, args),
    }
}

pub const REQ_STATUS_PENDING: c_int = 0;
pub const REQ_STATUS_APPROVED: c_int = 1;
pub const REQ_STATUS_DENIED: c_int = 2;
pub const REQ_STATUS_CHOICE: c_int = 3;
pub const REQ_STATUS_MESSAGE: c_int = 4;
pub const AWAIT_COMPLETE: c_int = 1;
pub const AWAIT_FAILED: c_int = 2;
pub const AWAIT_CANCELED: c_int = 3;
pub const AWAIT_INVALID: c_int = 4;
// ----------------------------

const LuaFnRef = struct {
    idx: c_int,
};

const LuaTableRef = struct {
    idx: c_int,
};

/// Comptime Helper to convert zig function to lua
pub fn LuaFnBind(
    comptime func: anytype,
    comptime name: []const u8,
) fn (?*c.lua_State) callconv(.c) c_int {
    const FnInfo = @typeInfo(@TypeOf(func)).@"fn";

    comptime var arg_types: [FnInfo.params.len]type = undefined;
    inline for (FnInfo.params, 0..) |p, i| arg_types[i] = p.type.?;
    const Args = @Tuple(&arg_types);

    return struct {
        fn lua_fn(L: ?*c.lua_State) callconv(.c) c_int {
            const state = L orelse @panic("lua vm gone? What happened");

            var args: Args = undefined;
            var offset: c_int = 1;

            inline for (FnInfo.params, 0..) |p, i| {
                switch (p.type.?) {
                    *r.app.App => {
                        @field(args, std.fmt.comptimePrint("{}", .{i})) = getAppFromRegistry(state) orelse {
                            _ = c.luaL_error(state, "failed to get app");
                            return 0;
                        };
                    },
                    *c.lua_State => {
                        @field(args, std.fmt.comptimePrint("{}", .{i})) = state;
                    },
                    else => |any| {
                        const vm = fromState(state) orelse {
                            _ = c.luaL_error(state, "failed to get lua vm");
                            return 0;
                        };

                        switch (readAnyValueAlloc(any, state, name, @as(c_int, offset), vm.luaArena())) {
                            .ok => |val| {
                                @field(args, std.fmt.comptimePrint("{}", .{i})) = val;
                            },
                            .err => |msg| {
                                _ = c.luaL_error(state, "%s", msg.ptr);
                                return 0;
                            },
                        }

                        offset += 1;
                    },
                }
            }

            if (FnInfo.return_type) |ret_type| {
                const RetInfo = @typeInfo(ret_type);
                const ret: ret_type = @call(.auto, func, args);

                switch (RetInfo) {
                    .error_union => |eun| {
                        const value = ret catch |err| {
                            _ = c.luaL_error(state, "function '" ++ name ++ "' failed with '%s'", @errorName(err).ptr);
                            return 0;
                        };

                        const Info = @typeInfo(eun.payload);
                        switch (Info) {
                            .void => return 0,
                            .optional => {
                                if (value) |inner| {
                                    pushAny(state, inner);
                                } else {
                                    c.lua_pushnil(state);
                                }
                                return 1;
                            },
                            .@"struct" => |str| {
                                if (str.is_tuple) {
                                    inline for (value) |s| {
                                        pushAny(state, s);
                                    }
                                    return value.len;
                                }

                                pushAny(state, value);
                                return 1;
                            },
                            else => {
                                pushAny(state, value);
                                return 1;
                            },
                        }
                    },
                    else => @compileError("must return error union"),
                }
            }
        }
    }.lua_fn;
}

pub const LuaType = union(enum) {
    raw: []const u8,
    raw_refs: struct {
        text: []const u8,
        refs: []const LuaType = &.{},
    },
    boolean,
    integer,
    number,
    string,
    table,
    table_def: struct {
        name: []const u8,
        fields: []const Field,
    },
    function: struct {
        args: []const Field = &.{},
        ret: ?*const LuaType = null,
        fn_ptr: c.lua_CFunction = null,
    },
    any,

    pub const Value = union(enum) {
        integer: c.lua_Integer,
        string: []const u8,
    };

    pub const Field = struct {
        name: []const u8,
        ty: LuaType,
        desc: ?[]const u8 = null,
        optional: bool = false,
        value: ?Value = null,
    };
};

const LuaInteger: LuaType = .integer;
const LuaNumber: LuaType = .number;
const LuaString: LuaType = .string;
const LuaAny: LuaType = .any;
const AgentIdOrNilDef = LuaType{ .raw = "integer|nil" };
const StringOrNilDef = LuaType{ .raw = "string|nil" };
const JsonEncodeRet = LuaType{ .raw = "string|nil, boolean" };
const JsonDecodeRet = LuaType{ .raw = "any, boolean" };
const Base64Ret = LuaType{ .raw = "string|nil, boolean" };

const StringListDef = LuaType{ .raw = "string[]" };
const CapabilityRuleListDef = LuaType{ .raw_refs = .{ .text = "BlitzCapabilityRule[]", .refs = &.{CapabilityRuleDef} } };
const CapabilityRuleDef = LuaType{ .table_def = .{ .name = "BlitzCapabilityRule", .fields = &.{
    .{ .name = "binary", .ty = LuaType.string, .desc = "binary resolved on PATH" },
    .{ .name = "rule", .ty = LuaType.string, .desc = "prompt line added when the binary exists" },
} } };
const ToolResultDef = LuaType{ .table_def = .{ .name = "BlitzToolResult", .fields = &.{
    .{ .name = "msg", .ty = LuaType.string, .optional = true },
    .{ .name = "img", .ty = LuaType.table, .optional = true, .desc = "{ media_type = string, data = string }" },
    .{ .name = "exit_loop", .ty = LuaType.boolean, .optional = true },
} } };
const AgentIdDef: LuaType = .integer;
const CtxDef = LuaType{ .table_def = .{ .name = "BlitzCtx", .fields = &.{
    .{ .name = "cwd", .ty = LuaType.string },
    .{ .name = "agent_id", .ty = AgentIdDef },
    .{ .name = "state", .ty = LuaType.table },
    .{ .name = "set_status", .ty = LuaType{ .raw = "fun(self: BlitzCtx, msg: string)" }, .desc = "Set the tool status text. May contain ANSI SGR escape codes for styling, and newlines for multiple lines." },
    .{ .name = "set_child_id", .ty = LuaType{ .raw = "fun(self: BlitzCtx, agent_id: integer)" } },
    .{ .name = "approve", .ty = LuaType{ .raw = "fun(self: BlitzCtx, description: string): integer, string|nil" } },
    .{ .name = "plan", .ty = LuaType{ .raw = "fun(self: BlitzCtx, path: string, plan_text: string): integer, string|nil" } },
    .{ .name = "ask", .ty = LuaType{ .raw = "fun(self: BlitzCtx, header: string, question: string, options: string[]): integer, string|nil" } },
} } };
const CallDef = LuaType{ .table_def = .{ .name = "BlitzCall", .fields = &.{
    .{ .name = "id", .ty = LuaType.string },
    .{ .name = "name", .ty = LuaType.string },
    .{ .name = "arguments", .ty = LuaType.table },
} } };
const ToolArgDef = LuaType{ .table_def = .{ .name = "BlitzArgDef", .fields = &.{
    .{ .name = "type", .ty = LuaType.string },
    .{ .name = "description", .ty = LuaType.string },
    .{ .name = "required", .ty = LuaType.boolean, .optional = true },
} } };
const TokenUsageDef = LuaType{ .table_def = .{ .name = "BlitzTokenUsage", .fields = &.{
    .{ .name = "input", .ty = LuaType.integer },
    .{ .name = "output", .ty = LuaType.integer },
    .{ .name = "cache", .ty = LuaType.integer },
    .{ .name = "cache_creation", .ty = LuaType.integer },
    .{ .name = "cost", .ty = LuaType.number, .desc = "total lifetime cost in USD" },
} } };
const ThinkingDef = LuaType{ .table_def = .{ .name = "BlitzThinking", .fields = &.{
    .{ .name = "type", .ty = LuaType.string },
    .{ .name = "budget_tokens", .ty = LuaType.integer, .optional = true },
} } };
const ModelCostDef = LuaType{ .table_def = .{ .name = "BlitzModelCost", .fields = &.{
    .{ .name = "input", .ty = LuaType.number, .desc = "price per 1M input tokens" },
    .{ .name = "output", .ty = LuaType.number, .desc = "price per 1M output tokens" },
    .{ .name = "cache", .ty = LuaType.number, .desc = "price per 1M cache-read tokens" },
} } };
const ModelDef = LuaType{ .table_def = .{ .name = "BlitzModelDef", .fields = &.{
    .{ .name = "name", .ty = LuaType.string, .desc = "the API model id" },
    .{ .name = "provider", .ty = LuaType.integer, .desc = "provider handle from add_provider" },
    .{ .name = "vision", .ty = LuaType.boolean, .optional = true, .desc = "model supports images" },
    .{ .name = "replay_reasoning", .ty = LuaType.boolean, .optional = true, .desc = "replay reasoning text as reasoning_content (deepseek/glm style)" },
    .{ .name = "cost", .ty = ModelCostDef, .optional = true, .desc = "price per 1M tokens; absent = free" },
} } };
const ProviderDef = LuaType{ .table_def = .{ .name = "BlitzProviderDef", .fields = &.{
    .{ .name = "type", .ty = LuaType.string, .desc = "'openai' | 'response' | 'anthropic' | 'ollama'" },
    .{ .name = "url", .ty = LuaType.string, .desc = "the endpoint url" },
    .{ .name = "key_envar", .ty = LuaType.string, .optional = true, .desc = "the ENVAR holding the api key (not the key itself!)" },
    .{ .name = "key", .ty = LuaType.string, .optional = true, .desc = "stored api key; the envar wins when both are set" },
    .{ .name = "temperature", .ty = LuaType.number, .optional = true },
    .{ .name = "max_tokens", .ty = LuaType.integer, .optional = true },
    .{ .name = "max_completion_tokens", .ty = LuaType.integer, .optional = true },
    .{ .name = "max_output_tokens", .ty = LuaType.integer, .optional = true },
    .{ .name = "top_p", .ty = LuaType.number, .optional = true },
    .{ .name = "top_k", .ty = LuaType.integer, .optional = true },
    .{ .name = "frequency_penalty", .ty = LuaType.number, .optional = true },
    .{ .name = "presence_penalty", .ty = LuaType.number, .optional = true },
    .{ .name = "enable_thinking", .ty = LuaType.boolean, .optional = true },
    .{ .name = "thinking", .ty = ThinkingDef, .optional = true },
    .{ .name = "rate_limit", .ty = LuaType.integer, .optional = true, .desc = "requests per minute; 0 = unlimited" },
} } };

const ThemeDef = LuaType{ .table_def = .{ .name = "BlitzTheme", .fields = &.{
    .{ .name = "bg", .ty = LuaType.string, .optional = true },
    .{ .name = "overlay_dark", .ty = LuaType.string, .optional = true },
    .{ .name = "overlay", .ty = LuaType.string, .optional = true },
    .{ .name = "muted", .ty = LuaType.string, .optional = true },
    .{ .name = "text", .ty = LuaType.string, .optional = true },
    .{ .name = "text_hl", .ty = LuaType.string, .optional = true },
    .{ .name = "ok", .ty = LuaType.string, .optional = true },
    .{ .name = "info", .ty = LuaType.string, .optional = true },
    .{ .name = "warn", .ty = LuaType.string, .optional = true },
    .{ .name = "err", .ty = LuaType.string, .optional = true },
    .{ .name = "on_err", .ty = LuaType.string, .optional = true },
    .{ .name = "diff_surface", .ty = LuaType.string, .optional = true },
    .{ .name = "diff_add", .ty = LuaType.string, .optional = true },
    .{ .name = "diff_remove", .ty = LuaType.string, .optional = true },
    .{ .name = "role_user", .ty = LuaType.string, .optional = true },
    .{ .name = "role_agent", .ty = LuaType.string, .optional = true },
    .{ .name = "role_system", .ty = LuaType.string, .optional = true },
} } };

const ThemeArg = struct {
    bg: ?[]const u8 = null,
    overlay_dark: ?[]const u8 = null,
    overlay: ?[]const u8 = null,
    muted: ?[]const u8 = null,
    text: ?[]const u8 = null,
    text_hl: ?[]const u8 = null,
    ok: ?[]const u8 = null,
    info: ?[]const u8 = null,
    warn: ?[]const u8 = null,
    err: ?[]const u8 = null,
    on_err: ?[]const u8 = null,
    diff_surface: ?[]const u8 = null,
    diff_add: ?[]const u8 = null,
    diff_remove: ?[]const u8 = null,
    role_user: ?[]const u8 = null,
    role_agent: ?[]const u8 = null,
    role_system: ?[]const u8 = null,
};

fn applyTheme(a: *r.app.App, theme: ThemeArg) !void {
    const C = r.tui.Color;
    const t = &a.theme;
    if (theme.bg) |v| t.bg = try C.parseStrHex(v);
    if (theme.overlay_dark) |v| t.overlay_dark = try C.parseStrHex(v);
    if (theme.overlay) |v| t.overlay = try C.parseStrHex(v);
    if (theme.muted) |v| t.muted = try C.parseStrHex(v);
    if (theme.text) |v| t.text = try C.parseStrHex(v);
    if (theme.text_hl) |v| t.text_hl = try C.parseStrHex(v);
    if (theme.ok) |v| t.ok = try C.parseStrHex(v);
    if (theme.info) |v| t.info = try C.parseStrHex(v);
    if (theme.warn) |v| t.warn = try C.parseStrHex(v);
    if (theme.err) |v| t.err = try C.parseStrHex(v);
    if (theme.on_err) |v| t.on_err = try C.parseStrHex(v);
    if (theme.diff_surface) |v| t.diff_surface = try C.parseStrHex(v);
    if (theme.diff_add) |v| t.diff_add = try C.parseStrHex(v);
    if (theme.diff_remove) |v| t.diff_remove = try C.parseStrHex(v);
    if (theme.role_user) |v| t.role_user = try C.parseStrHex(v);
    if (theme.role_agent) |v| t.role_agent = try C.parseStrHex(v);
    if (theme.role_system) |v| t.role_system = try C.parseStrHex(v);
    a.dirty = true;
}

const ToolArgsDef = LuaType{ .raw_refs = .{ .text = "table<string, BlitzArgDef>", .refs = &.{ToolArgDef} } };
const ToolDef = LuaType{ .table_def = .{ .name = "ToolDef", .fields = &.{
    .{ .name = "name", .ty = LuaType.string },
    .{ .name = "description", .ty = LuaType.string },
    .{ .name = "schema", .ty = LuaType.string, .optional = true },
    .{ .name = "args", .ty = ToolArgsDef, .optional = true },
    .{ .name = "snippet", .ty = LuaType.string, .optional = true },
    .{ .name = "guidelines", .ty = LuaType.string, .optional = true },
    .{ .name = "func", .ty = LuaType{ .raw_refs = .{
        .text = "fun(ctx: BlitzCtx, call: BlitzCall): BlitzToolResult",
        .refs = &.{ CtxDef, CallDef, ToolResultDef },
    } } },
} } };
const AgentDef = LuaType{ .table_def = .{ .name = "BlitzAgentDef", .fields = &.{
    .{ .name = "name", .ty = LuaType.string },
    .{ .name = "description", .ty = LuaType.string },
    .{ .name = "prompt", .ty = LuaType.string },
    .{ .name = "tools", .ty = StringListDef },
    .{ .name = "model", .ty = LuaType.integer, .optional = true, .desc = "model handle from add_model" },
    .{ .name = "effort", .ty = LuaType.string, .optional = true },
    .{ .name = "in_agent_tool", .ty = LuaType.boolean, .optional = true },
} } };
const AppFlagsDef = LuaType{ .table_def = .{ .name = "BlitzAppFlags", .fields = &.{
    .{ .name = "show_thinking", .ty = LuaType.boolean, .optional = true },
    .{ .name = "debug_log", .ty = LuaType.boolean, .optional = true },
    .{ .name = "approval_mode", .ty = LuaType.string, .optional = true, .desc = "strict|default|yolo|smart" },
} } };
const FlagsStrings = struct {
    show_thinking: ?bool = null,
    debug_log: ?bool = null,
    approval_mode: ?[]const u8 = null,
};
const McpServerDef = LuaType{ .table_def = .{ .name = "BlitzMcpServerDef", .fields = &.{
    .{ .name = "name", .ty = LuaType.string },
    .{ .name = "command", .ty = LuaType.string },
    .{ .name = "transport", .ty = LuaType.string, .optional = true },
    .{ .name = "args", .ty = StringListDef, .optional = true },
    .{ .name = "tools_prefix", .ty = LuaType.string, .optional = true },
} } };
const SpawnAgentArgsDef = LuaType{ .table_def = .{ .name = "BlitzSpawnArgs", .fields = &.{
    .{ .name = "parent_id", .ty = AgentIdDef, .optional = true },
    .{ .name = "prompt", .ty = LuaType.string },
    .{ .name = "agent_type", .ty = LuaType.integer, .optional = true },
    .{ .name = "fork", .ty = LuaType.boolean, .optional = true },
} } };
const SelectRequestDef = LuaType{ .table_def = .{ .name = "BlitzSelectRequest", .fields = &.{
    .{ .name = "header", .ty = LuaType.string, .desc = "very short label shown as a chip" },
    .{ .name = "question", .ty = LuaType.string, .desc = "the question shown above the options" },
    .{ .name = "options", .ty = StringListDef, .desc = "1-8 option strings; a custom message row is appended when allow_message is on" },
    .{ .name = "allow_message", .ty = LuaType.boolean, .optional = true, .desc = "show the trailing custom message row; default false" },
} } };
pub const Blitz = LuaType{
    .table_def = .{
        .name = "Blitz",
        .fields = &.{
            .{ .name = "mcp", .ty = BlitzMcp },
            .{ .name = "json", .ty = BlitzJson },
            .{ .name = "base64", .ty = BlitzBase64 },
            .{ .name = "cmd", .ty = BlitzCmd },
            .{ .name = "tools", .ty = BlitzToolDef },
            .{ .name = "hooks", .ty = BlitzHooks },
            .{ .name = "AGENT_GENERAL", .ty = LuaType.integer, .value = .{ .integer = 0 } },
            .{ .name = "REQ_STATUS_PENDING", .ty = LuaType.integer, .value = .{ .integer = lua.REQ_STATUS_PENDING } },
            .{ .name = "REQ_STATUS_APPROVED", .ty = LuaType.integer, .value = .{ .integer = lua.REQ_STATUS_APPROVED } },
            .{ .name = "REQ_STATUS_DENIED", .ty = LuaType.integer, .value = .{ .integer = lua.REQ_STATUS_DENIED } },
            .{ .name = "REQ_STATUS_CHOICE", .ty = LuaType.integer, .value = .{ .integer = lua.REQ_STATUS_CHOICE } },
            .{ .name = "REQ_STATUS_MESSAGE", .ty = LuaType.integer, .value = .{ .integer = lua.REQ_STATUS_MESSAGE } },
            .{ .name = "AWAIT_COMPLETE", .ty = LuaType.integer, .value = .{ .integer = lua.AWAIT_COMPLETE } },
            .{ .name = "AWAIT_FAILED", .ty = LuaType.integer, .value = .{ .integer = lua.AWAIT_FAILED } },
            .{ .name = "AWAIT_CANCELED", .ty = LuaType.integer, .value = .{ .integer = lua.AWAIT_CANCELED } },
            .{ .name = "AWAIT_INVALID", .ty = LuaType.integer, .value = .{ .integer = lua.AWAIT_INVALID } },
            .{
                .name = "register_tool",
                .desc = "Register a tool.",
                .ty = LuaType{
                    .function = .{
                        .args = &.{.{ .name = "def", .ty = ToolDef }},
                        .ret = &LuaString,
                        .fn_ptr = LuaFnBind((struct {
                            fn luafn(a: *r.app.App, state: *c.lua_State, def: LuaTableRef) ![]const u8 {
                                _ = a;
                                const vm = fromState(state) orelse return error.NoLuaVm;
                                if (vm.tool_entries.items.len >= MAX_LUA_TOOLS) return error.TooManyTools;

                                var entry: LuaToolEntry = .{};

                                entry.name_len = getStringField(state, def.idx, "name", &entry.name) orelse return error.InvalidToolName;
                                entry.desc_len = getStringField(state, def.idx, "description", &entry.description) orelse return error.InvalidToolDescription;
                                if (getStringField(state, def.idx, "snippet", &entry.snippet)) |len| {
                                    entry.snippet_len = len;
                                }
                                if (getStringField(state, def.idx, "guidelines", &entry.guidelines)) |len| {
                                    entry.guidelines_len = len;
                                }

                                if (getStringField(state, def.idx, "schema", &entry.schema)) |len| {
                                    entry.schema_len = len;
                                } else {
                                    _ = c.lua_getfield(state, def.idx, "args");
                                    defer c.lua_pop(state, 1);
                                    const args_type = c.lua_type(state, -1);
                                    if (args_type == c.LUA_TTABLE) {
                                        const json = try argsTableToJsonSchema(state, -1, &entry.schema);
                                        entry.schema_len = json.len;
                                    } else if (args_type == c.LUA_TNIL) {
                                        const schema = "{\"type\":\"object\",\"properties\":{}}";
                                        @memcpy(entry.schema[0..schema.len], schema);
                                        entry.schema_len = schema.len;
                                    } else return error.InvalidToolArgs;
                                }

                                entry.L = state;
                                _ = c.lua_getfield(state, def.idx, "func");
                                if (c.lua_type(state, -1) != c.LUA_TFUNCTION) return error.InvalidToolFunc;
                                entry.func_ref = c.luaL_ref(state, c.LUA_REGISTRYINDEX);

                                c.lua_newtable(state);
                                entry.state_ref = c.luaL_ref(state, c.LUA_REGISTRYINDEX);

                                vm.tool_entries.appendAssumeCapacity(entry);
                                return vm.tool_entries.items[vm.tool_entries.items.len - 1].nameSlice();
                            }
                        }).luafn, "register_tool"),
                    },
                },
            },
            .{
                .name = "add_tool",
                .desc = "Add a single tool from the tool pool to an agent type's tool set.",
                .ty = LuaType{
                    .function = .{
                        .args = &.{ .{ .name = "agent_type", .ty = LuaType.integer }, .{ .name = "tool_name", .ty = LuaType.string } },
                        .fn_ptr = LuaFnBind((struct {
                            fn lua_fn(state: *c.lua_State, a: *r.app.App, agent_type_id: u32, tool_name: []const u8) !void {
                                if (try isToolVm(state)) return;
                                try a.cmd_queue.append(a.io, .{ .add_tool = .{
                                    .agent_type = try r.ContextFactory.AgentType.fromLuaInt(agent_type_id),
                                    .tool_name = tool_name,
                                } });
                            }
                        }).lua_fn, "add_tool"),
                    },
                },
            },
            .{ .name = "get_main_agent", .desc = "Return the main agent, if a session is running.", .ty = LuaType{ .function = .{ .ret = &AgentIdOrNilDef, .fn_ptr = LuaFnBind((struct {
                fn lua_fn(a: *r.app.App) !?r.AgentId {
                    return a.main_agent_id;
                }
            }).lua_fn, "get_main_agent") } } },
            .{
                .name = "exit_loop",
                .desc = "Exit the agent loop with a message.",
                .ty = LuaType{ .function = .{
                    .args = &.{.{ .name = "content", .ty = LuaType.string, .optional = true }},
                    .ret = &ToolResultDef,
                    .fn_ptr = LuaFnBind((struct {
                        const Ret = struct { exit_loop: bool, msg: []const u8 };
                        fn lua_fn(content: ?[]const u8) !Ret {
                            return .{ .exit_loop = true, .msg = content orelse "" };
                        }
                    }).lua_fn, "exit_loop"),
                } },
            },
            .{
                .name = "add_provider",
                .desc = "Register a provider.",
                .ty = LuaType{
                    .function = .{
                        .args = &.{.{ .name = "def", .ty = ProviderDef }},
                        .ret = &LuaInteger,
                        .fn_ptr = LuaFnBind((struct {
                            const Arg = struct {
                                type: []const u8,
                                url: []const u8,
                                key_envar: ?[]const u8 = null,
                                key: ?[]const u8 = null,
                                temperature: ?f32 = null,
                                max_tokens: ?u32 = null,
                                max_completion_tokens: ?u32 = null,
                                max_output_tokens: ?u32 = null,
                                top_p: ?f32 = null,
                                top_k: ?u32 = null,
                                frequency_penalty: ?f32 = null,
                                presence_penalty: ?f32 = null,
                                enable_thinking: ?bool = true,
                                thinking: ?r.models.Thinking = null,
                                rate_limit: ?u32 = null,
                            };

                            fn lua_fn(state: *c.lua_State, a: *r.app.App, args: Arg) !r.config.ProviderHandle {
                                if (try isToolVm(state)) return @enumFromInt(0);
                                const slot = a.config.reserveProvider(args.url, args.key_envar orelse "", args.key orelse "") orelse return error.MaxProviderReached;
                                slot.rate_limit = args.rate_limit orelse 0;

                                const ptype: r.models.Kind = blk: {
                                    if (std.mem.eql(u8, args.type, "openai")) break :blk .openai;
                                    if (std.mem.eql(u8, args.type, "response")) break :blk .response;
                                    if (std.mem.eql(u8, args.type, "anthropic")) break :blk .anthropic;
                                    if (std.mem.eql(u8, args.type, "ollama")) break :blk .ollama;
                                    return error.UnknownProviderType;
                                };

                                slot.provider_config = switch (ptype) {
                                    .openai => .{ .openai = .{
                                        .temperature = args.temperature,
                                        .max_tokens = args.max_tokens orelse 32000,
                                        .max_completion_tokens = args.max_completion_tokens,
                                        .enable_thinking = args.enable_thinking,
                                        .top_p = args.top_p,
                                        .top_k = args.top_k,
                                        .frequency_penalty = args.frequency_penalty,
                                        .presence_penalty = args.presence_penalty,
                                    } },
                                    .response => .{ .response = .{
                                        .temperature = args.temperature,
                                        .max_output_tokens = args.max_output_tokens orelse args.max_tokens orelse 32000,
                                        .top_p = args.top_p,
                                    } },
                                    .anthropic => .{ .anthropic = .{
                                        .max_tokens = args.max_tokens orelse 32000,
                                        .thinking = args.thinking,
                                        .temperature = args.temperature,
                                        .top_p = args.top_p,
                                        .top_k = args.top_k,
                                    } },
                                    .ollama => .{ .ollama = .{
                                        .temperature = args.temperature,
                                        .max_tokens = args.max_tokens orelse 32000,
                                        .top_p = args.top_p,
                                        .top_k = args.top_k,
                                    } },
                                };

                                return a.config.commitProvider();
                            }
                        }).lua_fn, "add_provider"),
                    },
                },
            },
            .{
                .name = "add_model",
                .desc = "Register a model with provider, vision capability and cost.",
                .ty = LuaType{
                    .function = .{
                        .args = &.{.{ .name = "def", .ty = ModelDef }},
                        .ret = &LuaInteger,
                        .fn_ptr = LuaFnBind((struct {
                            const Arg = struct {
                                name: []const u8,
                                provider: u32,
                                vision: ?bool = null,
                                replay_reasoning: ?bool = null,
                                cost: ?r.config.ModelCost = null,
                            };

                            fn lua_fn(state: *c.lua_State, a: *r.app.App, args: Arg) !r.config.ModelHandle {
                                if (try isToolVm(state)) return @enumFromInt(0);
                                return a.config.addModel(args.name, @enumFromInt(args.provider), args.vision orelse false, args.replay_reasoning orelse false, args.cost);
                            }
                        }).lua_fn, "add_model"),
                    },
                },
            },
            .{
                .name = "add_agent",
                .desc = "Register a complete agent configuration.",
                .ty = LuaType{
                    .function = .{
                        .args = &.{.{ .name = "def", .ty = AgentDef }},
                        .ret = &LuaInteger,
                        .fn_ptr = LuaFnBind((struct {
                            const Args = struct {
                                name: []const u8,
                                description: []const u8,
                                prompt: []const u8,
                                tools: [][]const u8,
                                model: ?u32 = null,
                                effort: ?[]const u8,
                                in_agent_tool: ?bool,
                            };

                            fn lua_fn(state: *c.lua_State, a: *r.app.App, def: Args) !u32 {
                                if (try isToolVm(state)) return 0;
                                const effort = if (def.effort) |eff|
                                    r.config.parseReasoningEffort(eff) orelse return error.UnknownEffortType
                                else
                                    .medium;

                                const agent_type = try a.context_factory.addAgent(&a.config, .{
                                    .name = def.name,
                                    .description = def.description,
                                    .prompt = def.prompt,
                                    .in_agent_tool = def.in_agent_tool orelse true,
                                    .tools = def.tools,
                                    .model = if (def.model) |handle| .{
                                        .model = @enumFromInt(handle),
                                        .effort = effort,
                                    } else null,
                                });

                                return @intFromEnum(agent_type);
                            }
                        }).lua_fn, "add_agent"),
                    },
                },
            },
            .{
                .name = "set_agent_model",
                .desc = "Set the model config for a specific agent.",
                .ty = LuaType{
                    .function = .{
                        .args = &.{
                            .{ .name = "agent_type", .ty = LuaType.integer },
                            .{ .name = "model", .ty = LuaType.integer, .desc = "model handle from add_model" },
                            .{ .name = "force", .ty = LuaType.boolean, .optional = true, .desc = "also swap the model on live agents of this type" },
                        },
                        .fn_ptr = LuaFnBind((struct {
                            fn lua_fn(state: *c.lua_State, a: *r.app.App, agent_type_id: u32, model: u32, force: ?bool) !void {
                                if (try isToolVm(state)) return;
                                const agent_type = try r.ContextFactory.AgentType.fromLuaInt(agent_type_id);
                                try a.context_factory.setAgentModel(&a.config, agent_type, @enumFromInt(model));
                                try a.refreshLiveAgentTools();
                                if (force orelse false) try a.refreshLiveAgentModels(agent_type);
                            }
                        }).lua_fn, "set_agent_model"),
                    },
                },
            },
            .{
                .name = "set_agent_effort",
                .desc = "Set the reasoning effort for an agent type without touching its model.",
                .ty = LuaType{
                    .function = .{
                        .args = &.{
                            .{ .name = "agent_type", .ty = LuaType.integer },
                            .{ .name = "effort", .ty = LuaType.string, .desc = "none|low|medium|high|xhigh|max" },
                            .{ .name = "force", .ty = LuaType.boolean, .optional = true, .desc = "also swap the effort on live agents of this type" },
                        },
                        .fn_ptr = LuaFnBind((struct {
                            fn lua_fn(state: *c.lua_State, a: *r.app.App, agent_type_id: u32, effort: []const u8, force: ?bool) !void {
                                if (try isToolVm(state)) return;
                                const agent_type = try r.ContextFactory.AgentType.fromLuaInt(agent_type_id);
                                const eff = r.config.parseReasoningEffort(effort) orelse return error.UnknownEffort;
                                try a.context_factory.setAgentEffort(agent_type, eff);
                                try a.refreshLiveAgentTools();
                                if (force orelse false) try a.refreshLiveAgentModels(agent_type);
                            }
                        }).lua_fn, "set_agent_effort"),
                    },
                },
            },
            .{
                .name = "get_model_name",
                .desc = "Return the model name bound to an agent type.",
                .ty = LuaType{ .function = .{
                    .args = &.{.{ .name = "agent_type", .ty = LuaType.integer }},
                    .ret = &LuaString,
                    .fn_ptr = LuaFnBind((struct {
                        fn lua_fn(a: *r.app.App, agent_type_id: u32) ![]const u8 {
                            const agent_type = try r.ContextFactory.AgentType.fromLuaInt(agent_type_id);
                            const def = a.context_factory.agents.getPtrConst(agent_type).* orelse return error.UnknownAgent;
                            const model = def.model orelse return error.NoModel;
                            const entry = a.config.getModel(model.model) orelse return error.UnknownModel;
                            return entry.getName();
                        }
                    }).lua_fn, "get_model_name"),
                } },
            },
            .{
                .name = "get_agent_effort",
                .desc = "Return the reasoning effort string bound to an agent type.",
                .ty = LuaType{ .function = .{
                    .args = &.{.{ .name = "agent_type", .ty = LuaType.integer }},
                    .ret = &LuaString,
                    .fn_ptr = LuaFnBind((struct {
                        fn lua_fn(a: *r.app.App, agent_type_id: u32) ![]const u8 {
                            const agent_type = try r.ContextFactory.AgentType.fromLuaInt(agent_type_id);
                            const def = a.context_factory.agents.getPtrConst(agent_type).* orelse return error.UnknownAgent;
                            const model = def.model orelse return error.NoModel;
                            return @tagName(model.effort);
                        }
                    }).lua_fn, "get_agent_effort"),
                } },
            },
            .{
                .name = "token_usage",
                .desc = "Return token usage currently shown by the statusbar.",
                .ty = LuaType{
                    .function = .{
                        .ret = &TokenUsageDef,
                        .fn_ptr = LuaFnBind((struct {
                            const Ret = struct {
                                input: u64,
                                output: u64,
                                cache: u64,
                                cache_creation: u64,
                                cost: f64,
                            };

                            fn lua_fn(a: *r.app.App, _: *c.lua_State) !Ret {
                                var arena = std.heap.ArenaAllocator.init(a.gpa);
                                defer arena.deinit();
                                const entries = try a.registry.usageByModel(arena.allocator());
                                var cost: f64 = 0;
                                for (entries) |e| cost += a.config.modelCost(e.model, e.usage);
                                const useage = a.registry.usage();
                                return .{
                                    .input = useage.input_tokens,
                                    .output = useage.output_tokens,
                                    .cache = useage.cache_read_tokens,
                                    .cache_creation = useage.cache_write_tokens,
                                    .cost = cost,
                                };
                            }
                        }).lua_fn, "token_usage"),
                    },
                },
            },
            .{
                .name = "context_percent",
                .desc = "Return main-agent context fill percentage currently shown by the statusbar.",
                .ty = LuaType{ .function = .{
                    .ret = &LuaNumber,
                    .fn_ptr = LuaFnBind((struct {
                        fn lua_fn(a: *r.app.App) !f32 {
                            return a.contextPercent();
                        }
                    }).lua_fn, "context_percent"),
                } },
            },
            .{
                .name = "set_compact_edge",
                .desc = "Set the default context edge, in tokens, used for statusbar percentage and auto-compaction.",
                .ty = LuaType{
                    .function = .{
                        .args = &.{.{ .name = "tokens", .ty = LuaType.integer }},
                        .fn_ptr = LuaFnBind((struct {
                            fn lua_fn(state: *c.lua_State, a: *r.app.App, limit: u32) !void {
                                if (try isToolVm(state)) return;
                                a.default_context_limit = limit;
                                for (&a.registry.slots) |*slot| {
                                    const slot_state = slot.state.load(.acquire);
                                    if (slot_state == .free or slot_state == .reserved) continue;
                                    if (slot.agent) |*agent| agent.context_limit = limit;
                                }
                            }
                        }).lua_fn, "set_compact_edge"),
                    },
                },
            },
            .{
                .name = "bind",
                .desc =
                \\Bind a vim-style key combo to a Lua callback.
                \\Examples: "<C-c>", "<M-S-a>", "<Esc>", "<Up>", "<F1>", "a"
                \\
                ,
                .ty = LuaType{
                    .function = .{
                        .args = &.{
                            .{ .name = "key", .ty = LuaType.string },
                            .{ .name = "func", .ty = LuaType{ .function = .{} } },
                            .{ .name = "description", .ty = LuaType.string, .optional = true, .desc = "shown next to the keybind in the dashboard" },
                        },
                        .fn_ptr = LuaFnBind((struct {
                            fn lua_fn(a: *r.app.App, state: *c.lua_State, key: []const u8, func: LuaFnRef, description: ?[]const u8) !void {
                                if (try isToolVm(state)) return;
                                const parsed = keys.parseKeyString(key) orelse return error.InvalidKeyCombo;
                                const vm = a.lua_vm;
                                if (vm.bind_entries.items.len >= MAX_LUA_BINDS) return error.TooManyBinds;
                                const desc_len = if (description) |d| d.len else 0;
                                if (desc_len > 128) return error.BindDescriptionTooLong;
                                var entry = LuaBindEntry{
                                    .key = parsed,
                                    .description_len = desc_len,
                                    .func_ref = func.idx,
                                    .L = state,
                                };
                                if (description) |d| @memcpy(entry.description[0..d.len], d);
                                vm.bind_entries.appendAssumeCapacity(entry);
                            }
                        }).lua_fn, "bind"),
                    },
                },
            },
            .{
                .name = "add_command",
                .desc =
                \\Bind a slash command to a Lua callback. The leading "/" is added automatically.
                \\The callback always receives one string: the remaining input after the
                \\command name, empty when none. Always declare the parameter.
                \\Example: blitz.add_command("help", function(rem) end)
                \\
                ,
                .ty = LuaType{ .function = .{
                    .args = &.{
                        .{ .name = "command", .ty = LuaType.string },
                        .{ .name = "func", .ty = LuaType{ .function = .{
                            .args = &.{.{ .name = "rem", .ty = LuaType.string }},
                        } } },
                        .{ .name = "description", .ty = LuaType.string, .optional = true, .desc = "shown next to the command in the completion popup" },
                    },
                    .fn_ptr = LuaFnBind((struct {
                        fn lua_fn(a: *r.app.App, state: *c.lua_State, name: []const u8, func: LuaFnRef, description: ?[]const u8) !void {
                            if (try isToolVm(state)) return;
                            const vm = a.lua_vm;
                            if (vm.command_entries.items.len >= MAX_LUA_COMMANDS) return error.TooManyCommands;
                            if (name.len == 0) return error.InvalidCommandName;
                            const stripped = if (name[0] == '/') name[1..] else name;
                            if (stripped.len == 0) return error.InvalidCommandName;
                            if (std.mem.indexOfScalar(u8, stripped, ' ') != null) return error.InvalidCommandName;
                            if (stripped.len + 1 > 128) return error.CommandNameTooLong;
                            const desc_len = if (description) |d| d.len else 0;
                            if (desc_len > 128) return error.CommandDescriptionTooLong;

                            var buf: [128]u8 = undefined;
                            buf[0] = '/';
                            @memcpy(buf[1 .. stripped.len + 1], stripped);
                            const cmd_name = buf[0 .. stripped.len + 1];

                            var entry = LuaCommandEntry{
                                .name_len = cmd_name.len,
                                .description_len = desc_len,
                                .func_ref = func.idx,
                                .L = state,
                            };
                            @memcpy(entry.name[0..cmd_name.len], cmd_name);
                            if (description) |d| @memcpy(entry.description[0..d.len], d);
                            vm.command_entries.appendAssumeCapacity(entry);
                        }
                    }).lua_fn, "add_command"),
                } },
            },
            .{
                .name = "set_agent_tools",
                .desc =
                \\Override the tool set for a given agent type. Replaces defaults entirely.
                \\Names must match built-in tool names or names of tools registered via blitz.register_tool.
                ,
                .ty = LuaType{ .function = .{
                    .args = &.{ .{ .name = "agent_type", .ty = LuaType.integer }, .{ .name = "tool_names", .ty = StringListDef } },
                    .fn_ptr = LuaFnBind((struct {
                        fn lua_fn(state: *c.lua_State, a: *r.app.App, agent_type: r.ContextFactory.AgentType, tool_names: [][]const u8) !void {
                            if (try isToolVm(state)) return;
                            try a.context_factory.setAgentTools(agent_type, tool_names);
                        }
                    }).lua_fn, "set_agent_tools"),
                } },
            },
            .{
                .name = "set_capabilities",
                .desc =
                \\Register environment capability rules. Each rule names a binary; when it
                \\resolves on PATH, its rule line is added to the system prompt of agents
                \\that own the bash tool. Rules resolve on registration and on Lua reload.
                ,
                .ty = LuaType{ .function = .{
                    .args = &.{.{ .name = "rules", .ty = CapabilityRuleListDef }},
                    .fn_ptr = LuaFnBind((struct {
                        fn lua_fn(state: *c.lua_State, a: *r.app.App, rules: []r.ContextFactory.CapabilityRule) !void {
                            if (try isToolVm(state)) return;
                            try a.context_factory.setCapabilityRules(rules);
                        }
                    }).lua_fn, "set_capabilities"),
                } },
            },
            .{
                .name = "set_prompt",
                .desc = "Override the system prompt for a given agent type.",
                .ty = LuaType{ .function = .{
                    .args = &.{ .{ .name = "agent_type", .ty = LuaType.integer }, .{ .name = "prompt", .ty = LuaType.string } },
                    .fn_ptr = LuaFnBind((struct {
                        fn lua_fn(state: *c.lua_State, a: *r.app.App, agent_type: r.ContextFactory.AgentType, prompt: []const u8) !void {
                            if (try isToolVm(state)) return;
                            try a.context_factory.setAgentPrompt(agent_type, prompt);
                        }
                    }).lua_fn, "set_prompt"),
                } },
            },
            .{
                .name = "get_flags",
                .desc = "Return the current app flags.",
                .ty = LuaType{ .function = .{
                    .ret = &AppFlagsDef,
                    .fn_ptr = LuaFnBind((struct {
                        fn lua_fn(a: *r.app.App) !FlagsStrings {
                            a.mu.lockUncancelable(a.io);
                            defer a.mu.unlock(a.io);
                            return .{
                                .show_thinking = a.flags.show_thinking,
                                .debug_log = a.flags.debug_log,
                                .approval_mode = @tagName(a.flags.approval_mode),
                            };
                        }
                    }).lua_fn, "get_flags"),
                } },
            },
            .{
                .name = "set_flags",
                .desc = "Set the app flags from a table. Fields you omit are left unchanged.",
                .ty = LuaType{ .function = .{
                    .args = &.{.{ .name = "flags", .ty = AppFlagsDef }},
                    .fn_ptr = LuaFnBind((struct {
                        fn lua_fn(a: *r.app.App, flags: FlagsStrings) !void {
                            const mode: r.permissions.ApprovalMode = if (flags.approval_mode) |str|
                                r.permissions.parseApprovalMode(str) orelse return error.UnknownApprovalMode
                            else
                                .default;
                            a.mu.lockUncancelable(a.io);
                            defer a.mu.unlock(a.io);
                            if (flags.show_thinking) |v| a.flags.show_thinking = v;
                            if (flags.debug_log) |v| a.flags.debug_log = v;
                            a.flags.approval_mode = mode;
                            a.dirty = true;
                        }
                    }).lua_fn, "set_flags"),
                } },
            },
            .{
                .name = "get_theme",
                .desc = "Return the current theme as a table of hex color strings.",
                .ty = LuaType{ .function = .{
                    .ret = &ThemeDef,
                    .fn_ptr = LuaFnBind((struct {
                        const Ret = struct {
                            bg: [7]u8,
                            overlay_dark: [7]u8,
                            overlay: [7]u8,
                            muted: [7]u8,
                            text: [7]u8,
                            text_hl: [7]u8,
                            ok: [7]u8,
                            info: [7]u8,
                            warn: [7]u8,
                            err: [7]u8,
                            on_err: [7]u8,
                            diff_surface: [7]u8,
                            diff_add: [7]u8,
                            diff_remove: [7]u8,
                            role_user: [7]u8,
                            role_agent: [7]u8,
                            role_system: [7]u8,
                        };
                        fn lua_fn(a: *r.app.App) !Ret {
                            a.mu.lockUncancelable(a.io);
                            defer a.mu.unlock(a.io);
                            const t = a.theme;
                            return .{
                                .bg = t.bg.toHexStr(),
                                .overlay_dark = t.overlay_dark.toHexStr(),
                                .overlay = t.overlay.toHexStr(),
                                .muted = t.muted.toHexStr(),
                                .text = t.text.toHexStr(),
                                .text_hl = t.text_hl.toHexStr(),
                                .ok = t.ok.toHexStr(),
                                .info = t.info.toHexStr(),
                                .warn = t.warn.toHexStr(),
                                .err = t.err.toHexStr(),
                                .on_err = t.on_err.toHexStr(),
                                .diff_surface = t.diff_surface.toHexStr(),
                                .diff_add = t.diff_add.toHexStr(),
                                .diff_remove = t.diff_remove.toHexStr(),
                                .role_user = t.role_user.toHexStr(),
                                .role_agent = t.role_agent.toHexStr(),
                                .role_system = t.role_system.toHexStr(),
                            };
                        }
                    }).lua_fn, "get_theme"),
                } },
            },
            .{
                .name = "set_theme",
                .desc = "Set the theme from a table of hex color strings or \"transparent\". Missing fields keep their current value.",
                .ty = LuaType{ .function = .{
                    .args = &.{.{ .name = "theme", .ty = ThemeDef }},
                    .fn_ptr = LuaFnBind((struct {
                        fn lua_fn(a: *r.app.App, theme: ThemeArg) !void {
                            a.mu.lockUncancelable(a.io);
                            defer a.mu.unlock(a.io);
                            try applyTheme(a, theme);
                        }
                    }).lua_fn, "set_theme"),
                } },
            },
            .{
                .name = "log",
                .desc = "Write a debug log line.",
                .ty = LuaType{ .function = .{
                    .args = &.{.{ .name = "msg", .ty = LuaType.string }},
                    .fn_ptr = LuaFnBind((struct {
                        fn lua_fn(msg: []const u8) !void {
                            std.log.scoped(.lua).info("{s}", .{msg});
                        }
                    }).lua_fn, "log"),
                } },
            },
            .{
                .name = "shell",
                .desc = "Execute a shell command. Returns output, ok. Optionally a timeout in seconds.",
                .ty = LuaType{ .function = .{
                    .args = &.{
                        .{ .name = "cmd", .ty = LuaType.string },
                        .{ .name = "timeout", .ty = LuaType.number, .optional = true, .desc = "Timeout in seconds." },
                    },
                    .ret = &LuaAny,
                    .fn_ptr = (struct {
                        fn lua_fn(L: ?*c.lua_State) callconv(.c) c_int {
                            const state = L.?;
                            const a = getAppFromRegistry(state) orelse {
                                _ = c.luaL_error(state, "shell: app not initialized");
                                return 0;
                            };
                            const cmd = readAnyArg([]const u8, state, "shell", 1) orelse return pushNilBool(state, false);
                            const cwd: ?[]const u8 = if (a.cwd.len > 0) a.cwd else null;

                            var timeout_ms: ?i64 = null;
                            if (c.lua_gettop(state) >= 2 and c.lua_type(state, 2) != c.LUA_TNIL) {
                                const t = c.lua_tonumberx(state, 2, null);
                                if (!std.math.isFinite(t) or t <= 0) return pushNilBool(state, false);
                                timeout_ms = @intFromFloat(@min(t, 2_147_483.0) * 1000);
                            }

                            const opts: @TypeOf(a.exec_pool.*).RunOpts = .{ .cwd = cwd, .argv = &.{ "/bin/sh", "-c", cmd } };
                            const result = (if (timeout_ms) |ms|
                                a.exec_pool.runAndWaitTimeout(opts, ms)
                            else
                                a.exec_pool.runAndWait(opts)) catch {
                                _ = c.lua_pushliteral(state, "failed to execute command");
                                c.lua_pushboolean(state, 0);
                                return 2;
                            };
                            defer a.exec_pool.alloc.free(result.stdout);
                            defer a.exec_pool.alloc.free(result.stderr);

                            const success = result.ty == .success;
                            const output = if (success) result.stdout else if (result.stderr.len > 0) result.stderr else result.stdout;
                            _ = c.lua_pushlstring(state, output.ptr, output.len);
                            c.lua_pushboolean(state, @intFromBool(success));
                            return 2;
                        }
                    }).lua_fn,
                } },
            },
            .{
                .name = "write_tempfile",
                .desc = "Write content to a named file in the active session temp directory and return its path.",
                .ty = LuaType{ .function = .{
                    .args = &.{
                        .{ .name = "name", .ty = LuaType.string },
                        .{ .name = "content", .ty = LuaType.string },
                    },
                    .ret = &LuaString,
                    .fn_ptr = (struct {
                        fn lua_fn(L: ?*c.lua_State) callconv(.c) c_int {
                            const state = L.?;
                            const a = getAppFromRegistry(state) orelse {
                                _ = c.luaL_error(state, "write_tempfile: app not initialized");
                                return 0;
                            };
                            const name = readAnyArg([]const u8, state, "write_tempfile", 1) orelse return 0;
                            const content = readAnyArg([]const u8, state, "write_tempfile", 2) orelse return 0;
                            const path = r.artifact.write(a.exec_pool, a.gpa, name, content) catch |err| {
                                _ = c.luaL_error(state, "write_tempfile failed with '%s'", @errorName(err).ptr);
                                return 0;
                            };
                            defer a.gpa.free(path);
                            _ = c.lua_pushlstring(state, path.ptr, path.len);
                            return 1;
                        }
                    }).lua_fn,
                } },
            },
            .{
                .name = "push_notification",
                .desc = "Push a new popup notification with a lifetime of 8s to the top right corner.",
                .ty = LuaType{ .function = .{
                    .args = &.{.{ .name = "message", .ty = LuaType.string }},
                    .fn_ptr = LuaFnBind((struct {
                        fn lua_fn(_: *c.lua_State, a: *r.app.App, message: []const u8) !void {
                            try a.cmd_queue.append(a.io, .{ .push_notification = message });
                        }
                    }).lua_fn, "push_notification"),
                } },
            },
            .{ .name = "state", .ty = BlitzState },
            .{ .name = "status_bar_render", .ty = LuaType{ .raw = "fun(): string|nil" }, .desc = "Override the status bar text. Return a string to display, or nil to keep the default." },
        },
    },
};
pub const BlitzToolDef = LuaType{
    .table_def = .{
        .name = "BlitzToolDef",
        .fields = &.{
            .{ .name = "BASH", .ty = LuaType.string, .value = .{ .string = tl.bash.BashTool.def.name } },
            .{ .name = "READ", .ty = LuaType.string, .value = .{ .string = tl.read.ReadTool.def.name } },
            .{ .name = "VIEW_IMAGE", .ty = LuaType.string, .value = .{ .string = tl.read.ViewImageTool.def.name } },
            .{ .name = "WRITE", .ty = LuaType.string, .value = .{ .string = tl.write.WriteTool.def.name } },
            .{ .name = "EDIT", .ty = LuaType.string, .value = .{ .string = tl.edit.EditTool.def.name } },
            .{ .name = "PATCH", .ty = LuaType.string, .value = .{ .string = tl.patch.PatchTool.def.name } },
            .{ .name = "AGENT", .ty = LuaType.string, .value = .{ .string = tl.agent.AgentTool.def.name } },
            .{ .name = "ASK", .ty = LuaType.string, .value = .{ .string = tl.ask.AskTool.def.name } },
            .{ .name = "GLOB", .ty = LuaType.string, .value = .{ .string = tl.search.GlobTool.def.name } },
            .{ .name = "GREP", .ty = LuaType.string, .value = .{ .string = tl.search.GrepTool.def.name } },
            .{ .name = "START_MCP", .ty = LuaType.string, .value = .{ .string = tl.start.StartMcpTool.def.name } },
            .{ .name = "SKILL", .ty = LuaType.string, .value = .{ .string = tl.skill.SkillTool.def.name } },
        },
    },
};

const BlitzAgentEvent = LuaType{ .table_def = .{
    .name = "BlitzAgentEvent",
    .fields = &.{
        .{ .name = "id", .desc = "packed AgentId of the agent", .ty = LuaType.integer },
    },
} };

const BlitzAgentCreatedEvent = LuaType{ .table_def = .{
    .name = "BlitzAgentCreatedEvent",
    .fields = &.{
        .{ .name = "id", .desc = "packed AgentId of the new agent", .ty = LuaType.integer },
        .{ .name = "name", .desc = "agent type name", .ty = LuaType.string },
        .{ .name = "depth", .desc = "nesting depth below the main agent", .ty = LuaType.integer },
    },
} };

const BlitzAgentFailedEvent = LuaType{ .table_def = .{
    .name = "BlitzAgentFailedEvent",
    .fields = &.{
        .{ .name = "id", .desc = "packed AgentId of the failed agent", .ty = LuaType.integer },
        .{ .name = "err", .desc = "error name", .ty = LuaType.string },
    },
} };

const BlitzUserMessageEvent = LuaType{ .table_def = .{
    .name = "BlitzUserMessageEvent",
    .fields = &.{
        .{ .name = "text", .desc = "chat text as typed", .ty = LuaType.string },
    },
} };

fn EventFn(comptime tag: r.events.AppEventTag, comptime payload: ?LuaType) LuaType {
    const Bind = struct {
        fn t(state: *c.lua_State, a: *r.app.App, func: LuaFnRef) !void {
            const vm = fromState(state) orelse return error.NoLuaVm;
            vm.hook_entries.append(vm.luaArena(), .{ .tag = tag, .func_ref = func.idx }) catch {
                c.luaL_unref(state, c.LUA_REGISTRYINDEX, func.idx);
                return;
            };
            if (vm.is_tool_vm) return;
            a.event_bus.addTag(a.io, tag);
        }
    };
    const ev_args: []const LuaType.Field = if (payload) |p|
        &.{.{ .name = "ev", .ty = p }}
    else
        &.{};
    return .{ .function = .{
        .args = &.{.{ .name = "func", .ty = LuaType{ .function = .{ .args = ev_args } } }},
        .fn_ptr = LuaFnBind(Bind.t, @tagName(tag)),
    } };
}

const ListenerVmDesc =
    \\The listener runs in a sandbox Lua VM on a background thread. Cannot mutate lua state. Use `blitz.state.set/get`
;

pub const BlitzHooks = LuaType{
    .table_def = .{
        .name = "BlitzHooks",
        .fields = &.{
            .{ .name = "session_reset", .desc = "Register a listener for after the active session is reset. Takes no payload. " ++ ListenerVmDesc, .ty = EventFn(.session_reset, null) },
            .{ .name = "agent_created", .desc = "Register a listener for after an agent slot is activated. " ++ ListenerVmDesc, .ty = EventFn(.agent_created, BlitzAgentCreatedEvent) },
            .{ .name = "agent_started", .desc = "Register a listener for when an agent starts running. " ++ ListenerVmDesc, .ty = EventFn(.agent_started, BlitzAgentEvent) },
            .{ .name = "agent_complete", .desc = "Register a listener for when an agent completes. " ++ ListenerVmDesc, .ty = EventFn(.agent_complete, BlitzAgentEvent) },
            .{ .name = "agent_failed", .desc = "Register a listener for when an agent run fails. " ++ ListenerVmDesc, .ty = EventFn(.agent_failed, BlitzAgentFailedEvent) },
            .{ .name = "agent_cancelled", .desc = "Register a listener for when an agent is cancelled. " ++ ListenerVmDesc, .ty = EventFn(.agent_cancelled, BlitzAgentEvent) },
            .{ .name = "compaction_started", .desc = "Register a listener for when chat compaction starts. " ++ ListenerVmDesc, .ty = EventFn(.compaction_started, BlitzAgentEvent) },
            .{ .name = "compaction_complete", .desc = "Register a listener for when chat compaction completes. " ++ ListenerVmDesc, .ty = EventFn(.compaction_complete, BlitzAgentEvent) },
            .{ .name = "user_message_sent", .desc = "Register a listener for after the user sends a message. " ++ ListenerVmDesc, .ty = EventFn(.user_message_sent, BlitzUserMessageEvent) },
            .{ .name = "mcp_tools_reloaded", .desc = "Register a listener for after MCP tools are reloaded. Takes no payload. " ++ ListenerVmDesc, .ty = EventFn(.mcp_tools_reloaded, null) },
            .{
                .name = "inject",
                .desc =
                \\Install the system-reminder injection hook. Runs for every agent step
                \\before the reminder is built, in the main Lua VM on the calling thread.
                \\Return a string to append it to the agent's <system-reminder> block,
                \\nil for nothing. Last registration wins. Never call
                \\blitz.cmd.await_agent inside the hook.
                ,
                .ty = LuaType{ .function = .{
                    .args = &.{.{ .name = "hook", .ty = LuaType{ .function = .{
                        .args = &.{.{ .name = "agent_id", .ty = LuaType.integer }},
                        .ret = &LuaString,
                    } } }},
                    .fn_ptr = LuaFnBind((struct {
                        fn t(state: *c.lua_State, a: *r.app.App, hook: LuaFnRef) !void {
                            if (try isToolVm(state)) return;
                            const vm = fromState(state) orelse return error.NoLuaVm;
                            if (vm.inject_fn != c.LUA_NOREF) c.luaL_unref(state, c.LUA_REGISTRYINDEX, vm.inject_fn);
                            vm.inject_fn = hook.idx;
                            a.lua_inject_hooks_enabled.store(true, .release);
                        }
                    }).t, "inject"),
                } },
            },
            .{
                .name = "approve",
                .desc =
                \\Install the permission hook. Runs on every tool approval request
                \\before the approval-mode check, in the main Lua VM on the main
                \\thread. Return a BlitzPermissionDecision table, or nil for the
                \\normal flow. Last registration wins. Never call
                \\blitz.cmd.await_agent inside the hook.
                ,
                .ty = LuaType{ .function = .{
                    .args = &.{.{ .name = "hook", .ty = LuaType{ .function = .{
                        .args = &.{.{ .name = "payload", .ty = PermissionPayloadDef }},
                        .ret = &PermissionDecisionDef,
                    } } }},
                    .fn_ptr = LuaFnBind((struct {
                        fn t(state: *c.lua_State, a: *r.app.App, hook: LuaFnRef) !void {
                            _ = a;
                            if (try isToolVm(state)) return;
                            const vm = fromState(state) orelse return error.NoLuaVm;
                            vm.permission_hook = hook.idx;
                        }
                    }).t, "approve"),
                } },
            },
            .{
                .name = "clear",
                .desc = "Remove the approve and inject hooks.",
                .ty = LuaType{ .function = .{
                    .args = &.{},
                    .fn_ptr = LuaFnBind((struct {
                        fn t(state: *c.lua_State, a: *r.app.App) !void {
                            _ = a;
                            if (try isToolVm(state)) return;
                            const vm = fromState(state) orelse return error.NoLuaVm;
                            vm.permission_hook = c.LUA_NOREF;
                            vm.inject_fn = c.LUA_NOREF;
                        }
                    }).t, "clear"),
                } },
            },
        },
    },
};

const PermissionDecisionDef = LuaType{ .table_def = .{ .name = "BlitzPermissionDecision", .fields = &.{
    .{ .name = "approved", .ty = LuaType.boolean, .desc = "false denies, true approves; on ask picks the recommended option" },
    .{ .name = "msg", .ty = LuaType.string, .optional = true, .desc = "deny reason, reaches the model as tool error" },
    .{ .name = "select", .ty = LuaType.integer, .optional = true, .desc = "1-based option index, ask payloads only; ignored otherwise" },
} } };

const PermissionPayloadDef = LuaType{ .table_def = .{ .name = "BlitzPermissionPayload", .fields = &.{
    .{ .name = "agent_id", .ty = LuaType.integer, .desc = "packed AgentId of the requesting agent" },
    .{ .name = "call_id", .ty = LuaType.string, .optional = true },
    .{ .name = "kind", .ty = LuaType.string, .desc = "call|diff|ask|plan" },
    .{ .name = "tool", .ty = LuaType.string, .desc = "tool name" },
    .{ .name = "description", .ty = LuaType.string, .optional = true, .desc = "kind == call" },
    .{ .name = "path", .ty = LuaType.string, .optional = true, .desc = "kind == diff|plan" },
    .{ .name = "header", .ty = LuaType.string, .optional = true, .desc = "kind == ask" },
    .{ .name = "question", .ty = LuaType.string, .optional = true, .desc = "kind == ask" },
    .{ .name = "options", .ty = StringListDef, .optional = true, .desc = "kind == ask" },
    .{ .name = "plan", .ty = LuaType.string, .optional = true, .desc = "kind == plan, plan text" },
} } };

const BlitzMcp = LuaType{
    .table_def = .{
        .name = "BlitzMcp",
        .fields = &.{
            .{
                .name = "add",
                .desc = "Register an MCP stdio server. Disabled until explicitly enabled.",
                .ty = LuaType{
                    .function = .{
                        .args = &.{.{ .name = "def", .ty = McpServerDef }},
                        .ret = &LuaInteger,
                        .fn_ptr = LuaFnBind((struct {
                            const Args = struct {
                                name: []const u8,
                                command: []const u8,
                                args: [][]const u8,
                                tools_prefix: []const u8,
                            };

                            fn lua_fn(state: *c.lua_State, a: *r.app.App, args: Args) !u32 {
                                if (try isToolVm(state)) return 0;
                                try a.lua_vm.mcp_entries.appendBounded(LuaMcpServerEntry{
                                    .name = args.name,
                                    .command = args.command,
                                    .args = args.args,
                                    .tools_prefix = args.tools_prefix,
                                });

                                return @intCast(a.lua_vm.mcp_entries.items.len);
                            }
                        }).lua_fn, "add"),
                    },
                },
            },
            .{
                .name = "enable",
                .desc = "Enable an MCP server for this session.",
                .ty = LuaType{
                    .function = .{
                        .args = &.{.{ .name = "mcp_id", .ty = LuaType.integer }},
                        .fn_ptr = LuaFnBind((struct {
                            fn lua_fn(_: *c.lua_State, a: *r.app.App, mcp_id: u32) !void {
                                const vm = a.lua_vm;
                                if (mcp_id == 0 or mcp_id > vm.mcp_entries.items.len) return error.InvalidMcpId;
                                vm.mcp_entries.items[mcp_id - 1].enabled = true;
                                vm.mcp_entries.items[mcp_id - 1].conf_enabled = true;
                                try a.cmd_queue.append(a.io, .reload_mcp);
                            }
                        }).lua_fn, "mcp.enable"),
                    },
                },
            },
        },
    },
};

const BlitzJson = LuaType{ .table_def = .{ .name = "BlitzJson", .fields = &.{
    .{
        .name = "encode",
        .desc =
        \\Encode a Lua value as JSON.
        \\Supports nil, booleans, numbers, strings, and tables.
        ,
        .ty = LuaType{ .function = .{
            .args = &.{.{ .name = "obj", .ty = LuaType.any }},
            .fn_ptr = (struct {
                fn lua_fn(L: ?*c.lua_State) callconv(.c) c_int {
                    const state = L.?;
                    const vm = fromState(state) orelse return pushNilBool(state, false);
                    var arena = std.heap.ArenaAllocator.init(vm.parent);
                    defer arena.deinit();
                    const json = luaToJsonAlloc(arena.allocator(), state, 1) catch return pushNilBool(state, false);
                    _ = c.lua_pushlstring(state, json.ptr, json.len);
                    c.lua_pushboolean(state, 1);
                    return 2;
                }
            }).lua_fn,
            .ret = &JsonEncodeRet,
        } },
    },
    .{ .name = "decode", .desc =
    \\Decode a JSON string into Lua values.
    \\JSON arrays become 1-indexed Lua tables; objects become Lua tables; JSON null becomes nil.
    , .ty = LuaType{ .function = .{
        .args = &.{.{ .name = "json", .ty = LuaType.string }},
        .ret = &JsonDecodeRet,
        .fn_ptr = (struct {
            fn lua_fn(L: ?*c.lua_State) callconv(.c) c_int {
                const state = L.?;
                const vm = fromState(state) orelse return pushNilBool(state, false);
                if (c.lua_type(state, 1) != c.LUA_TSTRING) return pushNilBool(state, false);
                var len: usize = 0;
                const ptr = c.lua_tolstring(state, 1, &len) orelse return pushNilBool(state, false);
                var arena = std.heap.ArenaAllocator.init(vm.parent);
                defer arena.deinit();
                pushJsonValue(arena.allocator(), state, ptr[0..len]) catch return pushNilBool(state, false);
                c.lua_pushboolean(state, 1);
                return 2;
            }
        }).lua_fn,
    } } },
} } };

const BlitzBase64 = LuaType{ .table_def = .{ .name = "BlitzBase64", .fields = &.{
    .{ .name = "encode", .desc = "Encode a binary-safe Lua string as standard padded Base64.", .ty = LuaType{ .function = .{
        .args = &.{.{ .name = "data", .ty = LuaType.string }},
        .ret = &Base64Ret,
        .fn_ptr = (struct {
            fn lua_fn(L: ?*c.lua_State) callconv(.c) c_int {
                const state = L.?;
                const vm = fromState(state) orelse return pushNilBool(state, false);
                if (c.lua_type(state, 1) != c.LUA_TSTRING) return pushNilBool(state, false);
                var len: usize = 0;
                const ptr = c.lua_tolstring(state, 1, &len) orelse return pushNilBool(state, false);
                var arena = std.heap.ArenaAllocator.init(vm.parent);
                defer arena.deinit();
                const dest = arena.allocator().alloc(u8, std.base64.standard.Encoder.calcSize(len)) catch return pushNilBool(state, false);
                const encoded = std.base64.standard.Encoder.encode(dest, ptr[0..len]);
                _ = c.lua_pushlstring(state, encoded.ptr, encoded.len);
                c.lua_pushboolean(state, 1);
                return 2;
            }
        }).lua_fn,
    } } },
    .{ .name = "decode", .desc = "Decode standard padded Base64 into a binary-safe Lua string.", .ty = LuaType{ .function = .{
        .args = &.{.{ .name = "base64", .ty = LuaType.string }},
        .ret = &Base64Ret,
        .fn_ptr = (struct {
            fn lua_fn(L: ?*c.lua_State) callconv(.c) c_int {
                const state = L.?;
                const vm = fromState(state) orelse return pushNilBool(state, false);
                if (c.lua_type(state, 1) != c.LUA_TSTRING) return pushNilBool(state, false);
                var len: usize = 0;
                const ptr = c.lua_tolstring(state, 1, &len) orelse return pushNilBool(state, false);
                const source = ptr[0..len];
                const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(source) catch return pushNilBool(state, false);
                var arena = std.heap.ArenaAllocator.init(vm.parent);
                defer arena.deinit();
                const decoded = arena.allocator().alloc(u8, decoded_len) catch return pushNilBool(state, false);
                std.base64.standard.Decoder.decode(decoded, source) catch return pushNilBool(state, false);
                _ = c.lua_pushlstring(state, decoded.ptr, decoded.len);
                c.lua_pushboolean(state, 1);
                return 2;
            }
        }).lua_fn,
    } } },
} } };

const BlitzState = LuaType{ .table_def = .{ .name = "BlitzState", .fields = &.{
    .{
        .name = "set",
        .desc =
        \\Set a value in the shared state. Pass nil to delete the key.
        \\Returns true on success, or nil,false on a non-string key or unsupported value type.
        \\Tables must have a contiguous 1..n array part and string-only keys.
        ,
        .ty = LuaType{ .function = .{
            .args = &.{ .{ .name = "key", .ty = LuaType.string }, .{ .name = "value", .ty = LuaType.any } },
            .fn_ptr = &luaStateSet,
        } },
    },
    .{
        .name = "get",
        .desc =
        \\Get a value from the shared state. Returns nil if the key is missing,
        \\or nil,false on a non-string key.
        ,
        .ty = LuaType{ .function = .{
            .args = &.{.{ .name = "key", .ty = LuaType.string }},
            .fn_ptr = &luaStateGet,
        } },
    },
} } };

fn luaStateSet(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    const a = getAppFromRegistry(state) orelse return pushNilBool(state, false);
    if (c.lua_type(state, 1) != c.LUA_TSTRING) return pushNilBool(state, false);
    var klen: usize = 0;
    const key = c.lua_tolstring(state, 1, &klen) orelse return pushNilBool(state, false);
    const key_slice = key[0..klen];
    if (c.lua_type(state, 2) == c.LUA_TNIL) {
        a.lua_state.set(a.io, a.gpa, key_slice, null) catch return pushNilBool(state, false);
        c.lua_pushboolean(state, 1);
        return 1;
    }
    const value = stateValueFromLua(a.gpa, state, 2, 1) catch return pushNilBool(state, false);
    a.lua_state.set(a.io, a.gpa, key_slice, value) catch {
        lua_state.freeValue(a.gpa, value);
        return pushNilBool(state, false);
    };
    c.lua_pushboolean(state, 1);
    return 1;
}

fn luaStateGet(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    const a = getAppFromRegistry(state) orelse return pushNilBool(state, false);
    if (c.lua_type(state, 1) != c.LUA_TSTRING) return pushNilBool(state, false);
    var klen: usize = 0;
    const key = c.lua_tolstring(state, 1, &klen) orelse return pushNilBool(state, false);
    const value = a.lua_state.get(a.gpa, a.io, key[0..klen]) catch return pushNilBool(state, false);
    if (value) |v| {
        defer lua_state.freeValue(a.gpa, v);
        pushStateValue(state, v);
        return 1;
    }
    c.lua_pushnil(state);
    return 1;
}

fn stateValueFromLua(alloc: Allocator, L: *c.lua_State, idx: c_int, depth: u32) anyerror!lua_state.Value {
    return switch (c.lua_type(L, idx)) {
        c.LUA_TBOOLEAN => .{ .boolean = c.lua_toboolean(L, idx) != 0 },
        c.LUA_TNUMBER => if (c.lua_isinteger(L, idx) != 0)
            .{ .integer = @intCast(c.lua_tointegerx(L, idx, null)) }
        else
            .{ .number = c.lua_tonumberx(L, idx, null) },
        c.LUA_TSTRING => blk: {
            var len: usize = 0;
            const s = c.lua_tolstring(L, idx, &len) orelse return error.UnsupportedValue;
            break :blk .{ .string = try alloc.dupe(u8, s[0..len]) };
        },
        c.LUA_TTABLE => .{ .table = try stateTableFromLua(alloc, L, idx, depth) },
        else => error.UnsupportedValue,
    };
}

fn stateTableFromLua(alloc: Allocator, L: *c.lua_State, idx: c_int, depth: u32) anyerror!lua_state.Table {
    if (depth > MAX_STATE_DEPTH) return error.UnsupportedValue;
    if (c.lua_checkstack(L, 4) == 0) return error.UnsupportedValue;
    const abs = c.lua_absindex(L, idx);
    var out: lua_state.Table = .{};
    errdefer lua_state.freeValue(alloc, .{ .table = out });

    const n: i64 = @intCast(c.lua_rawlen(L, abs));
    try out.array.ensureTotalCapacity(alloc, @intCast(n));
    var i: i64 = 1;
    while (i <= n) : (i += 1) {
        _ = c.lua_rawgeti(L, abs, i);
        defer c.lua_pop(L, 1);
        out.array.appendAssumeCapacity(try stateValueFromLua(alloc, L, -1, depth + 1));
    }

    c.lua_pushnil(L);
    while (c.lua_next(L, abs) != 0) {
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -2) == c.LUA_TNUMBER) {
            if (c.lua_isinteger(L, -2) == 0) return error.UnsupportedValue;
            const k = c.lua_tointegerx(L, -2, null);
            if (k >= 1 and k <= n) continue;
            return error.UnsupportedValue;
        }
        if (c.lua_type(L, -2) != c.LUA_TSTRING) return error.UnsupportedValue;
        var klen: usize = 0;
        const k = c.lua_tolstring(L, -2, &klen) orelse return error.UnsupportedValue;
        try lua_state.mapPut(alloc, &out.map, k[0..klen], try stateValueFromLua(alloc, L, -1, depth + 1));
    }
    return out;
}

fn pushStateValue(L: *c.lua_State, value: lua_state.Value) void {
    switch (value) {
        .boolean => |b| c.lua_pushboolean(L, @intFromBool(b)),
        .integer => |i| c.lua_pushinteger(L, @intCast(i)),
        .number => |n| c.lua_pushnumber(L, n),
        .string => |s| _ = c.lua_pushlstring(L, s.ptr, s.len),
        .table => |t| {
            c.lua_createtable(L, @intCast(t.array.items.len), @intCast(t.map.count()));
            for (t.array.items, 0..) |item, i| {
                pushStateValue(L, item);
                c.lua_rawseti(L, -2, @intCast(i + 1));
            }
            var it = t.map.iterator();
            while (it.next()) |entry| {
                _ = c.lua_pushlstring(L, entry.key_ptr.ptr, entry.key_ptr.len);
                pushStateValue(L, entry.value_ptr.*);
                c.lua_rawset(L, -3);
            }
        },
    }
}

const BlitzCmd = LuaType{ .table_def = .{ .name = "BlitzCmd", .fields = &.{
    .{
        .name = "reset_session",
        .desc = "Reset the active session.",
        .ty = LuaType{
            .function = .{
                .fn_ptr = LuaFnBind((struct {
                    fn lua_fn(_: *c.lua_State, a: *r.app.App) !void {
                        try a.cmd_queue.append(a.io, .reset_session);
                    }
                }).lua_fn, "cmd.reset_session"),
            },
        },
    },
    .{
        .name = "cd",
        .desc = "Change the working directory.",
        .ty = LuaType{ .function = .{
            .args = &.{.{ .name = "path", .ty = LuaType.string }},
            .fn_ptr = LuaFnBind((struct {
                fn lua_fn(_: *c.lua_State, a: *r.app.App, path: []const u8) !void {
                    try a.cmd_queue.append(a.io, .{ .cd = path });
                }
            }).lua_fn, "cmd.cd"),
        } },
    },
    .{
        .name = "cancel",
        .desc = "Cancel all in-flight agent work and drop streaming preview.",
        .ty = LuaType{ .function = .{
            .fn_ptr = LuaFnBind((struct {
                fn lua_fn(_: *c.lua_State, a: *r.app.App) !void {
                    try a.cmd_queue.append(a.io, .cancel);
                }
            }).lua_fn, "cmd.cancel"),
        } },
    },
    .{
        .name = "cancel_agent",
        .desc = "Cancel the given agent. Returns 'Success' or 'Not Found'.",
        .ty = LuaType{ .function = .{
            .args = &.{.{ .name = "agent_id", .ty = AgentIdDef }},
            .ret = &LuaString,
            .fn_ptr = LuaFnBind((struct {
                fn lua_fn(_: *c.lua_State, a: *r.app.App, agent_id: r.AgentId) ![]const u8 {
                    if (a.registry.get(agent_id) == null) return "Not Found";
                    try a.cmd_queue.append(a.io, .{ .cancel_agent = agent_id });
                    return "Success";
                }
            }).lua_fn, "cmd.cancel_agent"),
        } },
    },
    .{
        .name = "close_agent",
        .desc = "Cancel a finished or running agent and free its slot. History stays rendered. Returns 'Success' or 'Not Found'.",
        .ty = LuaType{ .function = .{
            .args = &.{.{ .name = "agent_id", .ty = AgentIdDef }},
            .ret = &LuaString,
            .fn_ptr = LuaFnBind((struct {
                fn lua_fn(_: *c.lua_State, a: *r.app.App, agent_id: r.AgentId) ![]const u8 {
                    if (a.registry.get(agent_id) == null) return "Not Found";
                    try a.cmd_queue.append(a.io, .{ .close_agent = agent_id });
                    return "Success";
                }
            }).lua_fn, "cmd.close_agent"),
        } },
    },
    .{
        .name = "retry",
        .desc = "Retry the main agent's last turn.",
        .ty = LuaType{ .function = .{
            .fn_ptr = LuaFnBind((struct {
                fn lua_fn(_: *c.lua_State, a: *r.app.App) !void {
                    try a.cmd_queue.append(a.io, .retry);
                }
            }).lua_fn, "cmd.retry"),
        } },
    },
    .{
        .name = "compact",
        .desc = "Compact the main agent now when idle, or before its next turn while running.",
        .ty = LuaType{ .function = .{
            .fn_ptr = LuaFnBind((struct {
                fn lua_fn(_: *c.lua_State, a: *r.app.App) !void {
                    try a.cmd_queue.append(a.io, .compact);
                }
            }).lua_fn, "cmd.compact"),
        } },
    },
    .{
        .name = "message_chat",
        .desc = "Push a chat entry into the chat log.",
        .ty = LuaType{ .function = .{
            .args = &.{ .{ .name = "role", .ty = LuaType.string }, .{ .name = "text", .ty = LuaType.string } },
            .fn_ptr = LuaFnBind((struct {
                fn lua_fn(_: *c.lua_State, a: *r.app.App, role_str: []const u8, text: []const u8) !void {
                    const role: r.app.ChatRole = if (std.mem.eql(u8, role_str, "system"))
                        .system
                    else if (std.mem.eql(u8, role_str, "user"))
                        .user
                    else if (std.mem.eql(u8, role_str, "agent"))
                        .agent
                    else
                        return error.InvalidRole;

                    var parts = try a.sessionAlloc().alloc(r.app.ChatPart, 1);
                    parts[0] = .{ .message = text };
                    try a.cmd_queue.append(a.io, .{ .push_chat_entry = .{
                        .role = role,
                        .parts = parts,
                    } });
                }
            }).lua_fn, "cmd.message_chat"),
        } },
    },
    .{
        .name = "message_agent",
        .desc = "Queue a user message for the given agent.",
        .ty = LuaType{ .function = .{
            .args = &.{ .{ .name = "agent_id", .ty = AgentIdDef }, .{ .name = "text", .ty = LuaType.string } },
            .fn_ptr = LuaFnBind((struct {
                fn lua_fn(_: *c.lua_State, a: *r.app.App, agent_id: r.AgentId, text: []const u8) !void {
                    const parts = [_]r.sdk.Part{.{ .text = text }};
                    try a.cmd_queue.append(a.io, .{ .queue_agent_message = .{
                        .agent_id = agent_id,
                        .parts = &parts,
                    } });
                }
            }).lua_fn, "cmd.message_agent"),
        } },
    },
    .{
        .name = "prompt",
        .desc = "Send a user message to the main agent (queued if running, restarted if idle), or start a general agent if none exists.",
        .ty = LuaType{ .function = .{
            .args = &.{.{ .name = "text", .ty = LuaType.string }},
            .fn_ptr = LuaFnBind((struct {
                fn lua_fn(_: *c.lua_State, a: *r.app.App, text: []const u8) !void {
                    const parts = [_]r.sdk.Part{.{ .text = text }};
                    const entry = try r.app.ChatEntry.userMessageSimple(a.sessionAlloc(), .user, text);
                    if (a.main_agent_id) |id| {
                        try a.cmd_queue.append(a.io, .{ .queue_agent_message = .{
                            .agent_id = id,
                            .parts = &parts,
                            .chat_entry = entry,
                        } });
                    } else {
                        const id = a.registry.reserve() orelse return;
                        a.cmd_queue.append(a.io, .{ .spawn_agent = .{
                            .agent_id = id,
                            .agent_type = @intFromEnum(r.ContextFactory.AgentType.general),
                            .prompt = &parts,
                            .chat_entry = entry,
                            .cwd = a.cwd,
                        } }) catch {
                            a.registry.releaseReservation(id);
                            return;
                        };
                    }
                }
            }).lua_fn, "cmd.prompt"),
        } },
    },
    .{
        .name = "spawn_agent",
        .desc = "Reserve a free slot and enqueue a spawn or fork into it.",
        .ty = LuaType{ .function = .{
            .args = &.{.{ .name = "args", .ty = SpawnAgentArgsDef }},
            .fn_ptr = (struct {
                fn lua_fn(L: ?*c.lua_State) callconv(.c) c_int {
                    const state = L.?;
                    const a = getAppFromRegistry(state) orelse {
                        _ = c.luaL_error(state, "cmd.spawn_agent: app not initialized");
                        return 0;
                    };
                    const vm = fromState(state) orelse {
                        _ = c.luaL_error(state, "cmd.spawn_agent: no active lua vm");
                        return 0;
                    };

                    const SpawnArgs = struct {
                        parent_id: ?r.AgentId = null,
                        prompt: []const u8,
                        agent_type: ?u32 = null,
                        fork: ?bool = null,
                    };

                    const spawn = switch (readAnyValueAlloc(SpawnArgs, state, "cmd.spawn_agent", 1, vm.luaArena())) {
                        .ok => |v| v,
                        .err => |msg| {
                            _ = c.luaL_error(state, "%s", msg.ptr);
                            return 0;
                        },
                    };

                    if ((spawn.fork orelse false) and spawn.parent_id == null) {
                        _ = c.luaL_error(state, "cmd.spawn_agent: fork=true requires parent_id");
                        return 0;
                    }

                    var args: r.cmd.Command.SpawnArgs = .{
                        .agent_id = .{ .index = 0, .generation = 0 },
                        .parent_id = spawn.parent_id,
                        .prompt = &.{},
                        .fork = spawn.fork orelse false,
                    };
                    if (spawn.agent_type) |t| {
                        if (t > std.math.maxInt(u8)) {
                            _ = c.luaL_error(state, "cmd.spawn_agent: agent_type out of range");
                            return 0;
                        }
                        args.agent_type = @intCast(t);
                    }
                    const parts = [_]r.sdk.Part{.{ .text = spawn.prompt }};
                    args.prompt = &parts;

                    const id = a.registry.reserve() orelse {
                        c.lua_pushnil(state);
                        return 1;
                    };
                    args.agent_id = id;

                    a.cmd_queue.append(a.io, .{ .spawn_agent = args }) catch {
                        a.registry.releaseReservation(id);
                        c.lua_pushnil(state);
                        return 1;
                    };
                    pushAgentId(state, id);
                    return 1;
                }
            }).lua_fn,
            .ret = &AgentIdOrNilDef,
        } },
    },
    .{
        .name = "select",
        .desc = "Open a multiple-choice selection (same widget as the ask tool) and return at once. The callback runs with the picked option text and its 1-based index when the user chooses, with (message, nil) for the custom message row when allow_message is on, and with (nil, nil) when canceled.",
        .ty = LuaType{ .function = .{
            .args = &.{
                .{ .name = "request", .ty = SelectRequestDef },
                .{ .name = "func", .ty = LuaType{ .raw = "fun(choice: string?, index: integer?)" } },
            },
            .fn_ptr = (struct {
                fn lua_fn(L: ?*c.lua_State) callconv(.c) c_int {
                    const state = L.?;
                    const a = getAppFromRegistry(state) orelse {
                        _ = c.luaL_error(state, "cmd.select: app not initialized");
                        return 0;
                    };
                    const vm = fromState(state) orelse {
                        _ = c.luaL_error(state, "cmd.select: no active lua vm");
                        return 0;
                    };
                    if (vm.is_tool_vm) {
                        _ = c.luaL_error(state, "cmd.select: not available in tool vms");
                        return 0;
                    }

                    const Request = struct {
                        header: []const u8,
                        question: []const u8,
                        options: [][]const u8,
                        allow_message: ?bool,
                    };
                    const req = switch (readAnyValueAlloc(Request, state, "cmd.select", 1, vm.luaArena())) {
                        .ok => |v| v,
                        .err => |msg| {
                            _ = c.luaL_error(state, "%s", msg.ptr);
                            return 0;
                        },
                    };
                    if (req.options.len == 0) {
                        _ = c.luaL_error(state, "cmd.select: options must contain at least one entry");
                        return 0;
                    }
                    if (req.options.len > r.tools.ask.MAX_OPTIONS) {
                        _ = c.luaL_error(state, "cmd.select: too many options (max 8)");
                        return 0;
                    }

                    c.lua_pushvalue(state, 2);
                    const func_ref = c.luaL_ref(state, c.LUA_REGISTRYINDEX);

                    const sel = r.selection.Selection.create(a.gpa, .{
                        .header = req.header,
                        .question = req.question,
                        .options = req.options,
                        .allow_message = req.allow_message orelse false,
                    }, func_ref) catch {
                        c.luaL_unref(state, c.LUA_REGISTRYINDEX, func_ref);
                        _ = c.luaL_error(state, "cmd.select: out of memory");
                        return 0;
                    };

                    const g = a.selection_queue.lock(a.io);
                    g.ptr.append(a.gpa, sel) catch {
                        g.unlock();
                        sel.destroy();
                        c.luaL_unref(state, c.LUA_REGISTRYINDEX, func_ref);
                        _ = c.luaL_error(state, "cmd.select: queue append failed");
                        return 0;
                    };
                    g.unlock();
                    a.dirty = true;
                    return 0;
                }
            }).lua_fn,
        } },
    },
    .{
        .name = "await_agent",
        .desc = "Block until the referenced agent reaches a terminal state.",
        .ty = LuaType{ .function = .{
            .args = &.{.{ .name = "agent_id", .ty = AgentIdDef }},
            .ret = &LuaInteger,
            .fn_ptr = (struct {
                fn lua_fn(L: ?*c.lua_State) callconv(.c) c_int {
                    const state = L.?;
                    const a = getAppFromRegistry(state) orelse {
                        _ = c.luaL_error(state, "cmd.await_agent: app not initialized");
                        return 0;
                    };
                    const vm = fromState(state) orelse {
                        _ = c.luaL_error(state, "cmd.await_agent: no active lua vm");
                        return 0;
                    };
                    const id = readAgentIdArg(state, "cmd.await_agent", 1);
                    const io = a.io;
                    if (a.registry.state(id) == null) {
                        c.lua_pushinteger(state, AWAIT_INVALID);
                        return 1;
                    }
                    const slot = &a.registry.slots[id.index];

                    switch (slot.state.load(.acquire)) {
                        .complete => {
                            c.lua_pushinteger(state, AWAIT_COMPLETE);
                            return 1;
                        },
                        .failed => {
                            c.lua_pushinteger(state, AWAIT_FAILED);
                            return 1;
                        },
                        .free => {
                            c.lua_pushinteger(state, AWAIT_INVALID);
                            return 1;
                        },
                        .reserved, .active => {},
                    }

                    if (vm.main_thread_id != 0 and std.Thread.getCurrentId() != vm.main_thread_id) {
                        _ = c.luaL_error(state, "cmd.await_agent: cannot be called from the agent thread");
                        return 0;
                    }
                    vm.vm_mu.unlock(io);
                    slot.event.wait(io) catch {
                        vm.vm_mu.lockUncancelable(io);
                        c.lua_pushinteger(state, AWAIT_CANCELED);
                        return 1;
                    };
                    vm.vm_mu.lockUncancelable(io);

                    if (a.registry.state(id) == null) {
                        c.lua_pushinteger(state, AWAIT_CANCELED);
                        return 1;
                    }
                    const slot_now = &a.registry.slots[id.index];
                    const code: c_int = switch (slot_now.state.load(.acquire)) {
                        .complete => AWAIT_COMPLETE,
                        .failed => AWAIT_FAILED,
                        else => AWAIT_CANCELED,
                    };
                    c.lua_pushinteger(state, code);
                    return 1;
                }
            }).lua_fn,
        } },
    },
    .{
        .name = "await_agent_result",
        .desc = "Return the awaited agent's last assistant text.",
        .ty = LuaType{ .function = .{
            .args = &.{.{ .name = "agent_id", .ty = AgentIdDef }},
            .ret = &StringOrNilDef,
            .fn_ptr = (struct {
                fn lua_fn(L: ?*c.lua_State) callconv(.c) c_int {
                    const state = L.?;
                    const a = getAppFromRegistry(state) orelse {
                        _ = c.luaL_error(state, "cmd.await_agent_result: app not initialized");
                        return 0;
                    };
                    const id = readAgentIdArg(state, "cmd.await_agent_result", 1);
                    const agent = a.registry.get(id) orelse {
                        _ = c.luaL_error(state, "cmd.await_agent_result: agent not found");
                        return 0;
                    };
                    if (agent.history().len == 0) {
                        _ = c.luaL_error(state, "cmd.await_agent_result: agent has no chat entries");
                        return 0;
                    }

                    const last_msg = &agent.history()[agent.history().len -| 1];
                    var total: usize = 0;
                    for (last_msg.parts()) |p| switch (p) {
                        .text => |t| total += t.len,
                        else => {},
                    };
                    if (total == 0) {
                        _ = c.lua_pushlstring(state, "", 0);
                        return 1;
                    }

                    var b: c.luaL_Buffer = undefined;
                    c.luaL_buffinit(state, &b);
                    for (last_msg.parts()) |p| switch (p) {
                        .text => |t| c.luaL_addlstring(&b, t.ptr, t.len),
                        else => {},
                    };
                    c.luaL_pushresult(&b);
                    return 1;
                }
            }).lua_fn,
        } },
    },
    .{
        .name = "attach_screenshot",
        .desc = "Attach a screenshot/image to the current input.",
        .ty = LuaType{ .function = .{
            .args = &.{ .{ .name = "data", .ty = LuaType.string }, .{ .name = "media_type", .ty = LuaType.string, .optional = true } },
            .fn_ptr = LuaFnBind((struct {
                fn lua_fn(state: *c.lua_State, a: *r.app.App, data: []const u8, media_type: ?[]const u8) !void {
                    if (try isToolVm(state)) return;
                    try a.cmd_queue.append(a.io, .{ .attach_screenshot = .{
                        .media_type = media_type orelse "image/png",
                        .data = data,
                    } });
                }
            }).lua_fn, "cmd.attach_screenshot"),
        } },
    },
} } };

// ── Lua Tool Registry (per-VM, reached via registry lookup) ─────────

const LuaToolEntry = struct {
    name: [128]u8 = undefined,
    name_len: usize = 0,
    description: [1024]u8 = undefined,
    desc_len: usize = 0,
    snippet: [256]u8 = undefined,
    snippet_len: usize = 0,
    guidelines: [512]u8 = undefined,
    guidelines_len: usize = 0,
    schema: [2048]u8 = undefined,
    schema_len: usize = 0,
    func_ref: c_int = c.LUA_NOREF,
    state_ref: c_int = c.LUA_NOREF,
    L: ?*c.lua_State = null,

    fn nameSlice(self: *const LuaToolEntry) []const u8 {
        return self.name[0..self.name_len];
    }
    fn descSlice(self: *const LuaToolEntry) []const u8 {
        return self.description[0..self.desc_len];
    }
    fn snippetSlice(self: *const LuaToolEntry) []const u8 {
        return self.snippet[0..self.snippet_len];
    }
    fn guidelinesSlice(self: *const LuaToolEntry) []const u8 {
        return self.guidelines[0..self.guidelines_len];
    }
    fn schemaSlice(self: *const LuaToolEntry) []const u8 {
        return self.schema[0..self.schema_len];
    }
};

const LuaBindEntry = struct {
    key: tui.Key = .{ .code = .{ .char = 0 } },
    description: [128]u8 = undefined,
    description_len: usize = 0,
    func_ref: c_int = c.LUA_NOREF,
    L: ?*c.lua_State = null,

    fn descriptionSlice(self: *const LuaBindEntry) []const u8 {
        return self.description[0..self.description_len];
    }
};

const LuaHookEntry = struct {
    tag: r.events.AppEventTag,
    func_ref: c_int = c.LUA_NOREF,
};

const LuaCommandEntry = struct {
    name: [128]u8 = undefined,
    name_len: usize = 0,
    description: [128]u8 = undefined,
    description_len: usize = 0,
    func_ref: c_int = c.LUA_NOREF,
    L: ?*c.lua_State = null,

    fn nameSlice(self: *const LuaCommandEntry) []const u8 {
        return self.name[0..self.name_len];
    }

    fn descriptionSlice(self: *const LuaCommandEntry) ?[]const u8 {
        if (self.description_len == 0) return null;
        return self.description[0..self.description_len];
    }
};

fn fieldName(comptime field: []const u8) [*:0]const u8 {
    return (field ++ "\x00").ptr;
}

fn pushAny(L: *c.lua_State, value: anytype) void {
    const T = @TypeOf(value);
    const Info = @typeInfo(T);
    switch (Info) {
        .optional => {
            if (value) |inner| {
                pushAny(L, inner);
            } else {
                c.lua_pushnil(L);
            }
        },
        .bool => c.lua_pushboolean(L, @intFromBool(value)),
        .comptime_int, .int => c.lua_pushinteger(L, @intCast(value)),
        .comptime_float, .float => c.lua_pushnumber(L, @floatCast(value)),
        .@"enum" => c.lua_pushinteger(L, @intFromEnum(value)),
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                _ = c.lua_pushlstring(L, value.ptr, value.len);
            } else if (ptr.size == .slice) {
                c.lua_createtable(L, @intCast(value.len), 0);
                for (value, 0..) |item, i| {
                    pushAny(L, item);
                    c.lua_rawseti(L, -2, @intCast(i + 1));
                }
            } else {
                @compileError("pushAny: unsupported pointer type " ++ @typeName(T));
            }
        },
        .array => |arr| {
            if (arr.child == u8) {
                _ = c.lua_pushlstring(L, &value, value.len);
            } else {
                c.lua_createtable(L, @intCast(value.len), 0);
                for (value, 0..) |item, i| {
                    pushAny(L, item);
                    c.lua_rawseti(L, -2, @intCast(i + 1));
                }
            }
        },
        .@"struct" => |str| {
            if (T == r.AgentId) {
                c.lua_pushinteger(L, @intCast(id_pack: {
                    const Backing = str.backing_integer.?;
                    break :id_pack @as(Backing, @bitCast(value));
                }));
                return;
            }
            c.lua_createtable(L, 0, @intCast(str.fields.len));
            inline for (str.fields) |field| {
                pushAny(L, @field(value, field.name));
                c.lua_setfield(L, -2, fieldName(field.name));
            }
        },
        .void => {},
        else => @compileError("pushAny: unsupported type " ++ @typeName(T)),
    }
}

fn setFieldPushed(L: *c.lua_State, table_idx: c_int, comptime field: []const u8) void {
    c.lua_setfield(L, table_idx, fieldName(field));
}

fn setFieldAny(L: *c.lua_State, table_idx: c_int, comptime field: []const u8, value: anytype) void {
    pushAny(L, value);
    setFieldPushed(L, table_idx, field);
}

fn setCFunctionField(
    L: *c.lua_State,
    table_idx: c_int,
    comptime field: []const u8,
    func: c.lua_CFunction,
) void {
    c.lua_pushcfunction(L, func);
    setFieldPushed(L, table_idx, field);
}

fn pushLuaValue(L: *c.lua_State, comptime value: LuaType.Value) void {
    switch (value) {
        .integer => |n| c.lua_pushinteger(L, n),
        .string => |s| _ = c.lua_pushlstring(L, s.ptr, s.len),
    }
}

fn pushLuaType(L: *c.lua_State, comptime ty: LuaType) void {
    const def = switch (ty) {
        .table_def => |def| def,
        else => @compileError("Lua API root must be a table_def"),
    };

    c.lua_createtable(L, 0, @intCast(def.fields.len));
    inline for (def.fields) |field| {
        if (field.value) |value| {
            pushLuaValue(L, value);
            setFieldPushed(L, -2, field.name);
        } else switch (field.ty) {
            .table_def => {
                pushLuaType(L, field.ty);
                setFieldPushed(L, -2, field.name);
            },
            .function => |f| {
                if (f.fn_ptr) |fn_ptr| {
                    setCFunctionField(L, -2, field.name, fn_ptr);
                }
            },
            else => {},
        }
    }
}

fn setLuaTypeGlobal(L: *c.lua_State, comptime name: []const u8, comptime ty: LuaType) void {
    pushLuaType(L, ty);
    c.lua_setglobal(L, fieldName(name));
}

fn setClosureField(
    L: *c.lua_State,
    table_idx: c_int,
    comptime field: []const u8,
    userdata: *anyopaque,
    func: c.lua_CFunction,
) void {
    c.lua_pushlightuserdata(L, userdata);
    c.lua_pushcclosure(L, func, 1);
    setFieldPushed(L, table_idx, field);
}

fn pushNilBool(L: *c.lua_State, ok: bool) c_int {
    c.lua_pushnil(L);
    c.lua_pushboolean(L, @intFromBool(ok));
    return 2;
}

fn pushStatusNil(L: *c.lua_State, status: c_int) c_int {
    c.lua_pushinteger(L, status);
    c.lua_pushnil(L);
    return 2;
}

fn readAnyValue(comptime T: type, state: *c.lua_State, idx: c_int) ?T {
    const res = readAnyValueAlloc(T, state, "unknown", idx, null);
    switch (res) {
        .ok => |t| return t,
        .err => return null,
    }
}

fn ReadResult(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: []const u8,

        /// to many curly brackets?
        pub fn Err(err: []const u8) @This() {
            return .{ .err = err };
        }

        /// to many curly brackets?
        pub fn Ok(v: T) @This() {
            return .{ .ok = v };
        }

        pub fn E(err: anyerror) @This() {
            return .{ .err = @tagName(err) };
        }
    };
}

fn readAnyValueAlloc(
    comptime T: type,
    state: *c.lua_State,
    comptime name: []const u8,
    idx: c_int,
    allocator: ?Allocator,
) ReadResult(T) {
    if (T == LuaFnRef) {
        if (c.lua_type(state, idx) != c.LUA_TFUNCTION) return .Err(name ++ " is not a function");
        c.lua_pushvalue(state, idx);
        return .Ok(.{ .idx = c.luaL_ref(state, c.LUA_REGISTRYINDEX) });
    }

    if (T == LuaTableRef) {
        if (c.lua_type(state, idx) != c.LUA_TTABLE) return .Err(name ++ " is not a table");
        return .Ok(.{ .idx = c.lua_absindex(state, idx) });
    }

    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.size != .slice) @compileError("readAnyValue: unsupported pointer type " ++ @typeName(T));
            if (ptr.child == u8) {
                if (c.lua_type(state, idx) != c.LUA_TSTRING) return .Err(name ++ " is not a string");
                var len: usize = 0;
                const sptr = c.lua_tolstring(state, idx, &len) orelse return .Err(name ++ ": failed string conversion");
                return .Ok(sptr[0..len]);
            }
            if (c.lua_type(state, idx) != c.LUA_TTABLE) return .Err(name ++ " must be table for allocation");
            const alloc = allocator orelse return .Err(name ++ " require allocator");
            const abs = c.lua_absindex(state, idx);
            const len = c.lua_rawlen(state, abs);
            const result = alloc.alloc(ptr.child, len) catch return .Err("oom");
            for (result, 0..) |*item, i| {
                _ = c.lua_rawgeti(state, abs, @intCast(i + 1));
                defer c.lua_pop(state, 1);

                const res = readAnyValueAlloc(ptr.child, state, @typeName(ptr.child), -1, allocator);
                switch (res) {
                    .ok => |v| item.* = v,
                    .err => |msg| return .Err(msg),
                }
            }
            return .Ok(result);
        },
        .int, .comptime_int => {
            if (c.lua_type(state, idx) != c.LUA_TNUMBER) return .Err(name ++ " not a number");
            const n = c.lua_tointegerx(state, idx, null);
            if (T != comptime_int) {
                if (@typeInfo(T).int.signedness == .unsigned and n < 0) return .Err(name ++ " is unsigned");
                if (n < std.math.minInt(T) or n > std.math.maxInt(T)) return .Err(name ++ " integer overflow");
            }
            return .Ok(@as(T, @intCast(n)));
        },
        .float, .comptime_float => {
            if (c.lua_type(state, idx) != c.LUA_TNUMBER) return .Err(name ++ " not a float");
            return .Ok(@as(T, @floatCast(c.lua_tonumberx(state, idx, null))));
        },
        .bool => {
            if (c.lua_type(state, idx) != c.LUA_TBOOLEAN) return .Err(name ++ " not a bool");
            return .Ok(c.lua_toboolean(state, idx) != 0);
        },
        .@"enum" => {
            if (c.lua_type(state, idx) != c.LUA_TNUMBER) return .Err(name ++ " not a number");
            const n = c.lua_tointegerx(state, idx, null);
            const info = @typeInfo(T).@"enum";
            if (n < 0 or n > std.math.maxInt(info.tag_type)) return .Err(name ++ " overflow");
            if (info.is_exhaustive and n >= info.fields.len) return .Err(name ++ " invalid enum value");
            return .Ok(@enumFromInt(@as(info.tag_type, @intCast(n))));
        },
        .array => |arr| {
            if (c.lua_type(state, idx) != c.LUA_TTABLE) return .Err(name ++ " not a table");
            const abs = c.lua_absindex(state, idx);
            if (c.lua_rawlen(state, abs) != arr.len) return .Err(name ++ " array length mismatch");
            var result: T = undefined;
            for (&result, 0..) |*item, i| {
                _ = c.lua_rawgeti(state, abs, @intCast(i + 1));
                defer c.lua_pop(state, 1);

                const res = readAnyValueAlloc(arr.child, state, @typeName(arr.child), -1, allocator);
                switch (res) {
                    .ok => |val| item.* = val,
                    .err => |msg| return .Err(msg),
                }
            }
            return .Ok(result);
        },
        .@"struct" => |str| {
            if (T == r.AgentId) {
                if (c.lua_type(state, idx) != c.LUA_TNUMBER) return .Err(name ++ " not a number");
                const Backing = str.backing_integer.?;
                const n = c.lua_tointegerx(state, idx, null);
                if (n < std.math.minInt(Backing) or n > std.math.maxInt(Backing)) return .Err(name ++ " integer overflow");
                return .Ok(@as(T, @bitCast(@as(Backing, @intCast(n)))));
            }
            if (c.lua_type(state, idx) != c.LUA_TTABLE) return .Err(name ++ " is not a table");
            var result: T = undefined;
            inline for (str.fields) |field| {
                const res = readAnyFieldAlloc(field.type, state, field.name, idx, allocator);
                switch (res) {
                    .ok => |val| @field(result, field.name) = val,
                    .err => |msg| return .Err(msg),
                }
            }
            return .Ok(result);
        },
        .optional => |opt| {
            const res = readAnyValueAlloc(opt.child, state, name, idx, allocator);
            switch (res) {
                .ok => |val| return .Ok(val),
                .err => return .Ok(null),
            }
        },
        else => @compileError("readAnyValue: unsupported type " ++ @typeName(T)),
    }
}

fn readAnyFieldAlloc(comptime T: type, state: *c.lua_State, comptime field: []const u8, table_idx: c_int, allocator: ?Allocator) ReadResult(T) {
    const abs = c.lua_absindex(state, table_idx);
    _ = c.lua_getfield(state, abs, fieldName(field));
    defer c.lua_pop(state, 1);
    return readAnyValueAlloc(T, state, field, -1, allocator);
}

fn getStringField(state: *c.lua_State, table_idx: c_int, field: [*:0]const u8, dest: []u8) ?usize {
    _ = c.lua_getfield(state, table_idx, field);
    defer c.lua_pop(state, 1);
    if (c.lua_type(state, -1) != c.LUA_TSTRING) return null;
    var len: usize = 0;
    const ptr = c.lua_tolstring(state, -1, &len);
    if (len > dest.len) return null;
    @memcpy(dest[0..len], ptr[0..len]);
    return len;
}

fn findEntry(vm: *LuaVm, name: []const u8) ?*LuaToolEntry {
    for (vm.tool_entries.items) |*entry| {
        if (std.mem.eql(u8, entry.nameSlice(), name)) return entry;
    }
    return null;
}

fn findHookEntries(vm: *LuaVm, tag: r.events.AppEventTag) []const LuaHookEntry {
    var count: usize = 0;
    for (vm.hook_entries.items) |entry| {
        if (entry.tag == tag) count += 1;
    }
    const matched = vm.luaArena().alloc(LuaHookEntry, count) catch return &.{};
    var i: usize = 0;
    for (vm.hook_entries.items) |entry| {
        if (entry.tag != tag) continue;
        matched[i] = entry;
        i += 1;
    }
    return matched;
}

fn pushEventPayload(L: *c.lua_State, event: r.events.AppEvent) c_int {
    switch (event) {
        .session_reset, .mcp_tools_reloaded => return 0,
        .agent_created => |payload| pushAny(L, payload),
        .agent_failed => |payload| pushAny(L, payload),
        .user_message_sent => |text| pushAny(L, .{ .text = text }),
        .agent_started, .agent_complete, .agent_cancelled, .compaction_started, .compaction_complete => |id| pushAny(L, .{ .id = id }),
    }
    return 1;
}

// ── ToolContext bridge (passed as light userdata during tool calls) ──

const CtxBridge = struct {
    cwd: []const u8,
    tool_ctx: ToolContext,
    tool_call: ToolCall,
};

// ── LuaVm ───────────────────────────────────────────────────────────

var app_registry_key: u8 = 0;

var owner_registry_key: u8 = 0;

fn fromState(L: *c.lua_State) ?*LuaVm {
    _ = c.lua_rawgetp(L, c.LUA_REGISTRYINDEX, @ptrCast(&owner_registry_key));
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TLIGHTUSERDATA) return null;
    const ptr = c.lua_touserdata(L, -1) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn isToolVm(state: *c.lua_State) !bool {
    const vm = fromState(state) orelse return error.NoLuaVm;
    return vm.is_tool_vm;
}

fn luaArenaAlloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    const arena_state: *std.heap.ArenaAllocator = @ptrCast(@alignCast(ud orelse return null));
    const arena = arena_state.allocator();
    const alignment: std.mem.Alignment = .of(std.c.max_align_t);

    if (nsize == 0) return null;

    const new_ptr = arena.rawAlloc(nsize, alignment, @returnAddress()) orelse return null;
    if (ptr) |old_ptr| {
        const old_mem = @as([*]u8, @ptrCast(old_ptr))[0..osize];
        const copy_len = @min(osize, nsize);
        @memcpy(new_ptr[0..copy_len], old_mem[0..copy_len]);
    }
    return @ptrCast(new_ptr);
}

fn luaGpaAlloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    const vm: *LuaVm = @ptrCast(@alignCast(ud orelse return null));
    return luaAllocWith(&vm.parent, ptr, osize, nsize);
}

fn luaAllocWith(alloc: *const Allocator, ptr: ?*anyopaque, osize: usize, nsize: usize) ?*anyopaque {
    const alignment: std.mem.Alignment = .of(std.c.max_align_t);

    if (nsize == 0) {
        if (ptr) |p| alloc.rawFree(@as([*]u8, @ptrCast(p))[0..osize], alignment, @returnAddress());
        return null;
    }

    if (ptr) |old_ptr| {
        const old = @as([*]u8, @ptrCast(old_ptr))[0..osize];
        if (alloc.rawResize(old, alignment, nsize, @returnAddress())) return old_ptr;
        const new_ptr = alloc.rawAlloc(nsize, alignment, @returnAddress()) orelse return null;
        const copy_len = @min(osize, nsize);
        @memcpy(new_ptr[0..copy_len], old[0..copy_len]);
        alloc.rawFree(old, alignment, @returnAddress());
        return @ptrCast(new_ptr);
    }

    return @ptrCast(alloc.rawAlloc(nsize, alignment, @returnAddress()) orelse return null);
}

const MAX_LUA_TOOLS = 64;
const LUA_ERROR_SHOW_MS: i64 = 8_000;
pub const LUA_ERROR_FADE_NS: i128 = 2 * std.time.ns_per_s;
const MAX_LUA_BINDS = 64;
const MAX_LUA_COMMANDS = 64;
const MAX_LUA_MCP_SERVERS = 16;
const MAX_LUA_MCP_ARGS = 32;
const STDOUT_BUF_CAP = 1024 * 1024 * 16;
const CANCELLATION_HOOK_INTERVAL = 10000;
const MAX_STATE_DEPTH: u32 = 64;

pub const LuaMcpServerEntry = struct {
    name: []const u8,
    command: []const u8,
    args: [][]const u8,
    tools_prefix: []const u8,
    enabled: bool = false,
    conf_enabled: bool = false,
};

pub const LuaErrorSource = enum { config, action };

pub const LuaVm = struct {
    L: *c.lua_State,
    app: ?*app.App = null,
    is_tool_vm: bool = false,
    main_thread_id: std.Thread.Id = 0,
    cancel_token: ?*r.sdk.CancellationToken = null,
    parent: Allocator,
    arena_state: std.heap.ArenaAllocator,
    tool_entries: std.ArrayList(LuaToolEntry) = .empty,
    hook_entries: std.ArrayList(LuaHookEntry) = .empty,
    bind_entries: std.ArrayList(LuaBindEntry) = .empty,
    command_entries: std.ArrayList(LuaCommandEntry) = .empty,
    mcp_entries: std.ArrayList(LuaMcpServerEntry) = .empty,
    stdout_buf: std.ArrayList(u8) = .empty,
    last_error: [512]u8 = undefined,
    last_error_len: usize = 0,
    last_error_until_ns: i128 = 0,
    /// Serializes lua_pcall across worker threads. Lua VMs are not
    /// thread-safe; native tools run in parallel, Lua tools serialize here.
    vm_mu: std.Io.Mutex = .init,
    /// blitz.hooks.approve() slot. One handler, last registration wins.
    permission_hook: c_int = c.LUA_NOREF,
    inject_fn: c_int = c.LUA_NOREF,

    pub fn init(parent: Allocator) !*LuaVm {
        return create(parent, false);
    }

    pub fn initTool(parent: Allocator) !*LuaVm {
        return create(parent, true);
    }

    fn create(parent: Allocator, is_tool_vm: bool) !*LuaVm {
        const self = try parent.create(LuaVm);
        errdefer parent.destroy(self);
        self.* = .{
            .L = undefined,
            .is_tool_vm = is_tool_vm,
            .main_thread_id = if (is_tool_vm) 0 else std.Thread.getCurrentId(),
            .parent = parent,
            .arena_state = std.heap.ArenaAllocator.init(parent),
        };
        errdefer self.arena_state.deinit();
        try self.prepareArenaLists();
        try self.initLuaState();
        return self;
    }

    fn luaArena(self: *LuaVm) Allocator {
        return self.arena_state.allocator();
    }

    fn prepareArenaLists(self: *LuaVm) !void {
        const arena = self.luaArena();
        try self.tool_entries.ensureTotalCapacity(arena, MAX_LUA_TOOLS);
        if (self.is_tool_vm) return;
        try self.bind_entries.ensureTotalCapacity(arena, MAX_LUA_BINDS);
        try self.command_entries.ensureTotalCapacity(arena, MAX_LUA_COMMANDS);
        try self.mcp_entries.ensureTotalCapacity(arena, MAX_LUA_MCP_SERVERS);
        try self.stdout_buf.ensureTotalCapacity(arena, STDOUT_BUF_CAP);
    }

    fn bindLuaAllocator(self: *LuaVm) void {
        if (self.is_tool_vm) {
            c.lua_setallocf(self.L, &luaArenaAlloc, @ptrCast(&self.arena_state));
        } else {
            c.lua_setallocf(self.L, &luaGpaAlloc, @ptrCast(self));
        }
    }

    fn initLuaState(self: *LuaVm) !void {
        const allocf: c.lua_Alloc = if (self.is_tool_vm) &luaArenaAlloc else &luaGpaAlloc;
        const ud: *anyopaque = if (self.is_tool_vm) @ptrCast(&self.arena_state) else @ptrCast(self);
        self.L = c.lua_newstate(allocf, ud) orelse return error.LuaInitFailed;
        c.luaL_openlibs(self.L);
        c.lua_pushcfunction(self.L, &luaPrintToBuffer);
        c.lua_setglobal(self.L, "print");
        registerBlitzLib(self.L);
    }

    pub fn setApp(self: *LuaVm, a: *app.App) void {
        self.bindLuaAllocator();
        self.app = a;
        c.lua_pushlightuserdata(self.L, @ptrCast(a));
        c.lua_rawsetp(self.L, c.LUA_REGISTRYINDEX, @ptrCast(&app_registry_key));
        self.installOwner();
    }

    pub fn installOwner(self: *LuaVm) void {
        c.lua_pushlightuserdata(self.L, @ptrCast(self));
        c.lua_rawsetp(self.L, c.LUA_REGISTRYINDEX, @ptrCast(&owner_registry_key));
    }

    pub fn deinit(self: *LuaVm) void {
        c.lua_close(self.L);
        self.arena_state.deinit();
        self.parent.destroy(self);
    }

    pub fn load(self: *LuaVm, path: []const u8) !void {
        // Null-terminate for C
        var buf: [4096]u8 = undefined;
        if (path.len >= buf.len) return error.PathTooLong;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;

        const status = c.luaL_loadfilex(self.L, &buf, null);
        if (status != 0) {
            self.popError(.config);
            return error.LuaLoadFailed;
        }
        const call_status = c.lua_pcallk(self.L, 0, c.LUA_MULTRET, 0, 0, null);
        if (call_status != 0) {
            self.popError(.config);
            return error.LuaLoadFailed;
        }
    }

    pub fn exec(self: *LuaVm, code: []const u8) !void {
        const status = c.luaL_loadbufferx(self.L, code.ptr, code.len, null, null);
        if (status != 0) {
            self.popError(.config);
            return error.LuaExecFailed;
        }
        const call_status = c.lua_pcallk(self.L, 0, c.LUA_MULTRET, 0, 0, null);
        if (call_status != 0) {
            self.popError(.config);
            return error.LuaExecFailed;
        }
    }

    pub fn reset(self: *LuaVm) !void {
        for (self.tool_entries.items) |*entry| {
            c.luaL_unref(self.L, c.LUA_REGISTRYINDEX, entry.func_ref);
            c.luaL_unref(self.L, c.LUA_REGISTRYINDEX, entry.state_ref);
        }
        for (self.bind_entries.items) |*entry| {
            c.luaL_unref(self.L, c.LUA_REGISTRYINDEX, entry.func_ref);
        }
        for (self.command_entries.items) |*entry| {
            c.luaL_unref(self.L, c.LUA_REGISTRYINDEX, entry.func_ref);
        }
        c.lua_close(self.L);
        _ = self.arena_state.reset(.free_all);
        self.tool_entries = .empty;
        self.hook_entries = .empty;
        self.bind_entries = .empty;
        self.command_entries = .empty;
        self.mcp_entries = .empty;
        self.stdout_buf = .empty;
        self.prepareArenaLists() catch return error.LuaInitFailed;
        self.tool_entries.clearRetainingCapacity();
        self.hook_entries.clearRetainingCapacity();
        self.bind_entries.clearRetainingCapacity();
        self.command_entries.clearRetainingCapacity();
        self.mcp_entries.clearRetainingCapacity();
        self.stdout_buf.clearRetainingCapacity();
        self.permission_hook = c.LUA_NOREF;
        self.inject_fn = c.LUA_NOREF;
        if (self.app) |a| {
            a.config.reset();
            a.default_context_limit = app.CONTEXT_LIMIT;
        }
        try self.initLuaState();
        if (self.app) |a| self.setApp(a);
    }

    fn popError(self: *LuaVm, source: LuaErrorSource) void {
        if (c.lua_gettop(self.L) > 0) {
            var len: usize = 0;
            const ptr = c.lua_tolstring(self.L, -1, &len);
            if (ptr) |p| {
                const capped = @min(len, self.last_error.len);
                @memcpy(self.last_error[0..capped], p[0..capped]);
                self.last_error_len = capped;
            } else {
                self.last_error_len = 0;
            }
            c.lua_pop(self.L, 1);
        } else {
            self.last_error_len = 0;
        }
        self.last_error_until_ns = switch (source) {
            .config => std.math.maxInt(i128),
            .action => self.nowAwakeNs() + LUA_ERROR_SHOW_MS * std.time.ns_per_ms,
        };
    }

    fn nowAwakeNs(self: *LuaVm) i128 {
        const a = self.app orelse return 0;
        return std.Io.Clock.Timestamp.now(a.io, .awake).raw.nanoseconds;
    }

    pub fn getLastError(self: *const LuaVm) []const u8 {
        return self.last_error[0..self.last_error_len];
    }

    pub fn errorAlive(self: *const LuaVm, now_ns: i128) bool {
        return self.last_error_len != 0 and now_ns < self.last_error_until_ns;
    }

    pub fn errorNeedsFrame(self: *const LuaVm, now_ns: i128) bool {
        return self.errorAlive(now_ns) and self.last_error_until_ns -| now_ns <= LUA_ERROR_FADE_NS;
    }

    pub fn clearLastError(self: *LuaVm) void {
        self.last_error_len = 0;
        self.last_error_until_ns = 0;
    }

    /// Build Tool array from registered Lua tools. Caller owns slice.
    pub fn getRegisteredTools(self: *LuaVm, alloc: Allocator) ![]Tool {
        if (self.tool_entries.items.len == 0) return &.{};
        const tools = try alloc.alloc(Tool, self.tool_entries.items.len);
        for (self.tool_entries.items, 0..) |*entry, i| {
            tools[i] = .{
                .def = .{
                    .name = entry.nameSlice(),
                    .description = entry.descSlice(),
                    .parameters_schema = entry.schemaSlice(),
                    .prompt_snippet = if (entry.snippet_len > 0) entry.snippetSlice() else null,
                    .prompt_guidelines = if (entry.guidelines_len > 0) entry.guidelinesSlice() else null,
                },
                .func = &luaToolTrampoline,
            };
        }
        return tools;
    }

    pub const LuaBind = struct {
        key: tui.Key,
        description: []const u8 = "",
        lua_fn: c_int,
    };

    pub fn getRegisteredKeybinds(self: *LuaVm, alloc: Allocator) ![]LuaBind {
        if (self.bind_entries.items.len == 0) return &.{};
        const out = try alloc.alloc(LuaBind, self.bind_entries.items.len);
        for (self.bind_entries.items, 0..) |entry, i| {
            out[i] = .{
                .key = entry.key,
                .description = try alloc.dupe(u8, entry.descriptionSlice()),
                .lua_fn = entry.func_ref,
            };
        }
        return out;
    }

    fn collectEnabledServers(
        comptime Entry: type,
        comptime Cfg: type,
        comptime toCfg: fn (*Entry) Cfg,
        entries: []Entry,
        alloc: Allocator,
    ) ![]Cfg {
        if (entries.len == 0) return &.{};
        var count: usize = 0;
        for (entries) |*entry| {
            if (entry.enabled) count += 1;
        }
        if (count == 0) return &.{};

        const out = try alloc.alloc(Cfg, count);
        var out_i: usize = 0;
        for (entries) |*entry| {
            if (!entry.enabled) continue;
            out[out_i] = toCfg(entry);
            out_i += 1;
        }
        return out;
    }

    fn mcpToConfig(entry: *LuaMcpServerEntry) @import("mcp.zig").ServerConfig {
        return .{
            .name = entry.name,
            .command = entry.command,
            .args = entry.args,
            .tools_prefix = entry.tools_prefix,
        };
    }

    pub fn getEnabledMcpServers(self: *LuaVm, alloc: Allocator) ![]@import("mcp.zig").ServerConfig {
        return collectEnabledServers(LuaMcpServerEntry, @import("mcp.zig").ServerConfig, mcpToConfig, self.mcp_entries.items, alloc);
    }

    pub fn disableAllMcp(self: *LuaVm) void {
        for (self.mcp_entries.items) |*entry| entry.enabled = entry.conf_enabled;
    }

    pub fn hasMcp(self: *LuaVm, name: []const u8) bool {
        return self.findMcp(name) != null;
    }

    pub fn enableMcp(self: *LuaVm, name: []const u8) bool {
        const entry = self.findMcp(name) orelse return false;
        entry.enabled = true;
        return true;
    }

    pub fn publishAvailableSystems(self: *LuaVm, factory: *r.ContextFactory) !void {
        var mcp_names: [MAX_LUA_MCP_SERVERS][]const u8 = undefined;

        for (self.mcp_entries.items, 0..) |*entry, i| mcp_names[i] = entry.name;

        try factory.setAvailableSystems(mcp_names[0..self.mcp_entries.items.len]);
    }

    fn findMcp(self: *LuaVm, name: []const u8) ?*LuaMcpServerEntry {
        for (self.mcp_entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    /// Invoke a previously bound lua callback by its registry ref.
    pub fn invokeBind(self: *LuaVm, func_ref: c_int) void {
        _ = c.lua_rawgeti(self.L, c.LUA_REGISTRYINDEX, func_ref);
        if (c.lua_type(self.L, -1) != c.LUA_TFUNCTION) {
            c.lua_pop(self.L, 1);
            return;
        }
        const status = c.lua_pcallk(self.L, 0, 0, 0, 0, null);
        if (status != 0) self.popError(.action);
    }

    /// Invoke a registered lua command. `input` may be the full typed command
    /// ("/name args") or only the command name; returns false when unhandled.
    pub fn invokeCommand(self: *LuaVm, input: []const u8) bool {
        if (input.len == 0) return false;

        const split_at = std.mem.indexOfScalar(u8, input, ' ') orelse input.len;
        const name = input[0..split_at];
        const args = if (split_at < input.len) input[split_at + 1 ..] else "";

        for (self.command_entries.items) |*entry| {
            if (!std.mem.eql(u8, entry.nameSlice(), name)) continue;

            _ = c.lua_rawgeti(self.L, c.LUA_REGISTRYINDEX, entry.func_ref);
            if (c.lua_type(self.L, -1) != c.LUA_TFUNCTION) {
                c.lua_pop(self.L, 1);
                return true;
            }

            _ = c.lua_pushlstring(self.L, args.ptr, args.len);
            const status = c.lua_pcallk(self.L, 1, 0, 0, 0, null);
            if (status != 0) self.popError(.action);
            return true;
        }

        return false;
    }

    pub fn invokeEventHooks(self: *LuaVm, event: r.events.AppEvent) void {
        const tag = std.meta.activeTag(event);
        const entries = findHookEntries(self, tag);
        if (entries.len == 0) {
            hookLog(.warn, "no {s} listener registered after config load", .{@tagName(tag)});
            return;
        }

        const L = self.L;
        const top = c.lua_gettop(L);
        defer c.lua_settop(L, top);

        for (entries) |entry| {
            _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, entry.func_ref);
            if (c.lua_type(L, -1) != c.LUA_TFUNCTION) {
                c.lua_pop(L, 1);
                continue;
            }
            const nargs = pushEventPayload(L, event);

            const status = c.lua_pcallk(L, nargs, 0, 0, 0, null);
            if (status != 0) {
                var err_len: usize = 0;
                const err_ptr = c.lua_tolstring(L, -1, &err_len);
                hookLog(
                    .err,
                    "{s} listener failed: {s}",
                    .{ @tagName(tag), if (err_ptr) |p| p[0..err_len] else "unknown error" },
                );
                c.lua_pop(L, 1);
            }
        }
    }

    pub fn appendCommandCompletions(
        self: *LuaVm,
        prefix: []const u8,
        out: []?app.CommandCompletion,
        count: *usize,
    ) void {
        for (self.command_entries.items) |*entry| {
            if (count.* >= out.len) return;

            const name = entry.nameSlice();
            if (!startsWithIgnoreCase(name, prefix)) continue;
            {
                var dup = false;
                for (out[0..count.*]) |item| {
                    const value = item orelse continue;
                    if (std.mem.eql(u8, value.text, name)) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue;
            }

            out[count.*] = .{ .text = name, .description = entry.descriptionSlice() };
            count.* += 1;
        }
    }

    fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
        if (prefix.len > value.len) return false;
        for (prefix, 0..) |ch, i| {
            if (std.ascii.toLower(ch) != std.ascii.toLower(value[i])) return false;
        }
        return true;
    }

    /// Read config fields from the blitz global table after script execution.
    pub fn readConfigFields(self: *LuaVm) void {
        const a = self.app orelse return;
        const L = self.L;

        a.lua_status_bar_enabled = false;
        a.lua_status_bar_cache_len = 0;

        _ = c.lua_getglobal(L, "blitz");
        if (c.lua_type(L, -1) != c.LUA_TTABLE) {
            c.lua_pop(L, 1);
            return;
        }

        // blitz.status_bar_render = function() return "..." end
        _ = c.lua_getfield(L, -1, "status_bar_render");
        a.lua_status_bar_enabled = c.lua_type(L, -1) == c.LUA_TFUNCTION;
        c.lua_pop(L, 1);

        _ = c.lua_getfield(L, -1, "theme");
        if (c.lua_type(L, -1) == c.LUA_TTABLE) {
            switch (readAnyValueAlloc(ThemeArg, L, "blitz.theme", -1, self.luaArena())) {
                .ok => |theme| {
                    a.mu.lockUncancelable(a.io);
                    defer a.mu.unlock(a.io);
                    applyTheme(a, theme) catch |err| {
                        log.err("invalid blitz.theme: {s}", .{@errorName(err)});
                    };
                },
                .err => |msg| log.err("invalid blitz.theme: {s}", .{msg}),
            }
        }
        c.lua_pop(L, 1);

        c.lua_pop(L, 1); // pop blitz table
    }

    /// Call blitz.status_bar_render() and copy its returned string into `dest`.
    /// Caller must hold vm_mu. Returns null when the hook is missing, errors,
    /// or returns a non-string value.
    pub fn renderStatusBar(self: *LuaVm, dest: []u8) ?[]const u8 {
        const L = self.L;
        const top = c.lua_gettop(L);
        defer c.lua_settop(L, top);

        _ = c.lua_getglobal(L, "blitz");
        if (c.lua_type(L, -1) != c.LUA_TTABLE) return null;

        _ = c.lua_getfield(L, -1, "status_bar_render");
        if (c.lua_type(L, -1) != c.LUA_TFUNCTION) return null;

        // Drop the blitz table and leave only the callback for pcall.
        c.lua_rotate(L, -2, -1);
        c.lua_pop(L, 1);

        const status = c.lua_pcallk(L, 0, 1, 0, 0, null);
        if (status != 0) {
            self.popError(.action);
            return null;
        }

        if (c.lua_type(L, -1) != c.LUA_TSTRING) return null;
        var len: usize = 0;
        const ptr = c.lua_tolstring(L, -1, &len) orelse return null;
        const capped = @min(len, dest.len);
        @memcpy(dest[0..capped], ptr[0..capped]);
        return dest[0..capped];
    }

    /// Call blitz.hooks.approve hook for `perm`. Caller must hold vm_mu.
    /// Returns the decision, or null for fallback: no hook or a nil return.
    /// A malformed decision table denies with a fixed reason.
    fn runPermissionHook(self: *LuaVm, perm: *r.permissions.Request) ?r.permissions.State {
        const L = self.L;
        const top = c.lua_gettop(L);
        defer c.lua_settop(L, top);

        if (self.permission_hook == c.LUA_NOREF) return null;
        _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, self.permission_hook);
        if (c.lua_type(L, -1) != c.LUA_TFUNCTION) return null;

        pushPermissionPayload(L, perm);

        const status = c.lua_pcallk(L, 1, 1, 0, 0, null);
        if (status != 0) {
            self.popError(.action);
            const msg = std.fmt.allocPrint(std.heap.page_allocator, "permission hook error: {s}", .{self.getLastError()}) catch
                return .{ .message = "permission hook error" };
            return .{ .message = msg };
        }

        if (c.lua_type(L, -1) == c.LUA_TNIL) return null;
        return permissionDecisionFromLua(L, perm.payload) orelse return .{ .message = "permission hook returned an unusable value" };
    }

    /// Convert a BlitzPermissionDecision table on top of the stack. Lua shape:
    /// `{ approved = bool, msg = string?, select = integer? }`. Returns null
    /// only for a malformed table (caller denies with a fixed reason); null is
    /// the fallback-to-TUI signal and must not double as an error path. The
    /// deny reason is page-allocated process-lifetime; nothing frees it,
    /// denials are rare. `select` is 1-based, validated against the live
    /// option count (out of range denies), and ignored on non-ask payloads or
    /// when `approved` is true. Ask payloads resolve fully here: select picks
    /// the option, approval picks the recommended option, denial denies — no
    /// `.message` leaks into the ask tool's answer channel.
    fn permissionDecisionFromLua(L: *c.lua_State, payload: r.permissions.Payload) ?r.permissions.State {
        if (c.lua_type(L, -1) != c.LUA_TTABLE) return null;

        _ = c.lua_getfield(L, -1, "approved");
        if (c.lua_type(L, -1) != c.LUA_TBOOLEAN) {
            c.lua_pop(L, 1);
            return null;
        }
        const approved = c.lua_toboolean(L, -1) != 0;
        c.lua_pop(L, 1);

        if (payload == .ask) {
            _ = c.lua_getfield(L, -1, "select");
            if (c.lua_type(L, -1) == c.LUA_TNUMBER) {
                const one_based = c.lua_tointegerx(L, -1, null);
                c.lua_pop(L, 1);
                if (one_based < 1 or one_based > payload.ask.options.len) return .denied;
                return .{ .choice = @intCast(one_based - 1) };
            }
            c.lua_pop(L, 1);
            if (approved) return r.permissions.recommendedChoice(payload.ask.options);
            return .denied;
        }

        if (approved) return .approved;

        _ = c.lua_getfield(L, -1, "msg");
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -1) != c.LUA_TSTRING) return .denied;
        var len: usize = 0;
        const ptr = c.lua_tolstring(L, -1, &len) orelse return .denied;
        const reason = std.heap.page_allocator.dupe(u8, ptr[0..len]) catch return .denied;
        return .{ .message = reason };
    }

    /// Invoke the permission hook for `perm`. Deny reasons are page-allocated
    /// process-lifetime strings; nothing frees them, denials are rare.
    /// Call on the main thread.
    pub fn permissionHookDecision(self: *LuaVm, perm: *r.permissions.Request) ?r.permissions.State {
        const a = self.app orelse return null;
        self.vm_mu.lockUncancelable(a.io);
        defer self.vm_mu.unlock(a.io);
        return self.runPermissionHook(perm);
    }

    /// Run a cmd.select callback with (choice, index) or (nil, nil) on cancel.
    /// Consumes the registry ref.
    pub fn invokeSelection(self: *LuaVm, io: std.Io, func_ref: c_int, choice: ?[]const u8, index: ?u8) void {
        self.vm_mu.lockUncancelable(io);
        defer self.vm_mu.unlock(io);

        const L = self.L;
        const top = c.lua_gettop(L);
        defer c.lua_settop(L, top);

        _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, func_ref);
        if (c.lua_type(L, -1) != c.LUA_TFUNCTION) {
            c.lua_pop(L, 1);
            c.luaL_unref(L, c.LUA_REGISTRYINDEX, func_ref);
            return;
        }
        if (choice) |text| {
            _ = c.lua_pushlstring(L, text.ptr, text.len);
        } else {
            c.lua_pushnil(L);
        }
        if (index) |i| {
            c.lua_pushinteger(L, i);
        } else {
            c.lua_pushnil(L);
        }
        const status = c.lua_pcallk(L, 2, 0, 0, 0, null);
        if (status != 0) self.popError(.action);
        c.luaL_unref(L, c.LUA_REGISTRYINDEX, func_ref);
    }

    pub fn emitInjectHooks(self: *LuaVm, w: *std.Io.Writer, agent_id: r.AgentId, cancel_token: ?*r.sdk.CancellationToken) void {
        const a = self.app orelse return;
        if (!a.lua_inject_hooks_enabled.load(.acquire)) return;
        self.vm_mu.lockUncancelable(a.io);
        defer self.vm_mu.unlock(a.io);
        if (self.inject_fn == c.LUA_NOREF) return;

        if (cancel_token) |token| {
            self.cancel_token = token;
            c.lua_sethook(self.L, &luaCancellationHook, c.LUA_MASKCOUNT, CANCELLATION_HOOK_INTERVAL);
            defer {
                c.lua_sethook(self.L, null, 0, 0);
                self.cancel_token = null;
            }
        }

        const L = self.L;
        const top = c.lua_gettop(L);
        defer c.lua_settop(L, top);

        _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, self.inject_fn);
        pushAgentId(L, agent_id);
        const status = c.lua_pcallk(L, 1, 1, 0, 0, null);
        if (status != 0) {
            self.popError(.action);
            return;
        }
        if (c.lua_type(L, -1) != c.LUA_TSTRING) return;
        var len: usize = 0;
        const ptr = c.lua_tolstring(L, -1, &len) orelse return;
        w.writeAll(ptr[0..len]) catch {};
    }
};

// ── blitz.* Lua library ─────────────────────────────────────────────

fn registerBlitzLib(L: *c.lua_State) void {
    setLuaTypeGlobal(L, "blitz", Blitz);
}

fn luaPrintToBuffer(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const vm = fromState(state) orelse return 0;
    const top = c.lua_gettop(state);
    var i: c_int = 1;
    while (i <= top) : (i += 1) {
        if (i > 1) if (!appendPrint(vm, " ")) return 0;
        var len: usize = 0;
        const s = c.lua_tolstring(state, i, &len);
        if (s) |ptr| {
            if (!appendPrint(vm, ptr[0..len])) return 0;
        }
    }
    if (!appendPrint(vm, "\n")) return 0;
    return 0;
}

fn appendPrint(vm: *LuaVm, s: []const u8) bool {
    if (s.len > STDOUT_BUF_CAP -| vm.stdout_buf.items.len) return false;
    vm.stdout_buf.appendSlice(vm.luaArena(), s) catch return false;
    return true;
}

pub fn getAppFromRegistry(L: *c.lua_State) ?*app.App {
    _ = c.lua_rawgetp(L, c.LUA_REGISTRYINDEX, @ptrCast(&app_registry_key));
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TLIGHTUSERDATA) return null;
    const ptr = c.lua_touserdata(L, -1) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

/// blitz.bind(vim_key_combo_string, lua func)
/// blitz.add_command("command", lua func)
fn readAnyArg(
    comptime T: type,
    state: *c.lua_State,
    comptime name: []const u8,
    idx: c_int,
) ?T {
    return readAnyValue(T, state, idx) orelse {
        const expected = switch (@typeInfo(T)) {
            .pointer => "string",
            .int, .comptime_int, .float, .comptime_float => "number",
            .bool => "boolean",
            .@"enum" => "number (enum)",
            .@"struct" => "table",
            else => @compileError("readAnyArg: unsupported type " ++ @typeName(T)),
        };
        _ = c.luaL_error(state, name ++ ": arg %d must be a " ++ expected, @as(c_int, idx));
        return null;
    };
}

// ── Trampoline: Zig ToolFn → Lua function call ─────────────────────

// Import provider types used in tool interface
const ToolContext = r.tools.ToolContext;
const ToolCall = r.sdk.ToolCall;
const ToolResult = r.sdk.ToolOutput;
const Tool = r.tools.Tool;

fn failedResult(call: ToolCall, msg: []const u8) ToolResult {
    _ = call;
    return .{ .content = msg, .is_error = true };
}

fn loadToolConfig(vm: *LuaVm, a: *r.app.App) !void {
    if (a.lua_config_dir) |dir| {
        const inject = try std.fmt.allocPrint(vm.luaArena(), "package.path = \"{s}?.lua;\" .. package.path", .{dir});
        try vm.exec(inject);
    }
    if (a.lua_config_abs) |abs| {
        try vm.load(abs);
    }
    if (std.Io.Dir.cwd().statFile(a.io, "blitz.lua", .{})) |_| {
        try vm.load("blitz.lua");
    } else |_| {}
}

fn luaCancellationHook(L: ?*c.lua_State, ar: [*c]c.lua_Debug) callconv(.c) void {
    _ = ar;
    const state = L orelse return;
    const vm = fromState(state) orelse return;
    if (vm.cancel_token) |token| {
        if (token.isCancelled()) {
            _ = c.luaL_error(state, "canceled");
        }
    }
}

/// Run every listener of one event in a fresh sandboxed Lua VM, mirroring
/// the lua tool trampoline: reload the config, call each listener of the
/// event tag in registration order. The event bus owns the calling
/// thread; `await_agent` inside a listener unlocks the sandbox VM mutex
/// while it waits on the agent slot event.
pub fn runEventHook(app_ptr: *r.app.App, event: r.events.AppEvent) void {
    var vm = LuaVm.initTool(app_ptr.gpa) catch {
        hookLog(.err, "hook lua vm init failed", .{});
        return;
    };
    vm.setApp(app_ptr);
    defer vm.deinit();

    vm.cancel_token = &app_ptr.event_bus.hook_cancel;
    c.lua_sethook(vm.L, &luaCancellationHook, c.LUA_MASKCOUNT, CANCELLATION_HOOK_INTERVAL);
    defer {
        c.lua_sethook(vm.L, null, 0, 0);
        vm.cancel_token = null;
    }

    vm.vm_mu.lockUncancelable(app_ptr.io);
    defer vm.vm_mu.unlock(app_ptr.io);

    app_ptr.lua_vm.vm_mu.lockUncancelable(app_ptr.io);
    loadToolConfig(vm, app_ptr) catch {
        app_ptr.lua_vm.vm_mu.unlock(app_ptr.io);
        hookLog(.err, "hook config load failed: {s}", .{vm.getLastError()});
        return;
    };
    app_ptr.lua_vm.vm_mu.unlock(app_ptr.io);

    vm.invokeEventHooks(event);
}

fn luaToolTrampoline(ctx: ToolContext, call: ToolCall) ToolResult {
    const app_ptr: *r.app.App = @ptrCast(@alignCast(ctx.base.app orelse return failedResult(call, "lua tool has no app")));

    var vm = LuaVm.initTool(app_ptr.gpa) catch |err| return failedResult(call, @errorName(err));
    vm.setApp(app_ptr);
    defer vm.deinit();

    vm.cancel_token = ctx.cancellation();
    c.lua_sethook(vm.L, &luaCancellationHook, c.LUA_MASKCOUNT, CANCELLATION_HOOK_INTERVAL);
    defer {
        c.lua_sethook(vm.L, null, 0, 0);
        vm.cancel_token = null;
    }

    // Reading shared app config/factory state must be serialized against
    // hot-reload, which mutates it under lua_vm.vm_mu. The sandbox vm_mu is
    // held for the whole call so a top-level blitz.cmd.await_agent in the
    // config unlocks a locked mutex. Release main before the pcall so the
    // tool body itself still runs in parallel.
    vm.vm_mu.lockUncancelable(ctx.io);
    defer vm.vm_mu.unlock(ctx.io);

    var app_lock_released = false;
    app_ptr.lua_vm.vm_mu.lockUncancelable(ctx.io);
    defer if (!app_lock_released) app_ptr.lua_vm.vm_mu.unlock(ctx.io);

    loadToolConfig(vm, app_ptr) catch {
        const msg = vm.getLastError();
        const owned = r.util.sanitizeUtf8(ctx.alloc, if (msg.len > 0) msg else "failed to load lua tool config") catch "failed to load lua tool config";
        return failedResult(call, owned);
    };

    const entry = findEntry(vm, call.name) orelse return failedResult(call, "tool not found");
    const L = entry.L orelse return failedResult(call, "tool has no lua state");

    _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, entry.func_ref);
    if (c.lua_type(L, -1) != c.LUA_TFUNCTION) {
        c.lua_pop(L, 1);
        return failedResult(call, "tool func is not a function");
    }

    var bridge = CtxBridge{
        .cwd = ctx.base.cwd,
        .tool_ctx = ctx,
        .tool_call = call,
    };
    pushCtxTable(L, &bridge, entry.state_ref);
    pushCallTable(vm.luaArena(), L, call);

    app_lock_released = true;
    app_ptr.lua_vm.vm_mu.unlock(ctx.io);

    const status = c.lua_pcallk(L, 2, 1, 0, 0, null);

    if (status != 0) {
        var err_len: usize = 0;
        const err_ptr = c.lua_tolstring(L, -1, &err_len);
        const err_view = if (err_ptr != null) err_ptr[0..err_len] else "lua error";
        const owned = r.util.sanitizeUtf8(ctx.alloc, err_view) catch "lua error";
        c.lua_pop(L, 1);
        return failedResult(call, owned);
    }

    const stdout = vm.stdout_buf.items;
    if (stdout.len > 0) {
        if (c.lua_type(L, -1) == c.LUA_TTABLE) {
            _ = c.lua_getfield(L, -1, "msg");
            if (c.lua_type(L, -1) != c.LUA_TSTRING) {
                c.lua_pop(L, 1);
                _ = c.lua_pushlstring(L, "", 0);
            }
            _ = c.lua_pushlstring(L, "\n<stdout>\n", 10);
            _ = c.lua_pushlstring(L, stdout.ptr, stdout.len);
            _ = c.lua_pushlstring(L, "\n</stdout>", 10);
            _ = c.lua_concat(L, 4);
            c.lua_setfield(L, -2, "msg");
        }
        vm.stdout_buf.clearRetainingCapacity();
    }

    const ret = interpretReturns(L, call, ctx.alloc);
    c.lua_pop(L, 1);
    return ret;
}

fn interpretReturns(L: *c.lua_State, call: ToolCall, alloc: std.mem.Allocator) ToolResult {
    // Single return at top (-1): expect {msg = string|nil, img = table|nil, exit_loop = bool|nil}.
    if (c.lua_type(L, -1) != c.LUA_TTABLE) return failedResult(call, "lua tool did not return a table");

    _ = c.lua_getfield(L, -1, "exit_loop");
    const exit_loop = c.lua_type(L, -1) == c.LUA_TBOOLEAN and c.lua_toboolean(L, -1) != 0;
    c.lua_pop(L, 1);

    _ = c.lua_getfield(L, -1, "msg");
    var len: usize = 0;
    const content_ptr = c.lua_tolstring(L, -1, &len);
    const content_view = if (content_ptr != null) content_ptr[0..len] else "";
    // Dupe out of Lua memory before pop frees the string.
    // Lua strings are byte strings; sanitize so invalid UTF-8 from user tools never enters history.
    const owned = r.util.sanitizeUtf8(alloc, content_view) catch "oom";
    c.lua_pop(L, 1);

    _ = c.lua_getfield(L, -1, "img");
    var image: ?r.sdk.ToolImage = null;
    if (c.lua_type(L, -1) == c.LUA_TTABLE) {
        _ = c.lua_getfield(L, -1, "media_type");
        var mt_len: usize = 0;
        const mt_ptr = c.lua_tolstring(L, -1, &mt_len);
        const media_type: []const u8 = if (mt_ptr) |p|
            r.util.sanitizeUtf8(alloc, p[0..mt_len]) catch "image/png"
        else
            "image/png";
        c.lua_pop(L, 1);

        _ = c.lua_getfield(L, -1, "data");
        var d_len: usize = 0;
        const d_ptr = c.lua_tolstring(L, -1, &d_len);
        const data: ?[]const u8 = if (d_ptr) |p| r.util.sanitizeUtf8(alloc, p[0..d_len]) catch null else null;
        c.lua_pop(L, 1);

        if (data) |bytes| {
            if (bytes.len > 0) image = .{
                .media_type = media_type,
                .url = std.fmt.allocPrint(alloc, "data:{s};base64,{s}", .{ media_type, bytes }) catch "",
            };
        }
    }
    c.lua_pop(L, 1);

    return .{
        .content = owned,
        .image = image,
        .exit_loop = exit_loop,
    };
}

// ── Push ctx table with methods ─────────────────────────────────────

fn pushCtxTable(L: *c.lua_State, bridge: *CtxBridge, state_ref: c_int) void {
    c.lua_newtable(L);

    setFieldAny(L, -2, "cwd", bridge.cwd);
    setFieldAny(L, -2, "vision", ctxVision(bridge));

    pushAgentId(L, bridge.tool_ctx.base.self_id);
    setFieldPushed(L, -2, "agent_id");

    _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, state_ref);
    setFieldPushed(L, -2, "state");

    inline for (.{
        .{ "set_status", &luaSetStatus },
        .{ "ask", &luaAsk },
        .{ "approve", &luaApprove },
        .{ "plan", &luaPlan },
        .{ "set_child_id", &luaSetChildId },
    }) |binding| {
        setClosureField(L, -2, binding[0], @ptrCast(bridge), binding[1]);
    }
}

fn ctxVision(bridge: *CtxBridge) bool {
    const base = &bridge.tool_ctx.base;
    const app_ptr: *r.app.App = @ptrCast(@alignCast(base.app orelse return false));
    const agent = base.registry.get(base.self_id) orelse return false;
    return app_ptr.context_factory.agentVision(&app_ptr.config, @enumFromInt(agent.type_idx));
}

fn pushCallTable(alloc: Allocator, L: *c.lua_State, call: ToolCall) void {
    c.lua_newtable(L);

    setFieldAny(L, -2, "id", call.id);
    setFieldAny(L, -2, "name", call.name);

    // Parse arguments JSON into Lua table
    if (call.input.len > 0) {
        pushJsonValue(alloc, L, call.input) catch {
            // Fallback: raw string if JSON parse fails
            _ = c.lua_pushlstring(L, call.input.ptr, call.input.len);
        };
    } else {
        c.lua_newtable(L); // empty table for empty arguments
    }
    setFieldPushed(L, -2, "arguments");
}

// ── ctx method C callbacks ──────────────────────────────────────────

fn getBridge(L: *c.lua_State) ?*CtxBridge {
    const ptr = c.lua_touserdata(L, c.lua_upvalueindex(1));
    if (ptr == null) return null;
    return @ptrCast(@alignCast(ptr));
}

fn luaSetStatus(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const bridge = getBridge(state) orelse return 0;

    if (c.lua_type(state, 2) != c.LUA_TSTRING) return 0;

    var len: usize = 0;
    const ptr = c.lua_tolstring(state, 2, &len);
    if (ptr == null) return 0;

    r.tools.setToolStatusPrint(bridge.tool_ctx, bridge.tool_call, "{s}", .{ptr[0..len]});
    return 0;
}

fn luaSetChildId(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const bridge = getBridge(state) orelse return 0;
    const id = readAgentIdArg(state, "ctx.set_child_id", 2);
    r.tools.setToolChild(bridge.tool_ctx, bridge.tool_call, id);
    return 0;
}

/// Block on the perm event, then push (status_int, payload?) onto the Lua
/// stack. payload is the chosen option string for .choice, the user message
/// for .message, or nil otherwise. Returns 2 (status, payload).
fn awaitPermAndPush(state: *c.lua_State, io: std.Io, req: *r.permissions.Request, options: []const []const u8) c_int {
    req.event.wait(io) catch {
        return pushStatusNil(state, REQ_STATUS_DENIED);
    };

    switch (req.state) {
        .pending => return pushStatusNil(state, REQ_STATUS_DENIED),
        .approved => return pushStatusNil(state, REQ_STATUS_APPROVED),
        .denied => return pushStatusNil(state, REQ_STATUS_DENIED),
        .choice => |i| {
            c.lua_pushinteger(state, REQ_STATUS_CHOICE);
            if (i < options.len) {
                _ = c.lua_pushlstring(state, options[i].ptr, options[i].len);
            } else {
                c.lua_pushinteger(state, @intCast(i));
            }
        },
        .message => |m| {
            c.lua_pushinteger(state, REQ_STATUS_MESSAGE);
            _ = c.lua_pushlstring(state, m.ptr, m.len);
        },
    }
    return 2;
}

fn luaAsk(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const bridge = getBridge(state) orelse {
        return pushStatusNil(state, REQ_STATUS_DENIED);
    };

    if (c.lua_type(state, 2) != c.LUA_TSTRING or
        c.lua_type(state, 3) != c.LUA_TSTRING or
        c.lua_type(state, 4) != c.LUA_TTABLE)
    {
        return pushStatusNil(state, REQ_STATUS_DENIED);
    }

    const header = readAnyValue([]const u8, state, 2).?;
    const question = readAnyValue([]const u8, state, 3).?;

    // Extract options from table
    var options = std.ArrayList([]const u8).empty;

    c.lua_pushnil(state); // initial key
    while (c.lua_next(state, 4) != 0) {
        defer _ = c.lua_pop(state, 1);
        if (c.lua_type(state, -1) != c.LUA_TSTRING) continue;
        options.append(bridge.tool_ctx.alloc, readAnyValue([]const u8, state, -1).?) catch break;
    }

    var req = r.permissions.Request{
        .agent_id = bridge.tool_ctx.base.self_id,
        .payload = .{ .ask = .{
            .header = header,
            .question = question,
            .options = options.items,
        } },
    };

    bridge.tool_ctx.base.permissions.send(&req);
    return awaitPermAndPush(state, bridge.tool_ctx.io, &req, options.items);
}

fn luaApprove(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const bridge = getBridge(state) orelse {
        return pushStatusNil(state, REQ_STATUS_DENIED);
    };

    if (c.lua_type(state, 2) != c.LUA_TSTRING) {
        return pushStatusNil(state, REQ_STATUS_DENIED);
    }

    const description = readAnyValue([]const u8, state, 2).?;

    var req = r.permissions.Request{
        .agent_id = bridge.tool_ctx.base.self_id,
        .payload = .{ .call = .{
            .description = description,
        } },
    };

    bridge.tool_ctx.base.permissions.send(&req);
    return awaitPermAndPush(state, bridge.tool_ctx.io, &req, &.{});
}

fn luaPlan(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const bridge = getBridge(state) orelse {
        return pushStatusNil(state, REQ_STATUS_DENIED);
    };

    if (c.lua_type(state, 2) != c.LUA_TSTRING or c.lua_type(state, 3) != c.LUA_TSTRING) {
        return pushStatusNil(state, REQ_STATUS_DENIED);
    }

    const path = readAnyValue([]const u8, state, 2).?;
    const plan_text = readAnyValue([]const u8, state, 3).?;

    var req = r.permissions.Request{
        .agent_id = bridge.tool_ctx.base.self_id,
        .payload = .{ .plan = .{
            .path = path,
            .plan_text = plan_text,
        } },
    };

    bridge.tool_ctx.base.permissions.send(&req);
    return awaitPermAndPush(state, bridge.tool_ctx.io, &req, &.{});
}

/// Push AgentId as the packed integer.
fn pushAgentId(L: *c.lua_State, id: r.AgentId) void {
    c.lua_pushinteger(L, @intCast(id.pack()));
}

/// Push the hook payload table for a permission request. Strings point into
/// registry-owned memory and stay valid for the duration of the hook call.
fn pushPermissionPayload(L: *c.lua_State, perm: *r.permissions.Request) void {
    c.lua_createtable(L, 0, 8);

    c.lua_pushinteger(L, @intCast(perm.agent_id.pack()));
    c.lua_setfield(L, -2, "agent_id");

    if (perm.call_id) |call_id| {
        _ = c.lua_pushlstring(L, call_id.ptr, call_id.len);
        c.lua_setfield(L, -2, "call_id");
    }

    _ = c.lua_pushlstring(L, perm.tool_name.ptr, perm.tool_name.len);
    c.lua_setfield(L, -2, "tool");

    switch (perm.payload) {
        .call => |call| {
            pushTag(L, "call");
            c.lua_setfield(L, -2, "kind");
            _ = c.lua_pushlstring(L, call.description.ptr, call.description.len);
            c.lua_setfield(L, -2, "description");
        },
        .diff => |diff| {
            pushTag(L, "diff");
            c.lua_setfield(L, -2, "kind");
            _ = c.lua_pushlstring(L, diff.path.ptr, diff.path.len);
            c.lua_setfield(L, -2, "path");
        },
        .ask => |ask| {
            pushTag(L, "ask");
            c.lua_setfield(L, -2, "kind");
            _ = c.lua_pushlstring(L, ask.header.ptr, ask.header.len);
            c.lua_setfield(L, -2, "header");
            _ = c.lua_pushlstring(L, ask.question.ptr, ask.question.len);
            c.lua_setfield(L, -2, "question");
            c.lua_createtable(L, @intCast(ask.options.len), 0);
            for (ask.options, 0..) |option, i| {
                _ = c.lua_pushlstring(L, option.ptr, option.len);
                c.lua_rawseti(L, -2, @intCast(i + 1));
            }
            c.lua_setfield(L, -2, "options");
        },
        .plan => |plan| {
            pushTag(L, "plan");
            c.lua_setfield(L, -2, "kind");
            _ = c.lua_pushlstring(L, plan.path.ptr, plan.path.len);
            c.lua_setfield(L, -2, "path");
            _ = c.lua_pushlstring(L, plan.plan_text.ptr, plan.plan_text.len);
            c.lua_setfield(L, -2, "plan");
        },
    }
}

fn pushTag(L: *c.lua_State, tag: []const u8) void {
    _ = c.lua_pushlstring(L, tag.ptr, tag.len);
}

/// Read AgentId from integer at `idx`. Reports a Lua error on shape mismatch.
/// TODO: crash!
fn readAgentIdArg(state: *c.lua_State, comptime fname: []const u8, idx: c_int) r.AgentId {
    if (c.lua_type(state, idx) != c.LUA_TNUMBER) {
        _ = c.luaL_error(state, fname ++ ": agent_id must be an integer");
        return .{ .index = 0, .generation = 0 };
    }

    const packed_value = c.lua_tointegerx(state, idx, null);
    if (packed_value < 0 or packed_value > std.math.maxInt(u32)) {
        _ = c.luaL_error(state, fname ++ ": agent_id out of range");
        return .{ .index = 0, .generation = 0 };
    }

    return r.AgentId.unpack(@intCast(packed_value));
}

// ── JSON ↔ Lua conversion ──────────────────────────────────────────

fn luaToJsonAlloc(alloc: Allocator, L: *c.lua_State, idx: c_int) ![]u8 {
    var w = std.Io.Writer.Allocating.init(alloc);
    errdefer w.deinit();
    try luaToJsonWriter(L, idx, &w.writer, 0);
    try w.writer.flush();
    return try w.toOwnedSlice();
}

fn luaToJsonWriter(L: *c.lua_State, idx: c_int, writer: anytype, depth: usize) !void {
    if (depth > 32) return error.NestingTooDeep;
    const abs_idx = if (idx < 0) c.lua_gettop(L) + idx + 1 else idx;
    switch (c.lua_type(L, abs_idx)) {
        c.LUA_TSTRING => {
            var len: usize = 0;
            const ptr = c.lua_tolstring(L, abs_idx, &len);
            try writeJsonString(writer, ptr[0..len]);
        },
        c.LUA_TNUMBER => {
            if (c.lua_isinteger(L, abs_idx) != 0) {
                const n = c.lua_tointegerx(L, abs_idx, null);
                try writer.print("{d}", .{n});
            } else {
                const n = c.lua_tonumberx(L, abs_idx, null);
                try writer.print("{d}", .{n});
            }
        },
        c.LUA_TBOOLEAN => {
            const v = c.lua_toboolean(L, abs_idx);
            try writer.writeAll(if (v != 0) "true" else "false");
        },
        c.LUA_TNIL => {
            try writer.writeAll("null");
        },
        c.LUA_TTABLE => {
            // Detect array vs object: check if all keys are consecutive integers 1..n
            const is_array = blk: {
                var count: c_longlong = 0;
                c.lua_pushnil(L);
                while (c.lua_next(L, abs_idx) != 0) {
                    c.lua_pop(L, 1); // pop value, keep key
                    if (c.lua_type(L, -1) != c.LUA_TNUMBER or c.lua_isinteger(L, -1) == 0) {
                        c.lua_pop(L, 1); // pop key
                        break :blk false;
                    }
                    count += 1;
                }
                // Check length matches count
                const tbl_len = c.lua_rawlen(L, abs_idx);
                break :blk (count > 0 and tbl_len == @as(usize, @intCast(count)));
            };

            if (is_array) {
                try writer.writeByte('[');
                const len = c.lua_rawlen(L, abs_idx);
                for (1..len + 1) |i| {
                    if (i > 1) try writer.writeByte(',');
                    _ = c.lua_rawgeti(L, abs_idx, @intCast(i));
                    try luaToJsonWriter(L, -1, writer, depth + 1);
                    c.lua_pop(L, 1);
                }
                try writer.writeByte(']');
            } else {
                try writer.writeByte('{');
                var first = true;
                c.lua_pushnil(L);
                while (c.lua_next(L, abs_idx) != 0) {
                    // key at -2, value at -1
                    if (c.lua_type(L, -2) == c.LUA_TSTRING) {
                        if (!first) try writer.writeByte(',');
                        first = false;
                        var klen: usize = 0;
                        const kptr = c.lua_tolstring(L, -2, &klen);
                        try writeJsonString(writer, kptr[0..klen]);
                        try writer.writeByte(':');
                        try luaToJsonWriter(L, -1, writer, depth + 1);
                    }
                    c.lua_pop(L, 1); // pop value, keep key
                }
                try writer.writeByte('}');
            }
        },
        else => {
            try writer.writeAll("null");
        },
    }
}

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(ch),
        }
    }
    try writer.writeByte('"');
}

/// Convert a Lua `args` table into a JSON schema string.
/// Input: `{ url = { type = "string", description = "...", required = true }, ... }`
/// Output: `{"type":"object","properties":{...},"required":[...]}`
fn argsTableToJsonSchema(L: *c.lua_State, args_idx: c_int, buf: []u8) ![]const u8 {
    var stream = std.Io.Writer.fixed(buf);
    const w = &stream;
    const abs = if (args_idx < 0) c.lua_gettop(L) + args_idx + 1 else args_idx;

    try w.writeAll("{\"type\":\"object\",\"properties\":{");

    var required_names: [64]struct { buf: [128]u8 = undefined, len: usize = 0 } = @splat(.{});
    var required_count: usize = 0;
    var first = true;

    c.lua_pushnil(L);
    while (c.lua_next(L, abs) != 0) {
        // key at -2 (arg name), value at -1 (arg def table)
        if (c.lua_type(L, -2) != c.LUA_TSTRING) {
            c.lua_pop(L, 1);
            continue;
        }
        var klen: usize = 0;
        const kptr = c.lua_tolstring(L, -2, &klen);

        if (!first) try w.writeByte(',');
        first = false;

        try writeJsonString(w, kptr[0..klen]);
        try w.writeByte(':');

        if (c.lua_type(L, -1) == c.LUA_TTABLE) {
            try w.writeByte('{');
            var inner_first = true;

            // "type"
            _ = c.lua_getfield(L, -1, "type");
            if (c.lua_type(L, -1) == c.LUA_TSTRING) {
                var tlen: usize = 0;
                const tptr = c.lua_tolstring(L, -1, &tlen);
                try w.writeAll("\"type\":");
                try writeJsonString(w, tptr[0..tlen]);
                inner_first = false;
            }
            c.lua_pop(L, 1);

            // "description"
            _ = c.lua_getfield(L, -1, "description");
            if (c.lua_type(L, -1) == c.LUA_TSTRING) {
                var dlen: usize = 0;
                const dptr = c.lua_tolstring(L, -1, &dlen);
                if (!inner_first) try w.writeByte(',');
                try w.writeAll("\"description\":");
                try writeJsonString(w, dptr[0..dlen]);
            }
            c.lua_pop(L, 1);

            // "required" → collect for top-level array
            _ = c.lua_getfield(L, -1, "required");
            if (c.lua_toboolean(L, -1) != 0 and required_count < required_names.len) {
                @memcpy(required_names[required_count].buf[0..klen], kptr[0..klen]);
                required_names[required_count].len = klen;
                required_count += 1;
            }
            c.lua_pop(L, 1);

            try w.writeByte('}');
        } else {
            try w.writeAll("{}");
        }

        c.lua_pop(L, 1); // pop value, keep key
    }

    try w.writeAll("}");

    if (required_count > 0) {
        try w.writeAll(",\"required\":[");
        for (0..required_count) |i| {
            if (i > 0) try w.writeByte(',');
            try writeJsonString(w, required_names[i].buf[0..required_names[i].len]);
        }
        try w.writeByte(']');
    }

    try w.writeByte('}');
    return buf[0..stream.end];
}

/// Parse JSON string using the Lua arena and push corresponding Lua value.
fn pushJsonValue(alloc: Allocator, L: *c.lua_State, json: []const u8) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
    pushJsonValueRecursive(L, parsed);
}

fn pushJsonValueRecursive(L: *c.lua_State, val: std.json.Value) void {
    switch (val) {
        .null => c.lua_pushnil(L),
        .bool => |b| c.lua_pushboolean(L, @intFromBool(b)),
        .integer => |n| c.lua_pushinteger(L, @intCast(n)),
        .float => |n| c.lua_pushnumber(L, @floatCast(n)),
        .string => |s| _ = c.lua_pushlstring(L, s.ptr, s.len),
        .array => |arr| {
            c.lua_createtable(L, @intCast(arr.items.len), 0);
            for (arr.items, 1..) |item, i| {
                pushJsonValueRecursive(L, item);
                c.lua_rawseti(L, -2, @intCast(i));
            }
        },
        .object => |obj| {
            c.lua_createtable(L, 0, @intCast(obj.count()));
            var it = obj.iterator();
            while (it.next()) |kv| {
                _ = c.lua_pushlstring(L, kv.key_ptr.*.ptr, kv.key_ptr.*.len);
                pushJsonValueRecursive(L, kv.value_ptr.*);
                c.lua_settable(L, -3);
            }
        },
        .number_string => |s| _ = c.lua_pushlstring(L, s.ptr, s.len),
    }
}

test "add_provider binding accepts a stored key and resolves it" {
    var app_state: r.app.App = undefined;
    app_state.io = std.testing.io;
    app_state.gpa = std.testing.allocator;
    app_state.config = .{};

    const vm = try LuaVm.init(std.testing.allocator);
    defer vm.deinit();
    vm.setApp(&app_state);

    try vm.exec("local handle = blitz.add_provider({ type = 'openai', url = 'https://example.test/v1', key_envar = 'WIZARD_TEST_API_KEY', key = 'stored-secret' })\n" ++
        "local model = blitz.add_model({ name = 'test-model', provider = handle, vision = false })\n");

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const provider = app_state.config.getProvider(@enumFromInt(0)) orelse return error.ProviderMissing;
    try std.testing.expectEqualStrings("stored-secret", provider.resolveKey(&env));
    try std.testing.expectEqualStrings("stored-secret", provider.getKey());

    try env.put("WIZARD_TEST_API_KEY", "envar-secret");
    try std.testing.expectEqualStrings("envar-secret", provider.resolveKey(&env));
}

test "pushAny and readAnyValue handle arrays and slices" {
    const state = c.luaL_newstate() orelse return error.LuaInitFailed;
    defer c.lua_close(state);

    const values = [_][]const u8{ "ask", "read" };
    pushAny(state, values);

    const fixed = readAnyValue([2][]const u8, state, -1).?;
    try std.testing.expectEqualStrings("ask", fixed[0]);
    try std.testing.expectEqualStrings("read", fixed[1]);

    const slice = readAnyValueAlloc([]const []const u8, state, "slice", -1, std.testing.allocator).ok;
    defer std.testing.allocator.free(slice);
    try std.testing.expectEqual(@as(usize, 2), slice.len);
    try std.testing.expectEqualStrings("ask", slice[0]);
    try std.testing.expectEqualStrings("read", slice[1]);
}

test "LuaType defines recursive Lua globals" {
    const state = c.luaL_newstate() orelse return error.LuaInitFailed;
    defer c.lua_close(state);

    setLuaTypeGlobal(state, "blitz", Blitz);

    try std.testing.expectEqual(c.LUA_TTABLE, c.lua_getglobal(state, "blitz"));
    try std.testing.expectEqual(c.LUA_TFUNCTION, c.lua_getfield(state, -1, "register_tool"));
    c.lua_pop(state, 1);
    try std.testing.expectEqual(c.LUA_TFUNCTION, c.lua_getfield(state, -1, "write_tempfile"));
    c.lua_pop(state, 1);
    try std.testing.expectEqual(c.LUA_TTABLE, c.lua_getfield(state, -1, "cmd"));
    try std.testing.expectEqual(c.LUA_TFUNCTION, c.lua_getfield(state, -1, "await_agent"));
}

test "base64 Lua API round-trips binary strings" {
    var vm = try LuaVm.init(std.testing.allocator);
    defer vm.deinit();
    vm.bindLuaAllocator();
    vm.installOwner();

    try vm.exec(
        \\local data = string.char(0, 1, 127, 128, 255) .. "image data"
        \\local encoded, encode_ok = blitz.base64.encode(data)
        \\assert(encode_ok and encoded == "AAF/gP9pbWFnZSBkYXRh")
        \\local decoded, decode_ok = blitz.base64.decode(encoded)
        \\assert(decode_ok and decoded == data)
        \\local invalid, invalid_ok = blitz.base64.decode("not base64")
        \\assert(invalid == nil and invalid_ok == false)
    );
}

test "tool VMs resolve their owner and isolate globals" {
    var vm1 = try LuaVm.initTool(std.testing.allocator);
    defer vm1.deinit();
    vm1.bindLuaAllocator();
    vm1.installOwner();

    var vm2 = try LuaVm.initTool(std.testing.allocator);
    defer vm2.deinit();
    vm2.bindLuaAllocator();
    vm2.installOwner();

    try std.testing.expect(fromState(vm1.L) == vm1);
    try std.testing.expect(fromState(vm2.L) == vm2);
    try std.testing.expectEqual(true, try isToolVm(vm1.L));
    try std.testing.expectEqual(true, try isToolVm(vm2.L));

    c.lua_pushinteger(vm1.L, 42);
    c.lua_setglobal(vm1.L, "tool_shared_global");

    _ = c.lua_getglobal(vm2.L, "tool_shared_global");
    try std.testing.expectEqual(c.LUA_TNIL, c.lua_type(vm2.L, -1));
    c.lua_pop(vm2.L, 1);
}

fn readGlobalString(vm: *LuaVm, name: [*:0]const u8) ![]const u8 {
    _ = c.lua_getglobal(vm.L, name);
    defer c.lua_pop(vm.L, 1);
    var len: usize = 0;
    const ptr = c.lua_tolstring(vm.L, -1, &len) orelse return error.NotAString;
    return try std.testing.allocator.dupe(u8, ptr[0..len]);
}

test "hook listeners run sandboxed by registration order" {
    var app_state = permissionTestApp();
    app_state.event_bus = .{};
    defer app_state.event_bus.clear(std.testing.io);

    const vm = try LuaVm.initTool(std.testing.allocator);
    defer vm.deinit();
    vm.setApp(&app_state);

    try vm.exec(
        \\hook_log = ""
        \\blitz.hooks.agent_failed(function(ev)
        \\    hook_log = hook_log .. ev.err .. ":" .. ev.id
        \\end)
        \\blitz.hooks.agent_failed(function(ev)
        \\    hook_log = hook_log .. "|"
        \\end)
        \\blitz.hooks.session_reset(function()
        \\    hook_log = hook_log .. "R"
        \\end)
    );

    try std.testing.expectEqual(@as(usize, 3), vm.hook_entries.items.len);
    try std.testing.expectEqual(r.events.AppEventTag.agent_failed, vm.hook_entries.items[1].tag);

    const failed_id = r.AgentId{ .index = 2, .generation = 7 };
    vm.invokeEventHooks(.{ .agent_failed = .{ .id = failed_id, .err = "ProviderError" } });
    vm.invokeEventHooks(.session_reset);

    const log_text = try readGlobalString(vm, "hook_log");
    defer std.testing.allocator.free(log_text);
    var expected_buf: [64]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "ProviderError:{d}|R", .{failed_id.pack()});
    try std.testing.expectEqualStrings(expected, log_text);

    const main_vm = try LuaVm.init(std.testing.allocator);
    defer main_vm.deinit();
    main_vm.setApp(&app_state);
    try main_vm.exec(
        \\blitz.hooks.agent_failed(function() end)
        \\blitz.hooks.agent_complete(function() end)
    );
    try std.testing.expect(app_state.event_bus.active.contains(.agent_failed));
    try std.testing.expect(app_state.event_bus.active.contains(.agent_complete));
    try std.testing.expect(!app_state.event_bus.active.contains(.session_reset));
}

test "state values round-trip through the Lua stack" {
    const L = c.luaL_newstate() orelse return error.LuaInitFailed;
    defer c.lua_close(L);

    c.lua_createtable(L, 3, 2);
    c.lua_pushinteger(L, 1);
    c.lua_rawseti(L, -2, 1);
    c.lua_pushinteger(L, 2);
    c.lua_rawseti(L, -2, 2);
    c.lua_pushnumber(L, 3.5);
    c.lua_rawseti(L, -2, 3);
    c.lua_pushboolean(L, 1);
    c.lua_setfield(L, -2, "flag");
    _ = c.lua_pushliteral(L, "hi");
    c.lua_setfield(L, -2, "name");

    const value = try stateValueFromLua(std.testing.allocator, L, -1, 1);
    defer lua_state.freeValue(std.testing.allocator, value);

    try std.testing.expectEqual(@as(usize, 3), value.table.array.items.len);
    try std.testing.expectEqual(@as(i64, 1), value.table.array.items[0].integer);
    try std.testing.expectEqual(@as(i64, 2), value.table.array.items[1].integer);
    try std.testing.expectEqual(@as(f64, 3.5), value.table.array.items[2].number);
    try std.testing.expect(value.table.map.get("flag").?.boolean);
    try std.testing.expectEqualStrings("hi", value.table.map.get("name").?.string);

    c.lua_pop(L, 1);
    pushStateValue(L, value);
    const round = try stateValueFromLua(std.testing.allocator, L, -1, 1);
    defer lua_state.freeValue(std.testing.allocator, round);
    try std.testing.expectEqual(@as(i64, 1), round.table.array.items[0].integer);
    try std.testing.expectEqual(@as(f64, 3.5), round.table.array.items[2].number);
    try std.testing.expectEqualStrings("hi", round.table.map.get("name").?.string);
}

test "state conversion rejects cyclic tables" {
    const L = c.luaL_newstate() orelse return error.LuaInitFailed;
    defer c.lua_close(L);

    c.lua_createtable(L, 0, 1);
    c.lua_pushvalue(L, -1);
    c.lua_setfield(L, -2, "self");

    try std.testing.expectError(error.UnsupportedValue, stateValueFromLua(std.testing.allocator, L, -1, 1));
}

test "state conversion rejects non-integer numeric keys" {
    const L = c.luaL_newstate() orelse return error.LuaInitFailed;
    defer c.lua_close(L);

    c.lua_createtable(L, 1, 0);
    _ = c.lua_pushliteral(L, "a");
    c.lua_rawseti(L, -2, 1);
    c.lua_pushnumber(L, 1.5);
    _ = c.lua_pushliteral(L, "b");
    c.lua_rawset(L, -3);

    try std.testing.expectError(error.UnsupportedValue, stateValueFromLua(std.testing.allocator, L, -1, 1));
}

fn permissionTestApp() r.app.App {
    var app_state: r.app.App = undefined;
    app_state.io = std.testing.io;
    app_state.gpa = std.testing.allocator;
    app_state.config = .{};
    return app_state;
}

test "permission hook approve deny and nil fallback" {
    var app_state = permissionTestApp();
    const vm = try LuaVm.init(std.testing.allocator);
    defer vm.deinit();
    vm.setApp(&app_state);

    try vm.exec(
        \\blitz.hooks.approve(function(p)
        \\  if p.kind == "diff" then return { approved = true } end
        \\  if p.tool == "bash" then return { approved = false, msg = "no shell for you" } end
        \\  return nil
        \\end)
    );

    var diff_req = r.permissions.Request{
        .agent_id = .{ .index = 1, .generation = 2 },
        .call_id = "call_9",
        .tool_name = "write",
        .payload = .{ .diff = .{ .path = "a.txt", .before = null, .after = "x" } },
    };
    try std.testing.expectEqual(r.permissions.State.approved, vm.permissionHookDecision(&diff_req).?);

    var call_req = r.permissions.Request{
        .agent_id = .{ .index = 1, .generation = 2 },
        .tool_name = "bash",
        .payload = .{ .call = .{ .description = "run" } },
    };
    const denied = vm.permissionHookDecision(&call_req).?;
    try std.testing.expectEqualStrings("no shell for you", denied.message);

    var other_req = r.permissions.Request{
        .agent_id = .{ .index = 1, .generation = 2 },
        .tool_name = "grep",
        .payload = .{ .call = .{ .description = "search" } },
    };
    try std.testing.expect(vm.permissionHookDecision(&other_req) == null);
}

test "permission hook sees ask options and numeric choice" {
    var app_state = permissionTestApp();
    const vm = try LuaVm.init(std.testing.allocator);
    defer vm.deinit();
    vm.setApp(&app_state);

    try vm.exec(
        \\blitz.hooks.approve(function(p)
        \\  assert(p.kind == "ask")
        \\  assert(p.header == "Pick")
        \\  assert(p.options[2] == "beta")
        \\  return { approved = false, select = 1 }
        \\end)
    );

    const options = [_][]const u8{ "alpha", "beta" };
    var ask_req = r.permissions.Request{
        .agent_id = .{ .index = 0, .generation = 0 },
        .tool_name = "ask",
        .payload = .{ .ask = .{ .header = "Pick", .question = "?", .options = &options } },
    };
    const decision = vm.permissionHookDecision(&ask_req).?;
    try std.testing.expectEqual(@as(u8, 0), decision.choice);

    try vm.exec(
        \\blitz.hooks.approve(function(p)
        \\  return { approved = false, select = 9 }
        \\end)
    );
    try std.testing.expectEqual(r.permissions.State.denied, vm.permissionHookDecision(&ask_req).?);

    try vm.exec(
        \\blitz.hooks.approve(function(p)
        \\  return { approved = true, select = 2 }
        \\end)
    );
    try std.testing.expectEqual(@as(u8, 1), vm.permissionHookDecision(&ask_req).?.choice);

    try vm.exec(
        \\blitz.hooks.approve(function(p)
        \\  return { approved = true }
        \\end)
    );
    const approved_ask = vm.permissionHookDecision(&ask_req).?;
    try std.testing.expectEqual(@as(u8, 0), approved_ask.choice);

    try vm.exec(
        \\blitz.hooks.approve(function(p)
        \\  return { approved = false, msg = "no" }
        \\end)
    );
    try std.testing.expectEqual(r.permissions.State.denied, vm.permissionHookDecision(&ask_req).?);

    var diff_req = r.permissions.Request{
        .agent_id = .{ .index = 0, .generation = 0 },
        .tool_name = "write",
        .payload = .{ .diff = .{ .path = "a.txt", .before = null, .after = "x" } },
    };
    const diff_decision = vm.permissionHookDecision(&diff_req).?;
    try std.testing.expectEqualStrings("no", diff_decision.message);

    try vm.exec(
        \\blitz.hooks.approve(function(p)
        \\  return { approved = true }
        \\end)
    );
    const diff_decision2 = vm.permissionHookDecision(&diff_req).?;
    try std.testing.expectEqual(r.permissions.State.approved, diff_decision2);
}

test "permission hook error fails closed" {
    var app_state = permissionTestApp();
    const vm = try LuaVm.init(std.testing.allocator);
    defer vm.deinit();
    vm.setApp(&app_state);

    try vm.exec("blitz.hooks.approve(function(p) error('boom') end)");

    var req = r.permissions.Request{
        .agent_id = .{ .index = 0, .generation = 0 },
        .tool_name = "bash",
        .payload = .{ .call = .{ .description = "run" } },
    };
    const decision = vm.permissionHookDecision(&req).?;
    try std.testing.expect(decision == .message);
    try std.testing.expect(std.mem.indexOf(u8, decision.message, "boom") != null);
}

test "permission hook malformed table denies" {
    var app_state = permissionTestApp();
    const vm = try LuaVm.init(std.testing.allocator);
    defer vm.deinit();
    vm.setApp(&app_state);

    try vm.exec("blitz.hooks.approve(function(p) return { approved = 'yes' } end)");

    var req = r.permissions.Request{
        .agent_id = .{ .index = 0, .generation = 0 },
        .tool_name = "bash",
        .payload = .{ .call = .{ .description = "run" } },
    };
    const non_bool = vm.permissionHookDecision(&req).?;
    try std.testing.expectEqualStrings("permission hook returned an unusable value", non_bool.message);

    try vm.exec("blitz.hooks.approve(function(p) return 42 end)");
    const non_table = vm.permissionHookDecision(&req).?;
    try std.testing.expectEqualStrings("permission hook returned an unusable value", non_table.message);

    try vm.exec("blitz.hooks.approve(function(p) return { approved = false } end)");
    const no_reason = vm.permissionHookDecision(&req).?;
    try std.testing.expectEqual(r.permissions.State.denied, no_reason);
}

test "permission hook clear and no handler fall back" {
    var app_state = permissionTestApp();
    const vm = try LuaVm.init(std.testing.allocator);
    defer vm.deinit();
    vm.setApp(&app_state);

    var req = r.permissions.Request{
        .agent_id = .{ .index = 0, .generation = 0 },
        .tool_name = "bash",
        .payload = .{ .call = .{ .description = "run" } },
    };
    try std.testing.expect(vm.permissionHookDecision(&req) == null);

    try vm.exec(
        \\blitz.hooks.approve(function(p) return { approved = true } end)
        \\blitz.hooks.inject(function(agent_id) return nil end)
        \\blitz.hooks.clear()
    );
    try std.testing.expect(vm.permissionHookDecision(&req) == null);
    try std.testing.expectEqual(c.LUA_NOREF, vm.inject_fn);
}
