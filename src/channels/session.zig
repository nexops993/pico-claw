//! Session layer between channels and the agent: one bounded `Conversation`
//! per chat so histories never cross conversations. Channel sessions share
//! the same durable stores as CLI chat (memory, experience, tasks, proposals)
//! but keep an isolated message context per conversation identity.

const std = @import("std");

const ConversationModule = @import("../core/conversation.zig");
const Conversation = ConversationModule.Conversation;
const router = @import("../core/router.zig");
const task = @import("../core/task.zig");
const TaskStore = @import("../core/task_store.zig").TaskStore;
const ExperienceStore = @import("../experience/store.zig").ExperienceStore;
const StrategyStore = @import("../experience/strategy_store.zig").StrategyStore;
const ProposalStore = @import("../experience/proposal.zig").ProposalStore;
const KnowledgeStore = @import("../knowledge.zig").KnowledgeStore;
const Memory = @import("../memory/memory.zig").Memory;
const OwnerContext = @import("../owner.zig").OwnerContext;
const Provider = @import("../provider.zig").Provider;
const ToolRegistry = @import("../tools/registry.zig").ToolRegistry;

/// Fixed capacity for concurrent channel chats. When full, the least-recently
/// used chat is evicted: its in-memory context is dropped while all durable
/// stores are kept.
pub const max_sessions: usize = 8;

/// Everything `Conversation.init` needs, captured once when a channel starts
/// so chat sessions can be built on demand. `routing`/`teacher`/`proposals`
/// keep channel conversations at feature parity with the CLI conversation.
pub const AgentDeps = struct {
    provider: *Provider,
    tools: *const ToolRegistry,
    memory: *Memory,
    experience: *ExperienceStore,
    strategies: *StrategyStore,
    knowledge: *KnowledgeStore,
    owner: *const OwnerContext,
    tasks: ?*TaskStore = null,
    proposals: ?*ProposalStore = null,
    retry: task.RetryPolicy = .{},
    system_prompt: []const u8,
    routing: router.Policy = .{},
    teacher: ?ConversationModule.Teacher = null,
};

