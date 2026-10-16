const std = @import("std");
const options = @import("build_options");
const assert = @import("../quirks.zig").inlineAssert;
const base64_scalar = @import("base64_scalar.zig");
const scalar_decoder = base64_scalar.scalar_decoder;
const log = std.log.scoped(.simd_base64);
pub fn maxLen(input: []const u8) usize {
    if (comptime options.simd) return wasp_simd_base64_max_length(
        input.ptr,
        input.len,
    );
    return maxLenScalar(input);
}
fn maxLenScalar(input: []const u8) usize {
    return scalar_decoder.calcSizeForSlice(scalarInput(input)) catch |err| {
        log.warn("failed to calculate base64 size for payload: {}", .{err});
        return 0;
    };
}
pub fn decode(input: []const u8, output: []u8) error{Base64Invalid}![]const u8 {
    if (comptime options.simd) {
        const res = wasp_simd_base64_decode(
            input.ptr,
            input.len,
            output.ptr,
        );
        if (res < 0) return error.Base64Invalid;
        return output[0..@intCast(res)];
    }
    return decodeScalar(input, output);
}
fn decodeScalar(
    input_raw: []const u8,
    output: []u8,
) error{Base64Invalid}![]const u8 {
    const input = scalarInput(input_raw);
    const size = maxLenScalar(input);
    if (size == 0) return "";
    assert(output.len >= size);
    scalar_decoder.decode(
        output,
        scalarInput(input),
    ) catch return error.Base64Invalid;
    return output[0..size];
}
fn scalarInput(input: []const u8) []const u8 {
    var end = input.len;
    while (end > 0 and input[end - 1] == '=') end -= 1;
    return input[0..end];
}
pub const Padding = enum { required, optional };
pub fn decodeStrict(
    input: []const u8,
    output: []u8,
    padding: Padding,
) error{Base64Invalid}![]const u8 {
    var pad: usize = 0;
    if (input.len > 0 and input[input.len - 1] == '=') pad += 1;
    if (input.len > 1 and input[input.len - 2] == '=') pad += 1;
    switch (padding) {
        .required => if (input.len % 4 != 0) return error.Base64Invalid,
        .optional => if (pad > 0) {
            if (input.len % 4 != 0) return error.Base64Invalid;
        } else if (input.len % 4 == 1) return error.Base64Invalid,
    }
    const decoded = decode(input, output) catch return error.Base64Invalid;
    const expected = switch (input.len % 4) {
        0 => input.len / 4 * 3 - pad,
        2 => input.len / 4 * 3 + 1,
        3 => input.len / 4 * 3 + 2,
        else => unreachable,
    };
    if (decoded.len != expected) return error.Base64Invalid;
    return decoded;
}
pub const Streaming = struct {
    carry: [4]u8 = undefined,
    carry_len: u3 = 0,
    pub fn maxLen(self: *const Streaming, input: []const u8) usize {
        return (self.carry_len + input.len) / 4 * 3;
    }
    pub fn feed(
        self: *Streaming,
        input: []const u8,
        output: []u8,
    ) error{Base64Invalid}![]const u8 {
        assert(output.len >= self.maxLen(input));
        if (input.len == 0) return output[0..0];
        var rem = input;
        var written: usize = 0;
        if (self.carry_len > 0) {
            const take = @min(4 - @as(usize, self.carry_len), rem.len);
            for (rem[0..take], self.carry_len..) |c, pos| {
                if (!validPartialChar(pos, c)) return error.Base64Invalid;
            }
            @memcpy(self.carry[self.carry_len..][0..take], rem[0..take]);
            self.carry_len += @intCast(take);
            rem = rem[take..];
            if (self.carry_len < 4) return output[0..0];
            self.carry_len = 0;
            const decoded, const padded = try group(self.carry, output);
            written += decoded;
            if (padded) {
                if (rem.len > 0) return error.Base64Invalid;
                return output[0..written];
            }
        }
        const bulk = rem[0 .. rem.len - (rem.len % 4)];
        written += (try decodeStrict(bulk, output[written..], .required)).len;
        if (bulk.len > 0 and bulk[bulk.len - 1] == '=') {
            if (bulk.len != rem.len) return error.Base64Invalid;
            return output[0..written];
        }
        const tail = rem[bulk.len..];
        for (tail, 0..) |c, pos| {
            if (!validPartialChar(pos, c)) return error.Base64Invalid;
        }
        @memcpy(self.carry[0..tail.len], tail);
        self.carry_len = @intCast(tail.len);
        return output[0..written];
    }
    fn group(
        g: [4]u8,
        output: []u8,
    ) error{Base64Invalid}!struct { usize, bool } {
        const padded = g[3] == '=';
        const decoded = try decodeStrict(&g, output, .required);
        return .{ decoded.len, padded };
    }
    fn validPartialChar(pos: usize, c: u8) bool {
        return base64_scalar.isAlphabetChar(c) or (pos >= 2 and c == '=');
    }
    pub fn finish(self: *Streaming) error{Base64Invalid}!void {
        defer self.* = .{};
        if (self.carry_len != 0) return error.Base64Invalid;
    }
};
extern "c" fn wasp_simd_base64_max_length(
    input: [*]const u8,
    len: usize,
) usize;
extern "c" fn wasp_simd_base64_decode(
    input: [*]const u8,
    len: usize,
    output: [*]u8,
) isize;
test "base64 maxLen" {
    const testing = std.testing;
    const len = maxLen("aGVsbG8gd29ybGQ=");
    try testing.expectEqual(11, len);
}
test "base64 empty input" {
    const testing = std.testing;
    var output: [0]u8 = .{};
    try testing.expectEqual(0, maxLen(""));
    try testing.expectEqualStrings("", try decode("", &output));
}
test "base64 decode" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const input = "aGVsbG8gd29ybGQ=";
    const len = maxLen(input);
    const output = try alloc.alloc(u8, len);
    defer alloc.free(output);
    const str = try decode(input, output);
    try testing.expectEqualStrings("hello world", str);
}
test "base64 strict decode valid" {
    const testing = std.testing;
    var output: [128]u8 = undefined;
    const cases = [_]struct { input: []const u8, expect: []const u8 }{
        .{ .input = "", .expect = "" },
        .{ .input = "aGVsbG8gd29ybGQ=", .expect = "hello world" },
        .{ .input = "bGlnaHQgdw==", .expect = "light w" },
        .{ .input = "Zm9vYmFy", .expect = "foobar" },
        .{
            .input = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/",
            .expect = "\x00\x10\x83\x10\x51\x87\x20\x92\x8b\x30\xd3\x8f\x41\x14\x93\x51\x55\x97\x61\x96\x9b\x71\xd7\x9f\x82\x18\xa3\x92\x59\xa7\xa2\x9a\xab\xb2\xdb\xaf\xc3\x1c\xb3\xd3\x5d\xb7\xe3\x9e\xbb\xf3\xdf\xbf",
        },
    };
    for (cases) |case| {
        try testing.expectEqualStrings(
            case.expect,
            try decodeStrict(case.input, &output, .required),
        );
        try testing.expectEqualStrings(
            case.expect,
            try decodeStrict(case.input, &output, .optional),
        );
    }
}
test "base64 strict decode invalid" {
    const testing = std.testing;
    var output: [128]u8 = undefined;
    const cases = [_][]const u8{
        "bGlnaHQgdw=",
        "bGln!!Qgdw==",
        "bGlnaHQgdw==\n",
        "\nbGlnaHQgdw==",
        "bGlnaHQg dw==",
        "!!!!",
        "=",
        "==",
        "A===",
        "AB=C",
        "Zm9v YmFy",
    };
    for (cases) |case| {
        try testing.expectError(
            error.Base64Invalid,
            decodeStrict(case, &output, .required),
        );
        try testing.expectError(
            error.Base64Invalid,
            decodeStrict(case, &output, .optional),
        );
    }
    try testing.expectError(
        error.Base64Invalid,
        decodeStrict("bGlnaHQgdw", &output, .required),
    );
    try testing.expectEqualStrings(
        "light w",
        try decodeStrict("bGlnaHQgdw", &output, .optional),
    );
    try testing.expectError(
        error.Base64Invalid,
        decodeStrict("bGl", &output, .required),
    );
    try testing.expectEqualStrings(
        "li",
        try decodeStrict("bGl", &output, .optional),
    );
    try testing.expectError(
        error.Base64Invalid,
        decodeStrict("bGlna", &output, .optional),
    );
}
test "base64 streaming decode chunk boundaries" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const input = "c29tZSBsb25nZXIgZGF0YSB3aXRoIHBhZGRpbmc+Pz8=";
    const expect = "some longer data with padding>??";
    for (0..input.len + 1) |split| {
        var s: Streaming = .{};
        var result: std.ArrayListUnmanaged(u8) = .empty;
        defer result.deinit(alloc);
        var output: [64]u8 = undefined;
        try result.appendSlice(alloc, try s.feed(input[0..split], &output));
        try result.appendSlice(alloc, try s.feed(input[split..], &output));
        try s.finish();
        try testing.expectEqualStrings(expect, result.items);
    }
    {
        var s: Streaming = .{};
        var result: std.ArrayListUnmanaged(u8) = .empty;
        defer result.deinit(alloc);
        var output: [4]u8 = undefined;
        for (0..input.len) |i| {
            try result.appendSlice(alloc, try s.feed(input[i..][0..1], &output));
        }
        try s.finish();
        try testing.expectEqualStrings(expect, result.items);
    }
}
test "base64 streaming decode invalid" {
    const testing = std.testing;
    var output: [64]u8 = undefined;
    {
        var s: Streaming = .{};
        try testing.expectError(error.Base64Invalid, s.feed("!!!!", &output));
    }
    {
        var s: Streaming = .{};
        try testing.expectError(error.Base64Invalid, s.feed("SGVs!!!bG8=", &output));
    }
    {
        var s: Streaming = .{};
        try testing.expectError(
            error.Base64Invalid,
            s.feed("\nc29tZSBkYXRh", &output),
        );
    }
    {
        var s: Streaming = .{};
        try testing.expectError(error.Base64Invalid, s.feed("Z29vZA==SGVsbG8=", &output));
    }
    {
        var s: Streaming = .{};
        _ = try s.feed("Z29vZA=", &output);
        try testing.expectError(error.Base64Invalid, s.feed("=SGVs", &output));
    }
    {
        var s: Streaming = .{};
        try testing.expectEqualStrings("good", try s.feed("Z29vZA==", &output));
        try testing.expectEqualStrings("Hello", try s.feed("SGVsbG8=", &output));
        try s.finish();
    }
    {
        var s: Streaming = .{};
        try testing.expectEqualStrings("goo", try s.feed("Z29vZA=", &output));
        try testing.expectEqualStrings("d", try s.feed("=", &output));
        try testing.expectEqualStrings("more", try s.feed("bW9yZQ==", &output));
        try s.finish();
    }
    {
        var s: Streaming = .{};
        try testing.expectError(error.Base64Invalid, s.feed("YQ=X", &output));
    }
    {
        var s: Streaming = .{};
        try testing.expectError(error.Base64Invalid, s.feed("=AAA", &output));
    }
    {
        var s: Streaming = .{};
        try testing.expectEqualStrings("Hel", try s.feed("SGVsbG8", &output));
        try testing.expectError(error.Base64Invalid, s.finish());
        try testing.expectEqualStrings("Hel", try s.feed("SGVsbG8", &output));
        try testing.expectEqualStrings("lo", try s.feed("=", &output));
        try s.finish();
    }
}
