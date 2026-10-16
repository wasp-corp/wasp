const std = @import("std");
const assert = @import("../../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const apprt = @import("../../../apprt.zig");
const build_config = @import("../../../build_config.zig");
const build_options = @import("build_options");
const configpkg = @import("../../../config.zig");
const datastruct = @import("../../../datastruct/root.zig");
const font = @import("../../../font/root.zig");
const input = @import("../../../input.zig");
const internal_os = @import("../../../os/root.zig");
const renderer = @import("../../../renderer.zig");
const terminal = @import("../../../terminal/main.zig");
const CoreSurface = @import("../../../Surface.zig");
const gresource = @import("../build/gresource.zig");
const ext = @import("../ext.zig");
const gsettings = @import("../gsettings.zig");
const gtk_key = @import("../key.zig");
const ApprtSurface = @import("../Surface.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Config = @import("config.zig").Config;
const ResizeOverlay = @import("resize_overlay.zig").ResizeOverlay;
const SearchOverlay = @import("search_overlay.zig").SearchOverlay;
const KeyStateOverlay = @import("key_state_overlay.zig").KeyStateOverlay;
const ChildExited = @import("surface_child_exited.zig").SurfaceChildExited;
const ClipboardConfirmationDialog = @import("clipboard_confirmation_dialog.zig").ClipboardConfirmationDialog;
const TitleDialog = @import("title_dialog.zig").TitleDialog;
const Window = @import("window.zig").Window;
const InspectorWindow = @import("inspector_window.zig").InspectorWindow;
const SplitTree = @import("split_tree.zig").SplitTree;
const RenderSurface = @import("render_surface.zig").RenderSurface;
const i18n = @import("../../../os/i18n.zig");
const global = @import("../../../global.zig");
const gtk_version = @import("../gtk_version.zig");
const Overrides = @import("Overrides.zig");
const scale_util = @import("../scale.zig");
const DesktopNotifications = @import("../desktop_notifications.zig");
const log = std.log.scoped(.gtk_wasp_surface);
pub const Surface = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const Implements = [_]type{gtk.Scrollable};
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WaspSurface",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
        .implements = &.{
            gobject.ext.implement(gtk.Scrollable, .{}),
        },
    });
    pub const Tree = datastruct.SplitTree(Self);
    pub const properties = struct {
        pub const @"bell-ringing" = struct {
            pub const name = "bell-ringing";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = C.privateShallowFieldAccessor("bell_ringing"),
                },
            );
        };
        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };
        pub const @"child-exited" = struct {
            pub const name = "child-exited";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "child_exited",
                    ),
                },
            );
        };
        pub const @"default-size" = struct {
            pub const name = "default-size";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Size,
                .{
                    .accessor = C.privateBoxedFieldAccessor("default_size"),
                },
            );
        };
        pub const @"error" = struct {
            pub const name = "error";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "error",
                    ),
                },
            );
        };
        pub const @"font-size-request" = struct {
            pub const name = "font-size-request";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*font.face.DesiredSize,
                .{
                    .accessor = C.privateBoxedFieldAccessor("font_size_request"),
                },
            );
        };
        pub const focused = struct {
            pub const name = "focused";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "focused",
                    ),
                },
            );
        };
        pub const mapped = struct {
            pub const name = "mapped";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "mapped",
                    ),
                },
            );
        };
        pub const @"min-size" = struct {
            pub const name = "min-size";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Size,
                .{
                    .accessor = C.privateBoxedFieldAccessor("min_size"),
                },
            );
        };
        pub const @"mouse-hidden" = struct {
            pub const name = "mouse-hidden";
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
                            .getter = getMouseHidden,
                            .setter = setMouseHidden,
                        },
                    ),
                },
            );
        };
        pub const @"mouse-shape" = struct {
            pub const name = "mouse-shape";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                terminal.MouseShape,
                .{
                    .default = .text,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        terminal.MouseShape,
                        .{
                            .getter = getMouseShape,
                            .setter = setMouseShape,
                        },
                    ),
                },
            );
        };
        pub const @"mouse-hover-url" = struct {
            pub const name = "mouse-hover-url";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("mouse_hover_url"),
                },
            );
        };
        pub const pwd = struct {
            pub const name = "pwd";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("pwd"),
                },
            );
        };
        pub const title = struct {
            pub const name = "title";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("title"),
                },
            );
        };
        pub const @"title-override" = struct {
            pub const name = "title-override";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("title_override"),
                },
            );
        };
        pub const zoom = struct {
            pub const name = "zoom";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "zoom",
                    ),
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
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "is_split",
                    ),
                },
            );
        };
        pub const hadjustment = struct {
            pub const name = "hadjustment";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*gtk.Adjustment,
                .{
                    .accessor = .{
                        .getter = getHAdjustmentValue,
                        .setter = setHAdjustmentValue,
                    },
                },
            );
        };
        pub const vadjustment = struct {
            pub const name = "vadjustment";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*gtk.Adjustment,
                .{
                    .accessor = .{
                        .getter = getVAdjustmentValue,
                        .setter = setVAdjustmentValue,
                    },
                },
            );
        };
        pub const @"hscroll-policy" = struct {
            pub const name = "hscroll-policy";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                gtk.ScrollablePolicy,
                .{
                    .default = .natural,
                    .accessor = C.privateShallowFieldAccessor("hscroll_policy"),
                },
            );
        };
        pub const @"vscroll-policy" = struct {
            pub const name = "vscroll-policy";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                gtk.ScrollablePolicy,
                .{
                    .default = .natural,
                    .accessor = C.privateShallowFieldAccessor("vscroll_policy"),
                },
            );
        };
        pub const @"key-sequence" = struct {
            pub const name = "key-sequence";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*ext.StringList,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*ext.StringList,
                        .{
                            .getter = getKeySequence,
                            .getter_transfer = .full,
                        },
                    ),
                },
            );
        };
        pub const @"key-table" = struct {
            pub const name = "key-table";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*ext.StringList,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*ext.StringList,
                        .{
                            .getter = getKeyTable,
                            .getter_transfer = .full,
                        },
                    ),
                },
            );
        };
        pub const readonly = struct {
            pub const name = "readonly";
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
                            .getter = getReadonly,
                        },
                    ),
                },
            );
        };
    };
    pub const signals = struct {
        pub const bell = struct {
            pub const name = "bell";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
        pub const @"close-request" = struct {
            pub const name = "close-request";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
        pub const @"clipboard-write" = struct {
            pub const name = "clipboard-write";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{
                    apprt.Clipboard,
                    [*:0]const u8,
                },
                void,
            );
        };
        pub const @"clipboard-read" = struct {
            pub const name = "clipboard-read";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
        pub const init = struct {
            pub const name = "init";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
        pub const menu = struct {
            pub const name = "menu";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
        pub const @"present-request" = struct {
            pub const name = "present-request";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
        pub const @"toggle-fullscreen" = struct {
            pub const name = "toggle-fullscreen";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
        pub const @"toggle-maximize" = struct {
            pub const name = "toggle-maximize";
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
        config: ?*Config = null,
        default_size: ?*Size = null,
        min_size: ?*Size = null,
        font_size_request: ?*font.face.DesiredSize = null,
        mouse_shape: terminal.MouseShape = .default,
        mouse_hidden: bool = false,
        mouse_hover_url: ?[:0]const u8 = null,
        pwd: ?[:0]const u8 = null,
        title: ?[:0]const u8 = null,
        title_override: ?[:0]const u8 = null,
        focused: bool = true,
        mapped: bool = false,
        zoom: bool = false,
        render_surface: *RenderSurface,
        url_left: *gtk.Label,
        url_right: *gtk.Label,
        resize_overlay: *ResizeOverlay,
        search_overlay: *SearchOverlay,
        key_state_overlay: *KeyStateOverlay,
        rt_surface: ApprtSurface = undefined,
        core_surface: ?*CoreSurface = null,
        size: apprt.SurfaceSize,
        cursor_pos: apprt.CursorPos,
        in_keyevent: IMKeyEvent = .false,
        im_context: *gtk.IMMulticontext,
        im_composing: bool = false,
        im_buf: [128]u8 = undefined,
        im_len: u7 = 0,
        precision_scroll: bool = false,
        child_exited: bool = false,
        progress_bar_timer: ?c_uint = null,
        desktop_notifications: DesktopNotifications,
        bell_ringing: bool = false,
        @"error": bool = false,
        idle_rechild: ?c_uint = null,
        inspector: ?*InspectorWindow = null,
        is_split: bool = false,
        is_split_binding: ?*gobject.Binding = null,
        action_group: ?*gio.SimpleActionGroup = null,
        hadj: ?*gtk.Adjustment = null,
        vadj: ?*gtk.Adjustment = null,
        hscroll_policy: gtk.ScrollablePolicy = .natural,
        vscroll_policy: gtk.ScrollablePolicy = .natural,
        vadj_signal_group: ?*gobject.SignalGroup = null,
        key_sequence: std.ArrayListUnmanaged([:0]const u8) = .empty,
        key_tables: std.ArrayListUnmanaged([:0]const u8) = .empty,
        child_exited_overlay: *ChildExited,
        context_menu: *gtk.PopoverMenu,
        drop_target: *gtk.DropTarget,
        surface_drop_target: *gtk.DropTarget,
        drag_handle: *gtk.Widget,
        drop_overlay: *gtk.Widget,
        progress_bar_overlay: *gtk.ProgressBar,
        error_page: *adw.StatusPage,
        terminal_page: *gtk.Overlay,
        context: apprt.surface.NewSurfaceContext = .window,
        gtk_enable_primary_paste: bool = true,
        suppress_left_mouse_release: bool = false,
        pending_horizontal_scroll: f64 = 0.0,
        pending_horizontal_scroll_reset: ?c_uint = null,
        overrides: struct {
            command: ?configpkg.Command = null,
            shell_integration: ?configpkg.Config.ShellIntegration = null,
            working_directory: ?[:0]const u8 = null,
            pub const none: @This() = .{};
        } = .none,
        pub var offset: c_int = 0;
    };
    pub fn new(overrides: Overrides) *Self {
        const self = gobject.ext.newInstance(Self, .{
            .@"title-override" = overrides.title,
        });
        const alloc = Application.default().allocator();
        const priv: *Private = self.private();
        priv.overrides = .{
            .command = if (overrides.command) |c| c.clone(alloc) catch null else null,
            .shell_integration = overrides.shell_integration,
            .working_directory = if (overrides.working_directory) |wd| alloc.dupeZ(u8, wd) catch null else null,
        };
        return self;
    }
    pub fn core(self: *Self) ?*CoreSurface {
        const priv = self.private();
        return priv.core_surface;
    }
    pub fn rt(self: *Self) *ApprtSurface {
        const priv = self.private();
        return &priv.rt_surface;
    }
    pub fn setParent(
        self: *Self,
        parent: *CoreSurface,
        context: apprt.surface.NewSurfaceContext,
    ) void {
        const priv = self.private();
        if (priv.core_surface != null) {
            log.warn("setParent called after surface is already realized", .{});
            return;
        }
        priv.context = context;
        const font_size_ptr = glib.ext.create(font.face.DesiredSize);
        errdefer glib.ext.destroy(font_size_ptr);
        font_size_ptr.* = parent.font_size;
        priv.font_size_request = font_size_ptr;
        self.as(gobject.Object).notifyByPspec(properties.@"font-size-request".impl.param_spec);
        if (priv.config) |config_obj| {
            if (apprt.surface.shouldInheritWorkingDirectory(context, config_obj.get())) {
                if (parent.rt_surface.surface.getPwd()) |pwd| {
                    priv.pwd = glib.ext.dupeZ(u8, pwd);
                    self.as(gobject.Object).notifyByPspec(properties.pwd.impl.param_spec);
                }
            }
        }
    }
    pub fn redraw(self: *Self) void {
        const priv = self.private();
        priv.render_surface.as(gtk.Widget).queueDraw();
    }
    fn closureShouldBorderBeShown(
        _: *Self,
        config_: ?*Config,
        bell_ringing_: c_int,
    ) callconv(.c) c_int {
        const bell_ringing = bell_ringing_ != 0;
        if (!bell_ringing) return @intFromBool(false);
        const config = if (config_) |v| v.get() else {
            log.warn("config unavailable for computing whether border should be shown, likely bug", .{});
            return @intFromBool(false);
        };
        return @intFromBool(config.@"bell-features".border);
    }
    pub fn bindIsSplit(self: *Self, tree: *SplitTree) void {
        const priv = self.private();
        if (priv.is_split_binding) |binding| {
            binding.unbind();
            binding.unref();
            priv.is_split_binding = null;
        }
        const binding = tree.as(gobject.Object).bindProperty(
            "is-split",
            self.as(gobject.Object),
            "is-split",
            .{ .sync_create = true },
        );
        binding.ref();
        priv.is_split_binding = binding;
    }
    fn closureShouldUnfocusedSplitBeShown(
        _: *Self,
        search_active: c_int,
        focused: c_int,
        is_split: c_int,
    ) callconv(.c) c_int {
        return @intFromBool(search_active == 0 and focused == 0 and is_split != 0);
    }
    pub fn toggleFullscreen(self: *Self) void {
        signals.@"toggle-fullscreen".impl.emit(
            self,
            null,
            .{},
            null,
        );
    }
    pub fn toggleMaximize(self: *Self) void {
        signals.@"toggle-maximize".impl.emit(
            self,
            null,
            .{},
            null,
        );
    }
    pub fn toggleCommandPalette(self: *Self) bool {
        return self.as(gtk.Widget).activateAction("win.toggle-command-palette", null) != 0;
    }
    pub fn controlInspector(
        self: *Self,
        value: apprt.Action.Value(.inspector),
    ) bool {
        const priv = self.private();
        if (priv.inspector) |inspector| switch (value) {
            .show => {},
            .toggle, .hide => inspector.as(gtk.Window).destroy(),
        } else switch (value) {
            .toggle, .show => {
                const inspector = InspectorWindow.new(self);
                inspector.present();
                inspector.as(gobject.Object).weakRef(inspectorWeakNotify, self);
                priv.inspector = inspector;
            },
            .hide => {},
        }
        return true;
    }
    pub fn redrawInspector(self: *Self) void {
        const priv = self.private();
        if (priv.inspector) |v| v.queueRender();
    }
    pub fn keySequenceAction(
        self: *Self,
        value: apprt.action.KeySequence,
    ) Allocator.Error!void {
        const priv = self.private();
        const alloc = Application.default().allocator();
        self.as(gobject.Object).freezeNotify();
        defer self.as(gobject.Object).thawNotify();
        self.as(gobject.Object).notifyByPspec(properties.@"key-sequence".impl.param_spec);
        switch (value) {
            .trigger => |trigger| {
                var buf: std.Io.Writer.Allocating = .init(alloc);
                defer buf.deinit();
                if (gtk_key.labelFromTrigger(&buf.writer, trigger)) |success| {
                    if (!success) return;
                } else |_| return error.OutOfMemory;
                try priv.key_sequence.ensureUnusedCapacity(alloc, 1);
                const duped = try buf.toOwnedSliceSentinel(0);
                errdefer alloc.free(duped);
                priv.key_sequence.appendAssumeCapacity(duped);
            },
            .end => {
                for (priv.key_sequence.items) |s| alloc.free(s);
                priv.key_sequence.clearAndFree(alloc);
            },
        }
    }
    pub fn keyTableAction(
        self: *Self,
        value: apprt.action.KeyTable,
    ) Allocator.Error!void {
        const priv = self.private();
        const alloc = Application.default().allocator();
        self.as(gobject.Object).freezeNotify();
        defer self.as(gobject.Object).thawNotify();
        self.as(gobject.Object).notifyByPspec(properties.@"key-table".impl.param_spec);
        switch (value) {
            .activate => |name| {
                const duped = try alloc.dupeZ(u8, name);
                errdefer alloc.free(duped);
                try priv.key_tables.append(alloc, duped);
            },
            .deactivate => {
                if (priv.key_tables.pop()) |s| alloc.free(s);
            },
            .deactivate_all => {
                for (priv.key_tables.items) |s| alloc.free(s);
                priv.key_tables.clearAndFree(alloc);
            },
        }
    }
    pub fn showOnScreenKeyboard(self: *Self, event: ?*gdk.Event) bool {
        const priv = self.private();
        return priv.im_context.as(gtk.IMContext).activateOsk(event) != 0;
    }
    pub fn setScrollbar(self: *Self, scrollbar: terminal.Scrollbar) void {
        const vadj = self.getVAdjustment() orelse return;
        const value: f64 = @floatFromInt(scrollbar.offset);
        const upper: f64 = @floatFromInt(scrollbar.total);
        const page_size: f64 = @floatFromInt(scrollbar.len);
        if (std.math.approxEqAbs(f64, vadj.getValue(), value, 0.001) and
            std.math.approxEqAbs(f64, vadj.getUpper(), upper, 0.001) and
            std.math.approxEqAbs(f64, vadj.getPageSize(), page_size, 0.001))
        {
            return;
        }
        const priv = self.private();
        const group = priv.vadj_signal_group.?;
        group.block();
        defer group.unblock();
        vadj.configure(
            value,
            0,
            upper,
            1,
            page_size,
            page_size,
        );
    }
    pub fn setProgressReport(
        self: *Self,
        value: terminal.osc.Command.ProgressReport,
    ) void {
        const priv = self.private();
        if (priv.progress_bar_timer) |timer| {
            if (glib.Source.remove(timer) == 0) {
                log.warn("unable to remove progress bar timer", .{});
            }
            priv.progress_bar_timer = null;
        }
        if (priv.config) |config| {
            if (!config.get().@"progress-style") {
                log.debug("progress_report action blocked by config", .{});
                priv.progress_bar_overlay.as(gtk.Widget).setVisible(@intFromBool(false));
                return;
            }
        }
        const progress_bar = priv.progress_bar_overlay;
        switch (value.state) {
            .remove => {
                progress_bar.as(gtk.Widget).setVisible(@intFromBool(false));
                return;
            },
            .set => {
                progress_bar.as(gtk.Widget).removeCssClass("error");
                if (value.progress) |progress| {
                    progress_bar.setFraction(computeFraction(progress));
                } else {
                    progress_bar.pulse();
                }
            },
            .@"error" => {
                progress_bar.as(gtk.Widget).addCssClass("error");
                if (value.progress) |progress| {
                    progress_bar.setFraction(computeFraction(progress));
                } else {
                    progress_bar.pulse();
                }
            },
            .indeterminate => {
                progress_bar.pulse();
            },
            .pause => {
                if (value.progress) |progress| {
                    progress_bar.setFraction(computeFraction(progress));
                }
            },
        }
        assert(value.state != .remove);
        progress_bar.as(gtk.Widget).setVisible(@intFromBool(true));
        const progress_bar_timeout_seconds = 15;
        assert(priv.progress_bar_timer == null);
        priv.progress_bar_timer = glib.timeoutAdd(
            progress_bar_timeout_seconds * std.time.ms_per_s,
            progressBarTimer,
            self,
        );
    }
    fn progressBarTimer(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud.?));
        const priv = self.private();
        priv.progress_bar_timer = null;
        self.setProgressReport(.{ .state = .remove });
        return @intFromBool(glib.SOURCE_REMOVE);
    }
    pub fn present(self: *Self) void {
        signals.@"present-request".impl.emit(
            self,
            null,
            .{},
            null,
        );
    }
    pub fn commandFinished(self: *Self, value: apprt.Action.Value(.command_finished)) bool {
        const app = Application.default();
        const alloc = app.allocator();
        const priv: *Private = self.private();
        const notify_next_command_finish = notify: {
            const simple_action_group = priv.action_group orelse break :notify false;
            const action_group = simple_action_group.as(gio.ActionGroup);
            const state = action_group.getActionState("notify-on-next-command-finish") orelse break :notify false;
            const bool_variant_type = glib.ext.VariantType.newFor(bool);
            defer bool_variant_type.free();
            if (state.isOfType(bool_variant_type) == 0) break :notify false;
            const notify = state.getBoolean() != 0;
            action_group.changeActionState("notify-on-next-command-finish", glib.Variant.newBoolean(@intFromBool(false)));
            break :notify notify;
        };
        const config = priv.config orelse return false;
        const cfg = config.get();
        if (!notify_next_command_finish) {
            if (cfg.@"notify-on-command-finish" == .never) return true;
            if (cfg.@"notify-on-command-finish" == .unfocused and self.getFocused()) return true;
        }
        if (value.duration.lte(cfg.@"notify-on-command-finish-after")) return true;
        const action = cfg.@"notify-on-command-finish-action";
        if (action.bell) self.setBellRinging(true);
        if (action.notify) notify: {
            const title_ = title: {
                const exit_code = value.exit_code orelse break :title i18n._("Command Finished");
                if (exit_code == 0) break :title i18n._("Command Succeeded");
                break :title i18n._("Command Failed");
            };
            const title = std.mem.span(title_);
            const body = body: {
                const exit_code = value.exit_code orelse break :body std.fmt.allocPrintSentinel(
                    alloc,
                    "Command took {f}.",
                    .{value.duration.round(std.time.ns_per_ms)},
                    0,
                ) catch break :notify;
                break :body std.fmt.allocPrintSentinel(
                    alloc,
                    "Command took {f} and exited with code {d}.",
                    .{ value.duration.round(std.time.ns_per_ms), exit_code },
                    0,
                ) catch break :notify;
            };
            defer alloc.free(body);
            self.sendDesktopNotification(title, body);
        }
        return true;
    }
    pub fn getReadonly(self: *Self) bool {
        const priv: *Private = self.private();
        const surface = priv.core_surface orelse return false;
        return surface.readonly;
    }
    pub fn setReadonly(self: *Self, _: apprt.Action.Value(.readonly)) bool {
        self.as(gobject.Object).notifyByPspec(properties.readonly.impl.param_spec);
        return true;
    }
    pub fn keyEvent(
        self: *Surface,
        action: input.Action,
        ec_key: *gtk.EventControllerKey,
        keyval: c_uint,
        keycode: c_uint,
        gtk_mods: gdk.ModifierType,
    ) bool {
        const event = ec_key.as(gtk.EventController).getCurrentEvent() orelse return false;
        const key_event = gobject.ext.cast(gdk.KeyEvent, event) orelse return false;
        const priv = self.private();
        {
            if (priv.core_surface) |surface| {
                const ime_point = surface.imePoint();
                priv.im_context.as(gtk.IMContext).setCursorLocation(&.{
                    .f_x = @intFromFloat(ime_point.x),
                    .f_y = @intFromFloat(ime_point.y),
                    .f_width = 1,
                    .f_height = 1,
                });
            }
            priv.in_keyevent = if (priv.im_composing) .composing else .not_composing;
            defer priv.in_keyevent = .false;
            const im_handled = priv.im_context.as(gtk.IMContext).filterKeypress(event) != 0;
            if (im_handled) {
                if (priv.im_composing) return true;
                if (priv.in_keyevent == .composing) return true;
                if (priv.im_len == 0) return true;
            }
        }
        defer priv.im_len = 0;
        const keyval_unicode = gdk.keyvalToUnicode(keyval);
        const keyval_unicode_unshifted: u21 = gtk_key.keyvalUnicodeUnshifted(
            priv.render_surface.as(gtk.Widget),
            key_event,
            keycode,
        );
        const physical_key = keycode: {
            const w3c_key: input.Key = w3c: for (input.keycodes.entries) |entry| {
                if (entry.native == keycode) break :w3c entry.key;
            } else .unidentified;
            break :keycode gtk_key.remapKey(
                w3c_key,
                keyval,
                key_event.isModifier() != 0,
            );
        };
        const mods: input.Mods = gtk_key.eventMods(
            event,
            physical_key,
            gtk_mods,
            action,
            Application.default().winproto(),
        );
        const consumed_mods: input.Mods = consumed: {
            const T = @typeInfo(gdk.ModifierType);
            std.debug.assert(T.@"struct".layout == .@"packed");
            const I = T.@"struct".backing_integer.?;
            const masked = @as(I, @bitCast(key_event.getConsumedModifiers())) & @as(I, gdk.MODIFIER_MASK);
            break :consumed gtk_key.translateMods(@bitCast(masked));
        };
        if (priv.im_len == 0 and keyval_unicode > 0) im: {
            if (std.math.cast(u21, keyval_unicode)) |cp| {
                if (cp < 0x20) break :im;
                if (std.unicode.utf8Encode(cp, &priv.im_buf)) |len| {
                    priv.im_len = len;
                } else |_| {}
            }
        }
        const surface = priv.core_surface orelse return false;
        const effect = surface.keyCallback(.{
            .action = action,
            .key = physical_key,
            .mods = mods,
            .consumed_mods = consumed_mods,
            .composing = priv.im_composing,
            .utf8 = priv.im_buf[0..priv.im_len],
            .unshifted_codepoint = keyval_unicode_unshifted,
        }) catch |err| {
            log.err("error in key callback err={}", .{err});
            return false;
        };
        switch (effect) {
            .closed => return true,
            .ignored => {},
            .consumed => if (action == .press or action == .repeat) {
                if (priv.im_composing) {
                    priv.im_context.as(gtk.IMContext).reset();
                    surface.preeditCallback(null) catch {};
                }
                self.setBellRinging(false);
                return true;
            },
        }
        return false;
    }
    pub fn promptTitle(self: *Self) void {
        const priv = self.private();
        const dialog = TitleDialog.new(.surface, priv.title_override orelse priv.title);
        _ = TitleDialog.signals.set.connect(
            dialog,
            *Self,
            titleDialogSet,
            self,
            .{},
        );
        dialog.present(self.as(gtk.Widget));
    }
    fn scaledCoordinates(
        self: *Self,
        x: f64,
        y: f64,
    ) struct { x: f64, y: f64 } {
        const widget = self.private().render_surface;
        const scale_factor = scale_util.widgetSurfaceScale(widget.as(gtk.Widget));
        return .{
            .x = x * scale_factor,
            .y = y * scale_factor,
        };
    }
    pub fn close(self: *Self) void {
        signals.@"close-request".impl.emit(
            self,
            null,
            .{},
            null,
        );
    }
    pub fn childExited(
        self: *Self,
        data: apprt.surface.Message.ChildExited,
    ) bool {
        const priv = self.private();
        priv.child_exited = true;
        self.as(gobject.Object).notifyByPspec(
            properties.@"child-exited".impl.param_spec,
        );
        priv.child_exited_overlay.setData(&data);
        return true;
    }
    pub fn getContentScale(self: *Self) apprt.ContentScale {
        const priv = self.private();
        const widget = priv.render_surface.as(gtk.Widget);
        const gtk_scale: f32 = scale: {
            const surface_scale = scale_util.widgetSurfaceScale(widget);
            if (surface_scale <= 0) {
                logWarnOnce("widget surface scale was non-positive: {d}", .{surface_scale});
                break :scale 1.0;
            }
            break :scale @floatCast(surface_scale);
        };
        const xft_dpi_scale = xft_scale: {
            const gtk_xft_dpi = gsettings.get(.@"gtk-xft-dpi") orelse {
                logWarnOnce("gtk-xft-dpi was not set, using default value", .{});
                break :xft_scale 1.0;
            };
            if (gtk_xft_dpi <= 0) {
                if (gtk_xft_dpi != -1) {
                    logWarnOnce("gtk-xft-dpi has invalid value ({}), using default", .{gtk_xft_dpi});
                }
                break :xft_scale 1.0;
            }
            const xft_dpi: f32 = @as(f32, @floatFromInt(gtk_xft_dpi)) / 1024.0;
            break :xft_scale xft_dpi / 96.0;
        };
        const scale = gtk_scale * xft_dpi_scale;
        return .{ .x = scale, .y = scale };
    }
    pub fn getSize(self: *Self) apprt.SurfaceSize {
        const priv = self.private();
        assert(priv.size.width >= 0 and priv.size.height >= 0);
        return priv.size;
    }
    pub fn getCursorPos(self: *Self) apprt.CursorPos {
        return self.private().cursor_pos;
    }
    pub fn defaultTermioEnv(self: *Self) !std.process.Environ.Map {
        const app = Application.default();
        const alloc = app.allocator();
        var env = if (internal_os.isFlatpak())
            std.process.Environ.Map.init(alloc)
        else
            try global.environMap();
        errdefer env.deinit();
        if (app.savedLanguage()) |language| {
            try env.put("LANG", language);
        } else {
            _ = env.orderedRemove("LANG");
        }
        _ = env.orderedRemove("GDK_DEBUG");
        _ = env.orderedRemove("GDK_DISABLE");
        _ = env.orderedRemove("GSK_RENDERER");
        _ = env.orderedRemove("GIO_LAUNCHED_DESKTOP_FILE");
        _ = env.orderedRemove("GIO_LAUNCHED_DESKTOP_FILE_PID");
        _ = env.orderedRemove("DBUS_STARTER_ADDRESS");
        _ = env.orderedRemove("DBUS_STARTER_BUS_TYPE");
        _ = env.orderedRemove("INVOCATION_ID");
        _ = env.orderedRemove("JOURNAL_STREAM");
        _ = env.orderedRemove("NOTIFY_SOCKET");
        if (comptime build_config.snap) {
            if (env.get("SNAP") != null) try filterSnapPaths(
                alloc,
                &env,
            );
        }
        if (ext.getAncestor(Window, self.as(gtk.Widget))) |window| {
            try window.winproto().addSubprocessEnv(&env);
            if (window.isQuickTerminal()) {
                try env.put("WASP_QUICK_TERMINAL", "1");
            }
        }
        return env;
    }
    fn filterSnapPaths(gpa: std.mem.Allocator, env_map: *std.process.Environ.Map) !void {
        comptime assert(build_config.snap);
        const snap_vars = [_][]const u8{
            "SNAP",
            "SNAP_USER_COMMON",
            "SNAP_USER_DATA",
            "SNAP_DATA",
            "SNAP_COMMON",
        };
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const alloc = arena.allocator();
        var env_to_remove: std.ArrayList([]const u8) = .empty;
        var env_to_update: std.ArrayList(struct {
            key: []const u8,
            value: []const u8,
        }) = .empty;
        var it = env_map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            if (std.mem.eql(u8, key, "TERMINFO")) continue;
            if (std.mem.startsWith(u8, key, "WASP")) continue;
            if (std.mem.startsWith(u8, key, "SNAP_")) {
                try env_to_remove.append(alloc, key);
                continue;
            }
            var filtered_paths: std.ArrayList([]const u8) = .empty;
            var modified = false;
            var paths = std.mem.splitAny(u8, value, ":");
            while (paths.next()) |path| {
                var include = true;
                for (snap_vars) |k| if (env_map.get(k)) |snap_path| {
                    if (snap_path.len == 0) continue;
                    if (std.mem.startsWith(u8, path, snap_path)) {
                        include = false;
                        modified = true;
                        break;
                    }
                };
                if (include) try filtered_paths.append(alloc, path);
            }
            if (modified) {
                if (filtered_paths.items.len > 0) {
                    const new_value = try std.mem.join(alloc, ":", filtered_paths.items);
                    try env_to_update.append(alloc, .{ .key = key, .value = new_value });
                } else {
                    try env_to_remove.append(alloc, key);
                }
            }
        }
        for (env_to_update.items) |item| try env_map.put(
            item.key,
            item.value,
        );
        for (env_to_remove.items) |key| _ = env_map.orderedRemove(key);
    }
    pub fn clipboardRequest(
        self: *Self,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) !apprt.ClipboardReadResult {
        return try Clipboard.request(
            self,
            clipboard_type,
            state,
        );
    }
    pub fn setClipboard(
        self: *Self,
        clipboard_type: apprt.Clipboard,
        contents: []const apprt.ClipboardContent,
        confirm: bool,
    ) void {
        Clipboard.set(
            self,
            clipboard_type,
            contents,
            confirm,
        );
    }
    pub fn grabFocus(self: *Self) void {
        const priv = self.private();
        _ = priv.render_surface.as(gtk.Widget).grabFocus();
    }
    pub fn sendDesktopNotification(self: *Self, title: [:0]const u8, body: [:0]const u8) void {
        const app = Application.default();
        const priv: *Private = self.private();
        if (priv.core_surface == null) {
            log.warn("can't send notification because there is no core surface", .{});
            return;
        }
        priv.desktop_notifications.send(
            app.allocator(),
            priv.focused,
            title,
            body,
        );
    }
    fn clearDesktopNotifications(self: *Self) void {
        const app = Application.default();
        self.private().desktop_notifications.clear(app.allocator());
    }
    pub fn renderDeviceOptions(self: *Self) !renderer.Device.Options {
        switch (build_config.renderer) {
            .opengl => {
                const gtk_native = self.as(gtk.Widget).getNative() orelse return .{};
                const gdk_surface = gtk_native.getSurface() orelse return .{};
                const gdk_display = gdk_surface.getDisplay();
                if (comptime build_options.wayland) {
                    const gdk_wayland = @import("gdk_wayland");
                    if (gobject.ext.cast(gdk_wayland.WaylandDisplay, gdk_display)) |wl| {
                        return .{ .display = @ptrCast(wl.getEglDisplay()) };
                    }
                }
                if (comptime build_options.x11) {
                    const gdk_x11 = @import("gdk_x11");
                    if (gobject.ext.cast(gdk_x11.X11Display, gdk_display)) |x| {
                        return .{ .display = @ptrCast(x.getEglDisplay()) };
                    }
                }
                return .{};
            },
            .metal => comptime unreachable,
        }
    }
    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        self.initActionMap();
        const priv = self.private();
        priv.rt_surface = .{ .surface = self };
        priv.precision_scroll = false;
        priv.cursor_pos = .{ .x = 0, .y = 0 };
        priv.mouse_shape = .text;
        priv.mouse_hidden = false;
        priv.focused = true;
        priv.mapped = false;
        priv.size = .{ .width = 0, .height = 0 };
        priv.vadj_signal_group = null;
        priv.desktop_notifications = .{};
        if (priv.config == null) {
            const app = Application.default();
            priv.config = app.getConfig();
        }
        priv.in_keyevent = .false;
        priv.im_composing = false;
        priv.im_len = 0;
        priv.gtk_enable_primary_paste = gsettings.get(.@"gtk-enable-primary-paste") orelse true;
        var drop_target_types = [_]gobject.Type{
            gdk.FileList.getGObjectType(),
            gio.File.getGObjectType(),
            gobject.ext.types.string,
        };
        priv.drop_target.setGtypes(&drop_target_types, drop_target_types.len);
        var surface_drop_target_types = [_]gobject.Type{
            gobject.ext.types.uint64,
        };
        priv.surface_drop_target.setGtypes(
            &surface_drop_target_types,
            surface_drop_target_types.len,
        );
        priv.render_surface.as(gtk.Widget).setCursorFromName("text");
        priv.drag_handle.setCursorFromName("grab");
        self.propConfig(undefined, null);
    }
    fn initActionMap(self: *Self) void {
        const priv: *Private = self.private();
        const actions = [_]ext.actions.Action(Self){
            .init(
                "prompt-title",
                actionPromptTitle,
                null,
            ),
            .initStateful(
                "notify-on-next-command-finish",
                actionNotifyOnNextCommandFinish,
                null,
                glib.Variant.newBoolean(@intFromBool(false)),
            ),
        };
        priv.action_group = ext.actions.addAsGroup(Self, self, "surface", &actions);
    }
    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        self.clearDesktopNotifications();
        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }
        if (priv.is_split_binding) |binding| {
            binding.unbind();
            binding.unref();
            priv.is_split_binding = null;
        }
        if (priv.vadj_signal_group) |group| {
            group.setTarget(null);
            group.as(gobject.Object).unref();
            priv.vadj_signal_group = null;
        }
        if (priv.hadj) |v| {
            v.as(gobject.Object).unref();
            priv.hadj = null;
        }
        if (priv.vadj) |v| {
            v.as(gobject.Object).unref();
            priv.vadj = null;
        }
        if (priv.progress_bar_timer) |timer| {
            if (glib.Source.remove(timer) == 0) {
                log.warn("unable to remove progress bar timer", .{});
            }
            priv.progress_bar_timer = null;
        }
        if (priv.idle_rechild) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove idle source", .{});
            }
            priv.idle_rechild = null;
        }
        if (priv.pending_horizontal_scroll_reset) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove pending horizontal scroll reset source", .{});
            }
            priv.pending_horizontal_scroll_reset = null;
        }
        self.as(adw.Bin).setChild(null);
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
        const alloc = Application.default().allocator();
        const priv = self.private();
        if (priv.core_surface) |v| {
            Application.default().core().deleteSurface(self.rt());
            v.deinit();
            alloc.destroy(v);
            priv.core_surface = null;
        }
        if (priv.mouse_hover_url) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.mouse_hover_url = null;
        }
        if (priv.default_size) |v| {
            ext.boxedFree(Size, v);
            priv.default_size = null;
        }
        if (priv.font_size_request) |v| {
            glib.ext.destroy(v);
            priv.font_size_request = null;
        }
        if (priv.min_size) |v| {
            ext.boxedFree(Size, v);
            priv.min_size = null;
        }
        if (priv.pwd) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.pwd = null;
        }
        if (priv.title) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.title = null;
        }
        if (priv.title_override) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.title_override = null;
        }
        if (priv.overrides.command) |c| {
            c.deinit(alloc);
            priv.overrides.command = null;
        }
        if (priv.overrides.working_directory) |wd| {
            alloc.free(wd);
            priv.overrides.working_directory = null;
        }
        for (priv.key_sequence.items) |s| alloc.free(s);
        priv.key_sequence.deinit(alloc);
        for (priv.key_tables.items) |s| alloc.free(s);
        priv.key_tables.deinit(alloc);
        priv.desktop_notifications.deinit(alloc);
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }
    fn snapshot(self: *Self, snap: *gtk.Snapshot) callconv(.c) void {
        const priv = self.private();
        const blur = blur: {
            if (gtk_version.runtimeUntil(4, 23, 3)) break :blur null;
            const config = priv.config orelse break :blur null;
            break :blur switch (config.get().@"background-blur") {
                .radius => |v| @as(f32, v),
                .true, .@"macos-glass-regular", .@"macos-glass-clear" => 20.0,
                .false => null,
            };
        };
        if (blur) |b| blur: {
            if (comptime !gtk_version.atLeast(4, 22, 0)) break :blur;
            const width = self.as(gtk.Widget).getWidth();
            const height = self.as(gtk.Widget).getHeight();
            snap.pushCopy();
            defer snap.pop();
            snap.pushBlur(b);
            defer snap.pop();
            snap.appendPaste(&.{
                .f_origin = .{ .f_x = 0, .f_y = 0 },
                .f_size = .{
                    .f_width = @floatFromInt(width),
                    .f_height = @floatFromInt(height),
                },
            }, 0);
        }
        gtk.Widget.virtual_methods.snapshot.call(
            Class.parent,
            self.as(Parent),
            snap,
        );
    }
    pub fn getTitle(self: *Self) ?[:0]const u8 {
        return self.private().title;
    }
    pub fn getEffectiveTitle(self: *Self) ?[:0]const u8 {
        const priv = self.private();
        return priv.title_override orelse priv.title;
    }
    pub fn copyTitleToClipboard(self: *Self) bool {
        const title = self.getEffectiveTitle() orelse return false;
        if (title.len == 0) return false;
        self.setClipboard(.standard, &.{.{
            .mime = "text/plain",
            .data = title,
        }}, false);
        return true;
    }
    pub fn setTitle(self: *Self, title: ?[:0]const u8) void {
        const priv = self.private();
        if (priv.title) |v| glib.free(@ptrCast(@constCast(v)));
        priv.title = null;
        if (title) |v| priv.title = glib.ext.dupeZ(u8, v);
        self.as(gobject.Object).notifyByPspec(properties.title.impl.param_spec);
    }
    pub fn setTitleOverride(self: *Self, title: ?[:0]const u8) void {
        const priv = self.private();
        if (priv.title_override) |v| glib.free(@ptrCast(@constCast(v)));
        priv.title_override = null;
        if (title) |v| priv.title_override = glib.ext.dupeZ(u8, v);
        self.as(gobject.Object).notifyByPspec(properties.@"title-override".impl.param_spec);
    }
    pub fn getPwd(self: *Self) ?[:0]const u8 {
        return self.private().pwd;
    }
    pub fn setPwd(self: *Self, pwd: ?[:0]const u8) void {
        const priv = self.private();
        if (priv.pwd) |v| glib.free(@ptrCast(@constCast(v)));
        priv.pwd = null;
        if (pwd) |v| priv.pwd = glib.ext.dupeZ(u8, v);
        self.as(gobject.Object).notifyByPspec(properties.pwd.impl.param_spec);
    }
    pub fn getFocused(self: *Self) bool {
        return self.private().focused;
    }
    pub fn getMapped(self: *Self) bool {
        return self.private().mapped;
    }
    pub fn setConfig(self: *Self, config: *Config) void {
        const priv = self.private();
        if (priv.config) |c| c.unref();
        priv.config = config.ref();
        self.as(gobject.Object).notifyByPspec(properties.config.impl.param_spec);
    }
    pub fn getDefaultSize(self: *Self) ?*Size {
        const priv = self.private();
        return priv.default_size;
    }
    pub fn setDefaultSize(self: *Self, size: Size) void {
        const priv = self.private();
        if (priv.default_size) |v| ext.boxedFree(
            Size,
            v,
        );
        priv.default_size = ext.boxedCopy(
            Size,
            &size,
        );
        self.as(gobject.Object).notifyByPspec(properties.@"default-size".impl.param_spec);
    }
    pub fn estimateInitialSize(self: *Self) void {
        const priv: *Private = self.private();
        const config_obj = priv.config orelse return;
        const config = config_obj.get();
        if (config.@"window-height" <= 0 or config.@"window-width" <= 0) return;
        const app = Application.default();
        const alloc = app.allocator();
        const content_scale = self.getContentScale();
        const x_dpi = content_scale.x * font.face.default_dpi;
        const y_dpi = content_scale.y * font.face.default_dpi;
        const font_size: font.face.DesiredSize = .{
            .points = config.@"font-size",
            .xdpi = @intFromFloat(@round(x_dpi)),
            .ydpi = @intFromFloat(@round(y_dpi)),
        };
        var derived_config = font.SharedGridSet.DerivedConfig.init(alloc, config) catch return;
        defer derived_config.deinit();
        const font_grid_key, const font_grid = app.core().font_grid_set.ref(
            &derived_config,
            font_size,
        ) catch return;
        defer app.core().font_grid_set.deref(font_grid_key);
        const cell = font_grid.cellSize();
        const width = @max(CoreSurface.min_window_width_cells, config.@"window-width") * cell.width;
        const height = @max(CoreSurface.min_window_height_cells, config.@"window-height") * cell.height;
        const width_f32: f32 = @floatFromInt(width);
        const height_f32: f32 = @floatFromInt(height);
        const final_width: u32 = @intFromFloat(@ceil(width_f32 / content_scale.x));
        const final_height: u32 = @intFromFloat(@ceil(height_f32 / content_scale.y));
        self.setDefaultSize(.{ .width = final_width, .height = final_height });
    }
    fn getKeySequence(self: *Self) ?*ext.StringList {
        const priv = self.private();
        const alloc = Application.default().allocator();
        return ext.StringList.create(alloc, priv.key_sequence.items) catch null;
    }
    fn getKeyTable(self: *Self) ?*ext.StringList {
        const priv = self.private();
        const alloc = Application.default().allocator();
        return ext.StringList.create(alloc, priv.key_tables.items) catch null;
    }
    pub fn getMinSize(self: *Self) ?*Size {
        const priv = self.private();
        return priv.min_size;
    }
    pub fn setMinSize(self: *Self, size: Size) void {
        const priv = self.private();
        if (priv.min_size) |v| ext.boxedFree(
            Size,
            v,
        );
        priv.min_size = ext.boxedCopy(
            Size,
            &size,
        );
        self.as(gobject.Object).notifyByPspec(properties.@"min-size".impl.param_spec);
    }
    pub fn getMouseShape(self: *Self) terminal.MouseShape {
        return self.private().mouse_shape;
    }
    pub fn setMouseShape(self: *Self, shape: terminal.MouseShape) void {
        const priv = self.private();
        priv.mouse_shape = shape;
        self.as(gobject.Object).notifyByPspec(properties.@"mouse-shape".impl.param_spec);
    }
    pub fn getMouseHidden(self: *Self) bool {
        return self.private().mouse_hidden;
    }
    pub fn setMouseHidden(self: *Self, hidden: bool) void {
        const priv = self.private();
        priv.mouse_hidden = hidden;
        self.as(gobject.Object).notifyByPspec(properties.@"mouse-hidden".impl.param_spec);
    }
    pub fn setMouseHoverUrl(self: *Self, url: ?[:0]const u8) void {
        const priv = self.private();
        if (priv.mouse_hover_url) |v| glib.free(@ptrCast(@constCast(v)));
        priv.mouse_hover_url = null;
        if (url) |v| priv.mouse_hover_url = glib.ext.dupeZ(u8, v);
        self.as(gobject.Object).notifyByPspec(properties.@"mouse-hover-url".impl.param_spec);
    }
    pub fn getBellRinging(self: *Self) bool {
        return self.private().bell_ringing;
    }
    pub fn setBellRinging(self: *Self, ringing: bool) void {
        self.as(gobject.Object).freezeNotify();
        defer self.as(gobject.Object).thawNotify();
        if (ringing) {
            self.ringBell();
            if (self.getFocused()) return;
        }
        const priv = self.private();
        if (priv.bell_ringing == ringing) return;
        priv.bell_ringing = ringing;
        self.as(gobject.Object).notifyByPspec(properties.@"bell-ringing".impl.param_spec);
    }
    pub fn setError(self: *Self, v: bool) void {
        const priv = self.private();
        priv.@"error" = v;
        self.as(gobject.Object).notifyByPspec(properties.@"error".impl.param_spec);
    }
    pub fn setSearchActive(self: *Self, active: bool, needle: [:0]const u8) void {
        const priv = self.private();
        var value = gobject.ext.Value.newFrom(active);
        defer value.unset();
        gobject.Object.setProperty(
            priv.search_overlay.as(gobject.Object),
            SearchOverlay.properties.active.name,
            &value,
        );
        if (!std.mem.eql(u8, needle, "")) {
            priv.search_overlay.setSearchContents(needle);
        }
        if (active) {
            priv.search_overlay.grabFocus();
        }
    }
    pub fn setSearchTotal(self: *Self, total: ?usize) void {
        self.private().search_overlay.setSearchTotal(total);
    }
    pub fn setSearchSelected(self: *Self, selected: ?usize) void {
        self.private().search_overlay.setSearchSelected(selected);
    }
    fn propConfig(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();
        const config = if (priv.config) |c| c.get() else return;
        {
            const ms = config.@"resize-overlay-duration".asMilliseconds();
            var value = gobject.ext.Value.newFrom(ms);
            defer value.unset();
            gobject.Object.setProperty(
                priv.resize_overlay.as(gobject.Object),
                "duration",
                &value,
            );
        }
        {
            const hv: struct {
                gtk.Align,
                gtk.Align,
            } = switch (config.@"resize-overlay-position") {
                .center => .{ .center, .center },
                .@"top-left" => .{ .start, .start },
                .@"top-right" => .{ .end, .start },
                .@"top-center" => .{ .center, .start },
                .@"bottom-left" => .{ .start, .end },
                .@"bottom-right" => .{ .end, .end },
                .@"bottom-center" => .{ .center, .end },
            };
            var halign = gobject.ext.Value.newFrom(hv[0]);
            defer halign.unset();
            var valign = gobject.ext.Value.newFrom(hv[1]);
            defer valign.unset();
            gobject.Object.setProperty(
                priv.resize_overlay.as(gobject.Object),
                "overlay-halign",
                &halign,
            );
            gobject.Object.setProperty(
                priv.resize_overlay.as(gobject.Object),
                "overlay-valign",
                &valign,
            );
        }
    }
    fn propError(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.@"error") {
            self.as(gtk.Widget).addCssClass("background");
        } else {
            self.as(gtk.Widget).removeCssClass("background");
        }
        if (priv.idle_rechild == null) priv.idle_rechild = glib.idleAdd(
            onIdleRechild,
            self,
        );
    }
    fn onIdleRechild(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        priv.idle_rechild = null;
        if (priv.@"error") {
            self.as(adw.Bin).setChild(priv.error_page.as(gtk.Widget));
        } else {
            self.as(adw.Bin).setChild(priv.terminal_page.as(gtk.Widget));
        }
        return 0;
    }
    fn propMouseHoverUrl(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();
        const visible = if (priv.mouse_hover_url) |v| v.len > 0 else false;
        priv.url_left.as(gtk.Widget).setVisible(if (visible) 1 else 0);
    }
    fn propMouseHidden(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.mouse_hidden) {
            priv.render_surface.as(gtk.Widget).setCursorFromName("none");
            return;
        }
        self.propMouseShape(undefined, null);
    }
    fn propMouseShape(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.mouse_hidden) return;
        const name: [:0]const u8 = switch (priv.mouse_shape) {
            .default => "default",
            .help => "help",
            .pointer => "pointer",
            .context_menu => "context-menu",
            .progress => "progress",
            .wait => "wait",
            .cell => "cell",
            .crosshair => "crosshair",
            .text => "text",
            .vertical_text => "vertical-text",
            .alias => "alias",
            .copy => "copy",
            .no_drop => "no-drop",
            .move => "move",
            .not_allowed => "not-allowed",
            .grab => "grab",
            .grabbing => "grabbing",
            .all_scroll => "all-scroll",
            .col_resize => "col-resize",
            .row_resize => "row-resize",
            .n_resize => "n-resize",
            .e_resize => "e-resize",
            .s_resize => "s-resize",
            .w_resize => "w-resize",
            .ne_resize => "ne-resize",
            .nw_resize => "nw-resize",
            .se_resize => "se-resize",
            .sw_resize => "sw-resize",
            .ew_resize => "ew-resize",
            .ns_resize => "ns-resize",
            .nesw_resize => "nesw-resize",
            .nwse_resize => "nwse-resize",
            .zoom_in => "zoom-in",
            .zoom_out => "zoom-out",
        };
        priv.render_surface.as(gtk.Widget).setCursorFromName(name.ptr);
    }
    fn vadjValueChanged(adj: *gtk.Adjustment, self: *Self) callconv(.c) void {
        const core_surface = self.core() orelse return;
        const row: usize = @intFromFloat(@round(adj.getValue()));
        _ = core_surface.performBindingAction(.{ .scroll_to_row = row }) catch |err| {
            log.err("error performing scroll_to_row action err={}", .{err});
        };
    }
    fn propVAdjustment(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();
        const group: *gobject.SignalGroup = priv.vadj_signal_group orelse group: {
            const group = gobject.SignalGroup.new(gtk.Adjustment.getGObjectType());
            group.connect(
                "value-changed",
                @ptrCast(&vadjValueChanged),
                self,
            );
            priv.vadj_signal_group = group;
            break :group group;
        };
        group.setTarget(if (priv.vadj) |v| v.as(gobject.Object) else null);
    }
    fn ringBell(self: *Self) void {
        signals.bell.impl.emit(
            self,
            null,
            .{},
            null,
        );
        _ = self.as(gtk.Widget).activateAction("tab.ring-bell", null);
        _ = self.as(gtk.Widget).activateAction("win.ring-bell", null);
        _ = self.as(gtk.Widget).activateAction("app.ring-bell", null);
    }
    pub fn getHAdjustment(self: *Self) ?*gtk.Adjustment {
        return self.private().hadj;
    }
    pub fn setHAdjustment(self: *Self, adj_: ?*gtk.Adjustment) void {
        self.as(gobject.Object).freezeNotify();
        defer self.as(gobject.Object).thawNotify();
        self.as(gobject.Object).notifyByPspec(properties.hadjustment.impl.param_spec);
        const priv = self.private();
        if (priv.hadj) |old| {
            old.as(gobject.Object).unref();
            priv.hadj = null;
        }
        const adj = adj_ orelse return;
        _ = adj.as(gobject.Object).ref();
        priv.hadj = adj;
    }
    fn getHAdjustmentValue(self: *Self, value: *gobject.Value) void {
        gobject.ext.Value.set(value, self.getHAdjustment());
    }
    fn setHAdjustmentValue(self: *Self, value: *const gobject.Value) void {
        self.setHAdjustment(gobject.ext.Value.get(value, ?*gtk.Adjustment));
    }
    pub fn getVAdjustment(self: *Self) ?*gtk.Adjustment {
        return self.private().vadj;
    }
    pub fn setVAdjustment(self: *Self, adj_: ?*gtk.Adjustment) void {
        self.as(gobject.Object).freezeNotify();
        defer self.as(gobject.Object).thawNotify();
        self.as(gobject.Object).notifyByPspec(properties.vadjustment.impl.param_spec);
        const priv = self.private();
        if (priv.vadj) |old| {
            old.as(gobject.Object).unref();
            priv.vadj = null;
        }
        const adj = adj_ orelse return;
        _ = adj.as(gobject.Object).ref();
        priv.vadj = adj;
    }
    fn getVAdjustmentValue(self: *Self, value: *gobject.Value) void {
        gobject.ext.Value.set(value, self.getVAdjustment());
    }
    fn setVAdjustmentValue(self: *Self, value: *const gobject.Value) void {
        self.setVAdjustment(gobject.ext.Value.get(value, ?*gtk.Adjustment));
    }
    pub fn actionPromptTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const surface = self.core() orelse return;
        _ = surface.performBindingAction(.prompt_surface_title) catch |err| {
            log.warn("unable to perform prompt title action err={}", .{err});
        };
    }
    pub fn actionNotifyOnNextCommandFinish(
        action: *gio.SimpleAction,
        _: ?*glib.Variant,
        _: *Self,
    ) callconv(.c) void {
        const state = action.as(gio.Action).getState() orelse glib.Variant.newBoolean(@intFromBool(false));
        defer state.unref();
        const bool_variant_type = glib.ext.VariantType.newFor(bool);
        defer bool_variant_type.free();
        if (state.isOfType(bool_variant_type) == 0) return;
        const value = state.getBoolean() != 0;
        action.setState(glib.Variant.newBoolean(@intFromBool(!value)));
    }
    fn childExitedClose(
        _: *ChildExited,
        self: *Self,
    ) callconv(.c) void {
        self.close();
    }
    fn contextMenuClosed(
        _: *gtk.PopoverMenu,
        self: *Self,
    ) callconv(.c) void {
        self.grabFocus();
    }
    fn inspectorWeakNotify(
        ud: ?*anyopaque,
        _: *gobject.Object,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        const priv = self.private();
        priv.inspector = null;
    }
    fn dtDrop(
        _: *gtk.DropTarget,
        value: *gobject.Value,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) c_int {
        const alloc = Application.default().allocator();
        if (ext.gValueHolds(value, gdk.FileList.getGObjectType())) {
            var stream: std.Io.Writer.Allocating = .init(alloc);
            defer stream.deinit();
            var shell_escape_writer: internal_os.ShellEscapeWriter = .init(&stream.writer);
            const writer = &shell_escape_writer.writer;
            const list: ?*glib.SList = list: {
                const unboxed = value.getBoxed() orelse return 0;
                const fl: *gdk.FileList = @ptrCast(@alignCast(unboxed));
                break :list fl.getFiles();
            };
            defer if (list) |v| v.free();
            {
                var current: ?*glib.SList = list;
                while (current) |item| : (current = item.f_next) {
                    const file: *gio.File = @ptrCast(@alignCast(item.f_data orelse continue));
                    const path = file.getPath() orelse continue;
                    const slice = std.mem.span(path);
                    defer glib.free(path);
                    writer.writeAll(slice) catch |err| {
                        log.err("unable to write path to buffer: {}", .{err});
                        continue;
                    };
                    writer.writeAll("\n") catch |err| {
                        log.err("unable to write to buffer: {}", .{err});
                        continue;
                    };
                }
            }
            const string = stream.toOwnedSliceSentinel(0) catch |err| {
                log.err("unable to convert to a slice: {}", .{err});
                return 0;
            };
            defer alloc.free(string);
            Clipboard.paste(self, string);
            return 1;
        }
        if (ext.gValueHolds(value, gio.File.getGObjectType())) {
            const object = value.getObject() orelse return 0;
            const file = gobject.ext.cast(gio.File, object) orelse return 0;
            const path = file.getPath() orelse return 0;
            var stream: std.Io.Writer.Allocating = .init(alloc);
            defer stream.deinit();
            var shell_escape_writer: internal_os.ShellEscapeWriter = .init(&stream.writer);
            const writer = &shell_escape_writer.writer;
            writer.writeAll(std.mem.span(path)) catch |err| {
                log.err("unable to write path to buffer: {}", .{err});
                return 0;
            };
            writer.writeAll("\n") catch |err| {
                log.err("unable to write to buffer: {}", .{err});
                return 0;
            };
            const string = stream.toOwnedSliceSentinel(0) catch |err| {
                log.err("unable to convert to a slice: {}", .{err});
                return 0;
            };
            defer alloc.free(string);
            return 1;
        }
        if (ext.gValueHolds(value, gobject.ext.types.string)) {
            if (value.getString()) |string| {
                Clipboard.paste(self, std.mem.span(string));
            }
            return 1;
        }
        return 1;
    }
    fn ecKeyPressed(
        ec_key: *gtk.EventControllerKey,
        keyval: c_uint,
        keycode: c_uint,
        gtk_mods: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        return @intFromBool(self.keyEvent(
            .press,
            ec_key,
            keyval,
            keycode,
            gtk_mods,
        ));
    }
    fn ecKeyReleased(
        ec_key: *gtk.EventControllerKey,
        keyval: c_uint,
        keycode: c_uint,
        state: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) void {
        _ = self.keyEvent(
            .release,
            ec_key,
            keyval,
            keycode,
            state,
        );
    }
    fn ecFocusEnter(_: *gtk.EventControllerFocus, self: *Self) callconv(.c) void {
        self.updateFocus(true);
    }
    fn ecFocusLeave(_: *gtk.EventControllerFocus, self: *Self) callconv(.c) void {
        self.updateFocus(false);
    }
    fn updateFocus(self: *Self, focused: bool) void {
        const priv = self.private();
        priv.focused = focused;
        const ctx = priv.im_context.as(gtk.IMContext);
        if (focused) ctx.focusIn() else ctx.focusOut();
        _ = glib.idleAddOnce(idleFocus, self.ref());
        self.as(gobject.Object).notifyByPspec(properties.focused.impl.param_spec);
        if (focused) {
            self.setBellRinging(false);
            self.clearDesktopNotifications();
        }
    }
    fn idleFocus(ud: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        defer self.unref();
        const priv = self.private();
        const surface = priv.core_surface orelse return;
        surface.focusCallback(priv.focused) catch |err| {
            log.warn("error in focus callback err={}", .{err});
        };
    }
    fn gcMouseDown(
        gesture: *gtk.GestureClick,
        _: c_int,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) void {
        const event = gesture.as(gtk.EventController).getCurrentEvent() orelse return;
        self.setBellRinging(false);
        const priv = self.private();
        const core_surface = priv.core_surface orelse return;
        const widget = priv.render_surface.as(gtk.Widget);
        const had_focus = widget.hasFocus() != 0;
        if (!had_focus) {
            _ = widget.grabFocus();
        }
        const button = translateMouseButton(gesture.as(gtk.GestureSingle).getCurrentButton());
        if (!had_focus and button == .left) {
            priv.suppress_left_mouse_release = true;
            return;
        }
        if (button == .middle and
            !priv.gtk_enable_primary_paste and
            !core_surface.mouseReportingActive())
        {
            return;
        }
        const consumed = consumed: {
            const gtk_mods = event.getModifierState();
            const mods = gtk_key.translateMods(gtk_mods);
            break :consumed core_surface.mouseButtonCallback(
                .press,
                button,
                mods,
            ) catch |err| err: {
                log.warn("error in key callback err={}", .{err});
                break :err false;
            };
        };
        if (!consumed and button == .right) {
            signals.menu.impl.emit(
                self,
                null,
                .{},
                null,
            );
            const rect: gdk.Rectangle = .{
                .f_x = @intFromFloat(x),
                .f_y = @intFromFloat(y),
                .f_width = 1,
                .f_height = 1,
            };
            const popover = priv.context_menu.as(gtk.Popover);
            popover.setPointingTo(&rect);
            popover.popup();
        }
    }
    fn gcMouseUp(
        gesture: *gtk.GestureClick,
        _: c_int,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        const event = gesture.as(gtk.EventController).getCurrentEvent() orelse return;
        const priv = self.private();
        const surface = priv.core_surface orelse return;
        const gtk_mods = event.getModifierState();
        const button = translateMouseButton(gesture.as(gtk.GestureSingle).getCurrentButton());
        if (button == .left and priv.suppress_left_mouse_release) {
            priv.suppress_left_mouse_release = false;
            return;
        }
        if (button == .middle and
            !priv.gtk_enable_primary_paste and
            !surface.mouseReportingActive())
        {
            return;
        }
        const mods = gtk_key.translateMods(gtk_mods);
        const consumed = surface.mouseButtonCallback(
            .release,
            button,
            mods,
        ) catch |err| {
            log.warn("error in key callback err={}", .{err});
            return;
        };
        if (!consumed and button == .left and !surface.hasSelection()) {
            if (!self.showOnScreenKeyboard(event)) {
                log.warn("failed to activate the on-screen keyboard", .{});
            }
        }
    }
    fn ecMouseMotion(
        ec: *gtk.EventControllerMotion,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) void {
        const event = ec.as(gtk.EventController).getCurrentEvent() orelse return;
        const priv = self.private();
        const scaled = self.scaledCoordinates(x, y);
        const pos: apprt.CursorPos = .{
            .x = @floatCast(scaled.x),
            .y = @floatCast(scaled.y),
        };
        const is_cursor_still = @abs(priv.cursor_pos.x - pos.x) < 1 and
            @abs(priv.cursor_pos.y - pos.y) < 1;
        if (is_cursor_still) return;
        if (priv.config) |config| {
            const widget = priv.render_surface.as(gtk.Widget);
            if (widget.hasFocus() == 0 and
                config.get().@"focus-follows-mouse")
            {
                _ = widget.grabFocus();
            }
        }
        priv.cursor_pos = pos;
        if (priv.core_surface) |surface| {
            const gtk_mods = event.getModifierState();
            const mods = gtk_key.translateMods(gtk_mods);
            surface.cursorPosCallback(priv.cursor_pos, mods) catch |err| {
                log.warn("error in cursor pos callback err={}", .{err});
            };
        }
    }
    fn ecMouseLeave(
        ec_motion: *gtk.EventControllerMotion,
        self: *Self,
    ) callconv(.c) void {
        const event = ec_motion.as(gtk.EventController).getCurrentEvent() orelse return;
        const priv = self.private();
        if (priv.core_surface) |surface| {
            const gtk_mods = event.getModifierState();
            const mods = gtk_key.translateMods(gtk_mods);
            surface.cursorPosCallback(
                .{ .x = -1, .y = -1 },
                mods,
            ) catch |err| {
                log.warn("error in cursor pos callback err={}", .{err});
                return;
            };
        }
    }
    fn ecMouseScrollVerticalPrecisionBegin(
        _: *gtk.EventControllerScroll,
        self: *Self,
    ) callconv(.c) void {
        self.private().precision_scroll = true;
    }
    fn ecMouseScrollVerticalPrecisionEnd(
        _: *gtk.EventControllerScroll,
        self: *Self,
    ) callconv(.c) void {
        self.private().precision_scroll = false;
    }
    fn ecMouseScrollVertical(
        _: *gtk.EventControllerScroll,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) c_int {
        const priv: *Private = self.private();
        const surface = priv.core_surface orelse return 0;
        const multiplier: f64 = if (priv.precision_scroll) 10.0 else 1.0;
        const scroll_mods: input.ScrollMods = .{
            .precision = priv.precision_scroll,
        };
        const scaled = self.scaledCoordinates(x, y);
        surface.scrollCallback(
            scaled.x * -1 * multiplier,
            scaled.y * -1 * multiplier,
            scroll_mods,
        ) catch |err| {
            log.warn("error in scroll callback err={}", .{err});
            return 0;
        };
        return 1;
    }
    fn ecMouseScrollHorizontal(
        ec: *gtk.EventControllerScroll,
        x: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) c_int {
        const priv: *Private = self.private();
        const tab_scroll_enabled = if (priv.config) |config|
            config.get().@"gtk-horizontal-tab-scroll"
        else
            true;
        const is_surface_scroll = ec.getUnit() == .surface;
        if (tab_scroll_enabled and is_surface_scroll) {
            priv.pending_horizontal_scroll += x;
            if (@abs(priv.pending_horizontal_scroll) < 120) {
                if (priv.pending_horizontal_scroll_reset) |v| {
                    _ = glib.Source.remove(v);
                    priv.pending_horizontal_scroll_reset = null;
                }
                priv.pending_horizontal_scroll_reset = glib.timeoutAdd(500, ecMouseScrollHorizontalReset, self);
                return @intFromBool(true);
            }
            _ = self.as(gtk.Widget).activateAction(
                if (priv.pending_horizontal_scroll < 0.0)
                    "tab.next-page"
                else
                    "tab.previous-page",
                null,
            );
            if (priv.pending_horizontal_scroll_reset) |v| {
                _ = glib.Source.remove(v);
                priv.pending_horizontal_scroll_reset = null;
            }
            priv.pending_horizontal_scroll = 0.0;
            return @intFromBool(true);
        }
        const surface = priv.core_surface orelse return @intFromBool(false);
        const scaled = self.scaledCoordinates(x, 0);
        surface.scrollCallback(
            scaled.x * -1,
            0,
            .{},
        ) catch |err| {
            log.warn("error in scroll callback err={}", .{err});
            return @intFromBool(false);
        };
        return @intFromBool(true);
    }
    fn ecMouseScrollHorizontalReset(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return @intFromBool(glib.SOURCE_REMOVE)));
        const priv: *Private = self.private();
        priv.pending_horizontal_scroll = 0.0;
        priv.pending_horizontal_scroll_reset = null;
        return @intFromBool(glib.SOURCE_REMOVE);
    }
    fn imPreeditStart(
        _: *gtk.IMMulticontext,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.im_composing = true;
        priv.im_len = 0;
    }
    fn imPreeditChanged(
        ctx: *gtk.IMMulticontext,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.im_composing = true;
        const surface = priv.core_surface orelse return;
        var buf: [*:0]u8 = undefined;
        ctx.as(gtk.IMContext).getPreeditString(
            &buf,
            null,
            null,
        );
        defer glib.free(buf);
        const str = std.mem.sliceTo(buf, 0);
        surface.preeditCallback(str) catch |err| {
            log.warn(
                "error in preedit callback err={}",
                .{err},
            );
        };
    }
    fn imPreeditEnd(
        _: *gtk.IMMulticontext,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.im_composing = false;
        const surface = priv.core_surface orelse return;
        surface.preeditCallback(null) catch |err| {
            log.warn("error in preedit callback err={}", .{err});
        };
    }
    fn imCommit(
        _: *gtk.IMMulticontext,
        bytes: [*:0]u8,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const str = std.mem.sliceTo(bytes, 0);
        switch (priv.in_keyevent) {
            .false => {},
            .composing => {},
            .not_composing => {
                if (str.len > priv.im_buf.len) {
                    log.warn("not enough buffer space for input method commit", .{});
                    return;
                }
                @memcpy(priv.im_buf[0..str.len], str);
                priv.im_len = @intCast(str.len);
                return;
            },
        }
        priv.im_composing = false;
        if (priv.core_surface) |surface| {
            surface.preeditCallback(null) catch |err| {
                log.warn("error in preedit callback err={}", .{err});
            };
            _ = surface.keyCallback(.{
                .action = .press,
                .key = .unidentified,
                .mods = .{},
                .consumed_mods = .{},
                .composing = false,
                .utf8 = str,
            }) catch |err| {
                log.warn("error in key callback err={}", .{err});
            };
        }
    }
    fn renderSurfaceRealize(
        _: *RenderSurface,
        self: *Self,
    ) callconv(.c) void {
        log.debug("render surface realize", .{});
        const priv = self.private();
        if (priv.core_surface) |v| {
            v.displayRealized() catch |err| {
                log.warn("core displayRealized failed err={}", .{err});
            };
            self.redraw();
        }
        priv.im_context.as(gtk.IMContext).setClientWidget(self.as(gtk.Widget));
    }
    fn renderSurfaceUnrealize(
        _: *RenderSurface,
        self: *Self,
    ) callconv(.c) void {
        log.debug("render surface unrealize", .{});
        const priv = self.private();
        if (priv.core_surface) |surface| {
            surface.displayUnrealized();
        }
        priv.im_context.as(gtk.IMContext).setClientWidget(null);
    }
    fn renderSurfaceMap(
        _: *RenderSurface,
        self: *Self,
    ) callconv(.c) void {
        self.updateMapped(true);
        self.updateOcclusion();
    }
    fn renderSurfaceUnmap(
        _: *RenderSurface,
        self: *Self,
    ) callconv(.c) void {
        self.updateMapped(false);
        self.updateOcclusion();
    }
    fn updateMapped(self: *Self, mapped: bool) void {
        const priv = self.private();
        priv.mapped = mapped;
        self.as(gobject.Object).notifyByPspec(properties.mapped.impl.param_spec);
    }
    pub fn updateOcclusion(self: *Self) void {
        const surface = self.core() orelse return;
        const visible = self.private().mapped and !self.windowSuspended();
        surface.occlusionCallback(visible) catch |err| {
            log.warn("error in occlusion callback err={}", .{err});
        };
    }
    fn windowSuspended(self: *Self) bool {
        const native = self.as(gtk.Widget).getNative() orelse return false;
        const window = gobject.ext.cast(gtk.Window, native) orelse return false;
        return window.isSuspended() != 0;
    }
    fn renderSurfaceResize(
        _: *RenderSurface,
        width: c_int,
        height: c_int,
        self: *Self,
    ) callconv(.c) void {
        {
            const widget = self.private().render_surface.as(gtk.Widget);
            log.debug("gl resize width={} height={} scale={d} scale_factor={}", .{
                width,
                height,
                scale_util.widgetSurfaceScale(widget),
                widget.getScaleFactor(),
            });
        }
        const priv = self.private();
        const new_size: apprt.SurfaceSize = .{
            .width = @intCast(width),
            .height = @intCast(height),
        };
        const changed = !priv.size.eql(&new_size);
        priv.size = new_size;
        if (priv.core_surface) |surface| {
            surface.contentScaleCallback(self.getContentScale()) catch |err| {
                log.warn("error in content scale callback err={}", .{err});
            };
            if (changed) {
                surface.sizeCallback(new_size) catch |err| {
                    log.warn("error in size callback err={}", .{err});
                };
                self.resizeOverlaySchedule();
            }
        } else {
            self.initSurface() catch |err| {
                log.warn("surface failed to initialize err={}", .{err});
            };
        }
    }
    const InitError = Allocator.Error || error{
        SurfaceError,
    };
    fn initSurface(self: *Self) InitError!void {
        const priv: *Private = self.private();
        assert(priv.core_surface == null);
        const app = Application.default();
        const alloc = app.allocator();
        const surface = try alloc.create(CoreSurface);
        errdefer alloc.destroy(surface);
        try app.core().addSurface(self.rt());
        errdefer app.core().deleteSurface(self.rt());
        var config = try apprt.surface.newConfig(
            app.core(),
            priv.config.?.get(),
            priv.context,
        );
        defer config.deinit();
        try applyCommandOverrides(
            &config,
            priv.overrides.command,
            priv.overrides.shell_integration,
        );
        if (priv.overrides.working_directory) |wd| {
            const config_alloc = config.arenaAlloc();
            var wd_val: configpkg.WorkingDirectory = .{ .path = try config_alloc.dupe(u8, wd) };
            try wd_val.finalize(config_alloc);
            config.@"working-directory" = wd_val;
        }
        if (priv.font_size_request) |size| config.@"font-size" = size.points;
        if (priv.pwd) |pwd| {
            const config_alloc = config.arenaAlloc();
            var wd_val: configpkg.WorkingDirectory = .{ .path = try config_alloc.dupe(u8, pwd) };
            try wd_val.finalize(config_alloc);
            config.@"working-directory" = wd_val;
        }
        const content_scale = self.getContentScale();
        log.info("surface content scale: x={d} y={d} dpi={}x{} font_size={}", .{
            content_scale.x,
            content_scale.y,
            @round(content_scale.x * font.face.default_dpi),
            @round(content_scale.y * font.face.default_dpi),
            config.@"font-size",
        });
        surface.init(
            alloc,
            &config,
            app.core(),
            app.rt(),
            &priv.rt_surface,
        ) catch |err| {
            log.warn("failed to initialize surface err={}", .{err});
            return error.SurfaceError;
        };
        errdefer surface.deinit();
        priv.core_surface = surface;
        priv.desktop_notifications = .init(surface.id);
        priv.render_surface.setCoreSurface(surface);
        if (priv.render_surface.as(gtk.Widget).getRealized() == 0) {
            surface.displayUnrealized();
        }
        Surface.signals.init.impl.emit(
            self,
            null,
            .{},
            null,
        );
        self.updateFocus(priv.focused);
    }
    fn resizeOverlaySchedule(self: *Self) void {
        const priv = self.private();
        const surface = priv.core_surface orelse return;
        const config = if (priv.config) |c| c.get() else return;
        switch (config.@"resize-overlay") {
            .always, .@"after-first" => {},
            .never => return,
        }
        var buf: [32]u8 = undefined;
        priv.resize_overlay.setLabel(text: {
            const grid_size = surface.size.grid();
            break :text std.fmt.bufPrintZ(
                &buf,
                "{d} x {d}",
                .{
                    grid_size.columns,
                    grid_size.rows,
                },
            ) catch |err| err: {
                log.warn("unable to format text: {}", .{err});
                break :err "";
            };
        });
        priv.resize_overlay.schedule();
    }
    fn ecUrlMouseEnter(
        _: *gtk.EventControllerMotion,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const right = priv.url_right.as(gtk.Widget);
        right.setVisible(1);
    }
    fn ecUrlMouseLeave(
        _: *gtk.EventControllerMotion,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const right = priv.url_right.as(gtk.Widget);
        right.setVisible(0);
    }
    fn titleDialogSet(
        _: *TitleDialog,
        title_ptr: [*:0]const u8,
        self: *Self,
    ) callconv(.c) void {
        const title = std.mem.span(title_ptr);
        self.setTitleOverride(if (title.len == 0) null else title);
    }
    fn searchStop(_: *SearchOverlay, self: *Self) callconv(.c) void {
        const surface = self.core() orelse return;
        _ = surface.performBindingAction(.end_search) catch |err| {
            log.warn("unable to perform end_search action err={}", .{err});
        };
        _ = self.private().render_surface.as(gtk.Widget).grabFocus();
    }
    fn searchChanged(_: *SearchOverlay, needle: ?[*:0]const u8, self: *Self) callconv(.c) void {
        const surface = self.core() orelse return;
        _ = surface.performBindingAction(.{ .search = std.mem.sliceTo(needle orelse "", 0) }) catch |err| {
            log.warn("unable to perform search action err={}", .{err});
        };
    }
    fn searchNextMatch(_: *SearchOverlay, self: *Self) callconv(.c) void {
        const surface = self.core() orelse return;
        _ = surface.performBindingAction(.{ .navigate_search = .next }) catch |err| {
            log.warn("unable to perform navigate_search action err={}", .{err});
        };
    }
    fn searchPreviousMatch(_: *SearchOverlay, self: *Self) callconv(.c) void {
        const surface = self.core() orelse return;
        _ = surface.performBindingAction(.{ .navigate_search = .previous }) catch |err| {
            log.warn("unable to perform navigate_search action err={}", .{err});
        };
    }
    fn closureShouldDragHandleBeShown(
        _: *Self,
        config_: ?*Config,
        is_split: c_int,
    ) callconv(.c) c_int {
        const config = config_ orelse return @intFromBool(false);
        const shown = switch (config.get().@"drag-handle") {
            .always => true,
            .auto => is_split != 0,
            .never => false,
        };
        return @intFromBool(shown);
    }
    fn surfaceDragPrepare(
        src: *gtk.DragSource,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) *gdk.ContentProvider {
        _ = src;
        _ = x;
        _ = y;
        var val = gobject.ext.Value.newFrom(self.core().?.id);
        return gdk.ContentProvider.newForValue(&val);
    }
    fn surfaceDragBegin(
        src: *gtk.DragSource,
        _: *gdk.Drag,
        self: *Self,
    ) callconv(.c) void {
        const preview_scale: f32 = 0.2;
        const paintable = gtk.WidgetPaintable.new(self.as(gtk.Widget));
        defer paintable.unref();
        const width = self.as(gtk.Widget).getWidth();
        const height = self.as(gtk.Widget).getHeight();
        const mid_x = @as(f32, @floatFromInt(width)) / 2;
        const mid_y = @as(f32, @floatFromInt(height)) / 2;
        const snap = gtk.Snapshot.new();
        snap.scale(preview_scale, preview_scale);
        paintable.as(gdk.Paintable).snapshot(
            snap.as(gdk.Snapshot),
            @floatFromInt(width),
            @floatFromInt(height),
        );
        if (snap.freeToPaintable(null)) |scaled| {
            defer scaled.unref();
            src.setIcon(
                scaled,
                @intFromFloat(mid_x * preview_scale),
                @intFromFloat(mid_y * preview_scale),
            );
        } else {
            log.warn("preview scaling failed - falling back to original paintable", .{});
            src.setIcon(
                paintable.as(gdk.Paintable),
                @intFromFloat(mid_x),
                @intFromFloat(mid_y),
            );
        }
    }
    fn surfaceDrop(
        _: *gtk.DropTarget,
        v: *const gobject.Value,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) void {
        const dropped_id = v.getUint64();
        const dropped = self.core().?.app.findSurfaceByID(dropped_id) orelse return;
        const from = dropped.rt_surface.gobj();
        const st = ext.getAncestor(
            SplitTree,
            self.as(gtk.Widget),
        ) orelse {
            log.warn("surface is not placed in a split tree", .{});
            return;
        };
        const dir = self.calcDropDirection(x, y);
        st.moveSplit(from, self, dir) catch return;
        self.setDropOverlayDirection(null);
    }
    fn surfaceDropLeave(
        _: *gtk.DropTarget,
        self: *Self,
    ) callconv(.c) void {
        self.setDropOverlayDirection(null);
    }
    fn surfaceDropMotion(
        _: *gtk.DropTarget,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) gdk.DragAction {
        const dir = self.calcDropDirection(x, y);
        self.setDropOverlayDirection(dir);
        return .{ .move = true };
    }
    fn propDropValue(
        tgt: *gtk.DropTarget,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const core_surface = self.core() orelse return;
        const value = tgt.getValue() orelse return;
        const surface_id = value.getUint64();
        if (core_surface.id == surface_id) tgt.reject();
    }
    fn setDropOverlayDirection(self: *Self, dir: ?Tree.Split.Direction) void {
        const priv = self.private();
        inline for (&.{ "drop-top", "drop-left", "drop-right", "drop-bottom" }) |c| {
            priv.drop_overlay.removeCssClass(c);
        }
        if (dir) |d| priv.drop_overlay.addCssClass(switch (d) {
            .up => "drop-top",
            .left => "drop-left",
            .right => "drop-right",
            .down => "drop-bottom",
        });
    }
    fn calcDropDirection(self: *Self, x: f64, y: f64) Tree.Split.Direction {
        const width: f64 = @floatFromInt(self.as(gtk.Widget).getWidth());
        const height: f64 = @floatFromInt(self.as(gtk.Widget).getHeight());
        const l_dist = x / width;
        const t_dist = y / height;
        const r_dist = 1 - l_dist;
        const b_dist = 1 - t_dist;
        const min = @min(l_dist, t_dist, r_dist, b_dist);
        if (min == l_dist) return .left;
        if (min == r_dist) return .right;
        if (min == t_dist) return .up;
        return .down;
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
            gobject.ext.ensureType(ResizeOverlay);
            gobject.ext.ensureType(SearchOverlay);
            gobject.ext.ensureType(KeyStateOverlay);
            gobject.ext.ensureType(ChildExited);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 0,
                    .name = "surface",
                }),
            );
            class.bindTemplateChildPrivate("render_surface", .{});
            class.bindTemplateChildPrivate("url_left", .{});
            class.bindTemplateChildPrivate("url_right", .{});
            class.bindTemplateChildPrivate("child_exited_overlay", .{});
            class.bindTemplateChildPrivate("context_menu", .{});
            class.bindTemplateChildPrivate("error_page", .{});
            class.bindTemplateChildPrivate("progress_bar_overlay", .{});
            class.bindTemplateChildPrivate("resize_overlay", .{});
            class.bindTemplateChildPrivate("search_overlay", .{});
            class.bindTemplateChildPrivate("key_state_overlay", .{});
            class.bindTemplateChildPrivate("terminal_page", .{});
            class.bindTemplateChildPrivate("drop_target", .{});
            class.bindTemplateChildPrivate("surface_drop_target", .{});
            class.bindTemplateChildPrivate("drag_handle", .{});
            class.bindTemplateChildPrivate("drop_overlay", .{});
            class.bindTemplateChildPrivate("im_context", .{});
            class.bindTemplateCallback("focus_enter", &ecFocusEnter);
            class.bindTemplateCallback("focus_leave", &ecFocusLeave);
            class.bindTemplateCallback("key_pressed", &ecKeyPressed);
            class.bindTemplateCallback("key_released", &ecKeyReleased);
            class.bindTemplateCallback("mouse_down", &gcMouseDown);
            class.bindTemplateCallback("mouse_up", &gcMouseUp);
            class.bindTemplateCallback("mouse_motion", &ecMouseMotion);
            class.bindTemplateCallback("mouse_leave", &ecMouseLeave);
            class.bindTemplateCallback("scroll_vertical", &ecMouseScrollVertical);
            class.bindTemplateCallback("scroll_vertical_begin", &ecMouseScrollVerticalPrecisionBegin);
            class.bindTemplateCallback("scroll_vertical_end", &ecMouseScrollVerticalPrecisionEnd);
            class.bindTemplateCallback("scroll_horizontal", &ecMouseScrollHorizontal);
            class.bindTemplateCallback("drop", &dtDrop);
            class.bindTemplateCallback("render_surface_realize", &renderSurfaceRealize);
            class.bindTemplateCallback("render_surface_unrealize", &renderSurfaceUnrealize);
            class.bindTemplateCallback("render_surface_map", &renderSurfaceMap);
            class.bindTemplateCallback("render_surface_unmap", &renderSurfaceUnmap);
            class.bindTemplateCallback("render_surface_resize", &renderSurfaceResize);
            class.bindTemplateCallback("im_preedit_start", &imPreeditStart);
            class.bindTemplateCallback("im_preedit_changed", &imPreeditChanged);
            class.bindTemplateCallback("im_preedit_end", &imPreeditEnd);
            class.bindTemplateCallback("im_commit", &imCommit);
            class.bindTemplateCallback("url_mouse_enter", &ecUrlMouseEnter);
            class.bindTemplateCallback("url_mouse_leave", &ecUrlMouseLeave);
            class.bindTemplateCallback("child_exited_close", &childExitedClose);
            class.bindTemplateCallback("context_menu_closed", &contextMenuClosed);
            class.bindTemplateCallback("notify_config", &propConfig);
            class.bindTemplateCallback("notify_error", &propError);
            class.bindTemplateCallback("notify_mouse_hover_url", &propMouseHoverUrl);
            class.bindTemplateCallback("notify_mouse_hidden", &propMouseHidden);
            class.bindTemplateCallback("notify_mouse_shape", &propMouseShape);
            class.bindTemplateCallback("notify_vadjustment", &propVAdjustment);
            class.bindTemplateCallback("should_border_be_shown", &closureShouldBorderBeShown);
            class.bindTemplateCallback("should_unfocused_split_be_shown", &closureShouldUnfocusedSplitBeShown);
            class.bindTemplateCallback("search_stop", &searchStop);
            class.bindTemplateCallback("search_changed", &searchChanged);
            class.bindTemplateCallback("search_next_match", &searchNextMatch);
            class.bindTemplateCallback("search_previous_match", &searchPreviousMatch);
            class.bindTemplateCallback("should_drag_handle_be_shown", &closureShouldDragHandleBeShown);
            class.bindTemplateCallback("surface_drag_prepare", &surfaceDragPrepare);
            class.bindTemplateCallback("surface_drag_begin", &surfaceDragBegin);
            class.bindTemplateCallback("surface_drop", &surfaceDrop);
            class.bindTemplateCallback("surface_drop_leave", &surfaceDropLeave);
            class.bindTemplateCallback("surface_drop_motion", &surfaceDropMotion);
            class.bindTemplateCallback("notify_drop_value", &propDropValue);
            gobject.ext.registerProperties(class, &.{
                properties.@"bell-ringing".impl,
                properties.config.impl,
                properties.@"child-exited".impl,
                properties.@"default-size".impl,
                properties.@"error".impl,
                properties.@"font-size-request".impl,
                properties.focused.impl,
                properties.mapped.impl,
                properties.@"key-sequence".impl,
                properties.@"key-table".impl,
                properties.@"min-size".impl,
                properties.@"mouse-shape".impl,
                properties.@"mouse-hidden".impl,
                properties.@"mouse-hover-url".impl,
                properties.pwd.impl,
                properties.title.impl,
                properties.@"title-override".impl,
                properties.zoom.impl,
                properties.@"is-split".impl,
                properties.readonly.impl,
                properties.hadjustment.impl,
                properties.vadjustment.impl,
                properties.@"hscroll-policy".impl,
                properties.@"vscroll-policy".impl,
            });
            signals.bell.impl.register(.{});
            signals.@"close-request".impl.register(.{});
            signals.@"clipboard-read".impl.register(.{});
            signals.@"clipboard-write".impl.register(.{});
            signals.init.impl.register(.{});
            signals.menu.impl.register(.{});
            signals.@"present-request".impl.register(.{});
            signals.@"toggle-fullscreen".impl.register(.{});
            signals.@"toggle-maximize".impl.register(.{});
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
            gtk.Widget.virtual_methods.snapshot.implement(class, &snapshot);
        }
        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
    pub const Size = extern struct {
        width: u32,
        height: u32,
        pub const getGObjectType = gobject.ext.defineBoxed(
            Size,
            .{ .name = "WaspSurfaceSize" },
        );
    };
};
fn logWarnOnce(comptime format: []const u8, args: anytype) void {
    const Static = struct {
        const key = .{ format, @TypeOf(args) };
        var flag = false;
    };
    if (Static.flag) return else {
        @branchHint(.unlikely);
        Static.flag = true;
    }
    log.warn(format, args);
}
pub const IMKeyEvent = enum {
    false,
    composing,
    not_composing,
};
fn translateMouseButton(button: c_uint) input.MouseButton {
    return switch (button) {
        1 => .left,
        2 => .middle,
        3 => .right,
        4 => .four,
        5 => .five,
        6 => .six,
        7 => .seven,
        8 => .eight,
        9 => .nine,
        10 => .ten,
        11 => .eleven,
        else => .unknown,
    };
}
const Clipboard = struct {
    pub fn set(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        contents: []const apprt.ClipboardContent,
        confirm: bool,
    ) void {
        const priv = self.private();
        const text: [:0]const u8 = for (contents) |content| {
            if (std.mem.eql(u8, content.mime, "text/plain")) {
                break content.data;
            }
        } else return;
        if (!confirm) {
            const clipboard = get(
                priv.render_surface.as(gtk.Widget),
                clipboard_type,
            ) orelse return;
            const alloc = Application.default().allocator();
            if (alloc.alloc(*gdk.ContentProvider, contents.len)) |providers| {
                defer alloc.free(providers);
                for (contents, 0..) |content, i| {
                    const bytes = glib.Bytes.new(content.data.ptr, content.data.len);
                    defer bytes.unref();
                    if (std.mem.eql(u8, content.mime, "text/plain")) {
                        const text_provider_atoms = [_][:0]const u8{
                            "text/plain;charset=utf-8",
                            "text/plain",
                        };
                        var text_providers: [text_provider_atoms.len]*gdk.ContentProvider = undefined;
                        for (text_provider_atoms, 0..) |atom, j| {
                            const provider = gdk.ContentProvider.newForBytes(atom, bytes);
                            text_providers[j] = provider;
                        }
                        const text_union = gdk.ContentProvider.newUnion(
                            &text_providers,
                            text_providers.len,
                        );
                        providers[i] = text_union;
                    } else {
                        const provider = gdk.ContentProvider.newForBytes(content.mime, bytes);
                        providers[i] = provider;
                    }
                }
                const all = gdk.ContentProvider.newUnion(providers.ptr, providers.len);
                defer all.unref();
                _ = clipboard.setContent(all);
            } else |_| {
                clipboard.setText(text);
            }
            Surface.signals.@"clipboard-write".impl.emit(
                self,
                null,
                .{ clipboard_type, text.ptr },
                null,
            );
            return;
        }
        showClipboardConfirmation(
            self,
            .{ .osc_52_write = clipboard_type },
            text,
        );
    }
    pub fn request(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) Allocator.Error!apprt.ClipboardReadResult {
        if (state == .kitty_read or
            state == .kitty_write or
            state == .list) return .unsupported;
        const clipboard = get(
            self.private().render_surface.as(gtk.Widget),
            clipboard_type,
        ) orelse return .unsupported;
        if (state == .paste) {
            const formats = clipboard.getFormats();
            if (formats.containGtype(gobject.ext.types.string) == 0) {
                log.debug("clipboard has no text format, not starting paste request", .{});
                return .unavailable;
            }
        }
        const alloc = Application.default().allocator();
        const ud = try alloc.create(Request);
        errdefer alloc.destroy(ud);
        ud.* = .{
            .self = self.ref(),
            .state = state,
        };
        errdefer self.unref();
        clipboard.readTextAsync(
            null,
            clipboardReadText,
            ud,
        );
        return .started;
    }
    pub fn paste(
        self: *Surface,
        text: [:0]const u8,
    ) void {
        if (text.len == 0) return;
        const surface = self.private().core_surface orelse return;
        surface.completeClipboardRequest(
            .{ .paste = .standard },
            .{ .contents = &.{.{ .mime = "text/plain", .data = text }} },
        ) catch |err| switch (err) {
            error.UnsafePaste,
            error.UnauthorizedPaste,
            => {
                showClipboardConfirmation(
                    self,
                    .{ .paste = .standard },
                    text,
                );
                return;
            },
            else => {
                log.warn(
                    "failed to complete clipboard request err={}",
                    .{err},
                );
                return;
            },
        };
    }
    fn get(
        widget: *gtk.Widget,
        clipboard: apprt.Clipboard,
    ) ?*gdk.Clipboard {
        return switch (clipboard) {
            .standard => widget.getClipboard(),
            .selection, .primary => widget.getPrimaryClipboard(),
        };
    }
    fn showClipboardConfirmation(
        self: *Surface,
        req: apprt.ClipboardRequest,
        str: [:0]const u8,
    ) void {
        const contents_buf: *gtk.TextBuffer = .new(null);
        defer contents_buf.unref();
        contents_buf.insertAtCursor(str, @intCast(str.len));
        const dialog = gobject.ext.newInstance(
            ClipboardConfirmationDialog,
            .{
                .request = &req,
                .@"can-remember" = switch (req) {
                    .osc_52_read, .osc_52_write => true,
                    .paste, .list, .kitty_read, .kitty_write => false,
                },
                .@"clipboard-contents" = contents_buf,
            },
        );
        _ = ClipboardConfirmationDialog.signals.confirm.connect(
            dialog,
            *Surface,
            clipboardConfirmationConfirm,
            self,
            .{},
        );
        _ = ClipboardConfirmationDialog.signals.deny.connect(
            dialog,
            *Surface,
            clipboardConfirmationDeny,
            self,
            .{},
        );
        dialog.present(self.as(gtk.Widget));
    }
    fn clipboardConfirmationConfirm(
        dialog: *ClipboardConfirmationDialog,
        remember: bool,
        self: *Surface,
    ) callconv(.c) void {
        const priv = self.private();
        const surface = priv.core_surface orelse return;
        const req = dialog.getRequest() orelse return;
        if (remember) switch (req.*) {
            .osc_52_read => surface.config.clipboard_read = .allow,
            .osc_52_write => surface.config.clipboard_write = .allow,
            .paste, .list, .kitty_read, .kitty_write => {},
        };
        const text_buf = dialog.getClipboardContents() orelse return;
        var text_val = gobject.ext.Value.new(?[:0]const u8);
        defer text_val.unset();
        gobject.Object.getProperty(
            text_buf.as(gobject.Object),
            "text",
            &text_val,
        );
        const text = gobject.ext.Value.get(
            &text_val,
            ?[:0]const u8,
        ) orelse return;
        surface.completeClipboardRequest(req.*, .{
            .contents = &.{.{ .mime = "text/plain", .data = text }},
            .confirmed = true,
        }) catch |err| {
            log.warn("failed to complete clipboard request: {}", .{err});
        };
    }
    fn clipboardConfirmationDeny(
        dialog: *ClipboardConfirmationDialog,
        remember: bool,
        self: *Surface,
    ) callconv(.c) void {
        const priv = self.private();
        const surface = priv.core_surface orelse return;
        const req = dialog.getRequest() orelse return;
        if (remember) switch (req.*) {
            .osc_52_read => surface.config.clipboard_read = .deny,
            .osc_52_write => surface.config.clipboard_write = .deny,
            .paste, .list, .kitty_read, .kitty_write => @panic("request should not be able to be remembered"),
        };
    }
    fn clipboardReadText(
        source: ?*gobject.Object,
        res: *gio.AsyncResult,
        ud: ?*anyopaque,
    ) callconv(.c) void {
        const clipboard = gobject.ext.cast(
            gdk.Clipboard,
            source orelse return,
        ) orelse return;
        const req: *Request = @ptrCast(@alignCast(ud orelse return));
        const alloc = Application.default().allocator();
        defer alloc.destroy(req);
        const self = req.self;
        defer self.unref();
        var gerr: ?*glib.Error = null;
        const cstr_ = clipboard.readTextFinish(res, &gerr);
        if (gerr) |err| {
            defer err.free();
            log.warn(
                "failed to read clipboard err={s}",
                .{err.f_message orelse "(no message)"},
            );
            return;
        }
        const cstr = cstr_ orelse return;
        defer glib.free(cstr);
        const str = std.mem.sliceTo(cstr, 0);
        const surface = self.private().core_surface orelse return;
        surface.completeClipboardRequest(
            req.state,
            .{ .contents = &.{.{ .mime = "text/plain", .data = str }} },
        ) catch |err| switch (err) {
            error.UnsafePaste,
            error.UnauthorizedPaste,
            => {
                showClipboardConfirmation(
                    self,
                    req.state,
                    str,
                );
                return;
            },
            else => {
                log.warn(
                    "failed to complete clipboard request err={}",
                    .{err},
                );
                return;
            },
        };
        Surface.signals.@"clipboard-read".impl.emit(
            self,
            null,
            .{},
            null,
        );
    }
    const Request = struct {
        self: *Surface,
        state: apprt.ClipboardRequest,
    };
};
fn computeFraction(progress: u8) f64 {
    return @as(f64, @floatFromInt(std.math.clamp(progress, 0, 100))) / 100.0;
}
test "computeFraction" {
    try std.testing.expectEqual(1.0, computeFraction(100));
    try std.testing.expectEqual(1.0, computeFraction(255));
    try std.testing.expectEqual(0.0, computeFraction(0));
    try std.testing.expectEqual(0.5, computeFraction(50));
}
fn applyCommandOverrides(
    config: *configpkg.Config,
    command: ?configpkg.Command,
    shell_integration: ?configpkg.Config.ShellIntegration,
) Allocator.Error!void {
    if (command) |value| {
        config.command = try value.clone(config.arenaAlloc());
        if (shell_integration) |integration| {
            config.@"shell-integration" = integration;
        } else if (config.@"shell-integration" != .none) {
            config.@"shell-integration" = .detect;
        }
    } else if (shell_integration) |value| {
        config.@"shell-integration" = value;
    }
}
test "command and shell integration overrides" {
    const testing = std.testing;
    var config = try configpkg.Config.default(testing.allocator);
    defer config.deinit();
    config.@"shell-integration" = .nushell;
    try applyCommandOverrides(&config, .{ .shell = "vim" }, null);
    try testing.expectEqual(.detect, config.@"shell-integration");
    config.@"shell-integration" = .none;
    try applyCommandOverrides(&config, .{ .shell = "vim" }, null);
    try testing.expectEqual(.none, config.@"shell-integration");
    try applyCommandOverrides(&config, .{ .shell = "nu" }, .nushell);
    try testing.expectEqual(.nushell, config.@"shell-integration");
    try applyCommandOverrides(&config, .{ .shell = "vim" }, .none);
    try testing.expectEqual(.none, config.@"shell-integration");
    config.@"shell-integration" = .nushell;
    try applyCommandOverrides(&config, null, null);
    try testing.expectEqual(.nushell, config.@"shell-integration");
    config.@"shell-integration" = .none;
    try applyCommandOverrides(&config, null, .nushell);
    try testing.expectEqual(.nushell, config.@"shell-integration");
    try applyCommandOverrides(&config, null, .none);
    try testing.expectEqual(.none, config.@"shell-integration");
}
