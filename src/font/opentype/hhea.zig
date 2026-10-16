const std = @import("std");
const sfnt = @import("sfnt.zig");
const compat_reader = @import("../../lib/compat/reader.zig");
pub const Hhea = extern struct {
    majorVersion: sfnt.uint16 align(1),
    minorVersion: sfnt.uint16 align(1),
    ascender: sfnt.FWORD align(1),
    descender: sfnt.FWORD align(1),
    lineGap: sfnt.FWORD align(1),
    advanceWidthMax: sfnt.UFWORD align(1),
    minLeftSideBearing: sfnt.FWORD align(1),
    minRightSideBearing: sfnt.FWORD align(1),
    xMaxExtent: sfnt.FWORD align(1),
    caretSlopeRise: sfnt.int16 align(1),
    caretSlopeRun: sfnt.int16 align(1),
    caretOffset: sfnt.int16 align(1),
    _reserved0: sfnt.int16 align(1),
    _reserved1: sfnt.int16 align(1),
    _reserved2: sfnt.int16 align(1),
    _reserved3: sfnt.int16 align(1),
    metricDataFormat: sfnt.int16 align(1),
    numberOfHMetrics: sfnt.uint16 align(1),
    pub fn init(data: []const u8) !Hhea {
        var reader: std.Io.Reader = .fixed(data);
        return try compat_reader.readStructEndian(&reader, Hhea, .big);
    }
};
test "hhea" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const test_font = @import("../embedded.zig").julia_mono;
    const font = try sfnt.SFNT.init(test_font, alloc);
    defer font.deinit(alloc);
    const table = font.getTable("hhea").?;
    const hhea = try Hhea.init(table);
    try testing.expectEqualDeep(
        Hhea{
            .majorVersion = 1,
            .minorVersion = 0,
            .ascender = 1900,
            .descender = -450,
            .lineGap = 0,
            .advanceWidthMax = 1200,
            .minLeftSideBearing = -1000,
            .minRightSideBearing = -1889,
            .xMaxExtent = 3089,
            .caretSlopeRise = 1,
            .caretSlopeRun = 0,
            .caretOffset = 0,
            ._reserved0 = 0,
            ._reserved1 = 0,
            ._reserved2 = 0,
            ._reserved3 = 0,
            .metricDataFormat = 0,
            .numberOfHMetrics = 2,
        },
        hhea,
    );
}
