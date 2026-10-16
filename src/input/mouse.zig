const std = @import("std");
pub const Action = enum(c_int) { press, release, motion };
pub const ButtonState = enum(c_int) {
    release,
    press,
};
pub const Button = enum(c_int) {
    const Self = @This();
    pub const max = max: {
        var cur = 0;
        for (@typeInfo(Self).@"enum".fields) |field| {
            if (field.value > cur) cur = field.value;
        }
        break :max cur;
    };
    unknown = 0,
    left = 1,
    right = 2,
    middle = 3,
    four = 4,
    five = 5,
    six = 6,
    seven = 7,
    eight = 8,
    nine = 9,
    ten = 10,
    eleven = 11,
};
pub const Momentum = enum(u3) {
    none = 0,
    began = 1,
    stationary = 2,
    changed = 3,
    ended = 4,
    cancelled = 5,
    may_begin = 6,
};
pub const PressureStage = enum(u2) {
    none = 0,
    normal = 1,
    deep = 2,
};
pub const ScrollMods = packed struct(u8) {
    precision: bool = false,
    momentum: Momentum = .none,
    _padding: u4 = 0,
    test {
        const testing = std.testing;
        try testing.expectEqual(@as(u8, @bitCast(ScrollMods{})), @as(u8, 0b0));
        try testing.expectEqual(
            @as(u8, @bitCast(ScrollMods{ .precision = true })),
            @as(u8, 0b0000_0001),
        );
    }
};
