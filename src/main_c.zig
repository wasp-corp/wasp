const std = @import("std");
const assert = @import("quirks.zig").inlineAssert;
const posix = std.posix;
const builtin = @import("builtin");
const build_config = @import("build_config.zig");
const main = @import("main_wasp.zig");
const global = @import("global.zig");
const apprt = @import("apprt.zig");
const internal_os = @import("os/root.zig");
const windows = @import("os/windows.zig");
comptime {
    if (!builtin.is_test) {
        assert(apprt.runtime == apprt.embedded);
    }
}
pub const std_options = main.std_options;
comptime {
    _ = @import("config.zig").CApi;
    if (@hasDecl(apprt.runtime, "CAPI")) _ = apprt.runtime.CAPI;
    _ = @import("benchmark/main.zig").CApi;
    _ = @import("quirks_memset.zig");
}
const Info = extern struct {
    mode: BuildMode,
    version: [*]const u8,
    version_len: usize,
    const BuildMode = enum(c_int) {
        debug,
        release_safe,
        release_fast,
        release_small,
    };
};
pub const String = extern struct {
    ptr: ?[*]const u8,
    len: usize,
    sentinel: bool,
    pub const empty: String = .{
        .ptr = null,
        .len = 0,
        .sentinel = false,
    };
    pub fn fromSlice(slice: anytype) String {
        return .{
            .ptr = slice.ptr,
            .len = slice.len,
            .sentinel = sentinel: {
                const info = @typeInfo(@TypeOf(slice));
                switch (info) {
                    .pointer => |p| {
                        if (p.size != .slice) @compileError("only slices supported");
                        if (p.child != u8) @compileError("only u8 slices supported");
                        const sentinel_ = p.sentinel();
                        if (sentinel_) |sentinel| if (sentinel != 0) @compileError("only 0 is supported for sentinels");
                        break :sentinel sentinel_ != null;
                    },
                    else => @compileError("only []const u8 and [:0]const u8"),
                }
            },
        };
    }
    pub fn deinit(self: *const String) void {
        const ptr = self.ptr orelse return;
        if (self.sentinel) {
            global.alloc().free(ptr[0..self.len :0]);
        } else {
            global.alloc().free(ptr[0..self.len]);
        }
    }
};
pub export fn wasp_init(argc: usize, argv: [*][*:0]u8) c_int {
    assert(builtin.link_libc);
    global.init(.{
        .c = .{
            .argc = argc,
            .argv = argv,
            .environ = if (std.process.Environ.Block == std.process.Environ.PosixBlock)
                .{ .block = .{ .slice = std.c.environ[0..env_len: {
                    var len: usize = 0;
                    while (std.c.environ[len]) |_| : (len += 1) {}
                    break :env_len len;
                } :null] } }
            else
                .{ .block = .{ .use_global = true } },
        },
    }) catch |err| {
        std.log.err("failed to initialize wasp error={}", .{err});
        return 1;
    };
    return 0;
}
pub export fn wasp_cli_try_action() void {
    const action = global.action() orelse return;
    std.log.info("executing CLI action={}", .{action});
    posix.system.exit(action.run(global.alloc()) catch |err| {
        std.log.err("CLI action failed error={}", .{err});
        posix.system.exit(1);
    });
    posix.system.exit(0);
}
pub export fn wasp_info() Info {
    return .{
        .mode = switch (builtin.mode) {
            .Debug => .debug,
            .ReleaseSafe => .release_safe,
            .ReleaseFast => .release_fast,
            .ReleaseSmall => .release_small,
        },
        .version = build_config.version_string.ptr,
        .version_len = build_config.version_string.len,
    };
}
pub export fn wasp_translate(msgid: [*:0]const u8) [*:0]const u8 {
    return internal_os.i18n._(msgid);
}
pub export fn wasp_string_free(str: String) void {
    str.deinit();
}
pub const DllMain = if (builtin.os.tag == .windows) struct {
    const BOOL = windows.BOOL;
    const HINSTANCE = windows.HINSTANCE;
    const DWORD = windows.DWORD;
    const LPVOID = windows.LPVOID;
    const TRUE = windows.TRUE;
    const FALSE = windows.FALSE;
    const DLL_PROCESS_ATTACH: DWORD = 1;
    const DLL_PROCESS_DETACH: DWORD = 0;
    const __vcrt_initialize = @extern(*const fn () callconv(.c) c_int, .{ .name = "__vcrt_initialize" });
    const __vcrt_uninitialize = @extern(*const fn (c_int) callconv(.c) c_int, .{ .name = "__vcrt_uninitialize" });
    const __acrt_initialize = @extern(*const fn () callconv(.c) c_int, .{ .name = "__acrt_initialize" });
    const __acrt_uninitialize = @extern(*const fn (c_int) callconv(.c) c_int, .{ .name = "__acrt_uninitialize" });
    pub fn handler(_: HINSTANCE, fdwReason: DWORD, _: LPVOID) callconv(.winapi) BOOL {
        if (builtin.abi != .msvc) return TRUE;
        switch (fdwReason) {
            DLL_PROCESS_ATTACH => {
                if (__vcrt_initialize() < 0) return FALSE;
                if (__acrt_initialize() < 0) return FALSE;
                return TRUE;
            },
            DLL_PROCESS_DETACH => {
                _ = __acrt_uninitialize(1);
                _ = __vcrt_uninitialize(1);
                return TRUE;
            },
            else => return TRUE,
        }
    }
}.handler else void;
test "wasp_string_s empty string" {
    const testing = std.testing;
    const empty_string = String.empty;
    defer empty_string.deinit();
    try testing.expect(empty_string.len == 0);
    try testing.expect(empty_string.sentinel == false);
}
test "wasp_string_s c string" {
    const testing = std.testing;
    const slice: [:0]const u8 = "hello";
    const allocated_slice = try testing.allocator.dupeZ(u8, slice);
    const c_null_string = String.fromSlice(allocated_slice);
    defer c_null_string.deinit();
    try testing.expect(allocated_slice[5] == 0);
    try testing.expect(@TypeOf(slice) == [:0]const u8);
    try testing.expect(@TypeOf(allocated_slice) == [:0]u8);
    try testing.expect(c_null_string.len == 5);
    try testing.expect(c_null_string.sentinel == true);
}
test "wasp_string_s zig string" {
    const testing = std.testing;
    const slice: []const u8 = "hello";
    const allocated_slice = try testing.allocator.dupe(u8, slice);
    const zig_string = String.fromSlice(allocated_slice);
    defer zig_string.deinit();
    try testing.expect(@TypeOf(slice) == []const u8);
    try testing.expect(@TypeOf(allocated_slice) == []u8);
    try testing.expect(zig_string.len == 5);
    try testing.expect(zig_string.sentinel == false);
}
