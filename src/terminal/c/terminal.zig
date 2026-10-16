const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const build_options = @import("terminal_options");
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
pub const ZigTerminal = @import("../Terminal.zig");
const Action = @import("../stream.zig").Action;
const osc = @import("../osc.zig");
const Stream = @import("../stream_terminal.zig").Stream;
const Screen = @import("../Screen.zig");
const ScreenSet = @import("../ScreenSet.zig");
const PageList = @import("../PageList.zig");
const apc = @import("../apc.zig");
const kitty = @import("../kitty/key.zig");
const kitty_gfx_c = @import("kitty_graphics.zig");
const modes = @import("../modes.zig");
const mouse = @import("../mouse.zig");
const point = @import("../point.zig");
const size = @import("../size.zig");
const device_attributes = @import("../device_attributes.zig");
const device_status = @import("../device_status.zig");
const size_report = @import("../size_report.zig");
const cell_c = @import("cell.zig");
const row_c = @import("row.zig");
const grid_ref_c = @import("grid_ref.zig");
const grid_ref_tracked_c = @import("grid_ref_tracked.zig");
const search_c = @import("search.zig");
const selection_c = @import("selection.zig");
const style_c = @import("style.zig");
const color = @import("../color.zig");
const clipboard = @import("../clipboard.zig");
const kitty_clipboard = @import("../kitty/clipboard.zig");
const c_io = @import("io.zig");
const snapshot_core = @import("../snapshot/main.zig");
const terminal_mem = @import("../mem.zig");
const Result = @import("result.zig").Result;
const assert = @import("../../quirks.zig").inlineAssert;
const Handler = @import("../stream_terminal.zig").Handler;
const max_path_bytes = if (builtin.os.tag == .freestanding) 4096 else std.Io.Dir.max_path_bytes;
const log = std.log.scoped(.terminal_c);
pub const default_continuation_max_bytes: usize = 0;
pub const Io = struct {
    impl: lib.StdIo,
    pub const init: Io = .{ .impl = .init };
    pub fn io(self: Io) std.Io {
        return self.impl.io();
    }
};
const TerminalWrapper = struct {
    terminal: *ZigTerminal,
    io: Io,
    tmp_dir_path: ?[]u8 = null,
    terminfo_name_buf: [Handler.max_terminfo_name_bytes]u8,
    stream: Stream,
    effects: Effects = .{},
    tracked_grid_refs: std.AutoArrayHashMapUnmanaged(*grid_ref_tracked_c.TrackedGridRef, void) = .{},
    searches: std.AutoArrayHashMapUnmanaged(*search_c.SearchWrapper, void) = .{},
    fn fromHandler(handler: *Handler) *TerminalWrapper {
        const stream_ptr: *Stream = @fieldParentPtr("handler", handler);
        return @alignCast(@fieldParentPtr("stream", stream_ptr));
    }
};
pub const ClipboardContent = extern struct {
    mime: lib.String,
    data: lib.String,
};
pub const ClipboardWrite = extern struct {
    size: usize,
    location: clipboard.Location,
    contents: ?[*]const ClipboardContent,
    contents_len: usize,
    name: lib.String,
    granted: bool,
    can_remember: bool,
    ctx: *const anyopaque,
    reply: ClipboardWriteReplyFn,
};
pub const ClipboardWriteReply = extern struct {
    size: usize,
    result: clipboard.Write.Status,
    remember: bool,
};
pub const ClipboardWriteReplyFn = *const fn (*const ClipboardWrite, *const ClipboardWriteReply) callconv(lib.calling_conv) void;
pub const ClipboardReadReply = extern struct {
    size: usize,
    result: clipboard.Read.Status,
    contents: ?[*]const ClipboardContent,
    contents_len: usize,
    available: ?[*]const lib.String,
    available_len: usize,
    remember: bool,
};
pub const ClipboardRead = extern struct {
    size: usize,
    location: clipboard.Location,
    mimes: ?[*]const lib.String,
    mimes_len: usize,
    list: bool,
    name: lib.String,
    granted: bool,
    can_remember: bool,
    ctx: *const anyopaque,
    reply: ClipboardReadReplyFn,
};
pub const ClipboardReadReplyFn = *const fn (*const ClipboardRead, *const ClipboardReadReply) callconv(lib.calling_conv) void;
pub const DesktopNotification = extern struct {
    size: usize,
    title: lib.String,
    body: lib.String,
};
pub const ProgressState = osc.Command.ProgressReport.State;
pub const ProgressReport = extern struct {
    size: usize,
    state: ProgressState,
    progress: i8,
};
pub const ProgramStatusState = osc.Command.ProgramStatus.State;
pub const ProgramStatusKind = lib.Enum(lib.target, &.{
    "none",
    "permission",
    "question",
    "auth",
});
pub const ProgramStatus = extern struct {
    size: usize,
    state: ProgramStatusState,
    kind: ProgramStatusKind,
    progress: i8,
    id: lib.String,
    app: lib.String,
    title: lib.String,
    message: lib.String,
};
pub const SemanticPromptKind = Handler.SemanticPrompt.Kind;
pub const SemanticPromptPromptKind = Handler.SemanticPrompt.PromptKind;
pub const SemanticPrompt = extern struct {
    size: usize,
    kind: SemanticPromptKind,
    prompt_kind: SemanticPromptPromptKind,
    has_exit_code: bool,
    exit_code: i32,
    command: lib.String,
    @"error": lib.String,
};
pub const ResizeWindowGrid = extern struct {
    rows: u16,
    columns: u16,
};
pub const ResizeWindow = union(Tag) {
    grid: ResizeWindowGrid,
    pub const Tag = lib.Enum(lib.target, &.{"grid"});
    const c_union = lib.TaggedUnion(
        lib.target,
        @This(),
        .{ .padding = [2]u64 },
    );
    pub const C = c_union.C;
    pub const CValue = c_union.CValue;
    pub const cval = c_union.cval;
};
pub const UnknownStringSequence = extern struct {
    truncated: bool,
    content: lib.String,
};
pub const UnknownOscSequence = osc.Command.Unknown.C;
pub const UnknownSequence = union(Tag) {
    apc: UnknownStringSequence,
    osc: UnknownOscSequence,
    pub const Tag = lib.Enum(lib.target, &.{ "apc", "osc" });
    const c_union = lib.TaggedUnion(
        lib.target,
        @This(),
        .{ .padding = [16]u64 },
    );
    pub const C = c_union.C;
    pub const CValue = c_union.CValue;
    pub const cval = c_union.cval;
};
pub const ModeConfig = extern struct {
    mode: modes.ModeTag.Backing,
    value: bool,
    fn toMode(self: ModeConfig) ?modes.Mode {
        const tag: modes.ModeTag = @bitCast(self.mode);
        return modes.modeFromInt(tag.value, tag.ansi);
    }
};
const Effects = struct {
    userdata: ?*anyopaque = null,
    write_pty: ?WritePtyFn = null,
    bell: ?BellFn = null,
    color_scheme: ?ColorSchemeFn = null,
    desktop_notification: ?DesktopNotificationFn = null,
    device_attributes_cb: ?DeviceAttributesFn = null,
    enquiry: ?EnquiryFn = null,
    xtversion: ?XtversionFn = null,
    title_changed: ?TitleChangedFn = null,
    pwd_changed: ?PwdChangedFn = null,
    progress_report: ?ProgressReportFn = null,
    program_status: ?ProgramStatusFn = null,
    semantic_prompt: ?SemanticPromptFn = null,
    reset: ?ResetFn = null,
    size_cb: ?SizeFn = null,
    clipboard_write: ?ClipboardWriteFn = null,
    clipboard_read: ?ClipboardReadFn = null,
    unknown_sequence: ?UnknownSequenceFn = null,
    render_hold: ?RenderHoldFn = null,
    resize_window: ?ResizeWindowFn = null,
    da_features_buf: [64]device_attributes.Primary.Feature = undefined,
    pub const WritePtyFn = *const fn (Terminal, ?*anyopaque, [*]const u8, usize) callconv(lib.calling_conv) void;
    pub const BellFn = *const fn (Terminal, ?*anyopaque) callconv(lib.calling_conv) void;
    pub const ColorSchemeFn = *const fn (Terminal, ?*anyopaque, *device_status.ColorScheme) callconv(lib.calling_conv) bool;
    pub const EnquiryFn = *const fn (Terminal, ?*anyopaque) callconv(lib.calling_conv) lib.String;
    pub const XtversionFn = *const fn (Terminal, ?*anyopaque) callconv(lib.calling_conv) lib.String;
    pub const ClipboardWriteFn = *const fn (Terminal, ?*anyopaque, *const ClipboardWrite) callconv(lib.calling_conv) void;
    pub const ClipboardReadFn = *const fn (Terminal, ?*anyopaque, *const ClipboardRead) callconv(lib.calling_conv) void;
    pub const DesktopNotificationFn = *const fn (Terminal, ?*anyopaque, *const DesktopNotification) callconv(lib.calling_conv) void;
    pub const TitleChangedFn = *const fn (Terminal, ?*anyopaque) callconv(lib.calling_conv) void;
    pub const RenderHoldFn = *const fn (Terminal, ?*anyopaque, bool) callconv(lib.calling_conv) void;
    pub const ResizeWindowFn = *const fn (Terminal, ?*anyopaque, *const ResizeWindow.C) callconv(lib.calling_conv) void;
    pub const PwdChangedFn = *const fn (Terminal, ?*anyopaque) callconv(lib.calling_conv) void;
    pub const ProgressReportFn = *const fn (Terminal, ?*anyopaque, *const ProgressReport) callconv(lib.calling_conv) void;
    pub const ProgramStatusFn = *const fn (Terminal, ?*anyopaque, *const ProgramStatus) callconv(lib.calling_conv) void;
    pub const SemanticPromptFn = *const fn (Terminal, ?*anyopaque, *const SemanticPrompt) callconv(lib.calling_conv) void;
    pub const ResetFn = *const fn (Terminal, ?*anyopaque) callconv(lib.calling_conv) void;
    pub const UnknownSequenceFn = *const fn (Terminal, ?*anyopaque, *const UnknownSequence.C) callconv(lib.calling_conv) void;
    pub const SizeFn = *const fn (Terminal, ?*anyopaque, *size_report.Size) callconv(lib.calling_conv) bool;
    pub const DeviceAttributesFn = *const fn (Terminal, ?*anyopaque, *CDeviceAttributes) callconv(lib.calling_conv) bool;
    pub const CDeviceAttributes = extern struct {
        primary: Primary,
        secondary: Secondary,
        tertiary: Tertiary,
        pub const Primary = extern struct {
            conformance_level: u16,
            features: [64]u16,
            num_features: usize,
        };
        pub const Secondary = extern struct {
            device_type: u16,
            firmware_version: u16,
            rom_cartridge: u16,
        };
        pub const Tertiary = extern struct {
            unit_id: u32,
        };
    };
    fn writePtyTrampoline(handler: *Handler, data: []const u8) void {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.write_pty orelse return;
        func(@ptrCast(wrapper), wrapper.effects.userdata, data.ptr, data.len);
    }
    fn bellTrampoline(handler: *Handler) void {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.bell orelse return;
        func(@ptrCast(wrapper), wrapper.effects.userdata);
    }
    const ClipboardWriteCtx = struct {
        write: clipboard.Write,
    };
    fn clipboardWriteTrampoline(handler: *Handler, write: clipboard.Write) void {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.clipboard_write orelse
            return write.reply(.unsupported);
        var stack_contents: [4]ClipboardContent = undefined;
        const contents: []ClipboardContent = if (write.contents.len <= stack_contents.len)
            stack_contents[0..write.contents.len]
        else
            wrapper.terminal.gpa().alloc(ClipboardContent, write.contents.len) catch
                return write.reply(.io_error);
        defer if (write.contents.len > stack_contents.len)
            wrapper.terminal.gpa().free(contents);
        for (contents, write.contents) |*c_content, content| {
            c_content.* = .{
                .mime = .init(content.mime),
                .data = .init(content.data),
            };
        }
        const ctx: ClipboardWriteCtx = .{ .write = write };
        const request: ClipboardWrite = .{
            .size = @sizeOf(ClipboardWrite),
            .location = write.location,
            .contents = if (contents.len > 0) contents.ptr else null,
            .contents_len = contents.len,
            .name = .init(write.name),
            .granted = write.granted,
            .can_remember = write.can_remember,
            .ctx = &ctx,
            .reply = &clipboardWriteReplyTrampoline,
        };
        func(@ptrCast(wrapper), wrapper.effects.userdata, &request);
    }
    fn clipboardWriteReplyTrampoline(
        request: *const ClipboardWrite,
        reply: *const ClipboardWriteReply,
    ) callconv(lib.calling_conv) void {
        const ctx: *const ClipboardWriteCtx = @ptrCast(@alignCast(request.ctx));
        const write = ctx.write;
        switch (reply.result) {
            .success => write.reply(.{ .success = .{ .remember = reply.remember } }),
            .denied => write.reply(.denied),
            .busy => write.reply(.busy),
            .invalid_data => write.reply(.invalid_data),
            .io_error => write.reply(.io_error),
            .unsupported, _ => write.reply(.unsupported),
        }
    }
    const ClipboardReadCtx = struct {
        read: clipboard.Read,
        wrapper: *TerminalWrapper,
    };
    fn clipboardReadTrampoline(handler: *Handler, read: clipboard.Read) void {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.clipboard_read orelse return;
        var sfa = std.heap.stackFallback(128, wrapper.terminal.gpa());
        const alloc = sfa.get();
        const mimes = alloc.alloc(lib.String, read.mimes.len) catch {
            log.warn("out of memory converting clipboard read request", .{});
            return;
        };
        defer alloc.free(mimes);
        for (mimes, read.mimes) |*c_mime, mime| c_mime.* = .init(mime);
        const ctx: ClipboardReadCtx = .{ .read = read, .wrapper = wrapper };
        const request: ClipboardRead = .{
            .size = @sizeOf(ClipboardRead),
            .location = read.location,
            .mimes = if (mimes.len > 0) mimes.ptr else null,
            .mimes_len = mimes.len,
            .list = read.list,
            .name = .init(read.name),
            .granted = read.granted,
            .can_remember = read.can_remember,
            .ctx = &ctx,
            .reply = &clipboardReadReplyTrampoline,
        };
        func(@ptrCast(wrapper), wrapper.effects.userdata, &request);
    }
    fn clipboardReadReplyTrampoline(
        request: *const ClipboardRead,
        reply: *const ClipboardReadReply,
    ) callconv(lib.calling_conv) void {
        const ctx: *const ClipboardReadCtx = @ptrCast(@alignCast(request.ctx));
        const read = ctx.read;
        switch (reply.result) {
            .success => {},
            .denied => return read.reply(.denied),
            .busy => return read.reply(.busy),
            .io_error => return read.reply(.io_error),
            .unsupported, _ => return read.reply(.unsupported),
        }
        const c_contents: []const ClipboardContent = if (reply.contents) |ptr|
            ptr[0..reply.contents_len]
        else
            &.{};
        const c_available: []const lib.String = if (reply.available) |ptr|
            ptr[0..reply.available_len]
        else
            &.{};
        var sfa = std.heap.stackFallback(256, ctx.wrapper.terminal.gpa());
        const alloc = sfa.get();
        const contents = alloc.alloc(clipboard.Content, c_contents.len) catch {
            log.warn("out of memory converting clipboard read reply", .{});
            return;
        };
        defer alloc.free(contents);
        for (contents, c_contents) |*content, c_content| {
            content.* = .{
                .mime = c_content.mime.ptr[0..c_content.mime.len],
                .data = c_content.data.ptr[0..c_content.data.len],
            };
        }
        const available = alloc.alloc([]const u8, c_available.len) catch {
            log.warn("out of memory converting clipboard read reply", .{});
            return;
        };
        defer alloc.free(available);
        for (available, c_available) |*mime, c_mime| {
            mime.* = c_mime.ptr[0..c_mime.len];
        }
        read.reply(.{ .success = .{
            .contents = contents,
            .available = available,
            .remember = reply.remember,
        } });
    }
    fn desktopNotificationTrampoline(
        handler: *Handler,
        notification: Action.ShowDesktopNotification,
    ) void {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.desktop_notification orelse return;
        const request: DesktopNotification = .{
            .size = @sizeOf(DesktopNotification),
            .title = .init(notification.title),
            .body = .init(notification.body),
        };
        func(@ptrCast(wrapper), wrapper.effects.userdata, &request);
    }
    fn colorSchemeTrampoline(handler: *Handler) ?device_status.ColorScheme {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.color_scheme orelse return null;
        var scheme: device_status.ColorScheme = undefined;
        if (func(@ptrCast(wrapper), wrapper.effects.userdata, &scheme)) return scheme;
        return null;
    }
    fn deviceAttributesTrampoline(handler: *Handler) device_attributes.Attributes {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.device_attributes_cb orelse return .{};
        var c_attrs: CDeviceAttributes = undefined;
        if (!func(@ptrCast(wrapper), wrapper.effects.userdata, &c_attrs)) return .{};
        const n: usize = @min(c_attrs.primary.num_features, 64);
        for (0..n) |i| wrapper.effects.da_features_buf[i] = @enumFromInt(c_attrs.primary.features[i]);
        return .{
            .primary = .{
                .conformance_level = @enumFromInt(c_attrs.primary.conformance_level),
                .features = wrapper.effects.da_features_buf[0..n],
            },
            .secondary = .{
                .device_type = @enumFromInt(c_attrs.secondary.device_type),
                .firmware_version = c_attrs.secondary.firmware_version,
                .rom_cartridge = c_attrs.secondary.rom_cartridge,
            },
            .tertiary = .{
                .unit_id = c_attrs.tertiary.unit_id,
            },
        };
    }
    fn enquiryTrampoline(handler: *Handler) []const u8 {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.enquiry orelse return "";
        const result = func(@ptrCast(wrapper), wrapper.effects.userdata);
        if (result.len == 0) return "";
        return result.ptr[0..result.len];
    }
    fn xtversionTrampoline(handler: *Handler) []const u8 {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.xtversion orelse return "";
        const result = func(@ptrCast(wrapper), wrapper.effects.userdata);
        if (result.len == 0) return "";
        return result.ptr[0..result.len];
    }
    fn titleChangedTrampoline(handler: *Handler) void {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.title_changed orelse return;
        func(@ptrCast(wrapper), wrapper.effects.userdata);
    }
    fn renderHoldTrampoline(handler: *Handler, held: bool) void {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.render_hold orelse return;
        func(@ptrCast(wrapper), wrapper.effects.userdata, held);
    }
    fn pwdChangedTrampoline(handler: *Handler) void {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.pwd_changed orelse return;
        func(@ptrCast(wrapper), wrapper.effects.userdata);
    }
    fn progressReportTrampoline(
        handler: *Handler,
        report: osc.Command.ProgressReport,
    ) void {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.progress_report orelse return;
        const c_report: ProgressReport = .{
            .size = @sizeOf(ProgressReport),
            .state = @enumFromInt(@intFromEnum(report.state)),
            .progress = if (report.progress) |value| @intCast(value) else -1,
        };
        func(@ptrCast(wrapper), wrapper.effects.userdata, &c_report);
    }
    fn programStatusTrampoline(
        handler: *Handler,
        report: osc.Command.ProgramStatus.Report,
    ) void {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.program_status orelse return;
        var title_buf: [osc.program_status.max_title_bytes]u8 = undefined;
        var title: std.Io.Writer = .fixed(&title_buf);
        report.writeText(.title, &title) catch unreachable;
        var message_buf: [osc.program_status.max_msg_bytes]u8 = undefined;
        var message: std.Io.Writer = .fixed(&message_buf);
        report.writeText(.msg, &message) catch unreachable;
        const c_report: ProgramStatus = .{
            .size = @sizeOf(ProgramStatus),
            .state = report.state,
            .kind = if (report.readOption(.kind)) |kind| switch (kind) {
                inline else => |tag| @field(ProgramStatusKind, @tagName(tag)),
            } else .none,
            .progress = if (report.readOption(.progress)) |value| @intCast(value) else -1,
            .id = .init(report.readOption(.id) orelse ""),
            .app = .init(report.readOption(.app) orelse ""),
            .title = .init(title.buffered()),
            .message = .init(message.buffered()),
        };
        func(@ptrCast(wrapper), wrapper.effects.userdata, &c_report);
    }
    fn semanticPromptTrampoline(
        handler: *Handler,
        event: Handler.SemanticPrompt,
    ) void {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.semantic_prompt orelse return;
        const c_event: SemanticPrompt = .{
            .size = @sizeOf(SemanticPrompt),
            .kind = event.kind,
            .prompt_kind = event.prompt_kind,
            .has_exit_code = event.exit_code != null,
            .exit_code = event.exit_code orelse 0,
            .command = .init(event.command),
            .@"error" = .init(event.err),
        };
        func(@ptrCast(wrapper), wrapper.effects.userdata, &c_event);
    }
    fn resetTrampoline(handler: *Handler) void {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.reset orelse return;
        func(@ptrCast(wrapper), wrapper.effects.userdata);
    }
    fn resizeWindowTrampoline(
        handler: *Handler,
        request: Handler.ResizeWindow,
    ) void {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.resize_window orelse return;
        const value = ResizeWindow.cval(switch (request) {
            .grid => |grid| .{ .grid = .{
                .rows = grid.rows,
                .columns = grid.columns,
            } },
        });
        func(@ptrCast(wrapper), wrapper.effects.userdata, &value);
    }
    fn unknownSequenceTrampoline(
        handler: *Handler,
        sequence: Handler.UnknownSequence,
    ) void {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.unknown_sequence orelse return;
        const value = UnknownSequence.cval(switch (sequence) {
            .apc => |apc_value| .{
                .apc = .{
                    .truncated = apc_value.truncated,
                    .content = .init(apc_value.content),
                },
            },
            .osc => |osc_value| .{ .osc = osc_value.cval() },
        });
        func(@ptrCast(wrapper), wrapper.effects.userdata, &value);
    }
    fn sizeTrampoline(handler: *Handler) ?size_report.Size {
        const wrapper = TerminalWrapper.fromHandler(handler);
        const func = wrapper.effects.size_cb orelse return null;
        var s: size_report.Size = undefined;
        if (func(@ptrCast(wrapper), wrapper.effects.userdata, &s)) return s;
        return null;
    }
};
pub const Terminal = ?*TerminalWrapper;
pub const CompressionMode = ZigTerminal.CompressionMode;
pub const CompressionResult = ZigTerminal.CompressionResult;
pub fn zigTerminal(terminal_: Terminal) ?*ZigTerminal {
    return (terminal_ orelse return null).terminal;
}
fn wrap(
    alloc: std.mem.Allocator,
    t: *ZigTerminal,
    io: Io,
    continuation_max_bytes: usize,
) error{OutOfMemory}!Terminal {
    const wrapper = alloc.create(TerminalWrapper) catch
        return error.OutOfMemory;
    var handler: Stream.Handler = t.vtHandler();
    handler.effects = .{
        .write_pty = &Effects.writePtyTrampoline,
        .bell = &Effects.bellTrampoline,
        .color_scheme = &Effects.colorSchemeTrampoline,
        .desktop_notification = &Effects.desktopNotificationTrampoline,
        .drag_and_drop = null,
        .device_attributes = &Effects.deviceAttributesTrampoline,
        .enquiry = &Effects.enquiryTrampoline,
        .xtversion = &Effects.xtversionTrampoline,
        .title_changed = &Effects.titleChangedTrampoline,
        .pwd_changed = &Effects.pwdChangedTrampoline,
        .progress_report = &Effects.progressReportTrampoline,
        .semantic_prompt = &Effects.semanticPromptTrampoline,
        .reset = &Effects.resetTrampoline,
        .size = &Effects.sizeTrampoline,
        .render_hold = &Effects.renderHoldTrampoline,
        .resize_window = &Effects.resizeWindowTrampoline,
        .clipboard_write = null,
        .clipboard_read = null,
        .program_status = null,
    };
    wrapper.* = .{
        .terminal = t,
        .io = io,
        .terminfo_name_buf = undefined,
        .stream = Stream.init(.{
            .allocator = alloc,
            .handler = handler,
            .continuation_max_bytes = continuation_max_bytes,
        }),
    };
    return wrapper;
}
pub const RestoreContinuationError = error{
    OutOfMemory,
    ContinuationDisabled,
    ContinuationUnavailable,
    InvalidContinuation,
};
pub fn restoreContinuation(
    terminal_: Terminal,
    continuation: []const u8,
) RestoreContinuationError!void {
    const wrapper = terminal_ orelse return error.InvalidContinuation;
    if (continuation.len > 0) wrapper.stream.nextSlice(continuation);
    var exported: std.Io.Writer.Allocating = .init(wrapper.terminal.gpa());
    defer exported.deinit();
    wrapper.stream.writeContinuation(&exported.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.ContinuationDisabled => return error.ContinuationDisabled,
        error.ContinuationUnavailable => return error.ContinuationUnavailable,
    };
    if (!std.mem.eql(u8, continuation, exported.written())) {
        return error.InvalidContinuation;
    }
}
pub const FromDecodedError = error{
    OutOfMemory,
    InvalidContinuation,
};
pub fn fromDecoded(
    alloc: std.mem.Allocator,
    io: Io,
    decoded: *snapshot_core.Decoded,
    continuation_max_bytes: usize,
) FromDecodedError!Terminal {
    const native = alloc.create(ZigTerminal) catch
        return error.OutOfMemory;
    native.* = decoded.toOwned();
    const continuation = switch (decoded.continuation) {
        .ground => "",
        .bytes => |bytes| bytes,
    };
    assert(continuation_max_bytes == 0 or
        continuation.len <= continuation_max_bytes);
    const tracker_max_bytes = if (continuation_max_bytes > 0)
        continuation_max_bytes
    else
        continuation.len;
    const terminal = wrap(alloc, native, io, tracker_max_bytes) catch |err| {
        native.deinit(alloc);
        alloc.destroy(native);
        return err;
    };
    errdefer free(terminal);
    if (continuation.len > 0) {
        restoreContinuation(terminal, continuation) catch |err| return switch (err) {
            error.OutOfMemory,
            error.ContinuationUnavailable,
            => error.OutOfMemory,
            error.ContinuationDisabled,
            error.InvalidContinuation,
            => error.InvalidContinuation,
        };
    }
    if (continuation_max_bytes == 0) {
        setContinuationMaxBytes(terminal.?, default_continuation_max_bytes);
    }
    return terminal;
}
const NewError = error{
    InvalidValue,
    OutOfMemory,
};
pub fn new(
    alloc_: ?*const CAllocator,
    result: *Terminal,
    cols: size.CellCountInt,
    rows: size.CellCountInt,
) callconv(lib.calling_conv) Result {
    result.* = new_(alloc_, cols, rows) catch |err| {
        result.* = null;
        return switch (err) {
            error.InvalidValue => .invalid_value,
            error.OutOfMemory => .out_of_memory,
        };
    };
    return .success;
}
fn new_(
    alloc_: ?*const CAllocator,
    cols: size.CellCountInt,
    rows: size.CellCountInt,
) NewError!Terminal {
    if (cols == 0 or rows == 0) return error.InvalidValue;
    const alloc = lib.alloc.default(alloc_);
    const t = alloc.create(ZigTerminal) catch
        return error.OutOfMemory;
    errdefer alloc.destroy(t);
    const io: Io = .init;
    t.* = try .init(
        io.io(),
        alloc,
        .{
            .cols = cols,
            .rows = rows,
        },
    );
    errdefer t.deinit(alloc);
    t.flags.shell_redraws_prompt = .false;
    return try wrap(
        alloc,
        t,
        io,
        default_continuation_max_bytes,
    );
}
pub fn vt_write(
    terminal_: Terminal,
    ptr: [*]const u8,
    len: usize,
) callconv(lib.calling_conv) void {
    const wrapper = terminal_ orelse return;
    wrapper.stream.nextSlice(ptr[0..len]);
}
pub fn vt_write_until_ground(
    terminal_: Terminal,
    ptr_: ?[*]const u8,
    len: usize,
    out_consumed_: ?*usize,
) callconv(lib.calling_conv) Result {
    const out_consumed = out_consumed_ orelse return .invalid_value;
    out_consumed.* = 0;
    const wrapper = terminal_ orelse return .invalid_value;
    const input: []const u8 = if (ptr_) |ptr|
        ptr[0..len]
    else if (len == 0)
        ""
    else
        return .invalid_value;
    if (wrapper.stream.nextSliceUntilGround(input)) |consumed| {
        out_consumed.* = consumed;
        return .success;
    }
    out_consumed.* = len;
    return .no_value;
}
pub const ContinuationWriteError = error{
    InvalidValue,
    WriteFailed,
    ContinuationDisabled,
    ContinuationUnavailable,
};
pub fn continuationWriteIo(
    terminal_: Terminal,
    writer: *std.Io.Writer,
) ContinuationWriteError!void {
    const wrapper = terminal_ orelse return error.InvalidValue;
    try wrapper.stream.writeContinuation(writer);
}
pub const ContinuationAllocError = error{
    InvalidValue,
    OutOfMemory,
    ContinuationDisabled,
    ContinuationUnavailable,
};
pub fn continuationAllocIo(
    terminal_: Terminal,
    alloc: std.mem.Allocator,
    allow_untracked_ground: bool,
) ContinuationAllocError![]u8 {
    const wrapper = terminal_ orelse return error.InvalidValue;
    if (allow_untracked_ground and
        wrapper.stream.continuation == null and
        wrapper.stream.ground())
    {
        return alloc.dupe(u8, "") catch error.OutOfMemory;
    }
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    continuationWriteIo(terminal_, &aw.writer) catch |err| switch (err) {
        error.InvalidValue => return error.InvalidValue,
        error.WriteFailed => return error.OutOfMemory,
        error.ContinuationDisabled => return error.ContinuationDisabled,
        error.ContinuationUnavailable => return error.ContinuationUnavailable,
    };
    return aw.toOwnedSlice() catch error.OutOfMemory;
}
fn continuationErrorResult(err: ContinuationWriteError) Result {
    return switch (err) {
        error.InvalidValue => .invalid_value,
        error.WriteFailed => .io_error,
        error.ContinuationDisabled => .invalid_value,
        error.ContinuationUnavailable => .invalid_value,
    };
}
pub fn continuation_write(
    terminal_: Terminal,
    writer: c_io.Writer,
) callconv(lib.calling_conv) Result {
    if (writer.write == null) return .invalid_value;
    var buffer: [c_io.WriterAdapter.recommended_buffer_len]u8 = undefined;
    var adapter: c_io.WriterAdapter = .initBuffered(writer, &buffer);
    write: {
        continuationWriteIo(terminal_, &adapter.interface) catch |err| switch (err) {
            error.WriteFailed => break :write,
            else => return continuationErrorResult(err),
        };
        adapter.interface.flush() catch break :write;
        return .success;
    }
    if (adapter.invalid_write) return .limit_exceeded;
    if (adapter.callback_failed) return .io_error;
    return continuationErrorResult(error.WriteFailed);
}
pub fn continuation_buf(
    terminal_: Terminal,
    out_: ?[*]u8,
    out_len: usize,
    out_written_: ?*usize,
) callconv(lib.calling_conv) Result {
    const out_written = out_written_ orelse return .invalid_value;
    out_written.* = 0;
    if (out_ == null and out_len != 0) return .invalid_value;
    if (out_ == null) {
        var discarding: std.Io.Writer.Discarding = .init(&.{});
        continuationWriteIo(terminal_, &discarding.writer) catch |err|
            return continuationErrorResult(err);
        out_written.* = @intCast(discarding.count);
        return .out_of_space;
    }
    var writer: std.Io.Writer = .fixed(out_.?[0..out_len]);
    continuationWriteIo(terminal_, &writer) catch |err| switch (err) {
        error.WriteFailed => {
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            continuationWriteIo(terminal_, &discarding.writer) catch |count_err|
                return continuationErrorResult(count_err);
            out_written.* = @intCast(discarding.count);
            return .out_of_space;
        },
        else => return continuationErrorResult(err),
    };
    out_written.* = writer.end;
    return .success;
}
pub fn continuation_alloc(
    terminal_: Terminal,
    alloc_: ?*const CAllocator,
    out_ptr_: ?*?[*]u8,
    out_len_: ?*usize,
) callconv(lib.calling_conv) Result {
    const out_ptr = out_ptr_ orelse return .invalid_value;
    const out_len = out_len_ orelse return .invalid_value;
    out_ptr.* = null;
    out_len.* = 0;
    const bytes = continuationAllocIo(
        terminal_,
        lib.alloc.default(alloc_),
        false,
    ) catch |err| return switch (err) {
        error.InvalidValue => .invalid_value,
        error.OutOfMemory => .out_of_memory,
        error.ContinuationDisabled => .invalid_value,
        error.ContinuationUnavailable => .invalid_value,
    };
    out_ptr.* = if (bytes.len == 0) null else bytes.ptr;
    out_len.* = bytes.len;
    return .success;
}
fn continuationMaxBytes(wrapper: *const TerminalWrapper) usize {
    return if (wrapper.stream.continuation) |tracker|
        tracker.max_bytes
    else
        0;
}
fn setContinuationMaxBytes(wrapper: *TerminalWrapper, max_bytes: usize) void {
    if (max_bytes == 0) {
        if (wrapper.stream.continuation) |*tracker| tracker.deinit();
        wrapper.stream.continuation = null;
        return;
    }
    if (wrapper.stream.continuation) |*tracker| {
        tracker.max_bytes = max_bytes;
        if (tracker.bytes.items.len > max_bytes) {
            tracker.bytes.clearRetainingCapacity();
            tracker.broken = true;
        }
        return;
    }
    wrapper.stream.continuation = .init(wrapper.terminal.gpa(), max_bytes);
    if (!wrapper.stream.ground()) {
        wrapper.stream.continuation.?.broken = true;
    }
}
pub fn compression_activity(
    terminal_: Terminal,
    out_activity_: ?*u64,
) callconv(lib.calling_conv) Result {
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    const out_activity = out_activity_ orelse return .invalid_value;
    out_activity.* = t.compressionActivity();
    return .success;
}
pub fn compress(
    terminal_: Terminal,
    mode_: c_int,
    out_result_: ?*CompressionResult,
) callconv(lib.calling_conv) Result {
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    const out_result = out_result_ orelse return .invalid_value;
    const mode = std.enums.fromInt(CompressionMode, mode_) orelse return .invalid_value;
    out_result.* = t.compress(mode);
    return .success;
}
pub const Option = enum(c_int) {
    userdata = 0,
    write_pty = 1,
    bell = 2,
    enquiry = 3,
    xtversion = 4,
    title_changed = 5,
    size_cb = 6,
    color_scheme = 7,
    device_attributes = 8,
    title = 9,
    pwd = 10,
    color_foreground = 11,
    color_background = 12,
    color_cursor = 13,
    color_palette = 14,
    kitty_image_storage_limit = 15,
    kitty_image_medium_file = 16,
    kitty_image_medium_temp_file = 17,
    kitty_image_medium_shared_mem = 18,
    apc_max_bytes = 19,
    apc_max_bytes_kitty = 20,
    selection = 21,
    default_cursor_style = 22,
    default_cursor_blink = 23,
    glyph_protocol = 24,
    pwd_changed = 25,
    clipboard_write = 26,
    scrollback_max_bytes = 27,
    scrollback_max_lines = 28,
    desktop_notification = 29,
    progress_report = 30,
    continuation_max_bytes = 31,
    title_report = 32,
    mode_default = 33,
    mode = 34,
    unknown_sequence = 35,
    unknown_max_bytes = 36,
    terminfo_name = 37,
    clipboard_read = 38,
    clipboard_write_max_bytes = 39,
    resize_pull_scrollback = 40,
    render_hold = 41,
    semantic_prompt = 42,
    reset = 43,
    xt_checksum_report = 44,
    xt_checksum_extension = 45,
    program_status = 46,
    resize_window = 47,
    pub fn InType(comptime self: Option) type {
        return switch (self) {
            .userdata => ?*const anyopaque,
            .write_pty => ?Effects.WritePtyFn,
            .bell => ?Effects.BellFn,
            .color_scheme => ?Effects.ColorSchemeFn,
            .desktop_notification => ?Effects.DesktopNotificationFn,
            .device_attributes => ?Effects.DeviceAttributesFn,
            .enquiry => ?Effects.EnquiryFn,
            .xtversion => ?Effects.XtversionFn,
            .title_changed => ?Effects.TitleChangedFn,
            .pwd_changed => ?Effects.PwdChangedFn,
            .progress_report => ?Effects.ProgressReportFn,
            .program_status => ?Effects.ProgramStatusFn,
            .size_cb => ?Effects.SizeFn,
            .clipboard_write => ?Effects.ClipboardWriteFn,
            .clipboard_read => ?Effects.ClipboardReadFn,
            .unknown_sequence => ?Effects.UnknownSequenceFn,
            .render_hold => ?Effects.RenderHoldFn,
            .semantic_prompt => ?Effects.SemanticPromptFn,
            .reset => ?Effects.ResetFn,
            .resize_window => ?Effects.ResizeWindowFn,
            .title, .pwd, .terminfo_name => ?*const lib.String,
            .color_foreground, .color_background, .color_cursor => ?*const color.RGB.C,
            .color_palette => ?*const color.PaletteC,
            .kitty_image_storage_limit => ?*const u64,
            .xt_checksum_extension => ?*const u8,
            .kitty_image_medium_file,
            .kitty_image_medium_shared_mem,
            .glyph_protocol,
            .title_report,
            .xt_checksum_report,
            .resize_pull_scrollback,
            => ?*const bool,
            .kitty_image_medium_temp_file => ?*const lib.String,
            .apc_max_bytes,
            .apc_max_bytes_kitty,
            .scrollback_max_bytes,
            .scrollback_max_lines,
            .continuation_max_bytes,
            .unknown_max_bytes,
            .clipboard_write_max_bytes,
            => ?*const usize,
            .selection => ?*const selection_c.CSelection,
            .default_cursor_style => ?*const TerminalCursorStyle,
            .default_cursor_blink => ?*const bool,
            .mode, .mode_default => ?*const ModeConfig,
        };
    }
};
pub fn set(
    terminal_: Terminal,
    option: Option,
    value: ?*const anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.enums.fromInt(Option, @intFromEnum(option)) orelse {
            log.warn("terminal_set invalid option value={d}", .{@intFromEnum(option)});
            return .invalid_value;
        };
    }
    const wrapper = terminal_ orelse return .invalid_value;
    return switch (option) {
        inline else => |comptime_option| setTyped(
            wrapper,
            comptime_option,
            @ptrCast(@alignCast(value)),
        ),
    };
}
fn setTyped(
    wrapper: *TerminalWrapper,
    comptime option: Option,
    value: option.InType(),
) Result {
    switch (option) {
        .userdata => wrapper.effects.userdata = @constCast(value),
        .write_pty => wrapper.effects.write_pty = value,
        .bell => wrapper.effects.bell = value,
        .color_scheme => wrapper.effects.color_scheme = value,
        .desktop_notification => wrapper.effects.desktop_notification = value,
        .device_attributes => wrapper.effects.device_attributes_cb = value,
        .enquiry => wrapper.effects.enquiry = value,
        .xtversion => wrapper.effects.xtversion = value,
        .title_changed => wrapper.effects.title_changed = value,
        .pwd_changed => wrapper.effects.pwd_changed = value,
        .progress_report => wrapper.effects.progress_report = value,
        .resize_window => wrapper.effects.resize_window = value,
        .size_cb => wrapper.effects.size_cb = value,
        .render_hold => wrapper.effects.render_hold = value,
        .semantic_prompt => wrapper.effects.semantic_prompt = value,
        .reset => wrapper.effects.reset = value,
        .clipboard_write => {
            wrapper.effects.clipboard_write = value;
            wrapper.stream.handler.effects.clipboard_write = if (value != null)
                &Effects.clipboardWriteTrampoline
            else
                null;
        },
        .clipboard_read => {
            wrapper.effects.clipboard_read = value;
            wrapper.stream.handler.effects.clipboard_read = if (value != null)
                &Effects.clipboardReadTrampoline
            else
                null;
        },
        .program_status => {
            wrapper.effects.program_status = value;
            wrapper.stream.handler.effects.program_status = if (value != null)
                &Effects.programStatusTrampoline
            else
                null;
        },
        .unknown_sequence => {
            wrapper.effects.unknown_sequence = value;
            wrapper.stream.handler.unknown_sequence = if (value != null)
                &Effects.unknownSequenceTrampoline
            else
                null;
        },
        .title_report => wrapper.stream.handler.title_report = if (value) |ptr|
            ptr.*
        else
            false,
        .xt_checksum_report => wrapper.stream.handler.xt_checksum_report = if (value) |ptr|
            ptr.*
        else
            false,
        .title => {
            const str = if (value) |v| v.ptr[0..v.len] else "";
            wrapper.terminal.setTitle(str) catch return .out_of_memory;
        },
        .pwd => {
            const str = if (value) |v| v.ptr[0..v.len] else "";
            wrapper.terminal.setPwd(str) catch return .out_of_memory;
        },
        .terminfo_name => {
            const str = if (value) |v| v.ptr[0..v.len] else "";
            if (str.len > wrapper.terminfo_name_buf.len) return .invalid_value;
            @memcpy(wrapper.terminfo_name_buf[0..str.len], str);
            wrapper.stream.handler.terminfo_name = if (str.len > 0)
                wrapper.terminfo_name_buf[0..str.len]
            else
                null;
        },
        .color_foreground => {
            wrapper.terminal.colors.foreground.default = if (value) |v| .fromC(v.*) else null;
            wrapper.terminal.flags.dirty.palette = true;
        },
        .color_background => {
            wrapper.terminal.colors.background.default = if (value) |v| .fromC(v.*) else null;
            wrapper.terminal.flags.dirty.palette = true;
        },
        .color_cursor => {
            wrapper.terminal.colors.cursor.default = if (value) |v| .fromC(v.*) else null;
            wrapper.terminal.flags.dirty.palette = true;
        },
        .color_palette => {
            wrapper.terminal.colors.palette.changeDefault(
                wrapper.terminal.gpa(),
                if (value) |v| color.paletteZval(v) else color.default,
            ) catch return .out_of_memory;
            wrapper.terminal.flags.dirty.palette = true;
        },
        .kitty_image_storage_limit => {
            if (comptime !build_options.kitty_graphics) return .success;
            const limit: usize = if (value) |v| @intCast(v.*) else 0;
            var it = wrapper.terminal.screens.all.iterator();
            while (it.next()) |entry| {
                const screen = entry.value.*;
                screen.kitty_images.setLimit(screen.io, screen.alloc, screen, limit);
            }
        },
        .kitty_image_medium_file,
        .kitty_image_medium_shared_mem,
        => {
            if (comptime !build_options.kitty_graphics) return .success;
            const val = (value orelse return .success).*;
            var it = wrapper.terminal.screens.all.iterator();
            while (it.next()) |entry| {
                const screen = entry.value.*;
                switch (option) {
                    .kitty_image_medium_file => screen.kitty_images.image_limits.file = val,
                    .kitty_image_medium_shared_mem => screen.kitty_images.image_limits.shared_memory = val,
                    else => unreachable,
                }
            }
        },
        .kitty_image_medium_temp_file => {
            if (comptime !build_options.kitty_graphics) return .success;
            const alloc = wrapper.terminal.gpa();
            if (value) |v| {
                if (v.len > max_path_bytes) return .out_of_memory;
                const path = alloc.dupe(u8, v.ptr[0..v.len]) catch
                    return .out_of_memory;
                var it = wrapper.terminal.screens.all.iterator();
                while (it.next()) |entry| {
                    const screen = entry.value.*;
                    screen.kitty_images.image_limits.temporary_file = .{
                        .enabled = .{ .directory = path },
                    };
                }
                if (wrapper.tmp_dir_path) |old| alloc.free(old);
                wrapper.tmp_dir_path = path;
            } else {
                var it = wrapper.terminal.screens.all.iterator();
                while (it.next()) |entry| {
                    const screen = entry.value.*;
                    screen.kitty_images.image_limits.temporary_file = .disabled;
                }
                if (wrapper.tmp_dir_path) |old| alloc.free(old);
                wrapper.tmp_dir_path = null;
            }
        },
        .apc_max_bytes => {
            wrapper.stream.handler.apc_handler.max_bytes = if (value) |ptr|
                .initFull(ptr.*)
            else
                .{};
        },
        .apc_max_bytes_kitty => {
            if (value) |ptr| {
                wrapper.stream.handler.apc_handler.max_bytes.put(.kitty, ptr.*);
            } else {
                wrapper.stream.handler.apc_handler.max_bytes.remove(.kitty);
            }
        },
        .glyph_protocol => {
            const enabled = (value orelse return .success).*;
            wrapper.stream.handler.apc_handler.enable(.glyph, enabled);
            if (!enabled) wrapper.terminal.glyph_glossary.clearAndFree(wrapper.terminal.gpa());
        },
        .selection => {
            if (value) |ptr| {
                const sel = ptr.toZig() orelse return .invalid_value;
                wrapper.terminal.screens.active.select(sel) catch return .out_of_memory;
            } else {
                wrapper.terminal.screens.active.clearSelection();
            }
        },
        .default_cursor_style => {
            const style = (if (value) |ptr| ptr.* else TerminalCursorStyle.block).toZig() orelse return .invalid_value;
            wrapper.terminal.setDefaultCursorStyle(style);
        },
        .default_cursor_blink => {
            const blink = if (value) |ptr| ptr.* else false;
            wrapper.terminal.setDefaultCursorBlink(blink);
        },
        .scrollback_max_bytes => wrapper.terminal.setScrollbackMaxBytes(
            if (value) |ptr| ptr.* else null,
        ),
        .scrollback_max_lines => wrapper.terminal.setScrollbackMaxLines(
            if (value) |ptr| ptr.* else null,
        ),
        .continuation_max_bytes => setContinuationMaxBytes(
            wrapper,
            if (value) |ptr| ptr.* else default_continuation_max_bytes,
        ),
        .unknown_max_bytes => {
            const max_bytes = if (value) |ptr| ptr.* else 0;
            wrapper.stream.handler.apc_handler.unknown_max_bytes = max_bytes;
            wrapper.stream.parser.osc_parser.unknown_max_bytes = max_bytes;
        },
        .clipboard_write_max_bytes => wrapper.stream.handler.kitty_clipboard_write_max_bytes =
            if (value) |ptr| ptr.* else kitty_clipboard.max_write_size,
        .resize_pull_scrollback => wrapper.terminal.flags.resize_pull_scrollback =
            if (value) |ptr| ptr.* else true,
        .xt_checksum_extension => {
            const bits = if (value) |ptr| ptr.* else 0;
            const flags = std.math.cast(u5, bits) orelse return .invalid_value;
            wrapper.terminal.setDefaultXtChecksum(@bitCast(flags));
        },
        .mode, .mode_default => {
            const config = (value orelse return .invalid_value).*;
            const mode = config.toMode() orelse return .invalid_value;
            switch (option) {
                .mode => wrapper.terminal.modes.set(mode, config.value),
                .mode_default => {
                    if (!modes.defaultConfigurable(mode)) return .invalid_value;
                    wrapper.terminal.modes.setDefault(mode, config.value);
                },
                else => unreachable,
            }
        },
    }
    return .success;
}
pub const TerminalCursorStyle = enum(c_int) {
    bar = 0,
    block = 1,
    underline = 2,
    block_hollow = 3,
    _,
    fn toZig(self: TerminalCursorStyle) ?Screen.CursorStyle {
        return switch (self) {
            .bar => .bar,
            .block => .block,
            .underline => .underline,
            .block_hollow => .block_hollow,
            _ => null,
        };
    }
};
pub const DeviceAttributes = Effects.CDeviceAttributes;
pub const ScrollViewport = ZigTerminal.ScrollViewport.C;
pub fn scroll_viewport(
    terminal_: Terminal,
    behavior: ScrollViewport,
) callconv(lib.calling_conv) void {
    const t: *ZigTerminal = (terminal_ orelse return).terminal;
    t.scrollViewport(switch (behavior.tag) {
        .top => .top,
        .bottom => .bottom,
        .delta => .{ .delta = behavior.value.delta },
        .row => .{ .row = behavior.value.row },
        .delta_prompt => .{ .delta_prompt = behavior.value.delta_prompt },
    });
}
pub fn resize(
    terminal_: Terminal,
    cols: size.CellCountInt,
    rows: size.CellCountInt,
    cell_width_px: u32,
    cell_height_px: u32,
) callconv(lib.calling_conv) Result {
    const wrapper = terminal_ orelse return .invalid_value;
    wrapper.stream.handler.resize(.{
        .cols = cols,
        .rows = rows,
        .cell_size_px = .{
            .width = cell_width_px,
            .height = cell_height_px,
        },
    }) catch |err| return switch (err) {
        error.InvalidValue => .invalid_value,
        error.OutOfMemory => .out_of_memory,
    };
    return .success;
}
pub fn reset(terminal_: Terminal) callconv(lib.calling_conv) void {
    const wrapper = terminal_ orelse return;
    const t: *ZigTerminal = wrapper.terminal;
    const sync = t.modes.get(.synchronized_output);
    t.fullReset();
    if (sync) Effects.renderHoldTrampoline(&wrapper.stream.handler, false);
}
pub const KittyGraphics = kitty_gfx_c.KittyGraphics;
pub const TerminalScreen = ScreenSet.Key;
pub const TerminalScrollbar = PageList.Scrollbar.C;
pub const TerminalMemoryUsage = extern struct {
    size: usize = @sizeOf(TerminalMemoryUsage),
    compression_supported: bool = false,
    primary_pages: u64 = 0,
    primary_virtual_bytes: u64 = 0,
    primary_resident_bytes: u64 = 0,
    primary_compressed_pages: u64 = 0,
    primary_compressed_bytes: u64 = 0,
    primary_image_bytes: u64 = 0,
    alternate_pages: u64 = 0,
    alternate_virtual_bytes: u64 = 0,
    alternate_resident_bytes: u64 = 0,
    alternate_compressed_pages: u64 = 0,
    alternate_compressed_bytes: u64 = 0,
    alternate_image_bytes: u64 = 0,
    fn init(t: *const ZigTerminal, caller_size: usize) TerminalMemoryUsage {
        var result: TerminalMemoryUsage = .{
            .size = caller_size,
            .compression_supported = terminal_mem.canReclaim(.strict),
        };
        const primary = t.screens.get(.primary).?.memoryUsage();
        result.primary_pages = primary.pages.pages;
        result.primary_virtual_bytes = primary.pages.virtual_bytes;
        result.primary_resident_bytes = primary.pages.resident_bytes;
        result.primary_compressed_pages = primary.pages.compressed_pages;
        result.primary_compressed_bytes = primary.pages.compressed_bytes;
        result.primary_image_bytes = primary.image_bytes;
        if (t.screens.get(.alternate)) |screen| {
            const alternate = screen.memoryUsage();
            result.alternate_pages = alternate.pages.pages;
            result.alternate_virtual_bytes = alternate.pages.virtual_bytes;
            result.alternate_resident_bytes = alternate.pages.resident_bytes;
            result.alternate_compressed_pages = alternate.pages.compressed_pages;
            result.alternate_compressed_bytes = alternate.pages.compressed_bytes;
            result.alternate_image_bytes = alternate.image_bytes;
        }
        return result;
    }
};
pub const TerminalData = enum(c_int) {
    invalid = 0,
    cols = 1,
    rows = 2,
    cursor_x = 3,
    cursor_y = 4,
    cursor_pending_wrap = 5,
    active_screen = 6,
    cursor_visible = 7,
    kitty_keyboard_flags = 8,
    scrollbar = 9,
    cursor_style = 10,
    mouse_tracking = 11,
    title = 12,
    pwd = 13,
    total_rows = 14,
    scrollback_rows = 15,
    width_px = 16,
    height_px = 17,
    color_foreground = 18,
    color_background = 19,
    color_cursor = 20,
    color_palette = 21,
    color_foreground_default = 22,
    color_background_default = 23,
    color_cursor_default = 24,
    color_palette_default = 25,
    kitty_image_storage_limit = 26,
    kitty_image_medium_file = 27,
    kitty_image_medium_temp_file = 28,
    kitty_image_medium_shared_mem = 29,
    kitty_graphics = 30,
    selection = 31,
    viewport_active = 32,
    vt_processing_error = 33,
    scrollback_max_bytes = 34,
    scrollback_max_lines = 35,
    continuation_max_bytes = 36,
    mode = 37,
    vt_ground = 38,
    cursor_at_prompt = 39,
    clipboard_write_max_bytes = 40,
    mouse_shape = 41,
    memory_usage = 42,
    pub fn OutType(comptime self: TerminalData) type {
        return switch (self) {
            .invalid => void,
            .cols, .rows, .cursor_x, .cursor_y => size.CellCountInt,
            .cursor_pending_wrap,
            .cursor_visible,
            .mouse_tracking,
            .viewport_active,
            .vt_processing_error,
            .vt_ground,
            .cursor_at_prompt,
            => bool,
            .mouse_shape => mouse.Shape,
            .active_screen => TerminalScreen,
            .kitty_keyboard_flags => u8,
            .scrollbar => TerminalScrollbar,
            .cursor_style => style_c.Style,
            .title, .pwd => lib.String,
            .total_rows,
            .scrollback_rows,
            .scrollback_max_bytes,
            .scrollback_max_lines,
            .continuation_max_bytes,
            .clipboard_write_max_bytes,
            => usize,
            .width_px, .height_px => u32,
            .color_foreground,
            .color_background,
            .color_cursor,
            .color_foreground_default,
            .color_background_default,
            .color_cursor_default,
            => color.RGB.C,
            .color_palette, .color_palette_default => color.PaletteC,
            .kitty_image_storage_limit => u64,
            .kitty_image_medium_file,
            .kitty_image_medium_shared_mem,
            => bool,
            .kitty_image_medium_temp_file => lib.String,
            .kitty_graphics => KittyGraphics,
            .selection => selection_c.CSelection,
            .mode => ModeConfig,
            .memory_usage => TerminalMemoryUsage,
        };
    }
};
pub fn get(
    terminal_: Terminal,
    data: TerminalData,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.enums.fromInt(TerminalData, @intFromEnum(data)) orelse {
            log.warn("terminal_get invalid data value={d}", .{@intFromEnum(data)});
            return .invalid_value;
        };
    }
    const out_ptr = out orelse return .invalid_value;
    return switch (data) {
        .invalid => .invalid_value,
        inline else => |comptime_data| getTyped(
            terminal_,
            comptime_data,
            @ptrCast(@alignCast(out_ptr)),
        ),
    };
}
pub fn get_multi(
    terminal_: Terminal,
    count: usize,
    keys: ?[*]const TerminalData,
    values: ?[*]?*anyopaque,
    out_written: ?*usize,
) callconv(lib.calling_conv) Result {
    const k = keys orelse return .invalid_value;
    const v = values orelse return .invalid_value;
    for (0..count) |i| {
        const result = get(terminal_, k[i], v[i]);
        if (result != .success) {
            if (out_written) |w| w.* = i;
            return result;
        }
    }
    if (out_written) |w| w.* = count;
    return .success;
}
fn getTyped(
    terminal_: Terminal,
    comptime data: TerminalData,
    out: *data.OutType(),
) Result {
    const wrapper = terminal_ orelse return .invalid_value;
    const t: *ZigTerminal = wrapper.terminal;
    switch (data) {
        .invalid => return .invalid_value,
        .cols => out.* = t.cols,
        .rows => out.* = t.rows,
        .cursor_x => out.* = t.screens.active.cursor.x,
        .cursor_y => out.* = t.screens.active.cursor.y,
        .cursor_pending_wrap => out.* = t.screens.active.cursor.pending_wrap,
        .active_screen => out.* = t.screens.active_key,
        .cursor_visible => out.* = t.modes.get(.cursor_visible),
        .kitty_keyboard_flags => out.* = @as(u8, t.screens.active.kitty_keyboard.current().int()),
        .scrollbar => out.* = t.screens.active.pages.scrollbar().cval(),
        .cursor_style => out.* = .fromStyle(t.screens.active.cursor.style),
        .mouse_tracking => out.* = t.modes.get(.mouse_event_x10) or
            t.modes.get(.mouse_event_normal) or
            t.modes.get(.mouse_event_button) or
            t.modes.get(.mouse_event_any),
        .mouse_shape => out.* = t.mouse_shape,
        .title => {
            const title = t.getTitle() orelse "";
            out.* = .{ .ptr = title.ptr, .len = title.len };
        },
        .pwd => {
            const pwd = t.getPwd() orelse "";
            out.* = .{ .ptr = pwd.ptr, .len = pwd.len };
        },
        .total_rows => out.* = t.screens.active.pages.total_rows,
        .scrollback_rows => out.* = t.screens.active.pages.total_rows - t.rows,
        .width_px => out.* = t.width_px,
        .height_px => out.* = t.height_px,
        .color_foreground => out.* = (t.colors.foreground.get() orelse return .no_value).cval(),
        .color_background => out.* = (t.colors.background.get() orelse return .no_value).cval(),
        .color_cursor => out.* = (t.colors.cursor.get() orelse return .no_value).cval(),
        .color_foreground_default => out.* = (t.colors.foreground.default orelse return .no_value).cval(),
        .color_background_default => out.* = (t.colors.background.default orelse return .no_value).cval(),
        .color_cursor_default => out.* = (t.colors.cursor.default orelse return .no_value).cval(),
        .color_palette => out.* = color.paletteCval(&t.colors.palette.current),
        .color_palette_default => out.* = color.paletteCval(t.colors.palette.original),
        .kitty_image_storage_limit => {
            if (comptime !build_options.kitty_graphics) return .no_value;
            out.* = @intCast(t.screens.active.kitty_images.total_limit);
        },
        .kitty_image_medium_file => {
            if (comptime !build_options.kitty_graphics) return .no_value;
            out.* = t.screens.active.kitty_images.image_limits.file;
        },
        .kitty_image_medium_temp_file => {
            if (comptime !build_options.kitty_graphics) return .no_value;
            const dir = switch (t.screens.active.kitty_images.image_limits.temporary_file) {
                .enabled => |d| d.directory,
                .disabled => "",
            };
            out.* = .init(dir);
        },
        .kitty_image_medium_shared_mem => {
            if (comptime !build_options.kitty_graphics) return .no_value;
            out.* = t.screens.active.kitty_images.image_limits.shared_memory;
        },
        .kitty_graphics => {
            if (comptime !build_options.kitty_graphics) return .no_value;
            out.* = &t.screens.active.kitty_images;
        },
        .selection => out.* = selection_c.CSelection.fromZig(
            t.screens.active.selection orelse return .no_value,
        ),
        .viewport_active => out.* = t.screens.active.pages.viewport == .active,
        .vt_processing_error => out.* = wrapper.stream.handler.semantic_failure,
        .vt_ground => out.* = wrapper.stream.ground(),
        .scrollback_max_bytes => {
            const max = t.screens.get(.primary).?.pages.limits.bytes.explicit;
            if (max == std.math.maxInt(usize)) return .no_value;
            out.* = max;
        },
        .scrollback_max_lines => {
            const max = t.screens.get(.primary).?.pages.limits.lines.explicit;
            if (max == std.math.maxInt(usize)) return .no_value;
            out.* = max;
        },
        .continuation_max_bytes => out.* = continuationMaxBytes(wrapper),
        .clipboard_write_max_bytes => out.* = wrapper.stream.handler.kitty_clipboard_write_max_bytes,
        .mode => {
            const mode = out.toMode() orelse return .invalid_value;
            out.value = t.modes.get(mode);
        },
        .cursor_at_prompt => out.* = t.cursorIsAtPrompt(),
        .memory_usage => {
            if (out.size < @sizeOf(TerminalMemoryUsage)) return .invalid_value;
            out.* = .init(t, out.size);
        },
    }
    return .success;
}
pub fn grid_ref(
    terminal_: Terminal,
    pt: point.Point.C,
    out_ref: ?*grid_ref_c.CGridRef,
) callconv(lib.calling_conv) Result {
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    const zig_pt: point.Point = .fromC(pt);
    const p = t.screens.active.pages.pin(zig_pt) orelse
        return .invalid_value;
    if (out_ref) |out| out.* = grid_ref_c.CGridRef.fromPin(p);
    return .success;
}
pub fn grid_ref_track(
    terminal_: Terminal,
    pt: point.Point.C,
    out_ref: ?*grid_ref_tracked_c.CTrackedGridRef,
) callconv(lib.calling_conv) Result {
    const wrapper = terminal_ orelse return .invalid_value;
    const out = out_ref orelse return .invalid_value;
    out.* = null;
    const t: *ZigTerminal = wrapper.terminal;
    const list = &t.screens.active.pages;
    const p = list.pin(.fromC(pt)) orelse return .invalid_value;
    const tracked_pin = list.trackPin(p) catch return .out_of_memory;
    const alloc = t.gpa();
    const ref = alloc.create(grid_ref_tracked_c.TrackedGridRef) catch {
        list.untrackPin(tracked_pin);
        return .out_of_memory;
    };
    ref.* = .{
        .alloc = alloc,
        .terminal = wrapper,
        .screen_key = t.screens.active_key,
        .screen_generation = t.screens.generation(t.screens.active_key),
        .pin = tracked_pin,
    };
    wrapper.tracked_grid_refs.putNoClobber(
        alloc,
        ref,
        {},
    ) catch {
        list.untrackPin(tracked_pin);
        alloc.destroy(ref);
        return .out_of_memory;
    };
    out.* = ref;
    return .success;
}
pub fn point_from_grid_ref(
    terminal_: Terminal,
    ref: *const grid_ref_c.CGridRef,
    tag: point.Tag,
    out: ?*point.Coordinate,
) callconv(lib.calling_conv) Result {
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    const p = ref.toPin() orelse return .invalid_value;
    const pt = t.screens.active.pages.pointFromPin(tag, p) orelse
        return .no_value;
    if (out) |o| o.* = pt.coord();
    return .success;
}
pub fn free(terminal_: Terminal) callconv(lib.calling_conv) void {
    const wrapper = terminal_ orelse return;
    const t = wrapper.terminal;
    const alloc = t.gpa();
    for (wrapper.tracked_grid_refs.keys()) |ref| ref.terminal = null;
    wrapper.tracked_grid_refs.deinit(alloc);
    for (wrapper.searches.keys()) |search| search.terminal = null;
    wrapper.searches.deinit(alloc);
    wrapper.stream.deinit();
    t.deinit(alloc);
    if (wrapper.tmp_dir_path) |path| alloc.free(path);
    alloc.destroy(t);
    alloc.destroy(wrapper);
}
fn testEnableContinuation(terminal: Terminal) !void {
    const limit: usize = 1024;
    try testing.expectEqual(
        Result.success,
        set(terminal, .continuation_max_bytes, &limit),
    );
}
test "new/free" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    try testing.expect(t != null);
    free(t);
}
test "new invalid value" {
    var t: Terminal = null;
    try testing.expectEqual(Result.invalid_value, new(
        &lib.alloc.test_allocator,
        &t,
        0,
        24,
    ));
    try testing.expect(t == null);
    try testing.expectEqual(Result.invalid_value, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        0,
    ));
    try testing.expect(t == null);
}
test "continuation option and data" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var value: usize = 0;
    try testing.expectEqual(
        Result.success,
        get(t, .continuation_max_bytes, @ptrCast(&value)),
    );
    try testing.expectEqual(default_continuation_max_bytes, value);
    const custom: usize = 1234;
    try testing.expectEqual(
        Result.success,
        set(t, .continuation_max_bytes, &custom),
    );
    try testing.expectEqual(
        Result.success,
        get(t, .continuation_max_bytes, @ptrCast(&value)),
    );
    try testing.expectEqual(custom, value);
    try testing.expectEqual(
        Result.success,
        set(t, .continuation_max_bytes, null),
    );
    try testing.expectEqual(
        Result.success,
        get(t, .continuation_max_bytes, @ptrCast(&value)),
    );
    try testing.expectEqual(default_continuation_max_bytes, value);
    const disabled: usize = 0;
    try testing.expectEqual(
        Result.success,
        set(t, .continuation_max_bytes, &disabled),
    );
    try testing.expectEqual(
        Result.success,
        get(t, .continuation_max_bytes, @ptrCast(&value)),
    );
    try testing.expectEqual(@as(usize, 0), value);
    var written: usize = 99;
    try testing.expectEqual(
        Result.invalid_value,
        continuation_buf(t, null, 0, &written),
    );
    try testing.expectEqual(@as(usize, 0), written);
}
test "continuation buffer and allocator export exact suffix" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    try testEnableContinuation(t);
    vt_write(t, "A\x1b[31", 5);
    var required: usize = 0;
    try testing.expectEqual(
        Result.out_of_space,
        continuation_buf(t, null, 0, &required),
    );
    try testing.expectEqual(@as(usize, 4), required);
    var short: [2]u8 = undefined;
    try testing.expectEqual(
        Result.out_of_space,
        continuation_buf(t, &short, short.len, &required),
    );
    try testing.expectEqual(@as(usize, 4), required);
    var buf: [8]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(
        Result.success,
        continuation_buf(t, &buf, buf.len, &written),
    );
    try testing.expectEqualStrings("\x1b[31", buf[0..written]);
    var out_ptr: ?[*]u8 = null;
    var out_len: usize = 0;
    try testing.expectEqual(Result.success, continuation_alloc(
        t,
        &lib.alloc.test_allocator,
        &out_ptr,
        &out_len,
    ));
    const allocated = (out_ptr orelse return error.TestExpectedEqual)[0..out_len];
    defer lib.alloc.default(&lib.alloc.test_allocator).free(allocated);
    try testing.expectEqualStrings("\x1b[31", allocated);
    vt_write(t, "m", 1);
    try testing.expectEqual(
        Result.out_of_space,
        continuation_buf(t, null, 0, &required),
    );
    try testing.expectEqual(@as(usize, 0), required);
    const failing: CAllocator = .fromZig(&std.mem.Allocator.failing);
    try testing.expectEqual(Result.success, continuation_alloc(t, &failing, &out_ptr, &out_len));
    defer @import("allocator.zig").free(&failing, out_ptr, out_len);
    try testing.expectEqual(null, out_ptr);
    try testing.expectEqual(@as(usize, 0), out_len);
}
test "continuation export tracks split UTF-8" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    try testEnableContinuation(t);
    const prefix = [_]u8{ 0xF0, 0x9F };
    vt_write(t, &prefix, prefix.len);
    var buf: [4]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(
        Result.success,
        continuation_buf(t, &buf, buf.len, &written),
    );
    try testing.expectEqualSlices(u8, &prefix, buf[0..written]);
    const suffix = [_]u8{ 0x98, 0x80 };
    vt_write(t, &suffix, suffix.len);
    try testing.expectEqual(
        Result.out_of_space,
        continuation_buf(t, null, 0, &written),
    );
    try testing.expectEqual(@as(usize, 0), written);
}
test "continuation callback writer reports success and failure" {
    const Sink = struct {
        bytes: [8]u8 = undefined,
        len: usize = 0,
        fn write(
            userdata: ?*anyopaque,
            data: [*]const u8,
            len: usize,
        ) callconv(lib.calling_conv) bool {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            if (len > self.bytes.len - self.len) return false;
            @memcpy(self.bytes[self.len..][0..len], data[0..len]);
            self.len += len;
            return true;
        }
        fn fail(
            _: ?*anyopaque,
            _: [*]const u8,
            _: usize,
        ) callconv(lib.calling_conv) bool {
            return false;
        }
    };
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    try testEnableContinuation(t);
    vt_write(t, "\x1b[31", 4);
    var sink: Sink = .{};
    try testing.expectEqual(Result.success, continuation_write(t, .{
        .write = &Sink.write,
        .userdata = &sink,
    }));
    try testing.expectEqualStrings("\x1b[31", sink.bytes[0..sink.len]);
    try testing.expectEqual(Result.io_error, continuation_write(t, .{
        .write = &Sink.fail,
    }));
    try testing.expectEqual(
        Result.invalid_value,
        continuation_write(t, .{}),
    );
    try testing.expectEqual(Result.invalid_value, continuation_write(null, .{
        .write = &Sink.fail,
    }));
}
test "continuation runtime reconfiguration recovers safely" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const enough: usize = 8;
    try testing.expectEqual(
        Result.success,
        set(t, .continuation_max_bytes, &enough),
    );
    vt_write(t, "\x1b[123", 5);
    const too_small: usize = 2;
    try testing.expectEqual(
        Result.success,
        set(t, .continuation_max_bytes, &too_small),
    );
    var written: usize = 99;
    try testing.expectEqual(
        Result.invalid_value,
        continuation_buf(t, null, 0, &written),
    );
    try testing.expectEqual(@as(usize, 0), written);
    try testing.expectEqual(
        Result.success,
        set(t, .continuation_max_bytes, &enough),
    );
    vt_write(t, "\x1b[", 2);
    var buf: [8]u8 = undefined;
    try testing.expectEqual(
        Result.success,
        continuation_buf(t, &buf, buf.len, &written),
    );
    try testing.expectEqualStrings("\x1b[", buf[0..written]);
    const disabled: usize = 0;
    try testing.expectEqual(
        Result.success,
        set(t, .continuation_max_bytes, &disabled),
    );
    try testing.expectEqual(
        Result.success,
        set(t, .continuation_max_bytes, &enough),
    );
    try testing.expectEqual(
        Result.invalid_value,
        continuation_buf(t, null, 0, &written),
    );
    vt_write(t, "m", 1);
    try testing.expectEqual(
        Result.out_of_space,
        continuation_buf(t, null, 0, &written),
    );
    try testing.expectEqual(@as(usize, 0), written);
}
test "continuation internal allocation and restoration" {
    var source: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &source,
        80,
        24,
    ));
    defer free(source);
    try testEnableContinuation(source);
    vt_write(source, "\x1b[31", 4);
    const alloc = lib.alloc.default(&lib.alloc.test_allocator);
    const bytes = try continuationAllocIo(source, alloc, false);
    defer alloc.free(bytes);
    try testing.expectEqualStrings("\x1b[31", bytes);
    var restored: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &restored,
        80,
        24,
    ));
    defer free(restored);
    try testEnableContinuation(restored);
    try restoreContinuation(restored, bytes);
    const reexported = try continuationAllocIo(restored, alloc, false);
    defer alloc.free(reexported);
    try testing.expectEqualStrings(bytes, reexported);
    var invalid: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &invalid,
        80,
        24,
    ));
    defer free(invalid);
    try testEnableContinuation(invalid);
    try testing.expectError(
        error.InvalidContinuation,
        restoreContinuation(invalid, "A"),
    );
}
test "set scrollback limits" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        3,
    ));
    defer free(t);
    const primary = t.?.terminal.screens.get(.primary).?;
    const max_bytes: usize = 0;
    try testing.expectEqual(
        Result.success,
        set(t, .scrollback_max_bytes, &max_bytes),
    );
    try testing.expectEqual(
        @as(usize, 0),
        primary.pages.limits.bytes.explicit,
    );
    try testing.expect(primary.no_scrollback);
    try testing.expectEqual(
        Result.success,
        set(t, .scrollback_max_bytes, null),
    );
    try testing.expectEqual(
        std.math.maxInt(usize),
        primary.pages.limits.bytes.explicit,
    );
    try testing.expect(!primary.no_scrollback);
    const max_lines: usize = 12;
    try testing.expectEqual(
        Result.success,
        set(t, .scrollback_max_lines, &max_lines),
    );
    try testing.expectEqual(
        max_lines,
        primary.pages.limits.lines.explicit,
    );
    try testing.expectEqual(
        Result.success,
        set(t, .scrollback_max_lines, null),
    );
    try testing.expectEqual(
        std.math.maxInt(usize),
        primary.pages.limits.lines.explicit,
    );
}
test "free null" {
    free(null);
}
test "scroll_viewport" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        5,
        2,
    ));
    defer free(t);
    const zt = t.?.terminal;
    var viewport_active: bool = false;
    try testing.expectEqual(Result.success, get(t, .viewport_active, @ptrCast(&viewport_active)));
    try testing.expect(viewport_active);
    vt_write(t, "hello", 5);
    vt_write(t, "\x1bD\x1bD\x1bD", 6);
    {
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
    scroll_viewport(t, .{ .tag = .top, .value = undefined });
    try testing.expectEqual(Result.success, get(t, .viewport_active, @ptrCast(&viewport_active)));
    try testing.expect(!viewport_active);
    {
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello", str);
    }
    scroll_viewport(t, .{ .tag = .bottom, .value = undefined });
    try testing.expectEqual(Result.success, get(t, .viewport_active, @ptrCast(&viewport_active)));
    try testing.expect(viewport_active);
    {
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
    scroll_viewport(t, .{ .tag = .delta, .value = .{ .delta = -3 } });
    try testing.expectEqual(Result.success, get(t, .viewport_active, @ptrCast(&viewport_active)));
    try testing.expect(!viewport_active);
    {
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello", str);
    }
}
test "scroll_viewport row" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        5,
        2,
    ));
    defer free(t);
    const zt = t.?.terminal;
    vt_write(t, "1\r\n2\r\n3\r\n4", 10);
    var viewport_active: bool = false;
    try testing.expectEqual(Result.success, get(t, .viewport_active, @ptrCast(&viewport_active)));
    try testing.expect(viewport_active);
    scroll_viewport(t, .{ .tag = .row, .value = .{ .row = 0 } });
    try testing.expectEqual(Result.success, get(t, .viewport_active, @ptrCast(&viewport_active)));
    try testing.expect(!viewport_active);
    {
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1\n2", str);
    }
    scroll_viewport(t, .{ .tag = .row, .value = .{ .row = 1 } });
    {
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("2\n3", str);
    }
    var scrollbar_data: TerminalScrollbar = undefined;
    try testing.expectEqual(Result.success, get(t, .scrollbar, @ptrCast(&scrollbar_data)));
    try testing.expectEqual(@as(u64, 4), scrollbar_data.total);
    try testing.expectEqual(@as(u64, 1), scrollbar_data.offset);
    try testing.expectEqual(@as(u64, 2), scrollbar_data.len);
    scroll_viewport(t, .{ .tag = .row, .value = .{ .row = 9999 } });
    try testing.expectEqual(Result.success, get(t, .viewport_active, @ptrCast(&viewport_active)));
    try testing.expect(viewport_active);
    {
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("3\n4", str);
    }
    try testing.expectEqual(Result.success, get(t, .scrollbar, @ptrCast(&scrollbar_data)));
    try testing.expectEqual(@as(u64, 2), scrollbar_data.offset);
}
test "scroll_viewport row alt screen" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        5,
        2,
    ));
    defer free(t);
    vt_write(t, "\x1b[?1049h", 8);
    var screen: TerminalScreen = undefined;
    try testing.expectEqual(Result.success, get(t, .active_screen, @ptrCast(&screen)));
    try testing.expectEqual(TerminalScreen.alternate, screen);
    var viewport_active: bool = false;
    scroll_viewport(t, .{ .tag = .row, .value = .{ .row = 0 } });
    try testing.expectEqual(Result.success, get(t, .viewport_active, @ptrCast(&viewport_active)));
    try testing.expect(viewport_active);
    scroll_viewport(t, .{ .tag = .row, .value = .{ .row = 9999 } });
    try testing.expectEqual(Result.success, get(t, .viewport_active, @ptrCast(&viewport_active)));
    try testing.expect(viewport_active);
    var scrollbar_data: TerminalScrollbar = undefined;
    try testing.expectEqual(Result.success, get(t, .scrollbar, @ptrCast(&scrollbar_data)));
    try testing.expectEqual(@as(u64, 2), scrollbar_data.total);
    try testing.expectEqual(@as(u64, 0), scrollbar_data.offset);
    try testing.expectEqual(@as(u64, 2), scrollbar_data.len);
}
test "scroll_viewport delta_prompt" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        2,
    ));
    defer free(t);
    const transcript =
        "\x1b]133;P;k=i\x07p1\r\n" ++
        "\x1b]133;B\x07cmd1\r\n" ++
        "\x1b]133;C\x07out1\r\n" ++
        "\x1b]133;P;k=i\x07p2\r\n" ++
        "\x1b]133;B\x07cmd2\r\n" ++
        "\x1b]133;C\x07out2\r\n" ++
        "\x1b]133;P;k=i\x07p3\r\n" ++
        "\x1b]133;B\x07cmd3\r\n" ++
        "\x1b]133;C\x07out3\r\n" ++
        "\x1b]133;P;k=i\x07p4";
    vt_write(t, transcript, transcript.len);
    var scrollbar_data: TerminalScrollbar = undefined;
    scroll_viewport(t, .{ .tag = .delta_prompt, .value = .{ .delta_prompt = -1 } });
    try testing.expectEqual(Result.success, get(t, .scrollbar, @ptrCast(&scrollbar_data)));
    try testing.expectEqual(@as(u64, 6), scrollbar_data.offset);
    scroll_viewport(t, .{ .tag = .delta_prompt, .value = .{ .delta_prompt = -1 } });
    try testing.expectEqual(Result.success, get(t, .scrollbar, @ptrCast(&scrollbar_data)));
    try testing.expectEqual(@as(u64, 3), scrollbar_data.offset);
    scroll_viewport(t, .{ .tag = .delta_prompt, .value = .{ .delta_prompt = 1 } });
    try testing.expectEqual(Result.success, get(t, .scrollbar, @ptrCast(&scrollbar_data)));
    try testing.expectEqual(@as(u64, 6), scrollbar_data.offset);
    scroll_viewport(t, .{ .tag = .delta_prompt, .value = .{ .delta_prompt = std.math.minInt(isize) } });
    try testing.expectEqual(Result.success, get(t, .scrollbar, @ptrCast(&scrollbar_data)));
    try testing.expectEqual(@as(u64, 0), scrollbar_data.offset);
    scroll_viewport(t, .{ .tag = .delta_prompt, .value = .{ .delta_prompt = std.math.maxInt(isize) } });
    try testing.expectEqual(Result.success, get(t, .scrollbar, @ptrCast(&scrollbar_data)));
    try testing.expectEqual(@as(u64, 8), scrollbar_data.offset);
    scroll_viewport(t, .{ .tag = .delta_prompt, .value = .{ .delta_prompt = 0 } });
    try testing.expectEqual(Result.success, get(t, .scrollbar, @ptrCast(&scrollbar_data)));
    try testing.expectEqual(@as(u64, 8), scrollbar_data.offset);
}
test "scroll_viewport delta_prompt continuation" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        2,
    ));
    defer free(t);
    const transcript =
        "\x1b]133;P;k=i\x07p1\r\n" ++
        "\x1b]133;P;k=c\x07p1-continued\r\n" ++
        "\x1b]133;B\x07cmd1\r\n" ++
        "\x1b]133;C\x07out1\r\n" ++
        "\x1b]133;P;k=i\x07p2\r\n" ++
        "\x1b]133;B\x07cmd2\r\n" ++
        "\x1b]133;C\x07out2";
    vt_write(t, transcript, transcript.len);
    scroll_viewport(t, .{ .tag = .row, .value = .{ .row = 0 } });
    scroll_viewport(t, .{ .tag = .delta_prompt, .value = .{ .delta_prompt = 1 } });
    var scrollbar_data: TerminalScrollbar = undefined;
    try testing.expectEqual(Result.success, get(t, .scrollbar, @ptrCast(&scrollbar_data)));
    try testing.expectEqual(@as(u64, 4), scrollbar_data.offset);
}
test "scroll_viewport delta_prompt final continuation snaps to active" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        3,
    ));
    defer free(t);
    const transcript =
        "\x1b]133;P;k=i\x07prompt\r\n" ++
        "\x1b]133;P;k=c\x07continued\r\n" ++
        "continued\r\ncontinued\r\ncontinued\r\ncontinued\r\ncontinued";
    vt_write(t, transcript, transcript.len);
    scroll_viewport(t, .{ .tag = .row, .value = .{ .row = 1 } });
    var scrollbar_data: TerminalScrollbar = undefined;
    try testing.expectEqual(Result.success, get(t, .scrollbar, @ptrCast(&scrollbar_data)));
    try testing.expectEqual(@as(u64, 1), scrollbar_data.offset);
    scroll_viewport(t, .{ .tag = .delta_prompt, .value = .{ .delta_prompt = 1 } });
    try testing.expectEqual(Result.success, get(t, .scrollbar, @ptrCast(&scrollbar_data)));
    try testing.expectEqual(@as(u64, 4), scrollbar_data.offset);
}
test "scroll_viewport delta_prompt no markers and alternate screen" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        2,
    ));
    defer free(t);
    const history = "one\r\ntwo\r\nthree\r\nfour";
    vt_write(t, history, history.len);
    scroll_viewport(t, .{ .tag = .row, .value = .{ .row = 0 } });
    scroll_viewport(t, .{ .tag = .delta_prompt, .value = .{ .delta_prompt = 1 } });
    var scrollbar_data: TerminalScrollbar = undefined;
    try testing.expectEqual(Result.success, get(t, .scrollbar, @ptrCast(&scrollbar_data)));
    try testing.expectEqual(@as(u64, 0), scrollbar_data.offset);
    const alternate_screen = "\x1b[?1049h";
    vt_write(t, alternate_screen, alternate_screen.len);
    scroll_viewport(t, .{ .tag = .delta_prompt, .value = .{ .delta_prompt = -1 } });
    try testing.expectEqual(Result.success, get(t, .scrollbar, @ptrCast(&scrollbar_data)));
    try testing.expectEqual(@as(u64, 0), scrollbar_data.offset);
    try testing.expectEqual(@as(u64, 2), scrollbar_data.total);
}
test "get memory_usage" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var fresh: TerminalMemoryUsage = .{};
    try testing.expectEqual(Result.success, get(t, .memory_usage, @ptrCast(&fresh)));
    try testing.expectEqual(@sizeOf(TerminalMemoryUsage), fresh.size);
    try testing.expectEqual(terminal_mem.canReclaim(.strict), fresh.compression_supported);
    try testing.expect(fresh.primary_pages > 0);
    try testing.expect(fresh.primary_virtual_bytes > 0);
    try testing.expect(fresh.primary_resident_bytes <= fresh.primary_virtual_bytes);
    try testing.expectEqual(@as(u64, 0), fresh.primary_compressed_pages);
    try testing.expectEqual(@as(u64, 0), fresh.primary_compressed_bytes);
    try testing.expectEqual(@as(u64, 0), fresh.primary_image_bytes);
    try testing.expectEqual(@as(u64, 0), fresh.alternate_pages);
    try testing.expectEqual(@as(u64, 0), fresh.alternate_virtual_bytes);
    try testing.expectEqual(@as(u64, 0), fresh.alternate_resident_bytes);
    try testing.expectEqual(@as(u64, 0), fresh.alternate_compressed_pages);
    try testing.expectEqual(@as(u64, 0), fresh.alternate_compressed_bytes);
    try testing.expectEqual(@as(u64, 0), fresh.alternate_image_bytes);
    const line = "repeated and compressible terminal history\r\n";
    const repeat = 4_000;
    const input = try testing.allocator.alloc(u8, line.len * repeat);
    defer testing.allocator.free(input);
    for (0..repeat) |i|
        @memcpy(input[i * line.len ..][0..line.len], line);
    vt_write(t, input.ptr, input.len);
    var history: TerminalMemoryUsage = .{};
    try testing.expectEqual(Result.success, get(t, .memory_usage, @ptrCast(&history)));
    try testing.expect(history.primary_pages > fresh.primary_pages);
    try testing.expect(history.primary_resident_bytes > fresh.primary_resident_bytes);
    var compression_result: CompressionResult = undefined;
    try testing.expectEqual(
        Result.success,
        compress(t, @intFromEnum(CompressionMode.full), &compression_result),
    );
    try testing.expectEqual(
        history.compression_supported,
        compression_result == .complete,
    );
    var compressed: TerminalMemoryUsage = .{};
    try testing.expectEqual(Result.success, get(t, .memory_usage, @ptrCast(&compressed)));
    try testing.expectEqual(history.primary_pages, compressed.primary_pages);
    try testing.expectEqual(history.primary_virtual_bytes, compressed.primary_virtual_bytes);
    if (compressed.compression_supported) {
        try testing.expect(compressed.primary_compressed_pages > 0);
        try testing.expect(compressed.primary_compressed_bytes > 0);
        try testing.expect(compressed.primary_resident_bytes < history.primary_resident_bytes);
    } else {
        try testing.expectEqual(@as(u64, 0), compressed.primary_compressed_pages);
    }
    var again: TerminalMemoryUsage = .{};
    try testing.expectEqual(Result.success, get(t, .memory_usage, @ptrCast(&again)));
    try testing.expectEqual(compressed, again);
    if (comptime build_options.kitty_graphics) {
        const transmit = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;////////\x1b\\";
        vt_write(t, transmit.ptr, transmit.len);
        var images: TerminalMemoryUsage = .{};
        try testing.expectEqual(Result.success, get(t, .memory_usage, @ptrCast(&images)));
        try testing.expect(images.primary_image_bytes > 0);
        const delete = "\x1b_Ga=d,d=I,i=1\x1b\\";
        vt_write(t, delete.ptr, delete.len);
        try testing.expectEqual(Result.success, get(t, .memory_usage, @ptrCast(&images)));
        try testing.expectEqual(@as(u64, 0), images.primary_image_bytes);
    }
    vt_write(t, "\x1b[?1049h", 8);
    var alternate: TerminalMemoryUsage = .{};
    try testing.expectEqual(Result.success, get(t, .memory_usage, @ptrCast(&alternate)));
    try testing.expect(alternate.alternate_pages > 0);
    try testing.expect(alternate.alternate_virtual_bytes > 0);
    try testing.expect(alternate.alternate_resident_bytes > 0);
    try testing.expect(alternate.alternate_resident_bytes <= alternate.alternate_virtual_bytes);
    try testing.expectEqual(compressed.primary_pages, alternate.primary_pages);
}
test "get memory_usage size rule" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var small: TerminalMemoryUsage = .{
        .size = @sizeOf(TerminalMemoryUsage) - 1,
        .primary_pages = 1234,
    };
    try testing.expectEqual(Result.invalid_value, get(t, .memory_usage, @ptrCast(&small)));
    try testing.expectEqual(@sizeOf(TerminalMemoryUsage) - 1, small.size);
    try testing.expectEqual(@as(u64, 1234), small.primary_pages);
    const Larger = extern struct {
        usage: TerminalMemoryUsage,
        extra: u64,
    };
    var large: Larger = .{
        .usage = .{ .size = @sizeOf(Larger) },
        .extra = 0xDEADBEEF,
    };
    try testing.expectEqual(Result.success, get(t, .memory_usage, @ptrCast(&large)));
    try testing.expectEqual(@sizeOf(Larger), large.usage.size);
    try testing.expect(large.usage.primary_pages > 0);
    try testing.expectEqual(@as(u64, 0xDEADBEEF), large.extra);
}
test "scroll_viewport null" {
    scroll_viewport(null, .{ .tag = .top, .value = undefined });
    scroll_viewport(null, .{ .tag = .row, .value = .{ .row = 1 } });
}
test "compression invalid arguments" {
    var activity: u64 = undefined;
    var compression_result: CompressionResult = undefined;
    try testing.expectEqual(
        Result.invalid_value,
        compression_activity(null, &activity),
    );
    try testing.expectEqual(
        Result.invalid_value,
        compress(null, @intFromEnum(CompressionMode.incremental), &compression_result),
    );
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    try testing.expectEqual(
        Result.invalid_value,
        compression_activity(t, null),
    );
    try testing.expectEqual(
        Result.invalid_value,
        compress(t, @intFromEnum(CompressionMode.incremental), null),
    );
    try testing.expectEqual(
        Result.invalid_value,
        compress(t, -1, &compression_result),
    );
}
test "compression activity and incremental scheduling" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var initial_activity: u64 = undefined;
    try testing.expectEqual(
        Result.success,
        compression_activity(t, &initial_activity),
    );
    const line = "repeated and compressible terminal history\r\n";
    const repeat = 4_000;
    const input = try testing.allocator.alloc(u8, line.len * repeat);
    defer testing.allocator.free(input);
    for (0..repeat) |i|
        @memcpy(input[i * line.len ..][0..line.len], line);
    vt_write(t, input.ptr, input.len);
    var activity: u64 = undefined;
    try testing.expectEqual(
        Result.success,
        compression_activity(t, &activity),
    );
    try testing.expect(activity != initial_activity);
    var compression_result: CompressionResult = undefined;
    for (0..1_000) |_| {
        try testing.expectEqual(
            Result.success,
            compress(
                t,
                @intFromEnum(CompressionMode.incremental),
                &compression_result,
            ),
        );
        switch (compression_result) {
            .pending => continue,
            .complete => break,
            .unsupported => unreachable,
        }
    } else return error.TestUnexpectedResult;
    var final_activity: u64 = undefined;
    try testing.expectEqual(
        Result.success,
        compression_activity(t, &final_activity),
    );
    try testing.expectEqual(activity, final_activity);
    try testing.expectEqual(
        Result.success,
        compress(t, @intFromEnum(CompressionMode.full), &compression_result),
    );
    try testing.expectEqual(CompressionResult.complete, compression_result);
}
test "reset" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    vt_write(t, "Hello", 5);
    reset(t);
    const str = try t.?.terminal.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("", str);
}
test "reset null" {
    reset(null);
}
test "resize" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    try testing.expectEqual(Result.success, resize(t, 40, 12, 9, 18));
    try testing.expectEqual(40, t.?.terminal.cols);
    try testing.expectEqual(12, t.?.terminal.rows);
}
test "resize null" {
    try testing.expectEqual(Result.invalid_value, resize(null, 80, 24, 9, 18));
}
test "resize invalid value" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    try testing.expectEqual(Result.invalid_value, resize(t, 0, 24, 9, 18));
    try testing.expectEqual(Result.invalid_value, resize(t, 80, 0, 9, 18));
}
test "resize shrinks both axes with cursor at bottom" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const move = "\x1b[24;1H";
    vt_write(t, move, move.len);
    try testing.expectEqual(Result.success, resize(t, 79, 23, 8, 16));
    try testing.expectEqual(79, t.?.terminal.cols);
    try testing.expectEqual(23, t.?.terminal.rows);
}
test "set and get mode" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const cursor_visible: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 25, .ansi = false });
    var config: ModeConfig = .{ .mode = cursor_visible, .value = undefined };
    try testing.expectEqual(Result.success, get(t, .mode, @ptrCast(&config)));
    try testing.expect(config.value);
    config.value = false;
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    try testing.expectEqual(Result.success, get(t, .mode, @ptrCast(&config)));
    try testing.expect(!config.value);
    const insert: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 4, .ansi = true });
    config.mode = insert;
    try testing.expectEqual(Result.success, get(t, .mode, @ptrCast(&config)));
    try testing.expect(!config.value);
    config.value = true;
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    try testing.expectEqual(Result.success, get(t, .mode, @ptrCast(&config)));
    try testing.expect(config.value);
}
test "set mode default updates current and reset value" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const tag: modes.ModeTag.Backing = @bitCast(modes.ModeTag{
        .value = 2027,
        .ansi = false,
    });
    var config: ModeConfig = .{ .mode = tag, .value = true };
    try testing.expectEqual(Result.success, set(
        t,
        .mode_default,
        @ptrCast(&config),
    ));
    try testing.expect(t.?.terminal.modes.get(.grapheme_cluster));
    try testing.expect(t.?.terminal.modes.default.grapheme_cluster);
    config.value = false;
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    try testing.expect(!t.?.terminal.modes.get(.grapheme_cluster));
    try testing.expect(t.?.terminal.modes.default.grapheme_cluster);
    config.value = true;
    try testing.expectEqual(Result.success, set(
        t,
        .mode_default,
        @ptrCast(&config),
    ));
    try testing.expect(t.?.terminal.modes.get(.grapheme_cluster));
    config.value = false;
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    vt_write(t, "\x1bc", 2);
    try testing.expect(t.?.terminal.modes.get(.grapheme_cluster));
    config.value = false;
    try testing.expectEqual(Result.success, set(
        t,
        .mode_default,
        @ptrCast(&config),
    ));
    try testing.expect(!t.?.terminal.modes.get(.grapheme_cluster));
    try testing.expect(!t.?.terminal.modes.default.grapheme_cluster);
}
test "set mode default validates configuration" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    try testing.expectEqual(Result.invalid_value, set(
        t,
        .mode_default,
        null,
    ));
    var config: ModeConfig = .{
        .mode = @bitCast(modes.ModeTag{ .value = 9999, .ansi = false }),
        .value = true,
    };
    try testing.expectEqual(Result.invalid_value, set(
        t,
        .mode_default,
        @ptrCast(&config),
    ));
    config.mode = @bitCast(modes.ModeTag{ .value = 1047, .ansi = false });
    try testing.expectEqual(Result.invalid_value, set(
        t,
        .mode_default,
        @ptrCast(&config),
    ));
}
test "set and get mode null" {
    const tag: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 25, .ansi = false });
    var config: ModeConfig = .{ .mode = tag, .value = true };
    try testing.expectEqual(Result.invalid_value, set(null, .mode, @ptrCast(&config)));
    try testing.expectEqual(Result.invalid_value, get(null, .mode, @ptrCast(&config)));
}
test "set and get mode validate configuration" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    try testing.expectEqual(Result.invalid_value, set(t, .mode, null));
    try testing.expectEqual(Result.invalid_value, get(t, .mode, null));
    var config: ModeConfig = .{
        .mode = @bitCast(modes.ModeTag{ .value = 9999, .ansi = false }),
        .value = true,
    };
    try testing.expectEqual(Result.invalid_value, set(t, .mode, @ptrCast(&config)));
    try testing.expectEqual(Result.invalid_value, get(t, .mode, @ptrCast(&config)));
}
test "vt_write" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    vt_write(t, "Hello", 5);
    const str = try t.?.terminal.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Hello", str);
}
test "vt_write_until_ground result contract" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var consumed: usize = 99;
    const untouched = "unprocessed";
    try testing.expectEqual(
        Result.success,
        vt_write_until_ground(t, untouched, untouched.len, &consumed),
    );
    try testing.expectEqual(@as(usize, 0), consumed);
    vt_write(t, "\x1b[31", 4);
    const input = "mABC\x1b[";
    try testing.expectEqual(
        Result.success,
        vt_write_until_ground(t, input, input.len, &consumed),
    );
    try testing.expectEqual(@as(usize, 1), consumed);
    try testing.expect(t.?.stream.ground());
    var str = try t.?.terminal.plainString(testing.allocator);
    try testing.expectEqualStrings("", str);
    testing.allocator.free(str);
    vt_write(t, input.ptr + consumed, input.len - consumed);
    str = try t.?.terminal.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("ABC", str);
    try testing.expect(!t.?.stream.ground());
    try testing.expectEqual(
        Result.no_value,
        vt_write_until_ground(t, "123", 3, &consumed),
    );
    try testing.expectEqual(@as(usize, 3), consumed);
    try testing.expect(!t.?.stream.ground());
    try testing.expectEqual(
        Result.success,
        vt_write_until_ground(t, "m", 1, &consumed),
    );
    try testing.expectEqual(@as(usize, 1), consumed);
    try testing.expect(t.?.stream.ground());
}
test "vt_write_until_ground handles UTF-8 and abort boundaries" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var ground: bool = false;
    try testing.expectEqual(
        Result.success,
        get(t, .vt_ground, @ptrCast(&ground)),
    );
    try testing.expect(ground);
    vt_write(t, &.{0xF0}, 1);
    try testing.expectEqual(
        Result.success,
        get(t, .vt_ground, @ptrCast(&ground)),
    );
    try testing.expect(!ground);
    const utf8_suffix = [_]u8{ 0x9F, 0x98, 0x84 };
    var consumed: usize = 99;
    try testing.expectEqual(
        Result.success,
        vt_write_until_ground(t, &utf8_suffix, utf8_suffix.len, &consumed),
    );
    try testing.expectEqual(utf8_suffix.len, consumed);
    try testing.expect(t.?.stream.ground());
    vt_write(t, &.{ 0xE0, 0xA0 }, 2);
    try testing.expectEqual(
        Result.success,
        vt_write_until_ground(t, "A", 1, &consumed),
    );
    try testing.expectEqual(@as(usize, 1), consumed);
    try testing.expect(t.?.stream.ground());
    vt_write(t, "\x1b[123", 5);
    try testing.expectEqual(
        Result.success,
        vt_write_until_ground(t, &.{0x18}, 1, &consumed),
    );
    try testing.expectEqual(@as(usize, 1), consumed);
    try testing.expect(t.?.stream.ground());
}
test "vt_write_until_ground invokes effects only for consumed input" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var bell_count: usize = 0;
        fn bell(_: Terminal, _: ?*anyopaque) callconv(lib.calling_conv) void {
            bell_count += 1;
        }
    };
    S.bell_count = 0;
    try testing.expectEqual(Result.success, set(t, .bell, @ptrCast(&S.bell)));
    vt_write(t, "\x1b[31", 4);
    const input = "m\x07";
    var consumed: usize = 99;
    try testing.expectEqual(
        Result.success,
        vt_write_until_ground(t, input, input.len, &consumed),
    );
    try testing.expectEqual(@as(usize, 1), consumed);
    try testing.expectEqual(@as(usize, 0), S.bell_count);
    vt_write(t, input.ptr + consumed, input.len - consumed);
    try testing.expectEqual(@as(usize, 1), S.bell_count);
}
test "vt_write_until_ground validates arguments" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var consumed: usize = 99;
    try testing.expectEqual(
        Result.invalid_value,
        vt_write_until_ground(null, "x", 1, &consumed),
    );
    try testing.expectEqual(@as(usize, 0), consumed);
    consumed = 99;
    try testing.expectEqual(
        Result.invalid_value,
        vt_write_until_ground(t, null, 1, &consumed),
    );
    try testing.expectEqual(@as(usize, 0), consumed);
    try testing.expectEqual(
        Result.invalid_value,
        vt_write_until_ground(t, "", 0, null),
    );
    vt_write(t, "\x1b[", 2);
    consumed = 99;
    try testing.expectEqual(
        Result.no_value,
        vt_write_until_ground(t, null, 0, &consumed),
    );
    try testing.expectEqual(@as(usize, 0), consumed);
}
test "vt_write split escape sequence" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    vt_write(t, "Hello \x1b", 7);
    vt_write(t, "[1mBold\x1b[0m", 10);
    const str = try t.?.terminal.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Hello Bold", str);
}
test "vt_write split combining mark after base at right edge" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        2,
        2,
    ));
    defer free(t);
    vt_write(t, "xå", 3);
    vt_write(t, "\xcc\xb2", 2);
    const str = try t.?.terminal.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("xå̲", str);
}
test "get cols and rows" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var cols: size.CellCountInt = undefined;
    var rows: size.CellCountInt = undefined;
    try testing.expectEqual(Result.success, get(t, .cols, @ptrCast(&cols)));
    try testing.expectEqual(Result.success, get(t, .rows, @ptrCast(&rows)));
    try testing.expectEqual(80, cols);
    try testing.expectEqual(24, rows);
}
test "get cursor position" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    vt_write(t, "Hello", 5);
    var x: size.CellCountInt = undefined;
    var y: size.CellCountInt = undefined;
    try testing.expectEqual(Result.success, get(t, .cursor_x, @ptrCast(&x)));
    try testing.expectEqual(Result.success, get(t, .cursor_y, @ptrCast(&y)));
    try testing.expectEqual(5, x);
    try testing.expectEqual(0, y);
}
test "get vt_processing_error" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var processing_error: bool = true;
    try testing.expectEqual(Result.success, get(
        t,
        .vt_processing_error,
        @ptrCast(&processing_error),
    ));
    try testing.expect(!processing_error);
    {
        const alloc = t.?.terminal.screens.active.alloc;
        t.?.terminal.screens.active.alloc = testing.failing_allocator;
        defer t.?.terminal.screens.active.alloc = alloc;
        const input = "\x1B]2;unavailable\x1B\\";
        vt_write(t, input, input.len);
    }
    try testing.expectEqual(Result.success, get(
        t,
        .vt_processing_error,
        @ptrCast(&processing_error),
    ));
    try testing.expect(processing_error);
    reset(t);
    try testing.expectEqual(Result.success, get(
        t,
        .vt_processing_error,
        @ptrCast(&processing_error),
    ));
    try testing.expect(processing_error);
}
test "get null" {
    var cols: size.CellCountInt = undefined;
    try testing.expectEqual(Result.invalid_value, get(null, .cols, @ptrCast(&cols)));
}
test "get cursor_visible" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var visible: bool = undefined;
    try testing.expectEqual(Result.success, get(t, .cursor_visible, @ptrCast(&visible)));
    try testing.expect(visible);
    var config: ModeConfig = .{
        .mode = @bitCast(modes.ModeTag{ .value = 25, .ansi = false }),
        .value = false,
    };
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    try testing.expectEqual(Result.success, get(t, .cursor_visible, @ptrCast(&visible)));
    try testing.expect(!visible);
}
test "get cursor_at_prompt" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var at_prompt: bool = undefined;
    try testing.expectEqual(Result.success, get(t, .cursor_at_prompt, @ptrCast(&at_prompt)));
    try testing.expect(!at_prompt);
    const prompt_start = "\x1b]133;A\x07";
    vt_write(t, prompt_start, prompt_start.len);
    try testing.expectEqual(Result.success, get(t, .cursor_at_prompt, @ptrCast(&at_prompt)));
    try testing.expect(at_prompt);
    const alternate_screen = "\x1b[?1049h";
    vt_write(t, alternate_screen, alternate_screen.len);
    try testing.expectEqual(Result.success, get(t, .cursor_at_prompt, @ptrCast(&at_prompt)));
    try testing.expect(!at_prompt);
}
test "get active_screen" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var screen: TerminalScreen = undefined;
    try testing.expectEqual(Result.success, get(t, .active_screen, @ptrCast(&screen)));
    try testing.expectEqual(.primary, screen);
}
test "get kitty_keyboard_flags" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var flags: u8 = undefined;
    try testing.expectEqual(Result.success, get(t, .kitty_keyboard_flags, @ptrCast(&flags)));
    try testing.expectEqual(0, flags);
    vt_write(t, "\x1b[>3u", 5);
    try testing.expectEqual(Result.success, get(t, .kitty_keyboard_flags, @ptrCast(&flags)));
    try testing.expectEqual(3, flags);
}
test "get mouse_tracking" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var tracking: bool = undefined;
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(!tracking);
    var config: ModeConfig = .{
        .mode = @bitCast(modes.ModeTag{ .value = 9, .ansi = false }),
        .value = true,
    };
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(tracking);
    config.value = false;
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    config = .{
        .mode = @bitCast(modes.ModeTag{ .value = 1000, .ansi = false }),
        .value = true,
    };
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(tracking);
    config.value = false;
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    config = .{
        .mode = @bitCast(modes.ModeTag{ .value = 1002, .ansi = false }),
        .value = true,
    };
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(tracking);
    config.value = false;
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    config = .{
        .mode = @bitCast(modes.ModeTag{ .value = 1003, .ansi = false }),
        .value = true,
    };
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(tracking);
    config.value = false;
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&config)));
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(!tracking);
}
test "get total_rows" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var total: usize = undefined;
    try testing.expectEqual(Result.success, get(t, .total_rows, @ptrCast(&total)));
    try testing.expect(total >= 24);
}
test "get scrollback_rows" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        3,
    ));
    defer free(t);
    var scrollback: usize = undefined;
    try testing.expectEqual(Result.success, get(t, .scrollback_rows, @ptrCast(&scrollback)));
    try testing.expectEqual(@as(usize, 0), scrollback);
    vt_write(t, "line1\r\nline2\r\nline3\r\nline4\r\nline5\r\n", 34);
    try testing.expectEqual(Result.success, get(t, .scrollback_rows, @ptrCast(&scrollback)));
    try testing.expectEqual(@as(usize, 2), scrollback);
}
test "get configured scrollback limits" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        3,
    ));
    defer free(t);
    var value: usize = undefined;
    try testing.expectEqual(
        Result.success,
        get(t, .scrollback_max_bytes, @ptrCast(&value)),
    );
    try testing.expectEqual(@as(usize, 10_000), value);
    try testing.expectEqual(
        Result.no_value,
        get(t, .scrollback_max_lines, @ptrCast(&value)),
    );
    const max_bytes: usize = 0;
    const max_lines: usize = 12;
    try testing.expectEqual(
        Result.success,
        set(t, .scrollback_max_bytes, &max_bytes),
    );
    try testing.expectEqual(
        Result.success,
        set(t, .scrollback_max_lines, &max_lines),
    );
    try testing.expectEqual(
        Result.success,
        get(t, .scrollback_max_bytes, @ptrCast(&value)),
    );
    try testing.expectEqual(max_bytes, value);
    try testing.expectEqual(
        Result.success,
        get(t, .scrollback_max_lines, @ptrCast(&value)),
    );
    try testing.expectEqual(max_lines, value);
    vt_write(t, "\x1b[?1049h", 8);
    try testing.expectEqual(
        Result.success,
        get(t, .scrollback_max_bytes, @ptrCast(&value)),
    );
    try testing.expectEqual(max_bytes, value);
    try testing.expectEqual(
        Result.success,
        get(t, .scrollback_max_lines, @ptrCast(&value)),
    );
    try testing.expectEqual(max_lines, value);
    try testing.expectEqual(
        Result.success,
        set(t, .scrollback_max_bytes, null),
    );
    try testing.expectEqual(
        Result.success,
        set(t, .scrollback_max_lines, null),
    );
    try testing.expectEqual(
        Result.no_value,
        get(t, .scrollback_max_bytes, @ptrCast(&value)),
    );
    try testing.expectEqual(
        Result.no_value,
        get(t, .scrollback_max_lines, @ptrCast(&value)),
    );
}
test "get invalid" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    try testing.expectEqual(Result.invalid_value, get(t, .invalid, null));
}
test "set default cursor style and blink" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var default_style: TerminalCursorStyle = .bar;
    var default_blink = true;
    try testing.expectEqual(Result.success, set(t, .default_cursor_style, @ptrCast(&default_style)));
    try testing.expectEqual(Result.success, set(t, .default_cursor_blink, @ptrCast(&default_blink)));
    try testing.expectEqual(Screen.CursorStyle.bar, t.?.terminal.screens.active.cursor.cursor_style);
    try testing.expect(t.?.terminal.modes.get(.cursor_blinking));
    vt_write(t, "\x1b[2 q", 5);
    try testing.expectEqual(Screen.CursorStyle.block, t.?.terminal.screens.active.cursor.cursor_style);
    try testing.expect(!t.?.terminal.modes.get(.cursor_blinking));
    default_style = .underline;
    try testing.expectEqual(Result.success, set(t, .default_cursor_style, @ptrCast(&default_style)));
    try testing.expectEqual(Screen.CursorStyle.block, t.?.terminal.screens.active.cursor.cursor_style);
    try testing.expect(!t.?.terminal.modes.get(.cursor_blinking));
    vt_write(t, "\x1b[0 q", 5);
    try testing.expectEqual(Screen.CursorStyle.underline, t.?.terminal.screens.active.cursor.cursor_style);
    try testing.expect(t.?.terminal.modes.get(.cursor_blinking));
    vt_write(t, "\x1b[2 q", 5);
    reset(t);
    try testing.expectEqual(Screen.CursorStyle.underline, t.?.terminal.screens.active.cursor.cursor_style);
    try testing.expect(t.?.terminal.modes.get(.cursor_blinking));
}
test "set resize pull scrollback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    try testing.expect(t.?.terminal.flags.resize_pull_scrollback);
    const disabled = false;
    try testing.expectEqual(Result.success, set(t, .resize_pull_scrollback, &disabled));
    try testing.expect(!t.?.terminal.flags.resize_pull_scrollback);
    try testing.expectEqual(Result.success, set(t, .resize_pull_scrollback, null));
    try testing.expect(t.?.terminal.flags.resize_pull_scrollback);
}
test "set and get selection" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    vt_write(t, "Hello", 5);
    var start_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 0, .y = 0 } },
    }, &start_ref));
    var end_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 4, .y = 0 } },
    }, &end_ref));
    var out: selection_c.CSelection = undefined;
    try testing.expectEqual(Result.no_value, get(t, .selection, @ptrCast(&out)));
    const sel: selection_c.CSelection = .{
        .start = start_ref,
        .end = end_ref,
        .rectangle = true,
    };
    try testing.expectEqual(Result.success, set(t, .selection, @ptrCast(&sel)));
    try testing.expect(t.?.terminal.screens.active.selection.?.tracked());
    try testing.expectEqual(Result.success, get(t, .selection, @ptrCast(&out)));
    try testing.expect(out.start.toPin().?.eql(start_ref.toPin().?));
    try testing.expect(out.end.toPin().?.eql(end_ref.toPin().?));
    try testing.expect(out.rectangle);
    try testing.expectEqual(Result.success, set(t, .selection, null));
    try testing.expect(t.?.terminal.screens.active.selection == null);
    try testing.expectEqual(Result.no_value, get(t, .selection, @ptrCast(&out)));
}
test "selection derivation helpers" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    vt_write(t, "  Hello  \r\nWorld", 16);
    var out: selection_c.CSelection = undefined;
    var word_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 3, .y = 0 } },
    }, &word_ref));
    var empty_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 20, .y = 0 } },
    }, &empty_ref));
    var line_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 0, .y = 0 } },
    }, &line_ref));
    var word_opts: selection_c.SelectWordOptions = .{
        .ref = word_ref,
    };
    try testing.expectEqual(Result.success, selection_c.word(t, &word_opts, &out));
    try testing.expectEqual(@as(u16, 2), out.start.toPin().?.x);
    try testing.expectEqual(@as(u16, 6), out.end.toPin().?.x);
    word_opts.ref = empty_ref;
    try testing.expectEqual(Result.no_value, selection_c.word(t, &word_opts, &out));
    var between_start_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 20, .y = 1 } },
    }, &between_start_ref));
    var between_end_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 0, .y = 1 } },
    }, &between_end_ref));
    var word_between_opts: selection_c.SelectWordBetweenOptions = .{
        .start = between_start_ref,
        .end = between_end_ref,
    };
    try testing.expectEqual(Result.success, selection_c.word_between(t, &word_between_opts, &out));
    try testing.expectEqual(@as(u16, 0), out.start.toPin().?.x);
    try testing.expectEqual(@as(u16, 1), out.start.toPin().?.y);
    try testing.expectEqual(@as(u16, 4), out.end.toPin().?.x);
    try testing.expectEqual(@as(u16, 1), out.end.toPin().?.y);
    var line_opts: selection_c.SelectLineOptions = .{
        .ref = line_ref,
    };
    try testing.expectEqual(Result.success, selection_c.line(t, &line_opts, &out));
    try testing.expectEqual(@as(u16, 2), out.start.toPin().?.x);
    try testing.expectEqual(@as(u16, 6), out.end.toPin().?.x);
    try testing.expectEqual(Result.success, selection_c.all(t, &out));
    try testing.expectEqual(@as(u16, 2), out.start.toPin().?.x);
    try testing.expectEqual(@as(u16, 0), out.start.toPin().?.y);
    try testing.expectEqual(@as(u16, 4), out.end.toPin().?.x);
    try testing.expectEqual(@as(u16, 1), out.end.toPin().?.y);
    try testing.expectEqual(Result.no_value, selection_c.output(t, line_ref, &out));
    line_opts.size = @sizeOf(usize) - 1;
    try testing.expectEqual(Result.invalid_value, selection_c.line(t, &line_opts, &out));
    try testing.expectEqual(Result.invalid_value, selection_c.word(t, null, &out));
    try testing.expectEqual(Result.invalid_value, selection_c.word(t, &word_opts, null));
    try testing.expectEqual(Result.invalid_value, selection_c.word_between(t, null, &out));
    try testing.expectEqual(Result.invalid_value, selection_c.word_between(t, &word_between_opts, null));
}
test "selection_adjust mutates snapshot end" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    vt_write(t, "Hello", 5);
    var start_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 0, .y = 0 } },
    }, &start_ref));
    var end_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 1, .y = 0 } },
    }, &end_ref));
    var sel: selection_c.CSelection = .{
        .start = start_ref,
        .end = end_ref,
    };
    try testing.expectEqual(Result.success, selection_c.adjust(t, &sel, .right));
    try testing.expectEqual(@as(u16, 0), sel.start.toPin().?.x);
    try testing.expectEqual(@as(u16, 2), sel.end.toPin().?.x);
    try testing.expectEqual(Result.success, selection_c.adjust(t, &sel, .left));
    try testing.expectEqual(@as(u16, 0), sel.start.toPin().?.x);
    try testing.expectEqual(@as(u16, 1), sel.end.toPin().?.x);
    sel = .{
        .start = end_ref,
        .end = start_ref,
    };
    try testing.expectEqual(Result.success, selection_c.adjust(t, &sel, .right));
    try testing.expectEqual(@as(u16, 1), sel.start.toPin().?.x);
    try testing.expectEqual(@as(u16, 1), sel.end.toPin().?.x);
}
test "selection_order and selection_ordered" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    vt_write(t, "Hello\r\nWorld", 12);
    var start_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 3, .y = 0 } },
    }, &start_ref));
    var end_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 1, .y = 1 } },
    }, &end_ref));
    const sel: selection_c.CSelection = .{
        .start = start_ref,
        .end = end_ref,
        .rectangle = true,
    };
    var order: selection_c.Order = undefined;
    try testing.expectEqual(Result.success, selection_c.order(t, &sel, &order));
    try testing.expectEqual(selection_c.Order.mirrored_forward, order);
    var out: selection_c.CSelection = undefined;
    try testing.expectEqual(Result.success, selection_c.ordered(t, &sel, .forward, &out));
    try testing.expectEqual(@as(u16, 1), out.start.toPin().?.x);
    try testing.expectEqual(@as(u16, 0), out.start.toPin().?.y);
    try testing.expectEqual(@as(u16, 3), out.end.toPin().?.x);
    try testing.expectEqual(@as(u16, 1), out.end.toPin().?.y);
    try testing.expect(out.rectangle);
    try testing.expectEqual(Result.success, selection_c.ordered(t, &sel, .reverse, &out));
    try testing.expectEqual(@as(u16, 3), out.start.toPin().?.x);
    try testing.expectEqual(@as(u16, 1), out.start.toPin().?.y);
    try testing.expectEqual(@as(u16, 1), out.end.toPin().?.x);
    try testing.expectEqual(@as(u16, 0), out.end.toPin().?.y);
    try testing.expect(out.rectangle);
}
test "selection_contains" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    vt_write(t, "Hello\r\nWorld", 12);
    var start_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 3, .y = 0 } },
    }, &start_ref));
    var end_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 1, .y = 1 } },
    }, &end_ref));
    const linear: selection_c.CSelection = .{
        .start = start_ref,
        .end = end_ref,
    };
    var contains: bool = undefined;
    try testing.expectEqual(Result.success, selection_c.contains(t, &linear, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 4, .y = 0 } },
    }, &contains));
    try testing.expect(contains);
    try testing.expectEqual(Result.success, selection_c.contains(t, &linear, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 2, .y = 0 } },
    }, &contains));
    try testing.expect(!contains);
    const rectangle: selection_c.CSelection = .{
        .start = start_ref,
        .end = end_ref,
        .rectangle = true,
    };
    try testing.expectEqual(Result.success, selection_c.contains(t, &rectangle, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 2, .y = 0 } },
    }, &contains));
    try testing.expect(contains);
}
test "selection_equal" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var other_t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &other_t,
        80,
        24,
    ));
    defer free(other_t);
    vt_write(t, "Hello", 5);
    vt_write(other_t, "Hello", 5);
    var start_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 0, .y = 0 } },
    }, &start_ref));
    var end_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 1, .y = 0 } },
    }, &end_ref));
    var other_end_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 2, .y = 0 } },
    }, &other_end_ref));
    var cross_terminal_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(other_t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 1, .y = 0 } },
    }, &cross_terminal_ref));
    const sel: selection_c.CSelection = .{
        .start = start_ref,
        .end = end_ref,
    };
    const equal_sel: selection_c.CSelection = .{
        .start = start_ref,
        .end = end_ref,
    };
    const different_endpoint: selection_c.CSelection = .{
        .start = start_ref,
        .end = other_end_ref,
    };
    const different_rectangle: selection_c.CSelection = .{
        .start = start_ref,
        .end = end_ref,
        .rectangle = true,
    };
    const cross_terminal: selection_c.CSelection = .{
        .start = start_ref,
        .end = cross_terminal_ref,
    };
    var equal: bool = undefined;
    try testing.expectEqual(Result.success, selection_c.equal(t, &sel, &equal_sel, &equal));
    try testing.expect(equal);
    try testing.expectEqual(Result.success, selection_c.equal(t, &sel, &different_endpoint, &equal));
    try testing.expect(!equal);
    try testing.expectEqual(Result.success, selection_c.equal(t, &sel, &different_rectangle, &equal));
    try testing.expect(!equal);
    try testing.expectEqual(Result.success, selection_c.equal(t, &sel, &cross_terminal, &equal));
    try testing.expect(!equal);
    try testing.expectEqual(Result.invalid_value, selection_c.equal(t, &sel, &equal_sel, null));
}
test "selection_order invalid values" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var order: selection_c.Order = undefined;
    try testing.expectEqual(Result.invalid_value, selection_c.order(null, null, &order));
    try testing.expectEqual(Result.invalid_value, selection_c.order(t, null, &order));
}
test "grid_ref" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    vt_write(t, "Hello", 5);
    var out_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 0, .y = 0 } },
    }, &out_ref));
    var out_cell: cell_c.CCell = undefined;
    try testing.expectEqual(Result.success, grid_ref_c.grid_ref_cell(&out_ref, &out_cell));
    var cp: u32 = 0;
    try testing.expectEqual(Result.success, cell_c.get(out_cell, .codepoint, @ptrCast(&cp)));
    try testing.expectEqual(@as(u32, 'H'), cp);
}
test "grid_ref null terminal" {
    var out_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.invalid_value, grid_ref(null, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 0, .y = 0 } },
    }, &out_ref));
}
test "point_from_grid_ref roundtrip active" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    vt_write(t, "Hello", 5);
    var ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 2, .y = 0 } },
    }, &ref));
    var coord: point.Coordinate = undefined;
    try testing.expectEqual(Result.success, point_from_grid_ref(t, &ref, .active, &coord));
    try testing.expectEqual(@as(size.CellCountInt, 2), coord.x);
    try testing.expectEqual(@as(u32, 0), coord.y);
}
test "point_from_grid_ref roundtrip viewport" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    vt_write(t, "Hello", 5);
    var ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .viewport,
        .value = .{ .viewport = .{ .x = 0, .y = 0 } },
    }, &ref));
    var coord: point.Coordinate = undefined;
    try testing.expectEqual(Result.success, point_from_grid_ref(t, &ref, .viewport, &coord));
    try testing.expectEqual(@as(size.CellCountInt, 0), coord.x);
    try testing.expectEqual(@as(u32, 0), coord.y);
}
test "point_from_grid_ref history ref to active returns no_value" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        4,
    ));
    defer free(t);
    for (0..10) |_| {
        vt_write(t, "line\n", 5);
    }
    var ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .screen,
        .value = .{ .screen = .{ .x = 0, .y = 0 } },
    }, &ref));
    var coord: point.Coordinate = undefined;
    try testing.expectEqual(Result.success, point_from_grid_ref(t, &ref, .screen, &coord));
    try testing.expectEqual(@as(u32, 0), coord.y);
    try testing.expectEqual(Result.no_value, point_from_grid_ref(t, &ref, .active, &coord));
}
test "point_from_grid_ref null terminal" {
    var ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.invalid_value, point_from_grid_ref(null, &ref, .active, null));
}
test "point_from_grid_ref null node" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.invalid_value, point_from_grid_ref(t, &ref, .active, null));
}
test "set write_pty callback DECRQM" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var last_data: ?[]u8 = null;
        var last_userdata: ?*anyopaque = null;
        var calls: usize = 0;
        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
            last_userdata = null;
            calls = 0;
        }
        fn writePty(_: Terminal, ud: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
            last_userdata = ud;
            calls += 1;
        }
    };
    defer S.deinit();
    var sentinel: u8 = 42;
    try testing.expectEqual(Result.success, set(t, .userdata, @ptrCast(&sentinel)));
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    vt_write(t, "\x1B[?7$p", 6);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1B[?7;1$y", S.last_data.?);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);
    try testing.expectEqual(1, S.calls);
    const query = "\x1B[4h\x1B[4$p";
    vt_write(t, query, query.len);
    try testing.expectEqual(2, S.calls);
    try testing.expectEqualStrings("\x1B[4;1$y", S.last_data.?);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);
}
test "write_pty receives DECRQSS response" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var last_data: ?[]u8 = null;
        fn deinit() void {
            if (last_data) |data| testing.allocator.free(data);
            last_data = null;
        }
        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |data| testing.allocator.free(data);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
    };
    defer S.deinit();
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    const query = "\x1B[1m\x1BP$qm\x1B\\";
    vt_write(t, query, query.len);
    try testing.expectEqualStrings("\x1BP1$r0;1m\x1B\\", S.last_data.?);
}
test "write_pty receives OSC color query response" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var last_data: ?[]u8 = null;
        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }
        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
    };
    defer S.deinit();
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    const set_fg = "\x1B]10;rgb:01/02/03\x1B\\";
    vt_write(t, set_fg, set_fg.len);
    try testing.expect(S.last_data == null);
    const query_fg = "\x1B]10;?\x1B\\";
    vt_write(t, query_fg, query_fg.len);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1B]10;rgb:0101/0202/0303\x1B\\", S.last_data.?);
}
test "set write_pty without callback ignores queries" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    vt_write(t, "\x1B[?7$p", 6);
    vt_write(t, "\x1B[4$p", 5);
}
test "set write_pty null clears callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var called: bool = false;
        fn writePty(_: Terminal, _: ?*anyopaque, _: [*]const u8, _: usize) callconv(lib.calling_conv) void {
            called = true;
        }
    };
    S.called = false;
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .write_pty, null));
    vt_write(t, "\x1B[?7$p", 6);
    try testing.expect(!S.called);
}
test "set bell callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var bell_count: usize = 0;
        var last_userdata: ?*anyopaque = null;
        fn bell(_: Terminal, ud: ?*anyopaque) callconv(lib.calling_conv) void {
            bell_count += 1;
            last_userdata = ud;
        }
    };
    S.bell_count = 0;
    S.last_userdata = null;
    var sentinel: u8 = 99;
    try testing.expectEqual(Result.success, set(t, .userdata, @ptrCast(&sentinel)));
    try testing.expectEqual(Result.success, set(t, .bell, @ptrCast(&S.bell)));
    vt_write(t, "\x07", 1);
    try testing.expectEqual(@as(usize, 1), S.bell_count);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);
    vt_write(t, "\x07\x07", 2);
    try testing.expectEqual(@as(usize, 3), S.bell_count);
}
test "bell without callback is silent" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    vt_write(t, "\x07", 1);
}
test "set enquiry callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var last_data: ?[]u8 = null;
        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }
        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
        const response = "OK";
        fn enquiry(_: Terminal, _: ?*anyopaque) callconv(lib.calling_conv) lib.String {
            return .{ .ptr = response, .len = response.len };
        }
    };
    defer S.deinit();
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .enquiry, @ptrCast(&S.enquiry)));
    vt_write(t, "\x05", 1);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("OK", S.last_data.?);
}
test "enquiry without callback is silent" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    vt_write(t, "\x05", 1);
}
test "set xtversion callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var last_data: ?[]u8 = null;
        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }
        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
        const version = "myterm 1.0";
        fn xtversion(_: Terminal, _: ?*anyopaque) callconv(lib.calling_conv) lib.String {
            return .{ .ptr = version, .len = version.len };
        }
    };
    defer S.deinit();
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .xtversion, @ptrCast(&S.xtversion)));
    vt_write(t, "\x1B[>q", 4);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1BP>|myterm 1.0\x1B\\", S.last_data.?);
}
test "xtversion without callback reports default" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var last_data: ?[]u8 = null;
        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }
        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
    };
    defer S.deinit();
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    vt_write(t, "\x1B[>q", 4);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1BP>|libwasp\x1B\\", S.last_data.?);
}
test "set terminfo_name option" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var last_data: ?[]u8 = null;
        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }
        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
    };
    defer S.deinit();
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    const query = "\x1BP+q" ++ std.fmt.bytesToHex("TN", .upper) ++ "\x1B\\";
    vt_write(t, query, query.len);
    try testing.expect(S.last_data == null);
    const co_query = "\x1BP+q" ++ std.fmt.bytesToHex("Co", .upper) ++ "\x1B\\";
    vt_write(t, co_query, co_query.len);
    try testing.expectEqualStrings(
        "\x1BP1+r" ++ std.fmt.bytesToHex("Co", .upper) ++ "=" ++
            std.fmt.bytesToHex("256", .upper) ++ "\x1B\\",
        S.last_data.?,
    );
    S.deinit();
    var name: [14]u8 = "xterm-256color".*;
    const value: lib.String = .{ .ptr = &name, .len = name.len };
    try testing.expectEqual(Result.success, set(t, .terminfo_name, @ptrCast(&value)));
    @memset(&name, 'z');
    vt_write(t, query, query.len);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings(
        "\x1BP1+r" ++ std.fmt.bytesToHex("TN", .upper) ++ "=" ++
            std.fmt.bytesToHex("xterm-256color", .upper) ++ "\x1B\\",
        S.last_data.?,
    );
    S.deinit();
    try testing.expectEqual(Result.success, set(t, .terminfo_name, null));
    vt_write(t, query, query.len);
    try testing.expect(S.last_data == null);
    const long: [Handler.max_terminfo_name_bytes + 1]u8 = @splat('a');
    const long_value: lib.String = .{ .ptr = &long, .len = long.len };
    try testing.expectEqual(Result.invalid_value, set(t, .terminfo_name, @ptrCast(&long_value)));
}
test "set title_changed callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var title_count: usize = 0;
        var last_userdata: ?*anyopaque = null;
        fn titleChanged(_: Terminal, ud: ?*anyopaque) callconv(lib.calling_conv) void {
            title_count += 1;
            last_userdata = ud;
        }
    };
    S.title_count = 0;
    S.last_userdata = null;
    var sentinel: u8 = 77;
    try testing.expectEqual(Result.success, set(t, .userdata, @ptrCast(&sentinel)));
    try testing.expectEqual(Result.success, set(t, .title_changed, @ptrCast(&S.titleChanged)));
    vt_write(t, "\x1B]2;Hello\x1B\\", 10);
    try testing.expectEqual(@as(usize, 1), S.title_count);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);
    vt_write(t, "\x1B]2;World\x1B\\", 10);
    try testing.expectEqual(@as(usize, 2), S.title_count);
}
test "set render_hold callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var events: [8]bool = undefined;
        var len: usize = 0;
        var last_userdata: ?*anyopaque = null;
        fn hold(_: Terminal, ud: ?*anyopaque, held: bool) callconv(lib.calling_conv) void {
            events[len] = held;
            len += 1;
            last_userdata = ud;
        }
    };
    S.len = 0;
    S.last_userdata = null;
    var sentinel: u8 = 0;
    try testing.expectEqual(Result.success, set(t, .userdata, @ptrCast(&sentinel)));
    try testing.expectEqual(Result.success, set(t, .render_hold, @ptrCast(&S.hold)));
    const frame = "\x1b[?2026h\x1b[?2026hA\x1b[?2026l\x1b[?2026l";
    vt_write(t, frame, frame.len);
    try testing.expectEqualSlices(bool, &.{ true, false }, S.events[0..S.len]);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);
    const begin = "\x1b[?2026h";
    S.len = 0;
    vt_write(t, begin, begin.len);
    try testing.expectEqual(Result.success, resize(t, 80, 24, 9, 18));
    vt_write(t, begin, begin.len);
    reset(t);
    reset(t);
    try testing.expectEqualSlices(bool, &.{ true, false, true, false }, S.events[0..S.len]);
    S.len = 0;
    vt_write(t, begin, begin.len);
    const off: ModeConfig = .{ .mode = 2026, .value = false };
    try testing.expectEqual(Result.success, set(t, .mode, @ptrCast(&off)));
    try testing.expect(!t.?.terminal.modes.get(.synchronized_output));
    try testing.expectEqualSlices(bool, &.{true}, S.events[0..S.len]);
    S.len = 0;
    try testing.expectEqual(Result.success, set(t, .render_hold, null));
    vt_write(t, frame, frame.len);
    try testing.expectEqual(0, S.len);
}
test "title_changed without callback is silent" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    vt_write(t, "\x1B]2;Hello\x1B\\", 10);
}
test "kitty_image_medium_temp_file empty output" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(&lib.alloc.test_allocator, &t, 80, 24));
    defer free(t);
    const empty: lib.String = .{ .ptr = "", .len = 0 };
    try testing.expectEqual(Result.success, set(t, .kitty_image_medium_temp_file, &empty));
    var result: lib.String = undefined;
    try testing.expectEqual(Result.success, get(t, .kitty_image_medium_temp_file, &result));
    try testing.expectEqual(@as(usize, 0), result.len);
    try testing.expectEqual(@as([*]const u8, ""), result.ptr);
}
test "set desktop_notification callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var count: usize = 0;
        var last_userdata: ?*anyopaque = null;
        var last_size: usize = 0;
        var title: [64]u8 = undefined;
        var title_len: usize = 0;
        var body: [64]u8 = undefined;
        var body_len: usize = 0;
        fn desktopNotification(
            _: Terminal,
            ud: ?*anyopaque,
            notification: *const DesktopNotification,
        ) callconv(lib.calling_conv) void {
            count += 1;
            last_userdata = ud;
            last_size = notification.size;
            title_len = notification.title.len;
            body_len = notification.body.len;
            @memcpy(title[0..title_len], notification.title.ptr[0..title_len]);
            @memcpy(body[0..body_len], notification.body.ptr[0..body_len]);
        }
    };
    S.count = 0;
    S.last_userdata = null;
    S.last_size = 0;
    S.title_len = 0;
    S.body_len = 0;
    var sentinel: u8 = 99;
    try testing.expectEqual(Result.success, set(t, .userdata, @ptrCast(&sentinel)));
    try testing.expectEqual(Result.success, set(
        t,
        .desktop_notification,
        @ptrCast(&S.desktopNotification),
    ));
    const seq_a = "\x1B]777;notify;Codex;";
    const seq_b = "Needs attention\x1B\\";
    vt_write(t, seq_a, seq_a.len);
    try testing.expectEqual(@as(usize, 0), S.count);
    vt_write(t, seq_b, seq_b.len);
    try testing.expectEqual(@as(usize, 1), S.count);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);
    try testing.expectEqual(@sizeOf(DesktopNotification), S.last_size);
    try testing.expectEqualStrings("Codex", S.title[0..S.title_len]);
    try testing.expectEqualStrings("Needs attention", S.body[0..S.body_len]);
    const seq_c = "\x1B]9;Build complete\x07";
    vt_write(t, seq_c, seq_c.len);
    try testing.expectEqual(@as(usize, 2), S.count);
    try testing.expectEqualStrings("", S.title[0..S.title_len]);
    try testing.expectEqualStrings("Build complete", S.body[0..S.body_len]);
    try testing.expectEqual(Result.success, set(t, .desktop_notification, null));
    vt_write(t, seq_c, seq_c.len);
    try testing.expectEqual(@as(usize, 2), S.count);
}
test "set resize_window callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var count: usize = 0;
        var last_userdata: ?*anyopaque = null;
        var last_tag: ResizeWindow.Tag = .grid;
        var last: ResizeWindowGrid = .{ .rows = 0, .columns = 0 };
        fn resizeWindow(
            _: Terminal,
            ud: ?*anyopaque,
            request: *const ResizeWindow.C,
        ) callconv(lib.calling_conv) void {
            count += 1;
            last_userdata = ud;
            last_tag = request.tag;
            last = request.value.grid;
        }
    };
    S.count = 0;
    S.last_userdata = null;
    var sentinel: u8 = 44;
    try testing.expectEqual(Result.success, set(t, .userdata, @ptrCast(&sentinel)));
    try testing.expectEqual(Result.success, set(
        t,
        .resize_window,
        @ptrCast(&S.resizeWindow),
    ));
    const seq = "\x1B[8;30;100t";
    vt_write(t, seq, seq.len);
    try testing.expectEqual(@as(usize, 1), S.count);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);
    try testing.expectEqual(ResizeWindow.Tag.grid, S.last_tag);
    try testing.expectEqual(@as(u16, 30), S.last.rows);
    try testing.expectEqual(@as(u16, 100), S.last.columns);
    try testing.expectEqual(Result.success, set(t, .resize_window, null));
    vt_write(t, seq, seq.len);
    try testing.expectEqual(@as(usize, 1), S.count);
}
test "set progress_report callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var count: usize = 0;
        var last_userdata: ?*anyopaque = null;
        var last_size: usize = 0;
        var last_state: ProgressState = .remove;
        var last_progress: i8 = -1;
        fn progressReport(
            _: Terminal,
            ud: ?*anyopaque,
            report: *const ProgressReport,
        ) callconv(lib.calling_conv) void {
            count += 1;
            last_userdata = ud;
            last_size = report.size;
            last_state = report.state;
            last_progress = report.progress;
        }
    };
    S.count = 0;
    S.last_userdata = null;
    S.last_size = 0;
    S.last_state = .remove;
    S.last_progress = -1;
    var sentinel: u8 = 100;
    try testing.expectEqual(Result.success, set(t, .userdata, @ptrCast(&sentinel)));
    try testing.expectEqual(Result.success, set(
        t,
        .progress_report,
        @ptrCast(&S.progressReport),
    ));
    const cases = [_]struct {
        sequence: []const u8,
        state: ProgressState,
        progress: i8,
    }{
        .{ .sequence = "\x1B]9;4;0;\x1B\\", .state = .remove, .progress = -1 },
        .{ .sequence = "\x1B]9;4;1;42\x07", .state = .set, .progress = 42 },
        .{ .sequence = "\x1B]9;4;2;7\x1B\\", .state = .@"error", .progress = 7 },
        .{ .sequence = "\x1B]9;4;3\x1B\\", .state = .indeterminate, .progress = -1 },
        .{ .sequence = "\x1B]9;4;4;75\x1B\\", .state = .pause, .progress = 75 },
    };
    for (cases, 1..) |case, expected_count| {
        const midpoint = case.sequence.len / 2;
        vt_write(t, case.sequence.ptr, midpoint);
        try testing.expectEqual(expected_count - 1, S.count);
        vt_write(t, case.sequence.ptr + midpoint, case.sequence.len - midpoint);
        try testing.expectEqual(expected_count, S.count);
        try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);
        try testing.expectEqual(@sizeOf(ProgressReport), S.last_size);
        try testing.expectEqual(case.state, S.last_state);
        try testing.expectEqual(case.progress, S.last_progress);
    }
    try testing.expectEqual(Result.success, set(t, .progress_report, null));
    const ignored = "\x1B]9;4;1;90\x1B\\";
    vt_write(t, ignored, ignored.len);
    try testing.expectEqual(@as(usize, cases.len), S.count);
}
test "set program_status callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var count: usize = 0;
        var last_userdata: ?*anyopaque = null;
        var last_size: usize = 0;
        var last_state: ProgramStatusState = .idle;
        var last_kind: ProgramStatusKind = .none;
        var last_progress: i8 = -1;
        var last_id: [64]u8 = undefined;
        var last_id_len: usize = 0;
        var last_app: [64]u8 = undefined;
        var last_app_len: usize = 0;
        var last_title: [64]u8 = undefined;
        var last_title_len: usize = 0;
        var last_message: [64]u8 = undefined;
        var last_message_len: usize = 0;
        var written: [128]u8 = undefined;
        var written_len: usize = 0;
        fn programStatus(
            _: Terminal,
            ud: ?*anyopaque,
            report: *const ProgramStatus,
        ) callconv(lib.calling_conv) void {
            count += 1;
            last_userdata = ud;
            last_size = report.size;
            last_state = report.state;
            last_kind = report.kind;
            last_progress = report.progress;
            last_id_len = copy(&last_id, report.id);
            last_app_len = copy(&last_app, report.app);
            last_title_len = copy(&last_title, report.title);
            last_message_len = copy(&last_message, report.message);
        }
        fn writePty(
            _: Terminal,
            _: ?*anyopaque,
            ptr: [*]const u8,
            len: usize,
        ) callconv(lib.calling_conv) void {
            @memcpy(written[written_len..][0..len], ptr[0..len]);
            written_len += len;
        }
        fn copy(dst: []u8, src: lib.String) usize {
            if (src.len > 0) @memcpy(dst[0..src.len], src.ptr[0..src.len]);
            return src.len;
        }
    };
    S.count = 0;
    S.written_len = 0;
    var sentinel: u8 = 100;
    try testing.expectEqual(Result.success, set(t, .userdata, @ptrCast(&sentinel)));
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    const query = "\x1B]7501;?\x1B\\";
    vt_write(t, query, query.len);
    try testing.expectEqual(@as(usize, 0), S.written_len);
    try testing.expectEqual(Result.success, set(
        t,
        .program_status,
        @ptrCast(&S.programStatus),
    ));
    vt_write(t, query, query.len);
    try testing.expectEqualStrings(
        "\x1B]7501;?:states=idle,working,done,blocked,error" ++
            ":kinds=permission,question,auth\x1B\\",
        S.written[0..S.written_len],
    );
    try testing.expectEqual(@as(usize, 0), S.count);
    const report = "\x1B]7501;state=blocked:kind=permission:progress=40:id=a/b" ++
        ":app=terraform:title=UGxhbg==:msg=QXBwbHk/\x07";
    vt_write(t, report, report.len);
    try testing.expectEqual(@as(usize, 1), S.count);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);
    try testing.expectEqual(@sizeOf(ProgramStatus), S.last_size);
    try testing.expectEqual(ProgramStatusState.blocked, S.last_state);
    try testing.expectEqual(ProgramStatusKind.permission, S.last_kind);
    try testing.expectEqual(@as(i8, 40), S.last_progress);
    try testing.expectEqualStrings("a/b", S.last_id[0..S.last_id_len]);
    try testing.expectEqualStrings("terraform", S.last_app[0..S.last_app_len]);
    try testing.expectEqualStrings("Plan", S.last_title[0..S.last_title_len]);
    try testing.expectEqualStrings("Apply?", S.last_message[0..S.last_message_len]);
    const minimal = "\x1B]7501;state=done\x1B\\";
    vt_write(t, minimal, minimal.len);
    try testing.expectEqual(@as(usize, 2), S.count);
    try testing.expectEqual(ProgramStatusState.done, S.last_state);
    try testing.expectEqual(ProgramStatusKind.none, S.last_kind);
    try testing.expectEqual(@as(i8, -1), S.last_progress);
    try testing.expectEqual(@as(usize, 0), S.last_id_len);
    try testing.expectEqual(@as(usize, 0), S.last_app_len);
    try testing.expectEqual(@as(usize, 0), S.last_title_len);
    try testing.expectEqual(@as(usize, 0), S.last_message_len);
    try testing.expectEqual(Result.success, set(t, .program_status, null));
    S.written_len = 0;
    vt_write(t, query, query.len);
    vt_write(t, minimal, minimal.len);
    try testing.expectEqual(@as(usize, 0), S.written_len);
    try testing.expectEqual(@as(usize, 2), S.count);
}
test "set semantic_prompt callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var count: usize = 0;
        var last_userdata: ?*anyopaque = null;
        var last_size: usize = 0;
        var last_kind: SemanticPromptKind = .invalid;
        var last_prompt_kind: SemanticPromptPromptKind = .primary;
        var last_has_exit_code: bool = false;
        var last_exit_code: i32 = 0;
        var command_buf: [64]u8 = undefined;
        var command_len: usize = 0;
        var error_buf: [64]u8 = undefined;
        var error_len: usize = 0;
        fn semanticPrompt(
            _: Terminal,
            ud: ?*anyopaque,
            event: *const SemanticPrompt,
        ) callconv(lib.calling_conv) void {
            count += 1;
            last_userdata = ud;
            last_size = event.size;
            last_kind = event.kind;
            last_prompt_kind = event.prompt_kind;
            last_has_exit_code = event.has_exit_code;
            last_exit_code = event.exit_code;
            command_len = event.command.len;
            @memcpy(command_buf[0..command_len], event.command.ptr[0..command_len]);
            error_len = event.@"error".len;
            @memcpy(error_buf[0..error_len], event.@"error".ptr[0..error_len]);
        }
    };
    S.count = 0;
    S.last_userdata = null;
    S.last_size = 0;
    var sentinel: u8 = 100;
    try testing.expectEqual(Result.success, set(t, .userdata, @ptrCast(&sentinel)));
    try testing.expectEqual(Result.success, set(
        t,
        .semantic_prompt,
        @ptrCast(&S.semanticPrompt),
    ));
    const prompt = "\x1B]133;P;k=r\x07";
    vt_write(t, prompt, prompt.len);
    try testing.expectEqual(@as(usize, 1), S.count);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);
    try testing.expectEqual(@sizeOf(SemanticPrompt), S.last_size);
    try testing.expectEqual(SemanticPromptKind.prompt_start, S.last_kind);
    try testing.expectEqual(SemanticPromptPromptKind.right, S.last_prompt_kind);
    try testing.expect(!S.last_has_exit_code);
    const input = "\x1B]133;B\x07";
    vt_write(t, input, input.len);
    try testing.expectEqual(@as(usize, 2), S.count);
    try testing.expectEqual(SemanticPromptKind.input_start, S.last_kind);
    try testing.expectEqual(SemanticPromptPromptKind.primary, S.last_prompt_kind);
    const output = "\x1B]133;C;cmdline_url=ls%20-la\x07";
    vt_write(t, output, output.len);
    try testing.expectEqual(@as(usize, 3), S.count);
    try testing.expectEqual(SemanticPromptKind.output_start, S.last_kind);
    try testing.expectEqualStrings("ls -la", S.command_buf[0..S.command_len]);
    const end = "\x1B]133;D;-1;err=boom\x07";
    vt_write(t, end, end.len);
    try testing.expectEqual(@as(usize, 4), S.count);
    try testing.expectEqual(SemanticPromptKind.command_end, S.last_kind);
    try testing.expect(S.last_has_exit_code);
    try testing.expectEqual(@as(i32, -1), S.last_exit_code);
    try testing.expectEqualStrings("boom", S.error_buf[0..S.error_len]);
    try testing.expectEqual(@as(usize, 0), S.command_len);
    const end_no_code = "\x1B]133;D\x07";
    vt_write(t, end_no_code, end_no_code.len);
    try testing.expectEqual(@as(usize, 5), S.count);
    try testing.expect(!S.last_has_exit_code);
    try testing.expectEqual(@as(i32, 0), S.last_exit_code);
    try testing.expectEqual(@as(usize, 0), S.error_len);
    try testing.expectEqual(Result.success, set(t, .semantic_prompt, null));
    vt_write(t, prompt, prompt.len);
    try testing.expectEqual(@as(usize, 5), S.count);
}
test "set reset callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var count: usize = 0;
        var last_userdata: ?*anyopaque = null;
        fn reset(_: Terminal, ud: ?*anyopaque) callconv(lib.calling_conv) void {
            count += 1;
            last_userdata = ud;
        }
    };
    S.count = 0;
    S.last_userdata = null;
    var sentinel: u8 = 100;
    try testing.expectEqual(Result.success, set(t, .userdata, @ptrCast(&sentinel)));
    try testing.expectEqual(Result.success, set(t, .reset, @ptrCast(&S.reset)));
    const soft = "\x1B[!p";
    vt_write(t, soft, soft.len);
    try testing.expectEqual(@as(usize, 0), S.count);
    const full = "\x1Bc";
    vt_write(t, full, full.len);
    try testing.expectEqual(@as(usize, 1), S.count);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);
    try testing.expectEqual(Result.success, set(t, .reset, null));
    vt_write(t, full, full.len);
    try testing.expectEqual(@as(usize, 1), S.count);
}
test "set unknown_sequence callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var count: usize = 0;
        var last_terminal: Terminal = null;
        var last_userdata: ?*anyopaque = null;
        var last_tag: UnknownSequence.Tag = .apc;
        var last_truncated: bool = false;
        var last_terminator: osc.Terminator.C = .st;
        var content: [64]u8 = undefined;
        var content_len: usize = 0;
        fn unknownSequence(
            terminal_: Terminal,
            ud: ?*anyopaque,
            sequence: *const UnknownSequence.C,
        ) callconv(lib.calling_conv) void {
            count += 1;
            last_terminal = terminal_;
            last_userdata = ud;
            last_tag = sequence.tag;
            const str: lib.String = switch (sequence.tag) {
                .apc => str: {
                    const apc_value = sequence.value.apc;
                    last_truncated = apc_value.truncated;
                    break :str apc_value.content;
                },
                .osc => str: {
                    const osc_value = sequence.value.osc;
                    last_truncated = osc_value.truncated;
                    last_terminator = osc_value.terminator;
                    break :str osc_value.content;
                },
            };
            content_len = @min(str.len, content.len);
            @memcpy(content[0..content_len], str.ptr[0..content_len]);
        }
    };
    S.count = 0;
    S.last_terminal = null;
    S.last_userdata = null;
    S.last_tag = .apc;
    S.last_truncated = false;
    S.content_len = 0;
    var sentinel: u8 = 101;
    try testing.expectEqual(Result.success, set(t, .userdata, @ptrCast(&sentinel)));
    const max_bytes: usize = 8;
    try testing.expectEqual(Result.success, set(
        t,
        .unknown_max_bytes,
        @ptrCast(&max_bytes),
    ));
    try testing.expectEqual(max_bytes, t.?.stream.handler.apc_handler.unknown_max_bytes);
    try testing.expectEqual(max_bytes, t.?.stream.parser.osc_parser.unknown_max_bytes);
    const before_callback = "\x1B_abc;xy\x1B\\";
    vt_write(t, before_callback, before_callback.len);
    try testing.expectEqual(@as(usize, 0), S.count);
    try testing.expect(t.?.stream.handler.unknown_sequence == null);
    try testing.expectEqual(Result.success, set(
        t,
        .unknown_sequence,
        @ptrCast(&S.unknownSequence),
    ));
    try testing.expect(t.?.stream.handler.unknown_sequence != null);
    const seq_a = "\x1B_abc;";
    const seq_b = "xy\x1B\\";
    vt_write(t, seq_a, seq_a.len);
    try testing.expectEqual(@as(usize, 0), S.count);
    vt_write(t, seq_b, seq_b.len);
    try testing.expectEqual(@as(usize, 1), S.count);
    try testing.expectEqual(t, S.last_terminal);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);
    try testing.expectEqual(UnknownSequence.Tag.apc, S.last_tag);
    try testing.expect(!S.last_truncated);
    try testing.expectEqualStrings("abc;xy", S.content[0..S.content_len]);
    const truncated = "\x1B_abcdefghijkl\x1B\\";
    vt_write(t, truncated, truncated.len);
    try testing.expectEqual(@as(usize, 2), S.count);
    try testing.expect(S.last_truncated);
    try testing.expectEqualStrings("abcdefgh", S.content[0..S.content_len]);
    const aborted = "\x1B_abcdef\x18";
    vt_write(t, aborted, aborted.len);
    try testing.expectEqual(@as(usize, 2), S.count);
    const osc_st = "\x1B]7400;x\x1B\\";
    vt_write(t, osc_st, osc_st.len);
    try testing.expectEqual(@as(usize, 3), S.count);
    try testing.expectEqual(UnknownSequence.Tag.osc, S.last_tag);
    try testing.expect(!S.last_truncated);
    try testing.expectEqual(osc.Terminator.C.st, S.last_terminator);
    try testing.expectEqualStrings("7400;x", S.content[0..S.content_len]);
    const osc_bel = "\x1B]7400;abcdef\x07";
    vt_write(t, osc_bel, osc_bel.len);
    try testing.expectEqual(@as(usize, 4), S.count);
    try testing.expectEqual(UnknownSequence.Tag.osc, S.last_tag);
    try testing.expect(S.last_truncated);
    try testing.expectEqual(osc.Terminator.C.bel, S.last_terminator);
    try testing.expectEqualStrings("7400;abc", S.content[0..S.content_len]);
    const osc_aborted = "\x1B]7400;x\x18\x1B]2;title\x07";
    vt_write(t, osc_aborted, osc_aborted.len);
    try testing.expectEqual(@as(usize, 4), S.count);
    try testing.expectEqual(Result.success, set(t, .unknown_sequence, null));
    try testing.expect(t.?.stream.handler.unknown_sequence == null);
    vt_write(t, before_callback, before_callback.len);
    vt_write(t, osc_st, osc_st.len);
    try testing.expectEqual(@as(usize, 4), S.count);
    try testing.expectEqual(Result.success, set(
        t,
        .unknown_sequence,
        @ptrCast(&S.unknownSequence),
    ));
    try testing.expectEqual(Result.success, set(t, .unknown_max_bytes, null));
    try testing.expectEqual(@as(usize, 0), t.?.stream.handler.apc_handler.unknown_max_bytes);
    try testing.expectEqual(@as(usize, 0), t.?.stream.parser.osc_parser.unknown_max_bytes);
    vt_write(t, before_callback, before_callback.len);
    vt_write(t, osc_st, osc_st.len);
    try testing.expectEqual(@as(usize, 4), S.count);
}
test "set pwd_changed callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var pwd_count: usize = 0;
        var last_userdata: ?*anyopaque = null;
        fn pwdChanged(_: Terminal, ud: ?*anyopaque) callconv(lib.calling_conv) void {
            pwd_count += 1;
            last_userdata = ud;
        }
    };
    S.pwd_count = 0;
    S.last_userdata = null;
    var sentinel: u8 = 88;
    try testing.expectEqual(Result.success, set(t, .userdata, @ptrCast(&sentinel)));
    try testing.expectEqual(Result.success, set(t, .pwd_changed, @ptrCast(&S.pwdChanged)));
    const seq1 = "\x1B]7;file:///tmp\x1B\\";
    vt_write(t, seq1, seq1.len);
    try testing.expectEqual(@as(usize, 1), S.pwd_count);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);
    try testing.expectEqualStrings("file:///tmp", zigTerminal(t).?.getPwd().?);
    const seq2 = "\x1B]7;file:///home/user\x1B\\";
    vt_write(t, seq2, seq2.len);
    try testing.expectEqual(@as(usize, 2), S.pwd_count);
    try testing.expectEqualStrings("file:///home/user", zigTerminal(t).?.getPwd().?);
}
test "set clipboard_write callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var count: usize = 0;
        var last_terminal: Terminal = null;
        var last_userdata: ?*anyopaque = null;
        var last_size: usize = 0;
        var last_location: clipboard.Location = .standard;
        var last_contents_null: bool = false;
        var last_contents_len: usize = 0;
        var last_mimes: [8][64]u8 = undefined;
        var last_mime_lens: [8]usize = @splat(0);
        var last_data: [8][64]u8 = undefined;
        var last_data_lens: [8]usize = @splat(0);
        var last_name_len: usize = 0;
        var last_granted: bool = true;
        var last_can_remember: bool = true;
        var next_result: clipboard.Write.Status = .success;
        fn clipboardWrite(
            terminal_: Terminal,
            ud: ?*anyopaque,
            request: *const ClipboardWrite,
        ) callconv(lib.calling_conv) void {
            count += 1;
            last_terminal = terminal_;
            last_userdata = ud;
            last_size = request.size;
            last_location = request.location;
            last_contents_null = request.contents == null;
            last_contents_len = request.contents_len;
            last_name_len = request.name.len;
            last_granted = request.granted;
            last_can_remember = request.can_remember;
            if (request.contents) |ptr| {
                for (ptr[0..@min(request.contents_len, last_mimes.len)], 0..) |content, i| {
                    last_mime_lens[i] = @min(content.mime.len, last_mimes[i].len);
                    @memcpy(
                        last_mimes[i][0..last_mime_lens[i]],
                        content.mime.ptr[0..last_mime_lens[i]],
                    );
                    last_data_lens[i] = @min(content.data.len, last_data[i].len);
                    @memcpy(
                        last_data[i][0..last_data_lens[i]],
                        content.data.ptr[0..last_data_lens[i]],
                    );
                }
            }
            request.reply(request, &.{
                .size = @sizeOf(ClipboardWriteReply),
                .result = next_result,
                .remember = false,
            });
        }
    };
    S.count = 0;
    S.last_terminal = null;
    S.last_userdata = null;
    S.next_result = .denied;
    var sentinel: u8 = 88;
    try testing.expectEqual(Result.success, set(t, .userdata, @ptrCast(&sentinel)));
    try testing.expectEqual(Result.success, set(t, .clipboard_write, @ptrCast(&S.clipboardWrite)));
    const seq1_a = "\x1B]52;c;aGVs";
    const seq1_b = "bG8Ad29ybGQ=\x1B\\";
    vt_write(t, seq1_a, seq1_a.len);
    vt_write(t, seq1_b, seq1_b.len);
    try testing.expectEqual(@as(usize, 1), S.count);
    try testing.expectEqual(t, S.last_terminal);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);
    try testing.expectEqual(@sizeOf(ClipboardWrite), S.last_size);
    try testing.expectEqual(clipboard.Location.standard, S.last_location);
    try testing.expect(!S.last_contents_null);
    try testing.expectEqual(@as(usize, 1), S.last_contents_len);
    try testing.expectEqualStrings("text/plain", S.last_mimes[0][0..S.last_mime_lens[0]]);
    try testing.expectEqualSlices(u8, "hello\x00world", S.last_data[0][0..S.last_data_lens[0]]);
    try testing.expectEqual(@as(usize, 0), S.last_name_len);
    try testing.expect(!S.last_granted);
    try testing.expect(!S.last_can_remember);
    const location_cases = [_]struct {
        selector: u8,
        expected: clipboard.Location,
    }{
        .{ .selector = 's', .expected = .selection },
        .{ .selector = 'p', .expected = .primary },
        .{ .selector = 'q', .expected = .standard },
    };
    for (location_cases) |case| {
        const seq = [_]u8{ '\x1B', ']', '5', '2', ';', case.selector, ';', 'e', 'A', '=', '=', '\x1B', '\\' };
        vt_write(t, &seq, seq.len);
        try testing.expectEqual(case.expected, S.last_location);
    }
    try testing.expectEqual(@as(usize, 4), S.count);
    const clear = "\x1B]52;s;\x1B\\";
    vt_write(t, clear, clear.len);
    try testing.expectEqual(@as(usize, 5), S.count);
    try testing.expectEqual(clipboard.Location.selection, S.last_location);
    try testing.expect(S.last_contents_null);
    try testing.expectEqual(@as(usize, 0), S.last_contents_len);
    const read = "\x1B]52;c;?\x1B\\";
    vt_write(t, read, read.len);
    const malformed = "\x1B]52;c;%%%\x1B\\";
    vt_write(t, malformed, malformed.len);
    try testing.expectEqual(@as(usize, 5), S.count);
    const iterm = "\x1B]1337;Copy=:aVRlcm0=\x1B\\";
    vt_write(t, iterm, iterm.len);
    try testing.expectEqual(@as(usize, 6), S.count);
    try testing.expectEqual(clipboard.Location.standard, S.last_location);
    try testing.expectEqualStrings("text/plain", S.last_mimes[0][0..S.last_mime_lens[0]]);
    try testing.expectEqualStrings("iTerm", S.last_data[0][0..S.last_data_lens[0]]);
    const internal_contents = [_]clipboard.Content{
        .{ .mime = "text/plain", .data = "plain" },
        .{ .mime = "application/octet-stream", .data = "a\x00b" },
        .{ .mime = "text/html", .data = "<b>plain</b>" },
        .{ .mime = "text/rtf", .data = "{\\rtf1 plain}" },
        .{ .mime = "image/png", .data = "\x89PNG" },
    };
    const Reply = struct {
        var last: ?clipboard.Write.Result = null;
        fn reply(_: *anyopaque, result: clipboard.Write.Result) void {
            last = result;
        }
    };
    S.next_result = .busy;
    const handler = &t.?.stream.handler;
    handler.effects.clipboard_write.?(handler, .{
        .location = .primary,
        .contents = &internal_contents,
        .name = "app",
        .granted = true,
        .can_remember = true,
        .reply_ctx = handler,
        .reply_fn = &Reply.reply,
    });
    try testing.expect(Reply.last.? == .busy);
    try testing.expectEqual(@as(usize, 3), S.last_name_len);
    try testing.expect(S.last_granted);
    try testing.expect(S.last_can_remember);
    try testing.expectEqual(@as(usize, 7), S.count);
    try testing.expectEqual(@as(usize, 5), S.last_contents_len);
    try testing.expectEqualStrings(
        "application/octet-stream",
        S.last_mimes[1][0..S.last_mime_lens[1]],
    );
    try testing.expectEqualSlices(u8, "a\x00b", S.last_data[1][0..S.last_data_lens[1]]);
    try testing.expectEqualStrings("image/png", S.last_mimes[4][0..S.last_mime_lens[4]]);
    try testing.expectEqualSlices(u8, "\x89PNG", S.last_data[4][0..S.last_data_lens[4]]);
    try testing.expectEqual(Result.success, set(t, .clipboard_write, null));
    try testing.expect(t.?.stream.handler.effects.clipboard_write == null);
    const after_remove = "\x1B]52;c;eA==\x1B\\";
    vt_write(t, after_remove, after_remove.len);
    try testing.expectEqual(@as(usize, 7), S.count);
}
test "clipboard_write without callback is unsupported and silent" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const seq = "\x1B]52;c;aGVsbG8=\x1B\\";
    vt_write(t, seq, seq.len);
    try testing.expect(t.?.stream.handler.effects.clipboard_write == null);
}
test "kitty clipboard write via C effects" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var responses: [512]u8 = undefined;
        var responses_len: usize = 0;
        var write_count: usize = 0;
        var last_location: clipboard.Location = .standard;
        var last_contents_len: usize = 0;
        var last_mimes: [4][64]u8 = undefined;
        var last_mime_lens: [4]usize = @splat(0);
        var last_data: [4][64]u8 = undefined;
        var last_data_lens: [4]usize = @splat(0);
        var last_granted: bool = true;
        var last_can_remember: bool = true;
        var next_remember: bool = false;
        fn writePty(
            _: Terminal,
            _: ?*anyopaque,
            ptr: [*]const u8,
            len: usize,
        ) callconv(lib.calling_conv) void {
            @memcpy(responses[responses_len..][0..len], ptr[0..len]);
            responses_len += len;
        }
        fn clipboardWrite(
            _: Terminal,
            _: ?*anyopaque,
            request: *const ClipboardWrite,
        ) callconv(lib.calling_conv) void {
            write_count += 1;
            last_location = request.location;
            last_contents_len = request.contents_len;
            if (request.contents) |ptr| {
                for (ptr[0..@min(request.contents_len, last_mimes.len)], 0..) |content, i| {
                    last_mime_lens[i] = @min(content.mime.len, last_mimes[i].len);
                    @memcpy(
                        last_mimes[i][0..last_mime_lens[i]],
                        content.mime.ptr[0..last_mime_lens[i]],
                    );
                    last_data_lens[i] = @min(content.data.len, last_data[i].len);
                    @memcpy(
                        last_data[i][0..last_data_lens[i]],
                        content.data.ptr[0..last_data_lens[i]],
                    );
                }
            }
            last_granted = request.granted;
            last_can_remember = request.can_remember;
            request.reply(request, &.{
                .size = @sizeOf(ClipboardWriteReply),
                .result = .success,
                .remember = next_remember,
            });
        }
    };
    S.responses_len = 0;
    S.write_count = 0;
    S.last_mime_lens = @splat(0);
    S.last_data_lens = @splat(0);
    S.last_granted = true;
    S.last_can_remember = true;
    S.next_remember = false;
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .clipboard_write, @ptrCast(&S.clipboardWrite)));
    const seqs = [_][]const u8{
        "\x1B]5522;type=write:id=c1\x1B\\",
        "\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3Q=\x1B\\",
        "\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;dHk=\x1B\\",
        "\x1B]5522;type=wdata:mime=dGV4dC9odG1s;PGI+aGk8L2I+\x1B\\",
        "\x1B]5522;type=wdata\x1B\\",
    };
    for (seqs) |seq| vt_write(t, seq.ptr, seq.len);
    try testing.expectEqual(@as(usize, 1), S.write_count);
    try testing.expectEqual(clipboard.Location.standard, S.last_location);
    try testing.expectEqual(@as(usize, 2), S.last_contents_len);
    try testing.expectEqualStrings("text/plain", S.last_mimes[0][0..S.last_mime_lens[0]]);
    try testing.expectEqualStrings("Wasp", S.last_data[0][0..S.last_data_lens[0]]);
    try testing.expectEqualStrings("text/html", S.last_mimes[1][0..S.last_mime_lens[1]]);
    try testing.expectEqualStrings("<b>hi</b>", S.last_data[1][0..S.last_data_lens[1]]);
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=DONE:id=c1\x1B\\",
        S.responses[0..S.responses_len],
    );
    try testing.expect(!S.last_granted);
    try testing.expect(!S.last_can_remember);
    S.responses_len = 0;
    S.next_remember = true;
    const grant_seqs = [_][]const u8{
        "\x1B]5522;type=write:id=g1:pw=c2VjcmV0:name=YXBw\x1B\\",
        "\x1B]5522;type=wdata\x1B\\",
        "\x1B]5522;type=write:id=g2:pw=c2VjcmV0:name=YXBw\x1B\\",
        "\x1B]5522;type=wdata\x1B\\",
    };
    for (grant_seqs) |seq| vt_write(t, seq.ptr, seq.len);
    try testing.expectEqual(@as(usize, 3), S.write_count);
    try testing.expect(S.last_granted);
    try testing.expect(S.last_can_remember);
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=DONE:id=g1\x1B\\" ++
            "\x1B]5522;type=write:status=DONE:id=g2\x1B\\",
        S.responses[0..S.responses_len],
    );
    S.next_remember = false;
    S.responses_len = 0;
    const read = "\x1B]5522;type=read:id=r1;dGV4dC9wbGFpbg==\x1B\\";
    vt_write(t, read, read.len);
    try testing.expectEqual(@as(usize, 3), S.write_count);
    try testing.expectEqualStrings(
        "\x1B]5522;type=read:status=EPERM:id=r1\x1B\\",
        S.responses[0..S.responses_len],
    );
    const R = struct {
        var count: usize = 0;
        var last_mimes_len: usize = 0;
        var last_mime_is_text: bool = false;
        var last_list: bool = true;
        var last_name_len: usize = 0;
        var last_granted: bool = true;
        var last_can_remember: bool = true;
        fn clipboardRead(
            _: Terminal,
            _: ?*anyopaque,
            request: *const ClipboardRead,
        ) callconv(lib.calling_conv) void {
            count += 1;
            last_mimes_len = request.mimes_len;
            last_mime_is_text = request.mimes_len > 0 and std.mem.eql(
                u8,
                request.mimes.?[0].ptr[0..request.mimes.?[0].len],
                "text/plain",
            );
            last_list = request.list;
            last_name_len = request.name.len;
            last_granted = request.granted;
            last_can_remember = request.can_remember;
            const mime: []const u8 = "text/plain";
            const data: []const u8 = "hello";
            const contents = [_]ClipboardContent{.{
                .mime = .init(mime),
                .data = .init(data),
            }};
            request.reply(request, &.{
                .size = @sizeOf(ClipboardReadReply),
                .result = .success,
                .contents = &contents,
                .contents_len = contents.len,
                .available = null,
                .available_len = 0,
                .remember = false,
            });
        }
    };
    try testing.expectEqual(Result.success, set(t, .clipboard_read, @ptrCast(&R.clipboardRead)));
    S.responses_len = 0;
    const read2 = "\x1B]5522;type=read:id=r2:name=YXBw;dGV4dC9wbGFpbg==\x1B\\";
    vt_write(t, read2, read2.len);
    try testing.expectEqual(@as(usize, 1), R.count);
    try testing.expectEqual(@as(usize, 1), R.last_mimes_len);
    try testing.expect(R.last_mime_is_text);
    try testing.expect(!R.last_list);
    try testing.expectEqual(@as(usize, 3), R.last_name_len);
    try testing.expect(!R.last_granted);
    try testing.expect(!R.last_can_remember);
    try testing.expectEqualStrings(
        "\x1B]5522;type=read:status=OK:id=r2\x1B\\" ++
            "\x1B]5522;type=read:status=DATA:id=r2:mime=dGV4dC9wbGFpbg==;aGVsbG8=\x1B\\" ++
            "\x1B]5522;type=read:status=DONE:id=r2\x1B\\",
        S.responses[0..S.responses_len],
    );
    try testing.expectEqual(Result.success, set(t, .clipboard_write, null));
    S.responses_len = 0;
    const begin = "\x1B]5522;type=write:id=c2\x1B\\";
    vt_write(t, begin, begin.len);
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=ENOSYS:id=c2\x1B\\",
        S.responses[0..S.responses_len],
    );
}
test "set clipboard write max bytes" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var responses: [512]u8 = undefined;
        var responses_len: usize = 0;
        var write_count: usize = 0;
        fn writePty(
            _: Terminal,
            _: ?*anyopaque,
            ptr: [*]const u8,
            len: usize,
        ) callconv(lib.calling_conv) void {
            @memcpy(responses[responses_len..][0..len], ptr[0..len]);
            responses_len += len;
        }
        fn clipboardWrite(
            _: Terminal,
            _: ?*anyopaque,
            request: *const ClipboardWrite,
        ) callconv(lib.calling_conv) void {
            write_count += 1;
            request.reply(request, &.{
                .size = @sizeOf(ClipboardWriteReply),
                .result = .success,
                .remember = false,
            });
        }
    };
    S.responses_len = 0;
    S.write_count = 0;
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .clipboard_write, @ptrCast(&S.clipboardWrite)));
    var max: usize = 0;
    try testing.expectEqual(Result.success, get(t, .clipboard_write_max_bytes, @ptrCast(&max)));
    try testing.expectEqual(@as(usize, kitty_clipboard.max_write_size), max);
    const limit: usize = 4;
    try testing.expectEqual(Result.success, set(t, .clipboard_write_max_bytes, @ptrCast(&limit)));
    try testing.expectEqual(Result.success, get(t, .clipboard_write_max_bytes, @ptrCast(&max)));
    try testing.expectEqual(limit, max);
    const seqs = [_][]const u8{
        "\x1B]5522;type=write:id=c1\x1B\\",
        "\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;SGVsbA==\x1B\\",
        "\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;bw==\x1B\\",
        "\x1B]5522;type=wdata\x1B\\",
    };
    for (seqs) |seq| vt_write(t, seq.ptr, seq.len);
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=EFBIG:id=c1\x1B\\",
        S.responses[0..S.responses_len],
    );
    try testing.expectEqual(Result.success, set(t, .clipboard_write_max_bytes, null));
    try testing.expectEqual(Result.success, get(t, .clipboard_write_max_bytes, @ptrCast(&max)));
    try testing.expectEqual(@as(usize, kitty_clipboard.max_write_size), max);
}
test "set clipboard_read callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var last_data: ?[]u8 = null;
        var count: usize = 0;
        var last_size: usize = 0;
        var last_location: clipboard.Location = .standard;
        var last_mimes_len: usize = 0;
        var last_mime_is_text: bool = false;
        var last_list: bool = true;
        var last_name_len: usize = 1;
        var last_granted: bool = true;
        var last_can_remember: bool = true;
        var result: clipboard.Read.Status = .success;
        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }
        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
        fn clipboardRead(
            _: Terminal,
            _: ?*anyopaque,
            request: *const ClipboardRead,
        ) callconv(lib.calling_conv) void {
            count += 1;
            last_size = request.size;
            last_location = request.location;
            last_mimes_len = request.mimes_len;
            last_mime_is_text = request.mimes_len > 0 and std.mem.eql(
                u8,
                request.mimes.?[0].ptr[0..request.mimes.?[0].len],
                "text/plain",
            );
            last_list = request.list;
            last_name_len = request.name.len;
            last_granted = request.granted;
            last_can_remember = request.can_remember;
            const mime: []const u8 = "text/plain";
            const data: []const u8 = "hello";
            const contents = [_]ClipboardContent{.{
                .mime = .init(mime),
                .data = .init(data),
            }};
            request.reply(request, &.{
                .size = @sizeOf(ClipboardReadReply),
                .result = result,
                .contents = &contents,
                .contents_len = contents.len,
                .available = null,
                .available_len = 0,
                .remember = false,
            });
        }
    };
    defer S.deinit();
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expect(t.?.stream.handler.effects.clipboard_read == null);
    const read_st = "\x1B]52;c;?\x1B\\";
    vt_write(t, read_st, read_st.len);
    try testing.expect(S.last_data == null);
    try testing.expectEqual(Result.success, set(t, .clipboard_read, @ptrCast(&S.clipboardRead)));
    try testing.expect(t.?.stream.handler.effects.clipboard_read != null);
    const read_bel = "\x1B]52;p;?\x07";
    vt_write(t, read_bel, read_bel.len);
    try testing.expectEqual(1, S.count);
    try testing.expectEqual(@sizeOf(ClipboardRead), S.last_size);
    try testing.expectEqual(clipboard.Location.primary, S.last_location);
    try testing.expectEqual(1, S.last_mimes_len);
    try testing.expect(S.last_mime_is_text);
    try testing.expect(!S.last_list);
    try testing.expectEqual(0, S.last_name_len);
    try testing.expect(!S.last_granted);
    try testing.expect(!S.last_can_remember);
    try testing.expectEqualStrings("\x1B]52;p;aGVsbG8=\x07", S.last_data.?);
    S.result = .denied;
    vt_write(t, read_st, read_st.len);
    try testing.expectEqual(2, S.count);
    try testing.expectEqualStrings("\x1B]52;c;\x1B\\", S.last_data.?);
    try testing.expectEqual(Result.success, set(t, .clipboard_read, null));
    try testing.expect(t.?.stream.handler.effects.clipboard_read == null);
}
test "pwd_changed without callback is silent" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const seq = "\x1B]7;file:///tmp\x1B\\";
    vt_write(t, seq, seq.len);
    try testing.expectEqualStrings("file:///tmp", zigTerminal(t).?.getPwd().?);
}
test "set size callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var last_data: ?[]u8 = null;
        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }
        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
        fn sizeCb(_: Terminal, _: ?*anyopaque, out_size: *size_report.Size) callconv(lib.calling_conv) bool {
            out_size.* = .{
                .rows = 24,
                .columns = 80,
                .cell_width = 8,
                .cell_height = 16,
            };
            return true;
        }
    };
    defer S.deinit();
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .size_cb, @ptrCast(&S.sizeCb)));
    vt_write(t, "\x1B[18t", 5);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1b[8;24;80t", S.last_data.?);
}
test "size without callback is silent" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    vt_write(t, "\x1B[18t", 5);
}
test "mode 2048 enable and disable use C callbacks" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var data: [128]u8 = undefined;
        var len: usize = 0;
        var calls: usize = 0;
        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, length: usize) callconv(lib.calling_conv) void {
            @memcpy(data[0..length], ptr[0..length]);
            len = length;
            calls += 1;
        }
        fn sizeCb(_: Terminal, _: ?*anyopaque, out_size: *size_report.Size) callconv(lib.calling_conv) bool {
            out_size.* = .{
                .rows = 24,
                .columns = 80,
                .cell_width = 8,
                .cell_height = 16,
            };
            return true;
        }
    };
    S.len = 0;
    S.calls = 0;
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .size_cb, @ptrCast(&S.sizeCb)));
    const enable = "\x1B[?2048h";
    const disable = "\x1B[?2048l";
    vt_write(t, enable, enable.len);
    vt_write(t, enable, enable.len);
    try testing.expectEqual(@as(usize, 2), S.calls);
    try testing.expectEqualStrings("\x1B[48;24;80;384;640t", S.data[0..S.len]);
    vt_write(t, disable, disable.len);
    try testing.expectEqual(@as(usize, 2), S.calls);
    try testing.expect(!t.?.terminal.modes.get(.in_band_size_reports));
}
test "mode 2048 enable tolerates missing C callbacks" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var writes: usize = 0;
        var sizes: usize = 0;
        fn writePty(_: Terminal, _: ?*anyopaque, _: [*]const u8, _: usize) callconv(lib.calling_conv) void {
            writes += 1;
        }
        fn sizeCb(_: Terminal, _: ?*anyopaque, out_size: *size_report.Size) callconv(lib.calling_conv) bool {
            sizes += 1;
            out_size.* = .{
                .rows = 24,
                .columns = 80,
                .cell_width = 8,
                .cell_height = 16,
            };
            return true;
        }
    };
    S.writes = 0;
    S.sizes = 0;
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    const sequence = "\x1B[?2048h";
    vt_write(t, sequence, sequence.len);
    try testing.expectEqual(@as(usize, 0), S.writes);
    try testing.expect(t.?.terminal.modes.get(.in_band_size_reports));
    var no_write: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &no_write,
        80,
        24,
    ));
    defer free(no_write);
    try testing.expectEqual(Result.success, set(no_write, .size_cb, @ptrCast(&S.sizeCb)));
    vt_write(no_write, sequence, sequence.len);
    try testing.expectEqual(@as(usize, 1), S.sizes);
    try testing.expect(no_write.?.terminal.modes.get(.in_band_size_reports));
}
test "set device_attributes callback primary" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var last_data: ?[]u8 = null;
        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }
        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
        fn da(_: Terminal, _: ?*anyopaque, out: *Effects.CDeviceAttributes) callconv(lib.calling_conv) bool {
            out.* = .{
                .primary = .{
                    .conformance_level = 64,
                    .features = .{ 22, 52 } ++ .{0} ** 62,
                    .num_features = 2,
                },
                .secondary = .{
                    .device_type = 1,
                    .firmware_version = 10,
                    .rom_cartridge = 0,
                },
                .tertiary = .{ .unit_id = 0 },
            };
            return true;
        }
    };
    defer S.deinit();
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .device_attributes, @ptrCast(&S.da)));
    vt_write(t, "\x1B[c", 3);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1b[?64;22;52c", S.last_data.?);
}
test "set device_attributes callback secondary" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var last_data: ?[]u8 = null;
        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }
        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
        fn da(_: Terminal, _: ?*anyopaque, out: *Effects.CDeviceAttributes) callconv(lib.calling_conv) bool {
            out.* = .{
                .primary = .{
                    .conformance_level = 62,
                    .features = .{22} ++ .{0} ** 63,
                    .num_features = 1,
                },
                .secondary = .{
                    .device_type = 1,
                    .firmware_version = 10,
                    .rom_cartridge = 0,
                },
                .tertiary = .{ .unit_id = 0 },
            };
            return true;
        }
    };
    defer S.deinit();
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .device_attributes, @ptrCast(&S.da)));
    vt_write(t, "\x1B[>c", 4);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1b[>1;10;0c", S.last_data.?);
}
test "set device_attributes callback tertiary" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var last_data: ?[]u8 = null;
        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }
        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
        fn da(_: Terminal, _: ?*anyopaque, out: *Effects.CDeviceAttributes) callconv(lib.calling_conv) bool {
            out.* = .{
                .primary = .{
                    .conformance_level = 62,
                    .features = .{0} ** 64,
                    .num_features = 0,
                },
                .secondary = .{
                    .device_type = 1,
                    .firmware_version = 0,
                    .rom_cartridge = 0,
                },
                .tertiary = .{ .unit_id = 0xAABBCCDD },
            };
            return true;
        }
    };
    defer S.deinit();
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .device_attributes, @ptrCast(&S.da)));
    vt_write(t, "\x1B[=c", 4);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1bP!|AABBCCDD\x1b\\", S.last_data.?);
}
test "device_attributes without callback uses default" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var last_data: ?[]u8 = null;
        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }
        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
    };
    defer S.deinit();
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    vt_write(t, "\x1B[c", 3);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1b[?62;22c", S.last_data.?);
}
test "device_attributes callback returns false uses default" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var last_data: ?[]u8 = null;
        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }
        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
        fn da(_: Terminal, _: ?*anyopaque, _: *Effects.CDeviceAttributes) callconv(lib.calling_conv) bool {
            return false;
        }
    };
    defer S.deinit();
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .device_attributes, @ptrCast(&S.da)));
    vt_write(t, "\x1B[c", 3);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1b[?62;22c", S.last_data.?);
}
test "set and get title" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var title: lib.String = undefined;
    try testing.expectEqual(Result.success, get(t, .title, @ptrCast(&title)));
    try testing.expectEqual(@as(usize, 0), title.len);
    const hello: lib.String = .{ .ptr = "Hello", .len = 5 };
    try testing.expectEqual(Result.success, set(t, .title, @ptrCast(&hello)));
    try testing.expectEqual(Result.success, get(t, .title, @ptrCast(&title)));
    try testing.expectEqualStrings("Hello", title.ptr[0..title.len]);
    const world: lib.String = .{ .ptr = "World", .len = 5 };
    try testing.expectEqual(Result.success, set(t, .title, @ptrCast(&world)));
    try testing.expectEqual(Result.success, get(t, .title, @ptrCast(&title)));
    try testing.expectEqualStrings("World", title.ptr[0..title.len]);
    try testing.expectEqual(Result.success, set(t, .title, null));
    try testing.expectEqual(Result.success, get(t, .title, @ptrCast(&title)));
    try testing.expectEqual(@as(usize, 0), title.len);
}
test "set and get pwd" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var pwd: lib.String = undefined;
    try testing.expectEqual(Result.success, get(t, .pwd, @ptrCast(&pwd)));
    try testing.expectEqual(@as(usize, 0), pwd.len);
    const home: lib.String = .{ .ptr = "/home/user", .len = 10 };
    try testing.expectEqual(Result.success, set(t, .pwd, @ptrCast(&home)));
    try testing.expectEqual(Result.success, get(t, .pwd, @ptrCast(&pwd)));
    try testing.expectEqualStrings("/home/user", pwd.ptr[0..pwd.len]);
    try testing.expectEqual(Result.success, set(t, .pwd, null));
    try testing.expectEqual(Result.success, get(t, .pwd, @ptrCast(&pwd)));
    try testing.expectEqual(@as(usize, 0), pwd.len);
}
test "get title set via vt_write" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    vt_write(t, "\x1B]2;VT Title\x1B\\", 14);
    var title: lib.String = undefined;
    try testing.expectEqual(Result.success, get(t, .title, @ptrCast(&title)));
    try testing.expectEqualStrings("VT Title", title.ptr[0..title.len]);
}
test "title report requires explicit opt in" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var last_data: ?[]u8 = null;
        fn deinit() void {
            if (last_data) |data| testing.allocator.free(data);
            last_data = null;
        }
        fn writePty(
            _: Terminal,
            _: ?*anyopaque,
            ptr: [*]const u8,
            len: usize,
        ) callconv(lib.calling_conv) void {
            if (last_data) |data| testing.allocator.free(data);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
    };
    S.last_data = null;
    defer S.deinit();
    try testing.expectEqual(
        Result.success,
        set(t, .write_pty, @ptrCast(&S.writePty)),
    );
    const set_title = "\x1B]2;echo vulnerable\x1B\\";
    const query_title = "\x1B[21t";
    vt_write(t, set_title, set_title.len);
    vt_write(t, query_title, query_title.len);
    try testing.expect(S.last_data == null);
    const enabled = true;
    try testing.expectEqual(Result.success, set(t, .title_report, &enabled));
    vt_write(t, query_title, query_title.len);
    try testing.expectEqualStrings(
        "\x1b]lecho vulnerable\x1b\\",
        S.last_data.?,
    );
    S.deinit();
    try testing.expectEqual(Result.success, set(t, .title_report, null));
    vt_write(t, query_title, query_title.len);
    try testing.expect(S.last_data == null);
}
test "checksum report requires explicit opt in" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var last_data: ?[]u8 = null;
        fn deinit() void {
            if (last_data) |data| testing.allocator.free(data);
            last_data = null;
        }
        fn writePty(
            _: Terminal,
            _: ?*anyopaque,
            ptr: [*]const u8,
            len: usize,
        ) callconv(lib.calling_conv) void {
            if (last_data) |data| testing.allocator.free(data);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
    };
    S.last_data = null;
    defer S.deinit();
    try testing.expectEqual(
        Result.success,
        set(t, .write_pty, @ptrCast(&S.writePty)),
    );
    const text = "hello";
    const query = "\x1B[1;1;1;1;1;5*y";
    vt_write(t, text, text.len);
    vt_write(t, query, query.len);
    try testing.expect(S.last_data == null);
    const enabled = true;
    try testing.expectEqual(Result.success, set(t, .xt_checksum_report, &enabled));
    vt_write(t, query, query.len);
    try testing.expectEqualStrings("\x1bP1!~FDEC\x1b\\", S.last_data.?);
    S.deinit();
    try testing.expectEqual(Result.success, set(t, .xt_checksum_report, null));
    vt_write(t, query, query.len);
    try testing.expect(S.last_data == null);
}
test "checksum extension survives resets" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var last_data: ?[]u8 = null;
        fn deinit() void {
            if (last_data) |data| testing.allocator.free(data);
            last_data = null;
        }
        fn writePty(
            _: Terminal,
            _: ?*anyopaque,
            ptr: [*]const u8,
            len: usize,
        ) callconv(lib.calling_conv) void {
            if (last_data) |data| testing.allocator.free(data);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
    };
    S.last_data = null;
    defer S.deinit();
    const enabled = true;
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .xt_checksum_report, &enabled));
    const positive: u8 = 1;
    try testing.expectEqual(Result.success, set(t, .xt_checksum_extension, &positive));
    const text = "hello";
    const query = "\x1B[1;1;1;1;1;5*y";
    vt_write(t, text, text.len);
    vt_write(t, query, query.len);
    try testing.expectEqualStrings("\x1bP1!~0214\x1b\\", S.last_data.?);
    const negate = "\x1B[0#y";
    const ris = "\x1Bc";
    vt_write(t, negate, negate.len);
    vt_write(t, ris, ris.len);
    vt_write(t, text, text.len);
    vt_write(t, query, query.len);
    try testing.expectEqualStrings("\x1bP1!~0214\x1b\\", S.last_data.?);
    try testing.expectEqual(Result.success, set(t, .xt_checksum_extension, null));
    vt_write(t, query, query.len);
    try testing.expectEqualStrings("\x1bP1!~FDEC\x1b\\", S.last_data.?);
    const invalid: u8 = 32;
    try testing.expectEqual(Result.invalid_value, set(t, .xt_checksum_extension, &invalid));
}
test "resize updates pixel dimensions" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    try testing.expectEqual(Result.success, resize(t, 80, 24, 9, 18));
    const zt = t.?.terminal;
    try testing.expectEqual(@as(u32, 80 * 9), zt.width_px);
    try testing.expectEqual(@as(u32, 24 * 18), zt.height_px);
}
test "resize pixel overflow saturates" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    try testing.expectEqual(Result.success, resize(t, 100, 40, std.math.maxInt(u32), std.math.maxInt(u32)));
    const zt = t.?.terminal;
    try testing.expectEqual(std.math.maxInt(u32), zt.width_px);
    try testing.expectEqual(std.math.maxInt(u32), zt.height_px);
}
test "resize disables synchronized output" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const zt = t.?.terminal;
    zt.modes.set(.synchronized_output, true);
    try testing.expectEqual(Result.success, resize(t, 80, 24, 9, 18));
    try testing.expect(!zt.modes.get(.synchronized_output));
}
test "resize sends in-band size report" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var last_data: ?[]u8 = null;
        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }
        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
    };
    defer S.deinit();
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    t.?.terminal.modes.set(.in_band_size_reports, true);
    try testing.expectEqual(Result.success, resize(t, 100, 40, 9, 18));
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1B[48;40;100;720;900t", S.last_data.?);
}
test "resize no size report without mode 2048" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const S = struct {
        var called: bool = false;
        fn writePty(_: Terminal, _: ?*anyopaque, _: [*]const u8, _: usize) callconv(lib.calling_conv) void {
            called = true;
        }
    };
    S.called = false;
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, resize(t, 100, 40, 9, 18));
    try testing.expect(!S.called);
}
test "resize in-band report without write_pty callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    t.?.terminal.modes.set(.in_band_size_reports, true);
    try testing.expectEqual(Result.success, resize(t, 100, 40, 9, 18));
}
test "resize null terminal" {
    try testing.expectEqual(Result.invalid_value, resize(null, 100, 40, 9, 18));
}
test "resize zero cols" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    try testing.expectEqual(Result.invalid_value, resize(t, 0, 40, 9, 18));
}
test "resize zero rows" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    try testing.expectEqual(Result.invalid_value, resize(t, 100, 0, 9, 18));
}
test "grid_ref out of bounds" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var out_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.invalid_value, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 100, .y = 0 } },
    }, &out_ref));
}
test "set and get color_foreground" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var rgb: color.RGB.C = undefined;
    try testing.expectEqual(Result.no_value, get(t, .color_foreground, @ptrCast(&rgb)));
    const fg: color.RGB.C = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
    try testing.expectEqual(Result.success, set(t, .color_foreground, @ptrCast(&fg)));
    try testing.expectEqual(Result.success, get(t, .color_foreground, @ptrCast(&rgb)));
    try testing.expectEqual(fg, rgb);
    try testing.expectEqual(Result.success, set(t, .color_foreground, null));
    try testing.expectEqual(Result.no_value, get(t, .color_foreground, @ptrCast(&rgb)));
}
test "set and get color_background" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var rgb: color.RGB.C = undefined;
    try testing.expectEqual(Result.no_value, get(t, .color_background, @ptrCast(&rgb)));
    const bg: color.RGB.C = .{ .r = 0x11, .g = 0x22, .b = 0x33 };
    try testing.expectEqual(Result.success, set(t, .color_background, @ptrCast(&bg)));
    try testing.expectEqual(Result.success, get(t, .color_background, @ptrCast(&rgb)));
    try testing.expectEqual(bg, rgb);
    try testing.expectEqual(Result.success, set(t, .color_background, null));
    try testing.expectEqual(Result.no_value, get(t, .color_background, @ptrCast(&rgb)));
}
test "set and get color_cursor" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var rgb: color.RGB.C = undefined;
    try testing.expectEqual(Result.no_value, get(t, .color_cursor, @ptrCast(&rgb)));
    const cur: color.RGB.C = .{ .r = 0xFF, .g = 0x00, .b = 0x88 };
    try testing.expectEqual(Result.success, set(t, .color_cursor, @ptrCast(&cur)));
    try testing.expectEqual(Result.success, get(t, .color_cursor, @ptrCast(&rgb)));
    try testing.expectEqual(cur, rgb);
    try testing.expectEqual(Result.success, set(t, .color_cursor, null));
    try testing.expectEqual(Result.no_value, get(t, .color_cursor, @ptrCast(&rgb)));
}
test "set and get color_palette" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var palette: color.PaletteC = undefined;
    try testing.expectEqual(Result.success, get(t, .color_palette, @ptrCast(&palette)));
    try testing.expectEqual(color.default[0].cval(), palette[0]);
    var custom: color.PaletteC = color.paletteCval(&color.default);
    custom[0] = .{ .r = 0x12, .g = 0x34, .b = 0x56 };
    try testing.expectEqual(Result.success, set(t, .color_palette, @ptrCast(&custom)));
    try testing.expectEqual(Result.success, get(t, .color_palette, @ptrCast(&palette)));
    try testing.expectEqual(custom[0], palette[0]);
    try testing.expectEqual(Result.success, set(t, .color_palette, null));
    try testing.expectEqual(Result.success, get(t, .color_palette, @ptrCast(&palette)));
    try testing.expectEqual(color.default[0].cval(), palette[0]);
}
test "get color default vs effective with override" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const zt = t.?.terminal;
    var rgb: color.RGB.C = undefined;
    const fg: color.RGB.C = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
    const bg: color.RGB.C = .{ .r = 0x11, .g = 0x22, .b = 0x33 };
    const cur: color.RGB.C = .{ .r = 0xFF, .g = 0x00, .b = 0x88 };
    try testing.expectEqual(Result.success, set(t, .color_foreground, @ptrCast(&fg)));
    try testing.expectEqual(Result.success, set(t, .color_background, @ptrCast(&bg)));
    try testing.expectEqual(Result.success, set(t, .color_cursor, @ptrCast(&cur)));
    const override: color.RGB = .{ .r = 0x00, .g = 0x00, .b = 0x00 };
    zt.colors.foreground.override = override;
    zt.colors.background.override = override;
    zt.colors.cursor.override = override;
    try testing.expectEqual(Result.success, get(t, .color_foreground, @ptrCast(&rgb)));
    try testing.expectEqual(override.cval(), rgb);
    try testing.expectEqual(Result.success, get(t, .color_background, @ptrCast(&rgb)));
    try testing.expectEqual(override.cval(), rgb);
    try testing.expectEqual(Result.success, get(t, .color_cursor, @ptrCast(&rgb)));
    try testing.expectEqual(override.cval(), rgb);
    try testing.expectEqual(Result.success, get(t, .color_foreground_default, @ptrCast(&rgb)));
    try testing.expectEqual(fg, rgb);
    try testing.expectEqual(Result.success, get(t, .color_background_default, @ptrCast(&rgb)));
    try testing.expectEqual(bg, rgb);
    try testing.expectEqual(Result.success, get(t, .color_cursor_default, @ptrCast(&rgb)));
    try testing.expectEqual(cur, rgb);
}
test "get color default returns no_value when unset" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var rgb: color.RGB.C = undefined;
    try testing.expectEqual(Result.no_value, get(t, .color_foreground_default, @ptrCast(&rgb)));
    try testing.expectEqual(Result.no_value, get(t, .color_background_default, @ptrCast(&rgb)));
    try testing.expectEqual(Result.no_value, get(t, .color_cursor_default, @ptrCast(&rgb)));
}
test "get color_palette_default vs current" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const zt = t.?.terminal;
    var custom: color.PaletteC = color.paletteCval(&color.default);
    custom[0] = .{ .r = 0x12, .g = 0x34, .b = 0x56 };
    try testing.expectEqual(Result.success, set(t, .color_palette, @ptrCast(&custom)));
    zt.colors.palette.set(0, .{ .r = 0xFF, .g = 0xFF, .b = 0xFF });
    var palette: color.PaletteC = undefined;
    try testing.expectEqual(Result.success, get(t, .color_palette, @ptrCast(&palette)));
    try testing.expectEqual(color.RGB.C{ .r = 0xFF, .g = 0xFF, .b = 0xFF }, palette[0]);
    try testing.expectEqual(Result.success, get(t, .color_palette_default, @ptrCast(&palette)));
    try testing.expectEqual(custom[0], palette[0]);
}
test "set color sets dirty flag" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const zt = t.?.terminal;
    zt.flags.dirty.palette = false;
    const fg: color.RGB.C = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF };
    try testing.expectEqual(Result.success, set(t, .color_foreground, @ptrCast(&fg)));
    try testing.expect(zt.flags.dirty.palette);
}
test "set glyph protocol disables APC handling and clears glossary" {
    if (comptime !build_options.glyph_protocol) return error.SkipZigTest;
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    const register = "\x1B_25a1;r;cp=e0a0;AAAAAAAAAAAAAA==\x1B\\";
    vt_write(t, register, register.len);
    try testing.expect(t.?.terminal.glyph_glossary.contains(0xE0A0));
    const disabled = false;
    try testing.expectEqual(Result.success, set(t, .glyph_protocol, @ptrCast(&disabled)));
    try testing.expect(!t.?.stream.handler.apc_handler.enabled.contains(.glyph));
    try testing.expect(!t.?.terminal.glyph_glossary.contains(0xE0A0));
    vt_write(t, register, register.len);
    try testing.expect(!t.?.terminal.glyph_glossary.contains(0xE0A0));
    const enabled = true;
    try testing.expectEqual(Result.success, set(t, .glyph_protocol, @ptrCast(&enabled)));
    vt_write(t, register, register.len);
    try testing.expect(t.?.terminal.glyph_glossary.contains(0xE0A0));
}
test "get_multi success" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var cols: u16 = 0;
    var rows: u16 = 0;
    var written: usize = 0;
    const keys = [_]TerminalData{ .cols, .rows };
    var values = [_]?*anyopaque{ @ptrCast(&cols), @ptrCast(&rows) };
    try testing.expectEqual(Result.success, get_multi(t, keys.len, &keys, &values, &written));
    try testing.expectEqual(keys.len, written);
    try testing.expectEqual(80, cols);
    try testing.expectEqual(24, rows);
}
test "get_multi error sets out_written" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer free(t);
    var cols: u16 = 0;
    var written: usize = 99;
    const keys = [_]TerminalData{ .cols, .invalid };
    var values = [_]?*anyopaque{ @ptrCast(&cols), @ptrCast(&cols) };
    try testing.expectEqual(Result.invalid_value, get_multi(t, keys.len, &keys, &values, &written));
    try testing.expectEqual(1, written);
    try testing.expectEqual(80, cols);
}
test "get_multi null keys returns invalid_value" {
    var cols: u16 = 0;
    var values = [_]?*anyopaque{@ptrCast(&cols)};
    try testing.expectEqual(Result.invalid_value, get_multi(null, 1, null, &values, null));
}
test "get mouse_shape" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(&lib.alloc.test_allocator, &t, 80, 24));
    defer free(t);
    var shape: mouse.Shape = undefined;
    try testing.expectEqual(Result.success, get(t, .mouse_shape, @ptrCast(&shape)));
    try testing.expectEqual(mouse.Shape.text, shape);
    const cases = .{
        .{ "\x1b]22;pointer\x07", mouse.Shape.pointer },
        .{ "\x1b]22;crosshair\x1b\\", mouse.Shape.crosshair },
        .{ "\x1b]22;not-a-pointer-shape\x07", mouse.Shape.crosshair },
        .{ "\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\", mouse.Shape.crosshair },
        .{ "\x1b]22;\x1b\\", mouse.Shape.text },
        .{ "\x1b]22;default\x07", mouse.Shape.default },
        .{ "\x1b]22;text\x07", mouse.Shape.text },
    };
    inline for (cases) |case| {
        vt_write(t, case[0], case[0].len);
        try testing.expectEqual(Result.success, get(t, .mouse_shape, @ptrCast(&shape)));
        try testing.expectEqual(case[1], shape);
    }
    const prefix = "\x1b]22;wait";
    vt_write(t, prefix, prefix.len);
    try testing.expectEqual(Result.success, get(t, .mouse_shape, @ptrCast(&shape)));
    try testing.expectEqual(mouse.Shape.text, shape);
    vt_write(t, "\x07", 1);
    try testing.expectEqual(Result.success, get(t, .mouse_shape, @ptrCast(&shape)));
    try testing.expectEqual(mouse.Shape.wait, shape);
}
