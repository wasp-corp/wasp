const Screen = @This();
const std = @import("std");
const build_options = @import("terminal_options");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const ansi = @import("ansi.zig");
const charsets = @import("charsets.zig");
const fastmem = @import("../fastmem.zig");
const kitty = @import("kitty.zig");
const lib = @import("lib.zig");
const sgr = @import("sgr.zig");
const tripwire = @import("../tripwire.zig");
const unicode = @import("../unicode/root.zig");
const Selection = @import("Selection.zig");
const PageList = @import("PageList.zig");
const selection_codepoints = @import("selection_codepoints.zig");
const StringMap = @import("StringMap.zig");
const ScreenFormatter = @import("formatter.zig").ScreenFormatter;
const PinMap = @import("formatter.zig").PinMap;
const osc = @import("osc.zig");
const pagepkg = @import("page.zig");
const point = @import("point.zig");
const size = @import("size.zig");
const style = @import("style.zig");
const hyperlink = @import("hyperlink.zig");
const Offset = size.Offset;
const Page = pagepkg.Page;
const Row = pagepkg.Row;
const Cell = pagepkg.Cell;
const Pin = PageList.Pin;
pub const CursorStyle = @import("cursor.zig").Style;
const log = std.log.scoped(.screen);
io: std.Io,
alloc: Allocator,
pages: PageList,
no_scrollback: bool = false,
cursor: Cursor,
saved_cursor: ?SavedCursor = null,
selection: ?Selection = null,
charset: CharsetState = .{},
protected_mode: ansi.ProtectedMode = .off,
kitty_keyboard: kitty.KeyFlagStack = .{},
kitty_images: if (build_options.kitty_graphics)
    kitty.graphics.ImageStorage
else
    struct {} = .{},
