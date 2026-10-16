pub const Thread = @This();
const std = @import("std");
const builtin = @import("builtin");
const global = @import("../global.zig");
const xev = global.xev;
const crash = @import("../crash/main.zig");
const internal_os = @import("../os/root.zig");
const rendererpkg = @import("../renderer.zig");
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const terminalpkg = @import("../terminal/main.zig");
const BlockingQueue = @import("../datastruct/root.zig").BlockingQueue;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.renderer_thread);
const CURSOR_BLINK_INTERVAL = 600;
pub const Mailbox = BlockingQueue(rendererpkg.Message, 64);
alloc: std.mem.Allocator,
loop: xev.Loop,
wakeup: xev.Async,
wakeup_c: xev.Completion = .{},
stop: xev.Async,
stop_c: xev.Completion = .{},
render_h: xev.Timer,
render_c: xev.Completion = .{},
render_c_cancel: xev.Completion = .{},
animation_wake: rendererpkg.Renderer.AnimationWake.Kind = .draw,
draw_now: xev.Async,
draw_now_c: xev.Completion = .{},
cursor_h: xev.Timer,
cursor_c: xev.Completion = .{},
cursor_c_cancel: xev.Completion = .{},
compression: Compression = undefined,
surface: *apprt.Surface,
renderer: *rendererpkg.Renderer,
state: *rendererpkg.State,
mailbox: *Mailbox,
config: DerivedConfig,
flags: packed struct {
    cursor_blink_visible: bool = false,
    has_inspector: bool = false,
    visible: bool = true,
    focused: bool = true,
} = .{},
pub const DerivedConfig = struct {
    scrollback_compression: bool,
    pub fn init(config: *const configpkg.Config) DerivedConfig {
        return .{
            .scrollback_compression = config.@"scrollback-compression",
        };
    }
};
pub fn init(
    alloc: Allocator,
    config: *const configpkg.Config,
    surface: *apprt.Surface,
    renderer_impl: *rendererpkg.Renderer,
    state: *rendererpkg.State,
) !Thread {
    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();
    var wakeup_h = try xev.Async.init();
    errdefer wakeup_h.deinit();
    var stop_h = try xev.Async.init();
    errdefer stop_h.deinit();
    var render_h = try xev.Timer.init();
    errdefer render_h.deinit();
    var draw_now = try xev.Async.init();
    errdefer draw_now.deinit();
    var cursor_timer = try xev.Timer.init();
    errdefer cursor_timer.deinit();
    var mailbox = try Mailbox.create(alloc);
    errdefer mailbox.destroy(alloc);
    var result: Thread = .{
        .alloc = alloc,
        .config = .init(config),
        .loop = loop,
        .wakeup = wakeup_h,
        .stop = stop_h,
        .render_h = render_h,
        .draw_now = draw_now,
        .cursor_h = cursor_timer,
        .surface = surface,
        .renderer = renderer_impl,
        .state = state,
        .mailbox = mailbox,
    };
    if (comptime terminalpkg.compression_enabled) {
        result.compression = try .init();
    }
    return result;
}
pub fn deinit(self: *Thread) void {
    self.stop.deinit();
    self.wakeup.deinit();
    self.render_h.deinit();
    self.draw_now.deinit();
    self.cursor_h.deinit();
    if (comptime terminalpkg.compression_enabled)
        self.compression.deinit();
    self.loop.deinit();
    self.mailbox.destroy(self.alloc);
}
pub fn threadMain(self: *Thread) void {
    self.threadMain_() catch |err| {
        log.warn("error in renderer err={}", .{err});
    };
}
fn threadMain_(self: *Thread) !void {
    defer log.debug("renderer thread exited", .{});
    if (builtin.os.tag.isDarwin()) {
        internal_os.macos.pthread_setname_np(&"renderer".*);
    }
    crash.sentry.thread_state = .{
        .type = .renderer,
        .surface = self.renderer.surface_mailbox.surface,
    };
    defer crash.sentry.thread_state = null;
    self.setQosClass();
    const has_loop = @hasDecl(rendererpkg.Renderer, "loopEnter");
    if (has_loop) try self.renderer.loopEnter(self);
    defer if (has_loop) self.renderer.loopExit();
    try self.renderer.threadEnter(self.surface);
    defer self.renderer.threadExit();
    self.wakeup.wait(&self.loop, &self.wakeup_c, Thread, self, wakeupCallback);
    self.stop.wait(&self.loop, &self.stop_c, Thread, self, stopCallback);
    self.draw_now.wait(&self.loop, &self.draw_now_c, Thread, self, drawNowCallback);
    try self.wakeup.notify();
    self.cursor_h.run(
        &self.loop,
        &self.cursor_c,
        cursorBlinkInterval(),
        Thread,
        self,
        cursorTimerCallback,
    );
    self.armAnimationTimer();
    log.debug("starting renderer thread", .{});
    defer log.debug("starting renderer thread shutdown", .{});
    _ = try self.loop.run(.until_done);
}
fn setQosClass(self: *const Thread) void {
    if (comptime !builtin.target.os.tag.isDarwin()) return;
    const class: internal_os.macos.QosClass = class: {
        if (!self.flags.visible) break :class .utility;
        if (!self.flags.focused) break :class .user_initiated;
        break :class .user_interactive;
    };
    if (internal_os.macos.setQosClass(class)) {
        log.debug("thread QoS class set class={}", .{class});
    } else |err| {
        log.warn("error setting QoS class err={}", .{err});
    }
}
fn drainMailbox(self: *Thread) !void {
    const pool = if (builtin.os.tag.isDarwin())
        @import("objc").AutoreleasePool.init()
    else
        void;
    defer if (builtin.os.tag.isDarwin()) pool.deinit();
    while (self.mailbox.pop(global.io())) |message| {
        log.debug("mailbox message={}", .{message});
        switch (message) {
            .crash => @panic("crash request, crashing intentionally"),
            .visible => |v| visible: {
                if (self.flags.visible == v) break :visible;
                self.flags.visible = v;
                self.setQosClass();
                if (v) _ = renderCallback(self, undefined, undefined, {});
                self.renderer.setVisible(v);
            },
            .focus => |v| focus: {
                if (self.flags.focused == v) break :focus;
                self.flags.focused = v;
                self.setQosClass();
                try self.renderer.setFocus(v);
                self.armAnimationTimer();
                if (!v) {
                    if (self.cursor_c.state() == .active and
                        self.cursor_c_cancel.state() == .dead)
                    {
                        self.cursor_h.cancel(
                            &self.loop,
                            &self.cursor_c,
                            &self.cursor_c_cancel,
                            void,
                            null,
                            cursorCancelCallback,
                        );
                    }
                } else {
                    if (self.cursor_c.state() != .active) {
                        self.flags.cursor_blink_visible = true;
                        self.cursor_h.run(
                            &self.loop,
                            &self.cursor_c,
                            cursorBlinkInterval(),
                            Thread,
                            self,
                            cursorTimerCallback,
                        );
                    }
                }
            },
            .reset_cursor_blink => {
                self.flags.cursor_blink_visible = true;
                if (self.cursor_c.state() == .active) {
                    self.cursor_h.reset(
                        &self.loop,
                        &self.cursor_c,
                        &self.cursor_c_cancel,
                        cursorBlinkInterval(),
                        Thread,
                        self,
                        cursorTimerCallback,
                    );
                }
            },
            .font_grid => |grid| {
                self.renderer.setFontGrid(grid.grid);
                grid.set.deref(grid.old_key);
            },
            .presentation_health => |v| self.renderer.setPresentationHealth(v),
            .resize => |v| self.renderer.setScreenSize(v),
            .change_config => |config| {
                defer config.alloc.destroy(config.thread);
                defer config.alloc.destroy(config.impl);
                try self.changeConfig(config.thread);
                try self.renderer.changeConfig(config.impl);
                self.armAnimationTimer();
            },
            .search_viewport_matches => |v| {
                if (self.renderer.search_matches) |*m| m.arena.deinit();
                self.renderer.search_matches = v;
                self.renderer.search_matches_dirty = true;
            },
            .search_selected_match => |v| {
                if (self.renderer.search_selected_match) |*m| m.arena.deinit();
                self.renderer.search_selected_match = v;
                self.renderer.search_matches_dirty = true;
            },
            .inspector => |v| {
                self.flags.has_inspector = v;
            },
            .macos_display_id => |v| {
                if (@hasDecl(rendererpkg.Renderer, "setMacOSDisplayID")) {
                    try self.renderer.setMacOSDisplayID(v, &self.draw_now);
                }
            },
        }
    }
}
fn changeConfig(self: *Thread, config: *const DerivedConfig) !void {
    if (comptime terminalpkg.compression_enabled) {
        if (!self.config.scrollback_compression and
            config.scrollback_compression)
        {
            self.compression.activity = null;
        }
    }
    self.config = config.*;
}
fn drawFrame(self: *Thread, now: bool) void {
    if (!self.flags.visible) return;
    if (!now and self.renderer.hasVsync()) return;
    self.renderer.drawFrame(false) catch |err|
        log.warn("error drawing err={}", .{err});
}
fn wakeupCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.err("error in wakeup err={}", .{err});
        return .rearm;
    };
    const t = self_.?;
    t.drainMailbox() catch |err|
        log.err("error draining mailbox err={}", .{err});
    _ = renderCallback(t, undefined, undefined, {});
    t.compression.wake(t);
    return .rearm;
}
fn drawNowCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.err("error in draw now err={}", .{err});
        return .rearm;
    };
    const t = self_.?;
    t.drawFrame(true);
    return .rearm;
}
fn renderCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => return .disarm,
        else => unreachable,
    };
    const t: *Thread = self_ orelse {
        log.warn("render callback fired without data set", .{});
        return .disarm;
    };
    if (!t.renderer.display_realized) {
        t.renderer.draw_mutex.lockUncancelable(global.io());
        defer t.renderer.draw_mutex.unlock(global.io());
        t.renderer.releaseGpuResources();
        return .disarm;
    }
    if (!t.flags.visible) return .disarm;
    t.renderer.updateFrame(
        t.state,
        t.flags.cursor_blink_visible,
    ) catch |err|
        log.warn("error rendering err={}", .{err});
    t.drawFrame(false);
    t.armAnimationTimer();
    return .disarm;
}
fn armAnimationTimer(self: *Thread) void {
    const wake = self.renderer.animationWake() orelse return;
    self.animation_wake = wake.kind;
    self.render_h.reset(
        &self.loop,
        &self.render_c,
        &self.render_c_cancel,
        wake.delay_ms,
        Thread,
        self,
        animationTimerCallback,
    );
}
fn animationTimerCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => return .disarm,
        else => unreachable,
    };
    const t: *Thread = self_ orelse {
        log.warn("animation callback fired without data set", .{});
        return .disarm;
    };
    if (!t.flags.visible) return .disarm;
    switch (t.animation_wake) {
        .update => return renderCallback(
            t,
            undefined,
            undefined,
            {},
        ),
        .draw => {
            t.drawFrame(false);
            t.armAnimationTimer();
            return .disarm;
        },
    }
}
fn cursorTimerCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => return .disarm,
        else => {
            log.warn("error in cursor timer callback err={}", .{err});
            unreachable;
        },
    };
    const t: *Thread = self_ orelse {
        log.warn("render callback fired without data set", .{});
        return .disarm;
    };
    t.flags.cursor_blink_visible = !t.flags.cursor_blink_visible;
    t.wakeup.notify() catch {};
    t.cursor_h.run(
        &t.loop,
        &t.cursor_c,
        cursorBlinkInterval(),
        Thread,
        t,
        cursorTimerCallback,
    );
    return .disarm;
}
fn cursorCancelCallback(
    _: ?*void,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.CancelError!void,
) xev.CallbackAction {
    const CancelError = xev.Timer.CancelError || error{
        Canceled,
        NotFound,
        Unexpected,
    };
    _ = r catch |err| switch (@as(CancelError, @errorCast(err))) {
        error.Canceled => {},
        error.NotFound => {},
        else => {
            log.warn("error in cursor cancel callback err={}", .{err});
            unreachable;
        },
    };
    return .disarm;
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
fn cursorBlinkInterval() u64 {
    if (std.valgrind.runningOnValgrind() > 0) {
        return CURSOR_BLINK_INTERVAL * 5;
    }
    return CURSOR_BLINK_INTERVAL;
}
const Compression = struct {
    const idle_interval = 250;
    const step_interval = 1;
    timer: xev.Timer,
    completion: xev.Completion = .{},
    reset_completion: xev.Completion = .{},
    activity: ?u64 = null,
    fn init() !Compression {
        return .{ .timer = try xev.Timer.init() };
    }
    fn deinit(self: *Compression) void {
        self.timer.deinit();
    }
    fn wake(self: *Compression, thread: *Thread) void {
        if (comptime !terminalpkg.compression_enabled) return;
        if (!thread.config.scrollback_compression) return;
        if (thread.state.mutex.tryLock()) {
            defer thread.state.mutex.unlock(global.io());
            const activity = thread.state.terminal.compressionActivity();
            if (self.activity == activity) return;
            self.activity = activity;
        } else if (self.completion.state() == .active) {
            return;
        }
        self.schedule(thread, idle_interval);
    }
    fn schedule(self: *Compression, thread: *Thread, delay_ms: u64) void {
        self.timer.reset(
            &thread.loop,
            &self.completion,
            &self.reset_completion,
            delay_ms,
            Thread,
            thread,
            timerCallback,
        );
    }
    fn timerCallback(
        thread_: ?*Thread,
        _: *xev.Loop,
        _: *xev.Completion,
        result: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        _ = result catch |err| switch (err) {
            error.Canceled => return .disarm,
            else => {
                log.warn("error in compression timer err={}", .{err});
                return .disarm;
            },
        };
        const thread = thread_ orelse return .disarm;
        const self = &thread.compression;
        if (self.step(thread)) |delay| self.schedule(thread, delay);
        return .disarm;
    }
    fn step(self: *Compression, thread: *Thread) ?u64 {
        if (!thread.config.scrollback_compression) return null;
        const state = thread.state;
        if (!state.mutex.tryLock()) return idle_interval;
        defer state.mutex.unlock(global.io());
        const activity = state.terminal.compressionActivity();
        if (self.activity != activity) {
            self.activity = activity;
            return idle_interval;
        }
        return switch (state.terminal.compress(.incremental)) {
            .pending => step_interval,
            .unsupported,
            .complete,
            => null,
        };
    }
};
