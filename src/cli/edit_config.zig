const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const args = @import("args.zig");
const Allocator = std.mem.Allocator;
const Action = @import("wasp.zig").Action;
const configpkg = @import("../config.zig");
const internal_os = @import("../os/root.zig");
const Config = configpkg.Config;
const global = @import("../global.zig");
pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};
pub fn run(alloc: Allocator) !u8 {
    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
    const stderr = &stderr_writer.interface;
    var opts: Options = .{};
    defer opts.deinit();
    {
        var iter = try args.argsIterator(alloc, global.args());
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }
    const result = runInner(alloc, stderr);
    stderr.flush() catch {};
    return result;
}
fn runInner(alloc: Allocator, stderr: *std.Io.Writer) !u8 {
    comptime assert(builtin.link_libc);
    var config = try Config.load(alloc);
    defer config.deinit();
    const path = try configpkg.preferredDefaultFilePath(alloc);
    defer alloc.free(path);
    if (comptime builtin.os.tag == .windows) {
        try stderr.print(
            \\The `wasp +edit-config` command is not supported on Windows.
            \\Please edit the configuration file manually at the following path:
            \\
            \\
        ,
            .{},
        );
        return 1;
    }
    const command = internal_os.getConfigEditCommand(alloc, path, .{ .default_editor = .failure }) catch |err| {
        switch (err) {
            error.NoEditorConfigured => {
                try stderr.print(
                    \\The $EDITOR or $VISUAL environment variable is not set or is empty.
                    \\This environment variable is required to edit the Wasp configuration
                    \\via this CLI command.
                    \\
                    \\Please set the environment variable to your preferred terminal
                    \\text editor and try again.
                    \\
                    \\If you prefer to edit the configuration file another way,
                    \\you can find the configuration file at the following path:
                    \\
                    \\
                ,
                    .{},
                );
                try stderr.print(
                    "\x1b]8;;file://{s}\x1b\\{s}\x1b]8;;\x1b\\\n",
                    .{ path, path },
                );
                return 1;
            },
            error.WriteFailed,
            error.OutOfMemory,
            => |e| return e,
        }
    };
    defer alloc.free(command);
    const argv = [_:null]?[*:0]const u8{
        "/bin/sh",
        "-c",
        command.ptr,
    };
    const envp = std.c.environ;
    const err = std.posix.errno(std.posix.system.execve(argv[0].?, &argv, envp));
    try stderr.print(
        \\Failed to execute the editor (E{t}).
        \\
        \\This is usually due to the executable path not existing, invalid
        \\permissions, or the shell environment not being set up
        \\correctly.
        \\
        \\Command: {s}
        \\
    , .{
        err,
        command,
    });
    try stderr.print(
        "Path: \x1b]8;;file://{s}\x1b\\{s}\x1b]8;;\x1b\\\n",
        .{ path, path },
    );
    return 1;
}
