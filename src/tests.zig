// Test root used by `zig build test`.
//
// Zig only analyzes `test` blocks from the root file and from files that its
// tests reference. Referencing every module here keeps the full suite - all
// inline tests in src/ - discoverable through the documented
// `zig build test` command instead of compiling a zero-test binary.
//
// Note: `std_options` declared here is NOT honored by the compiler-generated
// test runner root in Zig 0.16 (std.options is resolved from the runner, not
// this file), so expected-diagnostic noise is suppressed at the call sites
// with `builtin.is_test` instead.

test {
    _ = @import("main.zig");
    _ = @import("brain.zig");
    _ = @import("config.zig");
    _ = @import("format.zig");
    _ = @import("core/agent.zig");
    _ = @import("core/capabilities.zig");
    _ = @import("core/context.zig");
    _ = @import("core/conversation.zig");
    _ = @import("core/task.zig");
    _ = @import("core/task_store.zig");
    _ = @import("core/router.zig");
    _ = @import("channels/channel.zig");
    _ = @import("channels/session.zig");
    _ = @import("channels/telegram.zig");
    _ = @import("experience/proposal.zig");
    _ = @import("experience/task_evaluation.zig");
    _ = @import("env_loader.zig");
    _ = @import("executor.zig");
    _ = @import("experience/entry.zig");
    _ = @import("experience/evaluation.zig");
    _ = @import("experience/learning.zig");
    _ = @import("experience/reflection.zig");
    _ = @import("experience/store.zig");
    _ = @import("experience/strategy_store.zig");
    _ = @import("interfaces/cli.zig");
    _ = @import("interfaces/http.zig");
    _ = @import("knowledge.zig");
    _ = @import("memory/entry.zig");
    _ = @import("memory/memory.zig");
    _ = @import("memory/store.zig");
    _ = @import("owner.zig");
    _ = @import("planner.zig");
    _ = @import("provider.zig");
    _ = @import("services/gateways.zig");
    _ = @import("services/models.zig");
    _ = @import("services/profiles.zig");
    _ = @import("services/service.zig");
    _ = @import("services/settings.zig");
    _ = @import("skills.zig");
    _ = @import("tools/calculator.zig");
    _ = @import("tools/filesystem.zig");
    _ = @import("tools/registry.zig");
    _ = @import("tools/system.zig");
    _ = @import("tools/tool.zig");
    _ = @import("runtime/sandbox.zig");
    _ = @import("runtime/fsops.zig");
    _ = @import("runtime/process.zig");
    _ = @import("runtime/archives.zig");
    _ = @import("runtime/media.zig");
    _ = @import("runtime/tools.zig");
    _ = @import("mcp/jsonrpc.zig");
    _ = @import("mcp/config.zig");
    _ = @import("mcp/client.zig");
    _ = @import("mcp/registry.zig");
    _ = @import("core/runs.zig");
    _ = @import("core/jobs.zig");
    _ = @import("runtime/attachments.zig");
    _ = @import("services/artifacts.zig");
    _ = @import("services/doctor.zig");
}
