const std = @import("std");
const app = @import("app.zig");
const c = @import("c");
const Allocator = std.mem.Allocator;
const tui = @import("tui/root.zig");
const keys = @import("keys.zig");
const tl = @import("tools/root.zig");

// ── blitz.* return status codes ─────────────────────────────────────

pub const RET_FAILED: c_int = 1;
pub const RET_OK: c_int = 2;
pub const RET_ERR: c_int = 3;

// ── Request status codes (exposed to Lua) ─────────────────────────

pub const REQ_STATUS_PENDING: c_int = 0;
pub const REQ_STATUS_APPROVED: c_int = 1;
pub const REQ_STATUS_DENIED: c_int = 2;
pub const REQ_STATUS_CHOICE: c_int = 3;
pub const REQ_STATUS_MESSAGE: c_int = 4;

// ── await_agent return codes ───────────────────────────────────────
pub const AWAIT_COMPLETE: c_int = 1;
pub const AWAIT_FAILED: c_int = 2;
pub const AWAIT_CANCELED: c_int = 3;
pub const AWAIT_INVALID: c_int = 4;

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
    switch (@typeInfo(T)) {
        .bool => c.lua_pushboolean(L, @intFromBool(value)),
        .comptime_int, .int => c.lua_pushinteger(L, @intCast(value)),
        .comptime_float, .float => c.lua_pushnumber(L, @floatCast(value)),
        .@"enum" => c.lua_pushinteger(L, @intFromEnum(value)),
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                _ = c.lua_pushlstring(L, value.ptr, value.len);
            } else {
                @compileError("pushAny: unsupported pointer type " ++ @typeName(T));
            }
        },
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
    switch (@typeInfo(T)) {
        .pointer => |ptr| if (ptr.size == .slice and ptr.child == u8) {
            if (c.lua_type(state, idx) != c.LUA_TSTRING) return null;
            var len: usize = 0;
            const sptr = c.lua_tolstring(state, idx, &len) orelse return null;
            return sptr[0..len];
        },
        .int, .comptime_int => {
            if (c.lua_type(state, idx) != c.LUA_TNUMBER) return null;
            const n = c.lua_tointegerx(state, idx, null);
            if (T != comptime_int) {
                if (@typeInfo(T).int.signedness == .unsigned and n < 0) return null;
                if (n < std.math.minInt(T) or n > std.math.maxInt(T)) return null;
            }
            return @as(T, @intCast(n));
        },
        .float, .comptime_float => {
            if (c.lua_type(state, idx) != c.LUA_TNUMBER) return null;
            return @as(T, @floatCast(c.lua_tonumberx(state, idx, null)));
        },
        .bool => {
            if (c.lua_type(state, idx) != c.LUA_TBOOLEAN) return null;
            return c.lua_toboolean(state, idx) != 0;
        },
        else => @compileError("readAnyValue: unsupported type " ++ @typeName(T)),
    }
}

