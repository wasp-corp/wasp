const Page = @This();
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const TerminalPage = @import("../page.zig").Page;
const lz4 = @import("lz4.zig");
page: TerminalPage,
encoded: []u8,
alloc: Allocator,
pub fn requiredScratch(raw_len: usize) lz4.CompressError!usize {
    _ = try lz4.compressBound(raw_len);
    const representation_overhead = @sizeOf(Page) - @sizeOf(TerminalPage);
    if (raw_len <= representation_overhead) return 0;
    return raw_len - representation_overhead - 1;
}
pub fn init(
    alloc: Allocator,
    source: *const TerminalPage,
    scratch: []u8,
    table: *lz4.HashTable,
) (Allocator.Error || lz4.CompressError)!?Page {
    const required = try requiredScratch(source.memory.len);
    if (scratch.len < required) return error.OutputTooSmall;
    if (required == 0) return null;
    if (std.valgrind.runningOnValgrind() > 0)
        std.valgrind.memcheck.makeMemDefined(source.memory);
    const encoded_len = lz4.compress(
        source.memory,
        scratch[0..required],
        table,
    ) catch |err| switch (err) {
        error.OutputTooSmall => return null,
        error.InputTooLarge => return err,
    };
    assert(@sizeOf(Page) + encoded_len <
        @sizeOf(TerminalPage) + source.memory.len);
    return .{
        .page = source.*,
        .encoded = try alloc.dupe(u8, scratch[0..encoded_len]),
        .alloc = alloc,
    };
}
pub fn deinit(self: *Page) void {
    self.alloc.free(self.encoded);
    self.* = undefined;
}
pub fn restore(self: *const Page) lz4.DecompressError!TerminalPage {
    const result = self.page;
    _ = try lz4.decompress(self.encoded, result.memory);
    return result;
}
pub fn cloneBuf(
    self: *const Page,
    memory: []align(std.heap.page_size_min) u8,
) lz4.DecompressError!TerminalPage {
    assert(memory.len >= self.page.memory.len);
    var result = self.page;
    result.memory = memory[0..self.page.memory.len];
    _ = try lz4.decompress(self.encoded, result.memory);
    return result;
}
test "compressed Page retained mapping round trip" {
    const testing = std.testing;
    var resident = try TerminalPage.init(.{
        .cols = 12,
        .rows = 9,
        .styles = 8,
        .grapheme_bytes = 128,
        .string_bytes = 128,
    });
    defer resident.deinit();
    resident.size = .{ .cols = 10, .rows = 7 };
    resident.dirty = true;
    const rac = resident.getRowAndCell(2, 3);
    rac.cell.* = .init('A');
    try resident.appendGrapheme(rac.row, rac.cell, 0x0301);
    const style_id = try resident.styles.add(resident.memory, .{ .flags = .{
        .bold = true,
    } });
    rac.cell.style_id = style_id;
    rac.row.styled = true;
    const hyperlink_id = try resident.insertHyperlink(.{
        .id = .{ .explicit = "compressed-page" },
        .uri = "https://wasp.org/docs",
    });
    try resident.setHyperlink(rac.row, rac.cell, hyperlink_id);
    try resident.verifyIntegrity(testing.allocator);
    const expected = try testing.allocator.dupe(u8, resident.memory);
    defer testing.allocator.free(expected);
    if (std.valgrind.runningOnValgrind() > 0) {
        std.valgrind.memcheck.makeMemDefined(expected);
    }
    const memory_ptr = resident.memory.ptr;
    const memory_len = resident.memory.len;
    const scratch = try testing.allocator.alloc(
        u8,
        try requiredScratch(resident.memory.len),
    );
    defer testing.allocator.free(scratch);
    var table: lz4.HashTable = undefined;
    var compressed = (try Page.init(
        testing.allocator,
        &resident,
        scratch,
        &table,
    )).?;
    defer compressed.deinit();
    try testing.expectEqual(memory_ptr, compressed.page.memory.ptr);
    try testing.expectEqual(memory_len, compressed.page.memory.len);
    try testing.expect(compressed.encoded.len < resident.memory.len);
    const expected_encoded = try testing.allocator.dupe(u8, compressed.encoded);
    defer testing.allocator.free(expected_encoded);
    @memset(resident.memory, 0);
    const clone_memory = try testing.allocator.alignedAlloc(
        u8,
        .fromByteUnits(std.heap.page_size_min),
        resident.memory.len,
    );
    defer testing.allocator.free(clone_memory);
    const cloned = try compressed.cloneBuf(clone_memory);
    try testing.expect(cloned.memory.ptr != memory_ptr);
    try testing.expect(std.mem.allEqual(u8, resident.memory, 0));
    try testing.expectEqualSlices(u8, expected_encoded, compressed.encoded);
    try testing.expectEqualSlices(u8, expected, cloned.memory);
    try testing.expectEqual(resident.size, cloned.size);
    try testing.expect(cloned.dirty);
    try cloned.verifyIntegrity(testing.allocator);
    const restored = try compressed.restore();
    try testing.expectEqual(memory_ptr, restored.memory.ptr);
    try testing.expectEqual(memory_len, restored.memory.len);
    try testing.expectEqualSlices(u8, expected, restored.memory);
    try testing.expectEqual(resident.size, restored.size);
    try testing.expect(restored.dirty);
    try restored.verifyIntegrity(testing.allocator);
    const restored_rac = restored.getRowAndCell(2, 3);
    try testing.expectEqualSlices(
        u21,
        &.{0x0301},
        restored.lookupGrapheme(restored_rac.cell).?,
    );
    try testing.expect(restored.styles.get(
        restored.memory,
        restored_rac.cell.style_id,
    ).flags.bold);
    const restored_hyperlink_id = restored.lookupHyperlink(restored_rac.cell).?;
    const restored_hyperlink = restored.hyperlink_set.get(
        restored.memory,
        restored_hyperlink_id,
    );
    try testing.expectEqualStrings(
        "https://wasp.org/docs",
        restored_hyperlink.uri.slice(restored.memory),
    );
}
test "compressed Page requires the maximum useful scratch" {
    const testing = std.testing;
    var resident = try TerminalPage.init(.{ .cols = 4, .rows = 4 });
    defer resident.deinit();
    const expected = try testing.allocator.dupe(u8, resident.memory);
    defer testing.allocator.free(expected);
    const required = try requiredScratch(resident.memory.len);
    try testing.expectEqual(
        resident.memory.len - (@sizeOf(Page) - @sizeOf(TerminalPage)) - 1,
        required,
    );
    try testing.expect(required < try lz4.compressBound(resident.memory.len));
    const scratch = try testing.allocator.alloc(u8, required - 1);
    defer testing.allocator.free(scratch);
    var table: lz4.HashTable = undefined;
    try testing.expectError(error.OutputTooSmall, Page.init(
        testing.allocator,
        &resident,
        scratch,
        &table,
    ));
    try testing.expectEqualSlices(u8, expected, resident.memory);
}
test "compressed Page rejects a representation without savings" {
    const testing = std.testing;
    var resident = try TerminalPage.init(.{
        .cols = 4,
        .rows = 4,
        .styles = 0,
        .grapheme_bytes = 0,
        .string_bytes = 0,
        .hyperlink_bytes = 0,
    });
    defer resident.deinit();
    var prng = std.Random.DefaultPrng.init(0x4C5A_3402);
    prng.random().bytes(resident.memory);
    const scratch = try testing.allocator.alloc(
        u8,
        try requiredScratch(resident.memory.len),
    );
    defer testing.allocator.free(scratch);
    var table: lz4.HashTable = undefined;
    var failing = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });
    try testing.expect((try Page.init(
        failing.allocator(),
        &resident,
        scratch,
        &table,
    )) == null);
    try testing.expect(!failing.has_induced_failure);
}
test "compressed Page can retry after malformed encoded data" {
    const testing = std.testing;
    var resident = try TerminalPage.init(.{ .cols = 8, .rows = 8 });
    defer resident.deinit();
    const expected = try testing.allocator.dupe(u8, resident.memory);
    defer testing.allocator.free(expected);
    const scratch = try testing.allocator.alloc(
        u8,
        try requiredScratch(resident.memory.len),
    );
    defer testing.allocator.free(scratch);
    var table: lz4.HashTable = undefined;
    var compressed = (try Page.init(
        testing.allocator,
        &resident,
        scratch,
        &table,
    )).?;
    defer compressed.deinit();
    const full_encoded = compressed.encoded;
    const first_byte = full_encoded[0];
    defer {
        compressed.encoded = full_encoded;
        compressed.encoded[0] = first_byte;
    }
    compressed.encoded = full_encoded[0..1];
    compressed.encoded[0] = 0xF0;
    const clone_memory = try testing.allocator.alignedAlloc(
        u8,
        .fromByteUnits(std.heap.page_size_min),
        resident.memory.len,
    );
    defer testing.allocator.free(clone_memory);
    try testing.expectError(
        error.TruncatedInput,
        compressed.cloneBuf(clone_memory),
    );
    try testing.expectError(error.TruncatedInput, compressed.restore());
    compressed.encoded = full_encoded;
    compressed.encoded[0] = first_byte;
    @memset(resident.memory, 0);
    const restored = try compressed.restore();
    try testing.expectEqualSlices(u8, expected, restored.memory);
}
