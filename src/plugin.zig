//! Plugin support shared by the Lua VMs and the `blitz plugin` commands:
//! declaration names, the lockfile, git operations, the main VM snapshot,
//! and the update and create commands.
const std = @import("std");
const exec = @import("exec");
const defaults = @import("defaults.zig");
const util = @import("util.zig");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.plugin);

pub const LOCK_FILE = "blitz.lock.json";
const NETWORK_TIMEOUT_MS: i64 = 120_000;
const LOCAL_TIMEOUT_MS: i64 = 10_000;
const LOCK_MAX_BYTES = 1024 * 1024;

/// `lua/<name>/init.lua` of a new plugin. Format arg: the plugin name.
pub const ENTRY_TEMPLATE =
    \\local M = {{}}
    \\
    \\M.tools = {{}}
    \\
    \\---Register tools, agents, and hooks. The user config calls
    \\---`require("{0s}").setup({{ ... }})`. Config replays in every tool and hook
    \\---VM, so keep this free of side effects.
    \\---@param opts? table
    \\function M.setup(opts)
    \\    opts = opts or {{}}
    \\    -- M.tools.hello = blitz.register_tool({{ name = "hello", ... }})
    \\end
    \\
    \\return M
    \\
;

/// `.luarc.json` of a new plugin: blitz types plus `lua/` module resolution.
pub const PLUGIN_LUARC =
    \\{
    \\  "runtime": {
    \\    "path": ["lua/?.lua", "lua/?/init.lua"]
    \\  },
    \\  "workspace": {
    \\    "library": [
    \\      "meta.lua"
    \\    ]
    \\  }
    \\}
;

/// `<dir>/lua/<name>/init.lua`, the module `blitz.plugin` loads.
pub fn entryPath(alloc: Allocator, dir: []const u8, name: []const u8) ![:0]u8 {
    return std.fmt.allocPrintSentinel(alloc, "{s}/lua/{s}/init.lua", .{ dir, name }, 0);
}

pub fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    }
    return true;
}

pub fn eqlName(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// A full URL (`scheme://...`) or an scp-style `user@host:path`. Rejects the
/// `owner/repo` shorthand.
pub fn isFullGitUrl(url: []const u8) bool {
    if (std.mem.indexOf(u8, url, "://") != null) return true;
    const at = std.mem.indexOfScalar(u8, url, '@') orelse return false;
    const colon = std.mem.indexOfScalarPos(u8, url, at, ':') orelse return false;
    return std.mem.indexOfScalar(u8, url[0..colon], '/') == null and colon + 1 < url.len;
}

pub fn isFullSha(ref: []const u8) bool {
    if (ref.len != 40 and ref.len != 64) return false;
    for (ref) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

fn isRefName(ref: []const u8) bool {
    if (ref.len == 0 or ref[0] == '-' or std.mem.indexOf(u8, ref, "..") != null) return false;
    for (ref) |ch| {
        if (ch <= ' ' or ch == 0x7f) return false;
        if (std.mem.indexOfScalar(u8, "~^:?*[\\", ch) != null) return false;
    }
    return true;
}

pub const RefKind = enum {
    commit,
    tag,
    branch,
    default,

    pub fn floats(self: RefKind) bool {
        return self == .branch or self == .default;
    }
};

/// When the loader runs. Only the hot reload stays off the network.
pub const Phase = enum {
    startup,
    reload,
    update,

    fn network(self: Phase) bool {
        return self != .reload;
    }
};

// ── Lockfile ──────────────────────────────────────────────────────────

pub const LockEntry = struct {
    source: []const u8,
    ref: ?[]const u8 = null,
    commit: []const u8,
};

pub const LockMap = std.array_hash_map.String(LockEntry);

const LockFile = struct {
    version: u32 = 1,
    plugins: std.json.ArrayHashMap(LockEntry) = .{},
};

/// A missing or corrupt lockfile reads as empty.
pub fn readLock(arena: Allocator, io: std.Io, path: []const u8) LockMap {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(LOCK_MAX_BYTES)) catch return .empty;
    const parsed = std.json.parseFromSliceLeaky(LockFile, arena, raw, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        log.warn("corrupt lockfile {s}; rebuilding it", .{path});
        return .empty;
    };
    return parsed.plugins.map;
}

fn lockGet(map: *const LockMap, name: []const u8) ?LockEntry {
    for (map.keys(), map.values()) |key, value| {
        if (eqlName(key, name)) return value;
    }
    return null;
}

fn lockPut(arena: Allocator, map: *LockMap, name: []const u8, entry: LockEntry) !void {
    lockRemove(map, name);
    try map.put(arena, name, entry);
}

fn lockRemove(map: *LockMap, name: []const u8) void {
    for (map.keys()) |key| {
        if (eqlName(key, name)) {
            _ = map.orderedRemove(key);
            return;
        }
    }
}

fn keyLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn renderLock(arena: Allocator, map: *const LockMap) ![]u8 {
    const names = try arena.dupe([]const u8, map.keys());
    std.mem.sort([]const u8, names, {}, keyLessThan);
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("{\n  \"version\": 1,\n  \"plugins\": {");
    for (names, 0..) |name, i| {
        const entry = map.get(name).?;
        try w.print("{s}\n    {f}: {{\n      \"source\": {f},\n      \"ref\": {f},\n      \"commit\": {f}\n    }}", .{
            if (i > 0) "," else "",
            std.json.fmt(name, .{}),
            std.json.fmt(entry.source, .{}),
            std.json.fmt(entry.ref, .{}),
            std.json.fmt(entry.commit, .{}),
        });
    }
    try w.writeAll(if (names.len > 0) "\n  }\n}\n" else "}\n}\n");
    return out.written();
}

/// Writes atomically, and only when the content changed. Returns whether it wrote.
pub fn writeLockIfChanged(arena: Allocator, io: std.Io, path: []const u8, map: *const LockMap) !bool {
    const next = try renderLock(arena, map);
    const cwd = std.Io.Dir.cwd();
    if (cwd.readFileAlloc(io, path, arena, .limited(LOCK_MAX_BYTES))) |current| {
        if (std.mem.eql(u8, current, next)) return false;
    } else |_| {
        // No lockfile and nothing to lock: users without git plugins get no file.
        if (map.count() == 0) return false;
    }
    const tmp = try std.fmt.allocPrint(arena, "{s}.tmp-{d}", .{ path, std.c.getpid() });
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = next });
    std.Io.Dir.renameAbsolute(tmp, path, io) catch |err| {
        cwd.deleteFile(io, tmp) catch {};
        return err;
    };
    return true;
}

