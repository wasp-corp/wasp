const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const posix = std.posix;
const global = @import("../global.zig");
const xev = global.xev;
const log = std.log.scoped(.flatpak);
pub fn isFlatpak() bool {
    if (comptime builtin.os.tag != .linux) return false;
    return if (std.Io.Dir.accessAbsolute(global.io(), "/.flatpak-info", .{}))
        true
    else |_|
        false;
}
pub const FlatpakHostCommand = struct {
    const fd_t = posix.fd_t;
    const EnvMap = std.process.Environ.Map;
    const gio_c = @import("gio_c");
    const Flags = packed struct(c_uint) {
        clear_env: bool = false,
        watch_bus: bool = false,
        _reserved: std.meta.Int(.unsigned, @bitSizeOf(c_uint) - 2) = 0,
    };
    argv: []const []const u8,
    cwd: ?[:0]const u8 = null,
    env: ?*const EnvMap = null,
    stdin: fd_t,
    stdout: fd_t,
    stderr: fd_t,
    state: State = .{ .init = {} },
    state_mutex: std.Io.Mutex = .init,
    state_cv: std.Io.Condition = .init,
    const State = union(enum) {
        init: void,
        err: void,
        started: struct {
            pid: u32,
            loop_xev: ?*xev.Loop,
            completion: ?*Completion,
            subscription: gio_c.guint,
            loop: *gio_c.GMainLoop,
        },
        exited: struct {
            pid: u32,
            status: u8,
        },
    };
    pub const Completion = struct {
        callback: *const fn (ud: ?*anyopaque, l: *xev.Loop, c: *Completion, r: WaitError!u8) void = noopCallback,
        c_xev: xev.Completion = .{},
        userdata: ?*anyopaque = null,
        timer: ?xev.Timer = null,
        result: ?WaitError!u8 = null,
    };
    pub const Error = error{
        FlatpakMustBeStarted,
        FlatpakSpawnFail,
        FlatpakSetupFail,
        FlatpakRPCFail,
    };
    pub const WaitError = xev.Timer.RunError || Error;
    pub fn spawn(self: *FlatpakHostCommand, alloc: Allocator) !u32 {
        const thread = try std.Thread.spawn(.{}, threadMain, .{ self, alloc });
        thread.setName(global.io(), "flatpak-host-command") catch {};
        thread.detach();
        self.state_mutex.lockUncancelable(global.io());
        defer self.state_mutex.unlock(global.io());
        while (self.state == .init) self.state_cv.waitUncancelable(global.io(), &self.state_mutex);
        return switch (self.state) {
            .init => unreachable,
            .err => Error.FlatpakSpawnFail,
            .started => |v| v.pid,
            .exited => |v| v.pid,
        };
    }
    pub fn wait(self: *FlatpakHostCommand) !u8 {
        self.state_mutex.lockUncancelable(global.io());
        defer self.state_mutex.unlock(global.io());
        while (true) {
            switch (self.state) {
                .init => return Error.FlatpakMustBeStarted,
                .err => return Error.FlatpakSpawnFail,
                .started => {},
                .exited => |v| {
                    self.state = .{ .init = {} };
                    self.state_cv.broadcast(global.io());
                    return v.status;
                },
            }
            self.state_cv.waitUncancelable(global.io(), &self.state_mutex);
        }
    }
    pub fn waitXev(
        self: *FlatpakHostCommand,
        loop: *xev.Loop,
        completion: *Completion,
        comptime Userdata: type,
        userdata: ?*Userdata,
        comptime cb: *const fn (
            ud: ?*Userdata,
            l: *xev.Loop,
            c: *Completion,
            r: WaitError!u8,
        ) void,
    ) void {
        self.state_mutex.lockUncancelable(global.io());
        defer self.state_mutex.unlock(global.io());
        completion.* = .{
            .callback = (struct {
                fn callback(
                    ud_: ?*anyopaque,
                    l_inner: *xev.Loop,
                    c_inner: *Completion,
                    r: WaitError!u8,
                ) void {
                    const ud = @as(?*Userdata, if (Userdata == void) null else @ptrCast(@alignCast(ud_)));
                    @call(.always_inline, cb, .{ ud, l_inner, c_inner, r });
                }
            }).callback,
            .userdata = userdata,
            .timer = xev.Timer.init() catch unreachable, 
        };
        switch (self.state) {
            .init => completion.result = Error.FlatpakMustBeStarted,
            .err => completion.result = Error.FlatpakSpawnFail,
            .started => |*v| {
                v.loop_xev = loop;
                v.completion = completion;
                return;
            },
            .exited => |v| {
                completion.result = v.status;
            },
        }
        completion.timer.?.run(
            loop,
            &completion.c_xev,
            0,
            anyopaque,
            completion.userdata,
            (struct {
                fn callback(
                    ud: ?*anyopaque,
                    l_inner: *xev.Loop,
                    c_inner: *xev.Completion,
                    r: xev.Timer.RunError!void,
                ) xev.CallbackAction {
                    const c_outer: *Completion = @fieldParentPtr("c_xev", c_inner);
                    defer if (c_outer.timer) |*t| t.deinit();
                    const result = if (r) |_| c_outer.result.? else |err| err;
                    c_outer.callback(ud, l_inner, c_outer, result);
                    return .disarm;
                }
            }).callback,
        );
    }
    pub fn signal(self: *FlatpakHostCommand, sig: u8, pg: bool) !void {
        const pid = pid: {
            self.state_mutex.lockUncancelable(global.io());
            defer self.state_mutex.unlock(global.io());
            switch (self.state) {
                .started => |v| break :pid v.pid,
                else => return,
            }
        };
        var g_err: ?*gio_c.GError = null;
        defer if (g_err) |ptr| gio_c.g_error_free(ptr);
        const bus = gio_c.g_bus_get_sync(gio_c.G_BUS_TYPE_SESSION, null, &g_err) orelse {
            log.warn("signal error getting bus: {s}", .{g_err.?.*.message});
            return Error.FlatpakSetupFail;
        };
        defer gio_c.g_object_unref(bus);
        const reply = gio_c.g_dbus_connection_call_sync(
            bus,
            "org.freedesktop.Flatpak",
            "/org/freedesktop/Flatpak/Development",
            "org.freedesktop.Flatpak.Development",
            "HostCommandSignal",
            gio_c.g_variant_new(
                "(uub)",
                pid,
                sig,
                @as(c_int, @intCast(@intFromBool(pg))),
            ),
            gio_c.G_VARIANT_TYPE("()"),
            gio_c.G_DBUS_CALL_FLAGS_NONE,
            gio_c.G_MAXINT,
            null,
            &g_err,
        );
        if (g_err != null) {
            log.warn("signal send error: {s}", .{g_err.?.*.message});
            return;
        }
        defer gio_c.g_variant_unref(reply);
    }
    fn threadMain(self: *FlatpakHostCommand, alloc: Allocator) void {
        const ctx = gio_c.g_main_context_new();
        defer gio_c.g_main_context_unref(ctx);
        gio_c.g_main_context_push_thread_default(ctx);
        defer gio_c.g_main_context_pop_thread_default(ctx);
        const loop = gio_c.g_main_loop_new(ctx, 1).?;
        defer gio_c.g_main_loop_unref(loop);
        var g_err: ?*gio_c.GError = null;
        defer if (g_err) |ptr| gio_c.g_error_free(ptr);
        const bus = gio_c.g_bus_get_sync(gio_c.G_BUS_TYPE_SESSION, null, &g_err) orelse {
            log.warn("spawn error getting bus: {s}", .{g_err.?.*.message});
            self.updateState(.{ .err = {} });
            return;
        };
        defer gio_c.g_object_unref(bus);
        self.start(alloc, bus, loop) catch |err| {
            log.warn("error starting host command: {}", .{err});
            self.updateState(.{ .err = {} });
            return;
        };
        gio_c.g_main_loop_run(loop);
    }
    fn start(
        self: *FlatpakHostCommand,
        alloc: Allocator,
        bus: *gio_c.GDBusConnection,
        loop: *gio_c.GMainLoop,
    ) !void {
        var err: ?*gio_c.GError = null;
        defer if (err) |ptr| gio_c.g_error_free(ptr);
        var arena_allocator = std.heap.ArenaAllocator.init(alloc);
        defer arena_allocator.deinit();
        const arena = arena_allocator.allocator();
        const fd_list = gio_c.g_unix_fd_list_new();
        defer gio_c.g_object_unref(fd_list);
        if (gio_c.g_unix_fd_list_append(fd_list, self.stdin, &err) < 0) {
            log.warn("error adding fd: {s}", .{err.?.*.message});
            return Error.FlatpakSetupFail;
        }
        if (gio_c.g_unix_fd_list_append(fd_list, self.stdout, &err) < 0) {
            log.warn("error adding fd: {s}", .{err.?.*.message});
            return Error.FlatpakSetupFail;
        }
        if (gio_c.g_unix_fd_list_append(fd_list, self.stderr, &err) < 0) {
            log.warn("error adding fd: {s}", .{err.?.*.message});
            return Error.FlatpakSetupFail;
        }
        const fd_builder = gio_c.g_variant_builder_new(gio_c.G_VARIANT_TYPE("a{uh}"));
        defer gio_c.g_variant_builder_unref(fd_builder);
        gio_c.g_variant_builder_add(fd_builder, "{uh}", @as(c_int, 0), self.stdin);
        gio_c.g_variant_builder_add(fd_builder, "{uh}", @as(c_int, 1), self.stdout);
        gio_c.g_variant_builder_add(fd_builder, "{uh}", @as(c_int, 2), self.stderr);
        const env_builder = gio_c.g_variant_builder_new(gio_c.G_VARIANT_TYPE("a{ss}"));
        defer gio_c.g_variant_builder_unref(env_builder);
        if (self.env) |env| {
            var it = env.iterator();
            while (it.next()) |pair| {
                const key = try arena.dupeZ(u8, pair.key_ptr.*);
                const value = try arena.dupeZ(u8, pair.value_ptr.*);
                gio_c.g_variant_builder_add(env_builder, "{ss}", key.ptr, value.ptr);
            }
        }
        const args = try arena.alloc(?[*:0]u8, self.argv.len + 1);
        for (0.., self.argv) |i, arg| {
            const argZ = try arena.dupeZ(u8, arg);
            args[i] = argZ.ptr;
        }
        args[args.len - 1] = null;
        const g_cwd = gio_c.g_get_current_dir();
        defer gio_c.g_free(g_cwd);
        const flags: Flags = .{ .watch_bus = true };
        const params = gio_c.g_variant_new(
            "(^ay^aay@a{uh}@a{ss}u)",
            @as(*const anyopaque, if (self.cwd) |*cwd| cwd.ptr else g_cwd),
            args.ptr,
            gio_c.g_variant_builder_end(fd_builder),
            gio_c.g_variant_builder_end(env_builder),
            @as(c_uint, @bitCast(flags)),
        );
        _ = gio_c.g_variant_ref_sink(params); 
        defer gio_c.g_variant_unref(params);
        const subscription_id = gio_c.g_dbus_connection_signal_subscribe(
            bus,
            "org.freedesktop.Flatpak",
            "org.freedesktop.Flatpak.Development",
            "HostCommandExited",
            "/org/freedesktop/Flatpak/Development",
            null,
            0,
            onExit,
            self,
            null,
        );
        errdefer gio_c.g_dbus_connection_signal_unsubscribe(bus, subscription_id);
        const reply = gio_c.g_dbus_connection_call_with_unix_fd_list_sync(
            bus,
            "org.freedesktop.Flatpak",
            "/org/freedesktop/Flatpak/Development",
            "org.freedesktop.Flatpak.Development",
            "HostCommand",
            params,
            gio_c.G_VARIANT_TYPE("(u)"),
            gio_c.G_DBUS_CALL_FLAGS_NONE,
            gio_c.G_MAXINT,
            fd_list,
            null,
            null,
            &err,
        ) orelse {
            log.warn("Flatpak.HostCommand failed: {s}", .{err.?.*.message});
            return Error.FlatpakRPCFail;
        };
        defer gio_c.g_variant_unref(reply);
        var pid: u32 = 0;
        gio_c.g_variant_get(reply, "(u)", &pid);
        log.debug("HostCommand started pid={} subscription={}", .{
            pid,
            subscription_id,
        });
        self.updateState(.{
            .started = .{
                .pid = pid,
                .subscription = subscription_id,
                .loop = loop,
                .completion = null,
                .loop_xev = null,
            },
        });
    }
    fn updateState(self: *FlatpakHostCommand, state: State) void {
        self.state_mutex.lockUncancelable(global.io());
        defer self.state_mutex.unlock(global.io());
        defer self.state_cv.broadcast(global.io());
        self.state = state;
    }
    fn onExit(
        bus: ?*gio_c.GDBusConnection,
        _: [*c]const u8,
        _: [*c]const u8,
        _: [*c]const u8,
        _: [*c]const u8,
        params: ?*gio_c.GVariant,
        ud: ?*anyopaque,
    ) callconv(.c) void {
        const self = @as(*FlatpakHostCommand, @ptrCast(@alignCast(ud)));
        const state = state: {
            self.state_mutex.lockUncancelable(global.io());
            defer self.state_mutex.unlock(global.io());
            break :state self.state.started;
        };
        var pid: u32 = 0;
        var exit_status_raw: u32 = 0;
        gio_c.g_variant_get(params.?, "(uu)", &pid, &exit_status_raw);
        if (state.pid != pid) return;
        const exit_status = posix.W.EXITSTATUS(exit_status_raw);
        self.updateState(.{
            .exited = .{
                .pid = pid,
                .status = exit_status,
            },
        });
        if (state.completion) |completion| {
            completion.result = exit_status;
            completion.timer.?.run(
                state.loop_xev.?,
                &completion.c_xev,
                0,
                anyopaque,
                completion.userdata,
                (struct {
                    fn callback(
                        ud_inner: ?*anyopaque,
                        l_inner: *xev.Loop,
                        c_inner: *xev.Completion,
                        r: xev.Timer.RunError!void,
                    ) xev.CallbackAction {
                        const c_outer: *Completion = @fieldParentPtr("c_xev", c_inner);
                        defer if (c_outer.timer) |*t| t.deinit();
                        const result = if (r) |_| c_outer.result.? else |err| err;
                        c_outer.callback(ud_inner, l_inner, c_outer, result);
                        return .disarm;
                    }
                }).callback,
            );
        }
        log.debug("HostCommand exited pid={} status={}", .{ pid, exit_status });
        gio_c.g_dbus_connection_signal_unsubscribe(bus.?, state.subscription);
        gio_c.g_main_loop_quit(state.loop);
    }
    fn noopCallback(_: ?*anyopaque, _: *xev.Loop, _: *Completion, _: WaitError!u8) void {}
};
