const std = @import("std");
const key = @import("key.zig");
const Config = @import("Config.zig");
const Color = Config.Color;
const Key = key.Key;
const Value = key.Value;
pub fn get(config: *const Config, k: Key, ptr_raw: *anyopaque) bool {
    @setEvalBranchQuota(10_000);
    switch (k) {
        inline else => |tag| {
            const value = fieldByKey(config, tag);
            return getValue(ptr_raw, value);
        },
    }
}
fn getValue(ptr_raw: *anyopaque, value: anytype) bool {
    switch (@TypeOf(value)) {
        ?[:0]const u8 => {
            const ptr: *?[*:0]const u8 = @ptrCast(@alignCast(ptr_raw));
            ptr.* = if (value) |slice| @ptrCast(slice.ptr) else null;
        },
        bool => {
            const ptr: *bool = @ptrCast(@alignCast(ptr_raw));
            ptr.* = value;
        },
        u8, u32 => {
            const ptr: *c_uint = @ptrCast(@alignCast(ptr_raw));
            ptr.* = @intCast(value);
        },
        i16 => {
            const ptr: *c_short = @ptrCast(@alignCast(ptr_raw));
            ptr.* = @intCast(value);
        },
        f32, f64 => |Float| {
            const ptr: *Float = @ptrCast(@alignCast(ptr_raw));
            ptr.* = @floatCast(value);
        },
        else => |T| switch (@typeInfo(T)) {
            .optional => {
                const unwrapped = value orelse return false;
                return getValue(ptr_raw, unwrapped);
            },
            .@"enum" => {
                const ptr: *[*:0]const u8 = @ptrCast(@alignCast(ptr_raw));
                ptr.* = @tagName(value);
            },
            .@"struct" => |info| {
                if (@hasDecl(T, "cval")) {
                    const PtrT = @typeInfo(@TypeOf(T.cval)).@"fn".return_type.?;
                    const ptr: *PtrT = @ptrCast(@alignCast(ptr_raw));
                    ptr.* = value.cval();
                    return true;
                }
                if (info.layout != .@"packed") return false;
                const Backing = info.backing_integer orelse return false;
                if (@bitSizeOf(Backing) > @bitSizeOf(c_uint)) return false;
                const ptr: *c_uint = @ptrCast(@alignCast(ptr_raw));
                ptr.* = @intCast(@as(Backing, @bitCast(value)));
            },
            .@"union" => {
                if (@hasDecl(T, "cval")) {
                    const PtrT = @typeInfo(@TypeOf(T.cval)).@"fn".return_type.?;
                    const ptr: *PtrT = @ptrCast(@alignCast(ptr_raw));
                    ptr.* = value.cval();
                    return true;
                }
                return false;
            },
            else => return false,
        },
    }
    return true;
}
fn fieldByKey(self: *const Config, comptime k: Key) Value(k) {
    const field = comptime field: {
        const fields = std.meta.fields(Config);
        for (fields) |field| {
            if (@field(Key, field.name) == k) {
                break :field field;
            }
        }
        unreachable;
    };
    return @field(self, field.name);
}
test "c_get: u8" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c = try Config.default(alloc);
    defer c.deinit();
    c.@"font-size" = 24;
    var cval: f32 = undefined;
    try testing.expect(get(&c, .@"font-size", &cval));
    try testing.expectEqual(@as(f32, 24), cval);
}
test "c_get: enum" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c = try Config.default(alloc);
    defer c.deinit();
    c.@"window-theme" = .dark;
    var cval: [*:0]u8 = undefined;
    try testing.expect(get(&c, .@"window-theme", @ptrCast(&cval)));
    const str = std.mem.sliceTo(cval, 0);
    try testing.expectEqualStrings("dark", str);
}
test "c_get: color" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c = try Config.default(alloc);
    defer c.deinit();
    c.background = .{ .r = 255, .g = 0, .b = 0 };
    var cval: Color.C = undefined;
    try testing.expect(get(&c, .background, @ptrCast(&cval)));
    try testing.expectEqual(255, cval.r);
    try testing.expectEqual(0, cval.g);
    try testing.expectEqual(0, cval.b);
}
test "c_get: optional" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c = try Config.default(alloc);
    defer c.deinit();
    {
        c.@"unfocused-split-fill" = null;
        var cval: Color.C = undefined;
        try testing.expect(!get(&c, .@"unfocused-split-fill", @ptrCast(&cval)));
    }
    {
        c.@"unfocused-split-fill" = .{ .r = 255, .g = 0, .b = 0 };
        var cval: Color.C = undefined;
        try testing.expect(get(&c, .@"unfocused-split-fill", @ptrCast(&cval)));
        try testing.expectEqual(255, cval.r);
        try testing.expectEqual(0, cval.g);
        try testing.expectEqual(0, cval.b);
    }
}
test "c_get: background-blur" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c = try Config.default(alloc);
    defer c.deinit();
    {
        c.@"background-blur" = .false;
        var cval: i16 = undefined;
        try testing.expect(get(&c, .@"background-blur", @ptrCast(&cval)));
        try testing.expectEqual(0, cval);
    }
    {
        c.@"background-blur" = .true;
        var cval: i16 = undefined;
        try testing.expect(get(&c, .@"background-blur", @ptrCast(&cval)));
        try testing.expectEqual(20, cval);
    }
    {
        c.@"background-blur" = .{ .radius = 42 };
        var cval: i16 = undefined;
        try testing.expect(get(&c, .@"background-blur", @ptrCast(&cval)));
        try testing.expectEqual(42, cval);
    }
    {
        c.@"background-blur" = .@"macos-glass-regular";
        var cval: i16 = undefined;
        try testing.expect(get(&c, .@"background-blur", @ptrCast(&cval)));
        try testing.expectEqual(-1, cval);
    }
    {
        c.@"background-blur" = .@"macos-glass-clear";
        var cval: i16 = undefined;
        try testing.expect(get(&c, .@"background-blur", @ptrCast(&cval)));
        try testing.expectEqual(-2, cval);
    }
}
test "c_get: split-preserve-zoom" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c = try Config.default(alloc);
    defer c.deinit();
    var bits: c_uint = undefined;
    try testing.expect(get(&c, .@"split-preserve-zoom", @ptrCast(&bits)));
    try testing.expectEqual(@as(c_uint, 0), bits);
    c.@"split-preserve-zoom".navigation = true;
    try testing.expect(get(&c, .@"split-preserve-zoom", @ptrCast(&bits)));
    try testing.expectEqual(@as(c_uint, 1), bits);
}