// ── Git ───────────────────────────────────────────────────────────────

fn dirExists(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .directory;
}

pub fn fileExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn lastLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const nl = std.mem.findScalarLast(u8, trimmed, '\n') orelse return trimmed;
    return std.mem.trim(u8, trimmed[nl + 1 ..], " \t\r");
}

fn short(commit: []const u8) []const u8 {
    return commit[0..@min(commit.len, 7)];
}

/// Synchronous git runner. Never prompts: git and ssh open `/dev/tty`
/// directly, so ignoring stdin is not enough. Failures set `last_err`.
pub const Git = struct {
    pool: *exec.CmdPool,
    arena: Allocator,
    last_err: []const u8 = "",

    pub const Error = error{ GitFailed, OutOfMemory };

    fn fail(self: *Git, comptime fmt: []const u8, args: anytype) Error {
        self.last_err = try std.fmt.allocPrint(self.arena, fmt, args);
        return error.GitFailed;
    }

    /// Returns trimmed stdout on success.
    pub fn run(self: *Git, dir: ?[]const u8, args: []const []const u8, network: bool) Error![]const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(self.arena, "git");
        try argv.appendSlice(self.arena, args);
        var env: [2][2][]const u8 = .{ .{ "GIT_TERMINAL_PROMPT", "0" }, .{ "GIT_SSH_COMMAND", "ssh -o BatchMode=yes" } };
        const env_len: usize = if (self.pool.env.get("GIT_SSH_COMMAND") == null) 2 else 1;
        const res = self.pool.runAndWaitTimeout(.{
            .cwd = dir,
            .argv = argv.items,
            .extra_env = env[0..env_len],
        }, if (network) NETWORK_TIMEOUT_MS else LOCAL_TIMEOUT_MS) catch |err| return self.fail("git: {s}", .{@errorName(err)});
        defer self.pool.alloc.free(res.stdout);
        defer self.pool.alloc.free(res.stderr);
        switch (res.ty) {
            .success => return self.arena.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n")),
            .timeout => return self.fail("git {s} timed out", .{args[0]}),
            .failed => {
                if (res.exit_code == null and res.signal == null) return self.fail("git failed to start; is git installed?", .{});
                const msg = lastLine(res.stderr);
                if (msg.len == 0) return self.fail("git {s} failed", .{args[0]});
                return self.fail("git {s}: {s}", .{ args[0], msg });
            },
        }
    }

    fn ok(self: *Git, dir: []const u8, args: []const []const u8) ?[]const u8 {
        return self.run(dir, args, false) catch null;
    }

    /// Clone into a temp dir, then rename into place. A rename that finds an
    /// existing clone means another instance won; that clone is used.
    pub fn clone(self: *Git, io: std.Io, url: []const u8, plugins_dir: []const u8, name: []const u8) Error!void {
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, plugins_dir) catch |err| return self.fail("cannot create {s}: {s}", .{ plugins_dir, @errorName(err) });
        const dest = try std.fs.path.join(self.arena, &.{ plugins_dir, name });
        const tmp = try std.fmt.allocPrint(self.arena, "{s}/.tmp-{s}-{d}", .{ plugins_dir, name, std.c.getpid() });
        cwd.deleteTree(io, tmp) catch {};
        _ = self.run(null, &.{ "clone", "--quiet", "--", url, tmp }, true) catch |err| {
            cwd.deleteTree(io, tmp) catch {};
            return err;
        };
        std.Io.Dir.renameAbsolute(tmp, dest, io) catch |err| {
            cwd.deleteTree(io, tmp) catch {};
            if (!dirExists(io, dest)) return self.fail("cannot move clone into {s}: {s}", .{ dest, @errorName(err) });
        };
    }

    pub fn originUrl(self: *Git, dir: []const u8) ?[]const u8 {
        return self.ok(dir, &.{ "config", "--get", "remote.origin.url" });
    }

    pub fn setOrigin(self: *Git, dir: []const u8, url: []const u8) Error!void {
        _ = try self.run(dir, &.{ "remote", "set-url", "origin", url }, false);
    }

    pub fn fetch(self: *Git, dir: []const u8, force: bool) Error!void {
        if (force) {
            _ = try self.run(dir, &.{ "fetch", "--quiet", "--tags", "--prune", "--force", "origin" }, true);
        } else {
            _ = try self.run(dir, &.{ "fetch", "--quiet", "--tags", "--prune", "origin" }, true);
        }
        _ = self.run(dir, &.{ "remote", "set-head", "origin", "--auto" }, true) catch {};
    }

    pub fn hasCommit(self: *Git, dir: []const u8, commit: []const u8) bool {
        const spec = std.fmt.allocPrint(self.arena, "{s}^{{commit}}", .{commit}) catch return false;
        return self.ok(dir, &.{ "cat-file", "-e", spec }) != null;
    }

    fn revParse(self: *Git, dir: []const u8, comptime prefix: []const u8, name: []const u8) ?[]const u8 {
        const spec = std.fmt.allocPrint(self.arena, prefix ++ "{s}^{{commit}}", .{name}) catch return null;
        return self.ok(dir, &.{ "rev-parse", "--verify", "--quiet", spec });
    }

    pub const Resolved = struct { commit: []const u8, kind: RefKind };

    /// Full SHA, then tag, then branch, then the remote default branch.
    /// Local refs only.
    pub fn resolve(self: *Git, dir: []const u8, ref: ?[]const u8) Error!Resolved {
        const name = ref orelse {
            const commit = self.revParse(dir, "", "refs/remotes/origin/HEAD") orelse return self.fail("cannot resolve the remote default branch", .{});
            return .{ .commit = commit, .kind = .default };
        };
        if (isFullSha(name)) {
            if (!self.hasCommit(dir, name)) return self.fail("commit {s} not found", .{short(name)});
            return .{ .commit = try std.ascii.allocLowerString(self.arena, name), .kind = .commit };
        }
        if (!isRefName(name)) return self.fail("invalid ref '{s}'; use a branch, a tag, or a full commit SHA", .{name});
        const tag = self.revParse(dir, "refs/tags/", name);
        const branch = self.revParse(dir, "refs/remotes/origin/", name);
        if (tag) |commit| {
            if (branch != null) log.warn("ref '{s}' names a tag and a branch; using the tag", .{name});
            return .{ .commit = commit, .kind = .tag };
        }
        if (branch) |commit| return .{ .commit = commit, .kind = .branch };
        return self.fail("ref '{s}' not found", .{name});
    }

    pub fn head(self: *Git, dir: []const u8) ?[]const u8 {
        return self.ok(dir, &.{ "rev-parse", "HEAD" });
    }

    /// Tracked changes only. Untracked files, such as plugin caches, are fine.
    pub fn isDirty(self: *Git, dir: []const u8) Error!bool {
        const out = try self.run(dir, &.{ "status", "--porcelain", "--untracked-files=no" }, false);
        return out.len > 0;
    }

    /// Detached checkout of `commit`. Never overwrites local changes.
    pub fn checkoutClean(self: *Git, dir: []const u8, commit: []const u8) Error!void {
        if (self.head(dir)) |current| if (std.mem.eql(u8, current, commit)) return;
        if (try self.isDirty(dir)) return self.fail("local changes block checkout of {s}; commit or discard them", .{short(commit)});
        _ = try self.run(dir, &.{ "-c", "advice.detachedHead=false", "checkout", "--quiet", "--detach", commit }, false);
    }
};

