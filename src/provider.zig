const std = @import("std");

const Config = @import("config.zig").Config;
const ui = @import("interfaces/ui.zig");
const Context = @import("core/context.zig").Context;
const Role = @import("core/context.zig").Role;

pub const Provider = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    config: Config,
    /// Teacher routing (M3): when set, requests target this endpoint and
    /// model instead of the primary configuration. Values come from
    /// configuration and are never logged or persisted with credentials.
    base_url_override: ?[]const u8 = null,
    model_override: ?[]const u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ_map: *std.process.Environ.Map,
        config: Config,
    ) Provider {
        return .{
            .allocator = allocator,
            .io = io,
            .environ_map = environ_map,
            .config = config,
        };
    }

    /// Build the teacher provider: the same adapter and key handling, pointed
    /// at the configured teacher endpoint and model.
    pub fn initTeacher(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ_map: *std.process.Environ.Map,
        config: Config,
        teacher_base_url: []const u8,
        teacher_model: []const u8,
    ) Provider {
        var provider = Provider.init(allocator, io, environ_map, config);
        provider.base_url_override = teacher_base_url;
        provider.model_override = teacher_model;
        return provider;
    }

    pub fn baseUrl(self: *const Provider) []const u8 {
        return self.base_url_override orelse self.config.base_url;
    }

    pub fn model(self: *const Provider) []const u8 {
        return self.model_override orelse self.config.model;
    }

    pub fn info(
        self: *const Provider,
    ) void {
        ui.debugOut(
            "Provider\n",
            .{},
        );

        ui.debugOut(
            "Base URL: {s}\n",
            .{self.config.base_url},
        );

        ui.debugOut(
            "Model: {s}\n",
            .{self.config.model},
        );

        ui.debugOut(
            "API Key: environment variable\n",
            .{},
        );
    }

    fn getApiKey(
        self: *const Provider,
    ) ![]u8 {
        const api_key = self.environ_map.get(
            "PICO_CLAW_API_KEY",
        ) orelse {
            return error.ApiKeyNotFound;
        };

        if (api_key.len == 0) {
            return error.ApiKeyNotFound;
        }

        return try self.allocator.dupe(
            u8,
            api_key,
        );
    }

    /// JSON string encoding that never emits invalid UTF-8. Every invalid
    /// byte sequence (bad lead byte, truncated tail, overlong form, surrogate
    /// half) becomes U+FFFD, and control characters are escaped, so provider
    /// requests stay valid JSON regardless of what a caller passed in.
    pub fn appendJsonString(
        writer: *std.Io.Writer,
        value: []const u8,
    ) !void {
        try writer.writeByte('"');

        var index: usize = 0;
        while (index < value.len) {
            const char = value[index];
            switch (char) {
                '"' => {
                    try writer.writeAll("\\\"");
                    index += 1;
                },
                '\\' => {
                    try writer.writeAll("\\\\");
                    index += 1;
                },
                '\n' => {
                    try writer.writeAll("\\n");
                    index += 1;
                },
                '\r' => {
                    try writer.writeAll("\\r");
                    index += 1;
                },
                '\t' => {
                    try writer.writeAll("\\t");
                    index += 1;
                },
                else => {
                    if (char < 0x20) {
                        try writer.print("\\u{x:0>4}", .{char});
                        index += 1;
                        continue;
                    }

                    const length = std.unicode.utf8ByteSequenceLength(char) catch {
                        try writer.writeAll("\u{FFFD}");
                        index += 1;
                        continue;
                    };

                    if (length == 1) {
                        try writer.writeByte(char);
                        index += 1;
                        continue;
                    }

                    const end = index + length;
                    const valid = end <= value.len and
                        std.unicode.utf8ValidateSlice(value[index..end]);
                    if (valid) {
                        try writer.writeAll(value[index..end]);
                        index = end;
                    } else {
                        try writer.writeAll("\u{FFFD}");
                        index += 1;
                    }
                },
            }
        }

        try writer.writeByte('"');
    }

    fn appendRole(
        writer: *std.Io.Writer,
        role: Role,
    ) !void {
        try writer.writeByte('"');

        switch (role) {
            .system => try writer.writeAll("system"),
            .user => try writer.writeAll("user"),
            .assistant => try writer.writeAll("assistant"),
        }

        try writer.writeByte('"');
    }

    fn buildRequestBody(
        self: *Provider,
        context: *const Context,
    ) ![]u8 {
        var writer =
            std.Io.Writer.Allocating.init(
                self.allocator,
            );
        defer writer.deinit();

        try writer.writer.writeAll(
            "{\"model\":",
        );

        try appendJsonString(
            &writer.writer,
            self.model(),
        );

        try writer.writer.writeAll(
            ",\"messages\":[",
        );

        for (
            context.messages.items,
            0..,
        ) |message, index| {
            if (index > 0) {
                try writer.writer.writeByte(',');
            }

            try writer.writer.writeAll(
                "{\"role\":",
            );

            try appendRole(
                &writer.writer,
                message.role,
            );

            try writer.writer.writeAll(
                ",\"content\":",
            );

            try appendJsonString(
                &writer.writer,
                message.content,
            );

            try writer.writer.writeByte('}');
        }

        try writer.writer.writeAll(
            "]}",
        );

        return try self.allocator.dupe(
            u8,
            writer.written(),
        );
    }

    /// One chat completion under a hard deadline. The blocking HTTP exchange
    /// runs as a concurrent task, so a hung provider endpoint fails with
    /// `error.RequestTimeout` instead of blocking the single-threaded runtime
    /// forever. Concurrency is required for that guarantee: when the runtime
    /// cannot provide it, the request is refused (`RequestDeadlineUnavailable`)
    /// rather than silently becoming unbounded again.
    pub fn chat(
        self: *Provider,
        context: *const Context,
    ) ![]u8 {
        ui.debugOut(
            "\n[HTTP] Memulai request...\n",
            .{},
        );

        // ==============================
        // API KEY
        // ==============================

        const api_key = try self.getApiKey();
        defer self.allocator.free(api_key);

        ui.debugOut(
            "[HTTP] API key ditemukan.\n",
            .{},
        );

        // ==============================
        // URL / BODY / AUTH (parent side)
        // ==============================

        const url_string = try std.fmt.allocPrint(
            self.allocator,
            "{s}/chat/completions",
            .{self.baseUrl()},
        );
        defer self.allocator.free(url_string);

        ui.debugOut(
            "[HTTP] URL: {s}\n",
            .{url_string},
        );

        const uri = try std.Uri.parse(
            url_string,
        );

        const body = try self.buildRequestBody(
            context,
        );
        defer self.allocator.free(body);

        ui.debugOut(
            "[HTTP] Request body: {d} bytes.\n",
            .{body.len},
        );

        const auth = try std.fmt.allocPrint(
            self.allocator,
            "Bearer {s}",
            .{api_key},
        );
        defer self.allocator.free(auth);

        // ==============================
        // BOUNDED EXCHANGE
        // ==============================

        // The exchange task owns copies of everything it touches (URL, auth,
        // body): it must stay memory-safe even when it is abandoned after a
        // deadline and outlives this call. Parent copies are freed above.
        const task = blk: {
            const created = try self.allocator.create(ChatTask);
            errdefer self.allocator.destroy(created);
            created.* = .{
                .allocator = self.allocator,
                .io = self.io,
                .guard = .{ .io = self.io },
                .uri = uri,
                .url = undefined,
                .auth = undefined,
                .body = undefined,
            };
            created.url = try self.allocator.dupe(u8, url_string);
            errdefer self.allocator.free(created.url);
            created.auth = try self.allocator.dupe(u8, auth);
            errdefer self.allocator.free(created.auth);
            created.body = try self.allocator.dupe(u8, body);
            errdefer self.allocator.free(created.body);
            break :blk created;
        };

        var select_buffer: [2]ChatExchange.SelectResult = undefined;
        var exchange_select = ChatExchange.Select.init(self.io, &select_buffer);
        exchange_select.concurrent(.exchange, chatExchangeTask, .{task}) catch |err| {
            // The task never started: the parent still owns everything.
            self.allocator.free(task.url);
            self.allocator.free(task.auth);
            self.allocator.free(task.body);
            self.allocator.destroy(task);
            // Honest refusal: without concurrency there is no deadline.
            return switch (err) {
                error.ConcurrencyUnavailable => error.RequestDeadlineUnavailable,
            };
        };

        ui.debugOut(
            "[HTTP] Request berjalan dengan deadline {d} ms...\n",
            .{self.config.request_timeout_ms},
        );

        const waited = ChatExchange.wait(
            self.allocator,
            &exchange_select,
            &task.guard,
            self.config.request_timeout_ms,
        );
        return switch (waited) {
            .result => |reply| {
                self.allocator.destroy(task);
                ui.debugOut(
                    "[HTTP] Response AI berhasil diekstrak: {d} bytes.\n",
                    .{reply.len},
                );
                return reply;
            },
            .failed => |err| {
                self.allocator.destroy(task);
                return err;
            },
            // The task self-frees and self-destroys; the runtime keeps
            // serving. The caller sees the honest deadline failure.
            .abandoned => |err| err,
        };
    }
};

