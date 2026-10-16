const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("terminal_options");
const testing = std.testing;
const apc = @import("apc.zig");
const xt_checksum = @import("xt_checksum.zig");
const clipboard = @import("clipboard.zig");
const csi = @import("csi.zig");
const dcs = @import("dcs.zig");
const device_attributes = @import("device_attributes.zig");
const device_status = @import("device_status.zig");
const stream = @import("stream.zig");
const Action = stream.Action;
const Screen = @import("Screen.zig");
const color = @import("color.zig");
const modes = @import("modes.zig");
const osc = @import("osc.zig");
const osc_color = @import("osc/parsers/color.zig");
const kitty_clipboard = @import("kitty/clipboard.zig");
const kitty_color = @import("kitty/color.zig");
const paste_pkg = @import("paste.zig");
const kitty_dnd = @import("kitty/dnd.zig");
const lib = @import("lib.zig");
const size_report = @import("size_report.zig");
const simd = @import("../simd/root.zig");
const terminfo = @import("../terminfo/root.zig");
const Terminal = @import("Terminal.zig");
const log = std.log.scoped(.stream_terminal);
pub const Stream = stream.Stream(Handler);
pub const Handler = struct {
    terminal: *Terminal,
    semantic_failure: bool = false,
    effects: Effects = .readonly,
    title_report: bool = false,
    xt_checksum_report: bool = false,
    apc_handler: apc.Handler = .{},
    dcs_handler: dcs.Handler = .{},
    kitty_clipboard_write: ?*kitty_clipboard.WriteState = null,
    kitty_clipboard_grants: kitty_clipboard.Grants = .{},
    kitty_clipboard_write_max_bytes: usize = kitty_clipboard.max_write_size,
    unknown_sequence: ?*const fn (*Handler, UnknownSequence) void = null,
    terminfo_name: ?[]const u8 = null,
    pub const max_terminfo_name_bytes = 128;
    pub const Effects = struct {
        write_pty: ?*const fn (*Handler, []const u8) void,
        bell: ?*const fn (*Handler) void,
        desktop_notification: ?*const fn (*Handler, Action.ShowDesktopNotification) void,
        drag_and_drop: ?*const fn (*Handler, kitty_dnd.Event) void,
        color_scheme: ?*const fn (*Handler) ?device_status.ColorScheme,
        device_attributes: ?*const fn (*Handler) device_attributes.Attributes,
        enquiry: ?*const fn (*Handler) []const u8,
        size: ?*const fn (*Handler) ?size_report.Size,
        title_changed: ?*const fn (*Handler) void,
        pwd_changed: ?*const fn (*Handler) void,
        progress_report: ?*const fn (*Handler, osc.Command.ProgressReport) void,
        program_status: ?*const fn (*Handler, osc.Command.ProgramStatus.Report) void,
        semantic_prompt: ?*const fn (*Handler, SemanticPrompt) void,
        reset: ?*const fn (*Handler) void,
        resize_window: ?*const fn (*Handler, ResizeWindow) void,
        clipboard_write: ?*const fn (*Handler, clipboard.Write) void,
        clipboard_read: ?*const fn (*Handler, clipboard.Read) void,
        xtversion: ?*const fn (*Handler) []const u8,
        render_hold: ?*const fn (*Handler, bool) void,
        pub const readonly: Effects = .{
            .bell = null,
            .clipboard_read = null,
            .clipboard_write = null,
            .color_scheme = null,
            .desktop_notification = null,
            .device_attributes = null,
            .drag_and_drop = null,
            .enquiry = null,
            .progress_report = null,
            .program_status = null,
            .reset = null,
            .semantic_prompt = null,
            .resize_window = null,
            .size = null,
            .render_hold = null,
            .title_changed = null,
            .pwd_changed = null,
            .write_pty = null,
            .xtversion = null,
        };
    };
    pub const UnknownSequence = union(enum) {
        apc: String,
        osc: Osc,
        pub const String = struct {
            content: []const u8,
            truncated: bool,
        };
        pub const Osc = osc.Command.Unknown;
    };
    pub const ResizeWindow = union(enum) {
        grid: Grid,
        pub const Grid = Action.ResizeWindow;
    };
    pub const SemanticPrompt = struct {
        kind: Kind,
        prompt_kind: PromptKind = .primary,
        exit_code: ?i32 = null,
        command: []const u8 = "",
        err: []const u8 = "",
        pub const Kind = lib.Enum(lib.target, &.{
            "invalid",
            "prompt_start",
            "input_start",
            "output_start",
            "command_end",
        });
        pub const PromptKind = lib.Enum(lib.target, &.{
            "primary",
            "right",
            "continuation",
            "secondary",
        });
    };
    pub fn init(terminal: *Terminal) Handler {
        return .{
            .terminal = terminal,
        };
    }
    pub fn deinit(self: *Handler) void {
        self.kittyClipboardAbort();
        self.kitty_clipboard_grants.deinit(self.terminal.gpa());
        self.apc_handler.deinit();
        self.dcs_handler.deinit();
    }
    pub fn resize(self: *Handler, value: Terminal.Resize) !void {
        const sync = self.terminal.modes.get(.synchronized_output);
        try self.terminal.resize(self.terminal.gpa(), value);
        if (sync) self.renderHold(false);
        const cell_size = value.cell_size_px orelse return;
        if (!self.terminal.modes.get(.in_band_size_reports)) return;
        const write_pty = self.effects.write_pty orelse return;
        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
        size_report.encode(&writer, .mode_2048, .{
            .rows = value.rows,
            .columns = value.cols,
            .cell_width = cell_size.width,
            .cell_height = cell_size.height,
        }) catch unreachable;
        buf[writer.end] = 0;
        write_pty(self, buf[0..writer.end :0]);
    }
    pub const Paste = paste_pkg.Request;
    pub const PasteError = Allocator.Error || std.Io.RandomSecureError || error{
        UnsafePaste,
        ReadFailed,
        NoWritePty,
    };
    pub const paste_chunk_size = 4096;
    pub fn paste(self: *Handler, req: Paste) PasteError!bool {
        if (self.effects.write_pty == null) return error.NoWritePty;
        var buf: [paste_chunk_size]u8 = undefined;
        var pty: PtyWriter = .init(self, &buf);
        defer pty.writer.flush() catch unreachable;
        return paste_pkg.paste(.{
            .terminal = self.terminal,
            .alloc = self.terminal.gpa(),
            .kitty_clipboard = if (self.effects.clipboard_read != null) .{
                .grants = &self.kitty_clipboard_grants,
                .io = self.terminal.io(),
            } else null,
            .writer = &pty.writer,
        }, req) catch |err| switch (err) {
            error.WriteFailed => unreachable,
            error.ReadFailed,
            error.OutOfMemory,
            error.UnsafePaste,
            error.EntropyUnavailable,
            error.Canceled,
            => |e| e,
        };
    }
    pub fn vt(
        self: *Handler,
        comptime action: Action.Tag,
        value: Action.Value(action),
    ) void {
        self.vtFallible(action, value) catch |err| {
            self.semantic_failure = true;
            log.warn("error handling VT action action={} err={}", .{ action, err });
        };
    }
    fn unknownSequence(self: *Handler, value: UnknownSequence) void {
        const func = self.unknown_sequence orelse return;
        func(self, value);
    }
    inline fn vtFallible(
        self: *Handler,
        comptime action: Action.Tag,
        value: Action.Value(action),
    ) !void {
        switch (action) {
            .print => try self.terminal.print(value.cp),
            .print_slice => try self.terminal.printSlice(value.cps),
            .print_repeat => try self.terminal.printRepeat(value),
            .backspace => self.terminal.backspace(),
            .carriage_return => self.terminal.carriageReturn(),
            .linefeed => try self.terminal.linefeed(),
            .index => try self.terminal.index(),
            .next_line => {
                try self.terminal.index();
                self.terminal.carriageReturn();
            },
            .reverse_index => self.terminal.reverseIndex(),
            .cursor_up => self.terminal.cursorUp(value.value),
            .cursor_down => self.terminal.cursorDown(value.value),
            .cursor_left => self.terminal.cursorLeft(value.value),
            .cursor_right => self.terminal.cursorRight(value.value),
            .cursor_pos => self.terminal.setCursorPos(value.row, value.col),
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
            .erase_display_complete => self.terminal.eraseDisplay(.complete, value),
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
            .horizontal_tab => self.horizontalTab(value),
            .horizontal_tab_back => self.horizontalTabBack(value),
            .tab_clear_current => self.terminal.tabClear(.current),
            .tab_clear_all => self.terminal.tabClear(.all),
            .tab_set => self.terminal.tabSet(),
            .tab_reset => self.terminal.tabReset(),
            .set_mode => try self.setMode(value.mode, true),
            .reset_mode => try self.setMode(value.mode, false),
            .save_mode => self.terminal.modes.save(value.mode),
            .restore_mode => {
                const prev = self.terminal.modes.get(value.mode);
                const v = self.terminal.modes.restore(value.mode);
                if (value.mode == .synchronized_output) {
                    self.terminal.modes.set(value.mode, prev);
                }
                try self.setMode(value.mode, v);
            },
            .top_and_bottom_margin => self.terminal.setTopAndBottomMargin(value.top_left, value.bottom_right),
            .left_and_right_margin => self.terminal.setLeftAndRightMargin(value.top_left, value.bottom_right),
            .left_and_right_margin_ambiguous => {
                if (self.terminal.modes.get(.enable_left_and_right_margin)) {
                    self.terminal.setLeftAndRightMargin(0, 0);
                } else {
                    self.terminal.saveCursor();
                }
            },
            .save_cursor => self.terminal.saveCursor(),
            .restore_cursor => self.terminal.restoreCursor(),
            .invoke_charset => self.terminal.invokeCharset(value.bank, value.charset, value.locking),
            .configure_charset => self.terminal.configureCharset(value.slot, value.charset),
            .set_attribute => switch (value) {
                .unknown => {},
                else => try self.terminal.setAttribute(value),
            },
            .protected_mode_off => self.terminal.setProtectedMode(.off),
            .protected_mode_iso => self.terminal.setProtectedMode(.iso),
            .protected_mode_dec => self.terminal.setProtectedMode(.dec),
            .mouse_shift_capture => self.terminal.flags.mouse_shift_capture = if (value) .true else .false,
            .xt_checksum_extension => if (self.xt_checksum_report) {
                self.terminal.flags.xt_checksum = value.flags;
            },
            .kitty_keyboard_push => self.terminal.screens.active.kitty_keyboard.push(value.flags),
            .kitty_keyboard_pop => self.terminal.screens.active.kitty_keyboard.pop(@intCast(value)),
            .kitty_keyboard_set => self.terminal.screens.active.kitty_keyboard.set(.set, value.flags),
            .kitty_keyboard_set_or => self.terminal.screens.active.kitty_keyboard.set(.@"or", value.flags),
            .kitty_keyboard_set_not => self.terminal.screens.active.kitty_keyboard.set(.not, value.flags),
            .modify_key_format => {
                self.terminal.flags.modify_other_keys_2 = false;
                switch (value) {
                    .other_keys_numeric => self.terminal.flags.modify_other_keys_2 = true,
                    else => {},
                }
            },
            .active_status_display => self.terminal.status_display = value,
            .decaln => try self.terminal.decaln(),
            .soft_reset => self.terminal.softReset(),
            .full_reset => {
                const sync = self.terminal.modes.get(.synchronized_output);
                self.terminal.fullReset();
                if (sync) self.renderHold(false);
                self.kitty_clipboard_grants.deinit(self.terminal.gpa());
                self.kitty_clipboard_grants = .{};
                self.progressReport(.{ .state = .remove });
                self.programStatusReport(.{ .state = .clear });
                if (self.effects.reset) |func| func(self);
            },
            .start_hyperlink => try self.terminal.screens.active.startHyperlink(value.uri, value.id),
            .end_hyperlink => self.terminal.screens.active.endHyperlink(),
            .semantic_prompt => try self.semanticPrompt(value),
            .mouse_shape => self.terminal.mouse_shape = value,
            .mouse_shape_reset => self.terminal.mouse_shape = .text,
            .color_operation => self.colorOperation(
                &value.requests,
                value.terminator,
            ) catch |err| log.warn("error reporting OSC color err={}", .{err}),
            .kitty_color_report => self.kittyColorOperation(value) catch |err| {
                log.warn("error reporting Kitty colors err={}", .{err});
            },
            .kitty_clipboard => self.kittyClipboard(value) catch |err| {
                log.warn("error handling kitty clipboard err={}", .{err});
            },
            .apc_start => self.apc_handler.start(),
            .apc_put => self.apc_handler.feed(self.terminal.gpa(), value),
            .apc_put_slice => self.apc_handler.feedSlice(self.terminal.gpa(), value.bytes),
            .apc_end => self.apcEnd(value.terminated),
            .osc_unknown => self.unknownSequence(.{ .osc = value }),
            .bell => self.bell(),
            .show_desktop_notification => self.desktopNotification(value),
            .device_attributes => self.reportDeviceAttributes(value),
            .device_status => self.deviceStatus(value.request),
            .enquiry => self.reportEnquiry(),
            .kitty_keyboard_query => self.queryKittyKeyboard(),
            .request_mode => self.requestMode(value.mode),
            .request_mode_unknown => self.requestModeUnknown(value.mode, value.ansi),
            .size_report => self.reportSize(value),
            .window_title => try self.windowTitle(value.title),
            .report_pwd => try self.reportPwd(value.url),
            .progress_report => self.progressReport(value),
            .program_status => self.programStatus(value),
            .resize_window => self.resizeWindow(value),
            .xtversion => self.reportXtversion(),
            .request_xt_checksum => self.reportXtChecksum(value),
            .clipboard_contents => self.clipboardContents(
                value.kind,
                value.data,
                value.terminator,
            ) catch |err| {
                log.warn("error handling clipboard operation err={}", .{err});
            },
            .kitty_dnd => self.kittyDnd(value) catch |err| {
                log.warn("error handling kitty dnd err={}", .{err});
            },
            .dcs_hook => try self.dcsHook(value),
            .dcs_put => try self.dcsPut(value),
            .dcs_unhook => try self.dcsUnhook(),
            .title_push,
            .title_pop,
            => {},
        }
    }
    inline fn writePty(self: *Handler, data: []const u8) void {
        const func = self.effects.write_pty orelse return;
        func(self, data);
    }
    fn dcsHook(self: *Handler, value: Action.Value(.dcs_hook)) !void {
        var cmd = self.dcs_handler.hook(
            self.terminal.gpa(),
            value,
        ) orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
    }
    fn dcsPut(self: *Handler, value: u8) !void {
        var cmd = self.dcs_handler.put(value) orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
    }
    fn dcsUnhook(self: *Handler) !void {
        var cmd = self.dcs_handler.unhook() orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
    }
    fn dcsCommand(self: *Handler, cmd: *dcs.Command) !void {
        switch (cmd.*) {
            .decrqss => |request| {
                var response: [
                    dcs.Command.DECRQSS.max_response_bytes + 1
                ]u8 = undefined;
                const encoded = try request.encode(
                    self.terminal,
                    response[0 .. response.len - 1],
                );
                response[encoded.len] = 0;
                self.writePty(response[0..encoded.len :0]);
            },
            .xtgettcap => |*gettcap| {
                if (self.effects.write_pty == null) return;
                const map = comptime terminfo.wasp.xtgettcapMap();
                while (gettcap.next()) |key| {
                    if (std.mem.eql(u8, key, encoded_tn_key)) {
                        self.writeTerminfoName();
                        continue;
                    }
                    self.writePty(map.get(key) orelse continue);
                }
            },
            .tmux => {},
        }
    }
    const encoded_tn_key = &std.fmt.bytesToHex("TN", .upper);
    fn writeTerminfoName(self: *Handler) void {
        const name = self.terminfo_name orelse return;
        if (name.len == 0 or name.len > max_terminfo_name_bytes) return;
        const max_tn_response_bytes =
            comptime "\x1bP1+r".len + encoded_tn_key.len + "=".len +
            (max_terminfo_name_bytes * 2) + "\x1b\\".len +
            1;
        var buf: [max_tn_response_bytes]u8 = undefined;
        self.writePty(std.fmt.bufPrintZ(
            &buf,
            "\x1bP1+r" ++ encoded_tn_key ++ "={X}\x1b\\",
            .{name},
        ) catch unreachable);
    }
    fn bell(self: *Handler) void {
        const func = self.effects.bell orelse return;
        func(self);
    }
    fn desktopNotification(
        self: *Handler,
        notification: Action.ShowDesktopNotification,
    ) void {
        const func = self.effects.desktop_notification orelse return;
        func(self, notification);
    }
    fn semanticPrompt(self: *Handler, cmd: osc.Command.SemanticPrompt) !void {
        try self.terminal.semanticPrompt(cmd);
        const func = self.effects.semantic_prompt orelse return;
        switch (cmd.action) {
            .fresh_line => {},
            .fresh_line_new_prompt,
            .new_command,
            .prompt_start,
            => func(self, .{
                .kind = .prompt_start,
                .prompt_kind = if (cmd.readOption(.prompt_kind)) |v| switch (v) {
                    .initial => .primary,
                    .right => .right,
                    .continuation => .continuation,
                    .secondary => .secondary,
                } else .primary,
            }),
            .end_prompt_start_input,
            .end_prompt_start_input_terminate_eol,
            => func(self, .{ .kind = .input_start }),
            .end_input_start_output => {
                const alloc = self.terminal.gpa();
                const buf = alloc.alloc(u8, cmd.options_unvalidated.len) catch |err| {
                    log.warn("error allocating semantic prompt command line err={}", .{err});
                    func(self, .{ .kind = .output_start });
                    return;
                };
                defer alloc.free(buf);
                var writer: std.Io.Writer = .fixed(buf);
                const command: []const u8 = if (cmd.writeCommandLine(&writer))
                    writer.buffered()
                else |_|
                    "";
                func(self, .{ .kind = .output_start, .command = command });
            },
            .end_command => func(self, .{
                .kind = .command_end,
                .exit_code = cmd.readOption(.exit_code),
                .err = cmd.readOption(.err) orelse "",
            }),
        }
    }
    fn progressReport(self: *Handler, report: osc.Command.ProgressReport) void {
        const func = self.effects.progress_report orelse return;
        func(self, report);
    }
    fn programStatus(self: *Handler, cmd: osc.Command.ProgramStatus) void {
        switch (cmd) {
            .report => |report| self.programStatusReport(report),
            .query => |terminator| if (self.effects.program_status != null) {
                switch (terminator) {
                    inline else => |t| self.writePty(
                        "\x1b]7501;" ++
                            osc.program_status.query_reply ++
                            comptime t.string(),
                    ),
                }
            },
        }
    }
    fn programStatusReport(
        self: *Handler,
        report: osc.Command.ProgramStatus.Report,
    ) void {
        const func = self.effects.program_status orelse return;
        func(self, report);
    }
    fn resizeWindow(self: *Handler, size: Action.ResizeWindow) void {
        const func = self.effects.resize_window orelse return;
        func(self, .{ .grid = size });
    }
    fn clipboardContents(
        self: *Handler,
        kind: u8,
        data: []const u8,
        terminator: osc.Terminator,
    ) !void {
        const location: clipboard.Location = switch (kind) {
            's' => .selection,
            'p' => .primary,
            else => .standard,
        };
        if (data.len == 1 and data[0] == '?') {
            self.clipboardRead(location, terminator);
            return;
        }
        const func = self.effects.clipboard_write orelse return;
        if (data.len == 0) {
            func(self, .{
                .location = location,
                .contents = &.{},
                .name = "",
                .granted = false,
                .can_remember = false,
                .reply_ctx = self,
                .reply_fn = &ignoreWriteReply,
            });
            return;
        }
        const alloc = self.terminal.gpa();
        const buf = try alloc.alloc(u8, simd.base64.maxLen(data));
        defer alloc.free(buf);
        const decoded = simd.base64.decodeStrict(data, buf, .optional) catch {
            log.warn("OSC 52 clipboard write is not valid base64, ignoring", .{});
            return;
        };
        const contents = [_]clipboard.Content{.{
            .mime = "text/plain",
            .data = decoded,
        }};
        func(self, .{
            .location = location,
            .contents = &contents,
            .name = "",
            .granted = false,
            .can_remember = false,
            .reply_ctx = self,
            .reply_fn = &ignoreWriteReply,
        });
    }
    fn ignoreWriteReply(_: *anyopaque, _: clipboard.Write.Result) void {}
    fn clipboardRead(
        self: *Handler,
        location: clipboard.Location,
        terminator: osc.Terminator,
    ) void {
        const func = self.effects.clipboard_read orelse return;
        var state: ClipboardReadState = .{
            .handler = self,
            .location = location,
            .terminator = terminator,
        };
        func(self, .{
            .location = location,
            .mimes = &.{"text/plain"},
            .list = false,
            .name = "",
            .granted = false,
            .can_remember = false,
            .reply_ctx = &state,
            .reply_fn = &ClipboardReadState.reply,
        });
        if (!state.replied) state.respond("") catch |err| {
            log.warn("error replying to clipboard read err={}", .{err});
        };
    }
    const ClipboardReadState = struct {
        handler: *Handler,
        location: clipboard.Location,
        terminator: osc.Terminator,
        replied: bool = false,
        fn reply(ctx: *anyopaque, result: clipboard.Read.Result) void {
            const self: *ClipboardReadState = @ptrCast(@alignCast(ctx));
            if (self.replied) {
                log.warn("clipboard read replied more than once, ignoring", .{});
                return;
            }
            const data: []const u8 = switch (result) {
                .denied, .unsupported, .busy, .io_error => "",
                .success => |s| for (s.contents) |c| {
                    if (clipboard.isTextMime(c.mime)) break c.data;
                } else "",
            };
            self.respond(data) catch |err| {
                log.warn("error replying to clipboard read err={}", .{err});
                return;
            };
            self.replied = true;
        }
        fn respond(
            self: *ClipboardReadState,
            data: []const u8,
        ) error{ OutOfMemory, WriteFailed }!void {
            const handler = self.handler;
            var stack = std.heap.stackFallback(256, handler.terminal.gpa());
            const alloc = stack.get();
            var aw: std.Io.Writer.Allocating = .init(alloc);
            defer aw.deinit();
            const kind: u8 = switch (self.location) {
                .selection => 's',
                .primary => 'p',
                .standard, _ => 'c',
            };
            try aw.writer.print("\x1b]52;{c};", .{kind});
            try std.base64.standard.Encoder.encodeWriter(&aw.writer, data);
            try aw.writer.writeAll(self.terminator.string());
            const written = try aw.toOwnedSliceSentinel(0);
            defer alloc.free(written);
            handler.writePty(written);
        }
    };
    fn kittyClipboard(
        self: *Handler,
        v: Action.Value(.kitty_clipboard),
    ) error{OutOfMemory}!void {
        var arena: std.heap.ArenaAllocator = .init(self.terminal.gpa());
        defer arena.deinit();
        const meta = (kitty_clipboard.Metadata.parse(
            arena.allocator(),
            v.metadata,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidValue => {
                const state = self.kitty_clipboard_write orelse return;
                switch (kitty_clipboard.Metadata.operation(v.metadata) orelse return) {
                    .wdata, .walias => self.kittyClipboardFinish(
                        state,
                        .EINVAL,
                        v.terminator,
                    ),
                    .read, .write => {},
                }
                return;
            },
        }) orelse return;
        const payload = v.payload orelse "";
        switch (meta.op) {
            .read => try self.kittyClipboardRead(&meta, payload, v.terminator),
            .write => try self.kittyClipboardWriteBegin(&meta, v.terminator),
            .wdata => try self.kittyClipboardData(&meta, payload, v.terminator),
            .walias => try self.kittyClipboardAlias(&meta, payload, v.terminator),
        }
    }
    fn kittyClipboardRead(
        self: *Handler,
        meta: *const kitty_clipboard.Metadata,
        payload: []const u8,
        terminator: osc.Terminator,
    ) error{OutOfMemory}!void {
        const alloc = self.terminal.gpa();
        const decoded = kitty_clipboard.Payload.init(
            alloc,
            payload,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => return,
        };
        defer decoded.deinit(alloc);
        if (!decoded.isValidUtf8()) return;
        const func = self.effects.clipboard_read orelse {
            self.kittyClipboardRespond(&.{
                .op = .read,
                .status = .EPERM,
                .id = meta.id,
                .terminator = terminator,
            });
            return;
        };
        var mimes_buf: [kitty_clipboard.max_read_mimes][]const u8 = undefined;
        const mimes, const list = mimes: {
            var targets = false;
            var len: usize = 0;
            var it = decoded.mimeIterator();
            while (it.next()) |mime| {
                if (std.mem.eql(u8, mime, kitty_clipboard.targets_mime)) {
                    targets = true;
                    continue;
                }
                if (len == mimes_buf.len) continue;
                mimes_buf[len] = mime;
                len += 1;
            }
            break :mimes .{ mimes_buf[0..len], targets };
        };
        const pw: []const u8 = if (meta.name.len > 0) meta.pw else "";
        const granted = !kitty_clipboard.readPromptExempt(mimes.len) and
            self.kitty_clipboard_grants.use(alloc, pw, .read);
        var state: KittyClipboardReadState = .{
            .handler = self,
            .primary = meta.loc == .primary,
            .id = meta.id,
            .pw = pw,
            .mimes = mimes,
            .list = list,
            .terminator = terminator,
        };
        func(self, .{
            .location = meta.loc,
            .mimes = mimes,
            .list = list,
            .name = meta.name,
            .granted = granted,
            .can_remember = pw.len > 0,
            .reply_ctx = &state,
            .reply_fn = &KittyClipboardReadState.reply,
        });
        if (!state.replied) state.respondStatus(.EPERM);
    }
    const KittyClipboardReadState = struct {
        handler: *Handler,
        primary: bool,
        id: []const u8,
        pw: []const u8,
        mimes: []const []const u8,
        list: bool,
        terminator: osc.Terminator,
        replied: bool = false,
        fn reply(ctx: *anyopaque, result: clipboard.Read.Result) void {
            const self: *KittyClipboardReadState = @ptrCast(@alignCast(ctx));
            if (self.replied) {
                log.warn("clipboard read replied more than once, ignoring", .{});
                return;
            }
            self.replied = true;
            const success = switch (result) {
                .denied => return self.respondStatus(.EPERM),
                .unsupported => return self.respondStatus(.ENOSYS),
                .busy => return self.respondStatus(.EBUSY),
                .io_error => return self.respondStatus(.EIO),
                .success => |s| s,
            };
            if (success.remember and self.pw.len > 0) {
                self.handler.kitty_clipboard_grants.grant(
                    self.handler.terminal.gpa(),
                    self.pw,
                    .read,
                    false,
                ) catch |err| {
                    log.warn("error recording clipboard grant err={}", .{err});
                };
            }
            self.respondSuccess(&success) catch |err| {
                log.warn("error replying to clipboard read err={}", .{err});
                self.respondStatus(.EIO);
            };
        }
        fn respondStatus(
            self: *const KittyClipboardReadState,
            status: kitty_clipboard.Status,
        ) void {
            self.handler.kittyClipboardRespond(&.{
                .op = .read,
                .status = status,
                .id = self.id,
                .terminator = self.terminator,
            });
        }
        fn respondSuccess(
            self: *const KittyClipboardReadState,
            success: *const clipboard.Read.Result.Success,
        ) error{ OutOfMemory, WriteFailed }!void {
            const handler = self.handler;
            if (handler.effects.write_pty == null) return;
            var served_buf: [kitty_clipboard.max_read_mimes]clipboard.Content = undefined;
            var served_len: usize = 0;
            for (self.mimes) |mime| {
                for (success.contents) |content| {
                    if (!std.mem.eql(u8, content.mime, mime)) continue;
                    served_buf[served_len] = content;
                    served_len += 1;
                    break;
                }
            }
            var stack = std.heap.stackFallback(1024, handler.terminal.gpa());
            const alloc = stack.get();
            var aw: std.Io.Writer.Allocating = .init(alloc);
            defer aw.deinit();
            try (kitty_clipboard.ReadSuccess{
                .primary = self.primary,
                .id = self.id,
                .list = self.list,
                .available = success.available,
                .contents = served_buf[0..served_len],
                .terminator = self.terminator,
            }).encode(&aw.writer);
            const written = try aw.toOwnedSliceSentinel(0);
            defer alloc.free(written);
            handler.writePty(written);
        }
    };
    fn kittyClipboardWriteBegin(
        self: *Handler,
        meta: *const kitty_clipboard.Metadata,
        terminator: osc.Terminator,
    ) error{OutOfMemory}!void {
        self.kittyClipboardAbort();
        if (self.effects.clipboard_write == null) {
            self.kittyClipboardRespond(&.{
                .op = .write,
                .status = .ENOSYS,
                .id = meta.id,
                .terminator = terminator,
            });
            return;
        }
        const alloc = self.terminal.gpa();
        const state = try alloc.create(kitty_clipboard.WriteState);
        errdefer alloc.destroy(state);
        state.* = try .init(alloc, meta, .{
            .max_size = self.kitty_clipboard_write_max_bytes,
        });
        self.kitty_clipboard_write = state;
    }
    fn kittyClipboardData(
        self: *Handler,
        meta: *const kitty_clipboard.Metadata,
        payload: []const u8,
        terminator: osc.Terminator,
    ) error{OutOfMemory}!void {
        const state = self.kitty_clipboard_write orelse return;
        if (meta.mime.len == 0) return self.kittyClipboardCommit(
            state,
            terminator,
        );
        state.data(
            self.terminal.gpa(),
            meta,
            payload,
        ) catch |err| switch (err) {
            error.OutOfMemory => {
                self.kittyClipboardFinish(
                    state,
                    .EIO,
                    terminator,
                );
                return error.OutOfMemory;
            },
            error.TooLarge => self.kittyClipboardFinish(
                state,
                .EFBIG,
                terminator,
            ),
            error.Invalid => self.kittyClipboardFinish(
                state,
                .EINVAL,
                terminator,
            ),
        };
    }
    fn kittyClipboardAlias(
        self: *Handler,
        meta: *const kitty_clipboard.Metadata,
        payload: []const u8,
        terminator: osc.Terminator,
    ) error{OutOfMemory}!void {
        const state = self.kitty_clipboard_write orelse return;
        if (meta.mime.len == 0) return self.kittyClipboardFinish(
            state,
            .EINVAL,
            terminator,
        );
        state.alias(
            self.terminal.gpa(),
            meta,
            payload,
        ) catch |err| switch (err) {
            error.OutOfMemory => {
                self.kittyClipboardFinish(
                    state,
                    .EIO,
                    terminator,
                );
                return error.OutOfMemory;
            },
            error.Invalid => self.kittyClipboardFinish(
                state,
                .EINVAL,
                terminator,
            ),
        };
    }
    fn kittyClipboardCommit(
        self: *Handler,
        state: *kitty_clipboard.WriteState,
        terminator: osc.Terminator,
    ) error{OutOfMemory}!void {
        const alloc = self.terminal.gpa();
        const committed = state.commit(alloc) catch |err| switch (err) {
            error.OutOfMemory => {
                self.kittyClipboardFinish(state, .EIO, terminator);
                return error.OutOfMemory;
            },
            error.Invalid => {
                self.kittyClipboardFinish(state, .EINVAL, terminator);
                return;
            },
        };
        defer committed.deinit(alloc);
        const func = self.effects.clipboard_write orelse {
            self.kittyClipboardFinish(state, .ENOSYS, terminator);
            return;
        };
        const pw: []const u8 = if (committed.name.len > 0) committed.pw else "";
        const granted = self.kitty_clipboard_grants.use(alloc, pw, .write);
        var reply_state: KittyClipboardWriteReplyState = .{
            .handler = self,
            .pw = pw,
        };
        func(self, .{
            .location = committed.loc,
            .contents = committed.contents,
            .name = committed.name,
            .granted = granted,
            .can_remember = pw.len > 0,
            .reply_ctx = &reply_state,
            .reply_fn = &KittyClipboardWriteReplyState.reply,
        });
        self.kittyClipboardFinish(
            state,
            reply_state.status orelse .EPERM,
            terminator,
        );
    }
    const KittyClipboardWriteReplyState = struct {
        handler: *Handler,
        pw: []const u8,
        status: ?kitty_clipboard.Status = null,
        fn reply(ctx: *anyopaque, result: clipboard.Write.Result) void {
            const self: *KittyClipboardWriteReplyState = @ptrCast(@alignCast(ctx));
            if (self.status != null) {
                log.warn("clipboard write replied more than once, ignoring", .{});
                return;
            }
            self.status = switch (result) {
                .denied => .EPERM,
                .unsupported => .ENOSYS,
                .busy => .EBUSY,
                .invalid_data => .EINVAL,
                .io_error => .EIO,
                .success => |success| status: {
                    if (success.remember and self.pw.len > 0) {
                        self.handler.kitty_clipboard_grants.grant(
                            self.handler.terminal.gpa(),
                            self.pw,
                            .write,
                            false,
                        ) catch |err| {
                            log.warn("error recording clipboard grant err={}", .{err});
                        };
                    }
                    break :status .DONE;
                },
            };
        }
    };
    fn kittyClipboardFinish(
        self: *Handler,
        state: *const kitty_clipboard.WriteState,
        status: kitty_clipboard.Status,
        terminator: osc.Terminator,
    ) void {
        self.kittyClipboardRespond(&.{
            .op = .write,
            .status = status,
            .id = state.id,
            .terminator = terminator,
        });
        self.kittyClipboardAbort();
    }
    fn kittyClipboardAbort(self: *Handler) void {
        if (self.kitty_clipboard_write) |state| {
            const alloc = self.terminal.gpa();
            state.deinit(alloc);
            alloc.destroy(state);
            self.kitty_clipboard_write = null;
        }
    }
    fn kittyClipboardRespond(
        self: *Handler,
        response: *const kitty_clipboard.Response,
    ) void {
        if (self.effects.write_pty == null) return;
        var stack = std.heap.stackFallback(1024, self.terminal.gpa());
        const alloc = stack.get();
        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        response.encode(&aw.writer) catch return;
        const resp = aw.toOwnedSliceSentinel(0) catch return;
        defer alloc.free(resp);
        self.writePty(resp);
    }
    fn kittyDnd(
        self: *Handler,
        v: Action.KittyDnd,
    ) (Allocator.Error || std.Io.Writer.Error)!void {
        var stack = std.heap.stackFallback(512, self.terminal.gpa());
        const response_alloc = stack.get();
        var aw: std.Io.Writer.Allocating = .init(response_alloc);
        defer aw.deinit();
        const event = try kitty_dnd.handleCommand(
            &self.terminal.kitty_dnd,
            self.terminal.gpa(),
            &aw.writer,
            v,
        );
        if (aw.written().len > 0) {
            const written = aw.toOwnedSliceSentinel(0) catch return;
            defer response_alloc.free(written);
            self.writePty(written);
        }
        if (event) |ev| {
            const func = self.effects.drag_and_drop orelse return;
            func(self, ev);
        }
    }
    fn reportDeviceAttributes(self: *Handler, req: device_attributes.Req) void {
        const func = self.effects.device_attributes orelse return;
        const attrs = func(self);
        var stack = std.heap.stackFallback(128, self.terminal.gpa());
        const alloc = stack.get();
        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        attrs.encode(req, &aw.writer) catch return;
        const written = aw.toOwnedSliceSentinel(0) catch return;
        defer alloc.free(written);
        self.writePty(written);
    }
    fn cursorReportPos(self: *Handler) struct { x: usize, y: usize } {
        return if (self.terminal.modes.get(.origin)) .{
            .x = self.terminal.screens.active.cursor.x -| self.terminal.scrolling_region.left,
            .y = self.terminal.screens.active.cursor.y -| self.terminal.scrolling_region.top,
        } else .{
            .x = self.terminal.screens.active.cursor.x,
            .y = self.terminal.screens.active.cursor.y,
        };
    }
    fn deviceStatus(self: *Handler, req: device_status.Request) void {
        switch (req) {
            .operating_status => self.writePty("\x1B[0n"),
            .cursor_position => {
                const pos = self.cursorReportPos();
                var buf: [64]u8 = undefined;
                const resp = std.fmt.bufPrintZ(&buf, "\x1B[{};{}R", .{
                    pos.y + 1,
                    pos.x + 1,
                }) catch return;
                self.writePty(resp);
            },
            .cursor_position_extended => {
                const pos = self.cursorReportPos();
                var buf: [64]u8 = undefined;
                const resp = std.fmt.bufPrintZ(&buf, "\x1B[?{};{};1R", .{
                    pos.y + 1,
                    pos.x + 1,
                }) catch return;
                self.writePty(resp);
            },
            .color_scheme => {
                const func = self.effects.color_scheme orelse return;
                const scheme = func(self) orelse return;
                var buf: [device_status.max_color_scheme_report_encode_size + 1]u8 = undefined;
                var writer: std.Io.Writer = .fixed(buf[0..device_status.max_color_scheme_report_encode_size]);
                device_status.encodeColorSchemeReport(&writer, scheme) catch return;
                buf[writer.end] = 0;
                self.writePty(buf[0..writer.end :0]);
            },
            .visibility => self.sendVisibilityReport(),
        }
    }
    fn sendVisibilityReport(self: *Handler) void {
        const write_pty = self.effects.write_pty orelse return;
        var buf: [device_status.max_visibility_report_encode_size + 1]u8 = undefined;
        var writer: std.Io.Writer = .fixed(buf[0..device_status.max_visibility_report_encode_size]);
        device_status.encodeVisibilityReport(
            &writer,
            if (self.terminal.flags.visible) .potentially_visible else .not_visible,
        ) catch return;
        buf[writer.end] = 0;
        write_pty(self, buf[0..writer.end :0]);
    }
    fn reportEnquiry(self: *Handler) void {
        const func = self.effects.enquiry orelse return;
        const response = func(self);
        if (response.len == 0) return;
        var buf: [256]u8 = undefined;
        if (response.len >= buf.len) return;
        @memcpy(buf[0..response.len], response);
        buf[response.len] = 0;
        self.writePty(buf[0..response.len :0]);
    }
    fn reportXtversion(self: *Handler) void {
        const version = if (self.effects.xtversion) |func| func(self) else "";
        var buf: [288]u8 = undefined;
        const resp = std.fmt.bufPrintZ(
            &buf,
            "\x1BP>|{s}\x1B\\",
            .{if (version.len > 0) version else "libwasp"},
        ) catch return;
        self.writePty(resp);
    }
    fn reportXtChecksum(self: *Handler, req: xt_checksum.Request) void {
        if (!self.xt_checksum_report) return;
        var buf: [xt_checksum.max_encode_size + 1]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        xt_checksum.encode(
            &writer,
            req.id,
            self.terminal.rectXtChecksum(req),
        ) catch unreachable;
        const len = writer.buffered().len;
        buf[len] = 0;
        self.writePty(buf[0..len :0]);
    }
    fn reportSize(self: *Handler, style: csi.SizeReportStyle) void {
        var stack = std.heap.stackFallback(
            256,
            self.terminal.gpa(),
        );
        const alloc = stack.get();
        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        switch (style) {
            .csi_21_t => {
                if (!self.title_report) return;
                const title = self.terminal.getTitle() orelse "";
                aw.writer.print("\x1b]l{s}\x1b\\", .{title}) catch return;
            },
            .csi_14_t, .csi_16_t, .csi_18_t, .csi_19_t => {
                const get_size = self.effects.size orelse return;
                const s = get_size(self) orelse return;
                const report_style: size_report.Style = switch (style) {
                    .csi_14_t => .csi_14_t,
                    .csi_16_t => .csi_16_t,
                    .csi_18_t => .csi_18_t,
                    .csi_19_t => .csi_19_t,
                    .csi_21_t => unreachable,
                };
                size_report.encode(
                    &aw.writer,
                    report_style,
                    s,
                ) catch |err| {
                    log.warn("error encoding size report err={}", .{err});
                    return;
                };
            },
        }
        const resp = aw.toOwnedSliceSentinel(0) catch return;
        defer alloc.free(resp);
        self.writePty(resp);
    }
    fn reportMode2048(self: *Handler) void {
        const get_size = self.effects.size orelse return;
        const current = get_size(self) orelse return;
        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
        size_report.encode(&writer, .mode_2048, current) catch return;
        buf[writer.end] = 0;
        self.writePty(buf[0..writer.end :0]);
    }
    fn windowTitle(self: *Handler, title_raw: []const u8) !void {
        const max_title_len = 1024;
        const title = if (title_raw.len > max_title_len) title: {
            log.warn("title length {d} exceeds max length {d}, truncating", .{
                title_raw.len,
                max_title_len,
            });
            break :title title_raw[0..max_title_len];
        } else title_raw;
        try self.terminal.setTitle(title);
        const func = self.effects.title_changed orelse return;
        func(self);
    }
    fn reportPwd(self: *Handler, url_raw: []const u8) !void {
        const max_url_len = 4096;
        const url = if (url_raw.len > max_url_len) url: {
            log.warn("pwd url length {d} exceeds max length {d}, truncating", .{
                url_raw.len,
                max_url_len,
            });
            break :url url_raw[0..max_url_len];
        } else url_raw;
        try self.terminal.setPwd(url);
        const func = self.effects.pwd_changed orelse return;
        func(self);
    }
    fn requestMode(self: *Handler, mode: modes.Mode) void {
        var report = self.terminal.modes.getReport(.fromMode(mode));
        if (mode == .kitty_paste_events and
            self.effects.clipboard_read == null)
        {
            report.state = .not_recognized;
        }
        self.sendModeReport(report);
    }
    fn requestModeUnknown(self: *Handler, mode_raw: u16, ansi: bool) void {
        const report = self.terminal.modes.getReport(.{
            .value = mode_raw,
            .ansi = ansi,
        });
        self.sendModeReport(report);
    }
    fn sendModeReport(self: *Handler, report: modes.Report) void {
        var buf: [modes.Report.max_size + 1]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        report.encode(&writer) catch |err| {
            log.warn("error encoding mode report err={}", .{err});
            return;
        };
        const len = writer.buffered().len;
        buf[len] = 0;
        self.writePty(buf[0..len :0]);
    }
    fn queryKittyKeyboard(self: *Handler) void {
        var buf: [32]u8 = undefined;
        const resp = std.fmt.bufPrintZ(&buf, "\x1b[?{}u", .{
            self.terminal.screens.active.kitty_keyboard.current().int(),
        }) catch return;
        self.writePty(resp);
    }
    inline fn horizontalTab(self: *Handler, count: u16) void {
        for (0..count) |_| {
            const x = self.terminal.screens.active.cursor.x;
            self.terminal.horizontalTab();
            if (x == self.terminal.screens.active.cursor.x) break;
        }
    }
    inline fn horizontalTabBack(self: *Handler, count: u16) void {
        for (0..count) |_| {
            const x = self.terminal.screens.active.cursor.x;
            self.terminal.horizontalTabBack();
            if (x == self.terminal.screens.active.cursor.x) break;
        }
    }
    inline fn renderHold(self: *Handler, held: bool) void {
        const func = self.effects.render_hold orelse return;
        func(self, held);
    }
    fn setMode(self: *Handler, mode: modes.Mode, enabled: bool) !void {
        if (mode == .synchronized_output) {
            if (self.terminal.modes.get(mode) == enabled) return;
            self.terminal.modes.set(mode, enabled);
            self.renderHold(enabled);
            return;
        }
        self.terminal.modes.set(mode, enabled);
        switch (mode) {
            .autorepeat,
            .reverse_colors,
            => {},
            .origin => self.terminal.setCursorPos(1, 1),
            .enable_left_and_right_margin => if (!enabled) {
                self.terminal.scrolling_region.left = 0;
                self.terminal.scrolling_region.right = self.terminal.cols - 1;
            },
            .alt_screen_legacy => try self.terminal.switchScreenMode(.@"47", enabled),
            .alt_screen => try self.terminal.switchScreenMode(.@"1047", enabled),
            .alt_screen_save_cursor_clear_enter => try self.terminal.switchScreenMode(.@"1049", enabled),
            .save_cursor => if (enabled) {
                self.terminal.saveCursor();
            } else {
                self.terminal.restoreCursor();
            },
            .enable_mode_3 => {},
            .@"132_column" => try self.terminal.deccolm(
                self.terminal.screens.active.alloc,
                if (enabled) .@"132_cols" else .@"80_cols",
            ),
            .synchronized_output => unreachable,
            .linefeed,
            .focus_event,
            => {},
            .in_band_size_reports => if (enabled) self.reportMode2048(),
            .report_visibility => if (enabled) self.sendVisibilityReport(),
            .mouse_event_x10 => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .x10;
                } else {
                    self.terminal.flags.mouse_event = .none;
                }
            },
            .mouse_event_normal => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .normal;
                } else {
                    self.terminal.flags.mouse_event = .none;
                }
            },
            .mouse_event_button => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .button;
                } else {
                    self.terminal.flags.mouse_event = .none;
                }
            },
            .mouse_event_any => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .any;
                } else {
                    self.terminal.flags.mouse_event = .none;
                }
            },
            .mouse_format_utf8 => self.terminal.flags.mouse_format = if (enabled) .utf8 else .x10,
            .mouse_format_sgr => self.terminal.flags.mouse_format = if (enabled) .sgr else .x10,
            .mouse_format_urxvt => self.terminal.flags.mouse_format = if (enabled) .urxvt else .x10,
            .mouse_format_sgr_pixels => self.terminal.flags.mouse_format = if (enabled) .sgr_pixels else .x10,
            else => {},
        }
    }
    fn colorOperation(
        self: *Handler,
        requests: *const osc_color.List,
        terminator: osc.Terminator,
    ) !void {
        if (requests.count() == 0) return;
        var stack = std.heap.stackFallback(1024, self.terminal.gpa());
        const alloc = stack.get();
        var response: std.Io.Writer.Allocating = .init(alloc);
        defer response.deinit();
        const writer = &response.writer;
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
                            => {},
                        },
                        .special => {},
                    }
                },
                .reset => |target| switch (target) {
                    .palette => |i| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.colors.palette.reset(i);
                    },
                    .dynamic => |dynamic| switch (dynamic) {
                        .foreground => self.terminal.colors.foreground.reset(),
                        .background => self.terminal.colors.background.reset(),
                        .cursor => self.terminal.colors.cursor.reset(),
                        .pointer_foreground,
                        .pointer_background,
                        .tektronix_foreground,
                        .tektronix_background,
                        .highlight_background,
                        .tektronix_cursor,
                        .highlight_foreground,
                        => {},
                    },
                    .special => {},
                },
                .reset_palette => {
                    const mask = &self.terminal.colors.palette.mask;
                    var mask_it = mask.iterator(.{});
                    while (mask_it.next()) |i| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.colors.palette.reset(@intCast(i));
                    }
                    mask.* = .initEmpty();
                },
                .query => |target| {
                    if (self.effects.write_pty == null) continue;
                    const c = self.terminal.colorForXterm(target) orelse continue;
                    try writeXtermColorReport(writer, target, c, terminator);
                },
                .reset_special => {},
            }
        }
        if (response.written().len > 0) {
            const resp = try response.toOwnedSliceSentinel(0);
            defer alloc.free(resp);
            self.writePty(resp);
        }
    }
    fn writeXtermColorReport(
        writer: *std.Io.Writer,
        target: osc_color.Target,
        c: color.RGB,
        terminator: osc.Terminator,
    ) !void {
        switch (target) {
            .palette => |i| {
                try writer.print("\x1b]4;{d};", .{i});
                try c.encodeRgb16(writer);
                try writer.writeAll(terminator.string());
            },
            .dynamic => |dynamic| switch (dynamic) {
                .foreground,
                .background,
                .cursor,
                => {
                    try writer.print("\x1b]{d};", .{@intFromEnum(dynamic)});
                    try c.encodeRgb16(writer);
                    try writer.writeAll(terminator.string());
                },
                .pointer_foreground,
                .pointer_background,
                .tektronix_foreground,
                .tektronix_background,
                .highlight_background,
                .tektronix_cursor,
                .highlight_foreground,
                => {},
            },
            .special => {},
        }
    }
    fn kittyColorOperation(
        self: *Handler,
        request: kitty_color.OSC,
    ) !void {
        var stack = std.heap.stackFallback(1024, self.terminal.gpa());
        const alloc = stack.get();
        var response: std.Io.Writer.Allocating = .init(alloc);
        defer response.deinit();
        const writer = &response.writer;
        for (request.list.items) |item| {
            switch (item) {
                .set => |v| switch (v.key) {
                    .palette => |palette| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.colors.palette.set(palette, v.color);
                    },
                    .special => |special| switch (special) {
                        .foreground => self.terminal.colors.foreground.set(v.color),
                        .background => self.terminal.colors.background.set(v.color),
                        .cursor => self.terminal.colors.cursor.set(v.color),
                        else => {},
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
                        else => {},
                    },
                },
                .query => |key| {
                    if (self.effects.write_pty == null) continue;
                    const c = self.terminal.colorForKitty(key) orelse {
                        if (!key.hasTerminalQueryColor()) continue;
                        if (response.written().len == 0) try writer.writeAll("\x1b]21");
                        try writer.print(";{f}=", .{key});
                        continue;
                    };
                    if (response.written().len == 0) try writer.writeAll("\x1b]21");
                    try writer.print(";{f}=", .{key});
                    try c.encodeRgb8(writer);
                },
            }
        }
        if (response.written().len > 0) {
            try writer.writeAll(request.terminator.string());
            const resp = try response.toOwnedSliceSentinel(0);
            defer alloc.free(resp);
            self.writePty(resp);
        }
    }
    fn apcEnd(self: *Handler, terminated: bool) void {
        const io = self.terminal.io();
        const alloc = self.terminal.gpa();
        var result = self.apc_handler.end() orelse return;
        defer result.deinit(alloc);
        switch (result) {
            .unknown => |*unknown| {
                if (terminated) self.unknownSequence(.{ .apc = .{
                    .content = unknown.content,
                    .truncated = unknown.truncated,
                } });
            },
            .kitty => |*kitty_cmd| if (comptime build_options.kitty_graphics) {
                if (self.terminal.kittyGraphics(
                    io,
                    alloc,
                    kitty_cmd,
                )) |resp| resp: {
                    if (self.effects.write_pty == null) break :resp;
                    var buf: [1024]u8 = undefined;
                    var writer: std.Io.Writer = .fixed(&buf);
                    resp.encode(&writer) catch return;
                    writer.writeByte(0) catch return;
                    const final = writer.buffered();
                    if (final.len > 3) self.writePty(final[0 .. final.len - 1 :0]);
                }
            },
            .glyph => |*glyph_req| if (comptime build_options.glyph_protocol) {
                const resp = self.terminal.glyphProtocol(alloc, glyph_req);
                if (resp) |r| resp_block: {
                    if (self.effects.write_pty == null) break :resp_block;
                    var buf: [apc.glyph.Response.max_wire_bytes]u8 = undefined;
                    var writer: std.Io.Writer = .fixed(&buf);
                    r.formatWire(&writer) catch return;
                    writer.writeByte(0) catch return;
                    const final = writer.buffered();
                    self.writePty(final[0 .. final.len - 1 :0]);
                }
            },
        }
    }
};
const PtyWriter = struct {
    handler: *Handler,
    writer: std.Io.Writer,
    fn init(handler: *Handler, buffer: []u8) PtyWriter {
        return .{
            .handler = handler,
            .writer = .{
                .vtable = &.{ .drain = drain },
                .buffer = buffer,
            },
        };
    }
    fn drain(
        w: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *PtyWriter = @alignCast(@fieldParentPtr("writer", w));
        if (w.end > 0) {
            self.handler.writePty(w.buffer[0..w.end]);
            w.end = 0;
        }
        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            if (slice.len > 0) self.handler.writePty(slice);
            consumed += slice.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            if (pattern.len > 0) self.handler.writePty(pattern);
            consumed += pattern.len;
        }
        return consumed;
    }
};
test "render hold effect fires on synchronized output transitions only" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var events: [8]bool = undefined;
        var len: usize = 0;
        fn hold(_: *Handler, held: bool) void {
            events[len] = held;
            len += 1;
        }
    };
    S.len = 0;
    var handler: Handler = .init(&t);
    handler.effects.render_hold = &S.hold;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1b[?2026l");
    try testing.expectEqual(0, S.len);
    s.nextSlice("\x1b[?2026hA\x1b[?2026hB\x1b[?2026l\x1b[?2026l");
    try testing.expectEqualSlices(bool, &.{ true, false }, S.events[0..S.len]);
    S.len = 0;
    s.nextSlice("\x1b[?2026s\x1b[?2026h\x1b[?2026r\x1b[?2026r");
    try testing.expectEqualSlices(bool, &.{ true, false }, S.events[0..S.len]);
    try testing.expect(!t.modes.get(.synchronized_output));
    S.len = 0;
    s.nextSlice("\x1b[?2026h\x1bc\x1bc");
    try testing.expectEqualSlices(bool, &.{ true, false }, S.events[0..S.len]);
    S.len = 0;
    s.nextSlice("\x1b[?2026h");
    try s.handler.resize(.{ .cols = 80, .rows = 24 });
    try s.handler.resize(.{ .cols = 80, .rows = 24 });
    try testing.expectEqualSlices(bool, &.{ true, false }, S.events[0..S.len]);
}
test "render hold effect can snapshot the frame when the hold begins" {
    const alloc = testing.allocator;
    const RenderState = @import("render.zig").RenderState;
    var t: Terminal = try .init(testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    const S = struct {
        var state: RenderState = .empty;
        var snapshots: usize = 0;
        fn hold(h: *Handler, held: bool) void {
            if (!held) return;
            state.update(testing.allocator, h.terminal) catch unreachable;
            snapshots += 1;
        }
        fn char(y: usize, x: usize) u21 {
            return state.row_data.items(.cells)[y].get(x).raw.codepoint();
        }
    };
    S.state = .empty;
    S.snapshots = 0;
    defer S.state.deinit(alloc);
    var handler: Handler = .init(&t);
    handler.effects.render_hold = &S.hold;
    var s: Stream = .init(.{ .allocator = alloc, .handler = handler });
    defer s.deinit();
    s.nextSlice("AB\x1b[?2026h\x1b[HXY");
    try testing.expectEqual(1, S.snapshots);
    try testing.expectEqual('A', S.char(0, 0));
    try testing.expectEqual('B', S.char(0, 1));
    s.nextSlice("Z\x1b[?2026l\x1b[?2026h\x1b[H123");
    try testing.expectEqual(2, S.snapshots);
    try testing.expectEqual('X', S.char(0, 0));
    try testing.expectEqual('Y', S.char(0, 1));
    try testing.expectEqual('Z', S.char(0, 2));
}
test "resize clears synchronized output on unchanged cell dimensions" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    t.modes.set(.synchronized_output, true);
    try s.handler.resize(.{
        .cols = 80,
        .rows = 24,
        .cell_size_px = .{ .width = 9, .height = 18 },
    });
    try testing.expect(!t.modes.get(.synchronized_output));
    try testing.expectEqual(@as(u32, 720), t.width_px);
    try testing.expectEqual(@as(u32, 432), t.height_px);
}
test "unknown APC effect callback" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var count: usize = 0;
        var osc_count: usize = 0;
        var content: [16]u8 = undefined;
        var content_len: usize = undefined;
        var truncated: bool = undefined;
        fn unknownSequence(_: *Handler, value: Handler.UnknownSequence) void {
            switch (value) {
                .apc => |apc_value| {
                    content_len = apc_value.content.len;
                    @memcpy(content[0..apc_value.content.len], apc_value.content);
                    truncated = apc_value.truncated;
                },
                .osc => osc_count += 1,
            }
            count += 1;
        }
    };
    S.count = 0;
    S.osc_count = 0;
    var handler: Handler = .init(&t);
    handler.unknown_sequence = &S.unknownSequence;
    handler.apc_handler.unknown_max_bytes = 8;
    var s: Stream = .init(.{
        .allocator = testing.allocator,
        .handler = handler,
    });
    defer s.deinit();
    s.nextSlice("\x1B]999;abcdef\x07");
    s.nextSlice("\x1B_abcd;payload\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.count);
    try testing.expectEqual(@as(usize, 0), S.osc_count);
    try testing.expectEqualStrings("abcd;pay", S.content[0..S.content_len]);
    try testing.expect(S.truncated);
    s.nextSlice("\x1B_Xpayload\x18");
    try testing.expectEqual(@as(usize, 1), S.count);
}
test "unknown OSC effect callback" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var count: usize = 0;
        var content: [32]u8 = undefined;
        var content_len: usize = undefined;
        var terminator: osc.Terminator = undefined;
        fn unknownSequence(_: *Handler, value: Handler.UnknownSequence) void {
            const v = switch (value) {
                .osc => |v| v,
                .apc => unreachable,
            };
            content_len = v.content.len;
            @memcpy(content[0..v.content.len], v.content);
            terminator = v.terminator;
            count += 1;
        }
    };
    S.count = 0;
    var handler: Handler = .init(&t);
    handler.unknown_sequence = &S.unknownSequence;
    var s: Stream = .init(.{
        .allocator = testing.allocator,
        .handler = handler,
        .osc_unknown_max_bytes = 24,
    });
    defer s.deinit();
    s.nextSlice("\x1B]7400;status=busy\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.count);
    try testing.expectEqualStrings("7400;status=busy", S.content[0..S.content_len]);
    try testing.expectEqual(osc.Terminator.st, S.terminator);
    s.nextSlice("\x1B]7400;?\x07");
    try testing.expectEqual(@as(usize, 2), S.count);
    try testing.expectEqualStrings("7400;?", S.content[0..S.content_len]);
    try testing.expectEqual(osc.Terminator.bel, S.terminator);
    s.nextSlice("\x1B]74");
    s.nextSlice("00;a");
    s.nextSlice("b\x07");
    try testing.expectEqual(@as(usize, 3), S.count);
    try testing.expectEqualStrings("7400;ab", S.content[0..S.content_len]);
    for ("\x1B]7400;cd\x1B\\") |ch| s.next(ch);
    try testing.expectEqual(@as(usize, 4), S.count);
    try testing.expectEqualStrings("7400;cd", S.content[0..S.content_len]);
    s.nextSlice("\x1B]7400;x\x18");
    s.nextSlice("\x1B]7400;x\x1A");
    try testing.expectEqual(@as(usize, 4), S.count);
    s.nextSlice("\x1B]2;title\x07");
    try testing.expectEqual(@as(usize, 4), S.count);
    try testing.expectEqualStrings("title", t.getTitle().?);
    s.parser.osc_parser.unknown_max_bytes = 0;
    s.nextSlice("\x1B]7400;x\x07");
    try testing.expectEqual(@as(usize, 4), S.count);
}
test "resize reports mode 2048 geometry" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var response: [128]u8 = undefined;
        var response_len: usize = 0;
        fn writePty(_: *Handler, data: []const u8) void {
            @memcpy(response[0..data.len], data);
            response_len = data.len;
        }
    };
    S.response_len = 0;
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    t.modes.set(.in_band_size_reports, true);
    try s.handler.resize(.{
        .cols = 100,
        .rows = 40,
        .cell_size_px = .{ .width = 9, .height = 18 },
    });
    try testing.expectEqualStrings(
        "\x1B[48;40;100;720;900t",
        S.response[0..S.response_len],
    );
}
test "resize suppresses mode 2048 reports" {
    const S = struct {
        var calls: usize = 0;
        fn writePty(_: *Handler, _: []const u8) void {
            calls += 1;
        }
    };
    S.calls = 0;
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    try s.handler.resize(.{
        .cols = 80,
        .rows = 24,
        .cell_size_px = .{ .width = 9, .height = 18 },
    });
    try testing.expectEqual(@as(usize, 0), S.calls);
    t.modes.set(.in_band_size_reports, true);
    try s.handler.resize(.{ .cols = 80, .rows = 24 });
    try testing.expectEqual(@as(usize, 0), S.calls);
    var readonly_terminal: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 80, .rows = 24 },
    );
    defer readonly_terminal.deinit(testing.allocator);
    readonly_terminal.modes.set(.in_band_size_reports, true);
    var readonly_stream: Stream = .init(.{
        .allocator = testing.allocator,
        .handler = .init(&readonly_terminal),
    });
    defer readonly_stream.deinit();
    try readonly_stream.handler.resize(.{
        .cols = 80,
        .rows = 24,
        .cell_size_px = .{ .width = 9, .height = 18 },
    });
    try testing.expectEqual(@as(usize, 0), S.calls);
}
test "resize failure preserves terminal state and does not write" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing.allocator();
    var t: Terminal = try .init(testing.io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);
    const S = struct {
        var called: bool = false;
        fn writePty(_: *Handler, _: []const u8) void {
            called = true;
        }
    };
    S.called = false;
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = alloc, .handler = handler });
    defer s.deinit();
    t.modes.set(.synchronized_output, true);
    t.modes.set(.in_band_size_reports, true);
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, s.handler.resize(.{
        .cols = 513,
        .rows = 1,
        .cell_size_px = .{ .width = 9, .height = 18 },
    }));
    try testing.expect(t.modes.get(.synchronized_output));
    try testing.expect(!S.called);
    try testing.expectEqual(@as(@TypeOf(t.cols), 10), t.cols);
    try testing.expectEqual(@as(u32, 0), t.width_px);
    try testing.expectEqual(@as(u32, 0), t.height_px);
}
test "resize effects do not change canonical terminal state" {
    var authoritative: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 10, .rows = 5 },
    );
    defer authoritative.deinit(testing.allocator);
    var readonly: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 10, .rows = 5 },
    );
    defer readonly.deinit(testing.allocator);
    const S = struct {
        fn writePty(_: *Handler, _: []const u8) void {}
    };
    var authoritative_handler: Handler = .init(&authoritative);
    authoritative_handler.effects.write_pty = &S.writePty;
    var authoritative_stream: Stream = .init(.{
        .allocator = testing.allocator,
        .handler = authoritative_handler,
    });
    defer authoritative_stream.deinit();
    var readonly_stream: Stream = .init(.{
        .allocator = testing.allocator,
        .handler = .init(&readonly),
    });
    defer readonly_stream.deinit();
    authoritative.modes.set(.in_band_size_reports, true);
    readonly.modes.set(.in_band_size_reports, true);
    const value: Terminal.Resize = .{
        .cols = 20,
        .rows = 10,
        .cell_size_px = .{ .width = 9, .height = 18 },
    };
    try authoritative_stream.handler.resize(value);
    try readonly_stream.handler.resize(value);
    try testing.expectEqual(authoritative.cols, readonly.cols);
    try testing.expectEqual(authoritative.rows, readonly.rows);
    try testing.expectEqual(authoritative.width_px, readonly.width_px);
    try testing.expectEqual(authoritative.height_px, readonly.height_px);
    try testing.expect(std.meta.eql(authoritative.modes, readonly.modes));
    try testing.expect(std.meta.eql(
        authoritative.scrolling_region,
        readonly.scrolling_region,
    ));
}
test "basic print" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("Hello");
    try testing.expectEqual(@as(usize, 5), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Hello", str);
}
test "semantic failure is sticky while processing continues" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing.allocator();
    var t: Terminal = try .init(testing.io, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);
    var s: Stream = .init(.{ .allocator = alloc, .handler = .init(&t) });
    defer s.deinit();
    try testing.expect(!s.handler.semantic_failure);
    failing.fail_index = failing.alloc_index;
    s.nextSlice("\x1B]2;unavailable\x1B\\");
    try testing.expect(s.handler.semantic_failure);
    failing.fail_index = std.math.maxInt(usize);
    s.nextSlice("ignored");
    s.nextSlice("\x1Bc");
    s.nextSlice("OK");
    try testing.expect(s.handler.semantic_failure);
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("OK", str);
    var fresh = Handler.init(&t);
    defer fresh.deinit();
    try testing.expect(!fresh.semantic_failure);
}
test "cursor movement" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("Hello\x1B[1;1H");
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    s.nextSlice("\x1B[2;3H");
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
}
test "erase operations" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 20, .rows = 10 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("Hello World");
    try testing.expectEqual(@as(usize, 11), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    s.nextSlice("\x1B[1;6H");
    s.nextSlice("\x1B[K");
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Hello", str);
}
test "tabs" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 10 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("A\tB");
    try testing.expectEqual(@as(usize, 9), t.screens.active.cursor.x);
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("A       B", str);
}
test "modes" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    try testing.expect(t.modes.get(.wraparound));
    s.nextSlice("\x1B[?7l");
    try testing.expect(!t.modes.get(.wraparound));
    s.nextSlice("\x1B[?7h");
    try testing.expect(t.modes.get(.wraparound));
}
test "scrolling regions" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1B[5;20r");
    try testing.expectEqual(@as(usize, 4), t.scrolling_region.top);
    try testing.expectEqual(@as(usize, 19), t.scrolling_region.bottom);
    try testing.expectEqual(@as(usize, 0), t.scrolling_region.left);
    try testing.expectEqual(@as(usize, 79), t.scrolling_region.right);
}
test "charsets" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1B(0");
    s.nextSlice("`");
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("◆", str);
}
test "alt screen" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("Primary");
    try testing.expectEqual(.primary, t.screens.active_key);
    s.nextSlice("\x1B[?1049h");
    try testing.expectEqual(.alternate, t.screens.active_key);
    s.nextSlice("Alt");
    s.nextSlice("\x1B[?1049l");
    try testing.expectEqual(.primary, t.screens.active_key);
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Primary", str);
}
test "cursor save and restore" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1B[10;15H");
    try testing.expectEqual(@as(usize, 14), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 9), t.screens.active.cursor.y);
    s.nextSlice("\x1B7");
    s.nextSlice("\x1B[1;1H");
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    s.nextSlice("\x1B8");
    try testing.expectEqual(@as(usize, 14), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 9), t.screens.active.cursor.y);
}
test "attributes" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1B[1mBold\x1B[0m");
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Bold", str);
}
test "DECRQSS responses" {
    var t: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 80, .rows = 24 },
    );
    defer t.deinit(testing.allocator);
    const S = struct {
        var response: [dcs.Command.DECRQSS.max_response_bytes]u8 = undefined;
        var response_len: usize = 0;
        var calls: usize = 0;
        fn reset() void {
            response_len = 0;
            calls = 0;
        }
        fn writePty(_: *Handler, data: []const u8) void {
            @memcpy(response[0..data.len], data);
            response_len = data.len;
            calls += 1;
        }
        fn expectResponse(expected: []const u8) !void {
            try testing.expectEqual(@as(usize, 1), calls);
            try testing.expectEqualStrings(
                expected,
                response[0..response_len],
            );
            reset();
        }
    };
    S.reset();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B[1m\x1BP$qm\x1B\\");
    try S.expectResponse("\x1BP1$r0;1m\x1B\\");
    s.nextSlice("\x1B[0;53m\x1BP$qm\x1B\\");
    try S.expectResponse("\x1BP1$r0;53m\x1B\\");
    s.nextSlice("\x1BP$qfoo\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.calls);
    try testing.expect(!s.handler.semantic_failure);
    s.nextSlice("\x1BP$qm\x1B\\");
    try S.expectResponse("\x1BP1$r0;53m\x1B\\");
}
test "DECRQSS without write effect is ignored" {
    var t: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 80, .rows = 24 },
    );
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1BP$qm\x1B\\");
    try testing.expect(!s.handler.semantic_failure);
}
test "XTGETTCAP responses" {
    var t: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 80, .rows = 24 },
    );
    defer t.deinit(testing.allocator);
    const S = struct {
        var response: [128]u8 = undefined;
        var response_len: usize = 0;
        var calls: usize = 0;
        fn reset() void {
            response_len = 0;
            calls = 0;
        }
        fn writePty(_: *Handler, data: []const u8) void {
            @memcpy(response[0..data.len], data);
            response_len = data.len;
            calls += 1;
        }
        fn expectResponse(expected: []const u8) !void {
            try testing.expectEqual(@as(usize, 1), calls);
            try testing.expectEqualStrings(
                expected,
                response[0..response_len],
            );
            reset();
        }
    };
    S.reset();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1BP+q" ++ std.fmt.bytesToHex("Co", .upper) ++ "\x1B\\");
    try S.expectResponse("\x1BP1+r" ++ std.fmt.bytesToHex("Co", .upper) ++ "=" ++
        std.fmt.bytesToHex("256", .upper) ++ "\x1B\\");
    s.nextSlice("\x1BP+q" ++ std.fmt.bytesToHex("am", .upper) ++ "\x1B\\");
    try S.expectResponse("\x1BP1+r" ++ std.fmt.bytesToHex("am", .upper) ++ "\x1B\\");
    s.nextSlice("\x1BP+q" ++ std.fmt.bytesToHex("am", .lower) ++ ";" ++
        std.fmt.bytesToHex("Co", .lower) ++ "\x1B\\");
    try testing.expectEqual(@as(usize, 2), S.calls);
    try testing.expectEqualStrings(
        "\x1BP1+r" ++ std.fmt.bytesToHex("Co", .upper) ++ "=" ++
            std.fmt.bytesToHex("256", .upper) ++ "\x1B\\",
        S.response[0..S.response_len],
    );
    S.reset();
    s.nextSlice("\x1BP+qWHO;5;GG\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.calls);
    try testing.expect(!s.handler.semantic_failure);
}
test "XTGETTCAP without write effect is ignored" {
    var t: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 80, .rows = 24 },
    );
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1BP+q" ++ std.fmt.bytesToHex("TN", .upper) ++ ";" ++
        std.fmt.bytesToHex("am", .upper) ++ "\x1B\\");
    try testing.expect(!s.handler.semantic_failure);
}
test "XTGETTCAP TN responses" {
    var t: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 80, .rows = 24 },
    );
    defer t.deinit(testing.allocator);
    const S = struct {
        var response: [512]u8 = undefined;
        var response_len: usize = 0;
        var calls: usize = 0;
        fn reset() void {
            response_len = 0;
            calls = 0;
        }
        fn writePty(_: *Handler, data: []const u8) void {
            @memcpy(response[0..data.len], data);
            response_len = data.len;
            calls += 1;
        }
        fn expectResponse(expected: []const u8) !void {
            try testing.expectEqual(@as(usize, 1), calls);
            try testing.expectEqualStrings(
                expected,
                response[0..response_len],
            );
            reset();
        }
    };
    S.reset();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    const tn_query = "\x1BP+q" ++ std.fmt.bytesToHex("TN", .upper) ++ "\x1B\\";
    s.nextSlice(tn_query);
    try testing.expectEqual(@as(usize, 0), S.calls);
    s.handler.terminfo_name = "xterm-256color";
    s.nextSlice(tn_query);
    try S.expectResponse("\x1BP1+r" ++ std.fmt.bytesToHex("TN", .upper) ++ "=" ++
        std.fmt.bytesToHex("xterm-256color", .upper) ++ "\x1B\\");
    const max_name = "a" ** Handler.max_terminfo_name_bytes;
    s.handler.terminfo_name = max_name;
    s.nextSlice(tn_query);
    try S.expectResponse("\x1BP1+r" ++ std.fmt.bytesToHex("TN", .upper) ++ "=" ++
        std.fmt.bytesToHex(max_name.*, .upper) ++ "\x1B\\");
    s.handler.terminfo_name = "";
    s.nextSlice("\x1BP+q" ++ std.fmt.bytesToHex("TN", .upper) ++ ";" ++
        std.fmt.bytesToHex("Co", .upper) ++ "\x1B\\");
    try S.expectResponse("\x1BP1+r" ++ std.fmt.bytesToHex("Co", .upper) ++ "=" ++
        std.fmt.bytesToHex("256", .upper) ++ "\x1B\\");
    s.handler.terminfo_name = "a" ** (Handler.max_terminfo_name_bytes + 1);
    s.nextSlice(tn_query);
    try testing.expectEqual(@as(usize, 0), S.calls);
    try testing.expect(!s.handler.semantic_failure);
}
test "DCS command memory is released" {
    var t: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 80, .rows = 24 },
    );
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    s.nextSlice("\x1BP+q536D756C78\x1B\\");
    s.nextSlice("\x1BP+q536D756C78");
    s.deinit();
}
test "DECALN screen alignment" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 3 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1B#8");
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("EEEEEEEEEE\nEEEEEEEEEE\nEEEEEEEEEE", str);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
}
test "full reset" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("Hello");
    s.nextSlice("\x1B[10;20H");
    s.nextSlice("\x1B[5;20r");
    s.nextSlice("\x1B[?7l");
    s.nextSlice("\x1B_25a1;r;cp=e0a0;AAAAAAAAAAAAAA==\x1B\\");
    try testing.expect(t.glyph_glossary.contains(0xE0A0));
    s.nextSlice("\x1Bc");
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.scrolling_region.top);
    try testing.expectEqual(@as(usize, 23), t.scrolling_region.bottom);
    try testing.expect(t.modes.get(.wraparound));
    try testing.expect(!t.glyph_glossary.contains(0xE0A0));
}
test "glyph protocol APC with write_pty callback" {
    if (comptime !build_options.glyph_protocol) return error.SkipZigTest;
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var last_response: ?[:0]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (last_response) |old| testing.allocator.free(old);
            last_response = testing.allocator.dupeZ(u8, data) catch @panic("OOM");
        }
    };
    S.last_response = null;
    defer if (S.last_response) |old| testing.allocator.free(old);
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B_25a1;s\x1B\\");
    try testing.expectEqualStrings("\x1B_25a1;s;fmt=glyf\x1B\\", S.last_response.?);
    s.nextSlice("\x1B_25a1;r;cp=e0a0;AAAAAAAAAAAAAA==\x1B\\");
    try testing.expectEqualStrings("\x1B_25a1;r;cp=e0a0;status=0\x1B\\", S.last_response.?);
    try testing.expect(t.glyph_glossary.contains(0xE0A0));
}
test "ignores query actions" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1B[c");
    s.nextSlice("\x1B[5n");
    s.nextSlice("\x1B[6n");
    s.nextSlice("\x1B]4;0;?\x1B\\");
    s.nextSlice("\x1B]21;foreground=?\x1B\\");
    s.nextSlice("\x1B]52;c;%%%invalid-base64%%%\x1B\\");
    s.nextSlice("\x1B_Ga=p,i=999\x1B\\");
    s.nextSlice("\x1B_25a1;r;cp=41;%%%invalid%%%\x1B\\");
    try testing.expect(!s.handler.semantic_failure);
    s.nextSlice("Test");
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Test", str);
}
test "OSC 4 set and reset palette" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    const default_color_0 = t.colors.palette.original[0];
    s.nextSlice("\x1b]4;0;rgb:ff/00/00\x1b\\");
    try testing.expectEqual(@as(u8, 0xff), t.colors.palette.current[0].r);
    try testing.expectEqual(@as(u8, 0x00), t.colors.palette.current[0].g);
    try testing.expectEqual(@as(u8, 0x00), t.colors.palette.current[0].b);
    try testing.expect(t.colors.palette.mask.isSet(0));
    s.nextSlice("\x1b]104;0\x1b\\");
    try testing.expectEqual(default_color_0, t.colors.palette.current[0]);
    try testing.expect(!t.colors.palette.mask.isSet(0));
}
test "OSC 104 reset all palette colors" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1b]4;0;rgb:ff/00/00\x1b\\");
    s.nextSlice("\x1b]4;1;rgb:00/ff/00\x1b\\");
    s.nextSlice("\x1b]4;2;rgb:00/00/ff\x1b\\");
    try testing.expect(t.colors.palette.mask.isSet(0));
    try testing.expect(t.colors.palette.mask.isSet(1));
    try testing.expect(t.colors.palette.mask.isSet(2));
    s.nextSlice("\x1b]104\x1b\\");
    try testing.expectEqual(t.colors.palette.original[0], t.colors.palette.current[0]);
    try testing.expectEqual(t.colors.palette.original[1], t.colors.palette.current[1]);
    try testing.expectEqual(t.colors.palette.original[2], t.colors.palette.current[2]);
    try testing.expect(!t.colors.palette.mask.isSet(0));
    try testing.expect(!t.colors.palette.mask.isSet(1));
    try testing.expect(!t.colors.palette.mask.isSet(2));
}
test "OSC 10 set and reset foreground color" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    try testing.expect(t.colors.foreground.get() == null);
    s.nextSlice("\x1b]10;rgb:ff/00/00\x1b\\");
    const fg = t.colors.foreground.get().?;
    try testing.expectEqual(@as(u8, 0xff), fg.r);
    try testing.expectEqual(@as(u8, 0x00), fg.g);
    try testing.expectEqual(@as(u8, 0x00), fg.b);
    s.nextSlice("\x1b]110\x1b\\");
    try testing.expect(t.colors.foreground.get() == null);
}
test "OSC 11 set and reset background color" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    const default: color.RGB = .{ .r = 0x10, .g = 0x20, .b = 0x30 };
    t.colors.background.default = default;
    s.nextSlice("\x1b]11;rgb:00/ff/00\x1b\\");
    const bg = t.colors.background.get().?;
    try testing.expectEqual(@as(u8, 0x00), bg.r);
    try testing.expectEqual(@as(u8, 0xff), bg.g);
    try testing.expectEqual(@as(u8, 0x00), bg.b);
    s.nextSlice("\x1b]111\x1b\\");
    try testing.expectEqual(default, t.colors.background.get().?);
    try testing.expectEqual(null, t.colors.background.override);
    const updated: color.RGB = .{ .r = 0x40, .g = 0x50, .b = 0x60 };
    t.colors.background.default = updated;
    try testing.expectEqual(updated, t.colors.background.get().?);
}
test "OSC 12 set and reset cursor color" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1b]12;rgb:00/00/ff\x1b\\");
    const cursor = t.colors.cursor.get().?;
    try testing.expectEqual(@as(u8, 0x00), cursor.r);
    try testing.expectEqual(@as(u8, 0x00), cursor.g);
    try testing.expectEqual(@as(u8, 0xff), cursor.b);
    s.nextSlice("\x1b]112\x1b\\");
}
test "OSC color query responses" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var last_response: ?[:0]const u8 = null;
        fn reset() void {
            if (last_response) |old| testing.allocator.free(old);
            last_response = null;
        }
        fn writePty(_: *Handler, data: []const u8) void {
            reset();
            last_response = testing.allocator.dupeZ(u8, data) catch @panic("OOM");
        }
    };
    S.last_response = null;
    defer S.reset();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1b]10;?\x1b\\");
    try testing.expect(S.last_response == null);
    s.nextSlice("\x1b]11;?\x1b\\");
    try testing.expect(S.last_response == null);
    s.nextSlice("\x1b]4;2;rgb:12/34/56;2;?\x1b\\");
    try testing.expectEqualStrings(
        "\x1b]4;2;rgb:1212/3434/5656\x1b\\",
        S.last_response.?,
    );
    s.nextSlice("\x1b]10;rgb:01/02/03\x1b\\");
    s.nextSlice("\x1b]11;rgb:04/05/06\x1b\\");
    s.nextSlice("\x1b]12;rgb:07/08/09\x1b\\");
    s.nextSlice("\x1b]10;?;?;?\x1b\\");
    try testing.expectEqualStrings(
        "\x1b]10;rgb:0101/0202/0303\x1b\\" ++
            "\x1b]11;rgb:0404/0505/0606\x1b\\" ++
            "\x1b]12;rgb:0707/0808/0909\x1b\\",
        S.last_response.?,
    );
    s.nextSlice("\x1b]112\x1b\\");
    s.nextSlice("\x1b]12;?\x07");
    try testing.expectEqualStrings(
        "\x1b]12;rgb:0101/0202/0303\x07",
        S.last_response.?,
    );
}
test "kitty color protocol set palette" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1b]21;5=rgb:ff/00/ff\x1b\\");
    try testing.expectEqual(@as(u8, 0xff), t.colors.palette.current[5].r);
    try testing.expectEqual(@as(u8, 0x00), t.colors.palette.current[5].g);
    try testing.expectEqual(@as(u8, 0xff), t.colors.palette.current[5].b);
    try testing.expect(t.colors.palette.mask.isSet(5));
    try testing.expect(t.flags.dirty.palette);
}
test "kitty color protocol reset palette" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    const original = t.colors.palette.original[7];
    s.nextSlice("\x1b]21;7=rgb:aa/bb/cc\x1b\\");
    try testing.expect(t.colors.palette.mask.isSet(7));
    s.nextSlice("\x1b]21;7=\x1b\\");
    try testing.expectEqual(original, t.colors.palette.current[7]);
    try testing.expect(!t.colors.palette.mask.isSet(7));
}
test "kitty color protocol set foreground" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1b]21;foreground=rgb:12/34/56\x1b\\");
    const fg = t.colors.foreground.get().?;
    try testing.expectEqual(@as(u8, 0x12), fg.r);
    try testing.expectEqual(@as(u8, 0x34), fg.g);
    try testing.expectEqual(@as(u8, 0x56), fg.b);
}
test "kitty color protocol set background" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1b]21;background=rgb:78/9a/bc\x1b\\");
    const bg = t.colors.background.get().?;
    try testing.expectEqual(@as(u8, 0x78), bg.r);
    try testing.expectEqual(@as(u8, 0x9a), bg.g);
    try testing.expectEqual(@as(u8, 0xbc), bg.b);
}
test "kitty color protocol set cursor" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1b]21;cursor=rgb:de/f0/12\x1b\\");
    const cursor = t.colors.cursor.get().?;
    try testing.expectEqual(@as(u8, 0xde), cursor.r);
    try testing.expectEqual(@as(u8, 0xf0), cursor.g);
    try testing.expectEqual(@as(u8, 0x12), cursor.b);
}
test "kitty color protocol reset foreground" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1b]21;foreground=rgb:11/22/33\x1b\\");
    try testing.expect(t.colors.foreground.get() != null);
    s.nextSlice("\x1b]21;foreground=\x1b\\");
    try testing.expect(t.colors.foreground.get() == null);
}
test "kitty color protocol query responses" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var last_response: ?[:0]const u8 = null;
        fn reset() void {
            if (last_response) |old| testing.allocator.free(old);
            last_response = null;
        }
        fn writePty(_: *Handler, data: []const u8) void {
            reset();
            last_response = testing.allocator.dupeZ(u8, data) catch @panic("OOM");
        }
    };
    S.last_response = null;
    defer S.reset();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1b]21;background=?\x1b\\");
    try testing.expectEqualStrings(
        "\x1b]21;background=\x1b\\",
        S.last_response.?,
    );
    s.nextSlice("\x1b]21;foreground=rgb:12/34/56;2=rgb:aa/bb/cc\x1b\\");
    s.nextSlice("\x1b]21;foreground=?;background=?;2=?\x1b\\");
    try testing.expectEqualStrings(
        "\x1b]21;foreground=rgb:12/34/56;background=;2=rgb:aa/bb/cc\x1b\\",
        S.last_response.?,
    );
}
test "palette dirty flag set on color change" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    t.flags.dirty.palette = false;
    s.nextSlice("\x1b]4;0;rgb:ff/00/00\x1b\\");
    try testing.expect(t.flags.dirty.palette);
    t.flags.dirty.palette = false;
    s.nextSlice("\x1b]104;0\x1b\\");
    try testing.expect(t.flags.dirty.palette);
    t.flags.dirty.palette = false;
    s.nextSlice("\x1b]21;1=rgb:00/ff/00\x1b\\");
    try testing.expect(t.flags.dirty.palette);
}
test "semantic prompt fresh line" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("Hello");
    s.nextSlice("\x1b]133;L\x07");
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
}
test "semantic prompt fresh line new prompt" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("Hello");
    s.nextSlice("\x1b]133;A\x07");
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(.prompt, t.screens.active.cursor.semantic_content);
    s.nextSlice("prompt$ ");
    s.nextSlice("\x1b]133;A;redraw=1\x07");
    try testing.expect(t.flags.shell_redraws_prompt == .true);
}
test "semantic prompt end of input, then start output" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("Hello");
    s.nextSlice("\x1b]133;A\x07");
    s.nextSlice("prompt$ ");
    s.nextSlice("\x1b]133;B\x07");
    try testing.expectEqual(.input, t.screens.active.cursor.semantic_content);
    s.nextSlice("\x1b]133;C\x07");
    try testing.expectEqual(.output, t.screens.active.cursor.semantic_content);
}
test "semantic prompt prompt_start" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("Hello");
    s.nextSlice("\x1b]133;P\x07");
    try testing.expectEqual(.prompt, t.screens.active.cursor.semantic_content);
    try testing.expectEqual(@as(usize, 5), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
}
test "semantic prompt new_command" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("Hello");
    s.nextSlice("\x1b]133;N\x07");
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(.prompt, t.screens.active.cursor.semantic_content);
}
test "semantic prompt new_command at column zero" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1b]133;N\x07");
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(.prompt, t.screens.active.cursor.semantic_content);
}
test "semantic prompt end_prompt_start_input_terminate_eol clears on linefeed" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1b]133;I\x07");
    try testing.expectEqual(.input, t.screens.active.cursor.semantic_content);
    s.nextSlice("\n");
    try testing.expectEqual(.output, t.screens.active.cursor.semantic_content);
}
test "bell effect callback" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    {
        var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
        defer s.deinit();
        s.nextSlice("\x07");
        s.nextSlice("AfterBell");
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AfterBell", str);
    }
    t.fullReset();
    {
        const S = struct {
            var bell_count: usize = 0;
            fn bell(_: *Handler) void {
                bell_count += 1;
            }
        };
        S.bell_count = 0;
        var handler: Handler = .init(&t);
        handler.effects.bell = &S.bell;
        var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
        defer s.deinit();
        s.nextSlice("\x07");
        try testing.expectEqual(@as(usize, 1), S.bell_count);
        s.nextSlice("\x07\x07");
        try testing.expectEqual(@as(usize, 3), S.bell_count);
    }
}
test "desktop_notification effect callback" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    {
        var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
        defer s.deinit();
        s.nextSlice("\x1B]9;Ignored\x1B\\AfterNotification");
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AfterNotification", str);
    }
    t.fullReset();
    const S = struct {
        var count: usize = 0;
        var last_title: []const u8 = "";
        var last_body: []const u8 = "";
        fn desktopNotification(
            _: *Handler,
            notification: Action.ShowDesktopNotification,
        ) void {
            count += 1;
            last_title = notification.title;
            last_body = notification.body;
        }
    };
    S.count = 0;
    S.last_title = "";
    S.last_body = "";
    var handler: Handler = .init(&t);
    handler.effects.desktop_notification = &S.desktopNotification;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B]9;Build ");
    try testing.expectEqual(@as(usize, 0), S.count);
    s.nextSlice("complete\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.count);
    try testing.expectEqualStrings("", S.last_title);
    try testing.expectEqualStrings("Build complete", S.last_body);
    s.nextSlice("\x1B]777;notify;Codex;Needs attention\x07");
    try testing.expectEqual(@as(usize, 2), S.count);
    try testing.expectEqualStrings("Codex", S.last_title);
    try testing.expectEqualStrings("Needs attention", S.last_body);
}
test "resize_window effect callback" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var calls: usize = 0;
        var last: Handler.ResizeWindow.Grid = .{ .rows = 0, .columns = 0 };
        fn resizeWindow(_: *Handler, request: Handler.ResizeWindow) void {
            calls += 1;
            switch (request) {
                .grid => |grid| last = grid,
            }
        }
    };
    S.calls = 0;
    var handler: Handler = .init(&t);
    handler.effects.resize_window = &S.resizeWindow;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1b[8;30;100t");
    try testing.expectEqual(1, S.calls);
    try testing.expectEqual(Handler.ResizeWindow.Grid{ .rows = 30, .columns = 100 }, S.last);
    s.nextSlice("\x1b[8;;120t");
    try testing.expectEqual(2, S.calls);
    try testing.expectEqual(Handler.ResizeWindow.Grid{ .rows = 0, .columns = 120 }, S.last);
    try testing.expectEqual(80, t.cols);
    try testing.expectEqual(24, t.rows);
}
test "resize_window without effect" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1b[8;30;100t");
    try testing.expectEqual(80, t.cols);
    try testing.expectEqual(24, t.rows);
}
test "progress_report effect callback" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    {
        var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
        defer s.deinit();
        s.nextSlice("\x1B]9;4;1;25\x1B\\");
    }
    const S = struct {
        var count: usize = 0;
        var last_state: osc.Command.ProgressReport.State = .remove;
        var last_progress: ?u8 = null;
        fn progressReport(_: *Handler, report: osc.Command.ProgressReport) void {
            count += 1;
            last_state = report.state;
            last_progress = report.progress;
        }
    };
    S.count = 0;
    S.last_state = .remove;
    S.last_progress = null;
    var handler: Handler = .init(&t);
    handler.effects.progress_report = &S.progressReport;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    const cases = [_]struct {
        sequence: []const u8,
        state: osc.Command.ProgressReport.State,
        progress: ?u8,
    }{
        .{ .sequence = "\x1B]9;4;0;\x1B\\", .state = .remove, .progress = null },
        .{ .sequence = "\x1B]9;4;1;42\x07", .state = .set, .progress = 42 },
        .{ .sequence = "\x1B]9;4;2;7\x1B\\", .state = .@"error", .progress = 7 },
        .{ .sequence = "\x1B]9;4;3\x1B\\", .state = .indeterminate, .progress = null },
        .{ .sequence = "\x1B]9;4;4;75\x1B\\", .state = .pause, .progress = 75 },
    };
    for (cases, 1..) |case, expected_count| {
        const midpoint = case.sequence.len / 2;
        s.nextSlice(case.sequence[0..midpoint]);
        try testing.expectEqual(expected_count - 1, S.count);
        s.nextSlice(case.sequence[midpoint..]);
        try testing.expectEqual(expected_count, S.count);
        try testing.expectEqual(case.state, S.last_state);
        try testing.expectEqual(case.progress, S.last_progress);
    }
    s.nextSlice("\x1B]9;4;1;50\x1B\\");
    try testing.expectEqual(@as(usize, cases.len + 1), S.count);
    try testing.expectEqual(osc.Command.ProgressReport.State.set, S.last_state);
    s.nextSlice("\x1Bc");
    try testing.expectEqual(@as(usize, cases.len + 2), S.count);
    try testing.expectEqual(osc.Command.ProgressReport.State.remove, S.last_state);
    try testing.expectEqual(@as(?u8, null), S.last_progress);
}
test "program_status effect callback" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var count: usize = 0;
        var last_state: ?osc.Command.ProgramStatus.State = null;
        var last_id: [64]u8 = undefined;
        var last_id_len: ?usize = null;
        var last_message: [64]u8 = undefined;
        var last_message_len: ?usize = null;
        var written: [128]u8 = undefined;
        var written_len: usize = 0;
        fn reset() void {
            count = 0;
            last_state = null;
            last_id_len = null;
            last_message_len = null;
            written_len = 0;
        }
        fn programStatus(_: *Handler, report: osc.Command.ProgramStatus.Report) void {
            count += 1;
            last_state = report.state;
            last_id_len = if (report.readOption(.id)) |v| copy(&last_id, v) else null;
            var message: std.Io.Writer = .fixed(&last_message);
            report.writeText(.msg, &message) catch unreachable;
            last_message_len = message.buffered().len;
        }
        fn writePty(_: *Handler, data: []const u8) void {
            written_len += copy(written[written_len..], data);
        }
        fn copy(dst: []u8, src: []const u8) usize {
            @memcpy(dst[0..src.len], src);
            return src.len;
        }
    };
    {
        S.reset();
        var handler: Handler = .init(&t);
        handler.effects.write_pty = &S.writePty;
        var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
        defer s.deinit();
        s.nextSlice("\x1B]7501;?\x1B\\\x1B]7501;state=idle\x1B\\");
        try testing.expectEqual(@as(usize, 0), S.written_len);
    }
    S.reset();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.program_status = &S.programStatus;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    const reply = "\x1B]7501;?:states=idle,working,done,blocked,error" ++
        ":kinds=permission,question,auth";
    s.nextSlice("\x1B]7501;?\x1B\\");
    try testing.expectEqualStrings(reply ++ "\x1B\\", S.written[0..S.written_len]);
    S.written_len = 0;
    s.nextSlice("\x1B]7501;?\x07");
    try testing.expectEqualStrings(reply ++ "\x07", S.written[0..S.written_len]);
    try testing.expectEqual(@as(usize, 0), S.count);
    S.written_len = 0;
    s.nextSlice("\x1B]7501;state=working:id=sync:msg=U3lu");
    try testing.expectEqual(@as(usize, 0), S.count);
    s.nextSlice("Y2luZyBwaG90b3M=\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.count);
    try testing.expectEqual(.working, S.last_state.?);
    try testing.expectEqualStrings("sync", S.last_id[0..S.last_id_len.?]);
    try testing.expectEqualStrings("Syncing photos", S.last_message[0..S.last_message_len.?]);
    s.nextSlice("\x1Bc");
    try testing.expectEqual(@as(usize, 2), S.count);
    try testing.expectEqual(.clear, S.last_state.?);
    try testing.expect(S.last_id_len == null);
    try testing.expectEqual(@as(?usize, 0), S.last_message_len);
    try testing.expectEqual(@as(usize, 0), S.written_len);
}
test "semantic_prompt effect callback" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    {
        var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
        defer s.deinit();
        s.nextSlice("\x1B]133;C;cmdline_url=ls\x1B\\");
    }
    const S = struct {
        var count: usize = 0;
        var last: Handler.SemanticPrompt = .{ .kind = .invalid };
        var last_cursor_x: usize = 0;
        var command_buf: [64]u8 = undefined;
        var err_buf: [64]u8 = undefined;
        fn semanticPrompt(handler: *Handler, event: Handler.SemanticPrompt) void {
            count += 1;
            last = event;
            last_cursor_x = handler.terminal.screens.active.cursor.x;
            @memcpy(command_buf[0..event.command.len], event.command);
            last.command = command_buf[0..event.command.len];
            @memcpy(err_buf[0..event.err.len], event.err);
            last.err = err_buf[0..event.err.len];
        }
    };
    S.count = 0;
    var handler: Handler = .init(&t);
    handler.effects.semantic_prompt = &S.semanticPrompt;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("abc");
    s.nextSlice("\x1B]133;A\x07");
    try testing.expectEqual(@as(usize, 1), S.count);
    try testing.expectEqual(Handler.SemanticPrompt.Kind.prompt_start, S.last.kind);
    try testing.expectEqual(Handler.SemanticPrompt.PromptKind.primary, S.last.prompt_kind);
    try testing.expectEqual(@as(usize, 0), S.last_cursor_x);
    s.nextSlice("\x1B]133;P;k=r\x07");
    try testing.expectEqual(@as(usize, 2), S.count);
    try testing.expectEqual(Handler.SemanticPrompt.Kind.prompt_start, S.last.kind);
    try testing.expectEqual(Handler.SemanticPrompt.PromptKind.right, S.last.prompt_kind);
    s.nextSlice("\x1B]133;P;k=c\x07");
    try testing.expectEqual(@as(usize, 3), S.count);
    try testing.expectEqual(Handler.SemanticPrompt.PromptKind.continuation, S.last.prompt_kind);
    s.nextSlice("\x1B]133;P;k=s\x07");
    try testing.expectEqual(@as(usize, 4), S.count);
    try testing.expectEqual(Handler.SemanticPrompt.PromptKind.secondary, S.last.prompt_kind);
    s.nextSlice("\x1B]133;P;k=x\x07");
    try testing.expectEqual(@as(usize, 5), S.count);
    try testing.expectEqual(Handler.SemanticPrompt.PromptKind.primary, S.last.prompt_kind);
    s.nextSlice("\x1B]133;N\x07");
    try testing.expectEqual(@as(usize, 6), S.count);
    try testing.expectEqual(Handler.SemanticPrompt.Kind.prompt_start, S.last.kind);
    try testing.expectEqual(Handler.SemanticPrompt.PromptKind.primary, S.last.prompt_kind);
    s.nextSlice("\x1B]133;B\x07");
    try testing.expectEqual(@as(usize, 7), S.count);
    try testing.expectEqual(Handler.SemanticPrompt.Kind.input_start, S.last.kind);
    s.nextSlice("\x1B]133;I\x07");
    try testing.expectEqual(@as(usize, 8), S.count);
    try testing.expectEqual(Handler.SemanticPrompt.Kind.input_start, S.last.kind);
    s.nextSlice("\x1B]133;C;cmdline_url=ls%20-la\x07");
    try testing.expectEqual(@as(usize, 9), S.count);
    try testing.expectEqual(Handler.SemanticPrompt.Kind.output_start, S.last.kind);
    try testing.expectEqualStrings("ls -la", S.last.command);
    s.nextSlice("\x1B]133;C;cmdline='echo hi'\x07");
    try testing.expectEqual(@as(usize, 10), S.count);
    try testing.expectEqualStrings("echo hi", S.last.command);
    s.nextSlice("\x1B]133;C\x07");
    try testing.expectEqual(@as(usize, 11), S.count);
    try testing.expectEqual(Handler.SemanticPrompt.Kind.output_start, S.last.kind);
    try testing.expectEqualStrings("", S.last.command);
    s.nextSlice("\x1B]133;C;cmdline='bad\x07");
    try testing.expectEqual(@as(usize, 12), S.count);
    try testing.expectEqualStrings("", S.last.command);
    s.nextSlice("\x1B]133;D;1\x07");
    try testing.expectEqual(@as(usize, 13), S.count);
    try testing.expectEqual(Handler.SemanticPrompt.Kind.command_end, S.last.kind);
    try testing.expectEqual(@as(?i32, 1), S.last.exit_code);
    try testing.expectEqualStrings("", S.last.err);
    s.nextSlice("\x1B]133;D\x07");
    try testing.expectEqual(@as(usize, 14), S.count);
    try testing.expectEqual(Handler.SemanticPrompt.Kind.command_end, S.last.kind);
    try testing.expectEqual(@as(?i32, null), S.last.exit_code);
    s.nextSlice("\x1B]133;D;-2;err=boom\x07");
    try testing.expectEqual(@as(usize, 15), S.count);
    try testing.expectEqual(@as(?i32, -2), S.last.exit_code);
    try testing.expectEqualStrings("boom", S.last.err);
    s.nextSlice("\x1B]133;L\x07");
    try testing.expectEqual(@as(usize, 15), S.count);
    s.nextSlice("\x1B]133;Lx\x07");
    s.nextSlice("\x1B]133;Z\x07");
    try testing.expectEqual(@as(usize, 15), S.count);
}
test "reset effect callback" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var events: [8]u8 = undefined;
        var len: usize = 0;
        var reset_cursor_x: usize = 0;
        fn progressReport(_: *Handler, _: osc.Command.ProgressReport) void {
            events[len] = 'p';
            len += 1;
        }
        fn reset(handler: *Handler) void {
            reset_cursor_x = handler.terminal.screens.active.cursor.x;
            events[len] = 'r';
            len += 1;
        }
    };
    S.len = 0;
    S.reset_cursor_x = 0;
    var handler: Handler = .init(&t);
    handler.effects.progress_report = &S.progressReport;
    handler.effects.reset = &S.reset;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B[!p");
    try testing.expectEqualStrings("", S.events[0..S.len]);
    s.nextSlice("abc\x1Bc");
    try testing.expectEqualStrings("pr", S.events[0..S.len]);
    try testing.expectEqual(@as(usize, 0), S.reset_cursor_x);
}
test "clipboard_write effect callback" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    {
        var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
        defer s.deinit();
        s.nextSlice("\x1B]52;c;aGVsbG8=\x1B\\");
        s.nextSlice("AfterClipboard");
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AfterClipboard", str);
    }
    t.fullReset();
    const S = struct {
        var count: usize = 0;
        var result: clipboard.Write.Result = .{ .success = .{} };
        var last_location: clipboard.Location = .standard;
        var last_contents_len: usize = 0;
        var last_mime: ?[]u8 = null;
        var last_data: ?[]u8 = null;
        fn clearCapture() void {
            if (last_mime) |value| testing.allocator.free(value);
            if (last_data) |value| testing.allocator.free(value);
            last_mime = null;
            last_data = null;
            last_contents_len = 0;
        }
        fn clipboardWrite(_: *Handler, write: clipboard.Write) void {
            clearCapture();
            count += 1;
            last_location = write.location;
            last_contents_len = write.contents.len;
            if (write.contents.len > 0) {
                last_mime = testing.allocator.dupe(u8, write.contents[0].mime) catch
                    @panic("failed to capture clipboard MIME type");
                last_data = testing.allocator.dupe(u8, write.contents[0].data) catch
                    @panic("failed to capture clipboard data");
            }
            write.reply(result);
        }
    };
    S.count = 0;
    S.result = .denied;
    S.clearCapture();
    defer S.clearCapture();
    var handler: Handler = .init(&t);
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    const cases = [_]struct {
        sequence: []const u8,
        location: clipboard.Location,
        data: []const u8,
    }{
        .{ .sequence = "\x1B]52;c;aGVsbG8=\x1B\\", .location = .standard, .data = "hello" },
        .{ .sequence = "\x1B]52;s;d29ybGQ=\x07", .location = .selection, .data = "world" },
        .{ .sequence = "\x1B]52;p;cHJpbWFyeQ==\x1B\\", .location = .primary, .data = "primary" },
        .{ .sequence = "\x1B]52;0;Y3V0\x1B\\", .location = .standard, .data = "cut" },
        .{ .sequence = "\x1B]52;x;ZmFsbGJhY2s=\x1B\\", .location = .standard, .data = "fallback" },
        .{ .sequence = "\x1B]52;c;YQBi\x1B\\", .location = .standard, .data = "a\x00b" },
        .{ .sequence = "\x1B]52;c;dW5wYWRkZWQ\x1B\\", .location = .standard, .data = "unpadded" },
    };
    for (cases, 1..) |case, expected_count| {
        s.nextSlice(case.sequence);
        try testing.expectEqual(expected_count, S.count);
        try testing.expectEqual(case.location, S.last_location);
        try testing.expectEqual(@as(usize, 1), S.last_contents_len);
        try testing.expectEqualStrings("text/plain", S.last_mime.?);
        try testing.expectEqualSlices(u8, case.data, S.last_data.?);
    }
    s.nextSlice("\x1B]52;s;\x1B\\");
    try testing.expectEqual(@as(usize, cases.len + 1), S.count);
    try testing.expectEqual(clipboard.Location.selection, S.last_location);
    try testing.expectEqual(@as(usize, 0), S.last_contents_len);
    try testing.expect(S.last_mime == null);
    try testing.expect(S.last_data == null);
    s.nextSlice("\x1B]52;c;?\x1B\\");
    s.nextSlice("\x1B]52;c;***\x1B\\");
    s.nextSlice("\x1B]52;c;SGVs!!!bG8=\x1B\\");
    s.nextSlice("\x1B]52;c;aGVs bG8=\x1B\\");
    try testing.expectEqual(@as(usize, cases.len + 1), S.count);
    s.nextSlice("\x1B]1337;Copy=:aVRlcm0y\x1B\\");
    try testing.expectEqual(@as(usize, cases.len + 2), S.count);
    try testing.expectEqual(clipboard.Location.standard, S.last_location);
    try testing.expectEqualStrings("text/plain", S.last_mime.?);
    try testing.expectEqualStrings("iTerm2", S.last_data.?);
    s.nextSlice("\x1B]52;p;ZnJh");
    s.nextSlice("Z21lbnRlZA==\x1B");
    s.nextSlice("\\");
    try testing.expectEqual(@as(usize, cases.len + 3), S.count);
    try testing.expectEqual(clipboard.Location.primary, S.last_location);
    try testing.expectEqualStrings("text/plain", S.last_mime.?);
    try testing.expectEqualStrings("fragmented", S.last_data.?);
    try testing.expect(S.result == .denied);
}
test "clipboard_read effect callback" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: std.ArrayList(u8) = .empty;
        var count: usize = 0;
        var last_location: clipboard.Location = .standard;
        var last_mimes: []const []const u8 = &.{};
        var last_list: bool = true;
        var last_name: []const u8 = "unset";
        var last_granted: bool = true;
        var last_can_remember: bool = true;
        var result: ?clipboard.Read.Result = .{ .success = .{ .contents = &.{.{
            .mime = "text/plain",
            .data = "hello",
        }} } };
        var reply_twice: bool = false;
        fn writePty(_: *Handler, data: []const u8) void {
            written.appendSlice(testing.allocator, data) catch @panic("OOM");
        }
        fn clipboardRead(_: *Handler, read: clipboard.Read) void {
            count += 1;
            last_location = read.location;
            last_mimes = read.mimes;
            last_list = read.list;
            last_name = read.name;
            last_granted = read.granted;
            last_can_remember = read.can_remember;
            if (result) |r| read.reply(r);
            if (reply_twice) read.reply(.{ .success = .{ .contents = &.{.{
                .mime = "text/plain",
                .data = "again",
            }} } });
        }
    };
    defer S.written.deinit(testing.allocator);
    {
        var handler: Handler = .init(&t);
        handler.effects.write_pty = &S.writePty;
        var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
        defer s.deinit();
        s.nextSlice("\x1B]52;c;?\x1B\\");
        try testing.expectEqual(0, S.written.items.len);
    }
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B]52;c;?\x1B\\");
    try testing.expectEqual(1, S.count);
    try testing.expectEqual(clipboard.Location.standard, S.last_location);
    try testing.expectEqual(1, S.last_mimes.len);
    try testing.expectEqualStrings("text/plain", S.last_mimes[0]);
    try testing.expect(!S.last_list);
    try testing.expectEqualStrings("", S.last_name);
    try testing.expect(!S.last_granted);
    try testing.expect(!S.last_can_remember);
    try testing.expectEqualStrings("\x1B]52;c;aGVsbG8=\x1B\\", S.written.items);
    S.written.clearRetainingCapacity();
    s.nextSlice("\x1B]52;p;?\x07");
    try testing.expectEqual(clipboard.Location.primary, S.last_location);
    try testing.expectEqualStrings("\x1B]52;p;aGVsbG8=\x07", S.written.items);
    S.written.clearRetainingCapacity();
    S.result = .{
        .success = .{
            .contents = &.{
                .{ .mime = "image/png", .data = "\x89PNG" },
                .{ .mime = "UTF8_STRING", .data = "hi" },
            },
            .remember = true,
        },
    };
    s.nextSlice("\x1B]52;s;?\x1B\\");
    try testing.expectEqual(clipboard.Location.selection, S.last_location);
    try testing.expectEqualStrings("\x1B]52;s;aGk=\x1B\\", S.written.items);
    for ([_]?clipboard.Read.Result{
        .denied,
        .unsupported,
        .busy,
        .io_error,
        .{ .success = .{} },
        null,
    }) |result| {
        S.written.clearRetainingCapacity();
        S.result = result;
        s.nextSlice("\x1B]52;c;?\x1B\\");
        try testing.expectEqualStrings("\x1B]52;c;\x1B\\", S.written.items);
    }
    S.written.clearRetainingCapacity();
    S.result = .{ .success = .{ .contents = &.{.{ .mime = "text/plain", .data = "hello" }} } };
    S.reply_twice = true;
    s.nextSlice("\x1B]52;c;?\x1B\\");
    try testing.expectEqualStrings("\x1B]52;c;aGVsbG8=\x1B\\", S.written.items);
}
test "clipboard_write allocation failure is ignored" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var count: usize = 0;
        fn clipboardWrite(_: *Handler, write: clipboard.Write) void {
            count += 1;
            write.reply(.{ .success = .{} });
        }
    };
    S.count = 0;
    var handler: Handler = .init(&t);
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    {
        const alloc = t.screens.active.alloc;
        t.screens.active.alloc = testing.failing_allocator;
        defer t.screens.active.alloc = alloc;
        s.nextSlice("\x1B]52;c;aGVsbG8=\x1B\\");
    }
    try testing.expectEqual(@as(usize, 0), S.count);
    try testing.expect(!s.handler.semantic_failure);
}
const KittyClipboardCapture = struct {
    var responses: [1024]u8 = undefined;
    var responses_len: usize = 0;
    var write_count: usize = 0;
    var write_result: ?clipboard.Write.Result = .{ .success = .{} };
    var write_reply_twice: bool = false;
    var last_location: clipboard.Location = .standard;
    var last_contents_len: usize = 0;
    var last_mimes: [8][64]u8 = undefined;
    var last_mime_lens: [8]usize = @splat(0);
    var last_data: [8][256]u8 = undefined;
    var last_data_lens: [8]usize = @splat(0);
    var last_write_name: [64]u8 = undefined;
    var last_write_name_len: usize = 0;
    var last_write_granted: bool = false;
    var last_write_can_remember: bool = false;
    var read_count: usize = 0;
    var read_result: ?clipboard.Read.Result = null;
    var read_reply_twice: bool = false;
    var last_read_location: clipboard.Location = .standard;
    var last_read_mimes: [8][64]u8 = undefined;
    var last_read_mime_lens: [8]usize = @splat(0);
    var last_read_mimes_len: usize = 0;
    var last_read_list: bool = false;
    var last_read_name: [64]u8 = undefined;
    var last_read_name_len: usize = 0;
    var last_read_granted: bool = false;
    var last_read_can_remember: bool = false;
    fn reset() void {
        responses_len = 0;
        write_count = 0;
        write_result = .{ .success = .{} };
        write_reply_twice = false;
        last_location = .standard;
        last_contents_len = 0;
        last_mime_lens = @splat(0);
        last_data_lens = @splat(0);
        last_write_name_len = 0;
        last_write_granted = false;
        last_write_can_remember = false;
        read_count = 0;
        read_result = null;
        read_reply_twice = false;
        last_read_location = .standard;
        last_read_mime_lens = @splat(0);
        last_read_mimes_len = 0;
        last_read_list = false;
        last_read_name_len = 0;
        last_read_granted = false;
        last_read_can_remember = false;
    }
    fn writePty(_: *Handler, data: []const u8) void {
        @memcpy(responses[responses_len..][0..data.len], data);
        responses_len += data.len;
    }
    fn clipboardWrite(_: *Handler, write: clipboard.Write) void {
        write_count += 1;
        last_location = write.location;
        last_contents_len = write.contents.len;
        for (write.contents[0..@min(write.contents.len, last_mimes.len)], 0..) |content, i| {
            last_mime_lens[i] = content.mime.len;
            @memcpy(last_mimes[i][0..content.mime.len], content.mime);
            last_data_lens[i] = content.data.len;
            @memcpy(last_data[i][0..content.data.len], content.data);
        }
        last_write_name_len = write.name.len;
        @memcpy(last_write_name[0..write.name.len], write.name);
        last_write_granted = write.granted;
        last_write_can_remember = write.can_remember;
        if (write_result) |r| write.reply(r);
        if (write_reply_twice) write.reply(.io_error);
    }
    fn clipboardRead(_: *Handler, read: clipboard.Read) void {
        read_count += 1;
        last_read_location = read.location;
        last_read_mimes_len = read.mimes.len;
        for (read.mimes[0..@min(read.mimes.len, last_read_mimes.len)], 0..) |mime, i| {
            last_read_mime_lens[i] = mime.len;
            @memcpy(last_read_mimes[i][0..mime.len], mime);
        }
        last_read_list = read.list;
        last_read_name_len = read.name.len;
        @memcpy(last_read_name[0..read.name.len], read.name);
        last_read_granted = read.granted;
        last_read_can_remember = read.can_remember;
        if (read_result) |r| read.reply(r);
        if (read_reply_twice) read.reply(.denied);
    }
    fn responseSlice() []const u8 {
        return responses[0..responses_len];
    }
    fn readMimeAt(i: usize) []const u8 {
        return last_read_mimes[i][0..last_read_mime_lens[i]];
    }
    fn readName() []const u8 {
        return last_read_name[0..last_read_name_len];
    }
    fn writeName() []const u8 {
        return last_write_name[0..last_write_name_len];
    }
    fn mimeAt(i: usize) []const u8 {
        return last_mimes[i][0..last_mime_lens[i]];
    }
    fn dataAt(i: usize) []const u8 {
        return last_data[i][0..last_data_lens[i]];
    }
};
test "kitty clipboard write transaction round trip" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = KittyClipboardCapture;
    S.reset();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B]5522;type=write:id=42\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3Q=\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;dHk=\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9odG1s;PGI+aGk8L2I+\x1B\\");
    s.nextSlice("\x1B]5522;type=walias:mime=dGV4dC9wbGFpbg==;VEVYVCBVVEY4X1NUUklORw==\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expectEqual(@as(usize, 0), S.responses_len);
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.write_count);
    try testing.expectEqual(clipboard.Location.standard, S.last_location);
    try testing.expectEqual(@as(usize, 4), S.last_contents_len);
    try testing.expectEqualStrings("text/plain", S.mimeAt(0));
    try testing.expectEqualStrings("Wasp", S.dataAt(0));
    try testing.expectEqualStrings("text/html", S.mimeAt(1));
    try testing.expectEqualStrings("<b>hi</b>", S.dataAt(1));
    try testing.expectEqualStrings("TEXT", S.mimeAt(2));
    try testing.expectEqualStrings("Wasp", S.dataAt(2));
    try testing.expectEqualStrings("UTF8_STRING", S.mimeAt(3));
    try testing.expectEqualStrings("Wasp", S.dataAt(3));
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=DONE:id=42\x1B\\",
        S.responseSlice(),
    );
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.write_count);
}
test "kitty clipboard write result maps to response status" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = KittyClipboardCapture;
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    const cases = [_]struct {
        result: ?clipboard.Write.Result,
        response: []const u8,
    }{
        .{ .result = .{ .success = .{} }, .response = "\x1B]5522;type=write:status=DONE\x1B\\" },
        .{ .result = .denied, .response = "\x1B]5522;type=write:status=EPERM\x1B\\" },
        .{ .result = .unsupported, .response = "\x1B]5522;type=write:status=ENOSYS\x1B\\" },
        .{ .result = .busy, .response = "\x1B]5522;type=write:status=EBUSY\x1B\\" },
        .{ .result = .invalid_data, .response = "\x1B]5522;type=write:status=EINVAL\x1B\\" },
        .{ .result = .io_error, .response = "\x1B]5522;type=write:status=EIO\x1B\\" },
        .{ .result = null, .response = "\x1B]5522;type=write:status=EPERM\x1B\\" },
    };
    for (cases) |case| {
        S.reset();
        S.write_result = case.result;
        s.nextSlice("\x1B]5522;type=write\x1B\\");
        s.nextSlice("\x1B]5522;type=wdata\x1B\\");
        try testing.expectEqual(@as(usize, 1), S.write_count);
        try testing.expectEqual(@as(usize, 0), S.last_contents_len);
        try testing.expectEqualStrings(case.response, S.responseSlice());
    }
    S.reset();
    S.write_reply_twice = true;
    s.nextSlice("\x1B]5522;type=write\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=DONE\x1B\\",
        S.responseSlice(),
    );
    S.reset();
    s.nextSlice("\x1B]5522;type=write:loc=primary\x07");
    s.nextSlice("\x1B]5522;type=wdata\x07");
    try testing.expectEqual(clipboard.Location.primary, S.last_location);
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=DONE\x07",
        S.responseSlice(),
    );
    S.reset();
    S.write_result = .unsupported;
    s.nextSlice("\x1B]5522;type=write:loc=primary:id=p1\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqual(clipboard.Location.primary, S.last_location);
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=ENOSYS:id=p1\x1B\\",
        S.responseSlice(),
    );
}
test "kitty clipboard write without clipboard effect responds ENOSYS" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = KittyClipboardCapture;
    S.reset();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B]5522;type=write:id=x\x1B\\");
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=ENOSYS:id=x\x1B\\",
        S.responseSlice(),
    );
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3Q=\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=ENOSYS:id=x\x1B\\",
        S.responseSlice(),
    );
}
test "kitty clipboard read without effect is denied with EPERM" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = KittyClipboardCapture;
    S.reset();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B]5522;type=read:loc=primary:id=*4 2*;dGV4dC9wbGFpbg==\x1B\\");
    try testing.expectEqualStrings(
        "\x1B]5522;type=read:status=EPERM:id=42\x1B\\",
        S.responseSlice(),
    );
    S.reset();
    s.nextSlice("\x1B]5522;type=read\x07");
    try testing.expectEqualStrings(
        "\x1B]5522;type=read:status=EPERM\x07",
        S.responseSlice(),
    );
    S.reset();
    s.nextSlice("\x1B]5522;type=read;!!!\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.responses_len);
}
test "kitty clipboard read round trip" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = KittyClipboardCapture;
    S.reset();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    S.read_result = .{
        .success = .{
            .contents = &.{
                .{ .mime = "image/png", .data = "\x89PNG" },
                .{ .mime = "text/html", .data = "<b>hi</b>" },
                .{ .mime = "text/plain", .data = "Wasp" },
            },
            .available = &.{ "text/plain", "text/html" },
        },
    };
    s.nextSlice("\x1B]5522;type=read:loc=primary:id=r1;LiB0ZXh0L3BsYWluIHRleHQvaHRtbA==\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.read_count);
    try testing.expectEqual(clipboard.Location.primary, S.last_read_location);
    try testing.expectEqual(@as(usize, 2), S.last_read_mimes_len);
    try testing.expectEqualStrings("text/plain", S.readMimeAt(0));
    try testing.expectEqualStrings("text/html", S.readMimeAt(1));
    try testing.expect(S.last_read_list);
    try testing.expectEqualStrings("", S.readName());
    try testing.expect(!S.last_read_granted);
    try testing.expect(!S.last_read_can_remember);
    try testing.expectEqualStrings(
        "\x1B]5522;type=read:status=OK:loc=primary:id=r1\x1B\\" ++
            "\x1B]5522;type=read:status=DATA:id=r1:mime=Lg==;dGV4dC9wbGFpbiB0ZXh0L2h0bWwK\x1B\\" ++
            "\x1B]5522;type=read:status=DATA:id=r1:mime=dGV4dC9wbGFpbg==;R2hvc3R0eQ==\x1B\\" ++
            "\x1B]5522;type=read:status=DATA:id=r1:mime=dGV4dC9odG1s;PGI+aGk8L2I+\x1B\\" ++
            "\x1B]5522;type=read:status=DONE:id=r1\x1B\\",
        S.responseSlice(),
    );
    S.responses_len = 0;
    s.nextSlice("\x1B]5522;type=read:id=r2;dGV4dC9wbGFpbg==\x07");
    try testing.expectEqual(clipboard.Location.standard, S.last_read_location);
    try testing.expectEqual(@as(usize, 1), S.last_read_mimes_len);
    try testing.expect(!S.last_read_list);
    try testing.expectEqualStrings(
        "\x1B]5522;type=read:status=OK:id=r2\x07" ++
            "\x1B]5522;type=read:status=DATA:id=r2:mime=dGV4dC9wbGFpbg==;R2hvc3R0eQ==\x07" ++
            "\x1B]5522;type=read:status=DONE:id=r2\x07",
        S.responseSlice(),
    );
    S.responses_len = 0;
    s.nextSlice("\x1B]5522;type=read;Lg==\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.last_read_mimes_len);
    try testing.expect(S.last_read_list);
    try testing.expectEqualStrings(
        "\x1B]5522;type=read:status=OK\x1B\\" ++
            "\x1B]5522;type=read:status=DATA:mime=Lg==;dGV4dC9wbGFpbiB0ZXh0L2h0bWwK\x1B\\" ++
            "\x1B]5522;type=read:status=DONE\x1B\\",
        S.responseSlice(),
    );
}
test "kitty clipboard read result maps to response status" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = KittyClipboardCapture;
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    const cases = [_]struct {
        result: ?clipboard.Read.Result,
        response: []const u8,
    }{
        .{ .result = .denied, .response = "\x1B]5522;type=read:status=EPERM:id=x\x1B\\" },
        .{ .result = .unsupported, .response = "\x1B]5522;type=read:status=ENOSYS:id=x\x1B\\" },
        .{ .result = .busy, .response = "\x1B]5522;type=read:status=EBUSY:id=x\x1B\\" },
        .{ .result = .io_error, .response = "\x1B]5522;type=read:status=EIO:id=x\x1B\\" },
        .{ .result = null, .response = "\x1B]5522;type=read:status=EPERM:id=x\x1B\\" },
        .{ .result = .{ .success = .{} }, .response = "\x1B]5522;type=read:status=OK:id=x\x1B\\" ++
            "\x1B]5522;type=read:status=DONE:id=x\x1B\\" },
    };
    for (cases) |case| {
        S.reset();
        S.read_result = case.result;
        s.nextSlice("\x1B]5522;type=read:id=x;dGV4dC9wbGFpbg==\x1B\\");
        try testing.expectEqual(@as(usize, 1), S.read_count);
        try testing.expectEqualStrings(case.response, S.responseSlice());
    }
    S.reset();
    S.read_result = .{ .success = .{ .contents = &.{.{ .mime = "text/plain", .data = "hello" }} } };
    S.read_reply_twice = true;
    s.nextSlice("\x1B]5522;type=read;dGV4dC9wbGFpbg==\x1B\\");
    try testing.expectEqualStrings(
        "\x1B]5522;type=read:status=OK\x1B\\" ++
            "\x1B]5522;type=read:status=DATA:mime=dGV4dC9wbGFpbg==;aGVsbG8=\x1B\\" ++
            "\x1B]5522;type=read:status=DONE\x1B\\",
        S.responseSlice(),
    );
}
test "kitty clipboard read caps requested types" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = KittyClipboardCapture;
    S.reset();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    S.read_result = .{ .success = .{} };
    s.nextSlice("\x1B]5522;type=read;YS8wIGEvMSBhLzIgYS8zIGEvNCBhLzUgLg==\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.read_count);
    try testing.expectEqual(kitty_clipboard.max_read_mimes, S.last_read_mimes_len);
    try testing.expectEqualStrings("a/0", S.readMimeAt(0));
    try testing.expectEqualStrings("a/3", S.readMimeAt(kitty_clipboard.max_read_mimes - 1));
    try testing.expect(S.last_read_list);
}
test "kitty clipboard read password grants" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = KittyClipboardCapture;
    S.reset();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    S.read_result = .{ .success = .{ .remember = true } };
    s.nextSlice("\x1B]5522;type=read:pw=c2VjcmV0:name=YXBw;dGV4dC9wbGFpbg==\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.read_count);
    try testing.expectEqualStrings("app", S.readName());
    try testing.expect(!S.last_read_granted);
    try testing.expect(S.last_read_can_remember);
    S.read_result = .{ .success = .{} };
    s.nextSlice("\x1B]5522;type=read:pw=c2VjcmV0:name=YXBw;dGV4dC9wbGFpbg==\x1B\\");
    try testing.expect(S.last_read_granted);
    s.nextSlice("\x1B]5522;type=read:pw=b3RoZXI=:name=YXBw;dGV4dC9wbGFpbg==\x1B\\");
    try testing.expect(!S.last_read_granted);
    try testing.expect(S.last_read_can_remember);
    S.read_result = .{ .success = .{ .remember = true } };
    s.nextSlice("\x1B]5522;type=read:pw=c2VjcmV0;dGV4dC9wbGFpbg==\x1B\\");
    try testing.expectEqualStrings("", S.readName());
    try testing.expect(!S.last_read_granted);
    try testing.expect(!S.last_read_can_remember);
    s.nextSlice("\x1B]5522;type=read:pw=b3RoZXI=;dGV4dC9wbGFpbg==\x1B\\");
    try testing.expect(!S.last_read_can_remember);
    S.read_result = .{ .success = .{} };
    s.nextSlice("\x1B]5522;type=read:pw=b3RoZXI=:name=YXBw;dGV4dC9wbGFpbg==\x1B\\");
    try testing.expect(!S.last_read_granted);
    S.responses_len = 0;
    S.read_result = .denied;
    s.nextSlice("\x1B]5522;type=read:id=d:pw=c2VjcmV0:name=YXBw;dGV4dC9wbGFpbg==\x1B\\");
    try testing.expect(S.last_read_granted);
    try testing.expectEqualStrings(
        "\x1B]5522;type=read:status=EPERM:id=d\x1B\\",
        S.responseSlice(),
    );
}
test "kitty clipboard read targets-only never consumes a one-time grant" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = KittyClipboardCapture;
    S.reset();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    try s.handler.kitty_clipboard_grants.grant(testing.allocator, "otp", .read, true);
    S.read_result = .{ .success = .{} };
    s.nextSlice("\x1B]5522;type=read:pw=b3Rw:name=YXBw;Lg==\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.read_count);
    try testing.expect(S.last_read_list);
    try testing.expectEqual(@as(usize, 0), S.last_read_mimes_len);
    try testing.expect(!S.last_read_granted);
    s.nextSlice("\x1B]5522;type=read:pw=b3Rw:name=YXBw;dGV4dC9wbGFpbg==\x1B\\");
    try testing.expect(S.last_read_granted);
    s.nextSlice("\x1B]5522;type=read:pw=b3Rw:name=YXBw;dGV4dC9wbGFpbg==\x1B\\");
    try testing.expect(!S.last_read_granted);
}
test "kitty clipboard write password grants" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = KittyClipboardCapture;
    S.reset();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    handler.effects.clipboard_read = &S.clipboardRead;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    S.write_result = .{ .success = .{ .remember = true } };
    s.nextSlice("\x1B]5522;type=write:pw=c2VjcmV0:name=YXBw\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.write_count);
    try testing.expectEqualStrings("app", S.writeName());
    try testing.expect(!S.last_write_granted);
    try testing.expect(S.last_write_can_remember);
    S.write_result = .{ .success = .{} };
    s.nextSlice("\x1B]5522;type=write:pw=c2VjcmV0:name=YXBw\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expect(S.last_write_granted);
    s.nextSlice("\x1B]5522;type=write:pw=b3RoZXI=:name=YXBw\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expect(!S.last_write_granted);
    try testing.expect(S.last_write_can_remember);
    S.read_result = .{ .success = .{} };
    s.nextSlice("\x1B]5522;type=read:pw=c2VjcmV0:name=YXBw\x1B\\");
    try testing.expect(!S.last_read_granted);
    S.write_result = .{ .success = .{ .remember = true } };
    s.nextSlice("\x1B]5522;type=write:pw=c2VjcmV0\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqualStrings("", S.writeName());
    try testing.expect(!S.last_write_granted);
    try testing.expect(!S.last_write_can_remember);
    S.responses_len = 0;
    S.write_result = .denied;
    s.nextSlice("\x1B]5522;type=write:id=d:pw=c2VjcmV0:name=YXBw\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expect(S.last_write_granted);
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=EPERM:id=d\x1B\\",
        S.responseSlice(),
    );
}
test "kitty clipboard malformed packets are silently dropped" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = KittyClipboardCapture;
    S.reset();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B]5522;loc=primary\x1B\\");
    s.nextSlice("\x1B]5522;type=bobr\x1B\\");
    s.nextSlice("\x1B]5522;type=read:bare\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=!!!;R2hvc3Q=\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3Q=\x1B\\");
    s.nextSlice("\x1B]5522;type=walias:mime=dGV4dC9wbGFpbg==;VEVYVA==\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expectEqual(@as(usize, 0), S.responses_len);
    try testing.expect(!s.handler.semantic_failure);
    s.nextSlice("ok");
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("ok", str);
}
test "kitty clipboard new write replaces in-flight transaction" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = KittyClipboardCapture;
    S.reset();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B]5522;type=write:id=old\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;b2xk\x1B\\");
    s.nextSlice("\x1B]5522;type=write:id=new\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;bmV3\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.write_count);
    try testing.expectEqual(@as(usize, 1), S.last_contents_len);
    try testing.expectEqualStrings("new", S.dataAt(0));
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=DONE:id=new\x1B\\",
        S.responseSlice(),
    );
}
test "kitty clipboard invalid write packets abort with EINVAL" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = KittyClipboardCapture;
    S.reset();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    const invalid_packets = [_][]const u8{
        "\x1B]5522;type=walias:mime=dGV4dC9wbGFpbg==;/w==\x1B\\",
        "\x1B]5522;type=walias;VEVYVA==\x1B\\",
        "\x1B]5522;type=walias:mime=//4=;VEVYVA==\x1B\\",
        "\x1B]5522;type=wdata:mime=//4=;R2hvc3Q=\x1B\\",
    };
    for (invalid_packets) |packet| {
        S.responses_len = 0;
        s.nextSlice("\x1B]5522;type=write:id=w\x1B\\");
        s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3Q=\x1B\\");
        s.nextSlice(packet);
        try testing.expectEqualStrings(
            "\x1B]5522;type=write:status=EINVAL:id=w\x1B\\",
            S.responseSlice(),
        );
        try testing.expect(!s.handler.semantic_failure);
        s.nextSlice("\x1B]5522;type=wdata\x1B\\");
        try testing.expectEqual(@as(usize, 0), S.write_count);
        try testing.expectEqualStrings(
            "\x1B]5522;type=write:status=EINVAL:id=w\x1B\\",
            S.responseSlice(),
        );
    }
}
test "kitty clipboard invalid read text does not abort a write" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = KittyClipboardCapture;
    S.reset();
    S.read_result = .{ .success = .{} };
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B]5522;type=write:id=w\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3Q=\x1B\\");
    s.nextSlice("\x1B]5522;type=read;/w==\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.read_count);
    try testing.expectEqual(@as(usize, 0), S.responses_len);
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.write_count);
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=DONE:id=w\x1B\\",
        S.responseSlice(),
    );
}
test "kitty clipboard oversized text write aborts with EFBIG" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = KittyClipboardCapture;
    S.reset();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.handler.kitty_clipboard_write_max_bytes = 4;
    s.nextSlice("\x1B]5522;type=write:id=w\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;SGVsbA==\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.responses_len);
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;bw==\x1B\\");
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=EFBIG:id=w\x1B\\",
        S.responseSlice(),
    );
    try testing.expect(!s.handler.semantic_failure);
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;IQ==\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=EFBIG:id=w\x1B\\",
        S.responseSlice(),
    );
}
test "kitty clipboard invalid wdata chunk aborts with EINVAL" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = KittyClipboardCapture;
    S.reset();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B]5522;type=write:id=w\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;SGVsbG8=\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;!!!bad!!!\x1B\\");
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=EINVAL:id=w\x1B\\",
        S.responseSlice(),
    );
    try testing.expect(!s.handler.semantic_failure);
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;V29ybGQ=\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=EINVAL:id=w\x1B\\",
        S.responseSlice(),
    );
}
test "kitty clipboard wdata chunks split one base64 stream" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = KittyClipboardCapture;
    S.reset();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B]5522;type=write\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;c29\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;tZSBk\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;YXRh\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.write_count);
    try testing.expectEqualStrings("some data", S.dataAt(0));
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=DONE\x1B\\",
        S.responseSlice(),
    );
}
test "kitty clipboard unpadded wdata stream aborts at commit" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = KittyClipboardCapture;
    S.reset();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B]5522;type=write:id=w\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;SGVsbG8\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.responses_len);
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=EINVAL:id=w\x1B\\",
        S.responseSlice(),
    );
    try testing.expect(!s.handler.semantic_failure);
}
test "kitty clipboard in-flight transaction is freed on deinit" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = KittyClipboardCapture;
    S.reset();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B]5522;type=write\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3Q=\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.write_count);
}
test "kitty clipboard allocation failure is ignored" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = KittyClipboardCapture;
    S.reset();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    {
        const alloc = t.screens.active.alloc;
        t.screens.active.alloc = testing.failing_allocator;
        defer t.screens.active.alloc = alloc;
        s.nextSlice("\x1B]5522;type=write\x1B\\");
    }
    try testing.expect(!s.handler.semantic_failure);
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3Q=\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expectEqual(@as(usize, 0), S.responses_len);
}
test "kitty clipboard without write_pty still commits writes" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = KittyClipboardCapture;
    S.reset();
    var handler: Handler = .init(&t);
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B]5522;type=write\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3Q=\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.write_count);
    try testing.expectEqualStrings("Ghost", S.dataAt(0));
    s.nextSlice("\x1B]5522;type=read\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.responses_len);
}
test "request mode DECRQM with write_pty callback" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    {
        var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
        defer s.deinit();
        s.nextSlice("\x1B[?7$p");
        s.nextSlice("\x1B[4$p");
    }
    t.fullReset();
    {
        const S = struct {
            var last_response: ?[:0]const u8 = null;
            fn writePty(_: *Handler, data: []const u8) void {
                if (last_response) |old| testing.allocator.free(old);
                last_response = testing.allocator.dupeZ(u8, data) catch @panic("OOM");
            }
        };
        S.last_response = null;
        defer if (S.last_response) |old| testing.allocator.free(old);
        var handler: Handler = .init(&t);
        handler.effects.write_pty = &S.writePty;
        var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
        defer s.deinit();
        s.nextSlice("\x1B[?7$p");
        try testing.expectEqualStrings("\x1B[?7;1$y", S.last_response.?);
        s.nextSlice("\x1B[?7l");
        s.nextSlice("\x1B[?7$p");
        try testing.expectEqualStrings("\x1B[?7;2$y", S.last_response.?);
        const before = t.modes;
        s.nextSlice("\x1B[?32775$p");
        try testing.expectEqualStrings("\x1B[?32775;0$y", S.last_response.?);
        try testing.expectEqualDeep(before, t.modes);
        s.nextSlice("\x1B[?9999$p");
        try testing.expectEqualStrings("\x1B[?9999;0$y", S.last_response.?);
        s.nextSlice("\x1B[?117$p");
        try testing.expectEqualStrings("\x1B[?117;4$y", S.last_response.?);
    }
}
test "request mode DECRQM ANSI responses" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var response: [32]u8 = undefined;
        var len: usize = 0;
        var calls: usize = 0;
        fn writePty(_: *Handler, data: []const u8) void {
            @memcpy(response[0..data.len], data);
            len = data.len;
            calls += 1;
        }
    };
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    inline for (.{
        .{ "2", modes.Mode.disable_keyboard },
        .{ "4", modes.Mode.insert },
        .{ "12", modes.Mode.send_receive_mode },
        .{ "20", modes.Mode.linefeed },
    }) |mode| {
        inline for (.{ false, true, false }) |enabled| {
            s.nextSlice("\x1b[" ++ mode[0] ++ (if (enabled) "h" else "l"));
            try testing.expectEqual(enabled, t.modes.get(mode[1]));
            const query = "\x1b[" ++ mode[0] ++ "$p";
            for (0..query.len + 1) |split| {
                S.calls = 0;
                S.len = 0;
                s.nextSlice(query[0..split]);
                if (split < query.len) try testing.expectEqual(0, S.calls);
                s.nextSlice(query[split..]);
                try testing.expectEqual(1, S.calls);
                try testing.expectEqualStrings("\x1b[" ++ mode[0] ++ (if (enabled) ";1$y" else ";2$y"), S.response[0..S.len]);
                try testing.expectEqual(enabled, t.modes.get(mode[1]));
            }
        }
    }
    s.nextSlice("\x1b[4h\x1b[?4l");
    const cases = .{
        .{ "\x1b[4$p", "\x1b[4;1$y" },
        .{ "\x1b[?4$p", "\x1b[?4;2$y" },
        .{ "\x1b[9999$p", "\x1b[9999;0$y" },
        .{ "\x1b[1$p", "\x1b[1;4$y" },
        .{ "\x1b[19$p", "\x1b[19;4$y" },
    };
    inline for (cases) |case| {
        S.calls = 0;
        S.len = 0;
        s.nextSlice(case[0]);
        try testing.expectEqual(1, S.calls);
        try testing.expectEqualStrings(case[1], S.response[0..S.len]);
    }
}
test "stream: CSI W with intermediate but no params" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_bytes = 100,
    });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1b[?W");
}
test "window_title effect is called" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var title_changed_count: usize = 0;
        fn titleChanged(_: *Handler) void {
            title_changed_count += 1;
        }
    };
    S.title_changed_count = 0;
    var handler: Handler = .init(&t);
    handler.effects.title_changed = &S.titleChanged;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1b]2;Hello World\x1b\\");
    try testing.expectEqualStrings("Hello World", t.getTitle().?);
    try testing.expectEqual(@as(usize, 1), S.title_changed_count);
}
test "window_title effect not called without callback" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1b]2;Hello World\x1b\\");
    try testing.expectEqualStrings("Hello World", t.getTitle().?);
    s.nextSlice("Test");
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Test", str);
}
test "window_title effect with empty title" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var title_changed_count: usize = 0;
        fn titleChanged(_: *Handler) void {
            title_changed_count += 1;
        }
    };
    S.title_changed_count = 0;
    var handler: Handler = .init(&t);
    handler.effects.title_changed = &S.titleChanged;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1b]2;\x1b\\");
    try testing.expect(t.getTitle() == null);
    try testing.expectEqual(@as(usize, 1), S.title_changed_count);
}
test "window_title not changed by cancelled OSC" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var title_changed_count: usize = 0;
        fn titleChanged(_: *Handler) void {
            title_changed_count += 1;
        }
    };
    S.title_changed_count = 0;
    var handler: Handler = .init(&t);
    handler.effects.title_changed = &S.titleChanged;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1b]2;before\x07");
    try testing.expectEqualStrings("before", t.getTitle().?);
    try testing.expectEqual(@as(usize, 1), S.title_changed_count);
    s.nextSlice("\x1b]2;can\x18");
    try testing.expectEqualStrings("before", t.getTitle().?);
    try testing.expectEqual(@as(usize, 1), S.title_changed_count);
    s.nextSlice("\x1b]2;sub\x1a");
    try testing.expectEqualStrings("before", t.getTitle().?);
    try testing.expectEqual(@as(usize, 1), S.title_changed_count);
    for ("\x1b]2;can\x18") |c| s.next(c);
    try testing.expectEqualStrings("before", t.getTitle().?);
    try testing.expectEqual(@as(usize, 1), S.title_changed_count);
    for ("\x1b]2;sub\x1a") |c| s.next(c);
    try testing.expectEqualStrings("before", t.getTitle().?);
    try testing.expectEqual(@as(usize, 1), S.title_changed_count);
    s.nextSlice("\x1b]2;after\x1b\\");
    try testing.expectEqualStrings("after", t.getTitle().?);
    try testing.expectEqual(@as(usize, 2), S.title_changed_count);
}
test "kitty_keyboard_query" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        var written_buf: [64]u8 = undefined;
        fn writePty(_: *Handler, data: []const u8) void {
            std.debug.assert(data.len <= written_buf.len);
            @memcpy(written_buf[0..data.len], data);
            written = written_buf[0..data.len];
        }
    };
    S.written = null;
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1b[?u");
    try testing.expectEqualStrings("\x1b[?0u", S.written.?);
    S.written = null;
    s.nextSlice("\x1b[>1u");
    s.nextSlice("\x1b[?u");
    try testing.expectEqualStrings("\x1b[?1u", S.written.?);
}
test "xtversion default" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        var written_buf: [64]u8 = undefined;
        fn writePty(_: *Handler, data: []const u8) void {
            std.debug.assert(data.len <= written_buf.len);
            @memcpy(written_buf[0..data.len], data);
            written = written_buf[0..data.len];
        }
    };
    S.written = null;
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1b[>0q");
    try testing.expectEqualStrings("\x1bP>|libwasp\x1b\\", S.written.?);
}
test "xtversion with effect" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        var written_buf: [64]u8 = undefined;
        fn writePty(_: *Handler, data: []const u8) void {
            std.debug.assert(data.len <= written_buf.len);
            @memcpy(written_buf[0..data.len], data);
            written = written_buf[0..data.len];
        }
        fn xtversion(_: *Handler) []const u8 {
            return "wasp 1.2.3";
        }
    };
    S.written = null;
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.xtversion = &S.xtversion;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1b[>0q");
    try testing.expectEqualStrings("\x1bP>|wasp 1.2.3\x1b\\", S.written.?);
}
test "xtversion with empty string effect" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        var written_buf: [64]u8 = undefined;
        fn writePty(_: *Handler, data: []const u8) void {
            std.debug.assert(data.len <= written_buf.len);
            @memcpy(written_buf[0..data.len], data);
            written = written_buf[0..data.len];
        }
        fn xtversion(_: *Handler) []const u8 {
            return "";
        }
    };
    S.written = null;
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.xtversion = &S.xtversion;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1b[>0q");
    try testing.expectEqualStrings("\x1bP>|libwasp\x1b\\", S.written.?);
}
test "size report csi_14_t with effect" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
        fn getSize(_: *Handler) ?size_report.Size {
            return .{ .rows = 24, .columns = 80, .cell_width = 9, .cell_height = 18 };
        }
    };
    S.written = null;
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.size = &S.getSize;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1b[14t");
    defer testing.allocator.free(S.written.?);
    try testing.expectEqualStrings("\x1b[4;432;720t", S.written.?);
}
test "mode 2048 enable reports current geometry and disable is silent" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var response: [128]u8 = undefined;
        var response_len: usize = 0;
        var calls: usize = 0;
        fn writePty(_: *Handler, data: []const u8) void {
            @memcpy(response[0..data.len], data);
            response_len = data.len;
            calls += 1;
        }
        fn getSize(_: *Handler) ?size_report.Size {
            return .{ .rows = 24, .columns = 80, .cell_width = 8, .cell_height = 16 };
        }
    };
    S.response_len = 0;
    S.calls = 0;
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.size = &S.getSize;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1b[?2048h");
    s.nextSlice("\x1b[?2048h");
    try testing.expectEqual(@as(usize, 2), S.calls);
    try testing.expectEqualStrings("\x1b[48;24;80;384;640t", S.response[0..S.response_len]);
    s.nextSlice("\x1b[?2048l");
    try testing.expectEqual(@as(usize, 2), S.calls);
    try testing.expect(!t.modes.get(.in_band_size_reports));
}
test "mode 2048 enable tolerates missing effects" {
    const S = struct {
        var calls: usize = 0;
        fn writePty(_: *Handler, _: []const u8) void {
            calls += 1;
        }
        fn getSize(_: *Handler) ?size_report.Size {
            return .{ .rows = 24, .columns = 80, .cell_width = 8, .cell_height = 16 };
        }
    };
    S.calls = 0;
    var no_size_terminal: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 80, .rows = 24 },
    );
    defer no_size_terminal.deinit(testing.allocator);
    var no_size_handler: Handler = .init(&no_size_terminal);
    no_size_handler.effects.write_pty = &S.writePty;
    var no_size_stream: Stream = .init(.{
        .allocator = testing.allocator,
        .handler = no_size_handler,
    });
    defer no_size_stream.deinit();
    no_size_stream.nextSlice("\x1b[?2048h");
    try testing.expect(no_size_terminal.modes.get(.in_band_size_reports));
    try testing.expectEqual(@as(usize, 0), S.calls);
    var no_write_terminal: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 80, .rows = 24 },
    );
    defer no_write_terminal.deinit(testing.allocator);
    var no_write_handler: Handler = .init(&no_write_terminal);
    no_write_handler.effects.size = &S.getSize;
    var no_write_stream: Stream = .init(.{
        .allocator = testing.allocator,
        .handler = no_write_handler,
    });
    defer no_write_stream.deinit();
    no_write_stream.nextSlice("\x1b[?2048h");
    try testing.expect(no_write_terminal.modes.get(.in_band_size_reports));
    try testing.expectEqual(@as(usize, 0), S.calls);
}
test "size report csi_16_t with effect" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
        fn getSize(_: *Handler) ?size_report.Size {
            return .{ .rows = 24, .columns = 80, .cell_width = 9, .cell_height = 18 };
        }
    };
    S.written = null;
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.size = &S.getSize;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1b[16t");
    defer testing.allocator.free(S.written.?);
    try testing.expectEqualStrings("\x1b[6;18;9t", S.written.?);
}
test "size report csi_18_t with effect" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
        fn getSize(_: *Handler) ?size_report.Size {
            return .{ .rows = 24, .columns = 80, .cell_width = 9, .cell_height = 18 };
        }
    };
    S.written = null;
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.size = &S.getSize;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1b[18t");
    defer testing.allocator.free(S.written.?);
    try testing.expectEqualStrings("\x1b[8;24;80t", S.written.?);
}
test "size report csi_19_t with effect" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
        fn getSize(_: *Handler) ?size_report.Size {
            return .{ .rows = 24, .columns = 80, .cell_width = 9, .cell_height = 18 };
        }
    };
    S.written = null;
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.size = &S.getSize;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1b[19t");
    defer testing.allocator.free(S.written.?);
    try testing.expectEqualStrings("\x1b[9;24;80t", S.written.?);
}
test "size report no effect callback" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1b[14t");
    try testing.expect(S.written == null);
}
test "size report csi_21_t title disabled by default" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1b]2;My Title\x1b\\");
    s.nextSlice("\x1b[21t");
    try testing.expect(S.written == null);
}
test "size report csi_21_t title enabled" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.title_report = true;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1b]2;My Title\x1b\\");
    s.nextSlice("\x1b[21t");
    defer testing.allocator.free(S.written.?);
    try testing.expectEqualStrings("\x1b]lMy Title\x1b\\", S.written.?);
}
test "DECRQCRA disabled" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("hello\x1b[1;1;1;1;1;5*y");
    try testing.expect(S.written == null);
}
test "DECRQCRA enabled" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    defer if (S.written) |v| testing.allocator.free(v);
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.xt_checksum_report = true;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("hello\x1b[3;1;1;1;1;5*y");
    try testing.expectEqualStrings("\x1bP3!~FDEC\x1b\\", S.written.?);
    s.nextSlice("\x1b[1#y\x1b[4;1;1;1;1;5*y");
    try testing.expectEqualStrings("\x1bP4!~0214\x1b\\", S.written.?);
    s.nextSlice("\x1bchello\x1b[5;1;1;1;1;5*y");
    try testing.expectEqualStrings("\x1bP5!~FDEC\x1b\\", S.written.?);
}
test "XTCHECKSUM ignored without xt checksum report" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const handler: Handler = .init(&t);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1b[1#y");
    try testing.expectEqual(xt_checksum.Flags{}, t.flags.xt_checksum);
}
test "enquiry no effect" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x05");
    try testing.expect(S.written == null);
}
test "enquiry with effect" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
        fn enquiry(_: *Handler) []const u8 {
            return "wasp";
        }
    };
    S.written = null;
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.enquiry = &S.enquiry;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x05");
    defer testing.allocator.free(S.written.?);
    try testing.expectEqualStrings("wasp", S.written.?);
}
test "enquiry with empty response" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
        fn enquiry(_: *Handler) []const u8 {
            return "";
        }
    };
    S.written = null;
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.enquiry = &S.enquiry;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x05");
    try testing.expect(S.written == null);
}
test "device status: operating status" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B[5n");
    try testing.expectEqualStrings("\x1B[0n", S.written.?);
}
test "device status: cursor position" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B[6n");
    try testing.expectEqualStrings("\x1B[1;1R", S.written.?);
    s.nextSlice("\x1B[5;10H");
    s.nextSlice("\x1B[6n");
    try testing.expectEqualStrings("\x1B[5;10R", S.written.?);
}
test "device status: cursor position with origin mode" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B[5;20r");
    s.nextSlice("\x1B[?6h");
    s.nextSlice("\x1B[3;5H");
    s.nextSlice("\x1B[6n");
    try testing.expectEqualStrings("\x1B[3;5R", S.written.?);
}
test "device status: extended cursor position" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B[5;3H");
    s.nextSlice("\x1B[?6n");
    try testing.expectEqualStrings("\x1B[?5;3;1R", S.written.?);
}
test "device status: extended cursor position with origin mode" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B[5;20r");
    s.nextSlice("\x1B[?6h");
    s.nextSlice("\x1B[3;5H");
    s.nextSlice("\x1B[?6n");
    try testing.expectEqualStrings("\x1B[?3;5;1R", S.written.?);
}
test "device status: color scheme dark" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
        fn colorScheme(_: *Handler) ?device_status.ColorScheme {
            return .dark;
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.color_scheme = &S.colorScheme;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B[?996n");
    try testing.expectEqualStrings("\x1B[?997;1n", S.written.?);
}
test "device status: color scheme light" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
        fn colorScheme(_: *Handler) ?device_status.ColorScheme {
            return .light;
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.color_scheme = &S.colorScheme;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B[?996n");
    try testing.expectEqualStrings("\x1B[?997;2n", S.written.?);
}
test "device status: color scheme without callback" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B[?996n");
    try testing.expect(S.written == null);
}
test "visibility reports" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        var count: usize = 0;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
            count += 1;
        }
    };
    S.written = null;
    S.count = 0;
    defer if (S.written) |old| testing.allocator.free(old);
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B[?2033$p");
    try testing.expectEqualStrings("\x1B[?2033;2$y", S.written.?);
    s.nextSlice("\x1B[?998n");
    try testing.expectEqualStrings("\x1B[?999;1n", S.written.?);
    try testing.expect(!t.modes.get(.report_visibility));
    t.flags.visible = false;
    s.nextSlice("\x1B[?2033h");
    try testing.expectEqualStrings("\x1B[?999;2n", S.written.?);
    const count = S.count;
    s.nextSlice("\x1B[?2033h");
    try testing.expectEqual(count + 1, S.count);
    s.nextSlice("\x1B[?2033l");
    try testing.expectEqual(count + 1, S.count);
    s.nextSlice("\x1Bc");
    s.nextSlice("\x1B[?998n");
    try testing.expectEqualStrings("\x1B[?999;2n", S.written.?);
}
test "device status: readonly ignores all" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1B[5n");
    s.nextSlice("\x1B[6n");
    s.nextSlice("\x1B[?996n");
    s.nextSlice("\x1B[?998n");
    s.nextSlice("Test");
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Test", str);
}
test "device attributes: primary DA" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
        fn da(_: *Handler) device_attributes.Attributes {
            return .{};
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.device_attributes = &S.da;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B[c");
    try testing.expectEqualStrings("\x1b[?62;22c", S.written.?);
}
test "device attributes: secondary DA" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
        fn da(_: *Handler) device_attributes.Attributes {
            return .{};
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.device_attributes = &S.da;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B[>c");
    try testing.expectEqualStrings("\x1b[>1;0;0c", S.written.?);
}
test "device attributes: tertiary DA" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
        fn da(_: *Handler) device_attributes.Attributes {
            return .{};
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.device_attributes = &S.da;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B[=c");
    try testing.expectEqualStrings("\x1bP!|00000000\x1b\\", S.written.?);
}
test "device attributes: readonly ignores" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1B[c");
    s.nextSlice("\x1B[>c");
    s.nextSlice("\x1B[=c");
    s.nextSlice("Test");
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Test", str);
}
test "device attributes: custom response" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
        fn da(_: *Handler) device_attributes.Attributes {
            return .{
                .primary = .{
                    .conformance_level = .vt420,
                    .features = &.{ .ansi_color, .clipboard },
                },
                .secondary = .{
                    .device_type = .vt420,
                    .firmware_version = 100,
                },
            };
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.device_attributes = &S.da;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B[c");
    try testing.expectEqualStrings("\x1b[?64;22;52c", S.written.?);
    s.nextSlice("\x1B[>c");
    try testing.expectEqualStrings("\x1b[>41;100;0c", S.written.?);
}
test "kitty graphics APC response" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2,c=10,r=1;////////\x1b\\");
    try testing.expectEqualStrings("\x1b_Gi=1;OK\x1b\\", S.written.?);
}
test "kitty graphics via APC" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    const handler: Handler = .init(&t);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2,c=10,r=1;////////\x1b\\");
    const storage = &t.screens.active.kitty_images;
    const img = storage.imageById(1).?;
    try testing.expectEqual(.rgb, img.format);
}
test "continuation reconstructs standard stream without duplicate effects" {
    const S = struct {
        var bell_count: usize = 0;
        var title_count: usize = 0;
        var write_count: usize = 0;
        var notification_count: usize = 0;
        var clipboard_count: usize = 0;
        fn bell(_: *Handler) void {
            bell_count += 1;
        }
        fn titleChanged(_: *Handler) void {
            title_count += 1;
        }
        fn writePty(_: *Handler, _: []const u8) void {
            write_count += 1;
        }
        fn desktopNotification(
            _: *Handler,
            _: Action.ShowDesktopNotification,
        ) void {
            notification_count += 1;
        }
        fn clipboardWrite(
            _: *Handler,
            write: clipboard.Write,
        ) void {
            clipboard_count += 1;
            write.reply(.{ .success = .{} });
        }
        fn reset() void {
            bell_count = 0;
            title_count = 0;
            write_count = 0;
            notification_count = 0;
            clipboard_count = 0;
        }
    };
    S.reset();
    const committed = "A\n\x07" ++
        "\x1b]2;title\x1b\\" ++
        "\x1b[5n" ++
        "\x1b]9;body\x1b\\" ++
        "\x1b]52;c;aA==\x1b\\";
    var source_terminal: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 80, .rows = 24 },
    );
    defer source_terminal.deinit(testing.allocator);
    var source_handler: Handler = .init(&source_terminal);
    source_handler.effects.bell = &S.bell;
    source_handler.effects.title_changed = &S.titleChanged;
    source_handler.effects.write_pty = &S.writePty;
    source_handler.effects.desktop_notification = &S.desktopNotification;
    source_handler.effects.clipboard_write = &S.clipboardWrite;
    var source = Stream.init(.{
        .allocator = testing.allocator,
        .handler = source_handler,
        .continuation_max_bytes = 1024,
    });
    defer source.deinit();
    source.nextSlice(committed ++ "\x1b[31");
    try testing.expectEqual(@as(usize, 1), S.bell_count);
    try testing.expectEqual(@as(usize, 1), S.title_count);
    try testing.expectEqual(@as(usize, 1), S.write_count);
    try testing.expectEqual(@as(usize, 1), S.notification_count);
    try testing.expectEqual(@as(usize, 1), S.clipboard_count);
    var continuation_buf: [1024]u8 = undefined;
    var continuation_writer: std.Io.Writer = .fixed(&continuation_buf);
    try source.writeContinuation(&continuation_writer);
    try testing.expectEqualStrings("\x1b[31", continuation_writer.buffered());
    var restored_terminal: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 80, .rows = 24 },
    );
    defer restored_terminal.deinit(testing.allocator);
    {
        var snapshot_stream: Stream = .init(.{
            .allocator = testing.allocator,
            .handler = .init(&restored_terminal),
        });
        defer snapshot_stream.deinit();
        snapshot_stream.nextSlice(committed);
    }
    const before = try restored_terminal.plainString(testing.allocator);
    defer testing.allocator.free(before);
    const before_x = restored_terminal.screens.active.cursor.x;
    const before_y = restored_terminal.screens.active.cursor.y;
    const before_style = restored_terminal.screens.active.cursor.style_id;
    const before_title = restored_terminal.getTitle().?;
    var restored_handler: Handler = .init(&restored_terminal);
    restored_handler.effects.bell = &S.bell;
    restored_handler.effects.title_changed = &S.titleChanged;
    restored_handler.effects.write_pty = &S.writePty;
    restored_handler.effects.desktop_notification = &S.desktopNotification;
    restored_handler.effects.clipboard_write = &S.clipboardWrite;
    var restored = Stream.init(.{
        .allocator = testing.allocator,
        .handler = restored_handler,
        .continuation_max_bytes = 1024,
    });
    defer restored.deinit();
    S.reset();
    restored.nextSlice(continuation_writer.buffered());
    try testing.expectEqual(@as(usize, 0), S.bell_count);
    try testing.expectEqual(@as(usize, 0), S.title_count);
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expectEqual(@as(usize, 0), S.notification_count);
    try testing.expectEqual(@as(usize, 0), S.clipboard_count);
    const after = try restored_terminal.plainString(testing.allocator);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    try testing.expectEqual(before_x, restored_terminal.screens.active.cursor.x);
    try testing.expectEqual(before_y, restored_terminal.screens.active.cursor.y);
    try testing.expectEqual(before_style, restored_terminal.screens.active.cursor.style_id);
    try testing.expectEqualStrings(before_title, restored_terminal.getTitle().?);
    source.nextSlice("mB");
    restored.nextSlice("mB");
    const source_text = try source_terminal.plainString(testing.allocator);
    defer testing.allocator.free(source_text);
    const restored_text = try restored_terminal.plainString(testing.allocator);
    defer testing.allocator.free(restored_text);
    try testing.expectEqualStrings(source_text, restored_text);
    try testing.expectEqual(
        source_terminal.screens.active.cursor.style_id,
        restored_terminal.screens.active.cursor.style_id,
    );
}
test "kitty dnd: query response" {
    const S = struct {
        var pty: std.ArrayListUnmanaged(u8) = .empty;
        fn writePty(_: *Handler, data: []const u8) void {
            pty.appendSlice(testing.allocator, data) catch unreachable;
        }
    };
    S.pty = .empty;
    defer S.pty.deinit(testing.allocator);
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B]72;t=q:i=3\x1B\\");
    try testing.expectEqualStrings("\x1b]72;t=q:i=3\x1b\\", S.pty.items);
}
test "kitty dnd: register, drop, and serve data" {
    const S = struct {
        var pty: std.ArrayListUnmanaged(u8) = .empty;
        fn writePty(_: *Handler, data: []const u8) void {
            pty.appendSlice(testing.allocator, data) catch unreachable;
        }
    };
    S.pty = .empty;
    defer S.pty.deinit(testing.allocator);
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B]72;t=a;text/plain text/uri-list\x1B\\");
    try testing.expectEqualStrings("", S.pty.items);
    try testing.expect(t.kitty_dnd != null);
    {
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try t.kitty_dnd.?.dragDrop(testing.allocator, &aw.writer, .{
            .cell_x = 2,
            .cell_y = 1,
            .pixel_x = 20,
            .pixel_y = 18,
            .operations = .{ .copy = true },
        }, &.{
            .{ .mime = "text/plain", .data = "hello" },
        });
        try testing.expectEqualStrings(
            "\x1b]72;t=M:x=2:y=1:X=20:Y=18:o=1:m=0;text/plain \x1b\\",
            aw.written(),
        );
    }
    s.nextSlice("\x1B]72;t=r:x=1\x1B\\");
    try testing.expectEqualStrings(
        "\x1b]72;t=r:x=1:m=0;aGVsbG8=\x1b\\" ++ "\x1b]72;t=r:x=1\x1b\\",
        S.pty.items,
    );
    S.pty.clearRetainingCapacity();
    s.nextSlice("\x1B]72;t=r\x1B\\");
    try testing.expectEqualStrings("", S.pty.items);
    try testing.expect(t.kitty_dnd.?.drop.items == null);
}
test "kitty dnd: state updates work without write_pty effect" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1B]72;t=q\x1B\\");
    s.nextSlice("\x1B]72;t=a\x1B\\");
    try testing.expect(t.kitty_dnd != null);
    s.nextSlice("ok");
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("ok", str);
}
test "kitty dnd: registration survives terminal reset" {
    const S = struct {
        var pty: std.ArrayListUnmanaged(u8) = .empty;
        fn writePty(_: *Handler, data: []const u8) void {
            pty.appendSlice(testing.allocator, data) catch unreachable;
        }
    };
    S.pty = .empty;
    defer S.pty.deinit(testing.allocator);
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B]72;t=a:i=5\x1B\\");
    s.nextSlice("\x1B]72;t=m:o=1:m=1;text/pl\x1B\\");
    s.nextSlice("\x1Bc");
    try testing.expect(t.kitty_dnd != null);
    try testing.expect(!t.kitty_dnd.?.chunking.active);
    s.nextSlice("\x1B]72;t=q\x1B\\");
    try testing.expectEqualStrings("\x1b]72;t=q\x1b\\", S.pty.items);
}
test "kitty dnd: effect reports registration, acceptance, and conclusion" {
    const S = struct {
        var events: std.ArrayListUnmanaged(kitty_dnd.Event) = .empty;
        var mimes: std.ArrayListUnmanaged(u8) = .empty;
        fn clear() void {
            events.deinit(testing.allocator);
            events = .empty;
            mimes.deinit(testing.allocator);
            mimes = .empty;
        }
        fn dragAndDrop(handler: *Handler, ev: kitty_dnd.Event) void {
            events.append(testing.allocator, ev) catch unreachable;
            if (ev == .registration) {
                mimes.clearRetainingCapacity();
                const state = handler.terminal.kitty_dnd orelse return;
                var it = state.registeredMimes();
                while (it.next()) |m| {
                    mimes.appendSlice(testing.allocator, m) catch unreachable;
                    mimes.append(testing.allocator, ',') catch unreachable;
                }
            }
        }
    };
    S.clear();
    defer S.clear();
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    var handler: Handler = .init(&t);
    handler.effects.drag_and_drop = &S.dragAndDrop;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B]72;t=a;image/png text/plain\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.events.items.len);
    try testing.expect(S.events.items[0] == .registration);
    try testing.expectEqualStrings("image/png,text/plain,", S.mimes.items);
    {
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try t.kitty_dnd.?.dragDrop(testing.allocator, &aw.writer, .{
            .cell_x = 0,
            .cell_y = 0,
            .pixel_x = 0,
            .pixel_y = 0,
            .operations = .{ .copy = true },
        }, &.{.{ .mime = "text/plain", .data = "x" }});
    }
    s.nextSlice("\x1B]72;t=m:o=2;text/plain\x1B\\");
    try testing.expectEqual(@as(usize, 2), S.events.items.len);
    try testing.expect(S.events.items[1] == .acceptance);
    s.nextSlice("\x1B]72;t=r:o=2\x1B\\");
    try testing.expectEqual(@as(usize, 3), S.events.items.len);
    try testing.expectEqual(kitty_dnd.Event.concluded_move, S.events.items[2]);
    s.nextSlice("\x1B]72;t=A\x1B\\");
    try testing.expectEqual(@as(usize, 4), S.events.items.len);
    try testing.expect(S.events.items[3] == .registration);
    try testing.expect(t.kitty_dnd == null);
    try testing.expectEqualStrings("", S.mimes.items);
}
const PasteCapture = struct {
    var written: std.ArrayList(u8) = .empty;
    var write_count: usize = 0;
    var read_count: usize = 0;
    var read_granted_count: usize = 0;
    var last_read_granted: bool = false;
    var last_read_name: [64]u8 = undefined;
    var last_read_name_len: usize = 0;
    fn reset() void {
        written.clearRetainingCapacity();
        write_count = 0;
        read_count = 0;
        read_granted_count = 0;
        last_read_granted = false;
        last_read_name_len = 0;
    }
    fn deinit() void {
        written.deinit(testing.allocator);
        written = .empty;
    }
    fn writePty(_: *Handler, data: []const u8) void {
        written.appendSlice(testing.allocator, data) catch @panic("OOM");
        write_count += 1;
    }
    fn clipboardRead(_: *Handler, read: clipboard.Read) void {
        read_count += 1;
        last_read_granted = read.granted;
        if (read.granted) read_granted_count += 1;
        last_read_name_len = read.name.len;
        @memcpy(last_read_name[0..read.name.len], read.name);
        read.reply(.{ .success = .{ .contents = &.{.{
            .mime = "text/plain",
            .data = "Wasp",
        }} } });
    }
    fn readName() []const u8 {
        return last_read_name[0..last_read_name_len];
    }
};
test "paste: no write_pty effect is an error" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    var handler: Handler = .init(&t);
    defer handler.deinit();
    try testing.expectError(error.NoWritePty, handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "hello" }} },
    }));
}
test "paste: plain text converts newlines and strips unsafe bytes" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = PasteCapture;
    S.reset();
    defer S.deinit();
    var handler: Handler = .init(&t);
    defer handler.deinit();
    handler.effects.write_pty = &S.writePty;
    try testing.expect(try handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "hel\x1blo\nwor\x00ld" }} },
        .allow_unsafe = true,
    }));
    try testing.expectEqualStrings("hel lo\rwor ld", S.written.items);
    try testing.expectEqual(@as(usize, 1), S.write_count);
    S.reset();
    try testing.expect(try handler.paste(.{
        .contents = .{ .memory = &.{
            .{ .mime = "image/png", .data = "\x89PNG" },
            .{ .mime = "UTF8_STRING", .data = "hi" },
            .{ .mime = "text/plain", .data = "ignored" },
        } },
    }));
    try testing.expectEqualStrings("hi", S.written.items);
    try testing.expectEqual(@as(usize, 1), S.write_count);
}
test "paste: unsafe text is refused unless allowed" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = PasteCapture;
    S.reset();
    defer S.deinit();
    var handler: Handler = .init(&t);
    defer handler.deinit();
    handler.effects.write_pty = &S.writePty;
    try testing.expectError(error.UnsafePaste, handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "rm -rf /\n" }} },
    }));
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expect(try handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "rm -rf /\n" }} },
        .allow_unsafe = true,
    }));
    try testing.expectEqualStrings("rm -rf /\r", S.written.items);
    S.reset();
    try testing.expectError(error.UnsafePaste, handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "rm -rf /\r" }} },
    }));
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expect(try handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "rm -rf /\r" }} },
        .allow_unsafe = true,
    }));
    try testing.expectEqualStrings("rm -rf /\r", S.written.items);
}
test "paste: bracketed paste frames the text" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = PasteCapture;
    S.reset();
    defer S.deinit();
    var handler: Handler = .init(&t);
    defer handler.deinit();
    handler.effects.write_pty = &S.writePty;
    t.modes.set(.bracketed_paste, true);
    try testing.expect(try handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "hello\nworld" }} },
    }));
    try testing.expectEqualStrings("\x1b[200~hello\nworld\x1b[201~", S.written.items);
    try testing.expectEqual(@as(usize, 1), S.write_count);
    S.reset();
    try testing.expect(try handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "hello\r\nworld" }} },
    }));
    try testing.expectEqualStrings("\x1b[200~hello\r\nworld\x1b[201~", S.written.items);
    S.reset();
    try testing.expectError(error.UnsafePaste, handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "he\x1b[201~llo" }} },
    }));
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expect(try handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "he\x1b[201~llo" }} },
        .allow_unsafe = true,
    }));
    try testing.expectEqualStrings("\x1b[200~he [201~llo\x1b[201~", S.written.items);
}
test "paste: no text representation writes nothing" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = PasteCapture;
    S.reset();
    defer S.deinit();
    var handler: Handler = .init(&t);
    defer handler.deinit();
    handler.effects.write_pty = &S.writePty;
    try testing.expect(!try handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "image/png", .data = "\x89PNG" }} },
    }));
    try testing.expect(!try handler.paste(.{
        .contents = .{ .memory = &.{} },
    }));
    try testing.expect(!try handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "" }} },
    }));
    try testing.expectEqual(@as(usize, 0), S.write_count);
}
test "paste: large text streams to the pty in chunks" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = PasteCapture;
    S.reset();
    defer S.deinit();
    var handler: Handler = .init(&t);
    defer handler.deinit();
    handler.effects.write_pty = &S.writePty;
    t.modes.set(.bracketed_paste, true);
    const data = "x" ** 10_000;
    try testing.expect(try handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = data }} },
    }));
    const total = data.len + "\x1b[200~\x1b[201~".len;
    try testing.expectEqual(
        @as(usize, (total + Handler.paste_chunk_size - 1) / Handler.paste_chunk_size),
        S.write_count,
    );
    try testing.expectEqual(total, S.written.items.len);
    try testing.expect(std.mem.startsWith(u8, S.written.items, "\x1b[200~xxx"));
    try testing.expect(std.mem.endsWith(u8, S.written.items, "xxx\x1b[201~"));
}
const PasteReader = struct {
    mimes: []const []const u8,
    data: []const []const u8,
    piece: usize = 3,
    reads: [4]usize = @splat(0),
    fail_after: ?usize = null,
    fn contents(self: *PasteReader) paste_pkg.Contents {
        return .{ .reader = .{
            .mimes = self.mimes,
            .read = .{ .ctx = self, .read_fn = &read },
        } };
    }
    fn read(ctx: ?*anyopaque, mime: []const u8, sink: *std.Io.Writer) clipboard.MimeReader.Error!void {
        const self: *PasteReader = @ptrCast(@alignCast(ctx.?));
        const index: usize = for (self.mimes, 0..) |m, i| {
            if (std.mem.eql(u8, m, mime)) break i;
        } else return error.ReadFailed;
        self.reads[index] += 1;
        const data = self.data[index];
        var offset: usize = 0;
        while (offset < data.len) {
            if (self.fail_after) |limit| if (offset >= limit) return error.ReadFailed;
            const n = @min(self.piece, data.len - offset);
            try sink.writeAll(data[offset..][0..n]);
            offset += n;
        }
    }
};
test "paste: reader contents are read on demand" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = PasteCapture;
    S.reset();
    defer S.deinit();
    var handler: Handler = .init(&t);
    defer handler.deinit();
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;
    var reader: PasteReader = .{
        .mimes = &.{ "image/png", "text/plain" },
        .data = &.{ "\x89PNG", "echo hi\nrm -rf /\n" },
    };
    try testing.expectError(error.UnsafePaste, handler.paste(.{
        .contents = reader.contents(),
    }));
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expectEqual(@as(usize, 0), reader.reads[0]);
    try testing.expectEqual(@as(usize, 1), reader.reads[1]);
    reader.reads = @splat(0);
    try testing.expect(try handler.paste(.{
        .contents = reader.contents(),
        .allow_unsafe = true,
    }));
    try testing.expectEqualStrings("echo hi\rrm -rf /\r", S.written.items);
    try testing.expectEqual(@as(usize, 0), reader.reads[0]);
    try testing.expectEqual(@as(usize, 1), reader.reads[1]);
    S.reset();
    reader = .{
        .mimes = &.{"text/plain"},
        .data = &.{"hello world"},
    };
    try testing.expect(try handler.paste(.{ .contents = reader.contents() }));
    try testing.expectEqualStrings("hello world", S.written.items);
    try testing.expectEqual(@as(usize, 1), reader.reads[0]);
    S.reset();
    reader = .{
        .mimes = &.{"text/plain"},
        .data = &.{""},
    };
    try testing.expect(!try handler.paste(.{ .contents = reader.contents() }));
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expectEqual(@as(usize, 1), reader.reads[0]);
    S.reset();
    t.modes.set(.kitty_paste_events, true);
    reader = .{
        .mimes = &.{ "text/plain", "image/png" },
        .data = &.{ "secret", "\x89PNG" },
    };
    try testing.expect(try handler.paste(.{ .contents = reader.contents() }));
    try testing.expect(std.mem.indexOf(u8, S.written.items, ";dGV4dC9wbGFpbiBpbWFnZS9wbmcK\x1b\\") != null);
    try testing.expect(std.mem.indexOf(u8, S.written.items, "secret") == null);
    try testing.expectEqual(@as(usize, 0), reader.reads[0]);
    try testing.expectEqual(@as(usize, 0), reader.reads[1]);
}
test "paste: reader failure writes nothing" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = PasteCapture;
    S.reset();
    defer S.deinit();
    var handler: Handler = .init(&t);
    defer handler.deinit();
    handler.effects.write_pty = &S.writePty;
    t.modes.set(.bracketed_paste, true);
    var reader: PasteReader = .{
        .mimes = &.{"text/plain"},
        .data = &.{"hello world"},
        .fail_after = 6,
    };
    try testing.expectError(error.ReadFailed, handler.paste(.{
        .contents = reader.contents(),
    }));
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expectError(error.ReadFailed, handler.paste(.{
        .contents = reader.contents(),
        .allow_unsafe = true,
    }));
    try testing.expectEqual(@as(usize, 0), S.write_count);
}
test "paste: mode 5522 sends an event the program can read with" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = PasteCapture;
    S.reset();
    defer S.deinit();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    t.modes.set(.kitty_paste_events, true);
    t.modes.set(.bracketed_paste, true);
    try testing.expect(try s.handler.paste(.{
        .contents = .{ .memory = &.{
            .{ .mime = "text/plain", .data = "secret" },
            .{ .mime = "image/png", .data = "" },
        } },
    }));
    try testing.expectEqual(@as(usize, 1), S.write_count);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, S.written.items, "\x1b]5522;"));
    try testing.expect(std.mem.indexOf(u8, S.written.items, "secret") == null);
    try testing.expect(std.mem.indexOf(u8, S.written.items, "\x1b[200~") == null);
    const ok_prefix = "\x1b]5522;type=read:status=OK:pw=";
    try testing.expect(std.mem.startsWith(u8, S.written.items, ok_prefix));
    const pw_end = std.mem.indexOfPos(u8, S.written.items, ok_prefix.len, "\x1b\\").?;
    var pw_buf: [64]u8 = undefined;
    const pw_b64 = pw_buf[0 .. pw_end - ok_prefix.len];
    @memcpy(pw_b64, S.written.items[ok_prefix.len..pw_end]);
    try testing.expectEqual(
        std.base64.standard.Encoder.calcSize(kitty_clipboard.otp_len),
        pw_b64.len,
    );
    var expected_buf: [256]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        "\x1b]5522;type=read:status=OK:pw={s}\x1b\\" ++
            "\x1b]5522;type=read:status=DATA:mime=Lg==:pw={s};dGV4dC9wbGFpbiBpbWFnZS9wbmcK\x1b\\" ++
            "\x1b]5522;type=read:status=DONE:pw={s}\x1b\\",
        .{ pw_b64, pw_b64, pw_b64 },
    );
    try testing.expectEqualStrings(expected, S.written.items);
    var read_buf: [256]u8 = undefined;
    const read = try std.fmt.bufPrint(
        &read_buf,
        "\x1b]5522;type=read:pw={s}:name=UGFzdGUgZXZlbnQ=;dGV4dC9wbGFpbg==\x1b\\",
        .{pw_b64},
    );
    S.reset();
    s.nextSlice(read);
    try testing.expectEqual(@as(usize, 1), S.read_count);
    try testing.expect(S.last_read_granted);
    try testing.expectEqualStrings("Paste event", S.readName());
    try testing.expectEqualStrings(
        "\x1b]5522;type=read:status=OK\x1b\\" ++
            "\x1b]5522;type=read:status=DATA:mime=dGV4dC9wbGFpbg==;R2hvc3R0eQ==\x1b\\" ++
            "\x1b]5522;type=read:status=DONE\x1b\\",
        S.written.items,
    );
    S.reset();
    s.nextSlice(read);
    try testing.expectEqual(@as(usize, 1), S.read_count);
    try testing.expect(!S.last_read_granted);
    try testing.expectEqual(@as(usize, 0), S.read_granted_count);
    S.reset();
    try testing.expect(try s.handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "secret" }} },
    }));
    try testing.expect(std.mem.indexOf(u8, S.written.items, pw_b64) == null);
}
test "paste: mode 5522 reports the selection as primary" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = PasteCapture;
    S.reset();
    defer S.deinit();
    var handler: Handler = .init(&t);
    defer handler.deinit();
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;
    t.modes.set(.kitty_paste_events, true);
    for ([_]clipboard.Location{ .primary, .selection }) |location| {
        S.reset();
        try testing.expect(try handler.paste(.{
            .source = .{ .clipboard = location },
            .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "x" }} },
        }));
        try testing.expect(std.mem.startsWith(
            u8,
            S.written.items,
            "\x1b]5522;type=read:status=OK:loc=primary:pw=",
        ));
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, S.written.items, "loc=primary"));
    }
    S.reset();
    try testing.expect(try handler.paste(.{
        .source = .{ .clipboard = .standard },
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "x" }} },
    }));
    try testing.expect(std.mem.indexOf(u8, S.written.items, "loc=") == null);
}
test "paste: mode 5522 without clipboard_read pastes text" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = PasteCapture;
    S.reset();
    defer S.deinit();
    var handler: Handler = .init(&t);
    defer handler.deinit();
    handler.effects.write_pty = &S.writePty;
    t.modes.set(.kitty_paste_events, true);
    try testing.expect(try handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "hello" }} },
    }));
    try testing.expectEqualStrings("hello", S.written.items);
    try testing.expectEqual(@as(usize, 0), handler.kitty_clipboard_grants.entries.items.len);
}
test "paste: text source never becomes an event" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = PasteCapture;
    S.reset();
    defer S.deinit();
    var handler: Handler = .init(&t);
    defer handler.deinit();
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;
    t.modes.set(.kitty_paste_events, true);
    try testing.expect(try handler.paste(.{
        .source = .text,
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "committed" }} },
    }));
    try testing.expectEqualStrings("committed", S.written.items);
    try testing.expectEqual(@as(usize, 0), handler.kitty_clipboard_grants.entries.items.len);
}
test "paste: mode 5522 without entropy fails and records no grant" {
    var t: Terminal = try .init(std.Io.failing, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = PasteCapture;
    S.reset();
    defer S.deinit();
    var handler: Handler = .init(&t);
    defer handler.deinit();
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;
    t.modes.set(.kitty_paste_events, true);
    try testing.expectError(error.EntropyUnavailable, handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "secret" }} },
    }));
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expectEqual(@as(usize, 0), handler.kitty_clipboard_grants.entries.items.len);
    try testing.expect(try handler.paste(.{
        .source = .text,
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "hello" }} },
    }));
    try testing.expectEqualStrings("hello", S.written.items);
}
test "paste: mode 5522 DECRQM requires clipboard read effect" {
    if (comptime build_options.artifact != .lib) return error.SkipZigTest;
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = PasteCapture;
    S.reset();
    defer S.deinit();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    s.nextSlice("\x1B[?5522$p");
    try testing.expectEqualStrings("\x1B[?5522;0$y", S.written.items);
    S.reset();
    s.nextSlice("\x1B[?5522h");
    try testing.expect(t.modes.get(.kitty_paste_events));
    s.nextSlice("\x1B[?5522$p");
    try testing.expectEqualStrings("\x1B[?5522;0$y", S.written.items);
    S.reset();
    s.handler.effects.clipboard_read = &S.clipboardRead;
    s.nextSlice("\x1B[?5522$p");
    try testing.expectEqualStrings("\x1B[?5522;1$y", S.written.items);
    S.reset();
    s.nextSlice("\x1B[?5522l");
    try testing.expect(!t.modes.get(.kitty_paste_events));
    s.nextSlice("\x1B[?5522$p");
    try testing.expectEqualStrings("\x1B[?5522;2$y", S.written.items);
    S.reset();
    s.handler.effects.clipboard_read = null;
    s.nextSlice("\x1B[?5522$p");
    try testing.expectEqualStrings("\x1B[?5522;0$y", S.written.items);
}
test "full reset drops kitty clipboard grants" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    const S = PasteCapture;
    S.reset();
    defer S.deinit();
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    try s.handler.kitty_clipboard_grants.grant(testing.allocator, "pw", .read, false);
    try testing.expectEqual(@as(usize, 1), s.handler.kitty_clipboard_grants.entries.items.len);
    s.nextSlice("\x1Bc");
    try testing.expectEqual(@as(usize, 0), s.handler.kitty_clipboard_grants.entries.items.len);
    S.reset();
    s.nextSlice("\x1b]5522;type=read:pw=cHc=:name=YXBw;dGV4dC9wbGFpbg==\x1b\\");
    try testing.expectEqual(@as(usize, 1), S.read_count);
    try testing.expect(!S.last_read_granted);
    try s.handler.kitty_clipboard_grants.grant(testing.allocator, "pw", .read, false);
}
