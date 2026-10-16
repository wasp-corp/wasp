const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const fastmem = @import("../fastmem.zig");
pub fn CircBuf(comptime T: type, comptime default: T) type {
    return struct {
        const Self = @This();
        storage: []T,
        head: usize,
        tail: usize,
        full: bool,
        pub const Iterator = struct {
            buf: Self,
            idx: usize,
            direction: Direction,
            pub const Direction = enum { forward, reverse };
            pub fn next(self: *Iterator) ?*T {
                if (self.idx >= self.buf.len()) return null;
                const tail_idx = switch (self.direction) {
                    .forward => self.idx,
                    .reverse => self.buf.len() - self.idx - 1,
                };
                const storage_idx = (self.buf.tail + tail_idx) % self.buf.capacity();
                self.idx += 1;
                return &self.buf.storage[storage_idx];
            }
            pub fn seekBy(self: *Iterator, amount: isize) void {
                if (amount > 0) {
                    self.idx +|= @intCast(amount);
                } else {
                    self.idx -|= @intCast(@abs(amount));
                }
            }
            pub fn reset(self: *Iterator) void {
                self.idx = 0;
            }
        };
        pub fn init(alloc: Allocator, size: usize) Allocator.Error!Self {
            const buf = try alloc.alloc(T, size);
            @memset(buf, default);
            return Self{
                .storage = buf,
                .head = 0,
                .tail = 0,
                .full = size == 0,
            };
        }
        pub fn deinit(self: *Self, alloc: Allocator) void {
            alloc.free(self.storage);
            self.* = undefined;
        }
        pub fn append(self: *Self, v: T) Allocator.Error!void {
            if (self.full) return error.OutOfMemory;
            self.storage[self.head] = v;
            self.head += 1;
            if (self.head >= self.storage.len) self.head = 0;
            self.full = self.head == self.tail;
        }
        pub fn appendAssumeCapacity(self: *Self, v: T) void {
            assert(!self.full);
            self.storage[self.head] = v;
            self.head += 1;
            if (self.head >= self.storage.len) self.head = 0;
            self.full = self.head == self.tail;
        }
        pub fn appendSliceAssumeCapacity(
            self: *Self,
            slice: []const T,
        ) void {
            const storage = self.getPtrSlice(
                self.len(),
                slice.len,
            );
            fastmem.copy(T, storage[0], slice[0..storage[0].len]);
            fastmem.copy(T, storage[1], slice[storage[0].len..]);
        }
        pub fn clear(self: *Self) void {
            self.head = 0;
            self.tail = 0;
            self.full = false;
        }
        pub fn iterator(self: Self, direction: Iterator.Direction) Iterator {
            return Iterator{
                .buf = self,
                .idx = 0,
                .direction = direction,
            };
        }
        pub fn first(self: Self) ?*T {
            var it = self.iterator(.forward);
            return it.next();
        }
        pub fn last(self: Self) ?*T {
            var it = self.iterator(.reverse);
            return it.next();
        }
        pub fn ensureUnusedCapacity(
            self: *Self,
            alloc: Allocator,
            amount: usize,
        ) Allocator.Error!void {
            const new_cap = self.len() + amount;
            if (new_cap <= self.capacity()) return;
            try self.resize(alloc, new_cap);
        }
        pub fn resize(self: *Self, alloc: Allocator, size: usize) Allocator.Error!void {
            try self.rotateToZero();
            const prev_len = self.len();
            const prev_cap = self.storage.len;
            self.storage = try alloc.realloc(self.storage, size);
            const retained_len = @min(prev_len, size);
            if (size > prev_cap) {
                @memset(self.storage[prev_cap..], default);
            }
            self.head = if (retained_len == size) 0 else retained_len;
            self.tail = 0;
            self.full = retained_len == size;
        }
        fn rotateToZero(self: *Self) Allocator.Error!void {
            if (self.tail == 0) return;
            std.mem.rotate(T, self.storage, self.tail);
            self.head = self.len() % self.storage.len;
            self.tail = 0;
        }
        pub fn empty(self: Self) bool {
            return !self.full and self.head == self.tail;
        }
        pub fn capacity(self: Self) usize {
            return self.storage.len;
        }
        pub fn len(self: Self) usize {
            if (self.full) return self.storage.len;
            if (self.head >= self.tail) return self.head - self.tail;
            return self.storage.len - (self.tail - self.head);
        }
        pub fn deleteOldest(self: *Self, n: usize) void {
            assert(n <= self.storage.len);
            if (n == 0) {
                @branchHint(.cold);
                return;
            }
            const slices = self.getPtrSlice(0, n);
            inline for (slices) |slice| @memset(slice, default);
            self.tail += @min(self.len(), n);
            if (self.tail >= self.storage.len) self.tail -= self.storage.len;
            self.full = false;
        }
        pub fn getPtrSlice(self: *Self, offset: usize, slice_len: usize) [2][]T {
            if (slice_len == 0) {
                @branchHint(.cold);
                return .{ &.{}, &.{} };
            }
            assert(offset + slice_len <= self.capacity());
            const end_offset = offset + slice_len;
            if (end_offset > self.len()) self.advance(end_offset - self.len());
            const start_idx = self.storageOffset(offset);
            const end_idx = self.storageOffset(end_offset - 1);
            if (end_idx >= start_idx) {
                return .{
                    self.storage[start_idx .. end_idx + 1],
                    self.storage[0..0], 
                };
            }
            return .{
                self.storage[start_idx..],
                self.storage[0 .. end_idx + 1],
            };
        }
        fn advance(self: *Self, amount: usize) void {
            assert(amount <= self.storage.len - self.len());
            self.head += amount;
            if (self.head >= self.storage.len) self.head = self.head - self.storage.len;
            if (self.full) self.tail = self.head;
            self.full = self.head == self.tail;
        }
        fn storageOffset(self: Self, offset: usize) usize {
            assert(offset < self.storage.len);
            const fits_offset = self.tail + offset;
            if (fits_offset < self.storage.len) return fits_offset;
            return fits_offset - self.storage.len;
        }
    };
}
test {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 12);
    defer buf.deinit(alloc);
    try testing.expect(buf.empty());
    try testing.expectEqual(@as(usize, 0), buf.len());
}
test "CircBuf append" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 3);
    defer buf.deinit(alloc);
    try buf.append(1);
    try buf.append(2);
    try buf.append(3);
    try testing.expectError(error.OutOfMemory, buf.append(4));
    buf.deleteOldest(1);
    try buf.append(4);
    try testing.expectError(error.OutOfMemory, buf.append(5));
}
test "CircBuf forward iterator" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 3);
    defer buf.deinit(alloc);
    {
        var it = buf.iterator(.forward);
        try testing.expect(it.next() == null);
    }
    try buf.append(1);
    try buf.append(2);
    {
        var it = buf.iterator(.forward);
        try testing.expect(it.next().?.* == 1);
        try testing.expect(it.next().?.* == 2);
        try testing.expect(it.next() == null);
    }
    try buf.append(3);
    {
        var it = buf.iterator(.forward);
        try testing.expect(it.next().?.* == 1);
        try testing.expect(it.next().?.* == 2);
        try testing.expect(it.next().?.* == 3);
        try testing.expect(it.next() == null);
    }
    buf.deleteOldest(1);
    try buf.append(4);
    {
        var it = buf.iterator(.forward);
        try testing.expect(it.next().?.* == 2);
        try testing.expect(it.next().?.* == 3);
        try testing.expect(it.next().?.* == 4);
        try testing.expect(it.next() == null);
    }
}
test "CircBuf reverse iterator" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 3);
    defer buf.deinit(alloc);
    {
        var it = buf.iterator(.reverse);
        try testing.expect(it.next() == null);
    }
    try buf.append(1);
    try buf.append(2);
    {
        var it = buf.iterator(.reverse);
        try testing.expect(it.next().?.* == 2);
        try testing.expect(it.next().?.* == 1);
        try testing.expect(it.next() == null);
    }
    try buf.append(3);
    {
        var it = buf.iterator(.reverse);
        try testing.expect(it.next().?.* == 3);
        try testing.expect(it.next().?.* == 2);
        try testing.expect(it.next().?.* == 1);
        try testing.expect(it.next() == null);
    }
    buf.deleteOldest(1);
    try buf.append(4);
    {
        var it = buf.iterator(.reverse);
        try testing.expect(it.next().?.* == 4);
        try testing.expect(it.next().?.* == 3);
        try testing.expect(it.next().?.* == 2);
        try testing.expect(it.next() == null);
    }
}
test "CircBuf first/last" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 3);
    defer buf.deinit(alloc);
    try buf.append(1);
    try buf.append(2);
    try buf.append(3);
    try testing.expectEqual(3, buf.last().?.*);
    try testing.expectEqual(1, buf.first().?.*);
}
test "CircBuf first/last empty" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 0);
    defer buf.deinit(alloc);
    try testing.expect(buf.first() == null);
    try testing.expect(buf.last() == null);
}
test "CircBuf first/last empty with cap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 3);
    defer buf.deinit(alloc);
    try testing.expect(buf.first() == null);
    try testing.expect(buf.last() == null);
}
test "CircBuf append slice" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 5);
    defer buf.deinit(alloc);
    buf.appendSliceAssumeCapacity("hello");
    {
        var it = buf.iterator(.forward);
        try testing.expect(it.next().?.* == 'h');
        try testing.expect(it.next().?.* == 'e');
        try testing.expect(it.next().?.* == 'l');
        try testing.expect(it.next().?.* == 'l');
        try testing.expect(it.next().?.* == 'o');
        try testing.expect(it.next() == null);
    }
}
test "CircBuf append slice with wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 4);
    defer buf.deinit(alloc);
    _ = buf.getPtrSlice(0, buf.capacity());
    try testing.expect(buf.full);
    try testing.expectEqual(@as(usize, 4), buf.len());
    buf.deleteOldest(2);
    try testing.expect(!buf.full);
    try testing.expectEqual(@as(usize, 2), buf.len());
    buf.appendSliceAssumeCapacity("AB");
    {
        var it = buf.iterator(.forward);
        try testing.expect(it.next().?.* == 0);
        try testing.expect(it.next().?.* == 0);
        try testing.expect(it.next().?.* == 'A');
        try testing.expect(it.next().?.* == 'B');
        try testing.expect(it.next() == null);
    }
}
test "CircBuf getPtrSlice fits" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 12);
    defer buf.deinit(alloc);
    const slices = buf.getPtrSlice(0, 11);
    try testing.expectEqual(@as(usize, 11), slices[0].len);
    try testing.expectEqual(@as(usize, 0), slices[1].len);
    try testing.expectEqual(@as(usize, 11), buf.len());
}
test "CircBuf getPtrSlice wraps" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 4);
    defer buf.deinit(alloc);
    _ = buf.getPtrSlice(0, buf.capacity());
    try testing.expect(buf.full);
    try testing.expectEqual(@as(usize, 4), buf.len());
    buf.deleteOldest(2);
    try testing.expect(!buf.full);
    try testing.expectEqual(@as(usize, 2), buf.len());
    {
        const slices = buf.getPtrSlice(0, 2);
        try testing.expectEqual(@as(usize, 2), slices[0].len);
        try testing.expectEqual(@as(usize, 0), slices[1].len);
        try testing.expectEqual(@as(usize, 2), buf.len());
        slices[0][0] = 1;
        slices[0][1] = 2;
    }
    {
        const slices = buf.getPtrSlice(2, 2);
        try testing.expectEqual(@as(usize, 2), slices[0].len);
        try testing.expectEqual(@as(usize, 0), slices[1].len);
        try testing.expectEqual(@as(usize, 4), buf.len());
        try testing.expectEqual(@as(u8, 0), slices[0][0]);
        try testing.expectEqual(@as(u8, 0), slices[0][1]);
        slices[0][0] = 3;
        slices[0][1] = 4;
    }
    {
        const slices = buf.getPtrSlice(0, 4);
        try testing.expectEqual(@as(usize, 2), slices[0].len);
        try testing.expectEqual(@as(usize, 2), slices[1].len);
        try testing.expectEqual(@as(usize, 4), buf.len());
        try testing.expectEqual(@as(u8, 1), slices[0][0]);
        try testing.expectEqual(@as(u8, 2), slices[0][1]);
        try testing.expectEqual(@as(u8, 3), slices[1][0]);
        try testing.expectEqual(@as(u8, 4), slices[1][1]);
    }
}
test "CircBuf rotateToZero" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 12);
    defer buf.deinit(alloc);
    _ = buf.getPtrSlice(0, 11);
    try buf.rotateToZero();
}
test "CircBuf rotateToZero offset" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 4);
    defer buf.deinit(alloc);
    _ = buf.getPtrSlice(0, 3);
    try testing.expectEqual(@as(usize, 3), buf.len());
    buf.deleteOldest(2);
    try testing.expect(!buf.full);
    try testing.expectEqual(@as(usize, 1), buf.len());
    try testing.expect(buf.tail > 0 and buf.head >= buf.tail);
    try buf.rotateToZero();
    try testing.expectEqual(@as(usize, 0), buf.tail);
    try testing.expectEqual(@as(usize, 1), buf.head);
}
test "CircBuf rotateToZero wraps" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 4);
    defer buf.deinit(alloc);
    _ = buf.getPtrSlice(0, 3);
    try testing.expectEqual(@as(usize, 3), buf.len());
    try testing.expect(buf.tail == 0 and buf.head == 3);
    buf.deleteOldest(3);
    try testing.expectEqual(@as(usize, 0), buf.len());
    try testing.expect(buf.tail == 3 and buf.head == 3);
    {
        const slices = buf.getPtrSlice(0, 3);
        slices[0][0] = 1;
        slices[1][0] = 2;
        slices[1][1] = 3;
        try testing.expectEqual(@as(usize, 3), buf.len());
        try testing.expect(buf.tail == 3 and buf.head == 2);
    }
    try buf.rotateToZero();
    try testing.expectEqual(@as(usize, 0), buf.tail);
    try testing.expectEqual(@as(usize, 3), buf.head);
    {
        const slices = buf.getPtrSlice(0, 3);
        try testing.expectEqual(@as(u8, 1), slices[0][0]);
        try testing.expectEqual(@as(u8, 2), slices[0][1]);
        try testing.expectEqual(@as(u8, 3), slices[0][2]);
    }
}
test "CircBuf rotateToZero full no wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 4);
    defer buf.deinit(alloc);
    _ = buf.getPtrSlice(0, 3);
    buf.deleteOldest(3);
    {
        const slices = buf.getPtrSlice(0, 4);
        try testing.expect(buf.full);
        slices[0][0] = 1;
        slices[1][0] = 2;
        slices[1][1] = 3;
        slices[1][2] = 4;
    }
    try buf.rotateToZero();
    try testing.expect(buf.full);
    try testing.expectEqual(@as(usize, 0), buf.tail);
    try testing.expectEqual(@as(usize, 0), buf.head);
    {
        const slices = buf.getPtrSlice(0, 4);
        try testing.expectEqual(@as(u8, 1), slices[0][0]);
        try testing.expectEqual(@as(u8, 2), slices[0][1]);
        try testing.expectEqual(@as(u8, 3), slices[0][2]);
        try testing.expectEqual(@as(u8, 4), slices[0][3]);
    }
}
test "CircBuf resize grow from zero" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 0);
    defer buf.deinit(alloc);
    try testing.expect(buf.full);
    try buf.resize(alloc, 2);
    try testing.expect(!buf.full);
    try testing.expectEqual(@as(usize, 0), buf.len());
    try testing.expectEqual(@as(usize, 2), buf.capacity());
    try buf.append(1);
    try buf.append(2);
    {
        const slices = buf.getPtrSlice(0, 2);
        try testing.expectEqual(@as(u8, 1), slices[0][0]);
        try testing.expectEqual(@as(u8, 2), slices[0][1]);
    }
}
test "CircBuf resize grow" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 4);
    defer buf.deinit(alloc);
    {
        const slices = buf.getPtrSlice(0, 4);
        try testing.expect(buf.full);
        slices[0][0] = 1;
        slices[0][1] = 2;
        slices[0][2] = 3;
        slices[0][3] = 4;
    }
    try buf.resize(alloc, 6);
    try testing.expect(!buf.full);
    try testing.expectEqual(@as(usize, 4), buf.len());
    try testing.expectEqual(@as(usize, 6), buf.capacity());
    {
        const slices = buf.getPtrSlice(0, 4);
        try testing.expectEqual(@as(u8, 1), slices[0][0]);
        try testing.expectEqual(@as(u8, 2), slices[0][1]);
        try testing.expectEqual(@as(u8, 3), slices[0][2]);
        try testing.expectEqual(@as(u8, 4), slices[0][3]);
    }
}
test "CircBuf resize shrink" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 4);
    defer buf.deinit(alloc);
    {
        const slices = buf.getPtrSlice(0, 4);
        try testing.expect(buf.full);
        slices[0][0] = 1;
        slices[0][1] = 2;
        slices[0][2] = 3;
        slices[0][3] = 4;
    }
    try buf.resize(alloc, 3);
    try testing.expect(buf.full);
    try testing.expectEqual(@as(usize, 3), buf.len());
    try testing.expectEqual(@as(usize, 3), buf.capacity());
    {
        const slices = buf.getPtrSlice(0, 3);
        try testing.expectEqual(@as(u8, 1), slices[0][0]);
        try testing.expectEqual(@as(u8, 2), slices[0][1]);
        try testing.expectEqual(@as(u8, 3), slices[0][2]);
    }
}
test "CircBuf resize shrink partially full" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 5);
    defer buf.deinit(alloc);
    try buf.append(1);
    try buf.append(2);
    try buf.append(3);
    try buf.resize(alloc, 2);
    try testing.expect(buf.full);
    try testing.expectEqual(@as(usize, 2), buf.len());
    try testing.expectEqual(@as(usize, 2), buf.capacity());
    var it = buf.iterator(.forward);
    try testing.expectEqual(@as(u8, 1), it.next().?.*);
    try testing.expectEqual(@as(u8, 2), it.next().?.*);
    try testing.expect(it.next() == null);
    try testing.expectError(error.OutOfMemory, buf.append(4));
}
test "CircBuf resize shrink to length" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 5);
    defer buf.deinit(alloc);
    try buf.append(1);
    try buf.append(2);
    try buf.resize(alloc, 2);
    try testing.expect(buf.full);
    try testing.expectEqual(@as(usize, 2), buf.len());
    try testing.expectEqual(@as(usize, 2), buf.capacity());
}
test "CircBuf resize empty to zero" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 5);
    defer buf.deinit(alloc);
    try buf.resize(alloc, 0);
    try testing.expect(buf.full);
    try testing.expectEqual(@as(usize, 0), buf.len());
    try testing.expectEqual(@as(usize, 0), buf.capacity());
}
test "CircBuf append empty slice" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 5);
    defer buf.deinit(alloc);
    buf.appendSliceAssumeCapacity("");
    try testing.expectEqual(@as(usize, 0), buf.len());
    try testing.expect(!buf.full);
    buf.appendSliceAssumeCapacity("hi");
    try testing.expectEqual(@as(usize, 2), buf.len());
    buf.appendSliceAssumeCapacity("");
    try testing.expectEqual(@as(usize, 2), buf.len());
}
test "CircBuf getPtrSlice zero length" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 5);
    defer buf.deinit(alloc);
    const slices = buf.getPtrSlice(0, 0);
    try testing.expectEqual(@as(usize, 0), slices[0].len);
    try testing.expectEqual(@as(usize, 0), slices[1].len);
    try testing.expectEqual(@as(usize, 0), buf.len());
    buf.appendSliceAssumeCapacity("abc");
    try testing.expectEqual(@as(usize, 3), buf.len());
    const slices2 = buf.getPtrSlice(0, 0);
    try testing.expectEqual(@as(usize, 0), slices2[0].len);
    try testing.expectEqual(@as(usize, 0), slices2[1].len);
    try testing.expectEqual(@as(usize, 3), buf.len());
}
test "CircBuf deleteOldest zero" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Buf = CircBuf(u8, 0);
    var buf = try Buf.init(alloc, 5);
    defer buf.deinit(alloc);
    buf.deleteOldest(0);
    try testing.expectEqual(@as(usize, 0), buf.len());
    buf.appendSliceAssumeCapacity("hello");
    try testing.expectEqual(@as(usize, 5), buf.len());
    buf.deleteOldest(0);
    try testing.expectEqual(@as(usize, 5), buf.len());
    var it = buf.iterator(.forward);
    try testing.expectEqual(@as(u8, 'h'), it.next().?.*);
}
