const std = @import("std");
const format = @import("../format.zig");
const session_mod = @import("../channels/session.zig");

pub const max_request_body = 1024 * 1024;

/// Upload route ceiling: attachments have their own, much larger, transport
/// budget. The service still enforces its own per-attachment and quota limits.
pub const max_upload_body = 20 * 1024 * 1024;

/// The transport budget for a request body, chosen by route. Uploads get the
/// large ceiling; everything else stays at the strict API limit.
fn bodyLimit(target: []const u8) usize {
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
    if (std.mem.eql(u8, path, "/api/attachments")) return max_upload_body;
    return max_request_body;
}

/// Extract and percent-decode one query parameter (`?name=...`). Returns an
/// owned string; `+` decodes to a space so file names survive the trip.
fn queryParam(allocator: std.mem.Allocator, target: []const u8, key: []const u8) ?[]u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], key)) continue;
        const raw = pair[eq + 1 ..];
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            if (c == '%' and i + 2 < raw.len) {
                const hi = std.fmt.charToDigit(raw[i + 1], 16) catch {
                    out.append(allocator, c) catch return null;
                    i += 1;
                    continue;
                };
                const lo = std.fmt.charToDigit(raw[i + 2], 16) catch {
                    out.append(allocator, c) catch return null;
                    i += 1;
                    continue;
                };
                out.append(allocator, @intCast(hi * 16 + lo)) catch return null;
                i += 3;
                continue;
            }
            if (c == '+') {
                out.append(allocator, ' ') catch return null;
            } else {
                out.append(allocator, c) catch return null;
            }
            i += 1;
        }
        return out.toOwnedSlice(allocator) catch null;
    }
    return null;
}
pub const default_port: u16 = 8080;

const json_header = std.http.Header{ .name = "content-type", .value = "application/json" };
const html_header = std.http.Header{ .name = "content-type", .value = "text/html; charset=utf-8" };

/// Modern single-page dashboard. Embedded at build time; no asset pipeline,
/// no external requests (fonts, scripts, or styles are all inline).
const dashboard_html = @embedFile("dashboard.html");

/// Session identity of the dashboard chat inside the shared `SessionStore`.
pub const default_chat_id = "dashboard";

/// Adapter so the dashboard chat goes through the same session layer and
/// agent core as CLI chat and Telegram.
pub const SessionChatHandler = struct {
    sessions: *session_mod.SessionStore,

    pub fn send(self: *SessionChatHandler, message: []const u8) ![]u8 {
        const conversation = try self.sessions.getOrCreate(default_chat_id);
        return conversation.send(message);
    }
};

const task_mod = @import("../core/task.zig");
const service_mod = @import("../services/service.zig");
const gateway_mod = @import("../services/gateways.zig");
const models_mod = @import("../services/models.zig");
const settings_mod = @import("../services/settings.zig");
const profiles_mod = @import("../services/profiles.zig");
const tool_registry_mod = @import("../tools/registry.zig");
const provider_mod = @import("../provider.zig");
const memory_mod = @import("../memory/memory.zig");
const experience_store_mod = @import("../experience/store.zig");
const strategy_store_mod = @import("../experience/strategy_store.zig");
const knowledge_mod = @import("../knowledge.zig");
const owner_mod = @import("../owner.zig");
const task_store_mod = @import("../core/task_store.zig");
const proposal_store_mod = @import("../experience/proposal.zig");
const sandbox_mod = @import("../runtime/sandbox.zig");
const attachments_mod = @import("../runtime/attachments.zig");
const artifacts_mod = @import("../services/artifacts.zig");
const fsops_mod = @import("../runtime/fsops.zig");
const archives_mod = @import("../runtime/archives.zig");
const jobs_mod = @import("../core/jobs.zig");
const runs_store_mod = @import("../core/runs.zig");
const Services = service_mod.Services;

/// Dashboard authentication configuration. A token is optional on loopback;
/// binding any non-loopback address REQUIRES a token (enforced at startup).
pub const Auth = struct {
    token: ?[]const u8 = null,
};

pub const security_errors = error{
    /// Refuse to bind a non-loopback address without a dashboard token.
    NonLoopbackRequiresAuth,
    InvalidHost,
};

pub fn isLoopbackHost(host: []const u8) bool {
    return std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "::1");
}

/// Length-checked, branch-equal token comparison (no early exit on content).
pub fn tokenMatches(presented: []const u8, expected: []const u8) bool {
    if (presented.len != expected.len) return false;
    if (presented.len == 0) return false;
    var matched: u8 = 1;
    for (presented, expected) |a, b| matched &= @intFromBool(a == b);
    return matched == 1;
}

/// Startup bind policy: a non-loopback bind address requires a dashboard
/// token. Called by `serve` before the listener is created.
pub fn validateBind(host: []const u8, token: ?[]const u8) security_errors!void {
    if (!isLoopbackHost(host) and token == null) return error.NonLoopbackRequiresAuth;
}

/// Path portion of a request target, query string stripped.
pub fn requestPath(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |q| return target[0..q];
    return target;
}

/// True for the dashboard shell route: `GET /` (or `HEAD /`), query aside.
/// The shell is static markup containing no secrets; it is deliberately
/// served without a token so a remote browser can load the login UI when
/// token authentication is enabled. Every data route (API, chat, health,
/// artifacts, uploads) stays token-protected.
pub fn isDashboardShell(method: std.http.Method, target: []const u8) bool {
    if (method != .GET and method != .HEAD) return false;
    return std.mem.eql(u8, requestPath(target), "/");
}

/// Token-authentication gate for an incoming request. Returns the rejection
/// status when the request must be refused, or `null` when it may proceed.
///
/// - No token configured: nothing is rejected here (loopback default).
/// - Token configured: `Authorization: Bearer <token>` or `X-Pico-Token`
///   must match — except the dashboard shell (`GET /`), which is served
///   without a token so the browser can render the login UI.
/// - A non-loopback bind without a token is refused earlier, at startup,
///   by `validateBind` (a token-less server never exposes the shell route).
pub fn authGate(
    auth: Auth,
    method: std.http.Method,
    target: []const u8,
    bearer: ?[]const u8,
    pico_token: ?[]const u8,
) ?std.http.Status {
    const token = auth.token orelse return null;
    if (isDashboardShell(method, target)) return null;
    const authorized = (bearer != null and tokenMatches(bearer.?, token)) or
        (pico_token != null and tokenMatches(pico_token.?, token));
    if (!authorized) return .unauthorized;
    return null;
}

/// Fixed-window rate limiter for state-changing requests. The server loop
/// is single-threaded, so no synchronization is needed.
pub const RateLimiter = struct {
    limit: usize = 120,
    window_start_ms: i64 = 0,
    count: usize = 0,

    pub const window_ms: i64 = 60_000;

    pub fn allow(self: *RateLimiter, now_ms: i64) bool {
        if (now_ms - self.window_start_ms >= window_ms) {
            self.window_start_ms = now_ms;
            self.count = 0;
        }
        if (self.count >= self.limit) return false;
        self.count += 1;
        return true;
    }
};

/// CSRF protection for the unauthenticated loopback default: browser
/// state-changing fetches carry an Origin header; when present it must match
/// the request host. Non-browser clients send no Origin and pass.
pub fn originAllowed(origin: ?[]const u8, host: ?[]const u8) bool {
    const value = origin orelse return true;
    if (value.len == 0) return true;
    const scheme_end = std.mem.indexOf(u8, value, "://") orelse return false;
    const authority = value[scheme_end + 3 ..];
    const actual_host = host orelse "";
    if (actual_host.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(authority, actual_host)) return true;
    // The request host may omit the default port; compare without the port too.
    if (std.mem.indexOfScalar(u8, authority, ':')) |colon| {
        if (std.ascii.eqlIgnoreCase(authority[0..colon], actual_host)) return true;
    }
    return false;
}

fn isStateChanging(method: std.http.Method) bool {
    return method == .POST or method == .PUT or method == .DELETE or method == .PATCH;
}

fn errorBodyFor(status: std.http.Status) []const u8 {
    return switch (status) {
        .unauthorized => "{\"ok\":false,\"error\":{\"code\":\"UNAUTHORIZED\",\"message\":\"authentication required\"}}",
        .forbidden => "{\"ok\":false,\"error\":{\"code\":\"FORBIDDEN\",\"message\":\"origin rejected\"}}",
        .too_many_requests => "{\"ok\":false,\"error\":{\"code\":\"RATE_LIMITED\",\"message\":\"too many requests\"}}",
        else => "{\"ok\":false,\"error\":{\"code\":\"REJECTED\",\"message\":\"request rejected\"}}",
    };
}

/// Wraps a service JSON payload in the standard ok envelope.
fn okEnvelope(allocator: std.mem.Allocator, data: []const u8) Response {
    defer allocator.free(data); // ownership of the service payload transfers here
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    output.writer.writeAll("{\"ok\":true,\"data\":") catch return internalError();
    output.writer.writeAll(data) catch return internalError();
    output.writer.writeAll("}") catch return internalError();
    var list = output.toArrayList();
    const owned = list.toOwnedSlice(allocator) catch return internalError();
    return .{ .status = .ok, .body = owned, .owned = true };
}

fn internalError() Response {
    return .{ .status = .internal_server_error, .body = "{\"ok\":false,\"error\":{\"code\":\"INTERNAL\",\"message\":\"internal error\"}}" };
}

/// Build the raw-bytes download response for an artifact, labeled with the
/// honest content type derived from the artifact kind.
fn artifactDownload(
    allocator: std.mem.Allocator,
    services: *Services,
    id: []const u8,
) Response {
    const result = services.artifactContent(id);
    switch (result) {
        .ok => |content| {
            const headers = allocator.alloc(std.http.Header, 1) catch
                return internalError();
            headers[0] = .{ .name = "content-type", .value = content.mime };
            return .{
                .status = .ok,
                .body = content.data,
                .owned = true,
                .content_type = headers,
                .owned_headers = true,
            };
        },
        .err => |e| return errorEnvelope(allocator, e.code, e.message),
    }
}

/// Map a service error to a status code and body. Never leaks internals.
fn errorEnvelope(allocator: std.mem.Allocator, code: []const u8, message: []const u8) Response {
    const status: std.http.Status = blk: {
        const Prefix = struct { code: []const u8, status: std.http.Status };
        const prefixes = [_]Prefix{
            .{ .code = "INVALID_", .status = .bad_request },
            .{ .code = "_NOT_FOUND", .status = .not_found },
            .{ .code = "ALREADY_EXISTS", .status = .conflict },
            .{ .code = "_ACTIVE", .status = .conflict },
            .{ .code = "NOT_CONFIGURED", .status = .service_unavailable },
            .{ .code = "GATEWAY_DISABLED", .status = .conflict },
            .{ .code = "GATEWAY_NOT_RUNNING", .status = .conflict },
            .{ .code = "_UNSUPPORTED", .status = .not_implemented },
            .{ .code = "PROVIDER_UNAVAILABLE", .status = .service_unavailable },
            .{ .code = "PROVIDER_INVALID", .status = .bad_gateway },
            .{ .code = "UNAVAILABLE", .status = .service_unavailable },
            .{ .code = "TOO_LARGE", .status = .payload_too_large },
            .{ .code = "METHOD_NOT_ALLOWED", .status = .method_not_allowed },
        };
        for (prefixes) |entry| {
            if (std.mem.indexOf(u8, code, entry.code) != null) break :blk entry.status;
        }
        break :blk .internal_server_error;
    };

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    output.writer.writeAll("{\"ok\":false,\"error\":{\"code\":") catch return internalError();
    appendJsonString(&output.writer, code) catch return internalError();
    output.writer.writeAll(",\"message\":") catch return internalError();
    appendJsonString(&output.writer, message) catch return internalError();
    output.writer.writeAll("}}") catch return internalError();
    var list = output.toArrayList();
    const owned = list.toOwnedSlice(allocator) catch return internalError();
    return .{ .status = status, .body = owned, .owned = true };
}