semantic_prompt: SemanticPrompt = .disabled,
dirty: Dirty = .{},
pub const Dirty = packed struct {
    selection: bool = false,
    hyperlink_hover: bool = false,
};
pub const SemanticPrompt = struct {
    seen: bool,
    click: SemanticClick,
    pub const disabled: SemanticPrompt = .{
        .seen = false,
        .click = .none,
    };
    pub const SemanticClickKind = lib.Enum(
        lib.target,
        &.{ "none", "click_events", "cl" },
    );
    pub const SemanticClick = union(SemanticClickKind) {
        none,
        click_events: osc.semantic_prompt.ClickEvents,
        cl: osc.semantic_prompt.Click,
    };
};
pub const Cursor = struct {
    x: size.CellCountInt = 0,
    y: size.CellCountInt = 0,
    cursor_style: CursorStyle = .block,
    pending_wrap: bool = false,
    protected: bool = false,
    style: style.Style = .{},
    style_id: style.Id = style.default_id,
    hyperlink_id: hyperlink.Id = 0,
    hyperlink_implicit_id: size.OffsetInt = 0,
    hyperlink: ?*hyperlink.Hyperlink = null,
    semantic_content: pagepkg.Cell.SemanticContent = .output,
    semantic_content_clear_eol: bool = false,
    page_pin: *PageList.Pin,
    page_row: *pagepkg.Row,
    page_cell: *pagepkg.Cell,
    pub fn deinit(self: *Cursor, alloc: Allocator) void {
        if (self.hyperlink) |link| {
            link.deinit(alloc);
            alloc.destroy(link);
        }
    }
};
pub const SavedCursor = struct {
    x: size.CellCountInt,
    y: size.CellCountInt,
    style: style.Style,
    protected: bool,
    pending_wrap: bool,
    origin: bool,
    charset: CharsetState,
};
pub const CharsetState = struct {
    charsets: CharsetArray = .{},
    gl: charsets.Slots = .G0,
    gr: charsets.Slots = .G2,
    single_shift: ?charsets.Slots = null,
    const CharsetArray = struct {
        g0: charsets.Charset = .utf8,
        g1: charsets.Charset = .utf8,
        g2: charsets.Charset = .utf8,
        g3: charsets.Charset = .utf8,
        pub inline fn get(
            self: *const CharsetArray,
            slot: charsets.Slots,
        ) charsets.Charset {
            return switch (slot) {
                .G0 => self.g0,
                .G1 => self.g1,
                .G2 => self.g2,
                .G3 => self.g3,
            };
        }
        pub inline fn set(
            self: *CharsetArray,
            slot: charsets.Slots,
            charset: charsets.Charset,
        ) void {
            switch (slot) {
                .G0 => self.g0 = charset,
                .G1 => self.g1 = charset,
                .G2 => self.g2 = charset,
                .G3 => self.g3 = charset,
            }
        }
    };
};
pub const Options = struct {
    cols: size.CellCountInt,
    rows: size.CellCountInt,
    max_scrollback_bytes: ?usize = 0,
    max_scrollback_lines: ?usize = null,
    kitty_image_storage_limit: usize = switch (build_options.artifact) {
        .wasp => 320 * 1000 * 1000,
        .lib => 10 * 1000 * 1000,
    },
    kitty_image_loading_limits: if (build_options.kitty_graphics)
        kitty.graphics.LoadingImage.Limits
    else
        void = if (build_options.kitty_graphics) .direct else {},
    pub const default: Options = .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_bytes = 0,
    };
};
pub fn init(
    io: std.Io,
    alloc: Allocator,
    opts: Options,
) Allocator.Error!Screen {
    var pages = try PageList.init(alloc, .{
        .cols = opts.cols,
        .rows = opts.rows,
        .max_size = opts.max_scrollback_bytes,
        .max_lines = opts.max_scrollback_lines,
    });
    errdefer pages.deinit();
    const page_pin = try pages.trackPin(.{ .node = pages.pages.first.? });
    errdefer pages.untrackPin(page_pin);
    const page_rac = page_pin.rowAndCell();
    var result: Screen = .{
        .io = io,
        .alloc = alloc,
        .pages = pages,
        .no_scrollback = opts.max_scrollback_bytes == 0,
        .cursor = .{
            .x = 0,
            .y = 0,
            .page_pin = page_pin,
            .page_row = page_rac.row,
            .page_cell = page_rac.cell,
        },
    };
    if (comptime build_options.kitty_graphics) {
        result.kitty_images.setLimit(
            io,
            alloc,
            &result,
            opts.kitty_image_storage_limit,
        );
        result.kitty_images.image_limits = opts.kitty_image_loading_limits;
    }
    return result;
}
pub fn deinit(self: *Screen) void {
    if (comptime build_options.kitty_graphics) {
        self.kitty_images.deinit(self.alloc, self);
    }
    self.cursor.deinit(self.alloc);
    self.pages.deinit();
}
pub fn assertIntegrity(self: *const Screen) void {
    if (build_options.slow_runtime_safety) {
        if (std.valgrind.runningOnValgrind() > 0) return;
        assert(self.cursor.x < self.pages.cols);
        assert(self.cursor.y < self.pages.rows);
        const pt: point.Point = self.pages.pointFromPin(
            .active,
            self.cursor.page_pin.*,
        ) orelse unreachable;
        assert(self.cursor.x == pt.active.x);
        assert(self.cursor.y == pt.active.y);
        const page: *const Page = self.cursor.page_pin.node.page();
        if (self.cursor.style_id != style.default_id) {
            assert(page.styles.refCount(page.memory, self.cursor.style_id) > 0);
        }
        if (self.cursor.hyperlink_id != 0) {
            assert(page.hyperlink_set.refCount(page.memory, self.cursor.hyperlink_id) > 0);
        }
    }
}
pub const MemoryUsage = struct {
    pages: PageList.MemoryUsage = .{},
    image_bytes: usize = 0,
};
pub fn memoryUsage(self: *const Screen) MemoryUsage {
    return .{
        .pages = self.pages.memoryUsage(),
        .image_bytes = if (comptime build_options.kitty_graphics)
            self.kitty_images.total_bytes
        else
            0,
    };
}
pub fn reset(self: *Screen) void {
    self.pages.reset();
    const cursor_pin: *PageList.Pin = self.cursor.page_pin;
    assert(cursor_pin.node == self.pages.pages.first.?);
    assert(cursor_pin.x == 0);
    assert(cursor_pin.y == 0);
    cursor_pin.garbage = false;
    const cursor_rac = cursor_pin.rowAndCell();
    self.cursor.deinit(self.alloc);
    self.cursor = .{
        .page_pin = cursor_pin,
        .page_row = cursor_rac.row,
        .page_cell = cursor_rac.cell,
    };
    if (comptime build_options.kitty_graphics) {
        const image_limits = self.kitty_images.image_limits;
        const total_limit = self.kitty_images.total_limit;
        self.kitty_images.deinit(self.alloc, self);
        self.kitty_images = .{
            .dirty = true,
            .image_limits = image_limits,
            .total_limit = total_limit,
        };
    }
    self.saved_cursor = null;
    self.charset = .{};
    self.kitty_keyboard = .{};
    self.protected_mode = .off;
    self.semantic_prompt = .disabled;
    self.clearSelection();
}
pub fn clone(
    self: *const Screen,
    io: std.Io,
    alloc: Allocator,
    top: point.Point,
    bot: ?point.Point,
) !Screen {
    var pin_remap = PageList.Clone.TrackedPinsRemap.init(alloc);
    defer pin_remap.deinit();
    var pages = try self.pages.clone(alloc, .{
        .top = top,
        .bot = bot,
        .tracked_pins = &pin_remap,
    });
    errdefer pages.deinit();
    const cursor: Cursor = cursor: {
        if (pin_remap.get(self.cursor.page_pin)) |p| remap: {
            const page_rac = p.rowAndCell();
            const pt = pages.pointFromPin(.active, p.*) orelse break :remap;
            break :cursor .{
                .x = @intCast(pt.active.x),
                .y = @intCast(pt.active.y),
                .page_pin = p,
                .page_row = page_rac.row,
                .page_cell = page_rac.cell,
            };
        }
        const page_pin = try pages.trackPin(.{ .node = pages.pages.first.? });
        const page_rac = page_pin.rowAndCell();
        break :cursor .{
            .x = 0,
            .y = 0,
            .page_pin = page_pin,
            .page_row = page_rac.row,
            .page_cell = page_rac.cell,
        };
    };
    const sel: ?Selection = if (self.selection) |sel| sel: {
        assert(sel.tracked());
        const ordered: struct {
            tl: *Pin,
            br: *Pin,
        } = switch (sel.order(self)) {
            .forward, .mirrored_forward => .{
                .tl = sel.bounds.tracked.start,
                .br = sel.bounds.tracked.end,
            },
            .reverse, .mirrored_reverse => .{
                .tl = sel.bounds.tracked.end,
                .br = sel.bounds.tracked.start,
            },
        };
        const start_pin = pin_remap.get(ordered.tl) orelse start: {
            if (pin_remap.get(ordered.br) == null) {
                const clone_top = self.pages.pin(top) orelse break :sel null;
                const clone_top_y = self.pages.pointFromPin(
                    .screen,
                    clone_top,
                ).?.screen.y;
                if (self.pages.pointFromPin(
                    .screen,
                    ordered.br.*,
                ).?.screen.y < clone_top_y) break :sel null;
                if (self.pages.pointFromPin(
                    .screen,
                    ordered.tl.*,
                ).?.screen.y > clone_top_y) break :sel null;
            }
            const node = pages.pages.first.?;
            break :start try pages.trackPin(.{
                .node = node,
                .x = if (sel.rectangle)
                    @min(ordered.tl.x, node.cols() - 1)
                else
                    0,
            });
        };
        const end_pin = pin_remap.get(ordered.br) orelse end: {
            const node = pages.pages.last.?;
            break :end try pages.trackPin(.{
                .node = node,
                .x = if (sel.rectangle)
                    @min(ordered.br.x, node.cols() - 1)
                else
                    node.cols() - 1,
                .y = node.rows() - 1,
            });
        };
        break :sel .{
            .bounds = .{ .tracked = .{
                .start = start_pin,
                .end = end_pin,
            } },
            .rectangle = sel.rectangle,
        };
    } else null;
    const result: Screen = .{
        .io = io,
        .alloc = alloc,
        .pages = pages,
        .no_scrollback = self.no_scrollback,
        .cursor = cursor,
        .selection = sel,
        .dirty = self.dirty,
    };
    result.assertIntegrity();
    return result;
}
pub fn increaseCapacity(
    self: *Screen,
    node: *PageList.List.Node,
    adjustment: ?PageList.IncreaseCapacity,
) PageList.IncreaseCapacityError!*PageList.List.Node {
    if (node != self.cursor.page_pin.node) return try self.pages.increaseCapacity(
        node,
        adjustment,
    );
    const new_node = try self.pages.increaseCapacity(node, adjustment);
    assert(self.cursor.page_pin.node == new_node);
    self.cursorPageReplaced();
    return new_node;
}
fn cursorPageReplaced(self: *Screen) void {
    const new_page: *Page = self.cursor.page_pin.node.page();
    if (self.cursor.style_id != style.default_id) {
        self.cursor.style_id = new_page.styles.add(
            new_page.memory,
            self.cursor.style,
        ) catch |err| id: {
            log.warn(
                "(Screen.cursorPageReplaced) Failed to add cursor style back to page, err={}",
                .{err},
            );
            self.cursor.style = .{};
            break :id style.default_id;
        };
    }
    if (self.cursor.hyperlink) |link| {
        self.cursor.hyperlink_id = 0;
        self.cursor.hyperlink = null;
        self.startHyperlinkOnce(link.*) catch |err| {
            log.warn(
                "(Screen.cursorPageReplaced) Failed to add cursor hyperlink back to page, err={}",
                .{err},
            );
        };
        link.deinit(self.alloc);
        self.alloc.destroy(link);
    }
    self.cursorReload();
}
pub fn clonePartialRowGrowCapacity(
    self: *Screen,
    node: *PageList.List.Node,
    dst_y: usize,
    src_page: *Page,
    src_row: *const Row,
    x_start: usize,
    x_end: usize,
) *PageList.List.Node {
    assert(src_page != node.page());
    var current = node;
    while (true) {
        const cur_page: *Page = current.page();
        const cur_rows = cur_page.rows.ptr(cur_page.memory.ptr);
        cur_page.clonePartialRowFrom(
            src_page,
            &cur_rows[dst_y],
            src_row,
            x_start,
            x_end,
        ) catch |err| {
            current = self.increaseCapacity(
                current,
                PageList.IncreaseCapacity.forCloneError(err),
            ) catch |e| switch (e) {
                error.OutOfMemory,
                => @panic("increaseCapacity system allocator OOM"),
                error.OutOfSpace,
                => @panic("increaseCapacity OutOfSpace"),
            };
            continue;
        };
        return current;
    }
}
pub inline fn cursorCellRight(self: *Screen, n: size.CellCountInt) *pagepkg.Cell {
    assert(self.cursor.x + n < self.pages.cols);
    const cell: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
    return @ptrCast(cell + n);
}
pub inline fn cursorCellLeft(self: *Screen, n: size.CellCountInt) *pagepkg.Cell {
    assert(self.cursor.x >= n);
    const cell: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
    return @ptrCast(cell - n);
}
pub fn cursorCellEndOfPrev(self: *Screen) *pagepkg.Cell {
    assert(self.cursor.y > 0);
    var page_pin = self.cursor.page_pin.up(1).?;
    page_pin.x = page_pin.node.cols() - 1;
    const page_rac = page_pin.rowAndCell();
    return page_rac.cell;
}
pub fn cursorRight(self: *Screen, n: size.CellCountInt) void {
    assert(self.cursor.x + n < self.pages.cols);
    defer self.assertIntegrity();
    const cell: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
    self.cursor.page_cell = @ptrCast(cell + n);
    self.cursor.page_pin.x += n;
    self.cursor.x += n;
}
pub fn cursorLeft(self: *Screen, n: size.CellCountInt) void {
    assert(self.cursor.x >= n);
    defer self.assertIntegrity();
    const cell: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
    self.cursor.page_cell = @ptrCast(cell - n);
    self.cursor.page_pin.x -= n;
    self.cursor.x -= n;
}
pub fn cursorUp(self: *Screen, n: size.CellCountInt) void {
    assert(self.cursor.y >= n);
    defer self.assertIntegrity();
    self.cursor.y -= n;
    self.cursorChangePin(self.cursor.page_pin.up(n).?);
    const page_rac = self.cursor.page_pin.rowAndCell();
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;
}
pub fn cursorRowUp(self: *Screen, n: size.CellCountInt) *pagepkg.Row {
    assert(self.cursor.y >= n);
    defer self.assertIntegrity();
    const page_pin = self.cursor.page_pin.up(n).?;
    const page_rac = page_pin.rowAndCell();
    return page_rac.row;
}
pub fn cursorDown(self: *Screen, n: size.CellCountInt) void {
    assert(self.cursor.y + n < self.pages.rows);
    defer self.assertIntegrity();
    self.cursor.y += n;
    self.cursorChangePin(self.cursor.page_pin.down(n).?);
    const page_rac = self.cursor.page_pin.rowAndCell();
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;
}
pub fn cursorHorizontalAbsolute(self: *Screen, x: size.CellCountInt) void {
    assert(x < self.pages.cols);
    defer self.assertIntegrity();
    self.cursor.page_pin.x = x;
    const page_rac = self.cursor.page_pin.rowAndCell();
    self.cursor.page_cell = page_rac.cell;
    self.cursor.x = x;
}
pub fn cursorAbsolute(self: *Screen, x: size.CellCountInt, y: size.CellCountInt) void {
    assert(x < self.pages.cols);
    assert(y < self.pages.rows);
    defer self.assertIntegrity();
    var page_pin = if (y < self.cursor.y)
        self.cursor.page_pin.up(self.cursor.y - y).?
    else if (y > self.cursor.y)
        self.cursor.page_pin.down(y - self.cursor.y).?
    else
        self.cursor.page_pin.*;
    page_pin.x = x;
    self.cursor.x = x;
    self.cursor.y = y;
    self.cursorChangePin(page_pin);
    const page_rac = self.cursor.page_pin.rowAndCell();
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;
}
pub fn cursorReload(self: *Screen) void {
    defer self.assertIntegrity();
    const pt: point.Point = self.pages.pointFromPin(
        .active,
        self.cursor.page_pin.*,
    ) orelse reset: {
        const old_rac = self.cursor.page_pin.rowAndCell();
        self.cursor.page_row = old_rac.row;
        self.cursor.page_cell = old_rac.cell;
        const pin = self.pages.pin(.{ .active = .{} }).?;
        self.cursor.x = 0;
        self.cursor.y = 0;
        self.cursorChangePin(pin);
        break :reset self.pages.pointFromPin(
            .active,
            self.cursor.page_pin.*,
        ).?;
    };
    self.cursor.x = @intCast(pt.active.x);
    self.cursor.y = @intCast(pt.active.y);
    const page_rac = self.cursor.page_pin.rowAndCell();
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;
}
pub fn cursorDownScroll(self: *Screen) !void {
    assert(self.cursor.y == self.pages.rows - 1);
    defer self.assertIntegrity();
    if (comptime build_options.kitty_graphics) {
        self.kitty_images.dirty = true;
    }
    if (self.no_scrollback) {
        if (self.pages.rows == 1) {
            const page: *Page = self.cursor.page_pin.node.page();
            self.clearCells(
                page,
                self.cursor.page_row,
                page.getCells(self.cursor.page_row),
            );
            self.cursor.page_row.reset();
            self.cursorMarkDirty();
        } else {
            const old_pin = self.cursor.page_pin.*;
            try self.pages.eraseRow(.{ .active = .{} });
            self.cursor.page_pin.* = old_pin;
            const page_rac = self.cursor.page_pin.rowAndCell();
            self.cursor.page_row = page_rac.row;
            self.cursor.page_cell = page_rac.cell;
        }
    } else {
        const old_pin = self.cursor.page_pin.*;
        _ = try self.pages.grow();
        const pruned = old_pin.node != self.cursor.page_pin.node;
        const new_pin = new_pin: {
            const page_pin = if (!pruned)
                self.cursor.page_pin.down(1).?
            else reuse: {
                var pin = self.cursor.page_pin.*;
                pin.x = self.cursor.x;
                pin.garbage = false;
                break :reuse pin;
            };
            if (build_options.slow_runtime_safety) {
                const active = self.pages.pointFromPin(
                    .active,
                    page_pin,
                ).?.active;
                assert(active.x == self.cursor.x);
                assert(active.y == self.cursor.y);
            }
            break :new_pin page_pin;
        };
        if (pruned) {
            self.cursor.page_pin.* = new_pin;
            self.cursorPageReplaced();
        } else if (self.cursor.page_pin.node == new_pin.node) {
            self.cursorMarkDirty();
            const page = new_pin.node.pageAssumeResident();
            const page_rac = page.getRowAndCell(new_pin.x, new_pin.y);
            self.cursor.page_pin.* = new_pin;
            self.cursor.page_row = page_rac.row;
            self.cursor.page_cell = page_rac.cell;
        } else {
            self.cursorChangePin(new_pin);
            const page_rac = self.cursor.page_pin.rowAndCell();
            self.cursor.page_row = page_rac.row;
            self.cursor.page_cell = page_rac.cell;
        }
        self.cursorMarkDirty();
        if (self.cursor.style.bg_color != .none) {
            const page: *Page = self.cursor.page_pin.node.page();
            self.clearCells(
                page,
                self.cursor.page_row,
                page.getCells(self.cursor.page_row),
            );
        }
    }
    if (self.cursor.style_id != style.default_id) {
        if (self.cursor.style.bgCell()) |blank_cell| {
            const cell_current: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
            const cells = cell_current - self.cursor.x;
            @memset(cells[0..self.pages.cols], blank_cell);
        }
    }
}
pub fn cursorScrollAbove(self: *Screen) !void {
    self.cursorMarkDirty();
    if (self.cursor.y == self.pages.rows - 1) {
        return try self.cursorDownScroll();
    }
    defer self.assertIntegrity();
    assert(self.cursor.y < self.pages.rows - 1);
    const old_pin = self.cursor.page_pin.*;
    if (try self.pages.grow()) |new_node| {
        try self.cursorScrollAboveRotate(new_node);
    } else {
        if (self.cursor.page_pin.node == self.pages.pages.last) {
            assert(old_pin.node == self.cursor.page_pin.node);
            self.cursor.page_pin.* = self.cursor.page_pin.down(1).?;
            const pin = self.cursor.page_pin;
            const page: *Page = self.cursor.page_pin.node.page();
            var rows = page.rows.ptr(page.memory.ptr);
            self.pages.invalidateNodeLayout(pin.node);
            fastmem.rotateOnceR(Row, rows[pin.y..page.size.rows]);
            page.dirty = true;
            const page_rac = self.cursor.page_pin.rowAndCell();
            self.cursor.page_row = page_rac.row;
            self.cursor.page_cell = page_rac.cell;
        } else {
            try self.cursorScrollAboveRotate(null);
        }
    }
    if (self.cursor.style_id != style.default_id) {
        if (self.cursor.style.bgCell()) |blank_cell| {
            const cell_current: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
            const cells = cell_current - self.cursor.x;
            @memset(cells[0..self.pages.cols], blank_cell);
        }
    }
}
fn cursorScrollAboveRotate(
    self: *Screen,
    fresh_node: ?*PageList.List.Node,
) !void {
    assert(fresh_node == null or fresh_node == self.pages.pages.last);
    self.cursorChangePin(self.cursor.page_pin.down(1).?);
    var current = self.pages.pages.last.?;
    var current_is_fresh = fresh_node != null;
    while (current != self.cursor.page_pin.node) : ({
        current = current.prev.?;
        current_is_fresh = false;
    }) {
        const prev = current.prev.?;
        if (!current_is_fresh) {
            self.pages.invalidateNodeLayout(current);
        }
        {
            const cur_page = current.page();
            const cur_rows = cur_page.rows.ptr(cur_page.memory.ptr);
            fastmem.rotateOnceR(Row, cur_rows[0..cur_page.size.rows]);
        }
        {
            const prev_page = prev.page();
            const prev_rows = prev_page.rows.ptr(prev_page.memory.ptr);
            current = self.clonePartialRowGrowCapacity(
                current,
                0,
                prev_page,
                &prev_rows[prev_page.size.rows - 1],
                0,
                self.pages.cols,
            );
        }
        current.page().dirty = true;
    }
    assert(current == self.cursor.page_pin.node);
    const cur_page = current.page();
    const cur_rows = cur_page.rows.ptr(cur_page.memory.ptr);
    self.pages.invalidateNodeLayout(current);
    fastmem.rotateOnceR(Row, cur_rows[self.cursor.page_pin.y..cur_page.size.rows]);
    self.clearCells(
        cur_page,
        &cur_rows[self.cursor.page_pin.y],
        cur_page.getCells(&cur_rows[self.cursor.page_pin.y]),
    );
    cur_rows[self.cursor.page_pin.y].reset();
    cur_page.dirty = true;
    const page_rac = self.cursor.page_pin.rowAndCell();
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;
}
pub fn cursorScrollRegionUp(self: *Screen, limit: usize) !void {
    assert(limit >= 1);
    assert(self.cursor.y >= limit);
    defer self.assertIntegrity();
    const pin: *Pin = self.cursor.page_pin;
    if (pin.y < limit) return try self.cursorScrollRegionUpSlow(limit);
    const page: *Page = pin.node.pageAssumeResident();
    const rows = page.rows.ptr(page.memory.ptr)[pin.y - limit ..][0 .. limit + 1];
    {
        const row: *Row = &rows[0];
        const blank_is_zero = self.cursor.style_id == style.default_id or
            self.cursor.style.bg_color == .none;
        if (!row.managedMemory() and blank_is_zero) {
            const cells = page.getCells(row);
            @memset(@as([]u64, @ptrCast(cells)), 0);
        } else {
            self.clearCells(page, row, page.getCells(row));
        }
        row.reset();
    }
    self.pages.invalidateNodeLayout(pin.node);
    fastmem.rotateOnce(Row, rows);
    page.dirty = true;
    if (self.pages.viewport == .pin) viewport: {
        if (self.pages.viewport_pin_row_offset) |*v| {
            const p = self.pages.viewport_pin;
            if (p.node != pin.node or
                p.y < pin.y - limit or
                p.y > pin.y or
                p.y == 0) break :viewport;
            v.* -= 1;
        }
    }
    const pin_keys = self.pages.tracked_pins.keys();
    for (pin_keys) |p| {
        if (p.node != pin.node or
            p == pin or
            p.y < pin.y - limit or
            p.y > pin.y) continue;
        if (p.y == 0) p.x = 0 else p.y -= 1;
    }
    const cursor_row: *Row = &rows[limit];
    self.cursor.page_row = cursor_row;
    self.cursor.page_cell = &page.getCells(cursor_row)[self.cursor.x];
}
fn cursorScrollRegionUpSlow(self: *Screen, limit: usize) !void {
    const old_pin = self.cursor.page_pin.*;
    try self.pages.eraseRowBounded(
        .{ .active = .{ .y = @intCast(self.cursor.y - limit) } },
        limit,
    );
    self.cursor.page_pin.* = old_pin;
    const page_rac = self.cursor.page_pin.rowAndCell();
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;
    const blank = self.blankCell();
    if (!blank.isZero()) {
        const cells: [*]Cell = @ptrCast(self.cursor.page_cell);
        @memset((cells - self.cursor.x)[0..self.pages.cols], blank);
    }
}
inline fn cursorDownOrScroll(self: *Screen) !void {
    if (self.cursor.y + 1 < self.pages.rows) {
        self.cursorDown(1);
    } else {
        try self.cursorDownScroll();
    }
}
pub fn cursorCopy(self: *Screen, other: Cursor, opts: struct {
    hyperlink: bool = true,
}) !void {
    assert(other.x < self.pages.cols);
    assert(other.y < self.pages.rows);
    self.endHyperlink();
    const old = self.cursor;
    self.cursor = other;
    errdefer self.cursor = old;
    self.cursor.style_id = old.style_id;
    self.cursor.hyperlink_id = 0;
    self.cursor.hyperlink = null;
    self.cursor.page_pin = old.page_pin;
    self.cursor.x = old.x;
    self.cursor.y = old.y;
    try self.manualStyleUpdate();
    self.cursorAbsolute(other.x, other.y);
    if (opts.hyperlink and other.hyperlink_id != 0) {
        const other_page = other.page_pin.node.page();
        const other_link = other_page.hyperlink_set.get(other_page.memory, other.hyperlink_id);
        const uri = other_link.uri.slice(other_page.memory);
        const id_ = switch (other_link.id) {
            .explicit => |id| id.slice(other_page.memory),
            .implicit => null,
        };
        self.startHyperlink(uri, id_) catch |err| {
            log.err("failed to update hyperlink on cursor change err={}", .{err});
        };
    }
}
inline fn cursorChangePin(self: *Screen, new: Pin) void {
    if (!self.cursor.page_pin.eql(new)) {
        self.cursorMarkDirty();
        new.markDirty();
    }
    if (self.cursor.page_pin.node == new.node) {
        self.cursor.page_pin.* = new;
        return;
    }
    const old_style_: ?style.Style = if (self.cursor.style_id == style.default_id)
        null
    else
        self.cursor.style;
    if (old_style_ != null) {
        const old_page: *Page = self.cursor.page_pin.node.page();
        old_page.styles.release(old_page.memory, self.cursor.style_id);
        self.cursor.style = .{};
        self.cursor.style_id = style.default_id;
    }
    if (self.cursor.hyperlink != null) {
        const old_page: *Page = self.cursor.page_pin.node.page();
        old_page.hyperlink_set.release(old_page.memory, self.cursor.hyperlink_id);
        self.cursor.hyperlink_id = 0;
    }
    self.cursor.page_pin.* = new;
    if (old_style_) |old_style| {
        self.cursor.style = old_style;
        self.manualStyleUpdate() catch |err| {
            log.err("failed to update style on cursor change err={}", .{err});
            self.cursor.style = .{};
            self.cursor.style_id = 0;
        };
    }
    if (self.cursor.hyperlink) |link| {
        self.cursor.hyperlink = null;
        self.startHyperlink(link.uri, switch (link.id) {
            .explicit => |v| v,
            .implicit => null,
        }) catch |err| {
            log.err("failed to update hyperlink on cursor change err={}", .{err});
        };
        link.deinit(self.alloc);
        self.alloc.destroy(link);
    }
}
pub inline fn cursorMarkDirty(self: *Screen) void {
    self.cursor.page_row.dirty = true;
}
pub fn cursorResetWrap(self: *Screen) void {
    self.cursor.pending_wrap = false;
    const page_row = self.cursor.page_row;
    if (!page_row.wrap) return;
    page_row.wrap = false;
    if (self.cursor.page_pin.down(1)) |next_row| {
        next_row.rowAndCell().row.wrap_continuation = false;
    }
    const cells = self.cursor.page_pin.cells(.all);
    const cell = cells[self.cursor.page_pin.node.cols() - 1];
    if (cell.wide == .spacer_head) {
        self.clearCells(
            self.cursor.page_pin.node.page(),
            page_row,
            cells[self.cursor.page_pin.node.cols() - 1 ..][0..1],
        );
    }
}
pub const Scroll = union(enum) {
    active,
    top,
    pin: Pin,
    row: usize,
    delta_row: isize,
    delta_prompt: isize,
};
pub inline fn scroll(self: *Screen, behavior: Scroll) void {
    defer self.assertIntegrity();
    if (comptime build_options.kitty_graphics) {
        self.kitty_images.dirty = true;
    }
    switch (behavior) {
        .active => self.pages.scroll(.{ .active = {} }),
        .top => self.pages.scroll(.{ .top = {} }),
        .pin => |p| self.pages.scroll(.{ .pin = p }),
        .row => |v| self.pages.scroll(.{ .row = v }),
        .delta_row => |v| self.pages.scroll(.{ .delta_row = v }),
        .delta_prompt => |v| self.pages.scroll(.{ .delta_prompt = v }),
    }
}
pub inline fn scrollClear(self: *Screen) !void {
    defer self.assertIntegrity();
    try self.pages.scrollClear();
    self.cursorReload();
    if (comptime build_options.kitty_graphics) {
        self.kitty_images.dirty = true;
    }
}
pub inline fn viewportIsBottom(self: Screen) bool {
    return self.pages.viewport == .active;
}
pub inline fn eraseHistory(
    self: *Screen,
    bl: ?point.Point,
) void {
    defer self.assertIntegrity();
    self.pages.eraseHistory(bl);
    self.cursorReload();
}
pub inline fn eraseActive(
    self: *Screen,
    y: size.CellCountInt,
) void {
    defer self.assertIntegrity();
    self.pages.eraseActive(y);
    self.cursorReload();
}
pub fn clearRows(
    self: *Screen,
    tl: point.Point,
    bl: ?point.Point,
    protected: bool,
) void {
    defer self.assertIntegrity();
    var it = self.pages.pageIterator(.right_down, tl, bl);
    while (it.next()) |chunk| {
        const page = chunk.node.page();
        for (chunk.rows()) |*row| {
            const cells_offset = row.cells;
            const cells = page.getCells(row);
            if (protected) {
                self.clearUnprotectedCells(page, row, cells);
                row.cells = cells_offset;
            } else {
                self.clearCells(page, row, cells);
                row.* = .{ .cells = cells_offset };
            }
            row.dirty = true;
        }
    }
}
pub fn clearCells(
    self: *Screen,
    page: *Page,
    row: *Row,
    cells: []Cell,
) void {
    if (cells.len == 0) return;
    page.pauseIntegrityChecks(true);
    defer {
        page.pauseIntegrityChecks(false);
        page.assertIntegrity();
        self.assertIntegrity();
    }
    if (comptime std.debug.runtime_safety) {
        const page_rows = page.rows.ptr(page.memory.ptr);
        assert(@intFromPtr(row) >= @intFromPtr(&page_rows[0]));
        assert(@intFromPtr(row) <= @intFromPtr(&page_rows[page.size.rows - 1]));
        const row_cells = page.getCells(row);
        assert(@intFromPtr(&cells[0]) >= @intFromPtr(&row_cells[0]));
        assert(@intFromPtr(&cells[cells.len - 1]) <= @intFromPtr(&row_cells[row_cells.len - 1]));
    }
    if (row.grapheme) {
        for (cells) |*cell| {
            if (cell.hasGrapheme())
                page.clearGrapheme(cell);
        }
        if (cells.len == page.size.cols) {
            row.grapheme = false;
        } else {
            page.updateRowGraphemeFlag(row);
        }
    }
    if (row.hyperlink) {
        for (cells) |*cell| {
            if (cell.hyperlink)
                page.clearHyperlink(cell);
        }
        if (cells.len == page.size.cols) {
            row.hyperlink = false;
        } else {
            page.updateRowHyperlinkFlag(row);
        }
    }
    if (row.styled) {
        var i: usize = 0;
        while (i < cells.len) {
            const id = cells[i].style_id;
            if (id == style.default_id) {
                i += 1;
                continue;
            }
            var j = i + 1;
            while (j < cells.len and cells[j].style_id == id) j += 1;
            page.styles.releaseMultiple(page.memory, id, @intCast(j - i));
            i = j;
        }
        if (cells.len == page.size.cols) {
            row.styled = false;
        } else {
            page.updateRowStyledFlag(row);
        }
    }
    if (comptime build_options.kitty_graphics) {
        if (cells.len == page.size.cols) {
            row.kitty_virtual_placeholder = false;
        }
    }
    @memset(cells, self.blankCell());
}
pub fn clearUnprotectedCells(
    self: *Screen,
    page: *Page,
    row: *Row,
    cells: []Cell,
) void {
    var x0: usize = 0;
    var x1: usize = 0;
    while (x0 < cells.len) clear: {
        while (cells[x0].protected) {
            x0 += 1;
            if (x0 >= cells.len) break :clear;
        }
        x1 = x0 + 1;
        while (x1 < cells.len and !cells[x1].protected) {
            x1 += 1;
        }
        self.clearCells(page, row, cells[x0..x1]);
        x0 = x1;
    }
    page.assertIntegrity();
    self.assertIntegrity();
}
pub fn splitCellBoundary(
    self: *Screen,
    x: size.CellCountInt,
) void {
    const page = self.cursor.page_pin.node.page();
    page.pauseIntegrityChecks(true);
    defer page.pauseIntegrityChecks(false);
    const cols = self.cursor.page_pin.node.cols();
    assert(x <= cols);
    if (x == cols) {
        if (!self.cursor.page_row.wrap) return;
        const cells = self.cursor.page_pin.cells(.all);
        if (cells[cols - 1].wide == .spacer_head) {
            self.clearCells(
                page,
                self.cursor.page_row,
                cells[cols - 1 ..][0..1],
            );
        }
        return;
    }
    if ((x == 0 or x == 1) and self.cursor.page_row.wrap_continuation) {
        const cells = self.cursor.page_pin.cells(.all);
        if (cells[0].wide == .wide) {
            if (self.cursor.page_pin.up(1)) |p_row| {
                const p_rac = p_row.rowAndCell();
                const p_cells = p_row.cells(.all);
                const p_cell = p_cells[p_row.node.cols() - 1];
                if (p_cell.wide == .spacer_head) {
                    self.clearCells(
                        p_row.node.page(),
                        p_rac.row,
                        p_cells[p_row.node.cols() - 1 ..][0..1],
                    );
                    p_row.markDirty();
                }
            }
        }
    }
    if (x == 0) return;
    {
        assert(x > 0);
        assert(x < cols);
        const cells = self.cursor.page_pin.cells(.all);
        const left = cells[x - 1];
        switch (left.wide) {
            .spacer_head => unreachable,
            .narrow, .spacer_tail => {},
            .wide => {
                self.clearCells(
                    page,
                    self.cursor.page_row,
                    cells[x - 1 ..][0..2],
                );
            },
        }
    }
}
pub inline fn blankCell(self: *const Screen) Cell {
    if (self.cursor.style_id == style.default_id) return .{};
    return self.cursor.style.bgCell() orelse .{};
}
pub const Resize = struct {
    cols: size.CellCountInt,
    rows: size.CellCountInt,
    reflow: bool = true,
    prompt_redraw: osc.semantic_prompt.Redraw = .false,
    pull_scrollback: bool = true,
};
const resize_tw = tripwire.module(enum {
    saved_cursor_pin,
    pages,
}, resize);
pub inline fn resize(
    self: *Screen,
    opts: Resize,
) Allocator.Error!void {
    const tw = resize_tw;
    defer self.assertIntegrity();
    const saved_cursor_pin: ?*Pin = saved_cursor: {
        const sc = self.saved_cursor orelse break :saved_cursor null;
        const pin = self.pages.pin(.{ .active = .{
            .x = sc.x,
            .y = sc.y,
        } }) orelse break :saved_cursor null;
        try tw.check(.saved_cursor_pin);
        break :saved_cursor try self.pages.trackPin(pin);
    };
    defer if (saved_cursor_pin) |p| self.pages.untrackPin(p);
    const cursor_node = self.cursor.page_pin.node;
    const cursor_node_serial = cursor_node.serial;
    const cursor_style = self.cursor.style;
    const cursor_style_id = self.cursor.style_id;
    const cursor_hyperlink = self.cursor.hyperlink;
    const cursor_hyperlink_id = self.cursor.hyperlink_id;
    {
        const page = cursor_node.page();
        if (cursor_style_id != style.default_id) {
            page.styles.use(page.memory, cursor_style_id);
        }
        if (cursor_hyperlink_id != 0) {
            page.hyperlink_set.use(page.memory, cursor_hyperlink_id);
        }
    }
    errdefer {
        self.cursor.style = cursor_style;
        self.cursor.style_id = cursor_style_id;
        self.cursor.hyperlink = cursor_hyperlink;
        self.cursor.hyperlink_id = cursor_hyperlink_id;
    }
    self.cursor.style = .{};
    self.manualStyleUpdate() catch unreachable;
    if (self.cursor.hyperlink_id != 0) {
        var page = self.cursor.page_pin.node.page();
        page.hyperlink_set.release(page.memory, self.cursor.hyperlink_id);
        self.cursor.hyperlink_id = 0;
        self.cursor.hyperlink = null;
    }
    try tw.check(.pages);
    try self.pages.resize(.{
        .rows = opts.rows,
        .cols = opts.cols,
        .reflow = opts.reflow,
        .cursor = .{
            .x = self.cursor.x,
            .y = self.cursor.y,
            .pin = self.cursor.page_pin,
        },
        .pull_scrollback = opts.pull_scrollback,
    });
    errdefer comptime unreachable;
    if (comptime build_options.kitty_graphics) self.kitty_images.dirty = true;
    if (self.no_scrollback) self.pages.eraseHistory(null);
    self.cursorReload();
    if (self.cursor.pending_wrap and self.cursor.x != opts.cols - 1) {
        self.cursor.pending_wrap = false;
        self.cursorRight(1);
    }
    self.clearPromptForRedraw(opts.prompt_redraw);
    self.cursor.style = cursor_style;
    self.manualStyleUpdate() catch |err| {
        log.err("failed to update style on cursor reload err={}", .{err});
        self.cursor.style = .{};
        self.cursor.style_id = 0;
    };
    if (saved_cursor_pin) |p| {
        const sc = &self.saved_cursor.?;
        if (self.pages.pointFromPin(.active, p.*)) |pt| {
            sc.x = @intCast(pt.active.x);
            sc.y = @intCast(pt.active.y);
            if (sc.pending_wrap and sc.x != opts.cols - 1) {
                sc.pending_wrap = false;
                sc.x += 1;
            }
        } else {
            sc.x = 0;
            sc.y = 0;
            sc.pending_wrap = false;
        }
    }
    if (cursor_hyperlink) |link| {
        self.startHyperlink(link.uri, switch (link.id) {
            .explicit => |v| v,
            .implicit => null,
        }) catch |err| {
            log.err("failed to update hyperlink on resize err={}", .{err});
        };
        link.deinit(self.alloc);
        self.alloc.destroy(link);
    }
    const cursor_node_survived =
        self.cursor.page_pin.node == cursor_node and
        self.cursor.page_pin.node.serial == cursor_node_serial;
    if (comptime build_options.slow_runtime_safety) {
        assert(cursor_node_survived ==
            self.pages.nodeIsValid(cursor_node, cursor_node_serial));
    }
    if (cursor_node_survived) {
        const page = cursor_node.page();
        if (cursor_style_id != style.default_id) {
            page.styles.release(page.memory, cursor_style_id);
        }
        if (cursor_hyperlink_id != 0) {
            page.hyperlink_set.release(page.memory, cursor_hyperlink_id);
        }
    }
}
fn clearPromptForRedraw(
    self: *Screen,
    redraw: osc.semantic_prompt.Redraw,
) void {
    if (redraw != .false and
        self.cursor.semantic_content != .output)
    prompt: {
        switch (redraw) {
            .false => unreachable,
            .last => {
                const page = self.cursor.page_pin.node.page();
                const row = self.cursor.page_row;
                const cells = page.getCells(row);
                self.clearCells(page, row, cells);
            },
            .true => {
                const start = start: {
                    var it = self.cursor.page_pin.promptIterator(
                        .left_up,
                        null,
                    );
                    break :start it.next() orelse {
                        log.warn("cursor on prompt line but promptIterator found no prompt", .{});
                        break :prompt;
                    };
                };
                var it = start.rowIterator(.right_down, null);
                while (it.next()) |pin| {
                    const page = pin.node.page();
                    const row = pin.rowAndCell().row;
                    const cells = page.getCells(row);
                    self.clearCells(page, row, cells);
                }
            },
        }
    }
}
pub fn setAttribute(
    self: *Screen,
    attr: sgr.Attribute,
) PageList.IncreaseCapacityError!void {
    const old_style = self.cursor.style;
    errdefer {
        self.cursor.style = old_style;
        self.manualStyleUpdate() catch |err| {
            log.warn("setAttribute error restoring old style after failure err={}", .{err});
            self.cursor.style = .{};
            self.manualStyleUpdate() catch unreachable;
        };
    }
    switch (attr) {
        .unset => {
            self.cursor.style = .{};
        },
        .bold => {
            self.cursor.style.flags.bold = true;
        },
        .reset_bold => {
            self.cursor.style.flags.bold = false;
            self.cursor.style.flags.faint = false;
        },
        .italic => {
            self.cursor.style.flags.italic = true;
        },
        .reset_italic => {
            self.cursor.style.flags.italic = false;
        },
        .faint => {
            self.cursor.style.flags.faint = true;
        },
        .underline => |v| {
            self.cursor.style.flags.underline = v;
        },
        .underline_color => |rgb| {
            self.cursor.style.underline_color = .{ .rgb = .{
                .r = rgb.r,
                .g = rgb.g,
                .b = rgb.b,
            } };
        },
        .@"256_underline_color" => |idx| {
            self.cursor.style.underline_color = .{ .palette = idx };
        },
        .reset_underline_color => {
            self.cursor.style.underline_color = .none;
        },
        .overline => {
            self.cursor.style.flags.overline = true;
        },
        .reset_overline => {
            self.cursor.style.flags.overline = false;
        },
        .blink => {
            self.cursor.style.flags.blink = true;
        },
        .reset_blink => {
            self.cursor.style.flags.blink = false;
        },
        .inverse => {
            self.cursor.style.flags.inverse = true;
        },
        .reset_inverse => {
            self.cursor.style.flags.inverse = false;
        },
        .invisible => {
            self.cursor.style.flags.invisible = true;
        },
        .reset_invisible => {
            self.cursor.style.flags.invisible = false;
        },
        .strikethrough => {
            self.cursor.style.flags.strikethrough = true;
        },
        .reset_strikethrough => {
            self.cursor.style.flags.strikethrough = false;
        },
        .direct_color_fg => |rgb| {
            self.cursor.style.fg_color = .{
                .rgb = .{
                    .r = rgb.r,
                    .g = rgb.g,
                    .b = rgb.b,
                },
            };
        },
        .direct_color_bg => |rgb| {
            self.cursor.style.bg_color = .{
                .rgb = .{
                    .r = rgb.r,
                    .g = rgb.g,
                    .b = rgb.b,
                },
            };
        },
        .@"8_fg" => |n| {
            self.cursor.style.fg_color = .{ .palette = @intFromEnum(n) };
        },
        .@"8_bg" => |n| {
            self.cursor.style.bg_color = .{ .palette = @intFromEnum(n) };
        },
        .reset_fg => self.cursor.style.fg_color = .none,
        .reset_bg => self.cursor.style.bg_color = .none,
        .@"8_bright_fg" => |n| {
            self.cursor.style.fg_color = .{ .palette = @intFromEnum(n) };
        },
        .@"8_bright_bg" => |n| {
            self.cursor.style.bg_color = .{ .palette = @intFromEnum(n) };
        },
        .@"256_fg" => |idx| {
            self.cursor.style.fg_color = .{ .palette = idx };
        },
        .@"256_bg" => |idx| {
            self.cursor.style.bg_color = .{ .palette = idx };
        },
        .unknown => return,
    }
    if (self.cursor.style.eql(old_style)) return;
    try self.manualStyleUpdate();
}
pub fn manualStyleUpdate(self: *Screen) PageList.IncreaseCapacityError!void {
    defer self.assertIntegrity();
    var page: *Page = self.cursor.page_pin.node.page();
    if (self.cursor.style_id != style.default_id) {
        page.styles.release(page.memory, self.cursor.style_id);
    }
    if (self.cursor.style.default()) {
        self.cursor.style_id = style.default_id;
        return;
    }
    self.cursor.style_id = style.default_id;
    const id = page.styles.add(
        page.memory,
        self.cursor.style,
    ) catch |err| id: {
        const node = self.increaseCapacity(
            self.cursor.page_pin.node,
            switch (err) {
                error.OutOfMemory => .styles,
                error.NeedsRehash => null,
            },
        ) catch |increase_err| switch (increase_err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.OutOfSpace => space: {
                try self.splitForCapacity(self.cursor.page_pin.*);
                break :space self.cursor.page_pin.node;
            },
        };
        page = node.page();
        break :id page.styles.add(
            page.memory,
            self.cursor.style,
        ) catch |err2| switch (err2) {
            error.OutOfMemory => {
                log.err("style addition failed after capacity increase", .{});
                return error.OutOfMemory;
            },
            error.NeedsRehash => {
                log.err("style rehash resulted in needs rehash", .{});
                return;
            },
        };
    };
    errdefer page.styles.release(page.memory, id);
    self.cursor.style_id = id;
}
fn splitForCapacity(
    self: *Screen,
    pin: Pin,
) PageList.SplitError!void {
    const bytes_above = Page.layout(pin.node.page().exactRowCapacity(
        0,
        pin.y + 1,
    )).total_size;
    const bytes_below = Page.layout(pin.node.page().exactRowCapacity(
        pin.y,
        pin.node.rows(),
    )).total_size;
    const old_cursor = self.cursor.page_pin.*;
    try self.pages.split(if (bytes_above < bytes_below)
        pin.down(1) orelse pin
    else
        pin);
    if (self.cursor.page_pin.node == old_cursor.node) return;
    const new_cursor = self.cursor.page_pin.*;
    self.cursor.page_pin.* = old_cursor;
    self.cursorChangePin(new_cursor);
}
pub fn appendGrapheme(
    self: *Screen,
    cell: *Cell,
    cp: u21,
) PageList.IncreaseCapacityError!void {
    defer self.cursor.page_pin.node.page().assertIntegrity();
    self.cursor.page_pin.node.page().appendGrapheme(
        self.cursor.page_row,
        cell,
        cp,
    ) catch |err| switch (err) {
        error.OutOfMemory => {
            const cell_idx: usize = cell_idx: {
                const cells: [*]Cell = @ptrCast(self.cursor.page_cell);
                const zero: [*]Cell = cells - self.cursor.x;
                const target: [*]Cell = @ptrCast(cell);
                const cell_idx = (@intFromPtr(target) - @intFromPtr(zero)) / @sizeOf(Cell);
                break :cell_idx cell_idx;
            };
            _ = try self.increaseCapacity(
                self.cursor.page_pin.node,
                .grapheme_bytes,
            );
            const reloaded_cell: *Cell = switch (std.math.order(cell_idx, self.cursor.x)) {
                .eq => self.cursor.page_cell,
                .lt => self.cursorCellLeft(@intCast(self.cursor.x - cell_idx)),
                .gt => self.cursorCellRight(@intCast(cell_idx - self.cursor.x)),
            };
            self.cursor.page_pin.node.page().appendGrapheme(
                self.cursor.page_row,
                reloaded_cell,
                cp,
            ) catch |err2| {
                comptime assert(@TypeOf(err2) == error{OutOfMemory});
                log.err("grapheme append failed after capacity increase", .{});
                return err2;
            };
        },
    };
}
pub fn setGraphemes(
    self: *Screen,
    cell: *Cell,
    cps: []const u21,
) PageList.IncreaseCapacityError!void {
    defer self.cursor.page_pin.node.page().assertIntegrity();
    self.cursor.page_pin.node.page().setGraphemes(
        self.cursor.page_row,
        cell,
        cps,
    ) catch |err| switch (err) {
        error.GraphemeMapOutOfMemory,
        error.GraphemeAllocOutOfMemory,
        => {
            const cell_idx: usize = cell_idx: {
                const cells: [*]Cell = @ptrCast(self.cursor.page_cell);
                const zero: [*]Cell = cells - self.cursor.x;
                const target: [*]Cell = @ptrCast(cell);
                const cell_idx = (@intFromPtr(target) - @intFromPtr(zero)) / @sizeOf(Cell);
                break :cell_idx cell_idx;
            };
            _ = try self.increaseCapacity(
                self.cursor.page_pin.node,
                .grapheme_bytes,
            );
            const reloaded_cell: *Cell = switch (std.math.order(cell_idx, self.cursor.x)) {
                .eq => self.cursor.page_cell,
                .lt => self.cursorCellLeft(@intCast(self.cursor.x - cell_idx)),
                .gt => self.cursorCellRight(@intCast(cell_idx - self.cursor.x)),
            };
            self.cursor.page_pin.node.page().setGraphemes(
                self.cursor.page_row,
                reloaded_cell,
                cps,
            ) catch |err2| {
                comptime assert(@TypeOf(err2) == Page.GraphemeError);
                log.err("grapheme set failed after capacity increase err={}", .{err2});
                return error.OutOfMemory;
            };
        },
    };
}
pub fn startHyperlink(
    self: *Screen,
    uri: []const u8,
    id_: ?[]const u8,
) PageList.IncreaseCapacityError!void {
    const link: hyperlink.Hyperlink = .{
        .uri = uri,
        .id = if (id_) |id| .{
            .explicit = id,
        } else implicit: {
            defer self.cursor.hyperlink_implicit_id +%= 1;
            break :implicit .{ .implicit = self.cursor.hyperlink_implicit_id };
        },
    };
    errdefer switch (link.id) {
        .explicit => {},
        .implicit => self.cursor.hyperlink_implicit_id -%= 1,
    };
    while (true) {
        if (self.startHyperlinkOnce(link)) {
            return;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StringsOutOfMemory => _ = try self.increaseCapacity(
                self.cursor.page_pin.node,
                .string_bytes,
            ),
            error.SetOutOfMemory => _ = try self.increaseCapacity(
                self.cursor.page_pin.node,
                .hyperlink_bytes,
            ),
            error.SetNeedsRehash => _ = try self.increaseCapacity(
                self.cursor.page_pin.node,
                null,
            ),
        }
        self.assertIntegrity();
    }
}
fn startHyperlinkOnce(
    self: *Screen,
    source: hyperlink.Hyperlink,
) (Allocator.Error || Page.InsertHyperlinkError)!void {
    const link = try self.alloc.create(hyperlink.Hyperlink);
    errdefer self.alloc.destroy(link);
    link.* = try source.dupe(self.alloc);
    errdefer link.deinit(self.alloc);
    self.endHyperlink();
    var page = self.cursor.page_pin.node.page();
    const id: hyperlink.Id = try page.insertHyperlink(link.*);
    self.cursor.hyperlink = link;
    self.cursor.hyperlink_id = id;
}
pub fn endHyperlink(self: *Screen) void {
    if (self.cursor.hyperlink_id == 0) {
        assert(self.cursor.hyperlink == null);
        return;
    }
    var page: *Page = self.cursor.page_pin.node.page();
    page.hyperlink_set.release(page.memory, self.cursor.hyperlink_id);
    self.cursor.hyperlink.?.deinit(self.alloc);
    self.alloc.destroy(self.cursor.hyperlink.?);
    self.cursor.hyperlink_id = 0;
    self.cursor.hyperlink = null;
}
pub fn cursorSetHyperlink(self: *Screen) PageList.IncreaseCapacityError!void {
    assert(self.cursor.hyperlink_id != 0);
    var page = self.cursor.page_pin.node.page();
    if (page.setHyperlink(
        self.cursor.page_row,
        self.cursor.page_cell,
        self.cursor.hyperlink_id,
    )) {
        page.hyperlink_set.use(page.memory, self.cursor.hyperlink_id);
        return;
    } else |err| switch (err) {
        error.HyperlinkMapOutOfMemory => {
            while (self.cursor.hyperlink) |link| {
                if (page.string_alloc.alloc(
                    u8,
                    page.memory,
                    link.uri.len,
                )) |slice| {
                    _ = slice;
                    break;
                } else |_| {}
                const new_node = try self.increaseCapacity(
                    self.cursor.page_pin.node,
                    .string_bytes,
                );
                assert(new_node == self.cursor.page_pin.node);
                page = new_node.page();
            }
            _ = try self.increaseCapacity(
                self.cursor.page_pin.node,
                .hyperlink_bytes,
            );
            if (self.cursor.hyperlink_id > 0) {
                return try self.cursorSetHyperlink();
            }
        },
    }
}
pub fn cursorSetSemanticContent(self: *Screen, t: union(enum) {
    prompt: osc.semantic_prompt.PromptKind,
    output,
    input: enum { clear_explicit, clear_eol },
}) void {
    const cursor = &self.cursor;
    switch (t) {
        .output => {
            cursor.semantic_content = .output;
            cursor.semantic_content_clear_eol = false;
        },
        .input => |clear| {
            cursor.semantic_content = .input;
            cursor.semantic_content_clear_eol = switch (clear) {
                .clear_explicit => false,
                .clear_eol => true,
            };
        },
        .prompt => |kind| {
            self.semantic_prompt.seen = true;
            cursor.semantic_content = .prompt;
            cursor.semantic_content_clear_eol = false;
            cursor.page_row.semantic_prompt = switch (kind) {
                .initial, .right => .prompt,
                .continuation, .secondary => .prompt_continuation,
            };
        },
    }
}
pub fn select(self: *Screen, sel_: ?Selection) Allocator.Error!void {
    const sel = sel_ orelse {
        self.clearSelection();
        return;
    };
    const tracked_sel = if (sel.tracked()) sel else try sel.track(self);
    errdefer if (!sel.tracked()) tracked_sel.deinit(self);
    if (self.selection) |old| {
        const new_bounds = tracked_sel.bounds.tracked;
        switch (old.bounds) {
            .untracked => old.deinit(self),
            .tracked => |old_bounds| {
                if (old_bounds.start != new_bounds.start and
                    old_bounds.start != new_bounds.end)
                {
                    self.pages.untrackPin(old_bounds.start);
                }
                if (old_bounds.end != new_bounds.start and
                    old_bounds.end != new_bounds.end)
                {
                    self.pages.untrackPin(old_bounds.end);
                }
            },
        }
    }
    self.selection = tracked_sel;
    self.dirty.selection = true;
}
pub fn clearSelection(self: *Screen) void {
    if (self.selection) |*sel| {
        sel.deinit(self);
        self.dirty.selection = true;
    }
    self.selection = null;
}
pub const SelectionString = struct {
    sel: Selection,
    trim: bool = true,
};
pub fn selectionString(
    self: *Screen,
    alloc: Allocator,
    opts: SelectionString,
) Allocator.Error![:0]const u8 {
    return self.selectionStringImpl(alloc, opts, null);
}
pub fn selectionStringMap(
    self: *Screen,
    alloc: Allocator,
    opts: SelectionString,
) Allocator.Error!StringMap {
    var pins: PinMap.Map = .empty;
    errdefer pins.deinit(alloc);
    return .{
        .string = try self.selectionStringImpl(alloc, opts, &pins),
        .map = pins,
    };
}
fn selectionStringImpl(
    self: *Screen,
    alloc: Allocator,
    opts: SelectionString,
    pins: ?*PinMap.Map,
) Allocator.Error![:0]const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var formatter: ScreenFormatter = .init(
        self,
        .{
            .emit = .plain,
            .unwrap = true,
            .trim = opts.trim,
        },
    );
    formatter.content = .{ .selection = opts.sel };
    if (pins) |map| formatter.pin_map = .{
        .alloc = alloc,
        .map = map,
    };
    formatter.format(&aw.writer) catch return error.OutOfMemory;
    return try aw.toOwnedSliceSentinel(0);
}
pub const SelectLine = struct {
    pin: Pin,
    whitespace: ?[]const u21 = &selection_codepoints.default_line_whitespace,
    semantic_prompt_boundary: bool = true,
};
pub fn selectLine(self: *const Screen, opts: SelectLine) ?Selection {
    _ = self;
    const semantic_prompt_state: ?Cell.SemanticContent = state: {
        if (!opts.semantic_prompt_boundary) break :state null;
        const rac = opts.pin.rowAndCell();
        break :state rac.cell.semantic_content;
    };
    const start_pin: Pin = start_pin: {
        var it = opts.pin.rowIterator(.left_up, null);
        var it_prev: Pin = it.next().?;
        if (semantic_prompt_state) |v| {
            const row = it_prev.rowAndCell().row;
            const cells = it_prev.node.page().getCells(row);
            for (0..opts.pin.x + 1) |i| {
                const x_rev = opts.pin.x - i;
                if (cells[x_rev].semantic_content != v) {
                    var copy = it_prev;
                    copy.x = @intCast(x_rev + 1);
                    break :start_pin copy;
                }
            }
        }
        while (it.next()) |p| {
            const row = p.rowAndCell().row;
            if (!row.wrap) {
                var copy = it_prev;
                copy.x = 0;
                break :start_pin copy;
            }
            if (semantic_prompt_state) |v| {
                const cells = p.node.page().getCells(row);
                for (0..cells.len) |x| {
                    const x_rev = cells.len - 1 - x;
                    const cell = cells[x_rev];
                    if (cell.semantic_content != v) break :start_pin it_prev;
                    it_prev = p;
                    it_prev.x = @intCast(x_rev);
                }
                continue;
            }
            it_prev = p;
        } else {
            var copy = it_prev;
            copy.x = 0;
            break :start_pin copy;
        }
    };
    const end_pin: Pin = end_pin: {
        var it = opts.pin.rowIterator(.right_down, null);
        while (it.next()) |p| {
            const row = p.rowAndCell().row;
            if (semantic_prompt_state) |v| {
                const cells = p.node.page().getCells(row);
                const start_offset = if (p.node == opts.pin.node and
                    p.y == opts.pin.y) opts.pin.x else 0;
                if (start_offset == 0 and cells[0].semantic_content != v) {
                    var prev = p.up(1).?;
                    prev.x = prev.node.cols() - 1;
                    break :end_pin prev;
                }
                for (start_offset.., cells[start_offset..]) |x, cell| {
                    if (cell.semantic_content != v) {
                        var copy = p;
                        copy.x = @intCast(x - 1);
                        break :end_pin copy;
                    }
                }
            }
            if (!row.wrap) {
                var copy = p;
                copy.x = p.node.cols() - 1;
                break :end_pin copy;
            }
        }
        return null;
    };
    const start: Pin = start: {
        const whitespace = opts.whitespace orelse break :start start_pin;
        var it = start_pin.cellIterator(.right_down, end_pin);
        while (it.next()) |p| {
            if (end_pin.before(p)) return null;
            const cell = p.rowAndCell().cell;
            if (!cell.hasText()) continue;
            const this_whitespace = std.mem.indexOfScalar(
                u21,
                whitespace,
                cell.content.codepoint.data,
            ) != null;
            if (this_whitespace) continue;
            break :start p;
        }
        return null;
    };
    const end: Pin = end: {
        const whitespace = opts.whitespace orelse break :end end_pin;
        var it = end_pin.cellIterator(.left_up, start_pin);
        while (it.next()) |p| {
            const cell = p.rowAndCell().cell;
            if (!cell.hasText()) continue;
            const this_whitespace = std.mem.indexOfScalar(
                u21,
                whitespace,
                cell.content.codepoint.data,
            ) != null;
            if (this_whitespace) continue;
            break :end p;
        }
        return null;
    };
    return .init(start, end, false);
}
pub fn selectAll(self: *Screen) ?Selection {
    const whitespace = &[_]u32{ 0, ' ', '\t' };
    const start: Pin = start: {
        var it = self.pages.cellIterator(
            .right_down,
            .{ .screen = .{} },
            null,
        );
        while (it.next()) |p| {
            const cell = p.rowAndCell().cell;
            if (!cell.hasText()) continue;
            const this_whitespace = std.mem.indexOfAny(
                u32,
                whitespace,
                &[_]u32{cell.content.codepoint.data},
            ) != null;
            if (this_whitespace) continue;
            break :start p;
        }
        return null;
    };
    const end: Pin = end: {
        var it = self.pages.cellIterator(
            .left_up,
            .{ .screen = .{} },
            null,
        );
        while (it.next()) |p| {
            const cell = p.rowAndCell().cell;
            if (!cell.hasText()) continue;
            const this_whitespace = std.mem.indexOfAny(
                u32,
                whitespace,
                &[_]u32{cell.content.codepoint.data},
            ) != null;
            if (this_whitespace) continue;
            break :end p;
        }
        return null;
    };
    return .init(start, end, false);
}
pub fn selectWordBetween(
    self: *Screen,
    start: Pin,
    end: Pin,
    boundary_codepoints: []const u21,
) ?Selection {
    const dir: PageList.Direction = if (start.before(end)) .right_down else .left_up;
    var it = start.cellIterator(dir, end);
    while (it.next()) |pin| {
        switch (dir) {
            .right_down => if (end.before(pin)) return null,
            .left_up => if (pin.before(end)) return null,
        }
        if (self.selectWord(pin, boundary_codepoints)) |sel| return sel;
    }
    return null;
}
pub fn selectWord(
    self: *Screen,
    pin: Pin,
    boundary_codepoints: []const u21,
) ?Selection {
    _ = self;
    const start_codepoint = selectWordCodepoint(pin) orelse return null;
    const expect_boundary = std.mem.indexOfScalar(
        u21,
        boundary_codepoints,
        start_codepoint,
    ) != null;
    const end: Pin = end: {
        var it = pin.cellIterator(.right_down, null);
        var prev = it.next().?;
        while (it.next()) |p| {
            if (prev.x == prev.node.cols() - 1 and !prev.rowAndCell().row.wrap) {
                break :end prev;
            }
            const codepoint = selectWordCodepoint(p) orelse break :end prev;
            const this_boundary = std.mem.indexOfScalar(
                u21,
                boundary_codepoints,
                codepoint,
            ) != null;
            if (this_boundary != expect_boundary) break :end prev;
            prev = p;
        }
        break :end prev;
    };
    const start: Pin = start: {
        var it = pin.cellIterator(.left_up, null);
        var prev = it.next().?;
        while (it.next()) |p| {
            const rac = p.rowAndCell();
            if (p.x == p.node.cols() - 1 and !rac.row.wrap) {
                break :start prev;
            }
            const codepoint = selectWordCodepoint(p) orelse break :start prev;
            const this_boundary = std.mem.indexOfScalar(
                u21,
                boundary_codepoints,
                codepoint,
            ) != null;
            if (this_boundary != expect_boundary) break :start prev;
            prev = p;
        }
        break :start prev;
    };
    return .init(start, end, false);
}
fn selectWordCodepoint(pin: Pin) ?u21 {
    const rac = pin.rowAndCell();
    const cell = switch (rac.cell.wide) {
        .narrow, .wide => rac.cell,
        .spacer_tail => pin.left(1).rowAndCell().cell,
        .spacer_head => cell: {
            const next_row = pin.down(1) orelse return null;
            const owner = &next_row.cells(.all)[0];
            if (owner.wide != .wide) return null;
            break :cell owner;
        },
    };
    return if (cell.hasText()) cell.content.codepoint.data else null;
}
pub fn selectOutput(self: *Screen, pin: Pin) ?Selection {
    if (pin.rowAndCell().cell.semantic_content != .output) return null;
    const prompt_pin: Pin = prompt: {
        var it = pin.promptIterator(.left_up, null);
        if (it.next()) |p| break :prompt p;
        it = pin.promptIterator(.right_down, null);
        const next = it.next() orelse return null;
        const start_pin = self.pages.getTopLeft(.screen);
        var end_pin = next.up(1) orelse return null;
        end_pin.x = end_pin.node.cols() - 1;
        var cell_it = end_pin.cellIterator(.left_up, start_pin);
        while (cell_it.next()) |p| {
            const cell = p.rowAndCell().cell;
            end_pin = p;
            if (cell.hasText()) break;
        }
        return .init(
            start_pin,
            end_pin,
            false,
        );
    };
    var hl = self.pages.highlightSemanticContent(
        prompt_pin,
        .output,
    ) orelse return null;
    var cell_it = hl.end.cellIterator(.left_up, hl.start);
    while (cell_it.next()) |p| {
        const cell = p.rowAndCell().cell;
        hl.end = p;
        if (cell.hasText()) break;
    }
    return .init(hl.start, hl.end, false);
}
pub const LineIterator = struct {
    screen: *const Screen,
    current: ?Pin = null,
    pub fn next(self: *LineIterator) ?Selection {
        const current = self.current orelse return null;
        const result = self.screen.selectLine(.{
            .pin = current,
            .whitespace = null,
            .semantic_prompt_boundary = false,
        }) orelse {
            self.current = null;
            return null;
        };
        self.current = result.end().down(1);
        return result;
    }
};
pub fn lineIterator(self: *const Screen, start: Pin) LineIterator {
    return LineIterator{
        .screen = self,
        .current = start,
    };
}
pub const PromptClickMove = struct {
    left: usize,
    right: usize,
    pub const zero = PromptClickMove{
        .left = 0,
        .right = 0,
    };
};
pub fn promptClickMove(
    self: *Screen,
    click_pin: Pin,
) PromptClickMove {
    if (self.cursor.semantic_content != .input and
        self.cursor.page_cell.semantic_content != .input) return .zero;
    return switch (self.semantic_prompt.click) {
        .none, .click_events => .zero,
        .cl => |cl| switch (cl) {
            .line,
            .multiple,
            .conservative_vertical,
            .smart_vertical,
            => self.promptClickLine(click_pin),
        },
    };
}
fn promptClickLine(self: *Screen, click_pin: Pin) PromptClickMove {
    const cursor_pin = self.cursor.page_pin.*;
    if (cursor_pin.eql(click_pin)) return .zero;
    if (cursor_pin.before(click_pin)) {
        var count: usize = 0;
        var row_it = cursor_pin.rowIterator(
            .right_down,
            click_pin,
        );
        row_it: while (row_it.next()) |row_pin| {
            const rac = row_pin.rowAndCell();
            const cells = row_pin.node.page().getCells(rac.row);
            const is_cursor_row = row_pin.node == cursor_pin.node and
                row_pin.y == cursor_pin.y;
            if (!is_cursor_row and
                rac.row.semantic_prompt != .prompt_continuation) break;
            const start_x: usize = start_x: {
                if (is_cursor_row) break :start_x cursor_pin.x + 1;
                for (cells, 0..) |cell, x| {
                    if (cell.semantic_content == .input) break :start_x x;
                }
                break :start_x cells.len;
            };
            for (cells[start_x..], start_x..) |cell, x| {
                if (cell.semantic_content != .input) continue;
                count += 1;
                if (row_pin.node == click_pin.node and
                    row_pin.y == click_pin.y and
                    x == click_pin.x)
                    break :row_it;
            }
            if (!rac.row.wrap) {
                if (self.cursor.page_cell.semantic_content == .input) count += 1;
                break;
            }
        }
        return .{ .left = 0, .right = count };
    }
    var count: usize = 0;
    var row_it = cursor_pin.rowIterator(
        .left_up,
        click_pin,
    );
    row_it: while (row_it.next()) |row_pin| {
        const rac = row_pin.rowAndCell();
        const cells = row_pin.node.page().getCells(rac.row);
        const end_len: usize = end_len: {
            if (row_pin.node == cursor_pin.node and
                row_pin.y == cursor_pin.y) break :end_len cursor_pin.x;
            break :end_len cells.len;
        };
        for (0..end_len) |rev_x| {
            const x: usize = end_len - 1 - rev_x;
            const cell = cells[x];
            if (cell.semantic_content != .input) continue;
            count += 1;
            if (row_pin.node == click_pin.node and
                row_pin.y == click_pin.y and
                x == click_pin.x)
                break :row_it;
        }
        if (!rac.row.wrap_continuation) break;
    }
    return .{ .left = count, .right = 0 };
}
pub fn dumpString(
    self: *const Screen,
    writer: *std.Io.Writer,
    opts: struct {
        tl: Pin,
        br: ?Pin = null,
        unwrap: bool = true,
    },
) std.Io.Writer.Error!void {
    var formatter: ScreenFormatter = .init(self, .{
        .emit = .plain,
        .unwrap = opts.unwrap,
        .trim = false,
    });
    const tl = opts.tl;
    const br = opts.br orelse self.pages.getBottomRight(.screen).?;
    formatter.content = .{
        .selection = Selection.init(
            tl,
            br,
            false,
        ),
    };
    try formatter.format(writer);
}
pub fn dumpStringAlloc(
    self: *const Screen,
    alloc: Allocator,
    tl: point.Point,
) ![]const u8 {
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    try self.dumpString(&builder.writer, .{
        .tl = self.pages.getTopLeft(tl),
        .br = self.pages.getBottomRight(tl) orelse return error.UnknownPoint,
        .unwrap = false,
    });
    return try builder.toOwnedSlice();
}
pub fn dumpStringAllocUnwrapped(
    self: *const Screen,
    alloc: Allocator,
    tl: point.Point,
) ![]const u8 {
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    try self.dumpString(&builder.writer, .{
        .tl = self.pages.getTopLeft(tl),
        .br = self.pages.getBottomRight(tl) orelse return error.UnknownPoint,
        .unwrap = true,
    });
    return try builder.toOwnedSlice();
}
pub fn testWriteString(self: *Screen, text: []const u8) !void {
    const view = try std.unicode.Utf8View.init(text);
    var iter = view.iterator();
    while (iter.nextCodepoint()) |c| {
        if (c == '\n') {
            try self.cursorDownOrScroll();
            self.cursorHorizontalAbsolute(0);
            self.cursor.pending_wrap = false;
            if (self.cursor.semantic_content_clear_eol) {
                self.cursorSetSemanticContent(.output);
            } else switch (self.cursor.semantic_content) {
                .output => {},
                .prompt, .input => self.cursor.page_row.semantic_prompt = .prompt_continuation,
            }
            continue;
        }
        const width: usize = if (c <= 0xFF) 1 else @intCast(unicode.table.get(c).width);
        if (width == 0) {
            const cell = cell: {
                var cell = self.cursorCellLeft(1);
                switch (cell.wide) {
                    .narrow => {},
                    .wide => {},
                    .spacer_head => unreachable,
                    .spacer_tail => cell = self.cursorCellLeft(2),
                }
                break :cell cell;
            };
            try self.cursor.page_pin.node.page().appendGrapheme(
                self.cursor.page_row,
                cell,
                c,
            );
            continue;
        }
        if (self.cursor.pending_wrap) {
            assert(self.cursor.x == self.pages.cols - 1);
            self.cursor.pending_wrap = false;
            self.cursor.page_row.wrap = true;
            try self.cursorDownOrScroll();
            self.cursorHorizontalAbsolute(0);
            self.cursor.page_row.wrap_continuation = true;
            switch (self.cursor.semantic_content) {
                .output => {},
                .input, .prompt => self.cursor.page_row.semantic_prompt = .prompt_continuation,
            }
        }
        assert(width == 1 or width == 2);
        switch (width) {
            1 => {
                self.cursor.page_cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = @bitCast(@as(u24, @intCast(c))) },
                    .style_id = self.cursor.style_id,
                    .protected = self.cursor.protected,
                    .semantic_content = self.cursor.semantic_content,
                };
                if (self.cursor.style_id != style.default_id) {
                    const page = self.cursor.page_pin.node.page();
                    page.styles.use(page.memory, self.cursor.style_id);
                    self.cursor.page_row.styled = true;
                }
                if (self.cursor.hyperlink_id > 0) try self.cursorSetHyperlink();
            },
            2 => {
                if (self.cursor.x == self.pages.cols - 1) {
                    self.cursor.page_cell.* = .{
                        .content_tag = .codepoint,
                        .content = .{ .codepoint = .{ .data = 0 } },
                        .wide = .spacer_head,
                        .protected = self.cursor.protected,
                        .semantic_content = self.cursor.semantic_content,
                    };
                    if (self.cursor.hyperlink_id > 0) try self.cursorSetHyperlink();
                    self.cursor.page_row.wrap = true;
                    try self.cursorDownOrScroll();
                    self.cursorHorizontalAbsolute(0);
                    self.cursor.page_row.wrap_continuation = true;
                }
                self.cursor.page_cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = c } },
                    .style_id = self.cursor.style_id,
                    .wide = .wide,
                    .protected = self.cursor.protected,
                    .semantic_content = self.cursor.semantic_content,
                };
                if (self.cursor.hyperlink_id > 0) try self.cursorSetHyperlink();
                self.cursorRight(1);
                self.cursor.page_cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = 0 } },
                    .wide = .spacer_tail,
                    .protected = self.cursor.protected,
                    .semantic_content = self.cursor.semantic_content,
                };
                if (self.cursor.hyperlink_id > 0) try self.cursorSetHyperlink();
                if (self.cursor.style_id != style.default_id) {
                    const page = self.cursor.page_pin.node.page();
                    page.styles.use(page.memory, self.cursor.style_id);
                    page.styles.use(page.memory, self.cursor.style_id);
                    self.cursor.page_row.styled = true;
                }
            },
            else => unreachable,
        }
        if (self.cursor.x + 1 < self.pages.cols) {
            self.cursorRight(1);
        } else {
            self.cursor.pending_wrap = true;
        }
    }
}
test "Screen forwards optional scrollback limits" {
    const testing = std.testing;
    const max_lines: usize = 123;
    var s = try init(testing.io, testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_bytes = null,
        .max_scrollback_lines = max_lines,
    });
    defer s.deinit();
    try testing.expectEqual(
        std.math.maxInt(usize),
        s.pages.limits.bytes.explicit,
    );
    try testing.expectEqual(max_lines, s.pages.limits.lines.explicit);
    try testing.expect(!s.no_scrollback);
}
test "Screen reset cursor pin is not garbage" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    try s.testWriteString("hello, world");
    s.reset();
    try testing.expect(!s.cursor.page_pin.garbage);
}
test "Screen read and write" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    try testing.expectEqual(@as(style.Id, 0), s.cursor.style_id);
    try s.testWriteString("hello, world");
    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("hello, world", str);
}
test "Screen read and write newline" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    try testing.expectEqual(@as(style.Id, 0), s.cursor.style_id);
    try s.testWriteString("hello\nworld");
    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("hello\nworld", str);
}
test "Screen read and write scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 2, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    try s.testWriteString("hello\nworld\ntest");
    {
        const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("hello\nworld\ntest", str);
    }
    {
        const str = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("world\ntest", str);
    }
}
test "Screen read and write no scrollback small" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 2, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("hello\nworld\ntest");
    {
        const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("world\ntest", str);
    }
    {
        const str = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("world\ntest", str);
    }
}
test "Screen read and write no scrollback large" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 2, .max_scrollback_bytes = 0 });
    defer s.deinit();
    for (0..1_000) |i| {
        var buf: [128]u8 = undefined;
        const str = try std.fmt.bufPrint(&buf, "{}\n", .{i});
        try s.testWriteString(str);
    }
    try s.testWriteString("1000");
    {
        const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("999\n1000", str);
    }
}
test "Screen cursorCopy x/y" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.cursorAbsolute(2, 3);
    try testing.expect(s.cursor.x == 2);
    try testing.expect(s.cursor.y == 3);
    var s2 = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s2.deinit();
    try s2.cursorCopy(s.cursor, .{});
    try testing.expect(s2.cursor.x == 2);
    try testing.expect(s2.cursor.y == 3);
    try s2.testWriteString("Hello");
    {
        const str = try s2.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("\n\n\n  Hello", str);
    }
}
test "Screen cursorCopy style deref" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    var s2 = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s2.deinit();
    const page = s2.cursor.page_pin.node.page();
    try s2.setAttribute(.{ .bold = {} });
    try testing.expectEqual(@as(usize, 1), page.styles.count());
    try testing.expect(s2.cursor.style.flags.bold);
    try s2.cursorCopy(s.cursor, .{});
    try testing.expect(!s2.cursor.style.flags.bold);
    try testing.expectEqual(@as(usize, 0), page.styles.count());
}
test "Screen cursorCopy style deref new page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    var s2 = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 2048 });
    defer s2.deinit();
    const first_page_size = s2.pages.pages.first.?.capacity().rows;
    s2.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 5) |_| {
        try s2.testWriteString("\n");
    }
    s2.pages.pages.first.?.page().pauseIntegrityChecks(false);
    try s2.testWriteString("1\n2\n3\n4\n5\n6\n7\n8\n9\n10");
    const page = s2.cursor.page_pin.node.page();
    try testing.expectEqual(s2.pages.pages.last.?.page(), page);
    try testing.expect(s2.cursor.page_pin.node.prev != null);
    try testing.expect(s2.cursor.x == 2);
    try testing.expect(s2.cursor.y == 9);
    try s2.setAttribute(.{ .bold = {} });
    try testing.expectEqual(@as(usize, 1), page.styles.count());
    try testing.expect(s2.cursor.style.flags.bold);
    try s2.cursorCopy(s.cursor, .{});
    try testing.expect(!s2.cursor.style.flags.bold);
    try testing.expectEqual(@as(usize, 0), page.styles.count());
    try testing.expectEqual(page, s2.cursor.page_pin.node.next.?.page());
    try testing.expect(s2.cursor.x == 0);
    try testing.expect(s2.cursor.y == 0);
}
test "Screen cursorCopy style copy" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.setAttribute(.{ .bold = {} });
    var s2 = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s2.deinit();
    const page = s2.cursor.page_pin.node.page();
    try s2.cursorCopy(s.cursor, .{});
    try testing.expect(s2.cursor.style.flags.bold);
    try testing.expectEqual(@as(usize, 1), page.styles.count());
}
test "Screen cursorCopy hyperlink deref" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    var s2 = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s2.deinit();
    const page = s2.cursor.page_pin.node.page();
    try s2.startHyperlink("https://example.com/", null);
    try testing.expectEqual(@as(usize, 1), page.hyperlink_set.count());
    try testing.expect(s2.cursor.hyperlink_id != 0);
    try s2.cursorCopy(s.cursor, .{});
    try testing.expectEqual(@as(usize, 0), page.hyperlink_set.count());
    try testing.expect(s2.cursor.hyperlink_id == 0);
}
test "Screen write regrows compacted page capacity" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_bytes = 0,
    });
    defer s.deinit();
    {
        const node = (try s.pages.compact(s.cursor.page_pin.node)).?;
        try testing.expectEqual(0, node.capacity().styles);
        try testing.expectEqual(0, node.capacity().grapheme_bytes);
        try testing.expectEqual(0, node.capacity().string_bytes);
        try testing.expectEqual(0, node.capacity().hyperlink_bytes);
        s.cursorReload();
    }
    try s.setAttribute(.{ .bold = {} });
    try s.testWriteString("A");
    try s.testWriteString("a");
    try s.appendGrapheme(s.cursorCellLeft(1), 0x0301);
    try s.startHyperlink("https://example.com/", null);
    try s.testWriteString("B");
    s.endHyperlink();
    const page = s.cursor.page_pin.node.page();
    try testing.expect(page.styles.count() >= 1);
    try testing.expect(page.hyperlink_set.count() >= 1);
    try testing.expect(page.graphemeCount() >= 1);
}
test "Screen scrollClear across pages migrates cursor style and hyperlink" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{
        .cols = 10,
        .rows = 10,
        .max_scrollback_bytes = std.math.maxInt(usize),
    });
    defer s.deinit();
    const first_page_size = s.pages.pages.first.?.capacity().rows;
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 5) |_| {
        try s.testWriteString("\n");
    }
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);
    try s.testWriteString("1\n2\n3\n4\n5\n6\n7\n8\n9\n10");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    s.cursorAbsolute(0, 0);
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.first.?);
    try s.setAttribute(.{ .bold = {} });
    try s.startHyperlink("https://example.com/", null);
    const old_page: *Page = s.cursor.page_pin.node.page();
    const old_style_id = s.cursor.style_id;
    const old_hyperlink_id = s.cursor.hyperlink_id;
    try testing.expect(old_style_id != style.default_id);
    try testing.expect(old_hyperlink_id != 0);
    try s.scrollClear();
    const new_page: *Page = s.cursor.page_pin.node.page();
    try testing.expect(new_page != old_page);
    try testing.expect(s.cursor.style_id != style.default_id);
    try testing.expect(s.cursor.hyperlink_id != 0);
    try testing.expect(new_page.styles.refCount(
        new_page.memory,
        s.cursor.style_id,
    ) > 0);
    try testing.expect(new_page.hyperlink_set.refCount(
        new_page.memory,
        s.cursor.hyperlink_id,
    ) > 0);
    try testing.expectEqual(0, old_page.styles.refCount(
        old_page.memory,
        old_style_id,
    ));
    try testing.expectEqual(0, old_page.hyperlink_set.refCount(
        old_page.memory,
        old_hyperlink_id,
    ));
    try s.testWriteString("B");
}
test "Screen cursorCopy hyperlink deref new page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    var s2 = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 2048 });
    defer s2.deinit();
    const first_page_size = s2.pages.pages.first.?.capacity().rows;
    s2.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 5) |_| {
        try s2.testWriteString("\n");
    }
    s2.pages.pages.first.?.page().pauseIntegrityChecks(false);
    try s2.testWriteString("1\n2\n3\n4\n5\n6\n7\n8\n9\n10");
    const page = s2.cursor.page_pin.node.page();
    try testing.expectEqual(s2.pages.pages.last.?.page(), page);
    try testing.expect(s2.cursor.page_pin.node.prev != null);
    try testing.expect(s2.cursor.x == 2);
    try testing.expect(s2.cursor.y == 9);
    try s2.startHyperlink("https://example.com/", null);
    try testing.expectEqual(@as(usize, 1), page.hyperlink_set.count());
    try testing.expect(s2.cursor.hyperlink_id != 0);
    try s2.cursorCopy(s.cursor, .{});
    try testing.expectEqual(@as(usize, 0), page.hyperlink_set.count());
    try testing.expect(s2.cursor.hyperlink_id == 0);
    try testing.expectEqual(page, s2.cursor.page_pin.node.next.?.page());
    try testing.expect(s2.cursor.x == 0);
    try testing.expect(s2.cursor.y == 0);
}
test "Screen cursorCopy hyperlink copy" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.startHyperlink("https://example.com/", null);
    try testing.expectEqual(@as(usize, 1), s.cursor.page_pin.node.page().hyperlink_set.count());
    try testing.expect(s.cursor.hyperlink_id != 0);
    var s2 = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s2.deinit();
    const page = s2.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 0), page.hyperlink_set.count());
    try testing.expect(s2.cursor.hyperlink_id == 0);
    try s2.cursorCopy(s.cursor, .{});
    try testing.expectEqual(@as(usize, 1), page.hyperlink_set.count());
    try testing.expect(s2.cursor.hyperlink_id != 0);
}
test "Screen cursorCopy hyperlink copy disabled" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.startHyperlink("https://example.com/", null);
    try testing.expectEqual(@as(usize, 1), s.cursor.page_pin.node.page().hyperlink_set.count());
    try testing.expect(s.cursor.hyperlink_id != 0);
    var s2 = try Screen.init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s2.deinit();
    const page = s2.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 0), page.hyperlink_set.count());
    try testing.expect(s2.cursor.hyperlink_id == 0);
    try s2.cursorCopy(s.cursor, .{ .hyperlink = false });
    try testing.expectEqual(@as(usize, 0), page.hyperlink_set.count());
    try testing.expect(s2.cursor.hyperlink_id == 0);
}
test "Screen style basics" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    const page = s.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 0), page.styles.count());
    try s.setAttribute(.{ .bold = {} });
    try testing.expect(s.cursor.style_id != 0);
    try testing.expectEqual(@as(usize, 1), page.styles.count());
    try testing.expect(s.cursor.style.flags.bold);
    try s.setAttribute(.{ .italic = {} });
    try testing.expect(s.cursor.style_id != 0);
    try testing.expectEqual(@as(usize, 1), page.styles.count());
    try testing.expect(s.cursor.style.flags.italic);
}
test "Screen style reset to default" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    const page = s.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 0), page.styles.count());
    try s.setAttribute(.{ .bold = {} });
    try testing.expect(s.cursor.style_id != 0);
    try testing.expectEqual(@as(usize, 1), page.styles.count());
    try s.setAttribute(.{ .reset_bold = {} });
    try testing.expect(s.cursor.style_id == 0);
    try testing.expectEqual(@as(usize, 0), page.styles.count());
}
test "Screen style reset with unset" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    const page = s.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 0), page.styles.count());
    try s.setAttribute(.{ .bold = {} });
    try testing.expect(s.cursor.style_id != 0);
    try testing.expectEqual(@as(usize, 1), page.styles.count());
    try s.setAttribute(.{ .unset = {} });
    try testing.expect(s.cursor.style_id == 0);
    try testing.expectEqual(@as(usize, 0), page.styles.count());
}
test "Screen clearRows active one line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    try s.testWriteString("hello, world");
    s.clearRows(.{ .active = .{} }, null, false);
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("", str);
}
test "Screen clearRows active multi line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    try s.testWriteString("hello\nworld");
    s.clearRows(.{ .active = .{} }, null, false);
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("", str);
}
test "Screen clearRows active styled line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    try s.setAttribute(.{ .bold = {} });
    try s.testWriteString("hello world");
    try s.setAttribute(.{ .unset = {} });
    const page = s.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 1), page.styles.count());
    s.clearRows(.{ .active = .{} }, null, false);
    try testing.expectEqual(@as(usize, 0), page.styles.count());
    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("", str);
}
test "Screen clearCells empty range" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .default);
    defer s.deinit();
    const page = s.cursor.page_pin.node.page();
    const row = s.cursor.page_row;
    const cells = page.getCells(row);
    s.clearCells(page, row, cells[0..0]);
}
test "Screen clearRows uses stored page width" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 1,
        .max_scrollback_bytes = 0,
    });
    defer s.deinit();
    try s.testWriteString("AB");
    const node = s.pages.pages.first.?;
    s.pages.cols = 4;
    s.clearRows(.{ .screen = .{} }, null, false);
    const cells = node.page().getCells(&node.page().rows.ptr(node.page().memory)[0]);
    try testing.expectEqual(@as(usize, 2), cells.len);
    for (cells) |cell| try testing.expect(cell.isEmpty());
}
test "Screen clearRows protected" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    try s.testWriteString("UNPROTECTED");
    s.cursor.protected = true;
    try s.testWriteString("PROTECTED");
    s.cursor.protected = false;
    try s.testWriteString("UNPROTECTED");
    try s.testWriteString("\n");
    s.cursor.protected = true;
    try s.testWriteString("PROTECTED");
    s.cursor.protected = false;
    try s.testWriteString("UNPROTECTED");
    s.cursor.protected = true;
    try s.testWriteString("PROTECTED");
    s.cursor.protected = false;
    s.clearRows(.{ .active = .{} }, null, true);
    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("           PROTECTED\nPROTECTED           PROTECTED", str);
}
test "Screen eraseRows history" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    try s.testWriteString("1\n2\n3\n4\n5\n6");
    {
        const str = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("2\n3\n4\n5\n6", str);
    }
    {
        const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("1\n2\n3\n4\n5\n6", str);
    }
    s.eraseHistory(null);
    {
        const str = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("2\n3\n4\n5\n6", str);
    }
    {
        const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("2\n3\n4\n5\n6", str);
    }
}
test "Screen eraseRows history with more lines" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 1000 });
    defer s.deinit();
    try s.testWriteString("A\nB\nC\n1\n2\n3\n4\n5\n6");
    {
        const str = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("2\n3\n4\n5\n6", str);
    }
    {
        const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("A\nB\nC\n1\n2\n3\n4\n5\n6", str);
    }
    s.eraseHistory(null);
    {
        const str = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("2\n3\n4\n5\n6", str);
    }
    {
        const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("2\n3\n4\n5\n6", str);
    }
}
test "Screen eraseRows active partial" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1\n2\n3");
    {
        const str = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("1\n2\n3", str);
    }
    s.eraseActive(1);
    {
        const str = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("3", str);
    }
    {
        const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("3", str);
    }
}
test "Screen: cursorCellEndOfPrev across mixed-width pages" {
    const testing = std.testing;
    var s = try init(testing.io, testing.allocator, .{
        .cols = 4,
        .rows = 2,
        .max_scrollback_bytes = 0,
    });
    defer s.deinit();
    try s.testWriteString("ABCDE");
    const first = s.pages.pages.first.?;
    try s.pages.split(.{ .node = first, .y = 1 });
    s.cursorReload();
    const second = first.next.?;
    first.page().size.cols = 2;
    try testing.expectEqual(second, s.cursor.page_pin.node);
    const expected = (Pin{ .node = first, .x = 1 }).rowAndCell().cell;
    try testing.expectEqual(expected, s.cursorCellEndOfPrev());
}
test "Screen: cursorDown across pages preserves style" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    const start_page = s.pages.pages.last.?.page();
    const rem = start_page.capacity.rows;
    start_page.pauseIntegrityChecks(true);
    for (0..rem) |_| try s.cursorDownOrScroll();
    start_page.pauseIntegrityChecks(false);
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expect(start_page != page);
    }
    s.cursorUp(1);
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expect(start_page == page);
    }
    try s.setAttribute(.{ .bold = {} });
    {
        const page = s.cursor.page_pin.node.page();
        const styleval = page.styles.get(
            page.memory,
            s.cursor.style_id,
        );
        try testing.expect(styleval.flags.bold);
    }
    s.cursorDown(1);
    {
        const page = s.cursor.page_pin.node.page();
        const styleval = page.styles.get(
            page.memory,
            s.cursor.style_id,
        );
        try testing.expect(styleval.flags.bold);
    }
}
test "Screen: cursorUp across pages preserves style" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    const start_page = s.pages.pages.last.?.page();
    const rem = start_page.capacity.rows;
    start_page.pauseIntegrityChecks(true);
    for (0..rem) |_| try s.cursorDownOrScroll();
    start_page.pauseIntegrityChecks(false);
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expect(start_page != page);
    }
    try s.setAttribute(.{ .bold = {} });
    {
        const page = s.cursor.page_pin.node.page();
        const styleval = page.styles.get(
            page.memory,
            s.cursor.style_id,
        );
        try testing.expect(styleval.flags.bold);
    }
    s.cursorUp(1);
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expect(start_page == page);
        const styleval = page.styles.get(
            page.memory,
            s.cursor.style_id,
        );
        try testing.expect(styleval.flags.bold);
    }
}
test "Screen: cursorAbsolute across pages preserves style" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    const start_page = s.pages.pages.last.?.page();
    const rem = start_page.capacity.rows;
    start_page.pauseIntegrityChecks(true);
    for (0..rem) |_| try s.cursorDownOrScroll();
    start_page.pauseIntegrityChecks(false);
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expect(start_page != page);
    }
    try s.setAttribute(.{ .bold = {} });
    {
        const page = s.cursor.page_pin.node.page();
        const styleval = page.styles.get(
            page.memory,
            s.cursor.style_id,
        );
        try testing.expect(styleval.flags.bold);
    }
    s.cursorAbsolute(1, 1);
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expect(start_page == page);
        const styleval = page.styles.get(
            page.memory,
            s.cursor.style_id,
        );
        try testing.expect(styleval.flags.bold);
    }
}
test "Screen: cursorAbsolute to page with insufficient capacity" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    const start_page = s.pages.pages.last.?.page();
    const rem = start_page.capacity.rows;
    start_page.pauseIntegrityChecks(true);
    for (0..rem) |_| try s.cursorDownOrScroll();
    start_page.pauseIntegrityChecks(false);
    const new_page = s.cursor.page_pin.node.page();
    try testing.expect(start_page != new_page);
    {
        start_page.pauseIntegrityChecks(true);
        defer start_page.pauseIntegrityChecks(false);
        defer start_page.assertIntegrity();
        var n: u24 = 1;
        while (start_page.styles.add(
            start_page.memory,
            .{ .bg_color = .{ .rgb = @bitCast(n) } },
        )) |_| n += 1 else |_| {}
    }
    try s.setAttribute(.{ .bold = {} });
    {
        const styleval = new_page.styles.get(
            new_page.memory,
            s.cursor.style_id,
        );
        try testing.expect(styleval.flags.bold);
    }
    s.cursorAbsolute(1, 1);
    {
        const cur_page = s.cursor.page_pin.node.page();
        try testing.expect(start_page != cur_page);
        try testing.expect(new_page != cur_page);
        const styleval = cur_page.styles.get(
            cur_page.memory,
            s.cursor.style_id,
        );
        try testing.expect(styleval.flags.bold);
    }
    s.cursor.page_pin.node.page().assertIntegrity();
    new_page.assertIntegrity();
}
test "Screen: scrolling" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.setAttribute(.{ .direct_color_bg = .{ .r = 155 } });
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try s.cursorDownScroll();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 2 } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 155,
            .g = 0,
            .b = 0,
        }, cell.content.color_rgb);
    }
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    s.scroll(.{ .active = {} });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
}
test "Screen: scrolling with a single-row screen no scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 1, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1ABCD");
    try s.cursorDownScroll();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
}
test "Screen: scrolling with a single-row screen with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 1, .max_scrollback_bytes = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD");
    try s.cursorDownScroll();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(s.pages.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    s.scroll(.{ .delta_row = -1 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD", contents);
    }
}
test "Screen: scrolling across pages preserves style" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    try s.setAttribute(.{ .bold = {} });
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    const start_page = s.pages.pages.last.?.page();
    const rem = start_page.capacity.rows - start_page.size.rows + 1;
    start_page.pauseIntegrityChecks(true);
    for (0..rem) |_| try s.cursorDownOrScroll();
    start_page.pauseIntegrityChecks(false);
    const page = s.pages.pages.last.?.page();
    try testing.expect(start_page != page);
    const styleval = page.styles.get(
        page.memory,
        s.cursor.style_id,
    );
    try testing.expect(styleval.flags.bold);
}
test "Screen: scroll down from 0" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    s.scroll(.{ .delta_row = -1 });
    try testing.expect(s.pages.viewport == .active);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }
}
test "Screen: scrollback various cases" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try s.cursorDownScroll();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
    s.scroll(.{ .active = {} });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
    s.scroll(.{ .delta_row = -1 });
    try testing.expect(s.pages.viewport != .active);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }
    s.scroll(.{ .delta_row = -1 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }
    s.scroll(.{ .active = {} });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
    s.scroll(.{ .delta_row = 1 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
    s.scroll(.{ .top = {} });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }
    s.clearRows(.{ .active = .{} }, null, false);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD", contents);
    }
    s.scroll(.{ .active = {} });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
}
test "Screen: scrollback with multi-row delta" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 3 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH\n6IJKL");
    s.scroll(.{ .top = {} });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }
    s.scroll(.{ .delta_row = 5 });
    try testing.expect(s.pages.viewport == .active);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\n5EFGH\n6IJKL", contents);
    }
}
test "Screen: scrollback empty" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 50 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    s.scroll(.{ .delta_row = 1 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }
}
test "Screen: scrollback doesn't move viewport if not at bottom" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 3 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH");
    s.scroll(.{ .delta_row = -1 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL\n4ABCD", contents);
    }
    try s.cursorDownScroll();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL\n4ABCD", contents);
    }
    try s.cursorDownScroll();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL\n4ABCD", contents);
    }
}
test "Screen: scrolling moves selection" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        s.pages.pin(.{ .active = .{ .x = s.pages.cols - 1, .y = 1 } }).?,
        false,
    ));
    try s.cursorDownScroll();
    {
        const sel = s.selection.?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = s.pages.cols - 1,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
    s.scroll(.{ .active = {} });
    {
        const sel = s.selection.?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = s.pages.cols - 1,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
    try s.cursorDownScroll();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("3IJKL", contents);
    }
    {
        const sel = s.selection.?;
        try testing.expect(s.pages.pointFromPin(.active, sel.start()) == null);
        try testing.expect(s.pages.pointFromPin(.active, sel.end()) == null);
    }
}
test "Screen: cursorScrollRegionUp simple" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4MNOP\n5QRST");
    s.cursorAbsolute(1, 2);
    try s.cursorScrollRegionUp(2);
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL\n\n4MNOP\n5QRST", contents);
    }
}
test "Screen: cursorScrollRegionUp renews page generation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4MNOP\n5QRST");
    s.cursorAbsolute(0, 2);
    const node = s.cursor.page_pin.node;
    const serial = node.serial;
    try s.cursorScrollRegionUp(2);
    try testing.expect(!s.pages.nodeIsValid(node, serial));
}
test "Screen: cursorScrollRegionUp moves selection" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4MNOP\n5QRST");
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        s.pages.pin(.{ .active = .{ .x = s.pages.cols - 1, .y = 1 } }).?,
        false,
    ));
    s.cursorAbsolute(0, 2);
    try s.cursorScrollRegionUp(2);
    {
        const sel = s.selection.?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = s.pages.cols - 1,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL\n\n4MNOP\n5QRST", contents);
    }
}
test "Screen: cursorScrollRegionUp region spans pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 10 });
    defer s.deinit();
    const first_page_size = s.pages.pages.first.?.capacity().rows;
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 3) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);
    try s.testWriteString("1A\n2B\n3C\n4D\n5E");
    s.cursorAbsolute(0, 3);
    try s.setAttribute(.{ .bold = {} });
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.last.?);
    try testing.expectEqual(@as(usize, 0), s.cursor.page_pin.y);
    try s.cursorScrollRegionUp(2);
    try testing.expectEqual(@as(size.CellCountInt, 0), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 3), s.cursor.y);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1A\n3C\n4D\n\n5E", contents);
    }
    try s.testWriteString("X");
    {
        const page = s.cursor.page_pin.node.page();
        const styles = page.styles.count();
        try testing.expectEqual(@as(usize, 1), styles);
    }
}
test "Screen: cursorScrollRegionUp region spans pages with background SGR" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 10 });
    defer s.deinit();
    const first_page_size = s.pages.pages.first.?.capacity().rows;
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 3) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);
    try s.testWriteString("1A\n2B\n3C\n4D\n5E");
    s.cursorAbsolute(0, 3);
    try s.setAttribute(.{ .direct_color_bg = .{ .r = 0xFF, .g = 0, .b = 0 } });
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.last.?);
    try testing.expectEqual(@as(usize, 0), s.cursor.page_pin.y);
    try s.cursorScrollRegionUp(2);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1A\n3C\n4D\n\n5E", contents);
    }
    for (0..s.pages.cols) |x| {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 3,
        } }).?;
        try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 0xFF,
            .g = 0,
            .b = 0,
        }, list_cell.cell.content.color_rgb);
    }
}
test "Screen: cursorScrollRegionUp with styled erased row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.setAttribute(.{ .bold = {} });
    try s.testWriteString("1ABCD");
    try s.setAttribute(.{ .unset = {} });
    try s.testWriteString("\n2EFGH\n3IJKL");
    s.cursorAbsolute(0, 2);
    try s.cursorScrollRegionUp(2);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
    const page = s.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 0), page.styles.count());
}
test "Screen: scrolling moves viewport" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n");
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    s.scroll(.{ .delta_row = -2 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL\n1ABCD", contents);
    }
    {
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, s.pages.getTopLeft(.viewport)));
    }
}
test "Screen: scrolling when viewport is pruned" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 215, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n");
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    s.scroll(.{ .delta_row = -2 });
    try s.testWriteString("\n");
    for (0..1000) |_| try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n");
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    {
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, s.pages.getTopLeft(.viewport)));
    }
}
test "Screen: scroll and clear full screen" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }
    try s.scrollClear();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }
}
test "Screen: scroll and clear partial screen" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH", contents);
    }
    try s.scrollClear();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH", contents);
    }
}
test "Screen: scroll and clear empty screen" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    try s.scrollClear();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
}
test "Screen: scroll and clear ignore blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 10 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH");
    try s.scrollClear();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
    s.cursorAbsolute(0, 0);
    try s.testWriteString("3ABCD\n");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("3ABCD", contents);
    }
    try s.scrollClear();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
    s.cursorAbsolute(0, 0);
    try s.testWriteString("X");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3ABCD\nX", contents);
    }
}
test "Screen: scroll above same page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 10 });
    defer s.deinit();
    try s.setAttribute(.{ .direct_color_bg = .{ .r = 155 } });
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    s.cursorAbsolute(0, 1);
    s.pages.clearDirty();
    const node = s.cursor.page_pin.node;
    const serial = node.serial;
    try s.cursorScrollAbove();
    try testing.expect(!s.pages.nodeIsValid(node, serial));
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n\n3IJKL", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 155,
            .g = 0,
            .b = 0,
        }, cell.content.color_rgb);
    }
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
}
test "Screen: scroll above same page but cursor on previous page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 10 });
    defer s.deinit();
    const first_page_size = s.pages.pages.first.?.capacity().rows;
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 3) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);
    try s.setAttribute(.{ .direct_color_bg = .{ .r = 155 } });
    try s.testWriteString("1A\n2B\n3C\n4D\n5E");
    s.cursorAbsolute(0, 1);
    s.pages.clearDirty();
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.first.?);
    try testing.expect(s.pages.pages.first.?.next != null);
    const first_node = s.pages.pages.first.?;
    const second_node = first_node.next.?;
    const first_serial = first_node.serial;
    const second_serial = second_node.serial;
    try s.cursorScrollAbove();
    try testing.expect(!s.pages.nodeIsValid(first_node, first_serial));
    try testing.expect(!s.pages.nodeIsValid(second_node, second_serial));
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2B\n\n3C\n4D\n5E", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 155,
            .g = 0,
            .b = 0,
        }, cell.content.color_rgb);
    }
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 4 } }));
}
test "Screen: scroll above same page but cursor on previous page last row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 10 });
    defer s.deinit();
    const first_page_size = s.pages.pages.first.?.capacity().rows;
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 2) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);
    try s.setAttribute(.{ .direct_color_bg = .{ .r = 155 } });
    try s.testWriteString("1A\n2B\n3C\n4D\n5E");
    s.cursorAbsolute(0, 1);
    s.pages.clearDirty();
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.first.?);
    try testing.expect(s.pages.pages.first.?.next != null);
    try s.cursorScrollAbove();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2B\n\n3C\n4D\n5E", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 155,
            .g = 0,
            .b = 0,
        }, cell.content.color_rgb);
    }
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 4 } }));
    try s.setAttribute(.{ .reset_bg = {} });
    s.pages.pages.first.?.page().assertIntegrity();
    s.pages.pages.last.?.page().assertIntegrity();
}
test "Screen: scroll above creates new page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 10 });
    defer s.deinit();
    const first_page_size = s.pages.pages.first.?.capacity().rows;
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 3) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);
    try s.setAttribute(.{ .direct_color_bg = .{ .r = 155 } });
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    s.cursorAbsolute(0, 1);
    s.pages.clearDirty();
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.first.?);
    const node = s.pages.pages.first.?;
    const serial = node.serial;
    try s.cursorScrollAbove();
    try testing.expect(!s.pages.nodeIsValid(node, serial));
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n\n3IJKL", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 155,
            .g = 0,
            .b = 0,
        }, cell.content.color_rgb);
    }
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
}
test "Screen: scroll above with cursor on non-final row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 4, .max_scrollback_bytes = 10 });
    defer s.deinit();
    const first_page_size = s.pages.pages.first.?.capacity().rows;
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 3) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);
    try s.setAttribute(.{ .direct_color_bg = .{ .r = 155 } });
    try s.testWriteString("1AB\n2BC\n3DE\n4FG");
    s.cursorAbsolute(0, 1);
    s.pages.clearDirty();
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.first.?);
    try s.cursorScrollAbove();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2BC\n\n3DE\n4FG", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 155,
            .g = 0,
            .b = 0,
        }, cell.content.color_rgb);
    }
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
}
test "Screen: scroll above no scrollback bottom of page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const first_page_size = s.pages.pages.first.?.capacity().rows;
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 3) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);
    try s.setAttribute(.{ .direct_color_bg = .{ .r = 155 } });
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    s.cursorAbsolute(0, 1);
    s.pages.clearDirty();
    try s.cursorScrollAbove();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n\n3IJKL", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 155,
            .g = 0,
            .b = 0,
        }, cell.content.color_rgb);
    }
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
}
test "Screen: scroll above hyperlink-dense row to fresh page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 10000 });
    defer s.deinit();
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try testing.expectEqual(
        s.pages.pages.first.?.capacity().rows,
        s.pages.pages.first.?.page().size.rows,
    );
    try testing.expectEqual(s.pages.rows - 1, s.cursor.y);
    for (0..s.pages.cols) |i| {
        var buf: [64]u8 = undefined;
        const uri = try std.fmt.bufPrint(&buf, "http://example.com/{d}", .{i});
        try s.startHyperlink(uri, null);
        try s.testWriteString("A");
        s.endHyperlink();
    }
    try testing.expectEqual(
        @as(usize, s.pages.cols),
        s.cursor.page_pin.node.page().hyperlink_set.count(),
    );
    s.cursorAbsolute(0, 1);
    try s.cursorScrollAbove();
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    var node_: ?*PageList.List.Node = s.pages.pages.first;
    while (node_) |node| : (node_ = node.next) {
        const page: *Page = node.page();
        page.assertIntegrity();
        for (0..page.size.rows) |y| {
            const row = page.getRow(y);
            if (!row.hyperlink) continue;
            for (page.getCells(row)) |*cell| {
                if (!cell.hyperlink) continue;
                try testing.expect(page.lookupHyperlink(cell) != null);
            }
        }
    }
    {
        const last_page: *Page = s.pages.pages.last.?.page();
        try testing.expectEqual(
            @as(usize, s.pages.cols),
            last_page.hyperlink_set.count(),
        );
    }
    for (0..s.pages.cols) |x| {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 4,
        } }).?;
        try testing.expect(list_cell.cell.hyperlink);
        const page: *Page = list_cell.node.page();
        const id = page.lookupHyperlink(list_cell.cell).?;
        const link = page.hyperlink_set.get(page.memory, id);
        var buf: [64]u8 = undefined;
        const expected = try std.fmt.bufPrint(&buf, "http://example.com/{d}", .{x});
        try testing.expectEqualStrings(expected, link.uri.slice(page.memory));
    }
}
test "Screen: scroll above hyperlink-dense row to existing page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 10000 });
    defer s.deinit();
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);
    try testing.expectEqual(s.pages.rows - 1, s.cursor.y);
    for (0..s.pages.cols) |i| {
        var buf: [64]u8 = undefined;
        const uri = try std.fmt.bufPrint(&buf, "http://example.com/{d}", .{i});
        try s.startHyperlink(uri, null);
        try s.testWriteString("A");
        s.endHyperlink();
    }
    try s.testWriteString("\n\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.last.?);
    s.cursorAbsolute(0, 0);
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.first.?);
    try s.cursorScrollAbove();
    var node_: ?*PageList.List.Node = s.pages.pages.first;
    while (node_) |node| : (node_ = node.next) {
        const page: *Page = node.page();
        page.assertIntegrity();
        for (0..page.size.rows) |y| {
            const row = page.getRow(y);
            if (!row.hyperlink) continue;
            for (page.getCells(row)) |*cell| {
                if (!cell.hyperlink) continue;
                try testing.expect(page.lookupHyperlink(cell) != null);
            }
        }
    }
    {
        const last_page: *Page = s.pages.pages.last.?.page();
        try testing.expectEqual(
            @as(usize, s.pages.cols),
            last_page.hyperlink_set.count(),
        );
    }
}
test "Screen: clone" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 10 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH", contents);
    }
    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 1), s.cursor.y);
    var s2 = try s.clone(io, alloc, .{ .active = .{} }, null);
    defer s2.deinit();
    {
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH", contents);
    }
    try testing.expectEqual(@as(usize, 5), s2.cursor.x);
    try testing.expectEqual(@as(usize, 1), s2.cursor.y);
    try s.testWriteString("\n34567");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n34567", contents);
    }
    {
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH", contents);
    }
    try testing.expectEqual(@as(usize, 5), s2.cursor.x);
    try testing.expectEqual(@as(usize, 1), s2.cursor.y);
}
test "Screen: clone partial" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 10 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH", contents);
    }
    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 1), s.cursor.y);
    var s2 = try s.clone(io, alloc, .{ .active = .{ .y = 1 } }, null);
    defer s2.deinit();
    {
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH", contents);
    }
    try testing.expectEqual(@as(usize, 5), s2.cursor.x);
    try testing.expectEqual(@as(usize, 0), s2.cursor.y);
}
test "Screen: clone partial cursor out of bounds" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 10 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH", contents);
    }
    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 1), s.cursor.y);
    var s2 = try s.clone(
        io,
        alloc,
        .{ .active = .{ .y = 0 } },
        .{ .active = .{ .y = 0 } },
    );
    defer s2.deinit();
    {
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD", contents);
    }
    try testing.expectEqual(@as(usize, 0), s2.cursor.x);
    try testing.expectEqual(@as(usize, 0), s2.cursor.y);
}
test "Screen: clone contains full selection" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        s.pages.pin(.{ .active = .{ .x = s.pages.cols - 1, .y = 1 } }).?,
        false,
    ));
    var s2 = try s.clone(
        io,
        alloc,
        .{ .active = .{} },
        null,
    );
    defer s2.deinit();
    {
        const sel = s2.selection.?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 1,
        } }, s2.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = s2.pages.cols - 1,
            .y = 1,
        } }, s2.pages.pointFromPin(.active, sel.end()).?);
    }
}
test "Screen: clone contains none of selection" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
        s.pages.pin(.{ .active = .{ .x = s.pages.cols - 1, .y = 0 } }).?,
        false,
    ));
    var s2 = try s.clone(
        io,
        alloc,
        .{ .active = .{ .y = 1 } },
        null,
    );
    defer s2.deinit();
    try testing.expect(s2.selection == null);
}
test "Screen: clone contains selection start cutoff" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
        s.pages.pin(.{ .active = .{ .x = s.pages.cols - 1, .y = 1 } }).?,
        false,
    ));
    var s2 = try s.clone(
        io,
        alloc,
        .{ .active = .{ .y = 1 } },
        null,
    );
    defer s2.deinit();
    {
        const sel = s2.selection.?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s2.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = s2.pages.cols - 1,
            .y = 0,
        } }, s2.pages.pointFromPin(.active, sel.end()).?);
    }
}
test "Screen: clone contains selection end cutoff" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        s.pages.pin(.{ .active = .{ .x = 2, .y = 2 } }).?,
        false,
    ));
    var s2 = try s.clone(
        io,
        alloc,
        .{ .active = .{ .y = 0 } },
        .{ .active = .{ .y = 1 } },
    );
    defer s2.deinit();
    {
        const sel = s2.selection.?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 1,
        } }, s2.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = s2.pages.cols - 1,
            .y = 2,
        } }, s2.pages.pointFromPin(.active, sel.end()).?);
    }
}
test "Screen: clone contains selection end cutoff reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 2, .y = 2 } }).?,
        s.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        false,
    ));
    var s2 = try s.clone(
        io,
        alloc,
        .{ .active = .{ .y = 0 } },
        .{ .active = .{ .y = 1 } },
    );
    defer s2.deinit();
    {
        const sel = s2.selection.?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 1,
        } }, s2.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = s2.pages.cols - 1,
            .y = 2,
        } }, s2.pages.pointFromPin(.active, sel.end()).?);
    }
}
test "Screen: clone contains subset of selection" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 4, .max_scrollback_bytes = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD");
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
        s.pages.pin(.{ .active = .{ .x = 0, .y = 3 } }).?,
        false,
    ));
    var s2 = try s.clone(
        io,
        alloc,
        .{ .active = .{ .y = 1 } },
        .{ .active = .{ .y = 2 } },
    );
    defer s2.deinit();
    {
        const sel = s2.selection.?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s2.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = s2.pages.cols - 1,
            .y = 3,
        } }, s2.pages.pointFromPin(.active, sel.end()).?);
    }
}
test "Screen: clone clamps clipped selections to mixed-width pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 4, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const first = s.pages.pages.first.?;
    try s.pages.split(.{ .node = first, .y = 2 });
    try s.pages.split(.{ .node = first, .y = 1 });
    const middle = first.next.?;
    const last = middle.next.?;
    middle.page().size.cols = 2;
    try s.select(Selection.init(
        .{ .node = first },
        .{ .node = last, .x = 3 },
        false,
    ));
    var linear = try s.clone(
        io,
        alloc,
        .{ .screen = .{} },
        .{ .screen = .{ .y = 1 } },
    );
    defer linear.deinit();
    const linear_end = linear.selection.?.end();
    _ = linear_end.rowAndCell();
    try testing.expectEqual(@as(size.CellCountInt, 1), linear_end.x);
    try s.select(Selection.init(
        .{ .node = first, .x = 3 },
        .{ .node = last, .x = 3 },
        true,
    ));
    var rectangle = try s.clone(
        io,
        alloc,
        .{ .screen = .{ .y = 1 } },
        null,
    );
    defer rectangle.deinit();
    const rectangle_start = rectangle.selection.?.start();
    _ = rectangle_start.rowAndCell();
    try testing.expectEqual(@as(size.CellCountInt, 1), rectangle_start.x);
}
test "Screen: clone contains subset of rectangle selection" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 4, .max_scrollback_bytes = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD");
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 1, .y = 0 } }).?,
        s.pages.pin(.{ .active = .{ .x = 3, .y = 3 } }).?,
        true,
    ));
    var s2 = try s.clone(
        io,
        alloc,
        .{ .active = .{ .y = 1 } },
        .{ .active = .{ .y = 2 } },
    );
    defer s2.deinit();
    {
        const sel = s2.selection.?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 0,
        } }, s2.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 3,
            .y = 3,
        } }, s2.pages.pointFromPin(.active, sel.end()).?);
    }
}
test "Screen: clone basic" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    {
        var s2 = try s.clone(
            io,
            alloc,
            .{ .active = .{ .y = 1 } },
            .{ .active = .{ .y = 1 } },
        );
        defer s2.deinit();
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH", contents);
    }
    {
        var s2 = try s.clone(
            io,
            alloc,
            .{ .active = .{ .y = 1 } },
            .{ .active = .{ .y = 2 } },
        );
        defer s2.deinit();
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
}
test "Screen: clone empty viewport" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    {
        var s2 = try s.clone(
            io,
            alloc,
            .{ .viewport = .{ .y = 0 } },
            .{ .viewport = .{ .y = 0 } },
        );
        defer s2.deinit();
        const contents = try s2.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
}
test "Screen: clone one line viewport" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1ABC");
    {
        var s2 = try s.clone(
            io,
            alloc,
            .{ .viewport = .{ .y = 0 } },
            .{ .viewport = .{ .y = 0 } },
        );
        defer s2.deinit();
        const contents = try s2.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABC", contents);
    }
}
test "Screen: clone empty active" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    {
        var s2 = try s.clone(
            io,
            alloc,
            .{ .active = .{ .y = 0 } },
            .{ .active = .{ .y = 0 } },
        );
        defer s2.deinit();
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
}
test "Screen: clone one line active with extra space" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1ABC");
    {
        var s2 = try s.clone(
            io,
            alloc,
            .{ .active = .{ .y = 0 } },
            null,
        );
        defer s2.deinit();
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABC", contents);
    }
}
test "Screen: clear history with no history" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 3 });
    defer s.deinit();
    try s.testWriteString("4ABCD\n5EFGH\n6IJKL");
    try testing.expect(s.pages.viewport == .active);
    s.eraseHistory(null);
    try testing.expect(s.pages.viewport == .active);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\n5EFGH\n6IJKL", contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\n5EFGH\n6IJKL", contents);
    }
}
test "Screen: clear history" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 3 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH\n6IJKL");
    try testing.expect(s.pages.viewport == .active);
    s.scroll(.{ .top = {} });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }
    s.eraseHistory(null);
    try testing.expect(s.pages.viewport == .active);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\n5EFGH\n6IJKL", contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\n5EFGH\n6IJKL", contents);
    }
}
test "Screen: clear above cursor" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 3 });
    defer s.deinit();
    try s.testWriteString("4ABCD\n5EFGH\n6IJKL");
    s.clearRows(
        .{ .active = .{ .y = 0 } },
        .{ .active = .{ .y = s.cursor.y - 1 } },
        false,
    );
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("\n\n6IJKL", contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("\n\n6IJKL", contents);
    }
    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 2), s.cursor.y);
}
test "Screen: clear above cursor with history" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 3 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n");
    try s.testWriteString("4ABCD\n5EFGH\n6IJKL");
    s.clearRows(
        .{ .active = .{ .y = 0 } },
        .{ .active = .{ .y = s.cursor.y - 1 } },
        false,
    );
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("\n\n6IJKL", contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL\n\n\n6IJKL", contents);
    }
    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 2), s.cursor.y);
}
test "Screen: resize (no reflow) more rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 10, .rows = 10, .reflow = false });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}
test "Screen: resize (no reflow) less rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try testing.expectEqual(5, s.cursor.x);
    try testing.expectEqual(2, s.cursor.y);
    try s.resize(.{ .cols = 10, .rows = 2, .reflow = false });
    try testing.expectEqual(5, s.cursor.x);
    try testing.expectEqual(1, s.cursor.y);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
}
test "Screen: resize (no reflow) less rows trims blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD";
    try s.testWriteString(str);
    for (1..s.pages.rows) |y| {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = 0,
            .y = @intCast(y),
        } }).?;
        list_cell.cell.* = .{
            .content_tag = .bg_color_rgb,
            .content = .{ .color_rgb = .{ .r = 0xFF, .g = 0, .b = 0 } },
        };
    }
    const cursor = s.cursor;
    try s.resize(.{ .cols = 6, .rows = 2, .reflow = false });
    try testing.expectEqual(cursor.x, s.cursor.x);
    try testing.expectEqual(cursor.y, s.cursor.y);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD", contents);
    }
}
test "Screen: resize (no reflow) more rows trims blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD";
    try s.testWriteString(str);
    for (1..s.pages.rows) |y| {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = 0,
            .y = @intCast(y),
        } }).?;
        list_cell.cell.* = .{
            .content_tag = .bg_color_rgb,
            .content = .{ .color_rgb = .{ .r = 0xFF, .g = 0, .b = 0 } },
        };
    }
    const cursor = s.cursor;
    try s.resize(.{ .cols = 10, .rows = 7, .reflow = false });
    try testing.expectEqual(cursor.x, s.cursor.x);
    try testing.expectEqual(cursor.y, s.cursor.y);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD", contents);
    }
}
test "Screen: resize (no reflow) more cols" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 20, .rows = 3, .reflow = false });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}
test "Screen: resize (no reflow) less cols" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 4, .rows = 3, .reflow = false });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1ABC\n2EFG\n3IJK";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: resize (no reflow) more rows with scrollback cursor end" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 7, .rows = 3, .max_scrollback_bytes = 2 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 7, .rows = 10, .reflow = false });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}
test "Screen: resize (no reflow) more rows no scrollback pull" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 7, .rows = 3, .max_scrollback_bytes = 2 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);
    try s.resize(.{
        .cols = 7,
        .rows = 10,
        .reflow = false,
        .pull_scrollback = false,
    });
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("3IJKL\n4ABCD\n5EFGH", contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}
test "Screen: resize more cols no scrollback pull" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 2 });
    defer s.deinit();
    try s.testWriteString("1AAAA\n2BBBB\n3CCCCDD\n4E");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("3CCCC\nDD\n4E", contents);
    }
    try s.resize(.{ .cols = 10, .rows = 3, .pull_scrollback = false });
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.y);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("3CCCCDD\n4E", contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1AAAA\n2BBBB\n3CCCCDD\n4E", contents);
    }
}
test "Screen: resize more cols no scrollback pull wrap straddles scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 2 });
    defer s.deinit();
    try s.testWriteString("1AAAA\n2BBBBXX\n3C\n4D");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("XX\n3C\n4D", contents);
    }
    try s.resize(.{ .cols = 10, .rows = 3, .pull_scrollback = false });
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2BBBBXX\n3C\n4D", contents);
    }
}
test "Screen: resize more cols and rows no scrollback pull" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 2 });
    defer s.deinit();
    try s.testWriteString("1AAAA\n2BBBB\n3CCCCDD\n4E");
    try s.resize(.{ .cols = 10, .rows = 5, .pull_scrollback = false });
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.y);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("3CCCCDD\n4E", contents);
    }
}
test "Screen: resize less cols no scrollback pull" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 2 });
    defer s.deinit();
    try s.testWriteString("0Z\n1AAAA\n2BBBBXX\n3C");
    try s.resize(.{ .cols = 5, .rows = 3, .pull_scrollback = false });
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2BBBB\nXX\n3C", contents);
    }
}
test "Screen: resize (no reflow) less rows with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 7, .rows = 3, .max_scrollback_bytes = 2 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 7, .rows = 2, .reflow = false });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: resize (no reflow) less rows with empty trailing" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    const str = "1\n2\n3\n4\n5\n6\n7\n8";
    try s.testWriteString(str);
    try s.scrollClear();
    s.cursorAbsolute(0, 0);
    try s.testWriteString("A\nB");
    const cursor = s.cursor;
    try s.resize(.{ .cols = 5, .rows = 2, .reflow = false });
    try testing.expectEqual(cursor.x, s.cursor.x);
    try testing.expectEqual(cursor.y, s.cursor.y);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("A\nB", contents);
    }
}
test "Screen: resize (no reflow) more rows with soft wrapping" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 2, .rows = 3, .max_scrollback_bytes = 3 });
    defer s.deinit();
    const str = "1A2B\n3C4E\n5F6G";
    try s.testWriteString(str);
    for (0..6) |y| {
        const list_cell = s.pages.getCell(.{ .screen = .{
            .x = 0,
            .y = @intCast(y),
        } }).?;
        const row = list_cell.row;
        const wrapped = (y % 2 == 0);
        try testing.expectEqual(wrapped, row.wrap);
    }
    try s.resize(.{ .cols = 2, .rows = 10, .reflow = false });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1A\n2B\n3C\n4E\n5F\n6G";
        try testing.expectEqualStrings(expected, contents);
    }
    for (0..6) |y| {
        const list_cell = s.pages.getCell(.{ .screen = .{
            .x = 0,
            .y = @intCast(y),
        } }).?;
        const row = list_cell.row;
        const wrapped = (y % 2 == 0);
        try testing.expectEqual(wrapped, row.wrap);
    }
}
test "Screen: resize more rows no scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    const cursor = s.cursor;
    try s.resize(.{ .cols = 5, .rows = 10 });
    try testing.expectEqual(cursor.x, s.cursor.x);
    try testing.expectEqual(cursor.y, s.cursor.y);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}