pub const SessionStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    deps: AgentDeps,
    entries: [max_sessions]?Entry = @splat(null),
    tick: u64 = 0,

    pub const Entry = struct {
        chat_id: []u8,
        conversation: Conversation,
        last_used: u64,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, deps: AgentDeps) SessionStore {
        return .{ .allocator = allocator, .io = io, .deps = deps };
    }

    pub fn deinit(self: *SessionStore) void {
        for (&self.entries) |*slot| {
            if (slot.*) |*entry| {
                entry.conversation.deinit();
                self.allocator.free(entry.chat_id);
                slot.* = null;
            }
        }
    }

    pub fn count(self: *const SessionStore) usize {
        var total: usize = 0;
        for (&self.entries) |*slot| {
            if (slot.* != null) total += 1;
        }
        return total;
    }

    /// Return the conversation for `chat_id`, creating it on first use. The
    /// returned pointer stays valid until the next `getOrCreate` call (which
    /// may evict a session) or `deinit`.
    pub fn getOrCreate(self: *SessionStore, chat_id: []const u8) !*Conversation {
        self.tick += 1;

        var lru_index: ?usize = null;
        for (&self.entries, 0..) |*slot, index| {
            if (slot.*) |*entry| {
                if (std.mem.eql(u8, entry.chat_id, chat_id)) {
                    entry.last_used = self.tick;
                    return &entry.conversation;
                }
                if (lru_index == null or entry.last_used < self.entries[lru_index.?].?.last_used) {
                    lru_index = index;
                }
            } else {
                return self.createIn(chat_id, slot);
            }
        }

        // Store is full: drop the least-recently-used chat, reuse its slot.
        const victim = &self.entries[lru_index.?];
        victim.*.?.conversation.deinit();
        self.allocator.free(victim.*.?.chat_id);
        victim.* = null;
        return self.createIn(chat_id, victim);
    }

    fn createIn(self: *SessionStore, chat_id: []const u8, slot: *?Entry) !*Conversation {
        const owned = try self.allocator.dupe(u8, chat_id);
        errdefer self.allocator.free(owned);

        const conversation = try Conversation.init(
            self.allocator,
            self.io,
            self.deps.provider,
            self.deps.tools,
            self.deps.memory,
            self.deps.experience,
            self.deps.strategies,
            self.deps.knowledge,
            self.deps.owner,
            self.deps.system_prompt,
            self.deps.tasks,
            self.deps.retry,
        );

        slot.* = .{
            .chat_id = owned,
            .conversation = conversation,
            .last_used = self.tick,
        };
        const stored = &slot.*.?.conversation;
        stored.routing = self.deps.routing;
        stored.teacher = self.deps.teacher;
        stored.proposals = self.deps.proposals;
        return stored;
    }

    /// Conversation for `chat_id` when a session already exists.
    pub fn find(self: *SessionStore, chat_id: []const u8) ?*Conversation {
        for (&self.entries) |*slot| {
            if (slot.*) |*entry| {
                if (std.mem.eql(u8, entry.chat_id, chat_id)) return &entry.conversation;
            }
        }
        return null;
    }

    /// Clear the conversation context of an existing chat session. Returns
    /// false when the chat has no session yet; nothing is created.
    pub fn clearChat(self: *SessionStore, chat_id: []const u8) bool {
        const conversation = self.find(chat_id) orelse return false;
        conversation.clear() catch return false;
        return true;
    }

    /// Remove a chat's session entirely (in-memory context dropped; durable
    /// stores are untouched). Returns false when the chat has no session.
    pub fn remove(self: *SessionStore, chat_id: []const u8) bool {
        for (&self.entries) |*slot| {
            if (slot.*) |*entry| {
                if (std.mem.eql(u8, entry.chat_id, chat_id)) {
                    entry.conversation.deinit();
                    self.allocator.free(entry.chat_id);
                    slot.* = null;
                    return true;
                }
            }
        }
        return false;
    }

    /// Rename a chat session: the conversation and its history keep their
    /// slot, only the identity changes. Returns false when `from` has no
    /// session or `to` is already taken.
    pub fn rename(self: *SessionStore, from: []const u8, to: []const u8) !bool {
        if (std.mem.eql(u8, from, to)) return self.find(from) != null;
        if (self.find(to) != null) return false;
        for (&self.entries) |*slot| {
            if (slot.*) |*entry| {
                if (std.mem.eql(u8, entry.chat_id, from)) {
                    const owned = try self.allocator.dupe(u8, to);
                    self.allocator.free(entry.chat_id);
                    entry.chat_id = owned;
                    return true;
                }
            }
        }
        return false;
    }

    /// Snapshot of live sessions. `chat_id` and counts are metadata only —
    /// never conversation content.
    pub const SessionInfo = struct {
        chat_id: []u8,
        message_count: usize,
    };

    /// List live sessions. Caller frees with `freeList`.
    pub fn list(self: *const SessionStore, allocator: std.mem.Allocator) error{OutOfMemory}![]SessionInfo {
        var infos: std.ArrayList(SessionInfo) = .empty;
        errdefer {
            for (infos.items) |*info| allocator.free(info.chat_id);
            infos.deinit(allocator);
        }
        for (&self.entries) |*slot| {
            if (slot.*) |*entry| {
                try infos.append(allocator, .{
                    .chat_id = try allocator.dupe(u8, entry.chat_id),
                    .message_count = entry.conversation.messageCount(),
                });
            }
        }
        return infos.toOwnedSlice(allocator);
    }

    /// Free a value returned by `list`.
    pub fn freeList(allocator: std.mem.Allocator, infos: []const SessionInfo) void {
        for (infos) |*info| allocator.free(info.chat_id);
        allocator.free(infos);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestHarness = struct {
    tmp: std.testing.TmpDir,
    env_map: std.process.Environ.Map,
    registry: ToolRegistry,
    memory: Memory,
    experience: ExperienceStore,
    strategies: StrategyStore,
    knowledge: KnowledgeStore,
    owner_context: OwnerContext,
    tasks: TaskStore,
    proposals: ProposalStore,
    provider: Provider,

    fn create(allocator: std.mem.Allocator, io: std.Io) !*TestHarness {
        const self = try allocator.create(TestHarness);
        errdefer allocator.destroy(self);

        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.env_map = std.process.Environ.Map.init(allocator);
        errdefer self.env_map.deinit();
        self.registry = ToolRegistry.init(allocator);
        errdefer self.registry.deinit();
        self.memory = try Memory.init(allocator, io);
        errdefer self.memory.deinit();
        self.experience = ExperienceStore.init(allocator, io);
        errdefer self.experience.deinit();
        self.strategies = StrategyStore.init(allocator, io);
        errdefer self.strategies.deinit();
        self.knowledge = KnowledgeStore.init(allocator, io);
        errdefer self.knowledge.deinit();
        self.tasks = TaskStore.init(allocator, io);
        errdefer self.tasks.deinit();
        self.proposals = ProposalStore.init(allocator, io);
        errdefer self.proposals.deinit();

        self.owner_context = try OwnerContext.initAt(
            allocator,
            io,
            self.tmp.dir,
            "SOUL.md",
            "MEMORY.md",
            .{},
        );
        errdefer self.owner_context.deinit();

        // No request is ever sent: the provider instance only exists so that
        // `Conversation.init` can be exercised with real dependencies.
        self.provider = Provider.init(allocator, io, &self.env_map, .{
            .agent_name = "test",
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
        return self;
    }

    fn destroy(self: *TestHarness, allocator: std.mem.Allocator) void {
        self.provider = undefined;
        self.owner_context.deinit();
        self.proposals.deinit();
        self.tasks.deinit();
        self.knowledge.deinit();
        self.strategies.deinit();
        self.experience.deinit();
        self.memory.deinit();
        self.registry.deinit();
        self.env_map.deinit();
        self.tmp.cleanup();
        allocator.destroy(self);
    }

    fn agentDeps(self: *TestHarness) AgentDeps {
        return .{
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
        };
    }
};

test "session store maps chats to isolated conversations" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const harness = try TestHarness.create(allocator, io);
    defer harness.destroy(allocator);

    var store = SessionStore.init(allocator, io, harness.agentDeps());
    defer store.deinit();

    const first = try store.getOrCreate("111");
    const second = try store.getOrCreate("222");
    try std.testing.expect(first != second);
    try std.testing.expectEqual(@as(usize, 2), store.count());

    // Repeated lookups return the same conversation; the store does not grow.
    const again = try store.getOrCreate("111");
    try std.testing.expectEqual(first, again);
    try std.testing.expectEqual(@as(usize, 2), store.count());
}

test "session store evicts the least recently used chat when full" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const harness = try TestHarness.create(allocator, io);
    defer harness.destroy(allocator);

    var store = SessionStore.init(allocator, io, harness.agentDeps());
    defer store.deinit();

    var chat_ids: [max_sessions + 1][]u8 = undefined;
    defer for (chat_ids) |id| allocator.free(id);
    for (&chat_ids, 0..) |*id, index| {
        id.* = try std.fmt.allocPrint(allocator, "chat-{d}", .{index});
    }

    for (chat_ids) |id| _ = try store.getOrCreate(id);

    // chat-0 was evicted when chat max_sessions arrived; the store stays at
    // capacity while accepting new chats.
    try std.testing.expectEqual(max_sessions, store.count());
    const survivor = try store.getOrCreate(chat_ids[1]);
    const fresh = try store.getOrCreate("chat-new");
    try std.testing.expect(survivor != fresh);
    try std.testing.expectEqual(max_sessions, store.count());
}

test "session clearChat resets only the target chat and reports missing chats" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const harness = try TestHarness.create(allocator, io);
    defer harness.destroy(allocator);

    var store = SessionStore.init(allocator, io, harness.agentDeps());
    defer store.deinit();

    // Clearing an unknown chat creates nothing and fails gracefully.
    try std.testing.expect(!store.clearChat("ghost"));
    try std.testing.expectEqual(@as(usize, 0), store.count());

    _ = try store.getOrCreate("111");
    const second = try store.getOrCreate("222");
    const first = store.find("111").?;
    try std.testing.expect(first != second);

    try std.testing.expect(store.clearChat("111"));
    // The cleared conversation keeps its system prompt seed but nothing else.
    try std.testing.expectEqual(@as(usize, 1), first.messageCount());
    try std.testing.expect(!store.clearChat("111x"));

    // Other chats are untouched.
    try std.testing.expectEqual(@as(usize, 2), store.count());
    try std.testing.expect(store.find("222") == second);
}

