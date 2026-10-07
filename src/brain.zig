const std = @import("std");

const Context = @import("core/context.zig").Context;
const Provider = @import("provider.zig").Provider;
const ToolRegistry = @import("tools/registry.zig").ToolRegistry;
const task = @import("core/task.zig");

pub const ChatProvider = struct {
    context: *anyopaque,
    chatFn: *const fn (*anyopaque, *const Context) anyerror![]u8,

    pub fn fromProvider(provider: *Provider) ChatProvider {
        return .{ .context = provider, .chatFn = providerChat };
    }

    pub fn chat(self: ChatProvider, context: *const Context) ![]u8 {
        return self.chatFn(self.context, context);
    }

    fn providerChat(context: *anyopaque, messages: *const Context) ![]u8 {
        const provider: *Provider = @ptrCast(@alignCast(context));
        return provider.chat(messages);
    }
};

pub const Brain = struct {
    allocator: std.mem.Allocator,
    provider: ChatProvider,
    tools: *const ToolRegistry,
    max_tool_calls: usize = 48,
    /// Bounded budget for malformed `<tool_call>` repair attempts per
    /// `respond`. After it is exhausted the respond fails honestly with
    /// `error.MalformedToolCall` instead of looping with the provider.
    max_tool_repairs: usize = 2,
    /// Optional clock; tool call durations are recorded as 0 when absent.
    io: ?std.Io = null,

    pub fn init(allocator: std.mem.Allocator, provider: ChatProvider, tools: *const ToolRegistry) Brain {
        return .{ .allocator = allocator, .provider = provider, .tools = tools };
    }

    pub fn respond(self: *Brain, context: *Context) ![]u8 {
        return self.respondChecked(context, null);
    }

    /// Same as `respond`, but consults the task `recorder` around tool calls:
    /// a call that already completed for this task (from an earlier failed
    /// attempt or a resumed run) is not executed again — the provider receives
    /// a bounded replay marker instead — and resolved calls are reported to
    /// the recorder. This keeps bounded provider retries from repeating
    /// completed side effects.
    pub fn respondChecked(self: *Brain, context: *Context, recorder: ?task.Recorder) ![]u8 {
        try self.addToolInstructions(context);
        var tool_calls: usize = 0;
        var repairs: usize = 0;
        while (true) {
            const response = try self.provider.chat(context);
            const scan = classifyToolCall(response);

            // A response that looks like a tool call is normalized once, up
            // front. `null` means the payload cannot be repaired: the call is
            // then fed back to the provider through the bounded repair loop
            // below instead of being executed or crashing the respond.
            const identity: ?ToolIdentity = switch (scan) {
                .none => null,
                .malformed => null,
                .call => self.parseToolIdentity(scan.call) catch |err| switch (err) {
                    error.MalformedToolCall => null,
                    else => {
                        self.allocator.free(response);
                        return err;
                    },
                },
            };

            if (scan != .none and identity == null) {
                // Bounded repair: the response attempted a tool call but was
                // malformed (prose is repaired earlier, so this is a payload
                // or wrapper problem). The invalid response stays in history,
                // a fixed protocol correction is appended, and the provider
                // may try again. Nothing was executed; once the repair budget
                // is spent the respond fails with error.MalformedToolCall.
                context.addAssistant(response) catch |err| {
                    self.allocator.free(response);
                    return err;
                };
                self.allocator.free(response);
                if (repairs >= self.max_tool_repairs) return error.MalformedToolCall;
                repairs += 1;
                context.addUser(tool_call_repair_message) catch |err| return err;
                continue;
            }
            if (scan == .none) return response;

            if (tool_calls >= self.max_tool_calls) {
                self.allocator.free(response);
                if (identity) |id| self.allocator.free(id.name);
                return error.ToolCallLimitExceeded;
            }

            const id = identity.?;
            // Freed at the end of this iteration and on every early return
            // below (defer scope is the loop body).
            defer self.allocator.free(id.name);

            if (recorder) |r| {
                if (r.sawCall(id.name, id.input_hash)) {
                    const marker = try self.allocator.dupe(u8, task.call_replay_marker);
                    context.addAssistant(response) catch |err| {
                        self.allocator.free(marker);
                        self.allocator.free(response);
                        return err;
                    };
                    self.allocator.free(response);
                    context.addUser(marker) catch |err| {
                        self.allocator.free(marker);
                        return err;
                    };
                    self.allocator.free(marker);
                    tool_calls += 1;
                    continue;
                }
            }

            const started = task.monotonicNow(self.io);
            const outcome = self.executeToolCall(scan.call) catch |err| {
                self.allocator.free(response);
                return err;
            };
            defer self.allocator.free(outcome.result);
            if (recorder) |r| r.noteCall(
                id.name,
                id.input_hash,
                if (outcome.ok) task.StepState.completed else task.StepState.failed,
                task.elapsedMs(self.io, started),
            );

            context.addAssistant(response) catch |err| {
                self.allocator.free(response);
                return err;
            };
            self.allocator.free(response);
            context.addUser(outcome.result) catch |err| {
                return err;
            };
            tool_calls += 1;
        }
    }

    pub fn executeTool(self: *const Brain, name: []const u8, input: []const u8) ![]u8 {
        return self.tools.execute(self.allocator, name, input);
    }

    fn addToolInstructions(self: *const Brain, context: *Context) !void {
        var instructions = std.Io.Writer.Allocating.init(self.allocator);
        defer instructions.deinit();
        try instructions.writer.writeAll(
            "Tools are optional. To call one, respond with only " ++
                "<tool_call>{\"name\":\"tool-name\",\"input\":\"tool-input\"}</tool_call>. " ++
                "Sandbox tools take a JSON object as input. Never claim to have read a " ++
                "file, executed a command, or inspected media unless the tool actually " ++
                "returned a result; if a tool fails or reports unsupported, say so and " ++
                "report the real outcome. Inspect first, act second, verify last.\n" ++
                "Available tools:\n",
        );
        // Disabled tools are not offered: the model must never believe an
        // unavailable capability exists.
        var offered: usize = 0;
        for (self.tools.tools.items) |tool| {
            if (!tool.enabled) continue;
            try instructions.writer.print("- {s}: {s}\n", .{ tool.name, tool.description });
            offered += 1;
        }
        if (offered == 0) {
            try instructions.writer.writeAll("- none\n");
        }
        try context.addSystem(instructions.written());
    }

    const ToolIdentity = struct {
        name: []u8,
        input_hash: u64,
    };

    /// Parse a tool call's identity (name + input hash) without executing it,
    /// so the recorder can be consulted before side effects happen.
    fn parseToolIdentity(self: *const Brain, json: []const u8) !ToolIdentity {
        var call = try parseToolCall(self.allocator, json);
        defer call.deinit(self.allocator);
        return .{
            .name = try self.allocator.dupe(u8, call.name),
            .input_hash = task.callInputHash(call.input),
        };
    }

    const ToolOutcome = struct {
        /// False when the tool itself reported an error; the protocol message
        /// carries it back to the provider (pre-M2 behavior).
        ok: bool,
        result: []u8,
    };

    fn executeToolCall(self: *const Brain, json: []const u8) !ToolOutcome {
        var call = try parseToolCall(self.allocator, json);
        defer call.deinit(self.allocator);
        const result = self.executeTool(call.name, call.input) catch |err| {
            return .{ .ok = false, .result = try formatProtocol(self.allocator, call.name, "error", @errorName(err)) };
        };
        defer self.allocator.free(result);
        return .{ .ok = true, .result = try formatProtocol(self.allocator, call.name, "result", result) };
    }
};

