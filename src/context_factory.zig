///! building agents and prompts
const Self = @This();

const std = @import("std");
const r = @import("root.zig");
const skills_mod = @import("skills.zig");

const CONFIG_DIR = @import("main.zig").DEFAULT_CONFIG_PATH;
const CONTEXT_FILES = .{"AGENTS.md"};
pub const MAX_AGENT_TOOLS = 64;
const MAX_AVAILABLE_SYSTEMS = 32;

// -------------------------------------------------------------------------------
alloc: std.mem.Allocator,
loaded_tools: std.ArrayList(ToolEntry) = .empty,
agent_counter: u32 = 3,
agents: std.EnumArray(AgentType, ?AgentDef) = .initFill(null),
// ---
available_mcp_names: [MAX_AVAILABLE_SYSTEMS][]const u8 = undefined,
available_mcp_count: usize = 0,
cli_checked: bool = false,
cli_installed: [cli_capabilities.len]bool = .{false} ** cli_capabilities.len,
// Arena holds definitions set from Lua. Reset on hot-reload so the
// factory keeps using the embedded defaults until lua re-installs them.
prompt_arena: std.heap.ArenaAllocator,
io: std.Io,
config_dir: ?std.Io.Dir,
skill_dir: ?std.Io.Dir,
skill_names: std.ArrayList([]const u8) = .empty,
skills: skills_mod.SkillRegistry = .{},
cwd: []const u8 = "",
ssh_dir: ?std.Io.Dir = null,
ssh_aliases: std.ArrayList(SshAlias) = .empty,
flags: Flags = .{},
// -------------------------------------------------------------------------------

const CliCapability = struct {
    binary: []const u8,
    guideline: []const u8,
};

const cli_capabilities = [_]CliCapability{
    .{ .binary = "rg", .guideline = "Use rg for fast recursive grep searches. Prefer rg over grep." },
    .{ .binary = "fd", .guideline = "Use fd for fast file discovery. Prefer fd over find." },
    .{ .binary = "jq", .guideline = "Use jq to parse and filter JSON data." },
};

pub const general_default_tool_set = .{
    r.tools.write.WriteTool,
    r.tools.edit.EditTool,
    r.tools.bash.BashTool,
    r.tools.read.ReadTool,
    r.tools.read.ViewImageTool,
    r.tools.agent.AgentTool,
    r.tools.patch.PatchTool,
    r.tools.ask.AskTool,
    r.tools.search.GlobTool,
    r.tools.search.GrepTool,
    r.tools.start.StartMcpTool,
    r.tools.skill.SkillTool,
};

pub const AgentDef = struct {
    name: []const u8,
    description: []const u8,
    prompt: []const u8,
    in_agent_tool: bool = true,
    tools: AgentTools = .{},
    model: ?AgentModelConfig = null,
};

pub const AgentType = enum(u6) {
    pub const Set = std.EnumSet(AgentType);
    general,
    _,
};

pub const ToolFlags = struct {
    allowed_agents: AgentType.Set,
    add_to_agents: bool = false,

    pub const all = ToolFlags{ .allowed_agents = .initFull() };
};

pub const ToolSet = struct {
    set: [64]r.tools.Tool = undefined,
    len: u32 = 0,

    pub fn slice(self: *const ToolSet) []const r.tools.Tool {
        return self.set[0..self.len];
    }
};

const ToolEntry = struct { tool: r.tools.Tool, flags: ToolFlags };

pub const AgentTools = struct {
    names: [MAX_AGENT_TOOLS][255]u8 = undefined,
    name_lens: [MAX_AGENT_TOOLS]u8 = @splat(0),
    len: u8 = 0,

    pub fn nameAt(self: *const AgentTools, i: usize) []const u8 {
        return self.names[i][0..self.name_lens[i]];
    }

    pub fn from(comptime names: []const []const u8) AgentTools {
        if (names.len > MAX_AGENT_TOOLS) @compileError("too many default agent tools");

        var tools: AgentTools = .{};
        inline for (names) |name| {
            if (name.len > 128) @compileError("default agent tool name too long");
            @memcpy(tools.names[tools.len][0..name.len], name);
            tools.name_lens[tools.len] = name.len;
            tools.len += 1;
        }
        return tools;
    }
};

pub const AgentModelConfig = struct {
    model: r.config.ModelHandle,
    effort: r.config.ReasoningEffort = .medium,
};

pub const AgentConfigDiagnostic = union(enum) {
    no_agent_model: []const u8,
    invalid_provider,
    missing_api_key: []const u8,
};

pub const AgentConfigResult = union(enum) {
    config: r.models.Config,
    diagnostic: AgentConfigDiagnostic,
};

pub const NewAgentDef = struct {
    name: []const u8,
    description: []const u8,
    prompt: []const u8,
    in_agent_tool: bool = true,
    tools: []const []const u8 = &.{},
    model: ?AgentModelConfig = null,
};

pub const AgentMeta = struct {
    name: []const u8 = "",
    description: []const u8 = "",
};