test "Screen: resize more rows with empty scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 10 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    const cursor = s.cursor;
    try s.resize(.{ .cols = 5, .rows = 10 });
    try testing.expectEqual(cursor.x, s.cursor.x);
    try testing.expectEqual(cursor.y, s.cursor.y);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}
test "Screen: resize more rows with populated scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
    s.cursorAbsolute(0, 1);
    s.cursor.pending_wrap = false;
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '4'), list_cell.cell.content.codepoint.data);
    }
    try s.resize(.{ .cols = 5, .rows = 10 });
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '4'), list_cell.cell.content.codepoint.data);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: resize more cols no reflow" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    const cursor = s.cursor;
    try s.resize(.{ .cols = 10, .rows = 3 });
    try testing.expect(!s.cursor.pending_wrap);
    try testing.expectEqual(cursor.x + 1, s.cursor.x);
    try testing.expectEqual(cursor.y, s.cursor.y);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}
test "Screen: resize more cols perfect split" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD2EFGH3IJKL";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 10, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD2EFGH\n3IJKL", contents);
    }
}
test "Screen: resize (no reflow) more cols with scrollback scrolled up" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    const str = "1\n2\n3\n4\n5\n6\n7\n8";
    try s.testWriteString(str);
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);
    s.scroll(.{ .delta_row = -4 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2\n3\n4", contents);
    }
    try s.resize(.{ .cols = 8, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);
}
test "Screen: resize (no reflow) less cols with scrollback scrolled up" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    const str = "1\n2\n3\n4\n5\n6\n7\n8";
    try s.testWriteString(str);
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);
    s.scroll(.{ .delta_row = -4 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2\n3\n4", contents);
    }
    try s.resize(.{ .cols = 4, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("6\n7\n8", contents);
    }
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);
}
test "Screen: resize more cols no reflow preserves semantic prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("1ABCD\n");
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("2EFGH");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("\n3IJKL");
    try s.resize(.{ .cols = 10, .rows = 3, .reflow = false });
    const expected = "1ABCD\n2EFGH\n3IJKL";
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(list_cell.row.semantic_prompt == .none);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?;
        try testing.expect(list_cell.row.semantic_prompt == .prompt);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 2 } }).?;
        try testing.expect(list_cell.row.semantic_prompt == .none);
    }
}
test "Screen: resize more cols with reflow that fits full width" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD2EFGH\n3IJKL";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
    s.cursorAbsolute(0, 1);
    s.cursor.pending_wrap = false;
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '2'), list_cell.cell.content.codepoint.data);
    }
    try s.resize(.{ .cols = 10, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 0), s.cursor.y);
}
test "Screen: resize more cols with reflow that ends in newline" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 6, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD2EFGH\n3IJKL";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1ABCD2\nEFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
    s.cursorAbsolute(0, 2);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '3'), list_cell.cell.content.codepoint.data);
    }
    try s.resize(.{ .cols = 10, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '3'), list_cell.cell.content.codepoint.data);
    }
}
test "Screen: resize more cols with reflow that forces more wrapping" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD2EFGH\n3IJKL";
    try s.testWriteString(str);
    s.cursorAbsolute(0, 1);
    s.cursor.pending_wrap = false;
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '2'), list_cell.cell.content.codepoint.data);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
    try s.resize(.{ .cols = 7, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1ABCD2E\nFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
    try testing.expectEqual(@as(size.CellCountInt, 5), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 0), s.cursor.y);
}
test "Screen: resize more cols with reflow that unwraps multiple times" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD2EFGH3IJKL";
    try s.testWriteString(str);
    s.cursorAbsolute(0, 2);
    s.cursor.pending_wrap = false;
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '3'), list_cell.cell.content.codepoint.data);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
    try s.resize(.{ .cols = 15, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1ABCD2EFGH3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
    try testing.expectEqual(@as(size.CellCountInt, 10), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 0), s.cursor.y);
}
test "Screen: resize more cols with populated scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD5EFGH";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
    s.cursorAbsolute(0, 2);
    s.cursor.pending_wrap = false;
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '5'), list_cell.cell.content.codepoint.data);
    }
    try s.resize(.{ .cols = 10, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJKL\n4ABCD5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '5'), list_cell.cell.content.codepoint.data);
    }
}
test "Screen: resize more cols bounded scrollback keeps viewport valid" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{
        .cols = 2,
        .rows = 10,
        .max_scrollback_bytes = 10_000,
    });
    defer s.deinit();
    for (0..30) |_| _ = try s.pages.grow();
    s.cursorReload();
    try testing.expectEqual(@as(usize, 40), s.pages.scrollbar().total);
    var it = s.pages.pageIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |chunk| {
        const page = chunk.node.page();
        for (chunk.start..chunk.end) |y| {
            const rac = page.getRowAndCell(0, y);
            if (y % 2 == 0) {
                rac.row.wrap = true;
            } else {
                rac.row.wrap_continuation = true;
            }
            for (0..s.pages.cols) |x| {
                page.getRowAndCell(x, y).cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = @bitCast(@as(u24, 'A')) },
                };
            }
        }
    }
    s.pages.scroll(.{ .pin = s.pages.pin(.{ .screen = .{ .y = 28 } }).? });
    try testing.expect(s.pages.viewport == .pin);
    try testing.expect(s.pages.getBottomRight(.viewport) != null);
    try s.resize(.{ .cols = 4, .rows = s.pages.rows, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.pages.cols);
    try testing.expect(s.pages.scrollbar().total < 40);
    try testing.expect(s.pages.viewport == .active);
    try testing.expect(s.pages.getBottomRight(.viewport) != null);
}
test "Screen: resize more cols with reflow" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 2, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    const str = "1ABC\n2DEF\n3ABC\n4DEF";
    try s.testWriteString(str);
    s.cursorAbsolute(0, 2);
    s.cursor.pending_wrap = false;
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u32, 'E'), list_cell.cell.content.codepoint.data);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "BC\n4D\nEF";
        try testing.expectEqualStrings(expected, contents);
    }
    try s.resize(.{ .cols = 7, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "1ABC\n2DEF\n3ABC\n4DEF";
        try testing.expectEqualStrings(expected, contents);
    }
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);
}
test "Screen: resize errors preserve state" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    for (std.meta.tags(resize_tw.FailPoint)) |tag| {
        const tw = resize_tw;
        defer tw.end(.reset) catch unreachable;
        var s = try init(io, alloc, .{
            .cols = 10,
            .rows = 3,
            .max_scrollback_bytes = 0,
        });
        defer s.deinit();
        s.cursorSetSemanticContent(.{ .prompt = .initial });
        try s.testWriteString("> ");
        s.cursorSetSemanticContent(.{ .input = .clear_explicit });
        try s.testWriteString("echo");
        try s.setAttribute(.{ .bold = {} });
        try s.startHyperlink("https://example.com", "resize");
        s.saved_cursor = .{
            .x = 1,
            .y = 0,
            .style = s.cursor.style,
            .protected = s.cursor.protected,
            .pending_wrap = s.cursor.pending_wrap,
            .origin = false,
            .charset = s.charset,
        };
        if (comptime build_options.kitty_graphics) {
            s.kitty_images.dirty = false;
        }
        try testing.expectEqual(s.pages.pages.first, s.pages.pages.last);
        const before = s;
        const before_viewport_pin = s.pages.viewport_pin.*;
        const before_tracked_pins = s.pages.countTrackedPins();
        const before_page = try alloc.dupe(
            u8,
            s.pages.pages.first.?.page().memory,
        );
        defer alloc.free(before_page);
        tw.errorAlways(tag, error.OutOfMemory);
        try testing.expectError(error.OutOfMemory, s.resize(.{
            .cols = 20,
            .rows = 4,
            .prompt_redraw = .true,
        }));
        try testing.expect(std.meta.eql(before.cursor, s.cursor));
        try testing.expect(std.meta.eql(before.saved_cursor, s.saved_cursor));
        try testing.expect(std.meta.eql(before.selection, s.selection));
        try testing.expect(std.meta.eql(before.charset, s.charset));
        try testing.expectEqual(before.protected_mode, s.protected_mode);
        try testing.expect(std.meta.eql(before.kitty_keyboard, s.kitty_keyboard));
        try testing.expect(std.meta.eql(before.semantic_prompt, s.semantic_prompt));
        try testing.expectEqual(before.dirty, s.dirty);
        try testing.expectEqual(before.pages.pages.first, s.pages.pages.first);
        try testing.expectEqual(before.pages.pages.last, s.pages.pages.last);
        try testing.expectEqual(before.pages.cols, s.pages.cols);
        try testing.expectEqual(before.pages.rows, s.pages.rows);
        try testing.expectEqual(before.pages.total_rows, s.pages.total_rows);
        try testing.expectEqual(before.pages.viewport, s.pages.viewport);
        try testing.expectEqual(before_viewport_pin, s.pages.viewport_pin.*);
        try testing.expectEqual(before_tracked_pins, s.pages.countTrackedPins());
        if (std.valgrind.runningOnValgrind() > 0) {
            std.valgrind.memcheck.makeMemDefined(before_page);
            std.valgrind.memcheck.makeMemDefined(
                s.pages.pages.first.?.page().memory,
            );
        }
        try testing.expectEqualSlices(
            u8,
            before_page,
            s.pages.pages.first.?.page().memory,
        );
        if (comptime build_options.kitty_graphics) {
            try testing.expectEqual(
                before.kitty_images.dirty,
                s.kitty_images.dirty,
            );
        }
    }
}
test "Screen: resize cursor references when node survives" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{
        .cols = 5,
        .rows = 3,
        .max_scrollback_bytes = 1000,
    });
    defer s.deinit();
    try s.setAttribute(.bold);
    try s.startHyperlink("https://example.com/", "resize");
    try s.testWriteString("abc");
    const original_node = s.cursor.page_pin.node;
    const original_serial = original_node.serial;
    {
        const page = original_node.page();
        try testing.expectEqual(
            4,
            page.styles.refCount(page.memory, s.cursor.style_id),
        );
        try testing.expectEqual(
            4,
            page.hyperlink_set.refCount(page.memory, s.cursor.hyperlink_id),
        );
    }
    try s.resize(.{ .cols = 5, .rows = 4 });
    try testing.expectEqual(original_node, s.cursor.page_pin.node);
    try testing.expectEqual(original_serial, s.cursor.page_pin.node.serial);
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expectEqual(
            4,
            page.styles.refCount(page.memory, s.cursor.style_id),
        );
        try testing.expectEqual(
            4,
            page.hyperlink_set.refCount(page.memory, s.cursor.hyperlink_id),
        );
    }
}
test "Screen: resize cursor references when node is replaced" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{
        .cols = 5,
        .rows = 3,
        .max_scrollback_bytes = 1000,
    });
    defer s.deinit();
    try s.setAttribute(.bold);
    try s.startHyperlink("https://example.com/", "resize");
    try s.testWriteString("abc");
    const original_node = s.cursor.page_pin.node;
    const original_serial = original_node.serial;
    {
        const page = original_node.page();
        try testing.expectEqual(
            4,
            page.styles.refCount(page.memory, s.cursor.style_id),
        );
        try testing.expectEqual(
            4,
            page.hyperlink_set.refCount(page.memory, s.cursor.hyperlink_id),
        );
    }
    try s.resize(.{ .cols = 10, .rows = 3 });
    try testing.expect(
        s.cursor.page_pin.node != original_node or
            s.cursor.page_pin.node.serial != original_serial,
    );
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expectEqual(
            4,
            page.styles.refCount(page.memory, s.cursor.style_id),
        );
        try testing.expectEqual(
            4,
            page.hyperlink_set.refCount(page.memory, s.cursor.hyperlink_id),
        );
    }
}
test "Screen: resize more rows and cols with wrapping" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 2, .rows = 4, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1A2B\n3C4D";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1A\n2B\n3C\n4D";
        try testing.expectEqualStrings(expected, contents);
    }
    try s.resize(.{ .cols = 5, .rows = 10 });
    try testing.expect(!s.cursor.pending_wrap);
    try testing.expectEqual(@as(size.CellCountInt, 4), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.y);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}
