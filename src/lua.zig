const std = @import("std");
const app = @import("app.zig");
const c = @import("c");
const Allocator = std.mem.Allocator;
const tui = @import("tui/root.zig");
const keys = @import("keys.zig");
const tl = @import("tools/root.zig");
const log = std.log.scoped(.lua);
const r = @import("root.zig");
const lua = @This();

pub const RET_FAILED: c_int = 1;
pub const RET_OK: c_int = 2;
pub const RET_ERR: c_int = 3;
pub const RET_EXIT_LOOP: c_int = 4;
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
                        const a = getAppFromRegistry(state) orelse {
                            _ = c.luaL_error(state, "failed to get app");
                            return 0;
                        };

                        switch (readAnyValueAlloc(any, state, name, @as(c_int, offset), a.lua_vm.arena_state.allocator())) {
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
    nil,
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
    userdata,
    thread,
    any,

    pub const Value = union(enum) {
        integer: c.lua_Integer,
        number: c.lua_Number,
        boolean: bool,
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
const AgentIdOrNilDef = LuaType{ .raw = "BlitzAgentId|nil" };
const StringOrNilDef = LuaType{ .raw = "string|nil" };
const JsonEncodeRet = LuaType{ .raw = "string|nil, boolean" };
const JsonDecodeRet = LuaType{ .raw = "any, boolean" };

const StringListDef = LuaType{ .raw = "string[]" };
const StatusDef = LuaType{ .table_def = .{ .name = "BlitzStatus", .fields = &.{
    .{ .name = "status", .ty = LuaType.integer },
    .{ .name = "msg", .ty = LuaType.string, .optional = true },
} } };
const AgentIdDef = LuaType{ .table_def = .{ .name = "BlitzAgentId", .fields = &.{
    .{ .name = "index", .ty = LuaType.integer },
    .{ .name = "generation", .ty = LuaType.integer },
} } };
const CtxDef = LuaType{ .table_def = .{ .name = "BlitzCtx", .fields = &.{
    .{ .name = "cwd", .ty = LuaType.string },
    .{ .name = "agent_id", .ty = AgentIdDef },
    .{ .name = "state", .ty = LuaType.table },
    .{ .name = "set_status", .ty = LuaType{ .raw = "fun(msg: string)" } },
    .{ .name = "set_child_id", .ty = LuaType{ .raw = "fun(agent_id: BlitzAgentId)" } },
    .{ .name = "approve", .ty = LuaType{ .raw = "fun(tool_name: string, tool_arguments: string): integer, string|nil" } },
    .{ .name = "plan", .ty = LuaType{ .raw = "fun(path: string, plan_text: string): integer, string|nil" } },
    .{ .name = "ask", .ty = LuaType{ .raw = "fun(header: string, question: string, options: string[]): integer, string|nil" } },
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
} } };
const ThinkingDef = LuaType{ .table_def = .{ .name = "BlitzThinking", .fields = &.{
    .{ .name = "type", .ty = LuaType.string },
    .{ .name = "budget_tokens", .ty = LuaType.integer, .optional = true },
} } };
const ProviderDef = LuaType{ .table_def = .{ .name = "BlitzProviderDef", .fields = &.{
    .{ .name = "type", .ty = LuaType.string, .desc = "'openai' | 'response' | 'anthropic' | 'ollama'" },
    .{ .name = "url", .ty = LuaType.string, .desc = "the endpoint url" },
    .{ .name = "key_envar", .ty = LuaType.string, .desc = "the ENVAR holding the api key (not the key itself!)" },
    .{ .name = "effort", .ty = LuaType.string, .optional = true },
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
} } };

const ThemeDef = LuaType{ .table_def = .{ .name = "BlitzTheme", .fields = &.{
    .{ .name = "bg", .ty = LuaType.string, .optional = true },
    .{ .name = "overlay_dark", .ty = LuaType.string, .optional = true },
    .{ .name = "overlay", .ty = LuaType.string, .optional = true },
    .{ .name = "muted", .ty = LuaType.string, .optional = true },
    .{ .name = "text", .ty = LuaType.string, .optional = true },
    .{ .name = "ok", .ty = LuaType.string, .optional = true },
    .{ .name = "info", .ty = LuaType.string, .optional = true },
    .{ .name = "warn", .ty = LuaType.string, .optional = true },
    .{ .name = "err", .ty = LuaType.string, .optional = true },
    .{ .name = "diff_surface", .ty = LuaType.string, .optional = true },
    .{ .name = "diff_add", .ty = LuaType.string, .optional = true },
    .{ .name = "diff_remove", .ty = LuaType.string, .optional = true },
} } };

const ThemeArg = struct {
    bg: ?[]const u8 = null,
    overlay_dark: ?[]const u8 = null,
    overlay: ?[]const u8 = null,
    muted: ?[]const u8 = null,
    text: ?[]const u8 = null,
    ok: ?[]const u8 = null,
    info: ?[]const u8 = null,
    warn: ?[]const u8 = null,
    err: ?[]const u8 = null,
    diff_surface: ?[]const u8 = null,
    diff_add: ?[]const u8 = null,
    diff_remove: ?[]const u8 = null,
};

fn applyTheme(a: *r.app.App, theme: ThemeArg) !void {
    const C = r.tui.Color;
    const t = &a.theme;
    if (theme.bg) |v| t.bg = try C.parseStrHex(v);
    if (theme.overlay_dark) |v| t.overlay_dark = try C.parseStrHex(v);
    if (theme.overlay) |v| t.overlay = try C.parseStrHex(v);
    if (theme.muted) |v| t.muted = try C.parseStrHex(v);
    if (theme.text) |v| t.text = try C.parseStrHex(v);
    if (theme.ok) |v| t.ok = try C.parseStrHex(v);
    if (theme.info) |v| t.info = try C.parseStrHex(v);
    if (theme.warn) |v| t.warn = try C.parseStrHex(v);
    if (theme.err) |v| t.err = try C.parseStrHex(v);
    if (theme.diff_surface) |v| t.diff_surface = try C.parseStrHex(v);
    if (theme.diff_add) |v| t.diff_add = try C.parseStrHex(v);
    if (theme.diff_remove) |v| t.diff_remove = try C.parseStrHex(v);
    a.dirty = true;
}

const ToolArgsDef = LuaType{ .raw_refs = .{ .text = "table<string, BlitzArgDef>", .refs = &.{ToolArgDef} } };
const ToolDef = LuaType{ .table_def = .{ .name = "ToolDef", .fields = &.{
    .{ .name = "name", .ty = LuaType.string },
    .{ .name = "description", .ty = LuaType.string },
    .{ .name = "schema", .ty = LuaType.string, .optional = true },
    .{ .name = "args", .ty = ToolArgsDef, .optional = true },
    .{ .name = "func", .ty = LuaType{ .raw_refs = .{
        .text = "fun(ctx: BlitzCtx, call: BlitzCall): BlitzStatus",
        .refs = &.{ CtxDef, CallDef, StatusDef },
    } } },
} } };
const AgentDef = LuaType{ .table_def = .{ .name = "BlitzAgentDef", .fields = &.{
    .{ .name = "name", .ty = LuaType.string },
    .{ .name = "description", .ty = LuaType.string },
    .{ .name = "prompt", .ty = LuaType.string },
    .{ .name = "tools", .ty = StringListDef },
    .{ .name = "model", .ty = LuaType.string },
    .{ .name = "effort", .ty = LuaType.string },
    .{ .name = "provider", .ty = LuaType.integer },
    .{ .name = "in_agent_tool", .ty = LuaType.boolean, .optional = true },
} } };
const AppFlagsDef = LuaType{ .table_def = .{ .name = "BlitzAppFlags", .fields = &.{
    .{ .name = "show_thinking", .ty = LuaType.boolean, .optional = true },
    .{ .name = "debug_log", .ty = LuaType.boolean, .optional = true },
    .{ .name = "ssh_agent_control", .ty = LuaType.boolean, .optional = true },
    .{ .name = "skip_permissions", .ty = LuaType.boolean, .optional = true },
} } };
const McpServerDef = LuaType{ .table_def = .{ .name = "BlitzMcpServerDef", .fields = &.{
    .{ .name = "name", .ty = LuaType.string },
    .{ .name = "command", .ty = LuaType.string },
    .{ .name = "transport", .ty = LuaType.string, .optional = true },
    .{ .name = "args", .ty = StringListDef, .optional = true },
    .{ .name = "tools_prefix", .ty = LuaType.string, .optional = true },
} } };
const LspServerDef = LuaType{ .table_def = .{ .name = "BlitzLspServerDef", .fields = &.{
    .{ .name = "name", .ty = LuaType.string },
    .{ .name = "command", .ty = LuaType.string },
    .{ .name = "args", .ty = StringListDef, .optional = true },
    .{ .name = "root", .ty = LuaType.string, .optional = true },
    .{ .name = "language_id", .ty = LuaType.string, .optional = true },
} } };
const SpawnAgentArgsDef = LuaType{ .table_def = .{ .name = "BlitzSpawnArgs", .fields = &.{
    .{ .name = "parent_id", .ty = AgentIdDef, .optional = true },
    .{ .name = "prompt", .ty = LuaType.string },
    .{ .name = "agent_type", .ty = LuaType.integer, .optional = true },
    .{ .name = "fork", .ty = LuaType.boolean, .optional = true },
} } };
pub const Blitz = LuaType{
    .table_def = .{
        .name = "Blitz",
        .fields = &.{
            .{ .name = "mcp", .ty = BlitzMcp },
            .{ .name = "lsp", .ty = BlitzLsp },
            .{ .name = "json", .ty = BlitzJson },
            .{ .name = "queue", .ty = BlitzQueue },
            .{ .name = "tools", .ty = BlitzToolDef },
            .{ .name = "events", .ty = BlitzEventDef },
            .{ .name = "RET_FAILED", .ty = LuaType.integer, .value = .{ .integer = lua.RET_FAILED } },
            .{ .name = "RET_OK", .ty = LuaType.integer, .value = .{ .integer = lua.RET_OK } },
            .{ .name = "RET_ERR", .ty = LuaType.integer, .value = .{ .integer = lua.RET_ERR } },
            .{ .name = "RET_EXIT_LOOP", .ty = LuaType.integer, .value = .{ .integer = lua.RET_EXIT_LOOP } },
            .{ .name = "AGENT_GENERAL", .ty = LuaType.integer, .value = .{ .integer = 0 } },
            .{ .name = "MODE_EXEC", .ty = LuaType.integer, .value = .{ .integer = 0 } },
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
                                const vm = &a.lua_vm;
                                if (vm.tool_entries.items.len >= MAX_LUA_TOOLS) return error.TooManyTools;

                                var entry: LuaToolEntry = .{};

                                entry.name_len = getStringField(state, def.idx, "name", &entry.name) orelse return error.InvalidToolName;
                                entry.desc_len = getStringField(state, def.idx, "description", &entry.description) orelse return error.InvalidToolDescription;

                                // schema (string) OR args (table) — at least one required
                                if (getStringField(state, def.idx, "schema", &entry.schema)) |len| {
                                    entry.schema_len = len;
                                } else {
                                    _ = c.lua_getfield(state, def.idx, "args");
                                    defer c.lua_pop(state, 1);
                                    if (c.lua_type(state, -1) != c.LUA_TTABLE) return error.SchemaOrArgsRequired;
                                    const json = try argsTableToJsonSchema(state, -1, &entry.schema);
                                    entry.schema_len = json.len;
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
                            fn lua_fn(a: *r.app.App, agent_type_id: u32, tool_name: []const u8) !void {
                                try a.cmd_queue.append(a.swarm.pool.io, .{ .add_tool = .{
                                    .agent_type = @enumFromInt(agent_type_id),
                                    .tool_name = tool_name,
                                } });
                            }
                        }).lua_fn, "add_tool"),
                    },
                },
            },
            .{ .name = "get_main_agent", .desc = "Return the main agent, if a session is running.", .ty = LuaType{ .function = .{ .ret = &AgentIdOrNilDef, .fn_ptr = LuaFnBind((struct {
                fn lua_fn(a: *r.app.App) !?r.prv.Swarm.AgentId {
                    return a.main_agent_id;
                }
            }).lua_fn, "get_main_agent") } } },
            .{
                .name = "ok",
                .desc = "Return success with content.",
                .ty = LuaType{ .function = .{
                    .args = &.{.{ .name = "content", .ty = LuaType.string, .optional = true }},
                    .ret = &StatusDef,
                    .fn_ptr = LuaFnBind((struct {
                        const Ret = struct { status: c_int, msg: []const u8 };
                        fn lua_fn(content: ?[]const u8) !Ret {
                            return .{ .status = RET_OK, .msg = content orelse "" };
                        }
                    }).lua_fn, "ok"),
                } },
            },
            .{
                .name = "err",
                .desc = "Return error with message.",
                .ty = LuaType{ .function = .{
                    .args = &.{.{ .name = "message", .ty = LuaType.string, .optional = true }},
                    .ret = &StatusDef,
                    .fn_ptr = LuaFnBind((struct {
                        const Ret = struct { status: c_int, msg: []const u8 };
                        fn lua_fn(message: ?[]const u8) !Ret {
                            return .{ .status = RET_ERR, .msg = message orelse "error" };
                        }
                    }).lua_fn, "err"),
                } },
            },
            .{
                .name = "exit_loop",
                .desc = "Exit the agent loop with a message.",
                .ty = LuaType{ .function = .{
                    .args = &.{.{ .name = "content", .ty = LuaType.string, .optional = true }},
                    .ret = &StatusDef,
                    .fn_ptr = LuaFnBind((struct {
                        const Ret = struct { status: c_int, msg: []const u8 };
                        fn lua_fn(content: ?[]const u8) !Ret {
                            return .{ .status = RET_EXIT_LOOP, .msg = content orelse "" };
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
                                key_envar: []const u8,
                                effort: ?[]const u8 = null,
                                temperature: ?f32 = null,
                                max_tokens: ?u32 = null,
                                max_completion_tokens: ?u32 = null,
                                max_output_tokens: ?u32 = null,
                                top_p: ?f32 = null,
                                top_k: ?u32 = null,
                                frequency_penalty: ?f32 = null,
                                presence_penalty: ?f32 = null,
                                enable_thinking: ?bool = true,
                                thinking: ?r.prv.adapter.Thinking = null,
                            };

                            fn lua_fn(a: *r.app.App, args: Arg) !r.prv.config.ProviderHandle {
                                const slot = a.config.reserveProvider(args.url, args.key_envar) orelse return error.MaxProviderReached;

                                if (args.effort) |eff| {
                                    slot.reasoning_effort = prv.config.parseReasoningEffort(eff) orelse return error.UnknownEffortValue;
                                }

                                const ptype: prv.adapter.Provider = blk: {
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
                                model: []const u8,
                                effort: ?[]const u8,
                                provider: u32,
                                in_agent_tool: ?bool,
                            };

                            fn lua_fn(a: *r.app.App, def: Args) !u32 {
                                const effort = if (def.effort) |eff|
                                    r.prv.config.parseReasoningEffort(eff) orelse return error.UnknownEffortType
                                else
                                    .medium;

                                const agent_type = try a.context_factory.addAgent(.{
                                    .name = def.name,
                                    .description = def.description,
                                    .prompt = def.prompt,
                                    .in_agent_tool = def.in_agent_tool orelse true,
                                    .tools = def.tools,
                                    .model = .{
                                        .name = def.model,
                                        .effort = effort,
                                        .provider = @enumFromInt(def.provider),
                                    },
                                });

                                return @intFromEnum(agent_type);
                            }
                        }).lua_fn, "add_agent"),
                    },
                },
            },
            .{
                .name = "set_model",
                .desc = "Set the default model.",
                .ty = LuaType{ .function = .{
                    .args = &.{
                        .{ .name = "model", .ty = LuaType.string },
                        .{ .name = "handle", .ty = LuaType.integer },
                    },
                    .fn_ptr = LuaFnBind((struct {
                        fn lua_fn(a: *r.app.App, model: []const u8, handle: u32) !void {
                            if (!a.config.setModel(model, @enumFromInt(handle))) {
                                return error.ModelStringTooLong;
                            }
                        }
                    }).lua_fn, "set_model"),
                } },
            },
            .{
                .name = "set_model_agent",
                .desc = "Set the model config for a specific agent.",
                .ty = LuaType{
                    .function = .{
                        .args = &.{
                            .{ .name = "agent_type", .ty = LuaType.integer },
                            .{ .name = "model", .ty = LuaType.string },
                            .{ .name = "effort", .ty = LuaType.string },
                            .{ .name = "handle", .ty = LuaType.integer },
                        },
                        .fn_ptr = LuaFnBind((struct {
                            fn lua_fn(a: *r.app.App, agent_type_id: u32, model: []const u8, effort: []const u8, handle: u32) !void {
                                const agent_type: r.ContextFactory.AgentType = @enumFromInt(agent_type_id);
                                const eff = r.prv.config.parseReasoningEffort(effort) orelse return error.UnknownEffort;
                                try a.context_factory.setAgentModel(agent_type, model, eff, @enumFromInt(handle));
                            }
                        }).lua_fn, "set_model_agent"),
                    },
                },
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
                            };

                            fn lua_fn(a: *r.app.App) !Ret {
                                const useage = a.swarm.usage();
                                return .{
                                    .input = useage.input_tokens,
                                    .output = useage.output_tokens,
                                    .cache = useage.cached_tokens,
                                    .cache_creation = useage.cache_creation_tokens,
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
                            fn lua_fn(a: *r.app.App, limit: u32) !void {
                                a.default_context_limit = limit;
                                for (&a.swarm.slots) |*slot| {
                                    const slot_state = slot.state.load(.acquire);
                                    if (slot_state == .free or slot_state == .reserved) continue;
                                    slot.agent.context_limit = limit;
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
                ,
                .ty = LuaType{
                    .function = .{
                        .args = &.{ .{ .name = "key", .ty = LuaType.string }, .{ .name = "func", .ty = LuaType{ .function = .{} } } },
                        .fn_ptr = LuaFnBind((struct {
                            fn lua_fn(a: *r.app.App, state: *c.lua_State, key: []const u8, func: LuaFnRef) !void {
                                const parsed = keys.parseKeyString(key) orelse return error.InvalidKeyCombo;
                                a.lua_vm.bind_entries.appendAssumeCapacity(.{
                                    .key = parsed,
                                    .func_ref = func.idx,
                                    .L = state,
                                });
                            }
                        }).lua_fn, "bind"),
                    },
                },
            },
            .{
                .name = "html_to_markdown",
                .desc = "Convert HTML to markdown using the built-in parser.",
                .ty = LuaType{ .function = .{
                    .args = &.{.{ .name = "html", .ty = LuaType.string }},
                    .ret = &LuaString,
                    .fn_ptr = LuaFnBind((struct {
                        fn lua_fn(a: *r.app.App, html: []const u8) ![]const u8 {
                            return tl.parse.htmlToMarkdown(a.lua_vm.luaArena(), html);
                        }
                    }).lua_fn, "html_to_markdown"),
                } },
            },
            .{
                .name = "add_command",
                .desc =
                \\Bind a colon command to a Lua callback.
                \\Example: blitz.add_command(":help", function(args) end)
                ,
                .ty = LuaType{ .function = .{
                    .args = &.{ .{ .name = "command", .ty = LuaType.string }, .{ .name = "func", .ty = LuaType{ .function = .{} } } },
                    .fn_ptr = LuaFnBind((struct {
                        fn lua_fn(a: *r.app.App, state: *c.lua_State, name: []const u8, func: LuaFnRef) !void {
                            const vm = &a.lua_vm;
                            if (vm.command_entries.items.len >= MAX_LUA_COMMANDS) return error.TooManyCommands;
                            if (name.len == 0 or (name[0] != ':' and name[0] != '/')) return error.InvalidCommandPrefix;
                            if (std.mem.indexOfScalar(u8, name, ' ') != null) return error.InvalidCommandName;
                            if (name.len > 128) return error.CommandNameTooLong;

                            var entry = LuaCommandEntry{
                                .name_len = name.len,
                                .func_ref = func.idx,
                                .L = state,
                            };
                            @memcpy(entry.name[0..name.len], name);
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
                        fn lua_fn(a: *r.app.App, agent_type: r.ContextFactory.AgentType, tool_names: [][]const u8) !void {
                            try a.context_factory.setAgentTools(agent_type, tool_names);
                        }
                    }).lua_fn, "set_agent_tools"),
                } },
            },
            .{
                .name = "set_prompt",
                .desc = "Override the system prompt for a given agent type.",
                .ty = LuaType{ .function = .{
                    .args = &.{ .{ .name = "agent_type", .ty = LuaType.integer }, .{ .name = "prompt", .ty = LuaType.string } },
                    .fn_ptr = LuaFnBind((struct {
                        fn lua_fn(a: *r.app.App, agent_type: r.ContextFactory.AgentType, prompt: []const u8) !void {
                            try a.context_factory.setAgentPrompt(agent_type, prompt);
                        }
                    }).lua_fn, "set_prompt"),
                } },
            },
            .{
                .name = "set_mode_prompt",
                .desc = "Override the mode reminder prompt (full variant).",
                .ty = LuaType{ .function = .{
                    .args = &.{ .{ .name = "mode", .ty = LuaType.integer }, .{ .name = "prompt", .ty = LuaType.string } },
                    .fn_ptr = LuaFnBind((struct {
                        fn lua_fn(a: *r.app.App, mode: r.ContextFactory.Mode, prompt: []const u8) !void {
                            try a.context_factory.setModePrompt(mode, prompt);
                        }
                    }).lua_fn, "set_mode_prompt"),
                } },
            },
            .{
                .name = "set_mode_prompt_sparse",
                .desc = "Override the sparse mode reminder prompt (subsequent turns).",
                .ty = LuaType{ .function = .{
                    .args = &.{ .{ .name = "mode", .ty = LuaType.integer }, .{ .name = "prompt", .ty = LuaType.string } },
                    .fn_ptr = LuaFnBind((struct {
                        fn lua_fn(a: *r.app.App, mode: r.ContextFactory.Mode, prompt: []const u8) !void {
                            try a.context_factory.setSparseModePrompt(mode, prompt);
                        }
                    }).lua_fn, "set_mode_prompt_sparse"),
                } },
            },
            .{
                .name = "set_mode_name",
                .desc = "Override the display name shown for a mode in the status bar.",
                .ty = LuaType{ .function = .{
                    .args = &.{ .{ .name = "mode", .ty = LuaType.integer }, .{ .name = "name", .ty = LuaType.string } },
                    .fn_ptr = LuaFnBind((struct {
                        fn lua_fn(a: *r.app.App, mode: r.ContextFactory.Mode, name: []const u8) !void {
                            try a.context_factory.setModeName(mode, name);
                            a.dirty = true;
                        }
                    }).lua_fn, "set_mode_name"),
                } },
            },
            .{
                .name = "add_mode",
                .desc = "Add a custom mode.",
                .ty = LuaType{ .function = .{
                    .args = &.{
                        .{ .name = "name", .ty = LuaType.string },
                        .{ .name = "color", .ty = LuaType.string },
                        .{ .name = "prompt", .ty = LuaType.string },
                        .{ .name = "sparse", .ty = LuaType.string },
                    },
                    .ret = &LuaInteger,
                    .fn_ptr = LuaFnBind((struct {
                        fn lua_fn(a: *r.app.App, name: []const u8, color: []const u8, prompt: []const u8, sparse: []const u8) !r.ContextFactory.Mode {
                            return a.context_factory.addMode(name, prompt, sparse, color);
                        }
                    }).lua_fn, "add_mode"),
                } },
            },
            .{
                .name = "set_mode",
                .desc = "Switch the active session mode. Forces a full mode-reminder on the next turn.",
                .ty = LuaType{ .function = .{
                    .args = &.{.{ .name = "mode", .ty = LuaType.integer }},
                    .fn_ptr = LuaFnBind((struct {
                        fn lua_fn(a: *r.app.App, mode_id: u8) !void {
                            try a.cmd_queue.append(a.io, .{ .set_mode = mode_id });
                        }
                    }).lua_fn, "set_mode"),
                } },
            },
            .{
                .name = "get_flags",
                .desc = "Return the current app flags.",
                .ty = LuaType{ .function = .{
                    .ret = &AppFlagsDef,
                    .fn_ptr = LuaFnBind((struct {
                        fn lua_fn(a: *r.app.App) !r.app.AppFlags {
                            return a.flags;
                        }
                    }).lua_fn, "get_flags"),
                } },
            },
            .{
                .name = "set_flags",
                .desc = "Set the app flags from a table. Missing fields are set to their default values.",
                .ty = LuaType{ .function = .{
                    .args = &.{.{ .name = "flags", .ty = AppFlagsDef }},
                    .fn_ptr = LuaFnBind((struct {
                        fn lua_fn(a: *r.app.App, flags: r.app.AppFlags) !void {
                            a.flags = flags;
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
                            ok: [7]u8,
                            info: [7]u8,
                            warn: [7]u8,
                            err: [7]u8,
                            diff_surface: [7]u8,
                            diff_add: [7]u8,
                            diff_remove: [7]u8,
                        };
                        fn lua_fn(a: *r.app.App) !Ret {
                            const t = a.theme;
                            return .{
                                .bg = t.bg.toHexStr(),
                                .overlay_dark = t.overlay_dark.toHexStr(),
                                .overlay = t.overlay.toHexStr(),
                                .muted = t.muted.toHexStr(),
                                .text = t.text.toHexStr(),
                                .ok = t.ok.toHexStr(),
                                .info = t.info.toHexStr(),
                                .warn = t.warn.toHexStr(),
                                .err = t.err.toHexStr(),
                                .diff_surface = t.diff_surface.toHexStr(),
                                .diff_add = t.diff_add.toHexStr(),
                                .diff_remove = t.diff_remove.toHexStr(),
                            };
                        }
                    }).lua_fn, "get_theme"),
                } },
            },
            .{
                .name = "set_theme",
                .desc = "Set the theme from a table of hex color strings. Missing fields keep their current value.",
                .ty = LuaType{ .function = .{
                    .args = &.{.{ .name = "theme", .ty = ThemeDef }},
                    .fn_ptr = LuaFnBind((struct {
                        fn lua_fn(a: *r.app.App, theme: ThemeArg) !void {
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
                .desc = "Execute a shell command.",
                .ty = LuaType{ .function = .{
                    .args = &.{.{ .name = "cmd", .ty = LuaType.string }},
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
                            const result = a.swarm.exec.runAndWait(.{
                                .cwd = cwd,
                                .argv = &.{ "/bin/sh", "-c", cmd },
                            }) catch {
                                _ = c.lua_pushliteral(state, "failed to execute command");
                                c.lua_pushboolean(state, 0);
                                return 2;
                            };
                            defer a.swarm.exec.alloc.free(result.stdout);
                            defer a.swarm.exec.alloc.free(result.stderr);

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
                .name = "push_notification",
                .desc = "Push a new popup notification with a lifetime of 8s to the top right corner.",
                .ty = LuaType{ .function = .{
                    .args = &.{.{ .name = "message", .ty = LuaType.string }},
                    .fn_ptr = LuaFnBind((struct {
                        fn lua_fn(a: *r.app.App, message: []const u8) !void {
                            try a.cmd_queue.append(a.io, .{ .push_notification = message });
                        }
                    }).lua_fn, "push_notification"),
                } },
            },
        },
    },
};
pub const BlitzToolDef = LuaType{
    .table_def = .{
        .name = "BlitzToolDef",
        .fields = &.{
            .{ .name = "BASH", .ty = LuaType.string, .value = .{ .string = tl.bash.BashTool.def.name } },
            .{ .name = "CANCEL_BACKGROUND", .ty = LuaType.string, .value = .{ .string = tl.bash.CancelBackgroundCommand.def.name } },
            .{ .name = "READ", .ty = LuaType.string, .value = .{ .string = tl.read.ReadTool.def.name } },
            .{ .name = "WRITE", .ty = LuaType.string, .value = .{ .string = tl.write.WriteTool.def.name } },
            .{ .name = "EDIT", .ty = LuaType.string, .value = .{ .string = tl.edit.EditTool.def.name } },
            .{ .name = "PATCH", .ty = LuaType.string, .value = .{ .string = tl.patch.PatchTool.def.name } },
            .{ .name = "AGENT", .ty = LuaType.string, .value = .{ .string = tl.agent.AgentTool.def.name } },
            .{ .name = "LIST_TODOS", .ty = LuaType.string, .value = .{ .string = tl.todos.ListTodosTool.def.name } },
            .{ .name = "UPDATE_TODO_STATE", .ty = LuaType.string, .value = .{ .string = tl.todos.UpdateTodoStateTool.def.name } },
            .{ .name = "CREATE_TODO", .ty = LuaType.string, .value = .{ .string = tl.todos.CreateTodoTool.def.name } },
            .{ .name = "ASK", .ty = LuaType.string, .value = .{ .string = tl.ask.AskTool.def.name } },
            .{ .name = "ENTER_SSH", .ty = LuaType.string, .value = .{ .string = tl.ssh.EnterSshMode.def.name } },
            .{ .name = "EXIT_SSH", .ty = LuaType.string, .value = .{ .string = tl.ssh.ExitSshMode.def.name } },
            .{ .name = "SEND_MESSAGE_TO_AGENT", .ty = LuaType.string, .value = .{ .string = tl.agent.SendMessageToAgent.def.name } },
            .{ .name = "AWAIT_AGENT", .ty = LuaType.string, .value = .{ .string = tl.agent.AwaitAgent.def.name } },
            .{ .name = "CANCEL_AGENT", .ty = LuaType.string, .value = .{ .string = tl.agent.CancelAgent.def.name } },
            .{ .name = "RIPGREP", .ty = LuaType.string, .value = .{ .string = tl.rg.RipGrepTool.def.name } },
            .{ .name = "LOADSKILL", .ty = LuaType.string, .value = .{ .string = tl.skill.LoadSkillTool.def.name } },
            .{ .name = "START_MCP", .ty = LuaType.string, .value = .{ .string = tl.start.StartMcpTool.def.name } },
            .{ .name = "START_LSP", .ty = LuaType.string, .value = .{ .string = tl.start.StartLspTool.def.name } },
            .{ .name = "LSP", .ty = LuaType.string, .value = .{ .string = r.lsp.TOOL_NAME } },
        },
    },
};

pub const BlitzEventDef = LuaType{
    .table_def = .{
        .name = "BlitzEventDef",
        .fields = &.{
            .{ .name = "SESSION_RESET", .desc = "Emitted after the active session is reset.", .ty = LuaType.integer, .value = .{ .integer = 0 } },
            .{ .name = "MODE_CHANGED", .desc = "Emitted after the active session mode changes.", .ty = LuaType.integer, .value = .{ .integer = 1 } },
            .{ .name = "AGENT_CREATED", .desc = "Emitted after an agent slot is created.", .ty = LuaType.integer, .value = .{ .integer = 2 } },
            .{ .name = "AGENT_STARTED", .desc = "Emitted when an agent starts running.", .ty = LuaType.integer, .value = .{ .integer = 3 } },
            .{ .name = "AGENT_COMPLETE", .desc = "Emitted when an agent completes.", .ty = LuaType.integer, .value = .{ .integer = 4 } },
            .{ .name = "AGENT_FAILED", .desc = "Emitted when an agent fails.", .ty = LuaType.integer, .value = .{ .integer = 5 } },
            .{ .name = "AGENT_CANCELLED", .desc = "Emitted when an agent is cancelled.", .ty = LuaType.integer, .value = .{ .integer = 6 } },
            .{ .name = "COMPACTION_STARTED", .desc = "Emitted when compaction starts.", .ty = LuaType.integer, .value = .{ .integer = 7 } },
            .{ .name = "COMPACTION_COMPLETE", .desc = "Emitted when compaction completes.", .ty = LuaType.integer, .value = .{ .integer = 8 } },
            .{ .name = "TOOL_CALL_STARTED", .desc = "Emitted when a tool call starts.", .ty = LuaType.integer, .value = .{ .integer = 9 } },
            .{ .name = "TOOL_CALL_COMPLETE", .desc = "Emitted when a tool call completes.", .ty = LuaType.integer, .value = .{ .integer = 10 } },
            .{ .name = "AGENT_BROADCAST", .desc = "Emitted when an agent broadcasts a message.", .ty = LuaType.integer, .value = .{ .integer = 11 } },
            .{ .name = "PERMISSION_REQUESTED", .desc = "Emitted when a permission request is created.", .ty = LuaType.integer, .value = .{ .integer = 12 } },
            .{ .name = "PERMISSION_RESOLVED", .desc = "Emitted when a permission request is resolved.", .ty = LuaType.integer, .value = .{ .integer = 13 } },
            .{ .name = "USER_MESSAGE_SENT", .desc = "Emitted after the user sends a message.", .ty = LuaType.integer, .value = .{ .integer = 14 } },
            .{ .name = "MCP_TOOLS_RELOADED", .desc = "Emitted after MCP tools are reloaded.", .ty = LuaType.integer, .value = .{ .integer = 15 } },
            .{
                .name = "add_listener",
                .desc =
                \\Bind an event listener.
                \\Example: blitz.events.add_listener(blitz.events.MODE_CHANGED, function(new_mode_id) end)
                ,
                .ty = LuaType{ .function = .{
                    .args = &.{ .{ .name = "event", .ty = LuaType.integer }, .{ .name = "func", .ty = LuaType{ .function = .{} } } },
                    .fn_ptr = LuaFnBind((struct {
                        fn t(a: *r.app.App, event: u32, func: LuaFnRef) !void {
                            const ev: r.events.AppEventTag = @enumFromInt(event);
                            a.event_bus.addLuaListener(a.arena_app.allocator(), ev, func.idx) catch {};
                        }
                    }).t, "add_listener"),
                } },
            },
        },
    },
};

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

                            fn lua_fn(a: *r.app.App, args: Args) !u32 {
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
                            fn lua_fn(a: *r.app.App, mcp_id: u32) !void {
                                const vm = &a.lua_vm;
                                if (mcp_id == 0 or mcp_id > vm.mcp_entries.items.len) return error.InvalidMcpId;
                                vm.mcp_entries.items[mcp_id - 1].enabled = true;
                                try a.cmd_queue.append(a.io, .reload_mcp);
                            }
                        }).lua_fn, "mcp.enable"),
                    },
                },
            },
        },
    },
};

const BlitzLsp = LuaType{
    .table_def = .{
        .name = "BlitzLsp",
        .fields = &.{
            .{
                .name = "add",
                .desc = "Register an LSP stdio server. Disabled until explicitly enabled.",
                .ty = LuaType{
                    .function = .{
                        .args = &.{.{ .name = "def", .ty = LspServerDef }},
                        .ret = &LuaInteger,
                        .fn_ptr = LuaFnBind((struct {
                            const Args = struct {
                                name: []const u8,
                                command: []const u8,
                                args: ?[][]const u8,
                                language_id: ?[]const u8,
                                root: ?[]const u8,
                            };
                            fn lua_fn(a: *r.app.App, args: Args) !u32 {
                                try a.lua_vm.lsp_entries.appendBounded(.{
                                    .name = args.name,
                                    .args = args.args orelse &.{},
                                    .root = args.root orelse "",
                                    .language_id = args.language_id orelse "",
                                    .command = args.command,
                                });

                                return @intCast(a.lua_vm.lsp_entries.items.len);
                            }
                        }).lua_fn, "add"),
                    },
                },
            },
            .{
                .name = "enable",
                .desc = "Enable an LSP server for this session.",
                .ty = LuaType{
                    .function = .{
                        .args = &.{.{ .name = "lsp_id", .ty = LuaType.integer }},
                        .fn_ptr = LuaFnBind((struct {
                            fn lua_fn(a: *r.app.App, lsp_id: u32) !void {
                                const vm = &a.lua_vm;
                                if (lsp_id == 0 or lsp_id > vm.lsp_entries.items.len) return error.InvalidLspId;
                                vm.lsp_entries.items[lsp_id - 1].enabled = true;
                                try a.cmd_queue.append(a.io, .reload_lsp);
                            }
                        }).lua_fn, "lsp.enable"),
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
                    const vm = &(getAppFromRegistry(state) orelse return pushNilBool(state, false)).lua_vm;
                    const json = luaToJsonAlloc(vm.luaArena(), state, 1) catch return pushNilBool(state, false);
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
                const vm = &(getAppFromRegistry(state) orelse return pushNilBool(state, false)).lua_vm;
                if (c.lua_type(state, 1) != c.LUA_TSTRING) return pushNilBool(state, false);
                var len: usize = 0;
                const ptr = c.lua_tolstring(state, 1, &len) orelse return pushNilBool(state, false);
                pushJsonValue(vm.luaArena(), state, ptr[0..len]) catch return pushNilBool(state, false);
                c.lua_pushboolean(state, 1);
                return 2;
            }
        }).lua_fn,
    } } },
} } };

