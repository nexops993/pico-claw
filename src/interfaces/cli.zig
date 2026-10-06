const std = @import("std");
const builtin = @import("builtin");
const ui = @import("ui.zig");
const ProposalStore = @import("../experience/proposal.zig").ProposalStore;
const ProposalStatus = @import("../experience/proposal.zig").ProposalStatus;

/// CLI output is silenced in tests so expected messages never look like a
/// failing command to the test runner.
/// Internal test/diagnostic printer kept for usage text on stderr.
fn cliPrint(comptime format: []const u8, args: anytype) void {
    if (!builtin.is_test) std.debug.print(format, args);
}

pub const ProposalsAction = enum {
    list,
    accept,
    reject,
};

pub const ProposalsCommand = struct {
    action: ProposalsAction = .list,
    id: ?u64 = null,
};

pub const ChannelAction = enum {
    status,
    telegram,
};

pub const ChannelCommand = struct {
    action: ChannelAction = .status,
};

pub const RuntimeCommand = union(enum) {
    chat,
    serve,
    status,
    help,
    version,
    doctor,
    install,
    uninstall: UninstallCommand,
    update: UpdateCommand,
    proposals: ProposalsCommand,
    channel: ChannelCommand,
};

pub const UninstallCommand = struct {
    /// Destructive step guard: without --yes the command only reports what
    /// it would remove and changes nothing.
    yes: bool = false,
};

pub const UpdateCommand = struct {
    /// `update --check` prints the current/expected release coordinates.
    /// Binary download/replacement is not implemented until signed release
    /// infrastructure exists, so this is the entire honest surface today.
    check_only: bool = false,
};

pub fn parseArgs(iterator: *std.process.Args.Iterator) !ParsedInvocation {
    _ = iterator.next();
    var buffer: [8][]const u8 = undefined;
    var count: usize = 0;
    while (iterator.next()) |arg| {
        if (count == buffer.len) return error.InvalidArguments;
        buffer[count] = arg;
        count += 1;
    }
    return parseSlice(buffer[0..count]);
}

pub const ParsedInvocation = struct {
    command: RuntimeCommand,
    debug: bool = false,
};

/// Pure argument parsing over the command words (program name excluded), so
/// the CLI surface is testable without constructing process arguments.
/// `--debug` may appear anywhere and enables internal diagnostics.
pub fn parseSlice(args: []const []const u8) !ParsedInvocation {
    var debug = false;
    var filtered: [8][]const u8 = undefined;
    var count: usize = 0;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--debug")) {
            debug = true;
            continue;
        }
        if (count == filtered.len) return error.InvalidArguments;
        filtered[count] = arg;
        count += 1;
    }
    return .{ .command = try parseCommand(filtered[0..count]), .debug = debug };
}

fn parseCommand(args: []const []const u8) !RuntimeCommand {
    if (args.len == 0) return .chat;
    const value = args[0];

    const simple: ?RuntimeCommand = blk: {
        if (std.mem.eql(u8, value, "chat")) break :blk .chat;
        if (std.mem.eql(u8, value, "serve")) break :blk .serve;
        if (std.mem.eql(u8, value, "status")) break :blk .status;
        if (std.mem.eql(u8, value, "doctor")) break :blk .doctor;
        if (std.mem.eql(u8, value, "install")) break :blk .install;
        if (std.mem.eql(u8, value, "--help") or std.mem.eql(u8, value, "-h")) break :blk .help;
        if (std.mem.eql(u8, value, "--version")) break :blk .version;
        break :blk null;
    };
    if (simple) |command| {
        if (args.len != 1) return error.InvalidArguments;
        return command;
    }
    if (std.mem.eql(u8, value, "proposals")) return parseProposals(args[1..]);
    if (std.mem.eql(u8, value, "channel")) return parseChannel(args[1..]);
    // Uninstall and update take one optional flag each (`--yes` / future
    // release flags); they never run destructive steps without it.
    if (std.mem.eql(u8, value, "uninstall")) return parseUninstall(args[1..]);
    if (std.mem.eql(u8, value, "update")) return parseUpdate(args[1..]);
    return error.InvalidArguments;
}

fn parseUninstall(args: []const []const u8) !RuntimeCommand {
    if (args.len == 0) return .{ .uninstall = .{} };
    if (std.mem.eql(u8, args[0], "--yes")) {
        if (args.len != 1) return error.InvalidArguments;
        return .{ .uninstall = .{ .yes = true } };
    }
    return error.InvalidArguments;
}

