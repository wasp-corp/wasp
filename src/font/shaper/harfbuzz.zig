const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const harfbuzz = @import("harfbuzz");
const font = @import("../main.zig");
const terminal = @import("../../terminal/main.zig");
const unicode = @import("../../unicode/root.zig");
const Feature = font.shape.Feature;
const FeatureList = font.shape.FeatureList;
const default_features = font.shape.default_features;
const Face = font.Face;
const Collection = font.Collection;
const DeferredFace = font.DeferredFace;
const Library = font.Library;
const SharedGrid = font.SharedGrid;
const Style = font.Style;
const Presentation = font.Presentation;
const global = @import("../../global.zig");
const log = std.log.scoped(.font_shaper);
pub const Shaper = struct {
    alloc: Allocator,
    hb_buf: harfbuzz.Buffer,
    cell_buf: CellBuf,
    hb_feats: []harfbuzz.Feature,
    codepoints: std.ArrayList(Codepoint) = .empty,
    const Codepoint = struct {
        cluster: u32,
        codepoint: u32,
    };
    const CellBuf = std.ArrayListUnmanaged(font.shape.Cell);
    const RunOffset = struct {
        cluster: u32 = 0,
        x: i32 = 0,
        y: i32 = 0,
    };
    const CellOffset = struct {
        cluster: u32 = 0,
        x: i32 = 0,
    };
    pub fn init(alloc: Allocator, opts: font.shape.Options) !Shaper {
        const hb_feats = hb_feats: {
            var feature_list: FeatureList = .{};
            defer feature_list.deinit(alloc);
            try feature_list.features.appendSlice(alloc, &default_features);
            for (opts.features) |feature_str| {
                try feature_list.appendFromString(alloc, feature_str);
            }
            var list = try alloc.alloc(harfbuzz.Feature, feature_list.features.items.len);
            errdefer alloc.free(list);
            for (feature_list.features.items, 0..) |feature, i| {
                list[i] = .{
                    .tag = std.mem.nativeToBig(u32, @bitCast(feature.tag)),
                    .value = feature.value,
                    .start = harfbuzz.c.HB_FEATURE_GLOBAL_START,
                    .end = harfbuzz.c.HB_FEATURE_GLOBAL_END,
                };
            }
            break :hb_feats list;
        };
        errdefer alloc.free(hb_feats);
        return Shaper{
            .alloc = alloc,
            .hb_buf = try harfbuzz.Buffer.create(),
            .cell_buf = .empty,
            .hb_feats = hb_feats,
        };
    }
    pub fn deinit(self: *Shaper) void {
        self.hb_buf.destroy();
        self.cell_buf.deinit(self.alloc);
        self.alloc.free(self.hb_feats);
        self.codepoints.deinit(self.alloc);
    }
    pub fn endFrame(self: *const Shaper) void {
        _ = self;
    }
    pub fn runIterator(
        self: *Shaper,
        opts: font.shape.RunOptions,
    ) font.shape.RunIterator {
        return .{
            .hooks = .{ .shaper = self },
            .opts = opts,
        };
    }
    pub fn shape(self: *Shaper, run: font.shape.TextRun) ![]const font.shape.Cell {
        if (run.font_index.special() == null) {
            run.grid.lock.lockUncancelable(global.io());
            defer run.grid.lock.unlock(global.io());
            const face = try run.grid.resolver.collection.getFace(run.font_index);
            const i = if (!face.quirks_disable_default_font_features) 0 else i: {
                break :i default_features.len;
            };
            harfbuzz.shape(face.hb_font, self.hb_buf, self.hb_feats[i..]);
        }
        if (self.hb_buf.getLength() == 0) return self.cell_buf.items[0..0];
        const info = self.hb_buf.getGlyphInfos();
        const pos = self.hb_buf.getGlyphPositions() orelse return error.HarfbuzzFailed;
        assert(info.len == pos.len);
        var run_offset: RunOffset = .{};
        var cell_offset: CellOffset = .{};
        self.cell_buf.clearRetainingCapacity();
        for (info, pos) |info_v, pos_v| {
            const index = info_v.cluster;
            const cluster = self.codepoints.items[index].cluster;
            if (cell_offset.cluster != cluster) {
                const is_after_glyph_from_current_or_next_clusters =
                    cluster <= run_offset.cluster;
                const is_first_codepoint_in_cluster = blk: {
                    var i = index;
                    while (i > 0) {
                        i -= 1;
                        const codepoint = self.codepoints.items[i];
                        break :blk codepoint.cluster != cluster;
                    } else break :blk true;
                };
                if (is_first_codepoint_in_cluster and
                    !is_after_glyph_from_current_or_next_clusters)
                {
                    cell_offset = .{
                        .cluster = cluster,
                        .x = run_offset.x,
                    };
                }
            }
            const x_offset = run_offset.x - cell_offset.x + ((pos_v.x_offset + 0b100_000) >> 6);
            const y_offset = run_offset.y + ((pos_v.y_offset + 0b100_000) >> 6);
            try self.cell_buf.append(self.alloc, .{
                .x = @intCast(cell_offset.cluster),
                .x_offset = @intCast(x_offset),
                .y_offset = @intCast(y_offset),
                .glyph_index = info_v.codepoint,
            });
            run_offset.x += (pos_v.x_advance + 0b100_000) >> 6;
            run_offset.y += (pos_v.y_advance + 0b100_000) >> 6;
            run_offset.cluster = @max(run_offset.cluster, cluster);
        }
        return self.cell_buf.items;
    }
    pub const RunIteratorHook = struct {
        shaper: *Shaper,
        pub fn prepare(self: RunIteratorHook) void {
            self.shaper.hb_buf.reset();
            self.shaper.hb_buf.setContentType(.unicode);
            self.shaper.hb_buf.setClusterLevel(.characters);
            self.shaper.codepoints.clearRetainingCapacity();
            self.shaper.hb_buf.setDirection(.ltr);
        }
        pub fn addCodepoint(self: RunIteratorHook, cp: u32, cluster: u32) !void {
            const index: u32 = @intCast(self.shaper.codepoints.items.len);
            self.shaper.hb_buf.add(cp, index);
            try self.shaper.codepoints.append(self.shaper.alloc, .{
                .cluster = cluster,
                .codepoint = cp,
            });
        }
        pub fn finalize(self: RunIteratorHook) void {
            self.shaper.hb_buf.guessSegmentProperties();
        }
    };
    fn debugPositions(
        self: *Shaper,
        run_offset: RunOffset,
        cell_offset: CellOffset,
        pos_v: harfbuzz.GlyphPosition,
        index: u32,
    ) !void {
        const x_offset = run_offset.x - cell_offset.x + ((pos_v.x_offset + 0b100_000) >> 6);
        const y_offset = run_offset.y + ((pos_v.y_offset + 0b100_000) >> 6);
        const advance_x_offset = run_offset.x - cell_offset.x;
        const advance_y_offset = run_offset.y;
        const x_offset_diff = x_offset - advance_x_offset;
        const y_offset_diff = y_offset - advance_y_offset;
        const positions_differ = @abs(x_offset_diff) > 0 or @abs(y_offset_diff) > 0;
        const y_offset_differs = run_offset.y != 0;
        const cluster = self.codepoints.items[index].cluster;
        const cluster_differs = cluster != cell_offset.cluster;
        const extra_debugging = false;
        const is_previous_codepoint_prepend = if (cluster_differs or
            extra_debugging)
        blk: {
            var i = index;
            while (i > 0) {
                i -= 1;
                const codepoint = self.codepoints.items[i];
                break :blk unicode.table.get(@intCast(codepoint.codepoint)).grapheme_boundary_class == .prepend;
            }
            break :blk false;
        } else false;
        const formatted_cps: ?[]u8 = if (positions_differ or
            y_offset_differs or
            cluster_differs or
            extra_debugging)
        blk: {
            var allocating = std.Io.Writer.Allocating.init(self.alloc);
            defer allocating.deinit();
            const writer = &allocating.writer;
            const codepoints = self.codepoints.items;
            var last_cluster: ?u32 = null;
            for (codepoints, 0..) |cp, i| {
                if (@as(i32, @intCast(cp.cluster)) >= @as(i32, @intCast(cell_offset.cluster)) - 1 and
                    cp.cluster <= cluster + 1)
                {
                    if (last_cluster) |last| {
                        if (cp.cluster != last) {
                            try writer.writeAll(" ");
                        }
                    }
                    if (i == index) {
                        try writer.writeAll("▸");
                    }
                    if (cp.codepoint > 0xFFFF) {
                        try writer.print("\\U{x:0>8}", .{cp.codepoint});
                    } else {
                        try writer.print("\\u{x:0>4}", .{cp.codepoint});
                    }
                    last_cluster = cp.cluster;
                }
            }
            try writer.writeAll(" → ");
            for (codepoints) |cp| {
                if (@as(i32, @intCast(cp.cluster)) >= @as(i32, @intCast(cell_offset.cluster)) - 1 and
                    cp.cluster <= cluster + 1)
                {
                    try writer.print("{u}", .{@as(u21, @intCast(cp.codepoint))});
                }
            }
            break :blk try allocating.toOwnedSlice();
        } else null;
        defer if (formatted_cps) |cps| self.alloc.free(cps);
        if (extra_debugging) {
            log.warn("extra debugging of positions index={d} cell_offset.cluster={d} cluster={d} run_offset.cluster={d} diff={d} pos=({d},{d}) run_offset=({d},{d}) cell_offset.x={d} is_prev_prepend={} cps = {s}", .{
                index,
                cell_offset.cluster,
                cluster,
                run_offset.cluster,
                @as(isize, @intCast(cluster)) - @as(isize, @intCast(cell_offset.cluster)),
                x_offset,
                y_offset,
                run_offset.x,
                run_offset.y,
                cell_offset.x,
                is_previous_codepoint_prepend,
                formatted_cps.?,
            });
        }
        if (positions_differ) {
            log.warn("position differs from advance: cluster={d} pos=({d},{d}) adv=({d},{d}) diff=({d},{d}) cps = {s}", .{
                cluster,
                x_offset,
                y_offset,
                advance_x_offset,
                advance_y_offset,
                x_offset_diff,
                y_offset_diff,
                formatted_cps.?,
            });
        }
        if (y_offset_differs) {
            log.warn("run_offset.y differs from zero: cluster={d} pos=({d},{d}) run_offset=({d},{d}) cell_offset.x={d} cps = {s}", .{
                cluster,
                x_offset,
                y_offset,
                run_offset.x,
                run_offset.y,
                cell_offset.x,
                formatted_cps.?,
            });
        }
        if (cluster_differs) {
            log.warn("cell_offset.cluster differs from cluster (potential ligature detected) cell_offset.cluster={d} cluster={d} run_offset.cluster={d} diff={d} pos=({d},{d}) run_offset=({d},{d}) cell_offset.x={d} is_prev_prepend={} cps = {s}", .{
                cell_offset.cluster,
                cluster,
                run_offset.cluster,
                @as(isize, @intCast(cluster)) - @as(isize, @intCast(cell_offset.cluster)),
                x_offset,
                y_offset,
                run_offset.x,
                run_offset.y,
                cell_offset.x,
                is_previous_codepoint_prepend,
                formatted_cps.?,
            });
        }
    }
};
test "run iterator" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    {
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);
        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice("ABCD");
        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |_| count += 1;
        try testing.expectEqual(@as(usize, 1), count);
    }
    {
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 3 });
        defer t.deinit(alloc);
        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice("ABCD   EFG");
        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |_| count += 1;
        try testing.expectEqual(@as(usize, 1), count);
    }
    {
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);
        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice("A😃D");
        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |_| {
            count += 1;
            try testing.expectEqual(@as(u32, 1), shaper.hb_buf.getLength());
        }
        try testing.expectEqual(@as(usize, 3), count);
    }
}
test "run iterator: empty cells with background set" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    {
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);
        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice("\x1b[48;2;255;0;0mA");
        {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 1 } }).?;
            const cell = list_cell.cell;
            cell.* = .{
                .content_tag = .bg_color_rgb,
                .content = .{ .color_rgb = .{ .r = 0xFF, .g = 0, .b = 0 } },
            };
        }
        {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 2 } }).?;
            const cell = list_cell.cell;
            cell.* = .{
                .content_tag = .bg_color_rgb,
                .content = .{ .color_rgb = .{ .r = 0xFF, .g = 0, .b = 0 } },
            };
        }
        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        {
            const run = (try it.next(alloc)).?;
            try testing.expectEqual(@as(u32, 3), shaper.hb_buf.getLength());
            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 3), cells.len);
        }
        try testing.expect(try it.next(alloc) == null);
    }
}
test "shape" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x1F44D, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0x1F44D, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0x1F3FD, buf[buf_idx..]);
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(buf[0..buf_idx]);
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        try testing.expectEqual(@as(u32, 3), shaper.hb_buf.getLength());
        _ = try shaper.shape(run);
    }
    try testing.expectEqual(@as(usize, 1), count);
}
test "shape inconsolata ligs" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    {
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);
        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice(">=");
        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            try testing.expectEqual(@as(usize, 2), run.cells);
            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 1), cells.len);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
    {
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);
        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice("===");
        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            try testing.expectEqual(@as(usize, 3), run.cells);
            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 1), cells.len);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}
