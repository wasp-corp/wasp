const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    if (args.len != 3) {
        std.log.err("usage: wasm_growable_table <input.wasm> <output.wasm>", .{});
        std.process.exit(1);
        unreachable;
    }
    const output: []const u8 = try patchTableGrowable(
        alloc,
        try std.Io.Dir.cwd().readFileAlloc(
            init.io,
            args[1],
            alloc,
            .unlimited,
        ),
    );
    const out_file = try std.Io.Dir.cwd().createFile(init.io, args[2], .{});
    defer out_file.close(init.io);
    try out_file.writePositionalAll(init.io, output, 0);
}
fn patchTableGrowable(
    alloc: Allocator,
    input: []const u8,
) (error{InvalidWasm} || std.Io.Writer.Error)![]const u8 {
    if (input.len < 8) return error.InvalidWasm;
    var pos: usize = 8;
    while (pos < input.len) {
        const section_id = input[pos];
        pos += 1;
        const section_size = readLeb128(input, &pos);
        const section_start = pos;
        if (section_id != 4) {
            pos = section_start + section_size;
            continue;
        }
        _ = readLeb128(input, &pos); 
        pos += 1; 
        const flags = input[pos];
        if (flags & 1 == 0) {
            return input;
        }
        const flags_pos = pos;
        pos += 1; 
        const min_start = pos;
        _ = readLeb128(input, &pos); 
        const max_start = pos;
        _ = readLeb128(input, &pos); 
        const max_end = pos;
        const section_end = section_start + section_size;
        var payload: std.Io.Writer.Allocating = .init(alloc);
        try payload.writer.writeAll(input[section_start..flags_pos]);
        try payload.writer.writeByte(0x00); 
        try payload.writer.writeAll(input[min_start..max_start]);
        try payload.writer.writeAll(input[max_end..section_end]);
        const before_section = input[0 .. section_start - 1 - uleb128Size(section_size)];
        var result: std.Io.Writer.Allocating = .init(alloc);
        try result.writer.writeAll(before_section);
        try result.writer.writeByte(4); 
        try result.writer.writeUleb128(@as(u32, @intCast(payload.written().len)));
        try result.writer.writeAll(payload.written());
        try result.writer.writeAll(input[section_end..]);
        return result.written();
    }
    return input;
}
fn readLeb128(bytes: []const u8, pos: *usize) u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        const byte = bytes[pos.*];
        pos.* += 1;
        result |= @as(u32, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return result;
        shift +%= 7;
    }
}
fn uleb128Size(value: u32) usize {
    var v = value;
    var size: usize = 0;
    while (true) {
        v >>= 7;
        size += 1;
        if (v == 0) return size;
    }
}
const test_wasm_bounded_table = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 
    0x01, 0x00, 0x00, 0x00, 
    0x01, 0x04, 0x01, 0x60,
    0x00, 0x00,
    0x04, 0x05,
    0x01, 0x70, 0x01, 0x01,
    0x01,
    0x07, 0x01, 0x00,
};
const test_wasm_growable_table = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 
    0x01, 0x00, 0x00, 0x00, 
    0x01, 0x04, 0x01, 0x60,
    0x00, 0x00,
    0x04, 0x04,
    0x01, 0x70, 0x00, 0x01,
    0x07, 0x01, 0x00,
};
const test_wasm_no_table = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 
    0x01, 0x00, 0x00, 0x00, 
    0x01, 0x04, 0x01, 0x60,
    0x00, 0x00,
    0x07, 0x01,
    0x00,
};
test "patches bounded table to remove max" {
    const result = try patchTableGrowable(
        std.heap.page_allocator,
        &test_wasm_bounded_table,
    );
    try testing.expect(!std.mem.eql(
        u8,
        result,
        &test_wasm_bounded_table,
    ));
    var pos: usize = 8;
    while (pos < result.len) {
        const id = result[pos];
        pos += 1;
        const size = readLeb128(result, &pos);
        if (id == 4) {
            _ = readLeb128(result, &pos); 
            pos += 1; 
            try testing.expectEqual(@as(u8, 0x00), result[pos]);
            return;
        }
        pos += size;
    }
    return error.TableSectionNotFound;
}
test "already growable table is returned unchanged" {
    const result = try patchTableGrowable(
        testing.allocator,
        &test_wasm_growable_table,
    );
    try testing.expectEqual(
        @as([*]const u8, &test_wasm_growable_table),
        result.ptr,
    );
}
test "no table section returns input unchanged" {
    const result = try patchTableGrowable(
        testing.allocator,
        &test_wasm_no_table,
    );
    try testing.expectEqual(@as([*]const u8, &test_wasm_no_table), result.ptr);
}
test "too short input returns InvalidWasm" {
    try testing.expectError(
        error.InvalidWasm,
        patchTableGrowable(testing.allocator, "short"),
    );
}
test "readLeb128 single byte" {
    const bytes = [_]u8{0x05};
    var pos: usize = 0;
    try testing.expectEqual(@as(u32, 5), readLeb128(&bytes, &pos));
    try testing.expectEqual(@as(usize, 1), pos);
}
test "readLeb128 multi byte" {
    const bytes = [_]u8{ 0xAC, 0x02 };
    var pos: usize = 0;
    try testing.expectEqual(@as(u32, 300), readLeb128(&bytes, &pos));
    try testing.expectEqual(@as(usize, 2), pos);
}
test "uleb128Size" {
    try testing.expectEqual(@as(usize, 1), uleb128Size(0));
    try testing.expectEqual(@as(usize, 1), uleb128Size(0x7f));
    try testing.expectEqual(@as(usize, 2), uleb128Size(0x80));
    try testing.expectEqual(@as(usize, 2), uleb128Size(300));
    try testing.expectEqual(@as(usize, 5), uleb128Size(std.math.maxInt(u32)));
}
