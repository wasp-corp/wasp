const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const lib = @import("../lib.zig");
const style = @import("../style.zig");
const color = @import("../color.zig");
const sgr = @import("../sgr.zig");
pub const ColorTag = enum(c_int) {
    none = 0,
    palette = 1,
    rgb = 2,
};
pub const ColorValue = extern union {
    palette: u8,
    rgb: color.RGB.C,
    _padding: u64,
};
pub const Color = extern struct {
    tag: ColorTag,
    value: ColorValue,
    comptime {
        const Tag = std.meta.Tag(style.Style.Color);
        for (@typeInfo(Tag).@"enum".fields) |f| {
            assert(f.value == @intFromEnum(@field(ColorTag, f.name)));
        }
    }
    pub fn fromColor(c: style.Style.Color) Color {
        const value: u64 = switch (c) {
            .none => 0,
            .palette => |idx| idx,
            .rgb => |rgb| @as(u24, @bitCast(rgb)),
        };
        return .{
            .tag = @enumFromInt(@intFromEnum(std.meta.activeTag(c))),
            .value = .{ ._padding = value },
        };
    }
};
pub const Style = extern struct {
    size: usize = @sizeOf(Style),
    fg_color: Color,
    bg_color: Color,
    underline_color: Color,
    bold: bool,
    italic: bool,
    faint: bool,
    blink: bool,
    inverse: bool,
    invisible: bool,
    strikethrough: bool,
    overline: bool,
    underline: c_int,
    pub const default: Style = .{
        .fg_color = .{ .tag = .none, .value = .{ ._padding = 0 } },
        .bg_color = .{ .tag = .none, .value = .{ ._padding = 0 } },
        .underline_color = .{ .tag = .none, .value = .{ ._padding = 0 } },
        .bold = false,
        .italic = false,
        .faint = false,
        .blink = false,
        .inverse = false,
        .invisible = false,
        .strikethrough = false,
        .overline = false,
        .underline = 0,
    };
    comptime {
        const flag_names = [8][:0]const u8{
            "bold",    "italic",    "faint",         "blink",
            "inverse", "invisible", "strikethrough", "overline",
        };
        const base = @offsetOf(Style, "bold");
        for (flag_names, 0..) |name, i| {
            assert(@offsetOf(Style, name) == base + i);
            assert(@bitOffsetOf(@FieldType(style.Style, "flags"), name) == i);
        }
    }
    pub fn write(s: style.Style, out: *Style) void {
        out.size = @sizeOf(Style);
        out.fg_color = .fromColor(s.fg_color);
        out.bg_color = .fromColor(s.bg_color);
        out.underline_color = .fromColor(s.underline_color);
        @as(*align(1) u64, @ptrCast(&out.bold)).* = bytes: {
            const flag_bits: u8 = @truncate(@as(u16, @bitCast(s.flags)));
            const masks: @Vector(8, u8) = .{ 1, 2, 4, 8, 16, 32, 64, 128 };
            const hits = (@as(@Vector(8, u8), @splat(flag_bits)) & masks) == masks;
            const bytes: @Vector(8, u8) = @select(
                u8,
                hits,
                @as(@Vector(8, u8), @splat(1)),
                @as(@Vector(8, u8), @splat(0)),
            );
            break :bytes @bitCast(bytes);
        };
        out.underline = @intFromEnum(s.flags.underline);
    }
    pub fn fromStyle(s: style.Style) Style {
        var result: Style = undefined;
        write(s, &result);
        return result;
    }
};
pub fn default_style(result: *Style) callconv(lib.calling_conv) void {
    result.* = .default;
    assert(result.size == @sizeOf(Style));
}
pub fn style_is_default(s: *const Style) callconv(lib.calling_conv) bool {
    assert(s.size == @sizeOf(Style));
    return s.fg_color.tag == .none and
        s.bg_color.tag == .none and
        s.underline_color.tag == .none and
        s.bold == false and
        s.italic == false and
        s.faint == false and
        s.blink == false and
        s.inverse == false and
        s.invisible == false and
        s.strikethrough == false and
        s.overline == false and
        s.underline == 0;
}
test "default style" {
    var s: Style = undefined;
    default_style(&s);
    try testing.expect(style_is_default(&s));
    try testing.expectEqual(ColorTag.none, s.fg_color.tag);
    try testing.expectEqual(ColorTag.none, s.bg_color.tag);
    try testing.expectEqual(ColorTag.none, s.underline_color.tag);
    try testing.expect(!s.bold);
    try testing.expect(!s.italic);
    try testing.expectEqual(@as(c_int, 0), s.underline);
}
test "convert style with colors" {
    const zig_style: style.Style = .{
        .fg_color = .{ .palette = 42 },
        .bg_color = .{ .rgb = .{ .r = 255, .g = 128, .b = 64 } },
        .underline_color = .none,
        .flags = .{ .bold = true, .underline = .curly },
    };
    const c_style: Style = .fromStyle(zig_style);
    try testing.expectEqual(ColorTag.palette, c_style.fg_color.tag);
    try testing.expectEqual(@as(u8, 42), c_style.fg_color.value.palette);
    try testing.expectEqual(ColorTag.rgb, c_style.bg_color.tag);
    try testing.expectEqual(@as(u8, 255), c_style.bg_color.value.rgb.r);
    try testing.expectEqual(@as(u8, 128), c_style.bg_color.value.rgb.g);
    try testing.expectEqual(@as(u8, 64), c_style.bg_color.value.rgb.b);
    try testing.expectEqual(ColorTag.none, c_style.underline_color.tag);
    try testing.expect(c_style.bold);
    try testing.expectEqual(@as(c_int, 3), c_style.underline);
    try testing.expect(!style_is_default(&c_style));
}
