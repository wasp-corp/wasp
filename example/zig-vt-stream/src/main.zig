const std = @import("std");
const wasp_vt = @import("wasp-vt");
pub fn main(init: std.process.Init) !void {
    var t: wasp_vt.Terminal = try .init(init.io, init.gpa, .{ .cols = 80, .rows = 24 });
    defer t.deinit(init.gpa);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("Hello, World!\r\n");
    stream.nextSlice("\x1b[1;32mGreen Text\x1b[0m\r\n");
    stream.nextSlice("\x1b[1;1HTop-left corner\r\n");
    stream.nextSlice("\x1b[5B");
    stream.nextSlice("Moved down!\r\n");
    stream.nextSlice("\x1b[2K");
    stream.nextSlice("New content\r\n");
    stream.nextSlice("Line A\r\nLine B\r\nLine C\r\n");
    const str = try t.plainString(init.gpa);
    defer init.gpa.free(str);
    std.debug.print("{s}\n", .{str});
}
