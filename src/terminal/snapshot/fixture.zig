const std = @import("std");
const envelope = @import("envelope.zig");
const record = @import("record.zig");
const log = std.log.scoped(.snapshot_fixture);
pub const Kind = enum {
    bytes,
    page,
    snapshot,
};
pub fn parse(comptime source: []const u8) [decodedLen(source)]u8 {
    comptime {
        @setEvalBranchQuota(100_000_000);
        var result: [decodedLen(source)]u8 = undefined;
        var source_index: usize = 0;
        var result_index: usize = 0;
        while (source_index < source.len) {
            skipIgnored(source, &source_index);
            if (source_index == source.len) break;
            if (source_index + 1 >= source.len) {
                @compileError("snapshot fixture ends with one hex digit");
            }
            result[result_index] =
                hexNibble(source[source_index]) << 4 |
                hexNibble(source[source_index + 1]);
            result_index += 1;
            source_index += 2;
            if (source_index < source.len and
                !std.ascii.isWhitespace(source[source_index]) and
                source[source_index] != '#')
            {
                @compileError(
                    "snapshot fixture hex bytes must be separated by whitespace",
                );
            }
        }
        return result;
    }
}
pub fn expectEqual(
    kind: Kind,
    reference_path: []const u8,
    candidate_name: []const u8,
    expected: []const u8,
    actual: []const u8,
) !void {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const reference_source = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        reference_path,
        alloc,
        .unlimited,
    );
    defer alloc.free(reference_source);
    {
        var candidate_file = try tmp.dir.createFile(
            testing.io,
            candidate_name,
            .{},
        );
        defer candidate_file.close(testing.io);
        var write_buffer: [4096]u8 = undefined;
        var candidate_writer = candidate_file.writer(
            testing.io,
            &write_buffer,
        );
        try format(
            kind,
            reference_source,
            actual,
            &candidate_writer.interface,
        );
        try candidate_writer.interface.flush();
    }
    if (std.mem.eql(u8, expected, actual)) return;
    const tmp_path = try tmp.dir.realPathFileAlloc(
        testing.io,
        candidate_name,
        alloc,
    );
    defer alloc.free(tmp_path);
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(
        testing.io,
        ".",
        alloc,
    );
    defer alloc.free(cwd);
    const candidate_path = try std.fs.path.join(
        alloc,
        &.{ cwd, candidate_name },
    );
    defer alloc.free(candidate_path);
    try std.Io.Dir.copyFileAbsolute(
        tmp_path,
        candidate_path,
        testing.io,
        .{},
    );
    const difference = difference: {
        const shared_len = @min(expected.len, actual.len);
        for (
            expected[0..shared_len],
            actual[0..shared_len],
            0..,
        ) |expected_byte, actual_byte, index| {
            if (expected_byte != actual_byte) break :difference index;
        }
        break :difference shared_len;
    };
    log.err(
        "snapshot fixture differs reference={s} candidate={s} " ++
            "offset=0x{x} expected_len={} actual_len={}",
        .{
            reference_path,
            candidate_path,
            difference,
            expected.len,
            actual.len,
        },
    );
    return error.TestExpectedEqual;
}
fn decodedLen(comptime source: []const u8) usize {
    comptime {
        @setEvalBranchQuota(100_000_000);
        var index: usize = 0;
        var result: usize = 0;
        while (index < source.len) {
            skipIgnored(source, &index);
            if (index == source.len) break;
            if (index + 1 >= source.len) {
                @compileError("snapshot fixture ends with one hex digit");
            }
            _ = hexNibble(source[index]);
            _ = hexNibble(source[index + 1]);
            result += 1;
            index += 2;
            if (index < source.len and
                !std.ascii.isWhitespace(source[index]) and
                source[index] != '#')
            {
                @compileError(
                    "snapshot fixture hex bytes must be separated by whitespace",
                );
            }
        }
        return result;
    }
}
fn skipIgnored(comptime source: []const u8, index: *usize) void {
    while (index.* < source.len) {
        if (std.ascii.isWhitespace(source[index.*])) {
            index.* += 1;
            continue;
        }
        if (source[index.*] != '#') return;
        while (index.* < source.len and source[index.*] != '\n') {
            index.* += 1;
        }
    }
}
fn hexNibble(comptime value: u8) u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        'A'...'F' => value - 'A' + 10,
        else => @compileError("snapshot fixture contains a non-hex digit"),
    };
}
fn format(
    kind: Kind,
    reference_source: []const u8,
    bytes: []const u8,
    writer: *std.Io.Writer,
) (std.Io.Writer.Error || error{InvalidKaitaiMetadata})!void {
    try writer.writeAll("# Wasp snapshot fixture\n");
    try writeKaitaiMetadata(reference_source, writer);
    try writer.print(
        "# Wire version: {}\n" ++
            "# Generated by its snapshot test; review before replacing.\n" ++
            "# On mismatch, the candidate is copied to the repository root.\n",
        .{envelope.version},
    );
    switch (kind) {
        .bytes => try writeSection(
            "encoded bytes",
            bytes,
            0,
            bytes.len,
            writer,
        ),
        .page => try formatPage(bytes, writer),
        .snapshot => try formatSnapshot(bytes, writer),
    }
}
fn writeKaitaiMetadata(
    reference_source: []const u8,
    writer: *std.Io.Writer,
) (std.Io.Writer.Error || error{InvalidKaitaiMetadata})!void {
    const prefixes = [_][]const u8{
        "# Kaitai type:",
        "# Kaitai params:",
        "# Kaitai offset:",
    };
    var found = [_]bool{false} ** prefixes.len;
    var lines = std.mem.splitScalar(u8, reference_source, '\n');
    while (lines.next()) |untrimmed| {
        const line = std.mem.trim(u8, untrimmed, " \r");
        for (prefixes, &found) |prefix, *seen| {
            if (!std.mem.startsWith(u8, line, prefix)) continue;
            if (seen.*) return error.InvalidKaitaiMetadata;
            seen.* = true;
            try writer.print("{s}\n", .{line});
            break;
        }
    }
    for (found) |seen| {
        if (!seen) return error.InvalidKaitaiMetadata;
    }
}
fn formatPage(
    bytes: []const u8,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const header_end = @min(bytes.len, 20);
    try writeSection("PAGE header", bytes, 0, header_end, writer);
    if (header_end < bytes.len) {
        try writeSection(
            "style and hyperlink tables, rows, and cells",
            bytes,
            header_end,
            bytes.len,
            writer,
        );
    }
}
fn formatSnapshot(
    bytes: []const u8,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const envelope_end = @min(bytes.len, envelope.encoded_len);
    try writeSection("snapshot envelope", bytes, 0, envelope_end, writer);
    var offset: usize = envelope_end;
    while (offset < bytes.len) {
        if (bytes.len - offset < record.Header.len) {
            try writeSection(
                "trailing partial record",
                bytes,
                offset,
                bytes.len,
                writer,
            );
            return;
        }
        const tag_raw = std.mem.readInt(
            u16,
            bytes[offset..][0..2],
            .little,
        );
        const payload_len: u32 = std.mem.readInt(
            u32,
            bytes[offset + 2 ..][0..4],
            .little,
        );
        const record_end: usize = @min(
            bytes.len,
            offset + record.Header.len + @as(usize, payload_len),
        );
        if (std.enums.fromInt(record.Tag, tag_raw)) |tag| {
            try writer.print(
                "\n# offset 0x{x:0>8}: {s} record, payload {} bytes\n",
                .{ offset, @tagName(tag), payload_len },
            );
        } else {
            try writer.print(
                "\n# offset 0x{x:0>8}: unknown record {}, payload {} bytes\n",
                .{ offset, tag_raw, payload_len },
            );
        }
        try writeHex(bytes, offset, record_end, writer);
        offset = record_end;
    }
}
fn writeSection(
    name: []const u8,
    bytes: []const u8,
    start: usize,
    end: usize,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try writer.print(
        "\n# offset 0x{x:0>8}: {s}\n",
        .{ start, name },
    );
    try writeHex(bytes, start, end, writer);
}
fn writeHex(
    bytes: []const u8,
    start: usize,
    end: usize,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const digits = "0123456789abcdef";
    var offset = start;
    while (offset < end) {
        const line_end = @min(end, offset + 16);
        for (bytes[offset..line_end], 0..) |byte, index| {
            if (index != 0) try writer.writeByte(' ');
            try writer.writeByte(digits[byte >> 4]);
            try writer.writeByte(digits[byte & 0x0f]);
        }
        try writer.print(" # 0x{x:0>8}\n", .{offset});
        offset = line_end;
    }
}