test "session list reports chat ids and message counts without content" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const harness = try TestHarness.create(allocator, io);
    defer harness.destroy(allocator);

    var store = SessionStore.init(allocator, io, harness.agentDeps());
    defer store.deinit();

    const empty = try store.list(allocator);
    defer SessionStore.freeList(allocator, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    _ = try store.getOrCreate("111");
    _ = try store.getOrCreate("222");

    const infos = try store.list(allocator);
    defer SessionStore.freeList(allocator, infos);
    try std.testing.expectEqual(@as(usize, 2), infos.len);
    // Message count includes only the system prompt seed for fresh chats.
    for (infos) |info| {
        try std.testing.expectEqual(@as(usize, 1), info.message_count);
        try std.testing.expect(info.chat_id.len == 3);
    }
}

test "session remove drops only the target chat" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const harness = try TestHarness.create(allocator, io);
    defer harness.destroy(allocator);

    var store = SessionStore.init(allocator, io, harness.agentDeps());
    defer store.deinit();

    try std.testing.expect(!store.remove("ghost"));
    _ = try store.getOrCreate("111");
    _ = try store.getOrCreate("222");
    try std.testing.expect(store.remove("111"));
    try std.testing.expect(!store.remove("111"));
    try std.testing.expectEqual(@as(usize, 1), store.count());
    try std.testing.expect(store.find("222") != null);
}

test "session rename keeps the conversation under a new id" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const harness = try TestHarness.create(allocator, io);
    defer harness.destroy(allocator);

    var store = SessionStore.init(allocator, io, harness.agentDeps());
    defer store.deinit();

    const conversation = try store.getOrCreate("111");
    try std.testing.expect(try store.rename("111", "research"));
    try std.testing.expectEqual(@as(usize, 1), store.count());
    try std.testing.expect(store.find("111") == null);
    try std.testing.expectEqual(conversation, store.find("research"));

    // Renaming to an existing id is refused.
    _ = try store.getOrCreate("other");
    try std.testing.expect(!(try store.rename("research", "other")));
    // Renaming to itself is a no-op.
    try std.testing.expect(try store.rename("research", "research"));
}
