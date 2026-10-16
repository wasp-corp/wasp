const std = @import("std");
pub fn parse(out: []u8, bytes: []const u8) ![]u8 {
    var dst_i: usize = 0;
    var src_i: usize = 0;
    while (src_i < bytes.len) {
        if (dst_i >= out.len) return error.OutOfMemory;
        const b = bytes[src_i];
        if (b != '\\') {
            out[dst_i] = b;
            dst_i += 1;
            src_i += 1;
            continue;
        }
        const is_byte_escape = src_i + 1 < bytes.len and
            bytes[src_i + 1] == 'x';
        switch (std.zig.string_literal.parseEscapeSequence(
            bytes,
            &src_i,
        )) {
            .failure => return error.InvalidString,
            .success => |cp| if (is_byte_escape) {
                out[dst_i] = @intCast(cp);
                dst_i += 1;
            } else {
                dst_i += try std.unicode.utf8Encode(cp, out[dst_i..]);
            },
        }
    }
    return out[0..dst_i];
}
pub fn codepointIterator(bytes: []const u8) CodepointIterator {
    return .{ .bytes = bytes, .i = 0 };
}
pub const CodepointIterator = struct {
    bytes: []const u8,
    i: usize,
    pub fn next(self: *CodepointIterator) error{InvalidString}!?u21 {
        if (self.i >= self.bytes.len) return null;
        switch (self.bytes[self.i]) {
            '\\' => return switch (std.zig.string_literal.parseEscapeSequence(
                self.bytes,
                &self.i,
            )) {
                .failure => error.InvalidString,
                .success => |cp| cp,
            },
            else => |start| {
                const cp_len = std.unicode.utf8ByteSequenceLength(start) catch
                    return error.InvalidString;
                defer self.i += cp_len;
                return std.unicode.utf8Decode(self.bytes[self.i..][0..cp_len]) catch
                    return error.InvalidString;
            },
        }
    }
};
test "parse: empty" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;
    const result = try parse(&buf, "");
    try testing.expectEqualStrings("", result);
}
test "parse: no escapes" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;
    const result = try parse(&buf, "hello world");
    try testing.expectEqualStrings("hello world", result);
}
test "parse: escapes" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;
    {
        const result = try parse(&buf, "hello\\nworld");
        try testing.expectEqualStrings("hello\nworld", result);
    }
    {
        const result = try parse(&buf, "hello\\u{1F601}world");
        try testing.expectEqualStrings("hello\u{1F601}world", result);
    }
}
test "parse: hex escapes are bytes" {
    var buf: [128]u8 = undefined;
    const result = try parse(
        &buf,
        "\\xe6\\x97\\xa5\\xe6\\x9c\\xac\\xe8\\xaa\\x9e",
    );
    try std.testing.expectEqualStrings("日本語", result);
}
test "codepointIterator: empty" {
    var it = codepointIterator("");
    try std.testing.expectEqual(null, try it.next());
}
test "codepointIterator: ascii no escapes" {
    var it = codepointIterator("abc");
    try std.testing.expectEqual(@as(u21, 'a'), (try it.next()).?);
    try std.testing.expectEqual(@as(u21, 'b'), (try it.next()).?);
    try std.testing.expectEqual(@as(u21, 'c'), (try it.next()).?);
    try std.testing.expectEqual(null, try it.next());
}
test "codepointIterator: multibyte utf8" {
    var it = codepointIterator("a│b");
    try std.testing.expectEqual(@as(u21, 'a'), (try it.next()).?);
    try std.testing.expectEqual(@as(u21, '│'), (try it.next()).?);
    try std.testing.expectEqual(@as(u21, 'b'), (try it.next()).?);
    try std.testing.expectEqual(null, try it.next());
}
test "codepointIterator: escape sequences" {
    var it = codepointIterator("a\\tb\\n\\\\");
    try std.testing.expectEqual(@as(u21, 'a'), (try it.next()).?);
    try std.testing.expectEqual(@as(u21, '\t'), (try it.next()).?);
    try std.testing.expectEqual(@as(u21, 'b'), (try it.next()).?);
    try std.testing.expectEqual(@as(u21, '\n'), (try it.next()).?);
    try std.testing.expectEqual(@as(u21, '\\'), (try it.next()).?);
    try std.testing.expectEqual(null, try it.next());
}
test "codepointIterator: unicode escape" {
    var it = codepointIterator("\\u{2502}x");
    try std.testing.expectEqual(@as(u21, '│'), (try it.next()).?);
    try std.testing.expectEqual(@as(u21, 'x'), (try it.next()).?);
    try std.testing.expectEqual(null, try it.next());
}
test "codepointIterator: emoji unicode escape" {
    var it = codepointIterator("\\u{1F601}");
    try std.testing.expectEqual(@as(u21, 0x1F601), (try it.next()).?);
    try std.testing.expectEqual(null, try it.next());
}
