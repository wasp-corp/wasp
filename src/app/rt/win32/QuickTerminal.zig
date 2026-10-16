const QuickTerminal = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const configpkg = @import("../../../config.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const Surface = @import("Surface.zig");
const w32 = @import("win32.zig");
const log = std.log.scoped(.win32_quick_terminal);
pub const ANIM_TIMER_ID: usize = 3;
const ANIM_TICK_MS: u32 = 16;
app: *App,
window: *Window,
visible: bool = false,
animating: bool = false,
animation_direction: enum { in, out } = .in,
animation_start_time: i64 = 0,
animation_duration: f64 = 0.2,
perf_freq: i64 = 1, 
target_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
hidden_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
pub fn init(app: *App) !*QuickTerminal {
    const alloc = app.core_app.alloc;
    const self = try alloc.create(QuickTerminal);
    errdefer alloc.destroy(self);
    self.* = .{
        .app = app,
        .window = undefined,
    };
    _ = w32.QueryPerformanceFrequency(&self.perf_freq);
    self.animation_duration = app.config.@"quick-terminal-animation-duration";
    const window = try alloc.create(Window);
    errdefer alloc.destroy(window);
    try window.init(app, .{ .is_quick_terminal = true });
    self.window = window;
    _ = try window.addTab();
    return self;
}
pub fn deinit(self: *QuickTerminal) void {
    const alloc = self.app.core_app.alloc;
    const app = self.app;
    if (self.animating) {
        _ = w32.KillTimer(app.msg_hwnd, ANIM_TIMER_ID);
        self.animating = false;
    }
    app.quick_terminal = null;
    self.window.close();
    alloc.destroy(self.window);
    alloc.destroy(self);
}
pub fn toggle(self: *QuickTerminal) void {
    if (self.animating) {
        self.animation_direction = if (self.animation_direction == .in) .out else .in;
        const elapsed_ticks = self.now() - self.animation_start_time;
        const elapsed = @as(f64, @floatFromInt(elapsed_ticks)) / @as(f64, @floatFromInt(self.perf_freq));
        const progress = @min(elapsed / self.animation_duration, 1.0);
        const remaining = (1.0 - progress) * self.animation_duration;
        self.animation_start_time = self.now() - @as(i64, @intFromFloat(remaining * @as(f64, @floatFromInt(self.perf_freq))));
        return;
    }
    if (self.visible) {
        self.animateOut();
    } else {
        self.animateIn();
    }
}
fn animateIn(self: *QuickTerminal) void {
    self.calculateRects();
    const hwnd = self.window.hwnd orelse return;
    _ = w32.SetWindowPos(
        hwnd,
        w32.HWND_TOPMOST,
        self.hidden_rect.left,
        self.hidden_rect.top,
        self.hidden_rect.right - self.hidden_rect.left,
        self.hidden_rect.bottom - self.hidden_rect.top,
        w32.SWP_NOACTIVATE,
    );
    _ = w32.ShowWindow(hwnd, w32.SW_SHOWNOACTIVATE);
    if (self.animation_duration <= 0) {
        _ = w32.SetWindowPos(
            hwnd,
            w32.HWND_TOPMOST,
            self.target_rect.left,
            self.target_rect.top,
            self.target_rect.right - self.target_rect.left,
            self.target_rect.bottom - self.target_rect.top,
            w32.SWP_NOACTIVATE,
        );
        self.visible = true;
        self.forceForeground();
        return;
    }
    self.animation_direction = .in;
    self.animation_start_time = self.now();
    self.animating = true;
    _ = w32.SetTimer(self.app.msg_hwnd, ANIM_TIMER_ID, ANIM_TICK_MS, null);
}
fn animateOut(self: *QuickTerminal) void {
    if (self.animation_duration <= 0) {
        if (self.window.hwnd) |hwnd| {
            _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
        }
        self.visible = false;
        return;
    }
    self.animation_direction = .out;
    self.animation_start_time = self.now();
    self.animating = true;
    _ = w32.SetTimer(self.app.msg_hwnd, ANIM_TIMER_ID, ANIM_TICK_MS, null);
}
pub fn onAnimationTick(self: *QuickTerminal) void {
    if (!self.animating) return;
    const elapsed_ticks = self.now() - self.animation_start_time;
    const elapsed = @as(f64, @floatFromInt(elapsed_ticks)) / @as(f64, @floatFromInt(self.perf_freq));
    const progress = @min(elapsed / self.animation_duration, 1.0);
    const t = if (self.animation_direction == .in) easeInOutCubic(progress) else 1.0 - easeInOutCubic(progress);
    const hwnd = self.window.hwnd orelse return;
    const x = lerp(self.hidden_rect.left, self.target_rect.left, t);
    const y = lerp(self.hidden_rect.top, self.target_rect.top, t);
    const w = self.target_rect.right - self.target_rect.left;
    const h = self.target_rect.bottom - self.target_rect.top;
    _ = w32.SetWindowPos(hwnd, w32.HWND_TOPMOST, x, y, w, h, w32.SWP_NOACTIVATE);
    if (progress >= 1.0) {
        _ = w32.KillTimer(self.app.msg_hwnd, ANIM_TIMER_ID);
        self.animating = false;
        if (self.animation_direction == .in) {
            self.visible = true;
            self.forceForeground();
        } else {
            self.visible = false;
            _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
        }
    }
}
pub fn onFocusLost(self: *QuickTerminal) void {
    if (!self.visible) return;
    if (self.animating and self.animation_direction == .out) return;
    if (!self.app.config.@"quick-terminal-autohide") return;
    self.animateOut();
}
pub fn onWindowDestroyed(self: *QuickTerminal) void {
    const alloc = self.app.core_app.alloc;
    const app = self.app;
    _ = w32.KillTimer(app.msg_hwnd, ANIM_TIMER_ID);
    alloc.destroy(self.window);
    app.quick_terminal = null;
    alloc.destroy(self);
    if (app.windows.items.len == 0) {
        app.startQuitTimer();
    }
}
pub fn onConfigChange(self: *QuickTerminal, config: *const configpkg.Config) void {
    self.animation_duration = config.@"quick-terminal-animation-duration";
}
fn calculateRects(self: *QuickTerminal) void {
    const config = &self.app.config;
    const position = config.@"quick-terminal-position";
    const monitor = self.getMonitor() orelse return;
    var mi = w32.MONITORINFO{
        .cbSize = @sizeOf(w32.MONITORINFO),
        .rcMonitor = undefined,
        .rcWork = undefined,
        .dwFlags = 0,
    };
    if (w32.GetMonitorInfoW(monitor, &mi) == 0) return;
    const work = mi.rcWork;
    const mw: u32 = @intCast(work.right - work.left);
    const mh: u32 = @intCast(work.bottom - work.top);
    const size = config.@"quick-terminal-size".calculate(position, .{
        .width = mw,
        .height = mh,
    });
    const scale = self.window.scale;
    var qw: i32 = if (config.@"quick-terminal-size".primary != null or config.@"quick-terminal-size".secondary != null)
        @intCast(size.width)
    else
        @intFromFloat(@round(@as(f32, @floatFromInt(size.width)) * scale));
    var qh: i32 = if (config.@"quick-terminal-size".primary != null or config.@"quick-terminal-size".secondary != null)
        @intCast(size.height)
    else
        @intFromFloat(@round(@as(f32, @floatFromInt(size.height)) * scale));
    if (qw > @as(i32, @intCast(mw))) qw = @intCast(mw);
    if (qh > @as(i32, @intCast(mh))) qh = @intCast(mh);
    switch (position) {
        .top => {
            self.target_rect = .{ .left = work.left, .top = work.top, .right = work.left + qw, .bottom = work.top + qh };
            self.hidden_rect = .{ .left = work.left, .top = work.top - qh, .right = work.left + qw, .bottom = work.top };
        },
        .bottom => {
            self.target_rect = .{ .left = work.left, .top = work.bottom - qh, .right = work.left + qw, .bottom = work.bottom };
            self.hidden_rect = .{ .left = work.left, .top = work.bottom, .right = work.left + qw, .bottom = work.bottom + qh };
        },
        .left => {
            self.target_rect = .{ .left = work.left, .top = work.top, .right = work.left + qw, .bottom = work.top + qh };
            self.hidden_rect = .{ .left = work.left - qw, .top = work.top, .right = work.left, .bottom = work.top + qh };
        },
        .right => {
            self.target_rect = .{ .left = work.right - qw, .top = work.top, .right = work.right, .bottom = work.top + qh };
            self.hidden_rect = .{ .left = work.right, .top = work.top, .right = work.right + qw, .bottom = work.top + qh };
        },
        .center => {
            const cx = work.left + @divTrunc(@as(i32, @intCast(mw)) - qw, 2);
            const cy = work.top + @divTrunc(@as(i32, @intCast(mh)) - qh, 2);
            self.target_rect = .{ .left = cx, .top = cy, .right = cx + qw, .bottom = cy + qh };
            self.hidden_rect = .{ .left = cx, .top = work.top - qh, .right = cx + qw, .bottom = work.top };
        },
    }
}
fn getMonitor(self: *QuickTerminal) ?w32.HMONITOR {
    const screen = self.app.config.@"quick-terminal-screen";
    switch (screen) {
        .main, .@"macos-menu-bar" => {
            return w32.MonitorFromPoint(.{ .x = 0, .y = 0 }, w32.MONITOR_DEFAULTTOPRIMARY);
        },
        .mouse => {
            var pt: w32.POINT = undefined;
            if (w32.GetCursorPos_(&pt) != 0) {
                return w32.MonitorFromPoint(pt, w32.MONITOR_DEFAULTTONEAREST);
            }
            return w32.MonitorFromPoint(.{ .x = 0, .y = 0 }, w32.MONITOR_DEFAULTTOPRIMARY);
        },
    }
}
fn forceForeground(self: *QuickTerminal) void {
    const hwnd = self.window.hwnd orelse return;
    const fg = w32.GetForegroundWindow();
    if (fg) |fg_hwnd| {
        const fg_tid = w32.GetWindowThreadProcessId(fg_hwnd, null);
        const our_tid = w32.GetCurrentThreadId();
        if (fg_tid != our_tid) {
            _ = w32.AttachThreadInput(our_tid, fg_tid, 1);
            _ = w32.SetForegroundWindow(hwnd);
            _ = w32.AttachThreadInput(our_tid, fg_tid, 0);
        } else {
            _ = w32.SetForegroundWindow(hwnd);
        }
    } else {
        _ = w32.SetForegroundWindow(hwnd);
    }
    if (self.window.getActiveSurface()) |s| {
        if (s.hwnd) |sh| _ = w32.SetFocus(sh);
    }
}
fn now(_: *QuickTerminal) i64 {
    var count: i64 = 0;
    _ = w32.QueryPerformanceCounter(&count);
    return count;
}
fn easeInOutCubic(t: f64) f64 {
    if (t < 0.5) {
        return 4.0 * t * t * t;
    } else {
        const f = -2.0 * t + 2.0;
        return 1.0 - (f * f * f) / 2.0;
    }
}
fn lerp(a: i32, b: i32, t: f64) i32 {
    return a + @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(b - a)) * t)));
}
