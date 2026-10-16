const std = @import("std");
const testing = std.testing;
const lib = @import("lib.zig");
pub const Req = lib.Enum(lib.target, &.{
    "primary", 
    "secondary", 
    "tertiary", 
});
pub const Attributes = struct {
    primary: Primary = .{},
    secondary: Secondary = .{},
    tertiary: Tertiary = .{},
    pub fn encode(
        self: Attributes,
        req: Req,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (req) {
            .primary => try self.primary.encode(writer),
            .secondary => try self.secondary.encode(writer),
            .tertiary => try self.tertiary.encode(writer),
        }
    }
};
pub const Primary = struct {
    conformance_level: ConformanceLevel = .vt220,
    features: []const Feature = &.{.ansi_color},
    pub const Feature = enum(u16) {
        columns_132 = 1,
        printer = 2,
        regis = 3,
        sixel = 4,
        selective_erase = 6,
        user_defined_keys = 8,
        national_replacement = 9,
        technical_characters = 15,
        locator = 16,
        terminal_state = 17,
        windowing = 18,
        horizontal_scrolling = 21,
        ansi_color = 22,
        rectangular_editing = 28,
        ansi_text_locator = 29,
        clipboard = 52,
        _,
    };
    pub fn encode(self: Primary, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("\x1b[?{}", .{@intFromEnum(self.conformance_level)});
        for (self.features) |feature| try writer.print(";{}", .{@intFromEnum(feature)});
        try writer.writeAll("c");
    }
};
pub const Secondary = struct {
    device_type: DeviceType = .vt220,
    firmware_version: u16 = 0,
    rom_cartridge: u16 = 0,
    pub fn encode(self: Secondary, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("\x1b[>{};{};{}c", .{
            @intFromEnum(self.device_type),
            self.firmware_version,
            self.rom_cartridge,
        });
    }
};
pub const Tertiary = struct {
    unit_id: u32 = 0,
    pub fn encode(
        self: Tertiary,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print(
            "\x1bP!|{X:0>8}\x1b\\",
            .{self.unit_id},
        );
    }
};
pub const ConformanceLevel = enum(u16) {
    vt100 = 1,
    vt132 = 4,
    vt102 = 6,
    vt131 = 7,
    vt125 = 12,
    level_2 = 62,
    level_3 = 63,
    level_4 = 64,
    level_5 = 65,
    _,
    pub const vt101 = ConformanceLevel.vt100;
    pub const vt220 = ConformanceLevel.level_2;
    pub const vt240 = ConformanceLevel.level_2;
    pub const vt320 = ConformanceLevel.level_3;
    pub const vt340 = ConformanceLevel.level_3;
    pub const vt420 = ConformanceLevel.level_4;
    pub const vt510 = ConformanceLevel.level_5;
    pub const vt520 = ConformanceLevel.level_5;
    pub const vt525 = ConformanceLevel.level_5;
};
pub const DeviceType = enum(u16) {
    vt100 = 0,
    vt220 = 1,
    vt240 = 2,
    vt330 = 18,
    vt340 = 19,
    vt320 = 24,
    vt382 = 32,
    vt420 = 41,
    vt510 = 61,
    vt520 = 64,
    vt525 = 65,
    _,
};
test "primary default" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try (Primary{}).encode(&writer);
    try testing.expectEqualStrings("\x1b[?62;22c", writer.buffered());
}
test "primary with clipboard" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try (Primary{ .features = &.{ .ansi_color, .clipboard } }).encode(&writer);
    try testing.expectEqualStrings("\x1b[?62;22;52c", writer.buffered());
}
test "primary with multiple features" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try (Primary{
        .conformance_level = .vt420,
        .features = &.{ .columns_132, .selective_erase, .ansi_color },
    }).encode(&writer);
    try testing.expectEqualStrings("\x1b[?64;1;6;22c", writer.buffered());
}
test "primary no features" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try (Primary{
        .conformance_level = .vt100,
        .features = &.{},
    }).encode(&writer);
    try testing.expectEqualStrings("\x1b[?1c", writer.buffered());
}
test "secondary default" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try (Secondary{}).encode(&writer);
    try testing.expectEqualStrings("\x1b[>1;0;0c", writer.buffered());
}
test "tertiary default" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try (Tertiary{}).encode(&writer);
    try testing.expectEqualStrings("\x1bP!|00000000\x1b\\", writer.buffered());
}
test "tertiary custom unit id" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try (Tertiary{ .unit_id = 0xAABBCCDD }).encode(&writer);
    try testing.expectEqualStrings("\x1bP!|AABBCCDD\x1b\\", writer.buffered());
}