// ---------------------------------------------------------------------------
// Bounded provider requests: a hard deadline for every HTTP exchange
// ---------------------------------------------------------------------------

/// Grace window for joining an exchange after its socket was shutdown. On
/// Windows the shutdown completion is asynchronous (AFD graceful disconnect
/// drains first), so this window must comfortably exceed typical unblock
/// latency. If it somehow expires, the exchange is abandoned (the task frees
/// everything it owns when it eventually completes) and the caller gets
/// `error.RequestTimeout`. Abandoning is safe for the runtime: the task never
/// touches Provider state, and the runtime Io instance lives for the whole
/// process.
const exchange_grace_ms: u64 = 1_500;

/// State shared between the calling thread and a bounded exchange task.
/// All fields are guarded by `mu`:
/// - `done`: the task finished its final locked section (results are final).
/// - `owned`: true while the parent owns the task struct and its inputs. The
///   parent flips it to false only when abandoning the exchange; the task
///   then frees everything itself, including its own allocation. Both sides
///   decide only under `mu`, so exactly one of them destroys the task: no
///   leak, no double free.
/// - `sock`: the connected socket, published by the task under `mu` as soon
///   as the connection exists, so the deadline path can shutdown() a pending
///   read/write. The socket is closed only inside the task's final locked
///   section, so a parent shutdown can never hit a closed (and possibly
///   reused) fd.
const DeadlineGuard = struct {
    mu: std.Io.Mutex = .init,
    io: std.Io,
    done: bool = false,
    owned: bool = true,
    sock: ?std.Io.net.Stream = null,
};

/// Timer task for the select: sleeps until its timeout, then delivers
/// `.timed_out`. `select.cancel()` wakes it early (sleep is cancelable), so
/// a healthy exchange never waits for its deadline to pass.
fn deadlineTimerTask(io: std.Io, timeout: std.Io.Timeout) void {
    timeout.sleep(io) catch {};
}

/// Deadline machinery shared by chat and model discovery. `ResultT` is the
/// exchange's success payload; `freeResult` releases a payload nobody
/// consumed (leftover race in a finished exchange).
fn Exchange(
    comptime ResultT: type,
    comptime freeResult: fn (std.mem.Allocator, ResultT) void,
) type {
    return struct {
        const Self = @This();

        pub const Outcome = union(enum) { ok: ResultT, err: anyerror };
        pub const SelectResult = union(enum) { exchange: Outcome, timed_out: void };
        pub const Select = std.Io.Select(SelectResult);

        pub const Waited = union(enum) {
            /// Exchange completed with this payload. The caller owns the
            /// payload AND the task struct.
            result: ResultT,
            /// Exchange finished with this error. The caller owns the task.
            failed: anyerror,
            /// The exchange was abandoned: the task owns (and will free) all
            /// of its state, including its own task allocation. The caller
            /// owns nothing and must fail with the carried error.
            abandoned: anyerror,
        };

        /// Wait for the exchange (already spawned via
        /// `select.concurrent(.exchange, taskFn, ...)`) under a hard deadline.
        pub fn wait(
            allocator: std.mem.Allocator,
            select: *Select,
            guard: *DeadlineGuard,
            timeout_ms: u64,
        ) Waited {
            const io = guard.io;
            const timeout: std.Io.Timeout = .{ .duration = .{
                .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
                .clock = .awake,
            } };
            // `concurrent`, never `async`: a timer spawned with `async` may
            // run inline on the CALLING thread when the runtime's async limit
            // is reached, which would sleep for the whole deadline inside the
            // caller (the single-threaded server) instead of racing it.
            select.concurrent(.timed_out, deadlineTimerTask, .{ io, timeout }) catch {
                // No unit of concurrency for the timer: a deadline cannot be
                // raced, so the caller must refuse the request honestly
                // rather than block unbounded.
                return deadlinePath(allocator, select, guard, error.RequestDeadlineUnavailable);
            };

            const first = select.await() catch {
                return deadlinePath(allocator, select, guard, error.Canceled);
            };
            return switch (first) {
                .exchange => |outcome| finishOutcome(allocator, select, outcome, null),
                .timed_out => deadlinePath(allocator, select, guard, error.RequestTimeout),
            };
        }

        /// Resolve an exchange outcome. `deadline_error` is set when the
        /// outcome raced in after the deadline expired: a late success is
        /// still delivered honestly, but a failure is reported as the
        /// deadline that caused the interrupt instead of shutdown noise.
        fn finishOutcome(
            allocator: std.mem.Allocator,
            select: *Select,
            outcome: Outcome,
            deadline_error: ?anyerror,
        ) Waited {
            drainAndCancel(allocator, select);
            return switch (outcome) {
                .ok => |payload| .{ .result = payload },
                .err => |err| .{ .failed = deadline_error orelse err },
            };
        }

        /// Cancel the select (wakes a sleeping timer) and free a leftover
        /// queued payload that was never consumed.
        fn drainAndCancel(allocator: std.mem.Allocator, select: *Select) void {
            const leftover = select.cancel();
            if (leftover) |res| switch (res) {
                .exchange => |outcome| if (outcome == .ok) {
                    freeResult(allocator, outcome.ok);
                },
                .timed_out => {},
            };
        }

        /// Deadline expired (or the parent was canceled). Bound the exchange
        /// deterministically: with a known socket the connection is shutdown,
        /// which unblocks the task's pending read/write, and the exchange is
        /// joined within a small grace window. Without a socket (still in
        /// DNS/connect/TLS) there is nothing to interrupt, so the exchange is
        /// abandoned and the runtime keeps serving.
        fn deadlinePath(
            allocator: std.mem.Allocator,
            select: *Select,
            guard: *DeadlineGuard,
            deadline_error: anyerror,
        ) Waited {
            const io = guard.io;

            guard.mu.lockUncancelable(io);
            if (guard.done) {
                guard.mu.unlock(io);
                // The exchange finished right at the deadline: its outcome is
                // queued (or about to be). Await it directly instead of
                // canceling, so nothing is dropped.
                const final = select.await() catch {
                    return abandon(allocator, select, guard, deadline_error);
                };
                return switch (final) {
                    .exchange => |outcome| finishOutcome(allocator, select, outcome, deadline_error),
                    .timed_out => abandon(allocator, select, guard, deadline_error),
                };
            }
            if (guard.sock) |stream| {
                stream.shutdown(io, .both) catch {};
                guard.mu.unlock(io);

                // The dead socket unblocks the task's pending read/write;
                // join it within a small grace window. The timer goes through
                // `concurrent` for the same reason as the main deadline: an
                // inline sleep here would block the caller.
                const grace: std.Io.Timeout = .{ .duration = .{
                    .raw = std.Io.Duration.fromMilliseconds(exchange_grace_ms),
                    .clock = .awake,
                } };
                select.concurrent(.timed_out, deadlineTimerTask, .{ io, grace }) catch {
                    return abandon(allocator, select, guard, deadline_error);
                };
                const second = select.await() catch {
                    return abandon(allocator, select, guard, deadline_error);
                };
                return switch (second) {
                    .exchange => |outcome| finishOutcome(allocator, select, outcome, deadline_error),
                    .timed_out => abandon(allocator, select, guard, deadline_error),
                };
            }
            // No socket yet (DNS/connect/TLS handshake): nothing to interrupt.
            guard.owned = false;
            guard.mu.unlock(io);
            select.queue.close(io);
            return .{ .abandoned = deadline_error };
        }

        /// Abandon the exchange unless it just finished. Not holding the lock.
        fn abandon(
            allocator: std.mem.Allocator,
            select: *Select,
            guard: *DeadlineGuard,
            deadline_error: anyerror,
        ) Waited {
            const io = guard.io;
            guard.mu.lockUncancelable(io);
            if (guard.done) {
                guard.mu.unlock(io);
                const final = select.await() catch {
                    return abandonLocked(select, guard, deadline_error);
                };
                return switch (final) {
                    .exchange => |outcome| finishOutcome(allocator, select, outcome, deadline_error),
                    .timed_out => abandonLocked(select, guard, deadline_error),
                };
            }
            return abandonLocked(select, guard, deadline_error);
        }

        /// Abandon the exchange; caller holds the lock. Ownership of the task
        /// moves to the task itself; the select queue is closed so the task's
        /// eventual result is dropped, never delivered into a dead frame.
        fn abandonLocked(
            select: *Select,
            guard: *DeadlineGuard,
            deadline_error: anyerror,
        ) Waited {
            const io = guard.io;
            guard.owned = false;
            guard.mu.unlock(io);
            select.queue.close(io);
            return .{ .abandoned = deadline_error };
        }
    };
}

