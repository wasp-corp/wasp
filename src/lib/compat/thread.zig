const builtin = @import("builtin");
const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
pub const WaitTimeoutError = std.Io.Cancelable || std.Io.Timeout.Error;
pub fn waitTimeout(
    cond: *std.Io.Condition,
    io: std.Io,
    mutex: *std.Io.Mutex,
    timeout: std.Io.Timeout,
) WaitTimeoutError!void {
    const deadline = timeout.toDeadline(io);
    var epoch = cond.epoch.load(.acquire); 
    {
        const prev_state = cond.state.fetchAdd(.{ .waiters = 1, .signals = 0 }, .monotonic);
        assert(prev_state.waiters < std.math.maxInt(u16)); 
    }
    mutex.unlock(io);
    defer mutex.lockUncancelable(io);
    while (true) {
        const result = io.futexWaitTimeout(u32, &cond.epoch.raw, epoch, deadline);
        epoch = cond.epoch.load(.acquire); 
        {
            var prev_state = cond.state.load(.monotonic);
            while (prev_state.signals > 0) {
                prev_state = cond.state.cmpxchgWeak(prev_state, .{
                    .waiters = prev_state.waiters - 1,
                    .signals = prev_state.signals - 1,
                }, .acquire, .monotonic) orelse {
                    return;
                };
            }
        }
        result catch |err| {
            const prev_state = cond.state.fetchSub(.{ .waiters = 1, .signals = 0 }, .monotonic);
            assert(prev_state.waiters > 0); 
            return err;
        };
        switch (deadline) {
            .none => {},
            .deadline => |d| if (d.untilNow(io).raw.nanoseconds >= 0) {
                const prev_state = cond.state.fetchSub(.{ .waiters = 1, .signals = 0 }, .monotonic);
                assert(prev_state.waiters > 0); 
                return error.Timeout;
            },
            .duration => unreachable,
        }
    }
}
