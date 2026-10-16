const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
pub const Layout = struct {
    width: usize,
    height: usize,
    x: usize,
    y: usize,
    content: Content,
    pub const Content = union(enum) {
        pane: usize,
        horizontal: []const Layout,
        vertical: []const Layout,
    };
    pub const ParseError = Allocator.Error || error{SyntaxError};
    pub fn parseWithChecksum(
        alloc: Allocator,
        str: []const u8,
    ) (ParseError || error{ChecksumMismatch})!Layout {
        if (str.len < 5) return error.SyntaxError;
        if (str[4] != ',') return error.SyntaxError;
        const checksum: Checksum = .calculate(str[5..]);
        if (!std.mem.startsWith(
            u8,
            str,
            &checksum.asString(),
        )) return error.ChecksumMismatch;
        return try parse(alloc, str[5..]);
    }
    pub fn parse(alloc: Allocator, str: []const u8) ParseError!Layout {
        var offset: usize = 0;
        const root = try parseNext(
            alloc,
            str,
            &offset,
        );
        if (offset != str.len) return error.SyntaxError;
        return root;
    }
    fn parseNext(
        alloc: Allocator,
        str: []const u8,
        offset: *usize,
    ) ParseError!Layout {
        const width: usize = if (std.mem.indexOfScalar(
            u8,
            str[offset.*..],
            'x',
        )) |idx| width: {
            defer offset.* += idx + 1; 
            break :width std.fmt.parseInt(
                usize,
                str[offset.* .. offset.* + idx],
                10,
            ) catch return error.SyntaxError;
        } else return error.SyntaxError;
        const height: usize = if (std.mem.indexOfScalar(
            u8,
            str[offset.*..],
            ',',
        )) |idx| height: {
            defer offset.* += idx + 1; 
            break :height std.fmt.parseInt(
                usize,
                str[offset.* .. offset.* + idx],
                10,
            ) catch return error.SyntaxError;
        } else return error.SyntaxError;
        const x: usize = if (std.mem.indexOfScalar(
            u8,
            str[offset.*..],
            ',',
        )) |idx| x: {
            defer offset.* += idx + 1; 
            break :x std.fmt.parseInt(
                usize,
                str[offset.* .. offset.* + idx],
                10,
            ) catch return error.SyntaxError;
        } else return error.SyntaxError;
        const y: usize = if (std.mem.indexOfAny(
            u8,
            str[offset.*..],
            ",{[",
        )) |idx| y: {
            defer offset.* += idx; 
            break :y std.fmt.parseInt(
                usize,
                str[offset.* .. offset.* + idx],
                10,
            ) catch return error.SyntaxError;
        } else return error.SyntaxError;
        const content: Layout.Content = switch (str[offset.*]) {
            ',' => content: {
                offset.* += 1;
                const idx = std.mem.indexOfAny(
                    u8,
                    str[offset.*..],
                    ",}]",
                ) orelse str.len - offset.*;
                defer offset.* += idx; 
                const pane_id = std.fmt.parseInt(
                    usize,
                    str[offset.* .. offset.* + idx],
                    10,
                ) catch return error.SyntaxError;
                break :content .{ .pane = pane_id };
            },
            '{', '[' => |opening| content: {
                var nodes: std.ArrayList(Layout) = .empty;
                defer nodes.deinit(alloc);
                offset.* += 1;
                while (true) {
                    try nodes.append(alloc, try parseNext(
                        alloc,
                        str,
                        offset,
                    ));
                    if (offset.* >= str.len) return error.SyntaxError;
                    if (str[offset.*] == ',') {
                        offset.* += 1; 
                        continue;
                    }
                    switch (opening) {
                        '{' => if (str[offset.*] != '}') return error.SyntaxError,
                        '[' => if (str[offset.*] != ']') return error.SyntaxError,
                        else => return error.SyntaxError,
                    }
                    offset.* += 1; 
                    break :content switch (opening) {
                        '{' => .{ .horizontal = try nodes.toOwnedSlice(alloc) },
                        '[' => .{ .vertical = try nodes.toOwnedSlice(alloc) },
                        else => unreachable,
                    };
                }
            },
            else => unreachable,
        };
        return .{
            .width = width,
            .height = height,
            .x = x,
            .y = y,
            .content = content,
        };
    }
};
pub const Checksum = enum(u16) {
    _,
    pub fn calculate(str: []const u8) Checksum {
        var result: u16 = 0;
        for (str) |c| {
            result = (result >> 1) | ((result & 1) << 15);
            result +%= c;
        }
        return @enumFromInt(result);
    }
    pub fn asString(self: Checksum) [4]u8 {
        const value = @intFromEnum(self);
        const charset = "0123456789abcdef";
        return .{
            charset[(value >> 12) & 0xf],
            charset[(value >> 8) & 0xf],
            charset[(value >> 4) & 0xf],
            charset[value & 0xf],
        };
    }
};
test "simple single pane" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0,42");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);
    try testing.expectEqual(0, layout.x);
    try testing.expectEqual(0, layout.y);
    try testing.expectEqual(42, layout.content.pane);
}
test "single pane with offset" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(arena.allocator(), "40x12,10,5,7");
    try testing.expectEqual(40, layout.width);
    try testing.expectEqual(12, layout.height);
    try testing.expectEqual(10, layout.x);
    try testing.expectEqual(5, layout.y);
    try testing.expectEqual(7, layout.content.pane);
}
test "single pane large values" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(arena.allocator(), "1920x1080,100,200,999");
    try testing.expectEqual(1920, layout.width);
    try testing.expectEqual(1080, layout.height);
    try testing.expectEqual(100, layout.x);
    try testing.expectEqual(200, layout.y);
    try testing.expectEqual(999, layout.content.pane);
}
test "horizontal split two panes" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0{40x24,0,0,1,40x24,40,0,2}");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);
    try testing.expectEqual(0, layout.x);
    try testing.expectEqual(0, layout.y);
    const children = layout.content.horizontal;
    try testing.expectEqual(2, children.len);
    try testing.expectEqual(40, children[0].width);
    try testing.expectEqual(24, children[0].height);
    try testing.expectEqual(0, children[0].x);
    try testing.expectEqual(0, children[0].y);
    try testing.expectEqual(1, children[0].content.pane);
    try testing.expectEqual(40, children[1].width);
    try testing.expectEqual(24, children[1].height);
    try testing.expectEqual(40, children[1].x);
    try testing.expectEqual(0, children[1].y);
    try testing.expectEqual(2, children[1].content.pane);
}
test "vertical split two panes" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0[80x12,0,0,1,80x12,0,12,2]");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);
    try testing.expectEqual(0, layout.x);
    try testing.expectEqual(0, layout.y);
    const children = layout.content.vertical;
    try testing.expectEqual(2, children.len);
    try testing.expectEqual(80, children[0].width);
    try testing.expectEqual(12, children[0].height);
    try testing.expectEqual(0, children[0].x);
    try testing.expectEqual(0, children[0].y);
    try testing.expectEqual(1, children[0].content.pane);
    try testing.expectEqual(80, children[1].width);
    try testing.expectEqual(12, children[1].height);
    try testing.expectEqual(0, children[1].x);
    try testing.expectEqual(12, children[1].y);
    try testing.expectEqual(2, children[1].content.pane);
}
test "horizontal split three panes" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(arena.allocator(), "120x24,0,0{40x24,0,0,1,40x24,40,0,2,40x24,80,0,3}");
    try testing.expectEqual(120, layout.width);
    try testing.expectEqual(24, layout.height);
    const children = layout.content.horizontal;
    try testing.expectEqual(3, children.len);
    try testing.expectEqual(1, children[0].content.pane);
    try testing.expectEqual(2, children[1].content.pane);
    try testing.expectEqual(3, children[2].content.pane);
}
test "nested horizontal in vertical" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0[80x12,0,0,1,80x12,0,12{40x12,0,12,2,40x12,40,12,3}]");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);
    const vert_children = layout.content.vertical;
    try testing.expectEqual(2, vert_children.len);
    try testing.expectEqual(1, vert_children[0].content.pane);
    const horiz_children = vert_children[1].content.horizontal;
    try testing.expectEqual(2, horiz_children.len);
    try testing.expectEqual(2, horiz_children[0].content.pane);
    try testing.expectEqual(3, horiz_children[1].content.pane);
}
test "nested vertical in horizontal" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0{40x24,0,0,1,40x24,40,0[40x12,40,0,2,40x12,40,12,3]}");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);
    const horiz_children = layout.content.horizontal;
    try testing.expectEqual(2, horiz_children.len);
    try testing.expectEqual(1, horiz_children[0].content.pane);
    const vert_children = horiz_children[1].content.vertical;
    try testing.expectEqual(2, vert_children.len);
    try testing.expectEqual(2, vert_children[0].content.pane);
    try testing.expectEqual(3, vert_children[1].content.pane);
}
test "deeply nested layout" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0{40x24,0,0[40x12,0,0,1,40x12,0,12,2],40x24,40,0,3}");
    const horiz = layout.content.horizontal;
    try testing.expectEqual(2, horiz.len);
    const vert = horiz[0].content.vertical;
    try testing.expectEqual(2, vert.len);
    try testing.expectEqual(1, vert[0].content.pane);
    try testing.expectEqual(2, vert[1].content.pane);
    try testing.expectEqual(3, horiz[1].content.pane);
}
test "syntax error empty string" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), ""));
}
test "syntax error missing width" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "x24,0,0,1"));
}
test "syntax error missing height" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x,0,0,1"));
}
test "syntax error missing x" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,,0,1"));
}
test "syntax error missing y" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,,1"));
}
test "syntax error missing pane id" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0,"));
}
test "syntax error non-numeric width" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "abcx24,0,0,1"));
}
test "syntax error non-numeric pane id" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0,abc"));
}
test "syntax error unclosed horizontal bracket" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0{40x24,0,0,1"));
}
test "syntax error unclosed vertical bracket" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0[40x24,0,0,1"));
}
test "syntax error mismatched brackets" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0{40x24,0,0,1]"));
    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0[40x24,0,0,1}"));
}
test "syntax error trailing data" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0,1extra"));
}
test "syntax error no x separator" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "8024,0,0,1"));
}
test "syntax error no content delimiter" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0"));
}
test "parseWithChecksum valid" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parseWithChecksum(arena.allocator(), "f8f9,80x24,0,0{40x24,0,0,1,40x24,40,0,2}");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);
}
test "parseWithChecksum mismatch" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.ChecksumMismatch, Layout.parseWithChecksum(arena.allocator(), "0000,80x24,0,0{40x24,0,0,1,40x24,40,0,2}"));
}
test "parseWithChecksum too short" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.SyntaxError, Layout.parseWithChecksum(arena.allocator(), "bb62"));
    try testing.expectError(error.SyntaxError, Layout.parseWithChecksum(arena.allocator(), ""));
}
test "parseWithChecksum missing comma" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.SyntaxError, Layout.parseWithChecksum(arena.allocator(), "bb62x159x48,0,0"));
}
test "checksum empty string" {
    const checksum = Checksum.calculate("");
    try testing.expectEqual(@as(u16, 0), @intFromEnum(checksum));
    try testing.expectEqualStrings("0000", &checksum.asString());
}
test "checksum single character" {
    const checksum = Checksum.calculate("A");
    try testing.expectEqual(@as(u16, 65), @intFromEnum(checksum));
    try testing.expectEqualStrings("0041", &checksum.asString());
}
test "checksum two characters" {
    const checksum = Checksum.calculate("AB");
    try testing.expectEqual(@as(u16, 32866), @intFromEnum(checksum));
    try testing.expectEqualStrings("8062", &checksum.asString());
}
test "checksum simple layout" {
    const checksum = Checksum.calculate("80x24,0,0,42");
    try testing.expectEqualStrings("d962", &checksum.asString());
}
test "checksum horizontal split layout" {
    const checksum = Checksum.calculate("80x24,0,0{40x24,0,0,1,40x24,40,0,2}");
    try testing.expectEqualStrings("f8f9", &checksum.asString());
}
test "checksum asString zero padding" {
    const checksum: Checksum = @enumFromInt(0x000f);
    try testing.expectEqualStrings("000f", &checksum.asString());
}
test "checksum asString all digits" {
    const checksum: Checksum = @enumFromInt(0x1234);
    try testing.expectEqualStrings("1234", &checksum.asString());
}
test "checksum asString with letters" {
    const checksum: Checksum = @enumFromInt(0xabcd);
    try testing.expectEqualStrings("abcd", &checksum.asString());
}
test "checksum asString max value" {
    const checksum: Checksum = @enumFromInt(0xffff);
    try testing.expectEqualStrings("ffff", &checksum.asString());
}
test "checksum wraparound" {
    const checksum = Checksum.calculate("\xff\xff\xff\xff\xff\xff\xff\xff");
    try testing.expectEqualStrings("03fc", &checksum.asString());
}
test "checksum deterministic" {
    const str = "159x48,0,0{79x48,0,0,79x48,80,0}";
    const checksum1 = Checksum.calculate(str);
    const checksum2 = Checksum.calculate(str);
    try testing.expectEqual(checksum1, checksum2);
}
test "checksum different inputs different outputs" {
    const checksum1 = Checksum.calculate("80x24,0,0,1");
    const checksum2 = Checksum.calculate("80x24,0,0,2");
    try testing.expect(@intFromEnum(checksum1) != @intFromEnum(checksum2));
}
test "checksum known tmux layout bb62" {
    const checksum = Checksum.calculate("159x48,0,0{79x48,0,0,79x48,80,0}");
    try testing.expectEqualStrings("bb62", &checksum.asString());
}
