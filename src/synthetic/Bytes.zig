const Bytes = @This();
const std = @import("std");
const Generator = @import("Generator.zig");
rand: std.Random,
min_len: usize = 1,
max_len: usize = std.math.maxInt(usize),
alphabet: ?[]const u8 = null,
pub fn generateAlphabet(comptime func: fn (u8) bool) []const u8 {
    @setEvalBranchQuota(3000);
    var count = 0;
    for (0..256) |c| {
        if (func(c)) count += 1;
    }
    var alphabet: [count]u8 = undefined;
    var i = 0;
    for (0..256) |c| {
        if (func(c)) {
            alphabet[i] = c;
            i += 1;
        }
    }
    const result = alphabet;
    return &result;
}
pub fn generator(self: *Bytes) Generator {
    return .init(self, next);
}
pub fn newAlphabet(self: *const Bytes, new_alphabet: ?[]const u8) Bytes {
    return .{
        .rand = self.rand,
        .alphabet = new_alphabet,
        .min_len = self.min_len,
        .max_len = self.max_len,
    };
}
pub fn atLeast(self: *const Bytes, new_min_len: usize) Bytes {
    return .{
        .rand = self.rand,
        .alphabet = self.alphabet,
        .min_len = @min(self.max_len, new_min_len),
        .max_len = self.max_len,
    };
}
pub fn atMost(self: *const Bytes, new_max_len: usize) Bytes {
    return .{
        .rand = self.rand,
        .alphabet = self.alphabet,
        .min_len = @min(self.min_len, @min(self.max_len, new_max_len)),
        .max_len = @min(self.max_len, new_max_len),
    };
}
pub fn next(self: *const Bytes, writer: *std.Io.Writer, max_len: usize) std.Io.Writer.Error!void {
    _ = try self.atMost(max_len).write(writer);
}
pub fn format(self: *const Bytes, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    _ = try self.write(writer);
}
pub fn write(self: *const Bytes, writer: *std.Io.Writer) std.Io.Writer.Error!usize {
    std.debug.assert(self.min_len >= 1);
    std.debug.assert(self.max_len >= self.min_len);
    const len = self.rand.intRangeAtMostBiased(usize, self.min_len, self.max_len);
    var buf: [8]u8 = undefined;
    var remaining = len;
    while (remaining > 0) {
        const data = buf[0..@min(remaining, buf.len)];
        self.rand.bytes(data);
        if (self.alphabet) |alphabet| {
            for (data) |*byte| byte.* = alphabet[byte.* % alphabet.len];
        }
        try writer.writeAll(data);
        remaining -= data.len;
    }
    return len;
}
test "bytes" {
    const testing = std.testing;
    var prng = std.Random.DefaultPrng.init(0);
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var v: Bytes = .{
        .rand = prng.random(),
        .min_len = buf.len,
        .max_len = buf.len,
    };
    const gen = v.generator();
    try gen.next(&writer, buf.len);
    try testing.expectEqual(buf.len, writer.buffered().len);
}
