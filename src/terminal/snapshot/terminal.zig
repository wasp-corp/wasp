const std = @import("std");
const Allocator = std.mem.Allocator;
const test_fixture = @import("fixture.zig");
const io = @import("io.zig");
const record = @import("record.zig");
const terminal_ansi = @import("../ansi.zig");
const terminal_color = @import("../color.zig");
const terminal_modes = @import("../modes.zig");
const terminal_mouse = @import("../mouse.zig");
const terminal_osc = @import("../osc.zig");
const Terminal = @import("../Terminal.zig");
const TerminalScreen = @import("../Screen.zig");
const TerminalScreenKey = @import("../ScreenSet.zig").Key;
const TerminalTabstops = @import("../Tabstops.zig");
const ModeBits = @typeInfo(
    terminal_modes.ModePacked,
).@"struct".backing_integer.?;
pub const RGB = terminal_color.RGB;
pub const DynamicRGB = terminal_color.DynamicRGB;
const ValidationError = error{
    InvalidDimensions,
    InvalidScrollingRegion,
    InvalidScreenCount,
    InvalidActiveScreenKey,
    InvalidPreviousCodepoint,
    InvalidScrollbackLimit,
};
const HeaderInitError = error{
    ScrollbackLimitOverflow,
};
const PayloadEncodeError = std.Io.Writer.Error ||
    ValidationError ||
    error{
        InvalidTabStops,
        InvalidPalette,
        StringTooLong,
    };
const PayloadDecodeError = std.Io.Reader.Error ||
    Allocator.Error ||
    error{
        InvalidDimensions,
        InvalidScreenCount,
    };
