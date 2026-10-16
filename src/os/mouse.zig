const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc");
const log = std.log.scoped(.os);
pub fn clickInterval() ?u32 {
    return switch (builtin.os.tag) {
        .macos => macos: {
            const NSEvent = objc.getClass("NSEvent") orelse {
                log.err("NSEvent class not found. Can't get click interval.", .{});
                return null;
            };
            const interval = NSEvent.msgSend(f64, objc.sel("doubleClickInterval"), .{});
            const ms = @as(u32, @intFromFloat(@ceil(interval * 1000)));
            break :macos ms;
        },
        else => null,
    };
}
