const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const lib = @import("../lib/main.zig");
pub const Errors = error{
    IPCFailed,
};
pub const Target = union(Key) {
    class: [:0]const u8,
    detect,
    pub const Key = enum(c_int) {
        class,
        detect,
        test "wasp.h Target.Key" {
            try lib.checkWaspHEnum(Key, "WASP_IPC_TARGET_");
        }
    };
    pub const CValue = extern union {
        class: [*:0]const u8,
        detect: void,
    };
    pub const C = extern struct {
        key: Key,
        value: CValue,
    };
    pub fn cval(self: Target) C {
        return .{
            .key = @as(Key, self),
            .value = switch (self) {
                .class => |class| .{ .class = class.ptr },
                .detect => .{ .detect = {} },
            },
        };
    }
};
pub const Action = union(enum) {
    new_window: NewWindow,
    new_tab: NewTab,
    toggle_quick_terminal: void,
    pub const NewWindow = struct {
        arguments: ?[][:0]const u8,
        pub const C = extern struct {
            arguments: ?[*]?[*:0]const u8,
            pub fn deinit(self: *NewWindow.C, alloc: Allocator) void {
                if (self.arguments) |arguments| alloc.free(arguments);
            }
        };
        pub fn cval(self: *NewWindow, alloc: Allocator) Allocator.Error!NewWindow.C {
            var result: NewWindow.C = undefined;
            if (self.arguments) |arguments| {
                result.arguments = try alloc.alloc([*:0]const u8, arguments.len + 1);
                for (arguments, 0..) |argument, i|
                    result.arguments[i] = argument.ptr;
                result.arguments[arguments.len] = null;
            } else {
                result.arguments = null;
            }
            return result;
        }
    };
    pub const NewTab = struct {
        surface_id: u64,
        arguments: ?[][:0]const u8,
        pub const C = extern struct {
            surface_id: u64,
            arguments: ?[*]?[*:0]const u8,
            pub fn deinit(self: *NewWindow.C, alloc: Allocator) void {
                if (self.arguments) |arguments| alloc.free(arguments);
            }
        };
        pub fn cval(self: *NewWindow, alloc: Allocator) Allocator.Error!NewWindow.C {
            var result: NewWindow.C = undefined;
            if (self.arguments) |arguments| {
                result.arguments = try alloc.alloc([*:0]const u8, arguments.len + 1);
                for (arguments, 0..) |argument, i|
                    result.arguments[i] = argument.ptr;
                result.arguments[arguments.len] = null;
            } else {
                result.arguments = null;
            }
            return result;
        }
    };
    pub const Key = enum(c_int) {
        new_window,
        new_tab,
        toggle_quick_terminal,
        test "wasp.h Action.Key" {
            try lib.checkWaspHEnum(Key, "WASP_IPC_ACTION_");
        }
    };
    pub const CValue = cvalue: {
        const key_fields = @typeInfo(Key).@"enum".fields;
        var names: [key_fields.len][]const u8 = undefined;
        var types: [key_fields.len]type = undefined;
        var attrs: [key_fields.len]std.builtin.Type.UnionField.Attributes = undefined;
        for (key_fields, &names, &types, &attrs) |field, *name, *ty, *attr| {
            const action = @unionInit(Action, field.name, undefined);
            const Type = t: {
                const Type = @TypeOf(@field(action, field.name));
                if (Type != void and @hasDecl(Type, "C")) break :t Type.C;
                break :t Type;
            };
            name.* = field.name;
            ty.* = Type;
            attr.* = .{ .@"align" = @alignOf(Type) };
        }
        break :cvalue @Union(.@"extern", null, &names, &types, &attrs);
    };
    pub const C = extern struct {
        key: Key,
        value: CValue,
    };
    comptime {
        assert(@sizeOf(CValue) == switch (@sizeOf(usize)) {
            4 => 12,
            8 => 16,
            else => unreachable,
        });
    }
    pub fn Value(comptime key: Key) type {
        inline for (@typeInfo(Action).@"union".fields) |field| {
            const field_key = @field(Key, field.name);
            if (field_key == key) return field.type;
        }
        unreachable;
    }
    pub fn cval(self: Action, alloc: Allocator) C {
        const value: CValue = switch (self) {
            inline else => |v, tag| @unionInit(
                CValue,
                @tagName(tag),
                if (@TypeOf(v) != void and @hasDecl(@TypeOf(v), "cval")) v.cval(alloc) else v,
            ),
        };
        return .{
            .key = @as(Key, self),
            .value = value,
        };
    }
};
