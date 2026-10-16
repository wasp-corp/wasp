const std = @import("std");
const assert = std.debug.assert;
const config = @import("config.zig");
const Allocator = std.mem.Allocator;
pub const fields = &config.mergeFields(config.fields, &.{
    .{ .name = "width", .type = u2 },
    .{ .name = "is_symbol", .type = bool },
});
pub const build_components = &config.mergeComponents(config.build_components, &.{
    .{
        .Impl = WidthComponent,
        .inputs = &.{
            "wcwidth_standalone",
            "wcwidth_zero_in_grapheme",
            "is_emoji_modifier",
            "grapheme_break_no_control",
        },
        .fields = &.{"width"},
    },
    .{
        .Impl = IsSymbolComponent,
        .inputs = &.{ "block", "general_category" },
        .fields = &.{"is_symbol"},
    },
});
pub const get_components: []const config.Component = &.{};
pub const tables = [_]config.Table{
    .{
        .name = "runtime",
        .fields = &.{
            "is_emoji_presentation",
            "case_folding_full",
        },
    },
    .{
        .name = "libvaxis_only",
        .fields = &.{
            "east_asian_width",
            "general_category",
            "grapheme_break",
        },
    },
    .{
        .name = "buildtime",
        .packing = .unpacked,
        .fields = &.{
            "width",
            "wcwidth_zero_in_grapheme",
            "grapheme_break_no_control",
            "is_symbol",
            "is_emoji_vs_base",
        },
    },
};
const WidthComponent = struct {
    pub fn build(
        comptime InputRow: type,
        comptime Row: type,
        allocator: std.mem.Allocator,
        io: std.Io,
        inputs: config.MultiSlice(InputRow),
        rows: *config.MultiSlice(Row),
        backing: anytype,
        tracking: anytype,
    ) !void {
        _ = allocator;
        _ = io;
        _ = backing;
        _ = tracking;
        rows.len = config.num_code_points;
        const items = rows.items(.width);
        const standalone = inputs.items(.wcwidth_standalone);
        const zero_in_grapheme = inputs.items(.wcwidth_zero_in_grapheme);
        const is_emoji_modifier = inputs.items(.is_emoji_modifier);
        const grapheme_break_no_control = inputs.items(.grapheme_break_no_control);
        for (0..config.num_code_points) |i| {
            if (zero_in_grapheme[i] and !is_emoji_modifier[i] and grapheme_break_no_control[i] != .prepend) {
                items[i] = 0;
            } else {
                items[i] = @min(2, standalone[i]);
            }
        }
    }
};
const IsSymbolComponent = struct {
    pub fn build(
        comptime InputRow: type,
        comptime Row: type,
        allocator: std.mem.Allocator,
        io: std.Io,
        inputs: config.MultiSlice(InputRow),
        rows: *config.MultiSlice(Row),
        backing: anytype,
        tracking: anytype,
    ) !void {
        _ = allocator;
        _ = io;
        _ = backing;
        _ = tracking;
        rows.len = config.num_code_points;
        const items = rows.items(.is_symbol);
        const block = inputs.items(.block);
        const general_category = inputs.items(.general_category);
        for (0..config.num_code_points) |i| {
            items[i] =
                general_category[i] == .other_private_use or
                block[i] == .arrows or
                block[i] == .dingbats or
                block[i] == .emoticons or
                block[i] == .miscellaneous_symbols or
                block[i] == .enclosed_alphanumerics or
                block[i] == .enclosed_alphanumeric_supplement or
                block[i] == .miscellaneous_symbols_and_pictographs or
                block[i] == .transport_and_map_symbols;
        }
    }
};
