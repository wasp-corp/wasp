const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const cimgui = @import("dcimgui");
pub const Mods = @import("key_mods.zig").Mods;
pub const KeyEvent = struct {
    action: Action = .press,
    key: Key = .unidentified,
    mods: Mods = .{},
    consumed_mods: Mods = .{},
    composing: bool = false,
    utf8: []const u8 = "",
    unshifted_codepoint: u21 = 0,
    pub fn effectiveMods(self: KeyEvent) Mods {
        if (self.utf8.len == 0) return self.mods;
        return self.mods.unset(self.consumed_mods);
    }
    pub fn bindingHash(self: KeyEvent) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, self.key);
        std.hash.autoHash(&hasher, self.unshifted_codepoint);
        std.hash.autoHash(&hasher, self.mods.binding());
        return hasher.final();
    }
};
pub const Action = enum(c_int) {
    release,
    press,
    repeat,
};
pub const Key = enum(c_int) {
    unidentified,
    backquote,
    backslash,
    bracket_left,
    bracket_right,
    comma,
    digit_0,
    digit_1,
    digit_2,
    digit_3,
    digit_4,
    digit_5,
    digit_6,
    digit_7,
    digit_8,
    digit_9,
    equal,
    intl_backslash,
    intl_ro,
    intl_yen,
    key_a,
    key_b,
    key_c,
    key_d,
    key_e,
    key_f,
    key_g,
    key_h,
    key_i,
    key_j,
    key_k,
    key_l,
    key_m,
    key_n,
    key_o,
    key_p,
    key_q,
    key_r,
    key_s,
    key_t,
    key_u,
    key_v,
    key_w,
    key_x,
    key_y,
    key_z,
    minus,
    period,
    quote,
    semicolon,
    slash,
    alt_left,
    alt_right,
    backspace,
    caps_lock,
    context_menu,
    control_left,
    control_right,
    enter,
    meta_left,
    meta_right,
    shift_left,
    shift_right,
    space,
    tab,
    convert,
    kana_mode,
    non_convert,
    delete,
    end,
    help,
    home,
    insert,
    page_down,
    page_up,
    arrow_down,
    arrow_left,
    arrow_right,
    arrow_up,
    num_lock,
    numpad_0,
    numpad_1,
    numpad_2,
    numpad_3,
    numpad_4,
    numpad_5,
    numpad_6,
    numpad_7,
    numpad_8,
    numpad_9,
    numpad_add,
    numpad_backspace,
    numpad_clear,
    numpad_clear_entry,
    numpad_comma,
    numpad_decimal,
    numpad_divide,
    numpad_enter,
    numpad_equal,
    numpad_memory_add,
    numpad_memory_clear,
    numpad_memory_recall,
    numpad_memory_store,
    numpad_memory_subtract,
    numpad_multiply,
    numpad_paren_left,
    numpad_paren_right,
    numpad_subtract,
    numpad_separator,
    numpad_up,
    numpad_down,
    numpad_right,
    numpad_left,
    numpad_begin,
    numpad_home,
    numpad_end,
    numpad_insert,
    numpad_delete,
    numpad_page_up,
    numpad_page_down,
    escape,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    f25,
    @"fn",
    fn_lock,
    print_screen,
    scroll_lock,
    pause,
    browser_back,
    browser_favorites,
    browser_forward,
    browser_home,
    browser_refresh,
    browser_search,
    browser_stop,
    eject,
    launch_app_1,
    launch_app_2,
    launch_mail,
    media_play_pause,
    media_select,
    media_stop,
    media_track_next,
    media_track_previous,
    power,
    sleep,
    audio_volume_down,
    audio_volume_mute,
    audio_volume_up,
    wake_up,
    copy,
    cut,
    paste,
    pub fn fromASCII(ch: u8) ?Key {
        return switch (ch) {
            inline else => |comptime_ch| {
                return comptime result: {
                    @setEvalBranchQuota(100_000);
                    for (codepoint_map) |entry| {
                        if (entry[1].keypad()) continue;
                        if (entry[0] == @as(u21, @intCast(comptime_ch))) {
                            break :result entry[1];
                        }
                    }
                    break :result null;
                };
            },
        };
    }
    pub fn fromW3C(code: []const u8) ?Key {
        var result: [128]u8 = undefined;
        if (code.len > result.len) return null;
        if (std.meta.stringToEnum(
            Key,
            std.ascii.lowerString(&result, code),
        )) |key| return key;
        var w: std.Io.Writer = .fixed(&result);
        for (code, 0..) |ch, i| switch (ch) {
            'a'...'z' => w.writeByte(ch) catch return null,
            'A'...'Z', '0'...'9' => {
                if (i > 0) w.writeByte('_') catch return null;
                w.writeByte(std.ascii.toLower(ch)) catch return null;
            },
            else => return null,
        };
        return std.meta.stringToEnum(Key, w.buffered());
    }
    pub fn w3c(self: Key) []const u8 {
        return switch (self) {
            inline else => |tag| comptime w3c: {
                @setEvalBranchQuota(50_000);
                const name = @tagName(tag);
                var buf: [128]u8 = undefined;
                var w: std.Io.Writer = .fixed(&buf);
                var i: usize = 0;
                while (i < name.len) {
                    if (i == 0) {
                        w.writeByte(std.ascii.toUpper(name[i])) catch unreachable;
                    } else if (name[i] == '_') {
                        i += 1;
                        w.writeByte(std.ascii.toUpper(name[i])) catch unreachable;
                    } else {
                        w.writeByte(name[i]) catch unreachable;
                    }
                    i += 1;
                }
                const written = buf;
                const result = written[0..w.end];
                break :w3c result;
            },
        };
    }
    pub fn printable(self: Key) bool {
        return switch (self) {
            inline else => |tag| {
                return comptime result: {
                    @setEvalBranchQuota(10_000);
                    for (codepoint_map) |entry| {
                        if (entry[1] == tag) break :result true;
                    }
                    break :result false;
                };
            },
        };
    }
    pub fn modifier(self: Key) bool {
        return switch (self) {
            .shift_left,
            .control_left,
            .alt_left,
            .meta_left,
            .shift_right,
            .control_right,
            .alt_right,
            .meta_right,
            => true,
            else => false,
        };
    }
    pub fn shouldBeRemappable(self: Key) bool {
        return switch (self) {
            .backquote,
            .backslash,
            .bracket_left,
            .bracket_right,
            .comma,
            .digit_0,
            .digit_1,
            .digit_2,
            .digit_3,
            .digit_4,
            .digit_5,
            .digit_6,
            .digit_7,
            .digit_8,
            .digit_9,
            .equal,
            .intl_backslash,
            .intl_ro,
            .intl_yen,
            .key_a,
            .key_b,
            .key_c,
            .key_d,
            .key_e,
            .key_f,
            .key_g,
            .key_h,
            .key_i,
            .key_j,
            .key_k,
            .key_l,
            .key_m,
            .key_n,
            .key_o,
            .key_p,
            .key_q,
            .key_r,
            .key_s,
            .key_t,
            .key_u,
            .key_v,
            .key_w,
            .key_x,
            .key_y,
            .key_z,
            .minus,
            .period,
            .quote,
            .semicolon,
            .slash,
            => false,
            else => true,
        };
    }
    pub fn keypad(self: Key) bool {
        return switch (self) {
            inline else => |tag| {
                const name = @tagName(tag);
                const result = comptime std.mem.startsWith(u8, name, "numpad_");
                return result;
            },
        };
    }
    pub fn codepoint(self: Key) ?u21 {
        return switch (self) {
            inline else => |tag| {
                return comptime result: {
                    @setEvalBranchQuota(10_000);
                    for (codepoint_map) |entry| {
                        if (entry[1] == tag) break :result entry[0];
                    }
                    break :result null;
                };
            },
        };
    }
    pub fn imguiKey(self: Key) ?c_int {
        return switch (self) {
            .key_a => cimgui.c.ImGuiKey_A,
            .key_b => cimgui.c.ImGuiKey_B,
            .key_c => cimgui.c.ImGuiKey_C,
            .key_d => cimgui.c.ImGuiKey_D,
            .key_e => cimgui.c.ImGuiKey_E,
            .key_f => cimgui.c.ImGuiKey_F,
            .key_g => cimgui.c.ImGuiKey_G,
            .key_h => cimgui.c.ImGuiKey_H,
            .key_i => cimgui.c.ImGuiKey_I,
            .key_j => cimgui.c.ImGuiKey_J,
            .key_k => cimgui.c.ImGuiKey_K,
            .key_l => cimgui.c.ImGuiKey_L,
            .key_m => cimgui.c.ImGuiKey_M,
            .key_n => cimgui.c.ImGuiKey_N,
            .key_o => cimgui.c.ImGuiKey_O,
            .key_p => cimgui.c.ImGuiKey_P,
            .key_q => cimgui.c.ImGuiKey_Q,
            .key_r => cimgui.c.ImGuiKey_R,
            .key_s => cimgui.c.ImGuiKey_S,
            .key_t => cimgui.c.ImGuiKey_T,
            .key_u => cimgui.c.ImGuiKey_U,
            .key_v => cimgui.c.ImGuiKey_V,
            .key_w => cimgui.c.ImGuiKey_W,
            .key_x => cimgui.c.ImGuiKey_X,
            .key_y => cimgui.c.ImGuiKey_Y,
            .key_z => cimgui.c.ImGuiKey_Z,
            .digit_0 => cimgui.c.ImGuiKey_0,
            .digit_1 => cimgui.c.ImGuiKey_1,
            .digit_2 => cimgui.c.ImGuiKey_2,
            .digit_3 => cimgui.c.ImGuiKey_3,
            .digit_4 => cimgui.c.ImGuiKey_4,
            .digit_5 => cimgui.c.ImGuiKey_5,
            .digit_6 => cimgui.c.ImGuiKey_6,
            .digit_7 => cimgui.c.ImGuiKey_7,
            .digit_8 => cimgui.c.ImGuiKey_8,
            .digit_9 => cimgui.c.ImGuiKey_9,
            .semicolon => cimgui.c.ImGuiKey_Semicolon,
            .space => cimgui.c.ImGuiKey_Space,
            .quote => cimgui.c.ImGuiKey_Apostrophe,
            .comma => cimgui.c.ImGuiKey_Comma,
            .backquote => cimgui.c.ImGuiKey_GraveAccent,
            .period => cimgui.c.ImGuiKey_Period,
            .slash => cimgui.c.ImGuiKey_Slash,
            .minus => cimgui.c.ImGuiKey_Minus,
            .equal => cimgui.c.ImGuiKey_Equal,
            .bracket_left => cimgui.c.ImGuiKey_LeftBracket,
            .bracket_right => cimgui.c.ImGuiKey_RightBracket,
            .backslash => cimgui.c.ImGuiKey_Backslash,
            .arrow_up => cimgui.c.ImGuiKey_UpArrow,
            .arrow_down => cimgui.c.ImGuiKey_DownArrow,
            .arrow_left => cimgui.c.ImGuiKey_LeftArrow,
            .arrow_right => cimgui.c.ImGuiKey_RightArrow,
            .home => cimgui.c.ImGuiKey_Home,
            .end => cimgui.c.ImGuiKey_End,
            .insert => cimgui.c.ImGuiKey_Insert,
            .delete => cimgui.c.ImGuiKey_Delete,
            .caps_lock => cimgui.c.ImGuiKey_CapsLock,
            .scroll_lock => cimgui.c.ImGuiKey_ScrollLock,
            .num_lock => cimgui.c.ImGuiKey_NumLock,
            .page_up => cimgui.c.ImGuiKey_PageUp,
            .page_down => cimgui.c.ImGuiKey_PageDown,
            .escape => cimgui.c.ImGuiKey_Escape,
            .enter => cimgui.c.ImGuiKey_Enter,
            .tab => cimgui.c.ImGuiKey_Tab,
            .backspace => cimgui.c.ImGuiKey_Backspace,
            .print_screen => cimgui.c.ImGuiKey_PrintScreen,
            .pause => cimgui.c.ImGuiKey_Pause,
            .context_menu => cimgui.c.ImGuiKey_Menu,
            .f1 => cimgui.c.ImGuiKey_F1,
            .f2 => cimgui.c.ImGuiKey_F2,
            .f3 => cimgui.c.ImGuiKey_F3,
            .f4 => cimgui.c.ImGuiKey_F4,
            .f5 => cimgui.c.ImGuiKey_F5,
            .f6 => cimgui.c.ImGuiKey_F6,
            .f7 => cimgui.c.ImGuiKey_F7,
            .f8 => cimgui.c.ImGuiKey_F8,
            .f9 => cimgui.c.ImGuiKey_F9,
            .f10 => cimgui.c.ImGuiKey_F10,
            .f11 => cimgui.c.ImGuiKey_F11,
            .f12 => cimgui.c.ImGuiKey_F12,
            .numpad_0 => cimgui.c.ImGuiKey_Keypad0,
            .numpad_1 => cimgui.c.ImGuiKey_Keypad1,
            .numpad_2 => cimgui.c.ImGuiKey_Keypad2,
            .numpad_3 => cimgui.c.ImGuiKey_Keypad3,
            .numpad_4 => cimgui.c.ImGuiKey_Keypad4,
            .numpad_5 => cimgui.c.ImGuiKey_Keypad5,
            .numpad_6 => cimgui.c.ImGuiKey_Keypad6,
            .numpad_7 => cimgui.c.ImGuiKey_Keypad7,
            .numpad_8 => cimgui.c.ImGuiKey_Keypad8,
            .numpad_9 => cimgui.c.ImGuiKey_Keypad9,
            .numpad_decimal => cimgui.c.ImGuiKey_KeypadDecimal,
            .numpad_divide => cimgui.c.ImGuiKey_KeypadDivide,
            .numpad_multiply => cimgui.c.ImGuiKey_KeypadMultiply,
            .numpad_subtract => cimgui.c.ImGuiKey_KeypadSubtract,
            .numpad_add => cimgui.c.ImGuiKey_KeypadAdd,
            .numpad_enter => cimgui.c.ImGuiKey_KeypadEnter,
            .numpad_equal => cimgui.c.ImGuiKey_KeypadEqual,
            .numpad_left => cimgui.c.ImGuiKey_LeftArrow,
            .numpad_right => cimgui.c.ImGuiKey_RightArrow,
            .numpad_up => cimgui.c.ImGuiKey_UpArrow,
            .numpad_down => cimgui.c.ImGuiKey_DownArrow,
            .numpad_page_up => cimgui.c.ImGuiKey_PageUp,
            .numpad_page_down => cimgui.c.ImGuiKey_PageUp,
            .numpad_home => cimgui.c.ImGuiKey_Home,
            .numpad_end => cimgui.c.ImGuiKey_End,
            .numpad_insert => cimgui.c.ImGuiKey_Insert,
            .numpad_delete => cimgui.c.ImGuiKey_Delete,
            .numpad_begin => cimgui.c.ImGuiKey_NamedKey_BEGIN,
            .shift_left => cimgui.c.ImGuiKey_LeftShift,
            .control_left => cimgui.c.ImGuiKey_LeftCtrl,
            .alt_left => cimgui.c.ImGuiKey_LeftAlt,
            .meta_left => cimgui.c.ImGuiKey_LeftSuper,
            .shift_right => cimgui.c.ImGuiKey_RightShift,
            .control_right => cimgui.c.ImGuiKey_RightCtrl,
            .alt_right => cimgui.c.ImGuiKey_RightAlt,
            .meta_right => cimgui.c.ImGuiKey_RightSuper,
            .f13,
            .f14,
            .f15,
            .f16,
            .f17,
            .f18,
            .f19,
            .f20,
            .f21,
            .f22,
            .f23,
            .f24,
            .f25,
            .intl_backslash,
            .intl_ro,
            .intl_yen,
            .convert,
            .kana_mode,
            .non_convert,
            .numpad_separator,
            .numpad_backspace,
            .numpad_clear,
            .numpad_clear_entry,
            .numpad_comma,
            .numpad_memory_add,
            .numpad_memory_clear,
            .numpad_memory_recall,
            .numpad_memory_store,
            .numpad_memory_subtract,
            .numpad_paren_left,
            .numpad_paren_right,
            .@"fn",
            .fn_lock,
            .browser_back,
            .browser_favorites,
            .browser_forward,
            .browser_home,
            .browser_refresh,
            .browser_search,
            .browser_stop,
            .eject,
            .launch_app_1,
            .launch_app_2,
            .launch_mail,
            .media_play_pause,
            .media_select,
            .media_stop,
            .media_track_next,
            .media_track_previous,
            .power,
            .sleep,
            .audio_volume_down,
            .audio_volume_mute,
            .audio_volume_up,
            .wake_up,
            .help,
            .copy,
            .cut,
            .paste,
            => null,
            .unidentified,
            => null,
        };
    }
    pub fn ctrlOrSuper(self: Key) bool {
        if (comptime builtin.target.os.tag.isDarwin()) {
            return self == .meta_left or self == .meta_right;
        }
        return self == .control_left or self == .control_right;
    }
    pub fn leftOrRightShift(self: Key) bool {
        return self == .shift_left or self == .shift_right;
    }
    pub fn leftOrRightAlt(self: Key) bool {
        return self == .alt_left or self == .alt_right;
    }
    test "fromASCII should not return keypad keys" {
        const testing = std.testing;
        try testing.expect(Key.fromASCII('0').? == .digit_0);
        try testing.expect(Key.fromASCII('*') == null);
    }
    test "keypad keys" {
        const testing = std.testing;
        try testing.expect(Key.numpad_0.keypad());
        try testing.expect(!Key.digit_1.keypad());
    }
    test "w3c" {
        const testing = std.testing;
        inline for (@typeInfo(Key).@"enum".fields) |field| {
            const key = @field(Key, field.name);
            const w3c_name = key.w3c();
            try testing.expectEqual(key, Key.fromW3C(w3c_name).?);
        }
    }
    const codepoint_map: []const struct { u21, Key } = &.{
        .{ 'a', .key_a },
        .{ 'b', .key_b },
        .{ 'c', .key_c },
        .{ 'd', .key_d },
        .{ 'e', .key_e },
        .{ 'f', .key_f },
        .{ 'g', .key_g },
        .{ 'h', .key_h },
        .{ 'i', .key_i },
        .{ 'j', .key_j },
        .{ 'k', .key_k },
        .{ 'l', .key_l },
        .{ 'm', .key_m },
        .{ 'n', .key_n },
        .{ 'o', .key_o },
        .{ 'p', .key_p },
        .{ 'q', .key_q },
        .{ 'r', .key_r },
        .{ 's', .key_s },
        .{ 't', .key_t },
        .{ 'u', .key_u },
        .{ 'v', .key_v },
        .{ 'w', .key_w },
        .{ 'x', .key_x },
        .{ 'y', .key_y },
        .{ 'z', .key_z },
        .{ '0', .digit_0 },
        .{ '1', .digit_1 },
        .{ '2', .digit_2 },
        .{ '3', .digit_3 },
        .{ '4', .digit_4 },
        .{ '5', .digit_5 },
        .{ '6', .digit_6 },
        .{ '7', .digit_7 },
        .{ '8', .digit_8 },
        .{ '9', .digit_9 },
        .{ ';', .semicolon },
        .{ ' ', .space },
        .{ '\'', .quote },
        .{ ',', .comma },
        .{ '`', .backquote },
        .{ '.', .period },
        .{ '/', .slash },
        .{ '-', .minus },
        .{ '=', .equal },
        .{ '[', .bracket_left },
        .{ ']', .bracket_right },
        .{ '\\', .backslash },
        .{ '\t', .tab },
        .{ '0', .numpad_0 },
        .{ '1', .numpad_1 },
        .{ '2', .numpad_2 },
        .{ '3', .numpad_3 },
        .{ '4', .numpad_4 },
        .{ '5', .numpad_5 },
        .{ '6', .numpad_6 },
        .{ '7', .numpad_7 },
        .{ '8', .numpad_8 },
        .{ '9', .numpad_9 },
        .{ '.', .numpad_decimal },
        .{ '/', .numpad_divide },
        .{ '*', .numpad_multiply },
        .{ '-', .numpad_subtract },
        .{ '+', .numpad_add },
        .{ '=', .numpad_equal },
    };
};
pub fn ctrlOrSuper(mods: Mods) Mods {
    var copy = mods;
    if (comptime builtin.target.os.tag.isDarwin()) {
        copy.super = true;
    } else {
        copy.ctrl = true;
    }
    return copy;
}
test "ctrlOrSuper" {
    const testing = std.testing;
    var m: Mods = ctrlOrSuper(.{});
    try testing.expect(m.ctrlOrSuper());
}