const BlitzQueue = LuaType{ .table_def = .{ .name = "BlitzQueue", .fields = &.{
    .{
        .name = "reset_session",
        .desc = "Reset the active session.",
        .ty = LuaType{
            .function = .{
                .fn_ptr = LuaFnBind((struct {
                    fn lua_fn(a: *r.app.App) !void {
                        try a.cmd_queue.append(a.io, .reset_session);
                    }
                }).lua_fn, "queue.reset_session"),
            },
        },
    },
    .{
        .name = "cancel",
        .desc = "Cancel all in-flight agent work and drop streaming preview.",
        .ty = LuaType{ .function = .{
            .fn_ptr = LuaFnBind((struct {
                fn lua_fn(a: *r.app.App) !void {
                    try a.cmd_queue.append(a.io, .cancel);
                }
            }).lua_fn, "queue.cancel"),
        } },
    },
    .{
        .name = "retry",
        .desc = "Retry the main agent's last turn.",
        .ty = LuaType{ .function = .{
            .fn_ptr = LuaFnBind((struct {
                fn lua_fn(a: *r.app.App) !void {
                    try a.cmd_queue.append(a.io, .retry);
                }
            }).lua_fn, "queue.retry"),
        } },
    },
    .{
        .name = "compact",
        .desc = "Request compaction for the main agent.",
        .ty = LuaType{ .function = .{
            .fn_ptr = LuaFnBind((struct {
                fn lua_fn(a: *r.app.App) !void {
                    try a.cmd_queue.append(a.io, .compact);
                }
            }).lua_fn, "queue.compact"),
        } },
    },
    .{
        .name = "set_mode",
        .desc = "Switch the active mode. Forces a full mode-reminder on the next turn.",
        .ty = LuaType{ .function = .{
            .args = &.{.{ .name = "mode", .ty = LuaType.integer }},
            .fn_ptr = LuaFnBind((struct {
                fn lua_fn(a: *r.app.App, mode: u8) !void {
                    try a.cmd_queue.append(a.io, .{ .set_mode = mode });
                }
            }).lua_fn, "queue.set_mode"),
        } },
    },
    .{
        .name = "push_chat_entry",
        .desc = "Push a chat entry into the chat log.",
        .ty = LuaType{ .function = .{
            .args = &.{ .{ .name = "role", .ty = LuaType.string }, .{ .name = "text", .ty = LuaType.string } },
            .fn_ptr = LuaFnBind((struct {
                fn lua_fn(a: *r.app.App, role_str: []const u8, text: []const u8) !void {
                    const role: prv.adapter.Role = if (std.mem.eql(u8, role_str, "system"))
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
            }).lua_fn, "queue.push_chat_entry"),
        } },
    },
    .{
        .name = "queue_agent_message",
        .desc = "Queue a user message for the given agent.",
        .ty = LuaType{ .function = .{
            .args = &.{ .{ .name = "agent_id", .ty = AgentIdDef }, .{ .name = "text", .ty = LuaType.string } },
            .fn_ptr = LuaFnBind((struct {
                fn lua_fn(a: *r.app.App, agent_id: r.prv.Swarm.AgentId, text: []const u8) !void {
                    const parts = [_]prv.adapter.ContentPart{.{ .text = text }};
                    try a.cmd_queue.append(a.io, .{ .queue_agent_message = .{
                        .agent_id = agent_id,
                        .parts = &parts,
                    } });
                }
            }).lua_fn, "queue.queue_agent_message"),
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
                        _ = c.luaL_error(state, "queue.spawn_agent: app not initialized");
                        return 0;
                    };
                    if (c.lua_type(state, 1) != c.LUA_TTABLE) {
                        _ = c.luaL_error(state, "queue.spawn_agent: expected a single table argument");
                        return 0;
                    }

                    var args: r.cmd.Command.SpawnArgs = .{
                        .agent_id = .{ .index = 0, .generation = 0 },
                        .prompt = &.{},
                    };

                    _ = c.lua_getfield(state, 1, "parent_id");
                    if (c.lua_type(state, -1) == c.LUA_TTABLE) {
                        args.parent_id = readAgentIdArg(state, "queue.spawn_agent", c.lua_gettop(state));
                    } else if (c.lua_type(state, -1) != c.LUA_TNIL) {
                        _ = c.luaL_error(state, "queue.spawn_agent: parent_id must be a table or nil");
                        return 0;
                    }
                    c.lua_pop(state, 1);

                    _ = c.lua_getfield(state, 1, "prompt");
                    if (c.lua_type(state, -1) != c.LUA_TSTRING) {
                        _ = c.luaL_error(state, "queue.spawn_agent: 'prompt' (string) required");
                        return 0;
                    }
                    var p_len: usize = 0;
                    const p_ptr = c.lua_tolstring(state, -1, &p_len);
                    const parts = [_]prv.adapter.ContentPart{.{ .text = p_ptr[0..p_len] }};
                    args.prompt = &parts;

                    if (getOptionalU32(state, 1, "agent_type")) |t| {
                        if (t > std.math.maxInt(u8)) {
                            _ = c.luaL_error(state, "queue.spawn_agent: agent_type out of range");
                            return 0;
                        }
                        args.agent_type = @intCast(t);
                    }
                    if (getOptionalBool(state, 1, "fork")) |f| args.fork = f;
                    c.lua_pop(state, 1);

                    if (args.fork and args.parent_id == null) {
                        _ = c.luaL_error(state, "queue.spawn_agent: fork=true requires parent_id");
                        return 0;
                    }

                    const id = a.swarm.reserveFreeSlot() orelse {
                        c.lua_pushnil(state);
                        return 1;
                    };
                    args.agent_id = id;

                    a.cmd_queue.append(a.io, .{ .spawn_agent = args }) catch {
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
        .name = "await_agent",
        .desc = "Block until the referenced agent reaches a terminal state.",
        .ty = LuaType{ .function = .{
            .args = &.{.{ .name = "agent_id", .ty = AgentIdDef }},
            .ret = &LuaInteger,
            .fn_ptr = (struct {
                fn lua_fn(L: ?*c.lua_State) callconv(.c) c_int {
                    const state = L.?;
                    const a = getAppFromRegistry(state) orelse {
                        _ = c.luaL_error(state, "queue.await_agent: app not initialized");
                        return 0;
                    };
                    const vm = activeVm() orelse {
                        _ = c.luaL_error(state, "queue.await_agent: no active lua vm");
                        return 0;
                    };
                    const id = readAgentIdArg(state, "queue.await_agent", 1);
                    const io = a.swarm.pool.io;
                    const slot = a.swarm.getSlot(id) orelse {
                        c.lua_pushinteger(state, AWAIT_INVALID);
                        return 1;
                    };

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

                    vm.vm_mu.unlock(io);
                    slot.event.wait(io) catch {
                        vm.vm_mu.lockUncancelable(io);
                        c.lua_pushinteger(state, AWAIT_CANCELED);
                        return 1;
                    };
                    vm.vm_mu.lockUncancelable(io);

                    const slot_now = a.swarm.getSlot(id) orelse {
                        c.lua_pushinteger(state, AWAIT_CANCELED);
                        return 1;
                    };
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
                        _ = c.luaL_error(state, "queue.await_agent_result: app not initialized");
                        return 0;
                    };
                    const id = readAgentIdArg(state, "queue.await_agent_result", 1);
                    const agent = a.swarm.getAgent(id) orelse {
                        _ = c.luaL_error(state, "queue.await_agent_result: agent not found");
                        return 0;
                    };
                    if (agent.chat.messages.items.len == 0) {
                        _ = c.luaL_error(state, "queue.await_agent_result: agent has no chat entries");
                        return 0;
                    }

                    const last_msg = &agent.chat.messages.items[agent.chat.messages.items.len -| 1];
                    var total: usize = 0;
                    for (last_msg.parts) |p| switch (p) {
                        .text => |t| total += t.len,
                        else => {},
                    };
                    if (total == 0) {
                        _ = c.lua_pushlstring(state, "", 0);
                        return 1;
                    }

                    var b: c.luaL_Buffer = undefined;
                    c.luaL_buffinit(state, &b);
                    for (last_msg.parts) |p| switch (p) {
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
        .name = "save_session",
        .desc = "Save current session to disk.",
        .ty = LuaType{ .function = .{
            .args = &.{.{ .name = "path", .ty = LuaType.string }},
            .fn_ptr = LuaFnBind((struct {
                fn lua_fn(a: *r.app.App, path: []const u8) !void {
                    try a.cmd_queue.append(a.io, .{ .save_session = path });
                }
            }).lua_fn, "save_session"),
        } },
    },
    .{
        .name = "load_session",
        .desc = "Load a session from disk.",
        .ty = LuaType{ .function = .{
            .args = &.{.{ .name = "path", .ty = LuaType.string }},
            .fn_ptr = LuaFnBind((struct {
                fn lua_fn(a: *r.app.App, path: []const u8) !void {
                    try a.cmd_queue.append(a.io, .{ .load_session = path });
                }
            }).lua_fn, "load_session"),
        } },
    },
    .{
        .name = "attach_screenshot",
        .desc = "Attach a screenshot/image to the current input.",
        .ty = LuaType{ .function = .{
            .args = &.{ .{ .name = "data", .ty = LuaType.string }, .{ .name = "media_type", .ty = LuaType.string, .optional = true } },
            .fn_ptr = LuaFnBind((struct {
                fn lua_fn(a: *r.app.App, data: []const u8, media_type: ?[]const u8) !void {
                    try a.cmd_queue.append(a.io, .{ .attach_screenshot = .{
                        .media_type = media_type orelse "image/png",
                        .data = data,
                    } });
                }
            }).lua_fn, "queue.attach_screenshot"),
        } },
    },
} } };

// ── Lua Tool Registry (per-VM, reached via registry lookup) ─────────

const LuaToolEntry = struct {
    name: [128]u8 = undefined,
    name_len: usize = 0,
    description: [512]u8 = undefined,
    desc_len: usize = 0,
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
    fn schemaSlice(self: *const LuaToolEntry) []const u8 {
        return self.schema[0..self.schema_len];
    }
};

const LuaAgentEntry = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    prompt: []const u8 = "",
    in_agent_tool: bool = true,
    model: []const u8 = "",
    effort: []const u8 = "",
};

const LuaBindEntry = struct {
    key: tui.Key = .{ .code = .{ .char = 0 } },
    func_ref: c_int = c.LUA_NOREF,
    L: ?*c.lua_State = null,
};

const LuaCommandEntry = struct {
    name: [128]u8 = undefined,
    name_len: usize = 0,
    func_ref: c_int = c.LUA_NOREF,
    L: ?*c.lua_State = null,

    fn nameSlice(self: *const LuaCommandEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

fn luaAbsIndex(L: *c.lua_State, idx: c_int) c_int {
    return if (idx < 0) c.lua_gettop(L) + idx + 1 else idx;
}

fn fieldName(comptime field: []const u8) [*:0]const u8 {
    return (field ++ "\x00").ptr;
}

fn pushAny(L: *c.lua_State, value: anytype) void {
    const T = @TypeOf(value);
    const Info = @typeInfo(T);
    switch (Info) {
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
        .array => {
            c.lua_createtable(L, @intCast(value.len), 0);
            for (value, 0..) |item, i| {
                pushAny(L, item);
                c.lua_rawseti(L, -2, @intCast(i + 1));
            }
        },
        .@"struct" => |str| {
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
        .number => |n| c.lua_pushnumber(L, n),
        .boolean => |b| c.lua_pushboolean(L, @intFromBool(b)),
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
        return .Ok(.{ .idx = luaAbsIndex(state, idx) });
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
            const abs = luaAbsIndex(state, idx);
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
            const tag_type = @typeInfo(T).@"enum".tag_type;
            if (n < 0 or n > std.math.maxInt(tag_type)) return .Err(name ++ " overflow");
            return .Ok(@enumFromInt(@as(tag_type, @intCast(n))));
        },
        .array => |arr| {
            if (c.lua_type(state, idx) != c.LUA_TTABLE) return .Err(name ++ " not a table");
            const abs = luaAbsIndex(state, idx);
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
    const abs = luaAbsIndex(state, table_idx);
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

/// Read a numeric field as f32. Returns null if missing or wrong type.
fn getOptionalF32(state: *c.lua_State, table_idx: c_int, field: [*:0]const u8) ?f32 {
    _ = c.lua_getfield(state, luaAbsIndex(state, table_idx), field);
    defer c.lua_pop(state, 1);
    return readAnyValue(f32, state, -1);
}

/// Read a boolean field. Returns null if missing or wrong type.
fn getOptionalBool(state: *c.lua_State, table_idx: c_int, field: [*:0]const u8) ?bool {
    _ = c.lua_getfield(state, luaAbsIndex(state, table_idx), field);
    defer c.lua_pop(state, 1);
    return readAnyValue(bool, state, -1);
}

/// Read a numeric field as u32. Returns null if missing, wrong type, or negative.
fn getOptionalU32(state: *c.lua_State, table_idx: c_int, field: [*:0]const u8) ?u32 {
    _ = c.lua_getfield(state, luaAbsIndex(state, table_idx), field);
    defer c.lua_pop(state, 1);
    return readAnyValue(u32, state, -1);
}

fn findEntry(vm: *LuaVm, name: []const u8) ?*LuaToolEntry {
    for (vm.tool_entries.items) |*entry| {
        if (std.mem.eql(u8, entry.nameSlice(), name)) return entry;
    }
    return null;
}

// ── ToolContext bridge (passed as light userdata during tool calls) ──

const CtxBridge = struct {
    cwd: []const u8,
    tool_ctx: ToolContext,
    tool_call: ToolCall,
};

// ── LuaVm ───────────────────────────────────────────────────────────

var app_registry_key: u8 = 0;

/// Process-wide pointer to the active VM. The tool trampoline receives no
/// lua_State, so it relies on this to find the owning VM. Set by setApp and
/// cleared by deinit.
var active_vm: ?*LuaVm = null;

fn activeVm() ?*LuaVm {
    return active_vm;
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

const MAX_LUA_TOOLS = 64;
const MAX_LUA_BINDS = 64;
const MAX_LUA_COMMANDS = 64;
const MAX_LUA_MCP_SERVERS = 16;
const MAX_LUA_MCP_ARGS = 32;
const MAX_LUA_LSP_SERVERS = 16;
const MAX_LUA_LSP_ARGS = 32;
const STDOUT_BUF_CAP = 1024 * 1024 * 16;

pub const LuaMcpServerEntry = struct {
    name: []const u8,
    command: []const u8,
    args: [][]const u8,
    tools_prefix: []const u8,
    enabled: bool = false,
};

pub const LuaLspServerEntry = struct {
    name: []const u8,
    command: []const u8,
    args: [][]const u8,
    root: []const u8,
    language_id: []const u8,
    enabled: bool = false,
};

pub const LuaVm = struct {
    L: *c.lua_State,
    app: ?*app.App = null,
    arena_state: std.heap.ArenaAllocator,
    tool_entries: std.ArrayList(LuaToolEntry) = .empty,
    bind_entries: std.ArrayList(LuaBindEntry) = .empty,
    command_entries: std.ArrayList(LuaCommandEntry) = .empty,
    mcp_entries: std.ArrayList(LuaMcpServerEntry) = .empty,
    lsp_entries: std.ArrayList(LuaLspServerEntry) = .empty,
    stdout_buf: std.ArrayList(u8) = .empty,
    last_error: [512]u8 = undefined,
    last_error_len: usize = 0,
    failed_ref: c_int = c.LUA_NOREF,
    exit_loop_ref: c_int = c.LUA_NOREF,
    /// Serializes lua_pcall across worker threads. Lua VMs are not
    /// thread-safe; native tools run in parallel, Lua tools serialize here.
    vm_mu: std.Io.Mutex = .init,

    pub fn init(parent: Allocator) !LuaVm {
        var self: LuaVm = .{
            .L = undefined,
            .arena_state = std.heap.ArenaAllocator.init(parent),
        };
        self.prepareArenaLists() catch |err| {
            self.arena_state.deinit();
            return err;
        };
        self.initLuaState() catch |err| {
            self.arena_state.deinit();
            return err;
        };
        return self;
    }

    fn luaArena(self: *LuaVm) Allocator {
        return self.arena_state.allocator();
    }

    fn prepareArenaLists(self: *LuaVm) !void {
        const arena = self.luaArena();
        try self.tool_entries.ensureTotalCapacity(arena, MAX_LUA_TOOLS);
        try self.bind_entries.ensureTotalCapacity(arena, MAX_LUA_BINDS);
        try self.command_entries.ensureTotalCapacity(arena, MAX_LUA_COMMANDS);
        try self.mcp_entries.ensureTotalCapacity(arena, MAX_LUA_MCP_SERVERS);
        try self.lsp_entries.ensureTotalCapacity(arena, MAX_LUA_LSP_SERVERS);
        try self.stdout_buf.ensureTotalCapacity(arena, STDOUT_BUF_CAP);
    }

    fn bindLuaAllocator(self: *LuaVm) void {
        c.lua_setallocf(self.L, &luaArenaAlloc, @ptrCast(&self.arena_state));
    }

    fn initLuaState(self: *LuaVm) !void {
        self.L = c.lua_newstate(&luaArenaAlloc, @ptrCast(&self.arena_state)) orelse return error.LuaInitFailed;
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
        active_vm = self;
        self.installStatusTables();
    }

    pub fn deinit(self: *LuaVm) void {
        if (active_vm == self) active_vm = null;
        c.lua_close(self.L);
        self.arena_state.deinit();
    }

    /// Build the singleton {status = RET_FAILED} table and expose it as
    /// blitz.FAILED. Refs stashed so we can `lua_rawgeti` the same instance
    /// for re-set after a reload.
    fn installStatusTables(self: *LuaVm) void {
        c.luaL_unref(self.L, c.LUA_REGISTRYINDEX, self.failed_ref);
        c.luaL_unref(self.L, c.LUA_REGISTRYINDEX, self.exit_loop_ref);

        c.lua_createtable(self.L, 0, 1);
        setFieldAny(self.L, -2, "status", RET_FAILED);
        self.failed_ref = c.luaL_ref(self.L, c.LUA_REGISTRYINDEX);

        c.lua_createtable(self.L, 0, 1);
        setFieldAny(self.L, -2, "status", RET_EXIT_LOOP);
        self.exit_loop_ref = c.luaL_ref(self.L, c.LUA_REGISTRYINDEX);

        _ = c.lua_getglobal(self.L, "blitz");
        if (c.lua_type(self.L, -1) == c.LUA_TTABLE) {
            _ = c.lua_rawgeti(self.L, c.LUA_REGISTRYINDEX, self.failed_ref);
            setFieldPushed(self.L, -2, "FAILED");
            _ = c.lua_rawgeti(self.L, c.LUA_REGISTRYINDEX, self.exit_loop_ref);
            setFieldPushed(self.L, -2, "EXIT_LOOP");
        }
        c.lua_pop(self.L, 1);
    }

    pub fn load(self: *LuaVm, path: []const u8) !void {
        // Null-terminate for C
        var buf: [4096]u8 = undefined;
        if (path.len >= buf.len) return error.PathTooLong;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;

        const status = c.luaL_loadfilex(self.L, &buf, null);
        if (status != 0) {
            self.popError();
            return error.LuaLoadFailed;
        }
        const call_status = c.lua_pcallk(self.L, 0, c.LUA_MULTRET, 0, 0, null);
        if (call_status != 0) {
            self.popError();
            return error.LuaLoadFailed;
        }
    }

    pub fn exec(self: *LuaVm, code: []const u8) !void {
        var buf: [8192]u8 = undefined;
        if (code.len >= buf.len) return error.CodeTooLong;
        @memcpy(buf[0..code.len], code);
        buf[code.len] = 0;

        const status = c.luaL_loadstring(self.L, &buf);
        if (status != 0) {
            self.popError();
            return error.LuaExecFailed;
        }
        const call_status = c.lua_pcallk(self.L, 0, c.LUA_MULTRET, 0, 0, null);
        if (call_status != 0) {
            self.popError();
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
        self.bind_entries = .empty;
        self.command_entries = .empty;
        self.mcp_entries = .empty;
        self.lsp_entries = .empty;
        self.stdout_buf = .empty;
        self.prepareArenaLists() catch return error.LuaInitFailed;
        self.tool_entries.clearRetainingCapacity();
        self.bind_entries.clearRetainingCapacity();
        self.command_entries.clearRetainingCapacity();
        self.mcp_entries.clearRetainingCapacity();
        self.lsp_entries.clearRetainingCapacity();
        self.stdout_buf.clearRetainingCapacity();
        // Refs were tied to the closed lua_State; drop them before re-init.
        self.failed_ref = c.LUA_NOREF;
        self.exit_loop_ref = c.LUA_NOREF;
        if (self.app) |a| {
            a.config.resetProviders();
            a.default_context_limit = app.CONTEXT_LIMIT;
        }
        try self.initLuaState();
        if (self.app) |a| self.setApp(a);
    }

    fn popError(self: *LuaVm) void {
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
    }

    pub fn getLastError(self: *const LuaVm) []const u8 {
        return self.last_error[0..self.last_error_len];
    }

    pub fn clearLastError(self: *LuaVm) void {
        self.last_error_len = 0;
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
                },
                .func = &luaToolTrampoline,
            };
        }
        return tools;
    }

    pub const LuaBind = struct {
        key: tui.Key,
        lua_fn: c_int,
    };

    pub fn getRegisteredKeybinds(self: *LuaVm, alloc: Allocator) ![]LuaBind {
        if (self.bind_entries.items.len == 0) return &.{};
        const out = try alloc.alloc(LuaBind, self.bind_entries.items.len);
        for (self.bind_entries.items, 0..) |entry, i| {
            out[i] = .{ .key = entry.key, .lua_fn = entry.func_ref };
        }
        return out;
    }

    pub fn getEnabledMcpServers(self: *LuaVm, alloc: Allocator) ![]@import("mcp.zig").ServerConfig {
        if (self.mcp_entries.items.len == 0) return &.{};
        var count: usize = 0;
        for (self.mcp_entries.items) |*entry| {
            if (entry.enabled) count += 1;
        }
        if (count == 0) return &.{};

        const out = try alloc.alloc(@import("mcp.zig").ServerConfig, count);
        var out_i: usize = 0;
        for (self.mcp_entries.items) |*entry| {
            if (!entry.enabled) continue;
            out[out_i] = .{
                .name = entry.name,
                .command = entry.command,
                .args = entry.args,
                .tools_prefix = entry.tools_prefix,
            };
            out_i += 1;
        }
        return out;
    }

    pub fn getEnabledLspServers(self: *LuaVm, alloc: Allocator) ![]@import("lsp.zig").ServerConfig {
        if (self.lsp_entries.items.len == 0) return &.{};
        var count: usize = 0;
        for (self.lsp_entries.items) |*entry| {
            if (entry.enabled) count += 1;
        }
        if (count == 0) return &.{};

        const out = try alloc.alloc(@import("lsp.zig").ServerConfig, count);
        var out_i: usize = 0;
        for (self.lsp_entries.items) |*entry| {
            if (!entry.enabled) continue;
            out[out_i] = .{
                .name = entry.name,
                .command = entry.command,
                .args = entry.args,
                .root = entry.root,
                .language_id = entry.language_id,
            };
            out_i += 1;
        }
        return out;
    }

    pub fn disableAllMcp(self: *LuaVm) void {
        for (self.mcp_entries.items) |*entry| entry.enabled = false;
    }

    pub fn disableAllLsp(self: *LuaVm) void {
        for (self.lsp_entries.items) |*entry| entry.enabled = false;
    }

    pub fn hasMcp(self: *LuaVm, name: []const u8) bool {
        return self.findMcp(name) != null;
    }

    pub fn hasLsp(self: *LuaVm, name: []const u8) bool {
        return self.findLsp(name) != null;
    }

    pub fn enableMcp(self: *LuaVm, name: []const u8) bool {
        const entry = self.findMcp(name) orelse return false;
        entry.enabled = true;
        return true;
    }

    pub fn enableLsp(self: *LuaVm, name: []const u8) bool {
        const entry = self.findLsp(name) orelse return false;
        entry.enabled = true;
        return true;
    }

    pub fn publishAvailableSystems(self: *LuaVm, factory: *r.ContextFactory) !void {
        var mcp_names: [MAX_LUA_MCP_SERVERS][]const u8 = undefined;
        var lsp_names: [MAX_LUA_LSP_SERVERS][]const u8 = undefined;

        for (self.mcp_entries.items, 0..) |*entry, i| mcp_names[i] = entry.name;
        for (self.lsp_entries.items, 0..) |*entry, i| lsp_names[i] = entry.name;

        try factory.setAvailableSystems(mcp_names[0..self.mcp_entries.items.len], lsp_names[0..self.lsp_entries.items.len]);
    }

    fn findMcp(self: *LuaVm, name: []const u8) ?*LuaMcpServerEntry {
        for (self.mcp_entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    fn findLsp(self: *LuaVm, name: []const u8) ?*LuaLspServerEntry {
        for (self.lsp_entries.items) |*entry| {
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
        if (status != 0) self.popError();
    }

    /// Invoke a registered lua command. `input` may be the full typed command
    /// (":name args") or only the command name; returns false when unhandled.
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
            if (status != 0) self.popError();
            return true;
        }

        return false;
    }

    pub fn invokeLuaFunction(self: *LuaVm, func_ref: c_int, args: anytype) void {
        _ = c.lua_rawgeti(self.L, c.LUA_REGISTRYINDEX, func_ref);
        pushAny(self.L, args);
        const status = c.lua_pcallk(self.L, 1, 0, 0, 0, null);
        if (status != 0) self.popError();
    }

    pub fn appendCommandCompletions(
        self: *LuaVm,
        prefix: []const u8,
        out: []?[]const u8,
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
                    if (std.mem.eql(u8, value, name)) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue;
            }

            out[count.*] = name;
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
                .ok => |theme| applyTheme(a, theme) catch |err| {
                    log.err("invalid blitz.theme: {s}", .{@errorName(err)});
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
            self.popError();
            return null;
        }

        if (c.lua_type(L, -1) != c.LUA_TSTRING) return null;
        var len: usize = 0;
        const ptr = c.lua_tolstring(L, -1, &len) orelse return null;
        const capped = @min(len, dest.len);
        @memcpy(dest[0..capped], ptr[0..capped]);
        return dest[0..capped];
    }
};

// ── blitz.* Lua library ─────────────────────────────────────────────

fn registerBlitzLib(L: *c.lua_State) void {
    setLuaTypeGlobal(L, "blitz", Blitz);
}

fn luaPrintToBuffer(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const vm = &(getAppFromRegistry(state) orelse return 0).lua_vm;
    const top = c.lua_gettop(state);
    var i: c_int = 1;
    while (i <= top) : (i += 1) {
        if (i > 1) vm.stdout_buf.appendSliceBounded(" ") catch return 0;
        var len: usize = 0;
        const s = c.lua_tolstring(state, i, &len);
        if (s) |ptr| {
            vm.stdout_buf.appendSliceBounded(ptr[0..len]) catch return 0;
        }
    }
    vm.stdout_buf.appendBounded('\n') catch return 0;
    return 0;
}

fn pushStatusTable(state: *c.lua_State, status: c_int, fallback: []const u8) void {
    c.lua_createtable(state, 0, 2);
    setFieldAny(state, -2, "status", status);
    if (c.lua_type(state, 1) == c.LUA_TSTRING) {
        c.lua_pushvalue(state, 1);
    } else {
        _ = c.lua_pushlstring(state, fallback.ptr, fallback.len);
    }
    setFieldPushed(state, -2, "msg");
}

pub fn getAppFromRegistry(L: *c.lua_State) ?*app.App {
    _ = c.lua_rawgetp(L, c.LUA_REGISTRYINDEX, @ptrCast(&app_registry_key));
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TLIGHTUSERDATA) return null;
    const ptr = c.lua_touserdata(L, -1) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn getCfgFromRegistry(L: *c.lua_State) ?*prv.config.BlitzdenkCfg {
    const a = getAppFromRegistry(L) orelse return null;
    return &a.config;
}

/// Read a required string field from the table at `table_idx`. On failure calls
/// luaL_error (which does not return) so the caller can treat the return value
/// as guaranteed. Returned slice is valid only while the field value remains on
/// the stack — this helper leaves the field on top of the stack for the caller
/// to pop once the slice has been copied elsewhere.
fn requireStringFieldOnStack(state: *c.lua_State, table_idx: c_int, field: [*:0]const u8) []const u8 {
    _ = c.lua_getfield(state, table_idx, field);
    if (c.lua_type(state, -1) != c.LUA_TSTRING) {
        _ = c.luaL_error(state, "add_provider: missing or non-string field '%s'", field);
        return &.{};
    }
    var len: usize = 0;
    const ptr = c.lua_tolstring(state, -1, &len);
    return ptr[0..len];
}

fn parseProviderType(state: *c.lua_State, type_str: []const u8) prv.adapter.Provider {
    if (std.mem.eql(u8, type_str, "openai")) return .openai;
    if (std.mem.eql(u8, type_str, "response")) return .response;
    if (std.mem.eql(u8, type_str, "anthropic")) return .anthropic;
    if (std.mem.eql(u8, type_str, "ollama")) return .ollama;
    _ = c.luaL_error(state, "add_provider: unknown type (expected openai/response/anthropic/ollama)");
    return .openai; // unreachable; luaL_error longjmps
}

/// Populate slot.thinking_type_buf and return a Thinking value whose `.type`
/// slice points at the slot's own buffer. Expects the table at absolute index
/// `sub_idx` to contain `{ type = "...", budget_tokens = N? }`.
fn readThinking(state: *c.lua_State, sub_idx: c_int, slot: *prv.config.Provider) prv.adapter.Thinking {
    _ = c.lua_getfield(state, sub_idx, "type");
    defer c.lua_pop(state, 1);
    if (c.lua_type(state, -1) != c.LUA_TSTRING) {
        _ = c.luaL_error(state, "add_provider: thinking.type must be a string");
    }
    var tlen: usize = 0;
    const tptr = c.lua_tolstring(state, -1, &tlen);
    if (!slot.setThinkingType(tptr[0..tlen])) {
        _ = c.luaL_error(state, "add_provider: thinking.type too long");
    }
    return .{
        .type = slot.getThinkingType(),
        .budget_tokens = getOptionalU32(state, sub_idx, "budget_tokens"),
    };
}

fn readReasoningEffort(state: *c.lua_State, table_idx: c_int) ?prv.config.ReasoningEffort {
    _ = c.lua_getfield(state, table_idx, "effort");
    defer c.lua_pop(state, 1);
    if (c.lua_isnil(state, -1)) return null;

    const value = readAnyValue([]const u8, state, -1) orelse {
        _ = c.luaL_error(state, "add_provider: effort must be a string");
        return null;
    };
    return prv.config.parseReasoningEffort(value) orelse {
        _ = c.luaL_error(state, "add_provider: unknown effort (expected none/low/medium/high/xhigh/max)");
        return null;
    };
}

fn readOpenAiConfig(state: *c.lua_State, table_idx: c_int) prv.adapter.OpenAiConfig {
    var cfg: prv.adapter.OpenAiConfig = .{};
    cfg.temperature = getOptionalF32(state, table_idx, "temperature");
    cfg.max_tokens = getOptionalU32(state, table_idx, "max_tokens");
    cfg.max_completion_tokens = getOptionalU32(state, table_idx, "max_completion_tokens");
    cfg.top_p = getOptionalF32(state, table_idx, "top_p");
    cfg.frequency_penalty = getOptionalF32(state, table_idx, "frequency_penalty");
    cfg.presence_penalty = getOptionalF32(state, table_idx, "presence_penalty");
    cfg.enable_thinking = getOptionalBool(state, table_idx, "enable_thinking");

    return cfg;
}

fn readAnthropicConfig(state: *c.lua_State, table_idx: c_int, slot: *prv.config.Provider) prv.adapter.AnthropicConfig {
    var cfg: prv.adapter.AnthropicConfig = .{};
    if (getOptionalU32(state, table_idx, "max_tokens")) |n| cfg.max_tokens = n;
    cfg.temperature = getOptionalF32(state, table_idx, "temperature");
    cfg.top_p = getOptionalF32(state, table_idx, "top_p");
    cfg.top_k = getOptionalU32(state, table_idx, "top_k");

    _ = c.lua_getfield(state, table_idx, "thinking");
    if (c.lua_type(state, -1) == c.LUA_TTABLE) {
        cfg.thinking = readThinking(state, c.lua_gettop(state), slot);
    }
    c.lua_pop(state, 1);

    return cfg;
}

fn readOllamaConfig(state: *c.lua_State, table_idx: c_int) prv.adapter.OllamaConfig {
    return .{
        .temperature = getOptionalF32(state, table_idx, "temperature"),
        .max_tokens = getOptionalU32(state, table_idx, "max_tokens"),
        .top_p = getOptionalF32(state, table_idx, "top_p"),
        .top_k = getOptionalU32(state, table_idx, "top_k"),
    };
}

/// blitz.bind(vim_key_combo_string, lua func)
/// blitz.add_command(":command", lua func)
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

fn readEnumArg(state: *c.lua_State, comptime E: type, comptime name: []const u8, idx: c_int) ?E {
    if (c.lua_type(state, idx) != c.LUA_TNUMBER) {
        _ = c.luaL_error(state, name ++ ": arg %d must be a number", @as(c_int, idx));
        return null;
    }
    const n = c.lua_tointegerx(state, idx, null);
    if (n < 0 or n > std.math.maxInt(u6)) {
        _ = c.luaL_error(state, name ++ ": value out of range");
        return null;
    }
    return @enumFromInt(@as(u6, @intCast(n)));
}

// ── Trampoline: Zig ToolFn → Lua function call ─────────────────────

// Import provider types used in tool interface
const prv = r.prv;

const ToolContext = prv.tool.ToolContext;
const ToolCall = prv.adapter.ToolCall;
const ToolResult = prv.adapter.ToolResult;
const Tool = prv.tool.Tool;

fn failedResult(call: ToolCall, msg: []const u8) ToolResult {
    return .{ .call_id = call.id, .name = call.name, .content = msg, .is_error = true };
}

fn luaToolTrampoline(ctx: ToolContext, call: ToolCall) ToolResult {
    const vm = activeVm() orelse return failedResult(call, "no active lua vm");
    const entry = findEntry(vm, call.name) orelse return failedResult(call, "tool not found");
    const L = entry.L orelse return failedResult(call, "tool has no lua state");

    // Serialize across worker threads — Lua VM is not thread-safe.
    vm.vm_mu.lockUncancelable(ctx.io);
    defer vm.vm_mu.unlock(ctx.io);

    // Push the Lua function
    _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, entry.func_ref);
    if (c.lua_type(L, -1) != c.LUA_TFUNCTION) {
        c.lua_pop(L, 1);
        return failedResult(call, "tool func is not a function");
    }

    // Build ctx bridge and push as arg 1
    var bridge = CtxBridge{
        .cwd = ctx.swarm.context.cwd(ctx.swarm.context.ptr),
        .tool_ctx = ctx,
        .tool_call = call,
    };
    pushCtxTable(L, &bridge, entry.state_ref);

    // Push call table as arg 2
    pushCallTable(vm.luaArena(), L, call);

    // pcall(func, ctx, call) → 1 return (status table). Bridge fns called
    // from Lua (ctx:approve / :ask / :plan) block the worker thread until
    // the UI resolves them; from Lua's perspective they are synchronous.
    const status = c.lua_pcallk(L, 2, 1, 0, 0, null);
    if (status != 0) {
        var err_len: usize = 0;
        const err_ptr = c.lua_tolstring(L, -1, &err_len);
        const err_msg = if (err_ptr != null) err_ptr[0..err_len] else "lua error";
        const owned = ctx.alloc.dupe(u8, err_msg) catch "lua error";
        c.lua_pop(L, 1);
        return failedResult(call, owned);
    }

    // Splice captured print() stdout into the OK table's msg field.
    const stdout = vm.stdout_buf.items;
    if (stdout.len > 0) {
        if (c.lua_type(L, -1) == c.LUA_TTABLE) {
            _ = c.lua_getfield(L, -1, "status");
            const is_ok = c.lua_type(L, -1) == c.LUA_TNUMBER and
                c.lua_tointegerx(L, -1, null) == RET_OK;
            c.lua_pop(L, 1);
            if (is_ok) {
                _ = c.lua_getfield(L, -1, "msg");
                _ = c.lua_pushlstring(L, "\nStdout:\n", 9);
                _ = c.lua_pushlstring(L, stdout.ptr, stdout.len);
                _ = c.lua_concat(L, 3);
                c.lua_setfield(L, -2, "msg");
            }
        }
        vm.stdout_buf.clearRetainingCapacity();
    }

    const ret = interpretReturns(L, call, ctx.alloc);
    c.lua_pop(L, 1);
    return ret;
}

fn interpretReturns(L: *c.lua_State, call: ToolCall, alloc: std.mem.Allocator) ToolResult {
    // Single return at top (-1): expect {status = int, msg = string|nil}.
    if (c.lua_type(L, -1) != c.LUA_TTABLE) return failedResult(call, "lua tool did not return a table");

    _ = c.lua_getfield(L, -1, "status");
    const status_ty = c.lua_type(L, -1);
    if (status_ty != c.LUA_TNUMBER) {
        c.lua_pop(L, 1);
        return failedResult(call, "lua tool return missing status");
    }
    const status = c.lua_tointegerx(L, -1, null);
    c.lua_pop(L, 1);

    switch (status) {
        RET_FAILED => return failedResult(call, "lua tool failed"),
        RET_EXIT_LOOP => {
            _ = c.lua_getfield(L, -1, "msg");
            var len: usize = 0;
            const content_ptr = c.lua_tolstring(L, -1, &len);
            const content_view = if (content_ptr != null) content_ptr[0..len] else "";
            const owned = alloc.dupe(u8, content_view) catch "oom";
            c.lua_pop(L, 1);
            return .{
                .call_id = call.id,
                .name = call.name,
                .content = owned,
                .exit_loop = true,
            };
        },
        RET_OK, RET_ERR => {
            _ = c.lua_getfield(L, -1, "msg");
            var len: usize = 0;
            const content_ptr = c.lua_tolstring(L, -1, &len);
            const fallback: []const u8 = if (status == RET_ERR) "error" else "";
            const content_view = if (content_ptr != null) content_ptr[0..len] else fallback;
            // Dupe out of Lua memory before pop frees the string.
            const owned = alloc.dupe(u8, content_view) catch "oom";
            c.lua_pop(L, 1);
            return .{
                .call_id = call.id,
                .name = call.name,
                .content = owned,
                .is_error = status == RET_ERR,
            };
        },
        else => return failedResult(call, "lua tool returned unknown status"),
    }
}

// ── Push ctx table with methods ─────────────────────────────────────

fn pushCtxTable(L: *c.lua_State, bridge: *CtxBridge, state_ref: c_int) void {
    c.lua_newtable(L);

    setFieldAny(L, -2, "cwd", bridge.cwd);

    pushAgentId(L, bridge.tool_ctx.self_id);
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

fn pushCallTable(alloc: Allocator, L: *c.lua_State, call: ToolCall) void {
    c.lua_newtable(L);

    setFieldAny(L, -2, "id", call.id);
    setFieldAny(L, -2, "name", call.name);

    // Parse arguments JSON into Lua table
    if (call.arguments.len > 0) {
        pushJsonValue(alloc, L, call.arguments) catch {
            // Fallback: raw string if JSON parse fails
            _ = c.lua_pushlstring(L, call.arguments.ptr, call.arguments.len);
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
fn awaitPermAndPush(state: *c.lua_State, io: std.Io, req: *r.prv.Swarm.PermissionReq, options: []const []const u8) c_int {
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

    var req = r.prv.Swarm.PermissionReq{
        .agent_id = bridge.tool_ctx.self_id,
        .payload = .{ .ask = .{
            .header = header,
            .question = question,
            .options = options.items,
        } },
    };

    bridge.tool_ctx.swarm.requestPermission(&req);
    return awaitPermAndPush(state, bridge.tool_ctx.io, &req, options.items);
}

fn luaApprove(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const bridge = getBridge(state) orelse {
        return pushStatusNil(state, REQ_STATUS_DENIED);
    };

    if (c.lua_type(state, 2) != c.LUA_TSTRING or c.lua_type(state, 3) != c.LUA_TSTRING) {
        return pushStatusNil(state, REQ_STATUS_DENIED);
    }

    const tool_name = readAnyValue([]const u8, state, 2).?;
    const tool_arguments = readAnyValue([]const u8, state, 3).?;

    var req = r.prv.Swarm.PermissionReq{
        .agent_id = bridge.tool_ctx.self_id,
        .payload = .{ .call = .{
            .tool_name = tool_name,
            .tool_arguments = tool_arguments,
        } },
    };

    bridge.tool_ctx.swarm.requestPermission(&req);
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

    var req = r.prv.Swarm.PermissionReq{
        .agent_id = bridge.tool_ctx.self_id,
        .payload = .{ .plan = .{
            .path = path,
            .plan_text = plan_text,
        } },
    };

    bridge.tool_ctx.swarm.requestPermission(&req);
    return awaitPermAndPush(state, bridge.tool_ctx.io, &req, &.{});
}

// ── blitz.queue.* — CommandQueue + Swarm reservation bindings ─────────

/// Push AgentId as `{index, generation}` table.
fn pushAgentId(L: *c.lua_State, id: r.prv.Swarm.AgentId) void {
    c.lua_createtable(L, 0, 2);
    setFieldAny(L, -2, "index", id.index);
    setFieldAny(L, -2, "generation", id.generation);
}

/// Read AgentId from table at `idx`. Reports a Lua error on shape mismatch.
/// TODO: crash!
fn readAgentIdArg(state: *c.lua_State, comptime fname: []const u8, idx: c_int) r.prv.Swarm.AgentId {
    if (c.lua_type(state, idx) != c.LUA_TTABLE) {
        _ = c.luaL_error(state, fname ++ ": agent_id must be a table {index, generation}");
        return .{ .index = 0, .generation = 0 };
    }

    const index = switch (readAnyFieldAlloc(u16, state, "index", idx, null)) {
        .ok => |v| v,
        .err => {
            _ = c.luaL_error(state, fname ++ ": agent_id.index must be a number");
            return .{ .index = 0, .generation = 0 };
        },
    };

    const generation = switch (readAnyFieldAlloc(u16, state, "generation", idx, null)) {
        .ok => |v| v,
        .err => {
            _ = c.luaL_error(state, fname ++ ": agent_id.generation must be a number");
            return .{ .index = 0, .generation = 0 };
        },
    };

    return .{
        .index = index,
        .generation = generation,
    };
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
    try std.testing.expectEqual(c.LUA_TTABLE, c.lua_getfield(state, -1, "queue"));
    try std.testing.expectEqual(c.LUA_TFUNCTION, c.lua_getfield(state, -1, "await_agent"));
}
