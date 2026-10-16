const std = @import("std");
const clipboard = @import("../clipboard.zig");
const oscpkg = @import("../osc.zig");
const protocol = @import("../osc/parsers/kitty_clipboard_protocol.zig");
const b64 = std.base64.standard.Encoder;
const Content = clipboard.Content;
const Operation = protocol.Operation;
const Status = protocol.Status;
const Terminator = oscpkg.Terminator;
pub const read_chunk_size = 4096;
pub const max_read_mimes = 4;
pub const targets_mime = ".";
pub const max_listing_mimes = 16;
pub const Response = struct {
    op: Operation,
    status: Status,
    primary: bool = false,
    id: []const u8 = "",
    mime: ?[]const u8 = null,
    pw: ?[]const u8 = null,
    payload: []const u8 = "",
    terminator: Terminator = .st,
    pub fn encode(
        self: *const Response,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try self.encodeMetadata(writer);
        if (self.payload.len > 0) {
            try writer.writeAll(";");
            try b64.encodeWriter(writer, self.payload);
        }
        try writer.writeAll(self.terminator.string());
    }
    fn encodeMetadata(
        self: *const Response,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("\x1b]5522;type={t}:status={t}", .{ self.op, self.status });
        if (self.primary) try writer.writeAll(":loc=primary");
        if (self.id.len > 0) try writer.print(":id={s}", .{self.id});
        if (self.mime) |mime| {
            try writer.writeAll(":mime=");
            try b64.encodeWriter(writer, mime);
        }
        if (self.pw) |pw| {
            try writer.writeAll(":pw=");
            try b64.encodeWriter(writer, pw);
        }
    }
};
pub const ReadSuccess = struct {
    primary: bool = false,
    id: []const u8 = "",
    pw: ?[]const u8 = null,
    list: bool = false,
    available: []const []const u8 = &.{},
    contents: []const Content = &.{},
    terminator: Terminator = .st,
    pub fn encode(
        self: *const ReadSuccess,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try (Response{
            .op = .read,
            .status = .OK,
            .primary = self.primary,
            .id = self.id,
            .pw = self.pw,
            .terminator = self.terminator,
        }).encode(writer);
        if (self.list) try self.encodeListing(writer);
        for (self.contents) |content| {
            var i: usize = 0;
            while (i < content.data.len) {
                const n = @min(content.data.len - i, read_chunk_size);
                try (Response{
                    .op = .read,
                    .status = .DATA,
                    .id = self.id,
                    .mime = content.mime,
                    .pw = self.pw,
                    .payload = content.data[i..][0..n],
                    .terminator = self.terminator,
                }).encode(writer);
                i += n;
            }
        }
        try (Response{
            .op = .read,
            .status = .DONE,
            .id = self.id,
            .pw = self.pw,
            .terminator = self.terminator,
        }).encode(writer);
    }
    fn encodeListing(
        self: *const ReadSuccess,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const listing: Response = .{
            .op = .read,
            .status = .DATA,
            .id = self.id,
            .mime = targets_mime,
            .pw = self.pw,
            .terminator = self.terminator,
        };
        try listing.encodeMetadata(writer);
        if (self.available.len > 0) {
            try writer.writeAll(";");
            var raw: [read_chunk_size]u8 = undefined;
            var fixed: std.Io.Writer = .fixed(&raw);
            for (self.available, 0..) |mime, i| {
                const sep: usize = if (i > 0) 1 else 0;
                if (fixed.end + sep + mime.len + "\n".len > raw.len) break;
                if (i > 0) fixed.writeAll(" ") catch unreachable;
                fixed.writeAll(mime) catch unreachable;
            }
            fixed.writeAll("\n") catch unreachable;
            try b64.encodeWriter(writer, fixed.buffered());
        }
        try writer.writeAll(self.terminator.string());
    }
};
pub const PasteEvent = struct {
    primary: bool = false,
    pw: []const u8,
    available: []const []const u8,
    terminator: Terminator = .st,
    pub fn encode(
        self: *const PasteEvent,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try (ReadSuccess{
            .primary = self.primary,
            .pw = self.pw,
            .list = true,
            .available = self.available,
            .terminator = self.terminator,
        }).encode(writer);
    }
};
test "response: basic status packet" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try (Response{ .op = .write, .status = .DONE }).encode(&writer);
    try testing.expectEqualStrings(
        "\x1b]5522;type=write:status=DONE\x1b\\",
        writer.buffered(),
    );
}
test "response: id echo and terminator" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try (Response{
        .op = .write,
        .status = .EPERM,
        .id = "42",
        .terminator = .bel,
    }).encode(&writer);
    try testing.expectEqualStrings(
        "\x1b]5522;type=write:status=EPERM:id=42\x07",
        writer.buffered(),
    );
}
test "response: key order type,status,loc,id,mime,pw and payload" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try (Response{
        .op = .read,
        .status = .DATA,
        .primary = true,
        .id = "x",
        .mime = "text/plain",
        .pw = "otp",
        .payload = "Wasp",
    }).encode(&writer);
    try testing.expectEqualStrings(
        "\x1b]5522;type=read:status=DATA:loc=primary:id=x" ++
            ":mime=dGV4dC9wbGFpbg==:pw=b3Rw;R2hvc3R0eQ==\x1b\\",
        writer.buffered(),
    );
}
test "read success: empty request is OK then DONE" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try (ReadSuccess{ .id = "7" }).encode(&writer);
    try testing.expectEqualStrings(
        "\x1b]5522;type=read:status=OK:id=7\x1b\\" ++
            "\x1b]5522;type=read:status=DONE:id=7\x1b\\",
        writer.buffered(),
    );
}
test "read success: targets listing with text" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try (ReadSuccess{ .list = true, .available = &.{"text/plain"} }).encode(&writer);
    try testing.expectEqualStrings(
        "\x1b]5522;type=read:status=OK\x1b\\" ++
            "\x1b]5522;type=read:status=DATA:mime=Lg==;dGV4dC9wbGFpbgo=\x1b\\" ++
            "\x1b]5522;type=read:status=DONE\x1b\\",
        writer.buffered(),
    );
}
test "read success: targets listing joins multiple types" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try (ReadSuccess{
        .list = true,
        .available = &.{ "text/plain", "image/png" },
    }).encode(&writer);
    try testing.expectEqualStrings(
        "\x1b]5522;type=read:status=OK\x1b\\" ++
            "\x1b]5522;type=read:status=DATA:mime=Lg==;dGV4dC9wbGFpbiBpbWFnZS9wbmcK\x1b\\" ++
            "\x1b]5522;type=read:status=DONE\x1b\\",
        writer.buffered(),
    );
}
test "read success: empty targets listing packet still sent" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try (ReadSuccess{ .list = true }).encode(&writer);
    try testing.expectEqualStrings(
        "\x1b]5522;type=read:status=OK\x1b\\" ++
            "\x1b]5522;type=read:status=DATA:mime=Lg==\x1b\\" ++
            "\x1b]5522;type=read:status=DONE\x1b\\",
        writer.buffered(),
    );
}
test "read success: data chunks under requested mime" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try (ReadSuccess{
        .contents = &.{.{ .mime = "text/plain", .data = "Wasp" }},
    }).encode(&writer);
    try testing.expectEqualStrings(
        "\x1b]5522;type=read:status=OK\x1b\\" ++
            "\x1b]5522;type=read:status=DATA:mime=dGV4dC9wbGFpbg==;R2hvc3R0eQ==\x1b\\" ++
            "\x1b]5522;type=read:status=DONE\x1b\\",
        writer.buffered(),
    );
}
test "read success: each representation carries its own data" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try (ReadSuccess{
        .contents = &.{
            .{ .mime = "text/plain", .data = "hello" },
            .{ .mime = "image/png", .data = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a" },
        },
    }).encode(&writer);
    try testing.expectEqualStrings(
        "\x1b]5522;type=read:status=OK\x1b\\" ++
            "\x1b]5522;type=read:status=DATA:mime=dGV4dC9wbGFpbg==;aGVsbG8=\x1b\\" ++
            "\x1b]5522;type=read:status=DATA:mime=aW1hZ2UvcG5n;iVBORw0KGgo=\x1b\\" ++
            "\x1b]5522;type=read:status=DONE\x1b\\",
        writer.buffered(),
    );
}
test "read success: chunking at read_chunk_size" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const data = "z" ** (read_chunk_size + 1);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try (ReadSuccess{
        .contents = &.{.{ .mime = "text/plain", .data = data }},
    }).encode(&aw.writer);
    const count = std.mem.count(u8, aw.written(), "\x1b]5522;");
    try testing.expectEqual(@as(usize, 4), count);
    const Encoder = std.base64.standard.Encoder;
    var chunk_buf: [Encoder.calcSize(read_chunk_size)]u8 = undefined;
    const first = Encoder.encode(&chunk_buf, data[0..read_chunk_size]);
    try testing.expect(std.mem.indexOf(u8, aw.written(), first) != null);
}
test "read success: no data packets for empty clipboard" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try (ReadSuccess{
        .contents = &.{.{ .mime = "text/plain", .data = "" }},
    }).encode(&writer);
    try testing.expectEqualStrings(
        "\x1b]5522;type=read:status=OK\x1b\\" ++
            "\x1b]5522;type=read:status=DONE\x1b\\",
        writer.buffered(),
    );
}
test "read success: paste event carries pw in every packet" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try (ReadSuccess{
        .list = true,
        .pw = "otp",
        .available = &.{"text/plain"},
    }).encode(&writer);
    try testing.expectEqualStrings(
        "\x1b]5522;type=read:status=OK:pw=b3Rw\x1b\\" ++
            "\x1b]5522;type=read:status=DATA:mime=Lg==:pw=b3Rw;dGV4dC9wbGFpbgo=\x1b\\" ++
            "\x1b]5522;type=read:status=DONE:pw=b3Rw\x1b\\",
        writer.buffered(),
    );
}
test "paste event: pw in every packet, listing of every type" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try (PasteEvent{
        .pw = "otp",
        .available = &.{ "text/plain", "image/png" },
    }).encode(&writer);
    try testing.expectEqualStrings(
        "\x1b]5522;type=read:status=OK:pw=b3Rw\x1b\\" ++
            "\x1b]5522;type=read:status=DATA:mime=Lg==:pw=b3Rw;dGV4dC9wbGFpbiBpbWFnZS9wbmcK\x1b\\" ++
            "\x1b]5522;type=read:status=DONE:pw=b3Rw\x1b\\",
        writer.buffered(),
    );
}
test "paste event: primary is reported only on the OK packet" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try (PasteEvent{
        .primary = true,
        .pw = "otp",
        .available = &.{"text/plain"},
        .terminator = .bel,
    }).encode(&writer);
    try testing.expectEqualStrings(
        "\x1b]5522;type=read:status=OK:loc=primary:pw=b3Rw\x07" ++
            "\x1b]5522;type=read:status=DATA:mime=Lg==:pw=b3Rw;dGV4dC9wbGFpbgo=\x07" ++
            "\x1b]5522;type=read:status=DONE:pw=b3Rw\x07",
        writer.buffered(),
    );
}
test "paste event: empty listing packet is still sent" {
    const testing = std.testing;
    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try (PasteEvent{ .pw = "otp", .available = &.{} }).encode(&writer);
    try testing.expectEqualStrings(
        "\x1b]5522;type=read:status=OK:pw=b3Rw\x1b\\" ++
            "\x1b]5522;type=read:status=DATA:mime=Lg==:pw=b3Rw\x1b\\" ++
            "\x1b]5522;type=read:status=DONE:pw=b3Rw\x1b\\",
        writer.buffered(),
    );
}
