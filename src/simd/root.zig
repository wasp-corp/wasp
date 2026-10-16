const std = @import("std");
const codepoint_width = @import("codepoint_width.zig");
pub const base64 = @import("base64.zig");
pub const index_of = @import("index_of.zig");
pub const vt = @import("vt.zig");
pub const codepointWidth = codepoint_width.codepointWidth;
pub fn lanes(comptime T: type) ?comptime_int {
    const native = std.simd.suggestVectorLength(T) orelse return null;
    return native * 2;
}
test {
    @import("std").testing.refAllDecls(@This());
}
