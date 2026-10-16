const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common.zig");
const Thickness = common.Thickness;
const Shade = common.Shade;
const Edge = common.Edge;
const hlineMiddle = common.hlineMiddle;
const vlineMiddle = common.vlineMiddle;
const arc = @import("box.zig").arc;
const font = @import("../../main.zig");
const BranchNode = packed struct(u5) {
    up: bool = false,
    right: bool = false,
    down: bool = false,
    left: bool = false,
    filled: bool = false,
};
pub fn drawF5D0_F60D(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = width;
    _ = height;
    switch (cp) {
        0x0f5d0 => hlineMiddle(metrics, canvas, .light),
        0x0f5d1 => vlineMiddle(metrics, canvas, .light),
        0x0f5d2 => fadingLine(metrics, canvas, .right, .light),
        0x0f5d3 => fadingLine(metrics, canvas, .left, .light),
        0x0f5d4 => fadingLine(metrics, canvas, .bottom, .light),
        0x0f5d5 => fadingLine(metrics, canvas, .top, .light),
        0x0f5d6 => try arc(metrics, canvas, .br, .light),
        0x0f5d7 => try arc(metrics, canvas, .bl, .light),
        0x0f5d8 => try arc(metrics, canvas, .tr, .light),
        0x0f5d9 => try arc(metrics, canvas, .tl, .light),
        0x0f5da => {
            vlineMiddle(metrics, canvas, .light);
            try arc(metrics, canvas, .tr, .light);
        },
        0x0f5db => {
            vlineMiddle(metrics, canvas, .light);
            try arc(metrics, canvas, .br, .light);
        },
        0x0f5dc => {
            try arc(metrics, canvas, .tr, .light);
            try arc(metrics, canvas, .br, .light);
        },
        0x0f5dd => {
            vlineMiddle(metrics, canvas, .light);
            try arc(metrics, canvas, .tl, .light);
        },
        0x0f5de => {
            vlineMiddle(metrics, canvas, .light);
            try arc(metrics, canvas, .bl, .light);
        },
        0x0f5df => {
            try arc(metrics, canvas, .tl, .light);
            try arc(metrics, canvas, .bl, .light);
        },
        0x0f5e0 => {
            try arc(metrics, canvas, .bl, .light);
            hlineMiddle(metrics, canvas, .light);
        },
        0x0f5e1 => {
            try arc(metrics, canvas, .br, .light);
            hlineMiddle(metrics, canvas, .light);
        },
        0x0f5e2 => {
            try arc(metrics, canvas, .br, .light);
            try arc(metrics, canvas, .bl, .light);
        },
        0x0f5e3 => {
            try arc(metrics, canvas, .tl, .light);
            hlineMiddle(metrics, canvas, .light);
        },
        0x0f5e4 => {
            try arc(metrics, canvas, .tr, .light);
            hlineMiddle(metrics, canvas, .light);
        },
        0x0f5e5 => {
            try arc(metrics, canvas, .tr, .light);
            try arc(metrics, canvas, .tl, .light);
        },
        0x0f5e6 => {
            vlineMiddle(metrics, canvas, .light);
            try arc(metrics, canvas, .tl, .light);
            try arc(metrics, canvas, .tr, .light);
        },
        0x0f5e7 => {
            vlineMiddle(metrics, canvas, .light);
            try arc(metrics, canvas, .bl, .light);
            try arc(metrics, canvas, .br, .light);
        },
        0x0f5e8 => {
            hlineMiddle(metrics, canvas, .light);
            try arc(metrics, canvas, .bl, .light);
            try arc(metrics, canvas, .tl, .light);
        },
        0x0f5e9 => {
            hlineMiddle(metrics, canvas, .light);
            try arc(metrics, canvas, .tr, .light);
            try arc(metrics, canvas, .br, .light);
        },
        0x0f5ea => {
            vlineMiddle(metrics, canvas, .light);
            try arc(metrics, canvas, .tl, .light);
            try arc(metrics, canvas, .br, .light);
        },
        0x0f5eb => {
            vlineMiddle(metrics, canvas, .light);
            try arc(metrics, canvas, .tr, .light);
            try arc(metrics, canvas, .bl, .light);
        },
        0x0f5ec => {
            hlineMiddle(metrics, canvas, .light);
            try arc(metrics, canvas, .tl, .light);
            try arc(metrics, canvas, .br, .light);
        },
        0x0f5ed => {
            hlineMiddle(metrics, canvas, .light);
            try arc(metrics, canvas, .tr, .light);
            try arc(metrics, canvas, .bl, .light);
        },
        0x0f5ee => branchNode(metrics, canvas, .{ .filled = true }, .light),
        0x0f5ef => branchNode(metrics, canvas, .{}, .light),
        0x0f5f0 => branchNode(metrics, canvas, .{
            .right = true,
            .filled = true,
        }, .light),
        0x0f5f1 => branchNode(metrics, canvas, .{
            .right = true,
        }, .light),
        0x0f5f2 => branchNode(metrics, canvas, .{
            .left = true,
            .filled = true,
        }, .light),
        0x0f5f3 => branchNode(metrics, canvas, .{
            .left = true,
        }, .light),
        0x0f5f4 => branchNode(metrics, canvas, .{
            .left = true,
            .right = true,
            .filled = true,
        }, .light),
        0x0f5f5 => branchNode(metrics, canvas, .{
            .left = true,
            .right = true,
        }, .light),
        0x0f5f6 => branchNode(metrics, canvas, .{
            .down = true,
            .filled = true,
        }, .light),
        0x0f5f7 => branchNode(metrics, canvas, .{
            .down = true,
        }, .light),
        0x0f5f8 => branchNode(metrics, canvas, .{
            .up = true,
            .filled = true,
        }, .light),
        0x0f5f9 => branchNode(metrics, canvas, .{
            .up = true,
        }, .light),
        0x0f5fa => branchNode(metrics, canvas, .{
            .up = true,
            .down = true,
            .filled = true,
        }, .light),
        0x0f5fb => branchNode(metrics, canvas, .{
            .up = true,
            .down = true,
        }, .light),
        0x0f5fc => branchNode(metrics, canvas, .{
            .right = true,
            .down = true,
            .filled = true,
        }, .light),
        0x0f5fd => branchNode(metrics, canvas, .{
            .right = true,
            .down = true,
        }, .light),
        0x0f5fe => branchNode(metrics, canvas, .{
            .left = true,
            .down = true,
            .filled = true,
        }, .light),
        0x0f5ff => branchNode(metrics, canvas, .{
            .left = true,
            .down = true,
        }, .light),
        0x0f600 => branchNode(metrics, canvas, .{
            .up = true,
            .right = true,
            .filled = true,
        }, .light),
        0x0f601 => branchNode(metrics, canvas, .{
            .up = true,
            .right = true,
        }, .light),
        0x0f602 => branchNode(metrics, canvas, .{
            .up = true,
            .left = true,
            .filled = true,
        }, .light),
        0x0f603 => branchNode(metrics, canvas, .{
            .up = true,
            .left = true,
        }, .light),
        0x0f604 => branchNode(metrics, canvas, .{
            .up = true,
            .down = true,
            .right = true,
            .filled = true,
        }, .light),
        0x0f605 => branchNode(metrics, canvas, .{
            .up = true,
            .down = true,
            .right = true,
        }, .light),
        0x0f606 => branchNode(metrics, canvas, .{
            .up = true,
            .down = true,
            .left = true,
            .filled = true,
        }, .light),
        0x0f607 => branchNode(metrics, canvas, .{
            .up = true,
            .down = true,
            .left = true,
        }, .light),
        0x0f608 => branchNode(metrics, canvas, .{
            .down = true,
            .left = true,
            .right = true,
            .filled = true,
        }, .light),
        0x0f609 => branchNode(metrics, canvas, .{
            .down = true,
            .left = true,
            .right = true,
        }, .light),
        0x0f60a => branchNode(metrics, canvas, .{
            .up = true,
            .left = true,
            .right = true,
            .filled = true,
        }, .light),
        0x0f60b => branchNode(metrics, canvas, .{
            .up = true,
            .left = true,
            .right = true,
        }, .light),
        0x0f60c => branchNode(metrics, canvas, .{
            .up = true,
            .down = true,
            .left = true,
            .right = true,
            .filled = true,
        }, .light),
        0x0f60d => branchNode(metrics, canvas, .{
            .up = true,
            .down = true,
            .left = true,
            .right = true,
        }, .light),
        else => unreachable,
    }
}
fn branchNode(
    metrics: font.Metrics,
    canvas: *font.sprite.Canvas,
    node: BranchNode,
    comptime thickness: Thickness,
) void {
    const thick_px = thickness.height(metrics.box_thickness);
    const float_width: f64 = @floatFromInt(metrics.cell_width);
    const float_height: f64 = @floatFromInt(metrics.cell_height);
    const float_thick: f64 = @floatFromInt(thick_px);
    const h_top = (metrics.cell_height -| thick_px) / 2;
    const h_bottom = h_top +| thick_px;
    const v_left = (metrics.cell_width -| thick_px) / 2;
    const v_right = v_left +| thick_px;
    const cx: f64 = @as(f64, @floatFromInt(v_left)) + float_thick / 2;
    const cy: f64 = @as(f64, @floatFromInt(h_top)) + float_thick / 2;
    const r: f64 = @min(
        @min(cx, cy),
        @min(float_width - cx, float_height - cy),
    );
    var ctx = canvas.getContext();
    defer ctx.deinit();
    ctx.setSource(.{ .opaque_pattern = .{
        .pixel = .{ .alpha8 = .{ .a = @intFromEnum(Shade.on) } },
    } });
    ctx.setLineWidth(float_thick);
    if (node.up) canvas.box(
        @intCast(v_left),
        0,
        @intCast(v_right),
        @intFromFloat(@ceil(cy - r + float_thick / 2)),
        .on,
    );
    if (node.right) canvas.box(
        @intFromFloat(@floor(cx + r - float_thick / 2)),
        @intCast(h_top),
        @intCast(metrics.cell_width),
        @intCast(h_bottom),
        .on,
    );
    if (node.down) canvas.box(
        @intCast(v_left),
        @intFromFloat(@floor(cy + r - float_thick / 2)),
        @intCast(v_right),
        @intCast(metrics.cell_height),
        .on,
    );
    if (node.left) canvas.box(
        0,
        @intCast(h_top),
        @intFromFloat(@ceil(cx - r + float_thick / 2)),
        @intCast(h_bottom),
        .on,
    );
    if (node.filled) {
        ctx.arc(cx, cy, r, 0, std.math.pi * 2) catch return;
        ctx.closePath() catch return;
        ctx.fill() catch return;
    } else {
        ctx.arc(cx, cy, r - float_thick / 2, 0, std.math.pi * 2) catch return;
        ctx.closePath() catch return;
        ctx.stroke() catch return;
    }
}
fn fadingLine(
    metrics: font.Metrics,
    canvas: *font.sprite.Canvas,
    comptime to: Edge,
    comptime thickness: Thickness,
) void {
    const thick_px = thickness.height(metrics.box_thickness);
    const float_width: f64 = @floatFromInt(metrics.cell_width);
    const float_height: f64 = @floatFromInt(metrics.cell_height);
    const h_top = (metrics.cell_height -| thick_px) / 2;
    const h_bottom = h_top +| thick_px;
    const v_left = (metrics.cell_width -| thick_px) / 2;
    const v_right = v_left +| thick_px;
    var color: f64 = switch (to) {
        .top, .left => 0.0,
        .bottom, .right => 255.0,
    };
    const inc: f64 = 255.0 / switch (to) {
        .top => float_height,
        .bottom => -float_height,
        .left => float_width,
        .right => -float_width,
    };
    switch (to) {
        .top, .bottom => {
            for (0..metrics.cell_height) |y| {
                for (v_left..v_right) |x| {
                    canvas.pixel(
                        @intCast(x),
                        @intCast(y),
                        @enumFromInt(@as(u8, @intFromFloat(@round(color)))),
                    );
                }
                color += inc;
            }
        },
        .left, .right => {
            for (0..metrics.cell_width) |x| {
                for (h_top..h_bottom) |y| {
                    canvas.pixel(
                        @intCast(x),
                        @intCast(y),
                        @enumFromInt(@as(u8, @intFromFloat(@round(color)))),
                    );
                }
                color += inc;
            }
        },
    }
}
