const ApcParser = @This();
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const terminalpkg = @import("../terminal/main.zig");
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const global = @import("../global.zig");
const log = std.log.scoped(.@"apc-parser-bench");
opts: Options,
stream: Stream,
data_f: ?std.Io.File = null,
pub const Options = struct {
    data: ?[]const u8 = null,
};
const Stream = terminalpkg.Stream(Handler);
const Handler = struct {
    alloc: Allocator,
    apc: terminalpkg.apc.Handler = .{},
    pub fn deinit(self: *Handler) void {
        self.apc.deinit();
    }
    pub fn vt(
        self: *Handler,
        comptime action: Stream.Action.Tag,
        value: Stream.Action.Value(action),
    ) void {
        switch (action) {
            .apc_start => self.apc.start(),
            .apc_put => self.apc.feed(self.alloc, value),
            .apc_put_slice => self.apc.feedSlice(self.alloc, value.bytes),
            .apc_end => if (self.apc.end()) |result| {
                var r = result;
                std.mem.doNotOptimizeAway(&r);
                r.deinit(self.alloc);
            },
            else => {},
        }
    }
};
pub fn create(
    alloc: Allocator,
    opts: Options,
) !*ApcParser {
    const ptr = try alloc.create(ApcParser);
    errdefer alloc.destroy(ptr);
    ptr.* = .{
        .opts = opts,
        .stream = .init(.{
            .allocator = alloc,
            .handler = .{ .alloc = alloc },
        }),
    };
    return ptr;
}
pub fn destroy(self: *ApcParser, alloc: Allocator) void {
    self.stream.deinit();
    alloc.destroy(self);
}
pub fn benchmark(self: *ApcParser) Benchmark {
    return .init(self, .{
        .stepFn = step,
        .setupFn = setup,
        .teardownFn = teardown,
    });
}
fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ApcParser = @ptrCast(@alignCast(ptr));
    assert(self.data_f == null);
    self.data_f = options.dataFile(self.opts.data) catch |err| {
        log.warn("error opening data file err={}", .{err});
        return error.BenchmarkFailed;
    };
}
fn teardown(ptr: *anyopaque) void {
    const self: *ApcParser = @ptrCast(@alignCast(ptr));
    if (self.data_f) |f| {
        f.close(global.io());
        self.data_f = null;
    }
}
fn step(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ApcParser = @ptrCast(@alignCast(ptr));
    const f = self.data_f orelse return;
    var read_buf: [64 * 1024]u8 align(std.atomic.cache_line) = undefined;
    var f_reader = f.reader(global.io(), &read_buf);
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
test ApcParser {
    const testing = std.testing;
    const alloc = testing.allocator;
    const impl: *ApcParser = try .create(alloc, .{});
    defer impl.destroy(alloc);
    const bench = impl.benchmark();
    _ = try bench.run(.once);
}
