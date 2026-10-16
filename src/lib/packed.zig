const std = @import("std");
const testing = std.testing;
pub const FieldOptions = struct {
    name: ?[]const u8 = null,
    type_name: ?[]const u8 = null,
    omit: bool = false,
    encoding: Encoding = .scalar,
    pub const Encoding = union(enum) {
        scalar,
        @"packed": type,
        tagged_union: type,
    };
};
pub fn Packed(
    comptime T: type,
    comptime options: PackedOptions(T),
) type {
    const info = packedStructInfo(T);
    const FieldT = std.meta.FieldEnum(T);
    return struct {
        pub const Zig = T;
        comptime {
            for (info.fields, 0..) |field, i| {
                const field_options = @field(options.fields, field.name);
                if (field_options.omit) {
                    if (field_options.name != null or
                        field_options.type_name != null or
                        field_options.encoding != .scalar)
                    {
                        @compileError("omitted packed field has other options: " ++ field.name);
                    }
                    continue;
                }
                if (field_options.name) |name| {
                    if (name.len == 0)
                        @compileError("packed field name cannot be empty: " ++ field.name);
                }
                switch (field_options.encoding) {
                    .scalar => switch (@typeInfo(field.type)) {
                        .bool, .int, .@"enum" => {},
                        else => @compileError("packed field requires an explicit encoding: " ++ field.name),
                    },
                    .@"packed" => |Layout| {
                        if (Layout.Zig != field.type)
                            @compileError("nested packed layout has the wrong Zig type: " ++ field.name);
                        if (field_options.type_name != null)
                            @compileError("nested packed field cannot have a scalar type name: " ++ field.name);
                    },
                    .tagged_union => |Layout| {
                        if (Layout.Owner != T or Layout.Union != field.type or
                            Layout.union_field != @field(FieldT, field.name))
                        {
                            @compileError("tagged union layout does not match packed field: " ++ field.name);
                        }
                        if (field_options.type_name != null)
                            @compileError("tagged union field cannot have a scalar type name: " ++ field.name);
                    },
                }
                const public_name = field_options.name orelse field.name;
                for (info.fields[0..i]) |previous| {
                    const previous_options = @field(options.fields, previous.name);
                    if (previous_options.omit) continue;
                    const previous_name = previous_options.name orelse previous.name;
                    if (std.mem.eql(u8, public_name, previous_name))
                        @compileError("duplicate public packed field name: " ++ public_name);
                }
            }
        }
        pub const Backing = info.backing_integer.?;
        pub const Field = std.meta.FieldEnum(T);
        pub fn fieldOptions(comptime field: Field) FieldOptions {
            return @field(options.fields, @tagName(field));
        }
        pub fn fieldName(comptime field: Field) ?[]const u8 {
            const field_options = fieldOptions(field);
            if (field_options.omit) return null;
            return field_options.name orelse @tagName(field);
        }
        pub fn bitOffset(comptime field: Field) usize {
            return @bitOffsetOf(T, @tagName(field));
        }
        pub fn bitWidth(comptime field: Field) usize {
            return @bitSizeOf(@FieldType(T, @tagName(field)));
        }
    };
}
pub fn PackedOptions(comptime T: type) type {
    const fields = packedStructInfo(T).fields;
    const default_options: FieldOptions = .{};
    var names: [fields.len][]const u8 = undefined;
    var types: [fields.len]type = undefined;
    var attrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
    for (fields, 0..) |field, i| {
        names[i] = field.name;
        types[i] = FieldOptions;
        attrs[i] = .{ .default_value_ptr = &default_options };
    }
    const Fields = @Struct(.auto, null, &names, &types, &attrs);
    return struct {
        fields: Fields = .{},
    };
}
pub fn PackedTaggedUnion(
    comptime OwnerT: type,
    comptime union_field_value: std.meta.FieldEnum(OwnerT),
    comptime tag_field_value: std.meta.FieldEnum(OwnerT),
    comptime options: PackedTaggedUnionOptions(
        @FieldType(OwnerT, @tagName(union_field_value)),
        @FieldType(OwnerT, @tagName(tag_field_value)),
    ),
) type {
    _ = packedStructInfo(OwnerT);
    const UnionT = @FieldType(OwnerT, @tagName(union_field_value));
    const union_info = @typeInfo(UnionT).@"union";
    if (union_info.layout != .@"packed")
        @compileError("packed tagged union value must be a packed union");
    const TagT = @FieldType(OwnerT, @tagName(tag_field_value));
    const tag_info = @typeInfo(TagT).@"enum";
    const ArmT = PackedTaggedUnionArm(UnionT);
    return struct {
        pub const Owner = OwnerT;
        pub const Union = UnionT;
        pub const Tag = TagT;
        pub const Arm = ArmT;
        pub const union_field = union_field_value;
        pub const tag_field = tag_field_value;
        comptime {
            for (tag_info.fields) |tag| {
                const arm_value = @field(options.arms, tag.name) orelse continue;
                switch (arm_value) {
                    inline else => |Layout, source| {
                        const source_name = @tagName(source);
                        if (Layout.Zig != @FieldType(UnionT, source_name))
                            @compileError("packed union arm layout has the wrong Zig type for tag: " ++ tag.name);
                        if (@bitSizeOf(Layout.Zig) > @bitSizeOf(UnionT))
                            @compileError("packed union arm is wider than its union: " ++ tag.name);
                    },
                }
            }
        }
        pub fn arm(comptime tag: Tag) ?Arm {
            return @field(options.arms, @tagName(tag));
        }
    };
}
pub fn PackedTaggedUnionOptions(comptime Union: type, comptime Tag: type) type {
    const union_info = @typeInfo(Union).@"union";
    if (union_info.layout != .@"packed")
        @compileError("packed tagged union value must be a packed union");
    const tag_fields = @typeInfo(Tag).@"enum".fields;
    const Arm = PackedTaggedUnionArm(Union);
    const default_arm: ?Arm = null;
    var names: [tag_fields.len][]const u8 = undefined;
    var types: [tag_fields.len]type = undefined;
    var attrs: [tag_fields.len]std.builtin.Type.StructField.Attributes = undefined;
    for (tag_fields, 0..) |field, i| {
        names[i] = field.name;
        types[i] = ?Arm;
        attrs[i] = .{ .default_value_ptr = &default_arm };
    }
    const Arms = @Struct(.auto, null, &names, &types, &attrs);
    return struct {
        arms: Arms = .{},
    };
}
fn PackedTaggedUnionArm(comptime Union: type) type {
    const fields = @typeInfo(Union).@"union".fields;
    const Tag = std.meta.FieldEnum(Union);
    var names: [fields.len][]const u8 = undefined;
    var types: [fields.len]type = undefined;
    var attrs: [fields.len]std.builtin.Type.UnionField.Attributes = undefined;
    for (fields, 0..) |field, i| {
        names[i] = field.name;
        types[i] = type;
        attrs[i] = .{ .@"align" = 1 };
    }
    return @Union(.auto, Tag, &names, &types, &attrs);
}
fn packedStructInfo(comptime T: type) std.builtin.Type.Struct {
    const info = @typeInfo(T).@"struct";
    if (info.layout != .@"packed")
        @compileError("Packed requires a packed struct");
    if (info.backing_integer == null)
        @compileError("Packed requires an integer-backed packed struct");
    return info;
}
test "Packed: reflected fields and nested tagged union" {
    const Tag = enum(u2) { first, second, third };
    const Value = packed union {
        number: packed struct(u4) {
            data: u3,
            _pad: u1,
        },
        flags: packed struct(u4) {
            a: bool,
            b: bool,
            _pad: u2,
        },
    };
    const Nested = packed struct(u1) { enabled: bool };
    const Subject = packed struct(u8) {
        tag: Tag,
        value: Value,
        nested: Nested,
        _padding: u1,
    };
    const Number = Packed(@FieldType(Value, "number"), .{ .fields = .{
        .data = .{ .name = "number" },
        ._pad = .{ .omit = true },
    } });
    const Flags = Packed(@FieldType(Value, "flags"), .{ .fields = .{
        ._pad = .{ .omit = true },
    } });
    const NestedLayout = Packed(Nested, .{});
    const ValueLayout = PackedTaggedUnion(Subject, .value, .tag, .{ .arms = .{
        .first = .{ .number = Number },
        .second = .{ .number = Number },
        .third = .{ .flags = Flags },
    } });
    const Layout = Packed(Subject, .{ .fields = .{
        .value = .{ .encoding = .{ .tagged_union = ValueLayout } },
        .nested = .{ .encoding = .{ .@"packed" = NestedLayout } },
        ._padding = .{ .omit = true },
    } });
    try testing.expectEqual(@bitOffsetOf(Subject, "value"), Layout.bitOffset(.value));
    try testing.expectEqual(@bitSizeOf(Value), Layout.bitWidth(.value));
    try testing.expectEqualStrings("number", Number.fieldName(.data).?);
    try testing.expect(Number.fieldName(._pad) == null);
    switch (ValueLayout.arm(.first).?) {
        .number => |ArmLayout| try testing.expect(ArmLayout == Number),
        else => return error.TestUnexpectedResult,
    }
    switch (ValueLayout.arm(.second).?) {
        .number => |ArmLayout| try testing.expect(ArmLayout == Number),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 1), NestedLayout.bitWidth(.enabled));
}
