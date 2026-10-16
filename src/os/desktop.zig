const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const global = @import("../global.zig");
const c = @import("posix_c");
pub fn launchedFromDesktop() bool {
    return switch (builtin.os.tag) {
        .macos => macos: {
            if (build_config.artifact == .lib) lib: {
                const env = "WASP_MAC_LAUNCH_SOURCE";
                const source = global.environ().getPosix(env) orelse break :lib;
                if (std.mem.eql(u8, source, "app")) break :macos true;
            }
            break :macos c.getppid() == 1;
        },
        .linux, .freebsd => ul: {
            const gio_pid_str = global.environ().getPosix("GIO_LAUNCHED_DESKTOP_FILE_PID") orelse
                break :ul false;
            const pid = c.getpid();
            const gio_pid = std.fmt.parseInt(
                @TypeOf(pid),
                gio_pid_str,
                10,
            ) catch break :ul false;
            break :ul gio_pid == pid;
        },
        .windows => false,
        .ios => true,
        else => @compileError("unsupported platform"),
    };
}
pub const DesktopEnvironment = enum {
    gnome,
    macos,
    other,
    windows,
};
pub fn desktopEnvironment(environ_map: *const std.process.Environ.Map) DesktopEnvironment {
    return switch (comptime builtin.os.tag) {
        .macos => .macos,
        .windows => .windows,
        .linux, .freebsd => de: {
            if (@inComptime()) @compileError("Checking for the desktop environment on Linux/BSD must be done at runtime.");
            if (environ_map.get("XDG_SESSION_DESKTOP")) |sd| {
                if (std.ascii.eqlIgnoreCase("gnome", sd)) break :de .gnome;
                if (std.ascii.eqlIgnoreCase("gnome-xorg", sd)) break :de .gnome;
            }
            if (environ_map.get("XDG_CURRENT_DESKTOP")) |cd| {
                var cd_it = std.mem.splitScalar(u8, cd, ':');
                const cd_first = cd_it.first();
                if (std.ascii.eqlIgnoreCase(cd_first, "gnome")) break :de .gnome;
            }
            break :de .other;
        },
        else => .other,
    };
}
test "desktop environment" {
    const testing = std.testing;
    switch (builtin.os.tag) {
        inline .macos, .windows => |tag| {
            var environ_map: std.process.Environ.Map = .init(testing.allocator);
            defer environ_map.deinit();
            try testing.expectEqual(@tagName(tag), @tagName(desktopEnvironment(&environ_map)));
        },
        .linux, .freebsd => {
            {
                var environ_map: std.process.Environ.Map = .init(testing.allocator);
                defer environ_map.deinit();
                try environ_map.put("XDG_SESSION_DESKTOP", "gnome");
                try testing.expectEqual(.gnome, desktopEnvironment(&environ_map));
            }
            {
                var environ_map: std.process.Environ.Map = .init(testing.allocator);
                defer environ_map.deinit();
                try environ_map.put("XDG_SESSION_DESKTOP", "gnome-xorg");
                try testing.expectEqual(.gnome, desktopEnvironment(&environ_map));
            }
            {
                var environ_map: std.process.Environ.Map = .init(testing.allocator);
                defer environ_map.deinit();
                try environ_map.put("XDG_SESSION_DESKTOP", "foobar");
                try testing.expectEqual(.other, desktopEnvironment(&environ_map));
            }
            {
                var environ_map: std.process.Environ.Map = .init(testing.allocator);
                defer environ_map.deinit();
                try environ_map.put("XDG_CURRENT_DESKTOP", "GNOME");
                try testing.expectEqual(.gnome, desktopEnvironment(&environ_map));
            }
            {
                var environ_map: std.process.Environ.Map = .init(testing.allocator);
                defer environ_map.deinit();
                try environ_map.put("XDG_CURRENT_DESKTOP", "FOOBAR");
                try testing.expectEqual(.other, desktopEnvironment(&environ_map));
            }
            {
                var environ_map: std.process.Environ.Map = .init(testing.allocator);
                defer environ_map.deinit();
                try testing.expectEqual(.other, desktopEnvironment(&environ_map));
            }
        },
        else => try testing.expectEqual(.other, DesktopEnvironment()),
    }
}
