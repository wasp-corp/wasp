const std = @import("std");
const build_info = @import("info.zig");
pub const ui_path = "src/app/rt/gtk/ui";
pub const css_path = "src/app/rt/gtk/css";
pub const icon_sizes: []const comptime_int = &.{ 16, 32, 128, 256, 512, 1024 };
pub const minimum_adwaita: struct { major: u16, minor: u16 } = .{
    .major = 1,
    .minor = 7,
};
pub const blueprints: []const Blueprint = &.{
    .{ .major = 1, .minor = 0, .name = "imgui-widget" },
    .{ .major = 1, .minor = 0, .name = "inspector-widget" },
    .{ .major = 1, .minor = 0, .name = "key-state-overlay" },
    .{ .major = 1, .minor = 0, .name = "resize-overlay" },
    .{ .major = 1, .minor = 0, .name = "search-overlay" },
    .{ .major = 1, .minor = 0, .name = "split-tree" },
    .{ .major = 1, .minor = 0, .name = "split-tree-split" },
    .{ .major = 1, .minor = 0, .name = "surface" },
    .{ .major = 1, .minor = 0, .name = "surface-scrolled-window" },
    .{ .major = 1, .minor = 0, .name = "tab" },
    .{ .major = 1, .minor = 3, .name = "debug-warning" },
    .{ .major = 1, .minor = 3, .name = "surface-child-exited" },
    .{ .major = 1, .minor = 4, .name = "inspector-window" },
    .{ .major = 1, .minor = 4, .name = "window" },
    .{ .major = 1, .minor = 5, .name = "clipboard-confirmation-dialog" },
    .{ .major = 1, .minor = 5, .name = "close-confirmation-dialog" },
    .{ .major = 1, .minor = 5, .name = "command-palette" },
    .{ .major = 1, .minor = 5, .name = "config-errors-dialog" },
    .{ .major = 1, .minor = 5, .name = "title-dialog" },
};
pub const css = [_][]const u8{
    "style.css",
};
pub const Blueprint = struct {
    major: u16,
    minor: u16,
    name: []const u8,
};
pub const file_inputs = deps: {
    const total = (icon_sizes.len * 2) + blueprints.len + css.len;
    var deps: [total][]const u8 = undefined;
    var index: usize = 0;
    for (icon_sizes) |size| {
        deps[index] = std.fmt.comptimePrint("images/gnome/{d}.png", .{size});
        deps[index + 1] = std.fmt.comptimePrint("images/gnome/{d}.png", .{size * 2});
        index += 2;
    }
    for (blueprints) |bp| {
        deps[index] = std.fmt.comptimePrint("{s}/{d}.{d}/{s}.blp", .{
            ui_path,
            bp.major,
            bp.minor,
            bp.name,
        });
        index += 1;
    }
    for (css) |name| {
        deps[index] = std.fmt.comptimePrint("{s}/{s}", .{ css_path, name });
        index += 1;
    }
    break :deps deps;
};
pub fn blueprint(comptime bp: Blueprint) [:0]const u8 {
    comptime {
        for (blueprints) |candidate| {
            if (candidate.major == bp.major and
                candidate.minor == bp.minor and
                std.mem.eql(u8, candidate.name, bp.name))
            {
                return std.fmt.comptimePrint("{s}/ui/{d}.{d}/{s}.ui", .{
                    build_info.resource_path,
                    candidate.major,
                    candidate.minor,
                    candidate.name,
                });
            }
        }
        @compileError("invalid blueprint");
    }
}
pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    const writer = &stdout.interface;
    try writer.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<gresources>
        \\
    );
    try genRoot(init.io, writer);
    try genIcons(init.io, writer);
    try genUi(init.io, writer);
    try writer.writeAll(
        \\</gresources>
        \\
    );
    try stdout.end();
}
fn genIcons(io: std.Io, writer: *std.Io.Writer) !void {
    try writer.print(
        \\  <gresource prefix="{s}/icons">
        \\
    , .{build_info.resource_path});
    const cwd: std.Io.Dir = .cwd();
    inline for (icon_sizes) |size| {
        {
            const alias = std.fmt.comptimePrint("{d}x{d}", .{ size, size });
            const source = std.fmt.comptimePrint("images/gnome/{d}.png", .{size});
            try cwd.access(io, source, .{});
            try writer.print(
                \\    <file alias="{s}/apps/{s}.png">{s}</file>
                \\
            ,
                .{ alias, build_info.base_application_id, source },
            );
        }
        {
            const alias = std.fmt.comptimePrint("{d}x{d}@2", .{ size, size });
            const source = std.fmt.comptimePrint("images/gnome/{d}.png", .{size * 2});
            try cwd.access(io, source, .{});
            try writer.print(
                \\    <file alias="{s}/apps/{s}.png">{s}</file>
                \\
            ,
                .{ alias, build_info.base_application_id, source },
            );
        }
    }
    try writer.writeAll(
        \\  </gresource>
        \\
    );
}
fn genRoot(io: std.Io, writer: *std.Io.Writer) !void {
    try writer.print(
        \\  <gresource prefix="{s}">
        \\
    , .{build_info.resource_path});
    const cwd: std.Io.Dir = .cwd();
    inline for (css) |name| {
        const source = std.fmt.comptimePrint(
            "{s}/{s}",
            .{ css_path, name },
        );
        try cwd.access(io, source, .{});
        try writer.print(
            \\    <file compressed="true" alias="{s}">{s}</file>
            \\
        ,
            .{ name, source },
        );
    }
    try writer.writeAll(
        \\  </gresource>
        \\
    );
}
fn genUi(io: std.Io, writer: *std.Io.Writer) !void {
    @setEvalBranchQuota(100_000);
    try writer.print(
        \\  <gresource prefix="{s}/ui">
        \\
    , .{build_info.resource_path});
    const cwd: std.Io.Dir = .cwd();
    inline for (blueprints) |bp| {
        const source = std.fmt.comptimePrint("{s}/{d}.{d}/{s}.blp", .{
            ui_path,
            bp.major,
            bp.minor,
            bp.name,
        });
        try cwd.access(io, source, .{});
        const alias = std.fmt.comptimePrint("{d}.{d}/{s}.ui", .{
            bp.major,
            bp.minor,
            bp.name,
        });
        try writer.print(
            \\    <file compressed="true" preprocess="xml-stripblanks" alias="{s}">{s}</file>
            \\
        , .{ alias, alias });
    }
    try writer.writeAll(
        \\  </gresource>
        \\
    );
}
