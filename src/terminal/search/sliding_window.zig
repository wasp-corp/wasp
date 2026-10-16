const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const CircBuf = @import("../../datastruct/root.zig").CircBuf;
const terminal = @import("../main.zig");
const point = terminal.point;
const size = terminal.size;
const PageList = terminal.PageList;
const Pin = PageList.Pin;
const Selection = terminal.Selection;
const Screen = terminal.Screen;
const Terminal = terminal.Terminal;
const PageFormatter = @import("../formatter.zig").PageFormatter;
const FlattenedHighlight = terminal.highlight.Flattened;
pub const SlidingWindow = struct {
    alloc: Allocator,
    data: DataBuf,
    meta: MetaBuf,
    chunk_buf: std.MultiArrayList(FlattenedHighlight.Chunk),
    data_offset: usize = 0,
    needle: []const u8,
    direction: Direction,
    overlap_buf: []u8,
    const Direction = enum { forward, reverse };
    const DataBuf = CircBuf(u8, 0);
    const MetaBuf = CircBuf(Meta, undefined);
    const Meta = struct {
        node: *PageList.List.Node,
        serial: u64,
        rows: size.CellCountInt,
        cell_map: std.ArrayList(point.Coordinate),
        pub fn deinit(self: *Meta, alloc: Allocator) void {
            self.cell_map.deinit(alloc);
        }
    };
    pub const AppendResult = struct {
        content_len: usize,
        last_row_wrapped: bool,
    };
    pub fn init(
        alloc: Allocator,
        direction: Direction,
        needle_unowned: []const u8,
    ) Allocator.Error!SlidingWindow {
        var data = try DataBuf.init(alloc, 0);
        errdefer data.deinit(alloc);
        var meta = try MetaBuf.init(alloc, 0);
        errdefer meta.deinit(alloc);
        const needle = try alloc.dupe(u8, needle_unowned);
        errdefer alloc.free(needle);
        switch (direction) {
            .forward => {},
            .reverse => std.mem.reverse(u8, needle),
        }
        const overlap_buf = try alloc.alloc(u8, needle.len * 2);
        errdefer alloc.free(overlap_buf);
        return .{
            .alloc = alloc,
            .data = data,
            .meta = meta,
            .chunk_buf = .empty,
            .needle = needle,
            .direction = direction,
            .overlap_buf = overlap_buf,
        };
    }
    pub fn deinit(self: *SlidingWindow) void {
        self.alloc.free(self.overlap_buf);
        self.alloc.free(self.needle);
        self.chunk_buf.deinit(self.alloc);
        self.data.deinit(self.alloc);
        var meta_it = self.meta.iterator(.forward);
        while (meta_it.next()) |meta| meta.deinit(self.alloc);
        self.meta.deinit(self.alloc);
    }
    pub fn clearAndRetainCapacity(self: *SlidingWindow) void {
        var meta_it = self.meta.iterator(.forward);
        while (meta_it.next()) |meta| meta.deinit(self.alloc);
        self.meta.clear();
        self.data.clear();
        self.data_offset = 0;
    }
    pub fn next(self: *SlidingWindow) ?FlattenedHighlight {
        if (self.needle.len == 0) return null;
        const slices = slices: {
            const data_len = self.data.len();
            if (data_len < self.needle.len) return null;
            break :slices self.data.getPtrSlice(
                self.data_offset,
                data_len - self.data_offset,
            );
        };
        if (std.ascii.indexOfIgnoreCase(slices[0], self.needle)) |idx| {
            return self.highlight(
                idx,
                self.needle.len,
            );
        }
        if (slices[0].len > 0 and slices[1].len > 0) overlap: {
            const prefix: []const u8 = prefix: {
                const len = @min(slices[0].len, self.needle.len - 1);
                const idx = slices[0].len - len;
                break :prefix slices[0][idx..];
            };
            const suffix: []const u8 = suffix: {
                const len = @min(slices[1].len, self.needle.len - 1);
                break :suffix slices[1][0..len];
            };
            const overlap_len = prefix.len + suffix.len;
            assert(overlap_len <= self.overlap_buf.len);
            @memcpy(self.overlap_buf[0..prefix.len], prefix);
            @memcpy(self.overlap_buf[prefix.len..overlap_len], suffix);
            const idx = std.ascii.indexOfIgnoreCase(
                self.overlap_buf[0..overlap_len],
                self.needle,
            ) orelse break :overlap;
            return self.highlight(
                slices[0].len - prefix.len + idx,
                self.needle.len,
            );
        }
        if (std.ascii.indexOfIgnoreCase(slices[1], self.needle)) |idx| {
            return self.highlight(
                slices[0].len + idx,
                self.needle.len,
            );
        }
        if (self.needle.len == 1) {
            self.clearAndRetainCapacity();
            self.assertIntegrity();
            return null;
        }
        prune: {
            var meta_it = self.meta.iterator(.reverse);
            var saved: usize = 0;
            while (meta_it.next()) |meta| {
                const needed = self.needle.len - 1 - saved;
                if (meta.cell_map.items.len >= needed) {
                    self.data_offset = meta.cell_map.items.len - needed;
                    break;
                }
                saved += meta.cell_map.items.len;
            } else {
                assert(saved < self.needle.len - 1);
                break :prune;
            }
            const prune_count = self.meta.len() - meta_it.idx;
            if (prune_count == 0) {
                break :prune;
            }
            meta_it = self.meta.iterator(.forward);
            var prune_data_len: usize = 0;
            for (0..prune_count) |_| {
                const meta = meta_it.next().?;
                prune_data_len += meta.cell_map.items.len;
                meta.deinit(self.alloc);
            }
            self.meta.deleteOldest(prune_count);
            self.data.deleteOldest(prune_data_len);
        }
        self.data_offset = self.data.len() - self.needle.len + 1;
        self.assertIntegrity();
        return null;
    }
    fn highlight(
        self: *SlidingWindow,
        start_offset: usize,
        len: usize,
    ) terminal.highlight.Flattened {
        const start = start_offset + self.data_offset;
        const end = start + len - 1;
        if (comptime std.debug.runtime_safety) {
            assert(start < self.data.len());
            assert(start + len <= self.data.len());
        }
        self.chunk_buf.clearRetainingCapacity();
        var result: terminal.highlight.Flattened = .empty;
        var cross_page_end_rows: ?size.CellCountInt = null;
        const tl: struct {
            br: ?struct {
                it: MetaBuf.Iterator,
                consumed: usize,
            },
            prune: struct {
                meta: usize,
                data: usize,
            },
        } = tl: {
            var meta_it = self.meta.iterator(.forward);
            var meta_consumed: usize = 0;
            while (meta_it.next()) |meta| {
                const prior_meta_consumed = meta_consumed;
                meta_consumed += meta.cell_map.items.len;
                const meta_i = start - prior_meta_consumed;
                if (meta_i >= meta.cell_map.items.len) continue;
                const end_i = end - prior_meta_consumed;
                if (end_i < meta.cell_map.items.len) {
                    @branchHint(.likely);
                    const start_map = meta.cell_map.items[meta_i];
                    const end_map = meta.cell_map.items[end_i];
                    result.top_x = start_map.x;
                    result.bot_x = end_map.x;
                    self.chunk_buf.appendAssumeCapacity(.{
                        .node = meta.node,
                        .serial = meta.serial,
                        .start = @intCast(start_map.y),
                        .end = @intCast(end_map.y + 1),
                    });
                    break :tl .{
                        .br = null,
                        .prune = .{
                            .meta = meta_it.idx - 1,
                            .data = prior_meta_consumed,
                        },
                    };
                } else {
                    const map = meta.cell_map.items[meta_i];
                    result.top_x = map.x;
                    self.chunk_buf.appendAssumeCapacity(.{
                        .node = meta.node,
                        .serial = meta.serial,
                        .start = @intCast(map.y),
                        .end = meta.rows,
                    });
                    break :tl .{
                        .br = .{
                            .it = meta_it,
                            .consumed = meta_consumed,
                        },
                        .prune = .{
                            .meta = meta_it.idx - 1,
                            .data = prior_meta_consumed,
                        },
                    };
                }
            } else {
                unreachable;
            }
        };
        if (tl.br) |br| {
            var meta_it = br.it;
            var meta_consumed: usize = br.consumed;
            while (meta_it.next()) |meta| {
                const meta_i = end - meta_consumed;
                if (meta_i >= meta.cell_map.items.len) {
                    self.chunk_buf.appendAssumeCapacity(.{
                        .node = meta.node,
                        .serial = meta.serial,
                        .start = 0,
                        .end = meta.rows,
                    });
                    meta_consumed += meta.cell_map.items.len;
                    continue;
                }
                const map = meta.cell_map.items[meta_i];
                result.bot_x = map.x;
                cross_page_end_rows = meta.rows;
                self.chunk_buf.appendAssumeCapacity(.{
                    .node = meta.node,
                    .serial = meta.serial,
                    .start = 0,
                    .end = @intCast(map.y + 1),
                });
                break;
            } else {
                unreachable;
            }
        }
        self.data_offset = start - tl.prune.data + 1;
        if (tl.prune.meta > 0) {
            var meta_it = self.meta.iterator(.forward);
            var meta_consumed: usize = 0;
            for (0..tl.prune.meta) |_| {
                const meta: *Meta = meta_it.next().?;
                meta_consumed += meta.cell_map.items.len;
                meta.deinit(self.alloc);
            }
            if (comptime std.debug.runtime_safety) {
                assert(meta_it.idx == tl.prune.meta);
                assert(meta_it.next().?.node == self.chunk_buf.items(.node)[0]);
            }
            self.meta.deleteOldest(tl.prune.meta);
            assert(tl.prune.data > 0);
            self.data.deleteOldest(tl.prune.data);
        }
        switch (self.direction) {
            .forward => {},
            .reverse => {
                const slice = self.chunk_buf.slice();
                const nodes = slice.items(.node);
                const serials = slice.items(.serial);
                const starts = slice.items(.start);
                const ends = slice.items(.end);
                if (self.chunk_buf.len > 1) {
                    std.mem.reverse(*PageList.List.Node, nodes);
                    std.mem.reverse(u64, serials);
                    std.mem.reverse(size.CellCountInt, starts);
                    std.mem.reverse(size.CellCountInt, ends);
                    assert(nodes.len >= 2);
                    starts[0] = ends[0] - 1;
                    ends[0] = cross_page_end_rows.?;
                    ends[nodes.len - 1] = starts[nodes.len - 1] + 1;
                    starts[nodes.len - 1] = 0;
                } else {
                    const start_y = starts[0];
                    starts[0] = ends[0] - 1;
                    ends[0] = start_y + 1;
                }
                const top_x = result.top_x;
                result.top_x = result.bot_x;
                result.bot_x = top_x;
            },
        }
        result.chunks = self.chunk_buf;
        return result;
    }
    pub fn append(
        self: *SlidingWindow,
        node: *PageList.List.Node,
    ) Allocator.Error!AppendResult {
        var preserved = try node.pagePreservingState(self.alloc);
        defer preserved.deinit();
        const page = preserved.page();
        const last_row_wrapped = page.getRow(page.size.rows - 1).wrap;
        return self.appendPage(node, page, last_row_wrapped);
    }
    pub fn appendIfWrapped(
        self: *SlidingWindow,
        node: *PageList.List.Node,
    ) Allocator.Error!?AppendResult {
        var preserved = try node.pagePreservingState(self.alloc);
        defer preserved.deinit();
        const page = preserved.page();
        const last_row_wrapped = page.getRow(page.size.rows - 1).wrap;
        if (!last_row_wrapped) return null;
        return try self.appendPage(node, page, last_row_wrapped);
    }
    fn appendPage(
        self: *SlidingWindow,
        node: *PageList.List.Node,
        page: *const terminal.Page,
        last_row_wrapped: bool,
    ) Allocator.Error!AppendResult {
        var meta: Meta = .{
            .node = node,
            .serial = node.serial,
            .rows = page.size.rows,
            .cell_map = .empty,
        };
        errdefer meta.deinit(self.alloc);
        var encoded: std.Io.Writer.Allocating = .init(self.alloc);
        defer encoded.deinit();
        const formatter: PageFormatter = formatter: {
            var formatter: PageFormatter = .init(page, .{
                .emit = .plain,
                .unwrap = true,
            });
            formatter.point_map = .{
                .alloc = self.alloc,
                .map = &meta.cell_map,
            };
            break :formatter formatter;
        };
        formatter.format(&encoded.writer) catch {
            return error.OutOfMemory;
        };
        assert(meta.cell_map.items.len == encoded.written().len);
        if (!last_row_wrapped) {
            encoded.writer.writeByte('\n') catch return error.OutOfMemory;
            try meta.cell_map.append(
                self.alloc,
                meta.cell_map.getLastOrNull() orelse .{
                    .x = 0,
                    .y = 0,
                },
            );
        }
        const written = encoded.written();
        if (written.len == 0) {
            self.assertIntegrity();
            return .{
                .content_len = 0,
                .last_row_wrapped = last_row_wrapped,
            };
        }
        switch (self.direction) {
            .forward => {},
            .reverse => {
                std.mem.reverse(u8, written);
                std.mem.reverse(point.Coordinate, meta.cell_map.items);
            },
        }
        try self.data.ensureUnusedCapacity(self.alloc, written.len);
        try self.meta.ensureUnusedCapacity(self.alloc, 1);
        try self.chunk_buf.ensureTotalCapacity(self.alloc, self.meta.capacity());
        self.data.appendSliceAssumeCapacity(written);
        self.meta.appendAssumeCapacity(meta);
        self.assertIntegrity();
        return .{
            .content_len = written.len,
            .last_row_wrapped = last_row_wrapped,
        };
    }
    fn testChangeNeedle(self: *SlidingWindow, new: []const u8) void {
        assert(new.len == self.needle.len);
        self.alloc.free(self.needle);
        self.needle = self.alloc.dupe(u8, new) catch unreachable;
    }
    fn assertIntegrity(self: *const SlidingWindow) void {
        if (comptime !std.debug.runtime_safety) return;
        if (std.valgrind.runningOnValgrind() > 0) return;
        var meta_it = self.meta.iterator(.forward);
        var data_len: usize = 0;
        while (meta_it.next()) |m| data_len += m.cell_map.items.len;
        assert(data_len == self.data.len());
        assert(self.data.len() == 0 or self.data_offset < self.data.len());
    }
};
test "SlidingWindow empty on init" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var w: SlidingWindow = try .init(alloc, .forward, "boo!");
    defer w.deinit();
    try testing.expectEqual(0, w.data.len());
    try testing.expectEqual(0, w.meta.len());
}
test "SlidingWindow empty needle has no matches" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var w: SlidingWindow = try .init(alloc, .forward, "");
    defer w.deinit();
    var s = try Screen.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_bytes = 0,
    });
    defer s.deinit();
    try s.testWriteString("hello");
    _ = try w.append(s.pages.pages.first.?);
    try testing.expectEqual(null, w.next());
}
test "SlidingWindow single append" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var w: SlidingWindow = try .init(alloc, .forward, "boo!");
    defer w.deinit();
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end));
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 22,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end));
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}
test "SlidingWindow single append case insensitive ASCII" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var w: SlidingWindow = try .init(alloc, .forward, "Boo!");
    defer w.deinit();
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end));
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 22,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end));
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}
test "SlidingWindow single append single char" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var w: SlidingWindow = try .init(alloc, .forward, "b");
    defer w.deinit();
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end));
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end));
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}
test "SlidingWindow single append no match" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var w: SlidingWindow = try .init(alloc, .forward, "nope!");
    defer w.deinit();
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
    try testing.expectEqual(1, w.meta.len());
}
test "SlidingWindow two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var w: SlidingWindow = try .init(alloc, .forward, "boo!");
    defer w.deinit();
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node.next.?);
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 79,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}
test "SlidingWindow two pages single char" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var w: SlidingWindow = try .init(alloc, .forward, "b");
    defer w.deinit();
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node.next.?);
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}
test "SlidingWindow two pages match across boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var w: SlidingWindow = try .init(alloc, .forward, "hello, world");
    defer w.deinit();
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("hell");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("o, world!");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node.next.?);
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
    try testing.expectEqual(2, w.meta.len());
}
test "SlidingWindow two pages no match across boundary with newline" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var w: SlidingWindow = try .init(alloc, .forward, "hello, world");
    defer w.deinit();
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("hell");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\no, world!");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node.next.?);
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
    try testing.expectEqual(2, w.meta.len());
}
test "SlidingWindow two pages no match across boundary with newline reverse" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var w: SlidingWindow = try .init(alloc, .reverse, "hello, world");
    defer w.deinit();
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("hell");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\no, world!");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node.next.?);
    _ = try w.append(node);
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}
test "SlidingWindow two pages no match prunes first page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var w: SlidingWindow = try .init(alloc, .forward, "nope!");
    defer w.deinit();
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node.next.?);
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
    try testing.expectEqual(1, w.meta.len());
}
test "SlidingWindow two pages no match keeps both pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");
    var needle_list: std.ArrayList(u8) = .empty;
    defer needle_list.deinit(alloc);
    try needle_list.appendNTimes(alloc, 'x', first_page_rows * s.pages.cols);
    const needle: []const u8 = needle_list.items;
    var w: SlidingWindow = try .init(alloc, .forward, needle);
    defer w.deinit();
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node.next.?);
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
    try testing.expectEqual(2, w.meta.len());
}
test "SlidingWindow single append across circular buffer boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var w: SlidingWindow = try .init(alloc, .forward, "abc");
    defer w.deinit();
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("XXXXXXXXXXXXXXXXXXXboo!XXXXX");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node);
    {
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len == 0);
    }
    try testing.expect(w.next() == null);
    try testing.expectEqual(1, w.meta.len());
    w.testChangeNeedle("boo");
    _ = try w.append(node);
    {
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len > 0);
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 21,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
}
test "SlidingWindow single append match on boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var w: SlidingWindow = try .init(alloc, .forward, "abcd");
    defer w.deinit();
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("o!XXXXXXXXXXXXXXXXXXXbo");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    node.page().getRow(node.rows() - 1).wrap = true;
    _ = try w.append(node);
    _ = try w.append(node);
    {
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len == 0);
    }
    try testing.expect(w.next() == null);
    try testing.expectEqual(1, w.meta.len());
    w.testChangeNeedle("boo!");
    _ = try w.append(node);
    {
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len > 0);
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 21,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
}
test "SlidingWindow single append reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var w: SlidingWindow = try .init(alloc, .reverse, "boo!");
    defer w.deinit();
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 22,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}
test "SlidingWindow single append no match reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var w: SlidingWindow = try .init(alloc, .reverse, "nope!");
    defer w.deinit();
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
    try testing.expectEqual(1, w.meta.len());
}
test "SlidingWindow two pages reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var w: SlidingWindow = try .init(alloc, .reverse, "boo!");
    defer w.deinit();
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node.next.?);
    _ = try w.append(node);
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 79,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}
test "SlidingWindow two pages match across boundary reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var w: SlidingWindow = try .init(alloc, .reverse, "hello, world");
    defer w.deinit();
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("hell");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("o, world!");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node.next.?);
    _ = try w.append(node);
    {
        const h = w.next().?;
        const chunks = h.chunks.slice();
        const nodes = chunks.items(.node);
        const serials = chunks.items(.serial);
        try testing.expectEqual(2, chunks.len);
        try testing.expectEqual(node, nodes[0]);
        try testing.expectEqual(node.serial, serials[0]);
        try testing.expectEqual(node.next.?, nodes[1]);
        try testing.expectEqual(node.next.?.serial, serials[1]);
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
    try testing.expectEqual(1, w.meta.len());
}
test "SlidingWindow two pages no match prunes first page reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var w: SlidingWindow = try .init(alloc, .reverse, "nope!");
    defer w.deinit();
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node.next.?);
    _ = try w.append(node);
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
    try testing.expectEqual(1, w.meta.len());
}
test "SlidingWindow two pages no match keeps both pages reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");
    var needle_list: std.ArrayList(u8) = .empty;
    defer needle_list.deinit(alloc);
    try needle_list.appendNTimes(alloc, 'x', first_page_rows * s.pages.cols);
    const needle: []const u8 = needle_list.items;
    var w: SlidingWindow = try .init(alloc, .reverse, needle);
    defer w.deinit();
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node.next.?);
    _ = try w.append(node);
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
    try testing.expectEqual(2, w.meta.len());
}
test "SlidingWindow single append across circular buffer boundary reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var w: SlidingWindow = try .init(alloc, .reverse, "abc");
    defer w.deinit();
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("XXXXXXXXXXXXXXXXXXXboo!XXXXX");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node);
    {
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len == 0);
    }
    try testing.expect(w.next() == null);
    try testing.expectEqual(1, w.meta.len());
    w.testChangeNeedle("oob");
    _ = try w.append(node);
    {
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len > 0);
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 21,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
}
test "SlidingWindow single append match on boundary reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var w: SlidingWindow = try .init(alloc, .reverse, "abcd");
    defer w.deinit();
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("o!XXXXXXXXXXXXXXXXXXXbo");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    node.page().getRow(node.rows() - 1).wrap = true;
    _ = try w.append(node);
    _ = try w.append(node);
    {
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len == 0);
    }
    try testing.expect(w.next() == null);
    try testing.expectEqual(1, w.meta.len());
    w.testChangeNeedle("!oob");
    _ = try w.append(node);
    {
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len > 0);
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 21,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
}
test "SlidingWindow single append soft wrapped" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var w: SlidingWindow = try .init(alloc, .forward, "boo!");
    defer w.deinit();
    var t: Terminal = try .init(io, alloc, .{ .cols = 4, .rows = 5 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("A\r\nxxboo!\r\nC");
    const screen = t.screens.active;
    try testing.expect(screen.pages.pages.first == screen.pages.pages.last);
    const node: *PageList.List.Node = screen.pages.pages.first.?;
    _ = try w.append(node);
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 2,
            .y = 1,
        } }, screen.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 2,
        } }, screen.pages.pointFromPin(.active, sel.end));
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}
test "SlidingWindow single append reversed soft wrapped" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var w: SlidingWindow = try .init(alloc, .reverse, "boo!");
    defer w.deinit();
    var t: Terminal = try .init(io, alloc, .{ .cols = 4, .rows = 5 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("A\r\nxxboo!\r\nC");
    const screen = t.screens.active;
    try testing.expect(screen.pages.pages.first == screen.pages.pages.last);
    const node: *PageList.List.Node = screen.pages.pages.first.?;
    _ = try w.append(node);
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 2,
            .y = 1,
        } }, screen.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 2,
        } }, screen.pages.pointFromPin(.active, sel.end));
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}
test "SlidingWindow append whitespace only node" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var w: SlidingWindow = try .init(alloc, .forward, "x");
    defer w.deinit();
    var s = try Screen.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_bytes = 0,
    });
    defer s.deinit();
    const node: *PageList.List.Node = s.pages.pages.first.?;
    const last_row = node.page().getRow(node.rows() - 1);
    last_row.wrap = true;
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    _ = try w.append(node);
    try testing.expect(w.next() == null);
}
