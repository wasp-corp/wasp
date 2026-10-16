const Entry = @This();
const std = @import("std");
hostname: []const u8,
timestamp: i64,
terminfo_version: []const u8,
pub fn parse(line: []const u8) ?Entry {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;
    var iter = std.mem.tokenizeScalar(u8, trimmed, '|');
    const hostname = iter.next() orelse return null;
    const timestamp_str = iter.next() orelse return null;
    const terminfo_version = iter.next() orelse "xterm-wasp";
    const timestamp = std.fmt.parseInt(i64, timestamp_str, 10) catch |err| {
        std.log.warn(
            "Invalid timestamp in cache entry: {s} err={}",
            .{ timestamp_str, err },
        );
        return null;
    };
    return .{
        .hostname = hostname,
        .timestamp = timestamp,
        .terminfo_version = terminfo_version,
    };
}
pub const FormatError = std.Io.Writer.Error;
pub fn format(self: Entry, writer: *std.Io.Writer) FormatError!void {
    try writer.print(
        "{s}|{d}|{s}\n",
        .{ self.hostname, self.timestamp, self.terminfo_version },
    );
}
test "cache entry parsing valid formats" {
    const testing = std.testing;
    const entry = Entry.parse("example.com|1640995200|xterm-wasp").?;
    try testing.expectEqualStrings("example.com", entry.hostname);
    try testing.expectEqual(@as(i64, 1640995200), entry.timestamp);
    try testing.expectEqualStrings("xterm-wasp", entry.terminfo_version);
    const entry_no_version = Entry.parse("test.com|1640995200").?;
    try testing.expectEqualStrings(
        "xterm-wasp",
        entry_no_version.terminfo_version,
    );
    const complex_entry = Entry.parse("user@server.example.com|1640995200|xterm-wasp").?;
    try testing.expectEqualStrings(
        "user@server.example.com",
        complex_entry.hostname,
    );
}
test "cache entry parsing invalid formats" {
    const testing = std.testing;
    try testing.expect(Entry.parse("") == null);
    try testing.expect(Entry.parse("v1") == null);
    try testing.expect(Entry.parse("example.com") == null);
    try testing.expect(Entry.parse("example.com|invalid") == null);
    try testing.expect(Entry.parse("example.com|1640995200|") != null);
}
test "cache entry parsing malformed data resilience" {
    const testing = std.testing;
    try testing.expect(Entry.parse("host|123|term|extra") != null);
    try testing.expect(Entry.parse("  host|123|term  ") != null);
    try testing.expect(Entry.parse("\n") == null);
    try testing.expect(Entry.parse("   \t  \n") == null);
    try testing.expect(
        Entry.parse("host|999999999999999999999999999999999999999999999999|xterm-wasp") == null,
    );
}
