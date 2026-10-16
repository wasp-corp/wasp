const std = @import("std");
const args = @import("args.zig");
const Action = @import("wasp.zig").Action;
const Allocator = std.mem.Allocator;
const helpgen_actions = @import("../input/helpgen_actions.zig");
const global = @import("../global.zig");
pub const Options = struct {
    docs: bool = false,
    pub fn deinit(self: Options) void {
        _ = self;
    }
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();
    {
        var iter = try args.argsIterator(alloc, global.args());
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }
    var stdout: std.Io.File = .stdout();
    var buffer: [4096]u8 = undefined;
    var stdout_writer = stdout.writer(global.io(), &buffer);
    try helpgen_actions.generate(
        &stdout_writer.interface,
        .plaintext,
        opts.docs,
        std.heap.page_allocator,
    );
    try stdout_writer.interface.flush();
    return 0;
}
