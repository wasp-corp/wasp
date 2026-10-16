const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
pub const max_page_size = std.math.maxInt(u32);
pub const OffsetInt = std.math.IntFittingRange(0, max_page_size - 1);
pub const CellCountInt = u16;
pub const StyleCountInt = CellCountInt;
pub const HyperlinkCountInt = CellCountInt;
pub const GraphemeBytesInt = u32;
pub const StringBytesInt = u32;
pub fn Offset(comptime T: type) type {
    return packed struct(OffsetInt) {
        const Self = @This();
        offset: OffsetInt = 0,
        pub const Slice = struct {
            offset: Self = .{},
            len: usize = 0,
            pub inline fn slice(self: Slice, base: anytype) []T {
                return self.offset.ptr(base)[0..self.len];
            }
        };
        pub inline fn ptr(self: Self, base: anytype) [*]T {
            const addr = intFromBase(base) + self.offset;
            assert(addr % @alignOf(T) == 0);
            return @ptrFromInt(addr);
        }
    };
}
pub const OffsetBuf = struct {
    base: [*]u8,
    offset: usize = 0,
    pub fn init(base: anytype) OffsetBuf {
        return initOffset(base, 0);
    }
    pub fn initOffset(base: anytype, offset: usize) OffsetBuf {
        return .{
            .base = @ptrFromInt(intFromBase(base)),
            .offset = offset,
        };
    }
    pub fn start(self: OffsetBuf) [*]u8 {
        const ptr = self.base + self.offset;
        return @ptrCast(ptr);
    }
    pub fn member(
        self: OffsetBuf,
        comptime T: type,
        len: usize,
    ) Offset(T) {
        return .{ .offset = @intCast(self.offset + len) };
    }
    pub fn add(self: OffsetBuf, offset: usize) OffsetBuf {
        return .{
            .base = self.base,
            .offset = self.offset + offset,
        };
    }
    pub fn rebase(self: OffsetBuf, offset: usize) OffsetBuf {
        return .{
            .base = self.start() + offset,
            .offset = 0,
        };
    }
};
pub inline fn getOffset(
    comptime T: type,
    base: anytype,
    ptr: *const T,
) Offset(T) {
    const base_int = intFromBase(base);
    const ptr_int = @intFromPtr(ptr);
    const offset = ptr_int - base_int;
    return .{ .offset = @intCast(offset) };
}
inline fn intFromBase(base: anytype) usize {
    const T = @TypeOf(base);
    return switch (@typeInfo(T)) {
        .pointer => |v| switch (v.size) {
            .one,
            .many,
            .c,
            => @intFromPtr(base),
            .slice => @intFromPtr(base.ptr),
        },
        else => switch (T) {
            OffsetBuf => @intFromPtr(base.base),
            else => @compileError("invalid base type"),
        },
    };
}
test "Offset" {
    const testing = std.testing;
    try testing.expect(OffsetInt == u32);
}
test "Offset ptr u8" {
    const testing = std.testing;
    const offset: Offset(u8) = .{ .offset = 42 };
    const base_int: usize = @intFromPtr(&offset);
    const actual = offset.ptr(&offset);
    try testing.expectEqual(@as(usize, base_int + 42), @intFromPtr(actual));
}
test "Offset ptr structural" {
    const Struct = struct { x: u32, y: u32 };
    const testing = std.testing;
    const offset: Offset(Struct) = .{ .offset = @alignOf(Struct) * 4 };
    const base_int: usize = std.mem.alignForward(usize, @intFromPtr(&offset), @alignOf(Struct));
    const base: [*]u8 = @ptrFromInt(base_int);
    const actual = offset.ptr(base);
    try testing.expectEqual(@as(usize, base_int + offset.offset), @intFromPtr(actual));
}
test "getOffset bytes" {
    const testing = std.testing;
    var widgets: []const u8 = "ABCD";
    const offset = getOffset(u8, widgets.ptr, &widgets[2]);
    try testing.expectEqual(@as(OffsetInt, 2), offset.offset);
}
test "getOffset structs" {
    const testing = std.testing;
    const Widget = struct { x: u32, y: u32 };
    const widgets: []const Widget = &.{
        .{ .x = 1, .y = 2 },
        .{ .x = 3, .y = 4 },
        .{ .x = 5, .y = 6 },
        .{ .x = 7, .y = 8 },
        .{ .x = 9, .y = 10 },
    };
    const offset = getOffset(Widget, widgets.ptr, &widgets[2]);
    try testing.expectEqual(
        @as(OffsetInt, @sizeOf(Widget) * 2),
        offset.offset,
    );
}
