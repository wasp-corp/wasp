const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const terminal = @import("../main.zig");
const point = terminal.point;
const size = terminal.size;
const FlattenedHighlight = @import("../highlight.zig").Flattened;
const Page = terminal.Page;
const PageList = terminal.PageList;
const Pin = PageList.Pin;
const Selection = terminal.Selection;
const Screen = terminal.Screen;
const Terminal = @import("../Terminal.zig");
const SlidingWindow = @import("sliding_window.zig").SlidingWindow;
pub const PageListSearch = struct {
    list: *PageList,
    window: SlidingWindow,
    pin: *Pin,
    pub fn init(
        alloc: Allocator,
        needle: []const u8,
        list: *PageList,
        start: *PageList.List.Node,
    ) Allocator.Error!PageListSearch {
        const pin = try list.trackPin(.{
            .node = start,
            .y = start.rows() - 1,
            .x = start.cols() - 1,
        });
        errdefer list.untrackPin(pin);
        var window: SlidingWindow = try .init(alloc, .reverse, needle);
        errdefer window.deinit();
        _ = try window.append(start);
        return .{
            .list = list,
            .window = window,
            .pin = pin,
        };
    }
    pub fn deinit(self: *PageListSearch) void {
        self.window.deinit();
        self.list.untrackPin(self.pin);
    }
    pub fn deinitListInvalid(self: *PageListSearch) void {
        self.window.deinit();
    }
    pub fn next(self: *PageListSearch) ?FlattenedHighlight {
        return self.window.next();
    }
    pub fn feed(self: *PageListSearch) Allocator.Error!bool {
        if (self.pin.garbage) return false;
        var rem = self.window.needle.len;
        var node_: ?*PageList.List.Node = self.pin.node.prev;
        while (node_) |node| : (node_ = node.prev) {
            rem -|= (try self.window.append(node)).content_len;
            self.pin.node = node;
            self.pin.y = node.rows() - 1;
            self.pin.x = node.cols() - 1;
            self.pin.garbage = false;
            if (rem == 0) break;
        }
        return rem < self.window.needle.len;
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
    var search: PageListSearch = try .init(
        alloc,
        "Fizz",
        &t.screens.active.pages,
        t.screens.active.pages.pages.last.?,
    );
    defer search.deinit();
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
    try testing.expect(search.next() == null);
    try testing.expect(!try search.feed());
}
test "feed multiple pages with matches" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    const first_page_rows = t.screens.active.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| s.nextSlice("\r\n");
    s.nextSlice("Fizz");
    try testing.expect(t.screens.active.pages.pages.first == t.screens.active.pages.pages.last);
    s.nextSlice("\r\n");
    try testing.expect(t.screens.active.pages.pages.first != t.screens.active.pages.pages.last);
    s.nextSlice("Buzz\r\nFizz");
    var search: PageListSearch = try .init(
        alloc,
        "Fizz",
        &t.screens.active.pages,
        t.screens.active.pages.pages.last.?,
    );
    defer search.deinit();
    const sel1 = search.next();
    try testing.expect(sel1 != null);
    try testing.expect(search.next() == null);
    try testing.expect(try search.feed());
    const sel2 = search.next();
    try testing.expect(sel2 != null);
    try testing.expect(search.next() == null);
    try testing.expect(!try search.feed());
}
test "feed multiple pages no matches" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    const first_page_rows = t.screens.active.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| s.nextSlice("\r\n");
    s.nextSlice("Hello");
    s.nextSlice("\r\n");
    try testing.expect(t.screens.active.pages.pages.first != t.screens.active.pages.pages.last);
    s.nextSlice("World");
    var search: PageListSearch = try .init(
        alloc,
        "Nope",
        &t.screens.active.pages,
        t.screens.active.pages.pages.last.?,
    );
    defer search.deinit();
    try testing.expect(search.next() == null);
    try testing.expect(try search.feed());
    try testing.expect(search.next() == null);
    try testing.expect(!try search.feed());
}
test "feed iteratively through multiple matches" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    const first_page_rows = t.screens.active.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| s.nextSlice("\r\n");
    s.nextSlice("Page1Test");
    try testing.expect(t.screens.active.pages.pages.first == t.screens.active.pages.pages.last);
    s.nextSlice("\r\n");
    try testing.expect(t.screens.active.pages.pages.first != t.screens.active.pages.pages.last);
    s.nextSlice("Page2Test");
    var search: PageListSearch = try .init(
        alloc,
        "Test",
        &t.screens.active.pages,
        t.screens.active.pages.pages.last.?,
    );
    defer search.deinit();
    try testing.expect(search.next() != null);
    try testing.expect(search.next() == null);
    try testing.expect(try search.feed());
    try testing.expect(search.next() != null);
    try testing.expect(search.next() == null);
    try testing.expect(!try search.feed());
}
test "feed with match spanning page boundary" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    const first_page_rows = t.screens.active.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| s.nextSlice("\r\n");
    for (0..t.screens.active.pages.cols - 2) |_| s.nextSlice("x");
    s.nextSlice("Te");
    try testing.expect(t.screens.active.pages.pages.first == t.screens.active.pages.pages.last);
    s.nextSlice("st");
    try testing.expect(t.screens.active.pages.pages.first != t.screens.active.pages.pages.last);
    var search: PageListSearch = try .init(
        alloc,
        "Test",
        &t.screens.active.pages,
        t.screens.active.pages.pages.last.?,
    );
    defer search.deinit();
    try testing.expect(search.next() == null);
    try testing.expect(try search.feed());
    const h = search.next().?;
    const sel = h.untracked();
    try testing.expect(sel.start.node != sel.end.node);
    {
        const str = try t.screens.active.selectionString(
            alloc,
            .{ .sel = .init(sel.start, sel.end, false) },
        );
        defer alloc.free(str);
        try testing.expectEqualStrings(str, "Test");
    }
    try testing.expect(search.next() == null);
    try testing.expect(!try search.feed());
}
test "compressed history match spanning page boundary remains compressed" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_bytes = 10 * 1024 * 1024,
    });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    const pages = &t.screens.active.pages;
    const first = pages.pages.first.?;
    const first_page_rows = first.capacity().rows;
    for (0..first_page_rows - 1) |_| stream.nextSlice("\r\n");
    for (0..pages.cols - 2) |_| stream.nextSlice("x");
    stream.nextSlice("Test");
    const second = first.next.?;
    try testing.expectEqual(second, pages.pages.last.?);
    while (pages.pages.last.? == second) stream.nextSlice("\r\n");
    for (0..pages.rows) |_| stream.nextSlice("\r\n");
    try testing.expect(pages.getTopLeft(.active).node != second);
    _ = pages.compress(.full);
    try testing.expectEqual(PageList.List.Node.Storage.compressed, first.storage());
    try testing.expectEqual(PageList.List.Node.Storage.compressed, second.storage());
    const compressed = pages.memoryStats();
    try testing.expect(compressed.compressed_pages >= 2);
    var search: PageListSearch = try .init(
        alloc,
        "Test",
        pages,
        pages.pages.last.?,
    );
    defer search.deinit();
    var found: ?FlattenedHighlight = null;
    for (0..pages.totalPages() + 1) |_| {
        if (search.next()) |match| {
            found = match;
            break;
        }
        if (!try search.feed()) break;
    }
    try testing.expect(found != null);
    const match = found.?.untracked();
    try testing.expectEqual(first, match.start.node);
    try testing.expectEqual(second, match.end.node);
    try testing.expectEqual(@as(size.CellCountInt, pages.cols - 2), match.start.x);
    try testing.expectEqual(@as(size.CellCountInt, 1), match.end.x);
    try testing.expectEqual(compressed, pages.memoryStats());
    try testing.expectEqual(PageList.List.Node.Storage.compressed, first.storage());
    try testing.expectEqual(PageList.List.Node.Storage.compressed, second.storage());
}
test "feed with match spanning page boundary with newline" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    const first_page_rows = t.screens.active.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| s.nextSlice("\r\n");
    for (0..t.screens.active.pages.cols - 2) |_| s.nextSlice("x");
    s.nextSlice("Te");
    try testing.expect(t.screens.active.pages.pages.first == t.screens.active.pages.pages.last);
    s.nextSlice("\r\n");
    try testing.expect(t.screens.active.pages.pages.first != t.screens.active.pages.pages.last);
    s.nextSlice("st");
    var search: PageListSearch = try .init(
        alloc,
        "Test",
        &t.screens.active.pages,
        t.screens.active.pages.pages.last.?,
    );
    defer search.deinit();
    try testing.expect(search.next() == null);
    try testing.expect(try search.feed());
    try testing.expect(search.next() == null);
    try testing.expect(!try search.feed());
}
test "feed with pruned page" {
    const alloc = testing.allocator;
    var p: PageList = try .init(alloc, .{
        .cols = 80,
        .rows = 24,
        .max_size = 0,
    });
    defer p.deinit();
    const page1_node = p.pages.last.?;
    const page1 = page1_node.page();
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try p.grow() == null);
    }
    const page2_node = (try p.grow()).?;
    const page2 = page2_node.page();
    for (0..page2.capacity.rows - page2.size.rows) |_| {
        try testing.expect(try p.grow() == null);
    }
    var search: PageListSearch = try .init(
        alloc,
        "Test",
        &p,
        p.pages.last.?,
    );
    defer search.deinit();
    try testing.expect(try search.feed());
    try testing.expect(!try search.feed());
    const new = (try p.grow()).?;
    try testing.expect(p.pages.last.? == new);
    try testing.expectEqual(page2_node, p.pages.first.?);
    try testing.expectEqual(page1_node, p.pages.last.?);
    try testing.expect(!try search.feed());
}
test "feed keeps its tracked pin within a shorter page" {
    const alloc = testing.allocator;
    var pages: PageList = try .init(alloc, .{
        .cols = 10,
        .rows = 2,
    });
    defer pages.deinit();
    const first = pages.pages.first.?;
    while (first.rows() < first.capacity().rows) _ = try pages.grow();
    const second = (try pages.grow()).?;
    while (second.rows() < second.capacity().rows) _ = try pages.grow();
    try pages.split(.{ .node = first, .y = 1, .x = 0 });
    const shorter = first.next.?;
    try testing.expect(shorter.rows() < second.rows());
    var search: PageListSearch = try .init(
        alloc,
        "x",
        &pages,
        second,
    );
    defer search.deinit();
    try testing.expect(try search.feed());
    try testing.expectEqual(shorter, search.pin.node);
    try testing.expect(pages.pinIsValid(search.pin.*));
}
test "feed discovers pages prepended after exhaustion" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 10,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz");
    const pages = &t.screens.active.pages;
    var search: PageListSearch = try .init(
        alloc,
        "Fizz",
        pages,
        pages.pages.last.?,
    );
    defer search.deinit();
    try testing.expect(search.next() != null);
    try testing.expect(search.next() == null);
    try testing.expect(!try search.feed());
    const old_first = pages.pages.first.?;
    {
        var allocation = try pages.allocatePage(.{ .cols = 10, .rows = 2 });
        defer allocation.deinit();
        const page = allocation.page();
        page.size.rows = 2;
        for ("Fizz", 0..) |c, x| page.getRowAndCell(x, 1).cell.* = .init(c);
        try allocation.finalize(.prepend, .{});
    }
    const prepended = pages.pages.first.?;
    try testing.expect(prepended != old_first);
    try testing.expectEqual(old_first, search.pin.node);
    try testing.expect(try search.feed());
    try testing.expectEqual(prepended, search.pin.node);
    const h = search.next().?;
    const sel = h.untracked();
    try testing.expectEqual(prepended, sel.start.node);
    try testing.expectEqual(prepended, sel.end.node);
    try testing.expectEqual(@as(size.CellCountInt, 1), sel.start.y);
    try testing.expectEqual(@as(size.CellCountInt, 0), sel.start.x);
    try testing.expectEqual(@as(size.CellCountInt, 3), sel.end.x);
    try testing.expect(search.next() == null);
    try testing.expect(!try search.feed());
}
