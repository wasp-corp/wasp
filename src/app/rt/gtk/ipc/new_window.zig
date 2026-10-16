const std = @import("std");
const Allocator = std.mem.Allocator;
const glib = @import("glib");
const apprt = @import("../../../apprt.zig");
const DBus = @import("DBus.zig");
pub fn newWindow(alloc: Allocator, target: apprt.ipc.Target, value: apprt.ipc.Action.NewWindow) (Allocator.Error || std.Io.Writer.Error || apprt.ipc.Errors)!bool {
    var dbus = try DBus.init(
        alloc,
        target,
        if (value.arguments == null)
            "new-window"
        else
            "new-window-command",
    );
    defer dbus.deinit(alloc);
    if (value.arguments) |arguments| {
        const as_variant_type = glib.VariantType.new("as");
        defer as_variant_type.free();
        const s_variant_type = glib.VariantType.new("s");
        defer s_variant_type.free();
        var command: glib.VariantBuilder = undefined;
        command.init(as_variant_type);
        errdefer command.clear();
        for (arguments) |argument| {
            const bytes = glib.Bytes.new(argument.ptr, argument.len + 1);
            defer bytes.unref();
            const string = glib.Variant.newFromBytes(s_variant_type, bytes, @intFromBool(true));
            command.addValue(string);
        }
        dbus.addParameter(command.end());
    }
    try dbus.send();
    return true;
}
