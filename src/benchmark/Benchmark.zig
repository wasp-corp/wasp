const Benchmark = @This();
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const macos = @import("macos");
const build_config = @import("../build_config.zig");
const global = @import("../global.zig");
ptr: *anyopaque,
vtable: VTable,
pub fn init(
    pointer: anytype,
    vtable: VTable,
) Benchmark {
    const Ptr = @TypeOf(pointer);
    assert(@typeInfo(Ptr) == .pointer);
    assert(@typeInfo(Ptr).pointer.size == .one);
    assert(@typeInfo(@typeInfo(Ptr).pointer.child) == .@"struct");
    return .{ .ptr = pointer, .vtable = vtable };
}
pub fn run(
    self: Benchmark,
    mode: RunMode,
) Error!RunResult {
    if (self.vtable.setupFn) |func| try func(self.ptr);
    defer if (self.vtable.teardownFn) |func| func(self.ptr);
    var result: RunResult = .{};
    const signpost_name = "wasp";
    const signpost: if (builtin.target.os.tag.isDarwin()) struct {
        log: *macos.os.Log,
        id: macos.os.signpost.Id,
    } else void = if (builtin.target.os.tag.isDarwin()) darwin: {
        macos.os.signpost.init();
        const log = macos.os.Log.create(
            build_config.bundle_id,
            macos.os.signpost.Category.points_of_interest,
        );
        const id = macos.os.signpost.Id.forPointer(log, self.ptr);
        macos.os.signpost.intervalBegin(log, id, signpost_name);
        break :darwin .{ .log = log, .id = id };
    } else {};
    defer if (comptime builtin.target.os.tag.isDarwin()) {
        macos.os.signpost.intervalEnd(
            signpost.log,
            signpost.id,
            signpost_name,
        );
        signpost.log.release();
    };
    const start: std.Io.Timestamp = .now(global.io(), .awake);
    while (true) {
        try self.vtable.stepFn(self.ptr);
        result.iterations += 1;
        const now: std.Io.Timestamp = .now(global.io(), .awake);
        const elapsed = start.durationTo(now).nanoseconds;
        assert(elapsed >= 0);
        const exit = switch (mode) {
            .once => true,
            .duration => |ns| elapsed >= ns,
        };
        if (exit) {
            result.duration = @as(u64, @intCast(std.math.clamp(elapsed, 0, std.math.maxInt(u64))));
            return result;
        }
    }
    unreachable;
}
pub const RunMode = union(enum) {
    once,
    duration: u64,
};
pub const RunResult = struct {
    iterations: u32 = 0,
    duration: u64 = 0,
};
pub const Error = error{BenchmarkFailed};
pub const VTable = struct {
    stepFn: *const fn (ptr: *anyopaque) Error!void,
    setupFn: ?*const fn (ptr: *anyopaque) Error!void = null,
    teardownFn: ?*const fn (ptr: *anyopaque) void = null,
};
test Benchmark {
    switch (builtin.os.tag) {
        .freebsd,
        .windows,
        => return error.SkipZigTest,
        else => {},
    }
    const testing = std.testing;
    const Simple = struct {
        const Self = @This();
        setup_i: usize = 0,
        step_i: usize = 0,
        pub fn benchmark(self: *Self) Benchmark {
            return .init(self, .{
                .stepFn = step,
                .setupFn = setup,
            });
        }
        fn setup(ptr: *anyopaque) Error!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.setup_i += 1;
        }
        fn step(ptr: *anyopaque) Error!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.step_i += 1;
        }
    };
    var s: Simple = .{};
    const b = s.benchmark();
    const result = try b.run(.once);
    try testing.expectEqual(1, s.setup_i);
    try testing.expectEqual(1, s.step_i);
    try testing.expectEqual(1, result.iterations);
    try testing.expect(result.duration > 0);
}
