const builtin = @import("builtin");
const std = @import("std");
const assert = @import("../../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const glibunix = @import("glibunix");
const gobject = @import("gobject");
const gtk = @import("gtk");
const build_config = @import("../../../build_config.zig");
const build_info = @import("../build/info.zig");
const cli = @import("../../../cli.zig");
const global = @import("../../../global.zig");
const i18n = @import("../../../os/root.zig").i18n;
const apprt = @import("../../../apprt.zig");
const CoreApp = @import("../../../App.zig");
const compat_file = @import("../../../lib/compat/file.zig");
const configpkg = @import("../../../config.zig");
const input = @import("../../../input.zig");
const internal_os = @import("../../../os/root.zig");
const systemd = @import("../../../os/systemd.zig");
const terminal = @import("../../../terminal/main.zig");
const xev = global.xev;
const Binding = @import("../../../input.zig").Binding;
const CoreConfig = configpkg.Config;
const CoreSurface = @import("../../../Surface.zig");
const ext = @import("../ext.zig");
const key = @import("../key.zig");
const adw_version = @import("../adw_version.zig");
const gtk_version = @import("../gtk_version.zig");
const winprotopkg = @import("../winproto.zig");
const ApprtApp = @import("../App.zig");
const Common = @import("../class.zig").Common;
const WeakRef = @import("../weak_ref.zig").WeakRef;
const Config = @import("config.zig").Config;
const Surface = @import("surface.zig").Surface;
const SplitTree = @import("split_tree.zig").SplitTree;
const Window = @import("window.zig").Window;
const Tab = @import("tab.zig").Tab;
const CloseConfirmationDialog = @import("close_confirmation_dialog.zig").CloseConfirmationDialog;
const ConfigErrorsDialog = @import("config_errors_dialog.zig").ConfigErrorsDialog;
const GlobalShortcuts = @import("global_shortcuts.zig").GlobalShortcuts;
const OpenURI = @import("../portal.zig").OpenURI;
const media = @import("../media.zig");
const Overrides = @import("Overrides.zig");
const log = std.log.scoped(.gtk_wasp_application);
extern "c" fn setenv(name: ?[*]const u8, value: ?[*]const u8, overwrite: c_int) c_int;
fn glibLogWriterFunction(
    level: glib.LogLevelFlags,
    fields: [*]const glib.LogField,
    n_fields: usize,
    _: ?*anyopaque,
) callconv(.c) glib.LogWriterOutput {
    const glib_log = std.log.scoped(.glib);
    var message_: ?[]const u8 = null;
    var domain_: ?[]const u8 = null;
    for (0..n_fields) |i| {
        const field = fields[i];
        const k = std.mem.span(field.f_key orelse continue);
        const v: []const u8 = v: {
            if (field.f_length >= 0) {
                const v: [*]const u8 = @ptrCast(field.f_value orelse continue);
                break :v v[0..@intCast(field.f_length)];
            }
            const v: [*:0]const u8 = @ptrCast(field.f_value orelse continue);
            break :v std.mem.span(v);
        };
        if (std.mem.eql(u8, k, "MESSAGE")) {
            message_ = v;
            continue;
        }
        if (std.mem.eql(u8, k, "GLIB_DOMAIN")) {
            domain_ = v;
            continue;
        }
    }
    const message = message_ orelse return .unhandled;
    const domain = domain_ orelse "«unknown»";
    if (level.level_error) {
        glib_log.err("ERROR: {s}: {s}", .{ domain, message });
        return .handled;
    }
    if (level.level_critical) {
        glib_log.err("CRITICAL: {s}: {s}", .{ domain, message });
        return .handled;
    }
    if (level.level_warning) {
        glib_log.warn("WARNING: {s}: {s}", .{ domain, message });
        return .handled;
    }
    if (level.level_message) {
        glib_log.info("MESSAGE: {s}: {s}", .{ domain, message });
        return .handled;
    }
    if (level.level_info) {
        glib_log.info("INFO: {s}: {s}", .{ domain, message });
        return .handled;
    }
    if (level.level_debug) {
        glib_log.debug("DEBUG: {s}: {s}", .{ domain, message });
        return .handled;
    }
    glib_log.debug("UNKNOWN: {s}: {s}", .{ domain, message });
    return .handled;
}
pub const Application = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Application;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WaspApplication",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });
    pub const properties = struct {
        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                "config",
                Self,
                ?*Config,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Config,
                        .{
                            .getter = Self.getConfig,
                            .getter_transfer = .full,
                        },
                    ),
                },
            );
        };
    };
    const Private = struct {
        rt_app: *ApprtApp,
        core_app: *CoreApp,
        config: *Config,
        winproto: winprotopkg.App,
        global_shortcuts: *GlobalShortcuts,
        requested_window: bool = false,
        running: bool = false,
        systemd_ready: bool = false,
        quit_timer: union(enum) {
            off,
            active: c_uint,
            expired,
        } = .off,
        config_errors_dialog: WeakRef(ConfigErrorsDialog) = .empty,
        signal_source: ?c_uint = null,
        css_provider: *gtk.CssProvider,
        custom_css_providers: std.ArrayListUnmanaged(*gtk.CssProvider) = .empty,
        saved_language: ?[:0]const u8 = null,
        open_uri: OpenURI = undefined,
        bell_media: ?*gtk.MediaFile = null,
        pub var offset: c_int = 0;
    };
    pub fn default() *Self {
        const app = gio.Application.getDefault().?;
        return gobject.ext.cast(Self, app).?;
    }
    pub fn new(
        rt_app: *ApprtApp,
        core_app: *CoreApp,
    ) (error{ GtkMinimumVersion, AdwaitaMinimumVersion } || Allocator.Error)!*Self {
        const alloc = core_app.alloc;
        _ = glib.logSetWriterFunc(glibLogWriterFunction, null, null);
        try gtk_version.logVersion();
        try adw_version.logVersion();
        var config = CoreConfig.load(alloc) catch |err| err: {
            var def: CoreConfig = try .default(alloc);
            errdefer def.deinit();
            try def.addDiagnosticFmt(
                "error loading user configuration: {}",
                .{err},
            );
            break :err def;
        };
        defer config.deinit();
        const saved_language: ?[:0]const u8 = saved_language: {
            const old_language = old_language: {
                const lang = global.environ().getPosix("LANG") orelse break :old_language null;
                break :old_language alloc.dupeSentinel(u8, @ptrCast(lang), 0) catch null;
            };
            if (config.language) |language| {
                _ = setenv("LANG", @ptrCast(language), 1);
                global.syncEnviron();
            }
            break :saved_language old_language;
        };
        internal_os.i18n.initGlobalDomain() catch |err| {
            log.warn("i18n initialization failed error={}", .{err});
        };
        setGtkEnv(&config) catch |err| switch (err) {
            error.WriteFailed => {
                log.warn(
                    "error setting GTK environment variables err={}",
                    .{err},
                );
            },
        };
        adw.init();
        const single_instance = switch (config.@"gtk-single-instance") {
            .true => true,
            .false => false,
            .detect => unreachable,
        };
        const app_flags: gio.ApplicationFlags = app_flags: {
            var flags: gio.ApplicationFlags = .flags_default_flags;
            if (!single_instance) flags.non_unique = true;
            break :app_flags flags;
        };
        const app_id: [:0]const u8 = app_id: {
            if (config.class) |class| {
                if (gio.Application.idIsValid(class) != 0) {
                    break :app_id class;
                } else {
                    log.warn("invalid 'class' in config, ignoring", .{});
                }
            }
            break :app_id build_info.application_id;
        };
        const display: *gdk.Display = gdk.Display.getDefault() orelse {
            log.warn("gdk display is null, exiting", .{});
            std.process.exit(1);
        };
        var wp: winprotopkg.App = winprotopkg.App.init(
            alloc,
            display,
            app_id,
            &config,
        ) catch |err| wp: {
            log.warn("error initializing windowing protocol err={}", .{err});
            break :wp .{ .none = .{} };
        };
        errdefer wp.deinit();
        log.debug("windowing protocol={s}", .{@tagName(wp)});
        log.debug("creating GTK application id={s} single-instance={}", .{
            app_id,
            single_instance,
        });
        const config_obj: *Config = try .new(alloc, &config);
        errdefer config_obj.unref();
        const css_provider = gtk.CssProvider.new();
        gtk.StyleContext.addProviderForDisplay(
            display,
            css_provider.as(gtk.StyleProvider),
            gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 3,
        );
        errdefer css_provider.unref();
        const self = gobject.ext.newInstance(Self, .{
            .application_id = app_id.ptr,
            .flags = app_flags,
            .resource_base_path = build_info.resource_path,
        });
        const priv: *Private = self.private();
        priv.* = .{
            .rt_app = rt_app,
            .core_app = core_app,
            .config = config_obj,
            .winproto = wp,
            .css_provider = css_provider,
            .custom_css_providers = .empty,
            .global_shortcuts = gobject.ext.newInstance(GlobalShortcuts, .{}),
            .saved_language = saved_language,
            .open_uri = .init(rt_app),
        };
        _ = gobject.Object.signals.notify.connect(
            self,
            *Self,
            propConfig,
            self,
            .{ .detail = "config" },
        );
        _ = gtk.CssProvider.signals.parsing_error.connect(
            css_provider,
            *Self,
            signalCssParsingError,
            self,
            .{},
        );
        self.as(gobject.Object).notifyByPspec(properties.config.impl.param_spec);
        return self;
    }
    pub fn deinit(self: *Self) void {
        const alloc = self.allocator();
        const priv: *Private = self.private();
        priv.config.unref();
        priv.winproto.deinit();
        priv.open_uri.deinit();
        priv.global_shortcuts.unref();
        if (priv.saved_language) |language| alloc.free(language);
        if (gdk.Display.getDefault()) |display| {
            gtk.StyleContext.removeProviderForDisplay(
                display,
                priv.css_provider.as(gtk.StyleProvider),
            );
            for (priv.custom_css_providers.items) |provider| {
                gtk.StyleContext.removeProviderForDisplay(
                    display,
                    provider.as(gtk.StyleProvider),
                );
            }
        }
        priv.css_provider.unref();
        for (priv.custom_css_providers.items) |provider| provider.unref();
        priv.custom_css_providers.deinit(alloc);
    }
    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.private().core_app.alloc;
    }
    pub fn savedLanguage(self: *Self) ?[:0]const u8 {
        return self.private().saved_language;
    }
    pub fn run(self: *Self) !void {
        const ctx = glib.MainContext.default();
        if (glib.MainContext.acquire(ctx) == 0) return error.ContextAcquireFailed;
        defer {
            self.stopQuitTimer();
            gio.Settings.sync();
            while (glib.MainContext.iteration(ctx, 0) != 0) {}
            defer glib.MainContext.release(ctx);
        }
        var err_: ?*glib.Error = null;
        if (self.as(gio.Application).register(
            null,
            &err_,
        ) == 0) {
            if (err_) |err| {
                defer err.free();
                log.warn(
                    "error registering application: {s}",
                    .{err.f_message orelse "(unknown)"},
                );
            }
            return error.ApplicationRegisterFailed;
        }
        assert(err_ == null);
        const priv = self.private();
        {
            const config = priv.config.get();
            if (config.@"initial-window") self.as(gio.Application).activate();
        }
        if (self.as(gio.Application).getIsRemote() != 0) {
            log.debug(
                "application is remote, exiting run loop after activation",
                .{},
            );
            return;
        }
        systemd.notify.ready();
        priv.systemd_ready = true;
        log.debug("entering runloop", .{});
        defer log.debug("exiting runloop", .{});
        priv.running = true;
        while (priv.running) {
            _ = glib.MainContext.iteration(ctx, 1);
            try priv.core_app.tick(priv.rt_app);
            const must_quit = q: {
                const config = priv.config.get();
                if (!config.@"quit-after-last-window-closed") break :q false;
                if (priv.quit_timer == .expired) {
                    log.debug("must_quit due to quit timer expired", .{});
                    break :q true;
                }
                if (config.@"quit-after-last-window-closed-delay" == null) {
                    if (priv.requested_window and @as(
                        ?*glib.List,
                        self.as(gtk.Application).getWindows(),
                    ) == null) {
                        log.debug("must_quit due to no app windows", .{});
                        break :q true;
                    }
                }
                break :q false;
            };
            if (must_quit) {
                self.quitNow();
            }
        }
    }
    pub fn quit(self: *Self) void {
        const priv = self.private();
        if (!priv.running) return;
        if (!priv.core_app.needsConfirmQuit()) {
            self.quitNow();
            return;
        }
        const parent: ?*gtk.Widget = parent: {
            const list = gtk.Window.listToplevels();
            defer list.free();
            const focused = @as(?*glib.List, list.findCustom(
                null,
                findActiveWindow,
            )) orelse {
                break :parent null;
            };
            break :parent @ptrCast(@alignCast(focused.f_data));
        };
        const dialog: *CloseConfirmationDialog = .new(.app);
        _ = CloseConfirmationDialog.signals.@"close-request".connect(
            dialog,
            *Application,
            handleCloseConfirmation,
            self,
            .{},
        );
        dialog.present(parent);
    }
    fn quitNow(self: *Self) void {
        const list = gtk.Window.listToplevels();
        defer list.free();
        list.foreach(struct {
            fn callback(data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
                const ptr = data orelse return;
                const window: *gtk.Window = @ptrCast(@alignCast(ptr));
                if (gobject.ext.isA(window, Window)) {
                    window.destroy();
                }
            }
        }.callback, null);
        self.private().running = false;
    }
    pub fn performAction(
        self: *Self,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        switch (action) {
            .close_tab => return Action.closeTab(target, value),
            .close_window => return Action.closeWindow(target),
            .copy_title_to_clipboard => return Action.copyTitleToClipboard(target),
            .config_change => try Action.configChange(
                self,
                target,
                value.config,
            ),
            .desktop_notification => Action.desktopNotification(self, target, value),
            .equalize_splits => return Action.equalizeSplits(target),
            .goto_split => return Action.gotoSplit(target, value),
            .goto_window => return Action.gotoWindow(value),
            .goto_tab => return Action.gotoTab(target, value),
            .initial_size => return Action.initialSize(target, value),
            .inspector => return Action.controlInspector(target, value),
            .export_terminal_io => return try Action.exportTerminalIO(
                self,
                target,
                value,
            ),
            .key_sequence => return Action.keySequence(target, value),
            .key_table => return Action.keyTable(target, value),
            .mouse_over_link => Action.mouseOverLink(target, value),
            .mouse_shape => Action.mouseShape(target, value),
            .mouse_visibility => Action.mouseVisibility(target, value),
            .move_tab => return Action.moveTab(target, value),
            .move_tab_to_new_window => return Action.moveTabToNewWindow(target),
            .new_split => return Action.newSplit(target, value),
            .new_tab => return Action.newTab(target, .none),
            .new_window => try Action.newWindow(
                self,
                switch (target) {
                    .app => null,
                    .surface => |v| v,
                },
                .none,
            ),
            .open_config => return Action.openConfig(self, value),
            .open_url => Action.openUrl(self, value),
            .pwd => Action.pwd(target, value),
            .present_terminal => return Action.presentTerminal(target),
            .progress_report => return Action.progressReport(target, value),
            .prompt_title => return Action.promptTitle(target, value),
            .quit => self.quit(),
            .quit_timer => try Action.quitTimer(self, value),
            .reload_config => try Action.reloadConfig(self, target, value),
            .render => Action.render(target),
            .resize_split => return Action.resizeSplit(target, value),
            .resize_window => return Action.resizeWindow(target, value),
            .ring_bell => Action.ringBell(target),
            .selection_changed => {},
            .scrollbar => Action.scrollbar(target, value),
            .set_title => Action.setTitle(target, value),
            .set_tab_title => return Action.setTabTitle(target, value),
            .set_window_title => return Action.setWindowTitle(target, value),
            .show_child_exited => return Action.showChildExited(target, value),
            .show_gtk_inspector => Action.showGtkInspector(),
            .size_limit => return Action.sizeLimit(target, value),
            .toggle_maximize => Action.toggleMaximize(target),
            .toggle_fullscreen => Action.toggleFullscreen(target),
            .toggle_quick_terminal => return Action.toggleQuickTerminal(self),
            .toggle_tab_overview => return Action.toggleTabOverview(target),
            .toggle_window_decorations => return Action.toggleWindowDecorations(target),
            .toggle_command_palette => return Action.toggleCommandPalette(target),
            .toggle_split_zoom => return Action.toggleSplitZoom(target),
            .show_on_screen_keyboard => return Action.showOnScreenKeyboard(target),
            .command_finished => return Action.commandFinished(target, value),
            .readonly => return Action.setReadonly(target, value),
            .start_search => Action.startSearch(target, value),
            .end_search => Action.endSearch(target),
            .search_total => Action.searchTotal(target, value),
            .search_selected => Action.searchSelected(target, value),
            .secure_input,
            .close_all_windows,
            .float_window,
            .toggle_visibility,
            .toggle_background_opacity,
            .cell_size,
            .render_inspector,
            .renderer_health,
            .color_change,
            .reset_window_size,
            .check_for_updates,
            .undo,
            .redo,
            => {
                log.warn("unimplemented action={}", .{action});
                return false;
            },
        }
        return true;
    }
    pub fn core(self: *Self) *CoreApp {
        return self.private().core_app;
    }
    pub fn rt(self: *Self) *ApprtApp {
        return self.private().rt_app;
    }
    pub fn winproto(self: *Self) *winprotopkg.App {
        return &self.private().winproto;
    }
    pub fn openUri(self: *Self) *OpenURI {
        return &self.private().open_uri;
    }
    fn startQuitTimer(self: *Self) void {
        const priv = self.private();
        const config = priv.config.get();
        self.stopQuitTimer();
        if (!config.@"quit-after-last-window-closed") return;
        if (config.@"quit-after-last-window-closed-delay") |v| {
            priv.quit_timer = .{
                .active = glib.timeoutAdd(
                    v.asMilliseconds(),
                    handleQuitTimerExpired,
                    self,
                ),
            };
        } else {
            priv.quit_timer = .expired;
        }
    }
    fn stopQuitTimer(self: *Self) void {
        const priv = self.private();
        switch (priv.quit_timer) {
            .off => {},
            .expired => priv.quit_timer = .off,
            .active => |source| {
                if (glib.Source.remove(source) == 0) {
                    log.warn(
                        "unable to remove quit timer source={d}",
                        .{source},
                    );
                }
                priv.quit_timer = .off;
            },
        }
    }
    fn loadRuntimeCss(self: *Self) (Allocator.Error || std.Io.Writer.Error)!void {
        const alloc = self.allocator();
        const priv: *Private = self.private();
        const config = priv.config.get();
        var buf: std.Io.Writer.Allocating = try .initCapacity(alloc, 2048);
        defer buf.deinit();
        const writer = &buf.writer;
        const window_theme = config.@"window-theme";
        const headerbar_background = config.@"window-titlebar-background" orelse config.background;
        const headerbar_foreground = config.@"window-titlebar-foreground" orelse config.foreground;
        try writer.writeAll(
            \\/*
            \\ * Child Exited Overlay
            \\ */
            \\
            \\.child-exited.normal revealer widget {
            \\  background-color: color-mix(
            \\    in srgb,
            \\    var(--success-bg-color),
            \\    transparent 50%
            \\  );
            \\}
            \\
            \\.child-exited.abnormal revealer widget {
            \\  background-color: color-mix(
            \\    in srgb,
            \\    var(--error-bg-color),
            \\    transparent 50%
            \\  );
            \\}
            \\
            \\/*
            \\ * Surface
            \\ */
            \\
            \\.surface progressbar.error trough progress {
            \\  background-color: color-mix(
            \\    in srgb,
            \\    var(--error-bg-color),
            \\    transparent 50%
            \\  );
            \\}
            \\
            \\.surface .bell-overlay {
            \\  border-color: color-mix(
            \\    in srgb,
            \\    var(--accent-color),
            \\    transparent 50%
            \\  );
            \\}
            \\
            \\/*
            \\ * Drag and Drop Overlay
            \\ */
            \\.drop-overlay.drop-left {
            \\  background: linear-gradient(
            \\    to left,
            \\    transparent, 50%,
            \\    color-mix(in srgb, var(--accent-bg-color), transparent 80%) 50%
            \\  );
            \\}
            \\.drop-overlay.drop-right {
            \\  background: linear-gradient(
            \\    to right,
            \\    transparent, 50%,
            \\    color-mix(in srgb, var(--accent-bg-color), transparent 80%) 50%
            \\  );
            \\}
            \\.drop-overlay.drop-top {
            \\  background: linear-gradient(
            \\    to top,
            \\    transparent, 50%,
            \\    color-mix(in srgb, var(--accent-bg-color), transparent 80%) 50%
            \\  );
            \\}
            \\.drop-overlay.drop-bottom {
            \\  background: linear-gradient(
            \\    to bottom,
            \\    transparent, 50%,
            \\    color-mix(in srgb, var(--accent-bg-color), transparent 80%) 50%
            \\  );
            \\}
            \\
            \\/*
            \\ * Splits
            \\ */
            \\
            \\.window .split paned > separator {
            \\  background-color: color-mix(
            \\    in srgb,
            \\    var(--window-bg-color),
            \\    transparent 0%
            \\  );
            \\}
            \\
        );
        switch (window_theme) {
            .wasp => try writer.print(
                \\:root {{
                \\  --wasp-fg: rgb({d},{d},{d});
                \\  --wasp-bg: rgb({d},{d},{d});
                \\  --headerbar-fg-color: var(--wasp-fg);
                \\  --headerbar-bg-color: var(--wasp-bg);
                \\  --headerbar-backdrop-color: oklab(from var(--headerbar-bg-color) calc(l * 0.9) a b / alpha);
                \\  --overview-fg-color: var(--wasp-fg);
                \\  --overview-bg-color: var(--wasp-bg);
                \\  --popover-fg-color: var(--wasp-fg);
                \\  --popover-bg-color: var(--wasp-bg);
                \\  --window-fg-color: var(--wasp-fg);
                \\  --window-bg-color: var(--wasp-bg);
                \\}}
                \\listview.command-palette-view {{
                \\  --view-fg-color: var(--wasp-fg);
                \\  --view-bg-color: var(--wasp-bg);
                \\}}
                \\windowhandle {{
                \\  background-color: var(--headerbar-bg-color);
                \\  color: var(--headerbar-fg-color);
                \\}}
                \\windowhandle:backdrop {{
                \\ background-color: var(--headerbar-backdrop-color);
                \\}}
            , .{
                headerbar_foreground.r,
                headerbar_foreground.g,
                headerbar_foreground.b,
                headerbar_background.r,
                headerbar_background.g,
                headerbar_background.b,
            }),
            else => {},
        }
        const unfocused_fill: CoreConfig.Color = config.@"unfocused-split-fill" orelse config.background;
        try writer.print(
            \\widget.unfocused-split {{
            \\ opacity: {d:.2};
            \\ background-color: rgb({d},{d},{d});
            \\}}
            \\
        , .{
            1.0 - config.@"unfocused-split-opacity",
            unfocused_fill.r,
            unfocused_fill.g,
            unfocused_fill.b,
        });
        if (config.@"split-divider-color") |color| {
            try writer.print(
                \\.window .split paned > separator {{
                \\  color: rgb({[r]d},{[g]d},{[b]d});
                \\  background: rgb({[r]d},{[g]d},{[b]d});
                \\}}
                \\
            , .{
                .r = color.r,
                .g = color.g,
                .b = color.b,
            });
        }
        if (config.@"window-title-font-family") |font_family| {
            try writer.print(
                \\.window headerbar {{
                \\  font-family: "{[font_family]s}";
                \\}}
                \\
            , .{ .font_family = font_family });
        }
        const contents = buf.written();
        log.debug("runtime CSS is {d} bytes", .{contents.len});
        const bytes = glib.Bytes.new(contents.ptr, contents.len);
        defer bytes.unref();
        priv.css_provider.loadFromBytes(bytes);
    }
    const LoadCustomCssError = std.Io.File.OpenError ||
        compat_file.ReadToEndAllocError ||
        std.mem.Allocator.Error;
    fn loadCustomCss(self: *Self) LoadCustomCssError!void {
        const priv: *Private = self.private();
        const alloc = self.allocator();
        const display = gdk.Display.getDefault() orelse {
            log.warn("unable to get display", .{});
            return;
        };
        for (priv.custom_css_providers.items) |provider| {
            gtk.StyleContext.removeProviderForDisplay(
                display,
                provider.as(gtk.StyleProvider),
            );
            provider.unref();
        }
        priv.custom_css_providers.clearRetainingCapacity();
        const config = priv.config.get();
        for (config.@"gtk-custom-css".value.items) |p| {
            const path, const optional = switch (p) {
                .optional => |path| .{ path, true },
                .required => |path| .{ path, false },
            };
            const file = std.Io.Dir.openFileAbsolute(
                global.io(),
                path,
                .{},
            ) catch |err| {
                if (err != error.FileNotFound or !optional) {
                    log.warn(
                        "error opening gtk-custom-css file {s}: {}",
                        .{ path, err },
                    );
                }
                continue;
            };
            defer file.close(global.io());
            const css_file_size_limit = 5 * 1024 * 1024;
            log.info("loading gtk-custom-css path={s}", .{path});
            const contents = compat_file.readToEndAlloc(
                file,
                alloc,
                css_file_size_limit,
            ) catch |err| switch (err) {
                error.FileTooBig => {
                    log.warn("gtk-custom-css file {s} was larger than {Bi}", .{ path, css_file_size_limit });
                    continue;
                },
                else => |e| return e,
            };
            defer alloc.free(contents);
            const bytes = glib.Bytes.new(contents.ptr, contents.len);
            defer bytes.unref();
            const css_provider = gtk.CssProvider.new();
            errdefer css_provider.unref();
            _ = gtk.CssProvider.signals.parsing_error.connect(
                css_provider,
                *Self,
                signalCssParsingError,
                self,
                .{},
            );
            try priv.custom_css_providers.append(alloc, css_provider);
            css_provider.loadFromBytes(bytes);
            gtk.StyleContext.addProviderForDisplay(
                display,
                css_provider.as(gtk.StyleProvider),
                gtk.STYLE_PROVIDER_PRIORITY_USER,
            );
        }
    }
    fn syncActionAccelerators(self: *Self) void {
        self.syncActionAccelerator("app.quit", .{ .quit = {} });
        self.syncActionAccelerator("app.open-config::os-open", .{ .open_config = .os_open });
        self.syncActionAccelerator("app.open-config::new-window", .{ .open_config = .new_window });
        self.syncActionAccelerator("app.reload-config", .{ .reload_config = {} });
        self.syncActionAccelerator("win.toggle-inspector", .{ .inspector = .toggle });
        self.syncActionAccelerator("app.show-gtk-inspector", .show_gtk_inspector);
        self.syncActionAccelerator("win.toggle-command-palette", .toggle_command_palette);
        self.syncActionAccelerator("win.close", .{ .close_window = {} });
        self.syncActionAccelerator("win.new-window", .{ .new_window = {} });
        self.syncActionAccelerator("win.new-tab", .{ .new_tab = {} });
        self.syncActionAccelerator("win.close-tab::this", .{ .close_tab = .this });
        self.syncActionAccelerator("tab.close::this", .{ .close_tab = .this });
        self.syncActionAccelerator("win.split-right", .{ .new_split = .right });
        self.syncActionAccelerator("win.split-down", .{ .new_split = .down });
        self.syncActionAccelerator("win.split-left", .{ .new_split = .left });
        self.syncActionAccelerator("win.split-up", .{ .new_split = .up });
        self.syncActionAccelerator("win.copy", .{ .copy_to_clipboard = .mixed });
        self.syncActionAccelerator("win.paste", .{ .paste_from_clipboard = {} });
        self.syncActionAccelerator("win.reset", .{ .reset = {} });
        self.syncActionAccelerator("win.clear", .{ .clear_screen = {} });
        self.syncActionAccelerator("win.prompt-title", .{ .prompt_surface_title = {} });
        self.syncActionAccelerator("split-tree.new-split::left", .{ .new_split = .left });
        self.syncActionAccelerator("split-tree.new-split::right", .{ .new_split = .right });
        self.syncActionAccelerator("split-tree.new-split::up", .{ .new_split = .up });
        self.syncActionAccelerator("split-tree.new-split::down", .{ .new_split = .down });
    }
    fn syncActionAccelerator(
        self: *Self,
        gtk_action: [:0]const u8,
        action: input.Binding.Action,
    ) void {
        const gtk_app = self.as(gtk.Application);
        const zero = [_:null]?[*:0]const u8{};
        gtk_app.setAccelsForAction(gtk_action, &zero);
        const config = self.private().config.get();
        const trigger = config.keybind.set.getTrigger(action) orelse return;
        var buf: [1024]u8 = undefined;
        const accel = if (key.accelFromTrigger(
            &buf,
            trigger,
        )) |accel_|
            accel_ orelse return
        else |err| switch (err) {
            error.WriteFailed => {
                log.warn("accelerator somehow longer than 1024 bytes: {f}", .{trigger});
                return;
            },
        };
        const accels = [_:null]?[*:0]const u8{accel};
        gtk_app.setAccelsForAction(gtk_action, &accels);
    }
    pub fn getConfig(self: *Self) *Config {
        return self.private().config.ref();
    }
    fn setConfig(self: *Self, config: *Config) void {
        const priv = self.private();
        priv.config.unref();
        priv.config = config.ref();
        self.as(gobject.Object).notifyByPspec(properties.config.impl.param_spec);
        self.showConfigErrorsDialog();
    }
    fn propConfig(
        _: *Application,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncActionAccelerators();
        self.loadRuntimeCss() catch |err| switch (err) {
            error.WriteFailed, error.OutOfMemory => log.warn(
                "out of memory loading runtime CSS, no runtime CSS applied",
                .{},
            ),
        };
        self.loadCustomCss() catch |err| {
            log.warn(
                "failed to load custom CSS, no custom CSS applied, err={}",
                .{err},
            );
        };
    }
    fn signalCssParsingError(
        _: *gtk.CssProvider,
        css_section: *gtk.CssSection,
        err: *glib.Error,
        _: *Self,
    ) callconv(.c) void {
        const location = css_section.toString();
        defer glib.free(location);
        bytes: {
            const bytes = css_section.getBytes() orelse break :bytes;
            var len: usize = undefined;
            const ptr = bytes.getData(&len) orelse break :bytes;
            const data = ptr[0..len];
            log.warn("css parsing failed at {s}: {s} {d} {s}\n{s}", .{
                location,
                glib.quarkToString(err.f_domain),
                err.f_code,
                err.f_message orelse "«unknown»",
                data,
            });
            return;
        }
        log.warn("css parsing failed at {s}: {s} {d} {s}", .{
            location,
            glib.quarkToString(err.f_domain),
            err.f_code,
            err.f_message orelse "«unknown»",
        });
    }
    pub fn wakeup(self: *Self) void {
        _ = self;
        glib.MainContext.wakeup(null);
    }
    fn startup(self: *Self) callconv(.c) void {
        log.debug("startup", .{});
        gio.Application.virtual_methods.startup.call(
            Class.parent,
            self.as(Parent),
        );
        gio.Application.setDefault(self.as(gio.Application));
        self.openUri().setDbusConnection(
            self.as(gio.Application).getDbusConnection(),
        );
        self.startupXev();
        self.startupSignals();
        self.startupStyleManager();
        self.startupActionMap();
        self.startupGlobalShortcuts();
        self.showConfigErrorsDialog();
    }
    fn startupXev(self: *Self) void {
        const priv = self.private();
        const config = priv.config.get();
        if (config.@"async-backend" == .auto) return;
        const result: bool = switch (config.@"async-backend") {
            .auto => unreachable,
            .epoll => if (comptime xev.dynamic) xev.prefer(.epoll) else false,
            .io_uring => if (comptime xev.dynamic) xev.prefer(.io_uring) else false,
        };
        if (result) {
            log.info(
                "libxev manual backend={s}",
                .{@tagName(xev.backend)},
            );
        } else {
            log.warn(
                "libxev manual backend failed, using default={s}",
                .{@tagName(xev.backend)},
            );
        }
    }
    fn startupStyleManager(self: *Self) void {
        const priv = self.private();
        const config = priv.config.get();
        const style = self.as(adw.Application).getStyleManager();
        style.setColorScheme(switch (config.@"window-theme") {
            .auto, .wasp => auto: {
                const lum = config.background.toTerminalRGB().perceivedLuminance();
                break :auto if (lum > 0.5)
                    .prefer_light
                else
                    .prefer_dark;
            },
            .system => .prefer_light,
            .dark => .force_dark,
            .light => .force_light,
        });
        _ = gobject.Object.signals.notify.connect(
            style,
            *Self,
            handleStyleManagerDark,
            self,
            .{ .detail = "dark" },
        );
        handleStyleManagerDark(style, undefined, self);
    }
    fn startupSignals(self: *Self) void {
        const priv = self.private();
        assert(priv.signal_source == null);
        priv.signal_source = glibunix.signalAdd(
            @intFromEnum(std.posix.SIG.USR2),
            handleSigusr2,
            self,
        );
    }
    fn startupActionMap(self: *Self) void {
        const t_variant_type = glib.ext.VariantType.newFor(u64);
        defer t_variant_type.free();
        const as_variant_type = glib.VariantType.new("as");
        defer as_variant_type.free();
        const tas_variant_type = glib.VariantType.new("(tas)");
        defer tas_variant_type.free();
        const s_variant_type = glib.ext.VariantType.newFor([:0]const u8);
        defer s_variant_type.free();
        const actions = [_]ext.actions.Action(Self){
            .init("new-window", actionNewWindow, null),
            .init("new-window-command", actionNewWindow, as_variant_type),
            .init("new-tab", actionNewTab, tas_variant_type),
            .init("open-config", actionOpenConfig, s_variant_type),
            .init("present-surface", actionPresentSurface, t_variant_type),
            .init("quit", actionQuit, null),
            .init("reload-config", actionReloadConfig, null),
            .init("toggle-quick-terminal", actionToggleQuickTerminal, null),
            .init("ring-bell", actionRingBell, null),
        };
        ext.actions.add(Self, self, &actions);
    }
    fn startupGlobalShortcuts(self: *Self) void {
        const priv = self.private();
        priv.global_shortcuts.setDbusConnection(
            self.as(gio.Application).getDbusConnection(),
        );
        _ = gobject.Object.bindProperty(
            self.as(gobject.Object),
            "config",
            priv.global_shortcuts.as(gobject.Object),
            "config",
            .{ .sync_create = true },
        );
        _ = GlobalShortcuts.signals.trigger.connect(
            priv.global_shortcuts,
            *Application,
            globalShortcutTrigger,
            self,
            .{},
        );
        _ = GlobalShortcuts.signals.@"bind-failed".connect(
            priv.global_shortcuts,
            *Application,
            globalShortcutBindFailed,
            self,
            .{},
        );
    }
    fn activate(self: *Self) callconv(.c) void {
        log.debug("activate", .{});
        const priv = self.private();
        _ = priv.core_app.mailbox.push(global.io(), .{
            .new_window = .{},
        }, .{ .forever = {} });
        gio.Application.virtual_methods.activate.call(
            Class.parent,
            self.as(Parent),
        );
    }
    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.config_errors_dialog.get()) |diag| {
            diag.close();
            diag.unref();
        }
        priv.config_errors_dialog.deinit();
        if (priv.signal_source) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove signal source", .{});
            }
            priv.signal_source = null;
        }
        if (priv.bell_media) |v| {
            v.unref();
            priv.bell_media = null;
        }
        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }
    fn finalize(self: *Self) callconv(.c) void {
        self.deinit();
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }
    fn handleSigusr2(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse
            return @intFromBool(glib.SOURCE_CONTINUE)));
        log.info("received SIGUSR2, reloading configuration", .{});
        Action.reloadConfig(
            self,
            .app,
            .{},
        ) catch |err| {
            log.warn("error reloading config: {}", .{err});
        };
        return @intFromBool(glib.SOURCE_CONTINUE);
    }
    fn handleCloseConfirmation(
        _: *CloseConfirmationDialog,
        self: *Self,
    ) callconv(.c) void {
        self.quitNow();
    }
    fn handleQuitTimerExpired(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud));
        const priv = self.private();
        priv.quit_timer = .expired;
        return 0;
    }
    fn handleStyleManagerDark(
        style: *adw.StyleManager,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const scheme: apprt.ColorScheme = if (style.getDark() == 0)
            .light
        else
            .dark;
        log.debug("style manager changed scheme={}", .{scheme});
        const priv: *Private = self.private();
        const core_app = priv.core_app;
        core_app.colorSchemeEvent(self.rt(), scheme) catch |err| {
            log.warn("error updating app color scheme err={}", .{err});
        };
        for (core_app.surfaces.items) |surface| {
            surface.core().colorSchemeCallback(scheme) catch |err| {
                log.warn(
                    "unable to tell surface about color scheme change err={}",
                    .{err},
                );
            };
        }
        if (gtk_version.atLeast(4, 20, 0)) {
            const gtk_scheme: gtk.InterfaceColorScheme = switch (scheme) {
                .light => gtk.InterfaceColorScheme.light,
                .dark => gtk.InterfaceColorScheme.dark,
            };
            var value = gobject.ext.Value.newFrom(gtk_scheme);
            gobject.Object.setProperty(
                priv.css_provider.as(gobject.Object),
                "prefers-color-scheme",
                &value,
            );
            for (priv.custom_css_providers.items) |css_provider| {
                gobject.Object.setProperty(
                    css_provider.as(gobject.Object),
                    "prefers-color-scheme",
                    &value,
                );
            }
        }
    }
    fn handleReloadConfig(
        _: *ConfigErrorsDialog,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.config_errors_dialog.set(null);
        Action.reloadConfig(
            self,
            .app,
            .{},
        ) catch |err| {
            log.warn("error reloading config: {}", .{err});
        };
    }
    fn showConfigErrorsDialog(self: *Self) void {
        const priv = self.private();
        if (priv.config_errors_dialog.get()) |diag| {
            defer diag.unref();
            var value = gobject.ext.Value.newFrom(priv.config);
            defer value.unset();
            gobject.Object.setProperty(
                diag.as(gobject.Object),
                "config",
                &value,
            );
            if (!priv.config.hasDiagnostics()) {
                diag.close();
            } else {
                diag.present(null);
            }
            return;
        }
        if (!priv.config.hasDiagnostics()) return;
        const dialog: *ConfigErrorsDialog = .new(priv.config);
        priv.config_errors_dialog.set(dialog);
        _ = ConfigErrorsDialog.signals.@"reload-config".connect(
            dialog,
            *Application,
            handleReloadConfig,
            self,
            .{},
        );
        dialog.present(null);
    }
    fn globalShortcutTrigger(
        _: *GlobalShortcuts,
        action: *const Binding.Action,
        self: *Self,
    ) callconv(.c) void {
        self.core().performAllAction(self.rt(), action.*) catch |err| {
            log.warn("failed to perform action={}", .{err});
        };
    }
    fn globalShortcutBindFailed(
        _: *GlobalShortcuts,
        failure: *const GlobalShortcuts.BindFailed,
        self: *Self,
    ) callconv(.c) void {
        var label_buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&label_buf);
        const label: []const u8 = label: {
            const ok = key.labelFromTrigger(&writer, failure.trigger) catch false;
            break :label if (ok) writer.buffered() else "?";
        };
        const detail: [*:0]const u8 = detail: {
            if (failure.message[0] != 0) break :detail failure.message;
            break :detail if (failure.revoked)
                i18n._("The keybind was revoked by the system.")
            else
                i18n._("The keybind was denied by the system.");
        };
        var body_buf: [512]u8 = undefined;
        const body = std.fmt.bufPrintZ(
            &body_buf,
            "{s}: {s}",
            .{ label, detail },
        ) catch return;
        Action.desktopNotification(self, .app, .{
            .title = std.mem.span(i18n._("Global keybind unavailable")),
            .body = body,
        });
    }
    fn actionReloadConfig(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.core_app.performAction(self.rt(), .reload_config) catch |err| {
            log.warn("error reloading config err={}", .{err});
        };
    }
    fn actionToggleQuickTerminal(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.core_app.performAction(self.rt(), .toggle_quick_terminal) catch |err| {
            log.warn("error toggling quick terminal err={}", .{err});
        };
    }
    fn actionQuit(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.core_app.performAction(self.rt(), .quit) catch |err| {
            log.warn("error quitting err={}", .{err});
        };
    }
    pub fn actionNewWindow(
        _: *gio.SimpleAction,
        parameter_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        log.debug("received new window action", .{});
        var arena: std.heap.ArenaAllocator = .init(self.core().alloc);
        defer arena.deinit();
        const alloc = arena.allocator();
        const overrides = overrides: {
            const arguments = parameter_ orelse break :overrides null;
            const as_variant_type = glib.VariantType.new("as");
            defer as_variant_type.free();
            if (glib.Variant.isOfType(arguments, as_variant_type) == 0) {
                log.warn("parameter is of type '{s}', not '{s}'", .{
                    arguments.getTypeString(),
                    as_variant_type.peekString()[0..as_variant_type.getStringLength()],
                });
                break :overrides null;
            }
            var arguments_it: glib.VariantIter = undefined;
            _ = arguments_it.init(arguments);
            break :overrides Overrides.parse(alloc, &arguments_it) catch null;
        };
        Action.newWindow(
            self,
            null,
            if (overrides) |o| .{
                .command = o.command,
                .shell_integration = o.shell_integration,
                .working_directory = o.working_directory,
                .title = o.title,
            } else .none,
        ) catch |err| {
            log.warn("unable to create new window: {t}", .{err});
        };
    }
    pub fn actionNewTab(
        _: *gio.SimpleAction,
        parameter_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        log.debug("received new tab action", .{});
        const core_app = self.core();
        var arena: std.heap.ArenaAllocator = .init(core_app.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();
        const surface_id_, const overrides = result: {
            const parameter = parameter_ orelse {
                log.warn("app.new-tab did not receive a parameter", .{});
                return;
            };
            log.warn("got parameter: {s}", .{parameter.getTypeString()});
            const tas_variant_type = glib.VariantType.new("(tas)");
            defer tas_variant_type.free();
            if (glib.Variant.isOfType(parameter, tas_variant_type) == 0) {
                log.warn("parameter is of type '{s}', not '{s}'", .{
                    parameter.getTypeString(),
                    tas_variant_type.peekString()[0..tas_variant_type.getStringLength()],
                });
                return;
            }
            var surface_id: u64 = 0;
            var arguments_it_: ?*glib.VariantIter = null;
            defer if (arguments_it_) |arguments_it| arguments_it.free();
            parameter.get("(tas)", &surface_id, &arguments_it_);
            const arguments_it = arguments_it_ orelse return;
            const overrides = Overrides.parse(alloc, arguments_it) catch return;
            break :result .{ if (surface_id == 0) null else surface_id, overrides };
        };
        const surface_ = surface: {
            if (surface_id_) |surface_id| find_by_id: {
                break :surface core_app.findSurfaceByID(surface_id) orelse {
                    log.warn("new-tab: unable to find surface 0x{x:0>16}", .{surface_id});
                    break :find_by_id;
                };
            }
            find_focused: {
                break :surface core_app.focusedSurface() orelse {
                    log.warn("new-tab: unable to find surface", .{});
                    break :find_focused;
                };
            }
            break :surface null;
        };
        if (surface_) |surface| {
            if (!Action.newTab(
                .{
                    .surface = surface,
                },
                .{
                    .command = overrides.command,
                    .shell_integration = overrides.shell_integration,
                    .working_directory = overrides.working_directory,
                    .title = overrides.title,
                },
            )) {
                log.warn("new-tab: unable to create tab", .{});
            }
        } else {
            Action.newWindow(
                self,
                null,
                .{
                    .command = overrides.command,
                    .shell_integration = overrides.shell_integration,
                    .working_directory = overrides.working_directory,
                    .title = overrides.title,
                },
            ) catch |err| {
                log.warn("new-tab: unable to create new window: {t}", .{err});
            };
        }
    }
    pub fn actionOpenConfig(
        _: *gio.SimpleAction,
        parameter_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const target: CoreApp.Message.OpenConfig = target: {
            const target_map: std.StaticStringMap(CoreApp.Message.OpenConfig) = .initComptime(&.{
                .{ "os-open", .os_open },
                .{ "new-window", .new_window },
            });
            const parameter = parameter_ orelse {
                log.warn("no parameter provided to app.open-config action", .{});
                break :target .os_open;
            };
            const s_variant_type = glib.ext.VariantType.newFor([:0]const u8);
            defer s_variant_type.free();
            if (parameter.isOfType(s_variant_type) == 0) {
                log.warn("parameter to app.open-config action is of type '{s}' not '{s}'", .{
                    parameter.getTypeString(),
                    s_variant_type.peekString()[0..s_variant_type.getStringLength()],
                });
                break :target .os_open;
            }
            var len: usize = undefined;
            const buf = parameter.getString(&len);
            const str = buf[0..len];
            break :target target_map.get(str) orelse {
                log.warn("'{s}' is not configured as a target for the app.open-config action", .{str});
                break :target .os_open;
            };
        };
        _ = self.core().mailbox.push(global.io(), .{ .open_config = target }, .forever);
    }
    fn actionPresentSurface(
        _: *gio.SimpleAction,
        parameter_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const parameter = parameter_ orelse return;
        const t = glib.ext.VariantType.newFor(u64);
        defer glib.VariantType.free(t);
        if (glib.Variant.isOfType(parameter, t) == 0) {
            return;
        }
        const surface_id = parameter.getUint64();
        if (surface_id == 0) return;
        const surface = self.core().findSurfaceByID(surface_id) orelse return;
        _ = self.core().mailbox.push(
            global.io(),
            .{
                .surface_message = .{
                    .surface = surface,
                    .message = .present_surface,
                },
            },
            .forever,
        );
    }
    pub fn actionRingBell(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv: *Private = self.private();
        const config = priv.config.get();
        if (config.@"bell-features".audio) audio: {
            const config_path = config.@"bell-audio-path" orelse break :audio;
            const path, const required = switch (config_path) {
                .optional => |path| .{ path, false },
                .required => |path| .{ path, true },
            };
            const volume = std.math.clamp(
                config.@"bell-audio-volume",
                0.0,
                1.0,
            );
            priv.bell_media = media.bellMediaFile(priv.bell_media, path, required);
            const media_file = priv.bell_media orelse break :audio;
            media.playBell(media_file, volume);
        }
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
            {
                const wasp_gtk_resources = @import("wasp_gtk_resources");
                if (wasp_gtk_resources.wasp_get_resource()) |ptr| {
                    gio.resourcesRegister(@ptrCast(@alignCast(ptr)));
                } else {
                    log.warn("unable to load resources", .{});
                }
            }
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
            });
            gio.Application.virtual_methods.activate.implement(class, &activate);
            gio.Application.virtual_methods.startup.implement(class, &startup);
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };
    pub fn openUrlFallback(self: *Application, kind: apprt.action.OpenUrl.Kind, url: []const u8) void {
        _ = self;
        internal_os.open(
            kind,
            url,
        ) catch |err| log.warn("unable to open url: {}", .{err});
    }
};
const Action = struct {
    pub fn closeTab(target: apprt.Target, value: apprt.Action.Value(.close_tab)) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                return surface.as(gtk.Widget).activateAction(
                    "tab.close",
                    glib.ext.VariantType.stringFor([:0]const u8),
                    @as([*:0]const u8, @tagName(value)),
                ) != 0;
            },
        }
    }
    pub fn closeWindow(target: apprt.Target) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                return surface.as(gtk.Widget).activateAction("win.close", null) != 0;
            },
        }
    }
    pub fn copyTitleToClipboard(target: apprt.Target) bool {
        return switch (target) {
            .app => false,
            .surface => |v| v.rt_surface.gobj().copyTitleToClipboard(),
        };
    }
    pub fn exportTerminalIO(
        self: *Application,
        target: apprt.Target,
        value: apprt.Action.Value(.export_terminal_io),
    ) Allocator.Error!bool {
        const surface = switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.gobj(),
        };
        const alloc = self.allocator();
        const contents = try alloc.dupe(u8, value.contents);
        errdefer alloc.free(contents);
        const request = try alloc.create(ExportTerminalIORequest);
        errdefer alloc.destroy(request);
        request.* = .{
            .alloc = alloc,
            .contents = contents,
        };
        const parent = ext.getAncestor(gtk.Window, surface.as(gtk.Widget));
        const dialog = gtk.FileChooserNative.new(
            i18n._("Export Terminal IO Events"),
            parent,
            .save,
            i18n._("Export"),
            i18n._("Cancel"),
        );
        const chooser = dialog.as(gtk.FileChooser);
        chooser.setCreateFolders(1);
        chooser.setCurrentName("wasp-terminal-io.txt");
        _ = gtk.NativeDialog.signals.response.connect(
            dialog,
            *ExportTerminalIORequest,
            ExportTerminalIORequest.response,
            request,
            .{ .destroyData = ExportTerminalIORequest.destroy },
        );
        dialog.as(gtk.NativeDialog).show();
        return true;
    }
    const ExportTerminalIORequest = struct {
        alloc: Allocator,
        contents: []u8,
        fn destroy(self: *ExportTerminalIORequest) callconv(.c) void {
            self.alloc.free(self.contents);
            self.alloc.destroy(self);
        }
        fn response(
            dialog: *gtk.FileChooserNative,
            response_id: c_int,
            self: *ExportTerminalIORequest,
        ) callconv(.c) void {
            defer dialog.unref();
            if (response_id != @intFromEnum(gtk.ResponseType.accept)) return;
            const file = dialog.as(gtk.FileChooser).getFile() orelse {
                log.warn("inspector export dialog returned no file", .{});
                return;
            };
            defer file.unref();
            var gerr: ?*glib.Error = null;
            const replaced = file.replaceContents(
                self.contents.ptr,
                self.contents.len,
                null,
                0,
                .{},
                null,
                null,
                &gerr,
            );
            if (gerr) |err| {
                defer err.free();
                log.err(
                    "failed to export terminal IO events err={s}",
                    .{err.f_message orelse "(unknown)"},
                );
                return;
            }
            if (replaced == 0) {
                log.err("failed to export terminal IO events", .{});
            }
        }
    };
    pub fn configChange(
        self: *Application,
        target: apprt.Target,
        new_config: *const CoreConfig,
    ) !void {
        const alloc = self.allocator();
        const config_obj: *Config = try .new(alloc, new_config);
        defer config_obj.unref();
        switch (target) {
            .surface => |core| core.rt_surface.surface.setConfig(config_obj),
            .app => self.setConfig(config_obj),
        }
    }
    pub fn desktopNotification(
        self: *Application,
        target: apprt.Target,
        n: apprt.action.DesktopNotification,
    ) void {
        switch (target) {
            .app => {},
            .surface => |v| {
                v.rt_surface.gobj().sendDesktopNotification(n.title, n.body);
                return;
            },
        }
        const t = switch (n.title.len) {
            0 => "Wasp",
            else => n.title,
        };
        const notification = gio.Notification.new(t);
        defer notification.unref();
        notification.setBody(n.body);
        const icon = gio.ThemedIcon.new("com.mitchellh.wasp");
        defer icon.unref();
        notification.setIcon(icon.as(gio.Icon));
        notification.setDefaultActionAndTargetValue(
            "app.present-surface",
            glib.Variant.newUint64(0),
        );
        const gio_app = self.as(gio.Application);
        gio_app.sendNotification(n.body, notification);
    }
    pub fn equalizeSplits(target: apprt.Target) bool {
        switch (target) {
            .app => {
                log.warn("equalize splits to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                const surface = core.rt_surface.surface;
                return surface.as(gtk.Widget).activateAction("split-tree.equalize", null) != 0;
            },
        }
    }
    pub fn gotoSplit(
        target: apprt.Target,
        to: apprt.action.GotoSplit,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const tree = ext.getAncestor(
                    SplitTree,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a split tree, ignoring goto_split", .{});
                    return false;
                };
                return tree.goto(switch (to) {
                    .previous => .previous_wrapped,
                    .next => .next_wrapped,
                    .up => .{ .spatial = .up },
                    .down => .{ .spatial = .down },
                    .left => .{ .spatial = .left },
                    .right => .{ .spatial = .right },
                });
            },
        }
    }
    pub fn gotoTab(
        target: apprt.Target,
        tab: apprt.action.GotoTab,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring new_tab", .{});
                    return false;
                };
                return window.selectTab(switch (tab) {
                    .previous => .previous,
                    .next => .next,
                    .last => .last,
                    else => .{ .n = @intCast(@intFromEnum(tab)) },
                });
            },
        }
    }
    pub fn gotoWindow(direction: apprt.action.GotoWindow) bool {
        const glist = gtk.Window.listToplevels();
        defer glist.free();
        const starting: *glib.List = @as(?*glib.List, glist.findCustom(
            null,
            findActiveWindow,
        )) orelse glist;
        var current_: ?*glib.List = starting;
        while (current_) |node| : (current_ = switch (direction) {
            .next => node.f_next,
            .previous => node.f_prev,
        }) {
            const data = node.f_data orelse continue;
            const gtk_window: *gtk.Window = @ptrCast(@alignCast(data));
            if (gotoWindowMaybe(gtk_window)) return true;
        }
        current_ = switch (direction) {
            .next => glist,
            .previous => last: {
                var end: *glib.List = glist;
                while (end.f_next) |next| end = next;
                break :last end;
            },
        };
        while (current_) |node| : (current_ = switch (direction) {
            .next => node.f_next,
            .previous => node.f_prev,
        }) {
            if (current_ == starting) break;
            const data = node.f_data orelse continue;
            const gtk_window: *gtk.Window = @ptrCast(@alignCast(data));
            if (gotoWindowMaybe(gtk_window)) return true;
        }
        return false;
    }
    fn gotoWindowMaybe(gtk_window: *gtk.Window) bool {
        if (gtk_window.isActive() != 0) return false;
        if (gtk_window.as(gtk.Widget).isVisible() == 0) return false;
        const window = gobject.ext.cast(
            Window,
            gtk_window,
        ) orelse return false;
        const surface = window.getActiveSurface() orelse return false;
        gtk.Window.present(gtk_window);
        surface.grabFocus();
        return true;
    }
    pub fn initialSize(
        target: apprt.Target,
        value: apprt.action.InitialSize,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                surface.setDefaultSize(.{
                    .width = value.width,
                    .height = value.height,
                });
                return true;
            },
        }
    }
    pub fn mouseOverLink(
        target: apprt.Target,
        value: apprt.action.MouseOverLink,
    ) void {
        switch (target) {
            .app => log.warn("mouse over link to app is unexpected", .{}),
            .surface => |surface| surface.rt_surface.gobj().setMouseHoverUrl(
                if (value.url.len > 0) value.url else null,
            ),
        }
    }
    pub fn mouseShape(
        target: apprt.Target,
        shape: terminal.MouseShape,
    ) void {
        switch (target) {
            .app => log.warn("mouse shape to app is unexpected", .{}),
            .surface => |surface| surface.rt_surface.gobj().setMouseShape(shape),
        }
    }
    pub fn mouseVisibility(
        target: apprt.Target,
        visibility: apprt.action.MouseVisibility,
    ) void {
        switch (target) {
            .app => log.warn("mouse visibility to app is unexpected", .{}),
            .surface => |surface| surface.rt_surface.gobj().setMouseHidden(switch (visibility) {
                .visible => false,
                .hidden => true,
            }),
        }
    }
    pub fn moveTab(
        target: apprt.Target,
        value: apprt.action.MoveTab,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring new_tab", .{});
                    return false;
                };
                return window.moveTab(
                    surface,
                    @intCast(value.amount),
                );
            },
        }
    }
    pub fn moveTabToNewWindow(
        target: apprt.Target,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring new_tab_to_new_window", .{});
                    return false;
                };
                return window.moveTabToNewWindow(surface);
            },
        }
    }
    pub fn newSplit(
        target: apprt.Target,
        direction: apprt.action.SplitDirection,
    ) bool {
        switch (target) {
            .app => {
                log.warn("new split to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                const surface = core.rt_surface.surface;
                return surface.as(gtk.Widget).activateAction(
                    "split-tree.new-split",
                    "&s",
                    @tagName(direction).ptr,
                ) != 0;
            },
        }
    }
    pub fn newTab(target: apprt.Target, overrides: Overrides) bool {
        switch (target) {
            .app => {
                log.warn("new tab to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring new_tab", .{});
                    return false;
                };
                window.newTab(core, .{
                    .command = overrides.command,
                    .shell_integration = overrides.shell_integration,
                    .working_directory = overrides.working_directory,
                    .title = overrides.title,
                });
                return true;
            },
        }
    }
    pub fn newWindow(self: *Application, parent: ?*CoreSurface, overrides: Overrides) !void {
        self.private().requested_window = true;
        const win = Window.new(self, .{
            .title = overrides.title,
        });
        initAndShowWindow(
            self,
            win,
            parent,
            .{
                .command = overrides.command,
                .shell_integration = overrides.shell_integration,
                .working_directory = overrides.working_directory,
                .title = overrides.title,
            },
        );
    }
    fn initAndShowWindow(
        self: *Application,
        win: *Window,
        parent: ?*CoreSurface,
        overrides: Overrides,
    ) void {
        _ = gobject.Object.bindProperty(
            self.as(gobject.Object),
            "config",
            win.as(gobject.Object),
            "config",
            .{},
        );
        win.newTabForWindow(parent, .{
            .command = overrides.command,
            .shell_integration = overrides.shell_integration,
            .working_directory = overrides.working_directory,
            .title = overrides.title,
        });
        if (win.getActiveSurface()) |surface| {
            surface.estimateInitialSize();
            if (surface.getDefaultSize()) |size| {
                win.as(gtk.Window).setDefaultSize(
                    @intCast(size.width),
                    @intCast(size.height),
                );
            }
        }
        gtk.Window.present(win.as(gtk.Window));
    }
    pub fn openConfig(self: *Application, value: apprt.action.OpenConfig) bool {
        const alloc = self.allocator();
        const path = configpkg.edit.openPath(alloc) catch |err| {
            log.warn("error getting config file path: {t}", .{err});
            return false;
        };
        defer alloc.free(path);
        switch (value) {
            .os_open => {
                openUrl(self, .{ .kind = .text, .url = path });
            },
            .new_window => {
                const cmd = internal_os.getConfigEditCommand(alloc, path, .default) catch |err| {
                    log.warn("unable to get command to edit the config: {t}", .{err});
                    return false;
                };
                defer alloc.free(cmd);
                const command: configpkg.Command = .{
                    .direct = &.{ "/bin/sh", "-c", cmd },
                };
                const title = std.fmt.allocPrintSentinel(
                    alloc,
                    "{s} {s}",
                    .{ i18n._("Editing configuration file"), path },
                    0,
                ) catch |err| t: {
                    log.warn("unable to format title: {t}", .{err});
                    break :t null;
                };
                defer if (title) |t| alloc.free(t);
                Action.newWindow(self, null, .{
                    .command = command,
                    .title = title,
                    .shell_integration = null,
                    .working_directory = null,
                }) catch |err| {
                    log.warn("unable to create new window: {t}", .{err});
                    return false;
                };
            },
        }
        return true;
    }
    pub fn openUrl(
        self: *Application,
        value: apprt.action.OpenUrl,
    ) void {
        if (std.mem.startsWith(u8, value.url, "/")) {
            self.openUrlFallback(value.kind, value.url);
            return;
        }
        if (std.mem.startsWith(u8, value.url, "file://")) {
            self.openUrlFallback(value.kind, value.url);
            return;
        }
        self.openUri().start(value) catch |err| {
            log.err("unable to open uri err={}", .{err});
            self.openUrlFallback(value.kind, value.url);
            return;
        };
    }
    pub fn pwd(
        target: apprt.Target,
        value: apprt.action.Pwd,
    ) void {
        switch (target) {
            .app => log.warn("pwd to app is unexpected", .{}),
            .surface => |surface| surface.rt_surface.gobj().setPwd(value.pwd),
        }
    }
    pub fn quitTimer(
        self: *Application,
        mode: apprt.action.QuitTimer,
    ) !void {
        switch (mode) {
            .start => self.startQuitTimer(),
            .stop => self.stopQuitTimer(),
        }
    }
    pub fn presentTerminal(
        target: apprt.Target,
    ) bool {
        return switch (target) {
            .app => false,
            .surface => |v| surface: {
                v.rt_surface.surface.present();
                break :surface true;
            },
        };
    }
    pub fn progressReport(
        target: apprt.Target,
        value: terminal.osc.Command.ProgressReport,
    ) bool {
        return switch (target) {
            .app => false,
            .surface => |v| surface: {
                v.rt_surface.surface.setProgressReport(value);
                break :surface true;
            },
        };
    }
    pub fn promptTitle(target: apprt.Target, value: apprt.action.PromptTitle) bool {
        switch (value) {
            .surface => switch (target) {
                .app => return false,
                .surface => |v| {
                    v.rt_surface.surface.promptTitle();
                    return true;
                },
            },
            .tab => {
                switch (target) {
                    .app => return false,
                    .surface => |v| {
                        const surface = v.rt_surface.surface;
                        const tab = ext.getAncestor(
                            Tab,
                            surface.as(gtk.Widget),
                        ) orelse {
                            log.warn("surface is not in a tab, ignoring prompt_tab_title", .{});
                            return false;
                        };
                        tab.promptTabTitle();
                        return true;
                    },
                }
            },
            .window => {
                switch (target) {
                    .app => return false,
                    .surface => |v| {
                        const surface = v.rt_surface.surface;
                        const win = ext.getAncestor(
                            Window,
                            surface.as(gtk.Widget),
                        ) orelse {
                            log.warn("surface is not in a window, ignoring prompt_window_title", .{});
                            return false;
                        };
                        win.promptWindowTitle();
                        return true;
                    },
                }
            },
        }
    }
    pub fn reloadConfig(
        self: *Application,
        target: apprt.Target,
        opts: apprt.action.ReloadConfig,
    ) !void {
        const notify_systemd = self.private().systemd_ready;
        if (notify_systemd) systemd.notify.reloading();
        defer if (notify_systemd) systemd.notify.ready();
        const config: *Config = config: {
            if (opts.soft) {
                break :config self.private().config.ref();
            }
            const alloc = self.allocator();
            var config = try CoreConfig.load(alloc);
            defer config.deinit();
            break :config try .new(alloc, &config);
        };
        defer config.unref();
        switch (target) {
            .app => try self.core().updateConfig(
                self.rt(),
                config.get(),
            ),
            .surface => |core| try core.updateConfig(config.get()),
        }
    }
    pub fn render(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.redraw(),
        }
    }
    pub fn resizeSplit(
        target: apprt.Target,
        value: apprt.action.ResizeSplit,
    ) bool {
        switch (target) {
            .app => {
                log.warn("resize_split to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const tree = ext.getAncestor(
                    SplitTree,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a split tree, ignoring resize_split", .{});
                    return false;
                };
                if (!tree.getIsSplit()) return false;
                return tree.resize(
                    switch (value.direction) {
                        .up => .up,
                        .down => .down,
                        .left => .left,
                        .right => .right,
                    },
                    value.amount,
                ) catch |err| switch (err) {
                    error.OutOfMemory => {
                        log.warn("unable to resize split, out of memory", .{});
                        return false;
                    },
                };
            },
        }
    }
    pub fn resizeWindow(
        target: apprt.Target,
        value: apprt.action.ResizeWindow,
    ) bool {
        switch (target) {
            .app => {
                log.warn("resize_window to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring resize_window", .{});
                    return false;
                };
                return window.resizeSurface(surface, value);
            },
        }
    }
    pub fn ringBell(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setBellRinging(true),
        }
    }
    pub fn scrollbar(
        target: apprt.Target,
        value: apprt.Action.Value(.scrollbar),
    ) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setScrollbar(value),
        }
    }
    pub fn startSearch(target: apprt.Target, value: apprt.action.StartSearch) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setSearchActive(true, value.needle),
        }
    }
    pub fn endSearch(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setSearchActive(false, ""),
        }
    }
    pub fn searchTotal(target: apprt.Target, value: apprt.action.SearchTotal) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setSearchTotal(value.total),
        }
    }
    pub fn searchSelected(target: apprt.Target, value: apprt.action.SearchSelected) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setSearchSelected(value.selected),
        }
    }
    pub fn setTitle(
        target: apprt.Target,
        value: apprt.action.SetTitle,
    ) void {
        switch (target) {
            .app => log.warn("set_title to app is unexpected", .{}),
            .surface => |surface| surface.rt_surface.gobj().setTitle(value.title),
        }
    }
    pub fn setTabTitle(
        target: apprt.Target,
        value: apprt.action.SetTitle,
    ) bool {
        switch (target) {
            .app => {
                log.warn("set_tab_title to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const tab = ext.getAncestor(
                    Tab,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a tab, ignoring set_tab_title", .{});
                    return false;
                };
                tab.setTitleOverride(if (value.title.len == 0) null else value.title);
                return true;
            },
        }
    }
    pub fn setWindowTitle(
        target: apprt.Target,
        value: apprt.action.SetTitle,
    ) bool {
        switch (target) {
            .app => {
                log.warn("set_tab_title to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring set_window_title", .{});
                    return false;
                };
                window.setTitleOverride(if (value.title.len == 0) null else value.title);
                return true;
            },
        }
    }
    pub fn showChildExited(
        target: apprt.Target,
        value: apprt.surface.Message.ChildExited,
    ) bool {
        return switch (target) {
            .app => false,
            .surface => |v| v.rt_surface.surface.childExited(value),
        };
    }
    pub fn showGtkInspector() void {
        gtk.Window.setInteractiveDebugging(@intFromBool(true));
    }
    pub fn sizeLimit(
        target: apprt.Target,
        value: apprt.action.SizeLimit,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                surface.setMinSize(.{
                    .width = value.min_width,
                    .height = value.min_height,
                });
                return true;
            },
        }
    }
    pub fn toggleFullscreen(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.toggleFullscreen(),
        }
    }
    pub fn toggleQuickTerminal(self: *Application) bool {
        if (getQuickTerminalWindow()) |win| {
            win.toggleVisibility();
            return true;
        }
        const priv = self.private();
        if (!priv.winproto.supportsQuickTerminal()) return false;
        const win = gobject.ext.newInstance(Window, .{
            .application = self,
            .@"quick-terminal" = true,
        });
        assert(win.isQuickTerminal());
        initAndShowWindow(self, win, null, .none);
        return true;
    }
    pub fn toggleSplitZoom(target: apprt.Target) bool {
        switch (target) {
            .app => {
                log.warn("toggle_split_zoom to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const tree = ext.getAncestor(
                    SplitTree,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a split tree, ignoring toggle_split_zoom", .{});
                    return false;
                };
                if (!tree.getIsSplit()) return false;
                return surface.as(gtk.Widget).activateAction("split-tree.zoom", null) != 0;
            },
        }
    }
    pub fn showOnScreenKeyboard(target: apprt.Target) bool {
        switch (target) {
            .app => {
                log.warn("show_on_screen_keyboard to app is unexpected", .{});
                return false;
            },
            .surface => |v| return v.rt_surface.surface.showOnScreenKeyboard(null),
        }
    }
    fn getQuickTerminalWindow() ?*Window {
        const list = gtk.Window.listToplevels();
        defer list.free();
        if (ext.listFind(gtk.Window, list, struct {
            fn find(gtk_win: *gtk.Window) bool {
                const win = gobject.ext.cast(
                    Window,
                    gtk_win,
                ) orelse return false;
                return win.isQuickTerminal();
            }
        }.find)) |w| return gobject.ext.cast(
            Window,
            w,
        ).?;
        return null;
    }
    pub fn toggleMaximize(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.toggleMaximize(),
        }
    }
    pub fn toggleTabOverview(target: apprt.Target) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring new_tab", .{});
                    return false;
                };
                window.toggleTabOverview();
                return true;
            },
        }
    }
    pub fn toggleWindowDecorations(target: apprt.Target) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring toggle_window_decorations", .{});
                    return false;
                };
                window.toggleWindowDecorations();
                return true;
            },
        }
    }
    pub fn toggleCommandPalette(target: apprt.Target) bool {
        switch (target) {
            .app => return false,
            .surface => |surface| {
                return surface.rt_surface.gobj().toggleCommandPalette();
            },
        }
    }
    pub fn controlInspector(target: apprt.Target, value: apprt.Action.Value(.inspector)) bool {
        switch (target) {
            .app => return false,
            .surface => |surface| {
                return surface.rt_surface.gobj().controlInspector(value);
            },
        }
    }
    pub fn commandFinished(target: apprt.Target, value: apprt.Action.Value(.command_finished)) bool {
        switch (target) {
            .app => return false,
            .surface => |surface| {
                return surface.rt_surface.gobj().commandFinished(value);
            },
        }
    }
    pub fn setReadonly(target: apprt.Target, value: apprt.Action.Value(.readonly)) bool {
        switch (target) {
            .app => return false,
            .surface => |surface| {
                return surface.rt_surface.gobj().setReadonly(value);
            },
        }
    }
    pub fn keySequence(target: apprt.Target, value: apprt.Action.Value(.key_sequence)) bool {
        switch (target) {
            .app => {
                log.warn("key_sequence action to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                core.rt_surface.gobj().keySequenceAction(value) catch |err| {
                    log.warn("error handling key_sequence action: {}", .{err});
                };
                return true;
            },
        }
    }
    pub fn keyTable(target: apprt.Target, value: apprt.Action.Value(.key_table)) bool {
        switch (target) {
            .app => {
                log.warn("key_table action to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                core.rt_surface.gobj().keyTableAction(value) catch |err| {
                    log.warn("error handling key_table action: {}", .{err});
                };
                return true;
            },
        }
    }
};
fn setGtkEnv(config: *const CoreConfig) std.Io.Writer.Error!void {
    assert(gtk.isInitialized() == 0);
    const gdk_debug: struct {
        opengl: bool = false,
    } = .{
        .opengl = global.logging().stderr and config.@"gtk-opengl-debug",
    };
    const gdk_disable: struct {
        vulkan: bool = true,
    } = .{};
    {
        var buf: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        var first: bool = true;
        inline for (@typeInfo(@TypeOf(gdk_debug)).@"struct".fields) |field| {
            if (@field(gdk_debug, field.name)) {
                if (!first) try writer.writeAll(",");
                try writer.writeAll(field.name);
                first = false;
            }
        }
        try writer.writeByte(0);
        const value = writer.buffered();
        log.warn("setting GDK_DEBUG={s}", .{value[0 .. value.len - 1]});
        _ = setenv("GDK_DEBUG", @ptrCast(value[0 .. value.len - 1 :0]), 1);
    }
    {
        var buf: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        var first: bool = true;
        inline for (@typeInfo(@TypeOf(gdk_disable)).@"struct".fields) |field| {
            if (@field(gdk_disable, field.name)) {
                if (!first) try writer.writeAll(",");
                try writer.writeAll(field.name);
                first = false;
            }
        }
        try writer.writeByte(0);
        const value = writer.buffered();
        log.warn("setting GDK_DISABLE={s}", .{value[0 .. value.len - 1]});
        _ = setenv("GDK_DISABLE", @ptrCast(value[0 .. value.len - 1 :0]), 1);
    }
    global.syncEnviron();
}
fn findActiveWindow(data: ?*const anyopaque, _: ?*const anyopaque) callconv(.c) c_int {
    const window: *gtk.Window = @ptrCast(@alignCast(@constCast(data orelse return -1)));
    return if (window.isActive() != 0) 0 else -1;
}
