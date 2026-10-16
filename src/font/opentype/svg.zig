const std = @import("std");
const font = @import("../main.zig");
const compat_reader = @import("../../lib/compat/reader.zig");
pub const SVG = struct {
    start_glyph_id: u16,
    end_glyph_id: u16,
    records: []const [12]u8,
    pub fn init(data: []const u8) (error{SVGVersionNotSupported} || std.Io.Reader.Error)!SVG {
        var reader: std.Io.Reader = .fixed(data);
        if (try compat_reader.readerInt(&reader, u16, .big) != 0) {
            return error.SVGVersionNotSupported;
        }
        const offset = try compat_reader.readerInt(&reader, u32, .big);
        if (offset > data.len) return error.EndOfStream;
        reader.seek = offset;
        const len = try compat_reader.readerInt(&reader, u16, .big);
        const records: [*]const [12]u8 = @ptrCast(data[reader.seek..]);
        const start_range = try glyphRange(&records[0]);
        const end_range = if (len == 1) start_range else try glyphRange(&records[(len - 1)]);
        return .{
            .start_glyph_id = start_range[0],
            .end_glyph_id = end_range[1],
            .records = records[0..len],
        };
    }
    pub fn hasGlyph(self: SVG, glyph_id: u16) bool {
        if (glyph_id < self.start_glyph_id or glyph_id > self.end_glyph_id) {
            return false;
        }
        if (glyph_id == self.start_glyph_id or glyph_id == self.end_glyph_id) {
            return true;
        }
        return std.sort.binarySearch(
            [12]u8,
            self.records,
            glyph_id,
            compareGlyphId,
        ) != null;
    }
    fn compareGlyphId(glyph_id: u16, record: [12]u8) std.math.Order {
        const start, const end = glyphRange(&record) catch return .lt;
        if (glyph_id < start) {
            return .lt;
        } else if (glyph_id > end) {
            return .gt;
        } else {
            return .eq;
        }
    }
    fn glyphRange(record: []const u8) !struct { u16, u16 } {
        var reader: std.Io.Reader = .fixed(record);
        return .{
            try compat_reader.readerInt(&reader, u16, .big),
            try compat_reader.readerInt(&reader, u16, .big),
        };
    }
};
test "SVG" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.julia_mono;
    var lib = try font.Library.init(alloc);
    defer lib.deinit();
    var face = try font.Face.init(lib, testFont, .{ .size = .{ .points = 12 } });
    defer face.deinit();
    const table = (try face.copyTable(alloc, "SVG ")).?;
    defer alloc.free(table);
    const svg = try SVG.init(table);
    try testing.expectEqual(11482, svg.start_glyph_id);
    try testing.expectEqual(11482, svg.end_glyph_id);
    try testing.expect(svg.hasGlyph(11482));
}
test "SVG document list offset past end" {
    const testing = std.testing;
    const table = [_]u8{
        0, 0, 
        0, 0, 0, 7, 
    };
    try testing.expectError(error.EndOfStream, SVG.init(&table));
}
