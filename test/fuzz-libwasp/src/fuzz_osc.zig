const std = @import("std");
const wasp_vt = @import("wasp-vt");
const mem = @import("mem.zig");
const osc = wasp_vt.osc;
var fuzz_alloc: mem.FuzzAllocator(8 * 1024 * 1024) = .{};
pub export fn zig_fuzz_init() callconv(.c) void {
    fuzz_alloc.init();
}
pub export fn zig_fuzz_test(
    buf: [*]const u8,
    len: usize,
) callconv(.c) void {
    if (len == 0) return;
    fuzz_alloc.reset();
    const alloc = fuzz_alloc.allocator();
    const input = buf[0..len];
    const selector = input[0];
    const payload = input[1..];
    var p = osc.Parser.init(alloc);
    defer p.deinit();
    for (payload) |byte| p.next(byte);
    const terminator: ?u8 = switch (selector % 3) {
        0 => 0x07,
        1 => 0x9c,
        else => null,
    };
    _ = p.end(terminator);
}