fn parseUpdate(args: []const []const u8) !RuntimeCommand {
    if (args.len == 0) return .{ .update = .{} };
    if (std.mem.eql(u8, args[0], "--check")) {
        if (args.len != 1) return error.InvalidArguments;
        return .{ .update = .{ .check_only = true } };
    }
    return error.InvalidArguments;
}

fn parseChannel(args: []const []const u8) !RuntimeCommand {
    if (args.len == 0) return .{ .channel = .{} };
    if (std.mem.eql(u8, args[0], "status")) {
        if (args.len != 1) return error.InvalidArguments;
        return .{ .channel = .{ .action = .status } };
    }
    if (std.mem.eql(u8, args[0], "telegram")) {
        if (args.len != 1) return error.InvalidArguments;
        return .{ .channel = .{ .action = .telegram } };
    }
    return error.InvalidArguments;
}

fn parseProposals(args: []const []const u8) !RuntimeCommand {
    if (args.len == 0) return .{ .proposals = .{} };
    if (std.mem.eql(u8, args[0], "list")) {
        if (args.len != 1) return error.InvalidArguments;
        return .{ .proposals = .{} };
    }
    const action: ProposalsAction = blk: {
        if (std.mem.eql(u8, args[0], "accept")) break :blk .accept;
        if (std.mem.eql(u8, args[0], "reject")) break :blk .reject;
        return error.InvalidArguments;
    };
    if (args.len != 2) return error.InvalidArguments;
    const id = std.fmt.parseInt(u64, args[1], 10) catch return error.InvalidArguments;
    return .{ .proposals = .{ .action = action, .id = id } };
}

pub fn printUsage() void {
    cliPrint("Usage: pico_claw [chat|serve|status|doctor|install|uninstall [--yes]|update --check|proposals [list|accept <id>|reject <id>]|channel [status|telegram]|--debug|--help|--version]\n", .{});
}

/// M4 proposal CLI flow. Listing shows metadata only; accepting or rejecting
/// records the decision and, for accepted proposals, prints the explicit
/// manual application instructions. Accepting never runs code, never mutates
/// other stores, and never applies a change automatically.
pub fn runProposals(
    io: std.Io,
    store: *ProposalStore,
    request: ProposalsCommand,
) void {
    switch (request.action) {
        .list => {
            std.debug.print(
                "Proposals: {d} ({d} proposed, {d} accepted, {d} rejected)\n",
                .{
                    store.count(),
                    store.countStatus(.proposed),
                    store.countStatus(.accepted),
                    store.countStatus(.rejected),
                },
            );
            if (store.records.items.len == 0) {
                std.debug.print("No proposals recorded.\n", .{});
                return;
            }
            for (store.records.items) |*record| {
                std.debug.print(
                    "\n#{d} [{s}] {s} confidence={d:.2}\n  problem: {s}\n  suggestion: {s}\n  basis: {s}\n  constraints: {s}\n",
                    .{
                        record.id,
                        record.status.name(),
                        record.kind.name(),
                        record.confidence,
                        record.problem,
                        record.suggestion,
                        record.confidence_basis,
                        record.constraints,
                    },
                );
                const error_code = if (record.evidence.error_code) |code| code else "none";
                std.debug.print(
                    "  evidence: task=#{d} route={s} state={s} error={s}/{s} attempts={d} escalations={d} latency={d}ms\n",
                    .{
                        record.evidence.task_id,
                        record.evidence.route.name(),
                        record.evidence.task_state.name(),
                        if (record.evidence.error_kind) |kind| kind.name() else "none",
                        error_code,
                        record.evidence.attempts,
                        record.evidence.escalations,
                        record.evidence.latency_ms,
                    },
                );
            }
        },
        .accept, .reject => {
            const id = request.id orelse {
                std.debug.print("A proposal id is required for accept/reject.\n", .{});
                return;
            };
            const status: ProposalStatus = if (request.action == .accept) .accepted else .rejected;
            store.decide(id, status, std.Io.Timestamp.now(io, .real).toMilliseconds()) catch |err| switch (err) {
                error.ProposalNotFound => {
                    std.debug.print("Proposal #{d} not found.\n", .{id});
                    return;
                },
                error.AlreadyDecided => {
                    std.debug.print("Proposal #{d} was already decided.\n", .{id});
                    return;
                },
                else => {
                    std.debug.print("Decision failed: {s}\n", .{@errorName(err)});
                    return;
                },
            };
            store.save() catch |err| {
                std.debug.print("Proposal save failed: {s}\n", .{@errorName(err)});
                return;
            };
            if (status == .accepted) {
                const record = store.find(id).?;
                std.debug.print(
                    "\nProposal #{d} accepted. No automatic change was made; apply manually after validation:\n  suggestion: {s}\n  constraints: {s}\n  provenance: task=#{d} route={s} attempts={d} escalations={d}\n",
                    .{
                        id,
                        record.suggestion,
                        record.constraints,
                        record.evidence.task_id,
                        record.evidence.route.name(),
                        record.evidence.attempts,
                        record.evidence.escalations,
                    },
                );
            } else {
                std.debug.print("\nProposal #{d} rejected.\n", .{id});
            }
        },
    }
}