// ── Loader state ──────────────────────────────────────────────────────

/// One `blitz.plugin` declaration, as collected for the update command.
pub const Decl = struct {
    name: []const u8,
    url: ?[]const u8 = null,
    path: ?[]const u8 = null,
    ref: ?[]const u8 = null,
};

/// What the main VM decided for one declaration. Sandbox VMs follow it.
pub const SnapshotEntry = struct {
    name: []const u8,
    dir: []const u8,
    commit: ?[]const u8 = null,
    loaded: bool = false,
    err: ?[]const u8 = null,
    path_plugin: bool = false,
};

const Resolution = struct { name: []const u8, entry: LockEntry };

/// App-owned plugin state. `begin`/`finish` bracket one main VM load. The
/// published `snapshot` is read by sandbox VMs under the main VM lock.
pub const Manager = struct {
    gpa: Allocator,
    io: std.Io,
    /// `<data dir>/plugins`; null when no data dir resolves.
    plugins_dir: ?[]u8 = null,
    lock_path: ?[]u8 = null,
    home: ?[]u8 = null,
    disabled: bool = false,
    /// Collect mode: record declarations, never execute entries or run git.
    collect: bool = false,
    phase: Phase = .startup,
    load_arena: std.heap.ArenaAllocator,
    lock: LockMap = .empty,
    pending: std.ArrayList(SnapshotEntry) = .empty,
    resolved: std.ArrayList(Resolution) = .empty,
    collected: std.ArrayList(Decl) = .empty,
    snap_arena: std.heap.ArenaAllocator,
    snapshot: []const SnapshotEntry = &.{},

    pub fn init(gpa: Allocator, io: std.Io) Manager {
        return .{ .gpa = gpa, .io = io, .load_arena = .init(gpa), .snap_arena = .init(gpa) };
    }

    pub fn deinit(self: *Manager) void {
        if (self.plugins_dir) |s| self.gpa.free(s);
        if (self.lock_path) |s| self.gpa.free(s);
        if (self.home) |s| self.gpa.free(s);
        self.load_arena.deinit();
        self.snap_arena.deinit();
    }

    pub fn configure(self: *Manager, data_dir: ?[]const u8, config_dir: ?[]const u8, home: ?[]const u8) !void {
        if (data_dir) |dir| self.plugins_dir = try std.fs.path.join(self.gpa, &.{ dir, "plugins" });
        if (config_dir) |dir| self.lock_path = try std.fs.path.join(self.gpa, &.{ dir, LOCK_FILE });
        if (home) |h| self.home = try self.gpa.dupe(u8, h);
    }

    pub fn arena(self: *Manager) Allocator {
        return self.load_arena.allocator();
    }

    pub fn begin(self: *Manager, phase: Phase) void {
        _ = self.load_arena.reset(.retain_capacity);
        self.phase = phase;
        self.pending = .empty;
        self.resolved = .empty;
        self.collected = .empty;
        self.lock = if (self.lock_path) |path| readLock(self.arena(), self.io, path) else .empty;
    }

    /// Write the merged lockfile after a clean load, then publish the snapshot.
    pub fn finish(self: *Manager, load_ok: bool) void {
        if (load_ok and !self.collect and !self.disabled) self.writeMergedLock() catch |err| {
            log.err("lockfile write failed: {s}", .{@errorName(err)});
        };
        _ = self.snap_arena.reset(.retain_capacity);
        self.snapshot = util.deepClone([]const SnapshotEntry, self.pending.items, self.snap_arena.allocator()) catch &.{};
    }

    fn writeMergedLock(self: *Manager) !void {
        const path = self.lock_path orelse return;
        var map = try self.lock.clone(self.arena());
        for (self.resolved.items) |res| try lockPut(self.arena(), &map, res.name, res.entry);
        _ = try writeLockIfChanged(self.arena(), self.io, path, &map);
    }

    pub fn find(self: *const Manager, name: []const u8) ?*const SnapshotEntry {
        for (self.snapshot) |*entry| {
            if (eqlName(entry.name, name)) return entry;
        }
        return null;
    }

    pub fn record(self: *Manager, entry: SnapshotEntry) void {
        const copy = util.deepClone(SnapshotEntry, entry, self.arena()) catch return;
        self.pending.append(self.arena(), copy) catch {};
    }

    pub fn collectDecl(self: *Manager, decl: Decl) void {
        const copy = util.deepClone(Decl, decl, self.arena()) catch return;
        self.collected.append(self.arena(), copy) catch {};
    }

    pub fn gitDir(self: *Manager, alloc: Allocator, name: []const u8) ?[]const u8 {
        const root = self.plugins_dir orelse return null;
        return std.fs.path.join(alloc, &.{ root, name }) catch null;
    }

    pub const GitLoad = union(enum) {
        ok: struct { dir: []const u8, commit: []const u8 },
        err: []const u8,
    };

    /// Main VM git load for one declaration. Follows the phase policy.
    pub fn loadGit(self: *Manager, pool: *exec.CmdPool, name: []const u8, url: []const u8, ref: ?[]const u8) GitLoad {
        var git = Git{ .pool = pool, .arena = self.arena() };
        const dir = self.gitDir(self.arena(), name) orelse return .{ .err = "no plugin data directory" };
        const commit = self.loadGitInner(&git, dir, name, url, ref) catch |err| return .{ .err = switch (err) {
            error.OutOfMemory => "out of memory",
            error.GitFailed => git.last_err,
        } };
        self.resolved.append(self.arena(), .{ .name = name, .entry = .{ .source = url, .ref = ref, .commit = commit } }) catch {};
        return .{ .ok = .{ .dir = dir, .commit = commit } };
    }

    fn loadGitInner(self: *Manager, git: *Git, dir: []const u8, name: []const u8, url: []const u8, ref: ?[]const u8) Git.Error![]const u8 {
        const network = self.phase.network();
        if (!dirExists(self.io, dir)) {
            if (!network) return git.fail("not installed; restart or run `blitz plugin update`", .{});
            if (self.phase == .startup) std.debug.print("blitz: installing {s}\n", .{name});
            try git.clone(self.io, url, self.plugins_dir.?, name);
        }

        var fetched = false;
        const origin = git.originUrl(dir) orelse "";
        if (!std.mem.eql(u8, origin, url)) {
            if (!network) return git.fail("source changed; restart or run `blitz plugin update`", .{});
            try git.setOrigin(dir, url);
            try git.fetch(dir, false);
            fetched = true;
        }

        const target = blk: {
            if (self.lockedCommit(name, url, ref)) |locked| {
                if (git.hasCommit(dir, locked)) break :blk locked;
                if (!network) return git.fail("locked commit {s} missing; restart or run `blitz plugin update`", .{short(locked)});
                if (!fetched) try git.fetch(dir, false);
                if (git.hasCommit(dir, locked)) break :blk locked;
                return git.fail("locked commit {s} not found on the remote", .{short(locked)});
            }
            if (git.resolve(dir, ref)) |res| break :blk res.commit else |err| {
                if (!network or fetched) return err;
            }
            try git.fetch(dir, false);
            break :blk (try git.resolve(dir, ref)).commit;
        };
        try git.checkoutClean(dir, target);
        return target;
    }

    /// The locked commit when the declaration matches its lock entry.
    fn lockedCommit(self: *const Manager, name: []const u8, url: []const u8, ref: ?[]const u8) ?[]const u8 {
        const entry = lockGet(&self.lock, name) orelse return null;
        if (!std.mem.eql(u8, entry.source, url)) return null;
        if ((entry.ref == null) != (ref == null)) return null;
        if (ref) |r| if (!std.mem.eql(u8, r, entry.ref.?)) return null;
        return entry.commit;
    }

    // ── blitz plugin update ───────────────────────────────────────────

    pub const UpdateOpts = struct {
        names: []const []const u8 = &.{},
        force: bool = false,
        prune: bool = true,
    };

    const Outcome = enum { installed, updated, unchanged, dirty };

    /// Returns the failure count. Reads the lock loaded by `begin`.
    pub fn update(self: *Manager, pool: *exec.CmdPool, decls: []const Decl, opts: UpdateOpts, out: *std.Io.Writer) !usize {
        const alloc = self.arena();
        var map = try self.lock.clone(alloc);
        var failures: usize = 0;
        var changed: usize = 0;

        for (opts.names) |name| {
            const decl = findDecl(decls, name) orelse {
                try out.print("failed     {s}: not declared\n", .{name});
                failures += 1;
                continue;
            };
            if (decl.url == null) try out.print("notice     {s}: path plugin, skipped\n", .{decl.name});
        }

        for (decls) |decl| {
            const url = decl.url orelse continue;
            if (opts.names.len > 0 and !nameListed(opts.names, decl.name)) continue;
            var git = Git{ .pool = pool, .arena = alloc };
            const dir = self.gitDir(alloc, decl.name) orelse {
                try out.print("failed     {s}: no plugin data directory\n", .{decl.name});
                failures += 1;
                continue;
            };
            const old_head = if (dirExists(self.io, dir)) git.head(dir) else null;
            const outcome = self.updateOne(&git, &map, decl, url, dir, opts.force) catch |err| {
                try out.print("failed     {s}: {s}\n", .{ decl.name, if (err == error.OutOfMemory) "out of memory" else git.last_err });
                failures += 1;
                continue;
            };
            const commit = if (lockGet(&map, decl.name)) |e| short(e.commit) else "";
            switch (outcome) {
                .installed => try out.print("installed  {s} {s}\n", .{ decl.name, commit }),
                .updated => try out.print("updated    {s} {s} -> {s}\n", .{ decl.name, short(old_head orelse ""), commit }),
                .unchanged => try out.print("unchanged  {s} {s}\n", .{ decl.name, commit }),
                .dirty => try out.print("skipped    {s}: local changes\n", .{decl.name}),
            }
            if (outcome == .installed or outcome == .updated) changed += 1;
        }

        if (opts.prune) try self.prune(pool, decls, &map, out);

        if (self.lock_path) |path| {
            if (try writeLockIfChanged(alloc, self.io, path, &map)) try out.print("wrote      {s}\n", .{path});
        }
        try out.print("{d} changed, {d} failed\n", .{ changed, failures });
        return failures;
    }

    // ── blitz plugin list ─────────────────────────────────────────────

    /// One line per declaration: name, kind, ref or path, checkout, status.
    /// Local git ops only; never fetches.
    pub fn list(self: *Manager, pool: *exec.CmdPool, decls: []const Decl, out: *std.Io.Writer) !void {
        if (decls.len == 0) return out.writeAll("no plugins declared\n");
        var width: usize = 0;
        for (decls) |decl| width = @max(width, decl.name.len);
        const alloc = self.arena();
        for (decls) |decl| {
            try out.writeAll(decl.name);
            try out.splatByteAll(' ', width - decl.name.len + 2);
            const path = decl.path orelse {
                try out.print("git   {s}  {s}\n", .{ decl.ref orelse "-", try self.gitStatus(pool, alloc, decl) });
                continue;
            };
            const entry = try entryPath(alloc, path, decl.name);
            try out.print("path  {s}  {s}\n", .{ path, if (fileExists(self.io, entry)) "ok" else "missing" });
        }
    }

    fn gitStatus(self: *Manager, pool: *exec.CmdPool, alloc: Allocator, decl: Decl) ![]const u8 {
        const dir = self.gitDir(alloc, decl.name) orelse return "no plugin data directory";
        if (!dirExists(self.io, dir)) return "not installed";
        var git = Git{ .pool = pool, .arena = alloc };
        const head = git.head(dir) orelse return "not a git checkout";
        const dirty = git.isDirty(dir) catch return git.last_err;
        const status = if (dirty)
            "local changes"
        else if (lockGet(&self.lock, decl.name)) |locked|
            (if (std.mem.eql(u8, locked.commit, head)) "ok" else "not at locked commit")
        else
            "not locked";
        return std.fmt.allocPrint(alloc, "{s}  {s}", .{ short(head), status });
    }

    fn updateOne(self: *Manager, git: *Git, map: *LockMap, decl: Decl, url: []const u8, dir: []const u8, force: bool) Git.Error!Outcome {
        var installed = false;
        if (!dirExists(self.io, dir)) {
            try git.clone(self.io, url, self.plugins_dir.?, decl.name);
            installed = true;
        } else {
            if (try git.isDirty(dir)) return .dirty;
            if (!std.mem.eql(u8, git.originUrl(dir) orelse "", url)) try git.setOrigin(dir, url);
            try git.fetch(dir, force);
        }
        const res = try git.resolve(dir, decl.ref);
        const target = blk: {
            if (res.kind.floats() or force) break :blk res.commit;
            const locked = self.lockedCommit(decl.name, url, decl.ref) orelse break :blk res.commit;
            break :blk if (git.hasCommit(dir, locked)) locked else res.commit;
        };
        const before = git.head(dir);
        try git.checkoutClean(dir, target);
        try lockPut(git.arena, map, decl.name, .{ .source = url, .ref = decl.ref, .commit = target });
        if (installed) return .installed;
        if (before) |b| if (std.mem.eql(u8, b, target)) return .unchanged;
        return .updated;
    }

    /// Delete clean clones that no git declaration references, and drop
    /// lock entries for undeclared plugins.
    fn prune(self: *Manager, pool: *exec.CmdPool, decls: []const Decl, map: *LockMap, out: *std.Io.Writer) !void {
        const alloc = self.arena();
        if (self.plugins_dir) |root| prune_dirs: {
            var dir = std.Io.Dir.openDirAbsolute(self.io, root, .{ .iterate = true }) catch break :prune_dirs;
            defer dir.close(self.io);
            var stale: std.ArrayList([]const u8) = .empty;
            var it = dir.iterate();
            while (it.next(self.io) catch null) |entry| {
                if (entry.kind != .directory or entry.name[0] == '.') continue;
                if (isGitDeclared(decls, entry.name)) continue;
                try stale.append(alloc, try alloc.dupe(u8, entry.name));
            }
            for (stale.items) |name| {
                var git = Git{ .pool = pool, .arena = alloc };
                const path = try std.fs.path.join(alloc, &.{ root, name });
                const dirty = git.isDirty(path) catch true;
                if (dirty) {
                    try out.print("kept       {s}: local changes or not a git checkout\n", .{name});
                    continue;
                }
                std.Io.Dir.cwd().deleteTree(self.io, path) catch |err| {
                    try out.print("failed     {s}: prune: {s}\n", .{ name, @errorName(err) });
                    continue;
                };
                lockRemove(map, name);
                try out.print("pruned     {s}\n", .{name});
            }
        }
        var i: usize = 0;
        while (i < map.count()) {
            const key = map.keys()[i];
            if (!isGitDeclared(decls, key)) {
                _ = map.orderedRemove(key);
                continue;
            }
            i += 1;
        }
    }
};

