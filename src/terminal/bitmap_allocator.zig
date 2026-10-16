const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const size = @import("size.zig");
const getOffset = size.getOffset;
const Offset = size.Offset;
const OffsetBuf = size.OffsetBuf;
const alignForward = std.mem.alignForward;
pub fn BitmapAllocator(comptime chunk_size: comptime_int) type {
    return struct {
        const Self = @This();
        comptime {
            assert(std.math.isPowerOfTwo(chunk_size));
        }
        pub const base_align: std.mem.Alignment = .fromByteUnits(@alignOf(u64));
        pub const bitmap_bit_size = @bitSizeOf(u64);
        bitmap: Offset(u64),
        bitmap_count: usize,
        search_start: usize = 0,
        chunks: Offset(u8),
        pub fn init(buf: OffsetBuf, l: Layout) Self {
            assert(base_align.check(@intFromPtr(buf.start())));
            const bitmap = buf.member(u64, l.bitmap_start);
            @memset(bitmap.ptr(buf)[0..l.bitmap_count], 0);
            return initAssumeZeroed(buf, l);
        }
        pub fn initAssumeZeroed(buf: OffsetBuf, l: Layout) Self {
            assert(base_align.check(@intFromPtr(buf.start())));
            return .{
                .bitmap = buf.member(u64, l.bitmap_start),
                .bitmap_count = l.bitmap_count,
                .chunks = buf.member(u8, l.chunks_start),
            };
        }
        pub fn bytesRequired(comptime T: type, n: usize) usize {
            const byte_count = @sizeOf(T) * n;
            return alignForward(usize, byte_count, chunk_size);
        }
        pub fn alloc(
            self: *Self,
            comptime T: type,
            base: anytype,
            n: usize,
        ) Allocator.Error![]T {
            assert(chunk_size % @alignOf(T) == 0);
            assert(n > 0);
            const byte_count = std.math.mul(usize, @sizeOf(T), n) catch
                return error.OutOfMemory;
            const chunk_count = std.math.divCeil(usize, byte_count, chunk_size) catch
                return error.OutOfMemory;
            const bitmaps = self.bitmap.ptr(base);
            const start = @min(self.search_start, self.bitmap_count);
            const rel = findFreeChunks(bitmaps[start..self.bitmap_count], chunk_count) orelse
                return error.OutOfMemory;
            const idx = start * bitmap_bit_size + rel;
            self.search_start = start: {
                var new_start = start;
                while (new_start < self.bitmap_count and
                    bitmaps[new_start] == std.math.maxInt(u64))
                {
                    new_start += 1;
                }
                break :start new_start;
            };
            const chunks = self.chunks.ptr(base);
            const ptr: [*]T = @ptrCast(@alignCast(&chunks[idx * chunk_size]));
            return ptr[0..n];
        }
        pub fn free(self: *Self, base: anytype, slice: anytype) void {
            const bytes = std.mem.sliceAsBytes(slice);
            const aligned_len = std.mem.alignForward(usize, bytes.len, chunk_size);
            const chunk_count = @divExact(aligned_len, chunk_size);
            const chunks = self.chunks.ptr(base);
            const chunk_idx = @divExact(@intFromPtr(slice.ptr) - @intFromPtr(chunks), chunk_size);
            self.search_start = @min(
                self.search_start,
                @divFloor(chunk_idx, bitmap_bit_size),
            );
            const bitmaps = self.bitmap.ptr(base);
            var i: usize = @divFloor(chunk_idx, 64);
            var rem: usize = chunk_count;
            {
                const bit = chunk_idx % 64;
                const bits = @min(rem, 64 - bit);
                bitmaps[i] &= ~(~@as(u64, 0) >> @intCast(64 - bits) << @intCast(bit));
                rem -= bits;
            }
            i += 1;
            while (rem > 64) : (i += 1) {
                bitmaps[i] = 0;
                rem -= 64;
            }
            if (rem > 0) {
                bitmaps[i] &= ~(~@as(u64, 0) >> @intCast(64 - rem));
            }
        }
        pub fn capacityBytes(self: Self) usize {
            return self.bitmap_count * bitmap_bit_size * chunk_size;
        }
        pub fn usedBytes(self: Self, base: anytype) usize {
            const bitmaps = self.bitmap.ptr(base);
            var used_chunks: usize = 0;
            for (bitmaps[0..self.bitmap_count]) |bitmap| used_chunks += @popCount(bitmap);
            return used_chunks * chunk_size;
        }
        fn isAllocated(self: *Self, base: anytype, slice: anytype) bool {
            comptime assert(@import("builtin").is_test);
            const bytes = std.mem.sliceAsBytes(slice);
            const aligned_len = std.mem.alignForward(usize, bytes.len, chunk_size);
            const chunk_count = @divExact(aligned_len, chunk_size);
            const chunks = self.chunks.ptr(base);
            const chunk_idx = @divExact(@intFromPtr(slice.ptr) - @intFromPtr(chunks), chunk_size);
            const bitmaps = self.bitmap.ptr(base);
            for (chunk_idx..chunk_idx + chunk_count) |i| {
                const bitmap = @divFloor(i, bitmap_bit_size);
                const bit = i % bitmap_bit_size;
                if (bitmaps[bitmap] & (@as(u64, 1) << @intCast(bit)) == 0) {
                    return false;
                }
            }
            return true;
        }
        fn dumpBitmaps(self: *Self, base: anytype) void {
            const bitmaps = self.bitmap.ptr(base);
            for (bitmaps[0..self.bitmap_count], 0..) |bitmap, idx| {
                std.log.warn("bm={b} idx={}", .{ bitmap, idx });
            }
        }
        pub const Layout = struct {
            total_size: usize,
            bitmap_count: usize,
            bitmap_start: usize,
            chunks_start: usize,
        };
        pub fn layout(cap: usize) Layout {
            const aligned_cap = alignForward(usize, cap, chunk_size);
            const chunk_count = @divExact(aligned_cap, chunk_size);
            const aligned_chunk_count = alignForward(usize, chunk_count, 64);
            const bitmap_count = @divExact(aligned_chunk_count, 64);
            const bitmap_start = 0;
            const bitmap_end = @sizeOf(u64) * bitmap_count;
            const chunks_start = alignForward(usize, bitmap_end, @alignOf(u8));
            const chunks_end = chunks_start + (aligned_chunk_count * chunk_size);
            const total_size = chunks_end;
            return Layout{
                .total_size = total_size,
                .bitmap_count = bitmap_count,
                .bitmap_start = bitmap_start,
                .chunks_start = chunks_start,
            };
        }
    };
}
fn findFreeChunks(bitmaps: []u64, n: usize) ?usize {
    if (n > @bitSizeOf(u64)) {
        var i: usize = 0;
        search: while (i < bitmaps.len) {
            const prefix = @clz(bitmaps[i]);
            if (prefix == 0) {
                i += 1;
                continue;
            }
            const start_bitmap = i;
            const start_bit = 64 - prefix;
            var rem: usize = n - prefix;
            i += 1;
            while (rem > 64) : (i += 1) {
                if (i >= bitmaps.len) return null;
                if (bitmaps[i] != 0) continue :search;
                rem -= 64;
            }
            if (@ctz(bitmaps[i]) < rem) continue;
            const suffix = (n - prefix) % 64;
            bitmaps[start_bitmap] |= ~@as(u64, 0) >> @intCast(start_bit) << @intCast(start_bit);
            const full_bitmaps = @divFloor(n - prefix - suffix, 64);
            for (bitmaps[start_bitmap + 1 ..][0..full_bitmaps]) |*bitmap| {
                bitmap.* = std.math.maxInt(u64);
            }
            if (suffix > 0) bitmaps[i] |= ~@as(u64, 0) >> @intCast(64 - suffix);
            return start_bitmap * 64 + start_bit;
        }
        return null;
    }
    assert(n <= @bitSizeOf(u64));
    for (bitmaps, 0..) |*bitmap, idx| {
        const free = ~bitmap.*;
        var shifted: u64 = free;
        for (1..n) |i| shifted &= free >> @intCast(i);
        if (shifted == 0) continue;
        const bit = @ctz(shifted);
        const mask = (@as(u64, std.math.maxInt(u64)) >> @intCast(64 - n)) << @intCast(bit);
        bitmap.* |= mask;
        return (idx * 64) + bit;
    }
    return null;
}
test "findFreeChunks single found" {
    const testing = std.testing;
    var bitmaps = [_]u64{
        0b01111111_11111111_11111111_11111111_11111111_11111111_11110001_11111111,
    };
    const idx = findFreeChunks(&bitmaps, 2).?;
    try testing.expectEqual(@as(usize, 9), idx);
    try testing.expectEqual(
        0b01111111_11111111_11111111_11111111_11111111_11111111_11110111_11111111,
        bitmaps[0],
    );
}
test "findFreeChunks single not found" {
    const testing = std.testing;
    var bitmaps = [_]u64{0b01111000_11111111_11111111_11111111_11111111_11111111_11111111_11111111};
    const idx = findFreeChunks(&bitmaps, 4);
    try testing.expect(idx == null);
}
test "findFreeChunks multiple found" {
    const testing = std.testing;
    var bitmaps = [_]u64{
        0b01111000_11111111_11111111_11111111_11111111_11111111_11111111_10001111,
        0b01111111_11000001_11111111_11111111_11111111_11111111_11000001_11111111,
    };
    const idx = findFreeChunks(&bitmaps, 4).?;
    try testing.expectEqual(@as(usize, 73), idx);
    try testing.expectEqual(
        0b01111111_11000001_11111111_11111111_11111111_11111111_11011111_11111111,
        bitmaps[1],
    );
}
test "findFreeChunks exactly 64 chunks" {
    const testing = std.testing;
    var bitmaps = [_]u64{
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
    };
    const idx = findFreeChunks(&bitmaps, 64).?;
    try testing.expectEqual(
        0b11111111_11111111_11111111_11111111_11111111_11111111_11111111_11111111,
        bitmaps[0],
    );
    try testing.expectEqual(@as(usize, 0), idx);
}
test "findFreeChunks larger than 64 chunks" {
    const testing = std.testing;
    var bitmaps = [_]u64{
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
    };
    const idx = findFreeChunks(&bitmaps, 65).?;
    try testing.expectEqual(
        0b11111111_11111111_11111111_11111111_11111111_11111111_11111111_11111111,
        bitmaps[0],
    );
    try testing.expectEqual(
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000001,
        bitmaps[1],
    );
    try testing.expectEqual(@as(usize, 0), idx);
}
test "findFreeChunks larger than 64 chunks not at beginning" {
    const testing = std.testing;
    var bitmaps = [_]u64{
        0b00000000_11111111_11111111_11111111_11111111_11111111_11111111_11111111,
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
    };
    const idx = findFreeChunks(&bitmaps, 65).?;
    try testing.expectEqual(
        0b11111111_11111111_11111111_11111111_11111111_11111111_11111111_11111111,
        bitmaps[0],
    );
    try testing.expectEqual(
        0b00000001_11111111_11111111_11111111_11111111_11111111_11111111_11111111,
        bitmaps[1],
    );
    try testing.expectEqual(
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        bitmaps[2],
    );
    try testing.expectEqual(@as(usize, 56), idx);
}
test "findFreeChunks larger than 64 chunks exact" {
    const testing = std.testing;
    var bitmaps = [_]u64{
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
    };
    const idx = findFreeChunks(&bitmaps, 128).?;
    try testing.expectEqual(
        0b11111111_11111111_11111111_11111111_11111111_11111111_11111111_11111111,
        bitmaps[0],
    );
    try testing.expectEqual(
        0b11111111_11111111_11111111_11111111_11111111_11111111_11111111_11111111,
        bitmaps[1],
    );
    try testing.expectEqual(@as(usize, 0), idx);
}
test "BitmapAllocator layout" {
    const Alloc = BitmapAllocator(4);
    const cap = 64 * 4;
    const testing = std.testing;
    const layout = Alloc.layout(cap);
    try testing.expectEqual(@as(usize, 1), layout.bitmap_count);
}
test "BitmapAllocator layout chunks region matches bitmap addressable bytes" {
    const testing = std.testing;
    inline for (.{ 1, 2, 4, 16, 32 }) |chunk| {
        const Alloc = BitmapAllocator(chunk);
        for ([_]usize{
            1,
            chunk,
            chunk + 1,
            48,
            64,
            512,
            1024,
            2048,
            8192,
            8193,
        }) |cap| {
            const layout = Alloc.layout(cap);
            const chunks_size = layout.total_size - layout.chunks_start;
            try testing.expectEqual(
                layout.bitmap_count * Alloc.bitmap_bit_size * chunk,
                chunks_size,
            );
            try testing.expect(chunks_size >= cap);
        }
    }
}
test "BitmapAllocator layout small capacity cannot alloc out of bounds" {
    const Alloc = BitmapAllocator(16);
    const cap = 48; 
    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);
    var bm = Alloc.init(.init(buf), layout);
    const buf_start = @intFromPtr(buf.ptr);
    const buf_end = buf_start + buf.len;
    var count: usize = 0;
    while (bm.alloc(u8, buf, 16)) |slice| {
        try testing.expect(@intFromPtr(slice.ptr) >= buf_start);
        try testing.expect(@intFromPtr(slice.ptr) + slice.len <= buf_end);
        @memset(slice, 0xAA);
        count += 1;
    } else |err| {
        try testing.expectEqual(error.OutOfMemory, err);
    }
    try testing.expectEqual(Alloc.bitmap_bit_size, count);
}
test "BitmapAllocator alloc sequentially" {
    const Alloc = BitmapAllocator(4);
    const cap = 64;
    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);
    var bm = Alloc.init(.init(buf), layout);
    const ptr = try bm.alloc(u8, buf, 1);
    ptr[0] = 'A';
    const ptr2 = try bm.alloc(u8, buf, 1);
    try testing.expect(@intFromPtr(ptr.ptr) != @intFromPtr(ptr2.ptr));
    try testing.expectEqual(@intFromPtr(ptr.ptr) + 4, @intFromPtr(ptr2.ptr));
    bm.free(buf, ptr);
    const ptr3 = try bm.alloc(u8, buf, 1);
    try testing.expectEqual(@intFromPtr(ptr.ptr), @intFromPtr(ptr3.ptr));
}
test "BitmapAllocator alloc non-byte" {
    const Alloc = BitmapAllocator(4);
    const cap = 128;
    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);
    var bm = Alloc.init(.init(buf), layout);
    const ptr = try bm.alloc(u21, buf, 1);
    ptr[0] = 'A';
    const ptr2 = try bm.alloc(u21, buf, 1);
    try testing.expect(@intFromPtr(ptr.ptr) != @intFromPtr(ptr2.ptr));
    try testing.expectEqual(@intFromPtr(ptr.ptr) + 4, @intFromPtr(ptr2.ptr));
    bm.free(buf, ptr);
    const ptr3 = try bm.alloc(u21, buf, 1);
    try testing.expectEqual(@intFromPtr(ptr.ptr), @intFromPtr(ptr3.ptr));
}
test "BitmapAllocator alloc non-byte multi-chunk" {
    const Alloc = BitmapAllocator(4 * @sizeOf(u21));
    const cap = 128;
    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);
    var bm = Alloc.init(.init(buf), layout);
    const ptr = try bm.alloc(u21, buf, 6);
    try testing.expectEqual(@as(usize, 6), ptr.len);
    for (ptr) |*v| v.* = 'A';
    const ptr2 = try bm.alloc(u21, buf, 1);
    try testing.expect(@intFromPtr(ptr.ptr) != @intFromPtr(ptr2.ptr));
    try testing.expectEqual(@intFromPtr(ptr.ptr) + (@sizeOf(u21) * 4 * 2), @intFromPtr(ptr2.ptr));
    bm.free(buf, ptr);
    const ptr3 = try bm.alloc(u21, buf, 1);
    try testing.expectEqual(@intFromPtr(ptr.ptr), @intFromPtr(ptr3.ptr));
}
test "BitmapAllocator alloc large" {
    const Alloc = BitmapAllocator(2);
    const cap = 256;
    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);
    var bm = Alloc.init(.init(buf), layout);
    const ptr = try bm.alloc(u8, buf, 129);
    ptr[0] = 'A';
    bm.free(buf, ptr);
}
test "BitmapAllocator alloc and free one bitmap" {
    const Alloc = BitmapAllocator(1);
    const cap = Alloc.bitmap_bit_size * 3;
    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);
    var bm = Alloc.init(.init(buf), layout);
    const slice = try bm.alloc(u8, buf, Alloc.bitmap_bit_size);
    try testing.expectEqual(Alloc.bitmap_bit_size, slice.len);
    @memset(slice, 0x11);
    try testing.expectEqualSlices(
        u8,
        &@as([Alloc.bitmap_bit_size]u8, @splat(0x11)),
        slice,
    );
    try testing.expect(bm.isAllocated(buf, slice));
    bm.free(buf, slice);
    try testing.expect(!bm.isAllocated(buf, slice));
    try testing.expectEqualSlices(
        u64,
        &@as([3]u64, @splat(0)),
        bm.bitmap.ptr(buf)[0..3],
    );
}
test "BitmapAllocator search hint skips full words" {
    const Alloc = BitmapAllocator(1);
    const cap = Alloc.bitmap_bit_size * 3;
    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);
    var bm = Alloc.init(.init(buf), layout);
    try testing.expectEqual(@as(usize, 0), bm.search_start);
    var first: []u8 = undefined;
    for (0..Alloc.bitmap_bit_size) |i| {
        const slice = try bm.alloc(u8, buf, 1);
        if (i == 0) first = slice;
    }
    try testing.expectEqual(@as(usize, 1), bm.search_start);
    const next = try bm.alloc(u8, buf, 1);
    try testing.expectEqual(
        @intFromPtr(first.ptr) + Alloc.bitmap_bit_size,
        @intFromPtr(next.ptr),
    );
    bm.free(buf, first);
    try testing.expectEqual(@as(usize, 0), bm.search_start);
    const again = try bm.alloc(u8, buf, 1);
    try testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(again.ptr));
}
test "BitmapAllocator search hint does not skip partial words" {
    const Alloc = BitmapAllocator(1);
    const cap = Alloc.bitmap_bit_size * 2;
    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);
    var bm = Alloc.init(.init(buf), layout);
    var first: []u8 = undefined;
    for (0..Alloc.bitmap_bit_size - 4) |i| {
        const slice = try bm.alloc(u8, buf, 1);
        if (i == 0) first = slice;
    }
    const big = try bm.alloc(u8, buf, 8);
    try testing.expectEqual(
        @intFromPtr(first.ptr) + Alloc.bitmap_bit_size,
        @intFromPtr(big.ptr),
    );
    try testing.expectEqual(@as(usize, 0), bm.search_start);
    const small = try bm.alloc(u8, buf, 4);
    try testing.expectEqual(
        @intFromPtr(first.ptr) + Alloc.bitmap_bit_size - 4,
        @intFromPtr(small.ptr),
    );
    try testing.expectEqual(@as(usize, 1), bm.search_start);
}
test "BitmapAllocator alloc and free half bitmap" {
    const Alloc = BitmapAllocator(1);
    const cap = Alloc.bitmap_bit_size * 3;
    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);
    var bm = Alloc.init(.init(buf), layout);
    const slice = try bm.alloc(u8, buf, Alloc.bitmap_bit_size / 2);
    try testing.expectEqual(Alloc.bitmap_bit_size / 2, slice.len);
    @memset(slice, 0x11);
    try testing.expectEqualSlices(
        u8,
        &@as([Alloc.bitmap_bit_size / 2]u8, @splat(0x11)),
        slice,
    );
    try testing.expect(bm.isAllocated(buf, slice));
    bm.free(buf, slice);
    try testing.expect(!bm.isAllocated(buf, slice));
    try testing.expectEqualSlices(
        u64,
        &@as([3]u64, @splat(0)),
        bm.bitmap.ptr(buf)[0..3],
    );
}
test "BitmapAllocator alloc and free two half bitmaps" {
    const Alloc = BitmapAllocator(1);
    const cap = Alloc.bitmap_bit_size * 3;
    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);
    var bm = Alloc.init(.init(buf), layout);
    const slice = try bm.alloc(u8, buf, Alloc.bitmap_bit_size / 2);
    try testing.expectEqual(Alloc.bitmap_bit_size / 2, slice.len);
    @memset(slice, 0x11);
    try testing.expectEqualSlices(
        u8,
        &@as([Alloc.bitmap_bit_size / 2]u8, @splat(0x11)),
        slice,
    );
    const slice2 = try bm.alloc(u8, buf, Alloc.bitmap_bit_size / 2);
    try testing.expectEqual(Alloc.bitmap_bit_size / 2, slice2.len);
    @memset(slice2, 0x22);
    try testing.expectEqualSlices(
        u8,
        &@as([Alloc.bitmap_bit_size / 2]u8, @splat(0x22)),
        slice2,
    );
    try testing.expectEqualSlices(
        u8,
        &@as([Alloc.bitmap_bit_size / 2]u8, @splat(0x11)),
        slice,
    );
    try testing.expect(bm.isAllocated(buf, slice2));
    bm.free(buf, slice2);
    try testing.expect(!bm.isAllocated(buf, slice2));
    try testing.expect(bm.isAllocated(buf, slice));
    bm.free(buf, slice);
    try testing.expect(!bm.isAllocated(buf, slice));
    try testing.expectEqualSlices(
        u64,
        &@as([3]u64, @splat(0)),
        bm.bitmap.ptr(buf)[0..3],
    );
}
test "BitmapAllocator alloc and free 1.5 bitmaps" {
    const Alloc = BitmapAllocator(1);
    const cap = Alloc.bitmap_bit_size * 3;
    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);
    var bm = Alloc.init(.init(buf), layout);
    const slice = try bm.alloc(u8, buf, 3 * Alloc.bitmap_bit_size / 2);
    try testing.expectEqual(3 * Alloc.bitmap_bit_size / 2, slice.len);
    @memset(slice, 0x11);
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 2]u8, @splat(0x11)),
        slice,
    );
    try testing.expect(bm.isAllocated(buf, slice));
    bm.free(buf, slice);
    try testing.expect(!bm.isAllocated(buf, slice));
    try testing.expectEqualSlices(
        u64,
        &@as([3]u64, @splat(0)),
        bm.bitmap.ptr(buf)[0..3],
    );
}
test "BitmapAllocator alloc and free two 1.5 bitmaps" {
    const Alloc = BitmapAllocator(1);
    const cap = Alloc.bitmap_bit_size * 3;
    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);
    var bm = Alloc.init(.init(buf), layout);
    const slice = try bm.alloc(u8, buf, 3 * Alloc.bitmap_bit_size / 2);
    try testing.expectEqual(3 * Alloc.bitmap_bit_size / 2, slice.len);
    @memset(slice, 0x11);
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 2]u8, @splat(0x11)),
        slice,
    );
    const slice2 = try bm.alloc(u8, buf, 3 * Alloc.bitmap_bit_size / 2);
    try testing.expectEqual(3 * Alloc.bitmap_bit_size / 2, slice2.len);
    @memset(slice2, 0x22);
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 2]u8, @splat(0x22)),
        slice2,
    );
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 2]u8, @splat(0x11)),
        slice,
    );
    try testing.expect(bm.isAllocated(buf, slice2));
    bm.free(buf, slice2);
    try testing.expect(!bm.isAllocated(buf, slice2));
    try testing.expect(bm.isAllocated(buf, slice));
    bm.free(buf, slice);
    try testing.expect(!bm.isAllocated(buf, slice));
    try testing.expectEqualSlices(
        u64,
        &@as([3]u64, @splat(0)),
        bm.bitmap.ptr(buf)[0..3],
    );
}
test "BitmapAllocator alloc and free 1.5 bitmaps offset by 0.75" {
    const Alloc = BitmapAllocator(1);
    const cap = Alloc.bitmap_bit_size * 3;
    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);
    var bm = Alloc.init(.init(buf), layout);
    const slice = try bm.alloc(u8, buf, 3 * Alloc.bitmap_bit_size / 4);
    try testing.expectEqual(3 * Alloc.bitmap_bit_size / 4, slice.len);
    @memset(slice, 0x11);
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 4]u8, @splat(0x11)),
        slice,
    );
    const slice2 = try bm.alloc(u8, buf, 3 * Alloc.bitmap_bit_size / 2);
    try testing.expectEqual(3 * Alloc.bitmap_bit_size / 2, slice2.len);
    @memset(slice2, 0x22);
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 2]u8, @splat(0x22)),
        slice2,
    );
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 4]u8, @splat(0x11)),
        slice,
    );
    try testing.expect(bm.isAllocated(buf, slice2));
    bm.free(buf, slice2);
    try testing.expect(!bm.isAllocated(buf, slice2));
    try testing.expect(bm.isAllocated(buf, slice));
    bm.free(buf, slice);
    try testing.expect(!bm.isAllocated(buf, slice));
    try testing.expectEqualSlices(
        u64,
        &@as([3]u64, @splat(0)),
        bm.bitmap.ptr(buf)[0..3],
    );
}
test "BitmapAllocator alloc and free three 0.75 bitmaps" {
    const Alloc = BitmapAllocator(1);
    const cap = Alloc.bitmap_bit_size * 3;
    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);
    var bm = Alloc.init(.init(buf), layout);
    const slice = try bm.alloc(u8, buf, 3 * Alloc.bitmap_bit_size / 4);
    try testing.expectEqual(3 * Alloc.bitmap_bit_size / 4, slice.len);
    @memset(slice, 0x11);
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 4]u8, @splat(0x11)),
        slice,
    );
    const slice2 = try bm.alloc(u8, buf, 3 * Alloc.bitmap_bit_size / 4);
    try testing.expectEqual(3 * Alloc.bitmap_bit_size / 4, slice2.len);
    @memset(slice2, 0x22);
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 4]u8, @splat(0x22)),
        slice2,
    );
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 4]u8, @splat(0x11)),
        slice,
    );
    const slice3 = try bm.alloc(u8, buf, 3 * Alloc.bitmap_bit_size / 4);
    try testing.expectEqual(3 * Alloc.bitmap_bit_size / 4, slice3.len);
    @memset(slice3, 0x33);
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 4]u8, @splat(0x33)),
        slice3,
    );
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 4]u8, @splat(0x22)),
        slice2,
    );
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 4]u8, @splat(0x11)),
        slice,
    );
    try testing.expect(bm.isAllocated(buf, slice2));
    bm.free(buf, slice2);
    try testing.expect(!bm.isAllocated(buf, slice2));
    try testing.expect(bm.isAllocated(buf, slice));
    bm.free(buf, slice);
    try testing.expect(!bm.isAllocated(buf, slice));
    try testing.expect(bm.isAllocated(buf, slice3));
    bm.free(buf, slice3);
    try testing.expect(!bm.isAllocated(buf, slice3));
    try testing.expectEqualSlices(
        u64,
        &@as([3]u64, @splat(0)),
        bm.bitmap.ptr(buf)[0..3],
    );
}
test "BitmapAllocator alloc and free two 1.5 bitmaps offset 0.75" {
    const Alloc = BitmapAllocator(1);
    const cap = Alloc.bitmap_bit_size * 4;
    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Alloc.layout(cap);
    const buf = try alloc.alignedAlloc(u8, Alloc.base_align, layout.total_size);
    defer alloc.free(buf);
    var bm = Alloc.init(.init(buf), layout);
    const slice = try bm.alloc(u8, buf, 3 * Alloc.bitmap_bit_size / 4);
    try testing.expectEqual(3 * Alloc.bitmap_bit_size / 4, slice.len);
    @memset(slice, 0x11);
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 4]u8, @splat(0x11)),
        slice,
    );
    const slice2 = try bm.alloc(u8, buf, 3 * Alloc.bitmap_bit_size / 2);
    try testing.expectEqual(3 * Alloc.bitmap_bit_size / 2, slice2.len);
    @memset(slice2, 0x22);
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 2]u8, @splat(0x22)),
        slice2,
    );
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 4]u8, @splat(0x11)),
        slice,
    );
    const slice3 = try bm.alloc(u8, buf, 3 * Alloc.bitmap_bit_size / 2);
    try testing.expectEqual(3 * Alloc.bitmap_bit_size / 2, slice3.len);
    @memset(slice3, 0x33);
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 2]u8, @splat(0x33)),
        slice3,
    );
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 2]u8, @splat(0x22)),
        slice2,
    );
    try testing.expectEqualSlices(
        u8,
        &@as([3 * Alloc.bitmap_bit_size / 4]u8, @splat(0x11)),
        slice,
    );
    try testing.expect(bm.isAllocated(buf, slice2));
    bm.free(buf, slice2);
    try testing.expect(!bm.isAllocated(buf, slice2));
    try testing.expect(bm.isAllocated(buf, slice));
    bm.free(buf, slice);
    try testing.expect(!bm.isAllocated(buf, slice));
    try testing.expect(bm.isAllocated(buf, slice3));
    bm.free(buf, slice3);
    try testing.expect(!bm.isAllocated(buf, slice3));
    try testing.expectEqualSlices(
        u64,
        &@as([4]u64, @splat(0)),
        bm.bitmap.ptr(buf)[0..4],
    );
}
test "BitmapAllocator bytesRequired" {
    const testing = std.testing;
    {
        const Alloc = BitmapAllocator(16);
        try testing.expectEqual(16, Alloc.bytesRequired(u8, 1));
        try testing.expectEqual(16, Alloc.bytesRequired(u8, 16));
        try testing.expectEqual(32, Alloc.bytesRequired(u8, 17));
        try testing.expectEqual(16, Alloc.bytesRequired(u21, 1)); 
        try testing.expectEqual(16, Alloc.bytesRequired(u21, 4)); 
        try testing.expectEqual(32, Alloc.bytesRequired(u21, 5)); 
        try testing.expectEqual(32, Alloc.bytesRequired(u21, 6)); 
    }
    {
        const Alloc = BitmapAllocator(4);
        try testing.expectEqual(4, Alloc.bytesRequired(u8, 1));
        try testing.expectEqual(4, Alloc.bytesRequired(u8, 4));
        try testing.expectEqual(8, Alloc.bytesRequired(u8, 5));
        try testing.expectEqual(4, Alloc.bytesRequired(u32, 1));
        try testing.expectEqual(8, Alloc.bytesRequired(u32, 2));
    }
    {
        const Alloc = BitmapAllocator(32);
        try testing.expectEqual(32, Alloc.bytesRequired(u8, 1));
        try testing.expectEqual(32, Alloc.bytesRequired(u8, 32));
        try testing.expectEqual(64, Alloc.bytesRequired(u8, 33));
    }
}
