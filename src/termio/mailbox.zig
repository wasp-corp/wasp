const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const xev = global.xev;
const renderer = @import("../renderer.zig");
const termio = @import("../termio.zig");
const BlockingQueue = @import("../datastruct/root.zig").BlockingQueue;
const log = std.log.scoped(.io_writer);
const Queue = BlockingQueue(termio.Message, 64);
pub const Mailbox = union(enum) {
    spsc: struct {
        queue: *Queue,
        wakeup: xev.Async,
    },
    pub fn initSPSC(alloc: Allocator) !Mailbox {
        var queue = try Queue.create(alloc);
        errdefer queue.destroy(alloc);
        var wakeup = try xev.Async.init();
        errdefer wakeup.deinit();
        return .{ .spsc = .{ .queue = queue, .wakeup = wakeup } };
    }
    pub fn deinit(self: *Mailbox, alloc: Allocator) void {
        switch (self.*) {
            .spsc => |*v| {
                while (v.queue.pop(global.io())) |msg| msg.deinit();
                v.queue.destroy(alloc);
                v.wakeup.deinit();
            },
        }
    }
    pub fn send(
        self: *Mailbox,
        msg: termio.Message,
        mutex: ?*std.Io.Mutex,
    ) void {
        switch (self.*) {
            .spsc => |*mb| send: {
                if (mb.queue.push(global.io(), msg, .{ .instant = {} }) > 0) break :send;
                mb.wakeup.notify() catch |err| {
                    log.warn("failed to wake up writer, data will be dropped err={}", .{err});
                    msg.deinit();
                    return;
                };
                if (mutex) |m| m.unlock(global.io());
                defer if (mutex) |m| m.lockUncancelable(global.io());
                if (mb.queue.push(global.io(), msg, .{ .forever = {} }) == 0) msg.deinit();
            },
        }
    }
    pub fn notify(self: *Mailbox) void {
        switch (self.*) {
            .spsc => |*v| v.wakeup.notify() catch |err| {
                log.warn("failed to notify writer, data will be dropped err={}", .{err});
            },
        }
    }
};