/// Upper bound for a tool name; longer names are refused instead of being
/// duplicated and hashed unbounded.
pub const max_tool_name_len: usize = 256;

/// Fixed protocol-correction message used by the bounded malformed-call
/// repair loop. Static text only: the invalid response is already in the
/// conversation history, and echoing arbitrary payload here could amplify
/// injected instructions.
pub const tool_call_repair_message =
    "System protocol notice: the previous assistant response was not a valid tool call, so nothing was executed. " ++
    "To call a tool, respond with only <tool_call>{\"name\":\"tool-name\",\"input\":\"tool-input\"}</tool_call> " ++
    "and no text before or after the wrapper. The input must be a JSON string; for sandbox tools pass a " ++
    "JSON object encoded as a string, for example " ++
    "<tool_call>{\"name\":\"filesystem\",\"input\":\"{\\\"op\\\":\\\"list\\\",\\\"path\\\":\\\".\\\"}\"}</tool_call>. " ++
    "If you do not need a tool, reply with plain text only.";

/// A normalized tool call. Both fields are owned by the caller.
const ParsedToolCall = struct {
    name: []u8,
    input: []u8,

    fn deinit(self: *const ParsedToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.input);
    }
};

/// Parse and normalize a tool call payload. Deterministic and bounded:
///
/// - the payload must be structurally valid JSON (an object);
/// - `name` must be a non-empty string of at most `max_tool_name_len` bytes;
/// - `input` may be a JSON string (used verbatim), a JSON object or array
///   (re-serialized to its canonical compact JSON text, because sandbox tools
///   take a JSON object as input and models routinely send it unescaped),
///   `null` or absent (empty input);
/// - any other JSON type for `input` (numbers, booleans, ...) is refused:
///   values are never silently coerced into tool input;
/// - unknown fields are ignored instead of failing the whole call.
///
/// Anything outside these rules is error.MalformedToolCall; repairs never
/// invent structure beyond what is listed above.
fn parseToolCall(allocator: std.mem.Allocator, json: []const u8) !ParsedToolCall {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch
        return error.MalformedToolCall;
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedToolCall;

    const name_value = parsed.value.object.get("name") orelse return error.MalformedToolCall;
    if (name_value != .string) return error.MalformedToolCall;
    if (name_value.string.len == 0 or name_value.string.len > max_tool_name_len) return error.MalformedToolCall;
    const name = try allocator.dupe(u8, name_value.string);
    errdefer allocator.free(name);

    const input_value = parsed.value.object.get("input") orelse std.json.Value{ .null = {} };
    const input: []u8 = switch (input_value) {
        .null => try allocator.dupe(u8, ""),
        .string => |s| try allocator.dupe(u8, s),
        .object, .array => std.json.Stringify.valueAlloc(allocator, input_value, .{}) catch return error.OutOfMemory,
        else => return error.MalformedToolCall,
    };
    errdefer allocator.free(input);
    return .{ .name = name, .input = input };
}