pub const Flags = packed struct(u8) {
    skip_local_context_file: bool = false,
    _pad: u7 = 0,
};

fn buildDefaultTools(alloc: std.mem.Allocator) !std.ArrayList(ToolEntry) {
    var list = std.ArrayList(ToolEntry).empty;
    inline for (general_default_tool_set) |tool| {
        try list.append(alloc, .{ .tool = tool, .flags = .all });
    }
    return list;
}

pub fn init(alloc: std.mem.Allocator, io: std.Io, home: []const u8, cwd: []const u8) !*Self {
    var self = try alloc.create(Self);

    var home_dir = try std.Io.Dir.openDirAbsolute(io, home, .{});
    const skill_dir: ?std.Io.Dir = home_dir.openDir(io, CONFIG_DIR ++ "skills/", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    const config_dir: ?std.Io.Dir = home_dir.openDir(io, CONFIG_DIR, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    const ssh_dir: ?std.Io.Dir = home_dir.openDir(io, ".ssh/", .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    self.* = Self{
        .alloc = alloc,
        .loaded_tools = try buildDefaultTools(alloc),
        .prompt_arena = std.heap.ArenaAllocator.init(alloc),
        .io = io,
        .skill_dir = skill_dir,
        .config_dir = config_dir,
        .cwd = cwd,
        .ssh_dir = ssh_dir,
    };

    self.resetDefs();
    self.checkCliCapabilities();
    return self;
}

/// Startup check for useful cli tools. Runs once, then caches the result
/// until the factory is relaunched.
pub fn checkCliCapabilities(self: *Self) void {
    if (self.cli_checked) return;
    self.cli_checked = true;

    for (0..cli_capabilities.len) |i| {
        self.cli_installed[i] = binaryExists(self.io, cli_capabilities[i].binary);
    }
}

pub fn buildAgentApiConfig(
    self: *Self,
    agent_type: AgentType,
    cfg: *r.config.BlitzdenkCfg,
    env: *const std.process.Environ.Map,
) AgentConfigResult {
    const def = self.getAgent(agent_type) orelse return .{ .diagnostic = .invalid_provider };
    if (def.model) |ag_cfg| {
        const model = cfg.getModel(ag_cfg.model) orelse return .{ .diagnostic = .invalid_provider };
        const provider = cfg.getProvider(model.provider) orelse return .{ .diagnostic = .invalid_provider };

        const key = if (provider.key_len > 0)
            env.get(provider.getKeyEnvar()) orelse return .{
                .diagnostic = .{ .missing_api_key = provider.getKeyEnvar() },
            }
        else
            "";

        return .{ .config = .{
            .api_key = key,
            .base_url = provider.getUrl(),
            .model = model.getName(),
            .provider = provider.provider_config,
            .reasoning_effort = ag_cfg.effort,
            .rate_limit = provider.rate_limit,
        } };
    }

    return .{ .diagnostic = .{ .no_agent_model = def.name } };
}

pub fn setAgentPrompt(self: *Self, agent_type: AgentType, prompt: []const u8) !void {
    const def = self.getAgentMut(agent_type) orelse return error.UnknownAgent;
    const dup = try self.prompt_arena.allocator().dupe(u8, prompt);
    def.prompt = dup;
}

pub fn setAgentModel(self: *Self, cfg: *const r.config.BlitzdenkCfg, agent_type: AgentType, model: r.config.ModelHandle, effort: r.config.ReasoningEffort) !void {
    const def = self.getAgentMut(agent_type) orelse return error.UnknownAgent;
    _ = cfg.getModel(model) orelse return error.UnknownModel;
    def.model = .{
        .model = model,
        .effort = effort,
    };
}

pub fn collectUnboundAgents(self: *const Self, alloc: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    for (0..self.agent_counter) |i| {
        const agent_type: AgentType = @enumFromInt(@as(u6, @intCast(i)));
        const def = self.getAgent(agent_type) orelse continue;
        if (def.model == null) try out.append(alloc, def.name);
    }
}

pub fn addAgent(self: *Self, cfg: *const r.config.BlitzdenkCfg, def: NewAgentDef) !AgentType {
    if (self.agent_counter > std.math.maxInt(u6)) return error.TooManyAgents;
    if (self.findAgentType(def.name) != null) return error.DuplicateAgentName;
    if (def.tools.len > MAX_AGENT_TOOLS) return error.TooManyTools;
    for (def.tools) |name| if (name.len > 128) return error.NameTooLong;

    const idx: AgentType = @enumFromInt(self.agent_counter);
    const alloc = self.prompt_arena.allocator();
    self.agents.set(idx, .{
        .name = try alloc.dupe(u8, def.name),
        .description = try alloc.dupe(u8, def.description),
        .prompt = try alloc.dupe(u8, def.prompt),
        .in_agent_tool = def.in_agent_tool,
        .model = if (def.model) |model| blk: {
            _ = cfg.getModel(model.model) orelse return error.UnknownModel;
            break :blk .{
                .model = model.model,
                .effort = model.effort,
            };
        } else null,
    });
    try self.setAgentTools(idx, def.tools);
    self.agent_counter += 1;
    return idx;
}

pub fn findAgentType(self: *const Self, name: []const u8) ?AgentType {
    for (0..self.agent_counter) |i| {
        const agent_type: AgentType = @enumFromInt(@as(u6, @intCast(i)));
        const def = self.getAgent(agent_type) orelse continue;
        if (std.mem.eql(u8, def.name, name)) return agent_type;
    }
    return null;
}

pub fn agentName(self: *const Self, agent_type: AgentType) []const u8 {
    return if (self.getAgent(agent_type)) |def| def.name else "UNKNOWN";
}

fn getAgent(self: *const Self, agent_type: AgentType) ?*const AgentDef {
    return if (self.agents.getPtrConst(agent_type).*) |*def| def else null;
}

fn getAgentMut(self: *Self, agent_type: AgentType) ?*AgentDef {
    return if (self.agents.getPtr(agent_type).*) |*def| def else null;
}

/// A connectable alias resolved from ~/.ssh/config.
pub const SshAlias = struct {
    name: []const u8,
    user: []const u8,
    host: []const u8,
    cwd: []const u8,
};

const SshKeys = struct {
    user: ?[]const u8 = null,
    host_name: ?[]const u8 = null,
    directory: ?[]const u8 = null,
};

fn mergeSshKeys(dst: *SshKeys, src: SshKeys) void {
    if (src.user) |v| dst.user = v;
    if (src.host_name) |v| dst.host_name = v;
    if (src.directory) |v| dst.directory = v;
}

fn freeSshAliases(alloc: std.mem.Allocator, aliases: []SshAlias) void {
    for (aliases) |a| {
        alloc.free(a.name);
        alloc.free(a.user);
        alloc.free(a.host);
        alloc.free(a.cwd);
    }
}

const SshBlock = struct {
    name: []const u8,
    keys: SshKeys,
};

const SshBlockState = enum { none, default, named, skipped };

/// Parse the contents of ~/.ssh/config into connectable aliases.
/// Global keys and `Host *` blocks provide defaults, later blocks win.
/// Named hosts need a resolvable user; wildcard or multi-name hosts are skipped.
fn parseSshAliases(alloc: std.mem.Allocator, content: []const u8) !std.ArrayList(SshAlias) {
    var list = std.ArrayList(SshAlias).empty;
    errdefer {
        freeSshAliases(alloc, list.items);
        list.deinit(alloc);
    }

    var defaults = SshKeys{};
    var named = std.ArrayList(SshBlock).empty;
    defer named.deinit(alloc);

    const flush = struct {
        fn call(
            blocks: *std.ArrayList(SshBlock),
            a: std.mem.Allocator,
            dflts: *SshKeys,
            state: SshBlockState,
            name: []const u8,
            keys: SshKeys,
        ) !void {
            switch (state) {
                .default => mergeSshKeys(dflts, keys),
                .named => try blocks.append(a, .{ .name = name, .keys = keys }),
                else => {},
            }
        }
    }.call;

    var state: SshBlockState = .none;
    var cur_name: []const u8 = undefined;
    var cur_keys = SshKeys{};

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const hash = std.mem.indexOfScalar(u8, line, '#') orelse line.len;
        const body = std.mem.trim(u8, line[0..hash], " \t");
        if (body.len == 0) continue;

        const sep = std.mem.indexOfAny(u8, body, " \t=") orelse continue;
        const key = body[0..sep];
        const value = std.mem.trim(u8, body[sep..], " \t=");

        if (std.ascii.eqlIgnoreCase(key, "host")) {
            try flush(&named, alloc, &defaults, state, cur_name, cur_keys);
            cur_keys = .{};
            state = .skipped;
            if (value.len > 0) {
                if (std.mem.indexOfAny(u8, value, "*?") != null) {
                    if (std.mem.eql(u8, value, "*")) state = .default;
                } else if (std.mem.indexOfAny(u8, value, " \t") == null) {
                    state = .named;
                    cur_name = value;
                }
            }
            continue;
        }

        switch (state) {
            .none => {
                if (std.ascii.eqlIgnoreCase(key, "user")) {
                    if (defaults.user == null) defaults.user = value;
                } else if (std.ascii.eqlIgnoreCase(key, "hostname")) {
                    if (defaults.host_name == null) defaults.host_name = value;
                } else if (std.ascii.eqlIgnoreCase(key, "directory")) {
                    if (defaults.directory == null) defaults.directory = value;
                }
            },
            .default, .named => {
                if (std.ascii.eqlIgnoreCase(key, "user")) {
                    if (cur_keys.user == null) cur_keys.user = value;
                } else if (std.ascii.eqlIgnoreCase(key, "hostname")) {
                    if (cur_keys.host_name == null) cur_keys.host_name = value;
                } else if (std.ascii.eqlIgnoreCase(key, "directory")) {
                    if (cur_keys.directory == null) cur_keys.directory = value;
                }
            },
            .skipped => {},
        }
    }
    try flush(&named, alloc, &defaults, state, cur_name, cur_keys);

    for (named.items) |b| {
        const user = b.keys.user orelse defaults.user orelse continue;
        const host = b.keys.host_name orelse defaults.host_name orelse b.name;
        const cwd = b.keys.directory orelse defaults.directory orelse "/";
        const name_d = try alloc.dupe(u8, b.name);
        errdefer alloc.free(name_d);
        const user_d = try alloc.dupe(u8, user);
        errdefer alloc.free(user_d);
        const host_d = try alloc.dupe(u8, host);
        errdefer alloc.free(host_d);
        const cwd_d = try alloc.dupe(u8, cwd);
        errdefer alloc.free(cwd_d);
        try list.append(alloc, .{ .name = name_d, .user = user_d, .host = host_d, .cwd = cwd_d });
    }
    return list;
}

/// Load the connectable aliases from ~/.ssh/config into a gpa-backed buffer,
/// replacing any previous contents. Called on startup and on hot-reload.
fn loadSshAliases(self: *Self) void {
    freeSshAliases(self.alloc, self.ssh_aliases.items);
    self.ssh_aliases.deinit(self.alloc);
    self.ssh_aliases = .empty;

    const dir = self.ssh_dir orelse return;
    const content = dir.readFileAlloc(self.io, "config", self.alloc, .limited64(1024 * 1024)) catch return;
    defer self.alloc.free(content);
    self.ssh_aliases = parseSshAliases(self.alloc, content) catch return;
}

/// Look up a connectable alias by its Host name, case-insensitively.
pub fn findSshAlias(self: *const Self, name: []const u8) ?SshAlias {
    for (self.ssh_aliases.items) |alias| {
        if (std.ascii.eqlIgnoreCase(alias.name, name)) return alias;
    }
    return null;
}

pub fn rescanSkills(self: *Self, cwd: []const u8) void {
    self.cwd = cwd;
    self.skills.scan(self.alloc, self.io, self.skill_dir, self.cwd);
    self.rebuildSkillNames();
}

fn rebuildSkillNames(self: *Self) void {
    for (self.skill_names.items) |name| self.alloc.free(name);
    self.skill_names.clearRetainingCapacity();
    for (self.skills.entries.items) |entry| {
        const dup = self.alloc.dupe(u8, entry.meta.name) catch continue;
        self.skill_names.append(self.alloc, dup) catch {
            self.alloc.free(dup);
            return;
        };
    }
}

/// Restore embedded defaults and free any Lua-installed definitions.
pub fn resetDefs(self: *Self) void {
    _ = self.prompt_arena.reset(.retain_capacity);
    self.agent_counter = 3;
    self.available_mcp_count = 0;
    self.agents = .initFill(null);

    self.agents.set(.general, .{
        .name = @tagName(AgentType.general),
        .description =
        \\General purpose builder agent with full tool access.
        \\
        ,
        .prompt = @embedFile("prompts/default.md"),
        .tools = .from(&.{
            r.tools.write.WriteTool.def.name,
            r.tools.edit.EditTool.def.name,
            r.tools.bash.BashTool.def.name,
            r.tools.read.ReadTool.def.name,
            r.tools.read.ViewImageTool.def.name,
            r.tools.agent.AgentTool.def.name,
            r.tools.ask.AskTool.def.name,
            r.tools.start.StartMcpTool.def.name,
            r.tools.skill.SkillTool.def.name,
        }),
    });

    self.rescanSkills(self.cwd);
    self.loadSshAliases();
}

pub fn add(self: *Self, tool: r.tools.Tool, flags: ToolFlags) !void {
    try self.loaded_tools.append(self.alloc, .{ .tool = tool, .flags = flags });
}

pub fn setAvailableSystems(self: *Self, mcp_names: []const []const u8) !void {
    const alloc = self.prompt_arena.allocator();
    self.available_mcp_count = 0;

    for (mcp_names[0..@min(mcp_names.len, MAX_AVAILABLE_SYSTEMS)]) |name| {
        self.available_mcp_names[self.available_mcp_count] = try alloc.dupe(u8, name);
        self.available_mcp_count += 1;
    }
}

pub fn remove(self: *Self, tool_name: []const u8) void {
    for (0..self.loaded_tools.items.len) |i| {
        const idx = self.loaded_tools.items.len - i - 1;
        const en = &self.loaded_tools.items[idx];
        if (std.mem.eql(u8, en.tool.def.name, tool_name)) {
            _ = self.loaded_tools.swapRemove(idx);
            return;
        }
    }
}

pub fn configureAgent(
    self: *const Self,
    cfg: *const r.config.BlitzdenkCfg,
    agent: *r.agent.Agent,
    base: r.tools.context.BaseContext,
) !void {
    try self.refreshAgentTools(cfg, agent, base);
    const alloc = agent.state_arena.allocator();
    const prompt = try self.build_system_prompt(alloc, @enumFromInt(agent.type_idx));
    try agent.setSystemPrompt(prompt);
}

pub fn agentVision(self: *const Self, cfg: *const r.config.BlitzdenkCfg, agent_type: AgentType) bool {
    if (self.getAgent(agent_type)) |def| {
        if (def.model) |m| {
            const model = cfg.getModel(m.model) orelse return false;
            return model.vision;
        }
    }
    return false;
}

pub fn refreshAgentTools(self: *const Self, cfg: *const r.config.BlitzdenkCfg, agent: *r.agent.Agent, base: r.tools.context.BaseContext) !void {
    try self.refreshAgentToolsInternal(cfg, agent, base, false);
}

pub fn refreshAgentToolsLive(self: *const Self, cfg: *const r.config.BlitzdenkCfg, agent: *r.agent.Agent, base: r.tools.context.BaseContext) !void {
    try self.refreshAgentToolsInternal(cfg, agent, base, true);
}

fn refreshAgentToolsInternal(self: *const Self, cfg: *const r.config.BlitzdenkCfg, agent: *r.agent.Agent, base: r.tools.context.BaseContext, live: bool) !void {
    const alloc = agent.state_arena.allocator();
    var definitions: [MAX_AGENT_TOOLS]r.tools.Tool = undefined;
    var count: usize = 0;
    const vision = self.agentVision(cfg, @enumFromInt(agent.type_idx));
    var it = self.iter(@enumFromInt(agent.type_idx));
    while (it.next()) |tool| {
        if (std.mem.eql(u8, tool.def.name, r.tools.read.ViewImageTool.def.name) and !vision) continue;
        if (std.mem.eql(u8, tool.def.name, r.tools.agent.AgentTool.def.name)) {
            var buf: [64]AgentMeta = undefined;
            var out = std.ArrayList(AgentMeta).initBuffer(&buf);

            for (0..64) |i| {
                const def = self.getAgent(@enumFromInt(i)) orelse continue;
                if (!def.in_agent_tool) continue;
                out.appendBounded(.{ .name = def.name, .description = def.description }) catch unreachable;
            }

            const def = try r.tools.agent.dynamic_def(alloc, out.items);

            var dynamic = tool;
            dynamic.def.description = def.desc;
            dynamic.def.parameters_schema = def.schema;
            definitions[count] = dynamic;
            count += 1;
            continue;
        }
        definitions[count] = tool;
        count += 1;
    }
    if (live) try r.tools.context.installLive(agent, base, definitions[0..count]) else try r.tools.context.install(agent, base, definitions[0..count]);
}

fn findLoaded(self: *const Self, name: []const u8) ?r.tools.Tool {
    for (self.loaded_tools.items) |entry| {
        if (std.mem.eql(u8, entry.tool.def.name, name)) return entry.tool;
    }
    return null;
}

const ToolIter = struct {
    factory: *const Self,
    agent_type: AgentType,
    i: u32 = 0,
    listed_tools_done: bool = false,
    pub fn next(self: *ToolIter) ?r.tools.Tool {
        const def = self.factory.getAgent(self.agent_type) orelse return null;
        const tools = &def.tools;
        if (!self.listed_tools_done) {
            while (self.i < tools.len) {
                const idx = self.i;
                self.i += 1;
                const name = tools.nameAt(idx);
                if (self.factory.findLoaded(name)) |tool| return tool;
            }
            self.listed_tools_done = true;
            self.i = 0;
        }
        while (self.i < self.factory.loaded_tools.items.len) {
            const en = self.factory.loaded_tools.items[self.i];
            self.i += 1;
            if (!en.flags.add_to_agents) continue;
            if (!en.flags.allowed_agents.contains(self.agent_type)) continue;
            if (contains(tools, en.tool.def.name)) continue;
            return en.tool;
        }
        return null;
    }

    fn contains(tools: *const AgentTools, name: []const u8) bool {
        for (0..tools.len) |idx| {
            if (std.mem.eql(u8, tools.nameAt(idx), name)) return true;
        }
        return false;
    }
};

pub fn iter(self: *const Self, agent_type: AgentType) ToolIter {
    return .{ .factory = self, .agent_type = agent_type };
}

fn agentHasTool(self: *const Self, agent_type: AgentType, name: []const u8) bool {
    var it = self.iter(agent_type);
    while (it.next()) |tool| {
        if (std.mem.eql(u8, tool.def.name, name)) return true;
    }
    return false;
}

pub fn build_toolset(self: *Self, agent_type: AgentType, out: *ToolSet) !void {
    out.len = 0;
    var it = self.iter(agent_type);
    while (it.next()) |tool| {
        if (out.len >= 64) return error.ToolLimitReachedSetTruncated;
        out.set[out.len] = tool;
        out.len += 1;
    }
}

pub fn setAgentTools(self: *Self, agent_type: AgentType, names: []const []const u8) !void {
    var tools = &(self.getAgentMut(agent_type) orelse return error.UnknownAgent).tools;
    if (names.len > MAX_AGENT_TOOLS) return error.TooManyTools;
    tools.len = 0;
    for (names) |name| {
        if (name.len > 128) return error.NameTooLong;
        @memcpy(tools.names[tools.len][0..name.len], name);
        tools.name_lens[tools.len] = @intCast(name.len);
        tools.len += 1;
    }
}

pub fn addAgentTool(self: *Self, agent_type: AgentType, name: []const u8) !void {
    var tools = &(self.getAgentMut(agent_type) orelse return error.UnknownAgent).tools;
    if (tools.len >= MAX_AGENT_TOOLS) return error.TooManyTools;
    if (name.len > 128) return error.NameTooLong;

    for (0..tools.len) |i| {
        const len = tools.name_lens[i];
        if (len == 0) continue;

        const existing = tools.names[i][0..len];
        if (std.mem.eql(u8, existing, name)) return;
    }

    @memcpy(tools.names[tools.len][0..name.len], name);
    tools.name_lens[tools.len] = @intCast(name.len);
    tools.len += 1;
}

pub fn resetLoadedTools(self: *Self) !void {
    self.loaded_tools.deinit(self.alloc);
    self.loaded_tools = try buildDefaultTools(self.alloc);
}

pub fn deinit(self: *Self) void {
    self.loaded_tools.deinit(self.alloc);
    for (self.skill_names.items) |name| self.alloc.free(name);
    self.skill_names.deinit(self.alloc);
    self.skills.deinit(self.alloc);
    freeSshAliases(self.alloc, self.ssh_aliases.items);
    self.ssh_aliases.deinit(self.alloc);
    self.prompt_arena.deinit();
    self.alloc.destroy(self);
}

pub fn build_system_prompt(
    self: *const Self,
    alloc: std.mem.Allocator,
    agent_type: AgentType,
) ![]const u8 {
    var allocating = std.Io.Writer.Allocating.init(alloc);
    var w = &allocating.writer;

    const def = self.getAgent(agent_type) orelse return error.UnknownAgent;
    _ = try w.write(def.prompt);
    try w.writeByte('\n');

    var wrote_tools_header = false;
    for (0..def.tools.len) |i| {
        const tool = self.findLoaded(def.tools.nameAt(i)) orelse continue;
        if (tool.def.prompt_snippet) |snippet| {
            if (!wrote_tools_header) {
                _ = try w.write(
                    \\
                    \\# Available tools:
                    \\
                );
                wrote_tools_header = true;
            }
            try w.print("- {s}: {s}\n", .{ tool.def.name, snippet });
        }
    }

    var wrote_guidelines_header = false;
    for (0..def.tools.len) |i| {
        const tool = self.findLoaded(def.tools.nameAt(i)) orelse continue;
        if (tool.def.prompt_guidelines) |guidelines| {
            if (!wrote_guidelines_header) {
                _ = try w.write(
                    \\
                    \\# Guidelines:
                    \\
                );
                wrote_guidelines_header = true;
            }
            try w.print("- {s}\n", .{guidelines});
        }
    }

    if (self.agentHasTool(agent_type, r.tools.skill.SkillTool.def.name)) {
        try w.writeAll(
            \\
            \\# Skills:
            \\Call the `skill` tool when the task matches a skill's trigger rules.
            \\
        );
    }

    if (self.available_mcp_count > 0 and self.agentHasTool(agent_type, r.tools.start.StartMcpTool.def.name)) {
        try w.writeAll(
            \\
            \\# Available mcp:
            \\
        );
        for (self.available_mcp_names[0..self.available_mcp_count]) |name| {
            try w.print("- name: \"{s}\"\n", .{name});
        }
    }

    _ = try w.write(
        \\
        \\# User context (AGENTS.md):
        \\
    );

    // global context
    if (self.config_dir) |dir| {
        inline for (CONTEXT_FILES) |context_file| {
            var buf: [255]u8 = undefined;
            if (dir.openFile(self.io, context_file, .{})) |user_ctx_file| {
                var filer_reader = user_ctx_file.reader(self.io, &buf);
                _ = try std.Io.Reader.streamRemaining(&filer_reader.interface, w);
                try w.writeAll("\n\n");
            } else |_| {}
        }
    }

    try w.writeAll("\n\n");

    // local context
    if (!self.flags.skip_local_context_file) {
        inline for (CONTEXT_FILES) |context_file| {
            if (std.Io.Dir.cwd().openFile(self.io, context_file, .{})) |user_ctx_file| {
                var buf: [100]u8 = undefined;
                var filer_reader = user_ctx_file.reader(self.io, &buf);
                _ = try std.Io.Reader.streamRemaining(&filer_reader.interface, w);
                try w.writeAll("\n\n");
            } else |_| {}
        }
    }

    if (self.agentHasTool(agent_type, r.tools.bash.BashTool.def.name)) {
        var wrote_cli_header = false;
        for (0..cli_capabilities.len) |i| {
            if (!self.cli_installed[i]) continue;
            if (!wrote_cli_header) {
                _ = try w.write(
                    \\
                    \\# Envirement:
                    \\
                );
                wrote_cli_header = true;
            }
            try w.print("- {s}: {s}\n", .{ cli_capabilities[i].binary, cli_capabilities[i].guideline });
        }
    }

    return allocating.written();
}

const ParsedCommand = struct {
    name: []const u8,
    rest: []const u8,
};

pub fn parsePrefixedCommand(raw: []const u8, prefix: []const u8) ?ParsedCommand {
    if (raw.len == 0 or raw[0] != '/') return null;
    const rest = raw[1..];
    if (!std.mem.startsWith(u8, rest, prefix)) return null;
    const after = rest[prefix.len..];
    if (after.len == 0) return null;
    const space = std.mem.indexOfScalar(u8, after, ' ');
    const name = if (space) |idx| after[0..idx] else after;
    if (name.len == 0) return null;
    const tail = if (space) |idx| after[idx + 1 ..] else "";
    return .{ .name = name, .rest = tail };
}

/// /ssh-<alias> → the alias name, or null.
pub fn parseSshAliasCommand(raw: []const u8) ?[]const u8 {
    const parsed = parsePrefixedCommand(raw, "ssh-") orelse return null;
    return parsed.name;
}

/// Checks whether `binary` can be resolved on the PATH. Uses `sh -c "command -v"`.
fn binaryExists(io: std.Io, binary: []const u8) bool {
    var buf: [256]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, "command -v {s} >/dev/null 2>&1", .{binary}) catch return false;
    const argv = [_][]const u8{ "sh", "-c", cmd };

    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    defer if (child.id != null) child.kill(io);
    const term = child.wait(io) catch return false;
    return term == .exited and term.exited == 0;
}

test "ssh alias command parse" {
    const Case = struct { in: []const u8, name: ?[]const u8 };
    const cases = [_]Case{
        .{ .in = "/ssh-mc", .name = "mc" },
        .{ .in = "/ssh-mc do it", .name = "mc" },
        .{ .in = "/ssh", .name = null },
        .{ .in = "/ssh-", .name = null },
        .{ .in = "/foo", .name = null },
        .{ .in = ":clear", .name = null },
        .{ .in = "/plan", .name = null },
        .{ .in = "ssh-mc", .name = null },
    };
    for (cases) |c| {
        const got = parseSshAliasCommand(c.in);
        if (c.name) |n| {
            try std.testing.expectEqualStrings(n, got.?);
        } else {
            try std.testing.expect(got == null);
        }
    }
}

test "ssh config parse resolves aliases, defaults and skips" {
    const content =
        \\User global
        \\Host *
        \\    User default
        \\    Directory /srv
        \\
        \\Host laptop
        \\    HostName 192.168.1.151
        \\    User lommix
        \\
        \\Host prod *.wild
        \\    User root
        \\
        \\Host noport
        \\    HostName example.com
        \\    Port 2222
        \\    Directory /opt
        \\
        \\Host nouser
        \\    HostName nope.example.com
        \\
        \\Host bare
        \\
        \\Host multi one two
        \\    User x
        \\
        \\Host wild-?
        \\    User y
        \\
        \\Host =
        \\    User z
        \\
    ;
    var list = try parseSshAliases(std.testing.allocator, content);
    defer {
        freeSshAliases(std.testing.allocator, list.items);
        list.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 4), list.items.len);

    try std.testing.expectEqualStrings("laptop", list.items[0].name);
    try std.testing.expectEqualStrings("lommix", list.items[0].user);
    try std.testing.expectEqualStrings("192.168.1.151", list.items[0].host);
    try std.testing.expectEqualStrings("/srv", list.items[0].cwd);

    try std.testing.expectEqualStrings("noport", list.items[1].name);
    try std.testing.expectEqualStrings("default", list.items[1].user);
    try std.testing.expectEqualStrings("example.com", list.items[1].host);
    try std.testing.expectEqualStrings("/opt", list.items[1].cwd);

    try std.testing.expectEqualStrings("nouser", list.items[2].name);
    try std.testing.expectEqualStrings("default", list.items[2].user);
    try std.testing.expectEqualStrings("nope.example.com", list.items[2].host);
    try std.testing.expectEqualStrings("/srv", list.items[2].cwd);

    try std.testing.expectEqualStrings("bare", list.items[3].name);
    try std.testing.expectEqualStrings("default", list.items[3].user);
    try std.testing.expectEqualStrings("bare", list.items[3].host);
    try std.testing.expectEqualStrings("/srv", list.items[3].cwd);
}

