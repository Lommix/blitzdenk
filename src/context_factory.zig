///! building agents and prompts
const Self = @This();

const std = @import("std");
const r = @import("root.zig");

const CONFIG_DIR = @import("main.zig").DEFAULT_CONFIG_PATH;
const CONTEXT_FILES = .{"AGENTS.md"};
pub const MAX_OVERRIDE_TOOLS = 64;

pub const default_tool_set = .{
    .{ r.tools.write.WriteTool, ToolFlags.empty.agents(&.{.general}) },
    .{ r.tools.edit.EditTool, ToolFlags.empty.agents(&.{.general}) },
    .{ r.tools.bash.BashTool, ToolFlags.all },
    .{ r.tools.bash.CancelBackgroundCommand, ToolFlags.all },
    .{ r.tools.read.ReadTool, ToolFlags.all },
    .{ r.tools.agent.AgentTool, ToolFlags.all },
    .{ r.tools.agent.SendMessageToAgent, ToolFlags.all },
    .{ r.tools.agent.AwaitAgent, ToolFlags.all },
    .{ r.tools.agent.CancelAgent, ToolFlags.all },
    .{ r.tools.tasks.ListTasksTool, ToolFlags.all },
    .{ r.tools.tasks.UpdateTaskStateTool, ToolFlags.all },
    .{ r.tools.tasks.CreateTaskTool, ToolFlags.all },
    .{ r.tools.patch.PatchTool, ToolFlags.all },
    .{ r.tools.ask.AskTool, ToolFlags.all },
    .{ r.tools.ssh.EnterSshMode, ToolFlags.empty.agents(&.{.general}) },
    .{ r.tools.ssh.ExitSshMode, ToolFlags.empty.agents(&.{.general}) },
};

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
    r.tools.ask.AskTool,
};

pub const readonly_no_sub_default_tool_set = .{
    r.tools.bash.BashTool,
    r.tools.bash.CancelBackgroundCommand,
    r.tools.read.ReadTool,
    r.tools.agent.SendMessageToAgent,
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
    review,
    _,
};

pub const ToolFlags = struct {
    // ----
    allowed_agents: AgentType.Set,
    include_with_overrides: bool = false,
    // ----
    pub const all = ToolFlags{ .allowed_agents = .initFull() };
    pub const empty = ToolFlags{ .allowed_agents = .initEmpty() };

    pub fn agents(self: ToolFlags, types: []const AgentType) ToolFlags {
        var s = self;
        for (types) |ty| s.allowed_agents.insert(ty);
        return s;
    }

    pub fn removeAgent(self: ToolFlags, val: AgentType) ToolFlags {
        var s = self;
        s.allowed_agents.remove(val);
        return s;
    }
};

pub const ToolSet = struct {
    set: [64]r.prv.tool.Tool = undefined,
    len: u32 = 0,

    pub fn slice(self: *const ToolSet) []const r.prv.tool.Tool {
        return self.set[0..self.len];
    }
};

const ToolEntry = struct { tool: r.prv.tool.Tool, flags: ToolFlags };

pub const AgentOverride = struct {
    names: [MAX_OVERRIDE_TOOLS][255]u8 = undefined,
    name_lens: [MAX_OVERRIDE_TOOLS]u8 = @splat(0),
    len: u8 = 0,
    active: bool = false,

    pub fn nameAt(self: *const AgentOverride, i: usize) []const u8 {
        return self.names[i][0..self.name_lens[i]];
    }
};
// -------------------------------------------------------------------------------
loaded_tools: std.ArrayList(ToolEntry) = .empty,
agent_prompts: std.EnumArray(AgentType, []const u8),
mode_colors: std.EnumArray(Mode, r.tui.Color),
mode_names: std.EnumArray(Mode, []const u8),
mode_prompts: std.EnumArray(Mode, []const u8),
sparse_mode_prompts: std.EnumArray(Mode, []const u8),
agent_overrides: std.EnumArray(AgentType, AgentOverride) = .initFill(.{}),
custom_mode_counter: u32 = 2, // skip first 2 for interal modes

agent_tool_sets: std.EnumMap(AgentType, ToolSet) = .{},

// Arena holds prompt overrides set from lua. Reset on hot-reload so the
// factory keeps using the embedded defaults until lua re-installs them.

