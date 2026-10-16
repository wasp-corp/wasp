const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("terminal_options");
const testing = std.testing;
const ComptimeIntSet = @import("../datastruct/root.zig").ComptimeIntSet;
pub const ModeState = struct {
    values: ModePacked = .{},
    saved: ModePacked = .{},
    default: ModePacked = .{},
    pub fn reset(self: *ModeState) void {
        self.values = self.default;
        self.saved = .{};
    }
    pub fn set(self: *ModeState, mode: Mode, value: bool) void {
        setPacked(&self.values, mode, value);
    }
    pub fn setDefault(self: *ModeState, mode: Mode, value: bool) void {
        setPacked(&self.values, mode, value);
        setPacked(&self.default, mode, value);
    }
    pub fn get(self: *const ModeState, mode: Mode) bool {
        return getPacked(&self.values, mode);
    }
    pub fn getDefault(self: *const ModeState, mode: Mode) bool {
        return getPacked(&self.default, mode);
    }
    pub fn save(self: *ModeState, mode: Mode) void {
        switch (mode) {
            inline else => |mode_comptime| {
                const entry = comptime entryForMode(mode_comptime);
                @field(self.saved, entry.name) = @field(self.values, entry.name);
            },
        }
    }
    pub fn restore(self: *ModeState, mode: Mode) bool {
        switch (mode) {
            inline else => |mode_comptime| {
                const entry = comptime entryForMode(mode_comptime);
                @field(self.values, entry.name) = @field(self.saved, entry.name);
                return @field(self.values, entry.name);
            },
        }
    }
    pub fn getReport(self: *const ModeState, tag: Report.Tag) Report {
        if (!tag.ansi and tag.value == 117) {
            return .{ .tag = tag, .state = .permanently_reset };
        }
        if (tag.ansi) {
            switch (tag.value) {
                inline 1, 5, 7, 10, 11, 13, 14, 15, 16, 17, 18, 19 => |v| {
                    comptime for (entries) |entry| {
                        if (entry.ansi and entry.value == v) @compileError(
                            std.fmt.comptimePrint(
                                "ANSI mode {} is in the mode table and " ++
                                    "must not be reported as permanently reset",
                                .{v},
                            ),
                        );
                    };
                    return .{ .tag = tag, .state = .permanently_reset };
                },
                else => {},
            }
        }
        const mode = modeFromInt(tag.value, tag.ansi) orelse return .{
            .tag = tag,
            .state = .not_recognized,
        };
        return .{
            .tag = tag,
            .state = if (self.get(mode)) .set else .reset,
        };
    }
    test {
        try std.testing.expectEqual(8, @sizeOf(ModePacked));
    }
};
fn setPacked(values: *ModePacked, mode: Mode, value: bool) void {
    switch (mode) {
        inline else => |mode_comptime| {
            const entry = comptime entryForMode(mode_comptime);
            @field(values, entry.name) = value;
        },
    }
}
fn getPacked(values: *const ModePacked, mode: Mode) bool {
    switch (mode) {
        inline else => |mode_comptime| {
            const entry = comptime entryForMode(mode_comptime);
            return @field(values, entry.name);
        },
    }
}
pub const ModePacked = packed_struct: {
    const StructField = std.builtin.Type.StructField;
    var names: [entries.len][]const u8 = undefined;
    var types = [_]type{bool} ** entries.len;
    var attrs: [entries.len]StructField.Attributes = undefined;
    for (entries, &names, &attrs) |entry, *name, *attr| {
        name.* = entry.name;
        attr.* = .{ .default_value_ptr = &entry.default };
    }
    break :packed_struct @Struct(.@"packed", null, &names, &types, &attrs);
};
pub const Mode = mode_enum: {
    var names: [entries.len][]const u8 = undefined;
    var values: [entries.len]ModeTag.Backing = undefined;
    for (entries, &names, &values) |entry, *name, *value| {
        name.* = entry.name;
        value.* = @bitCast(ModeTag{
            .value = entry.value,
            .ansi = entry.ansi,
        });
    }
    break :mode_enum @Enum(ModeTag.Backing, .exhaustive, &names, &values);
};
pub const ModeTag = packed struct(u16) {
    pub const Backing = @typeInfo(@This()).@"struct".backing_integer.?;
    value: u15,
    ansi: bool = false,
    pub fn fromMode(mode: Mode) ModeTag {
        return @bitCast(@intFromEnum(mode));
    }
    test "order" {
        const t: ModeTag = .{ .value = 1 };
        const int: Backing = @bitCast(t);
        try std.testing.expectEqual(@as(Backing, 1), int);
    }
};
pub fn modeFromInt(v: u16, ansi: bool) ?Mode {
    if (v > std.math.maxInt(u15)) return null;
    const tag: ModeTag = .{ .ansi = ansi, .value = @intCast(v) };
    const int: ModeTag.Backing = @bitCast(tag);
    const idx = EntrySet.indexOf(int) orelse return null;
    if (comptime entries_any_disabled) {
        if (entries_disabled[idx]) return null;
    }
    return @enumFromInt(int);
}
const EntrySet = ComptimeIntSet(ModeTag.Backing, keys: {
    var keys: [entries.len]ModeTag.Backing = undefined;
    for (entries, &keys) |entry, *key| key.* = @bitCast(ModeTag{
        .value = entry.value,
        .ansi = entry.ansi,
    });
    const final = keys;
    break :keys &final;
});
const entries_disabled: [entries.len]bool = disabled: {
    var result: [entries.len]bool = undefined;
    for (entries, &result) |entry, *v| v.* = entry.disabled;
    break :disabled result;
};
const entries_any_disabled: bool = any: {
    for (entries) |entry| if (entry.disabled) break :any true;
    break :any false;
};
pub const Report = struct {
    tag: Tag,
    state: State,
    pub const Tag = struct {
        value: u16,
        ansi: bool = false,
        pub fn fromMode(mode: Mode) Tag {
            const tag = ModeTag.fromMode(mode);
            return .{ .value = tag.value, .ansi = tag.ansi };
        }
    };
    pub const max_size = max_size: {
        const report: Report = .{
            .tag = .{
                .value = std.math.maxInt(u16),
                .ansi = false,
            },
            .state = .permanently_reset,
        };
        var discarding: std.Io.Writer.Discarding = .init(&.{});
        report.encode(&discarding.writer) catch unreachable;
        break :max_size discarding.count;
    };
    pub const State = enum(u8) {
        not_recognized = 0,
        set = 1,
        reset = 2,
        permanently_set = 3,
        permanently_reset = 4,
    };
    pub fn encode(
        self: Report,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("\x1B[{s}{};{}$y", .{
            if (self.tag.ansi) "" else "?",
            self.tag.value,
            @intFromEnum(self.state),
        });
    }
};
fn entryForMode(comptime mode: Mode) ModeEntry {
    @setEvalBranchQuota(10_000);
    const name = @tagName(mode);
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    unreachable;
}
const ModeEntry = struct {
    name: [:0]const u8,
    value: comptime_int,
    default: bool = false,
    ansi: bool = false,
    disabled: bool = false,
    default_configurable: bool = true,
};
pub fn defaultConfigurable(mode: Mode) bool {
    switch (mode) {
        inline else => |mode_comptime| {
            return comptime entryForMode(mode_comptime).default_configurable;
        },
    }
}
const entries: []const ModeEntry = &.{
    .{ .name = "disable_keyboard", .value = 2, .ansi = true },
    .{ .name = "insert", .value = 4, .ansi = true },
    .{ .name = "send_receive_mode", .value = 12, .ansi = true, .default = true },
    .{ .name = "linefeed", .value = 20, .ansi = true },
    .{ .name = "cursor_keys", .value = 1 },
    .{ .name = "132_column", .value = 3, .default_configurable = false },
    .{ .name = "slow_scroll", .value = 4 },
    .{ .name = "reverse_colors", .value = 5 },
    .{ .name = "origin", .value = 6, .default_configurable = false },
    .{ .name = "wraparound", .value = 7, .default = true },
    .{ .name = "autorepeat", .value = 8 },
    .{ .name = "mouse_event_x10", .value = 9, .default_configurable = false },
    .{ .name = "cursor_blinking", .value = 12, .default_configurable = false },
    .{ .name = "cursor_visible", .value = 25, .default = true },
    .{ .name = "enable_mode_3", .value = 40 },
    .{ .name = "reverse_wrap", .value = 45 },
    .{ .name = "alt_screen_legacy", .value = 47, .default_configurable = false },
    .{ .name = "keypad_keys", .value = 66 },
    .{ .name = "backarrow_key_mode", .value = 67 },
    .{ .name = "enable_left_and_right_margin", .value = 69, .default_configurable = false },
    .{ .name = "mouse_event_normal", .value = 1000, .default_configurable = false },
    .{ .name = "mouse_event_button", .value = 1002, .default_configurable = false },
    .{ .name = "mouse_event_any", .value = 1003, .default_configurable = false },
    .{ .name = "focus_event", .value = 1004 },
    .{ .name = "mouse_format_utf8", .value = 1005, .default_configurable = false },
    .{ .name = "mouse_format_sgr", .value = 1006, .default_configurable = false },
    .{ .name = "mouse_alternate_scroll", .value = 1007, .default = true },
    .{ .name = "mouse_format_urxvt", .value = 1015, .default_configurable = false },
    .{ .name = "mouse_format_sgr_pixels", .value = 1016, .default_configurable = false },
    .{ .name = "ignore_keypad_with_numlock", .value = 1035, .default = true },
    .{ .name = "alt_esc_prefix", .value = 1036, .default = true },
    .{ .name = "alt_sends_escape", .value = 1039 },
    .{ .name = "reverse_wrap_extended", .value = 1045 },
    .{ .name = "alt_screen", .value = 1047, .default_configurable = false },
    .{ .name = "save_cursor", .value = 1048, .default_configurable = false },
    .{ .name = "alt_screen_save_cursor_clear_enter", .value = 1049, .default_configurable = false },
    .{ .name = "bracketed_paste", .value = 2004 },
    .{ .name = "synchronized_output", .value = 2026, .default_configurable = false },
    .{ .name = "grapheme_cluster", .value = 2027 },
    .{ .name = "report_color_scheme", .value = 2031 },
    .{ .name = "report_visibility", .value = 2033, .default_configurable = false },
    .{ .name = "in_band_size_reports", .value = 2048 },
    .{
        .name = "kitty_paste_events",
        .value = 5522,
        .disabled = build_options.artifact != .lib and builtin.os.tag != .macos,
    },
};
test {
    _ = Mode;
    _ = ModePacked;
}
test modeFromInt {
    try testing.expect(modeFromInt(4, true).? == .insert);
    try testing.expect(modeFromInt(9, true) == null);
    try testing.expect(modeFromInt(9, false).? == .mouse_event_x10);
    try testing.expect(modeFromInt(14, true) == null);
    try testing.expect(modeFromInt(4 | 0x8000, false) == null);
    try testing.expect(modeFromInt(std.math.maxInt(u16), true) == null);
}
test "modeFromInt matches entries exhaustively" {
    for ([_]bool{ false, true }) |ansi| {
        for (0..std.math.maxInt(u16) + 1) |v| {
            const expected: ?Mode = expected: {
                inline for (entries) |entry| {
                    if (comptime !entry.disabled) {
                        if (entry.value == v and entry.ansi == ansi) {
                            break :expected @field(Mode, entry.name);
                        }
                    }
                }
                break :expected null;
            };
            try testing.expectEqual(expected, modeFromInt(@intCast(v), ansi));
        }
    }
}
test ModeState {
    var state: ModeState = .{};
    try testing.expect(!state.get(.cursor_keys));
    state.set(.cursor_keys, true);
    try testing.expect(state.get(.cursor_keys));
    state.save(.cursor_keys);
    state.set(.cursor_keys, false);
    try testing.expect(!state.get(.cursor_keys));
    try testing.expect(state.restore(.cursor_keys));
    try testing.expect(state.get(.cursor_keys));
}
test "ModeState set default updates current and reset value" {
    var state: ModeState = .{};
    state.setDefault(.grapheme_cluster, true);
    try testing.expect(state.get(.grapheme_cluster));
    try testing.expect(state.default.grapheme_cluster);
    state.set(.grapheme_cluster, false);
    try testing.expect(!state.get(.grapheme_cluster));
    try testing.expect(state.default.grapheme_cluster);
    state.setDefault(.grapheme_cluster, true);
    try testing.expect(state.get(.grapheme_cluster));
    state.set(.grapheme_cluster, false);
    state.reset();
    try testing.expect(state.get(.grapheme_cluster));
}
test "default configurable modes" {
    try testing.expect(defaultConfigurable(.grapheme_cluster));
    try testing.expect(defaultConfigurable(.wraparound));
    try testing.expect(!defaultConfigurable(.alt_screen));
    try testing.expect(!defaultConfigurable(.cursor_blinking));
}
test "getReport known DEC mode" {
    var state: ModeState = .{};
    const report = state.getReport(.{ .value = 1 });
    try testing.expectEqual(Report.State.reset, report.state);
    try testing.expectEqual(false, report.tag.ansi);
    try testing.expectEqual(@as(u15, 1), report.tag.value);
    state.set(.cursor_keys, true);
    const report2 = state.getReport(.{ .value = 1 });
    try testing.expectEqual(Report.State.set, report2.state);
}
test "getReport known ANSI mode" {
    var state: ModeState = .{};
    state.set(.insert, true);
    const report = state.getReport(.{ .value = 4, .ansi = true });
    try testing.expectEqual(Report.State.set, report.state);
    try testing.expectEqual(true, report.tag.ansi);
}
test "getReport DECECM permanently reset" {
    const state: ModeState = .{};
    const report = state.getReport(.{ .value = 117, .ansi = false });
    try testing.expectEqual(Report.State.permanently_reset, report.state);
    try testing.expectEqual(false, report.tag.ansi);
}
test "getReport unsupported ANSI modes permanently reset" {
    const state: ModeState = .{};
    for ([_]u16{ 1, 5, 7, 10, 11, 13, 14, 15, 16, 17, 18, 19 }) |value| {
        try testing.expect(modeFromInt(value, true) == null);
        const report = state.getReport(.{ .value = value, .ansi = true });
        try testing.expectEqual(Report.State.permanently_reset, report.state);
        try testing.expectEqual(true, report.tag.ansi);
        try testing.expectEqual(value, report.tag.value);
    }
    const unknown = state.getReport(.{ .value = 9, .ansi = true });
    try testing.expectEqual(Report.State.not_recognized, unknown.state);
}
test "getReport unknown mode" {
    const state: ModeState = .{};
    const report = state.getReport(.{ .value = 9999 });
    try testing.expectEqual(Report.State.not_recognized, report.state);
}
test "Report.encode DEC mode set" {
    var buf: [Report.max_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const report: Report = .{ .tag = .{ .value = 1, .ansi = false }, .state = .set };
    try report.encode(&writer);
    try testing.expectEqualStrings("\x1B[?1;1$y", writer.buffered());
}
test "Report.encode DEC mode reset" {
    var buf: [Report.max_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const report: Report = .{ .tag = .{ .value = 1, .ansi = false }, .state = .reset };
    try report.encode(&writer);
    try testing.expectEqualStrings("\x1B[?1;2$y", writer.buffered());
}
test "Report.encode ANSI mode" {
    var buf: [Report.max_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const report: Report = .{ .tag = .{ .value = 4, .ansi = true }, .state = .set };
    try report.encode(&writer);
    try testing.expectEqualStrings("\x1B[4;1$y", writer.buffered());
}
test "Report.encode not recognized" {
    var buf: [Report.max_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const report: Report = .{ .tag = .{ .value = 9999, .ansi = false }, .state = .not_recognized };
    try report.encode(&writer);
    try testing.expectEqualStrings("\x1B[?9999;0$y", writer.buffered());
}
test "getReport large unknown modes" {
    const state: ModeState = .{};
    for ([_]Report.Tag{
        .{ .value = 32772, .ansi = true },
        .{ .value = 32885 },
    }) |tag| {
        const report = state.getReport(tag);
        try testing.expectEqual(Report.State.not_recognized, report.state);
        try testing.expectEqualDeep(tag, report.tag);
    }
}
test "Report.encode maximum size" {
    var buf: [Report.max_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const report: Report = .{ .tag = .{ .value = 65535 }, .state = .permanently_reset };
    try report.encode(&writer);
    try testing.expectEqualStrings("\x1b[?65535;4$y", writer.buffered());
    try testing.expectEqual(buf.len, writer.buffered().len);
}
