const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");
const gresource = @import("../build/gresource.zig");
const Inspector = @import("../../../inspector/Inspector.zig");
const Common = @import("../class.zig").Common;
const Surface = @import("surface.zig").Surface;
const ImguiWidget = @import("imgui_widget.zig").ImguiWidget;
const log = std.log.scoped(.gtk_wasp_inspector_widget);
pub const InspectorWidget = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = ImguiWidget;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WaspInspectorWidget",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });
    pub const properties = struct {
        pub const surface = struct {
            pub const name = "surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = .{
                        .getter = getSurfaceValue,
                        .setter = setSurfaceValue,
                    },
                },
            );
        };
    };
    pub const signals = struct {};
    const Private = struct {
        surface: ?*Surface = null,
        pub var offset: c_int = 0;
    };
    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }
    fn dispose(self: *Self) callconv(.c) void {
        self.setSurface(null);
        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );
        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }
    fn imguiSetup(
        _: *Self,
    ) callconv(.c) void {
        Inspector.setup();
    }
    fn imguiRender(
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const surface = priv.surface orelse return;
        const core_surface = surface.core() orelse return;
        const inspector = core_surface.inspector orelse return;
        inspector.render(core_surface);
    }
    pub fn queueRender(self: *Self) void {
        self.as(ImguiWidget).queueRender();
    }
    fn getSurfaceValue(self: *Self, value: *gobject.Value) void {
        gobject.ext.Value.set(
            value,
            self.private().surface,
        );
    }
    fn setSurfaceValue(self: *Self, value: *const gobject.Value) void {
        self.setSurface(gobject.ext.Value.get(
            value,
            ?*Surface,
        ));
    }
    pub fn getSurface(self: *Self) ?*Surface {
        return self.private().surface;
    }
    pub fn setSurface(self: *Self, surface_: ?*Surface) void {
        const priv = self.private();
        if (surface_ == priv.surface) return;
        self.as(gobject.Object).freezeNotify();
        defer self.as(gobject.Object).thawNotify();
        self.as(gobject.Object).notifyByPspec(properties.surface.impl.param_spec);
        if (priv.surface) |old| old: {
            priv.surface = null;
            old.as(gobject.Object).weakUnref(
                surfaceWeakNotify,
                self,
            );
            const core_surface = old.core() orelse break :old;
            core_surface.deactivateInspector();
        }
        const surface = surface_ orelse return;
        const core_surface = surface.core() orelse return;
        core_surface.activateInspector() catch |err| {
            log.warn("failed to activate inspector err={}", .{err});
            return;
        };
        surface.as(gobject.Object).weakRef(
            surfaceWeakNotify,
            self,
        );
        priv.surface = surface;
        self.queueRender();
    }
    fn surfaceWeakNotify(
        ud: ?*anyopaque,
        surface: *gobject.Object,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        const priv = self.private();
        if (@intFromPtr(priv.surface) != @intFromPtr(surface)) return;
        const old = priv.surface orelse return;
        const core_surface = old.core() orelse return;
        core_surface.deactivateInspector();
        priv.surface = null;
        self.as(gobject.Object).notifyByPspec(properties.surface.impl.param_spec);
    }
    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const refSink = C.refSink;
    pub const unref = C.unref;
    const private = C.private;
    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;
        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(ImguiWidget);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 0,
                    .name = "inspector-widget",
                }),
            );
            gobject.ext.registerProperties(class, &.{
                properties.surface.impl,
            });
            ImguiWidget.virtual_methods.setup.implement(class, imguiSetup);
            ImguiWidget.virtual_methods.render.implement(class, imguiRender);
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }
        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
