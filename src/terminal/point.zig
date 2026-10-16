const std = @import("std");
const Allocator = std.mem.Allocator;
const lib = @import("lib.zig");
const size = @import("size.zig");
pub const Tag = lib.Enum(lib.target, &.{
    "active",
    "viewport",
    "screen",
    "history",
});
pub const Point = union(Tag) {
    active: Coordinate,
    viewport: Coordinate,
    screen: Coordinate,
    history: Coordinate,
    pub inline fn coord(self: Point) Coordinate {
        return switch (self) {
            .active,
            .viewport,
            .screen,
            .history,
            => |v| v,
        };
    }
    const c_union = lib.TaggedUnion(
        lib.target,
        @This(),
        .{
            .padding = [2]u64,
            .field_renames = .{
                .active = "coordinate",
                .viewport = "coordinate",
                .screen = "coordinate",
                .history = "coordinate",
            },
        },
    );
    pub const C = c_union.C;
    pub const CValue = c_union.CValue;
    pub const cval = c_union.cval;
    pub fn fromC(pt: C) Point {
        return switch (pt.tag) {
            .active => .{ .active = pt.value.active },
            .viewport => .{ .viewport = pt.value.viewport },
            .screen => .{ .screen = pt.value.screen },
            .history => .{ .history = pt.value.history },
        };
    }
};
pub const Coordinate = extern struct {
    x: size.CellCountInt = 0,
    y: u32 = 0,
    pub fn eql(self: Coordinate, other: Coordinate) bool {
        return self.x == other.x and self.y == other.y;
    }
};