test "Screen: resize less rows no scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    s.cursorAbsolute(0, 0);
    s.cursor.pending_wrap = false;
    const cursor = s.cursor;
    try s.resize(.{ .cols = 5, .rows = 1 });
    try testing.expectEqual(cursor.x, s.cursor.x);
    try testing.expectEqual(cursor.y, s.cursor.y);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: resize less rows moving cursor" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    s.cursorAbsolute(1, 2);
    s.cursor.pending_wrap = false;
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u32, 'I'), list_cell.cell.content.codepoint.data);
    }
    try s.resize(.{ .cols = 5, .rows = 1 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 0), s.cursor.y);
}
test "Screen: resize less rows with empty scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 10 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 5, .rows = 1 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: resize less rows with populated scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
    try s.resize(.{ .cols = 5, .rows = 1 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: resize less rows with full scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 3 });
    defer s.deinit();
    const str = "00000\n1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
    try testing.expectEqual(@as(size.CellCountInt, 4), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);
    try s.resize(.{ .cols = 5, .rows = 2 });
    try testing.expectEqual(@as(size.CellCountInt, 4), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.y);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "00000\n1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: resize less cols no reflow" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1AB\n2EF\n3IJ";
    try s.testWriteString(str);
    s.cursorAbsolute(0, 0);
    const cursor = s.cursor;
    try s.resize(.{ .cols = 3, .rows = 3 });
    try testing.expectEqual(cursor.x, s.cursor.x);
    try testing.expectEqual(cursor.y, s.cursor.y);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}
