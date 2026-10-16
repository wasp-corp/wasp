const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const xev = global.xev;
const apprt = @import("../apprt.zig");
const build_config = @import("../build_config.zig");
const configpkg = @import("../config.zig");
const internal_os = @import("../os/root.zig");
const renderer = @import("../renderer.zig");
const termio = @import("../termio.zig");
const terminal = @import("../terminal/main.zig");
const terminfo = @import("../terminfo/root.zig");
const posix = std.posix;
const log = std.log.scoped(.io_handler);
pub const StreamHandler = struct {
    alloc: Allocator,
    size: *renderer.Size,
    terminal: *terminal.Terminal,
    termio_mailbox: *termio.Mailbox,
    surface_mailbox: apprt.surface.Mailbox,
    renderer_state: *renderer.State,
    renderer_mailbox: *renderer.Thread.Mailbox,
    renderer_wakeup: xev.Async,
    enquiry_response: []const u8,
    osc_color_report_format: configpkg.Config.OSCColorReportFormat,
    clipboard_write: configpkg.ClipboardAccess,
    clipboard_write_limit: usize,
    xt_checksum_report: bool,
    apc: terminal.apc.Handler = .{},
    dcs: terminal.dcs.Handler = .{},
    tmux_viewer: if (tmux_enabled) ?*terminal.tmux.Viewer else void = if (tmux_enabled) null else {},
    kitty_clipboard_grants: terminal.kitty.clipboard.Grants = .{},
    kitty_clipboard_write: ?*terminal.kitty.clipboard.WriteState = null,
    termio_messaged: bool = false,
    seen_title: bool = false,
    pub const Stream = terminal.Stream(StreamHandler);
    pub const tmux_enabled = terminal.options.tmux_control_mode;
    pub fn deinit(self: *StreamHandler) void {
        self.apc.deinit();
        self.dcs.deinit();
        self.kittyClipboardWriteAbort();
        self.kitty_clipboard_grants.deinit(self.alloc);
        if (comptime tmux_enabled) tmux: {
            const viewer = self.tmux_viewer orelse break :tmux;
            viewer.deinit();
            self.alloc.destroy(viewer);
            self.tmux_viewer = null;
        }
    }
    pub inline fn queueRender(self: *StreamHandler) !void {
        try self.renderer_wakeup.notify();
    }
    pub fn changeConfig(self: *StreamHandler, config: *termio.DerivedConfig) void {
        self.osc_color_report_format = config.osc_color_report_format;
        self.clipboard_write = config.clipboard_write;
        self.clipboard_write_limit = config.clipboard_write_limit;
        self.enquiry_response = config.enquiry_response;
        self.xt_checksum_report = config.xt_checksum_report;
        self.terminal.setDefaultCursorStyle(config.cursor_style);
        self.terminal.setDefaultCursorBlink(config.cursor_blink);
        self.terminal.setDefaultXtChecksum(config.xt_checksum_extension);
        self.messageWriter(.{ .color_scheme_report = .{ .force = false } });
    }
    inline fn surfaceMessageWriter(
        self: *StreamHandler,
        msg: apprt.surface.Message,
    ) void {
        if (self.surface_mailbox.push(msg, .{ .instant = {} }) == 0) {
            self.renderer_state.mutex.unlock(global.io());
            defer self.renderer_state.mutex.lockUncancelable(global.io());
            _ = self.surface_mailbox.push(msg, .{ .forever = {} });
        }
    }
    inline fn messageWriter(self: *StreamHandler, msg: termio.Message) void {
        self.termio_mailbox.send(msg, self.renderer_state.mutex);
        self.termio_messaged = true;
    }
    inline fn rendererMessageWriter(
        self: *StreamHandler,
        msg: renderer.Message,
    ) void {
        if (self.renderer_mailbox.push(msg, .{ .instant = {} }) > 0) {
            return;
        }
        self.renderer_state.mutex.unlock(global.io());
        defer self.renderer_state.mutex.lockUncancelable(global.io());
        self.renderer_wakeup.notify() catch |err| {
            log.warn(
                "failed to notify renderer, may deadlock err={}",
                .{err},
            );
        };
        _ = self.renderer_mailbox.push(msg, .{ .forever = {} });
    }
    pub fn vt(
        self: *StreamHandler,
        comptime action: Stream.Action.Tag,
        value: Stream.Action.Value(action),
    ) void {
        self.vtFallible(action, value) catch |err| {
            log.warn("error handling VT action action={} err={}", .{ action, err });
        };
    }
    inline fn vtFallible(
        self: *StreamHandler,
        comptime action: Stream.Action.Tag,
        value: Stream.Action.Value(action),
    ) !void {
        switch (action) {
            .print => {
                @branchHint(.likely);
                try self.terminal.print(value.cp);
            },
            .print_slice => {
                @branchHint(.likely);
                try self.terminal.printSlice(value.cps);
            },
            .print_repeat => try self.terminal.printRepeat(value),
            .bell => self.bell(),
            .backspace => self.terminal.backspace(),
            .horizontal_tab => self.horizontalTab(value),
            .horizontal_tab_back => self.horizontalTabBack(value),
            .linefeed => {
                @branchHint(.likely);
                try self.linefeed();
            },
            .carriage_return => {
                @branchHint(.likely);
                self.terminal.carriageReturn();
            },
            .enquiry => try self.enquiry(),
            .invoke_charset => self.terminal.invokeCharset(value.bank, value.charset, value.locking),
            .cursor_up => self.terminal.cursorUp(value.value),
            .cursor_down => self.terminal.cursorDown(value.value),
            .cursor_left => self.terminal.cursorLeft(value.value),
            .cursor_right => self.terminal.cursorRight(value.value),
            .cursor_pos => {
                @branchHint(.likely);
                self.terminal.setCursorPos(value.row, value.col);
            },
            .cursor_col => self.terminal.setCursorPos(self.terminal.screens.active.cursor.y + 1, value.value),
            .cursor_row => self.terminal.setCursorPos(value.value, self.terminal.screens.active.cursor.x + 1),
            .cursor_col_relative => self.terminal.setCursorPos(
                self.terminal.screens.active.cursor.y + 1,
                self.terminal.screens.active.cursor.x + 1 +| value.value,
            ),
            .cursor_row_relative => self.terminal.setCursorPos(
                self.terminal.screens.active.cursor.y + 1 +| value.value,
                self.terminal.screens.active.cursor.x + 1,
            ),
            .cursor_style => self.terminal.setCursorStyle(value),
            .erase_display_below => self.terminal.eraseDisplay(.below, value),
            .erase_display_above => self.terminal.eraseDisplay(.above, value),
            .erase_display_complete => {
                self.terminal.scrollViewport(.{ .bottom = {} });
                self.terminal.eraseDisplay(.complete, value);
            },
            .erase_display_scrollback => self.terminal.eraseDisplay(.scrollback, value),
            .erase_display_scroll_complete => self.terminal.eraseDisplay(.scroll_complete, value),
            .erase_line_right => self.terminal.eraseLine(.right, value),
            .erase_line_left => self.terminal.eraseLine(.left, value),
            .erase_line_complete => self.terminal.eraseLine(.complete, value),
            .erase_line_right_unless_pending_wrap => self.terminal.eraseLine(.right_unless_pending_wrap, value),
            .delete_chars => self.terminal.deleteChars(value),
            .erase_chars => self.terminal.eraseChars(value),
            .insert_lines => self.terminal.insertLines(value),
            .insert_blanks => self.terminal.insertBlanks(value),
            .delete_lines => self.terminal.deleteLines(value),
            .scroll_up => try self.terminal.scrollUp(value),
            .scroll_down => self.terminal.scrollDown(value),
            .tab_clear_current => self.terminal.tabClear(.current),
            .tab_clear_all => self.terminal.tabClear(.all),
            .tab_set => self.terminal.tabSet(),
            .tab_reset => self.terminal.tabReset(),
            .index => try self.index(),
            .next_line => try self.nextLine(),
            .reverse_index => try self.reverseIndex(),
            .full_reset => try self.fullReset(),
            .soft_reset => self.terminal.softReset(),
            .set_mode => try self.setMode(value.mode, true),
            .reset_mode => try self.setMode(value.mode, false),
            .save_mode => self.terminal.modes.save(value.mode),
            .restore_mode => {
                const v = self.terminal.modes.restore(value.mode);
                try self.setMode(value.mode, v);
            },
            .request_mode => try self.requestMode(value.mode),
            .request_mode_unknown => try self.requestModeUnknown(value.mode, value.ansi),
            .top_and_bottom_margin => self.terminal.setTopAndBottomMargin(value.top_left, value.bottom_right),
            .left_and_right_margin => self.terminal.setLeftAndRightMargin(value.top_left, value.bottom_right),
            .left_and_right_margin_ambiguous => {
                if (self.terminal.modes.get(.enable_left_and_right_margin)) {
                    self.terminal.setLeftAndRightMargin(0, 0);
                } else {
                    self.terminal.saveCursor();
                }
            },
            .save_cursor => try self.saveCursor(),
            .restore_cursor => try self.restoreCursor(),
            .modify_key_format => try self.setModifyKeyFormat(value),
            .protected_mode_off => self.terminal.setProtectedMode(.off),
            .protected_mode_iso => self.terminal.setProtectedMode(.iso),
            .protected_mode_dec => self.terminal.setProtectedMode(.dec),
            .mouse_shift_capture => self.terminal.flags.mouse_shift_capture = if (value) .true else .false,
            .xt_checksum_extension => if (self.xt_checksum_report) {
                self.terminal.flags.xt_checksum = value.flags;
            },
            .request_xt_checksum => self.reportXtChecksum(value),
            .size_report => self.sendSizeReport(value),
            .resize_window => self.surfaceMessageWriter(.{ .resize_window = value }),
            .xtversion => try self.reportXtversion(),
            .device_attributes => try self.deviceAttributes(value),
            .device_status => try self.deviceStatusReport(value.request),
            .kitty_keyboard_query => try self.queryKittyKeyboard(),
            .kitty_keyboard_push => {
                log.debug("pushing kitty keyboard mode: {}", .{value.flags});
                self.terminal.screens.active.kitty_keyboard.push(value.flags);
            },
            .kitty_keyboard_pop => {
                log.debug("popping kitty keyboard mode n={}", .{value});
                self.terminal.screens.active.kitty_keyboard.pop(@intCast(value));
            },
            .kitty_keyboard_set => {
                log.debug("setting kitty keyboard mode: set {}", .{value.flags});
                self.terminal.screens.active.kitty_keyboard.set(.set, value.flags);
            },
            .kitty_keyboard_set_or => {
                log.debug("setting kitty keyboard mode: or {}", .{value.flags});
                self.terminal.screens.active.kitty_keyboard.set(.@"or", value.flags);
            },
            .kitty_keyboard_set_not => {
                log.debug("setting kitty keyboard mode: not {}", .{value.flags});
                self.terminal.screens.active.kitty_keyboard.set(.not, value.flags);
            },
            .kitty_color_report => try self.kittyColorReport(value),
            .color_operation => try self.colorOperation(value.op, &value.requests, value.terminator),
            .end_hyperlink => try self.endHyperlink(),
            .active_status_display => self.terminal.status_display = value,
            .decaln => try self.decaln(),
            .window_title => try self.windowTitle(value.title),
            .report_pwd => try self.reportPwd(value.url),
            .show_desktop_notification => try self.showDesktopNotification(value.title, value.body),
            .progress_report => self.progressReport(value),
            .start_hyperlink => try self.startHyperlink(value.uri, value.id),
            .clipboard_contents => try self.clipboardContents(value.kind, value.data),
            .semantic_prompt => try self.semanticPrompt(value),
            .mouse_shape => try self.setMouseShape(value),
            .mouse_shape_reset => try self.setMouseShape(
                if (self.terminal.flags.mouse_event != .none) .default else .text,
            ),
            .configure_charset => self.configureCharset(value.slot, value.charset),
            .set_attribute => {
                @branchHint(.likely);
                switch (value) {
                    .unknown => |unk| {
                        @branchHint(.unlikely);
                        log.warn("unimplemented or unknown SGR attribute: {any}", .{unk});
                    },
                    else => {
                        @branchHint(.likely);
                        self.terminal.setAttribute(value) catch |err| {
                            @branchHint(.cold);
                            log.warn("error setting attribute {}: {}", .{ value, err });
                        };
                    },
                }
            },
            .dcs_hook => try self.dcsHook(value),
            .dcs_put => try self.dcsPut(value),
            .dcs_unhook => try self.dcsUnhook(),
            .apc_start => self.apc.start(),
            .apc_end => try self.apcEnd(),
            .apc_put => self.apc.feed(self.alloc, value),
            .apc_put_slice => self.apc.feedSlice(self.alloc, value.bytes),
            .kitty_clipboard => try self.kittyClipboard(value),
            .title_push,
            .title_pop,
            .kitty_dnd,
            .osc_unknown,
            .program_status,
            => {},
        }
    }
    pub inline fn dcsHook(self: *StreamHandler, dcs: terminal.DCS) !void {
        var cmd = self.dcs.hook(self.alloc, dcs) orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
    }
    pub inline fn dcsPut(self: *StreamHandler, byte: u8) !void {
        var cmd = self.dcs.put(byte) orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
    }
    pub inline fn dcsUnhook(self: *StreamHandler) !void {
        var cmd = self.dcs.unhook() orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
    }
    fn dcsCommand(self: *StreamHandler, cmd: *terminal.dcs.Command) !void {
        switch (cmd.*) {
            .tmux => |tmux| tmux: {
                if (comptime !tmux_enabled) break :tmux;
                log.info("tmux control mode event cmd={f}", .{tmux});
                switch (tmux) {
                    .enter => {
                        assert(self.tmux_viewer == null);
                        const viewer = try self.alloc.create(terminal.tmux.Viewer);
                        errdefer self.alloc.destroy(viewer);
                        viewer.* = try .init(global.io(), self.alloc);
                        errdefer viewer.deinit();
                        self.tmux_viewer = viewer;
                        break :tmux;
                    },
                    .exit => {
                        if (self.tmux_viewer) |viewer| {
                            viewer.deinit();
                            self.alloc.destroy(viewer);
                            self.tmux_viewer = null;
                        }
                        break :tmux;
                    },
                    else => {},
                }
                assert(tmux != .enter);
                assert(tmux != .exit);
                const viewer = self.tmux_viewer orelse {
                    log.info(
                        "received tmux control mode command without viewer: {f}",
                        .{tmux},
                    );
                    break :tmux;
                };
                for (viewer.next(.{ .tmux = tmux })) |action| {
                    log.info("tmux viewer action={f}", .{action});
                    switch (action) {
                        .exit => {},
                        .command => |command| {
                            assert(command.len > 0);
                            assert(command[command.len - 1] == '\n');
                            self.messageWriter(try termio.Message.writeReq(
                                self.alloc,
                                command,
                            ));
                        },
                        .windows => {},
                    }
                }
            },
            .xtgettcap => |*gettcap| {
                const map = comptime terminfo.wasp.xtgettcapMap();
                while (gettcap.next()) |key| {
                    const response = map.get(key) orelse continue;
                    self.messageWriter(.{ .write_stable = response });
                }
            },
            .decrqss => |decrqss| {
                var response: [terminal.dcs.Command.DECRQSS.max_response_bytes]u8 = undefined;
                const encoded = try decrqss.encode(self.terminal, &response);
                const msg = try termio.Message.writeReq(
                    self.alloc,
                    encoded,
                );
                self.messageWriter(msg);
            },
        }
    }
    pub fn apcEnd(self: *StreamHandler) !void {
        var result = self.apc.end() orelse return;
        defer result.deinit(self.alloc);
        switch (result) {
            .unknown => return,
            .kitty => |*kitty_cmd| {
                if (self.terminal.kittyGraphics(global.io(), self.alloc, kitty_cmd)) |resp| {
                    var buf: [1024]u8 = undefined;
                    var writer: std.Io.Writer = .fixed(&buf);
                    try resp.encode(&writer);
                    const final = writer.buffered();
                    if (final.len > 2) {
                        log.debug("kitty graphics response: {x}", .{final});
                        self.messageWriter(try termio.Message.writeReq(self.alloc, final));
                    }
                }
            },
            .glyph => |*glyph_req| {
                const resp = self.terminal.glyphProtocol(self.alloc, glyph_req);
                switch (glyph_req.*) {
                    .register, .clear => try self.queueRender(),
                    .support, .query => {},
                }
                if (resp) |r| {
                    var buf: [terminal.apc.glyph.Response.max_wire_bytes]u8 = undefined;
                    var writer: std.Io.Writer = .fixed(&buf);
                    try r.formatWire(&writer);
                    const final = writer.buffered();
                    log.debug("glyph protocol response: {x}", .{final});
                    self.messageWriter(try termio.Message.writeReq(self.alloc, final));
                }
            },
        }
    }
    inline fn bell(self: *StreamHandler) void {
        self.surfaceMessageWriter(.ring_bell);
    }
    inline fn horizontalTab(self: *StreamHandler, count: u16) void {
        for (0..count) |_| {
            const x = self.terminal.screens.active.cursor.x;
            self.terminal.horizontalTab();
            if (x == self.terminal.screens.active.cursor.x) break;
        }
    }
    inline fn horizontalTabBack(self: *StreamHandler, count: u16) void {
        for (0..count) |_| {
            const x = self.terminal.screens.active.cursor.x;
            self.terminal.horizontalTabBack();
            if (x == self.terminal.screens.active.cursor.x) break;
        }
    }
    inline fn linefeed(self: *StreamHandler) !void {
        try self.terminal.index();
    }
    pub inline fn reverseIndex(self: *StreamHandler) !void {
        self.terminal.reverseIndex();
    }
    pub inline fn index(self: *StreamHandler) !void {
        try self.terminal.index();
    }
    pub inline fn nextLine(self: *StreamHandler) !void {
        try self.terminal.index();
        self.terminal.carriageReturn();
    }
    pub fn setModifyKeyFormat(self: *StreamHandler, format: terminal.ModifyKeyFormat) !void {
        self.terminal.flags.modify_other_keys_2 = false;
        switch (format) {
            .other_keys_numeric => self.terminal.flags.modify_other_keys_2 = true,
            else => {},
        }
    }
    fn requestMode(self: *StreamHandler, mode: terminal.Mode) !void {
        self.sendModeReport(self.terminal.modes.getReport(.fromMode(mode)));
    }
    fn requestModeUnknown(self: *StreamHandler, mode_raw: u16, ansi: bool) !void {
        self.sendModeReport(self.terminal.modes.getReport(.{ .value = mode_raw, .ansi = ansi }));
    }
    fn reportXtChecksum(self: *StreamHandler, req: terminal.xt_checksum.Request) void {
        if (!self.xt_checksum_report) return;
        var data: termio.Message.WriteReq.Small.Array = undefined;
        var writer: std.Io.Writer = .fixed(&data);
        terminal.xt_checksum.encode(
            &writer,
            req.id,
            self.terminal.rectXtChecksum(req),
        ) catch |err| {
            log.err("error encoding checksum report err={}", .{err});
            return;
        };
        self.messageWriter(.{ .write_small = .{
            .data = data,
            .len = @intCast(writer.buffered().len),
        } });
    }
    fn sendModeReport(self: *StreamHandler, report: terminal.modes.Report) void {
        var data: termio.Message.WriteReq.Small.Array = undefined;
        var writer: std.Io.Writer = .fixed(&data);
        report.encode(&writer) catch |err| {
            log.err("error encoding mode report err={}", .{err});
            return;
        };
        self.messageWriter(.{ .write_small = .{
            .data = data,
            .len = @intCast(writer.buffered().len),
        } });
    }
    pub fn setMode(self: *StreamHandler, mode: terminal.Mode, enabled: bool) !void {
        if (mode == .cursor_blinking and
            self.terminal.cursor.default_blink != null)
        {
            return;
        }
        self.terminal.modes.set(mode, enabled);
        switch (mode) {
            .autorepeat => {},
            .reverse_colors => self.terminal.flags.dirty.reverse_colors = true,
            .origin => self.terminal.setCursorPos(1, 1),
            .enable_left_and_right_margin => if (!enabled) {
                self.terminal.scrolling_region.left = 0;
                self.terminal.scrolling_region.right = self.terminal.cols - 1;
            },
            .alt_screen_legacy => {
                try self.terminal.switchScreenMode(.@"47", enabled);
            },
            .alt_screen => {
                try self.terminal.switchScreenMode(.@"1047", enabled);
            },
            .alt_screen_save_cursor_clear_enter => {
                try self.terminal.switchScreenMode(.@"1049", enabled);
            },
            .save_cursor => {
                if (enabled) {
                    self.terminal.saveCursor();
                } else {
                    self.terminal.restoreCursor();
                }
            },
            .enable_mode_3 => {
                const grid_size = self.size.grid();
                self.terminal.resize(
                    self.alloc,
                    .{
                        .cols = grid_size.columns,
                        .rows = grid_size.rows,
                    },
                ) catch |err| {
                    log.err("error updating terminal size: {}", .{err});
                };
            },
            .@"132_column" => try self.terminal.deccolm(
                self.alloc,
                if (enabled) .@"132_cols" else .@"80_cols",
            ),
            .synchronized_output => {
                if (enabled) self.messageWriter(.{ .start_synchronized_output = {} });
            },
            .linefeed => {
                self.messageWriter(.{ .linefeed_mode = enabled });
            },
            .in_band_size_reports => if (enabled) self.messageWriter(.{
                .size_report = .mode_2048,
            }),
            .report_visibility => if (enabled) self.messageWriter(.{
                .visibility_report = .{
                    .visible = self.terminal.flags.visible,
                    .force = true,
                },
            }),
            .focus_event => if (enabled) self.messageWriter(.{
                .focused = self.terminal.flags.focused,
            }),
            .mouse_event_x10 => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .x10;
                    try self.setMouseShape(.default);
                } else {
                    self.terminal.flags.mouse_event = .none;
                    try self.setMouseShape(.text);
                }
            },
            .mouse_event_normal => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .normal;
                    try self.setMouseShape(.default);
                } else {
                    self.terminal.flags.mouse_event = .none;
                    try self.setMouseShape(.text);
                }
            },
            .mouse_event_button => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .button;
                    try self.setMouseShape(.default);
                } else {
                    self.terminal.flags.mouse_event = .none;
                    try self.setMouseShape(.text);
                }
            },
            .mouse_event_any => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .any;
                    try self.setMouseShape(.default);
                } else {
                    self.terminal.flags.mouse_event = .none;
                    try self.setMouseShape(.text);
                }
            },
            .mouse_format_utf8 => self.terminal.flags.mouse_format = if (enabled) .utf8 else .x10,
            .mouse_format_sgr => self.terminal.flags.mouse_format = if (enabled) .sgr else .x10,
            .mouse_format_urxvt => self.terminal.flags.mouse_format = if (enabled) .urxvt else .x10,
            .mouse_format_sgr_pixels => self.terminal.flags.mouse_format = if (enabled) .sgr_pixels else .x10,
            else => {},
        }
    }
    inline fn startHyperlink(self: *StreamHandler, uri: []const u8, id: ?[]const u8) !void {
        try self.terminal.screens.active.startHyperlink(uri, id);
    }
    pub inline fn endHyperlink(self: *StreamHandler) !void {
        self.terminal.screens.active.endHyperlink();
    }
    pub fn deviceAttributes(
        self: *StreamHandler,
        req: terminal.DeviceAttributeReq,
    ) !void {
        switch (req) {
            .primary => self.messageWriter(.{
                .write_stable = if (self.clipboard_write != .deny)
                    "\x1B[?62;22;52c"
                else
                    "\x1B[?62;22c",
            }),
            .secondary => self.messageWriter(.{
                .write_stable = "\x1B[>1;10;0c",
            }),
            else => log.warn("unimplemented device attributes req: {}", .{req}),
        }
    }
    fn cursorReportPos(self: *StreamHandler) struct { x: usize, y: usize } {
        return if (self.terminal.modes.get(.origin)) .{
            .x = self.terminal.screens.active.cursor.x -| self.terminal.scrolling_region.left,
            .y = self.terminal.screens.active.cursor.y -| self.terminal.scrolling_region.top,
        } else .{
            .x = self.terminal.screens.active.cursor.x,
            .y = self.terminal.screens.active.cursor.y,
        };
    }
    pub fn deviceStatusReport(
        self: *StreamHandler,
        req: terminal.device_status.Request,
    ) !void {
        switch (req) {
            .operating_status => self.messageWriter(.{ .write_stable = "\x1B[0n" }),
            .cursor_position => {
                const pos = self.cursorReportPos();
                var msg: termio.Message = .{ .write_small = .{} };
                const resp = try std.fmt.bufPrint(&msg.write_small.data, "\x1B[{};{}R", .{
                    pos.y + 1,
                    pos.x + 1,
                });
                msg.write_small.len = @intCast(resp.len);
                self.messageWriter(msg);
            },
            .cursor_position_extended => {
                const pos = self.cursorReportPos();
                var msg: termio.Message = .{ .write_small = .{} };
                const resp = try std.fmt.bufPrint(&msg.write_small.data, "\x1B[?{};{};1R", .{
                    pos.y + 1,
                    pos.x + 1,
                });
                msg.write_small.len = @intCast(resp.len);
                self.messageWriter(msg);
            },
            .color_scheme => self.messageWriter(.{ .color_scheme_report = .{ .force = true } }),
            .visibility => self.messageWriter(.{ .visibility_report = .{
                .visible = self.terminal.flags.visible,
                .force = true,
            } }),
        }
    }
    pub inline fn decaln(self: *StreamHandler) !void {
        try self.terminal.decaln();
    }
    pub inline fn saveCursor(self: *StreamHandler) !void {
        self.terminal.saveCursor();
    }
    pub inline fn restoreCursor(self: *StreamHandler) !void {
        self.terminal.restoreCursor();
    }
    pub fn enquiry(self: *StreamHandler) !void {
        log.debug("sending enquiry response={s}", .{self.enquiry_response});
        self.messageWriter(try termio.Message.writeReq(self.alloc, self.enquiry_response));
    }
    fn configureCharset(
        self: *StreamHandler,
        slot: terminal.CharsetSlot,
        set: terminal.Charset,
    ) void {
        self.terminal.configureCharset(slot, set);
    }
    pub fn fullReset(
        self: *StreamHandler,
    ) !void {
        self.terminal.fullReset();
        try self.setMouseShape(.text);
        self.kitty_clipboard_grants.deinit(self.alloc);
        self.kitty_clipboard_grants = .{};
        self.messageWriter(.{ .color_scheme_report = .{ .force = false } });
        self.progressReport(.{ .state = .remove });
    }
    pub fn kittyClipboardGrant(
        self: *StreamHandler,
        pw: []const u8,
        dir: terminal.kitty.clipboard.Grants.Direction,
    ) error{OutOfMemory}!void {
        try self.kitty_clipboard_grants.grant(self.alloc, pw, dir, false);
    }
    pub fn queryKittyKeyboard(self: *StreamHandler) !void {
        log.debug("querying kitty keyboard mode", .{});
        var data: termio.Message.WriteReq.Small.Array = undefined;
        const resp = try std.fmt.bufPrint(&data, "\x1b[?{}u", .{
            self.terminal.screens.active.kitty_keyboard.current().int(),
        });
        self.messageWriter(.{
            .write_small = .{
                .data = data,
                .len = @intCast(resp.len),
            },
        });
    }
    pub fn reportXtversion(
        self: *StreamHandler,
    ) !void {
        log.debug("reporting XTVERSION: wasp {s}", .{build_config.version_string});
        var buf: [288]u8 = undefined;
        const resp = try std.fmt.bufPrint(
            &buf,
            "\x1BP>|{s} {s}\x1B\\",
            .{
                "wasp",
                build_config.version_string,
            },
        );
        const msg = try termio.Message.writeReq(self.alloc, resp);
        self.messageWriter(msg);
    }
    fn windowTitle(self: *StreamHandler, title: []const u8) !void {
        var buf: [256]u8 = undefined;
        if (title.len >= buf.len) {
            log.warn("change title requested larger than our buffer size, ignoring", .{});
            return;
        }
        self.terminal.setTitle(title) catch |err| {
            log.warn("error setting title in terminal state: {}", .{err});
        };
        @memcpy(buf[0..title.len], title);
        buf[title.len] = 0;
        if (title.len == 0) {
            if (self.terminal.getPwd()) |pwd| pwd: {
                if (pwd.len >= buf.len) break :pwd;
                @memcpy(buf[0..pwd.len], pwd);
                buf[pwd.len] = 0;
            }
            self.surfaceMessageWriter(.{ .set_title = buf });
            self.seen_title = false;
            return;
        }
        self.seen_title = true;
        self.surfaceMessageWriter(.{ .set_title = buf });
    }
    inline fn setMouseShape(
        self: *StreamHandler,
        shape: terminal.MouseShape,
    ) !void {
        if (self.terminal.mouse_shape == shape) return;
        self.terminal.mouse_shape = shape;
        self.surfaceMessageWriter(.{ .set_mouse_shape = shape });
    }
    fn clipboardContents(self: *StreamHandler, kind: u8, data: []const u8) !void {
        const clipboard_type: apprt.Clipboard = switch (kind) {
            'c' => .standard,
            's' => .selection,
            'p' => .primary,
            else => .standard,
        };
        if (data.len == 1 and data[0] == '?') {
            self.surfaceMessageWriter(.{ .clipboard_read = clipboard_type });
            return;
        }
        self.surfaceMessageWriter(.{
            .clipboard_write = .{
                .req = try apprt.surface.Message.WriteReq.init(
                    self.alloc,
                    data,
                ),
                .clipboard_type = clipboard_type,
            },
        });
    }
    fn kittyClipboard(
        self: *StreamHandler,
        v: terminal.osc.Command.KittyClipboardProtocol,
    ) error{ OutOfMemory, WriteFailed }!void {
        const kitty_clipboard = terminal.kitty.clipboard;
        var arena: std.heap.ArenaAllocator = .init(self.alloc);
        defer arena.deinit();
        const meta = (kitty_clipboard.Metadata.parse(
            arena.allocator(),
            v.metadata,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidValue => {
                const state = self.kitty_clipboard_write orelse return;
                switch (kitty_clipboard.Metadata.operation(v.metadata) orelse return) {
                    .wdata, .walias => try self.kittyClipboardWriteFinish(
                        state,
                        .EINVAL,
                        v.terminator,
                    ),
                    .read, .write => {},
                }
                return;
            },
        }) orelse return;
        switch (meta.op) {
            .read => try self.kittyClipboardRead(
                &meta,
                v.payload orelse "",
                v.terminator,
            ),
            .write => try self.kittyClipboardWriteBegin(
                &meta,
                v.terminator,
            ),
            .wdata => try self.kittyClipboardWriteData(
                &meta,
                v.payload orelse "",
                v.terminator,
            ),
            .walias => try self.kittyClipboardWriteAlias(
                &meta,
                v.payload orelse "",
                v.terminator,
            ),
        }
    }
    fn kittyClipboardRead(
        self: *StreamHandler,
        meta: *const terminal.kitty.clipboard.Metadata,
        payload: []const u8,
        terminator: terminal.osc.Terminator,
    ) !void {
        const kitty_clipboard = terminal.kitty.clipboard;
        var arena: std.heap.ArenaAllocator = .init(self.alloc);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const decoded = kitty_clipboard.Payload.init(
            alloc,
            payload,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => {
                arena.deinit();
                return;
            },
        };
        if (!decoded.isValidUtf8()) {
            arena.deinit();
            return;
        }
        var mimes_buf: [kitty_clipboard.max_read_mimes][]const u8 = undefined;
        var mimes_len: usize = 0;
        var list = false;
        var it = decoded.mimeIterator();
        while (it.next()) |mime| {
            if (std.mem.eql(u8, mime, kitty_clipboard.targets_mime)) {
                list = true;
                continue;
            }
            if (mimes_len == mimes_buf.len) continue;
            mimes_buf[mimes_len] = mime;
            mimes_len += 1;
        }
        const pw: []const u8 = if (meta.name.len > 0) meta.pw else "";
        const granted = self.kittyClipboardReadGranted(pw, mimes_len);
        const req = try alloc.create(apprt.ClipboardRequest.KittyRead);
        const mimes = try alloc.alloc([:0]const u8, mimes_len);
        for (mimes_buf[0..mimes_len], mimes) |src, *dst| {
            dst.* = try alloc.dupeZ(u8, src);
        }
        const id = try alloc.dupe(u8, meta.id);
        const pw_owned = try alloc.dupe(u8, pw);
        const name_owned = try alloc.dupeZ(u8, meta.name);
        req.* = .{
            .arena = arena,
            .location = switch (meta.loc) {
                .primary => .primary,
                else => .standard,
            },
            .mimes = mimes,
            .list = list,
            .id = id,
            .pw = pw_owned,
            .name = name_owned,
            .granted = granted,
            .terminator = terminator,
        };
        self.surfaceMessageWriter(.{ .kitty_clipboard_read = req });
    }
    fn kittyClipboardReadGranted(
        self: *StreamHandler,
        pw: []const u8,
        mimes_len: usize,
    ) bool {
        if (terminal.kitty.clipboard.readPromptExempt(mimes_len)) return false;
        return self.kitty_clipboard_grants.use(self.alloc, pw, .read);
    }
    fn kittyClipboardWriteBegin(
        self: *StreamHandler,
        meta: *const terminal.kitty.clipboard.Metadata,
        terminator: terminal.osc.Terminator,
    ) error{ OutOfMemory, WriteFailed }!void {
        self.kittyClipboardWriteAbort();
        if (self.clipboard_write == .deny) {
            log.info("application attempted to write clipboard, but 'clipboard-write' is set to deny", .{});
            try self.kittyClipboardWriteStatus(
                .EPERM,
                meta.id,
                terminator,
            );
            return;
        }
        const state = try self.alloc.create(terminal.kitty.clipboard.WriteState);
        errdefer self.alloc.destroy(state);
        state.* = try .init(self.alloc, meta, .{
            .max_size = self.clipboard_write_limit,
        });
        self.kitty_clipboard_write = state;
    }
    fn kittyClipboardWriteData(
        self: *StreamHandler,
        meta: *const terminal.kitty.clipboard.Metadata,
        payload: []const u8,
        terminator: terminal.osc.Terminator,
    ) error{ OutOfMemory, WriteFailed }!void {
        const state = self.kitty_clipboard_write orelse return;
        if (meta.mime.len == 0) return self.kittyClipboardWriteCommit(
            state,
            terminator,
        );
        state.data(
            self.alloc,
            meta,
            payload,
        ) catch |err| switch (err) {
            error.OutOfMemory => {
                try self.kittyClipboardWriteFinish(
                    state,
                    .EIO,
                    terminator,
                );
                return error.OutOfMemory;
            },
            error.TooLarge => try self.kittyClipboardWriteFinish(
                state,
                .EFBIG,
                terminator,
            ),
            error.Invalid => try self.kittyClipboardWriteFinish(
                state,
                .EINVAL,
                terminator,
            ),
        };
    }
    fn kittyClipboardWriteAlias(
        self: *StreamHandler,
        meta: *const terminal.kitty.clipboard.Metadata,
        payload: []const u8,
        terminator: terminal.osc.Terminator,
    ) error{ OutOfMemory, WriteFailed }!void {
        const state = self.kitty_clipboard_write orelse return;
        if (meta.mime.len == 0) return self.kittyClipboardWriteFinish(
            state,
            .EINVAL,
            terminator,
        );
        state.alias(
            self.alloc,
            meta,
            payload,
        ) catch |err| switch (err) {
            error.OutOfMemory => {
                try self.kittyClipboardWriteFinish(
                    state,
                    .EIO,
                    terminator,
                );
                return error.OutOfMemory;
            },
            error.Invalid => try self.kittyClipboardWriteFinish(
                state,
                .EINVAL,
                terminator,
            ),
        };
    }
    fn kittyClipboardWriteCommit(
        self: *StreamHandler,
        state: *terminal.kitty.clipboard.WriteState,
        terminator: terminal.osc.Terminator,
    ) error{ OutOfMemory, WriteFailed }!void {
        self.kittyClipboardWriteSend(
            state,
            terminator,
        ) catch |err| switch (err) {
            error.OutOfMemory => {
                try self.kittyClipboardWriteFinish(
                    state,
                    .EIO,
                    terminator,
                );
                return error.OutOfMemory;
            },
            error.Invalid => return try self.kittyClipboardWriteFinish(
                state,
                .EINVAL,
                terminator,
            ),
        };
        self.kittyClipboardWriteAbort();
    }
    fn kittyClipboardWriteSend(
        self: *StreamHandler,
        state: *terminal.kitty.clipboard.WriteState,
        terminator: terminal.osc.Terminator,
    ) error{ OutOfMemory, Invalid }!void {
        const committed = try state.commit(self.alloc);
        defer committed.deinit(self.alloc);
        const pw: []const u8 = if (committed.name.len > 0) committed.pw else "";
        const granted = self.kitty_clipboard_grants.use(self.alloc, pw, .write);
        var arena: std.heap.ArenaAllocator = .init(self.alloc);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const req = try alloc.create(apprt.ClipboardRequest.KittyWrite);
        const contents = try alloc.alloc(
            apprt.ClipboardContent,
            committed.contents.len,
        );
        for (committed.contents, contents) |src, *dst| dst.* = .{
            .mime = try alloc.dupeZ(u8, src.mime),
            .data = try alloc.dupeZ(u8, src.data),
        };
        const id = try alloc.dupe(u8, committed.id);
        const pw_owned = try alloc.dupe(u8, pw);
        const name_owned = try alloc.dupeZ(u8, committed.name);
        req.* = .{
            .arena = arena,
            .location = switch (committed.loc) {
                .primary => .primary,
                else => .standard,
            },
            .contents = contents,
            .id = id,
            .pw = pw_owned,
            .name = name_owned,
            .granted = granted,
            .terminator = terminator,
        };
        self.surfaceMessageWriter(.{ .kitty_clipboard_write = req });
    }
    fn kittyClipboardWriteFinish(
        self: *StreamHandler,
        state: *const terminal.kitty.clipboard.WriteState,
        status: terminal.kitty.clipboard.Status,
        terminator: terminal.osc.Terminator,
    ) error{ OutOfMemory, WriteFailed }!void {
        defer self.kittyClipboardWriteAbort();
        try self.kittyClipboardWriteStatus(status, state.id, terminator);
    }
    fn kittyClipboardWriteStatus(
        self: *StreamHandler,
        status: terminal.kitty.clipboard.Status,
        id: []const u8,
        terminator: terminal.osc.Terminator,
    ) error{ OutOfMemory, WriteFailed }!void {
        var stream: std.Io.Writer.Allocating = .init(self.alloc);
        defer stream.deinit();
        try (terminal.kitty.clipboard.Response{
            .op = .write,
            .status = status,
            .id = id,
            .terminator = terminator,
        }).encode(&stream.writer);
        self.messageWriter(.{ .write_alloc = .{
            .alloc = self.alloc,
            .data = try stream.toOwnedSlice(),
        } });
    }
    fn kittyClipboardWriteAbort(self: *StreamHandler) void {
        if (self.kitty_clipboard_write) |state| {
            state.deinit(self.alloc);
            self.alloc.destroy(state);
            self.kitty_clipboard_write = null;
        }
    }
    fn semanticPrompt(
        self: *StreamHandler,
        cmd: Stream.Action.SemanticPrompt,
    ) !void {
        switch (cmd.action) {
            .end_input_start_output => {
                self.surfaceMessageWriter(.start_command);
            },
            .end_command => {
                const code: u8 = code: {
                    const raw: i32 = cmd.readOption(.exit_code) orelse 0;
                    break :code std.math.cast(u8, raw) orelse 1;
                };
                self.surfaceMessageWriter(.{ .stop_command = code });
            },
            .end_prompt_start_input,
            .end_prompt_start_input_terminate_eol,
            .fresh_line,
            .fresh_line_new_prompt,
            .new_command,
            .prompt_start,
            => {},
        }
        try self.terminal.semanticPrompt(cmd);
    }
    fn reportPwd(self: *StreamHandler, url: []const u8) !void {
        if (url.len == 0) {
            self.terminal.setPwd("") catch unreachable;
            if (!self.seen_title) {
                try self.windowTitle("");
                assert(!self.seen_title);
            }
            self.surfaceMessageWriter(.{ .pwd_change = .{ .stable = "" } });
            return;
        }
        if (builtin.os.tag == .windows) {
            log.warn("reportPwd unimplemented on windows", .{});
            return;
        }
        const uri: std.Uri = internal_os.uri.parse(url, .{
            .mac_address = comptime builtin.os.tag != .macos,
            .raw_path = std.mem.startsWith(u8, url, "kitty-shell-cwd://"),
        }) catch |e| {
            log.warn("invalid url in OSC 7: {}", .{e});
            return;
        };
        if (!std.mem.eql(u8, "file", uri.scheme) and
            !std.mem.eql(u8, "kitty-shell-cwd", uri.scheme))
        {
            log.warn("OSC 7 scheme must be file or kitty-shell-cwd, got: {s}", .{uri.scheme});
            return;
        }
        var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = uri.getHost(&host_buffer) catch |err| switch (err) {
            error.UriMissingHost => {
                log.warn("OSC 7 uri must contain a hostname: {}", .{err});
                return;
            },
        };
        const host_valid = internal_os.hostname.isLocal(host.bytes) catch |err| switch (err) {
            error.PermissionDenied,
            error.Unexpected,
            => {
                log.warn("failed to get hostname for OSC 7 validation: {}", .{err});
                return;
            },
        };
        if (!host_valid) {
            log.warn("OSC 7 host ({s}) must be local", .{host.bytes});
            return;
        }
        var arena_alloc: std.heap.ArenaAllocator = .init(self.alloc);
        var stack_alloc = std.heap.stackFallback(1024, arena_alloc.allocator());
        defer arena_alloc.deinit();
        const path = try uri.path.toRawMaybeAlloc(stack_alloc.get());
        log.debug("terminal pwd: {s}", .{path});
        try self.terminal.setPwd(path);
        if (apprt.surface.Message.WriteReq.init(self.alloc, path)) |req| {
            self.surfaceMessageWriter(.{ .pwd_change = req });
        } else |err| {
            log.warn("error notifying surface of pwd change err={}", .{err});
        }
        if (!self.seen_title) {
            try self.windowTitle(path);
            self.seen_title = false;
        }
    }
    fn colorOperation(
        self: *StreamHandler,
        op: terminal.osc.color.Operation,
        requests: *const terminal.osc.color.List,
        terminator: terminal.osc.Terminator,
    ) !void {
        _ = op;
        if (requests.count() == 0) return;
        var buffer: [1024]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buffer);
        const alloc = fba.allocator();
        var response: std.Io.Writer.Allocating = .init(alloc);
        var it = requests.constIterator(0);
        while (it.next()) |req| {
            switch (req.*) {
                .set => |set| {
                    switch (set.target) {
                        .palette => |i| {
                            self.terminal.flags.dirty.palette = true;
                            self.terminal.colors.palette.set(i, set.color);
                        },
                        .dynamic => |dynamic| switch (dynamic) {
                            .foreground => self.terminal.colors.foreground.set(set.color),
                            .background => self.terminal.colors.background.set(set.color),
                            .cursor => self.terminal.colors.cursor.set(set.color),
                            .pointer_foreground,
                            .pointer_background,
                            .tektronix_foreground,
                            .tektronix_background,
                            .highlight_background,
                            .tektronix_cursor,
                            .highlight_foreground,
                            => log.info("setting dynamic color {s} not implemented", .{
                                @tagName(dynamic),
                            }),
                        },
                        .special => log.info("setting special colors not implemented", .{}),
                    }
                    self.surfaceMessageWriter(.{ .color_change = .{
                        .target = set.target,
                        .color = set.color,
                    } });
                },
                .reset => |target| switch (target) {
                    .palette => |i| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.colors.palette.reset(i);
                        self.surfaceMessageWriter(.{
                            .color_change = .{
                                .target = target,
                                .color = self.terminal.colors.palette.current[i],
                            },
                        });
                    },
                    .dynamic => |dynamic| switch (dynamic) {
                        .foreground => {
                            self.terminal.colors.foreground.reset();
                            if (self.terminal.colors.foreground.default) |c| {
                                self.surfaceMessageWriter(.{ .color_change = .{
                                    .target = target,
                                    .color = c,
                                } });
                            }
                        },
                        .background => {
                            self.terminal.colors.background.reset();
                            if (self.terminal.colors.background.default) |c| {
                                self.surfaceMessageWriter(.{ .color_change = .{
                                    .target = target,
                                    .color = c,
                                } });
                            }
                        },
                        .cursor => {
                            self.terminal.colors.cursor.reset();
                            if (self.terminal.colors.cursor.default) |c| {
                                self.surfaceMessageWriter(.{ .color_change = .{
                                    .target = target,
                                    .color = c,
                                } });
                            }
                        },
                        .pointer_foreground,
                        .pointer_background,
                        .tektronix_foreground,
                        .tektronix_background,
                        .highlight_background,
                        .tektronix_cursor,
                        .highlight_foreground,
                        => log.warn("resetting dynamic color {s} not implemented", .{
                            @tagName(dynamic),
                        }),
                    },
                    .special => log.info("resetting special colors not implemented", .{}),
                },
                .reset_palette => {
                    const mask = &self.terminal.colors.palette.mask;
                    var mask_it = mask.iterator(.{});
                    while (mask_it.next()) |i| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.colors.palette.reset(@intCast(i));
                        self.surfaceMessageWriter(.{
                            .color_change = .{
                                .target = .{ .palette = @intCast(i) },
                                .color = self.terminal.colors.palette.current[i],
                            },
                        });
                    }
                    mask.* = .initEmpty();
                },
                .reset_special => log.warn(
                    "resetting all special colors not implemented",
                    .{},
                ),
                .query => |kind| report: {
                    if (self.osc_color_report_format == .none) break :report;
                    const color = switch (kind) {
                        .palette => |i| self.terminal.colors.palette.current[i],
                        .dynamic => |dynamic| switch (dynamic) {
                            .foreground => self.terminal.colors.foreground.get().?,
                            .background => self.terminal.colors.background.get().?,
                            .cursor => self.terminal.colors.cursor.get() orelse
                                self.terminal.colors.foreground.get().?,
                            .pointer_foreground,
                            .pointer_background,
                            .tektronix_foreground,
                            .tektronix_background,
                            .highlight_background,
                            .tektronix_cursor,
                            .highlight_foreground,
                            => {
                                log.info(
                                    "reporting dynamic color {s} not implemented",
                                    .{@tagName(dynamic)},
                                );
                                break :report;
                            },
                        },
                        .special => {
                            log.info("reporting special colors not implemented", .{});
                            break :report;
                        },
                    };
                    switch (self.osc_color_report_format) {
                        .@"16-bit" => switch (kind) {
                            .palette => |i| try response.writer.print(
                                "\x1b]4;{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}",
                                .{
                                    i,
                                    @as(u16, color.r) * 257,
                                    @as(u16, color.g) * 257,
                                    @as(u16, color.b) * 257,
                                },
                            ),
                            .dynamic => |dynamic| try response.writer.print(
                                "\x1b]{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}",
                                .{
                                    @intFromEnum(dynamic),
                                    @as(u16, color.r) * 257,
                                    @as(u16, color.g) * 257,
                                    @as(u16, color.b) * 257,
                                },
                            ),
                            .special => unreachable,
                        },
                        .@"8-bit" => switch (kind) {
                            .palette => |i| try response.writer.print(
                                "\x1b]4;{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}",
                                .{
                                    i,
                                    @as(u16, color.r),
                                    @as(u16, color.g),
                                    @as(u16, color.b),
                                },
                            ),
                            .dynamic => |dynamic| try response.writer.print(
                                "\x1b]{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}",
                                .{
                                    @intFromEnum(dynamic),
                                    @as(u16, color.r),
                                    @as(u16, color.g),
                                    @as(u16, color.b),
                                },
                            ),
                            .special => unreachable,
                        },
                        .none => unreachable,
                    }
                    try response.writer.writeAll(terminator.string());
                },
            }
        }
        if (response.writer.end > 0) {
            const msg = try termio.Message.writeReq(self.alloc, response.writer.buffered());
            self.messageWriter(msg);
        }
    }
    fn showDesktopNotification(
        self: *StreamHandler,
        title: []const u8,
        body: []const u8,
    ) !void {
        self.surfaceMessageWriter(.{
            .desktop_notification = .init(title, body),
        });
    }
    pub fn sendSizeReport(self: *StreamHandler, style: terminal.SizeReportStyle) void {
        switch (style) {
            .csi_14_t => self.messageWriter(.{ .size_report = .csi_14_t }),
            .csi_16_t => self.messageWriter(.{ .size_report = .csi_16_t }),
            .csi_18_t => self.messageWriter(.{ .size_report = .csi_18_t }),
            .csi_19_t => self.messageWriter(.{ .size_report = .csi_19_t }),
            .csi_21_t => self.surfaceMessageWriter(.{ .report_title = .csi_21_t }),
        }
    }
    fn kittyColorReport(
        self: *StreamHandler,
        request: terminal.kitty.color.OSC,
    ) !void {
        var stream: std.Io.Writer.Allocating = .init(self.alloc);
        defer stream.deinit();
        const writer = &stream.writer;
        for (request.list.items) |item| {
            switch (item) {
                .query => |key| {
                    if (stream.written().len == 0) try writer.writeAll("\x1b]21");
                    const color: terminal.color.RGB = switch (key) {
                        .palette => |palette| self.terminal.colors.palette.current[palette],
                        .special => |special| switch (special) {
                            .foreground => self.terminal.colors.foreground.get(),
                            .background => self.terminal.colors.background.get(),
                            .cursor => self.terminal.colors.cursor.get(),
                            else => {
                                log.warn("ignoring unsupported kitty color protocol key: {f}", .{key});
                                continue;
                            },
                        },
                    } orelse {
                        try writer.print(";{f}=", .{key});
                        continue;
                    };
                    try writer.print(
                        ";{f}=rgb:{x:0>2}/{x:0>2}/{x:0>2}",
                        .{ key, color.r, color.g, color.b },
                    );
                },
                .set => |v| switch (v.key) {
                    .palette => |palette| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.colors.palette.set(palette, v.color);
                    },
                    .special => |special| switch (special) {
                        .foreground => self.terminal.colors.foreground.set(v.color),
                        .background => self.terminal.colors.background.set(v.color),
                        .cursor => self.terminal.colors.cursor.set(v.color),
                        else => {
                            log.warn(
                                "ignoring unsupported kitty color protocol key: {f}",
                                .{v.key},
                            );
                            continue;
                        },
                    },
                },
                .reset => |key| switch (key) {
                    .palette => |palette| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.colors.palette.reset(palette);
                    },
                    .special => |special| switch (special) {
                        .foreground => self.terminal.colors.foreground.reset(),
                        .background => self.terminal.colors.background.reset(),
                        .cursor => self.terminal.colors.cursor.reset(),
                        else => {
                            log.warn(
                                "ignoring unsupported kitty color protocol key: {f}",
                                .{key},
                            );
                            continue;
                        },
                    },
                },
            }
        }
        if (stream.written().len > 0) {
            try writer.writeAll(request.terminator.string());
            self.messageWriter(.{
                .write_alloc = .{
                    .alloc = self.alloc,
                    .data = try stream.toOwnedSlice(),
                },
            });
        }
    }
    fn progressReport(self: *StreamHandler, report: terminal.osc.Command.ProgressReport) void {
        self.surfaceMessageWriter(.{ .progress_report = report });
    }
};
test "kitty clipboard read: targets-only never consumes a one-time grant" {
    const testing = std.testing;
    var handler: StreamHandler = undefined;
    handler.alloc = testing.allocator;
    handler.kitty_clipboard_grants = .{};
    defer handler.kitty_clipboard_grants.deinit(testing.allocator);
    try handler.kitty_clipboard_grants.grant(testing.allocator, "otp", .read, true);
    try testing.expect(!handler.kittyClipboardReadGranted("otp", 0));
    try testing.expect(handler.kittyClipboardReadGranted("otp", 1));
    try testing.expect(!handler.kittyClipboardReadGranted("otp", 1));
}
test "kitty clipboard write: oversized text replies EFBIG" {
    const testing = std.testing;
    var mailbox = try termio.Mailbox.initSPSC(testing.allocator);
    defer mailbox.deinit(testing.allocator);
    var mutex: std.Io.Mutex = .init;
    mutex.lockUncancelable(global.io());
    defer mutex.unlock(global.io());
    var renderer_state: renderer.State = .{
        .mutex = &mutex,
        .terminal = undefined,
    };
    var handler: StreamHandler = undefined;
    handler.alloc = testing.allocator;
    handler.termio_mailbox = &mailbox;
    handler.renderer_state = &renderer_state;
    handler.clipboard_write = .allow;
    handler.clipboard_write_limit = 4;
    handler.kitty_clipboard_write = null;
    defer handler.kittyClipboardWriteAbort();
    const begin: terminal.kitty.clipboard.Metadata = .{
        .op = .write,
        .id = "macos",
    };
    try handler.kittyClipboardWriteBegin(&begin, .st);
    const state = handler.kitty_clipboard_write.?;
    try state.data(
        testing.allocator,
        &.{ .op = .wdata, .mime = "text/plain" },
        "SGVsbA==",
    );
    try testing.expectError(error.TooLarge, state.data(
        testing.allocator,
        &.{ .op = .wdata, .mime = "text/plain" },
        "bw==",
    ));
    try handler.kittyClipboardWriteFinish(state, .EFBIG, .st);
    try testing.expect(handler.kitty_clipboard_write == null);
    const response = mailbox.spsc.queue.pop(global.io());
    try testing.expect(response != null);
    const msg = response.?;
    defer msg.deinit();
    switch (msg) {
        .write_alloc => |v| try testing.expectEqualStrings(
            "\x1B]5522;type=write:status=EFBIG:id=macos\x1B\\",
            v.data,
        ),
        else => try testing.expect(false),
    }
    try testing.expect(mailbox.spsc.queue.pop(global.io()) == null);
}
