const colorpkg = @This();
const std = @import("std");
const lib = @import("lib.zig");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const fraction = @import("fraction.zig");
const x11_color = @import("x11_color.zig");
pub const default: Palette = default: {
    var result: Palette = undefined;
    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        result[i] = Name.default(@enumFromInt(i)) catch unreachable;
    }
    assert(i == 16);
    var r: u8 = 0;
    while (r < 6) : (r += 1) {
        var g: u8 = 0;
        while (g < 6) : (g += 1) {
            var b: u8 = 0;
            while (b < 6) : (b += 1) {
                result[i] = .{
                    .r = if (r == 0) 0 else (r * 40 + 55),
                    .g = if (g == 0) 0 else (g * 40 + 55),
                    .b = if (b == 0) 0 else (b * 40 + 55),
                };
                i += 1;
            }
        }
    }
    assert(i == 232);
    assert(@TypeOf(i) == u8);
    while (i > 0) : (i +%= 1) {
        const value = ((i - 232) * 10) + 8;
        result[i] = .{ .r = value, .g = value, .b = value };
    }
    break :default result;
};
pub const Palette = [256]RGB;
pub const PaletteEntry = struct {
    index: u8,
    color: RGB,
};
pub fn parsePaletteEntry(value: []const u8) error{ InvalidFormat, Overflow }!PaletteEntry {
    const eql_idx = std.mem.indexOfScalar(u8, value, '=') orelse
        return error.InvalidFormat;
    const index = std.fmt.parseInt(
        u8,
        std.mem.trim(u8, value[0..eql_idx], " \t"),
        0,
    ) catch |err| switch (err) {
        error.Overflow => return error.Overflow,
        error.InvalidCharacter => return error.InvalidFormat,
    };
    const rgb = try RGB.parse(value[eql_idx + 1 ..]);
    return .{ .index = index, .color = rgb };
}
test "parsePaletteEntry" {
    const testing = std.testing;
    {
        const entry = try parsePaletteEntry("0=#AABBCC");
        try testing.expectEqual(@as(u8, 0), entry.index);
        try testing.expectEqual(RGB{ .r = 170, .g = 187, .b = 204 }, entry.color);
    }
    {
        const entry = try parsePaletteEntry("0b1=#014589");
        try testing.expectEqual(@as(u8, 1), entry.index);
        try testing.expectEqual(RGB{ .r = 1, .g = 69, .b = 137 }, entry.color);
    }
    {
        const entry = try parsePaletteEntry("0o7=#234567");
        try testing.expectEqual(@as(u8, 7), entry.index);
        try testing.expectEqual(RGB{ .r = 35, .g = 69, .b = 103 }, entry.color);
    }
    {
        const entry = try parsePaletteEntry("0xF=#ABCDEF");
        try testing.expectEqual(@as(u8, 15), entry.index);
        try testing.expectEqual(RGB{ .r = 171, .g = 205, .b = 239 }, entry.color);
    }
    {
        const entry = try parsePaletteEntry("0 =  #AABBCC");
        try testing.expectEqual(@as(u8, 0), entry.index);
        try testing.expectEqual(RGB{ .r = 170, .g = 187, .b = 204 }, entry.color);
    }
    {
        const entry = try parsePaletteEntry(" 1= #DDEEFF    ");
        try testing.expectEqual(@as(u8, 1), entry.index);
        try testing.expectEqual(RGB{ .r = 221, .g = 238, .b = 255 }, entry.color);
    }
    {
        const entry = try parsePaletteEntry("  2  =  #123456 ");
        try testing.expectEqual(@as(u8, 2), entry.index);
        try testing.expectEqual(RGB{ .r = 18, .g = 52, .b = 86 }, entry.color);
    }
    {
        const entry = try parsePaletteEntry("1=black");
        try testing.expectEqual(@as(u8, 1), entry.index);
        try testing.expectEqual(RGB{ .r = 0, .g = 0, .b = 0 }, entry.color);
    }
    try testing.expectError(error.InvalidFormat, parsePaletteEntry(" "));
    try testing.expectError(error.InvalidFormat, parsePaletteEntry("a"));
    try testing.expectError(error.Overflow, parsePaletteEntry("256=#AABBCC"));
    try testing.expectError(error.InvalidFormat, parsePaletteEntry("1=notacolor"));
}
pub const PaletteC = [256]RGB.C;
pub fn paletteCval(palette: *const Palette) PaletteC {
    var result: PaletteC = undefined;
    paletteCvalSlice(palette[0..], result[0..]);
    return result;
}
pub fn paletteCvalSlice(src: []const RGB, dst: []RGB.C) void {
    assert(src.len == dst.len);
    var i: usize = 0;
    if (comptime builtin.cpu.arch.endian() == .little) {
        const V = @Vector(16, u8);
        const dst_bytes: [*]u8 = @ptrCast(dst.ptr);
        while (i + 6 <= src.len) : (i += 4) {
            const in: V = @as(*align(4) const V, @ptrCast(src[i..][0..4])).*;
            const out: V = @shuffle(u8, in, undefined, [16]i32{
                0,  1,  2,
                4,  5,  6,
                8,  9,  10,
                12, 13, 14,
                3,  7,  11,
                15,
            });
            @as(*align(1) V, @ptrCast(dst_bytes[i * 3 ..][0..16])).* = out;
        }
    }
    for (src[i..], dst[i..]) |entry, *out| out.* = entry.cval();
}
pub fn paletteZval(palette: *const PaletteC) Palette {
    var result: Palette = undefined;
    for (&result, palette) |*dst, src| dst.* = .fromC(src);
    return result;
}
pub const PaletteMask = std.StaticBitSet(@typeInfo(Palette).array.len);
pub fn generate256Color(
    base: Palette,
    skip: PaletteMask,
    bg: RGB,
    fg: RGB,
    harmonious: bool,
) Palette {
    const base8_lab: [8]LAB = base8: {
        var base8: [8]LAB = .{
            .fromRgb(bg),
            LAB.fromRgb(base[1]),
            LAB.fromRgb(base[2]),
            LAB.fromRgb(base[3]),
            LAB.fromRgb(base[4]),
            LAB.fromRgb(base[5]),
            LAB.fromRgb(base[6]),
            .fromRgb(fg),
        };
        const is_light_theme = base8[7].l < base8[0].l;
        const invert = is_light_theme and !harmonious;
        if (invert) std.mem.swap(LAB, &base8[0], &base8[7]);
        break :base8 base8;
    };
    var result = base;
    var idx: usize = 16;
    for (0..6) |ri| {
        const tr = @as(f32, @floatFromInt(ri)) / 5.0;
        const c0: LAB = .lerp(tr, base8_lab[0], base8_lab[1]);
        const c1: LAB = .lerp(tr, base8_lab[2], base8_lab[3]);
        const c2: LAB = .lerp(tr, base8_lab[4], base8_lab[5]);
        const c3: LAB = .lerp(tr, base8_lab[6], base8_lab[7]);
        for (0..6) |gi| {
            const tg = @as(f32, @floatFromInt(gi)) / 5.0;
            const c4: LAB = .lerp(tg, c0, c1);
            const c5: LAB = .lerp(tg, c2, c3);
            for (0..6) |bi| {
                if (!skip.isSet(idx)) {
                    const c6: LAB = .lerp(
                        @as(f32, @floatFromInt(bi)) / 5.0,
                        c4,
                        c5,
                    );
                    result[idx] = c6.toRgb();
                }
                idx += 1;
            }
        }
    }
    for (0..24) |i| {
        const t = @as(f32, @floatFromInt(i + 1)) / 25.0;
        if (!skip.isSet(idx)) {
            const c: LAB = .lerp(t, base8_lab[0], base8_lab[7]);
            result[idx] = c.toRgb();
        }
        idx += 1;
    }
    return result;
}
pub const DynamicPalette = struct {
    current: Palette,
    original: *const Palette,
    mask: PaletteMask,
    pub const default: DynamicPalette = .{
        .current = colorpkg.default,
        .original = &colorpkg.default,
        .mask = .initEmpty(),
    };
    pub fn init(alloc: Allocator, def: Palette) Allocator.Error!DynamicPalette {
        var result: DynamicPalette = .default;
        try result.changeDefault(alloc, def);
        return result;
    }
    pub fn deinit(self: *DynamicPalette, alloc: Allocator) void {
        if (self.ownedOriginal()) |owned| alloc.destroy(owned);
        self.* = undefined;
    }
    pub fn set(self: *DynamicPalette, idx: u8, color: RGB) void {
        self.current[idx] = color;
        self.mask.set(idx);
    }
    pub fn reset(self: *DynamicPalette, idx: u8) void {
        self.current[idx] = self.original[idx];
        self.mask.unset(idx);
    }
    pub fn resetAll(self: *DynamicPalette) void {
        self.current = self.original.*;
        self.mask = .initEmpty();
    }
    pub fn changeDefault(
        self: *DynamicPalette,
        alloc: Allocator,
        def: Palette,
    ) Allocator.Error!void {
        if (std.meta.eql(def, colorpkg.default)) return self.resetDefault(alloc);
        const owned = self.ownedOriginal() orelse try alloc.create(Palette);
        owned.* = def;
        self.original = owned;
        self.applyDefault(def);
    }
    pub fn resetDefault(self: *DynamicPalette, alloc: Allocator) void {
        if (self.ownedOriginal()) |owned| alloc.destroy(owned);
        self.original = &colorpkg.default;
        self.applyDefault(colorpkg.default);
    }
    fn applyDefault(self: *DynamicPalette, def: Palette) void {
        if (self.mask.count() == 0) {
            self.current = def;
            return;
        }
        var current = def;
        var it = self.mask.iterator(.{});
        while (it.next()) |idx| current[idx] = self.current[idx];
        self.current = current;
    }
    fn ownedOriginal(self: *const DynamicPalette) ?*Palette {
        if (self.original == &colorpkg.default) return null;
        return @constCast(self.original);
    }
};
pub const DynamicRGB = struct {
    override: ?RGB,
    default: ?RGB,
    pub const unset: DynamicRGB = .{ .override = null, .default = null };
    pub fn init(def: RGB) DynamicRGB {
        return .{
            .override = null,
            .default = def,
        };
    }
    pub fn get(self: *const DynamicRGB) ?RGB {
        return self.override orelse self.default;
    }
    pub fn set(self: *DynamicRGB, color: RGB) void {
        self.override = color;
    }
    pub fn reset(self: *DynamicRGB) void {
        self.override = null;
    }
};
pub const Name = enum(u8) {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,
    bright_black = 8,
    bright_red = 9,
    bright_green = 10,
    bright_yellow = 11,
    bright_blue = 12,
    bright_magenta = 13,
    bright_cyan = 14,
    bright_white = 15,
    _,
    pub const C = u8;
    pub fn cval(self: Name) C {
        return @intFromEnum(self);
    }
    pub fn default(self: Name) error{NoDefaultValue}!RGB {
        return switch (self) {
            .black => RGB{ .r = 0x1D, .g = 0x1F, .b = 0x21 },
            .red => RGB{ .r = 0xCC, .g = 0x66, .b = 0x66 },
            .green => RGB{ .r = 0xB5, .g = 0xBD, .b = 0x68 },
            .yellow => RGB{ .r = 0xF0, .g = 0xC6, .b = 0x74 },
            .blue => RGB{ .r = 0x81, .g = 0xA2, .b = 0xBE },
            .magenta => RGB{ .r = 0xB2, .g = 0x94, .b = 0xBB },
            .cyan => RGB{ .r = 0x8A, .g = 0xBE, .b = 0xB7 },
            .white => RGB{ .r = 0xC5, .g = 0xC8, .b = 0xC6 },
            .bright_black => RGB{ .r = 0x66, .g = 0x66, .b = 0x66 },
            .bright_red => RGB{ .r = 0xD5, .g = 0x4E, .b = 0x53 },
            .bright_green => RGB{ .r = 0xB9, .g = 0xCA, .b = 0x4A },
            .bright_yellow => RGB{ .r = 0xE7, .g = 0xC5, .b = 0x47 },
            .bright_blue => RGB{ .r = 0x7A, .g = 0xA6, .b = 0xDA },
            .bright_magenta => RGB{ .r = 0xC3, .g = 0x97, .b = 0xD8 },
            .bright_cyan => RGB{ .r = 0x70, .g = 0xC0, .b = 0xB1 },
            .bright_white => RGB{ .r = 0xEA, .g = 0xEA, .b = 0xEA },
            else => error.NoDefaultValue,
        };
    }
};
pub const Special = enum(u3) {
    bold = 0,
    underline = 1,
    blink = 2,
    reverse = 3,
    italic = 4,
    pub fn osc4(self: Special) u16 {
        const max = @typeInfo(Palette).array.len;
        return @as(u16, @intCast(@intFromEnum(self))) + max;
    }
    test "osc4" {
        const testing = std.testing;
        try testing.expectEqual(256, Special.bold.osc4());
        try testing.expectEqual(257, Special.underline.osc4());
        try testing.expectEqual(258, Special.blink.osc4());
        try testing.expectEqual(259, Special.reverse.osc4());
        try testing.expectEqual(260, Special.italic.osc4());
    }
};
test Special {
    _ = Special;
}
pub const Dynamic = enum(u5) {
    foreground = 10,
    background = 11,
    cursor = 12,
    pointer_foreground = 13,
    pointer_background = 14,
    tektronix_foreground = 15,
    tektronix_background = 16,
    highlight_background = 17,
    tektronix_cursor = 18,
    highlight_foreground = 19,
    pub fn next(self: Dynamic) ?Dynamic {
        return std.enums.fromInt(Dynamic, @intFromEnum(self) + 1);
    }
    test "next" {
        const testing = std.testing;
        try testing.expectEqual(.background, Dynamic.foreground.next());
        try testing.expectEqual(.cursor, Dynamic.background.next());
        try testing.expectEqual(.pointer_foreground, Dynamic.cursor.next());
        try testing.expectEqual(.pointer_background, Dynamic.pointer_foreground.next());
        try testing.expectEqual(.tektronix_foreground, Dynamic.pointer_background.next());
        try testing.expectEqual(.tektronix_background, Dynamic.tektronix_foreground.next());
        try testing.expectEqual(.highlight_background, Dynamic.tektronix_background.next());
        try testing.expectEqual(.tektronix_cursor, Dynamic.highlight_background.next());
        try testing.expectEqual(.highlight_foreground, Dynamic.tektronix_cursor.next());
        try testing.expectEqual(null, Dynamic.highlight_foreground.next());
    }
};
test Dynamic {
    _ = Dynamic;
}
pub const RGB = packed struct(u24) {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    pub const C = extern struct {
        r: u8,
        g: u8,
        b: u8,
    };
    pub fn fromC(c: C) RGB {
        return .{ .r = c.r, .g = c.g, .b = c.b };
    }
    pub fn cval(self: RGB) C {
        return .{
            .r = self.r,
            .g = self.g,
            .b = self.b,
        };
    }
    pub fn eql(self: RGB, other: RGB) bool {
        return self.r == other.r and self.g == other.g and self.b == other.b;
    }
    pub fn encodeRgb8(self: RGB, writer: *std.Io.Writer) !void {
        try writer.print(
            "rgb:{x:0>2}/{x:0>2}/{x:0>2}",
            .{ self.r, self.g, self.b },
        );
    }
    pub fn encodeRgb16(self: RGB, writer: *std.Io.Writer) !void {
        try writer.print(
            "rgb:{x:0>4}/{x:0>4}/{x:0>4}",
            .{
                @as(u16, self.r) * 257,
                @as(u16, self.g) * 257,
                @as(u16, self.b) * 257,
            },
        );
    }
    pub fn contrast(self: RGB, other: RGB) f64 {
        const pair: [2]f64 = pair: {
            const self_lum = self.luminance();
            const other_lum = other.luminance();
            if (self_lum > other_lum) break :pair .{ self_lum, other_lum };
            break :pair .{ other_lum, self_lum };
        };
        return (pair[0] + 0.05) / (pair[1] + 0.05);
    }
    pub fn luminance(self: RGB) f64 {
        const r_lum = componentLuminance(self.r);
        const g_lum = componentLuminance(self.g);
        const b_lum = componentLuminance(self.b);
        return 0.2126 * r_lum + 0.7152 * g_lum + 0.0722 * b_lum;
    }
    fn componentLuminance(c: u8) f64 {
        const c_f64: f64 = @floatFromInt(c);
        const normalized: f64 = c_f64 / 255;
        if (normalized <= 0.03928) return normalized / 12.92;
        return std.math.pow(f64, (normalized + 0.055) / 1.055, 2.4);
    }
    pub fn perceivedLuminance(self: RGB) f64 {
        const r_f64: f64 = @floatFromInt(self.r);
        const g_f64: f64 = @floatFromInt(self.g);
        const b_f64: f64 = @floatFromInt(self.b);
        return 0.299 * (r_f64 / 255) + 0.587 * (g_f64 / 255) + 0.114 * (b_f64 / 255);
    }
    comptime {
        assert(@bitSizeOf(RGB) == 24);
        assert(@sizeOf(RGB) == 4);
    }
    fn fromIntensity(value: []const u8) error{InvalidFormat}!u8 {
        const i = fraction.parse(value) orelse {
            @branchHint(.cold);
            return error.InvalidFormat;
        };
        return @intFromFloat(i * std.math.maxInt(u8));
    }
    fn fromHex(value: []const u8) error{InvalidFormat}!u8 {
        if (value.len == 0 or value.len > 4) {
            @branchHint(.cold);
            return error.InvalidFormat;
        }
        const color = lib.parseInt(u16, value, 16) catch {
            @branchHint(.cold);
            return error.InvalidFormat;
        };
        const divisor: usize = switch (value.len) {
            1 => std.math.maxInt(u4),
            2 => std.math.maxInt(u8),
            3 => std.math.maxInt(u12),
            4 => std.math.maxInt(u16),
            else => unreachable,
        };
        return @intCast(@as(usize, color) * std.math.maxInt(u8) / divisor);
    }
    pub fn parse(value: []const u8) error{InvalidFormat}!RGB {
        const input = std.mem.trim(u8, value, " \t");
        if (input.len == 0) {
            @branchHint(.cold);
            return error.InvalidFormat;
        }
        if (input[0] == '#') {
            switch (input.len) {
                4 => return RGB{
                    .r = try RGB.fromHex(input[1..2]),
                    .g = try RGB.fromHex(input[2..3]),
                    .b = try RGB.fromHex(input[3..4]),
                },
                7 => return RGB{
                    .r = try RGB.fromHex(input[1..3]),
                    .g = try RGB.fromHex(input[3..5]),
                    .b = try RGB.fromHex(input[5..7]),
                },
                10 => return RGB{
                    .r = try RGB.fromHex(input[1..4]),
                    .g = try RGB.fromHex(input[4..7]),
                    .b = try RGB.fromHex(input[7..10]),
                },
                13 => return RGB{
                    .r = try RGB.fromHex(input[1..5]),
                    .g = try RGB.fromHex(input[5..9]),
                    .b = try RGB.fromHex(input[9..13]),
                },
                else => {
                    @branchHint(.cold);
                    return error.InvalidFormat;
                },
            }
        }
        if (x11_color.map.get(input)) |rgb| return rgb;
        switch (input.len) {
            3 => return RGB{
                .r = try RGB.fromHex(input[0..1]),
                .g = try RGB.fromHex(input[1..2]),
                .b = try RGB.fromHex(input[2..3]),
            },
            6 => return RGB{
                .r = try RGB.fromHex(input[0..2]),
                .g = try RGB.fromHex(input[2..4]),
                .b = try RGB.fromHex(input[4..6]),
            },
            else => {},
        }
        if (input.len < "rgb:a/a/a".len or !std.mem.eql(u8, input[0..3], "rgb")) {
            @branchHint(.cold);
            return error.InvalidFormat;
        }
        var i: usize = 3;
        const use_intensity = if (input[i] == 'i') blk: {
            i += 1;
            break :blk true;
        } else false;
        if (input[i] != ':') {
            @branchHint(.cold);
            return error.InvalidFormat;
        }
        i += 1;
        const r = r: {
            const slice = if (std.mem.indexOfScalarPos(u8, input, i, '/')) |end|
                input[i..end]
            else {
                @branchHint(.cold);
                return error.InvalidFormat;
            };
            i += slice.len + 1;
            break :r if (use_intensity)
                try RGB.fromIntensity(slice)
            else
                try RGB.fromHex(slice);
        };
        const g = g: {
            const slice = if (std.mem.indexOfScalarPos(u8, input, i, '/')) |end|
                input[i..end]
            else {
                @branchHint(.cold);
                return error.InvalidFormat;
            };
            i += slice.len + 1;
            break :g if (use_intensity)
                try RGB.fromIntensity(slice)
            else
                try RGB.fromHex(slice);
        };
        const b = if (use_intensity)
            try RGB.fromIntensity(input[i..])
        else
            try RGB.fromHex(input[i..]);
        return RGB{
            .r = r,
            .g = g,
            .b = b,
        };
    }
};
const LAB = struct {
    l: f32,
    a: f32,
    b: f32,
    pub fn fromRgb(rgb: RGB) LAB {
        var r: f32 = @as(f32, @floatFromInt(rgb.r)) / 255.0;
        var g: f32 = @as(f32, @floatFromInt(rgb.g)) / 255.0;
        var b: f32 = @as(f32, @floatFromInt(rgb.b)) / 255.0;
        r = if (r > 0.04045) std.math.pow(f32, (r + 0.055) / 1.055, 2.4) else r / 12.92;
        g = if (g > 0.04045) std.math.pow(f32, (g + 0.055) / 1.055, 2.4) else g / 12.92;
        b = if (b > 0.04045) std.math.pow(f32, (b + 0.055) / 1.055, 2.4) else b / 12.92;
        var x = (r * 0.4124564 + g * 0.3575761 + b * 0.1804375) / 0.95047;
        var y = r * 0.2126729 + g * 0.7151522 + b * 0.0721750;
        var z = (r * 0.0193339 + g * 0.1191920 + b * 0.9503041) / 1.08883;
        x = if (x > 0.008856) std.math.cbrt(x) else 7.787 * x + 16.0 / 116.0;
        y = if (y > 0.008856) std.math.cbrt(y) else 7.787 * y + 16.0 / 116.0;
        z = if (z > 0.008856) std.math.cbrt(z) else 7.787 * z + 16.0 / 116.0;
        return .{ .l = 116.0 * y - 16.0, .a = 500.0 * (x - y), .b = 200.0 * (y - z) };
    }
    pub fn toRgb(self: LAB) RGB {
        const y = (self.l + 16.0) / 116.0;
        const x = self.a / 500.0 + y;
        const z = y - self.b / 200.0;
        const x3 = x * x * x;
        const y3 = y * y * y;
        const z3 = z * z * z;
        const xf = (if (x3 > 0.008856) x3 else (x - 16.0 / 116.0) / 7.787) * 0.95047;
        const yf = if (y3 > 0.008856) y3 else (y - 16.0 / 116.0) / 7.787;
        const zf = (if (z3 > 0.008856) z3 else (z - 16.0 / 116.0) / 7.787) * 1.08883;
        var r = xf * 3.2404542 - yf * 1.5371385 - zf * 0.4985314;
        var g = -xf * 0.9692660 + yf * 1.8760108 + zf * 0.0415560;
        var b = xf * 0.0556434 - yf * 0.2040259 + zf * 1.0572252;
        r = if (r > 0.0031308) 1.055 * std.math.pow(f32, r, 1.0 / 2.4) - 0.055 else 12.92 * r;
        g = if (g > 0.0031308) 1.055 * std.math.pow(f32, g, 1.0 / 2.4) - 0.055 else 12.92 * g;
        b = if (b > 0.0031308) 1.055 * std.math.pow(f32, b, 1.0 / 2.4) - 0.055 else 12.92 * b;
        return .{
            .r = @intFromFloat(@min(@max(r, 0.0), 1.0) * 255.0 + 0.5),
            .g = @intFromFloat(@min(@max(g, 0.0), 1.0) * 255.0 + 0.5),
            .b = @intFromFloat(@min(@max(b, 0.0), 1.0) * 255.0 + 0.5),
        };
    }
    pub fn lerp(t: f32, a: LAB, b: LAB) LAB {
        return .{
            .l = a.l + t * (b.l - a.l),
            .a = a.a + t * (b.a - a.a),
            .b = a.b + t * (b.b - a.b),
        };
    }
};
test "palette: default" {
    const testing = std.testing;
    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        try testing.expectEqual(Name.default(@as(Name, @enumFromInt(i))), default[i]);
    }
}
test "RGB.parse" {
    const testing = std.testing;
    try testing.expectEqual(RGB{ .r = 255, .g = 0, .b = 0 }, try RGB.parse("rgbi:1.0/0/0"));
    try testing.expectEqual(RGB{ .r = 127, .g = 160, .b = 0 }, try RGB.parse("rgb:7f/a0a0/0"));
    try testing.expectEqual(RGB{ .r = 255, .g = 255, .b = 255 }, try RGB.parse("rgb:f/ff/fff"));
    try testing.expectEqual(RGB{ .r = 255, .g = 255, .b = 255 }, try RGB.parse("#ffffff"));
    try testing.expectEqual(RGB{ .r = 255, .g = 255, .b = 255 }, try RGB.parse("#fff"));
    try testing.expectEqual(RGB{ .r = 255, .g = 255, .b = 255 }, try RGB.parse("#fffffffff"));
    try testing.expectEqual(RGB{ .r = 255, .g = 255, .b = 255 }, try RGB.parse("#ffffffffffff"));
    try testing.expectEqual(RGB{ .r = 255, .g = 0, .b = 16 }, try RGB.parse("#ff0010"));
    try testing.expectEqual(RGB{ .r = 10, .g = 11, .b = 12 }, try RGB.parse("0A0B0C"));
    try testing.expectEqual(RGB{ .r = 255, .g = 255, .b = 255 }, try RGB.parse("FFFFFF"));
    try testing.expectEqual(RGB{ .r = 255, .g = 255, .b = 255 }, try RGB.parse("FFF"));
    try testing.expectEqual(RGB{ .r = 51, .g = 68, .b = 85 }, try RGB.parse("#345"));
    try testing.expectEqual(RGB{ .r = 170, .g = 187, .b = 204 }, try RGB.parse(" #AABBCC   "));
    try testing.expectEqual(RGB{ .r = 0, .g = 0, .b = 0 }, try RGB.parse("black"));
    try testing.expectEqual(RGB{ .r = 255, .g = 0, .b = 0 }, try RGB.parse("red"));
    try testing.expectEqual(RGB{ .r = 0, .g = 255, .b = 0 }, try RGB.parse("green"));
    try testing.expectEqual(RGB{ .r = 0, .g = 0, .b = 255 }, try RGB.parse("blue"));
    try testing.expectEqual(RGB{ .r = 255, .g = 255, .b = 255 }, try RGB.parse("white"));
    try testing.expectEqual(RGB{ .r = 124, .g = 252, .b = 0 }, try RGB.parse("LawnGreen"));
    try testing.expectEqual(RGB{ .r = 0, .g = 250, .b = 154 }, try RGB.parse("medium spring green"));
    try testing.expectEqual(RGB{ .r = 34, .g = 139, .b = 34 }, try RGB.parse(" Forest Green "));
    try testing.expectEqual(RGB{ .r = 34, .g = 139, .b = 34 }, try RGB.parse("\tForestGreen\t"));
    try testing.expectError(error.InvalidFormat, RGB.parse(""));
    try testing.expectError(error.InvalidFormat, RGB.parse("  "));
    try testing.expectError(error.InvalidFormat, RGB.parse("rgb;"));
    try testing.expectError(error.InvalidFormat, RGB.parse("rgb:"));
    try testing.expectError(error.InvalidFormat, RGB.parse(":a/a/a"));
    try testing.expectError(error.InvalidFormat, RGB.parse("a/a/a"));
    try testing.expectError(error.InvalidFormat, RGB.parse("rgb:a/a/a/"));
    try testing.expectError(error.InvalidFormat, RGB.parse("rgb:00000///"));
    try testing.expectError(error.InvalidFormat, RGB.parse("rgb:000/"));
    try testing.expectError(error.InvalidFormat, RGB.parse("rgbi:a/a/a"));
    try testing.expectError(error.InvalidFormat, RGB.parse("rgb:0.5/0.0/1.0"));
    try testing.expectError(error.InvalidFormat, RGB.parse("rgb:not/hex/zz"));
    try testing.expectError(error.InvalidFormat, RGB.parse("#"));
    try testing.expectError(error.InvalidFormat, RGB.parse("#ff"));
    try testing.expectError(error.InvalidFormat, RGB.parse("#ffff"));
    try testing.expectError(error.InvalidFormat, RGB.parse("#fffff"));
    try testing.expectError(error.InvalidFormat, RGB.parse("#gggggg"));
    try testing.expectError(error.InvalidFormat, RGB.parse("#12345"));
    try testing.expectError(error.InvalidFormat, RGB.parse("12345"));
    try testing.expectError(error.InvalidFormat, RGB.parse("nosuchcolor"));
}
test "RGB.parse rejects digit separators" {
    const testing = std.testing;
    try testing.expectError(error.InvalidFormat, RGB.parse("rgb:f_f/0/0"));
    try testing.expectError(error.InvalidFormat, RGB.parse("#f_f000000"));
}
test "RGB: encode" {
    const rgb: RGB = .{ .r = 0x01, .g = 0x23, .b = 0xff };
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try rgb.encodeRgb8(&writer);
    try std.testing.expectEqualStrings("rgb:01/23/ff", writer.buffered());
    writer = .fixed(&buf);
    try rgb.encodeRgb16(&writer);
    try std.testing.expectEqualStrings("rgb:0101/2323/ffff", writer.buffered());
}
test "DynamicPalette: init" {
    const testing = std.testing;
    var p: DynamicPalette = .default;
    defer p.deinit(testing.allocator);
    try testing.expectEqual(default, p.current);
    try testing.expectEqual(default, p.original.*);
    try testing.expectEqual(&default, p.original);
    try testing.expectEqual(@as(usize, 0), p.mask.count());
}
test "DynamicPalette: set" {
    const testing = std.testing;
    var p: DynamicPalette = .default;
    const new_color = RGB{ .r = 255, .g = 0, .b = 0 };
    p.set(0, new_color);
    try testing.expectEqual(new_color, p.current[0]);
    try testing.expect(p.mask.isSet(0));
    try testing.expectEqual(@as(usize, 1), p.mask.count());
    try testing.expectEqual(default[0], p.original[0]);
}
test "DynamicPalette: reset" {
    const testing = std.testing;
    var p: DynamicPalette = .default;
    const new_color = RGB{ .r = 255, .g = 0, .b = 0 };
    p.set(0, new_color);
    try testing.expect(p.mask.isSet(0));
    p.reset(0);
    try testing.expectEqual(default[0], p.current[0]);
    try testing.expect(!p.mask.isSet(0));
    try testing.expectEqual(@as(usize, 0), p.mask.count());
}
test "DynamicPalette: resetAll" {
    const testing = std.testing;
    var p: DynamicPalette = .default;
    const new_color = RGB{ .r = 255, .g = 0, .b = 0 };
    p.set(0, new_color);
    p.set(5, new_color);
    p.set(10, new_color);
    try testing.expectEqual(@as(usize, 3), p.mask.count());
    p.resetAll();
    try testing.expectEqual(default, p.current);
    try testing.expectEqual(default, p.original.*);
    try testing.expectEqual(@as(usize, 0), p.mask.count());
}
test "DynamicPalette: changeDefault with no changes" {
    const testing = std.testing;
    var p: DynamicPalette = .default;
    defer p.deinit(testing.allocator);
    var new_palette = default;
    new_palette[0] = RGB{ .r = 100, .g = 100, .b = 100 };
    try p.changeDefault(testing.allocator, new_palette);
    try testing.expectEqual(new_palette, p.original.*);
    try testing.expectEqual(new_palette, p.current);
    try testing.expectEqual(@as(usize, 0), p.mask.count());
}
test "DynamicPalette: changeDefault shares the built-in default" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var new_palette = default;
    new_palette[0] = RGB{ .r = 100, .g = 100, .b = 100 };
    var p: DynamicPalette = try .init(alloc, new_palette);
    defer p.deinit(alloc);
    try testing.expect(p.original != &default);
    try testing.expectEqual(new_palette, p.original.*);
    const owned = p.original;
    new_palette[1] = RGB{ .r = 101, .g = 101, .b = 101 };
    try p.changeDefault(alloc, new_palette);
    try testing.expectEqual(owned, p.original);
    try testing.expectEqual(new_palette, p.original.*);
    try p.changeDefault(alloc, default);
    try testing.expectEqual(&default, p.original);
    try testing.expectEqual(default, p.current);
    try p.changeDefault(alloc, new_palette);
    p.set(2, RGB{ .r = 1, .g = 2, .b = 3 });
    var reset_failing: std.testing.FailingAllocator = .init(alloc, .{
        .fail_index = 0,
    });
    p.resetDefault(reset_failing.allocator());
    try testing.expect(!reset_failing.has_induced_failure);
    try testing.expectEqual(&default, p.original);
    try testing.expectEqual(default[0], p.current[0]);
    try testing.expectEqual(RGB{ .r = 1, .g = 2, .b = 3 }, p.current[2]);
    try testing.expect(p.mask.isSet(2));
    var failing: std.testing.FailingAllocator = .init(alloc, .{
        .fail_index = 0,
    });
    var q: DynamicPalette = try .init(failing.allocator(), default);
    defer q.deinit(failing.allocator());
    try testing.expectEqual(&default, q.original);
    try testing.expect(!failing.has_induced_failure);
}
test "DynamicPalette: changeDefault preserves changes" {
    const testing = std.testing;
    var p: DynamicPalette = .default;
    defer p.deinit(testing.allocator);
    const custom_color = RGB{ .r = 255, .g = 0, .b = 0 };
    p.set(5, custom_color);
    try testing.expect(p.mask.isSet(5));
    var new_palette = default;
    new_palette[0] = RGB{ .r = 100, .g = 100, .b = 100 };
    new_palette[5] = RGB{ .r = 50, .g = 50, .b = 50 };
    try p.changeDefault(testing.allocator, new_palette);
    try testing.expectEqual(new_palette, p.original.*);
    try testing.expectEqual(new_palette[0], p.current[0]);
    try testing.expectEqual(custom_color, p.current[5]);
    try testing.expect(p.mask.isSet(5));
    try testing.expectEqual(@as(usize, 1), p.mask.count());
}
test "DynamicPalette: changeDefault with multiple changes" {
    const testing = std.testing;
    var p: DynamicPalette = .default;
    defer p.deinit(testing.allocator);
    const red = RGB{ .r = 255, .g = 0, .b = 0 };
    const green = RGB{ .r = 0, .g = 255, .b = 0 };
    const blue = RGB{ .r = 0, .g = 0, .b = 255 };
    p.set(1, red);
    p.set(2, green);
    p.set(3, blue);
    var new_palette = default;
    new_palette[0] = RGB{ .r = 50, .g = 50, .b = 50 };
    new_palette[1] = RGB{ .r = 60, .g = 60, .b = 60 };
    try p.changeDefault(testing.allocator, new_palette);
    try testing.expectEqual(new_palette[0], p.current[0]);
    try testing.expectEqual(red, p.current[1]);
    try testing.expectEqual(green, p.current[2]);
    try testing.expectEqual(blue, p.current[3]);
    try testing.expectEqual(@as(usize, 3), p.mask.count());
}
test "LAB.fromRgb" {
    const testing = std.testing;
    const epsilon = 0.5;
    const white = LAB.fromRgb(.{ .r = 255, .g = 255, .b = 255 });
    try testing.expectApproxEqAbs(@as(f32, 100.0), white.l, epsilon);
    try testing.expectApproxEqAbs(@as(f32, 0.0), white.a, epsilon);
    try testing.expectApproxEqAbs(@as(f32, 0.0), white.b, epsilon);
    const black = LAB.fromRgb(.{ .r = 0, .g = 0, .b = 0 });
    try testing.expectApproxEqAbs(@as(f32, 0.0), black.l, epsilon);
    try testing.expectApproxEqAbs(@as(f32, 0.0), black.a, epsilon);
    try testing.expectApproxEqAbs(@as(f32, 0.0), black.b, epsilon);
    const red = LAB.fromRgb(.{ .r = 255, .g = 0, .b = 0 });
    try testing.expectApproxEqAbs(@as(f32, 53.23), red.l, epsilon);
    try testing.expectApproxEqAbs(@as(f32, 80.11), red.a, epsilon);
    try testing.expectApproxEqAbs(@as(f32, 67.22), red.b, epsilon);
    const green = LAB.fromRgb(.{ .r = 0, .g = 128, .b = 0 });
    try testing.expectApproxEqAbs(@as(f32, 46.23), green.l, epsilon);
    try testing.expectApproxEqAbs(@as(f32, -51.70), green.a, epsilon);
    try testing.expectApproxEqAbs(@as(f32, 49.90), green.b, epsilon);
    const blue = LAB.fromRgb(.{ .r = 0, .g = 0, .b = 255 });
    try testing.expectApproxEqAbs(@as(f32, 32.30), blue.l, epsilon);
    try testing.expectApproxEqAbs(@as(f32, 79.20), blue.a, epsilon);
    try testing.expectApproxEqAbs(@as(f32, -107.86), blue.b, epsilon);
}
test "generate256Color: base16 preserved" {
    const testing = std.testing;
    const bg = RGB{ .r = 0, .g = 0, .b = 0 };
    const fg = RGB{ .r = 255, .g = 255, .b = 255 };
    const palette = generate256Color(default, .initEmpty(), bg, fg, false);
    for (0..16) |i| {
        try testing.expectEqual(default[i], palette[i]);
    }
}
test "generate256Color: cube corners match base colors" {
    const testing = std.testing;
    const bg = RGB{ .r = 0, .g = 0, .b = 0 };
    const fg = RGB{ .r = 255, .g = 255, .b = 255 };
    const palette = generate256Color(default, .initEmpty(), bg, fg, false);
    try testing.expectEqual(bg, palette[16]);
    try testing.expectEqual(fg, palette[231]);
}
test "generate256Color: cube corners black/white with harmonious=false" {
    const testing = std.testing;
    const black = RGB{ .r = 0, .g = 0, .b = 0 };
    const white = RGB{ .r = 255, .g = 255, .b = 255 };
    const dark = generate256Color(default, .initEmpty(), black, white, false);
    try testing.expectEqual(black, dark[16]);
    try testing.expectEqual(white, dark[231]);
    const light = generate256Color(default, .initEmpty(), white, black, false);
    try testing.expectEqual(black, light[16]);
    try testing.expectEqual(white, light[231]);
}
test "generate256Color: light theme cube corners with harmonious=true" {
    const testing = std.testing;
    const white = RGB{ .r = 255, .g = 255, .b = 255 };
    const black = RGB{ .r = 0, .g = 0, .b = 0 };
    const palette = generate256Color(default, .initEmpty(), white, black, true);
    try testing.expectEqual(white, palette[16]);
    try testing.expectEqual(black, palette[231]);
}
test "generate256Color: grayscale ramp monotonic luminance" {
    const testing = std.testing;
    const bg = RGB{ .r = 0, .g = 0, .b = 0 };
    const fg = RGB{ .r = 255, .g = 255, .b = 255 };
    const palette = generate256Color(default, .initEmpty(), bg, fg, false);
    var prev_lum: f64 = 0.0;
    for (232..256) |i| {
        const lum = palette[i].luminance();
        try testing.expect(lum >= prev_lum);
        prev_lum = lum;
    }
}
test "generate256Color: skip mask preserves original colors" {
    const testing = std.testing;
    const bg = RGB{ .r = 0, .g = 0, .b = 0 };
    const fg = RGB{ .r = 255, .g = 255, .b = 255 };
    var skip: PaletteMask = .initEmpty();
    skip.set(20);
    skip.set(100);
    skip.set(240);
    const palette = generate256Color(default, skip, bg, fg, false);
    try testing.expectEqual(default[20], palette[20]);
    try testing.expectEqual(default[100], palette[100]);
    try testing.expectEqual(default[240], palette[240]);
    try testing.expect(!palette[21].eql(default[21]));
}
test "generate256Color: dark theme harmonious has no effect" {
    const testing = std.testing;
    const bg = RGB{ .r = 0, .g = 0, .b = 0 };
    const fg = RGB{ .r = 255, .g = 255, .b = 255 };
    const normal = generate256Color(default, .initEmpty(), bg, fg, false);
    const harmonious = generate256Color(default, .initEmpty(), bg, fg, true);
    for (16..256) |i| {
        try testing.expectEqual(normal[i], harmonious[i]);
    }
}
test "generate256Color: light theme harmonious skips inversion" {
    const testing = std.testing;
    const bg = RGB{ .r = 255, .g = 255, .b = 255 };
    const fg = RGB{ .r = 0, .g = 0, .b = 0 };
    const inverted = generate256Color(default, .initEmpty(), bg, fg, false);
    const harmonious = generate256Color(default, .initEmpty(), bg, fg, true);
    try testing.expectEqual(bg, harmonious[16]);
    try testing.expect(!inverted[16].eql(bg));
    var differ: usize = 0;
    for (16..232) |i| {
        if (!inverted[i].eql(harmonious[i])) differ += 1;
    }
    try testing.expect(differ > 0);
}
test "generate256Color: light theme harmonious grayscale ramp" {
    const testing = std.testing;
    const bg = RGB{ .r = 255, .g = 255, .b = 255 };
    const fg = RGB{ .r = 0, .g = 0, .b = 0 };
    {
        const palette = generate256Color(default, .initEmpty(), bg, fg, false);
        var prev_lum: f64 = 0.0;
        for (232..256) |i| {
            const lum = palette[i].luminance();
            try testing.expect(lum >= prev_lum);
            prev_lum = lum;
        }
    }
    {
        const palette = generate256Color(default, .initEmpty(), bg, fg, true);
        var prev_lum: f64 = 1.0;
        for (232..256) |i| {
            const lum = palette[i].luminance();
            try testing.expect(lum <= prev_lum);
            prev_lum = lum;
        }
    }
}
test "LAB.toRgb" {
    const testing = std.testing;
    const cases = [_]RGB{
        .{ .r = 255, .g = 255, .b = 255 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 255, .g = 0, .b = 0 },
        .{ .r = 0, .g = 128, .b = 0 },
        .{ .r = 0, .g = 0, .b = 255 },
        .{ .r = 128, .g = 128, .b = 128 },
        .{ .r = 64, .g = 224, .b = 208 },
    };
    for (cases) |expected| {
        const lab = LAB.fromRgb(expected);
        const actual = lab.toRgb();
        try testing.expectEqual(expected.r, actual.r);
        try testing.expectEqual(expected.g, actual.g);
        try testing.expectEqual(expected.b, actual.b);
    }
}
test paletteCvalSlice {
    const testing = std.testing;
    var src: Palette = undefined;
    for (&src, 0..) |*rgb, i| rgb.* = .{
        .r = @intCast(i % 256),
        .g = @intCast((i * 7 + 1) % 256),
        .b = @intCast((i * 13 + 2) % 256),
    };
    var dst: PaletteC = undefined;
    for (0..src.len + 1) |len| {
        @memset(std.mem.asBytes(&dst), 0xAA);
        paletteCvalSlice(src[0..len], dst[0..len]);
        for (src[0..len], dst[0..len]) |rgb, c| {
            try testing.expectEqual(rgb.r, c.r);
            try testing.expectEqual(rgb.g, c.g);
            try testing.expectEqual(rgb.b, c.b);
        }
        for (std.mem.asBytes(&dst)[len * 3 ..]) |b| {
            try testing.expectEqual(@as(u8, 0xAA), b);
        }
    }
}
