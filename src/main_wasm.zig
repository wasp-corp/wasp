const std = @import("std");
const builtin = @import("builtin");
comptime {
    _ = @import("os/wasm.zig");
    _ = @import("font/root.zig");
    _ = @import("terminal/main.zig");
    _ = @import("config.zig").Wasm;
    _ = @import("App.zig").Wasm;
}
pub const std_options = struct {
    pub const log_level: std.log.Level = switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSmall => .warn,
        else => .info,
    };
    pub const logFn = @import("os/wasm/log.zig").log;
};