/// Structural classification of a provider response. Bounded and
/// deterministic; the payload itself is validated later by `parseToolCall`.
const ToolCallScan = union(enum) {
    /// Not a tool call: plain text the agent should return as-is.
    none,
    /// A tool call payload (JSON between the wrappers), possibly repaired
    /// from benign formatting mistakes.
    call: []const u8,
    /// The response tried to be a tool call but cannot be repaired safely.
    malformed,
};

/// Classify a provider response into none / call / malformed.
///
/// Safe repairs (structural only, never guessed):
/// - prose before or after exactly one complete `<tool_call>...</tool_call>`
///   block is ignored, because the call itself is unambiguous;
/// - a missing closer (truncated response) is repaired by treating the rest
///   of the response as the payload; the parser still validates it.
///
/// Refused on purpose (would be dangerously permissive):
/// - multiple tool call blocks in one response: ambiguous intent, the
///   protocol is one call per response, so this is fed back for a retry;
/// - an empty payload;
/// - a closing wrapper without an opening one.
fn classifyToolCall(response: []const u8) ToolCallScan {
    const open = "<tool_call>";
    const close = "</tool_call>";
    const trimmed = std.mem.trim(u8, response, " \t\r\n");

    const open_pos = std.mem.indexOf(u8, trimmed, open) orelse {
        if (std.mem.indexOf(u8, trimmed, close) != null) return .malformed;
        return .none;
    };
    const body_start = open_pos + open.len;

    if (std.mem.indexOfPos(u8, trimmed, body_start, close)) |close_pos| {
        // A second opener after this complete block means the response
        // contains more than one call: ambiguous, never guessed.
        if (std.mem.indexOfPos(u8, trimmed, close_pos + close.len, open) != null) return .malformed;
        const json = std.mem.trim(u8, trimmed[body_start..close_pos], " \t\r\n");
        if (json.len == 0) return .malformed;
        return .{ .call = json };
    }

    // Missing closer (e.g. a response cut off at the token limit): repair by
    // taking everything up to the end as the payload.
    const json = std.mem.trim(u8, trimmed[body_start..], " \t\r\n");
    if (json.len == 0) return .malformed;
    return .{ .call = json };
}

