const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const build_config = @import("../build_config.zig");
const apprt = @import("../apprt.zig");
const global = @import("../global.zig");
const log = std.log.scoped(.@"os-open");
pub fn open(
    kind: apprt.action.OpenUrl.Kind,
    url: []const u8,
) !void {
    if (comptime builtin.os.tag == .macos) {
        switch (kind) {
            .unknown, .osc8 => return error.UntrustedLink,
            .text, .html => {},
        }
    }
    var spawn_opts: std.process.SpawnOptions = switch (builtin.os.tag) {
        .linux, .freebsd => .{ .argv = &.{ "xdg-open", url } },
        .windows => .{ .argv = &.{ "rundll32", "url.dll,FileProtocolHandler", url } },
        .macos => switch (kind) {
            .text => .{ .argv = &.{ "open", "-t", url } },
            .html => .{ .argv = &.{ "open", url } },
            .unknown, .osc8 => unreachable,
        },
        .ios => return error.Unimplemented,
        else => @compileError("unsupported OS"),
    };
    spawn_opts.stdout = .ignore;
    spawn_opts.stderr = .pipe;
    const exe = if (comptime build_config.snap) local_env: {
        var environ_map = try global.environMap();
        defer environ_map.deinit();
        _ = environ_map.orderedRemove("LD_LIBRARY_PATH");
        spawn_opts.environ_map = &environ_map;
        break :local_env try std.process.spawn(global.io(), spawn_opts);
    } else
        try std.process.spawn(global.io(), spawn_opts);
    const thread = try std.Thread.spawn(.{}, openThread, .{ global.io(), exe });
    thread.detach();
}
test "macOS untrusted links have no generic opener fallback" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try std.testing.expectError(
        error.UntrustedLink,
        open(.osc8, "file:///tmp/payload.command"),
    );
    try std.testing.expectError(
        error.UntrustedLink,
        open(.unknown, "file:///tmp/payload.command"),
    );
}
fn openThread(io: std.Io, exe_: std.process.Child) void {
    var exe = exe_;
    if (exe.stderr) |stderr| {
        var buffer: [256]u8 = undefined;
        var stream = stderr.readerStreaming(io, &buffer);
        const reader = &stream.interface;
        while (true) {
            const line = reader.takeDelimiterInclusive('\n') catch |outer| switch (outer) {
                error.EndOfStream => break,
                error.ReadFailed => break,
                error.StreamTooLong => reader.take(buffer.len) catch |inner| switch (inner) {
                    error.ReadFailed => break,
                    error.EndOfStream => break,
                },
            };
            log.warn("open stderr={s}", .{std.mem.trimEnd(u8, line, "\n")});
        }
    }
    _ = exe.wait(io) catch {};
}
