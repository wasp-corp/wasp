const std = @import("std");
const build_config = @import("../../../build_config.zig");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Surface = @import("surface.zig").Surface;
const DebugWarning = @import("debug_warning.zig").DebugWarning;
const InspectorWidget = @import("inspector_widget.zig").InspectorWidget;
const WeakRef = @import("../weak_ref.zig").WeakRef;
const log = std.log.scoped(.gtk_wasp_inspector_window);
pub const InspectorWindow = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.ApplicationWindow;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WaspInspectorWindow",
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
        pub const debug = struct {
            pub const name = "debug";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = build_config.is_debug,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = struct {
                            pub fn getter(_: *Self) bool {
                                return build_config.is_debug;
                            }
                        }.getter,
                    }),
                },
            );
        };
    };
    pub const signals = struct {};
    const Private = struct {
        surface: WeakRef(Surface) = .empty,
        inspector_widget: *InspectorWidget,
        pub var offset: c_int = 0;
    };
    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        if (comptime build_config.is_debug) {
            self.as(gtk.Widget).addCssClass("devel");
        }
        self.as(gtk.Window).setIconName(build_config.bundle_id);
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
    pub fn new(surface: *Surface) *Self {
        return gobject.ext.newInstance(Self, .{
            .surface = surface,
        });
    }
    pub fn present(self: *Self) void {
        self.as(gtk.Window).present();
    }
    pub fn queueRender(self: *Self) void {
        const priv = self.private();
        priv.inspector_widget.queueRender();
    }
    fn setSurface(self: *Self, newvalue: ?*Surface) void {
        const priv = self.private();
        priv.surface.set(newvalue);
    }
    fn getSurfaceValue(self: *Self, value: *gobject.Value) void {
        gobject.ext.Value.take(
            value,
            self.private().surface.get(),
        );
    }
    fn setSurfaceValue(self: *Self, value: *const gobject.Value) void {
        self.setSurface(gobject.ext.Value.get(
            value,
            ?*Surface,
        ));
    }
    fn propInspectorSurface(
        inspector: *InspectorWidget,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        if (inspector.getSurface() == null) {
            self.as(gtk.Window).destroy();
        }
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
            gobject.ext.ensureType(DebugWarning);
            gobject.ext.ensureType(InspectorWidget);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 4,
                    .name = "inspector-window",
                }),
            );
            class.bindTemplateChildPrivate("inspector_widget", .{});
            class.bindTemplateCallback("notify_inspector_surface", &propInspectorSurface);
            gobject.ext.registerProperties(class, &.{
                properties.surface.impl,
                properties.debug.impl,
            });
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }
        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
