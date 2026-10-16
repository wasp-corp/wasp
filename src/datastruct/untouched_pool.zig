const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
pub fn UntouchedPool(comptime Item: type, comptime alignment: Alignment) type {
    return struct {
        const Self = @This();
        pub const item_size = @sizeOf(Item);
        pub const item_alignment: Alignment = alignment.max(.of(Item));
        pub const ItemPtr = *align(item_alignment.toByteUnits()) Item;
        pub const ResetMode = std.heap.ArenaAllocator.ResetMode;
        allocator: Allocator,
        gpa: Allocator,
        free: std.ArrayList(ItemPtr),
        live: usize,
        pub fn initCapacity(
            gpa: Allocator,
            item_alloc: Allocator,
            preheat: usize,
        ) Allocator.Error!Self {
            var self: Self = .{
                .allocator = item_alloc,
                .gpa = gpa,
                .free = .empty,
                .live = 0,
            };
            errdefer self.deinit();
            try self.free.ensureTotalCapacityPrecise(gpa, preheat);
            for (0..preheat) |_| {
                const item = try self.allocItem();
                self.free.appendAssumeCapacity(item);
            }
            return self;
        }
        pub fn deinit(self: *Self) void {
            assert(self.live == self.free.items.len);
            for (self.free.items) |item| self.allocator.free(bytes(item));
            self.free.deinit(self.gpa);
            self.* = undefined;
        }
        pub fn reset(self: *Self, mode: ResetMode) bool {
            assert(self.live == self.free.items.len);
            const retain_bytes: usize = switch (mode) {
                .free_all => 0,
                .retain_capacity => return true,
                .retain_with_limit => |limit| limit,
            };
            const retain_items = retain_bytes / item_size;
            while (self.free.items.len > retain_items) {
                const item = self.free.pop().?;
                self.allocator.free(bytes(item));
                self.live -= 1;
            }
            return true;
        }
        pub fn freeCount(self: *const Self) usize {
            return self.free.items.len;
        }
        pub fn create(self: *Self) Allocator.Error!ItemPtr {
            if (self.free.pop()) |item| return item;
            try self.free.ensureTotalCapacity(self.gpa, self.live + 1);
            return try self.allocItem();
        }
        pub fn destroy(self: *Self, item: ItemPtr) void {
            assert(self.free.items.len < self.live);
            self.free.appendAssumeCapacity(item);
        }
        pub fn release(self: *Self, item: ItemPtr) void {
            assert(self.free.items.len < self.live);
            self.allocator.free(bytes(item));
            self.live -= 1;
        }
        fn allocItem(self: *Self) Allocator.Error!ItemPtr {
            assert(self.free.capacity > self.live);
            const memory = try self.allocator.alignedAlloc(
                u8,
                item_alignment,
                item_size,
            );
            self.live += 1;
            return @ptrCast(memory.ptr);
        }
        fn bytes(item: ItemPtr) []align(item_alignment.toByteUnits()) u8 {
            return std.mem.asBytes(item);
        }
    };
}
const TestPool = UntouchedPool(
    [std.heap.page_size_min]u8,
    .fromByteUnits(std.heap.page_size_min),
);
test "UntouchedPool: create, destroy, reuse" {
    const testing = std.testing;
    var pool: TestPool = try .initCapacity(testing.allocator, testing.allocator, 0);
    defer pool.deinit();
    const a = try pool.create();
    const b = try pool.create();
    const c = try pool.create();
    try testing.expect(a != b);
    try testing.expect(a != c);
    try testing.expect(b != c);
    try testing.expectEqual(0, pool.freeCount());
    pool.destroy(a);
    pool.destroy(b);
    try testing.expectEqual(2, pool.freeCount());
    try testing.expectEqual(b, try pool.create());
    try testing.expectEqual(a, try pool.create());
    try testing.expectEqual(0, pool.freeCount());
    pool.destroy(a);
    pool.destroy(b);
    pool.destroy(c);
}
test "UntouchedPool: create and destroy never touch items" {
    const testing = std.testing;
    const preheat = 4;
    const backing = try testing.allocator.alignedAlloc(
        u8,
        .fromByteUnits(std.heap.page_size_min),
        preheat * TestPool.item_size,
    );
    defer testing.allocator.free(backing);
    var fba: std.heap.FixedBufferAllocator = .init(backing);
    var pool: TestPool = try .initCapacity(
        testing.allocator,
        fba.allocator(),
        preheat,
    );
    defer pool.deinit();
    try testing.expectEqual(preheat * TestPool.item_size, fba.end_index);
    const sentinel: u8 = 0x5A;
    @memset(backing, sentinel);
    var items: [preheat]TestPool.ItemPtr = undefined;
    for (&items) |*item| {
        item.* = try pool.create();
        try testing.expectEqual(preheat * TestPool.item_size, fba.end_index);
        try testing.expect(std.mem.allEqual(u8, item.*, sentinel));
    }
    for (items) |item| pool.destroy(item);
    try testing.expect(std.mem.allEqual(u8, backing, sentinel));
    for (&items) |*item| {
        item.* = try pool.create();
        try testing.expect(std.mem.allEqual(u8, item.*, sentinel));
    }
    for (items) |item| pool.destroy(item);
}
test "UntouchedPool: destroy never allocates from the general allocator" {
    const testing = std.testing;
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{
        .fail_index = 0,
    });
    var pool: TestPool = try .initCapacity(testing.allocator, testing.allocator, 0);
    defer pool.deinit();
    var items: [64]TestPool.ItemPtr = undefined;
    for (&items) |*item| item.* = try pool.create();
    const gpa = pool.gpa;
    pool.gpa = failing.allocator();
    for (items) |item| pool.destroy(item);
    pool.gpa = gpa;
    try testing.expectEqual(items.len, pool.free.items.len);
}
test "UntouchedPool: reset retains at most the limit" {
    const testing = std.testing;
    var pool: TestPool = try .initCapacity(testing.allocator, testing.allocator, 4);
    defer pool.deinit();
    try testing.expect(pool.reset(.{ .retain_with_limit = 2 * TestPool.item_size }));
    try testing.expectEqual(2, pool.free.items.len);
    try testing.expectEqual(2, pool.live);
    try testing.expect(pool.reset(.retain_capacity));
    try testing.expectEqual(2, pool.free.items.len);
    const a = try pool.create();
    const b = try pool.create();
    try testing.expectEqual(2, pool.live);
    const c = try pool.create();
    try testing.expectEqual(3, pool.live);
    pool.destroy(a);
    pool.destroy(b);
    pool.destroy(c);
    try testing.expect(pool.reset(.free_all));
    try testing.expectEqual(0, pool.free.items.len);
    try testing.expectEqual(0, pool.live);
}
test "UntouchedPool: release frees immediately" {
    const testing = std.testing;
    var pool: TestPool = try .initCapacity(testing.allocator, testing.allocator, 1);
    defer pool.deinit();
    const a = try pool.create();
    const b = try pool.create();
    try testing.expectEqual(2, pool.live);
    pool.release(a);
    try testing.expectEqual(1, pool.live);
    try testing.expectEqual(0, pool.free.items.len);
    pool.destroy(b);
    try testing.expectEqual(1, pool.free.items.len);
}
