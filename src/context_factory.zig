///! building agents and prompts
const Self = @This();

const std = @import("std");
const r = @import("root.zig");

const CONFIG_DIR = @import("main.zig").DEFAULT_CONFIG_PATH;
const CONTEXT_FILES = .{"AGENTS.md"};
pub const MAX_AGENT_TOOLS = 64;

pub const general_default_tool_set = .{
    r.tools.write.WriteTool,
    r.tools.edit.EditTool,
    r.tools.bash.BashTool,
    r.tools.bash.CancelBackgroundCommand,
    r.tools.read.ReadTool,
    r.tools.agent.AgentTool,
    r.tools.agent.SendMessageToAgent,
    r.tools.agent.AwaitAgent,
    r.tools.agent.CancelAgent,
    r.tools.tasks.ListTasksTool,
    r.tools.tasks.UpdateTaskStateTool,
    r.tools.tasks.CreateTaskTool,
    r.tools.patch.PatchTool,
    r.tools.ask.AskTool,
    r.tools.ssh.EnterSshMode,
    r.tools.ssh.ExitSshMode,
};

pub const AgentDef = struct {
    name: []const u8,
    description: []const u8,
    prompt: []const u8,
    in_agent_tool: bool = true,
    tools: AgentTools = .{},
    model: ?AgentModelConfig = null,
};

pub const ModeDef = struct {
    name: []const u8,
    prompt: []const u8,
    sparse: []const u8,
    color: r.tui.Color = .white,
};

pub const Mode = enum(u6) {
    pub const Set = std.EnumSet(Mode);
    exec,
    _,
};

pub const AgentType = enum(u6) {
    pub const Set = std.EnumSet(AgentType);
    general,
    explore,
    _,
};

pub const ToolFlags = struct {
    allowed_agents: AgentType.Set,
    add_to_agents: bool = false,

    pub const all = ToolFlags{ .allowed_agents = .initFull() };
};

pub const ToolSet = struct {
    set: [64]r.prv.tool.Tool = undefined,
    len: u32 = 0,

    pub fn slice(self: *const ToolSet) []const r.prv.tool.Tool {
        return self.set[0..self.len];
    }
};

const ToolEntry = struct { tool: r.prv.tool.Tool, flags: ToolFlags };

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
    name: []const u8,
    effort: r.prv.config.ReasoningEffort = .medium,
    provider: r.prv.config.ProviderHandle,
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

// -------------------------------------------------------------------------------
loaded_tools: std.ArrayList(ToolEntry) = .empty,

mode_counter: u32 = 2, // skip first 2 for interal modes
agent_counter: u32 = 3,

agents: std.EnumArray(AgentType, ?AgentDef) = .initFill(null),
modes: std.EnumArray(Mode, ?ModeDef) = .initFill(null),

// Arena holds definitions set from Lua. Reset on hot-reload so the
// factory keeps using the embedded defaults until lua re-installs them.

prompt_arena: std.heap.ArenaAllocator,
io: std.Io,
config_dir: ?std.Io.Dir,
skill_dir: ?std.Io.Dir,
// -------------------------------------------------------------------------------

