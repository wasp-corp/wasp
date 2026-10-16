const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
pub const ResourcesDir = struct {
    app_path: ?[]const u8 = null,
    host_path: ?[]const u8 = null,
    pub fn deinit(self: *ResourcesDir, alloc: Allocator) void {
        if (self.app_path) |p| alloc.free(p);
        if (self.host_path) |p| alloc.free(p);
    }
    pub fn app(self: *const ResourcesDir) ?[]const u8 {
        return self.app_path;
    }
    pub fn host(self: *const ResourcesDir) ?[]const u8 {
        return self.host_path orelse self.app_path;
    }
};
pub fn resourcesDir(alloc: Allocator) !ResourcesDir {
    if (comptime builtin.mode != .Debug) env: {
        const dir = global.environ().getAlloc(alloc, "WASP_RESOURCES_DIR") catch |err| switch (err) {
            error.EnvironmentVariableMissing => break :env,
            else => return err,
        };
        if (dir.len > 0) return .{ .app_path = dir };
    }
    const sentinels = switch (comptime builtin.target.os.tag) {
        .windows => .{"terminfo/wasp.terminfo"},
        .macos => .{"terminfo/78/xterm-wasp"},
        .freebsd => .{ "site-terminfo/g/wasp", "site-terminfo/x/xterm-wasp" },
        else => .{ "terminfo/g/wasp", "terminfo/x/xterm-wasp" },
    };
    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var exe: []const u8 = exe_buf[0 .. std.process.executablePath(
        global.io(),
        &exe_buf,
    ) catch return .{}];
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    while (std.fs.path.dirname(exe)) |dir| {
        exe = dir;
        if (comptime builtin.target.os.tag.isDarwin()) {
            inline for (sentinels) |sentinel| {
                if (try maybeDir(
                    &dir_buf,
                    dir,
                    "Contents/Resources",
                    sentinel,
                )) |v| {
                    return .{ .app_path = try std.fs.path.join(alloc, &.{ v, "wasp" }) };
                }
            }
        }
        inline for (sentinels) |sentinel| {
            if (try maybeDir(
                &dir_buf,
                dir,
                if (builtin.target.os.tag == .freebsd) "local/share" else "share",
                sentinel,
            )) |v| {
                return .{ .app_path = try std.fs.path.join(alloc, &.{ v, "wasp" }) };
            }
        }
    }
    if (comptime builtin.mode == .Debug) {
        if (global.environ().getAlloc(alloc, "WASP_RESOURCES_DIR")) |dir| {
            if (dir.len > 0) return .{ .app_path = dir };
        } else |err| switch (err) {
            error.InvalidWtf8, error.EnvironmentVariableMissing => {},
            else => return err,
        }
    }
    return .{};
}
pub fn maybeDir(
    buf: []u8,
    base: []const u8,
    sub: []const u8,
    suffix: []const u8,
) !?[]const u8 {
    const path = try std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ base, sub, suffix });
    if (std.Io.Dir.accessAbsolute(global.io(), path, .{})) {
        const len = path.len - suffix.len - 1;
        return buf[0..len];
    } else |_| {}
    return null;
}
