const builtin = @import("builtin");
const std = @import("std");
pub fn version(comptime required: []const u8) void {
    const c = builtin.zig_version;
    const r = comptime std.SemanticVersion.parse(required) catch unreachable;
    if (c.major != r.major or c.minor != r.minor or c.patch < r.patch) {
        @compileError(std.fmt.comptimePrint(
            "build requires zig version \"{}.{}.{}\" or newer, but the current version is \"{}.{}.{}\".",
            .{
                r.major,
                r.minor,
                r.patch,
                c.major,
                c.minor,
                c.patch,
            },
        ));
    }
}