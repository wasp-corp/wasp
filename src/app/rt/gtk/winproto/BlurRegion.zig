const BlurRegion = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const gobject = @import("gobject");
const gdk = @import("gdk");
const gtk = @import("gtk");
const Window = @import("../winproto.zig").Window;
const ApprtWindow = @import("../class/window.zig").Window;
slices: std.ArrayList(Slice),
pub const Slice = extern struct {
    x: Pos,
    y: Pos,
    width: Pos,
    height: Pos,
};
const Pos = c_long;
pub const empty: BlurRegion = .{
    .slices = .empty,
};
pub fn deinit(self: *BlurRegion, alloc: Allocator) void {
    self.slices.deinit(alloc);
    self.slices = .empty;
}
pub fn calcForWindow(
    alloc: Allocator,
    window: *ApprtWindow,
    csd: bool,
    to_device_coordinates: bool,
) Allocator.Error!BlurRegion {
    const native = window.as(gtk.Native);
    const surface = native.getSurface() orelse return .empty;
    var slices: std.ArrayList(Slice) = .empty;
    errdefer slices.deinit(alloc);
    const x: Pos, const y: Pos = off: {
        var x: f64 = 0;
        var y: f64 = 0;
        native.getSurfaceTransform(&x, &y);
        if (csd) {
            x += 1;
            y += 1;
        }
        break :off .{ @intFromFloat(x), @intFromFloat(y) };
    };
    var width = @as(Pos, surface.getWidth());
    var height = @as(Pos, surface.getHeight());
    width -= x * 2;
    height -= y * 2;
    if (width <= 0 or height <= 0) return .empty;
    const are_corners_rounded = rounded: {
        const toplevel = gobject.ext.cast(
            gdk.Toplevel,
            surface,
        ) orelse break :rounded false;
        const state = toplevel.getState();
        if (state.fullscreen or state.maximized or state.tiled)
            break :rounded false;
        break :rounded csd;
    };
    const new_slices = try approxRoundedRect(
        alloc,
        x,
        y,
        width,
        height,
        if (are_corners_rounded) 15 else 0,
    );
    if (to_device_coordinates) {
        const sf = surface.getScaleFactor();
        for (new_slices.items) |*s| {
            s.x *= sf;
            s.y *= sf;
            s.width *= sf;
            s.height *= sf;
        }
    }
    return .{ .slices = new_slices };
}
pub fn eql(self: BlurRegion, other: BlurRegion) bool {
    if (self.slices.items.len != other.slices.items.len) return false;
    for (self.slices.items, other.slices.items) |this, that| {
        if (!std.meta.eql(this, that)) return false;
    }
    return true;
}
fn approxRoundedRect(
    alloc: Allocator,
    x: Pos,
    y: Pos,
    width: Pos,
    height: Pos,
    radius: Pos,
) Allocator.Error!std.ArrayList(Slice) {
    const r_f: f32 = @floatFromInt(radius);
    var slices: std.ArrayList(Slice) = .empty;
    errdefer slices.deinit(alloc);
    try slices.append(alloc, .{
        .x = x,
        .y = y + radius,
        .width = width,
        .height = height - 2 * radius,
    });
    var row: Pos = 0;
    while (row < radius) : (row += 1) {
        const dy = @as(f32, @floatFromInt(radius - row)) - 0.5;
        const dx = @sqrt(r_f * r_f - dy * dy);
        const row_x: Pos = @intFromFloat(r_f - @round(dx + 0.5));
        const row_w = width - 2 * row_x;
        try slices.append(alloc, .{
            .x = x + row_x,
            .y = y + row,
            .width = row_w,
            .height = 1,
        });
        try slices.append(alloc, .{
            .x = x + row_x,
            .y = y + height - 1 - row,
            .width = row_w,
            .height = 1,
        });
    }
    return slices;
}
