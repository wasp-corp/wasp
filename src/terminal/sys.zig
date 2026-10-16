const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("terminal_options");
pub var decode_png: ?DecodePngFn = png: {
    if (build_options.artifact == .lib) break :png null;
    break :png &decodePngWuffs;
};
pub const DecodeError = Allocator.Error || error{InvalidData};
pub const DecodePngFn = *const fn (Allocator, []const u8) DecodeError!Image;
pub const Image = struct {
    width: u32,
    height: u32,
    data: []u8,
};
fn decodePngWuffs(
    alloc: Allocator,
    data: []const u8,
) DecodeError!Image {
    const wuffs = @import("wuffs");
    const result = wuffs.png.decode(
        alloc,
        data,
    ) catch |err| switch (err) {
        error.WuffsError => return error.InvalidData,
        error.OutOfMemory => return error.OutOfMemory,
        error.Overflow => return error.InvalidData,
    };
    return .{
        .width = result.width,
        .height = result.height,
        .data = result.data,
    };
}
pub var random_secure: ?RandomSecureFn = null;
pub const RandomSecureError = error{EntropyUnavailable};
pub const RandomSecureFn = *const fn ([]u8) RandomSecureError!void;
pub fn randomSecure(io: std.Io, buffer: []u8) std.Io.RandomSecureError!void {
    if (random_secure) |func| return func(buffer);
    return io.randomSecure(buffer);
}
test "randomSecure: override is preferred over the Io" {
    const testing = std.testing;
    const S = struct {
        fn fill(buffer: []u8) RandomSecureError!void {
            @memset(buffer, 0xAB);
        }
        fn fail(_: []u8) RandomSecureError!void {
            return error.EntropyUnavailable;
        }
    };
    var buf: [8]u8 = @splat(0);
    try testing.expectError(error.EntropyUnavailable, randomSecure(std.Io.failing, &buf));
    random_secure = &S.fill;
    defer random_secure = null;
    try randomSecure(std.Io.failing, &buf);
    try testing.expect(std.mem.allEqual(u8, &buf, 0xAB));
    random_secure = &S.fail;
    try testing.expectError(error.EntropyUnavailable, randomSecure(testing.io, &buf));
}
