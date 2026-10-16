const Selection = @This();
const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const lib = @import("lib.zig");
const page = @import("page.zig");
const point = @import("point.zig");
const PageList = @import("PageList.zig");
const Screen = @import("Screen.zig");
const Pin = PageList.Pin;
bounds: Bounds,
rectangle: bool = false,
pub const Bounds = union(enum) {
    untracked: struct {
        start: Pin,
        end: Pin,
    },
    tracked: struct {
        start: *Pin,
        end: *Pin,
    },
};
pub fn init(
    start_pin: Pin,
    end_pin: Pin,
    rect: bool,
) Selection {
    return .{
        .bounds = .{ .untracked = .{
            .start = start_pin,
            .end = end_pin,
        } },
        .rectangle = rect,
    };
}
pub fn deinit(
    self: Selection,
    s: *Screen,
) void {
    switch (self.bounds) {
        .tracked => |v| {
            s.pages.untrackPin(v.start);
            s.pages.untrackPin(v.end);
        },
        .untracked => {},
    }
}
pub fn eql(self: Selection, other: Selection) bool {
    return self.start().eql(other.start()) and
        self.end().eql(other.end()) and
        self.rectangle == other.rectangle;
}
pub fn startPtr(self: *Selection) *Pin {
    return switch (self.bounds) {
        .untracked => |*v| &v.start,
        .tracked => |v| v.start,
    };
}
pub fn endPtr(self: *Selection) *Pin {
    return switch (self.bounds) {
        .untracked => |*v| &v.end,
        .tracked => |v| v.end,
    };
}
pub fn start(self: Selection) Pin {
    return switch (self.bounds) {
        .untracked => |v| v.start,
        .tracked => |v| v.start.*,
    };
}
pub fn end(self: Selection) Pin {
    return switch (self.bounds) {
        .untracked => |v| v.end,
        .tracked => |v| v.end.*,
    };
}
pub fn tracked(self: *const Selection) bool {
    return switch (self.bounds) {
        .untracked => false,
        .tracked => true,
    };
}
pub fn track(self: *const Selection, s: *Screen) Allocator.Error!Selection {
    assert(!self.tracked());
    const start_pin = self.bounds.untracked.start;
    const end_pin = self.bounds.untracked.end;
    const tracked_start = try s.pages.trackPin(start_pin);
    errdefer s.pages.untrackPin(tracked_start);
    const tracked_end = try s.pages.trackPin(end_pin);
    errdefer s.pages.untrackPin(tracked_end);
    return .{
        .bounds = .{ .tracked = .{
            .start = tracked_start,
            .end = tracked_end,
        } },
        .rectangle = self.rectangle,
    };
}
pub fn topLeft(self: Selection, s: *const Screen) Pin {
    return switch (self.order(s)) {
        .forward => self.start(),
        .reverse => self.end(),
        .mirrored_forward => pin: {
            var p = self.start();
            p.x = @min(self.end().x, p.node.cols() - 1);
            break :pin p;
        },
        .mirrored_reverse => pin: {
            var p = self.end();
            p.x = @min(self.start().x, p.node.cols() - 1);
            break :pin p;
        },
    };
}
pub fn bottomRight(self: Selection, s: *const Screen) Pin {
    return switch (self.order(s)) {
        .forward => self.end(),
        .reverse => self.start(),
        .mirrored_forward => pin: {
            var p = self.end();
            p.x = @min(self.start().x, p.node.cols() - 1);
            break :pin p;
        },
        .mirrored_reverse => pin: {
            var p = self.start();
            p.x = @min(self.end().x, p.node.cols() - 1);
            break :pin p;
        },
    };
}
pub const Order = lib.Enum(lib.target, &.{
    "forward",
    "reverse",
    "mirrored_forward",
    "mirrored_reverse",
});
pub fn order(self: Selection, s: *const Screen) Order {
    const start_pt = s.pages.pointFromPin(.screen, self.start()).?.screen;
    const end_pt = s.pages.pointFromPin(.screen, self.end()).?.screen;
    if (self.rectangle) {
        if (start_pt.y > end_pt.y and start_pt.x >= end_pt.x) return .reverse;
        if (start_pt.y >= end_pt.y and start_pt.x > end_pt.x) return .reverse;
        if (start_pt.y > end_pt.y and start_pt.x < end_pt.x) return .mirrored_reverse;
        if (start_pt.y < end_pt.y and start_pt.x > end_pt.x) return .mirrored_forward;
        return .forward;
    }
    if (start_pt.y < end_pt.y) return .forward;
    if (start_pt.y > end_pt.y) return .reverse;
    if (start_pt.x <= end_pt.x) return .forward;
    return .reverse;
}
pub fn ordered(self: Selection, s: *const Screen, desired: Order) Selection {
    if (self.order(s) == desired) return .init(
        self.start(),
        self.end(),
        self.rectangle,
    );
    const tl = self.topLeft(s);
    const br = self.bottomRight(s);
    return switch (desired) {
        .forward => .init(tl, br, self.rectangle),
        .reverse => .init(br, tl, self.rectangle),
        else => .init(tl, br, self.rectangle),
    };
}
pub fn contains(self: Selection, s: *const Screen, pin: Pin) bool {
    const tl_pin = self.topLeft(s);
    const br_pin = self.bottomRight(s);
    const tl = s.pages.pointFromPin(.screen, tl_pin).?.screen;
    const br = s.pages.pointFromPin(.screen, br_pin).?.screen;
    const p = s.pages.pointFromPin(.screen, pin).?.screen;
    if (self.rectangle)
        return p.y >= tl.y and p.y <= br.y and p.x >= tl.x and p.x <= br.x;
    if (tl.y == br.y) return p.y == tl.y and
        p.x >= tl.x and
        p.x <= br.x;
    if (p.y == tl.y) return p.x >= tl.x;
    if (p.y == br.y) return p.x <= br.x;
    return p.y > tl.y and p.y < br.y;
}
pub fn containedRow(self: Selection, s: *const Screen, pin: Pin) ?Selection {
    const tl_pin = self.topLeft(s);
    const br_pin = self.bottomRight(s);
    const tl = s.pages.pointFromPin(.screen, tl_pin).?.screen;
    const br = s.pages.pointFromPin(.screen, br_pin).?.screen;
    const p = s.pages.pointFromPin(.screen, pin).?.screen;
    return self.containedRowCached(
        s,
        tl_pin,
        br_pin,
        pin,
        tl,
        br,
        p,
    );
}
pub fn containedRowCached(
    self: Selection,
    s: *const Screen,
    tl_pin: Pin,
    br_pin: Pin,
    pin: Pin,
    tl: point.Coordinate,
    br: point.Coordinate,
    p: point.Coordinate,
) ?Selection {
    _ = s;
    if (p.y < tl.y or p.y > br.y) return null;
    if (self.rectangle) return init(
        start: {
            var copy: Pin = pin;
            copy.x = @min(tl.x, copy.node.cols() - 1);
            break :start copy;
        },
        end: {
            var copy: Pin = pin;
            copy.x = @min(br.x, copy.node.cols() - 1);
            break :end copy;
        },
        true,
    );
    if (p.y == tl.y) {
        if (p.y == br.y) {
            return init(tl_pin, br_pin, false);
        }
        return init(
            tl_pin,
            end: {
                var copy: Pin = pin;
                copy.x = copy.node.cols() - 1;
                break :end copy;
            },
            false,
        );
    }
    if (p.y == br.y) {
        assert(p.y != tl.y);
        return init(
            start: {
                var copy: Pin = pin;
                copy.x = 0;
                break :start copy;
            },
            br_pin,
            false,
        );
    }
    return init(
        start: {
            var copy: Pin = pin;
            copy.x = 0;
            break :start copy;
        },
        end: {
            var copy: Pin = pin;
            copy.x = copy.node.cols() - 1;
            break :end copy;
        },
        false,
    );
}
pub const Adjustment = lib.Enum(lib.target, &.{
    "left",
    "right",
    "up",
    "down",
    "home",
    "end",
    "page_up",
    "page_down",
    "beginning_of_line",
    "end_of_line",
});
pub fn adjust(
    self: *Selection,
    s: *const Screen,
    adjustment: Adjustment,
) void {
    const end_pin = self.endPtr();
    switch (adjustment) {
        .up => if (end_pin.up(1)) |new_end| {
            end_pin.* = new_end;
        } else {
            self.adjust(s, .beginning_of_line);
        },
        .down => {
            var current = end_pin.*;
            while (current.down(1)) |next| : (current = next) {
                const rac = next.rowAndCell();
                const cells = next.node.page().getCells(rac.row);
                if (page.Cell.hasTextAny(cells)) {
                    end_pin.* = next;
                    break;
                }
            } else {
                self.adjust(s, .end_of_line);
            }
        },
        .left => {
            var it = end_pin.cellIterator(.left_up, null);
            _ = it.next();
            while (it.next()) |next| {
                const rac = next.rowAndCell();
                if (rac.cell.hasText()) {
                    end_pin.* = next;
                    break;
                }
            }
        },
        .right => {
            var it = end_pin.cellIterator(.right_down, null);
            _ = it.next();
            while (it.next()) |next| {
                const rac = next.rowAndCell();
                if (rac.cell.hasText()) {
                    end_pin.* = next;
                    break;
                }
            }
        },
        .page_up => if (end_pin.up(s.pages.rows)) |new_end| {
            end_pin.* = new_end;
        } else {
            self.adjust(s, .home);
        },
        .page_down => if (end_pin.down(s.pages.rows)) |new_end| {
            end_pin.* = new_end;
        } else {
            self.adjust(s, .end);
        },
        .home => end_pin.* = s.pages.pin(.{ .screen = .{
            .x = 0,
            .y = 0,
        } }).?,
        .end => {
            var it = s.pages.rowIterator(
                .left_up,
                .{ .screen = .{} },
                null,
            );
            while (it.next()) |next| {
                const rac = next.rowAndCell();
                const cells = next.node.page().getCells(rac.row);
                if (page.Cell.hasTextAny(cells)) {
                    end_pin.* = next;
                    end_pin.x = @intCast(cells.len - 1);
                    break;
                }
            }
        },
        .beginning_of_line => end_pin.x = 0,
        .end_of_line => end_pin.x = end_pin.node.cols() - 1,
    }
}
test "Selection: adjust right" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A1234\nB5678\nC1234\nD5678");
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .right);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 2 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .right);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 3 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .right);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}
test "Selection: adjust left" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A1234\nB5678\nC1234\nD5678");
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .left);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 3 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .left);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}
test "Selection: adjust left skips blanks" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A1234\nB5678\nC12\nD56");
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 3 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .left);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 3 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .left);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}
test "Selection: adjust up" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A\nB\nC\nD\nE");
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .up);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 0 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .up);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}
test "Selection: adjust down" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A\nB\nC\nD\nE");
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .down);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 4,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 4 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .down);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 9,
            .y = 4,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}
