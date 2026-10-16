const std = @import("std");
const sfnt = @import("sfnt.zig");
const compat_reader = @import("../../lib/compat/reader.zig");
pub const Head = extern struct {
    majorVersion: sfnt.uint16 align(1),
    minorVersion: sfnt.uint16 align(1),
    fontRevision: sfnt.Fixed align(1),
    checksumAdjustment: sfnt.uint32 align(1),
    magicNumber: sfnt.uint32 align(1),
    flags: sfnt.uint16 align(1),
    unitsPerEm: sfnt.uint16 align(1),
    created: sfnt.LONGDATETIME align(1),
    modified: sfnt.LONGDATETIME align(1),
    xMin: sfnt.int16 align(1),
    yMin: sfnt.int16 align(1),
    xMax: sfnt.int16 align(1),
    yMax: sfnt.int16 align(1),
    macStyle: sfnt.uint16 align(1),
    lowestRecPPEM: sfnt.uint16 align(1),
    fontDirectionHint: sfnt.int16 align(1),
    indexToLocFormat: sfnt.int16 align(1),
    glyphDataFormat: sfnt.int16 align(1),
    pub fn init(data: []const u8) std.Io.Reader.Error!Head {
        var reader: std.Io.Reader = .fixed(data);
        return try compat_reader.readStructEndian(&reader, Head, .big);
    }
};
test "head" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const test_font = @import("../embedded.zig").julia_mono;
    const font = try sfnt.SFNT.init(test_font, alloc);
    defer font.deinit(alloc);
    const table = font.getTable("head").?;
    const head = try Head.init(table);
    try testing.expectEqualDeep(
        Head{
            .majorVersion = 1,
            .minorVersion = 0,
            .fontRevision = sfnt.Fixed.from(0.05499267578125),
            .checksumAdjustment = 1007668681,
            .magicNumber = 1594834165,
            .flags = 7,
            .unitsPerEm = 2000,
            .created = 3797757830,
            .modified = 3797760444,
            .xMin = -1000,
            .yMin = -1058,
            .xMax = 3089,
            .yMax = 2400,
            .macStyle = 0,
            .lowestRecPPEM = 7,
            .fontDirectionHint = 2,
            .indexToLocFormat = 1,
            .glyphDataFormat = 0,
        },
        head,
    );
}
