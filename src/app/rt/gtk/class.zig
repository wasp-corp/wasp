const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const ext = @import("ext.zig");
pub const Application = @import("class/application.zig").Application;
pub const Window = @import("class/window.zig").Window;
pub const Config = @import("class/config.zig").Config;
pub const Surface = @import("class/surface.zig").Surface;
pub const RenderSurface = @import("class/render_surface.zig").RenderSurface;
pub fn Common(
    comptime Self: type,
    comptime Private: ?type,
) type {
    return struct {
        pub fn as(self: *Self, comptime T: type) *T {
            return gobject.ext.as(T, self);
        }
        pub fn ref(self: *Self) *Self {
            return @ptrCast(@alignCast(gobject.Object.ref(self.as(gobject.Object))));
        }
        pub fn refSink(self: *Self) *Self {
            return @ptrCast(@alignCast(gobject.Object.refSink(self.as(gobject.Object))));
        }
        pub fn unref(self: *Self) void {
            gobject.Object.unref(self.as(gobject.Object));
        }
        pub const private = if (Private) |P| (struct {
            fn private(self: *Self) *P {
                return gobject.ext.impl_helpers.getPrivate(
                    self,
                    P,
                    P.offset,
                );
            }
        }).private else {};
        pub fn getClass(self: *Self) ?*Self.Class {
            const type_instance: *gobject.TypeInstance = @ptrCast(self);
            return @ptrCast(type_instance.f_g_class orelse return null);
        }
        pub fn defineVirtualMethod(
            comptime name: [:0]const u8,
        ) type {
            return struct {
                pub fn call(
                    class: anytype,
                    object: *ClassInstance(@TypeOf(class)),
                    params: anytype,
                ) (fn_info.return_type orelse void) {
                    const func = @field(
                        gobject.ext.as(Self.Class, class),
                        name,
                    ).?;
                    @call(.auto, func, .{
                        gobject.ext.as(Self, object),
                    } ++ params);
                }
                pub fn implement(
                    class: anytype,
                    implementation: *const ImplementFunc(@TypeOf(class)),
                ) void {
                    @field(gobject.ext.as(
                        Self.Class,
                        class,
                    ), name) = @ptrCast(implementation);
                }
                const fn_info = fn_info: {
                    const Field = @FieldType(Self.Class, name);
                    const opt = @typeInfo(Field).optional;
                    const ptr = @typeInfo(opt.child).pointer;
                    break :fn_info @typeInfo(ptr.child).@"fn";
                };
                fn ClassInstance(comptime T: type) type {
                    return @typeInfo(T).pointer.child.Instance;
                }
                fn ImplementFunc(comptime T: type) type {
                    var types: [fn_info.params.len]type = undefined;
                    var attrs: [fn_info.params.len]std.builtin.Type.Fn.Param.Attributes = undefined;
                    for (fn_info.params, &types, &attrs) |info, *ty, *attr| {
                        ty.* = info.type.?;
                        attr.* = .{ .@"noalias" = info.is_noalias };
                    }
                    types[0] = *ClassInstance(T);
                    return @Fn(
                        &types,
                        &attrs,
                        fn_info.return_type.?,
                        .{
                            .@"callconv" = fn_info.calling_convention,
                            .varargs = fn_info.is_var_args,
                        },
                    );
                }
            };
        }
        pub fn privateShallowFieldAccessor(
            comptime name: []const u8,
        ) gobject.ext.Accessor(
            Self,
            @FieldType(Private.?, name),
        ) {
            return gobject.ext.privateFieldAccessor(
                Self,
                Private.?,
                &Private.?.offset,
                name,
            );
        }
        pub fn privateBoxedFieldAccessor(
            comptime name: []const u8,
        ) gobject.ext.Accessor(
            Self,
            @FieldType(Private.?, name),
        ) {
            return .{
                .getter = &struct {
                    fn get(self: *Self, value: *gobject.Value) void {
                        gobject.ext.Value.set(
                            value,
                            @field(private(self), name),
                        );
                    }
                }.get,
                .setter = &struct {
                    fn set(self: *Self, value: *const gobject.Value) void {
                        const priv = private(self);
                        if (@field(priv, name)) |v| {
                            ext.boxedFree(
                                @typeInfo(@TypeOf(v)).pointer.child,
                                v,
                            );
                        }
                        const T = @TypeOf(@field(priv, name));
                        @field(
                            priv,
                            name,
                        ) = gobject.ext.Value.dup(value, T);
                    }
                }.set,
            };
        }
        pub fn privateObjFieldAccessor(
            comptime name: []const u8,
        ) gobject.ext.Accessor(
            Self,
            @FieldType(Private.?, name),
        ) {
            return .{
                .getter = &struct {
                    fn get(self: *Self, value: *gobject.Value) void {
                        gobject.ext.Value.set(
                            value,
                            @field(private(self), name),
                        );
                    }
                }.get,
                .setter = &struct {
                    fn set(self: *Self, value: *const gobject.Value) void {
                        const priv = private(self);
                        if (@field(priv, name)) |v| v.unref();
                        const T = @TypeOf(@field(priv, name));
                        @field(
                            priv,
                            name,
                        ) = gobject.ext.Value.dup(value, T);
                    }
                }.set,
            };
        }
        pub fn privateStringFieldAccessor(
            comptime name: []const u8,
        ) gobject.ext.Accessor(
            Self,
            @FieldType(Private.?, name),
        ) {
            const S = struct {
                fn getter(self: *Self) ?[:0]const u8 {
                    return @field(private(self), name);
                }
                fn setter(self: *Self, value: ?[:0]const u8) void {
                    const priv = private(self);
                    if (@field(priv, name)) |v| {
                        glib.free(@ptrCast(@constCast(v)));
                    }
                    @field(priv, name) = value;
                }
            };
            return gobject.ext.typedAccessor(
                Self,
                ?[:0]const u8,
                .{
                    .getter = S.getter,
                    .getter_transfer = .none,
                    .setter = S.setter,
                    .setter_transfer = .full,
                },
            );
        }
        pub const Class = struct {
            pub fn as(class: *Self.Class, comptime T: type) *T {
                return gobject.ext.as(T, class);
            }
            pub const bindTemplateChildPrivate = if (Private) |P| (struct {
                pub fn bindTemplateChildPrivate(
                    class: *Self.Class,
                    comptime name: [:0]const u8,
                    comptime options: gtk.ext.BindTemplateChildOptions,
                ) void {
                    gtk.ext.impl_helpers.bindTemplateChildPrivate(
                        class,
                        name,
                        P,
                        P.offset,
                        options,
                    );
                }
            }).bindTemplateChildPrivate else {};
            pub fn bindTemplateCallback(
                class: *Self.Class,
                comptime name: [:0]const u8,
                comptime func: anytype,
            ) void {
                {
                    const ptr_ti = @typeInfo(@TypeOf(func));
                    if (ptr_ti != .pointer) {
                        @compileError("bound function must be a pointer type");
                    }
                    if (ptr_ti.pointer.size != .one) {
                        @compileError("bound function must be a pointer to a function");
                    }
                    const func_ti = @typeInfo(ptr_ti.pointer.child);
                    if (func_ti != .@"fn") {
                        @compileError("bound function must be a function pointer");
                    }
                    if (func_ti.@"fn".return_type == bool) {
                        @compileError("bound function must return c_int instead of bool");
                    }
                }
                gtk.Widget.Class.bindTemplateCallbackFull(
                    class.as(gtk.Widget.Class),
                    name,
                    @ptrCast(func),
                );
            }
        };
    };
}
test {
    @import("std").testing.refAllDecls(@This());
}
