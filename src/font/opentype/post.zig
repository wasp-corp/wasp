const std = @import("std");
const sfnt = @import("sfnt.zig");
const compat_reader = @import("../../lib/compat/reader.zig");
pub const Post = extern struct {
    version: sfnt.Version16Dot16 align(1),
    italicAngle: sfnt.Fixed align(1),
    underlinePosition: sfnt.FWORD align(1),
    underlineThickness: sfnt.FWORD align(1),
    isFixedPitch: sfnt.uint32 align(1),
    minMemType42: sfnt.uint32 align(1),
    maxMemType42: sfnt.uint32 align(1),
    minMemType1: sfnt.uint32 align(1),
    maxMemType1: sfnt.uint32 align(1),
    pub fn init(data: []const u8) std.Io.Reader.Error!Post {
        var reader: std.Io.Reader = .fixed(data);
        return try compat_reader.readStructEndian(&reader, Post, .big);
    }
};
test "post" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const test_font = @import("../embedded.zig").julia_mono;
    const font = try sfnt.SFNT.init(test_font, alloc);
    defer font.deinit(alloc);
    const table = font.getTable("post").?;
    const post = try Post.init(table);
    try testing.expectEqualDeep(
        Post{
            .version = sfnt.Version16Dot16{ .minor = 0, .major = 2 },
            .italicAngle = sfnt.Fixed.from(0.0),
            .underlinePosition = -200,
            .underlineThickness = 100,
            .isFixedPitch = 1,
            .minMemType42 = 0,
            .maxMemType42 = 0,
            .minMemType1 = 0,
            .maxMemType1 = 0,
        },
        post,
    );
}
