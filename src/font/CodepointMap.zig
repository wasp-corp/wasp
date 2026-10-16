const CodepointMap = @This();
const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const discovery = @import("discovery.zig");
pub const Entry = struct {
    range: [2]u21,
    descriptor: discovery.Descriptor,
};
list: std.MultiArrayList(Entry) = .{},
pub fn deinit(self: *CodepointMap, alloc: Allocator) void {
    self.list.deinit(alloc);
}
pub fn clone(self: *const CodepointMap, alloc: Allocator) !CodepointMap {
    var list = try self.list.clone(alloc);
    for (list.items(.descriptor)) |*d| {
        d.* = try d.clone(alloc);
    }
    return .{ .list = list };
}
pub fn add(self: *CodepointMap, alloc: Allocator, entry: Entry) !void {
    assert(entry.range[0] <= entry.range[1]);
    try self.list.append(alloc, entry);
}
pub fn get(self: *const CodepointMap, cp: u21) ?discovery.Descriptor {
    const items = self.list.items(.range);
    for (0..items.len) |forward_i| {
        const i = items.len - forward_i - 1;
        const range = items[i];
        if (range[0] <= cp and cp <= range[1]) {
            const descs = self.list.items(.descriptor);
            return descs[i];
        }
    }
    return null;
}
pub fn hash(self: *const CodepointMap, hasher: anytype) void {
    const autoHash = std.hash.autoHash;
    autoHash(hasher, self.list.len);
    const slice = self.list.slice();
    for (0..slice.len) |i| {
        const entry = slice.get(i);
        autoHash(hasher, entry.range);
        entry.descriptor.hash(hasher);
    }
}
pub fn hashcode(self: *const CodepointMap) u64 {
    var hasher = std.hash.Wyhash.init(0);
    self.hash(&hasher);
    return hasher.final();
}
test "codepointmap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var m: CodepointMap = .{};
    defer m.deinit(alloc);
    try testing.expect(m.get(1) == null);
    try m.add(alloc, .{ .range = .{ 1, 1 }, .descriptor = .{ .family = "A" } });
    {
        const d = m.get(1).?;
        try testing.expectEqualStrings("A", d.family.?);
    }
    try m.add(alloc, .{ .range = .{ 1, 2 }, .descriptor = .{ .family = "B" } });
    {
        const d = m.get(1).?;
        try testing.expectEqualStrings("B", d.family.?);
    }
    try testing.expect(m.get(0) == null);
    try testing.expect(m.get(3) == null);
    try m.add(alloc, .{ .range = .{ 3, 4 }, .descriptor = .{ .family = "C" } });
    try m.add(alloc, .{ .range = .{ 5, 6 }, .descriptor = .{ .family = "D" } });
    {
        const d = m.get(3).?;
        try testing.expectEqualStrings("C", d.family.?);
    }
    {
        const d = m.get(1).?;
        try testing.expectEqualStrings("B", d.family.?);
    }
}