/// Everything the dashboard routes need. `sessions` may be null in tests;
/// API responses then report zeroed state instead of store contents.
pub const Dashboard = struct {
    handler: ChatHandler,
    sessions: ?*session_mod.SessionStore = null,
    agent_name: []const u8 = "Pico Claw",
    version: []const u8 = "0.1.0",
    model: []const u8 = "",
    base_url: []const u8 = "",
    telegram_state: []const u8 = "disabled",
    /// Application service facade for the control-plane API. Null keeps the
    /// legacy test behavior (zeroed API state).
    services: ?*Services = null,
    auth: Auth = .{},
};

pub const ChatHandler = struct {
    context: *anyopaque,
    sendFn: *const fn (*anyopaque, []const u8) anyerror![]u8,

    pub fn fromConversation(conversation: anytype) ChatHandler {
        const Pointer = @TypeOf(conversation);
        const Adapter = struct {
            fn send(context: *anyopaque, message: []const u8) ![]u8 {
                const value: Pointer = @ptrCast(@alignCast(context));
                return value.send(message);
            }
        };
        return .{ .context = conversation, .sendFn = Adapter.send };
    }

    fn send(self: ChatHandler, message: []const u8) ![]u8 {
        return self.sendFn(self.context, message);
    }
};

pub const Response = struct {
    status: std.http.Status,
    body: []const u8,
    owned: bool = false,
    content_type: []const std.http.Header = &.{json_header},
    /// True when `content_type` was heap-allocated and must be freed.
    owned_headers: bool = false,

    pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.body);
        if (self.owned_headers) allocator.free(self.content_type);
    }
};

pub fn route(
    allocator: std.mem.Allocator,
    handler: ChatHandler,
    method: std.http.Method,
    target: []const u8,
    body: []const u8,
    oversized: bool,
) Response {
    if (std.mem.eql(u8, target, "/")) {
        if (method != .GET) return jsonError(.method_not_allowed, "method not allowed");
        return .{ .status = .ok, .body = dashboard_html, .content_type = &.{html_header} };
    }
    if (std.mem.eql(u8, target, "/health")) {
        if (method != .GET) return jsonError(.method_not_allowed, "method not allowed");
        return .{ .status = .ok, .body = "{\"status\":\"ok\",\"agent\":\"Pico Claw\"}" };
    }
    if (std.mem.eql(u8, target, "/chat")) {
        if (method != .POST) return jsonError(.method_not_allowed, "method not allowed");
        if (oversized or body.len > max_request_body)
            return jsonError(.payload_too_large, "request body too large");

        const ChatRequest = struct { message: []const u8 };
        const parsed = std.json.parseFromSlice(ChatRequest, allocator, body, .{}) catch
            return jsonError(.bad_request, "invalid JSON or missing message");
        defer parsed.deinit();
        if (std.mem.trim(u8, parsed.value.message, " \t\r\n").len == 0)
            return jsonError(.bad_request, "message must not be empty");

        const reply = handler.send(parsed.value.message) catch
            return jsonError(.internal_server_error, "internal error");
        defer allocator.free(reply);
        const encoded = encodeChatReply(allocator, reply) catch
            return jsonError(.internal_server_error, "internal error");
        return .{ .status = .ok, .body = encoded, .owned = true };
    }
    return jsonError(.not_found, "not found");
}

/// Route a dashboard request. API routes are served first; everything else
/// (dashboard HTML, health, chat) falls through to the base `route`, so the
/// chat endpoint stays identical for the dashboard and any other client.
pub fn routeDashboard(
    allocator: std.mem.Allocator,
    dashboard: *const Dashboard,
    method: std.http.Method,
    target: []const u8,
    body: []const u8,
    oversized: bool,
) Response {
    // Control-plane API: every new endpoint goes through the application
    // service layer, never through agent internals directly.
    if (dashboard.services) |services| {
        if (apiRoute(allocator, services, method, target, body, oversized)) |response| return response;
    }
    if (dashboard.services == null) {
        // Legacy flat-shape routes (kept byte-identical for v1 clients and
        // tests). With services attached, apiRoute owns these paths.
        if (std.mem.eql(u8, target, "/api/status")) {
            if (method != .GET) return jsonError(.method_not_allowed, "method not allowed");
            return statusResponse(allocator, dashboard);
        }
        if (std.mem.eql(u8, target, "/api/sessions")) {
            if (method != .GET) return jsonError(.method_not_allowed, "method not allowed");
            return sessionsResponse(allocator, dashboard);
        }
        if (std.mem.eql(u8, target, "/api/sessions/clear")) {
            if (method != .POST) return jsonError(.method_not_allowed, "method not allowed");
            if (oversized or body.len > max_request_body)
                return jsonError(.payload_too_large, "request body too large");
            return clearSessionResponse(allocator, dashboard, body);
        }
    }
    return route(allocator, dashboard.handler, method, target, body, oversized);
}

/// Arena-backed JSON body reader. String field slices stay valid until
/// `deinit`, and the whole thing is freed at once — no per-request leaks.
const ParsedBody = struct {
    arena: std.heap.ArenaAllocator,
    value: std.json.Value,

    pub fn deinit(self: *ParsedBody) void {
        self.arena.deinit();
    }

    pub fn str(self: *const ParsedBody, name: []const u8) ?[]const u8 {
        if (self.value != .object) return null;
        const field = self.value.object.get(name) orelse return null;
        if (field != .string) return null;
        return field.string;
    }

    pub fn num(self: *const ParsedBody, name: []const u8) ?f64 {
        if (self.value != .object) return null;
        const field = self.value.object.get(name) orelse return null;
        return switch (field) {
            .float => |v| v,
            .integer => |v| @floatFromInt(v),
            .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
            else => null,
        };
    }

    pub fn uint(self: *const ParsedBody, name: []const u8) ?u64 {
        if (self.value != .object) return null;
        const field = self.value.object.get(name) orelse return null;
        if (field == .integer and field.integer >= 0) return @intCast(field.integer);
        return null;
    }

    pub fn boolean(self: *const ParsedBody, name: []const u8) ?bool {
        if (self.value != .object) return null;
        const field = self.value.object.get(name) orelse return null;
        if (field == .bool) return field.bool;
        return null;
    }

    /// True when the field exists at all (any JSON type). Lets callers
    /// distinguish "absent" from "present but not a string/list".
    pub fn has(self: *const ParsedBody, name: []const u8) bool {
        if (self.value != .object) return false;
        return self.value.object.get(name) != null;
    }

    /// Array-of-strings field, borrowed from the parse arena. `null` means
    /// the field is absent or structurally invalid (not an array, or any
    /// element is not a string). Hard-capped: a request cannot smuggle an
    /// unbounded list through here.
    pub fn strList(self: *ParsedBody, name: []const u8, comptime max_entries: usize) ?[]const []const u8 {
        if (self.value != .object) return null;
        const field = self.value.object.get(name) orelse return null;
        if (field != .array) return null;
        if (field.array.items.len > max_entries) return null;
        const items = self.arena.allocator().alloc([]const u8, field.array.items.len) catch return null;
        for (field.array.items, 0..) |element, index| {
            if (element != .string) return null;
            items[index] = element.string;
        }
        return items;
    }
};

fn parseBody(allocator: std.mem.Allocator, body: []const u8) ?ParsedBody {
    if (body.len == 0 or body.len > max_request_body) return null;
    var arena = std.heap.ArenaAllocator.init(allocator);
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{}) catch {
        arena.deinit();
        return null;
    };
    return .{ .arena = arena, .value = value };
}

fn memoryTypeFrom(name: []const u8) ?@import("../memory/entry.zig").MemoryType {
    if (name.len == 0) return null;
    return @import("../memory/entry.zig").MemoryType.fromString(name);
}

fn outcomeResponse(allocator: std.mem.Allocator, outcome: service_mod.Outcome) Response {
    switch (outcome) {
        // Payload ownership transfers to okEnvelope, which frees it.
        .ok => |data| return okEnvelope(allocator, data),
        .err => |e| return errorEnvelope(allocator, e.code, e.message),
    }
}

const ActionFn = *const fn (*Services, []const u8, []const u8) service_mod.Outcome;

/// `/api/<group>/<id>/<action>` with POST. Shared by skills, tools, and
/// gateway lifecycle actions.
fn handleActionRoute(
    allocator: std.mem.Allocator,
    services: *Services,
    method: std.http.Method,
    target: []const u8,
    prefix: []const u8,
    call: ActionFn,
) ?Response {
    const rest = target[prefix.len..];
    const slash = std.mem.lastIndexOfScalar(u8, rest, '/') orelse return errorEnvelope(allocator, "NOT_FOUND", "action required");
    const id = rest[0..slash];
    const action = rest[slash + 1 ..];
    if (id.len == 0 or action.len == 0) return errorEnvelope(allocator, "NOT_FOUND", "action required");
    if (method != .POST) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
    return outcomeResponse(allocator, call(services, id, action));
}

