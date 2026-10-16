const std = @import("std");
const Allocator = std.mem.Allocator;
const sfnt = @import("sfnt.zig");
const compat_reader = @import("../../lib/compat/reader.zig");
pub const Glyf = struct {
    data: []const u8,
    pub const Outline = struct {
        contours: []const sfnt.uint16,
        points: []const Point,
        pub const Point = struct {
            x: i32,
            y: i32,
            on_curve: bool,
        };
        pub fn contour(self: Outline, index: usize) []const Point {
            const start = if (index == 0)
                0
            else
                @as(usize, self.contours[index - 1]) + 1;
            const end = @as(usize, self.contours[index]) + 1;
            return self.points[start..end];
        }
        pub fn deinit(self: *Outline, alloc: Allocator) void {
            alloc.free(self.contours);
            alloc.free(self.points);
            self.* = undefined;
        }
    };
    pub const Entry = struct {
        header: Header,
        data: []const u8,
        pub const Header = extern struct {
            numberOfContours: sfnt.int16 align(1),
            xMin: sfnt.int16 align(1),
            yMin: sfnt.int16 align(1),
            xMax: sfnt.int16 align(1),
            yMax: sfnt.int16 align(1),
        };
        pub const SimpleFlags = packed struct(u8) {
            on_curve: bool,
            x_short: bool,
            y_short: bool,
            repeat: bool,
            x_repeat_or_sign: bool,
            y_repeat_or_sign: bool,
            overlap: bool,
            reserved: bool,
            pub inline fn xBytes(self: SimpleFlags) u2 {
                return if (self.x_short)
                    1
                else if (self.x_repeat_or_sign)
                    0
                else
                    2;
            }
            pub inline fn yBytes(self: SimpleFlags) u2 {
                return if (self.y_short)
                    1
                else if (self.y_repeat_or_sign)
                    0
                else
                    2;
            }
        };
        pub const Type = enum {
            simple,
            composite,
        };
        pub fn init(data: []const u8) std.Io.Reader.Error!Entry {
            var reader: std.Io.Reader = .fixed(data);
            const header = try compat_reader.readStructEndian(&reader, Header, .big);
            return .{ .header = header, .data = data[@sizeOf(Header)..] };
        }
        pub fn entryType(self: Entry) Type {
            return if (self.header.numberOfContours >= 0)
                .simple
            else
                .composite;
        }
        pub const SizeError = error{
            InstructionsNotSupported,
            CompositeNotSupported,
            EndPointsOutOfOrder,
            TooManyPoints,
        } || std.Io.Reader.Error;
        pub const DecodeError = SizeError || Allocator.Error || error{
            CoordinateOverflow,
        };
        pub fn size(self: Entry) SizeError!usize {
            var reader: std.Io.Reader = .fixed(self.data);
            switch (self.entryType()) {
                .simple => {
                    const num_contours: usize = @intCast(self.header.numberOfContours);
                    if (num_contours == 0 and self.data.len < 2) {
                        return @sizeOf(Header);
                    }
                    var max_point_index: isize = -1;
                    for (0..num_contours) |_| {
                        const index = try compat_reader.readerInt(&reader, sfnt.uint16, .big);
                        if (index <= max_point_index) return error.EndPointsOutOfOrder;
                        max_point_index = index;
                    }
                    const instructions_length = try compat_reader.readerInt(&reader, sfnt.uint16, .big);
                    if (instructions_length > 0) return error.InstructionsNotSupported;
                    var i: usize = 0;
                    var x_coords_len: usize = 0;
                    var y_coords_len: usize = 0;
                    while (i <= max_point_index) : (i += 1) {
                        const flag: SimpleFlags = @bitCast(try compat_reader.readByte(&reader));
                        x_coords_len += flag.xBytes();
                        y_coords_len += flag.yBytes();
                        if (flag.repeat) {
                            const repeat_count: usize = try compat_reader.readByte(&reader);
                            i += repeat_count;
                            x_coords_len += repeat_count * flag.xBytes();
                            y_coords_len += repeat_count * flag.yBytes();
                            if (i > max_point_index) return error.TooManyPoints;
                        }
                    }
                    try compat_reader.readSkipBytes(&reader, x_coords_len);
                    try compat_reader.readSkipBytes(&reader, y_coords_len);
                },
                .composite => {
                    return error.CompositeNotSupported;
                },
            }
            return @sizeOf(Header) + reader.seek;
        }
        pub fn decode(self: Entry, alloc: Allocator) DecodeError!Glyf.Outline {
            switch (self.entryType()) {
                .simple => {},
                .composite => return error.CompositeNotSupported,
            }
            var reader: std.Io.Reader = .fixed(self.data);
            const num_contours: usize = @intCast(self.header.numberOfContours);
            if (num_contours == 0 and self.data.len < 2) return .{
                .points = &.{},
                .contours = &.{},
            };
            const end_points = try alloc.alloc(sfnt.uint16, num_contours);
            errdefer alloc.free(end_points);
            if (num_contours == 0) {
                const instructions_length = try compat_reader.readerInt(&reader, sfnt.uint16, .big);
                if (instructions_length > 0) return error.InstructionsNotSupported;
                return .{ .points = &.{}, .contours = end_points };
            }
            const point_count: usize = point_count: {
                var prev_end_point: isize = -1;
                for (0..end_points.len) |i| {
                    const index = try compat_reader.readerInt(&reader, sfnt.uint16, .big);
                    if (index <= prev_end_point) return error.EndPointsOutOfOrder;
                    prev_end_point = index;
                    end_points[i] = index;
                }
                break :point_count @as(usize, end_points[end_points.len - 1]) + 1;
            };
            const instructions_length = try compat_reader.readerInt(&reader, sfnt.uint16, .big);
            if (instructions_length > 0) return error.InstructionsNotSupported;
            const points = try alloc.alloc(Glyf.Outline.Point, point_count);
            errdefer alloc.free(points);
            var flags_stack = std.heap.stackFallback(4096, alloc);
            const flags_alloc = flags_stack.get();
            const flags = try flags_alloc.alloc(SimpleFlags, point_count);
            defer flags_alloc.free(flags);
            {
                var point_i: usize = 0;
                while (point_i < point_count) {
                    const flag: SimpleFlags = @bitCast(try compat_reader.readByte(&reader));
                    flags[point_i] = flag;
                    point_i += 1;
                    if (flag.repeat) {
                        const repeat_count: usize = try compat_reader.readByte(&reader);
                        if (point_i + repeat_count > point_count) return error.TooManyPoints;
                        for (0..repeat_count) |_| {
                            flags[point_i] = flag;
                            point_i += 1;
                        }
                    }
                }
            }
            var x: i32 = 0;
            for (flags, points) |flag, *point| {
                const dx: i32 = if (flag.x_short) short: {
                    break :short if (flag.x_repeat_or_sign)
                        @as(i32, try compat_reader.readByte(&reader))
                    else
                        -@as(i32, try compat_reader.readByte(&reader));
                } else if (!flag.x_repeat_or_sign)
                    @as(i32, try compat_reader.readerInt(&reader, sfnt.int16, .big))
                else
                    0;
                x = std.math.add(
                    i32,
                    x,
                    dx,
                ) catch return error.CoordinateOverflow;
                point.x = x;
            }
            var y: i32 = 0;
            for (flags, points) |flag, *point| {
                const dy: i32 = if (flag.y_short) short: {
                    break :short if (flag.y_repeat_or_sign)
                        @as(i32, try compat_reader.readByte(&reader))
                    else
                        -@as(i32, try compat_reader.readByte(&reader));
                } else if (!flag.y_repeat_or_sign)
                    @as(i32, try compat_reader.readerInt(&reader, sfnt.int16, .big))
                else
                    0;
                y = std.math.add(
                    i32,
                    y,
                    dy,
                ) catch return error.CoordinateOverflow;
                point.y = y;
                point.on_curve = flag.on_curve;
            }
            return .{
                .points = points,
                .contours = end_points,
            };
        }
    };
    pub fn init(data: []const u8) Glyf {
        return .{ .data = data };
    }
    pub fn entry(self: Glyf, index: usize) std.Io.Reader.Error!Entry {
        return try Entry.init(self.data[index..]);
    }
};
pub fn getGlyph(font: sfnt.SFNT, index: usize) !struct { usize, Glyf.Entry } {
    comptime if (!@import("builtin").is_test)
        @compileError("This function is for testing only! It doesn't check bounds or anything!");
    const glyf = Glyf.init(font.getTable("glyf").?);
    const head = try @import("head.zig").Head.init(font.getTable("head").?);
    const loca = font.getTable("loca").?;
    const start_offset = switch (head.indexToLocFormat) {
        0 => @as(usize, std.mem.bigToNative(
            u16,
            std.mem.bytesAsSlice(u16, loca)[index],
        )) * 2,
        1 => @as(usize, std.mem.bigToNative(
            u32,
            std.mem.bytesAsSlice(u32, loca)[index],
        )),
        else => unreachable,
    };
    const end_offset = switch (head.indexToLocFormat) {
        0 => @as(usize, std.mem.bigToNative(
            u16,
            std.mem.bytesAsSlice(u16, loca)[index + 1],
        )) * 2,
        1 => @as(usize, std.mem.bigToNative(
            u32,
            std.mem.bytesAsSlice(u32, loca)[index + 1],
        )),
        else => unreachable,
    };
    return .{ end_offset - start_offset, try glyf.entry(start_offset) };
}
fn testAppendInt(
    buf: *std.ArrayList(u8),
    alloc: Allocator,
    comptime T: type,
    value: T,
) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .big);
    try buf.appendSlice(alloc, &bytes);
}
fn testAppendHeader(
    buf: *std.ArrayList(u8),
    alloc: Allocator,
    number_of_contours: i16,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
) !void {
    try testAppendInt(buf, alloc, i16, number_of_contours);
    try testAppendInt(buf, alloc, i16, x_min);
    try testAppendInt(buf, alloc, i16, y_min);
    try testAppendInt(buf, alloc, i16, x_max);
    try testAppendInt(buf, alloc, i16, y_max);
}
test "glyf" {
    if (comptime @import("terminal_options").artifact == .lib) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const test_font = @import("../embedded.zig").cozette;
    const font = try sfnt.SFNT.init(test_font, alloc);
    defer font.deinit(alloc);
    const len_nul, const glyph_nul = try getGlyph(font, 1);
    try testing.expect(glyph_nul.entryType() == .simple);
    try testing.expect(len_nul >= try glyph_nul.size());
    const len_A, const glyph_A = try getGlyph(font, 66);
    try testing.expect(glyph_A.entryType() == .simple);
    try testing.expect(len_A >= try glyph_A.size());
    var outline_A = try glyph_A.decode(alloc);
    defer outline_A.deinit(alloc);
    try testing.expectEqual(@as(usize, @intCast(glyph_A.header.numberOfContours)), outline_A.contours.len);
    try testing.expect(outline_A.points.len > 0);
    const len_Itilde, const glyph_Itilde = try getGlyph(font, 265);
    try testing.expect(glyph_Itilde.entryType() == .simple);
    try testing.expect(len_Itilde >= try glyph_Itilde.size());
}
test "glyf: decode triangle" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try testAppendHeader(&buf, alloc, 1, 100, 100, 900, 900);
    try testAppendInt(&buf, alloc, u16, 2); 
    try testAppendInt(&buf, alloc, u16, 0); 
    try buf.append(alloc, 0x01); 
    try buf.append(alloc, 0x01); 
    try buf.append(alloc, 0x01); 
    try testAppendInt(&buf, alloc, i16, 500);
    try testAppendInt(&buf, alloc, i16, -400);
    try testAppendInt(&buf, alloc, i16, 800);
    try testAppendInt(&buf, alloc, i16, 900);
    try testAppendInt(&buf, alloc, i16, -800);
    try testAppendInt(&buf, alloc, i16, 0);
    const glyph = try Glyf.Entry.init(buf.items);
    var outline = try glyph.decode(alloc);
    defer outline.deinit(alloc);
    try testing.expectEqual(@as(i16, 100), glyph.header.xMin);
    try testing.expectEqual(@as(i16, 900), glyph.header.xMax);
    try testing.expectEqual(@as(usize, 1), outline.contours.len);
    try testing.expectEqual(@as(usize, 3), outline.points.len);
    const contour = outline.contour(0);
    try testing.expectEqual(@as(usize, 3), contour.len);
    try testing.expectEqual(Glyf.Outline.Point{ .x = 500, .y = 900, .on_curve = true }, contour[0]);
    try testing.expectEqual(Glyf.Outline.Point{ .x = 100, .y = 100, .on_curve = true }, contour[1]);
    try testing.expectEqual(Glyf.Outline.Point{ .x = 900, .y = 100, .on_curve = true }, contour[2]);
}
test "glyf: decode multiple contours" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try testAppendHeader(&buf, alloc, 2, 0, 0, 30, 10);
    try testAppendInt(&buf, alloc, u16, 1); 
    try testAppendInt(&buf, alloc, u16, 3); 
    try testAppendInt(&buf, alloc, u16, 0); 
    for (0..4) |_| try buf.append(alloc, 0x01); 
    for ([_]i16{ 0, 10, 10, 10 }) |dx| try testAppendInt(&buf, alloc, i16, dx);
    for ([_]i16{ 0, 0, 10, 0 }) |dy| try testAppendInt(&buf, alloc, i16, dy);
    const glyph = try Glyf.Entry.init(buf.items);
    var outline = try glyph.decode(alloc);
    defer outline.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), outline.contours.len);
    try testing.expectEqual(@as(usize, 4), outline.points.len);
    try testing.expectEqual(@as(u16, 1), outline.contours[0]);
    try testing.expectEqual(@as(u16, 3), outline.contours[1]);
    try testing.expectEqual(@as(usize, 2), outline.contour(0).len);
    try testing.expectEqual(@as(usize, 2), outline.contour(1).len);
    try testing.expectEqual(outline.points[0..2].ptr, outline.contour(0).ptr);
    try testing.expectEqual(outline.points[2..4].ptr, outline.contour(1).ptr);
}
test "glyf: decode repeat and short vector flags" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try testAppendHeader(&buf, alloc, 1, 0, -16, 16, 0);
    try testAppendInt(&buf, alloc, u16, 3); 
    try testAppendInt(&buf, alloc, u16, 0); 
    try buf.append(alloc, 0x01 | 0x02 | 0x04 | 0x08 | 0x10); 
    try buf.append(alloc, 3); 
    for ([_]u8{ 1, 2, 4, 8 }) |dx| try buf.append(alloc, dx);
    for ([_]u8{ 1, 2, 4, 8 }) |dy| try buf.append(alloc, dy);
    const glyph = try Glyf.Entry.init(buf.items);
    var outline = try glyph.decode(alloc);
    defer outline.deinit(alloc);
    try testing.expectEqual(@as(usize, 4), outline.points.len);
    try testing.expectEqual(Glyf.Outline.Point{ .x = 1, .y = -1, .on_curve = true }, outline.points[0]);
    try testing.expectEqual(Glyf.Outline.Point{ .x = 3, .y = -3, .on_curve = true }, outline.points[1]);
    try testing.expectEqual(Glyf.Outline.Point{ .x = 7, .y = -7, .on_curve = true }, outline.points[2]);
    try testing.expectEqual(Glyf.Outline.Point{ .x = 15, .y = -15, .on_curve = true }, outline.points[3]);
}
test "glyf: decode off curve and same coordinate flags" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try testAppendHeader(&buf, alloc, 1, 0, 0, 7, 9);
    try testAppendInt(&buf, alloc, u16, 1); 
    try testAppendInt(&buf, alloc, u16, 0); 
    try buf.append(alloc, 0x10 | 0x20); 
    try buf.append(alloc, 0x01 | 0x02 | 0x04 | 0x10 | 0x20); 
    try buf.append(alloc, 7); 
    try buf.append(alloc, 9); 
    const glyph = try Glyf.Entry.init(buf.items);
    var outline = try glyph.decode(alloc);
    defer outline.deinit(alloc);
    try testing.expectEqual(Glyf.Outline.Point{ .x = 0, .y = 0, .on_curve = false }, outline.points[0]);
    try testing.expectEqual(Glyf.Outline.Point{ .x = 7, .y = 9, .on_curve = true }, outline.points[1]);
}
test "glyf: decode one-point contour" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try testAppendHeader(&buf, alloc, 1, 0, 0, 0, 0);
    try testAppendInt(&buf, alloc, u16, 0); 
    try testAppendInt(&buf, alloc, u16, 0); 
    try buf.append(alloc, 0x01 | 0x10 | 0x20); 
    const glyph = try Glyf.Entry.init(buf.items);
    var outline = try glyph.decode(alloc);
    defer outline.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), outline.points.len);
    try testing.expectEqual(@as(usize, 1), outline.contours.len);
    try testing.expectEqual(@as(u16, 0), outline.contours[0]);
    try testing.expectEqual(Glyf.Outline.Point{ .x = 0, .y = 0, .on_curve = true }, outline.contour(0)[0]);
}
test "glyf: decode contour ending at max point index" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try testAppendHeader(&buf, alloc, 1, 0, 0, 0, 0);
    try testAppendInt(&buf, alloc, u16, std.math.maxInt(u16)); 
    try testAppendInt(&buf, alloc, u16, 0); 
    const flag = 0x01 | 0x10 | 0x20; 
    var remaining: usize = @as(usize, std.math.maxInt(u16)) + 1;
    while (remaining > 0) {
        const run = @min(remaining, 256);
        if (run == 1) {
            try buf.append(alloc, flag);
        } else {
            try buf.append(alloc, flag | 0x08); 
            try buf.append(alloc, @intCast(run - 1));
        }
        remaining -= run;
    }
    const glyph = try Glyf.Entry.init(buf.items);
    var outline = try glyph.decode(alloc);
    defer outline.deinit(alloc);
    try testing.expectEqual(@as(usize, 65536), outline.points.len);
    try testing.expectEqual(@as(usize, 65536), outline.contour(0).len);
}
test "glyf: reject glyphs with instructions and composite glyphs" {
    if (comptime @import("terminal_options").artifact == .lib) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const test_font = @import("../embedded.zig").jetbrains_mono;
    const font = try sfnt.SFNT.init(test_font, alloc);
    defer font.deinit(alloc);
    const len_notdef, const glyph_notdef = try getGlyph(font, 0);
    try testing.expectEqual(100, len_notdef);
    try testing.expect(glyph_notdef.entryType() == .simple);
    try testing.expectError(
        Glyf.Entry.SizeError.InstructionsNotSupported,
        glyph_notdef.size(),
    );
    try testing.expectError(
        Glyf.Entry.DecodeError.InstructionsNotSupported,
        glyph_notdef.decode(alloc),
    );
    const len_Aacute, const glyph_Aacute = try getGlyph(font, 2);
    try testing.expectEqual(24, len_Aacute);
    try testing.expect(glyph_Aacute.entryType() == .composite);
    try testing.expectError(
        Glyf.Entry.SizeError.CompositeNotSupported,
        glyph_Aacute.size(),
    );
    try testing.expectError(
        Glyf.Entry.DecodeError.CompositeNotSupported,
        glyph_Aacute.decode(alloc),
    );
}
test "glyf: reject truncated" {
    if (comptime @import("terminal_options").artifact == .lib) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const test_font = @import("../embedded.zig").cozette;
    const font = try sfnt.SFNT.init(test_font, alloc);
    defer font.deinit(alloc);
    _, var glyph_nul = try getGlyph(font, 1);
    try testing.expect(glyph_nul.entryType() == .simple);
    glyph_nul.data = glyph_nul.data[0 .. 227 - @sizeOf(Glyf.Entry.Header)];
    try testing.expectError(Glyf.Entry.SizeError.EndOfStream, glyph_nul.size());
    try testing.expectError(Glyf.Entry.DecodeError.EndOfStream, glyph_nul.decode(alloc));
}
test "glyf: reject endpoints out of order" {
    if (comptime @import("terminal_options").artifact == .lib) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const test_font = try alloc.dupe(u8, @import("../embedded.zig").cozette[0..]);
    defer alloc.free(test_font);
    const font = try sfnt.SFNT.init(test_font, alloc);
    defer font.deinit(alloc);
    _, var glyph_nul = try getGlyph(font, 1);
    try testing.expect(glyph_nul.entryType() == .simple);
    std.mem.bytesAsSlice(u16, @as([]u8, @constCast(glyph_nul.data)))[3] = 0;
    try testing.expectError(Glyf.Entry.SizeError.EndPointsOutOfOrder, glyph_nul.size());
    try testing.expectError(
        Glyf.Entry.DecodeError.EndPointsOutOfOrder,
        glyph_nul.decode(alloc),
    );
}
test "glyf: reject too many points" {
    if (comptime @import("terminal_options").artifact == .lib) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const test_font = try alloc.dupe(u8, @import("../embedded.zig").cozette[0..]);
    defer alloc.free(test_font);
    const font = try sfnt.SFNT.init(test_font, alloc);
    defer font.deinit(alloc);
    _, var glyph_nul = try getGlyph(font, 1);
    try testing.expect(glyph_nul.entryType() == .simple);
    @as([]u8, @constCast(glyph_nul.data))[107] |= 0x08;
    @as([]u8, @constCast(glyph_nul.data))[108] = 0xFF;
    try testing.expectError(Glyf.Entry.SizeError.TooManyPoints, glyph_nul.size());
    try testing.expectError(Glyf.Entry.DecodeError.TooManyPoints, glyph_nul.decode(alloc));
}
test "glyf: zero-contour glyph can be header-only" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const header: Glyf.Entry.Header = .{
        .numberOfContours = 0,
        .xMin = 0,
        .yMin = 0,
        .xMax = 0,
        .yMax = 0,
    };
    const glyph = try Glyf.Entry.init(std.mem.asBytes(&header));
    try testing.expectEqual(@sizeOf(Glyf.Entry.Header), try glyph.size());
    var outline = try glyph.decode(alloc);
    defer outline.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), outline.points.len);
    try testing.expectEqual(@as(usize, 0), outline.contours.len);
}
test "glyf: zero-contour glyph can include instruction length" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try testAppendHeader(&buf, alloc, 0, 0, 0, 0, 0);
    try testAppendInt(&buf, alloc, u16, 0); 
    const glyph = try Glyf.Entry.init(buf.items);
    try testing.expectEqual(@sizeOf(Glyf.Entry.Header) + 2, try glyph.size());
    var outline = try glyph.decode(alloc);
    defer outline.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), outline.points.len);
    try testing.expectEqual(@as(usize, 0), outline.contours.len);
}
test "glyf: zero-contour glyph rejects instructions" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try testAppendHeader(&buf, alloc, 0, 0, 0, 0, 0);
    try testAppendInt(&buf, alloc, u16, 1); 
    const glyph = try Glyf.Entry.init(buf.items);
    try testing.expectError(Glyf.Entry.SizeError.InstructionsNotSupported, glyph.size());
    try testing.expectError(Glyf.Entry.DecodeError.InstructionsNotSupported, glyph.decode(alloc));
}
