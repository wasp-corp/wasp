const Source = @This();
const std = @import("std");
names: []const [:0]const u8,
capabilities: []const Capability,
pub const Capability = struct {
    name: []const u8,
    value: Value,
    pub const Value = union(enum) {
        canceled: void,
        boolean: void,
        numeric: u32,
        string: [:0]const u8,
    };
};
pub fn encode(self: Source, writer: *std.Io.Writer) !void {
    for (self.names, 0..) |name, i| {
        if (i != 0) try writer.writeAll("|");
        try writer.writeAll(name);
    }
    try writer.writeAll(",\n");
    for (self.capabilities) |cap| {
        try writer.writeAll("\t");
        try writer.writeAll(cap.name);
        switch (cap.value) {
            .canceled => try writer.writeAll("@"),
            .boolean => {},
            .numeric => |v| try writer.print("#{d}", .{v}),
            .string => |v| try writer.print("={s}", .{v}),
        }
        try writer.writeAll(",\n");
    }
}
pub fn xtgettcapMap(comptime self: Source) std.StaticStringMap([:0]const u8) {
    const KV = struct { []const u8, [:0]const u8 };
    const len = self.capabilities.len + 3;
    var kvs: [len]KV = @splat(.{ "", "" });
    kvs[0] = .{ "TN", self.names[0] };
    kvs[1] = .{ "Co", "256" };
    kvs[2] = .{ "RGB", "8" };
    for (self.capabilities, 3..) |cap, i| {
        kvs[i] = .{
            cap.name,
            switch (cap.value) {
                .canceled => @compileError("canceled not handled yet"),
                .boolean => "",
                .string => |v| string: {
                    @setEvalBranchQuota(100_000);
                    if (std.mem.indexOfScalar(u8, v, '%') != null) break :string v;
                    var result = comptimeReplace(v, "\\E", "\x1b");
                    while (std.mem.indexOfScalar(u8, result, '^')) |idx| {
                        if (idx > 0) @compileError("handle control-char in middle of string");
                        const replacement = switch (result[idx + 1]) {
                            '?' => 0x7F,
                            else => |c| c - 64,
                        };
                        result = comptimeReplace(
                            result,
                            result[idx .. idx + 2],
                            &.{replacement},
                        );
                    }
                    break :string result;
                },
                .numeric => |v| numeric: {
                    var buf: [11]u8 = @splat(0);
                    var writer: std.Io.Writer = .fixed(buf[0..10]);
                    writer.printInt(v, 10, .upper, .{}) catch unreachable;
                    const final = buf;
                    break :numeric final[0..writer.end :0];
                },
            },
        };
    }
    for (&kvs) |*entry| {
        entry[0] = hexencode(entry[0]);
        var buf: [5 + entry[0].len + 1 + (entry[1].len * 2) + 2 + 1]u8 = @splat(0);
        const out = if (std.mem.eql(u8, entry[1], "")) std.fmt.bufPrint(
            &buf,
            "\x1bP1+r{s}\x1b\\",
            .{entry[0]},
        ) catch unreachable else std.fmt.bufPrint(
            &buf,
            "\x1bP1+r{s}={s}\x1b\\",
            .{ entry[0], hexencode(entry[1]) },
        ) catch unreachable;
        const final = buf;
        entry[1] = final[0..out.len :0];
    }
    const kvs_final = kvs;
    return std.StaticStringMap([:0]const u8).initComptime(&kvs_final);
}
fn hexencode(comptime input: []const u8) []const u8 {
    return comptime &(std.fmt.bytesToHex(input, .upper));
}
fn comptimeReplace(
    input: []const u8,
    needle: []const u8,
    replacement: []const u8,
) [:0]const u8 {
    comptime {
        const len = std.mem.replacementSize(u8, input, needle, replacement);
        var buf: [len + 1]u8 = @splat(0);
        _ = std.mem.replace(u8, input, needle, replacement, buf[0..len]);
        const final = buf;
        return final[0..len :0];
    }
}
test "xtgettcap map" {
    const testing = std.testing;
    const src: Source = .{
        .names = &.{
            "wasp",
            "xterm-wasp",
            "Wasp",
        },
        .capabilities = &.{
            .{ .name = "am", .value = .{ .boolean = {} } },
            .{ .name = "colors", .value = .{ .numeric = 256 } },
            .{ .name = "kx", .value = .{ .string = "^?" } },
            .{ .name = "kbs", .value = .{ .string = "^H" } },
            .{ .name = "kf1", .value = .{ .string = "\\EOP" } },
            .{ .name = "Smulx", .value = .{ .string = "\\E[4:%p1%dm" } },
        },
    };
    const map = comptime src.xtgettcapMap();
    try testing.expectEqualStrings(
        "\x1bP1+r616D\x1b\\",
        map.get(hexencode("am")).?,
    );
    try testing.expectEqualStrings(
        "\x1bP1+r6B78=7F\x1b\\",
        map.get(hexencode("kx")).?,
    );
    try testing.expectEqualStrings(
        "\x1bP1+r6B6273=08\x1b\\",
        map.get(hexencode("kbs")).?,
    );
    try testing.expectEqualStrings(
        "\x1bP1+r6B6631=1B4F50\x1b\\",
        map.get(hexencode("kf1")).?,
    );
    try testing.expectEqualStrings(
        "\x1bP1+r536D756C78=5C455B343A25703125646D\x1b\\",
        map.get(hexencode("Smulx")).?,
    );
}
test "encode" {
    const src: Source = .{
        .names = &.{
            "wasp",
            "xterm-wasp",
            "Wasp",
        },
        .capabilities = &.{
            .{ .name = "am", .value = .{ .boolean = {} } },
            .{ .name = "ccc", .value = .{ .canceled = {} } },
            .{ .name = "colors", .value = .{ .numeric = 256 } },
            .{ .name = "bel", .value = .{ .string = "^G" } },
        },
    };
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try src.encode(&writer);
    const expected =
        "wasp|xterm-wasp|Wasp,\n" ++
        "\tam,\n" ++
        "\tccc@,\n" ++
        "\tcolors#256,\n" ++
        "\tbel=^G,\n";
    try std.testing.expectEqualStrings(@as([]const u8, expected), writer.buffered());
}
