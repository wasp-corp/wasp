const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/root.zig");
const cli = @import("../cli.zig");
const global = @import("../global.zig");
pub const Location = enum {
    user,
    resources,
    pub fn dir(
        self: Location,
        arena_alloc: Allocator,
    ) error{ OutOfMemory, Unexpected }!?[]const u8 {
        var environ_map = try global.environMap();
        defer environ_map.deinit();
        return switch (self) {
            .user => user: {
                const subdir = std.fs.path.join(arena_alloc, &.{
                    "wasp", "themes",
                }) catch return error.OutOfMemory;
                break :user internal_os.xdg.config(
                    global.io(),
                    arena_alloc,
                    &environ_map,
                    .{ .subdir = subdir },
                ) catch |err| {
                    const Error = @TypeOf(err) || switch (builtin.os.tag) {
                        .ios => error{BufferTooSmall},
                        else => error{},
                    };
                    switch (@as(Error, err)) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.BufferTooSmall => return error.OutOfMemory,
                        else => return null,
                    }
                };
            },
            .resources => try std.fs.path.join(arena_alloc, &.{
                global.resourcesDir().app() orelse return null,
                "themes",
            }),
        };
    }
};
pub const LocationIterator = struct {
    arena_alloc: Allocator,
    i: usize = 0,
    pub fn next(self: *LocationIterator) !?struct {
        location: Location,
        dir: []const u8,
    } {
        const max = @typeInfo(Location).@"enum".fields.len;
        while (self.i < max) {
            const location: Location = @enumFromInt(self.i);
            self.i += 1;
            if (try location.dir(self.arena_alloc)) |dir|
                return .{
                    .location = location,
                    .dir = dir,
                };
        }
        return null;
    }
    pub fn reset(self: *LocationIterator) void {
        self.i = 0;
    }
};
pub fn open(
    arena_alloc: Allocator,
    theme: []const u8,
    diags: *cli.DiagnosticList,
) error{ OutOfMemory, Unexpected }!?struct {
    path: []const u8,
    file: std.Io.File,
} {
    if (std.fs.path.isAbsolute(theme)) {
        const file: std.Io.File = try openAbsolute(
            arena_alloc,
            theme,
            diags,
        ) orelse return null;
        const stat = file.stat(global.io()) catch |err| {
            try diags.append(arena_alloc, .{
                .message = try std.fmt.allocPrintSentinel(
                    arena_alloc,
                    "not reading theme from \"{s}\": {}",
                    .{ theme, err },
                    0,
                ),
            });
            return null;
        };
        switch (stat.kind) {
            .file => {},
            else => {
                try diags.append(arena_alloc, .{
                    .message = try std.fmt.allocPrintSentinel(
                        arena_alloc,
                        "not reading theme from \"{s}\": it is a {s}",
                        .{ theme, @tagName(stat.kind) },
                        0,
                    ),
                });
                return null;
            },
        }
        return .{ .path = theme, .file = file };
    }
    const basename = std.fs.path.basename(theme);
    if (!std.mem.eql(u8, theme, basename)) {
        try diags.append(arena_alloc, .{
            .message = try std.fmt.allocPrintSentinel(
                arena_alloc,
                "theme \"{s}\" cannot include path separators unless it is an absolute path",
                .{theme},
                0,
            ),
        });
        return null;
    }
    var it: LocationIterator = .{ .arena_alloc = arena_alloc };
    const cwd = std.Io.Dir.cwd();
    while (try it.next()) |loc| {
        const path = try std.fs.path.join(arena_alloc, &.{ loc.dir, theme });
        if (cwd.openFile(global.io(), path, .{})) |file| {
            const stat = file.stat(global.io()) catch |err| {
                try diags.append(arena_alloc, .{
                    .message = try std.fmt.allocPrintSentinel(
                        arena_alloc,
                        "not reading theme from \"{s}\": {}",
                        .{ theme, err },
                        0,
                    ),
                });
                return null;
            };
            switch (stat.kind) {
                .file => {},
                else => {
                    try diags.append(arena_alloc, .{
                        .message = try std.fmt.allocPrintSentinel(
                            arena_alloc,
                            "not reading theme from \"{s}\": it is a {s}",
                            .{ theme, @tagName(stat.kind) },
                            0,
                        ),
                    });
                    return null;
                },
            }
            return .{
                .path = path,
                .file = file,
            };
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => {
                try diags.append(arena_alloc, .{
                    .message = try std.fmt.allocPrintSentinel(
                        arena_alloc,
                        "failed to load theme \"{s}\" from the file \"{s}\": {}",
                        .{ theme, path, err },
                        0,
                    ),
                });
                return null;
            },
        }
    }
    it.reset();
    while (try it.next()) |loc| {
        const path = try std.fs.path.join(arena_alloc, &.{ loc.dir, theme });
        try diags.append(arena_alloc, .{
            .message = try std.fmt.allocPrintSentinel(
                arena_alloc,
                "theme \"{s}\" not found, tried path \"{s}\"",
                .{ theme, path },
                0,
            ),
        });
    }
    return null;
}
pub fn openAbsolute(
    arena_alloc: Allocator,
    theme: []const u8,
    diags: *cli.DiagnosticList,
) error{OutOfMemory}!?std.Io.File {
    return std.Io.Dir.openFileAbsolute(global.io(), theme, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => try diags.append(arena_alloc, .{
                .message = try std.fmt.allocPrintSentinel(
                    arena_alloc,
                    "failed to load theme from the path \"{s}\"",
                    .{theme},
                    0,
                ),
            }),
            else => try diags.append(arena_alloc, .{
                .message = try std.fmt.allocPrintSentinel(
                    arena_alloc,
                    "failed to load theme from the path \"{s}\": {}",
                    .{ theme, err },
                    0,
                ),
            }),
        }
        return null;
    };
}
