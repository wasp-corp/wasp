const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const testing = std.testing;
const terminal = @import("../main.zig");
const kitty_gfx = terminal.kitty.graphics;
const Image = kitty_gfx.Image;
const ImageStorage = kitty_gfx.ImageStorage;
const RenderPlacement = kitty_gfx.RenderPlacement;
const log = std.log.scoped(.kitty_gfx);
pub const placeholder: u21 = 0x10EEEE;
pub fn placementIterator(
    pin: terminal.Pin,
    limit: ?terminal.Pin,
) PlacementIterator {
    var row_it = pin.rowIterator(.right_down, limit);
    const row = row_it.next();
    return .{ .row_it = row_it, .row = row };
}
pub const PlacementIterator = struct {
    row_it: terminal.PageList.RowIterator,
    row: ?terminal.Pin,
    pub fn next(self: *PlacementIterator) ?Placement {
        while (self.row) |*row| {
            if (!row.rowAndCell().row.kitty_virtual_placeholder) {
                self.row = self.row_it.next();
                continue;
            }
            var run: ?IncompletePlacement = null;
            const cells = row.cells(.right);
            for (cells, row.x..) |*cell, x| {
                assert(@intFromPtr(row) == @intFromPtr(&self.row));
                row.x = @intCast(x);
                if (cell.codepoint() != placeholder) {
                    if (run) |prev| return prev.complete();
                    continue;
                }
                const curr = IncompletePlacement.init(row, cell);
                if (run) |*prev| {
                    if (!prev.append(&curr)) {
                        return prev.complete();
                    }
                } else {
                    var prev = curr;
                    if (prev.row == null) prev.row = 0;
                    if (prev.col == null) prev.col = 0;
                    run = prev;
                }
            }
            self.row = self.row_it.next();
            if (run) |prev| return prev.complete();
        }
        return null;
    }
};
pub const Placement = struct {
    pin: terminal.Pin,
    image_id: u32,
    placement_id: u32,
    col: u32,
    row: u32,
    width: u32,
    height: u32,
    pub const Error = error{
        PlacementGridOutOfBounds,
        PlacementMissingPlacement,
    };
    pub fn renderPlacement(
        self: *const Placement,
        storage: *const ImageStorage,
        img: *const Image,
        cell_width: u32,
        cell_height: u32,
    ) Error!RenderPlacement {
        const p_grid = try self.grid(storage, img, cell_width, cell_height);
        const img_width_f64: f64 = @floatFromInt(img.width);
        const img_height_f64: f64 = @floatFromInt(img.height);
        const p_scale: struct {
            x_offset: f64 = 0,
            y_offset: f64 = 0,
            x_scale: f64 = 0,
            y_scale: f64 = 0,
        } = scale: {
            const p_rows_px: f64 = @floatFromInt(p_grid.rows * cell_height);
            const p_cols_px: f64 = @floatFromInt(p_grid.columns * cell_width);
            if (img_width_f64 * p_rows_px > img_height_f64 * p_cols_px) {
                const x_scale = p_cols_px / @max(img_width_f64, 1);
                const y_scale = x_scale;
                const y_offset = (p_rows_px - img_height_f64 * y_scale) / 2;
                break :scale .{
                    .x_scale = x_scale,
                    .y_scale = y_scale,
                    .y_offset = y_offset,
                };
            } else {
                const y_scale = p_rows_px / @max(img_height_f64, 1);
                const x_scale = y_scale;
                const x_offset = (p_cols_px - img_width_f64 * x_scale) / 2;
                break :scale .{
                    .x_scale = x_scale,
                    .y_scale = y_scale,
                    .x_offset = x_offset,
                };
            }
        };
        const img_scaled: struct {
            x_offset: f64,
            y_offset: f64,
            width: f64,
            height: f64,
        } = scale: {
            const x_offset: f64 = p_scale.x_offset / p_scale.x_scale;
            const y_offset: f64 = p_scale.y_offset / p_scale.y_scale;
            const width: f64 = img_width_f64 + (x_offset * 2);
            const height: f64 = img_height_f64 + (y_offset * 2);
            break :scale .{
                .x_offset = x_offset,
                .y_offset = y_offset,
                .width = width,
                .height = height,
            };
        };
        var img_scale_source: struct {
            x: f64,
            y: f64,
            width: f64,
            height: f64,
        } = source: {
            const vp_width: f64 = @floatFromInt(self.width);
            const vp_height: f64 = @floatFromInt(self.height);
            const vp_col: f64 = @floatFromInt(self.col);
            const vp_row: f64 = @floatFromInt(self.row);
            const p_grid_cols: f64 = @floatFromInt(p_grid.columns);
            const p_grid_rows: f64 = @floatFromInt(p_grid.rows);
            const width: f64 = img_scaled.width * (vp_width / p_grid_cols);
            const height: f64 = img_scaled.height * (vp_height / p_grid_rows);
            const x: f64 = img_scaled.width * (vp_col / p_grid_cols);
            const y: f64 = img_scaled.height * (vp_row / p_grid_rows);
            break :source .{
                .width = width,
                .height = height,
                .x = x,
                .y = y,
            };
        };
        const p_dest: struct {
            x_offset: f64,
            y_offset: f64,
            width: f64,
            height: f64,
        } = dest: {
            var x_offset: f64 = 0;
            var y_offset: f64 = 0;
            var width: f64 = @floatFromInt(self.width * cell_width);
            var height: f64 = @floatFromInt(self.height * cell_height);
            if (img_scale_source.y < img_scaled.y_offset) {
                const offset: f64 = img_scaled.y_offset - img_scale_source.y;
                img_scale_source.height -= offset;
                y_offset = offset;
                height -= offset * p_scale.y_scale;
                img_scale_source.y = 0;
                if (img_scale_source.height > img_height_f64) {
                    img_scale_source.height = img_height_f64;
                    height = img_height_f64 * p_scale.y_scale;
                }
            } else if (img_scale_source.y + img_scale_source.height >
                img_scaled.height - img_scaled.y_offset)
            {
                img_scale_source.y -= img_scaled.y_offset;
                img_scale_source.height = img_scaled.height - img_scaled.y_offset - img_scale_source.y;
                img_scale_source.height -= img_scaled.y_offset;
                height = img_scale_source.height * p_scale.y_scale;
            } else {
                img_scale_source.y -= img_scaled.y_offset;
            }
            if (img_scale_source.x < img_scaled.x_offset) {
                const offset: f64 = img_scaled.x_offset - img_scale_source.x;
                img_scale_source.width -= offset;
                x_offset = offset;
                width -= offset * p_scale.x_scale;
                img_scale_source.x = 0;
                if (img_scale_source.width > img_width_f64) {
                    img_scale_source.width = img_width_f64;
                    width = img_width_f64 * p_scale.x_scale;
                }
            } else if (img_scale_source.x + img_scale_source.width >
                img_scaled.width - img_scaled.x_offset)
            {
                img_scale_source.x -= img_scaled.x_offset;
                img_scale_source.width = img_scaled.width - img_scaled.x_offset - img_scale_source.x;
                img_scale_source.width -= img_scaled.x_offset;
                width = img_scale_source.width * p_scale.x_scale;
            } else {
                img_scale_source.x -= img_scaled.x_offset;
            }
            if (img_scale_source.width <= 0 or img_scale_source.height <= 0) {
                return .{ .top_left = self.pin };
            }
            break :dest .{
                .x_offset = x_offset * p_scale.x_scale,
                .y_offset = y_offset * p_scale.y_scale,
                .width = width,
                .height = height,
            };
        };
        return .{
            .top_left = self.pin,
            .offset_x = @intFromFloat(@round(p_dest.x_offset)),
            .offset_y = @intFromFloat(@round(p_dest.y_offset)),
            .source_x = @intFromFloat(@round(img_scale_source.x)),
            .source_y = @intFromFloat(@round(img_scale_source.y)),
            .source_width = @intFromFloat(@round(img_scale_source.width)),
            .source_height = @intFromFloat(@round(img_scale_source.height)),
            .dest_width = @intFromFloat(@round(p_dest.width)),
            .dest_height = @intFromFloat(@round(p_dest.height)),
        };
    }
    fn grid(
        self: *const Placement,
        storage: *const ImageStorage,
        image: *const Image,
        cell_width: u32,
        cell_height: u32,
    ) Error!struct {
        rows: u32,
        columns: u32,
    } {
        const target = storage.placeholderTarget(
            self.image_id,
            self.placement_id,
        ) orelse return Error.PlacementMissingPlacement;
        const placement = target.placement;
        var rows = placement.rows;
        var columns = placement.columns;
        if (rows == 0) rows = (image.height + cell_height - 1) / cell_height;
        if (columns == 0) columns = (image.width + cell_width - 1) / cell_width;
        return .{
            .rows = std.math.cast(terminal.size.CellCountInt, rows) orelse
                return Error.PlacementGridOutOfBounds,
            .columns = std.math.cast(terminal.size.CellCountInt, columns) orelse
                return Error.PlacementGridOutOfBounds,
        };
    }
};
const IncompletePlacement = struct {
    pin: terminal.Pin,
    image_id_low: u24,
    image_id_high: ?u8 = null,
    placement_id: ?u24 = null,
    row: ?u32 = null,
    col: ?u32 = null,
    width: u32 = 1,
    pub fn init(
        row: *const terminal.Pin,
        cell: *const terminal.Cell,
    ) IncompletePlacement {
        assert(cell.codepoint() == placeholder);
        const style = row.style(cell);
        var result: IncompletePlacement = .{
            .pin = row.*,
            .image_id_low = colorToId(style.fg_color),
            .placement_id = placement_id: {
                const id = colorToId(style.underline_color);
                break :placement_id if (id != 0) id else null;
            },
        };
        const cps: []const u21 = row.grapheme(cell) orelse &.{};
        if (cps.len > 0) {
            result.row = getIndex(cps[0]) orelse value: {
                log.warn("virtual placement with invalid row diacritic cp={X}", .{cps[0]});
                break :value null;
            };
            if (cps.len > 1) {
                result.col = getIndex(cps[1]) orelse value: {
                    log.warn("virtual placement with invalid col diacritic cp={X}", .{cps[1]});
                    break :value null;
                };
                if (cps.len > 2) {
                    const high_ = getIndex(cps[2]) orelse value: {
                        log.warn("virtual placement with invalid high diacritic cp={X}", .{cps[2]});
                        break :value null;
                    };
                    if (high_) |high| {
                        result.image_id_high = std.math.cast(
                            u8,
                            high,
                        ) orelse value: {
                            log.warn("virtual placement with invalid high diacritic cp={X} value={}", .{
                                cps[2],
                                high,
                            });
                            break :value null;
                        };
                    }
                }
            }
        }
        return result;
    }
    pub fn append(self: *IncompletePlacement, other: *const IncompletePlacement) bool {
        if (!self.canAppend(other)) return false;
        self.width += 1;
        return true;
    }
    fn canAppend(self: *const IncompletePlacement, other: *const IncompletePlacement) bool {
        return self.image_id_low == other.image_id_low and
            self.placement_id == other.placement_id and
            (other.row == null or other.row == self.row) and
            (other.col == null or other.col == self.col.? + self.width) and
            (other.image_id_high == null or other.image_id_high == self.image_id_high);
    }
    pub fn complete(self: *const IncompletePlacement) Placement {
        return .{
            .pin = self.pin,
            .image_id = image_id: {
                const low: u32 = @intCast(self.image_id_low);
                const high: u32 = @intCast(self.image_id_high orelse 0);
                break :image_id low | (high << 24);
            },
            .placement_id = self.placement_id orelse 0,
            .col = self.col orelse 0,
            .row = self.row orelse 0,
            .width = self.width,
            .height = 1,
        };
    }
    fn colorToId(c: terminal.Style.Color) u24 {
        return switch (c) {
            .none => 0,
            .palette => |v| @intCast(v),
            .rgb => |rgb| rgb: {
                const r: u24 = @intCast(rgb.r);
                const g: u24 = @intCast(rgb.g);
                const b: u24 = @intCast(rgb.b);
                break :rgb (r << 16) | (g << 8) | b;
            },
        };
    }
};
fn getIndex(cp: u21) ?u32 {
    const idx = std.sort.binarySearch(u21, diacritics, cp, (struct {
        fn compare(context: u21, item: u21) std.math.Order {
            return std.math.order(context, item);
        }
    }).compare) orelse return null;
    return @intCast(idx);
}
const diacritics: []const u21 = &.{
    0x0305,
    0x030D,
    0x030E,
    0x0310,
    0x0312,
    0x033D,
    0x033E,
    0x033F,
    0x0346,
    0x034A,
    0x034B,
    0x034C,
    0x0350,
    0x0351,
    0x0352,
    0x0357,
    0x035B,
    0x0363,
    0x0364,
    0x0365,
    0x0366,
    0x0367,
    0x0368,
    0x0369,
    0x036A,
    0x036B,
    0x036C,
    0x036D,
    0x036E,
    0x036F,
    0x0483,
    0x0484,
    0x0485,
    0x0486,
    0x0487,
    0x0592,
    0x0593,
    0x0594,
    0x0595,
    0x0597,
    0x0598,
    0x0599,
    0x059C,
    0x059D,
    0x059E,
    0x059F,
    0x05A0,
    0x05A1,
    0x05A8,
    0x05A9,
    0x05AB,
    0x05AC,
    0x05AF,
    0x05C4,
    0x0610,
    0x0611,
    0x0612,
    0x0613,
    0x0614,
    0x0615,
    0x0616,
    0x0617,
    0x0657,
    0x0658,
    0x0659,
    0x065A,
    0x065B,
    0x065D,
    0x065E,
    0x06D6,
    0x06D7,
    0x06D8,
    0x06D9,
    0x06DA,
    0x06DB,
    0x06DC,
    0x06DF,
    0x06E0,
    0x06E1,
    0x06E2,
    0x06E4,
    0x06E7,
    0x06E8,
    0x06EB,
    0x06EC,
    0x0730,
    0x0732,
    0x0733,
    0x0735,
    0x0736,
    0x073A,
    0x073D,
    0x073F,
    0x0740,
    0x0741,
    0x0743,
    0x0745,
    0x0747,
    0x0749,
    0x074A,
    0x07EB,
    0x07EC,
    0x07ED,
    0x07EE,
    0x07EF,
    0x07F0,
    0x07F1,
    0x07F3,
    0x0816,
    0x0817,
    0x0818,
    0x0819,
    0x081B,
    0x081C,
    0x081D,
    0x081E,
    0x081F,
    0x0820,
    0x0821,
    0x0822,
    0x0823,
    0x0825,
    0x0826,
    0x0827,
    0x0829,
    0x082A,
    0x082B,
    0x082C,
    0x082D,
    0x0951,
    0x0953,
    0x0954,
    0x0F82,
    0x0F83,
    0x0F86,
    0x0F87,
    0x135D,
    0x135E,
    0x135F,
    0x17DD,
    0x193A,
    0x1A17,
    0x1A75,
    0x1A76,
    0x1A77,
    0x1A78,
    0x1A79,
    0x1A7A,
    0x1A7B,
    0x1A7C,
    0x1B6B,
    0x1B6D,
    0x1B6E,
    0x1B6F,
    0x1B70,
    0x1B71,
    0x1B72,
    0x1B73,
    0x1CD0,
    0x1CD1,
    0x1CD2,
    0x1CDA,
    0x1CDB,
    0x1CE0,
    0x1DC0,
    0x1DC1,
    0x1DC3,
    0x1DC4,
    0x1DC5,
    0x1DC6,
    0x1DC7,
    0x1DC8,
    0x1DC9,
    0x1DCB,
    0x1DCC,
    0x1DD1,
    0x1DD2,
    0x1DD3,
    0x1DD4,
    0x1DD5,
    0x1DD6,
    0x1DD7,
    0x1DD8,
    0x1DD9,
    0x1DDA,
    0x1DDB,
    0x1DDC,
    0x1DDD,
    0x1DDE,
    0x1DDF,
    0x1DE0,
    0x1DE1,
    0x1DE2,
    0x1DE3,
    0x1DE4,
    0x1DE5,
    0x1DE6,
    0x1DFE,
    0x20D0,
    0x20D1,
    0x20D4,
    0x20D5,
    0x20D6,
    0x20D7,
    0x20DB,
    0x20DC,
    0x20E1,
    0x20E7,
    0x20E9,
    0x20F0,
    0x2CEF,
    0x2CF0,
    0x2CF1,
    0x2DE0,
    0x2DE1,
    0x2DE2,
    0x2DE3,
    0x2DE4,
    0x2DE5,
    0x2DE6,
    0x2DE7,
    0x2DE8,
    0x2DE9,
    0x2DEA,
    0x2DEB,
    0x2DEC,
    0x2DED,
    0x2DEE,
    0x2DEF,
    0x2DF0,
    0x2DF1,
    0x2DF2,
    0x2DF3,
    0x2DF4,
    0x2DF5,
    0x2DF6,
    0x2DF7,
    0x2DF8,
    0x2DF9,
    0x2DFA,
    0x2DFB,
    0x2DFC,
    0x2DFD,
    0x2DFE,
    0x2DFF,
    0xA66F,
    0xA67C,
    0xA67D,
    0xA6F0,
    0xA6F1,
    0xA8E0,
    0xA8E1,
    0xA8E2,
    0xA8E3,
    0xA8E4,
    0xA8E5,
    0xA8E6,
    0xA8E7,
    0xA8E8,
    0xA8E9,
    0xA8EA,
    0xA8EB,
    0xA8EC,
    0xA8ED,
    0xA8EE,
    0xA8EF,
    0xA8F0,
    0xA8F1,
    0xAAB0,
    0xAAB2,
    0xAAB3,
    0xAAB7,
    0xAAB8,
    0xAABE,
    0xAABF,
    0xAAC1,
    0xFE20,
    0xFE21,
    0xFE22,
    0xFE23,
    0xFE24,
    0xFE25,
    0xFE26,
    0x10A0F,
    0x10A38,
    0x1D185,
    0x1D186,
    0x1D187,
    0x1D188,
    0x1D189,
    0x1D1AA,
    0x1D1AB,
    0x1D1AC,
    0x1D1AD,
    0x1D242,
    0x1D243,
    0x1D244,
};
test "unicode diacritic sorted" {
    try testing.expect(std.sort.isSorted(u21, diacritics, {}, (struct {
        fn lessThan(context: void, lhs: u21, rhs: u21) bool {
            _ = context;
            return lhs < rhs;
        }
    }).lessThan));
}
test "unicode diacritic" {
    try testing.expectEqual(30, getIndex(0x483).?);
    try testing.expectEqual(294, getIndex(0x1d242).?);
}
test "unicode placement: none" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, true);
    try t.printString("hello\nworld\n1\n2");
    const pin = t.screens.active.pages.getTopLeft(.viewport);
    var it = placementIterator(pin, null);
    try testing.expect(it.next() == null);
}
test "unicode placement: single row/col" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, true);
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");
    const pin = t.screens.active.pages.getTopLeft(.viewport);
    var it = placementIterator(pin, null);
    {
        const p = it.next().?;
        try testing.expectEqual(0, p.image_id);
        try testing.expectEqual(0, p.placement_id);
        try testing.expectEqual(0, p.row);
        try testing.expectEqual(0, p.col);
    }
    try testing.expect(it.next() == null);
}
test "unicode placement: continuation break" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 5, .cols = 10 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, true);
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");
    try t.printString("\u{10EEEE}\u{0305}\u{030E}");
    const pin = t.screens.active.pages.getTopLeft(.viewport);
    var it = placementIterator(pin, null);
    {
        const p = it.next().?;
        try testing.expectEqual(0, p.image_id);
        try testing.expectEqual(0, p.placement_id);
        try testing.expectEqual(0, p.row);
        try testing.expectEqual(0, p.col);
        try testing.expectEqual(1, p.width);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(0, p.image_id);
        try testing.expectEqual(0, p.placement_id);
        try testing.expectEqual(0, p.row);
        try testing.expectEqual(2, p.col);
        try testing.expectEqual(1, p.width);
    }
    try testing.expect(it.next() == null);
}
test "unicode placement: continuation with diacritics set" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 5, .cols = 10 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, true);
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");
    try t.printString("\u{10EEEE}\u{0305}\u{030D}");
    try t.printString("\u{10EEEE}\u{0305}\u{030E}");
    const pin = t.screens.active.pages.getTopLeft(.viewport);
    var it = placementIterator(pin, null);
    {
        const p = it.next().?;
        try testing.expectEqual(0, p.image_id);
        try testing.expectEqual(0, p.placement_id);
        try testing.expectEqual(0, p.row);
        try testing.expectEqual(0, p.col);
        try testing.expectEqual(3, p.width);
    }
    try testing.expect(it.next() == null);
}
test "unicode placement: continuation with no col" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 5, .cols = 10 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, true);
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");
    try t.printString("\u{10EEEE}\u{0305}");
    try t.printString("\u{10EEEE}\u{0305}");
    const pin = t.screens.active.pages.getTopLeft(.viewport);
    var it = placementIterator(pin, null);
    {
        const p = it.next().?;
        try testing.expectEqual(0, p.image_id);
        try testing.expectEqual(0, p.placement_id);
        try testing.expectEqual(0, p.row);
        try testing.expectEqual(0, p.col);
        try testing.expectEqual(3, p.width);
    }
    try testing.expect(it.next() == null);
}
test "unicode placement: continuation with no diacritics" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 5, .cols = 10 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, true);
    try t.printString("\u{10EEEE}");
    try t.printString("\u{10EEEE}");
    try t.printString("\u{10EEEE}");
    const pin = t.screens.active.pages.getTopLeft(.viewport);
    var it = placementIterator(pin, null);
    {
        const p = it.next().?;
        try testing.expectEqual(0, p.image_id);
        try testing.expectEqual(0, p.placement_id);
        try testing.expectEqual(0, p.row);
        try testing.expectEqual(0, p.col);
        try testing.expectEqual(3, p.width);
    }
    try testing.expect(it.next() == null);
}
test "unicode placement: run ending" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 5, .cols = 10 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, true);
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");
    try t.printString("\u{10EEEE}\u{0305}\u{030D}");
    try t.printString("ABC");
    const pin = t.screens.active.pages.getTopLeft(.viewport);
    var it = placementIterator(pin, null);
    {
        const p = it.next().?;
        try testing.expectEqual(0, p.image_id);
        try testing.expectEqual(0, p.placement_id);
        try testing.expectEqual(0, p.row);
        try testing.expectEqual(0, p.col);
        try testing.expectEqual(2, p.width);
    }
    try testing.expect(it.next() == null);
}
test "unicode placement: run starting in the middle" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 5, .cols = 10 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, true);
    try t.printString("ABC");
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");
    try t.printString("\u{10EEEE}\u{0305}\u{030D}");
    const pin = t.screens.active.pages.getTopLeft(.viewport);
    var it = placementIterator(pin, null);
    {
        const p = it.next().?;
        try testing.expectEqual(0, p.image_id);
        try testing.expectEqual(0, p.placement_id);
        try testing.expectEqual(0, p.row);
        try testing.expectEqual(0, p.col);
        try testing.expectEqual(2, p.width);
    }
    try testing.expect(it.next() == null);
}
test "unicode placement: specifying image id as palette" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, true);
    try t.setAttribute(.{ .@"256_fg" = 42 });
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");
    const pin = t.screens.active.pages.getTopLeft(.viewport);
    var it = placementIterator(pin, null);
    {
        const p = it.next().?;
        try testing.expectEqual(42, p.image_id);
        try testing.expectEqual(0, p.placement_id);
        try testing.expectEqual(0, p.row);
        try testing.expectEqual(0, p.col);
    }
    try testing.expect(it.next() == null);
}
test "unicode placement: specifying image id with high bits" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, true);
    try t.setAttribute(.{ .@"256_fg" = 42 });
    try t.printString("\u{10EEEE}\u{0305}\u{0305}\u{030E}");
    const pin = t.screens.active.pages.getTopLeft(.viewport);
    var it = placementIterator(pin, null);
    {
        const p = it.next().?;
        try testing.expectEqual(33554474, p.image_id);
        try testing.expectEqual(0, p.placement_id);
        try testing.expectEqual(0, p.row);
        try testing.expectEqual(0, p.col);
    }
    try testing.expect(it.next() == null);
}
test "unicode placement: specifying placement id as palette" {
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, true);
    try t.setAttribute(.{ .@"256_fg" = 42 });
    try t.setAttribute(.{ .@"256_underline_color" = 21 });
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");
    const pin = t.screens.active.pages.getTopLeft(.viewport);
    var it = placementIterator(pin, null);
    {
        const p = it.next().?;
        try testing.expectEqual(42, p.image_id);
        try testing.expectEqual(21, p.placement_id);
        try testing.expectEqual(0, p.row);
        try testing.expectEqual(0, p.col);
    }
    try testing.expect(it.next() == null);
}
test "unicode render placement: dog 4x2" {
    const alloc = testing.allocator;
    const io = testing.io;
    const cell_width = 36;
    const cell_height = 80;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 100, .rows = 100 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    const image: Image = .{ .id = 1, .width = 500, .height = 306 };
    try s.addImage(io, alloc, t.screens.active, image);
    try s.addPlacement(io, alloc, t.screens.active, 1, 0, .{
        .location = .{ .virtual = {} },
        .columns = 4,
        .rows = 2,
    });
    {
        const p: Placement = .{
            .pin = t.screens.active.cursor.page_pin.*,
            .image_id = 1,
            .placement_id = 0,
            .col = 0,
            .row = 0,
            .width = 4,
            .height = 1,
        };
        const rp = try p.renderPlacement(&s, &image, cell_width, cell_height);
        try testing.expectEqual(0, rp.offset_x);
        try testing.expectEqual(36, rp.offset_y);
        try testing.expectEqual(0, rp.source_x);
        try testing.expectEqual(0, rp.source_y);
        try testing.expectEqual(500, rp.source_width);
        try testing.expectEqual(153, rp.source_height);
        try testing.expectEqual(144, rp.dest_width);
        try testing.expectEqual(44, rp.dest_height);
    }
    {
        const p: Placement = .{
            .pin = t.screens.active.cursor.page_pin.*,
            .image_id = 1,
            .placement_id = 0,
            .col = 0,
            .row = 1,
            .width = 4,
            .height = 1,
        };
        const rp = try p.renderPlacement(&s, &image, cell_width, cell_height);
        try testing.expectEqual(0, rp.offset_x);
        try testing.expectEqual(0, rp.offset_y);
        try testing.expectEqual(0, rp.source_x);
        try testing.expectEqual(153, rp.source_y);
        try testing.expectEqual(500, rp.source_width);
        try testing.expectEqual(153, rp.source_height);
        try testing.expectEqual(144, rp.dest_width);
        try testing.expectEqual(44, rp.dest_height);
    }
}
test "unicode render placement: dog 2x2 with blank cells" {
    const alloc = testing.allocator;
    const io = testing.io;
    const cell_width = 36;
    const cell_height = 80;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 100, .rows = 100 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    const image: Image = .{ .id = 1, .width = 500, .height = 306 };
    try s.addImage(io, alloc, t.screens.active, image);
    try s.addPlacement(io, alloc, t.screens.active, 1, 0, .{
        .location = .{ .virtual = {} },
        .columns = 2,
        .rows = 2,
    });
    {
        const p: Placement = .{
            .pin = t.screens.active.cursor.page_pin.*,
            .image_id = 1,
            .placement_id = 0,
            .col = 0,
            .row = 0,
            .width = 4,
            .height = 1,
        };
        const rp = try p.renderPlacement(&s, &image, cell_width, cell_height);
        try testing.expectEqual(0, rp.offset_x);
        try testing.expectEqual(58, rp.offset_y);
        try testing.expectEqual(0, rp.source_x);
        try testing.expectEqual(0, rp.source_y);
        try testing.expectEqual(500, rp.source_width);
        try testing.expectEqual(153, rp.source_height);
        try testing.expectEqual(72, rp.dest_width);
        try testing.expectEqual(22, rp.dest_height);
    }
    {
        const p: Placement = .{
            .pin = t.screens.active.cursor.page_pin.*,
            .image_id = 1,
            .placement_id = 0,
            .col = 0,
            .row = 1,
            .width = 4,
            .height = 1,
        };
        const rp = try p.renderPlacement(&s, &image, cell_width, cell_height);
        try testing.expectEqual(0, rp.offset_x);
        try testing.expectEqual(0, rp.offset_y);
        try testing.expectEqual(0, rp.source_x);
        try testing.expectEqual(153, rp.source_y);
        try testing.expectEqual(500, rp.source_width);
        try testing.expectEqual(153, rp.source_height);
        try testing.expectEqual(72, rp.dest_width);
        try testing.expectEqual(22, rp.dest_height);
    }
}
test "unicode render placement: dog 1x1" {
    const alloc = testing.allocator;
    const io = testing.io;
    const cell_width = 36;
    const cell_height = 80;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 100, .rows = 100 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    const image: Image = .{ .id = 1, .width = 500, .height = 306 };
    try s.addImage(io, alloc, t.screens.active, image);
    try s.addPlacement(io, alloc, t.screens.active, 1, 0, .{
        .location = .{ .virtual = {} },
        .columns = 1,
        .rows = 1,
    });
    {
        const p: Placement = .{
            .pin = t.screens.active.cursor.page_pin.*,
            .image_id = 1,
            .placement_id = 0,
            .col = 0,
            .row = 0,
            .width = 4,
            .height = 1,
        };
        const rp = try p.renderPlacement(&s, &image, cell_width, cell_height);
        try testing.expectEqual(0, rp.offset_x);
        try testing.expectEqual(29, rp.offset_y);
        try testing.expectEqual(0, rp.source_x);
        try testing.expectEqual(0, rp.source_y);
        try testing.expectEqual(500, rp.source_width);
        try testing.expectEqual(306, rp.source_height);
        try testing.expectEqual(36, rp.dest_width);
        try testing.expectEqual(22, rp.dest_height);
    }
}