/// Control-plane API router. Returns null for paths it does not own so the
/// legacy fall-through keeps handling the dashboard, health, and chat.
fn apiRoute(
    allocator: std.mem.Allocator,
    services: *Services,
    method: std.http.Method,
    target: []const u8,
    body: []const u8,
    oversized: bool,
) ?Response {
    if (oversized or body.len > max_request_body) {
        if (isStateChanging(method)) return errorEnvelope(allocator, "PAYLOAD_TOO_LARGE", "request body too large");
    }

    // --- capabilities / status ---
    if (std.mem.eql(u8, target, "/api/status")) {
        if (method != .GET) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
        const payload = services.statusJson() catch return errorEnvelope(allocator, "INTERNAL", "encoding failed");
        return okEnvelope(allocator, payload);
    }
    if (std.mem.eql(u8, target, "/api/capabilities")) {
        if (method != .GET) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
        const payload = services.capabilitiesJson() catch return errorEnvelope(allocator, "INTERNAL", "encoding failed");
        return okEnvelope(allocator, payload);
    }
    if (std.mem.eql(u8, target, "/api/sandbox")) {
        if (method != .GET) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
        const payload = services.sandboxJson() catch return errorEnvelope(allocator, "INTERNAL", "encoding failed");
        return okEnvelope(allocator, payload);
    }

    // --- models ---
    if (std.mem.eql(u8, target, "/api/models")) {
        if (method != .GET) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
        const payload = services.modelsJson() catch return errorEnvelope(allocator, "INTERNAL", "encoding failed");
        return okEnvelope(allocator, payload);
    }
    if (std.mem.eql(u8, target, "/api/models/refresh")) {
        if (method != .POST) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
        return outcomeResponse(allocator, services.refreshModels());
    }

    // --- sessions ---
    if (std.mem.eql(u8, target, "/api/sessions")) {
        if (method == .GET) {
            const payload = services.sessionsJson() catch return errorEnvelope(allocator, "INTERNAL", "encoding failed");
            return okEnvelope(allocator, payload);
        }
        if (method == .POST) {
            var parsed = parseBody(allocator, body) orelse return errorEnvelope(allocator, "INVALID_JSON", "invalid JSON or missing chat_id");
            defer parsed.deinit();
            const chat_id = parsed.str("chat_id") orelse return errorEnvelope(allocator, "INVALID_JSON", "invalid JSON or missing chat_id");
            return outcomeResponse(allocator, services.createSession(chat_id));
        }
        return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
    }
    if (std.mem.eql(u8, target, "/api/runs")) {
        if (method != .GET) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
        return outcomeResponse(allocator, services.runsJson(50));
    }
    if (std.mem.eql(u8, target, "/api/tools")) {
        if (method != .GET) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
        const payload = services.toolsJson() catch return errorEnvelope(allocator, "INTERNAL", "encoding failed");
        return okEnvelope(allocator, payload);
    }
    if (std.mem.eql(u8, target, "/api/skills")) {
        if (method != .GET) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
        const payload = services.skillsJson() catch return errorEnvelope(allocator, "INTERNAL", "encoding failed");
        return okEnvelope(allocator, payload);
    }
    if (std.mem.eql(u8, target, "/api/memory")) {
        if (method != .GET) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
        const payload = services.memoryJson(null) catch return errorEnvelope(allocator, "INTERNAL", "encoding failed");
        return okEnvelope(allocator, payload);
    }
    if (std.mem.eql(u8, target, "/api/memory/search")) {
        if (method != .POST) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
        var parsed = parseBody(allocator, body) orelse return errorEnvelope(allocator, "INVALID_JSON", "invalid JSON or missing query");
        defer parsed.deinit();
        const query = parsed.str("query") orelse return errorEnvelope(allocator, "INVALID_JSON", "invalid JSON or missing query");
        const filter = memoryTypeFrom(parsed.str("type") orelse "");
        return outcomeResponse(allocator, services.memorySearchJson(query, filter));
    }
    if (std.mem.eql(u8, target, "/api/memory/forget")) {
        if (method != .POST) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
        var parsed = parseBody(allocator, body) orelse return errorEnvelope(allocator, "INVALID_JSON", "invalid JSON or missing id");
        defer parsed.deinit();
        const id = parsed.uint("id") orelse return errorEnvelope(allocator, "INVALID_VALUE", "id is required");
        return outcomeResponse(allocator, services.memoryForgetJson(id));
    }
    if (std.mem.eql(u8, target, "/api/memory/clear")) {
        if (method != .POST) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
        var parsed = parseBody(allocator, body) orelse return errorEnvelope(allocator, "INVALID_JSON", "invalid JSON");
        defer parsed.deinit();
        const filter = memoryTypeFrom(parsed.str("type") orelse "");
        return outcomeResponse(allocator, services.memoryClearJson(filter));
    }
    if (std.mem.eql(u8, target, "/api/gateways")) {
        if (method != .GET) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
        return outcomeResponse(allocator, services.gatewaysJson());
    }
    if (std.mem.eql(u8, target, "/api/config")) {
        if (method != .GET) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
        const payload = services.configJson() catch return errorEnvelope(allocator, "INTERNAL", "encoding failed");
        return okEnvelope(allocator, payload);
    }
    if (std.mem.eql(u8, target, "/api/settings")) {
        if (method == .GET) {
            const payload = services.settingsJson() catch return errorEnvelope(allocator, "INTERNAL", "encoding failed");
            return okEnvelope(allocator, payload);
        }
        if (method == .PUT) {
            var parsed = parseBody(allocator, body) orelse return errorEnvelope(allocator, "INVALID_JSON", "invalid JSON");
            defer parsed.deinit();
            var attempts: ?u8 = null;
            if (parsed.num("task_max_attempts")) |raw| {
                if (!std.math.isFinite(raw) or raw < 1 or raw > 5) return errorEnvelope(allocator, "INVALID_VALUE", "task_max_attempts must be 1-5");
                attempts = @intFromFloat(raw);
            }
            const model = parsed.str("model");
            if (model) |value| {
                if (value.len == 0) return errorEnvelope(allocator, "INVALID_VALUE", "model must not be empty");
            }
            return outcomeResponse(allocator, services.putSettings(model, parsed.boolean("clear_model") orelse false, attempts));
        }
        return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
    }
    if (std.mem.eql(u8, target, "/api/profiles")) {
        if (method == .GET) {
            const payload = services.profilesJson() catch return errorEnvelope(allocator, "INTERNAL", "encoding failed");
            return okEnvelope(allocator, payload);
        }
        if (method == .POST) {
            var parsed = parseBody(allocator, body) orelse return errorEnvelope(allocator, "INVALID_JSON", "invalid JSON or missing id");
            defer parsed.deinit();
            const id = parsed.str("id") orelse return errorEnvelope(allocator, "INVALID_JSON", "invalid JSON or missing id");
            const name = parsed.str("name") orelse "";
            const source = parsed.str("source") orelse "";
            if (source.len > 0) return outcomeResponse(allocator, services.profileDuplicate(source, id, name));
            return outcomeResponse(allocator, services.profileCreate(id, name, parsed.str("description") orelse ""));
        }
        return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
    }

    // --- sub-resource routes ---
    if (std.mem.startsWith(u8, target, "/api/sessions/")) {
        const rest = target["/api/sessions/".len..];
        if (std.mem.endsWith(u8, rest, "/clear")) {
            const chat_id = rest[0 .. rest.len - "/clear".len];
            if (method != .POST) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
            return outcomeResponse(allocator, services.clearSession(chat_id));
        }
        if (std.mem.endsWith(u8, rest, "/send")) {
            const chat_id = rest[0 .. rest.len - "/send".len];
            if (method != .POST) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
            var parsed = parseBody(allocator, body) orelse return errorEnvelope(allocator, "INVALID_JSON", "invalid JSON or missing message");
            defer parsed.deinit();
            const message = parsed.str("message") orelse return errorEnvelope(allocator, "INVALID_JSON", "invalid JSON or missing message");
            return outcomeResponse(allocator, services.sendToSession(chat_id, message));
        }
        if (std.mem.endsWith(u8, rest, "/rename")) {
            const chat_id = rest[0 .. rest.len - "/rename".len];
            if (method != .POST) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
            var parsed = parseBody(allocator, body) orelse return errorEnvelope(allocator, "INVALID_JSON", "invalid JSON or missing chat_id");
            defer parsed.deinit();
            const target_id = parsed.str("chat_id") orelse return errorEnvelope(allocator, "INVALID_JSON", "invalid JSON or missing chat_id");
            return outcomeResponse(allocator, services.renameSession(chat_id, target_id));
        }
        if (method == .GET) {
            const payload = (services.sessionDetailJson(rest) catch return errorEnvelope(allocator, "INTERNAL", "encoding failed")) orelse return errorEnvelope(allocator, "SESSION_NOT_FOUND", "no such session");
            return okEnvelope(allocator, payload);
        }
        if (method == .DELETE) return outcomeResponse(allocator, services.deleteSession(rest));
        return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
    }
    if (std.mem.startsWith(u8, target, "/api/skills/")) {
        return handleActionRoute(allocator, services, method, target, "/api/skills/", struct {
            fn call(s: *Services, id: []const u8, action: []const u8) service_mod.Outcome {
                if (std.mem.eql(u8, action, "enable")) return s.setSkillEnabled(id, true);
                if (std.mem.eql(u8, action, "disable")) return s.setSkillEnabled(id, false);
                return service_mod.Outcome.fail("INVALID_ACTION", "unknown skill action");
            }
        }.call);
    }
    if (std.mem.startsWith(u8, target, "/api/tools/")) {
        return handleActionRoute(allocator, services, method, target, "/api/tools/", struct {
            fn call(s: *Services, id: []const u8, action: []const u8) service_mod.Outcome {
                if (std.mem.eql(u8, action, "enable")) return s.setToolEnabled(id, true);
                if (std.mem.eql(u8, action, "disable")) return s.setToolEnabled(id, false);
                return service_mod.Outcome.fail("INVALID_ACTION", "unknown tool action");
            }
        }.call);
    }
    if (std.mem.startsWith(u8, target, "/api/gateways/")) {
        const rest = target["/api/gateways/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/') == null) {
            if (method != .GET) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
            if (!services.gateways.known(rest)) return errorEnvelope(allocator, "GATEWAY_NOT_FOUND", "no gateway adapter with that name");
            return outcomeResponse(allocator, services.gatewaysJson());
        }
        return handleActionRoute(allocator, services, method, target, "/api/gateways/", struct {
            fn call(s: *Services, id: []const u8, action: []const u8) service_mod.Outcome {
                return s.gatewayAction(id, action);
            }
        }.call);
    }

    // --- MCP (real backend only: the registry lives in the service layer) ---
    if (std.mem.eql(u8, target, "/api/mcp")) {
        if (method != .GET) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
        return outcomeResponse(allocator, services.mcpJson());
    }
    if (std.mem.startsWith(u8, target, "/api/mcp/")) {
        const rest = target["/api/mcp/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |action_start| {
            const id = rest[0..action_start];
            const action = rest[action_start + 1 ..];
            if (id.len == 0 or action.len == 0)
                return errorEnvelope(allocator, "NOT_FOUND", "action required");
            return handleActionRoute(allocator, services, method, target, "/api/mcp/", struct {
                fn call(s: *Services, server_id: []const u8, action_name: []const u8) service_mod.Outcome {
                    return s.mcpAction(server_id, action_name);
                }
            }.call);
        }
        if (method != .GET) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
        return outcomeResponse(allocator, services.mcpServerJson(rest));
    }

    // --- Operations: attachments (uploads live inside the sandbox) ---------
    if (std.mem.startsWith(u8, target, "/api/attachments") and
        (target.len == "/api/attachments".len or target["/api/attachments".len] == '?' or target["/api/attachments".len] == '/'))
    {
        const rest = target["/api/attachments".len..];
        if (rest.len == 0 or rest[0] == '?') {
            if (method == .GET) return outcomeResponse(allocator, services.attachmentsJson());
            if (method != .POST) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
            const name = queryParam(allocator, target, "name") orelse
                return errorEnvelope(allocator, "INVALID_VALUE", "name query parameter is required");
            defer allocator.free(name);
            if (body.len == 0) return errorEnvelope(allocator, "INVALID_VALUE", "upload body is empty");
            return outcomeResponse(allocator, services.attachmentIngest(name, body));
        }
        const id = rest[1..];
        if (std.mem.indexOfScalar(u8, id, '/')) |action_start| {
            const action = id[action_start + 1 ..];
            if (std.mem.eql(u8, action, "extract")) {
                if (method != .POST) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
                return outcomeResponse(allocator, services.attachmentExtractJob(id[0..action_start]));
            }
            return errorEnvelope(allocator, "NOT_FOUND", "unknown attachment action");
        }
        if (method == .GET) return outcomeResponse(allocator, services.attachmentJson(id));
        if (method == .DELETE) return outcomeResponse(allocator, services.attachmentDelete(id));
        return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
    }

    // --- Operations: artifacts ---------------------------------------------
    if (std.mem.eql(u8, target, "/api/artifacts")) {
        if (method == .GET) return outcomeResponse(allocator, services.artifactsJson());
        if (method != .POST) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
        var parsed = parseBody(allocator, body) orelse
            return errorEnvelope(allocator, "INVALID_JSON", "invalid JSON");
        defer parsed.deinit();
        const kind = parsed.str("kind") orelse
            return errorEnvelope(allocator, "INVALID_VALUE", "kind is required");
        const filename = parsed.str("filename") orelse
            return errorEnvelope(allocator, "INVALID_VALUE", "filename is required");
        const content = parsed.str("content") orelse "";
        // Only zip artifacts take sources; other kinds ignore the field.
        // `null` means the field is absent; present-but-invalid maps to an
        // empty list so the service reports a precise INVALID_VALUE.
        const sources: []const []const u8 = parsed.strList("sources", 64) orelse &.{};
        const maybe_sources: ?[]const []const u8 = if (parsed.has("sources")) sources else null;
        return outcomeResponse(allocator, services.artifactCreate(kind, filename, content, maybe_sources));
    }
    if (std.mem.startsWith(u8, target, "/api/artifacts/")) {
        const id = target["/api/artifacts/".len..];
        if (std.mem.endsWith(u8, id, "/content")) {
            if (method != .GET) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
            return artifactDownload(allocator, services, id[0 .. id.len - "/content".len]);
        }
        if (method == .GET) return outcomeResponse(allocator, services.artifactJson(id));
        if (method == .DELETE) return outcomeResponse(allocator, services.artifactDelete(id));
        return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
    }

    // --- Operations: background jobs ---------------------------------------
    if (std.mem.eql(u8, target, "/api/jobs")) {
        if (method == .GET) return outcomeResponse(allocator, services.jobsJson());
        if (method != .POST) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
        var parsed = parseBody(allocator, body) orelse
            return errorEnvelope(allocator, "INVALID_JSON", "invalid JSON");
        defer parsed.deinit();
        const kind = parsed.str("kind") orelse
            return errorEnvelope(allocator, "INVALID_VALUE", "kind is required");
        if (std.mem.eql(u8, kind, "doctor")) {
            return outcomeResponse(allocator, services.doctorJob());
        }
        return errorEnvelope(allocator, "INVALID_VALUE", "unknown job kind (supported: doctor)");
    }
    if (std.mem.startsWith(u8, target, "/api/jobs/")) {
        const rest = target["/api/jobs/".len..];
        if (std.mem.endsWith(u8, rest, "/cancel")) {
            if (method != .POST) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
            return outcomeResponse(allocator, services.jobCancel(rest[0 .. rest.len - "/cancel".len]));
        }
        if (method != .GET) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
        return outcomeResponse(allocator, services.jobJson(rest));
    }

    // --- Operations: run inspector (event-level run history) ----------------
    if (std.mem.eql(u8, target, "/api/events")) {
        if (method != .GET) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
        return outcomeResponse(allocator, services.eventsJson());
    }
    if (std.mem.startsWith(u8, target, "/api/events/")) {
        if (method != .GET) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
        return outcomeResponse(allocator, services.eventJson(target["/api/events/".len..]));
    }

    // --- Operations: doctor --------------------------------------------------
    if (std.mem.eql(u8, target, "/api/doctor")) {
        if (method != .GET) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
        return outcomeResponse(allocator, services.doctorJson());
    }
    if (std.mem.startsWith(u8, target, "/api/profiles/")) {
        const rest = target["/api/profiles/".len..];
        if (std.mem.endsWith(u8, rest, "/activate")) {
            const id = rest[0 .. rest.len - "/activate".len];
            if (method != .POST) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
            return outcomeResponse(allocator, services.profileActivate(id));
        }
        if (method == .GET) {
            const payload = (services.profileDetailJson(rest) catch return errorEnvelope(allocator, "INTERNAL", "encoding failed")) orelse return errorEnvelope(allocator, "PROFILE_NOT_FOUND", "profile not found");
            return okEnvelope(allocator, payload);
        }
        if (method == .PUT) {
            var parsed = parseBody(allocator, body) orelse return errorEnvelope(allocator, "INVALID_JSON", "invalid JSON");
            defer parsed.deinit();
            const file_key = parsed.str("file") orelse return errorEnvelope(allocator, "INVALID_VALUE", "file is required");
            return outcomeResponse(allocator, services.profileUpdateFile(rest, file_key, parsed.str("content") orelse ""));
        }
        if (method == .DELETE) return outcomeResponse(allocator, services.profileDelete(rest));
        return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
    }
    if (std.mem.startsWith(u8, target, "/api/runs/")) {
        const rest = target["/api/runs/".len..];
        if (method != .GET) return errorEnvelope(allocator, "METHOD_NOT_ALLOWED", "method not allowed");
        const id = std.fmt.parseInt(u64, rest, 10) catch return errorEnvelope(allocator, "INVALID_VALUE", "run id must be numeric");
        return outcomeResponse(allocator, services.runDetailJson(id));
    }
    return null;
}

