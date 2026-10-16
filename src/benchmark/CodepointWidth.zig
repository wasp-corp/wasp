const CodepointWidth = @This();
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const UTF8Decoder = @import("../terminal/UTF8Decoder.zig");
const simd = @import("../simd/root.zig");
const table = @import("../unicode/root.zig").table;
const global = @import("../global.zig");
const log = std.log.scoped(.@"terminal-stream-bench");
opts: Options,
data_f: ?std.Io.File = null,
pub const Options = struct {
    mode: Mode = .noop,
    data: ?[]const u8 = null,
};
pub const Mode = enum {
    noop,
    wcwidth,
    simd,
    table,
};
pub fn create(
    alloc: Allocator,
    opts: Options,
) !*CodepointWidth {
    const ptr = try alloc.create(CodepointWidth);
    errdefer alloc.destroy(ptr);
    ptr.* = .{ .opts = opts };
    return ptr;
}
pub fn destroy(self: *CodepointWidth, alloc: Allocator) void {
    alloc.destroy(self);
}
pub fn benchmark(self: *CodepointWidth) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .noop => stepNoop,
            .wcwidth => stepWcwidth,
            .table => stepTable,
            .simd => stepSimd,
        },
        .setupFn = setup,
        .teardownFn = teardown,
    });
}
fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *CodepointWidth = @ptrCast(@alignCast(ptr));
    assert(self.data_f == null);
    self.data_f = options.dataFile(self.opts.data) catch |err| {
        log.warn("error opening data file err={}", .{err});
        return error.BenchmarkFailed;
    };
}
fn teardown(ptr: *anyopaque) void {
    const self: *CodepointWidth = @ptrCast(@alignCast(ptr));
    if (self.data_f) |f| {
        f.close(global.io());
        self.data_f = null;
    }
}
fn stepNoop(ptr: *anyopaque) Benchmark.Error!void {
    _ = ptr;
}
extern "c" fn wcwidth(c: u32) c_int;
fn stepWcwidth(ptr: *anyopaque) Benchmark.Error!void {
    if (comptime builtin.os.tag == .windows) {
        log.warn("wcwidth is not available on Windows", .{});
        return;
    }
    const self: *CodepointWidth = @ptrCast(@alignCast(ptr));
    const f = self.data_f orelse return;
    var read_buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    var f_reader = f.reader(global.io(), &read_buf);
    var r = &f_reader.interface;
    var d: UTF8Decoder = .{};
    var buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    while (true) {
        const n = r.readSliceShort(&buf) catch {
            log.warn("error reading data file err={?}", .{f_reader.err});
            return error.BenchmarkFailed;
        };
        if (n == 0) break;
        for (buf[0..n]) |c| {
            const cp_, const consumed = d.next(c);
            assert(consumed);
            if (cp_) |cp| {
                std.mem.doNotOptimizeAway(wcwidth(cp));
            }
        }
    }
}
fn stepTable(ptr: *anyopaque) Benchmark.Error!void {
    const self: *CodepointWidth = @ptrCast(@alignCast(ptr));
    const f = self.data_f orelse return;
    var read_buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    var f_reader = f.reader(global.io(), &read_buf);
    var r = &f_reader.interface;
    var d: UTF8Decoder = .{};
    var buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    while (true) {
        const n = r.readSliceShort(&buf) catch {
            log.warn("error reading data file err={?}", .{f_reader.err});
            return error.BenchmarkFailed;
        };
        if (n == 0) break;
        for (buf[0..n]) |c| {
            const cp_, const consumed = d.next(c);
            assert(consumed);
            if (cp_) |cp| {
                std.mem.doNotOptimizeAway(if (cp <= 0xFF)
                    1
                else
                    table.get(@intCast(cp)).width);
            }
        }
    }
}
fn stepSimd(ptr: *anyopaque) Benchmark.Error!void {
    const self: *CodepointWidth = @ptrCast(@alignCast(ptr));
    const f = self.data_f orelse return;
    var read_buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    var f_reader = f.reader(global.io(), &read_buf);
    var r = &f_reader.interface;
    var d: UTF8Decoder = .{};
    var buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    while (true) {
        const n = r.readSliceShort(&buf) catch {
            log.warn("error reading data file err={?}", .{f_reader.err});
            return error.BenchmarkFailed;
        };
        if (n == 0) break;
        for (buf[0..n]) |c| {
            const cp_, const consumed = d.next(c);
            assert(consumed);
            if (cp_) |cp| {
                std.mem.doNotOptimizeAway(simd.codepointWidth(cp));
            }
        }
    }
}
test CodepointWidth {
    const testing = std.testing;
    const alloc = testing.allocator;
    const impl: *CodepointWidth = try .create(alloc, .{});
    defer impl.destroy(alloc);
    const bench = impl.benchmark();
    _ = try bench.run(.once);
}
