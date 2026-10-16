const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const fastmem = @import("../fastmem.zig");
const lib = @import("lib.zig");
const color = @import("color.zig");
const cursor = @import("cursor.zig");
const highlight = @import("highlight.zig");
const point = @import("point.zig");
const size = @import("size.zig");
const page = @import("page.zig");
const PageList = @import("PageList.zig");
const Selection = @import("Selection.zig");
const Screen = @import("Screen.zig");
const ScreenSet = @import("ScreenSet.zig");
const Style = @import("style.zig").Style;
const Terminal = @import("Terminal.zig");
pub const RenderState = struct {
    rows: size.CellCountInt,
    cols: size.CellCountInt,
    colors: Colors,
    cursor: Cursor,
    row_data: std.MultiArrayList(Row),
    dirty: Dirty,
    screen: ScreenSet.Key,
    viewport_pin: ?PageList.Pin = null,
    overscan_request: Overscan = .{},
    overscan: Overscan = .{},
    selection_cache: ?SelectionCache = null,
    pending_styles: std.ArrayList(StyleRun) = .empty,
    pub const empty: RenderState = .{
        .rows = 0,
        .cols = 0,
        .colors = .{
            .background = .{ .r = 0, .g = 0, .b = 0 },
            .foreground = .{ .r = 0xff, .g = 0xff, .b = 0xff },
            .cursor = null,
            .palette = color.default,
        },
        .cursor = .{
            .active = .{ .x = 0, .y = 0 },
            .viewport = null,
            .cell = .{},
            .style = undefined,
            .visual_style = .block,
            .password_input = false,
            .visible = true,
            .blinking = false,
        },
        .row_data = .empty,
        .dirty = .false,
        .screen = .primary,
    };
    pub const Colors = struct {
        background: color.RGB,
        foreground: color.RGB,
        cursor: ?color.RGB,
        palette: color.Palette,
    };
    pub const Cursor = struct {
        active: point.Coordinate,
        viewport: ?Viewport,
        cell: page.Cell,
        style: Style,
        visual_style: cursor.Style,
        password_input: bool,
        visible: bool,
        blinking: bool,
        pub const Viewport = struct {
            x: size.CellCountInt,
            y: size.CellCountInt,
            wide_tail: bool,
        };
    };
    pub const Overscan = struct {
        above: size.CellCountInt = 0,
        below: size.CellCountInt = 0,
        pub fn eql(a: Overscan, b: Overscan) bool {
            return a.above == b.above and a.below == b.below;
        }
    };
    pub const Row = struct {
        arena: ArenaAllocator.State,
        pin: PageList.Pin,
        serial: u64,
        raw: page.Row,
        cells: std.MultiArrayList(Cell),
        dirty: bool,
        selection: ?[2]size.CellCountInt,
        highlights: std.ArrayList(Highlight),
        applied_styles: std.ArrayList(StyleRun),
        pub const Id = struct {
            serial: u64,
            y: size.CellCountInt,
            pub fn eql(a: Id, b: Id) bool {
                return a.serial == b.serial and a.y == b.y;
            }
        };
        pub fn id(self: *const Row) Id {
            return .{ .serial = self.serial, .y = self.pin.y };
        }
    };
    pub const Highlight = struct {
        tag: u8,
        range: [2]size.CellCountInt,
    };
    pub const Cell = struct {
        raw: page.Cell,
        grapheme: []const u21,
        style: Style,
    };
    pub const Dirty = lib.Enum(lib.target, &.{
        "false",
        "partial",
        "full",
    });
    const SelectionCache = struct {
        selection: Selection,
        tl_pin: PageList.Pin,
        br_pin: PageList.Pin,
    };
    pub const StyleRun = struct {
        y: size.CellCountInt,
        start: size.CellCountInt,
        end: size.CellCountInt,
        style: Style,
    };
    pub fn deinit(self: *RenderState, alloc: Allocator) void {
        for (
            self.row_data.items(.arena),
            self.row_data.items(.cells),
            self.row_data.items(.applied_styles),
        ) |state, *cells, *applied| {
            var arena: ArenaAllocator = state.promote(alloc);
            arena.deinit();
            cells.deinit(alloc);
            applied.deinit(alloc);
        }
        self.row_data.deinit(alloc);
        self.pending_styles.deinit(alloc);
    }
    pub fn update(
        self: *RenderState,
        alloc: Allocator,
        t: *Terminal,
    ) Allocator.Error!void {
        try self.beginUpdate(alloc, t);
        self.endUpdate();
    }
    pub fn beginUpdate(
        self: *RenderState,
        alloc: Allocator,
        t: *Terminal,
    ) Allocator.Error!void {
        const s: *Screen = t.screens.active;
        const viewport_pin = s.pages.getTopLeft(.viewport);
        const above_req: usize = self.overscan_request.above;
        const below_req: usize = self.overscan_request.below;
        const row_data_len: usize = above_req + s.pages.rows + below_req;
        const top: struct { pin: PageList.Pin, above: usize } = if (above_req == 0)
            .{ .pin = viewport_pin, .above = 0 }
        else switch (viewport_pin.upOverflow(above_req)) {
            .offset => |p| .{ .pin = p, .above = above_req },
            .overflow => |o| .{ .pin = o.end, .above = above_req - o.remaining },
        };
        const below: usize = if (below_req == 0) 0 else below: {
            const bottom = viewport_pin.down(s.pages.rows - 1).?;
            break :below switch (bottom.downOverflow(below_req)) {
                .offset => below_req,
                .overflow => |o| below_req - o.remaining,
            };
        };
        const first: usize = above_req - top.above;
        const redraw = redraw: {
            if (t.screens.active_key != self.screen) break :redraw true;
            {
                const Int = @typeInfo(Terminal.Dirty).@"struct".backing_integer.?;
                const v: Int = @bitCast(t.flags.dirty);
                if (v > 0) break :redraw true;
            }
            {
                const Int = @typeInfo(Screen.Dirty).@"struct".backing_integer.?;
                const v: Int = @bitCast(t.screens.active.dirty);
                if (v > 0) break :redraw true;
            }
            if (self.rows != s.pages.rows or
                self.cols != s.pages.cols)
            {
                break :redraw true;
            }
            if (self.row_data.len != row_data_len) break :redraw true;
            if (self.overscan.above != top.above or
                self.overscan.below != below) break :redraw true;
            if (self.viewport_pin) |old| {
                if (!old.eql(viewport_pin)) break :redraw true;
            }
            break :redraw false;
        };
        self.rows = s.pages.rows;
        self.cols = s.pages.cols;
        self.viewport_pin = viewport_pin;
        self.cursor.active = .{ .x = s.cursor.x, .y = s.cursor.y };
        self.cursor.cell = s.cursor.page_cell.*;
        self.cursor.style = s.cursor.style;
        self.cursor.visual_style = s.cursor.cursor_style;
        self.cursor.password_input = t.flags.password_input;
        self.cursor.visible = t.modes.get(.cursor_visible);
        self.cursor.blinking = t.modes.get(.cursor_blinking);
        self.cursor.viewport = null;
        self.colors.cursor = t.colors.cursor.get();
        if (redraw) self.colors.palette = t.colors.palette.current;
        bg_fg: {
            const bg = t.colors.background.get() orelse break :bg_fg;
            const fg = t.colors.foreground.get() orelse break :bg_fg;
            if (t.modes.get(.reverse_colors)) {
                self.colors.background = fg;
                self.colors.foreground = bg;
            } else {
                self.colors.background = bg;
                self.colors.foreground = fg;
            }
        }
        if (self.row_data.len != row_data_len) {
            @branchHint(.unlikely);
            if (self.row_data.len < row_data_len) {
                const old_len = self.row_data.len;
                try self.row_data.resize(alloc, row_data_len);
                var row_data = self.row_data.slice();
                for (old_len..row_data_len) |y| {
                    row_data.set(y, .{
                        .arena = .{},
                        .pin = undefined,
                        .serial = undefined,
                        .raw = undefined,
                        .cells = .empty,
                        .dirty = true,
                        .selection = null,
                        .highlights = .empty,
                        .applied_styles = .empty,
                    });
                }
            } else {
                const row_data = self.row_data.slice();
                for (
                    row_data.items(.arena)[row_data_len..],
                    row_data.items(.cells)[row_data_len..],
                    row_data.items(.applied_styles)[row_data_len..],
                ) |state, *cell, *applied| {
                    var arena: ArenaAllocator = state.promote(alloc);
                    arena.deinit();
                    cell.deinit(alloc);
                    applied.deinit(alloc);
                }
                self.row_data.shrinkRetainingCapacity(row_data_len);
            }
        }
        const row_data = self.row_data.slice();
        const row_arenas = row_data.items(.arena);
        const row_pins = row_data.items(.pin);
        const row_serials = row_data.items(.serial);
        const row_rows = row_data.items(.raw);
        const row_cells = row_data.items(.cells);
        const row_sels = row_data.items(.selection);
        const row_highlights = row_data.items(.highlights);
        const row_dirties = row_data.items(.dirty);
        const row_applied = row_data.items(.applied_styles);
        if (redraw) self.pending_styles.clearRetainingCapacity();
        const builder: RowBuilder = .{
            .alloc = alloc,
            .cols = self.cols,
            .arenas = row_arenas,
            .raws = row_rows,
            .cells = row_cells,
            .sels = row_sels,
            .highlights = row_highlights,
            .dirties = row_dirties,
            .pending_styles = &self.pending_styles,
            .applied_styles = row_applied,
        };
        const row_data_end: usize = first + top.above + self.rows + below;
        var y: usize = first;
        var any_dirty: bool = false;
        var page_it = top.pin.pageIterator(.right_down, null);
        while (y < row_data_end) {
            const chunk = page_it.next() orelse break;
            const node = chunk.node;
            const node_serial = node.serial;
            const p: *page.Page = node.page();
            const take: usize = @min(
                @as(usize, chunk.end - chunk.start),
                row_data_end - y,
            );
            if (self.cursor.viewport == null and
                node == s.cursor.page_pin.node)
            cursor: {
                const cy = s.cursor.page_pin.y;
                if (cy < chunk.start or cy >= chunk.start + take) break :cursor;
                const idx = y + (cy - chunk.start);
                const vp_start = self.viewportStart();
                if (idx < vp_start or idx >= vp_start + self.rows) break :cursor;
                self.cursor.viewport = .{
                    .y = @intCast(idx - vp_start),
                    .x = s.cursor.x,
                    .wide_tail = if (s.cursor.x > 0)
                        s.cursorCellLeft(1).wide == .wide
                    else
                        false,
                };
            }
            const page_dirty = p.dirty;
            if (page_dirty) p.dirty = false;
            const page_rows: []page.Row = p.rows.ptr(p.memory)[chunk.start..][0..take];
            assert(p.size.cols == self.cols);
            if (redraw or
                row_pins[y].node != node or
                row_pins[y].y != chunk.start or
                row_serials[y] != node_serial or
                row_pins[y + take - 1].node != node or
                row_pins[y + take - 1].y != chunk.start + take - 1 or
                row_serials[y + take - 1] != node_serial)
            {
                for (
                    row_pins[y..][0..take],
                    row_serials[y..][0..take],
                    chunk.start..,
                ) |*pin, *serial, py| {
                    pin.* = .{ .node = node, .y = @intCast(py) };
                    serial.* = node_serial;
                }
            }
            if (!redraw and !page_dirty) {
                var i: usize = 0;
                while (take - i >= RowDirtyMask.group_len) : (i += RowDirtyMask.group_len) {
                    if (RowDirtyMask.match(page_rows, i)) {
                        @branchHint(.likely);
                        continue;
                    }
                    for (page_rows[i..][0..RowDirtyMask.group_len], i..) |*page_row, j| {
                        if (!page_row.dirty) continue;
                        page_row.dirty = false;
                        any_dirty = true;
                        try builder.row(p, page_row, y + j);
                    }
                }
                while (i < take) : (i += 1) {
                    const page_row = &page_rows[i];
                    if (!page_row.dirty) continue;
                    page_row.dirty = false;
                    any_dirty = true;
                    try builder.row(p, page_row, y + i);
                }
            } else {
                any_dirty = true;
                for (page_rows, 0..) |*page_row, i| {
                    page_row.dirty = false;
                    try builder.row(p, page_row, y + i);
                }
            }
            y += take;
        }
        assert(y == row_data_end);
        self.overscan = .{
            .above = @intCast(top.above),
            .below = @intCast(below),
        };
        if (s.selection) |*sel| selection: {
            @branchHint(.unlikely);
            const cache: *const SelectionCache = cache: {
                if (self.selection_cache) |*c| cache_check: {
                    if (redraw) break :cache_check;
                    if (!c.selection.eql(sel.*)) break :cache_check;
                    if (!any_dirty) break :selection;
                    break :cache c;
                }
                const tl_pin = sel.topLeft(s);
                const br_pin = sel.bottomRight(s);
                self.selection_cache = .{
                    .selection = .init(tl_pin, br_pin, sel.rectangle),
                    .tl_pin = tl_pin,
                    .br_pin = br_pin,
                };
                break :cache &self.selection_cache.?;
            };
            const tl = s.pages.pointFromPin(.screen, cache.tl_pin).?.screen;
            const br_pin: PageList.Pin = if (!sel.rectangle and
                cache.br_pin.rowAndCell().cell.wide == .spacer_head)
                cache.br_pin.rightWrap(1) orelse cache.br_pin
            else
                cache.br_pin;
            const br = s.pages.pointFromPin(.screen, br_pin).?.screen;
            const range = self.rowDataRange();
            for (
                row_pins[range.start..range.end],
                row_sels[range.start..range.end],
                row_dirties[range.start..range.end],
            ) |pin, *sel_bounds, *dirty| {
                const p = s.pages.pointFromPin(.screen, pin).?.screen;
                const row_sel = sel.containedRowCached(
                    s,
                    cache.tl_pin,
                    br_pin,
                    pin,
                    tl,
                    br,
                    p,
                ) orelse {
                    if (sel_bounds.* != null) {
                        sel_bounds.* = null;
                        dirty.* = true;
                        any_dirty = true;
                    }
                    continue;
                };
                const start = row_sel.start();
                const end = row_sel.end();
                assert(start.node == end.node);
                assert(start.x <= end.x);
                assert(start.y == end.y);
                const start_x = if (start.x > 0 and
                    start.rowAndCell().cell.wide == .spacer_tail)
                    start.x - 1
                else
                    start.x;
                sel_bounds.* = .{ start_x, end.x };
            }
        }
        if (redraw) {
            self.screen = t.screens.active_key;
            self.dirty = .full;
        } else if (any_dirty and self.dirty == .false) {
            self.dirty = .partial;
        }
        t.flags.dirty = .{};
        s.dirty = .{};
    }
    pub fn endUpdate(self: *RenderState) void {
        if (self.pending_styles.items.len == 0) return;
        const row_data = self.row_data.slice();
        const row_cells = row_data.items(.cells);
        const row_applied = row_data.items(.applied_styles);
        const runs = self.pending_styles.items;
        var i: usize = 0;
        while (i < runs.len) {
            const y = runs[i].y;
            var j = i + 1;
            while (j < runs.len and runs[j].y == y) j += 1;
            const segment = runs[i..j];
            i = j;
            if (y >= row_cells.len) continue;
            const applied = &row_applied[y];
            if (runsEql(applied.items, segment)) continue;
            for (segment) |run| {
                const styles = row_cells[run.y].slice().items(.style);
                const end = @min(run.end, styles.len);
                const start = @min(run.start, end);
                fillStyles(styles[start..end], run.style);
            }
            applied.clearRetainingCapacity();
            if (applied.capacity >= segment.len) {
                applied.appendSliceAssumeCapacity(segment);
            }
        }
        self.pending_styles.clearRetainingCapacity();
    }
    pub fn clean(self: *RenderState) void {
        self.dirty = .false;
        @memset(self.row_data.items(.dirty), false);
    }
    pub fn viewportStart(self: *const RenderState) usize {
        return self.overscan_request.above;
    }
    pub fn viewportY(self: *const RenderState, index: usize) isize {
        return @as(isize, @intCast(index)) - @as(isize, @intCast(self.viewportStart()));
    }
    pub const RowDataRange = struct {
        start: usize,
        end: usize,
    };
    pub fn rowDataRange(self: *const RenderState) RowDataRange {
        const vp = self.viewportStart();
        return .{
            .start = vp - self.overscan.above,
            .end = vp + self.rows + self.overscan.below,
        };
    }
    fn fillStyles(dst: []Style, value: Style) void {
        const elem_size = @sizeOf(Style);
        comptime assert(elem_size >= 16 and elem_size <= 32);
        const V = @Vector(16, u8);
        const src: *align(@alignOf(Style)) const [elem_size]u8 = @ptrCast(&value);
        const lo = @as(*align(4) const V, @ptrCast(src[0..16])).*;
        const hi = @as(*align(1) const V, @ptrCast(src[elem_size - 16 ..][0..16])).*;
        const dst_bytes = std.mem.sliceAsBytes(dst);
        var off: usize = 0;
        for (0..dst.len) |_| {
            @as(*align(1) V, @ptrCast(dst_bytes[off..][0..16])).* = lo;
            @as(*align(1) V, @ptrCast(dst_bytes[off + elem_size - 16 ..][0..16])).* = hi;
            off += elem_size;
        }
    }
    fn runsEql(a: []const StyleRun, b: []const StyleRun) bool {
        if (a.len != b.len) return false;
        for (a, b) |ar, br| {
            if (ar.start != br.start or
                ar.end != br.end or
                !ar.style.eql(br.style)) return false;
        }
        return true;
    }
    pub fn updateHighlightsFlattened(
        self: *RenderState,
        alloc: Allocator,
        tag: u8,
        hls: []const highlight.Flattened,
    ) Allocator.Error!void {
        if (hls.len == 0) return;
        var any_dirty: bool = false;
        const row_data = self.row_data.slice();
        const row_arenas = row_data.items(.arena);
        const row_dirties = row_data.items(.dirty);
        const row_pins = row_data.items(.pin);
        const row_serials = row_data.items(.serial);
        const row_highlights_slice = row_data.items(.highlights);
        const range = self.rowDataRange();
        for (
            row_arenas[range.start..range.end],
            row_pins[range.start..range.end],
            row_serials[range.start..range.end],
            row_highlights_slice[range.start..range.end],
            row_dirties[range.start..range.end],
        ) |*row_arena, row_pin, row_serial, *row_highlights, *dirty| {
            for (hls) |hl| {
                const chunks_slice = hl.chunks.slice();
                const nodes = chunks_slice.items(.node);
                const serials = chunks_slice.items(.serial);
                const starts = chunks_slice.items(.start);
                const ends = chunks_slice.items(.end);
                for (0.., nodes) |i, node| {
                    if (node != row_pin.node or
                        serials[i] != row_serial or
                        row_pin.y < starts[i] or
                        row_pin.y >= ends[i]) continue;
                    var arena = row_arena.promote(alloc);
                    defer row_arena.* = arena.state;
                    const arena_alloc = arena.allocator();
                    try row_highlights.append(
                        arena_alloc,
                        .{
                            .tag = tag,
                            .range = .{
                                if (i == 0 and
                                    row_pin.y == starts[0])
                                    hl.top_x
                                else
                                    0,
                                if (i == nodes.len - 1 and
                                    row_pin.y == ends[nodes.len - 1] - 1)
                                    hl.bot_x
                                else
                                    self.cols - 1,
                            },
                        },
                    );
                    dirty.* = true;
                    any_dirty = true;
                }
            }
        }
        if (any_dirty and self.dirty == .false) self.dirty = .partial;
    }
    pub const StringMap = std.ArrayListUnmanaged(point.Coordinate);
    pub fn string(
        self: *const RenderState,
        writer: *std.Io.Writer,
        map: ?struct {
            alloc: Allocator,
            map: *StringMap,
        },
    ) (Allocator.Error || std.Io.Writer.Error)!void {
        const row_slice = self.row_data.slice();
        const vp_start = self.viewportStart();
        const row_rows = row_slice.items(.raw)[vp_start..][0..self.rows];
        const row_cells = row_slice.items(.cells)[vp_start..][0..self.rows];
        for (
            0..,
            row_rows,
            row_cells,
        ) |y, row, cells| {
            const cells_slice = cells.slice();
            for (
                0..,
                cells_slice.items(.raw),
                cells_slice.items(.grapheme),
            ) |x, cell, graphemes| {
                var len: usize = std.unicode.utf8CodepointSequenceLength(cell.codepoint()) catch
                    return error.WriteFailed;
                try writer.print("{u}", .{cell.codepoint()});
                if (cell.hasGrapheme()) {
                    for (graphemes) |cp| {
                        len += std.unicode.utf8CodepointSequenceLength(cp) catch
                            return error.WriteFailed;
                        try writer.print("{u}", .{cp});
                    }
                }
                if (map) |m| try m.map.appendNTimes(m.alloc, .{
                    .x = @intCast(x),
                    .y = @intCast(y),
                }, len);
            }
            if (!row.wrap) {
                try writer.writeAll("\n");
                if (map) |m| try m.map.append(m.alloc, .{
                    .x = @intCast(cells_slice.len),
                    .y = @intCast(y),
                });
            }
        }
    }
    pub const CellSet = std.AutoArrayHashMapUnmanaged(point.Coordinate, void);
    pub fn linkCells(
        self: *const RenderState,
        alloc: Allocator,
        viewport_point: point.Coordinate,
    ) Allocator.Error!CellSet {
        var result: CellSet = .empty;
        errdefer result.deinit(alloc);
        const row_slice = self.row_data.slice();
        const vp_start = self.viewportStart();
        const row_pins = row_slice.items(.pin)[vp_start..][0..self.rows];
        const row_cells = row_slice.items(.cells)[vp_start..][0..self.rows];
        if (viewport_point.x >= self.cols or
            viewport_point.y >= self.rows) return result;
        const link_pin: PageList.Pin = row_pins[viewport_point.y];
        const link_page: *page.Page = link_pin.node.page();
        const link = link: {
            const rac = link_page.getRowAndCell(
                viewport_point.x,
                link_pin.y,
            );
            if (!rac.cell.hyperlink) {
                @branchHint(.likely);
                return result;
            }
            const link_id = link_page.lookupHyperlink(rac.cell) orelse
                return result;
            break :link link_page.hyperlink_set.get(
                link_page.memory,
                link_id,
            );
        };
        for (
            0..,
            row_pins,
            row_cells,
        ) |y, pin, cells| {
            for (0.., cells.items(.raw)) |x, cell| {
                if (!cell.hyperlink) continue;
                const other_page: *page.Page = pin.node.page();
                const other = link: {
                    const rac = other_page.getRowAndCell(x, pin.y);
                    const link_id = other_page.lookupHyperlink(rac.cell) orelse continue;
                    break :link other_page.hyperlink_set.get(
                        other_page.memory,
                        link_id,
                    );
                };
                if (link.eql(
                    link_page.memory,
                    other,
                    other_page.memory,
                )) try result.put(alloc, .{
                    .y = @intCast(y),
                    .x = @intCast(x),
                }, {});
            }
        }
        return result;
    }
};
const scan_group_len = 8;
const RowDirtyMask = page.Mask(
    page.Row,
    &.{"dirty"},
    scan_group_len,
);
const CellSpecialMask = page.Mask(page.Cell, &.{
    "content_tag",
    "style_id",
}, scan_group_len);
const RowBuilder = struct {
    alloc: Allocator,
    cols: usize,
    arenas: []ArenaAllocator.State,
    raws: []page.Row,
    cells: []std.MultiArrayList(RenderState.Cell),
    sels: []?[2]size.CellCountInt,
    highlights: []std.ArrayList(RenderState.Highlight),
    dirties: []bool,
    pending_styles: *std.ArrayList(RenderState.StyleRun),
    applied_styles: []std.ArrayList(RenderState.StyleRun),
    fn row(
        b: *const RowBuilder,
        p: *page.Page,
        page_row: *const page.Row,
        vy: usize,
    ) Allocator.Error!void {
        var arena = b.arenas[vy].promote(b.alloc);
        defer b.arenas[vy] = arena.state;
        if (b.cells[vy].len > 0) {
            _ = arena.reset(.retain_capacity);
            b.sels[vy] = null;
            b.highlights[vy] = .empty;
        }
        b.dirties[vy] = true;
        const page_cells: []const page.Cell = page_row.cells.ptr(p.memory)[0..b.cols];
        b.raws[vy] = page_row.*;
        const cells: *std.MultiArrayList(RenderState.Cell) = &b.cells[vy];
        if (cells.len != b.cols) {
            b.applied_styles[vy].clearRetainingCapacity();
            try cells.resize(b.alloc, b.cols);
        }
        const cells_slice = cells.slice();
        fastmem.copy(
            page.Cell,
            cells_slice.items(.raw),
            page_cells,
        );
        if (!page_row.managedMemory()) return;
        const arena_alloc = arena.allocator();
        const cells_grapheme = cells_slice.items(.grapheme);
        const n = page_cells.len;
        const runs_start = b.pending_styles.items.len;
        var x: usize = 0;
        scan: while (x < n) {
            while (n - x >= CellSpecialMask.group_len) {
                if (!CellSpecialMask.match(page_cells, x)) break;
                x += CellSpecialMask.group_len;
            }
            while (true) {
                if (x >= n) break :scan;
                if (!CellSpecialMask.matchScalar(page_cells[x])) break;
                x += 1;
            }
            const page_cell = &page_cells[x];
            switch (page_cell.content_tag) {
                .codepoint => {
                    @branchHint(.likely);
                    const sid = page_cell.style_id;
                    assert(sid > 0); 
                    const style_val: Style = p.styles.get(p.memory, sid).*;
                    const pattern = CellSpecialMask.pattern(page_cell.*);
                    const start = x;
                    x += 1;
                    while (n - x >= CellSpecialMask.group_len) {
                        if (!CellSpecialMask.eql(
                            page_cells,
                            x,
                            pattern,
                        )) break;
                        x += CellSpecialMask.group_len;
                    }
                    while (x < n) : (x += 1) {
                        if (!CellSpecialMask.eqlScalar(
                            page_cells[x],
                            pattern,
                        )) break;
                    }
                    try b.pending_styles.append(b.alloc, .{
                        .y = @intCast(vy),
                        .start = @intCast(start),
                        .end = @intCast(x),
                        .style = style_val,
                    });
                },
                .codepoint_grapheme => {
                    if (page_cell.style_id > 0) {
                        try b.pending_styles.append(b.alloc, .{
                            .y = @intCast(vy),
                            .start = @intCast(x),
                            .end = @intCast(x + 1),
                            .style = p.styles.get(
                                p.memory,
                                page_cell.style_id,
                            ).*,
                        });
                    }
                    cells_grapheme[x] = try arena_alloc.dupe(
                        u21,
                        p.lookupGrapheme(page_cell) orelse &.{},
                    );
                    x += 1;
                },
                .bg_color_rgb, .bg_color_palette => {
                    const style_val: Style = switch (page_cell.content_tag) {
                        .bg_color_rgb => .{ .bg_color = .{ .rgb = .{
                            .r = page_cell.content.color_rgb.r,
                            .g = page_cell.content.color_rgb.g,
                            .b = page_cell.content.color_rgb.b,
                        } } },
                        .bg_color_palette => .{ .bg_color = .{
                            .palette = page_cell.content.color_palette.data,
                        } },
                        else => unreachable,
                    };
                    const first_bits = CellSpecialMask.bits(page_cell.*);
                    const start = x;
                    x += 1;
                    while (n - x >= CellSpecialMask.group_len) {
                        if (!CellSpecialMask.eqlExact(
                            page_cells,
                            x,
                            first_bits,
                        )) break;
                        x += CellSpecialMask.group_len;
                    }
                    while (x < n) : (x += 1) {
                        if (CellSpecialMask.bits(page_cells[x]) != first_bits)
                            break;
                    }
                    try b.pending_styles.append(b.alloc, .{
                        .y = @intCast(vy),
                        .start = @intCast(start),
                        .end = @intCast(x),
                        .style = style_val,
                    });
                },
            }
        }
        const runs_added = b.pending_styles.items.len - runs_start;
        if (runs_added > 0) try b.applied_styles[vy].ensureTotalCapacity(
            b.alloc,
            runs_added,
        );
    }
};
test "styled" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    try t.decaln();
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
}
test "basic text" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("ABCD");
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    const row_data = state.row_data.slice();
    try testing.expectEqual(3, row_data.len);
    const cells = row_data.items(.cells);
    try testing.expectEqual(10, cells[0].len);
    try testing.expectEqual(10, cells[1].len);
    try testing.expectEqual(10, cells[2].len);
    try testing.expectEqual('A', cells[0].get(0).raw.codepoint());
    try testing.expectEqual('B', cells[0].get(1).raw.codepoint());
    try testing.expectEqual('C', cells[0].get(2).raw.codepoint());
    try testing.expectEqual('D', cells[0].get(3).raw.codepoint());
    try testing.expectEqual(0, cells[0].get(4).raw.codepoint());
}
test "styled text" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[1mA"); 
    s.nextSlice("\x1b[0;3mB"); 
    s.nextSlice("\x1b[0;4mC"); 
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    const row_data = state.row_data.slice();
    try testing.expectEqual(3, row_data.len);
    const cells = row_data.items(.cells);
    try testing.expectEqual(10, cells[0].len);
    try testing.expectEqual(10, cells[1].len);
    try testing.expectEqual(10, cells[2].len);
    {
        const cell = cells[0].get(0);
        try testing.expectEqual('A', cell.raw.codepoint());
        try testing.expect(cell.style.flags.bold);
    }
    {
        const cell = cells[0].get(1);
        try testing.expectEqual('B', cell.raw.codepoint());
        try testing.expect(!cell.style.flags.bold);
        try testing.expect(cell.style.flags.italic);
    }
    try testing.expectEqual('C', cells[0].get(2).raw.codepoint());
    try testing.expectEqual(0, cells[0].get(3).raw.codepoint());
}
fn testCompareStates(
    incremental: *const RenderState,
    fresh: *const RenderState,
) !void {
    const testing = std.testing;
    const StaleOkMask = page.Mask(page.Row, &.{
        "wrap",
        "wrap_continuation",
        "semantic_prompt",
        "dirty",
    }, 1);
    try testing.expectEqual(fresh.rows, incremental.rows);
    try testing.expectEqual(fresh.cols, incremental.cols);
    try testing.expectEqual(fresh.cursor.active, incremental.cursor.active);
    try testing.expectEqual(fresh.cursor.viewport, incremental.cursor.viewport);
    try testing.expectEqual(
        @as(page.Cell.Backing, @bitCast(fresh.cursor.cell)),
        @as(page.Cell.Backing, @bitCast(incremental.cursor.cell)),
    );
    try testing.expectEqual(fresh.overscan, incremental.overscan);
    try testing.expectEqual(fresh.rowDataRange(), incremental.rowDataRange());
    const range = fresh.rowDataRange();
    const inc_data = incremental.row_data.slice();
    const new_data = fresh.row_data.slice();
    try testing.expectEqual(new_data.len, inc_data.len);
    for (range.start..range.end) |y| {
        errdefer std.log.warn("mismatch on row y={}", .{y});
        const inc_pin = inc_data.items(.pin)[y];
        const new_pin = new_data.items(.pin)[y];
        try testing.expectEqual(new_pin.node, inc_pin.node);
        try testing.expectEqual(new_pin.y, inc_pin.y);
        const inc_row = inc_data.items(.raw)[y];
        const new_row = new_data.items(.raw)[y];
        try testing.expectEqual(
            StaleOkMask.strip(new_row),
            StaleOkMask.strip(inc_row),
        );
        const inc_cells = inc_data.items(.cells)[y].slice();
        const new_cells = new_data.items(.cells)[y].slice();
        try testing.expectEqual(new_cells.len, inc_cells.len);
        const managed = new_row.managedMemory();
        for (0..new_cells.len) |x| {
            errdefer std.log.warn("mismatch on cell x={}", .{x});
            const inc_cell = inc_cells.items(.raw)[x];
            const new_cell = new_cells.items(.raw)[x];
            try testing.expectEqual(
                @as(page.Cell.Backing, @bitCast(new_cell)),
                @as(page.Cell.Backing, @bitCast(inc_cell)),
            );
            if (new_cell.style_id != 0 or
                (managed and switch (new_cell.content_tag) {
                    .bg_color_rgb, .bg_color_palette => true,
                    else => false,
                }))
            {
                try testing.expect(std.meta.eql(
                    new_cells.items(.style)[x],
                    inc_cells.items(.style)[x],
                ));
            }
            if (new_cell.content_tag == .codepoint_grapheme) {
                try testing.expectEqualSlices(
                    u21,
                    new_cells.items(.grapheme)[x],
                    inc_cells.items(.grapheme)[x],
                );
            }
        }
    }
}
test "incremental updates match full rebuild" {
    try testIncrementalMatchesFresh(.{});
}
test "incremental updates match full rebuild with overscan" {
    try testIncrementalMatchesFresh(.{ .above = 2, .below = 1 });
}
fn testIncrementalMatchesFresh(request: RenderState.Overscan) !void {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var prng = std.Random.DefaultPrng.init(0xB0BA_CAFE);
    const rand = prng.random();
    var t = try Terminal.init(io, alloc, .{
        .cols = 20,
        .rows = 8,
        .max_scrollback_bytes = 500,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    var inc: RenderState = .empty;
    defer inc.deinit(alloc);
    inc.overscan_request = request;
    var buf: [64]u8 = undefined;
    for (0..300) |_| {
        for (0..rand.intRangeAtMost(usize, 1, 6)) |_| {
            switch (rand.intRangeAtMost(u8, 0, 18)) {
                0, 1, 2 => for (0..rand.intRangeAtMost(usize, 1, 30)) |_| {
                    s.nextSlice(&.{rand.intRangeAtMost(u8, 'A', 'Z')});
                },
                3, 4 => for (0..rand.intRangeAtMost(usize, 1, 10)) |_| {
                    s.nextSlice("x\r\n");
                },
                5 => s.nextSlice(try std.fmt.bufPrint(&buf, "\x1b[{};{}H", .{
                    rand.intRangeAtMost(u16, 1, 8),
                    rand.intRangeAtMost(u16, 1, 20),
                })),
                6 => s.nextSlice(switch (rand.intRangeAtMost(u8, 0, 3)) {
                    0 => "\x1b[1m",
                    1 => "\x1b[48;2;30;60;90m",
                    2 => "\x1b[38;5;120m",
                    else => "\x1b[0m",
                }),
                7 => s.nextSlice(switch (rand.intRangeAtMost(u8, 0, 4)) {
                    0 => "\x1b[K",
                    1 => "\x1b[1K",
                    2 => "\x1b[J",
                    3 => "\x1b[2J",
                    else => "\x1b[3J",
                }),
                8 => s.nextSlice(try std.fmt.bufPrint(&buf, "\x1b[{}L", .{
                    rand.intRangeAtMost(u16, 1, 4),
                })),
                9 => s.nextSlice(try std.fmt.bufPrint(&buf, "\x1b[{}M", .{
                    rand.intRangeAtMost(u16, 1, 4),
                })),
                10 => s.nextSlice(try std.fmt.bufPrint(&buf, "\x1b[{}S", .{
                    rand.intRangeAtMost(u16, 1, 4),
                })),
                11 => s.nextSlice(try std.fmt.bufPrint(&buf, "\x1b[{}T", .{
                    rand.intRangeAtMost(u16, 1, 4),
                })),
                12 => {
                    const top = rand.intRangeAtMost(u16, 1, 4);
                    const bot = rand.intRangeAtMost(u16, top + 1, 8);
                    s.nextSlice(try std.fmt.bufPrint(
                        &buf,
                        "\x1b[{};{}r",
                        .{ top, bot },
                    ));
                },
                13 => s.nextSlice(try std.fmt.bufPrint(&buf, "\x1b[{}@", .{
                    rand.intRangeAtMost(u16, 1, 5),
                })),
                14 => s.nextSlice(try std.fmt.bufPrint(&buf, "\x1b[{}P", .{
                    rand.intRangeAtMost(u16, 1, 5),
                })),
                15 => s.nextSlice("\x1bM"),
                16 => s.nextSlice("字👨‍👩‍👧"),
                17 => s.nextSlice(if (rand.boolean())
                    "\x1b[?1049h"
                else
                    "\x1b[?1049l"),
                18 => s.nextSlice("\x1b#8"),
                else => unreachable,
            }
        }
        switch (rand.intRangeAtMost(u8, 0, 9)) {
            0 => t.scrollViewport(.{ .delta = -3 }),
            1 => t.scrollViewport(.{ .delta = 2 }),
            2 => t.scrollViewport(.bottom),
            3 => t.scrollViewport(.top),
            else => {},
        }
        try inc.update(alloc, &t);
        var fresh: RenderState = .empty;
        defer fresh.deinit(alloc);
        fresh.overscan_request = request;
        try fresh.update(alloc, &t);
        try testCompareStates(&inc, &fresh);
    }
}
test "begin and end update" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[1mAB"); 
    s.nextSlice("\x1b[0;3mC"); 
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.beginUpdate(alloc, &t);
    {
        const runs = state.pending_styles.items;
        try testing.expectEqual(2, runs.len);
        try testing.expectEqual(0, runs[0].y);
        try testing.expectEqual(0, runs[0].start);
        try testing.expectEqual(2, runs[0].end);
        try testing.expect(runs[0].style.flags.bold);
        try testing.expectEqual(0, runs[1].y);
        try testing.expectEqual(2, runs[1].start);
        try testing.expectEqual(3, runs[1].end);
        try testing.expect(runs[1].style.flags.italic);
    }
    state.endUpdate();
    {
        try testing.expectEqual(0, state.pending_styles.items.len);
        const row_data = state.row_data.slice();
        const cells = row_data.items(.cells);
        try testing.expect(cells[0].get(0).style.flags.bold);
        try testing.expect(cells[0].get(1).style.flags.bold);
        try testing.expect(cells[0].get(2).style.flags.italic);
    }
}
test "endUpdate skips unchanged style runs" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[1mAB"); 
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    {
        const row_data = state.row_data.slice();
        const applied = row_data.items(.applied_styles);
        try testing.expectEqual(1, applied[0].items.len);
        try testing.expect(applied[0].items[0].style.flags.bold);
        try testing.expect(state.row_data.items(.cells)[0].get(0).style.flags.bold);
    }
    s.nextSlice("\x1b[1;1H\x1b[1mXY");
    try state.update(alloc, &t);
    {
        const cells = &state.row_data.items(.cells)[0];
        try testing.expectEqual('X', cells.get(0).raw.codepoint());
        try testing.expect(cells.get(0).style.flags.bold);
        try testing.expect(cells.get(1).style.flags.bold);
    }
    s.nextSlice("\x1b[1;1H\x1b[0;3mZW"); 
    try state.update(alloc, &t);
    {
        const cells = &state.row_data.items(.cells)[0];
        try testing.expectEqual('Z', cells.get(0).raw.codepoint());
        try testing.expect(!cells.get(0).style.flags.bold);
        try testing.expect(cells.get(0).style.flags.italic);
        const applied = state.row_data.items(.applied_styles);
        try testing.expectEqual(1, applied[0].items.len);
        try testing.expect(applied[0].items[0].style.flags.italic);
    }
}
test "bg color cells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[1mA\x1b[48;5;1m\x1b[K");
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    const row_data = state.row_data.slice();
    const cells = row_data.items(.cells);
    {
        const cell = cells[0].get(0);
        try testing.expectEqual('A', cell.raw.codepoint());
        try testing.expect(cell.style.flags.bold);
    }
    for (1..10) |x| {
        const cell = cells[0].get(x);
        try testing.expectEqual(
            page.Cell.ContentTag.bg_color_palette,
            cell.raw.content_tag,
        );
        try testing.expectEqual(
            Style.Color{ .palette = 1 },
            cell.style.bg_color,
        );
    }
}
test "grapheme" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("A");
    s.nextSlice("👨‍"); 
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    const row_data = state.row_data.slice();
    try testing.expectEqual(3, row_data.len);
    const cells = row_data.items(.cells);
    try testing.expectEqual(10, cells[0].len);
    try testing.expectEqual(10, cells[1].len);
    try testing.expectEqual(10, cells[2].len);
    {
        const cell = cells[0].get(0);
        try testing.expectEqual('A', cell.raw.codepoint());
    }
    {
        const cell = cells[0].get(1);
        try testing.expectEqual(0x1F468, cell.raw.codepoint());
        try testing.expectEqual(.wide, cell.raw.wide);
        try testing.expectEqualSlices(u21, &.{0x200D}, cell.grapheme);
    }
    {
        const cell = cells[0].get(2);
        try testing.expectEqual(0, cell.raw.codepoint());
        try testing.expectEqual(.spacer_tail, cell.raw.wide);
    }
}
test "cursor state in viewport" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 5,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("A\x1b[H");
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    try testing.expectEqual(0, state.cursor.active.x);
    try testing.expectEqual(0, state.cursor.active.y);
    try testing.expectEqual(0, state.cursor.viewport.?.x);
    try testing.expectEqual(0, state.cursor.viewport.?.y);
    try testing.expectEqual('A', state.cursor.cell.codepoint());
    try testing.expect(state.cursor.style.default());
    s.nextSlice("\x1b[1m"); 
    try state.update(alloc, &t);
    try testing.expect(!state.cursor.style.default());
    try testing.expect(state.cursor.style.flags.bold);
    s.nextSlice("\x1b[0m"); 
    s.nextSlice("\x1b[2;3H");
    try state.update(alloc, &t);
    try testing.expectEqual(2, state.cursor.active.x);
    try testing.expectEqual(1, state.cursor.active.y);
    try testing.expectEqual(2, state.cursor.viewport.?.x);
    try testing.expectEqual(1, state.cursor.viewport.?.y);
}
test "cursor state out of viewport" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 2,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("A\r\nB\r\nC\r\nD\r\n");
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    try testing.expectEqual(0, state.cursor.active.x);
    try testing.expectEqual(1, state.cursor.active.y);
    try testing.expectEqual(0, state.cursor.viewport.?.x);
    try testing.expectEqual(1, state.cursor.viewport.?.y);
    t.scrollViewport(.top);
    try state.update(alloc, &t);
    try testing.expectEqual(0, state.cursor.active.x);
    try testing.expectEqual(1, state.cursor.active.y);
    try testing.expect(state.cursor.viewport == null);
}
test "dirty state" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 5,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    try testing.expectEqual(.full, state.dirty);
    state.dirty = .false;
    {
        const row_data = state.row_data.slice();
        const dirty = row_data.items(.dirty);
        @memset(dirty, false);
    }
    try state.update(alloc, &t);
    try testing.expectEqual(.false, state.dirty);
    {
        const row_data = state.row_data.slice();
        const dirty = row_data.items(.dirty);
        for (dirty) |d| try testing.expect(!d);
    }
    s.nextSlice("A");
    try state.update(alloc, &t);
    try testing.expectEqual(.partial, state.dirty);
    {
        const row_data = state.row_data.slice();
        const dirty = row_data.items(.dirty);
        try testing.expect(dirty[0]); 
        try testing.expect(!dirty[1]); 
    }
}
test "colors" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 5,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    s.nextSlice("\x1b]12;#FF0000\x07");
    try state.update(alloc, &t);
    const c = state.colors.cursor.?;
    try testing.expectEqual(0xFF, c.r);
    try testing.expectEqual(0, c.g);
    try testing.expectEqual(0, c.b);
    s.nextSlice("\x1b]4;0;#FFFFFF\x07");
    try state.update(alloc, &t);
    const p0 = state.colors.palette[0];
    try testing.expectEqual(0xFF, p0.r);
    try testing.expectEqual(0xFF, p0.g);
    try testing.expectEqual(0xFF, p0.b);
}
test "selection single line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);
    const screen: *Screen = t.screens.active;
    try screen.select(.init(
        screen.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        screen.pages.pin(.{ .active = .{ .x = 2, .y = 1 } }).?,
        false,
    ));
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    const row_data = state.row_data.slice();
    const sels = row_data.items(.selection);
    try testing.expectEqual(null, sels[0]);
    try testing.expectEqualSlices(size.CellCountInt, &.{ 0, 2 }, &sels[1].?);
    try testing.expectEqual(null, sels[2]);
    try screen.select(null);
    try state.update(alloc, &t);
    try testing.expectEqual(null, sels[0]);
    try testing.expectEqual(null, sels[1]);
    try testing.expectEqual(null, sels[2]);
}
test "selection multiple lines" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);
    const screen: *Screen = t.screens.active;
    try screen.select(.init(
        screen.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        screen.pages.pin(.{ .active = .{ .x = 2, .y = 2 } }).?,
        false,
    ));
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    const row_data = state.row_data.slice();
    const sels = row_data.items(.selection);
    try testing.expectEqual(null, sels[0]);
    try testing.expectEqualSlices(
        size.CellCountInt,
        &.{ 0, screen.pages.cols - 1 },
        &sels[1].?,
    );
    try testing.expectEqualSlices(
        size.CellCountInt,
        &.{ 0, 2 },
        &sels[2].?,
    );
}
test "selection starting on wide char spacer tail" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("a宽b");
    const screen: *Screen = t.screens.active;
    try screen.select(.init(
        screen.pages.pin(.{ .active = .{ .x = 3, .y = 0 } }).?,
        screen.pages.pin(.{ .active = .{ .x = 2, .y = 0 } }).?,
        false,
    ));
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    const row_data = state.row_data.slice();
    const sels = row_data.items(.selection);
    try testing.expectEqualSlices(size.CellCountInt, &.{ 1, 3 }, &sels[0].?);
    try testing.expectEqual(null, sels[1]);
}
test "selection ending on wide char spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("abcdefghi宽\x1b[1;10H");
    const screen: *Screen = t.screens.active;
    const sel: Selection = .init(
        screen.pages.pin(.{ .active = .{ .x = 7, .y = 0 } }).?,
        screen.pages.pin(.{ .active = .{ .x = 9, .y = 0 } }).?,
        false,
    );
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try screen.select(.init(sel.start(), sel.end(), true));
    try state.update(alloc, &t);
    const row_data = state.row_data.slice();
    const sels = row_data.items(.selection);
    const dirty = row_data.items(.dirty);
    try testing.expectEqualSlices(size.CellCountInt, &.{ 7, 9 }, &sels[0].?);
    try testing.expectEqual(null, sels[1]);
    try screen.select(sel);
    try state.update(alloc, &t);
    try testing.expectEqualSlices(size.CellCountInt, &.{ 7, 9 }, &sels[0].?);
    try testing.expectEqualSlices(size.CellCountInt, &.{ 0, 0 }, &sels[1].?);
    try testing.expectEqual(null, sels[2]);
    state.clean();
    s.nextSlice("Z");
    try state.update(alloc, &t);
    try testing.expectEqual(null, sels[1]);
    try testing.expect(dirty[1]);
    try testing.expect(!dirty[2]);
}
test "linkCells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 5,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    s.nextSlice("\x1b]8;;http://example.com\x1b\\LINK\x1b]8;;\x1b\\");
    try state.update(alloc, &t);
    var cells = try state.linkCells(alloc, .{ .x = 0, .y = 0 });
    defer cells.deinit(alloc);
    try testing.expectEqual(4, cells.count());
    try testing.expect(cells.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(cells.contains(.{ .x = 1, .y = 0 }));
    try testing.expect(cells.contains(.{ .x = 2, .y = 0 }));
    try testing.expect(cells.contains(.{ .x = 3, .y = 0 }));
    var cells2 = try state.linkCells(alloc, .{ .x = 4, .y = 0 });
    defer cells2.deinit(alloc);
    try testing.expectEqual(0, cells2.count());
}
test "string" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{
        .cols = 5,
        .rows = 2,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("AB");
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var w = std.Io.Writer.Allocating.init(alloc);
    defer w.deinit();
    try state.string(&w.writer, null);
    const result = try w.toOwnedSlice();
    defer alloc.free(result);
    const expected = "AB\x00\x00\x00\n\x00\x00\x00\x00\x00\n";
    try testing.expectEqualStrings(expected, result);
}
test "linkCells with scrollback spanning pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    const viewport_rows: size.CellCountInt = 10;
    const tail_rows: size.CellCountInt = 5;
    var t = try Terminal.init(io, alloc, .{
        .cols = page.std_capacity.cols,
        .rows = viewport_rows,
        .max_scrollback_bytes = 10_000,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    const pages = &t.screens.active.pages;
    const first_page_cap = pages.pages.first.?.capacity().rows;
    for (0..first_page_cap - 1) |_| s.nextSlice("\r\n");
    s.nextSlice("\r\n");
    s.nextSlice("\x1b]8;;http://example.com\x1b\\LINK\x1b]8;;\x1b\\");
    for (0..(tail_rows - 1)) |_| s.nextSlice("\r\n");
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    const expected_viewport_y: usize = viewport_rows - tail_rows;
    var cells = try state.linkCells(alloc, .{
        .x = 0,
        .y = expected_viewport_y,
    });
    defer cells.deinit(alloc);
    try testing.expectEqual(@as(usize, 4), cells.count());
}
test "linkCells with invalid viewport point" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 5,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    {
        var cells = try state.linkCells(
            alloc,
            .{ .x = 0, .y = t.rows + 10 },
        );
        defer cells.deinit(alloc);
        try testing.expectEqual(0, cells.count());
    }
    {
        var cells = try state.linkCells(
            alloc,
            .{ .x = t.cols + 10, .y = 0 },
        );
        defer cells.deinit(alloc);
        try testing.expectEqual(0, cells.count());
    }
}
test "flattened highlights require matching page serial" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);
    const live_pin = t.screens.active.pages.getTopLeft(.viewport);
    const live_serial = live_pin.node.serial;
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    const pin: PageList.Pin = pin: {
        const row_data = state.row_data.slice();
        @memset(row_data.items(.dirty), false);
        state.dirty = .false;
        break :pin row_data.items(.pin)[0];
    };
    const row_serial = state.row_data.items(.serial)[0];
    try testing.expectEqual(live_pin.node, pin.node);
    try testing.expectEqual(live_serial, row_serial);
    var hl: highlight.Flattened = .{
        .chunks = .empty,
        .top_x = 2,
        .bot_x = 4,
    };
    defer hl.deinit(alloc);
    try hl.chunks.append(alloc, .{
        .node = pin.node,
        .serial = live_serial ^ 1,
        .start = pin.y,
        .end = pin.y + 1,
    });
    try state.updateHighlightsFlattened(alloc, 42, &.{hl});
    {
        const row_data = state.row_data.slice();
        try testing.expectEqual(0, row_data.items(.highlights)[0].items.len);
        try testing.expect(!row_data.items(.dirty)[0]);
        try testing.expectEqual(.false, state.dirty);
    }
    hl.chunks.items(.serial)[0] = live_serial;
    try state.updateHighlightsFlattened(alloc, 42, &.{hl});
    {
        const row_data = state.row_data.slice();
        const row_highlights = row_data.items(.highlights)[0].items;
        try testing.expectEqual(1, row_highlights.len);
        try testing.expectEqual(42, row_highlights[0].tag);
        try testing.expectEqual([2]size.CellCountInt{ 2, 4 }, row_highlights[0].range);
        try testing.expect(row_data.items(.dirty)[0]);
        try testing.expectEqual(.partial, state.dirty);
    }
}
test "dirty row resets highlights" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("ABC");
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    state.dirty = .false;
    {
        const row_data = state.row_data.slice();
        const dirty = row_data.items(.dirty);
        @memset(dirty, false);
    }
    {
        const row_data = state.row_data.slice();
        const row_arenas = row_data.items(.arena);
        const row_highlights = row_data.items(.highlights);
        var arena = row_arenas[0].promote(alloc);
        defer row_arenas[0] = arena.state;
        try row_highlights[0].append(arena.allocator(), .{
            .tag = 1,
            .range = .{ 0, 2 },
        });
    }
    {
        const row_data = state.row_data.slice();
        const row_highlights = row_data.items(.highlights);
        try testing.expectEqual(1, row_highlights[0].items.len);
    }
    s.nextSlice("\x1b[H"); 
    s.nextSlice("X");
    try state.update(alloc, &t);
    {
        const row_data = state.row_data.slice();
        const row_highlights = row_data.items(.highlights);
        try testing.expectEqual(0, row_highlights[0].items.len);
    }
}
fn testWriteNumberedLines(t: *Terminal, n: usize) !void {
    var s = t.vtStream();
    defer s.deinit();
    var buf: [32]u8 = undefined;
    for (0..n) |i| s.nextSlice(try std.fmt.bufPrint(&buf, "{d}\r\n", .{i}));
}
fn testRowNumber(state: *const RenderState, idx: usize) ?usize {
    const cells = state.row_data.items(.cells)[idx].items(.raw);
    var result: ?usize = null;
    for (cells) |cell| {
        const cp = cell.codepoint();
        if (cp < '0' or cp > '9') break;
        result = (result orelse 0) * 10 + (cp - '0');
    }
    return result;
}
test "overscan zero request unchanged" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 10,
        .max_scrollback_bytes = 1_000_000,
    });
    defer t.deinit(alloc);
    try testWriteNumberedLines(&t, 50);
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    for ([_]bool{ false, true }) |scrolled| {
        if (scrolled) t.scrollViewport(.{ .delta = -5 });
        try state.update(alloc, &t);
        try testing.expectEqual(10, state.row_data.len);
        try testing.expectEqual(0, state.rowDataRange().start);
        try testing.expectEqual(10, state.rowDataRange().end);
        try testing.expect(state.overscan.eql(.{}));
        try testing.expectEqual(0, state.viewportStart());
    }
    try testing.expectEqual(36, testRowNumber(&state, 0).?);
}
test "overscan row_data layout" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 10,
        .max_scrollback_bytes = 1_000_000,
    });
    defer t.deinit(alloc);
    try testWriteNumberedLines(&t, 50);
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    state.overscan_request = .{ .above = 3, .below = 2 };
    {
        try state.update(alloc, &t);
        try testing.expect(state.overscan.eql(.{ .above = 3, .below = 0 }));
        try testing.expectEqual(15, state.row_data.len);
        try testing.expectEqual(0, state.rowDataRange().start);
        try testing.expectEqual(13, state.rowDataRange().end);
        try testing.expectEqual(3, state.viewportStart());
        try testing.expectEqual(-3, state.viewportY(0));
        try testing.expectEqual(0, state.viewportY(3));
        var plain: RenderState = .empty;
        defer plain.deinit(alloc);
        try plain.update(alloc, &t);
        const vp = state.viewportStart();
        for (0..state.rows) |y| {
            const a = state.row_data.get(vp + y);
            const b = plain.row_data.get(y);
            try testing.expectEqual(b.pin.node, a.pin.node);
            try testing.expectEqual(b.pin.y, a.pin.y);
            try testing.expectEqual(
                @as(page.Row.Backing, @bitCast(b.raw)),
                @as(page.Row.Backing, @bitCast(a.raw)),
            );
            for (b.cells.items(.raw), a.cells.items(.raw)) |bc, ac| {
                try testing.expectEqual(
                    @as(page.Cell.Backing, @bitCast(bc)),
                    @as(page.Cell.Backing, @bitCast(ac)),
                );
            }
        }
        try testing.expectEqual(41, testRowNumber(&state, vp).?);
        try testing.expectEqual(38, testRowNumber(&state, 0).?);
        try testing.expectEqual(40, testRowNumber(&state, vp - 1).?);
    }
    {
        t.scrollViewport(.{ .delta = -5 });
        try state.update(alloc, &t);
        try testing.expect(state.overscan.eql(.{ .above = 3, .below = 2 }));
        try testing.expectEqual(15, state.row_data.len);
        try testing.expectEqual(0, state.rowDataRange().start);
        try testing.expectEqual(15, state.rowDataRange().end);
        const vp = state.viewportStart();
        try testing.expectEqual(36, testRowNumber(&state, vp).?);
        try testing.expectEqual(35, testRowNumber(&state, vp - 1).?);
        try testing.expectEqual(46, testRowNumber(&state, vp + state.rows).?);
        try testing.expectEqual(47, testRowNumber(&state, vp + state.rows + 1).?);
    }
    {
        t.scrollViewport(.top);
        try state.update(alloc, &t);
        try testing.expectEqual(0, state.overscan.above);
        try testing.expectEqual(2, state.overscan.below);
        try testing.expectEqual(state.viewportStart(), state.rowDataRange().start);
        try testing.expectEqual(15, state.row_data.len);
        try testing.expectEqual(0, testRowNumber(&state, state.viewportStart()).?);
        t.scrollViewport(.{ .row = 1 });
        try state.update(alloc, &t);
        try testing.expectEqual(1, state.overscan.above);
        try testing.expectEqual(2, state.rowDataRange().start);
        try testing.expectEqual(15, state.row_data.len);
        try testing.expectEqual(0, testRowNumber(&state, 2).?);
        try testing.expectEqual(1, testRowNumber(&state, 3).?);
    }
    {
        t.scrollViewport(.bottom);
        t.scrollViewport(.{ .delta = -1 });
        try state.update(alloc, &t);
        try testing.expect(state.overscan.eql(.{ .above = 3, .below = 1 }));
        try testing.expectEqual(14, state.rowDataRange().end);
        try testing.expectEqual(15, state.row_data.len);
    }
}
test "overscan request change forces redraw" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 10,
        .max_scrollback_bytes = 1_000_000,
    });
    defer t.deinit(alloc);
    try testWriteNumberedLines(&t, 50);
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    state.clean();
    try state.update(alloc, &t);
    try testing.expectEqual(.false, state.dirty);
    state.overscan_request = .{ .above = 4, .below = 1 };
    try state.update(alloc, &t);
    try testing.expectEqual(.full, state.dirty);
    try testing.expectEqual(15, state.row_data.len);
    try testing.expectEqual(4, state.viewportStart());
    try testing.expectEqual(41, testRowNumber(&state, 4).?);
    state.clean();
    state.overscan_request = .{};
    try state.update(alloc, &t);
    try testing.expectEqual(.full, state.dirty);
    try testing.expectEqual(10, state.row_data.len);
    try testing.expectEqual(41, testRowNumber(&state, 0).?);
}
test "overscan row ids stable" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 10,
        .max_scrollback_bytes = 1_000_000,
    });
    defer t.deinit(alloc);
    try testWriteNumberedLines(&t, 50);
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    state.overscan_request = .{ .above = 3, .below = 2 };
    try state.update(alloc, &t);
    const range = state.rowDataRange();
    try testing.expectEqual(0, range.start);
    try testing.expectEqual(13, range.end);
    var ids: [13]RenderState.Row.Id = undefined;
    for (&ids, range.start..) |*id, i| id.* = state.row_data.get(i).id();
    for (ids, 0..) |a, i| for (ids[i + 1 ..]) |b| {
        try testing.expect(!a.eql(b));
    };
    try testWriteNumberedLines(&t, 1);
    try state.update(alloc, &t);
    try testing.expectEqual(13, state.rowDataRange().end);
    for (ids[1..], 0..) |id, i| {
        try testing.expect(id.eql(state.row_data.get(i).id()));
    }
    t.scrollViewport(.{ .delta = -1 });
    try state.update(alloc, &t);
    try testing.expectEqual(14, state.rowDataRange().end);
    for (ids, 0..) |id, i| {
        try testing.expect(id.eql(state.row_data.get(i).id()));
    }
}
test "overscan row ids and dirty on in-place rewrite" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 5,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[?1049h");
    s.nextSlice("0\r\n1\r\n2\r\n3\r\n4");
    s.nextSlice("\x1b[2;5r\x1b[5;2H");
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    state.overscan_request = .{ .above = 2, .below = 2 };
    try state.update(alloc, &t);
    try testing.expect(state.overscan.eql(.{}));
    const vp = state.viewportStart();
    var ids: [5]RenderState.Row.Id = undefined;
    var nums: [5]?usize = undefined;
    for (&ids, &nums, vp..) |*id, *num, i| {
        id.* = state.row_data.get(i).id();
        num.* = testRowNumber(&state, i);
    }
    state.clean();
    s.nextSlice("\r\n5");
    try state.update(alloc, &t);
    try testing.expect(state.dirty != .false);
    for (ids, nums, vp..) |id, num, i| {
        const row = state.row_data.get(i);
        const new_num = testRowNumber(&state, i);
        try testing.expectEqual(if (i == vp) 0 else i - vp + 1, new_num.?);
        if (id.eql(row.id()) and !row.dirty) {
            try testing.expectEqual(num, new_num);
        }
        if (num != new_num) try testing.expect(row.dirty);
    }
    for (ids, vp..) |id, i| {
        try testing.expect(!id.eql(state.row_data.get(i).id()));
    }
}
test "overscan cursor in overscan row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 10,
        .max_scrollback_bytes = 1_000_000,
    });
    defer t.deinit(alloc);
    try testWriteNumberedLines(&t, 50);
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    state.overscan_request = .{ .below = 2 };
    t.scrollViewport(.{ .delta = -1 });
    try state.update(alloc, &t);
    try testing.expectEqual(1, state.overscan.below);
    try testing.expect(state.cursor.viewport == null);
    t.scrollViewport(.bottom);
    try state.update(alloc, &t);
    try testing.expectEqual(state.rows - 1, state.cursor.viewport.?.y);
    try testing.expectEqual(0, state.cursor.viewport.?.x);
}
test "overscan selection on overscan rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 10,
        .max_scrollback_bytes = 1_000_000,
    });
    defer t.deinit(alloc);
    try testWriteNumberedLines(&t, 50);
    const screen: *Screen = t.screens.active;
    try screen.select(.init(
        screen.pages.pin(.{ .active = .{ .x = 0, .y = 8 } }).?,
        screen.pages.pin(.{ .active = .{ .x = 2, .y = 9 } }).?,
        false,
    ));
    var state: RenderState = .empty;
    defer state.deinit(alloc);
    state.overscan_request = .{ .below = 2 };
    t.scrollViewport(.{ .delta = -1 });
    try state.update(alloc, &t);
    try testing.expectEqual(1, state.overscan.below);
    const vp = state.viewportStart();
    const sels = state.row_data.items(.selection);
    try testing.expectEqual(
        [2]size.CellCountInt{ 0, 9 },
        sels[vp + state.rows - 1].?,
    );
    try testing.expectEqual(
        [2]size.CellCountInt{ 0, 2 },
        sels[vp + state.rows].?,
    );
    try testing.expect(sels[vp + state.rows - 2] == null);
}
