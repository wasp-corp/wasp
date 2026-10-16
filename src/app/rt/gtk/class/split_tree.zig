const std = @import("std");
const assert = @import("../../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const configpkg = @import("../../../config.zig");
const apprt = @import("../../../apprt.zig");
const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const WeakRef = @import("../weak_ref.zig").WeakRef;
const Application = @import("application.zig").Application;
const CloseConfirmationDialog = @import("close_confirmation_dialog.zig").CloseConfirmationDialog;
const Surface = @import("surface.zig").Surface;
const SurfaceScrolledWindow = @import("surface_scrolled_window.zig").SurfaceScrolledWindow;
const Overrides = @import("Overrides.zig");
const log = std.log.scoped(.gtk_wasp_split_tree);
pub const SplitTree = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WaspSplitTree",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });
    pub const properties = struct {
        pub const @"active-surface" = struct {
            pub const name = "active-surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Surface,
                        .{
                            .getter = getActiveSurface,
                        },
                    ),
                },
            );
        };
        pub const @"has-surfaces" = struct {
            pub const name = "has-surfaces";
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
                            .getter = getHasSurfaces,
                        },
                    ),
                },
            );
        };
        pub const @"is-zoomed" = struct {
            pub const name = "is-zoomed";
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
                            .getter = getIsZoomed,
                        },
                    ),
                },
            );
        };
        pub const tree = struct {
            pub const name = "tree";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface.Tree,
                .{
                    .accessor = .{
                        .getter = getTreeValue,
                        .setter = setTreeValue,
                    },
                },
            );
        };
        pub const @"is-split" = struct {
            pub const name = "is-split";
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
                            .getter = getIsSplit,
                        },
                    ),
                },
            );
        };
    };
    pub const signals = struct {
        pub const changed = struct {
            pub const name = "changed";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{ ?*const Surface.Tree, ?*const Surface.Tree },
                void,
            );
        };
    };
    const Private = struct {
        tree: ?*Surface.Tree,
        tree_bin: *adw.Bin,
        last_focused: WeakRef(Surface) = .empty,
        rebuild_source: ?c_uint = null,
        restore_focus_source: ?c_uint = null,
        pending_close: ?Surface.Tree.Node.Handle,
        pub var offset: c_int = 0;
    };
    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        self.initActionMap();
        const priv = self.private();
        priv.pending_close = null;
    }
    fn initActionMap(self: *Self) void {
        const s_variant_type = glib.ext.VariantType.newFor([:0]const u8);
        defer s_variant_type.free();
        const actions = [_]ext.actions.Action(Self){
            .init("new-split", actionNewSplit, s_variant_type),
            .init("equalize", actionEqualize, null),
            .init("zoom", actionZoom, null),
            .init("close-split", actionCloseSplit, null),
        };
        _ = ext.actions.addAsGroup(Self, self, "split-tree", &actions);
    }
    pub fn newSplit(
        self: *Self,
        direction: Surface.Tree.Split.Direction,
        parent_: ?*Surface,
        overrides: Overrides,
    ) Allocator.Error!void {
        const alloc = Application.default().allocator();
        const surface: *Surface = .new(.{
            .command = overrides.command,
            .shell_integration = overrides.shell_integration,
            .working_directory = overrides.working_directory,
            .title = overrides.title,
        });
        defer surface.unref();
        _ = surface.refSink();
        if (parent_) |p| {
            if (p.core()) |core| {
                surface.setParent(core, .split);
            }
        }
        surface.bindIsSplit(self);
        var single_tree = try Surface.Tree.init(alloc, surface);
        defer single_tree.deinit();
        const old_last_focused = self.private().last_focused.get();
        defer if (old_last_focused) |v| v.unref();
        self.private().last_focused.set(surface);
        errdefer self.private().last_focused.set(old_last_focused);
        const old_tree = self.getTree() orelse {
            self.setTree(&single_tree);
            return;
        };
        const handle = self.getActiveSurfaceHandle() orelse .root;
        var new_tree = try old_tree.split(
            alloc,
            handle,
            direction,
            0.5,
            &single_tree,
        );
        defer new_tree.deinit();
        log.debug(
            "new split at={} direction={} old_tree={f} new_tree={f}",
            .{ handle, direction, old_tree, &new_tree },
        );
        self.setTree(&new_tree);
    }
    pub fn resize(
        self: *Self,
        direction: Surface.Tree.Split.Direction,
        amount: u16,
    ) Allocator.Error!bool {
        if (amount == 0) return false;
        const old_tree = self.getTree() orelse return false;
        const active = self.getActiveSurfaceHandle() orelse return false;
        const priv = self.private();
        const width = priv.tree_bin.as(gtk.Widget).getWidth();
        const height = priv.tree_bin.as(gtk.Widget).getHeight();
        if (width == 0 or height == 0) return false;
        const width_f64: f64 = @floatFromInt(width);
        const height_f64: f64 = @floatFromInt(height);
        const amount_f64: f64 = @floatFromInt(amount);
        const ratio: f64 = switch (direction) {
            .right => amount_f64 / width_f64,
            .left => -(amount_f64 / width_f64),
            .down => amount_f64 / height_f64,
            .up => -(amount_f64 / height_f64),
        };
        const layout: Surface.Tree.Split.Layout = switch (direction) {
            .left, .right => .horizontal,
            .up, .down => .vertical,
        };
        var new_tree = try old_tree.resize(
            Application.default().allocator(),
            active,
            layout,
            @floatCast(ratio),
        );
        defer new_tree.deinit();
        self.setTree(&new_tree);
        return true;
    }
    pub fn goto(self: *Self, to: Surface.Tree.Goto) bool {
        const tree = self.getTree() orelse return false;
        const active = self.getActiveSurfaceHandle() orelse return false;
        const target = if (tree.goto(
            Application.default().allocator(),
            active,
            to,
        )) |handle_|
            handle_ orelse return false
        else |err| switch (err) {
            error.OutOfMemory => return false,
        };
        if (active == target) return false;
        const surface = tree.nodes[target.idx()].leaf;
        surface.grabFocus();
        const old_last_focused = self.private().last_focused.get();
        defer if (old_last_focused) |v| v.unref();
        self.private().last_focused.set(surface);
        errdefer self.private().last_focused.set(old_last_focused);
        if (tree.zoomed != null) {
            const app = Application.default();
            const config_obj = app.getConfig();
            defer config_obj.unref();
            const config = config_obj.get();
            if (!config.@"split-preserve-zoom".navigation) {
                tree.zoomed = null;
            } else {
                tree.zoom(target);
            }
            const object = self.as(gobject.Object);
            object.notifyByPspec(properties.tree.impl.param_spec);
            object.notifyByPspec(properties.@"is-zoomed".impl.param_spec);
        }
        return true;
    }
    pub fn moveSplit(
        self: *Self,
        source: *Surface,
        target: *Surface,
        dir: Surface.Tree.Split.Direction,
    ) Allocator.Error!void {
        const alloc = Application.default().allocator();
        const target_tree = self.getTree() orelse return;
        const target_handle = target_tree.locate(target) orelse {
            log.warn("target is not placed in a split tree", .{});
            return;
        };
        const source_handle = target_tree.locate(source);
        var branch = try Surface.Tree.init(alloc, source);
        defer branch.deinit();
        var after_split = try target_tree.split(
            alloc,
            target_handle,
            dir,
            0.5,
            &branch,
        );
        defer after_split.deinit();
        if (source_handle) |handle| {
            var after_remove = try after_split.remove(alloc, handle);
            defer after_remove.deinit();
            self.setTree(&after_remove);
        } else {
            const source_tree_widget = ext.getAncestor(
                SplitTree,
                source.as(gtk.Widget),
            ) orelse {
                log.warn("source is not placed in a split tree", .{});
                return;
            };
            const source_tree = source_tree_widget.getTree() orelse return;
            const handle = source_tree.locate(source) orelse return;
            var new_source_tree = try source_tree.remove(alloc, handle);
            defer new_source_tree.deinit();
            source_tree_widget.setTree(&new_source_tree);
            self.setTree(&after_split);
            source.bindIsSplit(self);
        }
    }
    fn disconnectSurfaceHandlers(self: *Self) void {
        const tree = self.getTree() orelse return;
        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            _ = gobject.signalHandlersDisconnectMatched(
                surface.as(gobject.Object),
                .{ .data = true },
                0,
                0,
                null,
                null,
                self,
            );
        }
    }
    fn connectSurfaceHandlers(self: *Self) void {
        const tree = self.getTree() orelse return;
        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            _ = Surface.signals.@"close-request".connect(
                surface,
                *Self,
                surfaceCloseRequest,
                self,
                .{},
            );
            _ = gobject.Object.signals.notify.connect(
                surface,
                *Self,
                propSurfaceFocused,
                self,
                .{ .detail = "focused" },
            );
            _ = gobject.Object.signals.notify.connect(
                surface,
                *Self,
                propSurfaceMapped,
                self,
                .{ .detail = "mapped" },
            );
        }
    }
    pub fn getNeedsConfirmQuit(self: *Self) bool {
        const tree = self.getTree() orelse return false;
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (entry.view.core()) |core| {
                if (core.needsConfirmQuit()) {
                    return true;
                }
            }
        }
        return false;
    }
    pub fn getActiveSurface(self: *Self) ?*Surface {
        const tree = self.getTree() orelse return null;
        const handle = self.getActiveSurfaceHandle() orelse return null;
        return tree.nodes[handle.idx()].leaf;
    }
    fn getActiveSurfaceHandle(self: *Self) ?Surface.Tree.Node.Handle {
        const tree = self.getTree() orelse return null;
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (entry.view.getFocused()) return entry.handle;
        }
        if (self.private().last_focused.get()) |v| {
            defer v.unref();
            it = tree.iterator();
            while (it.next()) |entry| {
                if (entry.view == v) return entry.handle;
            }
        }
        return null;
    }
    pub fn getLastFocusedSurface(self: *Self) ?*Surface {
        const surface = self.private().last_focused.get() orelse return null;
        surface.unref();
        return surface;
    }
    pub fn getHasSurfaces(self: *Self) bool {
        const tree: *const Surface.Tree = self.private().tree orelse &.empty;
        return !tree.isEmpty();
    }
    pub fn getIsZoomed(self: *Self) bool {
        const tree: *const Surface.Tree = self.private().tree orelse &.empty;
        return tree.zoomed != null;
    }
    pub fn getTree(self: *Self) ?*Surface.Tree {
        return self.private().tree;
    }
    pub fn setTree(self: *Self, tree_: ?*const Surface.Tree) void {
        const priv = self.private();
        const tree: ?*const Surface.Tree = tree: {
            const tree = tree_ orelse break :tree null;
            if (tree.isEmpty()) break :tree null;
            break :tree tree;
        };
        signals.changed.impl.emit(
            self,
            null,
            .{ priv.tree, tree },
            null,
        );
        if (priv.tree) |old_tree| {
            self.disconnectSurfaceHandlers();
            ext.boxedFree(Surface.Tree, old_tree);
            priv.tree = null;
        }
        if (tree) |new_tree| {
            assert(priv.tree == null);
            assert(!new_tree.isEmpty());
            priv.tree = ext.boxedCopy(Surface.Tree, new_tree);
            self.connectSurfaceHandlers();
        }
        self.as(gobject.Object).notifyByPspec(properties.tree.impl.param_spec);
    }
    fn getTreeValue(self: *Self, value: *gobject.Value) void {
        gobject.ext.Value.set(
            value,
            self.private().tree,
        );
    }
    fn setTreeValue(self: *Self, value: *const gobject.Value) void {
        self.setTree(gobject.ext.Value.get(
            value,
            ?*Surface.Tree,
        ));
    }
    pub fn getIsSplit(self: *Self) bool {
        const tree: *const Surface.Tree = self.private().tree orelse &.empty;
        if (tree.isEmpty()) return false;
        const root_handle: Surface.Tree.Node.Handle = .root;
        const root = tree.nodes[root_handle.idx()];
        return switch (root) {
            .leaf => false,
            .split => true,
        };
    }
    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.last_focused.deinit();
        if (priv.rebuild_source) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove rebuild source", .{});
            }
            priv.rebuild_source = null;
        }
        if (priv.restore_focus_source) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove restore_focus source", .{});
            }
            priv.restore_focus_source = null;
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
        if (priv.tree) |tree| {
            ext.boxedFree(Surface.Tree, tree);
            priv.tree = null;
        }
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }
    pub fn actionNewSplit(
        _: *gio.SimpleAction,
        args_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const args = args_ orelse {
            log.warn("split-tree.new-split called without a parameter", .{});
            return;
        };
        var dir: ?[*:0]const u8 = null;
        args.get("&s", &dir);
        const direction = std.meta.stringToEnum(
            Surface.Tree.Split.Direction,
            std.mem.span(dir) orelse return,
        ) orelse {
            log.warn("invalid split direction for split-tree.new-split: {s}", .{dir.?});
            return;
        };
        self.newSplit(
            direction,
            self.getActiveSurface(),
            .none,
        ) catch |err| {
            log.warn("new split failed error={}", .{err});
        };
    }
    pub fn actionEqualize(
        _: *gio.SimpleAction,
        parameter_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        _ = parameter_;
        const old_tree = self.getTree() orelse return;
        var new_tree = old_tree.equalize(Application.default().allocator()) catch |err| {
            log.warn("unable to equalize tree: {}", .{err});
            return;
        };
        defer new_tree.deinit();
        self.setTree(&new_tree);
    }
    pub fn actionZoom(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const tree = self.getTree() orelse return;
        if (tree.zoomed != null) {
            tree.zoomed = null;
        } else {
            const active = self.getActiveSurfaceHandle() orelse return;
            if (tree.zoomed == active) return;
            tree.zoom(active);
        }
        self.as(gobject.Object).notifyByPspec(properties.tree.impl.param_spec);
    }
    pub fn actionCloseSplit(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const surface = self.getActiveSurface() orelse return;
        surface.close();
    }
    fn surfaceCloseRequest(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        const core = surface.core() orelse return;
        const priv = self.private();
        priv.pending_close = null;
        const tree = self.getTree() orelse return;
        priv.pending_close = tree.locate(surface) orelse return;
        if (!core.needsConfirmQuit()) {
            closeConfirmationClose(
                null,
                self,
            );
            return;
        }
        const dialog: *CloseConfirmationDialog = .new(.surface);
        _ = CloseConfirmationDialog.signals.@"close-request".connect(
            dialog,
            *Self,
            closeConfirmationClose,
            self,
            .{},
        );
        dialog.present(self.as(gtk.Widget));
    }
    fn closeConfirmationClose(
        _: ?*CloseConfirmationDialog,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const handle = priv.pending_close orelse return;
        priv.pending_close = null;
        const old_tree = self.getTree() orelse return;
        const next_focus: ?*Surface = next_focus: {
            const alloc = Application.default().allocator();
            const next_handle: Surface.Tree.Node.Handle =
                (old_tree.goto(alloc, handle, .previous) catch null) orelse
                (old_tree.goto(alloc, handle, .next) catch null) orelse
                break :next_focus null;
            if (next_handle == handle) break :next_focus null;
            break :next_focus old_tree.nodes[next_handle.idx()].leaf;
        };
        var new_tree = old_tree.remove(
            Application.default().allocator(),
            handle,
        ) catch |err| {
            log.warn("unable to remove surface from tree: {}", .{err});
            return;
        };
        defer new_tree.deinit();
        self.setTree(&new_tree);
        if (next_focus) |v| priv.last_focused.set(v);
    }
    fn propSurfaceFocused(
        surface: *Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        if (!surface.getFocused()) return;
        self.private().last_focused.set(surface);
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
    }
    fn propSurfaceMapped(
        surface: *Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        if (!surface.getMapped()) return;
        const priv = self.private();
        if (priv.restore_focus_source == null) priv.restore_focus_source = glib.idleAdd(
            onRestoreFocus,
            self,
        );
    }
    fn propTree(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();
        self.as(gobject.Object).freezeNotify();
        defer self.as(gobject.Object).thawNotify();
        self.as(gobject.Object).notifyByPspec(properties.@"has-surfaces".impl.param_spec);
        self.as(gobject.Object).notifyByPspec(properties.@"is-zoomed".impl.param_spec);
        if (priv.rebuild_source) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove rebuild source", .{});
            }
            priv.rebuild_source = null;
        }
        if (priv.restore_focus_source) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove restore_focus source", .{});
            }
            priv.restore_focus_source = null;
        }
        if (priv.tree == null) {
            priv.tree_bin.setChild(null);
            return;
        }
        assert(priv.rebuild_source == null);
        priv.rebuild_source = glib.idleAdd(
            onRebuild,
            self,
        );
    }
    fn onRebuild(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        priv.rebuild_source = null;
        const tree: *const Surface.Tree = self.private().tree orelse &.empty;
        if (tree.isEmpty()) {
            priv.tree_bin.setChild(null);
        } else {
            const built = self.buildTree(
                tree,
                tree.zoomed orelse .root,
            );
            defer built.deinit();
            priv.tree_bin.setChild(built.widget);
        }
        if (priv.last_focused.get()) |v| {
            defer v.unref();
            v.grabFocus();
        }
        self.as(gobject.Object).notifyByPspec(properties.@"is-split".impl.param_spec);
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
        return 0;
    }
    fn onRestoreFocus(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        priv.restore_focus_source = null;
        if (priv.last_focused.get()) |v| {
            defer v.unref();
            if (v.getMapped()) {
                v.grabFocus();
            }
        }
        return 0;
    }
    const BuildTreeResult = struct {
        widget: *gtk.Widget,
        release_ref: bool,
        pub fn initNew(widget: *gtk.Widget) BuildTreeResult {
            return .{ .widget = widget, .release_ref = false };
        }
        pub fn initReused(widget: *gtk.Widget) BuildTreeResult {
            _ = widget.as(gobject.Object).ref();
            detachWidget(widget);
            return .{ .widget = widget, .release_ref = true };
        }
        pub fn deinit(self: BuildTreeResult) void {
            if (self.release_ref) self.widget.as(gobject.Object).unref();
        }
    };
    fn buildTree(
        self: *Self,
        tree: *const Surface.Tree,
        current: Surface.Tree.Node.Handle,
    ) BuildTreeResult {
        return switch (tree.nodes[current.idx()]) {
            .leaf => |v| leaf: {
                const window = ext.getAncestor(
                    SurfaceScrolledWindow,
                    v.as(gtk.Widget),
                ) orelse {
                    break :leaf .initNew(gobject.ext.newInstance(
                        SurfaceScrolledWindow,
                        .{ .surface = v },
                    ).as(gtk.Widget));
                };
                break :leaf .initReused(window.as(gtk.Widget));
            },
            .split => |s| split: {
                const left = self.buildTree(tree, s.left);
                defer left.deinit();
                const right = self.buildTree(tree, s.right);
                defer right.deinit();
                break :split .initNew(SplitTreeSplit.new(
                    current,
                    &s,
                    left.widget,
                    right.widget,
                ).as(gtk.Widget));
            },
        };
    }
    fn detachWidget(widget: *gtk.Widget) void {
        const parent = widget.getParent() orelse return;
        if (gobject.ext.cast(gtk.Paned, parent)) |paned| {
            if (paned.getStartChild()) |child| {
                if (child == widget) {
                    paned.setStartChild(null);
                    return;
                }
            }
            if (paned.getEndChild()) |child| {
                if (child == widget) {
                    paned.setEndChild(null);
                    return;
                }
            }
        }
        if (gobject.ext.cast(adw.Bin, parent)) |bin| {
            if (bin.getChild()) |child| {
                if (child == widget) {
                    bin.setChild(null);
                    return;
                }
            }
        }
        widget.unparent();
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
            gobject.ext.ensureType(Surface);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 0,
                    .name = "split-tree",
                }),
            );
            gobject.ext.registerProperties(class, &.{
                properties.@"active-surface".impl,
                properties.@"has-surfaces".impl,
                properties.@"is-zoomed".impl,
                properties.tree.impl,
                properties.@"is-split".impl,
            });
            class.bindTemplateChildPrivate("tree_bin", .{});
            class.bindTemplateCallback("notify_tree", &propTree);
            signals.changed.impl.register(.{});
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
const SplitTreeSplit = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WaspSplitTreeSplit",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });
    const Private = struct {
        handle: Surface.Tree.Node.Handle,
        ratio: f64,
        idle: ?c_uint = null,
        max_changed: bool = false,
        pos_changed: bool = false,
        paned: *gtk.Paned,
        pub var offset: c_int = 0;
    };
    pub fn new(
        handle: Surface.Tree.Node.Handle,
        split: *const Surface.Tree.Split,
        start_child: *gtk.Widget,
        end_child: *gtk.Widget,
    ) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const priv = self.private();
        priv.handle = handle;
        priv.ratio = split.ratio;
        const paned = priv.paned;
        paned.setStartChild(start_child);
        paned.setEndChild(end_child);
        paned.as(gtk.Orientable).setOrientation(switch (split.layout) {
            .horizontal => .horizontal,
            .vertical => .vertical,
        });
        if (gobject.ext.isA(start_child, SurfaceScrolledWindow)) {
            start_child.setSizeRequest(1, 1);
        }
        if (gobject.ext.isA(end_child, SurfaceScrolledWindow)) {
            end_child.setSizeRequest(1, 1);
        }
        return self;
    }
    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }
    const SyncDirection = enum {
        tree_to_widget,
        widget_to_tree,
    };
    fn syncSplitRatio(self: *Self, direction: SyncDirection) void {
        const priv = self.private();
        const paned = priv.paned;
        const pos = paned.getPosition();
        const min = min: {
            var val = gobject.ext.Value.new(c_int);
            defer val.unset();
            gobject.Object.getProperty(
                paned.as(gobject.Object),
                "min-position",
                &val,
            );
            break :min gobject.ext.Value.get(&val, c_int);
        };
        const max = max: {
            var val = gobject.ext.Value.new(c_int);
            defer val.unset();
            gobject.Object.getProperty(
                paned.as(gobject.Object),
                "max-position",
                &val,
            );
            break :max gobject.ext.Value.get(&val, c_int);
        };
        assert(min == 0);
        if (max == 0) return;
        const current_ratio: f64 = ratio: {
            const pos_f64: f64 = @floatFromInt(pos);
            const max_f64: f64 = @floatFromInt(max);
            break :ratio pos_f64 / max_f64;
        };
        const desired_ratio: f64 = priv.ratio;
        if (std.math.approxEqAbs(
            f64,
            current_ratio,
            desired_ratio,
            0.001,
        )) {
            return;
        }
        switch (direction) {
            .tree_to_widget => {
                const desired_pos: c_int = desired_pos: {
                    const max_f64: f64 = @floatFromInt(max);
                    break :desired_pos @intFromFloat(@round(max_f64 * desired_ratio));
                };
                paned.setPosition(desired_pos);
            },
            .widget_to_tree => {
                const split_tree = ext.getAncestor(
                    SplitTree,
                    self.as(gtk.Widget),
                ) orelse {
                    log.warn("SplitTree ancestor not found", .{});
                    return;
                };
                const tree = split_tree.getTree() orelse {
                    log.warn("no tree data model set", .{});
                    return;
                };
                assert(priv.handle.idx() < tree.nodes.len);
                assert(tree.nodes[priv.handle.idx()] == .split);
                tree.resizeInPlace(priv.handle, @floatCast(current_ratio));
                priv.ratio = current_ratio;
            },
        }
    }
    fn onIdle(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        defer {
            priv.idle = null;
            priv.max_changed = false;
            priv.pos_changed = false;
        }
        if (priv.max_changed) {
            return 0;
        }
        if (!priv.pos_changed) {
            return 0;
        }
        self.syncSplitRatio(.widget_to_tree);
        return 0;
    }
    fn propMaxPosition(
        _: *gtk.Paned,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.max_changed = true;
        self.syncSplitRatio(.tree_to_widget);
        if (priv.idle == null) priv.idle = glib.idleAdd(
            onIdle,
            self,
        );
    }
    fn propPosition(
        _: *gtk.Paned,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.pos_changed = true;
        if (priv.idle == null) priv.idle = glib.idleAdd(
            onIdle,
            self,
        );
    }
    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.idle) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove idle source", .{});
            }
            priv.idle = null;
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
                    .name = "split-tree-split",
                }),
            );
            class.bindTemplateChildPrivate("paned", .{});
            class.bindTemplateCallback("notify_max_position", &propMaxPosition);
            class.bindTemplateCallback("notify_position", &propPosition);
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