fn readAnyField(comptime T: type, state: *c.lua_State, table_idx: c_int, comptime field: []const u8) ?T {
    const abs = luaAbsIndex(state, table_idx);
    _ = c.lua_getfield(state, abs, fieldName(field));
    defer c.lua_pop(state, 1);
    return readAnyValue(T, state, -1);
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
var vm_registry_key: u8 = 0;

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
const STDOUT_BUF_CAP = 1024 * 1024 * 16;

pub const LuaMcpServerEntry = struct {
    name: [128]u8 = undefined,
    name_len: usize = 0,
    command: [512]u8 = undefined,
    command_len: usize = 0,
    args: [MAX_LUA_MCP_ARGS][256]u8 = undefined,
    arg_lens: [MAX_LUA_MCP_ARGS]u16 = @splat(0),
    args_len: usize = 0,
    tools_prefix: [128]u8 = undefined,
    tools_prefix_len: usize = 0,
    enabled_agents: @import("registry.zig").AgentType.Set = .initEmpty(),

    pub fn nameSlice(self: *const LuaMcpServerEntry) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn commandSlice(self: *const LuaMcpServerEntry) []const u8 {
        return self.command[0..self.command_len];
    }
    pub fn argSlice(self: *const LuaMcpServerEntry, i: usize) []const u8 {
        return self.args[i][0..self.arg_lens[i]];
    }
    pub fn toolsPrefixSlice(self: *const LuaMcpServerEntry) []const u8 {
        return self.tools_prefix[0..self.tools_prefix_len];
    }
};

pub const LuaVm = struct {
    L: *c.lua_State,
    app: ?*app.App = null,
    arena_state: std.heap.ArenaAllocator,
    tool_entries: std.ArrayList(LuaToolEntry) = .empty,
    bind_entries: std.ArrayList(LuaBindEntry) = .empty,
    command_entries: std.ArrayList(LuaCommandEntry) = .empty,
    mcp_entries: std.ArrayList(LuaMcpServerEntry) = .empty,
    stdout_buf: std.ArrayList(u8) = .empty,
    last_error: [512]u8 = undefined,
    last_error_len: usize = 0,
    failed_ref: c_int = c.LUA_NOREF,
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

    fn registerVmPtr(self: *LuaVm) void {
        c.lua_pushlightuserdata(self.L, @ptrCast(self));
        c.lua_rawsetp(self.L, c.LUA_REGISTRYINDEX, @ptrCast(&vm_registry_key));
    }

    pub fn setApp(self: *LuaVm, a: *app.App) void {
        self.bindLuaAllocator();
        self.app = a;
        c.lua_pushlightuserdata(self.L, @ptrCast(a));
        c.lua_rawsetp(self.L, c.LUA_REGISTRYINDEX, @ptrCast(&app_registry_key));
        self.registerVmPtr();
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

        c.lua_createtable(self.L, 0, 1);
        setFieldAny(self.L, -2, "status", RET_FAILED);
        self.failed_ref = c.luaL_ref(self.L, c.LUA_REGISTRYINDEX);

        _ = c.lua_getglobal(self.L, "blitz");
        if (c.lua_type(self.L, -1) == c.LUA_TTABLE) {
            _ = c.lua_rawgeti(self.L, c.LUA_REGISTRYINDEX, self.failed_ref);
            setFieldPushed(self.L, -2, "FAILED");
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
        self.stdout_buf = .empty;
        self.prepareArenaLists() catch return error.LuaInitFailed;
        self.tool_entries.clearRetainingCapacity();
        self.bind_entries.clearRetainingCapacity();
        self.command_entries.clearRetainingCapacity();
        self.mcp_entries.clearRetainingCapacity();
        self.stdout_buf.clearRetainingCapacity();
        // Refs were tied to the closed lua_State; drop them before re-init.
        self.failed_ref = c.LUA_NOREF;
        if (self.app) |a| {
            @constCast(a.swarm.cfg).resetProviders();
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
            if (entry.enabled_agents.count() > 0) count += 1;
        }
        if (count == 0) return &.{};

        const out = try alloc.alloc(@import("mcp.zig").ServerConfig, count);
        var out_i: usize = 0;
        for (self.mcp_entries.items) |*entry| {
            if (entry.enabled_agents.count() == 0) continue;
            const args = try alloc.alloc([]const u8, entry.args_len);
            for (0..entry.args_len) |j| args[j] = entry.argSlice(j);
            out[out_i] = .{
                .name = entry.nameSlice(),
                .command = entry.commandSlice(),
                .args = args,
                .tools_prefix = entry.toolsPrefixSlice(),
                .enabled_agents = entry.enabled_agents,
            };
            out_i += 1;
        }
        return out;
    }

    pub fn disableAllMcp(self: *LuaVm) void {
        for (self.mcp_entries.items) |*entry| entry.enabled_agents = .initEmpty();
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
            if (containsCompletion(out[0..count.*], name)) continue;

            out[count.*] = name;
            count.* += 1;
        }
    }

    fn containsCompletion(items: []?[]const u8, needle: []const u8) bool {
        for (items) |item| {
            const value = item orelse continue;
            if (std.mem.eql(u8, value, needle)) return true;
        }
        return false;
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

        // // blitz.search_api
        // _ = c.lua_getfield(L, -1, "search_api");
        // if (c.lua_type(L, -1) == c.LUA_TSTRING) {
        //     var len: usize = 0;
        //     const ptr = c.lua_tolstring(L, -1, &len);
        //     _ = cfg.setSearchApi(ptr[0..len]);
        // }
        // c.lua_pop(L, 1);

        // blitz.status_bar_render = function() return "..." end
        _ = c.lua_getfield(L, -1, "status_bar_render");
        a.lua_status_bar_enabled = c.lua_type(L, -1) == c.LUA_TFUNCTION;
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
    c.lua_newtable(L);

    inline for (.{
        .{ "register_tool", &luaRegisterTool },
        .{ "ok", &luaBlitzOk },
        .{ "err", &luaBlitzErr },
        .{ "add_provider", &luaAddProvider },
        .{ "set_model", &luaSetModel },
        .{ "add_doc", &luaAddDoc },
        .{ "token_usage", &luaTokenUsage },
        .{ "context_percent", &luaContextPercent },
        .{ "set_compact_edge", &luaSetCompactEdge },
        .{ "bind", &luaBind },
        .{ "html_to_markdown", &htmlToMarkdown },
        .{ "add_command", &luaAddCommand },
        .{ "set_agent_tools", &luaSetAgentTools },
        .{ "set_prompt", &luaSetPrompt },
        .{ "set_mode_prompt", &luaSetModePrompt },
        .{ "set_mode_prompt_sparse", &luaSetModePromptSparse },
        .{ "set_mode_name", &luaSetModeName },
        .{ "add_mode", &luaAddMode },
        .{ "set_mode", &luaSetMode },
        .{ "log", &luaLog },
        .{ "shell", &luaShell },
        .{ "push_notification", &luaPushNotification },
    }) |binding| {
        setCFunctionField(L, -2, binding[0], binding[1]);
    }

    inline for (.{
        .{ "RET_FAILED", RET_FAILED },
        .{ "RET_OK", RET_OK },
        .{ "RET_ERR", RET_ERR },
        .{ "AGENT_MAIN", 0 },
        .{ "AGENT_SUB", 1 },
        .{ "AGENT_PLAN", 2 },
        .{ "MODE_EXEC", 0 },
        .{ "REQ_STATUS_PENDING", REQ_STATUS_PENDING },
        .{ "REQ_STATUS_APPROVED", REQ_STATUS_APPROVED },
        .{ "REQ_STATUS_DENIED", REQ_STATUS_DENIED },
        .{ "REQ_STATUS_CHOICE", REQ_STATUS_CHOICE },
        .{ "REQ_STATUS_MESSAGE", REQ_STATUS_MESSAGE },
        .{ "AWAIT_COMPLETE", AWAIT_COMPLETE },
        .{ "AWAIT_FAILED", AWAIT_FAILED },
        .{ "AWAIT_CANCELED", AWAIT_CANCELED },
        .{ "AWAIT_INVALID", AWAIT_INVALID },
    }) |kv| {
        setFieldAny(L, -2, kv[0], kv[1]);
    }

    // blitz.mcp.{add,enable}
    c.lua_newtable(L);
    inline for (.{
        .{ "add", &luaMcpAdd },
        .{ "enable", &luaMcpEnable },
    }) |binding| {
        setCFunctionField(L, -2, binding[0], binding[1]);
    }
    setFieldPushed(L, -2, "mcp");

    // blitz.json.{encode,decode}
    c.lua_newtable(L);
    inline for (.{
        .{ "encode", &luaJsonEncode },
        .{ "decode", &luaJsonDecode },
    }) |binding| {
        setCFunctionField(L, -2, binding[0], binding[1]);
    }
    setFieldPushed(L, -2, "json");

    // TOOL_* string constants — names match the actual tool .name fields
    inline for (.{
        .{ "TOOL_BASH", tl.bash.BashTool.def.name },
        .{ "TOOL_CANCEL_BACKGROUND", tl.bash.CancelBackgroundCommand.def.name },
        .{ "TOOL_READ", tl.read.ReadTool.def.name },
        .{ "TOOL_WRITE", tl.write.WriteTool.def.name },
        .{ "TOOL_EDIT", tl.edit.EditTool.def.name },
        .{ "TOOL_PATCH", tl.patch.PatchTool.def.name },
        .{ "TOOL_AGENT", tl.agent.AgentTool.def.name },
        .{ "TOOL_LIST_TASKS", tl.tasks.ListTasksTool.def.name },
        .{ "TOOL_UPDATE_TASK_STATE", tl.tasks.UpdateTaskStateTool.def.name },
        .{ "TOOL_CREATE_TASK", tl.tasks.CreateTaskTool.def.name },
        .{ "TOOL_ASK", tl.ask.AskTool.def.name },
        .{ "TOOL_ENTER_SSH", tl.ssh.EnterSshMode.def.name },
        .{ "TOOL_EXIT_SSH", tl.ssh.ExitSshMode.def.name },
    }) |pair| {
        setFieldAny(L, -2, pair[0], pair[1]);
    }

    // blitz.queue.* — thread-safe command queue bindings
    c.lua_newtable(L);

    inline for (.{
        .{ "reset_session", &luaQueueResetSession },
        .{ "cancel", &luaQueueCancel },
        .{ "retry", &luaQueueRetry },
        .{ "compact", &luaQueueCompact },
        .{ "set_mode", &luaQueueSetMode },
        .{ "push_chat_entry", &luaQueuePushChatEntry },
        .{ "queue_agent_message", &luaQueueAgentMessage },
        .{ "spawn_agent", &luaQueueSpawnAgent },
        .{ "await_agent", &luaSwarmAwaitAgent },
        .{ "await_agent_result", &luaSwarmAwaitAgentResult },
        .{ "save_session", &luaSaveSession },
        .{ "load_session", &luaLoadSession },
        .{ "attach_screenshot", &luaQueueAttachScreenshot },
    }) |binding| {
        setCFunctionField(L, -2, binding[0], binding[1]);
    }

    setFieldPushed(L, -2, "queue");

    c.lua_setglobal(L, "blitz");
}

fn luaPrintToBuffer(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const vm = getVmFromRegistry(state) orelse return 0;
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

fn luaBlitzOk(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    pushStatusTable(state, RET_OK, "");
    return 1;
}

fn luaBlitzErr(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    pushStatusTable(state, RET_ERR, "error");
    return 1;
}

fn luaJsonEncode(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const vm = getVmFromRegistry(state) orelse {
        return pushNilBool(state, false);
    };
    const json = luaToJsonAlloc(vm.luaArena(), state, 1) catch {
        return pushNilBool(state, false);
    };

    _ = c.lua_pushlstring(state, json.ptr, json.len);
    c.lua_pushboolean(state, 1);
    return 2;
}

fn luaJsonDecode(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const vm = getVmFromRegistry(state) orelse {
        return pushNilBool(state, false);
    };
    if (c.lua_type(state, 1) != c.LUA_TSTRING) {
        return pushNilBool(state, false);
    }

    var len: usize = 0;
    const ptr = c.lua_tolstring(state, 1, &len) orelse {
        return pushNilBool(state, false);
    };

    pushJsonValue(vm.luaArena(), state, ptr[0..len]) catch {
        return pushNilBool(state, false);
    };
    c.lua_pushboolean(state, 1);
    return 2;
}

pub fn getAppFromRegistry(L: *c.lua_State) ?*app.App {
    _ = c.lua_rawgetp(L, c.LUA_REGISTRYINDEX, @ptrCast(&app_registry_key));
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TLIGHTUSERDATA) return null;
    const ptr = c.lua_touserdata(L, -1) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn getVmFromRegistry(L: *c.lua_State) ?*LuaVm {
    _ = c.lua_rawgetp(L, c.LUA_REGISTRYINDEX, @ptrCast(&vm_registry_key));
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TLIGHTUSERDATA) return null;
    const ptr = c.lua_touserdata(L, -1) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn getCfgFromRegistry(L: *c.lua_State) ?*prv.config.BlitzdenkCfg {
    const a = getAppFromRegistry(L) orelse return null;
    return @constCast(a.swarm.cfg);
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
    if (std.mem.eql(u8, type_str, "anthropic")) return .anthropic;
    if (std.mem.eql(u8, type_str, "ollama")) return .ollama;
    _ = c.luaL_error(state, "add_provider: unknown type (expected openai/anthropic/ollama)");
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

fn readReasoning(state: *c.lua_State, sub_idx: c_int, slot: *prv.config.Provider) prv.adapter.Reasoning {
    _ = c.lua_getfield(state, sub_idx, "effort");
    defer c.lua_pop(state, 1);
    if (c.lua_type(state, -1) != c.LUA_TSTRING) {
        _ = c.luaL_error(state, "add_provider: reasoning.effort must be a string");
    }
    var elen: usize = 0;
    const eptr = c.lua_tolstring(state, -1, &elen);
    if (!slot.setReasoningEffort(eptr[0..elen])) {
        _ = c.luaL_error(state, "add_provider: reasoning.effort too long");
    }
    return .{ .effort = slot.getReasoningEffort() };
}

fn readOpenAiConfig(state: *c.lua_State, table_idx: c_int, slot: *prv.config.Provider) prv.adapter.OpenAiConfig {
    var cfg: prv.adapter.OpenAiConfig = .{};
    cfg.temperature = getOptionalF32(state, table_idx, "temperature");
    cfg.max_tokens = getOptionalU32(state, table_idx, "max_tokens");
    cfg.max_completion_tokens = getOptionalU32(state, table_idx, "max_completion_tokens");
    cfg.top_p = getOptionalF32(state, table_idx, "top_p");
    cfg.frequency_penalty = getOptionalF32(state, table_idx, "frequency_penalty");
    cfg.presence_penalty = getOptionalF32(state, table_idx, "presence_penalty");
    cfg.enable_thinking = getOptionalBool(state, table_idx, "enable_thinking");

    _ = c.lua_getfield(state, table_idx, "reasoning");
    if (c.lua_type(state, -1) == c.LUA_TTABLE) {
        cfg.reasoning = readReasoning(state, c.lua_gettop(state), slot);
    }
    c.lua_pop(state, 1);

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

fn readOllamaConfig(state: *c.lua_State, table_idx: c_int, _: *prv.config.Provider) prv.adapter.OllamaConfig {
    return .{
        .temperature = getOptionalF32(state, table_idx, "temperature"),
        .max_tokens = getOptionalU32(state, table_idx, "max_tokens"),
        .top_p = getOptionalF32(state, table_idx, "top_p"),
        .top_k = getOptionalU32(state, table_idx, "top_k"),
    };
}

fn luaAddProvider(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;

    const cfg = getCfgFromRegistry(state) orelse {
        _ = c.luaL_error(state, "add_provider: config not initialized");
        return 0;
    };

    if (c.lua_type(state, 1) != c.LUA_TTABLE) {
        _ = c.luaL_error(state, "add_provider: expected a single table argument");
        return 0;
    }

    const type_str = requireStringFieldOnStack(state, 1, "type");
    const ptype = parseProviderType(state, type_str);
    c.lua_pop(state, 1);

    // Both url and key_envar slices must remain valid until reserveProvider
    // has copied them into the slot buffers. Keep both fields on the stack
    // simultaneously, then pop them together.
    const url = requireStringFieldOnStack(state, 1, "url");
    const key_envar = requireStringFieldOnStack(state, 1, "key_envar");
    const slot = cfg.reserveProvider(url, key_envar) orelse {
        _ = c.luaL_error(state, "add_provider: failed (max %d providers or url/key too long)", @as(c_int, prv.config.MAX_PROVIDERS));
        return 0;
    };
    c.lua_pop(state, 2);

    slot.provider_config = switch (ptype) {
        .openai => .{ .openai = readOpenAiConfig(state, 1, slot) },
        .anthropic => .{ .anthropic = readAnthropicConfig(state, 1, slot) },
        .ollama => .{ .ollama = readOllamaConfig(state, 1, slot) },
    };

    const handle = cfg.commitProvider();
    c.lua_pushinteger(state, @intCast(@intFromEnum(handle)));
    return 1;
}

fn luaSetModel(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;

    const cfg = getCfgFromRegistry(state) orelse {
        _ = c.luaL_error(state, "set_model: config not initialized");
        return 0;
    };

    const effort_str = readAnyArg([]const u8, state, "set_model", 1) orelse return 0;

    const effort: prv.config.EffortLevel = if (std.mem.eql(u8, effort_str, "max"))
        .max
    else if (std.mem.eql(u8, effort_str, "mid"))
        .mid
    else if (std.mem.eql(u8, effort_str, "min"))
        .min
    else {
        _ = c.luaL_error(state, "set_model: unknown effort (expected max/mid/min)");
        return 0;
    };

    const model = readAnyArg([]const u8, state, "set_model", 2) orelse return 0;
    const handle: prv.config.ProviderHandle = @enumFromInt(readAnyArg(u32, state, "set_model", 3) orelse return 0);

    if (!cfg.setModel(effort, model, handle)) {
        _ = c.luaL_error(state, "set_model: invalid provider handle or model name too long");
        return 0;
    }

    return 0;
}

fn luaLoadSession(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const a = getAppFromRegistry(state) orelse {
        _ = c.luaL_error(state, "load_session: app not initialized");
        return 0;
    };
    const path = readAnyArg([]const u8, state, "load_session", 1) orelse return 0;
    const cmd: app.Command = .{ .load_session = path };
    appQueueEnqueue(state, "load_session", a, cmd);
    return 0;
}

fn luaSaveSession(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const a = getAppFromRegistry(state) orelse {
        _ = c.luaL_error(state, "save_session: app not initialized");
        return 0;
    };
    const path = readAnyArg([]const u8, state, "save_session", 1) orelse return 0;
    const cmd: app.Command = .{ .save_session = path };
    appQueueEnqueue(state, "save_session", a, cmd);
    return 0;
}

fn luaAddDoc(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const cfg = getCfgFromRegistry(state) orelse {
        _ = c.luaL_error(state, "add_doc: config not initialized");
        return 0;
    };

    const name = readAnyArg([]const u8, state, "add_doc", 1) orelse return 0;
    const desc = readAnyArg([]const u8, state, "add_doc", 2) orelse return 0;
    const loc = readAnyArg([]const u8, state, "add_doc", 3) orelse return 0;

    if (!cfg.addDoc(name, desc, loc)) {
        _ = c.luaL_error(state, "add_doc: failed (max %d docs or field too long)", @as(c_int, prv.config.MAX_DOCS));
        return 0;
    }
    return 0;
}

fn luaTokenUsage(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const a = getAppFromRegistry(state) orelse {
        _ = c.luaL_error(state, "token_usage: app not initialized");
        return 0;
    };
    const usage = a.swarm.usage();

    c.lua_createtable(state, 0, 4);
    setFieldAny(state, -2, "input", usage.input_tokens);
    setFieldAny(state, -2, "output", usage.output_tokens);
    setFieldAny(state, -2, "cache", usage.cached_tokens);
    setFieldAny(state, -2, "cache_creation", usage.cache_creation_tokens);
    return 1;
}

fn luaContextPercent(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const a = getAppFromRegistry(state) orelse {
        _ = c.luaL_error(state, "context_percent: app not initialized");
        return 0;
    };
    c.lua_pushnumber(state, @floatCast(a.contextPercent()));
    return 1;
}

fn luaSetCompactEdge(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const a = getAppFromRegistry(state) orelse {
        _ = c.luaL_error(state, "set_compact_edge: app not initialized");
        return 0;
    };
    if (c.lua_type(state, 1) != c.LUA_TNUMBER) {
        _ = c.luaL_error(state, "set_compact_edge: arg 1 (tokens) must be a number");
        return 0;
    }
    const raw = c.lua_tointegerx(state, 1, null);
    if (raw <= 0 or raw > std.math.maxInt(u32)) {
        _ = c.luaL_error(state, "set_compact_edge: token count out of range");
        return 0;
    }
    const limit: u32 = @intCast(raw);
    a.default_context_limit = limit;
    for (&a.swarm.slots) |*slot| {
        const slot_state = slot.state.load(.acquire);
        if (slot_state == .free or slot_state == .reserved) continue;
        slot.agent.context_limit = limit;
    }
    a.dirty = true;
    return 0;
}

/// blitz.bind(vim_key_combo_string, lua func)
fn luaBind(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;

    if (c.lua_type(state, 2) != c.LUA_TFUNCTION) {
        _ = c.luaL_error(state, "bind: arg 2 (func) must be a function");
        return 0;
    }
    const vm = getVmFromRegistry(state) orelse {
        _ = c.luaL_error(state, "bind: vm not initialized");
        return 0;
    };
    if (vm.bind_entries.items.len >= MAX_LUA_BINDS) {
        _ = c.luaL_error(state, "bind: max binds reached (%d)", @as(c_int, MAX_LUA_BINDS));
        return 0;
    }

    const key_str = readAnyArg([]const u8, state, "bind", 1) orelse return 0;

    const parsed = keys.parseKeyString(key_str) orelse {
        _ = c.luaL_error(state, "bind: invalid key string");
        return 0;
    };

    // ref the function (pops it from stack — push a copy first so order doesn't matter)
    c.lua_pushvalue(state, 2);
    const func_ref = c.luaL_ref(state, c.LUA_REGISTRYINDEX);

    vm.bind_entries.appendAssumeCapacity(.{
        .key = parsed,
        .func_ref = func_ref,
        .L = state,
    });
    return 0;
}

fn htmlToMarkdown(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const vm = getVmFromRegistry(state) orelse {
        _ = c.luaL_error(state, "html_to_markdown: lua vm unavailable");
        return 0;
    };

    const html = readAnyArg([]const u8, state, "html_to_markdown", 1) orelse return 0;

    const markdown = tl.parse.htmlToMarkdown(vm.luaArena(), html) catch {
        _ = c.luaL_error(state, "html_to_markdown: failed to convert html");
        return 0;
    };

    _ = c.lua_pushlstring(state, markdown.ptr, markdown.len);
    return 1;
}

/// blitz.add_command(":command", lua func)
fn luaAddCommand(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;

    if (c.lua_type(state, 2) != c.LUA_TFUNCTION) {
        _ = c.luaL_error(state, "add_command: arg 2 (func) must be a function");
        return 0;
    }
    const vm = getVmFromRegistry(state) orelse {
        _ = c.luaL_error(state, "add_command: vm not initialized");
        return 0;
    };
    if (vm.command_entries.items.len >= MAX_LUA_COMMANDS) {
        _ = c.luaL_error(state, "add_command: max commands reached (%d)", @as(c_int, MAX_LUA_COMMANDS));
        return 0;
    }

    const name = readAnyArg([]const u8, state, "add_command", 1) orelse return 0;
    if (name.len == 0 or (name[0] != ':' and name[0] != '/')) {
        _ = c.luaL_error(state, "add_command: command must start with ':' or '/'");
        return 0;
    }
    if (std.mem.indexOfScalar(u8, name, ' ') != null) {
        _ = c.luaL_error(state, "add_command: command must not contain spaces");
        return 0;
    }
    if (name.len > 128) {
        _ = c.luaL_error(state, "add_command: command too long (max %d bytes)", @as(c_int, 128));
        return 0;
    }

    c.lua_pushvalue(state, 2);
    const func_ref = c.luaL_ref(state, c.LUA_REGISTRYINDEX);

    var entry = LuaCommandEntry{
        .name_len = name.len,
        .func_ref = func_ref,
        .L = state,
    };
    @memcpy(entry.name[0..name.len], name);
    vm.command_entries.appendAssumeCapacity(entry);
    return 0;
}

fn luaSetAgentTools(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;

    if (c.lua_type(state, 1) != c.LUA_TNUMBER) {
        _ = c.luaL_error(state, "set_agent_tools: arg 1 (agent type) must be a number (blitz.AGENT_*)");
        return 0;
    }
    const ty_int = c.lua_tointegerx(state, 1, null);
    if (ty_int < 0 or ty_int > std.math.maxInt(u6)) {
        _ = c.luaL_error(state, "set_agent_tools: agent type out of range");
        return 0;
    }
    const agent_type: @import("registry.zig").AgentType = @enumFromInt(@as(u6, @intCast(ty_int)));

    if (c.lua_type(state, 2) != c.LUA_TTABLE) {
        _ = c.luaL_error(state, "set_agent_tools: arg 2 (tools) must be a table of strings");
        return 0;
    }

    const a = getAppFromRegistry(state) orelse {
        _ = c.luaL_error(state, "set_agent_tools: app not initialized");
        return 0;
    };

    const factory = a.context_factory;

    var names_buf: [@import("registry.zig").ContextFactory.MAX_OVERRIDE_TOOLS][]const u8 = undefined;
    var names_count: usize = 0;

    const len = c.lua_rawlen(state, 2);
    for (1..len + 1) |i| {
        if (names_count >= names_buf.len) {
            _ = c.luaL_error(state, "set_agent_tools: too many tool names (max %d)", @as(c_int, @intCast(names_buf.len)));
            return 0;
        }
        _ = c.lua_rawgeti(state, 2, @intCast(i));
        if (c.lua_type(state, -1) != c.LUA_TSTRING) {
            c.lua_pop(state, 1);
            _ = c.luaL_error(state, "set_agent_tools: tool list entry %d is not a string", @as(c_int, @intCast(i)));
            return 0;
        }
        var slen: usize = 0;
        const sptr = c.lua_tolstring(state, -1, &slen);
        names_buf[names_count] = sptr[0..slen];
        names_count += 1;
        c.lua_pop(state, 1);
    }

    factory.setAgentTools(agent_type, names_buf[0..names_count]) catch {
        _ = c.luaL_error(state, "set_agent_tools: failed to apply override");
        return 0;
    };
    return 0;
}

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

fn readPromptArg(state: *c.lua_State, comptime name: []const u8, idx: c_int) ?[]const u8 {
    return readAnyArg([]const u8, state, name, idx);
}

fn luaSetPrompt(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const a = getAppFromRegistry(state) orelse {
        _ = c.luaL_error(state, "set_prompt: app not initialized");
        return 0;
    };
    const agent_type = readEnumArg(state, @import("registry.zig").AgentType, "set_prompt", 1) orelse return 0;
    const prompt = readPromptArg(state, "set_prompt", 2) orelse return 0;
    a.context_factory.setAgentPrompt(agent_type, prompt) catch {
        _ = c.luaL_error(state, "set_prompt: out of memory");
        return 0;
    };
    return 0;
}

fn luaSetModePrompt(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const a = getAppFromRegistry(state) orelse {
        _ = c.luaL_error(state, "set_mode_prompt: app not initialized");
        return 0;
    };
    const mode = readEnumArg(state, @import("registry.zig").Mode, "set_mode_prompt", 1) orelse return 0;
    const prompt = readPromptArg(state, "set_mode_prompt", 2) orelse return 0;
    a.context_factory.setModePrompt(mode, prompt) catch {
        _ = c.luaL_error(state, "set_mode_prompt: out of memory");
        return 0;
    };
    return 0;
}

fn luaSetModePromptSparse(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const a = getAppFromRegistry(state) orelse {
        _ = c.luaL_error(state, "set_mode_prompt_sparse: app not initialized");
        return 0;
    };
    const mode = readEnumArg(state, @import("registry.zig").Mode, "set_mode_prompt_sparse", 1) orelse return 0;
    const prompt = readPromptArg(state, "set_mode_prompt_sparse", 2) orelse return 0;
    a.context_factory.setSparseModePrompt(mode, prompt) catch {
        _ = c.luaL_error(state, "set_mode_prompt_sparse: out of memory");
        return 0;
    };
    return 0;
}

fn luaSetModeName(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const a = getAppFromRegistry(state) orelse {
        _ = c.luaL_error(state, "set_mode_name: app not initialized");
        return 0;
    };
    const mode = readEnumArg(state, @import("registry.zig").Mode, "set_mode_name", 1) orelse return 0;
    const name = readPromptArg(state, "set_mode_name", 2) orelse return 0;
    a.context_factory.setModeName(mode, name) catch {
        _ = c.luaL_error(state, "set_mode_name: out of memory");
        return 0;
    };
    a.dirty = true;
    return 0;
}

// blitz.add_mode(NAME,COLOR,PROMPT,SPARSE)
fn luaAddMode(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const a = getAppFromRegistry(state) orelse {
        _ = c.luaL_error(state, "add_mode: app not initialized");
        return 0;
    };

    const name = readAnyArg([]const u8, state, "add_mode", 1) orelse return 0;
    const color = readAnyArg([]const u8, state, "add_mode", 2) orelse return 0;
    const prompt = readAnyArg([]const u8, state, "add_mode", 3) orelse return 0;
    const sparse = readAnyArg([]const u8, state, "add_mode", 4) orelse return 0;

    const mode = a.context_factory.addMode(
        name,
        prompt,
        sparse,
        color,
    ) catch {
        _ = c.luaL_error(state, "add_mode: out of memory");
        return 0;
    };

    c.lua_pushinteger(state, @intFromEnum(mode));
    return 1;
}

fn luaSetMode(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const a = getAppFromRegistry(state) orelse {
        _ = c.luaL_error(state, "set_mode: app not initialized");
        return 0;
    };
    const mode = readEnumArg(state, @import("registry.zig").Mode, "set_mode", 1) orelse return 0;
    a.mode = mode;
    if (a.main_agent_id) |id| {
        if (a.swarm.getAgent(id)) |agent| agent.flags.force_full_reminder = true;
    }
    a.dirty = true;
    return 0;
}

fn luaLog(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const msg = readAnyArg([]const u8, state, "log", 1) orelse return 0;
    std.log.scoped(.lua).info("{s}", .{msg});
    return 0;
}

fn luaMcpAdd(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;

    if (c.lua_type(state, 1) != c.LUA_TTABLE) {
        _ = c.luaL_error(state, "mcp.add: expected table argument");
        return 0;
    }

    const vm = getVmFromRegistry(state) orelse {
        _ = c.luaL_error(state, "mcp.add: vm not initialized");
        return 0;
    };
    if (vm.mcp_entries.items.len >= MAX_LUA_MCP_SERVERS) {
        _ = c.luaL_error(state, "mcp.add: max servers reached (%d)", @as(c_int, MAX_LUA_MCP_SERVERS));
        return 0;
    }

    var entry: LuaMcpServerEntry = .{};

    entry.name_len = getStringField(state, 1, "name", &entry.name) orelse {
        _ = c.luaL_error(state, "mcp.add: 'name' must be a string (max %d)", @as(c_int, entry.name.len));
        return 0;
    };

    entry.command_len = getStringField(state, 1, "command", &entry.command) orelse {
        _ = c.luaL_error(state, "mcp.add: 'command' must be a string (max %d)", @as(c_int, entry.command.len));
        return 0;
    };

    _ = c.lua_getfield(state, 1, "transport");
    if (c.lua_type(state, -1) == c.LUA_TSTRING) {
        var len: usize = 0;
        const ptr = c.lua_tolstring(state, -1, &len);
        if (!std.mem.eql(u8, ptr[0..len], "stdio")) {
            c.lua_pop(state, 1);
            _ = c.luaL_error(state, "mcp.add: only transport='stdio' is supported");
            return 0;
        }
    }
    c.lua_pop(state, 1);

    if (getStringField(state, 1, "tools_prefix", &entry.tools_prefix)) |len| {
        entry.tools_prefix_len = len;
    } else {
        var w = std.Io.Writer.fixed(&entry.tools_prefix);
        w.print("mcp_{s}_", .{entry.nameSlice()}) catch {
            _ = c.luaL_error(state, "mcp.add: generated tools_prefix too long");
            return 0;
        };
        entry.tools_prefix_len = w.end;
    }

    _ = c.lua_getfield(state, 1, "args");
    if (c.lua_type(state, -1) == c.LUA_TTABLE) {
        const len = c.lua_rawlen(state, -1);
        if (len > MAX_LUA_MCP_ARGS) {
            c.lua_pop(state, 1);
            _ = c.luaL_error(state, "mcp.add: too many args (max %d)", @as(c_int, MAX_LUA_MCP_ARGS));
            return 0;
        }
        for (1..len + 1) |i| {
            _ = c.lua_rawgeti(state, -1, @intCast(i));
            if (c.lua_type(state, -1) != c.LUA_TSTRING) {
                c.lua_pop(state, 2);
                _ = c.luaL_error(state, "mcp.add: args[%d] must be a string", @as(c_int, @intCast(i)));
                return 0;
            }
            var arg_len: usize = 0;
            const arg_ptr = c.lua_tolstring(state, -1, &arg_len);
            if (arg_len > entry.args[i - 1].len) {
                c.lua_pop(state, 2);
                _ = c.luaL_error(state, "mcp.add: args[%d] too long", @as(c_int, @intCast(i)));
                return 0;
            }
            @memcpy(entry.args[i - 1][0..arg_len], arg_ptr[0..arg_len]);
            entry.arg_lens[i - 1] = @intCast(arg_len);
            entry.args_len += 1;
            c.lua_pop(state, 1);
        }
    } else if (c.lua_type(state, -1) != c.LUA_TNIL) {
        c.lua_pop(state, 1);
        _ = c.luaL_error(state, "mcp.add: 'args' must be a table of strings");
        return 0;
    }
    c.lua_pop(state, 1);

    vm.mcp_entries.appendAssumeCapacity(entry);
    c.lua_pushinteger(state, @intCast(vm.mcp_entries.items.len));
    return 1;
}

fn luaMcpEnable(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const vm = getVmFromRegistry(state) orelse {
        _ = c.luaL_error(state, "mcp.enable: vm not initialized");
        return 0;
    };

    if (c.lua_type(state, 1) != c.LUA_TNUMBER) {
        _ = c.luaL_error(state, "mcp.enable: arg 1 (mcp_id) must be a number");
        return 0;
    }
    const raw_id = c.lua_tointegerx(state, 1, null);
    if (raw_id <= 0 or raw_id > vm.mcp_entries.items.len) {
        _ = c.luaL_error(state, "mcp.enable: mcp_id out of range");
        return 0;
    }
    const idx: usize = @intCast(raw_id - 1);

    const agent_type: @import("registry.zig").AgentType = if (c.lua_gettop(state) >= 2 and c.lua_type(state, 2) != c.LUA_TNIL)
        readEnumArg(state, @import("registry.zig").AgentType, "mcp.enable", 2) orelse return 0
    else
        .main;

    vm.mcp_entries.items[idx].enabled_agents.insert(agent_type);

    if (getAppFromRegistry(state)) |a| {
        appQueueEnqueue(state, "mcp.reload", a, .reload_mcp);
    }
    return 0;
}

fn luaRegisterTool(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;

    if (c.lua_type(state, 1) != c.LUA_TTABLE) {
        _ = c.luaL_error(state, "register_tool: expected table argument");
        return 0;
    }

    const vm = getVmFromRegistry(state) orelse {
        _ = c.luaL_error(state, "register_tool: vm not initialized");
        return 0;
    };
    if (vm.tool_entries.items.len >= MAX_LUA_TOOLS) {
        _ = c.luaL_error(state, "register_tool: max tools reached (%d)", @as(c_int, MAX_LUA_TOOLS));
        return 0;
    }

    var entry: LuaToolEntry = .{};
    entry.L = state;

    // name (required)
    entry.name_len = getStringField(state, 1, "name", &entry.name) orelse {
        _ = c.luaL_error(state, "register_tool: 'name' must be a string (max %d)", @as(c_int, entry.name.len));
        return 0;
    };

    // description (required)
    entry.desc_len = getStringField(state, 1, "description", &entry.description) orelse {
        _ = c.luaL_error(state, "register_tool: 'description' must be a string (max %d)", @as(c_int, entry.description.len));
        return 0;
    };

    // schema (string) OR args (table) — at least one required
    if (getStringField(state, 1, "schema", &entry.schema)) |len| {
        entry.schema_len = len;
    } else {
        _ = c.lua_getfield(state, 1, "args");
        if (c.lua_type(state, -1) == c.LUA_TTABLE) {
            const json = argsTableToJsonSchema(state, -1, &entry.schema) catch {
                _ = c.luaL_error(state, "register_tool: failed to convert args to schema");
                return 0;
            };
            entry.schema_len = json.len;
            c.lua_pop(state, 1);
        } else {
            _ = c.luaL_error(state, "register_tool: 'schema' (string) or 'args' (table) required");
            return 0;
        }
    }

    // func (required)
    _ = c.lua_getfield(state, 1, "func");
    if (c.lua_type(state, -1) != c.LUA_TFUNCTION) {
        _ = c.luaL_error(state, "register_tool: 'func' must be a function");
        return 0;
    }
    entry.func_ref = c.luaL_ref(state, c.LUA_REGISTRYINDEX);

    // persistent state table
    c.lua_newtable(state);
    entry.state_ref = c.luaL_ref(state, c.LUA_REGISTRYINDEX);

    vm.tool_entries.appendAssumeCapacity(entry);

    return 0;
}

// ── Trampoline: Zig ToolFn → Lua function call ─────────────────────

// Import provider types used in tool interface
const prv = struct {
    const provider = @import("provider");
    const tool = provider.tool;
    const adapter = provider.adapter;
    const config = provider.config;
};

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
        .cwd = ctx.cwd,
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
        .{ "append_log", &luaAppendLog },
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

    bridge.tool_ctx.updateToolStatus(bridge.tool_call, "{s}", .{ptr[0..len]});
    return 0;
}

fn luaAppendLog(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const bridge = getBridge(state) orelse return 0;

    if (c.lua_type(state, 2) != c.LUA_TSTRING) return 0;

    var len: usize = 0;
    const ptr = c.lua_tolstring(state, 2, &len);
    if (ptr == null) return 0;

    bridge.tool_ctx.appendToolLog(bridge.tool_call, ptr[0..len]);
    return 0;
}

fn luaSetChildId(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const bridge = getBridge(state) orelse return 0;
    const id = readAgentIdArg(state, "ctx.set_child_id", 2);
    bridge.tool_ctx.setToolChild(bridge.tool_call, id);
    return 0;
}

/// Block on the perm event, then push (status_int, payload?) onto the Lua
/// stack. payload is the chosen option string for .choice, the user message
/// for .message, or nil otherwise. Returns 2 (status, payload).
fn awaitPermAndPush(state: *c.lua_State, bridge: *CtxBridge, options: []const []const u8) c_int {
    const ctx = bridge.tool_ctx;
    const req = ctx.swarm.permission_requests.getPtr(bridge.tool_call.id) orelse {
        return pushStatusNil(state, REQ_STATUS_DENIED);
    };
    req.event.wait(ctx.io) catch {
        return pushStatusNil(state, REQ_STATUS_DENIED);
    };
    if (ctx.isCanceled()) {
        return pushStatusNil(state, REQ_STATUS_DENIED);
    }

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

    bridge.tool_ctx.swarm.requestPermission(bridge.tool_call.id, .{
        .agent_id = bridge.tool_ctx.self_id,
        .payload = .{ .ask = .{
            .header = header,
            .question = question,
            .options = options.items,
        } },
    }) catch {
        return pushStatusNil(state, REQ_STATUS_DENIED);
    };

    return awaitPermAndPush(state, bridge, options.items);
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

    bridge.tool_ctx.swarm.requestPermission(bridge.tool_call.id, .{
        .agent_id = bridge.tool_ctx.self_id,
        .payload = .{ .call = .{
            .tool_name = tool_name,
            .tool_arguments = tool_arguments,
        } },
    }) catch {
        return pushStatusNil(state, REQ_STATUS_DENIED);
    };

    return awaitPermAndPush(state, bridge, &.{});
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

    bridge.tool_ctx.swarm.requestPermission(bridge.tool_call.id, .{
        .agent_id = bridge.tool_ctx.self_id,
        .payload = .{ .plan = .{
            .path = path,
            .plan_text = plan_text,
        } },
    }) catch {
        return pushStatusNil(state, REQ_STATUS_DENIED);
    };

    return awaitPermAndPush(state, bridge, &.{});
}

fn luaPushNotification(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const a = getAppFromRegistry(state) orelse {
        _ = c.luaL_error(state, "queue.push_notification: app not initialized");
        return 0;
    };

    const msg = readAnyArg([]const u8, state, "queue.push_notification", 1) orelse return 0;
    appQueueEnqueue(state, "queue.attach_notfication", a, .{ .push_notification = msg });

    return 0;
}

fn luaQueueAttachScreenshot(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const a = getAppFromRegistry(state) orelse {
        _ = c.luaL_error(state, "queue.attach_screenshot: app not initialized");
        return 0;
    };

    const data = readAnyArg([]const u8, state, "queue.attach_screenshot", 1) orelse return 0;
    const media_type = if (c.lua_gettop(state) >= 2 and c.lua_type(state, 2) != c.LUA_TNIL)
        readAnyArg([]const u8, state, "queue.attach_screenshot", 2) orelse return 0
    else
        "image/png";

    appQueueEnqueue(state, "queue.attach_screenshot", a, .{ .attach_screenshot = .{
        .media_type = media_type,
        .data = data,
    } });
    return 0;
}

fn luaShell(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;

    const a = getAppFromRegistry(state) orelse {
        _ = c.luaL_error(state, "shell: app not initialized");
        return 0;
    };

    if (c.lua_type(state, 1) != c.LUA_TSTRING) {
        return pushNilBool(state, false);
    }

    const cmd = readAnyValue([]const u8, state, 1) orelse return pushNilBool(state, false);

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
    const output = if (success)
        result.stdout
    else
        (if (result.stderr.len > 0) result.stderr else result.stdout);

    _ = c.lua_pushlstring(state, output.ptr, output.len);
    c.lua_pushboolean(state, @intFromBool(success));
    return 2;
}

// ── blitz.queue.* — CommandQueue + Swarm reservation bindings ─────────

/// Push AgentId as `{index, generation}` table.
fn pushAgentId(L: *c.lua_State, id: prv.provider.Swarm.AgentId) void {
    c.lua_createtable(L, 0, 2);
    setFieldAny(L, -2, "index", id.index);
    setFieldAny(L, -2, "generation", id.generation);
}

/// Read AgentId from table at `idx`. Reports a Lua error on shape mismatch.
fn readAgentIdArg(state: *c.lua_State, comptime fname: []const u8, idx: c_int) prv.provider.Swarm.AgentId {
    if (c.lua_type(state, idx) != c.LUA_TTABLE) {
        _ = c.luaL_error(state, fname ++ ": agent_id must be a table {index, generation}");
        return .{ .index = 0, .generation = 0 };
    }
    const index = readAnyField(u16, state, idx, "index") orelse {
        _ = c.luaL_error(state, fname ++ ": agent_id.index must be a number");
        return .{ .index = 0, .generation = 0 };
    };

    const generation = readAnyField(u16, state, idx, "generation") orelse {
        _ = c.luaL_error(state, fname ++ ": agent_id.generation must be a number");
        return .{ .index = 0, .generation = 0 };
    };

    return .{
        .index = index,
        .generation = generation,
    };
}

fn appQueueEnqueue(state: *c.lua_State, comptime fname: []const u8, a: *app.App, cmd: app.Command) void {
    a.cmd_queue.append(a.swarm.pool.io, cmd) catch {
        _ = c.luaL_error(state, fname ++ ": command queue full");
    };
}

fn luaQueueResetSession(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const a = getAppFromRegistry(state) orelse {
        _ = c.luaL_error(state, "queue.reset_session: app not initialized");
        return 0;
    };
    appQueueEnqueue(state, "queue.reset_session", a, .reset_session);
    return 0;
}

fn luaQueueCancel(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const a = getAppFromRegistry(state) orelse {
        _ = c.luaL_error(state, "queue.cancel: app not initialized");
        return 0;
    };
    appQueueEnqueue(state, "queue.cancel", a, .cancel);
    return 0;
}

fn luaQueueRetry(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const a = getAppFromRegistry(state) orelse {
        _ = c.luaL_error(state, "queue.retry: app not initialized");
        return 0;
    };
    appQueueEnqueue(state, "queue.retry", a, .retry);
    return 0;
}

fn luaQueueCompact(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const a = getAppFromRegistry(state) orelse {
        _ = c.luaL_error(state, "queue.compact: app not initialized");
        return 0;
    };
    appQueueEnqueue(state, "queue.compact", a, .compact);
    return 0;
}

fn luaQueueSetMode(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const a = getAppFromRegistry(state) orelse {
        _ = c.luaL_error(state, "queue.set_mode: app not initialized");
        return 0;
    };
    const mode = readAnyArg(u8, state, "queue.set_mode", 1) orelse return 0;
    appQueueEnqueue(state, "queue.set_mode", a, .{ .set_mode = mode });
    return 0;
}

fn luaQueuePushChatEntry(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const a = getAppFromRegistry(state) orelse {
        _ = c.luaL_error(state, "queue.push_chat_entry: app not initialized");
        return 0;
    };
    const role_str = readAnyArg([]const u8, state, "queue.push_chat_entry", 1) orelse return 0;
    const role: prv.adapter.Role = if (std.mem.eql(u8, role_str, "system"))
        .system
    else if (std.mem.eql(u8, role_str, "user"))
        .user
    else if (std.mem.eql(u8, role_str, "agent"))
        .agent
    else {
        _ = c.luaL_error(state, "queue.push_chat_entry: role must be 'system'|'user'|'agent'");
        return 0;
    };

    const text = readAnyArg([]const u8, state, "queue.push_chat_entry", 2) orelse return 0;
    const parts = [_]app.ChatEntry.MessagePart{.{ .text = text }};
    appQueueEnqueue(state, "queue.push_chat_entry", a, .{ .push_chat_entry = .{
        .message = .{ .role = role, .parts = &parts },
    } });
    return 0;
}

fn luaQueueAgentMessage(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const a = getAppFromRegistry(state) orelse {
        _ = c.luaL_error(state, "queue.queue_agent_message: app not initialized");
        return 0;
    };
    const id = readAgentIdArg(state, "queue.queue_agent_message", 1);

    const text = readAnyArg([]const u8, state, "queue.queue_agent_message", 2) orelse return 0;
    const parts = [_]prv.adapter.ContentPart{.{ .text = text }};
    appQueueEnqueue(state, "queue.queue_agent_message", a, .{ .queue_agent_message = .{
        .agent_id = id,
        .parts = &parts,
    } });
    return 0;
}

/// blitz.queue.spawn_agent({parent_id?, prompt, agent_type?, tool_budget?, effort?, fork?, level?})
/// Reserves a free slot and returns the new agent_id (or nil if swarm full).
fn luaQueueSpawnAgent(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const a = getAppFromRegistry(state) orelse {
        _ = c.luaL_error(state, "queue.spawn_agent: app not initialized");
        return 0;
    };
    if (c.lua_type(state, 1) != c.LUA_TTABLE) {
        _ = c.luaL_error(state, "queue.spawn_agent: expected a single table argument");
        return 0;
    }

    var args: app.Command.SpawnArgs = .{
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

    if (getOptionalU32(state, 1, "tool_budget")) |b| args.tool_budget = b;

    _ = c.lua_getfield(state, 1, "effort");
    if (c.lua_type(state, -1) == c.LUA_TSTRING) {
        var elen: usize = 0;
        const eptr = c.lua_tolstring(state, -1, &elen);
        const e = eptr[0..elen];
        args.effort = if (std.mem.eql(u8, e, "max"))
            .max
        else if (std.mem.eql(u8, e, "mid"))
            .mid
        else if (std.mem.eql(u8, e, "min"))
            .min
        else {
            _ = c.luaL_error(state, "queue.spawn_agent: effort must be 'max'|'mid'|'min'");
            return 0;
        };
    } else if (c.lua_type(state, -1) != c.LUA_TNIL) {
        _ = c.luaL_error(state, "queue.spawn_agent: effort must be a string");
        return 0;
    }
    c.lua_pop(state, 1);

    if (getOptionalBool(state, 1, "fork")) |f| args.fork = f;

    _ = c.lua_getfield(state, 1, "level");
    if (c.lua_type(state, -1) == c.LUA_TSTRING) {
        var llen: usize = 0;
        const lptr = c.lua_tolstring(state, -1, &llen);
        const lvl = lptr[0..llen];
        args.level = if (std.mem.eql(u8, lvl, "read"))
            .read
        else if (std.mem.eql(u8, lvl, "write"))
            .write
        else {
            _ = c.luaL_error(state, "queue.spawn_agent: level must be 'read'|'write'");
            return 0;
        };
    } else if (c.lua_type(state, -1) != c.LUA_TNIL) {
        _ = c.luaL_error(state, "queue.spawn_agent: level must be a string");
        return 0;
    }
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

    appQueueEnqueue(state, "queue.spawn_agent", a, .{ .spawn_agent = args });
    pushAgentId(state, id);
    return 1;
}

/// Block until the referenced agent reaches a terminal state. Releases the
/// VM mutex while waiting so the awaited agent's own Lua tools can run on
/// other workers; re-acquires before return so the trampoline's defer-unlock
/// stays balanced.
fn luaSwarmAwaitAgent(L: ?*c.lua_State) callconv(.c) c_int {
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

    const s0 = slot.state.load(.acquire);
    switch (s0) {
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

    // Slot generation may have changed if a release+reuse raced us. Re-validate.
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

/// Return the awaited agent's last assistant text, concatenated across
/// .text parts. Caller is expected to invoke this after await_agent
/// returned AWAIT_COMPLETE; returns nil otherwise.
fn luaSwarmAwaitAgentResult(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L.?;
    const a = getAppFromRegistry(state) orelse {
        _ = c.luaL_error(state, "queue.await_agent_result: app not initialized");
        return 0;
    };
    const id = readAgentIdArg(state, "queue.await_agent_result", 1);

    // Walk broadcast in reverse for the latest agent-role entry from this id.
    const entries = a.swarm.broadcast.items;
    var i: usize = entries.len;
    while (i > 0) {
        i -= 1;
        const e = entries[i];
        if (e.agent_id.index != id.index or e.agent_id.generation != id.generation) continue;
        if (e.role != .agent) continue;

        var total: usize = 0;
        for (e.parts) |p| switch (p) {
            .text => |t| total += t.len,
            else => {},
        };
        if (total == 0) {
            _ = c.lua_pushlstring(state, "", 0);
            return 1;
        }

        // luaL_Buffer keeps the string off the Zig heap.
        var b: c.luaL_Buffer = undefined;
        c.luaL_buffinit(state, &b);
        for (e.parts) |p| switch (p) {
            .text => |t| c.luaL_addlstring(&b, t.ptr, t.len),
            else => {},
        };
        c.luaL_pushresult(&b);
        return 1;
    }

    c.lua_pushnil(state);
    return 1;
}

// ── JSON ↔ Lua conversion ──────────────────────────────────────────

/// Serialize a Lua value at `idx` to JSON into `buf`. Returns slice written.
/// Supports: string, number, boolean, nil, table (object/array).
/// Tables with only consecutive integer keys [1..n] → JSON array, else object.
fn luaToJson(L: *c.lua_State, idx: c_int, buf: []u8) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try luaToJsonWriter(L, idx, &w, 0);
    return buf[0..w.end];
}

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
