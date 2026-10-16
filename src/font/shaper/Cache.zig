pub const Cache = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const font = @import("../main.zig");
const CacheTable = @import("../../datastruct/root.zig").CacheTable;
const log = std.log.scoped(.font_shaper_cache);
const CellCacheTableContext = struct {
    pub fn hash(self: *const CellCacheTableContext, key: u64) u64 {
        _ = self;
        return key;
    }
    pub fn eql(self: *const CellCacheTableContext, a: u64, b: u64) bool {
        _ = self;
        return a == b;
    }
};
const CellCacheTable = CacheTable(
    u64,
    []font.shape.Cell,
    CellCacheTableContext,
    256,
    8,
);
map: CellCacheTable,
pub fn init() Cache {
    return .{ .map = .{ .context = .{} } };
}
pub fn deinit(self: *Cache, alloc: Allocator) void {
    self.clear(alloc);
}
pub fn get(self: *Cache, run: font.shape.TextRun) ?[]const font.shape.Cell {
    return self.map.get(run.hash);
}
pub fn put(
    self: *Cache,
    alloc: Allocator,
    run: font.shape.TextRun,
    cells: []const font.shape.Cell,
) Allocator.Error!void {
    const copy = try alloc.dupe(font.shape.Cell, cells);
    const evicted = self.map.put(run.hash, copy);
    if (evicted) |kv| {
        alloc.free(kv.value);
    }
}
fn clear(self: *Cache, alloc: Allocator) void {
    for (self.map.buckets, self.map.lengths) |b, l| {
        for (b[0..l]) |kv| {
            alloc.free(kv.value);
        }
    }
    self.map.clear();
}
test Cache {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c = Cache.init();
    defer c.deinit(alloc);
    var run: font.shape.TextRun = undefined;
    run.hash = 1;
    try testing.expect(c.get(run) == null);
    try c.put(alloc, run, &.{
        .{ .x = 0, .glyph_index = 0 },
        .{ .x = 1, .glyph_index = 1 },
    });
    const actual = c.get(run).?;
    try testing.expect(actual.len == 2);
}