fn findDecl(decls: []const Decl, name: []const u8) ?Decl {
    for (decls) |decl| if (eqlName(decl.name, name)) return decl;
    return null;
}

fn nameListed(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (eqlName(n, name)) return true;
    return false;
}

fn isGitDeclared(decls: []const Decl, name: []const u8) bool {
    for (decls) |decl| if (decl.url != null and eqlName(decl.name, name)) return true;
    return false;
}

// ── blitz plugin create ───────────────────────────────────────────────

/// Scaffold a plugin in `dir_arg`. Writes nothing when the name is invalid or
/// the target is not a directory. Messages go to `out`.
pub fn create(io: std.Io, arena: Allocator, dir_arg: []const u8, out: *std.Io.Writer) !void {
    const cwd = std.Io.Dir.cwd();
    const base = try cwd.realPathFileAlloc(io, ".", arena);
    const target = try std.fs.path.resolve(arena, &.{ base, dir_arg });
    const name = std.fs.path.basename(target);
    if (!isValidName(name)) {
        try out.print("Error: invalid plugin name '{s}'; use letters, digits, '_' and '-'\n", .{name});
        return error.InvalidName;
    }
    if (cwd.statFile(io, target, .{})) |stat| {
        if (stat.kind != .directory) {
            try out.print("Error: {s} exists and is not a directory\n", .{target});
            return error.NotADirectory;
        }
    } else |_| {}
    try cwd.createDirPath(io, target);
    var dir = try std.Io.Dir.openDirAbsolute(io, target, .{});
    defer dir.close(io);

    const module_dir = try std.fmt.allocPrint(arena, "lua/{s}", .{name});
    try dir.createDirPath(io, module_dir);
    const module = try std.fmt.allocPrint(arena, "{s}/init.lua", .{module_dir});
    const entry = try std.fmt.allocPrint(arena, ENTRY_TEMPLATE, .{name});
    try out.print("{s} {s}\n", .{ if (try writeIfMissing(io, dir, module, entry)) "created" else "kept   ", module });
    try dir.writeFile(io, .{ .sub_path = "meta.lua", .data = defaults.LUA_META_FILE });
    try out.writeAll("wrote   meta.lua\n");
    try out.print("{s} .luarc.json\n", .{if (try writeIfMissing(io, dir, ".luarc.json", PLUGIN_LUARC)) "created" else "kept   "});

    const canonical = dir.realPathFileAlloc(io, ".", arena) catch target;
    try out.print("\nAdd to your blitz.lua:\n  blitz.plugin({f}, {{ path = {f} }})\n  local {s} = require({f})\n  {s}.setup({{}})\n", .{
        std.json.fmt(name, .{}),
        std.json.fmt(canonical, .{}),
        luaIdent(arena, name),
        std.json.fmt(name, .{}),
        luaIdent(arena, name),
    });
}

