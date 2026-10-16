const ScrollbackCompression = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const terminalpkg = @import("../terminal/main.zig");
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const PageList = terminalpkg.PageList;
const Terminal = terminalpkg.Terminal;
const global = @import("../global.zig");
const log = std.log.scoped(.@"scrollback-compression-bench");
opts: Options,
terminal: Terminal,
pub const Options = struct {
    _arena: ?std.heap.ArenaAllocator = null,
    mode: Mode = .compress,
    @"terminal-rows": u16 = 80,
    @"terminal-cols": u16 = 120,
    @"max-scrollback": usize = 10_000_000,
    data: ?[]const u8 = null,
    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }
};
pub const Mode = enum {
    noop,
    compress,
    incremental,
    restore,
    report,
};
pub fn create(
    alloc: Allocator,
    opts: Options,
) !*ScrollbackCompression {
    const ptr = try alloc.create(ScrollbackCompression);
    errdefer alloc.destroy(ptr);
    ptr.* = .{
        .opts = opts,
        .terminal = try .init(global.io(), alloc, .{
            .rows = opts.@"terminal-rows",
            .cols = opts.@"terminal-cols",
            .max_scrollback_bytes = opts.@"max-scrollback",
        }),
    };
    return ptr;
}
pub fn destroy(self: *ScrollbackCompression, alloc: Allocator) void {
    self.terminal.deinit(alloc);
    alloc.destroy(self);
}
pub fn benchmark(self: *ScrollbackCompression) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .noop => stepNoop,
            .compress => stepCompress,
            .incremental => stepIncremental,
            .restore => stepRestore,
            .report => stepReport,
        },
        .setupFn = setup,
    });
}
fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScrollbackCompression = @ptrCast(@alignCast(ptr));
    self.terminal.fullReset();
    self.loadCorpus() catch |err| {
        log.warn("failed to prepare scrollback compression benchmark err={}", .{err});
        return error.BenchmarkFailed;
    };
    if (self.opts.mode == .restore) {
        _ = self.pages().compress(.full);
    }
}
fn loadCorpus(self: *ScrollbackCompression) !void {
    const data_file = try options.dataFile(self.opts.data) orelse return;
    defer data_file.close(global.io());
    var stream = self.terminal.vtStream();
    defer stream.deinit();
    var read_buf: [64 * 1024]u8 align(std.atomic.cache_line) = undefined;
    var file_reader = data_file.reader(global.io(), &read_buf);
    const reader = &file_reader.interface;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&buf) catch
            return file_reader.err orelse error.ReadFailed;
        if (n == 0) return;
        stream.nextSlice(buf[0..n]);
    }
}
fn pages(self: *ScrollbackCompression) *PageList {
    return &self.terminal.screens.get(.primary).?.pages;
}
fn stepNoop(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScrollbackCompression = @ptrCast(@alignCast(ptr));
    std.mem.doNotOptimizeAway(&self.terminal);
}
fn stepCompress(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScrollbackCompression = @ptrCast(@alignCast(ptr));
    _ = self.pages().compress(.full);
    std.mem.doNotOptimizeAway(&self.terminal);
}
fn stepIncremental(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScrollbackCompression = @ptrCast(@alignCast(ptr));
    _ = self.pages().compress(.drain);
    std.mem.doNotOptimizeAway(&self.terminal);
}
fn stepRestore(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScrollbackCompression = @ptrCast(@alignCast(ptr));
    std.mem.doNotOptimizeAway(self.visitColdPages());
}
fn visitColdPages(self: *ScrollbackCompression) usize {
    const page_list = self.pages();
    const active_node = page_list.getTopLeft(.active).node;
    var visited: usize = 0;
    var node_ = page_list.pages.first;
    while (node_) |node| : (node_ = node.next) {
        if (node == active_node) break;
        std.mem.doNotOptimizeAway(node.page());
        visited += 1;
    }
    return visited;
}
fn stepReport(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScrollbackCompression = @ptrCast(@alignCast(ptr));
    _ = self.pages().compress(.full);
    const memory = self.pages().memoryStats();
    std.debug.print(
        "scrollback-compression compressed={d} raw={d} " ++
            "encoded={d} ratio={d:.2}% savings={d}\n",
        .{
            memory.compressed_pages,
            memory.decommitted_raw_bytes,
            memory.encoded_bytes,
            percentage(
                memory.encoded_bytes,
                memory.decommitted_raw_bytes,
            ),
            memory.estimatedSavings(),
        },
    );
}
fn percentage(part: usize, whole: usize) f64 {
    if (whole == 0) return 0;
    return @as(f64, @floatFromInt(part)) * 100 /
        @as(f64, @floatFromInt(whole));
}
test ScrollbackCompression {
    const testing = std.testing;
    const impl: *ScrollbackCompression = try .create(testing.allocator, .{});
    defer impl.destroy(testing.allocator);
    const bench = impl.benchmark();
    _ = try bench.run(.once);
}
test "ScrollbackCompression restores cold terminal pages" {
    const testing = std.testing;
    const impl: *ScrollbackCompression = try .create(testing.allocator, .{
        .mode = .restore,
        .@"terminal-rows" = 4,
        .@"terminal-cols" = 215,
        .@"max-scrollback" = 1_000_000,
    });
    defer impl.destroy(testing.allocator);
    var stream = impl.terminal.vtStream();
    defer stream.deinit();
    for (0..256) |_| stream.nextSlice("aaaa\r\n");
    _ = impl.pages().compress(.full);
    const compressed = impl.pages().memoryStats();
    try testing.expect(compressed.compressed_pages > 0);
    try testing.expect(impl.visitColdPages() >= compressed.compressed_pages);
    _ = impl.pages().compress(.full);
    const recompressed = impl.pages().memoryStats();
    try testing.expectEqual(
        compressed.compressed_pages,
        recompressed.compressed_pages,
    );
}
test "ScrollbackCompression drains incremental compression steps" {
    const testing = std.testing;
    const impl: *ScrollbackCompression = try .create(testing.allocator, .{
        .mode = .incremental,
        .@"terminal-rows" = 4,
        .@"terminal-cols" = 215,
        .@"max-scrollback" = 1_000_000,
    });
    defer impl.destroy(testing.allocator);
    var stream = impl.terminal.vtStream();
    defer stream.deinit();
    for (0..256) |_| stream.nextSlice("aaaa\r\n");
    _ = impl.pages().compress(.drain);
    const incremental = impl.pages().memoryStats();
    try testing.expect(incremental.compressed_pages > 0);
    _ = impl.visitColdPages();
    _ = impl.pages().compress(.full);
    const monolithic = impl.pages().memoryStats();
    try testing.expectEqual(monolithic, incremental);
}
