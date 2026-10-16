const std = @import("std");
const uucode = @import("uucode");
const lut = @import("lut.zig");
pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const gen: lut.Generator(
        bool,
        struct {
            pub fn get(ctx: @This(), cp: u21) !bool {
                _ = ctx;
                return if (cp > uucode.config.max_code_point)
                    false
                else
                    uucode.get(.is_symbol, @intCast(cp));
            }
            pub fn eql(ctx: @This(), a: bool, b: bool) bool {
                _ = ctx;
                return a == b;
            }
        },
    ) = .{};
    const t = try gen.generate(alloc);
    defer alloc.free(t.stage1);
    defer alloc.free(t.stage2);
    defer alloc.free(t.stage3);
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    try t.writeZig(&stdout.interface);
    try stdout.interface.flush();
}
test "unicode symbols: tables match uucode" {
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;
    const testing = std.testing;
    const table = @import("symbols_table.zig").table;
    for (0..std.math.maxInt(u21)) |cp| {
        const t = table.get(@intCast(cp));
        const uu = if (cp > uucode.config.max_code_point)
            false
        else
            uucode.get(.is_symbol, @intCast(cp));
        if (t != uu) {
            std.log.warn("mismatch cp=U+{x} t={} uu={}", .{ cp, t, uu });
            try testing.expect(false);
        }
    }
}