/// `my-plugin` -> `my_plugin`, a usable local name for the module.
fn luaIdent(arena: Allocator, name: []const u8) []const u8 {
    const out = arena.dupe(u8, name) catch return "exports";
    std.mem.replaceScalar(u8, out, '-', '_');
    return if (std.ascii.isDigit(out[0])) "exports" else out;
}

/// `.luarc.json` for the config dir: meta.lua plus each plugin's `lua/` dir,
/// like lazydev does, so `require("<name>")` resolves into the plugin source.
/// With no plugins this equals `defaults.LUARC_CONTENT`.
pub fn renderLuarc(arena: Allocator, plugin_dirs: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("{\n  \"workspace\": {\n    \"library\": [\n      \"meta.lua\"");
    for (plugin_dirs) |dir| {
        const lua_dir = try std.fs.path.join(arena, &.{ dir, "lua" });
        try w.print(",\n      {f}", .{std.json.fmt(lua_dir, .{})});
    }
    try w.writeAll("\n    ]\n  }\n}");
    return out.written();
}

/// Rewrites `<config_dir>/.luarc.json` when its content changes.
pub fn writeLuarc(arena: Allocator, io: std.Io, config_dir: []const u8, plugin_dirs: []const []const u8) !void {
    const next = try renderLuarc(arena, plugin_dirs);
    const path = try std.fs.path.join(arena, &.{ config_dir, ".luarc.json" });
    const cwd = std.Io.Dir.cwd();
    if (cwd.readFileAlloc(io, path, arena, .limited(LOCK_MAX_BYTES))) |current| {
        if (std.mem.eql(u8, current, next)) return;
    } else |_| {}
    try cwd.writeFile(io, .{ .sub_path = path, .data = next });
}

