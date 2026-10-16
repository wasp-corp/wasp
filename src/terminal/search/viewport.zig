const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const point = @import("../point.zig");
const size = @import("../size.zig");
const FlattenedHighlight = @import("../highlight.zig").Flattened;
const PageList = @import("../PageList.zig");
const SlidingWindow = @import("sliding_window.zig").SlidingWindow;
const Terminal = @import("../Terminal.zig");
pub const ViewportSearch = struct {
    window: SlidingWindow,
    fingerprint: Fingerprint = .{},
    active_dirty: ?bool,
    pub fn init(
        alloc: Allocator,
        needle_unowned: []const u8,
    ) Allocator.Error!ViewportSearch {
        var window: SlidingWindow = try .init(alloc, .forward, needle_unowned);
        errdefer window.deinit();
        return .{
            .window = window,
            .active_dirty = null,
        };
    }
    pub fn deinit(self: *ViewportSearch) void {
        self.fingerprint.deinit(self.window.alloc);
        self.window.deinit();
    }
    pub fn reset(self: *ViewportSearch) void {
        self.fingerprint.clearAndRetainCapacity();
        self.window.clearAndRetainCapacity();
    }
    pub fn needle(self: *const ViewportSearch) []const u8 {
        assert(self.window.direction == .forward);
        return self.window.needle;
    }
    pub fn update(
        self: *ViewportSearch,
        list: *PageList,
    ) Allocator.Error!bool {
        const fingerprint = &self.fingerprint;
        if (!try fingerprint.update(self.window.alloc, list)) match: {
            const check_active: bool = active: {
                const dirty = self.active_dirty orelse break :active true;
                if (!dirty) break :active false;
                self.active_dirty = false;
                break :active true;
            };
            if (check_active) {
                const active_tl = list.getTopLeft(.active);
                const active_br = list.getBottomRight(.active).?;
                for (fingerprint.entries.items) |entry| {
                    if (entry.node == active_tl.node) break :match;
                    if (entry.node == active_br.node) break :match;
                }
            }
            return false;
        }
        if (self.active_dirty) |*v| v.* = false;
        self.window.clearAndRetainCapacity();
        const overlap_len = self.window.needle.len -| 1;
        const entries = fingerprint.entries.items;
        var node_ = entries[0].node.prev;
        var added: usize = 0;
        while (node_) |node| : (node_ = node.prev) {
            const appended = try self.window.appendIfWrapped(node) orelse break;
            added += appended.content_len;
            if (added >= overlap_len) break;
        }
        var end_append: SlidingWindow.AppendResult = undefined;
        for (entries) |entry| {
            end_append = try self.window.append(entry.node);
        }
        trailing: {
            const end: *PageList.List.Node = entries[entries.len - 1].node;
            if (!end_append.last_row_wrapped) break :trailing;
            node_ = end.next;
            added = 0;
            while (node_) |node| : (node_ = node.next) {
                const appended = try self.window.append(node);
                added += appended.content_len;
                if (added >= overlap_len) break;
                if (!appended.last_row_wrapped) break;
            }
        }
        return true;
    }
    pub fn next(self: *ViewportSearch) ?FlattenedHighlight {
        return self.window.next();
    }
    const Fingerprint = struct {
        entries: std.ArrayListUnmanaged(Entry) = .empty,
        const Entry = struct {
            node: *PageList.List.Node,
            serial: u64,
        };
        pub fn deinit(self: *Fingerprint, alloc: Allocator) void {
            self.entries.deinit(alloc);
        }
        pub fn clearAndRetainCapacity(self: *Fingerprint) void {
            self.entries.clearRetainingCapacity();
        }
        pub fn update(self: *Fingerprint, alloc: Allocator, pages: *PageList) Allocator.Error!bool {
            try self.entries.ensureTotalCapacity(alloc, pages.rows);
            const old_len = self.entries.items.len;
            var changed = false;
            var i: usize = 0;
            var it = pages.pageIterator(.right_down, .{ .viewport = .{} }, null);
            while (it.next()) |chunk| : (i += 1) {
                const entry: Entry = .{
                    .node = chunk.node,
                    .serial = chunk.node.serial,
                };
                if (!changed) {
                    changed = i >= old_len or
                        self.entries.items[i].node != entry.node or
                        self.entries.items[i].serial != entry.serial;
                }
                if (i < self.entries.items.len) {
                    self.entries.items[i] = entry;
                } else {
                    self.entries.appendAssumeCapacity(entry);
                }
            }
            self.entries.shrinkRetainingCapacity(i);
            return changed or i != old_len;
        }
    };
};
test "simple search" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");
    var search: ViewportSearch = try .init(alloc, "Fizz");
    defer search.deinit();
    try testing.expect(try search.update(&t.screens.active.pages));
    try testing.expect(try search.update(&t.screens.active.pages));
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
test "fingerprint detects node generation changes" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    var search: ViewportSearch = try .init(alloc, "needle");
    defer search.deinit();
    search.active_dirty = false;
    try testing.expect(try search.update(&t.screens.active.pages));
    try testing.expect(!try search.update(&t.screens.active.pages));
    const old_entry = search.fingerprint.entries.items[0];
    const node = t.screens.active.pages.pages.first.?;
    try testing.expectEqual(node, old_entry.node);
    const original_serial = node.serial;
    defer node.serial = original_serial;
    node.serial += 1;
    try testing.expect(try search.update(&t.screens.active.pages));
    const new_entry = search.fingerprint.entries.items[0];
    try testing.expectEqual(old_entry.node, new_entry.node);
    try testing.expect(old_entry.serial != new_entry.serial);
}
test "fingerprint only allocates on changes" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    var failing = testing.FailingAllocator.init(alloc, .{});
    const failing_alloc = failing.allocator();
    var search: ViewportSearch = try .init(failing_alloc, "needle");
    defer search.deinit();
    search.active_dirty = false;
    try testing.expect(try search.update(&t.screens.active.pages));
    failing.fail_index = failing.alloc_index;
    try testing.expect(!try search.update(&t.screens.active.pages));
}
test "clear screen and search" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");
    var search: ViewportSearch = try .init(alloc, "Fizz");
    defer search.deinit();
    try testing.expect(try search.update(&t.screens.active.pages));
    s.nextSlice("\x1b[2J"); 
    s.nextSlice("\x1b[H"); 
    s.nextSlice("Buzz\r\nFizz\r\nBuzz");
    try testing.expect(try search.update(&t.screens.active.pages));
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
test "clear screen and search dirty tracking" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");
    var search: ViewportSearch = try .init(alloc, "Fizz");
    defer search.deinit();
    search.active_dirty = false;
    try testing.expect(try search.update(&t.screens.active.pages));
    try testing.expect(!try search.update(&t.screens.active.pages));
    s.nextSlice("\x1b[2J"); 
    s.nextSlice("\x1b[H"); 
    s.nextSlice("Buzz\r\nFizz\r\nBuzz");
    try testing.expect(!try search.update(&t.screens.active.pages));
    search.active_dirty = true;
    try testing.expect(try search.update(&t.screens.active.pages));
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
test "history search, no active area" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    const first_page_rows = t.screens.active.pages.pages.first.?.capacity().rows;
    s.nextSlice("Fizz\r\n");
    for (1..first_page_rows - 1) |_| s.nextSlice("\r\n");
    try testing.expect(t.screens.active.pages.pages.first == t.screens.active.pages.pages.last);
    s.nextSlice("\r\n");
    try testing.expect(t.screens.active.pages.pages.first != t.screens.active.pages.pages.last);
    s.nextSlice("Buzz\r\nFizz");
    t.scrollViewport(.top);
    var search: ViewportSearch = try .init(alloc, "Fizz");
    defer search.deinit();
    try testing.expect(try search.update(&t.screens.active.pages));
    {
        const h = search.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
    try testing.expect(search.next() == null);
    try testing.expect(!try search.update(&t.screens.active.pages));
    try testing.expect(search.next() == null);
}
