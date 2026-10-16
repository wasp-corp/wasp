const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const testing = std.testing;
const mem = std.mem;
const Allocator = std.mem.Allocator;
pub fn SegmentedList(comptime T: type, comptime prealloc_item_count: usize) type {
    return struct {
        const Self = @This();
        const ShelfIndex = std.math.Log2Int(usize);
        const prealloc_exp: ShelfIndex = blk: {
            if (prealloc_item_count == 0) {
                break :blk 0;
            } else {
                assert(std.math.isPowerOfTwo(prealloc_item_count));
                const value = std.math.log2_int(usize, prealloc_item_count);
                break :blk value;
            }
        };
        prealloc_segment: [prealloc_item_count]T = undefined,
        dynamic_segments: [][*]T = &[_][*]T{},
        len: usize = 0,
        pub const prealloc_count = prealloc_item_count;
        fn AtType(comptime SelfType: type) type {
            if (@typeInfo(SelfType).pointer.is_const) {
                return *const T;
            } else {
                return *T;
            }
        }
        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.freeShelves(allocator, @as(ShelfIndex, @intCast(self.dynamic_segments.len)), 0);
            allocator.free(self.dynamic_segments);
            self.* = undefined;
        }
        pub fn at(self: anytype, i: usize) AtType(@TypeOf(self)) {
            assert(i < self.len);
            return self.uncheckedAt(i);
        }
        pub fn count(self: Self) usize {
            return self.len;
        }
        pub fn append(self: *Self, allocator: Allocator, item: T) Allocator.Error!void {
            const new_item_ptr = try self.addOne(allocator);
            new_item_ptr.* = item;
        }
        pub fn appendSlice(self: *Self, allocator: Allocator, items: []const T) Allocator.Error!void {
            for (items) |item| {
                try self.append(allocator, item);
            }
        }
        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            const index = self.len - 1;
            const result = uncheckedAt(self, index).*;
            self.len = index;
            return result;
        }
        pub fn addOne(self: *Self, allocator: Allocator) Allocator.Error!*T {
            const new_length = self.len + 1;
            try self.growCapacity(allocator, new_length);
            const result = uncheckedAt(self, self.len);
            self.len = new_length;
            return result;
        }
        pub fn shrinkRetainingCapacity(self: *Self, new_len: usize) void {
            assert(new_len <= self.len);
            self.len = new_len;
        }
        pub fn clearRetainingCapacity(self: *Self) void {
            self.len = 0;
        }
        pub fn clearAndFree(self: *Self, allocator: Allocator) void {
            self.setCapacity(allocator, 0) catch unreachable;
            self.len = 0;
        }
        pub fn setCapacity(self: *Self, allocator: Allocator, new_capacity: usize) Allocator.Error!void {
            if (prealloc_item_count != 0) {
                if (new_capacity <= @as(usize, 1) << (prealloc_exp + @as(ShelfIndex, @intCast(self.dynamic_segments.len)))) {
                    return self.shrinkCapacity(allocator, new_capacity);
                }
            }
            return self.growCapacity(allocator, new_capacity);
        }
        pub fn growCapacity(self: *Self, allocator: Allocator, new_capacity: usize) Allocator.Error!void {
            const new_cap_shelf_count = shelfCount(new_capacity);
            const old_shelf_count = @as(ShelfIndex, @intCast(self.dynamic_segments.len));
            if (new_cap_shelf_count <= old_shelf_count) return;
            const new_dynamic_segments = try allocator.alloc([*]T, new_cap_shelf_count);
            errdefer allocator.free(new_dynamic_segments);
            var i: ShelfIndex = 0;
            while (i < old_shelf_count) : (i += 1) {
                new_dynamic_segments[i] = self.dynamic_segments[i];
            }
            errdefer while (i > old_shelf_count) : (i -= 1) {
                allocator.free(new_dynamic_segments[i][0..shelfSize(i)]);
            };
            while (i < new_cap_shelf_count) : (i += 1) {
                new_dynamic_segments[i] = (try allocator.alloc(T, shelfSize(i))).ptr;
            }
            allocator.free(self.dynamic_segments);
            self.dynamic_segments = new_dynamic_segments;
        }
        pub fn shrinkCapacity(self: *Self, allocator: Allocator, new_capacity: usize) void {
            if (new_capacity <= prealloc_item_count) {
                const len = @as(ShelfIndex, @intCast(self.dynamic_segments.len));
                self.freeShelves(allocator, len, 0);
                allocator.free(self.dynamic_segments);
                self.dynamic_segments = &[_][*]T{};
                return;
            }
            const new_cap_shelf_count = shelfCount(new_capacity);
            const old_shelf_count = @as(ShelfIndex, @intCast(self.dynamic_segments.len));
            assert(new_cap_shelf_count <= old_shelf_count);
            if (new_cap_shelf_count == old_shelf_count) return;
            const new_dynamic_segments = allocator.alloc([*]T, new_cap_shelf_count) catch return;
            self.freeShelves(allocator, old_shelf_count, new_cap_shelf_count);
            if (allocator.resize(self.dynamic_segments, new_cap_shelf_count)) {
                self.dynamic_segments = self.dynamic_segments[0..new_cap_shelf_count];
                allocator.free(new_dynamic_segments);
            } else {
                @memcpy(new_dynamic_segments, self.dynamic_segments[0..new_cap_shelf_count]);
                allocator.free(self.dynamic_segments);
                self.dynamic_segments = new_dynamic_segments;
            }
        }
        pub fn shrink(self: *Self, new_len: usize) void {
            assert(new_len <= self.len);
            self.len = new_len;
        }
        pub fn writeToSlice(self: *Self, dest: []T, start: usize) void {
            const end = start + dest.len;
            assert(end <= self.len);
            var i = start;
            if (end <= prealloc_item_count) {
                const src = self.prealloc_segment[i..end];
                @memcpy(dest[i - start ..][0..src.len], src);
                return;
            } else if (i < prealloc_item_count) {
                const src = self.prealloc_segment[i..];
                @memcpy(dest[i - start ..][0..src.len], src);
                i = prealloc_item_count;
            }
            while (i < end) {
                const shelf_index = shelfIndex(i);
                const copy_start = boxIndex(i, shelf_index);
                const copy_end = @min(shelfSize(shelf_index), copy_start + end - i);
                const src = self.dynamic_segments[shelf_index][copy_start..copy_end];
                @memcpy(dest[i - start ..][0..src.len], src);
                i += (copy_end - copy_start);
            }
        }
        pub fn uncheckedAt(self: anytype, index: usize) AtType(@TypeOf(self)) {
            if (index < prealloc_item_count) {
                return &self.prealloc_segment[index];
            }
            const shelf_index = shelfIndex(index);
            const box_index = boxIndex(index, shelf_index);
            return &self.dynamic_segments[shelf_index][box_index];
        }
        fn shelfCount(box_count: usize) ShelfIndex {
            if (prealloc_item_count == 0) {
                return log2_int_ceil(usize, box_count + 1);
            }
            return log2_int_ceil(usize, box_count + prealloc_item_count) - prealloc_exp - 1;
        }
        fn shelfSize(shelf_index: ShelfIndex) usize {
            if (prealloc_item_count == 0) {
                return @as(usize, 1) << shelf_index;
            }
            return @as(usize, 1) << (shelf_index + (prealloc_exp + 1));
        }
        fn shelfIndex(list_index: usize) ShelfIndex {
            if (prealloc_item_count == 0) {
                return std.math.log2_int(usize, list_index + 1);
            }
            return std.math.log2_int(usize, list_index + prealloc_item_count) - prealloc_exp - 1;
        }
        fn boxIndex(list_index: usize, shelf_index: ShelfIndex) usize {
            if (prealloc_item_count == 0) {
                return (list_index + 1) - (@as(usize, 1) << shelf_index);
            }
            return list_index + prealloc_item_count - (@as(usize, 1) << ((prealloc_exp + 1) + shelf_index));
        }
        fn freeShelves(self: *Self, allocator: Allocator, from_count: ShelfIndex, to_count: ShelfIndex) void {
            var i = from_count;
            while (i != to_count) {
                i -= 1;
                allocator.free(self.dynamic_segments[i][0..shelfSize(i)]);
            }
        }
        pub const Iterator = BaseIterator(*Self, *T);
        pub const ConstIterator = BaseIterator(*const Self, *const T);
        fn BaseIterator(comptime SelfType: type, comptime ElementPtr: type) type {
            return struct {
                list: SelfType,
                index: usize,
                box_index: usize,
                shelf_index: ShelfIndex,
                shelf_size: usize,
                pub fn next(it: *@This()) ?ElementPtr {
                    if (it.index >= it.list.len) return null;
                    if (it.index < prealloc_item_count) {
                        const ptr = &it.list.prealloc_segment[it.index];
                        it.index += 1;
                        if (it.index == prealloc_item_count) {
                            it.box_index = 0;
                            it.shelf_index = 0;
                            it.shelf_size = prealloc_item_count * 2;
                        }
                        return ptr;
                    }
                    const ptr = &it.list.dynamic_segments[it.shelf_index][it.box_index];
                    it.index += 1;
                    it.box_index += 1;
                    if (it.box_index == it.shelf_size) {
                        it.shelf_index += 1;
                        it.box_index = 0;
                        it.shelf_size *= 2;
                    }
                    return ptr;
                }
                pub fn prev(it: *@This()) ?ElementPtr {
                    if (it.index == 0) return null;
                    it.index -= 1;
                    if (it.index < prealloc_item_count) return &it.list.prealloc_segment[it.index];
                    if (it.box_index == 0) {
                        it.shelf_index -= 1;
                        it.shelf_size /= 2;
                        it.box_index = it.shelf_size - 1;
                    } else {
                        it.box_index -= 1;
                    }
                    return &it.list.dynamic_segments[it.shelf_index][it.box_index];
                }
                pub fn peek(it: *@This()) ?ElementPtr {
                    if (it.index >= it.list.len)
                        return null;
                    if (it.index < prealloc_item_count)
                        return &it.list.prealloc_segment[it.index];
                    return &it.list.dynamic_segments[it.shelf_index][it.box_index];
                }
                pub fn set(it: *@This(), index: usize) void {
                    it.index = index;
                    if (index < prealloc_item_count) return;
                    it.shelf_index = shelfIndex(index);
                    it.box_index = boxIndex(index, it.shelf_index);
                    it.shelf_size = shelfSize(it.shelf_index);
                }
            };
        }
        pub fn iterator(self: *Self, start_index: usize) Iterator {
            var it = Iterator{
                .list = self,
                .index = undefined,
                .shelf_index = undefined,
                .box_index = undefined,
                .shelf_size = undefined,
            };
            it.set(start_index);
            return it;
        }
        pub fn constIterator(self: *const Self, start_index: usize) ConstIterator {
            var it = ConstIterator{
                .list = self,
                .index = undefined,
                .shelf_index = undefined,
                .box_index = undefined,
                .shelf_size = undefined,
            };
            it.set(start_index);
            return it;
        }
    };
}
test "basic usage" {
    try testSegmentedList(0);
    try testSegmentedList(1);
    try testSegmentedList(2);
    try testSegmentedList(4);
    try testSegmentedList(8);
    try testSegmentedList(16);
}
fn testSegmentedList(comptime prealloc: usize) !void {
    var list = SegmentedList(i32, prealloc){};
    defer list.deinit(testing.allocator);
    {
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            try list.append(testing.allocator, @as(i32, @intCast(i + 1)));
            try testing.expect(list.len == i + 1);
        }
    }
    {
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            try testing.expect(list.at(i).* == @as(i32, @intCast(i + 1)));
        }
    }
    {
        var it = list.iterator(0);
        var x: i32 = 0;
        while (it.next()) |item| {
            x += 1;
            try testing.expect(item.* == x);
        }
        try testing.expect(x == 100);
        while (it.prev()) |item| : (x -= 1) {
            try testing.expect(item.* == x);
        }
        try testing.expect(x == 0);
    }
    {
        var it = list.constIterator(0);
        var x: i32 = 0;
        while (it.next()) |item| {
            x += 1;
            try testing.expect(item.* == x);
        }
        try testing.expect(x == 100);
        while (it.prev()) |item| : (x -= 1) {
            try testing.expect(item.* == x);
        }
        try testing.expect(x == 0);
    }
    try testing.expect(list.pop().? == 100);
    try testing.expect(list.len == 99);
    try list.appendSlice(testing.allocator, &[_]i32{ 1, 2, 3 });
    try testing.expect(list.len == 102);
    try testing.expect(list.pop().? == 3);
    try testing.expect(list.pop().? == 2);
    try testing.expect(list.pop().? == 1);
    try testing.expect(list.len == 99);
    try list.appendSlice(testing.allocator, &[_]i32{});
    try testing.expect(list.len == 99);
    {
        var i: i32 = 99;
        while (list.pop()) |item| : (i -= 1) {
            try testing.expect(item == i);
            list.shrinkCapacity(testing.allocator, list.len);
        }
    }
    {
        var control: [100]i32 = undefined;
        var dest: [100]i32 = undefined;
        var i: i32 = 0;
        while (i < 100) : (i += 1) {
            try list.append(testing.allocator, i + 1);
            control[@as(usize, @intCast(i))] = i + 1;
        }
        @memset(dest[0..], 0);
        list.writeToSlice(dest[0..], 0);
        try testing.expect(mem.eql(i32, control[0..], dest[0..]));
        @memset(dest[0..], 0);
        list.writeToSlice(dest[50..], 50);
        try testing.expect(mem.eql(i32, control[50..], dest[50..]));
    }
    try list.setCapacity(testing.allocator, 0);
}
test "clearRetainingCapacity" {
    var list = SegmentedList(i32, 1){};
    defer list.deinit(testing.allocator);
    try list.appendSlice(testing.allocator, &[_]i32{ 4, 5 });
    list.clearRetainingCapacity();
    try list.append(testing.allocator, 6);
    try testing.expect(list.at(0).* == 6);
    try testing.expect(list.len == 1);
    list.clearRetainingCapacity();
    try testing.expect(list.len == 0);
}
fn log2_int_ceil(comptime T: type, x: T) std.math.Log2Int(T) {
    assert(x != 0);
    const log2_val = std.math.log2_int(T, x);
    if (@as(T, 1) << log2_val == x)
        return log2_val;
    return log2_val + 1;
}
