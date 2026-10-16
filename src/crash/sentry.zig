const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const build_options = @import("build_options");
const sentry = if (build_options.sentry) @import("sentry");
const internal_os = @import("../os/root.zig");
const crash = @import("main.zig");
const Surface = @import("../Surface.zig");
const log = std.log.scoped(.sentry);
var init_thread: ?std.Thread = null;
var dir_mem: [std.Io.Dir.max_path_bytes * 2]u8 = undefined;
var cache_dir_: ?[]const u8 = null;
var state_dir_: ?[]const u8 = null;
pub const ThreadState = struct {
    type: Type,
    surface: *Surface,
    pub const Type = enum { main, renderer, io };
};
pub threadlocal var thread_state: ?ThreadState = null;
pub fn init(gpa: Allocator, environ_map: std.process.Environ.Map) !void {
    if (comptime !build_options.sentry) {
        var map = environ_map;
        map.deinit();
        return;
    }
    if (comptime builtin.os.tag == .windows) {
        var map = environ_map;
        map.deinit();
        return;
    }
    assert(init_thread == null);
    const thr = std.Thread.spawn(
        .{},
        initThread,
        .{ gpa, environ_map },
    ) catch |err| {
        var map = environ_map;
        map.deinit();
        return err;
    };
    var single_threaded: std.Io.Threaded = .init_single_threaded;
    defer single_threaded.deinit();
    thr.setName(single_threaded.io(), "sentry-init") catch {};
    init_thread = thr;
}
fn initThread(gpa: Allocator, environ_map_: std.process.Environ.Map) !void {
    var environ_map = environ_map_;
    defer environ_map.deinit();
    if (builtin.os.tag.isDarwin()) {
        internal_os.macos.pthread_setname_np(&"sentry-init".*);
    }
    var single_threaded: std.Io.Threaded = .init_single_threaded;
    defer single_threaded.deinit();
    var fba: std.heap.FixedBufferAllocator = .init(&dir_mem);
    state_dir_ = state_dir: {
        const dir = try crash.defaultDir(
            single_threaded.io(),
            gpa,
            &environ_map,
        );
        defer gpa.free(dir.path);
        break :state_dir try fba.allocator().dupe(u8, dir.path);
    };
    errdefer state_dir_ = null;
    const cache_dir = cache_dir: {
        const dir = try cacheDir(
            single_threaded.io(),
            gpa,
            &environ_map,
        );
        defer gpa.free(dir);
        break :cache_dir try fba.allocator().dupe(u8, dir);
    };
    cache_dir_ = cache_dir;
    errdefer cache_dir_ = null;
    const transport = sentry.Transport.init(&Transport.send);
    const opts = sentry.c.sentry_options_new();
    errdefer sentry.c.sentry_options_free(opts);
    sentry.c.sentry_options_set_release_n(
        opts,
        build_config.version_string.ptr,
        build_config.version_string.len,
    );
    sentry.c.sentry_options_set_transport(opts, @ptrCast(transport));
    sentry.c.sentry_options_set_before_send(opts, beforeSend, null);
    sentry.c.sentry_options_set_database_path_n(
        opts,
        cache_dir.ptr,
        cache_dir.len,
    );
    if (comptime builtin.mode == .Debug) {
        sentry.c.sentry_options_set_debug(opts, @intFromBool(true));
    }
    if (sentry.c.sentry_init(opts) != 0) return error.SentryInitFailed;
    sentry.setTag("build-mode", build_config.mode_string);
    sentry.setTag("app-runtime", @tagName(build_config.app_runtime));
    sentry.setTag("font-backend", @tagName(build_config.font_backend));
    sentry.setTag("renderer", @tagName(build_config.renderer));
    log.debug("sentry initialized database={s}", .{cache_dir});
}
fn cacheDir(io: std.Io, alloc: Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    if (comptime builtin.os.tag == .macos) macos: {
        const xdg_cache_home = environ_map.get("XDG_CACHE_HOME") orelse break :macos;
        if (xdg_cache_home.len > 0) {
            return try internal_os.macos.cacheDir(
                alloc,
                "sentry",
            );
        }
    }
    return try internal_os.xdg.cache(
        io,
        alloc,
        environ_map,
        .{ .subdir = "wasp/sentry" },
    );
}
pub fn deinit() void {
    if (comptime !build_options.sentry) return;
    if (comptime builtin.os.tag == .windows) return;
    const thr = init_thread orelse return;
    thr.join();
    _ = sentry.c.sentry_close();
}
fn beforeSend(
    event_val: sentry.c.sentry_value_t,
    _: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) sentry.c.sentry_value_t {
    const thr_state = thread_state orelse {
        log.debug("no thread state, skipping crash metadata", .{});
        return event_val;
    };
    const event: sentry.Value = .{ .value = event_val };
    const contexts = event.get("contexts") orelse contexts: {
        const obj = sentry.Value.initObject();
        event.set("contexts", obj);
        break :contexts obj;
    };
    const tags = event.get("tags") orelse tags: {
        const obj = sentry.Value.initObject();
        event.set("tags", obj);
        break :tags obj;
    };
    tags.set("thread-type", sentry.Value.initString(@tagName(thr_state.type)));
    {
        const obj = sentry.Value.initObject();
        errdefer obj.decref();
        const surface = thr_state.surface;
        const grid_size = surface.size.grid();
        obj.set(
            "screen-width",
            sentry.Value.initInt32(std.math.cast(i32, surface.size.screen.width) orelse -1),
        );
        obj.set(
            "screen-height",
            sentry.Value.initInt32(std.math.cast(i32, surface.size.screen.height) orelse -1),
        );
        obj.set(
            "grid-columns",
            sentry.Value.initInt32(std.math.cast(i32, grid_size.columns) orelse -1),
        );
        obj.set(
            "grid-rows",
            sentry.Value.initInt32(std.math.cast(i32, grid_size.rows) orelse -1),
        );
        obj.set(
            "cell-width",
            sentry.Value.initInt32(std.math.cast(i32, surface.size.cell.width) orelse -1),
        );
        obj.set(
            "cell-height",
            sentry.Value.initInt32(std.math.cast(i32, surface.size.cell.height) orelse -1),
        );
        contexts.set("Dimensions", obj);
    }
    return event_val;
}
pub const Transport = struct {
    pub fn send(envelope: *sentry.Envelope, ud: ?*anyopaque) callconv(.c) void {
        _ = ud;
        defer envelope.deinit();
        sendInternal(envelope) catch |err| {
            log.warn("failed to persist crash report err={}", .{err});
        };
    }
    fn sendInternal(envelope: *sentry.Envelope) !void {
        const state_dir = state_dir_ orelse return error.StateDirNotInitialized;
        var single_threaded: std.Io.Threaded = .init_single_threaded;
        defer single_threaded.deinit();
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        const json = envelope.serialize();
        defer sentry.free(@ptrCast(json.ptr));
        var parsed: crash.Envelope = parsed: {
            var reader: std.Io.Reader = .fixed(json);
            break :parsed try crash.Envelope.parse(alloc, &reader);
        };
        defer parsed.deinit();
        if (try shouldDiscard(&parsed)) {
            log.info("sentry envelope does not contain crash, discarding", .{});
            return;
        }
        const uuid = sentry.UUID.init();
        try std.Io.Dir.cwd().createDirPath(single_threaded.io(), state_dir);
        const path = try std.fs.path.join(alloc, &.{
            state_dir,
            try std.fmt.allocPrint(alloc, "{s}.waspcrash", .{uuid.string()}),
        });
        const file = try std.Io.Dir.cwd().createFile(single_threaded.io(), path, .{});
        defer file.close(single_threaded.io());
        var buf: [4096]u8 = undefined;
        var file_writer = file.writer(single_threaded.io(), &buf);
        try file_writer.interface.writeAll(json);
        try file_writer.end();
        log.warn("crash report written to disk path={s}", .{path});
    }
    fn shouldDiscard(envelope: *const crash.Envelope) !bool {
        for (envelope.items.items) |item| {
            if (item.itemType() == .event) return false;
        }
        return true;
    }
};
