const std = @import("std");
const builtin = @import("builtin");
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
const terminal_sys = @import("../sys.zig");
const stderr = @import("../../os/stderr.zig");
const Result = @import("result.zig").Result;
pub const Image = extern struct {
    width: u32,
    height: u32,
    data: ?[*]u8,
    data_len: usize,
};
pub const DecodePngFn = *const fn (
    ?*anyopaque,
    *const CAllocator,
    [*]const u8,
    usize,
    *Image,
) callconv(lib.calling_conv) bool;
pub const RandomSecureFn = *const fn (
    ?*anyopaque,
    [*]u8,
    usize,
) callconv(lib.calling_conv) bool;
pub const LogLevel = enum(c_int) {
    @"error" = 0,
    warning = 1,
    info = 2,
    debug = 3,
    pub fn fromStd(level: std.log.Level) LogLevel {
        return switch (level) {
            .err => .@"error",
            .warn => .warning,
            .info => .info,
            .debug => .debug,
        };
    }
};
pub const LogFn = *const fn (
    ?*anyopaque,
    LogLevel,
    [*]const u8,
    usize,
    [*]const u8,
    usize,
) callconv(lib.calling_conv) void;
pub const Option = enum(c_int) {
    userdata = 0,
    decode_png = 1,
    log = 2,
    random_secure = 3,
    pub fn InType(comptime self: Option) type {
        return switch (self) {
            .userdata => ?*const anyopaque,
            .decode_png => ?DecodePngFn,
            .log => ?LogFn,
            .random_secure => ?RandomSecureFn,
        };
    }
};
const Global = struct {
    userdata: ?*anyopaque = null,
    decode_png: ?DecodePngFn = null,
    log: ?LogFn = null,
    random_secure: ?RandomSecureFn = null,
};
var global: Global = .{};
fn decodePngWrapper(
    alloc: std.mem.Allocator,
    data: []const u8,
) terminal_sys.DecodeError!terminal_sys.Image {
    const func = global.decode_png orelse return error.InvalidData;
    const c_alloc = CAllocator.fromZig(&alloc);
    var out: Image = std.mem.zeroes(Image);
    if (!func(global.userdata, &c_alloc, lib.String.init(data).ptr, data.len, &out)) return error.InvalidData;
    const result_data = out.data orelse return error.InvalidData;
    return .{
        .width = out.width,
        .height = out.height,
        .data = result_data[0..out.data_len],
    };
}
fn randomSecureWrapper(buffer: []u8) terminal_sys.RandomSecureError!void {
    const func = global.random_secure orelse return error.EntropyUnavailable;
    if (!func(global.userdata, buffer.ptr, buffer.len)) return error.EntropyUnavailable;
}
pub fn set(
    option: Option,
    value: ?*const anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.enums.fromInt(Option, @intFromEnum(option)) orelse {
            return .invalid_value;
        };
    }
    return switch (option) {
        inline else => |comptime_option| setTyped(
            comptime_option,
            @ptrCast(@alignCast(value)),
        ),
    };
}
fn setTyped(
    comptime option: Option,
    value: option.InType(),
) Result {
    switch (option) {
        .userdata => global.userdata = @constCast(value),
        .decode_png => {
            global.decode_png = value;
            terminal_sys.decode_png = if (value != null) &decodePngWrapper else null;
        },
        .log => global.log = value,
        .random_secure => {
            global.random_secure = value;
            terminal_sys.random_secure = if (value != null) &randomSecureWrapper else null;
        },
    }
    return .success;
}
fn emitLog(level: LogLevel, scope: []const u8, message: []const u8) void {
    const func = global.log orelse return;
    func(
        global.userdata,
        level,
        scope.ptr,
        scope.len,
        message.ptr,
        message.len,
    );
}
const LogEmitter = struct {
    const buffer_size = 2048;
    c_level: LogLevel,
    scope_text: []const u8,
    writer: std.Io.Writer,
    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        switch (data.len) {
            0 => unreachable,
            1 => if (splat == 0) return 0,
            else => {},
        }
        const self: *@This() = @fieldParentPtr("writer", w);
        if (w.end > 0) {
            emitLog(
                self.c_level,
                self.scope_text,
                w.buffer[0..w.end],
            );
        }
        const len: usize = @min(data[0].len, w.buffer.len);
        @memcpy(w.buffer[0..len], data[0][0..len]);
        w.end = len;
        return len;
    }
};
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (global.log == null) return;
    const scope_text: []const u8 = if (scope == .default) "" else @tagName(scope);
    const c_level = LogLevel.fromStd(level);
    var log_emitter_buffer: [LogEmitter.buffer_size]u8 = undefined;
    var log_emitter: LogEmitter = .{
        .c_level = c_level,
        .scope_text = scope_text,
        .writer = .{
            .buffer = &log_emitter_buffer,
            .vtable = &.{
                .drain = LogEmitter.drain,
            },
        },
    };
    nosuspend log_emitter.writer.print(format, args) catch {};
    log_emitter.writer.flush() catch {};
}
pub fn logStderr(
    _: ?*anyopaque,
    level: LogLevel,
    scope_ptr: [*]const u8,
    scope_len: usize,
    message_ptr: [*]const u8,
    message_len: usize,
) callconv(lib.calling_conv) void {
    if (comptime builtin.target.cpu.arch.isWasm()) return;
    const scope = scope_ptr[0..scope_len];
    const message = message_ptr[0..message_len];
    const level_text = switch (level) {
        .@"error" => "error",
        .warning => "warning",
        .info => "info",
        .debug => "debug",
    };
    var buffer: [LogEmitter.buffer_size + 128]u8 = undefined;
    const line: ?[]const u8 = if (scope.len > 0)
        std.fmt.bufPrint(&buffer, "[{s}]({s}): {s}\n", .{ level_text, scope, message }) catch null
    else
        std.fmt.bufPrint(&buffer, "[{s}]: {s}\n", .{ level_text, message }) catch null;
    if (line) |v| {
        stderr.write(v);
        return;
    }
    stderr.write("[");
    stderr.write(level_text);
    stderr.write("]");
    if (scope.len > 0) {
        stderr.write("(");
        stderr.write(scope);
        stderr.write(")");
    }
    stderr.write(": ");
    stderr.write(message);
    stderr.write("\n");
}
test "set decode_png with null clears" {
    global.decode_png = null;
    terminal_sys.decode_png = null;
    try std.testing.expectEqual(Result.success, set(.decode_png, null));
    try std.testing.expect(terminal_sys.decode_png == null);
}
test "set decode_png installs wrapper" {
    const S = struct {
        fn decode(_: ?*anyopaque, _: *const CAllocator, _: [*]const u8, _: usize, out: *Image) callconv(lib.calling_conv) bool {
            out.* = .{ .width = 1, .height = 1, .data = null, .data_len = 0 };
            return true;
        }
    };
    try std.testing.expectEqual(Result.success, set(
        .decode_png,
        @ptrCast(&S.decode),
    ));
    try std.testing.expect(terminal_sys.decode_png != null);
    try std.testing.expectEqual(Result.success, set(.decode_png, null));
    try std.testing.expect(terminal_sys.decode_png == null);
}
test "decode_png output is zeroed before the callback" {
    const S = struct {
        var seen: ?Image = null;
        fn decode(_: ?*anyopaque, _: *const CAllocator, _: [*]const u8, _: usize, out: *Image) callconv(lib.calling_conv) bool {
            seen = out.*;
            return true;
        }
    };
    try std.testing.expectEqual(Result.success, set(
        .decode_png,
        @ptrCast(&S.decode),
    ));
    defer _ = set(.decode_png, null);
    try std.testing.expectError(
        error.InvalidData,
        decodePngWrapper(std.testing.allocator, "png"),
    );
    try std.testing.expectEqual(std.mem.zeroes(Image), S.seen.?);
}
test "set log with null clears" {
    global.log = null;
    try std.testing.expectEqual(Result.success, set(.log, null));
    try std.testing.expect(global.log == null);
}
test "set log installs callback" {
    const S = struct {
        var called: bool = false;
        fn logCb(_: ?*anyopaque, _: LogLevel, _: [*]const u8, _: usize, _: [*]const u8, _: usize) callconv(lib.calling_conv) void {
            called = true;
        }
    };
    try std.testing.expectEqual(Result.success, set(.log, @ptrCast(&S.logCb)));
    try std.testing.expect(global.log != null);
    emitLog(.info, "test", "hello");
    try std.testing.expect(S.called);
    S.called = false;
    try std.testing.expectEqual(Result.success, set(.log, null));
    try std.testing.expect(global.log == null);
    emitLog(.info, "test", "should not arrive");
    try std.testing.expect(!S.called);
}
test "logFn small message single chunk" {
    const S = struct {
        var call_count: usize = 0;
        var total_len: usize = 0;
        fn logCb(_: ?*anyopaque, _: LogLevel, _: [*]const u8, _: usize, msg: [*]const u8, msg_len: usize) callconv(lib.calling_conv) void {
            _ = msg;
            call_count += 1;
            total_len += msg_len;
        }
    };
    S.call_count = 0;
    S.total_len = 0;
    global.log = @ptrCast(&S.logCb);
    defer {
        global.log = null;
    }
    logFn(.info, .default, "hello", .{});
    try std.testing.expectEqual(@as(usize, 1), S.call_count);
    try std.testing.expectEqual(@as(usize, 5), S.total_len);
}
test "logFn message exceeding chunk size is split" {
    const S = struct {
        var call_count: usize = 0;
        var total_len: usize = 0;
        fn logCb(_: ?*anyopaque, _: LogLevel, _: [*]const u8, _: usize, msg: [*]const u8, msg_len: usize) callconv(lib.calling_conv) void {
            _ = msg;
            call_count += 1;
            total_len += msg_len;
            std.debug.assert(msg_len <= 2048);
        }
    };
    S.call_count = 0;
    S.total_len = 0;
    global.log = @ptrCast(&S.logCb);
    defer {
        global.log = null;
    }
    const fill: [3000]u8 = .{0x41} ** 3000;
    logFn(.info, .default, "{s}", .{@as([]const u8, &fill)});
    try std.testing.expect(S.call_count >= 2);
    try std.testing.expectEqual(@as(usize, 3000), S.total_len);
}
test "logFn message exactly at chunk boundary" {
    const S = struct {
        var call_count: usize = 0;
        var total_len: usize = 0;
        fn logCb(_: ?*anyopaque, _: LogLevel, _: [*]const u8, _: usize, msg: [*]const u8, msg_len: usize) callconv(lib.calling_conv) void {
            _ = msg;
            call_count += 1;
            total_len += msg_len;
            std.debug.assert(msg_len <= 2048);
        }
    };
    S.call_count = 0;
    S.total_len = 0;
    global.log = @ptrCast(&S.logCb);
    defer {
        global.log = null;
    }
    const fill: [2048]u8 = .{0x42} ** 2048;
    logFn(.info, .default, "{s}", .{@as([]const u8, &fill)});
    try std.testing.expectEqual(@as(usize, 1), S.call_count);
    try std.testing.expectEqual(@as(usize, 2048), S.total_len);
}
test "logFn message exactly double chunk size" {
    const S = struct {
        var call_count: usize = 0;
        var total_len: usize = 0;
        fn logCb(_: ?*anyopaque, _: LogLevel, _: [*]const u8, _: usize, msg: [*]const u8, msg_len: usize) callconv(lib.calling_conv) void {
            _ = msg;
            call_count += 1;
            total_len += msg_len;
            std.debug.assert(msg_len <= 2048);
        }
    };
    S.call_count = 0;
    S.total_len = 0;
    global.log = @ptrCast(&S.logCb);
    defer {
        global.log = null;
    }
    const fill: [4096]u8 = .{0x43} ** 4096;
    logFn(.info, .default, "{s}", .{@as([]const u8, &fill)});
    try std.testing.expectEqual(@as(usize, 2), S.call_count);
    try std.testing.expectEqual(@as(usize, 4096), S.total_len);
}
test "set userdata" {
    var data: u32 = 42;
    try std.testing.expectEqual(Result.success, set(.userdata, @ptrCast(&data)));
    try std.testing.expect(global.userdata == @as(?*anyopaque, @ptrCast(&data)));
    try std.testing.expectEqual(Result.success, set(.userdata, null));
    try std.testing.expect(global.userdata == null);
}
