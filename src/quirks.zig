const std = @import("std");
const builtin = @import("builtin");
const font = @import("font/root.zig");
pub fn disableDefaultFontFeatures(face: *const font.Face) bool {
    _ = face;
    return false;
}
pub const inlineAssert = switch (builtin.mode) {
    .Debug => std.debug.assert,
    .ReleaseSmall, .ReleaseSafe, .ReleaseFast => (struct {
        inline fn assert(ok: bool) void {
            if (!ok) unreachable;
        }
    }).assert,
};
