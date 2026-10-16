const std = @import("std");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gdk = @import("gdk");
const gtk = @import("gtk");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const log = std.log.scoped(.gtk_wasp_search_overlay);
pub const SearchOverlay = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WaspSearchOverlay",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });
    pub const properties = struct {
        pub const active = struct {
            pub const name = "active";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{
                            .getter = getSearchActive,
                            .setter = setSearchActive,
                        },
                    ),
                },
            );
        };
        pub const @"search-total" = struct {
            pub const name = "search-total";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                u64,
                .{
                    .default = 0,
                    .minimum = 0,
                    .maximum = std.math.maxInt(u64),
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        u64,
                        .{ .getter = getSearchTotal },
                    ),
                },
            );
        };
        pub const @"has-search-total" = struct {
            pub const name = "has-search-total";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{ .getter = getHasSearchTotal },
                    ),
                },
            );
        };
        pub const @"search-selected" = struct {
            pub const name = "search-selected";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                u64,
                .{
                    .default = 0,
                    .minimum = 0,
                    .maximum = std.math.maxInt(u64),
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        u64,
                        .{ .getter = getSearchSelected },
                    ),
                },
            );
        };
        pub const @"has-search-selected" = struct {
            pub const name = "has-search-selected";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{ .getter = getHasSearchSelected },
                    ),
                },
            );
        };
        pub const @"halign-target" = struct {
            pub const name = "halign-target";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                gtk.Align,
                .{
                    .default = .end,
                    .accessor = C.privateShallowFieldAccessor("halign_target"),
                },
            );
        };
        pub const @"valign-target" = struct {
            pub const name = "valign-target";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                gtk.Align,
                .{
                    .default = .start,
                    .accessor = C.privateShallowFieldAccessor("valign_target"),
                },
            );
        };
    };
    pub const signals = struct {
        pub const @"stop-search" = struct {
            pub const name = "stop-search";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
        pub const @"search-changed" = struct {
            pub const name = "search-changed";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{?[*:0]const u8},
                void,
            );
        };
        pub const @"next-match" = struct {
            pub const name = "next-match";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
        pub const @"previous-match" = struct {
            pub const name = "previous-match";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
    };
    const Private = struct {
        search_entry: *gtk.SearchEntry,
        active: bool = false,
        search_total: ?usize = null,
        search_selected: ?usize = null,
        halign_target: gtk.Align = .end,
        valign_target: gtk.Align = .start,
        pub var offset: c_int = 0;
    };
    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }
    pub fn grabFocus(self: *Self) void {
        const priv = self.private();
        _ = priv.search_entry.as(gtk.Widget).grabFocus();
        priv.search_entry.as(gtk.Editable).selectRegion(0, -1);
    }
    fn setSearchActive(self: *Self, active: bool) void {
        const priv = self.private();
        if (!priv.active and active) {
            const text = priv.search_entry.as(gtk.Editable).getText();
            signals.@"search-changed".impl.emit(self, null, .{text}, null);
        }
        priv.active = active;
    }
    pub fn setSearchContents(self: *Self, content: [:0]const u8) void {
        const priv = self.private();
        priv.search_entry.as(gtk.Editable).setText(content);
        signals.@"search-changed".impl.emit(self, null, .{content}, null);
    }
    pub fn setSearchTotal(self: *Self, total: ?usize) void {
        const priv = self.private();
        const had_total = priv.search_total != null;
        if (priv.search_total == total) return;
        priv.search_total = total;
        self.as(gobject.Object).notifyByPspec(properties.@"search-total".impl.param_spec);
        if (had_total != (total != null)) {
            self.as(gobject.Object).notifyByPspec(properties.@"has-search-total".impl.param_spec);
        }
    }
    pub fn setSearchSelected(self: *Self, selected: ?usize) void {
        const priv = self.private();
        const had_selected = priv.search_selected != null;
        if (priv.search_selected == selected) return;
        priv.search_selected = selected;
        self.as(gobject.Object).notifyByPspec(properties.@"search-selected".impl.param_spec);
        if (had_selected != (selected != null)) {
            self.as(gobject.Object).notifyByPspec(properties.@"has-search-selected".impl.param_spec);
        }
    }
    fn getSearchActive(self: *Self) bool {
        return self.private().active;
    }
    fn getSearchTotal(self: *Self) u64 {
        return self.private().search_total orelse 0;
    }
    fn getHasSearchTotal(self: *Self) bool {
        return self.private().search_total != null;
    }
    fn getSearchSelected(self: *Self) u64 {
        return self.private().search_selected orelse 0;
    }
    fn getHasSearchSelected(self: *Self) bool {
        return self.private().search_selected != null;
    }
    fn closureMatchLabel(
        _: *Self,
        has_selected: bool,
        selected: u64,
        has_total: bool,
        total: u64,
    ) callconv(.c) ?[*:0]const u8 {
        if (!has_total or total == 0) return glib.ext.dupeZ(u8, "0/0");
        var buf: [32]u8 = undefined;
        const label = std.fmt.bufPrintZ(&buf, "{}/{}", .{
            if (has_selected) selected + 1 else 0,
            total,
        }) catch return null;
        return glib.ext.dupeZ(u8, label);
    }
    fn searchChanged(entry: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        const text = entry.as(gtk.Editable).getText();
        signals.@"search-changed".impl.emit(self, null, .{text}, null);
    }
    fn stopSearch(_: *anyopaque, self: *Self) callconv(.c) void {
        signals.@"stop-search".impl.emit(self, null, .{}, null);
    }
    fn nextMatch(_: *anyopaque, self: *Self) callconv(.c) void {
        signals.@"next-match".impl.emit(self, null, .{}, null);
    }
    fn previousMatch(_: *anyopaque, self: *Self) callconv(.c) void {
        signals.@"previous-match".impl.emit(self, null, .{}, null);
    }
    fn searchEntryKeyPressed(
        _: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        gtk_mods: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        if (keyval == gdk.KEY_Return or keyval == gdk.KEY_KP_Enter) {
            if (gtk_mods.shift_mask) {
                signals.@"previous-match".impl.emit(self, null, .{}, null);
            } else {
                signals.@"next-match".impl.emit(self, null, .{}, null);
            }
            return 1;
        }
        return 0;
    }
    fn onDragEnd(
        _: *gtk.GestureDrag,
        offset_x: f64,
        offset_y: f64,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const widget = self.as(gtk.Widget);
        const parent = widget.getParent() orelse return;
        const parent_width: f64 = @floatFromInt(parent.getAllocatedWidth());
        const parent_height: f64 = @floatFromInt(parent.getAllocatedHeight());
        const self_width: f64 = @floatFromInt(widget.getAllocatedWidth());
        const self_height: f64 = @floatFromInt(widget.getAllocatedHeight());
        const self_x: f64 = if (priv.halign_target == .start) 0 else parent_width - self_width;
        const self_y: f64 = if (priv.valign_target == .start) 0 else parent_height - self_height;
        const new_x = self_x + offset_x + (self_width / 2);
        const new_y = self_y + offset_y + (self_height / 2);
        const new_halign: gtk.Align = if (new_x > parent_width / 2) .end else .start;
        const new_valign: gtk.Align = if (new_y > parent_height / 2) .end else .start;
        var changed = false;
        if (new_halign != priv.halign_target) {
            priv.halign_target = new_halign;
            self.as(gobject.Object).notifyByPspec(properties.@"halign-target".impl.param_spec);
            changed = true;
        }
        if (new_valign != priv.valign_target) {
            priv.valign_target = new_valign;
            self.as(gobject.Object).notifyByPspec(properties.@"valign-target".impl.param_spec);
            changed = true;
        }
        if (changed) self.as(gtk.Widget).queueResize();
    }
    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        _ = priv;
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
        _ = priv;
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
                    .name = "search-overlay",
                }),
            );
            class.bindTemplateChildPrivate("search_entry", .{});
            class.bindTemplateCallback("stop_search", &stopSearch);
            class.bindTemplateCallback("search_changed", &searchChanged);
            class.bindTemplateCallback("match_label_closure", &closureMatchLabel);
            class.bindTemplateCallback("next_match", &nextMatch);
            class.bindTemplateCallback("previous_match", &previousMatch);
            class.bindTemplateCallback("search_entry_key_pressed", &searchEntryKeyPressed);
            class.bindTemplateCallback("on_drag_end", &onDragEnd);
            gobject.ext.registerProperties(class, &.{
                properties.active.impl,
                properties.@"search-total".impl,
                properties.@"has-search-total".impl,
                properties.@"search-selected".impl,
                properties.@"has-search-selected".impl,
                properties.@"halign-target".impl,
                properties.@"valign-target".impl,
            });
            signals.@"stop-search".impl.register(.{});
            signals.@"search-changed".impl.register(.{});
            signals.@"next-match".impl.register(.{});
            signals.@"previous-match".impl.register(.{});
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
