const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../../apprt.zig");
const DBus = @import("DBus.zig");
pub fn toggleQuickTerminal(alloc: Allocator, target: apprt.ipc.Target) (Allocator.Error || std.Io.Writer.Error || apprt.ipc.Errors)!bool {
    var dbus = try DBus.init(alloc, target, "toggle-quick-terminal");
    defer dbus.deinit(alloc);
    try dbus.send();
    return true;
}
