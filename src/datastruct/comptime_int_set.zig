const std = @import("std");
const assert = std.debug.assert;
pub fn ComptimeIntSet(comptime T: type, comptime keys: []const T) type {
    comptime assert(@typeInfo(T) == .int);
    return struct {
        pub const len = keys.len;
        pub const Index = std.math.IntFittingRange(0, @max(len, 1) - 1);
        const Table = struct {
            sorted: [len]T,
            original: [len]Index,
        };
        const table: Table = table: {
            @setEvalBranchQuota(100 * (len + 1) * (len + 1));
            var order: [len]Index = undefined;
            for (&order, 0..) |*v, i| v.* = i;
            std.mem.sortUnstable(Index, &order, {}, struct {
                fn lessThan(_: void, a: Index, b: Index) bool {
                    return keys[a] < keys[b];
                }
            }.lessThan);
            var result: Table = undefined;
            for (order, 0..) |orig, i| {
                result.sorted[i] = keys[orig];
                result.original[i] = orig;
                if (i > 0 and result.sorted[i - 1] == result.sorted[i]) {
                    @compileError("ComptimeIntSet keys must be unique");
                }
            }
            break :table result;
        };
        pub inline fn indexOf(key: T) ?Index {
            if (comptime len == 0) return null;
            var base: usize = 0;
            comptime var n: usize = len;
            inline while (n > 1) {
                const half = comptime n / 2;
                base = if (table.sorted[base + half] <= key) base + half else base;
                n -= half;
            }
            if (table.sorted[base] != key) return null;
            return table.original[base];
        }
        pub inline fn contains(key: T) bool {
            return indexOf(key) != null;
        }
    };
}
test "ComptimeIntSet: empty" {
    const testing = std.testing;
    const Set = ComptimeIntSet(u16, &.{});
    try testing.expect(Set.indexOf(0) == null);
    try testing.expect(!Set.contains(1));
}
test "ComptimeIntSet: single" {
    const testing = std.testing;
    const Set = ComptimeIntSet(u16, &.{42});
    try testing.expectEqual(0, Set.indexOf(42).?);
    try testing.expect(Set.indexOf(41) == null);
    try testing.expect(Set.indexOf(43) == null);
}
test "ComptimeIntSet: unsorted keys return original index" {
    const testing = std.testing;
    const keys: []const u16 = &.{ 2026, 4, 1049, 25, 1, 65535, 0 };
    const Set = ComptimeIntSet(u16, keys);
    for (keys, 0..) |key, i| try testing.expectEqual(i, Set.indexOf(key).?);
}
test "ComptimeIntSet: exhaustive against linear scan" {
    const testing = std.testing;
    inline for (0..20) |n| {
        const keys = comptime keys: {
            var result: [n]u8 = undefined;
            for (&result, 0..) |*v, i| v.* = @intCast((i * 37 + 11) % 251);
            break :keys result;
        };
        const Set = ComptimeIntSet(u8, &keys);
        for (0..256) |v| {
            const expected: ?usize = for (keys, 0..) |key, i| {
                if (key == v) break i;
            } else null;
            const actual: ?usize = if (Set.indexOf(@intCast(v))) |i| i else null;
            try testing.expectEqual(expected, actual);
        }
    }
}
test "ComptimeIntSet: signed" {
    const testing = std.testing;
    const Set = ComptimeIntSet(i8, &.{ 5, -3, 0, -128, 127 });
    try testing.expectEqual(1, Set.indexOf(-3).?);
    try testing.expectEqual(3, Set.indexOf(-128).?);
    try testing.expectEqual(4, Set.indexOf(127).?);
    try testing.expect(Set.indexOf(-4) == null);
}
