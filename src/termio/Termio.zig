pub const Termio = @This();
const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const EnvMap = std.process.Environ.Map;
const posix = std.posix;
const termio = @import("../termio.zig");
const StreamHandler = @import("stream_handler.zig").StreamHandler;
const terminalpkg = @import("../terminal/main.zig");
const global = @import("../global.zig");
const xev = global.xev;
const renderer = @import("../renderer.zig");
const apprt = @import("../apprt.zig");
const internal_os = @import("../os/root.zig");
const windows = internal_os.windows;
const configpkg = @import("../config.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;
const compat_file = @import("../lib/compat/file.zig");
const log = std.log.scoped(.io_exec);
pub const MutexState = enum { locked, unlocked };
alloc: Allocator,
backend: termio.Backend,
config: DerivedConfig,
terminal: terminalpkg.Terminal,
renderer_state: *renderer.State,
renderer_wakeup: xev.Async,
renderer_mailbox: *renderer.Thread.Mailbox,
surface_mailbox: apprt.surface.Mailbox,
size: renderer.Size,
mailbox: termio.Mailbox,
terminal_stream: StreamHandler.Stream,
last_cursor_reset: ?std.Io.Timestamp = null,
thread_enter_state: ?*ThreadEnterState = null,
const ThreadEnterState = struct {
    arena: ArenaAllocator,
    input: configpkg.io.RepeatableReadableIO,
    pub fn create(
        alloc: Allocator,
        config: *const configpkg.Config,
    ) !?*ThreadEnterState {
        if (config.input.list.items.len == 0) return null;
        var arena = ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();
        const ptr = try arena_alloc.create(ThreadEnterState);
        const input = try config.input.cloneParsed(arena_alloc);
        ptr.* = .{
            .arena = arena,
            .input = input,
        };
        return ptr;
    }
    pub fn destroy(self: *ThreadEnterState) void {
        self.arena.deinit();
    }
    pub fn prepareInput(
        self: *ThreadEnterState,
    ) (Allocator.Error || error{InputNotFound})![]const Input {
        const alloc = self.arena.allocator();
        var inputs: std.ArrayList(Input) = try .initCapacity(
            alloc,
            self.input.list.items.len,
        );
        errdefer for (inputs.items) |item| item.deinit();
        for (self.input.list.items) |item| {
            inputs.appendAssumeCapacity(switch (item) {
                .raw => |v| .{ .string = v },
                .path => |path| file: {
                    const f = std.Io.Dir.cwd().openFile(
                        global.io(),
                        path,
                        .{},
                    ) catch |err| {
                        log.warn("failed to open input file={s} err={}", .{
                            path,
                            err,
                        });
                        return error.InputNotFound;
                    };
                    break :file .{ .file = f };
                },
            });
        }
        return inputs.items;
    }
    const Input = union(enum) {
        string: []const u8,
        file: std.Io.File,
        fn deinit(self: Input) void {
            switch (self) {
                .string => {},
                .file => |f| f.close(global.io()),
            }
        }
    };
};
fn xtChecksumFlags(
    ext: configpkg.Config.XtChecksumExtension,
) terminalpkg.xt_checksum.Flags {
    return .{
        .positive = !ext.negate,
        .no_attributes = !ext.attributes,
        .no_trim = !ext.trim,
        .undrawn = ext.undrawn,
        .full = ext.full,
    };
}
pub const DerivedConfig = struct {
    arena: ArenaAllocator,
    palette: terminalpkg.color.Palette,
    image_storage_limit: usize,
    cursor_style: terminalpkg.CursorStyle,
    cursor_blink: ?bool,
    cursor_color: ?configpkg.Config.TerminalColor,
    foreground: configpkg.Config.Color,
    background: configpkg.Config.Color,
    osc_color_report_format: configpkg.Config.OSCColorReportFormat,
    clipboard_write: configpkg.ClipboardAccess,
    clipboard_write_limit: usize,
    enquiry_response: []const u8,
    xt_checksum_report: bool,
    xt_checksum_extension: terminalpkg.xt_checksum.Flags,
    conditional_state: configpkg.ConditionalState,
    pub fn init(
        alloc_gpa: Allocator,
        config: *const configpkg.Config,
    ) !DerivedConfig {
        var arena = ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const palette: terminalpkg.color.Palette = palette: {
            if (config.@"palette-generate") generate: {
                if (config.palette.mask.findFirstSet() == null) {
                    break :generate;
                }
                break :palette terminalpkg.color.generate256Color(config.palette.value, config.palette.mask, config.background.toTerminalRGB(), config.foreground.toTerminalRGB(), config.@"palette-harmonious");
            }
            break :palette config.palette.value;
        };
        return .{
            .palette = palette,
            .image_storage_limit = config.@"image-storage-limit",
            .cursor_style = config.@"cursor-style",
            .cursor_blink = config.@"cursor-style-blink",
            .cursor_color = config.@"cursor-color",
            .foreground = config.foreground,
            .background = config.background,
            .osc_color_report_format = config.@"osc-color-report-format",
            .clipboard_write = config.@"clipboard-write",
            .clipboard_write_limit = config.@"clipboard-write-limit-bytes".value,
            .enquiry_response = try alloc.dupe(u8, config.@"enquiry-response"),
            .xt_checksum_report = config.@"vt-xt-checksum-report",
            .xt_checksum_extension = xtChecksumFlags(config.@"vt-xt-checksum-extension"),
            .conditional_state = config._conditional_state,
            .arena = arena,
        };
    }
    pub fn deinit(self: *DerivedConfig) void {
        self.arena.deinit();
    }
};
pub fn init(self: *Termio, alloc: Allocator, opts: termio.Options) !void {
    const default_modes: terminalpkg.ModePacked = modes: {
        var modes: terminalpkg.ModePacked = .{};
        switch (opts.full_config.@"grapheme-width-method") {
            .unicode => modes.grapheme_cluster = true,
            .legacy => {},
        }
        modes.cursor_blinking = opts.config.cursor_blink orelse true;
        break :modes modes;
    };
    var term = try terminalpkg.Terminal.init(global.io(), alloc, opts: {
        const grid_size = opts.size.grid();
        break :opts .{
            .cols = grid_size.columns,
            .rows = grid_size.rows,
            .max_scrollback_bytes = opts.full_config.@"scrollback-limit-bytes".optional(),
            .max_scrollback_lines = opts.full_config.@"scrollback-limit-lines".optional(),
            .default_modes = default_modes,
            .default_cursor_style = opts.config.cursor_style,
            .default_cursor_blink = opts.config.cursor_blink,
            .default_xt_checksum = opts.config.xt_checksum_extension,
            .colors = .{
                .background = .init(opts.config.background.toTerminalRGB()),
                .foreground = .init(opts.config.foreground.toTerminalRGB()),
                .cursor = cursor: {
                    const color = opts.config.cursor_color orelse break :cursor .unset;
                    const rgb = color.toTerminalRGB() orelse break :cursor .unset;
                    break :cursor .init(rgb);
                },
                .palette = .default,
            },
            .kitty_image_storage_limit = opts.config.image_storage_limit,
            .kitty_image_loading_limits = .allWithTempDir(global.tmpDirPath()),
        };
    });
    errdefer term.deinit(alloc);
    try term.colors.palette.changeDefault(alloc, opts.config.palette);
    term.width_px = term.cols * opts.size.cell.width;
    term.height_px = term.rows * opts.size.cell.height;
    var backend = opts.backend;
    backend.initTerminal(&term);
    const handler: StreamHandler = .{
        .alloc = alloc,
        .termio_mailbox = &self.mailbox,
        .surface_mailbox = opts.surface_mailbox,
        .renderer_state = opts.renderer_state,
        .renderer_wakeup = opts.renderer_wakeup,
        .renderer_mailbox = opts.renderer_mailbox,
        .size = &self.size,
        .terminal = &self.terminal,
        .osc_color_report_format = opts.config.osc_color_report_format,
        .clipboard_write = opts.config.clipboard_write,
        .clipboard_write_limit = opts.config.clipboard_write_limit,
        .enquiry_response = opts.config.enquiry_response,
        .xt_checksum_report = opts.config.xt_checksum_report,
    };
    const thread_enter_state = try ThreadEnterState.create(
        alloc,
        opts.full_config,
    );
    self.* = .{
        .alloc = alloc,
        .terminal = term,
        .config = opts.config,
        .renderer_state = opts.renderer_state,
        .renderer_wakeup = opts.renderer_wakeup,
        .renderer_mailbox = opts.renderer_mailbox,
        .surface_mailbox = opts.surface_mailbox,
        .size = opts.size,
        .backend = backend,
        .mailbox = opts.mailbox,
        .terminal_stream = .init(.{
            .allocator = alloc,
            .handler = handler,
        }),
        .thread_enter_state = thread_enter_state,
    };
}
pub fn deinit(self: *Termio) void {
    self.backend.deinit();
    self.terminal.deinit(self.alloc);
    self.config.deinit();
    self.mailbox.deinit(self.alloc);
    self.terminal_stream.deinit();
    if (self.thread_enter_state) |v| v.destroy();
}
pub fn threadEnter(
    self: *Termio,
    thread: *termio.Thread,
    data: *ThreadData,
) !void {
    defer if (self.thread_enter_state) |v| {
        v.destroy();
        self.thread_enter_state = null;
    };
    const inputs: ?[]const ThreadEnterState.Input = if (self.thread_enter_state) |v|
        try v.prepareInput()
    else
        null;
    defer if (inputs) |items| {
        for (items) |input| input.deinit();
    };
    data.* = .{
        .alloc = self.alloc,
        .loop = &thread.loop,
        .renderer_state = self.renderer_state,
        .surface_mailbox = self.surface_mailbox,
        .mailbox = &self.mailbox,
        .backend = undefined,
    };
    try self.backend.threadEnter(self.alloc, self, data);
    errdefer self.backend.threadExit(data);
    for (inputs orelse &.{}) |input| switch (input) {
        .string => |v| self.queueWrite(data, v, false) catch |err| {
            log.warn("failed to queue input string err={}", .{err});
            return error.InputFailed;
        },
        .file => |f| {
            const contents = compat_file.readToEndAlloc(
                f,
                self.alloc,
                10 * 1024 * 1024,
            ) catch |err| {
                log.warn("failed to read input file err={}", .{err});
                return error.InputFailed;
            };
            defer self.alloc.free(contents);
            self.queueWrite(data, contents, false) catch |err| {
                log.warn("failed to queue input file err={}", .{err});
                return error.InputFailed;
            };
        },
    };
}
pub fn threadExit(self: *Termio, data: *ThreadData) void {
    self.backend.threadExit(data);
}
pub fn queueMessage(
    self: *Termio,
    msg: termio.Message,
    mutex: MutexState,
) void {
    self.mailbox.send(msg, switch (mutex) {
        .locked => self.renderer_state.mutex,
        .unlocked => null,
    });
    self.mailbox.notify();
}
pub inline fn queueWrite(
    self: *Termio,
    td: *ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    try self.backend.queueWrite(self.alloc, td, data, linefeed);
}
pub fn changeConfig(self: *Termio, td: *ThreadData, config: *DerivedConfig) !void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    self.config.deinit();
    self.config = config.*;
    self.terminal_stream.handler.changeConfig(&self.config);
    td.backend.changeConfig(&self.config);
    self.terminal.colors.palette.changeDefault(
        self.alloc,
        config.palette,
    ) catch |err| {
        log.warn("error changing default palette, using built-in default err={}", .{err});
        self.terminal.colors.palette.resetDefault(self.alloc);
    };
    self.terminal.flags.dirty.palette = true;
    self.terminal.colors.background.default = config.background.toTerminalRGB();
    self.terminal.colors.foreground.default = config.foreground.toTerminalRGB();
    self.terminal.colors.cursor.default = cursor: {
        const color = config.cursor_color orelse break :cursor null;
        break :cursor color.toTerminalRGB() orelse break :cursor null;
    };
    self.terminal.setKittyGraphicsSizeLimit(self.alloc, config.image_storage_limit);
    self.terminal.setKittyGraphicsLoadingLimits(.allWithTempDir(global.tmpDirPath()));
}
pub fn resize(
    self: *Termio,
    td: *ThreadData,
    size: renderer.Size,
) !void {
    self.size = size;
    const grid_size = size.grid();
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        try self.backend.resize(grid_size, size.terminal());
        try self.terminal.resize(
            self.alloc,
            .{
                .cols = grid_size.columns,
                .rows = grid_size.rows,
                .cell_size_px = .{
                    .width = self.size.cell.width,
                    .height = self.size.cell.height,
                },
            },
        );
        if (self.terminal.modes.get(.in_band_size_reports)) {
            try self.sizeReportLocked(td, .mode_2048);
        }
    }
    _ = self.renderer_mailbox.push(global.io(), .{ .resize = size }, .{ .forever = {} });
    self.renderer_wakeup.notify() catch {};
}
pub fn sizeReport(self: *Termio, td: *ThreadData, style: termio.Message.SizeReport) !void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    try self.sizeReportLocked(td, style);
}
fn sizeReportLocked(self: *Termio, td: *ThreadData, style: termio.Message.SizeReport) !void {
    const grid_size = self.size.grid();
    const report_size: terminalpkg.size_report.Size = .{
        .rows = grid_size.rows,
        .columns = grid_size.columns,
        .cell_width = self.size.cell.width,
        .cell_height = self.size.cell.height,
    };
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try terminalpkg.size_report.encode(
        &writer,
        style,
        report_size,
    );
    try self.queueWrite(td, writer.buffered(), false);
}
pub fn resetSynchronizedOutput(self: *Termio) void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    self.terminal.modes.set(.synchronized_output, false);
    self.renderer_wakeup.notify() catch {};
}
pub fn clearScreen(self: *Termio, td: *ThreadData, history: bool) !void {
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        if (self.terminal.screens.active_key == .alternate) return;
        self.terminal.screens.active.clearSelection();
        if (history) self.terminal.eraseDisplay(.scrollback, false);
        if (!self.terminal.cursorIsAtPrompt()) {
            if (self.terminal.screens.active.cursor.y > 0) {
                self.terminal.screens.active.eraseActive(
                    self.terminal.screens.active.cursor.y - 1,
                );
            }
            self.terminal.screens.active.kitty_images.delete(
                self.terminal.io(),
                self.terminal.screens.active.alloc,
                &self.terminal,
                .{ .all = true },
            );
            return;
        }
        self.terminal.eraseDisplay(.complete, false);
    }
    try self.queueWrite(td, &[_]u8{0x0C}, false);
}
pub fn scrollViewport(
    self: *Termio,
    scroll: terminalpkg.Terminal.ScrollViewport,
) void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    self.terminal.scrollViewport(scroll);
}
pub fn jumpToPrompt(self: *Termio, delta: isize) !void {
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        self.terminal.screens.active.scroll(.{ .delta_prompt = delta });
    }
    try self.renderer_wakeup.notify();
}
pub fn focusGained(self: *Termio, td: *ThreadData, focused: bool) !void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    const focus_event = self.renderer_state.terminal.modes.get(.focus_event);
    self.renderer_state.mutex.unlock(global.io());
    if (focus_event) {
        var buf: [terminalpkg.focus.max_encode_size]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        terminalpkg.focus.encode(&writer, if (focused) .gained else .lost) catch |err| {
            log.err("error encoding focus event err={}", .{err});
            return;
        };
        try self.queueWrite(td, writer.buffered(), false);
    }
    try self.backend.focusGained(td, focused);
}
pub fn processOutput(self: *Termio, buf: []const u8) void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    self.processOutputLocked(buf);
}
fn processOutputLocked(self: *Termio, buf: []const u8) void {
    self.terminal_stream.handler.queueRender() catch unreachable;
    const now = std.Io.Timestamp.now(global.io(), .awake);
    cursor_reset: {
        if (self.last_cursor_reset) |last| {
            if (last.durationTo(now).toMilliseconds() <= 500) {
                break :cursor_reset;
            }
        }
        self.last_cursor_reset = now;
        _ = self.renderer_mailbox.push(global.io(), .{
            .reset_cursor_blink = {},
        }, .{ .instant = {} });
    }
    if (self.renderer_state.inspector) |insp| {
        for (buf, 0..) |byte, i| {
            insp.recordPtyRead(
                self.alloc,
                &self.terminal,
                buf[i .. i + 1],
            ) catch |err| {
                log.err("error recording pty read in inspector err={}", .{err});
            };
            self.terminal_stream.next(byte);
        }
    } else {
        self.terminal_stream.nextSlice(buf);
    }
    if (self.terminal_stream.handler.termio_messaged) {
        self.terminal_stream.handler.termio_messaged = false;
        self.mailbox.notify();
    }
}
pub fn kittyClipboardGrant(
    self: *Termio,
    pw: []const u8,
    dir: terminalpkg.kitty.clipboard.Grants.Direction,
) error{OutOfMemory}!void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    try self.terminal_stream.handler.kittyClipboardGrant(pw, dir);
}
pub fn colorSchemeReport(self: *Termio, td: *ThreadData, force: bool) !void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    try self.colorSchemeReportLocked(td, force);
}
pub fn colorSchemeReportLocked(self: *Termio, td: *ThreadData, force: bool) !void {
    if (!force and !self.renderer_state.terminal.modes.get(.report_color_scheme)) {
        return;
    }
    const scheme: terminalpkg.device_status.ColorScheme = switch (self.config.conditional_state.theme) {
        .light => .light,
        .dark => .dark,
    };
    var buf: [terminalpkg.device_status.max_color_scheme_report_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try terminalpkg.device_status.encodeColorSchemeReport(&writer, scheme);
    try self.queueWrite(td, writer.buffered(), false);
}
pub fn visibilityReport(
    self: *Termio,
    td: *ThreadData,
    visible: bool,
    force: bool,
) !void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    if (!force and !self.renderer_state.terminal.modes.get(.report_visibility)) {
        return;
    }
    var buf: [terminalpkg.device_status.max_visibility_report_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try terminalpkg.device_status.encodeVisibilityReport(
        &writer,
        if (visible) .potentially_visible else .not_visible,
    );
    try self.queueWrite(td, writer.buffered(), false);
}
pub const ThreadData = struct {
    alloc: Allocator,
    loop: *xev.Loop,
    renderer_state: *renderer.State,
    surface_mailbox: apprt.surface.Mailbox,
    backend: termio.backend.ThreadData,
    mailbox: *termio.Mailbox,
    pub fn deinit(self: *ThreadData) void {
        self.backend.deinit(self.alloc);
        self.* = undefined;
    }
};
pub fn getProcessInfo(self: *Termio, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    return self.backend.getProcessInfo(info);
}
