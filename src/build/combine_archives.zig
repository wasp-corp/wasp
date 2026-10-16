const std = @import("std");
pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    if (args.len < 4) {
        std.log.err("usage: combine_archives <zig_exe> <output> <input...>", .{});
        std.process.exit(1);
    }
    const zig_exe = args[1];
    const output_path = args[2];
    const inputs = args[3..];
    var script: std.ArrayListUnmanaged(u8) = .empty;
    try script.appendSlice(alloc, "CREATE ");
    try script.appendSlice(alloc, output_path);
    try script.append(alloc, '\n');
    for (inputs) |input| {
        try script.appendSlice(alloc, "ADDLIB ");
        try script.appendSlice(alloc, input);
        try script.append(alloc, '\n');
    }
    try script.appendSlice(alloc, "SAVE\nEND\n");
    var child = try std.process.spawn(init.io, .{
        .argv = &.{ zig_exe, "ar", "-M" },
        .stdin = .pipe,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    try child.stdin.?.writeStreamingAll(init.io, script.items);
    child.stdin.?.close(init.io);
    child.stdin = null;
    const term = try child.wait(init.io);
    if (term.exited != 0) {
        std.log.err("zig ar -M exited with code {d}", .{term.exited});
        std.process.exit(1);
    }
}
