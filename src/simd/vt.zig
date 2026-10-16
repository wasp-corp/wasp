const std = @import("std");
const options = @import("build_options");
const assert = @import("../quirks.zig").inlineAssert;
const indexOf = @import("index_of.zig").indexOf;
extern "c" fn wasp_simd_decode_utf8_until_control_seq(
    input: [*]const u8,
    count: usize,
    output: [*]u32,
    output_count: *usize,
) usize;
const DecodeResult = struct {
    consumed: usize,
    decoded: usize,
};
pub fn utf8DecodeUntilControlSeq(
    input: []const u8,
    output: []u32,
) DecodeResult {
    assert(output.len >= input.len);
    if (comptime options.simd) {
        var decoded: usize = 0;
        const consumed = wasp_simd_decode_utf8_until_control_seq(
            input.ptr,
            input.len,
            output.ptr,
            &decoded,
        );
        return .{ .consumed = consumed, .decoded = decoded };
    }
    return utf8DecodeUntilControlSeqScalar(input, output);
}
fn utf8DecodeUntilControlSeqScalar(
    input: []const u8,
    output: []u32,
) DecodeResult {
    const idx = indexOf(input, 0x1B) orelse input.len;
    const decode = input[0..idx];
    var decode_offset: usize = 0;
    var decode_count: usize = 0;
    while (decode_offset < decode.len) {
        const b0 = decode[decode_offset];
        if (b0 < 0x80) {
            if (comptime std.simd.suggestVectorLength(u8)) |vl| {
                const V = @Vector(vl, u8);
                while (decode_offset + vl <= decode.len) {
                    const v: V = decode[decode_offset..][0..vl].*;
                    if (@reduce(.Or, v >= @as(V, @splat(0x80)))) break;
                    const w: @Vector(vl, u32) = @intCast(v);
                    output[decode_count..][0..vl].* = w;
                    decode_count += vl;
                    decode_offset += vl;
                }
            }
            while (decode_offset < decode.len) {
                const b = decode[decode_offset];
                if (b >= 0x80) break;
                output[decode_count] = b;
                decode_count += 1;
                decode_offset += 1;
            }
            continue;
        }
        if (b0 < 0xC2 or b0 > 0xF4) {
            output[decode_count] = 0xFFFD;
            decode_count += 1;
            decode_offset += 1;
            continue;
        }
        const seq_len: usize = if (b0 < 0xE0) 2 else if (b0 < 0xF0) 3 else 4;
        const cb1_lo: u8, const cb1_hi: u8 = switch (b0) {
            0xE0 => .{ 0xA0, 0xBF },
            0xED => .{ 0x80, 0x9F },
            0xF0 => .{ 0x90, 0xBF },
            0xF4 => .{ 0x80, 0x8F },
            else => .{ 0x80, 0xBF },
        };
        var cp: u32 = b0 & (@as(u32, 0x7F) >> @intCast(seq_len));
        var valid: usize = 1;
        while (valid < seq_len) {
            if (decode_offset + valid >= decode.len) {
                if (decode.len == input.len) return .{
                    .consumed = decode_offset,
                    .decoded = decode_count,
                };
                break;
            }
            const cb = decode[decode_offset + valid];
            const lo: u8 = if (valid == 1) cb1_lo else 0x80;
            const hi: u8 = if (valid == 1) cb1_hi else 0xBF;
            if (cb < lo or cb > hi) break;
            cp = (cp << 6) | (cb & 0x3F);
            valid += 1;
        }
        if (valid == seq_len) {
            output[decode_count] = cp;
            decode_count += 1;
            decode_offset += seq_len;
        } else {
            output[decode_count] = 0xFFFD;
            decode_count += 1;
            decode_offset += valid;
        }
    }
    return .{
        .consumed = decode_offset,
        .decoded = decode_count,
    };
}
test "decode simd matches scalar" {
    if (comptime !options.simd) return error.SkipZigTest;
    const testing = std.testing;
    var prng = std.Random.DefaultPrng.init(0xf00dface);
    const rand = prng.random();
    var input: [257]u8 = undefined;
    var out_simd: [input.len]u32 = undefined;
    var out_scalar: [input.len]u32 = undefined;
    for (0..10_000) |_| {
        const len = rand.intRangeAtMost(usize, 0, input.len);
        const style = rand.intRangeAtMost(u8, 0, 2);
        for (input[0..len]) |*b| {
            b.* = switch (style) {
                0 => switch (rand.intRangeAtMost(u8, 0, 20)) {
                    0 => 0x1B,
                    1 => rand.intRangeAtMost(u8, 0, 0x1F),
                    2 => rand.int(u8),
                    else => rand.intRangeAtMost(u8, 0x20, 0x7E),
                },
                1 => switch (rand.intRangeAtMost(u8, 0, 3)) {
                    0 => rand.intRangeAtMost(u8, 0x80, 0xBF),
                    1 => rand.intRangeAtMost(u8, 0xC0, 0xFF),
                    2 => 0x1B,
                    else => rand.intRangeAtMost(u8, 0x20, 0x7E),
                },
                else => rand.int(u8),
            };
        }
        const res_simd = utf8DecodeUntilControlSeq(input[0..len], &out_simd);
        const res_scalar = utf8DecodeUntilControlSeqScalar(input[0..len], &out_scalar);
        errdefer std.debug.print("input={x}\n", .{input[0..len]});
        try testing.expectEqual(res_scalar.consumed, res_simd.consumed);
        try testing.expectEqual(res_scalar.decoded, res_simd.decoded);
        try testing.expectEqualSlices(
            u32,
            out_scalar[0..res_scalar.decoded],
            out_simd[0..res_simd.decoded],
        );
    }
}
test "decode no escape" {
    const testing = std.testing;
    var output: [1024]u32 = undefined;
    {
        const str = "hello" ** 128;
        try testing.expectEqual(DecodeResult{
            .consumed = str.len,
            .decoded = str.len,
        }, utf8DecodeUntilControlSeq(str, &output));
    }
}
test "decode ASCII to escape" {
    const testing = std.testing;
    var output: [1024]u32 = undefined;
    {
        const prefix = "hello" ** 64;
        const str = prefix ++ "\x1b" ++ ("world" ** 64);
        try testing.expectEqual(DecodeResult{
            .consumed = prefix.len,
            .decoded = prefix.len,
        }, utf8DecodeUntilControlSeq(str, &output));
    }
}
test "decode immediate esc sequence" {
    const testing = std.testing;
    var output: [64]u32 = undefined;
    const str = "\x1b[?5s";
    try testing.expectEqual(DecodeResult{
        .consumed = 0,
        .decoded = 0,
    }, utf8DecodeUntilControlSeq(str, &output));
}
test "decode incomplete UTF-8" {
    const testing = std.testing;
    var output: [64]u32 = undefined;
    {
        const str = "hello\xc2";
        try testing.expectEqual(DecodeResult{
            .consumed = 5,
            .decoded = 5,
        }, utf8DecodeUntilControlSeq(str, &output));
    }
    {
        const str = "hello\xe0\x00";
        const result = utf8DecodeUntilControlSeq(str, &output);
        try testing.expectEqual(@as(usize, 7), result.consumed);
        try testing.expectEqual(@as(usize, 7), result.decoded);
        try testing.expectEqual(@as(u32, 0xFFFD), output[5]);
        try testing.expectEqual(@as(u32, 0x00), output[6]);
    }
    {
        const str = "hello\xf0\x90";
        try testing.expectEqual(DecodeResult{
            .consumed = 5,
            .decoded = 5,
        }, utf8DecodeUntilControlSeq(str, &output));
    }
}
test "decode invalid UTF-8" {
    const testing = std.testing;
    var output: [64]u32 = undefined;
    {
        const str = "hello\xc2\x01";
        try testing.expectEqual(DecodeResult{
            .consumed = 7,
            .decoded = 7,
        }, utf8DecodeUntilControlSeq(str, &output));
    }
    try testing.expectEqual(@as(u32, 0xFFFD), output[5]);
    try testing.expectEqual(@as(u32, 0x01), output[6]);
}
test "decode invalid leading byte is replaced" {
    const testing = std.testing;
    var output: [64]u32 = undefined;
    {
        const str = "hello\xFF";
        const result = utf8DecodeUntilControlSeq(str, &output);
        try testing.expectEqual(@as(usize, 6), result.consumed);
        try testing.expectEqual(@as(usize, 6), result.decoded);
        try testing.expectEqual(@as(u32, 0xFFFD), output[5]);
    }
}
test "decode invalid continuation in 3-byte sequence" {
    const testing = std.testing;
    var output: [64]u32 = undefined;
    {
        const str = "hello\xe2\x28world";
        const result = utf8DecodeUntilControlSeq(str, &output);
        try testing.expectEqual(@as(usize, 12), result.decoded);
        try testing.expectEqual(@as(u32, 0xFFFD), output[5]);
        try testing.expectEqual(@as(u32, '('), output[6]);
        try testing.expectEqual(@as(u32, 'w'), output[7]);
    }
}
test "decode invalid continuation in 4-byte sequence" {
    const testing = std.testing;
    var output: [64]u32 = undefined;
    {
        const str = "hello\xf0\x90\x28world";
        const result = utf8DecodeUntilControlSeq(str, &output);
        try testing.expectEqual(@as(usize, 12), result.decoded);
        try testing.expectEqual(@as(u32, 0xFFFD), output[5]);
        try testing.expectEqual(@as(u32, '('), output[6]);
        try testing.expectEqual(@as(u32, 'w'), output[7]);
    }
}
test "decode multiple consecutive invalid bytes" {
    const testing = std.testing;
    var output: [64]u32 = undefined;
    {
        const str = "a\x80\x80b";
        const result = utf8DecodeUntilControlSeq(str, &output);
        try testing.expectEqual(@as(usize, 4), result.decoded);
        try testing.expectEqual(@as(u32, 'a'), output[0]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[1]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[2]);
        try testing.expectEqual(@as(u32, 'b'), output[3]);
    }
    {
        const str = "a\xc0\xc0b";
        const result = utf8DecodeUntilControlSeq(str, &output);
        try testing.expectEqual(@as(usize, 4), result.decoded);
        try testing.expectEqual(@as(u32, 'a'), output[0]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[1]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[2]);
        try testing.expectEqual(@as(u32, 'b'), output[3]);
    }
}
test "decode unexpected continuation byte as lead" {
    const testing = std.testing;
    var output: [64]u32 = undefined;
    {
        const str = "a\x80b";
        const result = utf8DecodeUntilControlSeq(str, &output);
        try testing.expectEqual(@as(usize, 3), result.decoded);
        try testing.expectEqual(@as(u32, 'a'), output[0]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[1]);
        try testing.expectEqual(@as(u32, 'b'), output[2]);
    }
}
test "decode overlong 2-byte encoding" {
    const testing = std.testing;
    var output: [64]u32 = undefined;
    {
        const str = "a\xc0\xafb";
        const result = utf8DecodeUntilControlSeq(str, &output);
        try testing.expectEqual(@as(usize, 4), result.decoded);
        try testing.expectEqual(@as(u32, 'a'), output[0]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[1]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[2]);
        try testing.expectEqual(@as(u32, 'b'), output[3]);
    }
}
test "decode surrogate half" {
    const testing = std.testing;
    var output: [64]u32 = undefined;
    {
        const str = "a\xed\xa0\x80b";
        const result = utf8DecodeUntilControlSeq(str, &output);
        try testing.expectEqual(@as(usize, 5), result.decoded);
        try testing.expectEqual(@as(u32, 'a'), output[0]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[1]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[2]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[3]);
        try testing.expectEqual(@as(u32, 'b'), output[4]);
    }
}
test "decode valid multibyte surrounded by invalid" {
    const testing = std.testing;
    var output: [64]u32 = undefined;
    {
        const str = "\x80\xc3\xa9\x80";
        const result = utf8DecodeUntilControlSeq(str, &output);
        try testing.expectEqual(@as(usize, 3), result.decoded);
        try testing.expectEqual(@as(u32, 0xFFFD), output[0]);
        try testing.expectEqual(@as(u32, 0x00E9), output[1]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[2]);
    }
}
test "decode partial UTF-8 before escape" {
    const testing = std.testing;
    var output: [64]u32 = undefined;
    {
        const str = "hi\xc2\x1b[0m";
        const result = utf8DecodeUntilControlSeq(str, &output);
        try testing.expectEqual(@as(usize, 3), result.consumed);
        try testing.expectEqual(@as(usize, 3), result.decoded);
        try testing.expectEqual(@as(u32, 0xFFFD), output[2]);
    }
    {
        const str = "\xe0\xa0\x1bX";
        const result = utf8DecodeUntilControlSeq(str, &output);
        try testing.expectEqual(@as(usize, 2), result.consumed);
        try testing.expectEqual(@as(usize, 1), result.decoded);
        try testing.expectEqual(@as(u32, 0xFFFD), output[0]);
    }
}
test "decode invalid byte before escape" {
    const testing = std.testing;
    var output: [64]u32 = undefined;
    {
        const str = "hi\x80\x1b[0m";
        const result = utf8DecodeUntilControlSeq(str, &output);
        try testing.expectEqual(@as(usize, 3), result.consumed);
        try testing.expectEqual(@as(usize, 3), result.decoded);
        try testing.expectEqual(@as(u32, 'h'), output[0]);
        try testing.expectEqual(@as(u32, 'i'), output[1]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[2]);
    }
}
test "Table 3-8: non-shortest form sequences" {
    const testing = std.testing;
    var output: [64]u32 = undefined;
    const str = "\xC0\xAF\xE0\x80\xBF\xF0\x81\x82\x41";
    const result = utf8DecodeUntilControlSeq(str, &output);
    try testing.expectEqual(@as(usize, 9), result.consumed);
    try testing.expectEqual(@as(usize, 9), result.decoded);
    for (0..8) |i| {
        try testing.expectEqual(@as(u32, 0xFFFD), output[i]);
    }
    try testing.expectEqual(@as(u32, 0x41), output[8]);
}
test "Table 3-9: surrogate sequences" {
    const testing = std.testing;
    var output: [64]u32 = undefined;
    const str = "\xED\xA0\x80\xED\xBF\xBF\xED\xAF\x41";
    const result = utf8DecodeUntilControlSeq(str, &output);
    try testing.expectEqual(@as(usize, 9), result.consumed);
    try testing.expectEqual(@as(usize, 9), result.decoded);
    for (0..8) |i| {
        try testing.expectEqual(@as(u32, 0xFFFD), output[i]);
    }
    try testing.expectEqual(@as(u32, 0x41), output[8]);
}
test "Table 3-10: other ill-formed sequences" {
    const testing = std.testing;
    var output: [64]u32 = undefined;
    const str = "\xF4\x91\x92\x93\xFF\x41\x80\xBF\x42";
    const result = utf8DecodeUntilControlSeq(str, &output);
    try testing.expectEqual(@as(usize, 9), result.consumed);
    try testing.expectEqual(@as(usize, 9), result.decoded);
    try testing.expectEqual(@as(u32, 0xFFFD), output[0]);
    try testing.expectEqual(@as(u32, 0xFFFD), output[1]);
    try testing.expectEqual(@as(u32, 0xFFFD), output[2]);
    try testing.expectEqual(@as(u32, 0xFFFD), output[3]);
    try testing.expectEqual(@as(u32, 0xFFFD), output[4]);
    try testing.expectEqual(@as(u32, 0x0041), output[5]);
    try testing.expectEqual(@as(u32, 0xFFFD), output[6]);
    try testing.expectEqual(@as(u32, 0xFFFD), output[7]);
    try testing.expectEqual(@as(u32, 0x0042), output[8]);
}
test "Table 3-11: truncated sequences" {
    const testing = std.testing;
    var output: [64]u32 = undefined;
    const str = "\xE1\x80\xE2\xF0\x91\x92\xF1\xBF\x41";
    const result = utf8DecodeUntilControlSeq(str, &output);
    try testing.expectEqual(@as(usize, 9), result.consumed);
    try testing.expectEqual(@as(usize, 5), result.decoded);
    try testing.expectEqual(@as(u32, 0xFFFD), output[0]);
    try testing.expectEqual(@as(u32, 0xFFFD), output[1]);
    try testing.expectEqual(@as(u32, 0xFFFD), output[2]);
    try testing.expectEqual(@as(u32, 0xFFFD), output[3]);
    try testing.expectEqual(@as(u32, 0x0041), output[4]);
}
