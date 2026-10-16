pub const Thread = @This();
const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const builtin = @import("builtin");
const global = @import("../global.zig");
const xev = global.xev;
const crash = @import("../crash/main.zig");
const internal_os = @import("../os/root.zig");
const termio = @import("../termio.zig");
const renderer = @import("../renderer.zig");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.io_thread);
const Coalesce = struct {
    const min_ms = 25;
    resize: ?renderer.Size = null,
};
const sync_reset_ms = 1000;
const selection_scroll_ms = 15;
alloc: std.mem.Allocator,
loop: xev.Loop,
wakeup_c: xev.Completion = .{},
stop: xev.Async,
stop_c: xev.Completion = .{},
scroll: xev.Timer,
scroll_c: xev.Completion = .{},
scroll_active: bool = false,
coalesce: xev.Timer,
coalesce_c: xev.Completion = .{},
coalesce_cancel_c: xev.Completion = .{},
coalesce_data: Coalesce = .{},
sync_reset: xev.Timer,
sync_reset_c: xev.Completion = .{},
sync_reset_cancel_c: xev.Completion = .{},
flags: packed struct {
    drain: bool = false,
    linefeed_mode: bool = false,
    has_inspector: bool = false,
} = .{},
pub fn init(
    alloc: Allocator,
) !Thread {
    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();
    var stop_h = try xev.Async.init();
    errdefer stop_h.deinit();
    var scroll_h = try xev.Timer.init();
    errdefer scroll_h.deinit();
    var coalesce_h = try xev.Timer.init();
    errdefer coalesce_h.deinit();
    var sync_reset_h = try xev.Timer.init();
    errdefer sync_reset_h.deinit();
    return Thread{
        .alloc = alloc,
        .loop = loop,
        .stop = stop_h,
        .scroll = scroll_h,
        .coalesce = coalesce_h,
        .sync_reset = sync_reset_h,
    };
}
pub fn deinit(self: *Thread) void {
    self.scroll.deinit();
    self.coalesce.deinit();
    self.sync_reset.deinit();
    self.stop.deinit();
    self.loop.deinit();
}
pub fn threadMain(self: *Thread, io: *termio.Termio) void {
    self.threadMain_(io) catch |err| {
        log.warn("error in io thread err={}", .{err});
        var arena = ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();
        io.renderer_state.mutex.lockUncancelable(global.io());
        defer io.renderer_state.mutex.unlock(global.io());
        const t = io.renderer_state.terminal;
        t.modes.set(.cursor_visible, false);
        const Err = @TypeOf(err) || error{
            OpenptyFailed,
            InputNotFound,
            InputFailed,
        };
        switch (@as(Err, @errorCast(err))) {
            error.OpenptyFailed => {
                const str =
                    \\Your system cannot allocate any more pty devices.
                    \\
                    \\Wasp requires a pty device to launch a new terminal.
                    \\This error is usually due to having too many terminal
                    \\windows open or having another program that is using too
                    \\many pty devices.
                    \\
                    \\Please free up some pty devices and try again.
                ;
                t.eraseDisplay(.complete, false);
                t.printString(str) catch {};
            },
            error.InputNotFound,
            error.InputFailed,
            => {
                const str =
                    \\A configured `input` path was not found, was not readable,
                    \\was too large, or the underlying pty failed to accept
                    \\the write.
                    \\
                    \\Wasp can't continue since it can't guarantee that
                    \\initial terminal state will be as desired. Please review
                    \\the value of `input` in your configuration file and
                    \\ensure that all the path values exist and are readable.
                ;
                t.eraseDisplay(.complete, false);
                t.printString(str) catch {};
            },
            else => {
                const str = std.fmt.allocPrint(
                    alloc,
                    \\error starting IO thread: {}
                    \\
                    \\The underlying shell or command was unable to be started.
                    \\This error is usually due to exhausting a system resource.
                    \\If this looks like a bug, please report it.
                    \\
                    \\This terminal is non-functional. Please close it and try again.
                ,
                    .{err},
                ) catch
                    \\Out of memory. This terminal is non-functional. Please close it and try again.
                ;
                t.eraseDisplay(.complete, false);
                t.printString(str) catch {};
            },
        }
    };
    if (!self.loop.stopped()) {
        log.warn("abrupt io thread exit detected, starting xev to drain mailbox", .{});
        defer log.debug("io thread fully exiting after abnormal failure", .{});
        self.flags.drain = true;
        self.loop.run(.until_done) catch |err| {
            log.err("failed to start xev loop for draining err={}", .{err});
        };
    }
}
fn threadMain_(self: *Thread, io: *termio.Termio) !void {
    defer log.debug("IO thread exited", .{});
    if (builtin.os.tag.isDarwin()) {
        internal_os.macos.pthread_setname_np(&"io".*);
    }
    crash.sentry.thread_state = .{
        .type = .io,
        .surface = io.surface_mailbox.surface,
    };
    defer crash.sentry.thread_state = null;
    const mailbox = switch (io.mailbox) {
        .spsc => |*v| v,
    };
    var cb: CallbackData = .{ .self = self, .io = io };
    try io.threadEnter(self, &cb.data);
    defer cb.data.deinit();
    defer io.threadExit(&cb.data);
    mailbox.wakeup.wait(&self.loop, &self.wakeup_c, CallbackData, &cb, wakeupCallback);
    self.stop.wait(&self.loop, &self.stop_c, CallbackData, &cb, stopCallback);
    log.debug("starting IO thread", .{});
    defer log.debug("starting IO thread shutdown", .{});
    try self.loop.run(.until_done);
}
const CallbackData = struct {
    self: *Thread,
    io: *termio.Termio,
    data: termio.Termio.ThreadData = undefined,
};
fn drainMailbox(
    self: *Thread,
    cb: *CallbackData,
) !void {
    const mailbox = cb.io.mailbox.spsc.queue;
    const io = cb.io;
    const data = &cb.data;
    if (self.flags.drain) {
        while (mailbox.pop(global.io())) |msg| msg.deinit();
        return;
    }
    var redraw: bool = false;
    while (mailbox.pop(global.io())) |message| {
        redraw = true;
        log.debug("mailbox message={s}", .{@tagName(message)});
        switch (message) {
            .color_scheme_report => |v| try io.colorSchemeReport(data, v.force),
            .visibility_report => |v| try io.visibilityReport(
                data,
                v.visible,
                v.force,
            ),
            .crash => @panic("crash request, crashing intentionally"),
            .change_config => |config| {
                defer config.alloc.destroy(config.ptr);
                try io.changeConfig(data, config.ptr);
            },
            .inspector => |v| self.flags.has_inspector = v,
            .resize => |v| self.handleResize(cb, v),
            .size_report => |v| try io.sizeReport(data, v),
            .clear_screen => |v| try io.clearScreen(data, v.history),
            .scroll_viewport => |v| io.scrollViewport(v),
            .selection_scroll => |v| {
                if (v) {
                    self.startScrollTimer(cb);
                } else {
                    self.stopScrollTimer();
                }
            },
            .jump_to_prompt => |v| try io.jumpToPrompt(v),
            .kitty_clipboard_grant_read => |v| {
                defer v.alloc.free(v.pw);
                try io.kittyClipboardGrant(v.pw, .read);
            },
            .kitty_clipboard_grant_write => |v| {
                defer v.alloc.free(v.pw);
                try io.kittyClipboardGrant(v.pw, .write);
            },
            .start_synchronized_output => self.startSynchronizedOutput(cb),
            .linefeed_mode => |v| self.flags.linefeed_mode = v,
            .focused => |v| try io.focusGained(data, v),
            .write_small => |v| try io.queueWrite(
                data,
                v.data[0..v.len],
                self.flags.linefeed_mode,
            ),
            .write_stable => |v| try io.queueWrite(
                data,
                v,
                self.flags.linefeed_mode,
            ),
            .write_alloc => |v| {
                defer v.alloc.free(v.data);
                try io.queueWrite(
                    data,
                    v.data,
                    self.flags.linefeed_mode,
                );
            },
        }
    }
    if (redraw) {
        try io.renderer_wakeup.notify();
    }
}
fn startSynchronizedOutput(self: *Thread, cb: *CallbackData) void {
    self.sync_reset.reset(
        &self.loop,
        &self.sync_reset_c,
        &self.sync_reset_cancel_c,
        sync_reset_ms,
        CallbackData,
        cb,
        syncResetCallback,
    );
}
fn handleResize(self: *Thread, cb: *CallbackData, resize: renderer.Size) void {
    self.coalesce_data.resize = resize;
    if (self.coalesce_c.state() == .active) return;
    self.coalesce.reset(
        &self.loop,
        &self.coalesce_c,
        &self.coalesce_cancel_c,
        Coalesce.min_ms,
        CallbackData,
        cb,
        coalesceCallback,
    );
}
fn syncResetCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => {},
        else => {
            log.warn("error during sync reset callback err={}", .{err});
            return .disarm;
        },
    };
    const cb = cb_ orelse return .disarm;
    cb.io.resetSynchronizedOutput();
    return .disarm;
}
fn coalesceCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => {},
        else => {
            log.warn("error during coalesce callback err={}", .{err});
            return .disarm;
        },
    };
    const cb = cb_ orelse return .disarm;
    if (cb.self.coalesce_data.resize) |v| {
        cb.self.coalesce_data.resize = null;
        cb.io.resize(&cb.data, v) catch |err| {
            log.warn("error during resize err={}", .{err});
        };
    }
    return .disarm;
}
fn wakeupCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.err("error in wakeup err={}", .{err});
        return .rearm;
    };
    const cb = cb_ orelse return .rearm;
    cb.self.drainMailbox(cb) catch |err|
        log.err("error draining mailbox err={}", .{err});
    return .rearm;
}
fn stopCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    cb_.?.self.loop.stop();
    return .disarm;
}
fn startScrollTimer(self: *Thread, cb: *CallbackData) void {
    self.scroll_active = true;
    switch (self.scroll_c.state()) {
        .active => return,
        .dead => self.scroll.run(
            &self.loop,
            &self.scroll_c,
            selection_scroll_ms,
            CallbackData,
            cb,
            selectionScrollCallback,
        ),
    }
}
fn stopScrollTimer(self: *Thread) void {
    self.scroll_active = false;
}
fn selectionScrollCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => {},
        else => {
            log.warn("error during selection scroll callback err={}", .{err});
            return .disarm;
        },
    };
    const cb = cb_ orelse return .disarm;
    const self = cb.self;
    _ = cb.io.surface_mailbox.push(
        .{ .selection_scroll_tick = self.scroll_active },
        .{ .instant = {} },
    );
    if (self.scroll_active) self.scroll.run(
        &self.loop,
        &self.scroll_c,
        selection_scroll_ms,
        CallbackData,
        cb,
        selectionScrollCallback,
    );
    return .disarm;
}
