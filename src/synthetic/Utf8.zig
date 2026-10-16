const Utf8 = @This();
const std = @import("std");
const assert = std.debug.assert;
const Generator = @import("Generator.zig");
pub const Utf8Len = enum(u3) {
    one = 1,
    two = 2,
    three = 3,
    four = 4,
};
const InvalidSequence = struct {
    len: u3,
    bytes: [4]u8,
    fn slice(self: *const InvalidSequence) []const u8 {
        return self.bytes[0..self.len];
    }
};
const invalid_sequences = [_]InvalidSequence{
    .{ .len = 1, .bytes = .{ 0x80, 0x00, 0x00, 0x00 } },
    .{ .len = 1, .bytes = .{ 0xC0, 0x00, 0x00, 0x00 } },
    .{ .len = 1, .bytes = .{ 0xFF, 0x00, 0x00, 0x00 } },
    .{ .len = 2, .bytes = .{ 0xC2, 0x20, 0x00, 0x00 } },
    .{ .len = 2, .bytes = .{ 0xC0, 0xAF, 0x00, 0x00 } },
    .{ .len = 2, .bytes = .{ 0x80, 0x80, 0x00, 0x00 } },
    .{ .len = 3, .bytes = .{ 0xED, 0xA0, 0x80, 0x00 } },
    .{ .len = 3, .bytes = .{ 0xE2, 0x28, 0x7A, 0x00 } },
    .{ .len = 4, .bytes = .{ 0xF0, 0x90, 0x28, 0x7A } },
};
rand: std.Random,
min_len: usize = 1,
max_len: usize = std.math.maxInt(usize),
p_length: std.enums.EnumArray(Utf8Len, f64) = .initFill(1.0),
ascii_printable_only: bool = false,
invalid_rate: f64 = 0,
pub fn generator(self: *Utf8) Generator {
    return .init(self, next);
}
pub fn next(self: *Utf8, writer: *std.Io.Writer, max_len: usize) Generator.Error!void {
    const len = @min(
        self.rand.intRangeAtMostBiased(usize, self.min_len, self.max_len),
        max_len,
    );
    var rem: usize = len;
    while (rem > 0) {
        if (try self.writeInvalid(writer, rem)) |written| {
            rem -= written;
            continue;
        }
        const written = try self.writeValid(writer, rem);
        rem -= written;
    }
}
fn writeInvalid(
    self: *Utf8,
    writer: *std.Io.Writer,
    rem: usize,
) Generator.Error!?usize {
    if (self.invalid_rate <= 0 or self.rand.float(f64) >= self.invalid_rate) {
        return null;
    }
    const seq = self.invalidSequence(rem) orelse return null;
    try writer.writeAll(seq.slice());
    return seq.len;
}
fn writeValid(
    self: *Utf8,
    writer: *std.Io.Writer,
    rem: usize,
) Generator.Error!usize {
    while (true) {
        const utf8_len = self.utf8Len(rem);
        const cp: u21 = switch (utf8_len) {
            .one => if (self.ascii_printable_only)
                self.rand.intRangeAtMostBiased(u21, 0x20, 0x7E)
            else
                self.rand.intRangeAtMostBiased(u21, 0x00, 0x7F),
            .two => self.rand.intRangeAtMostBiased(u21, 0x80, 0x7FF),
            .three => self.rand.intRangeAtMostBiased(u21, 0x800, 0xFFFF),
            .four => self.rand.intRangeAtMostBiased(u21, 0x10000, 0x10FFFF),
        };
        assert(std.unicode.utf8CodepointSequenceLength(
            cp,
        ) catch unreachable == @intFromEnum(utf8_len));
        var buf: [4]u8 = undefined;
        const l = std.unicode.utf8Encode(
            cp,
            &buf,
        ) catch |err| switch (err) {
            error.CodepointTooLarge => unreachable,
            error.Utf8CannotEncodeSurrogateHalf => continue,
        };
        try writer.writeAll(buf[0..l]);
        return l;
    }
}
fn utf8Len(self: *Utf8, rem: usize) Utf8Len {
    const Indexer = @TypeOf(self.p_length).Indexer;
    const idx = self.rand.weightedIndex(f64, &self.p_length.values);
    var utf8_len = Indexer.keyForIndex(idx);
    assert(rem > 0);
    while (@intFromEnum(utf8_len) > rem) {
        utf8_len = @enumFromInt(@intFromEnum(utf8_len) - 1);
    }
    return utf8_len;
}
fn invalidSequence(self: *Utf8, rem: usize) ?InvalidSequence {
    const candidates = &invalid_sequences;
    var valid_idx: [candidates.len]usize = undefined;
    var valid_len: usize = 0;
    for (candidates, 0..) |candidate, i| {
        if (candidate.len > rem) continue;
        valid_idx[valid_len] = i;
        valid_len += 1;
    }
    if (valid_len == 0) return null;
    return candidates[valid_idx[self.rand.uintLessThan(usize, valid_len)]];
}
test "utf8" {
    const testing = std.testing;
    var prng = std.Random.DefaultPrng.init(0);
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var v: Utf8 = .{ .rand = prng.random() };
    v.min_len = buf.len;
    v.max_len = buf.len;
    const gen = v.generator();
    try gen.next(&writer, buf.len);
    const result = writer.buffered();
    try testing.expectEqual(256, result.len);
    try testing.expect(std.unicode.utf8ValidateSlice(result));
}
test "utf8 printable ascii only" {
    const testing = std.testing;
    var prng = std.Random.DefaultPrng.init(0);
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var v: Utf8 = .{
        .rand = prng.random(),
        .ascii_printable_only = true,
    };
    v.min_len = buf.len;
    v.max_len = buf.len;
    v.p_length.set(.one, 1.0);
    v.p_length.set(.two, 0.0);
    v.p_length.set(.three, 0.0);
    v.p_length.set(.four, 0.0);
    const gen = v.generator();
    try gen.next(&writer, buf.len);
    const result = writer.buffered();
    try testing.expectEqual(256, result.len);
    try testing.expect(std.unicode.utf8ValidateSlice(result));
    for (result) |c| try testing.expect(std.ascii.isPrint(c));
}
test "utf8 malformed output" {
    const testing = std.testing;
    var prng = std.Random.DefaultPrng.init(0);
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var v: Utf8 = .{
        .rand = prng.random(),
        .invalid_rate = 1.0,
    };
    v.min_len = buf.len;
    v.max_len = buf.len;
    const gen = v.generator();
    try gen.next(&writer, buf.len);
    const result = writer.buffered();
    try testing.expectEqual(256, result.len);
    try testing.expect(!std.unicode.utf8ValidateSlice(result));
}