pub const Header = struct {
    pub const len = computeLen();
    comptime {
        std.debug.assert(len == 103);
    }
    columns: u16,
    rows: u16,
    width_px: u32,
    height_px: u32,
    scrolling_region_top: u16,
    scrolling_region_bottom: u16,
    scrolling_region_left: u16,
    scrolling_region_right: u16,
    status_display: terminal_ansi.StatusDisplay,
    active_screen_key: TerminalScreenKey,
    screen_count: u16,
    previous_codepoint: ?u21,
    cursor_is_default: bool,
    cursor_default_style: TerminalScreen.CursorStyle,
    cursor_default_blink: ?bool,
    shell_redraw: terminal_osc.semantic_prompt.Redraw,
    modify_other_keys_2: bool,
    mouse_event: terminal_mouse.Event,
    mouse_format: terminal_mouse.Format,
    mouse_shift_capture: ?bool,
    mouse_shape: terminal_mouse.Shape,
    password_input: bool,
    current_modes: terminal_modes.ModePacked,
    saved_modes: terminal_modes.ModePacked,
    default_modes: terminal_modes.ModePacked,
    background: DynamicRGB,
    foreground: DynamicRGB,
    cursor_color: DynamicRGB,
    max_scrollback_bytes: ?u64,
    max_scrollback_rows: ?u64,
    fn init(terminal: *const Terminal) HeaderInitError!Header {
        const primary = terminal.screens.get(.primary).?;
        return .{
            .columns = terminal.cols,
            .rows = terminal.rows,
            .width_px = terminal.width_px,
            .height_px = terminal.height_px,
            .scrolling_region_top = terminal.scrolling_region.top,
            .scrolling_region_bottom = terminal.scrolling_region.bottom,
            .scrolling_region_left = terminal.scrolling_region.left,
            .scrolling_region_right = terminal.scrolling_region.right,
            .status_display = terminal.status_display,
            .active_screen_key = terminal.screens.active_key,
            .screen_count = if (terminal.screens.get(.alternate) == null)
                1
            else
                2,
            .previous_codepoint = terminal.previous_char,
            .cursor_is_default = terminal.cursor.is_default,
            .cursor_default_style = terminal.cursor.default_style,
            .cursor_default_blink = terminal.cursor.default_blink,
            .shell_redraw = terminal.flags.shell_redraws_prompt,
            .modify_other_keys_2 = terminal.flags.modify_other_keys_2,
            .mouse_event = terminal.flags.mouse_event,
            .mouse_format = terminal.flags.mouse_format,
            .mouse_shift_capture = switch (terminal.flags.mouse_shift_capture) {
                .null => null,
                .false => false,
                .true => true,
            },
            .mouse_shape = terminal.mouse_shape,
            .password_input = terminal.flags.password_input,
            .current_modes = terminal.modes.values,
            .saved_modes = terminal.modes.saved,
            .default_modes = terminal.modes.default,
            .background = terminal.colors.background,
            .foreground = terminal.colors.foreground,
            .cursor_color = terminal.colors.cursor,
            .max_scrollback_bytes = try encodeScrollbackLimit(
                primary.pages.limits.bytes.explicit,
            ),
            .max_scrollback_rows = try encodeScrollbackLimit(
                primary.pages.limits.lines.explicit,
            ),
        };
    }
    pub fn encode(
        self: Header,
        writer: *std.Io.Writer,
    ) PayloadEncodeError!void {
        try self.validate();
        try io.writeInt(writer, u16, self.columns);
        try io.writeInt(writer, u16, self.rows);
        try io.writeInt(writer, u32, self.width_px);
        try io.writeInt(writer, u32, self.height_px);
        try io.writeInt(writer, u16, self.scrolling_region_top);
        try io.writeInt(writer, u16, self.scrolling_region_bottom);
        try io.writeInt(writer, u16, self.scrolling_region_left);
        try io.writeInt(writer, u16, self.scrolling_region_right);
        try writer.writeByte(@intCast(@intFromEnum(self.status_display)));
        try io.writeInt(
            writer,
            u16,
            @intCast(@intFromEnum(self.active_screen_key)),
        );
        try io.writeInt(writer, u16, self.screen_count);
        try io.writeInt(
            writer,
            u32,
            if (self.previous_codepoint) |value|
                @intCast(value)
            else
                std.math.maxInt(u32),
        );
        try writer.writeByte(@intFromBool(self.cursor_is_default));
        try writer.writeByte(
            @intCast(@intFromEnum(self.cursor_default_style)),
        );
        try writer.writeByte(encodeOptionalBool(self.cursor_default_blink));
        try writer.writeByte(@intCast(@intFromEnum(self.shell_redraw)));
        try writer.writeByte(@intFromBool(self.modify_other_keys_2));
        try writer.writeByte(@intCast(@intFromEnum(self.mouse_event)));
        try writer.writeByte(@intCast(@intFromEnum(self.mouse_format)));
        try writer.writeByte(encodeOptionalBool(self.mouse_shift_capture));
        try writer.writeByte(@intCast(@intFromEnum(self.mouse_shape)));
        try writer.writeByte(@intFromBool(self.password_input));
        const mode_values = [_]terminal_modes.ModePacked{
            self.current_modes,
            self.saved_modes,
            self.default_modes,
        };
        for (mode_values) |value| {
            const bits: ModeBits = @bitCast(value);
            try io.writeInt(writer, u64, @intCast(bits));
        }
        try encodeDynamicRGB(self.background, writer);
        try encodeDynamicRGB(self.foreground, writer);
        try encodeDynamicRGB(self.cursor_color, writer);
        try io.writeInt(
            writer,
            u64,
            self.max_scrollback_bytes orelse std.math.maxInt(u64),
        );
        try io.writeInt(
            writer,
            u64,
            self.max_scrollback_rows orelse std.math.maxInt(u64),
        );
    }
    pub fn decode(reader: *std.Io.Reader) PayloadDecodeError!Header {
        const columns = try io.readInt(reader, u16);
        const rows = try io.readInt(reader, u16);
        const width_px = try io.readInt(reader, u32);
        const height_px = try io.readInt(reader, u32);
        const scrolling_region_top = try io.readInt(reader, u16);
        const scrolling_region_bottom = try io.readInt(reader, u16);
        const scrolling_region_left = try io.readInt(reader, u16);
        const scrolling_region_right = try io.readInt(reader, u16);
        const status_display = enumFromInt(
            terminal_ansi.StatusDisplay,
            try reader.takeByte(),
        ) orelse .main;
        const active_screen_key_raw = try io.readInt(reader, u16);
        const screen_count = try io.readInt(reader, u16);
        const previous_raw = try io.readInt(reader, u32);
        const previous_codepoint: ?u21 = previous: {
            if (previous_raw == std.math.maxInt(u32)) break :previous null;
            const value = std.math.cast(u21, previous_raw) orelse
                break :previous null;
            if (value > 0x10FFFF or
                (value >= 0xD800 and value <= 0xDFFF))
            {
                break :previous null;
            }
            break :previous value;
        };
        const cursor_is_default = switch (try reader.takeByte()) {
            0 => false,
            1 => true,
            else => true,
        };
        const cursor_default_style = enumFromInt(
            TerminalScreen.CursorStyle,
            try reader.takeByte(),
        ) orelse .block;
        const cursor_default_blink: ?bool = switch (try reader.takeByte()) {
            0 => null,
            1 => false,
            2 => true,
            else => null,
        };
        const shell_redraw = enumFromInt(
            terminal_osc.semantic_prompt.Redraw,
            try reader.takeByte(),
        ) orelse .true;
        const modify_other_keys_2 = switch (try reader.takeByte()) {
            0 => false,
            1 => true,
            else => false,
        };
        const mouse_event = enumFromInt(
            terminal_mouse.Event,
            try reader.takeByte(),
        ) orelse .none;
        const mouse_format = enumFromInt(
            terminal_mouse.Format,
            try reader.takeByte(),
        ) orelse .x10;
        const mouse_shift_capture: ?bool = switch (try reader.takeByte()) {
            0 => null,
            1 => false,
            2 => true,
            else => null,
        };
        const mouse_shape = enumFromInt(
            terminal_mouse.Shape,
            try reader.takeByte(),
        ) orelse .text;
        const password_input = switch (try reader.takeByte()) {
            0 => false,
            1 => true,
            else => false,
        };
        var mode_values: [3]terminal_modes.ModePacked = undefined;
        for (&mode_values) |*value| {
            const raw = try io.readInt(reader, u64);
            const bits: ModeBits = @truncate(raw);
            value.* = @bitCast(bits);
        }
        const background = try decodeDynamicRGB(reader);
        const foreground = try decodeDynamicRGB(reader);
        const cursor_color = try decodeDynamicRGB(reader);
        const max_scrollback_bytes = decodeOptionalLimit(
            try io.readInt(reader, u64),
        );
        const max_scrollback_rows = decodeOptionalLimit(
            try io.readInt(reader, u64),
        );
        if (columns == 0 or rows == 0) return error.InvalidDimensions;
        if (screen_count != 1 and screen_count != 2) {
            return error.InvalidScreenCount;
        }
        const scrolling_region_vertical_valid =
            scrolling_region_top <= scrolling_region_bottom and
            scrolling_region_bottom < rows;
        const scrolling_region_horizontal_valid =
            scrolling_region_left <= scrolling_region_right and
            scrolling_region_right < columns;
        const active_screen_key: TerminalScreenKey = active: {
            const decoded = enumFromInt(
                TerminalScreenKey,
                active_screen_key_raw,
            ) orelse break :active .primary;
            if (decoded == .alternate and screen_count != 2) {
                break :active .primary;
            }
            break :active decoded;
        };
        const result: Header = .{
            .columns = columns,
            .rows = rows,
            .width_px = width_px,
            .height_px = height_px,
            .scrolling_region_top = if (scrolling_region_vertical_valid)
                scrolling_region_top
            else
                0,
            .scrolling_region_bottom = if (scrolling_region_vertical_valid)
                scrolling_region_bottom
            else
                rows - 1,
            .scrolling_region_left = if (scrolling_region_horizontal_valid)
                scrolling_region_left
            else
                0,
            .scrolling_region_right = if (scrolling_region_horizontal_valid)
                scrolling_region_right
            else
                columns - 1,
            .status_display = status_display,
            .active_screen_key = active_screen_key,
            .screen_count = screen_count,
            .previous_codepoint = previous_codepoint,
            .cursor_is_default = cursor_is_default,
            .cursor_default_style = cursor_default_style,
            .cursor_default_blink = cursor_default_blink,
            .shell_redraw = shell_redraw,
            .modify_other_keys_2 = modify_other_keys_2,
            .mouse_event = mouse_event,
            .mouse_format = mouse_format,
            .mouse_shift_capture = mouse_shift_capture,
            .mouse_shape = mouse_shape,
            .password_input = password_input,
            .current_modes = mode_values[0],
            .saved_modes = mode_values[1],
            .default_modes = mode_values[2],
            .background = background,
            .foreground = foreground,
            .cursor_color = cursor_color,
            .max_scrollback_bytes = max_scrollback_bytes,
            .max_scrollback_rows = max_scrollback_rows,
        };
        return result;
    }
    fn validate(self: Header) ValidationError!void {
        if (self.columns == 0 or self.rows == 0) {
            return error.InvalidDimensions;
        }
        if (self.scrolling_region_top > self.scrolling_region_bottom or
            self.scrolling_region_bottom >= self.rows or
            self.scrolling_region_left > self.scrolling_region_right or
            self.scrolling_region_right >= self.columns)
        {
            return error.InvalidScrollingRegion;
        }
        if (self.screen_count != 1 and self.screen_count != 2) {
            return error.InvalidScreenCount;
        }
        if (self.active_screen_key == .alternate and self.screen_count != 2) {
            return error.InvalidActiveScreenKey;
        }
        if (self.previous_codepoint) |value| {
            if (value > 0x10FFFF or
                (value >= 0xD800 and value <= 0xDFFF))
            {
                return error.InvalidPreviousCodepoint;
            }
        }
        if (self.max_scrollback_bytes == std.math.maxInt(u64) or
            self.max_scrollback_rows == std.math.maxInt(u64))
        {
            return error.InvalidScrollbackLimit;
        }
    }
    fn computeLen() usize {
        comptime {
            var buf: [128]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buf);
            const value: Header = .{
                .columns = 1,
                .rows = 1,
                .width_px = 0,
                .height_px = 0,
                .scrolling_region_top = 0,
                .scrolling_region_bottom = 0,
                .scrolling_region_left = 0,
                .scrolling_region_right = 0,
                .status_display = .main,
                .active_screen_key = .primary,
                .screen_count = 1,
                .previous_codepoint = null,
                .cursor_is_default = true,
                .cursor_default_style = .block,
                .cursor_default_blink = null,
                .shell_redraw = .true,
                .modify_other_keys_2 = false,
                .mouse_event = .none,
                .mouse_format = .x10,
                .mouse_shift_capture = null,
                .mouse_shape = .text,
                .password_input = false,
                .current_modes = .{},
                .saved_modes = .{},
                .default_modes = .{},
                .background = .unset,
                .foreground = .unset,
                .cursor_color = .unset,
                .max_scrollback_bytes = null,
                .max_scrollback_rows = null,
            };
            value.encode(&writer) catch unreachable;
            return writer.end;
        }
    }
};
const DecodedPayload = struct {
    header: Header,
    tabstops: TerminalTabstops,
    palette: terminal_color.DynamicPalette,
    pwd: []u8,
    title: []u8,
    fn deinit(self: *DecodedPayload, alloc: Allocator) void {
        self.tabstops.deinit(alloc);
        self.palette.deinit(alloc);
        alloc.free(self.pwd);
        alloc.free(self.title);
        self.* = undefined;
    }
};
fn encodePayload(
    header: Header,
    tabstops: *const TerminalTabstops,
    palette: *const terminal_color.DynamicPalette,
    pwd: []const u8,
    title: []const u8,
    writer: *std.Io.Writer,
) PayloadEncodeError!void {
    try header.validate();
    if (tabstops.cols != @as(usize, header.columns)) {
        return error.InvalidTabStops;
    }
    if (pwd.len > std.math.maxInt(u32) or
        title.len > std.math.maxInt(u32))
    {
        return error.StringTooLong;
    }
    for (palette.original, palette.current, 0..) |original, current, index| {
        if (!palette.mask.isSet(index) and !original.eql(current)) {
            return error.InvalidPalette;
        }
    }
    try header.encode(writer);
    const tabstop_len = (@as(usize, header.columns) + 7) / 8;
    for (0..tabstop_len) |byte_index| {
        var raw: u8 = 0;
        for (0..8) |bit| {
            const column = byte_index * 8 + bit;
            if (column >= header.columns) break;
            if (tabstops.get(column)) {
                raw |= @as(u8, 1) << @intCast(bit);
            }
        }
        try writer.writeByte(raw);
    }
    for (palette.original) |value| try encodeRGB(value, writer);
    for (0..32) |byte_index| {
        var raw: u8 = 0;
        for (0..8) |bit| {
            if (palette.mask.isSet(byte_index * 8 + bit)) {
                raw |= @as(u8, 1) << @intCast(bit);
            }
        }
        try writer.writeByte(raw);
    }
    for (palette.current, 0..) |value, index| {
        if (palette.mask.isSet(index)) try encodeRGB(value, writer);
    }
    try io.writeInt(writer, u32, @intCast(pwd.len));
    try writer.writeAll(pwd);
    try io.writeInt(writer, u32, @intCast(title.len));
    try writer.writeAll(title);
}
fn decodePayload(
    reader: *std.Io.Reader,
    alloc: Allocator,
) PayloadDecodeError!DecodedPayload {
    const header = try Header.decode(reader);
    var tabstops = try TerminalTabstops.init(alloc, header.columns, 0);
    errdefer tabstops.deinit(alloc);
    const tabstop_len = (@as(usize, header.columns) + 7) / 8;
    for (0..tabstop_len) |byte_index| {
        const raw = try reader.takeByte();
        for (0..8) |bit| {
            const mask = @as(u8, 1) << @intCast(bit);
            const column = byte_index * 8 + bit;
            if (column < header.columns and raw & mask != 0) {
                tabstops.set(column);
            }
        }
    }
    var original: terminal_color.Palette = undefined;
    for (&original) |*value| value.* = try decodeRGB(reader);
    var override_mask: [32]u8 = undefined;
    try reader.readSliceAll(&override_mask);
    var palette: terminal_color.DynamicPalette = try .init(alloc, original);
    errdefer palette.deinit(alloc);
    for (0..256) |index| {
        const mask = @as(u8, 1) << @intCast(index % 8);
        if (override_mask[index / 8] & mask != 0) {
            palette.set(@intCast(index), try decodeRGB(reader));
        }
    }
    const pwd_len: usize = @intCast(try io.readInt(reader, u32));
    const pwd = try alloc.alloc(u8, pwd_len);
    errdefer alloc.free(pwd);
    try reader.readSliceAll(pwd);
    const title_len: usize = @intCast(try io.readInt(reader, u32));
    const title = try alloc.alloc(u8, title_len);
    errdefer alloc.free(title);
    try reader.readSliceAll(title);
    return .{
        .header = header,
        .tabstops = tabstops,
        .palette = palette,
        .pwd = pwd,
        .title = title,
    };
}
pub const EncodeError = HeaderInitError ||
    PayloadEncodeError ||
    record.Writer.FinishError;
