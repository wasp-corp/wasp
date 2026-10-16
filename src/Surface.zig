const Surface = @This();
const apprt = @import("root.zig");
pub const Mailbox = apprt.surface.Mailbox;
pub const Message = apprt.surface.Message;
const std = @import("std");
const builtin = @import("builtin");
const assert = @import("quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const global = @import("global.zig");
const oni = @import("oniguruma");
const simd = @import("simd/root.zig");
const crash = @import("crash/main.zig");
const unicode = @import("unicode/root.zig");
const rendererpkg = @import("renderer.zig");
const termio = @import("termio.zig");
const font = @import("font/root.zig");
const Command = @import("Command.zig");
const terminal = @import("terminal/main.zig");
const configpkg = @import("config.zig");
const Duration = configpkg.Config.Duration;
const input = @import("input.zig");
const App = @import("App.zig");
const internal_os = @import("os/root.zig");
const inspectorpkg = @import("inspector/root.zig");
const SurfaceMouse = @import("surface_mouse.zig");
const ProcessInfo = @import("pty.zig").ProcessInfo;
const log = std.log.scoped(.surface);
const Renderer = rendererpkg.Renderer;
pub const min_window_width_cells: u32 = 10;
pub const min_window_height_cells: u32 = 4;
const min_resize_width_cells: u32 = 40;
const min_resize_height_cells: u32 = 10;
const max_active_key_tables = 8;
id: u64,
alloc: Allocator,
app: *App,
rt_app: *apprt.runtime.App,
rt_surface: *apprt.runtime.Surface,
font_grid_key: font.SharedGridSet.Key,
font_size: font.face.DesiredSize,
font_metrics: font.Metrics,
font_size_adjusted: bool,
renderer: Renderer,
renderer_state: rendererpkg.State,
renderer_thread: rendererpkg.Thread,
renderer_thr: std.Thread,
mouse: Mouse,
keyboard: Keyboard,
pressed_key: ?input.KeyEvent = null,
last_binding_trigger: u64 = 0,
io: termio.Termio,
io_thread: termio.Thread,
io_thr: std.Thread,
inspector: ?*inspectorpkg.Inspector = null,
size: rendererpkg.Size,
config: DerivedConfig,
config_conditional_state: configpkg.ConditionalState,
child_exited: bool = false,
focused: bool = true,
visible: bool = true,
selection_scroll_active: bool = false,
readonly: bool = false,
command_timer: ?std.Io.Timestamp = null,
search: ?Search = null,
last_bell_time: ?std.Io.Timestamp = null,
pub const InputEffect = enum {
    ignored,
    consumed,
    closed,
};
const Search = struct {
    state: terminal.search.Thread,
    thread: std.Thread,
    pub fn deinit(self: *Search) void {
        self.state.stop.notify() catch |err| log.err(
            "error notifying search thread to stop, may stall err={}",
            .{err},
        );
        self.thread.join();
        self.state.deinit();
    }
};
const Mouse = struct {
    click_state: [input.MouseButton.max]input.MouseButtonState = @splat(.release),
    mods: input.Mods = .{},
    selection_gesture: terminal.SelectionGesture = .init,
    event_point: ?terminal.point.Coordinate = null,
    pressure_stage: input.MousePressureStage = .none,
    pending_scroll_x: f64 = 0,
    pending_scroll_y: f64 = 0,
    hidden: bool = false,
    over_link: bool = false,
    link_point: ?terminal.point.Coordinate = null,
    fn activeLeftClickPin(self: *const Mouse, screens: *const terminal.ScreenSet) ?*terminal.Pin {
        return self.selection_gesture.validatedLeftClickPin(screens);
    }
};
pub const Keyboard = struct {
    sequence_set: ?*const input.Binding.Set = null,
    sequence_queued: std.ArrayListUnmanaged(termio.Message.WriteReq) = .empty,
    table_stack: std.ArrayListUnmanaged(struct {
        set: *const input.Binding.Set,
        once: bool,
    }) = .empty,
    last_trigger: ?u64 = null,
};
const DerivedConfig = struct {
    arena: ArenaAllocator,
    original_font_size: f32,
    keybind: configpkg.Keybinds,
    abnormal_command_exit_runtime_ms: u32,
    clipboard_read: configpkg.ClipboardAccess,
    clipboard_write: configpkg.ClipboardAccess,
    clipboard_trim_trailing_spaces: bool,
    clipboard_paste_protection: bool,
    clipboard_paste_bracketed_safe: bool,
    clipboard_codepoint_map: configpkg.Config.RepeatableClipboardCodepointMap,
    copy_on_select: configpkg.CopyOnSelect,
    right_click_action: configpkg.RightClickAction,
    middle_click_action: configpkg.MiddleClickAction,
    confirm_close_surface: configpkg.ConfirmCloseSurface,
    cursor_click_to_move: bool,
    desktop_notifications: bool,
    font: font.SharedGridSet.DerivedConfig,
    mouse_interval: u64,
    mouse_hide_while_typing: bool,
    mouse_reporting: bool,
    mouse_scroll_multiplier: configpkg.MouseScrollMultiplier,
    mouse_shift_capture: configpkg.MouseShiftCapture,
    fullscreen: configpkg.Fullscreen,
    macos_non_native_fullscreen: configpkg.NonNativeFullscreen,
    macos_option_as_alt: ?input.OptionAsAlt,
    selection_clear_on_copy: bool,
    selection_clear_on_typing: bool,
    selection_word_chars: []const u21,
    vt_kam_allowed: bool,
    wait_after_command: bool,
    window_padding_top: u32,
    window_padding_bottom: u32,
    window_padding_left: u32,
    window_padding_right: u32,
    window_padding_balance: configpkg.Config.WindowPaddingBalance,
    window_height: u32,
    window_width: u32,
    title: ?[:0]const u8,
    title_report: bool,
    vt_window_resize_allowed: bool,
    links: []DerivedConfig.Link,
    link_osc8: bool,
    link_previews: configpkg.LinkPreviews,
    scroll_to_bottom: configpkg.Config.ScrollToBottom,
    notify_on_command_finish: configpkg.Config.NotifyOnCommandFinish,
    notify_on_command_finish_action: configpkg.Config.NotifyOnCommandFinishAction,
    notify_on_command_finish_after: Duration,
    key_remaps: input.KeyRemapSet,
    const Link = struct {
        regex: oni.Regex,
        action: input.Link.Action,
        highlight: input.Link.Highlight,
    };
    pub fn init(alloc_gpa: Allocator, config: *const configpkg.Config) !DerivedConfig {
        var arena = ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const links = links: {
            var links: std.ArrayList(DerivedConfig.Link) = .empty;
            defer links.deinit(alloc);
            for (config.link.links.items) |link| {
                var regex = try link.oniRegex();
                errdefer regex.deinit();
                try links.append(alloc, .{
                    .regex = regex,
                    .action = link.action,
                    .highlight = link.highlight,
                });
            }
            break :links try links.toOwnedSlice(alloc);
        };
        errdefer {
            for (links) |*link| link.regex.deinit();
            alloc.free(links);
        }
        return .{
            .original_font_size = config.@"font-size",
            .keybind = try config.keybind.clone(alloc),
            .abnormal_command_exit_runtime_ms = config.@"abnormal-command-exit-runtime",
            .clipboard_read = config.@"clipboard-read",
            .clipboard_write = config.@"clipboard-write",
            .clipboard_trim_trailing_spaces = config.@"clipboard-trim-trailing-spaces",
            .clipboard_paste_protection = config.@"clipboard-paste-protection",
            .clipboard_paste_bracketed_safe = config.@"clipboard-paste-bracketed-safe",
            .clipboard_codepoint_map = try config.@"clipboard-codepoint-map".clone(alloc),
            .copy_on_select = config.@"copy-on-select",
            .right_click_action = config.@"right-click-action",
            .middle_click_action = config.@"middle-click-action",
            .confirm_close_surface = config.@"confirm-close-surface",
            .cursor_click_to_move = config.@"cursor-click-to-move",
            .desktop_notifications = config.@"desktop-notifications",
            .font = try font.SharedGridSet.DerivedConfig.init(alloc, config),
            .mouse_interval = config.@"click-repeat-interval" * 1_000_000,
            .mouse_hide_while_typing = config.@"mouse-hide-while-typing",
            .mouse_reporting = config.@"mouse-reporting",
            .mouse_scroll_multiplier = config.@"mouse-scroll-multiplier",
            .mouse_shift_capture = config.@"mouse-shift-capture",
            .fullscreen = config.fullscreen,
            .macos_non_native_fullscreen = config.@"macos-non-native-fullscreen",
            .macos_option_as_alt = config.@"macos-option-as-alt",
            .selection_clear_on_copy = config.@"selection-clear-on-copy",
            .selection_clear_on_typing = config.@"selection-clear-on-typing",
            .selection_word_chars = try alloc.dupe(u21, config.@"selection-word-chars".codepoints),
            .vt_kam_allowed = config.@"vt-kam-allowed",
            .wait_after_command = config.@"wait-after-command",
            .window_padding_top = config.@"window-padding-y".top_left,
            .window_padding_bottom = config.@"window-padding-y".bottom_right,
            .window_padding_left = config.@"window-padding-x".top_left,
            .window_padding_right = config.@"window-padding-x".bottom_right,
            .window_padding_balance = config.@"window-padding-balance",
            .window_height = config.@"window-height",
            .window_width = config.@"window-width",
            .title = config.title,
            .title_report = config.@"title-report",
            .vt_window_resize_allowed = config.@"vt-window-resize-allowed",
            .links = links,
            .link_osc8 = config.@"link-osc8",
            .link_previews = config.@"link-previews",
            .scroll_to_bottom = config.@"scroll-to-bottom",
            .notify_on_command_finish = config.@"notify-on-command-finish",
            .notify_on_command_finish_action = config.@"notify-on-command-finish-action",
            .notify_on_command_finish_after = config.@"notify-on-command-finish-after",
            .key_remaps = try config.@"key-remap".clone(alloc),
            .arena = arena,
        };
    }
    pub fn deinit(self: *DerivedConfig) void {
        for (self.links) |*link| link.regex.deinit();
        self.arena.deinit();
    }
    fn scaledPadding(self: *const DerivedConfig, x_dpi: f32, y_dpi: f32) rendererpkg.Padding {
        const padding_top: u32 = padding_top: {
            const padding_top: f32 = @floatFromInt(self.window_padding_top);
            break :padding_top @intFromFloat(@floor(padding_top * y_dpi / 72));
        };
        const padding_bottom: u32 = padding_bottom: {
            const padding_bottom: f32 = @floatFromInt(self.window_padding_bottom);
            break :padding_bottom @intFromFloat(@floor(padding_bottom * y_dpi / 72));
        };
        const padding_left: u32 = padding_left: {
            const padding_left: f32 = @floatFromInt(self.window_padding_left);
            break :padding_left @intFromFloat(@floor(padding_left * x_dpi / 72));
        };
        const padding_right: u32 = padding_right: {
            const padding_right: f32 = @floatFromInt(self.window_padding_right);
            break :padding_right @intFromFloat(@floor(padding_right * x_dpi / 72));
        };
        return .{
            .top = padding_top,
            .bottom = padding_bottom,
            .left = padding_left,
            .right = padding_right,
        };
    }
};
pub fn init(
    self: *Surface,
    alloc: Allocator,
    config_original: *const configpkg.Config,
    app: *App,
    rt_app: *apprt.runtime.App,
    rt_surface: *apprt.runtime.Surface,
) !void {
    var config_: ?configpkg.Config = config_original.changeConditionalState(
        app.config_conditional_state,
    ) catch |err| err: {
        log.warn("failed to apply conditional state to config err={}", .{err});
        break :err null;
    };
    defer if (config_) |*c| c.deinit();
    const config: *const configpkg.Config = if (config_) |*c| config: {
        c.@"working-directory" = config_original.@"working-directory";
        break :config c;
    } else config_original;
    var derived_config = try DerivedConfig.init(alloc, config);
    errdefer derived_config.deinit();
    const content_scale = try rt_surface.getContentScale();
    const x_dpi = content_scale.x * font.face.default_dpi;
    const y_dpi = content_scale.y * font.face.default_dpi;
    log.debug("xscale={} yscale={} xdpi={} ydpi={}", .{
        content_scale.x,
        content_scale.y,
        x_dpi,
        y_dpi,
    });
    const font_size: font.face.DesiredSize = .{
        .points = config.@"font-size",
        .xdpi = @intFromFloat(@round(x_dpi)),
        .ydpi = @intFromFloat(@round(y_dpi)),
    };
    const font_grid_key, const font_grid = try app.font_grid_set.ref(
        &derived_config.font,
        font_size,
    );
    const size: rendererpkg.Size = size: {
        var size: rendererpkg.Size = .{
            .screen = screen: {
                const surface_size = try rt_surface.getSize();
                break :screen .{
                    .width = surface_size.width,
                    .height = surface_size.height,
                };
            },
            .cell = font_grid.cellSize(),
            .padding = .{},
        };
        const explicit: rendererpkg.Padding = derived_config.scaledPadding(
            x_dpi,
            y_dpi,
        );
        if (derived_config.window_padding_balance != .false) {
            size.balancePadding(explicit, derived_config.window_padding_balance);
        } else {
            size.padding = explicit;
        }
        break :size size;
    };
    const render_device = app.device orelse device: {
        const device_options = try rt_surface.renderDeviceOptions();
        const device: *rendererpkg.Device = try .init(alloc, device_options);
        app.device = device;
        break :device device;
    };
    const app_mailbox: App.Mailbox = .{ .rt_app = rt_app, .mailbox = &app.mailbox };
    var renderer_impl = try Renderer.init(alloc, .{
        .device = render_device,
        .config = try .init(alloc, config),
        .font_grid = font_grid,
        .size = size,
        .surface_mailbox = .{ .surface = self, .app = app_mailbox },
        .rt_surface = rt_surface,
        .thread = &self.renderer_thread,
    });
    errdefer renderer_impl.deinit();
    const mutex = try alloc.create(std.Io.Mutex);
    mutex.* = .init;
    errdefer alloc.destroy(mutex);
    var render_thread = try rendererpkg.Thread.init(
        alloc,
        config,
        rt_surface,
        &self.renderer,
        &self.renderer_state,
    );
    errdefer render_thread.deinit();
    var io_thread = try termio.Thread.init(alloc);
    errdefer io_thread.deinit();
    self.* = .{
        .id = id: {
            while (true) {
                const candidate = candidate: {
                    const rng_impl: std.Random.IoSource = .{ .io = global.io() };
                    const rng = rng_impl.interface();
                    break :candidate rng.int(u64);
                };
                if (candidate == 0) continue;
                break :id candidate;
            }
        },
        .alloc = alloc,
        .app = app,
        .rt_app = rt_app,
        .rt_surface = rt_surface,
        .font_grid_key = font_grid_key,
        .font_size = font_size,
        .font_size_adjusted = false,
        .font_metrics = font_grid.metrics,
        .renderer = renderer_impl,
        .renderer_thread = render_thread,
        .renderer_state = .{
            .mutex = mutex,
            .terminal = &self.io.terminal,
        },
        .renderer_thr = undefined,
        .mouse = .{},
        .keyboard = .{},
        .io = undefined,
        .io_thread = io_thread,
        .io_thr = undefined,
        .size = size,
        .config = derived_config,
        .config_conditional_state = app.config_conditional_state,
    };
    const command: ?configpkg.Command = command: {
        if (app.first) {
            if (config.@"initial-command") |command| {
                break :command command;
            }
        }
        break :command config.command;
    };
    {
        var env = rt_surface.defaultTermioEnv() catch |err| env: {
            log.warn("error getting env map for surface err={}", .{err});
            break :env global.environMap() catch std.process.Environ.Map.init(alloc);
        };
        errdefer env.deinit();
        _ = env.orderedRemove("WASP_LOG");
        var buf: [18]u8 = undefined;
        try env.put(
            "WASP_SURFACE_ID",
            std.fmt.bufPrint(&buf, "0x{x:0>16}", .{self.id}) catch unreachable,
        );
        var io_exec = try termio.Exec.init(alloc, .{
            .command = command,
            .env = env,
            .env_override = config.env,
            .shell_integration = config.@"shell-integration",
            .shell_integration_features = config.@"shell-integration-features",
            .cursor_blink = config.@"cursor-style-blink",
            .working_directory = if (config.@"working-directory") |wd| wd.value() else null,
            .resources_dir = global.resourcesDir().host(),
            .term = config.term,
            .rt_pre_exec_info = .init(config),
            .rt_post_fork_info = .init(config),
        });
        errdefer io_exec.deinit();
        var io_mailbox = try termio.Mailbox.initSPSC(alloc);
        errdefer io_mailbox.deinit(alloc);
        try termio.Termio.init(&self.io, alloc, .{
            .size = size,
            .full_config = config,
            .config = try termio.Termio.DerivedConfig.init(alloc, config),
            .backend = .{ .exec = io_exec },
            .mailbox = io_mailbox,
            .renderer_state = &self.renderer_state,
            .renderer_wakeup = render_thread.wakeup,
            .renderer_mailbox = render_thread.mailbox,
            .surface_mailbox = .{ .surface = self, .app = app_mailbox },
        });
    }
    errdefer self.io.deinit();
    _ = try rt_app.performAction(
        .{ .surface = self },
        .cell_size,
        .{ .width = size.cell.width, .height = size.cell.height },
    );
    _ = try rt_app.performAction(
        .{ .surface = self },
        .size_limit,
        .{
            .min_width = size.cell.width * min_window_width_cells,
            .min_height = size.cell.height * min_window_height_cells,
            .max_width = 0,
            .max_height = 0,
        },
    );
    try self.resize(self.size.screen);
    self.renderer_thr = try std.Thread.spawn(
        .{},
        rendererpkg.Thread.threadMain,
        .{&self.renderer_thread},
    );
    self.renderer_thr.setName(global.io(), "renderer") catch {};
    self.io_thr = try std.Thread.spawn(
        .{},
        termio.Thread.threadMain,
        .{ &self.io_thread, &self.io },
    );
    self.io_thr.setName(global.io(), "io") catch {};
    self.recomputeInitialSize() catch |err| {
        log.warn("unable to set initial window size: {}", .{err});
    };
    if (config.title) |title| {
        _ = try rt_app.performAction(
            .{ .surface = self },
            .set_title,
            .{ .title = title },
        );
    } else if ((comptime builtin.os.tag == .linux) and
        config.@"_xdg-terminal-exec")
    xdg: {
        const v = command orelse break :xdg;
        const title = v.string(alloc) catch |err| {
            log.warn(
                "error copying command for title, title will not be set err={}",
                .{err},
            );
            break :xdg;
        };
        defer alloc.free(title);
        _ = try rt_app.performAction(
            .{ .surface = self },
            .set_title,
            .{ .title = title },
        );
    } else if (command) |cmd| switch (cmd) {
        .direct => |cmd_str| if (cmd_str.len != 0) {
            _ = try rt_app.performAction(
                .{ .surface = self },
                .set_title,
                .{ .title = cmd_str[0] },
            );
        },
        .shell => {},
    };
    app.first = false;
}
pub fn deinit(self: *Surface) void {
    if (self.search) |*s| s.deinit();
    {
        self.renderer_thread.stop.notify() catch |err|
            log.err("error notifying renderer thread to stop, may stall err={}", .{err});
        self.renderer_thr.join();
    }
    {
        self.io_thread.stop.notify() catch |err|
            log.err("error notifying io thread to stop, may stall err={}", .{err});
        self.io_thr.join();
    }
    self.renderer.deinit();
    self.renderer_thread.deinit();
    self.io_thread.deinit();
    self.mouse.selection_gesture.deinit(&self.io.terminal);
    self.io.deinit();
    if (self.inspector) |v| {
        v.deinit(self.alloc);
        self.alloc.destroy(v);
    }
    for (self.keyboard.sequence_queued.items) |req| req.deinit();
    self.keyboard.sequence_queued.deinit(self.alloc);
    self.keyboard.table_stack.deinit(self.alloc);
    self.app.font_grid_set.deref(self.font_grid_key);
    if (self.renderer_state.preedit) |p| self.alloc.free(p.codepoints);
    self.alloc.destroy(self.renderer_state.mutex);
    self.config.deinit();
    log.info("surface closed id={x}", .{self.id});
}
pub fn close(self: *Surface) void {
    self.rt_surface.close(self.needsConfirmQuit());
}
inline fn surfaceMailbox(self: *Surface) Mailbox {
    return .{
        .surface = self,
        .app = .{ .rt_app = self.rt_app, .mailbox = &self.app.mailbox },
    };
}
fn queueIo(
    self: *Surface,
    msg: termio.Message,
    mutex: termio.Termio.MutexState,
) void {
    if (self.readonly) {
        switch (msg) {
            .write_small,
            .write_stable,
            .write_alloc,
            => {
                msg.deinit();
                return;
            },
            else => {},
        }
    }
    self.io.queueMessage(msg, mutex);
}
pub fn draw(self: *Surface) !void {
    try self.renderer.drawFrame(true);
}
pub fn activateInspector(self: *Surface) !void {
    if (self.inspector != null) return;
    const ptr = try self.alloc.create(inspectorpkg.Inspector);
    errdefer self.alloc.destroy(ptr);
    ptr.* = try inspectorpkg.Inspector.init(self.alloc);
    errdefer ptr.deinit(self.alloc);
    self.inspector = ptr;
    errdefer self.inspector = null;
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        assert(self.renderer_state.inspector == null);
        self.renderer_state.inspector = self.inspector;
    }
    _ = self.renderer_thread.mailbox.push(global.io(), .{ .inspector = true }, .{ .forever = {} });
    self.queueIo(.{ .inspector = true }, .unlocked);
}
pub fn reportPresentationHealth(self: *Surface, health: rendererpkg.Health) void {
    _ = self.renderer_thread.mailbox.push(
        global.io(),
        .{ .presentation_health = health },
        .forever,
    );
    self.renderer_thread.wakeup.notify() catch |err|
        log.warn("failed to wake up renderer err={}", .{err});
}
pub fn deactivateInspector(self: *Surface) void {
    const insp = self.inspector orelse return;
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        assert(self.renderer_state.inspector != null);
        self.renderer_state.inspector = null;
    }
    _ = self.renderer_thread.mailbox.push(global.io(), .{ .inspector = false }, .{ .forever = {} });
    self.queueIo(.{ .inspector = false }, .unlocked);
    insp.deinit(self.alloc);
    self.alloc.destroy(insp);
    self.inspector = null;
}
pub fn needsConfirmQuit(self: *Surface) bool {
    if (self.readonly) return true;
    if (self.child_exited) return false;
    return switch (self.config.confirm_close_surface) {
        .always => true,
        .false => false,
        .true => true: {
            self.renderer_state.mutex.lockUncancelable(global.io());
            defer self.renderer_state.mutex.unlock(global.io());
            break :true !self.io.terminal.cursorIsAtPrompt();
        },
    };
}
pub fn handleMessage(self: *Surface, msg: Message) !void {
    switch (msg) {
        .change_config => |config| try self.updateConfig(config),
        .set_title => |*v| {
            if (self.config.title != null) {
                log.debug("ignoring title change request since static title is set via config", .{});
                return;
            }
            const slice = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(v)), 0);
            log.debug("changing title \"{s}\"", .{slice});
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .set_title,
                .{ .title = slice },
            );
        },
        .report_title => |style| report_title: {
            if (!self.config.title_report) {
                log.info("report_title requested, but disabled via config", .{});
                break :report_title;
            }
            const title: ?[:0]const u8 = self.rt_surface.getTitle();
            const data = switch (style) {
                .csi_21_t => try std.fmt.allocPrint(
                    self.alloc,
                    "\x1b]l{s}\x1b\\",
                    .{title orelse ""},
                ),
            };
            self.queueIo(.{
                .write_alloc = .{
                    .alloc = self.alloc,
                    .data = data,
                },
            }, .unlocked);
        },
        .resize_window => |size| try self.resizeWindow(size),
        .color_change => |change| color_change: {
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .color_change,
                .{
                    .kind = switch (change.target) {
                        .palette => |v| @enumFromInt(v),
                        .dynamic => |dyn| switch (dyn) {
                            .foreground => .foreground,
                            .background => .background,
                            .cursor => .cursor,
                            else => break :color_change,
                        },
                        .special => break :color_change,
                    },
                    .r = change.color.r,
                    .g = change.color.g,
                    .b = change.color.b,
                },
            );
        },
        .set_mouse_shape => |shape| {
            log.debug("changing mouse shape: {}", .{shape});
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .mouse_shape,
                shape,
            );
        },
        .clipboard_read => |clipboard| {
            if (self.config.clipboard_read == .deny) {
                log.info("application attempted to read clipboard, but 'clipboard-read' is set to deny", .{});
                return;
            }
            _ = try self.startClipboardRequest(.standard, .{ .osc_52_read = clipboard });
        },
        .kitty_clipboard_read => |req| try self.kittyClipboardRead(req),
        .kitty_clipboard_write => |req| try self.kittyClipboardWrite(req),
        .clipboard_write => |w| switch (w.req) {
            .small => |v| try self.clipboardWrite(v.data[0..v.len], w.clipboard_type),
            .stable => |v| try self.clipboardWrite(v, w.clipboard_type),
            .alloc => |v| {
                defer v.alloc.free(v.data);
                try self.clipboardWrite(v.data, w.clipboard_type);
            },
        },
        .pwd_change => |w| {
            defer w.deinit();
            var stack = std.heap.stackFallback(256, self.alloc);
            const alloc = stack.get();
            const str = try alloc.dupeZ(u8, w.slice());
            defer alloc.free(str);
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .pwd,
                .{ .pwd = str },
            );
        },
        .close => self.close(),
        .child_exited => |v| self.childExited(v),
        .desktop_notification => |notification| {
            if (!self.config.desktop_notifications) {
                log.info("application attempted to display a desktop notification, but 'desktop-notifications' is disabled", .{});
                return;
            }
            const title = std.mem.sliceTo(&notification.title, 0);
            const body = std.mem.sliceTo(&notification.body, 0);
            try self.showDesktopNotification(title, body);
        },
        .redraw => self.redraw(),
        .renderer_health => |health| self.updateRendererHealth(health),
        .scrollbar => |scrollbar| self.updateScrollbar(scrollbar),
        .present_surface => try self.presentSurface(),
        .password_input => |v| try self.passwordInput(v),
        .ring_bell => bell: {
            const now: std.Io.Timestamp = .now(global.io(), .awake);
            if (self.last_bell_time) |last| {
                if (last.durationTo(now).toMilliseconds() < 100) break :bell;
            }
            self.last_bell_time = now;
            _ = self.rt_app.performAction(
                .{ .surface = self },
                .ring_bell,
                {},
            ) catch |err| {
                log.warn("apprt failed to ring bell={}", .{err});
            };
        },
        .progress_report => |v| {
            _ = self.rt_app.performAction(
                .{ .surface = self },
                .progress_report,
                v,
            ) catch |err| {
                log.warn("apprt failed to report progress err={}", .{err});
            };
        },
        .selection_scroll_tick => |active| {
            self.selection_scroll_active = active;
            try self.selectionScrollTick();
        },
        .start_command => {
            self.command_timer = .now(global.io(), .awake);
        },
        .stop_command => |v| timer: {
            const end: std.Io.Timestamp = .now(global.io(), .awake);
            const start = self.command_timer orelse break :timer;
            self.command_timer = null;
            const duration_raw = start.durationTo(end).nanoseconds;
            assert(duration_raw >= 0 and duration_raw <= std.math.maxInt(u64));
            const duration: Duration = .{
                .duration = @as(
                    u64,
                    @intCast(std.math.clamp(start.durationTo(end).nanoseconds, 0, std.math.maxInt(u64))),
                ),
            };
            log.debug("command took {f}", .{duration});
            _ = self.rt_app.performAction(
                .{ .surface = self },
                .command_finished,
                .{
                    .exit_code = v,
                    .duration = duration,
                },
            ) catch |err| {
                log.warn("apprt failed to notify command finish={}", .{err});
            };
        },
        .search_total => |v| {
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .search_total,
                .{ .total = v },
            );
        },
        .search_selected => |v| {
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .search_selected,
                .{ .selected = v },
            );
        },
    }
}
fn selectionScrollTick(self: *Surface) !void {
    if (!self.selection_scroll_active) return;
    const was_autoscrolling = self.mouse.selection_gesture.left_drag_autoscroll != .none;
    if (!was_autoscrolling) {
        self.queueIo(
            .{ .selection_scroll = false },
            .unlocked,
        );
        return;
    }
    const pos = try self.rt_surface.getCursorPos();
    const pos_vp = self.posToViewport(pos.x, pos.y);
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    const t: *terminal.Terminal = self.renderer_state.terminal;
    const selection = self.mouse.selection_gesture.autoscrollTick(t, .{
        .viewport = pos_vp,
        .xpos = pos.x,
        .ypos = pos.y,
        .rectangle = SurfaceMouse.isRectangleSelectState(self.mouse.mods),
        .word_boundary_codepoints = self.config.selection_word_chars,
        .geometry = .{
            .columns = @intCast(self.size.grid().columns),
            .cell_width = self.size.cell.width,
            .padding_left = self.size.padding.left,
            .screen_height = self.size.screen.height,
        },
    });
    if (self.mouse.selection_gesture.left_drag_autoscroll == .none) {
        self.queueIo(
            .{ .selection_scroll = false },
            .locked,
        );
    }
    if (self.mouse.selection_gesture.left_click_count == 0) return;
    try self.setSelection(selection);
    try self.queueRender();
}
fn childExited(self: *Surface, info: apprt.surface.Message.ChildExited) void {
    self.child_exited = true;
    if (info.runtime_ms <= self.config.abnormal_command_exit_runtime_ms) runtime: {
        if (comptime !builtin.target.os.tag.isDarwin()) {
            if (info.exit_code == 0) break :runtime;
        }
        log.warn("abnormal process exit detected, showing error message", .{});
        if (self.rt_app.performAction(
            .{ .surface = self },
            .show_child_exited,
            info,
        ) catch |err| gui: {
            log.err("error trying to show native child exited GUI err={}", .{err});
            break :gui false;
        }) return;
        self.childExitedAbnormally(info) catch |err| {
            log.err("error handling abnormal child exit err={}", .{err});
            return;
        };
        return;
    }
    terminal: {
        if (self.rt_app.performAction(
            .{ .surface = self },
            .show_child_exited,
            info,
        ) catch |err| gui: {
            log.err("error trying to show native child exited GUI err={}", .{err});
            break :gui false;
        }) break :terminal;
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        const t: *terminal.Terminal = self.renderer_state.terminal;
        t.carriageReturn();
        t.linefeed() catch break :terminal;
        t.printString("Process exited. Press any key to close the terminal.") catch
            break :terminal;
        t.modes.set(.cursor_visible, false);
        t.modes.set(.disable_keyboard, false);
        t.screens.active.kitty_keyboard.set(.set, .disabled);
    }
    if (self.config.wait_after_command) return;
    self.close();
}
fn childExitedAbnormally(
    self: *Surface,
    info: apprt.surface.Message.ChildExited,
) !void {
    var arena = ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const command = try std.mem.join(alloc, " ", switch (self.io.backend) {
        .exec => |*exec| exec.subprocess.args,
    });
    const runtime_str = try std.fmt.allocPrint(alloc, "{d} ms", .{info.runtime_ms});
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    const t: *terminal.Terminal = self.renderer_state.terminal;
    t.carriageReturn();
    try t.setAttribute(.{ .unset = {} });
    const viewport_str = try t.plainString(alloc);
    if (viewport_str.len > 0) {
        try t.linefeed();
        for (0..t.cols) |_| try t.print(0x2501);
        t.carriageReturn();
        try t.linefeed();
        try t.linefeed();
    }
    try t.setAttribute(.{ .@"8_fg" = .bright_red });
    try t.setAttribute(.{ .bold = {} });
    try t.printString("Wasp failed to launch the requested command:");
    try t.setAttribute(.{ .unset = {} });
    t.carriageReturn();
    try t.linefeed();
    try t.linefeed();
    try t.printString(command);
    try t.setAttribute(.{ .unset = {} });
    t.carriageReturn();
    try t.linefeed();
    try t.linefeed();
    try t.printString("Runtime: ");
    try t.setAttribute(.{ .@"8_fg" = .red });
    try t.printString(runtime_str);
    try t.setAttribute(.{ .unset = {} });
    if (comptime !builtin.target.os.tag.isDarwin()) {
        const exit_code_str = try std.fmt.allocPrint(alloc, "{d}", .{info.exit_code});
        t.carriageReturn();
        try t.linefeed();
        try t.printString("Exit Code: ");
        try t.setAttribute(.{ .@"8_fg" = .red });
        try t.printString(exit_code_str);
        try t.setAttribute(.{ .unset = {} });
    }
    t.carriageReturn();
    try t.linefeed();
    try t.linefeed();
    try t.printString("Press any key to close the window.");
    t.modes.set(.cursor_visible, false);
}
fn passwordInput(self: *Surface, v: bool) !void {
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        const old = self.io.terminal.flags.password_input;
        if (old == v) return;
        self.io.terminal.flags.password_input = v;
    }
    _ = self.rt_app.performAction(
        .{ .surface = self },
        .secure_input,
        if (v) .on else .off,
    ) catch |err| {
        log.warn("apprt failed to set secure input state err={}", .{err});
    };
    try self.queueRender();
}
fn searchCallback(event: terminal.search.Thread.Event, ud: ?*anyopaque) void {
    const self: *Surface = @ptrCast(@alignCast(ud.?));
    self.searchCallback_(event) catch |err| {
        log.warn("error in search callback err={}", .{err});
    };
}
fn searchCallback_(
    self: *Surface,
    event: terminal.search.Thread.Event,
) !void {
    switch (event) {
        .viewport_matches => |matches_unowned| {
            var arena: ArenaAllocator = .init(self.alloc);
            errdefer arena.deinit();
            const alloc = arena.allocator();
            const matches = try alloc.dupe(terminal.highlight.Flattened, matches_unowned);
            for (matches) |*m| m.* = try m.clone(alloc);
            _ = self.renderer_thread.mailbox.push(
                global.io(),
                .{ .search_viewport_matches = .{
                    .arena = arena,
                    .matches = matches,
                } },
                .forever,
            );
            try self.renderer_thread.wakeup.notify();
        },
        .selected_match => |selected_| {
            if (selected_) |sel| {
                var arena: ArenaAllocator = .init(self.alloc);
                errdefer arena.deinit();
                const alloc = arena.allocator();
                const match = try sel.highlight.clone(alloc);
                _ = self.renderer_thread.mailbox.push(
                    global.io(),
                    .{ .search_selected_match = .{
                        .arena = arena,
                        .match = match,
                    } },
                    .forever,
                );
                _ = self.surfaceMailbox().push(
                    .{ .search_selected = sel.idx },
                    .forever,
                );
            } else {
                _ = self.renderer_thread.mailbox.push(
                    global.io(),
                    .{ .search_selected_match = null },
                    .forever,
                );
                _ = self.surfaceMailbox().push(
                    .{ .search_selected = null },
                    .forever,
                );
            }
            try self.renderer_thread.wakeup.notify();
        },
        .total_matches => |total| {
            _ = self.surfaceMailbox().push(
                .{ .search_total = total },
                .forever,
            );
        },
        .quit => {
            _ = self.renderer_thread.mailbox.push(
                global.io(),
                .{ .search_selected_match = null },
                .forever,
            );
            _ = self.renderer_thread.mailbox.push(
                global.io(),
                .{ .search_viewport_matches = .{
                    .arena = .init(self.alloc),
                    .matches = &.{},
                } },
                .forever,
            );
            try self.renderer_thread.wakeup.notify();
            _ = self.surfaceMailbox().push(
                .{ .search_total = null },
                .forever,
            );
            _ = self.surfaceMailbox().push(
                .{ .search_selected = null },
                .forever,
            );
        },
        .complete => {},
    }
}
fn modsChanged(self: *Surface, mods: input.Mods) void {
    if (!self.mouse.mods.equal(mods)) {
        self.mouse.mods = mods.binding();
        {
            self.renderer_state.mutex.lockUncancelable(global.io());
            defer self.renderer_state.mutex.unlock(global.io());
            self.renderer_state.mouse.mods = self.mouseModsWithCapture(self.mouse.mods);
            self.renderer_state.terminal.flags.dirty.clear = true;
        }
        self.queueRender() catch |err| {
            log.warn("failed to notify renderer of mods change err={}", .{err});
        };
    }
}
fn mouseRefreshLinks(
    self: *Surface,
    pos: apprt.CursorPos,
    pos_vp: terminal.point.Coordinate,
    over_link: bool,
) !void {
    if (pos.x < 0 or pos.y < 0) return;
    self.mouse.link_point = pos_vp;
    var arena = ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const link_: ?apprt.action.MouseOverLink, const preview: bool = link: {
        const left_idx = @intFromEnum(input.MouseButton.left);
        if (self.mouse.click_state[left_idx] == .press) click: {
            const pin = self.mouse.activeLeftClickPin(&self.io.terminal.screens) orelse break :click;
            const click_pt = self.io.terminal.screens.active.pages.pointFromPin(
                .viewport,
                pin.*,
            ) orelse break :click;
            if (!click_pt.coord().eql(pos_vp)) {
                log.debug("mouse moved while left click held, ignoring link hover", .{});
                break :link .{ null, false };
            }
        }
        const link = (try self.linkAtPos(pos)) orelse break :link .{ null, false };
        switch (link.action) {
            .open => {
                const str = try self.io.terminal.screens.active.selectionString(alloc, .{
                    .sel = link.selection,
                    .trim = false,
                });
                break :link .{
                    .{ .url = str },
                    self.config.link_previews == .true,
                };
            },
            ._open_osc8 => {
                const pin = link.selection.start();
                const uri = self.osc8URI(pin) orelse {
                    log.warn("failed to get URI for OSC8 hyperlink", .{});
                    break :link .{ null, false };
                };
                break :link .{
                    .{ .url = try alloc.dupeZ(u8, uri) },
                    self.config.link_previews != .false,
                };
            },
        }
    };
    if (link_) |link| {
        self.renderer_state.mouse.point = pos_vp;
        self.mouse.over_link = true;
        self.renderer_state.terminal.screens.active.dirty.hyperlink_hover = true;
        _ = try self.rt_app.performAction(
            .{ .surface = self },
            .mouse_shape,
            .pointer,
        );
        if (preview) {
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .mouse_over_link,
                link,
            );
        }
        try self.queueRender();
        return;
    }
    if (over_link) {
        _ = try self.rt_app.performAction(
            .{ .surface = self },
            .mouse_shape,
            self.io.terminal.mouse_shape,
        );
        _ = try self.rt_app.performAction(
            .{ .surface = self },
            .mouse_over_link,
            .{ .url = "" },
        );
        try self.queueRender();
        return;
    }
}
fn updateRendererHealth(self: *Surface, health: rendererpkg.Health) void {
    log.warn("renderer health status change status={}", .{health});
    _ = self.rt_app.performAction(
        .{ .surface = self },
        .renderer_health,
        health,
    ) catch |err| {
        log.warn("failed to notify app of renderer health change err={}", .{err});
    };
}
fn updateScrollbar(self: *Surface, scrollbar: terminal.Scrollbar) void {
    _ = self.rt_app.performAction(
        .{ .surface = self },
        .scrollbar,
        scrollbar,
    ) catch |err| {
        log.warn("failed to notify app of scrollbar change err={}", .{err});
    };
}
fn redraw(self: *Surface) void {
    _ = self.rt_app.performAction(
        .{ .surface = self },
        .render,
        {},
    ) catch |err| {
        log.warn("failed to notify app of frame present err={}", .{err});
    };
}
fn notifyConfigConditionalState(self: *Surface) void {
    _ = self.rt_app.performAction(
        .{ .surface = self },
        .reload_config,
        .{ .soft = true },
    ) catch |err| {
        log.warn("failed to notify app of config state change err={}", .{err});
    };
}
pub fn updateConfig(
    self: *Surface,
    original: *const configpkg.Config,
) !void {
    var config_: ?configpkg.Config = original.changeConditionalState(
        self.config_conditional_state,
    ) catch |err| err: {
        log.warn("failed to apply conditional state to config err={}", .{err});
        break :err null;
    };
    defer if (config_) |*c| c.deinit();
    const config: *const configpkg.Config = if (config_) |*c| c else original;
    const derived = DerivedConfig.init(self.alloc, config) catch |err| {
        log.err("error updating configuration err={}", .{err});
        return;
    };
    self.config.deinit();
    self.config = derived;
    if (!self.config.mouse_hide_while_typing and self.mouse.hidden) {
        self.showMouse();
    }
    self.endKeySequence(.drop, .free);
    _ = self.deactivateAllKeyTables() catch |err| {
        log.warn("failed to deactivate key tables err={}", .{err});
    };
    try self.setFontSize(font_size: {
        if (self.font_size_adjusted) {
            log.info("font size manually adjusted, preserving previous size on config reload", .{});
            break :font_size self.font_size;
        }
        var size = self.font_size;
        size.points = std.math.clamp(config.@"font-size", 1.0, 255.0);
        break :font_size size;
    });
    var renderer_message = try rendererpkg.Message.initChangeConfig(self.alloc, config);
    errdefer renderer_message.deinit();
    var termio_config_ptr = try self.alloc.create(termio.Termio.DerivedConfig);
    errdefer self.alloc.destroy(termio_config_ptr);
    termio_config_ptr.* = try termio.Termio.DerivedConfig.init(self.alloc, config);
    errdefer termio_config_ptr.deinit();
    _ = self.renderer_thread.mailbox.push(global.io(), renderer_message, .{ .forever = {} });
    self.queueIo(.{
        .change_config = .{
            .alloc = self.alloc,
            .ptr = termio_config_ptr,
        },
    }, .unlocked);
    self.queueRender() catch |err| {
        log.warn("failed to notify renderer of config change err={}", .{err});
    };
    if (config.title) |title| _ = try self.rt_app.performAction(
        .{ .surface = self },
        .set_title,
        .{ .title = title },
    );
    _ = try self.rt_app.performAction(
        .{ .surface = self },
        .config_change,
        .{ .config = config },
    );
}
const InitialSizeError = error{
    ContentScaleUnavailable,
    AppActionFailed,
};
fn recomputeInitialSize(
    self: *Surface,
) InitialSizeError!void {
    if (self.config.window_height <= 0 or
        self.config.window_width <= 0) return;
    const scale = self.rt_surface.getContentScale() catch
        return error.ContentScaleUnavailable;
    const height = @max(
        self.config.window_height,
        min_window_height_cells,
    ) * self.size.cell.height;
    const width = @max(
        self.config.window_width,
        min_window_width_cells,
    ) * self.size.cell.width;
    const width_f32: f32 = @floatFromInt(width);
    const height_f32: f32 = @floatFromInt(height);
    const final_width: u32 =
        @as(u32, @intFromFloat(@ceil(width_f32 / scale.x))) +
        self.size.padding.left +
        self.size.padding.right;
    const final_height: u32 =
        @as(u32, @intFromFloat(@ceil(height_f32 / scale.y))) +
        self.size.padding.top +
        self.size.padding.bottom;
    _ = self.rt_app.performAction(
        .{ .surface = self },
        .initial_size,
        .{ .width = final_width, .height = final_height },
    ) catch return error.AppActionFailed;
}
fn resizeWindow(
    self: *Surface,
    size: terminal.StreamAction.ResizeWindow,
) !void {
    if (!self.config.vt_window_resize_allowed) {
        log.info("resize_window requested, but disabled via config", .{});
        return;
    }
    const scale = try self.rt_surface.getContentScale();
    const padding = self.config.scaledPadding(
        scale.x * font.face.default_dpi,
        scale.y * font.face.default_dpi,
    );
    const width: f32 = @floatFromInt(@max(size.columns, min_resize_width_cells) *
        self.size.cell.width + padding.left + padding.right);
    const height: f32 = @floatFromInt(@max(size.rows, min_resize_height_cells) *
        self.size.cell.height + padding.top + padding.bottom);
    _ = try self.rt_app.performAction(
        .{ .surface = self },
        .resize_window,
        .{
            .width = if (size.columns > 0) @intFromFloat(@ceil(width / scale.x)) else 0,
            .height = if (size.rows > 0) @intFromFloat(@ceil(height / scale.y)) else 0,
        },
    );
}
pub const Text = struct {
    text: [:0]const u8,
    viewport: ?Viewport = null,
    pub const Viewport = struct {
        tl_px_x: f64,
        tl_px_y: f64,
        offset_start: u32,
        offset_len: u32,
    };
    pub fn deinit(self: *Text, alloc: Allocator) void {
        alloc.free(self.text);
    }
};
pub fn dumpText(
    self: *Surface,
    alloc: Allocator,
    sel: terminal.Selection,
) !Text {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    return try self.dumpTextLocked(alloc, sel);
}
pub fn dumpTextLocked(
    self: *Surface,
    alloc: Allocator,
    sel: terminal.Selection,
) !Text {
    const text = try self.io.terminal.screens.active.selectionString(alloc, .{
        .sel = sel,
        .trim = false,
    });
    errdefer alloc.free(text);
    const vp: ?Text.Viewport = viewport: {
        const vp_tl_pin = self.io.terminal.screens.active.pages.getTopLeft(.viewport);
        const br_pin = sel.bottomRight(self.io.terminal.screens.active);
        if (br_pin.before(vp_tl_pin)) break :viewport null;
        const vp_br_pin = self.io.terminal.screens.active.pages.getBottomRight(.viewport) orelse {
            log.warn("viewport bottom-right pin not found, bug?", .{});
            break :viewport null;
        };
        const tl_pin = sel.topLeft(self.io.terminal.screens.active);
        if (vp_br_pin.before(tl_pin)) break :viewport null;
        const tl_pt: terminal.Point = self.io.terminal.screens.active.pages.pointFromPin(
            .viewport,
            tl_pin,
        ) orelse tl: {
            if (comptime std.debug.runtime_safety) {
                assert(tl_pin.before(vp_tl_pin));
            }
            break :tl .{ .viewport = .{} };
        };
        const br_pt = self.io.terminal.screens.active.pages.pointFromPin(
            .viewport,
            br_pin,
        ) orelse br: {
            if (comptime std.debug.runtime_safety) {
                assert(vp_br_pin.before(br_pin));
            }
            break :br self.io.terminal.screens.active.pages.pointFromPin(
                .viewport,
                vp_br_pin,
            ).?;
        };
        const tl_coord = tl_pt.coord();
        const br_coord = br_pt.coord();
        const content_scale = self.rt_surface.getContentScale() catch .{ .x = 1, .y = 1 };
        const x: f64 = x: {
            var x: f64 = @floatFromInt(tl_coord.x * self.size.cell.width);
            x += @floatFromInt(self.size.padding.left);
            x /= content_scale.x;
            break :x x;
        };
        const y: f64 = y: {
            var y: f64 = @floatFromInt(tl_coord.y * self.size.cell.height);
            y += @floatFromInt(self.size.cell.height);
            y -= @floatFromInt(self.font_metrics.cell_baseline);
            y += @floatFromInt(self.size.padding.top);
            y /= content_scale.y;
            break :y y;
        };
        const start = tl_coord.y * self.io.terminal.screens.active.pages.cols + tl_coord.x;
        const end = br_coord.y * self.io.terminal.screens.active.pages.cols + br_coord.x;
        break :viewport .{
            .tl_px_x = x,
            .tl_px_y = y,
            .offset_start = start,
            .offset_len = end - start,
        };
    };
    return .{
        .text = text,
        .viewport = vp,
    };
}
pub fn hasSelection(self: *const Surface) bool {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    return self.io.terminal.screens.active.selection != null;
}
pub fn selectionString(self: *Surface, alloc: Allocator) !?[:0]const u8 {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    const sel = self.io.terminal.screens.active.selection orelse return null;
    return try self.io.terminal.screens.active.selectionString(alloc, .{
        .sel = sel,
        .trim = false,
    });
}
pub fn pwd(
    self: *const Surface,
    alloc: Allocator,
) Allocator.Error!?[]const u8 {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    const terminal_pwd = self.io.terminal.getPwd() orelse return null;
    return try alloc.dupe(u8, terminal_pwd);
}
fn resolvePathForOpening(
    self: *Surface,
    path: []const u8,
) Allocator.Error!?[]const u8 {
    if (!std.fs.path.isAbsolute(path)) {
        const terminal_pwd = self.io.terminal.getPwd() orelse {
            return null;
        };
        const resolved = try std.fs.path.resolve(self.alloc, &.{ terminal_pwd, path });
        std.Io.Dir.accessAbsolute(global.io(), resolved, .{}) catch {
            self.alloc.free(resolved);
            return null;
        };
        return resolved;
    }
    return null;
}
pub fn imePoint(self: *const Surface) apprt.IMEPos {
    self.renderer_state.mutex.lockUncancelable(global.io());
    const cursor = self.renderer_state.terminal.screens.active.cursor;
    const preedit_width: usize = if (self.renderer_state.preedit) |preedit| preedit.width() else 0;
    self.renderer_state.mutex.unlock(global.io());
    const content_scale = self.rt_surface.getContentScale() catch .{ .x = 1, .y = 1 };
    const x: f64 = x: {
        var x: f64 = @floatFromInt(cursor.x * self.size.cell.width + self.size.padding.left);
        x += @as(f64, @floatFromInt(self.size.cell.width)) / 2;
        x /= content_scale.x;
        break :x x;
    };
    const y: f64 = y: {
        var y: f64 = @floatFromInt(cursor.y * self.size.cell.height + self.size.padding.top);
        y += @floatFromInt(self.size.cell.height);
        y /= content_scale.y;
        break :y y;
    };
    const height: f64 = height: {
        var height: f64 = @floatFromInt(self.size.cell.height);
        height /= content_scale.y;
        break :height height;
    };
    const width: f64 = width: {
        var width: f64 = @floatFromInt(preedit_width * self.size.cell.width);
        const screen_width: f64 = @floatFromInt(self.size.terminal().width);
        const x_offset: f64 = @floatFromInt((cursor.x + 1) * self.size.cell.width);
        const max = screen_width - x_offset;
        width = @min(width, max);
        break :width width;
    };
    return .{
        .x = x,
        .y = y,
        .width = width,
        .height = height,
    };
}
fn clipboardWrite(self: *const Surface, data: []const u8, loc: apprt.Clipboard) !void {
    if (self.config.clipboard_write == .deny) {
        log.info("application attempted to write clipboard, but 'clipboard-write' is set to deny", .{});
        return;
    }
    var buf = try self.alloc.allocSentinel(u8, simd.base64.maxLen(data), 0);
    defer self.alloc.free(buf);
    const decoded = simd.base64.decodeStrict(data, buf, .optional) catch {
        log.info("application sent invalid base64 data for OSC 52", .{});
        return;
    };
    buf[decoded.len] = 0;
    const confirm = self.config.clipboard_write == .ask;
    self.rt_surface.setClipboard(loc, &.{.{
        .mime = "text/plain",
        .data = buf[0..decoded.len :0],
    }}, confirm) catch |err| {
        log.err("error setting clipboard string err={}", .{err});
        return;
    };
}
fn copySelectionToClipboards(
    self: *Surface,
    sel: terminal.Selection,
    clipboards: []const apprt.Clipboard,
    format: input.Binding.Action.CopyToClipboard,
) !void {
    var arena = ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const opts: terminal.formatter.Options = .{
        .emit = .plain,
        .unwrap = true,
        .trim = self.config.clipboard_trim_trailing_spaces,
        .codepoint_map = self.config.clipboard_codepoint_map.map.list,
        .background = self.io.terminal.colors.background.get(),
        .foreground = self.io.terminal.colors.foreground.get(),
        .palette = &self.io.terminal.colors.palette.current,
    };
    const ScreenFormatter = terminal.formatter.ScreenFormatter;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    var contents_buf: [2]apprt.ClipboardContent = undefined;
    var contents: std.ArrayList(apprt.ClipboardContent) = .initBuffer(&contents_buf);
    switch (format) {
        .plain => {
            var formatter: ScreenFormatter = .init(self.io.terminal.screens.active, opts);
            formatter.content = .{ .selection = sel };
            try formatter.format(&aw.writer);
            contents.appendAssumeCapacity(.{
                .mime = "text/plain",
                .data = try aw.toOwnedSliceSentinel(0),
            });
        },
        .vt => {
            var formatter: ScreenFormatter = .init(self.io.terminal.screens.active, opts: {
                var copy = opts;
                copy.emit = .vt;
                break :opts copy;
            });
            formatter.content = .{ .selection = sel };
            try formatter.format(&aw.writer);
            contents.appendAssumeCapacity(.{
                .mime = "text/plain",
                .data = try aw.toOwnedSliceSentinel(0),
            });
        },
        .html => {
            var formatter: ScreenFormatter = .init(self.io.terminal.screens.active, opts: {
                var copy = opts;
                copy.emit = .html;
                break :opts copy;
            });
            formatter.content = .{ .selection = sel };
            try formatter.format(&aw.writer);
            contents.appendAssumeCapacity(.{
                .mime = "text/html",
                .data = try aw.toOwnedSliceSentinel(0),
            });
        },
        .mixed => {
            var formatter: ScreenFormatter = .init(self.io.terminal.screens.active, opts);
            formatter.content = .{ .selection = sel };
            try formatter.format(&aw.writer);
            contents.appendAssumeCapacity(.{
                .mime = "text/plain",
                .data = try aw.toOwnedSliceSentinel(0),
            });
            assert(aw.written().len == 0);
            formatter = .init(self.io.terminal.screens.active, opts: {
                var copy = opts;
                copy.emit = .html;
                copy.background = null;
                copy.foreground = null;
                break :opts copy;
            });
            formatter.content = .{ .selection = sel };
            try formatter.format(&aw.writer);
            contents.appendAssumeCapacity(.{
                .mime = "text/html",
                .data = try aw.toOwnedSliceSentinel(0),
            });
        },
    }
    assert(contents.items.len > 0);
    for (clipboards) |clipboard| self.rt_surface.setClipboard(
        clipboard,
        contents.items,
        false,
    ) catch |err| {
        log.err(
            "error setting clipboard string clipboard={} err={}",
            .{ clipboard, err },
        );
    };
}
fn setSelection(self: *Surface, sel_: ?terminal.Selection) !void {
    const prev_ = self.io.terminal.screens.active.selection;
    const changed = changed: {
        const prev = prev_ orelse break :changed sel_ != null;
        const sel = sel_ orelse break :changed true;
        break :changed !sel.eql(prev);
    };
    try self.io.terminal.screens.active.select(sel_);
    if (changed) {
        _ = self.rt_app.performAction(
            .{ .surface = self },
            .selection_changed,
            {},
        ) catch |err| {
            log.warn("apprt failed selection_changed notification err={}", .{err});
        };
    }
}
fn setSelectionAndCopy(self: *Surface, sel: terminal.Selection) !void {
    try self.setSelection(sel);
    switch (self.config.copy_on_select) {
        .none => {},
        .primary => try self.copySelectionToClipboards(
            sel,
            &.{.selection},
            .mixed,
        ),
        .clipboard => try self.copySelectionToClipboards(
            sel,
            &.{.standard},
            .mixed,
        ),
        .both => try self.copySelectionToClipboards(
            sel,
            &.{ .standard, .selection },
            .mixed,
        ),
    }
}
fn setCellSize(self: *Surface, size: rendererpkg.CellSize) !void {
    self.size.cell = size;
    self.balancePaddingIfNeeded();
    self.queueIo(.{ .resize = self.size }, .unlocked);
    self.recomputeInitialSize() catch |err| {
        log.warn("unable to recompute initial window size: {}", .{err});
    };
    _ = try self.rt_app.performAction(
        .{ .surface = self },
        .cell_size,
        .{ .width = size.width, .height = size.height },
    );
}
pub fn setFontSize(self: *Surface, size: font.face.DesiredSize) !void {
    log.debug("set font size size={}", .{size.points});
    self.font_size = size;
    const font_grid_key, const font_grid = try self.app.font_grid_set.ref(
        &self.config.font,
        self.font_size,
    );
    errdefer self.app.font_grid_set.deref(font_grid_key);
    try self.setCellSize(.{
        .width = font_grid.metrics.cell_width,
        .height = font_grid.metrics.cell_height,
    });
    _ = self.renderer_thread.mailbox.push(global.io(), .{
        .font_grid = .{
            .grid = font_grid,
            .set = &self.app.font_grid_set,
            .old_key = self.font_grid_key,
            .new_key = font_grid_key,
        },
    }, .{ .forever = {} });
    self.font_grid_key = font_grid_key;
    self.font_metrics = font_grid.metrics;
    self.queueRender() catch unreachable;
}
fn queueRender(self: *Surface) !void {
    try self.renderer_thread.wakeup.notify();
}
pub fn displayRealized(self: *Surface) !void {
    try self.renderer.displayRealized();
}
pub fn displayUnrealized(self: *Surface) void {
    self.renderer.displayUnrealized();
    self.renderer_thread.wakeup.notify() catch |err| {
        log.warn("failed to notify renderer thread of unrealize err={}", .{err});
    };
}
pub fn sizeCallback(self: *Surface, size: apprt.SurfaceSize) !void {
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;
    const new_screen_size: rendererpkg.ScreenSize = .{
        .width = size.width,
        .height = size.height,
    };
    if (self.size.screen.equals(new_screen_size)) return;
    try self.resize(new_screen_size);
}
fn resize(self: *Surface, size: rendererpkg.ScreenSize) !void {
    self.size.screen = size;
    self.balancePaddingIfNeeded();
    const grid_size = self.size.grid();
    if (grid_size.columns < 5 and (self.size.padding.left > 0 or self.size.padding.right > 0)) {
        log.warn("WARNING: very small terminal grid detected with padding " ++
            "set. Is your padding reasonable?", .{});
    }
    if (grid_size.rows < 2 and (self.size.padding.top > 0 or self.size.padding.bottom > 0)) {
        log.warn("WARNING: very small terminal grid detected with padding " ++
            "set. Is your padding reasonable?", .{});
    }
    self.queueIo(.{ .resize = self.size }, .unlocked);
    _ = self.renderer_thread.mailbox.push(
        global.io(),
        .{ .resize = self.size },
        .forever,
    );
    self.queueRender() catch |err| {
        log.warn("failed to notify renderer of resize err={}", .{err});
    };
}
fn balancePaddingIfNeeded(self: *Surface) void {
    if (self.config.window_padding_balance == .false) return;
    const content_scale = try self.rt_surface.getContentScale();
    const x_dpi = content_scale.x * font.face.default_dpi;
    const y_dpi = content_scale.y * font.face.default_dpi;
    self.size.balancePadding(self.config.scaledPadding(x_dpi, y_dpi), self.config.window_padding_balance);
}
pub fn preeditCallback(self: *Surface, preedit_: ?[]const u8) !void {
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    if (self.renderer_state.preedit != null or
        preedit_ != null)
    {
        if (self.config.selection_clear_on_typing) {
            self.setSelection(null) catch {};
        }
    }
    if (self.renderer_state.preedit) |p| {
        self.alloc.free(p.codepoints);
        self.renderer_state.preedit = null;
    }
    self.io.terminal.flags.dirty.preedit = true;
    const text = preedit_ orelse {
        try self.queueRender();
        return;
    };
    const view = try std.unicode.Utf8View.init(text);
    var it = view.iterator();
    const Codepoint = rendererpkg.State.Preedit.Codepoint;
    var codepoints: std.ArrayList(Codepoint) = .empty;
    defer codepoints.deinit(self.alloc);
    while (it.nextCodepoint()) |cp| {
        const width: usize = @intCast(unicode.table.get(cp).width);
        if (width <= 0) continue;
        try codepoints.append(
            self.alloc,
            .{ .codepoint = cp, .wide = width >= 2 },
        );
    }
    if (codepoints.items.len == 0) {
        try self.queueRender();
        return;
    }
    self.renderer_state.preedit = .{
        .codepoints = try codepoints.toOwnedSlice(self.alloc),
    };
    try self.queueRender();
}
pub fn keyEventIsBinding(
    self: *Surface,
    event_orig: input.KeyEvent,
) ?input.Binding.Flags {
    var event = event_orig;
    if (self.config.key_remaps.isRemapped(event_orig.mods)) {
        event.mods = self.config.key_remaps.apply(event_orig.mods);
    }
    switch (event.action) {
        .release => return null,
        .press, .repeat => {},
    }
    const entry: input.Binding.Set.Entry = entry: {
        if (self.keyboard.sequence_set) |set| {
            break :entry set.getEvent(event) orelse return null;
        }
        const table_items = self.keyboard.table_stack.items;
        for (0..table_items.len) |i| {
            const rev_i: usize = table_items.len - 1 - i;
            if (table_items[rev_i].set.getEvent(event)) |entry| {
                break :entry entry;
            }
        }
        break :entry self.config.keybind.set.getEvent(event) orelse return null;
    };
    return switch (entry.value_ptr.*) {
        .leader => .{},
        inline .leaf, .leaf_chained => |v| v.flags,
    };
}
pub fn keyCallback(
    self: *Surface,
    event_orig: input.KeyEvent,
) !InputEffect {
    var event = event_orig;
    if (self.config.key_remaps.isRemapped(event_orig.mods)) {
        event.mods = self.config.key_remaps.apply(event_orig.mods);
    }
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;
    var insp_ev: ?inspectorpkg.KeyEvent = if (self.inspector != null) ev: {
        var copy = event;
        copy.utf8 = "";
        if (event.utf8.len > 0) copy.utf8 = try self.alloc.dupe(u8, event.utf8);
        break :ev .{ .event = copy };
    } else null;
    defer if (insp_ev) |ev| ev: {
        const insp = self.inspector orelse {
            ev.deinit(self.alloc);
            break :ev;
        };
        if (insp.recordKeyEvent(self.alloc, ev)) {
            self.queueRender() catch {};
        } else |err| {
            log.warn("error adding key event to inspector err={}", .{err});
        }
    };
    if (try self.maybeHandleBinding(
        event,
        if (insp_ev) |*ev| ev else null,
    )) |v| return v;
    if (self.config.vt_kam_allowed) {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        if (self.io.terminal.modes.get(.disable_keyboard)) return .consumed;
    }
    if (self.config.mouse_hide_while_typing and
        event.action == .press and
        !self.mouse.hidden and
        event.utf8.len > 0)
    {
        self.hideMouse();
    }
    if (!self.mouse.mods.equal(event.mods)) mouse_mods: {
        self.modsChanged(event.mods);
        if (self.io.terminal.flags.mouse_event == .none or
            (self.mouse.mods.shift and !self.mouseShiftCapture(false)))
        {
            const pos = self.rt_surface.getCursorPos() catch break :mouse_mods;
            self.renderer_state.mutex.lockUncancelable(global.io());
            defer self.renderer_state.mutex.unlock(global.io());
            self.mouseRefreshLinks(
                pos,
                self.posToViewport(pos.x, pos.y),
                self.mouse.over_link,
            ) catch |err| {
                log.warn("failed to refresh links err={}", .{err});
                break :mouse_mods;
            };
        } else if (self.io.terminal.flags.mouse_event != .none and !self.mouse.mods.shift) {
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .mouse_shape,
                self.io.terminal.mouse_shape,
            );
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .mouse_over_link,
                .{ .url = "" },
            );
            try self.queueRender();
        }
    }
    if ((SurfaceMouse{
        .physical_key = event.key,
        .mouse_event = self.io.terminal.flags.mouse_event,
        .mouse_shape = self.io.terminal.mouse_shape,
        .mods = self.mouse.mods,
        .over_link = self.mouse.over_link,
        .hidden = self.mouse.hidden,
    }).keyToMouseShape()) |shape| _ = try self.rt_app.performAction(
        .{ .surface = self },
        .mouse_shape,
        shape,
    );
    self.pressed_key = event: {
        var copy = event;
        copy.utf8 = "";
        if (event.action == .release) {
            const prev = self.pressed_key orelse break :event null;
            if (prev.key == copy.key) copy.key = .unidentified;
        }
        if (copy.key == .unidentified and copy.mods.empty()) break :event null;
        break :event copy;
    };
    if (try self.encodeKey(
        event,
        if (insp_ev) |*ev| ev else null,
    )) |write_req| {
        if (self.child_exited) {
            write_req.deinit();
            self.close();
            return .closed;
        }
        self.queueIo(switch (write_req) {
            .small => |v| .{ .write_small = v },
            .stable => |v| .{ .write_stable = v },
            .alloc => |v| .{ .write_alloc = v },
        }, .unlocked);
    } else {
        return .ignored;
    }
    if (!event.key.modifier()) {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        if (self.config.selection_clear_on_typing or
            event.key == .escape)
        {
            try self.setSelection(null);
        }
        if (self.config.scroll_to_bottom.keystroke) self.io.terminal.scrollViewport(.bottom);
        try self.queueRender();
    }
    return .consumed;
}
fn maybeHandleBinding(
    self: *Surface,
    event: input.KeyEvent,
    insp_ev: ?*inspectorpkg.KeyEvent,
) !?InputEffect {
    switch (event.action) {
        .release => {
            if (self.keyboard.last_trigger) |last| {
                if (last == event.bindingHash()) {
                    return .consumed;
                }
            }
            return null;
        },
        .press, .repeat => {},
    }
    const entry: input.Binding.Set.Entry = entry: {
        if (self.keyboard.sequence_set) |set| {
            if (set.getEvent(event)) |v| break :entry v;
            if (event.key.modifier()) return null;
            if (self.catchAllIsIgnore()) {
                self.endKeySequence(.drop, .retain);
                return .ignored;
            }
            self.endKeySequence(.flush, .retain);
            return null;
        }
        const table_items = self.keyboard.table_stack.items;
        if (table_items.len > 0) {
            for (0..table_items.len) |i| {
                const rev_i: usize = table_items.len - 1 - i;
                const table = table_items[rev_i];
                if (table.set.getEvent(event)) |v| {
                    if (table.once and i == 0) _ = try self.performBindingAction(
                        .deactivate_key_table,
                    );
                    break :entry v;
                }
            }
        }
        break :entry self.config.keybind.set.getEvent(event) orelse
            return null;
    };
    const leaf: input.Binding.Set.GenericLeaf = switch (entry.value_ptr.*) {
        .leader => |set| {
            if (try self.encodeKey(event, insp_ev)) |req| {
                self.keyboard.sequence_queued.append(self.alloc, req) catch |err| {
                    req.deinit();
                    return err;
                };
            }
            self.keyboard.sequence_set = set;
            _ = self.rt_app.performAction(
                .{ .surface = self },
                .key_sequence,
                .{ .trigger = entry.key_ptr.* },
            ) catch |err| {
                log.warn(
                    "failed to notify app of key sequence err={}",
                    .{err},
                );
            };
            return .consumed;
        },
        inline .leaf, .leaf_chained => |leaf| leaf.generic(),
    };
    const consumed = consumed: {
        if (leaf.flags.consumed) break :consumed true;
        if (leaf.flags.global or leaf.flags.all) break :consumed true;
        break :consumed false;
    };
    self.keyboard.last_trigger = null;
    self.keyboard.sequence_set = null;
    const actions = leaf.actionsSlice();
    log.debug("key event binding flags={} action={any}", .{
        leaf.flags,
        actions,
    });
    const performed = performed: {
        if (leaf.flags.global or leaf.flags.all) {
            self.app.performAllChainedAction(
                self.rt_app,
                actions,
            );
            break :performed true;
        }
        var performed: bool = false;
        for (actions) |action| {
            if (self.performBindingAction(action)) |v| {
                performed = performed or v;
            } else |err| {
                log.info(
                    "key binding action failed action={t} err={}",
                    .{ action, err },
                );
            }
        }
        break :performed performed;
    };
    if (performed) {
        for (actions) |action| if (closingAction(action)) {
            log.debug("key binding is a closing binding, halting key event processing", .{});
            return .closed;
        };
        for (actions) |action| if (action == .ignore) {
            self.endKeySequence(.drop, .retain);
            return .ignored;
        };
    }
    if (leaf.flags.performable and !performed) {
        self.endKeySequence(.flush, .retain);
        return null;
    }
    if (consumed) {
        self.endKeySequence(.drop, .retain);
        self.keyboard.last_trigger = event.bindingHash();
        if (insp_ev) |ev| {
            ev.binding = self.alloc.dupe(
                input.Binding.Action,
                actions,
            ) catch |err| binding: {
                log.warn(
                    "error allocating binding action for inspector err={}",
                    .{err},
                );
                break :binding &.{};
            };
        }
        return .consumed;
    }
    self.endKeySequence(.flush, .retain);
    return null;
}
fn deactivateAllKeyTables(self: *Surface) !bool {
    switch (self.keyboard.table_stack.items.len) {
        0 => return false,
        else => self.keyboard.table_stack.clearAndFree(self.alloc),
    }
    _ = self.rt_app.performAction(
        .{ .surface = self },
        .key_table,
        .deactivate_all,
    ) catch |err| {
        log.warn(
            "failed to notify app of key table err={}",
            .{err},
        );
    };
    return true;
}
fn catchAllIsIgnore(self: *Surface) bool {
    const entry: input.Binding.Set.Entry = entry: {
        const trigger: input.Binding.Trigger = .{ .key = .catch_all };
        const table_items = self.keyboard.table_stack.items;
        for (0..table_items.len) |i| {
            const rev_i: usize = table_items.len - 1 - i;
            const entry = table_items[rev_i].set.get(trigger) orelse continue;
            break :entry entry;
        }
        break :entry self.config.keybind.set.get(trigger) orelse
            return false;
    };
    return switch (entry.value_ptr.*) {
        .leader => false,
        .leaf => |leaf| leaf.action == .ignore,
        .leaf_chained => |leaf| chained: for (leaf.actions.items) |action| {
            if (action == .ignore) break :chained true;
        } else false,
    };
}
const KeySequenceQueued = enum { flush, drop };
const KeySequenceMemory = enum { retain, free };
fn endKeySequence(
    self: *Surface,
    action: KeySequenceQueued,
    mem: KeySequenceMemory,
) void {
    _ = self.rt_app.performAction(
        .{ .surface = self },
        .key_sequence,
        .end,
    ) catch |err| {
        log.warn(
            "failed to notify app of key sequence end err={}",
            .{err},
        );
    };
    self.keyboard.sequence_set = null;
    if (self.keyboard.sequence_queued.items.len == 0) return;
    switch (action) {
        .flush => for (self.keyboard.sequence_queued.items) |write_req| {
            self.queueIo(switch (write_req) {
                .small => |v| .{ .write_small = v },
                .stable => |v| .{ .write_stable = v },
                .alloc => |v| .{ .write_alloc = v },
            }, .unlocked);
        },
        .drop => for (self.keyboard.sequence_queued.items) |req| req.deinit(),
    }
    switch (mem) {
        .free => self.keyboard.sequence_queued.clearAndFree(self.alloc),
        .retain => self.keyboard.sequence_queued.clearRetainingCapacity(),
    }
}
fn encodeKey(
    self: *Surface,
    event: input.KeyEvent,
    insp_ev: ?*inspectorpkg.KeyEvent,
) !?termio.Message.WriteReq {
    const write_req: termio.Message.WriteReq = req: {
        const encoding_opts = self.encodeKeyOpts();
        var data: termio.Message.WriteReq.Small.Array = undefined;
        var writer: std.Io.Writer = .fixed(&data);
        if (input.key_encode.encode(
            &writer,
            event,
            encoding_opts,
        )) {
            const written = writer.buffered();
            if (written.len == 0) return null;
            break :req .{ .small = .{
                .data = data,
                .len = @intCast(written.len),
            } };
        } else |err| switch (err) {
            error.WriteFailed => {},
        }
        var alloc_writer: std.Io.Writer.Allocating = try .initCapacity(
            self.alloc,
            @max(event.utf8.len * 2, data.len * 2),
        );
        defer alloc_writer.deinit();
        try input.key_encode.encode(
            &alloc_writer.writer,
            event,
            encoding_opts,
        );
        break :req .{ .alloc = .{
            .alloc = self.alloc,
            .data = try alloc_writer.toOwnedSlice(),
        } };
    };
    if (insp_ev) |ev| pty: {
        const slice = write_req.slice();
        const copy = self.alloc.alloc(u8, slice.len) catch |err| {
            log.warn("error allocating pty data for inspector err={}", .{err});
            break :pty;
        };
        errdefer self.alloc.free(copy);
        @memcpy(copy, slice);
        ev.pty = copy;
    }
    return write_req;
}
fn encodeKeyOpts(self: *const Surface) input.key_encode.Options {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    const t = &self.io.terminal;
    var opts: input.key_encode.Options = .fromTerminal(t);
    if (comptime builtin.os.tag != .macos) return opts;
    opts.macos_option_as_alt = self.config.macos_option_as_alt orelse detect: {
        if (!self.mouse.mods.alt) break :detect .false;
        break :detect self.rt_app.keyboardLayout().detectOptionAsAlt();
    };
    return opts;
}
pub fn textCallback(self: *Surface, text: []const u8) !void {
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;
    try self.completeClipboardPaste(text, true);
}
pub fn occlusionCallback(self: *Surface, visible: bool) !void {
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;
    if (self.visible == visible) return;
    self.visible = visible;
    self.renderer_state.mutex.lockUncancelable(global.io());
    self.io.terminal.flags.visible = visible;
    const report_visibility = self.io.terminal.modes.get(.report_visibility);
    self.renderer_state.mutex.unlock(global.io());
    if (report_visibility) {
        self.queueIo(.{ .visibility_report = .{
            .visible = visible,
            .force = false,
        } }, .unlocked);
    }
    _ = self.renderer_thread.mailbox.push(global.io(), .{
        .visible = visible,
    }, .{ .forever = {} });
    try self.queueRender();
}
pub fn focusCallback(self: *Surface, focused: bool) !void {
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;
    if (focused) self.app.focusSurface(self);
    if (self.focused == focused) return;
    self.focused = focused;
    _ = self.renderer_thread.mailbox.push(global.io(), .{
        .focus = focused,
    }, .{ .forever = {} });
    if (!focused) unfocused: {
        var pressed_key = self.pressed_key orelse break :unfocused;
        self.pressed_key = null;
        pressed_key.action = .release;
        if (pressed_key.key != .unidentified) {
            assert(self.keyCallback(pressed_key) catch |err| err: {
                log.warn("error releasing key on focus loss err={}", .{err});
                break :err .ignored;
            } != .closed);
        }
        if (pressed_key.mods.empty()) break :unfocused;
        const keys = &.{ "shift", "ctrl", "alt", "super" };
        const original_key = pressed_key.key;
        inline for (keys) |key| {
            if (@field(pressed_key.mods, key)) {
                @field(pressed_key.mods, key) = false;
                inline for (&.{ "right", "left" }) |side| {
                    const keyname = comptime keyname: {
                        break :keyname if (std.mem.eql(u8, key, "ctrl"))
                            "control"
                        else if (std.mem.eql(u8, key, "super"))
                            "meta"
                        else
                            key;
                    };
                    pressed_key.key = @field(input.Key, keyname ++ "_" ++ side);
                    if (pressed_key.key != original_key) {
                        assert(self.keyCallback(pressed_key) catch |err| err: {
                            log.warn("error releasing key on focus loss err={}", .{err});
                            break :err .ignored;
                        } != .closed);
                    }
                }
            }
        }
    }
    try self.queueRender();
    self.showMouse();
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        self.io.terminal.flags.focused = focused;
        self.renderer_state.mutex.unlock(global.io());
        self.queueIo(.{ .focused = focused }, .unlocked);
    }
}
pub fn refreshCallback(self: *Surface) !void {
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;
    try self.queueRender();
}
const ScrollAmount = struct {
    delta: isize = 0,
    pub fn direction(self: ScrollAmount) enum { down_left, up_right } {
        return if (self.delta < 0) .down_left else .up_right;
    }
    pub fn magnitude(self: ScrollAmount) usize {
        return @abs(self.delta);
    }
};
pub fn scrollCallback(
    self: *Surface,
    xoff: f64,
    yoff: f64,
    scroll_mods: input.ScrollMods,
) !void {
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;
    if (self.mouse.hidden) self.showMouse();
    const y: ScrollAmount = if (yoff == 0) .{} else y: {
        const cell_size: f64 = @floatFromInt(self.size.cell.height);
        const yoff_adjusted: f64 = if (scroll_mods.precision)
            yoff * self.config.mouse_scroll_multiplier.precision
        else yoff_adjusted: {
            if (comptime builtin.target.os.tag.isDarwin()) {
                const yoff_max: f64 = if (yoff > 0)
                    @max(yoff, 1)
                else
                    @min(yoff, -1);
                break :yoff_adjusted yoff_max * cell_size * self.config.mouse_scroll_multiplier.discrete;
            } else {
                break :yoff_adjusted yoff * cell_size * self.config.mouse_scroll_multiplier.discrete;
            }
        };
        const poff: f64 = self.mouse.pending_scroll_y + yoff_adjusted;
        if (@abs(poff) < cell_size) {
            self.mouse.pending_scroll_y = poff;
            break :y .{};
        }
        const amount = poff / cell_size;
        assert(@abs(amount) >= 1);
        self.mouse.pending_scroll_y = poff - (amount * cell_size);
        const delta: isize = @intFromFloat(@trunc(amount));
        assert(@abs(delta) >= 1);
        break :y .{ .delta = delta };
    };
    const x: ScrollAmount = if (xoff == 0) .{} else x: {
        if (!scroll_mods.precision) {
            const x_delta_isize: isize = @intFromFloat(@round(xoff));
            break :x .{ .delta = x_delta_isize };
        }
        const poff: f64 = self.mouse.pending_scroll_x + xoff;
        const cell_size: f64 = @floatFromInt(self.size.cell.width);
        if (@abs(poff) < cell_size) {
            self.mouse.pending_scroll_x = poff;
            break :x .{};
        }
        const amount = poff / cell_size;
        assert(@abs(amount) >= 1);
        self.mouse.pending_scroll_x = poff - (amount * cell_size);
        const delta: isize = @intFromFloat(@trunc(amount));
        assert(@abs(delta) >= 1);
        break :x .{ .delta = delta };
    };
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        if (self.isMouseReporting()) {
            try self.setSelection(null);
        }
        if (self.io.terminal.screens.active_key == .alternate and
            self.io.terminal.flags.mouse_event == .none and
            self.io.terminal.modes.get(.mouse_alternate_scroll))
        {
            if (y.delta != 0) {
                try self.setSelection(null);
                const seq = if (self.io.terminal.modes.get(.cursor_keys)) seq: {
                    break :seq switch (y.direction()) {
                        .up_right => "\x1bOA",
                        .down_left => "\x1bOB",
                    };
                } else seq: {
                    break :seq switch (y.direction()) {
                        .up_right => "\x1b[A",
                        .down_left => "\x1b[B",
                    };
                };
                for (0..y.magnitude()) |_| {
                    self.queueIo(.{ .write_stable = seq }, .locked);
                }
            }
            return;
        }
        if (self.isMouseReporting()) {
            for (0..@abs(y.delta)) |_| {
                const pos = try self.rt_surface.getCursorPos();
                self.mouseReport(switch (y.direction()) {
                    .up_right => .four,
                    .down_left => .five,
                }, .press, self.mouse.mods, pos);
            }
            for (0..@abs(x.delta)) |_| {
                const pos = try self.rt_surface.getCursorPos();
                self.mouseReport(switch (x.direction()) {
                    .up_right => .six,
                    .down_left => .seven,
                }, .press, self.mouse.mods, pos);
            }
            return;
        }
        if (y.delta != 0) {
            self.io.terminal.scrollViewport(.{ .delta = y.delta * -1 });
        }
    }
    try self.queueRender();
}
pub fn contentScaleCallback(self: *Surface, content_scale: apprt.ContentScale) !void {
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;
    const x_dpi = content_scale.x * font.face.default_dpi;
    const y_dpi = content_scale.y * font.face.default_dpi;
    const size = size: {
        var size = self.font_size;
        size.xdpi = @intFromFloat(@round(x_dpi));
        size.ydpi = @intFromFloat(@round(y_dpi));
        break :size size;
    };
    if (size.xdpi == self.font_size.xdpi and size.ydpi == self.font_size.ydpi) {
        return;
    }
    try self.setFontSize(size);
    if (self.config.window_padding_balance == .false) {
        self.size.padding = self.config.scaledPadding(x_dpi, y_dpi);
    }
    try self.resize(self.size.screen);
}
fn isMouseReporting(self: *const Surface) bool {
    return self.config.mouse_reporting and
        self.io.terminal.flags.mouse_event != .none;
}
pub fn mouseReportingActive(self: *Surface) bool {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    return self.isMouseReporting();
}
fn mouseReport(
    self: *Surface,
    button: ?input.MouseButton,
    action: input.MouseAction,
    mods: input.Mods,
    pos: apprt.CursorPos,
) void {
    assert(self.config.mouse_reporting);
    assert(self.io.terminal.flags.mouse_event != .none);
    const encoding_opts: input.mouse_encode.Options = opts: {
        var opts: input.mouse_encode.Options = .fromTerminal(
            &self.io.terminal,
            self.size,
        );
        opts.any_button_pressed = pressed: {
            for (self.mouse.click_state) |state| {
                if (state != .release) break :pressed true;
            }
            break :pressed false;
        };
        opts.last_cell = &self.mouse.event_point;
        break :opts opts;
    };
    var data: termio.Message.WriteReq.Small.Array = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    input.mouse_encode.encode(&writer, .{
        .button = button,
        .action = action,
        .mods = mods,
        .pos = .{
            .x = pos.x,
            .y = pos.y,
        },
    }, encoding_opts) catch |err| switch (err) {
        error.WriteFailed => {
            log.warn("failed to encode mouse event err={}", .{err});
            return;
        },
    };
    const written = writer.buffered();
    if (written.len == 0) return;
    self.queueIo(.{ .write_small = .{
        .data = data,
        .len = @intCast(written.len),
    } }, .locked);
}
fn mouseShiftCapture(self: *const Surface, lock: bool) bool {
    switch (self.config.mouse_shift_capture) {
        .never => return false,
        .always => return true,
        .false, .true => {},
    }
    if (lock) self.renderer_state.mutex.lockUncancelable(global.io());
    defer if (lock) self.renderer_state.mutex.unlock(global.io());
    switch (self.io.terminal.flags.mouse_shift_capture) {
        .false => return false,
        .true => return true,
        .null => {},
    }
    return switch (self.config.mouse_shift_capture) {
        .false => false,
        .true => true,
        .never, .always => unreachable,
    };
}
pub fn mouseCaptured(self: *Surface) bool {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    return self.io.terminal.flags.mouse_event != .none;
}
pub fn mouseButtonCallback(
    self: *Surface,
    action: input.MouseButtonState,
    button: input.MouseButton,
    mods: input.Mods,
) !bool {
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;
    if (self.inspector != null) {
        defer self.queueRender() catch {};
    }
    self.mouse.click_state[@intCast(@intFromEnum(button))] = action;
    if (self.mouse.hidden) self.showMouse();
    self.modsChanged(mods);
    const shift_capture = self.mouseShiftCapture(true);
    if (button == .left and action == .press) {
        if (mods.shift and
            self.mouse.selection_gesture.left_click_count > 0 and
            !shift_capture)
        extend_selection: {
            if (!self.hasSelection()) break :extend_selection;
            const click_time = self.mouse.selection_gesture.left_click_time orelse
                break :extend_selection;
            const since = click_time.untilNow(global.io(), .awake);
            if (since.toNanoseconds() <= self.config.mouse_interval) {
                break :extend_selection;
            }
            const pos = try self.rt_surface.getCursorPos();
            try self.cursorPosCallback(pos, null);
            return true;
        }
    }
    if (button == .left and action == .release) {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        const release_pos: ?apprt.CursorPos = self.rt_surface.getCursorPos() catch |err| pos: {
            log.warn("error reading cursor position for mouse release err={}", .{err});
            break :pos null;
        };
        const release_pin: ?terminal.Pin = if (release_pos) |pos| pin: {
            const release_vp = self.posToViewport(pos.x, pos.y);
            break :pin self.io.terminal.screens.active.pages.pin(.{ .viewport = .{
                .x = release_vp.x,
                .y = release_vp.y,
            } });
        } else null;
        self.mouse.selection_gesture.release(
            self.renderer_state.terminal,
            .{ .pin = release_pin },
        );
        if (self.selection_scroll_active) {
            self.queueIo(
                .{ .selection_scroll = false },
                .locked,
            );
        }
        if (self.config.copy_on_select != .none) {
            const prev_ = self.io.terminal.screens.active.selection;
            if (prev_) |prev| {
                try self.setSelectionAndCopy(terminal.Selection.init(
                    prev.start(),
                    prev.end(),
                    prev.rectangle,
                ));
            }
        }
        if (self.mouse.over_link and !self.mouse.selection_gesture.left_click_dragged) {
            const pos = release_pos orelse try self.rt_surface.getCursorPos();
            if (self.processLinks(pos)) |processed| {
                if (processed) return true;
            } else |err| {
                log.warn("error processing links err={}", .{err});
            }
        }
        if (self.maybePromptClick()) |handled| {
            if (handled) return true;
        } else |err| {
            log.warn("error processing prompt click err={}", .{err});
        }
    }
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        if (self.isMouseReporting()) report: {
            if (mods.shift and !shift_capture) break :report;
            try self.setSelection(null);
            self.mouse.selection_gesture.reset(self.renderer_state.terminal);
            const pos = try self.rt_surface.getCursorPos();
            const report_action: input.MouseAction = switch (action) {
                .press => .press,
                .release => .release,
            };
            self.mouseReport(
                button,
                report_action,
                self.mouse.mods,
                pos,
            );
            return true;
        }
    }
    if (button == .left and action == .press) click: {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        const t: *terminal.Terminal = self.renderer_state.terminal;
        const screen: *terminal.Screen = self.renderer_state.terminal.screens.active;
        const pos = try self.rt_surface.getCursorPos();
        const pin = pin: {
            const pt_viewport = self.posToViewport(pos.x, pos.y);
            const pin = screen.pages.pin(.{
                .viewport = .{
                    .x = pt_viewport.x,
                    .y = pt_viewport.y,
                },
            }) orelse {
                if (comptime std.debug.runtime_safety) unreachable;
                break :click;
            };
            break :pin pin;
        };
        var press_selection = try self.mouse.selection_gesture.press(t, .{
            .time = std.Io.Timestamp.now(global.io(), .awake),
            .pin = pin,
            .xpos = pos.x,
            .ypos = pos.y,
            .max_distance = @floatFromInt(self.size.cell.width),
            .repeat_interval = self.config.mouse_interval,
            .word_boundary_codepoints = self.config.selection_word_chars,
            .behaviors = &.{
                .cell,
                .word,
                if (mods.ctrlOrSuper()) .output else .line,
            },
        });
        switch (self.mouse.selection_gesture.left_click_count) {
            1 => {},
            2 => {
                if (self.linkAtPin(
                    pin,
                    null,
                )) |result_| {
                    if (result_) |result| {
                        press_selection = result.selection;
                    }
                } else |_| {}
            },
            3 => {},
            else => unreachable,
        }
        if (press_selection) |selection| {
            try self.setSelection(selection);
            try self.queueRender();
        } else if (self.mouse.selection_gesture.left_click_count == 1 and
            self.io.terminal.screens.active.selection != null)
        {
            try self.setSelection(null);
            try self.queueRender();
        }
    }
    if (button == .middle and action == .press) switch (self.config.middle_click_action) {
        .ignore => {},
        .@"clipboard-paste" => {
            _ = try self.startClipboardRequest(.standard, .{ .paste = .standard });
        },
        .@"primary-paste" => {
            if (self.rt_surface.supportsClipboard(.selection)) {
                _ = try self.startClipboardRequest(.selection, .{ .paste = .selection });
            }
        },
    };
    if (button == .right and action == .press) sel: {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        const screen: *terminal.Screen = self.renderer_state.terminal.screens.active;
        const pos = try self.rt_surface.getCursorPos();
        const pin = pin: {
            const pt_viewport = self.posToViewport(pos.x, pos.y);
            const pin = screen.pages.pin(.{
                .viewport = .{
                    .x = pt_viewport.x,
                    .y = pt_viewport.y,
                },
            }) orelse {
                if (comptime std.debug.runtime_safety) unreachable;
                break :sel;
            };
            break :pin pin;
        };
        switch (self.config.right_click_action) {
            .ignore => {},
            .@"context-menu" => {
                if (self.io.terminal.screens.active.selection) |prev_sel| {
                    if (prev_sel.contains(screen, pin)) break :sel;
                }
                if (try self.linkAtPos(pos)) |link| {
                    try self.setSelectionAndCopy(link.selection);
                } else {
                    const sel = screen.selectWord(
                        pin,
                        self.config.selection_word_chars,
                    ) orelse break :sel;
                    try self.setSelectionAndCopy(sel);
                }
                try self.queueRender();
                return false;
            },
            .copy => {
                if (self.io.terminal.screens.active.selection) |sel| {
                    try self.copySelectionToClipboards(
                        sel,
                        &.{.standard},
                        .mixed,
                    );
                }
                try self.setSelection(null);
                try self.queueRender();
            },
            .@"copy-or-paste" => if (self.io.terminal.screens.active.selection) |sel| {
                try self.copySelectionToClipboards(
                    sel,
                    &.{.standard},
                    .mixed,
                );
                try self.setSelection(null);
                try self.queueRender();
            } else {
                self.renderer_state.mutex.unlock(global.io());
                defer self.renderer_state.mutex.lockUncancelable(global.io());
                _ = try self.startClipboardRequest(.standard, .{ .paste = .standard });
            },
            .paste => {
                try self.setSelection(null);
                try self.queueRender();
                self.renderer_state.mutex.unlock(global.io());
                defer self.renderer_state.mutex.lockUncancelable(global.io());
                _ = try self.startClipboardRequest(.standard, .{ .paste = .standard });
            },
        }
        return true;
    }
    return false;
}
fn maybePromptClick(self: *Surface) !bool {
    const t: *terminal.Terminal = self.renderer_state.terminal;
    const screen: *terminal.Screen = t.screens.active;
    if (screen.semantic_prompt.click == .none) return false;
    if (!self.config.cursor_click_to_move) return false;
    if (!t.cursorIsAtPrompt()) return false;
    if (self.mouse.selection_gesture.left_click_count == 0) return false;
    if (self.mouse.selection_gesture.left_click_dragged) return false;
    if (screen.selection != null) return false;
    const pos = try self.rt_surface.getCursorPos();
    const pos_vp = self.posToViewport(pos.x, pos.y);
    const click_pin: terminal.Pin = pin: {
        const pin = screen.pages.pin(.{
            .viewport = .{
                .x = pos_vp.x,
                .y = pos_vp.y,
            },
        }) orelse {
            if (comptime std.debug.runtime_safety) unreachable;
            return false;
        };
        break :pin pin;
    };
    const prompt_pin: terminal.Pin = prompt_pin: {
        var it = screen.cursor.page_pin.promptIterator(
            .left_up,
            null,
        );
        break :prompt_pin it.next() orelse {
            log.warn("cursor is at prompt but no prompt found", .{});
            if (comptime std.debug.runtime_safety) unreachable;
            return false;
        };
    };
    if (click_pin.before(prompt_pin)) return false;
    switch (screen.semantic_prompt.click) {
        .none => unreachable,
        .click_events => |v| {
            const key: u8, const y: u32 = switch (v) {
                .absolute => .{ 1, pos_vp.y +| 1 },
                .relative => .{
                    2,
                    promptClickRelativeRow(&screen.pages, prompt_pin, click_pin),
                },
            };
            var data: termio.Message.WriteReq.Small.Array = undefined;
            const resp = try std.fmt.bufPrint(
                &data,
                "\x1B[<0;{d};{d}M",
                .{ pos_vp.x + 1, y },
            );
            log.debug(
                "sending click_events={} event=ESC{s}",
                .{ key, resp[1..] },
            );
            self.queueIo(.{ .write_small = .{
                .data = data,
                .len = @intCast(resp.len),
            } }, .locked);
        },
        .cl => {
            const left_arrow = if (t.modes.get(.cursor_keys)) "\x1bOD" else "\x1b[D";
            const right_arrow = if (t.modes.get(.cursor_keys)) "\x1bOC" else "\x1b[C";
            const move = screen.promptClickMove(click_pin);
            for (0..move.left) |_| {
                self.queueIo(
                    .{ .write_stable = left_arrow },
                    .locked,
                );
            }
            for (0..move.right) |_| {
                self.queueIo(
                    .{ .write_stable = right_arrow },
                    .locked,
                );
            }
        },
    }
    return true;
}
fn promptClickRelativeRow(
    pages: *const terminal.PageList,
    prompt_pin: terminal.Pin,
    click_pin: terminal.Pin,
) u32 {
    const prompt_y = pages.pointFromPin(.screen, prompt_pin).?.screen.y;
    const click_y = pages.pointFromPin(.screen, click_pin).?.screen.y;
    return click_y - prompt_y + 1;
}
const Link = struct {
    action: input.Link.Action,
    selection: terminal.Selection,
};
fn linkAtPos(
    self: *Surface,
    pos: apprt.CursorPos,
) !?Link {
    const screen: *terminal.Screen = self.renderer_state.terminal.screens.active;
    const mouse_pin: terminal.Pin = mouse_pin: {
        const point = self.posToViewport(pos.x, pos.y);
        const pin = screen.pages.pin(.{ .viewport = point }) orelse {
            log.warn("failed to get pin for clicked point", .{});
            return null;
        };
        break :mouse_pin pin;
    };
    const mouse_mods = self.mouseModsWithCapture(self.mouse.mods);
    if (self.config.link_osc8 and
        mouse_mods.equal(input.ctrlOrSuper(.{})))
    hyperlink: {
        const rac = mouse_pin.rowAndCell();
        const cell = rac.cell;
        if (!cell.hyperlink) break :hyperlink;
        const sel = terminal.Selection.init(mouse_pin, mouse_pin, false);
        return .{ .action = ._open_osc8, .selection = sel };
    }
    return try self.linkAtPin(mouse_pin, mouse_mods);
}
fn linkAtPin(
    self: *Surface,
    mouse_pin: terminal.Pin,
    mouse_mods: ?input.Mods,
) !?Link {
    if (self.config.links.len == 0) return null;
    const screen: *terminal.Screen = self.renderer_state.terminal.screens.active;
    const line = screen.selectLine(.{
        .pin = mouse_pin,
        .whitespace = null,
        .semantic_prompt_boundary = true,
    }) orelse return null;
    const strmap = try screen.selectionStringMap(self.alloc, .{
        .sel = line,
        .trim = false,
    });
    defer strmap.deinit(self.alloc);
    for (self.config.links) |link| {
        if (mouse_mods) |mods| switch (link.highlight) {
            .always, .hover => {},
            .always_mods, .hover_mods => |v| if (!v.equal(mods)) continue,
        };
        var it = strmap.searchIterator(link.regex);
        while (true) {
            var match = (try it.next()) orelse break;
            defer match.deinit();
            const sel = match.selection();
            if (!sel.contains(screen, mouse_pin)) continue;
            return .{
                .action = link.action,
                .selection = sel,
            };
        }
    }
    return null;
}
fn mouseModsWithCapture(self: *Surface, mods: input.Mods) input.Mods {
    if (self.io.terminal.flags.mouse_event == .none) return mods;
    if (!mods.shift) return mods;
    if (self.mouseShiftCapture(false)) return mods;
    var final = mods;
    final.shift = false;
    return final;
}
fn processLinks(self: *Surface, pos: apprt.CursorPos) !bool {
    const link = try self.linkAtPos(pos) orelse return false;
    switch (link.action) {
        .open => {
            const str = try self.io.terminal.screens.active.selectionString(self.alloc, .{
                .sel = link.selection,
                .trim = false,
            });
            defer self.alloc.free(str);
            const resolved_path = try self.resolvePathForOpening(str);
            defer if (resolved_path) |p| self.alloc.free(p);
            const url_to_open = resolved_path orelse str;
            try self.openUrl(.{ .kind = .unknown, .url = url_to_open });
        },
        ._open_osc8 => {
            const uri = self.osc8URI(link.selection.start()) orelse {
                log.warn("failed to get URI for OSC8 hyperlink", .{});
                return false;
            };
            try self.openUrl(.{ .kind = .osc8, .url = uri });
        },
    }
    return true;
}
fn openUrl(
    self: *Surface,
    action: apprt.action.OpenUrl,
) !void {
    if (try self.rt_app.performAction(
        .{ .surface = self },
        .open_url,
        action,
    )) return;
    log.warn("apprt did not handle open URL action, falling back to default opener", .{});
    try internal_os.open(
        action.kind,
        action.url,
    );
}
fn osc8URI(self: *Surface, pin: terminal.Pin) ?[]const u8 {
    _ = self;
    const page = pin.node.page();
    const cell = pin.rowAndCell().cell;
    const link_id = page.lookupHyperlink(cell) orelse return null;
    const entry = page.hyperlink_set.get(page.memory, link_id);
    return entry.uri.slice(page.memory);
}
pub fn mousePressureCallback(
    self: *Surface,
    stage: input.MousePressureStage,
    pressure: f64,
) !void {
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;
    _ = pressure;
    if (self.mouse.pressure_stage == stage) return;
    self.mouse.pressure_stage = stage;
    const left_idx = @intFromEnum(input.MouseButton.left);
    if (self.mouse.click_state[left_idx] == .press and
        stage == .deep)
    select: {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        const sel = self.mouse.selection_gesture.deepPress(
            self.renderer_state.terminal,
            .{ .word_boundary_codepoints = self.config.selection_word_chars },
        );
        if (self.selection_scroll_active) {
            self.queueIo(
                .{ .selection_scroll = false },
                .locked,
            );
        }
        try self.setSelection(sel orelse break :select);
        try self.queueRender();
    }
}
pub fn cursorPosCallback(
    self: *Surface,
    pos: apprt.CursorPos,
    mods: ?input.Mods,
) !void {
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;
    if (pos.x < 0 or pos.y < 0) {
        self.mouse.link_point = null;
        if (self.mouse.over_link) {
            self.mouse.over_link = false;
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .mouse_shape,
                self.io.terminal.mouse_shape,
            );
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .mouse_over_link,
                .{ .url = "" },
            );
            try self.queueRender();
        }
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        self.renderer_state.mouse.point = null;
        self.renderer_state.terminal.screens.active.dirty.hyperlink_hover = true;
    }
    if (self.mouse.hidden) self.showMouse();
    if (mods) |v| self.modsChanged(v);
    const pos_vp = self.posToViewport(pos.x, pos.y);
    const over_link = self.mouse.over_link;
    self.mouse.over_link = false;
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    self.renderer_state.mouse.point = null;
    if (self.inspector) |insp| {
        insp.mouse.last_xpos = pos.x;
        insp.mouse.last_ypos = pos.y;
        const screen: *terminal.Screen = self.renderer_state.terminal.screens.active;
        insp.mouse.last_point = screen.pages.pin(.{ .viewport = .{
            .x = pos_vp.x,
            .y = pos_vp.y,
        } });
        try self.queueRender();
    }
    if ((over_link or
        self.mouse.link_point == null or
        (self.mouse.link_point != null and !self.mouse.link_point.?.eql(pos_vp))) and
        (self.io.terminal.flags.mouse_event == .none or
            (self.mouse.mods.shift and !self.mouseShiftCapture(false))))
    {
        try self.mouseRefreshLinks(pos, pos_vp, over_link);
    }
    if (self.isMouseReporting()) report: {
        if (self.mouse.mods.shift and !self.mouseShiftCapture(false)) {
            for (self.mouse.click_state) |state| {
                if (state != .release) break :report;
            }
        }
        const button: ?input.MouseButton = button: for (self.mouse.click_state, 0..) |state, i| {
            if (state == .press)
                break :button @enumFromInt(i);
        } else null;
        self.mouseReport(button, .motion, self.mouse.mods, pos);
        return;
    }
    if (self.mouse.click_state[@intFromEnum(input.MouseButton.left)] == .press) select: {
        if (self.mouse.selection_gesture.left_click_count == 0) break :select;
        const t: *terminal.Terminal = self.renderer_state.terminal;
        if (self.mouse.activeLeftClickPin(&t.screens) == null) break :select;
        try self.queueRender();
        const screen: *terminal.Screen = t.screens.active;
        const pin = screen.pages.pin(.{
            .viewport = .{
                .x = pos_vp.x,
                .y = pos_vp.y,
            },
        }) orelse {
            if (comptime std.debug.runtime_safety) unreachable;
            return;
        };
        const drag_selection = self.mouse.selection_gesture.drag(t, .{
            .pin = pin,
            .xpos = pos.x,
            .ypos = pos.y,
            .rectangle = SurfaceMouse.isRectangleSelectState(self.mouse.mods),
            .word_boundary_codepoints = self.config.selection_word_chars,
            .geometry = .{
                .columns = @intCast(self.size.grid().columns),
                .cell_width = self.size.cell.width,
                .padding_left = self.size.padding.left,
                .screen_height = self.size.screen.height,
            },
        });
        switch (self.mouse.selection_gesture.left_drag_autoscroll) {
            .none => if (self.selection_scroll_active) {
                self.queueIo(
                    .{ .selection_scroll = false },
                    .locked,
                );
            },
            .up, .down => if (!self.selection_scroll_active) {
                self.queueIo(
                    .{ .selection_scroll = true },
                    .locked,
                );
            },
        }
        try self.setSelection(drag_selection);
    }
}
pub fn colorSchemeCallback(self: *Surface, scheme: apprt.ColorScheme) !void {
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;
    const new_scheme: configpkg.ConditionalState.Theme = switch (scheme) {
        .light => .light,
        .dark => .dark,
    };
    if (self.config_conditional_state.theme == new_scheme) return;
    self.config_conditional_state.theme = new_scheme;
    self.notifyConfigConditionalState();
    self.queueIo(.{ .color_scheme_report = .{ .force = false } }, .unlocked);
}
pub fn posToViewport(self: Surface, xpos: f64, ypos: f64) terminal.point.Coordinate {
    const coord: rendererpkg.Coordinate = .{ .surface = .{ .x = xpos, .y = ypos } };
    const grid = coord.convert(.grid, self.size).grid;
    return .{ .x = grid.x, .y = grid.y };
}
fn scrollToBottom(self: *Surface) !void {
    self.io.terminal.scrollViewport(.{ .bottom = {} });
    try self.queueRender();
}
fn hideMouse(self: *Surface) void {
    if (self.mouse.hidden) return;
    self.mouse.hidden = true;
    _ = self.rt_app.performAction(
        .{ .surface = self },
        .mouse_visibility,
        .hidden,
    ) catch |err| {
        log.warn("apprt failed to set mouse visibility err={}", .{err});
    };
}
fn showMouse(self: *Surface) void {
    if (!self.mouse.hidden) return;
    self.mouse.hidden = false;
    _ = self.rt_app.performAction(
        .{ .surface = self },
        .mouse_visibility,
        .visible,
    ) catch |err| {
        log.warn("apprt failed to set mouse visibility err={}", .{err});
    };
}
pub fn performBindingAction(self: *Surface, action: input.Binding.Action) !bool {
    if (action.scoped(.app)) |app_action| {
        switch (app_action) {
            .new_window => try self.app.newWindow(
                self.rt_app,
                .{ .parent = self },
            ),
            .undo => return try self.rt_app.performAction(
                .{ .surface = self },
                .undo,
                {},
            ),
            .redo => return try self.rt_app.performAction(
                .{ .surface = self },
                .redo,
                {},
            ),
            else => try self.app.performAction(
                self.rt_app,
                action.scoped(.app).?,
            ),
        }
        return true;
    }
    switch (action.scoped(.surface).?) {
        .csi, .esc => |data| {
            var buf: [128]u8 = undefined;
            const full_data = switch (action) {
                .csi => try std.fmt.bufPrint(&buf, "\x1b[{s}", .{data}),
                .esc => try std.fmt.bufPrint(&buf, "\x1b{s}", .{data}),
                else => unreachable,
            };
            self.queueIo(try termio.Message.writeReq(
                self.alloc,
                full_data,
            ), .unlocked);
            {
                self.renderer_state.mutex.lockUncancelable(global.io());
                defer self.renderer_state.mutex.unlock(global.io());
                self.scrollToBottom() catch |err| {
                    log.warn("error scrolling to bottom err={}", .{err});
                };
            }
        },
        .text => |data| {
            var stack = std.heap.stackFallback(256, self.alloc);
            const alloc = stack.get();
            const buf = try alloc.alloc(u8, data.len);
            defer alloc.free(buf);
            const text = configpkg.string.parse(buf, data) catch |err| {
                log.warn(
                    "error parsing text binding text={s} err={}",
                    .{ data, err },
                );
                return true;
            };
            self.queueIo(try termio.Message.writeReq(
                self.alloc,
                text,
            ), .unlocked);
            {
                self.renderer_state.mutex.lockUncancelable(global.io());
                defer self.renderer_state.mutex.unlock(global.io());
                self.scrollToBottom() catch |err| {
                    log.warn("error scrolling to bottom err={}", .{err});
                };
            }
        },
        .cursor_key => |ck| {
            const normal = normal: {
                self.renderer_state.mutex.lockUncancelable(global.io());
                defer self.renderer_state.mutex.unlock(global.io());
                self.scrollToBottom() catch |err| {
                    log.warn("error scrolling to bottom err={}", .{err});
                };
                break :normal !self.io.terminal.modes.get(.cursor_keys);
            };
            if (normal) {
                self.queueIo(.{ .write_stable = ck.normal }, .unlocked);
            } else {
                self.queueIo(.{ .write_stable = ck.application }, .unlocked);
            }
        },
        .reset => {
            self.renderer_state.mutex.lockUncancelable(global.io());
            defer self.renderer_state.mutex.unlock(global.io());
            self.renderer_state.terminal.fullReset();
        },
        .start_search => {
            return try self.rt_app.performAction(
                .{ .surface = self },
                .start_search,
                .{ .needle = "" },
            );
        },
        .search_selection => {
            const selection = try self.selectionString(self.alloc) orelse return false;
            defer self.alloc.free(selection);
            return try self.rt_app.performAction(
                .{ .surface = self },
                .start_search,
                .{ .needle = selection },
            );
        },
        .end_search => {
            const performed = self.search != null;
            if (self.search) |*s| {
                s.deinit();
                self.search = null;
            }
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .end_search,
                {},
            );
            return performed;
        },
        .search => |text| search: {
            const s: *Search = if (self.search) |*s| s else init: {
                if (text.len == 0) return false;
                self.search = .{
                    .state = try .init(self.alloc, .{
                        .mutex = self.renderer_state.mutex,
                        .terminal = self.renderer_state.terminal,
                        .event_cb = &searchCallback,
                        .event_userdata = self,
                    }),
                    .thread = undefined,
                };
                const s: *Search = &self.search.?;
                errdefer s.state.deinit();
                s.thread = try .spawn(
                    .{},
                    terminal.search.Thread.threadMain,
                    .{&s.state},
                );
                s.thread.setName(global.io(), "search") catch {};
                break :init s;
            };
            if (text.len == 0) {
                s.deinit();
                self.search = null;
                break :search;
            }
            _ = s.state.mailbox.push(
                global.io(),
                .{ .change_needle = try .init(
                    self.alloc,
                    text,
                ) },
                .forever,
            );
            s.state.wakeup.notify() catch {};
        },
        .navigate_search => |nav| {
            const s: *Search = if (self.search) |*s| s else return false;
            _ = s.state.mailbox.push(
                global.io(),
                .{ .select = switch (nav) {
                    .next => .next,
                    .previous => .prev,
                } },
                .forever,
            );
            s.state.wakeup.notify() catch {};
        },
        .copy_to_clipboard => |format| {
            self.renderer_state.mutex.lockUncancelable(global.io());
            defer self.renderer_state.mutex.unlock(global.io());
            if (self.io.terminal.screens.active.selection) |sel| {
                try self.copySelectionToClipboards(
                    sel,
                    &.{.standard},
                    format,
                );
                if (self.config.selection_clear_on_copy) {
                    if (self.setSelection(null)) {
                        self.queueRender() catch |err| {
                            log.warn("failed to queue render after clear selection err={}", .{err});
                        };
                    } else |err| {
                        log.warn("failed to clear selection after copy err={}", .{err});
                    }
                }
                return true;
            }
            return false;
        },
        .copy_url_to_clipboard => {
            if (!self.mouse.over_link) return false;
            const pos = try self.rt_surface.getCursorPos();
            self.renderer_state.mutex.lockUncancelable(global.io());
            defer self.renderer_state.mutex.unlock(global.io());
            if (try self.linkAtPos(pos)) |link_info| {
                const url_text = switch (link_info.action) {
                    .open => url_text: {
                        break :url_text (self.io.terminal.screens.active.selectionString(self.alloc, .{
                            .sel = link_info.selection,
                            .trim = self.config.clipboard_trim_trailing_spaces,
                        })) catch |err| {
                            log.err("error reading url string err={}", .{err});
                            return false;
                        };
                    },
                    ._open_osc8 => url_text: {
                        const uri = self.osc8URI(link_info.selection.start()) orelse {
                            log.warn("failed to get URI for OSC8 hyperlink", .{});
                            return false;
                        };
                        break :url_text try self.alloc.dupeZ(u8, uri);
                    },
                };
                defer self.alloc.free(url_text);
                self.rt_surface.setClipboard(.standard, &.{.{
                    .mime = "text/plain",
                    .data = url_text,
                }}, false) catch |err| {
                    log.err("error copying url to clipboard err={}", .{err});
                    return false;
                };
                return true;
            }
            return false;
        },
        .copy_title_to_clipboard => return try self.rt_app.performAction(
            .{ .surface = self },
            .copy_title_to_clipboard,
            {},
        ),
        .paste_from_clipboard => return (try self.startClipboardRequest(
            .standard,
            .{ .paste = .standard },
        )) == .started,
        .paste_from_selection => return (try self.startClipboardRequest(
            .selection,
            .{ .paste = .selection },
        )) == .started,
        .increase_font_size => |delta| {
            const clamped_delta = @max(0, @min(255, delta));
            log.debug("increase font size={}", .{clamped_delta});
            var size = self.font_size;
            size.points = @min(size.points + clamped_delta, 255);
            try self.setFontSize(size);
            self.font_size_adjusted = true;
        },
        .decrease_font_size => |delta| {
            const clamped_delta = @max(0, @min(255, delta));
            log.debug("decrease font size={}", .{clamped_delta});
            var size = self.font_size;
            size.points = @max(1, size.points - clamped_delta);
            try self.setFontSize(size);
            self.font_size_adjusted = true;
        },
        .reset_font_size => {
            log.debug("reset font size", .{});
            var size = self.font_size;
            size.points = self.config.original_font_size;
            try self.setFontSize(size);
            self.font_size_adjusted = false;
        },
        .set_font_size => |points| {
            log.debug("set font size={d}", .{points});
            var size = self.font_size;
            size.points = std.math.clamp(points, 1.0, 255.0);
            try self.setFontSize(size);
            self.font_size_adjusted = true;
        },
        .prompt_surface_title => return try self.rt_app.performAction(
            .{ .surface = self },
            .prompt_title,
            .surface,
        ),
        .prompt_tab_title => return try self.rt_app.performAction(
            .{ .surface = self },
            .prompt_title,
            .tab,
        ),
        .prompt_window_title => return try self.rt_app.performAction(
            .{ .surface = self },
            .prompt_title,
            .window,
        ),
        .set_surface_title => |v| {
            const title = try self.alloc.dupeZ(u8, v);
            defer self.alloc.free(title);
            return try self.rt_app.performAction(
                .{ .surface = self },
                .set_title,
                .{ .title = title },
            );
        },
        .set_tab_title => |v| {
            const title = try self.alloc.dupeZ(u8, v);
            defer self.alloc.free(title);
            return try self.rt_app.performAction(
                .{ .surface = self },
                .set_tab_title,
                .{ .title = title },
            );
        },
        .set_window_title => |v| {
            const title = try self.alloc.dupeZ(u8, v);
            defer self.alloc.free(title);
            return try self.rt_app.performAction(
                .{ .surface = self },
                .set_window_title,
                .{ .title = title },
            );
        },
        .clear_screen => {
            {
                self.renderer_state.mutex.lockUncancelable(global.io());
                defer self.renderer_state.mutex.unlock(global.io());
                if (self.io.terminal.screens.active_key == .alternate) return false;
            }
            self.queueIo(.{
                .clear_screen = .{ .history = true },
            }, .unlocked);
        },
        .scroll_to_top => {
            self.queueIo(.{
                .scroll_viewport = .{ .top = {} },
            }, .unlocked);
        },
        .scroll_to_bottom => {
            self.queueIo(.{
                .scroll_viewport = .{ .bottom = {} },
            }, .unlocked);
        },
        .scroll_to_row => |n| {
            {
                self.renderer_state.mutex.lockUncancelable(global.io());
                defer self.renderer_state.mutex.unlock(global.io());
                const t: *terminal.Terminal = self.renderer_state.terminal;
                t.screens.active.scroll(.{ .row = n });
            }
            try self.queueRender();
        },
        .scroll_to_selection => {
            {
                self.renderer_state.mutex.lockUncancelable(global.io());
                defer self.renderer_state.mutex.unlock(global.io());
                const sel = self.io.terminal.screens.active.selection orelse return false;
                const tl = sel.topLeft(self.io.terminal.screens.active);
                self.io.terminal.screens.active.scroll(.{ .pin = tl });
            }
            try self.queueRender();
        },
        .scroll_page_up => {
            const rows: isize = @intCast(self.size.grid().rows);
            self.queueIo(.{
                .scroll_viewport = .{ .delta = -1 * rows },
            }, .unlocked);
        },
        .scroll_page_down => {
            const rows: isize = @intCast(self.size.grid().rows);
            self.queueIo(.{
                .scroll_viewport = .{ .delta = rows },
            }, .unlocked);
        },
        .scroll_page_fractional => |fraction| {
            const rows: f32 = @floatFromInt(self.size.grid().rows);
            const delta: isize = @intFromFloat(@trunc(fraction * rows));
            self.queueIo(.{
                .scroll_viewport = .{ .delta = delta },
            }, .unlocked);
        },
        .scroll_page_lines => |lines| {
            self.queueIo(.{
                .scroll_viewport = .{ .delta = lines },
            }, .unlocked);
        },
        .jump_to_prompt => |delta| {
            self.queueIo(.{
                .jump_to_prompt = @intCast(delta),
            }, .unlocked);
        },
        .write_screen_file => |v| try self.writeScreenFile(
            .screen,
            v,
        ),
        .write_scrollback_file => |v| try self.writeScreenFile(
            .history,
            v,
        ),
        .write_selection_file => |v| try self.writeScreenFile(
            .selection,
            v,
        ),
        .new_tab => return try self.rt_app.performAction(
            .{ .surface = self },
            .new_tab,
            {},
        ),
        .close_tab => |v| return try self.rt_app.performAction(
            .{ .surface = self },
            .close_tab,
            switch (v) {
                .this => .this,
                .other => .other,
                .right => .right,
            },
        ),
        inline .previous_tab,
        .next_tab,
        .last_tab,
        .goto_tab,
        => |v, tag| return try self.rt_app.performAction(
            .{ .surface = self },
            .goto_tab,
            switch (tag) {
                .previous_tab => .previous,
                .next_tab => .next,
                .last_tab => .last,
                .goto_tab => @enumFromInt(v),
                else => comptime unreachable,
            },
        ),
        .move_tab => |position| return try self.rt_app.performAction(
            .{ .surface = self },
            .move_tab,
            .{ .amount = position },
        ),
        .move_tab_to_new_window => return try self.rt_app.performAction(
            .{ .surface = self },
            .move_tab_to_new_window,
            {},
        ),
        .new_split => |direction| return try self.rt_app.performAction(
            .{ .surface = self },
            .new_split,
            switch (direction) {
                .right => .right,
                .left => .left,
                .down => .down,
                .up => .up,
                .auto => if (self.size.screen.width > self.size.screen.height)
                    .right
                else
                    .down,
            },
        ),
        .goto_split => |direction| return try self.rt_app.performAction(
            .{ .surface = self },
            .goto_split,
            switch (direction) {
                inline else => |tag| @field(
                    apprt.action.GotoSplit,
                    @tagName(tag),
                ),
            },
        ),
        .goto_window => |direction| return try self.rt_app.performAction(
            .{ .surface = self },
            .goto_window,
            switch (direction) {
                .previous => .previous,
                .next => .next,
            },
        ),
        .resize_split => |value| return try self.rt_app.performAction(
            .{ .surface = self },
            .resize_split,
            .{
                .amount = value[1],
                .direction = switch (value[0]) {
                    inline else => |tag| @field(
                        apprt.action.ResizeSplit.Direction,
                        @tagName(tag),
                    ),
                },
            },
        ),
        .equalize_splits => return try self.rt_app.performAction(
            .{ .surface = self },
            .equalize_splits,
            {},
        ),
        .toggle_split_zoom => return try self.rt_app.performAction(
            .{ .surface = self },
            .toggle_split_zoom,
            {},
        ),
        .toggle_readonly => {
            self.readonly = !self.readonly;
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .readonly,
                if (self.readonly) .on else .off,
            );
            return true;
        },
        .reset_window_size => return try self.rt_app.performAction(
            .{ .surface = self },
            .reset_window_size,
            {},
        ),
        .toggle_maximize => return try self.rt_app.performAction(
            .{ .surface = self },
            .toggle_maximize,
            {},
        ),
        .toggle_fullscreen => return try self.rt_app.performAction(
            .{ .surface = self },
            .toggle_fullscreen,
            switch (self.config.macos_non_native_fullscreen) {
                .false => .native,
                .true => .macos_non_native,
                .@"visible-menu" => .macos_non_native_visible_menu,
                .@"padded-notch" => .macos_non_native_padded_notch,
            },
        ),
        .toggle_window_decorations => return try self.rt_app.performAction(
            .{ .surface = self },
            .toggle_window_decorations,
            {},
        ),
        .toggle_tab_overview => return try self.rt_app.performAction(
            .{ .surface = self },
            .toggle_tab_overview,
            {},
        ),
        .toggle_window_float_on_top => return try self.rt_app.performAction(
            .{ .surface = self },
            .float_window,
            .toggle,
        ),
        .toggle_secure_input => return try self.rt_app.performAction(
            .{ .surface = self },
            .secure_input,
            .toggle,
        ),
        .toggle_mouse_reporting => {
            self.config.mouse_reporting = !self.config.mouse_reporting;
            log.debug("mouse reporting toggled: {}", .{self.config.mouse_reporting});
        },
        .toggle_command_palette => return try self.rt_app.performAction(
            .{ .surface = self },
            .toggle_command_palette,
            {},
        ),
        .toggle_background_opacity => return try self.rt_app.performAction(
            .{ .surface = self },
            .toggle_background_opacity,
            {},
        ),
        .show_on_screen_keyboard => return try self.rt_app.performAction(
            .{ .surface = self },
            .show_on_screen_keyboard,
            {},
        ),
        .select_all => {
            self.renderer_state.mutex.lockUncancelable(global.io());
            defer self.renderer_state.mutex.unlock(global.io());
            const sel = self.io.terminal.screens.active.selectAll();
            if (sel) |s| {
                try self.setSelectionAndCopy(s);
                try self.queueRender();
            }
        },
        .inspector => |mode| return try self.rt_app.performAction(
            .{ .surface = self },
            .inspector,
            switch (mode) {
                inline else => |tag| @field(
                    apprt.action.Inspector,
                    @tagName(tag),
                ),
            },
        ),
        .close_surface => self.close(),
        .close_window => return try self.rt_app.performAction(
            .{ .surface = self },
            .close_window,
            {},
        ),
        inline .activate_key_table,
        .activate_key_table_once,
        => |name, tag| {
            const set = self.config.keybind.tables.getPtr(name) orelse {
                log.debug("key table not found: {s}", .{name});
                return false;
            };
            if (self.keyboard.table_stack.items.len > 0) {
                const items = self.keyboard.table_stack.items;
                const active = items[items.len - 1].set;
                if (active == set) {
                    log.debug("ignoring duplicate activate table: {s}", .{name});
                    return false;
                }
            }
            if (self.keyboard.table_stack.items.len >= max_active_key_tables) {
                log.info(
                    "ignoring activate table, max depth reached: {s}",
                    .{name},
                );
                return false;
            }
            try self.keyboard.table_stack.append(self.alloc, .{
                .set = set,
                .once = tag == .activate_key_table_once,
            });
            _ = self.rt_app.performAction(
                .{ .surface = self },
                .key_table,
                .{ .activate = name },
            ) catch |err| {
                log.warn(
                    "failed to notify app of key table err={}",
                    .{err},
                );
            };
            log.debug("key table activated: {s}", .{name});
        },
        .deactivate_key_table => {
            switch (self.keyboard.table_stack.items.len) {
                0 => return false,
                1 => self.keyboard.table_stack.clearAndFree(self.alloc),
                else => _ = self.keyboard.table_stack.pop(),
            }
            _ = self.rt_app.performAction(
                .{ .surface = self },
                .key_table,
                .deactivate,
            ) catch |err| {
                log.warn(
                    "failed to notify app of key table err={}",
                    .{err},
                );
            };
        },
        .deactivate_all_key_tables => {
            return try self.deactivateAllKeyTables();
        },
        .end_key_sequence => {
            self.endKeySequence(.flush, .retain);
        },
        .crash => |location| switch (location) {
            .main => @panic("crash binding action, crashing intentionally"),
            .render => {
                _ = self.renderer_thread.mailbox.push(global.io(), .{ .crash = {} }, .{ .forever = {} });
                self.queueRender() catch |err| {
                    log.warn("failed to notify renderer of crash message err={}", .{err});
                };
            },
            .io => self.queueIo(.{ .crash = {} }, .unlocked),
        },
        .adjust_selection => |direction| {
            self.renderer_state.mutex.lockUncancelable(global.io());
            defer self.renderer_state.mutex.unlock(global.io());
            const screen: *terminal.Screen = self.io.terminal.screens.active;
            const sel = if (screen.selection) |*sel| sel else {
                return false;
            };
            sel.adjust(screen, switch (direction) {
                .left => .left,
                .right => .right,
                .up => .up,
                .down => .down,
                .page_up => .page_up,
                .page_down => .page_down,
                .home => .home,
                .end => .end,
                .beginning_of_line => .beginning_of_line,
                .end_of_line => .end_of_line,
            });
            scroll: {
                const viewport_tl = screen.pages.getTopLeft(.viewport);
                const viewport_br = screen.pages.getBottomRight(.viewport).?;
                if (sel.end().isBetween(viewport_tl, viewport_br))
                    break :scroll;
                const target = if (sel.end().before(viewport_tl))
                    sel.end()
                else
                    sel.end().up(screen.pages.rows - 1) orelse sel.end();
                screen.scroll(.{ .pin = target });
            }
            screen.dirty.selection = true;
            try self.queueRender();
        },
    }
    return true;
}
fn closingAction(action: input.Binding.Action) bool {
    return switch (action) {
        .close_surface,
        .close_window,
        .close_tab,
        => true,
        else => false,
    };
}
const WriteScreenLoc = enum {
    screen,
    history,
    selection,
};
fn writeScreenFile(
    self: *Surface,
    loc: WriteScreenLoc,
    write_screen: input.Binding.Action.WriteScreen,
) !void {
    var tmp_dir = try internal_os.TempDir.init();
    var retain_tmp_dir = false;
    defer if (retain_tmp_dir) tmp_dir.close(.retain) else tmp_dir.deinit();
    var filename_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const filename = try std.fmt.bufPrint(
        &filename_buf,
        "{s}.{s}",
        .{
            @tagName(loc),
            switch (write_screen.emit) {
                .plain, .vt => "txt",
                .html => "html",
            },
        },
    );
    var file = try tmp_dir.dir.createFile(
        global.io(),
        filename,
        switch (builtin.os.tag) {
            .windows => .{},
            else => .{ .permissions = .fromMode(0o600) },
        },
    );
    defer file.close(global.io());
    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(global.io(), &buf);
    var buf_writer = &file_writer.interface;
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        const pages = &self.io.terminal.screens.active.pages;
        const sel_: ?terminal.Selection = switch (loc) {
            .history => history: {
                if (self.io.terminal.screens.active_key == .alternate) {
                    break :history null;
                }
                break :history terminal.Selection.init(
                    pages.getTopLeft(.history),
                    pages.getBottomRight(.history) orelse
                        break :history null,
                    false,
                );
            },
            .screen => screen: {
                break :screen terminal.Selection.init(
                    pages.getTopLeft(.screen),
                    pages.getBottomRight(.screen) orelse
                        break :screen null,
                    false,
                );
            },
            .selection => self.io.terminal.screens.active.selection,
        };
        const sel = sel_ orelse {
            return;
        };
        const ScreenFormatter = terminal.formatter.ScreenFormatter;
        var formatter: ScreenFormatter = .init(self.io.terminal.screens.active, .{
            .emit = switch (write_screen.emit) {
                .plain => .plain,
                .vt => .vt,
                .html => .html,
            },
            .unwrap = true,
            .trim = false,
            .background = self.io.terminal.colors.background.get(),
            .foreground = self.io.terminal.colors.foreground.get(),
            .palette = &self.io.terminal.colors.palette.current,
        });
        formatter.content = .{ .selection = sel.ordered(
            self.io.terminal.screens.active,
            .forward,
        ) };
        try formatter.format(buf_writer);
    }
    try buf_writer.flush();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try tmp_dir.dir.realPathFile(
        global.io(),
        filename,
        &path_buf,
    )];
    switch (write_screen.action) {
        .copy => {
            const pathZ = try self.alloc.dupeZ(u8, path);
            defer self.alloc.free(pathZ);
            try self.rt_surface.setClipboard(.standard, &.{.{
                .mime = "text/plain",
                .data = pathZ,
            }}, false);
        },
        .open => try self.openUrl(.{
            .kind = switch (write_screen.emit) {
                .plain, .vt => .text,
                .html => .html,
            },
            .url = path,
        }),
        .paste => self.queueIo(try termio.Message.writeReq(
            self.alloc,
            path,
        ), .unlocked),
    }
    retain_tmp_dir = true;
}
pub const CompleteClipboard = struct {
    contents: []const terminal.clipboard.Content = &.{},
    available: []const []const u8 = &.{},
    confirmed: bool = false,
    remember: bool = false,
};
pub fn completeClipboardRequest(
    self: *Surface,
    req: apprt.ClipboardRequest,
    complete: CompleteClipboard,
) !void {
    switch (req) {
        .paste => try self.completeClipboardPaste(
            clipboardTextContent(complete.contents) orelse "",
            complete.confirmed,
        ),
        .list => |clipboard| if (!try self.completeClipboardPasteEvent(
            clipboard,
            complete.available,
        )) {
            log.debug("mode 5522 paste event was not written", .{});
        },
        .osc_52_read => |clipboard| try self.completeClipboardReadOSC52(
            clipboardTextContent(complete.contents) orelse "",
            clipboard,
            complete.confirmed,
        ),
        .osc_52_write => |clipboard| {
            const data = try self.alloc.dupeZ(
                u8,
                clipboardTextContent(complete.contents) orelse "",
            );
            defer self.alloc.free(data);
            try self.rt_surface.setClipboard(clipboard, &.{.{
                .mime = "text/plain",
                .data = data,
            }}, !complete.confirmed);
        },
        .kitty_read => |kitty| {
            if (self.config.clipboard_read == .ask and
                !complete.confirmed and
                !kitty.granted and
                !terminal.kitty.clipboard.readPromptExempt(kitty.mimes.len))
            {
                return error.UnauthorizedPaste;
            }
            defer kitty.destroy();
            if (complete.remember and kitty.pw.len > 0) {
                const pw = try self.alloc.dupe(u8, kitty.pw);
                self.queueIo(.{ .kitty_clipboard_grant_read = .{
                    .alloc = self.alloc,
                    .pw = pw,
                } }, .unlocked);
            }
            try self.completeKittyClipboardRead(
                kitty,
                complete.contents,
                complete.available,
            );
        },
        .kitty_write => |kitty| {
            if (self.config.clipboard_write == .ask and
                !complete.confirmed and
                !kitty.granted)
            {
                return error.UnauthorizedPaste;
            }
            defer kitty.destroy();
            if (complete.remember and kitty.pw.len > 0) {
                const pw = try self.alloc.dupe(u8, kitty.pw);
                self.queueIo(.{ .kitty_clipboard_grant_write = .{
                    .alloc = self.alloc,
                    .pw = pw,
                } }, .unlocked);
            }
            self.rt_surface.setClipboard(
                kitty.location,
                if (kitty.contents.len > 0) kitty.contents else &.{.{
                    .mime = "text/plain",
                    .data = "",
                }},
                false,
            ) catch |err| {
                log.err("error setting clipboard err={}", .{err});
                try self.kittyClipboardStatus(
                    .write,
                    kitty.id,
                    kitty.terminator,
                    .EIO,
                );
                return;
            };
            try self.kittyClipboardStatus(
                .write,
                kitty.id,
                kitty.terminator,
                .DONE,
            );
        },
    }
}
fn clipboardTextContent(contents: []const terminal.clipboard.Content) ?[]const u8 {
    for (contents) |content| {
        if (terminal.clipboard.isTextMime(content.mime)) return content.data;
    }
    return null;
}
pub fn denyClipboardRequest(self: *Surface, req: apprt.ClipboardRequest) void {
    switch (req) {
        .paste, .list => {},
        .osc_52_read => |clipboard| self.completeClipboardReadOSC52(
            "",
            clipboard,
            true,
        ) catch |err| {
            log.warn("error replying to OSC 52 clipboard read err={}", .{err});
        },
        .osc_52_write => {},
        .kitty_read => |kitty| {
            defer kitty.destroy();
            self.kittyClipboardStatus(
                .read,
                kitty.id,
                kitty.terminator,
                .EPERM,
            ) catch |err| {
                log.warn("error replying to kitty clipboard read err={}", .{err});
            };
        },
        .kitty_write => |kitty| {
            defer kitty.destroy();
            self.kittyClipboardStatus(
                .write,
                kitty.id,
                kitty.terminator,
                .EPERM,
            ) catch |err| {
                log.warn("error replying to kitty clipboard write err={}", .{err});
            };
        },
    }
}
fn startClipboardRequest(
    self: *Surface,
    loc: apprt.Clipboard,
    req: apprt.ClipboardRequest,
) !apprt.ClipboardReadResult {
    const effective_req: apprt.ClipboardRequest = switch (req) {
        .paste => |clipboard| effective: {
            self.renderer_state.mutex.lockUncancelable(global.io());
            const event = self.io.terminal.modes.get(.kitty_paste_events);
            self.renderer_state.mutex.unlock(global.io());
            break :effective if (event)
                .{ .list = clipboard }
            else
                req;
        },
        else => req,
    };
    switch (effective_req) {
        .paste, .list => {},
        .osc_52_read => if (self.config.clipboard_read == .deny) {
            log.info(
                "application attempted to read clipboard, but 'clipboard-read' is set to deny",
                .{},
            );
            return .unsupported;
        },
        .kitty_read, .kitty_write => {},
        .osc_52_write => unreachable,
    }
    return try self.rt_surface.clipboardRequest(loc, effective_req);
}
fn completeClipboardPaste(
    self: *Surface,
    data: []const u8,
    allow_unsafe: bool,
) !void {
    if (data.len == 0) return;
    const encode_opts: input.paste.Options = encode_opts: {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        const opts: input.paste.Options = .fromTerminal(&self.io.terminal);
        const unsafe = unsafe: {
            if (!self.config.clipboard_paste_protection) break :unsafe false;
            if (allow_unsafe) break :unsafe false;
            if (opts.bracketed) {
                if (std.mem.indexOf(u8, data, "\x1B[201~") != null) break :unsafe true;
                if (self.config.clipboard_paste_bracketed_safe) break :unsafe false;
            }
            break :unsafe !input.paste.isSafe(data);
        };
        if (unsafe) {
            log.info("potentially unsafe paste detected, rejecting until confirmation", .{});
            return error.UnsafePaste;
        }
        self.scrollToBottom() catch |err| {
            log.warn("error scrolling to bottom err={}", .{err});
        };
        break :encode_opts opts;
    };
    var data_duped: ?[]u8 = null;
    const vecs = input.paste.encode(data, encode_opts) catch |err| switch (err) {
        error.MutableRequired => vecs: {
            const buf: []u8 = try self.alloc.dupe(u8, data);
            errdefer self.alloc.free(buf);
            data_duped = buf;
            break :vecs input.paste.encode(buf, encode_opts);
        },
    };
    defer if (data_duped) |v| {
        self.alloc.free(v);
    };
    for (vecs) |vec| if (vec.len > 0) {
        self.queueIo(try termio.Message.writeReq(
            self.alloc,
            vec,
        ), .unlocked);
    };
}
fn completeClipboardPasteEvent(
    self: *Surface,
    clipboard: apprt.Clipboard,
    available: []const []const u8,
) !bool {
    if (self.readonly) return false;
    const kitty_clipboard = terminal.kitty.clipboard;
    const location: terminal.clipboard.Location = switch (clipboard) {
        .standard => .standard,
        .selection => .selection,
        .primary => .primary,
    };
    var contents_buf: [kitty_clipboard.max_listing_mimes]terminal.clipboard.Content = undefined;
    const contents_len = @min(available.len, contents_buf.len);
    for (available[0..contents_len], contents_buf[0..contents_len]) |mime, *content| {
        content.* = .{ .mime = mime, .data = "" };
    }
    var aw: std.Io.Writer.Allocating = .init(self.alloc);
    defer aw.deinit();
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    const pasted = try terminal.paste.paste(.{
        .terminal = &self.io.terminal,
        .alloc = self.alloc,
        .writer = &aw.writer,
        .kitty_clipboard = .{
            .grants = &self.io.terminal_stream.handler.kitty_clipboard_grants,
            .io = global.io(),
        },
    }, .{
        .source = .{ .clipboard = location },
        .contents = .{ .memory = contents_buf[0..contents_len] },
        .allow_unsafe = true,
    });
    if (!pasted) return false;
    self.queueIo(.{ .write_alloc = .{
        .alloc = self.alloc,
        .data = try aw.toOwnedSlice(),
    } }, .locked);
    return true;
}
fn completeClipboardReadOSC52(
    self: *Surface,
    data: []const u8,
    clipboard_type: apprt.Clipboard,
    confirmed: bool,
) !void {
    assert(self.config.clipboard_read != .deny);
    if (self.config.clipboard_read == .ask and !confirmed) {
        return error.UnauthorizedPaste;
    }
    const enc = std.base64.standard.Encoder;
    const size = enc.calcSize(data.len);
    const buf = try self.alloc.alloc(u8, size + 9);
    errdefer self.alloc.free(buf);
    const kind: u8 = switch (clipboard_type) {
        .standard => 'c',
        .selection => 's',
        .primary => 'p',
    };
    const prefix = try std.fmt.bufPrint(buf, "\x1b]52;{c};", .{kind});
    assert(prefix.len == 7);
    buf[buf.len - 2] = '\x1b';
    buf[buf.len - 1] = '\\';
    const encoded = enc.encode(buf[prefix.len..], data);
    assert(encoded.len == size);
    self.queueIo(.{ .write_alloc = .{
        .alloc = self.alloc,
        .data = buf,
    } }, .unlocked);
}
fn kittyClipboardRead(
    self: *Surface,
    req: *apprt.ClipboardRequest.KittyRead,
) !void {
    if (self.config.clipboard_read == .deny) {
        defer req.destroy();
        log.info("application attempted to read clipboard, but 'clipboard-read' is set to deny", .{});
        try self.kittyClipboardStatus(.read, req.id, req.terminator, .EPERM);
        return;
    }
    const result = self.startClipboardRequest(
        req.location,
        .{ .kitty_read = req },
    ) catch |err| {
        defer req.destroy();
        self.kittyClipboardStatus(.read, req.id, req.terminator, .EIO) catch {};
        return err;
    };
    switch (result) {
        .started => {},
        .unavailable => {
            defer req.destroy();
            try self.completeKittyClipboardRead(req, &.{}, &.{});
        },
        .unsupported => {
            defer req.destroy();
            try self.kittyClipboardStatus(.read, req.id, req.terminator, .ENOSYS);
        },
    }
}
fn kittyClipboardWrite(
    self: *Surface,
    req: *apprt.ClipboardRequest.KittyWrite,
) !void {
    if (self.config.clipboard_write == .deny) {
        defer req.destroy();
        log.info("application attempted to write clipboard, but 'clipboard-write' is set to deny", .{});
        try self.kittyClipboardStatus(.write, req.id, req.terminator, .EPERM);
        return;
    }
    const result = self.startClipboardRequest(
        req.location,
        .{ .kitty_write = req },
    ) catch |err| {
        defer req.destroy();
        self.kittyClipboardStatus(.write, req.id, req.terminator, .EIO) catch {};
        return err;
    };
    switch (result) {
        .started => {},
        .unavailable, .unsupported => {
            defer req.destroy();
            try self.kittyClipboardStatus(.write, req.id, req.terminator, .ENOSYS);
        },
    }
}
fn kittyClipboardStatus(
    self: *Surface,
    op: terminal.kitty.clipboard.Operation,
    id: []const u8,
    terminator: terminal.osc.Terminator,
    status: terminal.kitty.clipboard.Status,
) error{ OutOfMemory, WriteFailed }!void {
    var aw: std.Io.Writer.Allocating = .init(self.alloc);
    defer aw.deinit();
    try (terminal.kitty.clipboard.Response{
        .op = op,
        .status = status,
        .id = id,
        .terminator = terminator,
    }).encode(&aw.writer);
    self.queueIo(.{ .write_alloc = .{
        .alloc = self.alloc,
        .data = try aw.toOwnedSlice(),
    } }, .unlocked);
}
fn completeKittyClipboardRead(
    self: *Surface,
    req: *const apprt.ClipboardRequest.KittyRead,
    contents: []const terminal.clipboard.Content,
    available: []const []const u8,
) !void {
    const kitty_clipboard = terminal.kitty.clipboard;
    var contents_buf: [kitty_clipboard.max_read_mimes]terminal.clipboard.Content = undefined;
    var contents_len: usize = 0;
    for (req.mimes) |mime| {
        const data: []const u8 = data: {
            for (contents) |content| {
                if (std.mem.eql(u8, content.mime, mime)) break :data content.data;
                if (terminal.clipboard.isTextMime(mime) and
                    terminal.clipboard.isTextMime(content.mime))
                {
                    break :data content.data;
                }
            }
            continue;
        };
        contents_buf[contents_len] = .{ .mime = mime, .data = data };
        contents_len += 1;
    }
    var aw: std.Io.Writer.Allocating = .init(self.alloc);
    defer aw.deinit();
    try (kitty_clipboard.ReadSuccess{
        .primary = req.location == .primary,
        .id = req.id,
        .list = req.list,
        .available = available,
        .contents = contents_buf[0..contents_len],
        .terminator = req.terminator,
    }).encode(&aw.writer);
    self.queueIo(.{ .write_alloc = .{
        .alloc = self.alloc,
        .data = try aw.toOwnedSlice(),
    } }, .unlocked);
}
fn showDesktopNotification(self: *Surface, title: [:0]const u8, body: [:0]const u8) !void {
    const hash_algorithm = std.hash.Wyhash;
    const now: std.Io.Timestamp = .now(global.io(), .awake);
    if (self.app.last_notification_time) |last| {
        if (last.durationTo(now).toSeconds() < 1) {
            log.warn("rate limiting desktop notifications", .{});
            return;
        }
    }
    const new_digest = d: {
        var hash = hash_algorithm.init(0);
        hash.update(title);
        hash.update(body);
        break :d hash.final();
    };
    if (self.app.last_notification_time) |last| {
        if (self.app.last_notification_digest == new_digest) {
            if (last.durationTo(now).toSeconds() < 5) {
                log.warn("suppressing identical desktop notification", .{});
                return;
            }
        }
    }
    self.app.last_notification_time = now;
    self.app.last_notification_digest = new_digest;
    _ = try self.rt_app.performAction(
        .{ .surface = self },
        .desktop_notification,
        .{
            .title = title,
            .body = body,
        },
    );
}
fn crashThreadState(self: *Surface) crash.sentry.ThreadState {
    return .{
        .type = .main,
        .surface = self,
    };
}
fn presentSurface(self: *Surface) !void {
    _ = try self.rt_app.performAction(
        .{ .surface = self },
        .present_terminal,
        {},
    );
}
pub fn getProcessInfo(self: *Surface, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    return self.io.getProcessInfo(info);
}
test "queueIo frees allocated writes in readonly mode" {
    const testing = std.testing;
    const surface = try testing.allocator.create(Surface);
    defer testing.allocator.destroy(surface);
    surface.readonly = true;
    const data = try testing.allocator.dupe(u8, "\x1b]lWasp\x1b\\");
    surface.queueIo(.{ .write_alloc = .{
        .alloc = testing.allocator,
        .data = data,
    } }, .unlocked);
}
test "promptClickRelativeRow" {
    const testing = std.testing;
    const Case = struct {
        layout: enum { no_history, offset, cross_page, prompt_above_viewport },
        click_y: u32,
        expected: u32,
    };
    const cases = [_]Case{
        .{ .layout = .no_history, .click_y = 1, .expected = 1 },
        .{ .layout = .offset, .click_y = 3, .expected = 3 },
        .{ .layout = .cross_page, .click_y = 3, .expected = 3 },
        .{ .layout = .prompt_above_viewport, .click_y = 0, .expected = 3 },
    };
    for (cases) |case| {
        var pages = try terminal.PageList.init(testing.allocator, .{
            .cols = 80,
            .rows = 5,
        });
        defer pages.deinit();
        const scroll_rows: u32 = switch (case.layout) {
            .no_history => 0,
            .offset, .prompt_above_viewport => 10,
            .cross_page => pages.pages.first.?.capacity().rows - 2,
        };
        for (0..scroll_rows) |_| _ = try pages.grow();
        const prompt_y = if (case.layout == .prompt_above_viewport)
            scroll_rows - 2
        else
            scroll_rows + 1;
        const prompt = pages.pin(.{ .screen = .{ .y = prompt_y } }).?;
        const click = pages.pin(.{ .viewport = .{ .x = 7, .y = case.click_y } }).?;
        try testing.expectEqual(case.layout == .cross_page, prompt.node != click.node);
        try testing.expectEqual(
            case.layout == .prompt_above_viewport,
            pages.pointFromPin(.viewport, prompt) == null,
        );
        try testing.expectEqual(case.expected, promptClickRelativeRow(&pages, prompt, click));
    }
}