test "agent defaults can be replaced with an empty tool list" {
    var factory = Self{
        .alloc = std.testing.allocator,
        .prompt_arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .io = undefined,
        .config_dir = null,
        .skill_dir = null,
    };
    defer factory.prompt_arena.deinit();
    defer factory.loaded_tools.deinit(std.testing.allocator);

    factory.resetDefs();
    try factory.add(r.tools.read.ReadTool, .all);

    var tools = ToolSet{};
    try factory.build_toolset(.general, &tools);
    try std.testing.expectEqual(@as(u32, 1), tools.len);
    try std.testing.expectEqualStrings(r.tools.read.ReadTool.def.name, tools.slice()[0].def.name);

    try factory.setAgentTools(.general, &.{});
    try factory.build_toolset(.general, &tools);
    try std.testing.expectEqual(@as(u32, 0), tools.len);
}

test "remove deletes the matched loaded tool" {
    var factory = Self{
        .alloc = std.testing.allocator,
        .prompt_arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .io = undefined,
        .config_dir = null,
        .skill_dir = null,
    };
    defer factory.prompt_arena.deinit();
    defer factory.loaded_tools.deinit(std.testing.allocator);

    factory.resetDefs();
    try factory.add(r.tools.read.ReadTool, .all);
    try factory.add(r.tools.write.WriteTool, .all);
    try factory.add(r.tools.search.GlobTool, .all);
    try factory.add(r.tools.search.GrepTool, .all);

    factory.remove(r.tools.write.WriteTool.def.name);

    try std.testing.expect(factory.findLoaded(r.tools.read.ReadTool.def.name) != null);
    try std.testing.expect(factory.findLoaded(r.tools.write.WriteTool.def.name) == null);
    try std.testing.expect(factory.findLoaded(r.tools.search.GlobTool.def.name) != null);
    try std.testing.expect(factory.findLoaded(r.tools.search.GrepTool.def.name) != null);
}

