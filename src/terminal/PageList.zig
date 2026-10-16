const PageList = @This();
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("terminal_options");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const fastmem = @import("../fastmem.zig");
const simd = @import("../simd/root.zig");
const tripwire = @import("../tripwire.zig");
const DoublyLinkedList = @import("../datastruct/root.zig").IntrusiveDoublyLinkedList;
const datastruct = @import("../datastruct/root.zig");
const color = @import("color.zig");
const compression = @import("compress.zig");
const highlight = @import("highlight.zig");
const hyperlink = @import("hyperlink.zig");
const kitty = @import("kitty.zig");
const terminal_mem = @import("mem.zig");
const point = @import("point.zig");
const pagepkg = @import("page.zig");
const stylepkg = @import("style.zig");
const size = @import("size.zig");
const OffsetBuf = size.OffsetBuf;
const Capacity = pagepkg.Capacity;
const Page = pagepkg.Page;
const Row = pagepkg.Row;
const log = std.log.scoped(.page_list);
const native_freestanding = builtin.os.tag == .freestanding and
    !builtin.target.cpu.arch.isWasm();
const page_preheat = 4;
const node_preheat = 1;
const pin_preheat = 2;
pub const List = DoublyLinkedList(Node);
const Node = struct {
    prev: ?*Node = null,
    next: ?*Node = null,
    data: Data,
    serial: u64,
    owned: Owned,
    const Data = union(enum) {
        resident: Page,
        compressed: compression.Page,
    };
    const Owned = enum { pool, heap };
    pub const Storage = enum { resident, compressed };
    pub inline fn page(self: *Node) *Page {
        return switch (self.data) {
            .resident => |*page_| page_,
            .compressed => self.restore(.preserve),
        };
    }
    pub inline fn pageIfResident(self: *Node) ?*Page {
        return switch (self.data) {
            .resident => |*page_| page_,
            .compressed => null,
        };
    }
    pub const PreservedPage = union(enum) {
        borrowed: *const Page,
        owned: struct {
            page: Page,
            alloc: Allocator,
        },
        pub fn page(self: *const PreservedPage) *const Page {
            return switch (self.*) {
                .borrowed => |page_| page_,
                .owned => |*owned| &owned.page,
            };
        }
        pub fn deinit(self: *PreservedPage) void {
            switch (self.*) {
                .borrowed => {},
                .owned => |*owned| owned.alloc.free(owned.page.memory),
            }
            self.* = undefined;
        }
    };
    pub fn pagePreservingState(
        self: *const Node,
        alloc: Allocator,
    ) Allocator.Error!PreservedPage {
        return switch (self.data) {
            .resident => |*page_| .{ .borrowed = page_ },
            .compressed => |*compressed| owned: {
                const memory = try alloc.alignedAlloc(
                    u8,
                    .fromByteUnits(std.heap.page_size_min),
                    compressed.page.memory.len,
                );
                const page_ = compressed.cloneBuf(memory) catch |err| {
                    switch (err) {
                        error.TruncatedInput,
                        error.InvalidOffset,
                        error.OutputTooSmall,
                        error.OutputSizeMismatch,
                        => {},
                    }
                    alloc.free(memory);
                    log.err("failed to clone compressed page err={}", .{err});
                    @panic("failed to clone compressed terminal page");
                };
                break :owned .{ .owned = .{
                    .page = page_,
                    .alloc = alloc,
                } };
            },
        };
    }
    pub inline fn storage(self: *const Node) Storage {
        return switch (self.data) {
            .resident => .resident,
            .compressed => .compressed,
        };
    }
    pub inline fn pageAssumeResident(self: *Node) *Page {
        return &self.data.resident;
    }
    pub inline fn rows(self: *const Node) size.CellCountInt {
        return self.metadata().size.rows;
    }
    pub inline fn cols(self: *const Node) size.CellCountInt {
        return self.metadata().size.cols;
    }
    pub inline fn capacity(self: *const Node) Capacity {
        return self.metadata().capacity;
    }
    inline fn metadata(self: *const Node) *const Page {
        return switch (self.data) {
            .resident => |*page_| page_,
            .compressed => |*page_| &page_.page,
        };
    }
    const RestoreMode = enum {
        preserve,
        discard,
    };
    noinline fn restore(self: *Node, comptime mode: RestoreMode) *Page {
        const compressed = switch (self.data) {
            .resident => |*page_| return page_,
            .compressed => |*page_| page_,
        };
        terminal_mem.recommit(compressed.page.memory);
        const restored = switch (mode) {
            .preserve => compressed.restore() catch |err| {
                switch (err) {
                    error.TruncatedInput,
                    error.InvalidOffset,
                    error.OutputTooSmall,
                    error.OutputSizeMismatch,
                    => {},
                }
                log.err("failed to restore compressed page err={}", .{err});
                @panic("failed to restore compressed terminal page");
            },
            .discard => compressed.page,
        };
        compressed.deinit();
        self.data = .{ .resident = restored };
        return &self.data.resident;
    }
    inline fn isCompressed(self: *const Node) bool {
        return switch (self.data) {
            .resident => false,
            .compressed => true,
        };
    }
};
const NodePool = datastruct.UntouchedPool(List.Node, .of(List.Node));
const std_capacity = pagepkg.std_capacity;
const std_size = Page.layout(std_capacity).total_size;
const wasm_page_pool = builtin.target.cpu.arch.isWasm() and !builtin.is_test;
const PagePool = if (wasm_page_pool)
    datastruct.WasmPagePool([std_size]u8)
else untouched: {
    break :untouched datastruct.UntouchedPool(
        [std_size]u8,
        .fromByteUnits(std.heap.page_size_min),
    );
};
const PinSet = std.AutoArrayHashMapUnmanaged(*Pin, void);
const PinPool = std.heap.memory_pool.Managed(Pin);
pub const MemoryPool = struct {
    alloc: Allocator,
    nodes: NodePool,
    pages: PagePool,
    pins: PinPool,
    pub const ResetMode = std.heap.ArenaAllocator.ResetMode;
    pub fn init(
        gen_alloc: Allocator,
        page_alloc: Allocator,
        preheat: usize,
    ) Allocator.Error!MemoryPool {
        var node_pool = try NodePool.initCapacity(gen_alloc, gen_alloc, node_preheat);
        errdefer node_pool.deinit();
        var page_pool = try PagePool.initCapacity(gen_alloc, page_alloc, preheat);
        errdefer page_pool.deinit();
        var pin_pool = try PinPool.initCapacity(gen_alloc, pin_preheat);
        errdefer pin_pool.deinit();
        return .{
            .alloc = gen_alloc,
            .nodes = node_pool,
            .pages = page_pool,
            .pins = pin_pool,
        };
    }
    pub fn deinit(self: *MemoryPool) void {
        self.pages.deinit();
        self.nodes.deinit();
        self.pins.deinit();
    }
    pub fn reset(self: *MemoryPool, mode: ResetMode) void {
        _ = self.pages.reset(mode);
        _ = self.nodes.reset(mode);
        _ = self.pins.reset(mode);
    }
};
pool: MemoryPool,
pages: List,
page_serial: u64,
page_serial_epoch: u64,
page_size: usize,
page_compression: IncrementalCompressionState = .{},
recycle_node: ?*List.Node = null,
limits: Limits,
total_rows: usize,
tracked_pins: PinSet,
viewport: Viewport,
viewport_pin: *Pin,
viewport_pin_row_offset: ?usize,
cols: size.CellCountInt,
rows: size.CellCountInt,
pause_integrity_checks: if (build_options.slow_runtime_safety) usize else void =
    if (build_options.slow_runtime_safety) 0 else {},
pub const Viewport = union(enum) {
    active,
    top,
    pin,
};
fn initialCapacity(cols: size.CellCountInt) Capacity {
    comptime {
        var cap = std_capacity;
        cap.cols = std.math.maxInt(size.CellCountInt);
        const layout = Page.layout(cap);
        assert(layout.total_size <= size.max_page_size);
    }
    if (std_capacity.adjust(
        .{ .cols = cols },
    )) |cap| {
        return cap;
    } else |err| {
        comptime assert(@TypeOf(err) == error{OutOfMemory});
    }
    var cap: Capacity = std_capacity;
    cap.cols = cols;
    return cap;
}
inline fn pageAllocator(alloc: Allocator) Allocator {
    if (builtin.is_test) return std.testing.allocator;
    if (native_freestanding) return alloc;
    if (!builtin.target.os.tag.isDarwin()) return std.heap.page_allocator;
    const mach = @import("../os/mach.zig");
    return mach.taggedPageAllocator(.application_specific_1);
}
const init_tw = tripwire.module(enum {
    init_memory_pool,
    init_pages,
    viewport_pin,
    viewport_pin_track,
}, init);
pub const Options = struct {
    cols: size.CellCountInt,
    rows: size.CellCountInt,
    max_size: ?usize = null,
    max_lines: ?usize = null,
};
pub fn init(
    alloc: Allocator,
    opts: Options,
) Allocator.Error!PageList {
    const tw = init_tw;
    const cols = opts.cols;
    const rows = opts.rows;
    try tw.check(.init_memory_pool);
    var pool = try MemoryPool.init(
        alloc,
        pageAllocator(alloc),
        page_preheat,
    );
    errdefer pool.deinit();
    try tw.check(.init_pages);
    var page_serial: u64 = 0;
    const page_list, const page_size = try initPages(
        &pool,
        &page_serial,
        cols,
        rows,
    );
    errdefer releasePages(&pool, page_list);
    var limits: Limits = .init(cols, rows);
    limits.set(.bytes, opts.max_size);
    limits.set(.lines, opts.max_lines);
    try tw.check(.viewport_pin);
    const viewport_pin = try pool.pins.create();
    viewport_pin.* = .{ .node = page_list.first.? };
    try tw.check(.viewport_pin_track);
    var tracked_pins = try initTrackedPins(pool.alloc, viewport_pin);
    errdefer tracked_pins.deinit(pool.alloc);
    errdefer comptime unreachable;
    const result: PageList = .{
        .cols = cols,
        .rows = rows,
        .pool = pool,
        .pages = page_list,
        .page_serial = page_serial,
        .page_serial_epoch = 0,
        .page_size = page_size,
        .limits = limits,
        .total_rows = rows,
        .tracked_pins = tracked_pins,
        .viewport = .{ .active = {} },
        .viewport_pin = viewport_pin,
        .viewport_pin_row_offset = null,
    };
    result.assertIntegrity();
    return result;
}
fn initTrackedPins(alloc: Allocator, viewport_pin: *Pin) Allocator.Error!PinSet {
    var set: PinSet = .{};
    errdefer set.deinit(alloc);
    try set.entries.setCapacity(alloc, pin_preheat);
    set.putAssumeCapacityNoClobber(viewport_pin, {});
    return set;
}
const initPages_tw = tripwire.module(enum {
    page_node,
    page_buf_std,
    page_buf_non_std,
}, initPages);
fn initPages(
    pool: *MemoryPool,
    serial: *u64,
    cols: size.CellCountInt,
    rows: size.CellCountInt,
) Allocator.Error!struct { List, usize } {
    const tw = initPages_tw;
    var page_list: List = .{};
    var page_size: usize = 0;
    const cap = initialCapacity(cols);
    const layout = Page.layout(cap);
    const pooled = layout.total_size <= std_size;
    const page_alloc = pool.pages.allocator;
    assert(layout.total_size <= size.max_page_size);
    errdefer releasePages(pool, page_list);
    var rem = rows;
    while (rem > 0) {
        try tw.check(.page_node);
        const node = try pool.nodes.create();
        errdefer pool.nodes.destroy(node);
        const page_buf = if (pooled) buf: {
            try tw.check(.page_buf_std);
            const buf = try pool.pages.create();
            terminal_mem.recommit(buf);
            break :buf buf;
        } else buf: {
            try tw.check(.page_buf_non_std);
            break :buf try page_alloc.alignedAlloc(
                u8,
                .fromByteUnits(std.heap.page_size_min),
                layout.total_size,
            );
        };
        errdefer if (pooled)
            pool.pages.destroy(page_buf)
        else
            page_alloc.free(page_buf);
        if (comptime std.debug.runtime_safety or builtin.os.tag == .freestanding)
            @memset(page_buf, 0);
        node.* = .{
            .data = .{ .resident = .initBuf(.init(page_buf), layout) },
            .serial = serial.*,
            .owned = if (pooled) .pool else .heap,
        };
        node.page().size.rows = @min(rem, node.capacity().rows);
        rem -= node.rows();
        page_list.append(node);
        page_size += page_buf.len;
        errdefer comptime unreachable;
        serial.* += 1;
    }
    assert(page_list.first != null);
    return .{ page_list, page_size };
}
pub inline fn assertIntegrity(self: *const PageList) void {
    if (comptime !build_options.slow_runtime_safety) return;
    self.verifyIntegrity() catch |err| {
        log.err("PageList integrity check failed: {}", .{err});
        @panic("PageList integrity check failed");
    };
}
pub inline fn pauseIntegrityChecks(self: *PageList, pause: bool) void {
    if (comptime !build_options.slow_runtime_safety) return;
    if (pause) {
        self.pause_integrity_checks += 1;
    } else {
        self.pause_integrity_checks -= 1;
    }
}
const IntegrityError = error{
    MaxLinesExceeded,
    PageSerialInvalid,
    TotalRowsMismatch,
    TrackedPinInvalid,
    ViewportPinOffsetMismatch,
    ViewportPinInsufficientRows,
};
fn verifyIntegrity(self: *const PageList) IntegrityError!void {
    if (comptime !build_options.slow_runtime_safety) return;
    if (self.pause_integrity_checks > 0) return;
    assert(!self.viewport_pin.garbage);
    var actual_total: usize = 0;
    {
        var node_ = self.pages.first;
        while (node_) |node| {
            actual_total += node.rows();
            node_ = node.next;
            if (node.serial < self.page_serial_epoch) {
                log.warn(
                    "PageList integrity violation: page serial predates epoch serial={} epoch={}",
                    .{ node.serial, self.page_serial_epoch },
                );
                return IntegrityError.PageSerialInvalid;
            }
        }
    }
    if (actual_total != self.total_rows) {
        log.warn(
            "PageList integrity violation: total_rows mismatch cached={} actual={}",
            .{ self.total_rows, actual_total },
        );
        return IntegrityError.TotalRowsMismatch;
    }
    if (self.total_rows > self.rows) {
        const history_rows = self.total_rows - self.rows;
        if (history_rows > self.limits.max(.lines) and
            self.pages.first.? != self.getTopLeft(.active).node)
        {
            log.warn(
                "PageList integrity violation: max lines exceeded history={} max={}",
                .{ history_rows, self.limits.max(.lines) },
            );
            return IntegrityError.MaxLinesExceeded;
        }
    }
    for (self.tracked_pins.keys()) |p| {
        if (!self.pinIsValid(p.*)) return error.TrackedPinInvalid;
    }
    if (self.viewport == .pin) {
        const actual_offset: usize = offset: {
            var offset: usize = 0;
            var node = self.pages.last;
            while (node) |n| : (node = n.prev) {
                offset += n.rows();
                if (n == self.viewport_pin.node) {
                    offset -= self.viewport_pin.y;
                    break :offset self.total_rows - offset;
                }
            }
            log.warn(
                "PageList integrity violation: viewport pin not in list",
                .{},
            );
            return error.ViewportPinOffsetMismatch;
        };
        if (self.viewport_pin_row_offset) |cached_offset| {
            if (cached_offset != actual_offset) {
                log.warn(
                    "PageList integrity violation: viewport pin offset mismatch cached={} actual={}",
                    .{ cached_offset, actual_offset },
                );
                return error.ViewportPinOffsetMismatch;
            }
        }
        const rows = self.total_rows - actual_offset;
        if (rows < self.rows) {
            log.warn(
                "PageList integrity violation: viewport pin rows too small rows={} needed={}",
                .{ rows, self.rows },
            );
            return error.ViewportPinInsufficientRows;
        }
    }
}
fn releasePages(pool: *MemoryPool, list: List) void {
    const page_alloc = pool.pages.allocator;
    var it = list.first;
    while (it) |node| {
        it = node.next;
        const page = node.restore(.discard);
        switch (node.owned) {
            .pool => releasePoolPage(pool, page),
            .heap => page_alloc.free(page.memory),
        }
        pool.nodes.destroy(node);
    }
}
fn releasePoolPage(pool: *MemoryPool, page: *const Page) void {
    const item: *align(std.heap.page_size_min) [std_size]u8 =
        @ptrCast(@alignCast(page.memory.ptr));
    if (comptime wasm_page_pool) {
        _ = terminal_mem.decommit(.zero, item, page.memory.len);
        pool.pages.destroy(item);
        return;
    }
    pool.pages.release(item);
}
pub fn deinit(self: *PageList) void {
    self.assertIntegrity();
    self.tracked_pins.deinit(self.pool.alloc);
    releasePages(&self.pool, self.pages);
    self.pool.deinit();
}
pub fn reset(self: *PageList) void {
    defer self.assertIntegrity();
    self.page_compression.reset();
    self.page_serial_epoch = self.page_serial;
    const cap = initialCapacity(self.cols);
    assert(cap.rows > 0);
    const page_count = std.math.divCeil(
        usize,
        self.rows,
        cap.rows,
    ) catch unreachable;
    releasePages(&self.pool, self.pages);
    _ = self.pool.pages.reset(.{
        .retain_with_limit = page_count * PagePool.item_size,
    });
    _ = self.pool.nodes.reset(.{
        .retain_with_limit = page_count * NodePool.item_size,
    });
    self.pages, self.page_size = initPages(
        &self.pool,
        &self.page_serial,
        self.cols,
        self.rows,
    ) catch @panic("initPages failed");
    self.total_rows = self.rows;
    {
        var it = self.tracked_pins.iterator();
        while (it.next()) |entry| {
            const p: *Pin = entry.key_ptr.*;
            p.node = self.pages.first.?;
            p.x = 0;
            p.y = 0;
            p.garbage = true;
        }
        self.viewport_pin.garbage = false;
    }
    self.viewport = .active;
}
pub const Clone = struct {
    top: point.Point,
    bot: ?point.Point = null,
    tracked_pins: ?*TrackedPinsRemap = null,
    pub const TrackedPinsRemap = std.AutoHashMap(*Pin, *Pin);
};
pub fn clone(
    self: *const PageList,
    alloc: Allocator,
    opts: Clone,
) !PageList {
    var it = self.pageIterator(
        .right_down,
        opts.top,
        opts.bot,
    );
    var it_copy = it;
    const page_count: usize = page_count: {
        var count: usize = 0;
        while (it_copy.next()) |_| count += 1;
        break :page_count count;
    };
    var pool: MemoryPool = try .init(
        alloc,
        pageAllocator(alloc),
        page_count,
    );
    errdefer pool.deinit();
    const viewport_pin = try pool.pins.create();
    var tracked_pins = try initTrackedPins(pool.alloc, viewport_pin);
    errdefer tracked_pins.deinit(pool.alloc);
    var page_list: List = .{};
    errdefer releasePages(&pool, page_list);
    var page_serial: u64 = 0;
    var total_rows: usize = 0;
    var page_size: usize = 0;
    while (it.next()) |chunk| {
        const node = try createPageExt(
            &pool,
            .{ .cap = chunk.node.capacity() },
            &page_serial,
            &page_size,
        );
        page_list.append(node);
        const dst_page = node.page();
        const src_page = chunk.node.page();
        assert(node.capacity().rows >= chunk.end - chunk.start);
        defer dst_page.assertIntegrity();
        dst_page.size.rows = chunk.end - chunk.start;
        dst_page.size.cols = chunk.node.cols();
        try dst_page.cloneFrom(
            src_page,
            chunk.start,
            chunk.end,
        );
        dst_page.dirty = src_page.dirty;
        total_rows += node.rows();
        if (opts.tracked_pins) |remap| {
            const pin_keys = self.tracked_pins.keys();
            for (pin_keys) |p| {
                if (p.node != chunk.node or
                    p.y < chunk.start or
                    p.y >= chunk.end) continue;
                const new_p = try pool.pins.create();
                new_p.* = p.*;
                new_p.node = node;
                new_p.y -= chunk.start;
                try remap.putNoClobber(p, new_p);
                try tracked_pins.putNoClobber(pool.alloc, new_p, {});
            }
        }
    }
    viewport_pin.* = .{ .node = page_list.first.? };
    var result: PageList = .{
        .pool = pool,
        .pages = page_list,
        .page_serial = page_serial,
        .page_serial_epoch = 0,
        .page_size = page_size,
        .limits = self.limits,
        .cols = self.cols,
        .rows = self.rows,
        .total_rows = total_rows,
        .tracked_pins = tracked_pins,
        .viewport = .{ .active = {} },
        .viewport_pin = viewport_pin,
        .viewport_pin_row_offset = null,
    };
    if (total_rows < self.rows) {
        const len = self.rows - total_rows;
        for (0..len) |_| {
            _ = try result.grow();
            const last = result.pages.last.?;
            const page = last.page();
            const row = &page.rows.ptr(page.memory)[last.rows() - 1];
            page.clearCells(row, 0, result.cols);
        }
        result.total_rows = result.rows;
    }
    result.limits.enforce(&result, .lines);
    result.assertIntegrity();
    return result;
}
pub const Resize = struct {
    cols: ?size.CellCountInt = null,
    rows: ?size.CellCountInt = null,
    reflow: bool = true,
    cursor: ?Cursor = null,
    pull_scrollback: bool = true,
    pub const Cursor = struct {
        x: size.CellCountInt,
        y: size.CellCountInt,
        pin: ?*Pin = null,
    };
};
pub fn resize(self: *PageList, opts: Resize) Allocator.Error!void {
    defer self.assertIntegrity();
    self.page_compression.reset();
    self.page_compression.markActivity();
    if (comptime std.debug.runtime_safety) {
        if (opts.cols) |v| assert(v > 0);
        if (opts.rows) |v| assert(v > 0);
    }
    self.viewport_pin_row_offset = null;
    if (!opts.reflow) {
        try self.resizeWithoutReflow(opts);
        self.limits.enforce(self, .lines);
        return;
    }
    const old_limits = self.limits;
    self.limits.resize(
        opts.cols orelse self.cols,
        opts.rows orelse self.rows,
    );
    errdefer self.limits = old_limits;
    const cols = opts.cols orelse self.cols;
    switch (std.math.order(cols, self.cols)) {
        .eq => try self.resizeWithoutReflow(opts),
        .gt => {
            try self.resizeCols(cols, opts);
            try self.resizeWithoutReflow(opts);
        },
        .lt => {
            try self.resizeWithoutReflow(opts: {
                var copy = opts;
                copy.cols = self.cols;
                break :opts copy;
            });
            try self.resizeCols(cols, opts);
        },
    }
    switch (self.viewport) {
        .pin => if (self.pinIsActive(self.viewport_pin.*)) {
            self.viewport = .active;
        },
        .active, .top => {},
    }
    self.limits.enforce(self, .lines);
}
fn resizeCols(
    self: *PageList,
    cols: size.CellCountInt,
    opts: Resize,
) Allocator.Error!void {
    assert(cols != self.cols);
    const cursor = opts.cursor;
    const active_top: ?*Pin = if (!opts.pull_scrollback)
        try self.trackPin(self.getTopLeft(.active))
    else
        null;
    defer if (active_top) |p| self.untrackPin(p);
    const preserved_cursor: ?struct {
        tracked_pin: *Pin,
        untrack: bool,
        remaining_rows: usize,
        wrapped_rows: usize,
    } = if (cursor) |c| cursor: {
        const p = if (c.pin) |cursor_pin| cursor_pin.* else self.pin(.{ .active = .{
            .x = c.x,
            .y = c.y,
        } }) orelse break :cursor null;
        const active_pin = self.pin(.{ .active = .{} });
        const wrapped = wrapped: {
            var wrapped: usize = 0;
            if (active_pin) |ap| {
                if (p.before(ap)) break :wrapped 0;
            }
            var row_it = p.rowIterator(.left_up, active_pin);
            while (row_it.next()) |next| {
                const row = next.rowAndCell().row;
                if (row.wrap_continuation) wrapped += 1;
            }
            break :wrapped wrapped;
        };
        break :cursor .{
            .tracked_pin = c.pin orelse try self.trackPin(p),
            .untrack = c.pin == null,
            .remaining_rows = self.rows -| (c.y + 1),
            .wrapped_rows = wrapped,
        };
    } else null;
    defer if (preserved_cursor) |c| {
        if (c.untrack) self.untrackPin(c.tracked_pin);
    };
    self.cols = cols;
    const first_rewritten_node = node: {
        const page = self.pages.first.?.page();
        const cap = page.capacity.adjust(
            .{ .cols = cols },
        ) catch |err| err: {
            comptime assert(@TypeOf(err) == error{OutOfMemory});
            var cap = page.capacity;
            cap.cols = cols;
            cap.rows = @min(page.size.rows, cap.rows);
            break :err cap;
        };
        const node = try self.createPage(.{ .cap = cap });
        node.page().size.rows = 1;
        break :node node;
    };
    var it = self.rowIterator(
        .right_down,
        .{ .screen = .{} },
        null,
    );
    errdefer {
        var node_: ?*Node = if (it.chunk) |chunk| chunk.node else null;
        while (node_) |node| {
            node_ = node.next;
            self.destroyNode(node);
        }
    }
    defer if (self.recycle_node) |node| {
        self.recycle_node = null;
        self.destroyNode(node);
    };
    self.pages.first = first_rewritten_node;
    self.pages.last = first_rewritten_node;
    {
        var reflow_cursor: ReflowCursor = .init(first_rewritten_node);
        while (it.next()) |row| {
            try reflow_cursor.reflowRow(
                self,
                row,
                if (preserved_cursor) |c| c.tracked_pin else null,
            );
            if (row.y == row.node.rows() - 1) destroy_node: {
                if (self.recycle_node != null or
                    row.node.owned != .pool or
                    row.node.data != .resident)
                {
                    self.destroyNode(row.node);
                    break :destroy_node;
                }
                self.recycle_node = row.node;
            }
        }
        self.total_rows = reflow_cursor.total_rows;
    }
    var node_it = self.pages.first;
    var total: usize = 0;
    while (node_it) |node| : (node_it = node.next) {
        total += node.rows();
        if (total >= self.rows) break;
    } else {
        for (total..self.rows) |_| _ = try self.grow();
    }
    switch (self.viewport) {
        .active, .top => {},
        .pin => if (self.pinIsActive(self.viewport_pin.*)) {
            self.viewport = .active;
        },
    }
    if (active_top) |p| {
        if (self.pointFromPin(.active, p.*)) |pt| {
            for (0..pt.active.y) |_| _ = try self.grow();
        }
        return;
    }
    if (preserved_cursor) |c| cursor: {
        const active_pt = self.pointFromPin(
            .active,
            c.tracked_pin.*,
        ) orelse break :cursor;
        const active_pin = self.pin(.{ .active = .{} });
        const wrapped = wrapped: {
            var wrapped: usize = 0;
            var row_it = c.tracked_pin.rowIterator(.left_up, active_pin);
            while (row_it.next()) |next| {
                const row = next.rowAndCell().row;
                if (row.wrap_continuation) wrapped += 1;
            }
            break :wrapped wrapped;
        };
        const current = self.rows -| (active_pt.active.y + 1);
        var req_rows = c.remaining_rows;
        req_rows -|= wrapped -| c.wrapped_rows;
        req_rows -|= current;
        while (req_rows > 0) {
            _ = try self.grow();
            req_rows -= 1;
        }
    }
}
const ReflowCursor = struct {
    x: size.CellCountInt,
    y: size.CellCountInt,
    pending_wrap: bool,
    node: *List.Node,
    page: *pagepkg.Page,
    page_row: *pagepkg.Row,
    page_cell: *pagepkg.Cell,
    new_rows: usize,
    total_rows: usize,
    style_cache: StyleCache,
    cap_memo: ?struct {
        src_page: *const Page,
        cap: Capacity,
    },
    const StyleCache = struct {
        src_page: ?*const Page,
        src_id: stylepkg.Id,
        dst_id: stylepkg.Id,
        const invalid: StyleCache = .{
            .src_page = null,
            .src_id = stylepkg.default_id,
            .dst_id = stylepkg.default_id,
        };
    };
    fn init(node: *List.Node) ReflowCursor {
        const page = node.page();
        const rows = page.rows.ptr(page.memory);
        return .{
            .x = 0,
            .y = 0,
            .pending_wrap = false,
            .node = node,
            .page = page,
            .page_row = &rows[0],
            .page_cell = &rows[0].cells.ptr(page.memory)[0],
            .new_rows = 0,
            .total_rows = node.rows(),
            .style_cache = .invalid,
            .cap_memo = null,
        };
    }
    fn reflowRow(
        self: *ReflowCursor,
        list: *PageList,
        row: Pin,
        cursor_pin: ?*Pin,
    ) Allocator.Error!void {
        const src_page: *Page = row.node.page();
        const src_row = row.rowAndCell().row;
        const src_y = row.y;
        const cells = src_row.cells.ptr(src_page.memory)[0..src_page.size.cols];
        var cols_len = src_page.size.cols;
        if (!src_row.wrap) {
            while (cols_len > 0) {
                if (!cells[cols_len - 1].isEmpty()) break;
                cols_len -= 1;
            }
            if (cols_len == 0 and src_row.semantic_prompt != .none) cols_len = 1;
        }
        var row_has_pins = false;
        {
            const dst_x = if (self.new_rows > 0 or self.pending_wrap) 0 else self.x;
            const pin_keys = list.tracked_pins.keys();
            for (pin_keys) |p| {
                if (p.node != row.node or p.y != src_y) continue;
                row_has_pins = true;
                if (cursor_pin != null and p == cursor_pin.?) continue;
                if (p.x >= cols_len) p.x = @min(
                    p.x,
                    self.page.size.cols - 1 - dst_x,
                );
                cols_len = @max(cols_len, p.x + 1);
            }
        }
        if (cursor_pin) |p| {
            if (p.node == row.node and p.y == src_y) {
                cols_len = @max(cols_len, p.x + 1);
            }
        }
        if (cols_len == 0) {
            if (!src_row.wrap_continuation) self.new_rows += 1;
            return;
        }
        const cap: Capacity = if (self.cap_memo) |memo| cap: {
            if (memo.src_page == src_page) break :cap memo.cap;
            break :cap self.computeAndMemoizeCap(src_page);
        } else self.computeAndMemoizeCap(src_page);
        while (self.new_rows > 0) {
            try self.cursorScrollOrNewPage(list, cap);
            self.new_rows -= 1;
        }
        self.copyRowMetadata(src_row);
        var x: usize = 0;
        while (x < cols_len) {
            if (self.pending_wrap) {
                self.page_row.wrap = true;
                try self.cursorScrollOrNewPage(list, cap);
                self.copyRowMetadata(src_row);
                self.page_row.wrap_continuation = true;
            }
            if (!row_has_pins) {
                const max_run = @min(
                    cols_len - x,
                    @as(usize, self.page.size.cols) - self.x,
                );
                const window = cells[x..][0..max_run];
                const run = bulkRunLength(window);
                if (run > 0 and self.copyRun(window[0..run], src_page)) {
                    x += run;
                    continue;
                }
            }
            if (row_has_pins) {
                const pin_keys = list.tracked_pins.keys();
                for (pin_keys) |p| {
                    if (p.node != row.node or
                        p.y != src_y or
                        p.x != x) continue;
                    p.node = self.node;
                    p.x = self.x;
                    p.y = self.y;
                }
            }
            if (self.writeCell(
                list,
                &cells[x],
                src_page,
            )) |result| switch (result) {
                .success => x += 1,
                .skip_next => {
                    if (row_has_pins) for (list.tracked_pins.keys()) |p| {
                        if (p.node != row.node or
                            p.y != src_y or
                            p.x != x + 1) continue;
                        p.node = self.node;
                        p.x = self.x;
                        p.y = self.y;
                    };
                    x += 2;
                },
                .repeat => {},
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.OutOfSpace => if (self.y == 0) {
                    log.warn("reflowRow OutOfSpace on first row, discarding cell managed memory", .{});
                    x += 1;
                    self.cursorForward();
                } else {
                    try self.moveLastRowToNewPage(list, cap);
                },
            }
        }
        if (!src_row.wrap) {
            self.new_rows += 1;
        }
    }
    fn computeAndMemoizeCap(
        self: *ReflowCursor,
        src_page: *const Page,
    ) Capacity {
        const cap = src_page.capacity.adjust(
            .{ .cols = self.page.size.cols },
        ) catch |err| err: {
            comptime assert(@TypeOf(err) == error{OutOfMemory});
            var cap = src_page.capacity;
            cap.cols = self.page.size.cols;
            cap.rows = @min(src_page.size.rows, std_capacity.rows);
            break :err cap;
        };
        self.cap_memo = .{ .src_page = src_page, .cap = cap };
        return cap;
    }
    inline fn bulkCopyable(cell: pagepkg.Cell) bool {
        return switch (cell.content_tag) {
            .codepoint => copyable: {
                if (cell.wide != .narrow) break :copyable false;
                if (cell.hyperlink) break :copyable false;
                if (comptime build_options.kitty_graphics) {
                    if (cell.content.codepoint.data ==
                        kitty.graphics.unicode.placeholder)
                    {
                        break :copyable false;
                    }
                }
                break :copyable true;
            },
            .codepoint_grapheme => false,
            .bg_color_palette,
            .bg_color_rgb,
            => cell.style_id == stylepkg.default_id,
        };
    }
    const bulk_group_len = simd.lanes(u64) orelse 8;
    const BulkRunMask = pagepkg.Mask(pagepkg.Cell, &.{
        "content_tag",
        "style_id",
        "wide",
        "hyperlink",
    }, bulk_group_len);
    const PlaceholderMask = pagepkg.Mask(pagepkg.Cell, &.{
        "content.codepoint.data",
    }, bulk_group_len);
    fn bulkRunLength(cells: []const pagepkg.Cell) usize {
        if (cells.len == 0) return 0;
        const first = cells[0];
        const pair_start = first.content_tag == .codepoint and
            first.wide == .wide and
            !first.hyperlink;
        if (!pair_start and !bulkCopyable(first)) return 0;
        var proto = first;
        proto.wide = .narrow;
        const narrow_pattern = BulkRunMask.pattern(proto);
        proto.wide = .wide;
        const wide_pattern = BulkRunMask.pattern(proto);
        proto.wide = .spacer_tail;
        const tail_pattern = BulkRunMask.pattern(proto);
        const check_placeholder = build_options.kitty_graphics and
            first.content_tag == .codepoint;
        const placeholder_pattern = comptime pattern: {
            if (!build_options.kitty_graphics) break :pattern 0;
            break :pattern PlaceholderMask.pattern(.init(
                kitty.graphics.unicode.placeholder,
            ));
        };
        var len: usize = 0;
        outer: while (true) {
            while (cells.len - len >= bulk_group_len) {
                if (!BulkRunMask.eql(cells, len, narrow_pattern)) break;
                if (check_placeholder and PlaceholderMask.eqlAny(
                    cells,
                    len,
                    placeholder_pattern,
                )) break;
                len += bulk_group_len;
            }
            while (len < cells.len) {
                const cell = cells[len];
                if (BulkRunMask.eqlScalar(cell, narrow_pattern)) {
                    if (check_placeholder and PlaceholderMask.eqlScalar(
                        cell,
                        placeholder_pattern,
                    )) break :outer;
                    len += 1;
                    continue;
                }
                if (len + 1 < cells.len and
                    BulkRunMask.eqlScalar(cell, wide_pattern) and
                    BulkRunMask.eqlScalar(cells[len + 1], tail_pattern))
                {
                    len += 2;
                    continue :outer;
                }
                break :outer;
            }
            break;
        }
        return len;
    }
    fn copyRun(
        self: *ReflowCursor,
        src_cells: []const pagepkg.Cell,
        src_page: *const Page,
    ) bool {
        assert(!self.pending_wrap);
        assert(src_cells.len >= 1);
        assert(src_cells.len <= self.page.size.cols - self.x);
        const style_id = src_cells[0].style_id;
        const n: u16 = @intCast(src_cells.len);
        const dst_style_id: stylepkg.Id = if (style_id == stylepkg.default_id)
            stylepkg.default_id
        else dst: {
            if (self.style_cache.src_page == @as(?*const Page, src_page) and
                self.style_cache.src_id == style_id)
            {
                const id = self.style_cache.dst_id;
                self.page.styles.useMultiple(self.page.memory, id, n);
                break :dst id;
            }
            const style = src_page.styles.get(
                src_page.memory,
                style_id,
            ).*;
            const id = (self.page.styles.addWithId(
                self.page.memory,
                style,
                style_id,
            ) catch return false) orelse style_id;
            if (n > 1) self.page.styles.useMultiple(
                self.page.memory,
                id,
                n - 1,
            );
            self.style_cache = .{
                .src_page = src_page,
                .src_id = style_id,
                .dst_id = id,
            };
            break :dst id;
        };
        const dst_cells: []pagepkg.Cell = @as(
            [*]pagepkg.Cell,
            @ptrCast(self.page_cell),
        )[0..src_cells.len];
        @memcpy(dst_cells, src_cells);
        if (dst_style_id != style_id) {
            for (dst_cells) |*cell| cell.style_id = dst_style_id;
        }
        if (dst_style_id != stylepkg.default_id) self.page_row.styled = true;
        const cols = self.page.size.cols;
        const cell_ptr: [*]pagepkg.Cell = @ptrCast(self.page_cell);
        if (self.x + n == cols) {
            self.x = cols - 1;
            self.page_cell = @ptrCast(cell_ptr + n - 1);
            self.pending_wrap = true;
        } else {
            self.x += n;
            self.page_cell = @ptrCast(cell_ptr + n);
        }
        return true;
    }
    fn writeCell(
        self: *ReflowCursor,
        list: *PageList,
        cell: *const pagepkg.Cell,
        src_page: *const Page,
    ) IncreaseCapacityError!enum {
        success,
        repeat,
        skip_next,
    } {
        {
            errdefer comptime unreachable;
            switch (cell.content_tag) {
                .codepoint,
                .codepoint_grapheme,
                => switch (cell.wide) {
                    .narrow => self.page_cell.* = cell.*,
                    .wide => if (self.page.size.cols > 1) {
                        if (self.x == self.page.size.cols - 1) {
                            self.page_cell.* = .{
                                .content_tag = .codepoint,
                                .content = .{ .codepoint = .{ .data = 0 } },
                                .wide = .spacer_head,
                            };
                            self.cursorForward();
                            return .repeat;
                        } else {
                            self.page_cell.* = cell.*;
                        }
                    } else {
                        self.page_cell.content.codepoint = .{ .data = 0 };
                        self.page_cell.wide = .narrow;
                        self.cursorForward();
                        return .skip_next;
                    },
                    .spacer_tail => if (self.page.size.cols > 1) {
                        self.page_cell.* = cell.*;
                    } else {
                        return .success;
                    },
                    .spacer_head => {
                        return .success;
                    },
                },
                .bg_color_palette,
                .bg_color_rgb,
                => {
                    self.page_cell.* = cell.*;
                    self.cursorForward();
                    return .success;
                },
            }
            self.page_cell.content_tag = .codepoint;
            self.page_cell.hyperlink = false;
            self.page_cell.style_id = stylepkg.default_id;
            if (comptime build_options.kitty_graphics) {
                if (cell.codepoint() == kitty.graphics.unicode.placeholder) {
                    self.page_row.kitty_virtual_placeholder = true;
                }
            }
        }
        if (cell.content_tag == .codepoint_grapheme) {
            const cps = src_page.lookupGrapheme(cell).?;
            if (self.page.graphemeCount() >= self.page.graphemeCapacity()) {
                try self.increaseCapacity(
                    list,
                    .grapheme_bytes,
                );
            }
            while (true) {
                if (self.page.grapheme_alloc.alloc(
                    u21,
                    self.page.memory,
                    cps.len,
                )) |slice| {
                    self.page.grapheme_alloc.free(
                        self.page.memory,
                        slice,
                    );
                    break;
                } else |_| {
                    try self.increaseCapacity(list, .grapheme_bytes);
                }
            }
            self.page.setGraphemes(
                self.page_row,
                self.page_cell,
                cps,
            ) catch |err| {
                log.err("setGraphemes failed after capacity increase err={}", .{err});
                if (comptime std.debug.runtime_safety) {
                    unreachable;
                }
                self.page_cell.content_tag = .codepoint;
                self.page_cell.content = .{ .codepoint = .{ .data = 0xFFFD } };
            };
        }
        if (cell.hyperlink) hyperlink: {
            const src_id = src_page.lookupHyperlink(cell).?;
            const src_link = src_page.hyperlink_set.get(src_page.memory, src_id);
            if (self.page.hyperlinkCount() >= self.page.hyperlinkCapacity()) {
                try self.increaseCapacity(list, .hyperlink_bytes);
            }
            while (!self.hyperlinkStringsFit(src_link)) {
                try self.increaseCapacity(list, .string_bytes);
            }
            const dst_link = src_link.dupe(
                src_page,
                self.page,
            ) catch |err| {
                log.err("link dupe failed with capacity check err={}", .{err});
                if (comptime std.debug.runtime_safety) {
                    unreachable;
                }
                break :hyperlink;
            };
            const dst_id = self.page.hyperlink_set.addWithIdContext(
                self.page.memory,
                dst_link,
                src_id,
                .{ .page = self.page },
            ) catch |err| id: {
                dst_link.free(self.page);
                try self.increaseCapacity(list, switch (err) {
                    error.OutOfMemory => .hyperlink_bytes,
                    error.NeedsRehash => null,
                });
                while (!self.hyperlinkStringsFit(src_link)) {
                    try self.increaseCapacity(list, .string_bytes);
                }
                const dst_link2 = src_link.dupe(
                    src_page,
                    self.page,
                ) catch |err2| {
                    log.err("link dupe failed with capacity check err={}", .{err2});
                    if (comptime std.debug.runtime_safety) {
                        unreachable;
                    }
                    break :hyperlink;
                };
                break :id self.page.hyperlink_set.addWithIdContext(
                    self.page.memory,
                    dst_link2,
                    src_id,
                    .{ .page = self.page },
                ) catch |err2| {
                    log.err(
                        "addWithIdContext failed after capacity increase err={}",
                        .{err2},
                    );
                    if (comptime std.debug.runtime_safety) {
                        unreachable;
                    }
                    dst_link2.free(self.page);
                    break :hyperlink;
                };
            } orelse src_id;
            self.page.setHyperlink(
                self.page_row,
                self.page_cell,
                dst_id,
            ) catch |err| {
                log.err(
                    "setHyperlink failed after capacity increase err={}",
                    .{err},
                );
                if (comptime std.debug.runtime_safety) {
                    unreachable;
                }
                self.page.hyperlink_set.release(self.page.memory, dst_id);
                self.page_cell.hyperlink = false;
                break :hyperlink;
            };
        }
        if (cell.hasStyling()) style: {
            if (self.style_cache.src_page == src_page and
                self.style_cache.src_id == cell.style_id)
            {
                const id = self.style_cache.dst_id;
                self.page.styles.use(self.page.memory, id);
                self.page_row.styled = true;
                self.page_cell.style_id = id;
                break :style;
            }
            const style = src_page.styles.get(
                src_page.memory,
                cell.style_id,
            ).*;
            const id = self.page.styles.addWithId(
                self.page.memory,
                style,
                cell.style_id,
            ) catch |err| id: {
                try self.increaseCapacity(list, switch (err) {
                    error.OutOfMemory => .styles,
                    error.NeedsRehash => null,
                });
                break :id self.page.styles.addWithId(
                    self.page.memory,
                    style,
                    cell.style_id,
                ) catch |err2| {
                    log.err(
                        "addWithId failed after capacity increase err={}",
                        .{err2},
                    );
                    if (comptime std.debug.runtime_safety) {
                        unreachable;
                    }
                    self.page_cell.style_id = stylepkg.default_id;
                    break :style;
                };
            } orelse cell.style_id;
            self.style_cache = .{
                .src_page = src_page,
                .src_id = cell.style_id,
                .dst_id = id,
            };
            self.page_row.styled = true;
            self.page_cell.style_id = id;
        }
        self.cursorForward();
        return .success;
    }
    fn moveLastRowToNewPage(
        self: *ReflowCursor,
        list: *PageList,
        cap: Capacity,
    ) Allocator.Error!void {
        assert(self.y == self.page.size.rows - 1);
        assert(!self.pending_wrap);
        const old_node = self.node;
        const old_page = self.page;
        const old_row = self.page_row;
        const old_x = self.x;
        const old_total_rows = self.total_rows;
        defer self.total_rows = old_total_rows;
        try self.cursorNewPage(list, cap);
        assert(self.node != old_node);
        assert(self.y == 0);
        errdefer comptime unreachable;
        self.cursorAbsolute(old_x, 0);
        self.page.cloneRowFrom(
            old_page,
            self.page_row,
            old_row,
        ) catch |err| {
            log.err(
                "error cloning single row for moveLastRowToNewPage err={}",
                .{err},
            );
            @panic("unexpected copy row failure");
        };
        {
            const pin_keys = list.tracked_pins.keys();
            for (pin_keys) |p| {
                if (p.node.page() != old_page or
                    p.y != old_page.size.rows - 1) continue;
                p.node = self.node;
                p.y = self.y;
            }
        }
        old_page.resetRow(old_row);
        old_page.size.rows -= 1;
        if (old_page.size.rows == 0) {
            list.pages.remove(old_node);
            list.destroyNode(old_node);
        }
    }
    fn increaseCapacity(
        self: *ReflowCursor,
        list: *PageList,
        adjustment: ?IncreaseCapacity,
    ) IncreaseCapacityError!void {
        const old_x = self.x;
        const old_y = self.y;
        const old_total_rows = self.total_rows;
        const node = node: {
            list.pauseIntegrityChecks(true);
            defer list.pauseIntegrityChecks(false);
            break :node try list.increaseCapacity(
                self.node,
                adjustment,
            );
        };
        errdefer comptime unreachable;
        self.* = .init(node);
        self.cursorAbsolute(old_x, old_y);
        self.total_rows = old_total_rows;
    }
    fn hyperlinkStringsFit(
        self: *const ReflowCursor,
        src_link: *const hyperlink.PageEntry,
    ) bool {
        const uri_buf = self.page.string_alloc.alloc(
            u8,
            self.page.memory,
            src_link.uri.len,
        ) catch return false;
        defer self.page.string_alloc.free(self.page.memory, uri_buf);
        switch (src_link.id) {
            .implicit => {},
            .explicit => |v| {
                const id_buf = self.page.string_alloc.alloc(
                    u8,
                    self.page.memory,
                    v.len,
                ) catch return false;
                self.page.string_alloc.free(self.page.memory, id_buf);
            },
        }
        return true;
    }
    fn bottom(self: *const ReflowCursor) bool {
        return self.y == self.page.capacity.rows - 1;
    }
    fn cursorForward(self: *ReflowCursor) void {
        if (self.x == self.page.size.cols - 1) {
            self.pending_wrap = true;
        } else {
            const cell: [*]pagepkg.Cell = @ptrCast(self.page_cell);
            self.page_cell = @ptrCast(cell + 1);
            self.x += 1;
        }
    }
    fn cursorScroll(self: *ReflowCursor) void {
        assert(self.y == self.page.size.rows - 1);
        assert(self.page.size.rows < self.page.capacity.rows);
        self.page.size.rows += 1;
        const rows: [*]pagepkg.Row = @ptrCast(self.page_row);
        const row: *pagepkg.Row = @ptrCast(rows + 1);
        self.page_row = row;
        self.page_cell = &row.cells.ptr(self.page.memory)[0];
        self.pending_wrap = false;
        self.x = 0;
        self.y += 1;
    }
    fn cursorNewPage(
        self: *ReflowCursor,
        list: *PageList,
        cap: Capacity,
    ) Allocator.Error!void {
        const new_rows = self.new_rows;
        const node = try list.createPage(.{ .cap = cap });
        errdefer comptime unreachable;
        node.page().size.rows = 1;
        list.pages.insertAfter(self.node, node);
        self.* = .init(node);
        self.new_rows = new_rows;
    }
    fn cursorScrollOrNewPage(
        self: *ReflowCursor,
        list: *PageList,
        cap: Capacity,
    ) Allocator.Error!void {
        const new_total_rows: usize = self.total_rows + 1;
        defer self.total_rows = new_total_rows;
        if (self.bottom()) {
            try self.cursorNewPage(list, cap);
        } else {
            self.cursorScroll();
        }
    }
    fn cursorAbsolute(
        self: *ReflowCursor,
        x: size.CellCountInt,
        y: size.CellCountInt,
    ) void {
        assert(x < self.page.size.cols);
        assert(y < self.page.size.rows);
        const rows: [*]pagepkg.Row = @ptrCast(self.page_row);
        const row: *pagepkg.Row = switch (std.math.order(y, self.y)) {
            .eq => self.page_row,
            .lt => @ptrCast(rows - (self.y - y)),
            .gt => @ptrCast(rows + (y - self.y)),
        };
        self.page_row = row;
        self.page_cell = &row.cells.ptr(self.page.memory)[x];
        self.pending_wrap = false;
        self.x = x;
        self.y = y;
    }
    fn countTrailingEmptyCells(self: *const ReflowCursor) usize {
        if (self.page_row.wrap) return 0;
        const cells: [*]pagepkg.Cell = @ptrCast(self.page_cell);
        const len: usize = self.page.size.cols - self.x;
        for (0..len) |i| {
            const rev_i = len - i - 1;
            if (!cells[rev_i].isEmpty()) return i;
        }
        if (self.page_row.semantic_prompt != .none) return len - 1;
        return len;
    }
    fn copyRowMetadata(self: *ReflowCursor, other: *const Row) void {
        self.page_row.semantic_prompt = other.semantic_prompt;
    }
};
fn resizeWithoutReflow(self: *PageList, opts: Resize) Allocator.Error!void {
    const old_limits = self.limits;
    if (!opts.reflow) self.limits.resize(
        opts.cols orelse self.cols,
        opts.rows orelse self.rows,
    );
    errdefer self.limits = old_limits;
    if (opts.cols) |cols| {
        const old_total_rows = self.total_rows;
        defer assert(self.total_rows == old_total_rows);
        switch (std.math.order(cols, self.cols)) {
            .eq => {},
            .lt => {
                var it = self.pageIterator(.right_down, .{ .screen = .{} }, null);
                while (it.next()) |chunk| {
                    const page = chunk.node.page();
                    defer page.assertIntegrity();
                    const rows = page.rows.ptr(page.memory);
                    for (0..page.size.rows) |i| {
                        const row = &rows[i];
                        const cells = row.cells.ptr(page.memory);
                        const start = if (cells[cols - 1].wide == .wide) cols - 1 else cols;
                        page.clearCells(row, start, self.cols);
                    }
                    page.size.cols = cols;
                }
                const pin_keys = self.tracked_pins.keys();
                for (pin_keys) |p| {
                    if (p.x >= cols) p.x = cols - 1;
                }
                self.cols = cols;
            },
            .gt => {
                const old_cols = self.cols;
                var it = self.pageIterator(.right_down, .{ .screen = .{} }, null);
                while (it.next()) |chunk| {
                    self.cols = old_cols;
                    try self.resizeWithoutReflowGrowCols(cols, chunk);
                }
                self.cols = cols;
            },
        }
    }
    if (opts.rows) |rows| {
        switch (std.math.order(rows, self.rows)) {
            .eq => {},
            .lt => {
                const trimmed = self.trimTrailingBlankRows(self.rows - rows);
                self.total_rows -= trimmed;
                self.rows = rows;
            },
            .gt => gt: {
                const pull = pull: {
                    if (!opts.pull_scrollback) break :pull false;
                    const cursor = opts.cursor orelse break :pull true;
                    break :pull cursor.y >= self.rows - 1;
                };
                if (!pull) {
                    const delta = rows - self.rows;
                    self.rows = rows;
                    for (0..delta) |_| _ = try self.grow();
                    break :gt;
                }
                self.rows = rows;
                var count: usize = 0;
                var page = self.pages.first;
                while (page) |p| : (page = p.next) {
                    count += p.rows();
                    if (count >= rows) break;
                } else {
                    assert(count < rows);
                    for (count..rows) |_| _ = try self.grow();
                }
                switch (self.viewport) {
                    .pin => if (self.pinIsActive(self.viewport_pin.*)) {
                        self.viewport = .active;
                    },
                    .active, .top => {},
                }
            },
        }
        if (build_options.slow_runtime_safety) {
            assert(self.totalRows() >= self.rows);
        }
    }
}
fn resizeWithoutReflowGrowCols(
    self: *PageList,
    cols: size.CellCountInt,
    chunk: PageIterator.Chunk,
) Allocator.Error!void {
    assert(cols > self.cols);
    const page = chunk.node.page();
    const old_cols = self.cols;
    self.cols = cols;
    errdefer self.cols = old_cols;
    if (page.capacity.cols >= cols) fast: {
        const rows = page.rows.ptr(page.memory)[0..page.size.rows];
        for (rows) |*row| {
            const cells = page.getCells(row);
            if (cells[old_cols - 1].wide == .spacer_head) break :fast;
        }
        page.size.cols = cols;
        return;
    }
    const cap = page.capacity.adjust(
        .{ .cols = cols },
    ) catch |err| err: {
        comptime assert(@TypeOf(err) == error{OutOfMemory});
        var cap = page.capacity;
        cap.cols = cols;
        cap.rows = @min(page.size.rows, cap.rows);
        break :err cap;
    };
    const prev = chunk.node.prev;
    errdefer {
        var current = chunk.node.prev;
        while (current) |p| {
            if (current == prev) break;
            current = p.prev;
            self.pages.remove(p);
            self.destroyNode(p);
        }
    }
    var copied: size.CellCountInt = 0;
    if (prev) |prev_node| prev: {
        const prev_page = prev_node.page();
        if (prev_page.size.rows >= prev_page.capacity.rows) break :prev;
        const len = @min(
            prev_page.capacity.rows - prev_page.size.rows,
            page.size.rows,
        );
        const src_rows = page.rows.ptr(page.memory)[0..len];
        const dst_rows = prev_page.rows.ptr(prev_page.memory)[prev_page.size.rows..];
        for (dst_rows, src_rows) |*dst_row, *src_row| {
            prev_page.size.rows += 1;
            copied += 1;
            prev_page.cloneRowFrom(
                page,
                dst_row,
                src_row,
            ) catch {
                prev_page.size.rows -= 1;
                copied -= 1;
                break :prev;
            };
        }
        assert(copied == len);
        assert(prev_page.size.rows <= prev_page.capacity.rows);
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node != chunk.node or p.y >= len) continue;
            p.node = prev_node;
            p.y += prev_page.size.rows - len;
        }
    }
    const prev_copied = copied;
    errdefer if (prev_copied > 0) {
        const prev_page = prev.?.page();
        const prev_size = prev_page.size.rows - prev_copied;
        const prev_rows = prev_page.rows.ptr(prev_page.memory)[prev_size..prev_page.size.rows];
        for (prev_rows) |*row| prev_page.resetRow(row);
        prev_page.size.rows = prev_size;
    };
    errdefer {
        var it = chunk.node.prev;
        while (it) |node| {
            if (node == prev) break;
            it = node.prev;
            self.pages.remove(node);
            self.destroyNode(node);
        }
    }
    while (copied < page.size.rows) {
        const new_node = try self.createPage(.{ .cap = cap });
        const new_page = new_node.page();
        defer new_page.assertIntegrity();
        const len = @min(cap.rows, page.size.rows - copied);
        const y_start = copied;
        const src_rows = page.rows.ptr(page.memory)[y_start .. copied + len];
        const dst_rows = new_page.rows.ptr(new_page.memory)[0..len];
        for (dst_rows, src_rows) |*dst_row, *src_row| {
            new_page.size.rows += 1;
            if (new_page.cloneRowFrom(
                page,
                dst_row,
                src_row,
            )) |_| {
                copied += 1;
            } else |err| {
                log.warn(
                    "unexpected cloneRowFrom failure during resizeWithoutReflowGrowCols: {}",
                    .{err},
                );
                new_page.size.rows -= 1;
                break;
            }
        }
        const y_end = copied;
        self.pages.insertBefore(chunk.node, new_node);
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node != chunk.node or
                p.y < y_start or
                p.y >= y_end) continue;
            p.node = new_node;
            p.y -= y_start;
        }
    }
    assert(copied == page.size.rows);
    errdefer comptime unreachable;
    self.pages.remove(chunk.node);
    self.destroyNode(chunk.node);
}
fn trailingBlankLines(
    self: *const PageList,
    max: size.CellCountInt,
) size.CellCountInt {
    var count: size.CellCountInt = 0;
    var it = self.pages.last;
    while (it) |node| : (it = node.prev) {
        const page = node.page();
        const len = node.rows();
        const rows = page.rows.ptr(page.memory)[0..len];
        for (0..len) |i| {
            const rev_i = len - i - 1;
            const cells = rows[rev_i].cells.ptr(page.memory)[0..node.cols()];
            if (pagepkg.Cell.hasTextAny(cells)) return count;
            count += 1;
            if (count >= max) return count;
        }
    }
    return count;
}
fn trimTrailingBlankRows(
    self: *PageList,
    max: size.CellCountInt,
) size.CellCountInt {
    var trimmed: size.CellCountInt = 0;
    var invalidated_node: ?*List.Node = null;
    const bl_pin = self.getBottomRight(.screen).?;
    var it = bl_pin.rowIterator(.left_up, null);
    while (it.next()) |row_pin| {
        const cells = row_pin.cells(.all);
        if (pagepkg.Cell.hasTextAny(cells)) return trimmed;
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node != row_pin.node or
                p.y != row_pin.y) continue;
            return trimmed;
        }
        if (row_pin.node.rows() > 1 and invalidated_node != row_pin.node) {
            self.invalidateNodeLayout(row_pin.node);
            invalidated_node = row_pin.node;
        }
        row_pin.node.page().resetRow(row_pin.rowAndCell().row);
        row_pin.node.page().size.rows -= 1;
        if (row_pin.node.page().size.rows == 0) {
            self.erasePage(row_pin.node);
        } else {
            row_pin.node.page().assertIntegrity();
        }
        trimmed += 1;
        if (trimmed >= max) return trimmed;
    }
    return trimmed;
}
pub const Scroll = union(enum) {
    active,
    top,
    row: usize,
    delta_row: isize,
    delta_prompt: isize,
    pin: Pin,
};
pub fn scroll(self: *PageList, behavior: Scroll) void {
    defer self.assertIntegrity();
    if (self.limits.bytes.explicit == 0) {
        self.viewport = .active;
        return;
    }
    defer {
        self.page_compression.reset();
        self.page_compression.markActivity();
    }
    switch (behavior) {
        .active => self.viewport = .active,
        .top => self.viewport = .top,
        .pin => |p| {
            if (self.pinIsActive(p)) {
                self.viewport = .active;
                return;
            } else if (self.pinIsTop(p)) {
                self.viewport = .top;
                return;
            }
            self.viewport_pin.* = p;
            self.viewport = .pin;
            self.viewport_pin_row_offset = null;
        },
        .row => |n| row: {
            if (n == 0) {
                self.viewport = .top;
                break :row;
            }
            if (n >= self.total_rows - self.rows) {
                self.viewport = .active;
                break :row;
            }
            switch (self.viewport) {
                .top, .active => {},
                .pin => if (self.viewport_pin_row_offset) |*v| {
                    const delta: isize = delta: {
                        const n_isize: isize = @intCast(n);
                        const v_isize: isize = @intCast(v.*);
                        break :delta n_isize - v_isize;
                    };
                    self.scroll(.{ .delta_row = delta });
                    return;
                },
            }
            self.viewport_pin_row_offset = n;
            self.viewport = .pin;
            const midpoint = self.total_rows / 2;
            if (n < midpoint) {
                var node_it = self.pages.first;
                var rem: usize = n;
                while (node_it) |node| : (node_it = node.next) {
                    if (rem < node.rows()) {
                        self.viewport_pin.* = .{
                            .node = node,
                            .y = std.math.cast(size.CellCountInt, rem) orelse {
                                self.viewport = .active;
                                break :row;
                            },
                        };
                        break :row;
                    }
                    rem -= node.rows();
                }
            } else {
                var node_it = self.pages.last;
                var rem: usize = self.total_rows - n;
                while (node_it) |node| : (node_it = node.prev) {
                    if (rem <= node.rows()) {
                        self.viewport_pin.* = .{
                            .node = node,
                            .y = std.math.cast(size.CellCountInt, node.rows() - rem) orelse {
                                self.viewport = .active;
                                break :row;
                            },
                        };
                        break :row;
                    }
                    rem -= node.rows();
                }
            }
            self.viewport = .active;
        },
        .delta_prompt => |n| self.scrollPrompt(n),
        .delta_row => |n| delta_row: {
            const amount: usize = @abs(n);
            switch (self.viewport) {
                .top => if (n <= 0) break :delta_row,
                .active => if (n >= 0) break :delta_row,
                .pin => switch (std.math.order(n, 0)) {
                    .eq => break :delta_row,
                    .lt => switch (self.viewport_pin.upOverflow(amount)) {
                        .offset => |new_pin| {
                            self.viewport_pin.* = new_pin;
                            if (self.viewport_pin_row_offset) |*v| {
                                v.* -= amount;
                            }
                            break :delta_row;
                        },
                        .overflow => {
                            self.viewport = .top;
                            break :delta_row;
                        },
                    },
                    .gt => switch (self.viewport_pin.downOverflow(amount)) {
                        .offset => |new_pin| {
                            if (self.pinIsActive(new_pin)) {
                                self.viewport = .active;
                            } else {
                                self.viewport_pin.* = new_pin;
                                if (self.viewport_pin_row_offset) |*v| {
                                    v.* += amount;
                                }
                            }
                            break :delta_row;
                        },
                        .overflow => {
                            self.viewport = .active;
                            break :delta_row;
                        },
                    },
                },
            }
            const top = self.getTopLeft(.viewport);
            const p: Pin = if (n < 0) switch (top.upOverflow(amount)) {
                .offset => |v| v,
                .overflow => |v| v.end,
            } else switch (top.downOverflow(amount)) {
                .offset => |v| v,
                .overflow => |v| v.end,
            };
            if (self.pinIsActive(p)) {
                self.viewport = .active;
                return;
            }
            if (self.pinIsTop(p)) {
                self.viewport = .top;
                return;
            }
            self.viewport_pin.* = p;
            self.viewport = .pin;
            self.viewport_pin_row_offset = null;
        },
    }
}
fn scrollPrompt(self: *PageList, delta: isize) void {
    if (delta == 0) return;
    const delta_start: usize = @abs(delta);
    var delta_rem: usize = delta_start;
    const start_pin = start: {
        const tl = self.getTopLeft(.viewport);
        if (delta <= 0) break :start tl.up(1) orelse return;
        var adjusted: Pin = tl.down(1) orelse return;
        if (tl.rowAndCell().row.semantic_prompt != .none) skip: {
            while (adjusted.rowAndCell().row.semantic_prompt == .prompt_continuation) {
                adjusted = adjusted.down(1) orelse break :skip;
            }
        }
        break :start adjusted;
    };
    var it = start_pin.promptIterator(
        if (delta > 0) .right_down else .left_up,
        null,
    );
    var prompt_pin: ?Pin = null;
    while (it.next()) |next| {
        prompt_pin = next;
        delta_rem -= 1;
        if (delta_rem == 0) break;
    }
    if (prompt_pin) |p| {
        if (self.pinIsActive(p)) {
            self.viewport = .active;
        } else {
            self.viewport_pin.* = p;
            self.viewport = .pin;
            self.viewport_pin_row_offset = null;
        }
    }
}
pub fn scrollClear(self: *PageList) Allocator.Error!void {
    defer self.assertIntegrity();
    const non_empty: usize = non_empty: {
        var page = self.pages.last.?;
        var n: usize = 0;
        while (true) {
            const current_page = page.page();
            const rows: [*]Row = current_page.rows.ptr(current_page.memory);
            for (0..page.rows()) |i| {
                const rev_i = page.rows() - i - 1;
                const row = rows[rev_i];
                const cells = row.cells.ptr(current_page.memory)[0..self.cols];
                for (cells) |cell| {
                    if (!cell.isEmpty()) break :non_empty self.rows - n;
                }
                n += 1;
                if (n > self.rows) break :non_empty 0;
            }
            page = page.prev orelse break :non_empty 0;
        }
    };
    for (0..non_empty) |_| _ = try self.grow();
}
pub fn invalidateNodeLayout(self: *PageList, node: *List.Node) void {
    node.serial = self.page_serial;
    self.page_serial += 1;
}
pub fn compact(self: *PageList, node: *List.Node) Allocator.Error!?*List.Node {
    defer self.assertIntegrity();
    const page: *Page = node.page();
    assert(page.size.rows > 0);
    const req_cap = page.exactRowCapacity(0, page.size.rows);
    const new_size = Page.layout(req_cap).total_size;
    const old_size: usize = switch (node.owned) {
        .pool => PagePool.item_size,
        .heap => page.memory.len,
    };
    if (new_size >= old_size) return null;
    const new_node = try self.createPage(.{
        .cap = req_cap,
        .exact_size = true,
    });
    errdefer self.destroyNode(new_node);
    const new_page: *Page = new_node.page();
    new_page.size = page.size;
    new_page.dirty = page.dirty;
    new_page.cloneFrom(
        page,
        0,
        page.size.rows,
    ) catch |err| {
        log.err("compact clone failed err={}", .{err});
        self.destroyNode(new_node);
        return null;
    };
    const pin_keys = self.tracked_pins.keys();
    for (pin_keys) |p| {
        if (p.node != node) continue;
        p.node = new_node;
    }
    self.pages.insertBefore(node, new_node);
    self.pages.remove(node);
    self.destroyNode(node);
    self.page_compression.markActivity();
    new_page.assertIntegrity();
    return new_node;
}
pub const SplitError = error{
    OutOfMemory,
    OutOfSpace,
};
pub fn split(
    self: *PageList,
    p: Pin,
) SplitError!void {
    if (build_options.slow_runtime_safety) assert(self.pinIsValid(p));
    const original_node = p.node;
    const page: *Page = original_node.page();
    if (page.size.rows <= 1) return error.OutOfSpace;
    if (p.y == 0) return;
    defer self.assertIntegrity();
    const target = try self.createPage(.{ .cap = page.capacity });
    errdefer self.destroyNode(target);
    const y_start = p.y;
    const y_end = page.size.rows;
    target.page().size.rows = y_end - y_start;
    assert(target.rows() <= target.capacity().rows);
    target.page().cloneFrom(page, y_start, y_end) catch |err| {
        log.err(
            "error cloning rows for split err={}",
            .{err},
        );
        return error.OutOfSpace;
    };
    errdefer comptime unreachable;
    self.invalidateNodeLayout(original_node);
    self.page_compression.markActivity();
    for (self.tracked_pins.keys()) |tracked| {
        if (tracked.node.page() != page or
            tracked.y < p.y) continue;
        tracked.node = target;
        tracked.y -= p.y;
    }
    for (page.rows.ptr(page.memory)[y_start..y_end]) |*row| {
        page.resetRow(row);
    }
    page.size.rows -= y_end - y_start;
    self.pages.insertAfter(original_node, target);
}
pub const Scrollbar = struct {
    total: usize,
    offset: usize,
    len: usize,
    pub const zero: Scrollbar = .{
        .total = 0,
        .offset = 0,
        .len = 0,
    };
    pub const C = extern struct {
        total: u64,
        offset: u64,
        len: u64,
    };
    pub fn cval(self: Scrollbar) C {
        return .{
            .total = @intCast(self.total),
            .offset = @intCast(self.offset),
            .len = @intCast(self.len),
        };
    }
    pub fn eql(self: Scrollbar, other: Scrollbar) bool {
        return self.total == other.total and
            self.offset == other.offset and
            self.len == other.len;
    }
};
pub fn scrollbar(self: *PageList) Scrollbar {
    if (self.limits.bytes.explicit == 0) return .{
        .total = self.rows,
        .offset = 0,
        .len = self.rows,
    };
    return .{
        .total = self.total_rows,
        .offset = self.viewportRowOffset(),
        .len = self.rows,
    };
}
fn viewportRowOffset(self: *PageList) usize {
    return switch (self.viewport) {
        .top => 0,
        .active => self.total_rows - self.rows,
        .pin => pin: {
            defer self.assertIntegrity();
            if (self.viewport_pin_row_offset) |cached| break :pin cached;
            const top_offset: usize = offset: {
                var offset: usize = 0;
                var node = self.pages.last;
                while (node) |n| : (node = n.prev) {
                    offset += n.rows();
                    if (n == self.viewport_pin.node) {
                        assert(n.rows() > self.viewport_pin.y);
                        offset -= self.viewport_pin.y;
                        break :offset self.total_rows - offset;
                    }
                }
                unreachable;
            };
            self.viewport_pin_row_offset = top_offset;
            break :pin top_offset;
        },
    };
}
fn fixupViewport(
    self: *PageList,
    removed: usize,
) void {
    self.viewport_pin.garbage = false;
    switch (self.viewport) {
        .active => {},
        .pin => if (self.pinIsActive(self.viewport_pin.*)) {
            self.viewport = .active;
        } else if (self.viewport_pin_row_offset) |*v| {
            if (v.* < removed) {
                self.viewport = .top;
            } else {
                v.* -= removed;
            }
        },
        .top => if (self.pinIsActive(.{ .node = self.pages.first.? })) {
            self.viewport = .active;
        },
    }
}
pub fn setMaxBytes(self: *PageList, max: ?usize) void {
    defer self.assertIntegrity();
    self.limits.set(.bytes, max);
    self.limits.enforce(self, .bytes);
    if (self.limits.bytes.explicit == 0) self.viewport = .active;
}
pub fn setMaxLines(self: *PageList, max: ?usize) void {
    defer self.assertIntegrity();
    self.limits.set(.lines, max);
    self.limits.enforce(self, .lines);
}
pub fn grow(self: *PageList) Allocator.Error!?*List.Node {
    defer self.assertIntegrity();
    self.page_compression.markActivity();
    const last = self.pages.last.?;
    if (last.capacity().rows > last.rows()) {
        const page = last.page();
        page.size.rows += 1;
        page.assertIntegrity();
        self.total_rows += 1;
        self.limits.enforce(self, .lines);
        return null;
    }
    const cap = initialCapacity(self.cols);
    if (self.pages.first != null and
        self.pages.first != self.pages.last and
        self.page_size + PagePool.item_size > self.limits.max(.bytes))
    prune: {
        const first = self.pages.popFirst().?;
        assert(first != last);
        self.total_rows -= first.rows();
        if (self.total_rows + 1 < self.rows) {
            self.pages.prepend(first);
            assert(self.pages.first == first);
            self.total_rows += first.rows();
            break :prune;
        }
        if (self.viewport == .pin) viewport: {
            if (self.viewport_pin_row_offset) |*v| {
                if (v.* < first.rows()) {
                    self.viewport = .top;
                    break :viewport;
                }
                v.* -= first.rows();
            }
        }
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node != first) continue;
            p.node = self.pages.first.?;
            p.y = 0;
            p.x = 0;
            p.garbage = true;
        }
        self.viewport_pin.garbage = false;
        switch (first.owned) {
            .pool => {},
            .heap => {
                self.destroyNode(first);
                break :prune;
            },
        }
        const buf = first.restore(.discard).memory;
        @memset(buf, 0);
        assert(buf.len <= std_size);
        first.data = .{ .resident = .initBuf(.init(buf), Page.layout(cap)) };
        const page = first.page();
        page.size.rows = 1;
        self.pages.insertAfter(last, first);
        self.total_rows += 1;
        first.serial = self.page_serial;
        self.page_serial += 1;
        page.assertIntegrity();
        self.limits.enforce(self, .lines);
        return first;
    }
    const next_node = try self.createPage(.{ .cap = cap });
    self.pages.append(next_node);
    const page = next_node.page();
    page.size.rows = 1;
    page.assertIntegrity();
    self.total_rows += 1;
    self.limits.enforce(self, .lines);
    return next_node;
}
pub const IncreaseCapacity = enum {
    styles,
    grapheme_bytes,
    hyperlink_bytes,
    string_bytes,
    pub fn forCloneError(err: Page.CloneFromError) ?IncreaseCapacity {
        return switch (err) {
            error.StyleSetNeedsRehash,
            error.HyperlinkSetNeedsRehash,
            => null,
            error.StyleSetOutOfMemory,
            => .styles,
            error.StringAllocOutOfMemory,
            => .string_bytes,
            error.HyperlinkSetOutOfMemory,
            error.HyperlinkMapOutOfMemory,
            => .hyperlink_bytes,
            error.GraphemeMapOutOfMemory,
            error.GraphemeAllocOutOfMemory,
            => .grapheme_bytes,
        };
    }
};
pub const IncreaseCapacityError = error{
    OutOfMemory,
    OutOfSpace,
};
pub fn increaseCapacity(
    self: *PageList,
    node: *List.Node,
    adjustment: ?IncreaseCapacity,
) IncreaseCapacityError!*List.Node {
    defer self.assertIntegrity();
    const page: *Page = node.page();
    var cap = page.capacity;
    if (adjustment) |v| switch (v) {
        inline else => |tag| {
            const field_name = @tagName(tag);
            const Int = @FieldType(Capacity, field_name);
            const old = @field(cap, field_name);
            const new: Int = new: {
                if (old == 0) {
                    const default: Capacity = .{ .cols = 0, .rows = 0 };
                    break :new @field(default, field_name);
                }
                break :new std.math.mul(
                    Int,
                    old,
                    2,
                ) catch |err| overflow: {
                    comptime assert(@TypeOf(err) == error{Overflow});
                    if (old < std.math.maxInt(Int)) break :overflow std.math.maxInt(Int);
                    return error.OutOfSpace;
                };
            };
            @field(cap, field_name) = new;
            const layout = Page.layout(cap);
            if (layout.total_size > size.max_page_size) {
                return error.OutOfSpace;
            }
            project: {
                const used: u64 = switch (comptime tag) {
                    .grapheme_bytes => page.grapheme_alloc.usedBytes(page.memory),
                    .styles => page.styles.count(),
                    else => break :project,
                };
                if (used == 0 or page.size.rows == 0) break :project;
                const density = used * @as(u64, cap.rows) / page.size.rows;
                const projected_raw = density + density / 4;
                const projected = @min(
                    projected_raw,
                    @as(u64, old) * 32,
                    std.math.maxInt(Int),
                );
                if (projected <= @field(cap, field_name)) break :project;
                var proj_cap = cap;
                @field(proj_cap, field_name) = @intCast(projected);
                if (Page.layout(proj_cap).total_size > size.max_page_size)
                    break :project;
                cap = proj_cap;
            }
        },
    };
    log.debug("adjusting page capacity={}", .{cap});
    const new_node = try self.createPage(.{ .cap = cap });
    errdefer self.destroyNode(new_node);
    const new_page: *Page = new_node.page();
    assert(new_page.capacity.rows >= page.capacity.rows);
    assert(new_page.capacity.cols >= page.capacity.cols);
    new_page.size.rows = page.size.rows;
    new_page.size.cols = page.size.cols;
    new_page.cloneFrom(
        page,
        0,
        page.size.rows,
    ) catch |err| {
        log.err("increaseCapacity clone failed err={}", .{err});
        @panic("unexpected clone failure");
    };
    new_page.dirty = page.dirty;
    errdefer comptime unreachable;
    const pin_keys = self.tracked_pins.keys();
    for (pin_keys) |p| {
        if (p.node != node) continue;
        p.node = new_node;
    }
    self.pages.insertBefore(node, new_node);
    self.pages.remove(node);
    self.destroyNode(node);
    self.page_compression.markActivity();
    new_page.assertIntegrity();
    return new_node;
}
pub fn allocatePage(
    self: *PageList,
    capacity: Capacity,
) Allocator.Error!PageAllocation {
    return .{
        .destination = self,
        .node = try createPageExt(
            &self.pool,
            .{ .cap = capacity },
            &self.page_serial,
            null,
        ),
    };
}
pub const PageAllocation = struct {
    destination: *PageList,
    node: ?*List.Node,
    pub fn page(self: *PageAllocation) *Page {
        return self.node.?.pageAssumeResident();
    }
    pub fn deinit(self: *PageAllocation) void {
        const node = self.node orelse return;
        destroyNodeExt(
            &self.destination.pool,
            node,
            null,
        );
        self.node = null;
    }
    pub const Location = union(enum) {
        prepend,
    };
    pub const FinalizeOptions = struct {
        compress: bool = false,
    };
    pub fn finalize(
        self: *PageAllocation,
        location: Location,
        options: FinalizeOptions,
    ) FinalizeError!void {
        switch (location) {
            .prepend => return try self.prepend(options),
        }
    }
    pub const FinalizeError = error{
        InvalidPageDimensions,
        RowCountOverflow,
        PageSizeOverflow,
        MaxSizeExceeded,
        MaxLinesExceeded,
    };
    fn prepend(self: *PageAllocation, options: FinalizeOptions) FinalizeError!void {
        const destination = self.destination;
        const node = self.node.?;
        if (node.cols() == 0 or node.rows() == 0) return error.InvalidPageDimensions;
        const total_rows = std.math.add(
            usize,
            destination.total_rows,
            node.rows(),
        ) catch return error.RowCountOverflow;
        const node_size: usize = switch (node.owned) {
            .pool => PagePool.item_size,
            .heap => node.pageAssumeResident().memory.len,
        };
        const page_size = std.math.add(
            usize,
            destination.page_size,
            node_size,
        ) catch return error.PageSizeOverflow;
        if (page_size > destination.limits.max(.bytes)) {
            return error.MaxSizeExceeded;
        }
        if (total_rows - destination.rows > destination.limits.max(.lines)) {
            return error.MaxLinesExceeded;
        }
        errdefer comptime unreachable;
        destination.pages.prepend(node);
        destination.page_size = page_size;
        destination.total_rows = total_rows;
        if (destination.viewport == .pin) {
            if (destination.viewport_pin_row_offset) |*offset| {
                offset.* += node.rows();
            }
        }
        destination.page_compression.markActivity();
        destination.assertIntegrity();
        self.node = null;
        if (options.compress and
            terminal_mem.canReclaim(.strict) and
            destination.getTopLeft(.viewport).node != node)
        {
            _ = destination.compressPage(node);
        }
    }
};
const CreatePage = struct {
    cap: Capacity,
    exact_size: bool = false,
};
inline fn createPage(
    self: *PageList,
    opts: CreatePage,
) Allocator.Error!*List.Node {
    if (self.recycle_node) |node| recycle: {
        if (opts.exact_size) break :recycle;
        if (node.owned != .pool) break :recycle;
        if (node.data != .resident) break :recycle;
        const layout = Page.layout(opts.cap);
        if (layout.total_size > std_size) break :recycle;
        self.recycle_node = null;
        const page = &node.data.resident;
        const item: *align(std.heap.page_size_min) [std_size]u8 =
            @ptrCast(@alignCast(page.memory.ptr));
        @memset(page.memory, 0);
        node.* = .{
            .data = .{ .resident = .initBuf(.init(item), layout) },
            .serial = self.page_serial,
            .owned = .pool,
        };
        node.page().size.rows = 0;
        self.page_serial += 1;
        return node;
    }
    return try createPageExt(
        &self.pool,
        opts,
        &self.page_serial,
        &self.page_size,
    );
}
inline fn createPageExt(
    pool: *MemoryPool,
    opts: CreatePage,
    serial: *u64,
    total_size: ?*usize,
) Allocator.Error!*List.Node {
    var page = try pool.nodes.create();
    errdefer pool.nodes.destroy(page);
    const layout = Page.layout(opts.cap);
    const pooled = !opts.exact_size and layout.total_size <= std_size;
    const page_alloc = pool.pages.allocator;
    assert(layout.total_size <= size.max_page_size);
    const page_buf = if (pooled) buf: {
        const buf = try pool.pages.create();
        terminal_mem.recommit(buf);
        break :buf buf;
    } else try page_alloc.alignedAlloc(
        u8,
        .fromByteUnits(std.heap.page_size_min),
        layout.total_size,
    );
    errdefer if (pooled)
        pool.pages.destroy(page_buf)
    else
        page_alloc.free(page_buf);
    if (comptime std.debug.runtime_safety or builtin.os.tag == .freestanding)
        @memset(page_buf, 0);
    page.* = .{
        .data = .{ .resident = .initBuf(.init(page_buf), layout) },
        .serial = serial.*,
        .owned = if (pooled) .pool else .heap,
    };
    page.page().size.rows = 0;
    serial.* += 1;
    if (total_size) |v| {
        v.* += page_buf.len;
    }
    return page;
}
const CompressionScratch = union(enum) {
    pooled: *align(std.heap.page_size_min) [std_size]u8,
    allocated: []align(std.heap.page_size_min) u8,
    fn init(
        pool: *MemoryPool,
        required: usize,
        raw_len: usize,
    ) Allocator.Error!CompressionScratch {
        assert(required <= raw_len);
        if (required <= std_size) {
            const memory = try pool.pages.create();
            terminal_mem.recommit(memory);
            return .{ .pooled = memory };
        }
        const page_alloc = pool.pages.allocator;
        return .{ .allocated = try page_alloc.alignedAlloc(
            u8,
            .fromByteUnits(std.heap.page_size_min),
            raw_len,
        ) };
    }
    fn bytes(self: *CompressionScratch) []u8 {
        return switch (self.*) {
            .pooled => |memory| memory,
            .allocated => |memory| memory,
        };
    }
    fn deinit(
        self: *CompressionScratch,
        pool: *MemoryPool,
        dirty_len: usize,
    ) void {
        switch (self.*) {
            .pooled => |memory| {
                _ = terminal_mem.decommit(.zero, memory, dirty_len);
                pool.pages.destroy(memory);
            },
            .allocated => |memory| {
                const page_alloc = pool.pages.allocator;
                page_alloc.free(memory);
            },
        }
    }
};
const IncrementalCompressionState = struct {
    flags: packed struct {
        did_compress: bool = false,
        verifying: bool = false,
    } = .{},
    activity_serial: u48 = 0,
    last_serial: ?u64 = null,
    next_serial: u64 = 0,
    fn markActivity(self: *IncrementalCompressionState) void {
        self.activity_serial +%= 1;
    }
    fn reset(self: *IncrementalCompressionState) void {
        const activity_serial: u48 = self.activity_serial;
        self.* = .{ .activity_serial = activity_serial };
    }
};
pub const IncrementalCompressionResult = enum {
    unsupported,
    pending,
    complete,
};
const CompressionIterator = struct {
    current: *List.Node,
    active: *List.Node,
    viewport_first: *List.Node,
    viewport_last: *List.Node,
    fn init(self: *const PageList) CompressionIterator {
        return .{
            .current = self.pages.first.?,
            .active = self.getTopLeft(.active).node,
            .viewport_first = self.getTopLeft(.viewport).node,
            .viewport_last = self.getBottomRight(.viewport).?.node,
        };
    }
    fn next(self: *CompressionIterator) ?*List.Node {
        while (self.current != self.active) {
            if (self.current == self.viewport_first) {
                while (self.current != self.active and
                    self.current != self.viewport_last)
                {
                    self.current = self.current.next.?;
                }
                if (self.current == self.active) return null;
                self.current = self.current.next.?;
                continue;
            }
            const node = self.current;
            self.current = node.next.?;
            return node;
        }
        return null;
    }
    fn done(self: *const CompressionIterator) bool {
        return self.current == self.active;
    }
};
const incremental_compression_max_inspected = 8;
const compressPage_tw = tripwire.module(
    enum { decommit },
    error{DecommitFailed},
);
pub fn compress(
    self: *PageList,
    mode: enum { incremental, drain, full },
) IncrementalCompressionResult {
    return switch (mode) {
        .incremental => self.compressIncremental(),
        .drain => while (true) switch (self.compressIncremental()) {
            .pending => continue,
            .complete => break .complete,
            .unsupported => break .unsupported,
        },
        .full => full: {
            if (!terminal_mem.canReclaim(.strict)) {
                self.page_compression.reset();
                break :full .unsupported;
            }
            self.compressFull();
            self.page_compression.reset();
            break :full .complete;
        },
    };
}
fn compressIncremental(self: *PageList) IncrementalCompressionResult {
    const state = &self.page_compression;
    if (!terminal_mem.canReclaim(.strict)) {
        state.reset();
        return .unsupported;
    }
    var it: CompressionIterator = .init(self);
    if (state.last_serial) |last_serial| continuation: {
        while (it.next()) |node| {
            if (node.serial >= state.next_serial) break;
            if (node.serial != last_serial) continue;
            break :continuation;
        }
        state.last_serial = null;
        it = .init(self);
    }
    state.next_serial = self.page_serial;
    var inspected_pages: usize = 0;
    while (inspected_pages < incremental_compression_max_inspected) {
        const node = it.next() orelse break;
        state.last_serial = node.serial;
        inspected_pages += 1;
        if (node.isCompressed()) continue;
        if (self.compressPage(node)) state.flags.did_compress = true;
        break;
    }
    if (!it.done()) return .pending;
    if (!state.flags.verifying or state.flags.did_compress) {
        const activity_serial: u48 = state.activity_serial;
        state.* = .{
            .flags = .{ .verifying = true },
            .activity_serial = activity_serial,
        };
        return .pending;
    }
    state.reset();
    return .complete;
}
fn compressFull(self: *PageList) void {
    var it: CompressionIterator = .init(self);
    while (it.next()) |node| {
        if (node.isCompressed()) continue;
        _ = self.compressPage(node);
    }
}
fn compressPage(self: *PageList, node: *List.Node) bool {
    if (node.isCompressed()) return false;
    const page = node.page();
    const required = compression.Page.requiredScratch(page.memory.len) catch |err|
        switch (err) {
            error.InputTooLarge,
            error.OutputTooSmall,
            => return false,
        };
    if (required == 0) return false;
    const candidate = candidate: {
        var scratch = CompressionScratch.init(
            &self.pool,
            required,
            page.memory.len,
        ) catch |err| switch (err) {
            error.OutOfMemory => return false,
        };
        var dirty_len: usize = required;
        defer scratch.deinit(&self.pool, dirty_len);
        var table: compression.lz4.HashTable = undefined;
        const result = compression.Page.init(
            self.pool.alloc,
            page,
            scratch.bytes()[0..required],
            &table,
        ) catch |err| switch (err) {
            error.OutOfMemory,
            error.InputTooLarge,
            error.OutputTooSmall,
            => return false,
        };
        if (result) |compressed| dirty_len = compressed.encoded.len;
        break :candidate result;
    };
    var compressed = candidate orelse return false;
    const decommit_allowed: bool = allowed: {
        compressPage_tw.check(.decommit) catch |err| switch (err) {
            error.DecommitFailed => break :allowed false,
        };
        break :allowed true;
    };
    if (!decommit_allowed or !terminal_mem.decommit(
        .strict,
        compressed.page.memory,
        compressed.page.memory.len,
    )) {
        compressed.deinit();
        return false;
    }
    node.data = .{ .compressed = compressed };
    return true;
}
fn destroyNode(self: *PageList, node: *List.Node) void {
    destroyNodeExt(&self.pool, node, &self.page_size);
}
fn destroyNodeExt(
    pool: *MemoryPool,
    node: *List.Node,
    total_size: ?*usize,
) void {
    const page = node.restore(.discard);
    if (total_size) |v| v.* -= switch (node.owned) {
        .pool => PagePool.item_size,
        .heap => page.memory.len,
    };
    switch (node.owned) {
        .pool => {
            assert(page.memory.len <= std_size);
            const item: *align(std.heap.page_size_min) [std_size]u8 =
                @ptrCast(@alignCast(page.memory.ptr));
            _ = terminal_mem.decommit(.zero, item, page.memory.len);
            pool.pages.destroy(item);
        },
        .heap => {
            const page_alloc = pool.pages.allocator;
            page_alloc.free(page.memory);
        },
    }
    pool.nodes.destroy(node);
}
fn cloneRowGrowCapacity(
    self: *PageList,
    node: *List.Node,
    dst_y: usize,
    src_page: *Page,
    src_row: *const Row,
) *List.Node {
    assert(src_page != node.page());
    var current = node;
    while (true) {
        const cur_page = current.page();
        const cur_rows = cur_page.rows.ptr(cur_page.memory.ptr);
        cur_page.cloneRowFrom(
            src_page,
            &cur_rows[dst_y],
            src_row,
        ) catch |err| {
            current = self.increaseCapacity(
                current,
                IncreaseCapacity.forCloneError(err),
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
pub fn eraseRow(
    self: *PageList,
    pt: point.Point,
) !void {
    defer self.assertIntegrity();
    const pn = self.pin(pt).?;
    var node = pn.node;
    var page = node.page();
    var rows = page.rows.ptr(page.memory.ptr);
    self.page_compression.markActivity();
    self.invalidateNodeLayout(node);
    fastmem.rotateOnce(Row, rows[pn.y..node.rows()]);
    {
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node == node and p.y > pn.y) p.y -= 1;
        }
    }
    self.fixupViewport(1);
    page.dirty = true;
    while (node.next) |next| {
        const next_page = next.page();
        const next_rows = next_page.rows.ptr(next_page.memory.ptr);
        _ = self.cloneRowGrowCapacity(
            node,
            node.rows() - 1,
            next_page,
            &next_rows[0],
        );
        node = next;
        page = next_page;
        rows = next_rows;
        self.invalidateNodeLayout(node);
        fastmem.rotateOnce(Row, rows[0..node.rows()]);
        page.dirty = true;
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node != node) continue;
            if (p.y == 0) {
                p.node = node.prev.?;
                p.y = p.node.rows() - 1;
                continue;
            }
            p.y -= 1;
        }
    }
    page.resetRow(&rows[node.rows() - 1]);
}
pub fn eraseRowBounded(
    self: *PageList,
    pt: point.Point,
    limit: usize,
) !void {
    defer self.assertIntegrity();
    const pn = self.pin(pt).?;
    var node: *List.Node = pn.node;
    var page = node.page();
    var rows = page.rows.ptr(page.memory.ptr);
    self.page_compression.markActivity();
    if (node.rows() - pn.y > limit) {
        self.invalidateNodeLayout(node);
        page.resetRow(&rows[pn.y]);
        fastmem.rotateOnce(Row, rows[pn.y..][0 .. limit + 1]);
        page.dirty = true;
        if (self.viewport == .pin) viewport: {
            if (self.viewport_pin_row_offset) |*v| {
                const p = self.viewport_pin;
                if (p.node != node or
                    p.y < pn.y or
                    p.y > pn.y + limit or
                    p.y == 0) break :viewport;
                v.* -= 1;
            }
        }
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node == node and
                p.y >= pn.y and
                p.y <= pn.y + limit)
            {
                if (p.y == 0) {
                    p.x = 0;
                } else {
                    p.y -= 1;
                }
            }
        }
        return;
    }
    self.invalidateNodeLayout(node);
    fastmem.rotateOnce(Row, rows[pn.y..node.rows()]);
    page.dirty = true;
    var shifted: usize = node.rows() - pn.y;
    {
        if (self.viewport == .pin) viewport: {
            if (self.viewport_pin_row_offset) |*v| {
                const p = self.viewport_pin;
                if (p.node != node or
                    p.y < pn.y or
                    p.y == 0) break :viewport;
                v.* -= 1;
            }
        }
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node == node and p.y >= pn.y) {
                if (p.y == 0) {
                    p.x = 0;
                } else {
                    p.y -= 1;
                }
            }
        }
    }
    while (node.next) |next| {
        const next_page = next.page();
        const next_rows = next_page.rows.ptr(next_page.memory.ptr);
        _ = self.cloneRowGrowCapacity(
            node,
            node.rows() - 1,
            next_page,
            &next_rows[0],
        );
        node = next;
        page = next_page;
        rows = next_rows;
        const shifted_limit = limit - shifted;
        if (node.rows() > shifted_limit) {
            self.invalidateNodeLayout(node);
            page.resetRow(&rows[0]);
            fastmem.rotateOnce(Row, rows[0 .. shifted_limit + 1]);
            page.dirty = true;
            if (self.viewport == .pin) viewport: {
                if (self.viewport_pin_row_offset) |*v| {
                    const p = self.viewport_pin;
                    if (p.node != node or
                        p.y > shifted_limit) break :viewport;
                    v.* -= 1;
                }
            }
            const pin_keys = self.tracked_pins.keys();
            for (pin_keys) |p| {
                if (p.node != node or p.y > shifted_limit) continue;
                if (p.y == 0) {
                    p.node = node.prev.?;
                    p.y = p.node.rows() - 1;
                    continue;
                }
                p.y -= 1;
            }
            return;
        }
        self.invalidateNodeLayout(node);
        fastmem.rotateOnce(Row, rows[0..node.rows()]);
        page.dirty = true;
        shifted += node.rows();
        if (self.viewport == .pin) viewport: {
            if (self.viewport_pin_row_offset) |*v| {
                const p = self.viewport_pin;
                if (p.node != node) break :viewport;
                v.* -= 1;
            }
        }
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node != node) continue;
            if (p.y == 0) {
                p.node = node.prev.?;
                p.y = p.node.rows() - 1;
                continue;
            }
            p.y -= 1;
        }
    }
    page.resetRow(&rows[node.rows() - 1]);
}
pub fn eraseHistory(
    self: *PageList,
    bl_pt: ?point.Point,
) void {
    self.eraseRows(.{ .history = .{} }, bl_pt);
}
pub fn eraseActive(
    self: *PageList,
    y: size.CellCountInt,
) void {
    assert(y < self.rows);
    self.eraseRows(.{ .active = .{} }, .{ .active = .{ .y = y } });
}
fn eraseRows(
    self: *PageList,
    tl_pt: point.Point,
    bl_pt: ?point.Point,
) void {
    defer self.assertIntegrity();
    self.page_compression.markActivity();
    var erased: usize = 0;
    var it = self.pageIterator(.right_down, tl_pt, bl_pt);
    while (it.next()) |chunk| {
        if (chunk.fullPage()) {
            if (chunk.node.next == null and chunk.node.prev == null) {
                self.invalidateNodeLayout(chunk.node);
                const page = chunk.node.page();
                erased += page.size.rows;
                page.reinit();
                page.size.rows = 0;
                break;
            }
            erased += chunk.node.rows();
            self.erasePage(chunk.node);
            continue;
        }
        self.invalidateNodeLayout(chunk.node);
        const page = chunk.node.page();
        defer page.assertIntegrity();
        assert(chunk.start == 0);
        const rows = page.rows.ptr(page.memory);
        const scroll_amount = chunk.node.rows() - chunk.end;
        for (0..scroll_amount) |i| {
            const src: *Row = &rows[i + chunk.end];
            const dst: *Row = &rows[i];
            const old_dst = dst.*;
            dst.* = src.*;
            src.* = old_dst;
            dst.dirty = true;
        }
        for (scroll_amount..chunk.node.rows()) |i| {
            page.resetRow(&rows[i]);
        }
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node != chunk.node) continue;
            if (p.y >= chunk.end) {
                p.y -= chunk.end;
            } else {
                p.y = 0;
                p.x = 0;
            }
        }
        page.size.rows = @intCast(scroll_amount);
        erased += chunk.end;
    }
    self.total_rows -= erased;
    if (tl_pt == .active) {
        for (0..erased) |_| _ = self.grow() catch |err| {
            log.err("failed to regrow active area after erase err={}", .{err});
            return;
        };
    }
    self.fixupViewport(erased);
}
fn erasePage(self: *PageList, node: *List.Node) void {
    assert(node.next != null or node.prev != null);
    assert(node.prev == null or node.next == null);
    const pin_keys = self.tracked_pins.keys();
    for (pin_keys) |p| {
        if (p.node != node) continue;
        p.node = node.prev orelse node.next orelse unreachable;
        p.y = 0;
        p.x = 0;
    }
    self.pages.remove(node);
    self.destroyNode(node);
}
pub fn pin(self: *const PageList, pt: point.Point) ?Pin {
    const x = pt.coord().x;
    if (x >= self.cols) return null;
    var p = self.getTopLeft(pt).down(pt.coord().y) orelse return null;
    if (x >= p.node.cols()) return null;
    p.x = x;
    return p;
}
pub fn trackPin(self: *PageList, p: Pin) Allocator.Error!*Pin {
    if (build_options.slow_runtime_safety) assert(self.pinIsValid(p));
    const tracked = try self.pool.pins.create();
    errdefer self.pool.pins.destroy(tracked);
    tracked.* = p;
    try self.tracked_pins.putNoClobber(self.pool.alloc, tracked, {});
    errdefer _ = self.tracked_pins.remove(tracked);
    return tracked;
}
pub fn untrackPin(self: *PageList, p: *Pin) void {
    assert(p != self.viewport_pin);
    if (self.tracked_pins.swapRemove(p)) {
        self.pool.pins.destroy(p);
    }
}
pub fn countTrackedPins(self: *const PageList) usize {
    return self.tracked_pins.count();
}
pub fn trackedPins(self: *const PageList) []const *Pin {
    return self.tracked_pins.keys();
}
pub fn pinIsValid(self: *const PageList, p: Pin) bool {
    comptime assert(build_options.slow_runtime_safety);
    var it = self.pages.first;
    while (it) |node| : (it = node.next) {
        if (node != p.node) continue;
        return p.y < node.rows() and
            p.x < node.cols();
    }
    return false;
}
pub fn nodeIsValid(
    self: *const PageList,
    target: *List.Node,
    serial: u64,
) bool {
    if (serial < self.page_serial_epoch) return false;
    var it = self.pages.first;
    while (it) |node| : (it = node.next) {
        if (node == target) return node.serial == serial;
    }
    return false;
}
fn pinIsActive(self: *const PageList, p: Pin) bool {
    const active = self.getTopLeft(.active);
    if (p.node == active.node) return p.y >= active.y;
    var node_ = active.node.next;
    while (node_) |node| {
        if (node == p.node) return true;
        node_ = node.next;
    }
    return false;
}
fn pinIsTop(self: *const PageList, p: Pin) bool {
    return p.y == 0 and p.node == self.pages.first.?;
}
pub fn pointFromPin(self: *const PageList, tag: point.Tag, p: Pin) ?point.Point {
    const tl = self.getTopLeft(tag);
    var coord: point.Coordinate = .{ .x = p.x };
    if (p.node == tl.node) {
        if (tl.y > p.y) return null;
        coord.y = p.y - tl.y;
    } else {
        coord.y = std.math.add(
            u32,
            coord.y,
            tl.node.rows() - tl.y,
        ) catch return null;
        var node_ = tl.node.next;
        while (node_) |node| : (node_ = node.next) {
            if (node == p.node) {
                coord.y = std.math.add(u32, coord.y, p.y) catch return null;
                break;
            }
            coord.y = std.math.add(
                u32,
                coord.y,
                node.rows(),
            ) catch return null;
        } else {
            return null;
        }
    }
    return switch (tag) {
        inline else => |comptime_tag| @unionInit(
            point.Point,
            @tagName(comptime_tag),
            coord,
        ),
    };
}
pub fn getCell(self: *const PageList, pt: point.Point) ?Cell {
    const pt_pin = self.pin(pt) orelse return null;
    const rac = pt_pin.node.page().getRowAndCell(pt_pin.x, pt_pin.y);
    return .{
        .node = pt_pin.node,
        .row = rac.row,
        .cell = rac.cell,
        .row_idx = pt_pin.y,
        .col_idx = pt_pin.x,
    };
}
pub fn diagram(
    self: *const PageList,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const active_pin = self.getTopLeft(.active);
    var active = false;
    var active_index: usize = 0;
    var page_index: usize = 0;
    var cols: usize = 0;
    var it = self.pageIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |chunk| : (page_index += 1) {
        cols = chunk.node.cols();
        var skipped = false;
        for (0..chunk.node.rows()) |y| {
            if (!active and
                chunk.node == active_pin.node and
                active_pin.y == y)
            {
                active = true;
                try writer.writeAll("     +-");
                try writer.writeByteNTimes('-', cols);
                try writer.writeAll("--+ ACTIVE");
                try writer.writeByte('\n');
            }
            if (y == 0) {
                try writer.writeAll("      +");
                try writer.writeByteNTimes('-', cols);
                try writer.writeByte('+');
                if (active) try writer.writeAll(" :");
                try writer.print(" = PAGE {}", .{page_index});
                try writer.writeByte('\n');
            }
            {
                const row = chunk.node.page().getRow(y);
                const cells = chunk.node.page().getCells(row)[0..cols];
                var row_has_content = false;
                for (cells) |cell| {
                    if (cell.hasText()) {
                        row_has_content = true;
                        break;
                    }
                }
                if (!active and !row_has_content) {
                    if (!skipped) {
                        try writer.writeAll("  ... :");
                        try writer.writeByteNTimes(' ', cols);
                        try writer.writeByte(':');
                        if (active) try writer.writeAll(" :");
                        try writer.writeByte('\n');
                    }
                    skipped = true;
                    continue;
                }
                skipped = false;
                const y_digits = if (y == 0) 0 else std.math.log10_int(y);
                try writer.writeByteNTimes(' ', 4 - y_digits);
                try writer.print("{} ", .{y});
                try writer.writeAll(if (row.wrap_continuation) "…" else "|");
                if (row_has_content) {
                    for (cells) |*cell| {
                        if (cell.wide == .spacer_tail) continue;
                        if (cell.codepoint() < ' ') {
                            try writer.writeByte("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"[cell.codepoint()]);
                            continue;
                        }
                        try writer.print("{u}", .{cell.codepoint()});
                        if (cell.hasGrapheme()) {
                            const grapheme = chunk.node.page().lookupGrapheme(cell).?;
                            for (grapheme) |cp| {
                                try writer.print("{u}", .{cp});
                            }
                        }
                    }
                } else {
                    try writer.writeByteNTimes(' ', cols);
                }
                try writer.writeAll(if (row.wrap) "…" else "|");
                if (active) {
                    try writer.print(" | {}", .{active_index});
                    active_index += 1;
                }
                try writer.writeByte('\n');
            }
            pins: {
                var pin_buf: [16]*Pin = undefined;
                var pin_count: usize = 0;
                const pin_keys = self.tracked_pins.keys();
                for (pin_keys) |p| {
                    if (p.node != chunk.node) continue;
                    if (p.y != y) continue;
                    pin_buf[pin_count] = p;
                    pin_count += 1;
                    if (pin_count >= pin_buf.len) return error.TooManyTrackedPinsInRow;
                }
                if (pin_count == 0) break :pins;
                const pins = pin_buf[0..pin_count];
                std.mem.sort(
                    *Pin,
                    pins,
                    {},
                    struct {
                        fn lt(_: void, a: *Pin, b: *Pin) bool {
                            return a.x < b.x;
                        }
                    }.lt,
                );
                try writer.writeAll("      :");
                var x: usize = 0;
                for (pins) |p| {
                    if (x > p.x) continue;
                    try writer.writeByteNTimes(' ', p.x - x);
                    try writer.writeByte('^');
                    x = p.x + 1;
                }
                try writer.writeByteNTimes(' ', cols - x);
                try writer.writeByte(':');
                if (active) try writer.writeAll(" :");
                try writer.print(" = PIN{s}", .{if (pin_count > 1) "S" else ""});
                x = pins[0].x;
                for (pins, 0..) |p, i| {
                    if (p.x != x) try writer.writeByte(',');
                    try writer.print(" {}", .{i});
                }
                try writer.writeByte('\n');
            }
        }
        {
            try writer.writeAll("      +");
            try writer.writeByteNTimes('-', cols);
            try writer.writeByte('+');
            if (active) try writer.writeAll(" :");
            try writer.writeByte('\n');
        }
    }
    {
        try writer.writeAll("     +-");
        try writer.writeByteNTimes('-', cols);
        try writer.writeAll("--+");
        try writer.writeByte('\n');
    }
}
pub fn highlightSemanticContent(
    self: *const PageList,
    at: Pin,
    content: pagepkg.Cell.SemanticContent,
) ?highlight.Untracked {
    const end: Pin = end: {
        var it = at.promptIterator(.right_down, null);
        assert(it.next().?.y == at.y);
        if (it.next()) |next| next: {
            var prev = next.up(1) orelse break :next;
            prev.x = prev.node.cols() - 1;
            break :end prev;
        }
        break :end self.getBottomRight(.screen).?;
    };
    switch (content) {
        .prompt => {
            var result: highlight.Untracked = .{
                .start = at.left(at.x),
                .end = at,
            };
            var it = at.cellIterator(.right_down, end);
            while (it.next()) |p| {
                switch (p.rowAndCell().cell.semantic_content) {
                    .prompt, .input => result.end = p,
                    .output => break,
                }
            }
            return result;
        },
        .input => {
            var result: highlight.Untracked = .{
                .start = undefined,
                .end = undefined,
            };
            var it = at.cellIterator(.right_down, end);
            while (it.next()) |p| {
                switch (p.rowAndCell().cell.semantic_content) {
                    .prompt => {},
                    .input => {
                        result.start = p;
                        result.end = p;
                        break;
                    },
                    .output => return null,
                }
            } else {
                return null;
            }
            while (it.next()) |p| {
                switch (p.rowAndCell().cell.semantic_content) {
                    .prompt => {},
                    .output => break,
                    .input => result.end = p,
                }
            }
            return result;
        },
        .output => {
            var result: highlight.Untracked = .{
                .start = undefined,
                .end = undefined,
            };
            var it = at.cellIterator(.right_down, end);
            while (it.next()) |p| {
                const cell = p.rowAndCell().cell;
                switch (cell.semantic_content) {
                    .prompt, .input => {},
                    .output => {
                        if (!cell.hasText()) continue;
                        result.start = p;
                        result.end = p;
                        break;
                    },
                }
            } else {
                return null;
            }
            while (it.next()) |p| {
                const cell = p.rowAndCell().cell;
                switch (cell.semantic_content) {
                    .prompt, .input => break,
                    .output => {
                        if (cell.hasText()) result.end = p;
                    },
                }
            }
            return result;
        },
    }
}
pub const Direction = enum { left_up, right_down };
pub const PromptIterator = struct {
    current: ?Pin,
    limit: ?Pin,
    direction: Direction,
    pub const empty: PromptIterator = .{
        .current = null,
        .limit = null,
        .direction = .left_up,
    };
    pub fn next(self: *PromptIterator) ?Pin {
        switch (self.direction) {
            .left_up => return self.nextLeftUp(),
            .right_down => return self.nextRightDown(),
        }
    }
    pub fn nextRightDown(self: *PromptIterator) ?Pin {
        const start: Pin = self.current orelse return null;
        var current: ?Pin = start;
        while (current) |p| : (current = p.down(1)) {
            const at_limit = if (self.limit) |limit| limit.eql(p) else false;
            const rac = p.rowAndCell();
            switch (rac.row.semantic_prompt) {
                .none => if (at_limit) break,
                .prompt, .prompt_continuation => {
                    if (at_limit) {
                        self.current = null;
                        return p.left(p.x);
                    }
                    var end_pin = p;
                    while (end_pin.down(1)) |next_pin| : (end_pin = next_pin) {
                        switch (next_pin.rowAndCell().row.semantic_prompt) {
                            .prompt_continuation => if (self.limit) |limit| {
                                if (limit.eql(next_pin)) break;
                            },
                            .prompt, .none => {
                                self.current = next_pin;
                                return p.left(p.x);
                            },
                        }
                    }
                    self.current = null;
                    return p.left(p.x);
                },
            }
        }
        self.current = null;
        return null;
    }
    pub fn nextLeftUp(self: *PromptIterator) ?Pin {
        const start: Pin = self.current orelse return null;
        var current: ?Pin = start;
        while (current) |p| : (current = p.up(1)) {
            const at_limit = if (self.limit) |limit| limit.eql(p) else false;
            const rac = p.rowAndCell();
            switch (rac.row.semantic_prompt) {
                .none => if (at_limit) break,
                .prompt => {
                    self.current = if (at_limit) null else p.up(1);
                    return p.left(p.x);
                },
                .prompt_continuation => {
                    if (at_limit) {
                        self.current = null;
                        return p.left(p.x);
                    }
                    var end_pin = p;
                    while (end_pin.up(1)) |prior| : (end_pin = prior) {
                        if (self.limit) |limit| {
                            if (limit.eql(prior)) break;
                        }
                        switch (prior.rowAndCell().row.semantic_prompt) {
                            .none => {
                                self.current = prior;
                                return end_pin.left(end_pin.x);
                            },
                            .prompt_continuation => {},
                            .prompt => {
                                self.current = prior.up(1);
                                return prior.left(prior.x);
                            },
                        }
                    }
                    self.current = null;
                    return p.left(p.x);
                },
            }
        }
        self.current = null;
        return null;
    }
};
pub fn promptIterator(
    self: *const PageList,
    direction: Direction,
    tl_pt: point.Point,
    bl_pt: ?point.Point,
) PromptIterator {
    const tl_pin = self.pin(tl_pt).?;
    const bl_pin = if (bl_pt) |pt|
        self.pin(pt).?
    else
        self.getBottomRight(tl_pt) orelse return .empty;
    return switch (direction) {
        .right_down => tl_pin.promptIterator(.right_down, bl_pin),
        .left_up => bl_pin.promptIterator(.left_up, tl_pin),
    };
}
pub const CellIterator = struct {
    row_it: RowIterator,
    cell: ?Pin = null,
    pub fn next(self: *CellIterator) ?Pin {
        const cell = self.cell orelse return null;
        switch (self.row_it.page_it.direction) {
            .right_down => {
                if (cell.x + 1 < cell.node.cols()) {
                    var copy = cell;
                    copy.x += 1;
                    self.cell = copy;
                } else {
                    self.cell = self.row_it.next();
                }
            },
            .left_up => {
                if (cell.x > 0) {
                    var copy = cell;
                    copy.x -= 1;
                    self.cell = copy;
                } else {
                    if (self.row_it.next()) |next_cell| {
                        var copy = next_cell;
                        copy.x = next_cell.node.cols() - 1;
                        self.cell = copy;
                    } else {
                        self.cell = null;
                    }
                }
            },
        }
        return cell;
    }
};
pub fn cellIterator(
    self: *const PageList,
    direction: Direction,
    tl_pt: point.Point,
    bl_pt: ?point.Point,
) CellIterator {
    const tl_pin = self.pin(tl_pt).?;
    const bl_pin = if (bl_pt) |pt|
        self.pin(pt).?
    else
        self.getBottomRight(tl_pt) orelse
            return .{ .row_it = undefined };
    return switch (direction) {
        .right_down => tl_pin.cellIterator(.right_down, bl_pin),
        .left_up => bl_pin.cellIterator(.left_up, tl_pin),
    };
}
pub const RowIterator = struct {
    page_it: PageIterator,
    chunk: ?PageIterator.Chunk = null,
    offset: size.CellCountInt = 0,
    pub fn next(self: *RowIterator) ?Pin {
        const chunk = self.chunk orelse return null;
        const row: Pin = .{ .node = chunk.node, .y = self.offset };
        switch (self.page_it.direction) {
            .right_down => {
                self.offset += 1;
                if (self.offset >= chunk.end) {
                    self.chunk = self.page_it.next();
                    if (self.chunk) |c| self.offset = c.start;
                }
            },
            .left_up => {
                if (self.offset == 0) {
                    self.chunk = self.page_it.next();
                    if (self.chunk) |c| self.offset = c.end - 1;
                } else {
                    if (self.offset == chunk.start) {
                        self.chunk = null;
                    } else {
                        self.offset -= 1;
                    }
                }
            },
        }
        return row;
    }
};
pub fn rowIterator(
    self: *const PageList,
    direction: Direction,
    tl_pt: point.Point,
    bl_pt: ?point.Point,
) RowIterator {
    const tl_pin = self.pin(tl_pt).?;
    const bl_pin = if (bl_pt) |pt|
        self.pin(pt).?
    else
        self.getBottomRight(tl_pt) orelse
            return .{ .page_it = undefined };
    return switch (direction) {
        .right_down => tl_pin.rowIterator(.right_down, bl_pin),
        .left_up => bl_pin.rowIterator(.left_up, tl_pin),
    };
}
pub const PageIterator = struct {
    row: ?Pin = null,
    limit: Limit = .none,
    direction: Direction = .right_down,
    const Limit = union(enum) {
        none,
        count: usize,
        row: Pin,
    };
    pub fn next(self: *PageIterator) ?Chunk {
        return switch (self.direction) {
            .left_up => self.nextUp(),
            .right_down => self.nextDown(),
        };
    }
    fn nextDown(self: *PageIterator) ?Chunk {
        const row = self.row orelse return null;
        return switch (self.limit) {
            .none => none: {
                self.row = next: {
                    const next_page = row.node.next orelse break :next null;
                    break :next .{ .node = next_page };
                };
                break :none .{
                    .node = row.node,
                    .start = row.y,
                    .end = row.node.rows(),
                };
            },
            .count => |*limit| count: {
                assert(limit.* > 0);
                const available: usize = row.node.rows() - row.y;
                const len = @min(available, limit.*);
                limit.* -= len;
                self.row = if (limit.* > 0) row.down(len) else null;
                break :count .{
                    .node = row.node,
                    .start = row.y,
                    .end = @intCast(@as(usize, row.y) + len),
                };
            },
            .row => |limit_row| row: {
                if (limit_row.node != row.node) {
                    self.row = next: {
                        const next_page = row.node.next orelse break :next null;
                        break :next .{ .node = next_page };
                    };
                    break :row .{
                        .node = row.node,
                        .start = row.y,
                        .end = row.node.rows(),
                    };
                }
                self.row = null;
                if (row.y > limit_row.y) return null;
                break :row .{
                    .node = row.node,
                    .start = row.y,
                    .end = limit_row.y + 1,
                };
            },
        };
    }
    fn nextUp(self: *PageIterator) ?Chunk {
        const row = self.row orelse return null;
        return switch (self.limit) {
            .none => none: {
                self.row = next: {
                    const next_page = row.node.prev orelse break :next null;
                    break :next .{
                        .node = next_page,
                        .y = next_page.rows() - 1,
                    };
                };
                break :none .{
                    .node = row.node,
                    .start = 0,
                    .end = row.y + 1,
                };
            },
            .count => |*limit| count: {
                assert(limit.* > 0);
                const available: usize = @as(usize, row.y) + 1;
                const len = @min(available, limit.*);
                limit.* -= len;
                self.row = if (limit.* > 0) row.up(len) else null;
                break :count .{
                    .node = row.node,
                    .start = @intCast(available - len),
                    .end = @intCast(available),
                };
            },
            .row => |limit_row| row: {
                if (limit_row.node != row.node) {
                    self.row = next: {
                        const next_page = row.node.prev orelse break :next null;
                        break :next .{
                            .node = next_page,
                            .y = next_page.rows() - 1,
                        };
                    };
                    break :row .{
                        .node = row.node,
                        .start = 0,
                        .end = row.y + 1,
                    };
                }
                self.row = null;
                if (row.y < limit_row.y) return null;
                break :row .{
                    .node = row.node,
                    .start = limit_row.y,
                    .end = row.y + 1,
                };
            },
        };
    }
    pub const Chunk = struct {
        node: *List.Node,
        start: size.CellCountInt,
        end: size.CellCountInt,
        pub fn rows(self: Chunk) []Row {
            const page = self.node.page();
            const rows_ptr = page.rows.ptr(page.memory);
            return rows_ptr[self.start..self.end];
        }
        pub fn fullPage(self: Chunk) bool {
            return self.start == 0 and self.end == self.node.rows();
        }
        pub fn overlaps(self: Chunk, other: Chunk) bool {
            if (self.node != other.node) return false;
            if (self.end <= other.start) return false;
            if (self.start >= other.end) return false;
            return true;
        }
    };
};
pub fn pageIterator(
    self: *const PageList,
    direction: Direction,
    tl_pt: point.Point,
    bl_pt: ?point.Point,
) PageIterator {
    const tl_pin = self.pin(tl_pt).?;
    const bl_pin = if (bl_pt) |pt|
        self.pin(pt).?
    else
        self.getBottomRight(tl_pt) orelse return .{ .row = null };
    if (build_options.slow_runtime_safety) {
        assert(tl_pin.eql(bl_pin) or tl_pin.before(bl_pin));
    }
    return switch (direction) {
        .right_down => tl_pin.pageIterator(.right_down, bl_pin),
        .left_up => bl_pin.pageIterator(.left_up, tl_pin),
    };
}
pub fn getTopLeft(self: *const PageList, tag: point.Tag) Pin {
    return switch (tag) {
        .screen, .history => .{ .node = self.pages.first.? },
        .viewport => switch (self.viewport) {
            .active => self.getTopLeft(.active),
            .top => self.getTopLeft(.screen),
            .pin => self.viewport_pin.*,
        },
        .active => active: {
            var rem = self.rows;
            var it = self.pages.last;
            while (it) |node| : (it = node.prev) {
                if (rem <= node.rows()) break :active .{
                    .node = node,
                    .y = node.rows() - rem,
                };
                rem -= node.rows();
            }
            unreachable;
        },
    };
}
pub fn getBottomRight(self: *const PageList, tag: point.Tag) ?Pin {
    return switch (tag) {
        .screen, .active => last: {
            const node = self.pages.last.?;
            break :last .{
                .node = node,
                .y = node.rows() - 1,
                .x = node.cols() - 1,
            };
        },
        .viewport => viewport: {
            var br = self.getTopLeft(.viewport);
            br = br.down(self.rows - 1).?;
            br.x = br.node.cols() - 1;
            break :viewport br;
        },
        .history => active: {
            var br = self.getTopLeft(.active);
            br = br.up(1) orelse return null;
            br.x = br.node.cols() - 1;
            break :active br;
        },
    };
}
fn totalRows(self: *const PageList) usize {
    var rows: usize = 0;
    var node_ = self.pages.first;
    while (node_) |node| {
        rows += node.rows();
        node_ = node.next;
    }
    return rows;
}
pub fn totalPages(self: *const PageList) usize {
    var pages: usize = 0;
    var node_ = self.pages.first;
    while (node_) |node| {
        pages += 1;
        node_ = node.next;
    }
    return pages;
}
pub const MemoryStats = struct {
    resident_pages: usize = 0,
    compressed_pages: usize = 0,
    raw_bytes: usize = 0,
    resident_raw_bytes: usize = 0,
    decommitted_raw_bytes: usize = 0,
    resident_backing_bytes: usize = 0,
    encoded_bytes: usize = 0,
    pub fn estimatedResidentBytes(self: MemoryStats) usize {
        return self.resident_backing_bytes + self.encoded_bytes;
    }
    pub fn estimatedSavings(self: MemoryStats) usize {
        return self.decommitted_raw_bytes -| self.encoded_bytes;
    }
};
pub fn memoryStats(self: *const PageList) MemoryStats {
    var result: MemoryStats = .{};
    var current = self.pages.first;
    while (current) |node| : (current = node.next) {
        const raw_len = node.metadata().memory.len;
        const backing_len = switch (node.owned) {
            .pool => PagePool.item_size,
            .heap => raw_len,
        };
        assert(backing_len >= raw_len);
        result.raw_bytes += raw_len;
        switch (node.data) {
            .resident => {
                result.resident_pages += 1;
                result.resident_raw_bytes += raw_len;
                result.resident_backing_bytes += backing_len;
            },
            .compressed => |compressed| {
                result.compressed_pages += 1;
                result.decommitted_raw_bytes += raw_len;
                result.resident_backing_bytes += backing_len - raw_len;
                result.encoded_bytes += compressed.encoded.len;
            },
        }
    }
    return result;
}
pub const MemoryUsage = struct {
    pages: usize = 0,
    virtual_bytes: usize = 0,
    resident_bytes: usize = 0,
    compressed_pages: usize = 0,
    compressed_bytes: usize = 0,
};
pub fn memoryUsage(self: *const PageList) MemoryUsage {
    const stats = self.memoryStats();
    return .{
        .pages = stats.resident_pages + stats.compressed_pages,
        .virtual_bytes = self.page_size +
            self.pool.pages.freeCount() * PagePool.item_size,
        .resident_bytes = stats.estimatedResidentBytes(),
        .compressed_pages = stats.compressed_pages,
        .compressed_bytes = stats.encoded_bytes,
    };
}
fn growRows(self: *PageList, n: usize) Allocator.Error!void {
    for (0..n) |_| _ = try self.grow();
}
pub fn clearDirty(self: *PageList) void {
    var page = self.pages.first;
    while (page) |p| : (page = p.next) {
        const current_page = p.page();
        current_page.dirty = false;
        for (current_page.rows.ptr(current_page.memory)[0..p.rows()]) |*row| {
            row.dirty = false;
        }
    }
}
pub fn isDirty(self: *const PageList, pt: point.Point) bool {
    return self.getCell(pt).?.isDirty();
}
fn markDirty(self: *PageList, pt: point.Point) void {
    self.pin(pt).?.markDirty();
}
const Limits = struct {
    bytes: Limit,
    lines: Limit,
    pub const Key = std.meta.FieldEnum(Limits);
    pub const Limit = struct {
        explicit: usize = std.math.maxInt(usize),
        min: usize,
    };
    pub fn init(cols: size.CellCountInt, rows: size.CellCountInt) Limits {
        return .{
            .bytes = .{ .min = minMaxSize(cols, rows) },
            .lines = .{ .min = minMaxLines(cols) },
        };
    }
    pub fn set(
        self: *Limits,
        comptime key: Key,
        value: ?usize,
    ) void {
        switch (key) {
            .bytes => self.bytes.explicit = value orelse std.math.maxInt(usize),
            .lines => self.lines.explicit = value orelse std.math.maxInt(usize),
        }
    }
    pub fn resize(
        self: *Limits,
        cols: size.CellCountInt,
        rows: size.CellCountInt,
    ) void {
        self.bytes.min = minMaxSize(cols, rows);
        self.lines.min = minMaxLines(cols);
    }
    pub fn max(self: *const Limits, key: Key) usize {
        return switch (key) {
            .bytes => @max(self.bytes.explicit, self.bytes.min),
            .lines => @max(self.lines.explicit, self.lines.min),
        };
    }
    pub fn exceeded(
        self: *const Limits,
        pagelist: *const PageList,
        limit: Key,
    ) bool {
        return switch (limit) {
            .bytes => pagelist.page_size > self.max(.bytes),
            .lines => pagelist.total_rows > pagelist.rows and
                pagelist.total_rows - pagelist.rows > self.max(.lines),
        };
    }
    pub fn enforce(
        self: *const Limits,
        pagelist: *PageList,
        key: Key,
    ) void {
        if (!self.exceeded(pagelist, key)) return;
        if (pagelist.total_rows <= pagelist.rows) return;
        var removed: usize = 0;
        while (self.exceeded(pagelist, key)) {
            const first = pagelist.pages.first.?;
            if (first == pagelist.getTopLeft(.active).node) break;
            if (removed == 0) pagelist.page_compression.markActivity();
            const first_rows = first.rows();
            for (pagelist.tracked_pins.keys()) |p| {
                if (p.node == first) p.garbage = true;
            }
            pagelist.erasePage(first);
            pagelist.total_rows -= first_rows;
            removed += first_rows;
        }
        if (removed > 0) pagelist.fixupViewport(removed);
    }
    fn minMaxSize(cols: size.CellCountInt, rows: size.CellCountInt) usize {
        comptime {
            const max_rows = std.math.maxInt(size.CellCountInt);
            _ = std.math.divCeil(usize, max_rows, 1) catch unreachable;
        }
        const cap = initialCapacity(cols);
        const pages_exact = if (cap.rows >= rows) 1 else std.math.divCeil(
            usize,
            rows,
            cap.rows,
        ) catch {
            unreachable;
        };
        const pages = pages_exact + 1;
        assert(pages >= 2);
        return PagePool.item_size * pages;
    }
    fn minMaxLines(cols: size.CellCountInt) usize {
        return initialCapacity(cols).rows;
    }
};
pub const Pin = struct {
    node: *List.Node,
    y: size.CellCountInt = 0,
    x: size.CellCountInt = 0,
    garbage: bool = false,
    pub inline fn rowAndCell(self: Pin) struct {
        row: *pagepkg.Row,
        cell: *pagepkg.Cell,
    } {
        const rac = self.node.page().getRowAndCell(self.x, self.y);
        return .{ .row = rac.row, .cell = rac.cell };
    }
    pub const CellSubset = enum { all, left, right };
    pub inline fn cells(self: Pin, subset: CellSubset) []pagepkg.Cell {
        const page = self.node.page();
        const rac = page.getRowAndCell(self.x, self.y);
        const all = page.getCells(rac.row);
        return switch (subset) {
            .all => all,
            .left => all[0 .. self.x + 1],
            .right => all[self.x..],
        };
    }
    pub inline fn grapheme(self: Pin, cell: *const pagepkg.Cell) ?[]u21 {
        return self.node.page().lookupGrapheme(cell);
    }
    pub inline fn style(self: Pin, cell: *const pagepkg.Cell) stylepkg.Style {
        if (cell.style_id == stylepkg.default_id) return .{};
        const page = self.node.page();
        return page.styles.get(
            page.memory,
            cell.style_id,
        ).*;
    }
    pub inline fn isDirty(self: Pin) bool {
        const page = self.node.page();
        return page.dirty or page.getRowAndCell(self.x, self.y).row.dirty;
    }
    pub inline fn markDirty(self: Pin) void {
        self.rowAndCell().row.dirty = true;
    }
    pub inline fn pageIterator(
        self: Pin,
        direction: Direction,
        limit: ?Pin,
    ) PageIterator {
        if (build_options.slow_runtime_safety) {
            if (limit) |l| {
                switch (direction) {
                    .right_down => assert(self.eql(l) or self.before(l)),
                    .left_up => assert(self.eql(l) or l.before(self)),
                }
            }
        }
        return .{
            .row = self,
            .limit = if (limit) |p| .{ .row = p } else .{ .none = {} },
            .direction = direction,
        };
    }
    pub inline fn rowIterator(
        self: Pin,
        direction: Direction,
        limit: ?Pin,
    ) RowIterator {
        var page_it = self.pageIterator(direction, limit);
        const chunk = page_it.next() orelse return .{ .page_it = page_it };
        return .{
            .page_it = page_it,
            .chunk = chunk,
            .offset = switch (direction) {
                .right_down => chunk.start,
                .left_up => chunk.end - 1,
            },
        };
    }
    pub inline fn cellIterator(
        self: Pin,
        direction: Direction,
        limit: ?Pin,
    ) CellIterator {
        var row_it = self.rowIterator(direction, limit);
        var cell = row_it.next() orelse return .{ .row_it = row_it };
        cell.x = self.x;
        return .{ .row_it = row_it, .cell = cell };
    }
    pub inline fn promptIterator(
        self: Pin,
        direction: Direction,
        limit: ?Pin,
    ) PromptIterator {
        return .{
            .current = self,
            .limit = limit,
            .direction = direction,
        };
    }
    pub fn isBetween(self: Pin, top: Pin, bottom: Pin) bool {
        if (build_options.slow_runtime_safety) {
            if (top.node == bottom.node) {
                assert(top.y <= bottom.y);
                if (top.y == bottom.y) {
                    assert(top.x <= bottom.x);
                }
            } else {
                var node_ = top.node.next;
                while (node_) |node| : (node_ = node.next) {
                    if (node == bottom.node) break;
                } else assert(false);
            }
        }
        if (self.node == top.node) {
            if (self.y < top.y) return false;
            if (self.y > top.y) {
                return if (self.node == bottom.node)
                    self.y <= bottom.y
                else
                    true;
            }
            assert(self.y == top.y);
            if (self.x < top.x) return false;
        }
        if (self.node == bottom.node) {
            if (self.y > bottom.y) return false;
            if (self.y < bottom.y) return true;
            assert(self.y == bottom.y);
            return self.x <= bottom.x;
        }
        if (top.node == bottom.node) return false;
        var node_ = top.node.next;
        while (node_) |node| : (node_ = node.next) {
            if (node == bottom.node) break;
            if (node == self.node) return true;
        }
        return false;
    }
    pub fn before(self: Pin, other: Pin) bool {
        if (self.node == other.node) {
            if (self.y < other.y) return true;
            if (self.y > other.y) return false;
            return self.x < other.x;
        }
        var node_ = self.node.next;
        while (node_) |node| : (node_ = node.next) {
            if (node == other.node) return true;
        }
        return false;
    }
    pub inline fn eql(self: Pin, other: Pin) bool {
        return self.node == other.node and
            self.y == other.y and
            self.x == other.x;
    }
    pub inline fn left(self: Pin, n: usize) Pin {
        assert(n <= self.x);
        var result = self;
        result.x -= std.math.cast(size.CellCountInt, n) orelse result.x;
        return result;
    }
    pub inline fn right(self: Pin, n: usize) Pin {
        assert(self.x + n < self.node.cols());
        var result = self;
        result.x +|= std.math.cast(size.CellCountInt, n) orelse
            std.math.maxInt(size.CellCountInt);
        return result;
    }
    pub inline fn leftClamp(self: Pin, n: size.CellCountInt) Pin {
        var result = self;
        result.x -|= n;
        return result;
    }
    pub inline fn rightClamp(self: Pin, n: size.CellCountInt) Pin {
        var result = self;
        result.x = @min(self.x +| n, self.node.cols() - 1);
        return result;
    }
    pub fn leftWrap(self: Pin, n: usize) ?Pin {
        var result = self;
        var remaining = n;
        while (remaining > result.x) {
            remaining -= @as(usize, result.x) + 1;
            result = result.up(1) orelse return null;
            result.x = result.node.cols() - 1;
        }
        result.x -= @intCast(remaining);
        return result;
    }
    pub fn rightWrap(self: Pin, n: usize) ?Pin {
        var result = self;
        var remaining = n;
        while (true) {
            const row_remaining = result.node.cols() - result.x - 1;
            if (remaining <= row_remaining) {
                result.x += @intCast(remaining);
                return result;
            }
            remaining -= @as(usize, row_remaining) + 1;
            result = result.down(1) orelse return null;
            result.x = 0;
        }
    }
    pub inline fn down(self: Pin, n: usize) ?Pin {
        return switch (self.downOverflow(n)) {
            .offset => |v| v,
            .overflow => null,
        };
    }
    pub inline fn up(self: Pin, n: usize) ?Pin {
        return switch (self.upOverflow(n)) {
            .offset => |v| v,
            .overflow => null,
        };
    }
    pub fn downOverflow(self: Pin, n: usize) union(enum) {
        offset: Pin,
        overflow: struct {
            end: Pin,
            remaining: usize,
        },
    } {
        const rows = self.node.rows() - (self.y + 1);
        if (n <= rows) return .{ .offset = .{
            .node = self.node,
            .y = std.math.cast(size.CellCountInt, self.y + n) orelse
                std.math.maxInt(size.CellCountInt),
            .x = self.x,
        } };
        var node: *List.Node = self.node;
        var n_left: usize = n - rows;
        while (true) {
            node = node.next orelse return .{ .overflow = .{
                .end = .{
                    .node = node,
                    .y = node.rows() - 1,
                    .x = @min(self.x, node.cols() - 1),
                },
                .remaining = n_left,
            } };
            if (n_left <= node.rows()) return .{ .offset = .{
                .node = node,
                .y = std.math.cast(size.CellCountInt, n_left - 1) orelse
                    std.math.maxInt(size.CellCountInt),
                .x = @min(self.x, node.cols() - 1),
            } };
            n_left -= node.rows();
        }
    }
    pub fn upOverflow(self: Pin, n: usize) union(enum) {
        offset: Pin,
        overflow: struct {
            end: Pin,
            remaining: usize,
        },
    } {
        if (n <= self.y) return .{ .offset = .{
            .node = self.node,
            .y = std.math.cast(size.CellCountInt, self.y - n) orelse
                std.math.maxInt(size.CellCountInt),
            .x = self.x,
        } };
        var node: *List.Node = self.node;
        var n_left: usize = n - self.y;
        while (true) {
            node = node.prev orelse return .{ .overflow = .{
                .end = .{
                    .node = node,
                    .y = 0,
                    .x = @min(self.x, node.cols() - 1),
                },
                .remaining = n_left,
            } };
            if (n_left <= node.rows()) return .{ .offset = .{
                .node = node,
                .y = std.math.cast(size.CellCountInt, node.rows() - n_left) orelse
                    std.math.maxInt(size.CellCountInt),
                .x = @min(self.x, node.cols() - 1),
            } };
            n_left -= node.rows();
        }
    }
};
pub const Builder = struct {
    pool: MemoryPool,
    pages: List = .{},
    page_serial: u64 = 0,
    page_size: usize = 0,
    options: Options,
    finished: bool = false,
    pub fn init(
        alloc: Allocator,
        options: Options,
    ) Allocator.Error!Builder {
        return .{
            .pool = try MemoryPool.init(
                alloc,
                pageAllocator(alloc),
                page_preheat,
            ),
            .options = options,
        };
    }
    pub fn deinit(self: *Builder) void {
        if (self.finished) return;
        while (self.pages.popFirst()) |node| destroyNodeExt(
            &self.pool,
            node,
            &self.page_size,
        );
        self.pool.deinit();
        self.* = undefined;
    }
    pub fn allocatePage(
        self: *Builder,
        capacity: Capacity,
    ) Allocator.Error!*Page {
        const node = try createPageExt(
            &self.pool,
            .{ .cap = capacity },
            &self.page_serial,
            &self.page_size,
        );
        self.pages.append(node);
        return node.pageAssumeResident();
    }
    pub const FinishError = Allocator.Error || error{
        InvalidDimensions,
        InvalidPageDimensions,
        NoPages,
        InsufficientRows,
    };
    pub fn finish(self: *Builder) FinishError!PageList {
        if (self.options.cols == 0 or self.options.rows == 0) {
            return error.InvalidDimensions;
        }
        if (self.pages.first == null) return error.NoPages;
        const total_rows: usize = total_rows: {
            var total_rows: usize = 0;
            var node = self.pages.first;
            while (node) |current| : (node = current.next) {
                if (current.cols() == 0 or current.rows() == 0) {
                    return error.InvalidPageDimensions;
                }
                total_rows += current.rows();
            }
            if (total_rows < self.options.rows) return error.InsufficientRows;
            break :total_rows total_rows;
        };
        const active_top: Pin = active_top: {
            var rem = self.options.rows;
            var node = self.pages.last;
            while (node) |current| : (node = current.prev) {
                if (rem <= current.rows()) break :active_top .{
                    .node = current,
                    .y = current.rows() - rem,
                };
                rem -= current.rows();
            } else unreachable;
        };
        const viewport_pin = try self.pool.pins.create();
        errdefer self.pool.pins.destroy(viewport_pin);
        viewport_pin.* = active_top;
        var tracked_pins = try initTrackedPins(self.pool.alloc, viewport_pin);
        errdefer tracked_pins.deinit(self.pool.alloc);
        var limits: Limits = .init(self.options.cols, self.options.rows);
        limits.set(.bytes, self.options.max_size);
        limits.set(.lines, self.options.max_lines);
        const result: PageList = .{
            .cols = self.options.cols,
            .rows = self.options.rows,
            .pool = self.pool,
            .pages = self.pages,
            .page_serial = self.page_serial,
            .page_serial_epoch = 0,
            .page_size = self.page_size,
            .limits = limits,
            .total_rows = total_rows,
            .tracked_pins = tracked_pins,
            .viewport = .{ .active = {} },
            .viewport_pin = viewport_pin,
            .viewport_pin_row_offset = null,
        };
        result.assertIntegrity();
        self.finished = true;
        return result;
    }
};
test "PageList Builder transfers mixed-width pages" {
    const testing = std.testing;
    var result: PageList = result: {
        var builder = try Builder.init(testing.allocator, .{
            .cols = 4,
            .rows = 3,
            .max_size = null,
            .max_lines = null,
        });
        defer builder.deinit();
        const first = try builder.allocatePage(.{
            .cols = 2,
            .rows = 2,
        });
        first.size.rows = 2;
        first.getRowAndCell(0, 0).cell.* = .init('A');
        const second = try builder.allocatePage(.{
            .cols = 4,
            .rows = 2,
        });
        second.size.rows = 2;
        second.getRowAndCell(0, 0).cell.* = .init('B');
        break :result try builder.finish();
    };
    defer result.deinit();
    try testing.expectEqual(@as(size.CellCountInt, 4), result.cols);
    try testing.expectEqual(@as(size.CellCountInt, 3), result.rows);
    try testing.expectEqual(@as(usize, 2), result.totalPages());
    try testing.expectEqual(@as(usize, 1), result.countTrackedPins());
    try testing.expectEqual(Viewport.active, result.viewport);
    const screen_top = result.getTopLeft(.screen);
    try testing.expectEqual(@as(size.CellCountInt, 2), screen_top.node.cols());
    try testing.expectEqual(@as(u21, 'A'), screen_top
        .node.page().getRowAndCell(0, 0).cell.codepoint());
    const active_top = result.getTopLeft(.active);
    try testing.expectEqual(screen_top.node, active_top.node);
    try testing.expectEqual(@as(size.CellCountInt, 1), active_top.y);
    try testing.expectEqual(@as(size.CellCountInt, 4), active_top
        .node.next.?.cols());
    try testing.expectEqual(@as(u21, 'B'), active_top
        .node.next.?.page().getRowAndCell(0, 0).cell.codepoint());
    result.assertIntegrity();
}
test "PageList Builder validates the finished list" {
    const testing = std.testing;
    {
        var builder = try Builder.init(testing.allocator, .{
            .cols = 0,
            .rows = 1,
        });
        defer builder.deinit();
        try testing.expectError(error.InvalidDimensions, builder.finish());
    }
    {
        var builder = try Builder.init(testing.allocator, .{
            .cols = 1,
            .rows = 1,
        });
        defer builder.deinit();
        try testing.expectError(error.NoPages, builder.finish());
    }
    {
        var builder = try Builder.init(testing.allocator, .{
            .cols = 1,
            .rows = 1,
        });
        defer builder.deinit();
        const page = try builder.allocatePage(.{ .cols = 1, .rows = 1 });
        page.size.rows = 0;
        try testing.expectError(
            error.InvalidPageDimensions,
            builder.finish(),
        );
    }
    {
        var builder = try Builder.init(testing.allocator, .{
            .cols = 1,
            .rows = 2,
        });
        defer builder.deinit();
        const page = try builder.allocatePage(.{ .cols = 1, .rows = 1 });
        page.size.rows = 1;
        try testing.expectError(error.InsufficientRows, builder.finish());
    }
}
test "PageList Builder finish is transactional on allocation failure" {
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var builder = try Builder.init(failing.allocator(), .{
        .cols = 1,
        .rows = 1,
    });
    defer builder.deinit();
    const page = try builder.allocatePage(.{ .cols = 1, .rows = 1 });
    page.size.rows = 1;
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, builder.finish());
    try testing.expect(failing.has_induced_failure);
    try testing.expect(builder.pages.first != null);
    try testing.expectEqual(builder.pages.first, builder.pages.last);
}
test "PageList PageAllocation finalizes pages and preserves live state" {
    const testing = std.testing;
    var result: PageList = result: {
        var builder = try Builder.init(testing.allocator, .{
            .cols = 4,
            .rows = 2,
            .max_size = null,
            .max_lines = null,
        });
        defer builder.deinit();
        const first = try builder.allocatePage(.{ .cols = 3, .rows = 2 });
        first.size.rows = 2;
        first.getRowAndCell(0, 0).cell.* = .init('C');
        const second = try builder.allocatePage(.{ .cols = 4, .rows = 2 });
        second.size.rows = 2;
        second.getRowAndCell(0, 0).cell.* = .init('D');
        break :result try builder.finish();
    };
    defer result.deinit();
    const old_first = result.pages.first.?;
    const old_last = result.pages.last.?;
    const active_top = result.getTopLeft(.active);
    const tracked_active = try result.trackPin(active_top);
    result.scroll(.{ .row = 1 });
    try testing.expectEqual(Viewport.pin, result.viewport);
    try testing.expectEqual(@as(usize, 1), result.scrollbar().offset);
    {
        var allocation = try result.allocatePage(.{ .cols = 4, .rows = 1 });
        defer allocation.deinit();
        const page = allocation.page();
        page.size.rows = 1;
        page.getRowAndCell(0, 0).cell.* = .init('B');
        try allocation.finalize(.prepend, .{});
    }
    {
        var allocation = try result.allocatePage(.{ .cols = 2, .rows = 2 });
        defer allocation.deinit();
        const page = allocation.page();
        page.size.rows = 2;
        page.getRowAndCell(0, 0).cell.* = .init('A');
        try allocation.finalize(.prepend, .{});
    }
    try testing.expectEqual(@as(usize, 4), result.totalPages());
    try testing.expectEqual(@as(usize, 7), result.total_rows);
    try testing.expectEqual(old_last, result.pages.last.?);
    try testing.expectEqual(old_first, result.pages.first.?.next.?.next.?);
    try testing.expectEqual(
        @as(u21, 'A'),
        result.pages.first.?.page().getRowAndCell(0, 0).cell.codepoint(),
    );
    try testing.expectEqual(
        @as(u21, 'B'),
        result.pages.first.?.next.?
            .page().getRowAndCell(0, 0).cell.codepoint(),
    );
    try testing.expect(active_top.eql(result.getTopLeft(.active)));
    try testing.expect(active_top.eql(tracked_active.*));
    try testing.expectEqual(Viewport.pin, result.viewport);
    try testing.expectEqual(old_first, result.viewport_pin.node);
    try testing.expectEqual(@as(size.CellCountInt, 1), result.viewport_pin.y);
    const scrollbar_state = result.scrollbar();
    try testing.expectEqual(@as(usize, 7), scrollbar_state.total);
    try testing.expectEqual(@as(usize, 4), scrollbar_state.offset);
    try testing.expectEqual(@as(usize, 2), scrollbar_state.len);
    result.assertIntegrity();
}
test "PageList PageAllocation compresses prepended pages unless visible" {
    const testing = std.testing;
    const Case = struct {
        viewport: enum { active, pin, top },
        compressed: bool,
    };
    const cases = [_]Case{
        .{ .viewport = .active, .compressed = true },
        .{ .viewport = .pin, .compressed = true },
        .{ .viewport = .top, .compressed = false },
    };
    for (cases) |case| {
        var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
        defer s.deinit();
        try s.growColdPagesForTest(1);
        switch (case.viewport) {
            .active => {},
            .pin => s.scroll(.{ .row = 1 }),
            .top => s.scroll(.{ .top = {} }),
        }
        try testing.expectEqual(
            @as(Viewport, switch (case.viewport) {
                .active => .active,
                .pin => .pin,
                .top => .top,
            }),
            s.viewport,
        );
        const capacity = s.pages.first.?.capacity();
        var allocation = try s.allocatePage(capacity);
        defer allocation.deinit();
        const page = allocation.page();
        page.size.rows = capacity.rows;
        page.getRowAndCell(0, 0).cell.* = .init('X');
        try allocation.finalize(.prepend, .{ .compress = true });
        const node = s.pages.first.?;
        try testing.expectEqual(case.compressed, node.isCompressed());
        try testing.expectEqual(
            @as(usize, if (case.compressed) 1 else 0),
            s.memoryStats().compressed_pages,
        );
        try testing.expectEqual(
            @as(u21, 'X'),
            node.page().getRowAndCell(0, 0).cell.codepoint(),
        );
        s.assertIntegrity();
    }
}
test "PageList PageAllocation stays detached until finalize" {
    const testing = std.testing;
    var result = try init(testing.allocator, .{
        .cols = 1,
        .rows = 1,
        .max_size = null,
        .max_lines = null,
    });
    defer result.deinit();
    const initial_first = result.pages.first.?;
    const initial_last = result.pages.last.?;
    const initial_total_rows = result.total_rows;
    const initial_page_size = result.page_size;
    var detached = try result.allocatePage(.{ .cols = 1, .rows = 1 });
    detached.page().size.rows = 1;
    try testing.expectEqual(initial_first, result.pages.first.?);
    try testing.expectEqual(initial_last, result.pages.last.?);
    try testing.expectEqual(initial_total_rows, result.total_rows);
    try testing.expectEqual(initial_page_size, result.page_size);
    result.assertIntegrity();
    detached.deinit();
    result.assertIntegrity();
    var invalid = try result.allocatePage(.{ .cols = 1, .rows = 1 });
    defer invalid.deinit();
    try testing.expectError(
        error.InvalidPageDimensions,
        invalid.finalize(.prepend, .{}),
    );
    try testing.expectEqual(initial_first, result.pages.first.?);
    try testing.expectEqual(initial_last, result.pages.last.?);
    try testing.expectEqual(initial_total_rows, result.total_rows);
    try testing.expectEqual(initial_page_size, result.page_size);
    result.assertIntegrity();
}
test "PageList PageAllocation rejects limits before modifying the destination" {
    const testing = std.testing;
    var result = try init(testing.allocator, .{
        .cols = 1,
        .rows = 1,
        .max_size = 0,
        .max_lines = null,
    });
    defer result.deinit();
    {
        var allocation = try result.allocatePage(.{ .cols = 1, .rows = 1 });
        defer allocation.deinit();
        allocation.page().size.rows = 1;
        try allocation.finalize(.prepend, .{});
    }
    const before_first = result.pages.first.?;
    const before_total_rows = result.total_rows;
    const before_page_size = result.page_size;
    var allocation = try result.allocatePage(.{ .cols = 1, .rows = 1 });
    defer allocation.deinit();
    allocation.page().size.rows = 1;
    try testing.expectError(
        error.MaxSizeExceeded,
        allocation.finalize(.prepend, .{}),
    );
    try testing.expectEqual(before_first, result.pages.first.?);
    try testing.expectEqual(before_total_rows, result.total_rows);
    try testing.expectEqual(before_page_size, result.page_size);
    result.assertIntegrity();
}
test "PageList PageAllocation allocation failure leaves list unchanged" {
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var result = try init(failing.allocator(), .{
        .cols = 1,
        .rows = 1,
        .max_size = null,
        .max_lines = null,
    });
    defer result.deinit();
    const initial_first = result.pages.first.?;
    const initial_total_rows = result.total_rows;
    const initial_page_size = result.page_size;
    failing.fail_index = failing.alloc_index;
    var allocations: [64]PageAllocation = undefined;
    var allocation_count: usize = 0;
    defer for (allocations[0..allocation_count]) |*allocation| {
        allocation.deinit();
    };
    var failed = false;
    for (0..64) |_| {
        allocations[allocation_count] = result.allocatePage(.{
            .cols = 1,
            .rows = 1,
        }) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            failed = true;
            break;
        };
        allocation_count += 1;
    }
    try testing.expect(failed);
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(initial_first, result.pages.first.?);
    try testing.expectEqual(initial_total_rows, result.total_rows);
    try testing.expectEqual(initial_page_size, result.page_size);
    result.assertIntegrity();
}
fn mixedWidthPinListForTest(alloc: Allocator) !PageList {
    var result = try init(alloc, .{ .cols = 2, .rows = 1 });
    errdefer result.deinit();
    result.pauseIntegrityChecks(true);
    inline for (.{ 4, 3 }) |cols| {
        const node = try result.createPage(.{ .cap = .{
            .cols = cols,
            .rows = 1,
        } });
        node.page().size.rows = 1;
        result.pages.append(node);
        result.total_rows += 1;
    }
    result.cols = 4;
    return result;
}
test "PageList Pin row movement clamps across mixed-width pages" {
    const testing = std.testing;
    var s = try mixedWidthPinListForTest(testing.allocator);
    defer s.deinit();
    const first = s.pages.first.?;
    const second = first.next.?;
    const third = second.next.?;
    try testing.expect((Pin{ .node = third, .x = 2 }).eql(
        (Pin{ .node = second, .x = 3 }).down(1).?,
    ));
    try testing.expect((Pin{ .node = first, .x = 1 }).eql(
        (Pin{ .node = second, .x = 3 }).up(1).?,
    ));
    switch ((Pin{ .node = second, .x = 3 }).downOverflow(10)) {
        .offset => try testing.expect(false),
        .overflow => |overflow| try testing.expect(
            (Pin{ .node = third, .x = 2 }).eql(overflow.end),
        ),
    }
    switch ((Pin{ .node = second, .x = 3 }).upOverflow(10)) {
        .offset => try testing.expect(false),
        .overflow => |overflow| try testing.expect(
            (Pin{ .node = first, .x = 1 }).eql(overflow.end),
        ),
    }
}
test "PageList Pin wrapping crosses mixed-width pages" {
    const testing = std.testing;
    var s = try mixedWidthPinListForTest(testing.allocator);
    defer s.deinit();
    const first = s.pages.first.?;
    const second = first.next.?;
    const third = second.next.?;
    try testing.expect((Pin{ .node = third, .x = 2 }).eql(
        (Pin{ .node = first, .x = 1 }).rightWrap(7).?,
    ));
    try testing.expect((Pin{ .node = second, .x = 0 }).eql(
        (Pin{ .node = third, .x = 2 }).leftWrap(6).?,
    ));
    try testing.expect((Pin{ .node = first }).leftWrap(1) == null);
    try testing.expect((Pin{ .node = third, .x = 2 }).rightWrap(1) == null);
}
test "PageList Pin rejects columns beyond mixed-width page bounds" {
    const testing = std.testing;
    var s = try mixedWidthPinListForTest(testing.allocator);
    defer s.deinit();
    try testing.expect(s.pin(.{ .screen = .{ .x = 1, .y = 0 } }) != null);
    try testing.expect(s.pin(.{ .screen = .{ .x = 2, .y = 0 } }) == null);
    try testing.expect(s.pin(.{ .screen = .{ .x = 3, .y = 1 } }) != null);
    try testing.expect(s.pin(.{ .screen = .{ .x = 3, .y = 2 } }) == null);
}
pub const Cell = struct {
    node: *List.Node,
    row: *pagepkg.Row,
    cell: *pagepkg.Cell,
    row_idx: size.CellCountInt,
    col_idx: size.CellCountInt,
    pub fn isDirty(self: Cell) bool {
        return self.node.page().dirty or self.row.dirty;
    }
    pub fn style(self: Cell) stylepkg.Style {
        if (self.cell.style_id == stylepkg.default_id) return .{};
        const page = self.node.page();
        return page.styles.get(
            page.memory,
            self.cell.style_id,
        ).*;
    }
    pub fn screenPoint(self: Cell) point.Point {
        var y: u32 = self.row_idx;
        var node_ = self.node;
        while (node_.prev) |node| {
            y += node.rows();
            node_ = node;
        }
        return .{ .screen = .{
            .x = self.col_idx,
            .y = y,
        } };
    }
};
fn growColdPagesForTest(self: *PageList, count: usize) !void {
    while (true) {
        const active_node = self.getTopLeft(.active).node;
        var cold_count: usize = 0;
        var current = self.pages.first;
        while (current) |node| : (current = node.next) {
            if (node == active_node) break;
            cold_count += 1;
        }
        if (cold_count >= count) return;
        _ = try self.grow();
    }
}
fn fillLastPageForTest(self: *PageList) !void {
    const last = self.pages.last.?;
    while (last.rows() < last.capacity().rows) _ = try self.grow();
}
fn expectLivePageSerialsValidForTest(self: *const PageList) !void {
    const testing = std.testing;
    var node = self.pages.first;
    while (node) |live| : (node = live.next) {
        try testing.expect(live.serial >= self.page_serial_epoch);
        try testing.expect(live.serial < self.page_serial);
        try testing.expect(self.nodeIsValid(live, live.serial));
    }
}
test "PageList Pin rightWrap exact row multiple" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 10, .rows = 3 });
    defer s.deinit();
    const start = s.pin(.{ .active = .{ .x = 5, .y = 0 } }).?;
    const wrapped = start.rightWrap(14).?;
    _ = wrapped.rowAndCell();
    try testing.expectEqual(
        point.Point{ .active = .{ .x = 9, .y = 1 } },
        s.pointFromPin(.active, wrapped),
    );
}
test "PageList Pin leftWrap exact row multiple" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 10, .rows = 3 });
    defer s.deinit();
    const start = s.pin(.{ .active = .{ .x = 5, .y = 2 } }).?;
    const wrapped = start.leftWrap(15).?;
    _ = wrapped.rowAndCell();
    try testing.expectEqual(
        point.Point{ .active = .{ .x = 0, .y = 1 } },
        s.pointFromPin(.active, wrapped),
    );
}
test "PageList Pin rightWrap maximum distance" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 1, .rows = 3 });
    defer s.deinit();
    const start = s.pin(.{ .active = .{ .y = 0 } }).?;
    try testing.expectEqual(null, start.rightWrap(std.math.maxInt(usize)));
}
test "PageList Pin leftWrap maximum distance" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 1, .rows = 3 });
    defer s.deinit();
    const start = s.pin(.{ .active = .{ .y = 2 } }).?;
    try testing.expectEqual(null, start.leftWrap(std.math.maxInt(usize)));
}
test "PageList incremental compression skips visible history" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growColdPagesForTest(3);
    const initial_activity = s.page_compression.activity_serial;
    try testing.expect(initial_activity > 0);
    s.scroll(.top);
    const top_activity = s.page_compression.activity_serial;
    try testing.expect(top_activity != initial_activity);
    try testing.expectEqual(
        IncrementalCompressionResult.complete,
        s.compress(.drain),
    );
    const first = s.pages.first.?;
    const second = first.next.?;
    try testing.expectEqual(first, s.getTopLeft(.viewport).node);
    try testing.expectEqual(first, s.getBottomRight(.viewport).?.node);
    try testing.expect(!first.isCompressed());
    var eligible: CompressionIterator = .init(&s);
    var compressed_pages: usize = 0;
    while (eligible.next()) |node| {
        compressed_pages += 1;
        try testing.expect(node.isCompressed());
    }
    try testing.expect(compressed_pages > 0);
    s.scroll(.{ .row = first.rows() });
    try testing.expectEqual(second, s.getTopLeft(.viewport).node);
    _ = second.page();
    try testing.expect(!second.isCompressed());
    _ = s.compress(.drain);
    try testing.expect(first.isCompressed());
    try testing.expect(!second.isCompressed());
    s.scroll(.active);
    _ = s.compress(.drain);
    try testing.expect(second.isCompressed());
    try testing.expect(!s.page_compression.flags.did_compress);
    try testing.expect(!s.page_compression.flags.verifying);
    try testing.expectEqual(@as(?u64, null), s.page_compression.last_serial);
    try testing.expectEqual(@as(u64, 0), s.page_compression.next_serial);
}
test "PageList owns incremental compression state" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const state: IncrementalCompressionState = .{
        .flags = .{
            .did_compress = true,
            .verifying = true,
        },
        .activity_serial = 42,
        .last_serial = 42,
        .next_serial = 43,
    };
    s.page_compression = state;
    s.scroll(.top);
    try testing.expectEqual(
        IncrementalCompressionState{ .activity_serial = 43 },
        s.page_compression,
    );
    s.page_compression = state;
    s.scroll(.top);
    try testing.expectEqual(
        IncrementalCompressionState{ .activity_serial = 43 },
        s.page_compression,
    );
    s.page_compression = state;
    s.scroll(.active);
    try testing.expectEqual(
        IncrementalCompressionState{ .activity_serial = 43 },
        s.page_compression,
    );
    s.page_compression = state;
    try s.resize(.{ .cols = 80, .rows = 24 });
    try testing.expectEqual(
        IncrementalCompressionState{ .activity_serial = 43 },
        s.page_compression,
    );
    s.page_compression = state;
    s.reset();
    try testing.expectEqual(
        IncrementalCompressionState{ .activity_serial = 42 },
        s.page_compression,
    );
    s.page_compression = state;
    try testing.expectEqual(
        IncrementalCompressionResult.complete,
        s.compress(.full),
    );
    try testing.expectEqual(
        IncrementalCompressionState{ .activity_serial = 42 },
        s.page_compression,
    );
    s.page_compression = state;
    var cloned = try s.clone(testing.allocator, .{
        .top = .{ .active = .{} },
    });
    defer cloned.deinit();
    try testing.expectEqual(
        IncrementalCompressionState{},
        cloned.page_compression,
    );
}
test "PageList replacements preserve compression continuation and mark activity" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const state: IncrementalCompressionState = .{
        .flags = .{ .verifying = true },
        .activity_serial = 42,
        .last_serial = 7,
        .next_serial = 8,
    };
    const expected: IncrementalCompressionState = .{
        .flags = .{ .verifying = true },
        .activity_serial = 43,
        .last_serial = 7,
        .next_serial = 8,
    };
    s.page_compression = state;
    const replacement = try s.increaseCapacity(s.pages.first.?, null);
    try testing.expectEqual(expected, s.page_compression);
    s.page_compression = state;
    _ = (try s.compact(replacement)).?;
    try testing.expectEqual(expected, s.page_compression);
}
test "PageList incremental compression bounds inspected pages" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growColdPagesForTest(incremental_compression_max_inspected + 1);
    _ = s.compress(.full);
    s.page_compression.reset();
    s.page_compression.markActivity();
    try testing.expectEqual(
        incremental_compression_max_inspected + 1,
        s.memoryStats().compressed_pages,
    );
    var expected_last = s.pages.first.?;
    for (1..incremental_compression_max_inspected) |_|
        expected_last = expected_last.next.?;
    const first = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, first);
    try testing.expectEqual(
        expected_last.serial,
        s.page_compression.last_serial.?,
    );
    const second = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, second);
    try testing.expect(s.page_compression.flags.verifying);
    try testing.expect(s.page_compression.last_serial == null);
    try testing.expectEqual(
        IncrementalCompressionResult.pending,
        s.compress(.incremental),
    );
    try testing.expectEqual(
        IncrementalCompressionResult.complete,
        s.compress(.incremental),
    );
}
test "PageList incremental compression advances after failure" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growColdPagesForTest(2);
    const first = s.pages.first.?;
    const second = first.next.?;
    var prng = std.Random.DefaultPrng.init(0x494E_4352_5041_5353);
    prng.random().bytes(first.page().memory);
    const failed = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, failed);
    try testing.expect(!first.isCompressed());
    const continued = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, continued);
    try testing.expect(second.isCompressed());
}
test "PageList incremental compression advances after allocation failure" {
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing.allocator();
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growColdPagesForTest(2);
    const first = s.pages.first.?;
    const second = first.next.?;
    failing.fail_index = failing.alloc_index;
    const failed = s.compress(.incremental);
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(IncrementalCompressionResult.pending, failed);
    try testing.expect(!first.isCompressed());
    failing.fail_index = std.math.maxInt(usize);
    const continued = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, continued);
    try testing.expect(second.isCompressed());
}
test "PageList incremental compression advances after decommit failure" {
    const testing = std.testing;
    const tw = compressPage_tw;
    defer tw.end(.reset) catch unreachable;
    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growColdPagesForTest(2);
    tw.errorAlways(.decommit, error.DecommitFailed);
    const failed = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, failed);
    try testing.expect(!s.pages.first.?.isCompressed());
    try tw.end(.reset);
    const continued = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, continued);
    try testing.expect(s.pages.first.?.next.?.isCompressed());
}
test "PageList incremental compression restarts after replacement" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growColdPagesForTest(1);
    const initial = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, initial);
    try testing.expect(s.pages.first.?.isCompressed());
    const old = s.pages.first.?;
    const old_serial = old.serial;
    var replacement = old;
    while (replacement.page().memory.len <= std_size) {
        replacement = try s.increaseCapacity(
            replacement,
            .grapheme_bytes,
        );
    }
    try testing.expect(replacement.serial != old_serial);
    try testing.expect(replacement.page().memory.len > std_size);
    try testing.expect(!replacement.isCompressed());
    const restarted = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, restarted);
    try testing.expect(replacement.isCompressed());
}
test "PageList incremental compression restarts after reset" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growColdPagesForTest(1);
    const initial = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, initial);
    try testing.expect(s.pages.first.?.isCompressed());
    s.reset();
    try s.growColdPagesForTest(1);
    const restarted = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, restarted);
    try testing.expect(s.pages.first.?.isCompressed());
}
test "PageList incremental compression restarts after active boundary resize" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growColdPagesForTest(1);
    const initial = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, initial);
    try testing.expect(s.pages.first.?.isCompressed());
    const first = s.pages.first.?;
    const all_rows: size.CellCountInt = @intCast(s.total_rows);
    try s.resize(.{ .rows = all_rows });
    try testing.expectEqual(first, s.getTopLeft(.active).node);
    _ = first.page();
    const active = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, active);
    try testing.expectEqual(
        IncrementalCompressionResult.complete,
        s.compress(.incremental),
    );
    try s.resize(.{ .rows = 24 });
    try s.growColdPagesForTest(1);
    try testing.expectEqual(
        IncrementalCompressionResult.pending,
        s.compress(.incremental),
    );
    try testing.expect(first.isCompressed());
}
test "PageList incremental compression restarts after prune reuse" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_size = 2 * PagePool.item_size,
    });
    defer s.deinit();
    try s.growColdPagesForTest(1);
    const initial = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, initial);
    try testing.expect(s.pages.first.?.isCompressed());
    const reused = s.pages.first.?;
    const old_serial = reused.serial;
    while (s.pages.last.?.rows() < s.pages.last.?.capacity().rows) {
        _ = try s.grow();
    }
    try testing.expectEqual(reused, (try s.grow()).?);
    try testing.expect(reused.serial != old_serial);
    try s.growColdPagesForTest(1);
    _ = s.compress(.incremental);
    try testing.expectEqual(@as(usize, 1), s.memoryStats().compressed_pages);
}
test "PageList bounded pruning after partial erase preserves live serials" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_size = 2 * PagePool.item_size,
    });
    defer s.deinit();
    while (s.totalPages() < 2) _ = try s.grow();
    const first = s.pages.first.?;
    const old_serial = first.serial;
    const old_rows = first.rows();
    s.eraseHistory(.{ .history = .{ .y = 0 } });
    try testing.expectEqual(first, s.pages.first.?);
    try testing.expectEqual(old_rows - 1, first.rows());
    try testing.expect(!s.nodeIsValid(first, old_serial));
    try s.fillLastPageForTest();
    _ = try s.grow();
    try s.expectLivePageSerialsValidForTest();
}
test "PageList partial erase restarts compression before continuation" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growColdPagesForTest(incremental_compression_max_inspected + 1);
    _ = s.compress(.full);
    const first = s.pages.first.?;
    try testing.expect(first.isCompressed());
    var marker = first;
    for (1..incremental_compression_max_inspected) |_| marker = marker.next.?;
    s.page_compression = .{
        .flags = .{ .verifying = true },
        .last_serial = marker.serial,
        .next_serial = s.page_serial,
    };
    const activity = s.page_compression.activity_serial;
    s.eraseHistory(.{ .history = .{ .y = 0 } });
    try testing.expect(!first.isCompressed());
    try testing.expect(activity != s.page_compression.activity_serial);
    try testing.expectEqual(
        IncrementalCompressionResult.pending,
        s.compress(.incremental),
    );
    try testing.expect(first.isCompressed());
}
test "PageList bounded pruning after split invalidation preserves live serials" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_size = 2 * PagePool.item_size,
    });
    defer s.deinit();
    while (s.totalPages() < 2) _ = try s.grow();
    const first = s.pages.first.?;
    const old_serial = first.serial;
    const activity = s.page_compression.activity_serial;
    try s.split(.{
        .node = first,
        .y = first.rows() / 2,
        .x = 0,
    });
    try testing.expect(!s.nodeIsValid(first, old_serial));
    try testing.expect(activity != s.page_compression.activity_serial);
    try s.fillLastPageForTest();
    _ = try s.grow();
    try s.expectLivePageSerialsValidForTest();
}
test "PageList repeated bounded pruning after split preserves live serials" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_size = 3 * PagePool.item_size,
    });
    defer s.deinit();
    const epoch = s.page_serial_epoch;
    while (s.totalPages() < 3) _ = try s.grow();
    const first = s.pages.first.?;
    try s.split(.{
        .node = first,
        .y = first.rows() / 2,
        .x = 0,
    });
    for (0..2) |_| {
        while (s.pages.last.?.rows() < s.pages.last.?.capacity().rows) {
            _ = try s.grow();
        }
        _ = try s.grow();
        try testing.expectEqual(epoch, s.page_serial_epoch);
        try s.expectLivePageSerialsValidForTest();
    }
}
test "PageList bounded pruning after front replacement preserves live serials" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_size = 2 * PagePool.item_size,
    });
    defer s.deinit();
    while (s.totalPages() < 2) _ = try s.grow();
    const old = s.pages.first.?;
    const old_serial = old.serial;
    const replacement = try s.increaseCapacity(old, null);
    try testing.expect(replacement != old);
    try testing.expect(!s.nodeIsValid(old, old_serial));
    try s.fillLastPageForTest();
    _ = try s.grow();
    try s.expectLivePageSerialsValidForTest();
}
test "PageList bounded pruning after middle replacement preserves live serials" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_size = 3 * PagePool.item_size,
    });
    defer s.deinit();
    while (s.totalPages() < 3) _ = try s.grow();
    const old = s.pages.first.?.next.?;
    const old_serial = old.serial;
    const replacement = try s.increaseCapacity(old, null);
    try testing.expect(replacement != old);
    try testing.expect(!s.nodeIsValid(old, old_serial));
    for (0..2) |_| {
        try s.fillLastPageForTest();
        _ = try s.grow();
        try s.expectLivePageSerialsValidForTest();
    }
}
test "PageList incremental compression restarts after earlier replacement" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growColdPagesForTest(3);
    _ = s.compress(.incremental);
    _ = s.compress(.incremental);
    try testing.expect(s.pages.first.?.isCompressed());
    try testing.expect(s.pages.first.?.next.?.isCompressed());
    const old_first = s.pages.first.?;
    const old_serial = old_first.serial;
    const replacement = try s.increaseCapacity(
        old_first,
        .grapheme_bytes,
    );
    try testing.expect(replacement.serial != old_serial);
    try testing.expect(!replacement.isCompressed());
    _ = s.compress(.incremental);
    try testing.expect(replacement.isCompressed());
}
test "PageList incremental compression keeps progress after tail growth" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growColdPagesForTest(incremental_compression_max_inspected + 1);
    _ = s.compress(.full);
    s.page_compression.reset();
    s.page_compression.markActivity();
    var expected_last = s.pages.first.?;
    for (1..incremental_compression_max_inspected) |_|
        expected_last = expected_last.next.?;
    const first = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, first);
    try testing.expectEqual(
        expected_last.serial,
        s.page_compression.last_serial.?,
    );
    const next_serial = s.page_serial;
    while (s.page_serial == next_serial) _ = try s.grow();
    const continued = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, continued);
    try testing.expect(s.page_compression.flags.verifying);
}
test "PageList memory usage" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const fresh = s.memoryUsage();
    try testing.expectEqual(s.totalPages(), fresh.pages);
    try testing.expectEqual(page_preheat * PagePool.item_size, fresh.virtual_bytes);
    try testing.expectEqual(s.page_size, fresh.resident_bytes);
    try testing.expect(fresh.resident_bytes <= fresh.virtual_bytes);
    try testing.expectEqual(@as(usize, 0), fresh.compressed_pages);
    try testing.expectEqual(@as(usize, 0), fresh.compressed_bytes);
    try s.growColdPagesForTest(2);
    const before = s.memoryUsage();
    try testing.expectEqual(s.totalPages(), before.pages);
    try testing.expectEqual(
        s.page_size + s.pool.pages.freeCount() * PagePool.item_size,
        before.virtual_bytes,
    );
    try testing.expect(before.resident_bytes <= before.virtual_bytes);
    _ = s.compress(.full);
    const compressed = s.memoryUsage();
    try testing.expectEqual(before.pages, compressed.pages);
    try testing.expectEqual(before.virtual_bytes, compressed.virtual_bytes);
    try testing.expect(compressed.resident_bytes < before.resident_bytes);
    try testing.expectEqual(@as(usize, 2), compressed.compressed_pages);
    try testing.expect(compressed.compressed_bytes > 0);
    try testing.expectEqual(
        s.memoryStats().estimatedResidentBytes(),
        compressed.resident_bytes,
    );
    try testing.expectEqual(compressed, s.memoryUsage());
    _ = s.pages.first.?.page();
    const restored = s.memoryUsage();
    try testing.expectEqual(@as(usize, 1), restored.compressed_pages);
    try testing.expect(restored.resident_bytes > compressed.resident_bytes);
    try testing.expectEqual(before.virtual_bytes, restored.virtual_bytes);
    s.eraseRows(.{ .history = .{} }, null);
    const erased = s.memoryUsage();
    try testing.expect(erased.pages < restored.pages);
    try testing.expectEqual(before.virtual_bytes, erased.virtual_bytes);
    try testing.expect(erased.resident_bytes < restored.resident_bytes);
}
test "PageList memory stats do not restore compressed pages" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growColdPagesForTest(2);
    const before = s.memoryStats();
    try testing.expectEqual(s.totalPages(), before.resident_pages);
    try testing.expectEqual(@as(usize, 0), before.compressed_pages);
    try testing.expectEqual(s.page_size, before.raw_bytes);
    try testing.expectEqual(before.raw_bytes, before.resident_raw_bytes);
    try testing.expectEqual(@as(usize, 0), before.decommitted_raw_bytes);
    try testing.expectEqual(s.page_size, before.resident_backing_bytes);
    try testing.expectEqual(@as(usize, 0), before.encoded_bytes);
    try testing.expectEqual(
        before.resident_backing_bytes,
        before.estimatedResidentBytes(),
    );
    try testing.expectEqual(@as(usize, 0), before.estimatedSavings());
    _ = s.compress(.full);
    const first = s.pages.first.?;
    try testing.expectEqual(Node.Storage.compressed, first.storage());
    try testing.expect(first.pageIfResident() == null);
    const after = s.memoryStats();
    try testing.expect(first.isCompressed());
    try testing.expectEqual(s.totalPages(), after.resident_pages + after.compressed_pages);
    try testing.expectEqual(@as(usize, 2), after.compressed_pages);
    try testing.expectEqual(s.page_size, after.raw_bytes);
    try testing.expectEqual(
        after.raw_bytes,
        after.resident_raw_bytes + after.decommitted_raw_bytes,
    );
    try testing.expectEqual(
        after.resident_backing_bytes + after.encoded_bytes,
        after.estimatedResidentBytes(),
    );
    try testing.expectEqual(
        after.decommitted_raw_bytes - after.encoded_bytes,
        after.estimatedSavings(),
    );
    const first_raw_len = first.metadata().memory.len;
    const first_encoded_len = first.data.compressed.encoded.len;
    _ = first.page();
    try testing.expectEqual(Node.Storage.resident, first.storage());
    try testing.expect(first.pageIfResident() != null);
    const restored = s.memoryStats();
    try testing.expectEqual(after.resident_pages + 1, restored.resident_pages);
    try testing.expectEqual(after.compressed_pages - 1, restored.compressed_pages);
    try testing.expectEqual(after.raw_bytes, restored.raw_bytes);
    try testing.expectEqual(
        after.resident_raw_bytes + first_raw_len,
        restored.resident_raw_bytes,
    );
    try testing.expectEqual(
        after.decommitted_raw_bytes - first_raw_len,
        restored.decommitted_raw_bytes,
    );
    try testing.expectEqual(
        after.resident_backing_bytes + first_raw_len,
        restored.resident_backing_bytes,
    );
    try testing.expectEqual(
        after.encoded_bytes - first_encoded_len,
        restored.encoded_bytes,
    );
}
test "PageList preserved page keeps compressed storage" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const node = s.pages.first.?;
    const resident = node.page();
    resident.dirty = true;
    resident.getRowAndCell(3, 2).cell.* = .init('X');
    {
        var failing = testing.FailingAllocator.init(alloc, .{
            .fail_index = 0,
        });
        var preserved = try node.pagePreservingState(failing.allocator());
        defer preserved.deinit();
        switch (preserved) {
            .borrowed => |page_| try testing.expectEqual(resident, page_),
            .owned => try testing.expect(false),
        }
        try testing.expect(!failing.has_induced_failure);
    }
    const expected = try alloc.dupe(u8, resident.memory);
    defer alloc.free(expected);
    const retained_ptr = resident.memory.ptr;
    try testing.expect(s.compressPage(node));
    const stats = s.memoryStats();
    const expected_encoded = try alloc.dupe(u8, node.data.compressed.encoded);
    defer alloc.free(expected_encoded);
    try testing.expect(std.mem.allEqual(u8, node.metadata().memory, 0));
    var failing = testing.FailingAllocator.init(alloc, .{
        .fail_index = 0,
    });
    try testing.expectError(
        error.OutOfMemory,
        node.pagePreservingState(failing.allocator()),
    );
    try testing.expectEqual(Node.Storage.compressed, node.storage());
    try testing.expectEqual(stats, s.memoryStats());
    var preserved = try node.pagePreservingState(alloc);
    defer preserved.deinit();
    switch (preserved) {
        .borrowed => try testing.expect(false),
        .owned => {},
    }
    const page_ = preserved.page();
    try testing.expect(page_.memory.ptr != retained_ptr);
    try testing.expectEqualSlices(u8, expected, page_.memory);
    try testing.expect(page_.dirty);
    try testing.expectEqual(
        @as(u21, 'X'),
        page_.getRowAndCell(3, 2).cell.content.codepoint.data,
    );
    try testing.expectEqual(Node.Storage.compressed, node.storage());
    try testing.expectEqual(stats, s.memoryStats());
    try testing.expectEqual(retained_ptr, node.metadata().memory.ptr);
    try testing.expect(std.mem.allEqual(u8, node.metadata().memory, 0));
    try testing.expectEqualSlices(
        u8,
        expected_encoded,
        node.data.compressed.encoded,
    );
}
test "PageList memory stats include unused pool backing" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const node = try s.createPage(.{ .cap = .{ .cols = 1, .rows = 1 } });
    try testing.expectEqual(Node.Owned.pool, node.owned);
    try testing.expect(node.page().memory.len < PagePool.item_size);
    node.page().size.rows = 1;
    s.pages.append(node);
    s.total_rows += 1;
    const raw_len = node.metadata().memory.len;
    const before = s.memoryStats();
    try testing.expect(before.raw_bytes < s.page_size);
    try testing.expectEqual(before.raw_bytes, before.resident_raw_bytes);
    try testing.expectEqual(s.page_size, before.resident_backing_bytes);
    try testing.expectEqual(s.page_size, before.estimatedResidentBytes());
    try testing.expect(s.compressPage(node));
    const encoded_len = node.data.compressed.encoded.len;
    const compressed = s.memoryStats();
    try testing.expectEqual(before.raw_bytes, compressed.raw_bytes);
    try testing.expectEqual(
        before.resident_raw_bytes - raw_len,
        compressed.resident_raw_bytes,
    );
    try testing.expectEqual(raw_len, compressed.decommitted_raw_bytes);
    try testing.expectEqual(
        before.resident_backing_bytes - raw_len,
        compressed.resident_backing_bytes,
    );
    try testing.expectEqual(encoded_len, compressed.encoded_bytes);
    try testing.expectEqual(
        before.estimatedResidentBytes() - raw_len + encoded_len,
        compressed.estimatedResidentBytes(),
    );
}
test "PageList does not compress the mixed history and active page" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    _ = try s.grow();
    const active = s.getTopLeft(.active);
    try testing.expectEqual(s.pages.first.?, active.node);
    try testing.expect(active.y > 0);
    _ = s.compress(.full);
    try testing.expect(!s.pages.first.?.isCompressed());
}
test "PageList compresses only complete cold history pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const active_rows = initialCapacity(80).rows + 1;
    var s = try init(alloc, .{ .cols = 80, .rows = active_rows });
    defer s.deinit();
    try s.growColdPagesForTest(2);
    _ = try s.grow();
    const active = s.getTopLeft(.active);
    const active_node = active.node;
    try testing.expect(active.y > 0);
    try testing.expect(active_node != s.pages.last.?);
    var expected_compressed: usize = 0;
    var expected_raw_bytes: usize = 0;
    var current = s.pages.first;
    while (current) |node| : (current = node.next) {
        if (node == active_node) break;
        expected_compressed += 1;
        expected_raw_bytes += node.metadata().memory.len;
    }
    try testing.expectEqual(@as(usize, 2), expected_compressed);
    const first = s.pages.first.?;
    first.page().getRowAndCell(0, 0).cell.* = .init('X');
    const expected = try alloc.dupe(u8, first.page().memory);
    defer alloc.free(expected);
    const first_memory = first.page().memory.ptr;
    const page_size = s.page_size;
    _ = s.compress(.full);
    const memory = s.memoryStats();
    try testing.expectEqual(expected_compressed, memory.compressed_pages);
    try testing.expectEqual(expected_raw_bytes, memory.decommitted_raw_bytes);
    try testing.expect(memory.encoded_bytes < memory.decommitted_raw_bytes);
    try testing.expectEqual(page_size, s.page_size);
    current = s.pages.first;
    var actual_encoded_bytes: usize = 0;
    while (current) |node| : (current = node.next) {
        if (node == active_node) break;
        try testing.expect(node.isCompressed());
        actual_encoded_bytes += node.data.compressed.encoded.len;
    }
    try testing.expectEqual(actual_encoded_bytes, memory.encoded_bytes);
    current = active_node;
    while (current) |node| : (current = node.next) {
        try testing.expect(!node.isCompressed());
    }
    try testing.expectEqual(first_memory, first.metadata().memory.ptr);
    try testing.expectEqualSlices(u8, expected, first.page().memory);
    try testing.expectEqual(first_memory, first.page().memory.ptr);
}
test "PageList lazily restores compressed history made active by resize" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growColdPagesForTest(1);
    const first = s.pages.first.?;
    first.page().getRowAndCell(0, 0).cell.* = .init('X');
    const memory_ptr = first.page().memory.ptr;
    const memory_len = first.page().memory.len;
    const page_size = s.page_size;
    _ = s.compress(.full);
    try testing.expect(first.isCompressed());
    const all_rows: size.CellCountInt = @intCast(s.total_rows);
    try s.resize(.{ .rows = all_rows });
    const active = s.getTopLeft(.active);
    try testing.expectEqual(first, active.node);
    try testing.expectEqual(@as(size.CellCountInt, 0), active.y);
    try testing.expect(first.isCompressed());
    try testing.expectEqual(page_size, s.page_size);
    _ = s.compress(.full);
    try testing.expect(first.isCompressed());
    const cell = s.getCell(.{ .active = .{} }).?;
    try testing.expectEqual(@as(u21, 'X'), cell.cell.content.codepoint.data);
    try testing.expect(!first.isCompressed());
    try testing.expectEqual(memory_ptr, first.page().memory.ptr);
    try testing.expectEqual(memory_len, first.page().memory.len);
    try testing.expectEqual(page_size, s.page_size);
}
test "PageList full and incremental compression skip a spanning viewport" {
    const testing = std.testing;
    var full = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer full.deinit();
    try full.growColdPagesForTest(3);
    var incremental = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer incremental.deinit();
    try incremental.growColdPagesForTest(3);
    const first = full.pages.first.?;
    const overlap_rows: usize = full.rows / 2;
    const viewport_row: usize = first.rows() - overlap_rows;
    full.scroll(.{ .row = viewport_row });
    incremental.scroll(.{ .row = viewport_row });
    try testing.expect(
        full.getTopLeft(.viewport).node !=
            full.getBottomRight(.viewport).?.node,
    );
    const second = first.next.?;
    try testing.expectEqual(first, full.getTopLeft(.viewport).node);
    try testing.expectEqual(second, full.getBottomRight(.viewport).?.node);
    _ = full.compress(.full);
    _ = incremental.compress(.drain);
    try testing.expectEqual(full.memoryStats(), incremental.memoryStats());
    try testing.expect(!first.isCompressed());
    try testing.expect(!second.isCompressed());
    const full_active = full.getTopLeft(.active).node;
    const incremental_active = incremental.getTopLeft(.active).node;
    var full_node = full.pages.first.?;
    var incremental_node = incremental.pages.first.?;
    while (full_node != full_active) {
        try testing.expectEqual(
            full_node.isCompressed(),
            incremental_node.isCompressed(),
        );
        full_node = full_node.next.?;
        incremental_node = incremental_node.next.?;
    }
    try testing.expectEqual(incremental_active, incremental_node);
    var eligible: CompressionIterator = .init(&full);
    var compressed_pages: usize = 0;
    while (eligible.next()) |node| {
        compressed_pages += 1;
        try testing.expect(node.isCompressed());
    }
    try testing.expect(compressed_pages > 0);
}
test "PageList cold compression continues after an incompressible page" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growColdPagesForTest(2);
    const first = s.pages.first.?;
    const second = first.next.?;
    var prng = std.Random.DefaultPrng.init(0x434F_4C44_5041_4745);
    prng.random().bytes(first.page().memory);
    const page_size = s.page_size;
    _ = s.compress(.full);
    const memory = s.memoryStats();
    try testing.expectEqual(@as(usize, 1), memory.compressed_pages);
    try testing.expect(!first.isCompressed());
    try testing.expect(second.isCompressed());
    try testing.expectEqual(
        second.metadata().memory.len,
        memory.decommitted_raw_bytes,
    );
    try testing.expect(memory.encoded_bytes < memory.decommitted_raw_bytes);
    try testing.expectEqual(page_size, s.page_size);
    _ = s.compress(.full);
    try testing.expectEqual(memory, s.memoryStats());
}
test "PageList compression restores through page access" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const node = s.pages.first.?;
    const page = node.page();
    page.dirty = true;
    page.getRowAndCell(3, 2).cell.* = .init('X');
    const expected = try alloc.dupe(u8, page.memory);
    defer alloc.free(expected);
    const memory_ptr = page.memory.ptr;
    const memory_len = page.memory.len;
    const page_size = s.page_size;
    try testing.expect(s.compressPage(node));
    try testing.expect(node.isCompressed());
    try testing.expectEqual(@as(size.CellCountInt, 24), node.rows());
    try testing.expectEqual(@as(size.CellCountInt, 80), node.cols());
    try testing.expectEqual(memory_ptr, node.metadata().memory.ptr);
    try testing.expectEqual(memory_len, node.metadata().memory.len);
    try testing.expectEqual(page_size, s.page_size);
    const page_pin: Pin = .{ .node = node, .x = 3, .y = 2 };
    try testing.expectEqual(
        @as(u21, 'X'),
        page_pin.rowAndCell().cell.content.codepoint.data,
    );
    try testing.expect(!node.isCompressed());
    try testing.expectEqual(memory_ptr, node.page().memory.ptr);
    try testing.expectEqualSlices(u8, expected, node.page().memory);
    try testing.expect(node.page().dirty);
    try testing.expect(s.compressPage(node));
    var page_it = (Pin{ .node = node }).pageIterator(.right_down, null);
    const chunk = page_it.next().?;
    try testing.expectEqual(node.rows(), chunk.rows().len);
    try testing.expect(!node.isCompressed());
    try testing.expectEqualSlices(u8, expected, node.page().memory);
    try testing.expect(s.compressPage(node));
    var cloned = try s.clone(alloc, .{
        .top = .{ .screen = .{} },
    });
    defer cloned.deinit();
    try testing.expect(!node.isCompressed());
    try testing.expectEqual(
        @as(u21, 'X'),
        cloned.pages.first.?.page().getRowAndCell(3, 2).cell.content.codepoint.data,
    );
}
test "PageList compression uses temporary scratch for oversized pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    var node = s.pages.first.?;
    while (node.page().memory.len <= std_size) {
        node = try s.increaseCapacity(node, .grapheme_bytes);
    }
    const expected = try alloc.dupe(u8, node.page().memory);
    defer alloc.free(expected);
    const memory_ptr = node.page().memory.ptr;
    const memory_len = node.page().memory.len;
    const page_size = s.page_size;
    try testing.expect(s.compressPage(node));
    try testing.expect(node.isCompressed());
    try testing.expectEqual(page_size, s.page_size);
    try testing.expectEqual(memory_ptr, node.metadata().memory.ptr);
    try testing.expectEqual(memory_len, node.metadata().memory.len);
    try testing.expectEqualSlices(u8, expected, node.page().memory);
    try testing.expect(!node.isCompressed());
    try testing.expectEqual(memory_ptr, node.page().memory.ptr);
}
test "PageList compression leaves incompressible pages resident" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const node = s.pages.first.?;
    const original = try alloc.dupe(u8, node.page().memory);
    defer alloc.free(original);
    defer @memcpy(node.page().memory, original);
    var prng = std.Random.DefaultPrng.init(0x5041_4745_4C49_5354);
    prng.random().bytes(node.page().memory);
    const page_size = s.page_size;
    try testing.expect(!s.compressPage(node));
    try testing.expect(!node.isCompressed());
    try testing.expectEqual(page_size, s.page_size);
}
test "PageList reset discards malformed compressed data" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const node = s.pages.first.?;
    try testing.expect(s.compressPage(node));
    @memset(node.data.compressed.encoded, 0xFF);
    s.reset();
    try testing.expect(!s.pages.first.?.isCompressed());
    try testing.expectEqual(@as(usize, 1), s.totalPages());
}
test "PageList deinit discards malformed compressed data" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    const node = s.pages.first.?;
    try testing.expect(s.compressPage(node));
    @memset(node.data.compressed.encoded, 0xFF);
    s.deinit();
}
test "PageList prune reuses malformed compressed page memory" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_size = 2 * PagePool.item_size,
    });
    defer s.deinit();
    while (s.pages.first == s.pages.last) _ = try s.grow();
    const first = s.pages.first.?;
    try testing.expect(s.compressPage(first));
    @memset(first.data.compressed.encoded, 0xFF);
    var reused = false;
    const growth_limit = @as(usize, s.pages.last.?.capacity().rows) + 1;
    for (0..growth_limit) |_| {
        if (try s.grow()) |new_node| {
            if (new_node == first) {
                reused = true;
                break;
            }
        }
    }
    try testing.expect(reused);
    try testing.expectEqual(first, s.pages.last.?);
    try testing.expect(!first.isCompressed());
    try testing.expectEqual(@as(size.CellCountInt, 1), first.rows());
    first.page().assertIntegrity();
}
test "PageList" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try testing.expect(s.viewport == .active);
    try testing.expect(s.pages.first != null);
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
    try testing.expectEqual(s.rows, s.total_rows);
    try testing.expect(s.viewport_pin.node == s.pages.first.?);
    try testing.expectEqual(Pin{
        .node = s.pages.first.?,
        .y = 0,
        .x = 0,
    }, s.getTopLeft(.active));
    try testing.expectEqual(Scrollbar{
        .total = s.rows,
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList init error" {
    for (std.meta.tags(init_tw.FailPoint)) |tag| {
        const tw = init_tw;
        defer tw.end(.reset) catch unreachable;
        tw.errorAlways(tag, error.OutOfMemory);
        try std.testing.expectError(
            error.OutOfMemory,
            init(std.testing.allocator, .{
                .cols = 80,
                .rows = 24,
            }),
        );
    }
    for (std.meta.tags(initPages_tw.FailPoint)) |tag| {
        const tw = initPages_tw;
        defer tw.end(.reset) catch unreachable;
        tw.errorAlways(tag, error.OutOfMemory);
        const cols: size.CellCountInt = if (tag == .page_buf_std) 80 else std_capacity.maxCols().? + 1;
        try std.testing.expectError(
            error.OutOfMemory,
            init(std.testing.allocator, .{
                .cols = cols,
                .rows = 24,
            }),
        );
    }
    for ([_]initPages_tw.FailPoint{
        .page_buf_non_std,
    }) |tag| {
        const tw = initPages_tw;
        defer tw.end(.reset) catch unreachable;
        tw.errorAfter(tag, error.OutOfMemory, 1);
        try std.testing.expectError(
            error.OutOfMemory,
            init(std.testing.allocator, .{
                .cols = std_capacity.maxCols().? + 1,
                .rows = std_capacity.rows + 1,
            }),
        );
    }
}
test "PageList init rows across two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const rows = 100;
    const cap = cap: {
        var cap = try std_capacity.adjust(.{ .cols = 50 });
        while (cap.rows >= rows) cap = try std_capacity.adjust(.{
            .cols = cap.cols + 50,
        });
        break :cap cap;
    };
    var s = try init(alloc, .{ .cols = cap.cols, .rows = rows });
    defer s.deinit();
    try testing.expect(s.viewport == .active);
    try testing.expect(s.pages.first != null);
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
    try testing.expectEqual(s.rows, s.total_rows);
    try testing.expectEqual(Scrollbar{
        .total = s.rows,
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList init more than max cols" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{
        .cols = std_capacity.maxCols().? + 1,
        .rows = 80,
    });
    defer s.deinit();
    try testing.expect(s.viewport == .active);
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
    try testing.expect(s.pages.first != null);
    try testing.expect(s.pages.first.?.page().memory.len > std_size);
    try testing.expectEqual(s.rows, s.total_rows);
    try testing.expectEqual(Scrollbar{
        .total = s.rows,
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList pointFromPin active no history" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    {
        try testing.expectEqual(point.Point{
            .active = .{
                .y = 0,
                .x = 0,
            },
        }, s.pointFromPin(.active, .{
            .node = s.pages.first.?,
            .y = 0,
            .x = 0,
        }).?);
    }
    {
        try testing.expectEqual(point.Point{
            .active = .{
                .y = 2,
                .x = 4,
            },
        }, s.pointFromPin(.active, .{
            .node = s.pages.first.?,
            .y = 2,
            .x = 4,
        }).?);
    }
}
test "PageList pointFromPin active with history" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growRows(30);
    {
        try testing.expectEqual(point.Point{
            .active = .{
                .y = 0,
                .x = 2,
            },
        }, s.pointFromPin(.active, .{
            .node = s.pages.first.?,
            .y = 30,
            .x = 2,
        }).?);
    }
    {
        try testing.expect(s.pointFromPin(.active, .{
            .node = s.pages.first.?,
            .y = 21,
            .x = 2,
        }) == null);
    }
}
test "PageList pointFromPin active from prior page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const page = s.pages.last.?.page();
    var cur_page = s.pages.last.?;
    cur_page.page().pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.page().pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.page().pauseIntegrityChecks(true);
        }
    }
    cur_page.page().pauseIntegrityChecks(false);
    {
        try testing.expectEqual(point.Point{
            .active = .{
                .y = 0,
                .x = 2,
            },
        }, s.pointFromPin(.active, .{
            .node = s.pages.last.?,
            .y = 0,
            .x = 2,
        }).?);
    }
    {
        try testing.expect(s.pointFromPin(.active, .{
            .node = s.pages.first.?,
            .y = 0,
            .x = 0,
        }) == null);
    }
}
test "PageList pointFromPin traverse pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const page = s.pages.last.?.page();
    var cur_page = s.pages.last.?;
    cur_page.page().pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 2) |_| {
        if (try s.grow()) |new_page| {
            cur_page.page().pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.page().pauseIntegrityChecks(true);
        }
    }
    cur_page.page().pauseIntegrityChecks(false);
    {
        const pages = s.totalPages();
        const page_cap = page.capacity.rows;
        const expected_y = page_cap * (pages - 2) + 5;
        try testing.expectEqual(point.Point{
            .screen = .{
                .y = @intCast(expected_y),
                .x = 2,
            },
        }, s.pointFromPin(.screen, .{
            .node = s.pages.last.?.prev.?,
            .y = 5,
            .x = 2,
        }).?);
    }
    {
        try testing.expect(s.pointFromPin(.active, .{
            .node = s.pages.first.?,
            .y = 0,
            .x = 0,
        }) == null);
    }
}
test "PageList pointFromPin rejects overflowing screen coordinate" {
    const testing = std.testing;
    const page_count = 65_539;
    const rows_per_page = std.math.maxInt(size.CellCountInt);
    const nodes = try testing.allocator.alloc(Node, page_count);
    defer testing.allocator.free(nodes);
    for (nodes, 0..) |*node, i| {
        node.* = .{
            .prev = if (i > 0) &nodes[i - 1] else null,
            .next = if (i + 1 < nodes.len) &nodes[i + 1] else null,
            .data = .{ .resident = undefined },
            .serial = @intCast(i),
            .owned = .heap,
        };
        node.data.resident.size = .{
            .cols = 1,
            .rows = rows_per_page,
        };
    }
    var s: PageList = undefined;
    s.pages = .{
        .first = &nodes[0],
        .last = &nodes[nodes.len - 1],
    };
    try testing.expect(s.pointFromPin(.screen, .{
        .node = &nodes[nodes.len - 1],
        .y = 0,
        .x = 0,
    }) == null);
}
test "PageList active after grow" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
    try s.growRows(10);
    try testing.expectEqual(@as(usize, s.rows + 10), s.totalRows());
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }
    {
        const pt = s.getCell(.{ .screen = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }
    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = 10,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList grow allows exceeding max size for active area" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const cap = try std_capacity.adjust(.{ .cols = 5 });
    var s = try init(alloc, .{ .cols = 5, .rows = cap.rows, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
    _ = try s.grow();
    const start_pages = s.totalPages();
    try testing.expect(start_pages >= 2);
    {
        var it = s.pages.first;
        while (it) |page| : (it = page.next) {
            page.page().size.rows = 1;
            page.page().capacity.rows = 1;
        }
        s.total_rows = s.totalRows();
    }
    _ = try s.grow();
    try testing.expectEqual(start_pages + 1, s.totalPages());
}
test "PageList grow prune required with a single page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    {
        while (true) {
            const layout = Page.layout(s.pages.first.?.capacity());
            if (layout.total_size > std_size) break;
            _ = try s.increaseCapacity(s.pages.first.?, .grapheme_bytes);
        }
        try testing.expect(s.pages.first != null);
        try testing.expect(s.pages.first == s.pages.last);
    }
    const rem = rem: {
        const page = s.pages.first.?;
        break :rem page.capacity().rows - page.rows();
    };
    for (0..rem) |_| try testing.expect(try s.grow() == null);
    const new = try s.grow();
    try testing.expect(new != null);
    try testing.expect(new != s.pages.first);
    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList scrollbar with max_size 0 after grow" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24, .max_size = 0 });
    defer s.deinit();
    try s.growRows(10);
    const sb = s.scrollbar();
    try testing.expectEqual(s.rows, sb.total);
    try testing.expectEqual(@as(usize, 0), sb.offset);
}
test "PageList scroll with max_size 0 no history" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24, .max_size = 0 });
    defer s.deinit();
    try s.growRows(10);
    const pt_before = s.getCell(.{ .viewport = .{} }).?.screenPoint();
    s.scroll(.{ .delta_row = -5 });
    try testing.expect(s.viewport == .active);
    s.scroll(.{ .top = {} });
    const pt_after = s.getCell(.{ .viewport = .{} }).?.screenPoint();
    try testing.expectEqual(pt_before, pt_after);
}
test "PageList scroll top" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growRows(10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }
    s.scroll(.{ .top = {} });
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());
    try s.growRows(10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());
    s.scroll(.{ .active = {} });
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 20,
        } }, pt);
    }
    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList scroll delta row back" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growRows(10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }
    s.scroll(.{ .delta_row = -1 });
    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = s.total_rows - s.rows - 1,
        .len = s.rows,
    }, s.scrollbar());
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 9,
        } }, pt);
    }
    try s.growRows(10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 9,
        } }, pt);
    }
    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = s.total_rows - s.rows - 11,
        .len = s.rows,
    }, s.scrollbar());
    s.scroll(.{ .delta_row = -1 });
    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = s.total_rows - s.rows - 12,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList scroll delta row back overflow" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growRows(10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }
    s.scroll(.{ .delta_row = -100 });
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());
    try s.growRows(10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList scroll minimum row delta" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 10, .rows = 3 });
    defer s.deinit();
    try s.growRows(1);
    s.scroll(.{ .delta_row = std.math.minInt(isize) });
    try testing.expectEqual(Viewport.top, s.viewport);
}
test "PageList scroll delta row forward" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growRows(10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }
    s.scroll(.{ .top = {} });
    s.scroll(.{ .delta_row = 2 });
    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = 2,
        .len = s.rows,
    }, s.scrollbar());
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, pt);
    }
    try s.growRows(10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, pt);
    }
    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = 2,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList scroll delta row forward into active" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    s.scroll(.{ .delta_row = 2 });
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList scroll delta row back without space preserves active" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    s.scroll(.{ .delta_row = -1 });
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
    try testing.expect(s.viewport == .active);
    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList scroll to pin" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growRows(10);
    s.scroll(.{ .pin = s.pin(.{ .screen = .{
        .y = 4,
        .x = 2,
    } }).? });
    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = 4,
        .len = s.rows,
    }, s.scrollbar());
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 4,
        } }, pt);
    }
    s.scroll(.{ .pin = s.pin(.{ .screen = .{
        .y = 5,
        .x = 2,
    } }).? });
    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = 5,
        .len = s.rows,
    }, s.scrollbar());
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 5,
        } }, pt);
    }
}
test "PageList scroll to pin in active" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growRows(10);
    s.scroll(.{ .pin = s.pin(.{ .screen = .{
        .y = 30,
        .x = 2,
    } }).? });
    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }
}
test "PageList scroll to pin at top" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growRows(10);
    s.scroll(.{ .pin = s.pin(.{ .screen = .{
        .y = 0,
        .x = 2,
    } }).? });
    try testing.expect(s.viewport == .top);
    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
}
test "PageList scroll to row 0" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growRows(10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }
    s.scroll(.{ .row = 0 });
    try testing.expect(s.viewport == .top);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());
    try s.growRows(10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList scroll to row in scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growRows(20);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 20,
        } }, pt);
    }
    s.scroll(.{ .row = 5 });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 5,
        .len = s.rows,
    }, s.scrollbar());
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 5,
        } }, pt);
    }
    try s.growRows(10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 5,
        } }, pt);
    }
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 5,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList scroll to row in middle" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growRows(50);
    const total = s.total_rows;
    const midpoint = total / 2;
    s.scroll(.{ .row = midpoint });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = midpoint,
        .len = s.rows,
    }, s.scrollbar());
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = @as(size.CellCountInt, @intCast(midpoint)),
        } }, pt);
    }
    try s.growRows(10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = @as(size.CellCountInt, @intCast(midpoint)),
        } }, pt);
    }
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = midpoint,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList scroll to row at active boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growRows(20);
    const active_start = s.total_rows - s.rows;
    s.scroll(.{ .row = active_start });
    try testing.expect(s.viewport == .active);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = @as(size.CellCountInt, @intCast(active_start)),
        } }, pt);
    }
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
    try s.growRows(10);
    try testing.expect(s.viewport == .active);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList scroll to row beyond active" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growRows(10);
    s.scroll(.{ .row = 1000 });
    try testing.expect(s.viewport == .active);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList scroll to row without scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    s.scroll(.{ .row = 5 });
    try testing.expect(s.viewport == .active);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList scroll to row then delta" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growRows(30);
    s.scroll(.{ .row = 10 });
    try testing.expect(s.viewport == .pin);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 10,
        .len = s.rows,
    }, s.scrollbar());
    s.scroll(.{ .delta_row = 5 });
    try testing.expect(s.viewport == .pin);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 15,
        } }, pt);
    }
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 15,
        .len = s.rows,
    }, s.scrollbar());
    s.scroll(.{ .delta_row = -3 });
    try testing.expect(s.viewport == .pin);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 12,
        } }, pt);
    }
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 12,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList scroll to row with cache fast path down" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growRows(50);
    s.scroll(.{ .row = 10 });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 10,
        .len = s.rows,
    }, s.scrollbar());
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }
    try testing.expect(s.viewport_pin_row_offset != null);
    try testing.expectEqual(@as(usize, 10), s.viewport_pin_row_offset.?);
    s.scroll(.{ .row = 20 });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 20,
        .len = s.rows,
    }, s.scrollbar());
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 20,
        } }, pt);
    }
    try s.growRows(10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 20,
        } }, pt);
    }
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 20,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList scroll to row with cache fast path up" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growRows(50);
    s.scroll(.{ .row = 30 });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 30,
        .len = s.rows,
    }, s.scrollbar());
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 30,
        } }, pt);
    }
    try testing.expect(s.viewport_pin_row_offset != null);
    try testing.expectEqual(@as(usize, 30), s.viewport_pin_row_offset.?);
    s.scroll(.{ .row = 15 });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 15,
        .len = s.rows,
    }, s.scrollbar());
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 15,
        } }, pt);
    }
    try s.growRows(10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 15,
        } }, pt);
    }
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 15,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList scroll clear" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    {
        const cell = s.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        cell.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };
    }
    {
        const cell = s.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?;
        cell.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };
    }
    try s.scrollClear();
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, pt);
    }
}
test "PageList: jump zero prompts" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 5, .rows = 3 });
    defer s.deinit();
    try s.growRows(3);
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 1);
        rac.row.semantic_prompt = .prompt;
    }
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
    }
    s.scroll(.{ .delta_prompt = 0 });
    try testing.expect(s.viewport == .active);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList: jump minimum prompt delta" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 10, .rows = 3 });
    defer s.deinit();
    s.scroll(.{ .delta_prompt = std.math.minInt(isize) });
    try testing.expectEqual(Viewport.active, s.viewport);
}
test "Screen: jump back one prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 5, .rows = 3 });
    defer s.deinit();
    try s.growRows(3);
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 1);
        rac.row.semantic_prompt = .prompt;
    }
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
    }
    {
        s.scroll(.{ .delta_prompt = -1 });
        try testing.expect(s.viewport == .pin);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pointFromPin(.screen, s.pin(.{ .viewport = .{} }).?).?);
        try testing.expectEqual(Scrollbar{
            .total = s.total_rows,
            .offset = 1,
            .len = s.rows,
        }, s.scrollbar());
    }
    {
        s.scroll(.{ .delta_prompt = -1 });
        try testing.expect(s.viewport == .pin);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pointFromPin(.screen, s.pin(.{ .viewport = .{} }).?).?);
        try testing.expectEqual(Scrollbar{
            .total = s.total_rows,
            .offset = 1,
            .len = s.rows,
        }, s.scrollbar());
    }
    {
        s.scroll(.{ .delta_prompt = 1 });
        try testing.expect(s.viewport == .active);
        try testing.expectEqual(Scrollbar{
            .total = s.total_rows,
            .offset = s.total_rows - s.rows,
            .len = s.rows,
        }, s.scrollbar());
    }
    {
        s.scroll(.{ .delta_prompt = 1 });
        try testing.expect(s.viewport == .active);
        try testing.expectEqual(Scrollbar{
            .total = s.total_rows,
            .offset = s.total_rows - s.rows,
            .len = s.rows,
        }, s.scrollbar());
    }
}
test "Screen: jump forward prompt skips multiline continuation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 5, .rows = 3 });
    defer s.deinit();
    try s.growRows(7);
    {
        const p = s.pin(.{ .screen = .{ .y = 1 } }).?;
        p.rowAndCell().row.semantic_prompt = .prompt;
    }
    {
        const p = s.pin(.{ .screen = .{ .y = 2 } }).?;
        p.rowAndCell().row.semantic_prompt = .prompt_continuation;
    }
    {
        const p = s.pin(.{ .screen = .{ .y = 3 } }).?;
        p.rowAndCell().row.semantic_prompt = .prompt_continuation;
    }
    {
        const p = s.pin(.{ .screen = .{ .y = 6 } }).?;
        p.rowAndCell().row.semantic_prompt = .prompt;
    }
    s.scroll(.{ .row = 1 });
    s.scroll(.{ .delta_prompt = 1 });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 6,
    } }, s.pointFromPin(.screen, s.pin(.{ .viewport = .{} }).?).?);
    s.scroll(.{ .row = 2 });
    s.scroll(.{ .delta_prompt = 1 });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 6,
    } }, s.pointFromPin(.screen, s.pin(.{ .viewport = .{} }).?).?);
}
test "PageList grow fit in capacity" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const last = s.pages.last.?.page();
    try testing.expect(last.size.rows < last.capacity.rows);
    try testing.expect(try s.grow() == null);
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, pt);
    }
}
test "PageList grow allocate" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const last_node = s.pages.last.?;
    const last = s.pages.last.?.page();
    for (0..last.capacity.rows - last.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }
    const new = (try s.grow()).?;
    try testing.expect(s.pages.last.? == new);
    try testing.expect(last_node.next.? == new);
    {
        const cell = s.getCell(.{ .active = .{ .y = s.rows - 1 } }).?;
        try testing.expect(cell.node == new);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = last.capacity.rows,
        } }, cell.screenPoint());
    }
}
test "PageList Cell screenPoint supports long scrollback" {
    const testing = std.testing;
    const page_count = 307;
    const rows_per_page = std_capacity.rows;
    const nodes = try testing.allocator.alloc(Node, page_count);
    defer testing.allocator.free(nodes);
    for (nodes, 0..) |*node, i| {
        node.* = .{
            .prev = if (i > 0) &nodes[i - 1] else null,
            .next = if (i + 1 < nodes.len) &nodes[i + 1] else null,
            .data = .{ .resident = undefined },
            .serial = @intCast(i),
            .owned = .heap,
        };
        node.data.resident.size = .{
            .cols = 1,
            .rows = rows_per_page,
        };
    }
    const expected_y: u32 = (page_count - 1) * @as(u32, rows_per_page);
    try testing.expect(expected_y > std.math.maxInt(size.CellCountInt));
    const cell: Cell = .{
        .node = &nodes[nodes.len - 1],
        .row = undefined,
        .cell = undefined,
        .row_idx = 0,
        .col_idx = 0,
    };
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = expected_y,
    } }, cell.screenPoint());
}
test "PageList set max bytes prunes immediately and can be raised" {
    const testing = std.testing;
    const cols: size.CellCountInt = 80;
    const page_rows: usize = initialCapacity(cols).rows;
    var s = try init(testing.allocator, .{
        .cols = cols,
        .rows = 1,
        .max_size = null,
    });
    defer s.deinit();
    try s.growRows(4 * page_rows);
    try testing.expectEqual(@as(usize, 5), s.totalPages());
    const removed = s.pages.first.?;
    const retained = s.pages.last.?.prev.?;
    const removed_pin = try s.trackPin(.{ .node = removed });
    defer s.untrackPin(removed_pin);
    const retained_pin = try s.trackPin(.{ .node = retained });
    defer s.untrackPin(retained_pin);
    s.scroll(.{ .pin = retained_pin.* });
    try testing.expectEqual(3 * page_rows, s.scrollbar().offset);
    s.setMaxBytes(PagePool.item_size);
    try testing.expectEqual(PagePool.item_size, s.limits.bytes.explicit);
    try testing.expectEqual(2 * PagePool.item_size, s.limits.max(.bytes));
    try testing.expectEqual(s.limits.max(.bytes), s.page_size);
    try testing.expectEqual(@as(usize, 2), s.totalPages());
    try testing.expectEqual(page_rows, s.total_rows - s.rows);
    try testing.expectEqual(retained, s.pages.first.?);
    try testing.expectEqual(retained, removed_pin.node);
    try testing.expect(removed_pin.garbage);
    try testing.expectEqual(retained, retained_pin.node);
    try testing.expect(!retained_pin.garbage);
    try testing.expectEqual(@as(usize, 0), s.scrollbar().offset);
    const limited_size = s.page_size;
    const limited_rows = s.total_rows;
    s.setMaxBytes(8 * PagePool.item_size);
    try testing.expectEqual(limited_size, s.page_size);
    try testing.expectEqual(limited_rows, s.total_rows);
    try s.growRows(2 * page_rows);
    try testing.expect(s.page_size > limited_size);
    const raised_size = s.page_size;
    const raised_rows = s.total_rows;
    s.setMaxBytes(null);
    try testing.expectEqual(
        std.math.maxInt(usize),
        s.limits.bytes.explicit,
    );
    try testing.expectEqual(raised_size, s.page_size);
    try testing.expectEqual(raised_rows, s.total_rows);
    try s.growRows(5 * page_rows);
    try testing.expect(s.page_size > 8 * PagePool.item_size);
}
test "PageList set max bytes zero preserves active boundary" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{
        .cols = 80,
        .rows = 1,
        .max_size = null,
    });
    defer s.deinit();
    while (s.page_size <= s.limits.bytes.min) {
        _ = try s.increaseCapacity(s.pages.first.?, .grapheme_bytes);
    }
    _ = try s.grow();
    try testing.expectEqual(@as(usize, 1), s.totalPages());
    try testing.expectEqual(s.pages.first.?, s.getTopLeft(.active).node);
    try testing.expect(s.getTopLeft(.active).y > 0);
    s.scroll(.top);
    try testing.expect(s.viewport == .top);
    s.setMaxBytes(0);
    try testing.expectEqual(@as(usize, 0), s.limits.bytes.explicit);
    try testing.expect(s.page_size > s.limits.max(.bytes));
    try testing.expectEqual(@as(usize, 1), s.totalPages());
    try testing.expect(s.viewport == .active);
    try testing.expectEqual(Scrollbar{
        .total = s.rows,
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());
    s.scroll(.top);
    try testing.expect(s.viewport == .active);
}
test "PageList set max lines prunes immediately and can be raised" {
    const testing = std.testing;
    const cols: size.CellCountInt = 80;
    const page_rows: usize = initialCapacity(cols).rows;
    const lowered_lines = page_rows + page_rows / 2;
    var s = try init(testing.allocator, .{
        .cols = cols,
        .rows = 1,
        .max_size = null,
        .max_lines = null,
    });
    defer s.deinit();
    try s.growRows(4 * page_rows);
    try testing.expectEqual(@as(usize, 5), s.totalPages());
    const removed = s.pages.first.?;
    const retained = s.pages.last.?.prev.?;
    const removed_pin = try s.trackPin(.{ .node = removed });
    defer s.untrackPin(removed_pin);
    const retained_pin = try s.trackPin(.{ .node = retained });
    defer s.untrackPin(retained_pin);
    s.scroll(.{ .pin = retained_pin.* });
    try testing.expectEqual(3 * page_rows, s.scrollbar().offset);
    s.setMaxLines(lowered_lines);
    try testing.expectEqual(lowered_lines, s.limits.lines.explicit);
    try testing.expectEqual(lowered_lines, s.limits.max(.lines));
    try testing.expectEqual(page_rows, s.total_rows - s.rows);
    try testing.expectEqual(@as(usize, 2), s.totalPages());
    try testing.expectEqual(retained, s.pages.first.?);
    try testing.expectEqual(retained, removed_pin.node);
    try testing.expect(removed_pin.garbage);
    try testing.expectEqual(retained, retained_pin.node);
    try testing.expect(!retained_pin.garbage);
    try testing.expectEqual(@as(usize, 0), s.scrollbar().offset);
    const limited_size = s.page_size;
    const limited_rows = s.total_rows;
    s.setMaxLines(4 * page_rows);
    try testing.expectEqual(limited_size, s.page_size);
    try testing.expectEqual(limited_rows, s.total_rows);
    try s.growRows(2 * page_rows);
    try testing.expect(s.total_rows - s.rows > lowered_lines);
    const raised_size = s.page_size;
    const raised_rows = s.total_rows;
    s.setMaxLines(null);
    try testing.expectEqual(
        std.math.maxInt(usize),
        s.limits.lines.explicit,
    );
    try testing.expectEqual(raised_size, s.page_size);
    try testing.expectEqual(raised_rows, s.total_rows);
    try s.growRows(3 * page_rows);
    try testing.expect(s.total_rows - s.rows > 4 * page_rows);
}
test "PageList set max limits remain independent" {
    const testing = std.testing;
    const cols: size.CellCountInt = 80;
    const page_rows: usize = initialCapacity(cols).rows;
    const byte_limit = 3 * PagePool.item_size;
    const line_limit = page_rows / 2;
    var s = try init(testing.allocator, .{
        .cols = cols,
        .rows = 1,
        .max_size = null,
        .max_lines = null,
    });
    defer s.deinit();
    try s.growRows(4 * page_rows);
    s.setMaxBytes(byte_limit);
    try testing.expectEqual(byte_limit, s.limits.bytes.explicit);
    try testing.expectEqual(
        std.math.maxInt(usize),
        s.limits.lines.explicit,
    );
    try testing.expectEqual(@as(usize, 3), s.totalPages());
    try testing.expectEqual(2 * page_rows, s.total_rows - s.rows);
    s.setMaxLines(line_limit);
    try testing.expectEqual(byte_limit, s.limits.bytes.explicit);
    try testing.expectEqual(line_limit, s.limits.lines.explicit);
    try testing.expectEqual(page_rows, s.limits.max(.lines));
    try testing.expectEqual(@as(usize, 2), s.totalPages());
    try testing.expectEqual(page_rows, s.total_rows - s.rows);
    s.setMaxLines(null);
    try s.growRows(3 * page_rows);
    try testing.expectEqual(byte_limit, s.page_size);
    try testing.expectEqual(@as(usize, 3), s.totalPages());
    try testing.expect(s.total_rows - s.rows > page_rows);
}
test "PageList max lines uses one-page minimum" {
    const testing = std.testing;
    const cols: size.CellCountInt = 80;
    const page_rows: usize = initialCapacity(cols).rows;
    var s = try init(testing.allocator, .{
        .cols = cols,
        .rows = 1,
        .max_lines = page_rows / 2,
    });
    defer s.deinit();
    try testing.expectEqual(page_rows, s.limits.max(.lines));
    try s.growRows(page_rows);
    try testing.expectEqual(page_rows, s.total_rows - s.rows);
    try testing.expectEqual(@as(usize, 2), s.totalPages());
    const first = s.pages.first.?;
    const old_page_size = s.page_size;
    _ = try s.grow();
    try testing.expectEqual(@as(usize, 1), s.total_rows - s.rows);
    try testing.expectEqual(@as(usize, 1), s.totalPages());
    try testing.expect(s.pages.first.? != first);
    try testing.expectEqual(
        old_page_size - PagePool.item_size,
        s.page_size,
    );
}
test "PageList max lines does not round larger limits" {
    const testing = std.testing;
    const cols: size.CellCountInt = 80;
    const page_rows: usize = initialCapacity(cols).rows;
    const max_lines = page_rows + page_rows / 2;
    var s = try init(testing.allocator, .{
        .cols = cols,
        .rows = 1,
        .max_lines = max_lines,
    });
    defer s.deinit();
    try testing.expectEqual(max_lines, s.limits.max(.lines));
    try s.growRows(max_lines);
    try testing.expectEqual(max_lines, s.total_rows - s.rows);
    const first = s.pages.first.?;
    const retained = first.next.?;
    const removed_pin = try s.trackPin(.{ .node = first });
    defer s.untrackPin(removed_pin);
    const retained_pin = try s.trackPin(.{ .node = retained });
    defer s.untrackPin(retained_pin);
    s.scroll(.{ .pin = retained_pin.* });
    try testing.expectEqual(page_rows, s.scrollbar().offset);
    const old_page_size = s.page_size;
    _ = try s.grow();
    try testing.expectEqual(
        max_lines + 1 - page_rows,
        s.total_rows - s.rows,
    );
    try testing.expectEqual(retained, s.pages.first.?);
    try testing.expectEqual(retained, removed_pin.node);
    try testing.expect(removed_pin.garbage);
    try testing.expectEqual(retained, retained_pin.node);
    try testing.expect(!retained_pin.garbage);
    try testing.expectEqual(@as(usize, 0), s.scrollbar().offset);
    try testing.expectEqual(
        old_page_size - PagePool.item_size,
        s.page_size,
    );
}
test "PageList max lines and max size enforce the smaller limit" {
    const testing = std.testing;
    const cols: size.CellCountInt = 80;
    const page_rows: usize = initialCapacity(cols).rows;
    {
        var s = try init(testing.allocator, .{
            .cols = cols,
            .rows = 1,
            .max_size = 8 * PagePool.item_size,
            .max_lines = page_rows,
        });
        defer s.deinit();
        try s.growRows(4 * page_rows);
        try testing.expect(
            s.total_rows - s.rows <= s.limits.max(.lines),
        );
        try testing.expect(s.totalPages() <= 2);
        try testing.expect(s.page_size < s.limits.max(.bytes));
    }
    {
        var s = try init(testing.allocator, .{
            .cols = cols,
            .rows = 1,
            .max_size = PagePool.item_size,
            .max_lines = 4 * page_rows,
        });
        defer s.deinit();
        try s.growRows(2 * page_rows);
        try testing.expect(
            s.total_rows - s.rows < s.limits.max(.lines),
        );
        try testing.expectEqual(s.limits.max(.bytes), s.page_size);
    }
}
test "PageList max lines applies to resize and clone" {
    const testing = std.testing;
    const cols: size.CellCountInt = 80;
    const page_rows: usize = initialCapacity(cols).rows;
    var s = try init(testing.allocator, .{
        .cols = cols,
        .rows = 2,
        .max_lines = page_rows,
    });
    defer s.deinit();
    try s.growRows(page_rows);
    try testing.expectEqual(page_rows, s.total_rows - s.rows);
    const cell = s.getCell(.{ .active = .{ .y = 1 } }).?;
    cell.cell.* = .{
        .content_tag = .codepoint,
        .content = .{ .codepoint = .{ .data = 'A' } },
    };
    try s.resize(.{ .rows = 1, .reflow = false });
    try testing.expectEqual(@as(usize, 1), s.total_rows - s.rows);
    const new_cols: size.CellCountInt = cols + 1;
    try s.resize(.{ .cols = new_cols, .reflow = true });
    try testing.expectEqual(
        Limits.minMaxLines(new_cols),
        s.limits.lines.min,
    );
    {
        var reflowed = try init(testing.allocator, .{
            .cols = cols,
            .rows = 2,
            .max_lines = page_rows,
        });
        defer reflowed.deinit();
        try reflowed.growRows(page_rows);
        const active_cell = reflowed.getCell(.{ .active = .{ .y = 1 } }).?;
        active_cell.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };
        try reflowed.resize(.{
            .cols = new_cols,
            .rows = 1,
            .reflow = true,
        });
        try testing.expectEqual(
            Limits.minMaxLines(new_cols),
            reflowed.limits.lines.min,
        );
        try testing.expect(
            reflowed.total_rows - reflowed.rows <=
                reflowed.limits.max(.lines) or
                reflowed.pages.first.? ==
                    reflowed.getTopLeft(.active).node,
        );
    }
    var cloned = try s.clone(testing.allocator, .{
        .top = .{ .screen = .{} },
    });
    defer cloned.deinit();
    try testing.expectEqual(s.limits, cloned.limits);
    try cloned.growRows(2 * cloned.limits.max(.lines));
    try testing.expect(
        cloned.total_rows - cloned.rows <= cloned.limits.max(.lines) or
            cloned.pages.first.? == cloned.getTopLeft(.active).node,
    );
}
test "PageList grow prune scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24, .max_size = std_size });
    defer s.deinit();
    const page1_node = s.pages.last.?;
    const page1 = page1_node.page();
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }
    const page2_node = (try s.grow()).?;
    const page2 = page2_node.page();
    for (0..page2.capacity.rows - page2.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }
    const old_page_size = s.page_size;
    const p = try s.trackPin(s.pin(.{ .screen = .{} }).?);
    defer s.untrackPin(p);
    try testing.expect(p.node == s.pages.first.?);
    const pin_y = page1.capacity.rows / 2;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);
    const scrollbar_before = s.scrollbar();
    try testing.expectEqual(pin_y, scrollbar_before.offset);
    const new = (try s.grow()).?;
    try testing.expect(s.pages.last.? == new);
    try testing.expectEqual(s.page_size, old_page_size);
    try testing.expectEqual(page2_node, s.pages.first.?);
    try testing.expectEqual(page1_node, s.pages.last.?);
    try testing.expect(p.node == s.pages.first.?);
    try testing.expect(p.x == 0);
    try testing.expect(p.y == 0);
    try testing.expect(p.garbage);
    {
        const scrollbar_after = s.scrollbar();
        const rows_pruned = page1.capacity.rows;
        const expected_offset = if (pin_y >= rows_pruned)
            pin_y - rows_pruned
        else
            0;
        try testing.expectEqual(expected_offset, scrollbar_after.offset);
    }
}
test "PageList grow prune scrollback with viewport pin not in pruned page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24, .max_size = std_size });
    defer s.deinit();
    const page1_node = s.pages.last.?;
    const page1 = page1_node.page();
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }
    const page2_node = (try s.grow()).?;
    const page2 = page2_node.page();
    for (0..page2.capacity.rows - page2.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }
    const old_page_size = s.page_size;
    const pin_y = page1.capacity.rows + 5;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expect(s.viewport_pin.node == page2_node);
    const scrollbar_before = s.scrollbar();
    try testing.expectEqual(pin_y, scrollbar_before.offset);
    const new = (try s.grow()).?;
    try testing.expect(s.pages.last.? == new);
    try testing.expectEqual(s.page_size, old_page_size);
    try testing.expectEqual(page2_node, s.pages.first.?);
    try testing.expect(s.viewport_pin.node == page2_node);
    const scrollbar_after = s.scrollbar();
    const rows_pruned = page1.capacity.rows;
    const expected_offset = pin_y - rows_pruned;
    try testing.expectEqual(expected_offset, scrollbar_after.offset);
}
test "PageList eraseRows invalidates viewport offset cache" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const page = s.pages.last.?.page();
    {
        var cur_page = s.pages.last.?;
        for (0..page.capacity.rows * 3) |_| {
            if (try s.grow()) |new_page| cur_page = new_page;
        }
    }
    const pin_y = page.capacity.rows;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y,
        .len = s.rows,
    }, s.scrollbar());
    const rows_to_erase = page.capacity.rows / 2;
    s.eraseHistory(.{ .history = .{ .y = rows_to_erase - 1 } });
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y - rows_to_erase,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList eraseRow invalidates viewport offset cache" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const page = s.pages.last.?.page();
    {
        var cur_page = s.pages.last.?;
        for (0..page.capacity.rows * 3) |_| {
            if (try s.grow()) |new_page| cur_page = new_page;
        }
    }
    const pin_y = page.capacity.rows;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y,
        .len = s.rows,
    }, s.scrollbar());
    try s.eraseRow(.{ .history = .{ .y = 0 } });
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y - 1,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList eraseRowBounded invalidates viewport offset cache" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const page = s.pages.last.?.page();
    {
        var cur_page = s.pages.last.?;
        for (0..page.capacity.rows * 3) |_| {
            if (try s.grow()) |new_page| cur_page = new_page;
        }
    }
    const pin_y: u16 = 4;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y,
        .len = s.rows,
    }, s.scrollbar());
    try s.eraseRowBounded(.{ .history = .{ .y = 0 } }, 10);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y - 1,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList row erasure renews affected page generations" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    while (s.totalPages() < 2) _ = try s.grow();
    const first = s.pages.first.?;
    const second = first.next.?;
    var first_serial = first.serial;
    var second_serial = second.serial;
    var activity = s.page_compression.activity_serial;
    try s.eraseRow(.{ .history = .{ .y = 0 } });
    try testing.expect(!s.nodeIsValid(first, first_serial));
    try testing.expect(!s.nodeIsValid(second, second_serial));
    try testing.expect(activity != s.page_compression.activity_serial);
    first_serial = first.serial;
    second_serial = second.serial;
    activity = s.page_compression.activity_serial;
    try s.eraseRowBounded(
        .{ .history = .{ .y = 0 } },
        first.rows() + 1,
    );
    try testing.expect(!s.nodeIsValid(first, first_serial));
    try testing.expect(!s.nodeIsValid(second, second_serial));
    try testing.expect(activity != s.page_compression.activity_serial);
}
test "PageList trailing row truncation renews page generation" {
    const testing = std.testing;
    var s = try init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const node = s.pages.last.?;
    const old_serial = node.serial;
    const trimmed = s.trimTrailingBlankRows(1);
    s.total_rows -= trimmed;
    try testing.expectEqual(@as(size.CellCountInt, 1), trimmed);
    try testing.expect(!s.nodeIsValid(node, old_serial));
    _ = try s.grow();
    try s.expectLivePageSerialsValidForTest();
}
test "PageList eraseRowBounded multi-page invalidates viewport offset cache" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const page = s.pages.last.?.page();
    {
        var cur_page = s.pages.last.?;
        for (0..page.capacity.rows * 3) |_| {
            if (try s.grow()) |new_page| cur_page = new_page;
        }
    }
    const pin_y = page.capacity.rows + 1;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y,
        .len = s.rows,
    }, s.scrollbar());
    const limit = page.capacity.rows + 10;
    try s.eraseRowBounded(.{ .history = .{ .y = 0 } }, limit);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y - 1,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList eraseRowBounded full page shift invalidates viewport offset cache" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const page = s.pages.last.?.page();
    {
        var cur_page = s.pages.last.?;
        for (0..page.capacity.rows * 4) |_| {
            if (try s.grow()) |new_page| cur_page = new_page;
        }
    }
    const pin_y = 5;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y,
        .len = s.rows,
    }, s.scrollbar());
    const limit = page.capacity.rows * 2 + 10;
    try s.eraseRowBounded(.{ .history = .{ .y = 0 } }, limit);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y - 1,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList eraseRowBounded exhausts pages invalidates viewport offset cache" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const page = s.pages.last.?.page();
    {
        var cur_page = s.pages.last.?;
        for (0..page.capacity.rows * 3) |_| {
            if (try s.grow()) |new_page| cur_page = new_page;
        }
    }
    const total_rows_before = s.totalRows();
    try testing.expect(total_rows_before > s.rows);
    const pin_y = page.capacity.rows * 2 + 10;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y,
        .len = s.rows,
    }, s.scrollbar());
    const limit = total_rows_before * 2;
    try s.eraseRowBounded(.{ .history = .{ .y = 0 } }, limit);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y - 1,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList increaseCapacity to increase styles" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_size = 0 });
    defer s.deinit();
    const original_styles_cap = s.pages.first.?.capacity().styles;
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = @intCast(x) } },
                };
            }
        }
    }
    _ = try s.increaseCapacity(s.pages.first.?, .styles);
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        try testing.expectEqual(
            original_styles_cap * 2,
            page.capacity.styles,
        );
        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                try testing.expectEqual(
                    @as(u21, @intCast(x)),
                    rac.cell.content.codepoint.data,
                );
            }
        }
    }
}
test "PageList increaseCapacity styles projects capacity from page density" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_size = 0 });
    defer s.deinit();
    const original_cap = s.pages.first.?.capacity().styles;
    const bold: stylepkg.Style = .{ .flags = .{ .bold = true } };
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                const style_id = try page.styles.add(page.memory, bold);
                rac.row.styled = true;
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = @intCast(x + 1) } },
                    .style_id = style_id,
                };
            }
        }
    }
    _ = try s.increaseCapacity(s.pages.first.?, .styles);
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        try testing.expectEqual(
            original_cap * 32,
            page.capacity.styles,
        );
        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                try testing.expectEqual(
                    @as(u21, @intCast(x + 1)),
                    rac.cell.content.codepoint.data,
                );
                try testing.expect(rac.cell.style_id != stylepkg.default_id);
                try testing.expect(bold.eql(
                    page.styles.get(page.memory, rac.cell.style_id).*,
                ));
            }
        }
    }
}
test "PageList increaseCapacity to increase graphemes" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_size = 0 });
    defer s.deinit();
    const original_cap = s.pages.first.?.capacity().grapheme_bytes;
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = @intCast(x) } },
                };
            }
        }
    }
    _ = try s.increaseCapacity(s.pages.first.?, .grapheme_bytes);
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        try testing.expectEqual(original_cap * 2, page.capacity.grapheme_bytes);
        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                try testing.expectEqual(
                    @as(u21, @intCast(x)),
                    rac.cell.content.codepoint.data,
                );
            }
        }
    }
}
test "PageList increaseCapacity graphemes projects capacity from page density" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_size = 0 });
    defer s.deinit();
    const original_cap = s.pages.first.?.capacity().grapheme_bytes;
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = @intCast(x + 1) } },
                };
                try page.appendGrapheme(rac.row, rac.cell, 0x0301);
                try page.appendGrapheme(rac.row, rac.cell, 0x0302);
            }
        }
    }
    _ = try s.increaseCapacity(s.pages.first.?, .grapheme_bytes);
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        try testing.expectEqual(
            original_cap * 32,
            page.capacity.grapheme_bytes,
        );
        try testing.expectEqual(
            @as(usize, s.rows * s.cols),
            page.graphemeCount(),
        );
        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                try testing.expectEqual(
                    @as(u21, @intCast(x + 1)),
                    rac.cell.content.codepoint.data,
                );
                const cps = page.lookupGrapheme(rac.cell).?;
                try testing.expectEqual(@as(usize, 2), cps.len);
                try testing.expectEqual(@as(u21, 0x0301), cps[0]);
                try testing.expectEqual(@as(u21, 0x0302), cps[1]);
            }
        }
    }
}
test "PageList increaseCapacity to increase hyperlinks" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_size = 0 });
    defer s.deinit();
    const original_cap = s.pages.first.?.capacity().hyperlink_bytes;
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = @intCast(x) } },
                };
            }
        }
    }
    _ = try s.increaseCapacity(s.pages.first.?, .hyperlink_bytes);
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        try testing.expectEqual(original_cap * 2, page.capacity.hyperlink_bytes);
        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                try testing.expectEqual(
                    @as(u21, @intCast(x)),
                    rac.cell.content.codepoint.data,
                );
            }
        }
    }
}
test "PageList increaseCapacity to increase string_bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_size = 0 });
    defer s.deinit();
    const original_cap = s.pages.first.?.capacity().string_bytes;
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = @intCast(x) } },
                };
            }
        }
    }
    _ = try s.increaseCapacity(s.pages.first.?, .string_bytes);
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        try testing.expectEqual(original_cap * 2, page.capacity.string_bytes);
        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                try testing.expectEqual(
                    @as(u21, @intCast(x)),
                    rac.cell.content.codepoint.data,
                );
            }
        }
    }
}
test "PageList increaseCapacity tracked pins" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_size = 0 });
    defer s.deinit();
    const tracked = try s.trackPin(s.pin(.{ .active = .{ .x = 1, .y = 1 } }).?);
    defer s.untrackPin(tracked);
    const old_node = s.pages.first.?;
    try testing.expectEqual(old_node, tracked.node);
    const new_node = try s.increaseCapacity(s.pages.first.?, .styles);
    try testing.expectEqual(new_node, tracked.node);
    try testing.expectEqual(@as(size.CellCountInt, 1), tracked.x);
    try testing.expectEqual(@as(size.CellCountInt, 1), tracked.y);
}
test "PageList increaseCapacity returns OutOfSpace at max capacity" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_size = 0 });
    defer s.deinit();
    const max_styles = std.math.maxInt(size.StyleCountInt);
    while (true) {
        _ = s.increaseCapacity(
            s.pages.first.?,
            .styles,
        ) catch |err| {
            try testing.expectEqual(error.OutOfSpace, err);
            try testing.expectEqual(max_styles, s.pages.first.?.capacity().styles);
            break;
        };
    }
}
test "PageList increaseCapacity after col shrink" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 2, .max_size = 0 });
    defer s.deinit();
    try s.resize(.{ .cols = 5, .reflow = false });
    try testing.expectEqual(5, s.cols);
    {
        const page = s.pages.first.?.page();
        try testing.expectEqual(5, page.size.cols);
        try testing.expect(page.capacity.cols >= 10);
    }
    _ = try s.increaseCapacity(s.pages.first.?, .styles);
    {
        const page = s.pages.first.?.page();
        try testing.expectEqual(5, page.size.cols);
        try testing.expectEqual(5, s.cols);
    }
}
test "PageList increaseCapacity multi-page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const page1_node = s.pages.last.?;
    page1_node.page().pauseIntegrityChecks(true);
    for (0..page1_node.capacity().rows - page1_node.rows()) |_| {
        try testing.expect(try s.grow() == null);
    }
    page1_node.page().pauseIntegrityChecks(false);
    try testing.expect(try s.grow() != null);
    try testing.expect(s.pages.first != s.pages.last);
    const page2_node = s.pages.last.?;
    const page1_styles_cap = s.pages.first.?.capacity().styles;
    const page2_styles_cap = page2_node.capacity().styles;
    _ = try s.increaseCapacity(s.pages.first.?, .styles);
    try testing.expectEqual(
        page1_styles_cap * 2,
        s.pages.first.?.capacity().styles,
    );
    try testing.expectEqual(
        page2_styles_cap,
        s.pages.last.?.capacity().styles,
    );
}
test "PageList increaseCapacity preserves dirty flag" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 4, .max_size = 0 });
    defer s.deinit();
    const page = s.pages.first.?.page();
    page.dirty = true;
    const rows = page.rows.ptr(page.memory);
    rows[0].dirty = true;
    rows[1].dirty = false;
    rows[2].dirty = true;
    rows[3].dirty = false;
    const new_node = try s.increaseCapacity(s.pages.first.?, .styles);
    try testing.expect(new_node.page().dirty);
    const new_rows = new_node.page().rows.ptr(new_node.page().memory);
    try testing.expect(new_rows[0].dirty);
    try testing.expect(!new_rows[1].dirty);
    try testing.expect(new_rows[2].dirty);
    try testing.expect(!new_rows[3].dirty);
}
test "PageList pageIterator single page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try testing.expect(s.pages.first.?.next == null);
    var it = s.pageIterator(.right_down, .{ .active = .{} }, null);
    {
        const chunk = it.next().?;
        try testing.expect(chunk.node == s.pages.first.?);
        try testing.expectEqual(@as(usize, 0), chunk.start);
        try testing.expectEqual(@as(usize, s.rows), chunk.end);
    }
    try testing.expect(it.next() == null);
}
test "PageList pageIterator two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const page1_node = s.pages.last.?;
    const page1 = page1_node.page();
    page1_node.page().pauseIntegrityChecks(true);
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }
    page1_node.page().pauseIntegrityChecks(false);
    try testing.expect(try s.grow() != null);
    var it = s.pageIterator(.right_down, .{ .active = .{} }, null);
    {
        const chunk = it.next().?;
        try testing.expect(chunk.node == s.pages.first.?);
        const start = chunk.node.rows() - s.rows + 1;
        try testing.expectEqual(start, chunk.start);
        try testing.expectEqual(chunk.node.rows(), chunk.end);
    }
    {
        const chunk = it.next().?;
        try testing.expect(chunk.node == s.pages.last.?);
        const start: usize = 0;
        try testing.expectEqual(start, chunk.start);
        try testing.expectEqual(start + 1, chunk.end);
    }
    try testing.expect(it.next() == null);
}
test "PageList pageIterator history two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const page1_node = s.pages.last.?;
    const page1 = page1_node.page();
    page1_node.page().pauseIntegrityChecks(true);
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }
    page1_node.page().pauseIntegrityChecks(false);
    try testing.expect(try s.grow() != null);
    var it = s.pageIterator(.right_down, .{ .history = .{} }, null);
    {
        const active_tl = s.getTopLeft(.active);
        const chunk = it.next().?;
        try testing.expect(chunk.node == s.pages.first.?);
        const start: usize = 0;
        try testing.expectEqual(start, chunk.start);
        try testing.expectEqual(active_tl.y, chunk.end);
    }
    try testing.expect(it.next() == null);
}
test "PageList pageIterator reverse single page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try testing.expect(s.pages.first.?.next == null);
    var it = s.pageIterator(.left_up, .{ .active = .{} }, null);
    {
        const chunk = it.next().?;
        try testing.expect(chunk.node == s.pages.first.?);
        try testing.expectEqual(@as(usize, 0), chunk.start);
        try testing.expectEqual(@as(usize, s.rows), chunk.end);
    }
    try testing.expect(it.next() == null);
}
test "PageList pageIterator reverse two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const page1_node = s.pages.last.?;
    const page1 = page1_node.page();
    page1_node.page().pauseIntegrityChecks(true);
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }
    page1_node.page().pauseIntegrityChecks(false);
    try testing.expect(try s.grow() != null);
    var it = s.pageIterator(.left_up, .{ .active = .{} }, null);
    var count: usize = 0;
    {
        const chunk = it.next().?;
        try testing.expect(chunk.node == s.pages.last.?);
        const start: usize = 0;
        try testing.expectEqual(start, chunk.start);
        try testing.expectEqual(start + 1, chunk.end);
        count += chunk.end - chunk.start;
    }
    {
        const chunk = it.next().?;
        try testing.expect(chunk.node == s.pages.first.?);
        const start = chunk.node.rows() - s.rows + 1;
        try testing.expectEqual(start, chunk.start);
        try testing.expectEqual(chunk.node.rows(), chunk.end);
        count += chunk.end - chunk.start;
    }
    try testing.expect(it.next() == null);
    try testing.expectEqual(s.rows, count);
}
test "PageList pageIterator reverse history two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const page1_node = s.pages.last.?;
    const page1 = page1_node.page();
    page1_node.page().pauseIntegrityChecks(true);
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }
    page1_node.page().pauseIntegrityChecks(false);
    try testing.expect(try s.grow() != null);
    var it = s.pageIterator(.left_up, .{ .history = .{} }, null);
    {
        const active_tl = s.getTopLeft(.active);
        const chunk = it.next().?;
        try testing.expect(chunk.node == s.pages.first.?);
        const start: usize = 0;
        try testing.expectEqual(start, chunk.start);
        try testing.expectEqual(active_tl.y, chunk.end);
    }
    try testing.expect(it.next() == null);
}
test "PageList PageIterator reverse count includes row zero" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 2 });
    defer s.deinit();
    var it: PageIterator = .{
        .row = s.getTopLeft(.screen),
        .limit = .{ .count = 1 },
        .direction = .left_up,
    };
    const chunk = it.next().?;
    try testing.expectEqual(@as(size.CellCountInt, 0), chunk.start);
    try testing.expectEqual(@as(size.CellCountInt, 1), chunk.end);
    try testing.expect(it.next() == null);
}
test "PageList PageIterator count crosses page boundaries" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const first = s.pages.first.?;
    first.page().pauseIntegrityChecks(true);
    while (first.rows() < first.capacity().rows) _ = try s.grow();
    first.page().pauseIntegrityChecks(false);
    const second = (try s.grow()).?;
    var down: PageIterator = .{
        .row = .{ .node = first, .y = first.rows() - 1 },
        .limit = .{ .count = 2 },
        .direction = .right_down,
    };
    {
        const chunk = down.next().?;
        try testing.expectEqual(first, chunk.node);
        try testing.expectEqual(first.rows() - 1, chunk.start);
        try testing.expectEqual(first.rows(), chunk.end);
    }
    {
        const chunk = down.next().?;
        try testing.expectEqual(second, chunk.node);
        try testing.expectEqual(@as(size.CellCountInt, 0), chunk.start);
        try testing.expectEqual(@as(size.CellCountInt, 1), chunk.end);
    }
    try testing.expect(down.next() == null);
    var up: PageIterator = .{
        .row = .{ .node = second },
        .limit = .{ .count = 2 },
        .direction = .left_up,
    };
    {
        const chunk = up.next().?;
        try testing.expectEqual(second, chunk.node);
        try testing.expectEqual(@as(size.CellCountInt, 0), chunk.start);
        try testing.expectEqual(@as(size.CellCountInt, 1), chunk.end);
    }
    {
        const chunk = up.next().?;
        try testing.expectEqual(first, chunk.node);
        try testing.expectEqual(first.rows() - 1, chunk.start);
        try testing.expectEqual(first.rows(), chunk.end);
    }
    try testing.expect(up.next() == null);
}
test "PageList cellIterator" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    var it = s.cellIterator(.right_down, .{ .screen = .{} }, null);
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 1,
        } }, s.pointFromPin(.screen, p).?);
    }
    try testing.expect(it.next() == null);
}
test "PageList cellIterator reverse" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    var it = s.cellIterator(.left_up, .{ .screen = .{} }, null);
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 1,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pointFromPin(.screen, p).?);
    }
    try testing.expect(it.next() == null);
}
test "PageList promptIterator left_up" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 3);
        rac.row.semantic_prompt = .prompt;
    }
    {
        const rac = page.getRowAndCell(0, 6);
        rac.row.semantic_prompt = .prompt;
    }
    {
        const rac = page.getRowAndCell(0, 7);
        rac.row.semantic_prompt = .prompt_continuation;
    }
    {
        const rac = page.getRowAndCell(0, 8);
        rac.row.semantic_prompt = .prompt_continuation;
    }
    {
        const rac = page.getRowAndCell(0, 12);
        rac.row.semantic_prompt = .prompt_continuation;
    }
    var it = s.promptIterator(.left_up, .{ .screen = .{} }, null);
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 12,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 6,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 3,
        } }, s.pointFromPin(.screen, p).?);
    }
    try testing.expect(it.next() == null);
}
test "PageList promptIterator right_down" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 3);
        rac.row.semantic_prompt = .prompt;
    }
    {
        const rac = page.getRowAndCell(0, 6);
        rac.row.semantic_prompt = .prompt;
    }
    {
        const rac = page.getRowAndCell(0, 7);
        rac.row.semantic_prompt = .prompt_continuation;
    }
    {
        const rac = page.getRowAndCell(0, 8);
        rac.row.semantic_prompt = .prompt_continuation;
    }
    {
        const rac = page.getRowAndCell(0, 12);
        rac.row.semantic_prompt = .prompt_continuation;
    }
    var it = s.promptIterator(.right_down, .{ .screen = .{} }, null);
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 3,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 6,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 12,
        } }, s.pointFromPin(.screen, p).?);
    }
    try testing.expect(it.next() == null);
}
test "PageList promptIterator right_down continuation at start" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 0);
        rac.row.semantic_prompt = .prompt_continuation;
    }
    {
        const rac = page.getRowAndCell(0, 1);
        rac.row.semantic_prompt = .prompt_continuation;
    }
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
    }
    var it = s.promptIterator(.right_down, .{ .screen = .{} }, null);
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 5,
        } }, s.pointFromPin(.screen, p).?);
    }
    try testing.expect(it.next() == null);
}
test "PageList promptIterator right_down with prompt before continuation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 2);
        rac.row.semantic_prompt = .prompt;
    }
    {
        const rac = page.getRowAndCell(0, 3);
        rac.row.semantic_prompt = .prompt_continuation;
    }
    {
        const rac = page.getRowAndCell(0, 4);
        rac.row.semantic_prompt = .prompt_continuation;
    }
    var it = s.promptIterator(.right_down, .{ .screen = .{ .y = 3 } }, null);
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 3,
        } }, s.pointFromPin(.screen, p).?);
    }
    try testing.expect(it.next() == null);
}
test "PageList promptIterator right_down limit inclusive" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
    }
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }
    var it = s.promptIterator(.right_down, .{ .screen = .{} }, .{ .screen = .{ .y = 5 } });
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 5,
        } }, s.pointFromPin(.screen, p).?);
    }
    try testing.expect(it.next() == null);
}
test "PageList promptIterator left_up limit inclusive" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
    }
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }
    var it = s.promptIterator(.left_up, .{ .screen = .{ .y = 10 } }, .{ .screen = .{ .y = 15 } });
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, s.pointFromPin(.screen, p).?);
    }
    try testing.expect(it.next() == null);
}
test "PageList highlightSemanticContent prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
        for (0..5) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'A' } },
                .semantic_content = .prompt,
            };
        }
        for (5..8) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'B' } },
                .semantic_content = .input,
            };
        }
    }
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 2, .y = 5 } }).?,
        .prompt,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 7,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.end).?);
}
test "PageList highlightSemanticContent prompt with output" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
        for (0..3) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }
        for (3..7) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'l' } },
                .semantic_content = .input,
            };
        }
        for (7..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'o' } },
                .semantic_content = .output,
            };
        }
    }
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .prompt,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 6,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.end).?);
}
test "PageList highlightSemanticContent prompt multiline" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
        for (0..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }
    }
    {
        for (0..5) |x| {
            const cell = page.getRowAndCell(x, 6).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'c' } },
                .semantic_content = .input,
            };
        }
    }
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 2, .y = 5 } }).?,
        .prompt,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 4,
        .y = 6,
    } }, s.pointFromPin(.screen, hl.end).?);
}
test "PageList highlightSemanticContent prompt only" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
        for (0..5) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }
    }
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .prompt,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 4,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.end).?);
}
test "PageList highlightSemanticContent prompt to end of screen" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 15);
        rac.row.semantic_prompt = .prompt;
        for (0..3) |x| {
            const cell = page.getRowAndCell(x, 15).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }
        for (3..8) |x| {
            const cell = page.getRowAndCell(x, 15).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'c' } },
                .semantic_content = .input,
            };
        }
    }
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 15 } }).?,
        .prompt,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 15,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 7,
        .y = 15,
    } }, s.pointFromPin(.screen, hl.end).?);
}
test "PageList highlightSemanticContent input basic" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
        for (0..3) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }
        for (3..8) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'l' } },
                .semantic_content = .input,
            };
        }
    }
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .input,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 3,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 7,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.end).?);
}
test "PageList highlightSemanticContent input with output" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
        for (0..2) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }
        for (2..5) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'c' } },
                .semantic_content = .input,
            };
        }
        for (5..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'o' } },
                .semantic_content = .output,
            };
        }
    }
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .input,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 2,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 4,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.end).?);
}
test "PageList highlightSemanticContent input multiline with continuation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
        for (0..2) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }
        for (2..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'c' } },
                .semantic_content = .input,
            };
        }
    }
    {
        for (0..2) |x| {
            const cell = page.getRowAndCell(x, 6).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '>' } },
                .semantic_content = .prompt,
            };
        }
        for (2..6) |x| {
            const cell = page.getRowAndCell(x, 6).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'd' } },
                .semantic_content = .input,
            };
        }
    }
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .input,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 2,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 5,
        .y = 6,
    } }, s.pointFromPin(.screen, hl.end).?);
}
test "PageList highlightSemanticContent input no input returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
        for (0..3) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }
        for (3..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'o' } },
                .semantic_content = .output,
            };
        }
    }
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .input,
    );
    try testing.expect(hl == null);
}
test "PageList highlightSemanticContent input to end of screen" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 15);
        rac.row.semantic_prompt = .prompt;
        for (0..2) |x| {
            const cell = page.getRowAndCell(x, 15).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }
        for (2..7) |x| {
            const cell = page.getRowAndCell(x, 15).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'c' } },
                .semantic_content = .input,
            };
        }
    }
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 15 } }).?,
        .input,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 2,
        .y = 15,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 6,
        .y = 15,
    } }, s.pointFromPin(.screen, hl.end).?);
}
test "PageList highlightSemanticContent input prompt only returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
        for (0..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }
    }
    {
        for (6..10) |y| {
            for (0..10) |x| {
                const cell = page.getRowAndCell(x, y).cell;
                cell.semantic_content = .prompt;
            }
        }
    }
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .input,
    );
    try testing.expect(hl == null);
}
test "PageList highlightSemanticContent output basic" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
        for (0..2) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }
        for (2..5) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'l' } },
                .semantic_content = .input,
            };
        }
        for (5..8) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'o' } },
                .semantic_content = .output,
            };
        }
        for (8..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.semantic_content = .prompt;
        }
    }
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .output,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 5,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 7,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.end).?);
}
test "PageList highlightSemanticContent output multiline" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
        for (0..2) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }
        for (2..4) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'l' } },
                .semantic_content = .input,
            };
        }
        for (4..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'o' } },
                .semantic_content = .output,
            };
        }
    }
    {
        for (0..10) |x| {
            const cell = page.getRowAndCell(x, 6).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'o' } },
                .semantic_content = .output,
            };
        }
    }
    {
        for (0..5) |x| {
            const cell = page.getRowAndCell(x, 7).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'o' } },
                .semantic_content = .output,
            };
        }
        for (5..10) |x| {
            const cell = page.getRowAndCell(x, 7).cell;
            cell.semantic_content = .input;
        }
    }
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .output,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 4,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 4,
        .y = 7,
    } }, s.pointFromPin(.screen, hl.end).?);
}
test "PageList highlightSemanticContent output stops at next prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
        for (0..2) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }
        for (2..4) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'l' } },
                .semantic_content = .input,
            };
        }
        for (4..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'o' } },
                .semantic_content = .output,
            };
        }
    }
    {
        for (0..3) |x| {
            const cell = page.getRowAndCell(x, 6).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'o' } },
                .semantic_content = .output,
            };
        }
        for (3..6) |x| {
            const cell = page.getRowAndCell(x, 6).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }
    }
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .output,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 4,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 2,
        .y = 6,
    } }, s.pointFromPin(.screen, hl.end).?);
}
test "PageList highlightSemanticContent output to end of screen" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 15);
        rac.row.semantic_prompt = .prompt;
        for (0..2) |x| {
            const cell = page.getRowAndCell(x, 15).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }
        for (2..4) |x| {
            const cell = page.getRowAndCell(x, 15).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'c' } },
                .semantic_content = .input,
            };
        }
        for (4..10) |x| {
            const cell = page.getRowAndCell(x, 15).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'o' } },
                .semantic_content = .output,
            };
        }
    }
    {
        for (0..8) |x| {
            const cell = page.getRowAndCell(x, 16).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'o' } },
                .semantic_content = .output,
            };
        }
        for (8..10) |x| {
            const cell = page.getRowAndCell(x, 16).cell;
            cell.semantic_content = .prompt;
        }
    }
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 15 } }).?,
        .output,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 4,
        .y = 15,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 7,
        .y = 16,
    } }, s.pointFromPin(.screen, hl.end).?);
}
test "PageList highlightSemanticContent output no output returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
        for (0..3) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }
        for (3..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'c' } },
                .semantic_content = .input,
            };
        }
    }
    {
        for (6..10) |y| {
            for (0..10) |x| {
                const cell = page.getRowAndCell(x, y).cell;
                cell.semantic_content = .input;
            }
        }
    }
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .output,
    );
    try testing.expect(hl == null);
}
test "PageList highlightSemanticContent output skips empty cells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 20, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
        for (0..3) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '$' } },
                .semantic_content = .prompt,
            };
        }
    }
    {
        for (0..4) |x| {
            const cell = page.getRowAndCell(x, 6).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'l' } },
                .semantic_content = .input,
            };
        }
    }
    {
        for (7..9) |y| {
            for (0..5) |x| {
                const cell = page.getRowAndCell(x, y).cell;
                cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = 'o' } },
                    .semantic_content = .output,
                };
            }
        }
    }
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .output,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 7,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 4,
        .y = 8,
    } }, s.pointFromPin(.screen, hl.end).?);
}
test "PageList erase" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());
    const page = s.pages.last.?.page();
    var cur_page = s.pages.last.?;
    cur_page.page().pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.page().pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.page().pauseIntegrityChecks(true);
        }
    }
    cur_page.page().pauseIntegrityChecks(false);
    try testing.expectEqual(@as(usize, 6), s.totalPages());
    try testing.expect(s.total_rows > s.rows);
    s.eraseHistory(null);
    try testing.expectEqual(s.rows, s.total_rows);
    try testing.expectEqual(@as(usize, 1), s.totalPages());
    try testing.expect(s.pages.first == s.pages.last);
}
test "PageList erase reaccounts page size" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const start_size = s.page_size;
    const page = s.pages.last.?.page();
    var cur_page = s.pages.last.?;
    cur_page.page().pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.page().pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.page().pauseIntegrityChecks(true);
        }
    }
    cur_page.page().pauseIntegrityChecks(false);
    try testing.expect(s.page_size > start_size);
    s.eraseHistory(null);
    try testing.expectEqual(start_size, s.page_size);
}
test "PageList erase row with tracked pin resets to top-left" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const page = s.pages.last.?.page();
    var cur_page = s.pages.last.?;
    cur_page.page().pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.page().pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.page().pauseIntegrityChecks(true);
        }
    }
    cur_page.page().pauseIntegrityChecks(false);
    try testing.expect(s.total_rows > s.rows);
    const p = try s.trackPin(s.pin(.{ .history = .{} }).?);
    defer s.untrackPin(p);
    s.eraseHistory(null);
    try testing.expectEqual(s.rows, s.total_rows);
    try testing.expectEqual(s.pages.first.?, p.node);
    try testing.expectEqual(@as(usize, 0), p.y);
    try testing.expectEqual(@as(usize, 0), p.x);
}
test "PageList erase row with tracked pin shifts" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const p = try s.trackPin(s.pin(.{ .active = .{ .y = 4, .x = 2 } }).?);
    defer s.untrackPin(p);
    s.eraseActive(3);
    try testing.expectEqual(s.rows, s.total_rows);
    try testing.expectEqual(s.pages.first.?, p.node);
    try testing.expectEqual(@as(usize, 0), p.y);
    try testing.expectEqual(@as(usize, 2), p.x);
}
test "PageList erase row with tracked pin is erased" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const p = try s.trackPin(s.pin(.{ .active = .{ .y = 2, .x = 2 } }).?);
    defer s.untrackPin(p);
    s.eraseActive(3);
    try testing.expectEqual(s.rows, s.total_rows);
    try testing.expectEqual(s.pages.first.?, p.node);
    try testing.expectEqual(@as(usize, 0), p.y);
    try testing.expectEqual(@as(usize, 0), p.x);
}
test "PageList erase resets viewport to active if moves within active" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const page = s.pages.last.?.page();
    var cur_page = s.pages.last.?;
    cur_page.page().pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.page().pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.page().pauseIntegrityChecks(true);
        }
    }
    cur_page.page().pauseIntegrityChecks(false);
    s.scroll(.{ .delta_row = -@as(isize, @intCast(s.total_rows)) });
    try testing.expect(s.viewport == .top);
    s.eraseHistory(null);
    try testing.expect(s.viewport == .active);
}
test "PageList erase resets viewport if inside erased page but not active" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const page = s.pages.last.?.page();
    var cur_page = s.pages.last.?;
    cur_page.page().pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.page().pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.page().pauseIntegrityChecks(true);
        }
    }
    cur_page.page().pauseIntegrityChecks(false);
    s.scroll(.{ .delta_row = -@as(isize, @intCast(s.total_rows)) });
    try testing.expect(s.viewport == .top);
    s.eraseHistory(.{ .history = .{ .y = 2 } });
    try testing.expect(s.viewport == .top);
}
test "PageList erase resets viewport to active if top is inside active" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const page = s.pages.last.?.page();
    var cur_page = s.pages.last.?;
    cur_page.page().pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.page().pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.page().pauseIntegrityChecks(true);
        }
    }
    cur_page.page().pauseIntegrityChecks(false);
    s.scroll(.{ .top = {} });
    s.eraseHistory(null);
    try testing.expect(s.viewport == .active);
}
test "PageList erase active regrows automatically" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try testing.expect(s.totalRows() == s.rows);
    s.eraseActive(10);
    try testing.expect(s.totalRows() == s.rows);
}
test "PageList erase a one-row active" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 1 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };
    }
    s.eraseActive(0);
    try testing.expectEqual(s.rows, s.total_rows);
    {
        const get = s.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expectEqual(@as(u21, 0), get.cell.content.codepoint.data);
    }
}
test "PageList eraseRowBounded less than full row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 10 });
    defer s.deinit();
    const p_top = try s.trackPin(s.pin(.{ .active = .{ .y = 5, .x = 0 } }).?);
    defer s.untrackPin(p_top);
    const p_bot = try s.trackPin(s.pin(.{ .active = .{ .y = 8, .x = 0 } }).?);
    defer s.untrackPin(p_bot);
    const p_out = try s.trackPin(s.pin(.{ .active = .{ .y = 9, .x = 0 } }).?);
    defer s.untrackPin(p_out);
    try s.eraseRowBounded(.{ .active = .{ .y = 5 } }, 3);
    try testing.expectEqual(s.rows, s.totalRows());
    try testing.expect(s.isDirty(.{ .active = .{ .x = 0, .y = 5 } }));
    try testing.expect(s.isDirty(.{ .active = .{ .x = 0, .y = 6 } }));
    try testing.expect(s.isDirty(.{ .active = .{ .x = 0, .y = 7 } }));
    try testing.expectEqual(s.pages.first.?, p_top.node);
    try testing.expectEqual(@as(usize, 4), p_top.y);
    try testing.expectEqual(@as(usize, 0), p_top.x);
    try testing.expectEqual(s.pages.first.?, p_bot.node);
    try testing.expectEqual(@as(usize, 7), p_bot.y);
    try testing.expectEqual(@as(usize, 0), p_bot.x);
    try testing.expectEqual(s.pages.first.?, p_out.node);
    try testing.expectEqual(@as(usize, 9), p_out.y);
    try testing.expectEqual(@as(usize, 0), p_out.x);
}
test "PageList eraseRowBounded with pin at top" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 10 });
    defer s.deinit();
    const p_top = try s.trackPin(s.pin(.{ .active = .{ .y = 0, .x = 5 } }).?);
    defer s.untrackPin(p_top);
    try s.eraseRowBounded(.{ .active = .{ .y = 0 } }, 3);
    try testing.expectEqual(s.rows, s.totalRows());
    try testing.expect(s.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(s.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(s.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expectEqual(s.pages.first.?, p_top.node);
    try testing.expectEqual(@as(usize, 0), p_top.y);
    try testing.expectEqual(@as(usize, 0), p_top.x);
}
test "PageList eraseRowBounded full rows single page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 10 });
    defer s.deinit();
    const p_in = try s.trackPin(s.pin(.{ .active = .{ .y = 7, .x = 0 } }).?);
    defer s.untrackPin(p_in);
    const p_out = try s.trackPin(s.pin(.{ .active = .{ .y = 9, .x = 0 } }).?);
    defer s.untrackPin(p_out);
    try s.eraseRowBounded(.{ .active = .{ .y = 5 } }, 10);
    try testing.expectEqual(s.rows, s.totalRows());
    for (5..10) |y| try testing.expect(s.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));
    try testing.expectEqual(s.pages.first.?, p_in.node);
    try testing.expectEqual(@as(usize, 6), p_in.y);
    try testing.expectEqual(@as(usize, 0), p_in.x);
    try testing.expectEqual(s.pages.first.?, p_out.node);
    try testing.expectEqual(@as(usize, 8), p_out.y);
    try testing.expectEqual(@as(usize, 0), p_out.x);
}
test "PageList eraseRowBounded full rows two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 10 });
    defer s.deinit();
    {
        const page = s.pages.last.?.page();
        page.pauseIntegrityChecks(true);
        for (0..page.capacity.rows - page.size.rows) |_| _ = try s.grow();
        page.pauseIntegrityChecks(false);
        try s.growRows(5);
        try testing.expectEqual(@as(usize, 2), s.totalPages());
        try testing.expectEqual(@as(usize, 5), s.pages.last.?.rows());
    }
    const p_first = try s.trackPin(s.pin(.{ .active = .{ .y = 4, .x = 0 } }).?);
    defer s.untrackPin(p_first);
    const p_first_out = try s.trackPin(s.pin(.{ .active = .{ .y = 3, .x = 0 } }).?);
    defer s.untrackPin(p_first_out);
    const p_in = try s.trackPin(s.pin(.{ .active = .{ .y = 8, .x = 0 } }).?);
    defer s.untrackPin(p_in);
    const p_out = try s.trackPin(s.pin(.{ .active = .{ .y = 9, .x = 0 } }).?);
    defer s.untrackPin(p_out);
    {
        try testing.expectEqual(s.pages.last.?.prev.?, p_first.node);
        try testing.expectEqual(@as(usize, p_first.node.rows() - 1), p_first.y);
        try testing.expectEqual(@as(usize, 0), p_first.x);
        try testing.expectEqual(s.pages.last.?.prev.?, p_first_out.node);
        try testing.expectEqual(@as(usize, p_first_out.node.rows() - 2), p_first_out.y);
        try testing.expectEqual(@as(usize, 0), p_first_out.x);
        try testing.expectEqual(s.pages.last.?, p_in.node);
        try testing.expectEqual(@as(usize, 3), p_in.y);
        try testing.expectEqual(@as(usize, 0), p_in.x);
        try testing.expectEqual(s.pages.last.?, p_out.node);
        try testing.expectEqual(@as(usize, 4), p_out.y);
        try testing.expectEqual(@as(usize, 0), p_out.x);
    }
    try s.eraseRowBounded(.{ .active = .{ .y = 4 } }, 4);
    for (4..8) |y| try testing.expect(s.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));
    try testing.expectEqual(s.pages.last.?.prev.?, p_first.node);
    try testing.expectEqual(@as(usize, p_first.node.rows() - 2), p_first.y);
    try testing.expectEqual(@as(usize, 0), p_first.x);
    try testing.expectEqual(s.pages.last.?.prev.?, p_first_out.node);
    try testing.expectEqual(@as(usize, p_first_out.node.rows() - 2), p_first_out.y);
    try testing.expectEqual(@as(usize, 0), p_first_out.x);
    try testing.expectEqual(s.pages.last.?, p_in.node);
    try testing.expectEqual(@as(usize, 2), p_in.y);
    try testing.expectEqual(@as(usize, 0), p_in.x);
    try testing.expectEqual(s.pages.last.?, p_out.node);
    try testing.expectEqual(@as(usize, 4), p_out.y);
    try testing.expectEqual(@as(usize, 0), p_out.x);
}
test "PageList eraseRow hyperlink-dense row crosses page boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 10 });
    defer s.deinit();
    {
        const page = s.pages.last.?.page();
        page.pauseIntegrityChecks(true);
        for (0..page.capacity.rows - page.size.rows) |_| _ = try s.grow();
        page.pauseIntegrityChecks(false);
        try s.growRows(5);
        try testing.expectEqual(@as(usize, 2), s.totalPages());
        try testing.expectEqual(@as(usize, 5), s.pages.last.?.rows());
    }
    for (0..10) |y| {
        const row_pin = s.pin(.{ .active = .{ .y = @intCast(y) } }).?;
        row_pin.rowAndCell().cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast('0' + y) } },
        };
    }
    const link_count: usize = 10;
    while (s.pages.last.?.page().hyperlink_set.layout.cap <= link_count) {
        _ = try s.increaseCapacity(s.pages.last.?, .hyperlink_bytes);
    }
    try testing.expect(s.pages.first.?.page().hyperlink_set.layout.cap < link_count);
    {
        const page = s.pages.last.?.page();
        for (0..link_count) |x| {
            var buf: [64]u8 = undefined;
            const uri = try std.fmt.bufPrint(&buf, "http://example.com/{d}", .{x});
            const id = try page.insertHyperlink(.{
                .id = .{ .implicit = @intCast(x) },
                .uri = uri,
            });
            const rac = page.getRowAndCell(x, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast('A' + x) } },
            };
            try page.setHyperlink(rac.row, rac.cell, id);
            page.hyperlink_set.use(page.memory, id);
        }
    }
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 3, .y = 1 } }).?);
    defer s.untrackPin(p);
    try s.eraseRow(.{ .active = .{ .y = 0 } });
    const expected = [10]u21{ '1', '2', '3', '4', 'A', '6', '7', '8', '9', 0 };
    for (expected, 0..) |cp, y| {
        const list_cell = s.getCell(.{ .active = .{ .y = @intCast(y) } }).?;
        try testing.expectEqual(cp, list_cell.cell.content.codepoint.data);
    }
    for (0..link_count) |x| {
        const list_cell = s.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 4,
        } }).?;
        try testing.expect(list_cell.cell.hyperlink);
        const page: *Page = list_cell.node.page();
        const id = page.lookupHyperlink(list_cell.cell).?;
        const link = page.hyperlink_set.get(page.memory, id);
        var buf: [64]u8 = undefined;
        const uri = try std.fmt.bufPrint(&buf, "http://example.com/{d}", .{x});
        try testing.expectEqualStrings(uri, link.uri.slice(page.memory));
    }
    var node_: ?*List.Node = s.pages.first;
    while (node_) |node| : (node_ = node.next) node.page().assertIntegrity();
    try testing.expectEqual(s.pages.first.?, p.node);
    const p_pt = s.pointFromPin(.active, p.*).?.active;
    try testing.expectEqual(@as(u32, 3), p_pt.x);
    try testing.expectEqual(@as(u32, 0), p_pt.y);
}
test "PageList eraseRowBounded hyperlink-dense row crosses page boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 10 });
    defer s.deinit();
    {
        const page = s.pages.last.?.page();
        page.pauseIntegrityChecks(true);
        for (0..page.capacity.rows - page.size.rows) |_| _ = try s.grow();
        page.pauseIntegrityChecks(false);
        try s.growRows(5);
        try testing.expectEqual(@as(usize, 2), s.totalPages());
        try testing.expectEqual(@as(usize, 5), s.pages.last.?.rows());
    }
    for (0..10) |y| {
        const row_pin = s.pin(.{ .active = .{ .y = @intCast(y) } }).?;
        row_pin.rowAndCell().cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast('0' + y) } },
        };
    }
    const link_count: usize = 10;
    while (s.pages.last.?.page().hyperlink_set.layout.cap <= link_count) {
        _ = try s.increaseCapacity(s.pages.last.?, .hyperlink_bytes);
    }
    try testing.expect(s.pages.first.?.page().hyperlink_set.layout.cap < link_count);
    {
        const page = s.pages.last.?.page();
        for (0..link_count) |x| {
            var buf: [64]u8 = undefined;
            const uri = try std.fmt.bufPrint(&buf, "http://example.com/{d}", .{x});
            const id = try page.insertHyperlink(.{
                .id = .{ .implicit = @intCast(x) },
                .uri = uri,
            });
            const rac = page.getRowAndCell(x, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast('A' + x) } },
            };
            try page.setHyperlink(rac.row, rac.cell, id);
            page.hyperlink_set.use(page.memory, id);
        }
    }
    try s.eraseRowBounded(.{ .active = .{ .y = 0 } }, 6);
    const expected = [10]u21{ '1', '2', '3', '4', 'A', '6', 0, '7', '8', '9' };
    for (expected, 0..) |cp, y| {
        const list_cell = s.getCell(.{ .active = .{ .y = @intCast(y) } }).?;
        try testing.expectEqual(cp, list_cell.cell.content.codepoint.data);
    }
    for (0..link_count) |x| {
        const list_cell = s.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 4,
        } }).?;
        try testing.expect(list_cell.cell.hyperlink);
        const page: *Page = list_cell.node.page();
        const id = page.lookupHyperlink(list_cell.cell).?;
        const link = page.hyperlink_set.get(page.memory, id);
        var buf: [64]u8 = undefined;
        const uri = try std.fmt.bufPrint(&buf, "http://example.com/{d}", .{x});
        try testing.expectEqualStrings(uri, link.uri.slice(page.memory));
    }
    var node_: ?*List.Node = s.pages.first;
    while (node_) |node| : (node_ = node.next) node.page().assertIntegrity();
}
test "PageList clone" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
    var s2 = try s.clone(alloc, .{
        .top = .{ .screen = .{} },
    });
    defer s2.deinit();
    try testing.expectEqual(@as(usize, s.rows), s2.totalRows());
}
test "PageList clone partial trimmed right" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 20 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
    try s.growRows(30);
    var s2 = try s.clone(alloc, .{
        .top = .{ .screen = .{} },
        .bot = .{ .screen = .{ .y = 39 } },
    });
    defer s2.deinit();
    try testing.expectEqual(@as(usize, 40), s2.totalRows());
}
test "PageList clone partial trimmed left" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 20 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
    try s.growRows(30);
    var s2 = try s.clone(alloc, .{
        .top = .{ .screen = .{ .y = 10 } },
    });
    defer s2.deinit();
    try testing.expectEqual(@as(usize, 40), s2.totalRows());
}
test "PageList clone partial trimmed left reclaims styles" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 20 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
    try s.growRows(30);
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        const style: stylepkg.Style = .{ .flags = .{ .bold = true } };
        const style_id = try page.styles.add(page.memory, style);
        var it = s.rowIterator(.left_up, .{ .screen = .{} }, .{ .screen = .{ .y = 9 } });
        while (it.next()) |p| {
            const rac = p.rowAndCell();
            rac.row.styled = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'A' } },
                .style_id = style_id,
            };
            page.styles.use(page.memory, style_id);
        }
        page.styles.release(page.memory, style_id);
        try testing.expectEqual(1, page.styles.count());
    }
    var s2 = try s.clone(alloc, .{
        .top = .{ .screen = .{ .y = 10 } },
    });
    defer s2.deinit();
    try testing.expectEqual(@as(usize, 40), s2.totalRows());
    {
        try testing.expect(s2.pages.first == s2.pages.last);
        const page = s2.pages.first.?.page();
        try testing.expectEqual(0, page.styles.count());
    }
}
test "PageList clone partial trimmed both" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 20 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
    try s.growRows(30);
    var s2 = try s.clone(alloc, .{
        .top = .{ .screen = .{ .y = 10 } },
        .bot = .{ .screen = .{ .y = 35 } },
    });
    defer s2.deinit();
    try testing.expectEqual(@as(usize, 26), s2.totalRows());
}
test "PageList clone less than active" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
    var s2 = try s.clone(alloc, .{
        .top = .{ .active = .{ .y = 5 } },
    });
    defer s2.deinit();
    try testing.expectEqual(@as(usize, s.rows), s2.totalRows());
}
test "PageList clone remap tracked pin" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 6 } }).?);
    defer s.untrackPin(p);
    var pin_remap = Clone.TrackedPinsRemap.init(alloc);
    defer pin_remap.deinit();
    var s2 = try s.clone(alloc, .{
        .top = .{ .active = .{ .y = 5 } },
        .tracked_pins = &pin_remap,
    });
    defer s2.deinit();
    const p2 = pin_remap.get(p).?;
    try testing.expectEqual(
        point.Point{ .active = .{ .x = 0, .y = 1 } },
        s2.pointFromPin(.active, p2.*).?,
    );
}
test "PageList clone remap tracked pin not in cloned area" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 3 } }).?);
    defer s.untrackPin(p);
    var pin_remap = Clone.TrackedPinsRemap.init(alloc);
    defer pin_remap.deinit();
    var s2 = try s.clone(alloc, .{
        .top = .{ .active = .{ .y = 5 } },
        .tracked_pins = &pin_remap,
    });
    defer s2.deinit();
    try testing.expect(pin_remap.get(p) == null);
}
test "PageList clone full dirty" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
    s.markDirty(.{ .active = .{ .x = 0, .y = 0 } });
    s.markDirty(.{ .active = .{ .x = 0, .y = 12 } });
    s.markDirty(.{ .active = .{ .x = 0, .y = 23 } });
    var s2 = try s.clone(alloc, .{
        .top = .{ .screen = .{} },
    });
    defer s2.deinit();
    try testing.expectEqual(@as(usize, s.rows), s2.totalRows());
    try testing.expect(s2.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(!s2.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(s2.isDirty(.{ .active = .{ .x = 0, .y = 12 } }));
    try testing.expect(!s2.isDirty(.{ .active = .{ .x = 0, .y = 14 } }));
    try testing.expect(s2.isDirty(.{ .active = .{ .x = 0, .y = 23 } }));
}
test "PageList resize (no reflow) more rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 3), s.totalRows());
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 2 } }).?);
    defer s.untrackPin(p);
    try s.resize(.{ .rows = 10, .reflow = false });
    try testing.expectEqual(@as(usize, 10), s.rows);
    try testing.expectEqual(@as(usize, 10), s.totalRows());
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = 2,
    } }, s.pointFromPin(.active, p.*).?);
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
}
test "PageList resize (no reflow) more rows with history" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 3 });
    defer s.deinit();
    try s.growRows(50);
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 50,
        } }, pt);
    }
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 2 } }).?);
    defer s.untrackPin(p);
    try s.resize(.{ .rows = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.rows);
    try testing.expectEqual(@as(usize, 53), s.totalRows());
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = 4,
    } }, s.pointFromPin(.active, p.*).?);
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 48,
        } }, pt);
    }
}
test "PageList resize (no reflow) less rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 10), s.totalRows());
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };
    }
    try s.resize(.{ .rows = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.rows);
    try testing.expectEqual(@as(usize, 10), s.totalRows());
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 5,
        } }, pt);
    }
}
test "PageList resize (no reflow) one rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 10), s.totalRows());
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };
    }
    try s.resize(.{ .rows = 1, .reflow = false });
    try testing.expectEqual(@as(usize, 1), s.rows);
    try testing.expectEqual(@as(usize, 10), s.totalRows());
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 9,
        } }, pt);
    }
}
test "PageList resize (no reflow) less rows cursor on bottom" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 10), s.totalRows());
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast(y) } },
        };
    }
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 9 } }).?);
    defer s.untrackPin(p);
    {
        const cursor = s.pointFromPin(.active, p.*).?.active;
        const get = s.getCell(.{ .active = .{
            .x = cursor.x,
            .y = cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, 9), get.cell.content.codepoint.data);
    }
    try s.resize(.{ .rows = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.rows);
    try testing.expectEqual(@as(usize, 10), s.totalRows());
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = 4,
    } }, s.pointFromPin(.active, p.*).?);
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 5,
        } }, pt);
    }
}
test "PageList resize (no reflow) less rows cursor in scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 10), s.totalRows());
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast(y) } },
        };
    }
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 2 } }).?);
    defer s.untrackPin(p);
    {
        const cursor = s.pointFromPin(.active, p.*).?.active;
        const get = s.getCell(.{ .active = .{
            .x = cursor.x,
            .y = cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, 2), get.cell.content.codepoint.data);
    }
    try s.resize(.{ .rows = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.rows);
    try testing.expectEqual(@as(usize, 10), s.totalRows());
    try testing.expect(s.pointFromPin(.active, p.*) == null);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 2,
    } }, s.pointFromPin(.screen, p.*).?);
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 5,
        } }, pt);
    }
}
test "PageList resize (no reflow) less rows trims blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 5, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };
    }
    for (1..s.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .bg_color_rgb,
            .content = .{ .color_rgb = .{ .r = 0xFF, .g = 0, .b = 0 } },
        };
    }
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 0 } }).?);
    defer s.untrackPin(p);
    {
        const cursor = s.pointFromPin(.active, p.*).?.active;
        const get = s.getCell(.{ .active = .{
            .x = cursor.x,
            .y = cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, 'A'), get.cell.content.codepoint.data);
    }
    try s.resize(.{ .rows = 2, .reflow = false });
    try testing.expectEqual(@as(usize, 2), s.rows);
    try testing.expectEqual(@as(usize, 2), s.totalRows());
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = 0,
    } }, s.pointFromPin(.active, p.*).?);
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
}
test "PageList resize (no reflow) less rows trims blank lines cursor in blank line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 5, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };
    }
    for (1..s.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .bg_color_rgb,
            .content = .{ .color_rgb = .{ .r = 0xFF, .g = 0, .b = 0 } },
        };
    }
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 3 } }).?);
    defer s.untrackPin(p);
    try s.resize(.{ .rows = 2, .reflow = false });
    try testing.expectEqual(@as(usize, 2), s.rows);
    try testing.expectEqual(@as(usize, 4), s.totalRows());
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = 1,
    } }, s.pointFromPin(.active, p.*).?);
}
test "PageList resize (no reflow) less rows trims blank lines erases pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 100, .rows = 5, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rows = page.capacity.rows + 10;
        try s.resize(.{ .rows = rows, .reflow = false });
        try testing.expectEqual(@as(usize, 2), s.totalPages());
    }
    {
        const rac = page.getRowAndCell(0, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };
    }
    try s.resize(.{ .rows = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.rows);
    try testing.expectEqual(@as(usize, 5), s.totalRows());
    try testing.expectEqual(@as(usize, 1), s.totalPages());
}
test "PageList resize (no reflow) more rows extends blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };
    }
    for (1..s.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .bg_color_rgb,
            .content = .{ .color_rgb = .{ .r = 0xFF, .g = 0, .b = 0 } },
        };
    }
    try s.resize(.{ .rows = 7, .reflow = false });
    try testing.expectEqual(@as(usize, 7), s.rows);
    try testing.expectEqual(@as(usize, 7), s.totalRows());
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
}
test "PageList resize (no reflow) more rows contains viewport" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 5, .rows = 5, .max_size = 1 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    _ = try s.grow();
    try testing.expectEqual(@as(usize, 5), s.rows);
    try testing.expectEqual(@as(usize, 6), s.totalRows());
    s.scroll(.{ .delta_row = -1 });
    try testing.expectEqual(Viewport.top, s.viewport);
    try s.resize(.{ .rows = 7, .reflow = false });
    try testing.expectEqual(@as(usize, 7), s.rows);
    try testing.expectEqual(@as(usize, 7), s.totalRows());
    try testing.expectEqual(Viewport.top, s.viewport);
}
test "PageList resize (no reflow) less cols" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    try s.resize(.{ .cols = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 10), s.totalRows());
    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expectEqual(@as(usize, 5), cells.len);
    }
}
test "PageList resize (no reflow) less cols pin in trimmed cols" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 8, .y = 2 } }).?);
    defer s.untrackPin(p);
    try s.resize(.{ .cols = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 10), s.totalRows());
    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expectEqual(@as(usize, 5), cells.len);
    }
    try testing.expectEqual(point.Point{ .active = .{
        .x = 4,
        .y = 2,
    } }, s.pointFromPin(.active, p.*).?);
}
test "PageList resize (no reflow) less cols clears graphemes" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(9, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };
        try page.appendGrapheme(rac.row, rac.cell, 'A');
    }
    try testing.expectEqual(@as(usize, 1), page.graphemeCount());
    try s.resize(.{ .cols = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 10), s.totalRows());
    var it = s.pageIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |chunk| {
        try testing.expectEqual(@as(usize, 0), chunk.node.page().graphemeCount());
    }
}
test "PageList resize (no reflow) more cols" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_size = 0 });
    defer s.deinit();
    try s.resize(.{ .cols = 10, .reflow = false });
    try testing.expectEqual(@as(usize, 10), s.cols);
    try testing.expectEqual(@as(usize, 3), s.totalRows());
    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expectEqual(@as(usize, 10), cells.len);
    }
}
test "PageList resize (no reflow) more cols with spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 3, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        {
            const rac = page.getRowAndCell(0, 0);
            rac.row.wrap = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
        {
            const rac = page.getRowAndCell(1, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_head,
            };
        }
        {
            const rac = page.getRowAndCell(0, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '😀' } },
                .wide = .wide,
            };
        }
        {
            const rac = page.getRowAndCell(1, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_tail,
            };
        }
    }
    try s.resize(.{ .cols = 3, .reflow = false });
    try testing.expectEqual(@as(usize, 3), s.cols);
    try testing.expectEqual(@as(usize, 3), s.totalRows());
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(1, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(2, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
        }
    }
}
test "PageList resize (no reflow) grow cols fast path with spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_size = 0 });
    defer s.deinit();
    try s.resize(.{ .cols = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.cols);
    {
        const page = s.pages.first.?.page();
        {
            const rac = page.getRowAndCell(0, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
        {
            const rac = page.getRowAndCell(4, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_head,
            };
            rac.row.wrap = true;
        }
        {
            const rac = page.getRowAndCell(4, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_head,
            };
            rac.row.wrap = true;
        }
    }
    try s.resize(.{ .cols = 10, .reflow = false });
    try testing.expectEqual(@as(usize, 10), s.cols);
    {
        const page = s.pages.first.?.page();
        {
            const rac = page.getRowAndCell(4, 0);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
            try testing.expect(!rac.row.wrap);
        }
        {
            const rac = page.getRowAndCell(4, 1);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
            try testing.expect(!rac.row.wrap);
        }
    }
}
test "PageList resize (no reflow) more cols forces less rows per page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const cols: size.CellCountInt = 5;
    const rows: size.CellCountInt = 150;
    try testing.expect((try std_capacity.adjust(.{ .cols = cols })).rows >= rows);
    var s = try init(alloc, .{ .cols = cols, .rows = rows, .max_size = 0 });
    defer s.deinit();
    {
        const new_cols = new_cols: {
            var new_cols: size.CellCountInt = 50;
            var cap = try std_capacity.adjust(.{ .cols = new_cols });
            while (cap.rows >= rows) {
                new_cols += 50;
                cap = try std_capacity.adjust(.{ .cols = new_cols });
            }
            break :new_cols new_cols;
        };
        try s.resize(.{ .cols = new_cols, .reflow = false });
        try testing.expectEqual(@as(usize, new_cols), s.cols);
        try testing.expectEqual(@as(usize, rows), s.totalRows());
    }
    {
        var it = s.pages.first;
        while (it) |page| : (it = page.next) {
            if (page == s.pages.last.?) break;
            try testing.expectEqual(page.capacity().rows, page.rows());
        }
    }
    {
        const page = s.pages.first.?.page();
        try testing.expect(page.size.rows == page.capacity.rows);
        const new_cols = new_cols: {
            var new_cols = page.size.cols + 50;
            var cap = try std_capacity.adjust(.{ .cols = new_cols });
            while (cap.rows >= page.size.rows) {
                new_cols += 50;
                cap = try std_capacity.adjust(.{ .cols = new_cols });
            }
            break :new_cols new_cols;
        };
        try s.resize(.{ .cols = new_cols, .reflow = false });
        try testing.expectEqual(@as(usize, new_cols), s.cols);
        try testing.expectEqual(@as(usize, rows), s.totalRows());
    }
    {
        var it = s.pages.first;
        while (it) |page| : (it = page.next) {
            if (page == s.pages.last.?) break;
            try testing.expectEqual(page.capacity().rows, page.rows());
        }
    }
}
test "PageList resize (no reflow) less cols then more cols" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_size = 0 });
    defer s.deinit();
    try s.resize(.{ .cols = 2, .reflow = false });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try s.resize(.{ .cols = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 3), s.totalRows());
    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expectEqual(@as(usize, 5), cells.len);
    }
}
test "PageList resize (no reflow) less rows and cols" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    try s.resize(.{ .cols = 5, .rows = 7, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 7), s.rows);
    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expectEqual(@as(usize, 5), cells.len);
    }
}
test "PageList resize less rows and cols cursor at bottom" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24, .max_size = 0 });
    defer s.deinit();
    const cursor_pin = try s.trackPin(s.pin(.{ .active = .{
        .x = 0,
        .y = s.rows - 1,
    } }).?);
    defer s.untrackPin(cursor_pin);
    try s.resize(.{
        .cols = 79,
        .rows = 20,
        .reflow = true,
        .cursor = .{ .x = 0, .y = 23, .pin = cursor_pin },
    });
    try testing.expectEqual(@as(usize, 79), s.cols);
    try testing.expectEqual(@as(usize, 20), s.rows);
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = s.rows - 1,
    } }, s.pointFromPin(.active, cursor_pin.*).?);
}
test "PageList resize less rows and cols cursor near top pushed to scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    {
        var it = s.rowIterator(.right_down, .{ .active = .{} }, null);
        while (it.next()) |p| {
            const rac = p.rowAndCell();
            const cells = p.node.page().getCells(rac.row);
            for (cells, 0..) |*cell, x| cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast('A' + (x % 26)) } },
            };
        }
    }
    const cursor_pin = try s.trackPin(s.pin(.{ .active = .{
        .x = 0,
        .y = 0,
    } }).?);
    defer s.untrackPin(cursor_pin);
    try s.resize(.{
        .cols = 79,
        .rows = 20,
        .reflow = true,
        .cursor = .{ .x = 0, .y = 0, .pin = cursor_pin },
    });
    try testing.expectEqual(@as(usize, 79), s.cols);
    try testing.expectEqual(@as(usize, 20), s.rows);
    try testing.expect(s.pointFromPin(.active, cursor_pin.*) == null);
    try testing.expect(s.pointFromPin(.screen, cursor_pin.*) != null);
    s.assertIntegrity();
}
test "PageList resize (no reflow) more rows and less cols" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    try s.resize(.{ .cols = 5, .rows = 20, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 20), s.rows);
    try testing.expectEqual(@as(usize, 20), s.totalRows());
    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expectEqual(@as(usize, 5), cells.len);
    }
}
test "PageList resize more rows and cols doesn't fit in single std page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    const new_cols = 600;
    const new_rows = 600;
    const cap = try std_capacity.adjust(.{ .cols = new_cols });
    try testing.expect(cap.rows < new_rows);
    try s.resize(.{ .cols = new_cols, .rows = new_rows, .reflow = true });
    try testing.expectEqual(@as(usize, new_cols), s.cols);
    try testing.expectEqual(@as(usize, new_rows), s.rows);
    try testing.expectEqual(@as(usize, new_rows), s.totalRows());
}
test "PageList resize (no reflow) empty screen" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 5, .rows = 5, .max_size = 0 });
    defer s.deinit();
    try s.resize(.{ .cols = 10, .rows = 10, .reflow = false });
    try testing.expectEqual(@as(usize, 10), s.cols);
    try testing.expectEqual(@as(usize, 10), s.rows);
    try testing.expectEqual(@as(usize, 10), s.totalRows());
    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expectEqual(@as(usize, 10), cells.len);
    }
}
test "PageList resize (no reflow) more cols forces smaller cap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const cap = try std_capacity.adjust(.{ .cols = 100 });
    const cap2 = try std_capacity.adjust(.{ .cols = 500 });
    try testing.expectEqual(@as(size.CellCountInt, 500), cap2.cols);
    try testing.expect(cap2.rows < cap.rows);
    var s = try init(alloc, .{ .cols = cap.cols, .rows = cap.rows });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'A' } },
            };
        }
    }
    const rows = s.totalRows();
    try s.resize(.{ .cols = cap2.cols, .reflow = false });
    try testing.expectEqual(rows, s.totalRows());
    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expectEqual(@as(usize, cap2.cols), cells.len);
        try testing.expectEqual(@as(u21, 'A'), cells[0].content.codepoint.data);
    }
}
test "PageList resize (no reflow) more rows adds blank rows if cursor at bottom" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 5, .rows = 3 });
    defer s.deinit();
    try s.growRows(2);
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.totalRows()) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast(y) } },
        };
    }
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, pt);
    }
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = s.rows - 2 } }).?);
    defer s.untrackPin(p);
    const original_cursor = s.pointFromPin(.active, p.*).?.active;
    {
        const get = s.getCell(.{ .active = .{
            .x = original_cursor.x,
            .y = original_cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, 3), get.cell.content.codepoint.data);
    }
    try s.resizeWithoutReflow(.{
        .rows = 10,
        .reflow = false,
        .cursor = .{ .x = 0, .y = s.rows - 2 },
    });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 10), s.rows);
    try testing.expectEqual(original_cursor, s.pointFromPin(.active, p.*).?.active);
    try testing.expectEqual(@as(usize, 12), s.totalRows());
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, pt);
    }
    for (0..3) |y| {
        const get = s.getCell(.{ .active = .{ .y = @intCast(y) } }).?;
        const expected: u21 = @intCast(y + 2);
        try testing.expectEqual(expected, get.cell.content.codepoint.data);
    }
}
test "PageList resize reflow more cols no wrapped rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'A' } },
            };
        }
    }
    try s.resize(.{ .cols = 10, .reflow = true });
    try testing.expectEqual(@as(usize, 10), s.cols);
    try testing.expectEqual(@as(usize, 3), s.totalRows());
    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expectEqual(@as(usize, 10), cells.len);
        try testing.expectEqual(@as(u21, 'A'), cells[0].content.codepoint.data);
    }
}
test "PageList resize reflow more cols wrapped rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 4, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        if (y % 2 == 0) {
            const rac = page.getRowAndCell(0, y);
            rac.row.wrap = true;
        } else {
            const rac = page.getRowAndCell(0, y);
            rac.row.wrap_continuation = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'A' } },
            };
        }
    }
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 4), cells.len);
        try testing.expectEqual(@as(u21, 'A'), cells[0].content.codepoint.data);
        try testing.expectEqual(@as(u21, 'A'), cells[2].content.codepoint.data);
    }
}
test "PageList resize reflow invalidates viewport offset cache" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 4 });
    defer s.deinit();
    try s.growRows(20);
    const page = s.pages.last.?.page();
    for (0..s.rows) |y| {
        if (y % 2 == 0) {
            const rac = page.getRowAndCell(0, y);
            rac.row.wrap = true;
        } else {
            const rac = page.getRowAndCell(0, y);
            rac.row.wrap_continuation = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'A' } },
            };
        }
    }
    const pin_y = 10;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y,
        .len = s.rows,
    }, s.scrollbar());
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 5,
        .len = s.rows,
    }, s.scrollbar());
}
test "PageList resize reflow more cols creates multiple pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const cap = cap: {
        var current: size.CellCountInt = 100;
        while (true) : (current += 100) {
            const cap = try std_capacity.adjust(.{ .cols = current });
            if (cap.rows < 100) break :cap cap;
        }
        unreachable;
    };
    var s = try init(alloc, .{ .cols = cap.cols, .rows = cap.rows });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        for (0..s.rows) |y| {
            if (y % 2 == 0) {
                const rac = page.getRowAndCell(0, y);
                rac.row.wrap = true;
            } else {
                const rac = page.getRowAndCell(0, y);
                rac.row.wrap_continuation = true;
            }
            const rac = page.getRowAndCell(0, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'A' } },
            };
        }
    }
    const newcap = try cap.adjust(.{ .cols = cap.cols + 100 });
    try testing.expect(newcap.rows < cap.rows);
    try s.resize(.{ .cols = newcap.cols, .reflow = true });
    try testing.expectEqual(@as(usize, newcap.cols), s.cols);
    try testing.expectEqual(@as(usize, cap.rows), s.totalRows());
    {
        var count: usize = 0;
        var it = s.pages.first;
        while (it) |page| : (it = page.next) {
            count += 1;
            try testing.expectEqual(newcap.cols, page.capacity().cols);
            try testing.expectEqual(newcap.rows, page.capacity().rows);
        }
        try testing.expect(count > 1);
    }
}
test "PageList resize reflow more cols wrap across page boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 10, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());
    {
        const page = s.pages.first.?.page();
        page.pauseIntegrityChecks(true);
        for (page.size.rows..page.capacity.rows) |_| {
            _ = try s.grow();
        }
        page.pauseIntegrityChecks(false);
        try testing.expectEqual(@as(usize, 1), s.totalPages());
        try s.growRows(1);
        try testing.expectEqual(@as(usize, 2), s.totalPages());
    }
    {
        const page = s.pages.first.?.page();
        const y = page.size.rows - 1;
        {
            const rac = page.getRowAndCell(0, y);
            rac.row.wrap = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    {
        const page2 = s.pages.last.?.page();
        const y = 0;
        {
            const rac = page2.getRowAndCell(0, y);
            rac.row.wrap_continuation = true;
        }
        for (0..s.cols) |x| {
            const rac = page2.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    const end_rows = s.totalRows() - 1;
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, end_rows), s.totalRows());
    {
        const p = s.pin(.{ .active = .{ .y = 8 } }).?;
        const row = p.rowAndCell().row;
        try testing.expect(!row.wrap);
        try testing.expect(!row.wrap_continuation);
        const cells = p.cells(.all);
        try testing.expect(!cells[0].hasText());
        try testing.expect(!cells[1].hasText());
        try testing.expect(!cells[2].hasText());
        try testing.expect(!cells[3].hasText());
    }
    {
        const p = s.pin(.{ .active = .{ .y = 9 } }).?;
        const row = p.rowAndCell().row;
        try testing.expect(!row.wrap);
        try testing.expect(!row.wrap_continuation);
        const cells = p.cells(.all);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint.data);
        try testing.expectEqual(@as(u21, 1), cells[1].content.codepoint.data);
        try testing.expectEqual(@as(u21, 0), cells[2].content.codepoint.data);
        try testing.expectEqual(@as(u21, 1), cells[3].content.codepoint.data);
    }
}
test "PageList resize reflow more cols wrap across page boundary cursor in second page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 10, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());
    {
        const page = s.pages.first.?.page();
        page.pauseIntegrityChecks(true);
        for (page.size.rows..page.capacity.rows) |_| {
            _ = try s.grow();
        }
        page.pauseIntegrityChecks(false);
        try testing.expectEqual(@as(usize, 1), s.totalPages());
        try s.growRows(1);
        try testing.expectEqual(@as(usize, 2), s.totalPages());
    }
    {
        const page = s.pages.first.?.page();
        const y = page.size.rows - 1;
        {
            const rac = page.getRowAndCell(0, y);
            rac.row.wrap = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    {
        const page2 = s.pages.last.?.page();
        const y = 0;
        {
            const rac = page2.getRowAndCell(0, y);
            rac.row.wrap_continuation = true;
        }
        for (0..s.cols) |x| {
            const rac = page2.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 1, .y = 9 } }).?);
    defer s.untrackPin(p);
    try testing.expect(p.node == s.pages.last.?);
    const end_rows = s.totalRows() - 1;
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, end_rows), s.totalRows());
    try testing.expectEqual(point.Point{ .active = .{
        .x = 3,
        .y = 9,
    } }, s.pointFromPin(.active, p.*).?);
    {
        const p2 = s.pin(.{ .active = .{ .y = 9 } }).?;
        const row = p2.rowAndCell().row;
        try testing.expect(!row.wrap);
        const cells = p2.cells(.all);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint.data);
        try testing.expectEqual(@as(u21, 1), cells[1].content.codepoint.data);
        try testing.expectEqual(@as(u21, 0), cells[2].content.codepoint.data);
        try testing.expectEqual(@as(u21, 1), cells[3].content.codepoint.data);
    }
}
test "PageList resize reflow less cols wrap across page boundary cursor in second page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 5, .rows = 10 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());
    {
        const page = s.pages.first.?.page();
        page.pauseIntegrityChecks(true);
        for (page.size.rows..page.capacity.rows) |_| {
            _ = try s.grow();
        }
        page.pauseIntegrityChecks(false);
        try testing.expectEqual(@as(usize, 1), s.totalPages());
        try s.growRows(5);
        try testing.expectEqual(@as(usize, 2), s.totalPages());
    }
    {
        const page = s.pages.first.?.page();
        const y = page.size.rows - 1;
        {
            const rac = page.getRowAndCell(0, y);
            rac.row.wrap = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    {
        const page2 = s.pages.last.?.page();
        const y = 0;
        {
            const rac = page2.getRowAndCell(0, y);
            rac.row.wrap_continuation = true;
        }
        for (0..s.cols) |x| {
            const rac = page2.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 2, .y = 5 } }).?);
    defer s.untrackPin(p);
    try testing.expect(p.node == s.pages.last.?);
    try testing.expect(p.y == 0);
    try s.resize(.{
        .cols = 4,
        .reflow = true,
        .cursor = .{ .x = 2, .y = 5 },
    });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(point.Point{ .active = .{
        .x = 3,
        .y = 5,
    } }, s.pointFromPin(.active, p.*).?);
    {
        const p2 = s.pin(.{ .active = .{ .y = 3 } }).?;
        const row = p2.rowAndCell().row;
        try testing.expect(!row.wrap);
        try testing.expect(!row.wrap_continuation);
        const cells = p2.cells(.all);
        try testing.expect(!cells[0].hasText());
        try testing.expect(!cells[1].hasText());
        try testing.expect(!cells[2].hasText());
        try testing.expect(!cells[3].hasText());
    }
    {
        const p2 = s.pin(.{ .active = .{ .y = 4 } }).?;
        const row = p2.rowAndCell().row;
        try testing.expect(row.wrap);
        try testing.expect(!row.wrap_continuation);
        const cells = p2.cells(.all);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint.data);
        try testing.expectEqual(@as(u21, 1), cells[1].content.codepoint.data);
        try testing.expectEqual(@as(u21, 2), cells[2].content.codepoint.data);
        try testing.expectEqual(@as(u21, 3), cells[3].content.codepoint.data);
    }
    {
        const p2 = s.pin(.{ .active = .{ .y = 5 } }).?;
        const row = p2.rowAndCell().row;
        try testing.expect(row.wrap);
        try testing.expect(row.wrap_continuation);
        const cells = p2.cells(.all);
        try testing.expectEqual(@as(u21, 4), cells[0].content.codepoint.data);
        try testing.expectEqual(@as(u21, 0), cells[1].content.codepoint.data);
        try testing.expectEqual(@as(u21, 1), cells[2].content.codepoint.data);
        try testing.expectEqual(@as(u21, 2), cells[3].content.codepoint.data);
    }
    {
        const p2 = s.pin(.{ .active = .{ .y = 6 } }).?;
        const row = p2.rowAndCell().row;
        try testing.expect(!row.wrap);
        try testing.expect(row.wrap_continuation);
        const cells = p2.cells(.all);
        try testing.expectEqual(@as(u21, 3), cells[0].content.codepoint.data);
        try testing.expectEqual(@as(u21, 4), cells[1].content.codepoint.data);
    }
    {
        const p2 = s.pin(.{ .active = .{ .y = 7 } }).?;
        const row = p2.rowAndCell().row;
        try testing.expect(!row.wrap);
        try testing.expect(!row.wrap_continuation);
        const cells = p2.cells(.all);
        try testing.expect(!cells[0].hasText());
        try testing.expect(!cells[1].hasText());
        try testing.expect(!cells[2].hasText());
        try testing.expect(!cells[3].hasText());
    }
}
test "PageList resize reflow more cols cursor in wrapped row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 4, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        {
            const rac = page.getRowAndCell(0, 0);
            rac.row.wrap = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    {
        {
            const rac = page.getRowAndCell(0, 1);
            rac.row.wrap_continuation = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 1, .y = 1 } }).?);
    defer s.untrackPin(p);
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());
    try testing.expectEqual(point.Point{ .active = .{
        .x = 3,
        .y = 0,
    } }, s.pointFromPin(.active, p.*).?);
}
test "PageList resize reflow more cols cursor in not wrapped row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 4, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        {
            const rac = page.getRowAndCell(0, 0);
            rac.row.wrap = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    {
        {
            const rac = page.getRowAndCell(0, 1);
            rac.row.wrap_continuation = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 1, .y = 0 } }).?);
    defer s.untrackPin(p);
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());
    try testing.expectEqual(point.Point{ .active = .{
        .x = 1,
        .y = 0,
    } }, s.pointFromPin(.active, p.*).?);
}
test "PageList resize reflow more cols cursor in wrapped row that isn't unwrapped" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 4, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        {
            const rac = page.getRowAndCell(0, 0);
            rac.row.wrap = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    {
        {
            const rac = page.getRowAndCell(0, 1);
            rac.row.wrap = true;
            rac.row.wrap_continuation = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    {
        {
            const rac = page.getRowAndCell(0, 2);
            rac.row.wrap_continuation = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, 2);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 1, .y = 2 } }).?);
    defer s.untrackPin(p);
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());
    try testing.expectEqual(point.Point{ .active = .{
        .x = 1,
        .y = 1,
    } }, s.pointFromPin(.active, p.*).?);
}
test "PageList resize reflow more cols no reflow preserves semantic prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 4, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        const rac = page.getRowAndCell(0, 1);
        rac.row.semantic_prompt = .prompt;
    }
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        const rac = page.getRowAndCell(0, 1);
        try testing.expect(rac.row.semantic_prompt == .prompt);
    }
}
test "PageList resize reflow exceeds hyperlink memory forcing capacity increase" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 10, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());
    {
        const page = s.pages.first.?.page();
        page.pauseIntegrityChecks(true);
        for (page.size.rows..page.capacity.rows) |_| {
            _ = try s.grow();
        }
        page.pauseIntegrityChecks(false);
        try testing.expectEqual(@as(usize, 1), s.totalPages());
        try s.growRows(1);
        try testing.expectEqual(@as(usize, 2), s.totalPages());
        try std.testing.expect(s.pages.first.? != s.pages.last.?);
        try std.testing.expectEqual(s.pages.last.?, s.pages.first.?.next);
    }
    {
        const page = s.pages.first.?.page();
        const id = try page.insertHyperlink(.{
            .id = .{ .implicit = 0 },
            .uri = "a" ** (pagepkg.string_bytes_default - 1),
        });
        const rac = page.getRowAndCell(page.size.cols - 1, page.size.rows - 1);
        rac.row.wrap = true;
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'X' } },
        };
        try page.setHyperlink(rac.row, rac.cell, id);
        try std.testing.expectError(
            error.StringsOutOfMemory,
            page.insertHyperlink(.{
                .id = .{ .implicit = 1 },
                .uri = "AAAAAAAAAAAAAAAAAAAAAAAAAA",
            }),
        );
    }
    {
        const page = s.pages.last.?.page();
        const id = try page.insertHyperlink(.{
            .id = .{ .implicit = 1 },
            .uri = "a" ** (pagepkg.string_bytes_default - 1),
        });
        const rac = page.getRowAndCell(0, 0);
        rac.row.wrap_continuation = true;
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'X' } },
        };
        try page.setHyperlink(rac.row, rac.cell, id);
        try std.testing.expectError(
            error.StringsOutOfMemory,
            page.insertHyperlink(.{
                .id = .{ .implicit = 2 },
                .uri = "AAAAAAAAAAAAAAAAAAAAAAAAAA",
            }),
        );
    }
    try s.resize(.{ .cols = s.cols + 1, .reflow = true });
}
test "PageList resize reflow hyperlink dupe string alloc chunk rounding" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 10, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());
    {
        const page = s.pages.first.?.page();
        page.pauseIntegrityChecks(true);
        for (page.size.rows..page.capacity.rows) |_| {
            _ = try s.grow();
        }
        page.pauseIntegrityChecks(false);
        try testing.expectEqual(@as(usize, 1), s.totalPages());
        try s.growRows(1);
        try testing.expectEqual(@as(usize, 2), s.totalPages());
        try std.testing.expect(s.pages.first.? != s.pages.last.?);
        try std.testing.expectEqual(s.pages.last.?, s.pages.first.?.next);
    }
    const uri_a = "a" ** (pagepkg.string_bytes_default - 64);
    const uri_b = "b" ** 33;
    const id_b = "i" ** 31;
    {
        const page = s.pages.first.?.page();
        const id = try page.insertHyperlink(.{
            .id = .{ .implicit = 0 },
            .uri = uri_a,
        });
        const rac = page.getRowAndCell(page.size.cols - 1, page.size.rows - 1);
        rac.row.wrap = true;
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };
        try page.setHyperlink(rac.row, rac.cell, id);
        const buf = try page.string_alloc.alloc(u8, page.memory, 64);
        page.string_alloc.free(page.memory, buf);
        try std.testing.expectError(
            error.StringsOutOfMemory,
            page.insertHyperlink(.{
                .id = .{ .explicit = id_b },
                .uri = uri_b,
            }),
        );
    }
    {
        const page = s.pages.last.?.page();
        const id = try page.insertHyperlink(.{
            .id = .{ .explicit = id_b },
            .uri = uri_b,
        });
        const rac = page.getRowAndCell(0, 0);
        rac.row.wrap_continuation = true;
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'B' } },
        };
        try page.setHyperlink(rac.row, rac.cell, id);
    }
    try s.resize(.{ .cols = s.cols + 1, .reflow = true });
    var found: usize = 0;
    var node_it = s.pages.first;
    while (node_it) |node| : (node_it = node.next) {
        const page = node.page();
        for (0..page.size.rows) |y| {
            for (0..page.size.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                if (!rac.cell.hyperlink) continue;
                found += 1;
                const link_id = page.lookupHyperlink(rac.cell).?;
                const entry = page.hyperlink_set.get(page.memory, link_id);
                const uri = entry.uri.slice(page.memory);
                switch (entry.id) {
                    .implicit => try testing.expectEqualStrings(uri_a, uri),
                    .explicit => |slice| {
                        try testing.expectEqualStrings(uri_b, uri);
                        try testing.expectEqualStrings(
                            id_b,
                            slice.slice(page.memory),
                        );
                    },
                }
            }
        }
    }
    try testing.expectEqual(@as(usize, 2), found);
}
test "PageList resize reflow exceeds grapheme memory forcing capacity increase" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 4, .rows = 10, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());
    {
        const page = s.pages.first.?.page();
        page.pauseIntegrityChecks(true);
        for (page.size.rows..page.capacity.rows) |_| {
            _ = try s.grow();
        }
        page.pauseIntegrityChecks(false);
        try testing.expectEqual(@as(usize, 1), s.totalPages());
        try s.growRows(1);
        try testing.expectEqual(@as(usize, 2), s.totalPages());
        try std.testing.expect(s.pages.first.? != s.pages.last.?);
        try std.testing.expectEqual(s.pages.last.?, s.pages.first.?.next);
    }
    const suffixes: [pagepkg.grapheme_max_len]u21 = @splat('a');
    {
        const page = s.pages.first.?.page();
        const y = page.size.rows - 1;
        const row = page.getRow(y);
        row.wrap = true;
        for (0..page.size.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .init('X');
            try page.setGraphemes(rac.row, rac.cell, &suffixes);
        }
        try std.testing.expectEqual(
            page.grapheme_alloc.capacityBytes(),
            page.grapheme_alloc.usedBytes(page.memory),
        );
        try std.testing.expectError(
            error.OutOfMemory,
            page.grapheme_alloc.alloc(
                u21,
                page.memory,
                16,
            ),
        );
    }
    {
        const page = s.pages.last.?.page();
        const row = page.getRow(0);
        row.wrap_continuation = true;
        for (0..page.size.cols) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.cell.* = .init('X');
            try page.setGraphemes(rac.row, rac.cell, &suffixes);
        }
        try std.testing.expectError(
            error.OutOfMemory,
            page.grapheme_alloc.alloc(
                u21,
                page.memory,
                16,
            ),
        );
    }
    try s.resize(.{ .cols = s.cols + 1, .reflow = true });
}
test "PageList resize reflow exceeds style memory forcing capacity increase" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = pagepkg.std_capacity.styles - 1, .rows = 10, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());
    {
        const page = s.pages.first.?.page();
        page.pauseIntegrityChecks(true);
        for (page.size.rows..page.capacity.rows) |_| {
            _ = try s.grow();
        }
        page.pauseIntegrityChecks(false);
        try testing.expectEqual(@as(usize, 1), s.totalPages());
        try s.growRows(1);
        try testing.expectEqual(@as(usize, 2), s.totalPages());
        try std.testing.expect(s.pages.first.? != s.pages.last.?);
        try std.testing.expectEqual(s.pages.last.?, s.pages.first.?.next);
    }
    {
        const page = s.pages.first.?.page();
        for (0..s.cols) |x| {
            const id = page.styles.add(
                page.memory,
                .{
                    .bg_color = .{ .rgb = .{
                        .r = @truncate(x),
                        .g = @truncate(x >> 8),
                        .b = @truncate(x >> 16),
                    } },
                },
            ) catch break;
            const rac = page.getRowAndCell(x, page.size.rows - 1);
            rac.row.wrap = true;
            rac.row.styled = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'X' } },
                .style_id = id,
            };
        }
    }
    {
        const page = s.pages.last.?.page();
        for (0..s.cols) |x| {
            const id = page.styles.add(
                page.memory,
                .{
                    .fg_color = .{ .rgb = .{
                        .r = @truncate(x),
                        .g = @truncate(x >> 8),
                        .b = @truncate(x >> 16),
                    } },
                },
            ) catch break;
            const rac = page.getRowAndCell(x, 0);
            rac.row.wrap_continuation = true;
            rac.row.styled = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'X' } },
                .style_id = id,
            };
        }
    }
    try s.resize(.{ .cols = s.cols * 2, .reflow = true });
}
test "PageList resize reflow more cols unwrap wide spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        {
            const rac = page.getRowAndCell(0, 0);
            rac.row.wrap = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
        {
            const rac = page.getRowAndCell(1, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_head,
            };
        }
        {
            const rac = page.getRowAndCell(0, 1);
            rac.row.wrap_continuation = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '😀' } },
                .wide = .wide,
            };
        }
        {
            const rac = page.getRowAndCell(1, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_tail,
            };
        }
    }
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
            try testing.expect(!rac.row.wrap);
        }
        {
            const rac = page.getRowAndCell(1, 0);
            try testing.expectEqual(@as(u21, '😀'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(2, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
        }
    }
}
test "PageList resize reflow more cols unwrap wide spacer head across two rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 3, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        {
            const rac = page.getRowAndCell(0, 0);
            rac.row.wrap = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
        {
            const rac = page.getRowAndCell(1, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
        {
            const rac = page.getRowAndCell(0, 1);
            rac.row.wrap_continuation = true;
            rac.row.wrap = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
        {
            const rac = page.getRowAndCell(1, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_head,
            };
        }
        {
            const rac = page.getRowAndCell(0, 2);
            rac.row.wrap_continuation = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '😀' } },
                .wide = .wide,
            };
        }
        {
            const rac = page.getRowAndCell(1, 2);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_tail,
            };
        }
    }
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 3), s.totalRows());
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
            try testing.expect(rac.row.wrap);
        }
        {
            const rac = page.getRowAndCell(1, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(2, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(3, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_head, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(0, 1);
            try testing.expectEqual(@as(u21, '😀'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(1, 1);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
        }
    }
}
test "PageList resize reflow more cols unwrap still requires wide spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        {
            const rac = page.getRowAndCell(0, 0);
            rac.row.wrap = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
        {
            const rac = page.getRowAndCell(1, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
        {
            const rac = page.getRowAndCell(0, 1);
            rac.row.wrap_continuation = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '😀' } },
                .wide = .wide,
            };
        }
        {
            const rac = page.getRowAndCell(1, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_tail,
            };
        }
    }
    try s.resize(.{ .cols = 3, .reflow = true });
    try testing.expectEqual(@as(usize, 3), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
            try testing.expect(rac.row.wrap);
        }
        {
            const rac = page.getRowAndCell(1, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(2, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_head, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(0, 1);
            try testing.expectEqual(@as(u21, '😀'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(1, 1);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
        }
    }
}
test "PageList resize reflow less cols no reflow preserves semantic prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 4, .rows = 4, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        {
            const rac = page.getRowAndCell(0, 1);
            rac.row.semantic_prompt = .prompt;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());
    {
        try testing.expect(s.pages.first == s.pages.last);
        {
            const p = s.pin(.{ .active = .{ .y = 1 } }).?;
            const rac = p.rowAndCell();
            try testing.expect(rac.row.wrap);
            try testing.expect(rac.row.semantic_prompt == .prompt);
        }
        {
            const p = s.pin(.{ .active = .{ .y = 2 } }).?;
            const rac = p.rowAndCell();
            try testing.expect(rac.row.semantic_prompt == .prompt);
        }
    }
}
test "PageList resize reflow less cols no reflow preserves semantic prompt on first line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 4, .rows = 4, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        const rac = page.getRowAndCell(0, 0);
        rac.row.semantic_prompt = .prompt;
    }
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        const rac = page.getRowAndCell(0, 0);
        try testing.expect(rac.row.semantic_prompt == .prompt);
    }
}
test "PageList resize reflow less cols wrap preserves semantic prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 4, .rows = 4, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        const rac = page.getRowAndCell(0, 0);
        rac.row.semantic_prompt = .prompt;
    }
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        const rac = page.getRowAndCell(0, 0);
        try testing.expect(rac.row.semantic_prompt == .prompt);
    }
}
test "PageList resize reflow less cols no wrapped rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        const end = 4;
        assert(end < s.cols);
        for (0..4) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    try s.resize(.{ .cols = 5, .reflow = true });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 3), s.totalRows());
    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        for (0..4) |x| {
            var offset_copy = offset;
            offset_copy.x = @intCast(x);
            const rac = offset_copy.rowAndCell();
            const cells = offset.node.page().getCells(rac.row);
            try testing.expectEqual(@as(usize, 5), cells.len);
            try testing.expectEqual(@as(u21, @intCast(x)), cells[x].content.codepoint.data);
        }
    }
}
test "PageList resize reflow less cols wrapped rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 4, .rows = 2 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, pt);
    }
    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint.data);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 2), cells[0].content.codepoint.data);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint.data);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 2), cells[0].content.codepoint.data);
    }
}
test "PageList resize reflow less cols wrapped rows with graphemes" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 4, .rows = 2 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = @intCast(x) } },
                };
            }
            const rac = page.getRowAndCell(2, y);
            try page.appendGrapheme(rac.row, rac.cell, 'A');
        }
    }
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, pt);
    }
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint.data);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expect(rac.row.grapheme);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 2), cells[0].content.codepoint.data);
        const cps = page.lookupGrapheme(rac.cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
        try testing.expectEqual(@as(u21, 'A'), cps[0]);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint.data);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expect(rac.row.grapheme);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 2), cells[0].content.codepoint.data);
        const cps = page.lookupGrapheme(rac.cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
        try testing.expectEqual(@as(u21, 'A'), cps[0]);
    }
}
test "PageList resize reflow less cols cursor in wrapped row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 4, .rows = 2 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 2, .y = 1 } }).?);
    defer s.untrackPin(p);
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = 1,
    } }, s.pointFromPin(.active, p.*).?);
}
test "PageList resize reflow less cols wraps spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 4, .rows = 3, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        {
            const rac = page.getRowAndCell(0, 0);
            rac.row.wrap = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
        {
            const rac = page.getRowAndCell(1, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
        {
            const rac = page.getRowAndCell(2, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
        {
            const rac = page.getRowAndCell(3, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_head,
            };
        }
        {
            const rac = page.getRowAndCell(0, 1);
            rac.row.wrap_continuation = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '😀' } },
                .wide = .wide,
            };
        }
        {
            const rac = page.getRowAndCell(1, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_tail,
            };
        }
    }
    try s.resize(.{ .cols = 3, .reflow = true });
    try testing.expectEqual(@as(usize, 3), s.cols);
    try testing.expectEqual(@as(usize, 3), s.totalRows());
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
            try testing.expect(rac.row.wrap);
        }
        {
            const rac = page.getRowAndCell(1, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(2, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(0, 1);
            try testing.expectEqual(@as(u21, '😀'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(1, 1);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
        }
    }
}
test "PageList resize reflow less cols cursor goes to scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 4, .rows = 2 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 2, .y = 0 } }).?);
    defer s.untrackPin(p);
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());
    try testing.expect(s.pointFromPin(.active, p.*) == null);
}
test "PageList resize reflow less cols cursor in unchanged row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 4, .rows = 2 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        for (0..2) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 1, .y = 0 } }).?);
    defer s.untrackPin(p);
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());
    try testing.expectEqual(point.Point{ .active = .{
        .x = 1,
        .y = 0,
    } }, s.pointFromPin(.active, p.*).?);
}
test "PageList resize reflow less cols cursor in blank cell" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 6, .rows = 2 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        for (0..2) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 2, .y = 0 } }).?);
    defer s.untrackPin(p);
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());
    try testing.expectEqual(point.Point{ .active = .{
        .x = 2,
        .y = 0,
    } }, s.pointFromPin(.active, p.*).?);
}
test "PageList resize reflow less cols cursor in final blank cell" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 6, .rows = 2 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        for (0..2) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 3, .y = 0 } }).?);
    defer s.untrackPin(p);
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());
    try testing.expectEqual(point.Point{ .active = .{
        .x = 3,
        .y = 0,
    } }, s.pointFromPin(.active, p.*).?);
}
test "PageList resize reflow pin in blank cells after line break" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const cases = [_]struct {
        first: []const u8,
        wrap: bool,
        pin_x: size.CellCountInt,
        cols: size.CellCountInt,
        expected: point.Coordinate,
    }{
        .{ .first = "abc", .wrap = false, .pin_x = 5, .cols = 8, .expected = .{ .x = 5, .y = 1 } },
        .{ .first = "abcdef", .wrap = true, .pin_x = 3, .cols = 8, .expected = .{ .x = 7, .y = 0 } },
        .{ .first = "abcdef", .wrap = true, .pin_x = 2, .cols = 3, .expected = .{ .x = 2, .y = 2 } },
    };
    for (cases) |case| {
        var s = try init(alloc, .{ .cols = 6, .rows = 4 });
        defer s.deinit();
        const page = s.pages.first.?.page();
        page.getRow(0).wrap = case.wrap;
        for (case.first, 0..) |cp, x| {
            page.getRowAndCell(x, 0).cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = cp } },
            };
        }
        const rac = page.getRowAndCell(0, 1);
        rac.row.wrap_continuation = case.wrap;
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'g' } },
        };
        const p = try s.trackPin(s.pin(.{ .active = .{
            .x = case.pin_x,
            .y = 1,
        } }).?);
        defer s.untrackPin(p);
        try s.resize(.{ .cols = case.cols, .reflow = true });
        try testing.expectEqual(
            point.Point{ .active = case.expected },
            s.pointFromPin(.active, p.*).?,
        );
        try testing.expect(p.rowAndCell().cell.isEmpty());
    }
}
test "PageList resize reflow less cols cursor in wrapped blank cell" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 6, .rows = 2 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        for (0..2) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 5, .y = 0 } }).?);
    defer s.untrackPin(p);
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());
    try testing.expectEqual(point.Point{ .active = .{
        .x = 3,
        .y = 0,
    } }, s.pointFromPin(.active, p.*).?);
}
test "PageList resize reflow less cols blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 4, .rows = 3, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..1) |y| {
        for (0..4) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 3), s.totalRows());
    var it = s.rowIterator(.right_down, .{ .active = .{} }, null);
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint.data);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 2), cells[0].content.codepoint.data);
    }
}
test "PageList resize reflow less cols blank lines between" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 4, .rows = 3, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        for (0..4) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    {
        for (0..4) |x| {
            const rac = page.getRowAndCell(x, 2);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 5), s.totalRows());
    var it = s.rowIterator(.right_down, .{ .active = .{} }, null);
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        try testing.expect(!rac.row.wrap);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint.data);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 2), cells[0].content.codepoint.data);
    }
}
test "PageList resize reflow less cols blank lines between no scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_size = 0 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'A' } },
        };
    }
    {
        const rac = page.getRowAndCell(0, 2);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'C' } },
        };
    }
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 3), s.totalRows());
    var it = s.rowIterator(.right_down, .{ .active = .{} }, null);
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 'A'), cells[0].content.codepoint.data);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint.data);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 'C'), cells[0].content.codepoint.data);
    }
}
test "PageList resize reflow less cols cursor not on last line preserves location" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 5, .rows = 5, .max_size = 1 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        for (0..2) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    try s.growRows(5);
    try testing.expectEqual(@as(usize, 10), s.totalRows());
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 0 } }).?);
    defer s.untrackPin(p);
    try s.resize(.{
        .cols = 4,
        .reflow = true,
        .cursor = .{ .x = 1, .y = 1 },
    });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 10), s.totalRows());
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = 0,
    } }, s.pointFromPin(.active, p.*).?);
}
test "PageList resize reflow less cols no scrollback pull blank active" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 5, .rows = 5, .max_size = 1 });
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        for (0..2) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
            };
        }
    }
    try s.growRows(5);
    try testing.expectEqual(@as(usize, 10), s.totalRows());
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 0 } }).?);
    defer s.untrackPin(p);
    try s.resize(.{
        .cols = 4,
        .reflow = true,
        .pull_scrollback = false,
    });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 10), s.totalRows());
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = 0,
    } }, s.pointFromPin(.active, p.*).?);
}
test "PageList resize reflow less cols copy style" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 4, .rows = 2, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        const style: stylepkg.Style = .{ .flags = .{ .bold = true } };
        const style_id = try page.styles.add(page.memory, style);
        for (0..s.cols - 1) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = @intCast(x) } },
                .style_id = style_id,
            };
            page.styles.use(page.memory, style_id);
        }
        page.styles.release(page.memory, style_id);
    }
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());
    var it = s.rowIterator(.right_down, .{ .active = .{} }, null);
    while (it.next()) |offset| {
        for (0..s.cols - 1) |x| {
            var offset_copy = offset;
            offset_copy.x = @intCast(x);
            const rac = offset_copy.rowAndCell();
            const style_id = rac.cell.style_id;
            try testing.expect(style_id != 0);
            const style = offset.node.page().styles.get(
                offset.node.page().memory,
                style_id,
            );
            try testing.expect(style.flags.bold);
            const row = rac.row;
            try testing.expect(row.styled);
        }
    }
}
test "PageList resize reflow less cols to eliminate a wide char" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 1, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        {
            const rac = page.getRowAndCell(0, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '😀' } },
                .wide = .wide,
            };
        }
        {
            const rac = page.getRowAndCell(1, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_tail,
            };
        }
    }
    try s.resize(.{ .cols = 1, .reflow = true });
    try testing.expectEqual(@as(usize, 1), s.cols);
    try testing.expectEqual(@as(usize, 1), s.totalRows());
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
        }
    }
}
test "PageList resize reflow less cols to wrap a wide char" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 3, .rows = 1, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        {
            const rac = page.getRowAndCell(0, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
        {
            const rac = page.getRowAndCell(1, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = '😀' } },
                .wide = .wide,
            };
        }
        {
            const rac = page.getRowAndCell(2, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_tail,
            };
        }
    }
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
            try testing.expect(rac.row.wrap);
        }
        {
            const rac = page.getRowAndCell(1, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_head, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(0, 1);
            try testing.expectEqual(@as(u21, '😀'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(1, 1);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
        }
    }
}
test "PageList resize reflow less cols wide char bulk run" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 8, .rows = 1, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        for (0..4) |i| {
            {
                const rac = page.getRowAndCell(i * 2, 0);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = @intCast(0x4E00 + i) } },
                    .wide = .wide,
                };
            }
            {
                const rac = page.getRowAndCell(i * 2 + 1, 0);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = 0 } },
                    .wide = .spacer_tail,
                };
            }
        }
    }
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        for (0..4) |i| {
            const y = i / 2;
            const x = (i % 2) * 2;
            {
                const rac = page.getRowAndCell(x, y);
                try testing.expectEqual(
                    @as(u21, @intCast(0x4E00 + i)),
                    rac.cell.content.codepoint.data,
                );
                try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);
            }
            {
                const rac = page.getRowAndCell(x + 1, y);
                try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
                try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
            }
        }
        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expect(rac.row.wrap);
            try testing.expect(!rac.row.wrap_continuation);
        }
        {
            const rac = page.getRowAndCell(0, 1);
            try testing.expect(!rac.row.wrap);
            try testing.expect(rac.row.wrap_continuation);
        }
    }
}
test "PageList resize reflow less cols wide char bulk run odd cols spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 8, .rows = 1, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        for (0..4) |i| {
            {
                const rac = page.getRowAndCell(i * 2, 0);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = @intCast(0x4E00 + i) } },
                    .wide = .wide,
                };
            }
            {
                const rac = page.getRowAndCell(i * 2 + 1, 0);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = 0 } },
                    .wide = .spacer_tail,
                };
            }
        }
    }
    try s.resize(.{ .cols = 5, .reflow = true });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        for (0..4) |i| {
            const y = i / 2;
            const x = (i % 2) * 2;
            {
                const rac = page.getRowAndCell(x, y);
                try testing.expectEqual(
                    @as(u21, @intCast(0x4E00 + i)),
                    rac.cell.content.codepoint.data,
                );
                try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);
            }
            {
                const rac = page.getRowAndCell(x + 1, y);
                try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
                try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
            }
        }
        {
            const rac = page.getRowAndCell(4, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_head, rac.cell.wide);
            try testing.expect(rac.row.wrap);
        }
        {
            const rac = page.getRowAndCell(4, 1);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
            try testing.expect(rac.row.wrap_continuation);
        }
    }
}
test "PageList resize reflow less cols wide char bulk run mixed narrow round trip" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Shape = struct { cp: u21, wide: pagepkg.Cell.Wide };
    const shape: []const Shape = &.{
        .{ .cp = 0x4E00, .wide = .wide },
        .{ .cp = 0, .wide = .spacer_tail },
        .{ .cp = 'x', .wide = .narrow },
        .{ .cp = 0x4E01, .wide = .wide },
        .{ .cp = 0, .wide = .spacer_tail },
        .{ .cp = 'y', .wide = .narrow },
        .{ .cp = 0x4E02, .wide = .wide },
        .{ .cp = 0, .wide = .spacer_tail },
        .{ .cp = 'z', .wide = .narrow },
    };
    var s = try init(alloc, .{ .cols = 9, .rows = 1, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        for (shape, 0..) |c, x| {
            const rac = page.getRowAndCell(x, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = c.cp } },
                .wide = c.wide,
            };
        }
    }
    try s.resize(.{ .cols = 6, .reflow = true });
    try testing.expectEqual(@as(usize, 6), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        for (shape[0..6], 0..) |c, x| {
            const rac = page.getRowAndCell(x, 0);
            try testing.expectEqual(c.cp, rac.cell.content.codepoint.data);
            try testing.expectEqual(c.wide, rac.cell.wide);
        }
        for (shape[6..], 0..) |c, x| {
            const rac = page.getRowAndCell(x, 1);
            try testing.expectEqual(c.cp, rac.cell.content.codepoint.data);
            try testing.expectEqual(c.wide, rac.cell.wide);
        }
        try testing.expect(page.getRowAndCell(0, 0).row.wrap);
        try testing.expect(page.getRowAndCell(0, 1).row.wrap_continuation);
    }
    try s.resize(.{ .cols = 9, .reflow = true });
    try testing.expectEqual(@as(usize, 9), s.cols);
    try testing.expectEqual(@as(usize, 1), s.totalRows());
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        for (shape, 0..) |c, x| {
            const rac = page.getRowAndCell(x, 0);
            try testing.expectEqual(c.cp, rac.cell.content.codepoint.data);
            try testing.expectEqual(c.wide, rac.cell.wide);
        }
        try testing.expect(!page.getRowAndCell(0, 0).row.wrap);
    }
}
test "PageList resize reflow less cols wide char bulk run styled" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 8, .rows = 1, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        const style: stylepkg.Style = .{ .flags = .{ .bold = true } };
        const style_id = try page.styles.add(page.memory, style);
        for (0..4) |i| {
            {
                const rac = page.getRowAndCell(i * 2, 0);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = @intCast(0x4E00 + i) } },
                    .wide = .wide,
                    .style_id = style_id,
                };
                page.styles.use(page.memory, style_id);
            }
            {
                const rac = page.getRowAndCell(i * 2 + 1, 0);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = 0 } },
                    .wide = .spacer_tail,
                    .style_id = style_id,
                };
                page.styles.use(page.memory, style_id);
            }
        }
        page.styles.release(page.memory, style_id);
    }
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        for (0..2) |y| {
            for (0..4) |x| {
                const rac = page.getRowAndCell(x, y);
                const style_id = rac.cell.style_id;
                try testing.expect(style_id != 0);
                const style = page.styles.get(page.memory, style_id);
                try testing.expect(style.flags.bold);
                try testing.expect(rac.row.styled);
                try testing.expectEqual(
                    if (x % 2 == 0) pagepkg.Cell.Wide.wide else pagepkg.Cell.Wide.spacer_tail,
                    rac.cell.wide,
                );
            }
        }
    }
}
test "PageList resize reflow less cols wide char bulk run degenerate spacer tail style" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 4, .rows = 1, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        const style: stylepkg.Style = .{ .flags = .{ .bold = true } };
        const style_id = try page.styles.add(page.memory, style);
        {
            const rac = page.getRowAndCell(0, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0x4E00 } },
                .wide = .wide,
                .style_id = style_id,
            };
        }
        {
            const rac = page.getRowAndCell(1, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_tail,
            };
        }
        {
            const rac = page.getRowAndCell(2, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'x' } },
            };
        }
    }
    try s.resize(.{ .cols = 3, .reflow = true });
    try testing.expectEqual(@as(usize, 3), s.cols);
    try testing.expectEqual(@as(usize, 1), s.totalRows());
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 0x4E00), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);
            try testing.expect(rac.cell.style_id != 0);
            const style = page.styles.get(page.memory, rac.cell.style_id);
            try testing.expect(style.flags.bold);
        }
        {
            const rac = page.getRowAndCell(1, 0);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
            try testing.expectEqual(stylepkg.default_id, rac.cell.style_id);
        }
        {
            const rac = page.getRowAndCell(2, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
        }
    }
}
test "PageList resize reflow less cols to wrap a multi-codepoint grapheme with a spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 4, .rows = 2, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        {
            const rac = page.getRowAndCell(0, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0x1F468 } },
                .wide = .wide,
            };
            try page.setGraphemes(rac.row, rac.cell, &.{
                0x200D, 0x1F468,
                0x200D, 0x1F466,
                0x200D, 0x1F466,
            });
        }
        {
            const rac = page.getRowAndCell(1, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_tail,
            };
        }
        {
            const rac = page.getRowAndCell(2, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0x1F468 } },
                .wide = .wide,
            };
            try page.setGraphemes(rac.row, rac.cell, &.{
                0x200D, 0x1F468,
                0x200D, 0x1F466,
                0x200D, 0x1F466,
            });
        }
        {
            const rac = page.getRowAndCell(3, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 0 } },
                .wide = .spacer_tail,
            };
        }
    }
    try s.resize(.{ .cols = 3, .reflow = true });
    try testing.expectEqual(@as(usize, 3), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 0x1F468), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);
            const cps = page.lookupGrapheme(rac.cell).?;
            try testing.expectEqual(@as(usize, 6), cps.len);
            try testing.expectEqual(@as(u21, 0x200D), cps[0]);
            try testing.expectEqual(@as(u21, 0x1F468), cps[1]);
            try testing.expectEqual(@as(u21, 0x200D), cps[2]);
            try testing.expectEqual(@as(u21, 0x1F466), cps[3]);
            try testing.expectEqual(@as(u21, 0x200D), cps[4]);
            try testing.expectEqual(@as(u21, 0x1F466), cps[5]);
            try testing.expect(rac.row.wrap);
        }
        {
            const rac = page.getRowAndCell(1, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(2, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_head, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 0x1F468), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);
            const cps = page.lookupGrapheme(rac.cell).?;
            try testing.expectEqual(@as(usize, 6), cps.len);
            try testing.expectEqual(@as(u21, 0x200D), cps[0]);
            try testing.expectEqual(@as(u21, 0x1F468), cps[1]);
            try testing.expectEqual(@as(u21, 0x200D), cps[2]);
            try testing.expectEqual(@as(u21, 0x1F466), cps[3]);
            try testing.expectEqual(@as(u21, 0x200D), cps[4]);
            try testing.expectEqual(@as(u21, 0x1F466), cps[5]);
        }
        {
            const rac = page.getRowAndCell(1, 1);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint.data);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
        }
    }
}
test "PageList resize reflow less cols copy kitty placeholder" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 4, .rows = 2, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        for (0..s.cols - 1) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.row.kitty_virtual_placeholder = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = kitty.graphics.unicode.placeholder } },
            };
        }
    }
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());
    var it = s.rowIterator(.right_down, .{ .active = .{} }, null);
    while (it.next()) |offset| {
        for (0..s.cols - 1) |x| {
            var offset_copy = offset;
            offset_copy.x = @intCast(x);
            const rac = offset_copy.rowAndCell();
            const row = rac.row;
            try testing.expect(row.kitty_virtual_placeholder);
        }
    }
}
test "PageList resize reflow more cols clears kitty placeholder" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 4, .rows = 2, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        for (0..s.cols - 1) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.row.kitty_virtual_placeholder = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = kitty.graphics.unicode.placeholder } },
            };
        }
    }
    try s.resize(.{ .cols = 2, .reflow = true });
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());
    var it = s.rowIterator(.right_down, .{ .active = .{} }, null);
    {
        const row = it.next().?;
        const rac = row.rowAndCell();
        try testing.expect(rac.row.kitty_virtual_placeholder);
    }
    {
        const row = it.next().?;
        const rac = row.rowAndCell();
        try testing.expect(!rac.row.kitty_virtual_placeholder);
    }
    try testing.expect(it.next() == null);
}
test "PageList resize reflow wrap moves kitty placeholder" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 4, .rows = 2, .max_size = 0 });
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        for (2..s.cols - 1) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.row.kitty_virtual_placeholder = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = kitty.graphics.unicode.placeholder } },
            };
        }
    }
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());
    var it = s.rowIterator(.right_down, .{ .active = .{} }, null);
    {
        const row = it.next().?;
        const rac = row.rowAndCell();
        try testing.expect(!rac.row.kitty_virtual_placeholder);
    }
    {
        const row = it.next().?;
        const rac = row.rowAndCell();
        try testing.expect(rac.row.kitty_virtual_placeholder);
    }
    try testing.expect(it.next() == null);
}
test "PageList reset" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    s.reset();
    try testing.expect(s.viewport == .active);
    try testing.expect(s.pages.first != null);
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
    try testing.expectEqual(Pin{
        .node = s.pages.first.?,
        .y = 0,
        .x = 0,
    }, s.getTopLeft(.active));
}
test "PageList reset invalidates stale untracked refs even if node memory is reused" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    var stale_nodes: [page_preheat * 4]*List.Node = undefined;
    var stale_serials: [stale_nodes.len]u64 = undefined;
    var stale_len: usize = 0;
    var reused: ?struct { *List.Node, u64 } = null;
    while (stale_len < stale_nodes.len and reused == null) {
        const old_node = s.pages.first.?;
        const old_serial = old_node.serial;
        try testing.expect(old_serial >= s.page_serial_epoch);
        try testing.expect(old_serial < s.page_serial);
        stale_nodes[stale_len] = old_node;
        stale_serials[stale_len] = old_serial;
        stale_len += 1;
        s.reset();
        const new_node = s.pages.first.?;
        for (stale_nodes[0..stale_len], stale_serials[0..stale_len]) |node, serial| {
            if (node == new_node) {
                reused = .{ node, serial };
                break;
            }
        }
    }
    try testing.expect(reused != null);
    const old_node, const old_serial = reused.?;
    const new_node = s.pages.first.?;
    const new_serial = new_node.serial;
    try testing.expectEqual(old_node, new_node);
    try testing.expect(old_serial < s.page_serial_epoch);
    try testing.expect(!s.nodeIsValid(old_node, old_serial));
    try testing.expect(s.nodeIsValid(new_node, new_serial));
    try testing.expect(new_serial >= s.page_serial_epoch);
    try testing.expect(new_serial < s.page_serial);
}
test "PageList reset across two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const rows = 100;
    const cap = cap: {
        var cap = try std_capacity.adjust(.{ .cols = 50 });
        while (cap.rows >= rows) cap = try std_capacity.adjust(.{
            .cols = cap.cols + 50,
        });
        break :cap cap;
    };
    var s = try init(alloc, .{ .cols = cap.cols, .rows = rows });
    defer s.deinit();
    s.reset();
    try testing.expect(s.viewport == .active);
    try testing.expect(s.pages.first != null);
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
}
test "PageList reset moves tracked pins and marks them as garbage" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const p = try s.trackPin(s.pin(.{ .active = .{
        .x = 42,
        .y = 12,
    } }).?);
    defer s.untrackPin(p);
    s.reset();
    try testing.expect(p.garbage);
    try testing.expect(!s.viewport_pin.garbage);
}
test "PageList clears history" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    try s.growRows(30);
    s.reset();
    try testing.expect(s.viewport == .active);
    try testing.expect(s.pages.first != null);
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
    try testing.expectEqual(Pin{
        .node = s.pages.first.?,
        .y = 0,
        .x = 0,
    }, s.getTopLeft(.active));
}
test "PageList resize reflow grapheme map capacity exceeded" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 4, .rows = 10, .max_size = 0 });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());
    const grapheme_capacity = s.pages.first.?.page().graphemeCapacity();
    const graphemes_per_page = grapheme_capacity / 2 + grapheme_capacity / 4;
    {
        const page = s.pages.first.?.page();
        page.pauseIntegrityChecks(true);
        for (page.size.rows..page.capacity.rows) |_| {
            _ = try s.grow();
        }
        page.pauseIntegrityChecks(false);
        try testing.expectEqual(@as(usize, 1), s.totalPages());
        try s.growRows(graphemes_per_page);
        try testing.expectEqual(@as(usize, 2), s.totalPages());
        try testing.expect(s.pages.first.? != s.pages.last.?);
        try testing.expectEqual(s.pages.last.?, s.pages.first.?.next);
    }
    {
        const page = s.pages.first.?.page();
        const start_row = page.size.rows - graphemes_per_page;
        for (0..graphemes_per_page) |i| {
            const y = start_row + i;
            const rac = page.getRowAndCell(0, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'A' } },
            };
            try page.appendGrapheme(rac.row, rac.cell, @as(u21, @intCast(0x0301)));
        }
    }
    {
        const page = s.pages.last.?.page();
        const count = @min(graphemes_per_page, page.size.rows);
        for (0..count) |y| {
            const rac = page.getRowAndCell(0, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = .{ .data = 'B' } },
            };
            try page.appendGrapheme(rac.row, rac.cell, @as(u21, @intCast(0x0302)));
        }
    }
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
}
test "PageList resize grow cols with unwrap fixes viewport pin" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 2, .rows = 10 });
    defer s.deinit();
    try s.growRows(30);
    try testing.expectEqual(@as(usize, 40), s.totalRows());
    var it = s.pageIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |chunk| {
        const page = chunk.node.page();
        for (chunk.start..chunk.end) |y| {
            const rac = page.getRowAndCell(0, y);
            if (y % 2 == 0) {
                rac.row.wrap = true;
            } else {
                rac.row.wrap_continuation = true;
            }
            for (0..s.cols) |x| {
                page.getRowAndCell(x, y).cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = 'A' } },
                };
            }
        }
    }
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = 28 } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expect(s.getBottomRight(.viewport) != null);
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expect(s.totalRows() < 40);
    const br_after = s.getBottomRight(.viewport);
    try testing.expect(br_after != null);
}
test "PageList grow reuses non-standard page without leak" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24, .max_size = 3 * std_size });
    defer s.deinit();
    while (s.pages.first.?.page().memory.len <= std_size) {
        _ = try s.increaseCapacity(s.pages.first.?, .grapheme_bytes);
    }
    try testing.expect(s.pages.first.?.page().memory.len > std_size);
    const first_page = s.pages.first.?;
    while (first_page.rows() < first_page.capacity().rows) {
        _ = try s.grow();
    }
    _ = try s.grow();
    try testing.expect(s.pages.first != s.pages.last);
    while (s.page_size + PagePool.item_size <= s.limits.max(.bytes) or
        s.pages.last.?.rows() < s.pages.last.?.capacity().rows)
    {
        _ = try s.grow();
    }
    try testing.expect(s.pages.first.?.page().memory.len > std_size);
    try testing.expect(s.totalRows() >= s.rows);
    try testing.expect(s.pages.last.?.page().size.rows == s.pages.last.?.capacity().rows);
    const first_page_ptr = s.pages.first.?;
    const first_page_mem_ptr = s.pages.first.?.page().memory.ptr;
    const tracked_pin = try s.trackPin(.{ .node = first_page_ptr, .x = 0, .y = 0 });
    defer s.untrackPin(tracked_pin);
    _ = try s.grow();
    try testing.expect(s.pages.first.? != first_page_ptr);
    try testing.expect(s.pages.last.?.page().memory.ptr != first_page_mem_ptr);
    try testing.expectEqual(s.pages.first.?, tracked_pin.node);
    try testing.expectEqual(0, tracked_pin.x);
    try testing.expectEqual(0, tracked_pin.y);
    try testing.expect(tracked_pin.garbage);
}
test "PageList grow non-standard page prune protection" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const rows_count = 600;
    var s = try init(alloc, .{ .cols = 80, .rows = rows_count, .max_size = std_size });
    defer s.deinit();
    while (s.pages.first.?.page().memory.len <= std_size) {
        _ = try s.increaseCapacity(
            s.pages.first.?,
            .grapheme_bytes,
        );
    }
    try testing.expect(s.pages.first.?.page().memory.len > std_size);
    const first_page_node = s.pages.first.?;
    const first_page_cap = first_page_node.capacity().rows;
    while (first_page_node.rows() < first_page_cap) _ = try s.grow();
    var second_node: ?*List.Node = null;
    while (s.pages.first == s.pages.last) second_node = try s.grow();
    try testing.expect(s.pages.first != s.pages.last);
    const last_node = s.pages.last.?;
    const second_cap = last_node.capacity().rows;
    while (last_node.rows() < second_cap) _ = try s.grow();
    const total = s.totalRows();
    const would_remain = total - first_page_cap + 1;
    try testing.expect(would_remain < s.rows);
    try testing.expect(s.pages.first != s.pages.last);
    try testing.expect(
        s.page_size + PagePool.item_size > s.limits.max(.bytes),
    );
    try testing.expect(s.totalRows() >= s.rows);
    try testing.expectEqual(second_cap, last_node.rows());
    _ = try s.grow();
    try testing.expect(s.totalRows() >= s.rows);
}
test "PageList resize (no reflow) more cols remaps pins in backfill path" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const cols: size.CellCountInt = 5;
    const cap = try std_capacity.adjust(.{ .cols = cols });
    var s = try init(alloc, .{ .cols = cols, .rows = cap.rows });
    defer s.deinit();
    while (s.pages.first == s.pages.last) {
        _ = try s.grow();
    }
    const first_page = s.pages.first.?;
    const second_page = s.pages.last.?;
    try testing.expect(first_page != second_page);
    s.eraseHistory(.{ .history = .{ .y = 0 } });
    try testing.expect(first_page.rows() < first_page.capacity().rows);
    const new_cols: size.CellCountInt = cols + 1;
    const adjusted = try second_page.capacity().adjust(.{ .cols = new_cols });
    try testing.expect(second_page.capacity().cols < adjusted.cols);
    const tracked = try s.trackPin(.{ .node = second_page, .x = 0, .y = 0 });
    defer s.untrackPin(tracked);
    const marker: u21 = 'X';
    tracked.rowAndCell().cell.* = .{
        .content_tag = .codepoint,
        .content = .{ .codepoint = .{ .data = marker } },
    };
    try s.resize(.{ .cols = new_cols, .reflow = false });
    var found = false;
    var it = s.pages.first;
    while (it) |node| : (it = node.next) {
        if (node == tracked.node) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
    try testing.expect(tracked.y < tracked.node.rows());
    const cell = tracked.rowAndCell().cell;
    try testing.expectEqual(.codepoint, cell.content_tag);
    try testing.expectEqual(marker, cell.content.codepoint.data);
}
test "PageList compact pool page produces exact-size heap page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24, .max_size = 0 });
    defer s.deinit();
    const node = s.pages.first.?;
    try testing.expectEqual(.pool, node.owned);
    try testing.expect(node.page().memory.len <= std_size);
    const original_size = node.page().size;
    const new_node = (try s.compact(node)).?;
    try testing.expectEqual(.heap, new_node.owned);
    try testing.expect(new_node.page().memory.len < std_size);
    try testing.expectEqual(original_size.rows, new_node.rows());
    try testing.expectEqual(original_size.cols, new_node.cols());
    try testing.expectEqual(new_node, s.pages.first.?);
    try testing.expectEqual(new_node.page().memory.len, s.page_size);
    try testing.expectEqual(null, try s.compact(new_node));
}
test "PageList compact then grow allocates new page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const node = (try s.compact(s.pages.first.?)).?;
    try testing.expectEqual(node.rows(), node.capacity().rows);
    _ = try s.grow();
    try testing.expect(s.pages.first != s.pages.last);
    try testing.expectEqual(.pool, s.pages.last.?.owned);
    try testing.expectEqual(@as(usize, 25), s.totalRows());
}
test "PageList compact then reset frees heap pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24, .max_size = 0 });
    defer s.deinit();
    const node = (try s.compact(s.pages.first.?)).?;
    try testing.expectEqual(.heap, node.owned);
    try testing.expect(node.page().memory.len < std_size);
    s.reset();
    try testing.expectEqual(.pool, s.pages.first.?.owned);
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
}
test "PageList compact then clone" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    {
        const node = s.pages.first.?;
        const rac = node.page().getRowAndCell(1, 2);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'X' } },
        };
    }
    const node = (try s.compact(s.pages.first.?)).?;
    try testing.expectEqual(.heap, node.owned);
    try testing.expect(node.page().memory.len < std_size);
    var s2 = try s.clone(alloc, .{
        .top = .{ .screen = .{} },
    });
    defer s2.deinit();
    try testing.expectEqual(@as(usize, s.rows), s2.totalRows());
    {
        const node2 = s2.pages.first.?;
        const rac = node2.page().getRowAndCell(1, 2);
        try testing.expectEqual(@as(u21, 'X'), rac.cell.content.codepoint.data);
    }
}
test "PageList compact oversized page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const page1_node = s.pages.first.?;
    page1_node.page().pauseIntegrityChecks(true);
    for (0..page1_node.capacity().rows - page1_node.rows()) |_| {
        _ = try s.grow();
    }
    page1_node.page().pauseIntegrityChecks(false);
    _ = try s.grow();
    try testing.expect(s.pages.first != s.pages.last);
    var node = s.pages.first.?;
    {
        const page = node.page();
        for (0..page.size.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = .{ .data = @intCast(x + y * s.cols) } },
                };
            }
        }
    }
    const tracked = try s.trackPin(.{ .node = node, .x = 5, .y = 10 });
    defer s.untrackPin(tracked);
    while (node.page().memory.len <= std_size) {
        node = try s.increaseCapacity(node, .grapheme_bytes);
    }
    try testing.expect(node.page().memory.len > std_size);
    const oversized_len = node.page().memory.len;
    const original_size = node.page().size;
    const second_node = node.next.?;
    node.page().dirty = true;
    const new_node = try s.compact(node);
    try testing.expect(new_node != null);
    try testing.expect(new_node.?.page().memory.len < oversized_len);
    try testing.expectEqual(original_size.rows, new_node.?.rows());
    try testing.expectEqual(original_size.cols, new_node.?.cols());
    try testing.expect(new_node.?.page().dirty);
    try testing.expectEqual(new_node.?, s.pages.first.?);
    try testing.expectEqual(null, new_node.?.prev);
    try testing.expectEqual(second_node, new_node.?.next);
    try testing.expectEqual(new_node.?, second_node.prev);
    try testing.expectEqual(new_node.?, tracked.node);
    try testing.expectEqual(@as(size.CellCountInt, 5), tracked.x);
    try testing.expectEqual(@as(size.CellCountInt, 10), tracked.y);
    const page = new_node.?.page();
    for (0..page.size.rows) |y| {
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            try testing.expectEqual(
                @as(u21, @intCast(x + y * s.cols)),
                rac.cell.content.codepoint.data,
            );
        }
    }
}
test "PageList destroyed pool page reuse is zeroed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24 });
    defer s.deinit();
    const node = try s.createPage(.{ .cap = initialCapacity(80) });
    node.page().size.rows = 1;
    const mem_ptr = node.page().memory.ptr;
    @memset(node.page().memory, 0xAA);
    s.destroyNode(node);
    const node2 = try s.createPage(.{ .cap = initialCapacity(80) });
    try testing.expectEqual(mem_ptr, node2.page().memory.ptr);
    node2.page().size.rows = node2.capacity().rows;
    const cells_len = @as(usize, node2.capacity().cols) *
        @as(usize, node2.capacity().rows);
    const cells = node2.page().cells.ptr(node2.page().memory)[0..cells_len];
    try testing.expect(std.mem.allEqual(
        u64,
        @as([]const u64, @ptrCast(cells)),
        0,
    ));
    node2.page().assertIntegrity();
    s.destroyNode(node2);
}
test "PageList increaseCapacity from zero-capacity dimensions" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24, .max_size = 0 });
    defer s.deinit();
    var node = (try s.compact(s.pages.first.?)).?;
    try testing.expectEqual(0, node.capacity().styles);
    try testing.expectEqual(0, node.capacity().grapheme_bytes);
    try testing.expectEqual(0, node.capacity().string_bytes);
    try testing.expectEqual(0, node.capacity().hyperlink_bytes);
    node = try s.increaseCapacity(node, .styles);
    try testing.expect(node.capacity().styles > 0);
    node = try s.increaseCapacity(node, .grapheme_bytes);
    try testing.expect(node.capacity().grapheme_bytes > 0);
    node = try s.increaseCapacity(node, .string_bytes);
    try testing.expect(node.capacity().string_bytes > 0);
    node = try s.increaseCapacity(node, .hyperlink_bytes);
    try testing.expect(node.capacity().hyperlink_bytes > 0);
    const styles = node.capacity().styles;
    node = try s.increaseCapacity(node, .styles);
    try testing.expectEqual(styles * 2, node.capacity().styles);
}
test "PageList compact after increaseCapacity" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 80, .rows = 24, .max_size = 0 });
    defer s.deinit();
    var node = s.pages.first.?;
    node = try s.increaseCapacity(node, .grapheme_bytes);
    const grown_len = node.page().memory.len;
    const new_node = (try s.compact(node)).?;
    try testing.expectEqual(.heap, new_node.owned);
    try testing.expect(new_node.page().memory.len < grown_len);
    try testing.expect(new_node.page().memory.len < std_size);
}
test "PageList split at middle row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    const page = s.pages.first.?.page();
    for (0..page.size.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast(y) } },
        };
    }
    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 5, .x = 0 };
    try s.split(split_pin);
    try testing.expect(s.pages.first != null);
    try testing.expect(s.pages.first.?.next != null);
    const first_page = s.pages.first.?.page();
    const second_page = s.pages.first.?.next.?.page();
    try testing.expectEqual(@as(usize, 5), first_page.size.rows);
    try testing.expectEqual(@as(usize, 5), second_page.size.rows);
    for (0..5) |y| {
        const rac = first_page.getRowAndCell(0, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint.data);
    }
    for (0..5) |y| {
        const rac = second_page.getRowAndCell(0, y);
        try testing.expectEqual(@as(u21, @intCast(y + 5)), rac.cell.content.codepoint.data);
    }
}
test "PageList split at row 0 is no-op" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    const page = s.pages.first.?.page();
    for (0..page.size.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast(y) } },
        };
    }
    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 0, .x = 0 };
    try s.split(split_pin);
    try testing.expect(s.pages.first != null);
    try testing.expect(s.pages.first.?.next == null);
    try testing.expectEqual(@as(usize, 10), page.size.rows);
    for (0..10) |y| {
        const rac = page.getRowAndCell(0, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint.data);
    }
}
test "PageList split at last row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    const page = s.pages.first.?.page();
    for (0..page.size.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = @intCast(y) } },
        };
    }
    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 9, .x = 0 };
    try s.split(split_pin);
    try testing.expect(s.pages.first != null);
    try testing.expect(s.pages.first.?.next != null);
    const first_page = s.pages.first.?.page();
    const second_page = s.pages.first.?.next.?.page();
    try testing.expectEqual(@as(usize, 9), first_page.size.rows);
    try testing.expectEqual(@as(usize, 1), second_page.size.rows);
    const rac = second_page.getRowAndCell(0, 0);
    try testing.expectEqual(@as(u21, 9), rac.cell.content.codepoint.data);
}
test "PageList split single row page returns OutOfSpace" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 1, .max_size = 0 });
    defer s.deinit();
    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 0, .x = 0 };
    const result = s.split(split_pin);
    try testing.expectError(error.OutOfSpace, result);
}
test "PageList split moves tracked pins" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    const tracked = try s.trackPin(.{ .node = s.pages.first.?, .y = 7, .x = 3 });
    defer s.untrackPin(tracked);
    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 5, .x = 0 };
    try s.split(split_pin);
    try testing.expect(tracked.node == s.pages.first.?.next.?);
    try testing.expectEqual(@as(usize, 2), tracked.y);
    try testing.expectEqual(@as(usize, 3), tracked.x);
}
test "PageList split tracked pin before split point unchanged" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    const original_node = s.pages.first.?;
    const tracked = try s.trackPin(.{ .node = original_node, .y = 2, .x = 5 });
    defer s.untrackPin(tracked);
    const split_pin: Pin = .{ .node = original_node, .y = 5, .x = 0 };
    try s.split(split_pin);
    try testing.expect(tracked.node == s.pages.first.?);
    try testing.expectEqual(@as(usize, 2), tracked.y);
    try testing.expectEqual(@as(usize, 5), tracked.x);
}
test "PageList split tracked pin at split point moves to new page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    const original_node = s.pages.first.?;
    const tracked = try s.trackPin(.{ .node = original_node, .y = 5, .x = 4 });
    defer s.untrackPin(tracked);
    const split_pin: Pin = .{ .node = original_node, .y = 5, .x = 0 };
    try s.split(split_pin);
    try testing.expect(tracked.node == s.pages.first.?.next.?);
    try testing.expectEqual(@as(usize, 0), tracked.y);
    try testing.expectEqual(@as(usize, 4), tracked.x);
}
test "PageList split multiple tracked pins across regions" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    const original_node = s.pages.first.?;
    const pin_before = try s.trackPin(.{ .node = original_node, .y = 1, .x = 0 });
    defer s.untrackPin(pin_before);
    const pin_at_split = try s.trackPin(.{ .node = original_node, .y = 5, .x = 2 });
    defer s.untrackPin(pin_at_split);
    const pin_after1 = try s.trackPin(.{ .node = original_node, .y = 7, .x = 3 });
    defer s.untrackPin(pin_after1);
    const pin_after2 = try s.trackPin(.{ .node = original_node, .y = 9, .x = 8 });
    defer s.untrackPin(pin_after2);
    const split_pin: Pin = .{ .node = original_node, .y = 5, .x = 0 };
    try s.split(split_pin);
    const first_page = s.pages.first.?;
    const second_page = first_page.next.?;
    try testing.expect(pin_before.node == first_page);
    try testing.expectEqual(@as(usize, 1), pin_before.y);
    try testing.expectEqual(@as(usize, 0), pin_before.x);
    try testing.expect(pin_at_split.node == second_page);
    try testing.expectEqual(@as(usize, 0), pin_at_split.y);
    try testing.expectEqual(@as(usize, 2), pin_at_split.x);
    try testing.expect(pin_after1.node == second_page);
    try testing.expectEqual(@as(usize, 2), pin_after1.y);
    try testing.expectEqual(@as(usize, 3), pin_after1.x);
    try testing.expect(pin_after2.node == second_page);
    try testing.expectEqual(@as(usize, 4), pin_after2.y);
    try testing.expectEqual(@as(usize, 8), pin_after2.x);
}
test "PageList split tracked viewport_pin in split region moves correctly" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    const original_node = s.pages.first.?;
    s.viewport_pin.node = original_node;
    s.viewport_pin.y = 7;
    s.viewport_pin.x = 6;
    const split_pin: Pin = .{ .node = original_node, .y = 5, .x = 0 };
    try s.split(split_pin);
    try testing.expect(s.viewport_pin.node == s.pages.first.?.next.?);
    try testing.expectEqual(@as(usize, 2), s.viewport_pin.y);
    try testing.expectEqual(@as(usize, 6), s.viewport_pin.x);
}
test "PageList split middle page preserves linked list order" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 12, .max_size = 0 });
    defer s.deinit();
    const first_node = s.pages.first.?;
    const split_pin1: Pin = .{ .node = first_node, .y = 4, .x = 0 };
    try s.split(split_pin1);
    const page1 = s.pages.first.?;
    const page2 = s.pages.first.?.next.?;
    try testing.expectEqual(@as(usize, 4), page1.rows());
    try testing.expectEqual(@as(usize, 8), page2.rows());
    const split_pin2: Pin = .{ .node = page2, .y = 4, .x = 0 };
    try s.split(split_pin2);
    const first = s.pages.first.?;
    const middle = first.next.?;
    const last = middle.next.?;
    try testing.expectEqual(page1, first);
    try testing.expectEqual(page2, middle);
    try testing.expectEqual(s.pages.last.?, last);
    try testing.expect(first.prev == null);
    try testing.expectEqual(first, middle.prev.?);
    try testing.expectEqual(middle, last.prev.?);
    try testing.expectEqual(middle, first.next.?);
    try testing.expectEqual(last, middle.next.?);
    try testing.expect(last.next == null);
    try testing.expectEqual(@as(usize, 4), first.rows());
    try testing.expectEqual(@as(usize, 4), middle.rows());
    try testing.expectEqual(@as(usize, 4), last.rows());
}
test "PageList split last page makes new page the last" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    const first_node = s.pages.first.?;
    const split_pin1: Pin = .{ .node = first_node, .y = 5, .x = 0 };
    try s.split(split_pin1);
    const last_before_split = s.pages.last.?;
    try testing.expectEqual(@as(usize, 5), last_before_split.rows());
    const split_pin2: Pin = .{ .node = last_before_split, .y = 2, .x = 0 };
    try s.split(split_pin2);
    const new_last = s.pages.last.?;
    try testing.expect(new_last != last_before_split);
    try testing.expectEqual(last_before_split, new_last.prev.?);
    try testing.expect(new_last.next == null);
    try testing.expectEqual(@as(usize, 2), last_before_split.rows());
    try testing.expectEqual(@as(usize, 3), new_last.rows());
}
test "PageList split first page keeps original as first" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    const original_first = s.pages.first.?;
    const split_pin1: Pin = .{ .node = original_first, .y = 5, .x = 0 };
    try s.split(split_pin1);
    const second_page = s.pages.first.?.next.?;
    const split_pin2: Pin = .{ .node = s.pages.first.?, .y = 2, .x = 0 };
    try s.split(split_pin2);
    try testing.expectEqual(original_first, s.pages.first.?);
    try testing.expect(s.pages.first.?.prev == null);
    const inserted = s.pages.first.?.next.?;
    try testing.expect(inserted != second_page);
    try testing.expectEqual(second_page, inserted.next.?);
    try testing.expectEqual(@as(usize, 2), s.pages.first.?.rows());
    try testing.expectEqual(@as(usize, 3), inserted.rows());
    try testing.expectEqual(@as(usize, 5), second_page.rows());
}
test "PageList split preserves wrap flags" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    const page = s.pages.first.?.page();
    {
        const rac5 = page.getRowAndCell(0, 5);
        rac5.row.wrap = true;
        const rac6 = page.getRowAndCell(0, 6);
        rac6.row.wrap_continuation = true;
        const rac7 = page.getRowAndCell(0, 7);
        rac7.row.wrap = true;
        rac7.row.wrap_continuation = true;
    }
    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 5, .x = 0 };
    try s.split(split_pin);
    const second_page = s.pages.first.?.next.?.page();
    {
        const rac0 = second_page.getRowAndCell(0, 0);
        try testing.expect(rac0.row.wrap);
        try testing.expect(!rac0.row.wrap_continuation);
    }
    {
        const rac1 = second_page.getRowAndCell(0, 1);
        try testing.expect(!rac1.row.wrap);
        try testing.expect(rac1.row.wrap_continuation);
    }
    {
        const rac2 = second_page.getRowAndCell(0, 2);
        try testing.expect(rac2.row.wrap);
        try testing.expect(rac2.row.wrap_continuation);
    }
}
test "PageList split preserves styled cells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    const page = s.pages.first.?.page();
    const style: stylepkg.Style = .{ .flags = .{ .bold = true } };
    const style_id = try page.styles.add(page.memory, style);
    for (5..8) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'S' } },
            .style_id = style_id,
        };
        rac.row.styled = true;
        page.styles.use(page.memory, style_id);
    }
    page.styles.release(page.memory, style_id);
    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 5, .x = 0 };
    try s.split(split_pin);
    const first_page = s.pages.first.?.page();
    const second_page = s.pages.first.?.next.?.page();
    try testing.expectEqual(@as(usize, 0), first_page.styles.count());
    try testing.expectEqual(@as(usize, 1), second_page.styles.count());
    for (0..3) |y| {
        const rac = second_page.getRowAndCell(0, y);
        try testing.expectEqual(@as(u21, 'S'), rac.cell.content.codepoint.data);
        try testing.expect(rac.cell.style_id != 0);
        const got_style = second_page.styles.get(second_page.memory, rac.cell.style_id);
        try testing.expect(got_style.flags.bold);
        try testing.expect(rac.row.styled);
    }
}
test "PageList split preserves grapheme clusters" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    const page = s.pages.first.?.page();
    {
        const rac = page.getRowAndCell(0, 6);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 0x1F468 } },
        };
        try page.setGraphemes(rac.row, rac.cell, &.{
            0x200D,
            0x1F469,
        });
    }
    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 5, .x = 0 };
    try s.split(split_pin);
    const first_page = s.pages.first.?.page();
    const second_page = s.pages.first.?.next.?.page();
    try testing.expectEqual(@as(usize, 0), first_page.graphemeCount());
    try testing.expectEqual(@as(usize, 1), second_page.graphemeCount());
    {
        const rac = second_page.getRowAndCell(0, 1);
        try testing.expectEqual(@as(u21, 0x1F468), rac.cell.content.codepoint.data);
        try testing.expect(rac.row.grapheme);
        const cps = second_page.lookupGrapheme(rac.cell).?;
        try testing.expectEqual(@as(usize, 2), cps.len);
        try testing.expectEqual(@as(u21, 0x200D), cps[0]);
        try testing.expectEqual(@as(u21, 0x1F469), cps[1]);
    }
}
test "PageList split preserves hyperlinks" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_size = 0 });
    defer s.deinit();
    const page = s.pages.first.?.page();
    const hyperlink_id = try page.insertHyperlink(.{
        .id = .{ .implicit = 0 },
        .uri = "https://example.com",
    });
    {
        const rac = page.getRowAndCell(0, 7);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'L' } },
        };
        try page.setHyperlink(rac.row, rac.cell, hyperlink_id);
    }
    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 5, .x = 0 };
    try s.split(split_pin);
    const first_page = s.pages.first.?.page();
    const second_page = s.pages.first.?.next.?.page();
    try testing.expectEqual(@as(usize, 0), first_page.hyperlink_set.count());
    try testing.expectEqual(@as(usize, 1), second_page.hyperlink_set.count());
    {
        const rac = second_page.getRowAndCell(0, 2);
        try testing.expectEqual(@as(u21, 'L'), rac.cell.content.codepoint.data);
        try testing.expect(rac.cell.hyperlink);
        const link_id = second_page.lookupHyperlink(rac.cell).?;
        const link = second_page.hyperlink_set.get(second_page.memory, link_id);
        try testing.expectEqualStrings("https://example.com", link.uri.slice(second_page.memory));
    }
}
test "PageList eraseRow recycled row has default metadata" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 5, .rows = 3 });
    defer s.deinit();
    {
        const rac = s.getCell(.{ .active = .{} }).?;
        rac.row.wrap = true;
        rac.row.wrap_continuation = true;
        rac.row.semantic_prompt = .prompt;
    }
    try s.eraseRow(.{ .active = .{} });
    {
        const rac = s.getCell(.{ .active = .{ .y = 2 } }).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
}
test "PageList eraseRowBounded recycled row has default metadata" {
    const testing = std.testing;
    const alloc = testing.allocator;
    for ([_]usize{ 1, 10 }) |limit| {
        var s = try init(alloc, .{ .cols = 5, .rows = 3 });
        defer s.deinit();
        {
            const rac = s.getCell(.{ .active = .{} }).?;
            rac.row.wrap = true;
            rac.row.wrap_continuation = true;
            rac.row.semantic_prompt = .prompt;
        }
        try s.eraseRowBounded(.{ .active = .{} }, limit);
        const recycled_y = @min(limit, 2);
        const rac = s.getCell(.{ .active = .{ .y = @intCast(recycled_y) } }).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
}
test "PageList eraseActive regrown rows have default metadata" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 5, .rows = 3 });
    defer s.deinit();
    for (0..2) |y| {
        const rac = s.getCell(.{ .active = .{ .y = @intCast(y) } }).?;
        rac.row.wrap = true;
        rac.row.wrap_continuation = true;
        rac.row.semantic_prompt = .prompt;
    }
    s.eraseActive(1);
    for (0..3) |y| {
        const rac = s.getCell(.{ .active = .{ .y = @intCast(y) } }).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
}
test "PageList split retired rows have default state" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 5, .rows = 10 });
    defer s.deinit();
    {
        const rac = s.getCell(.{ .active = .{ .y = 7 } }).?;
        rac.row.wrap = true;
        rac.row.semantic_prompt = .prompt;
        rac.cell.* = .{
            .content_tag = .bg_color_palette,
            .content = .{ .color_palette = .{ .data = 42 } },
        };
    }
    const node = s.pages.first.?;
    try s.split(s.pin(.{ .active = .{ .y = 5 } }).?);
    const page = node.page();
    try testing.expectEqual(@as(usize, 5), page.size.rows);
    const rows = page.rows.ptr(page.memory.ptr);
    for (5..10) |y| {
        const row = rows[y];
        try testing.expect(!row.wrap);
        try testing.expect(!row.wrap_continuation);
        try testing.expectEqual(.none, row.semantic_prompt);
        const cells = row.cells.ptr(page.memory.ptr)[0..page.size.cols];
        for (cells) |cell| try testing.expect(cell.isZero());
    }
}
test "PageList resize trimmed rows have default state" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try init(alloc, .{ .cols = 5, .rows = 5 });
    defer s.deinit();
    {
        const rac = s.getCell(.{ .active = .{ .y = 4 } }).?;
        rac.row.wrap_continuation = true;
        rac.row.semantic_prompt = .prompt_continuation;
        rac.cell.* = .{
            .content_tag = .bg_color_palette,
            .content = .{ .color_palette = .{ .data = 42 } },
        };
    }
    try s.resize(.{ .rows = 4, .reflow = false });
    try s.resize(.{ .rows = 5, .reflow = false });
    {
        const rac = s.getCell(.{ .active = .{ .y = 4 } }).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
        try testing.expect(rac.cell.isZero());
    }
}
test "PageList memory pool never touches idle page memory" {
    const testing = std.testing;
    const preheat = page_preheat;
    const backing = try testing.allocator.alignedAlloc(
        u8,
        .fromByteUnits(std.heap.page_size_min),
        preheat * std_size,
    );
    defer testing.allocator.free(backing);
    var fba: std.heap.FixedBufferAllocator = .init(backing);
    var pool: MemoryPool = try .init(testing.allocator, fba.allocator(), preheat);
    defer pool.deinit();
    try testing.expectEqual(preheat * std_size, fba.end_index);
    const sentinel: u8 = 0x5A;
    @memset(backing, sentinel);
    var items: [preheat]PagePool.ItemPtr = undefined;
    for (&items) |*item| {
        item.* = try pool.pages.create();
        try testing.expectEqual(preheat * std_size, fba.end_index);
        try testing.expect(std.mem.allEqual(u8, item.*, sentinel));
    }
    for (items) |item| pool.pages.destroy(item);
    try testing.expect(std.mem.allEqual(u8, backing, sentinel));
}
test "PageList memory pool fast path does not allocate" {
    const testing = std.testing;
    var counting: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var pool: MemoryPool = try .init(
        testing.allocator,
        counting.allocator(),
        page_preheat,
    );
    defer pool.deinit();
    try testing.expectEqual(page_preheat, counting.allocations);
    var items: [page_preheat]PagePool.ItemPtr = undefined;
    for (0..1024) |_| {
        for (&items) |*item| item.* = try pool.pages.create();
        for (items) |item| pool.pages.destroy(item);
    }
    try testing.expectEqual(page_preheat, counting.allocations);
    try testing.expectEqual(0, counting.deallocations);
    var extra: [page_preheat + 2]PagePool.ItemPtr = undefined;
    for (0..1024) |_| {
        for (&extra) |*item| item.* = try pool.pages.create();
        for (extra) |item| pool.pages.destroy(item);
    }
    try testing.expectEqual(extra.len, counting.allocations);
    try testing.expectEqual(0, counting.deallocations);
}
