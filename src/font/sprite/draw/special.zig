const std = @import("std");
const Allocator = std.mem.Allocator;
const font = @import("../../main.zig");
const Sprite = font.sprite.Sprite;
pub fn underline(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    const y = @min(
        metrics.underline_position,
        height +| canvas.padding_y -| metrics.underline_thickness,
    );
    canvas.rect(.{
        .x = 0,
        .y = @intCast(y),
        .width = @intCast(width),
        .height = @intCast(metrics.underline_thickness),
    }, .on);
}
pub fn underline_double(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    const y = @min(
        metrics.underline_position,
        height +| canvas.padding_y -| 2 * metrics.underline_thickness,
    );
    canvas.rect(.{
        .x = 0,
        .y = @intCast(y -| metrics.underline_thickness),
        .width = @intCast(width),
        .height = @intCast(metrics.underline_thickness),
    }, .on);
    canvas.rect(.{
        .x = 0,
        .y = @intCast(y +| metrics.underline_thickness),
        .width = @intCast(width),
        .height = @intCast(metrics.underline_thickness),
    }, .on);
}
pub fn underline_dotted(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    var ctx = canvas.getContext();
    defer ctx.deinit();
    const float_width: f64 = @floatFromInt(width);
    const float_height: f64 = @floatFromInt(height);
    const float_pos: f64 = @floatFromInt(metrics.underline_position);
    const float_thick: f64 = @floatFromInt(metrics.underline_thickness);
    const radius = std.math.sqrt1_2 * float_thick;
    const padding: f64 = @floatFromInt(canvas.padding_y);
    const y = @min(
        float_pos + 0.5 * float_thick,
        float_height + padding - @ceil(radius),
    );
    const dot_count: f64 = @max(
        @min(
            @ceil(float_width / (4 * radius)),
            @floor(float_width / (3 * radius)),
            @floor(float_width / (2 * radius + 1)),
        ),
        1.0,
    );
    var x: f64 = (float_width / dot_count) / 2;
    for (0..@as(usize, @intFromFloat(dot_count))) |_| {
        try ctx.arc(x, y, radius, 0.0, std.math.tau);
        try ctx.closePath();
        x += float_width / dot_count;
    }
    try ctx.fill();
}
pub fn underline_dashed(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    const y = @min(
        metrics.underline_position,
        height +| canvas.padding_y -| metrics.underline_thickness,
    );
    const dash_width = width / 3 + 1;
    const dash_count = (width / dash_width) + 1;
    var i: u32 = 0;
    while (i < dash_count) : (i += 2) {
        const x = i * dash_width;
        canvas.rect(.{
            .x = @intCast(x),
            .y = @intCast(y),
            .width = @intCast(dash_width),
            .height = @intCast(metrics.underline_thickness),
        }, .on);
    }
}
pub fn underline_curly(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    var ctx = canvas.getContext();
    defer ctx.deinit();
    const float_width: f64 = @floatFromInt(width);
    const float_height: f64 = @floatFromInt(height);
    const float_pos: f64 = @floatFromInt(metrics.underline_position);
    ctx.line_width = @floatFromInt(metrics.underline_thickness);
    ctx.line_cap_mode = .round;
    const amplitude = float_width / std.math.pi;
    const padding: f64 = @floatFromInt(canvas.padding_y);
    const top: f64 = @min(
        float_pos,
        float_height + padding - amplitude - ctx.line_width,
    );
    const bottom = top + amplitude;
    const r = 0.4;
    const center = 0.5 * float_width;
    try ctx.moveTo(0, bottom);
    try ctx.curveTo(
        center * r,
        bottom,
        center - center * r,
        top,
        center,
        top,
    );
    try ctx.curveTo(
        center + center * r,
        top,
        float_width - center * r,
        bottom,
        float_width,
        bottom,
    );
    try ctx.stroke();
}
pub fn strikethrough(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = height;
    canvas.rect(.{
        .x = 0,
        .y = @intCast(metrics.strikethrough_position),
        .width = @intCast(width),
        .height = @intCast(metrics.strikethrough_thickness),
    }, .on);
}
pub fn overline(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = height;
    const y = @max(
        metrics.overline_position,
        -@as(i32, @intCast(canvas.padding_y)),
    );
    canvas.rect(.{
        .x = 0,
        .y = y,
        .width = @intCast(width),
        .height = @intCast(metrics.overline_thickness),
    }, .on);
}
pub fn cursor_rect(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = metrics;
    canvas.rect(.{
        .x = 0,
        .y = 0,
        .width = @intCast(width),
        .height = @intCast(height),
    }, .on);
}
pub fn cursor_hollow_rect(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    canvas.rect(.{
        .x = 0,
        .y = 0,
        .width = @intCast(width),
        .height = @intCast(height),
    }, .on);
    canvas.rect(.{
        .x = @intCast(metrics.cursor_thickness),
        .y = @intCast(metrics.cursor_thickness),
        .width = @intCast(width -| metrics.cursor_thickness * 2),
        .height = @intCast(height -| metrics.cursor_thickness * 2),
    }, .off);
}
pub fn cursor_bar(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = width;
    canvas.rect(.{
        .x = -@as(i32, @intCast((metrics.cursor_thickness + 1) / 2)),
        .y = 0,
        .width = @intCast(metrics.cursor_thickness),
        .height = @intCast(height),
    }, .on);
}
pub fn cursor_underline(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    const y = @min(
        metrics.underline_position,
        height +| canvas.padding_y -| metrics.underline_thickness,
    );
    canvas.rect(.{
        .x = 0,
        .y = @intCast(y),
        .width = @intCast(width),
        .height = @intCast(metrics.cursor_thickness),
    }, .on);
}
