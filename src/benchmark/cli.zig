const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("../cli.zig");
const global = @import("../global.zig");
pub const Action = enum {
    @"apc-parser",
    @"codepoint-width",
    @"grapheme-break",
    @"hyperlink-map",
    @"page-compression",
    @"scrollback-compression",
    @"screen-clone",
    @"terminal-formatter",
    @"terminal-parser",
    @"terminal-resize",
    @"terminal-snapshot",
    @"terminal-stream",
    @"is-symbol",
    @"osc-parser",
    pub fn Struct(comptime action: Action) type {
        return switch (action) {
            .@"apc-parser" => @import("ApcParser.zig"),
            .@"hyperlink-map" => @import("HyperlinkMap.zig"),
            .@"screen-clone" => @import("ScreenClone.zig"),
            .@"page-compression" => @import("PageCompression.zig"),
            .@"scrollback-compression" => @import("ScrollbackCompression.zig"),
            .@"terminal-stream" => @import("TerminalStream.zig"),
            .@"codepoint-width" => @import("CodepointWidth.zig"),
            .@"grapheme-break" => @import("GraphemeBreak.zig"),
            .@"terminal-formatter" => @import("TerminalFormatter.zig"),
            .@"terminal-parser" => @import("TerminalParser.zig"),
            .@"terminal-resize" => @import("TerminalResize.zig"),
            .@"terminal-snapshot" => @import("TerminalSnapshot.zig"),
            .@"is-symbol" => @import("IsSymbol.zig"),
            .@"osc-parser" => @import("OscParser.zig"),
        };
    }
};
pub fn main(minimal: std.process.Init.Minimal) !void {
    try global.init(.{ .tool = minimal });
    const alloc = std.heap.c_allocator;
    const action_ = try cli.action.detectArgs(Action, alloc, minimal.args);
    const action = action_ orelse return error.NoAction;
    try mainAction(alloc, action, .{ .cli = minimal.args });
}
pub const Args = union(enum) {
    cli: std.process.Args,
    string: []const u8,
};
pub fn mainAction(
    alloc: Allocator,
    action: Action,
    args: Args,
) !void {
    switch (action) {
        inline else => |comptime_action| {
            const BenchmarkImpl = Action.Struct(comptime_action);
            try mainActionImpl(BenchmarkImpl, alloc, args);
        },
    }
}
fn mainActionImpl(
    comptime BenchmarkImpl: type,
    alloc: Allocator,
    args: Args,
) !void {
    const Options = BenchmarkImpl.Options;
    var opts: Options = .{};
    defer if (@hasDecl(Options, "deinit")) opts.deinit();
    switch (args) {
        .cli => |process_args| {
            var iter = try cli.args.argsIterator(alloc, process_args);
            defer iter.deinit();
            try cli.args.parse(Options, alloc, &opts, &iter);
        },
        .string => |str| {
            var iter = try std.process.Args.IteratorGeneral(.{}).init(
                alloc,
                str,
            );
            defer iter.deinit();
            try cli.args.parse(Options, alloc, &opts, &iter);
        },
    }
    const impl = try BenchmarkImpl.create(alloc, opts);
    defer impl.destroy(alloc);
    const b = impl.benchmark();
    _ = try b.run(.once);
}
