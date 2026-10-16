const ClipboardCodepointMap = @This();
const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
pub const Entry = @import("../terminal/formatter.zig").CodepointMap;
pub const Replacement = Entry.Replacement;
list: std.MultiArrayList(Entry) = .{},
pub fn deinit(self: *ClipboardCodepointMap, alloc: Allocator) void {
    self.list.deinit(alloc);
}
pub fn clone(self: *const ClipboardCodepointMap, alloc: Allocator) !ClipboardCodepointMap {
    var list = try self.list.clone(alloc);
    for (list.items(.replacement)) |*r| switch (r.*) {
        .string => |s| r.string = try alloc.dupe(u8, s),
        .codepoint => {}, 
    };
    return .{ .list = list };
}
pub fn add(self: *ClipboardCodepointMap, alloc: Allocator, entry: Entry) !void {
    assert(entry.range[0] <= entry.range[1]);
    try self.list.append(alloc, entry);
}