test "Screen: resize less cols with reflow but row space" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    const str = "1ABCD";
    try s.testWriteString(str);
    s.cursorAbsolute(4, 0);
    s.cursor.pending_wrap = false;
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u32, 'D'), list_cell.cell.content.codepoint.data);
    }
    try s.resize(.{ .cols = 3, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1AB\nCD";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "1AB\nCD";
        try testing.expectEqualStrings(expected, contents);
    }
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.y);
}
test "Screen: resize less cols with reflow with trimmed rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 3, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "CD\n5EF\nGH";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "CD\n5EF\nGH";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: resize less cols with reflow with trimmed rows and scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    const str = "3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 3, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "CD\n5EF\nGH";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "3IJ\nKL\n4AB\nCD\n5EF\nGH";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: resize less cols with reflow previously wrapped" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "3IJKL4ABCD5EFGH";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
    try s.resize(.{ .cols = 3, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "ABC\nD5E\nFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: resize less cols with reflow and scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    const str = "1A\n2B\n3C\n4D\n5E";
    try s.testWriteString(str);
    s.cursorAbsolute(1, s.pages.rows - 1);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u32, 'E'), list_cell.cell.content.codepoint.data);
    }
    try s.resize(.{ .cols = 3, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3C\n4D\n5E";
        try testing.expectEqualStrings(expected, contents);
    }
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);
}
test "Screen: resize less cols with reflow previously wrapped and scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 2 });
    defer s.deinit();
    const str = "1ABCD2EFGH3IJKL4ABCD5EFGH";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
    s.cursorAbsolute(s.pages.cols - 1, s.pages.rows - 1);
    s.cursor.pending_wrap = false;
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u32, 'H'), list_cell.cell.content.codepoint.data);
    }
    try s.resize(.{ .cols = 3, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "CD5\nEFG\nH";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "1AB\nCD2\nEFG\nH3I\nJKL\n4AB\nCD5\nEFG\nH";
        try testing.expectEqualStrings(expected, contents);
    }
    try testing.expectEqual(@as(size.CellCountInt, 0), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u32, 'H'), list_cell.cell.content.codepoint.data);
    }
}
test "Screen: resize less cols with scrollback keeps cursor row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    const str = "1A\n2B\n3C\n4D\n5E";
    try s.testWriteString(str);
    try s.scrollClear();
    s.cursorAbsolute(0, 0);
    try s.resize(.{ .cols = 3, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "";
        try testing.expectEqualStrings(expected, contents);
    }
    try testing.expectEqual(@as(size.CellCountInt, 0), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 0), s.cursor.y);
}
test "Screen: resize more rows, less cols with reflow with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 3 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH3IJKL\n4MNOP";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH\n3IJKL\n4MNOP";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJKL\n4MNOP";
        try testing.expectEqualStrings(expected, contents);
    }
    try s.resize(.{ .cols = 2, .rows = 10 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "BC\nD\n2E\nFG\nH3\nIJ\nKL\n4M\nNO\nP";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "1A\nBC\nD\n2E\nFG\nH3\nIJ\nKL\n4M\nNO\nP";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: resize more rows then shrink again" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 10 });
    defer s.deinit();
    const str = "1ABC";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 5, .rows = 10 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    try s.resize(.{ .cols = 5, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    try s.resize(.{ .cols = 5, .rows = 10 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}
test "Screen: resize less cols to eliminate wide char" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 2, .rows = 1, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "😀";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expectEqual(@as(u21, '😀'), cell.content.codepoint.data);
    }
    try s.resize(.{ .cols = 1, .rows = 1 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}
test "Screen: resize less cols to wrap wide char" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 3, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "x😀";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expectEqual(@as(u21, '😀'), cell.content.codepoint.data);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
    try s.resize(.{ .cols = 2, .rows = 3 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("x\n😀", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
        try testing.expect(list_cell.row.wrap);
    }
}
test "Screen: resize less cols to eliminate wide char with row space" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 2, .rows = 2, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "😀";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expectEqual(@as(u21, '😀'), cell.content.codepoint.data);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
    try s.resize(.{ .cols = 1, .rows = 2 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
}
test "Screen: resize less cols reflows cursor after wrapped text" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 50, .rows = 7, .max_scrollback_bytes = 0 });
    defer s.deinit();
    for (0..30) |_| try s.testWriteString("a");
    try testing.expectEqual(@as(usize, 0), s.cursor.y);
    try testing.expectEqual(@as(usize, 30), s.cursor.x);
    try s.resize(.{ .cols = 25, .rows = 7 });
    try testing.expectEqual(@as(usize, 1), s.cursor.y);
    try testing.expectEqual(@as(usize, 5), s.cursor.x);
}
test "Screen: resize less cols reflows cursor after empty cells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("abc");
    s.cursorRight(6);
    try testing.expectEqual(@as(usize, 0), s.cursor.y);
    try testing.expectEqual(@as(usize, 9), s.cursor.x);
    try s.resize(.{ .cols = 5, .rows = 3 });
    try testing.expectEqual(@as(usize, 1), s.cursor.y);
    try testing.expectEqual(@as(usize, 4), s.cursor.x);
}
test "Screen: resize more cols with wide spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 3, .rows = 2, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "  😀";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("  \n😀", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 1, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
    try s.resize(.{ .cols = 4, .rows = 2 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expectEqual(@as(u21, '😀'), cell.content.codepoint.data);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 3, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}
test "Screen: resize more cols with wide spacer head multiple lines" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 3, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "xxxyy😀";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("xxx\nyy\n😀", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 2, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 0, .y = 2 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 1, .y = 2 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
    try s.resize(.{ .cols = 8, .rows = 2 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 5, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expectEqual(@as(u21, '😀'), cell.content.codepoint.data);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 6, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}
test "Screen: resize more cols requiring a wide spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 2, .rows = 2, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "xx😀";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("xx\n😀", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 1, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
    try s.resize(.{ .cols = 3, .rows = 2 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("xx\n😀", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expectEqual(@as(u21, '😀'), cell.content.codepoint.data);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 1, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}
test "Screen: resize more cols with cursor at prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    try s.testWriteString("ABCDE\n");
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_eol });
    try s.testWriteString("echo");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "ABCDE\n> echo";
        try testing.expectEqualStrings(expected, contents);
    }
    try s.resize(.{
        .cols = 20,
        .rows = 3,
        .prompt_redraw = .true,
    });
    try testing.expectEqual(6, s.cursor.x);
    try testing.expectEqual(1, s.cursor.y);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "ABCDE";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: resize more cols with cursor not at prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    try s.testWriteString("ABCDE\n");
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_eol });
    try s.testWriteString("echo\n");
    try s.testWriteString("output");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "ABCDE\n> echo\noutput";
        try testing.expectEqualStrings(expected, contents);
    }
    try s.resize(.{
        .cols = 20,
        .rows = 3,
        .prompt_redraw = .true,
    });
    try testing.expectEqual(6, s.cursor.x);
    try testing.expectEqual(2, s.cursor.y);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "ABCDE\n> echo\noutput";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: resize with prompt_redraw last clears only one line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 4, .max_scrollback_bytes = 5 });
    defer s.deinit();
    try s.testWriteString("ABCDE\n");
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello\n");
    try s.testWriteString("world");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "ABCDE\n> hello\nworld";
        try testing.expectEqualStrings(expected, contents);
    }
    try s.resize(.{
        .cols = 20,
        .rows = 4,
        .prompt_redraw = .last,
    });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "ABCDE\n> hello";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: resize with prompt_redraw last multiline prompt clears only last line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 5 });
    defer s.deinit();
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("line1\n");
    s.cursorSetSemanticContent(.{ .prompt = .continuation });
    try s.testWriteString("line2\n");
    s.cursorSetSemanticContent(.{ .prompt = .continuation });
    try s.testWriteString("line3");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "line1\nline2\nline3";
        try testing.expectEqualStrings(expected, contents);
    }
    try s.resize(.{
        .cols = 30,
        .rows = 5,
        .prompt_redraw = .last,
    });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "line1\nline2";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: select untracked" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("ABC  DEF\n 123\n456");
    try testing.expect(s.selection == null);
    const tracked = s.pages.countTrackedPins();
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
        s.pages.pin(.{ .active = .{ .x = 3, .y = 0 } }).?,
        false,
    ));
    try testing.expectEqual(tracked + 2, s.pages.countTrackedPins());
    try s.select(null);
    try testing.expectEqual(tracked, s.pages.countTrackedPins());
}
test "Screen: select replaces existing pins" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("ABC  DEF\n 123\n456");
    const tracked = s.pages.countTrackedPins();
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
        s.pages.pin(.{ .active = .{ .x = 3, .y = 0 } }).?,
        false,
    ));
    try testing.expectEqual(tracked + 2, s.pages.countTrackedPins());
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        s.pages.pin(.{ .active = .{ .x = 2, .y = 1 } }).?,
        false,
    ));
    try testing.expectEqual(tracked + 2, s.pages.countTrackedPins());
}
test "Screen: reselecting tracked selection preserves its pins" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 2, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 1, .y = 0 } }).?,
        s.pages.pin(.{ .active = .{ .x = 3, .y = 0 } }).?,
        false,
    ));
    try s.select(s.selection.?);
    try testing.expectEqual(Selection.Order.forward, s.selection.?.order(&s));
}
test "Screen: selectAll" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    {
        try s.testWriteString("ABC  DEF\n 123\n456");
        var sel = s.selectAll().?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        try s.testWriteString("\nFOO\n BAR\n BAZ\n QWERTY\n 12345678");
        var sel = s.selectAll().?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 8,
            .y = 7,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}
