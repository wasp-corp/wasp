const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("win32.zig");
const terminal = @import("../../../terminal/main.zig");
const Surface = @import("Surface.zig");
const testing = std.testing;
const log = std.log.scoped(.win32_scrollbar);
const SCROLLBAR_WIDTH_BASE: i32 = 14;
const SCROLLBAR_WIDTH_OVERLAY_COLLAPSED: i32 = 8;
const THUMB_MIN_HEIGHT_BASE: i32 = 20;
const FADE_TIMER_ID: usize = 1;
const IDLE_TIMER_ID: usize = 2;
const FADE_INTERVAL_MS: u32 = 16;
const FADE_STEP: u8 = 32;
const IDLE_DELAY_MS: u32 = 1000;
const ALPHA_IDLE: u8 = 80;
const ALPHA_HOVER: u8 = 140;
const ALPHA_DRAG: u8 = 200;
pub const ThumbRect = struct { y: i32, h: i32 };
pub fn thumbRect(
    total: usize,
    offset: usize,
    len: usize,
    track_h: i32,
    min_h: i32,
) ThumbRect {
    if (total == 0 or len >= total) {
        return .{ .y = 0, .h = track_h };
    }
    const total_f: f32 = @floatFromInt(total);
    const offset_f: f32 = @floatFromInt(offset);
    const len_f: f32 = @floatFromInt(len);
    const track_f: f32 = @floatFromInt(track_h);
    const computed_h_f = (len_f / total_f) * track_f;
    const computed_h: i32 = @intFromFloat(@round(computed_h_f));
    const h = @min(track_h, @max(min_h, computed_h));
    const computed_y_f = (offset_f / total_f) * track_f;
    var y: i32 = @intFromFloat(@round(computed_y_f));
    if (y + h > track_h) y = track_h - h;
    if (y < 0) y = 0;
    return .{ .y = y, .h = h };
}
pub fn dragOffset(
    mouse_y: i32,
    drag_anchor: i32,
    track_h: i32,
    thumb_h: i32,
    total: usize,
    len: usize,
) ?usize {
    if (total <= len) return null;
    const track_range = track_h - thumb_h;
    if (track_range <= 0) return null;
    const new_thumb_y = std.math.clamp(mouse_y - drag_anchor, 0, track_range);
    const range_f: f32 = @floatFromInt(track_range);
    const thumb_y_f: f32 = @floatFromInt(new_thumb_y);
    const max_off_f: f32 = @floatFromInt(total - len);
    return @intFromFloat(@round(thumb_y_f / range_f * max_off_f));
}
pub fn effectiveAlpha(base_alpha: u8, fade: u8) u8 {
    const product: u16 = @as(u16, base_alpha) * @as(u16, fade) / 255;
    return @intCast(@min(product, 255));
}
pub const Mode = enum { overlay, always_visible };
pub fn parseMode(value: ?u32) Mode {
    if (value) |v| {
        return if (v == 0) .always_visible else .overlay;
    }
    return .overlay;
}
pub fn readDynamicScrollbars() ?u32 {
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral("Control Panel\\Accessibility");
    const valname = std.unicode.utf8ToUtf16LeStringLiteral("DynamicScrollbars");
    var hkey: w32.HKEY = undefined;
    const open_ret = w32.RegOpenKeyExW(
        w32.HKEY_CURRENT_USER,
        subkey,
        0,
        w32.KEY_READ,
        &hkey,
    );
    if (open_ret != w32.ERROR_SUCCESS) return null;
    defer _ = w32.RegCloseKey(hkey);
    var kind: u32 = 0;
    var val: u32 = 0;
    var cb: u32 = @sizeOf(u32);
    const query_ret = w32.RegQueryValueExW(
        hkey,
        valname,
        null,
        &kind,
        @ptrCast(&val),
        &cb,
    );
    if (query_ret != w32.ERROR_SUCCESS) return null;
    if (kind != w32.REG_DWORD) return null;
    return val;
}
pub fn readMode() Mode {
    return parseMode(readDynamicScrollbars());
}
pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("WaspScrollbar");
pub const WM_WASP_SCROLLBAR_QUERY: u32 = w32.WM_USER + 1;
pub const Visibility = enum(isize) {
    hidden = 0,
    fading_in = 1,
    shown = 2,
    fading_out = 3,
};
pub const Scrollbar = struct {
    alloc: std.mem.Allocator,
    surface: *Surface,
    owner: w32.HWND,
    hwnd: w32.HWND,
    state: terminal.Scrollbar = .zero,
    first_update: bool = true,
    mode: Mode = .overlay,
    bg: terminal.color.RGB = .{ .r = 0, .g = 0, .b = 0 },
    fg: terminal.color.RGB = .{ .r = 255, .g = 255, .b = 255 },
    scale: f32 = 1.0,
    visibility: Visibility = .hidden,
    fade: u8 = 0,
    hover: bool = false,
    dragging: bool = false,
    drag_anchor: i32 = 0,
    pub fn create(
        alloc: std.mem.Allocator,
        owner: w32.HWND,
        surface: *Surface,
    ) !*Scrollbar {
        try registerClassOnce(surface.app.hinstance);
        const self = try alloc.create(Scrollbar);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .surface = surface,
            .owner = owner,
            .hwnd = undefined,
        };
        const ex_style: u32 = w32.WS_EX_LAYERED | w32.WS_EX_NOACTIVATE | w32.WS_EX_TOOLWINDOW;
        const style: u32 = w32.WS_POPUP;
        const hwnd = w32.CreateWindowExW(
            ex_style,
            WINDOW_CLASS_NAME,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            style,
            0,
            0,
            1,
            1,
            owner,
            null,
            surface.app.hinstance,
            null,
        ) orelse return error.Win32Error;
        errdefer _ = w32.DestroyWindow(hwnd);
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        self.hwnd = hwnd;
        self.mode = readMode();
        _ = self.repositionAndResize();
        return self;
    }
    pub fn destroy(self: *Scrollbar) void {
        _ = w32.DestroyWindow(self.hwnd);
        self.alloc.destroy(self);
    }
    pub fn update(self: *Scrollbar, state: terminal.Scrollbar) void {
        const was_first = self.first_update;
        const changed =
            self.state.total != state.total or
            self.state.offset != state.offset or
            self.state.len != state.len;
        self.state = state;
        self.first_update = false;
        if (was_first) {
            switch (self.mode) {
                .overlay => {
                    self.visibility = .hidden;
                    self.fade = 0;
                    self.setTransparent();
                    self.repaint();
                },
                .always_visible => {
                    self.visibility = .shown;
                    self.fade = 255;
                    self.clearTransparent();
                    self.repaint();
                },
            }
            return;
        }
        if (changed) {
            switch (self.mode) {
                .overlay => {
                    if (self.visibility == .hidden or self.visibility == .fading_out) {
                        self.startFadeIn();
                    }
                    self.restartIdleTimer();
                },
                .always_visible => {},
            }
            self.repaint();
        }
    }
    pub fn repositionAndResize(self: *Scrollbar) i32 {
        var rect: w32.RECT = undefined;
        if (w32.GetClientRect(self.owner, &rect) == 0) return 0;
        const client_h = rect.bottom - rect.top;
        const width = self.currentWidth();
        var top_right = w32.POINT{ .x = rect.right - width, .y = rect.top };
        _ = w32.ClientToScreen(self.owner, &top_right);
        _ = w32.SetWindowPos(
            self.hwnd,
            null,
            top_right.x,
            top_right.y,
            width,
            client_h,
            w32.SWP_NOACTIVATE | w32.SWP_NOZORDER | w32.SWP_SHOWWINDOW,
        );
        self.repaint();
        return switch (self.mode) {
            .always_visible => width,
            .overlay => 0,
        };
    }
    pub fn setOwnerVisible(self: *Scrollbar, visible: bool) void {
        _ = w32.ShowWindow(self.hwnd, if (visible) w32.SW_SHOWNOACTIVATE else w32.SW_HIDE);
    }
    pub fn setTheme(self: *Scrollbar, bg: terminal.color.RGB, fg: terminal.color.RGB) void {
        if (std.meta.eql(self.bg, bg) and std.meta.eql(self.fg, fg)) return;
        self.bg = bg;
        self.fg = fg;
        self.repaint();
    }
    fn dpiScaled(self: *const Scrollbar, base: i32) i32 {
        return @intFromFloat(@round(@as(f32, @floatFromInt(base)) * self.scale));
    }
    fn currentWidth(self: *const Scrollbar) i32 {
        return switch (self.mode) {
            .always_visible => self.dpiScaled(SCROLLBAR_WIDTH_BASE),
            .overlay => if (self.hover or self.dragging)
                self.dpiScaled(SCROLLBAR_WIDTH_BASE)
            else
                self.dpiScaled(SCROLLBAR_WIDTH_OVERLAY_COLLAPSED),
        };
    }
    fn repaint(self: *Scrollbar) void {
        var client: w32.RECT = undefined;
        if (w32.GetClientRect(self.hwnd, &client) == 0) return;
        const w = client.right - client.left;
        const h = client.bottom - client.top;
        if (w <= 0 or h <= 0) return;
        const screen_dc = w32.GetDC(null) orelse return;
        defer _ = w32.ReleaseDC(null, screen_dc);
        const mem_dc = w32.CreateCompatibleDC(screen_dc) orelse return;
        defer _ = w32.DeleteDC(mem_dc);
        var bits: ?*anyopaque = null;
        const bmi = w32.BITMAPINFO{
            .bmiHeader = .{
                .biWidth = w,
                .biHeight = -h,
            },
        };
        const bitmap = w32.CreateDIBSection(mem_dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return;
        defer _ = w32.DeleteObject(bitmap);
        const old = w32.SelectObject(mem_dc, bitmap);
        defer _ = w32.SelectObject(mem_dc, old.?);
        self.drawBitmap(@ptrCast(@alignCast(bits.?)), w, h);
        var window_rect: w32.RECT = undefined;
        _ = w32.GetWindowRect(self.hwnd, &window_rect);
        const dst_pt = w32.POINT{ .x = window_rect.left, .y = window_rect.top };
        const dst_size = w32.SIZE{ .cx = w, .cy = h };
        const src_pt = w32.POINT{ .x = 0, .y = 0 };
        const blend = w32.BLENDFUNCTION{
            .SourceConstantAlpha = 255,
        };
        _ = w32.UpdateLayeredWindow(
            self.hwnd,
            screen_dc,
            &dst_pt,
            &dst_size,
            mem_dc,
            &src_pt,
            0,
            &blend,
            w32.ULW_ALPHA,
        );
    }
    fn drawBitmap(self: *Scrollbar, pixels: [*]u32, w: i32, h: i32) void {
        const track_fill: u32 = switch (self.mode) {
            .always_visible => packBGRA(self.bg, 255),
            .overlay => 0,
        };
        const total = w * h;
        var i: i32 = 0;
        while (i < total) : (i += 1) {
            pixels[@intCast(i)] = track_fill;
        }
        const min_h = self.dpiScaled(THUMB_MIN_HEIGHT_BASE);
        const r = thumbRect(self.state.total, self.state.offset, self.state.len, h, min_h);
        const thumb_alpha = self.thumbAlpha();
        const thumb_color = packBGRA(self.fg, thumb_alpha);
        var y: i32 = r.y;
        while (y < r.y + r.h and y < h) : (y += 1) {
            var x: i32 = 0;
            while (x < w) : (x += 1) {
                pixels[@intCast(y * w + x)] = thumb_color;
            }
        }
    }
    fn thumbAlpha(self: *const Scrollbar) u8 {
        const base = if (self.dragging) ALPHA_DRAG else if (self.hover) ALPHA_HOVER else ALPHA_IDLE;
        return switch (self.mode) {
            .always_visible => base,
            .overlay => effectiveAlpha(base, self.fade),
        };
    }
    fn ensureLeaveTracking(self: *Scrollbar) void {
        var tme = w32.TRACKMOUSEEVENT{
            .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
            .dwFlags = w32.TME_LEAVE,
            .hwndTrack = self.hwnd,
            .dwHoverTime = 0,
        };
        _ = w32.TrackMouseEvent(&tme);
    }
    fn trackHeight(self: *const Scrollbar) i32 {
        var rect: w32.RECT = undefined;
        if (w32.GetClientRect(self.hwnd, &rect) == 0) return 0;
        return rect.bottom - rect.top;
    }
    fn currentThumbRect(self: *const Scrollbar) ThumbRect {
        return thumbRect(
            self.state.total,
            self.state.offset,
            self.state.len,
            self.trackHeight(),
            self.dpiScaled(THUMB_MIN_HEIGHT_BASE),
        );
    }
    fn onMouseMove(self: *Scrollbar, x: i32, y: i32) void {
        _ = x;
        if (self.visibility == .hidden or self.visibility == .fading_out) {
            self.startFadeIn();
        }
        self.ensureLeaveTracking();
        if (self.dragging) {
            if (dragOffset(
                y,
                self.drag_anchor,
                self.trackHeight(),
                self.currentThumbRect().h,
                self.state.total,
                self.state.len,
            )) |off| {
                self.state.offset = off;
                self.surface.scrollToOffset(off);
                self.repaint();
            }
            return;
        }
        if (!self.hover) {
            self.hover = true;
            self.repaint();
        }
    }
    fn onMouseLeave(self: *Scrollbar) void {
        if (self.hover) {
            self.hover = false;
            self.repaint();
        }
        if (!self.dragging) self.restartIdleTimer();
    }
    fn onLeftDown(self: *Scrollbar, y: i32) void {
        const r = self.currentThumbRect();
        if (y >= r.y and y < r.y + r.h) {
            _ = w32.SetCapture(self.hwnd);
            self.drag_anchor = y - r.y;
            self.dragging = true;
        } else {
            const total = self.state.total;
            const len = self.state.len;
            if (total <= len) return;
            const max = total - len;
            const new_off = if (y < r.y)
                (if (self.state.offset > len) self.state.offset - len else 0)
            else
                @min(self.state.offset + len, max);
            self.state.offset = new_off;
            self.surface.scrollToOffset(new_off);
            self.repaint();
        }
    }
    fn onLeftUp(self: *Scrollbar) void {
        if (self.dragging) {
            _ = w32.ReleaseCapture();
            self.dragging = false;
            self.repaint();
        }
    }
    pub fn onSettingsChange(self: *Scrollbar) bool {
        const new_mode = readMode();
        if (new_mode == self.mode) return false;
        self.mode = new_mode;
        switch (new_mode) {
            .overlay => {
                self.visibility = .hidden;
                self.fade = 0;
                self.setTransparent();
                self.repaint();
            },
            .always_visible => {
                self.visibility = .shown;
                self.fade = 255;
                self.clearTransparent();
                self.repaint();
            },
        }
        return true;
    }
    pub fn onDpiChanged(self: *Scrollbar, dpi: u32) void {
        self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
    }
    fn startFadeIn(self: *Scrollbar) void {
        self.visibility = .fading_in;
        _ = w32.SetTimer(self.hwnd, FADE_TIMER_ID, FADE_INTERVAL_MS, null);
        self.clearTransparent();
        self.repaint();
    }
    fn startFadeOut(self: *Scrollbar) void {
        self.visibility = .fading_out;
        _ = w32.SetTimer(self.hwnd, FADE_TIMER_ID, FADE_INTERVAL_MS, null);
        self.repaint();
    }
    fn restartIdleTimer(self: *Scrollbar) void {
        _ = w32.SetTimer(self.hwnd, IDLE_TIMER_ID, IDLE_DELAY_MS, null);
    }
    fn onFadeTick(self: *Scrollbar) void {
        switch (self.visibility) {
            .fading_in => {
                const new_fade = @min(@as(u16, self.fade) + FADE_STEP, 255);
                self.fade = @intCast(new_fade);
                if (self.fade == 255) {
                    self.visibility = .shown;
                    _ = w32.KillTimer(self.hwnd, FADE_TIMER_ID);
                }
                self.repaint();
            },
            .fading_out => {
                const new_fade = if (self.fade > FADE_STEP) self.fade - FADE_STEP else 0;
                self.fade = new_fade;
                if (self.fade == 0) {
                    self.visibility = .hidden;
                    _ = w32.KillTimer(self.hwnd, FADE_TIMER_ID);
                    self.setTransparent();
                }
                self.repaint();
            },
            else => _ = w32.KillTimer(self.hwnd, FADE_TIMER_ID),
        }
    }
    fn onIdleTick(self: *Scrollbar) void {
        _ = w32.KillTimer(self.hwnd, IDLE_TIMER_ID);
        if (self.dragging or self.hover) return;
        self.startFadeOut();
    }
    fn setTransparent(self: *Scrollbar) void {
        const cur = w32.GetWindowLongW(self.hwnd, w32.GWL_EXSTYLE);
        _ = w32.SetWindowLongW(self.hwnd, w32.GWL_EXSTYLE, cur | w32.WS_EX_TRANSPARENT);
    }
    fn clearTransparent(self: *Scrollbar) void {
        const cur = w32.GetWindowLongW(self.hwnd, w32.GWL_EXSTYLE);
        _ = w32.SetWindowLongW(self.hwnd, w32.GWL_EXSTYLE, cur & ~w32.WS_EX_TRANSPARENT);
    }
};
fn packBGRA(c: terminal.color.RGB, a: u8) u32 {
    const af: f32 = @as(f32, @floatFromInt(a)) / 255.0;
    const r: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(c.r)) * af));
    const g: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(c.g)) * af));
    const b: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(c.b)) * af));
    return (@as(u32, a) << 24) | (r << 16) | (g << 8) | b;
}
var class_registered: bool = false;
fn registerClassOnce(hinstance: w32.HINSTANCE) !void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = scrollbarWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}
fn scrollbarWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const ud = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self_opt: ?*Scrollbar = if (ud == 0) null else @ptrFromInt(@as(usize, @bitCast(ud)));
    const self = self_opt orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,
        w32.WM_TIMER => {
            switch (wparam) {
                FADE_TIMER_ID => self.onFadeTick(),
                IDLE_TIMER_ID => self.onIdleTick(),
                else => {},
            }
            return 0;
        },
        w32.WM_MOUSEMOVE => {
            const x: i32 = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) & 0xFFFF))));
            const y: i32 = @as(i16, @bitCast(@as(u16, @truncate((@as(usize, @bitCast(lparam)) >> 16) & 0xFFFF))));
            self.onMouseMove(x, y);
            return 0;
        },
        w32.WM_MOUSELEAVE => {
            self.onMouseLeave();
            return 0;
        },
        w32.WM_LBUTTONDOWN => {
            const y: i32 = @as(i16, @bitCast(@as(u16, @truncate((@as(usize, @bitCast(lparam)) >> 16) & 0xFFFF))));
            self.onLeftDown(y);
            return 0;
        },
        w32.WM_LBUTTONUP => {
            self.onLeftUp();
            return 0;
        },
        WM_WASP_SCROLLBAR_QUERY => return @intFromEnum(self.visibility),
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
test "thumbRect: thumb at top when offset is 0" {
    const r = thumbRect(1000, 0, 50, 400, 20);
    try testing.expectEqual(@as(i32, 0), r.y);
    try testing.expectEqual(@as(i32, 20), r.h);
}
test "thumbRect: thumb at bottom when offset = total - len" {
    const r = thumbRect(1000, 950, 50, 400, 20);
    try testing.expectEqual(@as(i32, 380), r.y);
    try testing.expectEqual(@as(i32, 20), r.h);
}
test "thumbRect: enforces minimum height" {
    const r = thumbRect(10000, 0, 1, 400, 20);
    try testing.expectEqual(@as(i32, 20), r.h);
}
test "thumbRect: total == 0 returns full track" {
    const r = thumbRect(0, 0, 0, 400, 20);
    try testing.expectEqual(@as(i32, 0), r.y);
    try testing.expectEqual(@as(i32, 400), r.h);
}
test "dragOffset: top of track" {
    const off = dragOffset(0, 0, 400, 20, 1000, 50).?;
    try testing.expectEqual(@as(usize, 0), off);
}
test "dragOffset: bottom of track" {
    const off = dragOffset(380, 0, 400, 20, 1000, 50).?;
    try testing.expectEqual(@as(usize, 950), off);
}
test "dragOffset: middle of track" {
    const off = dragOffset(190, 0, 400, 20, 1000, 50).?;
    try testing.expectEqual(@as(usize, 475), off);
}
test "dragOffset: clamped above" {
    const off = dragOffset(-100, 0, 400, 20, 1000, 50).?;
    try testing.expectEqual(@as(usize, 0), off);
}
test "dragOffset: clamped below" {
    const off = dragOffset(99999, 0, 400, 20, 1000, 50).?;
    try testing.expectEqual(@as(usize, 950), off);
}
test "dragOffset: returns null when total <= len" {
    try testing.expectEqual(@as(?usize, null), dragOffset(50, 0, 400, 20, 50, 100));
    try testing.expectEqual(@as(?usize, null), dragOffset(50, 0, 400, 20, 50, 50));
}
test "dragOffset: returns null when thumb fills track" {
    try testing.expectEqual(@as(?usize, null), dragOffset(0, 0, 400, 400, 1000, 50));
}
test "effectiveAlpha: full fade" {
    try testing.expectEqual(@as(u8, 80), effectiveAlpha(80, 255));
}
test "effectiveAlpha: half fade" {
    try testing.expectEqual(@as(u8, 40), effectiveAlpha(80, 128));
}
test "effectiveAlpha: zero fade" {
    try testing.expectEqual(@as(u8, 0), effectiveAlpha(80, 0));
}
test "parseMode: missing value defaults to overlay" {
    try testing.expectEqual(Mode.overlay, parseMode(null));
}
test "parseMode: 1 is overlay" {
    try testing.expectEqual(Mode.overlay, parseMode(1));
}
test "parseMode: 0 is always_visible" {
    try testing.expectEqual(Mode.always_visible, parseMode(0));
}
test "thumbRect: clamps when min_h exceeds track_h" {
    const r = thumbRect(1000, 0, 50, 10, 20);
    try testing.expect(r.h <= 10);
    try testing.expect(r.y + r.h <= 10);
}
test "thumbRect: clamps when offset would push thumb past bottom" {
    const r = thumbRect(1000, 999, 50, 400, 20);
    try testing.expectEqual(@as(i32, 380), r.y);
    try testing.expectEqual(@as(i32, 20), r.h);
    try testing.expect(r.y + r.h <= 400);
}
test "dragOffset: applies drag_anchor" {
    const a = dragOffset(190, 100, 400, 20, 1000, 50).?;
    const b = dragOffset(90, 0, 400, 20, 1000, 50).?;
    try testing.expectEqual(b, a);
}
test "dragOffset: rounds half to nearest" {
    const off = dragOffset(191, 0, 400, 20, 1000, 50).?;
    try testing.expect(off == 477 or off == 478);
}
test "parseMode: non-{0,1} value treated as overlay" {
    try testing.expectEqual(Mode.overlay, parseMode(2));
    try testing.expectEqual(Mode.overlay, parseMode(99));
}
