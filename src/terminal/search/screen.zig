const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const testing = std.testing;
const tripwire = @import("../../tripwire.zig");
const Allocator = std.mem.Allocator;
const point = @import("../point.zig");
const highlight = @import("../highlight.zig");
const size = @import("../size.zig");
const FlattenedHighlight = highlight.Flattened;
const TrackedHighlight = highlight.Tracked;
const PageList = @import("../PageList.zig");
const Pin = PageList.Pin;
const Screen = @import("../Screen.zig");
const Terminal = @import("../Terminal.zig");
const ActiveSearch = @import("active.zig").ActiveSearch;
const PageListSearch = @import("pagelist.zig").PageListSearch;
const SlidingWindow = @import("sliding_window.zig").SlidingWindow;
const log = std.log.scoped(.search_screen);
const reloadActive_tw = tripwire.module(enum {
    history_append_new,
    history_append_existing,
}, ScreenSearch.reloadActive);
pub const ScreenSearch = struct {
    screen: *Screen,
    active: ActiveSearch,
    history: ?HistorySearch,
    state: State,
    selected: ?SelectedMatch = null,
    history_results: std.ArrayList(FlattenedHighlight),
    active_results: std.ArrayList(FlattenedHighlight),
    rows: size.CellCountInt,
    cols: size.CellCountInt,
    pub const SelectedMatch = struct {
        idx: usize,
        highlight: TrackedHighlight,
        pub fn deinit(self: *SelectedMatch, screen: *Screen) void {
            self.highlight.deinit(screen);
        }
    };
    const HistorySearch = struct {
        searcher: PageListSearch,
        start_pin: *Pin,
        pub fn deinit(self: *HistorySearch, screen: *Screen) void {
            self.searcher.deinit();
            screen.pages.untrackPin(self.start_pin);
        }
    };
    const State = enum {
        active,
        history,
        history_feed,
        complete,
        pub fn isComplete(self: State) bool {
            return switch (self) {
                .complete => true,
                else => false,
            };
        }
        pub fn needsFeed(self: State) bool {
            return switch (self) {
                .history_feed => true,
                .complete => true,
                else => false,
            };
        }
    };
    pub fn init(
        alloc: Allocator,
        screen: *Screen,
        needle_unowned: []const u8,
    ) Allocator.Error!ScreenSearch {
        var result: ScreenSearch = .{
            .screen = screen,
            .rows = screen.pages.rows,
            .cols = screen.pages.cols,
            .active = try .init(alloc, needle_unowned),
            .history = null,
            .state = .active,
            .active_results = .empty,
            .history_results = .empty,
        };
        errdefer result.deinit();
        try result.reloadActive();
        return result;
    }
    pub fn deinit(self: *ScreenSearch) void {
        self.deinitInternal(true);
    }
    pub fn deinitScreenInvalid(self: *ScreenSearch) void {
        self.deinitInternal(false);
    }
    fn deinitInternal(self: *ScreenSearch, screen_valid: bool) void {
        const alloc = self.allocator();
        self.active.deinit();
        if (self.history) |*h| {
            if (screen_valid) {
                h.deinit(self.screen);
            } else {
                h.searcher.deinitListInvalid();
            }
        }
        if (screen_valid) {
            if (self.selected) |*m| m.deinit(self.screen);
        }
        for (self.active_results.items) |*hl| hl.deinit(alloc);
        self.active_results.deinit(alloc);
        for (self.history_results.items) |*hl| hl.deinit(alloc);
        self.history_results.deinit(alloc);
    }
    fn allocator(self: *ScreenSearch) Allocator {
        return self.active.window.alloc;
    }
    pub fn needle(self: *const ScreenSearch) []const u8 {
        assert(self.active.window.direction == .forward);
        return self.active.window.needle;
    }
    pub fn matchesLen(self: *const ScreenSearch) usize {
        return self.active_results.items.len + self.history_results.items.len;
    }
    fn resetIfDimensionsChanged(self: *ScreenSearch) Allocator.Error!bool {
        if (self.screen.pages.rows == self.rows and
            self.screen.pages.cols == self.cols)
        {
            return false;
        }
        const new: ScreenSearch = try .init(
            self.allocator(),
            self.screen,
            self.needle(),
        );
        self.deinit();
        self.* = new;
        assert(self.screen.pages.rows == self.rows);
        assert(self.screen.pages.cols == self.cols);
        return true;
    }
    pub fn matches(
        self: *ScreenSearch,
        alloc: Allocator,
    ) Allocator.Error![]FlattenedHighlight {
        const active_results = self.active_results.items;
        const history_results = self.history_results.items;
        const results = try alloc.alloc(
            FlattenedHighlight,
            active_results.len + history_results.len,
        );
        errdefer alloc.free(results);
        assert(self.active.window.direction == .forward);
        @memcpy(
            results[0..active_results.len],
            active_results,
        );
        std.mem.reverse(FlattenedHighlight, results[0..active_results.len]);
        @memcpy(
            results[active_results.len..],
            history_results,
        );
        return results;
    }
    pub fn searchAll(self: *ScreenSearch) Allocator.Error!void {
        while (true) {
            self.tick() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.FeedRequired => try self.feed(),
                error.SearchComplete => return,
            };
        }
    }
    pub const TickError = Allocator.Error || error{
        FeedRequired,
        SearchComplete,
    };
    pub fn tick(self: *ScreenSearch) TickError!void {
        switch (self.state) {
            .active => try self.tickActive(),
            .history => try self.tickHistory(),
            .history_feed => return error.FeedRequired,
            .complete => return error.SearchComplete,
        }
    }
    pub fn feed(self: *ScreenSearch) Allocator.Error!void {
        _ = try self.resetIfDimensionsChanged();
        const history: *PageListSearch = if (self.history) |*h| &h.searcher else {
            self.state = .complete;
            return;
        };
        if (!try history.feed()) {
            self.state = .complete;
            self.pruneHistory();
            return;
        }
        switch (self.state) {
            .active, .history => {},
            .history_feed => self.state = .history,
            .complete => self.state = .history,
        }
    }
    fn historyResultIsValid(
        self: *const ScreenSearch,
        hl: *const FlattenedHighlight,
    ) bool {
        const chunks = hl.chunks.slice();
        const nodes = chunks.items(.node);
        const serials = chunks.items(.serial);
        for (nodes, serials) |node, serial| {
            if (!self.screen.pages.nodeIsValid(node, serial)) return false;
        }
        return true;
    }
    fn validateSelectedHistory(self: *ScreenSearch) void {
        const m = if (self.selected) |*m| m else return;
        const active_len = self.active_results.items.len;
        if (m.idx < active_len) return;
        const history_idx = m.idx - active_len;
        if (history_idx < self.history_results.items.len and
            self.historyResultIsValid(&self.history_results.items[history_idx]))
        {
            return;
        }
        m.deinit(self.screen);
        self.selected = null;
    }
    fn pruneHistory(self: *ScreenSearch) void {
        var i: usize = 0;
        while (i < self.history_results.items.len) {
            const hl = &self.history_results.items[i];
            const chunks = hl.chunks.slice();
            const serials = chunks.items(.serial);
            const first_serial = serials[0];
            if (first_serial < self.screen.pages.page_serial_epoch) {
                const alloc = self.allocator();
                if (self.selected) |*m| {
                    const first_pruned = self.active_results.items.len + i;
                    if (m.idx >= first_pruned) {
                        m.deinit(self.screen);
                        self.selected = null;
                    }
                }
                for (self.history_results.items[i..]) |*prune_hl| prune_hl.deinit(alloc);
                self.history_results.shrinkAndFree(alloc, i);
                return;
            }
            if (self.historyResultIsValid(hl)) {
                i += 1;
                continue;
            }
            const result_idx = self.active_results.items.len + i;
            if (self.selected) |*m| {
                if (m.idx == result_idx) {
                    m.deinit(self.screen);
                    self.selected = null;
                } else if (m.idx > result_idx) {
                    m.idx -= 1;
                }
            }
            var removed = self.history_results.orderedRemove(i);
            removed.deinit(self.allocator());
        }
    }
    fn tickActive(self: *ScreenSearch) Allocator.Error!void {
        const alloc = self.allocator();
        while (self.active.next()) |hl| {
            var hl_cloned = try hl.clone(alloc);
            errdefer hl_cloned.deinit(alloc);
            try self.active_results.append(alloc, hl_cloned);
        }
        self.state = .history;
    }
    fn tickHistory(self: *ScreenSearch) Allocator.Error!void {
        const history: *HistorySearch = if (self.history) |*h| h else {
            self.state = .complete;
            return;
        };
        const alloc = self.allocator();
        while (history.searcher.next()) |hl| {
            if (hl.chunks.items(.node)[0] == history.start_pin.node) continue;
            var hl_cloned = try hl.clone(alloc);
            errdefer hl_cloned.deinit(alloc);
            try self.history_results.append(alloc, hl_cloned);
        }
        self.state = .history_feed;
    }
    pub fn reloadActive(self: *ScreenSearch) Allocator.Error!void {
        if (try self.resetIfDimensionsChanged()) return;
        self.validateSelectedHistory();
        const tw = reloadActive_tw;
        const select_prev: bool = select_prev: {
            const m = if (self.selected) |*m| m else break :select_prev false;
            if (!m.highlight.start.garbage and
                !m.highlight.end.garbage) break :select_prev false;
            m.deinit(self.screen);
            self.selected = null;
            break :select_prev true;
        };
        defer if (select_prev) {
            _ = self.select(.prev) catch |err| {
                log.info("reload failed to reset search selection err={}", .{err});
            };
        };
        const alloc = self.allocator();
        const list: *PageList = &self.screen.pages;
        if (try self.active.update(list)) |history_node| history: {
            if (self.screen.no_scrollback) {
                assert(self.history == null);
                break :history;
            }
            const history_: ?*HistorySearch = if (self.history) |*h| state: {
                if (h.start_pin.garbage) {
                    h.deinit(self.screen);
                    self.history = null;
                    for (self.history_results.items) |*hl| hl.deinit(alloc);
                    self.history_results.clearRetainingCapacity();
                    break :state null;
                }
                break :state h;
            } else null;
            const history = history_ orelse {
                var search: PageListSearch = try .init(
                    alloc,
                    self.needle(),
                    list,
                    history_node,
                );
                errdefer search.deinit();
                const pin = try list.trackPin(.{ .node = history_node });
                errdefer list.untrackPin(pin);
                self.history = .{
                    .searcher = search,
                    .start_pin = pin,
                };
                break :history;
            };
            if (history.start_pin.node == history_node) {
                break :history;
            }
            var window: SlidingWindow = try .init(
                alloc,
                .forward,
                self.needle(),
            );
            defer window.deinit();
            while (true) {
                _ = try window.append(history.start_pin.node);
                if (history.start_pin.node == history_node) break;
                const next = history.start_pin.node.next orelse break;
                history.start_pin.node = next;
            }
            assert(history.start_pin.node == history_node);
            var results: std.ArrayList(FlattenedHighlight) = try .initCapacity(
                alloc,
                self.history_results.items.len,
            );
            errdefer {
                for (results.items) |*hl| hl.deinit(alloc);
                results.deinit(alloc);
            }
            while (window.next()) |hl| {
                if (hl.chunks.items(.node)[0] == history_node) continue;
                var hl_cloned = try hl.clone(alloc);
                errdefer hl_cloned.deinit(alloc);
                try tw.check(.history_append_new);
                try results.append(alloc, hl_cloned);
            }
            if (results.items.len == 0) break :history;
            const added_len = results.items.len;
            std.mem.reverse(FlattenedHighlight, results.items);
            try tw.check(.history_append_existing);
            try results.appendSlice(alloc, self.history_results.items);
            self.history_results.deinit(alloc);
            self.history_results = results;
            if (self.selected) |*m| selected: {
                const active_len = self.active_results.items.len;
                if (m.idx < active_len) break :selected;
                m.idx += added_len;
                if (comptime std.debug.runtime_safety) {
                    const hl = self.history_results.items[m.idx - active_len];
                    assert(m.highlight.start.eql(hl.startPin()));
                }
            }
        } else {
            if (self.history) |*h| {
                h.deinit(self.screen);
                self.history = null;
                for (self.history_results.items) |*hl| hl.deinit(alloc);
                self.history_results.clearRetainingCapacity();
            }
            if (self.selected) |*m| selected: {
                const active_len = self.active_results.items.len;
                if (m.idx < active_len) break :selected;
                m.deinit(self.screen);
                self.selected = null;
                _ = self.select(.prev) catch |err| {
                    log.info("reload failed to reset search selection err={}", .{err});
                };
            }
        }
        const old_active_len = self.active_results.items.len;
        const old_selection_idx: ?usize = if (self.selected) |m| m.idx else null;
        errdefer if (old_selection_idx != null and
            old_selection_idx.? < old_active_len)
        {
            if (self.selected) |*m| {
                m.deinit(self.screen);
                self.selected = null;
                _ = self.select(.next) catch |err| {
                    log.info("reload failed to reset search selection err={}", .{err});
                };
            }
        };
        for (self.active_results.items) |*hl| hl.deinit(alloc);
        self.active_results.clearRetainingCapacity();
        switch (self.state) {
            .active => try self.tickActive(),
            else => {
                const old_state = self.state;
                defer self.state = old_state;
                try self.tickActive();
            },
        }
        if (self.screen.no_scrollback and
            self.active_results.items.len > 0)
        active_prune: {
            const items = self.active_results.items;
            const tl = self.screen.pages.getTopLeft(.active);
            for (0.., items) |i, *hl| {
                if (!tl.before(hl.endPin())) {
                    hl.deinit(alloc);
                    continue;
                }
                if (i > 0) self.active_results.replaceRangeAssumeCapacity(
                    0,
                    i,
                    &.{},
                );
                break :active_prune;
            }
            self.active_results.clearRetainingCapacity();
        }
        fixup: {
            const old_idx = old_selection_idx orelse break :fixup;
            const m = if (self.selected) |*m| m else break :fixup;
            if (old_idx >= old_active_len) {
                m.idx -= old_active_len;
                m.idx += self.active_results.items.len;
                break :fixup;
            }
            for (0.., self.active_results.items) |i, hl| {
                const untracked = hl.untracked();
                if (m.highlight.start.eql(untracked.start) and
                    m.highlight.end.eql(untracked.end))
                {
                    m.idx = self.active_results.items.len - 1 - i;
                    break :fixup;
                }
            }
            m.deinit(self.screen);
            self.selected = null;
            _ = self.select(.next) catch |err| {
                log.info("reload failed to reset search selection err={}", .{err});
            };
        }
    }
    pub fn matchAt(self: *const ScreenSearch, idx: usize) ?FlattenedHighlight {
        const active_len = self.active_results.items.len;
        if (idx < active_len) {
            return self.active_results.items[active_len - 1 - idx];
        }
        const history_len = self.history_results.items.len;
        if (idx < active_len + history_len) {
            return self.history_results.items[idx - active_len];
        }
        return null;
    }
    pub fn selectedMatch(self: *const ScreenSearch) ?FlattenedHighlight {
        const sel = self.selected orelse return null;
        return self.matchAt(sel.idx);
    }
    pub const Select = enum {
        next,
        prev,
    };
    pub fn select(self: *ScreenSearch, to: Select) Allocator.Error!bool {
        _ = try self.resetIfDimensionsChanged();
        try self.reloadActive();
        self.pruneHistory();
        return switch (to) {
            .next => try self.selectNext(),
            .prev => try self.selectPrev(),
        };
    }
    fn selectNext(self: *ScreenSearch) Allocator.Error!bool {
        var prev = if (self.selected) |*m| m else {
            const hl: FlattenedHighlight = hl: {
                if (self.active_results.items.len > 0) {
                    const len = self.active_results.items.len;
                    break :hl self.active_results.items[len - 1];
                } else if (self.history_results.items.len > 0) {
                    break :hl self.history_results.items[0];
                } else {
                    return false;
                }
            };
            const tracked = try hl.untracked().track(self.screen);
            errdefer tracked.deinit(self.screen);
            self.selected = .{
                .idx = 0,
                .highlight = tracked,
            };
            return true;
        };
        const active_len = self.active_results.items.len;
        const history_len = self.history_results.items.len;
        const next_idx = if (prev.idx + 1 >= active_len + history_len) 0 else prev.idx + 1;
        const hl: FlattenedHighlight = if (next_idx < active_len)
            self.active_results.items[active_len - 1 - next_idx]
        else
            self.history_results.items[next_idx - active_len];
        const tracked = try hl.untracked().track(self.screen);
        errdefer tracked.deinit(self.screen);
        prev.deinit(self.screen);
        self.selected = .{
            .idx = next_idx,
            .highlight = tracked,
        };
        return true;
    }
    fn selectPrev(self: *ScreenSearch) Allocator.Error!bool {
        var prev = if (self.selected) |*m| m else {
            const hl: FlattenedHighlight = hl: {
                if (self.history_results.items.len > 0) {
                    const len = self.history_results.items.len;
                    break :hl self.history_results.items[len - 1];
                } else if (self.active_results.items.len > 0) {
                    break :hl self.active_results.items[0];
                } else {
                    return false;
                }
            };
            const tracked = try hl.untracked().track(self.screen);
            errdefer tracked.deinit(self.screen);
            const active_len = self.active_results.items.len;
            const history_len = self.history_results.items.len;
            self.selected = .{
                .idx = active_len + history_len - 1,
                .highlight = tracked,
            };
            return true;
        };
        const active_len = self.active_results.items.len;
        const history_len = self.history_results.items.len;
        const next_idx = if (prev.idx != 0) prev.idx - 1 else active_len + history_len - 1;
        const hl: FlattenedHighlight = if (next_idx < active_len)
            self.active_results.items[active_len - 1 - next_idx]
        else
            self.history_results.items[next_idx - active_len];
        const tracked = try hl.untracked().track(self.screen);
        errdefer tracked.deinit(self.screen);
        prev.deinit(self.screen);
        self.selected = .{
            .idx = next_idx,
            .highlight = tracked,
        };
        return true;
    }
};
test "simple search" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");
    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(2, search.active_results.items.len);
    const matches = try search.matches(alloc);
    defer alloc.free(matches);
    try testing.expectEqual(2, matches.len);
    {
        const sel = matches[0].untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
    {
        const sel = matches[1].untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
}
test "simple search with history" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\n");
    while (list.totalPages() < 3) s.nextSlice("\r\n");
    for (0..list.rows) |_| s.nextSlice("\r\n");
    s.nextSlice("hello.");
    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(0, search.active_results.items.len);
    const matches = try search.matches(alloc);
    defer alloc.free(matches);
    try testing.expectEqual(1, matches.len);
    {
        const sel = matches[0].untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
}
test "reload active with history change" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\n");
    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    {
        const matches = try search.matches(alloc);
        defer alloc.free(matches);
        try testing.expectEqual(1, matches.len);
    }
    while (list.totalPages() < 2) s.nextSlice("\r\n");
    for (0..list.rows) |_| s.nextSlice("\r\n");
    s.nextSlice("2Fizz");
    try search.reloadActive();
    try search.searchAll();
    {
        const matches = try search.matches(alloc);
        defer alloc.free(matches);
        try testing.expectEqual(2, matches.len);
        {
            const sel = matches[1].untracked();
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 0,
                .y = 0,
            } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 3,
                .y = 0,
            } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
        }
        {
            const sel = matches[0].untracked();
            try testing.expectEqual(point.Point{ .active = .{
                .x = 1,
                .y = 1,
            } }, t.screens.active.pages.pointFromPin(.active, sel.start).?);
            try testing.expectEqual(point.Point{ .active = .{
                .x = 4,
                .y = 1,
            } }, t.screens.active.pages.pointFromPin(.active, sel.end).?);
        }
    }
    t.fullReset();
    s.nextSlice("WeFizzing");
    try search.reloadActive();
    try search.searchAll();
    {
        const matches = try search.matches(alloc);
        defer alloc.free(matches);
        try testing.expectEqual(1, matches.len);
        {
            const sel = matches[0].untracked();
            try testing.expectEqual(point.Point{ .active = .{
                .x = 2,
                .y = 0,
            } }, t.screens.active.pages.pointFromPin(.active, sel.start).?);
            try testing.expectEqual(point.Point{ .active = .{
                .x = 5,
                .y = 0,
            } }, t.screens.active.pages.pointFromPin(.active, sel.end).?);
        }
    }
}
test "active change contents" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fuzz\r\nBuzz\r\nFizz\r\nBang");
    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(1, search.active_results.items.len);
    s.nextSlice("\x1b[2J\x1b[H"); 
    s.nextSlice("Bang\r\nFizz\r\nHello!");
    try search.reloadActive();
    try search.searchAll();
    try testing.expectEqual(1, search.active_results.items.len);
    const matches = try search.matches(alloc);
    defer alloc.free(matches);
    try testing.expectEqual(1, matches.len);
    {
        const sel = matches[0].untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
}
test "select next" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");
    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try testing.expect(search.selectedMatch() == null);
    try search.searchAll();
    _ = try search.select(.next);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
    _ = try search.select(.next);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
    _ = try search.select(.next);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
}
test "select after resize resets stale flattened results" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 3,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("Fizz\r\nBuzz");
    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    try testing.expect(try search.select(.next));
    try testing.expect(search.selectedMatch() != null);
    try testing.expectEqual(@as(size.CellCountInt, 10), search.cols);
    try t.screens.active.pages.resize(.{ .cols = 5 });
    try testing.expectEqual(@as(size.CellCountInt, 10), search.cols);
    try testing.expect(try search.select(.next));
    try testing.expectEqual(@as(size.CellCountInt, 5), search.cols);
    const selected = search.selectedMatch().?.untracked();
    try testing.expectEqual(@as(size.CellCountInt, 5), selected.start.node.cols());
    try testing.expectEqual(@as(size.CellCountInt, 5), selected.end.node.cols());
}
test "select in active changes contents completely" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");
    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    _ = try search.select(.next);
    _ = try search.select(.next);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
    s.nextSlice("\x1b[2J\x1b[H"); 
    s.nextSlice("Fuzz\r\nFizz\r\nHello!");
    try search.reloadActive();
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
    s.nextSlice("\x1b[2J\x1b[H"); 
    s.nextSlice("Fuzz\r\nFizz\r\nFizz");
    try search.reloadActive();
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
}
test "select into history" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\n");
    while (list.totalPages() < 3) s.nextSlice("\r\n");
    for (0..list.rows) |_| s.nextSlice("\r\n");
    s.nextSlice("hello.");
    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    _ = try search.select(.next);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
    s.nextSlice("\x1b[2J\x1b[H"); 
    s.nextSlice("yo yo");
    try search.reloadActive();
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
    s.nextSlice("\r\nfizz\r\nfizz\r\nfizz"); 
    try search.reloadActive();
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
}
test "select prev" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");
    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try testing.expect(search.selectedMatch() == null);
    try search.searchAll();
    _ = try search.select(.prev);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
    _ = try search.select(.prev);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
    _ = try search.select(.prev);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
}
test "select prev then next" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");
    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    _ = try search.select(.next);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
    }
    _ = try search.select(.next);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
    }
    _ = try search.select(.prev);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
    }
}
test "select prev with history" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\n");
    while (list.totalPages() < 3) s.nextSlice("\r\n");
    for (0..list.rows) |_| s.nextSlice("\r\n");
    s.nextSlice("Fizz.");
    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    _ = try search.select(.prev);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
    _ = try search.select(.prev);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 3,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.active, sel.end).?);
    }
}
test "select prev wraps when all matches are in history" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\n");
    while (list.totalPages() < 3) s.nextSlice("\r\n");
    for (0..list.rows) |_| s.nextSlice("\r\n");
    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(0, search.active_results.items.len);
    _ = try search.select(.next);
    _ = try search.select(.prev);
    try testing.expect(search.selectedMatch() != null);
}
test "select after all matches disappear drops the selection" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz");
    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(1, search.active_results.items.len);
    _ = try search.select(.next);
    try testing.expect(search.selectedMatch() != null);
    s.nextSlice("\x1b[1;1H    ");
    _ = try search.select(.prev);
    try testing.expect(search.selectedMatch() == null);
    try testing.expectEqual(0, search.active_results.items.len);
    try testing.expectEqual(0, search.history_results.items.len);
}
test "select after partial history erase drops a pruned selection" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("error\r\n");
    const first = list.pages.first.?;
    while (list.totalPages() < 3) stream.nextSlice("\r\n");
    const first_rows = first.rows();
    var search: ScreenSearch = try .init(alloc, t.screens.active, "error");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(0, search.active_results.items.len);
    try testing.expectEqual(1, search.history_results.items.len);
    try testing.expect(try search.select(.next));
    list.eraseHistory(.{ .history = .{ .y = first_rows - 1 } });
    try testing.expect(!search.selected.?.highlight.start.garbage);
    try testing.expect(!try search.select(.next));
    try testing.expect(search.selected == null);
}
test "select after history compaction ignores replaced results" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("error\r\n");
    const first = list.pages.first.?;
    while (list.totalPages() < 3) stream.nextSlice("\r\n");
    try list.split(.{
        .node = first,
        .y = first.rows() / 2,
        .x = 0,
    });
    var search: ScreenSearch = try .init(alloc, t.screens.active, "error");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(1, search.history_results.items.len);
    const replacement = (try list.compact(first)).?;
    try testing.expect(replacement != first);
    try testing.expect(!try search.select(.next));
    try testing.expect(search.selected == null);
}
test "select after partial history page erase ignores shifted results" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;
    var stream = t.vtStream();
    defer stream.deinit();
    const first = list.pages.first.?;
    while (first.rows() < first.capacity().rows) stream.nextSlice("\r\n");
    stream.nextSlice("error");
    for (0..list.rows + 1) |_| stream.nextSlice("\r\n");
    try testing.expect(first != list.pages.last.?);
    var search: ScreenSearch = try .init(alloc, t.screens.active, "error");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(0, search.active_results.items.len);
    try testing.expectEqual(1, search.history_results.items.len);
    const old_rows = first.rows();
    list.eraseHistory(.{ .history = .{ .y = 0 } });
    try testing.expectEqual(old_rows - 1, first.rows());
    try testing.expect(!try search.select(.next));
    try testing.expect(search.selected == null);
}
test "reload defers pruning unselected history results" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;
    var stream = t.vtStream();
    defer stream.deinit();
    const first = list.pages.first.?;
    while (first.rows() < first.capacity().rows) stream.nextSlice("\r\n");
    stream.nextSlice("error");
    for (0..list.rows + 1) |_| stream.nextSlice("\r\n");
    var search: ScreenSearch = try .init(alloc, t.screens.active, "error");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(1, search.history_results.items.len);
    list.eraseHistory(.{ .history = .{ .y = 0 } });
    try search.reloadActive();
    try testing.expectEqual(1, search.history_results.items.len);
    try testing.expect(!try search.select(.next));
    try testing.expectEqual(0, search.history_results.items.len);
}
test "reload after partial history page erase drops shifted selection first" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;
    var stream = t.vtStream();
    defer stream.deinit();
    const first = list.pages.first.?;
    while (first.rows() < first.capacity().rows) stream.nextSlice("\r\n");
    stream.nextSlice("error");
    for (0..list.rows + 1) |_| stream.nextSlice("\r\n");
    var search: ScreenSearch = try .init(alloc, t.screens.active, "error");
    defer search.deinit();
    try search.searchAll();
    try testing.expect(try search.select(.next));
    try testing.expect(search.selected != null);
    list.eraseHistory(.{ .history = .{ .y = 0 } });
    const active_node = list.getTopLeft(.active).node;
    while (list.getTopLeft(.active).node == active_node) {
        stream.nextSlice("error\r\n");
    }
    try search.reloadActive();
    try testing.expect(search.selected == null);
}
test "select after history page split ignores moved results" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;
    var stream = t.vtStream();
    defer stream.deinit();
    const first = list.pages.first.?;
    while (first.rows() < first.capacity().rows) stream.nextSlice("\r\n");
    stream.nextSlice("error");
    for (0..list.rows + 1) |_| stream.nextSlice("\r\n");
    var search: ScreenSearch = try .init(alloc, t.screens.active, "error");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(1, search.history_results.items.len);
    try list.split(.{
        .node = first,
        .y = first.rows() / 2,
        .x = 0,
    });
    try testing.expect(!try search.select(.next));
    try testing.expect(search.selected == null);
}
test "screen search no scrollback has no history" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback_bytes = 0,
    });
    defer t.deinit(alloc);
    _ = try t.switchScreen(.alternate);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\n");
    s.nextSlice("\x1b[22J");
    s.nextSlice("hello.");
    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(0, search.active_results.items.len);
    const matches = try search.matches(alloc);
    defer alloc.free(matches);
    try testing.expectEqual(0, matches.len);
}
test "reloadActive partial history cleanup on appendSlice error" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\nFizz\r\n");
    while (list.totalPages() < 3) s.nextSlice("\r\n");
    for (0..list.rows) |_| s.nextSlice("\r\n");
    s.nextSlice("Fizz.");
    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    s.nextSlice("\r\nFizz\r\nFizz\r\n");
    while (list.totalPages() < 4) s.nextSlice("\r\n");
    for (0..list.rows) |_| s.nextSlice("\r\n");
    const tw = reloadActive_tw;
    defer tw.end(.reset) catch unreachable;
    tw.errorAlways(.history_append_existing, error.OutOfMemory);
    try testing.expectError(error.OutOfMemory, search.select(.next));
}
test "reloadActive partial history cleanup on loop append error" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\nFizz\r\n");
    while (list.totalPages() < 3) s.nextSlice("\r\n");
    for (0..list.rows) |_| s.nextSlice("\r\n");
    s.nextSlice("Fizz.");
    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    s.nextSlice("\r\nFizz\r\nFizz\r\n");
    while (list.totalPages() < 4) s.nextSlice("\r\n");
    for (0..list.rows) |_| s.nextSlice("\r\n");
    const tw = reloadActive_tw;
    defer tw.end(.reset) catch unreachable;
    tw.errorAfter(.history_append_new, error.OutOfMemory, 1);
    try testing.expectError(error.OutOfMemory, search.select(.next));
}
test "select after clearing scrollback" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("error\r\n");
    while (list.totalPages() < 3) s.nextSlice("error\r\n");
    for (0..list.rows) |_| s.nextSlice("\r\n");
    s.nextSlice("error.");
    var search: ScreenSearch = try .init(alloc, t.screens.active, "error");
    defer search.deinit();
    try search.searchAll();
    try testing.expect(search.history_results.items.len > 0);
    try testing.expect(search.active_results.items.len > 0);
    _ = try search.select(.next);
    try testing.expect(search.selected != null);
    t.eraseDisplay(.scrollback, false);
    _ = try search.select(.next);
    _ = try search.select(.prev);
}
test "feed after complete discovers prepended history pages" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("st\r\nTest\r\n");
    while (list.totalPages() < 2) s.nextSlice("\r\n");
    for (0..list.rows) |_| s.nextSlice("\r\n");
    s.nextSlice("Test");
    const old_first = list.pages.first.?;
    var search: ScreenSearch = try .init(alloc, t.screens.active, "Test");
    defer search.deinit();
    try search.searchAll();
    try testing.expect(search.state.isComplete());
    try testing.expectEqual(1, search.active_results.items.len);
    try testing.expectEqual(1, search.history_results.items.len);
    try testing.expect(try search.select(.prev));
    const selected_idx = search.selected.?.idx;
    try testing.expectEqual(1, selected_idx);
    const selected_before = search.selectedMatch().?.untracked();
    try testing.expectEqual(old_first, selected_before.start.node);
    {
        var allocation = try list.allocatePage(.{ .cols = 10, .rows = 2 });
        defer allocation.deinit();
        const page = allocation.page();
        page.size.rows = 2;
        for ("Test", 0..) |c, x| page.getRowAndCell(x, 0).cell.* = .init(c);
        for ("xxxxxxxxTe", 0..) |c, x| page.getRowAndCell(x, 1).cell.* = .init(c);
        page.getRow(1).wrap = true;
        old_first.page().getRow(0).wrap_continuation = true;
        try allocation.finalize(.prepend, .{});
    }
    const newest = list.pages.first.?;
    try search.feed();
    try testing.expect(!search.state.isComplete());
    try search.searchAll();
    try testing.expectEqual(1, search.active_results.items.len);
    try testing.expectEqual(3, search.history_results.items.len);
    {
        const boundary = search.history_results.items[1].untracked();
        try testing.expectEqual(newest, boundary.start.node);
        try testing.expectEqual(old_first, boundary.end.node);
        try testing.expectEqual(@as(size.CellCountInt, 1), boundary.start.y);
        try testing.expectEqual(@as(size.CellCountInt, 8), boundary.start.x);
        try testing.expectEqual(@as(size.CellCountInt, 0), boundary.end.y);
        try testing.expectEqual(@as(size.CellCountInt, 1), boundary.end.x);
        const str = try t.screens.active.selectionString(alloc, .{
            .sel = .init(boundary.start, boundary.end, false),
        });
        defer alloc.free(str);
        try testing.expectEqualStrings("Test", str);
    }
    {
        const oldest = search.history_results.items[2].untracked();
        try testing.expectEqual(newest, oldest.start.node);
        try testing.expectEqual(@as(size.CellCountInt, 0), oldest.start.y);
        try testing.expectEqual(@as(size.CellCountInt, 0), oldest.start.x);
    }
    try testing.expectEqual(selected_idx, search.selected.?.idx);
    {
        const selected_after = search.selectedMatch().?.untracked();
        try testing.expect(selected_before.start.eql(selected_after.start));
        try testing.expect(selected_before.end.eql(selected_after.end));
    }
    {
        var allocation = try list.allocatePage(.{ .cols = 10, .rows = 2 });
        defer allocation.deinit();
        const page = allocation.page();
        page.size.rows = 2;
        for ("Test", 0..) |c, x| page.getRowAndCell(x, 0).cell.* = .init(c);
        try allocation.finalize(.prepend, .{});
    }
    const oldest_node = list.pages.first.?;
    try search.feed();
    try search.searchAll();
    try testing.expectEqual(4, search.history_results.items.len);
    try testing.expectEqual(
        oldest_node,
        search.history_results.items[3].untracked().start.node,
    );
    try testing.expectEqual(selected_idx, search.selected.?.idx);
    {
        const selected_after = search.selectedMatch().?.untracked();
        try testing.expect(selected_before.start.eql(selected_after.start));
        try testing.expect(selected_before.end.eql(selected_after.end));
    }
    try search.feed();
    try testing.expect(search.state.isComplete());
    try testing.expectEqual(5, search.matchesLen());
}
