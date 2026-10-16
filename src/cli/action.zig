const std = @import("std");
const Allocator = std.mem.Allocator;
pub const DetectError = error{
    MultipleActions,
    InvalidAction,
};
pub fn detectArgs(comptime E: type, alloc: Allocator, args: std.process.Args) !?E {
    var iter = try args.iterateAllocator(alloc);
    defer iter.deinit();
    return try detectIter(E, &iter);
}
pub fn detectIter(
    comptime E: type,
    iter: anytype,
) DetectError!?E {
    var fallback: ?E = null;
    var pending: ?E = null;
    while (iter.next()) |arg| {
        if (@hasDecl(E, "detectSpecialCase")) special: {
            const special = E.detectSpecialCase(arg) orelse break :special;
            switch (special) {
                .action => |a| return a,
                .fallback => |a| fallback = a,
                .abort_if_no_action => if (pending == null) return null,
            }
        }
        if (arg.len == 0 or arg[0] != '+') continue;
        if (pending != null) return DetectError.MultipleActions;
        pending = std.meta.stringToEnum(E, arg[1..]) orelse
            return DetectError.InvalidAction;
    }
    if (pending != null) return pending;
    if (fallback) |a| return a;
    return null;
}
pub fn SpecialCase(comptime E: type) type {
    return union(enum) {
        action: E,
        fallback: E,
        abort_if_no_action,
    };
}
test "detect direct match" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Enum = enum { foo, bar, baz };
    var iter = try std.process.Args.IteratorGeneral(.{}).init(
        alloc,
        "+foo",
    );
    defer iter.deinit();
    const result = try detectIter(Enum, &iter);
    try testing.expectEqual(Enum.foo, result.?);
}
test "detect invalid match" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Enum = enum { foo, bar, baz };
    var iter = try std.process.Args.IteratorGeneral(.{}).init(
        alloc,
        "+invalid",
    );
    defer iter.deinit();
    try testing.expectError(
        DetectError.InvalidAction,
        detectIter(Enum, &iter),
    );
}
test "detect multiple actions" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Enum = enum { foo, bar, baz };
    var iter = try std.process.Args.IteratorGeneral(.{}).init(
        alloc,
        "+foo +bar",
    );
    defer iter.deinit();
    try testing.expectError(
        DetectError.MultipleActions,
        detectIter(Enum, &iter),
    );
}
test "detect no match" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Enum = enum { foo, bar, baz };
    var iter = try std.process.Args.IteratorGeneral(.{}).init(
        alloc,
        "--some-flag",
    );
    defer iter.deinit();
    const result = try detectIter(Enum, &iter);
    try testing.expect(result == null);
}
test "detect special case action" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Enum = enum {
        foo,
        bar,
        fn detectSpecialCase(arg: []const u8) ?SpecialCase(@This()) {
            return if (std.mem.eql(u8, arg, "--special"))
                .{ .action = .foo }
            else
                null;
        }
    };
    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--special +bar",
        );
        defer iter.deinit();
        const result = try detectIter(Enum, &iter);
        try testing.expectEqual(Enum.foo, result.?);
    }
    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "+bar --special",
        );
        defer iter.deinit();
        const result = try detectIter(Enum, &iter);
        try testing.expectEqual(Enum.foo, result.?);
    }
    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "+bar",
        );
        defer iter.deinit();
        const result = try detectIter(Enum, &iter);
        try testing.expectEqual(Enum.bar, result.?);
    }
}
test "detect special case fallback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Enum = enum {
        foo,
        bar,
        fn detectSpecialCase(arg: []const u8) ?SpecialCase(@This()) {
            return if (std.mem.eql(u8, arg, "--special"))
                .{ .fallback = .foo }
            else
                null;
        }
    };
    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--special",
        );
        defer iter.deinit();
        const result = try detectIter(Enum, &iter);
        try testing.expectEqual(Enum.foo, result.?);
    }
    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "+bar --special",
        );
        defer iter.deinit();
        const result = try detectIter(Enum, &iter);
        try testing.expectEqual(Enum.bar, result.?);
    }
    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--special +bar",
        );
        defer iter.deinit();
        const result = try detectIter(Enum, &iter);
        try testing.expectEqual(Enum.bar, result.?);
    }
}
test "detect special case abort_if_no_action" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Enum = enum {
        foo,
        bar,
        fn detectSpecialCase(arg: []const u8) ?SpecialCase(@This()) {
            return if (std.mem.eql(u8, arg, "-e"))
                .abort_if_no_action
            else
                null;
        }
    };
    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "-e",
        );
        defer iter.deinit();
        const result = try detectIter(Enum, &iter);
        try testing.expect(result == null);
    }
    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "+foo -e",
        );
        defer iter.deinit();
        const result = try detectIter(Enum, &iter);
        try testing.expectEqual(Enum.foo, result.?);
    }
    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "-e +bar",
        );
        defer iter.deinit();
        const result = try detectIter(Enum, &iter);
        try testing.expect(result == null);
    }
}
