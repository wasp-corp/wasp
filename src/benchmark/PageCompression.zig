const PageCompression = @This();
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const compress = @import("../terminal/compress.zig");
const CompressedPage = compress.Page;
const lz4 = compress.lz4;
const compat_file = @import("../lib/compat/file.zig");
const global = @import("../global.zig");
const log = std.log.scoped(.@"page-compression-bench");
const max_data_size = 64 * 1024 * 1024;
alloc: Allocator,
opts: Options,
data: []u8 = &.{},
encoded: std.ArrayList(Encoded) = .empty,
stored: []?[]u8 = &.{},
stored_next: usize = 0,
compression_output: []u8 = &.{},
decompression_output: []u8 = &.{},
table: lz4.HashTable = undefined,
pub const Options = struct {
    _arena: ?std.heap.ArenaAllocator = null,
    mode: Mode = .compress,
    loops: u32 = 1,
    @"page-size": usize = 400 * 1024,
    @"retained-pages": usize = 25,
    data: ?[]const u8 = null,
    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }
};
pub const Mode = enum {
    noop,
    compress,
    store,
    decompress,
    report,
};
const Encoded = struct {
    bytes: []u8,
    raw_len: usize,
};
pub fn create(
    alloc: Allocator,
    opts: Options,
) !*PageCompression {
    const ptr = try alloc.create(PageCompression);
    ptr.* = .{
        .alloc = alloc,
        .opts = opts,
    };
    return ptr;
}
pub fn destroy(self: *PageCompression, alloc: Allocator) void {
    self.clearPreparedData();
    alloc.destroy(self);
}
pub fn benchmark(self: *PageCompression) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .noop => stepNoop,
            .compress => stepCompress,
            .store => stepStore,
            .decompress => stepDecompress,
            .report => stepReport,
        },
        .setupFn = setup,
        .teardownFn = teardown,
    });
}
fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *PageCompression = @ptrCast(@alignCast(ptr));
    assert(self.data.len == 0);
    assert(self.encoded.items.len == 0);
    self.setupData() catch |err| {
        log.warn("failed to prepare page compression benchmark err={}", .{err});
        return error.BenchmarkFailed;
    };
}
fn setupData(self: *PageCompression) !void {
    if (self.opts.loops == 0) return error.InvalidLoops;
    if (self.opts.@"page-size" == 0) return error.InvalidPageSize;
    if (self.opts.mode == .store and self.opts.@"retained-pages" == 0)
        return error.InvalidRetainedPages;
    const data_file = try options.dataFile(self.opts.data) orelse return;
    defer data_file.close(global.io());
    self.data = try compat_file.readToEndAlloc(data_file, self.alloc, max_data_size);
    errdefer {
        self.alloc.free(self.data);
        self.data = &.{};
    }
    if (self.data.len == 0) return;
    if (self.opts.mode == .noop) return;
    const largest_page = @min(self.opts.@"page-size", self.data.len);
    self.compression_output = try self.alloc.alloc(
        u8,
        try lz4.compressBound(largest_page),
    );
    errdefer {
        self.alloc.free(self.compression_output);
        self.compression_output = &.{};
    }
    if (self.opts.mode == .store) try self.prepareStored();
    if (self.opts.mode == .decompress) try self.prepareEncoded();
}
fn prepareStored(self: *PageCompression) !void {
    self.stored = try self.alloc.alloc(?[]u8, self.opts.@"retained-pages");
    @memset(self.stored, null);
    self.stored_next = 0;
}
fn prepareEncoded(self: *PageCompression) !void {
    self.decompression_output = try self.alloc.alloc(
        u8,
        @min(self.opts.@"page-size", self.data.len),
    );
    errdefer {
        self.alloc.free(self.decompression_output);
        self.decompression_output = &.{};
    }
    var it = self.pages();
    while (it.next()) |page| {
        const encoded_len = try lz4.compress(
            page,
            self.compression_output,
            &self.table,
        );
        const encoded = try self.alloc.dupe(
            u8,
            self.compression_output[0..encoded_len],
        );
        self.encoded.append(self.alloc, .{
            .bytes = encoded,
            .raw_len = page.len,
        }) catch |err| {
            self.alloc.free(encoded);
            return err;
        };
    }
    var page_it = self.pages();
    for (self.encoded.items) |block| {
        const page = page_it.next().?;
        const output = self.decompression_output[0..block.raw_len];
        _ = try lz4.decompress(block.bytes, output);
        if (!std.mem.eql(u8, page, output)) return error.RoundTripMismatch;
    }
}
fn clearPreparedData(self: *PageCompression) void {
    for (self.encoded.items) |block| self.alloc.free(block.bytes);
    self.encoded.deinit(self.alloc);
    self.encoded = .empty;
    for (self.stored) |block| if (block) |bytes| self.alloc.free(bytes);
    if (self.stored.len > 0) self.alloc.free(self.stored);
    self.stored = &.{};
    self.stored_next = 0;
    if (self.compression_output.len > 0)
        self.alloc.free(self.compression_output);
    self.compression_output = &.{};
    if (self.decompression_output.len > 0)
        self.alloc.free(self.decompression_output);
    self.decompression_output = &.{};
    if (self.data.len > 0) self.alloc.free(self.data);
    self.data = &.{};
}
fn teardown(ptr: *anyopaque) void {
    const self: *PageCompression = @ptrCast(@alignCast(ptr));
    self.clearPreparedData();
}
fn stepNoop(ptr: *anyopaque) Benchmark.Error!void {
    const self: *PageCompression = @ptrCast(@alignCast(ptr));
    for (0..self.opts.loops) |_| {
        var it = self.pages();
        while (it.next()) |page| std.mem.doNotOptimizeAway(page);
    }
}
fn stepCompress(ptr: *anyopaque) Benchmark.Error!void {
    const self: *PageCompression = @ptrCast(@alignCast(ptr));
    for (0..self.opts.loops) |_| {
        var it = self.pages();
        while (it.next()) |page| {
            const encoded_len = lz4.compress(
                page,
                self.compression_output,
                &self.table,
            ) catch |err| {
                log.warn("page compression failed err={}", .{err});
                return error.BenchmarkFailed;
            };
            std.mem.doNotOptimizeAway(encoded_len);
        }
    }
}
fn stepStore(ptr: *anyopaque) Benchmark.Error!void {
    const self: *PageCompression = @ptrCast(@alignCast(ptr));
    if (self.data.len == 0) return;
    assert(self.stored.len > 0);
    for (0..self.opts.loops) |_| {
        var it = self.pages();
        while (it.next()) |page| {
            const output_len = CompressedPage.requiredScratch(page.len) catch |err| {
                log.warn("failed to size stored page output err={}", .{err});
                return error.BenchmarkFailed;
            };
            if (output_len == 0) continue;
            const encoded_len = lz4.compress(
                page,
                self.compression_output[0..output_len],
                &self.table,
            ) catch |err| switch (err) {
                error.OutputTooSmall => continue,
                error.InputTooLarge => {
                    log.warn("stored page compression failed err={}", .{err});
                    return error.BenchmarkFailed;
                },
            };
            const encoded = self.alloc.dupe(
                u8,
                self.compression_output[0..encoded_len],
            ) catch |err| {
                log.warn("stored page allocation failed err={}", .{err});
                return error.BenchmarkFailed;
            };
            const slot = &self.stored[self.stored_next];
            if (slot.*) |previous| self.alloc.free(previous);
            slot.* = encoded;
            self.stored_next = (self.stored_next + 1) % self.stored.len;
            std.mem.doNotOptimizeAway(encoded);
        }
    }
}
fn stepDecompress(ptr: *anyopaque) Benchmark.Error!void {
    const self: *PageCompression = @ptrCast(@alignCast(ptr));
    for (0..self.opts.loops) |_| {
        for (self.encoded.items) |block| {
            const output = self.decompression_output[0..block.raw_len];
            _ = lz4.decompress(block.bytes, output) catch |err| {
                log.warn("page decompression failed err={}", .{err});
                return error.BenchmarkFailed;
            };
            std.mem.doNotOptimizeAway(output);
        }
    }
}
fn stepReport(ptr: *anyopaque) Benchmark.Error!void {
    const self: *PageCompression = @ptrCast(@alignCast(ptr));
    if (self.data.len == 0) return;
    var page_index: usize = 0;
    var raw_total: usize = 0;
    var encoded_total: usize = 0;
    var it = self.pages();
    while (it.next()) |page| : (page_index += 1) {
        const encoded_len = lz4.compress(
            page,
            self.compression_output,
            &self.table,
        ) catch |err| {
            log.warn("page compression report failed err={}", .{err});
            return error.BenchmarkFailed;
        };
        raw_total += page.len;
        encoded_total += encoded_len;
        std.debug.print(
            "page-compression page={d} raw={d} encoded={d} ratio={d:.2}%\n",
            .{ page_index, page.len, encoded_len, percentage(encoded_len, page.len) },
        );
    }
    std.debug.print(
        "page-compression total pages={d} raw={d} encoded={d} ratio={d:.2}% " ++
            "workspace={d} output_bound={d}\n",
        .{
            page_index,
            raw_total,
            encoded_total,
            percentage(encoded_total, raw_total),
            @sizeOf(lz4.HashTable),
            self.compression_output.len,
        },
    );
}
fn pages(self: *const PageCompression) PageIterator {
    return .{
        .data = self.data,
        .page_size = self.opts.@"page-size",
    };
}
const PageIterator = struct {
    data: []const u8,
    page_size: usize,
    offset: usize = 0,
    fn next(self: *PageIterator) ?[]const u8 {
        if (self.offset >= self.data.len) return null;
        const len = @min(self.page_size, self.data.len - self.offset);
        const end = self.offset + len;
        defer self.offset = end;
        return self.data[self.offset..end];
    }
};
fn percentage(part: usize, whole: usize) f64 {
    if (whole == 0) return 0;
    return @as(f64, @floatFromInt(part)) * 100 /
        @as(f64, @floatFromInt(whole));
}
test PageCompression {
    const testing = std.testing;
    const impl: *PageCompression = try .create(testing.allocator, .{});
    defer impl.destroy(testing.allocator);
    const bench = impl.benchmark();
    _ = try bench.run(.once);
}
test "PageCompression store retains exact encoded allocations" {
    const testing = std.testing;
    const page_size = 1024;
    const impl: *PageCompression = try .create(testing.allocator, .{
        .mode = .store,
        .@"page-size" = page_size,
        .@"retained-pages" = 2,
    });
    defer impl.destroy(testing.allocator);
    impl.data = try testing.allocator.alloc(u8, 3 * page_size);
    @memset(impl.data, 0);
    impl.compression_output = try testing.allocator.alloc(
        u8,
        try lz4.compressBound(page_size),
    );
    try impl.prepareStored();
    try stepStore(impl);
    try testing.expectEqual(@as(usize, 1), impl.stored_next);
    for (impl.stored) |block| {
        const encoded = block.?;
        try testing.expect(encoded.len < page_size);
        var decoded: [page_size]u8 = undefined;
        _ = try lz4.decompress(encoded, &decoded);
        try testing.expect(std.mem.allEqual(u8, &decoded, 0));
    }
}
