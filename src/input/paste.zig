const std = @import("std");
const Terminal = @import("../terminal/Terminal.zig");
pub const bracketed_prefix = "\x1b[200~";
pub const bracketed_suffix = "\x1b[201~";
pub const max_frame_size = bracketed_prefix.len + bracketed_suffix.len;
pub const Options = struct {
    bracketed: bool,
    pub fn fromTerminal(t: *const Terminal) Options {
        return .{
            .bracketed = t.modes.get(.bracketed_paste),
        };
    }
};
pub fn encode(
    data: anytype,
    opts: Options,
) switch (@TypeOf(data)) {
    []u8 => [3][]const u8,
    []const u8 => Error![3][]const u8,
    else => unreachable,
} {
    const strip: []const u8 = &.{
        0x00, 
        0x08, 
        0x05, 
        0x04, 
        0x1B, 
        0x7F, 
        0x03, 
        0x1C, 
        0x15, 
        0x1A, 
        0x11, 
        0x13, 
        0x17, 
        0x16, 
        0x12, 
        0x0F, 
    };
    const mutable = @TypeOf(data) == []u8;
    var result: [3][]const u8 = .{ "", data, "" };
    if (std.mem.indexOfAny(u8, data, strip) != null) {
        if (comptime !mutable) return Error.MutableRequired;
        var offset: usize = 0;
        while (std.mem.indexOfAny(
            u8,
            data[offset..],
            strip,
        )) |idx| {
            offset += idx;
            data[offset] = ' ';
            offset += 1;
        }
    }
    if (opts.bracketed) {
        result[0] = bracketed_prefix;
        result[2] = bracketed_suffix;
        return result;
    }
    if (comptime mutable) {
        std.mem.replaceScalar(u8, data, '\n', '\r');
    } else if (std.mem.indexOfScalar(u8, data, '\n') != null) {
        return Error.MutableRequired;
    }
    return result;
}
pub const Error = error{
    MutableRequired,
};
pub fn encodeWriter(
    writer: *std.Io.Writer,
    data: []const u8,
    opts: Options,
) std.Io.Writer.Error!void {
    if (opts.bracketed) try writer.writeAll(bracketed_prefix);
    var remaining = data;
    while (remaining.len > 0) {
        const dest = try writer.writableSliceGreedy(1);
        const n = @min(dest.len, remaining.len);
        @memcpy(dest[0..n], remaining[0..n]);
        _ = encode(dest[0..n], opts);
        writer.advance(n);
        remaining = remaining[n..];
    }
    if (opts.bracketed) try writer.writeAll(bracketed_suffix);
}
pub fn isSafe(data: []const u8) bool {
    return std.mem.indexOfAny(u8, data, "\r\n") == null and
        std.mem.indexOf(u8, data, "\x1b[201~") == null;
}
pub fn isSafeWith(data: []const u8, opts: Options) bool {
    if (opts.bracketed) return std.mem.indexOf(u8, data, bracketed_suffix) == null;
    return isSafe(data);
}
test isSafe {
    const testing = std.testing;
    try testing.expect(isSafe("hello"));
    try testing.expect(isSafe("hello\tworld"));
    try testing.expect(!isSafe("hello\n"));
    try testing.expect(!isSafe("hello\nworld"));
    try testing.expect(!isSafe("he\x1b[201~llo"));
    try testing.expect(!isSafe("hello\r"));
    try testing.expect(!isSafe("hello\rworld"));
    try testing.expect(!isSafe("hello\r\nworld"));
    try testing.expect(!isSafe("\r"));
}
test isSafeWith {
    const testing = std.testing;
    try testing.expect(isSafeWith("hello", .{ .bracketed = true }));
    try testing.expect(isSafeWith("hello\nworld", .{ .bracketed = true }));
    try testing.expect(isSafeWith("hello\rworld", .{ .bracketed = true }));
    try testing.expect(isSafeWith("hello\r\nworld", .{ .bracketed = true }));
    try testing.expect(!isSafeWith("he\x1b[201~llo", .{ .bracketed = true }));
    try testing.expect(!isSafeWith("hello\n\x1b[201~", .{ .bracketed = true }));
    try testing.expect(isSafeWith("hello", .{ .bracketed = false }));
    try testing.expect(!isSafeWith("hello\nworld", .{ .bracketed = false }));
    try testing.expect(!isSafeWith("hello\rworld", .{ .bracketed = false }));
    try testing.expect(!isSafeWith("hello\r", .{ .bracketed = false }));
    try testing.expect(!isSafeWith("he\x1b[201~llo", .{ .bracketed = false }));
}
test "encodeWriter bracketed" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encodeWriter(&writer, "hel\x1blo\nworld", .{ .bracketed = true });
    try testing.expectEqualStrings("\x1b[200~hel lo\nworld\x1b[201~", writer.buffered());
}
test "encodeWriter unbracketed" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encodeWriter(&writer, "hel\x00lo\r\nworld", .{ .bracketed = false });
    try testing.expectEqualStrings("hel lo\r\rworld", writer.buffered());
}
test "encodeWriter empty" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encodeWriter(&writer, "", .{ .bracketed = true });
    try testing.expectEqualStrings("\x1b[200~\x1b[201~", writer.buffered());
    writer = .fixed(&buf);
    try encodeWriter(&writer, "", .{ .bracketed = false });
    try testing.expectEqualStrings("", writer.buffered());
}
test "encodeWriter chunks through a small writer buffer" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Sink = struct {
        list: std.ArrayList(u8) = .empty,
        writer: std.Io.Writer,
        fn drain(
            w: *std.Io.Writer,
            data: []const []const u8,
            splat: usize,
        ) std.Io.Writer.Error!usize {
            const self: *@This() = @alignCast(@fieldParentPtr("writer", w));
            self.list.appendSlice(testing.allocator, w.buffered()) catch return error.WriteFailed;
            w.end = 0;
            var n: usize = 0;
            for (data[0 .. data.len - 1]) |slice| {
                self.list.appendSlice(testing.allocator, slice) catch return error.WriteFailed;
                n += slice.len;
            }
            for (0..splat) |_| {
                self.list.appendSlice(testing.allocator, data[data.len - 1]) catch return error.WriteFailed;
            }
            return n + splat * data[data.len - 1].len;
        }
    };
    var staging: [4]u8 = undefined;
    var sink: Sink = .{ .writer = .{
        .buffer = &staging,
        .vtable = &.{ .drain = Sink.drain },
    } };
    defer sink.list.deinit(alloc);
    const data = "line one\nline\x1btwo\nline three\n";
    try encodeWriter(&sink.writer, data, .{ .bracketed = true });
    try sink.writer.flush();
    try testing.expectEqualStrings(
        "\x1b[200~line one\nline two\nline three\n\x1b[201~",
        sink.list.items,
    );
}
test "encodeWriter too small" {
    const testing = std.testing;
    var buf: [4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try testing.expectError(
        error.WriteFailed,
        encodeWriter(&writer, "hello", .{ .bracketed = true }),
    );
}
test max_frame_size {
    const testing = std.testing;
    const result = try encode(@as([]const u8, ""), .{ .bracketed = true });
    try testing.expectEqual(max_frame_size, result[0].len + result[2].len);
}
test "encode bracketed" {
    const testing = std.testing;
    const result = try encode(
        @as([]const u8, "hello"),
        .{ .bracketed = true },
    );
    try testing.expectEqualStrings("\x1b[200~", result[0]);
    try testing.expectEqualStrings("hello", result[1]);
    try testing.expectEqualStrings("\x1b[201~", result[2]);
}
test "encode unbracketed no newlines" {
    const testing = std.testing;
    const result = try encode(
        @as([]const u8, "hello"),
        .{ .bracketed = false },
    );
    try testing.expectEqualStrings("", result[0]);
    try testing.expectEqualStrings("hello", result[1]);
    try testing.expectEqualStrings("", result[2]);
}
test "encode unbracketed newlines const" {
    const testing = std.testing;
    try testing.expectError(Error.MutableRequired, encode(
        @as([]const u8, "hello\nworld"),
        .{ .bracketed = false },
    ));
}
test "encode unbracketed newlines" {
    const testing = std.testing;
    const data: []u8 = try testing.allocator.dupe(u8, "hello\nworld");
    defer testing.allocator.free(data);
    const result = encode(data, .{ .bracketed = false });
    try testing.expectEqualStrings("", result[0]);
    try testing.expectEqualStrings("hello\rworld", result[1]);
    try testing.expectEqualStrings("", result[2]);
}
test "encode unbracketed windows-stye newline" {
    const testing = std.testing;
    const data: []u8 = try testing.allocator.dupe(u8, "hello\r\nworld");
    defer testing.allocator.free(data);
    const result = encode(data, .{ .bracketed = false });
    try testing.expectEqualStrings("", result[0]);
    try testing.expectEqualStrings("hello\r\rworld", result[1]);
    try testing.expectEqualStrings("", result[2]);
}
test "encode strip unsafe bytes const" {
    const testing = std.testing;
    try testing.expectError(Error.MutableRequired, encode(
        @as([]const u8, "hello\x00world"),
        .{ .bracketed = true },
    ));
}
test "encode strip unsafe bytes mutable bracketed" {
    const testing = std.testing;
    const data: []u8 = try testing.allocator.dupe(u8, "hel\x1blo\x00world");
    defer testing.allocator.free(data);
    const result = encode(data, .{ .bracketed = true });
    try testing.expectEqualStrings("\x1b[200~", result[0]);
    try testing.expectEqualStrings("hel lo world", result[1]);
    try testing.expectEqualStrings("\x1b[201~", result[2]);
}
test "encode strip unsafe bytes mutable unbracketed" {
    const testing = std.testing;
    const data: []u8 = try testing.allocator.dupe(u8, "hel\x03lo");
    defer testing.allocator.free(data);
    const result = encode(data, .{ .bracketed = false });
    try testing.expectEqualStrings("", result[0]);
    try testing.expectEqualStrings("hel lo", result[1]);
    try testing.expectEqualStrings("", result[2]);
}
test "encode strip multiple unsafe bytes" {
    const testing = std.testing;
    const data: []u8 = try testing.allocator.dupe(u8, "\x00\x08\x7f");
    defer testing.allocator.free(data);
    const result = encode(data, .{ .bracketed = true });
    try testing.expectEqualStrings("   ", result[1]);
}
