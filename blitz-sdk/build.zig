const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdk_mod = b.addModule("blitz-sdk", .{
        .root_source_file = b.path("src/sdk.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "blitz-sdk", .module = sdk_mod },
        },
    });

    const live_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/live_opencode_go.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "blitz-sdk", .module = sdk_mod },
        },
    });

    const sdk_tests = b.addTest(.{ .root_module = sdk_mod });
    const integration_tests = b.addTest(.{ .root_module = tests_mod });
    const run_sdk_tests = b.addRunArtifact(sdk_tests);
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const test_step = b.step("test", "Run SDK tests");
    test_step.dependOn(&run_sdk_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    const live_tests = b.addTest(.{ .root_module = live_tests_mod });
    const run_live_tests = b.addRunArtifact(live_tests);
    const live_test_step = b.step("test-live", "Run live OpenCode Go API tests");
    live_test_step.dependOn(&run_live_tests.step);
}
