const std = @import("std");
const testing = std.testing;
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
const searchpkg = @import("../search.zig");
const TerminalSearch = searchpkg.Terminal;
const FlattenedHighlight = @import("../highlight.zig").Flattened;
const selection_c = @import("selection.zig");
const terminal_c = @import("terminal.zig");
const Result = @import("result.zig").Result;
const log = std.log.scoped(.search_c);
pub const Search = ?*SearchWrapper;
pub const SearchWrapper = struct {
    alloc: std.mem.Allocator,
    terminal: terminal_c.Terminal,
    search: ?TerminalSearch = null,
    select_scroll: TerminalSearch.SelectScroll = .if_needed,
    fn zigTerminal(self: *const SearchWrapper) ?*terminal_c.ZigTerminal {
        const terminal_wrapper = self.terminal orelse return null;
        return terminal_wrapper.terminal;
    }
    fn status(self: *SearchWrapper) Status {
        const s = if (self.search) |*s| s else return .complete;
        return .fromZig(s.status());
    }
};
pub const Status = enum(c_int) {
    running = 0,
    feed_required = 1,
    complete = 2,
    fn fromZig(status: TerminalSearch.Status) Status {
        return switch (status) {
            .running => .running,
            .feed_required => .feed_required,
            .complete => .complete,
        };
    }
};
pub const Scroll = enum(c_int) {
    if_needed = 0,
    none = 1,
    fn toZig(self: Scroll) TerminalSearch.SelectScroll {
        return switch (self) {
            .if_needed => .if_needed,
            .none => .none,
        };
    }
    fn fromZig(scroll: TerminalSearch.SelectScroll) Scroll {
        return switch (scroll) {
            .if_needed => .if_needed,
            .none => .none,
        };
    }
};
pub const Data = enum(c_int) {
    status = 0,
    needle = 1,
    total_matches = 2,
    selected_index = 3,
    selected_match = 4,
    matches = 5,
    viewport_matches = 6,
    select_scroll = 7,
    pub fn OutType(comptime self: Data) type {
        return switch (self) {
            .status => Status,
            .needle => lib.String,
            .total_matches => usize,
            .selected_index => usize,
            .selected_match => selection_c.CSelection,
            .matches, .viewport_matches => selection_c.CSelectionBuffer,
            .select_scroll => Scroll,
        };
    }
};
pub const Option = enum(c_int) {
    needle = 0,
    select_next = 1,
    select_prev = 2,
    select_scroll = 3,
    pub fn Type(comptime self: Option) type {
        return switch (self) {
            .needle => lib.String,
            .select_next, .select_prev => void,
            .select_scroll => Scroll,
        };
    }
};
pub fn new(
    alloc_: ?*const CAllocator,
    out_search: ?*Search,
    terminal: terminal_c.Terminal,
) callconv(lib.calling_conv) Result {
    const out = out_search orelse return .invalid_value;
    out.* = null;
    const terminal_wrapper = terminal orelse return .invalid_value;
    const alloc = lib.alloc.default(alloc_);
    const wrapper = alloc.create(SearchWrapper) catch return .out_of_memory;
    wrapper.* = .{
        .alloc = alloc,
        .terminal = terminal_wrapper,
    };
    terminal_wrapper.searches.putNoClobber(
        terminal_wrapper.terminal.gpa(),
        wrapper,
        {},
    ) catch {
        alloc.destroy(wrapper);
        return .out_of_memory;
    };
    out.* = wrapper;
    return .success;
}
pub fn free(search_: Search) callconv(lib.calling_conv) void {
    const wrapper = search_ orelse return;
    if (wrapper.terminal) |terminal_wrapper| {
        _ = terminal_wrapper.searches.swapRemove(wrapper);
        if (wrapper.search) |*s| s.deinit(terminal_wrapper.terminal);
    } else {
        if (wrapper.search) |*s| s.deinit(null);
    }
    const alloc = wrapper.alloc;
    alloc.destroy(wrapper);
}
pub fn tick(
    search_: Search,
    out_status: ?*Status,
) callconv(lib.calling_conv) Result {
    const wrapper = search_ orelse return .invalid_value;
    _ = wrapper.zigTerminal() orelse return .invalid_value;
    if (wrapper.search) |*s| _ = s.tick();
    if (out_status) |out| out.* = wrapper.status();
    return .success;
}
pub fn feed(search_: Search) callconv(lib.calling_conv) Result {
    const wrapper = search_ orelse return .invalid_value;
    const t = wrapper.zigTerminal() orelse return .invalid_value;
    const s = if (wrapper.search) |*s| s else return .success;
    s.feed(t, true);
    return .success;
}
pub fn run(search_: Search) callconv(lib.calling_conv) Result {
    const wrapper = search_ orelse return .invalid_value;
    const t = wrapper.zigTerminal() orelse return .invalid_value;
    const s = if (wrapper.search) |*s| s else return .success;
    s.feed(t, true);
    while (true) {
        switch (s.status()) {
            .complete => return .success,
            .feed_required => s.feed(t, true),
            .running => _ = s.tick(),
        }
    }
}
pub fn set(
    search_: Search,
    option: Option,
    value: ?*const anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.enums.fromInt(Option, @intFromEnum(option)) orelse {
            log.warn("search_set invalid option value={d}", .{@intFromEnum(option)});
            return .invalid_value;
        };
    }
    return switch (option) {
        inline else => |comptime_option| setTyped(
            search_,
            comptime_option,
            if (value) |ptr| @ptrCast(@alignCast(ptr)) else null,
        ),
    };
}
fn setTyped(
    search_: Search,
    comptime option: Option,
    value: ?*const option.Type(),
) Result {
    const wrapper = search_ orelse return .invalid_value;
    switch (option) {
        .needle => {
            const t = wrapper.zigTerminal() orelse return .invalid_value;
            const v = value orelse return clearNeedle(wrapper, t);
            if (v.len == 0) return clearNeedle(wrapper, t);
            if (@intFromPtr(v.ptr) == 0) return .invalid_value;
            const bytes = v.ptr[0..v.len];
            if (wrapper.search) |*s| {
                if (std.ascii.eqlIgnoreCase(s.needle(), bytes)) {
                    return .success;
                }
            }
            const replacement = TerminalSearch.init(
                wrapper.alloc,
                bytes,
            ) catch return .out_of_memory;
            if (wrapper.search) |*s| s.deinit(t);
            wrapper.search = replacement;
        },
        .select_next, .select_prev => {
            if (value != null) return .invalid_value;
            const t = wrapper.zigTerminal() orelse return .invalid_value;
            const s = if (wrapper.search) |*s| s else return .no_value;
            const selected = s.select(
                t,
                switch (option) {
                    .select_next => .next,
                    .select_prev => .prev,
                    else => comptime unreachable,
                },
                wrapper.select_scroll,
            ) catch return .out_of_memory;
            if (!selected) return .no_value;
        },
        .select_scroll => {
            const v = value orelse {
                wrapper.select_scroll = .if_needed;
                return .success;
            };
            const scroll = std.enums.fromInt(Scroll, @intFromEnum(v.*)) orelse
                return .invalid_value;
            wrapper.select_scroll = scroll.toZig();
        },
    }
    return .success;
}
fn clearNeedle(wrapper: *SearchWrapper, t: *terminal_c.ZigTerminal) Result {
    if (wrapper.search) |*s| {
        s.deinit(t);
        wrapper.search = null;
    }
    return .success;
}
pub fn get(
    search_: Search,
    data: Data,
    value: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.enums.fromInt(Data, @intFromEnum(data)) orelse {
            log.warn("search_get invalid data value={d}", .{@intFromEnum(data)});
            return .invalid_value;
        };
    }
    const out_ptr = value orelse return .invalid_value;
    return switch (data) {
        inline else => |comptime_data| getTyped(
            search_,
            comptime_data,
            @ptrCast(@alignCast(out_ptr)),
        ),
    };
}
pub fn get_multi(
    search_: Search,
    count: usize,
    keys: ?[*]const Data,
    values: ?[*]?*anyopaque,
    out_written: ?*usize,
) callconv(lib.calling_conv) Result {
    const k = keys orelse return .invalid_value;
    const v = values orelse return .invalid_value;
    for (0..count) |i| {
        const result = get(search_, k[i], v[i]);
        if (result != .success) {
            if (out_written) |w| w.* = i;
            return result;
        }
    }
    if (out_written) |w| w.* = count;
    return .success;
}
fn getTyped(
    search_: Search,
    comptime data: Data,
    out: *data.OutType(),
) Result {
    const wrapper = search_ orelse return .invalid_value;
    switch (data) {
        .status => out.* = wrapper.status(),
        .needle => {
            const s = if (wrapper.search) |*s| s else return .no_value;
            out.* = .init(s.needle());
        },
        .total_matches => out.* = total: {
            const s = if (wrapper.search) |*s| s else break :total 0;
            const ss = s.activeScreenSearch() orelse break :total 0;
            break :total ss.matchesLen();
        },
        .selected_index => {
            const s = if (wrapper.search) |*s| s else return .no_value;
            const ss = s.activeScreenSearch() orelse return .no_value;
            const selected = ss.selected orelse return .no_value;
            out.* = selected.idx;
        },
        .selected_match => {
            const s = if (wrapper.search) |*s| s else return .no_value;
            const ss = s.activeScreenSearch() orelse return .no_value;
            const hl = ss.selectedMatch() orelse return .no_value;
            out.* = selectionFromHighlight(hl);
        },
        .matches => {
            const ss = if (wrapper.search) |*s|
                s.activeScreenSearch()
            else
                null;
            const total = if (ss) |v| v.matchesLen() else 0;
            if (out.cap < total) {
                out.len = total;
                return .out_of_space;
            }
            if (total > 0) {
                const dst = (out.ptr orelse return .invalid_value)[0..total];
                for (dst, 0..) |*d, i| {
                    d.* = selectionFromHighlight(ss.?.matchAt(i).?);
                }
            }
            out.len = total;
        },
        .viewport_matches => {
            const matches: []const FlattenedHighlight = if (wrapper.search) |*s|
                s.viewportMatches() catch return .out_of_memory
            else
                &.{};
            if (out.cap < matches.len) {
                out.len = matches.len;
                return .out_of_space;
            }
            if (matches.len > 0) {
                const dst = (out.ptr orelse return .invalid_value)[0..matches.len];
                for (dst, matches) |*d, hl| d.* = selectionFromHighlight(hl);
            }
            out.len = matches.len;
        },
        .select_scroll => out.* = .fromZig(wrapper.select_scroll),
    }
    return .success;
}
fn selectionFromHighlight(hl: FlattenedHighlight) selection_c.CSelection {
    const untracked = hl.untracked();
    return .{
        .start = .fromPin(untracked.start),
        .end = .fromPin(untracked.end),
        .rectangle = false,
    };
}
fn testString(str: []const u8) lib.String {
    return .init(str);
}
fn testNewSearch(terminal: terminal_c.Terminal, needle_str: []const u8) !Search {
    var search: Search = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &search,
        terminal,
    ));
    errdefer free(search);
    const needle_value = testString(needle_str);
    try testing.expectEqual(Result.success, set(search, .needle, &needle_value));
    return search;
}
test "search lifecycle and run to complete" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        10,
        4,
    ));
    defer terminal_c.free(terminal);
    terminal_c.vt_write(terminal, "Fizz\r\nBuzz\r\nFizz\r\nBang", 22);
    const search: Search = try testNewSearch(terminal, "Fizz");
    defer free(search);
    var status: Status = .complete;
    try testing.expectEqual(Result.success, get(search, .status, &status));
    try testing.expectEqual(Status.feed_required, status);
    try testing.expectEqual(Result.success, run(search));
    try testing.expectEqual(Result.success, get(search, .status, &status));
    try testing.expectEqual(Status.complete, status);
    var total: usize = 0;
    try testing.expectEqual(Result.success, get(search, .total_matches, &total));
    try testing.expectEqual(@as(usize, 2), total);
    var needle: lib.String = undefined;
    try testing.expectEqual(Result.success, get(search, .needle, &needle));
    try testing.expectEqualStrings("Fizz", needle.ptr[0..needle.len]);
}
test "search tick reports feed required before first feed" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        10,
        4,
    ));
    defer terminal_c.free(terminal);
    const search: Search = try testNewSearch(terminal, "Fizz");
    defer free(search);
    var status: Status = .complete;
    try testing.expectEqual(Result.success, tick(search, &status));
    try testing.expectEqual(Status.feed_required, status);
    try testing.expectEqual(Result.success, tick(search, null));
}
test "search feed after write updates results" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        10,
        4,
    ));
    defer terminal_c.free(terminal);
    terminal_c.vt_write(terminal, "Fizz", 4);
    const search: Search = try testNewSearch(terminal, "Fizz");
    defer free(search);
    try testing.expectEqual(Result.success, run(search));
    var total: usize = 0;
    try testing.expectEqual(Result.success, get(search, .total_matches, &total));
    try testing.expectEqual(@as(usize, 1), total);
    terminal_c.vt_write(terminal, "\r\nFizz", 6);
    try testing.expectEqual(Result.success, run(search));
    try testing.expectEqual(Result.success, get(search, .total_matches, &total));
    try testing.expectEqual(@as(usize, 2), total);
}
test "search alt screen flip and return retains results" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        10,
        4,
    ));
    defer terminal_c.free(terminal);
    terminal_c.vt_write(terminal, "Fizz\r\nFizz", 10);
    const search: Search = try testNewSearch(terminal, "Fizz");
    defer free(search);
    try testing.expectEqual(Result.success, run(search));
    var total: usize = 0;
    try testing.expectEqual(Result.success, get(search, .total_matches, &total));
    try testing.expectEqual(@as(usize, 2), total);
    terminal_c.vt_write(terminal, "\x1b[?1049h", 8);
    try testing.expectEqual(Result.success, run(search));
    try testing.expectEqual(Result.success, get(search, .total_matches, &total));
    try testing.expectEqual(@as(usize, 0), total);
    terminal_c.vt_write(terminal, "Fizz", 4);
    try testing.expectEqual(Result.success, run(search));
    try testing.expectEqual(Result.success, get(search, .total_matches, &total));
    try testing.expectEqual(@as(usize, 1), total);
    terminal_c.vt_write(terminal, "\x1b[?1049l", 8);
    try testing.expectEqual(Result.success, run(search));
    try testing.expectEqual(Result.success, get(search, .total_matches, &total));
    try testing.expectEqual(@as(usize, 2), total);
}
test "search select wraps in both directions" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        10,
        4,
    ));
    defer terminal_c.free(terminal);
    terminal_c.vt_write(terminal, "Fizz\r\nBuzz\r\nFizz", 16);
    const search: Search = try testNewSearch(terminal, "Fizz");
    defer free(search);
    try testing.expectEqual(Result.success, run(search));
    var idx: usize = 999;
    try testing.expectEqual(Result.no_value, get(search, .selected_index, &idx));
    try testing.expectEqual(Result.success, set(search, .select_next, null));
    try testing.expectEqual(Result.success, get(search, .selected_index, &idx));
    try testing.expectEqual(@as(usize, 0), idx);
    var match: selection_c.CSelection = undefined;
    try testing.expectEqual(Result.success, get(search, .selected_match, &match));
    try testing.expect(match.start.toPin() != null);
    try testing.expectEqual(Result.success, set(search, .select_next, null));
    try testing.expectEqual(Result.success, get(search, .selected_index, &idx));
    try testing.expectEqual(@as(usize, 1), idx);
    try testing.expectEqual(Result.success, set(search, .select_next, null));
    try testing.expectEqual(Result.success, get(search, .selected_index, &idx));
    try testing.expectEqual(@as(usize, 0), idx);
    try testing.expectEqual(Result.success, set(search, .select_prev, null));
    try testing.expectEqual(Result.success, get(search, .selected_index, &idx));
    try testing.expectEqual(@as(usize, 1), idx);
}
test "search select with no matches returns no value" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        10,
        4,
    ));
    defer terminal_c.free(terminal);
    const search: Search = try testNewSearch(terminal, "Fizz");
    defer free(search);
    try testing.expectEqual(Result.no_value, set(search, .select_next, null));
    try testing.expectEqual(Result.no_value, set(search, .select_prev, null));
}
test "search select rejects a non-null reserved value" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        10,
        4,
    ));
    defer terminal_c.free(terminal);
    const search: Search = try testNewSearch(terminal, "Fizz");
    defer free(search);
    const bogus: c_int = 0;
    try testing.expectEqual(Result.invalid_value, set(search, .select_next, &bogus));
    try testing.expectEqual(Result.invalid_value, set(search, .select_prev, &bogus));
}
test "search select scroll option" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        10,
        4,
    ));
    defer terminal_c.free(terminal);
    const search: Search = try testNewSearch(terminal, "Fizz");
    defer free(search);
    var scroll: Scroll = .none;
    try testing.expectEqual(Result.success, get(search, .select_scroll, &scroll));
    try testing.expectEqual(Scroll.if_needed, scroll);
    const none: Scroll = .none;
    try testing.expectEqual(Result.success, set(search, .select_scroll, &none));
    try testing.expectEqual(Result.success, get(search, .select_scroll, &scroll));
    try testing.expectEqual(Scroll.none, scroll);
    try testing.expectEqual(Result.success, set(search, .select_scroll, null));
    try testing.expectEqual(Result.success, get(search, .select_scroll, &scroll));
    try testing.expectEqual(Scroll.if_needed, scroll);
    const bogus: c_int = 42;
    try testing.expectEqual(Result.invalid_value, set(search, .select_scroll, @ptrCast(&bogus)));
}
test "search selection dropped when reset prunes results" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        10,
        4,
    ));
    defer terminal_c.free(terminal);
    terminal_c.vt_write(terminal, "Fizz\r\nBuzz", 10);
    const search: Search = try testNewSearch(terminal, "Fizz");
    defer free(search);
    try testing.expectEqual(Result.success, run(search));
    try testing.expectEqual(Result.success, set(search, .select_next, null));
    terminal_c.vt_write(terminal, "\r\nBang", 6);
    try testing.expectEqual(Result.success, run(search));
    var match: selection_c.CSelection = undefined;
    try testing.expectEqual(Result.success, get(search, .selected_match, &match));
    terminal_c.vt_write(terminal, "\x1bc", 2);
    try testing.expectEqual(Result.success, run(search));
    var total: usize = 999;
    try testing.expectEqual(Result.success, get(search, .total_matches, &total));
    try testing.expectEqual(@as(usize, 0), total);
    try testing.expectEqual(Result.no_value, get(search, .selected_match, &match));
}
test "search matches buffer semantics" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        10,
        4,
    ));
    defer terminal_c.free(terminal);
    terminal_c.vt_write(terminal, "Fizz\r\nBuzz\r\nFizz", 16);
    const search: Search = try testNewSearch(terminal, "Fizz");
    defer free(search);
    try testing.expectEqual(Result.success, run(search));
    var buf: selection_c.CSelectionBuffer = .{};
    try testing.expectEqual(Result.out_of_space, get(search, .matches, &buf));
    try testing.expectEqual(@as(usize, 2), buf.len);
    var one: [1]selection_c.CSelection = undefined;
    buf = .{ .ptr = &one, .cap = one.len };
    try testing.expectEqual(Result.out_of_space, get(search, .matches, &buf));
    try testing.expectEqual(@as(usize, 2), buf.len);
    var storage: [4]selection_c.CSelection = undefined;
    buf = .{ .ptr = &storage, .cap = storage.len };
    try testing.expectEqual(Result.success, get(search, .matches, &buf));
    try testing.expectEqual(@as(usize, 2), buf.len);
    const first = storage[0].start.toPin().?;
    const second = storage[1].start.toPin().?;
    try testing.expect(first.y != second.y or first.node != second.node);
    buf = .{};
    try testing.expectEqual(Result.out_of_space, get(search, .viewport_matches, &buf));
    try testing.expectEqual(@as(usize, 2), buf.len);
    buf = .{ .ptr = &storage, .cap = storage.len };
    try testing.expectEqual(Result.success, get(search, .viewport_matches, &buf));
    try testing.expectEqual(@as(usize, 2), buf.len);
    buf = .{ .ptr = &storage, .cap = storage.len };
    try testing.expectEqual(Result.success, get(search, .viewport_matches, &buf));
    try testing.expectEqual(@as(usize, 2), buf.len);
}
test "search get_multi returns first failing index" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        10,
        4,
    ));
    defer terminal_c.free(terminal);
    terminal_c.vt_write(terminal, "Fizz", 4);
    const search: Search = try testNewSearch(terminal, "Fizz");
    defer free(search);
    try testing.expectEqual(Result.success, run(search));
    const keys = [_]Data{ .total_matches, .selected_index, .status };
    var total: usize = 0;
    var idx: usize = 0;
    var status: Status = .running;
    var values = [_]?*anyopaque{ &total, &idx, &status };
    var written: usize = 999;
    try testing.expectEqual(Result.no_value, get_multi(
        search,
        keys.len,
        &keys,
        &values,
        &written,
    ));
    try testing.expectEqual(@as(usize, 1), written);
    try testing.expectEqual(@as(usize, 1), total);
    try testing.expectEqual(Result.success, set(search, .select_next, null));
    try testing.expectEqual(Result.success, get_multi(
        search,
        keys.len,
        &keys,
        &values,
        &written,
    ));
    try testing.expectEqual(keys.len, written);
    try testing.expectEqual(@as(usize, 0), idx);
}
test "search new validates options" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        10,
        4,
    ));
    defer terminal_c.free(terminal);
    var search: Search = null;
    try testing.expectEqual(Result.invalid_value, new(
        &lib.alloc.test_allocator,
        null,
        terminal,
    ));
    try testing.expectEqual(Result.invalid_value, new(
        &lib.alloc.test_allocator,
        &search,
        null,
    ));
    try testing.expect(search == null);
}
test "search without a needle is idle" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        10,
        4,
    ));
    defer terminal_c.free(terminal);
    terminal_c.vt_write(terminal, "Fizz", 4);
    var search: Search = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &search,
        terminal,
    ));
    defer free(search);
    var status: Status = .running;
    try testing.expectEqual(Result.success, get(search, .status, &status));
    try testing.expectEqual(Status.complete, status);
    try testing.expectEqual(Result.success, feed(search));
    try testing.expectEqual(Result.success, run(search));
    try testing.expectEqual(Result.success, tick(search, &status));
    try testing.expectEqual(Status.complete, status);
    var needle_out: lib.String = undefined;
    try testing.expectEqual(Result.no_value, get(search, .needle, &needle_out));
    var total: usize = 999;
    try testing.expectEqual(Result.success, get(search, .total_matches, &total));
    try testing.expectEqual(@as(usize, 0), total);
    try testing.expectEqual(Result.no_value, set(search, .select_next, null));
    var buf: selection_c.CSelectionBuffer = .{};
    try testing.expectEqual(Result.success, get(search, .matches, &buf));
    try testing.expectEqual(@as(usize, 0), buf.len);
    buf = .{};
    try testing.expectEqual(Result.success, get(search, .viewport_matches, &buf));
    try testing.expectEqual(@as(usize, 0), buf.len);
    try testing.expectEqual(Result.success, set(search, .needle, null));
}
test "search needle change and clear" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        10,
        4,
    ));
    defer terminal_c.free(terminal);
    terminal_c.vt_write(terminal, "Fizz\r\nBuzz", 10);
    const search: Search = try testNewSearch(terminal, "Fizz");
    defer free(search);
    try testing.expectEqual(Result.success, run(search));
    try testing.expectEqual(Result.success, set(search, .select_next, null));
    var total: usize = 0;
    try testing.expectEqual(Result.success, get(search, .total_matches, &total));
    try testing.expectEqual(@as(usize, 1), total);
    const same = testString("fIZZ");
    try testing.expectEqual(Result.success, set(search, .needle, &same));
    var needle_out: lib.String = undefined;
    try testing.expectEqual(Result.success, get(search, .needle, &needle_out));
    try testing.expectEqualStrings("Fizz", needle_out.ptr[0..needle_out.len]);
    var idx: usize = 999;
    try testing.expectEqual(Result.success, get(search, .selected_index, &idx));
    try testing.expectEqual(@as(usize, 0), idx);
    const changed = testString("Buzz");
    try testing.expectEqual(Result.success, set(search, .needle, &changed));
    var status: Status = .complete;
    try testing.expectEqual(Result.success, get(search, .status, &status));
    try testing.expectEqual(Status.feed_required, status);
    try testing.expectEqual(Result.no_value, get(search, .selected_index, &idx));
    try testing.expectEqual(Result.success, run(search));
    try testing.expectEqual(Result.success, get(search, .total_matches, &total));
    try testing.expectEqual(@as(usize, 1), total);
    try testing.expectEqual(Result.success, get(search, .needle, &needle_out));
    try testing.expectEqualStrings("Buzz", needle_out.ptr[0..needle_out.len]);
    const empty = testString("");
    try testing.expectEqual(Result.success, set(search, .needle, &empty));
    try testing.expectEqual(Result.no_value, get(search, .needle, &needle_out));
    try testing.expectEqual(Result.success, get(search, .status, &status));
    try testing.expectEqual(Status.complete, status);
    try testing.expectEqual(Result.success, get(search, .total_matches, &total));
    try testing.expectEqual(@as(usize, 0), total);
}
test "search free after terminal free" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        10,
        4,
    ));
    terminal_c.vt_write(terminal, "Fizz\r\nFizz", 10);
    const search: Search = try testNewSearch(terminal, "Fizz");
    try testing.expectEqual(Result.success, run(search));
    try testing.expectEqual(Result.success, set(search, .select_next, null));
    terminal_c.free(terminal);
    try testing.expectEqual(Result.invalid_value, feed(search));
    try testing.expectEqual(Result.invalid_value, run(search));
    try testing.expectEqual(Result.invalid_value, tick(search, null));
    try testing.expectEqual(Result.invalid_value, set(search, .select_next, null));
    const needle_value = testString("Buzz");
    try testing.expectEqual(Result.invalid_value, set(search, .needle, &needle_value));
    var needle_out: lib.String = undefined;
    try testing.expectEqual(Result.success, get(search, .needle, &needle_out));
    try testing.expectEqualStrings("Fizz", needle_out.ptr[0..needle_out.len]);
    const scroll: Scroll = .none;
    try testing.expectEqual(Result.success, set(search, .select_scroll, &scroll));
    free(search);
}
test "search tick after terminal free with history" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        10,
        3,
    ));
    terminal_c.vt_write(terminal, "Fizz\r\nFizz\r\nFizz\r\nFizz\r\n", 24);
    const search: Search = try testNewSearch(terminal, "Fizz");
    defer free(search);
    try testing.expectEqual(Result.success, feed(search));
    var status: Status = .complete;
    try testing.expectEqual(Result.success, get(search, .status, &status));
    try testing.expectEqual(Status.running, status);
    terminal_c.free(terminal);
    try testing.expectEqual(Result.invalid_value, tick(search, &status));
}
test "search freed before terminal detaches from the registry" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        10,
        4,
    ));
    defer terminal_c.free(terminal);
    const a: Search = try testNewSearch(terminal, "Fizz");
    const b: Search = try testNewSearch(terminal, "Fizz");
    defer free(b);
    try testing.expectEqual(Result.success, run(a));
    free(a);
    try testing.expectEqual(Result.success, run(b));
}
test "search free null" {
    free(null);
}
