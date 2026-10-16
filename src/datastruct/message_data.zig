const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
pub fn MessageData(comptime Elem: type, comptime small_size: comptime_int) type {
    return union(enum) {
        pub const Self = @This();
        pub const Small = struct {
            pub const Max = small_size;
            pub const Array = [Max]Elem;
            pub const Len = std.math.IntFittingRange(0, small_size);
            data: Array = undefined,
            len: Len = 0,
        };
        pub const Alloc = struct {
            alloc: Allocator,
            data: []Elem,
        };
        pub const Stable = []const Elem;
        small: Small,
        stable: Stable,
        alloc: Alloc,
        pub fn init(alloc: Allocator, data: anytype) !Self {
            switch (@typeInfo(@TypeOf(data))) {
                .pointer => |info| {
                    assert(info.size == .slice);
                    assert(info.child == Elem);
                    if (data.len <= Small.Max) {
                        var buf: Small.Array = undefined;
                        @memcpy(buf[0..data.len], data);
                        return Self{
                            .small = .{
                                .data = buf,
                                .len = @intCast(data.len),
                            },
                        };
                    }
                    const buf = try alloc.dupe(Elem, data);
                    errdefer alloc.free(buf);
                    return Self{
                        .alloc = .{
                            .alloc = alloc,
                            .data = buf,
                        },
                    };
                },
                else => unreachable,
            }
        }
        pub fn deinit(self: Self) void {
            switch (self) {
                .small, .stable => {},
                .alloc => |v| v.alloc.free(v.data),
            }
        }
        pub fn slice(self: *const Self) []const Elem {
            return switch (self.*) {
                .small => |*v| v.data[0..v.len],
                .stable => |v| v,
                .alloc => |v| v.data,
            };
        }
    };
}
test "MessageData init small" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Data = MessageData(u8, 10);
    const input = "hello!";
    const io = try Data.init(alloc, @as([]const u8, input));
    try testing.expect(io == .small);
}
test "MessageData init alloc" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Data = MessageData(u8, 10);
    const input = "hello! " ** 100;
    const io = try Data.init(alloc, @as([]const u8, input));
    try testing.expect(io == .alloc);
    io.alloc.alloc.free(io.alloc.data);
}
test "MessageData small fits non-u8 sized data" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const len = 500;
    const Data = MessageData(u8, len);
    const input: []const u8 = "X" ** len;
    const io = try Data.init(alloc, input);
    try testing.expect(io == .small);
}
