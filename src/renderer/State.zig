const State = @This();
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Inspector = @import("../inspector/root.zig").Inspector;
const terminalpkg = @import("../terminal/main.zig");
const inputpkg = @import("../input.zig");
const renderer = @import("../renderer.zig");
mutex: *std.Io.Mutex,
terminal: *terminalpkg.Terminal,
inspector: ?*Inspector = null,
preedit: ?Preedit = null,
mouse: Mouse = .{},
demand: std.atomic.Value(u32) = .init(0),
handoff_gen: std.atomic.Value(u32) = .init(0),
const handoff_timeout_ns = 1 * std.time.ns_per_ms;
pub fn lockDemand(self: *State, io: std.Io) void {
    _ = self.demand.fetchAdd(1, .monotonic);
    self.mutex.lockUncancelable(io);
    const prev = self.demand.fetchSub(1, .monotonic);
    assert(prev > 0);
}
pub fn unlockDemand(self: *State, io: std.Io) void {
    self.mutex.unlock(io);
    _ = self.handoff_gen.fetchAdd(1, .monotonic);
    io.futexWake(@TypeOf(self.handoff_gen), &self.handoff_gen, 1);
}
pub fn yieldToDemand(self: *State, io: std.Io) void {
    if (self.demand.load(.monotonic) == 0) return;
    const gen = self.handoff_gen.load(.monotonic);
    if (self.demand.load(.monotonic) == 0) return;
    io.futexWaitTimeout(
        @TypeOf(self.handoff_gen),
        &self.handoff_gen,
        .init(gen),
        .{ .duration = .{ .raw = .fromNanoseconds(handoff_timeout_ns), .clock = .awake } },
    ) catch {};
}
pub const Mouse = struct {
    point: ?terminalpkg.point.Coordinate = null,
    mods: inputpkg.Mods = .{},
};
pub const Preedit = struct {
    codepoints: []const Codepoint = &.{},
    pub const Codepoint = struct {
        codepoint: u21,
        wide: bool = false,
    };
    pub fn deinit(self: *const Preedit, alloc: Allocator) void {
        alloc.free(self.codepoints);
    }
    pub fn clone(self: *const Preedit, alloc: Allocator) !Preedit {
        return .{
            .codepoints = try alloc.dupe(Codepoint, self.codepoints),
        };
    }
    pub fn width(self: *const Preedit) usize {
        var result: usize = 0;
        for (self.codepoints) |cp| {
            result += if (cp.wide) 2 else 1;
        }
        return result;
    }
    pub fn range(
        self: *const Preedit,
        start: terminalpkg.size.CellCountInt,
        max: terminalpkg.size.CellCountInt,
    ) struct {
        start: terminalpkg.size.CellCountInt,
        end: terminalpkg.size.CellCountInt,
        cp_offset: usize,
    } {
        const w, const cp_offset = width: {
            const max_width = max - start + 1;
            var w: terminalpkg.size.CellCountInt = 0;
            for (0..self.codepoints.len) |i| {
                const reverse_i = self.codepoints.len - i - 1;
                const cp = self.codepoints[reverse_i];
                w += if (cp.wide) 2 else 1;
                if (w > max_width) {
                    break :width .{ w, reverse_i };
                }
            }
            break :width .{ w, 0 };
        };
        const end = if (w > 0) start + (w - 1) else start;
        const start_offset = if (end > max) end - max else 0;
        return .{
            .start = start -| start_offset,
            .end = end -| start_offset,
            .cp_offset = cp_offset,
        };
    }
};
const test_hangul_ga: u21 = 0xAC00;
test "preedit range covers exact cell width" {
    const testing = std.testing;
    {
        const p: Preedit = .{
            .codepoints = &.{.{ .codepoint = 'a' }},
        };
        const range = p.range(2, 9);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.start);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.end);
        try testing.expectEqual(@as(usize, 0), range.cp_offset);
    }
    {
        const p: Preedit = .{
            .codepoints = &.{.{ .codepoint = test_hangul_ga, .wide = true }},
        };
        const range = p.range(2, 9);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.start);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 3), range.end);
        try testing.expectEqual(@as(usize, 0), range.cp_offset);
    }
}
test "preedit range shifts left at right edge" {
    const testing = std.testing;
    const p: Preedit = .{
        .codepoints = &.{.{ .codepoint = test_hangul_ga, .wide = true }},
    };
    const range = p.range(9, 9);
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 8), range.start);
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 9), range.end);
    try testing.expectEqual(@as(usize, 0), range.cp_offset);
}
