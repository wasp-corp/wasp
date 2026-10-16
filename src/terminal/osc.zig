const osc = @This();
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("terminal_options");
const mem = std.mem;
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = mem.Allocator;
const lib = @import("lib.zig");
const LibEnum = lib.Enum;
const kitty_color = @import("kitty/color.zig");
const parsers = @import("osc/parsers.zig");
const encoding = @import("osc/encoding.zig");
pub const color = parsers.color;
pub const semantic_prompt = parsers.semantic_prompt;
pub const program_status = parsers.program_status;
pub const hierarchical_context = parsers.hierarchical_context;
const log = std.log.scoped(.osc);
pub const Command = union(Key) {
    invalid,
    change_window_title: [:0]const u8,
    change_window_icon: [:0]const u8,
    semantic_prompt: SemanticPrompt,
    clipboard_contents: struct {
        kind: u8,
        data: [:0]const u8,
        terminator: Terminator = .st,
    },
    report_pwd: struct {
        value: [:0]const u8,
    },
    mouse_shape: struct {
        value: [:0]const u8,
    },
    color_operation: struct {
        op: color.Operation,
        requests: color.List = .{},
        terminator: Terminator = .st,
    },
    kitty_color_protocol: kitty_color.OSC,
    show_desktop_notification: struct {
        title: [:0]const u8,
        body: [:0]const u8,
    },
    hyperlink_start: struct {
        id: ?[:0]const u8 = null,
        uri: [:0]const u8,
    },
    hyperlink_end: void,
    conemu_sleep: struct {
        duration_ms: u16,
    },
    conemu_show_message_box: [:0]const u8,
    conemu_change_tab_title: union(enum) {
        reset,
        value: [:0]const u8,
    },
    conemu_progress_report: ProgressReport,
    conemu_wait_input,
    conemu_guimacro: [:0]const u8,
    conemu_run_process: [:0]const u8,
    conemu_output_environment_variable: [:0]const u8,
    conemu_xterm_emulation: struct {
        keyboard: ?bool,
        output: ?bool,
    },
    conemu_comment: [:0]const u8,
    kitty_text_sizing: parsers.kitty_text_sizing.OSC,
    kitty_clipboard_protocol: KittyClipboardProtocol,
    kitty_dnd_protocol: KittyDndProtocol,
    hierarchical_context: parsers.hierarchical_context.Command,
    kitty_desktop_notification: KittyDesktopNotification,
    unknown: Unknown,
    program_status: ProgramStatus,
    pub const SemanticPrompt = parsers.semantic_prompt.Command;
    pub const HierarchicalContext = parsers.hierarchical_context.Command;
    pub const KittyClipboardProtocol = parsers.kitty_clipboard_protocol.OSC;
    pub const KittyDndProtocol = parsers.kitty_dnd_protocol.OSC;
    pub const KittyDesktopNotification = parsers.kitty_desktop_notification.OSC;
    pub const ProgramStatus = parsers.program_status.Command;
    pub const Key = LibEnum(
        lib.target,
        &.{
            "invalid",
            "change_window_title",
            "change_window_icon",
            "semantic_prompt",
            "clipboard_contents",
            "report_pwd",
            "mouse_shape",
            "color_operation",
            "kitty_color_protocol",
            "show_desktop_notification",
            "hyperlink_start",
            "hyperlink_end",
            "conemu_sleep",
            "conemu_show_message_box",
            "conemu_change_tab_title",
            "conemu_progress_report",
            "conemu_wait_input",
            "conemu_guimacro",
            "conemu_run_process",
            "conemu_output_environment_variable",
            "conemu_xterm_emulation",
            "conemu_comment",
            "kitty_text_sizing",
            "kitty_clipboard_protocol",
            "kitty_dnd_protocol",
            "hierarchical_context",
            "kitty_desktop_notification",
            "unknown",
            "program_status",
        },
    );
    pub const Unknown = struct {
        content: []const u8,
        truncated: bool,
        terminator: Terminator,
        pub const C = extern struct {
            truncated: bool,
            content: lib.String,
            terminator: Terminator.C,
        };
        pub fn cval(self: Unknown) Unknown.C {
            return .{
                .truncated = self.truncated,
                .content = .init(self.content),
                .terminator = self.terminator.cval(),
            };
        }
    };
    pub const ProgressReport = struct {
        const state_keys = &.{
            "remove",
            "set",
            "error",
            "indeterminate",
            "pause",
        };
        pub const State = LibEnum(lib.target, state_keys);
        state: State,
        progress: ?u8 = null,
        pub const C = extern struct {
            state: c_int,
            progress: i8,
        };
        pub fn cval(self: ProgressReport) C {
            return .{
                .state = @intFromEnum(self.state),
                .progress = if (self.progress) |progress| @intCast(std.math.clamp(
                    progress,
                    0,
                    100,
                )) else -1,
            };
        }
        test "wasp.h Command.ProgressReport.State" {
            if (comptime build_options.artifact == .lib) return error.SkipZigTest;
            const CState = LibEnum(.c, state_keys);
            try lib.checkWaspHEnum(CState, "WASP_PROGRESS_STATE_");
        }
    };
    comptime {
        assert(@sizeOf(Command) == switch (@sizeOf(usize)) {
            4 => 44,
            8 => 64,
            else => unreachable,
        });
    }
};
pub const Terminator = enum {
    st,
    bel,
    pub const C = LibEnum(.c, &.{ "st", "bel" });
    pub fn init(ch: ?u8) Terminator {
        return switch (ch orelse return .st) {
            0x07 => .bel,
            else => .st,
        };
    }
    pub fn string(self: Terminator) []const u8 {
        return switch (self) {
            .st => "\x1b\\",
            .bel => "\x07",
        };
    }
    pub fn cval(self: Terminator) C {
        return switch (self) {
            .st => .st,
            .bel => .bel,
        };
    }
    pub fn format(
        self: Terminator,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: *std.Io.Writer,
    ) !void {
        try writer.writeAll(self.string());
    }
};
pub const Parser = struct {
    pub const MAX_BUF = 2048;
    pub const MAX_ALLOCATING_BUF = 8 * 1024 * 1024;
    alloc: ?Allocator,
    max_allocating_bytes: usize,
    unknown_max_bytes: usize,
    state: State,
    buffer: [MAX_BUF]u8,
    capture: ?Capture,
    command: Command,
    pub const State = enum {
        start,
        invalid,
        unknown,
        unknown_truncated,
        @"0",
        @"1",
        @"2",
        @"3",
        @"4",
        @"5",
        @"6",
        @"7",
        @"8",
        @"9",
        @"30",
        @"300",
        @"3008",
        @"10",
        @"11",
        @"12",
        @"13",
        @"14",
        @"15",
        @"16",
        @"17",
        @"18",
        @"19",
        @"21",
        @"22",
        @"52",
        @"55",
        @"66",
        @"72",
        @"75",
        @"750",
        @"7501",
        @"77",
        @"99",
        @"104",
        @"105",
        @"110",
        @"111",
        @"112",
        @"113",
        @"114",
        @"115",
        @"116",
        @"117",
        @"118",
        @"119",
        @"133",
        @"552",
        @"777",
        @"1337",
        @"5522",
    };
    pub fn init(alloc: ?Allocator) Parser {
        var result: Parser = .{
            .alloc = alloc,
            .max_allocating_bytes = MAX_ALLOCATING_BUF,
            .unknown_max_bytes = 0,
            .state = .start,
            .capture = null,
            .command = .invalid,
            .buffer = undefined,
        };
        if (std.valgrind.runningOnValgrind() > 0) {
            result.buffer = undefined;
        }
        return result;
    }
    pub fn deinit(self: *Parser) void {
        self.reset();
    }
    pub fn reset(self: *Parser) void {
        if (self.capture) |*cap| cap.deinit();
        switch (self.command) {
            .kitty_color_protocol => |*v| kitty_color_protocol: {
                v.deinit(self.alloc orelse break :kitty_color_protocol);
            },
            .color_operation => |*v| color_operation: {
                v.requests.deinit(self.alloc orelse break :color_operation);
            },
            .change_window_icon,
            .change_window_title,
            .clipboard_contents,
            .conemu_change_tab_title,
            .conemu_comment,
            .conemu_guimacro,
            .conemu_output_environment_variable,
            .conemu_progress_report,
            .conemu_run_process,
            .conemu_show_message_box,
            .conemu_sleep,
            .conemu_wait_input,
            .conemu_xterm_emulation,
            .hyperlink_end,
            .hyperlink_start,
            .invalid,
            .mouse_shape,
            .report_pwd,
            .semantic_prompt,
            .show_desktop_notification,
            .kitty_text_sizing,
            .kitty_clipboard_protocol,
            .kitty_dnd_protocol,
            .kitty_desktop_notification,
            .hierarchical_context,
            .unknown,
            .program_status,
            => {},
        }
        self.state = .start;
        self.capture = null;
        self.command = .invalid;
        if (std.valgrind.runningOnValgrind() > 0) {
            self.buffer = undefined;
        }
    }
    inline fn ensureAllocator(self: *Parser) bool {
        if (self.alloc != null) return true;
        log.warn("An allocator is required to process OSC {t} but none was provided.", .{self.state});
        self.state = .invalid;
        return false;
    }
    const Capture = struct {
        writer: *std.Io.Writer,
        backing: Backing,
        max_bytes: usize,
        const Backing = union(enum) {
            fixed: std.Io.Writer,
            allocating: std.Io.Writer.Allocating,
        };
        const Mode = enum {
            fixed,
            allocating,
        };
        pub inline fn fixed(new: *?Capture, buf: []u8) void {
            new.* = .{
                .backing = .{ .fixed = .fixed(buf) },
                .writer = &new.*.?.backing.fixed,
                .max_bytes = buf.len,
            };
        }
        pub inline fn allocating(
            new: *?Capture,
            alloc: Allocator,
            max_bytes: usize,
        ) error{OutOfMemory}!void {
            new.* = .{
                .backing = .{ .allocating = try std.Io.Writer.Allocating.initCapacity(
                    alloc,
                    @min(MAX_BUF, max_bytes),
                ) },
                .writer = &new.*.?.backing.allocating.writer,
                .max_bytes = max_bytes,
            };
        }
        pub inline fn writeByte(self: *Capture, byte: u8) error{WriteFailed}!void {
            if (self.writer.buffered().len >= self.max_bytes) return error.WriteFailed;
            switch (self.backing) {
                .fixed => {},
                .allocating => |*w| {
                    if (w.writer.end >= w.writer.buffer.len) {
                        const new_capacity = @min(
                            self.max_bytes,
                            @max(w.writer.buffer.len *| 2, 1),
                        );
                        w.writer.buffer = w.allocator.realloc(
                            w.writer.buffer,
                            new_capacity,
                        ) catch return error.WriteFailed;
                    }
                },
            }
            try self.writer.writeByte(byte);
        }
        pub fn writeSlice(
            self: *Capture,
            bytes: []const u8,
        ) error{WriteFailed}!void {
            const avail = self.max_bytes - self.writer.buffered().len;
            const n = @min(bytes.len, avail);
            switch (self.backing) {
                .fixed => {},
                .allocating => |*w| {
                    const needed = w.writer.end + n;
                    if (needed > w.writer.buffer.len) {
                        const new_capacity = @min(
                            self.max_bytes,
                            @max(w.writer.buffer.len *| 2, needed),
                        );
                        w.writer.buffer = w.allocator.realloc(
                            w.writer.buffer,
                            new_capacity,
                        ) catch return error.WriteFailed;
                    }
                },
            }
            try self.writer.writeAll(bytes[0..n]);
            if (n < bytes.len) return error.WriteFailed;
        }
        pub fn deinit(self: *Capture) void {
            switch (self.backing) {
                .fixed => {},
                .allocating => |*w| w.deinit(),
            }
        }
        pub inline fn trailing(self: *Capture) []u8 {
            return self.writer.buffered();
        }
    };
    inline fn captureTrailing(
        self: *Parser,
        comptime mode: Capture.Mode,
    ) void {
        assert(self.capture == null);
        switch (mode) {
            .fixed => Capture.fixed(
                &self.capture,
                &self.buffer,
            ),
            .allocating => {
                const alloc = self.alloc orelse {
                    self.captureTrailing(.fixed);
                    return;
                };
                Capture.allocating(
                    &self.capture,
                    alloc,
                    self.max_allocating_bytes,
                ) catch {
                    self.captureTrailing(.fixed);
                    return;
                };
            },
        }
    }
    noinline fn unknownOrInvalid(self: *Parser, c: ?u8) void {
        const max_bytes = self.unknown_max_bytes;
        if (max_bytes == 0) {
            @branchHint(.likely);
            self.state = .invalid;
            return;
        }
        assert(self.capture == null);
        const prefix: []const u8 = switch (self.state) {
            .start => "",
            .invalid, .unknown, .unknown_truncated => unreachable,
            inline else => |s| @tagName(s),
        };
        self.state = .unknown;
        const alloc = if (max_bytes > MAX_BUF) self.alloc else null;
        if (alloc) |a| {
            Capture.allocating(&self.capture, a, max_bytes) catch
                Capture.fixed(&self.capture, &self.buffer);
        } else {
            Capture.fixed(&self.capture, self.buffer[0..@min(max_bytes, MAX_BUF)]);
        }
        const cap = &self.capture.?;
        cap.writeSlice(prefix) catch return self.captureFailed();
        if (c) |byte| cap.writeByte(byte) catch return self.captureFailed();
    }
    inline fn captureFailed(self: *Parser) void {
        switch (self.state) {
            .unknown => {
                const cap = &self.capture.?;
                cap.max_bytes = cap.trailing().len;
                self.state = .unknown_truncated;
            },
            .unknown_truncated => {},
            else => self.state = .invalid,
        }
    }
    pub fn nextSlice(self: *Parser, input: []const u8) void {
        if (self.state == .invalid) return;
        var offset: usize = 0;
        while (self.capture == null) {
            if (offset >= input.len) return;
            self.next(input[offset]);
            offset += 1;
            if (self.state == .invalid) return;
        }
        const rem = input[offset..];
        if (rem.len == 0) return;
        self.capture.?.writeSlice(rem) catch |err| switch (err) {
            error.WriteFailed => self.captureFailed(),
        };
    }
    pub fn next(self: *Parser, c: u8) void {
        if (self.state == .invalid) return;
        if (self.capture) |*cap| {
            cap.writeByte(c) catch |err| switch (err) {
                error.WriteFailed => self.captureFailed(),
            };
            return;
        }
        switch (self.state) {
            .invalid => unreachable,
            .unknown, .unknown_truncated => unreachable,
            .start => switch (c) {
                '0' => self.state = .@"0",
                '1' => self.state = .@"1",
                '2' => self.state = .@"2",
                '3' => self.state = .@"3",
                '4' => self.state = .@"4",
                '5' => self.state = .@"5",
                '6' => self.state = .@"6",
                '7' => self.state = .@"7",
                '8' => self.state = .@"8",
                '9' => self.state = .@"9",
                else => self.unknownOrInvalid(c),
            },
            .@"3" => switch (c) {
                '0' => self.state = .@"30",
                else => self.unknownOrInvalid(c),
            },
            .@"30" => switch (c) {
                '0' => self.state = .@"300",
                else => self.unknownOrInvalid(c),
            },
            .@"300" => switch (c) {
                '8' => self.state = .@"3008",
                else => self.unknownOrInvalid(c),
            },
            .@"3008" => switch (c) {
                ';' => self.captureTrailing(.fixed),
                else => self.unknownOrInvalid(c),
            },
            .@"1" => switch (c) {
                ';' => self.captureTrailing(.fixed),
                '0' => self.state = .@"10",
                '1' => self.state = .@"11",
                '2' => self.state = .@"12",
                '3' => self.state = .@"13",
                '4' => self.state = .@"14",
                '5' => self.state = .@"15",
                '6' => self.state = .@"16",
                '7' => self.state = .@"17",
                '8' => self.state = .@"18",
                '9' => self.state = .@"19",
                else => self.unknownOrInvalid(c),
            },
            .@"10" => switch (c) {
                ';' => if (self.ensureAllocator()) self.captureTrailing(.fixed),
                '4' => self.state = .@"104",
                '5' => self.state = .@"105",
                else => self.unknownOrInvalid(c),
            },
            .@"11" => switch (c) {
                ';' => if (self.ensureAllocator()) self.captureTrailing(.fixed),
                '0' => self.state = .@"110",
                '1' => self.state = .@"111",
                '2' => self.state = .@"112",
                '3' => self.state = .@"113",
                '4' => self.state = .@"114",
                '5' => self.state = .@"115",
                '6' => self.state = .@"116",
                '7' => self.state = .@"117",
                '8' => self.state = .@"118",
                '9' => self.state = .@"119",
                else => self.unknownOrInvalid(c),
            },
            .@"4",
            .@"12",
            .@"14",
            .@"15",
            .@"16",
            .@"17",
            .@"18",
            .@"19",
            .@"21",
            .@"104",
            .@"105",
            .@"110",
            .@"111",
            .@"112",
            .@"113",
            .@"114",
            .@"115",
            .@"116",
            .@"117",
            .@"118",
            .@"119",
            => switch (c) {
                ';' => if (self.ensureAllocator()) self.captureTrailing(.fixed),
                else => self.unknownOrInvalid(c),
            },
            .@"13" => switch (c) {
                ';' => if (self.ensureAllocator()) self.captureTrailing(.fixed),
                '3' => self.state = .@"133",
                else => self.unknownOrInvalid(c),
            },
            .@"2" => switch (c) {
                ';' => self.captureTrailing(.fixed),
                '1' => self.state = .@"21",
                '2' => self.state = .@"22",
                else => self.unknownOrInvalid(c),
            },
            .@"5" => switch (c) {
                ';' => if (self.ensureAllocator()) self.captureTrailing(.fixed),
                '2' => self.state = .@"52",
                '5' => self.state = .@"55",
                else => self.unknownOrInvalid(c),
            },
            .@"6" => switch (c) {
                '6' => self.state = .@"66",
                else => self.unknownOrInvalid(c),
            },
            .@"52",
            .@"66",
            => switch (c) {
                ';' => self.captureTrailing(.allocating),
                else => self.unknownOrInvalid(c),
            },
            .@"55" => switch (c) {
                '2' => self.state = .@"552",
                else => self.unknownOrInvalid(c),
            },
            .@"7" => switch (c) {
                ';' => self.captureTrailing(.fixed),
                '2' => self.state = .@"72",
                '5' => self.state = .@"75",
                '7' => self.state = .@"77",
                else => self.unknownOrInvalid(c),
            },
            .@"75" => switch (c) {
                '0' => self.state = .@"750",
                else => self.unknownOrInvalid(c),
            },
            .@"750" => switch (c) {
                '1' => self.state = .@"7501",
                else => self.unknownOrInvalid(c),
            },
            .@"7501" => switch (c) {
                ';' => self.captureTrailing(.allocating),
                else => self.unknownOrInvalid(c),
            },
            .@"72" => switch (c) {
                ';' => self.captureTrailing(.allocating),
                else => self.unknownOrInvalid(c),
            },
            .@"77" => switch (c) {
                '7' => self.state = .@"777",
                else => self.unknownOrInvalid(c),
            },
            .@"133",
            => switch (c) {
                ';' => self.captureTrailing(.fixed),
                '7' => self.state = .@"1337",
                else => self.unknownOrInvalid(c),
            },
            .@"552" => switch (c) {
                '2' => self.state = .@"5522",
                else => self.unknownOrInvalid(c),
            },
            .@"1337",
            => switch (c) {
                ';' => self.captureTrailing(.fixed),
                else => self.unknownOrInvalid(c),
            },
            .@"5522",
            => switch (c) {
                ';' => self.captureTrailing(.allocating),
                else => self.unknownOrInvalid(c),
            },
            .@"9",
            => switch (c) {
                ';' => self.captureTrailing(.fixed),
                '9' => self.state = .@"99",
                else => self.unknownOrInvalid(c),
            },
            .@"99",
            => switch (c) {
                ';' => self.captureTrailing(.allocating),
                else => self.unknownOrInvalid(c),
            },
            .@"0",
            .@"22",
            .@"777",
            .@"8",
            => switch (c) {
                ';' => self.captureTrailing(.fixed),
                else => self.unknownOrInvalid(c),
            },
        }
    }
    pub fn end(self: *Parser, terminator_ch: ?u8) ?*Command {
        if (terminator_ch) |ch| switch (ch) {
            std.ascii.control_code.can,
            std.ascii.control_code.sub,
            => return null,
            else => {},
        };
        return switch (self.state) {
            .start => null,
            .invalid => null,
            .unknown,
            .unknown_truncated,
            => parsers.unknown.parse(self, terminator_ch),
            .@"3",
            .@"30",
            .@"300",
            .@"55",
            .@"552",
            .@"6",
            .@"75",
            .@"750",
            .@"77",
            => bridge: {
                self.unknownOrInvalid(null);
                if (self.state == .invalid) break :bridge null;
                break :bridge parsers.unknown.parse(self, terminator_ch);
            },
            .@"0",
            .@"2",
            => parsers.change_window_title.parse(self, terminator_ch),
            .@"1" => parsers.change_window_icon.parse(self, terminator_ch),
            .@"4",
            .@"5",
            .@"10",
            .@"11",
            .@"12",
            .@"13",
            .@"14",
            .@"15",
            .@"16",
            .@"17",
            .@"18",
            .@"19",
            .@"104",
            .@"105",
            .@"110",
            .@"111",
            .@"112",
            .@"113",
            .@"114",
            .@"115",
            .@"116",
            .@"117",
            .@"118",
            .@"119",
            => parsers.color.parse(self, terminator_ch),
            .@"7" => parsers.report_pwd.parse(self, terminator_ch),
            .@"8" => parsers.hyperlink.parse(self, terminator_ch),
            .@"9" => parsers.osc9.parse(self, terminator_ch),
            .@"21" => parsers.kitty_color.parse(self, terminator_ch),
            .@"22" => parsers.mouse_shape.parse(self, terminator_ch),
            .@"52" => parsers.clipboard_operation.parse(self, terminator_ch),
            .@"3008" => parsers.hierarchical_context.parse(self, terminator_ch),
            .@"66" => parsers.kitty_text_sizing.parse(self, terminator_ch),
            .@"72" => parsers.kitty_dnd_protocol.parse(self, terminator_ch),
            .@"99" => parsers.kitty_desktop_notification.parse(self, terminator_ch),
            .@"7501" => parsers.program_status.parse(self, terminator_ch),
            .@"133" => parsers.semantic_prompt.parse(self, terminator_ch),
            .@"777" => parsers.rxvt_extension.parse(self, terminator_ch),
            .@"1337" => parsers.iterm2.parse(self, terminator_ch),
            .@"5522" => parsers.kitty_clipboard_protocol.parse(self, terminator_ch),
        };
    }
};
test {
    _ = parsers;
    _ = encoding;
}
test "Parser end with CAN or SUB cancels the command" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    for ("2;title") |ch| p.next(ch);
    try testing.expect(p.end(std.ascii.control_code.can) == null);
    p.reset();
    for ("52;c;Zm9v") |ch| p.next(ch);
    try testing.expect(p.end(std.ascii.control_code.sub) == null);
    p.reset();
    for ("2;title") |ch| p.next(ch);
    const cmd = p.end(std.ascii.control_code.bel).?.*;
    try testing.expect(cmd == .change_window_title);
    try testing.expectEqualStrings("title", cmd.change_window_title);
}
test "Parser allocating captures have a hard limit" {
    const testing = std.testing;
    const prefixes = [_][]const u8{ "52;", "66;", "72;", "99;", "5522;" };
    const limit = Parser.MAX_BUF + 1;
    for (prefixes) |prefix| {
        var p: Parser = .init(testing.allocator);
        defer p.deinit();
        p.max_allocating_bytes = limit;
        for (prefix) |ch| p.next(ch);
        for (0..limit) |_| p.next('a');
        const cap = &p.capture.?;
        try testing.expectEqual(@as(usize, limit), cap.trailing().len);
        try testing.expectEqual(@as(usize, limit), cap.writer.buffer.len);
        p.next('a');
        try testing.expectEqual(Parser.State.invalid, p.state);
        try testing.expectEqual(@as(usize, limit), cap.trailing().len);
        try testing.expectEqual(@as(usize, limit), cap.writer.buffer.len);
    }
}
test "Parser nextSlice allocating captures have a hard limit" {
    const testing = std.testing;
    const limit = Parser.MAX_BUF + 1;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    p.max_allocating_bytes = limit;
    const data = try testing.allocator.alloc(u8, limit);
    defer testing.allocator.free(data);
    @memset(data, 'a');
    p.nextSlice("52;");
    p.nextSlice(data);
    const cap = &p.capture.?;
    try testing.expect(p.state != .invalid);
    try testing.expectEqual(@as(usize, limit), cap.trailing().len);
    try testing.expectEqual(@as(usize, limit), cap.writer.buffer.len);
    p.nextSlice("a");
    try testing.expectEqual(Parser.State.invalid, p.state);
    try testing.expectEqual(@as(usize, limit), cap.trailing().len);
    try testing.expectEqual(@as(usize, limit), cap.writer.buffer.len);
    try testing.expect(p.end(null) == null);
}
test "Parser nextSlice overflowing slice is truncated at the limit" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    p.max_allocating_bytes = 4;
    p.nextSlice("52;abcdef");
    try testing.expectEqual(Parser.State.invalid, p.state);
    try testing.expect(p.end(null) == null);
    const cap = &p.capture.?;
    try testing.expectEqualStrings("abcd", cap.trailing());
    try testing.expectEqual(@as(usize, 4), cap.writer.buffer.len);
}
test "Parser nextSlice matches per-byte parsing" {
    const testing = std.testing;
    const input = "52;c;aGVsbG8=";
    for (0..input.len + 1) |split| {
        var p: Parser = .init(testing.allocator);
        defer p.deinit();
        p.nextSlice(input[0..split]);
        p.nextSlice(input[split..]);
        const cmd = p.end(null).?.*;
        try testing.expect(cmd == .clipboard_contents);
        try testing.expectEqual(@as(u8, 'c'), cmd.clipboard_contents.kind);
        try testing.expectEqualStrings("aGVsbG8=", cmd.clipboard_contents.data);
    }
}
test "Parser allocating capture limit includes parser-added bytes" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    p.max_allocating_bytes = 4;
    for ("52;abcd") |ch| p.next(ch);
    try testing.expect(p.end(null) == null);
    try testing.expectEqual(Parser.State.invalid, p.state);
    const cap = &p.capture.?;
    try testing.expectEqual(@as(usize, 4), cap.trailing().len);
    try testing.expectEqual(@as(usize, 4), cap.writer.buffer.len);
}
