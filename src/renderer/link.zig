const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const oni = @import("oniguruma");
const inputpkg = @import("../input.zig");
const terminal = @import("../terminal/main.zig");
const point = terminal.point;
const Screen = terminal.Screen;
const Terminal = terminal.Terminal;
const log = std.log.scoped(.renderer_link);
pub const Link = struct {
    regex: oni.Regex,
    highlight: inputpkg.Link.Highlight,
    pub fn deinit(self: *Link) void {
        self.regex.deinit();
    }
    fn active(
        self: *const Link,
        mouse_viewport: ?point.Coordinate,
        mouse_mods: inputpkg.Mods,
    ) bool {
        return switch (self.highlight) {
            .always => true,
            .always_mods => |v| mouse_mods.equal(v),
            .hover => mouse_viewport != null,
            .hover_mods => |v| mouse_viewport != null and mouse_mods.equal(v),
        };
    }
};
pub const Set = struct {
    links: []Link,
    pub fn fromConfig(
        alloc: Allocator,
        config: []const inputpkg.Link,
    ) !Set {
        var links: std.ArrayList(Link) = .empty;
        defer links.deinit(alloc);
        for (config) |link| {
            var regex = try link.oniRegex();
            errdefer regex.deinit();
            try links.append(alloc, .{
                .regex = regex,
                .highlight = link.highlight,
            });
        }
        return .{ .links = try links.toOwnedSlice(alloc) };
    }
    pub fn deinit(self: *Set, alloc: Allocator) void {
        for (self.links) |*link| link.deinit();
        alloc.free(self.links);
    }
    pub fn renderCellMap(
        self: *const Set,
        alloc: Allocator,
        result: *terminal.RenderState.CellSet,
        render_state: *const terminal.RenderState,
        mouse_viewport: ?point.Coordinate,
        mouse_mods: inputpkg.Mods,
    ) !void {
        if (self.links.len == 0) return;
        for (self.links) |*link| {
            if (link.active(mouse_viewport, mouse_mods)) break;
        } else return;
        var builder: std.Io.Writer.Allocating = .init(alloc);
        defer builder.deinit();
        var map: terminal.RenderState.StringMap = .empty;
        defer map.deinit(alloc);
        try render_state.string(&builder.writer, .{
            .alloc = alloc,
            .map = &map,
        });
        const str = builder.writer.buffered();
        for (self.links) |*link| {
            if (!link.active(mouse_viewport, mouse_mods)) continue;
            var offset: usize = 0;
            while (offset < str.len) {
                var region = link.regex.search(
                    str[offset..],
                    .{},
                ) catch |err| switch (err) {
                    error.Mismatch => break,
                    else => return err,
                };
                defer region.deinit();
                const offset_start: usize = @intCast(region.starts()[0]);
                const offset_end: usize = @intCast(region.ends()[0]);
                const start = offset + offset_start;
                const end = offset + offset_end;
                defer offset = end;
                switch (link.highlight) {
                    .always, .always_mods => {},
                    .hover, .hover_mods => if (mouse_viewport) |vp| {
                        for (map.items[start..end]) |pt| {
                            if (pt.eql(vp)) break;
                        } else continue;
                    } else continue,
                }
                for (map.items[start..end]) |pt| {
                    try result.put(alloc, pt, {});
                }
            }
        }
    }
};
test "renderCellMap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t: terminal.Terminal = try .init(testing.io, alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },
        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },
    });
    defer set.deinit(alloc);
    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(alloc);
    try set.renderCellMap(
        alloc,
        &result,
        &state,
        null,
        .{},
    );
    try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
}
test "renderCellMap hover links" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t: terminal.Terminal = try .init(testing.io, alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .hover = {} },
        },
        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },
    });
    defer set.deinit(alloc);
    {
        var result: terminal.RenderState.CellSet = .empty;
        defer result.deinit(alloc);
        try set.renderCellMap(
            alloc,
            &result,
            &state,
            null,
            .{},
        );
        try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 2, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
    }
    {
        var result: terminal.RenderState.CellSet = .empty;
        defer result.deinit(alloc);
        try set.renderCellMap(
            alloc,
            &result,
            &state,
            .{ .x = 1, .y = 0 },
            .{},
        );
        try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
    }
}
test "renderCellMap inactive links don't allocate" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t: terminal.Terminal = try .init(io, alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .hover = {} },
        },
        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always_mods = .{ .ctrl = true } },
        },
        .{
            .regex = "IJ",
            .action = .{ .open = {} },
            .highlight = .{ .hover_mods = .{ .shift = true } },
        },
    });
    defer set.deinit(alloc);
    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    const failing_alloc = failing.allocator();
    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(failing_alloc);
    try set.renderCellMap(
        failing_alloc,
        &result,
        &state,
        null,
        .{},
    );
    try testing.expectEqual(@as(usize, 0), result.count());
}
test "renderCellMap mods no match" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t: terminal.Terminal = try .init(testing.io, alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },
        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always_mods = .{ .ctrl = true } },
        },
    });
    defer set.deinit(alloc);
    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(alloc);
    try set.renderCellMap(
        alloc,
        &result,
        &state,
        null,
        .{},
    );
    try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 1 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
}
