const Keymap = @This();
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const macos = @import("macos");
const codes = @import("keycodes.zig").entries;
const Mods = @import("key.zig").Mods;
source: *TISInputSource,
unicode_layout: *const UCKeyboardLayout,
pub const Error = error{
    GetInputSourceFailed,
    TranslateFailed,
};
pub const State = struct {
    dead_key: u32 = 0,
};
pub const Translation = struct {
    text: []const u8 = "",
    composing: bool = false,
    mods: Mods = .{},
};
pub fn init() !Keymap {
    var keymap: Keymap = .{ .source = undefined, .unicode_layout = undefined };
    try keymap.reinit();
    return keymap;
}
pub fn deinit(self: *const Keymap) void {
    macos.foundation.CFRelease(self.source);
}
pub fn reload(self: *Keymap) !void {
    macos.foundation.CFRelease(self.source);
    try self.reinit();
}
pub fn sourceId(self: *const Keymap, buf: []u8) Allocator.Error![]const u8 {
    const id_raw = TISGetInputSourceProperty(
        self.source,
        kTISPropertyInputSourceID,
    ) orelse return error.OutOfMemory;
    const id: *CFString = @ptrCast(id_raw);
    return id.cstring(buf, .utf8) orelse error.OutOfMemory;
}
fn reinit(self: *Keymap) !void {
    self.source = TISCopyCurrentKeyboardLayoutInputSource() orelse
        return Error.GetInputSourceFailed;
    self.unicode_layout = layout: {
        const data_raw = TISGetInputSourceProperty(
            self.source,
            kTISPropertyUnicodeKeyLayoutData,
        ) orelse return Error.GetInputSourceFailed;
        const data: *CFData = @ptrCast(data_raw);
        break :layout @ptrCast(data.getPointer());
    };
    if (comptime builtin.mode == .Debug) id: {
        var buf: [256]u8 = undefined;
        const id = self.sourceId(&buf) catch break :id;
        std.log.debug("keyboard layout={s}", .{id});
    }
}
pub fn translate(
    self: *const Keymap,
    out: []u8,
    state: *State,
    code: u16,
    input_mods: Mods,
) !Translation {
    const mods: Mods = mods: {
        var v = input_mods;
        v.ctrl = false;
        break :mods v;
    };
    const code_space: u16 = comptime space: for (codes) |entry| {
        if (std.mem.eql(u8, entry.code, "Space"))
            break :space entry.native;
    } else @compileError("space code not found");
    const modifier_state: u32 = (CarbonMods{
        .alt = if (mods.alt) true else false,
        .ctrl = if (mods.ctrl) true else false,
        .meta = if (mods.super) true else false,
        .shift = if (mods.shift) true else false,
        .caps_lock = if (mods.caps_lock) true else false,
    }).ucKeyTranslate();
    var char: [4]u16 = undefined;
    var char_count: c_ulong = 0;
    if (UCKeyTranslate(
        self.unicode_layout,
        code,
        kUCKeyActionDown,
        modifier_state,
        LMGetKbdType(),
        kUCKeyTranslateNoDeadKeysBit,
        &state.dead_key,
        char.len,
        &char_count,
        &char,
    ) != 0) return Error.TranslateFailed;
    const composing = if (state.dead_key != 0 and char_count == 0) composing: {
        var dead_key_ignore: u32 = state.dead_key;
        if (UCKeyTranslate(
            self.unicode_layout,
            code_space,
            kUCKeyActionDown,
            modifier_state,
            LMGetKbdType(),
            kUCKeyTranslateNoDeadKeysMask,
            &dead_key_ignore,
            char.len,
            &char_count,
            &char,
        ) != 0) return Error.TranslateFailed;
        break :composing true;
    } else false;
    const len = try std.unicode.utf16LeToUtf8(out, char[0..char_count]);
    return .{
        .text = out[0..len],
        .composing = composing,
        .mods = mods,
    };
}
const CarbonMods = packed struct(u32) {
    _padding_start: u8 = 0,
    meta: bool = false,
    shift: bool = false,
    caps_lock: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    _padding_end: u19 = 0,
    fn ucKeyTranslate(self: CarbonMods) u32 {
        const int: u32 = @bitCast(self);
        return (int >> 8) & 0xFF;
    }
    test "expected values" {
        const testing = std.testing;
        try testing.expectEqual(@as(u32, 0x100), @as(u32, @bitCast(CarbonMods{ .meta = true })));
        try testing.expectEqual(@as(u32, 0x200), @as(u32, @bitCast(CarbonMods{ .shift = true })));
        try testing.expectEqual(@as(u32, 0x400), @as(u32, @bitCast(CarbonMods{ .caps_lock = true })));
        try testing.expectEqual(@as(u32, 0x800), @as(u32, @bitCast(CarbonMods{ .alt = true })));
        try testing.expectEqual(@as(u32, 0x1000), @as(u32, @bitCast(CarbonMods{ .ctrl = true })));
    }
};
extern "c" fn TISCopyCurrentKeyboardLayoutInputSource() ?*TISInputSource;
extern "c" fn TISGetInputSourceProperty(*TISInputSource, *CFString) ?*anyopaque;
extern "c" fn LMGetKbdLast() u8;
extern "c" fn LMGetKbdType() u8;
extern "c" fn UCKeyTranslate(*const UCKeyboardLayout, u16, u16, u32, u32, u32, *u32, c_ulong, *c_ulong, [*]u16) i32;
extern const kTISPropertyLocalizedName: *CFString;
extern const kTISPropertyUnicodeKeyLayoutData: *CFString;
extern const kTISPropertyInputSourceID: *CFString;
const TISInputSource = opaque {};
const UCKeyboardLayout = opaque {};
const kUCKeyActionDown: u16 = 0;
const kUCKeyActionUp: u16 = 1;
const kUCKeyActionAutoKey: u16 = 2;
const kUCKeyActionDisplay: u16 = 3;
const kUCKeyTranslateNoDeadKeysBit: u32 = 0;
const kUCKeyTranslateNoDeadKeysMask: u32 = 1 << kUCKeyTranslateNoDeadKeysBit;
const CFData = macos.foundation.Data;
const CFString = macos.foundation.String;
test {
    var keymap = try init();
    defer keymap.deinit();
}
