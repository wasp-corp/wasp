const std = @import("std");
pub fn isAlphanumeric(c: u21) bool {
    return switch (c) {
        '0'...'9', 'A'...'Z', 'a'...'z' => true,
        else => false,
    };
}
pub fn isAlphabetic(c: u21) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z' => true,
        else => false,
    };
}
pub fn isControl(c: u21) bool {
    return c <= std.ascii.control_code.us or c == std.ascii.control_code.del;
}
pub fn isDigit(c: u21) bool {
    return switch (c) {
        '0'...'9' => true,
        else => false,
    };
}
pub fn isLower(c: u21) bool {
    return switch (c) {
        'a'...'z' => true,
        else => false,
    };
}
pub fn isPrint(c: u21) bool {
    return isAscii(c) and !isControl(c);
}
pub fn isWhitespace(c: u21) bool {
    return switch (c) {
        ' ', '\t'...'\r' => true,
        else => false,
    };
}
pub fn isUpper(c: u21) bool {
    return switch (c) {
        'A'...'Z' => true,
        else => false,
    };
}
pub fn isHex(c: u21) bool {
    return switch (c) {
        '0'...'9', 'A'...'F', 'a'...'f' => true,
        else => false,
    };
}
pub fn isAscii(c: u21) bool {
    return c < 128;
}
pub fn toUpper(c: u21) u21 {
    const mask = @as(u21, @intFromBool(isLower(c))) << 5;
    return c ^ mask;
}
pub fn toLower(c: u21) u21 {
    const mask = @as(u21, @intFromBool(isUpper(c))) << 5;
    return c | mask;
}