/// `{"agent":…,"version":…,"model":…,"provider":…,"memory":{…},"tasks":{…},
/// "proposals":{…},"channels":{…},"sessions":{"count":n}}` — identifiers and
/// counts only; never a token, key, or provider body.
fn statusResponse(allocator: std.mem.Allocator, dashboard: *const Dashboard) Response {
    const fail = jsonError(.internal_server_error, "internal error");
    const deps = if (dashboard.sessions) |store| &store.deps else null;

    var memories: usize = 0;
    var experiences: usize = 0;
    var strategies: usize = 0;
    var knowledge: usize = 0;
    var task_total: usize = 0;
    var task_completed: usize = 0;
    var task_failed: usize = 0;
    var proposal_total: usize = 0;
    var proposal_proposed: usize = 0;
    var proposal_accepted: usize = 0;
    var proposal_rejected: usize = 0;
    if (deps) |value| {
        memories = value.memory.count();
        experiences = value.experience.count();
        strategies = value.strategies.count();
        knowledge = value.knowledge.count();
        if (value.tasks) |store| {
            task_total = store.count();
            task_completed = store.completedCount();
            task_failed = store.failedCount();
        }
        if (value.proposals) |store| {
            proposal_total = store.count();
            proposal_proposed = store.countStatus(.proposed);
            proposal_accepted = store.countStatus(.accepted);
            proposal_rejected = store.countStatus(.rejected);
        }
    }
    const session_count = if (dashboard.sessions) |store| store.count() else 0;

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;

    writeAll(writer, "{\"agent\":") catch return fail;
    appendJsonString(writer, dashboard.agent_name) catch return fail;
    writeAll(writer, ",\"version\":") catch return fail;
    appendJsonString(writer, dashboard.version) catch return fail;
    writeAll(writer, ",\"model\":") catch return fail;
    appendJsonString(writer, dashboard.model) catch return fail;
    writeAll(writer, ",\"provider\":") catch return fail;
    appendJsonString(writer, dashboard.base_url) catch return fail;
    writer.print(",\"memory\":{{\"memories\":{d},\"experiences\":{d},\"strategies\":{d},\"knowledge\":{d}}}", .{
        memories, experiences, strategies, knowledge,
    }) catch return fail;
    writer.print(",\"tasks\":{{\"total\":{d},\"completed\":{d},\"failed\":{d}}}", .{
        task_total, task_completed, task_failed,
    }) catch return fail;
    writer.print(",\"proposals\":{{\"total\":{d},\"proposed\":{d},\"accepted\":{d},\"rejected\":{d}}}", .{
        proposal_total, proposal_proposed, proposal_accepted, proposal_rejected,
    }) catch return fail;
    writeAll(writer, ",\"channels\":{\"telegram\":") catch return fail;
    appendJsonString(writer, dashboard.telegram_state) catch return fail;
    writer.print("}},\"sessions\":{{\"count\":{d}}}}}", .{session_count}) catch return fail;

    const owned = allocator.dupe(u8, output.written()) catch return fail;
    return .{ .status = .ok, .body = owned, .owned = true };
}

/// `[{"chat_id":"…","messages":n}, …]` from the live session store.
fn sessionsResponse(allocator: std.mem.Allocator, dashboard: *const Dashboard) Response {
    const fail = jsonError(.internal_server_error, "internal error");
    const infos = blk: {
        const store = dashboard.sessions orelse break :blk &[_]session_mod.SessionStore.SessionInfo{};
        break :blk store.list(allocator) catch return fail;
    };
    defer if (infos.len > 0) session_mod.SessionStore.freeList(allocator, infos);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;

    writer.writeByte('[') catch return fail;
    for (infos, 0..) |info, index| {
        if (index > 0) writer.writeByte(',') catch return fail;
        writeAll(writer, "{\"chat_id\":") catch return fail;
        appendJsonString(writer, info.chat_id) catch return fail;
        writer.print(",\"messages\":{d}}}", .{info.message_count}) catch return fail;
    }
    writer.writeByte(']') catch return fail;

    const owned = allocator.dupe(u8, output.written()) catch return fail;
    return .{ .status = .ok, .body = owned, .owned = true };
}

/// `POST {"chat_id":"…"}` clears that session's in-memory context. Chat
/// content is never returned.
fn clearSessionResponse(allocator: std.mem.Allocator, dashboard: *const Dashboard, body: []const u8) Response {
    const ClearRequest = struct { chat_id: []const u8 = "" };
    const parsed = std.json.parseFromSlice(ClearRequest, allocator, body, .{}) catch
        return jsonError(.bad_request, "invalid JSON or missing chat_id");
    defer parsed.deinit();
    if (parsed.value.chat_id.len == 0)
        return jsonError(.bad_request, "chat_id must not be empty");

    const store = dashboard.sessions orelse
        return .{ .status = .ok, .body = "{\"cleared\":false}" };
    if (!store.clearChat(parsed.value.chat_id))
        return .{ .status = .not_found, .body = "{\"error\":\"session not found\"}" };
    return .{ .status = .ok, .body = "{\"cleared\":true}" };
}

fn writeAll(writer: *std.Io.Writer, bytes: []const u8) error{WriteFailed}!void {
    writer.writeAll(bytes) catch return error.WriteFailed;
}

fn appendJsonString(writer: *std.Io.Writer, value: []const u8) error{WriteFailed}!void {
    @import("../provider.zig").Provider.appendJsonString(writer, value) catch return error.WriteFailed;
}

pub fn serve(
    allocator: std.mem.Allocator,
    io: std.Io,
    dashboard: *const Dashboard,
    host: []const u8,
    port: u16,
) !void {
    // Security rule: a non-loopback bind without authentication is refused.
    try validateBind(host, dashboard.auth.token);
    const address = try std.Io.net.IpAddress.parseIp4(host, port);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    std.debug.print("HTTP listening on http://{s}:{d}\n", .{ host, port });
    if (!isLoopbackHost(host)) {
        std.debug.print("WARNING: dashboard bound to a non-loopback address; token authentication is active\n", .{});
    }

    var rate_limiter = RateLimiter{};

    while (true) {
        const stream = try listener.accept(io);
        serveConnection(allocator, io, stream, dashboard, &rate_limiter) catch |err|
            std.debug.print("HTTP connection error: {s}\n", .{@errorName(err)});
    }
}

fn serveConnection(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    dashboard: *const Dashboard,
    rate_limiter: *RateLimiter,
) !void {
    defer stream.close(io);
    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;
    var connection_reader = stream.reader(io, &read_buffer);
    var connection_writer = stream.writer(io, &write_buffer);
    var server: std.http.Server = .init(&connection_reader.interface, &connection_writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };
        // ---- security gates (token auth, CSRF origin, rate limit) ----
        {
            var host_header: ?[]const u8 = null;
            var origin_header: ?[]const u8 = null;
            var bearer: ?[]const u8 = null;
            var pico_token: ?[]const u8 = null;
            var headers = request.iterateHeaders();
            while (headers.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "host")) host_header = header.value;
                if (std.ascii.eqlIgnoreCase(header.name, "origin")) origin_header = header.value;
                if (std.ascii.eqlIgnoreCase(header.name, "x-pico-token")) pico_token = header.value;
                if (std.ascii.eqlIgnoreCase(header.name, "authorization") and
                    std.mem.startsWith(u8, header.value, "Bearer "))
                {
                    bearer = std.mem.trim(u8, header.value["Bearer ".len..], " ");
                }
            }

            var rejected: ?std.http.Status = authGate(
                dashboard.auth,
                request.head.method,
                request.head.target,
                bearer,
                pico_token,
            );
            if (rejected == null and isStateChanging(request.head.method)) {
                if (!originAllowed(origin_header, host_header)) rejected = .forbidden;
            }
            if (rejected == null and isStateChanging(request.head.method)) {
                if (!rate_limiter.allow(task_mod.wallClockMs(io))) rejected = .too_many_requests;
            }
            if (rejected) |status| {
                try request.respond(errorBodyFor(status), .{
                    .status = status,
                    .keep_alive = false,
                    .extra_headers = &.{json_header},
                });
                return;
            }
        }

        // The head (including `target`) borrows the connection reader's
        // buffer, which the body read below refills. Copy the target out
        // first so routing still sees the real path after reading the body.
        const target = allocator.dupe(u8, request.head.target) catch |err| return err;
        defer allocator.free(target);
        const method = request.head.method;

        const oversized_header = (request.head.content_length orelse 0) > bodyLimit(target);
        var transfer_buffer: [8192]u8 = undefined;
        var body: []u8 = &.{};
        var oversized = oversized_header;
        if (!oversized_header and
            (request.head.content_length != null or request.head.transfer_encoding == .chunked))
        {
            const body_reader = request.readerExpectNone(&transfer_buffer);
            body = body_reader.allocRemaining(allocator, .limited(bodyLimit(target))) catch |err| switch (err) {
                error.StreamTooLong => blk: {
                    oversized = true;
                    break :blk &.{};
                },
                else => return err,
            };
        }
        defer if (body.len > 0) allocator.free(body);

        const response = routeDashboard(allocator, dashboard, method, target, body, oversized);
        defer response.deinit(allocator);
        try request.respond(response.body, .{
            .status = response.status,
            .keep_alive = false,
            .extra_headers = response.content_type,
        });
        return;
    }
}

