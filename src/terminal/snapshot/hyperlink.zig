const std = @import("std");
const Allocator = std.mem.Allocator;
const test_fixture = @import("fixture.zig");
const io = @import("io.zig");
const terminal_hyperlink = @import("../hyperlink.zig");
const terminal_page = @import("../page.zig");
const terminal_size = @import("../size.zig");
const Kind = enum(u8) {
    implicit = 1,
    explicit = 2,
};
pub const EncodeError = std.Io.Writer.Error || error{
    InvalidUri,
    InvalidExplicitId,
    StringTooLong,
};
pub const DecodeError = std.Io.Reader.Error || Allocator.Error || error{
    InvalidKind,
    InvalidUri,
    InvalidExplicitId,
};
pub const DecodePageError = std.Io.Reader.Error || error{
    InvalidKind,
};
pub fn encode(
    value: terminal_hyperlink.Hyperlink,
    writer: *std.Io.Writer,
) EncodeError!void {
    if (value.uri.len == 0) return error.InvalidUri;
    if (value.uri.len > std.math.maxInt(u32)) return error.StringTooLong;
    if (value.id == .explicit) {
        const id = value.id.explicit;
        if (id.len == 0) return error.InvalidExplicitId;
        if (id.len > std.math.maxInt(u32)) return error.StringTooLong;
    }
    switch (value.id) {
        .implicit => |id| {
            try writer.writeByte(@intFromEnum(Kind.implicit));
            try io.writeInt(writer, u32, id);
            try io.writeInt(writer, u32, @intCast(value.uri.len));
            try writer.writeAll(value.uri);
        },
        .explicit => |id| {
            try writer.writeByte(@intFromEnum(Kind.explicit));
            try io.writeInt(writer, u32, @intCast(id.len));
            try writer.writeAll(id);
            try io.writeInt(writer, u32, @intCast(value.uri.len));
            try writer.writeAll(value.uri);
        },
    }
}
pub fn decode(
    reader: *std.Io.Reader,
    alloc: Allocator,
) DecodeError!terminal_hyperlink.Hyperlink {
    const kind_raw = try reader.takeByte();
    const kind = std.enums.fromInt(Kind, kind_raw) orelse
        return error.InvalidKind;
    return switch (kind) {
        .implicit => implicit: {
            const id = try io.readInt(reader, u32);
            const uri_len: usize = @intCast(try io.readInt(reader, u32));
            if (uri_len == 0) return error.InvalidUri;
            const uri = try alloc.alloc(u8, uri_len);
            errdefer alloc.free(uri);
            try reader.readSliceAll(uri);
            break :implicit .{
                .id = .{ .implicit = id },
                .uri = uri,
            };
        },
        .explicit => explicit: {
            const id_len: usize = @intCast(try io.readInt(reader, u32));
            if (id_len == 0) return error.InvalidExplicitId;
            const id = try alloc.alloc(u8, id_len);
            errdefer alloc.free(id);
            try reader.readSliceAll(id);
            const uri_len: usize = @intCast(try io.readInt(reader, u32));
            if (uri_len == 0) return error.InvalidUri;
            const uri = try alloc.alloc(u8, uri_len);
            errdefer alloc.free(uri);
            try reader.readSliceAll(uri);
            break :explicit .{
                .id = .{ .explicit = id },
                .uri = uri,
            };
        },
    };
}
pub fn decodePage(
    page: *terminal_page.Page,
    reader: *std.Io.Reader,
) DecodePageError!terminal_hyperlink.Id {
    const kind_raw = try reader.takeByte();
    const kind = std.enums.fromInt(Kind, kind_raw) orelse
        return error.InvalidKind;
    const entry: terminal_hyperlink.PageEntry = switch (kind) {
        .implicit => implicit: {
            const id = try io.readInt(reader, u32);
            const uri_len: usize = @intCast(try io.readInt(reader, u32));
            if (uri_len == 0) return 0;
            const uri = decodePageString(
                page,
                reader,
                uri_len,
            ) catch |err| switch (err) {
                error.StringsOutOfMemory => {
                    try reader.discardAll(uri_len);
                    return 0;
                },
                else => |read_err| return read_err,
            };
            break :implicit .{
                .id = .{ .implicit = id },
                .uri = uri,
            };
        },
        .explicit => explicit: {
            const id_len: usize = @intCast(try io.readInt(reader, u32));
            if (id_len == 0) {
                const uri_len: usize = @intCast(
                    try io.readInt(reader, u32),
                );
                try reader.discardAll(uri_len);
                return 0;
            }
            const id = decodePageString(
                page,
                reader,
                id_len,
            ) catch |err| switch (err) {
                error.StringsOutOfMemory => {
                    try reader.discardAll(id_len);
                    const uri_len: usize = @intCast(
                        try io.readInt(reader, u32),
                    );
                    try reader.discardAll(uri_len);
                    return 0;
                },
                else => |read_err| return read_err,
            };
            errdefer page.string_alloc.free(
                page.memory,
                id.slice(page.memory),
            );
            const uri_len: usize = @intCast(try io.readInt(reader, u32));
            if (uri_len == 0) {
                page.string_alloc.free(
                    page.memory,
                    id.slice(page.memory),
                );
                return 0;
            }
            const uri = decodePageString(
                page,
                reader,
                uri_len,
            ) catch |err| switch (err) {
                error.StringsOutOfMemory => {
                    try reader.discardAll(uri_len);
                    page.string_alloc.free(
                        page.memory,
                        id.slice(page.memory),
                    );
                    return 0;
                },
                else => |read_err| return read_err,
            };
            break :explicit .{
                .id = .{ .explicit = id },
                .uri = uri,
            };
        },
    };
    return page.hyperlink_set.addContext(
        page.memory,
        entry,
        .{ .page = page },
    ) catch {
        entry.free(page);
        return 0;
    };
}
fn decodePageString(
    page: *terminal_page.Page,
    reader: *std.Io.Reader,
    len: usize,
) (std.Io.Reader.Error || error{StringsOutOfMemory})!terminal_size.Offset(u8).Slice {
    std.debug.assert(len > 0);
    const value = page.string_alloc.alloc(
        u8,
        page.memory,
        len,
    ) catch return error.StringsOutOfMemory;
    errdefer page.string_alloc.free(page.memory, value);
    try reader.readSliceAll(value);
    return .{
        .len = value.len,
        .offset = terminal_size.getOffset(
            u8,
            page.memory,
            &value[0],
        ),
    };
}
const test_implicit_fixture = test_fixture.parse(@embedFile("testdata/hyperlink-implicit-v1.hex"));
const test_explicit_fixture = test_fixture.parse(@embedFile("testdata/hyperlink-explicit-v1.hex"));
test "golden implicit encoding" {
    const value: terminal_hyperlink.Hyperlink = .{
        .id = .{ .implicit = 0x01020304 },
        .uri = "uri",
    };
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(value, &writer);
    try test_fixture.expectEqual(
        .bytes,
        "src/terminal/snapshot/testdata/hyperlink-implicit-v1.hex",
        "snapshot_fixture-hyperlink-implicit-v1.hex",
        &test_implicit_fixture,
        writer.buffered(),
    );
    var reader: std.Io.Reader = .fixed(&test_implicit_fixture);
    var decoded = try decode(&reader, std.testing.allocator);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualDeep(value, decoded);
}
test "golden explicit encoding" {
    const value: terminal_hyperlink.Hyperlink = .{
        .id = .{ .explicit = "id" },
        .uri = "uri",
    };
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(value, &writer);
    try test_fixture.expectEqual(
        .bytes,
        "src/terminal/snapshot/testdata/hyperlink-explicit-v1.hex",
        "snapshot_fixture-hyperlink-explicit-v1.hex",
        &test_explicit_fixture,
        writer.buffered(),
    );
    var reader: std.Io.Reader = .fixed(&test_explicit_fixture);
    var decoded = try decode(&reader, std.testing.allocator);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualDeep(value, decoded);
}
test "encode rejects invalid strings before writing" {
    const cases = [_]struct {
        value: terminal_hyperlink.Hyperlink,
        expected: anyerror,
    }{
        .{
            .value = .{ .id = .{ .implicit = 1 }, .uri = "" },
            .expected = error.InvalidUri,
        },
        .{
            .value = .{ .id = .{ .explicit = "" }, .uri = "uri" },
            .expected = error.InvalidExplicitId,
        },
        .{
            .value = .{ .id = .{ .explicit = "id" }, .uri = "" },
            .expected = error.InvalidUri,
        },
    };
    for (cases) |case| {
        var encoded: [32]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&encoded);
        try std.testing.expectError(
            case.expected,
            encode(case.value, &writer),
        );
        try std.testing.expectEqual(@as(usize, 0), writer.end);
    }
}
test "decode rejects empty strings" {
    const cases = [_]struct {
        fixture: []const u8,
        expected: anyerror,
    }{
        .{
            .fixture = "\x01\x04\x03\x02\x01\x00\x00\x00\x00",
            .expected = error.InvalidUri,
        },
        .{
            .fixture = "\x02\x00\x00\x00\x00",
            .expected = error.InvalidExplicitId,
        },
        .{
            .fixture = "\x02\x02\x00\x00\x00id\x00\x00\x00\x00",
            .expected = error.InvalidUri,
        },
    };
    for (cases) |case| {
        var reader: std.Io.Reader = .fixed(case.fixture);
        try std.testing.expectError(
            case.expected,
            decode(&reader, std.testing.allocator),
        );
    }
}
test "decodePage ignores empty strings" {
    const fixtures = [_][]const u8{
        "\x01\x04\x03\x02\x01\x00\x00\x00\x00",
        "\x02\x00\x00\x00\x00\x03\x00\x00\x00uri",
        "\x02\x02\x00\x00\x00id\x00\x00\x00\x00",
    };
    for (fixtures) |fixture| {
        var page = try terminal_page.Page.init(.{
            .cols = 1,
            .rows = 1,
            .hyperlink_bytes = 512,
            .string_bytes = 16,
        });
        defer page.deinit();
        var reader: std.Io.Reader = .fixed(fixture);
        try std.testing.expectEqual(
            @as(terminal_hyperlink.Id, 0),
            try decodePage(&page, &reader),
        );
        try std.testing.expectEqual(@as(usize, 0), page.hyperlink_set.count());
        try std.testing.expectError(error.EndOfStream, reader.takeByte());
    }
}
test "decode rejects invalid kinds" {
    for ([_]u8{ 0, 3, std.math.maxInt(u8) }) |kind| {
        var fixture: [1]u8 = .{kind};
        var reader: std.Io.Reader = .fixed(&fixture);
        try std.testing.expectError(
            error.InvalidKind,
            decode(&reader, std.testing.allocator),
        );
    }
}
test "decode allocation failure" {
    {
        var reader: std.Io.Reader = .fixed(&test_implicit_fixture);
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = 0 },
        );
        try std.testing.expectError(
            error.OutOfMemory,
            decode(&reader, failing.allocator()),
        );
    }
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        var reader: std.Io.Reader = .fixed(&test_explicit_fixture);
        try std.testing.expectError(
            error.OutOfMemory,
            decode(&reader, failing.allocator()),
        );
    }
}
test "reject every truncation" {
    const fixtures: [2][]const u8 = .{
        &test_implicit_fixture,
        &test_explicit_fixture,
    };
    for (fixtures) |fixture| {
        for (0..fixture.len) |fixture_len| {
            var reader: std.Io.Reader = .fixed(fixture[0..fixture_len]);
            try std.testing.expectError(
                error.EndOfStream,
                decode(&reader, std.testing.allocator),
            );
        }
    }
}
