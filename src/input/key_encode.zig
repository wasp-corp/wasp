const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const KittyFlags = @import("../terminal/kitty/key.zig").Flags;
const OptionAsAlt = @import("config.zig").OptionAsAlt;
const Terminal = @import("../terminal/Terminal.zig");
const function_keys = @import("function_keys.zig");
const key = @import("key.zig");
const KittyEntry = @import("kitty.zig").Entry;
const kitty_entries = @import("kitty.zig").entries;
pub const Options = struct {
    cursor_key_application: bool = false,
    keypad_key_application: bool = false,
    backarrow_key_mode: bool = false,
    ignore_keypad_with_numlock: bool = false,
    alt_esc_prefix: bool = false,
    modify_other_keys_state_2: bool = false,
    kitty_flags: KittyFlags = .disabled,
    macos_option_as_alt: OptionAsAlt = .false,
    pub const default: Options = .{
        .cursor_key_application = false,
        .keypad_key_application = false,
        .ignore_keypad_with_numlock = false,
        .alt_esc_prefix = false,
        .modify_other_keys_state_2 = false,
        .kitty_flags = .disabled,
        .macos_option_as_alt = .false,
    };
    pub fn fromTerminal(t: *const Terminal) Options {
        return .{
            .alt_esc_prefix = t.modes.get(.alt_esc_prefix),
            .cursor_key_application = t.modes.get(.cursor_keys),
            .keypad_key_application = t.modes.get(.keypad_keys),
            .backarrow_key_mode = t.modes.get(.backarrow_key_mode),
            .ignore_keypad_with_numlock = t.modes.get(.ignore_keypad_with_numlock),
            .modify_other_keys_state_2 = t.flags.modify_other_keys_2,
            .kitty_flags = t.screens.active.kitty_keyboard.current(),
            .macos_option_as_alt = .false,
        };
    }
};
pub fn encode(
    writer: *std.Io.Writer,
    event: key.KeyEvent,
    opts: Options,
) std.Io.Writer.Error!void {
    return if (opts.kitty_flags.int() != 0) try kitty(
        writer,
        event,
        opts,
    ) else try legacy(
        writer,
        event,
        opts,
    );
}
fn kitty(
    writer: *std.Io.Writer,
    event: key.KeyEvent,
    opts: Options,
) std.Io.Writer.Error!void {
    if (opts.kitty_flags.int() == 0) return try legacy(
        writer,
        event,
        opts,
    );
    if (event.action == .release) {
        if (!opts.kitty_flags.report_events) return;
        if (!opts.kitty_flags.report_all) {
            switch (event.key) {
                .enter, .backspace, .tab => return,
                else => {},
            }
        }
    }
    const all_mods = event.mods;
    const effective_mods = event.effectiveMods();
    const binding_mods = effective_mods.binding();
    const entry_: ?KittyEntry = entry: {
        for (kitty_entries) |entry| {
            if (entry.key == event.key) break :entry entry;
        }
        if (event.unshifted_codepoint > 0) {
            break :entry .{
                .key = event.key,
                .code = event.unshifted_codepoint,
                .final = 'u',
                .modifier = false,
            };
        }
        break :entry null;
    };
    preprocessing: {
        if (event.composing) {
            if (entry_) |entry| {
                if (entry.modifier) break :preprocessing;
            }
            return;
        }
        if (event.utf8.len > 0) utf8: {
            switch (event.key) {
                else => {},
                inline .enter, .backspace => |tag| {
                    if (isControlUtf8(event.utf8)) break :utf8;
                    if (comptime tag == .backspace) return;
                    return try writer.writeAll(event.utf8);
                },
            }
        }
        if (!opts.kitty_flags.report_all) {
            if (binding_mods.empty()) {
                switch (event.key) {
                    .enter => return try writer.writeByte('\r'),
                    .tab => return try writer.writeByte('\t'),
                    .backspace => return try writer.writeByte(0x7F),
                    else => {},
                }
            }
            if (event.utf8.len > 0 and
                binding_mods.empty() and
                event.action != .release)
            plain_text: {
                const view = std.unicode.Utf8View.init(event.utf8) catch {
                    break :plain_text;
                };
                var it = view.iterator();
                while (it.nextCodepoint()) |cp| {
                    if (isControl(cp)) break :plain_text;
                }
                return try writer.writeAll(event.utf8);
            }
        }
    }
    const entry = entry_ orelse {
        if (event.action == .release) return;
        if (event.utf8.len == 0) return;
        return try writer.writeAll(event.utf8);
    };
    if (entry.modifier and !opts.kitty_flags.report_all) return;
    const seq: KittySequence = seq: {
        var seq: KittySequence = .{
            .key = entry.code,
            .final = entry.final,
            .mods = .fromInput(
                event.action,
                event.key,
                all_mods,
            ),
        };
        if (opts.kitty_flags.report_events) {
            seq.event = switch (event.action) {
                .press => .press,
                .release => .release,
                .repeat => .repeat,
            };
        }
        if (opts.kitty_flags.report_alternates) alternates: {
            if (isControl(seq.key)) break :alternates;
            const view = std.unicode.Utf8View.init(event.utf8) catch {
                break :alternates;
            };
            var it = view.iterator();
            if (it.nextCodepoint()) |cp1| {
                if (cp1 != seq.key and seq.mods.shift) seq.alternates[0] = cp1;
                const has_cp2 = it.nextCodepoint() != null;
                if (event.key.codepoint()) |base| {
                    if (base != seq.key and
                        (cp1 != base and !has_cp2))
                    {
                        seq.alternates[1] = base;
                    }
                }
            } else {
                if (event.key.codepoint()) |base| {
                    if (base != seq.key) seq.alternates[1] = base;
                }
            }
        }
        if (opts.kitty_flags.report_associated and
            seq.event != .release)
        associated: {
            const alt_prevents_text = if (comptime builtin.os.tag == .macos)
                switch (opts.macos_option_as_alt) {
                    .left => all_mods.sides.alt == .left,
                    .right => all_mods.sides.alt == .right,
                    .true => true,
                    .false => false,
                }
            else
                true;
            if (seq.mods.preventsText(alt_prevents_text)) break :associated;
            seq.text = event.utf8;
        }
        break :seq seq;
    };
    return try seq.encode(writer);
}
fn legacy(
    writer: *std.Io.Writer,
    event: key.KeyEvent,
    opts: Options,
) std.Io.Writer.Error!void {
    const all_mods = event.mods;
    const effective_mods = event.effectiveMods();
    const binding_mods = effective_mods.binding();
    if (event.action != .press and event.action != .repeat) return;
    if (event.composing) return;
    if (pcStyleFunctionKey(
        event.key,
        all_mods,
        opts.cursor_key_application,
        opts.keypad_key_application,
        opts.ignore_keypad_with_numlock,
        opts.modify_other_keys_state_2,
        opts.backarrow_key_mode,
    )) |sequence| pc_style: {
        if (event.utf8.len > 0) utf8: {
            switch (event.key) {
                else => {},
                inline .backspace, .enter, .escape => |tag| {
                    if (isControlUtf8(event.utf8)) break :utf8;
                    if (comptime tag == .backspace) return;
                    break :pc_style;
                },
            }
        }
        return try writer.writeAll(sequence);
    }
    const utf8 = event.utf8;
    if (opts.modify_other_keys_state_2) modify_other: {
        const view = std.unicode.Utf8View.init(utf8) catch {
            break :modify_other;
        };
        var it = view.iterator();
        const codepoint = it.nextCodepoint() orelse break :modify_other;
        if (it.nextCodepoint() != null) break :modify_other;
        const mods = mods: {
            var mods_binding = event.mods.binding();
            if (comptime builtin.target.os.tag.isDarwin()) alt: {
                switch (opts.macos_option_as_alt) {
                    .false => {},
                    .true => break :alt,
                    .left => if (event.mods.sides.alt == .left) break :alt,
                    .right => if (event.mods.sides.alt == .right) break :alt,
                }
                mods_binding.alt = false;
            }
            break :mods mods_binding;
        };
        const should_modify = should_modify: {
            if (codepoint >= 0x40 and codepoint <= 0x7F)
                break :should_modify true;
            var mods_no_shift = mods;
            mods_no_shift.shift = false;
            if (!mods_no_shift.empty()) break :should_modify true;
            if (codepoint == ' ') break :should_modify true;
            break :should_modify false;
        };
        if (should_modify) {
            for (function_keys.modifiers, 2..) |modset, code| {
                if (!mods.equal(modset)) continue;
                return try writer.print(
                    "\x1B[27;{};{}~",
                    .{ code, codepoint },
                );
            }
        }
    }
    if (ctrlSeq(
        event.key,
        event.utf8,
        event.unshifted_codepoint,
        all_mods,
    )) |char| {
        if (binding_mods.alt) {
            try writer.writeByte(0x1B);
            try writer.writeByte(char);
            return;
        }
        try writer.writeByte(char);
        return;
    }
    if (utf8.len == 0) {
        _ = try legacyAltPrefix(
            writer,
            event,
            binding_mods,
            all_mods,
            opts,
        );
        return;
    }
    if (event.mods.ctrl) csiu: {
        const csi_u_mods, const char = mods: {
            var mods = CsiUMods.fromInput(event.mods);
            const view = std.unicode.Utf8View.init(event.utf8) catch break :csiu;
            var it = view.iterator();
            var char = it.nextCodepoint() orelse break :csiu;
            if (it.nextCodepoint() != null) break :csiu;
            if (char >= 'A' and char <= 'Z' and mods.shift) {
                char = @intCast(std.ascii.toLower(@intCast(char)));
            }
            if (event.unshifted_codepoint != char) {
                mods.shift = false;
            }
            break :mods .{ mods, char };
        };
        return try writer.print(
            "\x1B[{};{}u",
            .{ char, csi_u_mods.seqInt() },
        );
    }
    if (try legacyAltPrefix(
        writer,
        event,
        binding_mods,
        all_mods,
        opts,
    )) return;
    if ((comptime builtin.os.tag == .macos) and all_mods.super) {
        return;
    }
    return try writer.writeAll(utf8);
}
fn legacyAltPrefix(
    writer: *std.Io.Writer,
    event: key.KeyEvent,
    binding_mods: key.Mods,
    mods: key.Mods,
    opts: Options,
) std.Io.Writer.Error!bool {
    if (!binding_mods.alt or !opts.alt_esc_prefix) return false;
    if (comptime builtin.os.tag == .macos) {
        switch (opts.macos_option_as_alt) {
            .false => return false,
            .left => if (mods.sides.alt == .right) return false,
            .right => if (mods.sides.alt == .left) return false,
            .true => {},
        }
    }
    const utf8 = event.utf8;
    if (utf8.len == 1) {
        try writer.writeByte(0x1B);
        try writer.writeAll(utf8);
        return true;
    }
    var unshifted_buf: [4]u8 = undefined;
    const value: []const u8 = value: {
        if (comptime builtin.os.tag == .macos) {
            if (event.unshifted_codepoint > 0) {
                const len = std.unicode.utf8Encode(
                    event.unshifted_codepoint,
                    &unshifted_buf,
                ) catch return false;
                break :value unshifted_buf[0..len];
            }
        }
        if (utf8.len > 0) break :value utf8;
        if (event.unshifted_codepoint > 0) {
            const len = std.unicode.utf8Encode(
                event.unshifted_codepoint,
                &unshifted_buf,
            ) catch return false;
            break :value unshifted_buf[0..len];
        }
        return false;
    };
    try writer.writeByte(0x1B);
    try writer.writeAll(value);
    return true;
}
fn copyToBuf(buf: []u8, src: []const u8) ![]const u8 {
    if (src.len > buf.len) return error.OutOfMemory;
    const result = buf[0..src.len];
    @memcpy(result, src);
    return result;
}
fn pcStyleFunctionKey(
    keyval: key.Key,
    mods: key.Mods,
    cursor_key_application: bool,
    keypad_key_application_req: bool,
    ignore_keypad_with_numlock: bool,
    modify_other_keys: bool, 
    backarrow_key_mode: bool,
) ?[]const u8 {
    const mods_int = mods.binding().int();
    const keypad_key_application = keypad: {
        if (ignore_keypad_with_numlock) break :keypad false;
        break :keypad keypad_key_application_req;
    };
    for (function_keys.keys.get(keyval)) |entry| {
        switch (entry.cursor) {
            .any => {},
            .normal => if (cursor_key_application) continue,
            .application => if (!cursor_key_application) continue,
        }
        switch (entry.keypad) {
            .any => {},
            .normal => if (keypad_key_application) continue,
            .application => if (!keypad_key_application) continue,
        }
        switch (entry.modify_other_keys) {
            .any => {},
            .set => if (modify_other_keys) continue,
            .set_other => if (!modify_other_keys) continue,
        }
        const entry_mods_int = entry.mods.int();
        if (entry_mods_int == 0) {
            if (mods_int != 0 and !entry.mods_empty_is_any) continue;
        } else if (entry_mods_int != mods_int) {
            continue;
        }
        if (backarrow_key_mode)
            if (entry.sequence_decbkm) |sequence|
                return sequence;
        return entry.sequence;
    }
    return null;
}
fn ctrlSeq(
    logical_key: key.Key,
    utf8: []const u8,
    unshifted_codepoint: u21,
    mods: key.Mods,
) ?u8 {
    const ctrl_only = comptime (key.Mods{ .ctrl = true }).int();
    if (!mods.ctrl) return null;
    const char, const unset_mods = unset_mods: {
        var unset_mods = mods.binding();
        unset_mods.alt = false;
        var char: u8 = char: {
            if (utf8.len == 1) break :char utf8[0];
            if (logical_key.codepoint()) |cp| {
                if (std.math.cast(u8, cp)) |byte| {
                    if (unset_mods.int() != ctrl_only) return null;
                    break :char byte;
                }
            }
            return null;
        };
        if (unset_mods.shift and (char < 'A' or char > 'Z')) shift: {
            if (char == '@') break :shift;
            unset_mods.shift = false;
        }
        if (char >= 'A' and char <= 'Z' and unshifted_codepoint > 0) {
            if (std.math.cast(u8, unshifted_codepoint)) |byte| {
                char = byte;
            }
        }
        break :unset_mods .{ char, unset_mods };
    };
    if (unset_mods.int() != ctrl_only) return null;
    return switch (char) {
        ' ' => 0,
        '/' => 31,
        '0' => 48,
        '1' => 49,
        '2' => 0,
        '3' => 27,
        '4' => 28,
        '5' => 29,
        '6' => 30,
        '7' => 31,
        '8' => 127,
        '9' => 57,
        '?' => 127,
        '@' => 0,
        '\\' => 28,
        ']' => 29,
        '^' => 30,
        '_' => 31,
        'a' => 1,
        'b' => 2,
        'c' => 3,
        'd' => 4,
        'e' => 5,
        'f' => 6,
        'g' => 7,
        'h' => 8,
        'j' => 10,
        'k' => 11,
        'l' => 12,
        'n' => 14,
        'o' => 15,
        'p' => 16,
        'q' => 17,
        'r' => 18,
        's' => 19,
        't' => 20,
        'u' => 21,
        'v' => 22,
        'w' => 23,
        'x' => 24,
        'y' => 25,
        'z' => 26,
        '~' => 30,
        else => null,
    };
}
fn isControl(cp: u21) bool {
    return cp < 0x20 or cp == 0x7F;
}
fn isControlUtf8(str: []const u8) bool {
    return str.len == 1 and isControl(@intCast(str[0]));
}
const CsiUMods = packed struct(u3) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    pub fn fromInput(mods: key.Mods) CsiUMods {
        return .{
            .shift = mods.shift,
            .alt = mods.alt,
            .ctrl = mods.ctrl,
        };
    }
    pub fn int(self: CsiUMods) u3 {
        return @bitCast(self);
    }
    pub fn seqInt(self: CsiUMods) u4 {
        const raw: u4 = @intCast(self.int());
        return raw + 1;
    }
    test "modifier sequence values" {
        var mods: CsiUMods = .{};
        try testing.expectEqual(@as(u4, 1), mods.seqInt());
        mods = .{ .shift = true };
        try testing.expectEqual(@as(u4, 2), mods.seqInt());
        mods = .{ .alt = true };
        try testing.expectEqual(@as(u4, 3), mods.seqInt());
        mods = .{ .ctrl = true };
        try testing.expectEqual(@as(u4, 5), mods.seqInt());
        mods = .{ .alt = true, .shift = true };
        try testing.expectEqual(@as(u4, 4), mods.seqInt());
        mods = .{ .ctrl = true, .shift = true };
        try testing.expectEqual(@as(u4, 6), mods.seqInt());
        mods = .{ .alt = true, .ctrl = true };
        try testing.expectEqual(@as(u4, 7), mods.seqInt());
        mods = .{ .alt = true, .ctrl = true, .shift = true };
        try testing.expectEqual(@as(u4, 8), mods.seqInt());
    }
};
const KittyMods = packed struct(u8) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,
    hyper: bool = false,
    meta: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    pub fn fromInput(
        action: key.Action,
        k: key.Key,
        mods: key.Mods,
    ) KittyMods {
        _ = action;
        _ = k;
        return .{
            .shift = mods.shift,
            .alt = mods.alt,
            .ctrl = mods.ctrl,
            .super = mods.super,
            .caps_lock = mods.caps_lock,
            .num_lock = mods.num_lock,
        };
    }
    pub fn preventsText(self: KittyMods, alt_prevents_text: bool) bool {
        return (self.alt and alt_prevents_text) or
            self.ctrl or
            self.super or
            self.hyper or
            self.meta;
    }
    pub fn int(self: KittyMods) u8 {
        return @bitCast(self);
    }
    pub fn seqInt(self: KittyMods) u9 {
        const raw: u9 = @intCast(self.int());
        return raw + 1;
    }
    test "modifier sequence values" {
        var mods: KittyMods = .{};
        try testing.expectEqual(@as(u9, 1), mods.seqInt());
        mods = .{ .shift = true };
        try testing.expectEqual(@as(u9, 2), mods.seqInt());
        mods = .{ .alt = true };
        try testing.expectEqual(@as(u9, 3), mods.seqInt());
        mods = .{ .ctrl = true };
        try testing.expectEqual(@as(u9, 5), mods.seqInt());
        mods = .{ .alt = true, .shift = true };
        try testing.expectEqual(@as(u9, 4), mods.seqInt());
        mods = .{ .ctrl = true, .shift = true };
        try testing.expectEqual(@as(u9, 6), mods.seqInt());
        mods = .{ .alt = true, .ctrl = true };
        try testing.expectEqual(@as(u9, 7), mods.seqInt());
        mods = .{ .alt = true, .ctrl = true, .shift = true };
        try testing.expectEqual(@as(u9, 8), mods.seqInt());
    }
};
const KittySequence = struct {
    key: u21,
    final: u8,
    mods: KittyMods = .{},
    event: Event = .none,
    alternates: [2]?u21 = .{ null, null },
    text: []const u8 = "",
    const Event = enum(u2) {
        none = 0,
        press = 1,
        repeat = 2,
        release = 3,
    };
    pub fn encode(
        self: KittySequence,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        if (self.final == 'u' or self.final == '~') return try self.encodeFull(writer);
        return try self.encodeSpecial(writer);
    }
    fn encodeFull(
        self: KittySequence,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("\x1B[{d}", .{self.key});
        if (self.alternates[0]) |shifted| try writer.print(":{d}", .{shifted});
        if (self.alternates[1]) |base| {
            if (self.alternates[0] == null) {
                try writer.print("::{d}", .{base});
            } else {
                try writer.print(":{d}", .{base});
            }
        }
        const mods = self.mods.seqInt();
        var emit_prior = false;
        if (self.event != .none and self.event != .press) {
            try writer.print(
                ";{d}:{d}",
                .{ mods, @intFromEnum(self.event) },
            );
            emit_prior = true;
        } else if (mods > 1) {
            try writer.print(";{d}", .{mods});
            emit_prior = true;
        }
        if (self.text.len > 0) text: {
            const view = std.unicode.Utf8View.init(self.text) catch {
                break :text;
            };
            var it = view.iterator();
            var count: usize = 0;
            while (it.nextCodepoint()) |cp| {
                if (isControl(cp)) continue;
                if (count == 0) {
                    if (!emit_prior) try writer.writeByte(';');
                    try writer.writeByte(';');
                } else {
                    try writer.writeByte(':');
                }
                try writer.print("{d}", .{cp});
                count += 1;
            }
        }
        try writer.print("{c}", .{self.final});
    }
    fn encodeSpecial(
        self: KittySequence,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const mods = self.mods.seqInt();
        if (self.event != .none) {
            return try writer.print("\x1B[1;{d}:{d}{c}", .{
                mods,
                @intFromEnum(self.event),
                self.final,
            });
        }
        if (mods > 1) {
            return try writer.print("\x1B[1;{d}{c}", .{
                mods,
                self.final,
            });
        }
        return try writer.print("\x1B[{c}", .{self.final});
    }
};
test "KittySequence: backspace" {
    var buf: [128]u8 = undefined;
    {
        var writer: std.Io.Writer = .fixed(&buf);
        var seq: KittySequence = .{ .key = 127, .final = 'u' };
        try seq.encode(&writer);
        try testing.expectEqualStrings("\x1B[127u", writer.buffered());
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        var seq: KittySequence = .{ .key = 127, .final = 'u', .event = .release };
        try seq.encode(&writer);
        try testing.expectEqualStrings("\x1B[127;1:3u", writer.buffered());
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        var seq: KittySequence = .{
            .key = 127,
            .final = 'u',
            .mods = .{ .shift = true },
        };
        try seq.encode(&writer);
        try testing.expectEqualStrings("\x1B[127;2u", writer.buffered());
    }
}
test "KittySequence: text" {
    var buf: [128]u8 = undefined;
    {
        var writer: std.Io.Writer = .fixed(&buf);
        var seq: KittySequence = .{
            .key = 127,
            .final = 'u',
            .text = "A",
        };
        try seq.encode(&writer);
        try testing.expectEqualStrings("\x1B[127;;65u", writer.buffered());
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        var seq: KittySequence = .{
            .key = 127,
            .final = 'u',
            .event = .release,
            .text = "A",
        };
        try seq.encode(&writer);
        try testing.expectEqualStrings("\x1B[127;1:3;65u", writer.buffered());
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        var seq: KittySequence = .{
            .key = 127,
            .final = 'u',
            .mods = .{ .shift = true },
            .text = "A",
        };
        try seq.encode(&writer);
        try testing.expectEqualStrings("\x1B[127;2;65u", writer.buffered());
    }
}
test "KittySequence: text with control characters" {
    var buf: [128]u8 = undefined;
    {
        var writer: std.Io.Writer = .fixed(&buf);
        var seq: KittySequence = .{
            .key = 127,
            .final = 'u',
            .text = "\n",
        };
        try seq.encode(&writer);
        try testing.expectEqualStrings("\x1b[127u", writer.buffered());
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        var seq: KittySequence = .{
            .key = 127,
            .final = 'u',
            .text = "A\n",
        };
        try seq.encode(&writer);
        try testing.expectEqualStrings("\x1b[127;;65u", writer.buffered());
    }
}
test "KittySequence: special no mods" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var seq: KittySequence = .{ .key = 1, .final = 'A' };
    try seq.encode(&writer);
    try testing.expectEqualStrings("\x1B[A", writer.buffered());
}
test "KittySequence: special mods only" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var seq: KittySequence = .{ .key = 1, .final = 'A', .mods = .{ .shift = true } };
    try seq.encode(&writer);
    try testing.expectEqualStrings("\x1B[1;2A", writer.buffered());
}
test "KittySequence: special mods and event" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var seq: KittySequence = .{
        .key = 1,
        .final = 'A',
        .event = .release,
        .mods = .{ .shift = true },
    };
    try seq.encode(&writer);
    try testing.expectEqualStrings("\x1B[1;2:3A", writer.buffered());
}
test "kitty: plain text" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .key_a,
        .mods = .{},
        .utf8 = "abcd",
    }, .{
        .kitty_flags = .{ .disambiguate = true },
    });
    try testing.expectEqualStrings("abcd", writer.buffered());
}
test "kitty: repeat with just disambiguate" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .key_a,
        .action = .repeat,
        .mods = .{},
        .utf8 = "a",
    }, .{
        .kitty_flags = .{ .disambiguate = true },
    });
    try testing.expectEqualStrings("a", writer.buffered());
}
test "kitty: enter, backspace, tab" {
    var buf: [128]u8 = undefined;
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try kitty(&writer, .{ .key = .enter, .mods = .{}, .utf8 = "" }, .{
            .kitty_flags = .{ .disambiguate = true },
        });
        try testing.expectEqualStrings("\r", writer.buffered());
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try kitty(&writer, .{ .key = .backspace, .mods = .{}, .utf8 = "" }, .{
            .kitty_flags = .{ .disambiguate = true },
            .backarrow_key_mode = false,
        });
        try testing.expectEqualStrings("\x7f", writer.buffered());
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try kitty(&writer, .{ .key = .backspace, .mods = .{}, .utf8 = "" }, .{
            .kitty_flags = .{ .disambiguate = true },
            .backarrow_key_mode = true,
        });
        try testing.expectEqualStrings("\x7f", writer.buffered());
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try kitty(&writer, .{ .key = .tab, .mods = .{}, .utf8 = "" }, .{
            .kitty_flags = .{ .disambiguate = true },
        });
        try testing.expectEqualStrings("\t", writer.buffered());
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try kitty(&writer, .{ .action = .release, .key = .enter, .mods = .{}, .utf8 = "" }, .{
            .kitty_flags = .{ .disambiguate = true, .report_events = true },
        });
        try testing.expectEqualStrings("", writer.buffered());
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try kitty(&writer, .{ .action = .release, .key = .backspace, .mods = .{}, .utf8 = "" }, .{
            .kitty_flags = .{ .disambiguate = true, .report_events = true },
        });
        try testing.expectEqualStrings("", writer.buffered());
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try kitty(&writer, .{ .action = .release, .key = .tab, .mods = .{}, .utf8 = "" }, .{
            .kitty_flags = .{ .disambiguate = true, .report_events = true },
        });
        try testing.expectEqualStrings("", writer.buffered());
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try kitty(&writer, .{ .action = .release, .key = .enter, .mods = .{}, .utf8 = "" }, .{
            .kitty_flags = .{
                .disambiguate = true,
                .report_events = true,
                .report_all = true,
            },
        });
        try testing.expectEqualStrings("\x1b[13;1:3u", writer.buffered());
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try kitty(&writer, .{ .action = .release, .key = .backspace, .mods = .{}, .utf8 = "" }, .{
            .kitty_flags = .{
                .disambiguate = true,
                .report_events = true,
                .report_all = true,
            },
        });
        try testing.expectEqualStrings("\x1b[127;1:3u", writer.buffered());
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try kitty(&writer, .{ .action = .release, .key = .tab, .mods = .{}, .utf8 = "" }, .{
            .kitty_flags = .{
                .disambiguate = true,
                .report_events = true,
                .report_all = true,
            },
        });
        try testing.expectEqualStrings("\x1b[9;1:3u", writer.buffered());
    }
}
test "kitty: shift+backspace emits CSI u" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .backspace,
        .mods = .{ .shift = true },
        .utf8 = "",
    }, .{
        .kitty_flags = .{ .disambiguate = true },
    });
    try testing.expectEqualStrings("\x1b[127;2u", writer.buffered());
}
test "kitty: alt+backspace emits CSI u" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .backspace,
        .mods = .{ .alt = true },
        .consumed_mods = .{ .alt = true },
        .utf8 = "",
    }, .{
        .kitty_flags = .{ .disambiguate = true },
    });
    try testing.expectEqualStrings("\x1b[127;3u", writer.buffered());
}
test "kitty: shift+enter emits CSI u" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .enter,
        .mods = .{ .shift = true },
        .utf8 = "",
    }, .{
        .kitty_flags = .{ .disambiguate = true },
    });
    try testing.expectEqualStrings("\x1b[13;2u", writer.buffered());
}
test "kitty: shift+tab emits CSI u" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .tab,
        .mods = .{ .shift = true },
        .utf8 = "",
    }, .{
        .kitty_flags = .{ .disambiguate = true },
    });
    try testing.expectEqualStrings("\x1b[9;2u", writer.buffered());
}
test "kitty: enter with all flags" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{ .key = .enter, .mods = .{}, .utf8 = "" }, .{
        .kitty_flags = .{
            .disambiguate = true,
            .report_events = true,
            .report_alternates = true,
            .report_all = true,
            .report_associated = true,
        },
    });
    const actual = writer.buffered();
    try testing.expectEqualStrings("[13u", actual[1..]);
}
test "kitty: ctrl with all flags" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{ .key = .control_left, .mods = .{ .ctrl = true }, .utf8 = "" }, .{
        .kitty_flags = .{
            .disambiguate = true,
            .report_events = true,
            .report_alternates = true,
            .report_all = true,
            .report_associated = true,
        },
    });
    const actual = writer.buffered();
    try testing.expectEqualStrings("[57442;5u", actual[1..]);
}
test "kitty: ctrl release with ctrl mod set" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .action = .release,
        .key = .control_left,
        .mods = .{ .ctrl = true },
        .utf8 = "",
    }, .{
        .kitty_flags = .{
            .disambiguate = true,
            .report_events = true,
            .report_alternates = true,
            .report_all = true,
            .report_associated = true,
        },
    });
    const actual = writer.buffered();
    try testing.expectEqualStrings("[57442;5:3u", actual[1..]);
}
test "kitty: delete" {
    var buf: [128]u8 = undefined;
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try kitty(&writer, .{ .key = .delete, .mods = .{}, .utf8 = "\x7F" }, .{
            .kitty_flags = .{ .disambiguate = true },
        });
        try testing.expectEqualStrings("\x1b[3~", writer.buffered());
    }
}
test "kitty: composing with no modifier" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .key_a,
        .mods = .{ .shift = true },
        .composing = true,
    }, .{
        .kitty_flags = .{ .disambiguate = true },
    });
    try testing.expectEqualStrings("", writer.buffered());
}
test "kitty: composing with modifier" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .shift_left,
        .mods = .{ .shift = true },
        .composing = true,
    }, .{
        .kitty_flags = .{ .disambiguate = true, .report_all = true },
    });
    try testing.expectEqualStrings("\x1b[57441;2u", writer.buffered());
}
test "kitty: composed text with report all" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .unidentified,
        .mods = .{},
        .utf8 = "\xc3\xbb", 
    }, .{
        .kitty_flags = .{
            .disambiguate = true,
            .report_events = true,
            .report_alternates = true,
            .report_all = true,
            .report_associated = true,
        },
    });
    try testing.expectEqualStrings("\xc3\xbb", writer.buffered());
}
test "kitty: text fallback on release" {
    for ([_]bool{ false, true }) |report_all| {
        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try kitty(&writer, .{
            .action = .release,
            .key = .unidentified,
            .mods = .{ .shift = true },
            .utf8 = "!",
        }, .{
            .kitty_flags = .{
                .disambiguate = true,
                .report_events = true,
                .report_alternates = true,
                .report_all = report_all,
                .report_associated = true,
            },
        });
        try testing.expectEqualStrings("", writer.buffered());
    }
}
test "kitty: text fallback on repeat" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .action = .repeat,
        .key = .unidentified,
        .mods = .{ .shift = true },
        .utf8 = "!",
    }, .{
        .kitty_flags = .{
            .disambiguate = true,
            .report_events = true,
            .report_alternates = true,
            .report_associated = true,
        },
    });
    try testing.expectEqualStrings("!", writer.buffered());
}
test "kitty: shift+a on US keyboard" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .key_a,
        .mods = .{ .shift = true },
        .utf8 = "A",
        .unshifted_codepoint = 97, 
    }, .{
        .kitty_flags = .{
            .disambiguate = true,
            .report_alternates = true,
        },
    });
    try testing.expectEqualStrings("\x1b[97:65;2u", writer.buffered());
}
test "kitty: matching unshifted codepoint" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .key_a,
        .mods = .{ .shift = true },
        .utf8 = "A",
        .unshifted_codepoint = 65,
    }, .{
        .kitty_flags = .{
            .disambiguate = true,
            .report_alternates = true,
        },
    });
    try testing.expectEqualStrings("\x1b[65::97;2u", writer.buffered());
}
test "kitty: report alternates with caps" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .key_j,
        .mods = .{ .caps_lock = true },
        .utf8 = "J",
        .unshifted_codepoint = 106,
    }, .{
        .kitty_flags = .{
            .disambiguate = true,
            .report_all = true,
            .report_alternates = true,
            .report_associated = true,
        },
    });
    try testing.expectEqualStrings("\x1b[106;65;74u", writer.buffered());
}
test "kitty: report alternates colon (shift+';')" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .semicolon,
        .mods = .{ .shift = true },
        .utf8 = ":",
        .unshifted_codepoint = ';',
    }, .{
        .kitty_flags = .{
            .disambiguate = true,
            .report_all = true,
            .report_alternates = true,
            .report_associated = true,
        },
    });
    try testing.expectEqualStrings("\x1b[59:58;2;58u", writer.buffered());
}
test "kitty: report alternates with ru layout" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .semicolon,
        .mods = .{},
        .utf8 = "ч",
        .unshifted_codepoint = 1095,
    }, .{
        .kitty_flags = .{
            .disambiguate = true,
            .report_all = true,
            .report_alternates = true,
            .report_associated = true,
        },
    });
    try testing.expectEqualStrings("\x1b[1095::59;;1095u", writer.buffered());
}
test "kitty: report alternates with ru layout shifted" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .semicolon,
        .mods = .{ .shift = true },
        .utf8 = "Ч",
        .unshifted_codepoint = 1095,
    }, .{
        .kitty_flags = .{
            .disambiguate = true,
            .report_all = true,
            .report_alternates = true,
            .report_associated = true,
        },
    });
    try testing.expectEqualStrings("\x1b[1095:1063:59;2;1063u", writer.buffered());
}
test "kitty: report alternates with ru layout caps lock" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .semicolon,
        .mods = .{ .caps_lock = true },
        .utf8 = "Ч",
        .unshifted_codepoint = 1095,
    }, .{
        .kitty_flags = .{
            .disambiguate = true,
            .report_all = true,
            .report_alternates = true,
            .report_associated = true,
        },
    });
    try testing.expectEqualStrings("\x1b[1095::59;65;1063u", writer.buffered());
}
test "kitty: report alternates with hu layout release" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .action = .release,
        .key = .bracket_left,
        .mods = .{ .ctrl = true },
        .utf8 = "",
        .unshifted_codepoint = 337,
    }, .{
        .kitty_flags = .{
            .disambiguate = true,
            .report_all = true,
            .report_alternates = true,
            .report_associated = true,
            .report_events = true,
        },
    });
    const actual = writer.buffered();
    try testing.expectEqualStrings("[337::91;5:3u", actual[1..]);
}
test "kitty: up arrow with utf8" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .arrow_up,
        .mods = .{},
        .utf8 = &.{30},
    }, .{
        .kitty_flags = .{ .disambiguate = true },
    });
    try testing.expectEqualStrings("\x1b[A", writer.buffered());
}
test "kitty: shift+tab" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .tab,
        .mods = .{ .shift = true },
        .utf8 = "", 
    }, .{
        .kitty_flags = .{ .disambiguate = true, .report_alternates = true },
    });
    try testing.expectEqualStrings("\x1b[9;2u", writer.buffered());
}
test "kitty: left shift" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .shift_left,
        .mods = .{},
        .utf8 = "",
    }, .{
        .kitty_flags = .{ .disambiguate = true, .report_alternates = true },
    });
    try testing.expectEqualStrings("", writer.buffered());
}
test "kitty: left shift with report all" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .shift_left,
        .mods = .{},
        .utf8 = "",
    }, .{
        .kitty_flags = .{ .disambiguate = true, .report_all = true },
    });
    try testing.expectEqualStrings("\x1b[57441u", writer.buffered());
}
test "kitty: report associated with alt text on macOS with option" {
    if (comptime !builtin.target.os.tag.isDarwin()) return error.SkipZigTest;
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .key_w,
        .mods = .{ .alt = true },
        .utf8 = "∑",
        .unshifted_codepoint = 119,
    }, .{
        .kitty_flags = .{
            .disambiguate = true,
            .report_all = true,
            .report_alternates = true,
            .report_associated = true,
        },
        .macos_option_as_alt = .false,
    });
    try testing.expectEqualStrings("\x1b[119;3;8721u", writer.buffered());
}
test "kitty: report associated with alt text on macOS with alt" {
    if (comptime !builtin.target.os.tag.isDarwin()) return error.SkipZigTest;
    {
        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try kitty(&writer, .{
            .key = .key_w,
            .mods = .{ .alt = true },
            .utf8 = "∑",
            .unshifted_codepoint = 119,
        }, .{
            .kitty_flags = .{
                .disambiguate = true,
                .report_all = true,
                .report_alternates = true,
                .report_associated = true,
            },
            .macos_option_as_alt = .true,
        });
        try testing.expectEqualStrings("\x1b[119;3u", writer.buffered());
    }
    {
        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try kitty(&writer, .{
            .key = .key_w,
            .mods = .{},
            .utf8 = "∑",
            .unshifted_codepoint = 119,
        }, .{
            .kitty_flags = .{
                .disambiguate = true,
                .report_all = true,
                .report_alternates = true,
                .report_associated = true,
            },
            .macos_option_as_alt = .true,
        });
        try testing.expectEqualStrings("\x1b[119;;8721u", writer.buffered());
    }
}
test "kitty: report associated with modifiers" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .key_j,
        .mods = .{ .ctrl = true },
        .utf8 = "j",
        .unshifted_codepoint = 106,
    }, .{
        .kitty_flags = .{
            .disambiguate = true,
            .report_all = true,
            .report_alternates = true,
            .report_associated = true,
        },
    });
    try testing.expectEqualStrings("\x1b[106;5u", writer.buffered());
}
test "kitty: report associated" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .key_j,
        .mods = .{ .shift = true },
        .utf8 = "J",
        .unshifted_codepoint = 106,
    }, .{
        .kitty_flags = .{
            .disambiguate = true,
            .report_all = true,
            .report_alternates = true,
            .report_associated = true,
        },
    });
    try testing.expectEqualStrings("\x1b[106:74;2;74u", writer.buffered());
}
test "kitty: report associated on release" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .action = .release,
        .key = .key_j,
        .mods = .{ .shift = true },
        .utf8 = "J",
        .unshifted_codepoint = 106,
    }, .{
        .kitty_flags = .{
            .disambiguate = true,
            .report_all = true,
            .report_alternates = true,
            .report_associated = true,
            .report_events = true,
        },
    });
    const actual = writer.buffered();
    try testing.expectEqualStrings("[106:74;2:3u", actual[1..]);
}
test "kitty: alternates omit control characters" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .delete,
        .mods = .{},
        .utf8 = &.{0x7F},
    }, .{
        .kitty_flags = .{
            .disambiguate = true,
            .report_alternates = true,
            .report_all = true,
        },
    });
    try testing.expectEqualStrings("\x1b[3~", writer.buffered());
}
test "kitty: enter with utf8 (dead key state)" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .enter,
        .utf8 = "A",
        .unshifted_codepoint = 0x0D,
    }, .{
        .kitty_flags = .{
            .disambiguate = true,
            .report_alternates = true,
            .report_all = true,
        },
    });
    try testing.expectEqualStrings("A", writer.buffered());
}
test "kitty: keypad number" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .numpad_1,
        .mods = .{},
        .utf8 = "1",
    }, .{
        .kitty_flags = .{
            .disambiguate = true,
            .report_events = true,
            .report_alternates = true,
            .report_all = true,
            .report_associated = true,
        },
    });
    const actual = writer.buffered();
    try testing.expectEqualStrings("[57400;;49u", actual[1..]);
}
test "kitty: backspace with utf8 (dead key state)" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .backspace,
        .utf8 = "A",
        .unshifted_codepoint = 0x0D,
    }, .{
        .kitty_flags = .{
            .disambiguate = true,
            .report_events = true,
            .report_alternates = true,
            .report_all = true,
            .report_associated = true,
        },
    });
    try testing.expectEqualStrings("", writer.buffered());
}
test "legacy: backspace with utf8 (dead key state)" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .backspace,
        .utf8 = "A",
        .unshifted_codepoint = 0x0D,
    }, .{});
    try testing.expectEqualStrings("", writer.buffered());
}
test "kitty: backspace (DECBKM reset) (report_all: true)" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .backspace,
    }, .{
        .kitty_flags = .{
            .disambiguate = true,
            .report_events = true,
            .report_alternates = true,
            .report_all = true,
            .report_associated = true,
        },
        .backarrow_key_mode = false,
    });
    try testing.expectEqualStrings("\x1b[127u", writer.buffered());
}
test "kitty: backspace (DECBKM set) (report_all: true)" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try kitty(&writer, .{
        .key = .backspace,
    }, .{
        .kitty_flags = .{
            .disambiguate = true,
            .report_events = true,
            .report_alternates = true,
            .report_all = true,
            .report_associated = true,
        },
        .backarrow_key_mode = true,
    });
    try testing.expectEqualStrings("\x1b[127u", writer.buffered());
}
test "legacy: enter with utf8 (dead key state)" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .enter,
        .utf8 = "A",
        .unshifted_codepoint = 0x0D,
    }, .{});
    try testing.expectEqualStrings("A", writer.buffered());
}
test "legacy: esc with utf8 (dead key state)" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .escape,
        .utf8 = "A",
        .unshifted_codepoint = 0x0D,
    }, .{});
    try testing.expectEqualStrings("A", writer.buffered());
}
test "legacy: alt+escape with modify other state 2" {
    var buf: [128]u8 = undefined;
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try legacy(&writer, .{
            .key = .escape,
            .mods = .{ .alt = true },
        }, .{});
        try testing.expectEqualStrings("\x1b\x1b", writer.buffered());
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try legacy(&writer, .{
            .key = .escape,
            .mods = .{ .alt = true },
        }, .{ .modify_other_keys_state_2 = true });
        try testing.expectEqualStrings("\x1b[27;3;27~", writer.buffered());
    }
}
test "legacy: ctrl+shift+minus (underscore on US)" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .minus,
        .mods = .{ .ctrl = true, .shift = true },
        .utf8 = "_",
    }, .{});
    try testing.expectEqualStrings("\x1F", writer.buffered());
}
test "legacy: ctrl+alt+c" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .key_c,
        .mods = .{ .ctrl = true, .alt = true },
        .utf8 = "c",
    }, .{});
    try testing.expectEqualStrings("\x1b\x03", writer.buffered());
}
test "legacy: alt+c" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .key_c,
        .utf8 = "c",
        .mods = .{ .alt = true },
    }, .{
        .alt_esc_prefix = true,
        .macos_option_as_alt = .true,
    });
    try testing.expectEqualStrings("\x1Bc", writer.buffered());
}
test "legacy: alt+e only unshifted" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .key_e,
        .unshifted_codepoint = 'e',
        .mods = .{ .alt = true },
    }, .{
        .alt_esc_prefix = true,
        .macos_option_as_alt = .true,
    });
    try testing.expectEqualStrings("\x1Be", writer.buffered());
}
test "legacy: alt+unicode" {
    const Case = struct {
        text: []const u8,
        codepoint: u21,
        expected: []const u8,
    };
    const cases = [_]Case{
        .{ .text = "é", .codepoint = 'é', .expected = "\x1B" ++ "é" },
        .{ .text = "ő", .codepoint = 'ő', .expected = "\x1B" ++ "ő" },
        .{ .text = "界", .codepoint = '界', .expected = "\x1B" ++ "界" },
        .{ .text = "😀", .codepoint = '😀', .expected = "\x1B" ++ "😀" },
    };
    for (cases) |case| {
        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try legacy(&writer, .{
            .key = .unidentified,
            .utf8 = case.text,
            .unshifted_codepoint = case.codepoint,
            .mods = .{ .alt = true },
        }, .{
            .alt_esc_prefix = true,
            .macos_option_as_alt = .true,
        });
        try testing.expectEqualStrings(case.expected, writer.buffered());
    }
}
test "legacy: alt+unicode only unshifted" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .unidentified,
        .unshifted_codepoint = '界',
        .mods = .{ .alt = true },
    }, .{
        .alt_esc_prefix = true,
        .macos_option_as_alt = .true,
    });
    try testing.expectEqualStrings("\x1B" ++ "界", writer.buffered());
}
test "legacy: alt+unicode without unshifted" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .unidentified,
        .utf8 = "😀",
        .mods = .{ .alt = true },
    }, .{
        .alt_esc_prefix = true,
        .macos_option_as_alt = .true,
    });
    try testing.expectEqualStrings("\x1B" ++ "😀", writer.buffered());
}
test "legacy: alt+x macos" {
    if (comptime !builtin.target.os.tag.isDarwin()) return error.SkipZigTest;
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .key_c,
        .utf8 = "≈",
        .unshifted_codepoint = 'c',
        .mods = .{ .alt = true },
    }, .{
        .alt_esc_prefix = true,
        .macos_option_as_alt = .true,
    });
    try testing.expectEqualStrings("\x1Bc", writer.buffered());
}
test "legacy: shift+alt+. macos" {
    if (comptime !builtin.target.os.tag.isDarwin()) return error.SkipZigTest;
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .period,
        .utf8 = ">",
        .unshifted_codepoint = '.',
        .mods = .{ .alt = true, .shift = true },
    }, .{
        .alt_esc_prefix = true,
        .macos_option_as_alt = .true,
    });
    try testing.expectEqualStrings("\x1B>", writer.buffered());
}
test "legacy: alt+ф" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .key_f,
        .utf8 = "ф",
        .mods = .{ .alt = true },
    }, .{
        .alt_esc_prefix = true,
        .macos_option_as_alt = .true,
    });
    try testing.expectEqualStrings("\x1B" ++ "ф", writer.buffered());
}
test "legacy: ctrl+c" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .key_c,
        .mods = .{ .ctrl = true },
        .utf8 = "c",
    }, .{});
    try testing.expectEqualStrings("\x03", writer.buffered());
}
test "legacy: ctrl+space" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .space,
        .mods = .{ .ctrl = true },
        .utf8 = " ",
    }, .{});
    try testing.expectEqualStrings("\x00", writer.buffered());
}
test "legacy: ctrl+shift+backspace" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .backspace,
        .mods = .{ .ctrl = true, .shift = true },
    }, .{});
    try testing.expectEqualStrings("\x08", writer.buffered());
}
test "legacy: ctrl+alt+shift+backspace" {
    const event: key.KeyEvent = .{
        .key = .backspace,
        .mods = .{ .ctrl = true, .alt = true, .shift = true },
    };
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, event, .{});
    try testing.expectEqualStrings("\x1b\x08", writer.buffered());
    writer = .fixed(&buf);
    try legacy(&writer, event, .{ .modify_other_keys_state_2 = true });
    try testing.expectEqualStrings("\x1b[27;8;127~", writer.buffered());
}
test "legacy: backspace (DECBKM reset)" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .backspace,
        .mods = .{},
    }, .{ .backarrow_key_mode = false });
    try testing.expectEqualStrings("\x7f", writer.buffered());
}
test "legacy: backspace (DECBKM reset, with ctrl)" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .backspace,
        .mods = .{
            .ctrl = true,
        },
    }, .{ .backarrow_key_mode = false });
    try testing.expectEqualStrings("\x08", writer.buffered());
}
test "legacy: backspace (DECBKM set)" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .backspace,
        .mods = .{},
    }, .{ .backarrow_key_mode = true });
    try testing.expectEqualStrings("\x08", writer.buffered());
}
test "legacy: backspace (DECBKM set, with ctrl)" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .backspace,
        .mods = .{
            .ctrl = true,
        },
    }, .{ .backarrow_key_mode = true });
    try testing.expectEqualStrings("\x7f", writer.buffered());
}
test "legacy: ctrl+shift+char with modify other state 2" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .key_h,
        .mods = .{ .ctrl = true, .shift = true },
        .utf8 = "H",
    }, .{
        .modify_other_keys_state_2 = true,
    });
    try testing.expectEqualStrings("\x1b[27;6;72~", writer.buffered());
}
test "legacy: ctrl+char with modify other state 2" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .key_p,
        .mods = .{ .ctrl = true },
        .utf8 = "p",
    }, .{
        .modify_other_keys_state_2 = true,
    });
    try testing.expectEqualStrings("\x1b[27;5;112~", writer.buffered());
}
test "legacy: ctrl+char without modify other state 2" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .key_p,
        .mods = .{ .ctrl = true },
        .utf8 = "p",
    }, .{});
    try testing.expectEqualStrings("\x10", writer.buffered());
}
test "legacy: ctrl+shift+char with modify other state 2 and consumed mods" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .key_h,
        .mods = .{ .ctrl = true, .shift = true },
        .consumed_mods = .{ .shift = true },
        .utf8 = "H",
    }, .{
        .modify_other_keys_state_2 = true,
    });
    try testing.expectEqualStrings("\x1b[27;6;72~", writer.buffered());
}
test "legacy: alt+digit with modify other state 2" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .digit_8,
        .mods = .{ .alt = true },
        .consumed_mods = .{},
        .utf8 = "8",
    }, .{
        .modify_other_keys_state_2 = true,
        .macos_option_as_alt = .true,
    });
    try testing.expectEqualStrings("\x1b[27;3;56~", writer.buffered());
}
test "legacy: alt+digit with modify other state 2 and macos-option-as-alt = false" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .digit_8,
        .mods = .{ .alt = true },
        .consumed_mods = .{ .alt = true },
        .utf8 = "[", 
    }, .{
        .modify_other_keys_state_2 = true,
        .macos_option_as_alt = .false,
    });
    try testing.expectEqualStrings("[", writer.buffered());
}
test "legacy: fixterm awkward letters" {
    var buf: [128]u8 = undefined;
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try legacy(&writer, .{
            .key = .key_i,
            .mods = .{ .ctrl = true },
            .utf8 = "i",
        }, .{});
        try testing.expectEqualStrings("\x1b[105;5u", writer.buffered());
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try legacy(&writer, .{
            .key = .key_m,
            .mods = .{ .ctrl = true },
            .utf8 = "m",
        }, .{});
        try testing.expectEqualStrings("\x1b[109;5u", writer.buffered());
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try legacy(&writer, .{
            .key = .bracket_left,
            .mods = .{ .ctrl = true },
            .utf8 = "[",
        }, .{});
        try testing.expectEqualStrings("\x1b[91;5u", writer.buffered());
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try legacy(&writer, .{
            .key = .digit_2,
            .mods = .{ .ctrl = true, .shift = true },
            .utf8 = "@",
            .unshifted_codepoint = '2',
        }, .{});
        try testing.expectEqualStrings("\x1b[64;5u", writer.buffered());
    }
}
test "legacy: ctrl+shift+letter ascii" {
    var buf: [128]u8 = undefined;
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try legacy(&writer, .{
            .key = .key_m,
            .mods = .{ .ctrl = true, .shift = true },
            .utf8 = "M",
            .unshifted_codepoint = 'm',
        }, .{});
        try testing.expectEqualStrings("\x1b[109;6u", writer.buffered());
    }
}
test "legacy: shift+function key should use all mods" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .arrow_up,
        .mods = .{ .shift = true },
        .consumed_mods = .{ .shift = true },
    }, .{});
    try testing.expectEqualStrings("\x1b[1;2A", writer.buffered());
}
test "legacy: keypad enter" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .numpad_enter,
        .mods = .{},
        .consumed_mods = .{},
    }, .{});
    try testing.expectEqualStrings("\r", writer.buffered());
}
test "legacy: keypad 1" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .numpad_1,
        .mods = .{},
        .consumed_mods = .{},
        .utf8 = "1",
    }, .{});
    try testing.expectEqualStrings("1", writer.buffered());
}
test "legacy: keypad 1 with modify other state 2" {
    var buf: [128]u8 = undefined;
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try legacy(&writer, .{
            .key = .numpad_1,
            .mods = .{ .ctrl = true },
            .utf8 = "1",
        }, .{
            .modify_other_keys_state_2 = true,
        });
        try testing.expectEqualStrings("1", writer.buffered());
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try legacy(&writer, .{
            .key = .numpad_1,
            .mods = .{ .ctrl = true },
            .utf8 = "1",
        }, .{
            .keypad_key_application = true,
            .modify_other_keys_state_2 = true,
        });
        try testing.expectEqualStrings("\x1bO5q", writer.buffered());
    }
}
test "legacy: keypad 1 with application keypad" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .numpad_1,
        .mods = .{},
        .consumed_mods = .{},
        .utf8 = "1",
    }, .{
        .keypad_key_application = true,
    });
    try testing.expectEqualStrings("\x1bOq", writer.buffered());
}
test "legacy: keypad 1 with application keypad and numlock" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .numpad_1,
        .mods = .{ .num_lock = true },
        .consumed_mods = .{},
        .utf8 = "1",
    }, .{
        .keypad_key_application = true,
    });
    try testing.expectEqualStrings("\x1bOq", writer.buffered());
}
test "legacy: keypad 1 with application keypad and numlock ignore" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .numpad_1,
        .mods = .{ .num_lock = false },
        .consumed_mods = .{},
        .utf8 = "1",
    }, .{
        .keypad_key_application = true,
        .ignore_keypad_with_numlock = true,
    });
    try testing.expectEqualStrings("1", writer.buffered());
}
test "legacy: f1" {
    var buf: [128]u8 = undefined;
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try legacy(&writer, .{
            .key = .f1,
            .mods = .{ .ctrl = true },
            .consumed_mods = .{},
        }, .{});
        try testing.expectEqualStrings("\x1b[1;5P", writer.buffered());
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try legacy(&writer, .{
            .key = .f2,
            .mods = .{ .ctrl = true },
            .consumed_mods = .{},
        }, .{});
        try testing.expectEqualStrings("\x1b[1;5Q", writer.buffered());
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try legacy(&writer, .{
            .key = .f3,
            .mods = .{ .ctrl = true },
            .consumed_mods = .{},
        }, .{});
        try testing.expectEqualStrings("\x1b[13;5~", writer.buffered());
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try legacy(&writer, .{
            .key = .f4,
            .mods = .{ .ctrl = true },
            .consumed_mods = .{},
        }, .{});
        try testing.expectEqualStrings("\x1b[1;5S", writer.buffered());
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try legacy(&writer, .{
            .key = .f5,
            .mods = .{ .ctrl = true },
            .consumed_mods = .{},
        }, .{});
        try testing.expectEqualStrings("\x1b[15;5~", writer.buffered());
    }
}
test "legacy: f13 through f25" {
    const Case = struct { key: key.Key, code: u8 };
    const cases = [_]Case{
        .{ .key = .f13, .code = 25 },
        .{ .key = .f14, .code = 26 },
        .{ .key = .f15, .code = 28 },
        .{ .key = .f16, .code = 29 },
        .{ .key = .f17, .code = 31 },
        .{ .key = .f18, .code = 32 },
        .{ .key = .f19, .code = 33 },
        .{ .key = .f20, .code = 34 },
        .{ .key = .f21, .code = 42 },
        .{ .key = .f22, .code = 43 },
        .{ .key = .f23, .code = 44 },
        .{ .key = .f24, .code = 45 },
        .{ .key = .f25, .code = 46 },
    };
    var buf: [128]u8 = undefined;
    var expected_buf: [32]u8 = undefined;
    for (cases) |case| {
        {
            var writer: std.Io.Writer = .fixed(&buf);
            try legacy(&writer, .{ .key = case.key }, .{});
            const expected = try std.fmt.bufPrint(
                &expected_buf,
                "\x1b[{}~",
                .{case.code},
            );
            try testing.expectEqualStrings(expected, writer.buffered());
        }
        {
            var writer: std.Io.Writer = .fixed(&buf);
            try legacy(&writer, .{
                .key = case.key,
                .mods = .{ .ctrl = true },
            }, .{ .modify_other_keys_state_2 = true });
            const expected = try std.fmt.bufPrint(
                &expected_buf,
                "\x1b[{};5~",
                .{case.code},
            );
            try testing.expectEqualStrings(expected, writer.buffered());
        }
    }
}
test "legacy: help and context menu" {
    const Case = struct { key: key.Key, code: u8 };
    const cases = [_]Case{
        .{ .key = .help, .code = 28 },
        .{ .key = .context_menu, .code = 29 },
    };
    var buf: [128]u8 = undefined;
    var expected_buf: [32]u8 = undefined;
    for (cases) |case| {
        {
            var writer: std.Io.Writer = .fixed(&buf);
            try legacy(&writer, .{ .key = case.key }, .{});
            const expected = try std.fmt.bufPrint(
                &expected_buf,
                "\x1b[{}~",
                .{case.code},
            );
            try testing.expectEqualStrings(expected, writer.buffered());
        }
        {
            var writer: std.Io.Writer = .fixed(&buf);
            try legacy(&writer, .{
                .key = case.key,
                .mods = .{ .ctrl = true },
            }, .{ .modify_other_keys_state_2 = true });
            const expected = try std.fmt.bufPrint(
                &expected_buf,
                "\x1b[{};5~",
                .{case.code},
            );
            try testing.expectEqualStrings(expected, writer.buffered());
        }
    }
}
test "legacy: left_shift+tab" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .tab,
        .mods = .{
            .shift = true,
            .sides = .{ .shift = .left },
        },
    }, .{});
    try testing.expectEqualStrings("\x1b[Z", writer.buffered());
}
test "legacy: right_shift+tab" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .tab,
        .mods = .{
            .shift = true,
            .sides = .{ .shift = .right },
        },
    }, .{});
    try testing.expectEqualStrings("\x1b[Z", writer.buffered());
}
test "legacy: hu layout ctrl+ő sends proper codepoint" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .bracket_left,
        .mods = .{ .ctrl = true },
        .utf8 = "ő",
        .unshifted_codepoint = 337,
    }, .{});
    const actual = writer.buffered();
    try testing.expectEqualStrings("[337;5u", actual[1..]);
}
test "legacy: super-only on macOS with text" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .key_b,
        .utf8 = "b",
        .mods = .{ .super = true },
    }, .{});
    try testing.expectEqualStrings("", writer.buffered());
}
test "legacy: super and other mods on macOS with text" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .key_b,
        .utf8 = "B",
        .mods = .{ .super = true, .shift = true },
    }, .{});
    try testing.expectEqualStrings("", writer.buffered());
}
test "legacy: backspace with DEL utf8 (DECBKM reset)" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .backspace,
        .utf8 = &.{0x7F},
        .unshifted_codepoint = 0x08,
    }, .{ .backarrow_key_mode = false });
    try testing.expectEqualStrings("\x7F", writer.buffered());
}
test "legacy: backspace with DEL utf8 (DECBKM set)" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try legacy(&writer, .{
        .key = .backspace,
        .utf8 = &.{0x7F},
        .unshifted_codepoint = 0x08,
    }, .{ .backarrow_key_mode = true });
    try testing.expectEqualStrings("\x08", writer.buffered());
}
test "ctrlseq: normal ctrl c" {
    const seq = ctrlSeq(.unidentified, "c", 'c', .{ .ctrl = true });
    try testing.expectEqual(@as(u8, 0x03), seq.?);
}
test "ctrlseq: normal ctrl c, right control" {
    const seq = ctrlSeq(.unidentified, "c", 'c', .{ .ctrl = true, .sides = .{ .ctrl = .right } });
    try testing.expectEqual(@as(u8, 0x03), seq.?);
}
test "ctrlseq: alt should be allowed" {
    const seq = ctrlSeq(.unidentified, "c", 'c', .{ .alt = true, .ctrl = true });
    try testing.expectEqual(@as(u8, 0x03), seq.?);
}
test "ctrlseq: no ctrl does nothing" {
    try testing.expect(ctrlSeq(.unidentified, "c", 'c', .{}) == null);
}
test "ctrlseq: shifted non-character" {
    const seq = ctrlSeq(.unidentified, "_", '-', .{ .ctrl = true, .shift = true });
    try testing.expectEqual(@as(u8, 0x1F), seq.?);
}
test "ctrlseq: caps ascii letter" {
    const seq = ctrlSeq(.unidentified, "C", 'c', .{ .ctrl = true, .caps_lock = true });
    try testing.expectEqual(@as(u8, 0x03), seq.?);
}
test "ctrlseq: shift does not generate ctrl seq" {
    try testing.expect(ctrlSeq(.unidentified, "C", 'c', .{ .shift = true }) == null);
    try testing.expect(ctrlSeq(.unidentified, "C", 'c', .{ .shift = true, .ctrl = true }) == null);
}
test "ctrlseq: russian ctrl c" {
    const seq = ctrlSeq(.key_c, "с", 0x0441, .{ .ctrl = true });
    try testing.expectEqual(@as(u8, 0x03), seq.?);
}
test "ctrlseq: russian shifted ctrl c" {
    const seq = ctrlSeq(.key_c, "с", 0x0441, .{ .ctrl = true, .shift = true });
    try testing.expect(seq == null);
}
test "ctrlseq: russian alt ctrl c" {
    const seq = ctrlSeq(.key_c, "с", 0x0441, .{ .ctrl = true, .alt = true });
    try testing.expectEqual(@as(u8, 0x03), seq.?);
}
test "ctrlseq: right ctrl c" {
    const seq = ctrlSeq(.key_c, "с", 'c', .{
        .ctrl = true,
        .sides = .{ .ctrl = .right },
    });
    try testing.expectEqual(@as(u8, 0x03), seq.?);
}
