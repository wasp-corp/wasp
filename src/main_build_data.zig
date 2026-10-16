const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("cli.zig");
pub const Action = enum {
    bash,
    fish,
    zsh,
    sublime,
    @"vim-syntax",
    @"vim-ftdetect",
    @"vim-ftplugin",
    @"vim-compiler",
    terminfo,
};
pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.c_allocator;
    const action_ = try cli.action.detectArgs(Action, alloc, init.minimal.args);
    const action = action_ orelse return error.NoAction;
    var buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const writer = &stdout_writer.interface;
    switch (action) {
        .bash => try writer.writeAll(@import("extra/bash.zig").completions),
        .fish => try writer.writeAll(@import("extra/fish.zig").completions),
        .zsh => try writer.writeAll(@import("extra/zsh.zig").completions),
        .sublime => try writer.writeAll(@import("extra/sublime.zig").syntax),
        .@"vim-syntax" => try writer.writeAll(@import("extra/vim.zig").syntax),
        .@"vim-ftdetect" => try writer.writeAll(@import("extra/vim.zig").ftdetect),
        .@"vim-ftplugin" => try writer.writeAll(@import("extra/vim.zig").ftplugin),
        .@"vim-compiler" => try writer.writeAll(@import("extra/vim.zig").compiler),
        .terminfo => try @import("terminfo/wasp.zig").wasp.encode(writer),
    }
    try stdout_writer.end();
}