fn initTestFactory() Self {
    var factory = Self{
        .alloc = std.testing.allocator,
        .prompt_arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .io = undefined,
        .config_dir = null,
        .skill_dir = null,
    };
    factory.resetDefs();
    return factory;
}

test "agent config diagnoses an unbound agent model" {
    var factory = initTestFactory();
    defer factory.prompt_arena.deinit();

    var cfg: r.config.BlitzdenkCfg = .{};
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    switch (factory.buildAgentApiConfig(.general, &cfg, &env)) {
        .diagnostic => |diagnostic| switch (diagnostic) {
            .no_agent_model => |name| try std.testing.expectEqualStrings("general", name),
            else => return error.TestExpectedUnboundAgentModel,
        },
        .config => return error.TestExpectedConfigDiagnostic,
    }
}

test "agent config diagnoses an invalid provider" {
    var factory = initTestFactory();
    defer factory.prompt_arena.deinit();

    var cfg: r.config.BlitzdenkCfg = .{};
    cfg.model_count = 1;
    cfg.models[0] = .{ .provider = @enumFromInt(0) };
    try factory.setAgentModel(&cfg, .general, @enumFromInt(0), .medium);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    switch (factory.buildAgentApiConfig(.general, &cfg, &env)) {
        .diagnostic => |diagnostic| try std.testing.expect(diagnostic == .invalid_provider),
        .config => return error.TestExpectedConfigDiagnostic,
    }
}

