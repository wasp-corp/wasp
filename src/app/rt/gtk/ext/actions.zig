const std = @import("std");
const assert = @import("../../../quirks.zig").inlineAssert;
const testing = std.testing;
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const gValueHolds = @import("../ext.zig").gValueHolds;
fn gActionNameIsValid(name: [:0]const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| switch (c) {
        '-' => continue,
        '.' => continue,
        '0'...'9' => continue,
        'a'...'z' => continue,
        'A'...'Z' => continue,
        else => return false,
    };
    return true;
}
test "gActionNameIsValid" {
    try testing.expect(gActionNameIsValid("ring-bell"));
    try testing.expect(!gActionNameIsValid("ring_bell"));
}
pub fn Action(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Callback = *const fn (*gio.SimpleAction, ?*glib.Variant, *T) callconv(.c) void;
        name: [:0]const u8,
        callback: Callback,
        parameter_type: ?*const glib.VariantType,
        state: ?*glib.Variant = null,
        pub fn init(
            comptime name: [:0]const u8,
            callback: Callback,
            parameter_type: ?*const glib.VariantType,
        ) Self {
            comptime assert(gActionNameIsValid(name));
            return .{
                .name = name,
                .callback = callback,
                .parameter_type = parameter_type,
            };
        }
        pub fn initStateful(
            comptime name: [:0]const u8,
            callback: Callback,
            parameter_type: ?*const glib.VariantType,
            state: *glib.Variant,
        ) Self {
            comptime assert(gActionNameIsValid(name));
            return .{
                .name = name,
                .callback = callback,
                .parameter_type = parameter_type,
                .state = state,
            };
        }
    };
}
pub fn add(comptime T: type, self: *T, actions: []const Action(T)) void {
    addToMap(T, self, self.as(gio.ActionMap), actions);
}
pub fn addToMap(comptime T: type, self: *T, map: *gio.ActionMap, actions: []const Action(T)) void {
    for (actions) |entry| {
        assert(gActionNameIsValid(entry.name));
        const action = action: {
            if (entry.state) |state| {
                break :action gio.SimpleAction.newStateful(
                    entry.name,
                    entry.parameter_type,
                    state,
                );
            }
            break :action gio.SimpleAction.new(
                entry.name,
                entry.parameter_type,
            );
        };
        defer action.unref();
        _ = gio.SimpleAction.signals.activate.connect(
            action,
            *T,
            entry.callback,
            self,
            .{},
        );
        map.addAction(action.as(gio.Action));
    }
}
pub fn addAsGroup(comptime T: type, self: *T, comptime name: [:0]const u8, actions: []const Action(T)) *gio.SimpleActionGroup {
    comptime assert(gActionNameIsValid(name));
    const group = gio.SimpleActionGroup.new();
    errdefer group.unref();
    addToMap(T, self, group.as(gio.ActionMap), actions);
    self.as(gtk.Widget).insertActionGroup(
        name,
        group.as(gio.ActionGroup),
    );
    return group;
}
test "adding actions to an object" {
    if (gtk.initCheck() == 0) return error.SkipZigTest;
    _ = glib.MainContext.acquire(null);
    defer glib.MainContext.release(null);
    const callbacks = struct {
        fn callback(_: *gio.SimpleAction, variant_: ?*glib.Variant, self: *gtk.Box) callconv(.c) void {
            const i32_variant_type = glib.ext.VariantType.newFor(i32);
            defer i32_variant_type.free();
            const variant = variant_ orelse return;
            assert(variant.isOfType(i32_variant_type) != 0);
            var value = std.mem.zeroes(gobject.Value);
            _ = value.init(gobject.ext.types.int);
            defer value.unset();
            value.setInt(variant.getInt32());
            self.as(gobject.Object).setProperty("spacing", &value);
        }
    };
    const box = gtk.Box.new(.vertical, 0);
    _ = box.as(gobject.Object).refSink();
    defer box.unref();
    {
        const i32_variant_type = glib.ext.VariantType.newFor(i32);
        defer i32_variant_type.free();
        const actions = [_]Action(gtk.Box){
            .init("test", callbacks.callback, i32_variant_type),
        };
        _ = addAsGroup(gtk.Box, box, "test", &actions);
    }
    const expected = expected: {
        const rng_impl: std.Random.IoSource = .{ .io = testing.io };
        const rng = rng_impl.interface();
        break :expected rng.intRangeAtMost(i32, 1, std.math.maxInt(u31));
    };
    const parameter = glib.Variant.newInt32(expected);
    try testing.expect(box.as(gtk.Widget).activateActionVariant("test.test", parameter) != 0);
    _ = glib.MainContext.iteration(null, @intFromBool(true));
    var value = std.mem.zeroes(gobject.Value);
    _ = value.init(gobject.ext.types.int);
    defer value.unset();
    box.as(gobject.Object).getProperty("spacing", &value);
    try testing.expect(gValueHolds(&value, gobject.ext.types.int));
    const actual = value.getInt();
    try testing.expectEqual(expected, actual);
    while (glib.MainContext.iteration(null, 0) != 0) {}
}