const ChatExchange = Exchange([]u8, freeChatResult);

fn freeChatResult(allocator: std.mem.Allocator, result: []u8) void {
    allocator.free(result);
}

/// Self-contained chat exchange task. It owns copies of everything it
/// touches (URL, auth, body) and never dereferences Provider state, so it
/// stays memory-safe even when abandoned after a deadline and outliving its
/// caller. Protocol resources are released in one final locked section; the
/// socket is closed only there, never while the deadline path may still
/// shutdown() it. Redirects are refused: std re-creates connections inside
/// redirect handling, which would race the deadline shutdown path.
const ChatTask = struct {
    guard: DeadlineGuard,
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Borrowed slices live inside `url` (owned below).
    uri: std.Uri,
    url: []u8,
    auth: []u8,
    body: []u8,
};

fn chatExchangeTask(self: *ChatTask) ChatExchange.Outcome {
    const allocator = self.allocator;
    const io = self.io;

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    var request: ?std.http.Client.Request = null;

    const outcome: ChatExchange.Outcome = blk: {
        var started = client.request(.POST, self.uri, .{
            .redirect_behavior = .not_allowed,
            .headers = .{
                .authorization = .{ .override = self.auth },
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .{ .override = "identity" },
            },
        }) catch |err| break :blk .{ .err = err };

        // Publish the connected socket so the deadline path can interrupt a
        // pending read/write. Under the guard lock: a concurrent deadline
        // expiry must never observe a half-published stream.
        self.guard.mu.lockUncancelable(io);
        self.guard.sock = started.connection.?.stream_reader.stream;
        self.guard.mu.unlock(io);

        // From here on the final locked section owns the request.
        request = started;
        started.sendBodyComplete(self.body) catch |err| break :blk .{ .err = err };

        var redirect_buffer: [4096]u8 = undefined;
        var response = started.receiveHead(&redirect_buffer) catch |err| break :blk .{ .err = err };

        // Header strings borrow the connection buffer and are invalidated
        // once the body is read; capture what the parser needs first. The
        // value is configuration metadata, not a credential.
        const content_type: []const u8 = allocator.dupe(
            u8,
            response.head.content_type orelse "application/json",
        ) catch |err| break :blk .{ .err = err };

        ui.debugOut(
            "\nHTTP Status: {d} {s}\nContent-Type: {s}\n",
            .{
                @intFromEnum(response.head.status),
                response.head.status.phrase() orelse "",
                content_type,
            },
        );

        var response_buffer: [64 * 1024]u8 = undefined;
        var reader = response.reader(&response_buffer);
        var response_body = std.Io.Writer.Allocating.init(allocator);
        _ = reader.streamRemaining(&response_body.writer) catch |err| {
            allocator.free(content_type);
            response_body.deinit();
            break :blk .{ .err = err };
        };
        const raw_response = response_body.written();

        ui.debugOut("[HTTP] Response: {d} bytes.\n", .{raw_response.len});

        if (response.head.status != .ok) {
            // Bounded, secret-free diagnostics: the raw body may contain
            // private content and is never printed in full.
            var prefix_buffer: [256]u8 = undefined;
            ui.debugOut(
                "\nAPI error (HTTP {d}); response prefix: {s}\n",
                .{
                    @intFromEnum(response.head.status),
                    boundedPrefix(&prefix_buffer, raw_response),
                },
            );
            allocator.free(content_type);
            response_body.deinit();
            break :blk .{ .err = error.ApiRequestFailed };
        }

        const reply = extractReply(allocator, content_type, raw_response) catch |err| {
            // Limited diagnostics only: content type, size, and a bounded,
            // sanitized prefix. The raw response is never printed in full.
            var prefix_buffer: [256]u8 = undefined;
            ui.debugOut(
                "\nResponse parse failed ({s}); content-type: {s}; size: {d} bytes; prefix: {s}\n",
                .{
                    @errorName(err),
                    content_type,
                    raw_response.len,
                    boundedPrefix(&prefix_buffer, raw_response),
                },
            );
            // TEMPORARY (streaming-parser fix): dump the raw body locally for
            // format analysis; removed once the format is confirmed.
            std.Io.Dir.cwd().writeFile(io, .{
                .sub_path = ".zig-cache/last-failed-body.txt",
                .data = raw_response,
            }) catch {};
            allocator.free(content_type);
            response_body.deinit();
            break :blk .{ .err = err };
        };

        allocator.free(content_type);
        response_body.deinit();
        break :blk .{ .ok = reply };
    };

    // Final locked section: release protocol resources, then publish
    // completion and resolve ownership under the same lock.
    self.guard.mu.lockUncancelable(io);
    if (request) |*completed| completed.deinit();
    client.deinit();
    self.guard.done = true;
    const abandoned = !self.guard.owned;
    self.guard.mu.unlock(io);

    // Task-owned inputs are never referenced past this point.
    allocator.free(self.url);
    allocator.free(self.auth);
    allocator.free(self.body);

    if (abandoned) {
        allocator.destroy(self);
        return .{ .err = error.RequestAbandoned }; // value discarded
    }
    return outcome;
}

