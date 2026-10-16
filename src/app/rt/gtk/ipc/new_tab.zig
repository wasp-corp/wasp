const std = @import("std");
const Allocator = std.mem.Allocator;
const glib = @import("glib");
const apprt = @import("../../../apprt.zig");
const DBus = @import("DBus.zig");
pub fn newTab(alloc: Allocator, target: apprt.ipc.Target, value: apprt.ipc.Action.NewTab) (Allocator.Error || std.Io.Writer.Error || apprt.ipc.Errors)!bool {
    var dbus = try DBus.init(alloc, target, "new-tab");
    defer dbus.deinit(alloc);
    const tas_variant_type = glib.VariantType.new("(tas)");
    defer tas_variant_type.free();
    var parameter: glib.VariantBuilder = undefined;
    parameter.init(tas_variant_type);
    errdefer parameter.clear();
    {
        const t = glib.Variant.newUint64(value.surface_id);
        parameter.addValue(t);
    }
    {
        const as_variant_type = glib.VariantType.new("as");
        defer as_variant_type.free();
        const s_variant_type = glib.VariantType.new("s");
        defer s_variant_type.free();
        var command: glib.VariantBuilder = undefined;
        command.init(as_variant_type);
        errdefer command.clear();
        if (value.arguments) |arguments| {
            for (arguments) |argument| {
                const bytes = glib.Bytes.new(argument.ptr, argument.len + 1);
                defer bytes.unref();
                const string = glib.Variant.newFromBytes(s_variant_type, bytes, @intFromBool(true));
                command.addValue(string);
            }
        }
        parameter.addValue(command.end());
    }
    dbus.addParameter(parameter.end());
    try dbus.send();
    return true;
}
