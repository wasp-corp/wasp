const std = @import("std");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const log = std.log.scoped(.gtk_wasp_resize_overlay);
pub const ResizeOverlay = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WaspResizeOverlay",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });
    pub const properties = struct {
        pub const duration = struct {
            pub const name = "duration";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                c_uint,
                .{
                    .default = 750,
                    .minimum = 250,
                    .maximum = std.math.maxInt(c_uint),
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "duration",
                    ),
                },
            );
        };
        pub const @"first-delay" = struct {
            pub const name = "first-delay";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                c_uint,
                .{
                    .default = 250,
                    .minimum = 250,
                    .maximum = std.math.maxInt(c_uint),
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "first_delay",
                    ),
                },
            );
        };
        pub const label = struct {
            pub const name = "label";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("label_text"),
                },
            );
        };
        pub const @"overlay-halign" = struct {
            pub const name = "overlay-halign";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                gtk.Align,
                .{
                    .default = .center,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "halign",
                    ),
                },
            );
        };
        pub const @"overlay-valign" = struct {
            pub const name = "overlay-valign";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                gtk.Align,
                .{
                    .default = .center,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "valign",
                    ),
                },
            );
        };
    };
    const Private = struct {
        label: *gtk.Label,
        label_text: ?[:0]const u8,
        duration: c_uint,
        first_delay: c_uint,
        idler: ?c_uint = null,
        timer: ?c_uint = null,
        delay_timer: ?c_uint = null,
        halign: gtk.Align,
        valign: gtk.Align,
        pub var offset: c_int = 0;
    };
    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        const priv = self.private();
        if (priv.first_delay > 0) {
            priv.delay_timer = glib.timeoutAdd(
                priv.first_delay,
                onDelayTimer,
                self,
            );
        }
    }
    pub fn setLabel(self: *Self, label: ?[:0]const u8) void {
        const priv = self.private();
        if (priv.label_text) |v| glib.free(@ptrCast(@constCast(v)));
        priv.label_text = null;
        if (label) |v| priv.label_text = glib.ext.dupeZ(u8, v);
        self.as(gobject.Object).notifyByPspec(properties.label.impl.param_spec);
    }
    pub fn schedule(self: *Self) void {
        const priv = self.private();
        if (priv.delay_timer != null) return;
        if (priv.idler != null) return;
        priv.idler = glib.idleAdd(onIdle, self);
    }
    fn onIdle(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        priv.idler = null;
        if (priv.timer) |timer| {
            if (glib.Source.remove(timer) == 0) {
                log.warn("unable to remove size overlay timer", .{});
            }
            priv.timer = null;
        }
        const text = priv.label_text orelse {
            self.as(gtk.Widget).setVisible(0);
            return 0;
        };
        priv.label.setLabel(text);
        self.as(gtk.Widget).setVisible(1);
        priv.timer = glib.timeoutAdd(
            priv.duration,
            onTimer,
            self,
        );
        return 0;
    }
    fn onTimer(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        priv.timer = null;
        self.as(gtk.Widget).setVisible(0);
        return 0;
    }
    fn onDelayTimer(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        priv.delay_timer = null;
        return 0;
    }
    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.idler) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove resize overlay idler", .{});
            }
            priv.idler = null;
        }
        if (priv.timer) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove resize overlay timer", .{});
            }
            priv.timer = null;
        }
        if (priv.delay_timer) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove resize overlay delay timer", .{});
            }
            priv.delay_timer = null;
        }
        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );
        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }
    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.label_text) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.label_text = null;
        }
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }
    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;
    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;
        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 0,
                    .name = "resize-overlay",
                }),
            );
            class.bindTemplateChildPrivate("label", .{});
            gobject.ext.registerProperties(class, &.{
                properties.duration.impl,
                properties.label.impl,
                properties.@"first-delay".impl,
                properties.@"overlay-halign".impl,
                properties.@"overlay-valign".impl,
            });
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};
