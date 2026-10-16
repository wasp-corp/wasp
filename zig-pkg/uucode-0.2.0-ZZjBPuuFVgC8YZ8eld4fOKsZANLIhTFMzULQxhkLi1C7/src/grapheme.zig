const std = @import("std");
const types = @import("types.zig");
const getpkg = @import("get.zig");
const utf8 = @import("utf8.zig");
const inlineAssert = @import("config.zig").quirks.inlineAssert;
const get = getpkg.get;
const FieldEnum = getpkg.FieldEnum;
pub const IteratorResult = struct {
    code_point: u21,
    is_break: bool,
};
pub const Grapheme = struct {
    start: usize,
    end: usize,
};
pub fn CustomIterator(
    comptime CodePointIterator: type,
    comptime GB: type,
    comptime grapheme_break_field: FieldEnum,
    comptime customIsBreak: fn (gb1: GB, gb2: GB, state: *BreakState) bool,
) type {
    return struct {
        i: usize,
        state: BreakState,
        next_cp_it: CodePointIterator,
        next_cp: ?u21,
        next_gb: GB,
        const Self = @This();
        pub fn init(cp_it: CodePointIterator) Self {
            var next_cp_it = cp_it;
            const i = next_cp_it.i;
            const next_cp = next_cp_it.next();
            return .{
                .state = .{},
                .i = i,
                .next_cp_it = next_cp_it,
                .next_cp = next_cp,
                .next_gb = if (next_cp) |code_point|
                    get(grapheme_break_field, code_point)
                else
                    .other,
            };
        }
        pub fn nextCodePoint(self: *Self) ?IteratorResult {
            if (self.next_cp == null) return null;
            const cp1 = self.next_cp.?;
            const gb1 = self.next_gb;
            self.i = self.next_cp_it.i;
            self.next_cp = self.next_cp_it.next();
            if (self.next_cp) |cp2| {
                self.next_gb = get(grapheme_break_field, cp2);
                const is_break = customIsBreak(gb1, self.next_gb, &self.state);
                return IteratorResult{
                    .code_point = cp1,
                    .is_break = is_break,
                };
            } else {
                return IteratorResult{
                    .code_point = cp1,
                    .is_break = true,
                };
            }
        }
        pub fn peekCodePoint(self: Self) ?IteratorResult {
            var it = self;
            return it.nextCodePoint();
        }
        pub fn nextGrapheme(self: *Self) ?Grapheme {
            const start = self.i;
            return while (self.nextCodePoint()) |result| {
                if (result.is_break) break .{ .start = start, .end = self.i };
            } else null;
        }
        pub fn peekGrapheme(self: Self) ?Grapheme {
            var it = self;
            return it.nextGrapheme();
        }
    };
}
pub fn Iterator(comptime CodePointIterator: type) type {
    return CustomIterator(
        CodePointIterator,
        types.GraphemeBreak,
        .grapheme_break,
        precomputedGraphemeBreak,
    );
}
pub fn utf8Iterator(bytes: []const u8) Iterator(utf8.Iterator) {
    return Iterator(utf8.Iterator).init(.init(bytes));
}
test "Iterator nextCodePoint/peekCodePoint" {
    const str = "👩🏽‍🚀🇨🇭";
    var it = Iterator(utf8.Iterator).init(.init(str));
    try std.testing.expect(it.i == 0);
    var result = it.peekCodePoint();
    try std.testing.expect(it.i == 0);
    try std.testing.expect(result.?.code_point == 0x1F469); 
    try std.testing.expect(result.?.is_break == false);
    result = it.nextCodePoint();
    try std.testing.expect(it.i == 4);
    try std.testing.expect(result.?.code_point == 0x1F469); 
    try std.testing.expect(result.?.is_break == false);
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x1F3FD); 
    try std.testing.expect(result.?.is_break == false);
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x200D); 
    try std.testing.expect(result.?.is_break == false);
    result = it.peekCodePoint();
    try std.testing.expect(result.?.code_point == 0x1F680); 
    try std.testing.expect(result.?.is_break == true);
    result = it.nextCodePoint();
    try std.testing.expect(it.i == 15);
    try std.testing.expect(result.?.code_point == 0x1F680); 
    try std.testing.expect(result.?.is_break == true);
    try std.testing.expect(std.mem.eql(u8, str[0..it.i], "👩🏽‍🚀"));
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x1F1E8); 
    try std.testing.expect(result.?.is_break == false);
    result = it.nextCodePoint();
    try std.testing.expect(it.i == str.len);
    try std.testing.expect(result.?.code_point == 0x1F1ED); 
    try std.testing.expect(result.?.is_break == true);
    try std.testing.expect(it.peekCodePoint() == null);
    try std.testing.expect(it.nextCodePoint() == null);
    try std.testing.expect(it.nextCodePoint() == null);
}
test "utf8Iterator nextGrapheme/peekGrapheme" {
    const str = "👩🏽‍🚀🇨🇭👨🏻‍🍼";
    var it = utf8Iterator(str);
    try std.testing.expect(it.i == 0);
    var result = it.peekGrapheme();
    try std.testing.expect(result.?.start == 0);
    try std.testing.expect(result.?.end == 15);
    try std.testing.expect(it.i == 0);
    result = it.nextGrapheme();
    try std.testing.expect(result.?.start == 0);
    try std.testing.expect(result.?.end == 15);
    try std.testing.expect(it.i == 15);
    try std.testing.expect(std.mem.eql(u8, str[result.?.start..result.?.end], "👩🏽‍🚀"));
    result = it.nextGrapheme();
    try std.testing.expect(result.?.start == 15);
    try std.testing.expect(result.?.end == 23);
    try std.testing.expect(it.i == 23);
    try std.testing.expect(std.mem.eql(u8, str[result.?.start..result.?.end], "🇨🇭"));
    result = it.peekGrapheme();
    try std.testing.expect(result.?.start == 23);
    try std.testing.expect(result.?.end == str.len);
    try std.testing.expect(std.mem.eql(u8, str[result.?.start..result.?.end], "👨🏻‍🍼"));
    result = it.nextGrapheme();
    try std.testing.expect(result.?.start == 23);
    try std.testing.expect(result.?.end == str.len);
    try std.testing.expect(it.i == str.len);
    try std.testing.expect(it.peekGrapheme() == null);
    try std.testing.expect(it.nextGrapheme() == null);
    try std.testing.expect(it.nextGrapheme() == null);
}
pub const BreakState = packed struct(u3) {
    after_linker: bool = false,
    base: Base = .default,
    pub const Base = enum(u2) {
        default,
        extended_pictographic,
        regional_indicator,
    };
    pub const default: BreakState = .{};
    pub const table_len = @typeInfo(Base).@"enum".fields.len * 2 - 1;
    pub inline fn tableIndex(self: BreakState) usize {
        return @as(u3, @bitCast(self));
    }
    pub fn fromTableIndex(i: usize) BreakState {
        return @bitCast(@as(u3, @intCast(i)));
    }
};
test "BreakState table index layout" {
    try std.testing.expectEqual(0, (BreakState{}).tableIndex());
    try std.testing.expectEqual(1, (BreakState{ .after_linker = true }).tableIndex());
    try std.testing.expectEqual(2, (BreakState{ .base = .extended_pictographic }).tableIndex());
    try std.testing.expectEqual(3, (BreakState{ .base = .extended_pictographic, .after_linker = true }).tableIndex());
    try std.testing.expectEqual(4, (BreakState{ .base = .regional_indicator }).tableIndex());
    try std.testing.expectEqual(5, BreakState.table_len);
    try std.testing.expectEqual(5, (BreakState{ .base = .regional_indicator, .after_linker = true }).tableIndex());
    for (0..BreakState.table_len) |i| {
        try std.testing.expectEqual(i, BreakState.fromTableIndex(i).tableIndex());
    }
}
pub fn computeGraphemeBreak(
    gb1: types.GraphemeBreak,
    gb2: types.GraphemeBreak,
    state: *BreakState,
) bool {
    const after_linker = isIndicConjunctBreakLinker(gb1) or
        (state.after_linker and isIndicConjunctBreakExtend(gb1));
    state.after_linker = after_linker and isIndicConjunctBreakExtend(gb2);
    switch (state.base) {
        .regional_indicator => {
            if (gb1 != .regional_indicator or gb2 != .regional_indicator) {
                state.base = .default;
            }
        },
        .extended_pictographic => {
            switch (gb1) {
                .indic_conjunct_break_extend, 
                .indic_conjunct_break_linker_extend, 
                .zwnj, 
                .zwj,
                .extended_pictographic,
                .emoji_modifier_base,
                .emoji_modifier,
                => {},
                else => state.base = .default,
            }
            switch (gb2) {
                .indic_conjunct_break_extend, 
                .indic_conjunct_break_linker_extend, 
                .zwnj, 
                .zwj,
                .extended_pictographic,
                .emoji_modifier_base,
                .emoji_modifier,
                => {},
                else => state.base = .default,
            }
        },
        .default => {},
    }
    if (gb1 == .cr and gb2 == .lf) return false;
    if (gb1 == .control or gb1 == .cr or gb1 == .lf) return true;
    if (gb2 == .control or gb2 == .cr or gb2 == .lf) return true;
    if (gb1 == .l) {
        if (gb2 == .l or
            gb2 == .v or
            gb2 == .lv or
            gb2 == .lvt) return false;
    }
    if (gb1 == .lv or gb1 == .v) {
        if (gb2 == .v or gb2 == .t) return false;
    }
    if (gb1 == .lvt or gb1 == .t) {
        if (gb2 == .t) return false;
    }
    if (gb2 == .spacing_mark) return false;
    if (gb1 == .prepend) return false;
    if (after_linker and gb2 == .indic_conjunct_break_consonant) {
        state.base = .default;
        return false;
    }
    if (isExtendedPictographic(gb1)) {
        if (isExtend(gb2) or gb2 == .zwj) {
            state.base = .extended_pictographic;
            return false;
        }
        if (gb1 == .emoji_modifier_base and gb2 == .emoji_modifier) {
            state.base = .extended_pictographic;
            return false;
        }
    } else if (state.base == .extended_pictographic) {
        if ((isExtend(gb1) or gb1 == .emoji_modifier) and
            (isExtend(gb2) or gb2 == .zwj))
        {
            return false;
        } else if (gb1 == .zwj and isExtendedPictographic(gb2)) {
            state.base = .default;
            return false;
        } else {
            state.base = .default;
        }
    }
    if (gb1 == .regional_indicator and gb2 == .regional_indicator) {
        if (state.base == .default) {
            state.base = .regional_indicator;
            return false;
        } else {
            state.base = .default;
            return true;
        }
    }
    if (isExtend(gb2) or gb2 == .zwj) return false;
    return true;
}
test "Unicode 18 Indic linker boundaries and overlapping emoji sequences" {
    const cases = [_]struct { cps: []const u21, breaks: []const bool }{
        .{ .cps = &.{ 0x094D, 0x0915 }, .breaks = &.{false} },
        .{ .cps = &.{ 0x0061, 0x094D, 0x0915 }, .breaks = &.{ false, false } },
        .{ .cps = &.{ 0x094D, 0x0300, 0x200D, 0x0915 }, .breaks = &.{ false, false, false } },
        .{ .cps = &.{ 0x094D, 0x094D, 0x0915 }, .breaks = &.{ false, false } },
        .{ .cps = &.{ 0x0915, 0x0300, 0x0915 }, .breaks = &.{ false, true } },
        .{ .cps = &.{ 0x094D, 0x0915, 0x0300, 0x0915 }, .breaks = &.{ false, false, true } },
        .{ .cps = &.{ 0x094D, 0x200C, 0x0300, 0x0915 }, .breaks = &.{ false, false, true } },
        .{ .cps = &.{ 0x094D, 0x0903, 0x0915 }, .breaks = &.{ false, true } },
        .{ .cps = &.{ 0x094D, 0x1F3FB, 0x0915 }, .breaks = &.{ true, true } },
        .{ .cps = &.{ 0x0061, 0x1CF5, 0x0300, 0x0915 }, .breaks = &.{ true, false, false } },
        .{ .cps = &.{ 0x0061, 0x1CF6, 0x0915 }, .breaks = &.{ true, false } },
        .{ .cps = &.{ 0x0061, 0x11A3A, 0x11A0B }, .breaks = &.{ true, false } },
        .{ .cps = &.{ 0x11A3A, 0x0061 }, .breaks = &.{true} },
        .{ .cps = &.{ 0x1F600, 0x094D, 0x0300, 0x200D, 0x1F600 }, .breaks = &.{ false, false, false, false } },
        .{ .cps = &.{ 0x1F600, 0x094D, 0x0300, 0x0915 }, .breaks = &.{ false, false, false } },
        .{ .cps = &.{ 0x1F600, 0x094D, 0x200C, 0x200D, 0x1F600 }, .breaks = &.{ false, false, false, false } },
        .{ .cps = &.{ 0x1F600, 0x094D, 0x200C, 0x0915 }, .breaks = &.{ false, false, true } },
        .{ .cps = &.{ 0x1F44D, 0x1F3FB, 0x094D, 0x0915 }, .breaks = &.{ false, false, false } },
        .{ .cps = &.{ 0x1F600, 0x1CF5, 0x0915 }, .breaks = &.{ true, false } },
    };
    inline for (.{ testGetActualComputedGraphemeBreak, isBreak, testGetActualComputedGraphemeBreakNoControl, isBreakNoControl }) |check| {
        for (cases) |case| {
            var state: BreakState = .{};
            for (case.breaks, 0..) |expected, i| {
                try std.testing.expectEqual(expected, check(case.cps[i], case.cps[i + 1], &state));
            }
        }
    }
}
fn isIndicConjunctBreakExtend(gb: types.GraphemeBreak) bool {
    return gb == .indic_conjunct_break_extend or gb == .zwj;
}
fn isIndicConjunctBreakLinker(gb: types.GraphemeBreak) bool {
    return gb == .indic_conjunct_break_linker_extend or
        gb == .indic_conjunct_break_linker_other;
}
fn isExtend(gb: types.GraphemeBreak) bool {
    return gb == .zwnj or
        gb == .indic_conjunct_break_extend or
        gb == .indic_conjunct_break_linker_extend;
}
fn isExtendedPictographic(gb: types.GraphemeBreak) bool {
    return gb == .extended_pictographic or gb == .emoji_modifier_base;
}
fn testGraphemeBreak(getActualIsBreak: fn (cp1: u21, cp2: u21, state: *BreakState) bool) !void {
    const comps = @import("config.zig").components;
    const trim = comps.trim;
    const parseCp = comps.parseCp;
    const allocator = std.testing.allocator;
    const file_path = "ucd/auxiliary/GraphemeBreakTest.txt";
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, file_path, .{});
    defer file.close(std.testing.io);
    var buf: [2048]u8 = undefined;
    var file_reader = file.reader(std.testing.io, &buf);
    const content = try file_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(content);
    var lines = std.mem.splitScalar(u8, content, '\n');
    var success = true;
    var line_num: usize = 1;
    while (lines.next()) |line| : (line_num += 1) {
        const trimmed = trim(line);
        if (trimmed.len == 0) continue;
        var parts = std.mem.splitScalar(u8, trimmed, ' ');
        const start = parts.next().?;
        try std.testing.expect(std.mem.eql(u8, start, "÷"));
        var state: BreakState = .{};
        var cp1 = try parseCp(parts.next().?);
        var gb1 = get(.grapheme_break, cp1);
        var expected_str = parts.next().?;
        var cp2 = try parseCp(parts.next().?);
        var gb2 = get(.grapheme_break, cp2);
        var next_expected_str = parts.next().?;
        while (true) {
            var expected_is_break = std.mem.eql(u8, expected_str, "÷");
            const actual_is_break = getActualIsBreak(cp1, cp2, &state);
            try std.testing.expect(expected_is_break or std.mem.eql(u8, expected_str, "×"));
            if (gb2 == .emoji_modifier and gb1 != .emoji_modifier_base) {
                inlineAssert(!expected_is_break);
                expected_is_break = true;
            }
            if (actual_is_break != expected_is_break) {
                std.log.err("line={d} cp1={x}, cp2={x}: gb1={}, gb2={}, state={}, expected={}, actual={}", .{
                    line_num,
                    cp1,
                    cp2,
                    gb1,
                    gb2,
                    state,
                    expected_is_break,
                    actual_is_break,
                });
                success = false;
            }
            if (parts.peek() == null) break;
            cp1 = cp2;
            gb1 = gb2;
            expected_str = next_expected_str;
            cp2 = try parseCp(parts.next().?);
            gb2 = get(.grapheme_break, cp2);
            next_expected_str = parts.next().?;
        }
        try std.testing.expect(std.mem.eql(u8, next_expected_str, "÷"));
    }
    try std.testing.expect(success);
}
fn testGetActualComputedGraphemeBreak(cp1: u21, cp2: u21, state: *BreakState) bool {
    const gb1 = get(.grapheme_break, cp1);
    const gb2 = get(.grapheme_break, cp2);
    return computeGraphemeBreak(gb1, gb2, state);
}
test "GraphemeBreakTest.txt - computeGraphemeBreak" {
    try testGraphemeBreak(testGetActualComputedGraphemeBreak);
}
pub fn GraphemeBreakTable(comptime GB: type) type {
    const Result = packed struct {
        result: bool,
        state: BreakState,
    };
    const gb_fields = @typeInfo(GB).@"enum".fields;
    const n_gb = gb_fields.len;
    const n_gb_2 = n_gb * n_gb;
    const n = BreakState.table_len * n_gb_2;
    inlineAssert(gb_fields[gb_fields.len - 1].value == n_gb - 1);
    return struct {
        data: [n]Result,
        inline fn index(gb1: GB, gb2: GB, state: BreakState) usize {
            return state.tableIndex() * n_gb_2 + @intFromEnum(gb1) * n_gb + @intFromEnum(gb2);
        }
        pub fn set(self: *@This(), gb1: GB, gb2: GB, state: BreakState, result: Result) void {
            self.data[index(gb1, gb2, state)] = result;
        }
        pub fn get(self: @This(), gb1: GB, gb2: GB, state: BreakState) Result {
            return self.data[index(gb1, gb2, state)];
        }
    };
}
pub fn buildGraphemeBreakTable(
    comptime GB: type,
    compute: fn (gb1: GB, gb2: GB, state: *BreakState) bool,
) GraphemeBreakTable(GB) {
    @setEvalBranchQuota(30_000);
    var table: GraphemeBreakTable(GB) = undefined;
    const gb_fields = @typeInfo(GB).@"enum".fields;
    for (0..BreakState.table_len) |state_i| {
        for (gb_fields) |gb1_field| {
            for (gb_fields) |gb2_field| {
                const original_state = BreakState.fromTableIndex(state_i);
                const gb1: GB = @enumFromInt(gb1_field.value);
                const gb2: GB = @enumFromInt(gb2_field.value);
                var state = original_state;
                const result = compute(gb1, gb2, &state);
                inlineAssert(state.tableIndex() < BreakState.table_len);
                table.set(gb1, gb2, original_state, .{
                    .result = result,
                    .state = state,
                });
            }
        }
    }
    return table;
}
pub fn precomputedGraphemeBreak(
    gb1: types.GraphemeBreak,
    gb2: types.GraphemeBreak,
    state: *BreakState,
) bool {
    const table = comptime buildGraphemeBreakTable(
        types.GraphemeBreak,
        computeGraphemeBreak,
    );
    inlineAssert(@sizeOf(@TypeOf(table)) == 2205);
    const result = table.get(gb1, gb2, state.*);
    state.* = result.state;
    return result.result;
}
pub fn isBreak(
    cp1: u21,
    cp2: u21,
    state: *BreakState,
) bool {
    const gb1 = get(.grapheme_break, cp1);
    const gb2 = get(.grapheme_break, cp2);
    return precomputedGraphemeBreak(gb1, gb2, state);
}
test "GraphemeBreakTest.txt - isBreak" {
    try testGraphemeBreak(isBreak);
}
test "long emoji zwj sequences" {
    var it = utf8Iterator("\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}_");
    var result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x1F469); 
    try std.testing.expect(!result.?.is_break);
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x200D);
    try std.testing.expect(!result.?.is_break);
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x1F469); 
    try std.testing.expect(!result.?.is_break);
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x200D);
    try std.testing.expect(!result.?.is_break);
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x1F467); 
    try std.testing.expect(!result.?.is_break);
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x200D);
    try std.testing.expect(!result.?.is_break);
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x1F466); 
    try std.testing.expect(result.?.is_break); 
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == '_');
    try std.testing.expect(result.?.is_break); 
}
test "long emoji zwj sequences with emoji modifiers" {
    var it = utf8Iterator("\u{1F468}\u{1F3FB}\u{200D}\u{2764}\u{FE0F}\u{200D}\u{1F48B}\u{200D}\u{1F468}\u{1F3FF}_");
    var result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x1F468); 
    try std.testing.expect(!result.?.is_break);
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x1F3FB); 
    try std.testing.expect(!result.?.is_break);
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x200D); 
    try std.testing.expect(!result.?.is_break);
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x2764); 
    try std.testing.expect(!result.?.is_break);
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0xFE0F); 
    try std.testing.expect(!result.?.is_break);
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x200D); 
    try std.testing.expect(!result.?.is_break);
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x1F48B); 
    try std.testing.expect(!result.?.is_break);
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x200D); 
    try std.testing.expect(!result.?.is_break);
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x1F468); 
    try std.testing.expect(!result.?.is_break);
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x1F3FF); 
    try std.testing.expect(result.?.is_break); 
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == '_');
    try std.testing.expect(result.?.is_break); 
}
test "sequence of regional indicators" {
    var it = utf8Iterator("\u{1F1FA}\u{1F1F8}\u{1F1E6}\u{1F1F9}\u{1F1FC}_\u{1F1F3}_");
    var result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x1F1FA); 
    try std.testing.expect(it.state.base == .regional_indicator);
    try std.testing.expect(!result.?.is_break);
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x1F1F8); 
    try std.testing.expect(it.state.base == .default);
    try std.testing.expect(result.?.is_break); 
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x1F1E6); 
    try std.testing.expect(!result.?.is_break);
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x1F1F9); 
    try std.testing.expect(result.?.is_break); 
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x1F1FC); 
    try std.testing.expect(result.?.is_break); 
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == '_');
    try std.testing.expect(result.?.is_break); 
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x1F1F3); 
    try std.testing.expect(result.?.is_break); 
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == '_');
    try std.testing.expect(result.?.is_break); 
}
pub fn wcwidthNext(it: anytype) usize {
    inlineAssert(@typeInfo(@TypeOf(it)) == .pointer);
    const first = it.nextCodePoint() orelse return 0;
    var prev_cp: u21 = first.code_point;
    const standalone = get(.wcwidth_standalone, prev_cp);
    if (first.is_break) return standalone;
    var width: usize = if (get(.wcwidth_zero_in_grapheme, prev_cp))
        0
    else
        standalone;
    var prev_state: BreakState = it.state;
    inlineAssert(it.peekCodePoint() != null);
    code_points: while (it.nextCodePoint()) |result| {
        switch (result.code_point) {
            0xFE0F => {
                if (get(.is_emoji_vs_base, prev_cp)) {
                    width = 2;
                }
            },
            0xFE0E => {
                if (get(.is_emoji_vs_base, prev_cp)) {
                    width = 1;
                }
            },
            0x200D => {
                if (prev_state.base == .extended_pictographic and
                    !result.is_break)
                {
                    const next = it.nextCodePoint() orelse unreachable;
                    if (next.is_break) break;
                    prev_cp = next.code_point;
                    prev_state = it.state;
                    continue :code_points;
                }
            },
            0x1F3FB, 0x1F3FC, 0x1F3FD, 0x1F3FE, 0x1F3FF => {
                width = 2;
                inlineAssert(
                    (comptime !getpkg.hasField("is_emoji_modifier_base")) or
                        get(.is_emoji_modifier_base, prev_cp),
                );
            },
            else => {
                if (prev_state.base == .regional_indicator) {
                    width = 2;
                } else if (!get(.wcwidth_zero_in_grapheme, result.code_point)) {
                    width += get(.wcwidth_standalone, result.code_point);
                }
            },
        }
        if (result.is_break) break;
        prev_cp = result.code_point;
        prev_state = it.state;
    }
    return width;
}
pub fn wcwidth(const_it: anytype) usize {
    var it = const_it;
    return wcwidthNext(&it);
}
pub fn wcwidthRemaining(it: anytype) usize {
    var width: usize = 0;
    while (it.next_cp != null) {
        width += wcwidthNext(it);
    }
    return width;
}
pub fn utf8Wcwidth(s: []const u8) usize {
    var it = utf8Iterator(s);
    return wcwidthRemaining(&it);
}
test "wcwidthNext iterator state" {
    const str = "A\u{0300}B";
    var it = utf8Iterator(str);
    const w1 = wcwidthNext(&it);
    try std.testing.expectEqual(1, w1);
    try std.testing.expectEqual(3, it.i);
    const w2 = wcwidthNext(&it);
    try std.testing.expectEqual(1, w2);
    try std.testing.expectEqual(4, it.i);
    try std.testing.expect(it.peekCodePoint() == null);
}
test "wcwidthRemaining" {
    var it1 = utf8Iterator("A\u{0300}B");
    try std.testing.expectEqual(2, wcwidthRemaining(&it1));
    var it2 = utf8Iterator("ABC");
    try std.testing.expectEqual(3, wcwidthRemaining(&it2));
    var it3 = utf8Iterator("😀AB");
    try std.testing.expectEqual(4, wcwidthRemaining(&it3));
    var it4 = utf8Iterator("");
    try std.testing.expectEqual(0, wcwidthRemaining(&it4));
    var it5 = utf8Iterator("ABC");
    _ = wcwidthNext(&it5);
    try std.testing.expectEqual(2, wcwidthRemaining(&it5));
}
test "utf8Wcwidth" {
    try std.testing.expectEqual(2, utf8Wcwidth("A\u{0300}B"));
}
test "wcwidth{,Next,Remaining} README example" {
    const str = "ò👨🏻‍❤️‍👨🏿_";
    var it = utf8Iterator(str);
    try std.testing.expectEqual(1, wcwidth(it));
    try std.testing.expectEqual(1, wcwidthNext(&it));
    const grapheme_result = it.peekGrapheme();
    try std.testing.expectEqualStrings("👨🏻‍❤️‍👨🏿", str[grapheme_result.?.start..grapheme_result.?.end]);
    try std.testing.expectEqual(3, wcwidthRemaining(&it));
    try std.testing.expectEqual(4, utf8Wcwidth(str));
}
test "wcwidth ascii" {
    const it1 = utf8Iterator("A");
    try std.testing.expectEqual(1, wcwidth(it1));
    const it2 = utf8Iterator("1");
    try std.testing.expectEqual(1, wcwidth(it2));
}
test "wcwidth control" {
    const it1 = utf8Iterator("\x00");
    try std.testing.expectEqual(0, wcwidth(it1));
    const it2 = utf8Iterator("\x7F");
    try std.testing.expectEqual(0, wcwidth(it2));
}
test "wcwidth default ignorable" {
    const it1 = utf8Iterator("\u{200B}");
    try std.testing.expectEqual(0, wcwidth(it1));
    const it2 = utf8Iterator("\u{3164}");
    try std.testing.expectEqual(0, wcwidth(it2));
}
test "wcwidth marks standing alone" {
    const it = utf8Iterator("\u{0300}");
    try std.testing.expectEqual(1, wcwidth(it));
}
test "wcwidth keycap standing alone" {
    const it = utf8Iterator("\u{20E3}");
    try std.testing.expectEqual(2, wcwidth(it));
}
test "wcwidth regional indicator standing alone" {
    const it = utf8Iterator("\u{1F1E6}");
    try std.testing.expectEqual(2, wcwidth(it));
}
test "wcwidth emoji" {
    const it = utf8Iterator("😀");
    try std.testing.expectEqual(2, wcwidth(it));
}
test "wcwidth ambiguous" {
    const it = utf8Iterator("\u{00A1}");
    try std.testing.expectEqual(1, wcwidth(it));
}
test "wcwidth fullwidth" {
    const it = utf8Iterator("\u{3000}");
    try std.testing.expectEqual(2, wcwidth(it));
}
test "wcwidth soft hyphen" {
    const it = utf8Iterator("\u{00AD}");
    try std.testing.expectEqual(1, wcwidth(it));
}
test "wcwidth sequence base + nonspacing marks" {
    const it = utf8Iterator("A\u{0300}");
    try std.testing.expectEqual(1, wcwidth(it));
}
test "wcwidth sequence base + spacing marks" {
    const it = utf8Iterator("\u{0905}\u{0903}");
    try std.testing.expectEqual(2, wcwidth(it));
}
test "wcwidth sequence emoji + modifier" {
    const it = utf8Iterator("\u{1F466}\u{1F3FB}");
    try std.testing.expectEqual(2, wcwidth(it));
}
test "wcwidth sequence emoji with default text presentation + modifier" {
    const it = utf8Iterator("\u{1F3CB}\u{1F3FE}");
    try std.testing.expectEqual(2, wcwidth(it));
}
test "wcwidth sequence emoji with default text presentation + VS16" {
    const it = utf8Iterator("\u{2601}\u{FE0F}");
    try std.testing.expectEqual(2, wcwidth(it));
}
test "wcwidth sequence emoji with default text presentation + VS15" {
    const it = utf8Iterator("\u{2601}\u{FE0E}");
    try std.testing.expectEqual(1, wcwidth(it));
}
test "wcwidth sequence emoji with default emoji presentation + VS16" {
    const it = utf8Iterator("\u{23F0}\u{FE0F}");
    try std.testing.expectEqual(2, wcwidth(it));
}
test "wcwidth sequence emoji not in emoji-variation-sequences + VS16" {
    const it = utf8Iterator("\u{1F5FF}\u{FE0F}");
    try std.testing.expectEqual(2, wcwidth(it));
}
test "wcwidth sequence emoji not in emoji-variation-sequences + VS15" {
    const it = utf8Iterator("\u{1F5FF}\u{FE0E}");
    try std.testing.expectEqual(2, wcwidth(it));
}
test "wcwidth sequence text not in emoji-variation-sequences + VS16" {
    const it = utf8Iterator("V\u{FE0F}");
    try std.testing.expectEqual(1, wcwidth(it));
}
test "wcwidth sequence text not in emoji-variation-sequences + VS15" {
    const it = utf8Iterator("V\u{FE0E}");
    try std.testing.expectEqual(1, wcwidth(it));
}
test "wcwidth sequence emoji with default emoji presentation + VS15" {
    const it = utf8Iterator("\u{23F0}\u{FE0E}");
    try std.testing.expectEqual(1, wcwidth(it));
}
test "wcwidth sequence keycap" {
    const it = utf8Iterator("1\u{FE0F}\u{20E3}");
    try std.testing.expectEqual(2, wcwidth(it));
}
test "wcwidth sequence regional indicator full" {
    const it = utf8Iterator("\u{1F1FA}\u{1F1F8}");
    try std.testing.expectEqual(2, wcwidth(it));
}
test "wcwidth sequence emoji zwj" {
    const it = utf8Iterator("\u{1F468}\u{200D}\u{1F33E}_");
    try std.testing.expectEqual(2, wcwidth(it));
}
test "wcwidth sequence emoji zwj long" {
    const it = utf8Iterator("\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}_");
    try std.testing.expectEqual(2, wcwidth(it));
}
test "wcwidth sequence emoji zwj long with emoji modifiers" {
    const it = utf8Iterator("\u{1F468}\u{1F3FB}\u{200D}\u{2764}\u{FE0F}\u{200D}\u{1F48B}\u{200D}\u{1F468}\u{1F3FF}_");
    try std.testing.expectEqual(2, wcwidth(it));
}
test "wcwidth Hangul L+V" {
    const it = utf8Iterator("\u{1100}\u{1161}");
    try std.testing.expectEqual(2, wcwidth(it));
}
test "wcwidth Hangul L+V+T" {
    const it = utf8Iterator("\u{1100}\u{1161}\u{11A8}");
    try std.testing.expectEqual(2, wcwidth(it));
}
test "wcwidth Hangul L+L+V" {
    const it = utf8Iterator("\u{1100}\u{1100}\u{1161}");
    try std.testing.expectEqual(4, wcwidth(it));
}
test "wcwidth Hangul LV+T" {
    const it = utf8Iterator("\u{AC00}\u{11A8}");
    try std.testing.expectEqual(2, wcwidth(it));
}
test "wcwidth Devanagari with ZWJ" {
    const str = "क्‍ष";
    const it = Iterator(utf8.Iterator).init(.init(str));
    try std.testing.expect(wcwidth(it) == 2);
}
test "wcwidth Devanagari 3 consonants" {
    const it = utf8Iterator("\u{0915}\u{094D}\u{0915}\u{094D}\u{0915}");
    try std.testing.expectEqual(3, wcwidth(it));
}
test "wcwidth prepend characters standing alone are width 1" {
    const it = utf8Iterator("\u{0D4E}");
    try std.testing.expectEqual(1, wcwidth(it));
}
test "wcwidth prepend characters don't contribute to width in grapheme cluster" {
    const it = utf8Iterator("\u{0D4E}\u{0D39}");
    try std.testing.expectEqual(1, wcwidth(it));
}
pub fn IteratorNoControl(comptime CodePointIterator: type) type {
    return CustomIterator(
        CodePointIterator,
        types.GraphemeBreakNoControl,
        .grapheme_break_no_control,
        precomputedGraphemeBreakNoControl,
    );
}
pub fn utf8IteratorNoControl(bytes: []const u8) IteratorNoControl(utf8.Iterator) {
    return IteratorNoControl(utf8.Iterator).init(.init(bytes));
}
test "IteratorNoControl nextCodePoint/peekCodePoint" {
    const str = "👩🏽‍🚀🇨🇭";
    var it = utf8IteratorNoControl(str);
    try std.testing.expect(it.i == 0);
    var result = it.peekCodePoint();
    try std.testing.expect(it.i == 0);
    try std.testing.expect(result.?.code_point == 0x1F469);
    try std.testing.expect(result.?.is_break == false);
    result = it.nextCodePoint();
    try std.testing.expect(it.i == 4);
    try std.testing.expect(result.?.code_point == 0x1F469);
    try std.testing.expect(result.?.is_break == false);
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x1F3FD);
    try std.testing.expect(result.?.is_break == false);
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x200D);
    try std.testing.expect(result.?.is_break == false);
    result = it.peekCodePoint();
    try std.testing.expect(result.?.code_point == 0x1F680);
    try std.testing.expect(result.?.is_break == true);
    result = it.nextCodePoint();
    try std.testing.expect(it.i == 15);
    try std.testing.expect(result.?.code_point == 0x1F680);
    try std.testing.expect(result.?.is_break == true);
    try std.testing.expect(std.mem.eql(u8, str[0..it.i], "👩🏽‍🚀"));
    result = it.nextCodePoint();
    try std.testing.expect(result.?.code_point == 0x1F1E8);
    try std.testing.expect(result.?.is_break == false);
    result = it.nextCodePoint();
    try std.testing.expect(it.i == str.len);
    try std.testing.expect(result.?.code_point == 0x1F1ED);
    try std.testing.expect(result.?.is_break == true);
    try std.testing.expect(it.peekCodePoint() == null);
    try std.testing.expect(it.nextCodePoint() == null);
    try std.testing.expect(it.nextCodePoint() == null);
}
pub fn computeGraphemeBreakNoControl(
    gb1: types.GraphemeBreakNoControl,
    gb2: types.GraphemeBreakNoControl,
    state: *BreakState,
) bool {
    const after_linker = isIndicConjunctBreakLinkerNoControl(gb1) or
        (state.after_linker and isIndicConjunctBreakExtendNoControl(gb1));
    state.after_linker = after_linker and isIndicConjunctBreakExtendNoControl(gb2);
    switch (state.base) {
        .regional_indicator => {
            if (gb1 != .regional_indicator or gb2 != .regional_indicator) {
                state.base = .default;
            }
        },
        .extended_pictographic => {
            switch (gb1) {
                .indic_conjunct_break_extend,
                .indic_conjunct_break_linker_extend,
                .zwnj,
                .zwj,
                .extended_pictographic,
                .emoji_modifier_base,
                .emoji_modifier,
                => {},
                else => state.base = .default,
            }
            switch (gb2) {
                .indic_conjunct_break_extend,
                .indic_conjunct_break_linker_extend,
                .zwnj,
                .zwj,
                .extended_pictographic,
                .emoji_modifier_base,
                .emoji_modifier,
                => {},
                else => state.base = .default,
            }
        },
        .default => {},
    }
    if (gb1 == .l) {
        if (gb2 == .l or
            gb2 == .v or
            gb2 == .lv or
            gb2 == .lvt) return false;
    }
    if (gb1 == .lv or gb1 == .v) {
        if (gb2 == .v or gb2 == .t) return false;
    }
    if (gb1 == .lvt or gb1 == .t) {
        if (gb2 == .t) return false;
    }
    if (gb2 == .spacing_mark) return false;
    if (gb1 == .prepend) return false;
    if (after_linker and gb2 == .indic_conjunct_break_consonant) {
        state.base = .default;
        return false;
    }
    if (isExtendedPictographicNoControl(gb1)) {
        if (isExtendNoControl(gb2) or gb2 == .zwj) {
            state.base = .extended_pictographic;
            return false;
        }
        if (gb1 == .emoji_modifier_base and gb2 == .emoji_modifier) {
            state.base = .extended_pictographic;
            return false;
        }
    } else if (state.base == .extended_pictographic) {
        if ((isExtendNoControl(gb1) or gb1 == .emoji_modifier) and
            (isExtendNoControl(gb2) or gb2 == .zwj))
        {
            return false;
        } else if (gb1 == .zwj and isExtendedPictographicNoControl(gb2)) {
            state.base = .default;
            return false;
        } else {
            state.base = .default;
        }
    }
    if (gb1 == .regional_indicator and gb2 == .regional_indicator) {
        if (state.base == .default) {
            state.base = .regional_indicator;
            return false;
        } else {
            state.base = .default;
            return true;
        }
    }
    if (isExtendNoControl(gb2) or gb2 == .zwj) return false;
    return true;
}
fn isIndicConjunctBreakExtendNoControl(gb: types.GraphemeBreakNoControl) bool {
    return gb == .indic_conjunct_break_extend or gb == .zwj;
}
fn isIndicConjunctBreakLinkerNoControl(gb: types.GraphemeBreakNoControl) bool {
    return gb == .indic_conjunct_break_linker_extend or
        gb == .indic_conjunct_break_linker_other;
}
fn isExtendNoControl(gb: types.GraphemeBreakNoControl) bool {
    return gb == .zwnj or
        gb == .indic_conjunct_break_extend or
        gb == .indic_conjunct_break_linker_extend;
}
fn isExtendedPictographicNoControl(gb: types.GraphemeBreakNoControl) bool {
    return gb == .extended_pictographic or gb == .emoji_modifier_base;
}
fn testGraphemeBreakNoControl(getActualIsBreak: fn (cp1: u21, cp2: u21, state: *BreakState) bool) !void {
    const comps = @import("config.zig").components;
    const trim = comps.trim;
    const parseCp = comps.parseCp;
    const allocator = std.testing.allocator;
    const file_path = "ucd/auxiliary/GraphemeBreakTest.txt";
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, file_path, .{});
    defer file.close(std.testing.io);
    var buf: [2048]u8 = undefined;
    var file_reader = file.reader(std.testing.io, &buf);
    const content = try file_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(content);
    var lines = std.mem.splitScalar(u8, content, '\n');
    var success = true;
    var line_num: usize = 1;
    line_loop: while (lines.next()) |line| : (line_num += 1) {
        const trimmed = trim(line);
        if (trimmed.len == 0) continue;
        var parts = std.mem.splitScalar(u8, trimmed, ' ');
        const start = parts.next().?;
        try std.testing.expect(std.mem.eql(u8, start, "÷"));
        var state: BreakState = .{};
        var cp1 = try parseCp(parts.next().?);
        var expected_str = parts.next().?;
        var cp2 = try parseCp(parts.next().?);
        const original_gb1 = get(.grapheme_break, cp1);
        var original_gb2 = get(.grapheme_break, cp2);
        if (original_gb1 == .control or
            original_gb1 == .cr or
            original_gb1 == .lf or
            original_gb2 == .control or
            original_gb2 == .cr or
            original_gb2 == .lf) continue :line_loop;
        var gb1 = get(.grapheme_break_no_control, cp1);
        var gb2 = get(.grapheme_break_no_control, cp2);
        var next_expected_str = parts.next().?;
        while (true) {
            var expected_is_break = std.mem.eql(u8, expected_str, "÷");
            const actual_is_break = getActualIsBreak(cp1, cp2, &state);
            try std.testing.expect(expected_is_break or std.mem.eql(u8, expected_str, "×"));
            if (gb2 == .emoji_modifier and gb1 != .emoji_modifier_base) {
                inlineAssert(!expected_is_break);
                expected_is_break = true;
            }
            if (actual_is_break != expected_is_break) {
                std.log.err("line={d} cp1={x}, cp2={x}: gb1={}, gb2={}, state={}, expected={}, actual={}", .{
                    line_num,
                    cp1,
                    cp2,
                    gb1,
                    gb2,
                    state,
                    expected_is_break,
                    actual_is_break,
                });
                success = false;
            }
            if (parts.peek() == null) break;
            cp1 = cp2;
            gb1 = gb2;
            expected_str = next_expected_str;
            cp2 = try parseCp(parts.next().?);
            original_gb2 = get(.grapheme_break, cp2);
            if (original_gb2 == .control or
                original_gb2 == .cr or
                original_gb2 == .lf) continue :line_loop;
            gb2 = get(.grapheme_break_no_control, cp2);
            next_expected_str = parts.next().?;
        }
        try std.testing.expect(std.mem.eql(u8, next_expected_str, "÷"));
    }
    try std.testing.expect(success);
}
fn testGetActualComputedGraphemeBreakNoControl(cp1: u21, cp2: u21, state: *BreakState) bool {
    const gb1 = get(.grapheme_break_no_control, cp1);
    const gb2 = get(.grapheme_break_no_control, cp2);
    return computeGraphemeBreakNoControl(gb1, gb2, state);
}
test "GraphemeBreakTest.txt - computeGraphemeBreakNoControl" {
    try testGraphemeBreakNoControl(testGetActualComputedGraphemeBreakNoControl);
}
pub fn precomputedGraphemeBreakNoControl(
    gb1: types.GraphemeBreakNoControl,
    gb2: types.GraphemeBreakNoControl,
    state: *BreakState,
) bool {
    const table = comptime buildGraphemeBreakTable(
        types.GraphemeBreakNoControl,
        computeGraphemeBreakNoControl,
    );
    inlineAssert(@sizeOf(@TypeOf(table)) == 1620);
    const result = table.get(gb1, gb2, state.*);
    state.* = result.state;
    return result.result;
}
pub fn isBreakNoControl(
    cp1: u21,
    cp2: u21,
    state: *BreakState,
) bool {
    const gb1 = get(.grapheme_break_no_control, cp1);
    const gb2 = get(.grapheme_break_no_control, cp2);
    return precomputedGraphemeBreakNoControl(gb1, gb2, state);
}
test "GraphemeBreakTest.txt - isBreakNoControl" {
    try testGraphemeBreakNoControl(isBreakNoControl);
}
