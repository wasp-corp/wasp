const std = @import("std");
pub const PipeError = error{
    SystemFdQuotaExceeded,
    ProcessFdQuotaExceeded,
} || std.posix.UnexpectedError;
pub fn close(fd: std.posix.fd_t) void {
    switch (std.posix.errno(std.posix.system.close(fd))) {
        .BADF => unreachable, 
        else => {}, 
    }
}
pub fn pipe() PipeError![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    switch (std.posix.errno(std.posix.system.pipe(&fds))) {
        .SUCCESS => return fds,
        .INVAL => unreachable, 
        .FAULT => unreachable, 
        .NFILE => return error.SystemFdQuotaExceeded,
        .MFILE => return error.ProcessFdQuotaExceeded,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}
pub fn pipe2(flags: std.posix.O) PipeError![2]std.posix.fd_t {
    if (@TypeOf(std.posix.system.pipe2) != void) {
        var fds: [2]std.posix.fd_t = undefined;
        switch (std.posix.errno(std.posix.system.pipe2(&fds, flags))) {
            .SUCCESS => return fds,
            .INVAL => unreachable, 
            .FAULT => unreachable, 
            .NFILE => return error.SystemFdQuotaExceeded,
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
    const fds: [2]std.posix.fd_t = try pipe();
    errdefer {
        close(fds[0]);
        close(fds[1]);
    }
    if (@as(u32, @bitCast(flags)) == 0)
        return fds;
    if (flags.CLOEXEC) {
        for (fds) |fd| {
            switch (std.posix.errno(std.posix.system.fcntl(fd, std.posix.F.SETFD, @as(u32, std.posix.FD_CLOEXEC)))) {
                .SUCCESS => {},
                .INVAL => unreachable, 
                .BADF => unreachable, 
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
    }
    const new_flags: u32 = f: {
        var new_flags = flags;
        new_flags.CLOEXEC = false;
        break :f @bitCast(new_flags);
    };
    if (new_flags != 0) {
        for (fds) |fd| {
            switch (std.posix.errno(std.posix.system.fcntl(fd, std.posix.F.SETFL, new_flags))) {
                .SUCCESS => {},
                .INVAL => unreachable, 
                .BADF => unreachable, 
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
    }
    return fds;
}
