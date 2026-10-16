const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const cli_args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const Action = @import("wasp.zig").Action;
const DiskCache = @import("ssh_cache.zig").DiskCache;
const internal_os = @import("../os/root.zig");
const terminfopkg = @import("../terminfo/root.zig");
const global = @import("../global.zig");
const log = std.log.scoped(.ssh);
const usage =
    \\Usage: wasp +ssh [flags] [--] <ssh args...>
    \\
    \\Flags:
    \\  --forward-env[=bool]  Enable TERM / SendEnv forwarding. Default: true.
    \\  --terminfo[=bool]     Install Wasp terminfo on first connect. Default: true.
    \\  --cache[=bool]        Use the terminfo install cache. Default: true.
    \\  --ssh=<path>          Path to the ssh binary. Default: first `ssh` on PATH.
    \\  --verbose             Print +ssh status lines to stderr.
    \\  --help                Show full help.
    \\
    \\ssh flags and the destination go after +ssh's own flags (or after `--`).
    \\
;
pub const Options = struct {
    _arena: ?ArenaAllocator = null,
    @"forward-env": bool = true,
    terminfo: bool = true,
    cache: bool = true,
    ssh: []const u8 = "ssh",
    verbose: bool = false,
    _ssh_args: std.ArrayList([]const u8) = .empty,
    _diagnostics: diagnostics.DiagnosticList = .{},
    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }
    pub fn help(_: Options) !void {
        return Action.help_error;
    }
    pub fn parseManuallyHook(
        self: *Options,
        alloc: Allocator,
        arg: []const u8,
        iter: anytype,
    ) Allocator.Error!bool {
        if (std.mem.eql(u8, arg, "--")) {
            while (iter.next()) |rest| {
                try self._ssh_args.append(alloc, try alloc.dupe(u8, rest));
            }
            return false;
        }
        if (!std.mem.startsWith(u8, arg, "--")) {
            try self._ssh_args.append(alloc, try alloc.dupe(u8, arg));
            while (iter.next()) |rest| {
                try self._ssh_args.append(alloc, try alloc.dupe(u8, rest));
            }
            return false;
        }
        return true;
    }
};
pub fn run(alloc_gpa: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();
    {
        var iter = try cli_args.argsIterator(alloc_gpa, global.args());
        defer iter.deinit();
        try cli_args.parse(Options, alloc_gpa, &opts, &iter);
    }
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file: std.Io.File = .stderr();
    var stderr_writer = stderr_file.writer(global.io(), &stderr_buffer);
    const stderr = &stderr_writer.interface;
    if (!opts._diagnostics.empty()) {
        for (opts._diagnostics.items()) |diag| {
            if (diag.key.len > 0) {
                stderr.print(
                    "Error: unknown flag `--{s}`.\n",
                    .{diag.key},
                ) catch {};
            } else {
                stderr.print("Error: {s}\n", .{diag.message}) catch {};
            }
        }
        stderr.print("\n{s}", .{usage}) catch {};
        stderr.flush() catch {};
        return 2;
    }
    const result = runInner(alloc_gpa, &opts, stderr);
    stderr.flush() catch {};
    return result;
}
fn runInner(
    gpa: Allocator,
    opts: *const Options,
    stderr: *std.Io.Writer,
) !u8 {
    var arena = ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    if (opts._ssh_args.items.len == 0) {
        try stderr.print("Error: no ssh arguments provided.\n\n{s}", .{usage});
        return 2;
    }
    const session: struct {
        term: []const u8,
        to_cache: ?struct { cache: DiskCache, dest: []const u8 } = null,
    } = session: {
        if (!opts.terminfo) break :session .{ .term = "xterm-256color" };
        const dest = resolveDestination(alloc, opts.ssh, opts._ssh_args.items) orelse {
            warnPrint(stderr, "could not resolve ssh destination; skipping terminfo install", .{});
            break :session .{ .term = "xterm-256color" };
        };
        const cache: ?DiskCache = if (opts.cache) cache: {
            const path = DiskCache.defaultPath(alloc, "wasp") catch |err| {
                warnPrint(stderr, "wasp terminfo cache unavailable: {t}", .{err});
                break :session .{ .term = "xterm-256color" };
            };
            break :cache .{ .path = path };
        } else null;
        if (cache) |c| {
            const cached = c.contains(
                alloc,
                dest,
                terminfopkg.version,
            ) catch |err| cached: {
                if (DiskCache.isFailure(err)) warnPrint(
                    stderr,
                    "unable to read the cache '{s}': {t}",
                    .{ c.path, err },
                );
                break :cached false;
            };
            if (cached) {
                verbosePrint(opts, stderr, "dest: {s} (cached, skipping install)", .{dest});
                break :session .{ .term = "xterm-wasp" };
            } else {
                verbosePrint(opts, stderr, "dest: {s} (not cached, will install)", .{dest});
            }
        } else {
            verbosePrint(opts, stderr, "dest: {s} (cache disabled, will install)", .{dest});
        }
        stderr.print("Setting up xterm-wasp terminfo on {s}...\n", .{dest}) catch {};
        stderr.flush() catch {};
        installRemoteTerminfo(alloc, opts, stderr) catch |err| {
            warnPrint(stderr, "failed to install terminfo: {t}", .{err});
            break :session .{ .term = "xterm-256color" };
        };
        break :session .{
            .term = "xterm-wasp",
            .to_cache = if (cache) |c| .{ .cache = c, .dest = dest } else null,
        };
    };
    const env_opts: []const []const u8 = if (opts.@"forward-env") env_opts: {
        const set_term = try std.fmt.allocPrint(
            alloc,
            "SetEnv=TERM={s}",
            .{session.term},
        );
        break :env_opts &.{
            "-o", set_term,
            "-o", "SendEnv=COLORTERM",
            "-o", "SendEnv=TERM_PROGRAM",
            "-o", "SendEnv=TERM_PROGRAM_VERSION",
        };
    } else &.{};
    const argv = try std.mem.concat(alloc, []const u8, &.{
        &.{opts.ssh},
        env_opts,
        opts._ssh_args.items,
    });
    verbosePrint(opts, stderr, "exec: {f}", .{Joined{ .items = argv }});
    const exit_code = childExec(argv) catch |err| {
        try stderr.print("Error: failed to run {s}: {t}\n", .{ argv[0], err });
        return 1;
    };
    verbosePrint(opts, stderr, "exit: {d}", .{exit_code});
    if (exit_code == 0) if (session.to_cache) |entry| {
        if (entry.cache.add(
            alloc,
            entry.dest,
            terminfopkg.version,
            std.Io.Timestamp.now(global.io(), .real).toSeconds(),
        )) |_| {
            verbosePrint(opts, stderr, "cache: wrote {s}", .{entry.dest});
        } else |err| {
            if (DiskCache.isFailure(err)) {
                warnPrint(
                    stderr,
                    "unable to add '{s}' to the cache '{s}': {t}",
                    .{ entry.dest, entry.cache.path, err },
                );
            } else {
                verbosePrint(
                    opts,
                    stderr,
                    "cache: skipped {s}: {t}",
                    .{ entry.dest, err },
                );
            }
        }
    };
    return exit_code;
}
fn verbosePrint(
    opts: *const Options,
    stderr: *std.Io.Writer,
    comptime fmt: []const u8,
    args: anytype,
) void {
    log.debug(fmt, args);
    if (!opts.verbose) return;
    stderr.print("+ssh: " ++ fmt ++ "\n", args) catch return;
    stderr.flush() catch return;
}
fn warnPrint(
    stderr: *std.Io.Writer,
    comptime fmt: []const u8,
    args: anytype,
) void {
    log.warn(fmt, args);
    stderr.print("Warning: " ++ fmt ++ "\n", args) catch return;
    stderr.flush() catch return;
}
const Joined = struct {
    items: []const []const u8,
    pub fn format(self: Joined, writer: *std.Io.Writer) !void {
        for (self.items, 0..) |a, i| {
            if (i > 0) try writer.writeByte(' ');
            try writer.writeAll(a);
        }
    }
    test {
        const testing = std.testing;
        var buf: [128]u8 = undefined;
        {
            var w: std.Io.Writer = .fixed(&buf);
            try w.print("{f}", .{Joined{ .items = &.{} }});
            try testing.expectEqualStrings("", buf[0..w.end]);
        }
        {
            var w: std.Io.Writer = .fixed(&buf);
            try w.print("{f}", .{Joined{ .items = &.{"only"} }});
            try testing.expectEqualStrings("only", buf[0..w.end]);
        }
        {
            var w: std.Io.Writer = .fixed(&buf);
            try w.print("{f}", .{Joined{ .items = &.{ "a", "b", "c" } }});
            try testing.expectEqualStrings("a b c", buf[0..w.end]);
        }
    }
};
fn checkExit(term: std.process.Child.Term, label: []const u8) error{ChildFailed}!void {
    switch (term) {
        .exited => |rc| if (rc != 0) {
            log.warn("{s} exited with non-zero status: {d}", .{ label, rc });
            return error.ChildFailed;
        },
        else => {
            log.warn("{s} terminated abnormally: {}", .{ label, term });
            return error.ChildFailed;
        },
    }
}
fn resolveDestination(
    alloc: Allocator,
    ssh: []const u8,
    args: []const []const u8,
) ?[]const u8 {
    const argv = std.mem.concat(alloc, []const u8, &.{
        &.{ ssh, "-G" },
        args,
    }) catch return null;
    const result = std.process.run(
        alloc,
        global.io(),
        .{ .argv = argv },
    ) catch |err| {
        log.warn("ssh -G spawn failed: {}", .{err});
        return null;
    };
    checkExit(result.term, "ssh -G") catch return null;
    return parseDestination(alloc, result.stdout);
}
fn parseDestination(alloc: Allocator, stdout: []const u8) ?[]const u8 {
    var user: []const u8 = "";
    var host: []const u8 = "";
    var port: []const u8 = "";
    var it = std.mem.tokenizeScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const key = line[0..space];
        const value = line[space + 1 ..];
        if (std.mem.eql(u8, key, "user")) {
            user = value;
        } else if (std.mem.eql(u8, key, "hostname")) {
            host = value;
        } else if (std.mem.eql(u8, key, "port")) {
            port = value;
        }
        if (user.len > 0 and host.len > 0 and port.len > 0) break;
    }
    if (user.len == 0) {
        log.warn("ssh -G output missing user", .{});
        return null;
    }
    if (host.len == 0) {
        log.warn("ssh -G output missing hostname", .{});
        return null;
    }
    if (port.len == 0 or std.mem.eql(u8, port, "22")) {
        return std.fmt.allocPrint(alloc, "{s}@{s}", .{ user, host }) catch null;
    }
    if (std.mem.indexOfScalar(u8, host, ':') != null) {
        return std.fmt.allocPrint(alloc, "{s}@[{s}]:{s}", .{ user, host, port }) catch null;
    }
    return std.fmt.allocPrint(alloc, "{s}@{s}:{s}", .{ user, host, port }) catch null;
}
fn installRemoteTerminfo(
    alloc: Allocator,
    opts: *const Options,
    stderr: *std.Io.Writer,
) !void {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try terminfopkg.wasp.encode(&buf.writer);
    const terminfo = buf.written();
    const control_path = try internal_os.randomTmpPath(alloc, "wasp-ssh-");
    const control_path_opt = try std.fmt.allocPrint(
        alloc,
        "ControlPath={s}",
        .{control_path},
    );
    const remote_script = if (opts.verbose)
        \\command -v tic >/dev/null 2>&1 || exit 1
        \\mkdir -p ~/.terminfo 2>/dev/null && tic -x - && exit 0
        \\exit 1
    else
        \\command -v tic >/dev/null 2>&1 || exit 1
        \\mkdir -p ~/.terminfo 2>/dev/null && tic -x - 2>/dev/null && exit 0
        \\exit 1
    ;
    const argv = try std.mem.concat(alloc, []const u8, &.{
        &.{opts.ssh},
        &.{
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=no",
            "-o", control_path_opt,
        },
        opts._ssh_args.items,
        &.{remote_script},
    });
    verbosePrint(opts, stderr, "exec: {f}", .{Joined{ .items = argv }});
    var child = std.process.spawn(global.io(), .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = if (opts.verbose) .inherit else .ignore,
    }) catch |err| {
        log.warn("terminfo install spawn failed: {}", .{err});
        return error.InstallFailed;
    };
    if (child.stdin) |stdin| {
        stdin.writeStreamingAll(global.io(), terminfo) catch {};
        stdin.close(global.io());
        child.stdin = null;
    }
    const term = child.wait(global.io()) catch |err| {
        log.warn("terminfo install wait failed: {}", .{err});
        return error.InstallFailed;
    };
    checkExit(term, "terminfo install") catch return error.InstallFailed;
}
fn childExec(argv: []const []const u8) !u8 {
    var child = try std.process.spawn(global.io(), .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(global.io());
    return switch (term) {
        .exited => |rc| rc,
        .signal => |sig| @as(u8, 128) + @as(u8, @intCast(@min(@intFromEnum(sig), 127))),
        .stopped, .unknown => 1,
    };
}
fn parseTestArgs(alloc: Allocator, opts: *Options, line: []const u8) !void {
    var iter = try std.process.Args.IteratorGeneral(.{}).init(alloc, line);
    defer iter.deinit();
    try cli_args.parse(Options, alloc, opts, &iter);
}
test "parseManuallyHook: bare destination starts ssh args" {
    const testing = std.testing;
    var opts: Options = .{};
    defer opts.deinit();
    try parseTestArgs(testing.allocator, &opts, "--terminfo=false user@example.com");
    try testing.expectEqual(false, opts.terminfo);
    try testing.expectEqual(true, opts.@"forward-env");
    try testing.expectEqual(@as(usize, 1), opts._ssh_args.items.len);
    try testing.expectEqualStrings("user@example.com", opts._ssh_args.items[0]);
}
test "parseManuallyHook: short ssh flags pass through verbatim" {
    const testing = std.testing;
    var opts: Options = .{};
    defer opts.deinit();
    try parseTestArgs(testing.allocator, &opts, "-p 2222 user@example.com");
    try testing.expectEqual(@as(usize, 3), opts._ssh_args.items.len);
    try testing.expectEqualStrings("-p", opts._ssh_args.items[0]);
    try testing.expectEqualStrings("2222", opts._ssh_args.items[1]);
    try testing.expectEqualStrings("user@example.com", opts._ssh_args.items[2]);
}
test "parseManuallyHook: explicit -- separator" {
    const testing = std.testing;
    var opts: Options = .{};
    defer opts.deinit();
    try parseTestArgs(
        testing.allocator,
        &opts,
        "--verbose -- --some-rare-ssh-arg user@example.com",
    );
    try testing.expectEqual(true, opts.verbose);
    try testing.expectEqual(@as(usize, 2), opts._ssh_args.items.len);
    try testing.expectEqualStrings("--some-rare-ssh-arg", opts._ssh_args.items[0]);
    try testing.expectEqualStrings("user@example.com", opts._ssh_args.items[1]);
}
test "parseDestination: typical ssh -G output" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout =
        \\user alice
        \\hostname example.com
        \\port 22
        \\identityfile ~/.ssh/id_ed25519
        \\
    ;
    const result = parseDestination(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@example.com", result.?);
}
test "parseDestination: hostname before user" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout =
        \\hostname example.com
        \\port 22
        \\user alice
        \\
    ;
    const result = parseDestination(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@example.com", result.?);
}
test "parseDestination: missing hostname returns null" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout = "user alice\nport 22\n";
    try testing.expectEqual(@as(?[]const u8, null), parseDestination(arena.allocator(), stdout));
}
test "parseDestination: missing user returns null" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout = "hostname example.com\nport 22\n";
    try testing.expectEqual(@as(?[]const u8, null), parseDestination(arena.allocator(), stdout));
}
test "parseDestination: empty input returns null" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(?[]const u8, null), parseDestination(arena.allocator(), ""));
}
test "parseDestination: IPv6 hostname" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout = "user alice\nhostname ::1\n";
    const result = parseDestination(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@::1", result.?);
}
test "parseDestination: non-default port" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout =
        \\user alice
        \\hostname example.com
        \\port 2222
        \\
    ;
    const result = parseDestination(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@example.com:2222", result.?);
}
test "parseDestination: port before hostname" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout = "port 2222\nuser alice\nhostname example.com\n";
    const result = parseDestination(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@example.com:2222", result.?);
}
test "parseDestination: IPv6 hostname with non-default port" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stdout = "user alice\nhostname ::1\nport 2222\n";
    const result = parseDestination(arena.allocator(), stdout);
    try testing.expectEqualStrings("alice@[::1]:2222", result.?);
}
test "parseDestination: result is a valid cache key" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const outputs = [_][]const u8{
        "user alice\nhostname example.com\nport 22\n",
        "user alice\nhostname example.com\nport 2222\n",
        "user alice\nhostname 2001:db8::1\nport 22\n",
        "user alice\nhostname 2001:db8::1\nport 2222\n",
    };
    for (outputs) |stdout| {
        const result = parseDestination(arena.allocator(), stdout).?;
        try testing.expect(DiskCache.isValidCacheKey(result));
    }
}
