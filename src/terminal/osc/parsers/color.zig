const std = @import("std");
const lib = @import("../../lib.zig");
const Allocator = std.mem.Allocator;
const DynamicColor = @import("../../color.zig").Dynamic;
const SpecialColor = @import("../../color.zig").Special;
const RGB = @import("../../color.zig").RGB;
const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;
const SegmentedList = @import("../../../datastruct/segmented_list.zig").SegmentedList;
const log = std.log.scoped(.osc_color);
const ParseError = Allocator.Error || error{
    MissingOperation,
};
pub const Operation = enum {
    osc_4,
    osc_5,
    osc_10,
    osc_11,
    osc_12,
    osc_13,
    osc_14,
    osc_15,
    osc_16,
    osc_17,
    osc_18,
    osc_19,
    osc_104,
    osc_105,
    osc_110,
    osc_111,
    osc_112,
    osc_113,
    osc_114,
    osc_115,
    osc_116,
    osc_117,
    osc_118,
    osc_119,
};
pub fn parse(parser: *Parser, terminator_ch: ?u8) ?*Command {
    const alloc = parser.alloc orelse {
        parser.state = .invalid;
        return null;
    };
    const data = data: {
        const cap = if (parser.capture) |*c| c else break :data "";
        break :data cap.trailing();
    };
    const op: Operation = switch (parser.state) {
        .@"4" => .osc_4,
        .@"5" => .osc_5,
        .@"10" => .osc_10,
        .@"11" => .osc_11,
        .@"12" => .osc_12,
        .@"13" => .osc_13,
        .@"14" => .osc_14,
        .@"15" => .osc_15,
        .@"16" => .osc_16,
        .@"17" => .osc_17,
        .@"18" => .osc_18,
        .@"19" => .osc_19,
        .@"104" => .osc_104,
        .@"105" => .osc_105,
        .@"110" => .osc_110,
        .@"111" => .osc_111,
        .@"112" => .osc_112,
        .@"113" => .osc_113,
        .@"114" => .osc_114,
        .@"115" => .osc_115,
        .@"116" => .osc_116,
        .@"117" => .osc_117,
        .@"118" => .osc_118,
        .@"119" => .osc_119,
        else => {
            parser.state = .invalid;
            return null;
        },
    };
    parser.command = .{
        .color_operation = .{
            .op = op,
            .requests = parseColor(alloc, op, data) catch |err| list: {
                log.info(
                    "failed to parse OSC {t} color request err={} data={s}",
                    .{ parser.state, err, data },
                );
                break :list .{};
            },
            .terminator = .init(terminator_ch),
        },
    };
    return &parser.command;
}
test "OSC 4: empty param" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const input = "4;;";
    for (input) |ch| p.next(ch);
    const cmd = p.end('\x1b');
    try testing.expect(cmd == null);
}
fn parseColor(
    alloc: Allocator,
    op: Operation,
    buf: []const u8,
) ParseError!List {
    var it = std.mem.tokenizeScalar(u8, buf, ';');
    return switch (op) {
        .osc_4 => try parseGetSetAnsiColor(alloc, .osc_4, &it),
        .osc_5 => try parseGetSetAnsiColor(alloc, .osc_5, &it),
        .osc_104 => try parseResetAnsiColor(alloc, .osc_104, &it),
        .osc_105 => try parseResetAnsiColor(alloc, .osc_105, &it),
        .osc_10 => try parseGetSetDynamicColor(alloc, .foreground, &it),
        .osc_11 => try parseGetSetDynamicColor(alloc, .background, &it),
        .osc_12 => try parseGetSetDynamicColor(alloc, .cursor, &it),
        .osc_13 => try parseGetSetDynamicColor(alloc, .pointer_foreground, &it),
        .osc_14 => try parseGetSetDynamicColor(alloc, .pointer_background, &it),
        .osc_15 => try parseGetSetDynamicColor(alloc, .tektronix_foreground, &it),
        .osc_16 => try parseGetSetDynamicColor(alloc, .tektronix_background, &it),
        .osc_17 => try parseGetSetDynamicColor(alloc, .highlight_background, &it),
        .osc_18 => try parseGetSetDynamicColor(alloc, .tektronix_cursor, &it),
        .osc_19 => try parseGetSetDynamicColor(alloc, .highlight_foreground, &it),
        .osc_110 => try parseResetDynamicColor(alloc, .foreground, &it),
        .osc_111 => try parseResetDynamicColor(alloc, .background, &it),
        .osc_112 => try parseResetDynamicColor(alloc, .cursor, &it),
        .osc_113 => try parseResetDynamicColor(alloc, .pointer_foreground, &it),
        .osc_114 => try parseResetDynamicColor(alloc, .pointer_background, &it),
        .osc_115 => try parseResetDynamicColor(alloc, .tektronix_foreground, &it),
        .osc_116 => try parseResetDynamicColor(alloc, .tektronix_background, &it),
        .osc_117 => try parseResetDynamicColor(alloc, .highlight_background, &it),
        .osc_118 => try parseResetDynamicColor(alloc, .tektronix_cursor, &it),
        .osc_119 => try parseResetDynamicColor(alloc, .highlight_foreground, &it),
    };
}
fn parseGetSetAnsiColor(
    alloc: Allocator,
    comptime op: Operation,
    it: *std.mem.TokenIterator(u8, .scalar),
) Allocator.Error!List {
    var result: List = .{};
    errdefer result.deinit(alloc);
    while (true) {
        const color_str = it.next() orelse return result;
        const spec_str = it.next() orelse return result;
        const color: u9 = lib.parseInt(
            u9,
            color_str,
            10,
        ) catch return result;
        const target: Target = switch (op) {
            .osc_5 => .{ .special = std.enums.fromInt(
                SpecialColor,
                std.math.cast(u3, color) orelse return result,
            ) orelse return result },
            .osc_4 => if (std.math.cast(u8, color)) |idx| .{
                .palette = idx,
            } else .{ .special = std.enums.fromInt(
                SpecialColor,
                std.math.cast(u3, color - 256) orelse return result,
            ) orelse return result },
            else => comptime unreachable,
        };
        if (std.mem.eql(u8, spec_str, "?")) {
            const req = try result.addOne(alloc);
            req.* = .{ .query = target };
            continue;
        }
        const rgb = RGB.parse(spec_str) catch return result;
        const req = try result.addOne(alloc);
        req.* = .{ .set = .{
            .target = target,
            .color = rgb,
        } };
    }
}
fn parseResetAnsiColor(
    alloc: Allocator,
    comptime op: Operation,
    it: *std.mem.TokenIterator(u8, .scalar),
) Allocator.Error!List {
    var result: List = .{};
    errdefer result.deinit(alloc);
    while (true) {
        const color_str = it.next() orelse {
            if (result.count() == 0) {
                const req = try result.addOne(alloc);
                req.* = switch (op) {
                    .osc_104 => .reset_palette,
                    .osc_105 => .reset_special,
                    else => comptime unreachable,
                };
            }
            return result;
        };
        if (color_str.len == 0) continue;
        const color: u9 = lib.parseInt(
            u9,
            color_str,
            10,
        ) catch continue;
        const target: Target = switch (op) {
            .osc_105 => .{ .special = std.enums.fromInt(
                SpecialColor,
                std.math.cast(u3, color) orelse continue,
            ) orelse continue },
            .osc_104 => if (std.math.cast(u8, color)) |idx| .{
                .palette = idx,
            } else .{ .special = std.enums.fromInt(
                SpecialColor,
                std.math.cast(u3, color - 256) orelse continue,
            ) orelse continue },
            else => comptime unreachable,
        };
        const req = try result.addOne(alloc);
        req.* = .{ .reset = target };
    }
}
fn parseGetSetDynamicColor(
    alloc: Allocator,
    start: DynamicColor,
    it: *std.mem.TokenIterator(u8, .scalar),
) Allocator.Error!List {
    var result: List = .{};
    var color: DynamicColor = start;
    while (true) {
        const spec_str = it.next() orelse return result;
        if (std.mem.eql(u8, spec_str, "?")) {
            const req = try result.addOne(alloc);
            req.* = .{ .query = .{ .dynamic = color } };
        } else {
            const rgb = RGB.parse(spec_str) catch return result;
            const req = try result.addOne(alloc);
            req.* = .{ .set = .{
                .target = .{ .dynamic = color },
                .color = rgb,
            } };
        }
        color = color.next() orelse return result;
    }
}
fn parseResetDynamicColor(
    alloc: Allocator,
    color: DynamicColor,
    it: *std.mem.TokenIterator(u8, .scalar),
) Allocator.Error!List {
    var result: List = .{};
    errdefer result.deinit(alloc);
    if (it.next() != null) return result;
    const req = try result.addOne(alloc);
    req.* = .{ .reset = .{ .dynamic = color } };
    return result;
}
pub const List = SegmentedList(
    Request,
    2,
);
pub const Request = union(enum) {
    set: ColoredTarget,
    query: Target,
    reset: Target,
    reset_palette,
    reset_special,
};
pub const Target = union(enum) {
    palette: u8,
    special: SpecialColor,
    dynamic: DynamicColor,
};
pub const ColoredTarget = struct {
    target: Target,
    color: RGB,
};
test "OSC color indexes reject digit separators" {
    const testing = std.testing;
    const alloc = testing.allocator;
    inline for (.{ Operation.osc_4, Operation.osc_5 }) |op| {
        var list = try parseColor(alloc, op, "1;red;0_3;blue;2;green");
        defer list.deinit(alloc);
        try testing.expectEqual(1, list.count());
    }
    inline for (.{ Operation.osc_104, Operation.osc_105 }) |op| {
        var list = try parseColor(alloc, op, "1;0_3;2");
        defer list.deinit(alloc);
        try testing.expectEqual(2, list.count());
    }
}
test "OSC 4:" {
    const testing = std.testing;
    const alloc = testing.allocator;
    for (0..std.math.maxInt(u8)) |idx| {
        {
            const body = try std.fmt.allocPrint(
                alloc,
                "{d};red",
                .{idx},
            );
            defer alloc.free(body);
            var list = try parseColor(alloc, .osc_4, body);
            defer list.deinit(alloc);
            try testing.expectEqual(1, list.count());
            try testing.expectEqual(
                Request{ .set = .{
                    .target = .{ .palette = @intCast(idx) },
                    .color = RGB{ .r = 255, .g = 0, .b = 0 },
                } },
                list.at(0).*,
            );
        }
        {
            const body = try std.fmt.allocPrint(
                alloc,
                "{d};?",
                .{idx},
            );
            defer alloc.free(body);
            var list = try parseColor(alloc, .osc_4, body);
            defer list.deinit(alloc);
            try testing.expectEqual(1, list.count());
            try testing.expectEqual(
                Request{ .query = .{ .palette = @intCast(idx) } },
                list.at(0).*,
            );
        }
        {
            const body = try std.fmt.allocPrint(
                alloc,
                "{d};red;",
                .{idx},
            );
            defer alloc.free(body);
            var list = try parseColor(alloc, .osc_4, body);
            defer list.deinit(alloc);
            try testing.expectEqual(1, list.count());
            try testing.expectEqual(
                Request{ .set = .{
                    .target = .{ .palette = @intCast(idx) },
                    .color = RGB{ .r = 255, .g = 0, .b = 0 },
                } },
                list.at(0).*,
            );
        }
        {
            const body = try std.fmt.allocPrint(
                alloc,
                "{d};red ",
                .{idx},
            );
            defer alloc.free(body);
            var list = try parseColor(alloc, .osc_4, body);
            defer list.deinit(alloc);
            try testing.expectEqual(1, list.count());
            try testing.expectEqual(
                Request{ .set = .{
                    .target = .{ .palette = @intCast(idx) },
                    .color = RGB{ .r = 255, .g = 0, .b = 0 },
                } },
                list.at(0).*,
            );
        }
    }
    for (0..@typeInfo(SpecialColor).@"enum".fields.len) |i| {
        const special = std.enums.fromInt(SpecialColor, i) orelse return error.InvalidEnumValue;
        {
            const body = try std.fmt.allocPrint(
                alloc,
                "{d};red",
                .{256 + i},
            );
            defer alloc.free(body);
            var list = try parseColor(alloc, .osc_4, body);
            defer list.deinit(alloc);
            try testing.expectEqual(1, list.count());
            try testing.expectEqual(
                Request{ .set = .{
                    .target = .{ .special = special },
                    .color = RGB{ .r = 255, .g = 0, .b = 0 },
                } },
                list.at(0).*,
            );
        }
    }
}
test "OSC 5:" {
    const testing = std.testing;
    const alloc = testing.allocator;
    for (0..@typeInfo(SpecialColor).@"enum".fields.len) |i| {
        const special = std.enums.fromInt(SpecialColor, i) orelse return error.InvalidEnumValue;
        {
            const body = try std.fmt.allocPrint(
                alloc,
                "{d};red",
                .{i},
            );
            defer alloc.free(body);
            var list = try parseColor(alloc, .osc_5, body);
            defer list.deinit(alloc);
            try testing.expectEqual(1, list.count());
            try testing.expectEqual(
                Request{ .set = .{
                    .target = .{ .special = special },
                    .color = RGB{ .r = 255, .g = 0, .b = 0 },
                } },
                list.at(0).*,
            );
        }
    }
}
test "OSC 4: multiple requests" {
    const testing = std.testing;
    const alloc = testing.allocator;
    {
        var list = try parseColor(
            alloc,
            .osc_4,
            "0;red;1;blue",
        );
        defer list.deinit(alloc);
        try testing.expectEqual(2, list.count());
        try testing.expectEqual(
            Request{ .set = .{
                .target = .{ .palette = 0 },
                .color = RGB{ .r = 255, .g = 0, .b = 0 },
            } },
            list.at(0).*,
        );
        try testing.expectEqual(
            Request{ .set = .{
                .target = .{ .palette = 1 },
                .color = RGB{ .r = 0, .g = 0, .b = 255 },
            } },
            list.at(1).*,
        );
    }
    {
        var list = try parseColor(
            alloc,
            .osc_4,
            "0;red;0;blue",
        );
        defer list.deinit(alloc);
        try testing.expectEqual(2, list.count());
        try testing.expectEqual(
            Request{ .set = .{
                .target = .{ .palette = 0 },
                .color = RGB{ .r = 255, .g = 0, .b = 0 },
            } },
            list.at(0).*,
        );
        try testing.expectEqual(
            Request{ .set = .{
                .target = .{ .palette = 0 },
                .color = RGB{ .r = 0, .g = 0, .b = 255 },
            } },
            list.at(1).*,
        );
    }
}
test "OSC 104:" {
    const testing = std.testing;
    const alloc = testing.allocator;
    for (0..std.math.maxInt(u8)) |idx| {
        {
            const body = try std.fmt.allocPrint(
                alloc,
                "{d}",
                .{idx},
            );
            defer alloc.free(body);
            var list = try parseColor(alloc, .osc_104, body);
            defer list.deinit(alloc);
            try testing.expectEqual(1, list.count());
            try testing.expectEqual(
                Request{ .reset = .{ .palette = @intCast(idx) } },
                list.at(0).*,
            );
        }
    }
    for (0..@typeInfo(SpecialColor).@"enum".fields.len) |i| {
        const special = std.enums.fromInt(SpecialColor, i) orelse return error.InvalidEnumValue;
        {
            const body = try std.fmt.allocPrint(
                alloc,
                "{d}",
                .{256 + i},
            );
            defer alloc.free(body);
            var list = try parseColor(alloc, .osc_104, body);
            defer list.deinit(alloc);
            try testing.expectEqual(1, list.count());
            try testing.expectEqual(
                Request{ .reset = .{ .special = special } },
                list.at(0).*,
            );
        }
    }
}
test "OSC 104: empty index" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var list = try parseColor(alloc, .osc_104, "0;;1");
    defer list.deinit(alloc);
    try testing.expectEqual(2, list.count());
    try testing.expectEqual(
        Request{ .reset = .{ .palette = 0 } },
        list.at(0).*,
    );
    try testing.expectEqual(
        Request{ .reset = .{ .palette = 1 } },
        list.at(1).*,
    );
}
test "OSC 104: invalid index" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var list = try parseColor(alloc, .osc_104, "ffff;1");
    defer list.deinit(alloc);
    try testing.expectEqual(1, list.count());
    try testing.expectEqual(
        Request{ .reset = .{ .palette = 1 } },
        list.at(0).*,
    );
}
test "OSC 104: reset all" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var list = try parseColor(alloc, .osc_104, "");
    defer list.deinit(alloc);
    try testing.expectEqual(1, list.count());
    try testing.expectEqual(
        Request{ .reset_palette = {} },
        list.at(0).*,
    );
}
test "OSC 105: reset all" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var list = try parseColor(alloc, .osc_105, "");
    defer list.deinit(alloc);
    try testing.expectEqual(1, list.count());
    try testing.expectEqual(
        Request{ .reset_special = {} },
        list.at(0).*,
    );
}
test "OSC 10: OSC 11: OSC 12: OSC: 13: OSC 14: OSC 15: OSC: 16: OSC 17: OSC 18: OSC 19: dynamic" {
    const testing = std.testing;
    const alloc = testing.allocator;
    inline for (@typeInfo(DynamicColor).@"enum".fields) |field| {
        const color = @field(DynamicColor, field.name);
        const op = @field(Operation, std.fmt.comptimePrint(
            "osc_{d}",
            .{field.value},
        ));
        {
            var list = try parseColor(alloc, op, "red");
            defer list.deinit(alloc);
            try testing.expectEqual(1, list.count());
            try testing.expectEqual(
                Request{ .set = .{
                    .target = .{ .dynamic = color },
                    .color = RGB{ .r = 255, .g = 0, .b = 0 },
                } },
                list.at(0).*,
            );
        }
    }
}
test "OSC 10: OSC 11: OSC 12: OSC: 13: OSC 14: OSC 15: OSC: 16: OSC 17: OSC 18: OSC 19: dynamic multiple" {
    const testing = std.testing;
    const alloc = testing.allocator;
    {
        var list = try parseColor(
            alloc,
            .osc_11,
            "red;blue",
        );
        defer list.deinit(alloc);
        try testing.expectEqual(2, list.count());
        try testing.expectEqual(
            Request{ .set = .{
                .target = .{ .dynamic = .background },
                .color = RGB{ .r = 255, .g = 0, .b = 0 },
            } },
            list.at(0).*,
        );
        try testing.expectEqual(
            Request{ .set = .{
                .target = .{ .dynamic = .cursor },
                .color = RGB{ .r = 0, .g = 0, .b = 255 },
            } },
            list.at(1).*,
        );
    }
}
test "OSC 110: OSC 111: OSC 112: OSC: 113: OSC 114: OSC 115: OSC: 116: OSC 117: OSC 118: OSC 119: reset dynamic" {
    const testing = std.testing;
    const alloc = testing.allocator;
    inline for (@typeInfo(DynamicColor).@"enum".fields) |field| {
        const color = @field(DynamicColor, field.name);
        const op = @field(Operation, std.fmt.comptimePrint(
            "osc_1{d}",
            .{field.value},
        ));
        {
            var list = try parseColor(alloc, op, "");
            defer list.deinit(alloc);
            try testing.expectEqual(1, list.count());
            try testing.expectEqual(
                Request{ .reset = .{ .dynamic = color } },
                list.at(0).*,
            );
        }
        {
            var list = try parseColor(alloc, op, ";");
            defer list.deinit(alloc);
            try testing.expectEqual(1, list.count());
            try testing.expectEqual(
                Request{ .reset = .{ .dynamic = color } },
                list.at(0).*,
            );
        }
        {
            var list = try parseColor(alloc, op, " ");
            defer list.deinit(alloc);
            try testing.expectEqual(0, list.count());
        }
    }
}
