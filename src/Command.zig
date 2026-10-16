const Command = @This();
const std = @import("std");
const builtin = @import("builtin");
const configpkg = @import("config.zig");
const global = @import("global.zig");
const internal_os = @import("os/root.zig");
const windows = internal_os.windows;
const TempDir = internal_os.TempDir;
const mem = std.mem;
const linux = std.os.linux;
const posix = std.posix;
const debug = std.debug;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const File = std.Io.File;
const EnvMap = std.process.Environ.Map;
const apprt = @import("apprt.zig");
const PreExecFn = fn (*Command) ?u8;
pub const PostForkError = error{PostForkError};
const PostForkFn = fn (*Command) PostForkError!void;
path: [:0]const u8,
args: []const [:0]const u8,
env: ?*const EnvMap = null,
cwd: ?[:0]const u8 = null,
stdin: ?File = null,
stdout: ?File = null,
stderr: ?File = null,
os_pre_exec: ?*const PreExecFn,
rt_pre_exec: ?*const PreExecFn,
rt_pre_exec_info: RtPreExecInfo,
rt_post_fork: ?*const PostForkFn,
rt_post_fork_info: RtPostForkInfo,
pseudo_console: if (builtin.os.tag == .windows) ?windows.HPCON else void =
    if (builtin.os.tag == .windows) null else {},
