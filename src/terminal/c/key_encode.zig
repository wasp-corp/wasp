const std = @import("std");
const Allocator = std.mem.Allocator;
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
const key_encode = @import("../../input/key_encode.zig");
const key_event = @import("key_event.zig");
const KittyFlags = @import("../../terminal/kitty/key.zig").Flags;
const OptionAsAlt = @import("../../input/config.zig").OptionAsAlt;
const Result = @import("result.zig").Result;
const KeyEvent = @import("key_event.zig").Event;
const Terminal = @import("terminal.zig").Terminal;
const ZigTerminal = @import("../Terminal.zig");
const log = std.log.scoped(.key_encode);
const KeyEncoderWrapper = struct {
    opts: key_encode.Options,
    alloc: Allocator,
};
pub const Encoder = ?*KeyEncoderWrapper;
pub fn new(
    alloc_: ?*const CAllocator,
    result: *Encoder,
) callconv(lib.calling_conv) Result {
    const alloc = lib.alloc.default(alloc_);
    const ptr = alloc.create(KeyEncoderWrapper) catch
        return .out_of_memory;
    ptr.* = .{
        .opts = .{},
        .alloc = alloc,
    };
    result.* = ptr;
    return .success;
}
pub fn free(encoder_: Encoder) callconv(lib.calling_conv) void {
    const wrapper = encoder_ orelse return;
    const alloc = wrapper.alloc;
    alloc.destroy(wrapper);
}
pub const Option = enum(c_int) {
    cursor_key_application = 0,
    keypad_key_application = 1,
    ignore_keypad_with_numlock = 2,
    alt_esc_prefix = 3,
    modify_other_keys_state_2 = 4,
    kitty_flags = 5,
    macos_option_as_alt = 6,
    backarrow_key_mode = 7,
    pub fn InType(comptime self: Option) type {
        return switch (self) {
            .cursor_key_application,
            .keypad_key_application,
            .ignore_keypad_with_numlock,
            .alt_esc_prefix,
            .modify_other_keys_state_2,
            .backarrow_key_mode,
            => bool,
            .kitty_flags => u8,
            .macos_option_as_alt => OptionAsAlt,
        };
    }
};
pub fn setopt(
    encoder_: Encoder,
    option: Option,
    value: ?*const anyopaque,
) callconv(lib.calling_conv) void {
    if (comptime std.debug.runtime_safety) {
        _ = std.enums.fromInt(Option, @intFromEnum(option)) orelse {
            log.warn("setopt invalid option value={d}", .{@intFromEnum(option)});
            return;
        };
    }
    return switch (option) {
        inline else => |comptime_option| setoptTyped(
            encoder_,
            comptime_option,
            @ptrCast(@alignCast(value orelse return)),
        ),
    };
}
fn setoptTyped(
    encoder_: Encoder,
    comptime option: Option,
    value: *const option.InType(),
) void {
    const opts = &encoder_.?.opts;
    switch (option) {
        .cursor_key_application => opts.cursor_key_application = value.*,
        .keypad_key_application => opts.keypad_key_application = value.*,
        .ignore_keypad_with_numlock => opts.ignore_keypad_with_numlock = value.*,
        .alt_esc_prefix => opts.alt_esc_prefix = value.*,
        .modify_other_keys_state_2 => opts.modify_other_keys_state_2 = value.*,
        .kitty_flags => opts.kitty_flags = flags: {
            const bits: u5 = @truncate(value.*);
            break :flags @bitCast(bits);
        },
        .macos_option_as_alt => {
            if (comptime std.debug.runtime_safety) {
                _ = std.enums.fromInt(OptionAsAlt, @intFromEnum(value.*)) orelse {
                    log.warn("setopt invalid OptionAsAlt value={d}", .{@intFromEnum(value.*)});
                    return;
                };
            }
            opts.macos_option_as_alt = value.*;
        },
        .backarrow_key_mode => opts.backarrow_key_mode = value.*,
    }
}
pub fn setopt_from_terminal(
    encoder_: Encoder,
    terminal_: Terminal,
) callconv(lib.calling_conv) void {
    const wrapper = encoder_ orelse return;
    const t: *ZigTerminal = (terminal_ orelse return).terminal;
    wrapper.opts = .fromTerminal(t);
}
pub fn encode(
    encoder_: Encoder,
    event_: KeyEvent,
    out_: ?[*]u8,
    out_len: usize,
    out_written: *usize,
) callconv(lib.calling_conv) Result {
    var writer: std.Io.Writer = .fixed(if (out_) |out| out[0..out_len] else &.{});
    key_encode.encode(
        &writer,
        event_.?.event,
        encoder_.?.opts,
    ) catch |err| switch (err) {
        error.WriteFailed => {
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            key_encode.encode(
                &discarding.writer,
                event_.?.event,
                encoder_.?.opts,
            ) catch unreachable;
            out_written.* = @intCast(discarding.count);
            return .out_of_space;
        },
    };
    out_written.* = writer.end;
    return .success;
}
test "alloc" {
    const testing = std.testing;
    var e: Encoder = undefined;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &e,
    ));
    free(e);
}
test "setopt bool" {
    const testing = std.testing;
    var e: Encoder = undefined;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &e,
    ));
    defer free(e);
    const val_true: bool = true;
    setopt(e, .cursor_key_application, &val_true);
    try testing.expect(e.?.opts.cursor_key_application);
    const val_false: bool = false;
    setopt(e, .cursor_key_application, &val_false);
    try testing.expect(!e.?.opts.cursor_key_application);
    setopt(e, .keypad_key_application, &val_true);
    try testing.expect(e.?.opts.keypad_key_application);
}
test "setopt kitty flags" {
    const testing = std.testing;
    var e: Encoder = undefined;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &e,
    ));
    defer free(e);
    const flags: KittyFlags = .{
        .disambiguate = true,
        .report_events = true,
    };
    const flags_int: u8 = @intCast(flags.int());
    setopt(e, .kitty_flags, &flags_int);
    try testing.expect(e.?.opts.kitty_flags.disambiguate);
    try testing.expect(e.?.opts.kitty_flags.report_events);
    try testing.expect(!e.?.opts.kitty_flags.report_alternates);
}
test "setopt macos option as alt" {
    const testing = std.testing;
    var e: Encoder = undefined;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &e,
    ));
    defer free(e);
    const opt_left: OptionAsAlt = .left;
    setopt(e, .macos_option_as_alt, &opt_left);
    try testing.expectEqual(OptionAsAlt.left, e.?.opts.macos_option_as_alt);
    const opt_true: OptionAsAlt = .true;
    setopt(e, .macos_option_as_alt, &opt_true);
    try testing.expectEqual(OptionAsAlt.true, e.?.opts.macos_option_as_alt);
}
test "setopt_from_terminal" {
    const testing = std.testing;
    const terminal_c = @import("terminal.zig");
    var e: Encoder = undefined;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &e,
    ));
    defer free(e);
    var t: Terminal = undefined;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);
    setopt_from_terminal(e, t);
    try testing.expect(!e.?.opts.cursor_key_application);
    try testing.expect(e.?.opts.alt_esc_prefix);
    try testing.expectEqual(KittyFlags.disabled, e.?.opts.kitty_flags);
    try testing.expectEqual(OptionAsAlt.false, e.?.opts.macos_option_as_alt);
}
test "setopt_from_terminal null" {
    setopt_from_terminal(null, null);
    const testing = std.testing;
    const terminal_c = @import("terminal.zig");
    var t: Terminal = undefined;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);
    setopt_from_terminal(null, t);
    var e: Encoder = undefined;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &e,
    ));
    defer free(e);
    setopt_from_terminal(e, null);
}
test "encode: kitty ctrl release with ctrl mod set" {
    const testing = std.testing;
    var encoder: Encoder = undefined;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &encoder,
    ));
    defer free(encoder);
    {
        const flags: KittyFlags = .{
            .disambiguate = true,
            .report_events = true,
            .report_alternates = true,
            .report_all = true,
            .report_associated = true,
        };
        const flags_int: u8 = @intCast(flags.int());
        setopt(encoder, .kitty_flags, &flags_int);
    }
    var event: key_event.Event = undefined;
    try testing.expectEqual(Result.success, key_event.new(
        &lib.alloc.test_allocator,
        &event,
    ));
    defer key_event.free(event);
    key_event.set_action(event, .release);
    key_event.set_key(event, .control_left);
    key_event.set_mods(event, .{ .ctrl = true });
    var required: usize = 0;
    try testing.expectEqual(Result.out_of_space, encode(
        encoder,
        event,
        null,
        0,
        &required,
    ));
    var buf: [128]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(Result.success, encode(
        encoder,
        event,
        &buf,
        buf.len,
        &written,
    ));
    try testing.expectEqual(required, written);
    const actual = buf[0..written];
    try testing.expectEqualStrings("\x1b[57442;5:3u", actual);
}
