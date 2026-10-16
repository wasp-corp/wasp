const std = @import("std");
const Allocator = std.mem.Allocator;
const help_strings = @import("help_strings");
const actionpkg = @import("action.zig");
const SpecialCase = actionpkg.SpecialCase;
const list_fonts = @import("list_fonts.zig");
const help = @import("help.zig");
const version = @import("version.zig");
const list_keybinds = @import("list_keybinds.zig");
const list_themes = @import("list_themes.zig");
const list_colors = @import("list_colors.zig");
const list_actions = @import("list_actions.zig");
const ssh = @import("ssh.zig");
const ssh_cache = @import("ssh_cache.zig");
const edit_config = @import("edit_config.zig");
const show_config = @import("show_config.zig");
const explain_config = @import("explain_config.zig");
const validate_config = @import("validate_config.zig");
const crash_report = @import("crash_report.zig");
const show_face = @import("show_face.zig");
const boo = @import("boo.zig");
const new_window = @import("new_window.zig");
const new_tab = @import("new_tab.zig");
const toggle_quick_terminal = @import("toggle_quick_terminal.zig");
const global = @import("../global.zig");
pub const Action = enum {
    version,
    help,
    @"list-fonts",
    @"list-keybinds",
    @"list-themes",
    @"list-colors",
    @"list-actions",
    ssh,
    @"ssh-cache",
    @"edit-config",
    @"show-config",
    @"explain-config",
    @"validate-config",
    @"show-face",
    @"crash-report",
    boo,
    @"new-window",
    @"new-tab",
    @"toggle-quick-terminal",
    pub fn detectSpecialCase(arg: []const u8) ?SpecialCase(Action) {
        if (std.mem.eql(u8, arg, "-e")) return .abort_if_no_action;
        if (std.mem.eql(u8, arg, "--version")) {
            return .{ .action = .version };
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .{ .fallback = .help };
        }
        return null;
    }
    pub const help_error = error.ActionHelpRequested;
    pub fn run(self: Action, alloc: Allocator) !u8 {
        return self.runMain(alloc) catch |err| switch (err) {
            help_error => err: {
                inline for (@typeInfo(Action).@"enum".fields) |field| {
                    if (std.mem.eql(u8, field.name, @tagName(self))) {
                        var buffer: [1024]u8 = undefined;
                        var stdout_writer = std.Io.File.stdout().writer(
                            global.io(),
                            &buffer,
                        );
                        const stdout = &stdout_writer.interface;
                        const text = @field(help_strings.Action, field.name) ++ "\n";
                        stdout.writeAll(text) catch |write_err| {
                            std.log.warn("failed to write help text: {}\n", .{write_err});
                            break :err 1;
                        };
                        stdout.flush() catch |flush_err| {
                            std.log.warn("failed to flush help text: {}\n", .{flush_err});
                            break :err 1;
                        };
                        break :err 0;
                    }
                }
                break :err err;
            },
            else => err,
        };
    }
    fn runMain(self: Action, alloc: Allocator) !u8 {
        return switch (self) {
            .version => try version.run(alloc),
            .help => try help.run(alloc),
            .@"list-fonts" => try list_fonts.run(alloc),
            .@"list-keybinds" => try list_keybinds.run(alloc),
            .@"list-themes" => try list_themes.run(alloc),
            .@"list-colors" => try list_colors.run(alloc),
            .@"list-actions" => try list_actions.run(alloc),
            .@"ssh-cache" => try ssh_cache.run(alloc),
            .ssh => try ssh.run(alloc),
            .@"edit-config" => try edit_config.run(alloc),
            .@"show-config" => try show_config.run(alloc),
            .@"explain-config" => try explain_config.run(alloc),
            .@"validate-config" => try validate_config.run(alloc),
            .@"crash-report" => try crash_report.run(alloc),
            .@"show-face" => try show_face.run(alloc),
            .boo => try boo.run(alloc),
            .@"new-window" => try new_window.run(alloc),
            .@"new-tab" => try new_tab.run(alloc),
            .@"toggle-quick-terminal" => try toggle_quick_terminal.run(alloc),
        };
    }
    pub fn file(comptime self: Action) []const u8 {
        comptime {
            const filename = filename: {
                const tag = @tagName(self);
                var filename: [tag.len]u8 = undefined;
                _ = std.mem.replace(u8, tag, "-", "_", &filename);
                break :filename &filename;
            };
            return "cli/" ++ filename ++ ".zig";
        }
    }
    pub fn options(comptime self: Action) type {
        comptime {
            return switch (self) {
                .version => version.Options,
                .help => help.Options,
                .@"list-fonts" => list_fonts.Options,
                .@"list-keybinds" => list_keybinds.Options,
                .@"list-themes" => list_themes.Options,
                .@"list-colors" => list_colors.Options,
                .@"list-actions" => list_actions.Options,
                .@"ssh-cache" => ssh_cache.Options,
                .ssh => ssh.Options,
                .@"edit-config" => edit_config.Options,
                .@"show-config" => show_config.Options,
                .@"explain-config" => explain_config.Options,
                .@"validate-config" => validate_config.Options,
                .@"crash-report" => crash_report.Options,
                .@"show-face" => show_face.Options,
                .boo => boo.Options,
                .@"new-window" => new_window.Options,
                .@"new-tab" => new_tab.Options,
                .@"toggle-quick-terminal" => toggle_quick_terminal.Options,
            };
        }
    }
};
test "parse action none" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var iter = try std.process.Args.IteratorGeneral(.{}).init(
        alloc,
        "--a=42 --b --b-f=false",
    );
    defer iter.deinit();
    const action = try actionpkg.detectIter(Action, &iter);
    try testing.expect(action == null);
}
test "parse action version" {
    const testing = std.testing;
    const alloc = testing.allocator;
    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--a=42 --b --b-f=false --version",
        );
        defer iter.deinit();
        const action = try actionpkg.detectIter(Action, &iter);
        try testing.expect(action.? == .version);
    }
    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--version --a=42 --b --b-f=false",
        );
        defer iter.deinit();
        const action = try actionpkg.detectIter(Action, &iter);
        try testing.expect(action.? == .version);
    }
    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--c=84 --d --version --a=42 --b --b-f=false",
        );
        defer iter.deinit();
        const action = try actionpkg.detectIter(Action, &iter);
        try testing.expect(action.? == .version);
    }
}
test "parse action plus" {
    const testing = std.testing;
    const alloc = testing.allocator;
    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--a=42 --b --b-f=false +version",
        );
        defer iter.deinit();
        const action = try actionpkg.detectIter(Action, &iter);
        try testing.expect(action.? == .version);
    }
    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "+version --a=42 --b --b-f=false",
        );
        defer iter.deinit();
        const action = try actionpkg.detectIter(Action, &iter);
        try testing.expect(action.? == .version);
    }
    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--c=84 --d +version --a=42 --b --b-f=false",
        );
        defer iter.deinit();
        const action = try actionpkg.detectIter(Action, &iter);
        try testing.expect(action.? == .version);
    }
}
test "parse action plus ignores -e" {
    const testing = std.testing;
    const alloc = testing.allocator;
    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--a=42 -e +version",
        );
        defer iter.deinit();
        const action = try actionpkg.detectIter(Action, &iter);
        try testing.expect(action == null);
    }
    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "+list-fonts --a=42 -e +version",
        );
        defer iter.deinit();
        try testing.expectError(
            actionpkg.DetectError.MultipleActions,
            actionpkg.detectIter(Action, &iter),
        );
    }
}
