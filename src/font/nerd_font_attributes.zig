const std = @import("std");
const lut = @import("../unicode/lut.zig");
const Constraint = @import("Glyph.zig").RenderOptions.Constraint;
const generated = @import("nerd_font_tables.zig").Tables(?Constraint);
pub const table: lut.Tables(?Constraint) = .{
    .stage1 = &generated.stage1,
    .stage2 = &generated.stage2,
    .stage3 = &generated.stage3,
};
const empty_block: u16 = 0;
comptime {
    if (generated.stage1.len != 0x2000) @compileError("stage1 must cover every u21 page");
    if (generated.stage3.len == 0 or generated.stage3[0] != null) {
        @compileError("stage3[0] must be null");
    }
    for (generated.stage2[0..256]) |entry| {
        if (entry != 0) @compileError("empty nerd-font page must be stage2 offset 0");
    }
}
pub inline fn getConstraint(cp: u21) ?Constraint {
    if (table.stage1[cp >> 8] == empty_block) return null;
    return table.get(cp);
}
test "Constraints lookup table" {
    const testing = std.testing;
    try testing.expect(getConstraint('A') == null);
    try testing.expect(getConstraint(0x30A2) == null); 
    try testing.expect(getConstraint(0xFF66) == null); 
    try testing.expect(getConstraint(0x2630) != null);
    try testing.expect(getConstraint(0x110000) == null);
    try testing.expect(getConstraint(std.math.maxInt(u21)) == null);
    var cp: u32 = 0;
    while (cp <= 0x10FFFF) {
        const scalar: u21 = @intCast(cp);
        if (table.stage1[scalar >> 8] == empty_block) {
            try testing.expect(getConstraint(scalar) == null);
            cp = (cp & ~@as(u32, 0xFF)) + 256;
            continue;
        }
        const full = table.get(scalar);
        const fast = getConstraint(scalar);
        if (full) |value| {
            try testing.expectEqual(value, fast.?);
        } else {
            try testing.expect(fast == null);
        }
        cp += 1;
    }
}
