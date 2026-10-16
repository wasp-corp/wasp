const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const macos = @import("macos");
const font = @import("../main.zig");
const os = @import("../../os/root.zig");
const terminal = @import("../../terminal/main.zig");
const unicode = @import("../../unicode/root.zig");
const Feature = font.shape.Feature;
const FeatureList = font.shape.FeatureList;
const default_features = font.shape.default_features;
const Face = font.Face;
const Collection = font.Collection;
const DeferredFace = font.DeferredFace;
const Group = font.Group;
const GroupCache = font.GroupCache;
const Library = font.Library;
const SharedGrid = font.SharedGrid;
const Style = font.Style;
const Presentation = font.Presentation;
const CFReleaseThread = os.CFReleaseThread;
const global = @import("../../global.zig");
const log = std.log.scoped(.font_shaper);
pub const Shaper = struct {
    alloc: Allocator,
    run_state: RunState,
    features: *macos.foundation.Dictionary,
    features_no_default: *macos.foundation.Dictionary,
    cell_buf: CellBuf,
    typesetter_attr_dict: *macos.foundation.Dictionary,
    cached_fonts: std.ArrayListUnmanaged(?*macos.foundation.Dictionary),
    cached_font_grid: usize,
    cf_release_pool: std.ArrayListUnmanaged(*anyopaque),
    cf_release_thread: *CFReleaseThread,
    cf_release_thr: std.Thread,
    const CellBuf = std.ArrayListUnmanaged(font.shape.Cell);
    const CodepointList = std.ArrayListUnmanaged(Codepoint);
    const Codepoint = struct {
        codepoint: u32,
        cluster: u32,
    };
    const RunState = struct {
        codepoints: CodepointList,
        unichars: std.ArrayListUnmanaged(u16),
        fn init() RunState {
            return .{ .codepoints = .empty, .unichars = .empty };
        }
        fn deinit(self: *RunState, alloc: Allocator) void {
            self.codepoints.deinit(alloc);
            self.unichars.deinit(alloc);
        }
        fn reset(self: *RunState) void {
            self.codepoints.clearRetainingCapacity();
            self.unichars.clearRetainingCapacity();
        }
    };
    const Offset = struct {
        cluster: u32 = 0,
        x: f64 = 0,
    };
    fn makeFeaturesDict(feats: []const Feature) !*macos.foundation.Dictionary {
        const list = try macos.foundation.MutableArray.create();
        defer list.release();
        for (feats) |feat| {
            const value_num: c_int = @intCast(feat.value);
            var key = try macos.foundation.String.createWithBytes(&feat.tag, .ascii, false);
            defer key.release();
            var value = try macos.foundation.Number.create(.int, &value_num);
            defer value.release();
            const dict = try macos.foundation.Dictionary.create(
                &[_]?*const anyopaque{
                    macos.text.c.kCTFontOpenTypeFeatureTag,
                    macos.text.c.kCTFontOpenTypeFeatureValue,
                },
                &[_]?*const anyopaque{ key, value },
            );
            defer dict.release();
            list.appendValue(macos.foundation.Dictionary, dict);
        }
        var dict = try macos.foundation.Dictionary.create(
            &[_]?*const anyopaque{macos.text.c.kCTFontFeatureSettingsAttribute},
            &[_]?*const anyopaque{list},
        );
        errdefer dict.release();
        return dict;
    }
    pub fn init(alloc: Allocator, opts: font.shape.Options) !Shaper {
        var feature_list: FeatureList = .{};
        defer feature_list.deinit(alloc);
        for (opts.features) |feature_str| {
            try feature_list.appendFromString(alloc, feature_str);
        }
        const feats = feature_list.features.items;
        const feats_df = try alloc.alloc(Feature, feats.len + default_features.len);
        defer alloc.free(feats_df);
        @memcpy(feats_df[0..default_features.len], &default_features);
        @memcpy(feats_df[default_features.len..], feats);
        const features = try makeFeaturesDict(feats_df);
        errdefer features.release();
        const features_no_default = try makeFeaturesDict(feats);
        errdefer features_no_default.release();
        var run_state = RunState.init();
        errdefer run_state.deinit(alloc);
        const typesetter_attr_dict = dict: {
            const num = try macos.foundation.Number.create(.int, &0);
            defer num.release();
            break :dict try macos.foundation.Dictionary.create(
                &.{macos.c.kCTTypesetterOptionForcedEmbeddingLevel},
                &.{num},
            );
        };
        errdefer typesetter_attr_dict.release();
        var cf_release_thread = try alloc.create(CFReleaseThread);
        errdefer alloc.destroy(cf_release_thread);
        cf_release_thread.* = try .init(alloc);
        errdefer cf_release_thread.deinit();
        var cf_release_thr = try std.Thread.spawn(
            .{},
            CFReleaseThread.threadMain,
            .{cf_release_thread},
        );
        cf_release_thr.setName(global.io(), "cf_release") catch {};
        return .{
            .alloc = alloc,
            .cell_buf = .empty,
            .run_state = run_state,
            .features = features,
            .features_no_default = features_no_default,
            .typesetter_attr_dict = typesetter_attr_dict,
            .cached_fonts = .empty,
            .cached_font_grid = 0,
            .cf_release_pool = .empty,
            .cf_release_thread = cf_release_thread,
            .cf_release_thr = cf_release_thr,
        };
    }
    pub fn deinit(self: *Shaper) void {
        self.cell_buf.deinit(self.alloc);
        self.run_state.deinit(self.alloc);
        self.features.release();
        self.features_no_default.release();
        self.typesetter_attr_dict.release();
        {
            for (self.cached_fonts.items) |ft| {
                if (ft) |f| f.release();
            }
            self.cached_fonts.deinit(self.alloc);
        }
        if (self.cf_release_pool.items.len > 0) {
            for (self.cf_release_pool.items) |ref| macos.foundation.CFRelease(ref);
            if (comptime !builtin.is_test) log.warn(
                "BUG: CFRelease pool was not empty, releasing remaining objects",
                .{},
            );
        }
        self.cf_release_pool.deinit(self.alloc);
        {
            self.cf_release_thread.stop.notify() catch |err|
                log.err("error notifying cf release thread to stop, may stall err={}", .{err});
            self.cf_release_thr.join();
        }
        self.cf_release_thread.deinit();
        self.alloc.destroy(self.cf_release_thread);
    }
    pub fn endFrame(self: *Shaper) void {
        if (self.cf_release_pool.items.len == 0) return;
        const items = self.cf_release_pool.toOwnedSlice(self.alloc) catch |err| {
            log.warn("error converting release pool to owned slice, slow release err={}", .{err});
            for (self.cf_release_pool.items) |ref| macos.foundation.CFRelease(ref);
            self.cf_release_pool.clearRetainingCapacity();
            return;
        };
        if (self.cf_release_thread.mailbox.push(global.io(), .{ .release = .{
            .refs = items,
            .alloc = self.alloc,
        } }, .{ .forever = {} }) != 0) {
            self.cf_release_thread.wakeup.notify() catch |err| {
                log.warn(
                    "error notifying cf release thread to wake up, may stall err={}",
                    .{err},
                );
            };
            return;
        }
        for (items) |ref| macos.foundation.CFRelease(ref);
        self.alloc.free(items);
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
    pub fn shape(
        self: *Shaper,
        run: font.shape.TextRun,
    ) ![]const font.shape.Cell {
        const state = &self.run_state;
        if (run.font_index.special() != null) {
            self.cell_buf.clearRetainingCapacity();
            try self.cell_buf.ensureTotalCapacity(self.alloc, state.codepoints.items.len);
            for (state.codepoints.items) |entry| {
                if (entry.codepoint == 0) continue;
                self.cell_buf.appendAssumeCapacity(.{
                    .x = @intCast(entry.cluster),
                    .glyph_index = @intCast(entry.codepoint),
                });
            }
            return self.cell_buf.items;
        }
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();
        const attr_dict: *macos.foundation.Dictionary = try self.getFont(
            run.grid,
            run.font_index,
        );
        try self.cf_release_pool.ensureUnusedCapacity(self.alloc, 4);
        const str = try macos.foundation.String.createWithCharactersNoCopy(state.unichars.items);
        self.cf_release_pool.appendAssumeCapacity(str);
        const attr_str = try macos.foundation.AttributedString.create(
            str,
            attr_dict,
        );
        self.cf_release_pool.appendAssumeCapacity(attr_str);
        const typesetter =
            try macos.text.Typesetter.createWithAttributedStringAndOptions(
                attr_str,
                self.typesetter_attr_dict,
            );
        self.cf_release_pool.appendAssumeCapacity(typesetter);
        const line = try typesetter.createLine(.{ .location = 0, .length = 0 });
        self.cf_release_pool.appendAssumeCapacity(line);
        var run_offset: Offset = .{};
        var cell_offset: Offset = .{};
        self.cell_buf.clearRetainingCapacity();
        try self.cell_buf.ensureTotalCapacity(self.alloc, line.getGlyphCount());
        var non_ltr: bool = false;
        const runs = line.getGlyphRuns();
        for (0..runs.getCount()) |run_i| {
            const ctrun = runs.getValueAtIndex(macos.text.Run, run_i);
            const status = ctrun.getStatus();
            if (status.non_monotonic or status.right_to_left) non_ltr = true;
            const glyphs = ctrun.getGlyphsPtr() orelse try ctrun.getGlyphs(alloc);
            const advances = ctrun.getAdvancesPtr() orelse try ctrun.getAdvances(alloc);
            const positions = ctrun.getPositionsPtr() orelse try ctrun.getPositions(alloc);
            const indices = ctrun.getStringIndicesPtr() orelse try ctrun.getStringIndices(alloc);
            assert(glyphs.len == advances.len);
            assert(glyphs.len == positions.len);
            assert(glyphs.len == indices.len);
            for (
                glyphs,
                advances,
                positions,
                indices,
            ) |glyph, advance, position, index| {
                const cluster = state.codepoints.items[index].cluster;
                if (cell_offset.cluster != cluster) {
                    const is_after_glyph_from_current_or_next_clusters =
                        cluster <= run_offset.cluster;
                    const is_first_codepoint_in_cluster = blk: {
                        var i = index;
                        while (i > 0) {
                            i -= 1;
                            const codepoint = state.codepoints.items[i];
                            if (codepoint.codepoint == 0) continue;
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
                const x_offset = position.x - cell_offset.x;
                self.cell_buf.appendAssumeCapacity(.{
                    .x = @intCast(cell_offset.cluster),
                    .x_offset = @intFromFloat(@round(x_offset)),
                    .y_offset = @intFromFloat(@round(position.y)),
                    .glyph_index = glyph,
                });
                run_offset.x += advance.width;
                run_offset.cluster = @max(run_offset.cluster, cluster);
            }
        }
        if (non_ltr) {
            @branchHint(.cold);
            std.mem.sort(
                font.shape.Cell,
                self.cell_buf.items,
                {},
                struct {
                    fn lt(_: void, a: font.shape.Cell, b: font.shape.Cell) bool {
                        return a.x < b.x;
                    }
                }.lt,
            );
        }
        return self.cell_buf.items;
    }
    fn getFont(
        self: *Shaper,
        grid: *font.SharedGrid,
        index: font.Collection.Index,
    ) !*macos.foundation.Dictionary {
        const grid_id: usize = @intFromPtr(grid);
        if (grid_id != self.cached_font_grid) {
            if (self.cached_font_grid > 0) {
                try self.cf_release_pool.ensureUnusedCapacity(
                    self.alloc,
                    self.cached_fonts.items.len,
                );
                for (self.cached_fonts.items) |ft| {
                    if (ft) |f| {
                        self.cf_release_pool.appendAssumeCapacity(f);
                    }
                }
                self.cached_fonts.clearRetainingCapacity();
            }
            self.cached_font_grid = grid_id;
        }
        const index_int = index.int();
        if (self.cached_fonts.items.len <= index_int) {
            try self.cached_fonts.ensureTotalCapacity(self.alloc, index_int + 1);
            while (self.cached_fonts.items.len <= index_int) {
                self.cached_fonts.appendAssumeCapacity(null);
            }
        }
        if (self.cached_fonts.items[index_int]) |cached| return cached;
        try self.cf_release_pool.ensureUnusedCapacity(self.alloc, 2);
        const run_font = font: {
            grid.lock.lockSharedUncancelable(global.io());
            defer grid.lock.unlockShared(global.io());
            const face = try grid.resolver.collection.getFace(index);
            const original = face.font;
            const attrs = if (face.quirks_disable_default_font_features)
                self.features_no_default
            else
                self.features;
            const desc = try macos.text.FontDescriptor.createWithAttributes(attrs);
            self.cf_release_pool.appendAssumeCapacity(desc);
            const copied = try original.copyWithAttributes(0, null, desc);
            errdefer copied.release();
            break :font copied;
        };
        self.cf_release_pool.appendAssumeCapacity(run_font);
        const attr_dict = dict: {
            break :dict try macos.foundation.Dictionary.create(
                &.{macos.text.StringAttribute.font.key()},
                &.{run_font},
            );
        };
        self.cached_fonts.items[index_int] = attr_dict;
        return attr_dict;
    }
    pub const RunIteratorHook = struct {
        shaper: *Shaper,
        pub fn prepare(self: *RunIteratorHook) void {
            self.shaper.run_state.reset();
        }
        pub fn addCodepoint(self: RunIteratorHook, cp: u32, cluster: u32) !void {
            const state = &self.shaper.run_state;
            const pair = cp > 0xFFFF;
            if (pair) {
                try state.unichars.ensureUnusedCapacity(self.shaper.alloc, 2);
                state.unichars.appendNTimesAssumeCapacity(0, 2);
                _ = macos.foundation.stringGetSurrogatePairForLongCharacter(
                    cp,
                    state.unichars.items[state.unichars.items.len - 2 ..][0..2],
                );
            } else {
                try state.unichars.append(self.shaper.alloc, @intCast(cp));
            }
            try state.codepoints.append(self.shaper.alloc, .{
                .codepoint = cp,
                .cluster = cluster,
            });
            if (pair) try state.codepoints.append(self.shaper.alloc, .{
                .codepoint = 0,
                .cluster = cluster,
            });
        }
        pub fn finalize(self: RunIteratorHook) void {
            _ = self;
        }
    };
    fn debugPositions(
        self: *Shaper,
        alloc: Allocator,
        run_offset: Offset,
        run_offset_y: f64,
        cell_offset: Offset,
        cell_offset_y: f64,
        position: macos.graphics.Point,
        index: usize,
    ) !void {
        const state = &self.run_state;
        const x_offset = position.x - cell_offset.x;
        const advance_x_offset = run_offset.x - cell_offset.x;
        const advance_y_offset = run_offset_y - cell_offset_y;
        const x_offset_diff = x_offset - advance_x_offset;
        const y_offset_diff = position.y - advance_y_offset;
        const positions_differ = @abs(x_offset_diff) > 0.0001 or @abs(y_offset_diff) > 0.0001;
        const old_offset_y = position.y - cell_offset_y;
        const position_y_differs = @abs(cell_offset_y) > 0.0001;
        const cluster = state.codepoints.items[index].cluster;
        const cluster_differs = cluster != cell_offset.cluster;
        const extra_debugging = false;
        const is_previous_codepoint_prepend = if (cluster_differs or
            extra_debugging)
        blk: {
            var i = index;
            while (i > 0) {
                i -= 1;
                const codepoint = state.codepoints.items[i];
                if (codepoint.codepoint == 0) continue;
                break :blk unicode.table.get(@intCast(codepoint.codepoint)).grapheme_boundary_class == .prepend;
            }
            break :blk false;
        } else false;
        const formatted_cps = if (positions_differ or
            position_y_differs or
            cluster_differs or
            extra_debugging)
        blk: {
            var allocating = std.Io.Writer.Allocating.init(alloc);
            const writer = &allocating.writer;
            const codepoints = state.codepoints.items;
            var last_cluster: ?u32 = null;
            for (codepoints, 0..) |cp, i| {
                if ((@as(i32, @intCast(cp.cluster)) >= @as(i32, @intCast(cell_offset.cluster)) - 1 and
                    cp.cluster <= cluster + 1) and
                    cp.codepoint != 0)
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
                if ((@as(i32, @intCast(cp.cluster)) >= @as(i32, @intCast(cell_offset.cluster)) - 1 and
                    cp.cluster <= cluster + 1) and
                    cp.codepoint != 0)
                {
                    try writer.print("{u}", .{@as(u21, @intCast(cp.codepoint))});
                }
            }
            break :blk try allocating.toOwnedSlice();
        } else "";
        if (extra_debugging) {
            log.warn("extra debugging of positions index={d} cell_offset.cluster={d} cluster={d} run_offset.cluster={d} diff={d} pos=({d:.2},{d:.2}) run_offset=({d:.2},{d:.2}) cell_offset=({d:.2},{d:.2}) is_prev_prepend={} cps = {s}", .{
                index,
                cell_offset.cluster,
                cluster,
                run_offset.cluster,
                @as(isize, @intCast(cluster)) - @as(isize, @intCast(cell_offset.cluster)),
                x_offset,
                position.y,
                run_offset.x,
                run_offset_y,
                cell_offset.x,
                cell_offset_y,
                is_previous_codepoint_prepend,
                formatted_cps,
            });
        }
        if (positions_differ) {
            log.warn("position differs from advance: cluster={d} pos=({d:.2},{d:.2}) adv=({d:.2},{d:.2}) diff=({d:.2},{d:.2}) cps = {s}", .{
                cluster,
                x_offset,
                position.y,
                advance_x_offset,
                advance_y_offset,
                x_offset_diff,
                y_offset_diff,
                formatted_cps,
            });
        }
        if (position_y_differs) {
            log.warn("position.y differs from old offset.y: cluster={d} pos=({d:.2},{d:.2}) run_offset=({d:.2},{d:.2}) cell_offset=({d:.2},{d:.2}) old offset.y={d:.2} cps = {s}", .{
                cluster,
                x_offset,
                position.y,
                run_offset.x,
                run_offset_y,
                cell_offset.x,
                cell_offset_y,
                old_offset_y,
                formatted_cps,
            });
        }
        if (cluster_differs) {
            log.warn("cell_offset.cluster differs from cluster (potential ligature detected) cell_offset.cluster={d} cluster={d} run_offset.cluster={d} diff={d} pos=({d:.2},{d:.2}) run_offset=({d:.2},{d:.2}) cell_offset=({d:.2},{d:.2}) is_prev_prepend={} cps = {s}", .{
                cell_offset.cluster,
                cluster,
                run_offset.cluster,
                @as(isize, @intCast(cluster)) - @as(isize, @intCast(cell_offset.cluster)),
                x_offset,
                position.y,
                run_offset.x,
                run_offset_y,
                cell_offset.x,
                cell_offset_y,
                is_previous_codepoint_prepend,
                formatted_cps,
            });
        }
    }
};
test "run iterator" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    {
        var t: terminal.Terminal = try .init(testing.io, alloc, .{
            .cols = 5,
            .rows = 3,
        });
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
        var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 3 });
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
        var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 5, .rows = 3 });
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
        while (try it.next(alloc)) |_| count += 1;
        try testing.expectEqual(@as(usize, 3), count);
    }
    for (&[_][]const u8{ "fl", "fi", "st" }) |bad| {
        var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);
        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice(bad);
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
        try testing.expectEqual(@as(usize, 2), count);
    }
}
test "run iterator: empty cells with background set" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    {
        var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);
        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice("\x1b[48;2;255;0;0m");
        s.nextSlice("A");
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
            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 3), cells.len);
        }
        try testing.expect(try it.next(alloc) == null);
    }
}
test "shape" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x1F44D, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0x1F44D, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0x1F3FD, buf[buf_idx..]);
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 3 });
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
        _ = try shaper.shape(run);
    }
    try testing.expectEqual(@as(usize, 1), count);
}
test "shape nerd fonts" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var testdata = try testShaperWithFont(alloc, .nerd_font);
    defer testdata.deinit();
    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(' ', buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0xF024B, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(' ', buf[buf_idx..]);
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 3 });
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
        _ = try shaper.shape(run);
    }
    try testing.expectEqual(@as(usize, 1), count);
}
test "shape inconsolata ligs" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    {
        var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 5, .rows = 3 });
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
        var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 5, .rows = 3 });
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
    var testdata = try testShaperWithFont(alloc, .monaspace_neon);
    defer testdata.deinit();
    {
        var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 5, .rows = 3 });
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
test "shape left-replaced lig in last run" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var testdata = try testShaperWithFont(alloc, .geist_mono);
    defer testdata.deinit();
    {
        var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);
        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice("!==");
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
test "shape left-replaced lig in early run" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var testdata = try testShaperWithFont(alloc, .geist_mono);
    defer testdata.deinit();
    {
        var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);
        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice("!==X");
        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        const run = (try it.next(alloc)).?;
        try testing.expectEqual(@as(usize, 4), run.cells);
        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 2), cells.len);
    }
}
test "shape U+3C9 with JB Mono" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var testdata = try testShaperWithFont(alloc, .jetbrains_mono);
    defer testdata.deinit();
    {
        var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 3 });
        defer t.deinit(alloc);
        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice("\u{03C9} foo");
        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var run_count: usize = 0;
        var cell_count: usize = 0;
        while (try it.next(alloc)) |run| {
            run_count += 1;
            const cells = try shaper.shape(run);
            cell_count += cells.len;
        }
        try testing.expectEqual(@as(usize, 1), run_count);
        try testing.expectEqual(@as(usize, 5), cell_count);
    }
}
test "shape emoji width" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    {
        var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 5, .rows = 3 });
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
            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 1), cells.len);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}
