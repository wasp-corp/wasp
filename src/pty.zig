const std = @import("std");
const builtin = @import("builtin");
const windows = @import("os/root.zig").windows;
const posix = std.posix;
const assert = @import("quirks.zig").inlineAssert;
const log = std.log.scoped(.pty);
pub const winsize = extern struct {
    ws_row: u16 = 100,
    ws_col: u16 = 80,
    ws_xpixel: u16 = 800,
    ws_ypixel: u16 = 600,
};
pub const Pty = switch (builtin.os.tag) {
    .windows => WindowsPty,
    .ios => NullPty,
    else => PosixPty,
};
pub const Mode = packed struct {
    canonical: bool = true,
    echo: bool = true,
};
pub const ProcessInfo = enum {
    foreground_pid,
    tty_name,
    pub fn Type(comptime info: ProcessInfo) type {
        return switch (info) {
            .foreground_pid => u64,
            .tty_name => [:0]const u8,
        };
    }
};
const NullPty = struct {
    pub const Error = OpenError || GetModeError || SetSizeError || ChildPreExecError;
    pub const Fd = posix.fd_t;
    master: Fd,
    slave: Fd,
    pub const OpenError = error{};
    pub fn open(size: winsize) OpenError!Pty {
        _ = size;
        return .{ .master = 0, .slave = 0 };
    }
    pub fn deinit(self: *Pty) void {
        _ = self;
    }
    pub const GetModeError = error{GetModeFailed};
    pub fn getMode(self: Pty) GetModeError!Mode {
        _ = self;
        return .{};
    }
    pub const SetSizeError = error{};
    pub fn setSize(self: *Pty, size: winsize) SetSizeError!void {
        _ = self;
        _ = size;
    }
    pub const ChildPreExecError = error{};
    pub fn childPreExec(self: Pty) ChildPreExecError!void {
        _ = self;
    }
    pub fn getProcessInfo(_: *Pty, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
        return null;
    }
};
const PosixPty = struct {
    pub const Error = OpenError || GetModeError || GetSizeError || SetSizeError || ChildPreExecError;
    pub const Fd = posix.fd_t;
    const c = @import("pty-c");
    master: Fd,
    slave: Fd,
    tty_name_buf: [std.Io.Dir.max_path_bytes:0]u8 = undefined,
    tty_name: ?[:0]const u8 = null,
    pub const OpenError = error{OpenptyFailed};
    pub fn open(size: winsize) OpenError!Pty {
        var sizeCopy = size;
        var master_fd: Fd = undefined;
        var slave_fd: Fd = undefined;
        if (c.openpty(
            &master_fd,
            &slave_fd,
            null,
            null,
            @ptrCast(&sizeCopy),
        ) < 0)
            return error.OpenptyFailed;
        errdefer {
            _ = posix.system.close(master_fd);
            _ = posix.system.close(slave_fd);
        }
        cloexec: {
            const flags = posix.system.fcntl(master_fd, posix.F.GETFD);
            if (flags == -1) {
                log.warn("error getting flags for master fd err=E{s}", .{@tagName(posix.errno(-1))});
                break :cloexec;
            }
            switch (posix.errno(posix.system.fcntl(
                master_fd,
                posix.F.SETFD,
                flags | posix.FD_CLOEXEC,
            ))) {
                .SUCCESS => {},
                else => |e| log.warn("error setting CLOEXEC on master fd err=E{}", .{e}),
            }
        }
        var attrs: c.termios = undefined;
        if (c.tcgetattr(master_fd, &attrs) != 0)
            return error.OpenptyFailed;
        attrs.c_iflag |= c.IUTF8;
        if (c.tcsetattr(master_fd, c.TCSANOW, &attrs) != 0)
            return error.OpenptyFailed;
        return .{
            .master = master_fd,
            .slave = slave_fd,
            .tty_name_buf = undefined,
            .tty_name = null,
        };
    }
    pub fn deinit(self: *Pty) void {
        _ = posix.system.close(self.master);
        self.* = undefined;
    }
    pub const GetModeError = error{GetModeFailed};
    pub fn getMode(self: Pty) GetModeError!Mode {
        var attrs: c.termios = undefined;
        if (c.tcgetattr(self.master, &attrs) != 0)
            return error.GetModeFailed;
        return .{
            .canonical = (attrs.c_lflag & c.ICANON) != 0,
            .echo = (attrs.c_lflag & c.ECHO) != 0,
        };
    }
    pub const GetSizeError = error{IoctlFailed};
    pub fn getSize(self: Pty) GetSizeError!winsize {
        var ws: winsize = undefined;
        if (c.ioctl(self.master, c.TIOCGWINSZ, @intFromPtr(&ws)) < 0)
            return error.IoctlFailed;
        return ws;
    }
    pub const SetSizeError = error{IoctlFailed};
    pub fn setSize(self: *Pty, size: winsize) SetSizeError!void {
        if (c.ioctl(self.master, c.TIOCSWINSZ, @intFromPtr(&size)) < 0)
            return error.IoctlFailed;
    }
    pub const ChildPreExecError = error{ OperationNotSupported, ProcessGroupFailed, SetControllingTerminalFailed };
    pub fn childPreExec(self: Pty) ChildPreExecError!void {
        var sa: posix.Sigaction = .{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.ABRT, &sa, null);
        posix.sigaction(posix.SIG.ALRM, &sa, null);
        posix.sigaction(posix.SIG.BUS, &sa, null);
        posix.sigaction(posix.SIG.CHLD, &sa, null);
        posix.sigaction(posix.SIG.FPE, &sa, null);
        posix.sigaction(posix.SIG.HUP, &sa, null);
        posix.sigaction(posix.SIG.ILL, &sa, null);
        posix.sigaction(posix.SIG.INT, &sa, null);
        posix.sigaction(posix.SIG.PIPE, &sa, null);
        posix.sigaction(posix.SIG.SEGV, &sa, null);
        posix.sigaction(posix.SIG.TRAP, &sa, null);
        posix.sigaction(posix.SIG.TERM, &sa, null);
        posix.sigaction(posix.SIG.QUIT, &sa, null);
        if (c.setsid() < 0) return error.ProcessGroupFailed;
        switch (posix.errno(c.ioctl(self.slave, c.TIOCSCTTY, @as(c_ulong, 0)))) {
            .SUCCESS => {},
            else => |err| {
                log.err("error setting controlling terminal errno={}", .{err});
                return error.SetControllingTerminalFailed;
            },
        }
        _ = posix.system.close(self.slave);
        _ = posix.system.close(self.master);
    }
    pub fn getProcessInfo(self: *PosixPty, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
        return switch (info) {
            .foreground_pid => {
                switch (builtin.os.tag) {
                    .linux => {
                        const linux = std.os.linux;
                        var pgrp: i32 = undefined;
                        const rc = linux.tcgetpgrp(self.master, &pgrp);
                        switch (rc) {
                            0 => return @intCast(pgrp),
                            else => return null,
                        }
                    },
                    else => {
                        const rc = c.tcgetpgrp(self.master);
                        if (rc < 0) return null;
                        return @intCast(rc);
                    },
                }
            },
            .tty_name => {
                if (self.tty_name) |tty_name| return tty_name;
                switch (builtin.os.tag) {
                    .macos => {
                        assert(self.tty_name_buf.len >= 128);
                        switch (posix.errno(c.ioctl(self.master, c.TIOCPTYGNAME, @intFromPtr(&self.tty_name_buf)))) {
                            .SUCCESS => {
                                const tty_name: [:0]const u8 = std.mem.sliceTo(&self.tty_name_buf, 0);
                                self.tty_name = tty_name;
                                return tty_name;
                            },
                            else => |err| {
                                log.err("error getting name of slave PTY errno={t}", .{err});
                                return null;
                            },
                        }
                    },
                    .linux => {
                        if (c.ptsname_r(self.master, &self.tty_name_buf, self.tty_name_buf.len) != 0) return null;
                        const tty_name: [:0]const u8 = std.mem.sliceTo(&self.tty_name_buf, 0);
                        self.tty_name = tty_name;
                        return tty_name;
                    },
                    else => return null,
                }
            },
        };
    }
};
const WindowsPty = struct {
    pub const Error = OpenError || GetSizeError || SetSizeError;
    pub const Fd = windows.HANDLE;
    var pipe_name_counter = std.atomic.Value(u32).init(1);
    out_pipe: windows.HANDLE,
    in_pipe: windows.HANDLE,
    out_pipe_pty: windows.HANDLE,
    in_pipe_pty: windows.HANDLE,
    pseudo_console: windows.HPCON,
    size: winsize,
    pub const OpenError = error{Unexpected};
    pub fn open(size: winsize) OpenError!Pty {
        var pty: Pty = undefined;
        var pipe_path_buf: [128]u8 = undefined;
        var pipe_path_buf_w: [128]u16 = undefined;
        const pipe_path = std.fmt.bufPrintZ(
            &pipe_path_buf,
            "\\\\.\\pipe\\LOCAL\\wasp-pty-{d}-{d}",
            .{
                windows.GetCurrentProcessId(),
                pipe_name_counter.fetchAdd(1, .monotonic),
            },
        ) catch unreachable;
        const pipe_path_w_len = std.unicode.utf8ToUtf16Le(
            &pipe_path_buf_w,
            pipe_path,
        ) catch unreachable;
        pipe_path_buf_w[pipe_path_w_len] = 0;
        const pipe_path_w = pipe_path_buf_w[0..pipe_path_w_len :0];
        const security_attributes = windows.SECURITY_ATTRIBUTES{
            .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
            .bInheritHandle = windows.FALSE,
            .lpSecurityDescriptor = null,
        };
        pty.in_pipe = windows.exp.kernel32.CreateNamedPipeW(
            pipe_path_w.ptr,
            windows.PIPE_ACCESS_OUTBOUND |
                windows.FILE_FLAG_FIRST_PIPE_INSTANCE |
                windows.FILE_FLAG_OVERLAPPED,
            windows.PIPE_TYPE_BYTE,
            1,
            4096,
            4096,
            0,
            &security_attributes,
        );
        if (pty.in_pipe == windows.INVALID_HANDLE_VALUE) {
            return windows.unexpectedError(windows.GetLastError());
        }
        errdefer _ = windows.exp.kernel32.CloseHandle(pty.in_pipe);
        var security_attributes_read = security_attributes;
        pty.in_pipe_pty = windows.exp.kernel32.CreateFileW(
            pipe_path_w.ptr,
            windows.GENERIC_READ,
            0,
            &security_attributes_read,
            windows.OPEN_EXISTING,
            windows.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (pty.in_pipe_pty == windows.INVALID_HANDLE_VALUE) {
            return windows.unexpectedError(windows.GetLastError());
        }
        errdefer _ = windows.exp.kernel32.CloseHandle(pty.in_pipe_pty);
        if (windows.exp.kernel32.CreatePipe(&pty.out_pipe, &pty.out_pipe_pty, null, 0) == windows.FALSE) {
            return windows.unexpectedError(windows.GetLastError());
        }
        errdefer {
            _ = windows.exp.kernel32.CloseHandle(pty.out_pipe);
            _ = windows.exp.kernel32.CloseHandle(pty.out_pipe_pty);
        }
        const SetHandleInformation = struct {
            fn f(hObject: windows.HANDLE) !void {
                if (windows.exp.kernel32.SetHandleInformation(
                    hObject,
                    windows.HANDLE_FLAG_INHERIT,
                    0,
                ) == windows.FALSE) {
                    return windows.unexpectedError(windows.GetLastError());
                }
            }
        };
        try SetHandleInformation.f(pty.in_pipe);
        try SetHandleInformation.f(pty.in_pipe_pty);
        try SetHandleInformation.f(pty.out_pipe);
        try SetHandleInformation.f(pty.out_pipe_pty);
        const result = windows.exp.kernel32.CreatePseudoConsole(
            .{ .X = @intCast(size.ws_col), .Y = @intCast(size.ws_row) },
            pty.in_pipe_pty,
            pty.out_pipe_pty,
            0,
            &pty.pseudo_console,
        );
        if (result != windows.S_OK) return error.Unexpected;
        pty.size = size;
        return pty;
    }
    pub fn deinit(self: *Pty) void {
        _ = windows.exp.kernel32.CloseHandle(self.in_pipe_pty);
        _ = windows.exp.kernel32.CloseHandle(self.in_pipe);
        _ = windows.exp.kernel32.CloseHandle(self.out_pipe_pty);
        _ = windows.exp.kernel32.CloseHandle(self.out_pipe);
        _ = windows.exp.kernel32.ClosePseudoConsole(self.pseudo_console);
        self.* = undefined;
    }
    pub const GetSizeError = error{};
    pub fn getSize(self: Pty) GetSizeError!winsize {
        return self.size;
    }
    pub const SetSizeError = error{ResizeFailed};
    pub fn setSize(self: *Pty, size: winsize) SetSizeError!void {
        const result = windows.exp.kernel32.ResizePseudoConsole(
            self.pseudo_console,
            .{ .X = @intCast(size.ws_col), .Y = @intCast(size.ws_row) },
        );
        if (result != windows.S_OK) return error.ResizeFailed;
        self.size = size;
    }
    pub fn getProcessInfo(_: *WindowsPty, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
        return null;
    }
};
test {
    const testing = std.testing;
    var ws: winsize = .{
        .ws_row = 50,
        .ws_col = 80,
        .ws_xpixel = 1,
        .ws_ypixel = 1,
    };
    var pty = try Pty.open(ws);
    defer pty.deinit();
    try testing.expectEqual(ws, try pty.getSize());
    ws.ws_row *= 2;
    try pty.setSize(ws);
    try testing.expectEqual(ws, try pty.getSize());
    switch (builtin.os.tag) {
        .freebsd => try testing.expect(std.mem.startsWith(u8, pty.getProcessInfo(.tty_name).?, "/dev/")),
        .linux => try testing.expect(std.mem.startsWith(u8, pty.getProcessInfo(.tty_name).?, "/dev/pts/")),
        .macos => try testing.expect(std.mem.startsWith(u8, pty.getProcessInfo(.tty_name).?, "/dev/")),
        else => try testing.expect(pty.getProcessInfo(.tty_name) == null),
    }
}