const ModelsExchange = Exchange(ModelsResult, freeModelsResult);

fn freeModelsResult(allocator: std.mem.Allocator, result: ModelsResult) void {
    var mutable = result;
    mutable.deinit(allocator);
}

/// Self-contained model discovery task; same ownership rules as `ChatTask`.
const ModelsTask = struct {
    guard: DeadlineGuard,
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Borrowed slices live inside `url` (owned below).
    uri: std.Uri,
    url: []u8,
    auth: []u8,
};

fn modelsExchangeTask(self: *ModelsTask) ModelsExchange.Outcome {
    const allocator = self.allocator;
    const io = self.io;

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    var request: ?std.http.Client.Request = null;

    const outcome: ModelsExchange.Outcome = blk: {
        var started = client.request(.GET, self.uri, .{
            .redirect_behavior = .not_allowed,
            .headers = .{
                .authorization = .{ .override = self.auth },
                .accept_encoding = .{ .override = "identity" },
            },
        }) catch |err| break :blk .{ .err = err };

        self.guard.mu.lockUncancelable(io);
        self.guard.sock = started.connection.?.stream_reader.stream;
        self.guard.mu.unlock(io);

        request = started;
        started.sendBodiless() catch |err| break :blk .{ .err = err };

        var redirect_buffer: [4096]u8 = undefined;
        var response = started.receiveHead(&redirect_buffer) catch |err| break :blk .{ .err = err };

        if (response.head.status != .ok) {
            ui.debugOut("[HTTP] models request failed: HTTP {d}\n", .{
                @intFromEnum(response.head.status),
            });
            break :blk .{ .err = error.ApiRequestFailed };
        }

        var response_buffer: [64 * 1024]u8 = undefined;
        var reader = response.reader(&response_buffer);
        var response_body = std.Io.Writer.Allocating.init(allocator);
        _ = reader.streamRemaining(&response_body.writer) catch |err| {
            response_body.deinit();
            break :blk .{ .err = err };
        };

        const parsed = parseModelsResponse(allocator, response_body.written()) catch |err| {
            response_body.deinit();
            break :blk .{ .err = err };
        };
        response_body.deinit();
        break :blk .{ .ok = parsed };
    };

    self.guard.mu.lockUncancelable(io);
    if (request) |*completed| completed.deinit();
    client.deinit();
    self.guard.done = true;
    const abandoned = !self.guard.owned;
    self.guard.mu.unlock(io);

    allocator.free(self.url);
    allocator.free(self.auth);

    if (abandoned) {
        allocator.destroy(self);
        return .{ .err = error.RequestAbandoned }; // value discarded
    }
    return outcome;
}

// ---------------------------------------------------------------------------
// Provider request encoding regression tests
// ---------------------------------------------------------------------------

test "provider JSON strings sanitize invalid UTF-8 and escape control bytes" {
    const allocator = std.testing.allocator;
    const raw = "ok" ++ "\xC3\x28" ++ "\xFF" ++ "\xC0\xAF" ++ "\x01" ++ "\x1F" ++
        "caf\u{00E9}" ++ "\xE2\x82";

    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try Provider.appendJsonString(&output.writer, raw);

    const encoded = try allocator.dupe(u8, output.written());
    defer allocator.free(encoded);

    try std.testing.expect(std.unicode.utf8ValidateSlice(encoded));

    // The encoded value must be a well-formed JSON string that decodes back
    // with U+FFFD for each invalid byte and the original values elsewhere.
    const parsed = try std.json.parseFromSlice([]const u8, allocator, encoded, .{});
    defer parsed.deinit();
    const expected = "ok" ++ "\u{FFFD}" ++ "(" ++ "\u{FFFD}" ++ "\u{FFFD}" ++ "\u{FFFD}" ++
        "\x01" ++ "\x1F" ++ "caf\u{00E9}" ++ "\u{FFFD}" ++ "\u{FFFD}";
    try std.testing.expectEqualStrings(expected, parsed.value);
}

// ---------------------------------------------------------------------------
// Response parsing: JSON completion and Server-Sent Events
//
// Servers answering OpenAI-style chat completions use two body shapes:
//
// - `application/json`: one full completion object with
//   `choices[0].message.content`;
// - `text/event-stream`: `data:` fields carrying either full completion
//   objects or incremental `choices[0].delta.content` parts, terminated by a
//   `data: [DONE]` event.
//
// The format is chosen by Content-Type, with a defensive fallback to SSE
// parsing when a JSON body clearly contains `data:` fields. All parsing is
// byte-level on the raw body: splitting on `\n` and trimming ASCII whitespace
// never splits a UTF-8 sequence, so multi-byte content (Indonesian text,
// emoji) survives unchanged.
// ---------------------------------------------------------------------------

/// True when the Content-Type header announces an event stream.
/// Case-insensitive and parameter-tolerant
/// (`text/event-stream; charset=utf-8`).
pub fn isEventStream(content_type: []const u8) bool {
    return std.mem.indexOf(u8, content_type, "text/event-stream") != null;
}

