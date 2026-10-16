const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
pub const uint8 = u8;
pub const int8 = i8;
pub const uint16 = u16;
pub const int16 = i16;
pub const uint24 = u24;
pub const uint32 = u32;
pub const int32 = i32;
pub const Fixed = FixedPoint(i32, 16, 16);
pub const FWORD = i16;
pub const UFWORD = u16;
pub const F2DOT14 = FixedPoint(i16, 2, 14);
pub const LONGDATETIME = i64;
pub const Tag = [4]u8;
pub const Offset8 = u8;
pub const Offset16 = u16;
pub const Offset24 = u24;
pub const Offset32 = u32;
pub const Version16Dot16 = packed struct(u32) {
    minor: u16,
    major: u16,
};
pub const F26Dot6 = FixedPoint(i32, 26, 6);
fn FixedPoint(comptime T: type, int_bits: u64, frac_bits: u64) type {
    const type_info: std.builtin.Type.Int = @typeInfo(T).int;
    comptime assert(int_bits + frac_bits == type_info.bits);
    return packed struct(T) {
        const Self = FixedPoint(T, int_bits, frac_bits);
        const frac_factor: comptime_float = @floatFromInt(std.math.pow(
            u64,
            2,
            frac_bits,
        ));
        const half = @as(T, 1) << @intCast(frac_bits - 1);
        const Frac = std.meta.Int(.unsigned, frac_bits);
        const Int = std.meta.Int(type_info.signedness, int_bits);
        frac: Frac,
        int: Int,
        pub fn to(self: Self, comptime FloatType: type) FloatType {
            return @as(FloatType, @floatFromInt(
                @as(T, @bitCast(self)),
            )) / frac_factor;
        }
        pub fn from(float: anytype) Self {
            return @bitCast(
                @as(T, @intFromFloat(@round(float * frac_factor))),
            );
        }
        pub fn round(self: Self) T {
            if (self.frac & half != 0)
                return self.int + 1
            else
                return self.int;
        }
        pub fn format(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: *std.Io.Writer,
        ) !void {
            _ = fmt;
            _ = options;
            try writer.print("{d}", .{self.to(f64)});
        }
    };
}
test FixedPoint {
    const testing = std.testing;
    const p26d6 = F26Dot6.from(26.6);
    try testing.expectEqual(F26Dot6{
        .int = 26,
        .frac = 38,
    }, p26d6);
    try testing.expectEqual(26.59375, p26d6.to(f64));
    try testing.expectEqual(27, p26d6.round());
    const n26d6 = F26Dot6.from(-26.6);
    try testing.expectEqual(F26Dot6{
        .int = -27,
        .frac = 26,
    }, n26d6);
    try testing.expectEqual(-26.59375, n26d6.to(f64));
    try testing.expectEqual(-27, n26d6.round());
}
pub const SFNT = struct {
    const Directory = struct {
        offset: OffsetSubtable,
        records: []TableRecord,
        const OffsetSubtable = extern struct {
            sfnt_version: uint32 align(1),
            num_tables: uint16 align(1),
            search_range: uint16 align(1),
            entry_selector: uint16 align(1),
            range_shift: uint16 align(1),
            pub fn format(
                self: OffsetSubtable,
                comptime fmt: []const u8,
                options: std.fmt.FormatOptions,
                writer: *std.Io.Writer,
            ) !void {
                _ = fmt;
                _ = options;
                try writer.print(
                    "OffsetSubtable('{s}'){{ .num_tables = {} }}",
                    .{
                        if (self.sfnt_version == 0x00_01_00_00)
                            &@as([10]u8, "0x00010000".*)
                        else
                            &@as([4]u8, @bitCast(
                                std.mem.nativeToBig(u32, self.sfnt_version),
                            )),
                        self.num_tables,
                    },
                );
            }
        };
        const TableRecord = extern struct {
            tag: Tag align(1),
            checksum: uint32 align(1),
            offset: Offset32 align(1),
            length: uint32 align(1),
            pub fn format(
                self: TableRecord,
                comptime fmt: []const u8,
                options: std.fmt.FormatOptions,
                writer: *std.Io.Writer,
            ) !void {
                _ = fmt;
                _ = options;
                try writer.print(
                    "TableRecord(\"{s}\"){{ .checksum = {}, .offset = {}, .length = {} }}",
                    .{
                        self.tag,
                        self.checksum,
                        self.offset,
                        self.length,
                    },
                );
            }
        };
    };
    directory: Directory,
    data: []const u8,
    pub fn init(data: []const u8, alloc: Allocator) !SFNT {
        var reader: std.Io.Reader = .fixed(data);
        const byte_swap = native_endian != .big;
        var directory: Directory = undefined;
        try reader.readSliceAll(std.mem.asBytes(&directory.offset));
        if (byte_swap) std.mem.byteSwapAllFields(
            Directory.OffsetSubtable,
            &directory.offset,
        );
        directory.records = try alloc.alloc(Directory.TableRecord, directory.offset.num_tables);
        try reader.readSliceAll(std.mem.sliceAsBytes(directory.records));
        if (byte_swap) for (directory.records) |*record| {
            std.mem.byteSwapAllFields(
                Directory.TableRecord,
                record,
            );
        };
        return .{
            .directory = directory,
            .data = data,
        };
    }
    pub fn deinit(self: SFNT, alloc: Allocator) void {
        alloc.free(self.directory.records);
    }
    pub fn getTable(self: SFNT, tag: *const [4]u8) ?[]const u8 {
        for (self.directory.records) |record| {
            if (std.mem.eql(u8, tag, &record.tag)) {
                return self.data[record.offset..][0..record.length];
            }
        }
        return null;
    }
};
const native_endian = @import("builtin").target.cpu.arch.endian();
test "parse font" {
    if (comptime @import("terminal_options").artifact == .lib) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const test_font = @import("../embedded.zig").julia_mono;
    const sfnt = try SFNT.init(&test_font.*, alloc);
    defer sfnt.deinit(alloc);
    try testing.expectEqual(19, sfnt.directory.offset.num_tables);
    try testing.expectEqualStrings("prep", &sfnt.directory.records[18].tag);
}
test "get table" {
    if (comptime @import("terminal_options").artifact == .lib) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const test_font = @import("../embedded.zig").julia_mono;
    const sfnt = try SFNT.init(&test_font.*, alloc);
    defer sfnt.deinit(alloc);
    const svg = sfnt.getTable("SVG ").?;
    try testing.expectEqual(430, svg.len);
}
