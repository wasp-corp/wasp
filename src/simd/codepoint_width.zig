const std = @import("std");
const options = @import("build_options");
extern "c" fn wasp_simd_codepoint_width(u32) i8;
pub fn codepointWidth(cp: u32) i8 {
    if (comptime options.simd) return wasp_simd_codepoint_width(cp);
    const uucode = @import("uucode");
    if (cp > uucode.config.max_code_point) return 1;
    return @import("uucode").get(.width, @intCast(cp));
}
test "codepointWidth basic" {
    const testing = std.testing;
    try testing.expectEqual(@as(i8, 1), codepointWidth('a'));
    try testing.expectEqual(@as(i8, 1), codepointWidth(0x100));
    try testing.expectEqual(@as(i8, 2), codepointWidth(0x3400));
    try testing.expectEqual(@as(i8, 2), codepointWidth(0x2E3A));
    try testing.expectEqual(@as(i8, 2), codepointWidth(0x1F1E6));
    try testing.expectEqual(@as(i8, 2), codepointWidth(0x4E00));
    try testing.expectEqual(@as(i8, 2), codepointWidth(0xF900));
    try testing.expectEqual(@as(i8, 2), codepointWidth(0x20000));
    try testing.expectEqual(@as(i8, 2), codepointWidth(0x30000));
}
