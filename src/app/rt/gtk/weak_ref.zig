const std = @import("std");
const gtk = @import("gtk");
const gobject = @import("gobject");
pub fn WeakRef(comptime T: type) type {
    return struct {
        const Self = @This();
        ref: gobject.WeakRef = std.mem.zeroes(gobject.WeakRef),
        pub const empty: Self = .{};
        pub fn set(self: *Self, v_: ?*T) void {
            if (v_) |v| {
                self.ref.set(v.as(gobject.Object));
            } else {
                self.ref.set(null);
            }
        }
        pub fn deinit(self: *Self) void {
            self.ref.clear();
        }
        pub fn get(self: *Self) ?*T {
            return gobject.ext.cast(T, self.ref.get() orelse return null);
        }
    };
}
test WeakRef {
    const testing = std.testing;
    var ref: WeakRef(gtk.TextBuffer) = .empty;
    const obj: *gtk.TextBuffer = .new(null);
    ref.set(obj);
    ref.get().?.unref(); 
    obj.unref();
    try testing.expect(ref.get() == null);
}
