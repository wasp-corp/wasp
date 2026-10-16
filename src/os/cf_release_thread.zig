pub const Thread = @This();
const std = @import("std");
const builtin = @import("builtin");
const macos = @import("macos");
const internal_os = @import("../os/root.zig");
const global = @import("../global.zig");
const xev = global.xev;
const BlockingQueue = @import("../datastruct/root.zig").BlockingQueue;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.cf_release_thread);
pub const Message = union(enum) {
    release: struct {
        refs: []*anyopaque,
        alloc: Allocator,
    },
};
pub const Mailbox = BlockingQueue(Message, 64);
alloc: std.mem.Allocator,
loop: xev.Loop,
wakeup: xev.Async,
wakeup_c: xev.Completion = .{},
stop: xev.Async,
stop_c: xev.Completion = .{},
mailbox: *Mailbox,
flags: packed struct {
    drain: bool = false,
} = .{},
pub fn init(
    alloc: Allocator,
) !Thread {
    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();
    var wakeup_h = try xev.Async.init();
    errdefer wakeup_h.deinit();
    var stop_h = try xev.Async.init();
    errdefer stop_h.deinit();
    var mailbox = try Mailbox.create(alloc);
    errdefer mailbox.destroy(alloc);
    return Thread{
        .alloc = alloc,
        .loop = loop,
        .wakeup = wakeup_h,
        .stop = stop_h,
        .mailbox = mailbox,
    };
}
pub fn deinit(self: *Thread) void {
    self.stop.deinit();
    self.wakeup.deinit();
    self.loop.deinit();
    self.mailbox.destroy(self.alloc);
}
pub fn threadMain(self: *Thread) void {
    self.threadMain_() catch |err| {
        log.warn("error in cf release thread err={}", .{err});
    };
    if (!self.loop.stopped()) {
        log.warn("abrupt cf release thread exit detected, starting xev to drain mailbox", .{});
        defer log.debug("cf release thread fully exiting after abnormal failure", .{});
        self.flags.drain = true;
        self.loop.run(.until_done) catch |err| {
            log.err("failed to start xev loop for draining err={}", .{err});
        };
    }
}
fn threadMain_(self: *Thread) !void {
    defer log.debug("cf release thread exited", .{});
    if (builtin.os.tag.isDarwin()) {
        internal_os.macos.pthread_setname_np(&"cf_release".*);
    }
    self.wakeup.wait(&self.loop, &self.wakeup_c, Thread, self, wakeupCallback);
    self.stop.wait(&self.loop, &self.stop_c, Thread, self, stopCallback);
    log.debug("starting cf release thread", .{});
    defer log.debug("starting cf release thread shutdown", .{});
    try self.loop.run(.until_done);
}
fn drainMailbox(self: *Thread) !void {
    if (self.flags.drain) {
        while (self.mailbox.pop(global.io())) |_| {}
        return;
    }
    while (self.mailbox.pop(global.io())) |message| {
        switch (message) {
            .release => |msg| {
                for (msg.refs) |ref| macos.foundation.CFRelease(ref);
                msg.alloc.free(msg.refs);
            },
        }
    }
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
