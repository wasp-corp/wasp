const Tabstops = @This();
const std = @import("std");
const tripwire = @import("../tripwire.zig");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const assert = @import("../quirks.zig").inlineAssert;
const Unit = u8;
const unit_bits = @bitSizeOf(Unit);
const prealloc_columns = 512;
const prealloc_count = prealloc_columns / unit_bits;
const masks = blk: {
    var res: [unit_bits]Unit = undefined;
    for (res, 0..) |_, i| {
        res[i] = @shlExact(@as(Unit, 1), @as(u3, @intCast(i)));
    }
    break :blk res;
};
cols: usize = 0,
prealloc_stops: [prealloc_count]Unit = @splat(0),
dynamic_stops: []Unit = &[0]Unit{},
inline fn entry(col: usize) usize {
    return col / unit_bits;
}
inline fn index(col: usize) usize {
    return @mod(col, unit_bits);
}
pub fn init(
    alloc: Allocator,
    cols: usize,
    interval: usize,
) Allocator.Error!Tabstops {
    var res: Tabstops = .{};
    try res.resize(alloc, cols);
    res.reset(interval);
    return res;
}
pub fn deinit(self: *Tabstops, alloc: Allocator) void {
    if (self.dynamic_stops.len > 0) alloc.free(self.dynamic_stops);
    self.* = undefined;
}
pub fn set(self: *Tabstops, col: usize) void {
    const i = entry(col);
    const idx = index(col);
    if (i < prealloc_count) {
        self.prealloc_stops[i] |= masks[idx];
        return;
    }
    const dynamic_i = i - prealloc_count;
    assert(dynamic_i < self.dynamic_stops.len);
    self.dynamic_stops[dynamic_i] |= masks[idx];
}
pub fn unset(self: *Tabstops, col: usize) void {
    const i = entry(col);
    const idx = index(col);
    if (i < prealloc_count) {
        self.prealloc_stops[i] &= ~masks[idx];
        return;
    }
    const dynamic_i = i - prealloc_count;
    assert(dynamic_i < self.dynamic_stops.len);
    self.dynamic_stops[dynamic_i] &= ~masks[idx];
}
pub fn get(self: Tabstops, col: usize) bool {
    const i = entry(col);
    const idx = index(col);
    const mask = masks[idx];
    const unit = if (i < prealloc_count)
        self.prealloc_stops[i]
    else unit: {
        const dynamic_i = i - prealloc_count;
        assert(dynamic_i < self.dynamic_stops.len);
        break :unit self.dynamic_stops[dynamic_i];
    };
    return unit & mask == mask;
}
const resize_tw = tripwire.module(enum {
    dynamic_alloc,
}, resize);
pub fn resize(
    self: *Tabstops,
    alloc: Allocator,
    cols: usize,
) Allocator.Error!void {
    const tw = resize_tw;
    if (cols <= prealloc_columns) {
        self.cols = cols;
        return;
    }
    const dynamic_count = std.math.divCeil(
        usize,
        cols - prealloc_columns,
        unit_bits,
    ) catch unreachable;
    if (dynamic_count <= self.dynamic_stops.len) {
        self.cols = cols;
        return;
    }
    try tw.check(.dynamic_alloc);
    const old_len = self.dynamic_stops.len;
    self.dynamic_stops = try alloc.realloc(self.dynamic_stops, dynamic_count);
    @memset(self.dynamic_stops[old_len..], 0);
    self.cols = cols;
}
pub fn capacity(self: Tabstops) usize {
    return (prealloc_count + self.dynamic_stops.len) * unit_bits;
}
pub fn reset(self: *Tabstops, interval: usize) void {
    @memset(&self.prealloc_stops, 0);
    @memset(self.dynamic_stops, 0);
    if (interval == 0 or self.cols <= 1) return;
    var i: usize = interval;
    while (i < self.cols - 1) : (i += interval) {
        self.set(i);
    }
}
test "Tabstops: basic" {
    var t: Tabstops = .{};
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), entry(4));
    try testing.expectEqual(@as(usize, 1), entry(8));
    try testing.expectEqual(@as(usize, 0), index(0));
    try testing.expectEqual(@as(usize, 1), index(1));
    try testing.expectEqual(@as(usize, 1), index(9));
    try testing.expectEqual(@as(Unit, 0b00001000), masks[3]);
    try testing.expectEqual(@as(Unit, 0b00010000), masks[4]);
    try testing.expect(!t.get(4));
    t.set(4);
    try testing.expect(t.get(4));
    try testing.expect(!t.get(3));
    t.reset(0);
    try testing.expect(!t.get(4));
    t.set(4);
    try testing.expect(t.get(4));
    t.unset(4);
    try testing.expect(!t.get(4));
    t.unset(4);
    try testing.expect(!t.get(4));
}
test "Tabstops: dynamic allocations" {
    var t: Tabstops = .{};
    defer t.deinit(testing.allocator);
    const cap = t.capacity();
    try t.resize(testing.allocator, cap + 5);
    try testing.expectEqual(cap + unit_bits, t.capacity());
    t.set(cap + 4);
    try testing.expect(t.get(cap + 4));
    try testing.expect(!t.get(cap + 3));
    t.unset(cap + 3);
    try testing.expect(!t.get(cap + 3));
    try t.resize(testing.allocator, cap + unit_bits + 1);
    try testing.expect(t.get(cap + 4));
    try testing.expect(!t.get(cap + unit_bits));
    try testing.expect(!t.get(5));
}
test "Tabstops: resize to existing capacity does not allocate" {
    var backing: [prealloc_count]Unit = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    var t: Tabstops = .{};
    try t.resize(fixed.allocator(), prealloc_columns * 2);
    try t.resize(fixed.allocator(), prealloc_columns * 2);
}
test "Tabstops: interval" {
    var t: Tabstops = try init(testing.allocator, 80, 4);
    defer t.deinit(testing.allocator);
    try testing.expect(!t.get(0));
    try testing.expect(t.get(4));
    try testing.expect(!t.get(5));
    try testing.expect(t.get(8));
}
test "Tabstops: interval with zero columns" {
    var t: Tabstops = try init(testing.allocator, 0, 8);
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), t.cols);
}
test "Tabstops: count on 80" {
    var t: Tabstops = try init(testing.allocator, 80, 8);
    defer t.deinit(testing.allocator);
    const count: usize = count: {
        var v: usize = 0;
        var i: usize = 0;
        while (i < 80) : (i += 1) {
            if (t.get(i)) {
                v += 1;
            }
        }
        break :count v;
    };
    try testing.expectEqual(@as(usize, 9), count);
}
test "Tabstops: resize alloc failure preserves state" {
    var t: Tabstops = try init(testing.allocator, 80, 8);
    defer t.deinit(testing.allocator);
    const original_cols = t.cols;
    resize_tw.errorAlways(.dynamic_alloc, error.OutOfMemory);
    const result = t.resize(testing.allocator, prealloc_columns * 2);
    try testing.expectError(error.OutOfMemory, result);
    try resize_tw.end(.reset);
    try testing.expectEqual(original_cols, t.cols);
}
