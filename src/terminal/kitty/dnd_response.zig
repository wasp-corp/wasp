const std = @import("std");
const Terminator = @import("../osc.zig").Terminator;
pub const max_chunk_raw = 3072;
pub const max_chunk_plain = 4096;
pub const Errno = enum {
    OK,
    EPERM,
    ENOENT,
    EIO,
    EINVAL,
    EMFILE,
    ENOMEM,
    EFBIG,
    EISDIR,
    ENOSPC,
    EUNKNOWN,
};
pub const Encoding = enum {
    plain,
    base64,
};
pub const RequestKeys = struct {
    x: i32 = 0,
    y: i32 = 0,
    Y: i32 = 0,
    pub fn format(self: RequestKeys, writer: *std.Io.Writer) !void {
        if (self.x != 0) try writer.print(":x={d}", .{self.x});
        if (self.y != 0) try writer.print(":y={d}", .{self.y});
        if (self.Y != 0) try writer.print(":Y={d}", .{self.Y});
    }
};
pub fn encode(
    writer: *std.Io.Writer,
    header: []const u8,
    client_id: u32,
    data: []const u8,
    encoding: Encoding,
    terminator: Terminator,
) std.Io.Writer.Error!void {
    var id_buf: [16]u8 = undefined;
    const id: []const u8 = if (client_id != 0) std.fmt.bufPrint(
        &id_buf,
        ":i={d}",
        .{client_id},
    ) catch unreachable else "";
    if (data.len == 0) {
        try writer.print("\x1b]72;{s}{s}{s}", .{
            header,
            id,
            terminator.string(),
        });
        return;
    }
    const limit: usize = switch (encoding) {
        .base64 => max_chunk_raw,
        .plain => max_chunk_plain,
    };
    var offset: usize = 0;
    while (offset < data.len) {
        const chunk_len = @min(data.len - offset, limit);
        const chunk = data[offset .. offset + chunk_len];
        offset += chunk_len;
        const last: u8 = if (offset >= data.len) '0' else '1';
        try writer.print("\x1b]72;{s}{s}:m={c};", .{ header, id, last });
        switch (encoding) {
            .plain => try writer.writeAll(chunk),
            .base64 => {
                var b64_buf: [std.base64.standard.Encoder.calcSize(max_chunk_raw)]u8 = undefined;
                try writer.writeAll(std.base64.standard.Encoder.encode(
                    &b64_buf,
                    chunk,
                ));
            },
        }
        try writer.writeAll(terminator.string());
    }
}
pub fn encodeError(
    writer: *std.Io.Writer,
    kind: enum { drop, drag },
    keys: RequestKeys,
    client_id: u32,
    errno: Errno,
    desc: []const u8,
    terminator: Terminator,
) std.Io.Writer.Error!void {
    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "t={c}{f}", .{
        @as(u8, switch (kind) {
            .drop => 'R',
            .drag => 'E',
        }),
        keys,
    }) catch unreachable;
    var payload_buf: [256]u8 = undefined;
    const payload = if (desc.len > 0) std.fmt.bufPrint(
        &payload_buf,
        "{t}:{s}",
        .{ errno, desc },
    ) catch unreachable else @tagName(errno);
    try encode(writer, header, client_id, payload, .plain, terminator);
}
test "encode: bare message" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(&writer, "t=q", 0, "", .plain, .st);
    try testing.expectEqualStrings("\x1b]72;t=q\x1b\\", writer.buffered());
}
test "encode: bare message with client id" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(&writer, "t=q", 7, "", .plain, .st);
    try testing.expectEqualStrings("\x1b]72;t=q:i=7\x1b\\", writer.buffered());
}
test "encode: plain payload single chunk" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(&writer, "t=m:x=1:y=2", 0, "text/plain ", .plain, .st);
    try testing.expectEqualStrings(
        "\x1b]72;t=m:x=1:y=2:m=0;text/plain \x1b\\",
        writer.buffered(),
    );
}
test "encode: base64 payload chunking" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const data = [_]u8{'A'} ** (max_chunk_raw + 1);
    try encode(&aw.writer, "t=r:x=1", 3, &data, .base64, .st);
    const out = aw.written();
    const prefix = "\x1b]72;t=r:x=1:i=3:m=1;";
    try testing.expect(std.mem.startsWith(u8, out, prefix));
    const first_end = std.mem.indexOf(u8, out, "\x1b\\").?;
    try testing.expectEqual(@as(usize, prefix.len + 4096), first_end);
    const rest = out[first_end + 2 ..];
    try testing.expect(std.mem.startsWith(u8, rest, "\x1b]72;t=r:x=1:i=3:m=0;"));
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(alloc);
    var it = std.mem.splitSequence(u8, out, "\x1b\\");
    while (it.next()) |osc| {
        if (osc.len == 0) continue;
        const payload_start = std.mem.indexOfScalar(u8, osc, ';').?;
        const payload = osc[std.mem.indexOfScalarPos(u8, osc, payload_start + 1, ';').? + 1 ..];
        const n = try std.base64.standard.Decoder.calcSizeForSlice(payload);
        const start = decoded.items.len;
        try decoded.resize(alloc, start + n);
        try std.base64.standard.Decoder.decode(decoded.items[start..], payload);
    }
    try testing.expectEqualSlices(u8, &data, decoded.items);
}
test "encodeError: with and without description" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try encodeError(&writer, .drop, .{ .x = 2 }, 0, .ENOENT, "drop data request index out of bounds", .st);
        try testing.expectEqualStrings(
            "\x1b]72;t=R:x=2:m=0;ENOENT:drop data request index out of bounds\x1b\\",
            writer.buffered(),
        );
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try encodeError(&writer, .drag, .{}, 5, .EPERM, "", .st);
        try testing.expectEqualStrings(
            "\x1b]72;t=E:i=5:m=0;EPERM\x1b\\",
            writer.buffered(),
        );
    }
}
test "RequestKeys: only non-zero keys written" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    {
        const s = try std.fmt.bufPrint(&buf, "{f}", .{RequestKeys{}});
        try testing.expectEqualStrings("", s);
    }
    {
        const s = try std.fmt.bufPrint(&buf, "{f}", .{RequestKeys{ .x = 1, .y = 2, .Y = 3 }});
        try testing.expectEqualStrings(":x=1:y=2:Y=3", s);
    }
    {
        const s = try std.fmt.bufPrint(&buf, "{f}", .{RequestKeys{ .Y = 4 }});
        try testing.expectEqualStrings(":Y=4", s);
    }
}
