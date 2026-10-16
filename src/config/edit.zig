const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const file_load = @import("file_load.zig");
const global = @import("../global.zig");
pub fn openPath(alloc_gpa: Allocator) ![:0]const u8 {
    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc_arena = arena.allocator();
    const config_path = try configPath(alloc_arena);
    if (!config_path.exists) {
        if (std.fs.path.dirname(config_path.name)) |config_dir| check_dir: {
            const dir = std.Io.Dir.cwd().openDir(global.io(), config_dir, .{ .follow_symlinks = true }) catch |err| {
                switch (err) {
                    error.FileNotFound => {
                        try std.Io.Dir.cwd().createDirPath(global.io(), config_dir);
                        break :check_dir;
                    },
                    else => return err,
                }
            };
            dir.close(global.io());
        }
        _ = std.Io.Dir.createFileAbsolute(
            global.io(),
            config_path.name,
            .{ .exclusive = true },
        ) catch |err| {
            switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            }
        };
    }
    return try alloc_gpa.dupeZ(u8, config_path.name);
}
const ConfigPathResult = struct {
    name: []const u8,
    exists: bool,
};
fn configPath(alloc_arena: Allocator) !ConfigPathResult {
    const paths: []const []const u8 = try configPathCandidates(alloc_arena);
    assert(paths.len > 0);
    var exists: ?[]const u8 = null;
    for (paths) |path| {
        const f = std.Io.Dir.openFileAbsolute(global.io(), path, .{}) catch |err| {
            switch (err) {
                error.BadPathName, error.FileNotFound => continue,
                else => return err,
            }
        };
        defer f.close(global.io());
        const stat = try f.stat(global.io());
        if (stat.size > 0) return .{
            .name = path,
            .exists = true,
        };
        if (exists == null) exists = path;
    }
    if (exists) |v| return .{
        .name = v,
        .exists = true,
    };
    return .{
        .name = paths[0],
        .exists = false,
    };
}
fn configPathCandidates(alloc_arena: Allocator) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = try .initCapacity(alloc_arena, 4);
    errdefer paths.deinit(alloc_arena);
    if (comptime builtin.os.tag == .macos) {
        paths.appendAssumeCapacity(try file_load.defaultAppSupportPath(alloc_arena));
        paths.appendAssumeCapacity(try file_load.legacyDefaultAppSupportPath(alloc_arena));
    }
    paths.appendAssumeCapacity(try file_load.defaultXdgPath(alloc_arena));
    paths.appendAssumeCapacity(try file_load.legacyDefaultXdgPath(alloc_arena));
    return paths.items;
}
