const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const EnvMap = std.process.Environ.Map;
const config = @import("../config.zig");
const homedir = @import("../os/homedir.zig");
const internal_os = @import("../os/root.zig");
const global = @import("../global.zig");
const log = std.log.scoped(.shell_integration);
pub const Shell = enum {
    bash,
    elvish,
    fish,
    nushell,
    zsh,
};
pub const ShellIntegration = struct {
    shell: Shell,
    command: config.Command,
};
pub fn setup(
    alloc_arena: Allocator,
    resource_dir: []const u8,
    command: config.Command,
    env: *EnvMap,
    force_shell: ?Shell,
) !?ShellIntegration {
    const shell: Shell = force_shell orelse
        try detectShell(alloc_arena, command) orelse
        return null;
    const new_command: config.Command = switch (shell) {
        .bash => try setupBash(
            alloc_arena,
            command,
            resource_dir,
            env,
        ),
        .nushell => try setupNushell(
            alloc_arena,
            command,
            resource_dir,
            env,
        ),
        .zsh => try setupZsh(
            alloc_arena,
            command,
            resource_dir,
            env,
        ),
        .elvish, .fish => xdg: {
            if (!try setupXdgDataDirs(alloc_arena, resource_dir, env)) return null;
            break :xdg try command.clone(alloc_arena);
        },
    } orelse return null;
    return .{
        .shell = shell,
        .command = new_command,
    };
}
test "force shell" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = EnvMap.init(alloc);
    defer env.deinit();
    inline for (@typeInfo(Shell).@"enum".fields) |field| {
        const shell = @field(Shell, field.name);
        var res: TmpResourcesDir = try .init(shell);
        defer res.deinit();
        const result = try setup(
            alloc,
            res.path,
            .{ .shell = "sh" },
            &env,
            shell,
        );
        try testing.expectEqual(shell, result.?.shell);
    }
}
test "shell integration failure" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = EnvMap.init(alloc);
    defer env.deinit();
    const result = try setup(
        alloc,
        "/nonexistent",
        .{ .shell = "sh" },
        &env,
        null,
    );
    try testing.expect(result == null);
    try testing.expectEqual(0, env.count());
}
fn detectShell(alloc: Allocator, command: config.Command) !?Shell {
    var arg_iter = try command.argIterator(alloc);
    defer arg_iter.deinit();
    const arg0 = arg_iter.next() orelse return null;
    const exe = std.fs.path.basename(arg0);
    if (std.mem.eql(u8, "bash", exe)) {
        if (comptime builtin.target.os.tag.isDarwin()) {
            if (std.mem.eql(u8, "/bin/bash", arg0)) {
                return null;
            }
        }
        return .bash;
    }
    if (std.mem.eql(u8, "elvish", exe)) return .elvish;
    if (std.mem.eql(u8, "fish", exe)) return .fish;
    if (std.mem.eql(u8, "nu", exe)) return .nushell;
    if (std.mem.eql(u8, "zsh", exe)) return .zsh;
    return null;
}
test detectShell {
    const testing = std.testing;
    const alloc = testing.allocator;
    try testing.expect(try detectShell(alloc, .{ .shell = "sh" }) == null);
    try testing.expectEqual(.bash, try detectShell(alloc, .{ .shell = "bash" }));
    try testing.expectEqual(.elvish, try detectShell(alloc, .{ .shell = "elvish" }));
    try testing.expectEqual(.fish, try detectShell(alloc, .{ .shell = "fish" }));
    try testing.expectEqual(.nushell, try detectShell(alloc, .{ .shell = "nu" }));
    try testing.expectEqual(.zsh, try detectShell(alloc, .{ .shell = "zsh" }));
    if (comptime builtin.target.os.tag.isDarwin()) {
        try testing.expect(try detectShell(alloc, .{ .shell = "/bin/bash" }) == null);
    }
    try testing.expectEqual(.bash, try detectShell(alloc, .{ .shell = "bash -c 'command'" }));
    try testing.expectEqual(.bash, try detectShell(alloc, .{ .shell = "\"/a b/bash\"" }));
}
pub fn setupFeatures(
    env: *EnvMap,
    features: config.ShellIntegrationFeatures,
    cursor_blink: bool,
) !void {
    const fields = @typeInfo(@TypeOf(features)).@"struct".fields;
    const capacity: usize = capacity: {
        comptime var n: usize = fields.len - 1;
        inline for (fields) |field| n += field.name.len;
        n += ":steady".len;
        break :capacity n;
    };
    var buf: [capacity]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const fields_sorted: [fields.len][]const u8 = comptime fields: {
        var fields_sorted: [fields.len][]const u8 = undefined;
        for (fields, 0..) |field, i| fields_sorted[i] = field.name;
        std.mem.sortUnstable(
            []const u8,
            &fields_sorted,
            {},
            (struct {
                fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                    return std.ascii.orderIgnoreCase(lhs, rhs) == .lt;
                }
            }).lessThan,
        );
        break :fields fields_sorted;
    };
    inline for (fields_sorted) |name| {
        if (@field(features, name)) {
            if (writer.end > 0) try writer.writeByte(',');
            try writer.writeAll(name);
            if (std.mem.eql(u8, name, "cursor")) {
                try writer.writeAll(if (cursor_blink) ":blink" else ":steady");
            }
        }
    }
    if (writer.end > 0) {
        try env.put("WASP_SHELL_FEATURES", buf[0..writer.end]);
    }
}
test "setup features" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();
        try setupFeatures(&env, .{ .cursor = true, .sudo = true, .title = true, .@"ssh-env" = true, .@"ssh-terminfo" = true, .path = true }, true);
        try testing.expectEqualStrings("cursor:blink,path,ssh-env,ssh-terminfo,sudo,title", env.get("WASP_SHELL_FEATURES").?);
    }
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();
        try setupFeatures(&env, std.mem.zeroes(config.ShellIntegrationFeatures), true);
        try testing.expect(env.get("WASP_SHELL_FEATURES") == null);
    }
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();
        try setupFeatures(&env, .{ .cursor = false, .sudo = true, .title = false, .@"ssh-env" = true, .@"ssh-terminfo" = false, .path = false }, true);
        try testing.expectEqualStrings("ssh-env,sudo", env.get("WASP_SHELL_FEATURES").?);
    }
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();
        try setupFeatures(&env, .{ .cursor = true, .sudo = false, .title = false, .@"ssh-env" = false, .@"ssh-terminfo" = false, .path = false }, true);
        try testing.expectEqualStrings("cursor:blink", env.get("WASP_SHELL_FEATURES").?);
    }
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();
        try setupFeatures(&env, .{ .cursor = true, .sudo = false, .title = false, .@"ssh-env" = false, .@"ssh-terminfo" = false, .path = false }, false);
        try testing.expectEqualStrings("cursor:steady", env.get("WASP_SHELL_FEATURES").?);
    }
}
fn setupBash(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
    env: *EnvMap,
) !?config.Command {
    var stack_fallback = std.heap.stackFallback(4096, alloc);
    var cmd = internal_os.shell.ShellCommandBuilder.init(stack_fallback.get());
    defer cmd.deinit();
    var iter = try command.argIterator(alloc);
    defer iter.deinit();
    if (iter.next()) |exe| {
        try cmd.appendArg(exe);
    } else return null;
    try cmd.appendArg("--posix");
    var buf: [32]u8 = undefined;
    var inject: std.Io.Writer = .fixed(&buf);
    try inject.writeAll("1");
    var rcfile: ?[]const u8 = null;
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--posix")) {
            return null;
        } else if (std.mem.eql(u8, arg, "--norc")) {
            try inject.writeAll(" --norc");
        } else if (std.mem.eql(u8, arg, "--noprofile")) {
            try inject.writeAll(" --noprofile");
        } else if (std.mem.eql(u8, arg, "--rcfile") or std.mem.eql(u8, arg, "--init-file")) {
            rcfile = iter.next();
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            if (std.mem.indexOfScalar(u8, arg, 'c') != null) {
                return null;
            }
            try cmd.appendArg(arg);
        } else if (std.mem.eql(u8, arg, "-") or std.mem.eql(u8, arg, "--")) {
            try cmd.appendArg(arg);
            while (iter.next()) |remaining_arg| {
                try cmd.appendArg(remaining_arg);
            }
            break;
        } else {
            try cmd.appendArg(arg);
        }
    }
    if (env.get("ENV")) |v| {
        try env.put("WASP_BASH_ENV", v);
    }
    var script_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const script_path = try std.fmt.bufPrint(
        &script_path_buf,
        "{s}/shell-integration/bash/wasp.bash",
        .{resource_dir},
    );
    if (std.Io.Dir.openFileAbsolute(global.io(), script_path, .{})) |file| {
        file.close(global.io());
        try env.put("ENV", script_path);
    } else |err| {
        log.warn("unable to open {s}: {}", .{ script_path, err });
        _ = env.swapRemove("WASP_BASH_ENV");
        return null;
    }
    try env.put("WASP_BASH_INJECT", buf[0..inject.end]);
    if (rcfile) |v| {
        try env.put("WASP_BASH_RCFILE", v);
    }
    if (env.get("HISTFILE") == null) {
        var environ_map = try global.environMap();
        defer environ_map.deinit();
        var home_buf: [1024]u8 = undefined;
        if (try homedir.home(global.io(), &environ_map, &home_buf)) |home| {
            var histfile_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const histfile = try std.fmt.bufPrint(
                &histfile_buf,
                "{s}/.bash_history",
                .{home},
            );
            try env.put("HISTFILE", histfile);
            try env.put("WASP_BASH_UNEXPORT_HISTFILE", "1");
        }
    }
    return .{ .shell = try alloc.dupeZ(u8, cmd.buffer.written()) };
}
test "bash" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();
    var env = EnvMap.init(alloc);
    defer env.deinit();
    const command = try setupBash(alloc, .{ .shell = "bash" }, res.path, &env);
    try testing.expectEqualStrings("bash --posix", command.?.shell);
    try testing.expectEqualStrings("1", env.get("WASP_BASH_INJECT").?);
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&path_buf, "{s}/wasp.bash", .{res.shell_path}),
        env.get("ENV").?,
    );
}
test "bash: unsupported options" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();
    const cmdlines = [_][:0]const u8{
        "bash --posix",
        "bash --rcfile script.sh --posix",
        "bash --init-file script.sh --posix",
        "bash -c script.sh",
        "bash -ic script.sh",
    };
    for (cmdlines) |cmdline| {
        var env = EnvMap.init(alloc);
        defer env.deinit();
        try testing.expect(try setupBash(alloc, .{ .shell = cmdline }, res.path, &env) == null);
        try testing.expectEqual(0, env.count());
    }
}
test "bash: inject flags" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();
        const command = try setupBash(alloc, .{ .shell = "bash --norc" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix", command.?.shell);
        try testing.expectEqualStrings("1 --norc", env.get("WASP_BASH_INJECT").?);
    }
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();
        const command = try setupBash(alloc, .{ .shell = "bash --noprofile" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix", command.?.shell);
        try testing.expectEqualStrings("1 --noprofile", env.get("WASP_BASH_INJECT").?);
    }
}
test "bash: rcfile" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();
    var env = EnvMap.init(alloc);
    defer env.deinit();
    {
        const command = try setupBash(alloc, .{ .shell = "bash --rcfile profile.sh" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix", command.?.shell);
        try testing.expectEqualStrings("profile.sh", env.get("WASP_BASH_RCFILE").?);
    }
    {
        const command = try setupBash(alloc, .{ .shell = "bash --init-file profile.sh" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix", command.?.shell);
        try testing.expectEqualStrings("profile.sh", env.get("WASP_BASH_RCFILE").?);
    }
}
test "bash: HISTFILE" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();
        _ = try setupBash(alloc, .{ .shell = "bash" }, res.path, &env);
        try testing.expect(std.mem.endsWith(u8, env.get("HISTFILE").?, ".bash_history"));
        try testing.expectEqualStrings("1", env.get("WASP_BASH_UNEXPORT_HISTFILE").?);
    }
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();
        try env.put("HISTFILE", "my_history");
        _ = try setupBash(alloc, .{ .shell = "bash" }, res.path, &env);
        try testing.expectEqualStrings("my_history", env.get("HISTFILE").?);
        try testing.expect(env.get("WASP_BASH_UNEXPORT_HISTFILE") == null);
    }
}
test "bash: ENV" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();
    var env = EnvMap.init(alloc);
    defer env.deinit();
    try env.put("ENV", "env.sh");
    _ = try setupBash(alloc, .{ .shell = "bash" }, res.path, &env);
    try testing.expectEqualStrings("env.sh", env.get("WASP_BASH_ENV").?);
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&path_buf, "{s}/wasp.bash", .{res.shell_path}),
        env.get("ENV").?,
    );
}
test "bash: additional arguments" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var res: TmpResourcesDir = try .init(.bash);
    defer res.deinit();
    var env = EnvMap.init(alloc);
    defer env.deinit();
    {
        const command = try setupBash(alloc, .{ .shell = "bash - --arg file1 file2" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix - --arg file1 file2", command.?.shell);
    }
    {
        const command = try setupBash(alloc, .{ .shell = "bash -- --arg file1 file2" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix -- --arg file1 file2", command.?.shell);
    }
}
test "bash: missing resources" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const resources_dir = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(resources_dir);
    var env = EnvMap.init(alloc);
    defer env.deinit();
    try testing.expect(try setupBash(alloc, .{ .shell = "bash" }, resources_dir, &env) == null);
    try testing.expectEqual(0, env.count());
}
fn setupXdgDataDirs(
    alloc: Allocator,
    resource_dir: []const u8,
    env: *EnvMap,
) !bool {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const integ_path = try std.fmt.bufPrint(
        &path_buf,
        "{s}/shell-integration",
        .{resource_dir},
    );
    var integ_dir = std.Io.Dir.openDirAbsolute(
        global.io(),
        integ_path,
        .{},
    ) catch |err| {
        log.warn("unable to open {s}: {}", .{ integ_path, err });
        return false;
    };
    integ_dir.close(global.io());
    try env.put("WASP_SHELL_INTEGRATION_XDG_DIR", integ_path);
    var stack_alloc_state = std.heap.stackFallback(4096, alloc);
    const stack_alloc = stack_alloc_state.get();
    const xdg_data_dirs_key = "XDG_DATA_DIRS";
    try env.put(
        xdg_data_dirs_key,
        try prependEnv(
            stack_alloc,
            env.get(xdg_data_dirs_key) orelse "/usr/local/share:/usr/share",
            integ_path,
        ),
    );
    return true;
}
fn prependEnv(
    alloc: Allocator,
    current: []const u8,
    value: []const u8,
) Allocator.Error![]u8 {
    if (current.len == 0) return try alloc.dupe(u8, value);
    return try std.fmt.allocPrint(alloc, "{s}{c}{s}", .{
        value,
        std.fs.path.delimiter,
        current,
    });
}
test "xdg: empty XDG_DATA_DIRS" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var res: TmpResourcesDir = try .init(.fish);
    defer res.deinit();
    var env = EnvMap.init(alloc);
    defer env.deinit();
    try testing.expect(try setupXdgDataDirs(alloc, res.path, &env));
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&path_buf, "{s}/shell-integration", .{res.path}),
        env.get("WASP_SHELL_INTEGRATION_XDG_DIR").?,
    );
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&path_buf, "{s}/shell-integration:/usr/local/share:/usr/share", .{res.path}),
        env.get("XDG_DATA_DIRS").?,
    );
}
test "xdg: existing XDG_DATA_DIRS" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var res: TmpResourcesDir = try .init(.fish);
    defer res.deinit();
    var env = EnvMap.init(alloc);
    defer env.deinit();
    try env.put("XDG_DATA_DIRS", "/opt/share");
    try testing.expect(try setupXdgDataDirs(alloc, res.path, &env));
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&path_buf, "{s}/shell-integration", .{res.path}),
        env.get("WASP_SHELL_INTEGRATION_XDG_DIR").?,
    );
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&path_buf, "{s}/shell-integration:/opt/share", .{res.path}),
        env.get("XDG_DATA_DIRS").?,
    );
}
test "xdg: missing resources" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const resources_dir = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(resources_dir);
    var env = EnvMap.init(alloc);
    defer env.deinit();
    try testing.expect(!try setupXdgDataDirs(alloc, resources_dir, &env));
    try testing.expectEqual(0, env.count());
}
fn setupNushell(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
    env: *EnvMap,
) !?config.Command {
    if (!try setupXdgDataDirs(alloc, resource_dir, env)) return null;
    var stack_fallback = std.heap.stackFallback(4096, alloc);
    var cmd = internal_os.shell.ShellCommandBuilder.init(stack_fallback.get());
    defer cmd.deinit();
    var iter = try command.argIterator(alloc);
    defer iter.deinit();
    if (iter.next()) |exe| {
        try cmd.appendArg(exe);
    } else return null;
    try cmd.appendArg("--execute 'use wasp *'");
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--command") or std.mem.eql(u8, arg, "--lsp")) {
            return null;
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            if (std.mem.indexOfScalar(u8, arg, 'c') != null) {
                return null;
            }
            try cmd.appendArg(arg);
        } else if (std.mem.eql(u8, arg, "-") or std.mem.eql(u8, arg, "--")) {
            try cmd.appendArg(arg);
            while (iter.next()) |remaining_arg| {
                try cmd.appendArg(remaining_arg);
            }
            break;
        } else {
            try cmd.appendArg(arg);
        }
    }
    return .{ .shell = try alloc.dupeZ(u8, cmd.buffer.written()) };
}
test "nushell" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var res: TmpResourcesDir = try .init(.nushell);
    defer res.deinit();
    var env = EnvMap.init(alloc);
    defer env.deinit();
    const command = try setupNushell(alloc, .{ .shell = "nu" }, res.path, &env);
    try testing.expectEqualStrings("nu --execute 'use wasp *'", command.?.shell);
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&path_buf, "{s}/shell-integration", .{res.path}),
        env.get("WASP_SHELL_INTEGRATION_XDG_DIR").?,
    );
    try testing.expectStringStartsWith(
        env.get("XDG_DATA_DIRS").?,
        try std.fmt.bufPrint(&path_buf, "{s}/shell-integration", .{res.path}),
    );
}
test "nushell: unsupported options" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var res: TmpResourcesDir = try .init(.nushell);
    defer res.deinit();
    const cmdlines = [_][:0]const u8{
        "nu --command exit",
        "nu --lsp",
        "nu -c script.sh",
        "nu -ic script.sh",
    };
    for (cmdlines) |cmdline| {
        var env = EnvMap.init(alloc);
        defer env.deinit();
        try testing.expect(try setupNushell(alloc, .{ .shell = cmdline }, res.path, &env) == null);
        try testing.expect(env.get("XDG_DATA_DIRS") != null);
        try testing.expect(env.get("WASP_SHELL_INTEGRATION_XDG_DIR") != null);
    }
}
test "nushell: missing resources" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const resources_dir = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(resources_dir);
    var env = EnvMap.init(alloc);
    defer env.deinit();
    try testing.expect(try setupNushell(alloc, .{ .shell = "nu" }, resources_dir, &env) == null);
    try testing.expectEqual(0, env.count());
}
fn setupZsh(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
    env: *EnvMap,
) !?config.Command {
    if (env.get("ZDOTDIR")) |old| {
        try env.put("WASP_ZSH_ZDOTDIR", old);
    }
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const integ_path = try std.fmt.bufPrint(
        &path_buf,
        "{s}/shell-integration/zsh",
        .{resource_dir},
    );
    var integ_dir = std.Io.Dir.openDirAbsolute(
        global.io(),
        integ_path,
        .{},
    ) catch |err| {
        log.warn("unable to open {s}: {}", .{ integ_path, err });
        return null;
    };
    integ_dir.close(global.io());
    try env.put("ZDOTDIR", integ_path);
    return try command.clone(alloc);
}
test "zsh" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var res: TmpResourcesDir = try .init(.zsh);
    defer res.deinit();
    var env = EnvMap.init(testing.allocator);
    defer env.deinit();
    const command = try setupZsh(alloc, .{ .shell = "zsh" }, res.path, &env);
    try testing.expectEqualStrings("zsh", command.?.shell);
    try testing.expectEqualStrings(res.shell_path, env.get("ZDOTDIR").?);
    try testing.expect(env.get("WASP_ZSH_ZDOTDIR") == null);
}
test "zsh: ZDOTDIR" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var res: TmpResourcesDir = try .init(.zsh);
    defer res.deinit();
    var env = EnvMap.init(testing.allocator);
    defer env.deinit();
    try env.put("ZDOTDIR", "$HOME/.config/zsh");
    const command = try setupZsh(alloc, .{ .shell = "zsh" }, res.path, &env);
    try testing.expectEqualStrings("zsh", command.?.shell);
    try testing.expectEqualStrings(res.shell_path, env.get("ZDOTDIR").?);
    try testing.expectEqualStrings("$HOME/.config/zsh", env.get("WASP_ZSH_ZDOTDIR").?);
}
test "zsh: missing resources" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const resources_dir = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(resources_dir);
    var env = EnvMap.init(alloc);
    defer env.deinit();
    try testing.expect(try setupZsh(alloc, .{ .shell = "zsh" }, resources_dir, &env) == null);
    try testing.expectEqual(0, env.count());
}
const TmpResourcesDir = struct {
    tmp_dir: std.testing.TmpDir,
    path: [:0]const u8,
    shell_path: []const u8,
    fn init(shell: Shell) !TmpResourcesDir {
        var tmp_dir = std.testing.tmpDir(.{});
        errdefer tmp_dir.cleanup();
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const relative_shell_path = try std.fmt.bufPrint(
            &path_buf,
            "shell-integration/{s}",
            .{@tagName(shell)},
        );
        try tmp_dir.dir.createDirPath(std.testing.io, relative_shell_path);
        const path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        errdefer std.testing.allocator.free(path);
        const shell_path = try std.fmt.allocPrint(
            std.testing.allocator,
            "{s}/{s}",
            .{ path, relative_shell_path },
        );
        errdefer std.testing.allocator.free(shell_path);
        switch (shell) {
            .bash => try tmp_dir.dir.writeFile(std.testing.io, .{
                .sub_path = "shell-integration/bash/wasp.bash",
                .data = "",
            }),
            else => {},
        }
        return .{
            .tmp_dir = tmp_dir,
            .path = path,
            .shell_path = shell_path,
        };
    }
    fn deinit(self: *TmpResourcesDir) void {
        std.testing.allocator.free(self.shell_path);
        std.testing.allocator.free(self.path);
        self.tmp_dir.cleanup();
    }
};
