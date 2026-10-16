const std = @import("std");
pub const Runtime = enum {
    none,
    gtk,
    win32,
    pub fn default(target: std.Target) Runtime {
        return switch (target.os.tag) {
            .linux, .freebsd => .gtk,
            .windows => .win32,
            else => .none,
        };
    }
};
test {
    _ = Runtime;
}
