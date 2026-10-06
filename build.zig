const std = @import("std");

pub fn build(b: *std.Build) void {
    const target =
        b.standardTargetOptions(.{});

    const optimize =
        b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "pico_claw",

        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),

            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const run_step =
        b.step("run", "Run Pico Claw");

    const run_cmd =
        b.addRunArtifact(exe);

    run_step.dependOn(
        &run_cmd.step,
    );

    run_cmd.step.dependOn(
        b.getInstallStep(),
    );

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),

        .target = target,
        .optimize = optimize,
    });

    const exe_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_exe_tests =
        b.addRunArtifact(exe_tests);

    // Deterministic MCP test server: built (and installed) alongside the test
    // binary and handed to the tests through the environment so they can
    // spawn a real MCP server over real stdio pipes without the internet.
    const mcp_test_server = b.addExecutable(.{
        .name = "pico_mcp_test_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mcp/test_server.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const install_mcp_test_server =
        b.addInstallArtifact(mcp_test_server, .{});

    run_exe_tests.step.dependOn(&install_mcp_test_server.step);
    run_exe_tests.setEnvironmentVariable(
        "PICO_MCP_TEST_SERVER",
        b.getInstallPath(
            .bin,
            if (target.result.os.tag == .windows)
                "pico_mcp_test_server.exe"
            else
                "pico_mcp_test_server",
        ),
    );

    const test_step =
        b.step("test", "Run Pico Claw tests");

    test_step.dependOn(
        &run_exe_tests.step,
    );
}
