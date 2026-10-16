const OpenURI = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const global = @import("../../../global.zig");
const App = @import("../App.zig");
const portal = @import("../portal.zig");
const apprt = @import("../../../apprt.zig");
const log = std.log.scoped(.openuri);
app: *App,
dbus: ?*gio.DBusConnection = null,
mutex: std.Io.Mutex = .init,
entries: std.AutoArrayHashMapUnmanaged(usize, *Entry) = .empty,
cleanup_timer: ?c_uint = null,
alive: bool = true,
const RequestData = struct {
    open_uri: *OpenURI,
    token: usize,
    kind: apprt.action.OpenUrl.Kind,
    uri: [:0]const u8,
    request_path: [:0]const u8,
    pub fn init(
        alloc: Allocator,
        open_uri: *OpenURI,
        token: usize,
        kind: apprt.action.OpenUrl.Kind,
        uri: []const u8,
        request_path: []const u8,
    ) Allocator.Error!*RequestData {
        const uri_copy = try alloc.dupeZ(u8, uri);
        errdefer alloc.free(uri_copy);
        const request_path_copy = try alloc.dupeZ(u8, request_path);
        errdefer alloc.free(request_path_copy);
        const data = try alloc.create(RequestData);
        errdefer alloc.destroy(data);
        data.* = .{
            .open_uri = open_uri,
            .token = token,
            .kind = kind,
            .uri = uri_copy,
            .request_path = request_path_copy,
        };
        return data;
    }
    pub fn deinit(self: *const RequestData, alloc: Allocator) void {
        alloc.free(self.uri);
        alloc.free(self.request_path);
    }
};
pub const Entry = struct {
    start: std.Io.Timestamp,
    token: usize,
    kind: apprt.action.OpenUrl.Kind,
    uri: [:0]const u8,
    subscription: ?c_uint = null,
    pub fn deinit(self: *const Entry, alloc: Allocator) void {
        alloc.free(self.uri);
    }
};
pub const Errors = error{
    DBusConnectionRequired,
    NoDBusUniqueName,
    TimerUnavailable,
};
pub fn init(app: *App) OpenURI {
    return .{
        .app = app,
    };
}
pub fn setDbusConnection(self: *OpenURI, dbus: ?*gio.DBusConnection) void {
    self.dbus = dbus;
}
pub fn deinit(self: *OpenURI) void {
    const alloc = self.app.app.allocator();
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    if (!self.alive) return;
    self.alive = false;
    self.stopCleanupTimer();
    for (self.entries.entries.items(.value)) |entry| {
        self.unsubscribeFromResponse(entry);
        destroyEntry(alloc, entry);
    }
    self.entries.deinit(alloc);
    self.entries = .empty;
    self.dbus = null;
}
pub fn start(self: *OpenURI, value: apprt.action.OpenUrl) (Allocator.Error || Errors)!void {
    const alloc = self.app.app.allocator();
    const dbus = self.dbus orelse return error.DBusConnectionRequired;
    const token = portal.generateToken();
    const request_path = try portal.getRequestPath(alloc, dbus, token);
    defer alloc.free(request_path);
    const request = try RequestData.init(alloc, self, token, value.kind, value.url, request_path);
    errdefer {
        request.deinit(alloc);
        alloc.destroy(request);
    }
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    const entry = entry: {
        const entry = try alloc.create(Entry);
        errdefer alloc.destroy(entry);
        entry.* = .{
            .start = std.Io.Timestamp.now(global.io(), .awake),
            .token = token,
            .kind = value.kind,
            .uri = try alloc.dupeZ(u8, value.url),
        };
        errdefer entry.deinit(alloc);
        try self.entries.putNoClobber(alloc, token, entry);
        break :entry entry;
    };
    errdefer {
        _ = self.entries.swapRemove(token);
        destroyEntry(alloc, entry);
    }
    self.startCleanupTimer();
    self.subscribeToResponse(entry, dbus, request_path.ptr);
    self.sendRequest(entry, dbus, request);
}
fn subscribeToResponse(
    self: *OpenURI,
    entry: *Entry,
    dbus: *gio.DBusConnection,
    request_path: [*:0]const u8,
) void {
    assert(!self.mutex.tryLock());
    if (entry.subscription != null) return;
    entry.subscription = dbus.signalSubscribe(
        null,
        "org.freedesktop.portal.Request",
        "Response",
        request_path,
        null,
        .{},
        responseReceived,
        self,
        null,
    );
}
fn unsubscribeFromResponse(self: *OpenURI, entry: *Entry) void {
    assert(!self.mutex.tryLock());
    if (entry.subscription) |subscription| {
        const dbus = self.dbus orelse {
            entry.subscription = null;
            log.warn("unable to unsubscribe open uri response without dbus connection", .{});
            return;
        };
        dbus.signalUnsubscribe(subscription);
        entry.subscription = null;
    }
}
fn destroyEntry(alloc: Allocator, entry: *Entry) void {
    entry.deinit(alloc);
    alloc.destroy(entry);
}
fn failRequest(self: *OpenURI, token: usize) ?*Entry {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    if (!self.alive) return null;
    const entry = (self.entries.fetchSwapRemove(token) orelse return null).value;
    self.unsubscribeFromResponse(entry);
    return entry;
}
fn failRequestAndFallback(self: *OpenURI, request: *const RequestData) void {
    const alloc = self.app.app.allocator();
    const entry = self.failRequest(request.token) orelse return;
    defer destroyEntry(alloc, entry);
    self.app.app.openUrlFallback(request.kind, request.uri);
}
fn sendRequest(
    self: *OpenURI,
    entry: *Entry,
    dbus: *gio.DBusConnection,
    request: *RequestData,
) void {
    assert(!self.mutex.tryLock());
    const payload = payload: {
        const builder_type = glib.VariantType.new("(ssa{sv})");
        defer builder_type.free();
        var builder: glib.VariantBuilder = undefined;
        builder.init(builder_type);
        builder.add("s", "");
        builder.add("s", entry.uri.ptr);
        {
            const options = glib.VariantType.new("a{sv}");
            defer options.free();
            builder.open(options);
            defer builder.close();
            {
                const option = glib.VariantType.new("{sv}");
                defer option.free();
                builder.open(option);
                defer builder.close();
                builder.add("s", "handle_token");
                var token_buf: portal.TokenBuffer = undefined;
                const token = portal.formatToken(&token_buf, entry.token);
                const handle_token = glib.Variant.newString(token.ptr);
                builder.add("v", handle_token);
            }
            {
                const option = glib.VariantType.new("{sv}");
                defer option.free();
                builder.open(option);
                defer builder.close();
                builder.add("s", "writable");
                const writable = glib.Variant.newBoolean(@intFromBool(false));
                builder.add("v", writable);
            }
            {
                const option = glib.VariantType.new("{sv}");
                defer option.free();
                builder.open(option);
                defer builder.close();
                builder.add("s", "ask");
                const ask = glib.Variant.newBoolean(@intFromBool(false));
                builder.add("v", ask);
            }
        }
        break :payload builder.end();
    };
    const reply_type = glib.VariantType.new("(o)");
    defer reply_type.free();
    dbus.call(
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.OpenURI",
        "OpenURI",
        payload,
        reply_type,
        .{},
        -1,
        null,
        requestCallback,
        request,
    );
}
fn requestCallback(
    source: ?*gobject.Object,
    result: *gio.AsyncResult,
    ud: ?*anyopaque,
) callconv(.c) void {
    const request: *RequestData = @ptrCast(@alignCast(ud orelse return));
    const self = request.open_uri;
    const alloc = self.app.app.allocator();
    defer {
        request.deinit(alloc);
        alloc.destroy(request);
    }
    const dbus = gobject.ext.cast(gio.DBusConnection, source orelse {
        log.err("Open URI request finished without a D-Bus source object", .{});
        self.failRequestAndFallback(request);
        return;
    }) orelse {
        log.err("Open URI request finished with an unexpected source object", .{});
        self.failRequestAndFallback(request);
        return;
    };
    var err_: ?*glib.Error = null;
    defer if (err_) |err| err.free();
    const reply_ = dbus.callFinish(result, &err_);
    if (err_) |err| {
        log.err("Open URI request failed={s} ({})", .{
            err.f_message orelse "(unknown)",
            err.f_code,
        });
        self.failRequestAndFallback(request);
        return;
    }
    const reply = reply_ orelse {
        log.err("D-Bus method call returned a null value!", .{});
        self.failRequestAndFallback(request);
        return;
    };
    defer reply.unref();
    const reply_type = glib.VariantType.new("(o)");
    defer reply_type.free();
    if (reply.isOfType(reply_type) == 0) {
        log.warn("Reply from D-Bus method call does not contain an object path!", .{});
        self.failRequestAndFallback(request);
        return;
    }
    var object_path: [*:0]const u8 = undefined;
    reply.get("(&o)", &object_path);
    const token = portal.parseRequestPathToken(std.mem.span(object_path)) orelse {
        log.warn("Unable to parse token from the object path {s}", .{object_path});
        self.failRequestAndFallback(request);
        return;
    };
    if (token != request.token) {
        log.warn("Open URI request returned mismatched token expected={x} actual={x}", .{
            request.token,
            token,
        });
        self.failRequestAndFallback(request);
        return;
    }
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    if (!self.alive) return;
    const entry = self.entries.get(token) orelse return;
    if (std.mem.eql(u8, request.request_path, std.mem.span(object_path))) return;
    log.debug("updating open uri request path old={s} new={s}", .{
        request.request_path,
        object_path,
    });
    self.unsubscribeFromResponse(entry);
    self.subscribeToResponse(entry, dbus, object_path);
}
fn responseReceived(
    _: *gio.DBusConnection,
    _: ?[*:0]const u8,
    object_path: [*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    params: *glib.Variant,
    ud: ?*anyopaque,
) callconv(.c) void {
    const self: *OpenURI = @ptrCast(@alignCast(ud orelse {
        log.err("OpenURI response received with null userdata", .{});
        return;
    }));
    const alloc = self.app.app.allocator();
    const token = portal.parseRequestPathToken(std.mem.span(object_path)) orelse {
        log.warn("invalid object path: {s}", .{std.mem.span(object_path)});
        return;
    };
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    if (!self.alive) return;
    const entry = (self.entries.fetchSwapRemove(token) orelse {
        log.warn("no entry for token {x}", .{token});
        return;
    }).value;
    defer destroyEntry(alloc, entry);
    self.unsubscribeFromResponse(entry);
    var response: u32 = 0;
    var results: ?*glib.Variant = null;
    defer if (results) |variant| variant.unref();
    params.get("(u@a{sv})", &response, &results);
    switch (response) {
        0 => {
            log.debug("open uri successful", .{});
        },
        1 => {
            log.debug("open uri request was cancelled by the user", .{});
        },
        2 => {
            log.warn("open uri request ended unexpectedly", .{});
            self.app.app.openUrlFallback(entry.kind, entry.uri);
        },
        else => {
            log.err("unrecognized response code={}", .{response});
            self.app.app.openUrlFallback(entry.kind, entry.uri);
        },
    }
}
const cleanup_timeout = 30;
fn stopCleanupTimer(self: *OpenURI) void {
    assert(!self.mutex.tryLock());
    if (self.cleanup_timer) |timer| {
        if (glib.Source.remove(timer) == 0) {
            log.warn("unable to remove cleanup timer source={d}", .{timer});
        }
        self.cleanup_timer = null;
    }
}
fn startCleanupTimer(self: *OpenURI) void {
    assert(!self.mutex.tryLock());
    self.stopCleanupTimer();
    self.cleanup_timer = glib.timeoutAddSeconds(cleanup_timeout + 1, cleanup, self);
}
fn cleanup(ud: ?*anyopaque) callconv(.c) c_int {
    const self: *OpenURI = @ptrCast(@alignCast(ud orelse {
        log.warn("cleanup called with null userdata", .{});
        return @intFromBool(glib.SOURCE_REMOVE);
    }));
    const alloc = self.app.app.allocator();
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    self.cleanup_timer = null;
    if (!self.alive) return @intFromBool(glib.SOURCE_REMOVE);
    loop: while (true) {
        for (self.entries.entries.items(.value)) |entry| {
            if (entry.start.untilNow(
                global.io(),
                .awake,
            ).toSeconds() > cleanup_timeout) {
                log.warn("open uri request timed out token={x}", .{entry.token});
                self.unsubscribeFromResponse(entry);
                _ = self.entries.swapRemove(entry.token);
                self.app.app.openUrlFallback(entry.kind, entry.uri);
                destroyEntry(alloc, entry);
                continue :loop;
            }
        }
        break :loop;
    }
    return @intFromBool(glib.SOURCE_REMOVE);
}
