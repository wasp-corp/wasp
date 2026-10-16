const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const point = @import("../point.zig");
const FlattenedHighlight = @import("../highlight.zig").Flattened;
const ScreenSet = @import("../ScreenSet.zig");
const Terminal = @import("../Terminal.zig");
const ScreenSearch = @import("screen.zig").ScreenSearch;
const ViewportSearch = @import("viewport.zig").ViewportSearch;
const log = std.log.scoped(.search_terminal);
pub const TerminalSearch = struct {
    alloc: Allocator,
    viewport: ViewportSearch,
    screens: std.EnumMap(ScreenSet.Key, ScreenSearch),
    screen_generations: std.EnumMap(ScreenSet.Key, usize),
    active_key: ScreenSet.Key,
    stale_viewport_matches: bool,
    viewport_matches: std.ArrayList(FlattenedHighlight),
    pub const Status = enum {
        running,
        feed_required,
        complete,
    };
    pub const SelectScroll = enum {
        if_needed,
        none,
    };
    pub fn init(
        alloc: Allocator,
        needle_unowned: []const u8,
    ) Allocator.Error!TerminalSearch {
        var vp: ViewportSearch = try .init(alloc, needle_unowned);
        errdefer vp.deinit();
        vp.active_dirty = true;
        return .{
            .alloc = alloc,
            .viewport = vp,
            .screens = .init(.{}),
            .screen_generations = .init(.{}),
            .active_key = .primary,
            .stale_viewport_matches = true,
            .viewport_matches = .empty,
        };
    }
    pub fn deinit(self: *TerminalSearch, t_: ?*Terminal) void {
        self.clearViewportMatches();
        self.viewport_matches.deinit(self.alloc);
        self.viewport.deinit();
        var it = self.screens.iterator();
        while (it.next()) |entry| {
            const valid = if (t_) |t| self.screenIsValid(
                &t.screens,
                entry.key,
                entry.value,
            ) else false;
            if (valid) {
                entry.value.deinit();
            } else {
                entry.value.deinitScreenInvalid();
            }
        }
    }
    fn screenIsValid(
        self: *const TerminalSearch,
        screens: *const ScreenSet,
        key: ScreenSet.Key,
        search: *const ScreenSearch,
    ) bool {
        const generation = self.screen_generations.get(key) orelse return false;
        if (generation != screens.generation(key)) return false;
        const actual = screens.get(key) orelse return false;
        return actual == search.screen;
    }
    pub fn needle(self: *const TerminalSearch) []const u8 {
        return self.viewport.needle();
    }
    pub fn activeScreenSearch(self: *TerminalSearch) ?*ScreenSearch {
        return self.screens.getPtr(self.active_key);
    }
    pub fn isComplete(self: *TerminalSearch) bool {
        var it = self.screens.iterator();
        while (it.next()) |entry| {
            if (!entry.value.state.isComplete()) return false;
        }
        return true;
    }
    pub fn status(self: *TerminalSearch) Status {
        var saw_any = false;
        var result: Status = .complete;
        var it = self.screens.iterator();
        while (it.next()) |entry| {
            saw_any = true;
            switch (entry.value.state) {
                .active, .history => return .running,
                .history_feed => result = .feed_required,
                .complete => {},
            }
        }
        if (!saw_any) return .feed_required;
        return result;
    }
    pub const Tick = enum {
        complete,
        progress,
        blocked,
    };
    pub fn tick(self: *TerminalSearch) Tick {
        var result: Tick = .complete;
        var it = self.screens.iterator();
        while (it.next()) |entry| {
            if (entry.value.tick()) {
                result = .progress;
            } else |err| switch (err) {
                error.OutOfMemory => log.warn(
                    "error ticking screen search key={} err={}",
                    .{ entry.key, err },
                ),
                error.SearchComplete => {},
                error.FeedRequired => switch (result) {
                    .complete => result = .blocked,
                    .progress => {},
                    .blocked => {},
                },
            }
        }
        return result;
    }
    pub fn feed(
        self: *TerminalSearch,
        t: *Terminal,
        active_dirty: bool,
    ) void {
        const alloc = self.alloc;
        if (t.screens.active_key != self.active_key) {
            self.active_key = t.screens.active_key;
        }
        {
            var it = self.screens.iterator();
            while (it.next()) |entry| {
                const remove = !self.screenIsValid(
                    &t.screens,
                    entry.key,
                    entry.value,
                );
                if (remove) {
                    entry.value.deinitScreenInvalid();
                    _ = self.screens.remove(entry.key);
                    _ = self.screen_generations.remove(entry.key);
                }
            }
        }
        {
            var it = t.screens.all.iterator();
            while (it.next()) |entry| {
                if (self.screens.contains(entry.key)) continue;
                const screen_search = ScreenSearch.init(
                    alloc,
                    entry.value.*,
                    self.viewport.needle(),
                ) catch |err| switch (err) {
                    error.OutOfMemory => {
                        log.warn(
                            "error initializing screen search for key={} err={}",
                            .{ entry.key, err },
                        );
                        continue;
                    },
                };
                self.screens.put(entry.key, screen_search);
                self.screen_generations.put(
                    entry.key,
                    t.screens.generation(entry.key),
                );
            }
        }
        if (active_dirty) {
            self.viewport.active_dirty = true;
            if (self.screens.getPtr(t.screens.active_key)) |screen_search| {
                screen_search.reloadActive() catch |err| switch (err) {
                    error.OutOfMemory => log.warn(
                        "error reloading active area for screen key={} err={}",
                        .{ t.screens.active_key, err },
                    ),
                };
            }
        }
        if (self.viewport.update(&t.screens.active.pages)) |updated| {
            if (updated) self.stale_viewport_matches = true;
        } else |err| switch (err) {
            error.OutOfMemory => log.warn(
                "error updating viewport search err={}",
                .{err},
            ),
        }
        var it = self.screens.iterator();
        while (it.next()) |entry| {
            if (entry.value.state.needsFeed()) {
                entry.value.feed() catch |err| switch (err) {
                    error.OutOfMemory => log.warn(
                        "error feeding screen search key={} err={}",
                        .{ entry.key, err },
                    ),
                };
            }
        }
    }
    pub fn viewportMatches(
        self: *TerminalSearch,
    ) Allocator.Error![]const FlattenedHighlight {
        if (!self.stale_viewport_matches) return self.viewport_matches.items;
        self.stale_viewport_matches = false;
        self.clearViewportMatches();
        errdefer {
            self.clearViewportMatches();
            self.viewport.reset();
        }
        while (self.viewport.next()) |hl| {
            var hl_cloned = try hl.clone(self.alloc);
            errdefer hl_cloned.deinit(self.alloc);
            try self.viewport_matches.append(self.alloc, hl_cloned);
        }
        return self.viewport_matches.items;
    }
    fn clearViewportMatches(self: *TerminalSearch) void {
        for (self.viewport_matches.items) |*hl| hl.deinit(self.alloc);
        self.viewport_matches.clearRetainingCapacity();
    }
    pub fn select(
        self: *TerminalSearch,
        t: *Terminal,
        to: ScreenSearch.Select,
        scroll: SelectScroll,
    ) Allocator.Error!bool {
        self.feed(t, false);
        const screen_search = self.screens.getPtr(self.active_key) orelse
            return false;
        _ = try screen_search.select(to);
        const flattened = screen_search.selectedMatch() orelse return false;
        switch (scroll) {
            .none => return true,
            .if_needed => {},
        }
        const screen = t.screens.get(self.active_key) orelse return true;
        var it = screen.pages.pageIterator(
            .right_down,
            .{ .viewport = .{} },
            null,
        );
        const hl_chunks = flattened.chunks.slice();
        while (it.next()) |chunk| {
            for (0..hl_chunks.len) |i| {
                const hl_chunk = hl_chunks.get(i);
                if (chunk.overlaps(.{
                    .node = hl_chunk.node,
                    .start = hl_chunk.start,
                    .end = hl_chunk.end,
                })) return true;
            }
        }
        screen.scroll(.{ .pin = flattened.startPin() });
        return true;
    }
};
test "starts feed required and runs to complete" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");
    var search: TerminalSearch = try .init(alloc, "Fizz");
    defer search.deinit(&t);
    try testing.expect(search.isComplete());
    try testing.expectEqual(TerminalSearch.Status.feed_required, search.status());
    while (search.status() != .complete) {
        switch (search.status()) {
            .feed_required => search.feed(&t, true),
            .running => _ = search.tick(),
            .complete => unreachable,
        }
    }
    const screen_search = search.activeScreenSearch().?;
    try testing.expectEqual(2, screen_search.matchesLen());
}
test "viewport matches are cached until the next feed" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");
    var search: TerminalSearch = try .init(alloc, "Fizz");
    defer search.deinit(&t);
    search.feed(&t, true);
    try testing.expectEqual(2, (try search.viewportMatches()).len);
    try testing.expectEqual(2, (try search.viewportMatches()).len);
    stream.nextSlice("\r\nFizz");
    search.feed(&t, true);
    try testing.expectEqual(3, (try search.viewportMatches()).len);
}
test "select after active screen removal" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 20, .rows = 2 });
    defer t.deinit(alloc);
    _ = try t.switchScreen(.alternate);
    var search: TerminalSearch = try .init(alloc, "needle");
    defer search.deinit(&t);
    search.feed(&t, false);
    try testing.expectEqual(ScreenSet.Key.alternate, search.active_key);
    try testing.expect(search.screens.contains(.alternate));
    _ = try t.switchScreen(.primary);
    t.screens.remove(alloc, .alternate);
    _ = try search.select(&t, .next, .if_needed);
    try testing.expectEqual(ScreenSet.Key.primary, search.active_key);
    try testing.expect(!search.screens.contains(.alternate));
}
test "select scrolls the viewport only when needed" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("Fizz\r\n");
    for (0..30) |_| stream.nextSlice("\r\n");
    stream.nextSlice("Fizz");
    var search: TerminalSearch = try .init(alloc, "Fizz");
    defer search.deinit(&t);
    while (search.status() != .complete) {
        switch (search.status()) {
            .feed_required => search.feed(&t, true),
            .running => _ = search.tick(),
            .complete => unreachable,
        }
    }
    const Visible = struct {
        fn check(term: *Terminal, s: *TerminalSearch) bool {
            const pin = s.activeScreenSearch().?.selectedMatch().?.startPin();
            const pages = &term.screens.active.pages;
            const pt = pages.pointFromPin(.viewport, pin) orelse return false;
            return pt.viewport.y < pages.rows;
        }
    };
    try testing.expect(try search.select(&t, .next, .if_needed));
    try testing.expectEqual(
        point.Point{ .active = .{ .x = 0, .y = 1 } },
        t.screens.active.pages.pointFromPin(
            .active,
            search.activeScreenSearch().?.selectedMatch().?.startPin(),
        ).?,
    );
    try testing.expect(Visible.check(&t, &search));
    try testing.expect(try search.select(&t, .next, .if_needed));
    try testing.expect(Visible.check(&t, &search));
    try testing.expect(try search.select(&t, .next, .none));
    try testing.expect(!Visible.check(&t, &search));
}
test "deinit after the terminal is gone" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });
    var stream = t.vtStream();
    stream.nextSlice("Fizz\r\nBuzz\r\nFizz");
    var search: TerminalSearch = try .init(alloc, "Fizz");
    while (search.status() != .complete) {
        switch (search.status()) {
            .feed_required => search.feed(&t, true),
            .running => _ = search.tick(),
            .complete => unreachable,
        }
    }
    try testing.expect(try search.select(&t, .next, .none));
    stream.deinit();
    t.deinit(alloc);
    search.deinit(null);
}
test "no matches selects nothing" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);
    var search: TerminalSearch = try .init(alloc, "Fizz");
    defer search.deinit(&t);
    search.feed(&t, true);
    try testing.expect(!try search.select(&t, .next, .if_needed));
    try testing.expect(!try search.select(&t, .prev, .if_needed));
}
test "feed after complete discovers prepended snapshot history" {
    const alloc = testing.allocator;
    const io = testing.io;
    const snapshot = @import("../snapshot/main.zig");
    var source: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });
    defer source.deinit(alloc);
    var needle_count: usize = 0;
    {
        var stream = source.vtStream();
        defer stream.deinit();
        const list = &source.screens.active.pages;
        while (list.totalPages() < 4) : (needle_count += 1) {
            stream.nextSlice("needle\r\n");
        }
    }
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try snapshot.encode(alloc, &encoded.writer, &source, .{
        .continuation = .ground,
    });
    var reader: std.Io.Reader = .fixed(encoded.written());
    var decoder: snapshot.Decoder = .init(&reader);
    var decoded = try decoder.ready(alloc, io, .{
        .max_continuation_bytes = 0,
    });
    defer decoded.deinit(alloc);
    var t = decoded.toOwned();
    defer t.deinit(alloc);
    const pages_at_ready = t.screens.active.pages.totalPages();
    const Pump = struct {
        fn run(search: *TerminalSearch, term: *Terminal) void {
            while (search.status() != .complete) {
                switch (search.status()) {
                    .feed_required => search.feed(term, true),
                    .running => _ = search.tick(),
                    .complete => unreachable,
                }
            }
        }
    };
    var search: TerminalSearch = try .init(alloc, "needle");
    defer search.deinit(&t);
    Pump.run(&search, &t);
    const partial = search.activeScreenSearch().?.matchesLen();
    try testing.expect(partial > 0);
    try testing.expect(partial < needle_count);
    try testing.expect(try search.select(&t, .prev, .none));
    const selected_idx = search.activeScreenSearch().?.selected.?.idx;
    try testing.expectEqual(partial - 1, selected_idx);
    const selected_before = search.activeScreenSearch().?.selectedMatch().?.untracked();
    var restored_pages: usize = 0;
    while (try decoder.next(alloc, &t)) |progress| : (restored_pages += 1) {
        try testing.expect(progress.rows > 0);
    }
    try testing.expect(restored_pages > 0);
    try testing.expectEqual(
        pages_at_ready + restored_pages,
        t.screens.active.pages.totalPages(),
    );
    search.feed(&t, true);
    Pump.run(&search, &t);
    const screen_search = search.activeScreenSearch().?;
    try testing.expectEqual(needle_count, screen_search.matchesLen());
    try testing.expectEqual(selected_idx, screen_search.selected.?.idx);
    const selected_after = screen_search.selectedMatch().?.untracked();
    try testing.expect(selected_before.start.eql(selected_after.start));
    try testing.expect(selected_before.end.eql(selected_after.end));
    const matches = try screen_search.matches(alloc);
    defer alloc.free(matches);
    const pages = &t.screens.active.pages;
    var prev_y: ?usize = null;
    for (matches) |hl| {
        const pt = pages.pointFromPin(.screen, hl.startPin()).?;
        if (prev_y) |y| try testing.expect(pt.screen.y < y);
        prev_y = pt.screen.y;
    }
    try testing.expectEqual(0, prev_y.?);
    var fresh: TerminalSearch = try .init(alloc, "needle");
    defer fresh.deinit(&t);
    Pump.run(&fresh, &t);
    try testing.expectEqual(
        needle_count,
        fresh.activeScreenSearch().?.matchesLen(),
    );
}
