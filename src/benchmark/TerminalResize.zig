const TerminalResize = @This();
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const terminalpkg = @import("../terminal/main.zig");
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const Terminal = terminalpkg.Terminal;
const global = @import("../global.zig");
const log = std.log.scoped(.@"terminal-resize-bench");
opts: Options,
alloc: Allocator,
terminal: Terminal,
pub const Options = struct {
    mode: Mode = .cols,
    loops: u32 = 1,
    @"terminal-rows": u16 = 80,
    @"terminal-cols": u16 = 120,
    @"resize-cols": ?u16 = null,
    @"resize-rows": ?u16 = null,
    @"fill-lines": u32 = 10_000,
    @"scrollback-bytes": usize = 50_000_000,
    data: ?[]const u8 = null,
};
pub const Mode = enum {
    noop,
    cols,
    @"cols-no-reflow",
    rows,
    both,
};
pub fn create(
    alloc: Allocator,
    opts: Options,
) !*TerminalResize {
    const ptr = try alloc.create(TerminalResize);
    errdefer alloc.destroy(ptr);
    ptr.* = .{
        .opts = opts,
        .alloc = alloc,
        .terminal = try .init(global.io(), alloc, .{
            .rows = opts.@"terminal-rows",
            .cols = opts.@"terminal-cols",
            .max_scrollback_bytes = opts.@"scrollback-bytes",
        }),
    };
    return ptr;
}
pub fn destroy(self: *TerminalResize, alloc: Allocator) void {
    self.terminal.deinit(alloc);
    alloc.destroy(self);
}
pub fn benchmark(self: *TerminalResize) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .noop => stepNoop,
            .cols, .@"cols-no-reflow" => stepCols,
            .rows => stepRows,
            .both => stepBoth,
        },
        .setupFn = setup,
    });
}
fn targetCols(self: *const TerminalResize) u16 {
    return self.opts.@"resize-cols" orelse
        @max(1, self.opts.@"terminal-cols" / 2);
}
fn targetRows(self: *const TerminalResize) u16 {
    return self.opts.@"resize-rows" orelse
        @max(1, self.opts.@"terminal-rows" / 2);
}
fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalResize = @ptrCast(@alignCast(ptr));
    self.terminal.fullReset();
    assert(self.terminal.cols == self.opts.@"terminal-cols");
    assert(self.terminal.rows == self.opts.@"terminal-rows");
    self.fill();
    try self.replayData();
    if (self.opts.mode == .@"cols-no-reflow") {
        self.terminal.modes.set(.wraparound, false);
    }
}
fn fill(self: *TerminalResize) void {
    if (self.opts.@"fill-lines" == 0) return;
    var s = self.terminal.vtStream();
    defer s.deinit();
    var prng: std.Random.DefaultPrng = .init(0xB3);
    const rand = prng.random();
    const cols: usize = self.terminal.cols;
    var line_buf: [8192]u8 = undefined;
    for (0..self.opts.@"fill-lines") |i| {
        if (i % 64 == 0) s.nextSlice("\x1b[48;2;20;40;60m");
        if (i % 64 == 32) s.nextSlice("\x1b[m");
        if (i % 16 == 15) {
            s.nextSlice("\r\n");
            continue;
        }
        const min = @max(1, cols / 4);
        const max = @min(line_buf.len, cols * 5 / 2);
        const len = min + rand.uintLessThan(usize, max - min);
        var j: usize = 0;
        while (j < len) {
            if (i % 8 == 7 and j % 16 == 8 and j + 3 <= len) {
                line_buf[j..][0..3].* = "漢".*;
                j += 3;
                continue;
            }
            line_buf[j] = if (j % 8 == 7)
                ' '
            else
                rand.intRangeAtMost(u8, 'a', 'z');
            j += 1;
        }
        s.nextSlice(line_buf[0..len]);
        s.nextSlice("\r\n");
    }
}
fn replayData(self: *TerminalResize) Benchmark.Error!void {
    const data_f: std.Io.File = (options.dataFile(
        self.opts.data,
    ) catch |err| {
        log.warn("error opening data file err={}", .{err});
        return error.BenchmarkFailed;
    }) orelse return;
    defer data_f.close(global.io());
    var stream = self.terminal.vtStream();
    defer stream.deinit();
    var read_buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    var f_reader = data_f.reader(global.io(), &read_buf);
    const r = &f_reader.interface;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = r.readSliceShort(&buf) catch {
            log.warn("error reading data file err={?}", .{f_reader.err});
            return error.BenchmarkFailed;
        };
        if (n == 0) break; 
        stream.nextSlice(buf[0..n]);
    }
}
fn resizeTerminal(
    self: *TerminalResize,
    cols: u16,
    rows: u16,
) Benchmark.Error!void {
    self.terminal.resize(self.alloc, .{
        .cols = cols,
        .rows = rows,
        .cell_size_px = .{ .width = 10, .height = 20 },
    }) catch |err| {
        log.warn("error resizing terminal err={}", .{err});
        return error.BenchmarkFailed;
    };
    std.mem.doNotOptimizeAway(&self.terminal);
}
fn stepNoop(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalResize = @ptrCast(@alignCast(ptr));
    const cols = self.opts.@"terminal-cols";
    const rows = self.opts.@"terminal-rows";
    for (0..50_000_000 * @as(u64, self.opts.loops)) |_| {
        try self.resizeTerminal(cols, rows);
    }
}
fn stepCols(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalResize = @ptrCast(@alignCast(ptr));
    const cols = self.opts.@"terminal-cols";
    const rows = self.opts.@"terminal-rows";
    const target = self.targetCols();
    const cycles: u64 = switch (self.opts.mode) {
        .cols => 25,
        .@"cols-no-reflow" => 1_500,
        else => unreachable,
    };
    for (0..cycles * @as(u64, self.opts.loops)) |_| {
        try self.resizeTerminal(target, rows);
        try self.resizeTerminal(cols, rows);
    }
}
fn stepRows(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalResize = @ptrCast(@alignCast(ptr));
    const cols = self.opts.@"terminal-cols";
    const rows = self.opts.@"terminal-rows";
    const target = self.targetRows();
    for (0..2_500_000 * @as(u64, self.opts.loops)) |_| {
        try self.resizeTerminal(cols, target);
        try self.resizeTerminal(cols, rows);
    }
}
fn stepBoth(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalResize = @ptrCast(@alignCast(ptr));
    const cols = self.opts.@"terminal-cols";
    const rows = self.opts.@"terminal-rows";
    const target_cols = self.targetCols();
    const target_rows = self.targetRows();
    for (0..25 * @as(u64, self.opts.loops)) |_| {
        try self.resizeTerminal(target_cols, target_rows);
        try self.resizeTerminal(cols, rows);
    }
}
test TerminalResize {
    const testing = std.testing;
    const alloc = testing.allocator;
    const impl: *TerminalResize = try .create(alloc, .{
        .mode = .cols,
        .@"terminal-rows" = 10,
        .@"terminal-cols" = 20,
        .@"fill-lines" = 50,
    });
    defer impl.destroy(alloc);
    const bench = impl.benchmark();
    _ = try bench.run(.once);
}
