pub const lut = @import("lut.zig");
const grapheme = @import("grapheme.zig");
pub const table = @import("props_table.zig").table;
pub const Properties = @import("props.zig").Properties;
pub const GraphemeWidthEffect = grapheme.GraphemeWidthEffect;
pub const GraphemeWidth = grapheme.GraphemeWidth;
pub const graphemeBreak = grapheme.graphemeBreak;
pub const graphemeWidth = grapheme.graphemeWidth;
pub const graphemeWidthEffect = grapheme.graphemeWidthEffect;
pub fn codepointWidth(cp: u21) u2 {
    return table.get(cp).width;
}
test "codepointWidth" {
    const testing = @import("std").testing;
    try testing.expectEqual(1, codepointWidth('a'));
    try testing.expectEqual(1, codepointWidth(' '));
    try testing.expectEqual(1, codepointWidth(0x10FFFF)); 
    try testing.expectEqual(0, codepointWidth(0x00)); 
    try testing.expectEqual(0, codepointWidth(0x07)); 
    try testing.expectEqual(0, codepointWidth(0x1B)); 
    try testing.expectEqual(0, codepointWidth(0x7F)); 
    try testing.expectEqual(0, codepointWidth(0x80)); 
    try testing.expectEqual(0, codepointWidth(0x0301)); 
    try testing.expectEqual(0, codepointWidth(0x200B)); 
    try testing.expectEqual(0, codepointWidth(0x200D)); 
    try testing.expectEqual(0, codepointWidth(0xFE0F)); 
    try testing.expectEqual(0, codepointWidth(0xD800)); 
    try testing.expectEqual(2, codepointWidth(0x4E00)); 
    try testing.expectEqual(2, codepointWidth(0xFF21)); 
    try testing.expectEqual(2, codepointWidth(0xAC00)); 
    try testing.expectEqual(2, codepointWidth(0x1F600)); 
    try testing.expectEqual(2, codepointWidth(0x1F1E6)); 
    try testing.expectEqual(2, codepointWidth(0x2E3B)); 
}
test {
    @import("std").testing.refAllDecls(@This());
}
