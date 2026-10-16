const fastmem = @import("../fastmem.zig");
const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
pub fn CacheTable(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
    comptime bucket_count: usize,
    comptime bucket_size: u8,
) type {
    return struct {
        const Self = @This();
        const KV = struct {
            key: K,
            value: V,
        };
        comptime {
            assert(std.math.isPowerOfTwo(bucket_count));
            assert(bucket_count <= std.math.maxInt(usize));
        }
        buckets: [bucket_count][bucket_size]KV = undefined,
        lengths: [bucket_count]u8 = @splat(0),
        context: Context,
        pub fn put(self: *Self, key: K, value: V) ?KV {
            const kv: KV = .{ .key = key, .value = value };
            const idx: usize = @intCast(self.context.hash(key) % bucket_count);
            if (self.lengths[idx] < bucket_size) {
                self.buckets[idx][self.lengths[idx]] = kv;
                self.lengths[idx] += 1;
                return null;
            }
            assert(self.lengths[idx] == bucket_size);
            const evicted = fastmem.rotateIn(KV, &self.buckets[idx], kv);
            if (comptime @hasDecl(Context, "evicted")) self.context.evicted(
                evicted.key,
                evicted.value,
            );
            return evicted;
        }
        pub fn get(self: *Self, key: K) ?V {
            const idx: usize = @intCast(self.context.hash(key) % bucket_count);
            const len = self.lengths[idx];
            var i: usize = len;
            while (i > 0) {
                i -= 1;
                if (self.context.eql(key, self.buckets[idx][i].key)) {
                    defer fastmem.rotateOnce(KV, self.buckets[idx][i..len]);
                    return self.buckets[idx][i].value;
                }
            }
            return null;
        }
        pub fn clear(self: *Self) void {
            if (comptime @hasDecl(Context, "evicted")) {
                for (self.buckets, self.lengths) |b, l| {
                    for (b[0..l]) |kv| {
                        self.context.evicted(kv.key, kv.value);
                    }
                }
            }
            @memset(&self.lengths, 0);
        }
    };
}
fn AutoContext(comptime K: type) type {
    return std.hash_map.AutoContext(K);
}
test CacheTable {
    const testing = std.testing;
    const T = CacheTable(u32, u32, struct {
        pub fn hash(self: *const @This(), key: u32) u64 {
            _ = self;
            return @intCast(key);
        }
        pub fn eql(self: *const @This(), a: u32, b: u32) bool {
            _ = self;
            return a == b;
        }
    }, 2, 2);
    var t: T = .{ .context = .{} };
    try testing.expect(t.put(0, 0) == null);
    try testing.expect(t.put(1, 0) == null);
    try testing.expect(t.put(2, 0) == null);
    try testing.expect(t.put(3, 0) == null);
    try testing.expectEqual(T.KV{
        .key = 0,
        .value = 0,
    }, t.put(4, 0).?);
    try testing.expect(t.get(0) == null);
}