test "Screen: selectLine" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("ABC  DEF\n 123\n456");
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 7,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 9,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}
test "Screen: selectLine across soft-wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString(" 12 34012   \n 123");
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}
test "Screen: selectLine across full soft-wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1ABCD2EFGH\n3IJKL");
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 1,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}
test "Screen: selectLine across soft-wrap ignores blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString(" 12 34012             \n 123");
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 1,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}
test "Screen: selectLine disabled whitespace trimming" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString(" 12 34012   \n 123");
    {
        var sel = s.selectLine(.{
            .pin = s.pages.pin(.{ .active = .{
                .x = 1,
                .y = 0,
            } }).?,
            .whitespace = null,
        }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        var sel = s.selectLine(.{
            .pin = s.pages.pin(.{ .active = .{
                .x = 1,
                .y = 3,
            } }).?,
            .whitespace = null,
        }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}
test "Screen: selectLine with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 2, .rows = 3, .max_scrollback_bytes = 5 });
    defer s.deinit();
    try s.testWriteString("1A\n2B\n3C\n4D\n5E");
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 2,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 2,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 2,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
}
test "Screen: selectLine semantic prompt boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("ABCDE\n");
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("A    ");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("> ");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("ABCDE\nA    \n> ", contents);
    }
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 1,
        } }).? }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        const expected = "A";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 2,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 2,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 2,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
}
test "Screen: selectLine semantic boundary around unwritten cells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 1, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("x");
    s.cursorRight(2);
    try s.testWriteString("m");
    for (1..3) |x| {
        const pin = s.pages.pin(.{ .active = .{ .x = @intCast(x) } }).?;
        try testing.expect(s.selectLine(.{ .pin = pin }) == null);
    }
}
test "Screen: selectLine semantic prompt to input boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("$>");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("command");
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 5,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 2,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 8,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
}
test "Screen: selectLine semantic input to output boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("ls -la\n");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("file.txt");
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("ls -la", contents);
    }
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 1,
        } }).? }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("file.txt", contents);
    }
}
test "Screen: selectLine semantic mid-row boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("out");
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("$>");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("cmd");
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 2,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 3,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 4,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 6,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 5,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
}
test "Screen: selectLine semantic boundary soft-wrap with mid-row transition" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("$ ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("cmd12");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("out");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("$ cmd\n12out", contents);
    }
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("cmd12", contents);
    }
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).? }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("cmd12", contents);
    }
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 1,
        } }).? }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("out", contents);
    }
}
test "Screen: selectLine semantic boundary disabled" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("$ ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("command");
    {
        var sel = s.selectLine(.{
            .pin = s.pages.pin(.{ .active = .{
                .x = 0,
                .y = 0,
            } }).?,
            .semantic_prompt_boundary = false,
        }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("$ command", contents);
    }
}
test "Screen: selectLine semantic boundary first cell of row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("12345");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("ABCDE");
    {
        const pin = s.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?;
        const row = pin.rowAndCell().row;
        try testing.expect(row.wrap);
    }
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 4,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 1,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 4,
            .y = 1,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
}
test "Screen: selectLine semantic boundary across mixed-width pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 4, .rows = 2, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("ABCD");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("E");
    const first = s.pages.pages.first.?;
    try s.pages.split(.{ .node = first, .y = 1 });
    const second = first.next.?;
    first.page().size.cols = 2;
    s.pages.pauseIntegrityChecks(true);
    defer s.pages.pauseIntegrityChecks(false);
    try testing.expectEqual(@as(size.CellCountInt, 2), first.cols());
    try testing.expectEqual(@as(size.CellCountInt, 4), second.cols());
    var sel = s.selectLine(.{ .pin = .{
        .node = first,
        .x = 1,
    } }).?;
    defer sel.deinit(&s);
    try testing.expect((Pin{ .node = first, .x = 0 }).eql(sel.start()));
    try testing.expect((Pin{ .node = first, .x = 1 }).eql(sel.end()));
}
test "Screen: selectLine semantic all same content" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("prompt text");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("promp\nt tex\nt", contents);
    }
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 1,
        } }).? }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("prompt text", contents);
    }
}
test "Screen: selectWord" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("ABC  DEF\n 123\n456");
    const boundary_codepoints = &[_]u21{
        0,   ' ', '\t', '\'', '"',
        '│',
        '`', '|', ':',  ';',  ',',
        '(', ')', '[',  ']',  '{',
        '}', '<', '>',  '$',
    };
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 0,
        } }).?, boundary_codepoints).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 0,
        } }).?, boundary_codepoints).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 0,
        } }).?, boundary_codepoints).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 0,
        } }).?, boundary_codepoints).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?, boundary_codepoints).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 2,
        } }).?, boundary_codepoints).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}
