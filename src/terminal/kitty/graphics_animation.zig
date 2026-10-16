const std = @import("std");
const Allocator = std.mem.Allocator;
pub const default_gap_ms: u32 = 40;
pub const Animation = struct {
    frames: std.ArrayListUnmanaged(Frame) = .empty,
    root_gap_ms: u32 = 0,
    current_index: u32 = 0,
    state: State = .stopped,
    max_loops: u32 = 0,
    current_loop: u32 = 0,
    frame_shown_at_ms: ?u64 = null,
    pub const State = enum {
        stopped,
        loading,
        running,
    };
    pub const Frame = struct {
        data: []u8,
        gap_ms: u32,
    };
    pub fn deinit(self: *Animation, alloc: Allocator) void {
        for (self.frames.items) |frame| alloc.free(frame.data);
        self.frames.deinit(alloc);
    }
    pub fn frameCount(self: *const Animation) u32 {
        return @intCast(self.frames.items.len + 1);
    }
    pub fn gapAt(self: *const Animation, index: u32) u32 {
        if (index == 0) return self.root_gap_ms;
        return self.frames.items[index - 1].gap_ms;
    }
    pub fn setGapAt(self: *Animation, index: u32, gap_ms: u32) void {
        if (index == 0) {
            self.root_gap_ms = gap_ms;
        } else {
            self.frames.items[index - 1].gap_ms = gap_ms;
        }
    }
    pub fn durationMs(self: *const Animation) u64 {
        var total: u64 = self.root_gap_ms;
        for (self.frames.items) |frame| total += frame.gap_ms;
        return total;
    }
    pub fn frameBytes(self: *const Animation) usize {
        var total: usize = 0;
        for (self.frames.items) |frame| total += frame.data.len;
        return total;
    }
};
test "animation gap helpers" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var anim: Animation = .{};
    defer anim.deinit(alloc);
    try anim.frames.append(alloc, .{
        .data = try alloc.alloc(u8, 4),
        .gap_ms = 100,
    });
    try testing.expectEqual(@as(u32, 2), anim.frameCount());
    try testing.expectEqual(@as(u32, 0), anim.gapAt(0));
    try testing.expectEqual(@as(u32, 100), anim.gapAt(1));
    try testing.expectEqual(@as(u64, 100), anim.durationMs());
    try testing.expectEqual(@as(usize, 4), anim.frameBytes());
    anim.setGapAt(0, 40);
    anim.setGapAt(1, 60);
    try testing.expectEqual(@as(u64, 100), anim.durationMs());
    try testing.expectEqual(@as(u32, 40), anim.root_gap_ms);
}