fn writeIfMissing(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, data: []const u8) !bool {
    const file = dir.createFile(io, sub_path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return false,
        else => return err,
    };
    defer file.close(io);
    try file.writeStreamingAll(io, data);
    return true;
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

test "names and urls validate" {
    try testing.expect(isValidName("blitz-tools_2"));
    try testing.expect(!isValidName("foo.nvim"));
    try testing.expect(!isValidName("a/b"));
    try testing.expect(!isValidName(""));
    try testing.expect(isFullGitUrl("https://github.com/o/r.git"));
    try testing.expect(isFullGitUrl("git@github.com:o/r.git"));
    try testing.expect(isFullGitUrl("file:///tmp/repo"));
    try testing.expect(!isFullGitUrl("owner/repo"));
    try testing.expect(isFullSha("0123456789abcdef0123456789abcdef01234567"));
    try testing.expect(!isFullSha("0123456"));
    try testing.expect(!isRefName("-x"));
    try testing.expect(!isRefName("a..b"));
    try testing.expect(isRefName("release/v1"));
}

test "lockfile renders sorted and round-trips" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const path = try std.fs.path.join(arena, &.{ dir, LOCK_FILE });

    var map: LockMap = .empty;
    try lockPut(arena, &map, "zeta", .{ .source = "https://x/zeta.git", .commit = "bbb" });
    try lockPut(arena, &map, "alpha", .{ .source = "https://x/alpha.git", .ref = "v1", .commit = "aaa" });
    try testing.expect(try writeLockIfChanged(arena, testing.io, path, &map));
    try testing.expect(!try writeLockIfChanged(arena, testing.io, path, &map));

    const raw = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(LOCK_MAX_BYTES));
    try testing.expect(std.mem.indexOf(u8, raw, "\"alpha\"").? < std.mem.indexOf(u8, raw, "\"zeta\"").?);
    try testing.expect(std.mem.indexOf(u8, raw, "\"ref\": null") != null);

    const read = readLock(arena, testing.io, path);
    try testing.expectEqual(@as(usize, 2), read.count());
    try testing.expectEqualStrings("v1", lockGet(&read, "ALPHA").?.ref.?);
    try testing.expectEqual(@as(?[]const u8, null), lockGet(&read, "zeta").?.ref);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = LOCK_FILE, .data = "{not json" });
    try testing.expectEqual(@as(usize, 0), readLock(arena, testing.io, path).count());
}

