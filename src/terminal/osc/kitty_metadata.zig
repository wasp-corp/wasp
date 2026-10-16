const std = @import("std");
pub fn ValueIterator(
    comptime key: []const u8,
    comptime valid_value_characters: ?[]const u8,
) type {
    return struct {
        const Self = @This();
        metadata: []const u8,
        pos: usize,
        pub fn init(metadata: []const u8) Self {
            return .{
                .metadata = metadata,
                .pos = 0,
            };
        }
        pub fn next(self: *Self) ?[]const u8 {
            while (self.pos < self.metadata.len) {
                const end = std.mem.indexOfScalarPos(
                    u8,
                    self.metadata,
                    self.pos,
                    ':',
                ) orelse self.metadata.len;
                const field = self.metadata[self.pos..end];
                self.pos = if (end < self.metadata.len) end + 1 else end;
                const equals = std.mem.indexOfScalar(u8, field, '=') orelse
                    continue;
                const field_key = std.mem.trim(
                    u8,
                    field[0..equals],
                    &std.ascii.whitespace,
                );
                if (!std.mem.eql(u8, field_key, key)) continue;
                const value = std.mem.trim(
                    u8,
                    field[equals + 1 ..],
                    &std.ascii.whitespace,
                );
                if (valid_value_characters) |valid| {
                    if (std.mem.indexOfNone(u8, value, valid) != null) continue;
                }
                return value;
            }
            return null;
        }
    };
}
test "ValueIterator skips malformed and prefix-matching keys" {
    const testing = std.testing;
    var it: ValueIterator("id", null) = .init(
        "id-extra=wrong:id: id = first :id=second",
    );
    try testing.expectEqualStrings("first", it.next().?);
    try testing.expectEqualStrings("second", it.next().?);
    try testing.expect(it.next() == null);
}
test "ValueIterator skips values containing disallowed characters" {
    const testing = std.testing;
    var it: ValueIterator("i", "abc") = .init("i=a?:i=abc");
    try testing.expectEqualStrings("abc", it.next().?);
    try testing.expect(it.next() == null);
}
