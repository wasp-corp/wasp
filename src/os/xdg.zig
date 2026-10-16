const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const homedir = @import("homedir.zig");
pub const Options = struct {
    subdir: ?[]const u8 = null,
    home: ?[]const u8 = null,
};
pub fn config(io: std.Io, alloc: Allocator, environ_map: *const std.process.Environ.Map, opts: Options) ![]u8 {
    return try dir(io, alloc, environ_map, opts, .{
        .env = "XDG_CONFIG_HOME",
        .windows_env = "LOCALAPPDATA",
        .default_subdir = ".config",
    });
}
pub fn cache(io: std.Io, alloc: Allocator, environ_map: *const std.process.Environ.Map, opts: Options) ![]u8 {
    return try dir(io, alloc, environ_map, opts, .{
        .env = "XDG_CACHE_HOME",
        .windows_env = "LOCALAPPDATA",
        .default_subdir = ".cache",
    });
}
pub fn state(io: std.Io, alloc: Allocator, environ_map: *const std.process.Environ.Map, opts: Options) ![]u8 {
    return try dir(io, alloc, environ_map, opts, .{
        .env = "XDG_STATE_HOME",
        .windows_env = "LOCALAPPDATA",
        .default_subdir = ".local/state",
    });
}
const InternalOptions = struct {
    env: []const u8,
    windows_env: []const u8,
    default_subdir: []const u8,
};
fn dir(
    io: std.Io,
    alloc: Allocator,
    environ_map: *const std.process.Environ.Map,
    opts: Options,
    internal_opts: InternalOptions,
) ![]u8 {
    if (opts.home) |home| {
        return try std.fs.path.join(alloc, &[_][]const u8{
            home,
            internal_opts.default_subdir,
            opts.subdir orelse "",
        });
    }
    const env = switch (builtin.os.tag) {
        .windows => environ_map.get(internal_opts.env) orelse environ_map.get(internal_opts.windows_env) orelse "",
        else => environ_map.get(internal_opts.env) orelse "",
    };
    if (env.len > 0) {
        if (opts.subdir) |subdir| {
            return try std.fs.path.join(alloc, &[_][]const u8{
                env,
                subdir,
            });
        }
        return try alloc.dupe(u8, env);
    }
    var buf: [1024]u8 = undefined;
    if (try homedir.home(io, environ_map, &buf)) |home| {
        return try std.fs.path.join(alloc, &[_][]const u8{
            home,
            internal_opts.default_subdir,
            opts.subdir orelse "",
        });
    }
    return error.NoHomeDir;
}
pub fn parseTerminalExec(argv: []const [*:0]const u8) ?[]const [*:0]const u8 {
    if (!std.mem.eql(
        u8,
        std.fs.path.basename(std.mem.sliceTo(argv[0], 0)),
        "xdg-terminal-exec",
    )) return null;
    if (argv.len < 2) return &.{};
    const start: usize = if (std.mem.eql(u8, std.mem.sliceTo(argv[1], 0), "-e")) 2 else 1;
    return argv[start..];
}
test {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var environ_map = try testing.environ.createMap(alloc);
    defer environ_map.deinit();
    {
        const value = try config(io, alloc, &environ_map, .{});
        defer alloc.free(value);
        try testing.expect(value.len > 0);
    }
}
test "cache directory paths" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    const mock_home = if (builtin.os.tag == .windows) "C:\\Users\\test" else "/Users/test";
    var environ_map = try testing.environ.createMap(alloc);
    defer environ_map.deinit();
    {
        {
            const cache_path = try cache(io, alloc, &environ_map, .{ .home = mock_home });
            defer alloc.free(cache_path);
            const expected = try std.fs.path.join(alloc, &.{ mock_home, ".cache" });
            defer alloc.free(expected);
            try testing.expectEqualStrings(expected, cache_path);
        }
        {
            const cache_path = try cache(io, alloc, &environ_map, .{
                .home = mock_home,
                .subdir = "wasp",
            });
            defer alloc.free(cache_path);
            const expected = try std.fs.path.join(alloc, &.{ mock_home, ".cache", "wasp" });
            defer alloc.free(expected);
            try testing.expectEqualStrings(expected, cache_path);
        }
    }
}
test "fallback when xdg env empty" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const DirCase = struct {
        name: [:0]const u8,
        func: fn (std.Io, Allocator, *std.process.Environ.Map, Options) anyerror![]u8,
        default_subdir: []const u8,
    };
    const cases = [_]DirCase{
        .{ .name = "XDG_CONFIG_HOME", .func = config, .default_subdir = ".config" },
        .{ .name = "XDG_CACHE_HOME", .func = cache, .default_subdir = ".cache" },
        .{ .name = "XDG_STATE_HOME", .func = state, .default_subdir = ".local/state" },
    };
    inline for (cases) |case| {
        var environ_map = try std.testing.environ.createMap(alloc);
        defer environ_map.deinit();
        const temp_home = "/tmp/wasp-test-home";
        try environ_map.put("HOME", temp_home);
        const expected = try std.fs.path.join(alloc, &[_][]const u8{
            temp_home,
            case.default_subdir,
        });
        defer alloc.free(expected);
        try environ_map.put(case.name, "");
        const actual = try case.func(io, alloc, &environ_map, .{});
        defer alloc.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
}
test "fallback when xdg env empty and subdir" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const DirCase = struct {
        name: [:0]const u8,
        func: fn (std.Io, Allocator, *const std.process.Environ.Map, Options) anyerror![]u8,
        default_subdir: []const u8,
    };
    const cases = [_]DirCase{
        .{ .name = "XDG_CONFIG_HOME", .func = config, .default_subdir = ".config" },
        .{ .name = "XDG_CACHE_HOME", .func = cache, .default_subdir = ".cache" },
        .{ .name = "XDG_STATE_HOME", .func = state, .default_subdir = ".local/state" },
    };
    inline for (cases) |case| {
        var environ_map = try std.testing.environ.createMap(alloc);
        defer environ_map.deinit();
        const temp_home = "/tmp/wasp-test-home";
        try environ_map.put("HOME", temp_home);
        const expected = try std.fs.path.join(alloc, &[_][]const u8{
            temp_home,
            case.default_subdir,
            "wasp",
        });
        defer alloc.free(expected);
        try environ_map.put(case.name, "");
        const actual = try case.func(io, alloc, &environ_map, .{ .subdir = "wasp" });
        defer alloc.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
}
test parseTerminalExec {
    const testing = std.testing;
    {
        const actual = parseTerminalExec(&.{ "a", "b", "c" });
        try testing.expect(actual == null);
    }
    {
        const actual = parseTerminalExec(&.{"xdg-terminal-exec"}).?;
        try testing.expectEqualSlices([*:0]const u8, actual, &.{});
    }
    {
        const actual = parseTerminalExec(&.{ "xdg-terminal-exec", "a", "b", "c" }).?;
        try testing.expectEqualSlices([*:0]const u8, actual, &.{ "a", "b", "c" });
    }
    {
        const actual = parseTerminalExec(&.{ "xdg-terminal-exec", "-e", "a", "b", "c" }).?;
        try testing.expectEqualSlices([*:0]const u8, actual, &.{ "a", "b", "c" });
    }
    {
        const actual = parseTerminalExec(&.{ "xdg-terminal-exec", "a", "-e", "b", "c" }).?;
        try testing.expectEqualSlices([*:0]const u8, actual, &.{ "a", "-e", "b", "c" });
    }
}
