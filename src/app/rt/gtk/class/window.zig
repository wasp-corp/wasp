const std = @import("std");
const build_config = @import("../../../build_config.zig");
const assert = @import("../../../quirks.zig").inlineAssert;
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const i18n = @import("../../../os/root.zig").i18n;
const apprt = @import("../../../apprt.zig");
const configpkg = @import("../../../config.zig");
const TitlebarStyle = configpkg.Config.GtkTitlebarStyle;
const input = @import("../../../input.zig");
const CoreSurface = @import("../../../Surface.zig");
const ext = @import("../ext.zig");
const gtk_version = @import("../gtk_version.zig");
const gresource = @import("../build/gresource.zig");
const winprotopkg = @import("../winproto.zig");
const Common = @import("../class.zig").Common;
const Config = @import("config.zig").Config;
const Application = @import("application.zig").Application;
const CloseConfirmationDialog = @import("close_confirmation_dialog.zig").CloseConfirmationDialog;
const SplitTree = @import("split_tree.zig").SplitTree;
const Surface = @import("surface.zig").Surface;
const Tab = @import("tab.zig").Tab;
const DebugWarning = @import("debug_warning.zig").DebugWarning;
const CommandPalette = @import("command_palette.zig").CommandPalette;
const WeakRef = @import("../weak_ref.zig").WeakRef;
const TitleDialog = @import("title_dialog.zig").TitleDialog;
const Overrides = @import("Overrides.zig");
const log = std.log.scoped(.gtk_wasp_window);
pub const Window = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.ApplicationWindow;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WaspWindow",
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
                            .getter = Self.getActiveSurface,
                        },
                    ),
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
        pub const @"titlebar-style" = struct {
            pub const name = "titlebar-style";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                TitlebarStyle,
                .{
                    .default = .native,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        TitlebarStyle,
                        .{
                            .getter = Self.getTitlebarStyle,
                        },
                    ),
                },
            );
        };
        pub const @"headerbar-visible" = struct {
            pub const name = "headerbar-visible";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getHeaderbarVisible,
                    }),
                },
            );
        };
        pub const @"quick-terminal" = struct {
            pub const name = "quick-terminal";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "quick_terminal",
                    ),
                },
            );
        };
        pub const @"tabs-autohide" = struct {
            pub const name = "tabs-autohide";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getTabsAutohide,
                    }),
                },
            );
        };
        pub const @"tabs-inverted" = struct {
            pub const name = "tabs-inverted";
            const impl = gobject.ext.defineProperty(name, Self, bool, .{
                .default = false,
                .accessor = gobject.ext.typedAccessor(
                    Self,
                    bool,
                    .{
                        .getter = Self.getTabsInverted,
                    },
                ),
            });
        };
        pub const @"tabs-wide" = struct {
            pub const name = "tabs-wide";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getTabsWide,
                    }),
                },
            );
        };
        pub const @"tabs-visible" = struct {
            pub const name = "tabs-visible";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getTabsVisible,
                    }),
                },
            );
        };
        pub const @"toolbar-style" = struct {
            pub const name = "toolbar-style";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                adw.ToolbarStyle,
                .{
                    .default = .raised,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        adw.ToolbarStyle,
                        .{
                            .getter = Self.getToolbarStyle,
                        },
                    ),
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
    };
    const Private = struct {
        quick_terminal: bool = false,
        handle_active_state_source: ?c_uint = null,
        window_decoration: ?configpkg.WindowDecoration = null,
        tab_bindings: *gobject.BindingGroup,
        config: ?*Config = null,
        winproto: winprotopkg.Window,
        surface_init: bool = false,
        resize_requested: bool = false,
        tab_overview_focus_timer: ?c_uint = null,
        command_palette: WeakRef(CommandPalette) = .empty,
        context_menu_page: ?*adw.TabPage = null,
        title_override: ?[:0]const u8 = null,
        tab_overview: *adw.TabOverview,
        tab_bar: *adw.TabBar,
        tab_view: *adw.TabView,
        toolbar: *adw.ToolbarView,
        toast_overlay: *adw.ToastOverlay,
        pub var offset: c_int = 0;
    };
    pub fn new(
        app: *Application,
        overrides: struct {
            title: ?[:0]const u8 = null,
            pub const none: @This() = .{};
        },
    ) *Self {
        const win = gobject.ext.newInstance(Self, .{
            .application = app,
        });
        if (overrides.title) |title| {
            win.as(gtk.Window).setTitle(title);
        }
        return win;
    }
    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        const priv = self.private();
        const config = config: {
            if (priv.config) |config| break :config config.get();
            const app = Application.default();
            const config = app.getConfig();
            priv.config = config;
            break :config config.get();
        };
        priv.winproto = .none;
        if (comptime build_config.is_debug) {
            self.as(gtk.Widget).addCssClass("devel");
        }
        priv.tab_bindings = gobject.BindingGroup.new();
        priv.tab_bindings.bind("title", self.as(gobject.Object), "title", .{});
        self.as(gtk.Window).setIconName(build_config.bundle_id);
        self.initActionMap();
        if (config.maximize) self.as(gtk.Window).maximize();
        if (config.fullscreen != .false) self.as(gtk.Window).fullscreen();
        if (config.title) |title| {
            self.as(gtk.Window).setTitle(title);
        }
        self.syncAppearance();
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
    }
    fn initActionMap(self: *Self) void {
        const s_variant_type = glib.ext.VariantType.newFor([:0]const u8);
        defer s_variant_type.free();
        const actions = [_]ext.actions.Action(Self){
            .init("about", actionAbout, null),
            .init("close", actionClose, null),
            .init("close-tab", actionCloseTab, s_variant_type),
            .init("new-tab", actionNewTab, null),
            .init("new-window", actionNewWindow, null),
            .init("prompt-surface-title", actionPromptSurfaceTitle, null),
            .init("prompt-tab-title", actionPromptTabTitle, null),
            .init("prompt-context-tab-title", actionPromptContextTabTitle, null),
            .init("prompt-window-title", actionPromptWindowTitle, null),
            .init("ring-bell", actionRingBell, null),
            .init("split-right", actionSplitRight, null),
            .init("split-left", actionSplitLeft, null),
            .init("split-up", actionSplitUp, null),
            .init("split-down", actionSplitDown, null),
            .init("copy", actionCopy, null),
            .init("paste", actionPaste, null),
            .init("reset", actionReset, null),
            .init("clear", actionClear, null),
            .init("toggle-command-palette", actionToggleCommandPalette, null),
            .init("toggle-inspector", actionToggleInspector, null),
        };
        ext.actions.add(Self, self, &actions);
    }
    pub fn winproto(self: *Self) *winprotopkg.Window {
        return &self.private().winproto;
    }
    pub fn newTab(self: *Self, parent_: ?*CoreSurface, overrides: Overrides) void {
        _ = self.newTabPage(parent_, .tab, .{
            .command = overrides.command,
            .shell_integration = overrides.shell_integration,
            .working_directory = overrides.working_directory,
            .title = overrides.title,
        });
    }
    pub fn newTabForWindow(self: *Self, parent_: ?*CoreSurface, overrides: Overrides) void {
        _ = self.newTabPage(
            parent_,
            .window,
            .{
                .command = overrides.command,
                .shell_integration = overrides.shell_integration,
                .working_directory = overrides.working_directory,
                .title = overrides.title,
            },
        );
    }
    fn newTabPage(
        self: *Self,
        parent_: ?*CoreSurface,
        context: apprt.surface.NewSurfaceContext,
        overrides: Overrides,
    ) *adw.TabPage {
        const priv: *Private = self.private();
        const tab_view = priv.tab_view;
        const tab = Tab.new(
            priv.config,
            .{
                .command = overrides.command,
                .shell_integration = overrides.shell_integration,
                .working_directory = overrides.working_directory,
                .title = overrides.title,
            },
        );
        if (parent_) |p| {
            if (context == .window) {
                surfaceInit(p.rt_surface.gobj(), self);
            }
            tab.setParentWithContext(p, context);
        }
        const config = if (priv.config) |v| v.get() else {
            return tab_view.append(tab.as(gtk.Widget));
        };
        const position = switch (config.@"window-new-tab-position") {
            .current => current: {
                const selected = tab_view.getSelectedPage() orelse
                    break :current tab_view.getNPages();
                const current = tab_view.getPagePosition(selected);
                break :current current + 1;
            },
            .end => tab_view.getNPages(),
        };
        const page = tab_view.insert(tab.as(gtk.Widget), position);
        tab_view.setSelectedPage(page);
        _ = tab.as(gobject.Object).bindProperty(
            "title",
            page.as(gobject.Object),
            "title",
            .{ .sync_create = true },
        );
        _ = tab.as(gobject.Object).bindProperty(
            "tooltip",
            page.as(gobject.Object),
            "tooltip",
            .{ .sync_create = true },
        );
        return page;
    }
    pub const SelectTab = union(enum) {
        previous,
        next,
        last,
        n: usize,
    };
    pub fn selectTab(self: *Self, n: SelectTab) bool {
        const priv = self.private();
        const tab_view = priv.tab_view;
        const selected = tab_view.getSelectedPage() orelse return false;
        const current = tab_view.getPagePosition(selected);
        const total = tab_view.getNPages();
        const goto: c_int = switch (n) {
            .previous => if (current > 0)
                current - 1
            else
                total - 1,
            .next => if (current < total - 1)
                current + 1
            else
                0,
            .last => total - 1,
            .n => |v| n: {
                if (v == 0) return false;
                const n_int = std.math.cast(
                    c_int,
                    v,
                ) orelse return false;
                break :n @min(n_int - 1, total - 1);
            },
        };
        assert(goto >= 0);
        assert(goto < total);
        if (goto == current) return false;
        const page = tab_view.getNthPage(goto);
        tab_view.setSelectedPage(page);
        return true;
    }
    pub fn moveTab(
        self: *Self,
        surface: *Surface,
        amount: isize,
    ) bool {
        const priv = self.private();
        const tab_view = priv.tab_view;
        const total = tab_view.getNPages();
        if (total == 1) return false;
        const tab = ext.getAncestor(
            Tab,
            surface.as(gtk.Widget),
        ) orelse return false;
        const page = tab_view.getPage(tab.as(gtk.Widget));
        const pos = tab_view.getPagePosition(page);
        const desired_pos: c_int = desired: {
            const initial: c_int = @intCast(pos + amount);
            const max = total - 1;
            break :desired if (initial < 0)
                max + initial + 1
            else if (initial > max)
                initial - max - 1
            else
                initial;
        };
        assert(desired_pos >= 0);
        assert(desired_pos < total);
        return tab_view.reorderPage(page, desired_pos) != 0;
    }
    pub fn moveTabToNewWindow(self: *Self, surface: *Surface) bool {
        const tab_view = self.private().tab_view;
        const tab = ext.getAncestor(
            Tab,
            surface.as(gtk.Widget),
        ) orelse return false;
        const page = tab_view.getPage(tab.as(gtk.Widget));
        if (tab_view.getNPages() <= 1) return false;
        const app = Application.default();
        const window = Window.new(app, .none);
        tab_view.transferPage(
            page,
            window.private().tab_view,
            0,
        );
        window.as(gtk.Window).present();
        return true;
    }
    pub fn toggleTabOverview(self: *Self) void {
        const priv = self.private();
        const tab_overview = priv.tab_overview;
        const is_open = tab_overview.getOpen() != 0;
        tab_overview.setOpen(@intFromBool(!is_open));
    }
    pub fn toggleVisibility(self: *Self) void {
        const widget = self.as(gtk.Widget);
        widget.setVisible(@intFromBool(widget.isVisible() == 0));
    }
    fn syncAppearance(self: *Self) void {
        const priv = self.private();
        const widget = self.as(gtk.Widget);
        {
            inline for (&.{
                "ssd",
                "csd",
                "solid-csd",
                "no-border-radius",
            }) |class|
                widget.removeCssClass(class);
            const csd_enabled = priv.winproto.clientSideDecorationEnabled();
            self.as(gtk.Window).setDecorated(@intFromBool(csd_enabled));
            if (csd_enabled) {
                const display = widget.getDisplay();
                if (display.isRgba() != 0 and display.isComposited() != 0) {
                    widget.addCssClass("csd");
                } else {
                    widget.addCssClass("solid-csd");
                }
            } else {
                widget.addCssClass("ssd");
                widget.addCssClass("no-border-radius");
            }
        }
        inline for (&.{
            "headerbar-visible",
            "tabs-autohide",
            "tabs-inverted",
            "tabs-visible",
            "tabs-wide",
            "toolbar-style",
            "titlebar-style",
        }) |key| {
            self.as(gobject.Object).notifyByPspec(
                @field(properties, key).impl.param_spec,
            );
        }
        const config = if (priv.config) |v| v.get() else return;
        self.toggleCssClass(
            "background",
            config.@"background-opacity" >= 1,
        );
        priv.toolbar.remove(priv.tab_bar.as(gtk.Widget));
        switch (config.@"gtk-tabs-location") {
            .top => priv.toolbar.addTopBar(priv.tab_bar.as(gtk.Widget)),
            .bottom => priv.toolbar.addBottomBar(priv.tab_bar.as(gtk.Widget)),
        }
        priv.winproto.syncAppearance() catch |err| {
            log.warn("failed to sync winproto appearance error={}", .{err});
        };
    }
    fn syncActions(self: *Self) void {
        const has_selection = selection: {
            const surface = self.getActiveSurface() orelse
                break :selection false;
            const core_surface = surface.core() orelse
                break :selection false;
            break :selection core_surface.hasSelection();
        };
        const action_map: *gio.ActionMap = gobject.ext.cast(
            gio.ActionMap,
            self,
        ) orelse return;
        const action: *gio.SimpleAction = gobject.ext.cast(
            gio.SimpleAction,
            action_map.lookupAction("copy") orelse return,
        ) orelse return;
        action.setEnabled(@intFromBool(has_selection));
    }
    fn toggleCssClass(self: *Self, class: [:0]const u8, value: bool) void {
        const widget = self.as(gtk.Widget);
        if (value)
            widget.addCssClass(class.ptr)
        else
            widget.removeCssClass(class.ptr);
    }
    fn performBindingAction(
        self: *Self,
        action: input.Binding.Action,
    ) void {
        const surface = self.getActiveSurface() orelse return;
        const core_surface = surface.core() orelse return;
        _ = core_surface.performBindingAction(action) catch |err| {
            log.warn("error performing binding action error={}", .{err});
            return;
        };
    }
    fn addToast(self: *Self, title: [*:0]const u8) void {
        const toast = adw.Toast.new(title);
        toast.setTimeout(3);
        self.private().toast_overlay.addToast(toast);
    }
    fn connectSurfaceHandlers(
        self: *Self,
        tree: *const Surface.Tree,
    ) void {
        const priv = self.private();
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
            _ = Surface.signals.@"present-request".connect(
                surface,
                *Self,
                surfacePresentRequest,
                self,
                .{},
            );
            _ = Surface.signals.@"clipboard-write".connect(
                surface,
                *Self,
                surfaceClipboardWrite,
                self,
                .{},
            );
            _ = Surface.signals.menu.connect(
                surface,
                *Self,
                surfaceMenu,
                self,
                .{},
            );
            _ = Surface.signals.@"toggle-fullscreen".connect(
                surface,
                *Self,
                surfaceToggleFullscreen,
                self,
                .{},
            );
            _ = Surface.signals.@"toggle-maximize".connect(
                surface,
                *Self,
                surfaceToggleMaximize,
                self,
                .{},
            );
            if (!priv.surface_init) {
                _ = Surface.signals.init.connect(
                    surface,
                    *Self,
                    surfaceInit,
                    self,
                    .{},
                );
            }
        }
    }
    fn disconnectSurfaceHandlers(
        self: *Self,
        tree: *const Surface.Tree,
    ) void {
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
    fn handleActiveState(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        priv.handle_active_state_source = null;
        if (self.isQuickTerminal()) {
            if (self.getConfig()) |cfg| {
                if (cfg.get().@"quick-terminal-autohide" and
                    self.as(gtk.Window).isActive() == 0 and
                    self.as(gtk.Widget).isVisible() == 1)
                {
                    self.toggleVisibility();
                }
            }
        }
        if (self.as(gtk.Window).isActive() == 0) return 0;
        self.winproto().setUrgent(false) catch |err| {
            log.warn(
                "winproto failed to reset urgency={}",
                .{err},
            );
        };
        return 0;
    }
    pub fn isQuickTerminal(self: *Self) bool {
        return self.private().quick_terminal;
    }
    pub fn getActiveSurface(self: *Self) ?*Surface {
        const tab = self.getSelectedTab() orelse return null;
        return tab.getActiveSurface();
    }
    pub fn getConfig(self: *Self) ?*Config {
        return self.private().config;
    }
    pub fn getTabView(self: *Self) *adw.TabView {
        return self.private().tab_view;
    }
    pub fn getWindowDecoration(self: *Self) configpkg.WindowDecoration {
        const priv = self.private();
        if (priv.window_decoration) |v| return v;
        if (priv.config) |v| return v.get().@"window-decoration";
        return .auto;
    }
    pub fn resizeSurface(
        self: *Self,
        surface: *Surface,
        size: apprt.action.ResizeWindow,
    ) bool {
        if (self.isQuickTerminal() or
            self.isMaximized() or
            self.isFullscreen() or
            self.isTiled()) return false;
        if (self.getTabView().getNPages() != 1) return false;
        const tree = ext.getAncestor(
            SplitTree,
            surface.as(gtk.Widget),
        ) orelse return false;
        if (tree.getIsSplit()) return false;
        const scale = surface.getContentScale();
        const current = surface.getSize();
        const factor: f32 = @floatFromInt(self.as(gtk.Widget).getScaleFactor());
        const dw = resizeDelta(size.width, scale.x, current.width, factor);
        const dh = resizeDelta(size.height, scale.y, current.height, factor);
        const widget = self.as(gtk.Widget);
        self.private().resize_requested = true;
        self.as(gtk.Window).setDefaultSize(
            widget.getWidth() + dw,
            widget.getHeight() + dh,
        );
        return true;
    }
    fn resizeDelta(requested: u32, scale: f32, current: u32, factor: f32) c_int {
        if (requested == 0) return 0;
        const px = @as(f32, @floatFromInt(requested)) * scale;
        return @intFromFloat(@round((px - @as(f32, @floatFromInt(current))) / factor));
    }
    pub fn toggleWindowDecorations(self: *Self) void {
        const priv = self.private();
        if (priv.window_decoration) |_| {
            self.setWindowDecoration(null);
            return;
        }
        const config = if (priv.config) |v| v.get() else return;
        self.setWindowDecoration(switch (config.@"window-decoration") {
            .none => .auto,
            .auto, .client, .server => .none,
        });
    }
    fn setWindowDecoration(
        self: *Self,
        new_: ?configpkg.WindowDecoration,
    ) void {
        const priv = self.private();
        priv.window_decoration = new_;
        self.syncAppearance();
    }
    fn getSelectedTab(self: *Self) ?*Tab {
        const priv = self.private();
        const page = priv.tab_view.getSelectedPage() orelse return null;
        const child = page.getChild();
        assert(gobject.ext.isA(child, Tab));
        return gobject.ext.cast(Tab, child);
    }
    fn getNeedsConfirmQuit(self: *Self) bool {
        const priv = self.private();
        const n = priv.tab_view.getNPages();
        assert(n >= 0);
        for (0..@intCast(n)) |i| {
            const page = priv.tab_view.getNthPage(@intCast(i));
            const child = page.getChild();
            const tab = gobject.ext.cast(Tab, child) orelse {
                log.warn("unexpected non-Tab child in tab view", .{});
                continue;
            };
            if (tab.getNeedsConfirmQuit()) return true;
        }
        return false;
    }
    fn isFullscreen(self: *Window) bool {
        return self.as(gtk.Window).isFullscreen() != 0;
    }
    fn isMaximized(self: *Window) bool {
        return self.as(gtk.Window).isMaximized() != 0;
    }
    fn isTiled(self: *Window) bool {
        const surface = self.as(gtk.Native).getSurface() orelse return false;
        const toplevel = gobject.ext.cast(gdk.Toplevel, surface) orelse return false;
        return toplevel.getState().tiled;
    }
    fn getHeaderbarVisible(self: *Self) bool {
        const priv = self.private();
        const csd_enabled = priv.winproto.clientSideDecorationEnabled();
        if (!csd_enabled) return false;
        if (priv.quick_terminal) return false;
        if (self.isFullscreen()) return false;
        const config_obj = self.private().config orelse return true;
        const config = config_obj.get();
        if (self.isMaximized() and config.@"gtk-titlebar-hide-when-maximized") {
            return false;
        }
        return switch (config.@"gtk-titlebar-style") {
            .tabs => false,
            .native => config.@"gtk-titlebar",
        };
    }
    fn getTabsAutohide(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return true;
        return switch (config.@"gtk-titlebar-style") {
            .tabs => false,
            .native => switch (config.@"window-show-tab-bar") {
                .auto => true,
                .always => false,
                .never => true,
            },
        };
    }
    fn getTabsVisible(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return true;
        switch (config.@"gtk-titlebar-style") {
            .tabs => {
                if (self.isMaximized() and config.@"gtk-titlebar-hide-when-maximized") return false;
                return true;
            },
            .native => {
                return switch (config.@"window-show-tab-bar") {
                    .always, .auto => true,
                    .never => false,
                };
            },
        }
    }
    fn getTabsInverted(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return false;
        return config.@"gtk-tabs-inverted";
    }
    fn getTabsWide(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return true;
        return config.@"gtk-wide-tabs";
    }
    fn getToolbarStyle(self: *Self) adw.ToolbarStyle {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return .raised;
        return switch (config.@"gtk-toolbar-style") {
            .flat => .flat,
            .raised => .raised,
            .@"raised-border" => .raised_border,
        };
    }
    fn getTitlebarStyle(self: *Self) TitlebarStyle {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return .native;
        return config.@"gtk-titlebar-style";
    }
    fn propConfig(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.config) |config_obj| {
            const config = config_obj.get();
            if (config.@"app-notifications".@"config-reload") {
                self.addToast(i18n._("Reloaded the configuration"));
            }
        }
        self.syncAppearance();
    }
    fn propIsActive(
        _: *gtk.Window,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.handle_active_state_source == null) {
            priv.handle_active_state_source = glib.timeoutAddFull(
                glib.PRIORITY_DEFAULT_IDLE,
                50,
                handleActiveState,
                self,
                null,
            );
        }
    }
    fn propGdkSurfaceDims(
        _: *gdk.Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.private().winproto.resizeEvent() catch |err| {
            log.warn(
                "winproto resize event failed error={}",
                .{err},
            );
        };
    }
    fn toplevelComputeSize(
        _: *gdk.Toplevel,
        size: *gdk.ToplevelSize,
        self: *Self,
    ) callconv(.c) void {
        if (self.isMaximized() or
            self.isFullscreen() or
            self.isQuickTerminal()) return;
        const priv = self.private();
        if (priv.resize_requested) {
            priv.resize_requested = false;
            return;
        }
        const gdk_surface = self.as(gtk.Native).getSurface() orelse return;
        const w = gdk_surface.getWidth();
        const h = gdk_surface.getHeight();
        if (w <= 0 or h <= 0) return;
        var bounds_w: c_int = undefined;
        var bounds_h: c_int = undefined;
        size.getBounds(&bounds_w, &bounds_h);
        if (bounds_w <= 0 or bounds_h <= 0) return;
        if (w <= bounds_w and h <= bounds_h) return;
        size.setSize(w, h);
    }
    fn propFullscreened(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncAppearance();
    }
    fn propMaximized(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncAppearance();
    }
    fn propMenuActive(
        button: *gtk.MenuButton,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const active = button.getActive() != 0;
        if (!active) return;
        self.syncActions();
    }
    fn propQuickTerminal(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.surface_init) {
            log.warn("quick terminal property can't be changed after surfaces have been initialized", .{});
            return;
        }
        if (priv.quick_terminal) {
            Application.default().winproto().initQuickTerminal(self) catch |err| {
                log.warn("failed to initialize quick terminal error={}", .{err});
                return;
            };
        }
    }
    fn propScaleFactor(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.private().winproto.syncAppearance() catch |err| {
            log.warn(
                "failed to sync appearance after scale factor has been updated={}",
                .{err},
            );
            return;
        };
    }
    fn closureTitlebarStyleIsTab(
        _: *Self,
        value: TitlebarStyle,
    ) callconv(.c) c_int {
        return @intFromBool(switch (value) {
            .native => false,
            .tabs => true,
        });
    }
    pub fn setTitleOverride(self: *Self, title: ?[]const u8) void {
        const priv: *Private = self.private();
        if (priv.title_override) |v| glib.free(@ptrCast(@constCast(v)));
        priv.title_override = null;
        if (title) |v| priv.title_override = glib.ext.dupeZ(u8, v);
        self.as(gobject.Object).notifyByPspec(properties.@"title-override".impl.param_spec);
    }
    fn titleDialogSet(_: *TitleDialog, title_: [*:0]const u8, self: *Self) callconv(.c) void {
        const title = std.mem.span(title_);
        self.setTitleOverride(if (title.len == 0) null else title);
    }
    pub fn promptWindowTitle(self: *Self) void {
        const priv: *Private = self.private();
        var value = std.mem.zeroes(gobject.Value);
        _ = value.init(gobject.ext.types.string);
        defer value.unset();
        self.as(gobject.Object).getProperty("title", &value);
        const title_: ?[*:0]const u8 = value.getString();
        const title: ?[:0]const u8 = if (title_) |v| std.mem.span(v) else null;
        const dialog = TitleDialog.new(.window, priv.title_override orelse title);
        _ = TitleDialog.signals.set.connect(
            dialog,
            *Self,
            titleDialogSet,
            self,
            .{},
        );
        dialog.present(self.as(gtk.Widget));
    }
    fn closureTitle(
        _: *Self,
        _: ?*Config,
        title_: ?[*:0]const u8,
        title_override_: ?[*:0]const u8,
    ) callconv(.c) ?[*:0]const u8 {
        if (title_override_) |v| return glib.ext.dupeZ(u8, std.mem.span(v));
        if (title_) |v| return glib.ext.dupeZ(u8, std.mem.span(v));
        return glib.ext.dupeZ(u8, "Wasp");
    }
    fn closureSubtitle(
        _: *Self,
        config_: ?*Config,
        pwd_: ?[*:0]const u8,
    ) callconv(.c) ?[*:0]const u8 {
        const config = if (config_) |v| v.get() else return null;
        return switch (config.@"window-subtitle") {
            .false => null,
            .@"working-directory" => pwd: {
                const pwd = pwd_ orelse return null;
                break :pwd glib.ext.dupeZ(u8, std.mem.span(pwd));
            },
        };
    }
    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.handle_active_state_source) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove handle active state source", .{});
            }
            priv.handle_active_state_source = null;
        }
        priv.command_palette.deinit();
        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }
        priv.tab_bindings.setSource(null);
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
        priv.tab_bindings.unref();
        priv.winproto.deinit();
        if (priv.title_override) |v| glib.free(@ptrCast(@constCast(v)));
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }
    fn windowRealize(_: *gtk.Widget, self: *Window) callconv(.c) void {
        const app = Application.default();
        if (winprotopkg.Window.init(
            app.allocator(),
            app.winproto(),
            self,
        )) |wp| {
            self.private().winproto = wp;
        } else |err| {
            log.warn("failed to initialize window protocol error={}", .{err});
            return;
        }
        if (self.as(gtk.Native).getSurface()) |gdk_surface| {
            _ = gobject.Object.signals.notify.connect(
                gdk_surface,
                *Self,
                propGdkSurfaceDims,
                self,
                .{ .detail = "width" },
            );
            _ = gobject.Object.signals.notify.connect(
                gdk_surface,
                *Self,
                propGdkSurfaceDims,
                self,
                .{ .detail = "height" },
            );
            if (gobject.ext.cast(gdk.Toplevel, gdk_surface)) |toplevel| {
                _ = gdk.Toplevel.signals.compute_size.connect(
                    toplevel,
                    *Self,
                    toplevelComputeSize,
                    self,
                    .{ .after = true },
                );
            }
        }
        _ = gobject.Object.signals.notify.connect(
            self.as(gtk.Window),
            *Self,
            propSuspended,
            self,
            .{ .detail = "suspended" },
        );
        self.syncAppearance();
    }
    fn propSuspended(
        _: *gtk.Window,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const tab = self.getSelectedTab() orelse return;
        const tree = tab.getSurfaceTree() orelse return;
        var it = tree.iterator();
        while (it.next()) |entry| entry.view.updateOcclusion();
    }
    fn btnNewTab(_: *adw.SplitButton, self: *Self) callconv(.c) void {
        self.performBindingAction(.new_tab);
    }
    fn tabOverviewCreateTab(
        _: *adw.TabOverview,
        self: *Self,
    ) callconv(.c) *adw.TabPage {
        return self.newTabPage(if (self.getActiveSurface()) |v| v.core() else null, .tab, .none);
    }
    fn tabOverviewOpen(
        tab_overview: *adw.TabOverview,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        if (tab_overview.getOpen() != 0) return;
        const priv = self.private();
        if (priv.tab_overview_focus_timer) |timer| {
            _ = glib.Source.remove(timer);
        }
        priv.tab_overview_focus_timer = glib.timeoutAdd(
            500,
            tabOverviewFocusTimer,
            self,
        );
    }
    fn tabOverviewFocusTimer(
        ud: ?*anyopaque,
    ) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        self.private().tab_overview_focus_timer = null;
        const surface = self.getActiveSurface() orelse return 0;
        surface.grabFocus();
        return 0;
    }
    fn windowCloseRequest(
        _: *gtk.Window,
        self: *Self,
    ) callconv(.c) c_int {
        if (self.getNeedsConfirmQuit()) {
            const dialog: *CloseConfirmationDialog = .new(.window);
            _ = CloseConfirmationDialog.signals.@"close-request".connect(
                dialog,
                *Self,
                closeConfirmationClose,
                self,
                .{},
            );
            dialog.present(self.as(gtk.Widget));
            return @intFromBool(true);
        }
        self.as(gtk.Window).destroy();
        return @intFromBool(false);
    }
    fn closeConfirmationClose(
        _: *CloseConfirmationDialog,
        self: *Self,
    ) callconv(.c) void {
        self.as(gtk.Window).destroy();
    }
    fn closeConfirmationCloseTab(
        _: *CloseConfirmationDialog,
        page: *adw.TabPage,
    ) callconv(.c) void {
        const tab_view = ext.getAncestor(
            adw.TabView,
            page.getChild().as(gtk.Widget),
        ) orelse {
            log.warn("close confirmation called for non-existent page", .{});
            return;
        };
        tab_view.closePageFinish(page, @intFromBool(true));
    }
    fn closeConfirmationCancelTab(
        _: *CloseConfirmationDialog,
        page: *adw.TabPage,
    ) callconv(.c) void {
        const tab_view = ext.getAncestor(
            adw.TabView,
            page.getChild().as(gtk.Widget),
        ) orelse {
            log.warn("close confirmation called for non-existent page", .{});
            return;
        };
        tab_view.closePageFinish(page, @intFromBool(false));
    }
    fn tabViewClosePage(
        _: *adw.TabView,
        page: *adw.TabPage,
        self: *Self,
    ) callconv(.c) c_int {
        const priv = self.private();
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse
            return @intFromBool(false);
        if (!tab.getNeedsConfirmQuit()) {
            priv.tab_view.closePageFinish(page, @intFromBool(true));
            return @intFromBool(true);
        }
        const dialog: *CloseConfirmationDialog = .new(.tab);
        _ = CloseConfirmationDialog.signals.@"close-request".connect(
            dialog,
            *adw.TabPage,
            closeConfirmationCloseTab,
            page,
            .{},
        );
        _ = CloseConfirmationDialog.signals.cancel.connect(
            dialog,
            *adw.TabPage,
            closeConfirmationCancelTab,
            page,
            .{},
        );
        dialog.present(child);
        return @intFromBool(true);
    }
    fn tabViewSelectedPage(
        _: *adw.TabView,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.tab_bindings.setSource(null);
        const page = priv.tab_view.getSelectedPage() orelse return;
        const child = page.getChild();
        assert(gobject.ext.isA(child, Tab));
        priv.tab_bindings.setSource(child.as(gobject.Object));
        page.setNeedsAttention(@intFromBool(false));
    }
    fn tabViewPageAttached(
        _: *adw.TabView,
        page: *adw.TabPage,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;
        _ = Tab.signals.@"close-request".connect(
            tab,
            *Self,
            tabCloseRequest,
            self,
            .{},
        );
        if (tab.getSurfaceTree()) |tree| {
            self.connectSurfaceHandlers(tree);
        }
        _ = SplitTree.signals.changed.connect(
            tab.getSplitTree(),
            *Self,
            tabSplitTreeChanged,
            self,
            .{},
        );
    }
    fn tabViewPageDetached(
        _: *adw.TabView,
        page: *adw.TabPage,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;
        _ = gobject.signalHandlersDisconnectMatched(
            tab.as(gobject.Object),
            .{ .data = true },
            0,
            0,
            null,
            null,
            self,
        );
        _ = gobject.signalHandlersDisconnectMatched(
            tab.getSplitTree().as(gobject.Object),
            .{ .data = true },
            0,
            0,
            null,
            null,
            self,
        );
        if (tab.getSurfaceTree()) |tree| {
            self.disconnectSurfaceHandlers(tree);
        }
    }
    fn tabViewCreateWindow(
        _: *adw.TabView,
        _: *Self,
    ) callconv(.c) *adw.TabView {
        const win = gobject.ext.newInstance(
            Self,
            .{
                .application = Application.default(),
            },
        );
        gtk.Window.present(win.as(gtk.Window));
        return win.private().tab_view;
    }
    fn tabCloseRequest(
        tab: *Tab,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const page = priv.tab_view.getPage(tab.as(gtk.Widget));
        priv.tab_view.closePage(page);
    }
    fn tabViewNPages(
        _: *adw.TabView,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.tab_view.getNPages() == 0) {
            if (priv.tab_overview.getOpen() != 0) return;
            self.as(gtk.Window).close();
        }
    }
    fn setupTabMenu(
        _: *adw.TabView,
        page: ?*adw.TabPage,
        self: *Self,
    ) callconv(.c) void {
        self.private().context_menu_page = page;
    }
    fn surfaceClipboardWrite(
        _: *Surface,
        clipboard_type: apprt.Clipboard,
        text: [*:0]const u8,
        self: *Self,
    ) callconv(.c) void {
        if (clipboard_type != .standard) return;
        const priv = self.private();
        const config_obj = priv.config orelse return;
        const config = config_obj.get();
        if (!config.@"app-notifications".@"clipboard-copy") {
            return;
        }
        if (text[0] != 0)
            self.addToast(i18n._("Copied to clipboard"))
        else
            self.addToast(i18n._("Cleared clipboard"));
    }
    fn surfaceMenu(
        _: *Surface,
        self: *Self,
    ) callconv(.c) void {
        self.syncActions();
    }
    fn surfacePresentRequest(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        {
            const surface_window = ext.getAncestor(
                Self,
                surface.as(gtk.Widget),
            ) orelse {
                log.warn(
                    "present request called for non-existent surface",
                    .{},
                );
                return;
            };
            if (surface_window != self) {
                log.warn(
                    "present request called for surface in different window",
                    .{},
                );
                return;
            }
        }
        const tab = ext.getAncestor(
            Tab,
            surface.as(gtk.Widget),
        ) orelse {
            log.warn("present request surface not found", .{});
            return;
        };
        const priv = self.private();
        const tab_view = priv.tab_view;
        const page = tab_view.getPage(tab.as(gtk.Widget));
        tab_view.setSelectedPage(page);
        surface.grabFocus();
        self.as(gtk.Window).present();
    }
    fn surfaceToggleFullscreen(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        _ = surface;
        if (self.as(gtk.Window).isFullscreen() != 0) {
            self.as(gtk.Window).unfullscreen();
        } else {
            self.as(gtk.Window).fullscreen();
        }
    }
    fn surfaceToggleMaximize(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        _ = surface;
        if (self.as(gtk.Window).isMaximized() != 0) {
            self.as(gtk.Window).unmaximize();
        } else {
            self.as(gtk.Window).maximize();
        }
    }
    fn surfaceInit(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.surface_init) return;
        priv.surface_init = true;
        if (surface.getDefaultSize()) |size| {
            self.as(gtk.Window).setDefaultSize(
                @intCast(size.width),
                @intCast(size.height),
            );
        }
        if (surface.getMinSize()) |size| {
            self.as(gtk.Widget).setSizeRequest(
                @intCast(size.width),
                @intCast(size.height),
            );
        }
    }
    fn tabSplitTreeChanged(
        _: *SplitTree,
        old_tree: ?*const Surface.Tree,
        new_tree: ?*const Surface.Tree,
        self: *Self,
    ) callconv(.c) void {
        if (old_tree) |tree| {
            self.disconnectSurfaceHandlers(tree);
        }
        if (new_tree) |tree| {
            self.connectSurfaceHandlers(tree);
        }
    }
    fn actionAbout(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const name = "Wasp";
        const icon = "com.mitchellh.wasp";
        const website = "https://wasp.org";
        adw.showAboutDialog(
            self.as(gtk.Widget),
            "application-name",
            name,
            "developer-name",
            i18n._("Wasp Developers"),
            "application-icon",
            icon,
            "version",
            build_config.version_string.ptr,
            "issue-url",
            "https://github.com/wasp-org/wasp/issues",
            "website",
            website,
            @as(?*anyopaque, null),
        );
    }
    fn actionClose(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        self.as(gtk.Window).close();
    }
    fn actionCloseTab(
        _: *gio.SimpleAction,
        param_: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        const param = param_ orelse {
            log.warn("win.close-tab called without a parameter", .{});
            return;
        };
        var str: ?[*:0]const u8 = null;
        param.get("&s", &str);
        const mode = std.meta.stringToEnum(
            input.Binding.Action.CloseTabMode,
            std.mem.span(
                str orelse {
                    log.warn("invalid mode provided to win.close-tab", .{});
                    return;
                },
            ),
        ) orelse {
            log.warn("invalid mode provided to win.close-tab: {s}", .{str.?});
            return;
        };
        self.performBindingAction(.{ .close_tab = mode });
    }
    fn actionNewWindow(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.new_window);
    }
    fn actionNewTab(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.new_tab);
    }
    fn actionPromptContextTabTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const page = priv.context_menu_page orelse return;
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;
        tab.promptTabTitle();
    }
    fn actionPromptSurfaceTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.prompt_surface_title);
    }
    fn actionPromptTabTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.prompt_tab_title);
    }
    fn actionPromptWindowTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.prompt_window_title);
    }
    fn actionSplitRight(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .right });
    }
    fn actionSplitLeft(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .left });
    }
    fn actionSplitUp(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .up });
    }
    fn actionSplitDown(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .down });
    }
    fn actionCopy(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .copy_to_clipboard = .mixed });
    }
    fn actionPaste(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.paste_from_clipboard);
    }
    fn actionReset(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.reset);
    }
    fn actionClear(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.clear_screen);
    }
    fn actionRingBell(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return;
        if (config.@"bell-features".system) system: {
            const native = self.as(gtk.Native).getSurface() orelse {
                log.warn("unable to get native surface from window", .{});
                break :system;
            };
            native.beep();
        }
        if (config.@"bell-features".attention) attention: {
            if (self.as(gtk.Window).isActive() != 0) break :attention;
            self.winproto().setUrgent(true) catch |err| {
                log.warn("winproto failed to set urgency={}", .{err});
            };
        }
    }
    fn toggleCommandPalette(self: *Window) void {
        const priv = self.private();
        const command_palette = priv.command_palette.get() orelse command_palette: {
            const command_palette = CommandPalette.new();
            _ = gobject.Object.bindProperty(
                self.as(gobject.Object),
                "config",
                command_palette.as(gobject.Object),
                "config",
                .{ .sync_create = true },
            );
            _ = CommandPalette.signals.trigger.connect(
                command_palette,
                *Window,
                signalCommandPaletteTrigger,
                self,
                .{},
            );
            priv.command_palette.set(command_palette);
            break :command_palette command_palette;
        };
        defer command_palette.unref();
        command_palette.toggle(self);
    }
    fn signalCommandPaletteTrigger(_: *CommandPalette, action: *const input.Binding.Action, self: *Self) callconv(.c) void {
        self.performBindingAction(action.*);
    }
    fn actionToggleCommandPalette(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.toggleCommandPalette();
    }
    fn toggleInspector(self: *Self) void {
        const surface = self.getActiveSurface() orelse return;
        _ = surface.controlInspector(.toggle);
    }
    fn actionToggleInspector(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.toggleInspector();
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
            gobject.ext.ensureType(DebugWarning);
            gobject.ext.ensureType(SplitTree);
            gobject.ext.ensureType(Surface);
            gobject.ext.ensureType(Tab);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 4,
                    .name = "window",
                }),
            );
            gobject.ext.registerProperties(class, &.{
                properties.@"active-surface".impl,
                properties.config.impl,
                properties.debug.impl,
                properties.@"headerbar-visible".impl,
                properties.@"quick-terminal".impl,
                properties.@"tabs-autohide".impl,
                properties.@"tabs-inverted".impl,
                properties.@"tabs-visible".impl,
                properties.@"tabs-wide".impl,
                properties.@"toolbar-style".impl,
                properties.@"titlebar-style".impl,
                properties.@"title-override".impl,
            });
            class.bindTemplateChildPrivate("tab_overview", .{});
            class.bindTemplateChildPrivate("tab_bar", .{});
            class.bindTemplateChildPrivate("tab_view", .{});
            class.bindTemplateChildPrivate("toolbar", .{});
            class.bindTemplateChildPrivate("toast_overlay", .{});
            class.bindTemplateCallback("realize", &windowRealize);
            class.bindTemplateCallback("new_tab", &btnNewTab);
            class.bindTemplateCallback("overview_create_tab", &tabOverviewCreateTab);
            class.bindTemplateCallback("overview_notify_open", &tabOverviewOpen);
            class.bindTemplateCallback("close_request", &windowCloseRequest);
            class.bindTemplateCallback("close_page", &tabViewClosePage);
            class.bindTemplateCallback("page_attached", &tabViewPageAttached);
            class.bindTemplateCallback("page_detached", &tabViewPageDetached);
            class.bindTemplateCallback("setup_tab_menu", &setupTabMenu);
            class.bindTemplateCallback("tab_create_window", &tabViewCreateWindow);
            class.bindTemplateCallback("notify_n_pages", &tabViewNPages);
            class.bindTemplateCallback("notify_selected_page", &tabViewSelectedPage);
            class.bindTemplateCallback("notify_config", &propConfig);
            class.bindTemplateCallback("notify_fullscreened", &propFullscreened);
            class.bindTemplateCallback("notify_is_active", &propIsActive);
            class.bindTemplateCallback("notify_maximized", &propMaximized);
            class.bindTemplateCallback("notify_menu_active", &propMenuActive);
            class.bindTemplateCallback("notify_quick_terminal", &propQuickTerminal);
            class.bindTemplateCallback("notify_scale_factor", &propScaleFactor);
            class.bindTemplateCallback("titlebar_style_is_tabs", &closureTitlebarStyleIsTab);
            class.bindTemplateCallback("computed_title", &closureTitle);
            class.bindTemplateCallback("computed_subtitle", &closureSubtitle);
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
