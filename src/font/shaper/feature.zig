const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const compat_reader = @import("../../lib/compat/reader.zig");
const log = std.log.scoped(.font_shaper);
pub const Feature = struct {
    tag: [4]u8,
    value: u32,
    pub fn fromString(str: []const u8) ?Feature {
        var reader: std.Io.Reader = .fixed(str);
        return .fromReader(&reader);
    }
    pub fn fromReader(reader: anytype) ?Feature {
        var tag_buf: [4]u8 = undefined;
        var tag: []u8 = tag_buf[0..0];
        var value: ?u32 = null;
        state: switch ((enum {
            start,
            tag,
            space,
            int,
            bool,
            err,
            done,
        }).start) {
            .done => while (true) switch (compat_reader.readByte(reader) catch ',') {
                ' ', '\t' => continue,
                ',' => break,
                else => continue :state .err,
            },
            .err => {
                compat_reader.readSkipUntilDelimiterOrEof(reader, ',') catch {};
                return null;
            },
            .start => while (true) switch (compat_reader.readByte(reader) catch ',') {
                ' ', '\t' => continue,
                ',' => return null,
                '+' => {
                    value = 1;
                    continue :state .tag;
                },
                '-' => {
                    value = 0;
                    continue :state .tag;
                },
                '"', '\'' => {
                    continue :state .tag;
                },
                else => |byte| {
                    tag.len = 1;
                    tag[0] = byte;
                    continue :state .tag;
                },
            },
            .tag => while (true) switch (compat_reader.readByte(reader) catch ',') {
                ',' => return null,
                '"', '\'' => continue,
                else => |byte| {
                    tag.len += 1;
                    tag[tag.len - 1] = byte;
                    if (tag.len == 4) continue :state .space;
                },
            },
            .space => while (true) switch (compat_reader.readByte(reader) catch ',') {
                ' ', '\t' => continue,
                '"', '\'' => continue,
                '=' => if (value != null) continue :state .err,
                ',' => {
                    if (value == null) value = 1;
                    break;
                },
                '0'...'9' => |byte| {
                    if (value != null) continue :state .err;
                    value = byte - '0';
                    continue :state .int;
                },
                'o', 'O' => {
                    if (value != null) continue :state .err;
                    continue :state .bool;
                },
                else => continue :state .err,
            },
            .int => while (true) switch (compat_reader.readByte(reader) catch ',') {
                ',' => break,
                '0'...'9' => |byte| {
                    value = std.math.mul(u32, value.?, 10) catch {
                        continue :state .err;
                    };
                    value.? += byte - '0';
                },
                else => continue :state .err,
            },
            .bool => while (true) switch (compat_reader.readByte(reader) catch ',') {
                ',' => return null,
                'n', 'N' => {
                    if (value != null) {
                        assert(value == 0);
                        continue :state .err;
                    }
                    value = 1;
                    continue :state .done;
                },
                'f', 'F' => {
                    if (value == null) {
                        value = 0;
                    } else {
                        assert(value == 0);
                        continue :state .done;
                    }
                },
                else => continue :state .err,
            },
        }
        assert(value != null);
        assert(tag.len == 4);
        return .{
            .tag = tag_buf,
            .value = value.?,
        };
    }
    pub fn toString(self: *const Feature, buf: []u8) !void {
        var fbs = std.io.fixedBufferStream(buf);
        try self.format("", .{}, fbs.writer());
    }
    pub fn format(
        self: Feature,
        comptime layout: []const u8,
        opts: std.fmt.FormatOptions,
        writer: *std.Io.Writer,
    ) !void {
        _ = layout;
        _ = opts;
        if (self.value <= 1) {
            try std.fmt.format(writer, "{c}{s}", .{
                "-+"[self.value],
                self.tag,
            });
        } else {
            try std.fmt.format(writer, "{s}={d}", .{
                self.tag,
                self.value,
            });
        }
    }
};
pub const FeatureList = struct {
    features: std.ArrayList(Feature) = .empty,
    pub fn deinit(self: *FeatureList, alloc: Allocator) void {
        self.features.deinit(alloc);
    }
    pub fn fromString(alloc: Allocator, str: []const u8) !FeatureList {
        var self: FeatureList = .{};
        try self.appendFromString(alloc, str);
        return self;
    }
    pub fn appendFromString(
        self: *FeatureList,
        alloc: Allocator,
        str: []const u8,
    ) !void {
        var reader: std.Io.Reader = .fixed(str);
        while (reader.seek < reader.end) {
            const i = reader.seek;
            if (Feature.fromReader(&reader)) |feature| {
                try self.features.append(alloc, feature);
            } else log.warn(
                "failed to parse font feature setting: \"{s}\"",
                .{reader.buffer[i..reader.seek]},
            );
        }
    }
    pub fn format(
        self: FeatureList,
        comptime layout: []const u8,
        opts: std.fmt.FormatOptions,
        writer: *std.Io.Writer,
    ) !void {
        for (self.features.items, 0..) |feature, i| {
            try feature.format(layout, opts, writer);
            if (i != std.features.items.len - 1) try writer.writeAll(", ");
        }
        if (self.value <= 1) {
            try std.fmt.format(writer, "{c}{s}", .{
                "-+"[self.value],
                self.tag,
            });
        } else {
            try std.fmt.format(writer, "{s}={d}", .{
                self.tag,
                self.value,
            });
        }
    }
};
pub const default_features = [_]Feature{
    .{ .tag = "liga".*, .value = 1 },
};
test "Feature.fromString" {
    const testing = std.testing;
    const kern_on = Feature{ .tag = "kern".*, .value = 1 };
    try testing.expectEqual(kern_on, Feature.fromString("kern"));
    try testing.expectEqual(kern_on, Feature.fromString("kern, "));
    try testing.expectEqual(kern_on, Feature.fromString("kern on"));
    try testing.expectEqual(kern_on, Feature.fromString("kern on, "));
    try testing.expectEqual(kern_on, Feature.fromString("+kern"));
    try testing.expectEqual(kern_on, Feature.fromString("+kern, "));
    try testing.expectEqual(kern_on, Feature.fromString("\"kern\" = 1"));
    try testing.expectEqual(kern_on, Feature.fromString("\"kern\" = 1, "));
    const kern_off = Feature{ .tag = "kern".*, .value = 0 };
    try testing.expectEqual(kern_off, Feature.fromString("kern off"));
    try testing.expectEqual(kern_off, Feature.fromString("kern off, "));
    try testing.expectEqual(kern_off, Feature.fromString("-'kern'"));
    try testing.expectEqual(kern_off, Feature.fromString("-'kern', "));
    try testing.expectEqual(kern_off, Feature.fromString("\"kern\" = 0"));
    try testing.expectEqual(kern_off, Feature.fromString("\"kern\" = 0, "));
    const aalt_2 = Feature{ .tag = "aalt".*, .value = 2 };
    try testing.expectEqual(aalt_2, Feature.fromString("aalt=2"));
    try testing.expectEqual(aalt_2, Feature.fromString("aalt=2, "));
    try testing.expectEqual(aalt_2, Feature.fromString("'aalt' 2"));
    try testing.expectEqual(aalt_2, Feature.fromString("'aalt' 2, "));
    try testing.expectEqual(null, Feature.fromString("aalt=2x")); 
    try testing.expectEqual(null, Feature.fromString("toolong")); 
    try testing.expectEqual(null, Feature.fromString("sht")); 
    try testing.expectEqual(null, Feature.fromString("-kern 1")); 
    try testing.expectEqual(null, Feature.fromString("-kern on")); 
    try testing.expectEqual(null, Feature.fromString("aalt=o,")); 
    try testing.expectEqual(null, Feature.fromString("aalt=ofn,")); 
}
test "FeatureList.fromString" {
    const testing = std.testing;
    const str =
        "  kern, kern on , +kern, \"kern\"  = 1," ++ 
        "kern    off, -'kern' , \"kern\"=0," ++ 
        "aalt=2,  'aalt'\t2," ++ 
        "aalt=2x, toolong, sht, -kern 1, -kern on, aalt=o, aalt=ofn," ++ 
        "last"; 
    var feats = try FeatureList.fromString(testing.allocator, str);
    defer feats.deinit(testing.allocator);
    try testing.expectEqualSlices(
        Feature,
        &(.{Feature{ .tag = "kern".*, .value = 1 }} ** 4 ++
            .{Feature{ .tag = "kern".*, .value = 0 }} ** 3 ++
            .{Feature{ .tag = "aalt".*, .value = 2 }} ** 2 ++
            .{Feature{ .tag = "last".*, .value = 1 }}),
        feats.features.items,
    );
}
