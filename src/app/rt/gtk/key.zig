const std = @import("std");
const gdk = @import("gdk");
const glib = @import("glib");
const gtk = @import("gtk");
const input = @import("../../input.zig");
const winproto = @import("winproto.zig");
pub fn accelFromTrigger(
    buf: []u8,
    trigger: input.Binding.Trigger,
) error{WriteFailed}!?[:0]const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    if (trigger.mods.shift) try writer.writeAll("<Shift>");
    if (trigger.mods.ctrl) try writer.writeAll("<Ctrl>");
    if (trigger.mods.alt) try writer.writeAll("<Alt>");
    if (trigger.mods.super) try writer.writeAll("<Super>");
    if (!try writeTriggerKey(&writer, trigger)) return null;
    try writer.writeByte(0);
    const slice = writer.buffered();
    return slice[0 .. slice.len - 1 :0];
}
pub fn xdgShortcutFromTrigger(
    buf: []u8,
    trigger: input.Binding.Trigger,
) error{WriteFailed}!?[:0]const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    if (trigger.mods.shift) try writer.writeAll("SHIFT+");
    if (trigger.mods.ctrl) try writer.writeAll("CTRL+");
    if (trigger.mods.alt) try writer.writeAll("ALT+");
    if (trigger.mods.super) try writer.writeAll("LOGO+");
    if (!try writeTriggerKey(&writer, trigger)) return null;
    try writer.writeByte(0);
    const slice = writer.buffered();
    return slice[0 .. slice.len - 1 :0];
}
pub fn keysymFromTrigger(trigger: input.Binding.Trigger) ?c_uint {
    return switch (trigger.key) {
        .physical => |k| keyvalFromKey(k),
        .unicode => |cp| gdk.unicodeToKeyval(cp),
        .catch_all => null,
    };
}
fn writeTriggerKey(
    writer: *std.Io.Writer,
    trigger: input.Binding.Trigger,
) error{WriteFailed}!bool {
    switch (trigger.key) {
        .physical => |k| {
            const keyval = keyvalFromKey(k) orelse return false;
            try writer.writeAll(std.mem.span(gdk.keyvalName(keyval) orelse return false));
        },
        .unicode => |cp| {
            if (gdk.keyvalName(cp)) |name| {
                try writer.writeAll(std.mem.span(name));
            } else {
                try writer.print("{u}", .{cp});
            }
        },
        .catch_all => return false,
    }
    return true;
}
pub fn translateMods(state: gdk.ModifierType) input.Mods {
    return .{
        .shift = state.shift_mask,
        .ctrl = state.control_mask,
        .alt = state.alt_mask,
        .super = state.super_mask,
        .caps_lock = state.lock_mask,
    };
}
pub fn keyvalUnicodeUnshifted(
    widget: *gtk.Widget,
    event: *gdk.KeyEvent,
    keycode: u32,
) u21 {
    const display = widget.getDisplay();
    const layout = event.getLayout();
    var keys: [*]gdk.KeymapKey = undefined;
    var keyvals: [*]c_uint = undefined;
    var n_entries: c_int = 0;
    if (display.mapKeycode(keycode, &keys, &keyvals, &n_entries) == 0) return 0;
    defer glib.free(keys);
    defer glib.free(keyvals);
    for (0..@intCast(n_entries)) |i| {
        if (keys[i].f_group == layout and
            keys[i].f_level == 0)
        {
            return std.math.cast(
                u21,
                gdk.keyvalToUnicode(keyvals[i]),
            ) orelse 0;
        }
    }
    return 0;
}
pub fn eventMods(
    event: *gdk.Event,
    physical_key: input.Key,
    gtk_mods: gdk.ModifierType,
    action: input.Action,
    app_winproto: *winproto.App,
) input.Mods {
    const device = event.getDevice();
    var mods = app_winproto.eventMods(device, gtk_mods);
    mods.num_lock = if (device) |d| d.getNumLockState() != 0 else false;
    switch (physical_key) {
        .shift_left => {
            mods.shift = action != .release;
            mods.sides.shift = .left;
        },
        .shift_right => {
            mods.shift = action != .release;
            mods.sides.shift = .right;
        },
        .control_left => {
            mods.ctrl = action != .release;
            mods.sides.ctrl = .left;
        },
        .control_right => {
            mods.ctrl = action != .release;
            mods.sides.ctrl = .right;
        },
        .alt_left => {
            mods.alt = action != .release;
            mods.sides.alt = .left;
        },
        .alt_right => {
            mods.alt = action != .release;
            mods.sides.alt = .right;
        },
        .meta_left => {
            mods.super = action != .release;
            mods.sides.super = .left;
        },
        .meta_right => {
            mods.super = action != .release;
            mods.sides.super = .right;
        },
        else => {},
    }
    return mods;
}
pub fn keyFromKeyval(keyval: c_uint) ?input.Key {
    for (keymap) |entry| {
        if (entry[0] == keyval) return entry[1];
    }
    return null;
}
pub fn remapKey(
    physical_key: input.Key,
    keyval: c_uint,
    is_modifier: bool,
) input.Key {
    if (keyFromKeyval(keyval)) |remapped| {
        if (physical_key.shouldBeRemappable() or remapped.shouldBeRemappable())
            return remapped;
    }
    if (is_modifier or isModifierKeyval(keyval)) return .unidentified;
    return physical_key;
}
fn isModifierKeyval(keyval: c_uint) bool {
    return switch (keyval) {
        gdk.KEY_Shift_L,
        gdk.KEY_Shift_R,
        gdk.KEY_Shift_Lock,
        gdk.KEY_Control_L,
        gdk.KEY_Control_R,
        gdk.KEY_Caps_Lock,
        gdk.KEY_Meta_L,
        gdk.KEY_Meta_R,
        gdk.KEY_Alt_L,
        gdk.KEY_Alt_R,
        gdk.KEY_Super_L,
        gdk.KEY_Super_R,
        gdk.KEY_Hyper_L,
        gdk.KEY_Hyper_R,
        gdk.KEY_Num_Lock,
        gdk.KEY_Mode_switch,
        gdk.KEY_ISO_Lock,
        gdk.KEY_ISO_Level2_Latch,
        gdk.KEY_ISO_Level3_Shift,
        gdk.KEY_ISO_Level3_Latch,
        gdk.KEY_ISO_Level3_Lock,
        gdk.KEY_ISO_Level5_Shift,
        gdk.KEY_ISO_Level5_Latch,
        gdk.KEY_ISO_Level5_Lock,
        gdk.KEY_ISO_Group_Latch,
        gdk.KEY_ISO_Group_Lock,
        => true,
        else => false,
    };
}
test "remap key" {
    const testing = std.testing;
    try testing.expectEqual(
        input.Key.escape,
        remapKey(.caps_lock, gdk.KEY_Escape, false),
    );
    try testing.expectEqual(
        input.Key.key_a,
        remapKey(.key_a, gdk.KEY_b, false),
    );
    try testing.expectEqual(
        input.Key.unidentified,
        remapKey(.delete, gdk.KEY_Mode_switch, false),
    );
    try testing.expectEqual(
        input.Key.unidentified,
        remapKey(.delete, gdk.KEY_VoidSymbol, true),
    );
}
pub fn keyvalFromKey(key: input.Key) ?c_uint {
    switch (key) {
        inline else => |key_comptime| {
            return comptime value: {
                @setEvalBranchQuota(50_000);
                for (keymap) |entry| {
                    if (entry[1] == key_comptime) break :value entry[0];
                }
                break :value null;
            };
        },
    }
}
pub fn labelFromTrigger(
    writer: *std.Io.Writer,
    trigger: input.Binding.Trigger,
) std.Io.Writer.Error!bool {
    if (trigger.mods.super) try writer.writeAll("Super+");
    if (trigger.mods.ctrl) try writer.writeAll("Ctrl+");
    if (trigger.mods.alt) try writer.writeAll("Alt+");
    if (trigger.mods.shift) try writer.writeAll("Shift+");
    return writeTriggerKeyLabel(writer, trigger);
}
fn writeTriggerKeyLabel(
    writer: *std.Io.Writer,
    trigger: input.Binding.Trigger,
) error{WriteFailed}!bool {
    switch (trigger.key) {
        .physical => |k| {
            const keyval = keyvalFromKey(k) orelse return false;
            const name = gdk.keyvalName(keyval) orelse return false;
            const span = std.mem.span(name);
            if (span.len > 0) {
                if (span[0] >= 'a' and span[0] <= 'z') {
                    try writer.writeByte(span[0] - 'a' + 'A');
                    if (span.len > 1) try writer.writeAll(span[1..]);
                } else {
                    try writer.writeAll(span);
                }
            }
        },
        .unicode => |cp| {
            if (gdk.keyvalName(cp)) |name| {
                const span = std.mem.span(name);
                if (span.len > 0) {
                    if (span[0] >= 'a' and span[0] <= 'z') {
                        try writer.writeByte(span[0] - 'a' + 'A');
                        if (span.len > 1) try writer.writeAll(span[1..]);
                    } else {
                        try writer.writeAll(span);
                    }
                }
            } else {
                try writer.print("{u}", .{cp});
            }
        },
        .catch_all => return false,
    }
    return true;
}
test "accelFromTrigger" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("<Super>q", (try accelFromTrigger(&buf, .{
        .mods = .{ .super = true },
        .key = .{ .unicode = 'q' },
    })).?);
    try testing.expectEqualStrings("<Shift><Ctrl><Alt><Super>backslash", (try accelFromTrigger(&buf, .{
        .mods = .{ .ctrl = true, .alt = true, .super = true, .shift = true },
        .key = .{ .unicode = 92 },
    })).?);
}
test "xdgShortcutFromTrigger" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("LOGO+q", (try xdgShortcutFromTrigger(&buf, .{
        .mods = .{ .super = true },
        .key = .{ .unicode = 'q' },
    })).?);
    try testing.expectEqualStrings("SHIFT+CTRL+ALT+LOGO+backslash", (try xdgShortcutFromTrigger(&buf, .{
        .mods = .{ .ctrl = true, .alt = true, .super = true, .shift = true },
        .key = .{ .unicode = 92 },
    })).?);
}
test "keysymFromTrigger" {
    const testing = std.testing;
    try testing.expectEqual(@as(?c_uint, 'q'), keysymFromTrigger(.{
        .mods = .{ .super = true },
        .key = .{ .unicode = 'q' },
    }));
    try testing.expectEqual(@as(?c_uint, gdk.KEY_a), keysymFromTrigger(.{
        .mods = .{},
        .key = .{ .physical = .key_a },
    }));
    try testing.expectEqual(@as(?c_uint, null), keysymFromTrigger(.{
        .mods = .{},
        .key = .catch_all,
    }));
}
test "labelFromTrigger" {
    const testing = std.testing;
    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try testing.expect(try labelFromTrigger(&buf.writer, .{
            .mods = .{ .super = true },
            .key = .{ .unicode = 'q' },
        }));
        try testing.expectEqualStrings("Super+Q", buf.written());
    }
    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try testing.expect(try labelFromTrigger(&buf.writer, .{
            .mods = .{ .ctrl = true, .alt = true, .super = true, .shift = true },
            .key = .{ .unicode = 92 },
        }));
        try testing.expectEqualStrings("Super+Ctrl+Alt+Shift+Backslash", buf.written());
    }
    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try testing.expect(try labelFromTrigger(&buf.writer, .{
            .mods = .{ .ctrl = true },
            .key = .{ .physical = .key_a },
        }));
        try testing.expectEqualStrings("Ctrl+A", buf.written());
    }
    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try testing.expect(try labelFromTrigger(&buf.writer, .{
            .mods = .{},
            .key = .{ .physical = .escape },
        }));
        try testing.expectEqualStrings("Escape", buf.written());
    }
    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try testing.expect(!try labelFromTrigger(&buf.writer, .{
            .mods = .{},
            .key = .catch_all,
        }));
    }
}
const RawEntry = struct { c_uint, input.Key };
const keymap: []const RawEntry = &.{
    .{ gdk.KEY_a, .key_a },
    .{ gdk.KEY_b, .key_b },
    .{ gdk.KEY_c, .key_c },
    .{ gdk.KEY_d, .key_d },
    .{ gdk.KEY_e, .key_e },
    .{ gdk.KEY_f, .key_f },
    .{ gdk.KEY_g, .key_g },
    .{ gdk.KEY_h, .key_h },
    .{ gdk.KEY_i, .key_i },
    .{ gdk.KEY_j, .key_j },
    .{ gdk.KEY_k, .key_k },
    .{ gdk.KEY_l, .key_l },
    .{ gdk.KEY_m, .key_m },
    .{ gdk.KEY_n, .key_n },
    .{ gdk.KEY_o, .key_o },
    .{ gdk.KEY_p, .key_p },
    .{ gdk.KEY_q, .key_q },
    .{ gdk.KEY_r, .key_r },
    .{ gdk.KEY_s, .key_s },
    .{ gdk.KEY_t, .key_t },
    .{ gdk.KEY_u, .key_u },
    .{ gdk.KEY_v, .key_v },
    .{ gdk.KEY_w, .key_w },
    .{ gdk.KEY_x, .key_x },
    .{ gdk.KEY_y, .key_y },
    .{ gdk.KEY_z, .key_z },
    .{ gdk.KEY_0, .digit_0 },
    .{ gdk.KEY_1, .digit_1 },
    .{ gdk.KEY_2, .digit_2 },
    .{ gdk.KEY_3, .digit_3 },
    .{ gdk.KEY_4, .digit_4 },
    .{ gdk.KEY_5, .digit_5 },
    .{ gdk.KEY_6, .digit_6 },
    .{ gdk.KEY_7, .digit_7 },
    .{ gdk.KEY_8, .digit_8 },
    .{ gdk.KEY_9, .digit_9 },
    .{ gdk.KEY_semicolon, .semicolon },
    .{ gdk.KEY_space, .space },
    .{ gdk.KEY_apostrophe, .quote },
    .{ gdk.KEY_comma, .comma },
    .{ gdk.KEY_grave, .backquote },
    .{ gdk.KEY_period, .period },
    .{ gdk.KEY_slash, .slash },
    .{ gdk.KEY_minus, .minus },
    .{ gdk.KEY_equal, .equal },
    .{ gdk.KEY_bracketleft, .bracket_left },
    .{ gdk.KEY_bracketright, .bracket_right },
    .{ gdk.KEY_backslash, .backslash },
    .{ gdk.KEY_Up, .arrow_up },
    .{ gdk.KEY_Down, .arrow_down },
    .{ gdk.KEY_Right, .arrow_right },
    .{ gdk.KEY_Left, .arrow_left },
    .{ gdk.KEY_Home, .home },
    .{ gdk.KEY_End, .end },
    .{ gdk.KEY_Insert, .insert },
    .{ gdk.KEY_Delete, .delete },
    .{ gdk.KEY_Caps_Lock, .caps_lock },
    .{ gdk.KEY_Scroll_Lock, .scroll_lock },
    .{ gdk.KEY_Num_Lock, .num_lock },
    .{ gdk.KEY_Page_Up, .page_up },
    .{ gdk.KEY_Page_Down, .page_down },
    .{ gdk.KEY_Escape, .escape },
    .{ gdk.KEY_Return, .enter },
    .{ gdk.KEY_Tab, .tab },
    .{ gdk.KEY_BackSpace, .backspace },
    .{ gdk.KEY_Print, .print_screen },
    .{ gdk.KEY_Pause, .pause },
    .{ gdk.KEY_F1, .f1 },
    .{ gdk.KEY_F2, .f2 },
    .{ gdk.KEY_F3, .f3 },
    .{ gdk.KEY_F4, .f4 },
    .{ gdk.KEY_F5, .f5 },
    .{ gdk.KEY_F6, .f6 },
    .{ gdk.KEY_F7, .f7 },
    .{ gdk.KEY_F8, .f8 },
    .{ gdk.KEY_F9, .f9 },
    .{ gdk.KEY_F10, .f10 },
    .{ gdk.KEY_F11, .f11 },
    .{ gdk.KEY_F12, .f12 },
    .{ gdk.KEY_F13, .f13 },
    .{ gdk.KEY_F14, .f14 },
    .{ gdk.KEY_F15, .f15 },
    .{ gdk.KEY_F16, .f16 },
    .{ gdk.KEY_F17, .f17 },
    .{ gdk.KEY_F18, .f18 },
    .{ gdk.KEY_F19, .f19 },
    .{ gdk.KEY_F20, .f20 },
    .{ gdk.KEY_F21, .f21 },
    .{ gdk.KEY_F22, .f22 },
    .{ gdk.KEY_F23, .f23 },
    .{ gdk.KEY_F24, .f24 },
    .{ gdk.KEY_F25, .f25 },
    .{ gdk.KEY_KP_0, .numpad_0 },
    .{ gdk.KEY_KP_1, .numpad_1 },
    .{ gdk.KEY_KP_2, .numpad_2 },
    .{ gdk.KEY_KP_3, .numpad_3 },
    .{ gdk.KEY_KP_4, .numpad_4 },
    .{ gdk.KEY_KP_5, .numpad_5 },
    .{ gdk.KEY_KP_6, .numpad_6 },
    .{ gdk.KEY_KP_7, .numpad_7 },
    .{ gdk.KEY_KP_8, .numpad_8 },
    .{ gdk.KEY_KP_9, .numpad_9 },
    .{ gdk.KEY_KP_Decimal, .numpad_decimal },
    .{ gdk.KEY_KP_Divide, .numpad_divide },
    .{ gdk.KEY_KP_Multiply, .numpad_multiply },
    .{ gdk.KEY_KP_Subtract, .numpad_subtract },
    .{ gdk.KEY_KP_Add, .numpad_add },
    .{ gdk.KEY_KP_Enter, .numpad_enter },
    .{ gdk.KEY_KP_Equal, .numpad_equal },
    .{ gdk.KEY_KP_Separator, .numpad_separator },
    .{ gdk.KEY_KP_Left, .numpad_left },
    .{ gdk.KEY_KP_Right, .numpad_right },
    .{ gdk.KEY_KP_Up, .numpad_up },
    .{ gdk.KEY_KP_Down, .numpad_down },
    .{ gdk.KEY_KP_Page_Up, .numpad_page_up },
    .{ gdk.KEY_KP_Page_Down, .numpad_page_down },
    .{ gdk.KEY_KP_Home, .numpad_home },
    .{ gdk.KEY_KP_End, .numpad_end },
    .{ gdk.KEY_KP_Insert, .numpad_insert },
    .{ gdk.KEY_KP_Delete, .numpad_delete },
    .{ gdk.KEY_KP_Begin, .numpad_begin },
    .{ gdk.KEY_Copy, .copy },
    .{ gdk.KEY_Cut, .cut },
    .{ gdk.KEY_Paste, .paste },
    .{ gdk.KEY_Shift_L, .shift_left },
    .{ gdk.KEY_Control_L, .control_left },
    .{ gdk.KEY_Alt_L, .alt_left },
    .{ gdk.KEY_Super_L, .meta_left },
    .{ gdk.KEY_Shift_R, .shift_right },
    .{ gdk.KEY_Control_R, .control_right },
    .{ gdk.KEY_Alt_R, .alt_right },
    .{ gdk.KEY_Super_R, .meta_right },
};
