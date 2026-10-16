const std = @import("std");
const lib = @import("../lib.zig");
const terminal = @import("../main.zig");
const RGB = terminal.color.RGB;
const Terminator = terminal.osc.Terminator;
pub const OSC = struct {
    pub const Request = union(enum) {
        query: Kind,
        set: struct { key: Kind, color: RGB },
        reset: Kind,
    };
    list: std.ArrayList(Request),
    terminator: Terminator = .st,
    pub fn deinit(self: *OSC, alloc: std.mem.Allocator) void {
        self.list.deinit(alloc);
    }
    pub const C = void;
    pub fn cval(_: OSC) C {
        return {};
    }
};
pub const Special = enum {
    foreground,
    background,
    selection_foreground,
    selection_background,
    cursor,
    cursor_text,
    visual_bell,
    second_transparent_background,
};
pub const Kind = union(enum) {
    pub const max: usize = std.math.maxInt(u8) + @typeInfo(Special).@"enum".fields.len;
    palette: u8,
    special: Special,
    pub fn parse(key: []const u8) ?Kind {
        if (std.meta.stringToEnum(Special, key)) |s| return .{ .special = s };
        return .{ .palette = lib.parseInt(u8, key, 10) catch return null };
    }
    pub fn hasTerminalQueryColor(self: Kind) bool {
        return switch (self) {
            .palette => true,
            .special => |special| switch (special) {
                .foreground,
                .background,
                .cursor,
                => true,
                else => false,
            },
        };
    }
    pub fn format(
        self: Kind,
        writer: *std.Io.Writer,
    ) !void {
        switch (self) {
            .palette => |p| try writer.print("{d}", .{p}),
            .special => |s| try writer.print("{s}", .{@tagName(s)}),
        }
    }
};
test "OSC: kitty color indexes reject digit separators" {
    try std.testing.expectEqual(null, Kind.parse("1_0"));
    try std.testing.expectEqualDeep(Kind{ .palette = 10 }, Kind.parse("10").?);
    try std.testing.expectEqualDeep(
        Kind{ .special = .selection_foreground },
        Kind.parse("selection_foreground").?,
    );
}
test "OSC: kitty color protocol kind string" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    {
        const actual = try std.fmt.bufPrint(&buf, "{f}", .{Kind{ .special = .foreground }});
        try testing.expectEqualStrings("foreground", actual);
    }
    {
        const actual = try std.fmt.bufPrint(&buf, "{f}", .{Kind{ .palette = 42 }});
        try testing.expectEqualStrings("42", actual);
    }
    try testing.expect((Kind{ .palette = 42 }).hasTerminalQueryColor());
    try testing.expect((Kind{ .special = .foreground }).hasTerminalQueryColor());
    try testing.expect(!(Kind{ .special = .selection_background }).hasTerminalQueryColor());
}
