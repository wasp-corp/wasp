const std = @import("std");
common: bool,
func_sections: bool,
data_sections: bool,
pic_level: PicLevel,
is_pie: bool,
optimization_level: OptimizationLevel,
is_ropi: bool,
is_rwpi: bool,
debug: DebugFormat,
dwarf_version: DwarfVersion,
pub const DebugFormat = union(enum) {
    strip,
    dwarf: std.dwarf.Format,
    code_view,
};
pub const DwarfVersion = enum(u3) {
    @"0" = 0,
    @"2" = 2,
    @"3" = 3,
    @"4" = 4,
    @"5" = 5,
};
pub const PicLevel = enum(u8) {
    none = 0,
    one = 1,
    two = 2,
};
pub const OptimizationLevel = enum {
    @"0",
    @"1",
    @"2",
    @"3",
    s,
    fast,
    g,
    z,
    const level_map = std.StaticStringMap(OptimizationLevel).initComptime(.{
        .{ "0", .@"0" },
        .{ "1", .@"1" },
        .{ "2", .@"2" },
        .{ "3", .@"3" },
        .{ "s", .s },
        .{ "fast", .fast },
        .{ "g", .g },
        .{ "z", .z },
    });
    pub fn fromString(str: []const u8) ?OptimizationLevel {
        return level_map.get(str);
    }
    pub fn isSizeOptimized(self: OptimizationLevel) bool {
        return switch (self) {
            .s, .z => true,
            .@"0", .@"1", .@"2", .@"3", .fast, .g => false,
        };
    }
    pub fn hasAnyOptimizations(self: OptimizationLevel) bool {
        return switch (self) {
            .@"0" => false,
            .@"1", .@"2", .@"3", .s, .fast, .g, .z => true,
        };
    }
};
pub const default: @This() = .{
    .common = false,
    .func_sections = false,
    .data_sections = false,
    .pic_level = .none,
    .is_pie = false,
    .is_ropi = false,
    .is_rwpi = false,
    .optimization_level = .@"0",
    .debug = .strip,
    .dwarf_version = .@"0",
};
