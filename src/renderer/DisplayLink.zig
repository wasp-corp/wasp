const DisplayLink = @This();
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const macos = @import("macos");
const log = std.log.scoped(.display_link);
alloc: Allocator,
link: *macos.video.DisplayLink,
closed: bool = false,
display: u32 = 0,
requested: std.atomic.Value(Requested) = .init(.{}),
sync_queued: std.atomic.Value(bool) = .init(false),
const Requested = packed struct(u64) {
    running: bool = false,
    _padding: u31 = 0,
    display: u32 = 0,
};
pub fn create(
    alloc: Allocator,
    comptime Userdata: type,
    comptime callbackFn: *const fn (*macos.video.DisplayLink, ?*Userdata) void,
    userdata: ?*Userdata,
) !*DisplayLink {
    const link = try macos.video.DisplayLink.createWithActiveCGDisplays();
    errdefer link.release();
    try link.setOutputCallback(Userdata, callbackFn, userdata);
    const self = try alloc.create(DisplayLink);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .link = link,
    };
    return self;
}
pub fn close(self: *DisplayLink) void {
    assert(!self.closed);
    self.closed = true;
    if (self.link.isRunning()) self.link.stop() catch |err| {
        log.warn("error stopping display link err={}", .{err});
    };
    self.link.release();
    if (!self.sync_queued.load(.seq_cst)) self.destroy();
}
fn destroy(self: *DisplayLink) void {
    const alloc = self.alloc;
    self.* = undefined;
    alloc.destroy(self);
}
pub fn isRunning(self: *DisplayLink) bool {
    return self.link.isRunning();
}
pub fn setRunning(self: *DisplayLink, running: bool) void {
    var requested = self.requested.load(.seq_cst);
    requested.running = running;
    self.requested.store(requested, .seq_cst);
    if (running != self.link.isRunning()) self.queueSync();
}
pub fn setDisplay(self: *DisplayLink, display_id: u32) void {
    if (display_id == 0) return;
    var requested = self.requested.load(.seq_cst);
    requested.display = display_id;
    self.requested.store(requested, .seq_cst);
    self.queueSync();
}
fn queueSync(self: *DisplayLink) void {
    if (self.sync_queued.swap(true, .seq_cst)) return;
    macos.dispatch.c.dispatch_async_f(
        macos.dispatch.c.dispatch_get_main_queue(),
        self,
        &syncCallback,
    );
}
fn syncCallback(ud: ?*anyopaque) callconv(.c) void {
    const self: *DisplayLink = @ptrCast(@alignCast(ud.?));
    self.sync_queued.store(false, .seq_cst);
    if (self.closed) {
        self.destroy();
        return;
    }
    self.sync();
}
fn sync(self: *DisplayLink) void {
    const requested = self.requested.load(.seq_cst);
    if (requested.display != 0 and requested.display != self.display) {
        self.display = requested.display;
        log.info("updating display link display id={}", .{requested.display});
        self.link.setCurrentCGDisplay(requested.display) catch |err| {
            log.warn("error setting display link display id err={}", .{err});
        };
    }
    const running = self.link.isRunning();
    if (requested.running and !running) {
        self.link.start() catch |err| {
            log.debug("error starting display link err={}", .{err});
        };
    } else if (!requested.running and running) {
        self.link.stop() catch |err| {
            log.warn("error stopping display link err={}", .{err});
        };
    }
}