fn jsonError(status: std.http.Status, message: []const u8) Response {
    if (std.mem.eql(u8, message, "method not allowed")) return .{ .status = status, .body = "{\"error\":\"method not allowed\"}" };
    if (std.mem.eql(u8, message, "request body too large")) return .{ .status = status, .body = "{\"error\":\"request body too large\"}" };
    if (std.mem.eql(u8, message, "invalid JSON or missing message")) return .{ .status = status, .body = "{\"error\":\"invalid JSON or missing message\"}" };
    if (std.mem.eql(u8, message, "message must not be empty")) return .{ .status = status, .body = "{\"error\":\"message must not be empty\"}" };
    if (std.mem.eql(u8, message, "invalid JSON or missing chat_id")) return .{ .status = status, .body = "{\"error\":\"invalid JSON or missing chat_id\"}" };
    if (std.mem.eql(u8, message, "chat_id must not be empty")) return .{ .status = status, .body = "{\"error\":\"chat_id must not be empty\"}" };
    if (std.mem.eql(u8, message, "not found")) return .{ .status = status, .body = "{\"error\":\"not found\"}" };
    return .{ .status = status, .body = "{\"error\":\"internal error\"}" };
}

/// `{"response":"…","html":"…"}` — the dashboard renders `html` produced by
/// the same formatter the Telegram channel uses, so formatting logic lives in
/// exactly one place. `html` is empty when formatting fails; clients then
/// fall back to the plain `response` text.
fn encodeChatReply(allocator: std.mem.Allocator, reply: []const u8) error{ OutOfMemory, WriteFailed }![]u8 {
    const html = format.format(allocator, reply) catch null;
    defer if (html) |value| allocator.free(value);

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var stringify: std.json.Stringify = .{ .writer = &output.writer };
    try stringify.beginObject();
    try stringify.objectField("response");
    try stringify.write(reply);
    try stringify.objectField("html");
    if (html) |value| {
        try stringify.write(value);
    } else {
        try stringify.write("");
    }
    try stringify.endObject();
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

const Fake = struct {
    allocator: std.mem.Allocator,
    fail: bool = false,

    fn send(context: *anyopaque, message: []const u8) ![]u8 {
        const self: *Fake = @ptrCast(@alignCast(context));
        if (self.fail) return error.ProviderFailed;
        return self.allocator.dupe(u8, message);
    }

    fn handler(self: *Fake) ChatHandler {
        return .{ .context = self, .sendFn = send };
    }
};

fn expectRoute(method: std.http.Method, target: []const u8, body: []const u8, oversized: bool, status: std.http.Status) !Response {
    var fake = Fake{ .allocator = std.testing.allocator };
    const response = route(std.testing.allocator, fake.handler(), method, target, body, oversized);
    try std.testing.expectEqual(status, response.status);
    return response;
}

/// Dashboard routes with no session store: API endpoints must still answer
/// with zeroed state instead of failing.
fn expectDashboardRoute(method: std.http.Method, target: []const u8, body: []const u8, status: std.http.Status) !Response {
    var fake = Fake{ .allocator = std.testing.allocator };
    var dashboard = Dashboard{
        .handler = fake.handler(),
        .model = "test-model",
        .base_url = "https://example.invalid/v1",
        .telegram_state = "disabled",
    };
    const response = routeDashboard(std.testing.allocator, &dashboard, method, target, body, false);
    try std.testing.expectEqual(status, response.status);
    return response;
}

test "GET dashboard does not expose API keys" {
    const response = try expectRoute(.GET, "/", "", false, .ok);
    defer response.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "Pico Claw") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "PICO_CLAW_API_KEY") == null);
}

test "GET health" {
    const response = try expectRoute(.GET, "/health", "", false, .ok);
    defer response.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "Pico Claw") != null);
}

test "POST chat parses request and escapes response" {
    const response = try expectRoute(.POST, "/chat", "{\"message\":\"say \\\"hi\\\"\"}", false, .ok);
    defer response.deinit(std.testing.allocator);
    // The reply is returned both raw and as formatter-produced HTML.
    try std.testing.expectEqualStrings(
        "{\"response\":\"say \\\"hi\\\"\",\"html\":\"say \\\"hi\\\"\\n\"}",
        response.body,
    );
}

test "POST chat returns formatter html for markdown replies" {
    var fake = Fake{ .allocator = std.testing.allocator };
    var dashboard = Dashboard{ .handler = fake.handler() };
    const response = routeDashboard(
        std.testing.allocator,
        &dashboard,
        .POST,
        "/chat",
        "{\"message\":\"**bold**\"}",
        false,
    );
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, response.status);
    // html shows the rendered bold tag; the raw markdown stars are gone.
    try std.testing.expect(std.mem.indexOf(u8, response.body, "<b>bold</b>") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"html\":") != null);
}

test "GET api status reports counts without secrets" {
    const response = try expectDashboardRoute(.GET, "/api/status", "", .ok);
    defer response.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"model\":\"test-model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"telegram\":\"disabled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"count\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"memories\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "PICO_CLAW_API_KEY") == null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "token") == null);
}

test "GET api sessions is empty without a store" {
    const response = try expectDashboardRoute(.GET, "/api/sessions", "", .ok);
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("[]", response.body);
}

test "POST api sessions clear validates the request" {
    const missing = try expectDashboardRoute(.POST, "/api/sessions/clear", "{}", .bad_request);
    defer missing.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{\"error\":\"chat_id must not be empty\"}", missing.body);

    const malformed = try expectDashboardRoute(.POST, "/api/sessions/clear", "{", .bad_request);
    defer malformed.deinit(std.testing.allocator);

    // Without a store nothing is cleared, but the request is well formed.
    const ok = try expectDashboardRoute(.POST, "/api/sessions/clear", "{\"chat_id\":\"dashboard\"}", .ok);
    defer ok.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{\"cleared\":false}", ok.body);
}

test "dashboard routes keep methods and unknown paths strict" {
    const wrong_method = try expectDashboardRoute(.POST, "/api/status", "", .method_not_allowed);
    defer wrong_method.deinit(std.testing.allocator);

    const unknown = try expectDashboardRoute(.GET, "/api/missing", "", .not_found);
    defer unknown.deinit(std.testing.allocator);
}

test "GET dashboard serves the modern ui without secrets" {
    const response = try expectDashboardRoute(.GET, "/", "", .ok);
    defer response.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "Pico Claw") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "id=\"chat-input\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "/api/status") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "PICO_CLAW_API_KEY") == null);
}

test "chat rejects malformed JSON" {
    const response = try expectRoute(.POST, "/chat", "{", false, .bad_request);
    defer response.deinit(std.testing.allocator);
}

test "chat rejects missing message" {
    const response = try expectRoute(.POST, "/chat", "{}", false, .bad_request);
    defer response.deinit(std.testing.allocator);
}

test "unknown route returns 404" {
    const response = try expectRoute(.GET, "/missing", "", false, .not_found);
    defer response.deinit(std.testing.allocator);
}

test "unsupported method returns 405" {
    const response = try expectRoute(.PUT, "/chat", "", false, .method_not_allowed);
    defer response.deinit(std.testing.allocator);
}

test "oversized request returns 413" {
    const response = try expectRoute(.POST, "/chat", "", true, .payload_too_large);
    defer response.deinit(std.testing.allocator);
}

test "provider error returns generic 500" {
    var fake = Fake{ .allocator = std.testing.allocator, .fail = true };
    const response = route(std.testing.allocator, fake.handler(), .POST, "/chat", "{\"message\":\"hi\"}", false);
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.internal_server_error, response.status);
    try std.testing.expectEqualStrings("{\"error\":\"internal error\"}", response.body);
}

// ---------------------------------------------------------------------------
// Control-plane API tests (envelope + service integration)
// ---------------------------------------------------------------------------

const ApiRig = struct {
    tmp: std.testing.TmpDir,
    env_map: std.process.Environ.Map,
    registry: tool_registry_mod.ToolRegistry,
    calculator: @import("../tools/calculator.zig").Calculator,
    filesystem: @import("../tools/filesystem.zig").Filesystem,
    system_tool: @import("../tools/system.zig").SystemTool,
    provider: provider_mod.Provider,
    memory: memory_mod.Memory,
    experience: experience_store_mod.ExperienceStore,
    strategies: strategy_store_mod.StrategyStore,
    knowledge: knowledge_mod.KnowledgeStore,
    owner_context: owner_mod.OwnerContext,
    tasks: task_store_mod.TaskStore,
    proposals: proposal_store_mod.ProposalStore,
    sessions: session_mod.SessionStore,
    gateways: gateway_mod.GatewayManager,
    models: models_mod.Catalog,
    settings: settings_mod.Settings,
    profiles: profiles_mod.Service,
    mcp: @import("../mcp/registry.zig").Registry,
    sandbox: sandbox_mod.Sandbox,
    attachments: attachments_mod.Store,
    artifacts: artifacts_mod.Store,
    runs_store: runs_store_mod.Store,
    jobs: *jobs_mod.Runtime,
    services: Services,

    fn create() !*ApiRig {
        const allocator = std.testing.allocator;
        const io = std.testing.io;
        const self = try allocator.create(ApiRig);
        errdefer allocator.destroy(self);

        self.* = .{
            .tmp = std.testing.tmpDir(.{}),
            .env_map = undefined,
            .registry = undefined,
            .calculator = .{},
            .filesystem = undefined,
            .system_tool = .{},
            .provider = undefined,
            .memory = undefined,
            .experience = undefined,
            .strategies = undefined,
            .knowledge = undefined,
            .owner_context = undefined,
            .tasks = undefined,
            .proposals = undefined,
            .sessions = undefined,
            .gateways = undefined,
            .models = undefined,
            .settings = undefined,
            .profiles = undefined,
            .mcp = undefined,
            .sandbox = undefined,
            .attachments = undefined,
            .artifacts = undefined,
            .runs_store = undefined,
            .jobs = undefined,
            .services = undefined,
        };
        errdefer self.tmp.cleanup();
        self.env_map = std.process.Environ.Map.init(allocator);
        errdefer self.env_map.deinit();
        self.registry = tool_registry_mod.ToolRegistry.init(allocator);
        errdefer self.registry.deinit();

        self.filesystem = @import("../tools/filesystem.zig").Filesystem.init(io, self.tmp.dir);
        try self.registry.register(self.calculator.tool());
        try self.registry.register(self.filesystem.tool());
        try self.registry.register(self.system_tool.tool());

        self.memory = try memory_mod.Memory.init(allocator, io);
        errdefer self.memory.deinit();
        self.experience = experience_store_mod.ExperienceStore.init(allocator, io);
        errdefer self.experience.deinit();
        self.strategies = strategy_store_mod.StrategyStore.init(allocator, io);
        errdefer self.strategies.deinit();
        self.knowledge = knowledge_mod.KnowledgeStore.init(allocator, io);
        errdefer self.knowledge.deinit();
        self.owner_context = try owner_mod.OwnerContext.initAt(allocator, io, self.tmp.dir, "SOUL.md", "MEMORY.md", .{});
        errdefer self.owner_context.deinit();
        self.tasks = task_store_mod.TaskStore.initAt(allocator, io, self.tmp.dir, "data/tasks", "data/tasks/journal.jsonl");
        errdefer self.tasks.deinit();
        self.proposals = proposal_store_mod.ProposalStore.init(allocator, io);
        errdefer self.proposals.deinit();

        self.provider = provider_mod.Provider.init(allocator, io, &self.env_map, .{
            .agent_name = "Pico Claw",
            .model = "test-model",
            .base_url = "http://127.0.0.1:1/v1",
            .system_prompt = "TEST POLICY",
            .temperature = 0.7,
            .max_tokens = 64,
            .soul_path = "SOUL.md",
            .memory_path = "MEMORY.md",
            .soul_budget_bytes = 1024,
            .memory_budget_bytes = 1024,
            .owner_budget_bytes = 2048,
        });
        errdefer {
            self.provider = undefined;
        }

        self.gateways = gateway_mod.GatewayManager.init(allocator, io, &self.env_map, false);
        errdefer self.gateways.deinit();
        self.models = models_mod.Catalog.init(allocator, io, &self.provider);
        errdefer self.models.deinit();
        self.settings = settings_mod.Settings.init(allocator);
        errdefer self.settings.deinit();
        self.profiles = profiles_mod.Service.init(allocator, io, self.tmp.dir, "profiles", &self.owner_context);
        errdefer self.profiles.deinit();
        self.mcp = @import("../mcp/registry.zig").Registry.init(allocator, io);
        errdefer self.mcp.deinit();
        self.sandbox = try sandbox_mod.Sandbox.init(io, allocator, self.tmp.dir, "workspace", .{
            .read = true,
            .write = true,
        }, .{});
        errdefer self.sandbox.deinit();
        self.attachments = attachments_mod.Store.init(allocator, &self.sandbox);
        errdefer self.attachments.deinit();
        self.artifacts = artifacts_mod.Store.init(allocator, &self.sandbox);
        errdefer self.artifacts.deinit();
        self.runs_store = runs_store_mod.Store.init(allocator, io);
        errdefer self.runs_store.deinit();
        self.jobs = try jobs_mod.Runtime.init(allocator, io, 5_000);
        errdefer self.jobs.deinit();
        self.jobs.attachRuns(&self.runs_store);

        self.sessions = session_mod.SessionStore.init(allocator, io, .{
            .provider = &self.provider,
            .tools = &self.registry,
            .memory = &self.memory,
            .experience = &self.experience,
            .strategies = &self.strategies,
            .knowledge = &self.knowledge,
            .owner = &self.owner_context,
            .tasks = &self.tasks,
            .proposals = &self.proposals,
            .retry = .{},
            .system_prompt = "TEST POLICY",
            .routing = .{},
            .teacher = null,
        });
        errdefer self.sessions.deinit();

        self.services = Services{
            .allocator = allocator,
            .io = io,
            .env_map = &self.env_map,
            .config = undefined,
            .provider = &self.provider,
            .sessions = &self.sessions,
            .tools = &self.registry,
            .memory = &self.memory,
            .tasks = &self.tasks,
            .proposals = &self.proposals,
            .owner_context = &self.owner_context,
            .gateways = &self.gateways,
            .models = &self.models,
            .settings = &self.settings,
            .profiles = &self.profiles,
            .mcp = &self.mcp,
            .sandbox = &self.sandbox,
            .attachments = &self.attachments,
            .artifacts = &self.artifacts,
            .jobs = self.jobs,
            .runs = &self.runs_store,
            .persist_settings = false,
        };
        self.services.config = &rig_config;
        errdefer self.services.deinit();
        self.services.init();
        return self;
    }

    fn destroy(self: *ApiRig) void {
        const allocator = std.testing.allocator;
        self.services.deinit();
        // Job worker stops first: it references the stores below.
        self.jobs.deinit();
        self.sessions.deinit();
        self.profiles.deinit();
        self.settings.deinit();
        self.models.deinit();
        self.gateways.deinit();
        self.proposals.deinit();
        self.tasks.deinit();
        self.owner_context.deinit();
        self.knowledge.deinit();
        self.strategies.deinit();
        self.experience.deinit();
        self.memory.deinit();
        self.runs_store.deinit();
        self.artifacts.deinit();
        self.attachments.deinit();
        self.sandbox.deinit();
        // MCP teardown must happen while the shared tool registry is alive
        // (it disables its tools there), and before the registry itself.
        self.mcp.deinit();
        self.registry.deinit();
        self.env_map.deinit();
        self.tmp.cleanup();
        allocator.destroy(self);
    }

    fn dashboard(self: *ApiRig) Dashboard {
        _ = self;
        return .{};
    }
};

