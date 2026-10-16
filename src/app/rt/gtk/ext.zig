const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const testing = std.testing;
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
pub const actions = @import("ext/actions.zig");
const slice = @import("ext/slice.zig");
pub const StringList = slice.StringList;
pub fn boxedCopy(comptime T: type, ptr: *const T) *T {
    const copy = gobject.boxedCopy(T.getGObjectType(), ptr);
    return @ptrCast(@alignCast(copy));
}
pub fn boxedFree(comptime T: type, ptr: ?*T) void {
    if (ptr) |p| gobject.boxedFree(
        T.getGObjectType(),
        p,
    );
}
pub fn listFind(
    comptime T: type,
    list: *glib.List,
    comptime func: *const fn (*T) bool,
) ?*T {
    const elem_: ?*glib.List = list.findCustom(null, struct {
        fn callback(data: ?*const anyopaque, _: ?*const anyopaque) callconv(.c) c_int {
            const ptr = data orelse return 1;
            const v: *T = @ptrCast(@alignCast(@constCast(ptr)));
            return if (func(v)) 0 else 1;
        }
    }.callback);
    const elem = elem_ orelse return null;
    return @ptrCast(@alignCast(elem.f_data));
}
pub fn getAncestor(comptime T: type, widget: *gtk.Widget) ?*T {
    const ancestor_ = widget.getAncestor(gobject.ext.typeFor(T));
    const ancestor = ancestor_ orelse return null;
    return gobject.ext.cast(T, ancestor).?;
}
pub fn gValueHolds(value_: ?*const gobject.Value, g_type: gobject.Type) bool {
    const value = value_ orelse return false;
    if (value.f_g_type == g_type) return true;
    return gobject.typeCheckValueHolds(value, g_type) != 0;
}
test {
    _ = actions;
    _ = slice;
}
