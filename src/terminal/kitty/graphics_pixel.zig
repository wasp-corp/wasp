const std = @import("std");
const Allocator = std.mem.Allocator;
const wuffs = @import("wuffs");
const command = @import("graphics_command.zig");
pub fn rgbaFromFormat(
    alloc: Allocator,
    format: command.Transmission.Format,
    data: []const u8,
) Allocator.Error![]u8 {
    const result = switch (format) {
        .rgba => return try alloc.dupe(u8, data),
        .rgb => wuffs.swizzle.rgbToRgba(alloc, data),
        .gray => wuffs.swizzle.gToRgba(alloc, data),
        .gray_alpha => wuffs.swizzle.gaToRgba(alloc, data),
        .png => unreachable,
    };
    return result catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.WuffsError, error.Overflow => unreachable,
    };
}
pub fn fillBackground(
    data: []u8,
    bg: command.AnimationFrameLoading.Background,
) void {
    const raw: u32 = @bitCast(bg);
    if (raw == 0) {
        @memset(data, 0);
        return;
    }
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) {
        data[i + 0] = bg.r;
        data[i + 1] = bg.g;
        data[i + 2] = bg.b;
        data[i + 3] = bg.a;
    }
}
pub fn composeRect(
    dst: []u8,
    dst_width: u32,
    dst_height: u32,
    src: []const u8,
    src_width: u32,
    src_height: u32,
    x: u32,
    y: u32,
    mode: command.CompositionMode,
) void {
    if (x >= dst_width or y >= dst_height) return;
    const width: usize = @min(src_width, dst_width - x);
    const height: usize = @min(src_height, dst_height - y);
    for (0..height) |row| {
        const dst_off = ((y + row) * dst_width + x) * 4;
        const src_off = row * @as(usize, src_width) * 4;
        composeRow(
            dst[dst_off..][0 .. width * 4],
            src[src_off..][0 .. width * 4],
            mode,
        );
    }
}
pub fn composeCanvasRect(
    dst: []u8,
    src: []const u8,
    canvas_width: u32,
    width: u32,
    height: u32,
    src_x: u32,
    src_y: u32,
    dst_x: u32,
    dst_y: u32,
    mode: command.CompositionMode,
) void {
    for (0..height) |row| {
        const dst_off = ((dst_y + row) * @as(usize, canvas_width) + dst_x) * 4;
        const src_off = ((src_y + row) * @as(usize, canvas_width) + src_x) * 4;
        composeRow(
            dst[dst_off..][0 .. @as(usize, width) * 4],
            src[src_off..][0 .. @as(usize, width) * 4],
            mode,
        );
    }
}
fn composeRow(dst: []u8, src: []const u8, mode: command.CompositionMode) void {
    switch (mode) {
        .overwrite => @memcpy(dst, src),
        .alpha_blend => wuffs.swizzle.rgbaSrcOver(dst, src),
    }
}
test "rgba conversion" {
    const testing = std.testing;
    const alloc = testing.allocator;
    {
        const rgb = [_]u8{ 1, 2, 3, 4, 5, 6 };
        const result = try rgbaFromFormat(alloc, .rgb, &rgb);
        defer alloc.free(result);
        try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255, 4, 5, 6, 255 }, result);
    }
    {
        const gray = [_]u8{ 7, 8 };
        const result = try rgbaFromFormat(alloc, .gray, &gray);
        defer alloc.free(result);
        try testing.expectEqualSlices(u8, &.{ 7, 7, 7, 255, 8, 8, 8, 255 }, result);
    }
    {
        const ga = [_]u8{ 7, 100, 8, 200 };
        const result = try rgbaFromFormat(alloc, .gray_alpha, &ga);
        defer alloc.free(result);
        try testing.expectEqualSlices(u8, &.{ 7, 7, 7, 100, 8, 8, 8, 200 }, result);
    }
    {
        const rgba = [_]u8{ 1, 2, 3, 4 };
        const result = try rgbaFromFormat(alloc, .rgba, &rgba);
        defer alloc.free(result);
        try testing.expectEqualSlices(u8, &rgba, result);
    }
}
test "fill background" {
    var buf: [8]u8 = undefined;
    fillBackground(&buf, .{ .r = 1, .g = 2, .b = 3, .a = 4 });
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 1, 2, 3, 4 }, &buf);
    fillBackground(&buf, .{});
    try std.testing.expectEqualSlices(u8, &(.{0} ** 8), &buf);
}
test "compose rect overwrite with clipping" {
    var dst = [_]u8{0} ** 16;
    const src = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    composeRect(&dst, 2, 2, &src, 2, 1, 1, 1, .overwrite);
    var expect = [_]u8{0} ** 16;
    expect[12] = 1;
    expect[13] = 2;
    expect[14] = 3;
    expect[15] = 4;
    try std.testing.expectEqualSlices(u8, &expect, &dst);
}
test "compose rect entirely out of bounds" {
    var dst = [_]u8{9} ** 16;
    const src = [_]u8{1} ** 4;
    composeRect(&dst, 2, 2, &src, 1, 1, 2, 0, .overwrite);
    composeRect(&dst, 2, 2, &src, 1, 1, 0, 2, .overwrite);
    try std.testing.expectEqualSlices(u8, &(.{9} ** 16), &dst);
}
test "alpha blend source-over semantics" {
    const testing = std.testing;
    {
        var dst = [4]u8{ 10, 20, 30, 40 };
        composeRect(&dst, 1, 1, &.{ 100, 110, 120, 255 }, 1, 1, 0, 0, .alpha_blend);
        try testing.expectEqualSlices(u8, &.{ 100, 110, 120, 255 }, &dst);
    }
    {
        var dst = [4]u8{ 10, 20, 30, 40 };
        composeRect(&dst, 1, 1, &.{ 100, 110, 120, 0 }, 1, 1, 0, 0, .alpha_blend);
        try testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40 }, &dst);
    }
    {
        var dst = [4]u8{ 0, 0, 0, 255 };
        composeRect(&dst, 1, 1, &.{ 255, 255, 255, 128 }, 1, 1, 0, 0, .alpha_blend);
        try testing.expectEqual(@as(u8, 255), dst[3]);
        try testing.expectEqual(@as(u8, 128), dst[0]);
    }
    {
        var dst = [4]u8{ 0, 0, 0, 0 };
        composeRect(&dst, 1, 1, &.{ 200, 100, 50, 128 }, 1, 1, 0, 0, .alpha_blend);
        try testing.expectEqualSlices(u8, &.{ 200, 100, 50, 128 }, &dst);
    }
}
test "compose canvas rect" {
    var canvas = [_]u8{ 1, 2, 3, 4, 0, 0, 0, 0, 9, 9, 9, 9 };
    composeCanvasRect(&canvas, &canvas, 3, 1, 1, 0, 0, 2, 0, .overwrite);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 1, 2, 3, 4, 0, 0, 0, 0, 1, 2, 3, 4 },
        &canvas,
    );
}
