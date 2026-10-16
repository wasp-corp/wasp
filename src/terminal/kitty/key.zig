const std = @import("std");
pub const FlagStack = struct {
    const len = 8;
    flags: [len]Flags = @splat(.disabled),
    idx: u3 = 0,
    pub fn current(self: FlagStack) Flags {
        return self.flags[self.idx];
    }
    pub fn set(
        self: *FlagStack,
        mode: SetMode,
        v: Flags,
    ) void {
        switch (mode) {
            .set => self.flags[self.idx] = v,
            .@"or" => self.flags[self.idx] = @bitCast(
                self.flags[self.idx].int() | v.int(),
            ),
            .not => self.flags[self.idx] = @bitCast(
                self.flags[self.idx].int() & ~v.int(),
            ),
        }
    }
    pub fn push(self: *FlagStack, flags: Flags) void {
        self.idx +%= 1;
        self.flags[self.idx] = flags;
    }
    pub fn pop(self: *FlagStack, n: usize) void {
        if (n >= self.flags.len) {
            self.idx = 0;
            self.flags = @splat(.disabled);
            return;
        }
        for (0..n) |_| {
            self.flags[self.idx] = .disabled;
            self.idx -%= 1;
        }
    }
    test {
        const testing = std.testing;
        var stack: FlagStack = .{};
        stack.idx = stack.flags.len - 1;
        stack.idx +%= 1;
        try testing.expect(stack.idx == 0);
        stack.idx = 0;
        stack.idx -%= 1;
        try testing.expect(stack.idx == stack.flags.len - 1);
    }
};
pub const Flags = packed struct(u5) {
    disambiguate: bool = false,
    report_events: bool = false,
    report_alternates: bool = false,
    report_all: bool = false,
    report_associated: bool = false,
    pub const disabled: Flags = .{
        .disambiguate = false,
        .report_events = false,
        .report_alternates = false,
        .report_all = false,
        .report_associated = false,
    };
    pub const @"true": Flags = .{
        .disambiguate = true,
        .report_events = true,
        .report_alternates = true,
        .report_all = true,
        .report_associated = true,
    };
    pub fn int(self: Flags) u5 {
        return @bitCast(self);
    }
    test {
        const testing = std.testing;
        try testing.expectEqual(
            @as(u5, 0b1),
            (Flags{ .disambiguate = true }).int(),
        );
        try testing.expectEqual(
            @as(u5, 0b10),
            (Flags{ .report_events = true }).int(),
        );
    }
};
pub const SetMode = enum { set, @"or", not };
test "FlagStack: push pop" {
    const testing = std.testing;
    var stack: FlagStack = .{};
    stack.push(.{ .disambiguate = true });
    try testing.expectEqual(
        Flags{ .disambiguate = true },
        stack.current(),
    );
    stack.pop(1);
    try testing.expectEqual(Flags{}, stack.current());
}
test "FlagStack: pop big number" {
    const testing = std.testing;
    var stack: FlagStack = .{};
    stack.pop(100);
    try testing.expectEqual(Flags{}, stack.current());
}
test "FlagStack: set" {
    const testing = std.testing;
    var stack: FlagStack = .{};
    stack.set(.set, .{ .disambiguate = true });
    try testing.expectEqual(
        Flags{ .disambiguate = true },
        stack.current(),
    );
    stack.set(.@"or", .{ .report_events = true });
    try testing.expectEqual(
        Flags{
            .disambiguate = true,
            .report_events = true,
        },
        stack.current(),
    );
    stack.set(.not, .{ .report_events = true });
    try testing.expectEqual(
        Flags{ .disambiguate = true },
        stack.current(),
    );
}