fn formatProtocol(allocator: std.mem.Allocator, name: []const u8, field: []const u8, value: []const u8) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try output.writer.writeAll("<tool_result>{\"name\":");
    try appendJsonString(&output.writer, name);
    try output.writer.writeAll(",\"");
    try output.writer.writeAll(field);
    try output.writer.writeAll("\":");
    try appendJsonString(&output.writer, value);
    try output.writer.writeAll("}</tool_result>");
    return allocator.dupe(u8, output.written());
}

fn appendJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |char| {
        switch (char) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (char < 0x20)
                try writer.print("\\u{x:0>4}", .{char})
            else
                try writer.writeByte(char),
        }
    }
    try writer.writeByte('"');
}

const FakeProvider = struct {
    allocator: std.mem.Allocator,
    responses: []const []const u8,
    index: usize = 0,
    required_message: ?[]const u8 = null,

    fn interface(self: *FakeProvider) ChatProvider {
        return .{ .context = self, .chatFn = chat };
    }

    fn chat(context: *anyopaque, messages: *const Context) ![]u8 {
        const self: *FakeProvider = @ptrCast(@alignCast(context));
        if (self.required_message) |required| {
            if (self.index > 0) {
                const last = messages.messages.items[messages.messages.items.len - 1];
                if (std.mem.indexOf(u8, last.content, required) == null) return error.MissingToolResult;
            }
        }
        if (self.index >= self.responses.len) return error.NoFakeResponse;
        const response = self.responses[self.index];
        self.index += 1;
        return self.allocator.dupe(u8, response);
    }
};

fn testContext() !Context {
    var context = Context.init(std.testing.allocator);
    errdefer context.deinit();
    try context.addSystem("test");
    try context.addUser("request");
    return context;
}

fn emptyRegistry() ToolRegistry {
    return ToolRegistry.init(std.testing.allocator);
}

const Calculator = @import("tools/calculator.zig").Calculator;
const Filesystem = @import("tools/filesystem.zig").Filesystem;
const SystemTool = @import("tools/system.zig").SystemTool;

test "brain returns final response without a tool call" {
    const responses = [_][]const u8{"final"};
    var fake = FakeProvider{ .allocator = std.testing.allocator, .responses = &responses };
    var registry = emptyRegistry();
    defer registry.deinit();
    var context = try testContext();
    defer context.deinit();
    var brain = Brain.init(std.testing.allocator, fake.interface(), &registry);

    const result = try brain.respond(&context);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("final", result);
}

test "brain completes calculator tool round trip" {
    const responses = [_][]const u8{
        "<tool_call>\n{\"name\":\"calculator\",\"input\":\"123 * 456\"}\n</tool_call>",
        "123 x 456 = 56088.",
    };
    var fake = FakeProvider{
        .allocator = std.testing.allocator,
        .responses = &responses,
        .required_message = "\"result\":\"56088\"",
    };
    var calculator = Calculator{};
    var registry = emptyRegistry();
    defer registry.deinit();
    try registry.register(calculator.tool());
    var context = try testContext();
    defer context.deinit();
    var brain = Brain.init(std.testing.allocator, fake.interface(), &registry);

    const result = try brain.respond(&context);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("123 x 456 = 56088.", result);
    try std.testing.expectEqual(@as(usize, 2), fake.index);
}

test "brain sends unknown tool error back to provider" {
    const responses = [_][]const u8{
        "<tool_call>{\"name\":\"missing\",\"input\":\"x\"}</tool_call>",
        "Tool unavailable.",
    };
    var fake = FakeProvider{
        .allocator = std.testing.allocator,
        .responses = &responses,
        .required_message = "\"error\":\"ToolNotFound\"",
    };
    var registry = emptyRegistry();
    defer registry.deinit();
    var context = try testContext();
    defer context.deinit();
    var brain = Brain.init(std.testing.allocator, fake.interface(), &registry);

    const result = try brain.respond(&context);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Tool unavailable.", result);
}

test "brain sends tool execution error back to provider" {
    const responses = [_][]const u8{
        "<tool_call>{\"name\":\"calculator\",\"input\":\"1 / 0\"}</tool_call>",
        "Cannot divide by zero.",
    };
    var fake = FakeProvider{
        .allocator = std.testing.allocator,
        .responses = &responses,
        .required_message = "\"error\":\"DivisionByZero\"",
    };
    var calculator = Calculator{};
    var registry = emptyRegistry();
    defer registry.deinit();
    try registry.register(calculator.tool());
    var context = try testContext();
    defer context.deinit();
    var brain = Brain.init(std.testing.allocator, fake.interface(), &registry);

    const result = try brain.respond(&context);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Cannot divide by zero.", result);
}

