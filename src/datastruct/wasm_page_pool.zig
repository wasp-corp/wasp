const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
pub fn WasmPagePool(comptime Item: type) type {
    return struct {
        const Self = @This();
        comptime {
            if (builtin.target.cpu.arch.isWasm()) {
                assert(builtin.single_threaded);
                assert(item_size > 0);
                assert(item_size % std.heap.page_size_min == 0);
                assert(@alignOf(Item) <= std.heap.page_size_min);
                assert(item_size >= @sizeOf(std.SinglyLinkedList.Node));
            }
        }
        allocator: Allocator,
        pub const item_size = @sizeOf(Item);
        pub const ItemPtr = *align(std.heap.page_size_min) Item;
        var free_list: std.SinglyLinkedList = .{};
        pub fn initCapacity(
            gpa: Allocator,
            allocator: Allocator,
            preheat: usize,
        ) Allocator.Error!Self {
            _ = gpa;
            _ = preheat;
            return .{ .allocator = allocator };
        }
        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }
        pub fn reset(
            self: *Self,
            mode: std.heap.ArenaAllocator.ResetMode,
        ) bool {
            _ = self;
            _ = mode;
            return true;
        }
        pub fn freeCount(self: *const Self) usize {
            _ = self;
            return 0;
        }
        pub fn create(self: *Self) Allocator.Error!ItemPtr {
            _ = self;
            if (free_list.popFirst()) |node| return @ptrCast(@alignCast(node));
            const pages = comptime item_size / std.heap.page_size_min;
            const page_index = @wasmMemoryGrow(0, pages);
            if (page_index == -1) return error.OutOfMemory;
            return @ptrFromInt(@as(usize, @intCast(page_index)) * std.heap.page_size_min);
        }
        pub fn destroy(self: *Self, ptr: ItemPtr) void {
            _ = self;
            const node: *std.SinglyLinkedList.Node = @ptrCast(ptr);
            node.* = .{};
            free_list.prepend(node);
        }
    };
}
test WasmPagePool {
    if (!comptime builtin.target.cpu.arch.isWasm()) return error.SkipZigTest;
    const testing = std.testing;
    const Pool = WasmPagePool([64 * 1024]u8);
    var pool: Pool = try .initCapacity(testing.allocator, testing.allocator, 0);
    defer pool.deinit();
    const a = try pool.create();
    const b = try pool.create();
    try testing.expect(a != b);
    pool.destroy(b);
    try testing.expectEqual(b, try pool.create());
    var pool2: Pool = try .initCapacity(testing.allocator, testing.allocator, 0);
    defer pool2.deinit();
    pool.destroy(a);
    try testing.expectEqual(a, try pool2.create());
    pool.destroy(a);
    pool.destroy(b);
}
