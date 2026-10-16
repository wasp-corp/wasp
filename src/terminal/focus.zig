const std = @import("std");
const lib = @import("lib.zig");
pub const max_encode_size = 3;
pub const Event = lib.Enum(lib.target, &.{
    "gained",
    "lost",
});
pub fn encode(
    writer: *std.Io.Writer,
    event: Event,
) std.Io.Writer.Error!void {
    try writer.writeAll(switch (event) {
        .gained => "\x1B[I",
        .lost => "\x1B[O",
    });
}
test "encode focus gained" {
    var buf: [max_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(&writer, .gained);
    try std.testing.expectEqualStrings("\x1B[I", writer.buffered());
}
test "encode focus lost" {
    var buf: [max_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(&writer, .lost);
    try std.testing.expectEqualStrings("\x1B[O", writer.buffered());
}