test "brain rejects malformed tool wrapper after the bounded repair budget" {
    // Empty payload cannot be repaired. The repair loop gives the provider
    // `max_tool_repairs` extra chances, then the respond fails honestly.
    const responses = [_][]const u8{
        "<tool_call>{}</tool_call>",
        "<tool_call>{}</tool_call>",
        "<tool_call>{}</tool_call>",
    };
    var fake = FakeProvider{ .allocator = std.testing.allocator, .responses = &responses };
    var registry = emptyRegistry();
    defer registry.deinit();
    var context = try testContext();
    defer context.deinit();
    var brain = Brain.init(std.testing.allocator, fake.interface(), &registry);

    try std.testing.expectError(error.MalformedToolCall, brain.respond(&context));
    try std.testing.expectEqual(responses.len, fake.index);
}

test "brain repairs a tool call wrapped in prose" {
    const responses = [_][]const u8{
        "Sure, checking that now. <tool_call>{\"name\":\"calculator\",\"input\":\"1 + 1\"}</tool_call>",
        "The answer is 2.",
    };
    var fake = FakeProvider{ .allocator = std.testing.allocator, .responses = &responses };
    var calculator = Calculator{};
    var registry = emptyRegistry();
    defer registry.deinit();
    try registry.register(calculator.tool());
    var context = try testContext();
    defer context.deinit();
    var brain = Brain.init(std.testing.allocator, fake.interface(), &registry);

    const result = try brain.respond(&context);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("The answer is 2.", result);
}

test "brain repairs a truncated tool call missing its closer" {
    // A response cut off after a complete payload is repairable: the JSON
    // between the opener and the end of the response parses cleanly.
    const responses = [_][]const u8{
        "<tool_call>{\"name\":\"calculator\",\"input\":\"2 + 2\"}",
        "The answer is 4.",
    };
    var fake = FakeProvider{ .allocator = std.testing.allocator, .responses = &responses };
    var calculator = Calculator{};
    var registry = emptyRegistry();
    defer registry.deinit();
    try registry.register(calculator.tool());
    var context = try testContext();
    defer context.deinit();
    var brain = Brain.init(std.testing.allocator, fake.interface(), &registry);

    const result = try brain.respond(&context);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("The answer is 4.", result);
}

test "brain repairs tool input sent as a JSON object" {
    const EchoTool = struct {
        fn execute(_: *anyopaque, allocator: std.mem.Allocator, input: []const u8) ![]u8 {
            return allocator.dupe(u8, input);
        }
    };
    const responses = [_][]const u8{
        "<tool_call>{\"name\":\"echo\",\"input\":{\"path\":\"notes.txt\"}}</tool_call>",
        "done",
    };
    var fake = FakeProvider{
        .allocator = std.testing.allocator,
        .responses = &responses,
        // The tool result echoes the normalized input; formatProtocol escapes
        // it as JSON string content, so the marker matches the escaped form.
        .required_message = "{\\\"path\\\":\\\"notes.txt\\\"}",
    };
    var marker: u8 = 0;
    var registry = emptyRegistry();
    defer registry.deinit();
    try registry.register(.{
        .name = "echo",
        .description = "echoes input",
        .context = &marker,
        .executeFn = EchoTool.execute,
    });
    var context = try testContext();
    defer context.deinit();
    var brain = Brain.init(std.testing.allocator, fake.interface(), &registry);

    const result = try brain.respond(&context);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("done", result);
}

test "brain rejects malformed tool JSON after the bounded repair budget" {
    const responses = [_][]const u8{
        "<tool_call>{not-json}</tool_call>",
        "<tool_call>{not-json}</tool_call>",
        "<tool_call>{not-json}</tool_call>",
    };
    var fake = FakeProvider{ .allocator = std.testing.allocator, .responses = &responses };
    var registry = emptyRegistry();
    defer registry.deinit();
    var context = try testContext();
    defer context.deinit();
    var brain = Brain.init(std.testing.allocator, fake.interface(), &registry);

    try std.testing.expectError(error.MalformedToolCall, brain.respond(&context));
    try std.testing.expectEqual(responses.len, fake.index);
}

