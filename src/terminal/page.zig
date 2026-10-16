const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("terminal_options");
const lib = @import("../lib/main.zig");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const assert = @import("../quirks.zig").inlineAssert;
const testing = std.testing;
const posix = std.posix;
const windows = @import("../os/windows.zig");
const fastmem = @import("../fastmem.zig");
const color = @import("color.zig");
const hyperlink = @import("hyperlink.zig");
const kitty = @import("kitty.zig");
const stylepkg = @import("style.zig");
const Style = stylepkg.Style;
const StyleId = stylepkg.Id;
const StyleSet = stylepkg.Set;
const size = @import("size.zig");
const getOffset = size.getOffset;
const Offset = size.Offset;
const OffsetBuf = size.OffsetBuf;
const BitmapAllocator = @import("bitmap_allocator.zig").BitmapAllocator;
const hash_map = @import("hash_map.zig");
const AutoOffsetHashMap = hash_map.AutoOffsetHashMap;
const alignForward = std.mem.alignForward;
const log = std.log.scoped(.page);
const PageAlloc = switch (builtin.os.tag) {
    .windows => AllocWindows,
    else => AllocPosix,
};
const AllocPosix = struct {
    pub fn alloc(n: usize) ![]align(std.heap.page_size_min) u8 {
        return try posix.mmap(
            null,
            n,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
    }
    pub fn free(mem: []align(std.heap.page_size_min) u8) void {
        posix.munmap(mem);
    }
};
const AllocWindows = struct {
    pub fn alloc(n: usize) error{OutOfMemory}![]align(std.heap.page_size_min) u8 {
        const addr = windows.exp.kernel32.VirtualAlloc(
            null,
            n,
            windows.MEM_COMMIT | windows.MEM_RESERVE,
            windows.PAGE_READWRITE,
        ) orelse return error.OutOfMemory;
        return @as(
            [*]align(std.heap.page_size_min) u8,
            @ptrCast(@alignCast(addr)),
        )[0..n];
    }
    pub fn free(mem: []align(std.heap.page_size_min) u8) void {
        _ = windows.exp.kernel32.VirtualFree(
            @ptrCast(@alignCast(mem.ptr)),
            0,
            windows.MEM_RELEASE,
        );
    }
};
const grapheme_chunk_len = 4;
const grapheme_chunk = grapheme_chunk_len * @sizeOf(u21);
pub const grapheme_max_len = 64;
const GraphemeAlloc = BitmapAllocator(grapheme_chunk);
const grapheme_count_default = GraphemeAlloc.bitmap_bit_size;
pub const grapheme_bytes_default = grapheme_count_default * grapheme_chunk;
const GraphemeMap = AutoOffsetHashMap(
    Offset(Cell),
    Offset(u21).Slice,
    hash_map.default_max_load_percentage,
);
const string_chunk_len = 32;
const string_chunk = string_chunk_len * @sizeOf(u8);
const StringAlloc = BitmapAllocator(string_chunk);
const string_count_default = StringAlloc.bitmap_bit_size;
pub const string_bytes_default = string_count_default * string_chunk;
const hyperlink_count_default = 4;
const hyperlink_bytes_default = hyperlink_count_default * @sizeOf(hyperlink.Set.Item);
const hyperlink_cell_multiplier = 16;
const cells_align: usize = @max(
    @alignOf(Cell),
    @min(
        std.atomic.cache_line,
        std.heap.page_size_min,
    ),
);
pub const Page = struct {
    comptime {
        assert(std.heap.page_size_min % @max(
            @alignOf(Row),
            cells_align,
            MetaLayout.alignment,
        ) == 0);
    }
    memory: []align(std.heap.page_size_min) u8,
    rows: Offset(Row),
    cells: Offset(Cell),
    dirty: bool,
    string_alloc: StringAlloc,
    grapheme_alloc: GraphemeAlloc,
    grapheme_map: GraphemeMap,
    styles: StyleSet,
    hyperlink_map: hyperlink.Map,
    hyperlink_set: hyperlink.Set,
    size: Size,
    capacity: Capacity,
    pause_integrity_checks: if (build_options.slow_runtime_safety) usize else void =
        if (build_options.slow_runtime_safety) 0 else {},
    pub inline fn init(cap: Capacity) !Page {
        const l = layout(cap);
        assert(l.total_size % std.heap.page_size_min == 0);
        const backing = try PageAlloc.alloc(l.total_size);
        errdefer PageAlloc.free(backing);
        const buf = OffsetBuf.init(backing);
        return initBuf(buf, l);
    }
    pub inline fn initBuf(buf: OffsetBuf, l: Layout) Page {
        const cap = l.capacity;
        assert(cap.rows > 0);
        const rows = buf.member(Row, l.rows_start);
        const cells = buf.member(Cell, l.cells_start);
        const cells_len = @as(usize, cap.cols) * @as(usize, cap.rows);
        const cells_ptr = cells.ptr(buf)[0..cells_len];
        for (rows.ptr(buf)[0..cap.rows], 0..) |*row, y| {
            const start = y * cap.cols;
            row.* = .{
                .cells = getOffset(Cell, buf, &cells_ptr[start]),
            };
        }
        return .{
            .memory = @alignCast(buf.start()[0..l.total_size]),
            .rows = rows,
            .cells = cells,
            .styles = StyleSet.initAssumeZeroed(
                buf.add(l.styles_start),
                l.styles_layout,
                .{},
            ),
            .string_alloc = .initAssumeZeroed(
                buf.add(l.string_alloc_start),
                l.string_alloc_layout,
            ),
            .grapheme_alloc = .initAssumeZeroed(
                buf.add(l.grapheme_alloc_start),
                l.grapheme_alloc_layout,
            ),
            .grapheme_map = .initAssumeZeroed(
                buf.add(l.grapheme_map_start),
                l.grapheme_map_layout,
            ),
            .hyperlink_map = .initAssumeZeroed(
                buf.add(l.hyperlink_map_start),
                l.hyperlink_map_layout,
            ),
            .hyperlink_set = .initAssumeZeroed(
                buf.add(l.hyperlink_set_start),
                l.hyperlink_set_layout,
                .{},
            ),
            .size = .{ .cols = cap.cols, .rows = cap.rows },
            .capacity = cap,
            .dirty = false,
        };
    }
    pub inline fn deinit(self: *Page) void {
        PageAlloc.free(self.memory);
        self.* = undefined;
    }
    pub inline fn reinit(self: *Page) void {
        @memset(@as([*]u64, @ptrCast(self.memory))[0 .. self.memory.len / 8], 0);
        self.* = initBuf(.init(self.memory), layout(self.capacity));
    }
    pub const IntegrityError = error{
        ZeroRowCount,
        ZeroColCount,
        UnmarkedGraphemeRow,
        MissingGraphemeData,
        InvalidGraphemeCount,
        UnmarkedGraphemeCell,
        MissingStyle,
        UnmarkedStyleRow,
        MismatchedStyleRef,
        InvalidStyleCount,
        MissingHyperlinkData,
        MismatchedHyperlinkRef,
        UnmarkedHyperlinkCell,
        UnmarkedHyperlinkRow,
        InvalidSpacerTailLocation,
        InvalidSpacerHeadLocation,
        UnwrappedSpacerHead,
    };
    pub inline fn pauseIntegrityChecks(self: *Page, v: bool) void {
        if (build_options.slow_runtime_safety) {
            if (v) {
                self.pause_integrity_checks += 1;
            } else {
                self.pause_integrity_checks -= 1;
            }
        }
    }
    pub inline fn assertIntegrity(self: *const Page) void {
        if (comptime build_options.slow_runtime_safety and builtin.os.tag != .freestanding) {
            var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
            defer _ = debug_allocator.deinit();
            const alloc = debug_allocator.allocator();
            self.verifyIntegrity(alloc) catch |err| {
                log.err("page integrity violation, crashing. err={}", .{err});
                @panic("page integrity violation");
            };
        }
    }
    pub fn verifyIntegrity(self: *const Page, alloc_gpa: Allocator) !void {
        if (std.valgrind.runningOnValgrind() > 0) return;
        if (build_options.slow_runtime_safety) {
            if (self.pause_integrity_checks > 0) return;
        }
        if (self.size.rows == 0) {
            log.warn("page integrity violation zero row count", .{});
            return IntegrityError.ZeroRowCount;
        }
        if (self.size.cols == 0) {
            log.warn("page integrity violation zero col count", .{});
            return IntegrityError.ZeroColCount;
        }
        var arena = ArenaAllocator.init(alloc_gpa);
        defer arena.deinit();
        const alloc = arena.allocator();
        var graphemes_seen: usize = 0;
        var styles_seen = std.AutoHashMap(StyleId, usize).init(alloc);
        defer styles_seen.deinit();
        var hyperlinks_seen = std.AutoHashMap(hyperlink.Id, usize).init(alloc);
        defer hyperlinks_seen.deinit();
        const grapheme_count = self.graphemeCount();
        const rows = self.rows.ptr(self.memory)[0..self.size.rows];
        for (rows, 0..) |*row, y| {
            const graphemes_start = graphemes_seen;
            const cells = row.cells.ptr(self.memory)[0..self.size.cols];
            for (cells, 0..) |*cell, x| {
                if (cell.hasGrapheme()) {
                    _ = self.lookupGrapheme(cell) orelse {
                        log.warn(
                            "page integrity violation y={} x={} grapheme data missing",
                            .{ y, x },
                        );
                        return IntegrityError.MissingGraphemeData;
                    };
                    graphemes_seen += 1;
                } else if (grapheme_count > 0) {
                    if (self.lookupGrapheme(cell) != null) {
                        log.warn(
                            "page integrity violation y={} x={} cell not marked as grapheme",
                            .{ y, x },
                        );
                        return IntegrityError.UnmarkedGraphemeCell;
                    }
                }
                if (cell.style_id != stylepkg.default_id) {
                    _ = self.styles.get(
                        self.memory,
                        cell.style_id,
                    );
                    if (!row.styled) {
                        log.warn(
                            "page integrity violation y={} x={} row not marked as styled",
                            .{ y, x },
                        );
                        return IntegrityError.UnmarkedStyleRow;
                    }
                    const gop = try styles_seen.getOrPut(cell.style_id);
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;
                }
                if (cell.hyperlink) {
                    const id = self.lookupHyperlink(cell) orelse {
                        log.warn(
                            "page integrity violation y={} x={} hyperlink data missing",
                            .{ y, x },
                        );
                        return IntegrityError.MissingHyperlinkData;
                    };
                    if (!row.hyperlink) {
                        log.warn(
                            "page integrity violation y={} x={} row not marked as hyperlink",
                            .{ y, x },
                        );
                        return IntegrityError.UnmarkedHyperlinkRow;
                    }
                    const gop = try hyperlinks_seen.getOrPut(id);
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;
                    _ = self.hyperlink_set.get(self.memory, id);
                } else {
                    if (self.lookupHyperlink(cell) != null) {
                        log.warn(
                            "page integrity violation y={} x={} cell not marked as hyperlink",
                            .{ y, x },
                        );
                        return IntegrityError.UnmarkedHyperlinkCell;
                    }
                }
                switch (cell.wide) {
                    .narrow => {},
                    .wide => {},
                    .spacer_tail => {
                        if (x == 0) {
                            log.warn(
                                "page integrity violation y={} x={} spacer tail at start",
                                .{ y, x },
                            );
                            return IntegrityError.InvalidSpacerTailLocation;
                        }
                        const prev = cells[x - 1];
                        if (prev.wide != .wide) {
                            log.warn(
                                "page integrity violation y={} x={} spacer tail not following wide",
                                .{ y, x },
                            );
                            return IntegrityError.InvalidSpacerTailLocation;
                        }
                    },
                    .spacer_head => {
                        if (x != self.size.cols - 1) {
                            log.warn(
                                "page integrity violation y={} x={} spacer head not at end",
                                .{ y, x },
                            );
                            return IntegrityError.InvalidSpacerHeadLocation;
                        }
                        if (!row.wrap) {
                            log.warn(
                                "page integrity violation y={} spacer head not wrapped",
                                .{y},
                            );
                            return IntegrityError.UnwrappedSpacerHead;
                        }
                    },
                }
            }
            if (graphemes_seen > graphemes_start) {
                if (!row.grapheme) {
                    log.warn(
                        "page integrity violation y={} grapheme data but row not marked",
                        .{y},
                    );
                    return IntegrityError.UnmarkedGraphemeRow;
                }
            }
        }
        if (graphemes_seen > self.graphemeCount()) {
            log.warn(
                "page integrity violation grapheme count mismatch expected={} actual={}",
                .{ graphemes_seen, self.graphemeCount() },
            );
            return IntegrityError.InvalidGraphemeCount;
        }
        {
            var it = styles_seen.iterator();
            while (it.next()) |entry| {
                const ref_count = self.styles.refCount(self.memory, entry.key_ptr.*);
                if (ref_count < entry.value_ptr.*) {
                    log.warn(
                        "page integrity violation style ref count mismatch id={} expected={} actual={}",
                        .{ entry.key_ptr.*, entry.value_ptr.*, ref_count },
                    );
                    return IntegrityError.MismatchedStyleRef;
                }
            }
        }
        {
            var it = hyperlinks_seen.iterator();
            while (it.next()) |entry| {
                const ref_count = self.hyperlink_set.refCount(self.memory, entry.key_ptr.*);
                if (ref_count < entry.value_ptr.*) {
                    log.warn(
                        "page integrity violation hyperlink ref count mismatch id={} expected={} actual={}",
                        .{ entry.key_ptr.*, entry.value_ptr.*, ref_count },
                    );
                    return IntegrityError.MismatchedHyperlinkRef;
                }
            }
        }
        {
            const styles_table = self.styles.table.ptr(self.memory)[0..self.styles.layout.table_cap];
            const styles_items = self.styles.items.ptr(self.memory)[0..self.styles.layout.cap];
            var zombies: usize = 0;
            for (styles_table) |id| {
                if (id == 0) continue;
                const item = styles_items[id];
                if (item.meta.ref == 0) continue;
                const expected = styles_seen.get(id) orelse 0;
                if (expected > 0) continue;
                if (item.meta.ref > expected) {
                    zombies += 1;
                }
            }
        }
    }
    pub inline fn clone(self: *const Page) !Page {
        const backing = try PageAlloc.alloc(self.memory.len);
        errdefer PageAlloc.free(backing);
        return self.cloneBuf(backing);
    }
    pub inline fn cloneBuf(self: *const Page, buf: []align(std.heap.page_size_min) u8) Page {
        assert(buf.len >= self.memory.len);
        var result = self.*;
        result.memory = buf[0..self.memory.len];
        fastmem.copy(u8, result.memory, self.memory);
        return result;
    }
    pub const StyleSetError = error{
        StyleSetOutOfMemory,
        StyleSetNeedsRehash,
    };
    pub const HyperlinkError = error{
        StringAllocOutOfMemory,
        HyperlinkSetOutOfMemory,
        HyperlinkSetNeedsRehash,
        HyperlinkMapOutOfMemory,
    };
    pub const GraphemeError = error{
        GraphemeMapOutOfMemory,
        GraphemeAllocOutOfMemory,
    };
    pub const CloneFromError =
        StyleSetError ||
        HyperlinkError ||
        GraphemeError;
    pub fn exactRowCapacity(
        self: *const Page,
        y_start: usize,
        y_end: usize,
    ) Capacity {
        assert(y_start < y_end);
        assert(y_end <= self.size.rows);
        const CellCountSet = std.StaticBitSet(std.math.maxInt(size.CellCountInt) + 1);
        comptime assert(size.StyleCountInt == size.CellCountInt);
        comptime assert(size.HyperlinkCountInt == size.CellCountInt);
        var id_set: CellCountSet = .initEmpty();
        var grapheme_bytes: usize = 0;
        var string_bytes: usize = 0;
        const rows = self.rows.ptr(self.memory)[y_start..y_end];
        for (rows) |*row| {
            const cells = row.cells.ptr(self.memory)[0..self.size.cols];
            for (cells) |*cell| {
                if (cell.style_id != stylepkg.default_id) {
                    id_set.set(cell.style_id);
                }
                if (cell.hasGrapheme()) {
                    if (self.lookupGrapheme(cell)) |cps| {
                        grapheme_bytes += GraphemeAlloc.bytesRequired(u21, cps.len);
                    }
                }
            }
        }
        const styles_cap = StyleSet.capacityForCount(id_set.count());
        id_set = .initEmpty();
        var hyperlink_cells: usize = 0;
        for (rows) |*row| {
            const cells = row.cells.ptr(self.memory)[0..self.size.cols];
            for (cells) |*cell| {
                if (cell.hyperlink) {
                    hyperlink_cells += 1;
                    if (self.lookupHyperlink(cell)) |id| {
                        if (!id_set.isSet(id)) {
                            id_set.set(id);
                            const entry = self.hyperlink_set.get(self.memory, id);
                            string_bytes += StringAlloc.bytesRequired(u8, entry.uri.len);
                            switch (entry.id) {
                                .implicit => {},
                                .explicit => |slice| {
                                    string_bytes += StringAlloc.bytesRequired(u8, slice.len);
                                },
                            }
                        }
                    }
                }
            }
        }
        const hyperlink_cap = cap: {
            const hyperlink_count = id_set.count();
            const hyperlink_set_cap = hyperlink.Set.capacityForCount(hyperlink_count);
            const hyperlink_map_min = std.math.divCeil(
                usize,
                hyperlink_cells,
                hyperlink_cell_multiplier,
            ) catch 0;
            break :cap @max(hyperlink_set_cap, hyperlink_map_min);
        };
        return .{
            .cols = self.size.cols,
            .rows = @intCast(y_end - y_start),
            .styles = @intCast(styles_cap),
            .grapheme_bytes = @intCast(grapheme_bytes),
            .hyperlink_bytes = @intCast(hyperlink_cap * @sizeOf(hyperlink.Set.Item)),
            .string_bytes = @intCast(string_bytes),
        };
    }
    pub inline fn cloneFrom(
        self: *Page,
        other: *const Page,
        y_start: usize,
        y_end: usize,
    ) CloneFromError!void {
        assert(y_start <= y_end);
        assert(y_end <= other.size.rows);
        assert(y_end - y_start <= self.size.rows);
        const other_rows = other.rows.ptr(other.memory)[y_start..y_end];
        const rows = self.rows.ptr(self.memory)[0 .. y_end - y_start];
        for (rows, other_rows) |*dst_row, *src_row| {
            try self.cloneRowFrom(other, dst_row, src_row);
        }
        self.assertIntegrity();
    }
    pub inline fn cloneRowFrom(
        self: *Page,
        other: *const Page,
        dst_row: *Row,
        src_row: *const Row,
    ) CloneFromError!void {
        try self.clonePartialRowFrom(
            other,
            dst_row,
            src_row,
            0,
            self.size.cols,
        );
    }
    pub fn clonePartialRowFrom(
        self: *Page,
        other: *const Page,
        dst_row: *Row,
        src_row: *const Row,
        x_start: usize,
        x_end_req: usize,
    ) CloneFromError!void {
        self.pauseIntegrityChecks(true);
        defer {
            self.pauseIntegrityChecks(false);
            self.assertIntegrity();
        }
        const cell_len = @min(self.size.cols, other.size.cols);
        const x_end = @min(x_end_req, cell_len);
        assert(x_start <= x_end);
        const other_cells = src_row.cells.ptr(other.memory)[x_start..x_end];
        const cells = dst_row.cells.ptr(self.memory)[x_start..x_end];
        if (dst_row.managedMemory()) self.clearCells(dst_row, x_start, x_end);
        dst_row.* = copy: {
            var copy = src_row.*;
            if ((x_end - x_start) < self.size.cols) {
                copy.wrap = dst_row.wrap;
                copy.wrap_continuation = dst_row.wrap_continuation;
                copy.grapheme = dst_row.grapheme;
                copy.hyperlink = dst_row.hyperlink;
                copy.styled = dst_row.styled;
                copy.dirty |= dst_row.dirty;
            }
            copy.cells = dst_row.cells;
            break :copy copy;
        };
        if (!src_row.managedMemory()) {
            if (build_options.slow_runtime_safety) {
                for (other_cells) |cell| {
                    assert(!cell.hasGrapheme());
                    assert(!cell.hyperlink);
                    assert(cell.style_id == stylepkg.default_id);
                }
            }
            fastmem.copy(Cell, cells, other_cells);
        } else {
            for (cells, other_cells) |*dst_cell, *src_cell| {
                dst_cell.* = src_cell.*;
                dst_cell.hyperlink = false;
                dst_cell.style_id = stylepkg.default_id;
                if (dst_cell.content_tag == .codepoint_grapheme) {
                    dst_cell.content_tag = .codepoint;
                }
                if (src_cell.hasGrapheme()) {
                    const cps = other.lookupGrapheme(src_cell).?;
                    try self.setGraphemes(dst_row, dst_cell, cps);
                }
                if (src_cell.hyperlink) hyperlink: {
                    const id = other.lookupHyperlink(src_cell).?;
                    if (other == self) {
                        self.hyperlink_set.use(self.memory, id);
                        try self.setHyperlink(dst_row, dst_cell, id);
                        break :hyperlink;
                    }
                    if (self.hyperlinkCount() >= self.hyperlinkCapacity()) {
                        return error.HyperlinkMapOutOfMemory;
                    }
                    const other_link = other.hyperlink_set.get(other.memory, id);
                    const dst_id = dst_id: {
                        if (self.hyperlink_set.lookupContext(
                            self.memory,
                            other_link.*,
                            .{ .page = self, .src_page = @constCast(other) },
                        )) |i| {
                            self.hyperlink_set.use(self.memory, i);
                            break :dst_id i;
                        }
                        const dst_link = other_link.dupe(other, self) catch |e| {
                            comptime assert(@TypeOf(e) == error{OutOfMemory});
                            return error.StringAllocOutOfMemory;
                        };
                        break :dst_id self.hyperlink_set.addWithIdContext(
                            self.memory,
                            dst_link,
                            id,
                            .{ .page = self },
                        ) catch |e| switch (e) {
                            error.OutOfMemory => return error.HyperlinkSetOutOfMemory,
                            error.NeedsRehash => return error.HyperlinkSetNeedsRehash,
                        } orelse id;
                    };
                    try self.setHyperlink(dst_row, dst_cell, dst_id);
                }
                if (src_cell.style_id != stylepkg.default_id) style: {
                    dst_row.styled = true;
                    if (other == self) {
                        dst_cell.style_id = src_cell.style_id;
                        self.styles.use(self.memory, dst_cell.style_id);
                        break :style;
                    }
                    const other_style = other.styles.get(other.memory, src_cell.style_id);
                    dst_cell.style_id = self.styles.addWithId(
                        self.memory,
                        other_style.*,
                        src_cell.style_id,
                    ) catch |e| switch (e) {
                        error.OutOfMemory => return error.StyleSetOutOfMemory,
                        error.NeedsRehash => return error.StyleSetNeedsRehash,
                    } orelse src_cell.style_id;
                }
                if (comptime build_options.kitty_graphics) {
                    if (src_cell.codepoint() == kitty.graphics.unicode.placeholder) {
                        dst_row.kitty_virtual_placeholder = true;
                    }
                }
            }
        }
        if (self.size.cols > other.size.cols) {
            const last = &cells[other.size.cols - 1];
            if (last.wide == .spacer_head) {
                last.wide = .narrow;
            }
        }
    }
    pub inline fn getRow(self: *const Page, y: usize) *Row {
        assert(y < self.size.rows);
        return &self.rows.ptr(self.memory)[y];
    }
    pub inline fn getCells(self: *const Page, row: *Row) []Cell {
        if (build_options.slow_runtime_safety) {
            const rows = self.rows.ptr(self.memory);
            const cells = self.cells.ptr(self.memory);
            assert(@intFromPtr(row) >= @intFromPtr(rows));
            assert(@intFromPtr(row) < @intFromPtr(cells));
        }
        const cells = row.cells.ptr(self.memory);
        return cells[0..self.size.cols];
    }
    pub inline fn getRowAndCell(self: *const Page, x: usize, y: usize) struct {
        row: *Row,
        cell: *Cell,
    } {
        assert(y < self.size.rows);
        assert(x < self.size.cols);
        const rows = self.rows.ptr(self.memory);
        const row = &rows[y];
        const cell = &row.cells.ptr(self.memory)[x];
        return .{ .row = row, .cell = cell };
    }
    pub fn moveCells(
        self: *Page,
        src_row: *Row,
        src_left: usize,
        dst_row: *Row,
        dst_left: usize,
        len: usize,
    ) void {
        defer self.assertIntegrity();
        const src_cells = src_row.cells.ptr(self.memory)[src_left .. src_left + len];
        const dst_cells = dst_row.cells.ptr(self.memory)[dst_left .. dst_left + len];
        self.clearCells(dst_row, dst_left, dst_left + len);
        if (!src_row.managedMemory()) {
            fastmem.copy(Cell, dst_cells, src_cells);
        } else {
            for (src_cells, dst_cells) |*src, *dst| {
                dst.* = src.*;
                if (src.hasGrapheme()) {
                    dst.content_tag = .codepoint;
                    self.moveGrapheme(src, dst);
                    src.content_tag = .codepoint;
                    dst.content_tag = .codepoint_grapheme;
                    dst_row.grapheme = true;
                }
                if (src.hyperlink) {
                    dst.hyperlink = false;
                    self.moveHyperlink(src, dst);
                    dst.hyperlink = true;
                    dst_row.hyperlink = true;
                }
                if (comptime build_options.kitty_graphics) {
                    if (src.codepoint() == kitty.graphics.unicode.placeholder) {
                        dst_row.kitty_virtual_placeholder = true;
                    }
                }
            }
        }
        if (!dst_row.styled) dst_row.styled = styled: for (dst_cells) |c| {
            if (c.style_id != stylepkg.default_id) break :styled true;
        } else false;
        @memset(@as([]u64, @ptrCast(src_cells)), 0);
        if (src_cells.len == self.size.cols) {
            src_row.grapheme = false;
            src_row.hyperlink = false;
            src_row.styled = false;
            if (comptime build_options.kitty_graphics) {
                src_row.kitty_virtual_placeholder = false;
            }
        }
    }
    pub inline fn swapCells(
        self: *Page,
        src: *Cell,
        dst: *Cell,
    ) void {
        defer self.assertIntegrity();
        if (src.hasGrapheme() or dst.hasGrapheme()) {
            if (src.hasGrapheme() and !dst.hasGrapheme()) {
                self.moveGrapheme(src, dst);
            } else if (!src.hasGrapheme() and dst.hasGrapheme()) {
                self.moveGrapheme(dst, src);
            } else {
                const src_offset = getOffset(Cell, self.memory, src);
                const dst_offset = getOffset(Cell, self.memory, dst);
                var map = self.grapheme_map.map(self.memory);
                const src_entry = map.getEntry(src_offset).?;
                const dst_entry = map.getEntry(dst_offset).?;
                const src_value = src_entry.value_ptr.*;
                const dst_value = dst_entry.value_ptr.*;
                src_entry.value_ptr.* = dst_value;
                dst_entry.value_ptr.* = src_value;
            }
        }
        if (src.hyperlink or dst.hyperlink) {
            if (src.hyperlink and !dst.hyperlink) {
                self.moveHyperlink(src, dst);
            } else if (!src.hyperlink and dst.hyperlink) {
                self.moveHyperlink(dst, src);
            } else {
                const src_offset = getOffset(Cell, self.memory, src);
                const dst_offset = getOffset(Cell, self.memory, dst);
                var map = self.hyperlink_map.map(self.memory);
                const src_entry = map.getEntry(src_offset).?;
                const dst_entry = map.getEntry(dst_offset).?;
                const src_value = src_entry.value_ptr.*;
                const dst_value = dst_entry.value_ptr.*;
                src_entry.value_ptr.* = dst_value;
                dst_entry.value_ptr.* = src_value;
            }
        }
        const old_dst = dst.*;
        dst.* = src.*;
        src.* = old_dst;
    }
    pub inline fn clearCells(
        self: *Page,
        row: *Row,
        left: usize,
        end: usize,
    ) void {
        defer self.assertIntegrity();
        const cells = row.cells.ptr(self.memory)[left..end];
        if (row.grapheme) {
            for (cells) |*cell| {
                if (cell.hasGrapheme())
                    @call(.always_inline, clearGrapheme, .{ self, cell });
            }
            if (cells.len == self.size.cols) {
                row.grapheme = false;
            } else {
                self.updateRowGraphemeFlag(row);
            }
        }
        if (row.hyperlink) {
            for (cells) |*cell| {
                if (cell.hyperlink)
                    @call(.always_inline, clearHyperlink, .{ self, cell });
            }
            if (cells.len == self.size.cols) {
                row.hyperlink = false;
            } else {
                self.updateRowHyperlinkFlag(row);
            }
        }
        if (row.styled) {
            for (cells) |*cell| {
                if (cell.hasStyling())
                    self.styles.release(self.memory, cell.style_id);
            }
            if (cells.len == self.size.cols) {
                row.styled = false;
            } else {
                self.updateRowStyledFlag(row);
            }
        }
        if (comptime build_options.kitty_graphics) {
            if (cells.len == self.size.cols) {
                row.kitty_virtual_placeholder = false;
            }
        }
        @memset(@as([]u64, @ptrCast(cells)), 0);
    }
    pub inline fn resetRow(self: *Page, row: *Row) void {
        self.clearCells(row, 0, self.size.cols);
        row.reset();
    }
    pub inline fn lookupHyperlink(self: *const Page, cell: *const Cell) ?hyperlink.Id {
        const cell_offset = getOffset(Cell, self.memory, cell);
        const map = self.hyperlink_map.map(self.memory);
        return map.get(cell_offset);
    }
    pub fn clearHyperlink(self: *Page, cell: *Cell) void {
        defer self.assertIntegrity();
        const cell_offset = getOffset(Cell, self.memory, cell);
        var map = self.hyperlink_map.map(self.memory);
        const entry = map.getEntry(cell_offset) orelse return;
        self.hyperlink_set.release(self.memory, entry.value_ptr.*);
        map.removeByPtr(entry.key_ptr);
        cell.hyperlink = false;
    }
    pub inline fn updateRowHyperlinkFlag(self: *Page, row: *Row) void {
        const cells = row.cells.ptr(self.memory)[0..self.size.cols];
        for (cells) |c| if (c.hyperlink) return;
        row.hyperlink = false;
    }
    pub const InsertHyperlinkError = error{
        StringsOutOfMemory,
        SetOutOfMemory,
        SetNeedsRehash,
    };
    pub fn insertHyperlink(
        self: *Page,
        link: hyperlink.Hyperlink,
    ) InsertHyperlinkError!hyperlink.Id {
        const page_uri: Offset(u8).Slice = uri: {
            const buf = self.string_alloc.alloc(
                u8,
                self.memory,
                link.uri.len,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.StringsOutOfMemory,
            };
            errdefer self.string_alloc.free(self.memory, buf);
            @memcpy(buf, link.uri);
            break :uri .{
                .offset = size.getOffset(u8, self.memory, &buf[0]),
                .len = link.uri.len,
            };
        };
        errdefer self.string_alloc.free(
            self.memory,
            page_uri.slice(self.memory),
        );
        const page_id: hyperlink.PageEntry.Id = switch (link.id) {
            .explicit => |id| explicit: {
                const buf = self.string_alloc.alloc(
                    u8,
                    self.memory,
                    id.len,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.StringsOutOfMemory,
                };
                errdefer self.string_alloc.free(self.memory, buf);
                @memcpy(buf, id);
                break :explicit .{
                    .explicit = .{
                        .offset = size.getOffset(u8, self.memory, &buf[0]),
                        .len = id.len,
                    },
                };
            },
            .implicit => |id| .{ .implicit = id },
        };
        errdefer switch (page_id) {
            .implicit => {},
            .explicit => |slice| self.string_alloc.free(
                self.memory,
                slice.slice(self.memory),
            ),
        };
        const entry: hyperlink.PageEntry = .{
            .id = page_id,
            .uri = page_uri,
        };
        const id = self.hyperlink_set.addContext(
            self.memory,
            entry,
            .{ .page = self },
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.SetOutOfMemory,
            error.NeedsRehash => return error.SetNeedsRehash,
        };
        errdefer self.hyperlink_set.release(self.memory, id);
        return id;
    }
    pub inline fn setHyperlink(self: *Page, row: *Row, cell: *Cell, id: hyperlink.Id) error{HyperlinkMapOutOfMemory}!void {
        defer self.assertIntegrity();
        const cell_offset = getOffset(Cell, self.memory, cell);
        var map = self.hyperlink_map.map(self.memory);
        const gop = map.getOrPut(cell_offset) catch |e| {
            comptime assert(@TypeOf(e) == error{OutOfMemory});
            return error.HyperlinkMapOutOfMemory;
        };
        if (gop.found_existing) {
            self.hyperlink_set.release(self.memory, gop.value_ptr.*);
            if (gop.value_ptr.* == id) {
                assert(row.hyperlink);
                cell.hyperlink = true;
                return;
            }
        }
        gop.value_ptr.* = id;
        cell.hyperlink = true;
        row.hyperlink = true;
    }
    inline fn moveHyperlink(self: *Page, src: *Cell, dst: *Cell) void {
        assert(src.hyperlink);
        assert(!dst.hyperlink);
        const src_offset = getOffset(Cell, self.memory, src);
        const dst_offset = getOffset(Cell, self.memory, dst);
        var map = self.hyperlink_map.map(self.memory);
        const entry = map.getEntry(src_offset).?;
        const value = entry.value_ptr.*;
        map.removeByPtr(entry.key_ptr);
        map.putAssumeCapacityNoClobber(dst_offset, value);
    }
    pub inline fn hyperlinkCount(self: *const Page) usize {
        return self.hyperlink_map.map(self.memory).count();
    }
    pub inline fn hyperlinkCapacity(self: *const Page) usize {
        return self.hyperlink_map.map(self.memory).maxLoad();
    }
    pub inline fn setGraphemes(
        self: *Page,
        row: *Row,
        cell: *Cell,
        cps: []const u21,
    ) GraphemeError!void {
        defer self.assertIntegrity();
        assert(cell.codepoint() > 0);
        assert(cell.content_tag == .codepoint);
        const cell_offset = getOffset(Cell, self.memory, cell);
        var map = self.grapheme_map.map(self.memory);
        const stored_cps = cps[0..@min(cps.len, grapheme_max_len)];
        const slice = self.grapheme_alloc.alloc(u21, self.memory, stored_cps.len) catch |e| {
            comptime assert(@TypeOf(e) == error{OutOfMemory});
            return error.GraphemeAllocOutOfMemory;
        };
        errdefer self.grapheme_alloc.free(self.memory, slice);
        @memcpy(slice, stored_cps);
        map.putNoClobber(cell_offset, .{
            .offset = getOffset(u21, self.memory, @ptrCast(slice.ptr)),
            .len = slice.len,
        }) catch |e| {
            comptime assert(@TypeOf(e) == error{OutOfMemory});
            return error.GraphemeMapOutOfMemory;
        };
        errdefer map.remove(cell_offset);
        cell.content_tag = .codepoint_grapheme;
        row.grapheme = true;
        return;
    }
    pub fn appendGrapheme(self: *Page, row: *Row, cell: *Cell, cp: u21) Allocator.Error!void {
        defer self.assertIntegrity();
        if (build_options.slow_runtime_safety) assert(cell.codepoint() != 0);
        const cell_offset = getOffset(Cell, self.memory, cell);
        var map = self.grapheme_map.map(self.memory);
        if (cell.content_tag != .codepoint_grapheme) {
            const cps = try self.grapheme_alloc.alloc(u21, self.memory, 1);
            errdefer self.grapheme_alloc.free(self.memory, cps);
            cps[0] = cp;
            try map.putNoClobber(cell_offset, .{
                .offset = getOffset(u21, self.memory, @ptrCast(cps.ptr)),
                .len = 1,
            });
            errdefer map.remove(cell_offset);
            cell.content_tag = .codepoint_grapheme;
            row.grapheme = true;
            return;
        }
        assert(row.grapheme);
        const slice = map.getPtr(cell_offset).?;
        if (slice.len >= grapheme_max_len) return;
        if (slice.len % grapheme_chunk_len != 0) {
            const cps = slice.offset.ptr(self.memory);
            cps[slice.len] = cp;
            slice.len += 1;
            return;
        }
        const cps = try self.grapheme_alloc.alloc(u21, self.memory, slice.len + 1);
        errdefer self.grapheme_alloc.free(self.memory, cps);
        const old_cps = slice.slice(self.memory);
        fastmem.copy(u21, cps[0..old_cps.len], old_cps);
        cps[slice.len] = cp;
        slice.* = .{
            .offset = getOffset(u21, self.memory, @ptrCast(cps.ptr)),
            .len = slice.len + 1,
        };
        self.grapheme_alloc.free(self.memory, old_cps);
    }
    pub inline fn lookupGrapheme(self: *const Page, cell: *const Cell) ?[]u21 {
        const cell_offset = getOffset(Cell, self.memory, cell);
        const map = self.grapheme_map.map(self.memory);
        const slice = map.get(cell_offset) orelse return null;
        return slice.slice(self.memory);
    }
    pub inline fn moveGrapheme(self: *Page, src: *Cell, dst: *Cell) void {
        if (build_options.slow_runtime_safety) {
            assert(src.hasGrapheme());
            assert(!dst.hasGrapheme());
        }
        const src_offset = getOffset(Cell, self.memory, src);
        const dst_offset = getOffset(Cell, self.memory, dst);
        var map = self.grapheme_map.map(self.memory);
        const entry = map.getEntry(src_offset).?;
        const value = entry.value_ptr.*;
        map.removeByPtr(entry.key_ptr);
        map.putAssumeCapacityNoClobber(dst_offset, value);
    }
    pub fn clearGrapheme(self: *Page, cell: *Cell) void {
        defer self.assertIntegrity();
        if (build_options.slow_runtime_safety) assert(cell.hasGrapheme());
        const cell_offset = getOffset(Cell, self.memory, cell);
        var map = self.grapheme_map.map(self.memory);
        const entry = map.getEntry(cell_offset).?;
        const cps = entry.value_ptr.slice(self.memory);
        self.grapheme_alloc.free(self.memory, cps);
        map.removeByPtr(entry.key_ptr);
        cell.content_tag = .codepoint;
    }
    pub inline fn updateRowGraphemeFlag(self: *Page, row: *Row) void {
        const cells = row.cells.ptr(self.memory)[0..self.size.cols];
        for (cells) |c| if (c.hasGrapheme()) return;
        row.grapheme = false;
    }
    pub inline fn graphemeCount(self: *const Page) usize {
        return self.grapheme_map.map(self.memory).count();
    }
    pub inline fn graphemeCapacity(self: *const Page) usize {
        return self.grapheme_map.map(self.memory).capacity();
    }
    pub inline fn updateRowStyledFlag(self: *Page, row: *Row) void {
        const cells = row.cells.ptr(self.memory)[0..self.size.cols];
        for (cells) |c| if (c.hasStyling()) return;
        row.styled = false;
    }
    pub inline fn isDirty(self: *const Page) bool {
        if (self.dirty) return true;
        for (self.rows.ptr(self.memory)[0..self.size.rows]) |row| {
            if (row.dirty) return true;
        }
        return false;
    }
    pub const Layout = struct {
        total_size: usize,
        rows_start: usize,
        rows_size: usize,
        cells_start: usize,
        cells_size: usize,
        styles_start: usize,
        styles_layout: StyleSet.Layout,
        grapheme_alloc_start: usize,
        grapheme_alloc_layout: GraphemeAlloc.Layout,
        grapheme_map_start: usize,
        grapheme_map_layout: GraphemeMap.Layout,
        string_alloc_start: usize,
        string_alloc_layout: StringAlloc.Layout,
        hyperlink_map_start: usize,
        hyperlink_map_layout: hyperlink.Map.Layout,
        hyperlink_set_start: usize,
        hyperlink_set_layout: hyperlink.Set.Layout,
        capacity: Capacity,
    };
    pub inline fn layout(cap: Capacity) Layout {
        const meta: MetaLayout = .init(cap);
        const rows_count: usize = @intCast(cap.rows);
        const rows_start = 0;
        const rows_end: usize = rows_start + (rows_count * @sizeOf(Row));
        const cells_count: usize = @as(usize, cap.cols) * @as(usize, cap.rows);
        const cells_start = alignForward(usize, rows_end, cells_align);
        const cells_end = cells_start + (cells_count * @sizeOf(Cell));
        const meta_start = alignForward(usize, cells_end, MetaLayout.alignment);
        const meta_end = meta_start + meta.total_size;
        const total_size = alignForward(usize, meta_end, std.heap.page_size_min);
        return .{
            .total_size = total_size,
            .rows_start = rows_start,
            .rows_size = rows_end - rows_start,
            .cells_start = cells_start,
            .cells_size = cells_end - cells_start,
            .styles_start = meta_start + meta.styles_start,
            .styles_layout = meta.styles_layout,
            .grapheme_alloc_start = meta_start + meta.grapheme_alloc_start,
            .grapheme_alloc_layout = meta.grapheme_alloc_layout,
            .grapheme_map_start = meta_start + meta.grapheme_map_start,
            .grapheme_map_layout = meta.grapheme_map_layout,
            .string_alloc_start = meta_start + meta.string_alloc_start,
            .string_alloc_layout = meta.string_alloc_layout,
            .hyperlink_map_start = meta_start + meta.hyperlink_map_start,
            .hyperlink_map_layout = meta.hyperlink_map_layout,
            .hyperlink_set_start = meta_start + meta.hyperlink_set_start,
            .hyperlink_set_layout = meta.hyperlink_set_layout,
            .capacity = cap,
        };
    }
    pub const MetaLayout = struct {
        total_size: usize,
        styles_start: usize,
        styles_layout: StyleSet.Layout,
        grapheme_alloc_start: usize,
        grapheme_alloc_layout: GraphemeAlloc.Layout,
        grapheme_map_start: usize,
        grapheme_map_layout: GraphemeMap.Layout,
        string_alloc_start: usize,
        string_alloc_layout: StringAlloc.Layout,
        hyperlink_set_start: usize,
        hyperlink_set_layout: hyperlink.Set.Layout,
        hyperlink_map_start: usize,
        hyperlink_map_layout: hyperlink.Map.Layout,
        pub const alignment = @max(
            StyleSet.base_align.toByteUnits(),
            GraphemeAlloc.base_align.toByteUnits(),
            GraphemeMap.base_align.toByteUnits(),
            StringAlloc.base_align.toByteUnits(),
            hyperlink.Set.base_align.toByteUnits(),
            hyperlink.Map.base_align.toByteUnits(),
        );
        pub fn init(cap: Capacity) MetaLayout {
            const styles_layout: StyleSet.Layout = .init(cap.styles);
            const styles_start = 0;
            const styles_end = styles_start + styles_layout.total_size;
            const grapheme_alloc_layout = GraphemeAlloc.layout(cap.grapheme_bytes);
            const grapheme_alloc_start = alignForward(usize, styles_end, GraphemeAlloc.base_align.toByteUnits());
            const grapheme_alloc_end = grapheme_alloc_start + grapheme_alloc_layout.total_size;
            const grapheme_count: usize = count: {
                if (cap.grapheme_bytes == 0) break :count 0;
                const base = std.math.divCeil(usize, cap.grapheme_bytes, grapheme_chunk) catch unreachable;
                break :count std.math.ceilPowerOfTwo(usize, base) catch unreachable;
            };
            const grapheme_map_layout = GraphemeMap.layout(@intCast(grapheme_count));
            const grapheme_map_start = alignForward(usize, grapheme_alloc_end, GraphemeMap.base_align.toByteUnits());
            const grapheme_map_end = grapheme_map_start + grapheme_map_layout.total_size;
            const string_layout = StringAlloc.layout(cap.string_bytes);
            const string_start = alignForward(usize, grapheme_map_end, StringAlloc.base_align.toByteUnits());
            const string_end = string_start + string_layout.total_size;
            const hyperlink_count = @divFloor(cap.hyperlink_bytes, @sizeOf(hyperlink.Set.Item));
            const hyperlink_set_layout: hyperlink.Set.Layout = .init(@intCast(hyperlink_count));
            const hyperlink_set_start = alignForward(usize, string_end, hyperlink.Set.base_align.toByteUnits());
            const hyperlink_set_end = hyperlink_set_start + hyperlink_set_layout.total_size;
            const hyperlink_map_count: u32 = count: {
                if (hyperlink_count == 0) break :count 0;
                const mult = std.math.cast(
                    u32,
                    hyperlink_count * hyperlink_cell_multiplier,
                ) orelse break :count std.math.maxInt(u32);
                break :count mult;
            };
            const hyperlink_map_layout = hyperlink.Map.layout(hyperlink_map_count);
            const hyperlink_map_start = alignForward(usize, hyperlink_set_end, hyperlink.Map.base_align.toByteUnits());
            const hyperlink_map_end = hyperlink_map_start + hyperlink_map_layout.total_size;
            return .{
                .total_size = hyperlink_map_end,
                .styles_start = styles_start,
                .styles_layout = styles_layout,
                .grapheme_alloc_start = grapheme_alloc_start,
                .grapheme_alloc_layout = grapheme_alloc_layout,
                .grapheme_map_start = grapheme_map_start,
                .grapheme_map_layout = grapheme_map_layout,
                .string_alloc_start = string_start,
                .string_alloc_layout = string_layout,
                .hyperlink_set_start = hyperlink_set_start,
                .hyperlink_set_layout = hyperlink_set_layout,
                .hyperlink_map_start = hyperlink_map_start,
                .hyperlink_map_layout = hyperlink_map_layout,
            };
        }
    };
};
pub const std_capacity: Capacity = .{
    .cols = 215,
    .rows = 215,
    .styles = 128,
    .grapheme_bytes = if (builtin.is_test) 512 else 8192,
};
pub const Size = struct {
    cols: size.CellCountInt,
    rows: size.CellCountInt,
};
pub const Capacity = struct {
    cols: size.CellCountInt,
    rows: size.CellCountInt,
    styles: size.StyleCountInt = 16,
    hyperlink_bytes: size.HyperlinkCountInt = hyperlink_bytes_default,
    grapheme_bytes: size.GraphemeBytesInt = grapheme_bytes_default,
    string_bytes: size.StringBytesInt = string_bytes_default,
    pub const Adjustment = struct {
        cols: ?size.CellCountInt = null,
    };
    pub fn maxCols(self: Capacity) ?size.CellCountInt {
        const available = self.availableBytesForGrid();
        const row_region = alignForward(usize, @sizeOf(Row), cells_align);
        if (available <= row_region) return null;
        const max_cols = (available - row_region) / @sizeOf(Cell);
        return @min(std.math.maxInt(size.CellCountInt), max_cols);
    }
    pub fn adjust(self: Capacity, req: Adjustment) Allocator.Error!Capacity {
        var adjusted = self;
        if (req.cols) |cols| {
            const total_size = Page.layout(self).total_size;
            const available = self.availableBytesForGrid();
            const bytes_per_row: usize = @sizeOf(Row) + @sizeOf(Cell) * @as(usize, @intCast(cols));
            var new_rows: usize = @divFloor(available, bytes_per_row);
            adjusted.cols = cols;
            while (new_rows > 0) : (new_rows -= 1) {
                adjusted.rows = @intCast(new_rows);
                if (Page.layout(adjusted).total_size <= total_size) break;
            }
            if (new_rows == 0) return error.OutOfMemory;
        }
        return adjusted;
    }
    fn availableBytesForGrid(self: Capacity) usize {
        comptime {
            assert(cells_align % Page.MetaLayout.alignment == 0);
            assert(@sizeOf(Cell) % Page.MetaLayout.alignment == 0);
        }
        const l = Page.layout(self);
        return l.total_size - Page.MetaLayout.init(self).total_size;
    }
};
pub const Row = packed struct(u64) {
    cells: Offset(Cell),
    wrap: bool = false,
    wrap_continuation: bool = false,
    grapheme: bool = false,
    styled: bool = false,
    hyperlink: bool = false,
    semantic_prompt: SemanticPrompt = .none,
    kitty_virtual_placeholder: bool = false,
    dirty: bool = false,
    _padding: u23 = 0,
    pub const SemanticPrompt = enum(u2) {
        none = 0,
        prompt = 1,
        prompt_continuation = 2,
    };
    pub const Backing = @typeInfo(Row).@"struct".backing_integer.?;
    pub const C = u64;
    pub fn cval(self: Row) C {
        return @bitCast(self);
    }
    pub inline fn managedMemory(self: Row) bool {
        return self.styled or self.hyperlink or self.grapheme;
    }
    pub inline fn reset(self: *Row) void {
        assert(!self.managedMemory());
        self.* = .{ .cells = self.cells, .dirty = true };
    }
};
pub const Cell = packed struct(u64) {
    content_tag: ContentTag = .codepoint,
    content: packed union {
        codepoint: packed struct(u24) {
            data: u21,
            _pad: u3 = 0,
        },
        color_palette: packed struct(u24) {
            data: u8,
            _pad: u16 = 0,
        },
        color_rgb: RGB,
    } = .{ .codepoint = .{ .data = 0 } },
    style_id: StyleId = 0,
    wide: Wide = .narrow,
    protected: bool = false,
    hyperlink: bool = false,
    semantic_content: SemanticContent = .output,
    _padding: u16 = 0,
    pub const ContentTag = enum(u2) {
        codepoint = 0,
        codepoint_grapheme = 1,
        bg_color_palette = 2,
        bg_color_rgb = 3,
    };
    pub const RGB = packed struct {
        r: u8,
        g: u8,
        b: u8,
    };
    pub const Wide = enum(u2) {
        narrow = 0,
        wide = 1,
        spacer_tail = 2,
        spacer_head = 3,
    };
    pub const SemanticContent = enum(u2) {
        output = 0,
        input = 1,
        prompt = 2,
    };
    pub const CLayout = lib.Packed(Cell, .{ .fields = .{
        .content_tag = .{ .type_name = "WaspCellContentTag" },
        .content = .{ .encoding = .{ .tagged_union = lib.PackedTaggedUnion(
            Cell,
            .content,
            .content_tag,
            .{ .arms = .{
                .codepoint = .{ .codepoint = lib.Packed(
                    @FieldType(@FieldType(Cell, "content"), "codepoint"),
                    .{ .fields = .{
                        .data = .{ .name = "codepoint" },
                        ._pad = .{ .omit = true },
                    } },
                ) },
                .codepoint_grapheme = .{ .codepoint = lib.Packed(
                    @FieldType(@FieldType(Cell, "content"), "codepoint"),
                    .{ .fields = .{
                        .data = .{ .name = "codepoint" },
                        ._pad = .{ .omit = true },
                    } },
                ) },
                .bg_color_palette = .{ .color_palette = lib.Packed(
                    @FieldType(@FieldType(Cell, "content"), "color_palette"),
                    .{ .fields = .{
                        .data = .{
                            .name = "index",
                            .type_name = "WaspColorPaletteIndex",
                        },
                        ._pad = .{ .omit = true },
                    } },
                ) },
                .bg_color_rgb = .{ .color_rgb = lib.Packed(
                    @FieldType(@FieldType(Cell, "content"), "color_rgb"),
                    .{},
                ) },
            } },
        ) } },
        .style_id = .{ .type_name = "WaspStyleId" },
        .wide = .{ .type_name = "WaspCellWide" },
        .semantic_content = .{ .type_name = "WaspCellSemanticContent" },
        ._padding = .{ .omit = true },
    } });
    pub const Backing = @typeInfo(Cell).@"struct".backing_integer.?;
    pub const C = u64;
    pub fn cval(self: Cell) C {
        return @bitCast(self);
    }
    pub fn init(cp: u21) Cell {
        var cell: Cell = @bitCast(@as(u64, 0));
        cell.content_tag = .codepoint;
        cell.content = .{ .codepoint = .{ .data = cp } };
        return cell;
    }
    pub inline fn isZero(self: Cell) bool {
        return @as(u64, @bitCast(self)) == 0;
    }
    pub inline fn hasText(self: Cell) bool {
        return switch (self.content_tag) {
            .codepoint,
            .codepoint_grapheme,
            => self.content.codepoint.data != 0,
            .bg_color_palette,
            .bg_color_rgb,
            => false,
        };
    }
    pub inline fn codepoint(self: Cell) u21 {
        return switch (self.content_tag) {
            .codepoint,
            .codepoint_grapheme,
            => self.content.codepoint.data,
            .bg_color_palette,
            .bg_color_rgb,
            => 0,
        };
    }
    pub inline fn gridWidth(self: Cell) u2 {
        return switch (self.wide) {
            .narrow, .spacer_head, .spacer_tail => 1,
            .wide => 2,
        };
    }
    pub inline fn hasStyling(self: Cell) bool {
        return self.style_id != stylepkg.default_id;
    }
    pub fn isEmpty(self: Cell) bool {
        return switch (self.content_tag) {
            .codepoint,
            .codepoint_grapheme,
            => !self.hasText() and self.wide == .narrow,
            .bg_color_palette,
            .bg_color_rgb,
            => false,
        };
    }
    pub inline fn hasGrapheme(self: Cell) bool {
        return self.content_tag == .codepoint_grapheme;
    }
    pub inline fn hasTextAny(cells: []const Cell) bool {
        for (cells) |cell| {
            if (cell.hasText()) return true;
        }
        return false;
    }
};
fn fieldMask(
    comptime T: type,
    comptime fields: []const []const u8,
) @typeInfo(T).@"struct".backing_integer.? {
    const Int = @typeInfo(T).@"struct".backing_integer.?;
    comptime var mask: Int = 0;
    inline for (fields) |path| {
        comptime var offset = 0;
        comptime var Field = T;
        comptime var it = std.mem.splitScalar(u8, path, '.');
        inline while (comptime it.next()) |name| {
            offset += switch (@typeInfo(Field)) {
                .@"struct" => @bitOffsetOf(Field, name),
                .@"union" => |u| offset: {
                    comptime assert(u.layout == .@"packed");
                    break :offset 0;
                },
                else => @compileError("invalid field path: " ++ path),
            };
            Field = @FieldType(Field, name);
        }
        const Ones = std.meta.Int(.unsigned, @bitSizeOf(Field));
        mask |= @as(Int, std.math.maxInt(Ones)) << offset;
    }
    return mask;
}
pub fn Mask(
    comptime T: type,
    comptime fields: []const []const u8,
    comptime group_len_param: comptime_int,
) type {
    return struct {
        const Backing = @typeInfo(T).@"struct".backing_integer.?;
        const mask: Backing = fieldMask(T, fields);
        pub const group_len = group_len_param;
        const Group = @Vector(group_len, Backing);
        inline fn load(values: []const T, i: usize) Group {
            return @bitCast(values[i..][0..group_len].*);
        }
        pub inline fn bits(v: T) Backing {
            return @bitCast(v);
        }
        pub inline fn pattern(v: T) Backing {
            return bits(v) & mask;
        }
        pub inline fn strip(v: T) Backing {
            return bits(v) & ~mask;
        }
        pub inline fn match(values: []const T, i: usize) bool {
            return @reduce(.Or, load(values, i)) & mask == 0;
        }
        pub inline fn matchScalar(v: T) bool {
            return bits(v) & mask == 0;
        }
        pub inline fn eql(
            values: []const T,
            i: usize,
            expected: Backing,
        ) bool {
            const masked = load(values, i) & @as(Group, @splat(mask));
            return @reduce(.And, masked == @as(Group, @splat(expected)));
        }
        pub inline fn eqlScalar(v: T, expected: Backing) bool {
            return pattern(v) == expected;
        }
        pub inline fn eqlAny(
            values: []const T,
            i: usize,
            expected: Backing,
        ) bool {
            const masked = load(values, i) & @as(Group, @splat(mask));
            return @reduce(.Or, masked == @as(Group, @splat(expected)));
        }
        pub inline fn eqlPrefix(
            values: []const T,
            i: usize,
            expected: Backing,
        ) usize {
            const masked = load(values, i) & @as(Group, @splat(mask));
            const ok = masked == @as(Group, @splat(expected));
            if (@reduce(.And, ok)) {
                @branchHint(.likely);
                return group_len;
            }
            const ok_bits: std.meta.Int(
                .unsigned,
                group_len,
            ) = @bitCast(ok);
            return @ctz(~ok_bits);
        }
        pub inline fn eqlExact(
            values: []const T,
            i: usize,
            expected: Backing,
        ) bool {
            const group = load(values, i);
            return @reduce(.And, group == @as(Group, @splat(expected)));
        }
    };
}
test "Mask" {
    const M = Mask(Cell, &.{ "content_tag", "style_id" }, 4);
    const plain: Cell = .init('A');
    var styled: Cell = .init('B');
    styled.style_id = 5;
    var styled2: Cell = .init('C');
    styled2.style_id = 5;
    var other: Cell = .init('D');
    other.style_id = 6;
    {
        var cells: [4]Cell = .{ plain, plain, plain, plain };
        try testing.expect(M.match(&cells, 0));
        try testing.expect(M.matchScalar(plain));
        cells[2] = styled;
        try testing.expect(!M.match(&cells, 0));
        try testing.expect(!M.matchScalar(styled));
    }
    {
        const expected = M.pattern(styled);
        var cells: [4]Cell = .{ styled, styled2, styled, styled2 };
        try testing.expect(M.eql(&cells, 0, expected));
        try testing.expect(M.eqlScalar(styled2, expected));
        cells[1] = other;
        try testing.expect(!M.eql(&cells, 0, expected));
        try testing.expect(!M.eqlScalar(other, expected));
    }
    {
        const expected = M.pattern(styled);
        var cells: [4]Cell = .{ styled, styled2, other, styled };
        try testing.expectEqual(2, M.eqlPrefix(&cells, 0, expected));
        cells[2] = styled;
        try testing.expectEqual(4, M.eqlPrefix(&cells, 0, expected));
    }
    {
        const expected = M.bits(styled);
        var cells: [4]Cell = .{ styled, styled, styled, styled };
        try testing.expect(M.eqlExact(&cells, 0, expected));
        cells[3] = styled2;
        try testing.expect(!M.eqlExact(&cells, 0, expected));
    }
    {
        var styled_other: Cell = .init('B');
        styled_other.style_id = 6;
        try testing.expectEqual(M.strip(styled), M.strip(styled_other));
        try testing.expect(M.strip(styled) != M.strip(styled2));
    }
    {
        const expected = M.pattern(styled);
        var cells: [4]Cell = .{ plain, plain, plain, plain };
        try testing.expect(!M.eqlAny(&cells, 0, expected));
        cells[2] = styled;
        try testing.expect(M.eqlAny(&cells, 0, expected));
        cells[2] = styled2;
        try testing.expect(M.eqlAny(&cells, 0, expected));
    }
}
test "Mask nested field path" {
    const M = Mask(Cell, &.{"content.codepoint.data"}, 4);
    const a: Cell = .init('A');
    var b: Cell = .init('A');
    b.style_id = 5;
    b.wide = .wide;
    const c: Cell = .init('C');
    const expected = M.pattern(a);
    try testing.expect(M.eqlScalar(b, expected));
    try testing.expect(!M.eqlScalar(c, expected));
    const cp_offset = @bitOffsetOf(Cell, "content");
    try testing.expectEqual(
        @as(u64, std.math.maxInt(u21)) << cp_offset,
        comptime fieldMask(Cell, &.{"content.codepoint.data"}),
    );
    {
        var cells: [4]Cell = .{ a, b, a, b };
        try testing.expect(M.eql(&cells, 0, expected));
        try testing.expect(M.eqlAny(&cells, 0, expected));
        cells[1] = c;
        try testing.expect(!M.eql(&cells, 0, expected));
        try testing.expect(M.eqlAny(&cells, 0, expected));
        const none: [4]Cell = .{ c, c, c, c };
        try testing.expect(!M.eqlAny(&none, 0, expected));
    }
}
test "Page.layout can take a maxed capacity" {
    var cap: Capacity = undefined;
    inline for (@typeInfo(Capacity).@"struct".fields) |field| {
        @field(cap, field.name) = std.math.maxInt(field.type);
    }
    _ = Page.layout(cap);
}
test "Cell is zero by default" {
    const cell = Cell.init(0);
    const cell_int: u64 = @bitCast(cell);
    try std.testing.expectEqual(@as(u64, 0), cell_int);
    try std.testing.expectEqual(Cell.SemanticContent.output, cell.semantic_content);
}
test "Page capacity adjust cols down" {
    const original = std_capacity;
    const original_size = Page.layout(original).total_size;
    const adjusted = try original.adjust(.{ .cols = original.cols / 2 });
    const adjusted_size = Page.layout(adjusted).total_size;
    try testing.expectEqual(original_size, adjusted_size);
    var bigger = adjusted;
    bigger.rows += 1;
    const bigger_size = Page.layout(bigger).total_size;
    try testing.expect(bigger_size > original_size);
}
test "Page capacity adjust cols down to 1" {
    const original = std_capacity;
    const original_size = Page.layout(original).total_size;
    const adjusted = try original.adjust(.{ .cols = 1 });
    const adjusted_size = Page.layout(adjusted).total_size;
    try testing.expectEqual(original_size, adjusted_size);
    var bigger = adjusted;
    bigger.rows += 1;
    const bigger_size = Page.layout(bigger).total_size;
    try testing.expect(bigger_size > original_size);
}
test "Page capacity adjust cols up" {
    const original = std_capacity;
    const original_size = Page.layout(original).total_size;
    const adjusted = try original.adjust(.{ .cols = original.cols * 2 });
    const adjusted_size = Page.layout(adjusted).total_size;
    try testing.expectEqual(original_size, adjusted_size);
    var bigger = adjusted;
    bigger.rows += 1;
    const bigger_size = Page.layout(bigger).total_size;
    try testing.expect(bigger_size > original_size);
}
test "Page capacity adjust cols sweep" {
    var cap = std_capacity;
    const original_cols = cap.cols;
    const original_size = Page.layout(cap).total_size;
    for (1..original_cols * 2) |c| {
        cap = try cap.adjust(.{ .cols = @as(u16, @intCast(c)) });
        const adjusted_size = Page.layout(cap).total_size;
        try testing.expectEqual(original_size, adjusted_size);
        var bigger = cap;
        bigger.rows += 1;
        const bigger_size = Page.layout(bigger).total_size;
        try testing.expect(bigger_size > original_size);
    }
}
test "Page capacity adjust cols too high" {
    const original = std_capacity;
    try testing.expectError(
        error.OutOfMemory,
        original.adjust(.{ .cols = std.math.maxInt(size.CellCountInt) }),
    );
}
test "Capacity maxCols basic" {
    const cap = std_capacity;
    const max = cap.maxCols().?;
    try testing.expect(max >= cap.cols);
    const adjusted = try cap.adjust(.{ .cols = max });
    try testing.expect(adjusted.rows >= 1);
    try testing.expectError(
        error.OutOfMemory,
        cap.adjust(.{ .cols = max + 1 }),
    );
}
test "Capacity maxCols preserves total size" {
    const cap = std_capacity;
    const original_size = Page.layout(cap).total_size;
    const max = cap.maxCols().?;
    const adjusted = try cap.adjust(.{ .cols = max });
    const adjusted_size = Page.layout(adjusted).total_size;
    try testing.expectEqual(original_size, adjusted_size);
}
test "Capacity maxCols with 1 row exactly" {
    const cap = std_capacity;
    const max = cap.maxCols().?;
    const adjusted = try cap.adjust(.{ .cols = max });
    try testing.expectEqual(@as(size.CellCountInt, 1), adjusted.rows);
}
test "Page init" {
    var page = try Page.init(.{
        .cols = 120,
        .rows = 80,
        .styles = 32,
    });
    defer page.deinit();
}
test "Page read and write cells" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{
                .codepoint = .{ .data = @intCast(y) },
            },
        };
    }
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint.data);
    }
}
test "Page appendGrapheme small" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    const rac = page.getRowAndCell(0, 0);
    rac.cell.* = .init(0x09);
    try page.appendGrapheme(rac.row, rac.cell, 0x0A);
    try testing.expect(rac.row.grapheme);
    try testing.expect(rac.cell.hasGrapheme());
    try testing.expectEqualSlices(u21, &.{0x0A}, page.lookupGrapheme(rac.cell).?);
    try page.appendGrapheme(rac.row, rac.cell, 0x0B);
    try testing.expect(rac.row.grapheme);
    try testing.expect(rac.cell.hasGrapheme());
    try testing.expectEqualSlices(u21, &.{ 0x0A, 0x0B }, page.lookupGrapheme(rac.cell).?);
    page.clearGrapheme(rac.cell);
    page.updateRowGraphemeFlag(rac.row);
    try testing.expect(!rac.row.grapheme);
    try testing.expect(!rac.cell.hasGrapheme());
}
test "Page appendGrapheme larger than chunk" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    const rac = page.getRowAndCell(0, 0);
    rac.cell.* = .init(0x09);
    const count = grapheme_chunk_len * 10;
    for (0..count) |i| {
        try page.appendGrapheme(rac.row, rac.cell, @intCast(0x0A + i));
    }
    const cps = page.lookupGrapheme(rac.cell).?;
    try testing.expectEqual(@as(usize, count), cps.len);
    for (0..count) |i| {
        try testing.expectEqual(@as(u21, @intCast(0x0A + i)), cps[i]);
    }
}
test "Page appendGrapheme caps codepoints per cell" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    const rac = page.getRowAndCell(0, 0);
    rac.cell.* = .init('A');
    for (0..grapheme_max_len + 16) |i| {
        try page.appendGrapheme(rac.row, rac.cell, @intCast(0x0300 + i));
    }
    const cps = page.lookupGrapheme(rac.cell).?;
    try testing.expectEqual(@as(usize, grapheme_max_len), cps.len);
    for (0..grapheme_max_len) |i| {
        try testing.expectEqual(@as(u21, @intCast(0x0300 + i)), cps[i]);
    }
}
test "Page setGraphemes caps codepoints per cell" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    var input: [grapheme_max_len + 16]u21 = undefined;
    for (&input, 0..) |*cp, i| cp.* = @intCast(0x0300 + i);
    const rac = page.getRowAndCell(0, 0);
    rac.cell.* = .init('A');
    try page.setGraphemes(rac.row, rac.cell, &input);
    try testing.expectEqual(
        @as(usize, grapheme_max_len),
        page.lookupGrapheme(rac.cell).?.len,
    );
}
test "Page clearGrapheme not all cells" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    const rac = page.getRowAndCell(0, 0);
    rac.cell.* = .init(0x09);
    try page.appendGrapheme(rac.row, rac.cell, 0x0A);
    const rac2 = page.getRowAndCell(1, 0);
    rac2.cell.* = .init(0x09);
    try page.appendGrapheme(rac2.row, rac2.cell, 0x0A);
    page.clearGrapheme(rac.cell);
    page.updateRowGraphemeFlag(rac.row);
    try testing.expect(rac.row.grapheme);
    try testing.expect(!rac.cell.hasGrapheme());
    try testing.expect(rac2.cell.hasGrapheme());
}
test "Page clearCells full row clears kitty placeholder flag" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    const rac = page.getRowAndCell(0, 0);
    rac.cell.* = .init(kitty.graphics.unicode.placeholder);
    rac.row.kitty_virtual_placeholder = true;
    page.clearCells(rac.row, 0, page.size.cols);
    try testing.expect(!rac.row.kitty_virtual_placeholder);
}
test "Page clone" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast(y) } },
        };
    }
    var page2 = try page.clone();
    defer page2.deinit();
    try testing.expectEqual(page2.capacity, page.capacity);
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint.data);
    }
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 0 } },
        };
    }
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint.data);
    }
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
    }
}
test "Page clone graphemes" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    {
        const rac = page.getRowAndCell(0, 0);
        rac.cell.* = .init(0x09);
        try page.appendGrapheme(rac.row, rac.cell, 0x0A);
        try page.appendGrapheme(rac.row, rac.cell, 0x0B);
    }
    var page2 = try page.clone();
    defer page2.deinit();
    {
        const rac = page2.getRowAndCell(0, 0);
        try testing.expect(rac.row.grapheme);
        try testing.expect(rac.cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{ 0x0A, 0x0B }, page2.lookupGrapheme(rac.cell).?);
    }
}
test "Page clone styles" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    {
        const id = try page.styles.add(page.memory, .{ .flags = .{
            .bold = true,
        } });
        for (0..page.size.cols) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.row.styled = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x + 1) } },
                .style_id = id,
            };
            page.styles.use(page.memory, id);
        }
    }
    var page2 = try page.clone();
    defer page2.deinit();
    {
        const id: u16 = style: {
            const rac = page2.getRowAndCell(0, 0);
            break :style rac.cell.style_id;
        };
        for (0..page.size.cols) |x| {
            const rac = page.getRowAndCell(x, 0);
            try testing.expect(rac.row.styled);
            try testing.expectEqual(id, rac.cell.style_id);
        }
        const style = page.styles.get(
            page.memory,
            id,
        );
        try testing.expect((Style{ .flags = .{
            .bold = true,
        } }).eql(style.*));
    }
}
test "Page cloneFrom" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast(y) } },
        };
    }
    var page2 = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page2.deinit();
    try page2.cloneFrom(&page, 0, page.size.rows);
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint.data);
    }
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 0 } },
        };
    }
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint.data);
    }
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
    }
}
test "Page cloneFrom shrink columns" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast(y) } },
        };
    }
    var page2 = try Page.init(.{
        .cols = 5,
        .rows = 10,
        .styles = 8,
    });
    defer page2.deinit();
    try page2.cloneFrom(&page, 0, page.size.rows);
    try testing.expectEqual(@as(size.CellCountInt, 5), page2.size.cols);
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint.data);
    }
}
test "Page cloneFrom partial" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast(y) } },
        };
    }
    var page2 = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page2.deinit();
    try page2.cloneFrom(&page, 0, 5);
    for (0..5) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint.data);
    }
    for (5..page2.size.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
    }
}
test "Page cloneFrom hyperlinks exact capacity" {
    var page = try Page.init(.{
        .cols = 50,
        .rows = 50,
    });
    defer page.deinit();
    const hyperlink_cap = page.hyperlinkCapacity();
    try testing.expect(hyperlink_cap <= page.size.cols * page.size.rows);
    const hyperlink_id = try page.insertHyperlink(.{
        .id = .{ .implicit = 0 },
        .uri = "https://example.com",
    });
    fill: for (0..page.size.cols) |x| {
        for (0..page.size.rows) |y| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 42 } },
            };
            try page.setHyperlink(rac.row, rac.cell, hyperlink_id);
            page.hyperlink_set.use(page.memory, hyperlink_id);
            if (page.hyperlinkCount() == hyperlink_cap) {
                break :fill;
            }
        }
    }
    try testing.expectEqual(page.hyperlinkCount(), page.hyperlinkCapacity());
    var page2 = try Page.init(page.capacity);
    defer page2.deinit();
    try page2.cloneFrom(&page, 0, page.size.rows);
    try testing.expectEqual(page2.hyperlinkCount(), page.hyperlinkCount());
}
test "Page cloneFrom graphemes" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast(y + 1) } },
        };
        try page.appendGrapheme(rac.row, rac.cell, 0x0A);
    }
    var page2 = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page2.deinit();
    try page2.cloneFrom(&page, 0, page.size.rows);
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y + 1)), rac.cell.content.codepoint.data);
        try testing.expect(rac.row.grapheme);
        try testing.expect(rac.cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{0x0A}, page2.lookupGrapheme(rac.cell).?);
    }
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        page.clearGrapheme(rac.cell);
        page.updateRowGraphemeFlag(rac.row);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 0 } },
        };
    }
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y + 1)), rac.cell.content.codepoint.data);
        try testing.expect(rac.row.grapheme);
        try testing.expect(rac.cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{0x0A}, page2.lookupGrapheme(rac.cell).?);
    }
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
    }
}
test "Page cloneFrom frees dst graphemes" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast(y + 1) } },
        };
    }
    var page2 = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page2.deinit();
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast(y + 1) } },
        };
        try page2.appendGrapheme(rac.row, rac.cell, 0x0A);
    }
    try page2.cloneFrom(&page, 0, page.size.rows);
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y + 1)), rac.cell.content.codepoint.data);
        try testing.expect(!rac.row.grapheme);
        try testing.expect(!rac.cell.hasGrapheme());
    }
    try testing.expectEqual(@as(usize, 0), page2.graphemeCount());
}
test "Page cloneRowFrom partial" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    {
        const y = 0;
        for (0..page.size.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x + 1) } },
            };
        }
    }
    var page2 = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page2.deinit();
    try page2.clonePartialRowFrom(
        &page,
        page2.getRow(0),
        page.getRow(0),
        2,
        8,
    );
    {
        const y = 0;
        for (0..page2.size.cols) |x| {
            const expected: u21 = if (x >= 2 and x < 8) @intCast(x + 1) else 0;
            const rac = page2.getRowAndCell(x, y);
            try testing.expectEqual(expected, rac.cell.content.codepoint.data);
        }
    }
}
test "Page cloneRowFrom partial grapheme in non-copied source region" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    {
        const y = 0;
        for (0..page.size.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x + 1) } },
            };
        }
        {
            const rac = page.getRowAndCell(0, y);
            try page.appendGrapheme(rac.row, rac.cell, 0x0A);
        }
        {
            const rac = page.getRowAndCell(9, y);
            try page.appendGrapheme(rac.row, rac.cell, 0x0A);
        }
    }
    try testing.expectEqual(@as(usize, 2), page.graphemeCount());
    var page2 = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page2.deinit();
    try page2.clonePartialRowFrom(
        &page,
        page2.getRow(0),
        page.getRow(0),
        2,
        8,
    );
    {
        const y = 0;
        for (0..page2.size.cols) |x| {
            const expected: u21 = if (x >= 2 and x < 8) @intCast(x + 1) else 0;
            const rac = page2.getRowAndCell(x, y);
            try testing.expectEqual(expected, rac.cell.content.codepoint.data);
            try testing.expect(!rac.cell.hasGrapheme());
        }
        {
            const rac = page2.getRowAndCell(9, y);
            try testing.expect(!rac.row.grapheme);
        }
    }
    try testing.expectEqual(@as(usize, 0), page2.graphemeCount());
}
test "Page cloneRowFrom partial grapheme in non-copied dest region" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    {
        const y = 0;
        for (0..page.size.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x + 1) } },
            };
        }
    }
    try testing.expectEqual(@as(usize, 0), page.graphemeCount());
    var page2 = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page2.deinit();
    {
        const y = 0;
        for (0..page2.size.cols) |x| {
            const rac = page2.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0xBB } },
            };
        }
        {
            const rac = page2.getRowAndCell(0, y);
            try page2.appendGrapheme(rac.row, rac.cell, 0x0A);
        }
        {
            const rac = page2.getRowAndCell(9, y);
            try page2.appendGrapheme(rac.row, rac.cell, 0x0A);
        }
    }
    try page2.clonePartialRowFrom(
        &page,
        page2.getRow(0),
        page.getRow(0),
        2,
        8,
    );
    {
        const y = 0;
        for (0..page2.size.cols) |x| {
            const expected: u21 = if (x >= 2 and x < 8) @intCast(x + 1) else 0xBB;
            const rac = page2.getRowAndCell(x, y);
            try testing.expectEqual(expected, rac.cell.content.codepoint.data);
        }
        {
            const rac = page2.getRowAndCell(9, y);
            try testing.expect(rac.row.grapheme);
        }
    }
    try testing.expectEqual(@as(usize, 2), page2.graphemeCount());
}
test "Page cloneRowFrom partial hyperlink in same page copy" {
    var page = try Page.init(.{ .cols = 10, .rows = 10 });
    defer page.deinit();
    const hyperlink_id = try page.hyperlink_set.addContext(
        page.memory,
        .{ .id = .{ .implicit = 0 }, .uri = .{} },
        .{ .page = &page },
    );
    {
        const y = 0;
        for (0..page.size.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x + 1) } },
            };
        }
        {
            const rac = page.getRowAndCell(7, y);
            try page.setHyperlink(rac.row, rac.cell, hyperlink_id);
        }
    }
    try testing.expectEqual(@as(usize, 1), page.hyperlinkCount());
    try page.clonePartialRowFrom(
        &page,
        page.getRow(1),
        page.getRow(0),
        2,
        8,
    );
    {
        const y = 1;
        for (0..page.size.cols) |x| {
            const expected: u21 = if (x >= 2 and x < 8) @intCast(x + 1) else 0;
            const rac = page.getRowAndCell(x, y);
            try testing.expectEqual(expected, rac.cell.content.codepoint.data);
        }
        {
            const rac = page.getRowAndCell(7, y);
            try testing.expect(rac.row.hyperlink);
            try testing.expect(rac.cell.hyperlink);
        }
    }
    try testing.expectEqual(@as(usize, 2), page.hyperlinkCount());
}
test "Page cloneRowFrom partial hyperlink in same page omit" {
    var page = try Page.init(.{ .cols = 10, .rows = 10 });
    defer page.deinit();
    const hyperlink_id = try page.hyperlink_set.addContext(
        page.memory,
        .{ .id = .{ .implicit = 0 }, .uri = .{} },
        .{ .page = &page },
    );
    {
        const y = 0;
        for (0..page.size.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x + 1) } },
            };
        }
        {
            const rac = page.getRowAndCell(7, y);
            try page.setHyperlink(rac.row, rac.cell, hyperlink_id);
        }
    }
    try testing.expectEqual(@as(usize, 1), page.hyperlinkCount());
    try page.clonePartialRowFrom(
        &page,
        page.getRow(1),
        page.getRow(0),
        2,
        6,
    );
    {
        const y = 1;
        for (0..page.size.cols) |x| {
            const expected: u21 = if (x >= 2 and x < 6) @intCast(x + 1) else 0;
            const rac = page.getRowAndCell(x, y);
            try testing.expectEqual(expected, rac.cell.content.codepoint.data);
        }
        {
            const rac = page.getRowAndCell(7, y);
            try testing.expect(!rac.row.hyperlink);
            try testing.expect(!rac.cell.hyperlink);
        }
    }
    try testing.expectEqual(@as(usize, 1), page.hyperlinkCount());
}
test "Page moveCells text-only" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    for (0..page.capacity.cols) |x| {
        const rac = page.getRowAndCell(x, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast(x + 1) } },
        };
    }
    const src = page.getRow(0);
    const dst = page.getRow(1);
    page.moveCells(src, 0, dst, 0, page.capacity.cols);
    for (0..page.capacity.cols) |x| {
        const rac = page.getRowAndCell(x, 1);
        try testing.expectEqual(
            @as(u21, @intCast(x + 1)),
            rac.cell.content.codepoint.data,
        );
    }
    for (0..page.capacity.cols) |x| {
        const rac = page.getRowAndCell(x, 0);
        try testing.expectEqual(
            @as(u21, 0),
            rac.cell.content.codepoint.data,
        );
    }
}
test "Page moveCells graphemes" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    for (0..page.size.cols) |x| {
        const rac = page.getRowAndCell(x, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast(x + 1) } },
        };
        try page.appendGrapheme(rac.row, rac.cell, 0x0A);
    }
    const original_count = page.graphemeCount();
    const src = page.getRow(0);
    const dst = page.getRow(1);
    page.moveCells(src, 0, dst, 0, page.size.cols);
    try testing.expectEqual(original_count, page.graphemeCount());
    for (0..page.size.cols) |x| {
        const rac = page.getRowAndCell(x, 1);
        try testing.expectEqual(
            @as(u21, @intCast(x + 1)),
            rac.cell.content.codepoint.data,
        );
        try testing.expectEqualSlices(
            u21,
            &.{0x0A},
            page.lookupGrapheme(rac.cell).?,
        );
    }
    for (0..page.size.cols) |x| {
        const rac = page.getRowAndCell(x, 0);
        try testing.expectEqual(
            @as(u21, 0),
            rac.cell.content.codepoint.data,
        );
    }
}
test "Page verifyIntegrity graphemes good" {
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    for (0..page.size.cols) |x| {
        const rac = page.getRowAndCell(x, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast(x + 1) } },
        };
        try page.appendGrapheme(rac.row, rac.cell, 0x0A);
    }
    try page.verifyIntegrity(testing.allocator);
}
test "Page verifyIntegrity grapheme row not marked" {
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    for (0..page.size.cols) |x| {
        const rac = page.getRowAndCell(x, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast(x + 1) } },
        };
        try page.appendGrapheme(rac.row, rac.cell, 0x0A);
    }
    page.getRow(0).grapheme = false;
    try testing.expectError(
        Page.IntegrityError.UnmarkedGraphemeRow,
        page.verifyIntegrity(testing.allocator),
    );
}
test "Page verifyIntegrity styles good" {
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    const id = try page.styles.add(page.memory, .{ .flags = .{
        .bold = true,
    } });
    for (0..page.size.cols) |x| {
        const rac = page.getRowAndCell(x, 0);
        rac.row.styled = true;
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast(x + 1) } },
            .style_id = id,
        };
        page.styles.use(page.memory, id);
    }
    page.styles.release(page.memory, id);
    try page.verifyIntegrity(testing.allocator);
}
test "Page verifyIntegrity styles ref count mismatch" {
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    const id = try page.styles.add(page.memory, .{ .flags = .{
        .bold = true,
    } });
    for (0..page.size.cols) |x| {
        const rac = page.getRowAndCell(x, 0);
        rac.row.styled = true;
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast(x + 1) } },
            .style_id = id,
        };
        page.styles.use(page.memory, id);
    }
    page.styles.release(page.memory, id);
    page.styles.release(page.memory, id);
    try testing.expectError(
        Page.IntegrityError.MismatchedStyleRef,
        page.verifyIntegrity(testing.allocator),
    );
}
test "Page verifyIntegrity zero rows" {
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    page.size.rows = 0;
    try testing.expectError(
        Page.IntegrityError.ZeroRowCount,
        page.verifyIntegrity(testing.allocator),
    );
}
test "Page verifyIntegrity zero cols" {
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    page.size.cols = 0;
    try testing.expectError(
        Page.IntegrityError.ZeroColCount,
        page.verifyIntegrity(testing.allocator),
    );
}
test "Page exactRowCapacity empty rows" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
        .hyperlink_bytes = 32 * @sizeOf(hyperlink.Set.Item),
        .string_bytes = 512,
    });
    defer page.deinit();
    const cap = page.exactRowCapacity(0, 5);
    try testing.expectEqual(10, cap.cols);
    try testing.expectEqual(5, cap.rows);
    try testing.expectEqual(0, cap.styles);
    try testing.expectEqual(0, cap.grapheme_bytes);
    try testing.expectEqual(0, cap.hyperlink_bytes);
    try testing.expectEqual(0, cap.string_bytes);
}
test "Page exactRowCapacity styles" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    {
        const cap = page.exactRowCapacity(0, 5);
        try testing.expectEqual(0, cap.styles);
    }
    const style1_id = try page.styles.add(page.memory, .{ .flags = .{ .bold = true } });
    {
        const rac = page.getRowAndCell(0, 0);
        rac.row.styled = true;
        rac.cell.style_id = style1_id;
    }
    const cap_one_style = page.exactRowCapacity(0, 5);
    {
        try testing.expectEqual(StyleSet.capacityForCount(1), cap_one_style.styles);
    }
    {
        const rac = page.getRowAndCell(1, 0);
        rac.cell.style_id = style1_id;
    }
    {
        const cap = page.exactRowCapacity(0, 5);
        try testing.expectEqual(cap_one_style.styles, cap.styles);
    }
    const style2_id = try page.styles.add(page.memory, .{ .flags = .{ .italic = true } });
    {
        const rac = page.getRowAndCell(2, 0);
        rac.cell.style_id = style2_id;
    }
    const cap_two_styles = page.exactRowCapacity(0, 5);
    {
        try testing.expectEqual(StyleSet.capacityForCount(2), cap_two_styles.styles);
        try testing.expect(cap_two_styles.styles > cap_one_style.styles);
    }
    {
        const rac = page.getRowAndCell(0, 7);
        rac.row.styled = true;
        rac.cell.style_id = try page.styles.add(page.memory, .{ .flags = .{ .underline = .single } });
    }
    {
        const cap = page.exactRowCapacity(0, 5);
        try testing.expectEqual(cap_two_styles.styles, cap.styles);
    }
    {
        const cap = page.exactRowCapacity(0, 10);
        try testing.expectEqual(StyleSet.capacityForCount(3), cap.styles);
    }
    {
        const cap = page.exactRowCapacity(0, 5);
        var cloned = try Page.init(cap);
        defer cloned.deinit();
        for (0..5) |y| {
            const src_row = &page.rows.ptr(page.memory)[y];
            const dst_row = &cloned.rows.ptr(cloned.memory)[y];
            try cloned.cloneRowFrom(&page, dst_row, src_row);
        }
        const cloned_cap = cloned.exactRowCapacity(0, 5);
        try testing.expectEqual(cap, cloned_cap);
    }
}
test "Page exactRowCapacity single style clone" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 2,
        .styles = 8,
    });
    defer page.deinit();
    const style_id = try page.styles.add(page.memory, .{ .flags = .{ .bold = true } });
    {
        const rac = page.getRowAndCell(0, 0);
        rac.row.styled = true;
        rac.cell.style_id = style_id;
    }
    const cap = page.exactRowCapacity(0, 1);
    try testing.expectEqual(StyleSet.capacityForCount(1), cap.styles);
    var cloned = try Page.init(cap);
    defer cloned.deinit();
    const src_row = &page.rows.ptr(page.memory)[0];
    const dst_row = &cloned.rows.ptr(cloned.memory)[0];
    try cloned.cloneRowFrom(&page, dst_row, src_row);
    const cloned_cell = &cloned.rows.ptr(cloned.memory)[0].cells.ptr(cloned.memory)[0];
    try testing.expect(cloned_cell.style_id != stylepkg.default_id);
}
test "Page exactRowCapacity styles max single row" {
    var page = try Page.init(.{
        .cols = std.math.maxInt(size.CellCountInt),
        .rows = 1,
        .styles = std.math.maxInt(size.StyleCountInt),
    });
    defer page.deinit();
    const row = &page.rows.ptr(page.memory)[0];
    row.styled = true;
    const cells = row.cells.ptr(page.memory)[0..page.size.cols];
    var count: usize = 0;
    const max_count: usize = 1000;
    for (cells, 0..) |*cell, i| {
        if (count >= max_count) break;
        const style_id = page.styles.add(page.memory, .{
            .fg_color = .{ .rgb = .{
                .r = @intCast(i & 0xFF),
                .g = @intCast((i >> 8) & 0xFF),
                .b = 0,
            } },
        }) catch break;
        cell.style_id = style_id;
        count += 1;
    }
    try testing.expect(count > 0);
    const cap = page.exactRowCapacity(0, 1);
    try testing.expectEqual(StyleSet.capacityForCount(count), cap.styles);
}
test "Page exactRowCapacity grapheme_bytes" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    {
        const cap = page.exactRowCapacity(0, 5);
        try testing.expectEqual(0, cap.grapheme_bytes);
    }
    {
        const rac = page.getRowAndCell(0, 0);
        rac.cell.* = .init('a');
        try page.appendGrapheme(rac.row, rac.cell, 0x0301);
    }
    {
        const cap = page.exactRowCapacity(0, 5);
        try testing.expectEqual(grapheme_chunk, cap.grapheme_bytes);
    }
    {
        const rac = page.getRowAndCell(1, 0);
        rac.cell.* = .init('e');
        try page.appendGrapheme(rac.row, rac.cell, 0x0300);
    }
    {
        const cap = page.exactRowCapacity(0, 5);
        try testing.expectEqual(grapheme_chunk * 2, cap.grapheme_bytes);
    }
    {
        const rac = page.getRowAndCell(2, 0);
        rac.cell.* = .init('o');
        try page.appendGrapheme(rac.row, rac.cell, 0x0301);
        try page.appendGrapheme(rac.row, rac.cell, 0x0302);
        try page.appendGrapheme(rac.row, rac.cell, 0x0303);
    }
    {
        const cap = page.exactRowCapacity(0, 5);
        try testing.expectEqual(grapheme_chunk * 3, cap.grapheme_bytes);
    }
    {
        const rac = page.getRowAndCell(0, 7);
        rac.cell.* = .init('x');
        try page.appendGrapheme(rac.row, rac.cell, 0x0304);
    }
    {
        const cap = page.exactRowCapacity(0, 5);
        try testing.expectEqual(grapheme_chunk * 3, cap.grapheme_bytes);
    }
    {
        const cap = page.exactRowCapacity(0, 10);
        try testing.expectEqual(grapheme_chunk * 4, cap.grapheme_bytes);
    }
    {
        const cap = page.exactRowCapacity(0, 5);
        var cloned = try Page.init(cap);
        defer cloned.deinit();
        for (0..5) |y| {
            const src_row = &page.rows.ptr(page.memory)[y];
            const dst_row = &cloned.rows.ptr(cloned.memory)[y];
            try cloned.cloneRowFrom(&page, dst_row, src_row);
        }
        const cloned_cap = cloned.exactRowCapacity(0, 5);
        try testing.expectEqual(cap, cloned_cap);
    }
}
test "Page exactRowCapacity grapheme_bytes larger than chunk" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    const rac = page.getRowAndCell(0, 0);
    rac.cell.* = .init('a');
    for (0..6) |i| {
        try page.appendGrapheme(rac.row, rac.cell, @intCast(0x0300 + i));
    }
    const cap = page.exactRowCapacity(0, 1);
    try testing.expectEqual(32, cap.grapheme_bytes);
    var cloned = try Page.init(cap);
    defer cloned.deinit();
    const src_row = &page.rows.ptr(page.memory)[0];
    const dst_row = &cloned.rows.ptr(cloned.memory)[0];
    try cloned.cloneRowFrom(&page, dst_row, src_row);
    const cloned_cap = cloned.exactRowCapacity(0, 1);
    try testing.expectEqual(cap, cloned_cap);
}
test "Page exactRowCapacity hyperlinks" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
        .hyperlink_bytes = 32 * @sizeOf(hyperlink.Set.Item),
        .string_bytes = 512,
    });
    defer page.deinit();
    {
        const cap = page.exactRowCapacity(0, 5);
        try testing.expectEqual(0, cap.hyperlink_bytes);
        try testing.expectEqual(0, cap.string_bytes);
    }
    const uri1 = "https://example.com";
    const id1 = blk: {
        const rac = page.getRowAndCell(0, 0);
        const id = try page.insertHyperlink(.{
            .id = .{ .implicit = 1 },
            .uri = uri1,
        });
        try page.setHyperlink(rac.row, rac.cell, id);
        break :blk id;
    };
    const cap_one_link = page.exactRowCapacity(0, 5);
    {
        try testing.expectEqual(hyperlink.Set.capacityForCount(1) * @sizeOf(hyperlink.Set.Item), cap_one_link.hyperlink_bytes);
        try testing.expectEqual(string_chunk, cap_one_link.string_bytes);
    }
    {
        const rac = page.getRowAndCell(1, 0);
        page.hyperlink_set.use(page.memory, id1);
        try page.setHyperlink(rac.row, rac.cell, id1);
    }
    {
        const cap = page.exactRowCapacity(0, 5);
        try testing.expectEqual(cap_one_link.hyperlink_bytes, cap.hyperlink_bytes);
        try testing.expectEqual(cap_one_link.string_bytes, cap.string_bytes);
    }
    const uri2 = "https://other.example.org/path";
    const explicit_id = "my-link-id";
    {
        const rac = page.getRowAndCell(2, 0);
        const id = try page.insertHyperlink(.{
            .id = .{ .explicit = explicit_id },
            .uri = uri2,
        });
        try page.setHyperlink(rac.row, rac.cell, id);
    }
    const cap_two_links = page.exactRowCapacity(0, 5);
    {
        try testing.expectEqual(hyperlink.Set.capacityForCount(2) * @sizeOf(hyperlink.Set.Item), cap_two_links.hyperlink_bytes);
        try testing.expectEqual(string_chunk * 3, cap_two_links.string_bytes);
    }
    {
        const rac = page.getRowAndCell(0, 7);
        const id = try page.insertHyperlink(.{
            .id = .{ .implicit = 99 },
            .uri = "https://outside.example.com",
        });
        try page.setHyperlink(rac.row, rac.cell, id);
    }
    {
        const cap = page.exactRowCapacity(0, 5);
        try testing.expectEqual(cap_two_links.hyperlink_bytes, cap.hyperlink_bytes);
        try testing.expectEqual(cap_two_links.string_bytes, cap.string_bytes);
    }
    {
        const cap = page.exactRowCapacity(0, 10);
        try testing.expectEqual(hyperlink.Set.capacityForCount(3) * @sizeOf(hyperlink.Set.Item), cap.hyperlink_bytes);
        try testing.expectEqual(string_chunk * 4, cap.string_bytes);
    }
    {
        const cap = page.exactRowCapacity(0, 5);
        var cloned = try Page.init(cap);
        defer cloned.deinit();
        for (0..5) |y| {
            const src_row = &page.rows.ptr(page.memory)[y];
            const dst_row = &cloned.rows.ptr(cloned.memory)[y];
            try cloned.cloneRowFrom(&page, dst_row, src_row);
        }
        const cloned_cap = cloned.exactRowCapacity(0, 5);
        try testing.expectEqual(cap, cloned_cap);
    }
}
test "Page exactRowCapacity single hyperlink clone" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 2,
        .styles = 8,
        .hyperlink_bytes = 32 * @sizeOf(hyperlink.Set.Item),
        .string_bytes = 512,
    });
    defer page.deinit();
    const uri = "https://example.com";
    const id = blk: {
        const rac = page.getRowAndCell(0, 0);
        const link_id = try page.insertHyperlink(.{
            .id = .{ .implicit = 1 },
            .uri = uri,
        });
        try page.setHyperlink(rac.row, rac.cell, link_id);
        break :blk link_id;
    };
    _ = id;
    const cap = page.exactRowCapacity(0, 1);
    try testing.expectEqual(hyperlink.Set.capacityForCount(1) * @sizeOf(hyperlink.Set.Item), cap.hyperlink_bytes);
    var cloned = try Page.init(cap);
    defer cloned.deinit();
    const src_row = &page.rows.ptr(page.memory)[0];
    const dst_row = &cloned.rows.ptr(cloned.memory)[0];
    try cloned.cloneRowFrom(&page, dst_row, src_row);
    const cloned_cell = &cloned.rows.ptr(cloned.memory)[0].cells.ptr(cloned.memory)[0];
    try testing.expect(cloned_cell.hyperlink);
}
test "Page exactRowCapacity hyperlink map capacity for many cells" {
    const cols = 50;
    var page = try Page.init(.{
        .cols = cols,
        .rows = 2,
        .styles = 8,
        .hyperlink_bytes = 32 * @sizeOf(hyperlink.Set.Item),
        .string_bytes = 512,
    });
    defer page.deinit();
    const uri = "https://example.com";
    const id = blk: {
        const rac = page.getRowAndCell(0, 0);
        const link_id = try page.insertHyperlink(.{
            .id = .{ .implicit = 1 },
            .uri = uri,
        });
        try page.setHyperlink(rac.row, rac.cell, link_id);
        break :blk link_id;
    };
    for (1..cols) |x| {
        const rac = page.getRowAndCell(@intCast(x), 0);
        page.hyperlink_set.use(page.memory, id);
        try page.setHyperlink(rac.row, rac.cell, id);
    }
    const cap = page.exactRowCapacity(0, 1);
    const min_for_map = std.math.divCeil(usize, cols, hyperlink_cell_multiplier) catch 0;
    const min_hyperlink_bytes = min_for_map * @sizeOf(hyperlink.Set.Item);
    try testing.expect(cap.hyperlink_bytes >= min_hyperlink_bytes);
    var cloned = try Page.init(cap);
    defer cloned.deinit();
    const src_row = &page.rows.ptr(page.memory)[0];
    const dst_row = &cloned.rows.ptr(cloned.memory)[0];
    try cloned.cloneRowFrom(&page, dst_row, src_row);
    for (0..cols) |x| {
        const cloned_cell = &cloned.rows.ptr(cloned.memory)[0].cells.ptr(cloned.memory)[x];
        try testing.expect(cloned_cell.hyperlink);
    }
}
test "Page layout avoids double rounding hyperlink map capacity" {
    const hyperlink_count = 3;
    const layout = Page.layout(.{
        .cols = 1,
        .rows = 1,
        .hyperlink_bytes = hyperlink_count * @sizeOf(hyperlink.Set.Item),
    });
    try std.testing.expectEqual(
        @as(u32, 64),
        layout.hyperlink_map_layout.capacity,
    );
}
