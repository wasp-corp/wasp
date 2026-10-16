const std = @import("std");
pub fn FuzzAllocator(comptime mem_size: usize) type {
    return struct {
        buf: [mem_size]u8 = undefined,
        state: std.heap.FixedBufferAllocator = undefined,
        const Self = @This();
        pub fn init(self: *Self) void {
            self.state = .init(&self.buf);
        }
        pub fn allocator(self: *Self) std.mem.Allocator {
            return self.state.allocator();
        }
        pub fn reset(self: *Self) void {
            self.state.reset();
        }
    };
}
