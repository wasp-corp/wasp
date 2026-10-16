const Window = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../../root.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const SplitTree = @import("../../../datastruct/split_tree.zig").SplitTree;
const w32 = @import("win32.zig");
const log = std.log.scoped(.win32);
const MAX_TABS: usize = 64;
app: *App,
hwnd: ?w32.HWND = null,
tab_count: usize = 0,
tab_trees: [64]SplitTree(Surface) = undefined,
tab_active_surface: [64]*Surface = undefined,
active_tab: usize = 0,
tab_bar_visible: bool = false,
scale: f32 = 1.0,
tab_rects: [64]w32.RECT = std.mem.zeroes([64]w32.RECT),
new_tab_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
hover_tab: isize = -1,
hover_close: bool = false,
hover_new_tab: bool = false,
drag_tab: isize = -1,
drag_start_x: i16 = 0,
drag_active: bool = false,
rename_edit: ?w32.HWND = null,
rename_font: ?*anyopaque = null,
rename_tab: usize = 0,
rename_window: bool = false,
tab_titles: [64][256]u16 = undefined,
tab_title_lens: [64]u16 = undefined,
window_title_override_len: ?u16 = null,
window_title_override: [256]u16 = undefined,
is_fullscreen: bool = false,
saved_style: u32 = 0,
saved_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
tab_font: ?*anyopaque = null,
tracking_mouse: bool = false,
is_quick_terminal: bool = false,
dragging_split: bool = false,
drag_split_handle: SplitTree(Surface).Node.Handle = .root,
drag_split_layout: SplitTree(Surface).Split.Layout = .horizontal,
drag_start_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
closing: bool = false,
min_track_w: i32 = 0,
min_track_h: i32 = 0,
max_track_w: i32 = 0,
max_track_h: i32 = 0,
resize_overlay_hwnd: ?w32.HWND = null,
resize_seen_first: bool = false,
pub const InitOptions = struct {
    is_quick_terminal: bool = false,
    force_opaque: bool = false,
};
fn systemUsesLightTheme() bool {
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral(
        "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
    );
    const valname = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");
    var hkey: w32.HKEY = undefined;
    if (w32.RegOpenKeyExW(w32.HKEY_CURRENT_USER, subkey, 0, w32.KEY_READ, &hkey) !=
        w32.ERROR_SUCCESS) return true;
    defer _ = w32.RegCloseKey(hkey);
    var kind: u32 = 0;
    var val: u32 = 0;
    var cb: u32 = @sizeOf(u32);
    if (w32.RegQueryValueExW(hkey, valname, null, &kind, @ptrCast(&val), &cb) !=
        w32.ERROR_SUCCESS) return true;
    if (kind != w32.REG_DWORD) return true;
    return val != 0;
}
fn applyChromeTheme(hwnd: w32.HWND, theme: anytype, bg: anytype) void {
    const luminance: f32 = (0.2126 * @as(f32, @floatFromInt(bg.r)) +
        0.7152 * @as(f32, @floatFromInt(bg.g)) +
        0.0722 * @as(f32, @floatFromInt(bg.b))) / 255.0;
    const by_luminance = luminance < 0.5;
    const dark = switch (theme) {
        .dark => true,
        .light => false,
        .system => !systemUsesLightTheme(),
        .auto, .wasp => by_luminance,
    };
    const dark_mode: u32 = if (dark) 1 else 0;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );
    const tint_caption = switch (theme) {
        .auto, .wasp => true,
        else => false,
    };
    const caption_color: u32 = if (tint_caption)
        (@as(u32, bg.r)) | (@as(u32, bg.g) << 8) | (@as(u32, bg.b) << 16)
    else
        w32.DWMWA_COLOR_DEFAULT;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_CAPTION_COLOR,
        @ptrCast(&caption_color),
        @sizeOf(u32),
    );
}
fn applyBackgroundBlur(hwnd: w32.HWND, enabled: bool) void {
    var policy: w32.ACCENT_POLICY = .{
        .AccentState = if (enabled) w32.ACCENT_ENABLE_BLURBEHIND else w32.ACCENT_DISABLED,
        .AccentFlags = 0,
        .GradientColor = 0,
        .AnimationId = 0,
    };
    var data: w32.WINDOWCOMPOSITIONATTRIBDATA = .{
        .Attrib = w32.WCA_ACCENT_POLICY,
        .pvData = @ptrCast(&policy),
        .cbData = @sizeOf(w32.ACCENT_POLICY),
    };
    _ = w32.SetWindowCompositionAttribute(hwnd, &data);
}
pub fn onConfigChange(self: *Window) void {
    if (self.hwnd) |hwnd| {
        applyChromeTheme(hwnd, self.app.config.@"window-theme", self.app.config.background);
        applyBackgroundBlur(hwnd, self.app.config.@"background-blur".enabled());
    }
}
pub fn init(self: *Window, app: *App, options: InitOptions) !void {
    self.* = .{
        .app = app,
        .is_quick_terminal = options.is_quick_terminal,
    };
    const style: u32 = if (options.is_quick_terminal)
        w32.WS_POPUP
    else if (app.config.@"window-decoration" == .none)
        w32.WS_POPUP | w32.WS_THICKFRAME
    else
        w32.WS_OVERLAPPEDWINDOW;
    const ex_style: u32 = if (options.is_quick_terminal) w32.WS_EX_TOOLWINDOW else 0;
    const cascade_step: i32 = 30;
    var cx: i32 = w32.CW_USEDEFAULT;
    var cy: i32 = w32.CW_USEDEFAULT;
    if (!options.is_quick_terminal) {
        if (app.config.@"window-position-x") |px| {
            if (app.config.@"window-position-y") |py| {
                cx = px;
                cy = py;
            }
        }
    }
    if (!options.is_quick_terminal and
        cx == w32.CW_USEDEFAULT and cy == w32.CW_USEDEFAULT and
        app.windows.items.len > 0)
    {
        const prev = app.windows.items[app.windows.items.len - 1];
        if (prev.hwnd) |ph| {
            var prev_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            if (w32.GetWindowRect(ph, &prev_rect) != 0) {
                cx = prev_rect.left + cascade_step;
                cy = prev_rect.top + cascade_step;
                if (cx + 800 > w32.GetSystemMetrics(0) or
                    cy + 600 > w32.GetSystemMetrics(1))
                {
                    cx = w32.CW_USEDEFAULT;
                    cy = w32.CW_USEDEFAULT;
                }
            }
        }
    }
    const hwnd = w32.CreateWindowExW(
        ex_style,
        App.WINDOW_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral("Wasp"),
        style,
        cx,
        cy,
        800,
        600,
        null,
        null,
        app.hinstance,
        null,
    ) orelse return error.Win32Error;
    self.hwnd = hwnd;
    errdefer {
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    applyChromeTheme(hwnd, app.config.@"window-theme", app.config.background);
    _ = w32.SetWindowTheme(
        hwnd,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );
    if (app.config.@"background-opacity" < 1.0 and !options.force_opaque) {
        const current_ex = w32.GetWindowLongW(hwnd, w32.GWL_EXSTYLE);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_EXSTYLE, current_ex | w32.WS_EX_LAYERED);
        const alpha: u8 = @intFromFloat(@round(app.config.@"background-opacity" * 255.0));
        _ = w32.SetLayeredWindowAttributes(hwnd, 0, alpha, w32.LWA_ALPHA);
    }
    if (app.config.@"background-blur".enabled()) {
        applyBackgroundBlur(hwnd, true);
    }
    const dpi = w32.GetDpiForWindow(hwnd);
    if (dpi != 0) {
        self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
    }
    const font_height: i32 = -@as(i32, @intFromFloat(16.0 * self.scale));
    self.tab_font = w32.CreateFontW(
        font_height,
        0,
        0,
        0,
        w32.FW_NORMAL,
        0,
        0,
        0,
        w32.DEFAULT_CHARSET,
        0,
        0,
        0,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );
}
pub fn deinit(self: *Window) void {
    self.cleanupAllSurfaces();
    if (self.tab_font) |font| {
        _ = w32.DeleteObject(font);
        self.tab_font = null;
    }
    if (self.hwnd) |hwnd| {
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }
}
pub fn tabBarHeight(self: *const Window) i32 {
    if (!self.tab_bar_visible) return 0;
    return @intFromFloat(@round(32.0 * self.scale));
}
pub fn surfaceRect(self: *const Window) w32.RECT {
    const hwnd = self.hwnd orelse return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &rect) == 0) {
        return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    }
    rect.top += self.tabBarHeight();
    return rect;
}
pub fn getActiveSurface(self: *Window) ?*Surface {
    if (self.tab_count == 0) return null;
    return self.tab_active_surface[self.active_tab];
}
pub fn findTabIndex(self: *Window, surface: *Surface) ?usize {
    for (self.tab_active_surface[0..self.tab_count], 0..) |s, i| {
        if (s == surface) return i;
    }
    for (0..self.tab_count) |i| {
        var it = self.tab_trees[i].iterator();
        while (it.next()) |entry| {
            if (entry.view == surface) return i;
        }
    }
    return null;
}
fn findHandle(self: *Window, tab_idx: usize, surface: *Surface) ?SplitTree(Surface).Node.Handle {
    var it = self.tab_trees[tab_idx].iterator();
    while (it.next()) |entry| {
        if (entry.view == surface) return entry.handle;
    }
    return null;
}
pub fn addTab(self: *Window) !*Surface {
    return self.addTabWithOptions(.{ .context = .tab });
}
pub const AddTabOptions = Surface.InitOptions;
pub fn addTabWithOptions(self: *Window, options: AddTabOptions) !*Surface {
    if (self.closing) return error.WindowClosing;
    if (self.tab_count >= MAX_TABS) return error.TooManyTabs;
    self.cancelTabRename();
    const alloc = self.app.core_app.alloc;
    const surface = try alloc.create(Surface);
    try surface.initWithOptions(self.app, self, options);
    var tree = SplitTree(Surface).init(alloc, surface) catch |err| {
        surface.deinit();
        if (!surface.leaked) alloc.destroy(surface);
        return err;
    };
    errdefer tree.deinit();
    const pos: usize = switch (self.app.config.@"window-new-tab-position") {
        .current => if (self.tab_count > 0) self.active_tab + 1 else 0,
        .end => self.tab_count,
    };
    var i: usize = self.tab_count;
    while (i > pos) : (i -= 1) {
        self.tab_trees[i] = self.tab_trees[i - 1];
        self.tab_active_surface[i] = self.tab_active_surface[i - 1];
        self.tab_titles[i] = self.tab_titles[i - 1];
        self.tab_title_lens[i] = self.tab_title_lens[i - 1];
    }
    self.tab_trees[pos] = tree;
    self.tab_active_surface[pos] = surface;
    self.tab_count += 1;
    const default_title = std.unicode.utf8ToUtf16LeStringLiteral("Wasp");
    @memcpy(self.tab_titles[pos][0..default_title.len], default_title);
    self.tab_title_lens[pos] = @intCast(default_title.len);
    if (self.tab_count == 1) {
        if (!self.is_quick_terminal) {
            if (self.hwnd) |h| {
                _ = w32.ShowWindow(h, w32.SW_SHOW);
                _ = w32.UpdateWindow(h);
            }
        }
        self.active_tab = pos;
        self.updateWindowTitle();
        if (!self.is_quick_terminal) {
            if (surface.hwnd) |h| _ = w32.SetFocus(h);
        }
    } else {
        self.selectTabIndex(pos);
    }
    self.updateTabBarVisibility();
    return surface;
}
pub fn closeTab(self: *Window, surface: *Surface) void {
    log.debug("closeTab called for surface={x} tab_count={}", .{ @intFromPtr(surface), self.tab_count });
    const idx = self.findTabIndex(surface) orelse return;
    self.closeTabByIndex(idx);
}
fn closeTabByIndex(self: *Window, idx: usize) void {
    if (idx >= self.tab_count) return;
    self.cancelTabRename();
    var tree = self.tab_trees[idx];
    tree.deinit();
    var i: usize = idx;
    while (i + 1 < self.tab_count) : (i += 1) {
        self.tab_trees[i] = self.tab_trees[i + 1];
        self.tab_active_surface[i] = self.tab_active_surface[i + 1];
        self.tab_titles[i] = self.tab_titles[i + 1];
        self.tab_title_lens[i] = self.tab_title_lens[i + 1];
    }
    self.tab_count -= 1;
    if (self.tab_count == 0) {
        self.closing = true;
        if (self.hwnd) |hwnd| _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
        return;
    }
    if (self.active_tab >= self.tab_count) {
        self.active_tab = self.tab_count - 1;
    } else if (self.active_tab > idx) {
        self.active_tab -= 1;
    }
    self.selectTabIndex(self.active_tab);
    self.updateTabBarVisibility();
}
pub fn closeTabMode(self: *Window, mode: apprt.action.CloseTabMode, surface: *Surface) void {
    switch (mode) {
        .this => self.closeSplitSurface(surface),
        .other => {
            var current = self.findTabIndex(surface) orelse return;
            var i: usize = self.tab_count;
            while (i > 0) {
                i -= 1;
                if (i != current) {
                    self.closeTabByIndex(i);
                    if (i < current) current -= 1;
                }
            }
        },
        .right => {
            const current = self.findTabIndex(surface) orelse return;
            var i: usize = self.tab_count;
            while (i > current + 1) {
                i -= 1;
                self.closeTabByIndex(i);
            }
        },
    }
}
pub fn closeSplitSurface(self: *Window, surface: *Surface) void {
    const alloc = self.app.core_app.alloc;
    const tab = self.findTabIndex(surface) orelse {
        log.debug("closeSplitSurface: surface not found in any tab", .{});
        return;
    };
    const tree = &self.tab_trees[tab];
    if (!tree.isSplit()) {
        log.debug("closeSplitSurface: not split, closing whole tab", .{});
        self.closeTab(surface);
        return;
    }
    const handle = self.findHandle(tab, surface) orelse {
        log.debug("closeSplitSurface: handle not found", .{});
        return;
    };
    log.debug("closeSplitSurface: removing handle={} from tab={}", .{ handle.idx(), tab });
    const next_handle = (tree.goto(alloc, handle, .next) catch null) orelse
        (tree.goto(alloc, handle, .previous) catch null);
    const next_surface: ?*Surface = if (next_handle) |nh| blk: {
        break :blk switch (tree.nodes[nh.idx()]) {
            .leaf => |v| v,
            .split => null,
        };
    } else null;
    log.debug("closeSplitSurface: has_next={}", .{next_surface != null});
    const new_tree = tree.remove(alloc, handle) catch {
        log.err("failed to remove surface from split tree", .{});
        return;
    };
    log.debug("closeSplitSurface: remove returned, new_tree nodes={}", .{new_tree.nodes.len});
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;
    if (next_surface) |ns| {
        log.debug("closeSplitSurface: focusing next surface", .{});
        self.tab_active_surface[tab] = ns;
        self.layoutSplits();
        if (ns.hwnd) |h| _ = w32.SetFocus(h);
    } else {
        log.debug("closeSplitSurface: no next surface, closing tab", .{});
        self.closeTabByIndex(tab);
    }
}
fn setActiveTabVisible(self: *Window, visible: bool) void {
    if (self.active_tab >= self.tab_count) return;
    var it = self.tab_trees[self.active_tab].iterator();
    while (it.next()) |entry| entry.view.setVisible(visible);
}
pub fn selectTabIndex(self: *Window, idx: usize) void {
    if (idx >= self.tab_count) return;
    self.cancelTabRename();
    if (self.drag_tab >= 0) {
        self.drag_tab = -1;
        self.drag_active = false;
        _ = w32.ReleaseCapture();
    }
    if (self.active_tab < self.tab_count) {
        var it = self.tab_trees[self.active_tab].iterator();
        while (it.next()) |entry| {
            entry.view.setVisible(false);
            if (entry.view.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
        }
    }
    self.active_tab = idx;
    const surface = self.tab_active_surface[idx];
    self.layoutSplits();
    if (surface.hwnd) |h| _ = w32.SetFocus(h);
    self.updateWindowTitle();
}
pub fn layoutSplits(self: *Window) void {
    if (self.tab_count == 0) return;
    const tree = self.tab_trees[self.active_tab];
    const rect = self.surfaceRect();
    if (tree.zoomed) |zoomed_handle| {
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (entry.handle == zoomed_handle) {
                entry.view.setVisible(true);
                if (entry.view.hwnd) |h| {
                    const w = @max(rect.right - rect.left, 1);
                    const ht = @max(rect.bottom - rect.top, 1);
                    _ = w32.MoveWindow(h, rect.left, rect.top, @intCast(w), @intCast(ht), 1);
                    _ = w32.ShowWindow(h, w32.SW_SHOW);
                }
            } else {
                entry.view.setVisible(false);
                if (entry.view.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
            }
        }
        return;
    }
    self.layoutNode(tree, .root, rect);
    if (self.hwnd) |hwnd| {
        const hdc = w32.GetDC(hwnd);
        if (hdc) |dc| {
            self.paintDividers(dc);
            _ = w32.ReleaseDC(hwnd, dc);
        }
    }
}
fn layoutNode(self: *Window, tree: SplitTree(Surface), handle: SplitTree(Surface).Node.Handle, rect: w32.RECT) void {
    if (handle.idx() >= tree.nodes.len) return;
    switch (tree.nodes[handle.idx()]) {
        .leaf => |view| {
            view.setVisible(true);
            if (view.hwnd) |h| {
                const w = @max(rect.right - rect.left, 1);
                const ht = @max(rect.bottom - rect.top, 1);
                _ = w32.MoveWindow(h, rect.left, rect.top, @intCast(w), @intCast(ht), 1);
                _ = w32.ShowWindow(h, w32.SW_SHOW);
            }
        },
        .split => |s| {
            const gap: i32 = @intFromFloat(@round(5.0 * self.scale));
            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                self.layoutNode(tree, s.left, left_rect);
                self.layoutNode(tree, s.right, right_rect);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                self.layoutNode(tree, s.left, top_rect);
                self.layoutNode(tree, s.right, bottom_rect);
            }
        },
    }
}
fn paintDividers(self: *Window, hdc: w32.HDC) void {
    if (self.tab_count == 0) return;
    const tree = self.tab_trees[self.active_tab];
    if (!tree.isSplit()) return;
    if (tree.zoomed != null) return;
    const rect = self.surfaceRect();
    self.paintDividerNode(hdc, tree, .root, rect);
}
fn paintDividerNode(self: *Window, hdc: w32.HDC, tree: SplitTree(Surface), handle: SplitTree(Surface).Node.Handle, rect: w32.RECT) void {
    if (handle.idx() >= tree.nodes.len) return;
    switch (tree.nodes[handle.idx()]) {
        .leaf => {},
        .split => |s| {
            const gap: i32 = @intFromFloat(@round(5.0 * self.scale));
            const line_w: i32 = @max(@as(i32, @intFromFloat(@round(1.0 * self.scale))), 1);
            const pen = w32.CreatePen(0, line_w, 0x00808080) orelse return;
            defer _ = w32.DeleteObject(pen);
            const old_pen = w32.SelectObject(hdc, pen);
            defer _ = w32.SelectObject(hdc, old_pen);
            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                _ = w32.MoveToEx(hdc, split_x, rect.top, null);
                _ = w32.LineTo(hdc, split_x, rect.bottom);
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                self.paintDividerNode(hdc, tree, s.left, left_rect);
                self.paintDividerNode(hdc, tree, s.right, right_rect);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                _ = w32.MoveToEx(hdc, rect.left, split_y, null);
                _ = w32.LineTo(hdc, rect.right, split_y);
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                self.paintDividerNode(hdc, tree, s.left, top_rect);
                self.paintDividerNode(hdc, tree, s.right, bottom_rect);
            }
        },
    }
}
const DividerHit = struct {
    handle: SplitTree(Surface).Node.Handle,
    layout: SplitTree(Surface).Split.Layout,
};
fn hitTestDivider(self: *Window, x: i32, y: i32) ?DividerHit {
    if (self.tab_count == 0) return null;
    const tree = self.tab_trees[self.active_tab];
    if (!tree.isSplit()) return null;
    if (tree.zoomed != null) return null;
    const rect = self.surfaceRect();
    return self.hitTestDividerNode(tree, .root, rect, x, y);
}
fn hitTestDividerNode(
    self: *Window,
    tree: SplitTree(Surface),
    handle: SplitTree(Surface).Node.Handle,
    rect: w32.RECT,
    x: i32,
    y: i32,
) ?DividerHit {
    if (handle.idx() >= tree.nodes.len) return null;
    switch (tree.nodes[handle.idx()]) {
        .leaf => return null,
        .split => |s| {
            const gap: i32 = @as(i32, @intFromFloat(@round(5.0 * self.scale)));
            const hit_area: i32 = @max(@as(i32, @intFromFloat(@round(3.0 * self.scale))), 3);
            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                if (x >= split_x - hit_area and x <= split_x + hit_area and y >= rect.top and y <= rect.bottom) {
                    return .{ .handle = handle, .layout = .horizontal };
                }
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                return self.hitTestDividerNode(tree, s.left, left_rect, x, y) orelse
                    self.hitTestDividerNode(tree, s.right, right_rect, x, y);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                if (y >= split_y - hit_area and y <= split_y + hit_area and x >= rect.left and x <= rect.right) {
                    return .{ .handle = handle, .layout = .vertical };
                }
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                return self.hitTestDividerNode(tree, s.left, top_rect, x, y) orelse
                    self.hitTestDividerNode(tree, s.right, bottom_rect, x, y);
            }
        },
    }
}
fn startDividerDrag(self: *Window, handle: SplitTree(Surface).Node.Handle, layout: SplitTree(Surface).Split.Layout) void {
    self.dragging_split = true;
    self.drag_split_handle = handle;
    self.drag_split_layout = layout;
    self.drag_start_rect = self.surfaceRect();
    if (self.hwnd) |hwnd| _ = w32.SetCapture(hwnd);
}
fn updateDividerDrag(self: *Window, x: i32, y: i32) void {
    if (!self.dragging_split) return;
    const rect = self.drag_start_rect;
    const handle = self.drag_split_handle;
    const new_ratio: f16 = switch (self.drag_split_layout) {
        .horizontal => ratio: {
            const total: f32 = @floatFromInt(@max(rect.right - rect.left, 1));
            const pos: f32 = @floatFromInt(x - rect.left);
            break :ratio @floatCast(std.math.clamp(pos / total, 0.1, 0.9));
        },
        .vertical => ratio: {
            const total: f32 = @floatFromInt(@max(rect.bottom - rect.top, 1));
            const pos: f32 = @floatFromInt(y - rect.top);
            break :ratio @floatCast(std.math.clamp(pos / total, 0.1, 0.9));
        },
    };
    self.tab_trees[self.active_tab].resizeInPlace(handle, new_ratio);
    self.layoutSplits();
}
fn endDividerDrag(self: *Window) void {
    if (!self.dragging_split) return;
    self.dragging_split = false;
    _ = w32.ReleaseCapture();
}
pub fn newSplit(self: *Window, direction: SplitTree(Surface).Split.Direction) !void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;
    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;
    const new_surface = try alloc.create(Surface);
    errdefer {
        new_surface.deinit();
        if (!new_surface.leaked) alloc.destroy(new_surface);
    }
    try new_surface.init(self.app, self, .split);
    var insert_tree = try SplitTree(Surface).init(alloc, new_surface);
    defer insert_tree.deinit();
    const new_tree = try self.tab_trees[tab].split(
        alloc,
        handle,
        direction,
        @as(f16, 0.5),
        &insert_tree,
    );
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;
    self.tab_active_surface[tab] = new_surface;
    self.layoutSplits();
    if (new_surface.hwnd) |h| _ = w32.SetFocus(h);
}
pub fn gotoSplit(self: *Window, goto_target: apprt.action.GotoSplit) void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;
    const tree = &self.tab_trees[tab];
    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;
    const target: SplitTree(Surface).Goto = switch (goto_target) {
        .previous => .previous,
        .next => .next,
        .up => .{ .spatial = .up },
        .down => .{ .spatial = .down },
        .left => .{ .spatial = .left },
        .right => .{ .spatial = .right },
    };
    const dest_handle = (tree.goto(alloc, handle, target) catch return) orelse return;
    switch (tree.nodes[dest_handle.idx()]) {
        .leaf => |surface| {
            self.tab_active_surface[tab] = surface;
            if (surface.hwnd) |h| _ = w32.SetFocus(h);
        },
        .split => {},
    }
}
pub fn resizeSplit(self: *Window, rs: apprt.action.ResizeSplit) void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;
    const tree = &self.tab_trees[tab];
    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;
    const layout: SplitTree(Surface).Split.Layout = switch (rs.direction) {
        .left, .right => .horizontal,
        .up, .down => .vertical,
    };
    const rect = self.surfaceRect();
    const dimension: f32 = switch (layout) {
        .horizontal => @floatFromInt(@max(rect.right - rect.left, 1)),
        .vertical => @floatFromInt(@max(rect.bottom - rect.top, 1)),
    };
    const sign: f32 = switch (rs.direction) {
        .left, .up => -1.0,
        .right, .down => 1.0,
    };
    const delta: f16 = @floatCast(sign * @as(f32, @floatFromInt(rs.amount)) / dimension);
    const new_tree = tree.resize(alloc, handle, layout, delta) catch return;
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;
    self.layoutSplits();
}
pub fn equalizeSplits(self: *Window) void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;
    const new_tree = self.tab_trees[tab].equalize(alloc) catch return;
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;
    self.layoutSplits();
}
pub fn toggleSplitZoom(self: *Window) void {
    if (self.tab_count == 0) return;
    const tab = self.active_tab;
    var tree = &self.tab_trees[tab];
    if (!tree.isSplit()) return;
    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;
    if (tree.zoomed) |z| {
        if (z == handle) {
            tree.zoom(null);
        } else {
            tree.zoom(handle);
        }
    } else {
        tree.zoom(handle);
    }
    self.layoutSplits();
}
pub fn selectTab(self: *Window, target: apprt.action.GotoTab) bool {
    if (self.tab_count <= 1) return false;
    const idx: usize = switch (target) {
        .previous => if (self.active_tab > 0) self.active_tab - 1 else self.tab_count - 1,
        .next => if (self.active_tab + 1 < self.tab_count) self.active_tab + 1 else 0,
        .last => self.tab_count - 1,
        _ => blk: {
            const raw = @intFromEnum(target);
            if (raw < 0) return false;
            const n: usize = @intCast(raw);
            break :blk if (n < self.tab_count) n else return false;
        },
    };
    self.selectTabIndex(idx);
    self.invalidateTabBar();
    return true;
}
pub fn moveTab(self: *Window, amount: isize) void {
    if (self.tab_count <= 1) return;
    const n: isize = @intCast(self.active_tab);
    const count: isize = @intCast(self.tab_count);
    const new_index: usize = @intCast(@mod(n + amount, count));
    if (new_index == self.active_tab) return;
    std.mem.swap(SplitTree(Surface), &self.tab_trees[self.active_tab], &self.tab_trees[new_index]);
    std.mem.swap(*Surface, &self.tab_active_surface[self.active_tab], &self.tab_active_surface[new_index]);
    std.mem.swap([256]u16, &self.tab_titles[self.active_tab], &self.tab_titles[new_index]);
    std.mem.swap(u16, &self.tab_title_lens[self.active_tab], &self.tab_title_lens[new_index]);
    self.active_tab = new_index;
    self.invalidateTabBar();
}
pub fn moveTabToNewWindow(self: *Window, surface: *Surface) !bool {
    if (self.is_quick_terminal or self.tab_count <= 1) return false;
    const tab_idx = self.findTabIndex(surface) orelse return false;
    const alloc = self.app.core_app.alloc;
    const destination = try alloc.create(Window);
    destination.init(self.app, .{}) catch |err| {
        alloc.destroy(destination);
        return err;
    };
    errdefer {
        destination.deinit();
        alloc.destroy(destination);
    }
    try self.app.windows.append(alloc, destination);
    var tracked = true;
    errdefer if (tracked) {
        for (self.app.windows.items, 0..) |window, i| {
            if (window == destination) {
                _ = self.app.windows.orderedRemove(i);
                break;
            }
        }
    };
    const destination_hwnd = destination.hwnd orelse return error.Win32Error;
    var moved_tree = self.tab_trees[tab_idx];
    var it = moved_tree.iterator();
    while (it.next()) |entry| {
        const child = entry.view.hwnd orelse continue;
        if (w32.SetParent(child, destination_hwnd) == null) {
            if (self.hwnd) |source_hwnd| {
                var rollback = moved_tree.iterator();
                while (rollback.next()) |rollback_entry| {
                    if (rollback_entry.view.hwnd) |h| _ = w32.SetParent(h, source_hwnd);
                }
            }
            return error.Win32Error;
        }
    }
    const moved_active = self.tab_active_surface[tab_idx];
    const moved_title = self.tab_titles[tab_idx];
    const moved_title_len = self.tab_title_lens[tab_idx];
    var i = tab_idx;
    while (i + 1 < self.tab_count) : (i += 1) {
        self.tab_trees[i] = self.tab_trees[i + 1];
        self.tab_active_surface[i] = self.tab_active_surface[i + 1];
        self.tab_titles[i] = self.tab_titles[i + 1];
        self.tab_title_lens[i] = self.tab_title_lens[i + 1];
    }
    self.tab_count -= 1;
    if (self.active_tab > tab_idx) {
        self.active_tab -= 1;
    } else if (self.active_tab >= self.tab_count) {
        self.active_tab = self.tab_count - 1;
    }
    destination.tab_trees[0] = moved_tree;
    destination.tab_active_surface[0] = moved_active;
    destination.tab_titles[0] = moved_title;
    destination.tab_title_lens[0] = moved_title_len;
    destination.tab_count = 1;
    destination.active_tab = 0;
    it = destination.tab_trees[0].iterator();
    while (it.next()) |entry| entry.view.parent_window = destination;
    self.selectTabIndex(self.active_tab);
    self.updateTabBarVisibility();
    self.invalidateTabBar();
    destination.updateTabBarVisibility();
    destination.updateWindowTitle();
    _ = w32.ShowWindow(destination_hwnd, w32.SW_SHOW);
    _ = w32.UpdateWindow(destination_hwnd);
    destination.layoutSplits();
    if (moved_active.hwnd) |h| _ = w32.SetFocus(h);
    tracked = false;
    return true;
}
fn updateWindowTitle(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (self.tab_count == 0) return;
    const len = self.window_title_override_len orelse
        self.tab_title_lens[self.active_tab];
    var buf: [257]u16 = undefined;
    if (self.window_title_override_len != null) {
        @memcpy(buf[0..len], self.window_title_override[0..len]);
    } else {
        @memcpy(buf[0..len], self.tab_titles[self.active_tab][0..len]);
    }
    buf[len] = 0;
    _ = w32.SetWindowTextW(hwnd, @ptrCast(&buf));
}
pub fn setWindowTitle(self: *Window, title: [:0]const u8) void {
    if (title.len == 0) {
        self.window_title_override_len = null;
    } else {
        const len = std.unicode.utf8ToUtf16Le(&self.window_title_override, title) catch 0;
        self.window_title_override_len = @intCast(@min(len, self.window_title_override.len));
    }
    self.updateWindowTitle();
}
pub fn onTabTitleChanged(self: *Window, surface: *Surface, title: [:0]const u8) void {
    const tab_idx = self.findTabIndex(surface) orelse return;
    var wbuf: [256]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, title) catch 0;
    const len: u16 = @intCast(@min(wlen, 255));
    @memcpy(self.tab_titles[tab_idx][0..len], wbuf[0..len]);
    self.tab_title_lens[tab_idx] = len;
    if (tab_idx == self.active_tab) self.updateWindowTitle();
    self.invalidateTabBar();
}
fn updateTabBarVisibility(self: *Window) void {
    if (self.is_quick_terminal) {
        self.tab_bar_visible = false;
        return;
    }
    const show_config = self.app.config.@"window-show-tab-bar";
    const should_show = switch (show_config) {
        .always => true,
        .auto => self.tab_count > 1,
        .never => false,
    };
    if (should_show != self.tab_bar_visible) {
        self.tab_bar_visible = should_show;
        self.handleResize();
    }
}
pub fn invalidateTabBar(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    var rect = w32.RECT{
        .left = 0,
        .top = 0,
        .right = 10000,
        .bottom = self.tabBarHeight(),
    };
    _ = w32.InvalidateRect(hwnd, &rect, 0);
}
fn layoutTabRects(
    rects: []w32.RECT,
    available_w: i32,
    bar_h: i32,
    min_tab_w: i32,
    max_tab_w: i32,
) i32 {
    const tab_count: i32 = @intCast(rects.len);
    if (tab_count == 0) return 0;
    var tab_w = @divTrunc(available_w, tab_count);
    tab_w = @max(tab_w, min_tab_w);
    tab_w = @min(tab_w, max_tab_w);
    var x: i32 = 0;
    for (rects) |*rect| {
        rect.* = .{
            .left = x,
            .top = 0,
            .right = x + tab_w,
            .bottom = bar_h,
        };
        x += tab_w;
    }
    return x;
}
test "tab bar keeps tab widths equal" {
    var rects: [2]w32.RECT = undefined;
    const tabs_right = layoutTabRects(&rects, 964, 30, 60, 200);
    try std.testing.expectEqual(@as(i32, 400), tabs_right);
    try std.testing.expectEqual(@as(i32, 200), rects[0].right - rects[0].left);
    try std.testing.expectEqual(@as(i32, 200), rects[1].right - rects[1].left);
    try std.testing.expectEqual(rects[0].right, rects[1].left);
}
fn paintTabBar(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    var ps: w32.PAINTSTRUCT = undefined;
    const hdc_screen = w32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = w32.EndPaint(hwnd, &ps);
    if (!self.tab_bar_visible) return;
    const bar_h = self.tabBarHeight();
    if (bar_h <= 0) return;
    var client_rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &client_rect) == 0) return;
    const client_w = client_rect.right - client_rect.left;
    if (client_w <= 0) return;
    const mem_dc = w32.CreateCompatibleDC(hdc_screen) orelse return;
    defer _ = w32.DeleteDC(mem_dc);
    const mem_bmp = w32.CreateCompatibleBitmap(hdc_screen, client_w, bar_h) orelse return;
    const old_bmp = w32.SelectObject(mem_dc, mem_bmp);
    defer {
        _ = w32.SelectObject(mem_dc, old_bmp);
        _ = w32.DeleteObject(mem_bmp);
    }
    const bg = self.app.config.background;
    const bar_r: u8 = @min(@as(u16, bg.r) + 20, 255);
    const bar_g: u8 = @min(@as(u16, bg.g) + 20, 255);
    const bar_b: u8 = @min(@as(u16, bg.b) + 20, 255);
    const bar_color = w32.RGB(bar_r, bar_g, bar_b);
    const hover_r: u8 = @min(@as(u16, bar_r) + 15, 255);
    const hover_g: u8 = @min(@as(u16, bar_g) + 15, 255);
    const hover_b: u8 = @min(@as(u16, bar_b) + 15, 255);
    const hover_color = w32.RGB(hover_r, hover_g, hover_b);
    const active_bg_color = w32.RGB(bg.r, bg.g, bg.b);
    const accent_color = w32.RGB(0x3D, 0x8E, 0xF8);
    const active_text_color = w32.RGB(230, 230, 230);
    const inactive_text_color = w32.RGB(150, 150, 150);
    const close_normal_color = w32.RGB(150, 150, 150);
    const close_hover_color = w32.RGB(232, 65, 65);
    var bar_rect = w32.RECT{ .left = 0, .top = 0, .right = client_w, .bottom = bar_h };
    const bar_brush = w32.CreateSolidBrush(bar_color) orelse return;
    _ = w32.FillRect(mem_dc, &bar_rect, bar_brush);
    _ = w32.DeleteObject(@ptrCast(bar_brush));
    var old_font: ?*anyopaque = null;
    if (self.tab_font) |font| {
        old_font = w32.SelectObject(mem_dc, font);
    }
    defer {
        if (old_font) |f| _ = w32.SelectObject(mem_dc, f);
    }
    _ = w32.SetBkMode(mem_dc, w32.TRANSPARENT);
    const new_tab_btn_w: i32 = @intFromFloat(@round(36.0 * self.scale));
    const close_btn_w: i32 = @intFromFloat(@round(20.0 * self.scale));
    const text_pad: i32 = @intFromFloat(@round(10.0 * self.scale));
    const accent_h: i32 = @intFromFloat(@round(2.0 * self.scale));
    const available_w = client_w - new_tab_btn_w;
    const min_tab_w: i32 = @intFromFloat(@round(60.0 * self.scale));
    const max_tab_w: i32 = @intFromFloat(@round(200.0 * self.scale));
    const tabs_right = layoutTabRects(
        self.tab_rects[0..self.tab_count],
        available_w,
        bar_h,
        min_tab_w,
        max_tab_w,
    );
    for (0..self.tab_count) |i| {
        const is_active = (i == self.active_tab);
        const is_hovered = (@as(isize, @intCast(i)) == self.hover_tab);
        const x = self.tab_rects[i].left;
        const this_tab_w = self.tab_rects[i].right - x;
        if (is_active) {
            var tab_rect = w32.RECT{ .left = x, .top = 0, .right = x + this_tab_w, .bottom = bar_h };
            if (w32.CreateSolidBrush(active_bg_color)) |brush| {
                _ = w32.FillRect(mem_dc, &tab_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
            var accent_rect = w32.RECT{
                .left = x,
                .top = bar_h - accent_h,
                .right = x + this_tab_w,
                .bottom = bar_h,
            };
            if (w32.CreateSolidBrush(accent_color)) |brush| {
                _ = w32.FillRect(mem_dc, &accent_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        } else if (is_hovered) {
            var hover_rect = w32.RECT{ .left = x, .top = 0, .right = x + this_tab_w, .bottom = bar_h };
            if (w32.CreateSolidBrush(hover_color)) |brush| {
                _ = w32.FillRect(mem_dc, &hover_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        }
        const title_len = self.tab_title_lens[i];
        if (title_len > 0) {
            _ = w32.SetTextColor(mem_dc, if (is_active) active_text_color else inactive_text_color);
            var text_rect = w32.RECT{
                .left = x + text_pad,
                .top = 0,
                .right = x + this_tab_w - close_btn_w - text_pad,
                .bottom = bar_h,
            };
            _ = w32.DrawTextW(
                mem_dc,
                @ptrCast(&self.tab_titles[i]),
                @intCast(title_len),
                &text_rect,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
            );
        }
        if (is_active or is_hovered) {
            const close_x = x + this_tab_w - close_btn_w - @divTrunc(text_pad, 2);
            const close_y_center = @divTrunc(bar_h, 2);
            const close_text_color = if (is_hovered and self.hover_close and @as(isize, @intCast(i)) == self.hover_tab)
                close_hover_color
            else
                close_normal_color;
            _ = w32.SetTextColor(mem_dc, close_text_color);
            const x_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{00D7}");
            var close_rect = w32.RECT{
                .left = close_x,
                .top = close_y_center - @divTrunc(close_btn_w, 2),
                .right = close_x + close_btn_w,
                .bottom = close_y_center + @divTrunc(close_btn_w, 2),
            };
            _ = w32.DrawTextW(
                mem_dc,
                x_char,
                1,
                &close_rect,
                w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );
        }
    }
    {
        const btn_left = tabs_right;
        const btn_right = btn_left + new_tab_btn_w;
        self.new_tab_rect = w32.RECT{
            .left = btn_left,
            .top = 0,
            .right = btn_right,
            .bottom = bar_h,
        };
        if (self.hover_new_tab) {
            var btn_rect = w32.RECT{ .left = btn_left, .top = 0, .right = btn_right, .bottom = bar_h };
            const nt_brush = w32.CreateSolidBrush(hover_color);
            if (nt_brush) |brush| {
                _ = w32.FillRect(mem_dc, &btn_rect, brush);
                _ = w32.DeleteObject(@ptrCast(brush));
            }
        }
        _ = w32.SetTextColor(mem_dc, inactive_text_color);
        const plus_char = std.unicode.utf8ToUtf16LeStringLiteral("+");
        var plus_rect = w32.RECT{
            .left = btn_left,
            .top = 0,
            .right = btn_right,
            .bottom = bar_h,
        };
        _ = w32.DrawTextW(
            mem_dc,
            plus_char,
            1,
            &plus_rect,
            w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );
    }
    _ = w32.BitBlt(hdc_screen, 0, 0, client_w, bar_h, mem_dc, 0, 0, w32.SRCCOPY);
}
pub fn toggleFullscreen(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (!self.is_fullscreen) {
        self.saved_style = w32.GetWindowLongW(hwnd, w32.GWL_STYLE);
        _ = w32.GetWindowRect(hwnd, &self.saved_rect);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, w32.WS_POPUP | w32.WS_VISIBLE_STYLE);
        const monitor = w32.MonitorFromWindow(hwnd, w32.MONITOR_DEFAULTTONEAREST);
        var mi: w32.MONITORINFO = undefined;
        mi.cbSize = @sizeOf(w32.MONITORINFO);
        if (w32.GetMonitorInfoW(monitor, &mi) != 0) {
            _ = w32.SetWindowPos(hwnd, null, mi.rcMonitor.left, mi.rcMonitor.top, mi.rcMonitor.right - mi.rcMonitor.left, mi.rcMonitor.bottom - mi.rcMonitor.top, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED);
        }
    } else {
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, self.saved_style);
        _ = w32.SetWindowPos(hwnd, null, self.saved_rect.left, self.saved_rect.top, self.saved_rect.right - self.saved_rect.left, self.saved_rect.bottom - self.saved_rect.top, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED);
    }
    self.is_fullscreen = !self.is_fullscreen;
}
pub fn toggleWindowDecorations(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const style = w32.GetWindowLongW(hwnd, w32.GWL_STYLE);
    const has_decorations = (style & w32.WS_CAPTION) != 0;
    if (has_decorations) {
        const new_style = style & ~@as(u32, w32.WS_CAPTION | w32.WS_THICKFRAME);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, new_style);
    } else {
        const new_style = style | w32.WS_CAPTION | w32.WS_THICKFRAME;
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, new_style);
    }
    _ = w32.SetWindowPos(hwnd, null, 0, 0, 0, 0, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED | w32.SWP_NOMOVE | w32.SWP_NOSIZE);
}
const RESIZE_OVERLAY_TIMER_ID: usize = 0x5247;
fn handleResize(self: *Window) void {
    self.layoutSplits();
    self.invalidateTabBar();
    self.showResizeOverlay();
}
fn showResizeOverlay(self: *Window) void {
    switch (self.app.config.@"resize-overlay") {
        .never => return,
        .@"after-first" => if (!self.resize_seen_first) {
            self.resize_seen_first = true;
            return;
        },
        .always => {},
    }
    self.resize_seen_first = true;
    const hwnd = self.hwnd orelse return;
    const surface = self.getActiveSurface() orelse return;
    if (!surface.core_surface_ready) return;
    const grid = surface.core_surface.size.grid();
    var buf8: [32]u8 = undefined;
    const text8 = std.fmt.bufPrint(&buf8, "{d} \u{00D7} {d}", .{
        grid.columns,
        grid.rows,
    }) catch return;
    var buf16: [32]u16 = undefined;
    const len16 = std.unicode.utf8ToUtf16Le(&buf16, text8) catch return;
    buf16[len16] = 0;
    if (self.resize_overlay_hwnd == null) {
        self.resize_overlay_hwnd = w32.CreateWindowExW(
            w32.WS_EX_TOOLWINDOW | w32.WS_EX_NOACTIVATE,
            std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            w32.WS_POPUP | w32.WS_BORDER | w32.SS_CENTER | w32.SS_CENTERIMAGE,
            0,
            0,
            10,
            10,
            hwnd,
            null,
            self.app.hinstance,
            null,
        );
        if (self.resize_overlay_hwnd) |h| {
            if (self.tab_font) |f| {
                _ = w32.SendMessageW(h, w32.WM_SETFONT, @intFromPtr(f), 1);
            }
        }
    }
    const overlay = self.resize_overlay_hwnd orelse return;
    _ = w32.SetWindowTextW(overlay, @ptrCast(&buf16));
    const s = self.scale;
    const ow: i32 = @intFromFloat(@round(110.0 * s));
    const oh: i32 = @intFromFloat(@round(34.0 * s));
    const margin: i32 = @intFromFloat(@round(16.0 * s));
    var client: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = w32.GetClientRect(hwnd, &client);
    const cw = client.right - client.left;
    const ch = client.bottom - client.top;
    const cx = @divTrunc(cw - ow, 2);
    const cy = @divTrunc(ch - oh, 2);
    var pt: w32.POINT = switch (self.app.config.@"resize-overlay-position") {
        .center => .{ .x = cx, .y = cy },
        .@"top-left" => .{ .x = margin, .y = margin },
        .@"top-center" => .{ .x = cx, .y = margin },
        .@"top-right" => .{ .x = cw - ow - margin, .y = margin },
        .@"bottom-left" => .{ .x = margin, .y = ch - oh - margin },
        .@"bottom-center" => .{ .x = cx, .y = ch - oh - margin },
        .@"bottom-right" => .{ .x = cw - ow - margin, .y = ch - oh - margin },
    };
    _ = w32.ClientToScreen(hwnd, &pt);
    _ = w32.SetWindowPos(overlay, null, pt.x, pt.y, ow, oh, w32.SWP_NOACTIVATE | w32.SWP_NOZORDER);
    _ = w32.ShowWindow(overlay, w32.SW_SHOWNOACTIVATE);
    const dur_ms: u32 = @max(1, self.app.config.@"resize-overlay-duration".asMilliseconds());
    _ = w32.SetTimer(hwnd, RESIZE_OVERLAY_TIMER_ID, dur_ms, null);
}
fn handleTabBarClick(self: *Window, x: i16, y: i16) void {
    if (!self.tab_bar_visible) return;
    if (y >= self.tabBarHeight()) return;
    if (x >= self.new_tab_rect.left and x < self.new_tab_rect.right) {
        _ = self.addTab() catch |err| {
            log.err("failed to create new tab: {}", .{err});
            return;
        };
        return;
    }
    const close_btn_w: i32 = @intFromFloat(@round(20.0 * self.scale));
    const text_pad: i32 = @intFromFloat(@round(10.0 * self.scale));
    for (0..self.tab_count) |i| {
        const rect = self.tab_rects[i];
        if (x >= rect.left and x < rect.right) {
            const close_left = rect.right - close_btn_w - @divTrunc(text_pad, 2);
            if (x >= close_left) {
                self.closeTabByIndex(i);
            } else {
                self.selectTabIndex(i);
                self.drag_tab = @intCast(i);
                self.drag_start_x = x;
                self.drag_active = false;
                if (self.hwnd) |h| _ = w32.SetCapture(h);
                self.invalidateTabBar();
            }
            return;
        }
    }
}
fn moveTabTo(self: *Window, from: usize, to: usize) void {
    if (from == to) return;
    if (from >= self.tab_count or to >= self.tab_count) return;
    self.cancelTabRename();
    const saved_tree = self.tab_trees[from];
    const saved_surface = self.tab_active_surface[from];
    const saved_title = self.tab_titles[from];
    const saved_title_len = self.tab_title_lens[from];
    if (from < to) {
        var i: usize = from;
        while (i < to) : (i += 1) {
            self.tab_trees[i] = self.tab_trees[i + 1];
            self.tab_active_surface[i] = self.tab_active_surface[i + 1];
            self.tab_titles[i] = self.tab_titles[i + 1];
            self.tab_title_lens[i] = self.tab_title_lens[i + 1];
        }
    } else {
        var i: usize = from;
        while (i > to) : (i -= 1) {
            self.tab_trees[i] = self.tab_trees[i - 1];
            self.tab_active_surface[i] = self.tab_active_surface[i - 1];
            self.tab_titles[i] = self.tab_titles[i - 1];
            self.tab_title_lens[i] = self.tab_title_lens[i - 1];
        }
    }
    self.tab_trees[to] = saved_tree;
    self.tab_active_surface[to] = saved_surface;
    self.tab_titles[to] = saved_title;
    self.tab_title_lens[to] = saved_title_len;
    self.active_tab = to;
    self.invalidateTabBar();
}
fn handleTabBarMouseMove(self: *Window, x: i16, y: i16) void {
    if (!self.tab_bar_visible) return;
    if (!self.tracking_mouse) {
        var tme = w32.TRACKMOUSEEVENT{
            .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
            .dwFlags = w32.TME_LEAVE,
            .hwndTrack = self.hwnd.?,
            .dwHoverTime = 0,
        };
        _ = w32.TrackMouseEvent(&tme);
        self.tracking_mouse = true;
    }
    var new_hover: isize = -1;
    var new_close = false;
    var new_new_tab = false;
    if (y < self.tabBarHeight()) {
        if (x >= self.new_tab_rect.left and x < self.new_tab_rect.right) {
            new_new_tab = true;
        } else {
            const close_btn_w: i32 = @intFromFloat(@round(20.0 * self.scale));
            const text_pad: i32 = @intFromFloat(@round(10.0 * self.scale));
            for (0..self.tab_count) |i| {
                const rect = self.tab_rects[i];
                if (x >= rect.left and x < rect.right) {
                    new_hover = @intCast(i);
                    const close_left = rect.right - close_btn_w - @divTrunc(text_pad, 2);
                    new_close = x >= close_left;
                    break;
                }
            }
        }
    }
    if (new_hover != self.hover_tab or new_close != self.hover_close or new_new_tab != self.hover_new_tab) {
        self.hover_tab = new_hover;
        self.hover_close = new_close;
        self.hover_new_tab = new_new_tab;
        self.invalidateTabBar();
    }
}
const TAB_CTX_CLOSE: usize = 9001;
const TAB_CTX_CLOSE_OTHERS: usize = 9002;
const TAB_CTX_CLOSE_RIGHT: usize = 9003;
const TAB_CTX_NEW_TAB: usize = 9004;
fn handleTabBarRightClick(self: *Window, x: i16, y: i16) void {
    if (!self.tab_bar_visible) return;
    if (y >= self.tabBarHeight()) return;
    var clicked_tab: ?usize = null;
    for (0..self.tab_count) |i| {
        const rect = self.tab_rects[i];
        if (x >= rect.left and x < rect.right) {
            clicked_tab = i;
            break;
        }
    }
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);
    if (clicked_tab) |tab| {
        _ = w32.AppendMenuW(menu, w32.MF_STRING, TAB_CTX_CLOSE, std.unicode.utf8ToUtf16LeStringLiteral("Close Tab"));
        _ = w32.AppendMenuW(menu, if (self.tab_count > 1) w32.MF_STRING else w32.MF_GRAYED, TAB_CTX_CLOSE_OTHERS, std.unicode.utf8ToUtf16LeStringLiteral("Close Other Tabs"));
        _ = w32.AppendMenuW(menu, if (tab + 1 < self.tab_count) w32.MF_STRING else w32.MF_GRAYED, TAB_CTX_CLOSE_RIGHT, std.unicode.utf8ToUtf16LeStringLiteral("Close Tabs to the Right"));
        _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    }
    _ = w32.AppendMenuW(menu, w32.MF_STRING, TAB_CTX_NEW_TAB, std.unicode.utf8ToUtf16LeStringLiteral("New Tab"));
    var pt = w32.POINT{ .x = @intCast(x), .y = @intCast(y) };
    if (self.hwnd) |h| _ = w32.ClientToScreen(h, &pt);
    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        self.hwnd.?,
        null,
    );
    switch (@as(usize, @intCast(cmd))) {
        TAB_CTX_CLOSE => {
            if (clicked_tab) |tab| self.closeTabByIndex(tab);
        },
        TAB_CTX_CLOSE_OTHERS => {
            if (clicked_tab) |tab| {
                var current = tab;
                var i: usize = self.tab_count;
                while (i > 0) {
                    i -= 1;
                    if (i != current) {
                        self.closeTabByIndex(i);
                        if (i < current) current -= 1;
                    }
                }
            }
        },
        TAB_CTX_CLOSE_RIGHT => {
            if (clicked_tab) |tab| {
                var i: usize = self.tab_count;
                while (i > tab + 1) {
                    i -= 1;
                    self.closeTabByIndex(i);
                }
            }
        },
        TAB_CTX_NEW_TAB => {
            _ = self.addTab() catch |err| {
                log.err("failed to create new tab: {}", .{err});
            };
        },
        else => {},
    }
}
fn handleTabBarMouseLeave(self: *Window) void {
    self.tracking_mouse = false;
    if (self.hover_tab != -1 or self.hover_new_tab) {
        self.hover_tab = -1;
        self.hover_close = false;
        self.hover_new_tab = false;
        self.invalidateTabBar();
    }
}
const RENAME_EDIT_ID: u16 = 300;
pub fn startTabRename(self: *Window, tab_idx: usize) void {
    self.cancelTabRename();
    self.rename_window = false;
    const hwnd = self.hwnd orelse return;
    const rect = rect: {
        if (self.tab_bar_visible) break :rect self.tab_rects[tab_idx];
        var client: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &client) == 0) return;
        break :rect w32.RECT{
            .left = 8,
            .top = 8,
            .right = @max(168, client.right - 8),
            .bottom = 38,
        };
    };
    var title_buf: [257]u16 = undefined;
    const tlen = self.tab_title_lens[tab_idx];
    @memcpy(title_buf[0..tlen], self.tab_titles[tab_idx][0..tlen]);
    title_buf[tlen] = 0;
    const edit = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        @ptrCast(&title_buf),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL | w32.WS_BORDER,
        rect.left + 2,
        rect.top + 2,
        rect.right - rect.left - 4,
        rect.bottom - rect.top - 4,
        hwnd,
        @ptrFromInt(@as(usize, RENAME_EDIT_ID)),
        self.app.hinstance,
        null,
    ) orelse return;
    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        edit,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );
    _ = w32.SetWindowTheme(
        edit,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );
    self.rename_font = w32.CreateFontW(
        -@as(i32, @intFromFloat(@round(12.0 * self.scale))),
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
    if (self.rename_font) |f| {
        _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
    }
    _ = w32.SendMessageW(edit, 0x00B1, 0, -1);
    _ = w32.SetFocus(edit);
    self.rename_edit = edit;
    self.rename_tab = tab_idx;
}
pub fn startWindowRename(self: *Window) void {
    self.startTabRename(self.active_tab);
    const edit = self.rename_edit orelse return;
    self.rename_window = true;
    var title: [257]u16 = undefined;
    const len: usize = if (self.window_title_override_len) |override_len| len: {
        @memcpy(title[0..override_len], self.window_title_override[0..override_len]);
        break :len override_len;
    } else @intCast(w32.GetWindowTextW(self.hwnd.?, &title, 256));
    title[len] = 0;
    _ = w32.SetWindowTextW(edit, @ptrCast(&title));
    _ = w32.SendMessageW(edit, 0x00B1, 0, -1);
}
pub fn finishTabRename(self: *Window) void {
    const edit = self.rename_edit orelse return;
    const tab_idx = self.rename_tab;
    var wbuf: [256]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(edit, &wbuf, 256));
    if (self.rename_window) {
        if (wlen == 0) {
            self.window_title_override_len = null;
        } else {
            const len: u16 = @intCast(@min(wlen, 255));
            @memcpy(self.window_title_override[0..len], wbuf[0..len]);
            self.window_title_override_len = len;
        }
        self.updateWindowTitle();
    } else if (wlen > 0) {
        const len: u16 = @intCast(@min(wlen, 255));
        @memcpy(self.tab_titles[tab_idx][0..len], wbuf[0..len]);
        self.tab_title_lens[tab_idx] = len;
        if (tab_idx == self.active_tab) self.updateWindowTitle();
    }
    self.rename_edit = null;
    self.rename_window = false;
    _ = w32.DestroyWindow(edit);
    if (self.rename_font) |f| {
        _ = w32.DeleteObject(f);
        self.rename_font = null;
    }
    self.invalidateTabBar();
    if (self.getActiveSurface()) |s| {
        if (s.hwnd) |h| _ = w32.SetFocus(h);
    }
}
pub fn cancelTabRename(self: *Window) void {
    if (self.rename_edit) |edit| {
        self.rename_edit = null;
        self.rename_window = false;
        _ = w32.DestroyWindow(edit);
        if (self.rename_font) |f| {
            _ = w32.DeleteObject(f);
            self.rename_font = null;
        }
        if (self.getActiveSurface()) |s| {
            if (s.hwnd) |h| _ = w32.SetFocus(h);
        }
    }
}
pub fn confirmCloseIfNeeded(self: *Window) bool {
    var needs = false;
    outer: for (0..self.tab_count) |i| {
        var it = self.tab_trees[i].iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            if (surface.core_surface_ready and
                surface.core_surface.needsConfirmQuit())
            {
                needs = true;
                break :outer;
            }
        }
    }
    if (!needs) return true;
    const result = w32.MessageBoxW(
        self.hwnd,
        std.unicode.utf8ToUtf16LeStringLiteral(
            "Processes are still running in this window.\nClose anyway?",
        ),
        std.unicode.utf8ToUtf16LeStringLiteral("Wasp"),
        w32.MB_OKCANCEL | w32.MB_ICONWARNING | w32.MB_DEFBUTTON2,
    );
    return result == w32.IDOK;
}
pub fn close(self: *Window) void {
    self.cleanupAllSurfaces();
    if (self.hwnd) |hwnd| {
        _ = w32.DestroyWindow(hwnd);
    }
}
fn cleanupAllSurfaces(self: *Window) void {
    for (self.tab_trees[0..self.tab_count]) |*tree| {
        tree.deinit();
        tree.* = .empty;
    }
    self.tab_count = 0;
}
fn onDestroy(self: *Window) void {
    const app = self.app;
    if (self.is_quick_terminal) {
        if (self.tab_font) |font| {
            _ = w32.DeleteObject(font);
            self.tab_font = null;
        }
        self.hwnd = null;
        if (app.quick_terminal) |qt| {
            qt.onWindowDestroyed();
        }
        return;
    }
    for (app.windows.items, 0..) |w, i| {
        if (w == self) {
            _ = app.windows.orderedRemove(i);
            break;
        }
    }
    if (self.tab_font) |font| {
        _ = w32.DeleteObject(font);
        self.tab_font = null;
    }
    self.hwnd = null;
    app.core_app.alloc.destroy(self);
    if (app.windows.items.len == 0 and app.quick_terminal == null) {
        app.startQuitTimer();
    }
}
pub fn windowWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const window: *Window = if (userdata != 0)
        @ptrFromInt(@as(usize, @bitCast(userdata)))
    else
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    if (window.closing) switch (msg) {
        w32.WM_LBUTTONDOWN,
        w32.WM_LBUTTONUP,
        w32.WM_LBUTTONDBLCLK,
        w32.WM_RBUTTONUP,
        w32.WM_MBUTTONDOWN,
        w32.WM_MOUSEMOVE,
        w32.WM_MOUSELEAVE,
        w32.WM_MOUSEWHEEL,
        w32.WM_MOUSEHWHEEL,
        w32.WM_KEYDOWN,
        w32.WM_KEYUP,
        w32.WM_SYSKEYDOWN,
        w32.WM_SYSKEYUP,
        w32.WM_CHAR,
        w32.WM_SETFOCUS,
        w32.WM_SETCURSOR,
        => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
        else => {},
    };
    switch (msg) {
        w32.WM_GETOBJECT => {
            if (lparam == w32.OBJID_CLIENT) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_TIMER => {
            if (wparam == RESIZE_OVERLAY_TIMER_ID) {
                if (window.resize_overlay_hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
                _ = w32.KillTimer(hwnd, RESIZE_OVERLAY_TIMER_ID);
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CTLCOLORSTATIC => {
            const hdc_static: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc_static, w32.RGB(220, 220, 220));
            _ = w32.SetBkColor(hdc_static, w32.RGB(45, 45, 45));
            if (window.app.bg_brush) |brush| {
                return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(brush))));
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_SIZE => {
            if (wparam == w32.SIZE_MINIMIZED) {
                window.setActiveTabVisible(false);
                return 0;
            }
            if (wparam == w32.SIZE_RESTORED or wparam == w32.SIZE_MAXIMIZED) {
                window.setActiveTabVisible(true);
            }
            window.handleResize();
            return 0;
        },
        w32.WM_POWERBROADCAST => {
            if (wparam == w32.PBT_APMRESUMEAUTOMATIC or
                wparam == w32.PBT_APMRESUMESUSPEND)
            {
                if (window.active_tab < window.tab_count) {
                    var it = window.tab_trees[window.active_tab].iterator();
                    while (it.next()) |entry| {
                        if (entry.view.hwnd) |h| _ = w32.InvalidateRect(h, null, 0);
                    }
                }
                return 1;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOVE => {
            for (0..window.tab_count) |i| {
                var it = window.tab_trees[i].iterator();
                while (it.next()) |entry| {
                    if (entry.view.scrollbar) |sb| _ = sb.repositionAndResize();
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_GETMINMAXINFO => {
            if (window.min_track_w > 0 or window.min_track_h > 0 or
                window.max_track_w > 0 or window.max_track_h > 0)
            {
                const mmi: *w32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
                if (window.min_track_w > 0) mmi.ptMinTrackSize.x = window.min_track_w;
                if (window.min_track_h > 0) mmi.ptMinTrackSize.y = window.min_track_h;
                if (window.max_track_w > 0) mmi.ptMaxTrackSize.x = window.max_track_w;
                if (window.max_track_h > 0) mmi.ptMaxTrackSize.y = window.max_track_h;
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_ENTERSIZEMOVE => {
            if (window.tab_count > 0) {
                var it = window.tab_trees[window.active_tab].iterator();
                while (it.next()) |entry| entry.view.in_live_resize = true;
            }
            return 0;
        },
        w32.WM_EXITSIZEMOVE => {
            if (window.tab_count > 0) {
                var it = window.tab_trees[window.active_tab].iterator();
                while (it.next()) |entry| entry.view.in_live_resize = false;
            }
            return 0;
        },
        w32.WM_CLOSE => {
            if (!window.confirmCloseIfNeeded()) return 0;
            window.close();
            return 0;
        },
        w32.WM_DESTROY => {
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            window.onDestroy();
            return 0;
        },
        w32.WM_PAINT => {
            window.paintTabBar();
            return 0;
        },
        w32.WM_COMMAND => {
            const notification: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const control_id: u16 = @intCast(wparam & 0xFFFF);
            if (control_id == RENAME_EDIT_ID and notification == w32.EN_KILLFOCUS) {
                window.finishTabRename();
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_SETFOCUS => {
            if (window.getActiveSurface()) |s| {
                if (s.hwnd) |h| _ = w32.SetFocus(h);
            }
            return 0;
        },
        w32.WM_ERASEBKGND => return 1,
        w32.WM_LBUTTONDOWN => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            if (window.hitTestDivider(x, y)) |hit| {
                window.startDividerDrag(hit.handle, hit.layout);
                return 0;
            }
            if (y < window.tabBarHeight()) {
                window.handleTabBarClick(@truncate(x), @truncate(y));
            }
            return 0;
        },
        w32.WM_LBUTTONUP => {
            if (window.dragging_split) {
                window.endDividerDrag();
                return 0;
            }
            if (window.drag_tab >= 0) {
                window.drag_tab = -1;
                window.drag_active = false;
                _ = w32.ReleaseCapture();
                return 0;
            }
            return 0;
        },
        w32.WM_LBUTTONDBLCLK => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            if (y < window.tabBarHeight()) {
                for (0..window.tab_count) |i| {
                    const rect = window.tab_rects[i];
                    if (x >= rect.left and x < rect.right) {
                        window.startTabRename(i);
                        return 0;
                    }
                }
                return 0;
            }
            if (window.hitTestDivider(x, y)) |hit| {
                window.tab_trees[window.active_tab].resizeInPlace(hit.handle, @as(f16, 0.5));
                window.layoutSplits();
                return 0;
            }
            return 0;
        },
        w32.WM_RBUTTONUP => {
            const x: i16 = @truncate(lparam & 0xFFFF);
            const y: i16 = @truncate((lparam >> 16) & 0xFFFF);
            if (y < window.tabBarHeight()) {
                window.handleTabBarRightClick(x, y);
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOUSEMOVE => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            if (window.dragging_split) {
                window.updateDividerDrag(x, y);
                return 0;
            }
            if (window.drag_tab >= 0) {
                const xi16: i16 = @truncate(x);
                const dx = if (xi16 > window.drag_start_x) xi16 - window.drag_start_x else window.drag_start_x - xi16;
                if (!window.drag_active and dx > 5) {
                    window.drag_active = true;
                }
                if (window.drag_active and window.tab_count > 1) {
                    const from: usize = @intCast(window.drag_tab);
                    const first_w = window.tab_rects[0].right - window.tab_rects[0].left;
                    var target: usize = 0;
                    for (0..window.tab_count) |i| {
                        const slot_left: i32 = @intCast(@as(i32, @intCast(i)) * first_w);
                        const slot_mid = slot_left + @divTrunc(first_w, 2);
                        if (x >= slot_mid) {
                            target = i;
                        }
                    }
                    if (target >= window.tab_count) target = window.tab_count - 1;
                    if (target != from) {
                        window.moveTabTo(from, target);
                        window.drag_tab = @intCast(target);
                        if (window.hwnd) |h| _ = w32.UpdateWindow(h);
                    }
                }
                return 0;
            }
            if (y < window.tabBarHeight()) {
                window.handleTabBarMouseMove(@truncate(x), @truncate(y));
            }
            return 0;
        },
        w32.WM_SETCURSOR => {
            var pt: w32.POINT = undefined;
            if (w32.GetCursorPos_(&pt) != 0) {
                if (window.hwnd) |h| _ = w32.ScreenToClient(h, &pt);
                if (window.hitTestDivider(pt.x, pt.y)) |hit| {
                    const cursor_id: usize = if (hit.layout == .horizontal) w32.IDC_SIZEWE else w32.IDC_SIZENS;
                    if (w32.LoadCursorW(null, cursor_id)) |cursor| {
                        _ = w32.SetCursor(cursor);
                    }
                    return 1;
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOUSELEAVE => {
            window.handleTabBarMouseLeave();
            return 0;
        },
        w32.WM_ACTIVATE => {
            const activated = @as(u16, @truncate(wparam & 0xFFFF));
            if (activated == w32.WA_INACTIVE and window.is_quick_terminal) {
                if (window.app.quick_terminal) |qt| {
                    qt.onFocusLost();
                }
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