var rig_config = @import("../config.zig").Config{
    .agent_name = "Pico Claw",
    .model = "test-model",
    .base_url = "http://127.0.0.1:1/v1",
    .system_prompt = "TEST POLICY",
    .temperature = 0.7,
    .max_tokens = 64,
    .soul_path = "SOUL.md",
    .memory_path = "MEMORY.md",
    .soul_budget_bytes = 1024,
    .memory_budget_bytes = 1024,
    .owner_budget_bytes = 2048,
};

fn apiGet(rig: *ApiRig, target: []const u8) !Response {
    return routeDashboard(std.testing.allocator, &.{
        .handler = undefined,
        .services = &rig.services,
    }, .GET, target, "", false);
}

fn apiSend(rig: *ApiRig, method: std.http.Method, target: []const u8, body: []const u8) !Response {
    return routeDashboard(std.testing.allocator, &.{
        .handler = undefined,
        .services = &rig.services,
    }, method, target, body, false);
}

test "api status uses the envelope and reports service data without secrets" {
    var rig = try ApiRig.create();
    defer rig.destroy();
    const response = try apiGet(rig, "/api/status");
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expect(std.mem.startsWith(u8, response.body, "{\"ok\":true,\"data\":"));
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"metrics\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "PICO_CLAW_API_KEY") == null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "token") == null);
}

test "api sandbox reports the live sandbox policy without secrets" {
    var rig = try ApiRig.create();
    defer rig.destroy();
    const response = try apiGet(rig, "/api/sandbox");
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expect(std.mem.startsWith(u8, response.body, "{\"ok\":true,\"data\":"));
    // The rig attaches a real sandbox on a temporary workspace.
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"enabled\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"limits\":") != null);
}

test "api capabilities reflects runtime state" {
    var rig = try ApiRig.create();
    defer rig.destroy();
    const response = try apiGet(rig, "/api/capabilities");
    defer response.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"channels\":{\"cli\":true") != null);
    // Telegram channel is not running in this process: reported disabled.
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"telegram\":false") != null);
    // Enabled tools appear in the manifest.
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"name\":\"calculator\",\"enabled\":true") != null);
}

// --- Operations API contract tests ----------------------------------------

fn testing_expectSubstring(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("substring not found: {s}\nbody: {s}\n", .{ needle, haystack[0..@min(haystack.len, 400)] });
        return error.TestUnexpectedResult;
    }
}

test "api attachments ingest, inspect, and delete real files" {
    var rig = try ApiRig.create();
    defer rig.destroy();

    // Uploads require a name; missing name is a client error.
    const no_name = try apiSend(rig, .POST, "/api/attachments", "data");
    defer no_name.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.bad_request, no_name.status);
    try testing_expectSubstring(no_name.body, "INVALID_VALUE");

    // A real upload: stored inside the sandbox with a derived hash.
    const uploaded = try apiSend(rig, .POST, "/api/attachments?name=notes.txt", "attachment body");
    defer uploaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, uploaded.status);
    try testing_expectSubstring(uploaded.body, "\"mime\":\"text/plain\"");

    // List shows it; detail finds it by id.
    const list = try apiGet(rig, "/api/attachments");
    defer list.deinit(std.testing.allocator);
    try testing_expectSubstring(list.body, "\"count\":1");

    // Traversal-style and reserved names are refused outright.
    const evil = try apiSend(rig, .POST, "/api/attachments?name=..%2Fescape.txt", "x");
    defer evil.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.bad_request, evil.status);
    try testing_expectSubstring(evil.body, "INVALID_NAME");
    const con = try apiSend(rig, .POST, "/api/attachments?name=CON", "x");
    defer con.deinit(std.testing.allocator);
    try testing_expectSubstring(con.body, "INVALID_NAME");

    // Delete removes the record and the directory.
    const id_start = std.mem.indexOf(u8, uploaded.body, "\"id\":\"att-").? + "\"id\":\"".len;
    const id_end = std.mem.indexOfScalarPos(u8, uploaded.body, id_start, '"').?;
    const id = try std.testing.allocator.dupe(u8, uploaded.body[id_start..id_end]);
    defer std.testing.allocator.free(id);
    var target: [72]u8 = undefined;
    const deleted = try apiSend(rig, .DELETE, std.fmt.bufPrint(&target, "/api/attachments/{s}", .{id}) catch unreachable, "");
    defer deleted.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, deleted.status);
    const ghost = try apiGet(rig, std.fmt.bufPrint(&target, "/api/attachments/{s}", .{id}) catch unreachable);
    defer ghost.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.not_found, ghost.status);
}

test "api artifacts create validated text and refuse unsupported formats" {
    var rig = try ApiRig.create();
    defer rig.destroy();

    const created = try apiSend(
        rig,
        .POST,
        "/api/artifacts",
        "{\"kind\":\"json\",\"filename\":\"data.json\",\"content\":\"{\\\"ok\\\":true}\"}",
    );
    defer created.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, created.status);
    try testing_expectSubstring(created.body, "\"kind\":\"json\"");
    try testing_expectSubstring(created.body, "\"validated\":true");

    // Invalid JSON content never becomes an artifact.
    const invalid = try apiSend(
        rig,
        .POST,
        "/api/artifacts",
        "{\"kind\":\"json\",\"filename\":\"bad.json\",\"content\":\"{broken\"}",
    );
    defer invalid.deinit(std.testing.allocator);
    try testing_expectSubstring(invalid.body, "INVALID_CONTENT");

    // PDF has no backend here: UNSUPPORTED, no fake file.
    const pdf = try apiSend(
        rig,
        .POST,
        "/api/artifacts",
        "{\"kind\":\"pdf\",\"filename\":\"r.pdf\",\"content\":\"%PDF-fake\"}",
    );
    defer pdf.deinit(std.testing.allocator);
    try testing_expectSubstring(pdf.body, "UNSUPPORTED_KIND");

    // Download round-trips the exact bytes.
    const id_start = std.mem.indexOf(u8, created.body, "\"id\":\"art-").? + "\"id\":\"".len;
    const id_end = std.mem.indexOfScalarPos(u8, created.body, id_start, '"').?;
    const id = try std.testing.allocator.dupe(u8, created.body[id_start..id_end]);
    defer std.testing.allocator.free(id);
    var target: [80]u8 = undefined;
    const download = try apiGet(rig, std.fmt.bufPrint(&target, "/api/artifacts/{s}/content", .{id}) catch unreachable);
    defer download.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, download.status);
    try std.testing.expectEqualStrings("{\"ok\":true}", download.body);
}

test "api artifacts create a real zip from workspace sources end to end" {
    var rig = try ApiRig.create();
    defer rig.destroy();

    // Seed real workspace files through the sandbox filesystem operations.
    var fsops = fsops_mod.FsOps.init(&rig.sandbox);
    _ = try fsops.write("bundle/a.txt", "alpha");
    _ = try fsops.write("bundle/b.md", "# beta");

    const created = try apiSend(
        rig,
        .POST,
        "/api/artifacts",
        "{\"kind\":\"zip\",\"filename\":\"bundle.zip\",\"sources\":[\"bundle/a.txt\",\"bundle/b.md\"]}",
    );
    defer created.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, created.status);
    try testing_expectSubstring(created.body, "\"kind\":\"zip\"");
    try testing_expectSubstring(created.body, "\"validated\":true");

    // Download the artifact and verify it is a real ZIP archive.
    const id_start = std.mem.indexOf(u8, created.body, "\"id\":\"art-").? + "\"id\":\"".len;
    const id_end = std.mem.indexOfScalarPos(u8, created.body, id_start, '"').?;
    const id = try std.testing.allocator.dupe(u8, created.body[id_start..id_end]);
    defer std.testing.allocator.free(id);
    var target: [80]u8 = undefined;
    const download = try apiGet(rig, std.fmt.bufPrint(&target, "/api/artifacts/{s}/content", .{id}) catch unreachable);
    defer download.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, download.status);
    try std.testing.expect(std.mem.startsWith(u8, download.body, "PK\x03\x04"));

    // The stored archive lists exactly the seeded sources.
    const record = rig.services.artifacts.?.find(id).?;
    var archives = archives_mod.Archives.init(&rig.sandbox);
    const listing = try archives.zipListJson(std.testing.allocator, record.path);
    defer std.testing.allocator.free(listing);
    try testing_expectSubstring(listing, "bundle/a.txt");
    try testing_expectSubstring(listing, "bundle/b.md");

    // Zip without sources is a client error, not a silent fake artifact.
    const missing_sources = try apiSend(rig, .POST, "/api/artifacts", "{\"kind\":\"zip\",\"filename\":\"x.zip\"}");
    defer missing_sources.deinit(std.testing.allocator);
    try testing_expectSubstring(missing_sources.body, "INVALID_VALUE");

    // A source that does not exist in the workspace fails honestly.
    const missing_file = try apiSend(
        rig,
        .POST,
        "/api/artifacts",
        "{\"kind\":\"zip\",\"filename\":\"y.zip\",\"sources\":[\"bundle/ghost.txt\"]}",
    );
    defer missing_file.deinit(std.testing.allocator);
    try testing_expectSubstring(missing_file.body, "ARTIFACT_FAILED");
}

