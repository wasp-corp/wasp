const Kitty = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const synthetic = @import("../main.zig");
const log = std.log.scoped(.@"kitty-gen");
pub const Options = struct {
    @"data-len": usize = 4096,
};
opts: Options,
buf: []u8,
pub fn create(
    alloc: Allocator,
    opts: Options,
) !*Kitty {
    const ptr = try alloc.create(Kitty);
    errdefer alloc.destroy(ptr);
    const buf = try alloc.alloc(u8, opts.@"data-len" + 128);
    errdefer alloc.free(buf);
    ptr.* = .{ .opts = opts, .buf = buf };
    return ptr;
}
pub fn destroy(self: *Kitty, alloc: Allocator) void {
    alloc.free(self.buf);
    alloc.destroy(self);
}
pub fn run(self: *Kitty, writer: *std.Io.Writer, rand: std.Random) !void {
    var gen: synthetic.Kitty = .{
        .rand = rand,
        .data_len = self.opts.@"data-len",
    };
    while (true) {
        var fixed: std.Io.Writer = .fixed(self.buf);
        try gen.next(&fixed, self.buf.len);
        writer.writeAll(fixed.buffered()) catch |err| switch (err) {
            error.WriteFailed => return,
        };
    }
}
test Kitty {
    const testing = std.testing;
    const alloc = testing.allocator;
    const impl: *Kitty = try .create(alloc, .{});
    defer impl.destroy(alloc);
    var prng = std.Random.DefaultPrng.init(1);
    const rand = prng.random();
    var buf: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try impl.run(&writer, rand);
}
