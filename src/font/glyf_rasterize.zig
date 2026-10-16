const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const z2d = @import("z2d");
const Glyph = @import("Glyph.zig");
const glyf = @import("opentype/glyf.zig");
const DesignMetrics = Glyph.DesignMetrics;
pub const Bitmap = struct {
    width: u32,
    height: u32,
    data: []u8,
    pub const empty: Bitmap = .{ .width = 0, .height = 0, .data = "" };
    pub fn initEmpty(alloc: Allocator, width: u32, height: u32) Allocator.Error!Bitmap {
        const data = try alloc.alloc(u8, @as(usize, width) * @as(usize, height));
        @memset(data, 0);
        return .{ .width = width, .height = height, .data = data };
    }
    pub fn deinit(self: *Bitmap, alloc: Allocator) void {
        alloc.free(self.data);
        self.* = undefined;
    }
};
pub const Error = Allocator.Error || z2d.Path.Error || z2d.painter.FillError;
pub fn rasterize(
    alloc: Allocator,
    outline: glyf.Glyf.Outline,
    design: DesignMetrics,
    opts: Glyph.RenderOptions,
) Error!Bitmap {
    assert(design.units_per_em > 0);
    assert(design.advance_width > 0);
    assert(design.line_height > 0);
    const width: u32 = std.math.mul(
        u32,
        opts.grid_metrics.cell_width,
        opts.cell_width orelse 1,
    ) catch std.math.maxInt(u32);
    const height = opts.grid_metrics.cell_height;
    assert(width > 0 and height > 0);
    if (outline.contours.len == 0 or outline.points.len == 0) return Bitmap.initEmpty(alloc, width, height);
    const bounds: Bounds = bounds: {
        var bounds: Bounds = .{
            .x_min = @floatFromInt(outline.points[0].x),
            .y_min = @floatFromInt(outline.points[0].y),
            .x_max = @floatFromInt(outline.points[0].x),
            .y_max = @floatFromInt(outline.points[0].y),
        };
        for (outline.points[1..]) |p| {
            const x: f64 = @floatFromInt(p.x);
            const y: f64 = @floatFromInt(p.y);
            bounds.x_min = @min(bounds.x_min, x);
            bounds.y_min = @min(bounds.y_min, y);
            bounds.x_max = @max(bounds.x_max, x);
            bounds.y_max = @max(bounds.y_max, y);
        }
        break :bounds bounds;
    };
    if (bounds.width() == 0 or bounds.height() == 0) return Bitmap.initEmpty(alloc, width, height);
    const data = try alloc.alloc(u8, @as(usize, width) * @as(usize, height));
    errdefer alloc.free(data);
    var sfc: z2d.Surface = .initBuffer(
        .image_surface_alpha8,
        null,
        std.mem.bytesAsSlice(z2d.pixel.Alpha8, data),
        @intCast(width),
        @intCast(height),
    );
    var path: z2d.Path = .empty;
    defer path.deinit(alloc);
    const placement: Placement = .init(bounds, design, opts);
    for (0..outline.contours.len) |i| try appendContourPath(
        alloc,
        &path,
        outline.contour(i),
        bounds,
        placement,
    );
    try z2d.painter.fill(
        alloc,
        &sfc,
        &.{ .opaque_pattern = .{
            .pixel = .{ .alpha8 = .{ .a = 255 } },
        } },
        path.nodes.items,
        .{},
    );
    return .{
        .width = width,
        .height = height,
        .data = data,
    };
}
const Bounds = struct {
    x_min: f64,
    y_min: f64,
    x_max: f64,
    y_max: f64,
    fn width(self: Bounds) f64 {
        return self.x_max - self.x_min;
    }
    fn height(self: Bounds) f64 {
        return self.y_max - self.y_min;
    }
};
const Placement = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    bitmap_height: f64,
    fn init(
        bounds: Bounds,
        design: DesignMetrics,
        opts: Glyph.RenderOptions,
    ) Placement {
        const scale = @as(f64, @floatFromInt(opts.grid_metrics.cell_height)) /
            @as(f64, @floatFromInt(design.units_per_em));
        const glyph: Glyph.Size = .{
            .width = bounds.width() * scale,
            .height = bounds.height() * scale,
            .x = bounds.x_min * scale,
            .y = bounds.y_min * scale,
        };
        const group_width = @as(f64, @floatFromInt(design.advance_width)) * scale;
        const group_height = @as(f64, @floatFromInt(design.line_height)) * scale;
        const constraint: Glyph.RenderOptions.Constraint = constraint: {
            var constraint = opts.constraint;
            if (group_width > 0 and group_height > 0) {
                constraint.relative_width = glyph.width / group_width;
                constraint.relative_height = glyph.height / group_height;
                constraint.relative_x = glyph.x / group_width;
                constraint.relative_y = glyph.y / group_height;
            }
            break :constraint constraint;
        };
        const constrained = constraint.constrain(
            glyph,
            opts.grid_metrics,
            opts.constraint_width,
        );
        return .{
            .x = constrained.x,
            .y = constrained.y,
            .width = constrained.width,
            .height = constrained.height,
            .bitmap_height = @floatFromInt(opts.grid_metrics.cell_height),
        };
    }
};
const Point = struct {
    x: f64,
    y: f64,
};
fn appendContourPath(
    alloc: Allocator,
    path: *z2d.Path,
    contour: []const glyf.Glyf.Outline.Point,
    bounds: Bounds,
    placement: Placement,
) Error!void {
    if (contour.len == 0) return;
    const first = contour[0];
    const last = contour[contour.len - 1];
    var current: Point = undefined;
    var i: usize = 0;
    if (first.on_curve) {
        i = 1;
        current = transformPoint(
            first,
            bounds,
            placement,
        );
    } else if (last.on_curve) {
        current = transformPoint(
            last,
            bounds,
            placement,
        );
    } else {
        current = midpoint(
            transformPoint(last, bounds, placement),
            transformPoint(first, bounds, placement),
        );
    }
    try path.moveTo(alloc, current.x, current.y);
    while (i < contour.len) {
        const p = contour[i];
        if (p.on_curve) {
            current = transformPoint(p, bounds, placement);
            try path.lineTo(alloc, current.x, current.y);
            i += 1;
            continue;
        }
        const control = transformPoint(p, bounds, placement);
        const next = contour[(i + 1) % contour.len];
        const end = if (next.on_curve) transformPoint(
            next,
            bounds,
            placement,
        ) else midpoint(
            control,
            transformPoint(next, bounds, placement),
        );
        const c1 = Point{
            .x = current.x + ((2.0 / 3.0) * (control.x - current.x)),
            .y = current.y + ((2.0 / 3.0) * (control.y - current.y)),
        };
        const c2 = Point{
            .x = end.x + ((2.0 / 3.0) * (control.x - end.x)),
            .y = end.y + ((2.0 / 3.0) * (control.y - end.y)),
        };
        try path.curveTo(
            alloc,
            c1.x,
            c1.y,
            c2.x,
            c2.y,
            end.x,
            end.y,
        );
        current = end;
        i += if (next.on_curve) 2 else 1;
    }
    try path.close(alloc);
}
fn transformPoint(
    p: glyf.Glyf.Outline.Point,
    bounds: Bounds,
    placement: Placement,
) Point {
    const scale_x = placement.width / bounds.width();
    const scale_y = placement.height / bounds.height();
    const x_design: f64 = @floatFromInt(p.x);
    const y_design: f64 = @floatFromInt(p.y);
    return .{
        .x = placement.x + ((x_design - bounds.x_min) * scale_x),
        .y = placement.bitmap_height - placement.y -
            ((y_design - bounds.y_min) * scale_y),
    };
}
fn midpoint(a: Point, b: Point) Point {
    return .{
        .x = (a.x + b.x) / 2.0,
        .y = (a.y + b.y) / 2.0,
    };
}
fn testMetrics(width: u32, height: u32) @import("Metrics.zig") {
    return .{
        .cell_width = width,
        .cell_height = height,
        .cell_baseline = 0,
        .underline_position = height,
        .underline_thickness = 1,
        .strikethrough_position = height / 2,
        .strikethrough_thickness = 1,
        .overline_position = 0,
        .overline_thickness = 1,
        .box_thickness = 1,
        .cursor_thickness = 1,
        .cursor_height = height,
        .icon_height = @floatFromInt(height),
        .icon_height_single = @floatFromInt(height),
        .face_width = @floatFromInt(width),
        .face_height = @floatFromInt(height),
        .face_y = 0,
    };
}
test {
    _ = @import("glyf_rasterize_png_test.zig");
}
test "glyf_rasterize: empty outline returns empty bitmap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var bm = try rasterize(alloc, .{ .points = &.{}, .contours = &.{} }, .{
        .units_per_em = 1000,
        .advance_width = 1000,
        .line_height = 1000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
    });
    defer bm.deinit(alloc);
    try testing.expectEqual(@as(u32, 20), bm.width);
    try testing.expectEqual(@as(u32, 20), bm.height);
    try testing.expectEqual(@as(usize, 20 * 20), bm.data.len);
    for (bm.data) |v| try testing.expectEqual(@as(u8, 0), v);
}
test "glyf_rasterize: square fills bitmap center" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const outline: glyf.Glyf.Outline = .{
        .points = &.{
            .{ .x = 0, .y = 0, .on_curve = true },
            .{ .x = 1000, .y = 0, .on_curve = true },
            .{ .x = 1000, .y = 1000, .on_curve = true },
            .{ .x = 0, .y = 1000, .on_curve = true },
        },
        .contours = &.{3},
    };
    var bm = try rasterize(alloc, outline, .{
        .units_per_em = 1000,
        .advance_width = 1000,
        .line_height = 1000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
    });
    defer bm.deinit(alloc);
    try testing.expect(bm.data[10 * bm.width + 10] > 200);
}
test "glyf_rasterize: quadratic contour renders" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const outline: glyf.Glyf.Outline = .{
        .points = &.{
            .{ .x = 0, .y = 0, .on_curve = true },
            .{ .x = 500, .y = 1000, .on_curve = false },
            .{ .x = 1000, .y = 0, .on_curve = true },
        },
        .contours = &.{2},
    };
    var bm = try rasterize(alloc, outline, .{
        .units_per_em = 1000,
        .advance_width = 1000,
        .line_height = 1000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
    });
    defer bm.deinit(alloc);
    var nonzero = false;
    for (bm.data) |v| nonzero = nonzero or v != 0;
    try testing.expect(nonzero);
}
test "glyf_rasterize: consecutive off-curve points render" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const outline: glyf.Glyf.Outline = .{
        .points = &.{
            .{ .x = 0, .y = 0, .on_curve = true },
            .{ .x = 250, .y = 1000, .on_curve = false },
            .{ .x = 750, .y = 1000, .on_curve = false },
            .{ .x = 1000, .y = 0, .on_curve = true },
        },
        .contours = &.{3},
    };
    var bm = try rasterize(alloc, outline, .{
        .units_per_em = 1000,
        .advance_width = 1000,
        .line_height = 1000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
    });
    defer bm.deinit(alloc);
    var nonzero = false;
    for (bm.data) |v| nonzero = nonzero or v != 0;
    try testing.expect(nonzero);
}
test "glyf_rasterize: units per em controls baseline scale" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const outline: glyf.Glyf.Outline = .{
        .points = &.{
            .{ .x = 0, .y = 0, .on_curve = true },
            .{ .x = 1000, .y = 0, .on_curve = true },
            .{ .x = 1000, .y = 1000, .on_curve = true },
            .{ .x = 0, .y = 1000, .on_curve = true },
        },
        .contours = &.{3},
    };
    var bm = try rasterize(alloc, outline, .{
        .units_per_em = 2000,
        .advance_width = 1000,
        .line_height = 1000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
    });
    defer bm.deinit(alloc);
    try testing.expect(bm.data[15 * bm.width + 5] > 200);
    try testing.expectEqual(@as(u8, 0), bm.data[5 * bm.width + 5]);
}
test "glyf_rasterize: degenerate outline returns full empty bitmap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const outline: glyf.Glyf.Outline = .{
        .points = &.{
            .{ .x = 0, .y = 0, .on_curve = true },
            .{ .x = 1000, .y = 0, .on_curve = true },
            .{ .x = 500, .y = 0, .on_curve = true },
        },
        .contours = &.{2},
    };
    var bm = try rasterize(alloc, outline, .{
        .units_per_em = 1000,
        .advance_width = 1000,
        .line_height = 1000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
    });
    defer bm.deinit(alloc);
    try testing.expectEqual(@as(u32, 20), bm.width);
    try testing.expectEqual(@as(u32, 20), bm.height);
    try testing.expectEqual(@as(usize, 20 * 20), bm.data.len);
    for (bm.data) |v| try testing.expectEqual(@as(u8, 0), v);
}
test "glyf_rasterize: contour can start off curve with final on curve point" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const outline: glyf.Glyf.Outline = .{
        .points = &.{
            .{ .x = 500, .y = 1000, .on_curve = false },
            .{ .x = 1000, .y = 0, .on_curve = true },
            .{ .x = 0, .y = 0, .on_curve = true },
        },
        .contours = &.{2},
    };
    var bm = try rasterize(alloc, outline, .{
        .units_per_em = 1000,
        .advance_width = 1000,
        .line_height = 1000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
    });
    defer bm.deinit(alloc);
    var nonzero = false;
    for (bm.data) |v| nonzero = nonzero or v != 0;
    try testing.expect(nonzero);
}
test "glyf_rasterize: contour can start with implied midpoint" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const outline: glyf.Glyf.Outline = .{
        .points = &.{
            .{ .x = 250, .y = 1000, .on_curve = false },
            .{ .x = 1000, .y = 0, .on_curve = true },
            .{ .x = 750, .y = 1000, .on_curve = false },
            .{ .x = 0, .y = 0, .on_curve = true },
        },
        .contours = &.{3},
    };
    var bm = try rasterize(alloc, outline, .{
        .units_per_em = 1000,
        .advance_width = 1000,
        .line_height = 1000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
    });
    defer bm.deinit(alloc);
    var nonzero = false;
    for (bm.data) |v| nonzero = nonzero or v != 0;
    try testing.expect(nonzero);
}
test "glyf_rasterize: multiple contours render independently" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const outline: glyf.Glyf.Outline = .{
        .points = &.{
            .{ .x = 0, .y = 0, .on_curve = true },
            .{ .x = 400, .y = 0, .on_curve = true },
            .{ .x = 400, .y = 400, .on_curve = true },
            .{ .x = 0, .y = 400, .on_curve = true },
            .{ .x = 600, .y = 600, .on_curve = true },
            .{ .x = 1000, .y = 600, .on_curve = true },
            .{ .x = 1000, .y = 1000, .on_curve = true },
            .{ .x = 600, .y = 1000, .on_curve = true },
        },
        .contours = &.{ 3, 7 },
    };
    var bm = try rasterize(alloc, outline, .{
        .units_per_em = 1000,
        .advance_width = 1000,
        .line_height = 1000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
    });
    defer bm.deinit(alloc);
    try testing.expect(bm.data[16 * bm.width + 4] > 200);
    try testing.expect(bm.data[4 * bm.width + 16] > 200);
    try testing.expectEqual(@as(u8, 0), bm.data[10 * bm.width + 10]);
}
test "glyf_rasterize: non-zero bearings preserve declared whitespace" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const outline: glyf.Glyf.Outline = .{
        .points = &.{
            .{ .x = 250, .y = 0, .on_curve = true },
            .{ .x = 750, .y = 0, .on_curve = true },
            .{ .x = 750, .y = 1000, .on_curve = true },
            .{ .x = 250, .y = 1000, .on_curve = true },
        },
        .contours = &.{3},
    };
    var bm = try rasterize(alloc, outline, .{
        .units_per_em = 1000,
        .advance_width = 1000,
        .line_height = 1000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
    });
    defer bm.deinit(alloc);
    try testing.expectEqual(@as(u8, 0), bm.data[10 * bm.width + 2]);
    try testing.expect(bm.data[10 * bm.width + 10] > 200);
    try testing.expectEqual(@as(u8, 0), bm.data[10 * bm.width + 17]);
}
test "glyf_rasterize: negative y coordinates descend below baseline" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const outline: glyf.Glyf.Outline = .{
        .points = &.{
            .{ .x = 0, .y = -250, .on_curve = true },
            .{ .x = 1000, .y = -250, .on_curve = true },
            .{ .x = 1000, .y = 750, .on_curve = true },
            .{ .x = 0, .y = 750, .on_curve = true },
        },
        .contours = &.{3},
    };
    var bm = try rasterize(alloc, outline, .{
        .units_per_em = 1000,
        .advance_width = 1000,
        .line_height = 1000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
    });
    defer bm.deinit(alloc);
    try testing.expectEqual(@as(u8, 0), bm.data[2 * bm.width + 10]);
    try testing.expect(bm.data[10 * bm.width + 10] > 200);
    try testing.expect(bm.data[18 * bm.width + 10] > 200);
}
test "glyf_rasterize: two-cell bitmap and constraint render within width" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const outline: glyf.Glyf.Outline = .{
        .points = &.{
            .{ .x = 0, .y = 0, .on_curve = true },
            .{ .x = 1000, .y = 0, .on_curve = true },
            .{ .x = 1000, .y = 1000, .on_curve = true },
            .{ .x = 0, .y = 1000, .on_curve = true },
        },
        .contours = &.{3},
    };
    var bm = try rasterize(alloc, outline, .{
        .units_per_em = 1000,
        .advance_width = 1000,
        .line_height = 1000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
        .cell_width = 2,
        .constraint_width = 2,
        .constraint = .{
            .size = .cover,
            .align_horizontal = .center,
            .align_vertical = .center,
        },
    });
    defer bm.deinit(alloc);
    try testing.expectEqual(@as(u32, 40), bm.width);
    try testing.expectEqual(@as(u32, 20), bm.height);
    try testing.expectEqual(@as(u8, 0), bm.data[10 * bm.width + 2]);
    try testing.expect(bm.data[10 * bm.width + 20] > 200);
    try testing.expectEqual(@as(u8, 0), bm.data[10 * bm.width + 37]);
}
test "glyf_rasterize: line height does not change unconstrained em scale" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const outline: glyf.Glyf.Outline = .{
        .points = &.{
            .{ .x = 0, .y = 0, .on_curve = true },
            .{ .x = 1000, .y = 0, .on_curve = true },
            .{ .x = 1000, .y = 1000, .on_curve = true },
            .{ .x = 0, .y = 1000, .on_curve = true },
        },
        .contours = &.{3},
    };
    var bm = try rasterize(alloc, outline, .{
        .units_per_em = 1000,
        .advance_width = 1000,
        .line_height = 2000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
    });
    defer bm.deinit(alloc);
    try testing.expect(bm.data[10 * bm.width + 10] > 200);
    try testing.expect(bm.data[2 * bm.width + 10] > 200);
    try testing.expect(bm.data[17 * bm.width + 10] > 200);
}
