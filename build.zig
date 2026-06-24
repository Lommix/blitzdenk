const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const provider_mod = b.addModule("provider", .{
        .root_source_file = b.path("src/provider/root.zig"),
        .target = target,
    });

    // -- Lua 5.4 (vendored) — translated header + C sources fused into one module --
    const lua_c_mod = build_lua_c(b, target, optimize);

    const exe = b.addExecutable(.{
        .name = "blitz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "provider", .module = provider_mod },
                .{ .name = "c", .module = lua_c_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    // -----------------------------------------------
    // lua
    const gen = b.addExecutable(.{
        .name = "gen_lua",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lua_gen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "provider", .module = provider_mod },
                .{ .name = "c", .module = lua_c_mod },
            },
        }),
    });
    b.installArtifact(gen);
    const gen_step = b.step("gen", "Run the app");
    const run_lua_gen = b.addRunArtifact(gen);
    gen_step.dependOn(&run_lua_gen.step);
    run_lua_gen.step.dependOn(b.getInstallStep());
    // -----------------------------------------------

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = provider_mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

fn build_lua_c(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const trans = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("vendor/lua/lua_c.h"),
        .link_libc = true,
    });

    const mod = trans.createModule();

    if (target.result.os.tag == .linux) {
        mod.addCMacro("LUA_USE_LINUX", "1");
    }
    if (target.result.os.tag.isDarwin()) {
        mod.addCMacro("LUA_USE_MACOSX", "1");
    }

    mod.addCSourceFiles(.{
        .root = b.path("vendor/lua"),
        .files = &.{
            "lapi.c",
            "lauxlib.c",
            "lbaselib.c",
            "lcode.c",
            "lcorolib.c",
            "lctype.c",
            "ldblib.c",
            "ldebug.c",
            "ldo.c",
            "ldump.c",
            "lfunc.c",
            "lgc.c",
            "linit.c",
            "liolib.c",
            "llex.c",
            "lmathlib.c",
            "lmem.c",
            "loadlib.c",
            "lobject.c",
            "lopcodes.c",
            "loslib.c",
            "lparser.c",
            "lstate.c",
            "lstring.c",
            "lstrlib.c",
            "ltable.c",
            "ltablib.c",
            "ltm.c",
            "lundump.c",
            "lutf8lib.c",
            "lvm.c",
            "lzio.c",
        },
        .flags = &.{"-std=c99"},
    });

    return mod;
}