test "brain refuses multiple tool calls in one response and retries bounded" {
    const EchoTool = struct {
        calls: usize = 0,
        fn execute(context: *anyopaque, allocator: std.mem.Allocator, input: []const u8) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            return allocator.dupe(u8, input);
        }
    };
    const double =
        "<tool_call>{\"name\":\"echo\",\"input\":\"a\"}</tool_call> then " ++
        "<tool_call>{\"name\":\"echo\",\"input\":\"b\"}</tool_call>";
    const responses = [_][]const u8{ double, "final text" };
    var fake = FakeProvider{
        .allocator = std.testing.allocator,
        .responses = &responses,
        .required_message = "not a valid tool call",
    };
    var echo = EchoTool{};
    var registry = emptyRegistry();
    defer registry.deinit();
    try registry.register(.{
        .name = "echo",
        .description = "echoes input",
        .context = &echo,
        .executeFn = EchoTool.execute,
    });
    var context = try testContext();
    defer context.deinit();
    var brain = Brain.init(std.testing.allocator, fake.interface(), &registry);

    // The ambiguous response is never executed; the fixed correction message
    // is fed back and the plain-text reply is returned.
    const result = try brain.respond(&context);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("final text", result);
    try std.testing.expectEqual(@as(usize, 0), echo.calls);
}

test "brain repair loop appends a protocol correction to the context" {
    const bad = "<tool_call></tool_call>";
    const responses = [_][]const u8{ bad, "recovered" };
    var fake = FakeProvider{
        .allocator = std.testing.allocator,
        .responses = &responses,
        .required_message = "not a valid tool call",
    };
    var registry = emptyRegistry();
    defer registry.deinit();
    var context = try testContext();
    defer context.deinit();
    var brain = Brain.init(std.testing.allocator, fake.interface(), &registry);

    const result = try brain.respond(&context);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("recovered", result);
    // History keeps the invalid response and the fixed correction, in order.
    const messages = context.messages.items;
    try std.testing.expectEqualStrings(bad, messages[messages.len - 2].content);
    try std.testing.expectEqualStrings(tool_call_repair_message, messages[messages.len - 1].content);
}

test "brain returns plain text mentioning the protocol without a wrapper" {
    const responses = [_][]const u8{"I will not use the tool_call syntax today."};
    var fake = FakeProvider{ .allocator = std.testing.allocator, .responses = &responses };
    var registry = emptyRegistry();
    defer registry.deinit();
    var context = try testContext();
    defer context.deinit();
    var brain = Brain.init(std.testing.allocator, fake.interface(), &registry);

    const result = try brain.respond(&context);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("I will not use the tool_call syntax today.", result);
}

test "brain enforces tool call limit" {
    const call = "<tool_call>{\"name\":\"calculator\",\"input\":\"1 + 1\"}</tool_call>";
    const responses = [_][]const u8{ call, call, call };
    var fake = FakeProvider{ .allocator = std.testing.allocator, .responses = &responses };
    var calculator = Calculator{};
    var registry = emptyRegistry();
    defer registry.deinit();
    try registry.register(calculator.tool());
    var context = try testContext();
    defer context.deinit();
    var brain = Brain.init(std.testing.allocator, fake.interface(), &registry);
    brain.max_tool_calls = 2;

    try std.testing.expectError(error.ToolCallLimitExceeded, brain.respond(&context));
}

test "brain propagates provider error" {
    const BrokenProvider = struct {
        fn chat(_: *anyopaque, _: *const Context) ![]u8 {
            return error.ProviderFailed;
        }
    };
    var marker: u8 = 0;
    const provider = ChatProvider{ .context = &marker, .chatFn = BrokenProvider.chat };
    var registry = emptyRegistry();
    defer registry.deinit();
    var context = try testContext();
    defer context.deinit();
    var brain = Brain.init(std.testing.allocator, provider, &registry);

    try std.testing.expectError(error.ProviderFailed, brain.respond(&context));
}