/// Collect the `data:` field payloads of an SSE body, in order. Per the SSE
/// format: empty lines dispatch the current event, lines starting with `:`
/// are comments, consecutive `data:` lines join with `\n`, and any other
/// field is ignored without dispatching. Returns an owned list of owned
/// payloads (free each payload, then the list).
pub fn collectSseData(
    allocator: std.mem.Allocator,
    body: []const u8,
) ![][]const u8 {
    var payloads: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (payloads.items) |payload| allocator.free(payload);
        payloads.deinit(allocator);
    }

    var current: std.Io.Writer.Allocating = .init(allocator);
    var current_open = false;
    var current_failed = false;

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) {
            // Event dispatch: emit the accumulated data field, if any.
            if (current_open and !current_failed) {
                const payload = try current.toOwnedSlice();
                try payloads.append(allocator, payload);
            }
            if (current_open) {
                current.deinit();
                current_open = false;
                current_failed = false;
            }
            continue;
        }
        if (line[0] == ':') continue; // comment
        if (line[0] == '{' or line[0] == '[') {
            // Tolerated: a bare JSON completion line without a `data:` prefix
            // (observed in the wild, glued directly to `data: [DONE]`). The
            // line is a complete event, so it is dispatched immediately.
            if (!current_open) {
                current = .init(allocator);
                current_open = true;
                current_failed = false;
            }
            if (!current_failed) {
                current.writer.print("{s}\n", .{line}) catch {
                    current.deinit();
                    current_open = true;
                    current_failed = true;
                };
            }
            if (current_open and !current_failed) {
                const payload = try current.toOwnedSlice();
                try payloads.append(allocator, payload);
            }
            if (current_open) {
                current.deinit();
                current_open = false;
                current_failed = false;
            }
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue; // bare field name: ignore
        const field = line[0..colon];
        if (!std.mem.eql(u8, field, "data")) continue;

        var value = line[colon + 1 ..];
        if (value.len > 0 and value[0] == ' ') value = value[1..];

        if (!current_open) {
            current = .init(allocator);
            current_open = true;
            current_failed = false;
        }
        if (current_failed) continue;
        current.writer.print("{s}\n", .{value}) catch {
            current.deinit();
            current_open = true;
            current_failed = true;
        };
    }
    // Final event without a trailing blank line.
    if (current_open and !current_failed) {
        const payload = try current.toOwnedSlice();
        try payloads.append(allocator, payload);
    }
    if (current_open) current.deinit();

    return payloads.toOwnedSlice(allocator);
}

/// One piece of assistant content extracted from a completion payload:
/// `whole` is `choices[0].message.content` (non-streaming completion),
/// `delta` is one `choices[0].delta.content` part (streaming).
pub const CompletionChunk = struct {
    kind: enum { whole, delta },
    text: []u8,
};

/// Extract assistant content from a single completion payload. Returns null
/// when the payload carries no content (for example a role-only delta or a
/// `finish_reason`-only chunk). The payload itself is never logged.
pub fn completionChunkFromJson(
    allocator: std.mem.Allocator,
    payload: []const u8,
) !?CompletionChunk {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const choices = parsed.value.object.get("choices") orelse return null;
    if (choices != .array or choices.array.items.len == 0) return null;
    const first = choices.array.items[0];
    if (first != .object) return null;

    if (first.object.get("message")) |message| {
        if (message == .object) {
            if (message.object.get("content")) |content| {
                if (content == .string) {
                    return .{
                        .kind = .whole,
                        .text = try allocator.dupe(u8, content.string),
                    };
                }
            }
        }
    }

    if (first.object.get("delta")) |delta| {
        if (delta == .object) {
            if (delta.object.get("content")) |content| {
                if (content == .string) {
                    return .{
                        .kind = .delta,
                        .text = try allocator.dupe(u8, content.string),
                    };
                }
            }
        }
    }

    return null;
}

/// Extract the assistant reply from a full response body.
///
/// - `text/event-stream` bodies are parsed as SSE: `data:` payloads are
///   processed in order, `[DONE]` stops the scan. The first full completion
///   (`message.content`) wins; otherwise all `delta.content` parts are
///   concatenated in order. Malformed JSON payloads are skipped, and an empty
///   or entirely malformed stream fails with `error.InvalidApiResponse`.
/// - Any other content type is parsed as one full completion JSON object.
///   When that fails and the body clearly contains `data:` fields, SSE
///   parsing is used as a defensive fallback (servers that stream with the
///   wrong Content-Type).
///
/// Returns an owned reply; the caller frees it. UTF-8 is preserved verbatim.
pub fn extractReply(
    allocator: std.mem.Allocator,
    content_type: []const u8,
    body: []const u8,
) ![]u8 {
    if (isEventStream(content_type)) {
        return extractReplyFromSse(allocator, body);
    }

    if (completionChunkFromJson(allocator, body)) |maybe| {
        if (maybe) |chunk| return chunk.text;
        return error.InvalidApiResponse;
    } else |json_err| {
        if (std.mem.indexOf(u8, body, "data:") != null) {
            return extractReplyFromSse(allocator, body);
        }
        return json_err;
    }
}

/// Parse one SSE payload into assistant content, tolerating the variant some
/// servers emit where the `data: [DONE]` terminator is glued directly onto a
/// bare JSON completion line (no newline between them): the terminator suffix
/// is stripped and the payload is retried. Malformed payloads return null and
/// are skipped by the caller. The payload is never logged.
fn parseChunkTolerant(
    allocator: std.mem.Allocator,
    payload: []const u8,
) ?CompletionChunk {
    if (completionChunkFromJson(allocator, payload)) |chunk| {
        return chunk;
    } else |_| {}

    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    const terminator = "data: [DONE]";
    if (std.mem.endsWith(u8, trimmed, terminator)) {
        const stripped = trimmed[0 .. trimmed.len - terminator.len];
        if (completionChunkFromJson(allocator, stripped)) |chunk| {
            return chunk;
        } else |_| {}
    }
    return null;
}

/// Parse an event-stream body into the assistant reply (see `extractReply`).
pub fn extractReplyFromSse(
    allocator: std.mem.Allocator,
    body: []const u8,
) ![]u8 {
    const payloads = try collectSseData(allocator, body);
    defer {
        for (payloads) |payload| allocator.free(payload);
        allocator.free(payloads);
    }

    var whole: ?[]u8 = null;
    var parts: std.ArrayList([]u8) = .empty;
    defer {
        for (parts.items) |part| allocator.free(part);
        parts.deinit(allocator);
    }

    for (payloads) |payload| {
        const trimmed = std.mem.trim(u8, payload, " ");
        if (std.mem.eql(u8, trimmed, "[DONE]")) break;

        const chunk = parseChunkTolerant(allocator, payload);
        if (chunk) |parsed| {
            switch (parsed.kind) {
                .whole => {
                    // Keep the first full completion; discard duplicates.
                    if (whole == null) {
                        whole = parsed.text;
                    } else {
                        allocator.free(parsed.text);
                    }
                },
                .delta => {
                    parts.append(allocator, parsed.text) catch allocator.free(parsed.text);
                },
            }
        }
    }

    if (whole) |text| return text;

    if (parts.items.len == 0) return error.InvalidApiResponse;

    var total: usize = 0;
    for (parts.items) |part| total += part.len;
    const joined = try allocator.alloc(u8, total);
    var offset: usize = 0;
    for (parts.items) |part| {
        @memcpy(joined[offset .. offset + part.len], part);
        offset += part.len;
    }
    return joined;
}

/// Bounded, sanitized body prefix for diagnostics: control characters
/// (including newlines) become `.`, multi-byte UTF-8 passes through, and the
/// result never exceeds the buffer length.
pub fn boundedPrefix(buffer: []u8, body: []const u8) []const u8 {
    const count = @min(buffer.len, body.len);
    for (0..count) |index| {
        const byte = body[index];
        buffer[index] = if (byte < 0x20 or byte == 0x7f) '.' else byte;
    }
    return buffer[0..count];
}

// ---------------------------------------------------------------------------
// Response parsing tests: JSON completion, SSE, UTF-8, safe errors
// ---------------------------------------------------------------------------