pub const Command = enum {
    chat,
    exit,
    clear,
    help,
};

pub fn classify(input: []const u8) Command {
    if (std.mem.eql(u8, input, "exit") or std.mem.eql(u8, input, "quit") or
        std.mem.eql(u8, input, "/exit") or std.mem.eql(u8, input, "/quit")) return .exit;
    if (std.mem.eql(u8, input, "clear") or std.mem.eql(u8, input, "/clear")) return .clear;
    if (std.mem.eql(u8, input, "help") or std.mem.eql(u8, input, "/help")) return .help;
    return .chat;
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    conversation: anytype,
) !void {
    var buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &buffer);
    while (true) {
        ui.out(io, "{s}>{s} ", .{ ui.Color.dim.code(), ui.Color.reset.code() });
        const line = reader.interface.takeDelimiter('\n') catch |err| {
            ui.out(io, "\n", .{});
            ui.statusLine(io, .fail, "Input error");
            ui.out(io, "  {s}{s}{s}\n", .{ ui.Color.dim.code(), @errorName(err), ui.Color.reset.code() });
            return err;
        } orelse break;
        const input = std.mem.trim(u8, line, " \t\r\n");
        if (input.len == 0) continue;

        switch (classify(input)) {
            .exit => break,
            .help => printHelp(io),
            .clear => {
                conversation.clear() catch |err| {
                    ui.statusLine(io, .fail, "Clear failed");
                    ui.out(io, "  {s}{s}{s}\n", .{ ui.Color.dim.code(), @errorName(err), ui.Color.reset.code() });
                    continue;
                };
                ui.statusLine(io, .ok, "Conversation cleared");
            },
            .chat => {
                ui.showThinking(io);
                const reply = conversation.send(input) catch |err| {
                    ui.clearThinking(io);
                    ui.statusLine(io, .fail, "AI request failed");
                    ui.out(io, "  {s}{s}{s}\n", .{ ui.Color.dim.code(), @errorName(err), ui.Color.reset.code() });
                    continue;
                };
                ui.clearThinking(io);
                defer allocator.free(reply);
                ui.out(io, "\n  {s}Pico Claw{s}\n", .{ ui.Color.cyan.code(), ui.Color.reset.code() });
                ui.writeRaw(io, reply);
                ui.writeRaw(io, "\n\n");
            },
        }
    }
    ui.out(io, "{s}Bye!{s}\n", .{ ui.Color.dim.code(), ui.Color.reset.code() });
}

fn printHelp(io: std.Io) void {
    ui.out(io, "\n{s}Pico Claw commands{s}\n\n", .{ ui.Color.cyan.code(), ui.Color.reset.code() });
    ui.out(io, "  {s}help{s}     Show this help\n", .{ ui.Color.dim.code(), ui.Color.reset.code() });
    ui.out(io, "  {s}clear{s}    Clear the screen\n", .{ ui.Color.dim.code(), ui.Color.reset.code() });
    ui.out(io, "  {s}exit{s}     Exit Pico Claw\n", .{ ui.Color.dim.code(), ui.Color.reset.code() });
    ui.out(io, "  {s}quit{s}     Exit Pico Claw\n", .{ ui.Color.dim.code(), ui.Color.reset.code() });
    ui.out(io, "\n", .{});
}

