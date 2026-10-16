const std = @import("std");
const wasp_vt = @import("wasp-vt");
pub fn main(init: std.process.Init) !void {
    var t: wasp_vt.Terminal = try .init(init.io, init.gpa, .{ .cols = 150, .rows = 80 });
    defer t.deinit(init.gpa);
    var stream = t.vtStream();
    defer stream.deinit();
    const stdin = std.Io.File.stdin();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try stdin.readStreaming(init.io, &.{&buf});
        if (n == 0) break;
        for (buf[0..n]) |byte| {
            if (byte == '\n') stream.next('\r');
            stream.next(byte);
        }
    }
    const formatter: wasp_vt.formatter.TerminalFormatter = .init(&t, .{
        .emit = .html,
        .palette = &t.colors.palette.current,
    });
    var stdout_writer = std.Io.File.stdout().writer(init.io, &buf);
    const stdout = &stdout_writer.interface;
    try stdout.print("{f}", .{formatter});
    try stdout.flush();
}
