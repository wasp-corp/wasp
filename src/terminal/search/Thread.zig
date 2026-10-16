pub const Thread = @This();
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Mutex = std.Io.Mutex;
const global = @import("../../global.zig");
const xev = global.xev;
const internal_os = @import("../../os/root.zig");
const BlockingQueue = @import("../../datastruct/root.zig").BlockingQueue;
const MessageData = @import("../../datastruct/root.zig").MessageData;
const point = @import("../point.zig");
const FlattenedHighlight = @import("../highlight.zig").Flattened;
const UntrackedHighlight = @import("../highlight.zig").Untracked;
const ScreenSet = @import("../ScreenSet.zig");
const Terminal = @import("../Terminal.zig");
const ScreenSearch = @import("screen.zig").ScreenSearch;
const TerminalSearch = @import("terminal.zig").TerminalSearch;
const log = std.log.scoped(.search_thread);
const REFRESH_INTERVAL = 24;
alloc: std.mem.Allocator,
mailbox: *Mailbox,
loop: xev.Loop,
wakeup: xev.Async,
wakeup_c: xev.Completion = .{},
stop: xev.Async,
stop_c: xev.Completion = .{},
refresh: xev.Timer,
refresh_c: xev.Completion = .{},
refresh_active: bool = false,
search: ?TerminalSearch = null,
notify_state: NotifyState = .{},
opts: Options,
pub fn init(alloc: Allocator, opts: Options) !Thread {
    var mailbox = try Mailbox.create(alloc);
    errdefer mailbox.destroy(alloc);
    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();
    var wakeup_h = try xev.Async.init();
    errdefer wakeup_h.deinit();
    var stop_h = try xev.Async.init();
    errdefer stop_h.deinit();
    var refresh_h = try xev.Timer.init();
    errdefer refresh_h.deinit();
    return .{
        .alloc = alloc,
        .mailbox = mailbox,
        .loop = loop,
        .wakeup = wakeup_h,
        .stop = stop_h,
        .refresh = refresh_h,
        .opts = opts,
    };
}
pub fn deinit(self: *Thread) void {
    self.refresh.deinit();
    self.wakeup.deinit();
    self.stop.deinit();
    self.loop.deinit();
    self.mailbox.destroy(self.alloc);
    if (self.search) |*s| {
        self.opts.mutex.lockUncancelable(global.io());
        defer self.opts.mutex.unlock(global.io());
        s.deinit(self.opts.terminal);
    }
}
pub fn threadMain(self: *Thread) void {
    self.threadMain_() catch |err| {
        log.warn("search thread err={}", .{err});
    };
}
fn threadMain_(self: *Thread) !void {
    defer log.debug("search thread exited", .{});
    if (comptime builtin.os.tag.isDarwin()) {
        internal_os.macos.pthread_setname_np(&"search".*);
        const class: internal_os.macos.QosClass = .utility;
        if (internal_os.macos.setQosClass(class)) {
            log.debug("thread QoS class set class={}", .{class});
        } else |err| {
            log.warn("error setting QoS class err={}", .{err});
        }
    }
    self.wakeup.wait(&self.loop, &self.wakeup_c, Thread, self, wakeupCallback);
    self.stop.wait(&self.loop, &self.stop_c, Thread, self, stopCallback);
    try self.wakeup.notify();
    self.startRefreshTimer();
    log.debug("starting search thread", .{});
    defer {
        log.debug("starting search thread shutdown", .{});
        if (self.opts.event_cb) |cb| {
            cb(.quit, self.opts.event_userdata);
        }
    }
    while (true) {
        if (self.loop.stopped()) {
            while (self.mailbox.pop(global.io())) |message| {
                log.debug("mailbox message ignored during shutdown={}", .{message});
            }
            return;
        }
        const s: *TerminalSearch = if (self.search) |*s| s else {
            try self.loop.run(.once);
            continue;
        };
        if (self.opts.event_cb) |cb| {
            self.notify(s, cb, self.opts.event_userdata);
        }
        if (s.isComplete()) {
            try self.loop.run(.once);
            continue;
        }
        switch (s.tick()) {
            .complete => {},
            .progress => {},
            .blocked => {
                self.opts.mutex.lockUncancelable(global.io());
                defer self.opts.mutex.unlock(global.io());
                self.feedLocked(s);
            },
        }
        try self.loop.run(.no_wait);
    }
}
fn feedLocked(self: *Thread, s: *TerminalSearch) void {
    const t = self.opts.terminal;
    const active_dirty = t.flags.search_viewport_dirty;
    t.flags.search_viewport_dirty = false;
    s.feed(t, active_dirty);
}
fn drainMailbox(self: *Thread) !void {
    while (self.mailbox.pop(global.io())) |message| {
        log.debug("mailbox message={}", .{message});
        switch (message) {
            .change_needle => |v| {
                defer v.deinit();
                try self.changeNeedle(v.slice());
            },
            .select => |v| try self.select(v),
        }
    }
}
fn select(self: *Thread, sel: ScreenSearch.Select) !void {
    const s = if (self.search) |*s| s else return;
    self.opts.mutex.lockUncancelable(global.io());
    defer self.opts.mutex.unlock(global.io());
    if (try s.select(self.opts.terminal, sel, .if_needed)) {
        self.notify_state.selected = null;
    }
}
fn changeNeedle(self: *Thread, needle: []const u8) !void {
    log.debug("changing search needle to '{s}'", .{needle});
    if (self.search) |*s| {
        if (std.ascii.eqlIgnoreCase(s.needle(), needle)) return;
        {
            self.opts.mutex.lockUncancelable(global.io());
            defer self.opts.mutex.unlock(global.io());
            s.deinit(self.opts.terminal);
        }
        self.search = null;
        self.notify_state = .{};
        if (self.opts.event_cb) |cb| {
            cb(
                .{ .total_matches = 0 },
                self.opts.event_userdata,
            );
            cb(
                .{ .selected_match = null },
                self.opts.event_userdata,
            );
            cb(
                .{ .viewport_matches = &.{} },
                self.opts.event_userdata,
            );
        }
    }
    if (needle.len == 0) return;
    self.search = try .init(self.alloc, needle);
    self.notify_state = .{};
    self.opts.mutex.lockUncancelable(global.io());
    defer self.opts.mutex.unlock(global.io());
    self.feedLocked(&self.search.?);
}
fn notify(
    self: *Thread,
    s: *TerminalSearch,
    cb: EventCallback,
    ud: ?*anyopaque,
) void {
    const state = &self.notify_state;
    if (state.key != s.active_key) {
        state.key = s.active_key;
        state.total = null;
        state.selected = null;
    }
    const screen_search = s.activeScreenSearch() orelse return;
    const total = screen_search.matchesLen();
    if (total != state.total) {
        log.debug("notifying total matches={}", .{total});
        state.total = total;
        cb(.{ .total_matches = total }, ud);
    }
    if (s.stale_viewport_matches) viewport: {
        const matches = s.viewportMatches() catch |err| {
            log.warn("error collecting viewport matches err={}", .{err});
            break :viewport;
        };
        log.debug("notifying viewport matches len={}", .{matches.len});
        cb(.{ .viewport_matches = matches }, ud);
    }
    if (screen_search.selected) |m| match: {
        const flattened = screen_search.selectedMatch() orelse break :match;
        const untracked = flattened.untracked();
        if (state.selected) |prev| {
            if (prev.idx == m.idx and prev.highlight.eql(untracked)) {
                break :match;
            }
        }
        state.selected = .{
            .idx = m.idx,
            .highlight = untracked,
        };
        log.debug("notifying selection updated idx={}", .{m.idx});
        cb(
            .{ .selected_match = .{
                .idx = m.idx,
                .highlight = flattened,
            } },
            ud,
        );
    } else if (state.selected != null) {
        log.debug("notifying selection cleared", .{});
        state.selected = null;
        cb(
            .{ .selected_match = null },
            ud,
        );
    }
    if (!state.complete and s.isComplete()) {
        log.debug("notifying search complete", .{});
        state.complete = true;
        cb(.complete, ud);
    }
}
fn startRefreshTimer(self: *Thread) void {
    self.refresh_active = true;
    if (self.refresh_c.state() == .active) return;
    self.refresh.run(
        &self.loop,
        &self.refresh_c,
        REFRESH_INTERVAL,
        Thread,
        self,
        refreshCallback,
    );
}
fn stopRefreshTimer(self: *Thread) void {
    self.refresh_active = false;
}
fn wakeupCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.warn("error in wakeup err={}", .{err});
        return .rearm;
    };
    const self = self_.?;
    self.drainMailbox() catch |err|
        log.warn("error draining mailbox err={}", .{err});
    return .rearm;
}
fn stopCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    self_.?.loop.stop();
    return .disarm;
}
fn refreshCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    const self: *Thread = self_ orelse {
        log.warn("refresh callback fired without data set", .{});
        return .disarm;
    };
    if (self.search) |*s| {
        self.opts.mutex.lockUncancelable(global.io());
        defer self.opts.mutex.unlock(global.io());
        self.feedLocked(s);
    }
    if (self.refresh_active) self.refresh.run(
        &self.loop,
        &self.refresh_c,
        REFRESH_INTERVAL,
        Thread,
        self,
        refreshCallback,
    );
    return .disarm;
}
pub const Options = struct {
    mutex: *Mutex,
    terminal: *Terminal,
    event_cb: ?EventCallback = null,
    event_userdata: ?*anyopaque = null,
};
pub const EventCallback = *const fn (event: Event, userdata: ?*anyopaque) void;
pub const Mailbox = BlockingQueue(Message, 64);
pub const Message = union(enum) {
    pub const WriteReq = MessageData(u8, 255);
    change_needle: WriteReq,
    select: ScreenSearch.Select,
};
pub const Event = union(enum) {
    quit,
    complete,
    total_matches: usize,
    selected_match: ?SelectedMatch,
    viewport_matches: []const FlattenedHighlight,
    pub const SelectedMatch = struct {
        idx: usize,
        highlight: FlattenedHighlight,
    };
};
const NotifyState = struct {
    key: ScreenSet.Key = .primary,
    total: ?usize = null,
    selected: ?Selected = null,
    complete: bool = false,
    const Selected = struct {
        idx: usize,
        highlight: UntrackedHighlight,
    };
};
const TestUserData = struct {
    const Self = @This();
    reset: std.Io.Event = .unset,
    total: usize = 0,
    selected: ?Event.SelectedMatch = null,
    viewport: []FlattenedHighlight = &.{},
    fn deinit(self: *Self) void {
        for (self.viewport) |*hl| hl.deinit(testing.allocator);
        testing.allocator.free(self.viewport);
    }
    fn callback(event: Event, userdata: ?*anyopaque) void {
        const ud: *Self = @ptrCast(@alignCast(userdata.?));
        switch (event) {
            .quit => {},
            .complete => ud.reset.set(global.io()),
            .total_matches => |v| ud.total = v,
            .selected_match => |v| ud.selected = v,
            .viewport_matches => |v| {
                for (ud.viewport) |*hl| hl.deinit(testing.allocator);
                testing.allocator.free(ud.viewport);
                ud.viewport = testing.allocator.alloc(
                    FlattenedHighlight,
                    v.len,
                ) catch unreachable;
                for (ud.viewport, v) |*dst, src| {
                    dst.* = src.clone(testing.allocator) catch unreachable;
                }
            },
        }
    }
};
test {
    const alloc = testing.allocator;
    const io = testing.io;
    var mutex: std.Io.Mutex = .init;
    var t: Terminal = try .init(io, alloc, .{ .cols = 20, .rows = 2 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("Hello, world");
    var ud: TestUserData = .{};
    defer ud.deinit();
    var thread: Thread = try .init(alloc, .{
        .mutex = &mutex,
        .terminal = &t,
        .event_cb = &TestUserData.callback,
        .event_userdata = &ud,
    });
    defer thread.deinit();
    var os_thread = try std.Thread.spawn(
        .{},
        threadMain,
        .{&thread},
    );
    _ = thread.mailbox.push(
        io,
        .{ .change_needle = try .init(
            alloc,
            @as([]const u8, "world"),
        ) },
        .forever,
    );
    try thread.wakeup.notify();
    try ud.reset.waitTimeout(testing.io, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(100) } });
    try thread.stop.notify();
    os_thread.join();
    try testing.expectEqual(1, ud.total);
    try testing.expectEqual(1, ud.viewport.len);
    {
        const sel = ud.viewport[0].untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 11,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
}