test "Screen: selectWord at hard line breaks" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    const cases = [_]struct { cols: size.CellCountInt, text: []const u8 }{
        .{ .cols = 5, .text = "abcde\nfghij" },
        .{ .cols = 5, .text = "     \n     " },
        .{ .cols = 1, .text = "a\nb" },
        .{ .cols = 1, .text = " \n " },
    };
    for (cases) |case| {
        var s = try init(io, alloc, .{
            .cols = case.cols,
            .rows = 2,
            .max_scrollback_bytes = 0,
        });
        defer s.deinit();
        try s.testWriteString(case.text);
        for (0..2) |y| {
            for (0..case.cols) |x| {
                var sel = s.selectWord(s.pages.pin(.{ .active = .{
                    .x = @intCast(x),
                    .y = @intCast(y),
                } }).?, &.{ 0, ' ' }).?;
                defer sel.deinit(&s);
                try testing.expectEqual(point.Point{ .screen = .{
                    .x = 0,
                    .y = @intCast(y),
                } }, s.pages.pointFromPin(.screen, sel.start()).?);
                try testing.expectEqual(point.Point{ .screen = .{
                    .x = case.cols - 1,
                    .y = @intCast(y),
                } }, s.pages.pointFromPin(.screen, sel.end()).?);
            }
        }
    }
}
test "Screen: selectWord across soft-wrap at right edge" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{
        .cols = 5,
        .rows = 3,
        .max_scrollback_bytes = 0,
    });
    defer s.deinit();
    try s.testWriteString("abcdefghij\nklmno");
    for (0..2) |y| {
        for (0..5) |x| {
            var sel = s.selectWord(s.pages.pin(.{ .active = .{
                .x = @intCast(x),
                .y = @intCast(y),
            } }).?, &.{ 0, ' ' }).?;
            defer sel.deinit(&s);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 0,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.start()).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 4,
                .y = 1,
            } }, s.pages.pointFromPin(.screen, sel.end()).?);
        }
    }
}
test "Screen: selectWord wide characters" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    const cases = [_]struct {
        text: []const u8,
        cols: size.CellCountInt = 10,
        boundary_codepoints: []const u21 = &.{ 0, ' ' },
        start: usize = 0,
        end: usize,
        expected: []const u8,
    }{
        .{ .text = "日本語", .end = 5, .expected = "日本語" },
        .{ .text = "日本語", .end = 5, .expected = "日本語", .boundary_codepoints = &.{' '} },
        .{ .text = "a日b語c", .end = 6, .expected = "a日b語c" },
        .{ .text = " 日本語 ", .start = 1, .end = 6, .expected = "日本語" },
        .{ .text = "日本語", .cols = 4, .end = 5, .expected = "日本語" },
        .{ .text = "日本語", .cols = 5, .end = 6, .expected = "日本語" },
        .{ .text = "日本\n語文", .cols = 4, .end = 3, .expected = "日本" },
        .{ .text = "日本\n語文", .cols = 4, .start = 4, .end = 7, .expected = "語文" },
        .{ .text = "a語b", .boundary_codepoints = &.{ 0, '語' }, .end = 0, .expected = "a" },
        .{ .text = "a語b", .boundary_codepoints = &.{ 0, '語' }, .start = 1, .end = 2, .expected = "語" },
        .{ .text = "a語b", .boundary_codepoints = &.{ 0, '語' }, .start = 3, .end = 3, .expected = "b" },
        .{ .text = "abcd語ef", .cols = 5, .boundary_codepoints = &.{ 0, '語' }, .end = 3, .expected = "abcd" },
        .{ .text = "abcd語ef", .cols = 5, .boundary_codepoints = &.{ 0, '語' }, .start = 4, .end = 6, .expected = "語" },
        .{ .text = "abcd語ef", .cols = 5, .boundary_codepoints = &.{ 0, '語' }, .start = 7, .end = 8, .expected = "ef" },
    };
    for (cases) |case| {
        var s = try init(io, alloc, .{
            .cols = case.cols,
            .rows = 4,
            .max_scrollback_bytes = 0,
        });
        defer s.deinit();
        try s.testWriteString(case.text);
        for (case.start..case.end + 1) |offset| {
            const pin = s.pages.pin(.{ .active = .{
                .x = @intCast(offset % case.cols),
                .y = @intCast(offset / case.cols),
            } }).?;
            var sel = s.selectWord(pin, case.boundary_codepoints).?;
            defer sel.deinit(&s);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = @intCast(case.start % case.cols),
                .y = @intCast(case.start / case.cols),
            } }, s.pages.pointFromPin(.screen, sel.start()).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = @intCast(case.end % case.cols),
                .y = @intCast(case.end / case.cols),
            } }, s.pages.pointFromPin(.screen, sel.end()).?);
            const contents = try s.selectionString(alloc, .{ .sel = sel });
            defer alloc.free(contents);
            try testing.expectEqualStrings(case.expected, contents);
        }
    }
}
test "Screen: selectWord across soft-wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString(" 1234012\n 123");
    const boundary_codepoints = &[_]u21{
        0,   ' ', '\t', '\'', '"',
        '│',
        '`', '|', ':',  ';',  ',',
        '(', ')', '[',  ']',  '{',
        '}', '<', '>',  '$',
    };
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(" 1234\n012\n 123", contents);
    }
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 0,
        } }).?, boundary_codepoints).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 1,
        } }).?, boundary_codepoints).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 0,
        } }).?, boundary_codepoints).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}
test "Screen: selectWord whitespace across soft-wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1       1\n 123");
    const boundary_codepoints = &[_]u21{
        0,   ' ', '\t', '\'', '"',
        '│',
        '`', '|', ':',  ';',  ',',
        '(', ')', '[',  ']',  '{',
        '}', '<', '>',  '$',
    };
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 0,
        } }).?, boundary_codepoints).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 1,
        } }).?, boundary_codepoints).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 0,
        } }).?, boundary_codepoints).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}
