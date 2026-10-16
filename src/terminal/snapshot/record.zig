const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const test_fixture = @import("fixture.zig");
const io = @import("io.zig");
pub const Crc32c = @import("../../crc32c.zig").Crc32c;
pub const Tag = enum(u16) {
    terminal = 1,
    screen = 2,
    page = 3,
    history = 4,
    ready = 5,
    finish = 6,
    continuation = 7,
};
pub const Header = struct {
    pub const len = computeLen();
    comptime {
        assert(len == 10);
    }
    tag: Tag,
    payload_len: u32,
    crc32c: u32,
    pub const DecodeError = std.Io.Reader.Error || error{InvalidTag};
    pub fn encode(
        self: Header,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try encodeChecksumPrefix(self.tag, self.payload_len, writer);
        try io.writeInt(writer, u32, self.crc32c);
    }
    pub fn decode(reader: *std.Io.Reader) DecodeError!Header {
        const tag_raw = try io.readInt(reader, u16);
        const tag = std.enums.fromInt(Tag, tag_raw) orelse {
            return error.InvalidTag;
        };
        return .{
            .tag = tag,
            .payload_len = try io.readInt(reader, u32),
            .crc32c = try io.readInt(reader, u32),
        };
    }
    fn computeLen() usize {
        comptime {
            var buf: [128]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buf);
            const header: Header = .{
                .tag = .terminal,
                .payload_len = 0,
                .crc32c = 0,
            };
            header.encode(&writer) catch unreachable;
            return writer.end;
        }
    }
};
pub const Checksum = struct {
    hashing: std.Io.Writer.Hashing(Crc32c),
    pub fn init(tag: Tag, payload_len: u32) Checksum {
        var result: Checksum = .{
            .hashing = .initHasher(.init(), &.{}),
        };
        encodeChecksumPrefix(
            tag,
            payload_len,
            &result.hashing.writer,
        ) catch unreachable;
        return result;
    }
    pub fn writer(self: *Checksum) *std.Io.Writer {
        return &self.hashing.writer;
    }
    pub fn final(self: *Checksum) u32 {
        self.hashing.writer.flush() catch unreachable;
        return self.hashing.hasher.final();
    }
};
pub const Writer = struct {
    destination: *std.Io.Writer,
    scratch: std.Io.Writer.Allocating,
    active_tag: ?Tag,
    pub fn init(
        alloc: Allocator,
        destination: *std.Io.Writer,
    ) Writer {
        return .{
            .destination = destination,
            .scratch = .init(alloc),
            .active_tag = null,
        };
    }
    pub fn deinit(self: *Writer) void {
        assert(self.active_tag == null);
        assert(self.scratch.writer.end == 0);
        self.scratch.deinit();
        self.* = undefined;
    }
    pub fn writer(self: *Writer) *std.Io.Writer {
        assert(self.active_tag == null);
        return self.destination;
    }
    pub fn begin(self: *Writer, tag: Tag) *std.Io.Writer {
        assert(self.active_tag == null);
        assert(self.scratch.writer.end == 0);
        self.active_tag = tag;
        return &self.scratch.writer;
    }
    pub const FinishError = std.Io.Writer.Error || error{
        PayloadTooLarge,
    };
    pub fn finish(self: *Writer) FinishError!void {
        assert(self.active_tag != null);
        const tag = self.active_tag.?;
        defer self.cancel();
        const payload = self.scratch.written();
        const payload_len = std.math.cast(
            u32,
            payload.len,
        ) orelse return error.PayloadTooLarge;
        var checksum: Checksum = .init(tag, payload_len);
        checksum.writer().writeAll(payload) catch unreachable;
        const header: Header = .{
            .tag = tag,
            .payload_len = payload_len,
            .crc32c = checksum.final(),
        };
        var header_bytes: [Header.len]u8 = undefined;
        var header_writer: std.Io.Writer = .fixed(&header_bytes);
        header.encode(&header_writer) catch unreachable;
        try self.destination.writeAll(&header_bytes);
        try self.destination.writeAll(payload);
    }
    pub fn cancel(self: *Writer) void {
        self.scratch.shrinkRetainingCapacity(0);
        self.active_tag = null;
    }
};
pub const Reader = struct {
    header: Header,
    limited_buffer: [1]u8,
    hashing_buffer: [256]u8,
    limited: std.Io.Reader.Limited,
    hashing: std.Io.Reader.Hashed(Crc32c),
    borrowed: ?Borrowed,
    const Borrowed = struct {
        source: *std.Io.Reader,
        payload: std.Io.Reader,
    };
    pub const InitError = Header.DecodeError;
    pub const FinishError = error{
        InvalidChecksum,
        PayloadNotExhausted,
    };
    pub fn init(
        self: *Reader,
        source: *std.Io.Reader,
    ) InitError!void {
        self.* = undefined;
        self.header = try Header.decode(source);
        if (source.bufferedLen() >= self.header.payload_len) {
            self.borrowed = .{
                .source = source,
                .payload = .fixed(
                    source.buffered()[0..self.header.payload_len],
                ),
            };
            return;
        }
        self.borrowed = null;
        self.limited = .init(
            source,
            .limited(self.header.payload_len),
            &self.limited_buffer,
        );
        const checksum: Checksum = .init(
            self.header.tag,
            self.header.payload_len,
        );
        self.hashing = .init(
            &self.limited.interface,
            checksum.hashing.hasher,
            &self.hashing_buffer,
        );
    }
    pub fn payloadReader(self: *Reader) *std.Io.Reader {
        if (self.borrowed) |*borrowed| return &borrowed.payload;
        return &self.hashing.reader;
    }
    pub fn finish(self: *Reader) FinishError!void {
        if (self.borrowed) |*borrowed| {
            if (borrowed.payload.bufferedLen() != 0) {
                return error.PayloadNotExhausted;
            }
            var checksum: Checksum = .init(
                self.header.tag,
                self.header.payload_len,
            );
            checksum.writer().writeAll(
                borrowed.payload.buffer[0..borrowed.payload.end],
            ) catch unreachable;
            if (checksum.final() != self.header.crc32c) {
                return error.InvalidChecksum;
            }
            borrowed.source.toss(self.header.payload_len);
            return;
        }
        if (self.hashing.reader.bufferedLen() != 0 or
            self.limited.remaining != .nothing)
        {
            return error.PayloadNotExhausted;
        }
        if (self.hashing.hasher.final() != self.header.crc32c) {
            return error.InvalidChecksum;
        }
    }
};
fn encodeChecksumPrefix(
    tag: Tag,
    payload_len: u32,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try io.writeInt(writer, u16, @intFromEnum(tag));
    try io.writeInt(writer, u32, payload_len);
}
const test_page_header_fixture = test_fixture.parse(
    @embedFile("testdata/record-page-header-v1.hex"),
);
test "golden PAGE record header and checksum" {
    const page_header =
        "\x50\x00\x18\x00\x00\x00\x00\x00" ++
        "\x00\x00\x00\x00\x00\x00\x00\x00" ++
        "\x00\x00\x00\x00\x00\x00\x00\x00";
    var checksum: Checksum = .init(.page, page_header.len);
    try checksum.writer().writeAll(page_header);
    try std.testing.expectEqual(@as(u32, 0x7178441b), checksum.final());
    const header: Header = .{
        .tag = .page,
        .payload_len = page_header.len,
        .crc32c = 0x7178441b,
    };
    var buf: [Header.len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try header.encode(&writer);
    try test_fixture.expectEqual(
        .bytes,
        "src/terminal/snapshot/testdata/record-page-header-v1.hex",
        "snapshot_fixture-record-page-header-v1.hex",
        &test_page_header_fixture,
        writer.buffered(),
    );
    var reader: std.Io.Reader = .fixed(&test_page_header_fixture);
    try std.testing.expectEqual(header, try Header.decode(&reader));
}
test "reject invalid tags" {
    for ([_]u16{ 0, 8, std.math.maxInt(u16) }) |tag| {
        var fixture = [_]u8{0} ** Header.len;
        std.mem.writeInt(u16, fixture[0..2], tag, .little);
        var reader: std.Io.Reader = .fixed(&fixture);
        try std.testing.expectError(error.InvalidTag, Header.decode(&reader));
    }
}
test "reject every header truncation" {
    for (0..Header.len) |len| {
        var reader: std.Io.Reader = .fixed(
            test_page_header_fixture[0..len],
        );
        try std.testing.expectError(error.EndOfStream, Header.decode(&reader));
    }
}
test "record reader verifies exhaustion and checksum" {
    const payload = "snapshot payload";
    var checksum: Checksum = .init(.page, payload.len);
    try checksum.writer().writeAll(payload);
    const header: Header = .{
        .tag = .page,
        .payload_len = payload.len,
        .crc32c = checksum.final(),
    };
    var encoded: [Header.len + payload.len + 4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try header.encode(&writer);
    try writer.writeAll(payload ++ "next");
    var source: std.Io.Reader = .fixed(writer.buffered());
    var record_reader: Reader = undefined;
    try record_reader.init(&source);
    var decoded: [payload.len]u8 = undefined;
    try record_reader.payloadReader().readSliceAll(&decoded);
    try record_reader.finish();
    try std.testing.expectEqualStrings(payload, &decoded);
    try std.testing.expectEqualStrings("next", try source.take(4));
}
test "record reader rejects remaining bytes and invalid checksum" {
    const payload = "payload";
    const header: Header = .{
        .tag = .page,
        .payload_len = payload.len,
        .crc32c = 0,
    };
    var encoded: [Header.len + payload.len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try header.encode(&writer);
    try writer.writeAll(payload);
    {
        var source: std.Io.Reader = .fixed(writer.buffered());
        var record_reader: Reader = undefined;
        try record_reader.init(&source);
        _ = try record_reader.payloadReader().takeByte();
        try std.testing.expectError(
            error.PayloadNotExhausted,
            record_reader.finish(),
        );
    }
    {
        var source: std.Io.Reader = .fixed(writer.buffered());
        var record_reader: Reader = undefined;
        try record_reader.init(&source);
        try record_reader.payloadReader().discardAll(payload.len);
        try std.testing.expectError(
            error.InvalidChecksum,
            record_reader.finish(),
        );
    }
}
test "payload limit does not consume the next record" {
    const payload = "ab";
    var checksum: Checksum = .init(.page, payload.len);
    try checksum.writer().writeAll(payload);
    const header: Header = .{
        .tag = .page,
        .payload_len = payload.len,
        .crc32c = checksum.final(),
    };
    var encoded: [Header.len + payload.len + 4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try header.encode(&writer);
    try writer.writeAll(payload ++ "next");
    var source: std.Io.Reader = .fixed(writer.buffered());
    var record_reader: Reader = undefined;
    try record_reader.init(&source);
    var too_long: [3]u8 = undefined;
    try std.testing.expectError(
        error.EndOfStream,
        record_reader.payloadReader().readSliceAll(&too_long),
    );
    try record_reader.finish();
    try std.testing.expectEqualStrings("next", try source.take(4));
}
test "record writer buffers a payload and appends framing" {
    var destination: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer destination.deinit();
    try destination.writer.writeAll("prefix");
    var stream: Writer = .init(
        std.testing.allocator,
        &destination.writer,
    );
    defer stream.deinit();
    const payload = stream.begin(.page);
    errdefer stream.cancel();
    try payload.writeAll("payload");
    try stream.finish();
    const encoded = destination.written();
    try std.testing.expectEqualStrings("prefix", encoded[0..6]);
    var source: std.Io.Reader = .fixed(encoded[6..]);
    var record_reader: Reader = undefined;
    try record_reader.init(&source);
    try std.testing.expectEqual(Tag.page, record_reader.header.tag);
    try std.testing.expectEqual(
        @as(u32, 7),
        record_reader.header.payload_len,
    );
    try std.testing.expectEqualStrings(
        "payload",
        try record_reader.payloadReader().take(7),
    );
    try record_reader.finish();
}
test "record writer cancel preserves preceding bytes" {
    var destination: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer destination.deinit();
    try destination.writer.writeAll("prefix");
    var stream: Writer = .init(
        std.testing.allocator,
        &destination.writer,
    );
    defer stream.deinit();
    const partial = stream.begin(.page);
    errdefer stream.cancel();
    try partial.writeAll("partial");
    const scratch_capacity = stream.scratch.writer.buffer.len;
    stream.cancel();
    try std.testing.expectEqualStrings("prefix", destination.written());
    try std.testing.expectEqual(
        scratch_capacity,
        stream.scratch.writer.buffer.len,
    );
    const next = stream.begin(.page);
    try next.writeAll("next");
    try stream.finish();
    var source: std.Io.Reader = .fixed(destination.written()[6..]);
    var record_reader: Reader = undefined;
    try record_reader.init(&source);
    try std.testing.expectEqualStrings(
        "next",
        try record_reader.payloadReader().take(4),
    );
    try record_reader.finish();
}
test "record writer clears active state after destination failure" {
    var destination_bytes: [Header.len]u8 = undefined;
    var destination: std.Io.Writer = .fixed(&destination_bytes);
    var stream: Writer = .init(std.testing.allocator, &destination);
    defer stream.deinit();
    const payload = stream.begin(.page);
    try payload.writeByte(0);
    try std.testing.expectError(error.WriteFailed, stream.finish());
    try std.testing.expectEqual(@as(?Tag, null), stream.active_tag);
    try std.testing.expectEqual(@as(usize, 0), stream.scratch.writer.end);
}
