const std = @import("std");
pub const Metadata = struct {
    type: ?EventType = null,
    more: bool = false,
    client_id: u32 = 0,
    operation: u32 = 0,
    cell_x: i32 = 0,
    cell_y: i32 = 0,
    pixel_x: i32 = 0,
    pixel_y: i32 = 0,
    pub fn parse(raw: []const u8) ?Metadata {
        var result: Metadata = .{};
        var pos: usize = 0;
        while (pos < raw.len) : (pos += 1) {
            const key = raw[pos];
            pos += 1;
            switch (key) {
                't', 'm', 'i', 'o', 'x', 'y', 'X', 'Y' => {},
                else => return null,
            }
            if (pos >= raw.len) return null;
            if (raw[pos] != '=') return null;
            pos += 1;
            if (pos >= raw.len) return null;
            switch (key) {
                't' => {
                    result.type = std.enums.fromInt(
                        EventType,
                        raw[pos],
                    ) orelse return null;
                    pos += 1;
                },
                'm', 'i', 'o' => {
                    const v = parseUnsigned(raw, &pos) orelse return null;
                    switch (key) {
                        'm' => result.more = v != 0,
                        'i' => result.client_id = v,
                        'o' => result.operation = v,
                        else => unreachable,
                    }
                },
                'x', 'y', 'X', 'Y' => {
                    const negative = raw[pos] == '-';
                    if (negative) pos += 1;
                    const unsigned = parseUnsigned(raw, &pos) orelse return null;
                    const magnitude: i32 = @bitCast(unsigned);
                    const v = if (negative) 0 -% magnitude else magnitude;
                    switch (key) {
                        'x' => result.cell_x = v,
                        'y' => result.cell_y = v,
                        'X' => result.pixel_x = v,
                        'Y' => result.pixel_y = v,
                        else => unreachable,
                    }
                },
                else => unreachable,
            }
            if (pos >= raw.len) break;
            if (raw[pos] != ':') return null;
        }
        return result;
    }
    fn parseUnsigned(raw: []const u8, pos: *usize) ?u32 {
        const start = pos.*;
        var acc: u64 = 0;
        var i = start;
        while (i < raw.len and i < start + 10) : (i += 1) {
            const d = raw[i] -% '0';
            if (d > 9) break;
            acc = acc * 10 + d;
        }
        if (i == start) return null;
        pos.* = i;
        return std.math.cast(u32, acc) orelse null;
    }
};
pub const EventType = enum(u8) {
    register = 'a',
    unregister = 'A',
    status = 'm',
    drop = 'M',
    request = 'r',
    request_error = 'R',
    offer = 'o',
    present = 'p',
    start_drag = 'P',
    drag_event = 'e',
    drag_error = 'E',
    remote_data = 'k',
    query = 'q',
};
pub const Operation = enum(u2) {
    none = 0,
    copy = 1,
    move = 2,
    pub fn fromProtocol(v: u32) Operation {
        return switch (v) {
            1 => .copy,
            2 => .move,
            else => .none,
        };
    }
};
pub const Operations = packed struct(u2) {
    copy: bool = false,
    move: bool = false,
    pub fn protocolValue(self: Operations) u2 {
        return @bitCast(self);
    }
};
pub const Request = union(enum) {
    conclude: Operation,
    mime: i32,
    uri: struct {
        mime_idx: i32,
        uri_idx: i32,
    },
    dir: struct {
        handle: i32,
        entry: i32,
    },
    pub fn init(meta: Metadata) Request {
        if (meta.pixel_y != 0) return .{ .dir = .{
            .handle = meta.pixel_y,
            .entry = meta.cell_x,
        } };
        if (meta.cell_y != 0) return .{ .uri = .{
            .mime_idx = meta.cell_x,
            .uri_idx = meta.cell_y,
        } };
        if (meta.cell_x != 0) return .{ .mime = meta.cell_x };
        return .{ .conclude = .fromProtocol(meta.operation) };
    }
};
pub const Chunking = struct {
    active: bool = false,
    metadata: Metadata = .{},
    pub fn apply(self: *Chunking, meta: Metadata) Metadata {
        if (self.active) {
            var copy = self.metadata;
            copy.more = meta.more;
            self.active = meta.more;
            return copy;
        }
        if (meta.more) {
            self.active = true;
            self.metadata = meta;
        }
        return meta;
    }
};
test "Metadata: empty" {
    const testing = std.testing;
    const meta = Metadata.parse("").?;
    try testing.expect(meta.type == null);
    try testing.expect(!meta.more);
    try testing.expectEqual(@as(u32, 0), meta.client_id);
}
test "Metadata: all keys" {
    const testing = std.testing;
    const meta = Metadata.parse("t=m:m=1:i=3:o=2:x=10:y=5:X=320:Y=200").?;
    try testing.expectEqual(EventType.status, meta.type.?);
    try testing.expect(meta.more);
    try testing.expectEqual(@as(u32, 3), meta.client_id);
    try testing.expectEqual(@as(u32, 2), meta.operation);
    try testing.expectEqual(@as(i32, 10), meta.cell_x);
    try testing.expectEqual(@as(i32, 5), meta.cell_y);
    try testing.expectEqual(@as(i32, 320), meta.pixel_x);
    try testing.expectEqual(@as(i32, 200), meta.pixel_y);
}
test "Metadata: all event types" {
    const testing = std.testing;
    const cases = .{
        .{ "t=a", EventType.register },
        .{ "t=A", EventType.unregister },
        .{ "t=m", EventType.status },
        .{ "t=M", EventType.drop },
        .{ "t=r", EventType.request },
        .{ "t=R", EventType.request_error },
        .{ "t=o", EventType.offer },
        .{ "t=p", EventType.present },
        .{ "t=P", EventType.start_drag },
        .{ "t=e", EventType.drag_event },
        .{ "t=E", EventType.drag_error },
        .{ "t=k", EventType.remote_data },
        .{ "t=q", EventType.query },
    };
    inline for (cases) |case| {
        try testing.expectEqual(case[1], Metadata.parse(case[0]).?.type.?);
    }
}
test "Metadata: case-sensitive coordinate keys" {
    const testing = std.testing;
    const meta = Metadata.parse("x=10:Y=200").?;
    try testing.expectEqual(@as(i32, 10), meta.cell_x);
    try testing.expectEqual(@as(i32, 0), meta.cell_y);
    try testing.expectEqual(@as(i32, 0), meta.pixel_x);
    try testing.expectEqual(@as(i32, 200), meta.pixel_y);
}
test "Metadata: negative coordinates" {
    const testing = std.testing;
    const meta = Metadata.parse("t=m:x=-1:y=-1").?;
    try testing.expectEqual(@as(i32, -1), meta.cell_x);
    try testing.expectEqual(@as(i32, -1), meta.cell_y);
}
test "Metadata: malformed inputs rejected" {
    const testing = std.testing;
    try testing.expect(Metadata.parse("t=z") == null);
    try testing.expect(Metadata.parse("z=1") == null);
    try testing.expect(Metadata.parse("x10") == null);
    try testing.expect(Metadata.parse("x=notanumber") == null);
    try testing.expect(Metadata.parse("x=-") == null);
    try testing.expect(Metadata.parse("i=4294967296") == null);
    try testing.expect(Metadata.parse("i=99999999999") == null);
    try testing.expect(Metadata.parse("x=1z") == null);
    try testing.expect(Metadata.parse("t=a: x=1") == null);
    try testing.expect(Metadata.parse("t = a") == null);
    try testing.expect(Metadata.parse("t") == null);
    try testing.expect(Metadata.parse("t=") == null);
    try testing.expect(Metadata.parse("x=") == null);
    try testing.expect(Metadata.parse("t=r:x=") == null);
    try testing.expect(Metadata.parse("x=1:t=") == null);
}
test "Metadata: trailing separator accepted" {
    const testing = std.testing;
    const meta = Metadata.parse("t=a:").?;
    try testing.expectEqual(EventType.register, meta.type.?);
}
test "Metadata: u32 boundary accepted" {
    const testing = std.testing;
    const meta = Metadata.parse("i=4294967295").?;
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), meta.client_id);
}
test "Request: classification" {
    const testing = std.testing;
    {
        const r: Request = .init(Metadata.parse("t=r:o=2").?);
        try testing.expectEqual(Operation.move, r.conclude);
    }
    {
        const r: Request = .init(Metadata.parse("t=r:o=9").?);
        try testing.expectEqual(Operation.none, r.conclude);
    }
    {
        const r: Request = .init(Metadata.parse("t=r:x=2").?);
        try testing.expectEqual(@as(i32, 2), r.mime);
    }
    {
        const r: Request = .init(Metadata.parse("t=r:x=1:y=3").?);
        try testing.expectEqual(@as(i32, 1), r.uri.mime_idx);
        try testing.expectEqual(@as(i32, 3), r.uri.uri_idx);
    }
    {
        const r: Request = .init(Metadata.parse("t=r:Y=2:x=1").?);
        try testing.expectEqual(@as(i32, 2), r.dir.handle);
        try testing.expectEqual(@as(i32, 1), r.dir.entry);
    }
}
test "Chunking: reassembly reuses first chunk metadata" {
    const testing = std.testing;
    var chunking: Chunking = .{};
    const first = chunking.apply(Metadata.parse("t=m:o=1:m=1").?);
    try testing.expect(chunking.active);
    try testing.expectEqual(EventType.status, first.type.?);
    try testing.expect(first.more);
    const second = chunking.apply(Metadata.parse("t=q:o=2:m=1").?);
    try testing.expect(chunking.active);
    try testing.expectEqual(EventType.status, second.type.?);
    try testing.expectEqual(@as(u32, 1), second.operation);
    try testing.expect(second.more);
    const last = chunking.apply(Metadata.parse("t=q:m=0").?);
    try testing.expect(!chunking.active);
    try testing.expectEqual(EventType.status, last.type.?);
    try testing.expect(!last.more);
}
test "Chunking: unchunked commands pass through" {
    const testing = std.testing;
    var chunking: Chunking = .{};
    const meta = chunking.apply(Metadata.parse("t=q").?);
    try testing.expect(!chunking.active);
    try testing.expectEqual(EventType.query, meta.type.?);
}