test "a failed load keeps the previous lockfile and a clean load merges" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    var mgr = Manager.init(testing.allocator, testing.io);
    defer mgr.deinit();
    try mgr.configure(null, dir, null);
    const seed =
        \\{
        \\  "version": 1,
        \\  "plugins": {
        \\    "a": { "source": "https://x/a.git", "ref": null, "commit": "aaa" },
        \\    "b": { "source": "https://x/b.git", "ref": null, "commit": "bbb" }
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = LOCK_FILE, .data = seed });

    mgr.begin(.startup);
    try mgr.resolved.append(mgr.arena(), .{ .name = "a", .entry = .{ .source = "https://x/a.git", .commit = "a2" } });
    mgr.finish(false);
    const after_fail = try tmp.dir.readFileAlloc(testing.io, LOCK_FILE, mgr.arena(), .limited(LOCK_MAX_BYTES));
    try testing.expectEqualStrings(seed, after_fail);

    mgr.begin(.startup);
    try mgr.resolved.append(mgr.arena(), .{ .name = "a", .entry = .{ .source = "https://x/a.git", .commit = "a2" } });
    mgr.finish(true);
    const merged = readLock(mgr.arena(), testing.io, mgr.lock_path.?);
    try testing.expectEqualStrings("a2", lockGet(&merged, "a").?.commit);
    try testing.expectEqualStrings("bbb", lockGet(&merged, "b").?.commit);
}

test "snapshot lookups are case-insensitive" {
    var mgr = Manager.init(testing.allocator, testing.io);
    defer mgr.deinit();
    mgr.begin(.startup);
    mgr.record(.{ .name = "Tools", .dir = "/p/Tools", .loaded = true });
    mgr.finish(false);
    try testing.expect(mgr.find("tools").?.loaded);
    try testing.expectEqual(@as(?*const SnapshotEntry, null), mgr.find("other"));
}

test "create scaffolds a plugin and refreshes only meta.lua" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const target = try std.fs.path.join(arena, &.{ root, "nested", "my-plugin" });
    var sink: std.Io.Writer.Allocating = .init(arena);

    try create(testing.io, arena, target, &sink.writer);
    const entry = try tmp.dir.readFileAlloc(testing.io, "nested/my-plugin/lua/my-plugin/init.lua", arena, .unlimited);
    try testing.expect(std.mem.startsWith(u8, entry, "local M = {}\n\nM.tools = {}\n"));
    try testing.expect(std.mem.indexOf(u8, entry, "function M.setup(opts)") != null);
    try testing.expect(std.mem.endsWith(u8, entry, "return M\n"));
    try testing.expect(std.mem.indexOf(u8, sink.written(), "blitz.plugin(\"my-plugin\", { path = ") != null);
    try testing.expect(std.mem.indexOf(u8, sink.written(), "local my_plugin = require(\"my-plugin\")\n  my_plugin.setup({})") != null);
    try testing.expectEqualStrings(defaults.LUA_META_FILE, try tmp.dir.readFileAlloc(testing.io, "nested/my-plugin/meta.lua", arena, .unlimited));
    try testing.expectEqualStrings(PLUGIN_LUARC, try tmp.dir.readFileAlloc(testing.io, "nested/my-plugin/.luarc.json", arena, .unlimited));

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "nested/my-plugin/lua/my-plugin/init.lua", .data = "-- mine" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "nested/my-plugin/.luarc.json", .data = "{}" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "nested/my-plugin/meta.lua", .data = "stale" });
    try create(testing.io, arena, target, &sink.writer);
    try testing.expectEqualStrings("-- mine", try tmp.dir.readFileAlloc(testing.io, "nested/my-plugin/lua/my-plugin/init.lua", arena, .unlimited));
    try testing.expectEqualStrings("{}", try tmp.dir.readFileAlloc(testing.io, "nested/my-plugin/.luarc.json", arena, .unlimited));
    try testing.expectEqualStrings(defaults.LUA_META_FILE, try tmp.dir.readFileAlloc(testing.io, "nested/my-plugin/meta.lua", arena, .unlimited));

    const bad = try std.fs.path.join(arena, &.{ root, "foo.nvim" });
    try testing.expectError(error.InvalidName, create(testing.io, arena, bad, &sink.writer));
    try testing.expect(!fileExists(testing.io, bad));

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "afile", .data = "x" });
    const file_target = try std.fs.path.join(arena, &.{ root, "afile" });
    try testing.expectError(error.NotADirectory, create(testing.io, arena, file_target, &sink.writer));
}

