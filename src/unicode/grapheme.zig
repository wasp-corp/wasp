const std = @import("std");
const table = @import("props_table.zig").table;
const uucode = @import("uucode");
pub const GraphemeWidthEffect = enum {
    ignore,
    no_change,
    wide,
    narrow,
};
pub const GraphemeWidth = struct {
    len: usize,
    width: u2,
};
pub fn graphemeBreak(cp1: u21, cp2: u21, state: *uucode.grapheme.BreakState) bool {
    const value = Precompute.data[
        (Precompute.Key{
            .gb1 = table.get(cp1).grapheme_break,
            .gb2 = table.get(cp2).grapheme_break,
            .state = state.*,
        }).index()
    ];
    state.* = value.state;
    return value.result;
}
pub inline fn graphemeWidthEffect(prev: u21, cp: u21) GraphemeWidthEffect {
    if (cp == 0xFE0F or cp == 0xFE0E) {
        const prev_props = table.get(prev);
        if (!prev_props.emoji_vs_base) return .ignore;
        return switch (cp) {
            0xFE0F => .wide,
            0xFE0E => .narrow,
            else => unreachable,
        };
    }
    if (!table.get(cp).width_zero_in_grapheme) return .wide;
    return .no_change;
}
pub fn graphemeWidth(comptime T: type, cps: []const T) GraphemeWidth {
    const check_invalid = comptime @bitSizeOf(T) > @bitSizeOf(u21);
    if (cps.len == 0) return .{ .len = 0, .width = 0 };
    if (check_invalid and invalidCodepoint(cps[0])) return .{ .len = 1, .width = 1 };
    var len: usize = 1;
    var width = table.get(@as(u21, @intCast(cps[0]))).width;
    var prev: u21 = @intCast(cps[0]);
    var state: uucode.grapheme.BreakState = .default;
    while (len < cps.len) : (len += 1) {
        if (check_invalid and invalidCodepoint(cps[len])) break;
        const cp: u21 = @intCast(cps[len]);
        const state_before = state;
        if (graphemeBreak(prev, cp, &state)) break;
        switch (graphemeWidthEffect(prev, cp)) {
            .ignore => state = state_before,
            .no_change => prev = cp,
            .wide => {
                width = 2;
                prev = cp;
            },
            .narrow => {
                width = 1;
                prev = cp;
            },
        }
    }
    return .{ .len = len, .width = width };
}
inline fn invalidCodepoint(cp: anytype) bool {
    return cp > 0x10FFFF;
}
const Precompute = struct {
    const Key = packed struct(u13) {
        state: uucode.grapheme.BreakState,
        gb1: uucode.types.GraphemeBreakNoControl,
        gb2: uucode.types.GraphemeBreakNoControl,
        fn index(self: Key) usize {
            return @intCast(@as(u13, @bitCast(self)));
        }
    };
    const Value = packed struct(u8) {
        result: bool,
        state: uucode.grapheme.BreakState,
        _padding: u4 = 0,
    };
    const data = precompute: {
        var result: [std.math.maxInt(u13) + 1]Value = undefined;
        @setEvalBranchQuota(20_000);
        const info = @typeInfo(uucode.types.GraphemeBreakNoControl).@"enum";
        for (0..uucode.grapheme.BreakState.table_len) |state_int| {
            for (info.fields) |field1| {
                for (info.fields) |field2| {
                    var state: uucode.grapheme.BreakState = .fromTableIndex(state_int);
                    const key: Key = .{
                        .gb1 = @field(uucode.types.GraphemeBreakNoControl, field1.name),
                        .gb2 = @field(uucode.types.GraphemeBreakNoControl, field2.name),
                        .state = state,
                    };
                    const v = uucode.grapheme.computeGraphemeBreakNoControl(
                        key.gb1,
                        key.gb2,
                        &state,
                    );
                    result[key.index()] = .{ .result = v, .state = state };
                }
            }
        }
        std.debug.assert(@sizeOf(@TypeOf(result)) == 8192);
        break :precompute result;
    };
};
pub fn main() !void {
    const min = 0;
    const max = uucode.config.max_code_point + 1;
    var state: uucode.grapheme.BreakState = .default;
    var uu_state: uucode.grapheme.BreakState = .default;
    for (min..max) |cp1| {
        if (cp1 % 1000 == 0) std.log.warn("progress cp1={}", .{cp1});
        if (cp1 == '\r' or cp1 == '\n' or
            uucode.get(.grapheme_break, @intCast(cp1)) == .control) continue;
        for (min..max) |cp2| {
            if (cp2 == '\r' or cp2 == '\n' or
                uucode.get(.grapheme_break, @intCast(cp1)) == .control) continue;
            const gb = graphemeBreak(@intCast(cp1), @intCast(cp2), &state);
            const uu_gb = uucode.grapheme.isBreak(@intCast(cp1), @intCast(cp2), &uu_state);
            if (gb != uu_gb) {
                std.log.warn("cp1={x} cp2={x} gb={} state={} uu_gb={} uu_state={}", .{
                    cp1,
                    cp2,
                    gb,
                    state,
                    uu_gb,
                    uu_state,
                });
            }
        }
    }
}
pub const std_options = struct {
    pub const log_level: std.log.Level = .info;
};
test "grapheme break: emoji modifier" {
    const testing = std.testing;
    {
        var state: uucode.grapheme.BreakState = .default;
        try testing.expect(!graphemeBreak(0x261D, 0x1F3FF, &state));
    }
    {
        var state: uucode.grapheme.BreakState = .default;
        try testing.expect(graphemeBreak(0x22, 0x1F3FF, &state));
    }
}
test "long emoji zwj sequences" {
    var state: uucode.grapheme.BreakState = .default;
    var it = uucode.utf8.Iterator.init("\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}_");
    var cp1 = it.next() orelse unreachable;
    var cp2 = it.next() orelse unreachable;
    try std.testing.expect(cp1 == 0x1F469); 
    try std.testing.expect(!graphemeBreak(cp1, cp2, &state));
    cp1 = cp2;
    cp2 = it.next() orelse unreachable;
    try std.testing.expect(cp1 == 0x200D);
    try std.testing.expect(!graphemeBreak(cp1, cp2, &state));
    cp1 = cp2;
    cp2 = it.next() orelse unreachable;
    try std.testing.expect(cp1 == 0x1F469); 
    try std.testing.expect(!graphemeBreak(cp1, cp2, &state));
    cp1 = cp2;
    cp2 = it.next() orelse unreachable;
    try std.testing.expect(cp1 == 0x200D);
    try std.testing.expect(!graphemeBreak(cp1, cp2, &state));
    cp1 = cp2;
    cp2 = it.next() orelse unreachable;
    try std.testing.expect(cp1 == 0x1F467); 
    try std.testing.expect(!graphemeBreak(cp1, cp2, &state));
    cp1 = cp2;
    cp2 = it.next() orelse unreachable;
    try std.testing.expect(cp1 == 0x200D);
    try std.testing.expect(!graphemeBreak(cp1, cp2, &state));
    cp1 = cp2;
    cp2 = it.next() orelse unreachable;
    try std.testing.expect(cp1 == 0x1F466); 
    try std.testing.expect(graphemeBreak(cp1, cp2, &state)); 
}
test "grapheme width: variation selectors" {
    const testing = std.testing;
    try testing.expectEqual(GraphemeWidthEffect.wide, graphemeWidthEffect(0x2764, 0xFE0F));
    try testing.expectEqual(GraphemeWidthEffect.narrow, graphemeWidthEffect(0x23, 0xFE0E));
    try testing.expectEqual(GraphemeWidthEffect.ignore, graphemeWidthEffect('x', 0xFE0F));
    try testing.expectEqual(GraphemeWidth{ .len = 2, .width = 2 }, graphemeWidth(u21, &.{ 0x2764, 0xFE0F }));
    try testing.expectEqual(GraphemeWidth{ .len = 2, .width = 2 }, graphemeWidth(u21, &.{ 0x23, 0xFE0F }));
    try testing.expectEqual(GraphemeWidth{ .len = 2, .width = 1 }, graphemeWidth(u21, &.{ 'x', 0xFE0F }));
    try testing.expectEqual(GraphemeWidth{ .len = 3, .width = 1 }, graphemeWidth(u21, &.{ 'x', 0xFE0F, 0xFE0F }));
    try testing.expectEqual(GraphemeWidth{ .len = 2, .width = 1 }, graphemeWidth(u21, &.{ 0x23, 0xFE0E }));
    try testing.expectEqual(GraphemeWidth{ .len = 2, .width = 1 }, graphemeWidth(u21, &.{ 0x231A, 0xFE0E }));
    try testing.expectEqual(GraphemeWidth{ .len = 3, .width = 1 }, graphemeWidth(u21, &.{ 0x231A, 0xFE0E, 0xFE0F }));
    try testing.expectEqual(GraphemeWidth{ .len = 4, .width = 2 }, graphemeWidth(u21, &.{ 0x1F3F4, 0x200D, 0x2620, 0xFE0F }));
}
test "grapheme width: emoji sequences" {
    const testing = std.testing;
    try testing.expectEqual(GraphemeWidth{ .len = 5, .width = 2 }, graphemeWidth(u21, &.{ 0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467 }));
    try testing.expectEqual(GraphemeWidth{ .len = 3, .width = 2 }, graphemeWidth(u21, &.{ 0x23, 0xFE0F, 0x20E3 }));
    try testing.expectEqual(GraphemeWidth{ .len = 2, .width = 1 }, graphemeWidth(u21, &.{ '1', 0x20E3 }));
    try testing.expectEqual(GraphemeWidth{ .len = 2, .width = 2 }, graphemeWidth(u21, &.{ 0x1F44B, 0x1F3FF }));
}
test "grapheme width: spacing marks can widen narrow clusters" {
    const testing = std.testing;
    var mark: ?u21 = null;
    for (0..0x110000) |cp_usize| {
        const cp: u21 = @intCast(cp_usize);
        const props = table.get(cp);
        if (props.width != 1 or props.width_zero_in_grapheme) continue;
        var state: uucode.grapheme.BreakState = .default;
        if (!graphemeBreak('a', cp, &state)) {
            mark = cp;
            break;
        }
    }
    try testing.expect(mark != null);
    const cp = mark.?;
    try testing.expectEqual(@as(u2, 1), table.get(cp).width);
    try testing.expect(!table.get(cp).width_zero_in_grapheme);
    try testing.expectEqual(GraphemeWidth{ .len = 2, .width = 2 }, graphemeWidth(u21, &.{ 'a', cp }));
}
test "grapheme width: segmentation" {
    const testing = std.testing;
    try testing.expectEqual(GraphemeWidth{ .len = 1, .width = 1 }, graphemeWidth(u21, &.{'a'}));
    try testing.expectEqual(GraphemeWidth{ .len = 1, .width = 1 }, graphemeWidth(u21, &.{ 'a', 'b' }));
    try testing.expectEqual(GraphemeWidth{ .len = 2, .width = 2 }, graphemeWidth(u21, &.{ 0x1F1E6, 0x1F1E7, 0x1F1E8 }));
    try testing.expectEqual(GraphemeWidth{ .len = 1, .width = 2 }, graphemeWidth(u21, &.{0x1F1E8}));
    try testing.expectEqual(GraphemeWidth{ .len = 0, .width = 0 }, graphemeWidth(u21, &.{}));
    try testing.expectEqual(GraphemeWidth{ .len = 2, .width = 0 }, graphemeWidth(u21, &.{ 0x0301, 0x0302 }));
}
test "grapheme width: u32 invalid codepoints stand alone" {
    const testing = std.testing;
    try testing.expectEqual(GraphemeWidth{ .len = 1, .width = 1 }, graphemeWidth(u32, &.{ 0x110000, 0x0301 }));
    try testing.expectEqual(GraphemeWidth{ .len = 1, .width = 1 }, graphemeWidth(u32, &.{ 'a', 0x110000 }));
}
