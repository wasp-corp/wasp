const std = @import("std");
const testing = std.testing;
const Target = @import("target.zig").Target;
pub fn TaggedUnion(
    comptime target: Target,
    comptime Union: type,
    comptime options: TaggedUnionOptions(Union),
) type {
    return struct {
        comptime {
            switch (target) {
                .zig => {},
                .c => if (@sizeOf(CValue) != @sizeOf(options.padding)) {
                    @compileLog(@sizeOf(CValue));
                    @compileError("TaggedUnion CValue size does not match expected fixed size");
                },
            }
        }
        pub const Tag = @typeInfo(Union).@"union".tag_type.?;
        pub const Zig = Union;
        pub const C = switch (target) {
            .zig => struct {},
            .c => extern struct {
                tag: Tag,
                value: CValue,
                pub fn cFieldRename(comptime tag: Tag) ?[]const u8 {
                    const tag_name = @tagName(tag);
                    const value = @field(@unionInit(Union, tag_name, undefined), tag_name);
                    if (@field(options.field_renames, tag_name)) |name| return name;
                    if (@sizeOf(@TypeOf(value)) == 0) return null;
                    return tag_name;
                }
            },
        };
        pub const CValue = cvalue: {
            @setEvalBranchQuota(10_000);
            switch (target) {
                .zig => break :cvalue extern struct {},
                .c => {},
            }
            const tag_fields = @typeInfo(Tag).@"enum".fields;
            var names: [tag_fields.len + 1][]const u8 = undefined;
            var types: [tag_fields.len + 1]type = undefined;
            var attrs: [tag_fields.len + 1]std.builtin.Type.UnionField.Attributes = undefined;
            for (tag_fields, 0..) |field, i| {
                const action = @unionInit(Union, field.name, undefined);
                const Type = t: {
                    const Type = @TypeOf(@field(action, field.name));
                    switch (@typeInfo(Type)) {
                        .@"enum", .@"struct", .@"union" => if (@hasDecl(Type, "C")) break :t Type.C,
                        else => {},
                    }
                    break :t Type;
                };
                names[i] = field.name;
                types[i] = Type;
                attrs[i] = .{ .@"align" = @alignOf(Type) };
            }
            names[tag_fields.len] = "_padding";
            types[tag_fields.len] = options.padding;
            attrs[tag_fields.len] = .{ .@"align" = @alignOf(options.padding) };
            break :cvalue @Union(.@"extern", null, &names, &types, &attrs);
        };
        pub fn cval(self: Union) C {
            const value: CValue = switch (self) {
                inline else => |v, tag| @unionInit(
                    CValue,
                    @tagName(tag),
                    value: {
                        switch (@typeInfo(@TypeOf(v))) {
                            .@"enum", .@"struct", .@"union" => if (@hasDecl(@TypeOf(v), "cval")) break :value v.cval(),
                            else => {},
                        }
                        break :value v;
                    },
                ),
            };
            return .{
                .tag = @as(Tag, self),
                .value = value,
            };
        }
        pub fn Value(comptime tag: Tag) type {
            return @FieldType(Union, @tagName(tag));
        }
    };
}
pub fn TaggedUnionOptions(comptime Union: type) type {
    const Tag = @typeInfo(Union).@"union".tag_type.?;
    const tag_fields = @typeInfo(Tag).@"enum".fields;
    const FieldRenames: type = field_renames: {
        const default_rename: ?[]const u8 = null;
        var names: [tag_fields.len][]const u8 = undefined;
        var types: [tag_fields.len]type = undefined;
        var attrs: [tag_fields.len]std.builtin.Type.StructField.Attributes = undefined;
        for (tag_fields, 0..) |field, i| {
            names[i] = field.name;
            types[i] = ?[]const u8;
            attrs[i] = .{ .default_value_ptr = &default_rename };
        }
        break :field_renames @Struct(.auto, null, &names, &types, &attrs);
    };
    return struct {
        padding: type,
        field_renames: FieldRenames = .{},
    };
}
test "TaggedUnion: matching size" {
    const Tag = enum(c_int) { a, b };
    const U = TaggedUnion(
        .c,
        union(Tag) {
            a: u32,
            b: u64,
        },
        .{ .padding = u64 },
    );
    try testing.expectEqual(8, @sizeOf(U.CValue));
}
test "TaggedUnion: padded size" {
    const Tag = enum(c_int) { a };
    const U = TaggedUnion(
        .c,
        union(Tag) {
            a: u32,
        },
        .{ .padding = u64 },
    );
    try testing.expectEqual(8, @sizeOf(U.CValue));
}
test "TaggedUnion: c conversion" {
    const Tag = enum(c_int) { a, b };
    const U = TaggedUnion(.c, union(Tag) {
        a: u32,
        b: u64,
    }, .{ .padding = u64 });
    const c = U.cval(.{ .a = 42 });
    try testing.expectEqual(Tag.a, c.tag);
    try testing.expectEqual(42, c.value.a);
}
test "TaggedUnion: custom C value fields" {
    const Tag = enum(c_int) { a, b, none };
    const Union = union(Tag) {
        a: u32,
        b: u32,
        none,
    };
    const U = TaggedUnion(.c, Union, .{
        .padding = u64,
        .field_renames = .{
            .a = "value",
            .b = "value",
        },
    });
    try testing.expect(!@hasField(U.CValue, "value"));
    try testing.expect(@hasField(U.CValue, "a"));
    try testing.expect(@hasField(U.CValue, "b"));
    try testing.expect(@hasField(U.CValue, "none"));
    try testing.expectEqualStrings("value", U.C.cFieldRename(.a).?);
    try testing.expect(U.C.cFieldRename(.none) == null);
    const a = U.cval(.{ .a = 42 });
    try testing.expectEqual(Tag.a, a.tag);
    try testing.expectEqual(42, a.value.a);
    const none = U.cval(.none);
    try testing.expectEqual(Tag.none, none.tag);
}
