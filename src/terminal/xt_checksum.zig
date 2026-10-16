const std = @import("std");
const testing = std.testing;
const PageList = @import("PageList.zig");
const Screen = @import("Screen.zig");
const Selection = @import("Selection.zig");
const Terminal = @import("Terminal.zig");
const pagepkg = @import("page.zig");
const point = @import("point.zig");
const style = @import("style.zig");
pub const Flags = packed struct(u5) {
    positive: bool = false,
    no_attributes: bool = false,
    no_trim: bool = false,
    undrawn: bool = false,
    full: bool = false,
};
pub const Request = extern struct {
    id: u16 = 0,
    top: u16 = 0,
    left: u16 = 0,
    bottom: u16 = 0,
    right: u16 = 0,
    pub fn selection(
        self: Request,
        pages: *const PageList,
        origin: ?Terminal.ScrollingRegion,
    ) ?Selection {
        const rows = pages.rows;
        const cols = pages.cols;
        if (rows == 0 or cols == 0) return null;
        const top_margin: u16 = if (origin) |o| o.top else 0;
        const left_margin: u16 = if (origin) |o| o.left else 0;
        const top = limit(self.top, 1, top_margin, rows);
        const left = limit(self.left, 1, left_margin, cols);
        const bottom = limit(self.bottom, rows, top_margin, rows);
        const right = limit(self.right, cols, left_margin, cols);
        if (top > bottom or left > right) return null;
        return .init(
            pages.pin(.{ .active = .{ .x = left - 1, .y = top - 1 } }) orelse return null,
            pages.pin(.{ .active = .{ .x = right - 1, .y = bottom - 1 } }) orelse return null,
            true,
        );
    }
    fn limit(v: u16, default: u16, margin: u16, max: u16) u16 {
        const n = if (v == 0) default else v;
        return std.math.clamp(n +| margin, 1, max);
    }
};
pub fn compute(screen: *const Screen, sel_: ?Selection, flags: Flags) u16 {
    const sel = sel_ orelse return 0;
    const tl = sel.topLeft(screen);
    const br = sel.bottomRight(screen);
    var sum: u16 = 0;
    var first = true;
    var it = tl.rowIterator(.right_down, br);
    while (it.next()) |row| {
        const cells = row.cells(.all);
        const left = @min(tl.x, cells.len);
        const right = @min(br.x + 1, cells.len);
        for (cells[left..right]) |*cell| {
            var ch: u16 = switch (value(cell, flags)) {
                .skip => continue,
                .undrawn => if (flags.no_trim or flags.undrawn) ' ' else continue,
                .value => |v| v,
            };
            const s = row.style(cell);
            if (!flags.no_attributes) ch +%= attributes(cell, s);
            if (flags.no_trim) {
                sum +%= ch;
                if (!flags.full and cell.hasGrapheme()) {
                    if (row.grapheme(cell)) |cps| {
                        for (cps) |cp| sum +%= @truncate(cp);
                    }
                }
            } else if (first or ch != ' ' or extended(s)) {
                sum +%= ch;
            }
            first = flags.no_trim;
        }
        if (!flags.no_trim) first = false;
    }
    return if (flags.positive) sum else 0 -% sum;
}
const Value = union(enum) {
    skip,
    undrawn,
    value: u16,
};
fn value(cell: *const pagepkg.Cell, flags: Flags) Value {
    if (cell.wide == .spacer_tail) {
        return if (flags.full) .skip else .{ .value = 0x1B };
    }
    if (!cell.hasText()) return .undrawn;
    const cp = cell.codepoint();
    if (flags.full) return .{ .value = @truncate(cp) };
    return .{ .value = switch (cp) {
        0x7F, 0xFF => 0,
        0x20...0x7E, 0x80...0x9F, 0xA1...0xFE => @intCast(cp & 0x7F),
        else => 0x1B,
    } };
}
fn attributes(cell: *const pagepkg.Cell, s: style.Style) u16 {
    var result: u16 = 0;
    if (cell.protected) result += 0x04;
    if (s.flags.invisible) result += 0x08;
    if (s.flags.underline != .none) result += 0x10;
    if (s.flags.inverse) result += 0x20;
    if (s.flags.blink) result += 0x40;
    if (s.flags.bold) result += 0x80;
    return result;
}
fn extended(s: style.Style) bool {
    return s.flags.faint or
        s.flags.italic or
        s.flags.strikethrough or
        s.flags.underline == .double;
}
pub const max_encode_size = "\x1bP65535!~FFFF\x1b\\".len;
pub fn encode(
    writer: *std.Io.Writer,
    id: u16,
    sum: u16,
) std.Io.Writer.Error!void {
    try writer.print("\x1bP{d}!~{X:0>4}\x1b\\", .{ id, sum });
}
test "xt_checksum: encode" {
    var buf: [max_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(&writer, 65535, 0xFFFF);
    try testing.expectEqualStrings("\x1bP65535!~FFFF\x1b\\", writer.buffered());
    writer = .fixed(&buf);
    try encode(&writer, 1, 0x1A);
    try testing.expectEqualStrings("\x1bP1!~001A\x1b\\", writer.buffered());
}
test "xt_checksum: selection defaults and clamping" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    const pages = &t.screens.active.pages;
    {
        const sel = (Request{}).selection(pages, null).?;
        try testing.expect(sel.rectangle);
        try testing.expectEqual(
            point.Point{ .active = .{ .x = 0, .y = 0 } },
            pages.pointFromPin(.active, sel.start()).?,
        );
        try testing.expectEqual(
            point.Point{ .active = .{ .x = 9, .y = 4 } },
            pages.pointFromPin(.active, sel.end()).?,
        );
    }
    {
        const req: Request = .{ .top = 2, .left = 3, .bottom = 99, .right = 99 };
        const sel = req.selection(pages, null).?;
        try testing.expectEqual(
            point.Point{ .active = .{ .x = 2, .y = 1 } },
            pages.pointFromPin(.active, sel.start()).?,
        );
        try testing.expectEqual(
            point.Point{ .active = .{ .x = 9, .y = 4 } },
            pages.pointFromPin(.active, sel.end()).?,
        );
    }
    try testing.expectEqual(
        null,
        (Request{ .top = 3, .bottom = 2 }).selection(pages, null),
    );
    try testing.expectEqual(
        null,
        (Request{ .left = 3, .right = 2 }).selection(pages, null),
    );
}
test "xt_checksum: selection origin mode" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    const pages = &t.screens.active.pages;
    const region: Terminal.ScrollingRegion = .{
        .top = 1,
        .bottom = 3,
        .left = 2,
        .right = 8,
    };
    {
        const sel = (Request{}).selection(pages, region).?;
        try testing.expectEqual(
            point.Point{ .active = .{ .x = 2, .y = 1 } },
            pages.pointFromPin(.active, sel.start()).?,
        );
        try testing.expectEqual(
            point.Point{ .active = .{ .x = 9, .y = 4 } },
            pages.pointFromPin(.active, sel.end()).?,
        );
    }
    {
        const req: Request = .{ .top = 1, .left = 1, .bottom = 1, .right = 1 };
        const sel = req.selection(pages, region).?;
        try testing.expectEqual(
            point.Point{ .active = .{ .x = 2, .y = 1 } },
            pages.pointFromPin(.active, sel.start()).?,
        );
        try testing.expectEqual(
            point.Point{ .active = .{ .x = 2, .y = 1 } },
            pages.pointFromPin(.active, sel.end()).?,
        );
    }
}
test "xt_checksum: DEC trims blanks and skips undrawn cells" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    const s = t.screens.active;
    try t.printString("a b");
    const req: Request = .{ .top = 1, .bottom = 1 };
    const sel = req.selection(&s.pages, null);
    try testing.expectEqual(0 -% @as(u16, 'a' + 'b'), compute(s, sel, .{}));
    try testing.expectEqual(@as(u16, 'a' + 'b'), compute(s, sel, .{ .positive = true }));
    try testing.expectEqual(
        @as(u16, 'a' + 'b' + ' ' * 8),
        compute(s, sel, .{ .positive = true, .no_trim = true }),
    );
    try testing.expectEqual(
        @as(u16, 'a' + 'b'),
        compute(s, sel, .{ .positive = true, .undrawn = true }),
    );
}
test "xt_checksum: DEC counts a leading space" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    const s = t.screens.active;
    try t.printString(" a\n b");
    const req: Request = .{};
    const sel = req.selection(&s.pages, null);
    try testing.expectEqual(
        @as(u16, ' ' + 'a' + 'b'),
        compute(s, sel, .{ .positive = true }),
    );
}
test "xt_checksum: empty rectangle" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    const s = t.screens.active;
    try t.printString("abc");
    const req: Request = .{ .left = 3, .right = 2 };
    try testing.expectEqual(0, compute(s, req.selection(&s.pages, null), .{}));
}
test "xt_checksum: rectangle bounds" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    const s = t.screens.active;
    try t.printString("abc\ndef\nghi");
    const req: Request = .{ .top = 2, .left = 2, .bottom = 3, .right = 3 };
    const sel = req.selection(&s.pages, null);
    try testing.expectEqual(
        @as(u16, 'e' + 'f' + 'h' + 'i'),
        compute(s, sel, .{ .positive = true }),
    );
}
test "xt_checksum: attributes" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    const s = t.screens.active;
    try t.setAttribute(.bold);
    try t.setAttribute(.{ .underline = .single });
    try t.printString("a");
    try t.setAttribute(.unset);
    try t.setAttribute(.inverse);
    try t.setAttribute(.blink);
    try t.printString(" ");
    try t.setAttribute(.unset);
    try t.setAttribute(.invisible);
    t.setProtectedMode(.dec);
    try t.printString("b");
    const req: Request = .{ .top = 1, .bottom = 1 };
    const sel = req.selection(&s.pages, null);
    try testing.expectEqual(
        @as(u16, 'a' + 0x80 + 0x10 + ' ' + 0x20 + 0x40 + 'b' + 0x08 + 0x04),
        compute(s, sel, .{ .positive = true }),
    );
    try testing.expectEqual(
        @as(u16, 'a' + 'b'),
        compute(s, sel, .{ .positive = true, .no_attributes = true }),
    );
}
test "xt_checksum: extended attributes keep a space" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    const s = t.screens.active;
    try t.printString("a");
    try t.setAttribute(.italic);
    try t.printString(" ");
    const req: Request = .{ .top = 1, .bottom = 1 };
    const sel = req.selection(&s.pages, null);
    try testing.expectEqual(
        @as(u16, 'a' + ' '),
        compute(s, sel, .{ .positive = true }),
    );
}
test "xt_checksum: DEC 8-bit values" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    const s = t.screens.active;
    try t.printString("é€");
    const req: Request = .{ .top = 1, .bottom = 1 };
    const sel = req.selection(&s.pages, null);
    try testing.expectEqual(
        @as(u16, 0x69 + 0x1B),
        compute(s, sel, .{ .positive = true }),
    );
    try testing.expectEqual(
        @as(u16, 0xE9 + 0x20AC),
        compute(s, sel, .{ .positive = true, .full = true }),
    );
}
test "xt_checksum: wide characters" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    const s = t.screens.active;
    try t.printString("橋");
    const req: Request = .{ .top = 1, .bottom = 1 };
    const sel = req.selection(&s.pages, null);
    try testing.expectEqual(
        @as(u16, 0x1B + 0x1B),
        compute(s, sel, .{ .positive = true }),
    );
    try testing.expectEqual(
        @as(u16, 0x6A4B),
        compute(s, sel, .{ .positive = true, .full = true }),
    );
}
test "xt_checksum: combining marks" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    const s = t.screens.active;
    t.modes.set(.grapheme_cluster, true);
    try t.printString("e\u{301}");
    const req: Request = .{ .top = 1, .bottom = 1, .right = 1 };
    const sel = req.selection(&s.pages, null);
    try testing.expectEqual(
        @as(u16, 'e'),
        compute(s, sel, .{ .positive = true }),
    );
    try testing.expectEqual(
        @as(u16, 'e' + 0x301),
        compute(s, sel, .{ .positive = true, .no_trim = true }),
    );
    try testing.expectEqual(
        @as(u16, 'e'),
        compute(s, sel, .{ .positive = true, .no_trim = true, .full = true }),
    );
}
