const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const MessageData = @import("../datastruct/root.zig").MessageData;
pub const Message = union(enum) {
    pub const WriteReq = MessageData(u8, 38);
    color_scheme_report: struct {
        force: bool,
    },
    visibility_report: struct {
        visible: bool,
        force: bool,
    },
    crash: void,
    change_config: struct {
        alloc: Allocator,
        ptr: *termio.Termio.DerivedConfig,
    },
    inspector: bool,
    resize: renderer.Size,
    size_report: SizeReport,
    clear_screen: struct {
        history: bool,
    },
    scroll_viewport: terminal.Terminal.ScrollViewport,
    selection_scroll: bool,
    jump_to_prompt: isize,
    start_synchronized_output: void,
    linefeed_mode: bool,
    focused: bool,
    kitty_clipboard_grant_read: KittyClipboardGrant,
    kitty_clipboard_grant_write: KittyClipboardGrant,
    write_small: WriteReq.Small,
    write_stable: WriteReq.Stable,
    write_alloc: WriteReq.Alloc,
    pub const KittyClipboardGrant = struct {
        alloc: Allocator,
        pw: []const u8,
    };
    pub fn writeReq(alloc: Allocator, data: anytype) !Message {
        return switch (try WriteReq.init(alloc, data)) {
            .stable => unreachable,
            .small => |v| Message{ .write_small = v },
            .alloc => |v| Message{ .write_alloc = v },
        };
    }
    pub fn deinit(self: *const Message) void {
        switch (self.*) {
            .change_config => |v| {
                v.ptr.deinit();
                v.alloc.destroy(v.ptr);
            },
            .write_alloc => |v| v.alloc.free(v.data),
            .kitty_clipboard_grant_read,
            .kitty_clipboard_grant_write,
            => |v| v.alloc.free(v.pw),
            else => {},
        }
    }
    pub const SizeReport = terminal.size_report.Style;
};
test {
    std.testing.refAllDecls(@This());
}
test {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 40), @sizeOf(Message));
}
