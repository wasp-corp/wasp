const std = @import("std");
const assert = @import("../../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const global = @import("../../../global.zig");
const Binding = @import("../../../input.zig").Binding;
const key = @import("../key.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Config = @import("config.zig").Config;
const log = std.log.scoped(.gtk_wasp_global_shortcuts);
pub const GlobalShortcuts = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gobject.Object;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WaspGlobalShortcuts",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });
    pub const properties = struct {
        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };
        pub const @"dbus-connection" = struct {
            pub const name = "dbus-connection";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*gio.DBusConnection,
                .{
                    .accessor = C.privateObjFieldAccessor("dbus_connection"),
                },
            );
        };
    };
    const Private = struct {
        config: ?*Config = null,
        dbus_connection: ?*gio.DBusConnection = null,
        arena: ?std.heap.ArenaAllocator = null,
        map: std.StringArrayHashMapUnmanaged(Binding.Action) = .{},
        handle: ?[:0]const u8 = null,
        response_subscription: c_uint = 0,
        activate_subscription: c_uint = 0,
        pub var offset: c_int = 0;
    };
    pub const BindFailed = struct {
        trigger: Binding.Trigger,
        action: Binding.Action,
        message: [*:0]const u8,
        revoked: bool,
        pub const getGObjectType = gobject.ext.defineBoxed(
            BindFailed,
            .{ .name = "WaspGlobalShortcutsBindFailed" },
        );
    };
    pub const signals = struct {
        pub const trigger = struct {
            pub const name = "trigger";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{*const Binding.Action},
                void,
            );
        };
        pub const @"bind-failed" = struct {
            pub const name = "bind-failed";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{*const BindFailed},
                void,
            );
        };
    };
    fn init(self: *Self, _: *Class) callconv(.c) void {
        _ = gobject.Object.signals.notify.connect(
            self,
            *Self,
            propConfig,
            self,
            .{ .detail = "config" },
        );
    }
    fn close(self: *Self) void {
        const priv = self.private();
        Application.default().winproto().clearGlobalShortcuts();
        if (priv.dbus_connection) |dbus| {
            if (priv.response_subscription != 0) {
                dbus.signalUnsubscribe(priv.response_subscription);
                priv.response_subscription = 0;
            }
            if (priv.activate_subscription != 0) {
                dbus.signalUnsubscribe(priv.activate_subscription);
                priv.activate_subscription = 0;
            }
            if (priv.handle) |handle| {
                dbus.call(
                    "org.freedesktop.portal.Desktop",
                    handle,
                    "org.freedesktop.portal.Session",
                    "Close",
                    null,
                    null,
                    .{},
                    -1,
                    null,
                    null,
                    null,
                );
                priv.handle = null;
            }
        }
        if (priv.arena) |*arena| {
            arena.deinit();
            priv.arena = null;
            priv.map = .{};
        }
    }
    fn refresh(self: *Self) Allocator.Error!void {
        self.close();
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return;
        if (Application.default().winproto().bindGlobalShortcuts(self, config)) {
            log.debug("global shortcuts bound via winproto", .{});
            return;
        }
        if (priv.dbus_connection == null) return;
        assert(priv.arena == null);
        var arena: std.heap.ArenaAllocator = .init(Application.default().allocator());
        errdefer arena.deinit();
        const alloc = arena.allocator();
        priv.map = .{};
        errdefer priv.map = .{};
        var trigger_buf: [1024]u8 = undefined;
        var it = config.keybind.set.bindings.iterator();
        while (it.next()) |entry| {
            const leaf: Binding.Set.GenericLeaf = switch (entry.value_ptr.*) {
                .leader => continue,
                inline .leaf, .leaf_chained => |leaf| leaf.generic(),
            };
            if (!leaf.flags.global) continue;
            const actions = leaf.actionsSlice();
            if (actions.len != 1) continue;
            const trigger = if (key.xdgShortcutFromTrigger(
                &trigger_buf,
                entry.key_ptr.*,
            )) |shortcut_|
                shortcut_ orelse continue
            else |err| switch (err) {
                error.WriteFailed => {
                    log.warn(
                        "buffer too small to translate trigger, ignoring={f}",
                        .{entry.key_ptr.*},
                    );
                    continue;
                },
            };
            try priv.map.put(
                alloc,
                try alloc.dupeZ(u8, trigger),
                actions[0],
            );
        }
        priv.arena = arena;
        if (priv.map.count() > 0) try self.request(.create_session);
    }
    const Method = enum {
        create_session,
        bind_shortcuts,
        fn name(self: Method) [:0]const u8 {
            return switch (self) {
                .create_session => "CreateSession",
                .bind_shortcuts => "BindShortcuts",
            };
        }
        fn makePayload(
            self: Method,
            shortcuts: *GlobalShortcuts,
            request_token: [:0]const u8,
        ) ?*glib.Variant {
            switch (self) {
                .create_session => {
                    var session_token: Token = undefined;
                    return glib.Variant.newParsed(
                        "({'handle_token': <%s>, 'session_handle_token': <%s>},)",
                        request_token.ptr,
                        generateToken(&session_token).ptr,
                    );
                },
                .bind_shortcuts => {
                    const priv = shortcuts.private();
                    const handle = priv.handle orelse return null;
                    const bind_type = glib.VariantType.new("a(sa{sv})");
                    defer glib.free(bind_type);
                    var binds: glib.VariantBuilder = undefined;
                    glib.VariantBuilder.init(&binds, bind_type);
                    var action_buf: [256]u8 = undefined;
                    var it = priv.map.iterator();
                    while (it.next()) |entry| {
                        const trigger = entry.key_ptr.*.ptr;
                        const action = std.fmt.bufPrintZ(
                            &action_buf,
                            "{f}",
                            .{entry.value_ptr.*},
                        ) catch continue;
                        binds.addParsed(
                            "(%s, {'description': <%s>, 'preferred_trigger': <%s>})",
                            trigger,
                            action.ptr,
                            trigger,
                        );
                    }
                    return glib.Variant.newParsed(
                        "(%o, %*, '', {'handle_token': <%s>})",
                        handle.ptr,
                        binds.end(),
                        request_token.ptr,
                    );
                },
            }
        }
        fn onResponse(self: Method, shortcuts: *GlobalShortcuts, vardict: *glib.Variant) void {
            switch (self) {
                .create_session => {
                    var handle: ?[*:0]u8 = null;
                    if (vardict.lookup("session_handle", "&s", &handle) == 0) {
                        log.warn(
                            "session handle not found in response={s}",
                            .{vardict.print(@intFromBool(true))},
                        );
                        return;
                    }
                    const priv = shortcuts.private();
                    const dbus = priv.dbus_connection.?;
                    const alloc = priv.arena.?.allocator();
                    priv.handle = alloc.dupeZ(u8, std.mem.span(handle.?)) catch {
                        log.warn("out of memory: failed to clone session handle", .{});
                        return;
                    };
                    log.debug("session_handle={?s}", .{handle});
                    assert(priv.activate_subscription == 0);
                    priv.activate_subscription = dbus.signalSubscribe(
                        null,
                        "org.freedesktop.portal.GlobalShortcuts",
                        "Activated",
                        "/org/freedesktop/portal/desktop",
                        handle,
                        .{ .match_arg0_path = true },
                        shortcutActivated,
                        shortcuts,
                        null,
                    );
                    shortcuts.request(.bind_shortcuts) catch |err| {
                        log.warn("failed to bind shortcuts={}", .{err});
                        return;
                    };
                },
                .bind_shortcuts => {},
            }
        }
    };
    fn request(
        self: *Self,
        comptime method: Method,
    ) Allocator.Error!void {
        const callbacks = struct {
            fn gotResponseHandle(
                source: ?*gobject.Object,
                res: *gio.AsyncResult,
                _: ?*anyopaque,
            ) callconv(.c) void {
                const dbus_ = gobject.ext.cast(gio.DBusConnection, source.?).?;
                var err: ?*glib.Error = null;
                defer if (err) |err_| err_.free();
                const params_ = dbus_.callFinish(res, &err) orelse {
                    if (err) |err_| log.warn("request failed={s} ({})", .{
                        err_.f_message orelse "(unknown)",
                        err_.f_code,
                    });
                    return;
                };
                defer params_.unref();
            }
            fn responded(
                dbus: *gio.DBusConnection,
                _: ?[*:0]const u8,
                _: [*:0]const u8,
                _: [*:0]const u8,
                _: [*:0]const u8,
                params_: *glib.Variant,
                ud: ?*anyopaque,
            ) callconv(.c) void {
                const self_cb: *GlobalShortcuts = @ptrCast(@alignCast(ud));
                const priv = self_cb.private();
                if (priv.response_subscription != 0) {
                    dbus.signalUnsubscribe(priv.response_subscription);
                    priv.response_subscription = 0;
                }
                var response: u32 = 0;
                var vardict: ?*glib.Variant = null;
                defer if (vardict) |v| v.unref();
                params_.get("(u@a{sv})", &response, &vardict);
                switch (response) {
                    0 => {
                        log.debug("request successful", .{});
                        method.onResponse(self_cb, vardict.?);
                    },
                    1 => log.debug("request was cancelled by user", .{}),
                    2 => log.warn("request ended unexpectedly", .{}),
                    else => log.warn("unrecognized response code={}", .{response}),
                }
            }
        };
        var request_token_buf: Token = undefined;
        const request_token = generateToken(&request_token_buf);
        const payload = method.makePayload(self, request_token) orelse return;
        const request_path = try self.getRequestPath(request_token);
        const priv = self.private();
        const dbus = priv.dbus_connection.?;
        assert(priv.response_subscription == 0);
        priv.response_subscription = dbus.signalSubscribe(
            null,
            "org.freedesktop.portal.Request",
            "Response",
            request_path,
            null,
            .{},
            callbacks.responded,
            self,
            null,
        );
        dbus.call(
            "org.freedesktop.portal.Desktop",
            "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.GlobalShortcuts",
            method.name(),
            payload,
            null,
            .{},
            -1,
            null,
            callbacks.gotResponseHandle,
            null,
        );
    }
    fn getRequestPath(self: *Self, token: [:0]const u8) Allocator.Error![:0]const u8 {
        const priv = self.private();
        const dbus = priv.dbus_connection.?;
        const alloc = priv.arena.?.allocator();
        const unique_name = std.mem.span(dbus.getUniqueName().?);
        const object_path = try std.mem.joinZ(
            alloc,
            "/",
            &.{
                "/org/freedesktop/portal/desktop/request",
                unique_name[1..],
                token,
            },
        );
        std.mem.replaceScalar(u8, object_path, '.', '_');
        return object_path;
    }
    pub fn setDbusConnection(
        self: *Self,
        dbus_connection: ?*gio.DBusConnection,
    ) void {
        const priv = self.private();
        if (priv.dbus_connection) |v| {
            self.close();
            v.unref();
            priv.dbus_connection = null;
        }
        priv.dbus_connection = null;
        if (dbus_connection) |v| {
            v.ref();
            priv.dbus_connection = v;
            self.refresh() catch |err| {
                log.warn("error refreshing global shortcuts: {}", .{err});
            };
        }
        self.as(gobject.Object).notifyByPspec(properties.@"dbus-connection".impl.param_spec);
    }
    fn propConfig(
        _: *Self,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.refresh() catch |err| {
            log.warn("error refreshing global shortcuts: {}", .{err});
        };
    }
    fn shortcutActivated(
        _: *gio.DBusConnection,
        _: ?[*:0]const u8,
        _: [*:0]const u8,
        _: [*:0]const u8,
        _: [*:0]const u8,
        params: *glib.Variant,
        ud: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud));
        var shortcut_id: [*:0]const u8 = undefined;
        params.getChild(1, "&s", &shortcut_id);
        log.debug("activated={s}", .{shortcut_id});
        const action = self.private().map.get(std.mem.span(shortcut_id)) orelse return;
        self.emitTrigger(&action);
    }
    pub fn emitTrigger(self: *Self, action: *const Binding.Action) void {
        signals.trigger.impl.emit(
            self,
            null,
            .{action},
            null,
        );
    }
    pub fn emitBindFailed(self: *Self, failure: *const BindFailed) void {
        signals.@"bind-failed".impl.emit(
            self,
            null,
            .{failure},
            null,
        );
    }
    fn dispose(self: *Self) callconv(.c) void {
        self.close();
        const priv = self.private();
        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }
        if (priv.dbus_connection) |v| {
            v.unref();
            priv.dbus_connection = null;
        }
        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }
    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;
    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;
        fn init(class: *Class) callconv(.c) void {
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
                properties.@"dbus-connection".impl,
            });
            signals.trigger.impl.register(.{});
            signals.@"bind-failed".impl.register(.{});
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }
        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};
const Token = [16]u8;
fn generateToken(buf: *Token) [:0]const u8 {
    return std.fmt.bufPrintZ(
        buf,
        "wasp_{x:0<7}",
        .{rand_int: {
            const rng_impl: std.Random.IoSource = .{ .io = global.io() };
            break :rand_int rng_impl.interface().int(u28);
        }},
    ) catch unreachable;
}