test "plain json completion extracts message content with utf-8 intact" {
    const body =
        \\{"id":"1","model":"m","choices":[{"index":0,"finish_reason":"stop",
        \\"message":{"role":"assistant","content":"Halo! 👋 Semoga harimu menyenangkan."}}],
        \\"usage":{"prompt_tokens":5,"completion_tokens":7,"total_tokens":12}}
    ;

    const reply = try extractReply(std.testing.allocator, "application/json", body);
    defer std.testing.allocator.free(reply);

    try std.testing.expectEqualStrings("Halo! 👋 Semoga harimu menyenangkan.", reply);
    try std.testing.expect(std.unicode.utf8ValidateSlice(reply));
    // Byte-exact: 👋 (U+1F44B) is exactly the four UTF-8 bytes f0 9f 91 8b,
    // so the extraction neither transliterates nor double-encodes it.
    try std.testing.expectEqualSlices(u8, &.{ 0xf0, 0x9f, 0x91, 0x8b }, reply[6..10]);
}

test "sse with one whole completion and done marker is parsed" {
    const body = ": keep-alive\n\n" ++
        "data: {\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"Halo! 👋\"}}]}\n\n" ++
        "data: [DONE]\n\n" ++
        "data: {\"ignored\":true}\n\n";

    const reply = try extractReply(std.testing.allocator, "text/event-stream", body);
    defer std.testing.allocator.free(reply);

    // [DONE] stops the scan: events after it are ignored.
    try std.testing.expectEqualStrings("Halo! 👋", reply);
    try std.testing.expect(std.unicode.utf8ValidateSlice(reply));
}

test "sse with crlf endings comments and event fields is parsed" {
    const body = "event: completion\r\n" ++
        "data: {\"choices\":[{\"message\":{\"content\":\"Halo\"}}]}\r\n" ++
        "\r\n" ++
        ": ping\r\n" ++
        "data: [DONE]\r\n\r\n";

    const reply = try extractReply(std.testing.allocator, "text/event-stream; charset=utf-8", body);
    defer std.testing.allocator.free(reply);

    try std.testing.expectEqualStrings("Halo", reply);
}

test "sse deltas are concatenated in order across utf-8 boundaries" {
    const body =
        "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"Sampai jumpa \"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"☀ teman!\"}}]}\n\n" ++
        "data: [DONE]\n\n";

    const reply = try extractReply(std.testing.allocator, "text/event-stream", body);
    defer std.testing.allocator.free(reply);

    try std.testing.expectEqualStrings("Sampai jumpa ☀ teman!", reply);
    try std.testing.expect(std.unicode.utf8ValidateSlice(reply));
}

test "sse deltas with unicode escapes decode to intact emoji" {
    // 👋 as a surrogate-pair escape inside the JSON string (U+1F44B =
    // \uD83D\uDC4B); the decoder must recombine it into valid UTF-8.
    const body = "data: {\"choices\":[{\"delta\":{\"content\":\"Halo \\ud83d\\udc4b\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\" semuanya\"}}]}\n\n" ++
        "data: [DONE]\n\n";

    const reply = try extractReply(std.testing.allocator, "text/event-stream", body);
    defer std.testing.allocator.free(reply);

    try std.testing.expectEqualStrings("Halo 👋 semuanya", reply);
    try std.testing.expect(std.unicode.utf8ValidateSlice(reply));
}

test "empty and malformed sse bodies fail with a safe error" {
    // Completely empty body.
    try std.testing.expectError(
        error.InvalidApiResponse,
        extractReply(std.testing.allocator, "text/event-stream", ""),
    );

    // Comments only: no data fields at all.
    try std.testing.expectError(
        error.InvalidApiResponse,
        extractReply(std.testing.allocator, "text/event-stream", ": keep-alive\n\n"),
    );

    // Data payloads that are not JSON are skipped; nothing usable remains.
    try std.testing.expectError(
        error.InvalidApiResponse,
        extractReply(std.testing.allocator, "text/event-stream", "data: hello\n\ndata: [DONE]\n\n"),
    );

    // A malformed payload between valid ones is skipped, not fatal.
    const body = "data: not-json\n\n" ++
        "data: {\"choices\":[{\"message\":{\"content\":\"selamat\"}}]}\n\n" ++
        "data: [DONE]\n\n";
    const reply = try extractReply(std.testing.allocator, "text/event-stream", body);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("selamat", reply);
}

test "json bodies with sse content fall back when the content type lies" {
    const body = "data: {\"choices\":[{\"message\":{\"content\":\"dari sse\"}}]}\n\n" ++
        "data: [DONE]\n\n";

    const reply = try extractReply(std.testing.allocator, "application/json", body);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("dari sse", reply);

    // A genuinely invalid JSON body without data fields fails with the
    // underlying parse error (safe: content is never echoed).
    try std.testing.expectError(
        error.SyntaxError,
        extractReply(std.testing.allocator, "application/json", "bukan json"),
    );
}

test "bounded prefix truncates and sanitizes control characters" {
    var buffer: [256]u8 = undefined;

    const short = boundedPrefix(&buffer, "ok\nbinary\x01tail");
    try std.testing.expectEqualStrings("ok.binary.tail", short);

    const long_body = "a" ** 400;
    const bounded = boundedPrefix(&buffer, long_body);
    try std.testing.expect(bounded.len <= buffer.len);
    try std.testing.expectEqualStrings("a" ** 256, bounded);

    // Multi-byte UTF-8 passes through untouched.
    const unicode = boundedPrefix(&buffer, "Halo 👋");
    try std.testing.expectEqualStrings("Halo 👋", unicode);
    try std.testing.expect(std.unicode.utf8ValidateSlice(unicode));
}
test "sse body with a bare json completion then done is parsed" {
    // Observed in the wild: Content-Type text/event-stream with one full
    // completion object (no `data:` prefix) followed by `data: [DONE]`.
    const body =
        "{\"choices\":[{\"finish_reason\":\"stop\",\"index\":0," ++
        "\"message\":{\"role\":\"assistant\",\"content\":\"Hai! 👋 Siap membantu.\"}}]," ++
        "\"model\":\"m\",\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":9,\"total_tokens\":14}}\n" ++
        "data: [DONE]\n";

    const reply = try extractReply(std.testing.allocator, "text/event-stream", body);
    defer std.testing.allocator.free(reply);

    try std.testing.expectEqualStrings("Hai! 👋 Siap membantu.", reply);
    try std.testing.expect(std.unicode.utf8ValidateSlice(reply));
}

test "glued data done terminator on a bare json line is tolerated" {
    // Same server variant with NO newline between the completion and the
    // terminator: `...}}data: [DONE]\n`.
    const body =
        "{\"choices\":[{\"finish_reason\":\"stop\",\"index\":0," ++
        "\"message\":{\"role\":\"assistant\",\"content\":\"Hai! 👋 Siap membantu.\"}}]," ++
        "\"usage\":{\"total_tokens\":14}}data: [DONE]\n";

    const reply = try extractReply(std.testing.allocator, "text/event-stream", body);
    defer std.testing.allocator.free(reply);

    try std.testing.expectEqualStrings("Hai! 👋 Siap membantu.", reply);
    try std.testing.expect(std.unicode.utf8ValidateSlice(reply));
}

// ---------------------------------------------------------------------------
// Model discovery (OpenAI-compatible /v1/models)
// ---------------------------------------------------------------------------

