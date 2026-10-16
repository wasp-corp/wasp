const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.sentry_envelope);
pub const Envelope = struct {
    arena: std.heap.ArenaAllocator,
    headers: std.json.ObjectMap,
    items: std.ArrayList(Item),
    pub fn parse(
        alloc_gpa: Allocator,
        reader: *std.Io.Reader,
    ) !Envelope {
        var arena = std.heap.ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const headers = try parseHeader(alloc, reader);
        const items = try parseItems(alloc, reader);
        return .{
            .headers = headers,
            .items = items,
            .arena = arena,
        };
    }
    fn parseHeader(
        alloc: Allocator,
        reader: *std.Io.Reader,
    ) !std.json.ObjectMap {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        _ = try reader.streamDelimiterLimit(
            &buf.writer,
            '\n',
            .limited(1024 * 1024), 
        );
        _ = reader.discardDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        };
        const value = try std.json.parseFromSliceLeaky(
            std.json.Value,
            alloc,
            buf.written(),
            .{ .allocate = .alloc_if_needed },
        );
        return switch (value) {
            .object => |map| map,
            else => error.EnvelopeMalformedHeaders,
        };
    }
    fn parseItems(
        alloc: Allocator,
        reader: *std.Io.Reader,
    ) !std.ArrayList(Item) {
        var items: std.ArrayList(Item) = .empty;
        errdefer items.deinit(alloc);
        while (try parseOneItem(alloc, reader)) |item| {
            try items.append(alloc, item);
        }
        return items;
    }
    fn parseOneItem(
        alloc: Allocator,
        reader: *std.Io.Reader,
    ) !?Item {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        _ = reader.streamDelimiterLimit(
            &buf.writer,
            '\n',
            .limited(1024 * 1024), 
        ) catch |err| switch (err) {
            error.StreamTooLong => return null,
            else => return err,
        };
        _ = reader.discardDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        };
        const headers: std.json.ObjectMap = headers: {
            const line = std.mem.trim(u8, buf.written(), " \t");
            if (line.len == 0) return null;
            const value = try std.json.parseFromSliceLeaky(
                std.json.Value,
                alloc,
                line,
                .{ .allocate = .alloc_if_needed },
            );
            break :headers switch (value) {
                .object => |map| map,
                else => return error.EnvelopeItemMalformedHeaders,
            };
        };
        const typ: ItemType = if (headers.get("type")) |v| switch (v) {
            .string => |str| std.meta.stringToEnum(
                ItemType,
                str,
            ) orelse .unknown,
            else => return error.EnvelopeItemTypeMissing,
        } else return error.EnvelopeItemTypeMissing;
        const len_: ?u64 = if (headers.get("length")) |v| switch (v) {
            .integer => |int| std.math.cast(
                u64,
                int,
            ) orelse return error.EnvelopeItemLengthMalformed,
            else => return error.EnvelopeItemLengthMalformed,
        } else null;
        const payload: []const u8 = if (len_) |len| payload: {
            var payload: std.Io.Writer.Allocating = .init(alloc);
            defer payload.deinit();
            reader.streamExact(&payload.writer, len) catch |err| switch (err) {
                error.EndOfStream => return error.EnvelopeItemPayloadTooShort,
                else => return err,
            };
            if (reader.takeByte()) |byte| {
                if (byte != '\n') return error.EnvelopeItemPayloadNoNewline;
            } else |err| switch (err) {
                error.EndOfStream => {},
                else => return err,
            }
            break :payload try payload.toOwnedSlice();
        } else payload: {
            var payload: std.Io.Writer.Allocating = .init(alloc);
            _ = reader.streamDelimiterLimit(
                &payload.writer,
                '\n',
                .limited(1024 * 1024), 
            ) catch |err| switch (err) {
                error.StreamTooLong => return error.EnvelopeItemPayloadTooShort,
                else => |v| return v,
            };
            _ = reader.discardDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => {},
                else => return err,
            };
            break :payload try payload.toOwnedSlice();
        };
        return .{ .encoded = .{
            .headers = headers,
            .type = typ,
            .payload = payload,
        } };
    }
    pub fn deinit(self: *Envelope) void {
        self.arena.deinit();
    }
    pub fn allocator(self: *Envelope) Allocator {
        return self.arena.allocator();
    }
    pub fn serialize(
        self: *Envelope,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("{f}\n", .{std.json.fmt(
            std.json.Value{ .object = self.headers },
            json_opts,
        )});
        const alloc = self.allocator();
        for (self.items.items, 0..) |*item, idx| {
            if (idx > 0) try writer.writeByte('\n');
            const encoded = try item.encode(alloc);
            assert(item.* == .encoded);
            try writer.print("{f}\n{s}", .{
                std.json.fmt(
                    std.json.Value{ .object = encoded.headers },
                    json_opts,
                ),
                encoded.payload,
            });
        }
    }
};
pub const ItemType = enum {
    unknown,
    event,
    transaction,
    attachment,
    session,
    sessions,
    statsd,
    metric_meta,
    user_feedback,
    client_report,
    replay_event,
    replay_recording,
    profile,
    check_in,
};
pub const Item = union(enum) {
    encoded: EncodedItem,
    attachment: Attachment,
    pub fn encode(
        self: *Item,
        alloc: Allocator,
    ) !EncodedItem {
        const result: EncodedItem = switch (self.*) {
            .encoded => |v| return v,
            .attachment => |*v| try v.encode(alloc),
        };
        self.* = .{ .encoded = result };
        return result;
    }
    pub fn itemType(self: Item) ItemType {
        return switch (self) {
            .encoded => |v| v.type,
            .attachment => .attachment,
        };
    }
    pub const DecodeError = Allocator.Error || error{
        MissingRequiredField,
        InvalidFieldType,
        UnsupportedType,
    };
    pub fn decode(self: *Item, alloc: Allocator) DecodeError!void {
        const encoded: EncodedItem = switch (self.*) {
            .encoded => |v| v,
            else => return,
        };
        self.* = switch (encoded.type) {
            .attachment => .{ .attachment = try .decode(
                alloc,
                encoded,
            ) },
            else => return error.UnsupportedType,
        };
    }
};
pub const EncodedItem = struct {
    headers: std.json.ObjectMap,
    type: ItemType,
    payload: []const u8,
};
pub const Attachment = struct {
    filename: []const u8,
    type: ?[]const u8 = null,
    headers_extra: ObjectMapUnmanaged = .{},
    payload: []const u8,
    pub fn decode(
        alloc: Allocator,
        item: EncodedItem,
    ) Item.DecodeError!Attachment {
        _ = alloc;
        return .{
            .filename = if (item.headers.get("filename")) |v| switch (v) {
                .string => |str| str,
                else => return error.InvalidFieldType,
            } else return error.MissingRequiredField,
            .type = if (item.headers.get("attachment_type")) |v| switch (v) {
                .string => |str| str,
                else => return error.InvalidFieldType,
            } else null,
            .headers_extra = item.headers,
            .payload = item.payload,
        };
    }
    pub fn encode(
        self: *Attachment,
        alloc: Allocator,
    ) !EncodedItem {
        try self.headers_extra.put(
            alloc,
            "filename",
            .{ .string = self.filename },
        );
        if (self.type) |v| {
            try self.headers_extra.put(
                alloc,
                "attachment_type",
                .{ .string = v },
            );
        } else {
            _ = self.headers_extra.swapRemove("attachment_type");
        }
        return .{
            .headers = self.headers_extra,
            .type = .attachment,
            .payload = self.payload,
        };
    }
};
pub const ObjectMapUnmanaged = std.StringArrayHashMapUnmanaged(std.json.Value);
const json_opts: std.json.Stringify.Options = .{
    .whitespace = .minified,
};
test "Envelope parse" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var reader: std.Io.Reader = .fixed(
        \\{}
    );
    var v = try Envelope.parse(alloc, &reader);
    defer v.deinit();
}
test "Envelope parse session" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var reader: std.Io.Reader = .fixed(
        \\{}
        \\{"type":"session","length":218}
        \\{"init":true,"sid":"c148cc2f-5f9f-4231-575c-2e85504d6434","status":"abnormal","errors":0,"started":"2024-08-29T02:38:57.607016Z","duration":0.000343,"attrs":{"release":"0.1.0-HEAD+d37b7d09","environment":"production"}}
    );
    var v = try Envelope.parse(alloc, &reader);
    defer v.deinit();
    try testing.expectEqual(@as(usize, 1), v.items.items.len);
    try testing.expectEqual(ItemType.session, v.items.items[0].encoded.type);
}
test "Envelope parse multiple" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var reader: std.Io.Reader = .fixed(
        \\{}
        \\{"type":"session","length":218}
        \\{"init":true,"sid":"c148cc2f-5f9f-4231-575c-2e85504d6434","status":"abnormal","errors":0,"started":"2024-08-29T02:38:57.607016Z","duration":0.000343,"attrs":{"release":"0.1.0-HEAD+d37b7d09","environment":"production"}}
        \\{"type":"attachment","length":4,"filename":"test.txt"}
        \\ABCD
    );
    var v = try Envelope.parse(alloc, &reader);
    defer v.deinit();
    try testing.expectEqual(@as(usize, 2), v.items.items.len);
    try testing.expectEqual(ItemType.session, v.items.items[0].encoded.type);
    try testing.expectEqual(ItemType.attachment, v.items.items[1].encoded.type);
}
test "Envelope parse multiple no length" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var reader: std.Io.Reader = .fixed(
        \\{}
        \\{"type":"session"}
        \\{}
        \\{"type":"attachment","length":4,"filename":"test.txt"}
        \\ABCD
    );
    var v = try Envelope.parse(alloc, &reader);
    defer v.deinit();
    try testing.expectEqual(@as(usize, 2), v.items.items.len);
    try testing.expectEqual(ItemType.session, v.items.items[0].encoded.type);
    try testing.expectEqual(ItemType.attachment, v.items.items[1].encoded.type);
}
test "Envelope parse end in new line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var reader: std.Io.Reader = .fixed(
        \\{}
        \\{"type":"session","length":218}
        \\{"init":true,"sid":"c148cc2f-5f9f-4231-575c-2e85504d6434","status":"abnormal","errors":0,"started":"2024-08-29T02:38:57.607016Z","duration":0.000343,"attrs":{"release":"0.1.0-HEAD+d37b7d09","environment":"production"}}
        \\
    );
    var v = try Envelope.parse(alloc, &reader);
    defer v.deinit();
    try testing.expectEqual(@as(usize, 1), v.items.items.len);
    try testing.expectEqual(ItemType.session, v.items.items[0].encoded.type);
}
test "Envelope parse attachment" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var reader: std.Io.Reader = .fixed(
        \\{}
        \\{"type":"attachment","length":4,"filename":"test.txt"}
        \\ABCD
    );
    var v = try Envelope.parse(alloc, &reader);
    defer v.deinit();
    try testing.expectEqual(@as(usize, 1), v.items.items.len);
    var item = &v.items.items[0];
    try testing.expectEqual(ItemType.attachment, item.encoded.type);
    try item.decode(v.allocator());
    try testing.expect(item.* == .attachment);
    try testing.expectEqualStrings("test.txt", item.attachment.filename);
    {
        var output: std.Io.Writer.Allocating = .init(alloc);
        defer output.deinit();
        try v.serialize(&output.writer);
        try testing.expectEqualStrings(
            \\{}
            \\{"type":"attachment","length":4,"filename":"test.txt"}
            \\ABCD
        , std.mem.trim(u8, output.written(), "\n"));
    }
}
test "Envelope serialize empty" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var reader: std.Io.Reader = .fixed(
        \\{}
    );
    var v = try Envelope.parse(alloc, &reader);
    defer v.deinit();
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    try v.serialize(&output.writer);
    try testing.expectEqualStrings(
        \\{}
    , std.mem.trim(u8, output.written(), "\n"));
}
test "Envelope serialize session" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var reader: std.Io.Reader = .fixed(
        \\{}
        \\{"type":"session","length":218}
        \\{"init":true,"sid":"c148cc2f-5f9f-4231-575c-2e85504d6434","status":"abnormal","errors":0,"started":"2024-08-29T02:38:57.607016Z","duration":0.000343,"attrs":{"release":"0.1.0-HEAD+d37b7d09","environment":"production"}}
    );
    var v = try Envelope.parse(alloc, &reader);
    defer v.deinit();
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    try v.serialize(&output.writer);
    try testing.expectEqualStrings(
        \\{}
        \\{"type":"session","length":218}
        \\{"init":true,"sid":"c148cc2f-5f9f-4231-575c-2e85504d6434","status":"abnormal","errors":0,"started":"2024-08-29T02:38:57.607016Z","duration":0.000343,"attrs":{"release":"0.1.0-HEAD+d37b7d09","environment":"production"}}
    , std.mem.trim(u8, output.written(), "\n"));
}
