const std = @import("std");
const args = @import("args.zig");
const Allocator = std.mem.Allocator;
const Action = @import("wasp.zig").Action;
const configpkg = @import("../config.zig");
const Config = configpkg.Config;
const Pager = @import("Pager.zig");
const global = @import("../global.zig");
pub const Options = struct {
    default: bool = false,
    @"changes-only": bool = true,
    docs: bool = false,
    @"no-pager": bool = false,
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
    var config = if (opts.default) try Config.default(alloc) else try Config.load(alloc);
    defer config.deinit();
    const configfmt: configpkg.FileFormatter = .{
        .alloc = alloc,
        .config = &config,
        .changed = !opts.default and opts.@"changes-only",
        .docs = opts.docs,
    };
    var pager: Pager = if (!opts.@"no-pager") .init() else .{};
    defer pager.deinit();
    var buffer: [4096]u8 = undefined;
    const writer = pager.writer(&buffer);
    try configfmt.format(writer);
    try writer.flush();
    return 0;
}
