const std = @import("std");
const build_options = @import("terminal_options");
const Allocator = std.mem.Allocator;
pub const glyph = @import("apc/glyph.zig");
const kitty_gfx = @import("kitty/graphics.zig");
const log = std.log.scoped(.terminal_apc);
pub const Handler = struct {
    state: State = .inactive,
    unknown_max_bytes: usize = 0,
    max_bytes: std.EnumMap(Protocol, usize) = .initFullWith(.{
        .kitty = Protocol.defaultMaxBytes(.kitty),
        .glyph = Protocol.defaultMaxBytes(.glyph),
    }),
    enabled: std.EnumSet(Protocol) = .initFull(),
    pub fn deinit(self: *Handler) void {
        self.state.deinit();
    }
    pub fn start(self: *Handler) void {
        self.state.deinit();
        self.state = .{ .identify = .{} };
    }
    pub fn enable(self: *Handler, protocol: Protocol, enabled: bool) void {
        self.enabled.setPresent(protocol, enabled);
    }
    pub fn feed(self: *Handler, alloc: Allocator, byte: u8) void {
        switch (self.state) {
            .inactive => unreachable,
            .ignore => return,
            .unknown => |*unknown| unknown.append(&.{byte}),
            .identify => |*id| id: {
                if (id.len == 0 and byte == 'G') {
                    if (comptime build_options.kitty_graphics) {
                        if (self.enabled.contains(.kitty)) {
                            self.state = .{ .kitty = .init(
                                alloc,
                                self.max_bytes.get(.kitty) orelse
                                    Protocol.defaultMaxBytes(.kitty),
                            ) };
                        } else {
                            self.state = .ignore;
                        }
                    } else {
                        self.state = .ignore;
                    }
                    break :id;
                }
                if (byte == ';') {
                    const str = id.buf[0..id.len];
                    if (std.mem.eql(u8, str, glyph.identifier)) {
                        if (comptime build_options.glyph_protocol) {
                            if (self.enabled.contains(.glyph)) {
                                self.state = .{ .glyph = .init(
                                    alloc,
                                    self.max_bytes.get(.glyph) orelse
                                        Protocol.defaultMaxBytes(.glyph),
                                ) };
                            } else {
                                self.state = .ignore;
                            }
                        } else {
                            self.state = .ignore;
                        }
                    } else {
                        self.beginUnknown(alloc, str, &.{byte});
                    }
                    break :id;
                }
                if (id.len >= id.buf.len) {
                    self.beginUnknown(alloc, id.buf[0..id.len], &.{byte});
                    break :id;
                }
                const expected_idx: usize = id.len;
                id.buf[id.len] = byte;
                id.len += 1;
                if (self.unknown_max_bytes > 0 and
                    byte != glyph.identifier[expected_idx])
                {
                    self.beginUnknown(alloc, id.buf[0..id.len], &.{});
                }
            },
            .kitty => |*p| if (comptime build_options.kitty_graphics) {
                p.feed(byte) catch |err| {
                    log.warn("kitty graphics protocol error: {}", .{err});
                    p.deinit();
                    self.state = .ignore;
                };
            } else unreachable,
            .glyph => |*p| if (comptime build_options.glyph_protocol) {
                p.feed(byte) catch |err| {
                    log.warn("glyph protocol error: {}", .{err});
                    p.deinit();
                    self.state = .ignore;
                };
            } else unreachable,
        }
    }
    fn beginUnknown(
        self: *Handler,
        alloc: Allocator,
        prefix: []const u8,
        suffix: []const u8,
    ) void {
        const max_bytes = self.unknown_max_bytes;
        if (max_bytes == 0) {
            self.state = .ignore;
            return;
        }
        var unknown: UnknownBuilder = .init(alloc, max_bytes);
        unknown.append(prefix);
        unknown.append(suffix);
        self.state = .{ .unknown = unknown };
    }
    pub fn feedSlice(self: *Handler, alloc: Allocator, bytes: []const u8) void {
        var rem = bytes;
        while (rem.len > 0) {
            switch (self.state) {
                .inactive => unreachable,
                .ignore => return,
                .unknown => |*unknown| {
                    unknown.append(rem);
                    return;
                },
                .identify => {
                    self.feed(alloc, rem[0]);
                    rem = rem[1..];
                },
                .kitty => |*p| if (comptime build_options.kitty_graphics) {
                    p.feedSlice(rem) catch |err| {
                        log.warn("kitty graphics protocol error: {}", .{err});
                        p.deinit();
                        self.state = .ignore;
                    };
                    return;
                } else unreachable,
                .glyph => |*p| if (comptime build_options.glyph_protocol) {
                    p.feedSlice(rem) catch |err| {
                        log.warn("glyph protocol error: {}", .{err});
                        p.deinit();
                        self.state = .ignore;
                    };
                    return;
                } else unreachable,
            }
        }
    }
    pub fn end(self: *Handler) ?Command {
        defer {
            self.state.deinit();
            self.state = .inactive;
        }
        return switch (self.state) {
            .inactive => unreachable,
            .ignore, .identify => null,
            .unknown => |*unknown| .{ .unknown = unknown.toOwned() },
            .kitty => |*p| kitty: {
                if (comptime !build_options.kitty_graphics) unreachable;
                const alloc = p.alloc;
                const command = p.complete(alloc) catch |err| {
                    log.warn("kitty graphics protocol error: {}", .{err});
                    break :kitty null;
                };
                break :kitty .{ .kitty = command };
            },
            .glyph => |*p| glyph_cmd: {
                if (comptime !build_options.glyph_protocol) unreachable;
                const command = p.complete(p.alloc) catch |err| {
                    log.warn("glyph protocol error: {}", .{err});
                    break :glyph_cmd null;
                };
                break :glyph_cmd .{ .glyph = command };
            },
        };
    }
};
pub const State = union(enum) {
    inactive,
    ignore,
    identify: struct {
        len: u3 = 0,
        buf: [glyph.identifier.len]u8 = undefined,
    },
    kitty: if (build_options.kitty_graphics)
        kitty_gfx.CommandParser
    else
        void,
    glyph: if (build_options.glyph_protocol)
        glyph.CommandParser
    else
        void,
    unknown: UnknownBuilder,
    pub fn deinit(self: *State) void {
        switch (self.*) {
            .inactive, .ignore, .identify => {},
            .unknown => |*v| v.deinit(),
            .glyph => |*v| if (comptime build_options.glyph_protocol)
                v.deinit()
            else
                unreachable,
            .kitty => |*v| if (comptime build_options.kitty_graphics)
                v.deinit()
            else
                unreachable,
        }
    }
};
const UnknownBuilder = struct {
    data: std.ArrayList(u8) = .empty,
    alloc: Allocator,
    max_bytes: usize,
    truncated: bool = false,
    fn init(alloc: Allocator, max_bytes: usize) UnknownBuilder {
        return .{
            .alloc = alloc,
            .max_bytes = max_bytes,
        };
    }
    fn deinit(self: *UnknownBuilder) void {
        self.data.deinit(self.alloc);
        self.data = .empty;
    }
    fn append(self: *UnknownBuilder, bytes: []const u8) void {
        if (bytes.len == 0) return;
        const current = self.data.items.len;
        const retained = @min(bytes.len, self.max_bytes -| current);
        if (retained < bytes.len) self.truncated = true;
        const required = current + retained;
        if (required > self.data.capacity) {
            const capacity = @min(
                self.max_bytes,
                @max(required, @max(self.data.capacity *| 2, 1)),
            );
            self.data.ensureTotalCapacityPrecise(
                self.alloc,
                capacity,
            ) catch {
                self.truncated = true;
                return;
            };
        }
        self.data.appendSliceAssumeCapacity(bytes[0..retained]);
    }
    fn toOwned(self: *UnknownBuilder) Unknown {
        const content = self.data.toOwnedSlice(self.alloc) catch {
            self.data.deinit(self.alloc);
            self.data = .empty;
            return .{
                .content = self.data.items,
                .truncated = true,
            };
        };
        return .{
            .content = content,
            .truncated = self.truncated,
        };
    }
};
pub const Unknown = struct {
    content: []u8,
    truncated: bool,
    pub fn deinit(self: *Unknown, alloc: Allocator) void {
        if (self.content.len > 0) alloc.free(self.content);
        self.* = undefined;
    }
};
pub const Protocol = enum {
    kitty,
    glyph,
    pub fn defaultMaxBytes(self: Protocol) usize {
        return switch (self) {
            .kitty => 65 * 1024 * 1024,
            .glyph => 1 * 1024 * 1024,
        };
    }
    pub fn maxDefaultBytes() usize {
        var result: usize = 0;
        for (std.enums.values(Protocol)) |protocol| {
            result = @max(result, protocol.defaultMaxBytes());
        }
        return result;
    }
};
pub const Command = union(enum) {
    kitty: if (build_options.kitty_graphics)
        kitty_gfx.Command
    else
        void,
    glyph: if (build_options.glyph_protocol)
        glyph.Request
    else
        void,
    unknown: Unknown,
    pub fn deinit(self: *Command, alloc: Allocator) void {
        switch (self.*) {
            .kitty => |*v| if (comptime build_options.kitty_graphics)
                v.deinit(alloc)
            else
                unreachable,
            .glyph => |*v| if (comptime build_options.glyph_protocol)
                v.deinit(alloc)
            else
                unreachable,
            .unknown => |*v| v.deinit(alloc),
        }
    }
};
test "unknown APC command" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var h: Handler = .{};
    h.start();
    for ("Xabcdef1234") |c| h.feed(alloc, c);
    try testing.expect(h.end() == null);
}
test "capture unknown APC command" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var h: Handler = .{ .unknown_max_bytes = 5 };
    defer h.deinit();
    h.start();
    h.feedSlice(alloc, "abcd;payload");
    var result = h.end().?;
    defer result.deinit(alloc);
    const unknown = &result.unknown;
    try testing.expectEqualStrings("abcd;", unknown.content);
    try testing.expect(unknown.truncated);
}
test "capture short unknown APC command" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var h: Handler = .{ .unknown_max_bytes = 16 };
    defer h.deinit();
    h.start();
    h.feed(alloc, 'X');
    var result = h.end().?;
    const unknown = &result.unknown;
    try testing.expectEqualStrings("X", unknown.content);
    try testing.expect(!unknown.truncated);
    result.deinit(alloc);
    h.unknown_max_bytes = 1;
    h.start();
    h.feedSlice(alloc, "XYZ");
    result = h.end().?;
    const truncated = &result.unknown;
    try testing.expectEqualStrings("X", truncated.content);
    try testing.expect(truncated.truncated);
    result.deinit(alloc);
}
test "disabled known APC protocol is not unknown" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var h: Handler = .{ .unknown_max_bytes = 64 };
    defer h.deinit();
    h.enable(.glyph, false);
    h.start();
    h.feedSlice(alloc, "25a1;q;cp=E0A0");
    try testing.expect(h.end() == null);
    h.start();
    h.feedSlice(alloc, "25a");
    try testing.expect(h.end() == null);
}
test "garbage Kitty command" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var h: Handler = .{};
    h.start();
    for ("Gabcdef1234") |c| h.feed(alloc, c);
    try testing.expect(h.end() == null);
}
test "Kitty command with overflow u32" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var h: Handler = .{};
    h.start();
    for ("Ga=p,i=10000000000") |c| h.feed(alloc, c);
    try testing.expect(h.end() == null);
}
test "Kitty command with overflow i32" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var h: Handler = .{};
    h.start();
    for ("Ga=p,i=1,z=-9999999999") |c| h.feed(alloc, c);
    try testing.expect(h.end() == null);
}
test "kitty feed error deinits parser" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var h: Handler = .{};
    defer h.deinit();
    h.start();
    for ("Ga=p,i=10000000000;") |c| h.feed(alloc, c);
    try testing.expect(h.state == .ignore);
}
test "kitty max bytes exceeded" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var h: Handler = .{ .max_bytes = .init(.{ .kitty = 4 }) };
    defer h.deinit();
    h.start();
    for ("Ga=t;") |c| h.feed(alloc, c);
    try testing.expect(h.state != .ignore);
    for ("abcd") |c| h.feed(alloc, c);
    try testing.expect(h.state != .ignore);
    h.feed(alloc, 'e');
    try testing.expect(h.state == .ignore);
}
test "valid Kitty command" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var h: Handler = .{};
    h.start();
    const input = "Gf=24,s=10,v=20,hello=world";
    for (input) |c| h.feed(alloc, c);
    var result = h.end().?;
    defer result.deinit(alloc);
    try testing.expect(result == .kitty);
}
test "identify with unrecognized command" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var h: Handler = .{};
    h.start();
    for ("abcd;payload") |c| h.feed(alloc, c);
    try testing.expect(h.end() == null);
}
test "identify buffer overflow" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var h: Handler = .{};
    h.start();
    for ("abcde;payload") |c| h.feed(alloc, c);
    try testing.expect(h.end() == null);
}
test "identify with no input" {
    const testing = std.testing;
    var h: Handler = .{};
    h.start();
    try testing.expect(h.end() == null);
}
test "identify with unknown partial input" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var h: Handler = .{};
    h.start();
    for ("25a") |c| h.feed(alloc, c);
    try testing.expect(h.end() == null);
}
test "garbage glyph command" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var h: Handler = .{};
    h.start();
    for ("25a1;X") |c| h.feed(alloc, c);
    try testing.expect(h.end() == null);
}
test "valid glyph command" {
    if (comptime !build_options.glyph_protocol) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var h: Handler = .{};
    h.start();
    for ("25a1;q;cp=E0A0") |c| h.feed(alloc, c);
    var result = h.end().?;
    defer result.deinit(alloc);
    try testing.expect(result == .glyph);
    try testing.expect(result.glyph == .query);
}
test "feedSlice valid Kitty command" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var h: Handler = .{};
    h.start();
    h.feedSlice(alloc, "Gf=24,s=10,v=20;aGVsbG8=");
    var result = h.end().?;
    defer result.deinit(alloc);
    try testing.expect(result == .kitty);
    try testing.expectEqualStrings("hello", result.kitty.data);
}
test "feedSlice identify split across slices" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var h: Handler = .{};
    h.start();
    h.feedSlice(alloc, "G");
    h.feedSlice(alloc, "f=24,s=10,");
    h.feedSlice(alloc, "v=20;aGVsbG8=");
    var result = h.end().?;
    defer result.deinit(alloc);
    try testing.expect(result == .kitty);
    try testing.expectEqualStrings("hello", result.kitty.data);
}
test "feedSlice unknown APC command is ignored" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var h: Handler = .{};
    h.start();
    h.feedSlice(alloc, "Xabcdef1234");
    try testing.expect(h.state == .ignore);
    h.feedSlice(alloc, "more data that is dropped");
    try testing.expect(h.end() == null);
}
test "feedSlice valid glyph command" {
    if (comptime !build_options.glyph_protocol) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var h: Handler = .{};
    h.start();
    h.feedSlice(alloc, "25a1;q;cp=E0A0");
    var result = h.end().?;
    defer result.deinit(alloc);
    try testing.expect(result == .glyph);
    try testing.expect(result.glyph == .query);
}
test "feedSlice kitty max bytes exceeded" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var h: Handler = .{ .max_bytes = .init(.{ .kitty = 4 }) };
    defer h.deinit();
    h.start();
    h.feedSlice(alloc, "Ga=t;abcd");
    try testing.expect(h.state != .ignore);
    h.feedSlice(alloc, "e");
    try testing.expect(h.state == .ignore);
}
test "disabled glyph command is ignored" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var h: Handler = .{};
    h.enable(.glyph, false);
    h.start();
    for ("25a1;q;cp=e0a0") |c| h.feed(alloc, c);
    try testing.expect(h.end() == null);
}
