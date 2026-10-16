const std = @import("std");
const test_fixture = @import("fixture.zig");
const io = @import("io.zig");
pub const magic = "GHOSTSNP";
pub const version: u16 = 1;
pub const encoded_len = computeLen();
comptime {
    std.debug.assert(encoded_len == 10);
}
pub const DecodeError = std.Io.Reader.Error || error{
    InvalidMagic,
    UnsupportedVersion,
};
pub fn encode(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(magic);
    try io.writeInt(writer, u16, version);
}
pub fn decode(reader: *std.Io.Reader) DecodeError!void {
    var actual_magic: [magic.len]u8 = undefined;
    try reader.readSliceAll(&actual_magic);
    if (!std.mem.eql(u8, magic, &actual_magic)) return error.InvalidMagic;
    const actual_version = try io.readInt(reader, u16);
    if (actual_version != version) return error.UnsupportedVersion;
}
fn computeLen() usize {
    comptime {
        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        encode(&writer) catch unreachable;
        return writer.end;
    }
}
const test_golden_fixture = test_fixture.parse(@embedFile("testdata/envelope-v1.hex"));
test "golden encoding" {
    var buf: [encoded_len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(&writer);
    try test_fixture.expectEqual(
        .bytes,
        "src/terminal/snapshot/testdata/envelope-v1.hex",
        "snapshot_fixture-envelope-v1.hex",
        &test_golden_fixture,
        writer.buffered(),
    );
    var reader: std.Io.Reader = .fixed(&test_golden_fixture);
    try decode(&reader);
}
test "reject invalid magic and version" {
    var invalid_magic: std.Io.Reader = .fixed("GHOSTSNX\x01\x00");
    try std.testing.expectError(error.InvalidMagic, decode(&invalid_magic));
    var invalid_version: std.Io.Reader = .fixed("GHOSTSNP\x00\x00");
    try std.testing.expectError(
        error.UnsupportedVersion,
        decode(&invalid_version),
    );
}
test "reject every truncation" {
    for (0..encoded_len) |len| {
        var reader: std.Io.Reader = .fixed(test_golden_fixture[0..len]);
        try std.testing.expectError(error.EndOfStream, decode(&reader));
    }
}
