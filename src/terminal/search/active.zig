const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const point = @import("../point.zig");
const size = @import("../size.zig");
const FlattenedHighlight = @import("../highlight.zig").Flattened;
const PageList = @import("../PageList.zig");
const SlidingWindow = @import("sliding_window.zig").SlidingWindow;
const Terminal = @import("../Terminal.zig");
pub const ActiveSearch = struct {
    window: SlidingWindow,
    pub fn init(
        alloc: Allocator,
        needle: []const u8,
    ) Allocator.Error!ActiveSearch {
        var window: SlidingWindow = try .init(alloc, .forward, needle);
        errdefer window.deinit();
        return .{ .window = window };
    }
    pub fn deinit(self: *ActiveSearch) void {
        self.window.deinit();
    }
    pub fn update(
        self: *ActiveSearch,
        list: *const PageList,
    ) Allocator.Error!?*PageList.List.Node {
        self.window.clearAndRetainCapacity();
        if (self.window.needle.len == 0) return null;
        var rem: usize = list.rows;
        var node_ = list.pages.last;
        var last_node: ?*PageList.List.Node = null;
        while (node_) |node| : (node_ = node.prev) {
            _ = try self.window.append(node);
            last_node = node;
            if (rem <= node.rows()) {
                node_ = node.prev;
                break;
            }
            rem -= node.rows();
        }
        while (node_) |node| : (node_ = node.prev) {
            const appended = try self.window.appendIfWrapped(node) orelse break;
            if (appended.content_len >= self.window.needle.len - 1) break;
        }
        return last_node;
    }
    pub fn next(self: *ActiveSearch) ?FlattenedHighlight {
        return self.window.next();
    }
};
test "simple search" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");
    var search: ActiveSearch = try .init(alloc, "Fizz");
    defer search.deinit();
    _ = try search.update(&t.screens.active.pages);
    {
        const h = search.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.active, sel.end).?);
    }
    {
        const h = search.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 3,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(search.next() == null);
}
test "clear screen and search" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");
    var search: ActiveSearch = try .init(alloc, "Fizz");
    defer search.deinit();
    _ = try search.update(&t.screens.active.pages);
    s.nextSlice("\x1b[2J"); 
    s.nextSlice("\x1b[H"); 
    s.nextSlice("Buzz\r\nFizz\r\nBuzz");
    _ = try search.update(&t.screens.active.pages);
    {
        const h = search.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 3,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(search.next() == null);
}