test "shape monaspace ligs" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var testdata = try testShaperWithFont(alloc, .monaspace_neon);
    defer testdata.deinit();
    {
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);
        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice("===");
        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            try testing.expectEqual(@as(usize, 3), run.cells);
            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 1), cells.len);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}
test "shape arabic forced LTR" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var testdata = try testShaperWithFont(alloc, .arabic);
    defer testdata.deinit();
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 120, .rows = 30 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(@embedFile("testdata/arabic.txt"));
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        try testing.expectEqual(@as(usize, 25), run.cells);
        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 25), cells.len);
        var x: u16 = cells[0].x;
        for (cells[1..]) |cell| {
            try testing.expectEqual(x + 1, cell.x);
            x = cell.x;
        }
    }
    try testing.expectEqual(@as(usize, 1), count);
}
test "shape emoji width" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    {
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);
        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice("👍");
        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            try testing.expectEqual(@as(usize, 2), run.cells);
            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 1), cells.len);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}
test "shape emoji width long" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    var t = try terminal.Terminal.init(
        io,
        alloc,
        .{ .cols = 30, .rows = 3 },
    );
    defer t.deinit(alloc);
    var page = t.screens.active.pages.pages.first.?.page();
    var row = page.getRow(1);
    const cell = &row.cells.ptr(page.memory)[0];
    cell.* = .{
        .content_tag = .codepoint,
        .content = .{ .codepoint = @bitCast(@as(u24, 0x1F9D4)) },
    };
    var graphemes = [_]u21{
        0x1F3FB,
        0x200D,
        0x2642,
        0xFE0F,
    };
    try page.setGraphemes(
        row,
        cell,
        graphemes[0..],
    );
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(1).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        try testing.expectEqual(@as(u32, 4), shaper.hb_buf.getLength());
        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 1), cells.len);
    }
    try testing.expectEqual(@as(usize, 1), count);
}
test "shaper selects font for entire grapheme" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("#\u{20E3}");
    const primary = (try testdata.grid.getIndex(alloc, '#', .regular, null)).?;
    try testing.expect(testdata.grid.hasCodepoint(primary, '#', null));
    try testing.expect(!testdata.grid.hasCodepoint(primary, 0x20E3, null));
    const additional = (try testdata.grid.getIndex(alloc, 0x20E3, .regular, null)).?;
    try testing.expect(testdata.grid.hasCodepoint(additional, '#', null));
    try testing.expect(testdata.grid.hasCodepoint(additional, 0x20E3, null));
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var it = testdata.shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    const run = (try it.next(alloc)).?;
    try testing.expectEqual(additional, run.font_index);
}
test "shape variation selector VS15" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x270C, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0xFE0E, buf[buf_idx..]);
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(buf[0..buf_idx]);
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        try testing.expectEqual(@as(u32, 1), shaper.hb_buf.getLength());
        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 1), cells.len);
    }
    try testing.expectEqual(@as(usize, 1), count);
}
test "shape variation selector VS16" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x270C, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0xFE0F, buf[buf_idx..]);
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(buf[0..buf_idx]);
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        try testing.expectEqual(@as(u32, 1), shaper.hb_buf.getLength());
        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 1), cells.len);
    }
    try testing.expectEqual(@as(usize, 1), count);
}
test "shape with empty cells in between" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    var t = try terminal.Terminal.init(
        io,
        alloc,
        .{ .cols = 30, .rows = 3 },
    );
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("A");
    s.nextSlice("\x1b[5C");
    s.nextSlice("B");
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 1), count);
        try testing.expectEqual(@as(usize, 7), cells.len);
    }
}
test "shape Combining characters" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode('n', buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0x0308, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0x0308, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode('a', buf[buf_idx..]);
    var t = try terminal.Terminal.init(
        io,
        alloc,
        .{ .cols = 30, .rows = 3 },
    );
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(buf[0..buf_idx]);
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 4), cells.len);
        try testing.expectEqual(@as(u16, 0), cells[0].x);
        try testing.expectEqual(@as(u16, 0), cells[1].x);
        try testing.expectEqual(@as(u16, 0), cells[2].x);
        try testing.expectEqual(@as(u16, 1), cells[3].x);
    }
    try testing.expectEqual(@as(usize, 1), count);
}
test "shape Devanagari string" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var testdata = testShaperWithDiscoveredFont(
        alloc,
        "Arial Unicode MS",
    ) catch return error.SkipZigTest;
    defer testdata.deinit();
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, false);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("अपार्टमेंट");
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    const run = try it.next(alloc);
    try testing.expect(run != null);
    const cells = try shaper.shape(run.?);
    try testing.expectEqual(@as(usize, 8), cells.len);
    try testing.expectEqual(@as(u16, 0), cells[0].x);
    try testing.expectEqual(@as(u16, 1), cells[1].x);
    try testing.expectEqual(@as(u16, 2), cells[2].x);
    try testing.expectEqual(@as(u16, 4), cells[3].x);
    try testing.expectEqual(@as(u16, 4), cells[4].x);
    try testing.expectEqual(@as(u16, 5), cells[5].x);
    try testing.expectEqual(@as(u16, 5), cells[6].x);
    try testing.expectEqual(@as(u16, 6), cells[7].x);
    try testing.expect(try it.next(alloc) == null);
}
test "shape Tai Tham vowels (position differs from advance)" {
    return error.SkipZigTest;
}
test "shape Tibetan characters" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var testdata = testShaperWithDiscoveredFont(
        alloc,
        "Noto Serif Tibetan",
    ) catch return error.SkipZigTest;
    defer testdata.deinit();
    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x0f00, buf[buf_idx..]);
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, true);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(buf[0..buf_idx]);
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u16, 0), cells[0].x);
        try testing.expectEqual(@as(u16, 0), cells[1].x);
        try testing.expect(cells[1].x_offset < 2);
    }
    try testing.expectEqual(@as(usize, 1), count);
}
test "shape Tai Tham letters (run_offset.y differs from zero)" {
    return error.SkipZigTest;
}
test "shape Javanese ligatures" {
    return error.SkipZigTest;
}
test "shape Chakma vowel sign with ligature (vowel sign renders first)" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var testdata = testShaperWithDiscoveredFont(
        alloc,
        "Noto Sans Chakma",
    ) catch return error.SkipZigTest;
    defer testdata.deinit();
    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x1111d, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0x11116, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0x11133, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0x11120, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0x1112c, buf[buf_idx..]);
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, true);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(buf[0..buf_idx]);
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 4), cells.len);
        try testing.expectEqual(@as(u16, 0), cells[0].x);
        try testing.expectEqual(@as(u16, 0), cells[1].x);
        try testing.expectEqual(@as(u16, 0), cells[2].x);
        try testing.expectEqual(@as(u16, 0), cells[3].x);
        try testing.expect(cells[1].x_offset < cells[2].x_offset);
    }
    try testing.expectEqual(@as(usize, 1), count);
}
test "shape Bengali ligatures with out of order vowels" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var testdata = testShaperWithDiscoveredFont(
        alloc,
        "Arial Unicode MS",
    ) catch return error.SkipZigTest;
    defer testdata.deinit();
    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x09b0, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0x09be, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0x09b7, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0x09cd, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0x099f, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0x09cd, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0x09b0, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0x09c7, buf[buf_idx..]);
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, true);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(buf[0..buf_idx]);
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 8), cells.len);
        try testing.expectEqual(@as(u16, 0), cells[0].x);
        try testing.expectEqual(@as(u16, 0), cells[1].x);
        try testing.expectEqual(@as(u16, 2), cells[2].x);
        try testing.expectEqual(@as(u16, 2), cells[3].x);
        try testing.expectEqual(@as(u16, 2), cells[4].x);
        try testing.expectEqual(@as(u16, 2), cells[5].x);
        try testing.expectEqual(@as(u16, 2), cells[6].x);
        try testing.expectEqual(@as(u16, 2), cells[7].x);
        try testing.expect(cells[2].x_offset < cells[3].x_offset);
    }
    try testing.expectEqual(@as(usize, 1), count);
}
test "shape box glyphs" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x2500, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0x2501, buf[buf_idx..]);
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(buf[0..buf_idx]);
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        try testing.expectEqual(@as(u32, 2), shaper.hb_buf.getLength());
        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u32, 0x2500), cells[0].glyph_index);
        try testing.expectEqual(@as(u16, 0), cells[0].x);
        try testing.expectEqual(@as(u32, 0x2501), cells[1].glyph_index);
        try testing.expectEqual(@as(u16, 1), cells[1].x);
    }
    try testing.expectEqual(@as(usize, 1), count);
}
test "shape selection boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("a1b2c3d4e5");
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    {
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
            .selection = .{ 0, 9 },
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
    {
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
            .selection = .{ 2, 9 },
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 2), count);
    }
    {
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
            .selection = .{ 0, 3 },
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 2), count);
    }
    {
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
            .selection = .{ 1, 3 },
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 3), count);
    }
    {
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
            .selection = .{ 1, 1 },
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 3), count);
    }
}
test "shape cursor boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("a1b2c3d4e5");
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    {
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
    {
        {
            var shaper = &testdata.shaper;
            var it = shaper.runIterator(.{
                .grid = testdata.grid,
                .cells = state.row_data.get(0).cells.slice(),
                .cursor_x = 0,
            });
            var count: usize = 0;
            while (try it.next(alloc)) |run| {
                count += 1;
                _ = try shaper.shape(run);
            }
            try testing.expectEqual(@as(usize, 2), count);
        }
        {
            var shaper = &testdata.shaper;
            var it = shaper.runIterator(.{
                .grid = testdata.grid,
                .cells = state.row_data.get(0).cells.slice(),
            });
            var count: usize = 0;
            while (try it.next(alloc)) |run| {
                count += 1;
                _ = try shaper.shape(run);
            }
            try testing.expectEqual(@as(usize, 1), count);
        }
    }
    {
        {
            var shaper = &testdata.shaper;
            var it = shaper.runIterator(.{
                .grid = testdata.grid,
                .cells = state.row_data.get(0).cells.slice(),
                .cursor_x = 1,
            });
            var count: usize = 0;
            while (try it.next(alloc)) |run| {
                count += 1;
                _ = try shaper.shape(run);
            }
            try testing.expectEqual(@as(usize, 3), count);
        }
        {
            var shaper = &testdata.shaper;
            var it = shaper.runIterator(.{
                .grid = testdata.grid,
                .cells = state.row_data.get(0).cells.slice(),
            });
            var count: usize = 0;
            while (try it.next(alloc)) |run| {
                count += 1;
                _ = try shaper.shape(run);
            }
            try testing.expectEqual(@as(usize, 1), count);
        }
    }
    {
        {
            var shaper = &testdata.shaper;
            var it = shaper.runIterator(.{
                .grid = testdata.grid,
                .cells = state.row_data.get(0).cells.slice(),
                .cursor_x = 9,
            });
            var count: usize = 0;
            while (try it.next(alloc)) |run| {
                count += 1;
                _ = try shaper.shape(run);
            }
            try testing.expectEqual(@as(usize, 2), count);
        }
        {
            var shaper = &testdata.shaper;
            var it = shaper.runIterator(.{
                .grid = testdata.grid,
                .cells = state.row_data.get(0).cells.slice(),
            });
            var count: usize = 0;
            while (try it.next(alloc)) |run| {
                count += 1;
                _ = try shaper.shape(run);
            }
            try testing.expectEqual(@as(usize, 1), count);
        }
    }
}
test "shape cursor boundary and colored emoji" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    var t = try terminal.Terminal.init(
        io,
        alloc,
        .{ .cols = 3, .rows = 10 },
    );
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("👍🏼");
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    {
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
    {
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
            .cursor_x = 0,
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
    {
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
    {
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
            .cursor_x = 1,
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
    {
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}
test "shape cell attribute change" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    {
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 3 });
        defer t.deinit(alloc);
        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice(">=");
        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
    {
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 3, .rows = 10 });
        defer t.deinit(alloc);
        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice(">");
        s.nextSlice("\x1b[1m");
        s.nextSlice("=");
        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 2), count);
    }
    {
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 3, .rows = 10 });
        defer t.deinit(alloc);
        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice("\x1b[38;2;1;2;3m");
        s.nextSlice(">");
        s.nextSlice("\x1b[38;2;3;2;1m");
        s.nextSlice("=");
        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 2), count);
    }
    {
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 3, .rows = 10 });
        defer t.deinit(alloc);
        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice("\x1b[48;2;1;2;3m");
        s.nextSlice(">");
        s.nextSlice("\x1b[48;2;3;2;1m");
        s.nextSlice("=");
        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
    {
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 3, .rows = 10 });
        defer t.deinit(alloc);
        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice("\x1b[48;2;1;2;3m");
        s.nextSlice(">");
        s.nextSlice("=");
        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}
