const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const Parser = @import("Parser.zig");
const UTF8Decoder = @import("UTF8Decoder.zig");
pub const ValidateError = error{
    NoPendingState,
    NonCanonicalContinuation,
    ReplayWouldCommit,
};
pub fn validate(bytes: []const u8) ValidateError!void {
    if (bytes.len == 0) return;
    var scanner: BoundaryScanner = .init();
    var committed_work = false;
    for (bytes) |byte| {
        if (scanner.next(byte) != .uncommitted) committed_work = true;
    }
    if (scanner.ground()) return error.NoPendingState;
    const replay_start = if (scanner.parser.state != .ground)
        findVTReplayStart(bytes)
    else
        findUtf8ReplayStart(bytes);
    if (replay_start != 0) return error.NonCanonicalContinuation;
    if (committed_work) return error.ReplayWouldCommit;
}
pub const Tracker = struct {
    const initial_capacity = 4096;
    alloc: Allocator,
    max_bytes: usize,
    bytes: std.ArrayList(u8) = .empty,
    broken: bool = false,
    pub fn init(alloc: Allocator, max_bytes: usize) Tracker {
        var result: Tracker = .{
            .alloc = alloc,
            .max_bytes = max_bytes,
        };
        result.bytes.ensureTotalCapacity(
            alloc,
            @min(max_bytes, initial_capacity),
        ) catch {
        };
        return result;
    }
    pub fn deinit(self: *Tracker) void {
        self.bytes.deinit(self.alloc);
    }
    pub fn reset(self: *Tracker) void {
        self.broken = false;
        self.bytes.clearRetainingCapacity();
    }
    pub const Pending = enum { vt, utf8 };
    pub fn append(self: *Tracker, pending: Pending, input: []const u8) void {
        const start = switch (pending) {
            .vt => findVTReplayStart(input),
            .utf8 => findUtf8ReplayStart(input),
        } orelse {
            self.extend(input);
            return;
        };
        self.replace(input[start..]);
    }
    fn replace(self: *Tracker, suffix: []const u8) void {
        self.bytes.clearRetainingCapacity();
        if (suffix.len > self.max_bytes) {
            self.markBroken();
            return;
        }
        self.bytes.appendSlice(self.alloc, suffix) catch {
            self.markBroken();
            return;
        };
        self.broken = false;
    }
    fn extend(self: *Tracker, fragment: []const u8) void {
        if (self.broken) return;
        if (fragment.len > self.max_bytes -| self.bytes.items.len) {
            self.markBroken();
            return;
        }
        self.bytes.appendSlice(self.alloc, fragment) catch self.markBroken();
    }
    pub fn write(
        self: *const Tracker,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        var scanner: BoundaryScanner = .init();
        for (self.bytes.items) |c| {
            if (scanner.next(c) == .omittable) continue;
            try writer.writeByte(c);
        }
    }
    fn markBroken(self: *Tracker) void {
        self.broken = true;
        self.bytes.clearRetainingCapacity();
    }
};
fn findVTReplayStart(input: []const u8) ?usize {
    const esc: u8 = 0x1B;
    var rem: usize = input.len;
    if (comptime std.simd.suggestVectorLength(u8)) |lanes| {
        const V = @Vector(lanes, u8);
        const Bits = std.meta.Int(.unsigned, lanes);
        const needle: V = @splat(esc);
        const unroll = 4;
        while (rem >= lanes * unroll) {
            const start = rem - lanes * unroll;
            var match: @Vector(lanes, bool) = @splat(false);
            inline for (0..unroll) |block| {
                const v: V = input[start + block * lanes ..][0..lanes].*;
                match = match | (v == needle);
            }
            if (@reduce(.Or, match)) {
                inline for (0..unroll) |i| {
                    const block = unroll - 1 - i;
                    const v: V = input[start + block * lanes ..][0..lanes].*;
                    const bits: Bits = @bitCast(v == needle);
                    if (bits != 0) {
                        return start + block * lanes + (lanes - 1 - @clz(bits));
                    }
                }
                unreachable;
            }
            rem = start;
        }
        while (rem >= lanes) {
            const start = rem - lanes;
            const v: V = input[start..][0..lanes].*;
            const bits: Bits = @bitCast(v == needle);
            if (bits != 0) return start + (lanes - 1 - @clz(bits));
            rem = start;
        }
    }
    while (rem > 0) {
        rem -= 1;
        if (input[rem] == esc) return rem;
    }
    return null;
}
fn findUtf8ReplayStart(input: []const u8) ?usize {
    const max_pending = 3;
    var idx = input.len;
    while (idx > 0 and input.len - idx < max_pending) {
        idx -= 1;
        if (input[idx] >= 0xC0) return idx;
    }
    return null;
}
const BoundaryScanner = struct {
    parser: Parser,
    utf8decoder: UTF8Decoder,
    fn init() BoundaryScanner {
        return .{
            .parser = .init(),
            .utf8decoder = .{},
        };
    }
    const Effect = enum {
        uncommitted,
        committed,
        omittable,
    };
    fn ground(self: *const BoundaryScanner) bool {
        return self.parser.state == .ground and self.utf8decoder.state == 0;
    }
    fn next(self: *BoundaryScanner, c: u8) Effect {
        const parser_state = self.parser.state;
        const utf8_state = self.utf8decoder.state;
        const committed = committed: {
            if (self.parser.state == .ground) {
                var committed = false;
                const res = self.utf8decoder.next(c);
                if (res[0]) |cp| committed = self.codepoint(cp) or committed;
                if (!res[1]) {
                    const retry = self.utf8decoder.next(c);
                    assert(retry[1]);
                    if (retry[0]) |cp| committed = self.codepoint(cp) or committed;
                }
                break :committed committed;
            }
            const actions = self.parser.next(c);
            for (actions) |action_opt| {
                const action = action_opt orelse continue;
                switch (action) {
                    .dcs_hook,
                    .dcs_put,
                    .apc_start,
                    .apc_put,
                    => {},
                    else => break :committed true,
                }
            }
            break :committed false;
        };
        if (!committed) return .uncommitted;
        const state_changed = parser_state != self.parser.state or
            utf8_state != self.utf8decoder.state;
        return if (!state_changed and !self.ground())
            .omittable
        else
            .committed;
    }
    fn codepoint(self: *BoundaryScanner, cp: u21) bool {
        if (cp == 0x1B) {
            self.parser.state = .escape;
            self.parser.clear();
            return false;
        }
        return true;
    }
};
test "boundary scanner classifies effects and ground" {
    const testing = std.testing;
    var scanner: BoundaryScanner = .init();
    try testing.expect(scanner.ground());
    try testing.expectEqual(BoundaryScanner.Effect.committed, scanner.next('A'));
    try testing.expect(scanner.ground());
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, scanner.next(0x1B));
    try testing.expect(!scanner.ground());
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, scanner.next('['));
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, scanner.next('1'));
    try testing.expectEqual(BoundaryScanner.Effect.omittable, scanner.next(0x07));
    try testing.expect(!scanner.ground());
    try testing.expectEqual(BoundaryScanner.Effect.committed, scanner.next('m'));
    try testing.expect(scanner.ground());
}
test "boundary scanner preserves unfinished builder actions" {
    const testing = std.testing;
    var apc: BoundaryScanner = .init();
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, apc.next(0x1B));
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, apc.next('_'));
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, apc.next('G'));
    try testing.expectEqual(BoundaryScanner.Effect.committed, apc.next(0x1B));
    var dcs: BoundaryScanner = .init();
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, dcs.next(0x1B));
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, dcs.next('P'));
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, dcs.next('q'));
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, dcs.next('x'));
    try testing.expectEqual(BoundaryScanner.Effect.committed, dcs.next(0x1B));
}
test "boundary scanner handles UTF-8 and malformed retries" {
    const testing = std.testing;
    var valid: BoundaryScanner = .init();
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, valid.next(0xF0));
    try testing.expect(!valid.ground());
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, valid.next(0x9F));
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, valid.next(0x98));
    try testing.expectEqual(BoundaryScanner.Effect.committed, valid.next(0x84));
    try testing.expect(valid.ground());
    var malformed: BoundaryScanner = .init();
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, malformed.next(0xE0));
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, malformed.next(0xA0));
    try testing.expect(malformed.next(0xF0) != .uncommitted);
    try testing.expect(!malformed.ground());
}
test "findVTReplayStart finds the latest ESC across vector boundaries" {
    const testing = std.testing;
    try testing.expectEqual(@as(?usize, null), findVTReplayStart(""));
    try testing.expectEqual(@as(?usize, null), findVTReplayStart("no escapes here"));
    try testing.expectEqual(@as(?usize, 0), findVTReplayStart("\x1b"));
    try testing.expectEqual(@as(?usize, 5), findVTReplayStart("\x1b[1m\x20\x1b[2"));
    var buf: [193]u8 = undefined;
    @memset(&buf, 'a');
    try testing.expectEqual(@as(?usize, null), findVTReplayStart(&buf));
    for (0..buf.len) |idx| {
        @memset(&buf, 'a');
        buf[idx] = 0x1B;
        try testing.expectEqual(@as(?usize, idx), findVTReplayStart(&buf));
        if (idx > 0) {
            buf[idx - 1] = 0x1B;
            try testing.expectEqual(@as(?usize, idx), findVTReplayStart(&buf));
        }
    }
}
test "findUtf8ReplayStart finds the pending lead byte" {
    const testing = std.testing;
    try testing.expectEqual(@as(?usize, null), findUtf8ReplayStart(""));
    try testing.expectEqual(@as(?usize, 4), findUtf8ReplayStart("text\xF0"));
    try testing.expectEqual(@as(?usize, 4), findUtf8ReplayStart("text\xF0\x9F"));
    try testing.expectEqual(@as(?usize, 4), findUtf8ReplayStart("text\xF0\x9F\x98"));
    try testing.expectEqual(@as(?usize, 0), findUtf8ReplayStart("\xE0\xA0"));
    try testing.expectEqual(@as(?usize, 2), findUtf8ReplayStart("\xE0\xA0\xF0"));
    try testing.expectEqual(@as(?usize, null), findUtf8ReplayStart("\x9F"));
    try testing.expectEqual(@as(?usize, null), findUtf8ReplayStart("\x9F\x98"));
}
test "tracker retains and normalizes replay-safe bytes" {
    const testing = std.testing;
    var tracker = Tracker.init(testing.allocator, 64);
    defer tracker.deinit();
    tracker.append(.vt, "committed\x1b[1\x07");
    tracker.append(.vt, ";2");
    try testing.expect(!tracker.broken);
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try tracker.write(&writer);
    try testing.expectEqualStrings("\x1b[1;2", writer.buffered());
    tracker.append(.vt, "committed\x1b]0;t");
    var replaced_buf: [64]u8 = undefined;
    var replaced_writer: std.Io.Writer = .fixed(&replaced_buf);
    try tracker.write(&replaced_writer);
    try testing.expectEqualStrings("\x1b]0;t", replaced_writer.buffered());
    tracker.append(.utf8, "committed\xF0");
    tracker.append(.utf8, "\x9F");
    var utf8_buf: [4]u8 = undefined;
    var utf8_writer: std.Io.Writer = .fixed(&utf8_buf);
    try tracker.write(&utf8_writer);
    try testing.expectEqualSlices(u8, "\xF0\x9F", utf8_writer.buffered());
}
test "tracker cap, reset, and broken recovery" {
    const testing = std.testing;
    var tracker = Tracker.init(testing.allocator, 4);
    defer tracker.deinit();
    tracker.append(.vt, "\x1b[123");
    try testing.expect(tracker.broken);
    tracker.append(.vt, "4");
    try testing.expect(tracker.broken);
    try testing.expectEqual(@as(usize, 0), tracker.bytes.items.len);
    tracker.reset();
    tracker.append(.vt, "\x1b[1");
    tracker.append(.vt, "23");
    try testing.expect(tracker.broken);
    tracker.append(.vt, "\x1b[");
    try testing.expect(!tracker.broken);
    var buf: [4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try tracker.write(&writer);
    try testing.expectEqualStrings("\x1b[", writer.buffered());
    tracker.append(.vt, "\x1b[123");
    try testing.expect(tracker.broken);
    tracker.reset();
    try testing.expect(!tracker.broken);
    var empty_buf: [1]u8 = undefined;
    var empty_writer: std.Io.Writer = .fixed(&empty_buf);
    try tracker.write(&empty_writer);
    try testing.expectEqual(@as(usize, 0), empty_writer.end);
}
test "tracker reports writer failure and defers allocation failure" {
    const testing = std.testing;
    var tracker = Tracker.init(testing.allocator, 64);
    defer tracker.deinit();
    tracker.append(.vt, "\x1b[");
    var buf: [1]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try testing.expectError(error.WriteFailed, tracker.write(&writer));
    var failing = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });
    var failing_tracker = Tracker.init(failing.allocator(), 64);
    defer failing_tracker.deinit();
    try testing.expect(!failing_tracker.broken);
    failing_tracker.append(.vt, "\x1b[");
    try testing.expect(failing_tracker.broken);
}
