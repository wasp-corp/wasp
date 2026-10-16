const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const gdk = @import("gdk");
const gdk_x11 = @import("gdk_x11");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const xlib = @import("xlib");
pub const c = @import("x11_c");
const input = @import("../../../input.zig");
const Config = @import("../../../config.zig").Config;
const ApprtWindow = @import("../class/window.zig").Window;
const GlobalShortcuts = @import("../class/global_shortcuts.zig").GlobalShortcuts;
const BlurRegion = @import("BlurRegion.zig");
const log = std.log.scoped(.gtk_x11);
pub const App = struct {
    display: *xlib.Display,
    base_event_code: c_int,
    atoms: Atoms,
    pub fn init(
        _: Allocator,
        gdk_display: *gdk.Display,
        app_id: [:0]const u8,
        config: *const Config,
    ) !?App {
        const gdk_x11_display = gobject.ext.cast(
            gdk_x11.X11Display,
            gdk_display,
        ) orelse return null;
        const xlib_display = gdk_x11_display.getXdisplay();
        const x11_program_name: [:0]const u8 = if (config.@"x11-instance-name") |pn|
            pn
        else if (builtin.mode == .Debug)
            "wasp-debug"
        else
            "wasp";
        glib.setPrgname(x11_program_name);
        gdk_x11.X11Display.setProgramClass(gdk_display, app_id);
        log.debug("Xkb.init: initializing Xkb", .{});
        log.debug("Xkb.init: running XkbQueryExtension", .{});
        var opcode: c_int = 0;
        var base_event_code: c_int = 0;
        var base_error_code: c_int = 0;
        var major = c.XkbMajorVersion;
        var minor = c.XkbMinorVersion;
        if (c.XkbQueryExtension(
            @ptrCast(@alignCast(xlib_display)),
            &opcode,
            &base_event_code,
            &base_error_code,
            &major,
            &minor,
        ) == 0) {
            log.err("Fatal: error initializing Xkb extension: error executing XkbQueryExtension", .{});
            return error.XkbInitializationError;
        }
        log.debug("Xkb.init: running XkbSelectEventDetails", .{});
        if (c.XkbSelectEventDetails(
            @ptrCast(@alignCast(xlib_display)),
            c.XkbUseCoreKbd,
            c.XkbStateNotify,
            c.XkbModifierStateMask,
            c.XkbModifierStateMask,
        ) == 0) {
            log.err("Fatal: error initializing Xkb extension: error executing XkbSelectEventDetails", .{});
            return error.XkbInitializationError;
        }
        return .{
            .display = xlib_display,
            .base_event_code = base_event_code,
            .atoms = .init(gdk_x11_display),
        };
    }
    pub fn deinit(self: *App) void {
        _ = self;
    }
    pub fn eventMods(
        self: App,
        device: ?*gdk.Device,
        gtk_mods: gdk.ModifierType,
    ) ?input.Mods {
        _ = device;
        _ = gtk_mods;
        if (c.XEventsQueued(
            @ptrCast(@alignCast(self.display)),
            c.QueuedAfterReading,
        ) == 0) return null;
        var nextEvent: c.XEvent = undefined;
        _ = c.XPeekEvent(@ptrCast(@alignCast(self.display)), &nextEvent);
        if (nextEvent.type != self.base_event_code) return null;
        const xkb_event: *c.XkbEvent = @ptrCast(&nextEvent);
        if (xkb_event.any.xkb_type != c.XkbStateNotify) return null;
        const xkb_state_notify_event: *c.XkbStateNotifyEvent = @ptrCast(xkb_event);
        const lookup_mods = xkb_state_notify_event.lookup_mods;
        var mods: input.Mods = .{};
        log.debug("X11: found extra XkbStateNotify event w/lookup_mods: {b}", .{lookup_mods});
        if (lookup_mods & c.ShiftMask != 0) mods.shift = true;
        if (lookup_mods & c.ControlMask != 0) mods.ctrl = true;
        if (lookup_mods & c.Mod1Mask != 0) mods.alt = true;
        if (lookup_mods & c.Mod4Mask != 0) mods.super = true;
        if (lookup_mods & c.LockMask != 0) mods.caps_lock = true;
        return mods;
    }
    pub fn bindGlobalShortcuts(
        _: *App,
        _: *GlobalShortcuts,
        _: *const Config,
    ) bool {
        return false;
    }
    pub fn clearGlobalShortcuts(_: *App) void {}
    pub fn supportsQuickTerminal(_: App) bool {
        log.warn("quick terminal is not yet supported on X11", .{});
        return false;
    }
    pub fn initQuickTerminal(_: *App, _: *ApprtWindow) !void {}
};
pub const Window = struct {
    app: *App,
    apprt_window: *ApprtWindow,
    x11_surface: *gdk_x11.X11Surface,
    alloc: Allocator,
    blur_region: BlurRegion = .empty,
    last_applied_decoration_hints: ?MotifWMHints = null,
    pub fn init(
        alloc: Allocator,
        app: *App,
        apprt_window: *ApprtWindow,
    ) !Window {
        const surface = apprt_window.as(gtk.Native).getSurface() orelse
            return error.NotX11Surface;
        const x11_surface = gobject.ext.cast(
            gdk_x11.X11Surface,
            surface,
        ) orelse return error.NotX11Surface;
        return .{
            .app = app,
            .alloc = alloc,
            .apprt_window = apprt_window,
            .x11_surface = x11_surface,
        };
    }
    pub fn deinit(self: *Window) void {
        self.blur_region.deinit(self.alloc);
    }
    pub fn resizeEvent(self: *Window) !void {
        self.syncBlur() catch |err| {
            log.err("failed to sync blur={}", .{err});
        };
    }
    pub fn syncAppearance(self: *Window) !void {
        self.syncBlur() catch |err| {
            log.err("failed to sync blur={}", .{err});
        };
        self.syncDecorations() catch |err| {
            log.err("failed to sync decorations={}", .{err});
        };
    }
    pub fn clientSideDecorationEnabled(self: Window) bool {
        return switch (self.apprt_window.getWindowDecoration()) {
            .auto, .client => true,
            .server, .none => false,
        };
    }
    fn syncBlur(self: *Window) !void {
        const config = if (self.apprt_window.getConfig()) |v| v.get() else return;
        const blur = config.@"background-blur";
        var region: BlurRegion = if (blur.enabled())
            try .calcForWindow(
                self.alloc,
                self.apprt_window,
                self.clientSideDecorationEnabled(),
                true,
            )
        else
            .empty;
        errdefer region.deinit(self.alloc);
        if (region.eql(self.blur_region)) {
            region.deinit(self.alloc);
            return;
        }
        if (region.slices.items.len > 0) {
            log.debug("set blur={}, window xid={}, region={}", .{
                blur,
                self.x11_surface.getXid(),
                region,
            });
            try self.changeProperty(
                BlurRegion.Slice,
                self.app.atoms.kde_blur,
                c.XA_CARDINAL,
                ._32,
                .{ .mode = .replace },
                region.slices.items,
            );
        } else {
            try self.deleteProperty(self.app.atoms.kde_blur);
        }
        self.blur_region.deinit(self.alloc);
        self.blur_region = region;
    }
    fn syncDecorations(self: *Window) !void {
        var hints: MotifWMHints = .{};
        self.getWindowProperty(
            MotifWMHints,
            self.app.atoms.motif_wm_hints,
            self.app.atoms.motif_wm_hints,
            ._32,
            .{},
            &hints,
        ) catch |err| switch (err) {
            error.PropertyNotFound => {},
            error.RequestFailed,
            error.PropertyTypeMismatch,
            error.PropertyFormatMismatch,
            => return err,
        };
        hints.flags.decorations = true;
        hints.decorations.all = switch (self.apprt_window.getWindowDecoration()) {
            .server => true,
            .auto, .client, .none => false,
        };
        if (self.last_applied_decoration_hints) |last| {
            if (std.meta.eql(hints, last)) return;
        }
        try self.changeProperty(
            MotifWMHints,
            self.app.atoms.motif_wm_hints,
            self.app.atoms.motif_wm_hints,
            ._32,
            .{ .mode = .replace },
            &.{hints},
        );
        self.last_applied_decoration_hints = hints;
    }
    pub fn addSubprocessEnv(self: *Window, env: *std.process.Environ.Map) !void {
        var buf: [64]u8 = undefined;
        const window_id = try std.fmt.bufPrint(
            &buf,
            "{}",
            .{self.x11_surface.getXid()},
        );
        try env.put("WINDOWID", window_id);
    }
    pub fn setUrgent(self: *Window, urgent: bool) !void {
        self.x11_surface.setUrgencyHint(@intFromBool(urgent));
    }
    fn getWindowProperty(
        self: *Window,
        comptime T: type,
        name: c.Atom,
        typ: c.Atom,
        comptime format: PropertyFormat,
        options: struct {
            offset: c_long = 0,
            length: c_long = std.math.maxInt(c_long),
            delete: bool = false,
        },
        result: *T,
    ) GetWindowPropertyError!void {
        var actual_type_return: c.Atom = undefined;
        var actual_format_return: c_int = undefined;
        var nitems_return: c_ulong = undefined;
        var bytes_after_return: c_ulong = undefined;
        var prop_return: ?format.bufferType() = null;
        const code = c.XGetWindowProperty(
            @ptrCast(@alignCast(self.app.display)),
            self.x11_surface.getXid(),
            name,
            options.offset,
            options.length,
            @intFromBool(options.delete),
            typ,
            &actual_type_return,
            &actual_format_return,
            &nitems_return,
            &bytes_after_return,
            @ptrCast(&prop_return),
        );
        if (code != c.Success) return error.RequestFailed;
        if (actual_type_return == c.None) return error.PropertyNotFound;
        if (typ != actual_type_return) return error.PropertyTypeMismatch;
        if (@intFromEnum(format) != actual_format_return) return error.PropertyFormatMismatch;
        const data_ptr: *T = @ptrCast(prop_return);
        result.* = data_ptr.*;
        _ = c.XFree(prop_return);
    }
    fn changeProperty(
        self: *Window,
        comptime T: type,
        name: c.Atom,
        typ: c.Atom,
        comptime format: PropertyFormat,
        options: struct {
            mode: PropertyChangeMode,
        },
        values: []const T,
    ) X11Error!void {
        const data: format.bufferType() = @ptrCast(@constCast(values));
        const words_per_elem = @divExact(@sizeOf(T), @sizeOf(format.elemType()));
        const status = c.XChangeProperty(
            @ptrCast(@alignCast(self.app.display)),
            self.x11_surface.getXid(),
            name,
            typ,
            @intFromEnum(format),
            @intFromEnum(options.mode),
            data,
            @intCast(words_per_elem * values.len),
        );
        if (status == 0) return error.RequestFailed;
    }
    fn deleteProperty(self: *Window, name: c.Atom) X11Error!void {
        const status = c.XDeleteProperty(
            @ptrCast(@alignCast(self.app.display)),
            self.x11_surface.getXid(),
            name,
        );
        if (status == 0) return error.RequestFailed;
    }
};
const X11Error = error{
    RequestFailed,
};
const GetWindowPropertyError = X11Error || error{
    PropertyNotFound,
    PropertyTypeMismatch,
    PropertyFormatMismatch,
};
const Atoms = struct {
    kde_blur: c.Atom,
    motif_wm_hints: c.Atom,
    fn init(display: *gdk_x11.X11Display) Atoms {
        return .{
            .kde_blur = gdk_x11.x11GetXatomByNameForDisplay(
                display,
                "_KDE_NET_WM_BLUR_BEHIND_REGION",
            ),
            .motif_wm_hints = gdk_x11.x11GetXatomByNameForDisplay(
                display,
                "_MOTIF_WM_HINTS",
            ),
        };
    }
};
const PropertyChangeMode = enum(c_int) {
    replace = c.PropModeReplace,
    prepend = c.PropModePrepend,
    append = c.PropModeAppend,
};
const PropertyFormat = enum(c_int) {
    _8 = 8,
    _16 = 16,
    _32 = 32,
    fn elemType(comptime self: PropertyFormat) type {
        return switch (self) {
            ._8 => c_char,
            ._16 => c_int,
            ._32 => c_long,
        };
    }
    fn bufferType(comptime self: PropertyFormat) type {
        return [*]align(@alignOf(self.elemType())) u8;
    }
};
const MotifWMHints = extern struct {
    flags: packed struct(c_ulong) {
        _pad: u1 = 0,
        decorations: bool = false,
        _rest: std.meta.Int(.unsigned, @bitSizeOf(c_ulong) - 2) = 0,
    } = .{},
    functions: c_ulong = 0,
    decorations: packed struct(c_ulong) {
        all: bool = false,
        _rest: std.meta.Int(.unsigned, @bitSizeOf(c_ulong) - 1) = 0,
    } = .{},
    input_mode: c_long = 0,
    status: c_ulong = 0,
};
