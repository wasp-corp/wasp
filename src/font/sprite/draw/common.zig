const std = @import("std");
const Allocator = std.mem.Allocator;
const font = @import("../../main.zig");
const log = std.log.scoped(.sprite_font);
pub const one_eighth: f64 = 0.125;
pub const one_quarter: f64 = 0.25;
pub const one_third: f64 = (1.0 / 3.0);
pub const three_eighths: f64 = 0.375;
pub const half: f64 = 0.5;
pub const five_eighths: f64 = 0.625;
pub const two_thirds: f64 = (2.0 / 3.0);
pub const three_quarters: f64 = 0.75;
pub const seven_eighths: f64 = 0.875;
pub const Thickness = enum {
    super_light,
    light,
    heavy,
    pub fn height(self: Thickness, base: u32) u32 {
        return switch (self) {
            .super_light => @max(base / 2, 1),
            .light => base,
            .heavy => base * 2,
        };
    }
};
pub const Shade = enum(u8) {
    off = 0x00,
    light = 0x40,
    medium = 0x80,
    dark = 0xc0,
    on = 0xff,
    _,
};
pub const Quads = packed struct(u4) {
    tl: bool = false,
    tr: bool = false,
    bl: bool = false,
    br: bool = false,
};
pub const Corner = enum(u2) {
    tl,
    tr,
    bl,
    br,
};
pub const Edge = enum(u2) {
    top,
    left,
    bottom,
    right,
};
pub const Alignment = struct {
    horizontal: enum {
        left,
        right,
        center,
    } = .center,
    vertical: enum {
        top,
        bottom,
        middle,
    } = .middle,
    pub const upper: Alignment = .{ .vertical = .top };
    pub const lower: Alignment = .{ .vertical = .bottom };
    pub const left: Alignment = .{ .horizontal = .left };
    pub const right: Alignment = .{ .horizontal = .right };
    pub const upper_left: Alignment = .{ .vertical = .top, .horizontal = .left };
    pub const upper_right: Alignment = .{ .vertical = .top, .horizontal = .right };
    pub const lower_left: Alignment = .{ .vertical = .bottom, .horizontal = .left };
    pub const lower_right: Alignment = .{ .vertical = .bottom, .horizontal = .right };
    pub const center: Alignment = .{};
    pub const upper_center = upper;
    pub const lower_center = lower;
    pub const middle_left = left;
    pub const middle_right = right;
    pub const middle_center: Alignment = center;
    pub const top = upper;
    pub const bottom = lower;
    pub const center_top = top;
    pub const center_bottom = bottom;
    pub const top_left = upper_left;
    pub const top_right = upper_right;
    pub const bottom_left = lower_left;
    pub const bottom_right = lower_right;
};
pub const Fraction = enum {
    start,
    left,
    top,
    zero,
    eighth,
    one_eighth,
    two_eighths,
    three_eighths,
    four_eighths,
    five_eighths,
    six_eighths,
    seven_eighths,
    quarter,
    one_quarter,
    two_quarters,
    three_quarters,
    third,
    one_third,
    two_thirds,
    half,
    one_half,
    center,
    middle,
    end,
    right,
    bottom,
    one,
    full,
    pub const eighths: [9]Fraction = .{
        .zero,
        .one_eighth,
        .two_eighths,
        .three_eighths,
        .four_eighths,
        .five_eighths,
        .six_eighths,
        .seven_eighths,
        .one,
    };
    pub const quarters: [5]Fraction = .{
        .zero,
        .one_quarter,
        .two_quarters,
        .three_quarters,
        .one,
    };
    pub const thirds: [4]Fraction = .{
        .zero,
        .one_third,
        .two_thirds,
        .one,
    };
    pub const halves: [3]Fraction = .{
        .zero,
        .one_half,
        .one,
    };
    pub inline fn min(self: Fraction, size: anytype) i32 {
        const s: f64 = @as(f64, @floatFromInt(size));
        return @intFromFloat(s - @round((1.0 - self.fraction()) * s));
    }
    pub inline fn max(self: Fraction, size: anytype) i32 {
        const s: f64 = @as(f64, @floatFromInt(size));
        return @intFromFloat(@round(self.fraction() * s));
    }
    pub inline fn float(self: Fraction, size: anytype) f64 {
        return self.fraction() * @as(f64, @floatFromInt(size));
    }
    pub inline fn fraction(self: Fraction) f64 {
        return switch (self) {
            .start,
            .left,
            .top,
            .zero,
            => 0.0,
            .eighth,
            .one_eighth,
            => 0.125,
            .quarter,
            .one_quarter,
            .two_eighths,
            => 0.25,
            .third,
            .one_third,
            => 1.0 / 3.0,
            .three_eighths,
            => 0.375,
            .half,
            .one_half,
            .two_quarters,
            .four_eighths,
            .center,
            .middle,
            => 0.5,
            .five_eighths,
            => 0.625,
            .two_thirds,
            => 2.0 / 3.0,
            .three_quarters,
            .six_eighths,
            => 0.75,
            .seven_eighths,
            => 0.875,
            .end,
            .right,
            .bottom,
            .one,
            .full,
            => 1.0,
        };
    }
};
pub fn fill(
    metrics: font.Metrics,
    canvas: *font.sprite.Canvas,
    x0: Fraction,
    x1: Fraction,
    y0: Fraction,
    y1: Fraction,
) void {
    canvas.box(
        x0.min(metrics.cell_width),
        y0.min(metrics.cell_height),
        x1.max(metrics.cell_width),
        y1.max(metrics.cell_height),
        .on,
    );
}
pub fn vlineMiddle(
    metrics: font.Metrics,
    canvas: *font.sprite.Canvas,
    thickness: Thickness,
) void {
    const thick_px = thickness.height(metrics.box_thickness);
    vline(
        canvas,
        0,
        @intCast(metrics.cell_height),
        @intCast((metrics.cell_width -| thick_px) / 2),
        thick_px,
    );
}
pub fn hlineMiddle(
    metrics: font.Metrics,
    canvas: *font.sprite.Canvas,
    thickness: Thickness,
) void {
    const thick_px = thickness.height(metrics.box_thickness);
    hline(
        canvas,
        0,
        @intCast(metrics.cell_width),
        @intCast((metrics.cell_height -| thick_px) / 2),
        thick_px,
    );
}
pub fn vline(
    canvas: *font.sprite.Canvas,
    y1: i32,
    y2: i32,
    x: i32,
    thickness_px: u32,
) void {
    canvas.box(x, y1, x + @as(i32, @intCast(thickness_px)), y2, .on);
}
pub fn hline(
    canvas: *font.sprite.Canvas,
    x1: i32,
    x2: i32,
    y: i32,
    thickness_px: u32,
) void {
    canvas.box(x1, y, x2, y + @as(i32, @intCast(thickness_px)), .on);
}
