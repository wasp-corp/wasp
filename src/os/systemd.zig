const std = @import("std");
const builtin = @import("builtin");
const global = @import("../global.zig");
const log = std.log.scoped(.systemd);
pub fn launchedBySystemd() bool {
    return switch (builtin.os.tag) {
        .linux => linux: {
            if (global.environ().getPosix("INVOCATION_ID") == null) break :linux false;
            if (global.environ().getPosix("JOURNAL_STREAM") == null) break :linux false;
            const ppid = std.os.linux.getppid();
            if (ppid == 1) break :linux true;
            var comm_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const comm_path = std.fmt.bufPrint(&comm_path_buf, "/proc/{d}/comm", .{ppid}) catch {
                log.err("unable to format comm path for pid {d}", .{ppid});
                break :linux false;
            };
            const comm_file = std.Io.Dir.openFileAbsolute(global.io(), comm_path, .{ .mode = .read_only }) catch {
                log.err("unable to open '{s}' for reading", .{comm_path});
                break :linux false;
            };
            defer comm_file.close();
            const TASK_COMM_LEN = 16;
            var comm_data_buf: [TASK_COMM_LEN]u8 = undefined;
            const comm_size = comm_file.readAll(&comm_data_buf) catch {
                log.err("problems reading from '{s}'", .{comm_path});
                break :linux false;
            };
            const comm_data = comm_data_buf[0..comm_size];
            break :linux std.mem.eql(
                u8,
                std.mem.trimRight(u8, comm_data, "\n"),
                "systemd",
            );
        },
        else => false,
    };
}
pub const notify = struct {
    fn send(message: []const u8) void {
        if (comptime builtin.os.tag != .linux) return;
        const socket_path = global.environ().getPosix("NOTIFY_SOCKET") orelse return;
        if (socket_path.len == 0) return;
        if (socket_path[0] != '/' and socket_path[0] != '@') {
            log.warn("only AF_UNIX sockets with path or abstract namespace addresses are supported!", .{});
            return;
        }
        var socket_address: std.os.linux.sockaddr.un = undefined;
        if (socket_address.path.len < socket_path.len) {
            log.warn("NOTIFY_SOCKET path is too long!", .{});
            return;
        }
        socket_address.family = std.os.linux.AF.UNIX;
        @memcpy(socket_address.path[0..socket_path.len], socket_path);
        socket_address.path[socket_path.len] = 0;
        const socket: std.os.linux.socket_t = socket: {
            const rc = std.os.linux.socket(
                std.os.linux.AF.UNIX,
                std.os.linux.SOCK.DGRAM | std.os.linux.SOCK.CLOEXEC,
                0,
            );
            switch (linuxErrnoFromSyscall(rc)) {
                .SUCCESS => break :socket @intCast(rc),
                else => |e| {
                    log.warn("creating socket failed: {s}", .{@tagName(e)});
                    return;
                },
            }
        };
        defer _ = std.os.linux.close(socket);
        connect: {
            const rc = std.os.linux.connect(
                socket,
                &socket_address,
                @offsetOf(std.os.linux.sockaddr.un, "path") + socket_address.path.len,
            );
            switch (linuxErrnoFromSyscall(rc)) {
                .SUCCESS => break :connect,
                else => |e| {
                    log.warn("unable to connect to notify socket: {s}", .{@tagName(e)});
                    return;
                },
            }
        }
        write: {
            const rc = std.os.linux.write(socket, message.ptr, message.len);
            switch (linuxErrnoFromSyscall(rc)) {
                .SUCCESS => {
                    const written = rc;
                    if (written < message.len) {
                        log.warn("short write to notify socket: {d} < {d}", .{ rc, message.len });
                        return;
                    }
                    break :write;
                },
                else => |e| {
                    log.warn("unable to write to notify socket: {s}", .{@tagName(e)});
                    return;
                },
            }
        }
    }
    pub fn ready() void {
        if (comptime builtin.os.tag != .linux) return;
        send("READY=1");
    }
    pub fn reloading() void {
        if (comptime builtin.os.tag != .linux) return;
        const now = std.Io.Timestamp.now(global.io(), .awake).toMicroseconds();
        var buffer: [64]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "RELOADING=1\nMONOTONIC_USEC={d}", .{now}) catch |err| {
            log.err("unable to format reloading message: {}", .{err});
            return;
        };
        send(message);
    }
};
fn linuxErrnoFromSyscall(r: usize) std.os.linux.E {
    const signed_r: isize = @bitCast(r);
    const int = if (signed_r > -4096 and signed_r < 0) -signed_r else 0;
    return @enumFromInt(int);
}
