const Exec = @This();
const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const posix = std.posix;
const global = @import("../global.zig");
const xev = global.xev;
const apprt = @import("../apprt.zig");
const build_config = @import("../build_config.zig");
const configpkg = @import("../config.zig");
const crash = @import("../crash/main.zig");
const fastmem = @import("../fastmem.zig");
const internal_os = @import("../os/root.zig");
const renderer = @import("../renderer.zig");
const shell_integration = @import("shell_integration.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const Command = @import("../Command.zig");
const ptypkg = @import("../pty.zig");
const Pty = ptypkg.Pty;
const EnvMap = std.process.Environ.Map;
const PasswdEntry = internal_os.passwd.Entry;
const windows = internal_os.windows;
const ProcessInfo = @import("../pty.zig").ProcessInfo;
const compat_fd = @import("../lib/compat/fd.zig");
const log = std.log.scoped(.io_exec);
const TERMIOS_POLL_MS = 200;
const FlatpakHostCommand = if (!build_config.flatpak) struct {
    pub const Completion = struct {};
} else internal_os.FlatpakHostCommand;
subprocess: Subprocess,
pub fn init(
    alloc: Allocator,
    cfg: Config,
) !Exec {
    var subprocess = try Subprocess.init(alloc, cfg);
    errdefer subprocess.deinit();
    return .{ .subprocess = subprocess };
}
pub fn deinit(self: *Exec) void {
    self.subprocess.deinit();
}
pub fn initTerminal(self: *Exec, term: *terminal.Terminal) void {
    if (self.subprocess.cwd) |cwd| term.setPwd(cwd) catch |err| {
        log.warn("error setting initial pwd err={}", .{err});
    };
    self.resize(.{
        .columns = term.cols,
        .rows = term.rows,
    }, .{
        .width = term.width_px,
        .height = term.height_px,
    }) catch unreachable;
}
pub fn threadEnter(
    self: *Exec,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    const pty_fds = self.subprocess.start(alloc) catch |err| {
        if (err != error.ExecFailedInChild) return err;
        std.process.exit(1);
    };
    errdefer self.subprocess.stop();
    var process: ?xev.Process = if (self.subprocess.process) |v| switch (v) {
        .fork_exec => |cmd| try xev.Process.init(
            cmd.pid orelse return error.ProcessNoPid,
        ),
        .flatpak => null,
    } else return error.ProcessNotStarted;
    errdefer if (process) |*p| p.deinit();
    const process_start: std.Io.Timestamp = .now(global.io(), .awake);
    const pipe = try internal_os.pipe();
    errdefer _ = posix.system.close(pipe[0]);
    errdefer _ = posix.system.close(pipe[1]);
    var stream = xev.Stream.initFd(pty_fds.write);
    errdefer stream.deinit();
    var termios_timer = try xev.Timer.init();
    errdefer termios_timer.deinit();
    const read_thread = try std.Thread.spawn(
        .{},
        if (builtin.os.tag == .windows) ReadThread.threadMainWindows else ReadThread.threadMainPosix,
        .{ pty_fds.read, io, pipe[0] },
    );
    read_thread.setName(global.io(), "io-reader") catch {};
    td.backend = .{ .exec = .{
        .start = process_start,
        .write_stream = stream,
        .process = process,
        .read_thread = read_thread,
        .read_thread_pipe = pipe[1],
        .read_thread_fd = pty_fds.read,
        .termios_timer = termios_timer,
    } };
    if (process) |*p| p.wait(
        td.loop,
        &td.backend.exec.process_wait_c,
        termio.Termio.ThreadData,
        td,
        processExit,
    ) else if (comptime build_config.flatpak) flatpak: {
        switch (self.subprocess.process orelse break :flatpak) {
            .flatpak => |*c| c.waitXev(
                td.loop,
                &td.backend.exec.flatpak_wait_c,
                termio.Termio.ThreadData,
                td,
                flatpakExit,
            ),
            .fork_exec => {},
        }
    }
    if (comptime builtin.os.tag != .windows) {
        termios_timer.run(
            td.loop,
            &td.backend.exec.termios_timer_c,
            TERMIOS_POLL_MS,
            termio.Termio.ThreadData,
            td,
            termiosTimer,
        );
    }
}
pub fn threadExit(self: *Exec, td: *termio.Termio.ThreadData) void {
    assert(td.backend == .exec);
    const exec = &td.backend.exec;
    if (exec.exited) self.subprocess.externalExit();
    self.subprocess.stop();
    switch (posix.errno(posix.system.write(exec.read_thread_pipe, "x", 1))) {
        .SUCCESS => {},
        .PIPE => {},
        else => |e| log.warn(
            "error writing to read thread quit pipe err=E{s}",
            .{@tagName(e)},
        ),
    }
    if (comptime builtin.os.tag == .windows) {
        if (windows.exp.kernel32.CancelIoEx(exec.read_thread_fd, null) == windows.FALSE) {
            switch (windows.GetLastError()) {
                .NOT_FOUND => {},
                else => |err| log.warn("error interrupting read thread err={}", .{err}),
            }
        }
    }
    exec.read_thread.join();
}
pub fn focusGained(
    self: *Exec,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    assert(td.backend == .exec);
    const execdata = &td.backend.exec;
    if (comptime builtin.os.tag == .windows) return;
    if (!focused) {
        execdata.termios_timer_running = false;
    } else {
        execdata.termios_timer_running = true;
        if (execdata.termios_timer_c.state() != .active) {
            _ = termiosTimer(td, undefined, undefined, {});
        }
    }
}
pub fn resize(
    self: *Exec,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    return try self.subprocess.resize(grid_size, screen_size);
}
fn processExitCommon(td: *termio.Termio.ThreadData, exit_code: u32) void {
    assert(td.backend == .exec);
    const execdata = &td.backend.exec;
    execdata.exited = true;
    const runtime_ms: u64 = @max(
        0,
        execdata.start.untilNow(global.io(), .awake).toMilliseconds(),
    );
    log.debug("child process exited status={} runtime={}ms", .{ exit_code, runtime_ms });
    _ = td.surface_mailbox.push(.{
        .child_exited = .{
            .exit_code = exit_code,
            .runtime_ms = runtime_ms,
        },
    }, .{ .forever = {} });
}
fn processExit(
    td_: ?*termio.Termio.ThreadData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Process.WaitError!u32,
) xev.CallbackAction {
    const exit_code = r catch unreachable;
    processExitCommon(td_.?, exit_code);
    return .disarm;
}
fn flatpakExit(
    td_: ?*termio.Termio.ThreadData,
    _: *xev.Loop,
    _: *FlatpakHostCommand.Completion,
    r: FlatpakHostCommand.WaitError!u8,
) void {
    const exit_code = r catch unreachable;
    processExitCommon(td_.?, exit_code);
}
fn termiosTimer(
    td_: ?*termio.Termio.ThreadData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    if (comptime builtin.os.tag == .windows) {
        @panic("termios timer not implemented on Windows");
    }
    _ = r catch |err| switch (err) {
        error.Canceled => return .disarm,
        else => {
            log.warn("error in termios timer callback err={}", .{err});
            @panic("crash in termios timer callback");
        },
    };
    const td = td_.?;
    assert(td.backend == .exec);
    const exec = &td.backend.exec;
    const mode: ptypkg.Mode = (Pty{
        .master = exec.read_thread_fd,
        .slave = undefined,
    }).getMode() catch |err| err: {
        log.warn("error getting termios mode err={}", .{err});
        break :err .{};
    };
    if (!std.meta.eql(mode, exec.termios_mode)) mode_change: {
        log.debug("termios change mode={}", .{mode});
        exec.termios_mode = mode;
        const password_input = mode.canonical and !mode.echo;
        {
            td.renderer_state.mutex.lockUncancelable(global.io());
            defer td.renderer_state.mutex.unlock(global.io());
            const t = td.renderer_state.terminal;
            if (t.flags.password_input == password_input) {
                break :mode_change;
            }
        }
        _ = td.surface_mailbox.push(.{
            .password_input = password_input,
        }, .{ .forever = {} });
    }
    if (exec.termios_timer_running) {
        exec.termios_timer.run(
            td.loop,
            &exec.termios_timer_c,
            TERMIOS_POLL_MS,
            termio.Termio.ThreadData,
            td,
            termiosTimer,
        );
    }
    return .disarm;
}
pub fn queueWrite(
    self: *Exec,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = self;
    const exec = &td.backend.exec;
    if (exec.exited) return;
    var i: usize = 0;
    while (i < data.len) {
        const w = try exec.write_pool.create(alloc);
        w.td = exec;
        const buf = &w.buf;
        const slice = slice: {
            const max = @min(data.len, i + buf.len);
            if (!linefeed) {
                fastmem.copy(u8, buf, data[i..max]);
                const len = max - i;
                i = max;
                break :slice buf[0..len];
            }
            var buf_i: usize = 0;
            while (i < data.len and buf_i < buf.len - 1) {
                const ch = data[i];
                i += 1;
                if (ch != '\r') {
                    buf[buf_i] = ch;
                    buf_i += 1;
                    continue;
                }
                buf[buf_i] = '\r';
                buf[buf_i + 1] = '\n';
                buf_i += 2;
            }
            break :slice buf[0..buf_i];
        };
        exec.write_stream.queueWrite(
            td.loop,
            &exec.write_queue,
            &w.req,
            .{ .slice = slice },
            ThreadData.Write,
            w,
            ttyWrite,
        );
    }
}
fn ttyWrite(
    w_: ?*ThreadData.Write,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.Stream,
    _: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    const w = w_.?;
    w.td.write_pool.destroy(w);
    const d = r catch |err| {
        log.err("write error: {}", .{err});
        return .disarm;
    };
    _ = d;
    return .disarm;
}
pub const ThreadData = struct {
    pub const Write = struct {
        td: *ThreadData,
        req: xev.WriteRequest,
        buf: [64]u8,
    };
    start: std.Io.Timestamp,
    exited: bool = false,
    write_stream: xev.Stream,
    process: ?xev.Process,
    write_pool: std.heap.MemoryPool(Write) = .empty,
    write_queue: xev.WriteQueue = .{},
    process_wait_c: xev.Completion = .{},
    flatpak_wait_c: FlatpakHostCommand.Completion = .{},
    read_thread: std.Thread,
    read_thread_pipe: posix.fd_t,
    read_thread_fd: posix.fd_t,
    termios_timer: xev.Timer,
    termios_timer_c: xev.Completion = .{},
    termios_timer_running: bool = true,
    termios_mode: ptypkg.Mode = .{},
    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = posix.system.close(self.read_thread_pipe);
        self.write_pool.deinit(alloc);
        if (self.process) |*p| p.deinit();
        self.write_stream.deinit();
        self.termios_timer.deinit();
    }
};
pub const Config = struct {
    command: ?configpkg.Command = null,
    env: EnvMap,
    env_override: configpkg.RepeatableStringMap = .{},
    shell_integration: configpkg.Config.ShellIntegration = .detect,
    shell_integration_features: configpkg.Config.ShellIntegrationFeatures = .{},
    cursor_blink: ?bool = null,
    working_directory: ?[]const u8 = null,
    resources_dir: ?[]const u8,
    term: []const u8,
    rt_pre_exec_info: Command.RtPreExecInfo,
    rt_post_fork_info: Command.RtPostForkInfo,
};
const Subprocess = struct {
    const c = @import("posix_c");
    arena: std.heap.ArenaAllocator,
    cwd: ?[:0]const u8,
    env: ?EnvMap,
    args: []const [:0]const u8,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
    pty: ?Pty = null,
    process: ?Process = null,
    rt_pre_exec_info: Command.RtPreExecInfo,
    rt_post_fork_info: Command.RtPostForkInfo,
    const Process = union(enum) {
        fork_exec: Command,
        flatpak: FlatpakHostCommand,
    };
    const ArgsFormatter = struct {
        args: []const [:0]const u8,
        pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            for (this.args, 0..) |a, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("`{s}`", .{a});
            }
        }
    };
    pub fn init(gpa: Allocator, cfg: Config) !Subprocess {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        var env = cfg.env;
        if (cfg.resources_dir) |dir| {
            log.info("found Wasp resources dir: {s}", .{dir});
            try env.put("WASP_RESOURCES_DIR", dir);
        }
        if (cfg.resources_dir) |base| {
            try env.put("TERM", cfg.term);
            try env.put("COLORTERM", "truecolor");
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const dir = try std.fmt.bufPrint(&buf, "{s}/terminfo", .{
                std.fs.path.dirname(base) orelse unreachable,
            });
            try env.put("TERMINFO", dir);
        } else {
            if (comptime builtin.target.os.tag.isDarwin()) {
                log.warn("wasp terminfo not found, using xterm-256color", .{});
                log.warn("the terminfo SHOULD exist on macos, please ensure", .{});
                log.warn("you're using a valid app bundle.", .{});
            }
            try env.put("TERM", "xterm-256color");
            try env.put("COLORTERM", "truecolor");
        }
        wasp_path: {
            if ((comptime build_config.flatpak) and
                internal_os.isFlatpak())
            {
                break :wasp_path;
            }
            var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const exe_bin_path = exe_buf[0 .. std.process.executablePath(
                global.io(),
                &exe_buf,
            ) catch |err| {
                log.warn("failed to get wasp exe path err={}", .{err});
                break :wasp_path;
            }];
            const exe_dir = std.fs.path.dirname(exe_bin_path) orelse break :wasp_path;
            log.debug("appending wasp bin to path dir={s}", .{exe_dir});
            try env.put("WASP_BIN_DIR", exe_dir);
            if (env.get("PATH")) |path| {
                var it = std.mem.tokenizeScalar(u8, path, std.fs.path.delimiter);
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry, exe_dir)) break :wasp_path;
                }
                try env.put(
                    "PATH",
                    try appendEnv(alloc, path, exe_dir),
                );
            } else {
                try env.put("PATH", exe_dir);
            }
        }
        if (comptime builtin.target.os.tag.isDarwin()) darwin: {
            const resources_dir = cfg.resources_dir orelse break :darwin;
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const xdg_data_dir_key = "XDG_DATA_DIRS";
            if (std.fmt.bufPrint(&buf, "{s}/..", .{resources_dir})) |data_dir| {
                try env.put(
                    xdg_data_dir_key,
                    try appendEnv(
                        alloc,
                        env.get(xdg_data_dir_key) orelse "/usr/local/share:/usr/share",
                        data_dir,
                    ),
                );
            } else |err| {
                log.warn("error building {s}; err={}", .{ xdg_data_dir_key, err });
            }
            const manpath_key = "MANPATH";
            if (std.fmt.bufPrint(&buf, "{s}/../man", .{resources_dir})) |man_dir| {
                try env.put(
                    manpath_key,
                    try appendEnvAlways(
                        alloc,
                        env.get(manpath_key) orelse "",
                        man_dir,
                    ),
                );
            } else |err| {
                log.warn("error building {s}; man pages may not be available; err={}", .{ manpath_key, err });
            }
        }
        try env.put("TERM_PROGRAM", "wasp");
        try env.put("TERM_PROGRAM_VERSION", build_config.version_string);
        _ = env.orderedRemove("VTE_VERSION");
        const shell_command: configpkg.Command = shell: {
            const default_shell_command: configpkg.Command =
                cfg.command orelse .{ .shell = switch (builtin.os.tag) {
                    .windows => "cmd.exe",
                    else => "sh",
                } };
            try shell_integration.setupFeatures(
                &env,
                cfg.shell_integration_features,
                cfg.cursor_blink orelse true,
            );
            const force: ?shell_integration.Shell = switch (cfg.shell_integration) {
                .none => {
                    log.info("shell integration disabled by configuration", .{});
                    break :shell default_shell_command;
                },
                .detect => null,
                .bash => .bash,
                .elvish => .elvish,
                .fish => .fish,
                .nushell => .nushell,
                .zsh => .zsh,
            };
            const dir = cfg.resources_dir orelse {
                log.warn("no resources dir set, shell integration disabled", .{});
                break :shell default_shell_command;
            };
            const integration = try shell_integration.setup(
                alloc,
                dir,
                default_shell_command,
                &env,
                force,
            ) orelse {
                log.warn("shell could not be detected, no automatic shell integration will be injected", .{});
                break :shell default_shell_command;
            };
            log.info(
                "shell integration automatically injected shell={}",
                .{integration.shell},
            );
            break :shell integration.command;
        };
        {
            var it = cfg.env_override.iterator();
            while (it.next()) |entry| try env.put(
                entry.key_ptr.*,
                entry.value_ptr.*,
            );
        }
        const args: []const [:0]const u8 = execCommand(
            alloc,
            shell_command,
            internal_os.passwd,
        ) catch |err| switch (err) {
            error.OutOfMemory => oom: {
                log.warn("failed to allocate space for command args, falling back to basic shell", .{});
                break :oom comptime switch (builtin.os.tag) {
                    .windows => &.{"cmd.exe"},
                    else => &.{"/bin/sh"},
                };
            },
            error.SystemError => return err,
        };
        const cwd: ?[:0]u8 = if (cfg.working_directory) |cwd|
            try alloc.dupeZ(u8, cwd)
        else
            null;
        if (cwd) |pwd| try env.put("PWD", pwd);
        return .{
            .arena = arena,
            .env = env,
            .cwd = cwd,
            .args = args,
            .rt_pre_exec_info = cfg.rt_pre_exec_info,
            .rt_post_fork_info = cfg.rt_post_fork_info,
            .grid_size = .{},
            .screen_size = .{ .width = 1, .height = 1 },
        };
    }
    pub fn deinit(self: *Subprocess) void {
        self.stop();
        if (self.pty) |*pty| pty.deinit();
        if (self.env) |*env| env.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn start(self: *Subprocess, alloc: Allocator) !struct {
        read: Pty.Fd,
        write: Pty.Fd,
    } {
        assert(self.pty == null and self.process == null);
        var in_child: bool = false;
        var pty = try Pty.open(.{
            .ws_row = @intCast(self.grid_size.rows),
            .ws_col = @intCast(self.grid_size.columns),
            .ws_xpixel = @intCast(self.screen_size.width),
            .ws_ypixel = @intCast(self.screen_size.height),
        });
        self.pty = pty;
        errdefer if (!in_child) {
            if (comptime builtin.os.tag != .windows) {
                _ = posix.system.close(pty.slave);
            }
            pty.deinit();
            self.pty = null;
        };
        defer if (!in_child and self.process != null) {
            if (comptime builtin.os.tag != .windows) {
                _ = posix.system.close(pty.slave);
            }
            if (self.env) |*env| {
                env.deinit();
                self.env = null;
            }
        };
        log.debug("starting command command={f}", .{ArgsFormatter{ .args = self.args }});
        const cwd: ?[:0]const u8 = if (self.cwd) |proposed| cwd: {
            if ((comptime build_config.flatpak) and internal_os.isFlatpak()) {
                log.info("flatpak detected, will use host command to verify cwd access", .{});
                const dev_null = try std.Io.Dir.cwd().openFile(
                    global.io(),
                    "/dev/null",
                    .{ .mode = .read_write },
                );
                defer dev_null.close(global.io());
                var cmd: internal_os.FlatpakHostCommand = .{
                    .argv = &[_][]const u8{
                        "/bin/sh",
                        "-c",
                        ":",
                    },
                    .cwd = proposed,
                    .stdin = dev_null.handle,
                    .stdout = dev_null.handle,
                    .stderr = dev_null.handle,
                };
                _ = cmd.spawn(alloc) catch |err| {
                    log.warn("cannot spawn command at cwd, ignoring: {}", .{err});
                    break :cwd null;
                };
                _ = try cmd.wait();
                break :cwd proposed;
            }
            if (std.Io.Dir.cwd().access(global.io(), proposed, .{})) {
                break :cwd proposed;
            } else |err| {
                log.warn("cannot access cwd, ignoring: {}", .{err});
                break :cwd null;
            }
        } else null;
        if (internal_os.isFlatpak()) flatpak: {
            if (comptime !build_config.flatpak) {
                log.warn("flatpak detected, but flatpak support not built-in", .{});
                break :flatpak;
            }
            self.process = .{ .flatpak = .{
                .argv = self.args,
                .cwd = cwd,
                .env = if (self.env) |*env| env else null,
                .stdin = pty.slave,
                .stdout = pty.slave,
                .stderr = pty.slave,
            } };
            var cmd = &self.process.?.flatpak;
            const pid = try cmd.spawn(alloc);
            errdefer killCommandFlatpak(cmd);
            log.info("started subcommand on host via flatpak API path={s} pid={}", .{
                self.args[0],
                pid,
            });
            return .{
                .read = pty.master,
                .write = pty.master,
            };
        }
        var cmd: Command = .{
            .path = self.args[0],
            .args = self.args,
            .env = if (self.env) |*env| env else null,
            .cwd = cwd,
            .stdin = if (builtin.os.tag == .windows) null else .{
                .handle = pty.slave,
                .flags = .{ .nonblocking = false },
            },
            .stdout = if (builtin.os.tag == .windows) null else .{
                .handle = pty.slave,
                .flags = .{ .nonblocking = false },
            },
            .stderr = if (builtin.os.tag == .windows) null else .{
                .handle = pty.slave,
                .flags = .{ .nonblocking = false },
            },
            .pseudo_console = if (builtin.os.tag == .windows) pty.pseudo_console else {},
            .os_pre_exec = switch (comptime builtin.os.tag) {
                .windows => null,
                else => f: {
                    const f = struct {
                        fn callback(cmd: *Command) ?u8 {
                            const sp = cmd.getData(Subprocess) orelse unreachable;
                            sp.childPreExec() catch |err| log.err(
                                "error initializing child: {}",
                                .{err},
                            );
                            return null;
                        }
                    };
                    break :f f.callback;
                },
            },
            .rt_pre_exec = if (comptime @hasDecl(apprt.runtime, "pre_exec")) apprt.runtime.pre_exec.preExec else null,
            .rt_pre_exec_info = self.rt_pre_exec_info,
            .rt_post_fork = if (comptime @hasDecl(apprt.runtime, "post_fork")) apprt.runtime.post_fork.postFork else null,
            .rt_post_fork_info = self.rt_post_fork_info,
            .data = self,
        };
        cmd.start(alloc) catch |err| {
            const StartError = error{ExecFailedInChild} || @TypeOf(err);
            switch (@as(StartError, err)) {
                error.ExecFailedInChild => {
                    in_child = true;
                    return err;
                },
                else => return err,
            }
        };
        errdefer killCommand(&cmd) catch |err| {
            log.warn("error killing command during cleanup err={}", .{err});
        };
        log.info("started subcommand path={s} pid={?}", .{ self.args[0], cmd.pid });
        self.process = .{ .fork_exec = cmd };
        return switch (builtin.os.tag) {
            .windows => .{
                .read = pty.out_pipe,
                .write = pty.in_pipe,
            },
            else => .{
                .read = pty.master,
                .write = pty.master,
            },
        };
    }
    fn childPreExec(self: *Subprocess) !void {
        try self.pty.?.childPreExec();
    }
    pub fn externalExit(self: *Subprocess) void {
        self.process = null;
    }
    pub fn stop(self: *Subprocess) void {
        switch (self.process orelse return) {
            .fork_exec => |*cmd| {
                killCommand(cmd) catch |err|
                    log.err("error sending SIGHUP to command, may hang: {}", .{err});
            },
            .flatpak => |*cmd| if (comptime build_config.flatpak) {
                killCommandFlatpak(cmd) catch |err|
                    log.err("error sending SIGHUP to command, may hang: {}", .{err});
                _ = cmd.wait() catch |err|
                    log.err("error waiting for command to exit: {}", .{err});
            },
        }
        self.process = null;
    }
    pub fn resize(
        self: *Subprocess,
        grid_size: renderer.GridSize,
        screen_size: renderer.ScreenSize,
    ) !void {
        self.grid_size = grid_size;
        self.screen_size = screen_size;
        if (self.pty) |*pty| {
            try pty.setSize(.{
                .ws_row = std.math.cast(u16, grid_size.rows) orelse std.math.maxInt(u16),
                .ws_col = std.math.cast(u16, grid_size.columns) orelse std.math.maxInt(u16),
                .ws_xpixel = std.math.cast(u16, screen_size.width) orelse std.math.maxInt(u16),
                .ws_ypixel = std.math.cast(u16, screen_size.height) orelse std.math.maxInt(u16),
            });
        }
    }
    fn killCommand(command: *Command) !void {
        if (command.pid) |pid| {
            switch (builtin.os.tag) {
                .windows => {
                    if (windows.exp.kernel32.TerminateProcess(pid, 0) == windows.FALSE) {
                        return windows.unexpectedError(windows.GetLastError());
                    }
                    _ = try command.wait(false);
                },
                else => try killPid(pid),
            }
        }
    }
    fn killPid(pid: c.pid_t) !void {
        const pgid = getpgid(pid) orelse return;
        while (true) {
            switch (posix.errno(c.killpg(pgid, c.SIGHUP))) {
                .SUCCESS => log.debug("process group killed pgid={}", .{pgid}),
                else => |err| killpg: {
                    if ((comptime builtin.target.os.tag.isDarwin()) and
                        err == .PERM)
                    {
                        log.debug("killpg failed with EPERM, expected on Darwin and ignoring", .{});
                        break :killpg;
                    }
                    log.warn("error killing process group pgid={} err={}", .{ pgid, err });
                    return error.KillFailed;
                },
            }
            const res_pid = while (true) {
                const rc = posix.system.waitpid(pid, null, std.c.W.NOHANG);
                if (posix.errno(rc) == .INTR) continue;
                break rc;
            };
            log.debug("waitpid result={}", .{res_pid});
            if (res_pid != 0) break;
            try std.Io.sleep(global.io(), .fromMilliseconds(10), .awake);
        }
    }
    fn getpgid(pid: c.pid_t) ?c.pid_t {
        const my_pgid = c.getpgid(0);
        while (true) {
            const pgid = c.getpgid(pid);
            if (pgid == my_pgid) {
                log.warn("pgid is our own, retrying", .{});
                std.Io.sleep(global.io(), .fromMilliseconds(10), .awake) catch {};
                continue;
            }
            if (pgid == 0) return null;
            if (pgid == c.ESRCH) return null;
            if (pgid < 0) {
                log.warn("error getting pgid for kill", .{});
                return null;
            }
            return pgid;
        }
    }
    fn killCommandFlatpak(command: *FlatpakHostCommand) !void {
        try command.signal(c.SIGHUP, true);
    }
    pub fn getProcessInfo(self: *Subprocess, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
        const pty = &(self.pty orelse return null);
        return pty.getProcessInfo(info);
    }
};
pub const ReadThread = struct {
    const buffer_count = 4;
    const buffer_capacity = 64 * 1024;
    const bridge_threshold = 1024;
    const bridge_spin_max = 16;
    const bridge_poll_timeout_ms = 1;
    const gather_budget_ns = 3 * std.time.ns_per_ms;
    const Pipeline = struct {
        mutex: std.Io.Mutex = .init,
        batch_ready: std.Io.Condition = .init,
        slot_free: std.Io.Condition = .init,
        lens: [buffer_count]usize = @splat(0),
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,
        bridging: bool = false,
        idle_read_fd: posix.fd_t = -1,
        idle_write_fd: posix.fd_t = -1,
        done: bool = false,
        bufs: [buffer_count][buffer_capacity]u8 = undefined,
    };
    fn threadMainPosix(fd: posix.fd_t, io: *termio.Termio, quit: posix.fd_t) void {
        defer _ = posix.system.close(quit);
        if (builtin.os.tag.isDarwin()) {
            internal_os.macos.pthread_setname_np(&"io-reader".*);
            setQosClass();
        }
        crash.sentry.thread_state = .{
            .type = .io,
            .surface = io.surface_mailbox.surface,
        };
        defer crash.sentry.thread_state = null;
        if (!setNonblock(fd)) {
            log.err("read thread exiting, pty fd must be non-blocking", .{});
            return;
        }
        var pipeline: Pipeline = .{};
        if (compat_fd.pipe2(.{
            .CLOEXEC = true,
            .NONBLOCK = true,
        })) |fds| {
            pipeline.idle_read_fd = fds[0];
            pipeline.idle_write_fd = fds[1];
        } else |err| {
            log.warn("read thread failed to create idle pipe err={}", .{err});
        }
        defer if (pipeline.idle_read_fd >= 0) {
            compat_fd.close(pipeline.idle_read_fd);
            compat_fd.close(pipeline.idle_write_fd);
        };
        const gather_thread = std.Thread.spawn(
            .{},
            gatherMainPosix,
            .{ fd, quit, &pipeline },
        ) catch |err| {
            log.err("read thread exiting, failed to spawn gather thread err={}", .{err});
            return;
        };
        defer gather_thread.join();
        if (comptime !builtin.os.tag.isDarwin()) {
            gather_thread.setName(global.io(), "io-gather") catch {};
        }
        while (true) {
            const batch: []const u8 = batch: {
                pipeline.mutex.lockUncancelable(global.io());
                defer pipeline.mutex.unlock(global.io());
                while (pipeline.count == 0) {
                    if (pipeline.done) return;
                    pipeline.batch_ready.waitUncancelable(global.io(), &pipeline.mutex);
                }
                const slot = pipeline.tail;
                break :batch pipeline.bufs[slot][0..pipeline.lens[slot]];
            };
            io.processOutput(batch);
            {
                pipeline.mutex.lockUncancelable(global.io());
                pipeline.tail = (pipeline.tail + 1) % buffer_count;
                pipeline.count -= 1;
                const wake = pipeline.count == 0 and
                    pipeline.bridging and
                    pipeline.idle_write_fd >= 0;
                pipeline.mutex.unlock(global.io());
                pipeline.slot_free.signal(global.io());
                if (wake) {
                    _ = posix.system.write(pipeline.idle_write_fd, "i", 1);
                }
            }
            io.renderer_state.yieldToDemand(global.io());
        }
    }
    fn gatherMainPosix(fd: posix.fd_t, quit: posix.fd_t, pipeline: *Pipeline) void {
        if (builtin.os.tag.isDarwin()) {
            internal_os.macos.pthread_setname_np(&"io-gather".*);
            setQosClass();
        }
        defer {
            pipeline.mutex.lockUncancelable(global.io());
            pipeline.done = true;
            pipeline.mutex.unlock(global.io());
            pipeline.batch_ready.signal(global.io());
        }
        var pollfds: [3]posix.pollfd = .{
            .{ .fd = fd, .events = posix.POLL.IN, .revents = undefined },
            .{ .fd = quit, .events = posix.POLL.IN, .revents = undefined },
            .{ .fd = pipeline.idle_read_fd, .events = posix.POLL.IN, .revents = undefined },
        };
        while (true) {
            const buf: *[buffer_capacity]u8 = buf: {
                pipeline.mutex.lockUncancelable(global.io());
                defer pipeline.mutex.unlock(global.io());
                while (pipeline.count == buffer_count) {
                    pipeline.slot_free.waitUncancelable(global.io(), &pipeline.mutex);
                }
                break :buf &pipeline.bufs[pipeline.head];
            };
            var total: usize = 0;
            var bridge_start: ?std.Io.Timestamp = null;
            var spins: usize = 0;
            var fatal = false;
            gather: while (total < buffer_capacity) {
                const n = posix.read(
                    fd,
                    buf[total..],
                ) catch |err| switch (err) {
                    error.WouldBlock => {
                        if (total < bridge_threshold) break :gather;
                        if (spins < bridge_spin_max) {
                            spins += 1;
                            continue :gather;
                        }
                        const now = std.Io.Timestamp.now(global.io(), .awake);
                        if (bridge_start) |start| {
                            if (start.durationTo(now).toNanoseconds() >= gather_budget_ns)
                                break :gather;
                        } else bridge_start = now;
                        {
                            pipeline.mutex.lockUncancelable(global.io());
                            defer pipeline.mutex.unlock(global.io());
                            if (pipeline.count == 0) break :gather;
                            pipeline.bridging = true;
                        }
                        const r = posix.poll(
                            &pollfds,
                            bridge_poll_timeout_ms,
                        ) catch |poll_err| {
                            clearBridging(pipeline);
                            log.warn("bridge poll failed err={}", .{poll_err});
                            break :gather;
                        };
                        clearBridging(pipeline);
                        if (r == 0) break :gather;
                        if (pollfds[1].revents & posix.POLL.IN != 0) {
                            log.info("read thread got quit signal", .{});
                            fatal = true;
                            break :gather;
                        }
                        if (pollfds[2].revents & posix.POLL.IN != 0) {
                            var trash: [16]u8 = undefined;
                            while (true) {
                                const drained = posix.read(
                                    pipeline.idle_read_fd,
                                    &trash,
                                ) catch break;
                                if (drained < trash.len) break;
                            }
                            break :gather;
                        }
                        if (pollfds[0].revents & posix.POLL.IN == 0)
                            break :gather;
                        continue :gather;
                    },
                    error.NotOpenForReading,
                    error.InputOutput,
                    => {
                        log.info("io gather exiting", .{});
                        fatal = true;
                        break :gather;
                    },
                    else => {
                        log.err("io gather error err={}", .{err});
                        unreachable;
                    },
                };
                if (n == 0) break :gather;
                total += n;
                spins = 0;
            }
            if (total > 0) {
                pipeline.mutex.lockUncancelable(global.io());
                pipeline.lens[pipeline.head] = total;
                pipeline.head = (pipeline.head + 1) % buffer_count;
                pipeline.count += 1;
                pipeline.mutex.unlock(global.io());
                pipeline.batch_ready.signal(global.io());
            }
            if (fatal) return;
            if (total == buffer_capacity) continue;
            _ = posix.poll(pollfds[0..2], -1) catch |err| {
                log.warn("poll failed on read thread, exiting early err={}", .{err});
                return;
            };
            if (pollfds[1].revents & posix.POLL.IN != 0) {
                log.info("read thread got quit signal", .{});
                return;
            }
            if (pollfds[0].revents & posix.POLL.HUP != 0) {
                log.info("pty fd closed, read thread exiting", .{});
                return;
            }
        }
    }
    fn clearBridging(pipeline: *Pipeline) void {
        pipeline.mutex.lockUncancelable(global.io());
        defer pipeline.mutex.unlock(global.io());
        pipeline.bridging = false;
    }
    fn setQosClass() void {
        internal_os.macos.setQosClass(.user_initiated) catch |err| {
            log.warn("error setting QoS class err={}", .{err});
        };
    }
    fn setNonblock(fd: posix.fd_t) bool {
        const flags = posix.system.fcntl(fd, posix.F.GETFL);
        if (flags == -1) {
            log.warn("read thread failed to get flags err=E{s}", .{@tagName(posix.errno(-1))});
            return false;
        }
        switch (posix.errno(posix.system.fcntl(
            fd,
            posix.F.SETFL,
            flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })),
        ))) {
            .SUCCESS => {},
            else => |e| {
                log.warn("read thread failed to set flags err=E{s}", .{@tagName(e)});
                return false;
            },
        }
        return true;
    }
    fn threadMainWindows(fd: posix.fd_t, io: *termio.Termio, quit: posix.fd_t) void {
        defer _ = posix.system.close(quit);
        crash.sentry.thread_state = .{
            .type = .io,
            .surface = io.surface_mailbox.surface,
        };
        defer crash.sentry.thread_state = null;
        var buf: [1024]u8 = undefined;
        while (true) {
            while (true) {
                var n: windows.DWORD = 0;
                if (windows.exp.kernel32.ReadFile(fd, &buf, buf.len, &n, null) == windows.FALSE) {
                    const err = windows.GetLastError();
                    switch (err) {
                        .OPERATION_ABORTED => break,
                        else => {
                            log.err("io reader error err={}", .{err});
                            unreachable;
                        },
                    }
                }
                @call(.always_inline, termio.Termio.processOutput, .{ io, buf[0..n] });
                io.renderer_state.yieldToDemand(global.io());
            }
            var quit_bytes: windows.DWORD = 0;
            if (windows.exp.kernel32.PeekNamedPipe(quit, null, 0, null, &quit_bytes, null) == windows.FALSE) {
                const err = windows.GetLastError();
                log.err("quit pipe reader error err={}", .{err});
                unreachable;
            }
            if (quit_bytes > 0) {
                log.info("read thread got quit signal", .{});
                return;
            }
        }
    }
};
fn execCommand(
    alloc: Allocator,
    command: configpkg.Command,
    comptime passwdpkg: type,
) (Allocator.Error || error{SystemError})![]const [:0]const u8 {
    if (comptime builtin.target.os.tag.isDarwin()) darwin: {
        const passwd = passwdpkg.get(alloc) catch |err| {
            log.warn("failed to read passwd, not using a login shell err={}", .{err});
            break :darwin;
        };
        const username = passwd.name orelse {
            log.warn("failed to get username, not using a login shell", .{});
            break :darwin;
        };
        const hush = if (passwd.home) |home| hush: {
            var dir = std.Io.Dir.openDirAbsolute(global.io(), home, .{}) catch |err| {
                log.warn(
                    "failed to open home dir, not checking for hushlogin err={}",
                    .{err},
                );
                break :hush false;
            };
            defer dir.close(global.io());
            break :hush if (dir.access(global.io(), ".hushlogin", .{})) true else |_| false;
        } else false;
        var args: std.ArrayList([:0]const u8) = try .initCapacity(
            alloc,
            9,
        );
        defer args.deinit(alloc);
        try args.append(alloc, "/usr/bin/login");
        if (hush) try args.append(alloc, "-q");
        try args.append(alloc, "-flp");
        try args.append(alloc, username);
        switch (command) {
            .direct => |v| try args.appendSlice(alloc, v),
            .shell => |v| {
                const cmd = try std.fmt.allocPrintSentinel(
                    alloc,
                    "exec -l {s}",
                    .{v},
                    0,
                );
                try args.append(alloc, "/bin/bash");
                try args.append(alloc, "--noprofile");
                try args.append(alloc, "--norc");
                try args.append(alloc, "-c");
                try args.append(alloc, cmd);
            },
        }
        return try args.toOwnedSlice(alloc);
    }
    return switch (command) {
        .direct => (try command.clone(alloc)).direct,
        .shell => |v| shell: {
            var args: std.ArrayList([:0]const u8) = try .initCapacity(alloc, 4);
            defer args.deinit(alloc);
            if (comptime builtin.os.tag == .windows) {
                if (std.mem.indexOfAny(u8, v, " \t") == null) {
                    const argv0 = if (std.ascii.eqlIgnoreCase(v, "cmd.exe"))
                        global.environ().getAlloc(alloc, "COMSPEC") catch
                            try alloc.dupe(u8, v)
                    else
                        try alloc.dupe(u8, v);
                    try args.append(alloc, try alloc.dupeZ(u8, argv0));
                } else {
                    var it = std.mem.tokenizeAny(u8, v, " \t");
                    while (it.next()) |tok| {
                        try args.append(alloc, try alloc.dupeZ(u8, tok));
                    }
                }
                break :shell try args.toOwnedSlice(alloc);
            } else {
                try args.append(alloc, "/bin/sh");
                if (internal_os.isFlatpak()) try args.append(alloc, "-l");
                try args.append(alloc, "-c");
            }
            try args.append(alloc, v);
            break :shell try args.toOwnedSlice(alloc);
        },
    };
}
fn appendEnv(
    alloc: Allocator,
    current: []const u8,
    value: []const u8,
) Allocator.Error![]u8 {
    if (current.len == 0) return try alloc.dupe(u8, value);
    return try appendEnvAlways(alloc, current, value);
}
fn appendEnvAlways(
    alloc: Allocator,
    current: []const u8,
    value: []const u8,
) Allocator.Error![]u8 {
    return try std.fmt.allocPrint(alloc, "{s}{c}{s}", .{
        current,
        std.fs.path.delimiter,
        value,
    });
}
pub fn getProcessInfo(self: *Exec, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    return self.subprocess.getProcessInfo(info);
}
test "execCommand darwin: shell command" {
    if (comptime !builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try execCommand(alloc, .{ .shell = "foo bar baz" }, struct {
        fn get(_: Allocator) !PasswdEntry {
            return .{
                .name = "testuser",
            };
        }
    });
    try testing.expectEqual(8, result.len);
    try testing.expectEqualStrings(result[0], "/usr/bin/login");
    try testing.expectEqualStrings(result[1], "-flp");
    try testing.expectEqualStrings(result[2], "testuser");
    try testing.expectEqualStrings(result[3], "/bin/bash");
    try testing.expectEqualStrings(result[4], "--noprofile");
    try testing.expectEqualStrings(result[5], "--norc");
    try testing.expectEqualStrings(result[6], "-c");
    try testing.expectEqualStrings(result[7], "exec -l foo bar baz");
}
test "execCommand darwin: direct command" {
    if (comptime !builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try execCommand(alloc, .{ .direct = &.{
        "foo",
        "bar baz",
    } }, struct {
        fn get(_: Allocator) !PasswdEntry {
            return .{
                .name = "testuser",
            };
        }
    });
    try testing.expectEqual(5, result.len);
    try testing.expectEqualStrings(result[0], "/usr/bin/login");
    try testing.expectEqualStrings(result[1], "-flp");
    try testing.expectEqualStrings(result[2], "testuser");
    try testing.expectEqualStrings(result[3], "foo");
    try testing.expectEqualStrings(result[4], "bar baz");
}
test "execCommand: shell command, empty passwd" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try execCommand(
        alloc,
        .{ .shell = "foo bar baz" },
        struct {
            fn get(_: Allocator) !PasswdEntry {
                return .{};
            }
        },
    );
    try testing.expectEqual(3, result.len);
    try testing.expectEqualStrings(result[0], "/bin/sh");
    try testing.expectEqualStrings(result[1], "-c");
    try testing.expectEqualStrings(result[2], "foo bar baz");
}
test "execCommand: shell command, error passwd" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try execCommand(
        alloc,
        .{ .shell = "foo bar baz" },
        struct {
            fn get(_: Allocator) !PasswdEntry {
                return error.Fail;
            }
        },
    );
    try testing.expectEqual(3, result.len);
    try testing.expectEqualStrings(result[0], "/bin/sh");
    try testing.expectEqualStrings(result[1], "-c");
    try testing.expectEqualStrings(result[2], "foo bar baz");
}
test "execCommand: direct command, error passwd" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try execCommand(alloc, .{
        .direct = &.{
            "foo",
            "bar baz",
        },
    }, struct {
        fn get(_: Allocator) !PasswdEntry {
            return error.Fail;
        }
    });
    try testing.expectEqual(2, result.len);
    try testing.expectEqualStrings(result[0], "foo");
    try testing.expectEqualStrings(result[1], "bar baz");
}
test "execCommand: direct command, config freed" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var command_arena = ArenaAllocator.init(testing.allocator);
    const command_alloc = command_arena.allocator();
    const command = try (configpkg.Command{
        .direct = &.{
            "foo",
            "bar baz",
        },
    }).clone(command_alloc);
    const result = try execCommand(alloc, command, struct {
        fn get(_: Allocator) !PasswdEntry {
            return error.Fail;
        }
    });
    command_arena.deinit();
    try testing.expectEqual(2, result.len);
    try testing.expectEqualStrings(result[0], "foo");
    try testing.expectEqualStrings(result[1], "bar baz");
}
test "execCommand windows: bare cmd.exe resolves via COMSPEC" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try execCommand(alloc, .{ .shell = "cmd.exe" }, struct {
        fn get(_: Allocator) !PasswdEntry {
            return .{};
        }
    });
    try testing.expectEqual(1, result.len);
    const expected = testing.environ.getAlloc(alloc, "COMSPEC") catch
        try alloc.dupe(u8, "C:\\Windows\\System32\\cmd.exe");
    try testing.expectEqualStrings(expected, result[0]);
}
test "execCommand windows: bare non-cmd shell is passed through" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try execCommand(alloc, .{ .shell = "pwsh.exe" }, struct {
        fn get(_: Allocator) !PasswdEntry {
            return .{};
        }
    });
    try testing.expectEqual(1, result.len);
    try testing.expectEqualStrings("pwsh.exe", result[0]);
}
test "execCommand windows: shell with args is split on whitespace" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try execCommand(alloc, .{ .shell = "wsl ~" }, struct {
        fn get(_: Allocator) !PasswdEntry {
            return .{};
        }
    });
    try testing.expectEqual(2, result.len);
    try testing.expectEqualStrings("wsl", result[0]);
    try testing.expectEqualStrings("~", result[1]);
}
test "execCommand windows: direct command is passed through unchanged" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try execCommand(alloc, .{ .direct = &.{
        "C:\\tools\\foo.exe",
        "arg with spaces",
    } }, struct {
        fn get(_: Allocator) !PasswdEntry {
            return .{};
        }
    });
    try testing.expectEqual(2, result.len);
    try testing.expectEqualStrings("C:\\tools\\foo.exe", result[0]);
    try testing.expectEqualStrings("arg with spaces", result[1]);
}