test "Screen: selectWord with character boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    const boundary_codepoints = &[_]u21{
        0,   ' ', '\t', '\'', '"',
        '│',
        '`', '|', ':',  ';',  ',',
        '(', ')', '[',  ']',  '{',
        '}', '<', '>',  '$',
    };
    const cases = [_][]const u8{
        " 'abc' \n123",
        " \"abc\" \n123",
        " │abc│ \n123",
        " `abc` \n123",
        " |abc| \n123",
        " :abc: \n123",
        " ;abc; \n123",
        " ,abc, \n123",
        " (abc( \n123",
        " )abc) \n123",
        " [abc[ \n123",
        " ]abc] \n123",
        " {abc{ \n123",
        " }abc} \n123",
        " <abc< \n123",
        " >abc> \n123",
        " $abc$ \n123",
    };
    for (cases) |case| {
        var s = try init(io, alloc, .{ .cols = 20, .rows = 10, .max_scrollback_bytes = 0 });
        defer s.deinit();
        try s.testWriteString(case);
        {
            var sel = s.selectWord(s.pages.pin(.{ .active = .{
                .x = 2,
                .y = 0,
            } }).?, boundary_codepoints).?;
            defer sel.deinit(&s);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 2,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.start()).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 4,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.end()).?);
        }
        {
            var sel = s.selectWord(s.pages.pin(.{ .active = .{
                .x = 4,
                .y = 0,
            } }).?, boundary_codepoints).?;
            defer sel.deinit(&s);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 2,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.start()).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 4,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.end()).?);
        }
        {
            var sel = s.selectWord(s.pages.pin(.{ .active = .{
                .x = 3,
                .y = 0,
            } }).?, boundary_codepoints).?;
            defer sel.deinit(&s);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 2,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.start()).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 4,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.end()).?);
        }
        {
            var sel = s.selectWord(s.pages.pin(.{ .active = .{
                .x = 1,
                .y = 0,
            } }).?, boundary_codepoints).?;
            defer sel.deinit(&s);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 0,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.start()).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 1,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.end()).?);
        }
    }
}
test "Screen: selectOutput" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 15, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("output1\n");
    try s.testWriteString("output1\n");
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("prompt2\n");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("input2\n");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("output2output2output2output2\n");
    try s.testWriteString("output2\n");
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("$ ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("input3\n");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("output3\n");
    try s.testWriteString("output3\n");
    try s.testWriteString("output3");
    {
        var sel = s.selectOutput(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 1,
        } }).?).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("output1\noutput1", contents);
    }
    {
        var sel = s.selectOutput(s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 7,
        } }).?).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings(
            "output2output2output2output2\noutput2",
            contents,
        );
    }
    {
        var sel = s.selectOutput(s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 10,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 9,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 6,
            .y = 11,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
    {
        try testing.expect(s.selectOutput(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 8,
        } }).?) == null);
    }
    {
        try testing.expect(s.selectOutput(s.pages.pin(.{ .active = .{
            .x = 5,
            .y = 8,
        } }).?) == null);
    }
}
test "Screen: selectionString basic" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJ";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: selectionString start outside of written area" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 6 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: selectionString end outside of written area" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 2 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 6 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: selectionString trim space" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1AB  \n2EFGH\n3IJKL";
    try s.testWriteString(str);
    const sel = Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
        false,
    );
    {
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "1AB\n2EF";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        const expected = "1AB  \n2EF";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: selectionString trim empty line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1AB  \n\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    const sel = Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
        false,
    );
    {
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "1AB\n\n2EF";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        const expected = "1AB  \n\n2EF";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: selectionString soft wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD2EFGH3IJKL";
    try s.testWriteString(str);
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "2EFGH3IJ";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: selectionString wide char" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1A⚡";
    try s.testWriteString(str);
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 0 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = str;
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 0 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = str;
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 0 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "⚡";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: selectionString wide char with header" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABC⚡";
    try s.testWriteString(str);
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 0 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = str;
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: selectionString empty with soft wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 2, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("👨");
    try s.testWriteString("      ");
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 0 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "👨";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: selectionString with zero width joiner" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 1, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "👨‍";
    try s.testWriteString(str);
    {
        const pin = s.pages.pin(.{ .screen = .{ .y = 0, .x = 0 } }).?;
        const cell = pin.rowAndCell().cell;
        try testing.expectEqual(@as(u21, 0x1F468), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = pin.node.page().lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "👨‍";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: selectionString, rectangle, basic" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 30, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str =
        \\Lorem ipsum dolor
        \\sit amet, consectetur
        \\adipiscing elit, sed do
        \\eiusmod tempor incididunt
        \\ut labore et dolore
    ;
    const sel = Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 6, .y = 3 } }).?,
        true,
    );
    const expected =
        \\t ame
        \\ipisc
        \\usmod
    ;
    try s.testWriteString(str);
    const contents = try s.selectionString(alloc, .{
        .sel = sel,
        .trim = true,
    });
    defer alloc.free(contents);
    try testing.expectEqualStrings(expected, contents);
}
test "Screen: selectionString, rectangle, w/EOL" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 30, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str =
        \\Lorem ipsum dolor
        \\sit amet, consectetur
        \\adipiscing elit, sed do
        \\eiusmod tempor incididunt
        \\ut labore et dolore
    ;
    const sel = Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 12, .y = 0 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 26, .y = 4 } }).?,
        true,
    );
    const expected =
        \\dolor
        \\nsectetur
        \\lit, sed do
        \\or incididunt
        \\ dolore
    ;
    try s.testWriteString(str);
    const contents = try s.selectionString(alloc, .{
        .sel = sel,
        .trim = true,
    });
    defer alloc.free(contents);
    try testing.expectEqualStrings(expected, contents);
}
test "Screen: selectionString, rectangle, more complex w/breaks" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 30, .rows = 8, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str =
        \\Lorem ipsum dolor
        \\sit amet, consectetur
        \\adipiscing elit, sed do
        \\eiusmod tempor incididunt
        \\ut labore et dolore
        \\
        \\magna aliqua. Ut enim
        \\ad minim veniam, quis
    ;
    const sel = Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 11, .y = 2 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 26, .y = 7 } }).?,
        true,
    );
    const expected =
        \\elit, sed do
        \\por incididunt
        \\t dolore
        \\
        \\a. Ut enim
        \\niam, quis
    ;
    try s.testWriteString(str);
    const contents = try s.selectionString(alloc, .{
        .sel = sel,
        .trim = true,
    });
    defer alloc.free(contents);
    try testing.expectEqualStrings(expected, contents);
}
test "Screen: selectionString multi-page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 2048 });
    defer s.deinit();
    const first_page_size = s.pages.pages.first.?.capacity().rows;
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 1) |_| {
        try s.testWriteString("\n");
    }
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);
    try s.testWriteString("123456789\n!@#$%^&*(\n123456789");
    {
        const sel = Selection.init(
            s.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
            s.pages.pin(.{ .active = .{ .x = 2, .y = 2 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "123456789\n!@#$%^&*(\n123";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: lineIterator" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH";
    try s.testWriteString(str);
    var iter = s.lineIterator(s.pages.pin(.{ .viewport = .{} }).?);
    {
        const sel = iter.next().?;
        const actual = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(actual);
        try testing.expectEqualStrings("1ABCD", actual);
    }
    {
        const sel = iter.next().?;
        const actual = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(actual);
        try testing.expectEqualStrings("2EFGH", actual);
    }
}
test "Screen: lineIterator soft wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD2EFGH\n3ABCD";
    try s.testWriteString(str);
    var iter = s.lineIterator(s.pages.pin(.{ .viewport = .{} }).?);
    {
        const sel = iter.next().?;
        const actual = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(actual);
        try testing.expectEqualStrings("1ABCD2EFGH", actual);
    }
    {
        const sel = iter.next().?;
        const actual = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(actual);
        try testing.expectEqualStrings("3ABCD", actual);
    }
}
test "Screen: hyperlink start/end" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try testing.expect(s.cursor.hyperlink_id == 0);
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expectEqual(0, page.hyperlink_set.count());
    }
    try s.startHyperlink("http://example.com", null);
    try testing.expect(s.cursor.hyperlink_id != 0);
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expectEqual(1, page.hyperlink_set.count());
    }
    s.endHyperlink();
    try testing.expect(s.cursor.hyperlink_id == 0);
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expectEqual(0, page.hyperlink_set.count());
    }
}
test "Screen: hyperlink accepts its current values" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.startHyperlink("http://example.com", "current");
    const current = s.cursor.hyperlink.?;
    try s.startHyperlink(current.uri, current.id.explicit);
    try testing.expectEqualStrings("http://example.com", s.cursor.hyperlink.?.uri);
    try testing.expectEqualStrings("current", s.cursor.hyperlink.?.id.explicit);
}
test "Screen: implicit hyperlink ID wraps" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.cursor.hyperlink_implicit_id = std.math.maxInt(size.OffsetInt);
    try s.startHyperlink("http://example.com", null);
    try testing.expectEqual(@as(size.OffsetInt, 0), s.cursor.hyperlink_implicit_id);
    try testing.expectEqual(
        std.math.maxInt(size.OffsetInt),
        s.cursor.hyperlink.?.id.implicit,
    );
    s.endHyperlink();
    s.cursor.hyperlink_implicit_id = std.math.maxInt(size.OffsetInt);
    var failing = testing.FailingAllocator.init(alloc, .{});
    failing.fail_index = failing.alloc_index;
    {
        const original_alloc = s.alloc;
        defer s.alloc = original_alloc;
        s.alloc = failing.allocator();
        try testing.expectError(
            error.OutOfMemory,
            s.startHyperlink("http://example.com", null),
        );
    }
    try testing.expectEqual(
        std.math.maxInt(size.OffsetInt),
        s.cursor.hyperlink_implicit_id,
    );
}
test "Screen: hyperlink reuse" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try testing.expect(s.cursor.hyperlink_id == 0);
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expectEqual(0, page.hyperlink_set.count());
    }
    try s.startHyperlink("http://example.com", null);
    try testing.expect(s.cursor.hyperlink_id != 0);
    const id = s.cursor.hyperlink_id;
    try s.startHyperlink("http://example.com", null);
    try testing.expectEqual(id, s.cursor.hyperlink_id);
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expectEqual(1, page.hyperlink_set.count());
    }
    s.endHyperlink();
    try testing.expect(s.cursor.hyperlink_id == 0);
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expectEqual(0, page.hyperlink_set.count());
    }
}
test "Screen: hyperlink cursor state on resize" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.startHyperlink("http://example.com", null);
    try testing.expect(s.cursor.hyperlink_id != 0);
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expectEqual(1, page.hyperlink_set.count());
    }
    try s.resize(.{ .cols = 10, .rows = 10 });
    try testing.expect(s.cursor.hyperlink_id != 0);
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expectEqual(1, page.hyperlink_set.count());
    }
    s.endHyperlink();
    try testing.expect(s.cursor.hyperlink_id == 0);
    {
        const page = s.cursor.page_pin.node.page();
        try testing.expectEqual(0, page.hyperlink_set.count());
    }
}
test "Screen: cursorSetHyperlink OOM + URI too large for string alloc" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const uri = "a" ** (pagepkg.std_capacity.string_bytes - 8);
    try s.startHyperlink(uri, null);
    const base_capacity = s.cursor.page_pin.node.page().hyperlinkCapacity();
    const base_string_bytes = s.cursor.page_pin.node.capacity().string_bytes;
    for (0..base_capacity * 2) |_| {
        try s.cursorSetHyperlink();
        if (s.cursor.x >= s.pages.cols - 1) {
            try s.cursorDownOrScroll();
            s.cursorHorizontalAbsolute(0);
        } else {
            s.cursorRight(1);
        }
    }
    try testing.expect(base_capacity < s.cursor.page_pin.node.page().hyperlinkCapacity());
    try testing.expect(base_string_bytes < s.cursor.page_pin.node.capacity().string_bytes);
}
test "Screen: increaseCapacity cursor style ref count preserved" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{
        .cols = 5,
        .rows = 5,
        .max_scrollback_bytes = 0,
    });
    defer s.deinit();
    try s.setAttribute(.bold);
    try s.testWriteString("1ABCD");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try testing.expect(s.pages.pages.first == s.cursor.page_pin.node);
    const old_style = s.cursor.style;
    {
        const page = s.pages.pages.last.?.page();
        try testing.expectEqual(
            6,
            page.styles.refCount(page.memory, s.cursor.style_id),
        );
    }
    const new_node = try s.increaseCapacity(
        s.cursor.page_pin.node,
        .grapheme_bytes,
    );
    try testing.expect(s.cursor.page_pin.node == new_node);
    const page_rac = s.cursor.page_pin.rowAndCell();
    try testing.expect(s.cursor.page_row == page_rac.row);
    try testing.expect(s.cursor.page_cell == page_rac.cell);
    try testing.expectEqual(old_style, s.cursor.style);
    try testing.expect(s.cursor.style_id != style.default_id);
    {
        const page = s.pages.pages.last.?.page();
        const ref_count = page.styles.refCount(page.memory, s.cursor.style_id);
        try testing.expectEqual(6, ref_count);
    }
}
test "Screen: increaseCapacity cursor hyperlink ref count preserved" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{
        .cols = 5,
        .rows = 5,
        .max_scrollback_bytes = 0,
    });
    defer s.deinit();
    try s.startHyperlink("https://example.com/", null);
    try s.testWriteString("1ABCD");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try testing.expect(s.pages.pages.first == s.cursor.page_pin.node);
    {
        const page = s.pages.pages.last.?.page();
        try testing.expectEqual(1, page.hyperlink_set.count());
        try testing.expect(s.cursor.hyperlink_id != 0);
        try testing.expect(s.cursor.hyperlink != null);
    }
    _ = try s.increaseCapacity(
        s.cursor.page_pin.node,
        .grapheme_bytes,
    );
    try testing.expect(s.cursor.hyperlink != null);
    try testing.expect(s.cursor.hyperlink_id != 0);
    try testing.expectEqualStrings("https://example.com/", s.cursor.hyperlink.?.uri);
    {
        const page = s.pages.pages.last.?.page();
        try testing.expectEqual(1, page.hyperlink_set.count());
    }
}
test "Screen: increaseCapacity cursor with both style and hyperlink preserved" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{
        .cols = 5,
        .rows = 5,
        .max_scrollback_bytes = 0,
    });
    defer s.deinit();
    try s.setAttribute(.bold);
    try s.startHyperlink("https://example.com/", null);
    try s.testWriteString("1ABCD");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try testing.expect(s.pages.pages.first == s.cursor.page_pin.node);
    const old_style = s.cursor.style;
    {
        const page = s.pages.pages.last.?.page();
        try testing.expectEqual(
            6,
            page.styles.refCount(page.memory, s.cursor.style_id),
        );
        try testing.expectEqual(1, page.hyperlink_set.count());
        try testing.expect(s.cursor.style_id != style.default_id);
        try testing.expect(s.cursor.hyperlink_id != 0);
        try testing.expect(s.cursor.hyperlink != null);
    }
    _ = try s.increaseCapacity(
        s.cursor.page_pin.node,
        .grapheme_bytes,
    );
    try testing.expectEqual(old_style, s.cursor.style);
    try testing.expect(s.cursor.style_id != style.default_id);
    try testing.expect(s.cursor.hyperlink != null);
    try testing.expect(s.cursor.hyperlink_id != 0);
    try testing.expectEqualStrings("https://example.com/", s.cursor.hyperlink.?.uri);
    {
        const page = s.pages.pages.last.?.page();
        const ref_count = page.styles.refCount(page.memory, s.cursor.style_id);
        try testing.expectEqual(6, ref_count);
        try testing.expectEqual(1, page.hyperlink_set.count());
    }
}
test "Screen: increaseCapacity non-cursor page returns early" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_bytes = 10000,
    });
    defer s.deinit();
    try s.setAttribute(.bold);
    try s.startHyperlink("https://example.com/", null);
    try s.testWriteString("Hello");
    const old_style = s.cursor.style;
    const old_style_id = s.cursor.style_id;
    const old_hyperlink = s.cursor.hyperlink;
    const old_hyperlink_id = s.cursor.hyperlink_id;
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.first.?);
    const first_page_node = s.pages.pages.first.?;
    first_page_node.page().pauseIntegrityChecks(true);
    for (0..first_page_node.capacity().rows - first_page_node.rows()) |_| {
        _ = try s.pages.grow();
    }
    first_page_node.page().pauseIntegrityChecks(false);
    _ = try s.pages.grow();
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    const second_page = s.pages.pages.last.?;
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.first.?);
    try testing.expect(s.cursor.page_pin.node != second_page);
    const second_page_styles_cap = second_page.capacity().styles;
    const cursor_page_styles_cap = s.cursor.page_pin.node.capacity().styles;
    const new_second_page = try s.increaseCapacity(second_page, .styles);
    try testing.expectEqual(
        second_page_styles_cap * 2,
        new_second_page.capacity().styles,
    );
    try testing.expectEqual(
        cursor_page_styles_cap,
        s.cursor.page_pin.node.capacity().styles,
    );
    try testing.expectEqual(old_style, s.cursor.style);
    try testing.expectEqual(old_style_id, s.cursor.style_id);
    try testing.expectEqual(old_hyperlink, s.cursor.hyperlink);
    try testing.expectEqual(old_hyperlink_id, s.cursor.hyperlink_id);
    try testing.expect(s.cursor.hyperlink != null);
    try testing.expectEqualStrings("https://example.com/", s.cursor.hyperlink.?.uri);
}
test "Screen: cursorDown to page with insufficient capacity" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 1 });
    defer s.deinit();
    const start_page = s.pages.pages.last.?.page();
    const rem = start_page.capacity.rows;
    start_page.pauseIntegrityChecks(true);
    for (0..rem) |_| try s.cursorDownOrScroll();
    start_page.pauseIntegrityChecks(false);
    const new_page = s.cursor.page_pin.node.page();
    try testing.expect(start_page != new_page);
    {
        new_page.pauseIntegrityChecks(true);
        defer new_page.pauseIntegrityChecks(false);
        defer new_page.assertIntegrity();
        var n: u24 = 1;
        while (new_page.styles.add(
            new_page.memory,
            .{ .bg_color = .{ .rgb = @bitCast(n) } },
        )) |_| n += 1 else |_| {}
    }
    s.cursorAbsolute(0, 0);
    try s.setAttribute(.bold);
    try testing.expect(s.cursor.style.flags.bold);
    try testing.expect(s.cursor.style_id != style.default_id);
    for (0..s.pages.rows - 1) |row| {
        s.cursorAbsolute(0, @intCast(row));
        const cur_node = s.cursor.page_pin.node;
        if (s.cursor.page_pin.down(1)) |next_pin| {
            if (next_pin.node != cur_node) {
                try testing.expect(next_pin.node.page() == new_page);
                s.cursorDown(1);
                try testing.expect(s.cursor.y == row + 1);
                try testing.expect(s.cursor.style.flags.bold);
                break;
            }
        }
    } else {
        try testing.expect(false);
    }
}
test "Screen setAttribute increases capacity when style map is full" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 10 });
    defer s.deinit();
    try s.testWriteString("line1\nline2\nline3\nline4\nline5");
    const page = s.cursor.page_pin.node.page();
    const original_styles_capacity = page.capacity.styles;
    {
        page.pauseIntegrityChecks(true);
        defer page.pauseIntegrityChecks(false);
        defer page.assertIntegrity();
        const max_items = page.styles.layout.cap;
        var n: usize = 1;
        while (n < max_items) : (n += 1) {
            _ = page.styles.add(
                page.memory,
                .{ .bg_color = .{ .rgb = @bitCast(@as(u24, @intCast(n))) } },
            ) catch break;
        }
    }
    try s.setAttribute(.bold);
    try testing.expect(s.cursor.style.flags.bold);
    try testing.expect(s.cursor.style_id != style.default_id);
    const current_page = s.cursor.page_pin.node.page();
    const capacity_increased = current_page.capacity.styles > original_styles_capacity;
    const page_changed = current_page != page;
    try testing.expect(capacity_increased or page_changed);
}
test "Screen setAttribute splits page on OutOfSpace at max styles" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{
        .cols = 10,
        .rows = 10,
        .max_scrollback_bytes = 0,
    });
    defer s.deinit();
    try s.testWriteString("line1\nline2\nline3\nline4\nline5");
    const original_node = s.cursor.page_pin.node;
    const max_styles = std.math.maxInt(size.CellCountInt);
    while (s.cursor.page_pin.node.capacity().styles < max_styles) {
        _ = s.increaseCapacity(
            s.cursor.page_pin.node,
            .styles,
        ) catch break;
    }
    var page = s.cursor.page_pin.node.page();
    try testing.expectEqual(max_styles, page.capacity.styles);
    {
        page.pauseIntegrityChecks(true);
        defer page.pauseIntegrityChecks(false);
        defer page.assertIntegrity();
        const max_items = page.styles.layout.cap;
        var n: usize = 1;
        while (n < max_items) : (n += 1) {
            _ = page.styles.add(
                page.memory,
                .{ .bg_color = .{ .rgb = @bitCast(@as(u24, @intCast(n))) } },
            ) catch break;
        }
    }
    const node_before_set = s.cursor.page_pin.node;
    try s.setAttribute(.bold);
    try testing.expect(s.cursor.style.flags.bold);
    try testing.expect(s.cursor.style_id != style.default_id);
    const page_was_split = s.cursor.page_pin.node != node_before_set or
        node_before_set.next != null or
        node_before_set.prev != null or
        s.cursor.page_pin.node != original_node;
    try testing.expect(page_was_split);
}
test "Screen: promptClickMove line right basic" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.semantic_prompt.click = .{ .cl = .line };
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");
    s.cursorAbsolute(2, 0);
    const click_pin = s.pages.pin(.{ .active = .{ .x = 4, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);
    try testing.expectEqual(@as(usize, 2), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}
test "Screen: promptClickMove line right cursor not on input" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.semantic_prompt.click = .{ .cl = .line };
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");
    s.cursorSetSemanticContent(.output);
    s.cursorAbsolute(0, 0);
    const click_pin = s.pages.pin(.{ .active = .{ .x = 4, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);
    try testing.expectEqual(PromptClickMove.zero, result);
}
test "Screen: promptClickMove line right click on same position" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.semantic_prompt.click = .{ .cl = .line };
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");
    s.cursorAbsolute(4, 0);
    const click_pin = s.pages.pin(.{ .active = .{ .x = 4, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);
    try testing.expectEqual(PromptClickMove.zero, result);
}
test "Screen: promptClickMove line right skips non-input cells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.semantic_prompt.click = .{ .cl = .line };
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("h");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("X");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("llo");
    s.cursorAbsolute(2, 0);
    const click_pin = s.pages.pin(.{ .active = .{ .x = 5, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);
    try testing.expectEqual(@as(usize, 2), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}
test "Screen: promptClickMove line right soft-wrapped line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.semantic_prompt.click = .{ .cl = .line };
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("abcdefgh");
    try s.testWriteString("ij");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("> abcdefgh\nij", contents);
    }
    s.cursorAbsolute(2, 0);
    const click_pin = s.pages.pin(.{ .active = .{ .x = 1, .y = 1 } }).?;
    const result = s.promptClickMove(click_pin);
    try testing.expectEqual(@as(usize, 9), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}
test "Screen: promptClickMove disabled when click is none" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try testing.expectEqual(Screen.SemanticPrompt.SemanticClick.none, s.semantic_prompt.click);
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");
    s.cursorAbsolute(2, 0);
    const click_pin = s.pages.pin(.{ .active = .{ .x = 4, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);
    try testing.expectEqual(PromptClickMove.zero, result);
}
test "Screen: promptClickMove line right stops at hard wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.semantic_prompt.click = .{ .cl = .line };
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");
    try s.testWriteString("\n");
    try s.testWriteString("world");
    s.cursorAbsolute(2, 0);
    const click_pin = s.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?;
    const result = s.promptClickMove(click_pin);
    try testing.expectEqual(@as(usize, 5), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}
test "Screen: promptClickMove line right stops at non-continuation row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.semantic_prompt.click = .{ .cl = .line };
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello\n");
    s.cursorSetSemanticContent(.{ .prompt = .continuation });
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("world\n");
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("again");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("> hello\nworld\n> again", contents);
    }
    s.cursorAbsolute(0, 1);
    const click_pin = s.pages.pin(.{ .active = .{ .x = 2, .y = 2 } }).?;
    const result = s.promptClickMove(click_pin);
    try testing.expectEqual(@as(usize, 5), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}
test "Screen: promptClickMove line left basic" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.semantic_prompt.click = .{ .cl = .line };
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");
    s.cursorAbsolute(6, 0);
    const click_pin = s.pages.pin(.{ .active = .{ .x = 2, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);
    try testing.expectEqual(@as(usize, 4), result.left);
    try testing.expectEqual(@as(usize, 0), result.right);
}
test "Screen: promptClickMove line left skips non-input cells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.semantic_prompt.click = .{ .cl = .line };
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("h");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("X");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("llo");
    s.cursorAbsolute(6, 0);
    const click_pin = s.pages.pin(.{ .active = .{ .x = 2, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);
    try testing.expectEqual(@as(usize, 3), result.left);
    try testing.expectEqual(@as(usize, 0), result.right);
}
test "Screen: promptClickMove line left soft-wrapped line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.semantic_prompt.click = .{ .cl = .line };
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("abcdefgh");
    try s.testWriteString("ij");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("> abcdefgh\nij", contents);
    }
    s.cursorAbsolute(1, 1);
    const click_pin = s.pages.pin(.{ .active = .{ .x = 2, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);
    try testing.expectEqual(@as(usize, 9), result.left);
    try testing.expectEqual(@as(usize, 0), result.right);
}
test "Screen: promptClickMove line left stops at hard wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.semantic_prompt.click = .{ .cl = .line };
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");
    try s.testWriteString("\n");
    try s.testWriteString("world");
    s.cursorAbsolute(4, 1);
    const click_pin = s.pages.pin(.{ .active = .{ .x = 2, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);
    try testing.expectEqual(@as(usize, 4), result.left);
    try testing.expectEqual(@as(usize, 0), result.right);
}
test "Screen: promptClickMove click right of input same line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.semantic_prompt.click = .{ .cl = .line };
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");
    s.cursorAbsolute(2, 0);
    const click_pin = s.pages.pin(.{ .active = .{ .x = 15, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);
    try testing.expectEqual(@as(usize, 5), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}
test "Screen: promptClickMove click right of input cursor at end" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.semantic_prompt.click = .{ .cl = .line };
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");
    const click_pin = s.pages.pin(.{ .active = .{ .x = 15, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);
    try testing.expectEqual(@as(usize, 0), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}
test "Screen: promptClickMove click right of input on lower line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.semantic_prompt.click = .{ .cl = .line };
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");
    s.cursorAbsolute(2, 0);
    const click_pin = s.pages.pin(.{ .active = .{ .x = 5, .y = 1 } }).?;
    const result = s.promptClickMove(click_pin);
    try testing.expectEqual(@as(usize, 5), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}
test "Screen: promptClickMove click right of input cursor at end lower line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.semantic_prompt.click = .{ .cl = .line };
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");
    const click_pin = s.pages.pin(.{ .active = .{ .x = 5, .y = 1 } }).?;
    const result = s.promptClickMove(click_pin);
    try testing.expectEqual(@as(usize, 0), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}
test "Screen: promptClickMove click right of input cursor on last char" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    s.semantic_prompt.click = .{ .cl = .line };
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");
    s.cursorAbsolute(6, 0);
    const click_pin = s.pages.pin(.{ .active = .{ .x = 15, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);
    try testing.expectEqual(@as(usize, 1), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}
test "Screen: cursorScrollRegionUp recycled row has default metadata" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4MNOP\n5QRST");
    {
        const rac = s.pages.getCell(.{ .active = .{} }).?;
        rac.row.wrap = true;
        rac.row.wrap_continuation = true;
        rac.row.semantic_prompt = .prompt;
    }
    s.cursorAbsolute(1, 2);
    try s.cursorScrollRegionUp(2);
    {
        const rac = s.pages.getCell(.{ .active = .{ .y = 2 } }).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL\n\n4MNOP\n5QRST", contents);
    }
}
test "Screen: cursorScrollRegionUp cross-page recycled row has default metadata" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 10 });
    defer s.deinit();
    const first_page_size = s.pages.pages.first.?.capacity().rows;
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 3) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);
    try s.testWriteString("1A\n2B\n3C\n4D\n5E");
    {
        const rac = s.pages.getCell(.{ .active = .{ .y = 3 } }).?;
        rac.row.wrap = true;
        rac.row.wrap_continuation = true;
        rac.row.semantic_prompt = .prompt;
    }
    s.cursorAbsolute(0, 3);
    try s.cursorScrollRegionUp(2);
    {
        const rac = s.pages.getCell(.{ .active = .{ .y = 3 } }).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1A\n3C\n4D\n\n5E", contents);
    }
}
test "Screen: cursorScrollAbove cross-page recycled row has default metadata" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 10 });
    defer s.deinit();
    const first_page_size = s.pages.pages.first.?.capacity().rows;
    s.pages.pages.first.?.page().pauseIntegrityChecks(true);
    for (0..first_page_size - 3) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.page().pauseIntegrityChecks(false);
    try s.testWriteString("1A\n2B\n3C\n4D\n5E");
    s.cursorAbsolute(0, 1);
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.first.?);
    try testing.expect(s.pages.pages.first.?.next != null);
    {
        const rac = s.pages.getCell(.{ .active = .{ .y = 2 } }).?;
        rac.row.wrap = true;
        rac.row.wrap_continuation = true;
        rac.row.semantic_prompt = .prompt;
    }
    try s.cursorScrollAbove();
    {
        const rac = s.pages.getCell(.{ .active = .{ .y = 1 } }).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2B\n\n3C\n4D\n5E", contents);
    }
}
test "Screen: cursorDownScroll no scrollback recycled row has default metadata" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    {
        const rac = s.pages.getCell(.{ .active = .{} }).?;
        rac.row.wrap = true;
        rac.row.wrap_continuation = true;
        rac.row.semantic_prompt = .prompt;
    }
    s.cursorAbsolute(0, 2);
    try s.cursorDownScroll();
    {
        const rac = s.pages.getCell(.{ .active = .{ .y = 2 } }).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
}
test "Screen: cursorDownScroll single row no scrollback resets metadata" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 5, .rows = 1, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1ABCD");
    {
        const rac = s.pages.getCell(.{ .active = .{} }).?;
        rac.row.wrap = true;
        rac.row.wrap_continuation = true;
        rac.row.semantic_prompt = .prompt;
    }
    try s.cursorDownScroll();
    {
        const rac = s.pages.getCell(.{ .active = .{} }).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
}
test "Screen: selectLine does not join lines across a recycled row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try init(io, alloc, .{ .cols = 6, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("AAAAAAA");
    s.cursorAbsolute(0, 2);
    try s.cursorScrollRegionUp(2);
    s.cursorAbsolute(0, 2);
    try s.testWriteString("world");
    s.cursorAbsolute(0, 3);
    try s.testWriteString("hello");
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 2,
        } }).? }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("world", contents);
    }
}
