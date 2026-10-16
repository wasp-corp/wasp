const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const z2d = @import("z2d");
const font = @import("../main.zig");
const global = @import("../../global.zig");
pub fn Point(comptime T: type) type {
    return struct {
        x: T,
        y: T,
    };
}
pub fn Line(comptime T: type) type {
    return struct {
        p0: Point(T),
        p1: Point(T),
    };
}
pub fn Box(comptime T: type) type {
    return struct {
        p0: Point(T),
        p1: Point(T),
        pub fn rect(self: Box(T)) Rect(T) {
            const tl_x = @min(self.p0.x, self.p1.x);
            const tl_y = @min(self.p0.y, self.p1.y);
            const br_x = @max(self.p0.x, self.p1.x);
            const br_y = @max(self.p0.y, self.p1.y);
            return .{
                .x = tl_x,
                .y = tl_y,
                .width = br_x - tl_x,
                .height = br_y - tl_y,
            };
        }
    };
}
pub fn Rect(comptime T: type) type {
    return struct {
        x: T,
        y: T,
        width: T,
        height: T,
    };
}
pub fn Triangle(comptime T: type) type {
    return struct {
        p0: Point(T),
        p1: Point(T),
        p2: Point(T),
    };
}
pub fn Quad(comptime T: type) type {
    return struct {
        p0: Point(T),
        p1: Point(T),
        p2: Point(T),
        p3: Point(T),
    };
}
pub const Color = enum(u8) {
    on = 255,
    off = 0,
    _,
};
pub const Canvas = struct {
    sfc: z2d.Surface,
    padding_x: u32,
    padding_y: u32,
    clip_top: u32 = 0,
    clip_left: u32 = 0,
    clip_right: u32 = 0,
    clip_bottom: u32 = 0,
    alloc: Allocator,
    pub fn init(
        alloc: Allocator,
        width: u32,
        height: u32,
        padding_x: u32,
        padding_y: u32,
    ) !Canvas {
        const sfc = try z2d.Surface.initPixel(
            .{ .alpha8 = .{ .a = 0 } },
            alloc,
            @intCast(width + 2 * padding_x),
            @intCast(height + 2 * padding_y),
        );
        errdefer sfc.deinit(alloc);
        return .{
            .sfc = sfc,
            .padding_x = padding_x,
            .padding_y = padding_y,
            .alloc = alloc,
        };
    }
    pub fn deinit(self: *Canvas) void {
        self.sfc.deinit(self.alloc);
        self.* = undefined;
    }
    pub fn writeAtlas(
        self: *Canvas,
        alloc: Allocator,
        atlas: *font.Atlas,
    ) (Allocator.Error || font.Atlas.Error)!font.Atlas.Region {
        assert(atlas.format == .grayscale);
        self.trim();
        const sfc_width: u32 = @intCast(self.sfc.getWidth());
        const sfc_height: u32 = @intCast(self.sfc.getHeight());
        const region_width = sfc_width -| self.clip_left -| self.clip_right;
        const region_height = sfc_height -| self.clip_top -| self.clip_bottom;
        const region = try atlas.reserve(alloc, region_width, region_height);
        if (region.width > 0 and region.height > 0) {
            const buffer: []u8 = @ptrCast(self.sfc.image_surface_alpha8.buf);
            assert(region.width == region_width);
            assert(region.height == region_height);
            atlas.setFromLarger(
                region,
                buffer,
                sfc_width,
                self.clip_left,
                self.clip_top,
            );
        }
        return region;
    }
    fn trim(self: *Canvas) void {
        const width: u32 = @intCast(self.sfc.getWidth());
        const height: u32 = @intCast(self.sfc.getHeight());
        const buf = std.mem.sliceAsBytes(self.sfc.image_surface_alpha8.buf);
        top: while (self.clip_top < height - self.clip_bottom) {
            const y = self.clip_top;
            const x0 = self.clip_left;
            const x1 = width - self.clip_right;
            for (buf[y * width ..][x0..x1]) |v| {
                if (v != 0) break :top;
            }
            self.clip_top += 1;
        }
        bottom: while (self.clip_bottom < height - self.clip_top) {
            const y = height - self.clip_bottom -| 1;
            const x0 = self.clip_left;
            const x1 = width - self.clip_right;
            for (buf[y * width ..][x0..x1]) |v| {
                if (v != 0) break :bottom;
            }
            self.clip_bottom += 1;
        }
        left: while (self.clip_left < width - self.clip_right) {
            const x = self.clip_left;
            const y0 = self.clip_top;
            const y1 = height - self.clip_bottom;
            for (y0..y1) |y| {
                if (buf[y * width + x] != 0) break :left;
            }
            self.clip_left += 1;
        }
        right: while (self.clip_right < width - self.clip_left) {
            const x = width - self.clip_right -| 1;
            const y0 = self.clip_top;
            const y1 = height - self.clip_bottom;
            for (y0..y1) |y| {
                if (buf[y * width + x] != 0) break :right;
            }
            self.clip_right += 1;
        }
    }
    pub fn clearClippingRegions(self: *Canvas) void {
        const buf = std.mem.sliceAsBytes(self.sfc.image_surface_alpha8.buf);
        const width: usize = @intCast(self.sfc.getWidth());
        const height: usize = @intCast(self.sfc.getHeight());
        for (0..height) |y| {
            for (0..self.clip_left) |x| {
                buf[y * width + x] = 0;
            }
        }
        for (0..height) |y| {
            for (width - self.clip_right..width) |x| {
                buf[y * width + x] = 0;
            }
        }
        for (0..self.clip_top) |y| {
            for (0..width) |x| {
                buf[y * width + x] = 0;
            }
        }
        for (height - self.clip_bottom..height) |y| {
            for (0..width) |x| {
                buf[y * width + x] = 0;
            }
        }
    }
    pub fn transformation(self: Canvas) z2d.Transformation {
        return .{
            .ax = 1,
            .by = 0,
            .cx = 0,
            .dy = 1,
            .tx = @as(f64, @floatFromInt(self.padding_x)),
            .ty = @as(f64, @floatFromInt(self.padding_y)),
        };
    }
    pub fn getContext(self: *Canvas) z2d.Context {
        var ctx = z2d.Context.init(global.io(), self.alloc, &self.sfc);
        ctx.setTransformation(self.transformation());
        return ctx;
    }
    pub fn pixel(self: *Canvas, x: i32, y: i32, color: Color) void {
        self.sfc.putPixel(
            x + @as(i32, @intCast(self.padding_x)),
            y + @as(i32, @intCast(self.padding_y)),
            .{ .alpha8 = .{ .a = @intFromEnum(color) } },
        );
    }
    pub fn rect(self: *Canvas, v: Rect(i32), color: Color) void {
        var y = v.y;
        while (y < v.y + v.height) : (y += 1) {
            var x = v.x;
            while (x < v.x + v.width) : (x += 1) {
                self.pixel(
                    @intCast(x),
                    @intCast(y),
                    color,
                );
            }
        }
    }
    pub fn box(
        self: *Canvas,
        x0: i32,
        y0: i32,
        x1: i32,
        y1: i32,
        color: Color,
    ) void {
        self.rect((Box(i32){
            .p0 = .{ .x = x0, .y = y0 },
            .p1 = .{ .x = x1, .y = y1 },
        }).rect(), color);
    }
    pub fn quad(self: *Canvas, q: Quad(f64), color: Color) !void {
        var path = self.staticPath(6); 
        path.moveTo(q.p0.x, q.p0.y); 
        path.lineTo(q.p1.x, q.p1.y); 
        path.lineTo(q.p2.x, q.p2.y); 
        path.lineTo(q.p3.x, q.p3.y); 
        path.close(); 
        try self.fillPath(path.wrapped_path, .{}, color);
    }
    pub fn triangle(self: *Canvas, t: Triangle(f64), color: Color) !void {
        var path = self.staticPath(5); 
        path.moveTo(t.p0.x, t.p0.y); 
        path.lineTo(t.p1.x, t.p1.y); 
        path.lineTo(t.p2.x, t.p2.y); 
        path.close(); 
        try self.fillPath(path.wrapped_path, .{}, color);
    }
    pub fn line(
        self: *Canvas,
        l: Line(f64),
        thickness: f64,
        color: Color,
    ) !void {
        var path = self.staticPath(2); 
        path.moveTo(l.p0.x, l.p0.y); 
        path.lineTo(l.p1.x, l.p1.y); 
        try self.strokePath(
            path.wrapped_path,
            .{
                .line_cap_mode = .butt,
                .line_width = thickness,
            },
            color,
        );
    }
    pub inline fn staticPath(
        self: *Canvas,
        comptime len: usize,
    ) z2d.StaticPath(len) {
        var path: z2d.StaticPath(len) = .{};
        path.init();
        path.wrapped_path.transformation = self.transformation();
        return path;
    }
    pub fn strokePath(
        self: *Canvas,
        path: z2d.Path,
        opts: z2d.painter.StrokeOptions,
        color: Color,
    ) z2d.painter.StrokeError!void {
        try z2d.painter.stroke(
            self.alloc,
            &self.sfc,
            &.{ .opaque_pattern = .{
                .pixel = .{ .alpha8 = .{ .a = @intFromEnum(color) } },
            } },
            path.nodes.items,
            opts,
        );
    }
    pub fn innerStrokePath(
        self: *Canvas,
        path: z2d.Path,
        opts: z2d.painter.StrokeOptions,
        color: Color,
    ) (z2d.Path.OffsetError || z2d.painter.StrokeError)!void {
        var inset_path = try path.offset(self.alloc, -opts.line_width / 2.0);
        defer inset_path.deinit(self.alloc);
        return self.strokePath(inset_path, opts, color);
    }
    pub fn fillPath(
        self: *Canvas,
        path: z2d.Path,
        opts: z2d.painter.FillOptions,
        color: Color,
    ) z2d.painter.FillError!void {
        try z2d.painter.fill(
            self.alloc,
            &self.sfc,
            &.{ .opaque_pattern = .{
                .pixel = .{ .alpha8 = .{ .a = @intFromEnum(color) } },
            } },
            path.nodes.items,
            opts,
        );
    }
    pub fn invert(self: *Canvas) void {
        for (std.mem.sliceAsBytes(self.sfc.image_surface_alpha8.buf)) |*v| {
            v.* = 255 - v.*;
        }
    }
    pub fn flipHorizontal(self: *Canvas) Allocator.Error!void {
        const buf = std.mem.sliceAsBytes(self.sfc.image_surface_alpha8.buf);
        const clone = try self.alloc.dupe(u8, buf);
        defer self.alloc.free(clone);
        const width: usize = @intCast(self.sfc.getWidth());
        const height: usize = @intCast(self.sfc.getHeight());
        for (0..height) |y| {
            for (0..width) |x| {
                buf[y * width + x] = clone[y * width + width - x - 1];
            }
        }
        std.mem.swap(u32, &self.clip_left, &self.clip_right);
    }
    pub fn flipVertical(self: *Canvas) Allocator.Error!void {
        const buf = std.mem.sliceAsBytes(self.sfc.image_surface_alpha8.buf);
        const clone = try self.alloc.dupe(u8, buf);
        defer self.alloc.free(clone);
        const width: usize = @intCast(self.sfc.getWidth());
        const height: usize = @intCast(self.sfc.getHeight());
        for (0..height) |y| {
            for (0..width) |x| {
                buf[y * width + x] = clone[(height - y - 1) * width + x];
            }
        }
        std.mem.swap(u32, &self.clip_top, &self.clip_bottom);
    }
};