test "brain completes filesystem tool round trip" {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const test_dir = "zig-cache-pico-brain-test";
    cwd.createDirPath(io, test_dir) catch |err| if (err != error.PathAlreadyExists) return err;
    var dir = try cwd.openDir(io, test_dir, .{});
    defer dir.close(io);
    defer cwd.deleteTree(io, test_dir) catch {};
    try dir.writeFile(io, .{ .sub_path = "note.txt", .data = "brain file" });

    const responses = [_][]const u8{
        "<tool_call>{\"name\":\"filesystem\",\"input\":\"read note.txt\"}</tool_call>",
        "File read.",
    };
    var fake = FakeProvider{
        .allocator = std.testing.allocator,
        .responses = &responses,
        .required_message = "\"result\":\"brain file\"",
    };
    var filesystem = Filesystem.init(io, dir);
    var registry = emptyRegistry();
    defer registry.deinit();
    try registry.register(filesystem.tool());
    var context = try testContext();
    defer context.deinit();
    var brain = Brain.init(std.testing.allocator, fake.interface(), &registry);

    const result = try brain.respond(&context);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("File read.", result);
}

test "brain completes system tool round trip" {
    const responses = [_][]const u8{
        "<tool_call>{\"name\":\"system\",\"input\":\"info\"}</tool_call>",
        "System info returned.",
    };
    var fake = FakeProvider{
        .allocator = std.testing.allocator,
        .responses = &responses,
        .required_message = "pico_claw=0.1.0",
    };
    var system = SystemTool{};
    var registry = emptyRegistry();
    defer registry.deinit();
    try registry.register(system.tool());
    var context = try testContext();
    defer context.deinit();
    var brain = Brain.init(std.testing.allocator, fake.interface(), &registry);

    const result = try brain.respond(&context);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("System info returned.", result);
}

test "brain skips tool calls that already completed for the task" {
    const CountingTool = struct {
        calls: usize = 0,

        fn execute(context: *anyopaque, allocator: std.mem.Allocator, input: []const u8) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            return allocator.dupe(u8, input);
        }
    };

    // The provider emits the same call twice: after the first execution the
    // recorder reports it completed, so the second emission is answered with
    // a replay marker and the tool runs exactly once.
    const call = "<tool_call>{\"name\":\"counter\",\"input\":\"x\"}</tool_call>";
    const responses = [_][]const u8{ call, call, "done" };
    var fake = FakeProvider{ .allocator = std.testing.allocator, .responses = &responses };
    var counter = CountingTool{};
    var registry = emptyRegistry();
    defer registry.deinit();
    try registry.register(.{
        .name = "counter",
        .description = "counts executions",
        .context = &counter,
        .executeFn = CountingTool.execute,
    });

    var record = task.TaskRecord.begin(std.testing.allocator, 1, 0);
    defer record.deinit();
    try record.start();

    var context = try testContext();
    defer context.deinit();
    var brain = Brain.init(std.testing.allocator, fake.interface(), &registry);

    const result = try brain.respondChecked(&context, record.recorder());
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("done", result);
    try std.testing.expectEqual(@as(usize, 1), counter.calls);
    try std.testing.expectEqual(@as(usize, 1), record.toolCallCount());
    try std.testing.expect(record.wasCallCompleted("counter", task.callInputHash("x")));
    try std.testing.expectEqual(task.StepState.completed, record.calls.items[0].state);
}

test "brain records failed tool calls as not resumable" {
    const FailingTool = struct {
        fn execute(_: *anyopaque, _: std.mem.Allocator, _: []const u8) ![]u8 {
            return error.ToolFailure;
        }
    };

    const call = "<tool_call>{\"name\":\"broken\",\"input\":\"x\"}</tool_call>";
    const responses = [_][]const u8{ call, "after error" };
    var fake = FakeProvider{ .allocator = std.testing.allocator, .responses = &responses };
    var marker: u8 = 0;
    var registry = emptyRegistry();
    defer registry.deinit();
    try registry.register(.{
        .name = "broken",
        .description = "always fails",
        .context = &marker,
        .executeFn = FailingTool.execute,
    });

    var record = task.TaskRecord.begin(std.testing.allocator, 1, 0);
    defer record.deinit();
    try record.start();

    var context = try testContext();
    defer context.deinit();
    var brain = Brain.init(std.testing.allocator, fake.interface(), &registry);

    const result = try brain.respondChecked(&context, record.recorder());
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("after error", result);
    try std.testing.expectEqual(@as(usize, 1), record.toolCallCount());
    try std.testing.expectEqual(task.StepState.failed, record.calls.items[0].state);
    try std.testing.expect(!record.wasCallCompleted("broken", task.callInputHash("x")));
}