fn testGit(git: *Git, dir: []const u8, args: []const []const u8) ![]const u8 {
    var full: std.ArrayList([]const u8) = .empty;
    try full.appendSlice(git.arena, &.{ "-c", "user.email=t@t", "-c", "user.name=t", "-c", "init.defaultBranch=main" });
    try full.appendSlice(git.arena, args);
    return git.run(dir, full.items, false) catch |err| {
        std.debug.print("git {s}: {s}\n", .{ args[0], git.last_err });
        return err;
    };
}

test "git loads follow the phase policy, the lock, and ref resolution" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env = try std.process.Environ.createMap(testing.environ, testing.allocator);
    defer env.deinit();
    var pool = exec.CmdPool.init(testing.allocator, testing.io, &env);
    defer pool.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "origin");
    try tmp.dir.createDirPath(testing.io, "cfg");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const origin = try std.fs.path.join(arena, &.{ root, "origin" });
    const url = try std.fmt.allocPrint(arena, "file://{s}", .{origin});

    var git = Git{ .pool = &pool, .arena = arena };
    _ = try testGit(&git, origin, &.{"init"});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "origin/blitz.lua", .data = "-- v1" });
    _ = try testGit(&git, origin, &.{ "add", "-A" });
    _ = try testGit(&git, origin, &.{ "commit", "-qm", "v1" });
    _ = try testGit(&git, origin, &.{ "tag", "v1" });
    const v1 = try testGit(&git, origin, &.{ "rev-parse", "HEAD" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "origin/blitz.lua", .data = "-- v2" });
    _ = try testGit(&git, origin, &.{ "commit", "-qam", "v2" });
    const v2 = try testGit(&git, origin, &.{ "rev-parse", "HEAD" });

    var mgr = Manager.init(testing.allocator, testing.io);
    defer mgr.deinit();
    try mgr.configure(root, try std.fs.path.join(arena, &.{ root, "cfg" }), null);

    mgr.begin(.reload);
    try testing.expectStringStartsWith(mgr.loadGit(&pool, "p", url, null).err, "not installed");

    mgr.begin(.update);
    try testing.expectEqualStrings(v2, mgr.loadGit(&pool, "p", url, null).ok.commit);
    try testing.expectEqualStrings(v1, mgr.loadGit(&pool, "t", url, "v1").ok.commit);
    try testing.expectStringStartsWith(mgr.loadGit(&pool, "s", url, "abc1234").err, "ref 'abc1234' not found");
    mgr.finish(true);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "origin/blitz.lua", .data = "-- v3" });
    _ = try testGit(&git, origin, &.{ "commit", "-qam", "v3" });

    // A floating ref stays on the locked commit until `blitz plugin update`.
    mgr.begin(.reload);
    try testing.expectEqualStrings(v2, mgr.loadGit(&pool, "p", url, null).ok.commit);

    // A changed source needs the network, so a reload refuses it.
    try testing.expectStringStartsWith(mgr.loadGit(&pool, "p", "file:///elsewhere", null).err, "source changed");

    // Tracked local changes block a checkout to another commit.
    const clone = mgr.gitDir(arena, "t").?;
    const local = try std.fs.path.join(arena, &.{ clone, "blitz.lua" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = local, .data = "-- local" });
    mgr.begin(.update);
    try testing.expectStringStartsWith(mgr.loadGit(&pool, "t", url, null).err, "local changes block checkout");
}

test "list reports path plugins and missing git clones without git" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "plug/lua/plug");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plug/lua/plug/init.lua", .data = "" });
    var mgr = Manager.init(testing.allocator, testing.io);
    defer mgr.deinit();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try mgr.configure(root, null, null);
    mgr.begin(.update);
    const plug = try std.fs.path.join(mgr.arena(), &.{ root, "plug" });
    const gone = try std.fs.path.join(mgr.arena(), &.{ root, "gone" });
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    var pool = exec.CmdPool.init(testing.allocator, testing.io, &env);
    defer pool.deinit();
    var sink: std.Io.Writer.Allocating = .init(mgr.arena());

    try mgr.list(&pool, &.{
        .{ .name = "plug", .path = plug },
        .{ .name = "gone", .path = gone },
        .{ .name = "remote", .url = "https://x/remote.git", .ref = "v1" },
    }, &sink.writer);
    const text = sink.written();
    try testing.expect(std.mem.indexOf(u8, text, "plug    path  ") != null);
    try testing.expect(std.mem.endsWith(u8, std.mem.sliceTo(text, '\n'), "  ok"));
    try testing.expect(std.mem.indexOf(u8, text, "/gone  missing\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "remote  git   v1  not installed\n") != null);

    sink.clearRetainingCapacity();
    try mgr.list(&pool, &.{}, &sink.writer);
    try testing.expectEqualStrings("no plugins declared\n", sink.written());
}

test "luarc lists plugin entries and matches the default without plugins" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings(defaults.LUARC_CONTENT, try renderLuarc(arena, &.{}));
    const text = try renderLuarc(arena, &.{"/p/acme"});
    const parsed = try std.json.parseFromSliceLeaky(struct { workspace: struct { library: []const []const u8 } }, arena, text, .{});
    try testing.expectEqual(@as(usize, 2), parsed.workspace.library.len);
    try testing.expectEqualStrings("/p/acme/lua", parsed.workspace.library[1]);
}
