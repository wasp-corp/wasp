const std = @import("std");
const builtin = @import("builtin");
pub fn launchedByDbusActivation() bool {
    return switch (builtin.os.tag) {
        .linux => std.posix.getenv("DBUS_STARTER_ADDRESS") != null and
            std.posix.getenv("DBUS_STARTER_BUS_TYPE") != null,
        else => false,
    };
}