data: ?*anyopaque = null,
pid: ?posix.system.pid_t = null,
pub const Exit = if (builtin.os.tag == .windows) union(enum) {
    Exited: u32,
} else union(enum) {
    Exited: u8,
    Signal: u32,
    Stopped: u32,
    Unknown: u32,
    pub fn init(status: u32) Exit {
        return if (posix.W.IFEXITED(status))
            Exit{ .Exited = posix.W.EXITSTATUS(status) }
        else if (posix.W.IFSIGNALED(status))
            Exit{ .Signal = @intFromEnum(posix.W.TERMSIG(status)) }
        else if (posix.W.IFSTOPPED(status))
            Exit{ .Stopped = @intFromEnum(posix.W.STOPSIG(status)) }
        else
            Exit{ .Unknown = status };
    }
};
pub const RtPreExecInfo = if (@hasDecl(apprt.runtime, "pre_exec")) apprt.runtime.pre_exec.PreExecInfo else struct {
    pub inline fn init(_: *const configpkg.Config) @This() {
        return .{};
    }
};
pub const RtPostForkInfo = if (@hasDecl(apprt.runtime, "post_fork")) apprt.runtime.post_fork.PostForkInfo else struct {
    pub inline fn init(_: *const configpkg.Config) @This() {
        return .{};
    }
};
pub fn start(self: *Command, alloc: Allocator) !void {
    var arena_allocator = std.heap.ArenaAllocator.init(alloc);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    switch (builtin.os.tag) {
        .windows => try self.startWindows(arena),
        else => try self.startPosix(arena),
    }
}
fn startPosix(self: *Command, arena: Allocator) !void {
    const argsZ = try arena.allocSentinel(?[*:0]const u8, self.args.len, null);
    for (self.args, 0..) |arg, i| argsZ[i] = arg.ptr;
    const envp = if (self.env) |env_map|
        (try createNullDelimitedEnvMap(arena, env_map)).ptr
    else if (builtin.link_libc)
        std.c.environ
    else
        @compileError("missing env vars");
    const pid = try fork();
    if (pid != 0) {
        self.pid = @intCast(pid);
        if (self.rt_post_fork) |f| try f(self);
        return;
    }
    if (self.stdin) |f| setupFd(f.handle, posix.STDIN_FILENO) catch
        return error.ExecFailedInChild;
    if (self.stdout) |f| setupFd(f.handle, posix.STDOUT_FILENO) catch
        return error.ExecFailedInChild;
    if (self.stderr) |f| setupFd(f.handle, posix.STDERR_FILENO) catch
        return error.ExecFailedInChild;
    if (self.cwd) |cwd| _ = posix.system.chdir(cwd);
    global.rlimits().restore();
    if (self.os_pre_exec) |f| if (f(self)) |exitcode| posix.system.exit(exitcode);
    if (self.rt_pre_exec) |f| if (f(self)) |exitcode| posix.system.exit(exitcode);
    const err: posix.E = execve: {
        const file_slice = std.mem.sliceTo(self.path, 0);
        if (std.mem.findScalar(u8, file_slice, '/') != null) {
            break :execve posix.errno(posix.system.execve(self.path, argsZ, envp));
        }
        var path_expanded_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const PATH = global.environ().getPosix("PATH") orelse "/usr/local/bin:/bin/:/usr/bin";
        var it = std.mem.tokenizeScalar(u8, PATH, ':');
        var err: posix.system.E = .NOENT;
        var seen_eacces = false;
        while (it.next()) |search_path| {
            const path_len = search_path.len + file_slice.len + 1;
            if (path_expanded_buf.len < path_len + 1) break :execve .NAMETOOLONG;
            @memcpy(path_expanded_buf[0..search_path.len], search_path);
            path_expanded_buf[search_path.len] = '/';
            @memcpy(path_expanded_buf[search_path.len + 1 ..][0..file_slice.len], file_slice);
            path_expanded_buf[path_len] = 0;
            const full_path = path_expanded_buf[0..path_len :0].ptr;
            err = posix.errno(posix.system.execve(full_path, argsZ, envp));
            switch (err) {
                .ACCES => seen_eacces = true,
                .NOENT, .NOTDIR => {},
                else => break :execve err,
            }
        }
        if (seen_eacces) break :execve .ACCES;
        break :execve err;
    };
    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &stderr_buf);
    const stderr = &stderr_writer.interface;
    switch (err) {
        posix.system.E.NOENT => stderr.print(
            \\Requested executable not found. Please verify the command is on
            \\the PATH and try again.
            \\
        ,
            .{},
        ) catch {},
        else => |e| stderr.print(
            \\exec syscall failed with unexpected error: E{s}
            \\
        ,
            .{@tagName(e)},
        ) catch {},
    }
    stderr.flush() catch {};
    return error.ExecFailedInChild;
}
fn fork() !posix.pid_t {
    const rc = posix.system.fork();
    switch (posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .AGAIN, .NOMEM => return error.SystemResources,
        else => |err| return posix.unexpectedErrno(err),
    }
}
fn startWindows(self: *Command, arena: Allocator) !void {
    const cwd_w = if (self.cwd) |cwd| try std.unicode.utf8ToUtf16LeAllocZ(arena, cwd) else null;
    const command_line = if (self.args.len > 0)
        try windowsCreateCommandLine(arena, self.args)
    else
        try windowsCreateCommandLine(arena, &.{self.path});
    const command_line_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, command_line);
    const env_w = if (self.env) |env_map| try createWindowsEnvBlock(arena, env_map) else null;
    const any_null_fd = self.stdin == null or self.stdout == null or self.stderr == null;
    const null_fd = if (any_null_fd) null_fd: {
        const path = [_]u16{ '\\', 'D', 'e', 'v', 'i', 'c', 'e', '\\', 'N', 'u', 'l', 'l' };
        var path_unicode_string: windows.UNICODE_STRING = .init(&path);
        var attrs: windows.OBJECT_ATTRIBUTES = .{ .ObjectName = &path_unicode_string };
        var fd: windows.HANDLE = undefined;
        var io_status: windows.IO_STATUS_BLOCK = undefined; 
        const result = windows.exp.ntdll.NtCreateFile(
            &fd,
            .{ .GENERIC = .{ .READ = true }, .STANDARD = .{ .SYNCHRONIZE = true } },
            &attrs,
            &io_status,
            null,
            windows.FILE_ATTRIBUTE_NORMAL,
            windows.FILE_SHARE_READ,
            windows.OPEN_EXISTING,
            windows.FILE_NON_DIRECTORY_FILE,
            null,
            0,
        );
        if (result != .SUCCESS) {
            return windows.unexpectedStatus(result);
        }
        break :null_fd fd;
    } else null;
    defer {
        if (null_fd) |fd| _ = windows.exp.kernel32.CloseHandle(fd);
    }
    const attribute_list, const stdin, const stdout, const stderr = if (self.pseudo_console) |pseudo_console| b: {
        var attribute_list_size: usize = undefined;
        _ = windows.exp.kernel32.InitializeProcThreadAttributeList(
            null,
            1,
            0,
            &attribute_list_size,
        );
        const attribute_list_buf = try arena.alloc(u8, attribute_list_size);
        if (windows.exp.kernel32.InitializeProcThreadAttributeList(
            attribute_list_buf.ptr,
            1,
            0,
            &attribute_list_size,
        ) == windows.FALSE) return windows.unexpectedError(windows.GetLastError());
        if (windows.exp.kernel32.UpdateProcThreadAttribute(
            attribute_list_buf.ptr,
            0,
            windows.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            pseudo_console,
            @sizeOf(windows.HPCON),
            null,
            null,
        ) == windows.FALSE) return windows.unexpectedError(windows.GetLastError());
        break :b .{ attribute_list_buf.ptr, null, null, null };
    } else b: {
        const stdin = if (self.stdin) |f| f.handle else null_fd.?;
        const stdout = if (self.stdout) |f| f.handle else null_fd.?;
        const stderr = if (self.stderr) |f| f.handle else null_fd.?;
        break :b .{ null, stdin, stdout, stderr };
    };
    var startup_info_ex = windows.STARTUPINFOEX{
        .StartupInfo = .{
            .cb = if (attribute_list != null) @sizeOf(windows.STARTUPINFOEX) else @sizeOf(windows.STARTUPINFOW),
            .hStdError = stderr,
            .hStdOutput = stdout,
            .hStdInput = stdin,
            .dwFlags = windows.STARTF_USESTDHANDLES,
            .lpReserved = null,
            .lpDesktop = null,
            .lpTitle = null,
            .dwX = 0,
            .dwY = 0,
            .dwXSize = 0,
            .dwYSize = 0,
            .dwXCountChars = 0,
            .dwYCountChars = 0,
            .dwFillAttribute = 0,
            .wShowWindow = 0,
            .cbReserved2 = 0,
            .lpReserved2 = null,
        },
        .lpAttributeList = attribute_list,
    };
    var flags: windows.DWORD = windows.CREATE_UNICODE_ENVIRONMENT;
    if (attribute_list != null) flags |= windows.EXTENDED_STARTUPINFO_PRESENT;
    var process_information: windows.PROCESS_INFORMATION = undefined;
    if (windows.exp.kernel32.CreateProcessW(
        null,
        command_line_w.ptr,
        null,
        null,
        windows.TRUE,
        flags,
        if (env_w) |w| w.ptr else null,
        if (cwd_w) |w| w.ptr else null,
        @ptrCast(&startup_info_ex.StartupInfo),
        &process_information,
    ) == windows.FALSE) return windows.unexpectedError(windows.GetLastError());
    self.pid = process_information.hProcess;
}
fn setupFd(src: File.Handle, target: i32) !void {
    const PosixCall = struct {
        fn f(func: anytype, args: anytype) !usize {
            while (true) {
                const rc = @call(.auto, func, args);
                switch (posix.errno(rc)) {
                    .SUCCESS => return @intCast(rc),
                    .INTR => continue,
                    .AGAIN, .ACCES => return error.Locked,
                    .BADF => unreachable,
                    .BUSY => return error.FileBusy,
                    .INVAL => unreachable, 
                    .PERM => return error.PermissionDenied,
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NOTDIR => unreachable, 
                    .DEADLK => return error.DeadLock,
                    .NOLCK => return error.LockedRegionLimitExceeded,
                    else => |err| return posix.unexpectedErrno(err),
                }
            }
        }
    };
    switch (builtin.os.tag) {
        .linux => {
            _ = try PosixCall.f(linux.dup3, .{ src, target, 0 });
        },
        .freebsd, .ios, .macos => {
            const flags = try PosixCall.f(posix.system.fcntl, .{ src, posix.F.GETFD });
            if (flags & posix.FD_CLOEXEC != 0) {
                _ = try PosixCall.f(
                    posix.system.fcntl,
                    .{ src, posix.F.SETFD, flags & ~@as(u32, posix.FD_CLOEXEC) },
                );
            }
            _ = try PosixCall.f(posix.system.dup2, .{ src, target });
        },
        else => @compileError("unsupported platform"),
    }
}
pub fn wait(self: Command, block: bool) !Exit {
    if (comptime builtin.os.tag == .windows) {
        const result = windows.exp.kernel32.WaitForSingleObject(self.pid.?, windows.INFINITE);
        if (result == windows.WAIT_FAILED) {
            return windows.unexpectedError(windows.GetLastError());
        }
        var exit_code: windows.DWORD = undefined;
        const has_code = windows.exp.kernel32.GetExitCodeProcess(self.pid.?, &exit_code) != windows.FALSE;
        if (!has_code) {
            return windows.unexpectedError(windows.GetLastError());
        }
        return .{ .Exited = exit_code };
    }
    const status: u32 = if (block) wait_block: {
        var status: if (builtin.link_libc) c_int else u32 = undefined;
        _ = try waitPid(self.pid.?, &status, 0);
        break :wait_block @bitCast(status);
    } else wait_nohang: {
        while (true) {
            var status: if (builtin.link_libc) c_int else u32 = undefined;
            const pid = try waitPid(self.pid.?, &status, posix.system.W.NOHANG);
            if (pid != 0) break :wait_nohang @bitCast(status);
        }
    };
    return .init(status);
}
fn waitPid(
    pid: posix.pid_t,
    status: *if (builtin.link_libc) c_int else u32,
    flags: u32,
) !posix.pid_t {
    while (true) {
        const rc = posix.system.waitpid(pid, status, @intCast(flags));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .CHILD => return error.NoChildProcess,
            .INVAL => return error.InvalidWaitOptions,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}
pub fn setData(self: *Command, pointer: ?*anyopaque) void {
    self.data = pointer;
}
pub fn getData(self: Command, comptime DT: type) ?*DT {
    return if (self.data) |ptr| @ptrCast(@alignCast(ptr)) else null;
}
fn createNullDelimitedEnvMap(arena: mem.Allocator, env_map: *const EnvMap) ![:null]?[*:0]u8 {
    const envp_count = env_map.count();
    const envp_buf = try arena.allocSentinel(?[*:0]u8, envp_count, null);
    var it = env_map.iterator();
    var i: usize = 0;
    while (it.next()) |pair| : (i += 1) {
        const env_buf = try arena.allocSentinel(u8, pair.key_ptr.len + pair.value_ptr.len + 1, 0);
        @memcpy(env_buf[0..pair.key_ptr.len], pair.key_ptr.*);
        env_buf[pair.key_ptr.len] = '=';
        @memcpy(env_buf[pair.key_ptr.len + 1 ..], pair.value_ptr.*);
        envp_buf[i] = env_buf.ptr;
    }
    std.debug.assert(i == envp_count);
    return envp_buf;
}
fn createWindowsEnvBlock(allocator: mem.Allocator, env_map: *const EnvMap) ![]u16 {
    const max_chars_needed = x: {
        var max_chars_needed: usize = 4; 
        var it = env_map.iterator();
        while (it.next()) |pair| {
            max_chars_needed += pair.key_ptr.len + pair.value_ptr.len + 2;
        }
        break :x max_chars_needed;
    };
    const result = try allocator.alloc(u16, max_chars_needed);
    errdefer allocator.free(result);
    var it = env_map.iterator();
    var i: usize = 0;
    while (it.next()) |pair| {
        i += try std.unicode.utf8ToUtf16Le(result[i..], pair.key_ptr.*);
        result[i] = '=';
        i += 1;
        i += try std.unicode.utf8ToUtf16Le(result[i..], pair.value_ptr.*);
        result[i] = 0;
        i += 1;
    }
    result[i] = 0;
    i += 1;
    result[i] = 0;
    i += 1;
    result[i] = 0;
    i += 1;
    result[i] = 0;
    i += 1;
    return try allocator.realloc(result, i);
}
fn windowsCreateCommandLine(allocator: mem.Allocator, argv: []const []const u8) ![:0]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const writer = &buf.writer;
    for (argv, 0..) |arg, arg_i| {
        if (arg_i != 0) try writer.writeByte(' ');
        if (mem.indexOfAny(u8, arg, " \t\n\"") == null) {
            try writer.writeAll(arg);
            continue;
        }
        try writer.writeByte('"');
        var backslash_count: usize = 0;
        for (arg) |byte| {
            switch (byte) {
                '\\' => backslash_count += 1,
                '"' => {
                    try writer.splatByteAll('\\', backslash_count * 2 + 1);
                    try writer.writeByte('"');
                    backslash_count = 0;
                },
                else => {
                    try writer.splatByteAll('\\', backslash_count);
                    try writer.writeByte(byte);
                    backslash_count = 0;
                },
            }
        }
        try writer.splatByteAll('\\', backslash_count * 2);
        try writer.writeByte('"');
    }
    return buf.toOwnedSliceSentinel(0);
}
test "createNullDelimitedEnvMap" {
    const allocator = testing.allocator;
    var envmap = EnvMap.init(allocator);
    defer envmap.deinit();
    try envmap.put("HOME", "/home/ifreund");
    try envmap.put("WAYLAND_DISPLAY", "wayland-1");
    try envmap.put("DISPLAY", ":1");
    try envmap.put("DEBUGINFOD_URLS", " ");
    try envmap.put("XCURSOR_SIZE", "24");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const environ = try createNullDelimitedEnvMap(arena.allocator(), &envmap);
    try testing.expectEqual(@as(usize, 5), environ.len);
    inline for (.{
        "HOME=/home/ifreund",
        "WAYLAND_DISPLAY=wayland-1",
        "DISPLAY=:1",
        "DEBUGINFOD_URLS= ",
        "XCURSOR_SIZE=24",
    }) |target| {
        for (environ) |variable| {
            if (mem.eql(u8, mem.span(variable orelse continue), target)) break;
        } else {
            try testing.expect(false); 
        }
    }
}
test "Command: os pre exec 1" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var cmd: Command = .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-v" },
        .os_pre_exec = (struct {
            fn do(_: *Command) ?u8 {
                posix.system.exit(42);
            }
        }).do,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };
    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 42);
}
test "Command: os pre exec 2" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var cmd: Command = .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-v" },
        .os_pre_exec = (struct {
            fn do(_: *Command) ?u8 {
                return 42;
            }
        }).do,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };
    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 42);
}
test "Command: rt pre exec 1" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var cmd: Command = .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-v" },
        .os_pre_exec = null,
        .rt_pre_exec = (struct {
            fn do(_: *Command) ?u8 {
                posix.system.exit(42);
            }
        }).do,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };
    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 42);
}
test "Command: rt pre exec 2" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var cmd: Command = .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-v" },
        .os_pre_exec = null,
        .rt_pre_exec = (struct {
            fn do(_: *Command) ?u8 {
                return 42;
            }
        }).do,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };
    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 42);
}
test "Command: rt post fork 1" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var cmd: Command = .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-c", "sleep 1" },
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = (struct {
            fn do(_: *Command) PostForkError!void {
                return error.PostForkError;
            }
        }).do,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };
    try testing.expectError(error.PostForkError, cmd.testingStart());
}
fn createTestStdout(io: std.Io, dir: std.Io.Dir) !File {
    const file = try dir.createFile(io, "stdout.txt", .{ .read = true });
    if (builtin.os.tag == .windows) {
        if (windows.exp.kernel32.SetHandleInformation(
            file.handle,
            windows.HANDLE_FLAG_INHERIT,
            windows.HANDLE_FLAG_INHERIT,
        ) == windows.FALSE) {
            return windows.unexpectedError(windows.GetLastError());
        }
    }
    return file;
}
fn createTestStderr(io: std.Io, dir: std.Io.Dir) !File {
    const file = try dir.createFile(io, "stderr.txt", .{ .read = true });
    if (builtin.os.tag == .windows) {
        if (windows.exp.kernel32.SetHandleInformation(
            file.handle,
            windows.HANDLE_FLAG_INHERIT,
            windows.HANDLE_FLAG_INHERIT,
        ) == windows.FALSE) {
            return windows.unexpectedError(windows.GetLastError());
        }
    }
    return file;
}
test "Command: redirect stdout to file" {
    var td = try TempDir.init();
    defer td.deinit();
    var stdout = try createTestStdout(testing.io, td.dir);
    defer stdout.close(testing.io);
    var cmd: Command = if (builtin.os.tag == .windows) .{
        .path = "C:\\Windows\\System32\\whoami.exe",
        .args = &.{"C:\\Windows\\System32\\whoami.exe"},
        .stdout = stdout,
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    } else .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-c", "echo hello" },
        .stdout = stdout,
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };
    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expectEqual(@as(u32, 0), @as(u32, exit.Exited));
    const contents = contents: {
        const size = (try stdout.stat(testing.io)).size;
        const data = try testing.allocator.alloc(u8, size);
        errdefer testing.allocator.free(data);
        try testing.expectEqual(size, try stdout.readPositionalAll(testing.io, data, 0));
        break :contents data;
    };
    defer testing.allocator.free(contents);
    try testing.expect(contents.len > 0);
}
test "Command: custom env vars" {
    var td = try TempDir.init();
    defer td.deinit();
    var stdout = try createTestStdout(testing.io, td.dir);
    defer stdout.close(testing.io);
    var env = EnvMap.init(testing.allocator);
    defer env.deinit();
    try env.put("VALUE", "hello");
    var cmd: Command = if (builtin.os.tag == .windows) .{
        .path = "C:\\Windows\\System32\\cmd.exe",
        .args = &.{ "C:\\Windows\\System32\\cmd.exe", "/C", "echo %VALUE%" },
        .stdout = stdout,
        .env = &env,
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    } else .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-c", "echo $VALUE" },
        .stdout = stdout,
        .env = &env,
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };
    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 0);
    const contents = contents: {
        const size = (try stdout.stat(testing.io)).size;
        const data = try testing.allocator.alloc(u8, size);
        errdefer testing.allocator.free(data);
        try testing.expectEqual(size, try stdout.readPositionalAll(testing.io, data, 0));
        break :contents data;
    };
    defer testing.allocator.free(contents);
    if (builtin.os.tag == .windows) {
        try testing.expectEqualStrings("hello\r\n", contents);
    } else {
        try testing.expectEqualStrings("hello\n", contents);
    }
}
test "Command: custom working directory" {
    var td = try TempDir.init();
    defer td.deinit();
    var stdout = try createTestStdout(testing.io, td.dir);
    defer stdout.close(testing.io);
    var cmd: Command = if (builtin.os.tag == .windows) .{
        .path = "C:\\Windows\\System32\\cmd.exe",
        .args = &.{ "C:\\Windows\\System32\\cmd.exe", "/C", "cd" },
        .stdout = stdout,
        .cwd = "C:\\Windows\\System32",
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    } else .{
        .path = "/bin/sh",
        .args = &.{ "/bin/sh", "-c", "pwd" },
        .stdout = stdout,
        .cwd = "/tmp",
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };
    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 0);
    const contents = contents: {
        const size = (try stdout.stat(testing.io)).size;
        const data = try testing.allocator.alloc(u8, size);
        errdefer testing.allocator.free(data);
        try testing.expectEqual(size, try stdout.readPositionalAll(testing.io, data, 0));
        break :contents data;
    };
    defer testing.allocator.free(contents);
    if (builtin.os.tag == .windows) {
        try testing.expectEqualStrings("C:\\Windows\\System32\r\n", contents);
    } else if (builtin.os.tag == .macos) {
        try testing.expectEqualStrings("/private/tmp\n", contents);
    } else {
        try testing.expectEqualStrings("/tmp\n", contents);
    }
}
test "Command: posix fork handles execveZ failure" {
    if (builtin.os.tag == .windows) {
        return error.SkipZigTest;
    }
    var td = try TempDir.init();
    defer td.deinit();
    var stdout = try createTestStdout(testing.io, td.dir);
    defer stdout.close(testing.io);
    var stderr = try createTestStderr(testing.io, td.dir);
    defer stderr.close(testing.io);
    var cmd: Command = .{
        .path = "/not/a/binary",
        .args = &.{ "/not/a/binary", "" },
        .stdout = stdout,
        .stderr = stderr,
        .cwd = "/bin",
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };
    try cmd.testingStart();
    try testing.expect(cmd.pid != null);
    const exit = try cmd.wait(true);
    try testing.expect(exit == .Exited);
    try testing.expect(exit.Exited == 1);
}
fn testingStart(self: *Command) !void {
    self.start(testing.allocator) catch |err| {
        if (err == error.ExecFailedInChild) {
            posix.system.exit(1);
        }
        return err;
    };
}
