const std = @import("std");
const testing = std.testing;
const Target = @import("target.zig").Target;
pub fn Struct(
    comptime target: Target,
    comptime Zig: type,
) type {
    return switch (target) {
        .zig => Zig,
        .c => c: {
            const info = @typeInfo(Zig).@"struct";
            var names: [info.fields.len][]const u8 = undefined;
            var types: [info.fields.len]type = undefined;
            var attrs: [info.fields.len]std.builtin.Type.StructField.Attributes = undefined;
            for (info.fields, &names, &types, &attrs) |field, *name, *ty, *attr| {
                name.* = field.name;
                ty.* = field.type;
                attr.* = .{
                    .@"align" = field.alignment,
                    .@"comptime" = field.is_comptime,
                    .default_value_ptr = field.default_value_ptr,
                };
            }
            break :c @Struct(.@"extern", null, &names, &types, &attrs);
        },
    };
}
pub fn sizedFieldFits(
    comptime T: type,
    size: usize,
    comptime field: []const u8,
) bool {
    const offset = @offsetOf(T, field);
    const field_size = @sizeOf(@FieldType(T, field));
    return size >= offset + field_size;
}
test "sizedFieldFits boundary checks" {
    const Sized = extern struct {
        size: usize,
        a: u8,
        b: u32,
    };
    const size_required = @offsetOf(Sized, "size") + @sizeOf(@FieldType(Sized, "size"));
    const a_required = @offsetOf(Sized, "a") + @sizeOf(@FieldType(Sized, "a"));
    const b_required = @offsetOf(Sized, "b") + @sizeOf(@FieldType(Sized, "b"));
    try testing.expect(sizedFieldFits(Sized, size_required, "size"));
    try testing.expect(!sizedFieldFits(Sized, size_required - 1, "size"));
    try testing.expect(sizedFieldFits(Sized, a_required, "a"));
    try testing.expect(!sizedFieldFits(Sized, a_required - 1, "a"));
    try testing.expect(sizedFieldFits(Sized, b_required, "b"));
    try testing.expect(!sizedFieldFits(Sized, b_required - 1, "b"));
}
test "sizedFieldFits respects alignment padding" {
    const Sized = extern struct {
        size: usize,
        a: u8,
        b: u32,
    };
    const up_to_padding = @offsetOf(Sized, "b");
    try testing.expect(sizedFieldFits(Sized, up_to_padding, "a"));
    try testing.expect(!sizedFieldFits(Sized, up_to_padding, "b"));
}
test "packed struct converts to extern with full-size bools" {
    const Packed = packed struct {
        flag1: bool,
        flag2: bool,
        value: u8,
    };
    const C = Struct(.c, Packed);
    const info = @typeInfo(C).@"struct";
    try testing.expectEqual(.@"extern", info.layout);
    try testing.expectEqual(@as(usize, 1), @sizeOf(@FieldType(C, "flag1")));
    try testing.expectEqual(@as(usize, 1), @sizeOf(@FieldType(C, "flag2")));
    try testing.expectEqual(@as(usize, 1), @sizeOf(@FieldType(C, "value")));
    try testing.expectEqual(@as(usize, 3), @sizeOf(C));
}
