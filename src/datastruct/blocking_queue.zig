const std = @import("std");
const Allocator = std.mem.Allocator;
const compat_thread = @import("../lib/compat/thread.zig");
pub fn BlockingQueue(
    comptime T: type,
    comptime capacity: usize,
) type {
    return struct {
        const Self = @This();
        pub const Size = u32;
        const bounds: Size = @intCast(capacity);
        pub const Timeout = union(enum) {
            instant: void,
            forever: void,
            ns: u64,
        };
        data: [bounds]T = undefined,
        write: Size = 0,
        read: Size = 0,
        len: Size = 0,
        mutex: std.Io.Mutex = .init,
        cond_not_full: std.Io.Condition = .init,
        not_full_waiters: usize = 0,
        pub fn create(alloc: Allocator) Allocator.Error!*Self {
            const ptr = try alloc.create(Self);
            errdefer alloc.destroy(ptr);
            ptr.* = .{
                .data = undefined,
                .len = 0,
                .write = 0,
                .read = 0,
                .mutex = .init,
                .cond_not_full = .init,
                .not_full_waiters = 0,
            };
            return ptr;
        }
        pub fn destroy(self: *Self, alloc: Allocator) void {
            self.* = undefined;
            alloc.destroy(self);
        }
        pub fn push(self: *Self, io: std.Io, value: T, timeout: Timeout) Size {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.full()) {
                switch (timeout) {
                    .instant => return 0,
                    .forever => {
                        self.not_full_waiters += 1;
                        defer self.not_full_waiters -= 1;
                        self.cond_not_full.waitUncancelable(io, &self.mutex);
                    },
                    .ns => |ns| {
                        self.not_full_waiters += 1;
                        defer self.not_full_waiters -= 1;
                        compat_thread.waitTimeout(
                            &self.cond_not_full,
                            io,
                            &self.mutex,
                            .{
                                .duration = .{
                                    .raw = .fromNanoseconds(ns),
                                    .clock = .awake,
                                },
                            },
                        ) catch return 0;
                    },
                }
                if (self.full()) return 0;
            }
            self.data[self.write] = value;
            self.write += 1;
            if (self.write >= bounds) self.write -= bounds;
            self.len += 1;
            return self.len;
        }
        pub fn pop(self: *Self, io: std.Io) ?T {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.len == 0) return null;
            const n = self.read;
            self.read += 1;
            if (self.read >= bounds) self.read -= bounds;
            self.len -= 1;
            if (self.not_full_waiters > 0) self.cond_not_full.signal(io);
            return self.data[n];
        }
        pub fn drain(self: *Self, io: std.Io) DrainIterator {
            self.mutex.lockUncancelable(io);
            return .{ .queue = self };
        }
        pub const DrainIterator = struct {
            queue: *Self,
            pub fn next(self: *DrainIterator) ?T {
                if (self.queue.len == 0) return null;
                const n = self.queue.read;
                self.queue.read += 1;
                if (self.queue.read >= bounds) self.queue.read -= bounds;
                self.queue.len -= 1;
                return self.queue.data[n];
            }
            pub fn deinit(self: *DrainIterator, io: std.Io) void {
                if (self.queue.not_full_waiters > 0) self.queue.cond_not_full.signal(io);
                self.queue.mutex.unlock(io);
            }
        };
        inline fn full(self: *Self) bool {
            return self.len == bounds;
        }
    };
}
test "basic push and pop" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    const Q = BlockingQueue(u64, 4);
    const q = try Q.create(alloc);
    defer q.destroy(alloc);
    try testing.expect(q.pop(io) == null);
    try testing.expectEqual(@as(Q.Size, 1), q.push(io, 1, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 2), q.push(io, 2, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 3), q.push(io, 3, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 4), q.push(io, 4, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 0), q.push(io, 5, .{ .instant = {} }));
    try testing.expect(q.pop(io).? == 1);
    try testing.expect(q.pop(io).? == 2);
    try testing.expect(q.pop(io).? == 3);
    try testing.expect(q.pop(io).? == 4);
    try testing.expect(q.pop(io) == null);
    var it = q.drain(io);
    try testing.expect(it.next() == null);
    it.deinit(io);
    try testing.expectEqual(@as(Q.Size, 1), q.push(io, 1, .{ .instant = {} }));
}
test "timed push" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    const Q = BlockingQueue(u64, 1);
    const q = try Q.create(alloc);
    defer q.destroy(alloc);
    try testing.expectEqual(@as(Q.Size, 1), q.push(io, 1, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 0), q.push(io, 2, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 0), q.push(io, 2, .{ .ns = 1000 }));
}
