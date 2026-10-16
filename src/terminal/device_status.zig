const std = @import("std");
const lib = @import("lib.zig");
pub const ColorScheme = lib.Enum(lib.target, &.{
    "light",
    "dark",
});
pub const Visibility = lib.Enum(lib.target, &.{
    "potentially_visible",
    "not_visible",
});
pub const max_color_scheme_report_encode_size = max: {
    var result: usize = 0;
    for (@typeInfo(ColorScheme).@"enum".fields) |field| {
        var discarding: std.Io.Writer.Discarding = .init(&.{});
        encodeColorSchemeReport(
            &discarding.writer,
            @enumFromInt(field.value),
        ) catch unreachable;
        result = @max(result, @as(usize, @intCast(discarding.count)));
    }
    break :max result;
};
pub fn encodeColorSchemeReport(
    writer: *std.Io.Writer,
    scheme: ColorScheme,
) std.Io.Writer.Error!void {
    try writer.writeAll(switch (scheme) {
        .dark => "\x1B[?997;1n",
        .light => "\x1B[?997;2n",
    });
}
pub const max_visibility_report_encode_size = "\x1B[?999;2n".len;
pub fn encodeVisibilityReport(
    writer: *std.Io.Writer,
    visibility: Visibility,
) std.Io.Writer.Error!void {
    try writer.writeAll(switch (visibility) {
        .potentially_visible => "\x1B[?999;1n",
        .not_visible => "\x1B[?999;2n",
    });
}
pub const Request = dsr_enum: {
    var names: [entries.len][]const u8 = undefined;
    var values: [entries.len]Tag.Backing = undefined;
    for (entries, &names, &values) |entry, *name, *value| {
        name.* = entry.name;
        value.* = @bitCast(Tag{
            .value = entry.value,
            .question = entry.question,
        });
    }
    break :dsr_enum @Enum(Tag.Backing, .exhaustive, &names, &values);
};
pub const Tag = packed struct(u16) {
    pub const Backing = @typeInfo(@This()).@"struct".backing_integer.?;
    value: u15,
    question: bool = false,
    test "order" {
        const t: Tag = .{ .value = 1 };
        const int: Backing = @bitCast(t);
        try std.testing.expectEqual(@as(Backing, 1), int);
    }
};
pub fn reqFromInt(v: u16, question: bool) ?Request {
    inline for (entries) |entry| {
        if (entry.value == v and entry.question == question) {
            const tag: Tag = .{ .question = question, .value = entry.value };
            const int: Tag.Backing = @bitCast(tag);
            return @enumFromInt(int);
        }
    }
    return null;
}
const Entry = struct {
    name: [:0]const u8,
    value: comptime_int,
    question: bool = false, 
};
const entries: []const Entry = &.{
    .{ .name = "operating_status", .value = 5 },
    .{ .name = "cursor_position", .value = 6 },
    .{ .name = "cursor_position_extended", .value = 6, .question = true },
    .{ .name = "color_scheme", .value = 996, .question = true },
    .{ .name = "visibility", .value = 998, .question = true },
};
test "encode color scheme report dark" {
    try std.testing.expectEqual(@as(usize, 9), max_color_scheme_report_encode_size);
    var buf: [max_color_scheme_report_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encodeColorSchemeReport(&writer, .dark);
    try std.testing.expectEqualStrings("\x1B[?997;1n", writer.buffered());
}
test "encode color scheme report light" {
    var buf: [max_color_scheme_report_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encodeColorSchemeReport(&writer, .light);
    try std.testing.expectEqualStrings("\x1B[?997;2n", writer.buffered());
}
test "encode visibility report" {
    var buf: [max_visibility_report_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encodeVisibilityReport(&writer, .potentially_visible);
    try std.testing.expectEqualStrings("\x1B[?999;1n", writer.buffered());
    writer = .fixed(&buf);
    try encodeVisibilityReport(&writer, .not_visible);
    try std.testing.expectEqualStrings("\x1B[?999;2n", writer.buffered());
}
