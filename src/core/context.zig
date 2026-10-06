const std = @import("std");

pub const Role = enum {
    system,
    user,
    assistant,
};

pub const Message = struct {
    role: Role,
    content: []u8,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(Message),

    pub fn init(
        allocator: std.mem.Allocator,
    ) Context {
        return .{
            .allocator = allocator,
            .messages = .empty,
        };
    }

    pub fn deinit(
        self: *Context,
    ) void {
        for (self.messages.items) |message| {
            self.allocator.free(message.content);
        }

        self.messages.deinit(self.allocator);
    }

    pub fn add(
        self: *Context,
        role: Role,
        content: []const u8,
    ) !void {
        const owned_content =
            try self.allocator.dupe(
                u8,
                content,
            );

        errdefer self.allocator.free(
            owned_content,
        );

        try self.messages.append(
            self.allocator,
            .{
                .role = role,
                .content = owned_content,
            },
        );
    }

    pub fn addSystem(
        self: *Context,
        content: []const u8,
    ) !void {
        try self.add(
            .system,
            content,
        );
    }

    pub fn addUser(
        self: *Context,
        content: []const u8,
    ) !void {
        try self.add(
            .user,
            content,
        );
    }

    pub fn addAssistant(
        self: *Context,
        content: []const u8,
    ) !void {
        try self.add(
            .assistant,
            content,
        );
    }

    pub fn count(
        self: *const Context,
    ) usize {
        return self.messages.items.len;
    }

    /// Total content bytes across messages: a bounded size estimate for the
    /// provider request, recorded as usage without storing message content.
    pub fn byteCount(
        self: *const Context,
    ) usize {
        var total: usize = 0;

        for (self.messages.items) |message| {
            total += message.content.len;
        }

        return total;
    }

    pub fn clear(
        self: *Context,
    ) void {
        for (self.messages.items) |message| {
            self.allocator.free(message.content);
        }

        self.messages.clearRetainingCapacity();
    }

    pub fn print(
        self: *const Context,
    ) void {
        std.debug.print(
            "\nContext: {d} messages\n",
            .{self.messages.items.len},
        );

        for (
            self.messages.items,
            0..,
        ) |message, index| {
            std.debug.print(
                "[{d}] {s}: {s}\n",
                .{
                    index,
                    roleName(message.role),
                    message.content,
                },
            );
        }
    }

    fn roleName(
        role: Role,
    ) []const u8 {
        return switch (role) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
        };
    }
};
