const std = @import("std");
const testing = std.testing;
pub const ParseError = error{
    MissingEntry,
    ExtraEntry,
    FormatError,
};
pub fn parseFormatStruct(
    comptime T: type,
    str: []const u8,
    delimiter: u8,
) ParseError!T {
    const fields = @typeInfo(T).@"struct".fields;
    var it = std.mem.splitScalar(u8, str, delimiter);
    var result: T = undefined;
    inline for (fields) |field| {
        const part = it.next() orelse return error.MissingEntry;
        @field(result, field.name) = Variable.parse(
            @field(Variable, field.name),
            part,
        ) catch return error.FormatError;
    }
    if (it.next() != null) return error.ExtraEntry;
    return result;
}
pub fn comptimeFormat(
    comptime vars: []const Variable,
    comptime delimiter: u8,
) []const u8 {
    comptime {
        @setEvalBranchQuota(50000);
        var counter: std.Io.Writer.Discarding = .init(&.{});
        try format(&counter.writer, vars, delimiter);
        var buf: [counter.count]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try format(&writer, vars, delimiter);
        const final = buf;
        return final[0..writer.end];
    }
}
pub fn format(
    writer: *std.Io.Writer,
    vars: []const Variable,
    delimiter: u8,
) std.Io.Writer.Error!void {
    for (vars, 0..) |variable, i| {
        if (i != 0) try writer.writeByte(delimiter);
        try writer.print("#{{{t}}}", .{variable});
    }
}
pub fn FormatStruct(comptime vars: []const Variable) type {
    var names: [vars.len][]const u8 = undefined;
    var types: [vars.len]type = undefined;
    var attrs: [vars.len]std.builtin.Type.StructField.Attributes = undefined;
    for (vars, &names, &types, &attrs) |variable, *name, *ty, *attr| {
        name.* = @tagName(variable);
        ty.* = variable.Type();
        attr.* = .{ .@"align" = @alignOf(variable.Type()) };
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}
pub const Variable = enum {
    alternate_on,
    alternate_saved_x,
    alternate_saved_y,
    bracketed_paste,
    cursor_blinking,
    cursor_colour,
    cursor_flag,
    cursor_shape,
    cursor_x,
    cursor_y,
    focus_flag,
    insert_flag,
    keypad_cursor_flag,
    keypad_flag,
    mouse_all_flag,
    mouse_button_flag,
    mouse_sgr_flag,
    mouse_standard_flag,
    mouse_utf8_flag,
    origin_flag,
    pane_id,
    pane_tabs,
    scroll_region_lower,
    scroll_region_upper,
    session_id,
    version,
    window_id,
    window_width,
    window_height,
    window_layout,
    wrap_flag,
    pub fn parse(comptime self: Variable, value: []const u8) !Type(self) {
        return switch (self) {
            .alternate_on,
            .bracketed_paste,
            .cursor_blinking,
            .cursor_flag,
            .focus_flag,
            .insert_flag,
            .keypad_cursor_flag,
            .keypad_flag,
            .mouse_all_flag,
            .mouse_button_flag,
            .mouse_sgr_flag,
            .mouse_standard_flag,
            .mouse_utf8_flag,
            .origin_flag,
            .wrap_flag,
            => std.mem.eql(u8, value, "1"),
            .alternate_saved_x,
            .alternate_saved_y,
            .cursor_x,
            .cursor_y,
            .scroll_region_lower,
            .scroll_region_upper,
            => try std.fmt.parseInt(usize, value, 10),
            .session_id => if (value.len >= 2 and value[0] == '$')
                try std.fmt.parseInt(usize, value[1..], 10)
            else
                return error.FormatError,
            .window_id => if (value.len >= 2 and value[0] == '@')
                try std.fmt.parseInt(usize, value[1..], 10)
            else
                return error.FormatError,
            .pane_id => if (value.len >= 2 and value[0] == '%')
                try std.fmt.parseInt(usize, value[1..], 10)
            else
                return error.FormatError,
            .window_width => try std.fmt.parseInt(usize, value, 10),
            .window_height => try std.fmt.parseInt(usize, value, 10),
            .cursor_colour,
            .cursor_shape,
            .pane_tabs,
            .version,
            .window_layout,
            => value,
        };
    }
    pub fn Type(comptime self: Variable) type {
        return switch (self) {
            .alternate_on,
            .bracketed_paste,
            .cursor_blinking,
            .cursor_flag,
            .focus_flag,
            .insert_flag,
            .keypad_cursor_flag,
            .keypad_flag,
            .mouse_all_flag,
            .mouse_button_flag,
            .mouse_sgr_flag,
            .mouse_standard_flag,
            .mouse_utf8_flag,
            .origin_flag,
            .wrap_flag,
            => bool,
            .alternate_saved_x,
            .alternate_saved_y,
            .cursor_x,
            .cursor_y,
            .scroll_region_lower,
            .scroll_region_upper,
            .session_id,
            .window_id,
            .pane_id,
            .window_width,
            .window_height,
            => usize,
            .cursor_colour,
            .cursor_shape,
            .pane_tabs,
            .version,
            .window_layout,
            => []const u8,
        };
    }
};
test "parse alternate_on" {
    try testing.expectEqual(true, try Variable.parse(.alternate_on, "1"));
    try testing.expectEqual(false, try Variable.parse(.alternate_on, "0"));
    try testing.expectEqual(false, try Variable.parse(.alternate_on, ""));
    try testing.expectEqual(false, try Variable.parse(.alternate_on, "true"));
    try testing.expectEqual(false, try Variable.parse(.alternate_on, "yes"));
}
test "parse alternate_saved_x" {
    try testing.expectEqual(0, try Variable.parse(.alternate_saved_x, "0"));
    try testing.expectEqual(42, try Variable.parse(.alternate_saved_x, "42"));
    try testing.expectError(error.InvalidCharacter, Variable.parse(.alternate_saved_x, "abc"));
}
test "parse alternate_saved_y" {
    try testing.expectEqual(0, try Variable.parse(.alternate_saved_y, "0"));
    try testing.expectEqual(42, try Variable.parse(.alternate_saved_y, "42"));
    try testing.expectError(error.InvalidCharacter, Variable.parse(.alternate_saved_y, "abc"));
}
test "parse cursor_x" {
    try testing.expectEqual(0, try Variable.parse(.cursor_x, "0"));
    try testing.expectEqual(79, try Variable.parse(.cursor_x, "79"));
    try testing.expectError(error.InvalidCharacter, Variable.parse(.cursor_x, "abc"));
}
test "parse cursor_y" {
    try testing.expectEqual(0, try Variable.parse(.cursor_y, "0"));
    try testing.expectEqual(23, try Variable.parse(.cursor_y, "23"));
    try testing.expectError(error.InvalidCharacter, Variable.parse(.cursor_y, "abc"));
}
test "parse scroll_region_upper" {
    try testing.expectEqual(0, try Variable.parse(.scroll_region_upper, "0"));
    try testing.expectEqual(5, try Variable.parse(.scroll_region_upper, "5"));
    try testing.expectError(error.InvalidCharacter, Variable.parse(.scroll_region_upper, "abc"));
}
test "parse scroll_region_lower" {
    try testing.expectEqual(0, try Variable.parse(.scroll_region_lower, "0"));
    try testing.expectEqual(23, try Variable.parse(.scroll_region_lower, "23"));
    try testing.expectError(error.InvalidCharacter, Variable.parse(.scroll_region_lower, "abc"));
}
test "parse session id" {
    try testing.expectEqual(42, try Variable.parse(.session_id, "$42"));
    try testing.expectEqual(0, try Variable.parse(.session_id, "$0"));
    try testing.expectError(error.FormatError, Variable.parse(.session_id, "0"));
    try testing.expectError(error.FormatError, Variable.parse(.session_id, "@0"));
    try testing.expectError(error.FormatError, Variable.parse(.session_id, "$"));
    try testing.expectError(error.FormatError, Variable.parse(.session_id, ""));
    try testing.expectError(error.InvalidCharacter, Variable.parse(.session_id, "$abc"));
}
test "parse window id" {
    try testing.expectEqual(42, try Variable.parse(.window_id, "@42"));
    try testing.expectEqual(0, try Variable.parse(.window_id, "@0"));
    try testing.expectEqual(12345, try Variable.parse(.window_id, "@12345"));
    try testing.expectError(error.FormatError, Variable.parse(.window_id, "0"));
    try testing.expectError(error.FormatError, Variable.parse(.window_id, "$0"));
    try testing.expectError(error.FormatError, Variable.parse(.window_id, "@"));
    try testing.expectError(error.FormatError, Variable.parse(.window_id, ""));
    try testing.expectError(error.InvalidCharacter, Variable.parse(.window_id, "@abc"));
}
test "parse window width" {
    try testing.expectEqual(80, try Variable.parse(.window_width, "80"));
    try testing.expectEqual(0, try Variable.parse(.window_width, "0"));
    try testing.expectEqual(12345, try Variable.parse(.window_width, "12345"));
    try testing.expectError(error.InvalidCharacter, Variable.parse(.window_width, "abc"));
    try testing.expectError(error.InvalidCharacter, Variable.parse(.window_width, "80px"));
    try testing.expectError(error.Overflow, Variable.parse(.window_width, "-1"));
}
test "parse window height" {
    try testing.expectEqual(24, try Variable.parse(.window_height, "24"));
    try testing.expectEqual(0, try Variable.parse(.window_height, "0"));
    try testing.expectEqual(12345, try Variable.parse(.window_height, "12345"));
    try testing.expectError(error.InvalidCharacter, Variable.parse(.window_height, "abc"));
    try testing.expectError(error.InvalidCharacter, Variable.parse(.window_height, "24px"));
    try testing.expectError(error.Overflow, Variable.parse(.window_height, "-1"));
}
test "parse window layout" {
    try testing.expectEqualStrings("abc123", try Variable.parse(.window_layout, "abc123"));
    try testing.expectEqualStrings("", try Variable.parse(.window_layout, ""));
    try testing.expectEqualStrings("a]b,c{d}e(f)", try Variable.parse(.window_layout, "a]b,c{d}e(f)"));
}
test "parse cursor_flag" {
    try testing.expectEqual(true, try Variable.parse(.cursor_flag, "1"));
    try testing.expectEqual(false, try Variable.parse(.cursor_flag, "0"));
    try testing.expectEqual(false, try Variable.parse(.cursor_flag, ""));
    try testing.expectEqual(false, try Variable.parse(.cursor_flag, "true"));
}
test "parse insert_flag" {
    try testing.expectEqual(true, try Variable.parse(.insert_flag, "1"));
    try testing.expectEqual(false, try Variable.parse(.insert_flag, "0"));
    try testing.expectEqual(false, try Variable.parse(.insert_flag, ""));
    try testing.expectEqual(false, try Variable.parse(.insert_flag, "true"));
}
test "parse keypad_cursor_flag" {
    try testing.expectEqual(true, try Variable.parse(.keypad_cursor_flag, "1"));
    try testing.expectEqual(false, try Variable.parse(.keypad_cursor_flag, "0"));
    try testing.expectEqual(false, try Variable.parse(.keypad_cursor_flag, ""));
    try testing.expectEqual(false, try Variable.parse(.keypad_cursor_flag, "true"));
}
test "parse keypad_flag" {
    try testing.expectEqual(true, try Variable.parse(.keypad_flag, "1"));
    try testing.expectEqual(false, try Variable.parse(.keypad_flag, "0"));
    try testing.expectEqual(false, try Variable.parse(.keypad_flag, ""));
    try testing.expectEqual(false, try Variable.parse(.keypad_flag, "true"));
}
test "parse mouse_button_flag" {
    try testing.expectEqual(true, try Variable.parse(.mouse_button_flag, "1"));
    try testing.expectEqual(false, try Variable.parse(.mouse_button_flag, "0"));
    try testing.expectEqual(false, try Variable.parse(.mouse_button_flag, ""));
    try testing.expectEqual(false, try Variable.parse(.mouse_button_flag, "true"));
}
test "parse mouse_sgr_flag" {
    try testing.expectEqual(true, try Variable.parse(.mouse_sgr_flag, "1"));
    try testing.expectEqual(false, try Variable.parse(.mouse_sgr_flag, "0"));
    try testing.expectEqual(false, try Variable.parse(.mouse_sgr_flag, ""));
    try testing.expectEqual(false, try Variable.parse(.mouse_sgr_flag, "true"));
}
test "parse mouse_standard_flag" {
    try testing.expectEqual(true, try Variable.parse(.mouse_standard_flag, "1"));
    try testing.expectEqual(false, try Variable.parse(.mouse_standard_flag, "0"));
    try testing.expectEqual(false, try Variable.parse(.mouse_standard_flag, ""));
    try testing.expectEqual(false, try Variable.parse(.mouse_standard_flag, "true"));
}
test "parse mouse_utf8_flag" {
    try testing.expectEqual(true, try Variable.parse(.mouse_utf8_flag, "1"));
    try testing.expectEqual(false, try Variable.parse(.mouse_utf8_flag, "0"));
    try testing.expectEqual(false, try Variable.parse(.mouse_utf8_flag, ""));
    try testing.expectEqual(false, try Variable.parse(.mouse_utf8_flag, "true"));
}
test "parse wrap_flag" {
    try testing.expectEqual(true, try Variable.parse(.wrap_flag, "1"));
    try testing.expectEqual(false, try Variable.parse(.wrap_flag, "0"));
    try testing.expectEqual(false, try Variable.parse(.wrap_flag, ""));
    try testing.expectEqual(false, try Variable.parse(.wrap_flag, "true"));
}
test "parse bracketed_paste" {
    try testing.expectEqual(true, try Variable.parse(.bracketed_paste, "1"));
    try testing.expectEqual(false, try Variable.parse(.bracketed_paste, "0"));
    try testing.expectEqual(false, try Variable.parse(.bracketed_paste, ""));
    try testing.expectEqual(false, try Variable.parse(.bracketed_paste, "true"));
}
test "parse cursor_blinking" {
    try testing.expectEqual(true, try Variable.parse(.cursor_blinking, "1"));
    try testing.expectEqual(false, try Variable.parse(.cursor_blinking, "0"));
    try testing.expectEqual(false, try Variable.parse(.cursor_blinking, ""));
    try testing.expectEqual(false, try Variable.parse(.cursor_blinking, "true"));
}
test "parse focus_flag" {
    try testing.expectEqual(true, try Variable.parse(.focus_flag, "1"));
    try testing.expectEqual(false, try Variable.parse(.focus_flag, "0"));
    try testing.expectEqual(false, try Variable.parse(.focus_flag, ""));
    try testing.expectEqual(false, try Variable.parse(.focus_flag, "true"));
}
test "parse mouse_all_flag" {
    try testing.expectEqual(true, try Variable.parse(.mouse_all_flag, "1"));
    try testing.expectEqual(false, try Variable.parse(.mouse_all_flag, "0"));
    try testing.expectEqual(false, try Variable.parse(.mouse_all_flag, ""));
    try testing.expectEqual(false, try Variable.parse(.mouse_all_flag, "true"));
}
test "parse origin_flag" {
    try testing.expectEqual(true, try Variable.parse(.origin_flag, "1"));
    try testing.expectEqual(false, try Variable.parse(.origin_flag, "0"));
    try testing.expectEqual(false, try Variable.parse(.origin_flag, ""));
    try testing.expectEqual(false, try Variable.parse(.origin_flag, "true"));
}
test "parse pane_id" {
    try testing.expectEqual(42, try Variable.parse(.pane_id, "%42"));
    try testing.expectEqual(0, try Variable.parse(.pane_id, "%0"));
    try testing.expectError(error.FormatError, Variable.parse(.pane_id, "0"));
    try testing.expectError(error.FormatError, Variable.parse(.pane_id, "@0"));
    try testing.expectError(error.FormatError, Variable.parse(.pane_id, "%"));
    try testing.expectError(error.FormatError, Variable.parse(.pane_id, ""));
    try testing.expectError(error.InvalidCharacter, Variable.parse(.pane_id, "%abc"));
}
test "parse cursor_colour" {
    try testing.expectEqualStrings("red", try Variable.parse(.cursor_colour, "red"));
    try testing.expectEqualStrings("#ff0000", try Variable.parse(.cursor_colour, "#ff0000"));
    try testing.expectEqualStrings("", try Variable.parse(.cursor_colour, ""));
}
test "parse cursor_shape" {
    try testing.expectEqualStrings("block", try Variable.parse(.cursor_shape, "block"));
    try testing.expectEqualStrings("underline", try Variable.parse(.cursor_shape, "underline"));
    try testing.expectEqualStrings("bar", try Variable.parse(.cursor_shape, "bar"));
    try testing.expectEqualStrings("", try Variable.parse(.cursor_shape, ""));
}
test "parse pane_tabs" {
    try testing.expectEqualStrings("0,8,16,24", try Variable.parse(.pane_tabs, "0,8,16,24"));
    try testing.expectEqualStrings("", try Variable.parse(.pane_tabs, ""));
    try testing.expectEqualStrings("0", try Variable.parse(.pane_tabs, "0"));
}
test "parse version" {
    try testing.expectEqualStrings("3.5a", try Variable.parse(.version, "3.5a"));
    try testing.expectEqualStrings("3.5", try Variable.parse(.version, "3.5"));
    try testing.expectEqualStrings("next-3.5", try Variable.parse(.version, "next-3.5"));
    try testing.expectEqualStrings("", try Variable.parse(.version, ""));
}
test "parseFormatStruct single field" {
    const T = FormatStruct(&.{.session_id});
    const result = try parseFormatStruct(T, "$42", ' ');
    try testing.expectEqual(42, result.session_id);
}
test "parseFormatStruct multiple fields" {
    const T = FormatStruct(&.{ .session_id, .window_id, .window_width, .window_height });
    const result = try parseFormatStruct(T, "$1 @2 80 24", ' ');
    try testing.expectEqual(1, result.session_id);
    try testing.expectEqual(2, result.window_id);
    try testing.expectEqual(80, result.window_width);
    try testing.expectEqual(24, result.window_height);
}
test "parseFormatStruct with string field" {
    const T = FormatStruct(&.{ .window_id, .window_layout });
    const result = try parseFormatStruct(T, "@5,abc123", ',');
    try testing.expectEqual(5, result.window_id);
    try testing.expectEqualStrings("abc123", result.window_layout);
}
test "parseFormatStruct different delimiter" {
    const T = FormatStruct(&.{ .window_width, .window_height });
    const result = try parseFormatStruct(T, "120\t40", '\t');
    try testing.expectEqual(120, result.window_width);
    try testing.expectEqual(40, result.window_height);
}
test "parseFormatStruct missing entry" {
    const T = FormatStruct(&.{ .session_id, .window_id });
    try testing.expectError(error.MissingEntry, parseFormatStruct(T, "$1", ' '));
}
test "parseFormatStruct extra entry" {
    const T = FormatStruct(&.{.session_id});
    try testing.expectError(error.ExtraEntry, parseFormatStruct(T, "$1 @2", ' '));
}
test "parseFormatStruct format error" {
    const T = FormatStruct(&.{.session_id});
    try testing.expectError(error.FormatError, parseFormatStruct(T, "42", ' '));
    try testing.expectError(error.FormatError, parseFormatStruct(T, "@42", ' '));
    try testing.expectError(error.FormatError, parseFormatStruct(T, "$abc", ' '));
}
test "parseFormatStruct empty string" {
    const T = FormatStruct(&.{.session_id});
    try testing.expectError(error.FormatError, parseFormatStruct(T, "", ' '));
}
test "parseFormatStruct with empty layout field" {
    const T = FormatStruct(&.{ .session_id, .window_layout });
    const result = try parseFormatStruct(T, "$1,", ',');
    try testing.expectEqual(1, result.session_id);
    try testing.expectEqualStrings("", result.window_layout);
}
fn testFormat(
    comptime vars: []const Variable,
    comptime delimiter: u8,
    comptime expected: []const u8,
) !void {
    const comptime_result = comptime comptimeFormat(vars, delimiter);
    try testing.expectEqualStrings(expected, comptime_result);
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try format(&writer, vars, delimiter);
    try testing.expectEqualStrings(expected, buf[0..writer.end]);
}
test "format single variable" {
    try testFormat(&.{.session_id}, ' ', "#{session_id}");
}
test "format multiple variables" {
    try testFormat(&.{ .session_id, .window_id, .window_width, .window_height }, ' ', "#{session_id} #{window_id} #{window_width} #{window_height}");
}
test "format with comma delimiter" {
    try testFormat(&.{ .window_id, .window_layout }, ',', "#{window_id},#{window_layout}");
}
test "format with tab delimiter" {
    try testFormat(&.{ .window_width, .window_height }, '\t', "#{window_width}\t#{window_height}");
}
test "format empty variables" {
    try testFormat(&.{}, ' ', "");
}
test "format all variables" {
    try testFormat(&.{ .session_id, .window_id, .window_width, .window_height, .window_layout }, ' ', "#{session_id} #{window_id} #{window_width} #{window_height} #{window_layout}");
}
