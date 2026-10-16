const Pager = @This();
const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/root.zig");
const global = @import("../global.zig");
child: ?std.process.Child = null,
file_writer: std.Io.File.Writer = undefined,
pub fn init() Pager {
    return .{ .child = initPager() };
}
pub fn writer(self: *Pager, buffer: []u8) *std.Io.Writer {
    if (self.child) |child| {
        self.file_writer = child.stdin.?.writer(global.io(), buffer);
    } else {
        self.file_writer = std.Io.File.stdout().writer(global.io(), buffer);
    }
    return &self.file_writer.interface;
}
pub fn deinit(self: *Pager) void {
    if (self.child) |*child| {
        self.file_writer.interface.flush() catch {};
        if (child.stdin) |stdin| {
            stdin.close(global.io());
            child.stdin = null;
        }
        _ = child.wait(global.io()) catch {};
    }
    self.* = undefined;
}
fn initPager() ?std.process.Child {
    const stdout_file: std.Io.File = .stdout();
    if (!(stdout_file.isTty(global.io()) catch return null)) return null;
    var env = global.environMap() catch return null;
    defer env.deinit();
    const wasp_var = env.get("WASP_PAGER");
    const pager_var = env.get("PAGER");
    const cmd: ?[]const u8 = cmd: {
        if (wasp_var) |v| break :cmd if (v.len > 0) v else null;
        if (pager_var) |v| break :cmd if (v.len > 0) v else null;
        break :cmd "less";
    };
    if (cmd == null) return null;
    return std.process.spawn(global.io(), .{
        .argv = &.{cmd.?},
        .stdin = .pipe,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch null;
}
test "pager: non-tty" {
    var pager: Pager = .init();
    defer pager.deinit();
    try std.testing.expect(pager.child == null);
}
test "pager: default writer" {
    var pager: Pager = .{};
    defer pager.deinit();
    try std.testing.expect(pager.child == null);
    var buf: [4096]u8 = undefined;
    const w = pager.writer(&buf);
    try w.writeAll("hello");
}
