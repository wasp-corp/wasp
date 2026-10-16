const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const testing = std.testing;
const log = std.log.scoped(.tripwire);
pub fn module(
    comptime P: type,
    comptime E: anytype,
) type {
    return struct {
        pub const FailPoint = P;
        pub const Error = err: {
            const T = if (@TypeOf(E) == type) E else @TypeOf(E);
            break :err switch (@typeInfo(T)) {
                .error_set => E,
                .error_union => |info| info.error_set,
                .@"fn" => |info| @typeInfo(info.return_type.?).error_union.error_set,
                else => @compileError("E must be an error set or function type"),
            };
        };
        pub const enabled = builtin.is_test;
        comptime {
            assert(@typeInfo(FailPoint) == .@"enum");
            assert(@typeInfo(Error) == .error_set);
        }
        var tripwires: TripwireMap = .{};
        const TripwireMap = std.EnumMap(FailPoint, Tripwire);
        const Tripwire = struct {
            err: Error,
            reached: usize = 0,
            min: usize = 0,
            tripped: bool = false,
        };
        pub fn check(point: FailPoint) callconv(callingConvention()) Error!void {
            if (comptime !enabled) return;
            return checkConstrained(point, Error);
        }
        pub fn checkConstrained(
            point: FailPoint,
            comptime ConstrainedError: type,
        ) callconv(callingConvention()) ConstrainedError!void {
            if (comptime !enabled) return;
            const tripwire = tripwires.getPtr(point) orelse return;
            tripwire.reached += 1;
            if (tripwire.reached <= tripwire.min) return;
            tripwire.tripped = true;
            return tripwire.err;
        }
        pub fn errorAlways(point: FailPoint, err: Error) void {
            errorAfter(point, err, 0);
        }
        pub fn errorAfter(point: FailPoint, err: Error, min: usize) void {
            tripwires.put(point, .{ .err = err, .min = min });
        }
        pub fn end(reset_mode: enum { reset, retain }) error{UntrippedError}!void {
            var untripped: bool = false;
            var iter = tripwires.iterator();
            while (iter.next()) |entry| {
                if (!entry.value.tripped) {
                    log.warn("untripped point={s}", .{@tagName(entry.key)});
                    untripped = true;
                }
            }
            switch (reset_mode) {
                .reset => reset(),
                .retain => {},
            }
            if (untripped) return error.UntrippedError;
        }
        pub fn reset() void {
            tripwires = .{};
        }
        fn callingConvention() std.builtin.CallingConvention {
            return if (!enabled) .@"inline" else .auto;
        }
    };
}
test {
    const io = module(enum {
        read,
        write,
    }, anyerror);
    try io.end(.reset);
    try io.check(.read);
    io.errorAlways(.read, error.OutOfMemory);
    try testing.expectError(
        error.OutOfMemory,
        io.check(.read),
    );
    try testing.expectError(
        error.OutOfMemory,
        io.check(.read),
    );
    try io.end(.reset);
}
test "module as error set" {
    const io = module(enum { read, write }, @TypeOf((struct {
        fn func() error{ Foo, Bar }!void {
            return error.Foo;
        }
    }).func));
    try io.end(.reset);
}
test "errorAfter" {
    const io = module(enum { read, write }, anyerror);
    io.errorAfter(.read, error.OutOfMemory, 2);
    try io.check(.read);
    try io.check(.read);
    try testing.expectError(error.OutOfMemory, io.check(.read));
    try testing.expectError(error.OutOfMemory, io.check(.read));
    try io.end(.reset);
}
test "errorAfter untripped error if min not reached" {
    const io = module(enum { read }, anyerror);
    io.errorAfter(.read, error.OutOfMemory, 2);
    try io.check(.read);
    try testing.expectError(
        error.UntrippedError,
        io.end(.reset),
    );
}
