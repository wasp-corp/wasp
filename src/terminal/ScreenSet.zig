const ScreenSet = @This();
const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const lib = @import("lib.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Screen = @import("Screen.zig");
pub const Key = lib.Enum(lib.target, &.{
    "primary",
    "alternate",
});
active_key: Key,
active: *Screen,
all: std.EnumMap(Key, *Screen),
generations: std.EnumMap(Key, usize),
pub fn init(
    io: std.Io,
    alloc: Allocator,
    opts: Screen.Options,
) Allocator.Error!ScreenSet {
    const screen = try alloc.create(Screen);
    errdefer alloc.destroy(screen);
    screen.* = try .init(io, alloc, opts);
    return .{
        .active_key = .primary,
        .active = screen,
        .all = .init(.{ .primary = screen }),
        .generations = .initFull(0),
    };
}
pub fn deinit(self: *ScreenSet, alloc: Allocator) void {
    var it = self.all.iterator();
    while (it.next()) |entry| {
        entry.value.*.deinit();
        alloc.destroy(entry.value.*);
    }
}
pub fn get(self: *const ScreenSet, key: Key) ?*Screen {
    return self.all.get(key);
}
pub fn generation(self: *const ScreenSet, key: Key) usize {
    return self.generations.get(key).?;
}
pub fn getInit(
    self: *ScreenSet,
    io: std.Io,
    alloc: Allocator,
    key: Key,
    opts: Screen.Options,
) Allocator.Error!*Screen {
    if (self.get(key)) |screen| return screen;
    const screen = try alloc.create(Screen);
    errdefer alloc.destroy(screen);
    screen.* = try .init(io, alloc, opts);
    self.all.put(key, screen);
    return screen;
}
pub fn remove(
    self: *ScreenSet,
    alloc: Allocator,
    key: Key,
) void {
    assert(key != .primary);
    if (self.all.fetchRemove(key)) |screen| {
        self.generations.put(key, self.generation(key) +% 1);
        screen.deinit();
        alloc.destroy(screen);
    }
}
pub fn switchTo(self: *ScreenSet, key: Key) void {
    self.active_key = key;
    self.active = self.all.get(key).?;
}
test ScreenSet {
    const alloc = testing.allocator;
    const io = testing.io;
    var set: ScreenSet = try .init(io, alloc, .default);
    defer set.deinit(alloc);
    try testing.expectEqual(.primary, set.active_key);
    try testing.expectEqual(@as(usize, 0), set.generation(.primary));
    try testing.expectEqual(@as(usize, 0), set.generation(.alternate));
    _ = try set.getInit(io, alloc, .alternate, .default);
    try testing.expectEqual(@as(usize, 0), set.generation(.alternate));
    set.switchTo(.alternate);
    try testing.expectEqual(.alternate, set.active_key);
}
test "ScreenSet generations" {
    const alloc = testing.allocator;
    const io = testing.io;
    var set: ScreenSet = try .init(io, alloc, .default);
    defer set.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), set.generation(.primary));
    try testing.expectEqual(@as(usize, 0), set.generation(.alternate));
    set.remove(alloc, .alternate);
    try testing.expectEqual(@as(usize, 0), set.generation(.alternate));
    _ = try set.getInit(io, alloc, .alternate, .default);
    try testing.expectEqual(@as(usize, 0), set.generation(.alternate));
    const alternate_generation = set.generation(.alternate);
    set.remove(alloc, .alternate);
    try testing.expectEqual(alternate_generation +% 1, set.generation(.alternate));
    _ = try set.getInit(io, alloc, .alternate, .default);
    try testing.expectEqual(alternate_generation +% 1, set.generation(.alternate));
    try testing.expectEqual(@as(usize, 0), set.generation(.primary));
}