pub fn encode(
    terminal: *const Terminal,
    destination: *record.Writer,
) EncodeError!void {
    const header = try Header.init(terminal);
    const payload = destination.begin(.terminal);
    errdefer destination.cancel();
    try encodePayload(
        header,
        &terminal.tabstops,
        &terminal.colors.palette,
        terminal.getPwd() orelse "",
        terminal.getTitle() orelse "",
        payload,
    );
    try destination.finish();
}
pub const DecodeError = PayloadDecodeError ||
    record.Reader.InitError ||
    record.Reader.FinishError ||
    error{
        UnexpectedRecordTag,
    };
pub fn decode(
    source: *std.Io.Reader,
    io_: std.Io,
    alloc: Allocator,
) DecodeError!Terminal {
    var payload: DecodedPayload = payload: {
        var record_reader: record.Reader = undefined;
        try record_reader.init(source);
        if (record_reader.header.tag != .terminal) {
            return error.UnexpectedRecordTag;
        }
        var payload = try decodePayload(record_reader.payloadReader(), alloc);
        errdefer payload.deinit(alloc);
        try record_reader.finish();
        break :payload payload;
    };
    defer payload.deinit(alloc);
    const header = payload.header;
    const max_scrollback_bytes = nativeScrollbackLimit(
        header.max_scrollback_bytes,
    );
    const max_scrollback_lines = nativeScrollbackLimit(
        header.max_scrollback_rows,
    );
    var result = try Terminal.init(io_, alloc, .{
        .cols = header.columns,
        .rows = header.rows,
        .max_scrollback_bytes = max_scrollback_bytes,
        .max_scrollback_lines = max_scrollback_lines,
        .colors = .{
            .background = header.background,
            .foreground = header.foreground,
            .cursor = header.cursor_color,
            .palette = payload.palette,
        },
        .default_modes = header.default_modes,
        .default_cursor_style = header.cursor_default_style,
        .default_cursor_blink = header.cursor_default_blink,
    });
    errdefer result.deinit(alloc);
    payload.palette = .default;
    if (header.screen_count == 2) {
        _ = try result.screens.getInit(io_, alloc, .alternate, .{
            .cols = header.columns,
            .rows = header.rows,
            .max_scrollback_bytes = 0,
        });
    }
    result.screens.switchTo(header.active_screen_key);
    result.width_px = header.width_px;
    result.height_px = header.height_px;
    result.scrolling_region = .{
        .top = header.scrolling_region_top,
        .bottom = header.scrolling_region_bottom,
        .left = header.scrolling_region_left,
        .right = header.scrolling_region_right,
    };
    result.status_display = header.status_display;
    result.previous_char = header.previous_codepoint;
    result.cursor = .{
        .is_default = header.cursor_is_default,
        .default_style = header.cursor_default_style,
        .default_blink = header.cursor_default_blink,
    };
    result.modes = .{
        .values = header.current_modes,
        .saved = header.saved_modes,
        .default = header.default_modes,
    };
    result.flags.shell_redraws_prompt = header.shell_redraw;
    result.flags.modify_other_keys_2 = header.modify_other_keys_2;
    result.flags.mouse_event = header.mouse_event;
    result.flags.mouse_format = header.mouse_format;
    result.flags.mouse_shift_capture = if (header.mouse_shift_capture) |value|
        if (value) .true else .false
    else
        .null;
    result.flags.password_input = header.password_input;
    result.mouse_shape = header.mouse_shape;
    try result.setPwd(payload.pwd);
    try result.setTitle(payload.title);
    const initialized_tabstops = result.tabstops;
    result.tabstops = payload.tabstops;
    payload.tabstops = initialized_tabstops;
    result.screens.active.pages.assertIntegrity();
    return result;
}
fn enumFromInt(comptime T: type, raw: anytype) ?T {
    const Tag = @typeInfo(T).@"enum".tag_type;
    const value = std.math.cast(Tag, raw) orelse return null;
    return std.enums.fromInt(T, value);
}
fn encodeOptionalBool(value: ?bool) u8 {
    return if (value) |present|
        if (present) 2 else 1
    else
        0;
}
fn encodeRGB(
    value: RGB,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try writer.writeByte(value.r);
    try writer.writeByte(value.g);
    try writer.writeByte(value.b);
}
fn decodeRGB(reader: *std.Io.Reader) std.Io.Reader.Error!RGB {
    return .{
        .r = try reader.takeByte(),
        .g = try reader.takeByte(),
        .b = try reader.takeByte(),
    };
}
fn encodeDynamicRGB(
    value: DynamicRGB,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    if (value.default) |rgb| {
        try writer.writeByte(1);
        try encodeRGB(rgb, writer);
    } else {
        try writer.writeByte(0);
        try writer.splatByteAll(0, 3);
    }
    if (value.override) |rgb| {
        try writer.writeByte(1);
        try encodeRGB(rgb, writer);
    } else {
        try writer.writeByte(0);
        try writer.splatByteAll(0, 3);
    }
}
fn decodeDynamicRGB(
    reader: *std.Io.Reader,
) std.Io.Reader.Error!DynamicRGB {
    const default_present = try reader.takeByte();
    const default_rgb = try decodeRGB(reader);
    const default: ?RGB = if (default_present == 1) default_rgb else null;
    const override_present = try reader.takeByte();
    const override_rgb = try decodeRGB(reader);
    const override: ?RGB = if (override_present == 1) override_rgb else null;
    return .{ .default = default, .override = override };
}
fn decodeOptionalLimit(raw: u64) ?u64 {
    return if (raw == std.math.maxInt(u64)) null else raw;
}
fn encodeScrollbackLimit(value: usize) HeaderInitError!?u64 {
    if (value == std.math.maxInt(usize)) return null;
    const result = std.math.cast(u64, value) orelse
        return error.ScrollbackLimitOverflow;
    if (result == std.math.maxInt(u64)) {
        return error.ScrollbackLimitOverflow;
    }
    return result;
}
fn nativeScrollbackLimit(
    value: ?u64,
) ?usize {
    const present = value orelse return null;
    return @intCast(@min(
        present,
        @as(u64, std.math.maxInt(usize) - 1),
    ));
}
const test_header: Header = header: {
    var current_modes = std.mem.zeroes(terminal_modes.ModePacked);
    current_modes.disable_keyboard = true;
    var saved_modes = std.mem.zeroes(terminal_modes.ModePacked);
    saved_modes.in_band_size_reports = true;
    var default_modes = current_modes;
    default_modes.in_band_size_reports = true;
    break :header .{
        .columns = 0x0102,
        .rows = 0x0304,
        .width_px = 0x05060708,
        .height_px = 0x090a0b0c,
        .scrolling_region_top = 1,
        .scrolling_region_bottom = 2,
        .scrolling_region_left = 3,
        .scrolling_region_right = 4,
        .status_display = .status_line,
        .active_screen_key = .alternate,
        .screen_count = 2,
        .previous_codepoint = 'A',
        .cursor_is_default = true,
        .cursor_default_style = .block_hollow,
        .cursor_default_blink = true,
        .shell_redraw = .last,
        .modify_other_keys_2 = true,
        .mouse_event = .any,
        .mouse_format = .sgr_pixels,
        .mouse_shift_capture = false,
        .mouse_shape = .zoom_out,
        .password_input = true,
        .current_modes = current_modes,
        .saved_modes = saved_modes,
        .default_modes = default_modes,
        .background = .{
            .default = .{ .r = 1, .g = 2, .b = 3 },
            .override = null,
        },
        .foreground = .{
            .default = null,
            .override = .{ .r = 4, .g = 5, .b = 6 },
        },
        .cursor_color = .{
            .default = .{ .r = 7, .g = 8, .b = 9 },
            .override = .{ .r = 10, .g = 11, .b = 12 },
        },
        .max_scrollback_bytes = null,
        .max_scrollback_rows = 0x0102030405060708,
    };
};
const test_header_fixture = test_fixture.parse(
    @embedFile("testdata/terminal-header-v1.hex"),
);
test "TERMINAL mode bit layout" {
    try std.testing.expectEqual(
        @as(usize, 43),
        @bitSizeOf(terminal_modes.ModePacked),
    );
    var first: terminal_modes.ModePacked = std.mem.zeroes(
        terminal_modes.ModePacked,
    );
    first.disable_keyboard = true;
    try std.testing.expectEqual(
        @as(u43, 1) << 0,
        @as(u43, @bitCast(first)),
    );
    var visibility: terminal_modes.ModePacked = std.mem.zeroes(
        terminal_modes.ModePacked,
    );
    visibility.report_visibility = true;
    try std.testing.expectEqual(
        @as(u43, 1) << 40,
        @as(u43, @bitCast(visibility)),
    );
    var size_reports: terminal_modes.ModePacked = std.mem.zeroes(
        terminal_modes.ModePacked,
    );
    size_reports.in_band_size_reports = true;
    try std.testing.expectEqual(
        @as(u43, 1) << 41,
        @as(u43, @bitCast(size_reports)),
    );
    var last: terminal_modes.ModePacked = std.mem.zeroes(
        terminal_modes.ModePacked,
    );
    last.kitty_paste_events = true;
    try std.testing.expectEqual(
        @as(u43, 1) << 42,
        @as(u43, @bitCast(last)),
    );
}
test "TERMINAL header golden encoding and decoding" {
    const testing = std.testing;
    var encoded: [Header.len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try test_header.encode(&writer);
    try test_fixture.expectEqual(
        .bytes,
        "src/terminal/snapshot/testdata/terminal-header-v1.hex",
        "snapshot_fixture-terminal-header-v1.hex",
        &test_header_fixture,
        writer.buffered(),
    );
    try testing.expectEqual(Header.len, test_header_fixture.len);
    var source: std.Io.Reader = .fixed(&test_header_fixture);
    var buffer: [1]u8 = undefined;
    var limited = source.limited(.unlimited, &buffer);
    try testing.expectEqualDeep(
        test_header,
        try Header.decode(&limited.interface),
    );
    for (0..Header.len) |fixture_len| {
        var truncated: std.Io.Reader = .fixed(
            test_header_fixture[0..fixture_len],
        );
        try testing.expectError(
            error.EndOfStream,
            Header.decode(&truncated),
        );
    }
}
test "TERMINAL header encoding rejects noncanonical values" {
    const testing = std.testing;
    var invalid_header = test_header;
    invalid_header.columns = 0;
    var encoded: [Header.len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try testing.expectError(
        error.InvalidDimensions,
        invalid_header.encode(&writer),
    );
    try testing.expectEqual(@as(usize, 0), writer.end);
    invalid_header = test_header;
    invalid_header.max_scrollback_bytes = std.math.maxInt(u64);
    writer = .fixed(&encoded);
    try testing.expectError(
        error.InvalidScrollbackLimit,
        invalid_header.encode(&writer),
    );
    try testing.expectEqual(@as(usize, 0), writer.end);
}
test "TERMINAL header decoding rejects structural values" {
    const testing = std.testing;
    var invalid_dimensions = test_header_fixture;
    invalid_dimensions[0] = 0;
    invalid_dimensions[1] = 0;
    var dimensions_reader: std.Io.Reader = .fixed(&invalid_dimensions);
    try testing.expectError(
        error.InvalidDimensions,
        Header.decode(&dimensions_reader),
    );
    var invalid_screen_count = test_header_fixture;
    invalid_screen_count[23] = 3;
    var screen_count_reader: std.Io.Reader = .fixed(&invalid_screen_count);
    try testing.expectError(
        error.InvalidScreenCount,
        Header.decode(&screen_count_reader),
    );
}
test "TERMINAL header decoding normalizes semantic values" {
    const testing = std.testing;
    var fixture = test_header_fixture;
    fixture[20] = 2;
    fixture[21] = 2;
    fixture[22] = 0;
    fixture[29] = 2;
    fixture[30] = 4;
    fixture[31] = 3;
    fixture[32] = 3;
    fixture[33] = 2;
    fixture[34] = 5;
    fixture[35] = 5;
    fixture[36] = 3;
    fixture[37] = 34;
    fixture[38] = 2;
    fixture[44] = 4;
    fixture[63] = 2;
    fixture[68] = 1;
    fixture[72] = 0xAA;
    fixture[14] = 0x04;
    fixture[15] = 0x03;
    fixture[25] = 0x00;
    fixture[26] = 0xD8;
    fixture[27] = 0x00;
    fixture[28] = 0x00;
    var reader: std.Io.Reader = .fixed(&fixture);
    const decoded = try Header.decode(&reader);
    try testing.expectEqual(terminal_ansi.StatusDisplay.main, decoded.status_display);
    try testing.expectEqual(TerminalScreenKey.primary, decoded.active_screen_key);
    try testing.expectEqual(@as(u16, 0), decoded.scrolling_region_top);
    try testing.expectEqual(test_header.rows - 1, decoded.scrolling_region_bottom);
    try testing.expectEqual(test_header.scrolling_region_left, decoded.scrolling_region_left);
    try testing.expectEqual(test_header.scrolling_region_right, decoded.scrolling_region_right);
    try testing.expectEqual(null, decoded.previous_codepoint);
    try testing.expect(decoded.cursor_is_default);
    try testing.expectEqual(TerminalScreen.CursorStyle.block, decoded.cursor_default_style);
    try testing.expectEqual(null, decoded.cursor_default_blink);
    try testing.expectEqual(terminal_osc.semantic_prompt.Redraw.true, decoded.shell_redraw);
    try testing.expect(!decoded.modify_other_keys_2);
    try testing.expectEqual(terminal_mouse.Event.none, decoded.mouse_event);
    try testing.expectEqual(terminal_mouse.Format.x10, decoded.mouse_format);
    try testing.expectEqual(null, decoded.mouse_shift_capture);
    try testing.expectEqual(terminal_mouse.Shape.text, decoded.mouse_shape);
    try testing.expect(!decoded.password_input);
    try testing.expect(decoded.current_modes.disable_keyboard);
    try testing.expectEqualDeep(DynamicRGB.unset, decoded.background);
    try testing.expectEqual(null, decoded.foreground.default);
    try testing.expectEqual(
        RGB{ .r = 4, .g = 5, .b = 6 },
        decoded.foreground.override.?,
    );
    var invalid_horizontal = test_header_fixture;
    invalid_horizontal[18] = 0x02;
    invalid_horizontal[19] = 0x01;
    var horizontal_reader: std.Io.Reader = .fixed(&invalid_horizontal);
    const horizontal = try Header.decode(&horizontal_reader);
    try testing.expectEqual(
        test_header.scrolling_region_top,
        horizontal.scrolling_region_top,
    );
    try testing.expectEqual(
        test_header.scrolling_region_bottom,
        horizontal.scrolling_region_bottom,
    );
    try testing.expectEqual(@as(u16, 0), horizontal.scrolling_region_left);
    try testing.expectEqual(
        test_header.columns - 1,
        horizontal.scrolling_region_right,
    );
    var missing_active_screen = test_header_fixture;
    missing_active_screen[23] = 1;
    var active_screen_reader: std.Io.Reader = .fixed(&missing_active_screen);
    try testing.expectEqual(
        TerminalScreenKey.primary,
        (try Header.decode(&active_screen_reader)).active_screen_key,
    );
    const largest_finite = std.math.maxInt(u64) - 1;
    try testing.expectEqual(
        @as(usize, @intCast(@min(
            largest_finite,
            @as(u64, std.math.maxInt(usize) - 1),
        ))),
        nativeScrollbackLimit(largest_finite).?,
    );
}
test "TERMINAL payload round trip" {
    const testing = std.testing;
    var tabstops = try TerminalTabstops.init(
        testing.allocator,
        test_header.columns,
        0,
    );
    defer tabstops.deinit(testing.allocator);
    tabstops.set(0);
    tabstops.set(8);
    tabstops.set(test_header.columns - 1);
    var palette: terminal_color.DynamicPalette = .default;
    palette.set(0, .{ .r = 1, .g = 2, .b = 3 });
    palette.set(255, .{ .r = 4, .g = 5, .b = 6 });
    var destination: std.Io.Writer.Allocating = .init(testing.allocator);
    defer destination.deinit();
    try encodePayload(
        test_header,
        &tabstops,
        &palette,
        "file:///tmp/example",
        "snapshot title",
        &destination.writer,
    );
    const bytes = destination.written();
    const tabstop_len = (@as(usize, test_header.columns) + 7) / 8;
    try testing.expectEqual(@as(u8, 0x01), bytes[Header.len]);
    try testing.expectEqual(@as(u8, 0x01), bytes[Header.len + 1]);
    try testing.expectEqual(
        @as(u8, 0x02),
        bytes[Header.len + tabstop_len - 1],
    );
    const palette_mask_offset = Header.len + tabstop_len + 256 * 3;
    try testing.expectEqual(@as(u8, 0x01), bytes[palette_mask_offset]);
    try testing.expectEqual(
        @as(u8, 0x80),
        bytes[palette_mask_offset + 31],
    );
    var source: std.Io.Reader = .fixed(bytes);
    var buffer: [1]u8 = undefined;
    var limited = source.limited(.unlimited, &buffer);
    var decoded = try decodePayload(
        &limited.interface,
        testing.allocator,
    );
    defer decoded.deinit(testing.allocator);
    try testing.expectEqualDeep(test_header, decoded.header);
    for (0..test_header.columns) |column| {
        try testing.expectEqual(
            tabstops.get(column),
            decoded.tabstops.get(column),
        );
    }
    try testing.expectEqualDeep(palette, decoded.palette);
    try testing.expectEqualStrings("file:///tmp/example", decoded.pwd);
    try testing.expectEqualStrings("snapshot title", decoded.title);
}
test "TERMINAL payload rejects noncanonical state" {
    const testing = std.testing;
    var tabstops = try TerminalTabstops.init(
        testing.allocator,
        test_header.columns - 1,
        0,
    );
    defer tabstops.deinit(testing.allocator);
    var palette: terminal_color.DynamicPalette = .default;
    var encoded: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try testing.expectError(
        error.InvalidTabStops,
        encodePayload(
            test_header,
            &tabstops,
            &palette,
            "",
            "",
            &writer,
        ),
    );
    try testing.expectEqual(@as(usize, 0), writer.end);
    tabstops.cols = test_header.columns;
    palette.current[7] = .{ .r = 1, .g = 2, .b = 3 };
    writer = .fixed(&encoded);
    try testing.expectError(
        error.InvalidPalette,
        encodePayload(
            test_header,
            &tabstops,
            &palette,
            "",
            "",
            &writer,
        ),
    );
    try testing.expectEqual(@as(usize, 0), writer.end);
}
test "TERMINAL payload ignores tab-stop padding" {
    const testing = std.testing;
    var tabstops = try TerminalTabstops.init(
        testing.allocator,
        test_header.columns,
        0,
    );
    defer tabstops.deinit(testing.allocator);
    var palette: terminal_color.DynamicPalette = .default;
    palette.set(1, .{ .r = 1, .g = 2, .b = 3 });
    var destination: std.Io.Writer.Allocating = .init(testing.allocator);
    defer destination.deinit();
    try encodePayload(
        test_header,
        &tabstops,
        &palette,
        "pwd",
        "title",
        &destination.writer,
    );
    const tabstop_len = (@as(usize, test_header.columns) + 7) / 8;
    const last_tabstop = Header.len + tabstop_len - 1;
    const invalid_padding = try testing.allocator.dupe(
        u8,
        destination.written(),
    );
    defer testing.allocator.free(invalid_padding);
    invalid_padding[last_tabstop] |= 1 << 7;
    var padding_reader: std.Io.Reader = .fixed(invalid_padding);
    var decoded = try decodePayload(
        &padding_reader,
        testing.allocator,
    );
    defer decoded.deinit(testing.allocator);
    for (0..test_header.columns) |column| {
        try testing.expectEqual(
            tabstops.get(column),
            decoded.tabstops.get(column),
        );
    }
}
test "TERMINAL record encodes native terminal state" {
    const testing = std.testing;
    var terminal = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 10,
        .rows = 3,
        .max_scrollback_bytes = 12_345,
        .max_scrollback_lines = 67,
    });
    defer terminal.deinit(testing.allocator);
    terminal.width_px = 800;
    terminal.height_px = 600;
    terminal.scrolling_region = .{
        .top = 1,
        .bottom = 2,
        .left = 2,
        .right = 8,
    };
    terminal.status_display = .status_line;
    terminal.previous_char = 'X';
    terminal.cursor = .{
        .is_default = false,
        .default_style = .underline,
        .default_blink = true,
    };
    terminal.flags.shell_redraws_prompt = .last;
    terminal.flags.modify_other_keys_2 = true;
    terminal.flags.mouse_event = .button;
    terminal.flags.mouse_format = .sgr;
    terminal.flags.mouse_shift_capture = .true;
    terminal.flags.password_input = true;
    terminal.mouse_shape = .pointer;
    terminal.modes.values.disable_keyboard = true;
    terminal.modes.saved.in_band_size_reports = true;
    terminal.modes.default.bracketed_paste = true;
    terminal.colors.background = .{
        .default = .{ .r = 1, .g = 2, .b = 3 },
        .override = .{ .r = 4, .g = 5, .b = 6 },
    };
    terminal.colors.palette.set(7, .{ .r = 7, .g = 8, .b = 9 });
    terminal.tabstops.reset(0);
    terminal.tabstops.set(1);
    terminal.tabstops.set(9);
    try terminal.setPwd("file:///tmp/native");
    try terminal.setTitle("native title");
    var destination: std.Io.Writer.Allocating = .init(testing.allocator);
    defer destination.deinit();
    var stream: record.Writer = .init(
        testing.allocator,
        &destination.writer,
    );
    defer stream.deinit();
    try encode(&terminal, &stream);
    var source: std.Io.Reader = .fixed(destination.written());
    var restored = try decode(
        &source,
        testing.io,
        testing.allocator,
    );
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 10), restored.cols);
    try testing.expectEqual(@as(u16, 3), restored.rows);
    try testing.expectEqual(@as(u32, 800), restored.width_px);
    try testing.expectEqual(@as(u32, 600), restored.height_px);
    try testing.expectEqual(terminal.scrolling_region, restored.scrolling_region);
    try testing.expectEqual(terminal.status_display, restored.status_display);
    try testing.expectEqual(.primary, restored.screens.active_key);
    try testing.expect(restored.screens.get(.alternate) == null);
    try testing.expectEqual(@as(?u21, 'X'), restored.previous_char);
    try testing.expectEqualDeep(terminal.cursor, restored.cursor);
    try testing.expectEqual(
        terminal.flags.shell_redraws_prompt,
        restored.flags.shell_redraws_prompt,
    );
    try testing.expectEqual(
        terminal.flags.modify_other_keys_2,
        restored.flags.modify_other_keys_2,
    );
    try testing.expectEqual(
        terminal.flags.mouse_event,
        restored.flags.mouse_event,
    );
    try testing.expectEqual(
        terminal.flags.mouse_format,
        restored.flags.mouse_format,
    );
    try testing.expectEqual(
        terminal.flags.mouse_shift_capture,
        restored.flags.mouse_shift_capture,
    );
    try testing.expectEqual(
        terminal.flags.password_input,
        restored.flags.password_input,
    );
    try testing.expectEqual(terminal.mouse_shape, restored.mouse_shape);
    try testing.expectEqualDeep(terminal.modes, restored.modes);
    try testing.expectEqualDeep(terminal.colors, restored.colors);
    try testing.expectEqual(
        @as(usize, 12_345),
        restored.screens.active.pages.limits.bytes.explicit,
    );
    try testing.expectEqual(
        @as(usize, 67),
        restored.screens.active.pages.limits.lines.explicit,
    );
    try testing.expect(restored.tabstops.get(1));
    try testing.expect(restored.tabstops.get(9));
    try testing.expectEqualStrings(
        "file:///tmp/native",
        restored.getPwd().?,
    );
    try testing.expectEqualStrings("native title", restored.getTitle().?);
}
test "TERMINAL record declares an initialized alternate screen" {
    const testing = std.testing;
    var terminal = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 10,
        .rows = 3,
    });
    defer terminal.deinit(testing.allocator);
    _ = try terminal.switchScreen(.alternate);
    var destination: std.Io.Writer.Allocating = .init(testing.allocator);
    defer destination.deinit();
    var stream: record.Writer = .init(
        testing.allocator,
        &destination.writer,
    );
    defer stream.deinit();
    try encode(&terminal, &stream);
    var source: std.Io.Reader = .fixed(destination.written());
    var restored = try decode(
        &source,
        testing.io,
        testing.allocator,
    );
    defer restored.deinit(testing.allocator);
    const primary = restored.screens.get(.primary).?;
    const alternate = restored.screens.get(.alternate).?;
    try testing.expectEqual(.alternate, restored.screens.active_key);
    try testing.expectEqual(alternate, restored.screens.active);
    try testing.expect(primary != alternate);
    try testing.expectEqual(@as(u16, 10), alternate.pages.cols);
    try testing.expectEqual(@as(u16, 3), alternate.pages.rows);
    try testing.expectEqual(
        @as(usize, 0),
        alternate.pages.limits.bytes.explicit,
    );
}
test "TERMINAL payload failure emits no incomplete record" {
    const testing = std.testing;
    var terminal = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 10,
        .rows = 3,
    });
    defer terminal.deinit(testing.allocator);
    var destination: std.Io.Writer.Allocating = .init(testing.allocator);
    defer destination.deinit();
    try destination.writer.writeAll("prefix");
    var stream: record.Writer = .init(
        testing.allocator,
        &destination.writer,
    );
    defer stream.deinit();
    terminal.colors.palette.current[7] = .{ .r = 1, .g = 2, .b = 3 };
    try testing.expectError(
        error.InvalidPalette,
        encode(&terminal, &stream),
    );
    try testing.expectEqualStrings("prefix", destination.written());
}
test "TERMINAL record decoding rejects malformed input transactionally" {
    const testing = std.testing;
    var wrong_tag: std.Io.Writer.Allocating = .init(testing.allocator);
    defer wrong_tag.deinit();
    var wrong_tag_stream: record.Writer = .init(
        testing.allocator,
        &wrong_tag.writer,
    );
    defer wrong_tag_stream.deinit();
    {
        _ = wrong_tag_stream.begin(.screen);
        errdefer wrong_tag_stream.cancel();
        try wrong_tag_stream.finish();
    }
    var wrong_tag_source: std.Io.Reader = .fixed(wrong_tag.written());
    try testing.expectError(
        error.UnexpectedRecordTag,
        decode(&wrong_tag_source, testing.io, testing.allocator),
    );
    var terminal = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 10,
        .rows = 3,
    });
    defer terminal.deinit(testing.allocator);
    try terminal.setPwd("pwd");
    try terminal.setTitle("title");
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    var encoded_stream: record.Writer = .init(
        testing.allocator,
        &encoded.writer,
    );
    defer encoded_stream.deinit();
    try encode(&terminal, &encoded_stream);
    for (0..encoded.written().len) |fixture_len| {
        var source: std.Io.Reader = .fixed(
            encoded.written()[0..fixture_len],
        );
        var restored = decode(
            &source,
            testing.io,
            testing.allocator,
        ) catch continue;
        restored.deinit(testing.allocator);
        try testing.expect(false);
    }
    var failing = testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 0 },
    );
    var failing_source: std.Io.Reader = .fixed(encoded.written());
    try testing.expectError(
        error.OutOfMemory,
        decode(&failing_source, testing.io, failing.allocator()),
    );
}
