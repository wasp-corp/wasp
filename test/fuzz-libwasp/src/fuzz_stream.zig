const builtin = @import("builtin");
const std = @import("std");
const wasp_vt = @import("wasp-vt");
const mem = @import("mem.zig");
const Terminal = wasp_vt.Terminal;
const TerminalStream = wasp_vt.TerminalStream;
var fuzz_alloc: mem.FuzzAllocator(64 * 1024 * 1024) = .{};
pub export fn zig_fuzz_init() callconv(.c) void {
    fuzz_alloc.init();
}
pub export fn zig_fuzz_test(
    buf: [*]const u8,
    len: usize,
) callconv(.c) void {
    if (len == 0) return;
    fuzz_alloc.reset();
    const alloc = fuzz_alloc.allocator();
    const input = buf[0..len];
    const argv0 = "wasp-fuzz";
    const argv0_windows = argv0_windows: {
        var argv0_windows_buf: [std.unicode.calcUtf16LeLen(argv0) catch unreachable]u16 = undefined;
        _ = std.unicode.utf8ToUtf16Le(&argv0_windows_buf, argv0) catch unreachable;
        break :argv0_windows argv0_windows_buf;
    };
    var threaded: std.Io.Threaded = .init(alloc, .{
        .argv0 = .init(.{ .vector = if (builtin.target.os.tag == .windows)
            &argv0_windows
        else
            &.{argv0} }),
    });
    defer threaded.deinit();
    var t = Terminal.init(threaded.io(), alloc, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_bytes = 100,
    }) catch return;
    defer t.deinit(alloc);
    var stream: TerminalStream = t.vtStream();
    defer stream.deinit();
    const mode = input[0];
    const data = input[1..];
    if (mode & 1 == 0) {
        stream.nextSlice(data);
    } else {
        for (data) |byte| stream.next(byte);
    }
}