test "agent config reports the missing API key environment variable" {
    var factory = initTestFactory();
    defer factory.prompt_arena.deinit();

    var cfg: r.config.BlitzdenkCfg = .{};
    _ = cfg.reserveProvider("https://example.test/v1", "EXAMPLE_API_KEY").?;
    const provider = cfg.commitProvider();
    const model = try cfg.addModel("example-model", provider, false, null);
    try factory.setAgentModel(&cfg, .general, model, .medium);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    switch (factory.buildAgentApiConfig(.general, &cfg, &env)) {
        .diagnostic => |diagnostic| switch (diagnostic) {
            .missing_api_key => |name| try std.testing.expectEqualStrings("EXAMPLE_API_KEY", name),
            else => return error.TestExpectedMissingApiKey,
        },
        .config => return error.TestExpectedConfigDiagnostic,
    }
}

test "agent config permits keyless providers" {
    var factory = initTestFactory();
    defer factory.prompt_arena.deinit();

    var cfg: r.config.BlitzdenkCfg = .{};
    _ = cfg.reserveProvider("http://localhost:8080/v1", "").?;
    const provider = cfg.commitProvider();
    const model = try cfg.addModel("local-model", provider, false, null);
    try factory.setAgentModel(&cfg, .general, model, .medium);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    switch (factory.buildAgentApiConfig(.general, &cfg, &env)) {
        .config => |config| {
            try std.testing.expectEqualStrings("", config.api_key);
            try std.testing.expectEqualStrings("local-model", config.model);
        },
        .diagnostic => return error.TestExpectedAgentConfig,
    }
}

test "system_prompt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const io = std.testing.io_instance;
    const home_dir = io.environ.process_environ.getPosix("HOME") orelse "/root";

    var factory = try Self.init(alloc, std.testing.io, home_dir, "/");
    defer factory.prompt_arena.deinit();

    const prompt = try factory.build_system_prompt(alloc, .general);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# Available tools:") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- read: Read file contents") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- bash: Execute a bash command") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# Guidelines:") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- Use read to examine files instead of cat or sed.") != null);
}
