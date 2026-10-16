const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/root.zig");
const global = @import("../global.zig");
const log = std.log.scoped(.config);
pub fn defaultXdgPath(alloc: Allocator) ![]const u8 {
    var environ_map = try global.environMap();
    defer environ_map.deinit();
    return try internal_os.xdg.config(
        global.io(),
        alloc,
        &environ_map,
        .{ .subdir = "wasp/config.wasp" },
    );
}
pub fn legacyDefaultXdgPath(alloc: Allocator) ![]const u8 {
    var environ_map = try global.environMap();
    defer environ_map.deinit();
    return try internal_os.xdg.config(
        global.io(),
        alloc,
        &environ_map,
        .{ .subdir = "wasp/config" },
    );
}
pub fn preferredXdgPath(alloc: Allocator) ![]const u8 {
    const xdg_path = try defaultXdgPath(alloc);
    if (open(global.io(), xdg_path)) |f| {
        f.close(global.io());
        return xdg_path;
    } else |_| {}
    errdefer alloc.free(xdg_path);
    const legacy_xdg_path = try legacyDefaultXdgPath(alloc);
    if (open(global.io(), legacy_xdg_path)) |f| {
        f.close(global.io());
        alloc.free(xdg_path);
        return legacy_xdg_path;
    } else |_| {}
    alloc.free(legacy_xdg_path);
    return xdg_path;
}
pub fn defaultAppSupportPath(alloc: Allocator) ![]const u8 {
    return try internal_os.macos.appSupportDir(alloc, "config.wasp");
}
pub fn legacyDefaultAppSupportPath(alloc: Allocator) ![]const u8 {
    return try internal_os.macos.appSupportDir(alloc, "config");
}
pub fn preferredAppSupportPath(alloc: Allocator) ![]const u8 {
    const app_support_path = try defaultAppSupportPath(alloc);
    if (open(global.io(), app_support_path)) |f| {
        f.close(global.io());
        return app_support_path;
    } else |_| {}
    errdefer alloc.free(app_support_path);
    const legacy_app_support_path = try legacyDefaultAppSupportPath(alloc);
    if (open(global.io(), legacy_app_support_path)) |f| {
        f.close(global.io());
        alloc.free(app_support_path);
        return legacy_app_support_path;
    } else |_| {}
    alloc.free(legacy_app_support_path);
    return app_support_path;
}
pub fn preferredDefaultFilePath(alloc: Allocator) ![]const u8 {
    switch (builtin.os.tag) {
        .macos => {
            const app_support_path = try preferredAppSupportPath(alloc);
            const app_support_file = open(global.io(), app_support_path) catch {
                const xdg_path = try preferredXdgPath(alloc);
                const xdg_file = open(global.io(), xdg_path) catch {
                    alloc.free(xdg_path);
                    return app_support_path;
                };
                xdg_file.close(global.io());
                alloc.free(app_support_path);
                return xdg_path;
            };
            app_support_file.close(global.io());
            return app_support_path;
        },
        else => return try preferredXdgPath(alloc),
    }
}
const OpenFileError = error{
    FileNotFound,
    FileIsEmpty,
    FileOpenFailed,
    NotAFile,
};
pub fn open(io: std.Io, path: []const u8) OpenFileError!std.Io.File {
    assert(std.fs.path.isAbsolute(path));
    var file = std.Io.Dir.openFileAbsolute(
        io,
        path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return OpenFileError.FileNotFound,
        else => {
            log.warn("unexpected file open error path={s} err={}", .{
                path,
                err,
            });
            return OpenFileError.FileOpenFailed;
        },
    };
    errdefer file.close(io);
    const stat = file.stat(io) catch |err| {
        log.warn("error getting file stat path={s} err={}", .{
            path,
            err,
        });
        return OpenFileError.FileOpenFailed;
    };
    switch (stat.kind) {
        .file => {},
        else => return OpenFileError.NotAFile,
    }
    if (stat.size == 0) return OpenFileError.FileIsEmpty;
    return file;
}
