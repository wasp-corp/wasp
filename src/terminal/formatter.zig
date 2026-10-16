const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const fastprint = @import("../fastprint.zig");
const lib = @import("lib.zig");
const Allocator = std.mem.Allocator;
const color = @import("color.zig");
const size = @import("size.zig");
const charsets = @import("charsets.zig");
const hyperlink = @import("hyperlink.zig");
const kitty = @import("kitty.zig");
const modespkg = @import("modes.zig");
const Screen = @import("Screen.zig");
const Terminal = @import("Terminal.zig");
const Cell = @import("page.zig").Cell;
const Coordinate = @import("point.zig").Coordinate;
const Page = @import("page.zig").Page;
const PageList = @import("PageList.zig");
const Pin = PageList.Pin;
const Row = @import("page.zig").Row;
const Selection = @import("Selection.zig");
const Style = @import("style.zig").Style;
pub const Format = lib.Enum(lib.target, &.{
    "plain",
    "vt",
    "html",
});
pub fn formatStyled(fmt: Format) bool {
    return switch (fmt) {
        .plain => false,
        .html, .vt => true,
    };
}
pub const CodepointMap = struct {
    range: [2]u21,
    replacement: Replacement,
    pub const Replacement = union(enum) {
        codepoint: u21,
        string: []const u8,
    };
};
pub const Options = struct {
    emit: Format,
    unwrap: bool = false,
    trim: bool = true,
    codepoint_map: ?std.MultiArrayList(CodepointMap) = .{},
    background: ?color.RGB = null,
    foreground: ?color.RGB = null,
    palette: ?*const color.Palette = null,
    pub const plain: Options = .{ .emit = .plain };
    pub const vt: Options = .{ .emit = .vt };
    pub const html: Options = .{ .emit = .html };
};
pub const PinMap = struct {
    alloc: Allocator,
    map: *Map,
    pub const Node = @FieldType(Pin, "node");
    pub const NodeRun = struct {
        offset: usize,
        node: Node,
    };
    pub const Map = struct {
        points: std.ArrayList(Coordinate) = .empty,
        nodes: std.ArrayList(NodeRun) = .empty,
        pub const empty: Map = .{};
        pub fn deinit(self: *Map, alloc: Allocator) void {
            self.points.deinit(alloc);
            self.nodes.deinit(alloc);
        }
        pub fn clearRetainingCapacity(self: *Map) void {
            self.points.clearRetainingCapacity();
            self.nodes.clearRetainingCapacity();
        }
        pub fn count(self: *const Map) usize {
            return self.points.items.len;
        }
        pub fn setNode(
            self: *Map,
            alloc: Allocator,
            node: Node,
        ) Allocator.Error!void {
            if (self.nodes.getLastOrNull()) |last| {
                if (last.node == node) return;
            }
            try self.nodes.append(alloc, .{
                .offset = self.points.items.len,
                .node = node,
            });
        }
        pub fn append(
            self: *Map,
            alloc: Allocator,
            pin: Pin,
            n: usize,
        ) Allocator.Error!void {
            if (n == 0) return;
            try self.setNode(alloc, pin.node);
            try self.points.appendNTimes(
                alloc,
                .{ .x = pin.x, .y = pin.y },
                n,
            );
        }
        pub fn get(self: *const Map, offset: usize) ?Pin {
            if (offset >= self.points.items.len) return null;
            const coord = self.points.items[offset];
            return .{
                .node = findNode(self.nodes.items, offset) orelse return null,
                .x = coord.x,
                .y = @intCast(coord.y),
            };
        }
        pub fn getLastOrNull(self: *const Map) ?Pin {
            const len = self.points.items.len;
            if (len == 0) return null;
            return self.get(len - 1);
        }
    };
    pub fn findNode(runs: []const NodeRun, offset: usize) ?Node {
        if (runs.len == 0 or offset < runs[0].offset) return null;
        var lo: usize = 0;
        var hi: usize = runs.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (runs[mid].offset <= offset) lo = mid else hi = mid;
        }
        return runs[lo].node;
    }
};
pub const TerminalFormatter = struct {
    terminal: *const Terminal,
    opts: Options,
    content: ScreenFormatter.Content,
    extra: Extra,
    pin_map: ?PinMap,
    pub const Extra = packed struct {
        palette: bool,
        modes: bool,
        scrolling_region: bool,
        tabstops: bool,
        pwd: bool,
        keyboard: bool,
        screen: ScreenFormatter.Extra,
        pub const none: Extra = .{
            .palette = false,
            .modes = false,
            .scrolling_region = false,
            .tabstops = false,
            .pwd = false,
            .keyboard = false,
            .screen = .none,
        };
        pub const styles: Extra = .{
            .palette = true,
            .modes = false,
            .scrolling_region = false,
            .tabstops = false,
            .pwd = false,
            .keyboard = false,
            .screen = .styles,
        };
        pub const all: Extra = .{
            .palette = true,
            .modes = true,
            .scrolling_region = true,
            .tabstops = true,
            .pwd = true,
            .keyboard = true,
            .screen = .all,
        };
    };
    pub fn init(
        terminal: *const Terminal,
        opts: Options,
    ) TerminalFormatter {
        return .{
            .terminal = terminal,
            .opts = opts,
            .content = .{ .selection = null },
            .extra = .styles,
            .pin_map = null,
        };
    }
    pub fn format(
        self: TerminalFormatter,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        if (self.extra.palette) palette: {
            switch (self.opts.emit) {
                .plain => break :palette,
                .vt => {
                    for (self.terminal.colors.palette.current, 0..) |rgb, i| {
                        try writer.print(
                            "\x1b]4;{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\",
                            .{ i, rgb.r, rgb.g, rgb.b },
                        );
                    }
                },
                .html => {
                    try writer.writeAll("<style>:root{");
                    for (self.terminal.colors.palette.current, 0..) |rgb, i| {
                        try writer.print(
                            "--vt-palette-{d}: #{x:0>2}{x:0>2}{x:0>2};",
                            .{ i, rgb.r, rgb.g, rgb.b },
                        );
                    }
                    try writer.writeAll("}</style>");
                },
            }
            if (self.pin_map) |*m| {
                var discarding: std.Io.Writer.Discarding = .init(&.{});
                var extra_formatter: TerminalFormatter = self;
                extra_formatter.content = .none;
                extra_formatter.pin_map = null;
                extra_formatter.extra = .none;
                extra_formatter.extra.palette = true;
                try extra_formatter.format(&discarding.writer);
                m.map.append(
                    m.alloc,
                    self.terminal.screens.active.pages.getTopLeft(.screen),
                    std.math.cast(usize, discarding.count) orelse return error.WriteFailed,
                ) catch return error.WriteFailed;
            }
        }
        if (self.opts.emit == .vt and self.extra.modes) {
            inline for (@typeInfo(modespkg.Mode).@"enum".fields) |field| {
                const mode: modespkg.Mode = @enumFromInt(field.value);
                const current = self.terminal.modes.get(mode);
                const default_val = @field(self.terminal.modes.default, field.name);
                if (current != default_val) {
                    const tag: modespkg.ModeTag = @bitCast(@intFromEnum(mode));
                    const prefix = if (tag.ansi) "" else "?";
                    const suffix = if (current) "h" else "l";
                    try writer.print("\x1b[{s}{d}{s}", .{ prefix, tag.value, suffix });
                }
            }
            if (self.pin_map) |*m| {
                var discarding: std.Io.Writer.Discarding = .init(&.{});
                var extra_formatter: TerminalFormatter = self;
                extra_formatter.content = .none;
                extra_formatter.pin_map = null;
                extra_formatter.extra = .none;
                extra_formatter.extra.modes = true;
                try extra_formatter.format(&discarding.writer);
                m.map.append(
                    m.alloc,
                    self.terminal.screens.active.pages.getTopLeft(.screen),
                    std.math.cast(usize, discarding.count) orelse return error.WriteFailed,
                ) catch return error.WriteFailed;
            }
        }
        if (self.opts.emit == .vt and self.extra.tabstops) {
            try writer.print("\x1b[3g", .{});
            for (0..self.terminal.cols) |col| {
                if (self.terminal.tabstops.get(col)) {
                    try writer.print("\x1b[{d}G", .{col + 1});
                    try writer.print("\x1bH", .{});
                }
            }
            try writer.writeAll("\x1b[H");
            if (self.pin_map) |*m| {
                var discarding: std.Io.Writer.Discarding = .init(&.{});
                var extra_formatter: TerminalFormatter = self;
                extra_formatter.content = .none;
                extra_formatter.pin_map = null;
                extra_formatter.extra = .none;
                extra_formatter.extra.tabstops = true;
                try extra_formatter.format(&discarding.writer);
                m.map.append(
                    m.alloc,
                    self.terminal.screens.active.pages.getTopLeft(.screen),
                    std.math.cast(usize, discarding.count) orelse return error.WriteFailed,
                ) catch return error.WriteFailed;
            }
        }
        var screen_formatter: ScreenFormatter = .init(self.terminal.screens.active, self.opts);
        screen_formatter.content = self.content;
        screen_formatter.pin_map = self.pin_map;
        try screen_formatter.format(writer);
        if (self.opts.emit == .vt) {
            if (self.extra.scrolling_region) {
                const region = &self.terminal.scrolling_region;
                if (region.top != 0 or region.bottom != self.terminal.rows - 1) {
                    try writer.print("\x1b[{d};{d}r", .{ region.top + 1, region.bottom + 1 });
                }
                if (region.left != 0 or region.right != self.terminal.cols - 1) {
                    try writer.print("\x1b[{d};{d}s", .{ region.left + 1, region.right + 1 });
                }
            }
            if (self.extra.keyboard) {
                if (self.terminal.flags.modify_other_keys_2) {
                    try writer.print("\x1b[>4;2m", .{});
                }
            }
            if (self.extra.pwd) {
                const pwd = self.terminal.pwd.items;
                if (pwd.len > 0) try writer.print("\x1b]7;{s}\x1b\\", .{pwd});
            }
            if (self.pin_map) |*m| {
                var discarding: std.Io.Writer.Discarding = .init(&.{});
                var extra_formatter: TerminalFormatter = self;
                extra_formatter.content = .none;
                extra_formatter.pin_map = null;
                extra_formatter.extra = .none;
                extra_formatter.extra.scrolling_region = self.extra.scrolling_region;
                extra_formatter.extra.keyboard = self.extra.keyboard;
                extra_formatter.extra.pwd = self.extra.pwd;
                try extra_formatter.format(&discarding.writer);
                m.map.append(
                    m.alloc,
                    m.map.getLastOrNull() orelse
                        self.terminal.screens.active.pages.getTopLeft(.screen),
                    std.math.cast(usize, discarding.count) orelse return error.WriteFailed,
                ) catch return error.WriteFailed;
            }
        }
        screen_formatter.content = .none;
        screen_formatter.extra = self.extra.screen;
        if (self.opts.emit == .vt and
            self.extra.modes and
            self.extra.scrolling_region and
            self.terminal.modes.get(.origin))
        {
            screen_formatter.cursor_origin = .{
                .x = self.terminal.scrolling_region.left,
                .y = self.terminal.scrolling_region.top,
            };
        }
        try screen_formatter.format(writer);
    }
};
pub const ScreenFormatter = struct {
    screen: *const Screen,
    opts: Options,
    content: Content,
    extra: Extra,
    pin_map: ?PinMap,
    cursor_origin: CursorOrigin = .{},
    pub const Content = union(enum) {
        none,
        selection: ?Selection,
    };
    pub const CursorOrigin = struct {
        x: size.CellCountInt = 0,
        y: size.CellCountInt = 0,
    };
    pub const Extra = packed struct {
        cursor: bool,
        style: bool,
        hyperlink: bool,
        protection: bool,
        kitty_keyboard: bool,
        charsets: bool,
        pub const none: Extra = .{
            .cursor = false,
            .style = false,
            .hyperlink = false,
            .protection = false,
            .kitty_keyboard = false,
            .charsets = false,
        };
        pub const styles: Extra = .{
            .cursor = false,
            .style = true,
            .hyperlink = true,
            .protection = false,
            .kitty_keyboard = false,
            .charsets = false,
        };
        pub const all: Extra = .{
            .cursor = true,
            .style = true,
            .hyperlink = true,
            .protection = true,
            .kitty_keyboard = true,
            .charsets = true,
        };
        fn isSet(self: Extra) bool {
            const Int = @typeInfo(Extra).@"struct".backing_integer.?;
            const v: Int = @bitCast(self);
            return v != 0;
        }
    };
    pub fn init(
        screen: *const Screen,
        opts: Options,
    ) ScreenFormatter {
        return .{
            .screen = screen,
            .opts = opts,
            .content = .{ .selection = null },
            .extra = .none,
            .pin_map = null,
        };
    }
    pub fn format(
        self: ScreenFormatter,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self.content) {
            .none => {},
            .selection => |selection_| {
                var list_formatter: PageListFormatter = .init(&self.screen.pages, self.opts);
                list_formatter.pin_map = self.pin_map;
                if (selection_) |sel| {
                    list_formatter.top_left = sel.topLeft(self.screen);
                    list_formatter.bottom_right = sel.bottomRight(self.screen);
                    list_formatter.rectangle = sel.rectangle;
                }
                try list_formatter.format(writer);
            },
        }
        switch (self.opts.emit) {
            .plain => return,
            .vt => if (!self.extra.isSet()) return,
            .html => return,
        }
        if (self.extra.cursor) cursor: {
            const cursor = &self.screen.cursor;
            const origin = self.cursor_origin;
            if (!cursor.pending_wrap or cursor.x != self.screen.pages.cols - 1) {
                try writer.print("\x1b[{d};{d}H", .{
                    (cursor.y -| origin.y) + 1,
                    (cursor.x -| origin.x) + 1,
                });
                break :cursor;
            }
            const start_x = switch (cursor.page_cell.wide) {
                .spacer_tail => cursor.x - 1,
                .narrow, .wide, .spacer_head => cursor.x,
            };
            try writer.print(
                "\x1b[{d};{d}H",
                .{ (cursor.y -| origin.y) + 1, (start_x -| origin.x) + 1 },
            );
            if (cursor.page_cell.wide != .spacer_tail and
                !cursor.page_cell.hasText())
            {
                try writer.writeAll(" \x1b7\x1b[X\x1b8");
                break :cursor;
            }
            var cell_formatter: PageFormatter = .init(
                cursor.page_pin.node.page(),
                self.opts,
            );
            cell_formatter.start_x = cursor.x;
            cell_formatter.end_x = cursor.x;
            cell_formatter.start_y = cursor.page_pin.y;
            cell_formatter.end_y = cursor.page_pin.y;
            try cell_formatter.format(writer);
        }
        if (self.extra.style) {
            const cursor = &self.screen.cursor;
            try writer.print("{f}", .{cursor.style.formatterVt()});
        }
        if (self.extra.hyperlink) {
            const cursor = &self.screen.cursor;
            if (cursor.hyperlink) |link| {
                switch (link.id) {
                    .explicit => |id| try writer.print(
                        "\x1b]8;id={s};{s}\x1b\\",
                        .{ id, link.uri },
                    ),
                    .implicit => try writer.print(
                        "\x1b]8;;{s}\x1b\\",
                        .{link.uri},
                    ),
                }
            }
        }
        if (self.extra.protection) {
            const cursor = &self.screen.cursor;
            if (cursor.protected) {
                try writer.print("\x1b[1\"q", .{});
            }
        }
        if (self.extra.kitty_keyboard) {
            const current_flags = self.screen.kitty_keyboard.current();
            if (current_flags.int() != kitty.KeyFlags.disabled.int()) {
                const flags = current_flags.int();
                try writer.print("\x1b[={d};1u", .{flags});
            }
        }
        if (self.extra.charsets) {
            const charset = &self.screen.charset;
            for (std.enums.values(charsets.Slots)) |slot| {
                const cs = charset.charsets.get(slot);
                if (cs != .utf8) { 
                    const intermediate: u8 = switch (slot) {
                        .G0 => '(',
                        .G1 => ')',
                        .G2 => '*',
                        .G3 => '+',
                    };
                    const final: u8 = switch (cs) {
                        .ascii => 'B',
                        .british => 'A',
                        .dec_special => '0',
                        else => continue,
                    };
                    try writer.print("\x1b{c}{c}", .{ intermediate, final });
                }
            }
            if (charset.gl != .G0) {
                const seq = switch (charset.gl) {
                    .G0 => unreachable,
                    .G1 => "\x0e", 
                    .G2 => "\x1bn", 
                    .G3 => "\x1bo", 
                };
                try writer.print("{s}", .{seq});
            }
            if (charset.gr != .G2) {
                const seq = switch (charset.gr) {
                    .G0 => unreachable, 
                    .G1 => "\x1b~", 
                    .G2 => unreachable,
                    .G3 => "\x1b|", 
                };
                try writer.print("{s}", .{seq});
            }
        }
        if (self.pin_map) |*m| {
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            var extra_formatter: ScreenFormatter = self;
            extra_formatter.content = .none;
            extra_formatter.pin_map = null;
            try extra_formatter.format(&discarding.writer);
            m.map.append(
                m.alloc,
                m.map.getLastOrNull() orelse
                    self.screen.pages.getTopLeft(.screen),
                std.math.cast(usize, discarding.count) orelse return error.WriteFailed,
            ) catch return error.WriteFailed;
        }
    }
};
pub const PageListFormatter = struct {
    list: *const PageList,
    opts: Options,
    top_left: ?PageList.Pin,
    bottom_right: ?PageList.Pin,
    rectangle: bool,
    pin_map: ?PinMap,
    pub fn init(
        list: *const PageList,
        opts: Options,
    ) PageListFormatter {
        return PageListFormatter{
            .list = list,
            .opts = opts,
            .top_left = null,
            .bottom_right = null,
            .rectangle = false,
            .pin_map = null,
        };
    }
    pub fn format(
        self: PageListFormatter,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const tl: PageList.Pin = self.top_left orelse self.list.getTopLeft(.screen);
        var br: PageList.Pin = self.bottom_right orelse self.list.getBottomRight(.screen).?;
        if (self.opts.unwrap and !self.rectangle and
            br.rowAndCell().cell.wide == .spacer_head)
        {
            br = br.rightWrap(1) orelse br;
        }
        var page_state: ?PageFormatter.TrailingState = null;
        var iter = tl.pageIterator(.right_down, br);
        while (iter.next()) |chunk| {
            assert(chunk.start < chunk.end);
            assert(chunk.end > 0);
            var formatter: PageFormatter = .init(chunk.node.page(), self.opts);
            formatter.start_y = chunk.start;
            formatter.end_y = chunk.end - 1;
            formatter.trailing_state = page_state;
            formatter.rectangle = self.rectangle;
            if (self.rectangle) {
                formatter.start_x = tl.x;
                formatter.end_x = br.x;
            } else {
                if (chunk.node == tl.node) formatter.start_x = tl.x;
                if (chunk.node == br.node) formatter.end_x = br.x;
            }
            if (self.pin_map) |*m| {
                m.map.setNode(m.alloc, chunk.node) catch return error.WriteFailed;
                formatter.point_map = .{
                    .alloc = m.alloc,
                    .map = &m.map.points,
                    .base = m.map.points.items.len,
                };
            }
            page_state = try formatter.formatWithState(writer);
        }
    }
};
pub const PageFormatter = struct {
    page: *const Page,
    opts: Options,
    start_x: size.CellCountInt,
    start_y: size.CellCountInt,
    end_x: ?size.CellCountInt,
    end_y: ?size.CellCountInt,
    rectangle: bool,
    point_map: ?PointMap,
    trailing_state: ?TrailingState,
    pub const PointMap = struct {
        alloc: Allocator,
        map: *std.ArrayList(Coordinate),
        base: usize = 0,
    };
    pub const TrailingState = struct {
        rows: usize = 0,
        cells: usize = 0,
        pub const empty: TrailingState = .{ .rows = 0, .cells = 0 };
    };
    pub fn init(page: *const Page, opts: Options) PageFormatter {
        return .{
            .page = page,
            .opts = opts,
            .start_x = 0,
            .start_y = 0,
            .end_x = null,
            .end_y = null,
            .rectangle = false,
            .point_map = null,
            .trailing_state = null,
        };
    }
    pub fn format(
        self: PageFormatter,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        _ = try self.formatWithState(writer);
    }
    pub fn formatWithState(
        self: PageFormatter,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!TrailingState {
        switch (self.opts.emit) {
            inline else => |emit| return self.formatWithStateEmit(writer, emit),
        }
    }
    fn formatWithStateEmit(
        self: PageFormatter,
        writer: *std.Io.Writer,
        comptime emit: Format,
    ) std.Io.Writer.Error!TrailingState {
        var blank_rows: usize = 0;
        var blank_cells: usize = 0;
        if (self.trailing_state) |state| {
            if (self.start_y == 0 and self.start_x == 0) {
                blank_rows = state.rows;
                blank_cells = state.cells;
            }
        }
        const start_x: size.CellCountInt = self.start_x;
        if (start_x >= self.page.size.cols) return .{ .rows = blank_rows, .cells = blank_cells };
        const end_x_unclamped: size.CellCountInt = self.end_x orelse self.page.size.cols - 1;
        const end_x = @min(end_x_unclamped, self.page.size.cols - 1);
        const start_y: size.CellCountInt = self.start_y;
        if (start_y >= self.page.size.rows) return .{ .rows = blank_rows, .cells = blank_cells };
        const end_y_unclamped: size.CellCountInt = self.end_y orelse self.page.size.rows - 1;
        if (start_y > end_y_unclamped) return .{ .rows = blank_rows, .cells = blank_cells };
        const end_y = @min(end_y_unclamped, self.page.size.rows - 1);
        if (start_y == end_y and start_x > end_x) {
            return .{ .rows = blank_rows, .cells = blank_cells };
        }
        switch (emit) {
            .plain => {},
            .html => {
                var buf: [1024]u8 = undefined;
                var buf_writer: std.Io.Writer = .fixed(&buf);
                buf_writer.writeAll("<div style=\"font-family: monospace; white-space: pre;") catch return error.WriteFailed;
                if (self.opts.background) |bg| buf_writer.print(
                    "background-color: #{x:0>2}{x:0>2}{x:0>2};",
                    .{ bg.r, bg.g, bg.b },
                ) catch return error.WriteFailed;
                if (self.opts.foreground) |fg| buf_writer.print(
                    "color: #{x:0>2}{x:0>2}{x:0>2};",
                    .{ fg.r, fg.g, fg.b },
                ) catch return error.WriteFailed;
                buf_writer.writeAll("\">") catch return error.WriteFailed;
                const header = buf_writer.buffered();
                try writer.writeAll(header);
                if (self.point_map) |*map| map.map.appendNTimes(
                    map.alloc,
                    .{ .x = 0, .y = 0 },
                    header.len,
                ) catch return error.WriteFailed;
            },
            .vt => {
                var buf: [512]u8 = undefined;
                var buf_writer: std.Io.Writer = .fixed(&buf);
                if (self.opts.foreground) |fg| {
                    buf_writer.print(
                        "\x1b]10;rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\",
                        .{ fg.r, fg.g, fg.b },
                    ) catch return error.WriteFailed;
                }
                if (self.opts.background) |bg| {
                    buf_writer.print(
                        "\x1b]11;rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\",
                        .{ bg.r, bg.g, bg.b },
                    ) catch return error.WriteFailed;
                }
                const header = buf_writer.buffered();
                try writer.writeAll(header);
                if (self.point_map) |*map| map.map.appendNTimes(
                    map.alloc,
                    .{ .x = 0, .y = 0 },
                    header.len,
                ) catch return error.WriteFailed;
            },
        }
        const invalid_style_id: u32 = std.math.maxInt(u32);
        var style: Style = .{};
        var style_id: u32 = 0;
        const cp_map_empty: bool = if (self.opts.codepoint_map) |m|
            m.len == 0
        else
            true;
        var current_hyperlink_id: ?hyperlink.Id = null;
        const page_hyperlinks = self.page.hyperlinkCount() > 0;
        for (start_y..end_y + 1) |y_usize| {
            const y: size.CellCountInt = @intCast(y_usize);
            const row: *Row = self.page.getRow(y);
            const cells: []const Cell = self.page.getCells(row);
            const cells_subset, const row_start_x = cells_subset: {
                const row_end_x: size.CellCountInt = if (self.rectangle or y == end_y)
                    end_x + 1
                else
                    self.page.size.cols;
                const row_start_x: size.CellCountInt = if (start_x > 0 and
                    (self.rectangle or y == start_y))
                start_x: {
                    break :start_x switch (cells[start_x].wide) {
                        .spacer_tail => start_x - 1,
                        .spacer_head => continue,
                        .narrow, .wide => start_x,
                    };
                } else 0;
                const subset = cells[row_start_x..row_end_x];
                break :cells_subset .{ subset, row_start_x };
            };
            if (!Cell.hasTextAny(cells_subset)) {
                blank_rows += 1;
                continue;
            }
            if (blank_rows > 0) {
                if (!style.default()) {
                    try self.formatStyleClose(emit, writer);
                    style = .{};
                    style_id = 0;
                }
                const sequence: []const u8 = switch (emit) {
                    .plain => "\n",
                    .vt => "\r\n",
                    .html => "\n",
                };
                for (0..blank_rows) |_| try writer.writeAll(sequence);
                if (self.point_map) |*map| {
                    const start: Coordinate = if (map.map.items.len > map.base)
                        map.map.items[map.map.items.len - 1]
                    else
                        .{ .x = 0, .y = 0 };
                    map.map.appendNTimes(
                        map.alloc,
                        .{ .x = start.x, .y = start.y },
                        sequence.len,
                    ) catch return error.WriteFailed;
                    for (1..blank_rows) |y_offset_usize| {
                        const y_offset: size.CellCountInt = @intCast(y_offset_usize);
                        map.map.appendNTimes(
                            map.alloc,
                            .{ .x = 0, .y = start.y + y_offset },
                            sequence.len,
                        ) catch return error.WriteFailed;
                    }
                }
                blank_rows = 0;
            }
            if (!row.wrap or !self.opts.unwrap) blank_rows += 1;
            if (!row.wrap_continuation or !self.opts.unwrap) blank_cells = 0;
            var cell_i: usize = 0;
            while (cell_i < cells_subset.len) : (cell_i += 1) {
                const cell: *const Cell = &cells_subset[cell_i];
                const x: size.CellCountInt = @intCast(row_start_x + cell_i);
                if (cp_map_empty) fast: {
                    if (comptime formatStyled(emit)) {
                        if (style_id == invalid_style_id) break :fast;
                    }
                    const consumed = if (formatStyled(emit) and page_hyperlinks)
                        try self.writeCellRun(
                            emit,
                            true,
                            self.point_map != null,
                            writer,
                            cells_subset[cell_i..],
                            x,
                            y,
                            style_id,
                            current_hyperlink_id,
                            &blank_cells,
                        )
                    else
                        try self.writeCellRun(
                            emit,
                            false,
                            self.point_map != null,
                            writer,
                            cells_subset[cell_i..],
                            x,
                            y,
                            style_id,
                            current_hyperlink_id,
                            &blank_cells,
                        );
                    if (consumed == 0) break :fast;
                    cell_i += consumed - 1;
                    continue;
                }
                switch (cell.wide) {
                    .narrow, .wide => {},
                    .spacer_head, .spacer_tail => continue,
                }
                blank: {
                    if (comptime formatStyled(emit)) {
                        if (!cell.isEmpty() or cell.hasStyling()) break :blank;
                    }
                    if (!cell.hasText()) {
                        blank_cells += 1;
                        continue;
                    }
                    if (cell.codepoint() == ' ' and self.opts.trim) {
                        blank_cells += 1;
                        continue;
                    }
                }
                if (blank_cells > 0) {
                    if (comptime emit == .vt) {
                        if (current_hyperlink_id != null) {
                            try self.formatHyperlinkClose(emit, writer);
                            current_hyperlink_id = null;
                        }
                    }
                    try writer.splatByteAll(' ', blank_cells);
                    if (self.point_map) |*map| try self.appendBlankPoints(
                        map,
                        blank_cells,
                        x,
                        y,
                    );
                    blank_cells = 0;
                }
                style: {
                    if (!comptime formatStyled(emit)) break :style;
                    const cell_style_id: u32 = switch (cell.content_tag) {
                        .codepoint, .codepoint_grapheme => cell.style_id,
                        .bg_color_palette, .bg_color_rgb => invalid_style_id,
                    };
                    if (cell_style_id == style_id and
                        cell_style_id != invalid_style_id) break :style;
                    const cell_style = self.cellStyle(cell);
                    if (cell_style_id == invalid_style_id or
                        style_id == invalid_style_id)
                    {
                        if (cell_style.eql(style)) {
                            style_id = cell_style_id;
                            break :style;
                        }
                    }
                    if (!style.default()) switch (emit) {
                        .html => try self.formatStyleClose(emit, writer),
                        .vt => if (cell_style.default()) try self.formatStyleClose(emit, writer),
                        .plain => unreachable,
                    };
                    style = cell_style;
                    style_id = cell_style_id;
                    if (cell_style.default()) break :style;
                    try self.formatStyleOpen(
                        emit,
                        writer,
                        &style,
                    );
                    if (self.point_map) |*map| {
                        var discarding: std.Io.Writer.Discarding = .init(&.{});
                        try self.formatStyleOpen(
                            emit,
                            &discarding.writer,
                            &style,
                        );
                        map.map.appendNTimes(
                            map.alloc,
                            .{ .x = x, .y = y },
                            std.math.cast(
                                usize,
                                discarding.count,
                            ) orelse return error.WriteFailed,
                        ) catch return error.WriteFailed;
                    }
                }
                hyperlink: {
                    if (comptime !formatStyled(emit)) break :hyperlink;
                    if (!page_hyperlinks) break :hyperlink;
                    const link_id_: ?u16 = if (cell.hyperlink)
                        self.page.lookupHyperlink(cell)
                    else
                        null;
                    if (current_hyperlink_id == link_id_) break :hyperlink;
                    if (current_hyperlink_id != null and
                        (emit == .html or link_id_ == null))
                    {
                        try self.formatHyperlinkClose(emit, writer);
                    }
                    current_hyperlink_id = null;
                    const link_id = link_id_ orelse break :hyperlink;
                    current_hyperlink_id = link_id;
                    const link = self.page.hyperlink_set.get(
                        self.page.memory,
                        link_id,
                    );
                    try self.formatHyperlinkOpen(
                        emit,
                        writer,
                        link,
                    );
                    if (self.point_map) |*map| map.map.appendNTimes(
                        map.alloc,
                        .{ .x = x, .y = y },
                        try self.hyperlinkOpenLen(emit, link),
                    ) catch return error.WriteFailed;
                }
                switch (cell.content_tag) {
                    inline .codepoint, .codepoint_grapheme => |tag| {
                        try self.writeCell(tag, emit, writer, cell);
                        if (self.point_map) |*map| {
                            var discarding: std.Io.Writer.Discarding = .init(&.{});
                            try self.writeCell(tag, emit, &discarding.writer, cell);
                            map.map.appendNTimes(
                                map.alloc,
                                .{ .x = x, .y = y },
                                std.math.cast(
                                    usize,
                                    discarding.count,
                                ) orelse return error.WriteFailed,
                            ) catch return error.WriteFailed;
                        }
                    },
                    .bg_color_palette, .bg_color_rgb => {
                        try writer.writeByte(' ');
                        if (self.point_map) |*map| map.map.append(
                            map.alloc,
                            .{ .x = x, .y = y },
                        ) catch return error.WriteFailed;
                    },
                }
            }
        }
        if (!style.default()) try self.formatStyleClose(emit, writer);
        if (current_hyperlink_id != null) try self.formatHyperlinkClose(emit, writer);
        if (comptime emit == .html) {
            const closing = "</div>";
            try writer.writeAll(closing);
            if (self.point_map) |*map| {
                map.map.ensureUnusedCapacity(
                    map.alloc,
                    closing.len,
                ) catch return error.WriteFailed;
                map.map.appendNTimesAssumeCapacity(
                    map.map.items[map.map.items.len - 1],
                    closing.len,
                );
            }
            if (blank_rows >= 1) blank_rows -= 1;
        }
        return .{ .rows = blank_rows, .cells = blank_cells };
    }
    noinline fn writeCellRun(
        self: *const PageFormatter,
        comptime emit: Format,
        comptime hyperlinks: bool,
        track_points: bool,
        writer: *std.Io.Writer,
        cells: []const Cell,
        run_x: size.CellCountInt,
        run_y: size.CellCountInt,
        run_style_id: u32,
        run_hyperlink_id: ?hyperlink.Id,
        blank_cells: *usize,
    ) std.Io.Writer.Error!usize {
        assert(track_points == (self.point_map != null));
        const max_encoding_len = 16;
        var buf: [512]u8 = undefined;
        var len: usize = 0;
        var pending: usize = blank_cells.*;
        var i: usize = 0;
        while (i < cells.len) : (i += 1) {
            const cell = &cells[i];
            switch (cell.wide) {
                .narrow, .wide => {},
                .spacer_head, .spacer_tail => continue,
            }
            switch (cell.content_tag) {
                .codepoint, .codepoint_grapheme => {},
                .bg_color_palette, .bg_color_rgb => break,
            }
            if (comptime formatStyled(emit)) {
                if (cell.style_id != run_style_id) break;
            }
            const cp: u21 = cell.content.codepoint.data;
            if (comptime formatStyled(emit)) {
                if (cp == 0 and cell.wide == .narrow and run_style_id == 0) {
                    pending += 1;
                    continue;
                }
            } else {
                if (cp == 0) {
                    pending += 1;
                    continue;
                }
                if (cp == ' ' and self.opts.trim) {
                    pending += 1;
                    continue;
                }
            }
            if (comptime hyperlinks) {
                if (cell.hyperlink) {
                    const run_id = run_hyperlink_id orelse break;
                    const cell_id = self.page.lookupHyperlink(cell) orelse break;
                    if (cell_id != run_id) break;
                } else if (run_hyperlink_id != null) break;
            }
            const x: size.CellCountInt = @intCast(run_x + i);
            if (pending > 0) {
                if (comptime emit == .vt and hyperlinks) {
                    if (run_hyperlink_id != null) break;
                }
                if (track_points) try self.appendBlankPoints(
                    &self.point_map.?,
                    pending,
                    x,
                    run_y,
                );
                while (pending > 0) {
                    if (len == buf.len) {
                        try writer.writeAll(buf[0..len]);
                        len = 0;
                    }
                    const n = @min(pending, buf.len - len);
                    @memset(buf[len..][0..n], ' ');
                    len += n;
                    pending -= n;
                }
            }
            if (len + max_encoding_len > buf.len) {
                try writer.writeAll(buf[0..len]);
                len = 0;
            }
            var cell_bytes: usize = 0;
            if (cp == 0) {
                buf[len] = ' ';
                len += 1;
                cell_bytes = 1;
            } else {
                cell_bytes = encodeCodepoint(emit, &buf, &len, cp);
                if (cell.content_tag == .codepoint_grapheme) {
                    @branchHint(.unlikely);
                    cell_bytes += try self.writeGraphemeCps(
                        emit,
                        writer,
                        cell,
                        &buf,
                        &len,
                    );
                }
            }
            if (track_points) {
                const map = &self.point_map.?;
                map.map.appendNTimes(
                    map.alloc,
                    .{ .x = x, .y = run_y },
                    cell_bytes,
                ) catch return error.WriteFailed;
            }
        }
        if (len > 0) try writer.writeAll(buf[0..len]);
        blank_cells.* = pending;
        return i;
    }
    noinline fn writeGraphemeCps(
        self: *const PageFormatter,
        comptime emit: Format,
        writer: *std.Io.Writer,
        cell: *const Cell,
        buf: *[512]u8,
        len: *usize,
    ) std.Io.Writer.Error!usize {
        const max_encoding_len = 16;
        var bytes: usize = 0;
        for (self.page.lookupGrapheme(cell).?) |gcp| {
            if (len.* + max_encoding_len > buf.len) {
                try writer.writeAll(buf[0..len.*]);
                len.* = 0;
            }
            bytes += encodeCodepoint(emit, buf, len, gcp);
        }
        return bytes;
    }
    inline fn encodeCodepoint(
        comptime emit: Format,
        buf: *[512]u8,
        len: *usize,
        cp: u21,
    ) usize {
        const start = len.*;
        switch (emit) {
            .plain, .vt => if (cp < 0x80) {
                buf[start] = @intCast(cp);
                len.* += 1;
            } else {
                len.* += std.unicode.utf8Encode(cp, buf[start..][0..4]) catch l: {
                    buf[start..][0..3].* = std.unicode.replacement_character_utf8;
                    break :l 3;
                };
            },
            .html => html: {
                const esc: ?[]const u8 = switch (cp) {
                    '<' => "&lt;",
                    '>' => "&gt;",
                    '&' => "&amp;",
                    '"' => "&quot;",
                    '\'' => "&#39;",
                    else => null,
                };
                if (esc) |s| {
                    @memcpy(buf[start..][0..s.len], s);
                    len.* += s.len;
                    break :html;
                }
                if (cp < 0x80) {
                    buf[start] = @intCast(cp);
                    len.* += 1;
                    break :html;
                }
                buf[start..][0..2].* = "&#".*;
                len.* += 2;
                len.* += fastprint.printDecimal(u21, buf[len.*..], cp);
                buf[len.*] = ';';
                len.* += 1;
            },
        }
        return len.* - start;
    }
    fn appendBlankPoints(
        self: *const PageFormatter,
        map: *const PointMap,
        count: usize,
        x: size.CellCountInt,
        y: size.CellCountInt,
    ) std.Io.Writer.Error!void {
        map.map.ensureUnusedCapacity(
            map.alloc,
            count,
        ) catch return error.WriteFailed;
        var remaining = count;
        var blank_x = x;
        var blank_y = y;
        while (remaining > 0) : (remaining -= 1) {
            if (blank_x > 0) {
                blank_x -= 1;
            } else if (blank_y > 0) {
                blank_y -= 1;
                blank_x = self.page.size.cols - 1;
            } else {
                blank_x = 0;
                blank_y = 0;
            }
            map.map.appendAssumeCapacity(.{ .x = blank_x, .y = blank_y });
        }
    }
    fn writeCell(
        self: PageFormatter,
        comptime tag: Cell.ContentTag,
        comptime emit: Format,
        writer: *std.Io.Writer,
        cell: *const Cell,
    ) !void {
        if (!cell.hasText()) {
            try writer.writeByte(' ');
            return;
        }
        try self.writeCodepointWithReplacement(emit, writer, cell.content.codepoint.data);
        if (comptime tag == .codepoint_grapheme) {
            for (self.page.lookupGrapheme(cell).?) |cp| {
                try self.writeCodepointWithReplacement(emit, writer, cp);
            }
        }
    }
    fn writeCodepointWithReplacement(
        self: PageFormatter,
        comptime emit: Format,
        writer: *std.Io.Writer,
        codepoint: u21,
    ) !void {
        const r_: ?CodepointMap.Replacement = replacement: {
            const map = self.opts.codepoint_map orelse break :replacement null;
            const items = map.items(.range);
            for (0..items.len) |forward_i| {
                const i = items.len - forward_i - 1;
                const range = items[i];
                if (range[0] <= codepoint and codepoint <= range[1]) {
                    const replacements = map.items(.replacement);
                    break :replacement replacements[i];
                }
            }
            break :replacement null;
        };
        const r = r_ orelse return try self.writeCodepoint(
            emit,
            writer,
            codepoint,
        );
        switch (r) {
            .codepoint => |v| try self.writeCodepoint(
                emit,
                writer,
                v,
            ),
            .string => |s| {
                const view = std.unicode.Utf8View.init(s) catch unreachable;
                var it = view.iterator();
                while (it.nextCodepoint()) |cp| try self.writeCodepoint(
                    emit,
                    writer,
                    cp,
                );
            },
        }
    }
    fn writeCodepoint(
        self: PageFormatter,
        comptime emit: Format,
        writer: *std.Io.Writer,
        codepoint: u21,
    ) !void {
        _ = self;
        switch (emit) {
            .plain, .vt => try writer.printUnicodeCodepoint(codepoint),
            .html => {
                switch (codepoint) {
                    '<' => try writer.writeAll("&lt;"),
                    '>' => try writer.writeAll("&gt;"),
                    '&' => try writer.writeAll("&amp;"),
                    '"' => try writer.writeAll("&quot;"),
                    '\'' => try writer.writeAll("&#39;"),
                    else => {
                        if (codepoint < 0x80) {
                            try writer.writeByte(@intCast(codepoint));
                        } else {
                            var buf: [16]u8 = undefined;
                            buf[0..2].* = "&#".*;
                            var len: usize = 2 + fastprint.printDecimal(u21, buf[2..], codepoint);
                            buf[len] = ';';
                            len += 1;
                            try writer.writeAll(buf[0..len]);
                        }
                    },
                }
            },
        }
    }
    fn cellStyle(
        self: *const PageFormatter,
        cell: *const Cell,
    ) Style {
        return switch (cell.content_tag) {
            inline .codepoint, .codepoint_grapheme => if (!cell.hasStyling())
                .{}
            else
                self.page.styles.get(
                    self.page.memory,
                    cell.style_id,
                ).*,
            .bg_color_palette => .{
                .bg_color = .{
                    .palette = cell.content.color_palette.data,
                },
            },
            .bg_color_rgb => .{
                .bg_color = .{
                    .rgb = .{
                        .r = cell.content.color_rgb.r,
                        .g = cell.content.color_rgb.g,
                        .b = cell.content.color_rgb.b,
                    },
                },
            },
        };
    }
    fn formatStyleOpen(
        self: PageFormatter,
        comptime emit: Format,
        writer: *std.Io.Writer,
        style: *const Style,
    ) std.Io.Writer.Error!void {
        switch (emit) {
            .plain => unreachable,
            .vt => {
                var formatter = style.formatterVt();
                formatter.palette = self.opts.palette;
                try formatter.format(writer);
            },
            .html => {
                var formatter = style.formatterHtml();
                formatter.palette = self.opts.palette;
                try writer.writeAll("<div style=\"display: inline;");
                try formatter.format(writer);
                try writer.writeAll("\">");
            },
        }
    }
    fn formatStyleClose(
        self: PageFormatter,
        comptime emit: Format,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const str: []const u8 = switch (emit) {
            .plain => return,
            .vt => "\x1b[0m",
            .html => "</div>",
        };
        try writer.writeAll(str);
        if (self.point_map) |*m| {
            assert(m.map.items.len > 0);
            m.map.ensureUnusedCapacity(
                m.alloc,
                str.len,
            ) catch return error.WriteFailed;
            m.map.appendNTimesAssumeCapacity(
                m.map.items[m.map.items.len - 1],
                str.len,
            );
        }
    }
    fn formatHyperlinkOpen(
        self: PageFormatter,
        comptime emit: Format,
        writer: *std.Io.Writer,
        link: *const hyperlink.PageEntry,
    ) std.Io.Writer.Error!void {
        const uri = link.uri.slice(self.page.memory);
        switch (emit) {
            .plain => unreachable,
            .vt => switch (link.id) {
                .explicit => |id| try writer.print(
                    "\x1b]8;id={s};{s}\x1b\\",
                    .{ id.slice(self.page.memory), uri },
                ),
                .implicit => try writer.print("\x1b]8;;{s}\x1b\\", .{uri}),
            },
            .html => {
                try writer.writeAll("<a href=\"");
                for (uri) |byte| try self.writeCodepoint(
                    emit,
                    writer,
                    byte,
                );
                try writer.writeAll("\">");
            },
        }
    }
    fn hyperlinkOpenLen(
        self: PageFormatter,
        comptime emit: Format,
        link: *const hyperlink.PageEntry,
    ) std.Io.Writer.Error!usize {
        switch (emit) {
            .plain => unreachable,
            .vt => return link.uri.len + switch (link.id) {
                .explicit => |id| id.len + 10,
                .implicit => 7,
            },
            .html => {
                var discarding: std.Io.Writer.Discarding = .init(&.{});
                try self.formatHyperlinkOpen(emit, &discarding.writer, link);
                return std.math.cast(
                    usize,
                    discarding.count,
                ) orelse error.WriteFailed;
            },
        }
    }
    fn formatHyperlinkClose(
        self: PageFormatter,
        comptime emit: Format,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const str: []const u8 = switch (emit) {
            .html => "</a>",
            .vt => "\x1b]8;;\x1b\\",
            .plain => return,
        };
        try writer.writeAll(str);
        if (self.point_map) |*m| {
            assert(m.map.items.len > 0);
            m.map.ensureUnusedCapacity(
                m.alloc,
                str.len,
            ) catch return error.WriteFailed;
            m.map.appendNTimesAssumeCapacity(
                m.map.items[m.map.items.len - 1],
                str.len,
            );
        }
    }
};
test "Page plain single line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello, world");
    const pages = &t.screens.active.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hello, world", output);
    try testing.expectEqual(@as(usize, page.size.rows), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 12), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..output.len) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 0 },
        point_map.items[i],
    );
}
test "Page plain single line soft-wrapped unwrapped" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 3,
        .rows = 5,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello!");
    const pages = &t.screens.active.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .{
        .emit = .plain,
        .unwrap = true,
    });
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    _ = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hello!", output);
    try testing.expectEqual(output.len, point_map.items.len);
    try testing.expectEqual(
        Coordinate{ .x = 0, .y = 0 },
        point_map.items[0],
    );
    try testing.expectEqual(
        Coordinate{ .x = 1, .y = 0 },
        point_map.items[1],
    );
    try testing.expectEqual(
        Coordinate{ .x = 2, .y = 0 },
        point_map.items[2],
    );
    try testing.expectEqual(
        Coordinate{ .x = 0, .y = 1 },
        point_map.items[3],
    );
    try testing.expectEqual(
        Coordinate{ .x = 1, .y = 1 },
        point_map.items[4],
    );
    try testing.expectEqual(
        Coordinate{ .x = 2, .y = 1 },
        point_map.items[5],
    );
}
test "Page plain single wide char" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("1A⚡");
    const pages = &t.screens.active.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    {
        builder.clearRetainingCapacity();
        point_map.clearRetainingCapacity();
        const state = try formatter.formatWithState(&builder.writer);
        const output = builder.writer.buffered();
        try testing.expectEqualStrings("1A⚡", output);
        try testing.expectEqual(@as(usize, page.size.rows), state.rows);
        try testing.expectEqual(@as(usize, page.size.cols - 4), state.cells);
        try testing.expectEqual(output.len, point_map.items.len);
        for (2..output.len) |i| try testing.expectEqual(
            Coordinate{ .x = 2, .y = 0 },
            point_map.items[i],
        );
    }
    {
        builder.clearRetainingCapacity();
        point_map.clearRetainingCapacity();
        formatter.start_x = 2;
        const state = try formatter.formatWithState(&builder.writer);
        const output = builder.writer.buffered();
        try testing.expectEqualStrings("⚡", output);
        try testing.expectEqual(@as(usize, page.size.rows), state.rows);
        try testing.expectEqual(@as(usize, page.size.cols - 4), state.cells);
        try testing.expectEqual(output.len, point_map.items.len);
        for (0..output.len) |i| try testing.expectEqual(
            Coordinate{ .x = 2, .y = 0 },
            point_map.items[i],
        );
    }
    {
        builder.clearRetainingCapacity();
        point_map.clearRetainingCapacity();
        formatter.start_x = 3;
        const state = try formatter.formatWithState(&builder.writer);
        const output = builder.writer.buffered();
        try testing.expectEqualStrings("⚡", output);
        try testing.expectEqual(@as(usize, page.size.rows), state.rows);
        try testing.expectEqual(@as(usize, page.size.cols - 4), state.cells);
        try testing.expectEqual(output.len, point_map.items.len);
        for (0..output.len) |i| try testing.expectEqual(
            Coordinate{ .x = 2, .y = 0 },
            point_map.items[i],
        );
    }
}
test "Page plain single wide char soft-wrapped unwrapped" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 3,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("1A⚡");
    const pages = &t.screens.active.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    formatter.opts.unwrap = true;
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    {
        builder.clearRetainingCapacity();
        point_map.clearRetainingCapacity();
        const state = try formatter.formatWithState(&builder.writer);
        const output = builder.writer.buffered();
        try testing.expectEqualStrings("1A⚡", output);
        try testing.expectEqual(@as(usize, page.size.rows - 1), state.rows);
        try testing.expectEqual(@as(usize, page.size.cols - 2), state.cells);
        try testing.expectEqual(output.len, point_map.items.len);
        for (2..output.len) |i| try testing.expectEqual(
            Coordinate{ .x = 0, .y = 1 },
            point_map.items[i],
        );
    }
    {
        builder.clearRetainingCapacity();
        point_map.clearRetainingCapacity();
        formatter.start_x = 2;
        const state = try formatter.formatWithState(&builder.writer);
        const output = builder.writer.buffered();
        try testing.expectEqualStrings("⚡", output);
        try testing.expectEqual(@as(usize, page.size.rows - 1), state.rows);
        try testing.expectEqual(@as(usize, page.size.cols - 2), state.cells);
        try testing.expectEqual(output.len, point_map.items.len);
        for (0..output.len) |i| try testing.expectEqual(
            Coordinate{ .x = 0, .y = 1 },
            point_map.items[i],
        );
    }
    {
        builder.clearRetainingCapacity();
        point_map.clearRetainingCapacity();
        formatter.start_y = 1;
        formatter.start_x = 1;
        const state = try formatter.formatWithState(&builder.writer);
        const output = builder.writer.buffered();
        try testing.expectEqualStrings("⚡", output);
        try testing.expectEqual(@as(usize, page.size.rows - 1), state.rows);
        try testing.expectEqual(@as(usize, page.size.cols - 2), state.cells);
        try testing.expectEqual(output.len, point_map.items.len);
        for (0..output.len) |i| try testing.expectEqual(
            Coordinate{ .x = 0, .y = 1 },
            point_map.items[i],
        );
    }
}
test "Page plain multiline" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello\r\nworld");
    const pages = &t.screens.active.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hello\nworld", output);
    try testing.expectEqual(@as(usize, page.size.rows - 1), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 5), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..5) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 0 },
        point_map.items[i],
    );
    try testing.expectEqual(Coordinate{ .x = 4, .y = 0 }, point_map.items[5]); 
    for (0..5) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 1 },
        point_map.items[6 + i],
    );
}
test "Page plain multiline rectangle" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello\r\nworld");
    const pages = &t.screens.active.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    formatter.start_x = 1;
    formatter.end_x = 3;
    formatter.rectangle = true;
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("ell\norl", output);
    try testing.expectEqual(@as(usize, page.size.rows - 1), state.rows);
    try testing.expectEqual(@as(usize, 0), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..3) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i + 1), .y = 0 },
        point_map.items[i],
    );
    try testing.expectEqual(Coordinate{ .x = 3, .y = 0 }, point_map.items[3]); 
    for (0..3) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i + 1), .y = 1 },
        point_map.items[4 + i],
    );
}
test "Page plain multi blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello\r\n\r\n\r\nworld");
    const pages = &t.screens.active.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hello\n\n\nworld", output);
    try testing.expectEqual(@as(usize, page.size.rows - 3), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 5), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..5) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 0 },
        point_map.items[i],
    );
    try testing.expectEqual(Coordinate{ .x = 4, .y = 0 }, point_map.items[5]); 
    try testing.expectEqual(Coordinate{ .x = 0, .y = 1 }, point_map.items[6]); 
    try testing.expectEqual(Coordinate{ .x = 0, .y = 2 }, point_map.items[7]); 
    for (0..5) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 3 },
        point_map.items[8 + i],
    );
}
test "Page plain trailing blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello\r\nworld\r\n\r\n");
    const pages = &t.screens.active.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hello\nworld", output);
    try testing.expectEqual(@as(usize, page.size.rows - 1), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 5), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..5) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 0 },
        point_map.items[i],
    );
    try testing.expectEqual(Coordinate{ .x = 4, .y = 0 }, point_map.items[5]); 
    for (0..5) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 1 },
        point_map.items[6 + i],
    );
}
test "Page plain trailing whitespace" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello   \r\nworld   ");
    const pages = &t.screens.active.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hello\nworld", output);
    try testing.expectEqual(@as(usize, page.size.rows - 1), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 5), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..5) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 0 },
        point_map.items[i],
    );
    try testing.expectEqual(Coordinate{ .x = 4, .y = 0 }, point_map.items[5]); 
    for (0..5) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 1 },
        point_map.items[6 + i],
    );
}
test "Page plain trailing whitespace no trim" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello   \r\nworld  ");
    const pages = &t.screens.active.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .{
        .emit = .plain,
        .trim = false,
    });
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hello   \nworld  ", output);
    try testing.expectEqual(@as(usize, page.size.rows - 1), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 7), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..8) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 0 },
        point_map.items[i],
    );
    try testing.expectEqual(Coordinate{ .x = 7, .y = 0 }, point_map.items[8]); 
    for (0..7) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 1 },
        point_map.items[9 + i],
    );
}
test "Page plain with prior trailing state rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello");
    const pages = &t.screens.active.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    formatter.trailing_state = .{ .rows = 2, .cells = 0 };
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("\n\nhello", output);
    try testing.expectEqual(@as(usize, page.size.rows), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 5), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    try testing.expectEqual(Coordinate{ .x = 0, .y = 0 }, point_map.items[0]); 
    try testing.expectEqual(Coordinate{ .x = 0, .y = 1 }, point_map.items[1]); 
    for (0..5) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 0 },
        point_map.items[2 + i],
    );
}
test "Page plain with prior trailing state cells no wrapped line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello");
    const pages = &t.screens.active.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    formatter.trailing_state = .{ .rows = 0, .cells = 3 };
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hello", output);
    try testing.expectEqual(@as(usize, page.size.rows), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 5), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..5) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 0 },
        point_map.items[i],
    );
}
test "Page plain with prior trailing state cells with wrap continuation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("world");
    const pages = &t.screens.active.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);
    const page = pages.pages.last.?.page();
    const row = page.getRow(0);
    row.wrap_continuation = true;
    var formatter: PageFormatter = .init(page, .{ .emit = .plain, .unwrap = true });
    formatter.trailing_state = .{ .rows = 0, .cells = 3 };
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("   world", output);
    try testing.expectEqual(@as(usize, page.size.rows), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 5), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    try testing.expectEqual(Coordinate{ .x = 0, .y = 0 }, point_map.items[0]); 
    try testing.expectEqual(Coordinate{ .x = 0, .y = 0 }, point_map.items[1]); 
    try testing.expectEqual(Coordinate{ .x = 0, .y = 0 }, point_map.items[2]); 
    for (0..5) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 0 },
        point_map.items[3 + i],
    );
}
test "Page plain soft-wrapped without unwrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello world test");
    const pages = &t.screens.active.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hello worl\nd test", output);
    try testing.expectEqual(@as(usize, page.size.rows - 1), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 6), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..10) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 0 },
        point_map.items[i],
    );
    try testing.expectEqual(Coordinate{ .x = 9, .y = 0 }, point_map.items[10]); 
    for (0..6) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 1 },
        point_map.items[11 + i],
    );
}
test "Page plain soft-wrapped with unwrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello world test");
    const pages = &t.screens.active.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .{ .emit = .plain, .unwrap = true });
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hello world test", output);
    try testing.expectEqual(@as(usize, page.size.rows - 1), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 6), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..10) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 0 },
        point_map.items[i],
    );
    for (0..6) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 1 },
        point_map.items[10 + i],
    );
}
test "Page plain soft-wrapped 3 lines without unwrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello world this is a test");
    const pages = &t.screens.active.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hello worl\nd this is\na test", output);
    try testing.expectEqual(@as(usize, page.size.rows - 2), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 6), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..10) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 0 },
        point_map.items[i],
    );
    try testing.expectEqual(Coordinate{ .x = 9, .y = 0 }, point_map.items[10]); 
    for (0..9) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 1 },
        point_map.items[11 + i],
    );
    try testing.expectEqual(Coordinate{ .x = 8, .y = 1 }, point_map.items[20]); 
    for (0..6) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 2 },
        point_map.items[21 + i],
    );
}
test "Page plain soft-wrapped 3 lines with unwrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello world this is a test");
    const pages = &t.screens.active.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .{ .emit = .plain, .unwrap = true });
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hello world this is a test", output);
    try testing.expectEqual(@as(usize, page.size.rows - 2), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 6), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..10) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 0 },
        point_map.items[i],
    );
    for (0..10) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 1 },
        point_map.items[10 + i],
    );
    for (0..6) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 2 },
        point_map.items[20 + i],
    );
}
test "Page plain start_y subset" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello\r\nworld\r\ntest");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    formatter.start_y = 1;
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("world\ntest", output);
    try testing.expectEqual(@as(usize, page.size.rows - 2), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 4), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..5) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 1 },
        point_map.items[i],
    );
    try testing.expectEqual(Coordinate{ .x = 4, .y = 1 }, point_map.items[5]); 
    for (0..4) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 2 },
        point_map.items[6 + i],
    );
}
test "Page plain end_y subset" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello\r\nworld\r\ntest");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    formatter.end_y = 1;
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hello\nworld", output);
    try testing.expectEqual(@as(usize, 1), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 5), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..5) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 0 },
        point_map.items[i],
    );
    try testing.expectEqual(Coordinate{ .x = 4, .y = 0 }, point_map.items[5]); 
    for (0..5) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 1 },
        point_map.items[6 + i],
    );
}
test "Page plain start_y and end_y range" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello\r\nworld\r\ntest\r\nfoo");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    formatter.start_y = 1;
    formatter.end_y = 2;
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("world\ntest", output);
    try testing.expectEqual(@as(usize, 1), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 4), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..5) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 1 },
        point_map.items[i],
    );
    try testing.expectEqual(Coordinate{ .x = 4, .y = 1 }, point_map.items[5]); 
    for (0..4) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 2 },
        point_map.items[6 + i],
    );
}
test "Page plain start_y out of bounds" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    formatter.start_y = 30;
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("", output);
    try testing.expectEqual(@as(usize, 0), state.rows);
    try testing.expectEqual(@as(usize, 0), state.cells);
    try testing.expectEqual(@as(usize, 0), point_map.items.len);
}
test "Page plain end_y greater than rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    formatter.end_y = 30;
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hello", output);
    try testing.expectEqual(@as(usize, page.size.rows), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 5), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..5) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 0 },
        point_map.items[i],
    );
}
test "Page plain end_y less than start_y" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    formatter.start_y = 5;
    formatter.end_y = 2;
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("", output);
    try testing.expectEqual(@as(usize, 0), state.rows);
    try testing.expectEqual(@as(usize, 0), state.cells);
    try testing.expectEqual(@as(usize, 0), point_map.items.len);
}
test "Page plain start_x on first row only" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello world");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    formatter.start_x = 6;
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("world", output);
    try testing.expectEqual(@as(usize, page.size.rows), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 11), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..5) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i + 6), .y = 0 },
        point_map.items[i],
    );
}
test "Page plain end_x on last row only" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("first line\r\nsecond line\r\nthird line");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    formatter.end_y = 2;
    formatter.end_x = 4;
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("first line\nsecond line\nthird", output);
    try testing.expectEqual(@as(usize, 1), state.rows);
    try testing.expectEqual(@as(usize, 0), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..10) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 0 },
        point_map.items[i],
    );
    try testing.expectEqual(Coordinate{ .x = 9, .y = 0 }, point_map.items[10]); 
    for (0..11) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 1 },
        point_map.items[11 + i],
    );
    try testing.expectEqual(Coordinate{ .x = 10, .y = 1 }, point_map.items[22]); 
    for (0..5) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 2 },
        point_map.items[23 + i],
    );
}
test "Page plain start_x and end_x multiline" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello world\r\ntest case\r\nfoo bar");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    formatter.start_x = 6;
    formatter.end_y = 2;
    formatter.end_x = 2;
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("world\ntest case\nfoo", output);
    try testing.expectEqual(@as(usize, 1), state.rows);
    try testing.expectEqual(@as(usize, 0), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..5) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i + 6), .y = 0 },
        point_map.items[i],
    );
    try testing.expectEqual(Coordinate{ .x = 10, .y = 0 }, point_map.items[5]); 
    for (0..9) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 1 },
        point_map.items[6 + i],
    );
    try testing.expectEqual(Coordinate{ .x = 8, .y = 1 }, point_map.items[15]); 
    for (0..3) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 2 },
        point_map.items[16 + i],
    );
}
test "Page plain start_x out of bounds" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    formatter.start_x = 100;
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("", output);
    try testing.expectEqual(@as(usize, 0), state.rows);
    try testing.expectEqual(@as(usize, 0), state.cells);
    try testing.expectEqual(@as(usize, 0), point_map.items.len);
}
test "Page plain end_x greater than cols" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    formatter.end_x = 100;
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hello", output);
    try testing.expectEqual(@as(usize, page.size.rows), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 5), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..5) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 0 },
        point_map.items[i],
    );
}
test "Page plain end_x less than start_x single row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    formatter.start_x = 10;
    formatter.end_y = 0;
    formatter.end_x = 5;
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("", output);
    try testing.expectEqual(@as(usize, 0), state.rows);
    try testing.expectEqual(@as(usize, 0), state.cells);
    try testing.expectEqual(@as(usize, 0), point_map.items.len);
}
test "Page plain start_y non-zero ignores trailing state" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello\r\nworld");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    formatter.start_y = 1;
    formatter.trailing_state = .{ .rows = 5, .cells = 10 };
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("world", output);
    try testing.expectEqual(@as(usize, page.size.rows - 1), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 5), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..5) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 1 },
        point_map.items[i],
    );
}
test "Page plain start_x non-zero ignores trailing state" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello world");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    formatter.start_x = 6;
    formatter.trailing_state = .{ .rows = 2, .cells = 8 };
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("world", output);
    try testing.expectEqual(@as(usize, page.size.rows), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 11), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..5) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i + 6), .y = 0 },
        point_map.items[i],
    );
}
test "Page plain start_y and start_x zero uses trailing state" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    formatter.start_y = 0;
    formatter.start_x = 0;
    formatter.trailing_state = .{ .rows = 2, .cells = 0 };
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("\n\nhello", output);
    try testing.expectEqual(@as(usize, page.size.rows), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 5), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    try testing.expectEqual(Coordinate{ .x = 0, .y = 0 }, point_map.items[0]); 
    try testing.expectEqual(Coordinate{ .x = 0, .y = 1 }, point_map.items[1]); 
    for (0..5) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 0 },
        point_map.items[2 + i],
    );
}
test "Page plain single line with styling" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello, \x1b[1mworld\x1b[0m");
    const pages = &t.screens.active.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .plain);
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hello, world", output);
    try testing.expectEqual(@as(usize, page.size.rows), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 12), state.cells);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..12) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 0 },
        point_map.items[i],
    );
}
test "Page VT single line plain text" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .vt);
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hello", output);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..5) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 0 },
        point_map.items[i],
    );
}
test "Page VT single line with bold" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[1mhello\x1b[0m");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .vt);
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("\x1b[0m\x1b[1mhello\x1b[0m", output);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..8) |i| try testing.expectEqual(
        Coordinate{ .x = 0, .y = 0 },
        point_map.items[i],
    );
    for (0..5) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 0 },
        point_map.items[8 + i],
    );
}
test "Page VT multiple styles" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[1mhello \x1b[3mworld\x1b[0m");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .vt);
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("\x1b[0m\x1b[1mhello \x1b[0m\x1b[1m\x1b[3mworld\x1b[0m", output);
    try testing.expectEqual(output.len, point_map.items.len);
}
test "Page VT with foreground color" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[31mred\x1b[0m");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .vt);
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("\x1b[0m\x1b[38;5;1mred\x1b[0m", output);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..13) |i| try testing.expectEqual(
        Coordinate{ .x = 0, .y = 0 },
        point_map.items[i],
    );
    for (0..3) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 0 },
        point_map.items[13 + i],
    );
}
test "Page VT with background and foreground colors" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .{
        .emit = .vt,
        .background = .{ .r = 0x12, .g = 0x34, .b = 0x56 },
        .foreground = .{ .r = 0xab, .g = 0xcd, .b = 0xef },
    });
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings(
        "\x1b]10;rgb:ab/cd/ef\x1b\\\x1b]11;rgb:12/34/56\x1b\\hello",
        output,
    );
}
test "Page VT multi-line with styles" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[1mfirst\x1b[0m\r\n\x1b[3msecond\x1b[0m");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .vt);
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("\x1b[0m\x1b[1mfirst\x1b[0m\r\n\x1b[0m\x1b[3msecond\x1b[0m", output);
    try testing.expectEqual(output.len, point_map.items.len);
}
test "Page VT duplicate style not emitted twice" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[1mhel\x1b[1mlo\x1b[0m");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .vt);
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("\x1b[0m\x1b[1mhello\x1b[0m", output);
    try testing.expectEqual(output.len, point_map.items.len);
}
test "PageList plain single line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello, world");
    var pin_map: PinMap.Map = .empty;
    defer pin_map.deinit(alloc);
    var formatter: PageListFormatter = .init(&t.screens.active.pages, .plain);
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hello, world", output);
    try testing.expectEqual(output.len, pin_map.count());
    const node = t.screens.active.pages.pages.first.?;
    for (0..output.len) |i| try testing.expectEqual(
        Pin{ .node = node, .x = @intCast(i), .y = 0 },
        pin_map.get(i).?,
    );
}
test "PageList plain spanning two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    const pages = &t.screens.active.pages;
    const first_page_rows = pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| s.nextSlice("\r\n");
    s.nextSlice("page one");
    try testing.expect(pages.pages.first == pages.pages.last);
    s.nextSlice("\r\n");
    try testing.expect(pages.pages.first != pages.pages.last);
    s.nextSlice("page two");
    var pin_map: PinMap.Map = .empty;
    defer pin_map.deinit(alloc);
    var formatter: PageListFormatter = .init(pages, .plain);
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&builder.writer);
    const full_output = builder.writer.buffered();
    const output = std.mem.trimStart(u8, full_output, "\n");
    try testing.expectEqualStrings("page one\npage two", output);
    try testing.expectEqual(full_output.len, pin_map.count());
    const first_node = pages.pages.first.?;
    const last_node = pages.pages.last.?;
    const trimmed_count = full_output.len - output.len;
    for (0..trimmed_count) |i| {
        try testing.expectEqual(first_node, pin_map.get(i).?.node);
    }
    for (0..8) |i| {
        const idx = trimmed_count + i;
        try testing.expectEqual(first_node, pin_map.get(idx).?.node);
        try testing.expectEqual(@as(size.CellCountInt, @intCast(i)), pin_map.get(idx).?.x);
    }
    try testing.expectEqual(last_node, pin_map.get(trimmed_count + 8).?.node);
    for (0..8) |i| {
        const idx = trimmed_count + 9 + i;
        try testing.expectEqual(last_node, pin_map.get(idx).?.node);
        try testing.expectEqual(@as(size.CellCountInt, @intCast(i)), pin_map.get(idx).?.x);
    }
}
test "PageList soft-wrapped line spanning two pages without unwrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    const pages = &t.screens.active.pages;
    const first_page_rows = pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| s.nextSlice("\r\n");
    s.nextSlice("hello world test");
    try testing.expect(pages.pages.first != pages.pages.last);
    var pin_map: PinMap.Map = .empty;
    defer pin_map.deinit(alloc);
    var formatter: PageListFormatter = .init(pages, .plain);
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&builder.writer);
    const full_output = builder.writer.buffered();
    const output = std.mem.trimStart(u8, full_output, "\n");
    try testing.expectEqualStrings("hello worl\nd test", output);
    try testing.expectEqual(full_output.len, pin_map.count());
    const first_node = pages.pages.first.?;
    const last_node = pages.pages.last.?;
    const trimmed_count = full_output.len - output.len;
    for (0..trimmed_count) |i| {
        try testing.expectEqual(first_node, pin_map.get(i).?.node);
    }
    for (0..10) |i| {
        const idx = trimmed_count + i;
        try testing.expectEqual(first_node, pin_map.get(idx).?.node);
    }
    try testing.expectEqual(last_node, pin_map.get(trimmed_count + 10).?.node);
    for (0..6) |i| {
        const idx = trimmed_count + 11 + i;
        try testing.expectEqual(last_node, pin_map.get(idx).?.node);
    }
}
test "PageList soft-wrapped line spanning two pages with unwrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    const pages = &t.screens.active.pages;
    const first_page_rows = pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| s.nextSlice("\r\n");
    s.nextSlice("hello world test");
    try testing.expect(pages.pages.first != pages.pages.last);
    var pin_map: PinMap.Map = .empty;
    defer pin_map.deinit(alloc);
    var formatter: PageListFormatter = .init(pages, .{ .emit = .plain, .unwrap = true });
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&builder.writer);
    const full_output = builder.writer.buffered();
    const output = std.mem.trimStart(u8, full_output, "\r\n");
    try testing.expectEqualStrings("hello world test", output);
    try testing.expectEqual(full_output.len, pin_map.count());
    const first_node = pages.pages.first.?;
    const last_node = pages.pages.last.?;
    const trimmed_count = full_output.len - output.len;
    for (0..trimmed_count) |i| {
        try testing.expectEqual(first_node, pin_map.get(i).?.node);
    }
    for (0..10) |i| {
        const idx = trimmed_count + i;
        try testing.expectEqual(first_node, pin_map.get(idx).?.node);
    }
    for (0..6) |i| {
        const idx = trimmed_count + 10 + i;
        try testing.expectEqual(last_node, pin_map.get(idx).?.node);
    }
}
test "PageList selection ending on spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    for ([_]bool{ false, true }) |across_pages| {
        var t = try Terminal.init(io, alloc, .{ .cols = 3, .rows = 3 });
        defer t.deinit(alloc);
        var s = t.vtStream();
        defer s.deinit();
        const pages = &t.screens.active.pages;
        const first_node = pages.pages.first.?;
        const y = if (across_pages) first_node.capacity().rows - 1 else 0;
        for (0..y) |_| s.nextSlice("\r\n");
        s.nextSlice("1A⚡Z");
        const start: Pin = .{ .node = first_node, .x = 0, .y = y };
        const end: Pin = .{ .node = first_node, .x = 2, .y = y };
        var glyph = end.down(1).?;
        glyph.x = 0;
        try testing.expectEqual(across_pages, glyph.node != first_node);
        var builder: std.Io.Writer.Allocating = .init(alloc);
        defer builder.deinit();
        var pin_map: PinMap.Map = .empty;
        defer pin_map.deinit(alloc);
        var formatter: PageListFormatter = .init(pages, .{ .emit = .plain, .unwrap = true });
        formatter.bottom_right = end;
        formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
        for ([_]bool{ true, false }) |only_glyph| {
            builder.clearRetainingCapacity();
            pin_map.clearRetainingCapacity();
            formatter.top_left = if (only_glyph) end else start;
            try formatter.format(&builder.writer);
            const output = builder.writer.buffered();
            try testing.expectEqualStrings(if (only_glyph) "⚡" else "1A⚡", output);
            try testing.expectEqual(output.len, pin_map.count());
            for (output.len - "⚡".len..output.len) |i| {
                try testing.expectEqual(glyph, pin_map.get(i).?);
            }
        }
        for ([_]struct { unwrap: bool, rectangle: bool }{
            .{ .unwrap = false, .rectangle = false },
            .{ .unwrap = true, .rectangle = true },
        }) |case| {
            builder.clearRetainingCapacity();
            formatter.opts.unwrap = case.unwrap;
            formatter.rectangle = case.rectangle;
            try formatter.format(&builder.writer);
            try testing.expectEqualStrings("1A", builder.writer.buffered());
        }
    }
}
test "PageList VT spanning two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    const pages = &t.screens.active.pages;
    const first_page_rows = pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| s.nextSlice("\r\n");
    s.nextSlice("\x1b[1mpage one");
    try testing.expect(pages.pages.first == pages.pages.last);
    s.nextSlice("\r\n");
    try testing.expect(pages.pages.first != pages.pages.last);
    s.nextSlice("page two");
    var pin_map: PinMap.Map = .empty;
    defer pin_map.deinit(alloc);
    var formatter: PageListFormatter = .init(pages, .vt);
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&builder.writer);
    const full_output = builder.writer.buffered();
    const output = std.mem.trimStart(u8, full_output, "\r\n");
    try testing.expectEqualStrings("\x1b[0m\x1b[1mpage one\x1b[0m\r\n\x1b[0m\x1b[1mpage two\x1b[0m", output);
    try testing.expectEqual(full_output.len, pin_map.count());
    const first_node = pages.pages.first.?;
    const last_node = pages.pages.last.?;
    var first_count: usize = 0;
    var last_count: usize = 0;
    for (0..pin_map.count()) |byte_i| {
        const pin = pin_map.get(byte_i).?;
        if (pin.node == first_node) first_count += 1;
        if (pin.node == last_node) last_count += 1;
    }
    try testing.expect(first_count > 0);
    try testing.expect(last_count > 0);
}
test "PageList plain with x offset on single page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello world\r\ntest case\r\nfoo bar");
    const pages = &t.screens.active.pages;
    const node = pages.pages.first.?;
    var pin_map: PinMap.Map = .empty;
    defer pin_map.deinit(alloc);
    var formatter: PageListFormatter = .init(pages, .plain);
    formatter.top_left = .{ .node = node, .y = 0, .x = 6 };
    formatter.bottom_right = .{ .node = node, .y = 2, .x = 2 };
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("world\ntest case\nfoo", output);
    try testing.expectEqual(output.len, pin_map.count());
    for (0..pin_map.count()) |byte_i| {
        const pin = pin_map.get(byte_i).?;
        try testing.expectEqual(node, pin.node);
    }
    for (0..5) |i| {
        try testing.expectEqual(@as(size.CellCountInt, @intCast(6 + i)), pin_map.get(i).?.x);
        try testing.expectEqual(@as(size.CellCountInt, 0), pin_map.get(i).?.y);
    }
}
test "PageList plain with x offset spanning two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    const pages = &t.screens.active.pages;
    const first_page_rows = pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| s.nextSlice("\r\n");
    s.nextSlice("hello world");
    try testing.expect(pages.pages.first == pages.pages.last);
    s.nextSlice("\r\n");
    try testing.expect(pages.pages.first != pages.pages.last);
    s.nextSlice("foo bar test");
    const first_node = pages.pages.first.?;
    const last_node = pages.pages.last.?;
    var pin_map: PinMap.Map = .empty;
    defer pin_map.deinit(alloc);
    var formatter: PageListFormatter = .init(pages, .plain);
    formatter.top_left = .{ .node = first_node, .y = first_node.rows() - 1, .x = 6 };
    formatter.bottom_right = .{ .node = last_node, .y = 1, .x = 2 };
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&builder.writer);
    const full_output = builder.writer.buffered();
    const output = std.mem.trimStart(u8, full_output, "\n");
    try testing.expectEqualStrings("world\nfoo", output);
    try testing.expectEqual(full_output.len, pin_map.count());
    const trimmed_count = full_output.len - output.len;
    for (0..5) |i| {
        const idx = trimmed_count + i;
        try testing.expectEqual(first_node, pin_map.get(idx).?.node);
        try testing.expectEqual(@as(size.CellCountInt, @intCast(6 + i)), pin_map.get(idx).?.x);
    }
    try testing.expectEqual(last_node, pin_map.get(trimmed_count + 5).?.node);
    for (0..3) |i| {
        const idx = trimmed_count + 6 + i;
        try testing.expectEqual(last_node, pin_map.get(idx).?.node);
        try testing.expectEqual(@as(size.CellCountInt, @intCast(i)), pin_map.get(idx).?.x);
    }
}
test "PageList plain with start_x only" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello world");
    const pages = &t.screens.active.pages;
    const node = pages.pages.first.?;
    var pin_map: PinMap.Map = .empty;
    defer pin_map.deinit(alloc);
    var formatter: PageListFormatter = .init(pages, .plain);
    formatter.top_left = .{ .node = node, .y = 0, .x = 6 };
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("world", output);
    try testing.expectEqual(output.len, pin_map.count());
    for (0..5) |i| {
        try testing.expectEqual(node, pin_map.get(i).?.node);
        try testing.expectEqual(@as(size.CellCountInt, @intCast(6 + i)), pin_map.get(i).?.x);
        try testing.expectEqual(@as(size.CellCountInt, 0), pin_map.get(i).?.y);
    }
}
test "PageList plain with end_x only" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello world\r\ntest");
    const pages = &t.screens.active.pages;
    const node = pages.pages.first.?;
    var pin_map: PinMap.Map = .empty;
    defer pin_map.deinit(alloc);
    var formatter: PageListFormatter = .init(pages, .plain);
    formatter.bottom_right = .{ .node = node, .y = 1, .x = 2 };
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hello world\ntes", output);
    try testing.expectEqual(output.len, pin_map.count());
    for (0..11) |i| {
        try testing.expectEqual(node, pin_map.get(i).?.node);
        try testing.expectEqual(@as(size.CellCountInt, @intCast(i)), pin_map.get(i).?.x);
        try testing.expectEqual(@as(size.CellCountInt, 0), pin_map.get(i).?.y);
    }
    try testing.expectEqual(node, pin_map.get(11).?.node);
    for (0..3) |i| {
        try testing.expectEqual(node, pin_map.get(12 + i).?.node);
        try testing.expectEqual(@as(size.CellCountInt, @intCast(i)), pin_map.get(12 + i).?.x);
        try testing.expectEqual(@as(size.CellCountInt, 1), pin_map.get(12 + i).?.y);
    }
}
test "PageList plain rectangle basic" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 30,
        .rows = 5,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Lorem ipsum dolor\r\n");
    s.nextSlice("sit amet, consectetur\r\n");
    s.nextSlice("adipiscing elit, sed do\r\n");
    s.nextSlice("eiusmod tempor incididunt\r\n");
    s.nextSlice("ut labore et dolore");
    const pages = &t.screens.active.pages;
    var formatter: PageListFormatter = .init(pages, .plain);
    formatter.top_left = pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?;
    formatter.bottom_right = pages.pin(.{ .screen = .{ .x = 6, .y = 3 } }).?;
    formatter.rectangle = true;
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    const expected =
        \\t ame
        \\ipisc
        \\usmod
    ;
    try testing.expectEqualStrings(expected, output);
}
test "PageList plain rectangle with EOL" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 30,
        .rows = 5,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Lorem ipsum dolor\r\n");
    s.nextSlice("sit amet, consectetur\r\n");
    s.nextSlice("adipiscing elit, sed do\r\n");
    s.nextSlice("eiusmod tempor incididunt\r\n");
    s.nextSlice("ut labore et dolore");
    const pages = &t.screens.active.pages;
    var formatter: PageListFormatter = .init(pages, .plain);
    formatter.top_left = pages.pin(.{ .screen = .{ .x = 12, .y = 0 } }).?;
    formatter.bottom_right = pages.pin(.{ .screen = .{ .x = 26, .y = 4 } }).?;
    formatter.rectangle = true;
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    const expected =
        \\dolor
        \\nsectetur
        \\lit, sed do
        \\or incididunt
        \\ dolore
    ;
    try testing.expectEqualStrings(expected, output);
}
test "PageList plain rectangle more complex with breaks" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 30,
        .rows = 8,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Lorem ipsum dolor\r\n");
    s.nextSlice("sit amet, consectetur\r\n");
    s.nextSlice("adipiscing elit, sed do\r\n");
    s.nextSlice("eiusmod tempor incididunt\r\n");
    s.nextSlice("ut labore et dolore\r\n");
    s.nextSlice("\r\n");
    s.nextSlice("magna aliqua. Ut enim\r\n");
    s.nextSlice("ad minim veniam, quis");
    const pages = &t.screens.active.pages;
    var formatter: PageListFormatter = .init(pages, .plain);
    formatter.top_left = pages.pin(.{ .screen = .{ .x = 11, .y = 2 } }).?;
    formatter.bottom_right = pages.pin(.{ .screen = .{ .x = 26, .y = 7 } }).?;
    formatter.rectangle = true;
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    const expected =
        \\elit, sed do
        \\por incididunt
        \\t dolore
        \\
        \\a. Ut enim
        \\niam, quis
    ;
    try testing.expectEqualStrings(expected, output);
}
test "TerminalFormatter plain no selection" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello\r\nworld");
    const formatter: TerminalFormatter = .init(&t, .plain);
    try formatter.format(&builder.writer);
    try testing.expectEqualStrings("hello\nworld", builder.writer.buffered());
}
test "TerminalFormatter vt with palette" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]4;0;rgb:12/34/56\x1b\\");
    s.nextSlice("\x1b]4;1;rgb:ab/cd/ef\x1b\\");
    s.nextSlice("\x1b]4;255;rgb:ff/00/ff\x1b\\");
    s.nextSlice("test");
    const formatter: TerminalFormatter = .init(&t, .vt);
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    var t2 = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t2.deinit(alloc);
    var s2 = t2.vtStream();
    defer s2.deinit();
    s2.nextSlice(output);
    try testing.expectEqual(t.colors.palette.current[0], t2.colors.palette.current[0]);
    try testing.expectEqual(t.colors.palette.current[1], t2.colors.palette.current[1]);
    try testing.expectEqual(t.colors.palette.current[255], t2.colors.palette.current[255]);
}
test "TerminalFormatter with selection" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("line1\r\nline2\r\nline3");
    var formatter: TerminalFormatter = .init(&t, .plain);
    formatter.content = .{ .selection = .init(
        t.screens.active.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        t.screens.active.pages.pin(.{ .active = .{ .x = 4, .y = 1 } }).?,
        false,
    ) };
    try formatter.format(&builder.writer);
    try testing.expectEqualStrings("line2", builder.writer.buffered());
}
test "TerminalFormatter plain with pin_map" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello, world");
    var pin_map: PinMap.Map = .empty;
    defer pin_map.deinit(alloc);
    var formatter: TerminalFormatter = .init(&t, .plain);
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hello, world", output);
    try testing.expectEqual(output.len, pin_map.count());
    const node = t.screens.active.pages.pages.first.?;
    for (0..output.len) |i| try testing.expectEqual(
        Pin{ .node = node, .x = @intCast(i), .y = 0 },
        pin_map.get(i).?,
    );
}
test "TerminalFormatter plain multiline with pin_map" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello\r\nworld");
    var pin_map: PinMap.Map = .empty;
    defer pin_map.deinit(alloc);
    var formatter: TerminalFormatter = .init(&t, .plain);
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hello\nworld", output);
    try testing.expectEqual(output.len, pin_map.count());
    const node = t.screens.active.pages.pages.first.?;
    for (0..5) |i| {
        try testing.expectEqual(node, pin_map.get(i).?.node);
        try testing.expectEqual(@as(size.CellCountInt, @intCast(i)), pin_map.get(i).?.x);
        try testing.expectEqual(@as(size.CellCountInt, 0), pin_map.get(i).?.y);
    }
    try testing.expectEqual(node, pin_map.get(5).?.node);
    for (0..5) |i| {
        const idx = 6 + i;
        try testing.expectEqual(node, pin_map.get(idx).?.node);
        try testing.expectEqual(@as(size.CellCountInt, @intCast(i)), pin_map.get(idx).?.x);
        try testing.expectEqual(@as(size.CellCountInt, 1), pin_map.get(idx).?.y);
    }
}
test "TerminalFormatter vt with palette and pin_map" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]4;0;rgb:12/34/56\x1b\\");
    s.nextSlice("test");
    var pin_map: PinMap.Map = .empty;
    defer pin_map.deinit(alloc);
    var formatter: TerminalFormatter = .init(&t, .vt);
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqual(output.len, pin_map.count());
    const node = t.screens.active.pages.pages.first.?;
    for (0..output.len) |i| {
        try testing.expectEqual(node, pin_map.get(i).?.node);
    }
}
test "TerminalFormatter with selection and pin_map" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("line1\r\nline2\r\nline3");
    var pin_map: PinMap.Map = .empty;
    defer pin_map.deinit(alloc);
    var formatter: TerminalFormatter = .init(&t, .plain);
    formatter.content = .{ .selection = .init(
        t.screens.active.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        t.screens.active.pages.pin(.{ .active = .{ .x = 4, .y = 1 } }).?,
        false,
    ) };
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("line2", output);
    try testing.expectEqual(output.len, pin_map.count());
    const node = t.screens.active.pages.pages.first.?;
    for (0..5) |i| {
        try testing.expectEqual(node, pin_map.get(i).?.node);
        try testing.expectEqual(@as(size.CellCountInt, @intCast(i)), pin_map.get(i).?.x);
        try testing.expectEqual(@as(size.CellCountInt, 1), pin_map.get(i).?.y);
    }
}
test "Screen plain single line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello, world");
    var pin_map: PinMap.Map = .empty;
    defer pin_map.deinit(alloc);
    var formatter: ScreenFormatter = .init(t.screens.active, .plain);
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hello, world", output);
    try testing.expectEqual(output.len, pin_map.count());
    const node = t.screens.active.pages.pages.first.?;
    for (0..output.len) |i| try testing.expectEqual(
        Pin{ .node = node, .x = @intCast(i), .y = 0 },
        pin_map.get(i).?,
    );
}
test "Screen plain multiline" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello\r\nworld");
    var pin_map: PinMap.Map = .empty;
    defer pin_map.deinit(alloc);
    var formatter: ScreenFormatter = .init(t.screens.active, .plain);
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hello\nworld", output);
    try testing.expectEqual(output.len, pin_map.count());
    const node = t.screens.active.pages.pages.first.?;
    for (0..5) |i| {
        try testing.expectEqual(node, pin_map.get(i).?.node);
        try testing.expectEqual(@as(size.CellCountInt, @intCast(i)), pin_map.get(i).?.x);
        try testing.expectEqual(@as(size.CellCountInt, 0), pin_map.get(i).?.y);
    }
    try testing.expectEqual(node, pin_map.get(5).?.node);
    for (0..5) |i| {
        const idx = 6 + i;
        try testing.expectEqual(node, pin_map.get(idx).?.node);
        try testing.expectEqual(@as(size.CellCountInt, @intCast(i)), pin_map.get(idx).?.x);
        try testing.expectEqual(@as(size.CellCountInt, 1), pin_map.get(idx).?.y);
    }
}
test "Screen plain with selection" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("line1\r\nline2\r\nline3");
    var pin_map: PinMap.Map = .empty;
    defer pin_map.deinit(alloc);
    var formatter: ScreenFormatter = .init(t.screens.active, .plain);
    formatter.content = .{ .selection = .init(
        t.screens.active.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        t.screens.active.pages.pin(.{ .active = .{ .x = 4, .y = 1 } }).?,
        false,
    ) };
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("line2", output);
    try testing.expectEqual(output.len, pin_map.count());
    const node = t.screens.active.pages.pages.first.?;
    for (0..5) |i| {
        try testing.expectEqual(node, pin_map.get(i).?.node);
        try testing.expectEqual(@as(size.CellCountInt, @intCast(i)), pin_map.get(i).?.x);
        try testing.expectEqual(@as(size.CellCountInt, 1), pin_map.get(i).?.y);
    }
}
test "Screen vt with cursor position" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello\r\nworld");
    var pin_map: PinMap.Map = .empty;
    defer pin_map.deinit(alloc);
    var formatter: ScreenFormatter = .init(t.screens.active, .vt);
    formatter.extra.cursor = true;
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    var t2 = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t2.deinit(alloc);
    var s2 = t2.vtStream();
    defer s2.deinit();
    s2.nextSlice(output);
    try testing.expectEqual(t.screens.active.cursor.x, t2.screens.active.cursor.x);
    try testing.expectEqual(t.screens.active.cursor.y, t2.screens.active.cursor.y);
    try testing.expectEqual(output.len, pin_map.count());
    const node = t.screens.active.pages.pages.first.?;
    const content_len = "hello\r\nworld".len;
    for (0..content_len) |i| {
        try testing.expectEqual(node, pin_map.get(i).?.node);
    }
    for (content_len..output.len) |i| {
        try testing.expectEqual(node, pin_map.get(i).?.node);
    }
}
test "Terminal vt cursor preserves pending wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var source = try Terminal.init(io, alloc, .{
        .cols = 4,
        .rows = 2,
    });
    defer source.deinit(alloc);
    var source_stream = source.vtStream();
    defer source_stream.deinit();
    source_stream.nextSlice("abcd");
    try testing.expect(source.screens.active.cursor.pending_wrap);
    var pin_map: PinMap.Map = .empty;
    defer pin_map.deinit(alloc);
    var formatter: TerminalFormatter = .init(&source, .vt);
    formatter.extra = .none;
    formatter.extra.screen.cursor = true;
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&builder.writer);
    try testing.expectEqual(builder.writer.buffered().len, pin_map.count());
    var target = try Terminal.init(io, alloc, .{
        .cols = 4,
        .rows = 2,
    });
    defer target.deinit(alloc);
    var target_stream = target.vtStream();
    defer target_stream.deinit();
    target_stream.nextSlice(builder.writer.buffered());
    try testing.expectEqual(
        source.screens.active.cursor.pending_wrap,
        target.screens.active.cursor.pending_wrap,
    );
    source_stream.nextSlice("X");
    target_stream.nextSlice("X");
    const source_contents = try source.screens.active.dumpStringAlloc(
        alloc,
        .{ .screen = .{} },
    );
    defer alloc.free(source_contents);
    const target_contents = try target.screens.active.dumpStringAlloc(
        alloc,
        .{ .screen = .{} },
    );
    defer alloc.free(target_contents);
    try testing.expectEqualStrings(source_contents, target_contents);
}
test "Terminal vt cursor preserves pending wrap over a blank cell" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var source = try Terminal.init(io, alloc, .{
        .cols = 4,
        .rows = 2,
    });
    defer source.deinit(alloc);
    var source_stream = source.vtStream();
    defer source_stream.deinit();
    source_stream.nextSlice("abcd\x1b7\x1b[2K\x1b8");
    try testing.expect(source.screens.active.cursor.pending_wrap);
    try testing.expect(!source.screens.active.cursor.page_cell.hasText());
    var pin_map: PinMap.Map = .empty;
    defer pin_map.deinit(alloc);
    var formatter: TerminalFormatter = .init(&source, .vt);
    formatter.extra = .none;
    formatter.extra.screen.cursor = true;
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&builder.writer);
    try testing.expectEqual(builder.writer.buffered().len, pin_map.count());
    var target = try Terminal.init(io, alloc, .{
        .cols = 4,
        .rows = 2,
    });
    defer target.deinit(alloc);
    var target_stream = target.vtStream();
    defer target_stream.deinit();
    target_stream.nextSlice(builder.writer.buffered());
    try testing.expectEqual(
        source.screens.active.cursor.pending_wrap,
        target.screens.active.cursor.pending_wrap,
    );
    try testing.expect(!target.screens.active.cursor.page_cell.hasText());
    var target_builder: std.Io.Writer.Allocating = .init(alloc);
    defer target_builder.deinit();
    var target_formatter: TerminalFormatter = .init(&target, .vt);
    target_formatter.extra = .none;
    target_formatter.extra.screen.cursor = true;
    try target_formatter.format(&target_builder.writer);
    try testing.expectEqualStrings(
        builder.writer.buffered(),
        target_builder.writer.buffered(),
    );
    source_stream.nextSlice("X");
    target_stream.nextSlice("X");
    const source_contents = try source.screens.active.dumpStringAlloc(
        alloc,
        .{ .screen = .{} },
    );
    defer alloc.free(source_contents);
    const target_contents = try target.screens.active.dumpStringAlloc(
        alloc,
        .{ .screen = .{} },
    );
    defer alloc.free(target_contents);
    try testing.expectEqualStrings(source_contents, target_contents);
}
test "Terminal vt cursor preserves pending wrap after a wide character" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var source = try Terminal.init(io, alloc, .{
        .cols = 4,
        .rows = 2,
    });
    defer source.deinit(alloc);
    var source_stream = source.vtStream();
    defer source_stream.deinit();
    source_stream.nextSlice("ab\u{1F600}");
    try testing.expect(source.screens.active.cursor.pending_wrap);
    try testing.expectEqual(.spacer_tail, source.screens.active.cursor.page_cell.wide);
    var formatter: TerminalFormatter = .init(&source, .vt);
    formatter.extra = .none;
    formatter.extra.screen.cursor = true;
    try formatter.format(&builder.writer);
    var target = try Terminal.init(io, alloc, .{
        .cols = 4,
        .rows = 2,
    });
    defer target.deinit(alloc);
    var target_stream = target.vtStream();
    defer target_stream.deinit();
    target_stream.nextSlice(builder.writer.buffered());
    try testing.expectEqual(
        source.screens.active.cursor.pending_wrap,
        target.screens.active.cursor.pending_wrap,
    );
    source_stream.nextSlice("X");
    target_stream.nextSlice("X");
    const source_contents = try source.screens.active.dumpStringAlloc(
        alloc,
        .{ .screen = .{} },
    );
    defer alloc.free(source_contents);
    const target_contents = try target.screens.active.dumpStringAlloc(
        alloc,
        .{ .screen = .{} },
    );
    defer alloc.free(target_contents);
    try testing.expectEqualStrings(source_contents, target_contents);
}
test "Screen vt with style" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[1;31mhello");
    var pin_map: PinMap.Map = .empty;
    defer pin_map.deinit(alloc);
    var formatter: ScreenFormatter = .init(t.screens.active, .vt);
    formatter.extra.style = true;
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    var t2 = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t2.deinit(alloc);
    var s2 = t2.vtStream();
    defer s2.deinit();
    s2.nextSlice(output);
    try testing.expect(t.screens.active.cursor.style.eql(t2.screens.active.cursor.style));
    try testing.expectEqual(output.len, pin_map.count());
    const node = t.screens.active.pages.pages.first.?;
    for (0..output.len) |i| {
        try testing.expectEqual(node, pin_map.get(i).?.node);
    }
}
test "Screen vt with hyperlink" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]8;;http://example.com\x1b\\hello");
    var pin_map: PinMap.Map = .empty;
    defer pin_map.deinit(alloc);
    var formatter: ScreenFormatter = .init(t.screens.active, .vt);
    formatter.extra.hyperlink = true;
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    var t2 = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t2.deinit(alloc);
    var s2 = t2.vtStream();
    defer s2.deinit();
    s2.nextSlice(output);
    const has_link1 = t.screens.active.cursor.hyperlink != null;
    const has_link2 = t2.screens.active.cursor.hyperlink != null;
    try testing.expectEqual(has_link1, has_link2);
    if (has_link1) {
        const link1 = t.screens.active.cursor.hyperlink.?;
        const link2 = t2.screens.active.cursor.hyperlink.?;
        try testing.expectEqualStrings(link1.uri, link2.uri);
    }
    try testing.expectEqual(output.len, pin_map.count());
    const node = t.screens.active.pages.pages.first.?;
    for (0..output.len) |i| {
        try testing.expectEqual(node, pin_map.get(i).?.node);
    }
}
test "Page VT with hyperlinks" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]8;;https://example.com\x1b\\link text\x1b]8;;\x1b\\ normal");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    var formatter: PageFormatter = .init(page, .vt);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings(
        "\x1b]8;;https://example.com\x1b\\link text\x1b]8;;\x1b\\ normal",
        output,
    );
    try testing.expectEqual(output.len, point_map.items.len);
}
test "Page VT with explicit hyperlink id" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]8;id=a;https://example.com\x1b\\one\x1b]8;;\x1b\\");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .vt);
    try formatter.format(&builder.writer);
    try testing.expectEqualStrings(
        "\x1b]8;id=a;https://example.com\x1b\\one\x1b]8;;\x1b\\",
        builder.writer.buffered(),
    );
}
test "Page VT with hyperlink across rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]8;;https://example.com\x1b\\ab\r\ncd\x1b]8;;\x1b\\");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .vt);
    try formatter.format(&builder.writer);
    try testing.expectEqualStrings(
        "\x1b]8;;https://example.com\x1b\\ab\r\ncd\x1b]8;;\x1b\\",
        builder.writer.buffered(),
    );
}
test "Page VT closes a hyperlink before blank cells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]8;;https://example.com\x1b\\ab\x1b[5Gcd\x1b]8;;\x1b\\");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .vt);
    try formatter.format(&builder.writer);
    try testing.expectEqualStrings(
        "\x1b]8;;https://example.com\x1b\\ab\x1b]8;;\x1b\\" ++
            "  " ++
            "\x1b]8;;https://example.com\x1b\\cd\x1b]8;;\x1b\\",
        builder.writer.buffered(),
    );
}
test "Page VT switches between hyperlinks without closing" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]8;;https://a.example\x1b\\ab\x1b]8;;https://b.example\x1b\\cd\x1b]8;;\x1b\\");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    var formatter: PageFormatter = .init(page, .vt);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    try formatter.format(&builder.writer);
    const open_a = "\x1b]8;;https://a.example\x1b\\";
    const open_b = "\x1b]8;;https://b.example\x1b\\";
    const close = "\x1b]8;;\x1b\\";
    try testing.expectEqualStrings(
        open_a ++ "ab" ++ open_b ++ "cd" ++ close,
        builder.writer.buffered(),
    );
    var expected: std.ArrayList(Coordinate) = .empty;
    defer expected.deinit(alloc);
    try expected.appendNTimes(alloc, .{ .x = 0, .y = 0 }, open_a.len + 1);
    try expected.append(alloc, .{ .x = 1, .y = 0 });
    try expected.appendNTimes(alloc, .{ .x = 2, .y = 0 }, open_b.len + 1);
    try expected.appendNTimes(alloc, .{ .x = 3, .y = 0 }, 1 + close.len);
    try testing.expectEqualSlices(Coordinate, expected.items, point_map.items);
}
test "Page VT closes a hyperlink on a row without hyperlinks" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]8;;https://example.com\x1b\\ab\x1b]8;;\x1b\\\r\ncd");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .vt);
    try formatter.format(&builder.writer);
    try testing.expectEqualStrings(
        "\x1b]8;;https://example.com\x1b\\ab\r\n\x1b]8;;\x1b\\cd",
        builder.writer.buffered(),
    );
}
test "Terminal vt restores hyperlinks of cells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var source = try Terminal.init(io, alloc, .{
        .cols = 20,
        .rows = 3,
    });
    defer source.deinit(alloc);
    var source_stream = source.vtStream();
    defer source_stream.deinit();
    source_stream.nextSlice(
        "\x1b]8;;https://a.example\x1b\\aa\x1b]8;;\x1b\\ " ++
            "\x1b]8;id=x;https://b.example\x1b\\bb\x1b[5Gbb\x1b]8;;\x1b\\\r\n" ++
            "\x1b]8;;https://a.example\x1b\\\x1b[1mcc\x1b[0m\x1b]8;;\x1b\\ plain",
    );
    var formatter: TerminalFormatter = .init(&source, .vt);
    try formatter.format(&builder.writer);
    var target = try Terminal.init(io, alloc, .{
        .cols = 20,
        .rows = 3,
    });
    defer target.deinit(alloc);
    var target_stream = target.vtStream();
    defer target_stream.deinit();
    target_stream.nextSlice(builder.writer.buffered());
    for (0..3) |y| for (0..20) |x| {
        const pt: @import("point.zig").Point = .{ .active = .{
            .x = @intCast(x),
            .y = @intCast(y),
        } };
        const a = source.screens.active.pages.getCell(pt).?;
        const b = target.screens.active.pages.getCell(pt).?;
        try testing.expectEqual(a.cell.hyperlink, b.cell.hyperlink);
        if (!a.cell.hyperlink) continue;
        const a_page = a.node.page();
        const b_page = b.node.page();
        const a_link = a_page.hyperlink_set.get(
            a_page.memory,
            a_page.lookupHyperlink(a.cell).?,
        );
        const b_link = b_page.hyperlink_set.get(
            b_page.memory,
            b_page.lookupHyperlink(b.cell).?,
        );
        try testing.expectEqualStrings(
            a_link.uri.slice(a_page.memory),
            b_link.uri.slice(b_page.memory),
        );
        try testing.expectEqual(
            std.meta.activeTag(a_link.id),
            std.meta.activeTag(b_link.id),
        );
        if (a_link.id == .explicit) try testing.expectEqualStrings(
            a_link.id.explicit.slice(a_page.memory),
            b_link.id.explicit.slice(b_page.memory),
        );
    };
}
test "Screen vt with protection" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[1\"qhello");
    var pin_map: PinMap.Map = .empty;
    defer pin_map.deinit(alloc);
    var formatter: ScreenFormatter = .init(t.screens.active, .vt);
    formatter.extra.protection = true;
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    var t2 = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t2.deinit(alloc);
    var s2 = t2.vtStream();
    defer s2.deinit();
    s2.nextSlice(output);
    try testing.expectEqual(t.screens.active.cursor.protected, t2.screens.active.cursor.protected);
    try testing.expectEqual(output.len, pin_map.count());
    const node = t.screens.active.pages.pages.first.?;
    for (0..output.len) |i| {
        try testing.expectEqual(node, pin_map.get(i).?.node);
    }
}
test "Screen vt with kitty keyboard" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[=3;1uhello");
    var pin_map: PinMap.Map = .empty;
    defer pin_map.deinit(alloc);
    var formatter: ScreenFormatter = .init(t.screens.active, .vt);
    formatter.extra.kitty_keyboard = true;
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    var t2 = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t2.deinit(alloc);
    var s2 = t2.vtStream();
    defer s2.deinit();
    s2.nextSlice(output);
    const flags1 = t.screens.active.kitty_keyboard.current().int();
    const flags2 = t2.screens.active.kitty_keyboard.current().int();
    try testing.expectEqual(flags1, flags2);
    try testing.expectEqual(output.len, pin_map.count());
    const node = t.screens.active.pages.pages.first.?;
    for (0..output.len) |i| {
        try testing.expectEqual(node, pin_map.get(i).?.node);
    }
}
test "Screen vt with charsets" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b(0\x0ehello");
    var pin_map: PinMap.Map = .empty;
    defer pin_map.deinit(alloc);
    var formatter: ScreenFormatter = .init(t.screens.active, .vt);
    formatter.extra.charsets = true;
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    var t2 = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t2.deinit(alloc);
    var s2 = t2.vtStream();
    defer s2.deinit();
    s2.nextSlice(output);
    try testing.expectEqual(t.screens.active.charset.gl, t2.screens.active.charset.gl);
    try testing.expectEqual(t.screens.active.charset.gr, t2.screens.active.charset.gr);
    try testing.expectEqual(
        t.screens.active.charset.charsets.get(.G0),
        t2.screens.active.charset.charsets.get(.G0),
    );
    try testing.expectEqual(output.len, pin_map.count());
    const node = t.screens.active.pages.pages.first.?;
    for (0..output.len) |i| {
        try testing.expectEqual(node, pin_map.get(i).?.node);
    }
}
test "Terminal vt with scrolling region" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[6;21rhello");
    var formatter: TerminalFormatter = .init(&t, .vt);
    formatter.extra.scrolling_region = true;
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    var t2 = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t2.deinit(alloc);
    var s2 = t2.vtStream();
    defer s2.deinit();
    s2.nextSlice(output);
    try testing.expectEqual(t.scrolling_region.top, t2.scrolling_region.top);
    try testing.expectEqual(t.scrolling_region.bottom, t2.scrolling_region.bottom);
    try testing.expectEqual(t.scrolling_region.left, t2.scrolling_region.left);
    try testing.expectEqual(t.scrolling_region.right, t2.scrolling_region.right);
}
test "Terminal vt with cursor in origin mode" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    const streams = [_][]const u8{
        "\x1b[3;8r\x1b[?6h\x1b[2;5H",
        "\x1b[?69h\x1b[3;8r\x1b[4;15s\x1b[?6h\x1b[2;3H",
        "\x1b[3;8r\x1b[?6h\x1b[2;20Hx",
    };
    for (streams) |stream| {
        var builder: std.Io.Writer.Allocating = .init(alloc);
        defer builder.deinit();
        var t = try Terminal.init(io, alloc, .{ .cols = 20, .rows = 10 });
        defer t.deinit(alloc);
        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice(stream);
        var formatter: TerminalFormatter = .init(&t, .vt);
        formatter.extra = .all;
        try formatter.format(&builder.writer);
        var t2 = try Terminal.init(io, alloc, .{ .cols = 20, .rows = 10 });
        defer t2.deinit(alloc);
        var s2 = t2.vtStream();
        defer s2.deinit();
        s2.nextSlice(builder.writer.buffered());
        try testing.expect(t2.modes.get(.origin));
        try testing.expectEqual(t.screens.active.cursor.x, t2.screens.active.cursor.x);
        try testing.expectEqual(t.screens.active.cursor.y, t2.screens.active.cursor.y);
        try testing.expectEqual(
            t.screens.active.cursor.pending_wrap,
            t2.screens.active.cursor.pending_wrap,
        );
    }
}
test "Terminal vt with cursor in origin mode without the region" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{ .cols = 20, .rows = 10 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[3;8r\x1b[?6h\x1b[2;5H");
    var formatter: TerminalFormatter = .init(&t, .vt);
    formatter.extra = .all;
    formatter.extra.scrolling_region = false;
    try formatter.format(&builder.writer);
    try testing.expect(std.mem.indexOf(u8, builder.writer.buffered(), "\x1b[4;5H") != null);
}
test "Terminal vt with modes" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[?2004h"); 
    s.nextSlice("\x1b[?1000h"); 
    s.nextSlice("\x1b[?7l"); 
    s.nextSlice("hello");
    var formatter: TerminalFormatter = .init(&t, .vt);
    formatter.extra.modes = true;
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    var t2 = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t2.deinit(alloc);
    var s2 = t2.vtStream();
    defer s2.deinit();
    s2.nextSlice(output);
    try testing.expectEqual(t.modes.get(.bracketed_paste), t2.modes.get(.bracketed_paste));
    try testing.expectEqual(t.modes.get(.mouse_event_normal), t2.modes.get(.mouse_event_normal));
    try testing.expectEqual(t.modes.get(.wraparound), t2.modes.get(.wraparound));
}
test "Terminal vt with tabstops" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[3g"); 
    s.nextSlice("\x1b[5G\x1bH"); 
    s.nextSlice("\x1b[15G\x1bH"); 
    s.nextSlice("\x1b[30G\x1bH"); 
    s.nextSlice("\x1b[Hhello");
    var pin_map: PinMap.Map = .empty;
    defer pin_map.deinit(alloc);
    var formatter: TerminalFormatter = .init(&t, .vt);
    formatter.extra.tabstops = true;
    formatter.extra.screen.cursor = true;
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    var t2 = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t2.deinit(alloc);
    var s2 = t2.vtStream();
    defer s2.deinit();
    s2.nextSlice(output);
    try testing.expectEqual(t.tabstops.get(4), t2.tabstops.get(4));
    try testing.expectEqual(t.tabstops.get(14), t2.tabstops.get(14));
    try testing.expectEqual(t.tabstops.get(29), t2.tabstops.get(29));
    try testing.expect(t2.tabstops.get(4)); 
    try testing.expect(t2.tabstops.get(14)); 
    try testing.expect(t2.tabstops.get(29)); 
    try testing.expect(!t2.tabstops.get(8)); 
    for ("hello", 0..) |expected, col| {
        const cell = t2.screens.active.pages.getCell(.{
            .screen = .{ .x = @intCast(col), .y = 0 },
        }).?;
        try testing.expectEqual(expected, cell.cell.codepoint());
    }
    try testing.expectEqual(t.screens.active.cursor.x, t2.screens.active.cursor.x);
    try testing.expectEqual(t.screens.active.cursor.y, t2.screens.active.cursor.y);
    try testing.expectEqual(output.len, pin_map.count());
}
test "Terminal vt with keyboard modes" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[>4;2m");
    s.nextSlice("hello");
    var formatter: TerminalFormatter = .init(&t, .vt);
    formatter.extra.keyboard = true;
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    var t2 = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t2.deinit(alloc);
    var s2 = t2.vtStream();
    defer s2.deinit();
    s2.nextSlice(output);
    try testing.expectEqual(t.flags.modify_other_keys_2, t2.flags.modify_other_keys_2);
    try testing.expect(t2.flags.modify_other_keys_2);
}
test "Terminal vt with pwd" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]7;file://host/home/user\x1b\\hello");
    var formatter: TerminalFormatter = .init(&t, .vt);
    formatter.extra.pwd = true;
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    var t2 = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t2.deinit(alloc);
    var s2 = t2.vtStream();
    defer s2.deinit();
    s2.nextSlice(output);
    try testing.expectEqualStrings(t.pwd.items, t2.pwd.items);
}
test "Page html with multiple styles" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[1mbold\x1b[3mitalic\x1b[0mnormal");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .{ .emit = .html });
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings(
        "<div style=\"font-family: monospace; white-space: pre;\">" ++
            "<div style=\"display: inline;font-weight: bold;\">bold</div>" ++
            "<div style=\"display: inline;font-weight: bold;font-style: italic;\">italic</div>" ++
            "normal" ++
            "</div>",
        output,
    );
}
test "Page html plain text" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello, world");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .{ .emit = .html });
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings(
        "<div style=\"font-family: monospace; white-space: pre;\">hello, world</div>",
        output,
    );
}
test "Page html with colors" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[31;44mcolored");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .{ .emit = .html });
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings(
        "<div style=\"font-family: monospace; white-space: pre;\">" ++
            "<div style=\"display: inline;color: var(--vt-palette-1);background-color: var(--vt-palette-4);\">colored</div>" ++
            "</div>",
        output,
    );
}
test "TerminalFormatter html with palette" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]4;0;rgb:12/34/56\x1b\\");
    s.nextSlice("\x1b]4;1;rgb:ab/cd/ef\x1b\\");
    s.nextSlice("\x1b]4;255;rgb:ff/00/ff\x1b\\");
    s.nextSlice("test");
    var formatter: TerminalFormatter = .init(&t, .{ .emit = .html });
    formatter.extra.palette = true;
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "<style>:root{") != null);
    try testing.expect(std.mem.indexOf(u8, output, "--vt-palette-0: #123456;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "--vt-palette-1: #abcdef;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "--vt-palette-255: #ff00ff;") != null);
    try testing.expect(std.mem.indexOf(u8, output, "}</style>") != null);
    try testing.expect(std.mem.indexOf(u8, output, "test") != null);
}
test "Page html with background and foreground colors" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .{
        .emit = .html,
        .background = .{ .r = 0x12, .g = 0x34, .b = 0x56 },
        .foreground = .{ .r = 0xab, .g = 0xcd, .b = 0xef },
    });
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings(
        "<div style=\"font-family: monospace; white-space: pre;background-color: #123456;color: #abcdef;\">hello</div>",
        output,
    );
}
test "Page html with escaping" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("<tag>&\"'text");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .{ .emit = .html });
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings(
        "<div style=\"font-family: monospace; white-space: pre;\">&lt;tag&gt;&amp;&quot;&#39;text</div>",
        output,
    );
    try testing.expectEqual(output.len, point_map.items.len);
    const wrapper_start = "<div style=\"font-family: monospace; white-space: pre;\">";
    const wrapper_start_len = wrapper_start.len;
    for (0..wrapper_start_len) |i| try testing.expectEqual(Coordinate{ .x = 0, .y = 0 }, point_map.items[i]);
    const offset = wrapper_start_len;
    for (0..4) |i| try testing.expectEqual(Coordinate{ .x = 0, .y = 0 }, point_map.items[offset + i]);
    try testing.expectEqual(Coordinate{ .x = 1, .y = 0 }, point_map.items[offset + 4]);
    try testing.expectEqual(Coordinate{ .x = 2, .y = 0 }, point_map.items[offset + 5]);
    try testing.expectEqual(Coordinate{ .x = 3, .y = 0 }, point_map.items[offset + 6]);
    for (0..4) |i| try testing.expectEqual(Coordinate{ .x = 4, .y = 0 }, point_map.items[offset + 7 + i]);
    for (0..5) |i| try testing.expectEqual(Coordinate{ .x = 5, .y = 0 }, point_map.items[offset + 11 + i]);
    for (0..6) |i| try testing.expectEqual(Coordinate{ .x = 6, .y = 0 }, point_map.items[offset + 16 + i]);
    for (0..5) |i| try testing.expectEqual(Coordinate{ .x = 7, .y = 0 }, point_map.items[offset + 22 + i]);
    try testing.expectEqual(Coordinate{ .x = 8, .y = 0 }, point_map.items[offset + 27]);
    try testing.expectEqual(Coordinate{ .x = 9, .y = 0 }, point_map.items[offset + 28]);
    try testing.expectEqual(Coordinate{ .x = 10, .y = 0 }, point_map.items[offset + 29]);
    try testing.expectEqual(Coordinate{ .x = 11, .y = 0 }, point_map.items[offset + 30]);
}
test "Page html with unicode as numeric entities" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("╰─ ❯");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .{ .emit = .html });
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings(
        "<div style=\"font-family: monospace; white-space: pre;\">&#9584;&#9472; &#10095;</div>",
        output,
    );
}
test "Page html trailing blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello\r\nworld\r\n\r\n");
    const pages = &t.screens.active.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .{ .emit = .html });
    const state = try formatter.formatWithState(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqual(@as(usize, page.size.rows - 2), state.rows);
    try testing.expectEqualStrings(
        "<div style=\"font-family: monospace; white-space: pre;\">hello\nworld</div>",
        output,
    );
}
test "Page html ascii characters unchanged" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello world");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .{ .emit = .html });
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings(
        "<div style=\"font-family: monospace; white-space: pre;\">hello world</div>",
        output,
    );
}
test "Page html mixed ascii and unicode" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("test ╰─❯ ok");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .{ .emit = .html });
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings(
        "<div style=\"font-family: monospace; white-space: pre;\">test &#9584;&#9472;&#10095; ok</div>",
        output,
    );
}
test "Page VT with palette option emits RGB" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]4;1;rgb:ab/cd/ef\x1b\\");
    s.nextSlice("\x1b[31mred");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    {
        builder.clearRetainingCapacity();
        var formatter: PageFormatter = .init(page, .vt);
        try formatter.format(&builder.writer);
        const output = builder.writer.buffered();
        try testing.expectEqualStrings("\x1b[0m\x1b[38;5;1mred\x1b[0m", output);
    }
    {
        builder.clearRetainingCapacity();
        var opts: Options = .vt;
        opts.palette = &t.colors.palette.current;
        var formatter: PageFormatter = .init(page, opts);
        try formatter.format(&builder.writer);
        const output = builder.writer.buffered();
        try testing.expectEqualStrings("\x1b[0m\x1b[38;2;171;205;239mred\x1b[0m", output);
    }
}
test "Page html with palette option emits RGB" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]4;1;rgb:ab/cd/ef\x1b\\");
    s.nextSlice("\x1b[31mred");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    {
        builder.clearRetainingCapacity();
        var formatter: PageFormatter = .init(page, .{ .emit = .html });
        try formatter.format(&builder.writer);
        const output = builder.writer.buffered();
        try testing.expectEqualStrings(
            "<div style=\"font-family: monospace; white-space: pre;\">" ++
                "<div style=\"display: inline;color: var(--vt-palette-1);\">red</div>" ++
                "</div>",
            output,
        );
    }
    {
        builder.clearRetainingCapacity();
        var opts: Options = .{ .emit = .html };
        opts.palette = &t.colors.palette.current;
        var formatter: PageFormatter = .init(page, opts);
        try formatter.format(&builder.writer);
        const output = builder.writer.buffered();
        try testing.expectEqualStrings(
            "<div style=\"font-family: monospace; white-space: pre;\">" ++
                "<div style=\"display: inline;color: rgb(171, 205, 239);\">red</div>" ++
                "</div>",
            output,
        );
    }
}
test "Page VT style reset properly closes styles" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[1mbold\x1b[0mnormal");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    builder.clearRetainingCapacity();
    var formatter: PageFormatter = .init(page, .vt);
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("\x1b[0m\x1b[1mbold\x1b[0mnormal", output);
}
test "Page codepoint_map single replacement" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello world");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var map: std.MultiArrayList(CodepointMap) = .{};
    defer map.deinit(alloc);
    try map.append(alloc, .{
        .range = .{ 'o', 'o' },
        .replacement = .{ .codepoint = 'x' },
    });
    var opts: Options = .plain;
    opts.codepoint_map = map;
    var formatter: PageFormatter = .init(page, opts);
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hellx wxrld", output);
    try testing.expectEqual(output.len, point_map.items.len);
    try testing.expectEqual(Coordinate{ .x = 0, .y = 0 }, point_map.items[0]); 
    try testing.expectEqual(Coordinate{ .x = 1, .y = 0 }, point_map.items[1]); 
    try testing.expectEqual(Coordinate{ .x = 2, .y = 0 }, point_map.items[2]); 
    try testing.expectEqual(Coordinate{ .x = 3, .y = 0 }, point_map.items[3]); 
    try testing.expectEqual(Coordinate{ .x = 4, .y = 0 }, point_map.items[4]); 
    try testing.expectEqual(Coordinate{ .x = 5, .y = 0 }, point_map.items[5]); 
    try testing.expectEqual(Coordinate{ .x = 6, .y = 0 }, point_map.items[6]); 
    try testing.expectEqual(Coordinate{ .x = 7, .y = 0 }, point_map.items[7]); 
    try testing.expectEqual(Coordinate{ .x = 8, .y = 0 }, point_map.items[8]); 
    try testing.expectEqual(Coordinate{ .x = 9, .y = 0 }, point_map.items[9]); 
    try testing.expectEqual(Coordinate{ .x = 10, .y = 0 }, point_map.items[10]); 
}
test "Page codepoint_map conflicting replacement prefers last" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var map: std.MultiArrayList(CodepointMap) = .{};
    defer map.deinit(alloc);
    try map.append(alloc, .{
        .range = .{ 'o', 'o' },
        .replacement = .{ .codepoint = 'x' },
    });
    try map.append(alloc, .{
        .range = .{ 'o', 'o' },
        .replacement = .{ .codepoint = 'y' },
    });
    var opts: Options = .plain;
    opts.codepoint_map = map;
    var formatter: PageFormatter = .init(page, opts);
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("helly", output);
}
test "Page codepoint_map replace with string" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var map: std.MultiArrayList(CodepointMap) = .{};
    defer map.deinit(alloc);
    try map.append(alloc, .{
        .range = .{ 'o', 'o' },
        .replacement = .{ .string = "XYZ" },
    });
    var opts: Options = .plain;
    opts.codepoint_map = map;
    var formatter: PageFormatter = .init(page, opts);
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hellXYZ", output);
    try testing.expectEqual(output.len, point_map.items.len);
    try testing.expectEqual(Coordinate{ .x = 0, .y = 0 }, point_map.items[0]); 
    try testing.expectEqual(Coordinate{ .x = 1, .y = 0 }, point_map.items[1]); 
    try testing.expectEqual(Coordinate{ .x = 2, .y = 0 }, point_map.items[2]); 
    try testing.expectEqual(Coordinate{ .x = 3, .y = 0 }, point_map.items[3]); 
    try testing.expectEqual(Coordinate{ .x = 4, .y = 0 }, point_map.items[4]); 
    try testing.expectEqual(Coordinate{ .x = 4, .y = 0 }, point_map.items[5]); 
    try testing.expectEqual(Coordinate{ .x = 4, .y = 0 }, point_map.items[6]); 
}
test "Page codepoint_map range replacement" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("abcdefg");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var map: std.MultiArrayList(CodepointMap) = .{};
    defer map.deinit(alloc);
    try map.append(alloc, .{
        .range = .{ 'b', 'e' },
        .replacement = .{ .codepoint = 'X' },
    });
    var opts: Options = .plain;
    opts.codepoint_map = map;
    var formatter: PageFormatter = .init(page, opts);
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("aXXXXfg", output);
}
test "Page codepoint_map multiple ranges" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello world");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var map: std.MultiArrayList(CodepointMap) = .{};
    defer map.deinit(alloc);
    try map.append(alloc, .{
        .range = .{ 'a', 'm' },
        .replacement = .{ .codepoint = 'A' },
    });
    try map.append(alloc, .{
        .range = .{ 'n', 'z' },
        .replacement = .{ .codepoint = 'Z' },
    });
    var opts: Options = .plain;
    opts.codepoint_map = map;
    var formatter: PageFormatter = .init(page, opts);
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("AAAAZ ZZZAA", output);
}
test "Page codepoint_map unicode replacement" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello ⚡ world");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var map: std.MultiArrayList(CodepointMap) = .{};
    defer map.deinit(alloc);
    try map.append(alloc, .{
        .range = .{ '⚡', '⚡' },
        .replacement = .{ .string = "🔥" },
    });
    var opts: Options = .plain;
    opts.codepoint_map = map;
    var formatter: PageFormatter = .init(page, opts);
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hello 🔥 world", output);
    try testing.expectEqual(output.len, point_map.items.len);
    for (0..6) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(i), .y = 0 },
        point_map.items[i],
    );
    const fire_start = 6; 
    for (0..4) |i| try testing.expectEqual(
        Coordinate{ .x = 6, .y = 0 },
        point_map.items[fire_start + i],
    );
    const world_start = fire_start + 4;
    for (0..6) |i| try testing.expectEqual(
        Coordinate{ .x = @intCast(8 + i), .y = 0 },
        point_map.items[world_start + i],
    );
}
test "Page codepoint_map with styled formats" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[31mred text\x1b[0m");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var map: std.MultiArrayList(CodepointMap) = .{};
    defer map.deinit(alloc);
    try map.append(alloc, .{
        .range = .{ 'e', 'e' },
        .replacement = .{ .codepoint = 'X' },
    });
    var opts: Options = .vt;
    opts.codepoint_map = map;
    var formatter: PageFormatter = .init(page, opts);
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("\x1b[0m\x1b[38;5;1mrXd tXxt\x1b[0m", output);
}
test "Page codepoint_map empty map" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello world");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var map: std.MultiArrayList(CodepointMap) = .{};
    defer map.deinit(alloc);
    var opts: Options = .plain;
    opts.codepoint_map = map;
    var formatter: PageFormatter = .init(page, opts);
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings("hello world", output);
}
test "Page VT background color on trailing blank cells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 20,
        .rows = 5,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("CPU:\x1b[41m\x1b[K");
    s.nextSlice("\x1b[0m\r\nline2");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .vt);
    formatter.opts.trim = false; 
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    const crlf_pos = std.mem.indexOf(u8, output, "\r\n") orelse {
        return error.TestUnexpectedResult;
    };
    const line1 = output[0..crlf_pos];
    const has_red_bg_line1 = std.mem.indexOf(u8, line1, "\x1b[41m") != null or
        std.mem.indexOf(u8, line1, "\x1b[48;5;1m") != null;
    try testing.expect(has_red_bg_line1);
}
test "Page HTML with hyperlinks" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]8;;https://example.com\x1b\\link text\x1b]8;;\x1b\\ normal");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .{ .emit = .html });
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings(
        "<div style=\"font-family: monospace; white-space: pre;\">" ++
            "<a href=\"https://example.com\">link text</a> normal" ++
            "</div>",
        output,
    );
}
test "Page HTML with multiple hyperlinks" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]8;;https://first.com\x1b\\first\x1b]8;;\x1b\\ ");
    s.nextSlice("\x1b]8;;https://second.com\x1b\\second\x1b]8;;\x1b\\");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .{ .emit = .html });
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings(
        "<div style=\"font-family: monospace; white-space: pre;\">" ++
            "<a href=\"https://first.com\">first</a>" ++
            " " ++
            "<a href=\"https://second.com\">second</a>" ++
            "</div>",
        output,
    );
}
test "Page HTML with hyperlink escaping" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]8;;https://example.com?a=1&b=2\x1b\\link\x1b]8;;\x1b\\");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .{ .emit = .html });
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings(
        "<div style=\"font-family: monospace; white-space: pre;\">" ++
            "<a href=\"https://example.com?a=1&amp;b=2\">link</a>" ++
            "</div>",
        output,
    );
}
test "Page HTML with styled hyperlink" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]8;;https://example.com\x1b\\\x1b[1mbold link\x1b[0m\x1b]8;;\x1b\\");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .{ .emit = .html });
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings(
        "<div style=\"font-family: monospace; white-space: pre;\">" ++
            "<div style=\"display: inline;font-weight: bold;\">" ++
            "<a href=\"https://example.com\">bold link</div></a>" ++
            "</div>",
        output,
    );
}
test "Page HTML hyperlink closes style before anchor" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]8;;https://example.com\x1b\\\x1b[1mbold\x1b[0m plain");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .{ .emit = .html });
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    try testing.expectEqualStrings(
        "<div style=\"font-family: monospace; white-space: pre;\">" ++
            "<div style=\"display: inline;font-weight: bold;\">" ++
            "<a href=\"https://example.com\">bold</div> plain</a>" ++
            "</div>",
        output,
    );
}
test "Page HTML hyperlink point map maps closing to previous cell" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\ normal");
    const pages = &t.screens.active.pages;
    const page = pages.pages.last.?.page();
    var formatter: PageFormatter = .init(page, .{ .emit = .html });
    var point_map: std.ArrayList(Coordinate) = .empty;
    defer point_map.deinit(alloc);
    formatter.point_map = .{ .alloc = alloc, .map = &point_map };
    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();
    const expected_output =
        "<div style=\"font-family: monospace; white-space: pre;\">" ++
        "<a href=\"https://example.com\">link</a> normal" ++
        "</div>";
    try testing.expectEqualStrings(expected_output, output);
    try testing.expectEqual(expected_output.len, point_map.items.len);
    const closing_idx = comptime std.mem.indexOf(u8, expected_output, "</a>").?;
    const expected_coord = point_map.items[closing_idx - 1];
    for (closing_idx..closing_idx + "</a>".len) |i| {
        try testing.expectEqual(expected_coord, point_map.items[i]);
    }
}