test "shape emoji width long" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);
    var page = t.screens.active.pages.pages.first.?.page();
    var row = page.getRow(1);
    const cell = &row.cells.ptr(page.memory)[0];
    cell.* = .{
        .content_tag = .codepoint,
        .content = .{ .codepoint = .{ .data = 0x1F9D4 } },
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
        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 1), cells.len);
    }
    try testing.expectEqual(@as(usize, 1), count);
}
test "shape variation selector VS15" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x270C, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0xFE0E, buf[buf_idx..]);
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 3 });
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
        try testing.expectEqual(@as(usize, 1), cells.len);
    }
    try testing.expectEqual(@as(usize, 1), count);
}
test "shape variation selector VS16" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x270C, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0xFE0F, buf[buf_idx..]);
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 3 });
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
        try testing.expectEqual(@as(usize, 1), cells.len);
    }
    try testing.expectEqual(@as(usize, 1), count);
}
test "shape with empty cells in between" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 30, .rows = 3 });
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
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode('n', buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0x0308, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0x0308, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode('a', buf[buf_idx..]);
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 30, .rows = 3 });
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
        try testing.expectEqual(@as(u16, 1), cells[3].x);
    }
    try testing.expectEqual(@as(usize, 1), count);
}
test "shape Devanagari string" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var testdata = testShaperWithDiscoveredFont(
        alloc,
        "Arial Unicode MS",
    ) catch return error.SkipZigTest;
    defer testdata.deinit();
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 30, .rows = 3 });
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
    const testing = std.testing;
    const alloc = testing.allocator;
    var testdata = testShaperWithDiscoveredFont(
        alloc,
        "Noto Sans Tai Tham",
    ) catch return error.SkipZigTest;
    defer testdata.deinit();
    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x1a2F, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0x1a70, buf[buf_idx..]);
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 30, .rows = 3 });
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
        const cell_width = run.grid.metrics.cell_width;
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u16, 0), cells[0].x);
        try testing.expectEqual(@as(u16, 0), cells[1].x);
        try testing.expectEqual(@as(i16, @intCast(cell_width)), cells[0].x_offset);
        try testing.expectEqual(@as(i16, 0), cells[1].x_offset);
    }
    try testing.expectEqual(@as(usize, 1), count);
}
test "shape Tai Tham letters (position.y differs from advance)" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var testdata = testShaperWithDiscoveredFont(
        alloc,
        "Noto Sans Tai Tham",
    ) catch return error.SkipZigTest;
    defer testdata.deinit();
    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x1a49, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0x1a60, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0x1a3f, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0x1a69, buf[buf_idx..]);
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 30, .rows = 3 });
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
        try testing.expectEqual(@as(usize, 3), cells.len);
        try testing.expectEqual(@as(u16, 0), cells[0].x);
        try testing.expectEqual(@as(u16, 0), cells[1].x);
        try testing.expectEqual(@as(u16, 0), cells[2].x);
        try testing.expectEqual(@as(i16, -3), cells[2].y_offset);
    }
    try testing.expectEqual(@as(usize, 1), count);
}
test "shape Javanese ligatures" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var testdata = testShaperWithDiscoveredFont(
        alloc,
        "Noto Sans Javanese",
    ) catch return error.SkipZigTest;
    defer testdata.deinit();
    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0xa9a4, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0xa9c0, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0xa9b2, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0xa9b8, buf[buf_idx..]);
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 30, .rows = 3 });
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
        const cell_width = run.grid.metrics.cell_width;
        try testing.expectEqual(@as(usize, 3), cells.len);
        try testing.expectEqual(@as(u16, 0), cells[0].x);
        try testing.expectEqual(@as(u16, 0), cells[1].x);
        try testing.expectEqual(@as(u16, 0), cells[2].x);
        try testing.expect(cells[2].x_offset > 3 * cell_width);
    }
    try testing.expectEqual(@as(usize, 1), count);
}
test "shape Chakma vowel sign with ligature (vowel sign renders first)" {
    const testing = std.testing;
    const alloc = testing.allocator;
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
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 30, .rows = 3 });
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
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 30, .rows = 3 });
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
        try testing.expectEqual(@as(u16, 0), cells[2].x);
        try testing.expectEqual(@as(u16, 0), cells[3].x);
        try testing.expectEqual(@as(u16, 0), cells[4].x);
        try testing.expectEqual(@as(u16, 0), cells[5].x);
        try testing.expectEqual(@as(u16, 0), cells[6].x);
        try testing.expectEqual(@as(u16, 0), cells[7].x);
        try testing.expect(cells[2].x_offset < cells[3].x_offset);
    }
    try testing.expectEqual(@as(usize, 1), count);
}
test "shape box glyphs" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x2500, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode(0x2501, buf[buf_idx..]);
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 3 });
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
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 3 });
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
            .selection = .{ 0, @intCast(t.cols - 1) },
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
            .selection = .{ 2, @intCast(t.cols - 1) },
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
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 3 });
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
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 3, .rows = 10 });
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
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    {
        var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 3 });
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
        var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 3, .rows = 10 });
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
        var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 3, .rows = 10 });
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
        var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 3, .rows = 10 });
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
        var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 3, .rows = 10 });
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
test "shape high plane sprite font codepoint" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var testdata = try testShaper(alloc);
    defer testdata.deinit();
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\u{1FB70}");
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    const run = (try it.next(alloc)).?;
    try testing.expectEqualSlices(
        u16,
        &.{ 0xD83E, 0xDF70 },
        shaper.run_state.unichars.items,
    );
    try testing.expectEqualSlices(
        Shaper.Codepoint,
        &.{
            .{ .codepoint = 0x1FB70, .cluster = 0 },
            .{ .codepoint = 0, .cluster = 0 },
        },
        shaper.run_state.codepoints.items,
    );
    const cells = try shaper.shape(run);
    try testing.expectEqual(1, run.cells);
    try testing.expectEqual(0, run.offset);
    try testing.expectEqual(1, cells.len);
    try testing.expectEqual(0, cells[0].x);
    try testing.expectEqual(0x1FB70, cells[0].glyph_index);
    try testing.expect(run.font_index.special() != null);
    try testing.expectEqual(null, try it.next(alloc));
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
    code_new_roman,
    geist_mono,
    inconsolata,
    jetbrains_mono,
    monaspace_neon,
    nerd_font,
};
fn testShaper(alloc: Allocator) !TestShaper {
    return try testShaperWithFont(alloc, .inconsolata);
}
fn testShaperWithFont(alloc: Allocator, font_req: TestFont) !TestShaper {
    const testEmoji = font.embedded.emoji;
    const testEmojiText = font.embedded.emoji_text;
    const testFont = switch (font_req) {
        .code_new_roman => font.embedded.code_new_roman,
        .inconsolata => font.embedded.inconsolata,
        .geist_mono => font.embedded.geist_mono,
        .jetbrains_mono => font.embedded.jetbrains_mono,
        .monaspace_neon => font.embedded.monaspace_neon,
        .nerd_font => font.embedded.test_nerd_font,
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
    if (font.options.backend != .coretext) {
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
