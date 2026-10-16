const Overlay = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const z2d = @import("z2d");
const terminal = @import("../terminal/main.zig");
const size = @import("size.zig");
const Size = size.Size;
const CellSize = size.CellSize;
const Image = @import("image.zig").Image;
const global = @import("../global.zig");
const log = std.log.scoped(.renderer_overlay);
pub const Color = enum {
    hyperlink, 
    semantic_prompt, 
    semantic_input, 
    pub fn rgb(self: Color) z2d.pixel.RGB {
        return switch (self) {
            .hyperlink => .{ .r = 180, .g = 180, .b = 255 },
            .semantic_prompt => .{ .r = 255, .g = 200, .b = 64 },
            .semantic_input => .{ .r = 64, .g = 200, .b = 255 },
        };
    }
    pub fn rectFill(self: Color) z2d.Pixel {
        return self.alphaPixel(96);
    }
    pub fn rectBorder(self: Color) z2d.Pixel {
        return self.alphaPixel(200);
    }
    pub fn pixel(self: Color) z2d.Pixel {
        return self.rgb().asPixel();
    }
    fn alphaPixel(self: Color, alpha: u8) z2d.Pixel {
        var rgba: z2d.pixel.RGBA = .fromPixel(self.pixel());
        rgba.a = alpha;
        return rgba.multiply().asPixel();
    }
};
surface: z2d.Surface,
cell_size: CellSize,
pub const Feature = union(enum) {
    highlight_hyperlinks,
    semantic_prompts,
};
pub const InitError = Allocator.Error || error{
    InvalidDimensions,
};
pub fn init(alloc: Allocator, sz: Size) InitError!Overlay {
    const term_size = sz.terminal();
    var sfc = z2d.Surface.initPixel(
        .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
        alloc,
        std.math.cast(i32, term_size.width) orelse
            return error.InvalidDimensions,
        std.math.cast(i32, term_size.height) orelse
            return error.InvalidDimensions,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWidth, error.InvalidHeight => return error.InvalidDimensions,
    };
    errdefer sfc.deinit(alloc);
    return .{
        .surface = sfc,
        .cell_size = sz.cell,
    };
}
pub fn deinit(self: *Overlay, alloc: Allocator) void {
    self.surface.deinit(alloc);
}
pub fn pendingImage(self: *const Overlay) Image.Pending {
    return .{
        .width = @intCast(self.surface.getWidth()),
        .height = @intCast(self.surface.getHeight()),
        .pixel_format = .rgba,
        .data = @ptrCast(self.surface.image_surface_rgba.buf.ptr),
    };
}
pub fn reset(self: *Overlay) void {
    self.surface.paintPixel(.{ .rgba = .{
        .r = 0,
        .g = 0,
        .b = 0,
        .a = 0,
    } });
}
pub fn applyFeatures(
    self: *Overlay,
    alloc: Allocator,
    state: *const terminal.RenderState,
    features: []const Feature,
) void {
    for (features) |f| switch (f) {
        .highlight_hyperlinks => self.highlightHyperlinks(
            alloc,
            state,
        ),
        .semantic_prompts => self.highlightSemanticPrompts(
            alloc,
            state,
        ),
    };
}
fn highlightHyperlinks(
    self: *Overlay,
    alloc: Allocator,
    state: *const terminal.RenderState,
) void {
    const border_color = Color.hyperlink.rectBorder();
    const fill_color = Color.hyperlink.rectFill();
    const row_slice = state.row_data.slice();
    const row_raw = row_slice.items(.raw);
    const row_cells = row_slice.items(.cells);
    for (row_raw, row_cells, 0..) |row, cells, y| {
        if (!row.hyperlink) continue;
        const cells_slice = cells.slice();
        const raw_cells = cells_slice.items(.raw);
        var x: usize = 0;
        while (x < raw_cells.len) {
            if (!raw_cells[x].hyperlink) {
                x += 1;
                continue;
            }
            const start_x = x;
            while (x < raw_cells.len and raw_cells[x].hyperlink) x += 1;
            const end_x = x;
            self.highlightGridRect(
                alloc,
                start_x,
                y,
                end_x - start_x,
                1,
                border_color,
                fill_color,
            ) catch |err| {
                std.log.warn("Error drawing hyperlink border: {}", .{err});
            };
        }
    }
}
fn highlightSemanticPrompts(
    self: *Overlay,
    alloc: Allocator,
    state: *const terminal.RenderState,
) void {
    const row_slice = state.row_data.slice();
    const row_raw = row_slice.items(.raw);
    const row_cells = row_slice.items(.cells);
    {
        const prompt_border = Color.semantic_prompt.rectBorder();
        const prompt_fill = Color.semantic_prompt.rectFill();
        var y: usize = 0;
        while (y < row_raw.len) {
            if (row_raw[y].semantic_prompt == .none) {
                y += 1;
                continue;
            }
            const start_y = y;
            y += 1;
            while (y < row_raw.len and
                row_raw[y].semantic_prompt == .prompt_continuation)
            {
                y += 1;
            }
            const end_y = y; 
            const bar_width = @min(@as(usize, 5), self.cell_size.width);
            self.highlightPixelRect(
                alloc,
                0,
                start_y,
                bar_width,
                end_y - start_y,
                prompt_border,
                prompt_fill,
            ) catch |err| {
                log.warn("Error drawing semantic prompt bar: {}", .{err});
            };
        }
    }
    for (row_cells, 0..) |cells, y| {
        const cells_slice = cells.slice();
        const raw_cells = cells_slice.items(.raw);
        var x: usize = 0;
        while (x < raw_cells.len) {
            const cell = raw_cells[x];
            const content = cell.semantic_content;
            const start_x = x;
            if (cell.semantic_content == .output) {
                x += 1;
                continue;
            }
            x += 1;
            while (x < raw_cells.len) {
                const next = raw_cells[x];
                if (next.semantic_content != content) break;
                x += 1;
            }
            const color: Color = switch (content) {
                .prompt => .semantic_prompt,
                .input => .semantic_input,
                .output => unreachable,
            };
            self.highlightGridRect(
                alloc,
                start_x,
                y,
                x - start_x,
                1,
                color.rectBorder(),
                color.rectFill(),
            ) catch |err| {
                log.warn("Error drawing semantic content highlight: {}", .{err});
            };
        }
    }
}
fn highlightGridRect(
    self: *Overlay,
    alloc: Allocator,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    border_color: z2d.Pixel,
    fill_color: z2d.Pixel,
) !void {
    const px_width = std.math.cast(i32, try std.math.mul(
        usize,
        width,
        self.cell_size.width,
    )) orelse return error.Overflow;
    const px_height = std.math.cast(i32, try std.math.mul(
        usize,
        height,
        self.cell_size.height,
    )) orelse return error.Overflow;
    const start_x: f64 = @floatFromInt(std.math.cast(i32, try std.math.mul(
        usize,
        x,
        self.cell_size.width,
    )) orelse return error.Overflow);
    const start_y: f64 = @floatFromInt(std.math.cast(i32, try std.math.mul(
        usize,
        y,
        self.cell_size.height,
    )) orelse return error.Overflow);
    const end_x: f64 = start_x + @as(f64, @floatFromInt(px_width));
    const end_y: f64 = start_y + @as(f64, @floatFromInt(px_height));
    var ctx: z2d.Context = .init(global.io(), alloc, &self.surface);
    defer ctx.deinit();
    ctx.setAntiAliasingMode(.none);
    ctx.setHairline(true);
    try ctx.moveTo(start_x, start_y);
    try ctx.lineTo(end_x, start_y);
    try ctx.lineTo(end_x, end_y);
    try ctx.lineTo(start_x, end_y);
    try ctx.closePath();
    ctx.setSourceToPixel(fill_color);
    try ctx.fill();
    ctx.setLineWidth(1);
    ctx.setSourceToPixel(border_color);
    try ctx.stroke();
}
fn highlightPixelRect(
    self: *Overlay,
    alloc: Allocator,
    x: usize,
    y: usize,
    width_px: usize,
    height: usize,
    border_color: z2d.Pixel,
    fill_color: z2d.Pixel,
) !void {
    const px_width = std.math.cast(i32, width_px) orelse return error.Overflow;
    const px_height = std.math.cast(i32, try std.math.mul(
        usize,
        height,
        self.cell_size.height,
    )) orelse return error.Overflow;
    const start_x: f64 = @floatFromInt(std.math.cast(i32, try std.math.mul(
        usize,
        x,
        self.cell_size.width,
    )) orelse return error.Overflow);
    const start_y: f64 = @floatFromInt(std.math.cast(i32, try std.math.mul(
        usize,
        y,
        self.cell_size.height,
    )) orelse return error.Overflow);
    const end_x: f64 = start_x + @as(f64, @floatFromInt(px_width));
    const end_y: f64 = start_y + @as(f64, @floatFromInt(px_height));
    var ctx: z2d.Context = .init(global.io(), alloc, &self.surface);
    defer ctx.deinit();
    ctx.setAntiAliasingMode(.none);
    ctx.setHairline(true);
    try ctx.moveTo(start_x, start_y);
    try ctx.lineTo(end_x, start_y);
    try ctx.lineTo(end_x, end_y);
    try ctx.lineTo(start_x, end_y);
    try ctx.closePath();
    ctx.setSourceToPixel(fill_color);
    try ctx.fill();
    ctx.setLineWidth(1);
    ctx.setSourceToPixel(border_color);
    try ctx.stroke();
}