test "api jobs run doctor asynchronously and the run inspector records it" {
    var rig = try ApiRig.create();
    defer rig.destroy();

    const queued = try apiSend(rig, .POST, "/api/jobs", "{\"kind\":\"doctor\"}");
    defer queued.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, queued.status);
    const id_start = std.mem.indexOf(u8, queued.body, "\"id\":\"job-").? + "\"id\":\"".len;
    const id_end = std.mem.indexOfScalarPos(u8, queued.body, id_start, '"').?;
    const id = try std.testing.allocator.dupe(u8, queued.body[id_start..id_end]);
    defer std.testing.allocator.free(id);

    // Poll until the doctor job completes (worker thread; real checks).
    var completed = false;
    var target: [64]u8 = undefined;
    for (0..200) |_| {
        const detail = try apiGet(rig, std.fmt.bufPrint(&target, "/api/jobs/{s}", .{id}) catch unreachable);
        defer detail.deinit(std.testing.allocator);
        if (std.mem.indexOf(u8, detail.body, "\"state\":\"completed\"") != null) {
            completed = true;
            try testing_expectSubstring(detail.body, "overall");
            break;
        }
        std.testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(completed);

    // The job run is linked in the inspector: summary lists it, detail has
    // the job_start/job_result events.
    const events = try apiGet(rig, "/api/events");
    defer events.deinit(std.testing.allocator);
    try testing_expectSubstring(events.body, "\"profile\":\"doctor\"");
    const run_detail = try apiGet(rig, "/api/events/run-1");
    defer run_detail.deinit(std.testing.allocator);
    try testing_expectSubstring(run_detail.body, "\"kind\":\"job_start\"");
    try testing_expectSubstring(run_detail.body, "\"kind\":\"job_result\"");

    // Unknown ids / unknown kinds / finished jobs behave honestly.
    const ghost = try apiGet(rig, "/api/jobs/job-999");
    defer ghost.deinit(std.testing.allocator);
    try testing_expectSubstring(ghost.body, "JOB_NOT_FOUND");
    const bad_kind = try apiSend(rig, .POST, "/api/jobs", "{\"kind\":\"rm -rf\"}");
    defer bad_kind.deinit(std.testing.allocator);
    try testing_expectSubstring(bad_kind.body, "INVALID_VALUE");
    var cancel_target: [80]u8 = undefined;
    const cancelled = try apiSend(rig, .POST, std.fmt.bufPrint(&cancel_target, "/api/jobs/{s}/cancel", .{id}) catch unreachable, "");
    defer cancelled.deinit(std.testing.allocator);
    try testing_expectSubstring(cancelled.body, "JOB_NOT_CANCELLABLE");
}

test "api doctor returns real checks with pass and unavailable states" {
    var rig = try ApiRig.create();
    defer rig.destroy();

    const report = try apiGet(rig, "/api/doctor");
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, report.status);
    try testing_expectSubstring(report.body, "\"name\":\"binary\",\"status\":\"pass\"");
    try testing_expectSubstring(report.body, "\"name\":\"configuration\",\"status\":\"pass\"");
    try testing_expectSubstring(report.body, "\"name\":\"sandbox\",\"status\":\"pass\"");
    try testing_expectSubstring(report.body, "\"name\":\"provider\",\"status\":\"unavailable\"");
    try testing_expectSubstring(report.body, "\"overall\":\"");
    // The doctor probe file must be cleaned up after the run.
    try std.testing.expectError(error.FileNotFound, rig.sandbox.root.statFile(
        std.testing.io,
        "doctor-probe.txt",
        .{},
    ));
}

fn mcpTestConfig(id: []const u8, extra: []const u8) ![]u8 {
    const path = std.process.Environ.getAlloc(
        std.testing.environ,
        std.testing.allocator,
        "PICO_MCP_TEST_SERVER",
    ) catch return error.SkipZigTest;
    defer std.testing.allocator.free(path);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer out.deinit();
    try out.writer.print(
        "{{\"enabled\":true,\"servers\":[{{\"id\":\"{s}\",\"command\":",
        .{id},
    );
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try stringify.write(path);
    if (extra.len > 0) {
        try out.writer.writeByte(',');
        try out.writer.writeAll(extra);
    }
    try out.writer.writeAll(",\"enabled\":true}]}\n");
    return out.toOwnedSlice();
}

test "api mcp reports the live registry and refuses unknown ids" {
    var rig = try ApiRig.create();
    defer rig.destroy();

    // No MCP config loaded: the inventory is empty but real.
    const list = try apiGet(rig, "/api/mcp");
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, list.status);
    try std.testing.expect(std.mem.indexOf(u8, list.body, "\"enabled\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, list.body, "\"servers\":[]") != null);

    const missing = try apiGet(rig, "/api/mcp/ghost");
    defer missing.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.not_found, missing.status);
    try std.testing.expect(std.mem.indexOf(u8, missing.body, "MCP_SERVER_NOT_FOUND") != null);

    const bad_action = try apiSend(rig, .POST, "/api/mcp/ghost/start", "");
    defer bad_action.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.not_found, bad_action.status);
    try std.testing.expect(std.mem.indexOf(u8, bad_action.body, "MCP_SERVER_NOT_FOUND") != null);

    const wrong_method = try apiSend(rig, .POST, "/api/mcp", "");
    defer wrong_method.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.method_not_allowed, wrong_method.status);
    try std.testing.expect(std.mem.indexOf(u8, wrong_method.body, "METHOD_NOT_ALLOWED") != null);
}

test "api mcp start, inspect, and stop a real stdio server" {
    var rig = try ApiRig.create();
    defer rig.destroy();

    const config_json = try mcpTestConfig("demo", "\"env\":{\"PICO_API_CANARY\":\"CANARY-SECRET-VALUE\"}");
    defer std.testing.allocator.free(config_json);
    try rig.mcp.loadConfig(config_json);
    rig.mcp.attachToolRegistry(&rig.registry);

    const started = try apiSend(rig, .POST, "/api/mcp/demo/start", "");
    defer started.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, started.status);
    try std.testing.expect(std.mem.indexOf(u8, started.body, "\"state\":\"running\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, started.body, "\"transport\":\"stdio\"") != null);
    // Environment names are visible; values never are.
    try std.testing.expect(std.mem.indexOf(u8, started.body, "PICO_API_CANARY") != null);
    try std.testing.expect(std.mem.indexOf(u8, started.body, "CANARY-SECRET-VALUE") == null);

    // Discovered tools are in the shared manifest, namespaced, disabled-capable.
    const detail = try apiGet(rig, "/api/mcp/demo");
    defer detail.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, detail.status);
    try std.testing.expect(std.mem.indexOf(u8, detail.body, "\"name\":\"mcp.demo.echo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail.body, "\"permission\":\"elevated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail.body, "\"risk\":\"high\"") != null);

    const stopped = try apiSend(rig, .POST, "/api/mcp/demo/stop", "");
    defer stopped.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, stopped.status);
    try std.testing.expect(std.mem.indexOf(u8, stopped.body, "\"state\":\"stopped\"") != null);

    // Double stop is an error, never a fake success.
    const again = try apiSend(rig, .POST, "/api/mcp/demo/stop", "");
    defer again.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, again.body, "MCP_NOT_RUNNING") != null);
}

test "api mcp enable/disable actions work through the control plane" {
    var rig = try ApiRig.create();
    defer rig.destroy();

    const config_json = try mcpTestConfig("ctrl", "");
    defer std.testing.allocator.free(config_json);
    try rig.mcp.loadConfig(config_json);

    const disabled = try apiSend(rig, .POST, "/api/mcp/ctrl/disable", "");
    defer disabled.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, disabled.body, "\"state\":\"disabled\"") != null);

    const enabled = try apiSend(rig, .POST, "/api/mcp/ctrl/enable", "");
    defer enabled.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, enabled.body, "\"state\":\"configured\"") != null);

    // Unknown action names are refused by the dispatcher.
    const unknown = try apiSend(rig, .POST, "/api/mcp/ctrl/dance", "");
    defer unknown.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, unknown.body, "INVALID_ACTION") != null);
}

test "api models lists the empty cache and never leaks the key" {
    var rig = try ApiRig.create();
    defer rig.destroy();
    const response = try apiGet(rig, "/api/models");
    defer response.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"count\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"active_model\":\"test-model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "PICO_CLAW_API_KEY") == null);

    // Refresh without a key fails with a mapped provider error.
    const refresh = try apiSend(rig, .POST, "/api/models/refresh", "");
    defer refresh.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.service_unavailable, refresh.status);
    try std.testing.expect(std.mem.indexOf(u8, refresh.body, "PROVIDER_UNAVAILABLE") != null);
}

test "api tools manifest and enable-disable cycle" {
    var rig = try ApiRig.create();
    defer rig.destroy();
    const list = try apiGet(rig, "/api/tools");
    defer list.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, list.body, "\"name\":\"calculator\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list.body, "\"permission\":\"standard\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list.body, "\"permission\":\"elevated\"") != null);

    const disable = try apiSend(rig, .POST, "/api/tools/calculator/disable", "");
    defer disable.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, disable.body, "\"enabled\":false") != null);
    try std.testing.expectEqual(@as(?bool, false), rig.registry.isEnabled("calculator"));

    const enable = try apiSend(rig, .POST, "/api/tools/calculator/enable", "");
    defer enable.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, enable.body, "\"enabled\":true") != null);

    const missing = try apiSend(rig, .POST, "/api/tools/ghost/disable", "");
    defer missing.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.not_found, missing.status);
}

test "api skills list and toggle" {
    var rig = try ApiRig.create();
    defer rig.destroy();
    const list = try apiGet(rig, "/api/skills");
    defer list.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, list.body, "\"id\":\"arithmetic\"") != null);

    const off = try apiSend(rig, .POST, "/api/skills/arithmetic/disable", "");
    defer off.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, off.body, "\"enabled\":false") != null);

    const on = try apiSend(rig, .POST, "/api/skills/arithmetic/enable", "");
    defer on.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, on.body, "\"enabled\":true") != null);
}

test "api session lifecycle create detail rename clear delete" {
    var rig = try ApiRig.create();
    defer rig.destroy();

    const invalid = try apiSend(rig, .POST, "/api/sessions", "{\"chat_id\":\"../bad\"}");
    defer invalid.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.bad_request, invalid.status);

    const created = try apiSend(rig, .POST, "/api/sessions", "{\"chat_id\":\"dash-2\"}");
    defer created.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, created.status);
    try std.testing.expect(std.mem.indexOf(u8, created.body, "\"chat_id\":\"dash-2\"") != null);

    const detail = try apiGet(rig, "/api/sessions/dash-2");
    defer detail.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, detail.body, "\"count\":0") != null);

    const renamed = try apiSend(rig, .POST, "/api/sessions/dash-2/rename", "{\"chat_id\":\"research\"}");
    defer renamed.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, renamed.body, "\"research\"") != null);

    const cleared = try apiSend(rig, .POST, "/api/sessions/research/clear", "");
    defer cleared.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, cleared.status);

    const removed = try apiSend(rig, .DELETE, "/api/sessions/research", "");
    defer removed.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, removed.status);

    const gone = try apiGet(rig, "/api/sessions/research");
    defer gone.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.not_found, gone.status);
}

