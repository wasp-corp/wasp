const std = @import("std");
const testing = std.testing;
const lib = @import("../lib.zig");
const page = @import("../page.zig");
const Cell = page.Cell;
const color = @import("../color.zig");
const style_c = @import("style.zig");
const Result = @import("result.zig").Result;
pub const CCell = u64;
pub const CellsView = extern struct {
    ptr: ?[*]const CCell,
    len: usize,
};
pub const ContentTag = enum(c_int) {
    codepoint = 0,
    codepoint_grapheme = 1,
    bg_color_palette = 2,
    bg_color_rgb = 3,
};
pub const Wide = enum(c_int) {
    narrow = 0,
    wide = 1,
    spacer_tail = 2,
    spacer_head = 3,
};
pub const SemanticContent = enum(c_int) {
    output = 0,
    input = 1,
    prompt = 2,
};
pub const CellData = enum(c_int) {
    invalid = 0,
    codepoint = 1,
    content_tag = 2,
    wide = 3,
    has_text = 4,
    has_styling = 5,
    style_id = 6,
    has_hyperlink = 7,
    protected = 8,
    semantic_content = 9,
    color_palette = 10,
    color_rgb = 11,
    pub fn OutType(comptime self: CellData) type {
        return switch (self) {
            .invalid => void,
            .codepoint => u32,
            .content_tag => ContentTag,
            .wide => Wide,
            .has_text, .has_styling, .has_hyperlink, .protected => bool,
            .style_id => u16,
            .semantic_content => SemanticContent,
            .color_palette => u8,
            .color_rgb => color.RGB.C,
        };
    }
};
pub fn get(
    cell_: CCell,
    data: CellData,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.enums.fromInt(CellData, @intFromEnum(data)) orelse {
            return .invalid_value;
        };
    }
    return switch (data) {
        .invalid => .invalid_value,
        inline else => |comptime_data| getTyped(
            cell_,
            comptime_data,
            @ptrCast(@alignCast(out)),
        ),
    };
}
pub fn get_multi(
    cell_: CCell,
    count: usize,
    keys: ?[*]const CellData,
    values: ?[*]?*anyopaque,
    out_written: ?*usize,
) callconv(lib.calling_conv) Result {
    const k = keys orelse return .invalid_value;
    const v = values orelse return .invalid_value;
    for (0..count) |i| {
        const result = get(cell_, k[i], v[i]);
        if (result != .success) {
            if (out_written) |w| w.* = i;
            return result;
        }
    }
    if (out_written) |w| w.* = count;
    return .success;
}
fn getTyped(
    cell_: CCell,
    comptime data: CellData,
    out: *data.OutType(),
) Result {
    const cell: Cell = @bitCast(cell_);
    switch (data) {
        .invalid => return .invalid_value,
        .codepoint => out.* = @intCast(cell.codepoint()),
        .content_tag => out.* = @enumFromInt(@intFromEnum(cell.content_tag)),
        .wide => out.* = @enumFromInt(@intFromEnum(cell.wide)),
        .has_text => out.* = cell.hasText(),
        .has_styling => out.* = cell.hasStyling(),
        .style_id => out.* = cell.style_id,
        .has_hyperlink => out.* = cell.hyperlink,
        .protected => out.* = cell.protected,
        .semantic_content => out.* = @enumFromInt(@intFromEnum(cell.semantic_content)),
        .color_palette => out.* = cell.content.color_palette.data,
        .color_rgb => {
            const rgb = cell.content.color_rgb;
            out.* = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
        },
    }
    return .success;
}
test "get codepoint" {
    const cell: CCell = @bitCast(Cell.init('A'));
    var cp: u32 = 0;
    try testing.expectEqual(Result.success, get(cell, .codepoint, @ptrCast(&cp)));
    try testing.expectEqual(@as(u32, 'A'), cp);
}
test "get has_text" {
    const cell: CCell = @bitCast(Cell.init('A'));
    var has: bool = false;
    try testing.expectEqual(Result.success, get(cell, .has_text, @ptrCast(&has)));
    try testing.expect(has);
}
test "get empty cell" {
    const cell: CCell = @bitCast(Cell.init(0));
    var has: bool = true;
    try testing.expectEqual(Result.success, get(cell, .has_text, @ptrCast(&has)));
    try testing.expect(!has);
}
test "get wide" {
    var zig_cell = Cell.init('A');
    zig_cell.wide = .wide;
    const cell: CCell = @bitCast(zig_cell);
    var w: Wide = .narrow;
    try testing.expectEqual(Result.success, get(cell, .wide, @ptrCast(&w)));
    try testing.expectEqual(Wide.wide, w);
}
test "get_multi success" {
    const cell: CCell = @bitCast(Cell.init('B'));
    var cp: u32 = 0;
    var has_text: bool = false;
    var written: usize = 0;
    const keys = [_]CellData{ .codepoint, .has_text };
    var values = [_]?*anyopaque{ @ptrCast(&cp), @ptrCast(&has_text) };
    try testing.expectEqual(Result.success, get_multi(cell, keys.len, &keys, &values, &written));
    try testing.expectEqual(keys.len, written);
    try testing.expectEqual(@as(u32, 'B'), cp);
    try testing.expect(has_text);
}
test "get_multi error sets out_written" {
    const cell: CCell = @bitCast(Cell.init('C'));
    var cp: u32 = 0;
    var written: usize = 99;
    const keys = [_]CellData{ .codepoint, .invalid };
    var values = [_]?*anyopaque{ @ptrCast(&cp), @ptrCast(&cp) };
    try testing.expectEqual(Result.invalid_value, get_multi(cell, keys.len, &keys, &values, &written));
    try testing.expectEqual(1, written);
    try testing.expectEqual(@as(u32, 'C'), cp);
}
test "get_multi null keys returns invalid_value" {
    const cell: CCell = @bitCast(Cell.init('A'));
    var cp: u32 = 0;
    var values = [_]?*anyopaque{@ptrCast(&cp)};
    try testing.expectEqual(Result.invalid_value, get_multi(cell, 1, null, &values, null));
}
test "get_multi null values returns invalid_value" {
    const cell: CCell = @bitCast(Cell.init('A'));
    const keys = [_]CellData{.codepoint};
    try testing.expectEqual(Result.invalid_value, get_multi(cell, 1, &keys, null, null));
}
