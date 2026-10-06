//! Channel core: transport-neutral message types shared by every channel
//! adapter. An adapter converts platform-specific payloads into an
//! `InboundMessage`, hands it to the session layer, and delivers the agent's
//! reply (an `OutboundMessage`) back to the user. Adapters never touch agent
//! internals beyond `Conversation.send`.

const std = @import("std");

/// Known transport channels. Adding a channel means adding a tag here plus a
/// new adapter under `src/channels/`; the agent core is unchanged.
pub const ChannelKind = enum {
    telegram,

    pub fn name(self: ChannelKind) []const u8 {
        return switch (self) {
            .telegram => "telegram",
        };
    }
};

/// Lifecycle state reported by `status` and `channel status`. `running` is
/// only observable while a channel loop is active.
pub const ChannelState = enum {
    disabled,
    not_configured,
    enabled,
    running,

    pub fn label(self: ChannelState) []const u8 {
        return switch (self) {
            .disabled => "disabled",
            .not_configured => "not configured (missing token)",
            .enabled => "enabled",
            .running => "running",
        };
    }
};

/// Normalized inbound user message. All strings are owned copies allocated
/// from `allocator` and freed by `deinit`; callers may pass borrowed slices.
pub const InboundMessage = struct {
    channel: ChannelKind,
    /// Platform user identity, normalized to text (e.g. a decimal id).
    user_id: []u8,
    /// Conversation identity within the channel (e.g. a chat id).
    chat_id: []u8,
    text: []u8,
    /// Platform message id when the transport provides one.
    message_id: ?u64,

    pub fn init(
        allocator: std.mem.Allocator,
        channel: ChannelKind,
        user_id: []const u8,
        chat_id: []const u8,
        text: []const u8,
        message_id: ?u64,
    ) !InboundMessage {
        return .{
            .channel = channel,
            .user_id = try allocator.dupe(u8, user_id),
            .chat_id = try allocator.dupe(u8, chat_id),
            .text = try allocator.dupe(u8, text),
            .message_id = message_id,
        };
    }

    pub fn deinit(
        self: *const InboundMessage,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.user_id);
        allocator.free(self.chat_id);
        allocator.free(self.text);
    }
};

/// Outbound reply toward one chat. Both fields are borrowed: the adapter
/// sends it and frees the backing memory itself.
pub const OutboundMessage = struct {
    chat_id: []const u8,
    text: []const u8,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "inbound message copies inputs and frees them" {
    const allocator = std.testing.allocator;

    const message = try InboundMessage.init(
        allocator,
        .telegram,
        "111",
        "222",
        "Halo 👋",
        7,
    );
    defer message.deinit(allocator);

    try std.testing.expectEqual(ChannelKind.telegram, message.channel);
    try std.testing.expectEqualStrings("111", message.user_id);
    try std.testing.expectEqualStrings("222", message.chat_id);
    try std.testing.expectEqualStrings("Halo 👋", message.text);
    try std.testing.expectEqual(@as(?u64, 7), message.message_id);
}

test "channel kind and state labels are stable" {
    try std.testing.expectEqualStrings("telegram", ChannelKind.telegram.name());
    try std.testing.expectEqualStrings("disabled", ChannelState.disabled.label());
    try std.testing.expectEqualStrings("not configured (missing token)", ChannelState.not_configured.label());
    try std.testing.expectEqualStrings("enabled", ChannelState.enabled.label());
    try std.testing.expectEqualStrings("running", ChannelState.running.label());
}
