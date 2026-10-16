const std = @import("std");
const gio = @import("gio");
const global = @import("../../global.zig");
const Allocator = std.mem.Allocator;
pub const OpenURI = @import("portal/OpenURI.zig");
pub const token_hex_len = @sizeOf(usize) * 2;
pub const TokenBuffer = [token_hex_len + 1]u8;
const token_format = std.fmt.comptimePrint("{{x:0>{}}}", .{token_hex_len});
pub fn generateToken() usize {
    const rng_impl: std.Random.IoSource = .{ .io = global.io() };
    return rng_impl.interface().int(usize);
}
pub fn formatToken(buf: *TokenBuffer, token: usize) [:0]const u8 {
    return std.fmt.bufPrintZ(buf, token_format, .{token}) catch unreachable;
}
pub fn getRequestPath(alloc: Allocator, dbus: *gio.DBusConnection, token: usize) (Allocator.Error || error{NoDBusUniqueName})![:0]const u8 {
    const unique_name = std.mem.span(
        dbus.getUniqueName() orelse {
            return error.NoDBusUniqueName;
        },
    )[1..];
    return buildRequestPath(alloc, unique_name, token);
}
fn buildRequestPath(alloc: Allocator, unique_name: []const u8, token: usize) Allocator.Error![:0]const u8 {
    var token_buf: TokenBuffer = undefined;
    const token_string = formatToken(&token_buf, token);
    const object_path = try std.mem.joinZ(
        alloc,
        "/",
        &.{
            "/org/freedesktop/portal/desktop/request",
            unique_name,
            token_string,
        },
    );
    _ = std.mem.replaceScalar(u8, object_path, '.', '_');
    return object_path;
}
pub fn parseRequestPathToken(request_path: []const u8) ?usize {
    const index = std.mem.lastIndexOfScalar(u8, request_path, '/') orelse return null;
    const token = request_path[index + 1 ..];
    return std.fmt.parseUnsigned(usize, token, 16) catch return null;
}
test "formatToken pads to fixed width" {
    const testing = std.testing;
    var token_buf: TokenBuffer = undefined;
    const token = formatToken(&token_buf, 0x42);
    try testing.expectEqual(@as(usize, token_hex_len), token.len);
    try testing.expectEqualStrings("0000000000000042", token);
}
test "buildRequestPath" {
    const testing = std.testing;
    const path = try buildRequestPath(testing.allocator, "1.42", 0x75af01a79c6fea34);
    try testing.expectEqualStrings(
        "/org/freedesktop/portal/desktop/request/1_42/75af01a79c6fea34",
        path,
    );
    testing.allocator.free(path);
}
test "buildRequestPath pads token" {
    const testing = std.testing;
    const path = try buildRequestPath(testing.allocator, "1.42", 0x42);
    try testing.expectEqualStrings(
        "/org/freedesktop/portal/desktop/request/1_42/0000000000000042",
        path,
    );
    testing.allocator.free(path);
}
test "parseRequestPathToken" {
    const testing = std.testing;
    try testing.expectEqual(0x75af01a79c6fea34, parseRequestPathToken("/org/freedesktop/portal/desktop/request/1_42/75af01a79c6fea34").?);
    try testing.expectEqual(null, parseRequestPathToken("/org/freedesktop/portal/desktop/request/1_42/75af01a79c6fGa34"));
    try testing.expectEqual(null, parseRequestPathToken("75af01a79c6fea34"));
}
