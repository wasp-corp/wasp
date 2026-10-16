const std = @import("std");
const builtin = @import("builtin");
const internal_os = @import("main.zig");
const build_config = @import("../build_config.zig");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const posix = std.posix;
const compat_fd = @import("../lib/compat/fd.zig");
const log = std.log.scoped(.passwd);
comptime {
    if (builtin.target.cpu.arch.isWasm()) {
        @compileError("passwd is not available for wasm");
    }
}
const c = if (builtin.os.tag != .windows) @import("posix_c") else {};
pub const Entry = struct {
    shell: ?[:0]const u8 = null,
    home: ?[:0]const u8 = null,
    name: ?[:0]const u8 = null,
};
pub fn get(alloc: Allocator) !Entry {
    if (builtin.os.tag == .windows) @compileError("passwd is not available on windows");
    var buf: [1024]u8 = undefined;
    var pw: c.struct_passwd = undefined;
    var pw_ptr: ?*c.struct_passwd = null;
    const res = c.getpwuid_r(c.getuid(), &pw, &buf, buf.len, &pw_ptr);
    if (res != 0) {
        log.warn("error retrieving pw entry code={d}", .{res});
        return Entry{};
    }
    if (pw_ptr == null) {
        log.warn("no pw entry to detect default shell, will default to 'sh'", .{});
        return Entry{};
    }
    var result: Entry = .{};
    if (internal_os.isFlatpak()) flatpak: {
        if (comptime !build_config.flatpak) {
            log.warn("flatpak detected, but this build doesn't contain flatpak support", .{});
            break :flatpak;
        }
        log.info("flatpak detected, will use host command to get our entry", .{});
        const Pty = @import("../pty.zig").Pty;
        var pty = try Pty.open(.{});
        defer pty.deinit();
        var cmd: internal_os.FlatpakHostCommand = .{
            .argv = &[_][]const u8{
                "/bin/sh",
                "-l",
                "-c",
                try std.fmt.allocPrint(
                    alloc,
                    "getent passwd {s}",
                    .{std.mem.sliceTo(pw.pw_name, 0)},
                ),
            },
            .stdin = pty.slave,
            .stdout = pty.slave,
            .stderr = pty.slave,
        };
        _ = try cmd.spawn(alloc);
        _ = try cmd.wait();
        _ = compat_fd.close(pty.slave);
        const output = output: {
            var output: std.ArrayListUnmanaged(u8) = .empty;
            while (true) {
                const n = posix.read(pty.master, &buf) catch |err| {
                    switch (err) {
                        error.InputOutput => break,
                        else => return err,
                    }
                };
                try output.appendSlice(alloc, buf[0..n]);
                if (output.items.len > buf.len) break;
            }
            break :output try output.toOwnedSlice(alloc);
        };
        var it = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, output, " \r\n"), ':');
        result.shell = if (it.next()) |v| try alloc.dupeZ(u8, v) else null;
        result.home = if (it.next()) |v| try alloc.dupeZ(u8, v) else null;
        return result;
    }
    if (pw.pw_shell) |ptr| {
        const source = std.mem.sliceTo(ptr, 0);
        const value = try alloc.dupeZ(u8, source);
        result.shell = value;
    }
    if (pw.pw_dir) |ptr| {
        const source = std.mem.sliceTo(ptr, 0);
        const value = try alloc.dupeZ(u8, source);
        result.home = value;
    }
    if (pw.pw_name) |ptr| {
        const source = std.mem.sliceTo(ptr, 0);
        const value = try alloc.dupeZ(u8, source);
        result.name = value;
    }
    return result;
}
test {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const entry = try get(alloc);
    try testing.expect(entry.shell != null);
    try testing.expect(entry.home != null);
}
