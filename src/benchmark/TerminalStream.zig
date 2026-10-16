const TerminalStream = @This();
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const terminalpkg = @import("../terminal/main.zig");
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const Terminal = terminalpkg.Terminal;
const Stream = terminalpkg.TerminalStream;
const global = @import("../global.zig");
const log = std.log.scoped(.@"terminal-stream-bench");
opts: Options,
terminal: Terminal,
stream: Stream,
data_f: ?std.Io.File = null,
pub const Options = struct {
    @"terminal-rows": u16 = 80,
    @"terminal-cols": u16 = 120,
    @"continuation-enabled": bool = false,
    @"continuation-max-bytes": usize = 1024 * 1024,
    @"osc-unknown-max-bytes": usize = 0,
    data: ?[]const u8 = null,
};
pub fn create(
    alloc: Allocator,
    opts: Options,
) !*TerminalStream {
    const ptr = try alloc.create(TerminalStream);
    errdefer alloc.destroy(ptr);
    ptr.* = .{
        .opts = opts,
        .terminal = try .init(global.io(), alloc, .{
            .rows = opts.@"terminal-rows",
            .cols = opts.@"terminal-cols",
        }),
        .stream = undefined,
    };
    errdefer ptr.terminal.deinit(alloc);
    var handler: Stream.Handler = .init(&ptr.terminal);
    if (opts.@"osc-unknown-max-bytes" > 0) {
        handler.unknown_sequence = &unknownSequence;
    }
    ptr.stream = .init(.{
        .allocator = alloc,
        .handler = handler,
        .continuation_max_bytes = if (opts.@"continuation-enabled")
            opts.@"continuation-max-bytes"
        else
            null,
        .osc_unknown_max_bytes = opts.@"osc-unknown-max-bytes",
    });
    return ptr;
}
fn unknownSequence(
    _: *Stream.Handler,
    value: terminalpkg.UnknownSequence,
) void {
    switch (value) {
        inline else => |v| std.mem.doNotOptimizeAway(v.content.len),
    }
}
pub fn destroy(self: *TerminalStream, alloc: Allocator) void {
    self.stream.deinit();
    self.terminal.deinit(alloc);
    alloc.destroy(self);
}
pub fn benchmark(self: *TerminalStream) Benchmark {
    return .init(self, .{
        .stepFn = step,
        .setupFn = setup,
        .teardownFn = teardown,
    });
}
fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalStream = @ptrCast(@alignCast(ptr));
    self.terminal.fullReset();
    assert(self.data_f == null);
    self.data_f = options.dataFile(self.opts.data) catch |err| {
        log.warn("error opening data file err={}", .{err});
        return error.BenchmarkFailed;
    };
}
fn teardown(ptr: *anyopaque) void {
    const self: *TerminalStream = @ptrCast(@alignCast(ptr));
    if (self.data_f) |f| {
        f.close(global.io());
        self.data_f = null;
    }
}
fn step(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalStream = @ptrCast(@alignCast(ptr));
    const f = self.data_f orelse return;
    var f_reader = f.reader(global.io(), &.{});
    const r = &f_reader.interface;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = r.readSliceShort(&buf) catch {
            log.warn("error reading data file err={?}", .{f_reader.err});
            return error.BenchmarkFailed;
        };
        if (n == 0) break; 
        self.stream.nextSlice(buf[0..n]);
    }
}
test TerminalStream {
    const testing = std.testing;
    const alloc = testing.allocator;
    const impl: *TerminalStream = try .create(alloc, .{});
    defer impl.destroy(alloc);
    const bench = impl.benchmark();
    _ = try bench.run(.once);
    const tracked: *TerminalStream = try .create(alloc, .{
        .@"continuation-enabled" = true,
    });
    defer tracked.destroy(alloc);
    const tracked_bench = tracked.benchmark();
    _ = try tracked_bench.run(.once);
}
