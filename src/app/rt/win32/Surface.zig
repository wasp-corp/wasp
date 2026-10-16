const Surface = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../../root.zig");
const configpkg = @import("../../../config.zig");
const input = @import("../../../input.zig");
const terminal = @import("../../../terminal/main.zig");
const termio = @import("../../../termio.zig");
const CoreSurface = @import("../../../Surface.zig");
const internal_os = @import("../../../os/root.zig");
const global = @import("../../../global.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const w32 = @import("win32.zig");
const Scrollbar = @import("Scrollbar.zig").Scrollbar;
const log = std.log.scoped(.win32);
hwnd: ?w32.HWND = null,
hdc: ?w32.HDC = null,
hglrc: ?w32.HGLRC = null,
width: u32 = 800,
height: u32 = 600,
scale: f32 = 1.0,
app: *App,
parent_window: *Window = undefined,
title_len: usize = 0,
title: [4096]u8 = std.mem.zeroes([4096]u8),
core_surface: CoreSurface = undefined,
core_surface_ready: bool = false,
core_surface_initialized: bool = false,
high_surrogate: u16 = 0,
mouse_button_mask: u3 = 0,
ime_composing: bool = false,
key_event_produced_text: bool = false,
in_live_resize: bool = false,
frame_event: ?w32.HANDLE = null,
scrollbar: ?*Scrollbar = null,
current_cursor: ?w32.HCURSOR = null,
mouse_visible: bool = true,
search_hwnd: ?w32.HWND = null,
search_edit: ?w32.HWND = null,
search_active: bool = false,
search_font: ?*anyopaque = null,
search_count_label: ?w32.HWND = null,
link_preview_hwnd: ?w32.HWND = null,
link_font: ?*anyopaque = null,
search_total: ?usize = null,
search_selected: ?usize = null,
last_reported_visible: ?bool = null,
palette_hwnd: ?w32.HWND = null,
palette_edit: ?w32.HWND = null,
palette_font: ?*anyopaque = null,
palette_paint_font: ?*anyopaque = null,
palette_brush: ?w32.HBRUSH = null,
palette_active: bool = false,
palette_selected: u16 = 0,
palette_count: u16 = 0,
palette_filtered: [palette_entries.len + MAX_USER_PALETTE_ENTRIES]u16 = undefined,
ref_count: u32 = 0,
leaked: bool = false,
pub fn ref(self: *Surface, alloc: Allocator) Allocator.Error!*Surface {
    _ = alloc;
    self.ref_count += 1;
    return self;
}
pub fn unref(self: *Surface, alloc: Allocator) void {
    self.ref_count -= 1;
    if (self.ref_count == 0) {
        if (self.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
        self.deinit();
        if (!self.leaked) alloc.destroy(self);
    }
}
pub fn eql(self: *const Surface, other: *const Surface) bool {
    return self == other;
}
pub fn init(
    self: *Surface,
    app: *App,
    parent: *Window,
    context: apprt.surface.NewSurfaceContext,
) !void {
    return self.initWithOptions(app, parent, .{ .context = context });
}
pub const InitOptions = struct {
    context: apprt.surface.NewSurfaceContext,
    command: ?*const configpkg.Command = null,
    title: ?[:0]const u8 = null,
};
pub fn initWithOptions(
    self: *Surface,
    app: *App,
    parent: *Window,
    options: InitOptions,
) !void {
    self.* = .{
        .app = app,
        .parent_window = parent,
    };
    self.frame_event = w32.CreateEventW(null, 1, 0, null);
    const parent_hwnd = parent.hwnd orelse return error.Win32Error;
    const sr = parent.surfaceRect();
    const hwnd = w32.CreateWindowExW(
        0,
        App.TERMINAL_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD,
        sr.left,
        sr.top,
        @intCast(@max(sr.right - sr.left, 1)),
        @intCast(@max(sr.bottom - sr.top, 1)),
        parent_hwnd,
        null,
        app.hinstance,
        null,
    ) orelse return error.Win32Error;
    self.hwnd = hwnd;
    errdefer {
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }
    w32.DragAcceptFiles(hwnd, 1);
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.hdc = w32.GetDC(hwnd);
    if (self.hdc == null) return error.Win32Error;
    errdefer {
        _ = w32.ReleaseDC(hwnd, self.hdc.?);
        self.hdc = null;
    }
    try self.setupPixelFormat();
    self.hglrc = w32.wglCreateContext(self.hdc.?);
    if (self.hglrc == null) return error.Win32Error;
    errdefer {
        _ = w32.wglMakeCurrent(null, null);
        _ = w32.wglDeleteContext(self.hglrc.?);
        self.hglrc = null;
    }
    self.updateDpiScale();
    self.updateClientSize();
    log.debug("Win32 surface created: {}x{} scale={d:.2}", .{
        self.width,
        self.height,
        self.scale,
    });
    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.UpdateWindow(hwnd);
    const alloc = app.core_app.alloc;
    self.scrollbar = try Scrollbar.create(alloc, hwnd, self);
    errdefer if (self.scrollbar) |sb| {
        sb.destroy();
        self.scrollbar = null;
    };
    if (self.scrollbar) |sb| {
        sb.setTheme(
            app.config.background.toTerminalRGB(),
            app.config.foreground.toTerminalRGB(),
        );
    }
    try app.core_app.addSurface(self);
    errdefer app.core_app.deleteSurface(self);
    var config = try apprt.surface.newConfig(app.core_app, &app.config, options.context);
    defer config.deinit();
    if (options.command) |command| {
        config.command = try command.clone(config.arenaAlloc());
        config.@"shell-integration" = .detect;
    }
    if (options.title) |title| {
        config.title = try config.arenaAlloc().dupeZ(u8, title);
    }
    try self.core_surface.init(
        alloc,
        &config,
        app.core_app,
        app,
        self,
    );
    self.core_surface_ready = true;
    self.core_surface_initialized = true;
}
pub fn deinit(self: *Surface) void {
    log.debug("surface deinit: start addr={x}", .{@intFromPtr(self)});
    if (self.core_surface_initialized) {
        log.debug("surface deinit: core_surface.deinit start", .{});
        self.core_surface.deinit();
        log.debug("surface deinit: core_surface.deinit done", .{});
        self.app.core_app.deleteSurface(self);
        log.debug("surface deinit: deleteSurface done", .{});
        if (self.core_surface.deinit_leaked) {
            self.leaked = true;
            self.deinitGui();
            return;
        }
    }
    if (self.frame_event) |event| {
        _ = w32.CloseHandle(event);
        self.frame_event = null;
    }
    log.debug("surface deinit: frame_event closed", .{});
    if (self.hglrc) |hglrc| {
        log.debug("surface deinit: wglMakeCurrent(null)", .{});
        _ = w32.wglMakeCurrent(null, null);
        log.debug("surface deinit: wglDeleteContext", .{});
        _ = w32.wglDeleteContext(hglrc);
        self.hglrc = null;
    }
    log.debug("surface deinit: GL context cleaned up", .{});
    if (self.hdc) |hdc| {
        if (self.hwnd) |hwnd| {
            log.debug("surface deinit: ReleaseDC", .{});
            _ = w32.ReleaseDC(hwnd, hdc);
        }
        self.hdc = null;
    }
    log.debug("surface deinit: DC released", .{});
    self.deinitGui();
}
fn deinitGui(self: *Surface) void {
    if (self.scrollbar) |sb| {
        sb.destroy();
        self.scrollbar = null;
    }
    if (self.search_hwnd) |popup| {
        _ = w32.DestroyWindow(popup);
        self.search_hwnd = null;
        self.search_edit = null;
        self.search_count_label = null;
    }
    if (self.search_font) |f| {
        _ = w32.DeleteObject(f);
        self.search_font = null;
    }
    if (self.link_preview_hwnd) |h| {
        _ = w32.DestroyWindow(h);
        self.link_preview_hwnd = null;
    }
    if (self.link_font) |f| {
        _ = w32.DeleteObject(f);
        self.link_font = null;
    }
    if (self.palette_hwnd) |popup| {
        _ = w32.DestroyWindow(popup);
        self.palette_hwnd = null;
        self.palette_edit = null;
    }
    if (self.palette_font) |f| {
        _ = w32.DeleteObject(f);
        self.palette_font = null;
    }
    if (self.palette_brush) |b| {
        _ = w32.DeleteObject(b);
        self.palette_brush = null;
    }
    if (self.palette_paint_font) |f| {
        _ = w32.DeleteObject(f);
        self.palette_paint_font = null;
    }
    if (self.hwnd) |hwnd| {
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
    }
    self.hwnd = null;
    log.debug("surface deinit: complete", .{});
}
pub fn recreateGLContext(self: *Surface) !void {
    const hdc = self.hdc orelse return error.Win32Error;
    const new = w32.wglCreateContext(hdc) orelse return error.Win32Error;
    _ = w32.wglMakeCurrent(null, null);
    if (self.hglrc) |old| _ = w32.wglDeleteContext(old);
    self.hglrc = new;
    if (w32.wglMakeCurrent(hdc, new) == 0) return error.Win32Error;
}
fn setupPixelFormat(self: *Surface) !void {
    const pfd = w32.PIXELFORMATDESCRIPTOR{
        .nSize = @sizeOf(w32.PIXELFORMATDESCRIPTOR),
        .nVersion = 1,
        .dwFlags = w32.PFD_DRAW_TO_WINDOW | w32.PFD_SUPPORT_OPENGL | w32.PFD_DOUBLEBUFFER,
        .iPixelType = w32.PFD_TYPE_RGBA,
        .cColorBits = 32,
        .cRedBits = 0,
        .cRedShift = 0,
        .cGreenBits = 0,
        .cGreenShift = 0,
        .cBlueBits = 0,
        .cBlueShift = 0,
        .cAlphaBits = 8,
        .cAlphaShift = 0,
        .cAccumBits = 0,
        .cAccumRedBits = 0,
        .cAccumGreenBits = 0,
        .cAccumBlueBits = 0,
        .cAccumAlphaBits = 0,
        .cDepthBits = 24,
        .cStencilBits = 8,
        .cAuxBuffers = 0,
        .iLayerType = 0,
        .bReserved = 0,
        .dwLayerMask = 0,
        .dwVisibleMask = 0,
        .dwDamageMask = 0,
    };
    const format = w32.ChoosePixelFormat(self.hdc.?, &pfd);
    if (format == 0) return error.Win32Error;
    if (w32.SetPixelFormat(self.hdc.?, format, &pfd) == 0)
        return error.Win32Error;
}
fn updateDpiScale(self: *Surface) void {
    if (self.hwnd) |hwnd| {
        const dpi = w32.GetDpiForWindow(hwnd);
        if (dpi != 0) {
            self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
        }
    }
}
fn updateClientSize(self: *Surface) void {
    if (self.hwnd) |hwnd| {
        var rect: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &rect) != 0) {
            self.width = @intCast(rect.right - rect.left);
            self.height = @intCast(rect.bottom - rect.top);
        }
    }
}
pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
    return .{ .x = self.scale, .y = self.scale };
}
pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
    return .{ .width = self.width, .height = self.height };
}
pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
    if (self.hwnd) |hwnd| {
        var point: w32.POINT = undefined;
        if (w32.GetCursorPos_(&point) != 0) {
            _ = w32.ScreenToClient(hwnd, &point);
            return .{
                .x = @floatFromInt(point.x),
                .y = @floatFromInt(point.y),
            };
        }
    }
    return error.GetCursorPosFailed;
}
pub fn getTitle(self: *const Surface) ?[:0]const u8 {
    if (self.title_len == 0) return null;
    return self.title[0..self.title_len :0];
}
pub fn setVisible(self: *Surface, visible: bool) void {
    if (!visible) {
        if (self.link_preview_hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
    }
    if (!self.core_surface_ready) return;
    if (self.last_reported_visible == visible) return;
    self.last_reported_visible = visible;
    self.core_surface.occlusionCallback(visible) catch |err| {
        self.last_reported_visible = null;
        log.warn("occlusionCallback failed err={}", .{err});
    };
}
pub fn close(self: *Surface, process_active: bool) void {
    log.debug("Surface.close called process_active={}", .{process_active});
    if (process_active) {
        const parent_hwnd = self.parent_window.hwnd;
        const result = w32.MessageBoxW(
            parent_hwnd,
            std.unicode.utf8ToUtf16LeStringLiteral(
                "A process is still running in this terminal.\nClose anyway?",
            ),
            std.unicode.utf8ToUtf16LeStringLiteral("Wasp"),
            w32.MB_OKCANCEL | w32.MB_ICONWARNING | w32.MB_DEFBUTTON2,
        );
        if (result != w32.IDOK) return;
    }
    if (self.hwnd) |hwnd| {
        _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
    }
}
pub fn supportsClipboard(
    self: *const Surface,
    clipboard_type: apprt.Clipboard,
) bool {
    _ = self;
    return switch (clipboard_type) {
        .standard => true,
        .selection, .primary => false,
    };
}
fn normalizeWindowsClipboardNewlines(data: []u8) []u8 {
    var read_idx: usize = 0;
    var write_idx: usize = 0;
    while (read_idx < data.len) {
        if (data[read_idx] == '\r' and
            read_idx + 1 < data.len and
            data[read_idx + 1] == '\n')
        {
            data[write_idx] = '\n';
            read_idx += 2;
        } else {
            data[write_idx] = data[read_idx];
            read_idx += 1;
        }
        write_idx += 1;
    }
    return data[0..write_idx];
}
test "normalize Windows clipboard newlines" {
    var data = "one\r\ntwo\r\n\r\nthree\rfour\n".*;
    const normalized = normalizeWindowsClipboardNewlines(data[0..]);
    try std.testing.expectEqualStrings("one\ntwo\n\nthree\rfour\n", normalized);
}
fn confirmClipboard(
    self: *Surface,
    comptime message: [:0]const u8,
    comptime title: [:0]const u8,
) bool {
    const result = w32.MessageBoxW(
        self.parent_window.hwnd,
        std.unicode.utf8ToUtf16LeStringLiteral(message),
        std.unicode.utf8ToUtf16LeStringLiteral(title),
        w32.MB_OKCANCEL | w32.MB_ICONWARNING | w32.MB_DEFBUTTON2,
    );
    return result == w32.IDOK;
}
pub fn clipboardRequest(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !apprt.ClipboardReadResult {
    if (clipboard_type != .standard) return .unsupported;
    if (state == .kitty_write) {
        return self.completeClipboardRequestWithConfirmation(
            state,
            &.{},
            &.{},
        );
    }
    if (state == .list) {
        if (w32.OpenClipboard(self.hwnd) == 0) {
            log.warn("OpenClipboard failed", .{});
            return .unavailable;
        }
        defer _ = w32.CloseClipboard();
        if (w32.GetClipboardData(w32.CF_HDROP) == null and
            w32.GetClipboardData(w32.CF_UNICODETEXT) == null)
        {
            return .unavailable;
        }
        return self.completeClipboardRequestWithConfirmation(
            state,
            &.{},
            &.{"text/plain"},
        );
    }
    const alloc = self.app.core_app.alloc;
    const utf8z: [:0]const u8 = blk: {
        if (w32.OpenClipboard(self.hwnd) == 0) {
            log.warn("OpenClipboard failed", .{});
            return .unavailable;
        }
        defer _ = w32.CloseClipboard();
        if (w32.GetClipboardData(w32.CF_HDROP)) |hdrop_handle| hdrop: {
            const paths = (try hdropPathsToUtf8(alloc, @ptrCast(hdrop_handle))) orelse
                break :hdrop;
            defer alloc.free(paths);
            break :blk try alloc.dupeZ(u8, paths);
        }
        const hglobal = w32.GetClipboardData(w32.CF_UNICODETEXT) orelse
            return .unavailable;
        const ptr16 = w32.GlobalLock(hglobal) orelse {
            log.warn("GlobalLock failed", .{});
            return .unavailable;
        };
        defer _ = w32.GlobalUnlock(hglobal);
        const wptr: [*]const u16 = @ptrCast(@alignCast(ptr16));
        var wlen: usize = 0;
        while (wptr[wlen] != 0) wlen += 1;
        const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, wptr[0..wlen]) catch |err| {
            log.warn("utf16LeToUtf8Alloc failed: {}", .{err});
            return .unavailable;
        };
        defer alloc.free(utf8);
        break :blk try alloc.dupeZ(
            u8,
            normalizeWindowsClipboardNewlines(utf8),
        );
    };
    defer alloc.free(utf8z);
    return self.completeClipboardRequestWithConfirmation(
        state,
        &.{.{ .mime = "text/plain", .data = utf8z }},
        &.{},
    );
}
fn completeClipboardRequestWithConfirmation(
    self: *Surface,
    state: apprt.ClipboardRequest,
    contents: []const terminal.clipboard.Content,
    available: []const []const u8,
) apprt.ClipboardReadResult {
    const core_app = self.app.core_app;
    const surface_id = self.core_surface.id;
    self.core_surface.completeClipboardRequest(state, .{
        .contents = contents,
        .available = available,
    }) catch |err| {
        const approved = switch (err) {
            error.UnsafePaste => self.confirmClipboard(
                "The text being pasted contains characters that could run " ++
                    "commands unexpectedly (for example, newlines).\n\nPaste anyway?",
                "Wasp \u{2014} Potentially Unsafe Paste",
            ),
            error.UnauthorizedPaste => switch (state) {
                .kitty_write, .osc_52_write => self.confirmClipboard(
                    "An application is requesting to write to the system clipboard.\n\nAllow this?",
                    "Wasp \u{2014} Authorize Clipboard Access",
                ),
                else => self.confirmClipboard(
                    "An application is requesting access to read the clipboard.\n\nAllow this?",
                    "Wasp \u{2014} Authorize Clipboard Access",
                ),
            },
            else => {
                log.err("completeClipboardRequest error: {}", .{err});
                return .started;
            },
        };
        const cs = core_app.findSurfaceByID(surface_id) orelse {
            switch (state) {
                .kitty_read => |kitty| kitty.destroy(),
                .kitty_write => |kitty| kitty.destroy(),
                else => {},
            }
            return .started;
        };
        if (approved) {
            cs.completeClipboardRequest(state, .{
                .contents = contents,
                .available = available,
                .confirmed = true,
            }) catch |e| {
                log.err("completeClipboardRequest (confirmed) error: {}", .{e});
            };
        } else {
            cs.denyClipboardRequest(state);
        }
    };
    return .started;
}
pub fn setClipboard(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    if (clipboard_type != .standard) return;
    const app = self.app;
    if (confirm) {
        if (!self.confirmClipboard(
            "An application is requesting to write to the system clipboard.\n\nAllow this?",
            "Wasp \u{2014} Authorize Clipboard Access",
        )) return;
    }
    const text = blk: {
        for (contents) |c| {
            if (std.mem.eql(u8, c.mime, "text/plain")) break :blk c.data;
        }
        return;
    };
    const alloc = app.core_app.alloc;
    const utf16 = try std.unicode.utf8ToUtf16LeAlloc(alloc, text);
    defer alloc.free(utf16);
    const byte_size = (utf16.len + 1) * @sizeOf(u16);
    const hglobal = w32.GlobalAlloc(w32.GMEM_MOVEABLE, byte_size) orelse {
        log.warn("GlobalAlloc failed for clipboard write", .{});
        return;
    };
    const dst_bytes = w32.GlobalLock(hglobal) orelse {
        log.warn("GlobalLock failed for clipboard write", .{});
        _ = w32.GlobalFree(hglobal);
        return;
    };
    const dst16: [*]u16 = @ptrCast(@alignCast(dst_bytes));
    @memcpy(dst16[0..utf16.len], utf16);
    dst16[utf16.len] = 0;
    _ = w32.GlobalUnlock(hglobal);
    if (w32.OpenClipboard(null) == 0) {
        log.warn("OpenClipboard failed for clipboard write", .{});
        _ = w32.GlobalFree(hglobal);
        return;
    }
    defer _ = w32.CloseClipboard();
    _ = w32.EmptyClipboard();
    if (w32.SetClipboardData(w32.CF_UNICODETEXT, hglobal) == null) {
        log.warn("SetClipboardData failed", .{});
        _ = w32.GlobalFree(hglobal);
    }
}
pub fn defaultTermioEnv(self: *const Surface) !std.process.Environ.Map {
    _ = self;
    const env = try global.environMap();
    return env;
}
pub fn setTitle(self: *Surface, title: [:0]const u8) void {
    const len = @min(title.len, self.title.len - 1);
    @memcpy(self.title[0..len], title[0..len]);
    self.title[len] = 0;
    self.title_len = len;
    self.parent_window.onTabTitleChanged(self, title);
}
pub fn toggleFullscreen(self: *Surface) void {
    self.parent_window.toggleFullscreen();
}
pub fn setMouseShape(self: *Surface, shape: terminal.MouseShape) void {
    const cursor = switch (shape) {
        .text => w32.LoadCursorW(null, w32.IDC_IBEAM),
        .pointer => w32.LoadCursorW(null, w32.IDC_HAND),
        .crosshair => w32.LoadCursorW(null, w32.IDC_CROSS),
        .e_resize, .w_resize, .ew_resize => w32.LoadCursorW(null, w32.IDC_SIZEWE),
        .n_resize, .s_resize, .ns_resize => w32.LoadCursorW(null, w32.IDC_SIZENS),
        .nwse_resize, .nw_resize, .se_resize => w32.LoadCursorW(null, w32.IDC_SIZENWSE),
        .nesw_resize, .ne_resize, .sw_resize => w32.LoadCursorW(null, w32.IDC_SIZENESW),
        .not_allowed => w32.LoadCursorW(null, w32.IDC_NO),
        .progress => w32.LoadCursorW(null, w32.IDC_APPSTARTING),
        .wait => w32.LoadCursorW(null, w32.IDC_WAIT),
        else => w32.LoadCursorW(null, w32.IDC_ARROW),
    };
    self.current_cursor = cursor;
    if (cursor) |c| _ = w32.SetCursor(c);
}
pub fn handleSetCursor(self: *Surface) bool {
    if (!self.mouse_visible) {
        _ = w32.SetCursor(null);
        return true;
    }
    if (self.current_cursor) |c| {
        _ = w32.SetCursor(c);
        return true;
    }
    return false;
}
pub const SEARCH_EDIT_ID: u16 = 100;
pub fn setMouseOverLink(self: *Surface, url: []const u8) void {
    if (url.len == 0) {
        if (self.link_preview_hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
        return;
    }
    const hwnd = self.hwnd orelse return;
    const s = self.scale;
    if (self.link_preview_hwnd == null) {
        self.link_preview_hwnd = w32.CreateWindowExW(
            w32.WS_EX_TOOLWINDOW | w32.WS_EX_NOACTIVATE,
            std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            w32.WS_POPUP | w32.WS_BORDER | w32.SS_CENTERIMAGE,
            0,
            0,
            10,
            10,
            self.parent_window.hwnd.?,
            null,
            self.app.hinstance,
            null,
        );
        if (self.link_preview_hwnd) |h| {
            if (self.link_font == null) {
                self.link_font = w32.CreateFontW(
                    -@as(i32, @intFromFloat(@round(13.0 * s))),
                    0,
                    0,
                    0,
                    400,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
                );
            }
            if (self.link_font) |f| {
                _ = w32.SendMessageW(h, w32.WM_SETFONT, @intFromPtr(f), 1);
            }
        }
    }
    const preview = self.link_preview_hwnd orelse return;
    var buf16: [512]u16 = undefined;
    const truncated = if (url.len > 480) url[0..480] else url;
    const len16 = std.unicode.utf8ToUtf16Le(&buf16, truncated) catch return;
    buf16[@min(len16, buf16.len - 1)] = 0;
    _ = w32.SetWindowTextW(preview, @ptrCast(&buf16));
    const char_w: i32 = @intFromFloat(@round(7.0 * s));
    const pad: i32 = @intFromFloat(@round(12.0 * s));
    const pw: i32 = @min(
        @as(i32, @intCast(self.width)),
        @as(i32, @intCast(len16)) * char_w + pad,
    );
    const ph: i32 = @intFromFloat(@round(22.0 * s));
    var pt = w32.POINT{ .x = 0, .y = @as(i32, @intCast(self.height)) - ph };
    _ = w32.ClientToScreen(hwnd, &pt);
    _ = w32.SetWindowPos(preview, null, pt.x, pt.y, pw, ph, w32.SWP_NOACTIVATE | w32.SWP_NOZORDER);
    _ = w32.ShowWindow(preview, w32.SW_SHOWNOACTIVATE);
}
pub fn setSearchTotal(self: *Surface, total: ?usize) void {
    self.search_total = total;
    self.updateSearchCountLabel();
}
pub fn setSearchSelected(self: *Surface, selected: ?usize) void {
    self.search_selected = selected;
    self.updateSearchCountLabel();
}
fn updateSearchCountLabel(self: *Surface) void {
    const label = self.search_count_label orelse return;
    var buf8: [32]u8 = undefined;
    const text8: []const u8 = blk: {
        const total = self.search_total orelse break :blk "";
        if (total == 0) break :blk "0/0";
        if (self.search_selected) |sel| {
            break :blk std.fmt.bufPrint(&buf8, "{d}/{d}", .{ sel + 1, total }) catch "";
        }
        break :blk std.fmt.bufPrint(&buf8, "-/{d}", .{total}) catch "";
    };
    var buf16: [64]u16 = undefined;
    const len16 = std.unicode.utf8ToUtf16Le(&buf16, text8) catch 0;
    buf16[len16] = 0;
    _ = w32.SetWindowTextW(label, @ptrCast(&buf16));
}
pub fn setSearchActive(self: *Surface, active: bool, needle: [:0]const u8) void {
    if (active) {
        if (self.palette_active) {
            self.setCommandPaletteActive(false);
        }
        self.search_active = true;
        self.ensureSearchBar();
        if (self.search_hwnd) |popup| {
            self.positionSearchBar();
            _ = w32.ShowWindow(popup, w32.SW_SHOW);
            if (needle.len > 0) {
                if (self.search_edit) |edit| {
                    var wbuf: [512]u16 = undefined;
                    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, needle) catch 0;
                    if (wlen < wbuf.len) {
                        wbuf[wlen] = 0;
                        _ = w32.SetWindowTextW(edit, @ptrCast(&wbuf));
                    }
                }
            }
            if (self.search_edit) |edit| {
                _ = w32.SetFocus(edit);
            }
        }
    } else {
        self.search_active = false;
        self.search_total = null;
        self.search_selected = null;
        self.updateSearchCountLabel();
        if (self.search_hwnd) |popup| {
            _ = w32.ShowWindow(popup, 0);
        }
        if (self.hwnd) |hwnd| {
            _ = w32.SetFocus(hwnd);
        }
    }
}
fn ensureSearchBar(self: *Surface) void {
    if (self.search_hwnd != null) return;
    const s = self.scale;
    const bar_w: i32 = @intFromFloat(@round(310.0 * s));
    const bar_h: i32 = @intFromFloat(@round(32.0 * s));
    const pad: i32 = @intFromFloat(@round(4.0 * s));
    const popup = w32.CreateWindowExW(
        w32.WS_EX_TOOLWINDOW,
        App.TERMINAL_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP | w32.WS_BORDER,
        0,
        0,
        bar_w,
        bar_h,
        self.parent_window.hwnd.?,
        null,
        self.app.hinstance,
        null,
    ) orelse return;
    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        popup,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );
    _ = w32.SetWindowTheme(
        popup,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );
    const count_w: i32 = @intFromFloat(@round(64.0 * s));
    const edit = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL,
        pad,
        pad,
        bar_w - pad * 2 - 2 - count_w,
        bar_h - pad * 2 - 2,
        popup,
        @ptrFromInt(@as(usize, SEARCH_EDIT_ID)),
        self.app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(popup);
        return;
    };
    self.search_count_label = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.SS_RIGHT | w32.SS_CENTERIMAGE,
        bar_w - pad - count_w,
        pad,
        count_w - pad,
        bar_h - pad * 2 - 2,
        popup,
        null,
        self.app.hinstance,
        null,
    );
    self.search_font = w32.CreateFontW(
        -@as(i32, @intFromFloat(@round(16.0 * s))),
        0,
        0,
        0,
        400,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );
    if (self.search_font) |f| {
        _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
        if (self.search_count_label) |label| {
            _ = w32.SendMessageW(label, w32.WM_SETFONT, @intFromPtr(f), 1);
        }
    }
    _ = w32.SetWindowLongPtrW(popup, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.search_hwnd = popup;
    self.search_edit = edit;
}
fn positionSearchBar(self: *Surface) void {
    const popup = self.search_hwnd orelse return;
    const hwnd = self.parent_window.hwnd orelse return;
    var rect: w32.RECT = undefined;
    if (w32.GetWindowRect(hwnd, &rect) != 0) {
        const s = self.scale;
        const bar_width: i32 = @intFromFloat(@round(310.0 * s));
        const bar_height: i32 = @intFromFloat(@round(32.0 * s));
        const padding: i32 = @intFromFloat(@round(8.0 * s));
        const title_bar: i32 = @intFromFloat(@round(32.0 * s));
        _ = w32.MoveWindow(
            popup,
            rect.right - bar_width - padding,
            rect.top + title_bar + padding,
            bar_width,
            bar_height,
            1,
        );
    }
}
pub fn handleSearchChange(self: *Surface) void {
    if (!self.core_surface_ready) return;
    const search = self.search_edit orelse return;
    var wbuf: [512]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(search, &wbuf, @intCast(wbuf.len)));
    var utf8_buf: [1024]u8 = undefined;
    const utf8_len = std.unicode.utf16LeToUtf8(&utf8_buf, wbuf[0..wlen]) catch 0;
    var needle_buf: [1025]u8 = undefined;
    @memcpy(needle_buf[0..utf8_len], utf8_buf[0..utf8_len]);
    needle_buf[utf8_len] = 0;
    const needle: [:0]const u8 = needle_buf[0..utf8_len :0];
    _ = self.core_surface.performBindingAction(.{ .search = needle }) catch |err| {
        log.err("search error: {}", .{err});
    };
}
pub fn handleSearchKey(self: *Surface, vk: u16) bool {
    if (!self.core_surface_ready) return false;
    switch (vk) {
        w32.VK_RETURN => {
            const shift = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0;
            const nav: input.Binding.Action = if (shift)
                .{ .navigate_search = .previous }
            else
                .{ .navigate_search = .next };
            _ = self.core_surface.performBindingAction(nav) catch |err| {
                log.err("navigate_search error: {}", .{err});
            };
            return true;
        },
        w32.VK_ESCAPE => {
            _ = self.core_surface.performBindingAction(.end_search) catch |err| {
                log.err("end_search error: {}", .{err});
            };
            return true;
        },
        else => return false,
    }
}
const PaletteEntry = struct {
    name: []const u8,
    action: input.Binding.Action,
};
pub const MAX_USER_PALETTE_ENTRIES = 64;
fn paletteEntryName(self: *const Surface, idx: u16) []const u8 {
    if (idx < palette_entries.len) return palette_entries[idx].name;
    const user = self.app.config.@"command-palette-entry".value.items;
    const uidx = idx - palette_entries.len;
    if (uidx >= user.len) return "";
    return user[uidx].title;
}
fn paletteEntryAction(self: *const Surface, idx: u16) ?input.Binding.Action {
    if (idx < palette_entries.len) return palette_entries[idx].action;
    const user = self.app.config.@"command-palette-entry".value.items;
    const uidx = idx - palette_entries.len;
    if (uidx >= user.len) return null;
    return user[uidx].action;
}
pub const PALETTE_EDIT_ID: u16 = 200;
pub const PALETTE_LIST_TOP: f32 = 40.0;
pub const PALETTE_ITEM_HEIGHT: f32 = 28.0;
const palette_entries = [_]PaletteEntry{
    .{ .name = "New Window", .action = .new_window },
    .{ .name = "New Tab", .action = .new_tab },
    .{ .name = "Close Surface", .action = .close_surface },
    .{ .name = "Close Tab", .action = .{ .close_tab = .this } },
    .{ .name = "Close Window", .action = .close_window },
    .{ .name = "Previous Tab", .action = .previous_tab },
    .{ .name = "Next Tab", .action = .next_tab },
    .{ .name = "Last Tab", .action = .last_tab },
    .{ .name = "Split Right", .action = .{ .new_split = .right } },
    .{ .name = "Split Down", .action = .{ .new_split = .down } },
    .{ .name = "Split Left", .action = .{ .new_split = .left } },
    .{ .name = "Split Up", .action = .{ .new_split = .up } },
    .{ .name = "Focus Split Right", .action = .{ .goto_split = .right } },
    .{ .name = "Focus Split Down", .action = .{ .goto_split = .down } },
    .{ .name = "Focus Split Left", .action = .{ .goto_split = .left } },
    .{ .name = "Focus Split Up", .action = .{ .goto_split = .up } },
    .{ .name = "Focus Previous Split", .action = .{ .goto_split = .previous } },
    .{ .name = "Focus Next Split", .action = .{ .goto_split = .next } },
    .{ .name = "Toggle Split Zoom", .action = .toggle_split_zoom },
    .{ .name = "Equalize Splits", .action = .equalize_splits },
    .{ .name = "Toggle Fullscreen", .action = .toggle_fullscreen },
    .{ .name = "Toggle Maximize", .action = .toggle_maximize },
    .{ .name = "Toggle Window Decorations", .action = .toggle_window_decorations },
    .{ .name = "Toggle Background Opacity", .action = .toggle_background_opacity },
    .{ .name = "Toggle Quick Terminal", .action = .toggle_quick_terminal },
    .{ .name = "Toggle Read-Only", .action = .toggle_readonly },
    .{ .name = "Toggle Mouse Reporting", .action = .toggle_mouse_reporting },
    .{ .name = "Copy to Clipboard", .action = .{ .copy_to_clipboard = .mixed } },
    .{ .name = "Paste from Clipboard", .action = .paste_from_clipboard },
    .{ .name = "Copy URL to Clipboard", .action = .copy_url_to_clipboard },
    .{ .name = "Copy Title to Clipboard", .action = .copy_title_to_clipboard },
    .{ .name = "Select All", .action = .select_all },
    .{ .name = "Find", .action = .start_search },
    .{ .name = "Search Selection", .action = .search_selection },
    .{ .name = "Increase Font Size", .action = .{ .increase_font_size = 1 } },
    .{ .name = "Decrease Font Size", .action = .{ .decrease_font_size = 1 } },
    .{ .name = "Reset Font Size", .action = .reset_font_size },
    .{ .name = "Scroll Page Up", .action = .scroll_page_up },
    .{ .name = "Scroll Page Down", .action = .scroll_page_down },
    .{ .name = "Scroll to Top", .action = .scroll_to_top },
    .{ .name = "Scroll to Bottom", .action = .scroll_to_bottom },
    .{ .name = "Clear Screen", .action = .clear_screen },
    .{ .name = "Reset Terminal", .action = .reset },
    .{ .name = "Open Config", .action = .{ .open_config = .default } },
    .{ .name = "Reload Config", .action = .reload_config },
    .{ .name = "Quit", .action = .quit },
};
pub fn setCommandPaletteActive(self: *Surface, active: bool) void {
    if (active) {
        if (self.search_active) {
            self.setSearchActive(false, &[_:0]u8{});
        }
        self.palette_active = true;
        self.ensureCommandPalette();
        if (self.palette_hwnd) |popup| {
            self.positionCommandPalette();
            self.filterPaletteEntries("");
            _ = w32.ShowWindow(popup, w32.SW_SHOW);
            if (self.palette_edit) |edit| {
                _ = w32.SetWindowTextW(edit, std.unicode.utf8ToUtf16LeStringLiteral(""));
                _ = w32.SetFocus(edit);
            }
        }
    } else {
        self.palette_active = false;
        if (self.palette_hwnd) |popup| {
            _ = w32.ShowWindow(popup, 0);
        }
        if (self.hwnd) |hwnd| {
            _ = w32.SetFocus(hwnd);
        }
    }
}
fn ensureCommandPalette(self: *Surface) void {
    if (self.palette_hwnd != null) return;
    const s = self.scale;
    const pal_w: i32 = @intFromFloat(@round(500.0 * s));
    const pal_h: i32 = @intFromFloat(@round(450.0 * s));
    const pad: i32 = @intFromFloat(@round(8.0 * s));
    const edit_h: i32 = @intFromFloat(@round(24.0 * s));
    const popup = w32.CreateWindowExW(
        w32.WS_EX_TOOLWINDOW,
        App.TERMINAL_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP | w32.WS_BORDER,
        0,
        0,
        pal_w,
        pal_h,
        self.parent_window.hwnd.?,
        null,
        self.app.hinstance,
        null,
    ) orelse return;
    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        popup,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );
    _ = w32.SetWindowTheme(
        popup,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );
    const edit = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL,
        pad,
        pad,
        pal_w - pad * 2 - 2,
        edit_h,
        popup,
        @ptrFromInt(@as(usize, PALETTE_EDIT_ID)),
        self.app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(popup);
        return;
    };
    self.palette_font = w32.CreateFontW(
        -@as(i32, @intFromFloat(@round(16.0 * s))),
        0,
        0,
        0,
        400,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );
    if (self.palette_font) |f| {
        _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
    }
    self.palette_brush = w32.CreateSolidBrush(w32.RGB(30, 30, 30));
    const placeholder = std.unicode.utf8ToUtf16LeStringLiteral("Type a command...");
    _ = w32.SendMessageW(edit, 0x1501, 1, @bitCast(@intFromPtr(placeholder)));
    _ = w32.SetWindowLongPtrW(popup, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.palette_hwnd = popup;
    self.palette_edit = edit;
}
fn positionCommandPalette(self: *Surface) void {
    const popup = self.palette_hwnd orelse return;
    const hwnd = self.parent_window.hwnd orelse return;
    var rect: w32.RECT = undefined;
    if (w32.GetWindowRect(hwnd, &rect) != 0) {
        const s = self.scale;
        const win_width = rect.right - rect.left;
        const pal_width: i32 = @intFromFloat(@round(500.0 * s));
        const pal_height: i32 = @intFromFloat(@round(450.0 * s));
        const title_bar: i32 = @intFromFloat(@round(40.0 * s));
        const x = rect.left + @divTrunc(win_width - pal_width, 2);
        const y = rect.top + title_bar;
        _ = w32.MoveWindow(popup, x, y, pal_width, pal_height, 1);
    }
}
fn filterPaletteEntries(self: *Surface, filter: []const u8) void {
    var count: u16 = 0;
    for (palette_entries, 0..) |entry, i| {
        if (filter.len == 0 or std.ascii.indexOfIgnoreCase(entry.name, filter) != null) {
            self.palette_filtered[count] = @intCast(i);
            count += 1;
        }
    }
    const user = self.app.config.@"command-palette-entry".value.items;
    const user_len = @min(user.len, MAX_USER_PALETTE_ENTRIES);
    for (user[0..user_len], 0..) |entry, i| {
        if (filter.len == 0 or std.ascii.indexOfIgnoreCase(entry.title, filter) != null) {
            self.palette_filtered[count] = @intCast(palette_entries.len + i);
            count += 1;
        }
    }
    self.palette_count = count;
    self.palette_selected = 0;
    if (self.palette_hwnd) |popup| {
        _ = w32.InvalidateRect(popup, null, 1);
    }
}
pub fn handlePaletteChange(self: *Surface) void {
    const edit = self.palette_edit orelse return;
    var wbuf: [256]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(edit, &wbuf, @intCast(wbuf.len)));
    var utf8_buf: [512]u8 = undefined;
    const utf8_len = std.unicode.utf16LeToUtf8(&utf8_buf, wbuf[0..wlen]) catch 0;
    self.filterPaletteEntries(utf8_buf[0..utf8_len]);
}
pub fn handlePaletteKey(self: *Surface, vk: u16) bool {
    switch (vk) {
        w32.VK_ESCAPE => {
            self.setCommandPaletteActive(false);
            return true;
        },
        w32.VK_RETURN => {
            self.executePaletteSelection();
            return true;
        },
        w32.VK_UP => {
            if (self.palette_selected > 0) {
                self.palette_selected -= 1;
                if (self.palette_hwnd) |popup| {
                    _ = w32.InvalidateRect(popup, null, 1);
                }
            }
            return true;
        },
        w32.VK_DOWN => {
            if (self.palette_count > 0 and self.palette_selected < self.palette_count - 1) {
                self.palette_selected += 1;
                if (self.palette_hwnd) |popup| {
                    _ = w32.InvalidateRect(popup, null, 1);
                }
            }
            return true;
        },
        else => return false,
    }
}
pub fn executePaletteSelection(self: *Surface) void {
    if (!self.core_surface_ready) return;
    if (self.palette_selected >= self.palette_count) return;
    const entry_idx = self.palette_filtered[self.palette_selected];
    const action = self.paletteEntryAction(entry_idx) orelse return;
    self.setCommandPaletteActive(false);
    _ = self.core_surface.performBindingAction(action) catch |err| {
        log.err("palette action error: {}", .{err});
    };
}
pub fn paintPalette(self: *Surface, hwnd: w32.HWND) void {
    var ps: w32.PAINTSTRUCT = undefined;
    const hdc = w32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = w32.EndPaint(hwnd, &ps);
    var client_rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client_rect) == 0) return;
    if (self.palette_brush) |b| {
        _ = w32.FillRect(hdc, &client_rect, b);
    } else if (w32.CreateSolidBrush(w32.RGB(30, 30, 30))) |b| {
        _ = w32.FillRect(hdc, &client_rect, b);
        _ = w32.DeleteObject(b);
    }
    const s = self.scale;
    if (self.palette_paint_font == null) {
        self.palette_paint_font = w32.CreateFontW(
            -@as(i32, @intFromFloat(@round(14.0 * s))),
            0,
            0,
            0,
            400,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
        );
    }
    const old_font = if (self.palette_paint_font) |f| w32.SelectObject(hdc, f) else null;
    defer {
        if (old_font) |of| _ = w32.SelectObject(hdc, of);
    }
    _ = w32.SetBkMode(hdc, 1);
    const item_height: i32 = @intFromFloat(@round(PALETTE_ITEM_HEIGHT * s));
    const list_top: i32 = @intFromFloat(@round(PALETTE_LIST_TOP * s));
    const max_visible = @divTrunc(client_rect.bottom - list_top, item_height);
    if (max_visible <= 0) return;
    var scroll_offset: i32 = 0;
    if (self.palette_selected >= max_visible) {
        scroll_offset = self.palette_selected - @as(u16, @intCast(max_visible)) + 1;
    }
    var i: u16 = 0;
    while (i < self.palette_count) : (i += 1) {
        const visual_idx = @as(i32, i) - scroll_offset;
        if (visual_idx < 0) continue;
        if (visual_idx >= max_visible) break;
        const y = list_top + visual_idx * item_height;
        const entry_idx = self.palette_filtered[i];
        const entry_name = self.paletteEntryName(entry_idx);
        const entry_action = self.paletteEntryAction(entry_idx);
        if (i == self.palette_selected) {
            if (w32.CreateSolidBrush(w32.RGB(60, 60, 80))) |sel_brush| {
                const sel_rect = w32.RECT{
                    .left = 0,
                    .top = y,
                    .right = client_rect.right,
                    .bottom = y + item_height,
                };
                _ = w32.FillRect(hdc, &sel_rect, sel_brush);
                _ = w32.DeleteObject(sel_brush);
            }
        }
        const text_pad: i32 = @intFromFloat(@round(12.0 * s));
        const text_top_pad: i32 = @intFromFloat(@round(4.0 * s));
        const kb_area: i32 = @intFromFloat(@round(160.0 * s));
        _ = w32.SetTextColor(hdc, w32.RGB(220, 220, 220));
        var name_rect = w32.RECT{
            .left = text_pad,
            .top = y + text_top_pad,
            .right = client_rect.right - kb_area,
            .bottom = y + item_height,
        };
        var wname_buf: [128]u16 = undefined;
        var name_len = @min(entry_name.len, wname_buf.len);
        while (name_len > 0 and entry_name[name_len - 1] & 0xC0 == 0x80) name_len -= 1;
        const wname_len = std.unicode.utf8ToUtf16Le(&wname_buf, entry_name[0..name_len]) catch 0;
        _ = w32.DrawTextW(hdc, @ptrCast(&wname_buf), @intCast(wname_len), &name_rect, 0);
        const trigger = if (entry_action) |a| self.app.config.keybind.set.getTrigger(a) else null;
        if (trigger) |t| {
            _ = w32.SetTextColor(hdc, w32.RGB(140, 140, 140));
            var kb_buf: [64]u8 = undefined;
            const kb_len = formatTrigger(t, &kb_buf);
            var wkb_buf: [64]u16 = undefined;
            const wkb_len = std.unicode.utf8ToUtf16Le(&wkb_buf, kb_buf[0..kb_len]) catch 0;
            var kb_rect = w32.RECT{
                .left = client_rect.right - kb_area + text_top_pad,
                .top = y + text_top_pad,
                .right = client_rect.right - text_pad,
                .bottom = y + item_height,
            };
            _ = w32.DrawTextW(hdc, @ptrCast(&wkb_buf), @intCast(wkb_len), &kb_rect, 0x0002);
        }
    }
}
fn formatTrigger(trigger: input.Binding.Trigger, buf: []u8) usize {
    var pos: usize = 0;
    if (trigger.mods.super) {
        const s = "Win+";
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }
    if (trigger.mods.ctrl) {
        const s = "Ctrl+";
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }
    if (trigger.mods.alt) {
        const s = "Alt+";
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }
    if (trigger.mods.shift) {
        const s = "Shift+";
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }
    switch (trigger.key) {
        .unicode => |cp| {
            if (cp >= 'a' and cp <= 'z') {
                buf[pos] = @intCast(cp - 32);
                pos += 1;
            } else if (cp >= ' ' and cp <= '~') {
                buf[pos] = @intCast(cp);
                pos += 1;
            }
        },
        .physical => |k| {
            const name = keyName(k);
            if (name.len > 0 and pos + name.len <= buf.len) {
                @memcpy(buf[pos..][0..name.len], name);
                pos += name.len;
            }
        },
        .catch_all => {},
    }
    return pos;
}
fn keyName(k: input.Key) []const u8 {
    return switch (k) {
        .key_a => "A",
        .key_b => "B",
        .key_c => "C",
        .key_d => "D",
        .key_e => "E",
        .key_f => "F",
        .key_g => "G",
        .key_h => "H",
        .key_i => "I",
        .key_j => "J",
        .key_k => "K",
        .key_l => "L",
        .key_m => "M",
        .key_n => "N",
        .key_o => "O",
        .key_p => "P",
        .key_q => "Q",
        .key_r => "R",
        .key_s => "S",
        .key_t => "T",
        .key_u => "U",
        .key_v => "V",
        .key_w => "W",
        .key_x => "X",
        .key_y => "Y",
        .key_z => "Z",
        .digit_0 => "0",
        .digit_1 => "1",
        .digit_2 => "2",
        .digit_3 => "3",
        .digit_4 => "4",
        .digit_5 => "5",
        .digit_6 => "6",
        .digit_7 => "7",
        .digit_8 => "8",
        .digit_9 => "9",
        .f1 => "F1",
        .f2 => "F2",
        .f3 => "F3",
        .f4 => "F4",
        .f5 => "F5",
        .f6 => "F6",
        .f7 => "F7",
        .f8 => "F8",
        .f9 => "F9",
        .f10 => "F10",
        .f11 => "F11",
        .f12 => "F12",
        .space => "Space",
        .enter => "Enter",
        .tab => "Tab",
        .backspace => "Backspace",
        .escape => "Escape",
        .arrow_left => "Left",
        .arrow_right => "Right",
        .arrow_up => "Up",
        .arrow_down => "Down",
        .page_up => "PgUp",
        .page_down => "PgDn",
        .home => "Home",
        .end => "End",
        .insert => "Insert",
        .delete => "Delete",
        .comma => ",",
        .period => ".",
        .slash => "/",
        .semicolon => ";",
        .quote => "'",
        .bracket_left => "[",
        .bracket_right => "]",
        .backslash => "\\",
        .minus => "-",
        .equal => "=",
        .backquote => "`",
        else => "",
    };
}
pub fn toggleWindowDecorations(self: *Surface) void {
    self.parent_window.toggleWindowDecorations();
}
pub fn setScrollbar(self: *Surface, scrollbar: terminal.Scrollbar) void {
    if (self.scrollbar) |sb| sb.update(scrollbar);
}
pub fn scrollToOffset(self: *Surface, offset: usize) void {
    if (!self.core_surface_ready) return;
    _ = self.core_surface.performBindingAction(.{ .scroll_to_row = offset }) catch |err| {
        log.err("scrollToOffset error: {}", .{err});
    };
}
pub fn handleResize(self: *Surface, width: u32, height: u32) void {
    if (width == 0 or height == 0) return;
    self.height = height;
    var grid_width = width;
    if (self.scrollbar) |sb| {
        const sub = sb.repositionAndResize();
        if (sub > 0 and grid_width > @as(u32, @intCast(sub))) {
            grid_width -= @as(u32, @intCast(sub));
        }
    }
    self.width = grid_width;
    if (self.search_active) self.positionSearchBar();
    if (self.palette_active) self.positionCommandPalette();
    if (!self.core_surface_ready) return;
    self.core_surface.sizeCallback(.{ .width = grid_width, .height = height }) catch |err| {
        log.err("sizeCallback error: {}", .{err});
        return;
    };
    if (self.in_live_resize) {
        if (self.frame_event) |event| {
            _ = w32.ResetEvent(event);
        }
        self.core_surface.renderer_thread.wakeup.notify() catch {};
        if (self.frame_event) |event| {
            _ = w32.WaitForSingleObject(event, 16);
        }
    } else {
        self.core_surface.renderer_thread.wakeup.notify() catch {};
    }
}
pub fn handleDpiChange(self: *Surface) void {
    self.updateDpiScale();
    const s = self.scale;
    if (self.search_font) |old| {
        _ = w32.DeleteObject(old);
        self.search_font = null;
    }
    if (self.palette_font) |old| {
        _ = w32.DeleteObject(old);
        self.palette_font = null;
    }
    if (self.palette_paint_font) |old| {
        _ = w32.DeleteObject(old);
        self.palette_paint_font = null;
    }
    if (self.search_edit) |edit| {
        self.search_font = w32.CreateFontW(
            -@as(i32, @intFromFloat(@round(16.0 * s))),
            0,
            0,
            0,
            400,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
        );
        if (self.search_font) |f| {
            _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
            if (self.search_count_label) |label| {
                _ = w32.SendMessageW(label, w32.WM_SETFONT, @intFromPtr(f), 1);
            }
        }
    }
    if (self.palette_edit) |edit| {
        self.palette_font = w32.CreateFontW(
            -@as(i32, @intFromFloat(@round(16.0 * s))),
            0,
            0,
            0,
            400,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
        );
        if (self.palette_font) |f| {
            _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
        }
    }
    if (self.scrollbar) |sb| sb.onDpiChanged(@intFromFloat(self.scale * 96.0));
}
pub fn handleKeyEvent(self: *Surface, wparam: usize, lparam: isize, action: input.Action) void {
    if (!self.core_surface_ready) return;
    const vk: u16 = @intCast(wparam & 0xFFFF);
    if (vk == w32.VK_PROCESSKEY) return;
    if (vk == w32.VK_PACKET) return;
    const extended = (lparam & (1 << 24)) != 0;
    const key = mapVirtualKey(vk, extended);
    const mods = getModifiers();
    if (self.isWin32InputMode()) {
        if (!key.modifier()) {
            const actual_action_w32 = if (action == .press and (lparam & (1 << 30)) != 0)
                input.Action.repeat
            else
                action;
            const unshifted_cp: u21 = if (key.codepoint()) |cp| cp else 0;
            const effect = self.core_surface.keyCallback(.{
                .action = actual_action_w32,
                .key = key,
                .mods = mods,
                .consumed_mods = .{},
                .utf8 = "",
                .unshifted_codepoint = unshifted_cp,
            }) catch |err| {
                log.err("key callback error: {}", .{err});
                return;
            };
            if (effect == .consumed or effect == .closed) return;
        }
        self.sendWin32InputEvent(vk, lparam, action);
        return;
    }
    const actual_action = if (action == .press and (lparam & (1 << 30)) != 0)
        input.Action.repeat
    else
        action;
    const unshifted_codepoint: u21 = if (key.codepoint()) |cp| cp else 0;
    var utf8_buf: [16]u8 = undefined;
    var utf8_text: []const u8 = "";
    var consumed_mods: input.Mods = .{};
    var event_mods = mods;
    self.key_event_produced_text = false;
    if ((actual_action == .press or actual_action == .repeat) and !isModifierVk(vk)) {
        var keyboard_state: [256]u8 = undefined;
        if (w32.GetKeyboardState(&keyboard_state) != 0) {
            const scancode: u32 = @intCast((lparam >> 16) & 0xFF);
            var utf16_buf: [4]u16 = undefined;
            const result = w32.ToUnicode(
                @intCast(vk),
                scancode,
                &keyboard_state,
                &utf16_buf,
                utf16_buf.len,
                0,
            );
            if (result > 0) {
                const utf16_slice = utf16_buf[0..@intCast(result)];
                if (utf16_slice[0] >= 0x20) {
                    const len = std.unicode.utf16LeToUtf8(&utf8_buf, utf16_slice) catch 0;
                    if (len > 0) {
                        utf8_text = utf8_buf[0..len];
                        if (mods.shift) consumed_mods.shift = true;
                        self.key_event_produced_text = true;
                        if (mods.ctrl and mods.alt and
                            (keyboard_state[w32.VK_RMENU] & 0x80) != 0)
                        {
                            event_mods.ctrl = false;
                            event_mods.alt = false;
                            consumed_mods.ctrl = true;
                            consumed_mods.alt = true;
                        }
                    }
                }
            }
        }
    }
    const event = input.KeyEvent{
        .action = actual_action,
        .key = key,
        .mods = event_mods,
        .consumed_mods = consumed_mods,
        .utf8 = utf8_text,
        .unshifted_codepoint = unshifted_codepoint,
    };
    _ = self.core_surface.keyCallback(event) catch |err| {
        log.err("key callback error: {}", .{err});
    };
}
pub fn handleCharEvent(self: *Surface, wparam: usize) void {
    if (!self.core_surface_ready) return;
    const char_code: u16 = @intCast(wparam & 0xFFFF);
    if (char_code < 0x20 and char_code != '\t' and char_code != '\r' and char_code != '\n') return;
    const codepoint: u21 = if (char_code >= 0xD800 and char_code <= 0xDBFF) {
        self.high_surrogate = char_code;
        return;
    } else if (char_code >= 0xDC00 and char_code <= 0xDFFF) blk: {
        if (self.high_surrogate != 0) {
            const hi: u21 = self.high_surrogate;
            self.high_surrogate = 0;
            break :blk @intCast((@as(u21, hi - 0xD800) << 10) + (@as(u21, char_code) - 0xDC00) + 0x10000);
        }
        return;
    } else blk: {
        self.high_surrogate = 0;
        break :blk @intCast(char_code);
    };
    var utf8_buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch return;
    _ = self.core_surface.keyCallback(.{
        .action = .press,
        .key = .unidentified,
        .mods = .{},
        .consumed_mods = .{},
        .composing = false,
        .utf8 = utf8_buf[0..len],
    }) catch |err| {
        log.err("text input callback error: {}", .{err});
    };
}
pub fn handleMouseButton(
    self: *Surface,
    button: input.MouseButton,
    action: input.MouseButtonState,
    lparam: isize,
) void {
    if (!self.core_surface_ready) return;
    const x: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, lparam & 0xFFFF))));
    const y: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, (lparam >> 16) & 0xFFFF))));
    const mods = getModifiers();
    const bit: u3 = switch (button) {
        .left => 1,
        .right => 2,
        .middle => 4,
        else => 0,
    };
    if (bit != 0) {
        const prev = self.mouse_button_mask;
        if (action == .press) {
            self.mouse_button_mask |= bit;
            if (prev == 0) {
                if (self.hwnd) |hwnd| _ = w32.SetCapture(hwnd);
            }
        } else {
            self.mouse_button_mask &= ~bit;
            if (prev != 0 and self.mouse_button_mask == 0) {
                _ = w32.ReleaseCapture();
            }
        }
    }
    self.core_surface.cursorPosCallback(.{ .x = x, .y = y }, mods) catch |err| {
        log.err("cursor pos callback error: {}", .{err});
    };
    const consumed = self.core_surface.mouseButtonCallback(action, button, mods) catch |err| blk: {
        log.err("mouse button callback error: {}", .{err});
        break :blk true;
    };
    if (!consumed and button == .right and action == .press) {
        self.showContextMenu(lparam);
    }
}
fn showContextMenu(self: *Surface, lparam: isize) void {
    const hwnd = self.hwnd orelse return;
    if (self.mouse_button_mask != 0) {
        self.mouse_button_mask = 0;
        _ = w32.ReleaseCapture();
    }
    _ = self.core_surface.mouseButtonCallback(.release, .right, getModifiers()) catch |err| {
        log.err("mouse button callback error: {}", .{err});
    };
    const CTX_COPY: usize = 1;
    const CTX_PASTE: usize = 2;
    const CTX_SELECT_ALL: usize = 3;
    const CTX_SPLIT_RIGHT: usize = 4;
    const CTX_SPLIT_DOWN: usize = 5;
    const CTX_RESET: usize = 6;
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);
    const has_sel = self.core_surface.hasSelection();
    _ = w32.AppendMenuW(menu, if (has_sel) w32.MF_STRING else w32.MF_GRAYED, CTX_COPY, std.unicode.utf8ToUtf16LeStringLiteral("Copy"));
    _ = w32.AppendMenuW(menu, w32.MF_STRING, CTX_PASTE, std.unicode.utf8ToUtf16LeStringLiteral("Paste"));
    _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    _ = w32.AppendMenuW(menu, w32.MF_STRING, CTX_SELECT_ALL, std.unicode.utf8ToUtf16LeStringLiteral("Select All"));
    _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    _ = w32.AppendMenuW(menu, w32.MF_STRING, CTX_SPLIT_RIGHT, std.unicode.utf8ToUtf16LeStringLiteral("Split Right"));
    _ = w32.AppendMenuW(menu, w32.MF_STRING, CTX_SPLIT_DOWN, std.unicode.utf8ToUtf16LeStringLiteral("Split Down"));
    _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    _ = w32.AppendMenuW(menu, w32.MF_STRING, CTX_RESET, std.unicode.utf8ToUtf16LeStringLiteral("Reset Terminal"));
    var pt = w32.POINT{
        .x = @intCast(@as(i16, @truncate(@as(isize, lparam & 0xFFFF)))),
        .y = @intCast(@as(i16, @truncate(@as(isize, (lparam >> 16) & 0xFFFF)))),
    };
    _ = w32.ClientToScreen(hwnd, &pt);
    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        hwnd,
        null,
    );
    const binding: ?input.Binding.Action = switch (@as(usize, @intCast(cmd))) {
        CTX_COPY => .{ .copy_to_clipboard = .mixed },
        CTX_PASTE => .paste_from_clipboard,
        CTX_SELECT_ALL => .select_all,
        CTX_SPLIT_RIGHT => .{ .new_split = .right },
        CTX_SPLIT_DOWN => .{ .new_split = .down },
        CTX_RESET => .reset,
        else => null,
    };
    if (binding) |b| {
        _ = self.core_surface.performBindingAction(b) catch |err| {
            log.err("context menu action failed err={}", .{err});
        };
    }
}
pub fn handleMouseMove(self: *Surface, lparam: isize) void {
    if (!self.core_surface_ready) return;
    const x: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, lparam & 0xFFFF))));
    const y: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, (lparam >> 16) & 0xFFFF))));
    const mods = getModifiers();
    self.core_surface.cursorPosCallback(.{ .x = x, .y = y }, mods) catch |err| {
        log.err("cursor pos callback error: {}", .{err});
    };
}
pub fn handleDropFiles(self: *Surface, wparam: usize) void {
    if (!self.core_surface_ready) return;
    const hdrop: w32.HDROP = @ptrFromInt(wparam);
    defer w32.DragFinish(hdrop);
    const alloc = self.app.core_app.alloc;
    const text = (hdropPathsToUtf8(alloc, hdrop) catch |err| {
        log.err("drop-files path conversion: {}", .{err});
        return;
    }) orelse return;
    defer alloc.free(text);
    _ = self.core_surface.keyCallback(.{
        .action = .press,
        .key = .unidentified,
        .mods = .{},
        .consumed_mods = .{},
        .composing = false,
        .utf8 = text,
        .unshifted_codepoint = 0,
    }) catch |err| {
        log.err("drop-files keyCallback: {}", .{err});
    };
}
fn hdropPathsToUtf8(alloc: Allocator, hdrop: w32.HDROP) Allocator.Error!?[]u8 {
    const count = w32.DragQueryFileW(hdrop, 0xFFFFFFFF, null, 0);
    if (count == 0) return null;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const u16_len = w32.DragQueryFileW(hdrop, i, null, 0);
        if (u16_len == 0) continue;
        const u16_buf = try alloc.alloc(u16, u16_len + 1);
        defer alloc.free(u16_buf);
        const got = w32.DragQueryFileW(hdrop, i, u16_buf.ptr, @intCast(u16_buf.len));
        if (got == 0) continue;
        const utf8_buf = try alloc.alloc(u8, u16_buf.len * 4);
        defer alloc.free(utf8_buf);
        const utf8_len = std.unicode.utf16LeToUtf8(utf8_buf, u16_buf[0..got]) catch continue;
        const path = utf8_buf[0..utf8_len];
        if (std.mem.indexOfScalar(u8, path, '"') != null) {
            log.warn("refusing to paste a path containing a double quote", .{});
            continue;
        }
        if (buf.items.len > 0) try buf.append(alloc, ' ');
        try buf.append(alloc, '"');
        try buf.appendSlice(alloc, path);
        try buf.append(alloc, '"');
    }
    if (buf.items.len == 0) {
        buf.deinit(alloc);
        return null;
    }
    return try buf.toOwnedSlice(alloc);
}
pub fn handleMouseWheel(self: *Surface, wparam: usize, axis: enum { vertical, horizontal }) void {
    if (!self.core_surface_ready) return;
    const raw_delta: i16 = @bitCast(@as(u16, @intCast((wparam >> 16) & 0xFFFF)));
    const delta: f64 = @as(f64, @floatFromInt(raw_delta)) / @as(f64, @floatFromInt(w32.WHEEL_DELTA));
    const scroll_mods: input.ScrollMods = .{};
    const xoff: f64 = if (axis == .horizontal) delta else 0;
    const yoff: f64 = if (axis == .vertical) delta else 0;
    self.core_surface.scrollCallback(xoff, yoff, scroll_mods) catch |err| {
        log.err("scroll callback error: {}", .{err});
    };
}
pub fn handleImeStartComposition(self: *Surface) void {
    self.ime_composing = true;
    self.high_surrogate = 0;
    self.positionImeWindow();
}
pub fn handleImeEndComposition(self: *Surface) void {
    self.ime_composing = false;
    if (self.core_surface_ready) {
        self.core_surface.preeditCallback(null) catch {};
    }
}
pub fn handleImeComposition(self: *Surface, lparam: isize) bool {
    if (!self.core_surface_ready) return false;
    const flags: u32 = @intCast(lparam & 0xFFFFFFFF);
    if (flags & w32.GCS_RESULTSTR == 0) {
        if (flags & w32.GCS_COMPSTR != 0) {
            self.updateImePreedit();
            return true;
        }
        return false;
    }
    self.core_surface.preeditCallback(null) catch {};
    const hwnd = self.hwnd orelse return false;
    const himc = w32.ImmGetContext(hwnd) orelse return false;
    defer _ = w32.ImmReleaseContext(hwnd, himc);
    const byte_len = w32.ImmGetCompositionStringW(himc, w32.GCS_RESULTSTR, null, 0);
    if (byte_len <= 0) return false;
    if (byte_len & 1 != 0) return false;
    const u16_len: usize = @intCast(@divTrunc(byte_len, 2));
    var stack_buf: [64]u16 = undefined;
    if (u16_len <= stack_buf.len) {
        const got = w32.ImmGetCompositionStringW(himc, w32.GCS_RESULTSTR, &stack_buf, @intCast(byte_len));
        if (got <= 0) return false;
        if (got & 1 != 0) return false;
        const actual_len: usize = @intCast(@divTrunc(got, 2));
        self.sendImeText(stack_buf[0..actual_len]);
    } else {
        const alloc = self.app.core_app.alloc;
        const buf = alloc.alloc(u16, u16_len) catch return false;
        defer alloc.free(buf);
        const got = w32.ImmGetCompositionStringW(himc, w32.GCS_RESULTSTR, buf.ptr, @intCast(byte_len));
        if (got <= 0) return false;
        if (got & 1 != 0) return false;
        const actual_len: usize = @intCast(@divTrunc(got, 2));
        self.sendImeText(buf[0..actual_len]);
    }
    if (flags & w32.GCS_COMPSTR != 0) self.updateImePreedit();
    self.positionImeWindow();
    return true;
}
fn updateImePreedit(self: *Surface) void {
    const hwnd = self.hwnd orelse return;
    const himc = w32.ImmGetContext(hwnd) orelse return;
    defer _ = w32.ImmReleaseContext(hwnd, himc);
    var buf16: [128]u16 = undefined;
    const byte_len = w32.ImmGetCompositionStringW(himc, w32.GCS_COMPSTR, null, 0);
    if (byte_len <= 0 or byte_len & 1 != 0) {
        self.core_surface.preeditCallback(null) catch {};
        return;
    }
    const u16_len: usize = @intCast(@divTrunc(byte_len, 2));
    if (u16_len > buf16.len) {
        self.core_surface.preeditCallback(null) catch {};
        return;
    }
    const got = w32.ImmGetCompositionStringW(himc, w32.GCS_COMPSTR, &buf16, @intCast(byte_len));
    if (got <= 0 or got & 1 != 0) return;
    const n: usize = @intCast(@divTrunc(got, 2));
    var buf8: [buf16.len * 3]u8 = undefined;
    const len8 = std.unicode.utf16LeToUtf8(&buf8, buf16[0..n]) catch return;
    self.core_surface.preeditCallback(if (len8 == 0) null else buf8[0..len8]) catch |err| {
        log.warn("preeditCallback failed err={}", .{err});
    };
}
fn sendImeText(self: *Surface, utf16: []const u16) void {
    if (self.isWin32InputMode()) {
        for (utf16) |code_unit| {
            self.sendWin32CharEvent(code_unit);
        }
        return;
    }
    var utf8_buf: [256]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&utf8_buf, utf16) catch |err| {
        log.warn("IME utf16→utf8 error: {}", .{err});
        return;
    };
    if (len == 0) return;
    _ = self.core_surface.keyCallback(.{
        .action = .press,
        .key = .unidentified,
        .mods = .{},
        .consumed_mods = .{},
        .composing = false,
        .utf8 = utf8_buf[0..len],
    }) catch |err| {
        log.err("IME text callback error: {}", .{err});
    };
}
fn positionImeWindow(self: *Surface) void {
    const hwnd = self.hwnd orelse return;
    const himc = w32.ImmGetContext(hwnd) orelse return;
    defer _ = w32.ImmReleaseContext(hwnd, himc);
    var pos = w32.POINT{ .x = 0, .y = 0 };
    if (self.core_surface_ready) {
        const ime_pos = self.core_surface.imePoint();
        pos.x = @intFromFloat(ime_pos.x);
        pos.y = @intFromFloat(ime_pos.y);
    }
    const cf = w32.COMPOSITIONFORM{
        .dwStyle = w32.CFS_POINT,
        .ptCurrentPos = pos,
        .rcArea = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    };
    _ = w32.ImmSetCompositionWindow(himc, &cf);
}
pub fn isWin32InputMode(self: *Surface) bool {
    self.core_surface.renderer_state.mutex.lockUncancelable(global.io());
    defer self.core_surface.renderer_state.mutex.unlock(global.io());
    return self.core_surface.io.terminal.modes.get(.win32_input);
}
fn sendWin32InputEvent(self: *Surface, vk: u16, lparam: isize, action: input.Action) void {
    const scancode: u16 = @intCast((lparam >> 16) & 0xFF);
    const extended = (lparam & (1 << 24)) != 0;
    const repeat_count: u16 = @intCast(lparam & 0xFFFF);
    const key_down: u1 = if (action == .press or action == .repeat) 1 else 0;
    var unicode_char: u16 = 0;
    if (key_down == 1 and !isModifierVk(vk)) {
        var keyboard_state: [256]u8 = undefined;
        if (w32.GetKeyboardState(&keyboard_state) != 0) {
            var utf16_buf: [4]u16 = undefined;
            const result = w32.ToUnicode(
                @intCast(vk),
                @intCast(scancode),
                &keyboard_state,
                &utf16_buf,
                utf16_buf.len,
                0,
            );
            if (result > 0) {
                unicode_char = utf16_buf[0];
            } else if (result < 0) {
                unicode_char = 0;
            }
        }
    }
    var ctrl_state: u32 = 0;
    if (w32.GetKeyState(@as(i32, w32.VK_RSHIFT)) < 0 or
        w32.GetKeyState(@as(i32, w32.VK_LSHIFT)) < 0 or
        w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0)
        ctrl_state |= 0x0010;
    if (w32.GetKeyState(@as(i32, w32.VK_LCONTROL)) < 0)
        ctrl_state |= 0x0008;
    if (w32.GetKeyState(@as(i32, w32.VK_RCONTROL)) < 0)
        ctrl_state |= 0x0004;
    if (w32.GetKeyState(@as(i32, w32.VK_LMENU)) < 0)
        ctrl_state |= 0x0002;
    if (w32.GetKeyState(@as(i32, w32.VK_RMENU)) < 0)
        ctrl_state |= 0x0001;
    if (w32.GetKeyState(@as(i32, w32.VK_CAPITAL)) & 1 != 0)
        ctrl_state |= 0x0080;
    if (w32.GetKeyState(@as(i32, w32.VK_NUMLOCK)) & 1 != 0)
        ctrl_state |= 0x0020;
    if (w32.GetKeyState(@as(i32, w32.VK_SCROLL)) & 1 != 0)
        ctrl_state |= 0x0040;
    if (extended)
        ctrl_state |= 0x0100;
    self.writeWin32InputSequence(vk, scancode, unicode_char, key_down, ctrl_state, repeat_count);
}
pub fn sendWin32CharEvent(self: *Surface, char_code: u16) void {
    self.writeWin32InputSequence(0, 0, char_code, 1, 0, 1);
    self.writeWin32InputSequence(0, 0, char_code, 0, 0, 1);
}
fn writeWin32InputSequence(
    self: *Surface,
    vk: u16,
    sc: u16,
    uc: u16,
    kd: u1,
    cs: u32,
    rc: u16,
) void {
    var buf: [64]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{};{};{};{};{};{}_", .{
        vk, sc, uc, kd, cs, rc,
    }) catch return;
    const msg = termio.Message.writeReq(
        self.app.core_app.alloc,
        seq,
    ) catch return;
    self.core_surface.io.queueMessage(msg, .unlocked);
}
pub fn signalFrameDrawn(self: *Surface) void {
    if (self.frame_event) |event| {
        _ = w32.SetEvent(event);
    }
}
pub fn handleFocus(self: *Surface, focused: bool) void {
    if (!self.core_surface_ready) return;
    if (!focused) {
        self.high_surrogate = 0;
        if (self.ime_composing) {
            self.ime_composing = false;
            if (self.hwnd) |hwnd| {
                if (w32.ImmGetContext(hwnd)) |himc| {
                    defer _ = w32.ImmReleaseContext(hwnd, himc);
                    _ = w32.ImmNotifyIME(himc, w32.NI_COMPOSITIONSTR, w32.CPS_CANCEL, 0);
                }
            }
            self.core_surface.preeditCallback(null) catch {};
        }
        var ks: [256]u8 = undefined;
        if (w32.GetKeyboardState(&ks) != 0) {
            var buf: [4]u16 = undefined;
            _ = w32.ToUnicode(@intCast(w32.VK_SPACE), 0x39, &ks, &buf, buf.len, 0);
            _ = w32.ToUnicode(@intCast(w32.VK_SPACE), 0x39, &ks, &buf, buf.len, 0);
        }
    }
    self.core_surface.focusCallback(focused) catch |err| {
        log.err("focus callback error: {}", .{err});
    };
}
fn getModifiers() input.Mods {
    var mods: input.Mods = .{};
    if (w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0) {
        mods.shift = true;
        if (w32.GetKeyState(@as(i32, w32.VK_RSHIFT)) < 0) {
            mods.sides.shift = .right;
        }
    }
    if (w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0) {
        mods.ctrl = true;
        if (w32.GetKeyState(@as(i32, w32.VK_RCONTROL)) < 0) {
            mods.sides.ctrl = .right;
        }
    }
    if (w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0) {
        mods.alt = true;
        if (w32.GetKeyState(@as(i32, w32.VK_RMENU)) < 0) {
            mods.sides.alt = .right;
        }
    }
    if (w32.GetKeyState(@as(i32, w32.VK_LWIN)) < 0 or
        w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0)
    {
        mods.super = true;
        if (w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0) {
            mods.sides.super = .right;
        }
    }
    if (w32.GetKeyState(@as(i32, w32.VK_CAPITAL)) & 1 != 0) {
        mods.caps_lock = true;
    }
    if (w32.GetKeyState(@as(i32, w32.VK_NUMLOCK)) & 1 != 0) {
        mods.num_lock = true;
    }
    return mods;
}
fn isModifierVk(vk: u16) bool {
    return switch (vk) {
        w32.VK_SHIFT,
        w32.VK_LSHIFT,
        w32.VK_RSHIFT,
        w32.VK_CONTROL,
        w32.VK_LCONTROL,
        w32.VK_RCONTROL,
        w32.VK_MENU,
        w32.VK_LMENU,
        w32.VK_RMENU,
        w32.VK_LWIN,
        w32.VK_RWIN,
        w32.VK_CAPITAL,
        w32.VK_NUMLOCK,
        w32.VK_SCROLL,
        => true,
        else => false,
    };
}
fn mapVirtualKey(vk: u16, extended: bool) input.Key {
    return switch (vk) {
        0x41 => .key_a,
        0x42 => .key_b,
        0x43 => .key_c,
        0x44 => .key_d,
        0x45 => .key_e,
        0x46 => .key_f,
        0x47 => .key_g,
        0x48 => .key_h,
        0x49 => .key_i,
        0x4A => .key_j,
        0x4B => .key_k,
        0x4C => .key_l,
        0x4D => .key_m,
        0x4E => .key_n,
        0x4F => .key_o,
        0x50 => .key_p,
        0x51 => .key_q,
        0x52 => .key_r,
        0x53 => .key_s,
        0x54 => .key_t,
        0x55 => .key_u,
        0x56 => .key_v,
        0x57 => .key_w,
        0x58 => .key_x,
        0x59 => .key_y,
        0x5A => .key_z,
        0x30 => .digit_0,
        0x31 => .digit_1,
        0x32 => .digit_2,
        0x33 => .digit_3,
        0x34 => .digit_4,
        0x35 => .digit_5,
        0x36 => .digit_6,
        0x37 => .digit_7,
        0x38 => .digit_8,
        0x39 => .digit_9,
        w32.VK_F1 => .f1,
        w32.VK_F2 => .f2,
        w32.VK_F3 => .f3,
        w32.VK_F4 => .f4,
        w32.VK_F5 => .f5,
        w32.VK_F6 => .f6,
        w32.VK_F7 => .f7,
        w32.VK_F8 => .f8,
        w32.VK_F9 => .f9,
        w32.VK_F10 => .f10,
        w32.VK_F11 => .f11,
        w32.VK_F12 => .f12,
        w32.VK_F13 => .f13,
        w32.VK_F14 => .f14,
        w32.VK_F15 => .f15,
        w32.VK_F16 => .f16,
        w32.VK_F17 => .f17,
        w32.VK_F18 => .f18,
        w32.VK_F19 => .f19,
        w32.VK_F20 => .f20,
        w32.VK_F21 => .f21,
        w32.VK_F22 => .f22,
        w32.VK_F23 => .f23,
        w32.VK_F24 => .f24,
        w32.VK_RETURN => if (extended) .numpad_enter else .enter,
        w32.VK_BACK => .backspace,
        w32.VK_TAB => .tab,
        w32.VK_ESCAPE => .escape,
        w32.VK_SPACE => .space,
        w32.VK_PRIOR => .page_up,
        w32.VK_NEXT => .page_down,
        w32.VK_END => .end,
        w32.VK_HOME => .home,
        w32.VK_LEFT => .arrow_left,
        w32.VK_UP => .arrow_up,
        w32.VK_RIGHT => .arrow_right,
        w32.VK_DOWN => .arrow_down,
        w32.VK_INSERT => .insert,
        w32.VK_DELETE => .delete,
        w32.VK_LSHIFT => .shift_left,
        w32.VK_RSHIFT => .shift_right,
        w32.VK_LCONTROL => .control_left,
        w32.VK_RCONTROL => .control_right,
        w32.VK_LMENU => .alt_left,
        w32.VK_RMENU => .alt_right,
        w32.VK_LWIN => .meta_left,
        w32.VK_RWIN => .meta_right,
        w32.VK_SHIFT => if (extended) .shift_right else .shift_left,
        w32.VK_CONTROL => if (extended) .control_right else .control_left,
        w32.VK_MENU => if (extended) .alt_right else .alt_left,
        w32.VK_CAPITAL => .caps_lock,
        w32.VK_NUMLOCK => .num_lock,
        w32.VK_SCROLL => .scroll_lock,
        w32.VK_OEM_1 => .semicolon,
        w32.VK_OEM_PLUS => .equal,
        w32.VK_OEM_COMMA => .comma,
        w32.VK_OEM_MINUS => .minus,
        w32.VK_OEM_PERIOD => .period,
        w32.VK_OEM_2 => .slash,
        w32.VK_OEM_3 => .backquote,
        w32.VK_OEM_4 => .bracket_left,
        w32.VK_OEM_5 => .backslash,
        w32.VK_OEM_6 => .bracket_right,
        w32.VK_OEM_7 => .quote,
        w32.VK_NUMPAD0 => .numpad_0,
        w32.VK_NUMPAD1 => .numpad_1,
        w32.VK_NUMPAD2 => .numpad_2,
        w32.VK_NUMPAD3 => .numpad_3,
        w32.VK_NUMPAD4 => .numpad_4,
        w32.VK_NUMPAD5 => .numpad_5,
        w32.VK_NUMPAD6 => .numpad_6,
        w32.VK_NUMPAD7 => .numpad_7,
        w32.VK_NUMPAD8 => .numpad_8,
        w32.VK_NUMPAD9 => .numpad_9,
        w32.VK_MULTIPLY => .numpad_multiply,
        w32.VK_ADD => .numpad_add,
        w32.VK_SEPARATOR => .numpad_separator,
        w32.VK_SUBTRACT => .numpad_subtract,
        w32.VK_DECIMAL => .numpad_decimal,
        w32.VK_DIVIDE => .numpad_divide,
        w32.VK_APPS => .context_menu,
        w32.VK_PAUSE => .pause,
        else => .unidentified,
    };
}
pub fn core(self: *Surface) *CoreSurface {
    return &self.core_surface;
}
pub fn rtApp(self: *Surface) *App {
    return self.app;
}
