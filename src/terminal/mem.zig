const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const windows = @import("../os/windows.zig");
const log = std.log.scoped(.terminal_mem);
pub const DecommitMode = enum {
    zero,
    strict,
};
pub inline fn canReclaim(comptime mode: DecommitMode) bool {
    return switch (mode) {
        .zero, .strict => supported: {
            if (builtin.is_test) break :supported true;
            if (builtin.target.ptrBitWidth() != 64) break :supported false;
            if (builtin.target.os.tag == .linux) break :supported true;
            if (builtin.target.os.tag.isDarwin()) break :supported true;
            if (builtin.target.os.tag == .windows) break :supported true;
            break :supported false;
        },
    };
}
pub fn decommit(
    comptime mode: DecommitMode,
    memory: []align(std.heap.page_size_min) u8,
    dirty_len: usize,
) bool {
    assert(memory.len > 0);
    assert(@intFromPtr(memory.ptr) % std.heap.page_size_min == 0);
    assert(memory.len % std.heap.page_size_min == 0);
    assert(dirty_len <= memory.len);
    if (comptime mode == .strict) assert(dirty_len == memory.len);
    if (comptime builtin.is_test) {
        @memset(memory[0..dirty_len], 0);
        return true;
    }
    if (comptime builtin.os.tag == .linux) {
        if (std.posix.madvise(
            memory.ptr,
            memory.len,
            std.posix.MADV.DONTNEED,
        )) |_| return true else |err| {
            log.warn("madvise(DONTNEED) failed err={}", .{err});
            if (comptime mode == .strict) return false;
        }
    }
    if (comptime builtin.os.tag.isDarwin()) {
        if (comptime mode == .zero) @memset(memory[0..dirty_len], 0);
        if (std.posix.madvise(
            memory.ptr,
            memory.len,
            std.posix.MADV.FREE_REUSABLE,
        )) |_| return true else |err| {
            switch (mode) {
                .strict => {
                    log.warn("madvise(FREE_REUSABLE) failed err={}", .{err});
                    return false;
                },
                .zero => {
                    std.posix.madvise(
                        memory.ptr,
                        memory.len,
                        std.posix.MADV.FREE,
                    ) catch {};
                    return false;
                },
            }
        }
    }
    if (comptime builtin.os.tag == .windows) {
        if (comptime mode == .zero) @memset(memory[0..dirty_len], 0);
        const rc = windows.exp.kernel32.DiscardVirtualMemory(
            memory.ptr,
            memory.len,
        );
        if (rc == windows.ERROR_SUCCESS) return true;
        log.warn("DiscardVirtualMemory failed err={d}", .{rc});
        return false;
    }
    if (comptime mode == .zero) @memset(memory[0..dirty_len], 0);
    return false;
}
pub fn recommit(memory: []align(std.heap.page_size_min) u8) void {
    assert(memory.len > 0);
    assert(@intFromPtr(memory.ptr) % std.heap.page_size_min == 0);
    assert(memory.len % std.heap.page_size_min == 0);
    if (comptime builtin.is_test) return;
    if (comptime builtin.os.tag.isDarwin()) {
        std.posix.madvise(
            memory.ptr,
            memory.len,
            std.posix.MADV.FREE_REUSE,
        ) catch |err| {
            log.warn("madvise(FREE_REUSE) failed err={}", .{err});
        };
    }
}
test "decommit with zero fallback clears the dirty prefix" {
    const testing = std.testing;
    const memory_len = 2 * std.heap.page_size_min;
    const memory = try testing.allocator.alignedAlloc(
        u8,
        .fromByteUnits(std.heap.page_size_min),
        memory_len,
    );
    defer testing.allocator.free(memory);
    @memset(memory, 0xAA);
    _ = decommit(.zero, memory, memory.len);
    try testing.expect(std.mem.allEqual(u8, memory, 0));
    @memset(memory[0..1024], 0xAA);
    _ = decommit(.zero, memory, 1024);
    try testing.expect(std.mem.allEqual(u8, memory, 0));
}
test "strict decommit retains the mapping for recommit" {
    const testing = std.testing;
    const memory_len = 2 * std.heap.page_size_min;
    const memory = try testing.allocator.alignedAlloc(
        u8,
        .fromByteUnits(std.heap.page_size_min),
        memory_len,
    );
    defer testing.allocator.free(memory);
    @memset(memory, 0xAA);
    const original_ptr = memory.ptr;
    const original_len = memory.len;
    try testing.expect(decommit(.strict, memory, memory.len));
    try testing.expectEqual(original_ptr, memory.ptr);
    try testing.expectEqual(original_len, memory.len);
    try testing.expect(std.mem.allEqual(u8, memory, 0));
    recommit(memory);
    @memset(memory, 0xBB);
    try testing.expect(std.mem.allEqual(u8, memory, 0xBB));
}
test "test builds can reclaim retained mappings" {
    const testing = std.testing;
    try testing.expect(canReclaim(.zero));
    try testing.expect(canReclaim(.strict));
}
