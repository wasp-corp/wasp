const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("wasp.zig").Action;
const global = @import("../global.zig");
pub const Options = struct {
    help: bool = false,
    pub fn deinit(self: Options) void {
        _ = self;
    }
};
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();
    {
        var iter = try args.argsIterator(alloc, global.args());
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }
    var buffer: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(global.io(), &buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(
        \\Usage: wasp [+action] [options]
        \\
        \\Run the Wasp terminal emulator or a specific helper action.
        \\
        \\If no `+action` is specified, run the Wasp terminal emulator.
        \\All configuration keys are available as command line options.
        \\To specify a configuration key, use the `--<key>=<value>` syntax
        \\where key and value are the same format you'd put into a configuration
        \\file. For example, `--font-size=12` or `--font-family="Fira Code"`.
        \\
        \\To see a list of all available configuration options, please see
        \\the `src/config/Config.zig` file. A future update will allow seeing
        \\the list of configuration options from the command line.
        \\
        \\A special command line argument `-e <command>` can be used to run
        \\the specific command inside the terminal emulator. For example,
        \\`wasp -e top` will run the `top` command inside the terminal.
        \\
        \\On macOS, launching the terminal emulator from the CLI is not
        \\supported and only actions are supported. Use `open -na Wasp.app`
        \\instead, or `open -na wasp.app --args --foo=bar --baz=quz` to pass
        \\arguments.
        \\
        \\Available actions:
        \\
        \\
    );
    inline for (@typeInfo(Action).@"enum".fields) |field| {
        try stdout.print("  +{s}\n", .{field.name});
    }
    try stdout.writeAll(
        \\
        \\Specify `+<action> --help` to see the help for a specific action,
        \\where `<action>` is one of actions listed above.
        \\
    );
    try stdout.flush();
    return 0;
}
