const std = @import("std");
const global = @import("../global.zig");
const log = std.log.scoped(.@"linux-cgroup");
pub fn current(buf: []u8, pid: u32) ?[]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{}/cgroup", .{pid}) catch return null;
    const file = std.Io.Dir.openFileAbsolute(global.io(), path, .{}) catch return null;
    defer file.close(global.io());
    var read_buf: [64]u8 = undefined;
    var file_reader = file.reader(global.io(), &read_buf);
    const reader = &file_reader.interface;
    const len = reader.readSliceShort(buf) catch return null;
    const contents = buf[0..len];
    const idx = std.mem.lastIndexOfScalar(u8, contents, ':') orelse return null;
    return std.mem.trimEnd(u8, contents[idx + 1 ..], " \r\n");
}