test "cli classifies interactive commands" {
    try std.testing.expectEqual(Command.exit, classify("exit"));
    try std.testing.expectEqual(Command.exit, classify("quit"));
    try std.testing.expectEqual(Command.clear, classify("clear"));
    try std.testing.expectEqual(Command.help, classify("help"));
    try std.testing.expectEqual(Command.chat, classify("Halo"));
}

test "cli parses legacy and proposal commands" {
    const chat = try parseSlice(&.{});
    try std.testing.expect(chat.debug == false);
    try std.testing.expect(std.meta.activeTag(chat.command) == .chat);
    const debugged = try parseSlice(&.{ "--debug", "status" });
    try std.testing.expect(debugged.debug);
    try std.testing.expect(std.meta.activeTag(debugged.command) == .status);

    const list = try parseSlice(&.{"proposals"});
    try std.testing.expect(std.meta.activeTag(list.command) == .proposals);
    try std.testing.expectEqual(ProposalsAction.list, list.command.proposals.action);
    try std.testing.expect(list.command.proposals.id == null);

    const accept = try parseSlice(&.{ "proposals", "accept", "7" });
    try std.testing.expectEqual(ProposalsAction.accept, accept.command.proposals.action);
    try std.testing.expectEqual(@as(u64, 7), accept.command.proposals.id.?);

    const reject = try parseSlice(&.{ "proposals", "reject", "12" });
    try std.testing.expectEqual(ProposalsAction.reject, reject.command.proposals.action);
    try std.testing.expectEqual(@as(u64, 12), reject.command.proposals.id.?);

    try std.testing.expectError(error.InvalidArguments, parseSlice(&.{ "proposals", "accept" }));
    try std.testing.expectError(error.InvalidArguments, parseSlice(&.{ "proposals", "accept", "x" }));
    try std.testing.expectError(error.InvalidArguments, parseSlice(&.{ "proposals", "nope" }));
    try std.testing.expectError(error.InvalidArguments, parseSlice(&.{ "status", "extra" }));
    try std.testing.expectError(error.InvalidArguments, parseSlice(&.{"nonsense"}));
}

test "cli parses channel commands" {
    const bare = try parseSlice(&.{"channel"});
    try std.testing.expect(std.meta.activeTag(bare.command) == .channel);
    try std.testing.expectEqual(ChannelAction.status, bare.command.channel.action);

    const status = try parseSlice(&.{ "channel", "status" });
    try std.testing.expectEqual(ChannelAction.status, status.command.channel.action);

    const telegram = try parseSlice(&.{ "channel", "telegram" });
    try std.testing.expectEqual(ChannelAction.telegram, telegram.command.channel.action);

    try std.testing.expectError(error.InvalidArguments, parseSlice(&.{ "channel", "discord" }));
    try std.testing.expectError(error.InvalidArguments, parseSlice(&.{ "channel", "status", "extra" }));
    try std.testing.expectError(error.InvalidArguments, parseSlice(&.{ "channel", "telegram", "extra" }));
}

test "cli parses operations commands" {
    const doctor = try parseSlice(&.{"doctor"});
    try std.testing.expect(std.meta.activeTag(doctor.command) == .doctor);

    const install = try parseSlice(&.{"install"});
    try std.testing.expect(std.meta.activeTag(install.command) == .install);

    // Uninstall is a dry run without --yes, and refuses extra flags.
    const dry = try parseSlice(&.{"uninstall"});
    try std.testing.expect(!dry.command.uninstall.yes);
    const destructive = try parseSlice(&.{ "uninstall", "--yes" });
    try std.testing.expect(destructive.command.uninstall.yes);
    try std.testing.expectError(error.InvalidArguments, parseSlice(&.{ "uninstall", "--nope" }));

    // Update only offers --check today.
    const update = try parseSlice(&.{"update"});
    try std.testing.expect(!update.command.update.check_only);
    const check = try parseSlice(&.{ "update", "--check" });
    try std.testing.expect(check.command.update.check_only);
    try std.testing.expectError(error.InvalidArguments, parseSlice(&.{ "update", "--download" }));

    try std.testing.expectError(error.InvalidArguments, parseSlice(&.{ "doctor", "extra" }));
    try std.testing.expectError(error.InvalidArguments, parseSlice(&.{ "install", "extra" }));
}
