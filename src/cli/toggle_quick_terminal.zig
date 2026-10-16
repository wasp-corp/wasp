const std = @import("std");
const Allocator = std.mem.Allocator;
const Action = @import("../cli.zig").wasp.Action;
const apprt = @import("../apprt.zig");
const global = @import("../global.zig");
pub const Options = struct {
    class: ?[:0]const u8 = null,
    pub fn deinit(self: *Options) void {
        self.* = undefined;
    }
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};
pub fn run(alloc: Allocator) !u8 {
    var buf: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &buf);
    const stderr = &stderr_writer.interface;
    if (apprt.App.performIpc(
        alloc,
        .detect,
        .toggle_quick_terminal,
        {},
    ) catch |err| switch (err) {
        error.IPCFailed => {
            return 1;
        },
        else => {
            try stderr.print("Sending the IPC failed: {}\n", .{err});
            return 1;
        },
    }) return 0;
    try stderr.print("+toggle-quick-terminal is not supported on this platform.\n", .{});
    return 1;
}
