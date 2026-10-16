const std = @import("std");
const global = @import("../global.zig");
pub fn dataFile(path_: ?[]const u8) !?std.Io.File {
    const path = path_ orelse return null;
    if (std.mem.eql(u8, path, "-")) return .stdin();
    const file = try std.Io.Dir.cwd().openFile(global.io(), path, .{});
    errdefer file.close(global.io());
    return file;
}
