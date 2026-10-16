const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
pub const max_input_size: usize = 0x7E000000;
const min_match = 4;
const last_literals = 5;
const match_find_limit = 12;
const hash_log = 12;
const hash_multiplier: u32 = 2_654_435_761;
pub const HashTable = [1 << hash_log]u32;
pub const CompressError = error{
    InputTooLarge,
    OutputTooSmall,
};
pub const DecompressError = error{
    TruncatedInput,
    InvalidOffset,
    OutputTooSmall,
    OutputSizeMismatch,
};
pub fn compressBound(input_len: usize) CompressError!usize {
    if (input_len > max_input_size) return error.InputTooLarge;
    return input_len + input_len / 255 + 16;
}
pub fn compress(
    input: []const u8,
    output: []u8,
    table: *HashTable,
) CompressError!usize {
    if (input.len > max_input_size) return error.InputTooLarge;
    @memset(table, std.math.maxInt(u32));
    var op: usize = 0;
    var anchor: usize = 0;
    if (input.len >= match_find_limit) {
        const search_end = input.len - match_find_limit;
        const match_end_limit = input.len - last_literals;
        var ip: usize = 0;
        var search_attempts: usize = 0;
        search: while (ip <= search_end) {
            const sequence = readU32(input, ip);
            const hash = hashSequence(sequence);
            const candidates = table[hash];
            rememberPosition(table, hash, ip);
            var match_pos = candidatePosition(ip, @truncate(candidates)) orelse
                candidatePosition(ip, @truncate(candidates >> 16)) orelse
                {
                    advanceSearch(&ip, anchor, &search_attempts);
                    continue :search;
                };
            if (readU32(input, match_pos) != sequence) {
                match_pos = older: {
                    if (candidatePosition(
                        ip,
                        @truncate(candidates >> 16),
                    )) |older| {
                        if (readU32(input, older) == sequence and
                            input[older + min_match] == input[ip + min_match])
                        {
                            break :older older;
                        }
                    }
                    advanceSearch(&ip, anchor, &search_attempts);
                    continue :search;
                };
            }
            const match_begin = matchBegin(input, ip, match_pos, anchor);
            ip = match_begin.position;
            match_pos = match_begin.candidate;
            const match_end = matchEnd(
                input,
                ip + min_match,
                match_pos + min_match,
                match_end_limit,
            );
            try emitSequence(
                output,
                &op,
                input[anchor..ip],
                @intCast(ip - match_pos),
                match_end - ip,
            );
            if (match_end >= 2 and match_end - 2 + min_match <= input.len) {
                const seed = match_end - 2;
                rememberPosition(
                    table,
                    hashSequence(readU32(input, seed)),
                    seed,
                );
            }
            ip = match_end;
            anchor = ip;
            search_attempts = 0;
        }
    }
    try emitLastLiterals(output, &op, input[anchor..]);
    return op;
}
pub fn decompress(input: []const u8, output: []u8) DecompressError!usize {
    var ip: usize = 0;
    var op: usize = 0;
    while (true) {
        if (ip == input.len) {
            if (op != output.len) return error.OutputSizeMismatch;
            return op;
        }
        const token = input[ip];
        ip += 1;
        const literal_len: usize = len: {
            const nibble: usize = token >> 4;
            if (nibble != 15 and
                @min(input.len - ip, output.len - op) >= 16)
            {
                copyIntAt(u128, output, op, input, ip);
                break :len nibble;
            }
            const len = try decodeLength(input, &ip, nibble);
            if (len > input.len - ip) return error.TruncatedInput;
            if (len > output.len - op) return error.OutputTooSmall;
            @memcpy(output[op..][0..len], input[ip..][0..len]);
            break :len len;
        };
        ip += literal_len;
        op += literal_len;
        if (ip == input.len) {
            if (op != output.len) return error.OutputSizeMismatch;
            return op;
        }
        if (input.len - ip < 2) return error.TruncatedInput;
        const offset = readIntAt(u16, input, ip);
        ip += 2;
        if (offset == 0 or offset > op) return error.InvalidOffset;
        const match_nibble: usize = token & 0x0F;
        if (match_nibble != 15 and offset >= 8 and output.len - op >= 18) {
            const match = op - offset;
            copyIntAt(u64, output, op, output, match);
            copyIntAt(u64, output, op + 8, output, match + 8);
            copyIntAt(u16, output, op + 16, output, match + 16);
            op += match_nibble + min_match;
            continue;
        }
        const encoded_match_len = try decodeLength(input, &ip, match_nibble);
        const match_len = std.math.add(
            usize,
            encoded_match_len,
            min_match,
        ) catch return error.OutputTooSmall;
        if (match_len > output.len - op) return error.OutputTooSmall;
        copyMatch(output, op, offset, match_len);
        op += match_len;
    }
}
fn emitSequence(
    output: []u8,
    op: *usize,
    literals: []const u8,
    offset: u16,
    match_len: usize,
) CompressError!void {
    assert(match_len >= min_match);
    assert(offset > 0);
    const encoded_match_len = match_len - min_match;
    const required = 1 +
        encodedLengthBytes(literals.len) + literals.len +
        2 + encodedLengthBytes(encoded_match_len);
    if (required > output.len - op.*) return error.OutputTooSmall;
    const token_pos = op.*;
    op.* += 1;
    output[token_pos] = (@as(u8, @intCast(@min(literals.len, 15))) << 4) |
        @as(u8, @intCast(@min(encoded_match_len, 15)));
    if (literals.len >= 15) writeLength(output, op, literals.len - 15);
    @memcpy(output[op.*..][0..literals.len], literals);
    op.* += literals.len;
    writeIntAt(u16, output, op.*, offset);
    op.* += 2;
    if (encoded_match_len >= 15)
        writeLength(output, op, encoded_match_len - 15);
}
fn emitLastLiterals(
    output: []u8,
    op: *usize,
    literals: []const u8,
) CompressError!void {
    const required = 1 + encodedLengthBytes(literals.len) + literals.len;
    if (required > output.len - op.*) return error.OutputTooSmall;
    output[op.*] = @as(u8, @intCast(@min(literals.len, 15))) << 4;
    op.* += 1;
    if (literals.len >= 15) writeLength(output, op, literals.len - 15);
    @memcpy(output[op.*..][0..literals.len], literals);
    op.* += literals.len;
}
fn encodedLengthBytes(encoded_len: usize) usize {
    if (encoded_len < 15) return 0;
    return (encoded_len - 15) / 255 + 1;
}
fn writeLength(output: []u8, op: *usize, length_: usize) void {
    var length = length_;
    while (length >= 255) {
        output[op.*] = 255;
        op.* += 1;
        length -= 255;
    }
    output[op.*] = @intCast(length);
    op.* += 1;
}
fn decodeLength(
    input: []const u8,
    ip: *usize,
    nibble: usize,
) DecompressError!usize {
    var length: usize = nibble;
    if (nibble != 15) return length;
    while (true) {
        if (ip.* >= input.len) return error.TruncatedInput;
        const value = input[ip.*];
        ip.* += 1;
        length = std.math.add(usize, length, value) catch
            return error.TruncatedInput;
        if (value != 255) return length;
    }
}
inline fn readIntAt(
    comptime Int: type,
    input: []const u8,
    position: usize,
) Int {
    return std.mem.readInt(
        Int,
        input[position..][0..@sizeOf(Int)],
        .little,
    );
}
inline fn writeIntAt(
    comptime Int: type,
    output: []u8,
    position: usize,
    value: Int,
) void {
    std.mem.writeInt(
        Int,
        output[position..][0..@sizeOf(Int)],
        value,
        .little,
    );
}
inline fn copyIntAt(
    comptime Int: type,
    output: []u8,
    output_position: usize,
    input: []const u8,
    input_position: usize,
) void {
    writeIntAt(
        Int,
        output,
        output_position,
        readIntAt(Int, input, input_position),
    );
}
inline fn readU32(input: []const u8, pos: usize) u32 {
    return readIntAt(u32, input, pos);
}
inline fn rememberPosition(table: *HashTable, hash: usize, position: usize) void {
    const low: u16 = @truncate(position);
    if (low == std.math.maxInt(u16)) return;
    table[hash] = (@as(u32, @truncate(table[hash])) << 16) | low;
}
inline fn candidatePosition(ip: usize, stored: u16) ?usize {
    if (stored == std.math.maxInt(u16)) return null;
    const distance: u16 = @as(u16, @truncate(ip)) -% stored;
    if (distance == 0) return null;
    return ip - distance;
}
inline fn advanceSearch(
    ip: *usize,
    anchor: usize,
    attempts: *usize,
) void {
    if (attempts.* == 0) {
        ip.* += 1;
        if (ip.* - anchor == 1024) attempts.* = 1;
        return;
    }
    attempts.* += 1;
    ip.* += 1 + attempts.* / 64;
}
fn matchBegin(
    input: []const u8,
    position_: usize,
    candidate_: usize,
    anchor: usize,
) struct { position: usize, candidate: usize } {
    var position = position_;
    var candidate = candidate_;
    while (@min(position - anchor, candidate) >= @sizeOf(u64)) {
        const position_word = position - @sizeOf(u64);
        const candidate_word = candidate - @sizeOf(u64);
        const difference = readIntAt(u64, input, position_word) ^
            readIntAt(u64, input, candidate_word);
        if (difference != 0) {
            const equal_bytes: usize = @intCast(@clz(difference) / 8);
            position -= equal_bytes;
            candidate -= equal_bytes;
            return .{ .position = position, .candidate = candidate };
        }
        position = position_word;
        candidate = candidate_word;
    }
    while (position > anchor and candidate > 0 and
        input[position - 1] == input[candidate - 1])
    {
        position -= 1;
        candidate -= 1;
    }
    return .{ .position = position, .candidate = candidate };
}
fn matchEnd(
    input: []const u8,
    position_: usize,
    candidate_: usize,
    limit: usize,
) usize {
    var position = position_;
    var candidate = candidate_;
    while (limit - position >= @sizeOf(u64)) {
        const difference = readIntAt(u64, input, position) ^
            readIntAt(u64, input, candidate);
        if (difference != 0) {
            const equal_bytes: usize = @intCast(@ctz(difference) / 8);
            return position + equal_bytes;
        }
        position += @sizeOf(u64);
        candidate += @sizeOf(u64);
    }
    while (position < limit and input[position] == input[candidate]) {
        position += 1;
        candidate += 1;
    }
    return position;
}
fn copyMatch(output: []u8, op_: usize, offset: usize, match_len: usize) void {
    var op = op_;
    const end = op_ + match_len;
    if (offset >= match_len and match_len >= 64) {
        @memcpy(
            output[op..][0..match_len],
            output[op - offset ..][0..match_len],
        );
        return;
    }
    switch (offset) {
        1, 2, 4, 8 => {
            const pattern: u64 = switch (offset) {
                1 => @as(u64, output[op - 1]) * 0x0101_0101_0101_0101,
                2 => @as(u64, readIntAt(u16, output, op - 2)) *
                    0x0001_0001_0001_0001,
                4 => @as(u64, readIntAt(u32, output, op - 4)) *
                    0x0000_0001_0000_0001,
                8 => readIntAt(u64, output, op - 8),
                else => unreachable,
            };
            const limit = @min(end, output.len -| 7);
            while (op < limit) : (op += 8)
                writeIntAt(u64, output, op, pattern);
        },
        else => if (offset >= 16) {
            const limit = @min(end, output.len -| 15);
            while (op < limit) : (op += 16)
                copyIntAt(u128, output, op, output, op - offset);
        } else if (offset >= 8) {
            const limit = @min(end, output.len -| 7);
            while (op < limit) : (op += 8)
                copyIntAt(u64, output, op, output, op - offset);
        },
    }
    while (op < end) : (op += 1) output[op] = output[op - offset];
}
inline fn hashSequence(sequence: u32) usize {
    return @intCast((sequence *% hash_multiplier) >> (32 - hash_log));
}
fn expectRoundTrip(input: []const u8) !void {
    const bound = try compressBound(input.len);
    const encoded = try testing.allocator.alloc(u8, bound);
    defer testing.allocator.free(encoded);
    const decoded = try testing.allocator.alloc(u8, input.len);
    defer testing.allocator.free(decoded);
    var table: HashTable = undefined;
    const encoded_len = try compress(input, encoded, &table);
    try testing.expectEqual(input.len, try decompress(
        encoded[0..encoded_len],
        decoded,
    ));
    try testing.expectEqualSlices(u8, input, decoded);
}
test "compressBound" {
    try testing.expectEqual(@as(usize, 16), try compressBound(0));
    try testing.expectEqual(@as(usize, 272), try compressBound(255));
    try testing.expectError(error.InputTooLarge, compressBound(max_input_size + 1));
}
test "literal-only compatibility vectors" {
    var empty: [0]u8 = .{};
    try testing.expectEqual(@as(usize, 0), try decompress(&.{0}, &empty));
    var hello: [5]u8 = undefined;
    try testing.expectEqual(@as(usize, 5), try decompress(
        &.{ 0x50, 'h', 'e', 'l', 'l', 'o' },
        &hello,
    ));
    try testing.expectEqualStrings("hello", &hello);
    var fifteen: [15]u8 = undefined;
    var encoded: [17]u8 = undefined;
    encoded[0] = 0xF0;
    encoded[1] = 0;
    @memset(encoded[2..], 'x');
    _ = try decompress(&encoded, &fifteen);
    try testing.expect(std.mem.allEqual(u8, &fifteen, 'x'));
}
test "overlapping match compatibility vector" {
    var output: [5]u8 = undefined;
    try testing.expectEqual(@as(usize, 5), try decompress(
        &.{ 0x10, 'a', 0x01, 0x00 },
        &output,
    ));
    try testing.expectEqualStrings("aaaaa", &output);
}
test "extended overlapping match compatibility vector" {
    var output: [275]u8 = undefined;
    try testing.expectEqual(@as(usize, output.len), try decompress(
        &.{ 0x1F, 'a', 0x01, 0x00, 0xFF, 0x00 },
        &output,
    ));
    try testing.expect(std.mem.allEqual(u8, &output, 'a'));
}
test "short offset compatibility vectors" {
    var offset_two: [6]u8 = undefined;
    _ = try decompress(&.{ 0x20, 'a', 'b', 0x02, 0x00 }, &offset_two);
    try testing.expectEqualStrings("ababab", &offset_two);
    var offset_three: [9]u8 = undefined;
    _ = try decompress(
        &.{ 0x32, 'a', 'b', 'c', 0x03, 0x00 },
        &offset_three,
    );
    try testing.expectEqualStrings("abcabcabc", &offset_three);
    var offset_four: [8]u8 = undefined;
    _ = try decompress(
        &.{ 0x40, 'a', 'b', 'c', 'd', 0x04, 0x00 },
        &offset_four,
    );
    try testing.expectEqualStrings("abcdabcd", &offset_four);
}
test "bounded wild copies are overwritten by final literals" {
    var repeated_byte: [15]u8 = undefined;
    _ = try decompress(
        &.{
            0x15, 'a', 0x01, 0x00,
            0x50, '1', '2',  '3',
            '4',  '5',
        },
        &repeated_byte,
    );
    try testing.expectEqualStrings("aaaaaaaaaa12345", &repeated_byte);
    var word_offset: [22]u8 = undefined;
    _ = try decompress(
        &.{
            0x85, 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 0x08, 0x00,
            0x50, '1', '2', '3', '4', '5',
        },
        &word_offset,
    );
    try testing.expectEqualStrings(
        "abcdefghabcdefgha12345",
        &word_offset,
    );
}
test "maximum match offset compatibility vector" {
    const literal_len = std.math.maxInt(u16);
    const extension_len = (literal_len - 15) / 255 + 1;
    const encoded = try testing.allocator.alloc(
        u8,
        1 + extension_len + literal_len + 2,
    );
    defer testing.allocator.free(encoded);
    const output = try testing.allocator.alloc(u8, literal_len + min_match);
    defer testing.allocator.free(output);
    var op: usize = 0;
    encoded[op] = 0xF0;
    op += 1;
    writeLength(encoded, &op, literal_len - 15);
    for (encoded[op..][0..literal_len], 0..) |*byte, i|
        byte.* = @truncate(i);
    op += literal_len;
    std.mem.writeInt(u16, encoded[op..][0..2], std.math.maxInt(u16), .little);
    op += 2;
    try testing.expectEqual(encoded.len, op);
    try testing.expectEqual(output.len, try decompress(encoded, output));
    try testing.expectEqualSlices(u8, encoded[1 + extension_len ..][0..4], output[literal_len..]);
}
test "round trips boundary-sized inputs" {
    const lengths = [_]usize{
        0,   1,      3,      4,      5,   12,  15,  16,  19,
        20,  254,    255,    256,    269, 270, 271, 510, 511,
        512, 65_535, 65_536, 65_537,
    };
    for (lengths) |len| {
        const buf = try testing.allocator.alloc(u8, len);
        defer testing.allocator.free(buf);
        for (buf, 0..) |*byte, i| byte.* = @truncate(i *% 31);
        try expectRoundTrip(buf);
    }
}
test "round trips compressible page-sized inputs" {
    const page_len = 400 * 1024;
    const zeros = try testing.allocator.alloc(u8, page_len);
    defer testing.allocator.free(zeros);
    @memset(zeros, 0);
    try expectRoundTrip(zeros);
    const structured = try testing.allocator.alloc(u8, page_len);
    defer testing.allocator.free(structured);
    @memset(structured, 0);
    for (0..page_len / 8) |i| {
        structured[i * 8] = @truncate(' ' + i % 95);
        structured[i * 8 + 4] = @truncate((i / 80) % 16);
    }
    try expectRoundTrip(structured);
}
test "round trips deterministic random inputs" {
    var prng = std.Random.DefaultPrng.init(0x4C5A_3401);
    const random = prng.random();
    for (0..256) |_| {
        const len = random.uintLessThan(usize, 32 * 1024);
        const input = try testing.allocator.alloc(u8, len);
        defer testing.allocator.free(input);
        random.bytes(input);
        try expectRoundTrip(input);
    }
}
test "compress reports short output" {
    const input = "a terminal page needs enough output space";
    var table: HashTable = undefined;
    var output: [4]u8 = undefined;
    try testing.expectError(
        error.OutputTooSmall,
        compress(input, &output, &table),
    );
}
test "decompress rejects malformed blocks" {
    var output: [32]u8 = undefined;
    try testing.expectError(error.TruncatedInput, decompress(&.{0xF0}, &output));
    try testing.expectError(error.TruncatedInput, decompress(&.{ 0x10, 'a', 1 }, output[0..5]));
    try testing.expectError(error.InvalidOffset, decompress(&.{ 0x10, 'a', 0, 0 }, output[0..5]));
    try testing.expectError(error.InvalidOffset, decompress(&.{ 0x10, 'a', 2, 0 }, output[0..5]));
    try testing.expectError(error.OutputTooSmall, decompress(
        &.{ 0x10, 'a', 1, 0 },
        output[0..4],
    ));
    try testing.expectError(error.OutputSizeMismatch, decompress(&.{0}, output[0..1]));
}
test {
    _ = @import("lz4_differential.zig");
}
