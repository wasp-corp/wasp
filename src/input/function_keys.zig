const std = @import("std");
const key = @import("key.zig");
pub const CursorMode = enum { any, normal, application };
pub const KeypadMode = enum { any, normal, application };
pub const ModifyKeys = enum {
    any,
    set,
    set_other,
};
pub const Entry = struct {
    mods: key.Mods = .{},
    mods_empty_is_any: bool = true,
    cursor: CursorMode = .any,
    keypad: KeypadMode = .any,
    modify_other_keys: ModifyKeys = .any,
    sequence: []const u8,
    sequence_decbkm: ?[]const u8 = null,
};
pub const modifiers: []const key.Mods = &.{
    .{ .shift = true },
    .{ .alt = true },
    .{ .shift = true, .alt = true },
    .{ .ctrl = true },
    .{ .shift = true, .ctrl = true },
    .{ .alt = true, .ctrl = true },
    .{ .shift = true, .alt = true, .ctrl = true },
    .{ .super = true },
    .{ .shift = true, .super = true },
    .{ .alt = true, .super = true },
    .{ .shift = true, .alt = true, .super = true },
    .{ .ctrl = true, .super = true },
    .{ .shift = true, .ctrl = true, .super = true },
    .{ .alt = true, .ctrl = true, .super = true },
    .{ .shift = true, .alt = true, .ctrl = true, .super = true },
};
pub const KeyEntryArray = std.EnumArray(key.Key, []const Entry);
pub const keys = keys: {
    var result = KeyEntryArray.initFill(&.{});
    result.set(.arrow_up, pcStyle("\x1b[1;{}A") ++ cursorKey("\x1b[A", "\x1bOA"));
    result.set(.arrow_down, pcStyle("\x1b[1;{}B") ++ cursorKey("\x1b[B", "\x1bOB"));
    result.set(.arrow_right, pcStyle("\x1b[1;{}C") ++ cursorKey("\x1b[C", "\x1bOC"));
    result.set(.arrow_left, pcStyle("\x1b[1;{}D") ++ cursorKey("\x1b[D", "\x1bOD"));
    result.set(.home, pcStyle("\x1b[1;{}H") ++ cursorKey("\x1b[H", "\x1bOH"));
    result.set(.end, pcStyle("\x1b[1;{}F") ++ cursorKey("\x1b[F", "\x1bOF"));
    result.set(.insert, pcStyle("\x1b[2;{}~") ++ .{Entry{ .sequence = "\x1B[2~" }});
    result.set(.delete, pcStyle("\x1b[3;{}~") ++ .{Entry{ .sequence = "\x1B[3~" }});
    result.set(.page_up, pcStyle("\x1b[5;{}~") ++ .{Entry{ .sequence = "\x1B[5~" }});
    result.set(.page_down, pcStyle("\x1b[6;{}~") ++ .{Entry{ .sequence = "\x1B[6~" }});
    result.set(.help, pcStyle("\x1b[28;{}~") ++ .{Entry{ .sequence = "\x1B[28~" }});
    result.set(.context_menu, pcStyle("\x1b[29;{}~") ++ .{Entry{ .sequence = "\x1B[29~" }});
    result.set(.f1, pcStyle("\x1b[1;{}P") ++ .{Entry{ .sequence = "\x1BOP" }});
    result.set(.f2, pcStyle("\x1b[1;{}Q") ++ .{Entry{ .sequence = "\x1BOQ" }});
    result.set(.f3, pcStyle("\x1b[13;{}~") ++ .{Entry{ .sequence = "\x1BOR" }});
    result.set(.f4, pcStyle("\x1b[1;{}S") ++ .{Entry{ .sequence = "\x1BOS" }});
    result.set(.f5, pcStyle("\x1b[15;{}~") ++ .{Entry{ .sequence = "\x1B[15~" }});
    result.set(.f6, pcStyle("\x1b[17;{}~") ++ .{Entry{ .sequence = "\x1B[17~" }});
    result.set(.f7, pcStyle("\x1b[18;{}~") ++ .{Entry{ .sequence = "\x1B[18~" }});
    result.set(.f8, pcStyle("\x1b[19;{}~") ++ .{Entry{ .sequence = "\x1B[19~" }});
    result.set(.f9, pcStyle("\x1b[20;{}~") ++ .{Entry{ .sequence = "\x1B[20~" }});
    result.set(.f10, pcStyle("\x1b[21;{}~") ++ .{Entry{ .sequence = "\x1B[21~" }});
    result.set(.f11, pcStyle("\x1b[23;{}~") ++ .{Entry{ .sequence = "\x1B[23~" }});
    result.set(.f12, pcStyle("\x1b[24;{}~") ++ .{Entry{ .sequence = "\x1B[24~" }});
    result.set(.f13, pcStyle("\x1b[25;{}~") ++ .{Entry{ .sequence = "\x1B[25~" }});
    result.set(.f14, pcStyle("\x1b[26;{}~") ++ .{Entry{ .sequence = "\x1B[26~" }});
    result.set(.f15, pcStyle("\x1b[28;{}~") ++ .{Entry{ .sequence = "\x1B[28~" }});
    result.set(.f16, pcStyle("\x1b[29;{}~") ++ .{Entry{ .sequence = "\x1B[29~" }});
    result.set(.f17, pcStyle("\x1b[31;{}~") ++ .{Entry{ .sequence = "\x1B[31~" }});
    result.set(.f18, pcStyle("\x1b[32;{}~") ++ .{Entry{ .sequence = "\x1B[32~" }});
    result.set(.f19, pcStyle("\x1b[33;{}~") ++ .{Entry{ .sequence = "\x1B[33~" }});
    result.set(.f20, pcStyle("\x1b[34;{}~") ++ .{Entry{ .sequence = "\x1B[34~" }});
    result.set(.f21, pcStyle("\x1b[42;{}~") ++ .{Entry{ .sequence = "\x1B[42~" }});
    result.set(.f22, pcStyle("\x1b[43;{}~") ++ .{Entry{ .sequence = "\x1B[43~" }});
    result.set(.f23, pcStyle("\x1b[44;{}~") ++ .{Entry{ .sequence = "\x1B[44~" }});
    result.set(.f24, pcStyle("\x1b[45;{}~") ++ .{Entry{ .sequence = "\x1B[45~" }});
    result.set(.f25, pcStyle("\x1b[46;{}~") ++ .{Entry{ .sequence = "\x1B[46~" }});
    result.set(.numpad_0, kpKeys("p", "0"));
    result.set(.numpad_1, kpKeys("q", "1"));
    result.set(.numpad_2, kpKeys("r", "2"));
    result.set(.numpad_3, kpKeys("s", "3"));
    result.set(.numpad_4, kpKeys("t", "4"));
    result.set(.numpad_5, kpKeys("u", "5"));
    result.set(.numpad_6, kpKeys("v", "6"));
    result.set(.numpad_7, kpKeys("w", "7"));
    result.set(.numpad_8, kpKeys("x", "8"));
    result.set(.numpad_9, kpKeys("y", "9"));
    result.set(.numpad_decimal, kpKeys("n", "."));
    result.set(.numpad_divide, kpKeys("o", "/"));
    result.set(.numpad_multiply, kpKeys("j", "*"));
    result.set(.numpad_subtract, kpKeys("m", "-"));
    result.set(.numpad_add, kpKeys("k", "+"));
    result.set(.numpad_enter, kpKeys("M", "\r"));
    result.set(.numpad_up, pcStyle("\x1b[1;{}A") ++ cursorKey("\x1b[A", "\x1bOA"));
    result.set(.numpad_down, pcStyle("\x1b[1;{}B") ++ cursorKey("\x1b[B", "\x1bOB"));
    result.set(.numpad_right, pcStyle("\x1b[1;{}C") ++ cursorKey("\x1b[C", "\x1bOC"));
    result.set(.numpad_left, pcStyle("\x1b[1;{}D") ++ cursorKey("\x1b[D", "\x1bOD"));
    result.set(.numpad_begin, pcStyle("\x1b[1;{}E") ++ cursorKey("\x1b[E", "\x1bOE"));
    result.set(.numpad_home, pcStyle("\x1b[1;{}H") ++ cursorKey("\x1b[H", "\x1bOH"));
    result.set(.numpad_end, pcStyle("\x1b[1;{}F") ++ cursorKey("\x1b[F", "\x1bOF"));
    result.set(.numpad_insert, pcStyle("\x1b[2;{}~") ++ .{Entry{ .sequence = "\x1B[2~" }});
    result.set(.numpad_delete, pcStyle("\x1b[3;{}~") ++ .{Entry{ .sequence = "\x1B[3~" }});
    result.set(.numpad_page_up, pcStyle("\x1b[5;{}~") ++ .{Entry{ .sequence = "\x1B[5~" }});
    result.set(.numpad_page_down, pcStyle("\x1b[6;{}~") ++ .{Entry{ .sequence = "\x1B[6~" }});
    result.set(.backspace, &.{
        .{ .mods = .{ .shift = true }, .modify_other_keys = .set, .sequence = "\x7f" },
        .{ .mods = .{ .alt = true }, .modify_other_keys = .set, .sequence = "\x1b\x7f" },
        .{ .mods = .{ .alt = true, .shift = true }, .modify_other_keys = .set, .sequence = "\x1b\x7f" },
        .{ .mods = .{ .ctrl = true, .shift = true }, .modify_other_keys = .set, .sequence = "\x08" },
        .{ .mods = .{ .alt = true, .ctrl = true }, .modify_other_keys = .set, .sequence = "\x1b\x08" },
        .{ .mods = .{ .alt = true, .shift = true, .ctrl = true }, .modify_other_keys = .set, .sequence = "\x1b\x08" },
        .{ .mods = .{ .super = true }, .modify_other_keys = .set, .sequence = "\x7f" },
        .{ .mods = .{ .super = true, .shift = true }, .modify_other_keys = .set, .sequence = "\x7f" },
        .{ .mods = .{ .alt = true, .super = true }, .modify_other_keys = .set, .sequence = "\x1b\x7f" },
        .{ .mods = .{ .alt = true, .super = true, .shift = true }, .modify_other_keys = .set, .sequence = "\x1b\x7f" },
        .{ .mods = .{ .super = true, .ctrl = true }, .modify_other_keys = .set, .sequence = "\x08" },
        .{ .mods = .{ .super = true, .ctrl = true, .shift = true }, .modify_other_keys = .set, .sequence = "\x08" },
        .{ .mods = .{ .alt = true, .super = true, .ctrl = true }, .modify_other_keys = .set, .sequence = "\x1b\x08" },
        .{ .mods = .{ .alt = true, .super = true, .ctrl = true, .shift = true }, .modify_other_keys = .set, .sequence = "\x1b\x08" },
        .{ .mods = .{ .shift = true }, .modify_other_keys = .set_other, .sequence = "\x1b[27;2;127~" },
        .{ .mods = .{ .alt = true }, .modify_other_keys = .set_other, .sequence = "\x1b[27;3;127~" },
        .{ .mods = .{ .alt = true, .shift = true }, .modify_other_keys = .set_other, .sequence = "\x1b[27;4;127~" },
        .{ .mods = .{ .ctrl = true, .shift = true }, .modify_other_keys = .set_other, .sequence = "\x1b[27;6;127~" },
        .{ .mods = .{ .alt = true, .ctrl = true }, .modify_other_keys = .set_other, .sequence = "\x1b[27;7;127~" },
        .{ .mods = .{ .alt = true, .shift = true, .ctrl = true }, .modify_other_keys = .set_other, .sequence = "\x1b[27;8;127~" },
        .{ .mods = .{ .super = true }, .modify_other_keys = .set_other, .sequence = "\x1b[27;9;127~" },
        .{ .mods = .{ .super = true, .shift = true }, .modify_other_keys = .set_other, .sequence = "\x1b[27;10;127~" },
        .{ .mods = .{ .alt = true, .super = true }, .modify_other_keys = .set_other, .sequence = "\x1b[27;11;127~" },
        .{ .mods = .{ .alt = true, .super = true, .shift = true }, .modify_other_keys = .set_other, .sequence = "\x1b[27;12;127~" },
        .{ .mods = .{ .super = true, .ctrl = true }, .modify_other_keys = .set_other, .sequence = "\x1b[27;13;127~" },
        .{ .mods = .{ .super = true, .ctrl = true, .shift = true }, .modify_other_keys = .set_other, .sequence = "\x1b[27;14;127~" },
        .{ .mods = .{ .alt = true, .super = true, .ctrl = true }, .modify_other_keys = .set_other, .sequence = "\x1b[27;15;127~" },
        .{ .mods = .{ .alt = true, .super = true, .ctrl = true, .shift = true }, .modify_other_keys = .set_other, .sequence = "\x1b[27;16;127~" },
        .{ .mods = .{ .ctrl = true }, .sequence = "\x08", .sequence_decbkm = "\x7f" },
        .{ .sequence = "\x7f", .sequence_decbkm = "\x08" },
    });
    result.set(.tab, &.{
        .{ .mods = .{ .shift = true }, .modify_other_keys = .set, .sequence = "\x1b[Z" },
        .{ .mods = .{ .alt = true }, .modify_other_keys = .set, .sequence = "\x1b\t" },
        .{ .mods = .{ .shift = true }, .modify_other_keys = .set_other, .sequence = "\x1b[27;2;9~" },
        .{ .mods = .{ .alt = true }, .modify_other_keys = .set_other, .sequence = "\x1b[27;3;9~" },
        .{ .mods = .{ .alt = true, .shift = true }, .sequence = "\x1b[27;4;9~" },
        .{ .mods = .{ .ctrl = true }, .sequence = "\x1b[27;5;9~" },
        .{ .mods = .{ .ctrl = true, .shift = true }, .sequence = "\x1b[27;6;9~" },
        .{ .mods = .{ .alt = true, .ctrl = true }, .sequence = "\x1b[27;7;9~" },
        .{ .mods = .{ .alt = true, .ctrl = true, .shift = true }, .sequence = "\x1b[27;8;9~" },
        .{ .mods = .{ .super = true }, .sequence = "\x1b[27;9;9~" },
        .{ .mods = .{ .super = true, .shift = true }, .sequence = "\x1b[27;10;9~" },
        .{ .mods = .{ .alt = true, .super = true }, .sequence = "\x1b[27;11;9~" },
        .{ .mods = .{ .alt = true, .super = true, .shift = true }, .sequence = "\x1b[27;12;9~" },
        .{ .mods = .{ .super = true, .ctrl = true }, .sequence = "\x1b[27;13;9~" },
        .{ .mods = .{ .super = true, .ctrl = true, .shift = true }, .sequence = "\x1b[27;14;9~" },
        .{ .mods = .{ .alt = true, .super = true, .ctrl = true }, .sequence = "\x1b[27;15;9~" },
        .{ .mods = .{ .alt = true, .super = true, .ctrl = true, .shift = true }, .sequence = "\x1b[27;16;9~" },
        .{ .sequence = "\t" },
    });
    result.set(.enter, &.{
        .{ .mods = .{ .shift = true }, .sequence = "\x1b[27;2;13~" },
        .{ .mods = .{ .alt = true }, .modify_other_keys = .set, .sequence = "\x1b\r" },
        .{ .mods = .{ .alt = true }, .modify_other_keys = .set_other, .sequence = "\x1b[27;3;13~" },
        .{ .mods = .{ .alt = true, .shift = true }, .sequence = "\x1b[27;4;13~" },
        .{ .mods = .{ .ctrl = true }, .sequence = "\x1b[27;5;13~" },
        .{ .mods = .{ .ctrl = true, .shift = true }, .sequence = "\x1b[27;6;13~" },
        .{ .mods = .{ .alt = true, .ctrl = true }, .sequence = "\x1b[27;7;13~" },
        .{ .mods = .{ .alt = true, .ctrl = true, .shift = true }, .sequence = "\x1b[27;8;13~" },
        .{ .mods = .{ .super = true }, .sequence = "\x1b[27;9;13~" },
        .{ .mods = .{ .super = true, .shift = true }, .sequence = "\x1b[27;10;13~" },
        .{ .mods = .{ .alt = true, .super = true }, .sequence = "\x1b[27;11;13~" },
        .{ .mods = .{ .alt = true, .super = true, .shift = true }, .sequence = "\x1b[27;12;13~" },
        .{ .mods = .{ .super = true, .ctrl = true }, .sequence = "\x1b[27;13;13~" },
        .{ .mods = .{ .super = true, .ctrl = true, .shift = true }, .sequence = "\x1b[27;14;13~" },
        .{ .mods = .{ .alt = true, .super = true, .ctrl = true }, .sequence = "\x1b[27;15;13~" },
        .{ .mods = .{ .alt = true, .super = true, .ctrl = true, .shift = true }, .sequence = "\x1b[27;16;13~" },
        .{ .sequence = "\r" },
    });
    result.set(.escape, &.{
        .{ .mods = .{ .shift = true }, .sequence = "\x1b[27;2;27~" },
        .{ .mods = .{ .alt = true }, .modify_other_keys = .set, .sequence = "\x1b\x1b" },
        .{ .mods = .{ .alt = true }, .modify_other_keys = .set_other, .sequence = "\x1b[27;3;27~" },
        .{ .mods = .{ .alt = true, .shift = true }, .sequence = "\x1b[27;4;27~" },
        .{ .mods = .{ .ctrl = true }, .sequence = "\x1b[27;5;27~" },
        .{ .mods = .{ .ctrl = true, .shift = true }, .sequence = "\x1b[27;6;27~" },
        .{ .mods = .{ .alt = true, .ctrl = true }, .sequence = "\x1b[27;7;27~" },
        .{ .mods = .{ .alt = true, .ctrl = true, .shift = true }, .sequence = "\x1b[27;8;27~" },
        .{ .mods = .{ .super = true }, .sequence = "\x1b[27;9;27~" },
        .{ .mods = .{ .super = true, .shift = true }, .sequence = "\x1b[27;10;27~" },
        .{ .mods = .{ .alt = true, .super = true }, .sequence = "\x1b[27;11;27~" },
        .{ .mods = .{ .alt = true, .super = true, .shift = true }, .sequence = "\x1b[27;12;27~" },
        .{ .mods = .{ .super = true, .ctrl = true }, .sequence = "\x1b[27;13;27~" },
        .{ .mods = .{ .super = true, .ctrl = true, .shift = true }, .sequence = "\x1b[27;14;27~" },
        .{ .mods = .{ .alt = true, .super = true, .ctrl = true }, .sequence = "\x1b[27;15;27~" },
        .{ .mods = .{ .alt = true, .super = true, .ctrl = true, .shift = true }, .sequence = "\x1b[27;16;27~" },
        .{ .sequence = "\x1b" },
    });
    break :keys result;
};
fn kpDefault(comptime suffix: []const u8) []const Entry {
    return &.{
        .{
            .mods_empty_is_any = false,
            .keypad = .application,
            .sequence = "\x1bO" ++ suffix,
        },
    };
}
fn kpKeys(comptime suffix: []const u8, comptime normal: []const u8) []const Entry {
    const pc = pcStyle("\x1bO{}" ++ suffix);
    for (pc) |*entry| entry.keypad = .application;
    return kpDefault(suffix) ++ pc ++ .{
        Entry{ .keypad = .normal, .sequence = normal },
    };
}
fn cursorKey(
    comptime normal: []const u8,
    comptime application: []const u8,
) []const Entry {
    return &.{
        .{ .cursor = .normal, .sequence = normal },
        .{ .cursor = .application, .sequence = application },
    };
}
fn pcStyle(comptime fmt: []const u8) []Entry {
    comptime {
        @setEvalBranchQuota(500_000);
        var entries: [modifiers.len]Entry = undefined;
        for (modifiers, 2.., 0..) |mods, code, i| {
            entries[i] = .{
                .mods = mods,
                .sequence = std.fmt.comptimePrint(fmt, .{code}),
            };
        }
        return &entries;
    }
}
test "keys" {
    const testing = std.testing;
    switch (@import("terminal_options").artifact) {
        .wasp => {},
        .lib => return error.SkipZigTest,
    }
    _ = keys;
    const max = @import("../termio.zig").Message.WriteReq.Small.Max;
    for (keys.values) |entries| {
        for (entries) |entry| {
            try testing.expect(entry.sequence.len <= max);
        }
    }
}
