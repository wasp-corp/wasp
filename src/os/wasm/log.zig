const std = @import("std");
const wasm = @import("../wasm.zig");
pub const log = Freestanding.log;
pub fn noop(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = level;
    _ = scope;
    _ = format;
    _ = args;
}
pub const Freestanding = struct {
    pub fn log(
        comptime level: std.log.Level,
        comptime scope: @TypeOf(.EnumLiteral),
        comptime format: []const u8,
        args: anytype,
    ) void {
        var buf: [2048]u8 = undefined;
        const level_txt = comptime level.asText();
        const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
        const txt = level_txt ++ prefix ++ format;
        var allocated: bool = false;
        const str = nosuspend std.fmt.bufPrint(&buf, txt, args) catch str: {
            allocated = true;
            break :str std.fmt.allocPrint(wasm.alloc, txt, args) catch return;
        };
        defer if (allocated) wasm.alloc.free(str);
        JS.log(str.ptr, str.len);
    }
    const JS = struct {
        extern "env" fn log(ptr: [*]const u8, len: usize) void;
    };
};