prompt_arena: std.heap.ArenaAllocator,
io: std.Io,
config_dir: ?std.Io.Dir,
skill_dir: ?std.Io.Dir,
// -------------------------------------------------------------------------------

pub fn init(alloc: std.mem.Allocator, io: std.Io, home: []const u8) !Self {
    var list = std.ArrayList(ToolEntry).empty;
    inline for (default_tool_set) |entry| {
        try list.append(alloc, .{ .tool = entry[0], .flags = entry[1] });
    }

    var agent_prompts = std.EnumArray(AgentType, []const u8).initFill("");
    agent_prompts.set(.general, r.prompts.default_main_agent_prompt);
    agent_prompts.set(.explore, r.prompts.explore_sub_agent_prompt);
    agent_prompts.set(.review, r.prompts.review_sub_agent_prompt);

    const mode_prompts = std.EnumArray(Mode, []const u8).initFill("");
    const sparse_mode_prompts = std.EnumArray(Mode, []const u8).initFill("");
    var mode_names = std.EnumArray(Mode, []const u8).initFill("UNKNOWN");
    mode_names.set(.exec, "EXEC");
    var mode_colors = std.EnumArray(Mode, r.tui.Color).initFill(.white);
    mode_colors.set(.exec, .red);

    var home_dir = try std.Io.Dir.openDirAbsolute(io, home, .{});
    const skill_dir: ?std.Io.Dir = home_dir.openDir(io, CONFIG_DIR ++ "skills/", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    const config_dir: ?std.Io.Dir = home_dir.openDir(io, CONFIG_DIR, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    return Self{
        .loaded_tools = list,
        .agent_prompts = agent_prompts,
        .mode_prompts = mode_prompts,
        .mode_colors = mode_colors,
        .mode_names = mode_names,
        .sparse_mode_prompts = sparse_mode_prompts,
        .prompt_arena = std.heap.ArenaAllocator.init(alloc),
        .io = io,
        .skill_dir = skill_dir,
        .config_dir = config_dir,
    };
}

pub fn setAgentPrompt(self: *Self, agent_type: AgentType, prompt: []const u8) !void {
    const dup = try self.prompt_arena.allocator().dupe(u8, prompt);
    self.agent_prompts.set(agent_type, dup);
}

pub fn setModePrompt(self: *Self, mode: Mode, prompt: []const u8) !void {
    const dup = try self.prompt_arena.allocator().dupe(u8, prompt);
    self.mode_prompts.set(mode, dup);
}

pub fn setModeName(self: *Self, mode: Mode, name: []const u8) !void {
    const dup = try self.prompt_arena.allocator().dupe(u8, name);
    self.mode_names.set(mode, dup);
}

pub fn setSparseModePrompt(self: *Self, mode: Mode, prompt: []const u8) !void {
    const dup = try self.prompt_arena.allocator().dupe(u8, prompt);
    self.sparse_mode_prompts.set(mode, dup);
}

pub fn addMode(self: *Self, name: []const u8, prompt: []const u8, sparse: []const u8, color: []const u8) !Mode {
    defer self.custom_mode_counter += 1;
    const idx: Mode = @enumFromInt(self.custom_mode_counter);
    const alloc = self.prompt_arena.allocator();
    self.mode_names.set(idx, try alloc.dupe(u8, name));
    self.mode_prompts.set(idx, try alloc.dupe(u8, prompt));
    self.sparse_mode_prompts.set(idx, try alloc.dupe(u8, sparse));
    const c = r.tui.Color.parseStrHex(color) catch r.tui.Color.white;
    self.mode_colors.set(idx, c);
    return idx;
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

/// Restore embedded defaults and free any lua-installed prompt overrides.
pub fn resetPrompts(self: *Self) void {
    _ = self.prompt_arena.reset(.retain_capacity);
    self.custom_mode_counter = 2;
    self.agent_prompts = .initFill("NOT PROMPT, REPORT TO THE USER");
    self.mode_names = .initFill("UNKNOWN");
    self.mode_colors = .initFill(.white);
    self.mode_prompts = .initFill("");
    self.sparse_mode_prompts = .initFill("");
    self.mode_names.set(.exec, "EXEC");
    self.mode_colors.set(.exec, .red);
    self.mode_prompts.set(.exec, "");
    self.sparse_mode_prompts.set(.exec, "");

    self.agent_prompts.set(.general, r.prompts.default_main_agent_prompt);
    self.agent_prompts.set(.explore, r.prompts.explore_sub_agent_prompt);
    self.agent_prompts.set(.review, r.prompts.review_sub_agent_prompt);
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
        try agent.chat.addTool(alloc, tool.def);
    }

    const prompt = try self.build_prompt(alloc, config, @enumFromInt(agent.type_idx));
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
    override_phase_done: bool = false,
    pub fn next(self: *ToolIter) ?r.prv.tool.Tool {
        const override = self.factory.agent_overrides.getPtrConst(self.agent_type);
        if (override.active and !self.override_phase_done) {
            while (self.i < override.len) {
                const idx = self.i;
                self.i += 1;
                const name = override.nameAt(idx);
                if (self.factory.findLoaded(name)) |tool| return tool;
            }
            self.override_phase_done = true;
            self.i = 0;
        }
        if (override.active) {
            while (self.i < self.factory.loaded_tools.items.len) {
                const en = self.factory.loaded_tools.items[self.i];
                self.i += 1;
                if (!en.flags.include_with_overrides) continue;
                if (!en.flags.allowed_agents.contains(self.agent_type)) continue;
                if (overrideContains(override, en.tool.def.name)) continue;
                return en.tool;
            }
            return null;
        }
        while (self.i < self.factory.loaded_tools.items.len) {
            const en = self.factory.loaded_tools.items[self.i];
            self.i += 1;
            if (!en.flags.allowed_agents.contains(self.agent_type)) continue;
            return en.tool;
        }
        return null;
    }

    fn overrideContains(override: *const AgentOverride, name: []const u8) bool {
        for (0..override.len) |idx| {
            if (std.mem.eql(u8, override.nameAt(idx), name)) return true;
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
    var ov = self.agent_overrides.getPtr(agent_type);
    if (names.len > MAX_OVERRIDE_TOOLS) return error.TooManyTools;
    ov.len = 0;
    for (names) |name| {
        if (name.len > 128) return error.NameTooLong;
        @memcpy(ov.names[ov.len][0..name.len], name);
        ov.name_lens[ov.len] = @intCast(name.len);
        ov.len += 1;
    }
    ov.active = true;
}

pub fn addAgentTool(self: *Self, agent_type: AgentType, name: []const u8) !void {
    var ov = self.agent_overrides.getPtr(agent_type);
    if (ov.len >= MAX_OVERRIDE_TOOLS) return error.TooManyTools;
    if (name.len > 128) return error.NameTooLong;

    for (0..ov.len) |i| {
        const len = ov.name_lens[i];
        if (len == 0) continue;

        const existing = ov.names[i][0..len];
        if (std.mem.eql(u8, existing, name)) return;
    }

    @memcpy(ov.names[ov.len][0..name.len], name);
    ov.name_lens[ov.len] = @intCast(name.len);
    ov.len += 1;
    ov.active = true;
}

pub fn clearAgentTools(self: *Self, agent_type: AgentType) void {
    const ov = self.agent_overrides.getPtr(agent_type);
    ov.* = .{};
}

pub fn clearAllAgentTools(self: *Self) void {
    self.agent_overrides = .initFill(.{});
}

pub fn clearTools(self: *Self) void {
    self.loaded_tools.clearRetainingCapacity();
}

pub fn build_prompt(
    self: *const Self,
    alloc: std.mem.Allocator,
    config: *const r.prv.config.BlitzdenkCfg,
    agent_type: AgentType,
) ![]const u8 {
    var allocating = std.Io.Writer.Allocating.init(alloc);
    var w = &allocating.writer;

    _ = try w.write(self.agent_prompts.get(agent_type));
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

    if (config.doc_count > 0) {
        _ = try w.write("Available docs:\n");
        for (config.doc_entries[0..config.doc_count]) |entry| {
            try w.print(
                \\name: "{s}"
                \\description: "{s}"
                \\location: "{s}"
                \\
            , .{
                entry.getName(),
                entry.getDescription(),
                entry.getLocation(),
            });
        }
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
