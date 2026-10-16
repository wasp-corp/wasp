const std = @import("std");
const testing = std.testing;
const osc = @import("../osc.zig");
const dnd = @import("dnd.zig");
const Harness = struct {
    state: ?*dnd.State = null,
    output: std.Io.Writer.Allocating,
    fn init() Harness {
        return .{ .output = .init(testing.allocator) };
    }
    fn deinit(self: *Harness) void {
        if (self.state) |state| state.destroy(testing.allocator);
        self.output.deinit();
    }
    fn registered(self: *Harness) *dnd.State {
        return self.state.?;
    }
    fn command(self: *Harness, metadata: []const u8, payload: ?[]const u8) !?dnd.Event {
        return try dnd.handleCommand(&self.state, testing.allocator, &self.output.writer, .{
            .metadata = metadata,
            .payload = payload,
            .terminator = .st,
        });
    }
    fn consume(self: *Harness) []const u8 {
        const written = self.output.written();
        return written;
    }
    fn clear(self: *Harness) void {
        self.output.clearRetainingCapacity();
    }
    fn expectOutput(self: *Harness, expected: []const u8) !void {
        try testing.expectEqualStrings(expected, self.output.written());
        self.clear();
    }
};
test "dnd: query response" {
    var h: Harness = .init();
    defer h.deinit();
    _ = try h.command("t=q", null);
    try h.expectOutput("\x1b]72;t=q\x1b\\");
    try testing.expect(h.state == null);
}
test "dnd: query response echoes client id" {
    var h: Harness = .init();
    defer h.deinit();
    _ = try h.command("t=q:i=31", null);
    try h.expectOutput("\x1b]72;t=q:i=31\x1b\\");
}
test "dnd: register and unregister" {
    var h: Harness = .init();
    defer h.deinit();
    try testing.expect(h.state == null);
    try testing.expect((try h.command("t=a", "text/plain text/uri-list")).? == .registration);
    try h.expectOutput("");
    {
        var it = h.registered().registeredMimes();
        try testing.expectEqualStrings("text/plain", it.next().?);
        try testing.expectEqualStrings("text/uri-list", it.next().?);
        try testing.expect(it.next() == null);
    }
    try testing.expect((try h.command("t=a:x=1", "1:deadbeef")) == null);
    try h.expectOutput("");
    try testing.expect(h.state != null);
    try testing.expect((try h.command("t=a", "image/png")).? == .registration);
    {
        var it = h.registered().registeredMimes();
        try testing.expectEqualStrings("image/png", it.next().?);
        try testing.expect(it.next() == null);
    }
    try testing.expect((try h.command("t=a", null)).? == .registration);
    {
        var it = h.registered().registeredMimes();
        try testing.expect(it.next() == null);
    }
    try testing.expect((try h.command("t=A", null)).? == .registration);
    try h.expectOutput("");
    try testing.expect(h.state == null);
    try testing.expect((try h.command("t=A", null)) == null);
    try h.expectOutput("");
    try testing.expect(h.state == null);
}
test "dnd: no state before registration" {
    var h: Harness = .init();
    defer h.deinit();
    _ = try h.command("t=m:o=1", "text/plain");
    _ = try h.command("t=r", null);
    try h.expectOutput("");
    _ = try h.command("t=r:x=1", null);
    try h.expectOutput(
        "\x1b]72;t=R:x=1:m=0;ENOENT:no drop data available\x1b\\",
    );
    try testing.expect(h.state == null);
}
test "dnd: move event carries position, operations, and mime list" {
    var h: Harness = .init();
    defer h.deinit();
    _ = try h.command("t=a", "text/plain");
    try h.registered().dragMove(testing.allocator, &h.output.writer, .{
        .cell_x = 5,
        .cell_y = 3,
        .pixel_x = 100,
        .pixel_y = 60,
        .operations = .{ .copy = true },
    }, &.{ "text/plain", "text/uri-list" });
    try h.expectOutput(
        "\x1b]72;t=m:x=5:y=3:X=100:Y=60:o=1:m=0;text/plain text/uri-list \x1b\\",
    );
}
test "dnd: move event echoes registration client id" {
    var h: Harness = .init();
    defer h.deinit();
    _ = try h.command("t=a:i=7", "");
    try h.registered().dragMove(testing.allocator, &h.output.writer, .{
        .cell_x = 1,
        .cell_y = 2,
        .pixel_x = 8,
        .pixel_y = 16,
        .operations = .{ .copy = true, .move = true },
    }, &.{"text/plain"});
    try h.expectOutput("\x1b]72;t=m:x=1:y=2:X=8:Y=16:o=3:i=7:m=0;text/plain \x1b\\");
}
test "dnd: re-registration updates client id in place" {
    var h: Harness = .init();
    defer h.deinit();
    _ = try h.command("t=a:i=7", "");
    const state = h.registered();
    _ = try h.command("t=a:i=9", "");
    try testing.expect(h.state.? == state);
    try testing.expectEqual(@as(u32, 9), state.drop.client_id);
}
test "dnd: mime list sent on every move" {
    var h: Harness = .init();
    defer h.deinit();
    _ = try h.command("t=a", "");
    const ev: dnd.MoveEvent = .{
        .cell_x = 0,
        .cell_y = 0,
        .pixel_x = 0,
        .pixel_y = 0,
        .operations = .{ .copy = true },
    };
    try h.registered().dragMove(testing.allocator, &h.output.writer, ev, &.{"text/plain"});
    h.clear();
    try h.registered().dragMove(testing.allocator, &h.output.writer, ev, &.{"text/plain"});
    try h.expectOutput("\x1b]72;t=m:x=0:y=0:X=0:Y=0:o=1:m=0;text/plain \x1b\\");
}
test "dnd: leave event" {
    var h: Harness = .init();
    defer h.deinit();
    _ = try h.command("t=a", "");
    try h.registered().dragMove(testing.allocator, &h.output.writer, .{
        .cell_x = 0,
        .cell_y = 0,
        .pixel_x = 0,
        .pixel_y = 0,
        .operations = .{ .copy = true },
    }, &.{"text/plain"});
    h.clear();
    try h.registered().dragLeave(testing.allocator, &h.output.writer);
    try h.expectOutput("\x1b]72;t=m:x=-1:y=-1\x1b\\");
}
test "dnd: client acceptance recorded" {
    var h: Harness = .init();
    defer h.deinit();
    _ = try h.command("t=a", "");
    try testing.expect(h.registered().clientAccepted() == null);
    try testing.expect((try h.command("t=m:o=1", "text/plain")).? == .acceptance);
    try h.expectOutput("");
    try testing.expectEqual(dnd.Operation.copy, h.registered().clientAccepted().?);
    try testing.expect((try h.command("t=m:o=0", "")).? == .acceptance);
    try testing.expectEqual(dnd.Operation.none, h.registered().clientAccepted().?);
}
test "dnd: chunked client acceptance" {
    var h: Harness = .init();
    defer h.deinit();
    _ = try h.command("t=a", "");
    try testing.expect((try h.command("t=m:o=2:m=1", "text/pl")) == null);
    try testing.expect(h.registered().clientAccepted() == null);
    try testing.expect((try h.command("t=m:m=1", "ain text")) == null);
    try testing.expect((try h.command("t=m:m=0", "/html")).? == .acceptance);
    try testing.expectEqual(dnd.Operation.move, h.registered().clientAccepted().?);
    try testing.expectEqualSlices(
        u8,
        "text/plain\x00text/html\x00",
        h.registered().drop.accepted_mimes.items,
    );
}
test "dnd: drop and data serving round trip" {
    var h: Harness = .init();
    defer h.deinit();
    _ = try h.command("t=a", "text/plain text/uri-list");
    const ev: dnd.MoveEvent = .{
        .cell_x = 4,
        .cell_y = 2,
        .pixel_x = 40,
        .pixel_y = 20,
        .operations = .{ .copy = true },
    };
    try h.registered().dragDrop(testing.allocator, &h.output.writer, ev, &.{
        .{ .mime = "text/uri-list", .data = "file:///tmp/a.txt\r\n" },
        .{ .mime = "text/plain", .data = "hello" },
    });
    try h.expectOutput(
        "\x1b]72;t=M:x=4:y=2:X=40:Y=20:o=1:m=0;text/uri-list text/plain \x1b\\",
    );
    _ = try h.command("t=r:x=2", null);
    try h.expectOutput(
        "\x1b]72;t=r:x=2:m=0;aGVsbG8=\x1b\\" ++ "\x1b]72;t=r:x=2\x1b\\",
    );
    _ = try h.command("t=r:x=3", null);
    try h.expectOutput(
        "\x1b]72;t=R:x=3:m=0;ENOENT:drop data request index out of bounds\x1b\\",
    );
    try testing.expectEqual(dnd.Event.concluded_copy, (try h.command("t=r:o=1", null)).?);
    try h.expectOutput("");
    try testing.expect((try h.command("t=r:o=1", null)) == null);
    _ = try h.command("t=r:x=1", null);
    try h.expectOutput(
        "\x1b]72;t=R:x=1:m=0;ENOENT:no drop data available\x1b\\",
    );
}
test "dnd: empty item served as a single end-of-data message" {
    var h: Harness = .init();
    defer h.deinit();
    _ = try h.command("t=a", "");
    try h.registered().dragDrop(testing.allocator, &h.output.writer, .{
        .cell_x = 0,
        .cell_y = 0,
        .pixel_x = 0,
        .pixel_y = 0,
        .operations = .{ .copy = true },
    }, &.{.{ .mime = "text/plain", .data = "" }});
    h.clear();
    _ = try h.command("t=r:x=1", null);
    try h.expectOutput("\x1b]72;t=r:x=1\x1b\\");
}
test "dnd: leave without hover sends nothing" {
    var h: Harness = .init();
    defer h.deinit();
    _ = try h.command("t=a", "");
    try h.registered().dragLeave(testing.allocator, &h.output.writer);
    try h.expectOutput("");
}
test "dnd: data request with no drop" {
    var h: Harness = .init();
    defer h.deinit();
    _ = try h.command("t=a", "");
    _ = try h.command("t=r:x=1", null);
    try h.expectOutput(
        "\x1b]72;t=R:x=1:m=0;ENOENT:no drop data available\x1b\\",
    );
}
test "dnd: leave after drop is ignored" {
    var h: Harness = .init();
    defer h.deinit();
    _ = try h.command("t=a", "");
    try h.registered().dragDrop(testing.allocator, &h.output.writer, .{
        .cell_x = 0,
        .cell_y = 0,
        .pixel_x = 0,
        .pixel_y = 0,
        .operations = .{ .copy = true },
    }, &.{.{ .mime = "text/plain", .data = "x" }});
    h.clear();
    try h.registered().dragLeave(testing.allocator, &h.output.writer);
    try h.expectOutput("");
    _ = try h.command("t=r:x=1", null);
    try h.expectOutput(
        "\x1b]72;t=r:x=1:m=0;eA==\x1b\\" ++ "\x1b]72;t=r:x=1\x1b\\",
    );
}
test "dnd: new drag resets held drop data" {
    var h: Harness = .init();
    defer h.deinit();
    _ = try h.command("t=a", "");
    const ev: dnd.MoveEvent = .{
        .cell_x = 0,
        .cell_y = 0,
        .pixel_x = 0,
        .pixel_y = 0,
        .operations = .{ .copy = true },
    };
    try h.registered().dragDrop(testing.allocator, &h.output.writer, ev, &.{
        .{ .mime = "text/plain", .data = "old" },
    });
    h.clear();
    try h.registered().dragMove(testing.allocator, &h.output.writer, ev, &.{"text/plain"});
    h.clear();
    _ = try h.command("t=r:x=1", null);
    try h.expectOutput(
        "\x1b]72;t=R:x=1:m=0;ENOENT:no drop data available\x1b\\",
    );
}
test "dnd: remote transfer requests refused" {
    var h: Harness = .init();
    defer h.deinit();
    _ = try h.command("t=a", "");
    _ = try h.command("t=r:x=1:y=2", null);
    try h.expectOutput(
        "\x1b]72;t=R:x=1:y=2:m=0;EINVAL:remote drop data is not supported\x1b\\",
    );
    _ = try h.command("t=r:Y=2:x=1", null);
    try h.expectOutput(
        "\x1b]72;t=R:x=1:Y=2:m=0;EINVAL:remote drop data is not supported\x1b\\",
    );
}
test "dnd: drag out refused" {
    var h: Harness = .init();
    defer h.deinit();
    _ = try h.command("t=o:x=1", null);
    _ = try h.command("t=o:x=2", null);
    try h.expectOutput("");
    try testing.expect(h.state == null);
    _ = try h.command("t=o:x=1", null);
    _ = try h.command("t=o:o=3", "text/plain");
    try h.expectOutput(
        "\x1b]72;t=E:m=0;EPERM:drag out is not supported by this terminal\x1b\\",
    );
    _ = try h.command("t=P:x=-1:i=9", null);
    try h.expectOutput(
        "\x1b]72;t=E:i=9:m=0;EPERM:drag out is not supported by this terminal\x1b\\",
    );
    try testing.expect(h.state == null);
}
test "dnd: unregister frees held drop data" {
    var h: Harness = .init();
    defer h.deinit();
    _ = try h.command("t=a", "");
    try h.registered().dragDrop(testing.allocator, &h.output.writer, .{
        .cell_x = 0,
        .cell_y = 0,
        .pixel_x = 0,
        .pixel_y = 0,
        .operations = .{ .copy = true },
    }, &.{.{ .mime = "text/plain", .data = "x" }});
    h.clear();
    _ = try h.command("t=A", null);
    try testing.expect(h.state == null);
}
test "dnd: chunked registration reuses first chunk metadata" {
    var h: Harness = .init();
    defer h.deinit();
    try testing.expect((try h.command("t=a:i=4:m=1", "text/pla")) == null);
    try testing.expect(h.state != null);
    try testing.expect((try h.command("t=q:m=0", "in")).? == .registration);
    try h.expectOutput("");
    try testing.expectEqual(@as(u32, 4), h.registered().drop.client_id);
    {
        var it = h.registered().registeredMimes();
        try testing.expectEqualStrings("text/plain", it.next().?);
    }
    _ = try h.command("t=q", null);
    try h.expectOutput("\x1b]72;t=q\x1b\\");
}
test "dnd: malformed metadata ignored" {
    var h: Harness = .init();
    defer h.deinit();
    _ = try h.command("t=a:zz=1", "");
    try h.expectOutput("");
    try testing.expect(h.state == null);
    _ = try h.command("x=1", "");
    try h.expectOutput("");
    try testing.expect(h.state == null);
}
test "dnd: bel terminator echoed in responses" {
    var h: Harness = .init();
    defer h.deinit();
    _ = try dnd.handleCommand(&h.state, testing.allocator, &h.output.writer, .{
        .metadata = "t=q",
        .payload = null,
        .terminator = .bel,
    });
    try h.expectOutput("\x1b]72;t=q\x07");
}
test "dnd: kitten 0.47 conversation replay" {
    var h: Harness = .init();
    defer h.deinit();
    _ = try h.command("t=a:m=0", "text/uri-list text/plain");
    _ = try h.command(
        "t=a:x=1:m=0",
        "1:5cff8247c477900a8727e2281fe890252f8848f87c224dd8dd7fb6303e94ddbd",
    );
    _ = try h.command("t=A", null);
    try testing.expect(h.state == null);
    _ = try h.command("t=o:x=2", null);
    _ = try h.command("t=a:m=0", "text/uri-list text/plain");
    _ = try h.command(
        "t=a:x=1:m=0",
        "1:5cff8247c477900a8727e2281fe890252f8848f87c224dd8dd7fb6303e94ddbd",
    );
    try h.expectOutput("");
    try testing.expect(h.state != null);
    const ev: dnd.MoveEvent = .{
        .cell_x = 2,
        .cell_y = 1,
        .pixel_x = 20,
        .pixel_y = 18,
        .operations = .{ .copy = true },
    };
    try h.registered().dragMove(testing.allocator, &h.output.writer, ev, &.{"text/plain"});
    try h.expectOutput("\x1b]72;t=m:x=2:y=1:X=20:Y=18:o=1:m=0;text/plain \x1b\\");
    _ = try h.command("t=m:o=1:m=0", "text/plain");
    try h.expectOutput("");
    try testing.expectEqual(dnd.Operation.copy, h.registered().clientAccepted().?);
    try h.registered().dragDrop(testing.allocator, &h.output.writer, ev, &.{
        .{ .mime = "text/plain", .data = "hello from wasp\n" },
    });
    try h.expectOutput("\x1b]72;t=M:x=2:y=1:X=20:Y=18:o=1:m=0;text/plain \x1b\\");
    _ = try h.command("t=r:x=1", null);
    try h.expectOutput(
        "\x1b]72;t=r:x=1:m=0;aGVsbG8gZnJvbSBnaG9zdHR5Cg==\x1b\\" ++
            "\x1b]72;t=r:x=1\x1b\\",
    );
    _ = try h.command("t=r:o=1", null);
    try h.expectOutput("");
    try testing.expect(h.registered().drop.items == null);
}
test "dnd: large data served in chunks" {
    var h: Harness = .init();
    defer h.deinit();
    _ = try h.command("t=a", "");
    const data = [_]u8{'Z'} ** 3073;
    try h.registered().dragDrop(testing.allocator, &h.output.writer, .{
        .cell_x = 0,
        .cell_y = 0,
        .pixel_x = 0,
        .pixel_y = 0,
        .operations = .{ .copy = true },
    }, &.{.{ .mime = "application/octet-stream", .data = &data }});
    h.clear();
    _ = try h.command("t=r:x=1", null);
    const out = h.consume();
    try testing.expect(std.mem.startsWith(u8, out, "\x1b]72;t=r:x=1:m=1;"));
    try testing.expect(std.mem.indexOf(u8, out, "\x1b]72;t=r:x=1:m=0;") != null);
    try testing.expect(std.mem.endsWith(u8, out, "\x1b]72;t=r:x=1\x1b\\"));
    h.clear();
}
test "dnd: over-cap registration list never completes" {
    var h: Harness = .init();
    defer h.deinit();
    const big = try testing.allocator.alloc(u8, dnd.max_mime_list_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    try testing.expect((try h.command("t=a", big)) == null);
    try testing.expect(h.state != null);
    {
        var it = h.registered().registeredMimes();
        try testing.expect(it.next() == null);
    }
}
