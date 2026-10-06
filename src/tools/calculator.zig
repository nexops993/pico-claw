const std = @import("std");
const Tool = @import("tool.zig").Tool;

pub const Calculator = struct {
    pub fn tool(self: *Calculator) Tool {
        return .{
            .name = "calculator",
            .description = "Evaluate arithmetic with +, -, *, /, and parentheses",
            .context = self,
            .executeFn = executeErased,
            .permission = .standard,
            .risk = .low,
            .parameters = &.{
                .{ .name = "expression", .description = "Arithmetic expression, e.g. (2 + 3) * 4", .required = true },
            },
        };
    }

    pub fn execute(
        _: *Calculator,
        allocator: std.mem.Allocator,
        input: []const u8,
    ) ![]u8 {
        var parser = Parser{ .input = input };
        const value = try parser.parseExpression();
        parser.skipWhitespace();
        if (parser.index != input.len) return error.InvalidExpression;
        if (!std.math.isFinite(value)) return error.InvalidResult;
        return std.fmt.allocPrint(allocator, "{d}", .{value});
    }

    fn executeErased(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        input: []const u8,
    ) ![]u8 {
        const self: *Calculator = @ptrCast(@alignCast(context));
        return self.execute(allocator, input);
    }
};

const ParseError = error{
    InvalidExpression,
    DivisionByZero,
};

const Parser = struct {
    input: []const u8,
    index: usize = 0,

    fn parseExpression(self: *Parser) ParseError!f64 {
        var value = try self.parseTerm();
        while (true) {
            self.skipWhitespace();
            if (self.consume('+')) value += try self.parseTerm() else if (self.consume('-')) value -= try self.parseTerm() else return value;
        }
    }

    fn parseTerm(self: *Parser) ParseError!f64 {
        var value = try self.parseFactor();
        while (true) {
            self.skipWhitespace();
            if (self.consume('*')) {
                value *= try self.parseFactor();
            } else if (self.consume('/')) {
                const divisor = try self.parseFactor();
                if (divisor == 0) return error.DivisionByZero;
                value /= divisor;
            } else return value;
        }
    }

    fn parseFactor(self: *Parser) ParseError!f64 {
        self.skipWhitespace();
        if (self.consume('+')) return self.parseFactor();
        if (self.consume('-')) return -(try self.parseFactor());
        if (self.consume('(')) {
            const value = try self.parseExpression();
            self.skipWhitespace();
            if (!self.consume(')')) return error.InvalidExpression;
            return value;
        }
        return self.parseNumber();
    }

    fn parseNumber(self: *Parser) ParseError!f64 {
        self.skipWhitespace();
        const start = self.index;
        var dot_seen = false;
        while (self.index < self.input.len) : (self.index += 1) {
            const char = self.input[self.index];
            if (std.ascii.isDigit(char)) continue;
            if (char == '.' and !dot_seen) {
                dot_seen = true;
                continue;
            }
            break;
        }
        if (start == self.index) return error.InvalidExpression;
        return std.fmt.parseFloat(f64, self.input[start..self.index]) catch error.InvalidExpression;
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.index < self.input.len and std.ascii.isWhitespace(self.input[self.index])) self.index += 1;
    }

    fn consume(self: *Parser, expected: u8) bool {
        if (self.index >= self.input.len or self.input[self.index] != expected) return false;
        self.index += 1;
        return true;
    }
};

test "calculator evaluates arithmetic" {
    var calculator = Calculator{};
    const result = try calculator.execute(std.testing.allocator, "123 * 456");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("56088", result);
}

test "calculator honors precedence and parentheses" {
    var calculator = Calculator{};
    const result = try calculator.execute(std.testing.allocator, "(2 + 3) * 4 - 6 / 2");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("17", result);
}

test "calculator rejects invalid input and division by zero" {
    var calculator = Calculator{};
    try std.testing.expectError(error.InvalidExpression, calculator.execute(std.testing.allocator, "2 + nope"));
    try std.testing.expectError(error.DivisionByZero, calculator.execute(std.testing.allocator, "1 / 0"));
}