pub fn init(alloc: std.mem.Allocator, io: std.Io, home: []const u8) !Self {
    var list = std.ArrayList(ToolEntry).empty;
    inline for (general_default_tool_set) |tool| {
        try list.append(alloc, .{ .tool = tool, .flags = .all });
    }

    var home_dir = try std.Io.Dir.openDirAbsolute(io, home, .{});
    const skill_dir: ?std.Io.Dir = home_dir.openDir(io, CONFIG_DIR ++ "skills/", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    const config_dir: ?std.Io.Dir = home_dir.openDir(io, CONFIG_DIR, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    var self = Self{
        .loaded_tools = list,
        .prompt_arena = std.heap.ArenaAllocator.init(alloc),
        .io = io,
        .skill_dir = skill_dir,
        .config_dir = config_dir,
    };

    self.resetDefs();
    return self;
}

pub fn buildAgentApiConfig(
    self: *Self,
    agent_type: AgentType,
    cfg: *r.prv.config.BlitzdenkCfg,
    env: *const std.process.Environ.Map,
) ?r.prv.adapter.Config {
    const def = self.getAgent(agent_type) orelse return null;
    if (def.model) |ag_cfg| {
        const provider_idx = @intFromEnum(ag_cfg.provider);
        if (provider_idx >= cfg.provider_count) return null;

        const provider = &cfg.providers[provider_idx];
        if (!provider.active) return null;

        const key = if (provider.key_len > 0)
            env.get(provider.getKeyEnvar()) orelse return null
        else
            "";

        return r.prv.adapter.Config{
            .api_key = key,
            .base_url = provider.getUrl(),
            .model = ag_cfg.name,
            .provider = provider.provider_config,
            .reasoning_effort = ag_cfg.effort,
        };
    }

    return cfg.buildConfig(env);
}

pub fn setAgentPrompt(self: *Self, agent_type: AgentType, prompt: []const u8) !void {
    const def = self.getAgentMut(agent_type) orelse return error.UnknownAgent;
    const dup = try self.prompt_arena.allocator().dupe(u8, prompt);
    def.prompt = dup;
}

pub fn setAgentModel(self: *Self, agent_type: AgentType, model: []const u8, effort: r.prv.config.ReasoningEffort, provider: r.prv.config.ProviderHandle) !void {
    const def = self.getAgentMut(agent_type) orelse return error.UnknownAgent;
    def.model = .{
        .name = try self.prompt_arena.allocator().dupe(u8, model),
        .effort = effort,
        .provider = provider,
    };
}

pub fn addAgent(self: *Self, def: NewAgentDef) !AgentType {
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
        .model = if (def.model) |model| .{
            .name = try alloc.dupe(u8, model.name),
            .effort = model.effort,
            .provider = model.provider,
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

pub fn setModePrompt(self: *Self, mode: Mode, prompt: []const u8) !void {
    const slot = self.modes.getPtr(mode);
    if (slot.* == null) return error.UnknownMode;
    const dup = try self.prompt_arena.allocator().dupe(u8, prompt);
    slot.*.?.prompt = dup;
}

pub fn setModeName(self: *Self, mode: Mode, name: []const u8) !void {
    const slot = self.modes.getPtr(mode);
    if (slot.* == null) return error.UnknownMode;
    const dup = try self.prompt_arena.allocator().dupe(u8, name);
    slot.*.?.name = dup;
}

pub fn setSparseModePrompt(self: *Self, mode: Mode, prompt: []const u8) !void {
    const slot = self.modes.getPtr(mode);
    if (slot.* == null) return error.UnknownMode;
    const dup = try self.prompt_arena.allocator().dupe(u8, prompt);
    slot.*.?.sparse = dup;
}

pub fn addMode(self: *Self, name: []const u8, prompt: []const u8, sparse: []const u8, color: []const u8) !Mode {
    if (self.mode_counter > std.math.maxInt(u6)) return error.TooManyModes;
    const idx: Mode = @enumFromInt(self.mode_counter);
    const alloc = self.prompt_arena.allocator();
    self.modes.set(idx, .{
        .name = try alloc.dupe(u8, name),
        .prompt = try alloc.dupe(u8, prompt),
        .sparse = try alloc.dupe(u8, sparse),
        .color = r.tui.Color.parseStrHex(color) catch .white,
    });
    self.mode_counter += 1;
    return idx;
}

pub fn getMode(self: *const Self, mode: Mode) ModeDef {
    return self.modes.get(mode) orelse .{ .name = "UNKNOWN", .prompt = "", .sparse = "" };
}

fn getAgent(self: *const Self, agent_type: AgentType) ?*const AgentDef {
    return if (self.agents.getPtrConst(agent_type).*) |*def| def else null;
}

fn getAgentMut(self: *Self, agent_type: AgentType) ?*AgentDef {
    return if (self.agents.getPtr(agent_type).*) |*def| def else null;
}

// No alloc iter
pub const SkillIter = struct {
    dir_itr: std.Io.Dir.Iterator,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    header_buf: [4096]u8 = undefined,
    io: std.Io,

    pub const Entry = struct {
        path: []const u8,
        name: []const u8,
        description: []const u8,

        pub fn toOwned(self: *const Entry, alloc: std.mem.Allocator) !Entry {
            return .{
                .name = try alloc.dupe(u8, self.name),
                .description = try alloc.dupe(u8, self.description),
                .path = try alloc.dupe(u8, self.path),
            };
        }
    };

    pub fn next(self: *SkillIter) ?Entry {
        while (true) {
            const entry = self.dir_itr.next(self.io) catch return null orelse return null;
            if (entry.kind != .file) continue;

            const len = self.dir_itr.reader.dir.realPathFile(self.io, entry.name, &self.path_buf) catch continue;
            const path = self.path_buf[0..len];

            const meta = loadSkillMeta(self.io, path, &self.header_buf) orelse continue;
            return .{
                .path = path,
                .name = meta.name,
                .description = meta.description,
            };
        }
    }
};

/// Restore embedded defaults and free any Lua-installed definitions.
pub fn resetDefs(self: *Self) void {
    _ = self.prompt_arena.reset(.retain_capacity);
    self.mode_counter = 2;
    self.agent_counter = 3;
    self.agents = .initFill(null);
    self.modes = .initFill(null);

    self.agents.set(.general, .{
        .name = @tagName(AgentType.general),
        .description = "General purpose agent",
        .prompt = r.prompts.default_main_agent_prompt,
        .tools = .from(&.{
            r.tools.write.WriteTool.def.name,
            r.tools.edit.EditTool.def.name,
            r.tools.bash.BashTool.def.name,
            r.tools.bash.CancelBackgroundCommand.def.name,
            r.tools.read.ReadTool.def.name,
            r.tools.agent.AgentTool.def.name,
            r.tools.agent.SendMessageToAgent.def.name,
            r.tools.agent.AwaitAgent.def.name,
            r.tools.agent.CancelAgent.def.name,
            r.tools.tasks.ListTasksTool.def.name,
            r.tools.tasks.UpdateTaskStateTool.def.name,
            r.tools.tasks.CreateTaskTool.def.name,
            r.tools.ask.AskTool.def.name,
        }),
    });
    self.agents.set(.explore, .{
        .name = @tagName(AgentType.explore),
        .description =
        \\Search specialist for code, documentation and web
        \\When to use:
        \\- Any questions against documentation
        \\- Explore how certain parts of code work
        \\- Doing research on the web
        \\
        ,
        .prompt = r.prompts.explore_sub_agent_prompt,
        .tools = .from(&.{
            r.tools.bash.BashTool.def.name,
            r.tools.bash.CancelBackgroundCommand.def.name,
            r.tools.read.ReadTool.def.name,
            r.tools.agent.SendMessageToAgent.def.name,
        }),
    });

    self.modes.set(.exec, .{
        .name = "EXEC",
        .prompt = "",
        .sparse = "",
        .color = .red,
    });
}

pub fn add(self: *Self, alloc: std.mem.Allocator, tool: r.prv.tool.Tool, flags: ToolFlags) !void {
    try self.loaded_tools.append(alloc, .{ .tool = tool, .flags = flags });
}

pub fn remove(self: *Self, tool_name: []const u8) void {
    for (0..self.loaded_tools.items.len) |i| {
        const en = &self.loaded_tools.items[self.loaded_tools.items.len - i - 1];
        if (std.mem.eql(u8, en.tool.def.name, tool_name)) {
            _ = self.loaded_tools.swapRemove(i);
            return;
        }
    }
}

pub fn configureAgent(
    self: *const Self,
    agent: *r.prv.agent.Agent,
    config: *const r.prv.config.BlitzdenkCfg,
) !void {
    agent.reset();
    const alloc = agent.arena.allocator();

    agent.chat.tools.items.len = 0;
    agent.tools.clearRetainingCapacity();
    var it = self.iter(@enumFromInt(agent.type_idx));
    while (it.next()) |tool| {
        try agent.tools.append(alloc, tool);

        // Build the Agent tool schema from the registered agent definitions.
        if (std.mem.eql(u8, tool.def.name, r.tools.agent.AgentTool.def.name)) {
            var buf: [64]AgentMeta = undefined;
            var out = std.ArrayList(AgentMeta).initBuffer(&buf);

            for (0..64) |i| {
                const def = self.getAgent(@enumFromInt(i)) orelse continue;
                if (!def.in_agent_tool) continue;
                out.appendBounded(.{ .name = def.name, .description = def.description }) catch unreachable;
            }

            const def = try r.tools.agent.dynamic_def(alloc, out.items);

            try agent.chat.addTool(alloc, .{
                .name = tool.def.name,
                .description = def.desc,
                .parameters_schema = def.schema,
            });

            continue;
        }

        try agent.chat.addTool(alloc, tool.def);
    }

    const prompt = try self.build_system_prompt(alloc, config, @enumFromInt(agent.type_idx));
    try agent.setSystemPrompt(prompt);
}

fn findLoaded(self: *const Self, name: []const u8) ?r.prv.tool.Tool {
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
    pub fn next(self: *ToolIter) ?r.prv.tool.Tool {
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

pub fn clearTools(self: *Self) void {
    self.loaded_tools.clearRetainingCapacity();
}

pub fn build_system_prompt(
    self: *const Self,
    alloc: std.mem.Allocator,
    config: *const r.prv.config.BlitzdenkCfg,
    agent_type: AgentType,
) ![]const u8 {
    _ = config; // autofix
    var allocating = std.Io.Writer.Allocating.init(alloc);
    var w = &allocating.writer;

    const def = self.getAgent(agent_type) orelse return error.UnknownAgent;
    _ = try w.write(def.prompt);
    try w.writeByte('\n');

    // global context
    if (self.config_dir) |dir| {
        inline for (CONTEXT_FILES) |context_file| {
            var buf: [255]u8 = undefined;
            const path_len = try dir.realPath(self.io, &buf);

            if (dir.openFile(self.io, context_file, .{})) |user_ctx_file| {
                try w.print("Instructions from: {s}/{s}\n", .{ buf[0..path_len], context_file });
                var filer_reader = user_ctx_file.reader(self.io, &buf);
                _ = try std.Io.Reader.streamRemaining(&filer_reader.interface, w);
            } else |_| {}
        }
    }

    try w.writeAll("\n\n");

    // local context
    inline for (CONTEXT_FILES) |context_file| {
        if (std.Io.Dir.cwd().openFile(self.io, context_file, .{})) |user_ctx_file| {
            var buf: [100]u8 = undefined;
            try w.print("Instructions from: ./{s}\n", .{context_file});
            var filer_reader = user_ctx_file.reader(self.io, &buf);
            _ = try std.Io.Reader.streamRemaining(&filer_reader.interface, w);
        } else |_| {}
    }

    if (self.skill_dir) |skill_dir| {
        var it = skill_dir.iterate();
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var header_buf: [4096]u8 = undefined;

        _ = try w.write("Available skills:\n");

        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

            const len = try skill_dir.realPathFile(self.io, entry.name, &path_buf);
            const path = path_buf[0..len];

            const skill = loadSkillMeta(self.io, path, &header_buf) orelse {
                std.log.err("failed to load skill header for '{s}'", .{entry.name});
                continue;
            };

            try w.print(
                \\skill: "{s}"
                \\description: "{s}"
                \\location: "{s}"
                \\
            , .{
                skill.name,
                skill.description,
                path,
            });
        }
    }

    return allocating.written();
}

// Example: skill.md, yaml header followed by plain text content.
//
//```skill.md
//---
//name: pdf-processing
//description: Extract PDF text, fill forms, merge files. Use when handling PDFs.
//license: Apache-2.0
//metadata:
//  author: example-org
//  version: "1.0"
//---
//The skill content ...
//```

pub const SkillMeta = struct {
    name: []const u8,
    description: []const u8,
    license: ?[]const u8 = null,
    compatibility: ?[]const u8 = null,
    metadata: ?[]const []const u8 = null,
    allowed_tools: ?[]const u8 = null,
};

/// Reads only the yaml header from `path` into `buf`. Returned slices point into `buf`,
/// so it must outlive the result.
pub fn loadSkillMeta(io: std.Io, path: []const u8, buf: []u8) ?SkillMeta {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);

    var read_buf: [256]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const n = file_reader.interface.readSliceShort(buf) catch return null;
    const raw = buf[0..n];
    if (!std.mem.startsWith(u8, raw, "---\n")) return null;

    const header_end = std.mem.indexOf(u8, raw[4..], "\n---") orelse return null;
    const header = raw[4..][0..header_end];

    var meta: SkillMeta = .{ .name = "", .description = "" };

    var lines = std.mem.splitScalar(u8, header, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == ' ' or line[0] == '\t') continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (std.mem.eql(u8, key, "name")) {
            meta.name = val;
        } else if (std.mem.eql(u8, key, "description")) {
            meta.description = val;
        } else if (std.mem.eql(u8, key, "license")) {
            meta.license = if (val.len > 0) val else null;
        } else if (std.mem.eql(u8, key, "compatibility")) {
            meta.compatibility = if (val.len > 0) val else null;
        } else if (std.mem.eql(u8, key, "allowed_tools")) {
            meta.allowed_tools = if (val.len > 0) val else null;
        }
    }

    if (meta.name.len == 0 or meta.description.len == 0) return null;
    return meta;
}

test "agent defaults can be replaced with an empty tool list" {
    var factory = Self{
        .prompt_arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .io = undefined,
        .config_dir = null,
        .skill_dir = null,
    };
    defer factory.prompt_arena.deinit();
    defer factory.loaded_tools.deinit(std.testing.allocator);

    factory.resetDefs();
    try factory.add(std.testing.allocator, r.tools.read.ReadTool, .all);

    var tools = ToolSet{};
    try factory.build_toolset(.general, &tools);
    try std.testing.expectEqual(@as(u32, 1), tools.len);
    try std.testing.expectEqualStrings(r.tools.read.ReadTool.def.name, tools.slice()[0].def.name);

    try factory.setAgentTools(.general, &.{});
    try factory.build_toolset(.general, &tools);
    try std.testing.expectEqual(@as(u32, 0), tools.len);
}