test "Selection: adjust down with not full screen" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A\nB\nC");
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 2 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .down);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 9,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}
test "Selection: adjust home" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A\nB\nC");
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 2 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .home);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}
test "Selection: adjust end with not full screen" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A\nB\nC");
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .end);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 9,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}
test "Selection: adjust beginning of line" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 8, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A12 B34\nC12 D34");
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .beginning_of_line);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .beginning_of_line);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .beginning_of_line);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}
test "Selection: adjust end of line" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 8, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A12 B34\nC12 D34");
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .end_of_line);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 7, .y = 0 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .end_of_line);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 7, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .end_of_line);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}
test "Selection: order, standard" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 100, .rows = 100, .max_scrollback_bytes = 1 });
    defer s.deinit();
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
            false,
        );
        defer sel.deinit(&s);
        try testing.expect(sel.order(&s) == .forward);
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);
        try testing.expect(sel.order(&s) == .reverse);
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);
        try testing.expect(sel.order(&s) == .forward);
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);
        try testing.expect(sel.order(&s) == .forward);
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);
        try testing.expect(sel.order(&s) == .reverse);
    }
}
test "Selection: rectangle corners clamp across mixed-width pages" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{
        .cols = 4,
        .rows = 2,
        .max_scrollback_bytes = 0,
    });
    defer s.deinit();
    const first = s.pages.pages.first.?;
    try s.pages.split(.{ .node = first, .y = 1 });
    const second = first.next.?;
    second.page().size.cols = 2;
    const sel = Selection.init(
        .{ .node = first, .x = 3 },
        .{ .node = second, .x = 1 },
        true,
    );
    try testing.expectEqual(.mirrored_forward, sel.order(&s));
    const bottom_right = sel.bottomRight(&s);
    _ = bottom_right.rowAndCell();
    try testing.expect((Pin{ .node = second, .x = 1 }).eql(bottom_right));
}
test "Selection: order, rectangle" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try Screen.init(io, alloc, .{ .cols = 100, .rows = 100, .max_scrollback_bytes = 1 });
    defer s.deinit();
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
            true,
        );
        defer sel.deinit(&s);
        try testing.expect(sel.order(&s) == .forward);
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);
        try testing.expect(sel.order(&s) == .reverse);
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            true,
        );
        defer sel.deinit(&s);
        try testing.expect(sel.order(&s) == .mirrored_forward);
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);
        try testing.expect(sel.order(&s) == .mirrored_reverse);
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);
        try testing.expect(sel.order(&s) == .forward);
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);
        try testing.expect(sel.order(&s) == .reverse);
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 3 } }).?,
            true,
        );
        defer sel.deinit(&s);
        try testing.expect(sel.order(&s) == .forward);
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);
        try testing.expect(sel.order(&s) == .reverse);
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);
        try testing.expect(sel.order(&s) == .forward);
    }
}
test "topLeft" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);
        const tl = sel.topLeft(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, tl));
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);
        const tl = sel.topLeft(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, tl));
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            true,
        );
        defer sel.deinit(&s);
        const tl = sel.topLeft(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, tl));
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);
        const tl = sel.topLeft(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, tl));
    }
}
test "bottomRight" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);
        const br = sel.bottomRight(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, br));
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);
        const br = sel.bottomRight(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, br));
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            true,
        );
        defer sel.deinit(&s);
        const br = sel.bottomRight(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, br));
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);
        const br = sel.bottomRight(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, br));
    }
}
test "ordered" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            false,
        );
        const sel_reverse = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            false,
        );
        try testing.expect(sel.ordered(&s, .forward).eql(sel));
        try testing.expect(sel.ordered(&s, .reverse).eql(sel_reverse));
        try testing.expect(sel.ordered(&s, .mirrored_forward).eql(sel));
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            false,
        );
        const sel_forward = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            false,
        );
        try testing.expect(sel.ordered(&s, .forward).eql(sel_forward));
        try testing.expect(sel.ordered(&s, .reverse).eql(sel));
        try testing.expect(sel.ordered(&s, .mirrored_forward).eql(sel_forward));
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            true,
        );
        const sel_forward = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            true,
        );
        const sel_reverse = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            true,
        );
        try testing.expect(sel.ordered(&s, .forward).eql(sel_forward));
        try testing.expect(sel.ordered(&s, .reverse).eql(sel_reverse));
        try testing.expect(sel.ordered(&s, .mirrored_reverse).eql(sel_forward));
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            true,
        );
        const sel_forward = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            true,
        );
        const sel_reverse = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            true,
        );
        try testing.expect(sel.ordered(&s, .forward).eql(sel_forward));
        try testing.expect(sel.ordered(&s, .reverse).eql(sel_reverse));
        try testing.expect(sel.ordered(&s, .mirrored_forward).eql(sel_forward));
    }
}
test "Selection: contains" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 2 } }).?,
            false,
        );
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 6, .y = 1 } }).?));
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 1, .y = 2 } }).?));
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?));
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 2 } }).?));
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 2 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            false,
        );
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 6, .y = 1 } }).?));
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 1, .y = 2 } }).?));
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?));
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 2 } }).?));
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 8, .y = 1 } }).?,
            false,
        );
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 6, .y = 1 } }).?));
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?));
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 9, .y = 1 } }).?));
    }
}
test "Selection: contains, rectangle" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 15, .rows = 15, .max_scrollback_bytes = 0 });
    defer s.deinit();
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 7, .y = 9 } }).?,
            true,
        );
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 6 } }).?)); 
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 3, .y = 6 } }).?)); 
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 7, .y = 6 } }).?)); 
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 3 } }).?)); 
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 9 } }).?)); 
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 2 } }).?)); 
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 10 } }).?)); 
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 2, .y = 6 } }).?)); 
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 8, .y = 6 } }).?)); 
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 8, .y = 3 } }).?)); 
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 2, .y = 9 } }).?)); 
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 7, .y = 9 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            true,
        );
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 6 } }).?)); 
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 3, .y = 6 } }).?)); 
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 7, .y = 6 } }).?)); 
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 3 } }).?)); 
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 9 } }).?)); 
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 2 } }).?)); 
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 10 } }).?)); 
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 2, .y = 6 } }).?)); 
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 8, .y = 6 } }).?)); 
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 8, .y = 3 } }).?)); 
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 2, .y = 9 } }).?)); 
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 10, .y = 1 } }).?,
            true,
        );
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 6, .y = 1 } }).?));
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?));
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 12, .y = 1 } }).?));
    }
}
test "Selection: containedRow" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            false,
        );
        try testing.expect(sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 4 } }).?,
        ) == null);
        try testing.expectEqual(Selection.init(
            sel.start(),
            s.pages.pin(.{ .screen = .{ .x = s.pages.cols - 1, .y = 1 } }).?,
            false,
        ), sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
        ).?);
        try testing.expectEqual(Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 3 } }).?,
            sel.end(),
            false,
        ), sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 3 } }).?,
        ).?);
        try testing.expectEqual(Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 2 } }).?,
            s.pages.pin(.{ .screen = .{ .x = s.pages.cols - 1, .y = 2 } }).?,
            false,
        ), sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
        ).?);
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 6, .y = 3 } }).?,
            true,
        );
        try testing.expect(sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 4 } }).?,
        ) == null);
        try testing.expectEqual(Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 6, .y = 1 } }).?,
            true,
        ), sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
        ).?);
        try testing.expectEqual(Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 6, .y = 3 } }).?,
            true,
        ), sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 3 } }).?,
        ).?);
        try testing.expectEqual(Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 2 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 6, .y = 2 } }).?,
            true,
        ), sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
        ).?);
    }
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 6, .y = 1 } }).?,
            false,
        );
        try testing.expect(sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
        ) == null);
        try testing.expect(sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 2 } }).?,
        ) == null);
        try testing.expectEqual(sel, sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
        ).?);
    }
}
test "Selection: containedRow clamps mixed-width pages" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{
        .cols = 4,
        .rows = 3,
        .max_scrollback_bytes = 0,
    });
    defer s.deinit();
    const first = s.pages.pages.first.?;
    try s.pages.split(.{ .node = first, .y = 2 });
    try s.pages.split(.{ .node = first, .y = 1 });
    const middle = first.next.?;
    const last = middle.next.?;
    middle.page().size.cols = 2;
    const linear = Selection.init(
        .{ .node = first, .x = 1 },
        .{ .node = last, .x = 1 },
        false,
    );
    const linear_row = linear.containedRow(
        &s,
        .{ .node = middle },
    ).?;
    _ = linear_row.end().rowAndCell();
    try testing.expect((Pin{ .node = middle }).eql(linear_row.start()));
    try testing.expect((Pin{ .node = middle, .x = 1 }).eql(linear_row.end()));
    const rectangle = Selection.init(
        .{ .node = first, .x = 1 },
        .{ .node = last, .x = 3 },
        true,
    );
    const rectangle_row = rectangle.containedRow(
        &s,
        .{ .node = middle },
    ).?;
    _ = rectangle_row.end().rowAndCell();
    try testing.expect((Pin{ .node = middle, .x = 1 }).eql(rectangle_row.start()));
    try testing.expect((Pin{ .node = middle, .x = 1 }).eql(rectangle_row.end()));
}
