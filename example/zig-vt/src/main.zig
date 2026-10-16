const std = @import("std");
const wasp_vt = @import("wasp-vt");
pub fn main(init: std.process.Init) !void {
    var t: wasp_vt.Terminal = try .init(init.io, init.gpa, .{
        .cols = 6,
        .rows = 40,
    });
    defer t.deinit(init.gpa);
    try t.printString("Hello, World!");
    const str = try t.plainString(init.gpa);
    defer init.gpa.free(str);
    std.debug.print("{s}\n", .{str});
}