test "api memory search forget and clear validation" {
    var rig = try ApiRig.create();
    defer rig.destroy();

    _ = try rig.memory.rememberSemantic("The workspace root holds SOUL.md");

    const list = try apiGet(rig, "/api/memory");
    defer list.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, list.body, "SOUL.md") != null);

    const search = try apiSend(rig, .POST, "/api/memory/search", "{\"query\":\"SOUL\"}");
    defer search.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, search.body, "\"matches\":") != null);

    const empty_query = try apiSend(rig, .POST, "/api/memory/search", "{\"query\":\" \"}");
    defer empty_query.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.bad_request, empty_query.status);

    const miss = try apiSend(rig, .POST, "/api/memory/forget", "{\"id\":9999}");
    defer miss.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.not_found, miss.status);
}

test "api gateways report planned transports and honest lifecycle" {
    var rig = try ApiRig.create();
    defer rig.destroy();

    const list = try apiGet(rig, "/api/gateways");
    defer list.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, list.body, "\"name\":\"telegram\",\"adapter\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, list.body, "\"name\":\"whatsapp\",\"adapter\":false,\"planned\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, list.body, "\"configured\":false") != null);

    // start without a token is a configuration failure.
    const start = try apiSend(rig, .POST, "/api/gateways/telegram/start", "");
    defer start.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.service_unavailable, start.status);
    try std.testing.expect(std.mem.indexOf(u8, start.body, "GATEWAY_NOT_CONFIGURED") != null);

    // With a token and explicit enable, start is still refused here — and
    // says so honestly — because this process cannot host the channel loop.
    rig.gateways.token = try std.testing.allocator.dupe(u8, "test-token");
    try rig.gateways.enable();
    const start_configured = try apiSend(rig, .POST, "/api/gateways/telegram/start", "");
    defer start_configured.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.not_implemented, start_configured.status);
    try std.testing.expect(std.mem.indexOf(u8, start_configured.body, "GATEWAY_LIFECYCLE_UNSUPPORTED") != null);
    // The state was not faked: still stopped after the refused start.
    const after = try apiGet(rig, "/api/gateways");
    defer after.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, after.body, "\"state\":\"stopped\"") != null);

    // test connection with an injected successful probe caches only the
    // safe bot identity (no network access in tests).
    rig.gateways.probe = struct {
        fn fake(allocator: std.mem.Allocator, _: std.Io, _: []const u8) anyerror!gateway_mod.BotIdentity {
            return .{
                .id = 7,
                .username = try allocator.dupe(u8, "pico_bot"),
                .first_name = try allocator.dupe(u8, "Pico"),
            };
        }
    }.fake;
    const probe = try apiSend(rig, .POST, "/api/gateways/telegram/test", "");
    defer probe.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, probe.status);
    try std.testing.expect(std.mem.indexOf(u8, probe.body, "\"username\":\"pico_bot\"") != null);
    // Token values never appear anywhere.
    try std.testing.expect(std.mem.indexOf(u8, list.body, "TELEGRAM_BOT_TOKEN") == null);

    // Unknown transport never becomes available.
    const unknown = try apiSend(rig, .POST, "/api/gateways/whatsapp/start", "");
    defer unknown.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.not_found, unknown.status);
}

test "api runs list and unknown run" {
    var rig = try ApiRig.create();
    defer rig.destroy();
    const list = try apiGet(rig, "/api/runs");
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{\"ok\":true,\"data\":[]}", list.body);

    const missing = try apiGet(rig, "/api/runs/999");
    defer missing.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.not_found, missing.status);
}

test "api settings get put and validation" {
    var rig = try ApiRig.create();
    defer rig.destroy();
    const initial = try apiGet(rig, "/api/settings");
    defer initial.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, initial.body, "\"model_source\":\"config\"") != null);

    const invalid = try apiSend(rig, .PUT, "/api/settings", "{\"model\":\"bad model\"}");
    defer invalid.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.bad_request, invalid.status);

    const valid = try apiSend(rig, .PUT, "/api/settings", "{\"task_max_attempts\":3}");
    defer valid.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, valid.body, "\"task_max_attempts\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, valid.body, "\"task_max_attempts_source\":\"settings\"") != null);
}

test "api config view is schema-shaped and secret-free" {
    var rig = try ApiRig.create();
    defer rig.destroy();
    const response = try apiGet(rig, "/api/config");
    defer response.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"provider\":{\"endpoint\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"api_key_set\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"token_set\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "PICO_CLAW_API_KEY") == null);
}

test "api profiles lifecycle with containment" {
    var rig = try ApiRig.create();
    defer rig.destroy();

    const empty = try apiGet(rig, "/api/profiles");
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{\"ok\":true,\"data\":[]}", empty.body);

    const create = try apiSend(rig, .POST, "/api/profiles", "{\"id\":\"work\",\"name\":\"Work\",\"description\":\"Day job\"}");
    defer create.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, create.body, "\"id\":\"work\"") != null);

    const bad_id = try apiSend(rig, .POST, "/api/profiles", "{\"id\":\"../x\",\"name\":\"x\"}");
    defer bad_id.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.bad_request, bad_id.status);

    const update = try apiSend(rig, .PUT, "/api/profiles/work", "{\"file\":\"soul.md\",\"content\":\"# Work soul\"}");
    defer update.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, update.body, "# Work soul") != null);

    const bad_file = try apiSend(rig, .PUT, "/api/profiles/work", "{\"file\":\"../evil.md\",\"content\":\"x\"}");
    defer bad_file.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.bad_request, bad_file.status);

    const activate = try apiSend(rig, .POST, "/api/profiles/work/activate", "");
    defer activate.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, activate.body, "\"active\":true") != null);

    // Activation rewrote the workspace SOUL.md through the owner context.
    const soul = try rig.owner_context.renderSoul(std.testing.allocator);
    defer if (soul) |value| std.testing.allocator.free(value);
    try std.testing.expect(soul != null);
    try std.testing.expect(std.mem.indexOf(u8, soul.?, "Work soul") != null);

    const delete_active = try apiSend(rig, .DELETE, "/api/profiles/work", "");
    defer delete_active.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.conflict, delete_active.status);

    // Detail view exposes every file section.
    const detail = try apiGet(rig, "/api/profiles/work");
    defer detail.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, detail.body, "\"soul.md\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail.body, "\"custom.md\":") != null);
}

test "security primitives behave correctly" {
    try std.testing.expect(isLoopbackHost("127.0.0.1"));
    try std.testing.expect(isLoopbackHost("localhost"));
    try std.testing.expect(!isLoopbackHost("0.0.0.0"));

    try std.testing.expect(tokenMatches("secret", "secret"));
    try std.testing.expect(!tokenMatches("secret", "secretx"));
    try std.testing.expect(!tokenMatches("", "secret"));

    // Browser-style cross-origin POST is rejected; same-origin passes;
    // non-browser requests without Origin pass.
    try std.testing.expect(originAllowed(null, "127.0.0.1:8080"));
    try std.testing.expect(!originAllowed("http://evil.example", "127.0.0.1:8080"));
    try std.testing.expect(originAllowed("http://127.0.0.1:8080", "127.0.0.1:8080"));
    // An Origin without a usable Host is rejected (stricter, safe default).
    try std.testing.expect(!originAllowed("http://evil.example", null));

    var limiter = RateLimiter{ .limit = 2 };
    try std.testing.expect(limiter.allow(1000));
    try std.testing.expect(limiter.allow(1001));
    try std.testing.expect(!limiter.allow(1002));
    try std.testing.expect(limiter.allow(1000 + RateLimiter.window_ms));
}

test "auth gate: dashboard shell loads without token, API stays protected" {
    const auth = Auth{ .token = "secret" };

    // The dashboard shell is served without a token so the login UI can load.
    try std.testing.expectEqual(@as(?std.http.Status, null), authGate(auth, .GET, "/", null, null));
    try std.testing.expectEqual(@as(?std.http.Status, null), authGate(auth, .GET, "/?next=%2Fchat", null, null));
    try std.testing.expectEqual(@as(?std.http.Status, null), authGate(auth, .HEAD, "/", null, null));

    // Unauthenticated API/control-plane requests are rejected with 401.
    try std.testing.expectEqual(@as(?std.http.Status, .unauthorized), authGate(auth, .GET, "/api/status", null, null));
    try std.testing.expectEqual(@as(?std.http.Status, .unauthorized), authGate(auth, .GET, "/api/sessions", null, null));
    try std.testing.expectEqual(@as(?std.http.Status, .unauthorized), authGate(auth, .GET, "/chat", null, null));
    try std.testing.expectEqual(@as(?std.http.Status, .unauthorized), authGate(auth, .GET, "/health", null, null));
    try std.testing.expectEqual(@as(?std.http.Status, .unauthorized), authGate(auth, .POST, "/", null, null));

    // Wrong, empty, or wrong-length tokens are rejected on both headers.
    try std.testing.expectEqual(@as(?std.http.Status, .unauthorized), authGate(auth, .GET, "/api/status", "wrong", null));
    try std.testing.expectEqual(@as(?std.http.Status, .unauthorized), authGate(auth, .GET, "/api/status", null, ""));
    try std.testing.expectEqual(@as(?std.http.Status, .unauthorized), authGate(auth, .GET, "/api/status", "secrets", null));

    // X-Pico-Token authenticates successfully.
    try std.testing.expectEqual(@as(?std.http.Status, null), authGate(auth, .GET, "/api/status", null, "secret"));
    // Authorization: Bearer authenticates successfully.
    try std.testing.expectEqual(@as(?std.http.Status, null), authGate(auth, .GET, "/api/status", "secret", null));
    // One header wrong, the other right: the right one wins.
    try std.testing.expectEqual(@as(?std.http.Status, null), authGate(auth, .GET, "/api/status", "wrong", "secret"));

    // No token configured: the gate rejects nothing (loopback default).
    try std.testing.expectEqual(@as(?std.http.Status, null), authGate(.{}, .GET, "/api/status", null, null));
    try std.testing.expectEqual(@as(?std.http.Status, null), authGate(.{}, .POST, "/chat", null, null));
}

test "validateBind: remote bind requires token" {
    try std.testing.expectError(error.NonLoopbackRequiresAuth, validateBind("0.0.0.0", null));
    try std.testing.expectError(error.NonLoopbackRequiresAuth, validateBind("192.168.1.10", null));
    try std.testing.expectError(error.NonLoopbackRequiresAuth, validateBind("100.64.0.5", null));
    try validateBind("0.0.0.0", "secret");
    try validateBind("192.168.1.10", "secret");
    try validateBind("127.0.0.1", null);
    try validateBind("127.0.0.1", "secret");
    try validateBind("localhost", null);
    try validateBind("::1", null);
}

test "dashboard shell is served with token auth configured" {
    var fake = Fake{ .allocator = std.testing.allocator };
    var dashboard = Dashboard{
        .handler = fake.handler(),
        .model = "test-model",
        .base_url = "https://example.invalid/v1",
        .telegram_state = "disabled",
        .auth = .{ .token = "secret" },
    };
    const shell = routeDashboard(std.testing.allocator, &dashboard, .GET, "/", "", false);
    defer shell.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, shell.status);
    try std.testing.expect(std.mem.indexOf(u8, shell.body, "Pico Claw") != null);
    // API routes stay unchanged at the routing layer; the connection-level
    // authGate is what rejects unauthenticated /api traffic with 401.
    const api = routeDashboard(std.testing.allocator, &dashboard, .GET, "/api/status", "", false);
    defer api.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, api.status);
}

test "dashboard HTML embeds the token login gate" {
    // The embedded shell must ship the login UI so a remote browser can
    // authenticate without any server-rendered secret.
    try std.testing.expect(std.mem.indexOf(u8, dashboard_html, "login-overlay") != null);
    try std.testing.expect(std.mem.indexOf(u8, dashboard_html, "id=\"login-token\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, dashboard_html, "localStorage.getItem(\"picoToken\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, dashboard_html, "localStorage.setItem(\"picoToken\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, dashboard_html, "X-Pico-Token") != null);
    try std.testing.expect(std.mem.indexOf(u8, dashboard_html, "signout-btn") != null);
    // A 401 from any API call re-opens the gate.
    try std.testing.expect(std.mem.indexOf(u8, dashboard_html, "showLogin") != null);
}
