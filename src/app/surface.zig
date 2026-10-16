const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");
const build_config = @import("../build_config.zig");
const App = @import("../App.zig");
const Surface = @import("../Surface.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const Config = @import("../config.zig").Config;
const MessageData = @import("../datastruct/root.zig").MessageData;
pub const Message = union(enum) {
    pub const WriteReq = MessageData(u8, 255);
    pub const DesktopNotification = struct {
        title: [63:0]u8,
        body: [255:0]u8,
        pub fn init(title: []const u8, body: []const u8) DesktopNotification {
            var result: DesktopNotification = undefined;
            copyUtf8Z(result.title.len, &result.title, title);
            copyUtf8Z(result.body.len, &result.body, body);
            return result;
        }
        fn isUtf8ContinuationByte(byte: u8) bool {
            return switch (byte) {
                0x80...0xBF => true,
                else => false,
            };
        }
        fn copyUtf8Z(
            comptime capacity: usize,
            dst: *[capacity:0]u8,
            src: []const u8,
        ) void {
            var len = @min(src.len, capacity);
            while (len > 0 and
                len < src.len and
                isUtf8ContinuationByte(src[len])) : (len -= 1)
            {}
            @memcpy(dst[0..len], src[0..len]);
            dst[len] = 0;
        }
    };
    set_title: [256]u8,
    report_title: ReportTitleStyle,
    resize_window: terminal.StreamAction.ResizeWindow,
    set_mouse_shape: terminal.MouseShape,
    clipboard_read: apprt.Clipboard,
    kitty_clipboard_read: *apprt.ClipboardRequest.KittyRead,
    kitty_clipboard_write: *apprt.ClipboardRequest.KittyWrite,
    clipboard_write: struct {
        clipboard_type: apprt.Clipboard,
        req: WriteReq,
    },
    change_config: *const Config,
    close: void,
    child_exited: ChildExited,
    desktop_notification: DesktopNotification,
    renderer_health: renderer.Health,
    present_surface: void,
    password_input: bool,
    color_change: terminal.osc.color.ColoredTarget,
    selection_scroll_tick: bool,
    pwd_change: WriteReq,
    ring_bell,
    progress_report: terminal.osc.Command.ProgressReport,
    start_command,
    stop_command: ?u8,
    scrollbar: terminal.Scrollbar,
    search_total: ?usize,
    search_selected: ?usize,
    redraw,
    pub const ReportTitleStyle = enum {
        csi_21_t,
    };
    pub const ChildExited = extern struct {
        exit_code: u32,
        runtime_ms: u64,
        pub const getGObjectType = switch (build_config.app_runtime) {
            .gtk,
            => @import("gobject").ext.defineBoxed(
                ChildExited,
                .{ .name = "WaspApprtChildExited" },
            ),
            .none => void,
        };
    };
};
pub const Mailbox = struct {
    surface: *Surface,
    app: App.Mailbox,
    pub fn push(
        self: Mailbox,
        msg: Message,
        timeout: App.Mailbox.Queue.Timeout,
    ) App.Mailbox.Queue.Size {
        return self.app.push(.{
            .surface_message = .{
                .surface = self.surface,
                .message = msg,
            },
        }, timeout);
    }
};
pub const NewSurfaceContext = enum(c_int) {
    window = 0,
    tab = 1,
    split = 2,
};
pub fn shouldInheritWorkingDirectory(context: NewSurfaceContext, config: *const Config) bool {
    return switch (context) {
        .window => config.@"window-inherit-working-directory",
        .tab => config.@"tab-inherit-working-directory",
        .split => config.@"split-inherit-working-directory",
    };
}
pub fn newConfig(
    app: *const App,
    config: *const Config,
    context: NewSurfaceContext,
) Allocator.Error!Config {
    var copy = config.shallowClone(app.alloc);
    const alloc = copy._arena.?.allocator();
    const prev = app.focusedSurface();
    if (prev) |p| {
        if (shouldInheritWorkingDirectory(context, config)) {
            if (try p.pwd(alloc)) |pwd| {
                copy.@"working-directory" = .{ .path = pwd };
            }
        }
    }
    return copy;
}
test "DesktopNotification init" {
    const notification = Message.DesktopNotification.init("Title", "Body");
    try std.testing.expectEqualStrings("Title", std.mem.sliceTo(&notification.title, 0));
    try std.testing.expectEqualStrings("Body", std.mem.sliceTo(&notification.body, 0));
}
test "copyUtf8Z handles len at the final byte of every UTF-8 sequence length" {
    const DesktopNotification = Message.DesktopNotification;
    var dst_1_byte: [1:0]u8 = undefined;
    const src_ending_in_1_byte_codepoint = "ab";
    try std.testing.expect(!DesktopNotification.isUtf8ContinuationByte(
        src_ending_in_1_byte_codepoint[dst_1_byte.len],
    ));
    DesktopNotification.copyUtf8Z(
        dst_1_byte.len,
        &dst_1_byte,
        src_ending_in_1_byte_codepoint,
    );
    try std.testing.expectEqualStrings("a", std.mem.sliceTo(&dst_1_byte, 0));
    var dst_2_bytes: [2:0]u8 = undefined;
    const src_ending_in_2_byte_codepoint = "aЯ";
    try std.testing.expect(DesktopNotification.isUtf8ContinuationByte(
        src_ending_in_2_byte_codepoint[dst_2_bytes.len],
    ));
    DesktopNotification.copyUtf8Z(
        dst_2_bytes.len,
        &dst_2_bytes,
        src_ending_in_2_byte_codepoint,
    );
    try std.testing.expectEqualStrings("a", std.mem.sliceTo(&dst_2_bytes, 0));
    var dst_3_bytes: [3:0]u8 = undefined;
    const src_ending_in_3_byte_codepoint = "a€";
    try std.testing.expect(DesktopNotification.isUtf8ContinuationByte(
        src_ending_in_3_byte_codepoint[dst_3_bytes.len],
    ));
    DesktopNotification.copyUtf8Z(
        dst_3_bytes.len,
        &dst_3_bytes,
        src_ending_in_3_byte_codepoint,
    );
    try std.testing.expectEqualStrings("a", std.mem.sliceTo(&dst_3_bytes, 0));
    var dst_4_bytes: [4:0]u8 = undefined;
    const src_ending_in_4_byte_codepoint = "a😀";
    try std.testing.expect(DesktopNotification.isUtf8ContinuationByte(
        src_ending_in_4_byte_codepoint[dst_4_bytes.len],
    ));
    DesktopNotification.copyUtf8Z(
        dst_4_bytes.len,
        &dst_4_bytes,
        src_ending_in_4_byte_codepoint,
    );
    try std.testing.expectEqualStrings("a", std.mem.sliceTo(&dst_4_bytes, 0));
}
test "copyUtf8Z keeps a complete codepoint at the truncation boundary" {
    var dst: [5:0]u8 = undefined;
    Message.DesktopNotification.copyUtf8Z(dst.len, &dst, "abcЯz");
    try std.testing.expectEqualStrings("abcЯ", std.mem.sliceTo(&dst, 0));
}
test "copyUtf8Z preserves UTF-8 that fits" {
    var dst: [5:0]u8 = undefined;
    Message.DesktopNotification.copyUtf8Z(dst.len, &dst, "abcЯ");
    try std.testing.expectEqualStrings("abcЯ", std.mem.sliceTo(&dst, 0));
}
