const std = @import("std");
const builtin = @import("builtin");
pub const inlineAssert = switch (builtin.mode) {
    .Debug => std.debug.assert,
    .ReleaseSmall, .ReleaseSafe, .ReleaseFast => (struct {
        inline fn assert(ok: bool) void {
            if (!ok) unreachable;
        }
    }).assert,
};
