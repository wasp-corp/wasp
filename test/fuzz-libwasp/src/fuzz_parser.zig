const std = @import("std");
const wasp_vt = @import("wasp-vt");
pub export fn zig_fuzz_init() callconv(.c) void {}
pub export fn zig_fuzz_test(
    buf: [*]const u8,
    len: usize,
) callconv(.c) void {
    var p: wasp_vt.Parser = .init();
    defer p.deinit();
    for (buf[0..@intCast(len)]) |byte| _ = p.next(byte);
}
