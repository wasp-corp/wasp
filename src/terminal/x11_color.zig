const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const RGB = @import("color.zig").RGB;
pub const Entry = struct {
    name: [:0]const u8,
    color: RGB,
};
pub const entries: []const Entry = entriesArray();
pub const map = colorMap();
pub const ColorMap = std.StaticStringMapWithEql(
    RGB,
    std.static_string_map.eqlAsciiIgnoreCase,
);
fn entriesArray() []const Entry {
    @setEvalBranchQuota(1_000_000);
    const len = std.mem.count(u8, data, "\n");
    var result: [len]Entry = undefined;
    var iter = std.mem.splitScalar(u8, data, '\n');
    var i: usize = 0;
    while (iter.next()) |raw_line| {
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;
        if (line.len == 0) continue;
        const r = try std.fmt.parseInt(u8, std.mem.trim(u8, line[0..3], " "), 10);
        const g = try std.fmt.parseInt(u8, std.mem.trim(u8, line[4..7], " "), 10);
        const b = try std.fmt.parseInt(u8, std.mem.trim(u8, line[8..11], " "), 10);
        const name = std.mem.trim(u8, line[12..], " \t");
        var name_z: [name.len:0]u8 = undefined;
        @memcpy(name_z[0..name.len], name);
        name_z[name.len] = 0;
        const final_name = name_z;
        result[i] = .{
            .name = final_name[0..name.len :0],
            .color = .{ .r = r, .g = g, .b = b },
        };
        i += 1;
    }
    assert(i == len);
    const final = result;
    return &final;
}
fn colorMap() ColorMap {
    @setEvalBranchQuota(1_000_000);
    const KV = struct { []const u8, RGB };
    var kvs: [entries.len]KV = undefined;
    for (entries, 0..) |entry, i| kvs[i] = .{ entry.name, entry.color };
    return .initComptime(kvs);
}
const data = @embedFile("res/rgb.txt");
test {
    const testing = std.testing;
    try testing.expectEqual(null, map.get("nosuchcolor"));
    try testing.expectEqual(RGB{ .r = 255, .g = 255, .b = 255 }, map.get("white").?);
    try testing.expectEqual(RGB{ .r = 0, .g = 250, .b = 154 }, map.get("medium spring green"));
    try testing.expectEqual(RGB{ .r = 34, .g = 139, .b = 34 }, map.get("ForestGreen"));
    try testing.expectEqual(RGB{ .r = 34, .g = 139, .b = 34 }, map.get("FoReStGReen"));
    try testing.expectEqual(RGB{ .r = 0, .g = 0, .b = 0 }, map.get("black"));
    try testing.expectEqual(RGB{ .r = 255, .g = 0, .b = 0 }, map.get("red"));
    try testing.expectEqual(RGB{ .r = 0, .g = 255, .b = 0 }, map.get("green"));
    try testing.expectEqual(RGB{ .r = 0, .g = 0, .b = 255 }, map.get("blue"));
    try testing.expectEqual(RGB{ .r = 255, .g = 255, .b = 255 }, map.get("white"));
    try testing.expectEqual(RGB{ .r = 124, .g = 252, .b = 0 }, map.get("lawngreen"));
    try testing.expectEqual(RGB{ .r = 0, .g = 250, .b = 154 }, map.get("mediumspringgreen"));
    try testing.expectEqual(RGB{ .r = 34, .g = 139, .b = 34 }, map.get("forestgreen"));
}
test "entries" {
    const testing = std.testing;
    try testing.expect(entries.len > 700);
    for (entries) |entry| {
        try testing.expectEqual(entry.color, map.get(entry.name).?);
        try testing.expectEqual(@as(u8, 0), entry.name.ptr[entry.name.len]);
    }
    try testing.expectEqualStrings("snow", entries[0].name);
}
