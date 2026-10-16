const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const build_config = @import("build_config.zig");
const macos = @import("macos");
const cli = @import("cli.zig");
const renderer = @import("renderer.zig");
const apprt = @import("apprt.zig");
const App = @import("App.zig");
const Wasp = @import("main_c.zig").Wasp;
const global = @import("global.zig");
const MainReturn = switch (build_config.artifact) {
    .lib => noreturn,
    else => void,
};
pub fn main(minimal: std.process.Init.Minimal) !MainReturn {
    global.init(.{ .main = minimal }) catch |err| {
        var buffer: [1024]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(
            std.Io.Threaded.global_single_threaded.io(),
            &buffer,
        );
        const stderr = &stderr_writer.interface;
        defer std.process.exit(1);
        const ErrSet = @TypeOf(err) || error{Unknown};
        switch (@as(ErrSet, @errorCast(err))) {
            error.MultipleActions => try stderr.print(
                "Error: multiple CLI actions specified. You must specify only one\n" ++
                    "action starting with the `+` character.\n",
                .{},
            ),
            error.InvalidAction => try stderr.print(
                "Error: unknown CLI action specified. CLI actions are specified with\n" ++
                    "the '+' character.\n\n" ++
                    "All valid CLI actions can be listed with `wasp +help`\n",
                .{},
            ),
            else => try stderr.print("invalid CLI invocation err={}\n", .{err}),
        }
        try stderr.flush();
    };
    defer global.deinit();
    const alloc = global.alloc();
    if (comptime builtin.mode == .Debug) {
        std.log.warn("This is a debug build. Performance will be very poor.", .{});
        std.log.warn("You should only use a debug build for developing Wasp.", .{});
        std.log.warn("Otherwise, please rebuild in a release mode.", .{});
    }
    if (global.action()) |action| {
        std.log.info("executing CLI action={}", .{action});
        std.process.exit(action.run(alloc) catch |err| err: {
            std.log.err("CLI action failed error={}", .{err});
            break :err 1;
        });
        return;
    }
    if (comptime build_config.app_runtime == .none) {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("Usage: wasp +<action> [flags]\n\n", .{});
        try stdout.print(
            \\This is the Wasp helper CLI that accompanies the graphical Wasp app.
            \\To launch the terminal directly, please launch the graphical app
            \\(i.e. Wasp.app on macOS). This CLI can be used to perform various
            \\actions such as inspecting the version, listing fonts, etc.
            \\
            \\On macOS, the terminal can also be launched using `open -na Wasp.app`,
            \\or `open -na Wasp.app --args --foo=bar --baz=qux` to pass arguments.
            \\
            \\We don't have proper help output yet, sorry! Please refer to the
            \\source code or Discord community for help for now. We'll fix this in time.
            \\
        ,
            .{},
        );
        std.process.exit(0);
    }
    const app: *App = try App.create(alloc);
    defer app.destroy();
    var app_runtime: apprt.App = undefined;
    try app_runtime.init(app, .{});
    defer app_runtime.terminate();
    if (@hasDecl(apprt.App, "startQuitTimer")) app_runtime.startQuitTimer();
    try app_runtime.run();
}
fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    macos: {
        if (comptime !builtin.target.os.tag.isDarwin()) break :macos;
        if (!global.logging().macos) break :macos;
        const prefix = if (scope == .default) "" else @tagName(scope) ++ ": ";
        const mac_level: macos.os.LogType = switch (level) {
            .debug => .debug,
            .info => .info,
            .warn => .err,
            .err => .fault,
        };
        macosLogger(scope).log(
            std.heap.c_allocator,
            mac_level,
            prefix ++ format,
            args,
        );
    }
    stderr: {
        if (comptime builtin.mode != .Debug and level == .debug) break :stderr;
        if (!global.logging().stderr) break :stderr;
        var buf: [64]u8 = undefined;
        const stderr = std.debug.lockStderr(&buf);
        defer std.debug.unlockStderr();
        const level_txt = comptime level.asText();
        const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
        nosuspend stderr.file_writer.interface.print(level_txt ++ prefix ++ format ++ "\n", args) catch break :stderr;
        nosuspend stderr.file_writer.interface.flush() catch break :stderr;
    }
}
fn macosLogger(comptime scope: @TypeOf(.EnumLiteral)) *macos.os.Log {
    const S = struct {
        var cached: std.atomic.Value(?*macos.os.Log) = .init(null);
    };
    if (S.cached.load(.acquire)) |v| return v;
    const created = macos.os.Log.create(
        build_config.bundle_id,
        @tagName(scope),
    );
    if (S.cached.cmpxchgStrong(
        null,
        created,
        .acq_rel,
        .acquire,
    )) |existing| {
        created.release();
        return existing.?;
    }
    return created;
}
pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },
    .logFn = logFn,
    .allow_stack_tracing = if (builtin.target.os.tag.isDarwin() and builtin.target.os.tag != .macos)
        false
    else
        !builtin.strip_debug_info,
};
test {
    _ = @import("pty.zig");
    _ = @import("Command.zig");
    _ = @import("font/root.zig");
    _ = @import("apprt.zig");
    _ = @import("renderer.zig");
    _ = @import("termio.zig");
    _ = @import("input.zig");
    _ = @import("cli.zig");
    _ = @import("surface_mouse.zig");
    _ = @import("tripwire.zig");
    _ = @import("benchmark/main.zig");
    _ = @import("crash/main.zig");
    _ = @import("datastruct/root.zig");
    _ = @import("inspector/root.zig");
    _ = @import("lib/main.zig");
    _ = @import("terminal/main.zig");
    _ = @import("terminfo/root.zig");
    _ = @import("simd/root.zig");
    _ = @import("synthetic/root.zig");
    _ = @import("unicode/root.zig");
    _ = @import("unicode/props_uucode.zig");
    _ = @import("unicode/symbols_uucode.zig");
    _ = @import("extra/bash.zig");
    _ = @import("extra/fish.zig");
    _ = @import("extra/sublime.zig");
    _ = @import("extra/vim.zig");
    _ = @import("extra/zsh.zig");
}
