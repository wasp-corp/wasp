const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config.zig");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const internal_os = @import("os/root.zig");
const fontconfig = @import("fontconfig");
const glslang = @import("glslang");
const harfbuzz = @import("harfbuzz");
const oni = @import("oniguruma");
const crash = @import("crash/main.zig");
const renderer = @import("renderer.zig");
const apprt = @import("apprt.zig");
const assert = @import("quirks.zig").inlineAssert;
const allocTmpDir = @import("os/file.zig").allocTmpDir;
const freeTmpDir = @import("os/file.zig").freeTmpDir;
comptime {
    switch (@import("terminal_options").artifact) {
        .wasp => {},
        .lib => @compileError("global state cannot be used in libwasp-vt"),
    }
}
pub const xev = @import("xev").Dynamic;
var state: ?GlobalState = null;
pub const InitOpts = union(enum) {
    main: std.process.Init.Minimal,
    tool: std.process.Init.Minimal,
    c: struct {
        argc: usize,
        argv: [*][*:0]u8,
        environ: std.process.Environ,
    },
};
pub fn init(opts: InitOpts) !void {
    state = .{
        .io_impl = undefined,
        .gpa = null,
        .alloc = undefined,
        .environ = switch (opts) {
            .main, .tool => |m| m.environ,
            .c => |c| c.environ,
        },
        .args = switch (opts) {
            .main, .tool => |m| m.args,
            .c => |c| .{ .vector = if (builtin.os.tag == .windows)
                return error.UnsupportedOSForCApi
            else
                c.argv[0..c.argc] },
        },
        .tmp_dir_path = null,
        .action = null,
        .logging = .{},
        .rlimits = .{},
        .resources_dir = .{},
    };
    const self = &state.?;
    errdefer deinit();
    self.gpa = gpa: {
        if (builtin.link_libc) {
            if (switch (builtin.mode) {
                .ReleaseSafe, .ReleaseFast => true,
                else => std.valgrind.runningOnValgrind() > 0,
            }) break :gpa null;
        }
        break :gpa .init;
    };
    self.alloc = if (self.gpa) |*value|
        value.allocator()
    else if (builtin.link_libc)
        std.heap.c_allocator
    else
        unreachable;
    self.io_impl = .init(self.alloc, .{
        .argv0 = .init(self.args),
        .environ = self.environ,
    });
    self.tmp_dir_path = try allocTmpDir(self.alloc, self.environ);
    self.action = switch (opts) {
        .main, .c => try cli.action.detectArgs(
            cli.wasp.Action,
            self.alloc,
            self.args,
        ),
        .tool => null,
    };
    if (self.action != null) self.logging.stderr = false;
    logging: {
        const v = self.environ.getAlloc(self.alloc, "WASP_LOG") catch |err| switch (err) {
            error.EnvironmentVariableMissing => break :logging,
            else => return err,
        };
        defer self.alloc.free(v);
        self.logging = cli.args.parsePackedStruct(GlobalState.Logging, v) catch .{};
    }
    GlobalState.initSignals();
    if (comptime xev.dynamic) xev.detect() catch |err| {
        std.log.warn("failed to detect xev backend, falling back to " ++
            "most compatible backend err={}", .{err});
    };
    std.log.info("wasp version={s}", .{build_config.version_string});
    std.log.info("wasp build optimize={s}", .{build_config.mode_string});
    std.log.info("runtime={}", .{build_config.app_runtime});
    std.log.info("font_backend={}", .{build_config.font_backend});
    if (comptime build_config.font_backend.hasHarfbuzz()) {
        std.log.info("dependency harfbuzz={s}", .{harfbuzz.versionString()});
    }
    if (comptime build_config.font_backend.hasFontconfig()) {
        std.log.info("dependency fontconfig={d}", .{fontconfig.version()});
    }
    std.log.info("renderer={}", .{renderer.Renderer});
    std.log.info("libxev default backend={t}", .{xev.backend});
    self.rlimits = .init();
    if (build_options.sentry) {
        const environ_map = try self.environ.createMap(self.alloc);
        crash.init(self.alloc, environ_map) catch |err| {
            std.log.warn(
                "sentry init failed, no crash capture available err={}",
                .{err},
            );
        };
    }
    try internal_os.ensureLocale();
    syncEnviron();
    try glslang.init();
    try oni.init(&.{oni.Encoding.utf8});
    self.resources_dir = try apprt.runtime.resourcesDir(self.alloc);
    errdefer self.resources_dir.deinit(self.alloc);
    if (self.resources_dir.app()) |v| internal_os.i18n.init(v) catch |err| {
        std.log.warn("failed to init i18n, translations will not be available err={}", .{err});
    };
}
pub fn deinit() void {
    const self = &state.?;
    self.resources_dir.deinit(self.alloc);
    crash.deinit();
    if (self.tmp_dir_path) |td| freeTmpDir(self.alloc, td);
    self.io_impl.deinit();
    if (self.gpa) |*value| {
        _ = value.deinit();
    }
}
pub fn io() std.Io {
    if (builtin.is_test) return std.testing.io;
    return state.?.io();
}
pub fn alloc() std.mem.Allocator {
    if (builtin.is_test) return std.testing.allocator;
    return state.?.alloc;
}
pub fn environ() std.process.Environ {
    if (builtin.is_test) return std.testing.environ;
    return state.?.environ;
}
pub fn environMap() !std.process.Environ.Map {
    if (builtin.is_test) return std.testing.environ.createMap(std.testing.allocator);
    return state.?.environ.createMap(state.?.alloc);
}
pub fn syncEnviron() void {
    switch (builtin.os.tag) {
        .windows => {},
        else => {
            assert(builtin.link_libc);
            assert(!builtin.is_test);
            const new_environ: std.process.Environ = .{ .block = .{ .slice = std.c.environ[0..env_len: {
                var len: usize = 0;
                while (std.c.environ[len]) |_| : (len += 1) {}
                break :env_len len;
            } :null] } };
            state.?.environ = new_environ;
            state.?.io_impl.environ = .{ .process_environ = new_environ };
        },
    }
}
pub fn args() std.process.Args {
    if (builtin.is_test) return .{ .vector = &.{} };
    return state.?.args;
}
pub fn tmpDirPath() []const u8 {
    return state.?.tmp_dir_path.?;
}
pub fn resourcesDir() internal_os.ResourcesDir {
    if (builtin.is_test) return .{};
    return state.?.resources_dir;
}
pub fn rlimits() ResourceLimits {
    if (builtin.is_test) return .{};
    return state.?.rlimits;
}
pub fn logging() GlobalState.Logging {
    return state.?.logging;
}
pub fn action() ?cli.wasp.Action {
    return state.?.action;
}
pub const GlobalState = struct {
    const GPA = std.heap.DebugAllocator(.{});
    io_impl: std.Io.Threaded,
    gpa: ?GPA,
    alloc: std.mem.Allocator,
    environ: std.process.Environ,
    args: std.process.Args,
    tmp_dir_path: ?[]const u8,
    action: ?cli.wasp.Action,
    logging: Logging,
    rlimits: ResourceLimits = .{},
    resources_dir: internal_os.ResourcesDir,
    pub const Logging = packed struct {
        stderr: bool = build_config.app_runtime != .none,
        macos: bool = builtin.os.tag.isDarwin(),
    };
    pub fn io(self: *GlobalState) std.Io {
        return self.io_impl.io();
    }
    fn initSignals() void {
        if (comptime builtin.os.tag == .windows) return;
        const p = std.posix;
        var sa: p.Sigaction = .{
            .handler = .{ .handler = p.SIG.IGN },
            .mask = p.sigemptyset(),
            .flags = 0,
        };
        p.sigaction(p.SIG.PIPE, &sa, null);
    }
};
pub const ResourceLimits = struct {
    nofile: ?internal_os.rlimit = null,
    pub fn init() ResourceLimits {
        return .{
            .nofile = internal_os.fixMaxFiles(),
        };
    }
    pub fn restore(self: *const ResourceLimits) void {
        if (self.nofile) |lim| internal_os.restoreMaxFiles(lim);
    }
};