const TestShaper = struct {
    alloc: Allocator,
    shaper: Shaper,
    grid: *SharedGrid,
    lib: Library,
    pub fn deinit(self: *TestShaper) void {
        self.shaper.deinit();
        self.grid.deinit(self.alloc);
        self.alloc.destroy(self.grid);
        self.lib.deinit();
    }
};
const TestFont = enum {
    inconsolata,
    monaspace_neon,
    arabic,
};
fn testShaper(alloc: Allocator) !TestShaper {
    return try testShaperWithFont(alloc, .inconsolata);
}
fn testShaperWithFont(alloc: Allocator, font_req: TestFont) !TestShaper {
    const testEmoji = font.embedded.emoji;
    const testEmojiText = font.embedded.emoji_text;
    const testFont = switch (font_req) {
        .inconsolata => font.embedded.inconsolata,
        .monaspace_neon => font.embedded.monaspace_neon,
        .arabic => font.embedded.arabic,
    };
    var lib = try Library.init(alloc);
    errdefer lib.deinit();
    var c = Collection.init();
    c.load_options = .{ .library = lib };
    _ = try c.add(alloc, try .init(
        lib,
        testFont,
        .{ .size = .{ .points = 12 } },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .none,
    });
    if (comptime !font.options.backend.hasCoretext()) {
        _ = try c.add(alloc, try .init(
            lib,
            testEmoji,
            .{ .size = .{ .points = 12 } },
        ), .{
            .style = .regular,
            .fallback = false,
            .size_adjustment = .none,
        });
    } else {
        var disco = font.Discover.init(lib);
        defer disco.deinit();
        var disco_it = try disco.discover(alloc, .{
            .family = "Apple Color Emoji",
            .size = 12,
            .monospace = false,
        });
        defer disco_it.deinit();
        var face = (try disco_it.next()).?;
        errdefer face.deinit();
        _ = try c.addDeferred(alloc, face, .{
            .style = .regular,
            .fallback = false,
            .size_adjustment = .none,
        });
    }
    _ = try c.add(alloc, try .init(
        lib,
        testEmojiText,
        .{ .size = .{ .points = 12 } },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .none,
    });
    const grid_ptr = try alloc.create(SharedGrid);
    errdefer alloc.destroy(grid_ptr);
    grid_ptr.* = try .init(alloc, .{ .collection = c });
    errdefer grid_ptr.*.deinit(alloc);
    var shaper = try Shaper.init(alloc, .{
        .features = &.{"dlig"},
    });
    errdefer shaper.deinit();
    return TestShaper{
        .alloc = alloc,
        .shaper = shaper,
        .grid = grid_ptr,
        .lib = lib,
    };
}
fn testShaperWithDiscoveredFont(alloc: Allocator, font_req: [:0]const u8) !TestShaper {
    if (font.Discover == void) return error.SkipZigTest;
    var lib = try Library.init(alloc);
    errdefer lib.deinit();
    var c = Collection.init();
    c.load_options = .{ .library = lib };
    {
        var disco = font.Discover.init(lib);
        defer disco.deinit();
        var disco_it = try disco.discover(alloc, .{
            .family = font_req,
            .size = 12,
            .monospace = false,
        });
        defer disco_it.deinit();
        var face: font.DeferredFace = (try disco_it.next()) orelse return error.FontNotFound;
        errdefer face.deinit();
        var name_buf: [256]u8 = undefined;
        const face_name = face.name(&name_buf) catch "(unknown)";
        if (std.mem.indexOf(u8, face_name, font_req) == null) {
            return error.SkipZigTest;
        }
        _ = try c.add(
            alloc,
            try face.load(lib, .{ .size = .{ .points = 12 } }),
            .{
                .style = .regular,
                .fallback = false,
                .size_adjustment = .none,
            },
        );
    }
    const grid_ptr = try alloc.create(SharedGrid);
    errdefer alloc.destroy(grid_ptr);
    grid_ptr.* = try .init(alloc, .{ .collection = c });
    errdefer grid_ptr.*.deinit(alloc);
    var shaper = try Shaper.init(alloc, .{});
    errdefer shaper.deinit();
    return TestShaper{
        .alloc = alloc,
        .shaper = shaper,
        .grid = grid_ptr,
        .lib = lib,
    };
}