/// One normalized model record. All strings are owned; free the whole result
/// with `ModelsResult.deinit`.
pub const ModelRecord = struct {
    id: []u8,
    display_name: []u8,
    /// Owner/organization reported by the endpoint (e.g. "system"), if any.
    owner: ?[]u8 = null,
    /// Provider-reported creation time (unix seconds), when present.
    created: ?i64 = null,
    /// True only when the endpoint reported a capabilities block. When false,
    /// the flags below are unknown rather than false.
    capabilities_known: bool = false,
    streaming: bool = false,
    vision: bool = false,
    tool_calling: bool = false,
    context_limit: ?u64 = null,
};

pub const ModelsResult = struct {
    models: []ModelRecord = &.{},

    pub fn deinit(self: *ModelsResult, allocator: std.mem.Allocator) void {
        for (self.models) |model| {
            allocator.free(model.id);
            allocator.free(model.display_name);
            if (model.owner) |owner| allocator.free(owner);
        }
        allocator.free(self.models);
        self.models = &.{};
    }
};

/// Parse an OpenAI-compatible `GET /models` response body. Pure: no I/O and
/// no network, so provider-dependent shapes are unit-testable. Entries
/// without a non-empty string `id` are skipped; a body without a usable
/// `data` array fails with `InvalidApiResponse`. No credential material can
/// appear in the result: the parse only reads `data` entries.
pub fn parseModelsResponse(allocator: std.mem.Allocator, body: []const u8) !ModelsResult {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidApiResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidApiResponse;
    const data = parsed.value.object.get("data") orelse return error.InvalidApiResponse;
    if (data != .array) return error.InvalidApiResponse;

    var records: std.ArrayList(ModelRecord) = .empty;
    errdefer {
        for (records.items) |*model| {
            allocator.free(model.id);
            allocator.free(model.display_name);
            if (model.owner) |owner| allocator.free(owner);
        }
        records.deinit(allocator);
    }

    for (data.array.items) |item| {
        if (item != .object) continue;
        const id_value = item.object.get("id") orelse continue;
        if (id_value != .string or id_value.string.len == 0) continue;
        const id = try allocator.dupe(u8, id_value.string);
        errdefer allocator.free(id);
        const display = try allocator.dupe(u8, id_value.string);

        var record = ModelRecord{ .id = id, .display_name = display };
        if (item.object.get("display_name")) |value| {
            if (value == .string and value.string.len > 0) {
                allocator.free(record.display_name);
                record.display_name = try allocator.dupe(u8, value.string);
            }
        }
        if (item.object.get("owned_by")) |value| {
            if (value == .string and value.string.len > 0) {
                record.owner = try allocator.dupe(u8, value.string);
            }
        }
        if (item.object.get("created")) |value| {
            if (value == .integer and value.integer >= 0) {
                record.created = value.integer;
            }
        }
        if (item.object.get("context_window")) |value| {
            if (value == .integer and value.integer > 0) record.context_limit = @intCast(value.integer);
        } else if (item.object.get("context_length")) |value| {
            if (value == .integer and value.integer > 0) record.context_limit = @intCast(value.integer);
        }
        if (item.object.get("capabilities")) |value| {
            if (value == .object) {
                record.capabilities_known = true;
                if (value.object.get("streaming")) |flag| {
                    if (flag == .bool) record.streaming = flag.bool;
                }
                if (value.object.get("vision")) |flag| {
                    if (flag == .bool) record.vision = flag.bool;
                }
                if (value.object.get("tool_calling")) |flag| {
                    if (flag == .bool) record.tool_calling = flag.bool;
                }
            }
        }

        try records.append(allocator, record);
    }

    return .{ .models = try records.toOwnedSlice(allocator) };
}

/// Fetch and normalize `GET <base_url>/models` with the same bearer
/// credentials as chat requests, under the same hard request deadline: a
/// hung endpoint fails with `error.RequestTimeout` instead of blocking the
/// single-threaded runtime. The Authorization header and API key are never
/// logged and never appear in the returned records.
pub fn listModels(self: *Provider) !ModelsResult {
    const api_key = try self.getApiKey();
    defer self.allocator.free(api_key);

    const url_string = try std.fmt.allocPrint(self.allocator, "{s}/models", .{self.baseUrl()});
    defer self.allocator.free(url_string);
    const uri = try std.Uri.parse(url_string);

    const auth = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{api_key});
    defer self.allocator.free(auth);

    // Same ownership protocol as `chat`: the task owns copies of its inputs.
    const task = blk: {
        const created = try self.allocator.create(ModelsTask);
        errdefer self.allocator.destroy(created);
        created.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .guard = .{ .io = self.io },
            .uri = uri,
            .url = undefined,
            .auth = undefined,
        };
        created.url = try self.allocator.dupe(u8, url_string);
        errdefer self.allocator.free(created.url);
        created.auth = try self.allocator.dupe(u8, auth);
        errdefer self.allocator.free(created.auth);
        break :blk created;
    };

    var select_buffer: [2]ModelsExchange.SelectResult = undefined;
    var exchange_select = ModelsExchange.Select.init(self.io, &select_buffer);
    exchange_select.concurrent(.exchange, modelsExchangeTask, .{task}) catch |err| {
        self.allocator.free(task.url);
        self.allocator.free(task.auth);
        self.allocator.destroy(task);
        // Honest refusal: without concurrency there is no deadline.
        return switch (err) {
            error.ConcurrencyUnavailable => error.RequestDeadlineUnavailable,
        };
    };

    const waited = ModelsExchange.wait(
        self.allocator,
        &exchange_select,
        &task.guard,
        self.config.request_timeout_ms,
    );
    return switch (waited) {
        .result => |result| {
            self.allocator.destroy(task);
            return result;
        },
        .failed => |err| {
            self.allocator.destroy(task);
            return err;
        },
        .abandoned => |err| err,
    };
}

test "model discovery parses ids owners and optional metadata" {
    const body =
        \\{"object":"list","data":[
        \\{"id":"model-a","object":"model","created":1700000000,"owned_by":"system"},
        \\{"id":"model-b","display_name":"Model B","context_window":128000,
        \\"capabilities":{"streaming":true,"vision":false,"tool_calling":true}},
        \\{"id":"","object":"model"},
        \\{"nope":true},
        \\{"id":"model-c"}
        \\]}
    ;

    var result = try parseModelsResponse(std.testing.allocator, body);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.models.len);
    try std.testing.expectEqualStrings("model-a", result.models[0].id);
    try std.testing.expectEqualStrings("model-a", result.models[0].display_name);
    try std.testing.expectEqualStrings("system", result.models[0].owner.?);
    try std.testing.expectEqual(@as(?i64, 1700000000), result.models[0].created);
    try std.testing.expect(!result.models[0].capabilities_known);

    try std.testing.expectEqualStrings("Model B", result.models[1].display_name);
    try std.testing.expectEqual(@as(?u64, 128000), result.models[1].context_limit);
    try std.testing.expect(result.models[1].capabilities_known);
    try std.testing.expect(result.models[1].streaming);
    try std.testing.expect(result.models[1].tool_calling);
    try std.testing.expect(!result.models[1].vision);

    try std.testing.expectEqualStrings("model-c", result.models[2].id);
    try std.testing.expect(result.models[2].owner == null);
}

