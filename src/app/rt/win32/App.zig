const App = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../../root.zig");
const configpkg = @import("../../../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../../App.zig");
const CoreSurface = @import("../../../Surface.zig");
const internal_os = @import("../../../os/root.zig");
const global = @import("../../../global.zig");
const QuickTerminal = @import("QuickTerminal.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const SplitTree = @import("../../../datastruct/split_tree.zig").SplitTree;
const w32 = @import("win32.zig");
const build_config = @import("../../../build_config.zig");
const input = @import("../../../input.zig");
const GlobalHotkey = struct { id: i32, action: input.Binding.Action };
const log = std.log.scoped(.win32);
pub const must_draw_from_app_thread = false;
const WM_APP_WAKEUP: u32 = w32.WM_APP + 1;
const QUIT_TIMER_ID: usize = 1;
pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("WaspWindow");
pub const TERMINAL_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("WaspTerminal");
pub const MSG_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("WaspMsg");
core_app: *CoreApp,
config: Config,
msg_hwnd: ?w32.HWND = null,
hinstance: w32.HINSTANCE,
class_atom: u16 = 0,
terminal_class_atom: u16 = 0,
msg_class_atom: u16 = 0,
windows: std.ArrayList(*Window) = .empty,
bg_brush: ?w32.HBRUSH = null,
quit_timer_state: enum { off, active, expired } = .off,
quit_requested: bool = false,
quick_terminal: ?*QuickTerminal = null,
global_hotkeys: std.ArrayList(GlobalHotkey) = .empty,
taskbar: ?*w32.ITaskbarList3 = null,
notif_desktop_surface_id: u64 = 0,
com_initialized: bool = false,
pub fn init(
    self: *App,
    core_app: *CoreApp,
    opts: struct {},
) !void {
    _ = opts;
    const hinstance = w32.GetModuleHandleW(null) orelse
        return error.Win32Error;
    const alloc = core_app.alloc;
    var config = Config.load(alloc) catch |err| err: {
        log.err("failed to load config: {}", .{err});
        var def: Config = try .default(alloc);
        errdefer def.deinit();
        try def.addDiagnosticFmt(
            "error loading user configuration: {}",
            .{err},
        );
        break :err def;
    };
    errdefer config.deinit();
    const bg = config.background;
    const bg_brush = w32.CreateSolidBrush(w32.RGB(bg.r, bg.g, bg.b));
    self.* = .{
        .core_app = core_app,
        .config = config,
        .hinstance = hinstance,
        .bg_brush = bg_brush,
    };
    const app_icon = w32.LoadIconW(hinstance, w32.IDI_WASP) orelse
        w32.LoadIconW(null, w32.IDI_APPLICATION);
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = w32.CS_DBLCLKS,
        .lpfnWndProc = &Window.windowWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = app_icon,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = bg_brush,
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = app_icon,
    };
    self.class_atom = w32.RegisterClassExW(&wc);
    if (self.class_atom == 0) return error.Win32Error;
    errdefer if (self.class_atom != 0) {
        _ = w32.UnregisterClassW(WINDOW_CLASS_NAME, self.hinstance);
    };
    const tc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = w32.CS_OWNDC,
        .lpfnWndProc = &surfaceWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = app_icon,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = TERMINAL_CLASS_NAME,
        .hIconSm = app_icon,
    };
    self.terminal_class_atom = w32.RegisterClassExW(&tc);
    if (self.terminal_class_atom == 0) return error.Win32Error;
    errdefer if (self.terminal_class_atom != 0) {
        _ = w32.UnregisterClassW(TERMINAL_CLASS_NAME, self.hinstance);
    };
    const mc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &msgWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = MSG_CLASS_NAME,
        .hIconSm = null,
    };
    self.msg_class_atom = w32.RegisterClassExW(&mc);
    if (self.msg_class_atom == 0) return error.Win32Error;
    errdefer if (self.msg_class_atom != 0) {
        _ = w32.UnregisterClassW(MSG_CLASS_NAME, self.hinstance);
    };
    self.msg_hwnd = w32.CreateWindowExW(
        0,
        MSG_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral("WaspMsg"),
        0,
        0,
        0,
        0,
        0,
        w32.HWND_MESSAGE,
        null,
        hinstance,
        null,
    );
    if (self.msg_hwnd == null) return error.Win32Error;
    _ = w32.SetWindowLongPtrW(self.msg_hwnd.?, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.registerGlobalHotkey();
    self.startUpdateCheck();
}
pub fn run(self: *App) !void {
    const alloc = self.core_app.alloc;
    const window = try alloc.create(Window);
    errdefer alloc.destroy(window);
    try window.init(self, .{});
    try self.windows.append(alloc, window);
    _ = try window.addTab();
    var msg: w32.MSG = undefined;
    loop: while (true) {
        const result = w32.GetMessageW(&msg, null, 0, 0);
        if (result == 0) {
            if (!self.quit_requested) continue;
            break;
        }
        if (result < 0) return error.Win32Error;
        if (self.quit_requested) break;
        if (msg.message == w32.WM_HOTKEY) {
            const id: i32 = @intCast(msg.wParam);
            for (self.global_hotkeys.items) |hk| {
                if (hk.id != id) continue;
                self.core_app.performAllAction(self, hk.action) catch |err| {
                    log.warn("global hotkey action failed err={}", .{err});
                };
                break;
            }
            continue;
        }
        if (msg.message == w32.WM_KEYDOWN and msg.hwnd != null) {
            const vk: u16 = @intCast(msg.wParam & 0xFFFF);
            if (vk == w32.VK_RETURN or vk == w32.VK_ESCAPE) {
                for (self.windows.items) |win| {
                    if (win.rename_edit != null and win.rename_edit.? == msg.hwnd) {
                        if (vk == w32.VK_RETURN) {
                            win.finishTabRename();
                        } else {
                            win.cancelTabRename();
                        }
                        continue :loop;
                    }
                }
            }
            const parent = w32.GetParent(msg.hwnd.?);
            if (parent) |p| {
                const userdata = w32.GetWindowLongPtrW(p, w32.GWLP_USERDATA);
                if (userdata != 0) {
                    const surface: *Surface = @ptrFromInt(@as(usize, @bitCast(userdata)));
                    if (surface.search_active and surface.search_edit == msg.hwnd) {
                        if (surface.handleSearchKey(vk)) continue;
                    }
                    if (surface.palette_active and surface.palette_edit == msg.hwnd) {
                        if (surface.handlePaletteKey(vk)) continue;
                    }
                }
            }
            const ctrl_held = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0;
            const shift_held = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0;
            const route_key = ctrl_held and (shift_held or !isEditShortcutVk(vk));
            if (route_key) {
                const target_surface: ?*Surface = blk: {
                    for (self.windows.items) |win| {
                        if (win.rename_edit != null and win.rename_edit.? == msg.hwnd) {
                            win.finishTabRename();
                            break :blk win.getActiveSurface();
                        }
                    }
                    const pp = w32.GetParent(msg.hwnd.?) orelse break :blk null;
                    const ud = w32.GetWindowLongPtrW(pp, w32.GWLP_USERDATA);
                    if (ud == 0) break :blk null;
                    const surface: *Surface = @ptrFromInt(@as(usize, @bitCast(ud)));
                    if (surface.palette_active and surface.palette_edit == msg.hwnd) {
                        surface.setCommandPaletteActive(false);
                        break :blk surface;
                    }
                    if (surface.search_active and surface.search_edit == msg.hwnd) {
                        surface.setSearchActive(false, &[_:0]u8{});
                        break :blk surface;
                    }
                    break :blk null;
                };
                if (target_surface) |s| {
                    s.handleKeyEvent(msg.wParam, msg.lParam, .press);
                    continue :loop;
                }
            }
        }
        const skip_translate = switch (msg.message) {
            w32.WM_KEYDOWN, w32.WM_KEYUP, w32.WM_SYSKEYDOWN, w32.WM_SYSKEYUP => blk: {
                if (msg.wParam == w32.VK_PROCESSKEY) break :blk false;
                const h = msg.hwnd orelse break :blk false;
                const atom: u16 = @truncate(w32.GetClassLongW(h, w32.GCW_ATOM));
                break :blk atom != 0 and atom == self.terminal_class_atom;
            },
            else => false,
        };
        if (!skip_translate) _ = w32.TranslateMessage(&msg);
        _ = w32.DispatchMessageW(&msg);
    }
}
pub fn terminate(self: *App) void {
    self.stopQuitTimer();
    for (self.global_hotkeys.items) |hk| _ = w32.UnregisterHotKey(null, hk.id);
    self.global_hotkeys.deinit(self.core_app.alloc);
    if (self.taskbar) |tb| {
        tb.Release();
        self.taskbar = null;
    }
    if (self.quick_terminal) |qt| {
        qt.deinit();
        self.quick_terminal = null;
    }
    if (self.msg_hwnd) |hwnd| {
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(hwnd);
        self.msg_hwnd = null;
    }
    const alloc = self.core_app.alloc;
    for (self.windows.items) |window| {
        window.deinit();
        alloc.destroy(window);
    }
    self.windows.deinit(alloc);
    if (self.bg_brush) |brush| {
        _ = w32.DeleteObject(@ptrCast(brush));
        self.bg_brush = null;
    }
    if (self.msg_class_atom != 0) {
        _ = w32.UnregisterClassW(MSG_CLASS_NAME, self.hinstance);
        self.msg_class_atom = 0;
    }
    if (self.terminal_class_atom != 0) {
        _ = w32.UnregisterClassW(TERMINAL_CLASS_NAME, self.hinstance);
        self.terminal_class_atom = 0;
    }
    if (self.class_atom != 0) {
        _ = w32.UnregisterClassW(WINDOW_CLASS_NAME, self.hinstance);
        self.class_atom = 0;
    }
    self.config.deinit();
}
pub fn wakeup(self: *App) void {
    if (self.msg_hwnd) |hwnd| {
        _ = w32.PostMessageW(hwnd, WM_APP_WAKEUP, 0, 0);
    }
}
pub fn performIpc(
    _: Allocator,
    _: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    _: apprt.ipc.Action.Value(action),
) !bool {
    return false;
}
pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .quit => {
            self.quit_requested = true;
            w32.PostQuitMessage(0);
            return true;
        },
        .new_window => {
            const force_opaque: bool = switch (target) {
                .app => false,
                .surface => |cs| blk: {
                    if (self.config.@"background-opacity" >= 1.0) break :blk false;
                    const h = cs.rt_surface.parent_window.hwnd orelse break :blk false;
                    const ex = w32.GetWindowLongW(h, w32.GWL_EXSTYLE);
                    break :blk (ex & w32.WS_EX_LAYERED) == 0;
                },
            };
            const alloc = self.core_app.alloc;
            const window = alloc.create(Window) catch |err| {
                log.err("failed to allocate new window err={}", .{err});
                return true;
            };
            window.init(self, .{ .force_opaque = force_opaque }) catch |err| {
                log.err("failed to init new window err={}", .{err});
                alloc.destroy(window);
                return true;
            };
            self.windows.append(alloc, window) catch |err| {
                log.err("failed to track new window err={}", .{err});
                window.deinit();
                alloc.destroy(window);
                return true;
            };
            _ = window.addTab() catch |err| {
                log.err("failed to add tab to new window err={}", .{err});
                return true;
            };
            return true;
        },
        .set_title => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const rt_surface = core_surface.rt_surface;
                    rt_surface.setTitle(value.title);
                },
            }
            return true;
        },
        .ring_bell => {
            _ = w32.MessageBeep(0xFFFFFFFF);
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.parent_window.hwnd) |win_hwnd| {
                        if (w32.GetForegroundWindow() != win_hwnd) {
                            var fwi: w32.FLASHWINFO = .{
                                .cbSize = @sizeOf(w32.FLASHWINFO),
                                .hwnd = win_hwnd,
                                .dwFlags = w32.FLASHW_ALL | w32.FLASHW_TIMERNOFG,
                                .uCount = 2,
                                .dwTimeout = 0,
                            };
                            _ = w32.FlashWindowEx(&fwi);
                        }
                    }
                },
            }
            return true;
        },
        .quit_timer => {
            switch (value) {
                .start => self.startQuitTimer(),
                .stop => self.stopQuitTimer(),
            }
            return true;
        },
        .config_change => {
            if (value.config.clone(self.core_app.alloc)) |new_config| {
                self.config.deinit();
                self.config = new_config;
                if (self.bg_brush) |old_brush| {
                    _ = w32.DeleteObject(@ptrCast(old_brush));
                }
                const bg = new_config.background;
                self.bg_brush = w32.CreateSolidBrush(w32.RGB(bg.r, bg.g, bg.b));
                for (self.windows.items) |w| w.onConfigChange();
                for (self.global_hotkeys.items) |hk| _ = w32.UnregisterHotKey(null, hk.id);
                self.global_hotkeys.clearRetainingCapacity();
                self.registerGlobalHotkey();
                if (self.quick_terminal) |qt| {
                    qt.onConfigChange(&self.config);
                }
            } else |err| {
                log.err("error updating app config err={}", .{err});
            }
            return true;
        },
        .toggle_fullscreen => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.toggleFullscreen();
                },
            }
            return true;
        },
        .toggle_maximize => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.parent_window.hwnd) |hwnd| {
                        if (w32.IsZoomed(hwnd) != 0) {
                            _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
                        } else {
                            _ = w32.ShowWindow(hwnd, w32.SW_MAXIMIZE);
                        }
                    }
                },
            }
            return true;
        },
        .close_window => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const win = core_surface.rt_surface.parent_window;
                    if (win.confirmCloseIfNeeded()) win.close();
                },
            }
            return true;
        },
        .open_config => {
            const config_path = configpkg.edit.openPath(
                self.core_app.alloc,
            ) catch |err| {
                log.err("failed to get config path: {}", .{err});
                return false;
            };
            defer self.core_app.alloc.free(config_path);
            return switch (value) {
                .os_open => self.openConfigWithOs(config_path),
                .new_window => (try self.openConfigInNewWindow(config_path)) or
                    self.openConfigWithOs(config_path),
            };
        },
        .scrollbar => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setScrollbar(value);
                },
            }
            return true;
        },
        .mouse_shape => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setMouseShape(value);
                },
            }
            return true;
        },
        .open_url => {
            var wbuf: [2048]u16 = undefined;
            const wlen = std.unicode.utf8ToUtf16Le(&wbuf, value.url) catch return true;
            if (wlen < wbuf.len) {
                wbuf[wlen] = 0;
                _ = w32.ShellExecuteW(
                    null,
                    std.unicode.utf8ToUtf16LeStringLiteral("open"),
                    @ptrCast(&wbuf),
                    null,
                    null,
                    w32.SW_SHOW,
                );
            }
            return true;
        },
        .mouse_over_link => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setMouseOverLink(value.url);
                },
            }
            return true;
        },
        .start_search => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setSearchActive(true, value.needle);
                },
            }
            return true;
        },
        .end_search => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setSearchActive(false, "");
                },
            }
            return true;
        },
        .search_total => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setSearchTotal(value.total);
                },
            }
            return true;
        },
        .search_selected => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setSearchSelected(value.selected);
                },
            }
            return true;
        },
        .desktop_notification => {
            self.showDesktopNotification(target, value);
            return true;
        },
        .new_tab => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const parent = core_surface.rt_surface.parent_window;
                    _ = parent.addTab() catch |err| {
                        log.err("failed to add new tab err={}", .{err});
                    };
                },
            }
            return true;
        },
        .close_tab => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.closeTabMode(
                        value,
                        core_surface.rt_surface,
                    );
                },
            }
            return true;
        },
        .goto_tab => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    _ = core_surface.rt_surface.parent_window.selectTab(value);
                },
            }
            return true;
        },
        .set_tab_title => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.onTabTitleChanged(
                        core_surface.rt_surface,
                        value.title,
                    );
                },
            }
            return true;
        },
        .set_window_title => {
            switch (target) {
                .app => return false,
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.setWindowTitle(value.title);
                },
            }
            return true;
        },
        .move_tab => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.moveTab(value.amount);
                },
            }
            return true;
        },
        .move_tab_to_new_window => {
            return switch (target) {
                .app => false,
                .surface => |core_surface| try core_surface.rt_surface.parent_window
                    .moveTabToNewWindow(core_surface.rt_surface),
            };
        },
        .toggle_tab_overview => {
            return true;
        },
        .initial_size => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.parent_window.hwnd) |h| {
                        var rect = w32.RECT{
                            .left = 0,
                            .top = 0,
                            .right = @intCast(value.width),
                            .bottom = @intCast(value.height),
                        };
                        _ = w32.AdjustWindowRectEx(&rect, w32.WS_OVERLAPPEDWINDOW, 0, 0);
                        _ = w32.SetWindowPos(
                            h,
                            null,
                            0,
                            0,
                            rect.right - rect.left,
                            rect.bottom - rect.top,
                            w32.SWP_NOZORDER | w32.SWP_NOMOVE,
                        );
                    }
                },
            }
            return true;
        },
        .reload_config => {
            const alloc = self.core_app.alloc;
            if (value.soft) {
                self.core_app.updateConfig(self, &self.config) catch |err| {
                    log.err("soft config reload error: {}", .{err});
                };
            } else {
                var new_config = Config.load(alloc) catch |err| {
                    log.err("failed to reload config: {}", .{err});
                    return true;
                };
                defer new_config.deinit();
                self.core_app.updateConfig(self, &new_config) catch |err| {
                    log.err("config update error: {}", .{err});
                };
            }
            return true;
        },
        .show_child_exited => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const exit_code = value.exit_code;
                    if (exit_code != 0) {
                        const hwnd_val = core_surface.rt_surface.parent_window.hwnd;
                        var utf8_buf: [128]u8 = undefined;
                        const msg_utf8 = std.fmt.bufPrint(
                            &utf8_buf,
                            "The shell process exited with code {d}.",
                            .{exit_code},
                        ) catch "The shell process exited unexpectedly.";
                        var utf16_buf: [256]u16 = undefined;
                        const utf16_len = std.unicode.utf8ToUtf16Le(&utf16_buf, msg_utf8) catch {
                            _ = w32.MessageBoxW(
                                hwnd_val,
                                std.unicode.utf8ToUtf16LeStringLiteral("The shell process exited unexpectedly."),
                                std.unicode.utf8ToUtf16LeStringLiteral("Wasp"),
                                w32.MB_ICONWARNING,
                            );
                            return true;
                        };
                        utf16_buf[utf16_len] = 0;
                        _ = w32.MessageBoxW(
                            hwnd_val,
                            @ptrCast(&utf16_buf),
                            std.unicode.utf8ToUtf16LeStringLiteral("Wasp"),
                            w32.MB_ICONWARNING,
                        );
                    }
                },
            }
            return true;
        },
        .toggle_window_decorations => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.toggleWindowDecorations();
                },
            }
            return true;
        },
        .close_all_windows => {
            self.quit_requested = true;
            w32.PostQuitMessage(0);
            return true;
        },
        .toggle_background_opacity => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.parent_window.hwnd) |h| {
                        const current_ex = w32.GetWindowLongW(h, w32.GWL_EXSTYLE);
                        if (current_ex & w32.WS_EX_LAYERED != 0) {
                            _ = w32.SetWindowLongW(h, w32.GWL_EXSTYLE, current_ex & ~w32.WS_EX_LAYERED);
                            _ = w32.RedrawWindow(
                                h,
                                null,
                                null,
                                w32.RDW_ERASE | w32.RDW_INVALIDATE | w32.RDW_FRAME | w32.RDW_ALLCHILDREN,
                            );
                        } else {
                            _ = w32.SetWindowLongW(h, w32.GWL_EXSTYLE, current_ex | w32.WS_EX_LAYERED);
                            const alpha: u8 = @intFromFloat(@round(self.config.@"background-opacity" * 255.0));
                            _ = w32.SetLayeredWindowAttributes(h, 0, alpha, w32.LWA_ALPHA);
                        }
                    }
                },
            }
            return true;
        },
        .goto_window => {
            return true;
        },
        .reset_window_size => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.parent_window.hwnd) |h| {
                        var rect = w32.RECT{
                            .left = 0,
                            .top = 0,
                            .right = 800,
                            .bottom = 600,
                        };
                        _ = w32.AdjustWindowRectEx(&rect, w32.WS_OVERLAPPEDWINDOW, 0, 0);
                        _ = w32.SetWindowPos(
                            h,
                            null,
                            0,
                            0,
                            rect.right - rect.left,
                            rect.bottom - rect.top,
                            w32.SWP_NOZORDER | w32.SWP_NOMOVE,
                        );
                    }
                },
            }
            return true;
        },
        .copy_title_to_clipboard => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.parent_window.hwnd) |h| {
                        var wbuf: [512]u16 = undefined;
                        const wlen: usize = @intCast(w32.GetWindowTextW(h, &wbuf, @intCast(wbuf.len)));
                        if (wlen > 0) {
                            var utf8_buf: [1024]u8 = undefined;
                            const utf8_len = std.unicode.utf16LeToUtf8(&utf8_buf, wbuf[0..wlen]) catch 0;
                            if (utf8_len > 0) {
                                const alloc = self.core_app.alloc;
                                const text = alloc.dupeZ(u8, utf8_buf[0..utf8_len]) catch return true;
                                defer alloc.free(text);
                                core_surface.rt_surface.setClipboard(
                                    .standard,
                                    &.{.{ .mime = "text/plain", .data = text }},
                                    false,
                                ) catch {};
                            }
                        }
                    }
                },
            }
            return true;
        },
        .export_terminal_io => return self.exportTerminalIo(target, value.contents),
        .render => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.core_surface_ready) {
                        core_surface.rt_surface.core_surface.renderer_thread.wakeup.notify() catch {};
                    }
                },
            }
            return true;
        },
        .key_sequence,
        .key_table,
        .pwd,
        .cell_size,
        .readonly,
        .secure_input,
        .undo,
        .redo,
        .show_gtk_inspector,
        .show_on_screen_keyboard,
        .inspector,
        .render_inspector,
        => return true,
        .renderer_health => {
            switch (value) {
                .healthy => {},
                .unhealthy => {
                    self.notif_desktop_surface_id = 0;
                    self.showDesktopNotificationText(
                        "Renderer Unhealthy",
                        "The GPU renderer is in an unhealthy state; terminal output may stop updating.",
                    );
                },
            }
            return true;
        },
        .progress_report => {
            if (!self.config.@"progress-style") return true;
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const hwnd = core_surface.rt_surface.parent_window.hwnd orelse
                        return true;
                    const tb = self.taskbarList() orelse return true;
                    switch (value.state) {
                        .remove => tb.SetProgressState(hwnd, w32.TBPF_NOPROGRESS),
                        .indeterminate => tb.SetProgressState(hwnd, w32.TBPF_INDETERMINATE),
                        .set => {
                            tb.SetProgressState(hwnd, w32.TBPF_NORMAL);
                            if (value.progress) |p| tb.SetProgressValue(hwnd, p, 100);
                        },
                        .@"error" => {
                            tb.SetProgressState(hwnd, w32.TBPF_ERROR);
                            if (value.progress) |p| tb.SetProgressValue(hwnd, p, 100);
                        },
                        .pause => {
                            tb.SetProgressState(hwnd, w32.TBPF_PAUSED);
                            if (value.progress) |p| tb.SetProgressValue(hwnd, p, 100);
                        },
                    }
                },
            }
            return true;
        },
        .color_change => {
            if (value.kind != .background) return true;
            if (self.bg_brush) |old_brush| {
                _ = w32.DeleteObject(@ptrCast(old_brush));
            }
            self.bg_brush = w32.CreateSolidBrush(w32.RGB(value.r, value.g, value.b));
            for (self.windows.items) |w| {
                if (w.hwnd) |h| {
                    if (self.bg_brush) |b| {
                        _ = w32.SetClassLongPtrW(
                            h,
                            w32.GCLP_HBRBACKGROUND,
                            @intCast(@intFromPtr(b)),
                        );
                    }
                }
            }
            return true;
        },
        .size_limit => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const win = core_surface.rt_surface.parent_window;
                    win.min_track_w = @intCast(value.min_width);
                    win.min_track_h = @intCast(value.min_height);
                    win.max_track_w = @intCast(value.max_width);
                    win.max_track_h = @intCast(value.max_height);
                },
            }
            return true;
        },
        .toggle_visibility => {
            var any_visible = false;
            for (self.windows.items) |w| {
                if (w.hwnd) |h| {
                    if (w32.IsWindowVisible_(h) != 0) {
                        any_visible = true;
                        break;
                    }
                }
            }
            for (self.windows.items) |w| {
                if (w.hwnd) |h| {
                    if (any_visible) {
                        _ = w32.ShowWindow(h, w32.SW_HIDE);
                    } else {
                        _ = w32.ShowWindow(h, w32.SW_SHOWNOACTIVATE);
                    }
                }
            }
            return true;
        },
        .float_window => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const win_hwnd = core_surface.rt_surface.parent_window.hwnd orelse return true;
                    const ex = w32.GetWindowLongPtrW(win_hwnd, w32.GWL_EXSTYLE);
                    const is_topmost = (ex & @as(isize, w32.WS_EX_TOPMOST)) != 0;
                    const want: bool = switch (value) {
                        .on => true,
                        .off => false,
                        .toggle => !is_topmost,
                    };
                    if (want == is_topmost) return true;
                    const insert_after = if (want) w32.HWND_TOPMOST else w32.HWND_NOTOPMOST;
                    _ = w32.SetWindowPos(
                        win_hwnd,
                        insert_after,
                        0,
                        0,
                        0,
                        0,
                        w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_NOACTIVATE,
                    );
                },
            }
            return true;
        },
        .command_finished => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    switch (self.config.@"notify-on-command-finish") {
                        .never => return true,
                        .unfocused => if (core_surface.focused) return true,
                        .always => {},
                    }
                    if (value.duration.lte(self.config.@"notify-on-command-finish-after"))
                        return true;
                    const act = self.config.@"notify-on-command-finish-action";
                    if (act.bell) {
                        _ = w32.MessageBeep(0xFFFFFFFF);
                        if (core_surface.rt_surface.parent_window.hwnd) |win_hwnd| {
                            if (w32.GetForegroundWindow() != win_hwnd) {
                                var fwi: w32.FLASHWINFO = .{
                                    .cbSize = @sizeOf(w32.FLASHWINFO),
                                    .hwnd = win_hwnd,
                                    .dwFlags = w32.FLASHW_ALL | w32.FLASHW_TIMERNOFG,
                                    .uCount = 3,
                                    .dwTimeout = 0,
                                };
                                _ = w32.FlashWindowEx(&fwi);
                            }
                        }
                    }
                    if (act.notify) {
                        const title: []const u8 = if (value.exit_code) |code|
                            (if (code == 0) "Command Succeeded" else "Command Failed")
                        else
                            "Command Finished";
                        var body_buf: [128]u8 = undefined;
                        const body: []const u8 = if (value.exit_code) |code|
                            std.fmt.bufPrint(
                                &body_buf,
                                "Command took {f} and exited with code {d}.",
                                .{ value.duration.round(std.time.ns_per_ms), code },
                            ) catch "Command finished."
                        else
                            std.fmt.bufPrint(
                                &body_buf,
                                "Command took {f}.",
                                .{value.duration.round(std.time.ns_per_ms)},
                            ) catch "Command finished.";
                        self.notif_desktop_surface_id = core_surface.id;
                        self.showDesktopNotificationText(title, body);
                    }
                },
            }
            return true;
        },
        .mouse_visibility => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const visible = value == .visible;
                    core_surface.rt_surface.mouse_visible = visible;
                    if (!visible) {
                        _ = w32.SetCursor(null);
                    } else if (core_surface.rt_surface.current_cursor) |c| {
                        _ = w32.SetCursor(c);
                    }
                },
            }
            return true;
        },
        .present_terminal => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const win = core_surface.rt_surface.parent_window;
                    if (win.hwnd) |hwnd| {
                        _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
                        _ = w32.SetForegroundWindow(hwnd);
                        if (win.findTabIndex(core_surface.rt_surface)) |idx| {
                            if (idx != win.active_tab) win.selectTabIndex(idx);
                        }
                        if (core_surface.rt_surface.hwnd) |sh| {
                            _ = w32.SetFocus(sh);
                        }
                    }
                },
            }
            return true;
        },
        .new_split => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const dir: SplitTree(Surface).Split.Direction = switch (value) {
                        .left => .left,
                        .right => .right,
                        .up => .up,
                        .down => .down,
                    };
                    core_surface.rt_surface.parent_window.newSplit(dir) catch |err| {
                        log.err("failed to create split: {}", .{err});
                    };
                },
            }
            return true;
        },
        .goto_split => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.gotoSplit(value);
                },
            }
            return true;
        },
        .resize_split => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.resizeSplit(value);
                },
            }
            return true;
        },
        .equalize_splits => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.equalizeSplits();
                },
            }
            return true;
        },
        .toggle_split_zoom => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.parent_window.toggleSplitZoom();
                },
            }
            return true;
        },
        .prompt_title => {
            return switch (target) {
                .app => false,
                .surface => |core_surface| blk: {
                    const window = core_surface.rt_surface.parent_window;
                    switch (value) {
                        .surface, .tab => window.startTabRename(window.active_tab),
                        .window => window.startWindowRename(),
                    }
                    break :blk true;
                },
            };
        },
        .check_for_updates => {
            self.startUpdateCheck();
            return true;
        },
        .toggle_command_palette => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const active = core_surface.rt_surface.palette_active;
                    core_surface.rt_surface.setCommandPaletteActive(!active);
                },
            }
            return true;
        },
        .toggle_quick_terminal => {
            if (self.quick_terminal) |qt| {
                qt.toggle();
            } else {
                const qt = QuickTerminal.init(self) catch |err| {
                    log.err("failed to create quick terminal: {}", .{err});
                    return true;
                };
                self.quick_terminal = qt;
                qt.toggle();
            }
            return true;
        },
        .selection_changed => {
            return true;
        },
    }
}
fn openConfigWithOs(self: *App, path: [:0]const u8) bool {
    const alloc = self.core_app.alloc;
    const path_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch |err| {
        log.warn("unable to encode config path: {}", .{err});
        return false;
    };
    defer alloc.free(path_w);
    const result = w32.ShellExecuteW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        path_w,
        null,
        null,
        w32.SW_SHOW,
    );
    return result > 32;
}
fn openConfigInNewWindow(self: *App, path: [:0]const u8) !bool {
    const alloc = self.core_app.alloc;
    const editor = global.environ().getAlloc(alloc, "VISUAL") catch
        global.environ().getAlloc(alloc, "EDITOR") catch return false;
    defer alloc.free(editor);
    if (std.mem.trim(u8, editor, " \t\r\n").len == 0) return false;
    const command_text = try std.fmt.allocPrintSentinel(
        alloc,
        "{s} \"{s}\"",
        .{ editor, path },
        0,
    );
    defer alloc.free(command_text);
    const command: configpkg.Command = .{ .shell = command_text };
    const title = try std.fmt.allocPrintSentinel(
        alloc,
        "Editing configuration file {s}",
        .{path},
        0,
    );
    defer alloc.free(title);
    const window = try alloc.create(Window);
    window.init(self, .{}) catch |err| {
        alloc.destroy(window);
        return err;
    };
    self.windows.append(alloc, window) catch |err| {
        window.deinit();
        alloc.destroy(window);
        return err;
    };
    _ = window.addTabWithOptions(.{
        .context = .window,
        .command = &command,
        .title = title,
    }) catch |err| {
        window.close();
        return err;
    };
    return true;
}
fn exportTerminalIo(self: *App, target: apprt.Target, contents: []const u8) bool {
    const owner = switch (target) {
        .app => return false,
        .surface => |core_surface| core_surface.rt_surface.parent_window.hwnd,
    };
    var file_buf: [32768]u16 = std.mem.zeroes([32768]u16);
    const default_name = std.unicode.utf8ToUtf16LeStringLiteral("wasp-terminal-io.txt");
    @memcpy(file_buf[0..default_name.len], default_name);
    const filter = std.unicode.utf8ToUtf16LeStringLiteral(
        "Text files (*.txt)\x00*.txt\x00All files (*.*)\x00*.*\x00",
    );
    var dialog: w32.OPENFILENAMEW = std.mem.zeroes(w32.OPENFILENAMEW);
    dialog.lStructSize = @sizeOf(w32.OPENFILENAMEW);
    dialog.hwndOwner = owner;
    dialog.lpstrFilter = filter;
    dialog.nFilterIndex = 1;
    dialog.lpstrFile = &file_buf;
    dialog.nMaxFile = file_buf.len;
    dialog.lpstrTitle = std.unicode.utf8ToUtf16LeStringLiteral("Export Terminal IO Events");
    dialog.lpstrDefExt = std.unicode.utf8ToUtf16LeStringLiteral("txt");
    dialog.Flags = w32.OFN_EXPLORER |
        w32.OFN_NOCHANGEDIR |
        w32.OFN_PATHMUSTEXIST |
        w32.OFN_OVERWRITEPROMPT;
    if (w32.GetSaveFileNameW(&dialog) == 0) return true;
    const path_len = std.mem.indexOfScalar(u16, &file_buf, 0) orelse file_buf.len;
    const alloc = self.core_app.alloc;
    const path = std.unicode.utf16LeToUtf8Alloc(alloc, file_buf[0..path_len]) catch |err| {
        log.warn("unable to decode terminal IO export path: {}", .{err});
        return false;
    };
    defer alloc.free(path);
    var file = std.Io.Dir.createFileAbsolute(global.io(), path, .{ .truncate = true }) catch |err| {
        log.warn("unable to create terminal IO export file: {}", .{err});
        return false;
    };
    defer file.close(global.io());
    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(global.io(), &write_buf);
    writer.interface.writeAll(contents) catch |err| {
        log.warn("unable to write terminal IO export file: {}", .{err});
        return false;
    };
    writer.interface.flush() catch |err| {
        log.warn("unable to flush terminal IO export file: {}", .{err});
        return false;
    };
    return true;
}
fn isEditShortcutVk(vk: u16) bool {
    return switch (vk) {
        'A', 'C', 'V', 'X', 'Y', 'Z' => true,
        else => false,
    };
}
fn taskbarList(self: *App) ?*w32.ITaskbarList3 {
    if (self.taskbar) |tb| return tb;
    if (!self.com_initialized) {
        _ = w32.CoInitializeEx(null, w32.COINIT_APARTMENTTHREADED);
        self.com_initialized = true;
    }
    var ptr: ?*anyopaque = null;
    const hr = w32.CoCreateInstance(
        &w32.CLSID_TaskbarList,
        null,
        w32.CLSCTX_INPROC_SERVER,
        &w32.IID_ITaskbarList3,
        &ptr,
    );
    if (hr < 0 or ptr == null) return null;
    const tb: *w32.ITaskbarList3 = @ptrCast(@alignCast(ptr.?));
    _ = tb.HrInit();
    self.taskbar = tb;
    return tb;
}
fn registerGlobalHotkey(self: *App) void {
    const alloc = self.core_app.alloc;
    var next_id: i32 = 1;
    var it = self.config.keybind.set.bindings.iterator();
    while (it.next()) |entry| {
        const leaf = switch (entry.value_ptr.*) {
            .leaf => |l| l,
            .leader, .leaf_chained => continue,
        };
        if (!leaf.flags.global) continue;
        const trigger = entry.key_ptr.*;
        var mods: u32 = w32.MOD_NOREPEAT;
        if (trigger.mods.ctrl) mods |= w32.MOD_CONTROL;
        if (trigger.mods.alt) mods |= w32.MOD_ALT;
        if (trigger.mods.shift) mods |= w32.MOD_SHIFT;
        if (trigger.mods.super) mods |= w32.MOD_WIN;
        const vk: ?u32 = switch (trigger.key) {
            .physical => |phys| keyToVk(phys),
            .unicode => |cp| blk: {
                if (cp >= 'a' and cp <= 'z') break :blk @as(u32, cp - 'a' + 'A');
                if (cp >= '0' and cp <= '9') break :blk @as(u32, cp);
                break :blk null;
            },
            else => null,
        };
        const vk_code = vk orelse {
            log.warn("unsupported key for global hotkey action={s}", .{@tagName(leaf.action)});
            continue;
        };
        const id = next_id;
        if (w32.RegisterHotKey(null, id, mods, vk_code) == 0) {
            log.warn("failed to register global hotkey (may be in use) action={s}", .{@tagName(leaf.action)});
            continue;
        }
        self.global_hotkeys.append(alloc, .{ .id = id, .action = leaf.action }) catch {
            _ = w32.UnregisterHotKey(null, id);
            continue;
        };
        next_id += 1;
        log.info("registered global hotkey id={} action={s}", .{ id, @tagName(leaf.action) });
    }
}
fn keyToVk(key: @import("../../input/key.zig").Key) ?u32 {
    return switch (key) {
        .key_a => 0x41,
        .key_b => 0x42,
        .key_c => 0x43,
        .key_d => 0x44,
        .key_e => 0x45,
        .key_f => 0x46,
        .key_g => 0x47,
        .key_h => 0x48,
        .key_i => 0x49,
        .key_j => 0x4A,
        .key_k => 0x4B,
        .key_l => 0x4C,
        .key_m => 0x4D,
        .key_n => 0x4E,
        .key_o => 0x4F,
        .key_p => 0x50,
        .key_q => 0x51,
        .key_r => 0x52,
        .key_s => 0x53,
        .key_t => 0x54,
        .key_u => 0x55,
        .key_v => 0x56,
        .key_w => 0x57,
        .key_x => 0x58,
        .key_y => 0x59,
        .key_z => 0x5A,
        .digit_0 => 0x30,
        .digit_1 => 0x31,
        .digit_2 => 0x32,
        .digit_3 => 0x33,
        .digit_4 => 0x34,
        .digit_5 => 0x35,
        .digit_6 => 0x36,
        .digit_7 => 0x37,
        .digit_8 => 0x38,
        .digit_9 => 0x39,
        .backquote => w32.VK_OEM_3,
        .minus => w32.VK_OEM_MINUS,
        .equal => w32.VK_OEM_PLUS,
        .bracket_left => w32.VK_OEM_4,
        .bracket_right => w32.VK_OEM_6,
        .backslash => w32.VK_OEM_5,
        .semicolon => w32.VK_OEM_1,
        .quote => w32.VK_OEM_7,
        .comma => w32.VK_OEM_COMMA,
        .period => w32.VK_OEM_PERIOD,
        .slash => w32.VK_OEM_2,
        .enter => w32.VK_RETURN,
        .tab => w32.VK_TAB,
        .space => w32.VK_SPACE,
        .backspace => w32.VK_BACK,
        .escape => w32.VK_ESCAPE,
        .f1 => w32.VK_F1,
        .f2 => w32.VK_F2,
        .f3 => w32.VK_F3,
        .f4 => w32.VK_F4,
        .f5 => w32.VK_F5,
        .f6 => w32.VK_F6,
        .f7 => w32.VK_F7,
        .f8 => w32.VK_F8,
        .f9 => w32.VK_F9,
        .f10 => w32.VK_F10,
        .f11 => w32.VK_F11,
        .f12 => w32.VK_F12,
        else => null,
    };
}
const UPDATE_URL = "https://api.github.com/repos/InsipidPoint/wasp-windows/releases/latest";
const WM_APP_UPDATE_AVAILABLE: u32 = w32.WM_APP + 2;
const WM_APP_TRAY: u32 = w32.WM_APP + 3;
const RELEASES_URL = "https://github.com/InsipidPoint/wasp-windows/releases/latest";
const NOTIF_DESKTOP_UID: u32 = 1;
const NOTIF_DESKTOP_TIMER_ID: usize = 2;
const NOTIF_UPDATE_UID: u32 = 2;
const NOTIF_UPDATE_TIMER_ID: usize = 3;
const UPDATE_CHECK_INTERVAL_SECS: i64 = 60 * 60;
fn startUpdateCheck(self: *App) void {
    if (!self.shouldRunUpdateCheck()) {
        log.debug("skipping update check (last run within {d}s)", .{UPDATE_CHECK_INTERVAL_SECS});
        return;
    }
    _ = std.Thread.spawn(.{}, updateCheckThread, .{self}) catch |err| {
        log.warn("failed to start update check thread: {}", .{err});
    };
}
fn shouldRunUpdateCheck(self: *App) bool {
    const alloc = self.core_app.alloc;
    const io = global.io();
    const dir = global.environ().getAlloc(alloc, "LOCALAPPDATA") catch return true;
    defer alloc.free(dir);
    const path = std.fs.path.join(alloc, &.{ dir, "wasp", "update_check_at" }) catch return true;
    defer alloc.free(path);
    const now = std.Io.Clock.now(.real, io).toSeconds();
    if (std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(32))) |contents| {
        defer alloc.free(contents);
        const text = std.mem.trim(u8, contents, " \t\r\n");
        if (std.fmt.parseInt(i64, text, 10)) |last| {
            if (now - last < UPDATE_CHECK_INTERVAL_SECS) return false;
        } else |_| {}
    } else |_| {}
    std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path) orelse return true) catch {};
    var ts_buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&ts_buf, "{d}", .{now}) catch return true;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = s }) catch {};
    return true;
}
fn updateCheckThread(app: *App) void {
    const result = fetchLatestVersion() catch |err| {
        log.debug("update check failed: {}", .{err});
        return;
    };
    const latest = result.tag;
    const latest_len = result.len;
    if (latest_len == 0) return;
    const latest_start: usize = if (std.mem.startsWith(u8, latest[0..latest_len], "win-v"))
        5
    else if (latest[0] == 'v')
        1
    else
        0;
    const latest_ver = latest[latest_start..latest_len];
    const current_sv = build_config.version;
    const latest_sv = std.SemanticVersion.parse(latest_ver) catch {
        log.debug("failed to parse remote version: {s}", .{latest_ver});
        return;
    };
    if (latest_sv.order(current_sv) != .gt) {
        log.debug("up to date: current={d}.{d}.{d} latest={s}", .{
            current_sv.major, current_sv.minor, current_sv.patch, latest_ver,
        });
        return;
    }
    log.info("update available: current={d}.{d}.{d} latest={s}", .{
        current_sv.major, current_sv.minor, current_sv.patch, latest_ver,
    });
    const hwnd = app.msg_hwnd orelse return;
    const alloc = app.core_app.alloc;
    const owned = alloc.dupe(u8, latest_ver) catch {
        log.warn("oom allocating update version", .{});
        return;
    };
    const wparam: usize = @intFromPtr(owned.ptr);
    const lparam: isize = @intCast(owned.len);
    if (w32.PostMessageW(hwnd, WM_APP_UPDATE_AVAILABLE, wparam, lparam) == 0) {
        alloc.free(owned);
    }
}
fn showUpdateNotification(self: *App, ver: []const u8) void {
    const hwnd = self.msg_hwnd orelse return;
    if (ver.len == 0) return;
    const ver_len = ver.len;
    var nid: w32.NOTIFYICONDATAW = std.mem.zeroes(w32.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = NOTIF_UPDATE_UID;
    nid.uFlags = w32.NIF_INFO | w32.NIF_ICON | w32.NIF_TIP | w32.NIF_MESSAGE;
    nid.uCallbackMessage = WM_APP_TRAY;
    nid.hIcon = w32.LoadIconW(self.hinstance, w32.IDI_WASP) orelse w32.LoadIconW(null, w32.IDI_APPLICATION);
    nid.dwInfoFlags = w32.NIIF_INFO;
    nid.uVersion_or_uTimeout = 10000;
    const title = std.unicode.utf8ToUtf16LeStringLiteral("Wasp Update Available");
    @memcpy(nid.szInfoTitle[0..title.len], title);
    nid.szInfoTitle[title.len] = 0;
    var body_utf8: [256]u8 = undefined;
    const body_len = std.fmt.bufPrint(&body_utf8, "Version {s} is available.\nVisit GitHub releases to download.", .{ver[0..ver_len]}) catch return;
    var body_utf16: [256]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&body_utf16, body_len) catch 0;
    @memcpy(nid.szInfo[0..wlen], body_utf16[0..wlen]);
    nid.szInfo[wlen] = 0;
    const tip = std.unicode.utf8ToUtf16LeStringLiteral("Wasp");
    @memcpy(nid.szTip[0..tip.len], tip);
    nid.szTip[tip.len] = 0;
    _ = w32.Shell_NotifyIconW(w32.NIM_ADD, &nid);
    _ = w32.Shell_NotifyIconW(w32.NIM_MODIFY, &nid);
    _ = w32.SetTimer(hwnd, NOTIF_UPDATE_TIMER_ID, 10000, null);
}
const VersionResult = struct { tag: [128]u8, len: usize };
fn fetchLatestVersion() !VersionResult {
    const agent = std.unicode.utf8ToUtf16LeStringLiteral("Wasp-UpdateCheck/1.0");
    const inet = w32.InternetOpenW(agent, w32.INTERNET_OPEN_TYPE_PRECONFIG, null, null, 0) orelse
        return error.InternetOpenFailed;
    defer _ = w32.InternetCloseHandle(inet);
    var url_buf: [256]u16 = undefined;
    const url_len = std.unicode.utf8ToUtf16Le(&url_buf, UPDATE_URL) catch return error.UrlTooLong;
    url_buf[url_len] = 0;
    const flags = w32.INTERNET_FLAG_SECURE | w32.INTERNET_FLAG_NO_CACHE_WRITE | w32.INTERNET_FLAG_RELOAD;
    const conn = w32.InternetOpenUrlW(inet, @ptrCast(&url_buf), null, 0, flags, 0) orelse
        return error.InternetOpenUrlFailed;
    defer _ = w32.InternetCloseHandle(conn);
    var response: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < response.len) {
        var bytes_read: u32 = 0;
        if (w32.InternetReadFile(conn, response[total..].ptr, @intCast(response.len - total), &bytes_read) == 0) {
            return error.ReadFailed;
        }
        if (bytes_read == 0) break;
        total += bytes_read;
    }
    const json = response[0..total];
    const needle = "\"tag_name\":\"";
    const start = std.mem.indexOf(u8, json, needle) orelse return error.TagNotFound;
    const tag_start = start + needle.len;
    const tag_end = std.mem.indexOfPos(u8, json, tag_start, "\"") orelse return error.TagNotFound;
    const tag = json[tag_start..tag_end];
    var result: VersionResult = .{ .tag = undefined, .len = tag.len };
    if (tag.len > 128) return error.TagTooLong;
    @memcpy(result.tag[0..tag.len], tag);
    return result;
}
pub fn startQuitTimer(self: *App) void {
    self.stopQuitTimer();
    if (!self.config.@"quit-after-last-window-closed") return;
    if (self.config.@"quit-after-last-window-closed-delay") |v| {
        const ms = v.asMilliseconds();
        if (self.msg_hwnd) |hwnd| {
            _ = w32.SetTimer(hwnd, QUIT_TIMER_ID, ms, null);
            self.quit_timer_state = .active;
        }
    } else {
        self.quit_timer_state = .expired;
        self.quit_requested = true;
        w32.PostQuitMessage(0);
    }
}
pub fn stopQuitTimer(self: *App) void {
    switch (self.quit_timer_state) {
        .off => {},
        .expired => {
            self.quit_timer_state = .off;
            self.quit_requested = false;
        },
        .active => {
            if (self.msg_hwnd) |hwnd| {
                _ = w32.KillTimer(hwnd, QUIT_TIMER_ID);
            }
            self.quit_timer_state = .off;
        },
    }
}
fn showDesktopNotification(
    self: *App,
    target: apprt.Target,
    value: apprt.Action.Value(.desktop_notification),
) void {
    self.notif_desktop_surface_id = switch (target) {
        .app => 0,
        .surface => |core_surface| core_surface.id,
    };
    self.showDesktopNotificationText(value.title, value.body);
}
fn showDesktopNotificationText(self: *App, title: []const u8, body: []const u8) void {
    const hwnd = self.msg_hwnd orelse return;
    var nid: w32.NOTIFYICONDATAW = std.mem.zeroes(w32.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = NOTIF_DESKTOP_UID;
    nid.uFlags = w32.NIF_INFO | w32.NIF_ICON | w32.NIF_TIP | w32.NIF_MESSAGE;
    nid.uCallbackMessage = WM_APP_TRAY;
    nid.hIcon = w32.LoadIconW(self.hinstance, w32.IDI_WASP) orelse w32.LoadIconW(null, w32.IDI_APPLICATION);
    nid.dwInfoFlags = w32.NIIF_INFO;
    nid.uVersion_or_uTimeout = 5000;
    const title_z = title;
    var title_len = std.unicode.utf8ToUtf16Le(&nid.szInfoTitle, title_z) catch 0;
    if (title_len >= nid.szInfoTitle.len) title_len = nid.szInfoTitle.len - 1;
    nid.szInfoTitle[title_len] = 0;
    const body_z = body;
    var body_len = std.unicode.utf8ToUtf16Le(&nid.szInfo, body_z) catch 0;
    if (body_len >= nid.szInfo.len) body_len = nid.szInfo.len - 1;
    nid.szInfo[body_len] = 0;
    const tip = std.unicode.utf8ToUtf16LeStringLiteral("Wasp");
    @memcpy(nid.szTip[0..tip.len], tip);
    nid.szTip[tip.len] = 0;
    _ = w32.Shell_NotifyIconW(w32.NIM_ADD, &nid);
    _ = w32.Shell_NotifyIconW(w32.NIM_MODIFY, &nid);
    _ = w32.SetTimer(hwnd, NOTIF_DESKTOP_TIMER_ID, 6000, null);
}
fn tick(self: *App) void {
    self.core_app.tick(self) catch |err| {
        log.err("core app tick error: {}", .{err});
    };
}
fn surfaceWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const surface: *Surface = if (userdata != 0)
        @ptrFromInt(@as(usize, @bitCast(userdata)))
    else
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const is_surface_window = surface.hwnd != null and surface.hwnd.? == hwnd;
    const is_search_popup = surface.search_hwnd != null and surface.search_hwnd.? == hwnd;
    const is_palette_popup = surface.palette_hwnd != null and surface.palette_hwnd.? == hwnd;
    if (!is_surface_window and !is_search_popup and !is_palette_popup)
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        w32.WM_ENTERSIZEMOVE => {
            surface.in_live_resize = true;
            return 0;
        },
        w32.WM_EXITSIZEMOVE => {
            surface.in_live_resize = false;
            return 0;
        },
        w32.WM_SIZE => {
            const width: u32 = @intCast(lparam & 0xFFFF);
            const height: u32 = @intCast((lparam >> 16) & 0xFFFF);
            surface.handleResize(width, height);
            return 0;
        },
        w32.WM_MOVE => {
            if (surface.scrollbar) |sb| _ = sb.repositionAndResize();
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_SHOWWINDOW => {
            if (surface.scrollbar) |sb| sb.setOwnerVisible(wparam != 0);
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_SETTINGCHANGE => {
            if (surface.scrollbar) |sb| {
                if (sb.onSettingsChange()) {
                    const width: u32 = surface.width;
                    const height: u32 = surface.height;
                    const lp_size: isize = @intCast((@as(usize, height) << 16) | @as(usize, width));
                    _ = w32.PostMessageW(hwnd, w32.WM_SIZE, 0, lp_size);
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CLOSE => {
            surface.parent_window.closeSplitSurface(surface);
            return 0;
        },
        w32.WM_DESTROY => {
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            surface.hwnd = null;
            surface.core_surface_ready = false;
            return 0;
        },
        w32.WM_ERASEBKGND => {
            if (surface.app.bg_brush) |brush| {
                const hdc_erase: w32.HDC = @ptrFromInt(wparam);
                var rect: w32.RECT = undefined;
                if (w32.GetClientRect(hwnd, &rect) != 0) {
                    _ = w32.FillRect(hdc_erase, &rect, brush);
                }
            }
            return 1;
        },
        w32.WM_PAINT => {
            if (is_palette_popup) {
                surface.paintPalette(hwnd);
                return 0;
            }
            _ = w32.ValidateRect(hwnd, null);
            if (surface.core_surface_ready) {
                surface.core_surface.renderer_thread.wakeup.notify() catch {};
            }
            return 0;
        },
        w32.WM_DPICHANGED => {
            surface.handleDpiChange();
            return 0;
        },
        w32.WM_KEYDOWN, w32.WM_SYSKEYDOWN => {
            surface.handleKeyEvent(wparam, lparam, .press);
            return 0;
        },
        w32.WM_KEYUP, w32.WM_SYSKEYUP => {
            surface.handleKeyEvent(wparam, lparam, .release);
            return 0;
        },
        w32.WM_SYSCHAR => {
            return 0;
        },
        w32.WM_DEADCHAR, w32.WM_SYSDEADCHAR => {
            return 0;
        },
        w32.WM_CHAR => {
            if (surface.isWin32InputMode()) return 0;
            if (surface.key_event_produced_text) {
                surface.key_event_produced_text = false;
                return 0;
            }
            surface.handleCharEvent(wparam);
            return 0;
        },
        w32.WM_GETOBJECT => {
            if (lparam == w32.OBJID_CLIENT) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_IME_SETCONTEXT => {
            const cleared = lparam & ~w32.ISC_SHOWUICOMPOSITIONWINDOW;
            return w32.DefWindowProcW(hwnd, msg, wparam, cleared);
        },
        w32.WM_IME_STARTCOMPOSITION => {
            surface.handleImeStartComposition();
            return 0;
        },
        w32.WM_IME_COMPOSITION => {
            _ = surface.handleImeComposition(lparam);
            return 0;
        },
        w32.WM_IME_ENDCOMPOSITION => {
            surface.handleImeEndComposition();
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_LBUTTONDOWN => {
            if (is_palette_popup) {
                const y: i32 = @intCast(@as(i16, @truncate((lparam >> 16) & 0xFFFF)));
                const sc = surface.scale;
                const list_top: i32 = @intFromFloat(@round(Surface.PALETTE_LIST_TOP * sc));
                const item_height: i32 = @intFromFloat(@round(Surface.PALETTE_ITEM_HEIGHT * sc));
                if (y >= list_top) {
                    const clicked = @divTrunc(y - list_top, item_height);
                    if (clicked >= 0 and clicked < surface.palette_count) {
                        surface.palette_selected = @intCast(clicked);
                        surface.executePaletteSelection();
                    }
                }
                return 0;
            }
            _ = w32.SetFocus(hwnd);
            surface.handleMouseButton(.left, .press, lparam);
            return 0;
        },
        w32.WM_LBUTTONUP => {
            surface.handleMouseButton(.left, .release, lparam);
            return 0;
        },
        w32.WM_RBUTTONDOWN => {
            _ = w32.SetFocus(hwnd);
            surface.handleMouseButton(.right, .press, lparam);
            return 0;
        },
        w32.WM_RBUTTONUP => {
            surface.handleMouseButton(.right, .release, lparam);
            return 0;
        },
        w32.WM_MBUTTONDOWN => {
            _ = w32.SetFocus(hwnd);
            surface.handleMouseButton(.middle, .press, lparam);
            return 0;
        },
        w32.WM_MBUTTONUP => {
            surface.handleMouseButton(.middle, .release, lparam);
            return 0;
        },
        w32.WM_XBUTTONDOWN => {
            _ = w32.SetFocus(hwnd);
            const btn: input.MouseButton =
                if ((wparam >> 16) & 0xFFFF == w32.XBUTTON2) .five else .four;
            surface.handleMouseButton(btn, .press, lparam);
            return 1;
        },
        w32.WM_XBUTTONUP => {
            const btn: input.MouseButton =
                if ((wparam >> 16) & 0xFFFF == w32.XBUTTON2) .five else .four;
            surface.handleMouseButton(btn, .release, lparam);
            return 1;
        },
        w32.WM_MOUSEMOVE => {
            surface.handleMouseMove(lparam);
            return 0;
        },
        w32.WM_MOUSEWHEEL => {
            surface.handleMouseWheel(wparam, .vertical);
            return 0;
        },
        w32.WM_MOUSEHWHEEL => {
            surface.handleMouseWheel(wparam, .horizontal);
            return 0;
        },
        w32.WM_DROPFILES => {
            surface.handleDropFiles(wparam);
            return 0;
        },
        w32.WM_SETCURSOR => {
            const hit_test: u16 = @intCast(lparam & 0xFFFF);
            if (hit_test == w32.HTCLIENT and surface.handleSetCursor()) {
                return 1;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_COMMAND => {
            const notification: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const control_id: u16 = @intCast(wparam & 0xFFFF);
            if (control_id == Surface.SEARCH_EDIT_ID and notification == w32.EN_CHANGE) {
                surface.handleSearchChange();
                return 0;
            }
            if (control_id == Surface.PALETTE_EDIT_ID and notification == w32.EN_CHANGE) {
                surface.handlePaletteChange();
                return 0;
            }
            if (notification == w32.EN_KILLFOCUS) {
                if (control_id == Surface.PALETTE_EDIT_ID and surface.palette_active) {
                    surface.setCommandPaletteActive(false);
                    return 0;
                }
                if (control_id == Surface.SEARCH_EDIT_ID and surface.search_active) {
                    surface.setSearchActive(false, &[_:0]u8{});
                    return 0;
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CTLCOLOREDIT => {
            const hdc_edit: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc_edit, w32.RGB(220, 220, 220));
            _ = w32.SetBkColor(hdc_edit, if (is_palette_popup) w32.RGB(30, 30, 30) else w32.RGB(45, 45, 45));
            if (is_palette_popup) {
                if (surface.palette_brush) |brush| {
                    return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(brush))));
                }
            }
            if (surface.app.bg_brush) |brush| {
                return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(brush))));
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CTLCOLORSTATIC => {
            const hdc_static: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc_static, w32.RGB(160, 160, 160));
            _ = w32.SetBkColor(hdc_static, w32.RGB(45, 45, 45));
            if (surface.app.bg_brush) |brush| {
                return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(brush))));
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_ACTIVATE => {
            if (is_palette_popup) {
                const activate = @as(u16, @intCast(wparam & 0xFFFF));
                if (activate == 0) {
                    surface.setCommandPaletteActive(false);
                }
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_SETFOCUS => {
            const tab = surface.parent_window.active_tab;
            surface.parent_window.tab_active_surface[tab] = surface;
            surface.handleFocus(true);
            return 0;
        },
        w32.WM_KILLFOCUS => {
            surface.handleFocus(false);
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
fn msgWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const app: *App = @ptrFromInt(@as(usize, @bitCast(userdata)));
    if (msg == WM_APP_WAKEUP) {
        app.tick();
        return 0;
    }
    if (msg == WM_APP_UPDATE_AVAILABLE) {
        if (wparam != 0 and lparam > 0) {
            const ptr: [*]u8 = @ptrFromInt(wparam);
            const len: usize = @intCast(lparam);
            const ver = ptr[0..len];
            defer app.core_app.alloc.free(ver);
            app.showUpdateNotification(ver);
        }
        return 0;
    }
    if (msg == WM_APP_TRAY) {
        const event: u32 = @intCast(lparam & 0xFFFF);
        if (wparam == NOTIF_DESKTOP_UID and event == w32.NIN_BALLOONUSERCLICK) {
            if (app.notif_desktop_surface_id != 0) {
                if (app.core_app.findSurfaceByID(app.notif_desktop_surface_id)) |surface| {
                    _ = app.performAction(
                        .{ .surface = surface },
                        .present_terminal,
                        {},
                    ) catch |err| {
                        log.warn("present_terminal from notification failed err={}", .{err});
                    };
                }
            }
            return 0;
        }
        if (wparam == NOTIF_UPDATE_UID and event == w32.NIN_BALLOONUSERCLICK) {
            var url_buf: [256]u16 = undefined;
            const url_len = std.unicode.utf8ToUtf16Le(&url_buf, RELEASES_URL) catch return 0;
            url_buf[url_len] = 0;
            _ = w32.ShellExecuteW(
                null,
                std.unicode.utf8ToUtf16LeStringLiteral("open"),
                @ptrCast(&url_buf),
                null,
                null,
                w32.SW_SHOW,
            );
        }
        return 0;
    }
    if (msg == w32.WM_TIMER and wparam == QUIT_TIMER_ID) {
        _ = w32.KillTimer(hwnd, QUIT_TIMER_ID);
        app.quit_timer_state = .expired;
        app.quit_requested = true;
        w32.PostQuitMessage(0);
        return 0;
    }
    if (msg == w32.WM_TIMER and wparam == QuickTerminal.ANIM_TIMER_ID) {
        if (app.quick_terminal) |qt| qt.onAnimationTick();
        return 0;
    }
    if (msg == w32.WM_TIMER and
        (wparam == NOTIF_DESKTOP_TIMER_ID or wparam == NOTIF_UPDATE_TIMER_ID))
    {
        const uid: u32 = if (wparam == NOTIF_DESKTOP_TIMER_ID)
            NOTIF_DESKTOP_UID
        else
            NOTIF_UPDATE_UID;
        _ = w32.KillTimer(hwnd, wparam);
        var nid: w32.NOTIFYICONDATAW = std.mem.zeroes(w32.NOTIFYICONDATAW);
        nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
        nid.hWnd = hwnd;
        nid.uID = uid;
        _ = w32.Shell_NotifyIconW(w32.NIM_DELETE, &nid);
        return 0;
    }
    return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
}
test "export terminal IO requires a surface target" {
    var app: App = undefined;
    try std.testing.expect(!app.exportTerminalIo(.app, "test contents"));
}
