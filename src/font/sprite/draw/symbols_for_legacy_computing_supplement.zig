const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../../../quirks.zig").inlineAssert;
const common = @import("common.zig");
const Thickness = common.Thickness;
const Fraction = common.Fraction;
const Corner = common.Corner;
const Shade = common.Shade;
const fill = common.fill;
const box = @import("box.zig");
const sflc = @import("symbols_for_legacy_computing.zig");
const font = @import("../../main.zig");
const octant_min = 0x1cd00;
const octant_max = 0x1cde5;
pub fn draw1CD00_1CDE5(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = width;
    _ = height;
    const Octant = packed struct(u8) {
        @"1": bool = false,
        @"2": bool = false,
        @"3": bool = false,
        @"4": bool = false,
        @"5": bool = false,
        @"6": bool = false,
        @"7": bool = false,
        @"8": bool = false,
    };
    const octants_len = octant_max - octant_min + 1;
    const octants: [octants_len]Octant = comptime octants: {
        @setEvalBranchQuota(10_000);
        var result: [octants_len]Octant = @splat(.{});
        var i: usize = 0;
        const data = @embedFile("octants.txt");
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |raw_line| {
            const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
                raw_line[0 .. raw_line.len - 1]
            else
                raw_line;
            if (line.len == 0 or line[0] == '#') continue;
            const current = &result[i];
            i += 1;
            const idx = std.mem.indexOfScalar(u8, line, '-').?;
            for (line[idx + 1 ..]) |c| @field(current, &.{c}) = true;
        }
        assert(i == octants_len);
        break :octants result;
    };
    const oct = octants[cp - octant_min];
    if (oct.@"1") fill(metrics, canvas, .zero, .half, .zero, .one_quarter);
    if (oct.@"2") fill(metrics, canvas, .half, .full, .zero, .one_quarter);
    if (oct.@"3") fill(metrics, canvas, .zero, .half, .one_quarter, .two_quarters);
    if (oct.@"4") fill(metrics, canvas, .half, .full, .one_quarter, .two_quarters);
    if (oct.@"5") fill(metrics, canvas, .zero, .half, .two_quarters, .three_quarters);
    if (oct.@"6") fill(metrics, canvas, .half, .full, .two_quarters, .three_quarters);
    if (oct.@"7") fill(metrics, canvas, .zero, .half, .three_quarters, .end);
    if (oct.@"8") fill(metrics, canvas, .half, .full, .three_quarters, .end);
}
pub fn draw1CC21_1CC2F(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = metrics;
    const Quads = packed struct(u4) {
        tl: bool,
        tr: bool,
        bl: bool,
        br: bool,
    };
    const quad: Quads = @bitCast(@as(u4, @truncate(cp - 0x1CC20)));
    const gap: i32 = @intCast(@max(1, width / 12));
    const mid_gap_x: i32 = gap * 2 + @as(i32, @intCast(width % 2));
    const mid_gap_y: i32 = gap * 2 + @as(i32, @intCast(height % 2));
    const w: i32 = @divExact(@as(i32, @intCast(width)) - gap * 2 - mid_gap_x, 2);
    const h: i32 = @divExact(@as(i32, @intCast(height)) - gap * 2 - mid_gap_y, 2);
    if (quad.tl) canvas.box(
        gap,
        gap,
        gap + w,
        gap + h,
        .on,
    );
    if (quad.tr) canvas.box(
        gap + w + mid_gap_x,
        gap,
        gap + w + mid_gap_x + w,
        gap + h,
        .on,
    );
    if (quad.bl) canvas.box(
        gap,
        gap + h + mid_gap_y,
        gap + w,
        gap + h + mid_gap_y + h,
        .on,
    );
    if (quad.br) canvas.box(
        gap + w + mid_gap_x,
        gap + h + mid_gap_y,
        gap + w + mid_gap_x + w,
        gap + h + mid_gap_y + h,
        .on,
    );
}
pub fn draw1CC30_1CC3F(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    switch (cp) {
        0x1CC30 => try circlePiece(canvas, width, height, metrics, 0, 0, 2, 2, .tl),
        0x1CC31 => try circlePiece(canvas, width, height, metrics, 1, 0, 2, 2, .tl),
        0x1CC32 => try circlePiece(canvas, width, height, metrics, 2, 0, 2, 2, .tr),
        0x1CC33 => try circlePiece(canvas, width, height, metrics, 3, 0, 2, 2, .tr),
        0x1CC34 => try circlePiece(canvas, width, height, metrics, 0, 1, 2, 2, .tl),
        0x1CC35 => try circlePiece(canvas, width, height, metrics, 0, 0, 1, 1, .tl),
        0x1CC36 => try circlePiece(canvas, width, height, metrics, 1, 0, 1, 1, .tr),
        0x1CC37 => try circlePiece(canvas, width, height, metrics, 3, 1, 2, 2, .tr),
        0x1CC38 => try circlePiece(canvas, width, height, metrics, 0, 2, 2, 2, .bl),
        0x1CC39 => try circlePiece(canvas, width, height, metrics, 0, 1, 1, 1, .bl),
        0x1CC3A => try circlePiece(canvas, width, height, metrics, 1, 1, 1, 1, .br),
        0x1CC3B => try circlePiece(canvas, width, height, metrics, 3, 2, 2, 2, .br),
        0x1CC3C => try circlePiece(canvas, width, height, metrics, 0, 3, 2, 2, .bl),
        0x1CC3D => try circlePiece(canvas, width, height, metrics, 1, 3, 2, 2, .bl),
        0x1CC3E => try circlePiece(canvas, width, height, metrics, 2, 3, 2, 2, .br),
        0x1CC3F => try circlePiece(canvas, width, height, metrics, 3, 3, 2, 2, .br),
        else => unreachable,
    }
}
pub fn draw1CC1B_1CC1E(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    const w: i32 = @intCast(width);
    const h: i32 = @intCast(height);
    const t: i32 = @intCast(metrics.box_thickness);
    switch (cp) {
        0x1CC1B => {
            box.linesChar(metrics, canvas, .{ .left = .light, .right = .light });
            canvas.box(w - t, 0, w, @divFloor(h, 2), .on);
        },
        0x1CC1C => {
            box.linesChar(metrics, canvas, .{ .left = .light, .right = .light });
            canvas.box(w - t, @divFloor(h, 2), w, h, .on);
        },
        0x1CC1D => {
            canvas.box(0, 0, w, t, .on);
            canvas.box(0, 0, t, @divFloor(h, 2), .on);
        },
        0x1CC1E => {
            canvas.box(0, h - t, w, h, .on);
            canvas.box(0, @divFloor(h, 2), t, h, .on);
        },
        else => unreachable,
    }
}
pub fn draw1CE00(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = width;
    _ = height;
    sflc.circle(metrics, canvas, .left, false);
    sflc.circle(metrics, canvas, .right, false);
}
pub fn draw1CE01(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = width;
    _ = height;
    sflc.circle(metrics, canvas, .top, false);
    sflc.circle(metrics, canvas, .bottom, false);
}
pub fn draw1CE0B(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    try circlePiece(canvas, width, height, metrics, 0, 0, 1, 0.5, .tl);
    try circlePiece(canvas, width, height, metrics, 0, 0, 1, 0.5, .bl);
}
pub fn draw1CE0C(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    try circlePiece(canvas, width, height, metrics, 1, 0, 1, 0.5, .tr);
    try circlePiece(canvas, width, height, metrics, 1, 0, 1, 0.5, .br);
}
pub fn draw1CE16_1CE19(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    const w: i32 = @intCast(width);
    const h: i32 = @intCast(height);
    const t: i32 = @intCast(metrics.box_thickness);
    switch (cp) {
        0x1CE16 => {
            box.linesChar(metrics, canvas, .{ .up = .light, .down = .light });
            canvas.box(@divFloor(w, 2), 0, w, t, .on);
        },
        0x1CE17 => {
            box.linesChar(metrics, canvas, .{ .up = .light, .down = .light });
            canvas.box(@divFloor(w, 2), h - t, w, h, .on);
        },
        0x1CE18 => {
            box.linesChar(metrics, canvas, .{ .up = .light, .down = .light });
            canvas.box(0, 0, @divFloor(w, 2), t, .on);
        },
        0x1CE19 => {
            box.linesChar(metrics, canvas, .{ .up = .light, .down = .light });
            canvas.box(0, h - t, @divFloor(w, 2), h, .on);
        },
        else => unreachable,
    }
}
pub fn draw1CE51_1CE8F(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = metrics;
    const Sextants = packed struct(u6) {
        tl: bool,
        tr: bool,
        ml: bool,
        mr: bool,
        bl: bool,
        br: bool,
    };
    const sex: Sextants = @bitCast(@as(u6, @truncate(cp - 0x1CE50)));
    const gap: i32 = @intCast(@max(1, width / 12));
    const mid_gap_x: i32 = gap * 2 + @as(i32, @intCast(width % 2));
    const y_extra: i32 = @as(i32, @intCast(height % 3));
    const mid_gap_y: i32 = gap * 2 + @divFloor(y_extra, 2);
    const w: i32 = @divExact(@as(i32, @intCast(width)) - gap * 2 - mid_gap_x, 2);
    const h: i32 = @divFloor(
        @as(i32, @intCast(height)) - gap * 2 - mid_gap_y * 2,
        3,
    );
    const h_m: i32 = @as(i32, @intCast(height)) - gap * 2 - mid_gap_y * 2 - h * 2;
    if (sex.tl) canvas.box(
        gap,
        gap,
        gap + w,
        gap + h,
        .on,
    );
    if (sex.tr) canvas.box(
        gap + w + mid_gap_x,
        gap,
        gap + w + mid_gap_x + w,
        gap + h,
        .on,
    );
    if (sex.ml) canvas.box(
        gap,
        gap + h + mid_gap_y,
        gap + w,
        gap + h + mid_gap_y + h_m,
        .on,
    );
    if (sex.mr) canvas.box(
        gap + w + mid_gap_x,
        gap + h + mid_gap_y,
        gap + w + mid_gap_x + w,
        gap + h + mid_gap_y + h_m,
        .on,
    );
    if (sex.bl) canvas.box(
        gap,
        gap + h + mid_gap_y + h_m + mid_gap_y,
        gap + w,
        gap + h + mid_gap_y + h_m + mid_gap_y + h,
        .on,
    );
    if (sex.br) canvas.box(
        gap + w + mid_gap_x,
        gap + h + mid_gap_y + h_m + mid_gap_y,
        gap + w + mid_gap_x + w,
        gap + h + mid_gap_y + h_m + mid_gap_y + h,
        .on,
    );
}
pub fn draw1CE90_1CEAF(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = width;
    _ = height;
    const q = Fraction.quarters;
    switch (cp) {
        0x1CE90 => fill(metrics, canvas, q[0], q[1], q[0], q[1]),
        0x1CE91 => fill(metrics, canvas, q[1], q[2], q[0], q[1]),
        0x1CE92 => fill(metrics, canvas, q[2], q[3], q[0], q[1]),
        0x1CE93 => fill(metrics, canvas, q[3], q[4], q[0], q[1]),
        0x1CE94 => fill(metrics, canvas, q[0], q[1], q[1], q[2]),
        0x1CE95 => fill(metrics, canvas, q[1], q[2], q[1], q[2]),
        0x1CE96 => fill(metrics, canvas, q[2], q[3], q[1], q[2]),
        0x1CE97 => fill(metrics, canvas, q[3], q[4], q[1], q[2]),
        0x1CE98 => fill(metrics, canvas, q[0], q[1], q[2], q[3]),
        0x1CE99 => fill(metrics, canvas, q[1], q[2], q[2], q[3]),
        0x1CE9A => fill(metrics, canvas, q[2], q[3], q[2], q[3]),
        0x1CE9B => fill(metrics, canvas, q[3], q[4], q[2], q[3]),
        0x1CE9C => fill(metrics, canvas, q[0], q[1], q[3], q[4]),
        0x1CE9D => fill(metrics, canvas, q[1], q[2], q[3], q[4]),
        0x1CE9E => fill(metrics, canvas, q[2], q[3], q[3], q[4]),
        0x1CE9F => fill(metrics, canvas, q[3], q[4], q[3], q[4]),
        0x1CEA0 => fill(metrics, canvas, q[2], q[4], q[3], q[4]),
        0x1CEA1 => fill(metrics, canvas, q[1], q[4], q[3], q[4]),
        0x1CEA2 => fill(metrics, canvas, q[0], q[3], q[3], q[4]),
        0x1CEA3 => fill(metrics, canvas, q[0], q[2], q[3], q[4]),
        0x1CEA4 => fill(metrics, canvas, q[0], q[1], q[2], q[4]),
        0x1CEA5 => fill(metrics, canvas, q[0], q[1], q[1], q[4]),
        0x1CEA6 => fill(metrics, canvas, q[0], q[1], q[0], q[3]),
        0x1CEA7 => fill(metrics, canvas, q[0], q[1], q[0], q[2]),
        0x1CEA8 => fill(metrics, canvas, q[0], q[2], q[0], q[1]),
        0x1CEA9 => fill(metrics, canvas, q[0], q[3], q[0], q[1]),
        0x1CEAA => fill(metrics, canvas, q[1], q[4], q[0], q[1]),
        0x1CEAB => fill(metrics, canvas, q[2], q[4], q[0], q[1]),
        0x1CEAC => fill(metrics, canvas, q[3], q[4], q[0], q[2]),
        0x1CEAD => fill(metrics, canvas, q[3], q[4], q[0], q[3]),
        0x1CEAE => fill(metrics, canvas, q[3], q[4], q[1], q[4]),
        0x1CEAF => fill(metrics, canvas, q[3], q[4], q[2], q[4]),
        else => unreachable,
    }
}
fn circlePiece(
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    corner: Corner,
) !void {
    const wdth: f64 = @as(f64, @floatFromInt(width)) * w;
    const hght: f64 = @as(f64, @floatFromInt(height)) * h;
    const xp: f64 = @as(f64, @floatFromInt(width)) * x;
    const yp: f64 = @as(f64, @floatFromInt(height)) * y;
    canvas.clip_left = canvas.padding_x;
    canvas.clip_right = canvas.padding_x;
    canvas.clip_top = canvas.padding_y;
    canvas.clip_bottom = canvas.padding_y;
    const c: f64 = (std.math.sqrt2 - 1.0) * 4.0 / 3.0;
    const cw = c * wdth;
    const ch = c * hght;
    const thick: f64 = @floatFromInt(metrics.box_thickness);
    const ht = thick * 0.5;
    var path = canvas.staticPath(2);
    switch (corner) {
        .tl => {
            path.moveTo(wdth - xp, ht - yp);
            path.curveTo(
                wdth - cw - xp,
                ht - yp,
                ht - xp,
                hght - ch - yp,
                ht - xp,
                hght - yp,
            );
        },
        .tr => {
            path.moveTo(wdth - xp, ht - yp);
            path.curveTo(
                wdth + cw - xp,
                ht - yp,
                wdth * 2 - ht - xp,
                hght - ch - yp,
                wdth * 2 - ht - xp,
                hght - yp,
            );
        },
        .bl => {
            path.moveTo(ht - xp, hght - yp);
            path.curveTo(
                ht - xp,
                hght + ch - yp,
                wdth - cw - xp,
                hght * 2 - ht - yp,
                wdth - xp,
                hght * 2 - ht - yp,
            );
        },
        .br => {
            path.moveTo(wdth * 2 - ht - xp, hght - yp);
            path.curveTo(
                wdth * 2 - ht - xp,
                hght + ch - yp,
                wdth + cw - xp,
                hght * 2 - ht - yp,
                wdth - xp,
                hght * 2 - ht - yp,
            );
        },
    }
    try canvas.strokePath(path.wrapped_path, .{
        .line_cap_mode = .butt,
        .line_width = @floatFromInt(metrics.box_thickness),
    }, .on);
}