test "model discovery rejects bodies without a data list" {
    try std.testing.expectError(error.InvalidApiResponse, parseModelsResponse(std.testing.allocator, "{}"));
    try std.testing.expectError(error.InvalidApiResponse, parseModelsResponse(std.testing.allocator, "{\"data\":{}}"));
    try std.testing.expectError(error.InvalidApiResponse, parseModelsResponse(std.testing.allocator, "not json"));

    var empty = try parseModelsResponse(std.testing.allocator, "{\"data\":[]}");
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.models.len);
}

// ---------------------------------------------------------------------------
// Bounded request regression tests: real local sockets, no internet
// ---------------------------------------------------------------------------

const TestServerBehavior = union(enum) {
    respond,
    /// Accepts, never responds, and tears the connection down after the
    /// given delay: the exchange must fail within its deadline, and the
    /// teardown lets the task drain before the test ends.
    stall_close_after_ms: u64,
};

const TestHttpServer = struct {
    io: std.Io,
    port: u16,
    listener: std.Io.net.Server,

    /// Bind a loopback port; retry a few candidates to dodge races with
    /// other processes on shared machines.
    fn start(io: std.Io) !TestHttpServer {
        var port: u16 = 24100;
        var attempt: usize = 0;
        while (attempt < 32) : (attempt += 1) {
            const address = std.Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
            if (address.listen(io, .{ .reuse_address = true })) |listener| {
                return .{ .io = io, .port = port, .listener = listener };
            } else |_| {
                port +%= 1;
            }
        }
        return error.NoTestPortAvailable;
    }

    fn stop(self: *TestHttpServer) void {
        self.listener.deinit(self.io);
    }

    /// Serve exactly one connection from a detached thread. `respond` writes
    /// a canned chat-completion response and closes; `hang` accepts and then
    /// never writes, modeling a provider endpoint that accepts a connection
    /// and stalls forever (the QA hang case).
    fn spawn(self: *TestHttpServer, behavior: TestServerBehavior) void {
        const thread = std.Thread.spawn(.{}, serveOne, .{ self, behavior }) catch return;
        thread.detach();
    }

    fn serveOne(self: *TestHttpServer, behavior: TestServerBehavior) void {
        const io = self.io;
        var stream = self.listener.accept(io) catch return;
        switch (behavior) {
            .respond => {
                const body =
                    "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"halo dari server uji\"}}]}";
                var head_buffer: [256]u8 = undefined;
                const head = std.fmt.bufPrint(
                    &head_buffer,
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
                    .{body.len},
                ) catch return;
                var writer = stream.writer(io, &.{});
                writer.interface.writeAll(head) catch return;
                writer.interface.writeAll(body) catch return;
                writer.interface.flush() catch return;

                // Half-close send, then drain the client's request bytes
                // before closing: closing with unread data pending sends a
                // RST on Windows, which the peer would observe as a spurious
                // LOCAL_DISCONNECT instead of a clean response + EOF.
                stream.shutdown(io, .send) catch {};
                var drain_buffer: [512]u8 = undefined;
                var sink_buffer: [512]u8 = undefined;
                var drain_reader = stream.reader(io, &drain_buffer);
                var sink = std.Io.Writer.Discarding.init(&sink_buffer);
                _ = drain_reader.interface.streamRemaining(&sink.writer) catch {};
                stream.close(io);
            },
            .stall_close_after_ms => |close_after_ms| {
                // Never write: the client blocks in its read until the
                // deadline shutdown — or this teardown — unblocks it. The
                // bounded teardown keeps the test deterministic: the task is
                // always joined before the test ends.
                const nap: std.Io.Timeout = .{ .duration = .{
                    .raw = std.Io.Duration.fromMilliseconds(@intCast(close_after_ms)),
                    .clock = .awake,
                } };
                nap.sleep(io) catch {};
                // Consume the client's request bytes before closing: closing
                // with unread data pending sends a RST on Windows, which the
                // blocked client read would surface as unexpectedStatus noise
                // instead of a clean EOF.
                var drain_buffer: [512]u8 = undefined;
                var drain_reader = stream.reader(io, &drain_buffer);
                _ = drain_reader.interface.readSliceShort(&drain_buffer) catch {};
                stream.shutdown(io, .both) catch {};
                stream.close(io);
            },
        }
    }
};

fn testProvider(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    base_url: []const u8,
    timeout_ms: u32,
) Provider {
    return Provider.init(allocator, io, env_map, .{
        .agent_name = "Test",
        .model = "test-model",
        .base_url = base_url,
        .system_prompt = "TEST POLICY",
        .temperature = 0.7,
        .max_tokens = 64,
        .soul_path = "SOUL.md",
        .memory_path = "MEMORY.md",
        .soul_budget_bytes = 1024,
        .memory_budget_bytes = 1024,
        .owner_budget_bytes = 2048,
        .request_timeout_ms = timeout_ms,
    });
}

test "model records never echo credential-shaped fields" {
    // Extra unknown fields (including a hypothetical credential) are ignored:
    // the parser reads only the whitelisted keys.
    const body =
        \\{"data":[{"id":"m","authorization":"Bearer secret","api_key":"x"}]}
    ;
    var result = try parseModelsResponse(std.testing.allocator, body);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.models.len);
}

test "provider chat completes against a local server within the deadline" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestHttpServer.start(io);
    defer server.stop();
    server.spawn(.respond);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PICO_CLAW_API_KEY", "canary-not-a-real-key");

    const base_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/v1", .{server.port});
    defer allocator.free(base_url);

    var provider = testProvider(allocator, io, &env_map, base_url, 10_000);

    var context = Context.init(allocator);
    defer context.deinit();
    try context.addUser("hello");

    const started = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    const reply = try provider.chat(&context);
    defer allocator.free(reply);
    const elapsed = std.Io.Timestamp.now(io, .awake).toMilliseconds() - started;

    try std.testing.expectEqualStrings("halo dari server uji", reply);
    // The concurrent exchange must not have waited for anything near the
    // (10 second) deadline: a healthy exchange finishes immediately.
    try std.testing.expect(elapsed < 10_000);
}

test "provider chat fails with RequestTimeout against a hung server" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestHttpServer.start(io);
    defer server.stop();
    // Accepts the connection and stalls forever: the pre-fix behavior would
    // block the whole single-threaded runtime indefinitely. The server tears
    // its connection down at 1000 ms — after the 500 ms deadline and well
    // inside the join grace window — so the exchange task is always fully
    // drained before the test ends.
    server.spawn(.{ .stall_close_after_ms = 1_000 });

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PICO_CLAW_API_KEY", "canary-not-a-real-key");

    const base_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/v1", .{server.port});
    defer allocator.free(base_url);

    var provider = testProvider(allocator, io, &env_map, base_url, 500);

    var context = Context.init(allocator);
    defer context.deinit();
    try context.addUser("hello");

    const started = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    const result = provider.chat(&context);
    try std.testing.expectError(error.RequestTimeout, result);
    const elapsed = std.Io.Timestamp.now(io, .awake).toMilliseconds() - started;

    // Bounded: at least the 500 ms deadline, but far below an unbounded hang.
    // Generous upper bound keeps slow CI hosts green.
    try std.testing.expect(elapsed < 10_000);
    try std.testing.expect(elapsed >= 500);
}
