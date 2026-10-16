const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const simd = @import("../../simd/root.zig");
const clipboard = @import("../clipboard.zig");
const clipboard_command = @import("clipboard_command.zig");
const Metadata = clipboard_command.Metadata;
const Payload = clipboard_command.Payload;
const max_mime_len = clipboard_command.max_mime_len;
const log = std.log.scoped(.kitty_clipboard);
pub const max_write_size = 64 * 1024 * 1024;
pub const max_write_mimes = 64;
pub const max_write_aliases = 64;
pub const Content = clipboard.Content;
pub const WriteState = struct {
    arena: std.heap.ArenaAllocator,
    loc: clipboard.Location,
    id: []const u8,
    pw: []const u8,
    name: []const u8,
    spool: std.ArrayListUnmanaged(u8) = .empty,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    aliases: std.ArrayListUnmanaged(Alias) = .empty,
    max_size: usize,
    current: ?usize = null,
    decoder: simd.base64.Streaming = .{},
    pub const Options = struct {
        max_size: usize = max_write_size,
    };
    const Entry = struct {
        mime: []const u8,
        start: usize = 0,
        len: usize = 0,
    };
    const Alias = struct {
        alias: []const u8,
        target_buf: [max_mime_len]u8 = undefined,
        target_len: usize = 0,
        fn target(self: *const Alias) []const u8 {
            return self.target_buf[0..self.target_len];
        }
        fn setTarget(self: *Alias, v: []const u8) void {
            assert(v.len <= max_mime_len);
            @memcpy(self.target_buf[0..v.len], v);
            self.target_len = v.len;
        }
    };
    pub fn init(
        alloc: Allocator,
        meta: *const Metadata,
        opts: Options,
    ) Allocator.Error!WriteState {
        assert(meta.op == .write);
        var arena: std.heap.ArenaAllocator = .init(alloc);
        errdefer arena.deinit();
        const id = try arena.allocator().dupe(u8, meta.id);
        const pw = try arena.allocator().dupe(u8, meta.pw);
        const name = try arena.allocator().dupe(u8, meta.name);
        return .{
            .arena = arena,
            .loc = meta.loc,
            .id = id,
            .pw = pw,
            .name = name,
            .max_size = opts.max_size,
        };
    }
    pub fn deinit(self: *WriteState, alloc: Allocator) void {
        self.spool.deinit(alloc);
        self.entries.deinit(alloc);
        self.aliases.deinit(alloc);
        self.arena.deinit();
    }
    pub fn data(
        self: *WriteState,
        alloc: Allocator,
        meta: *const Metadata,
        payload: []const u8,
    ) error{ OutOfMemory, TooLarge, Invalid }!void {
        assert(meta.op == .wdata);
        assert(meta.mime.len > 0);
        entry: {
            if (self.current) |idx| {
                const entry = &self.entries.items[idx];
                if (std.mem.eql(u8, entry.mime, meta.mime)) {
                    break :entry;
                }
                try self.finishCurrent();
                entry.len = self.spool.items.len - entry.start;
            }
            for (self.entries.items, 0..) |*entry, idx| {
                if (std.mem.eql(u8, entry.mime, meta.mime)) {
                    entry.start = self.spool.items.len;
                    entry.len = 0;
                    self.current = idx;
                    break :entry;
                }
            }
            if (self.entries.items.len >= max_write_mimes) {
                log.warn(
                    "clipboard write has too many MIME types, ignoring mime={s}",
                    .{meta.mime},
                );
                self.current = null;
                return;
            }
            try self.entries.append(alloc, .{
                .mime = try self.arena.allocator().dupe(u8, meta.mime),
                .start = self.spool.items.len,
            });
            self.current = self.entries.items.len - 1;
        }
        try self.spool.ensureUnusedCapacity(alloc, self.decoder.maxLen(payload));
        const decoded = self.decoder.feed(
            payload,
            self.spool.unusedCapacitySlice(),
        ) catch return error.Invalid;
        const remaining = self.max_size -| self.spool.items.len;
        if (decoded.len > remaining) return error.TooLarge;
        self.spool.items.len += decoded.len;
    }
    fn finishCurrent(self: *WriteState) error{Invalid}!void {
        self.decoder.finish() catch return error.Invalid;
    }
    pub fn alias(
        self: *WriteState,
        alloc: Allocator,
        meta: *const Metadata,
        payload: []const u8,
    ) error{ OutOfMemory, Invalid }!void {
        assert(meta.op == .walias);
        assert(meta.mime.len > 0);
        const decoded = try Payload.init(alloc, payload);
        defer decoded.deinit(alloc);
        if (!decoded.isValidUtf8()) return error.Invalid;
        var it = decoded.mimeIterator();
        while (it.next()) |name| {
            if (name.len > max_mime_len) continue;
            for (self.aliases.items) |*a| {
                if (std.mem.eql(u8, a.alias, name)) {
                    a.setTarget(meta.mime);
                    break;
                }
            } else {
                if (self.aliases.items.len >= max_write_aliases) {
                    log.warn("clipboard write has too many aliases, ignoring", .{});
                    return;
                }
                var a: Alias = .{
                    .alias = try self.arena.allocator().dupe(u8, name),
                };
                a.setTarget(meta.mime);
                try self.aliases.append(alloc, a);
            }
        }
    }
    pub const Committed = struct {
        loc: clipboard.Location,
        id: []const u8,
        pw: []const u8,
        name: []const u8,
        contents: []const Content,
        pub fn deinit(self: *const Committed, alloc: Allocator) void {
            alloc.free(self.contents);
        }
    };
    pub fn commit(
        self: *WriteState,
        alloc: Allocator,
    ) error{ OutOfMemory, Invalid }!Committed {
        if (self.current) |idx| {
            try self.finishCurrent();
            const entry = &self.entries.items[idx];
            entry.len = self.spool.items.len - entry.start;
            self.current = null;
        }
        var contents: std.ArrayListUnmanaged(Content) = .empty;
        defer contents.deinit(alloc);
        try contents.ensureTotalCapacity(
            alloc,
            self.entries.items.len + self.aliases.items.len,
        );
        for (self.entries.items) |*entry| {
            contents.appendAssumeCapacity(.{
                .mime = entry.mime,
                .data = self.spool.items[entry.start..][0..entry.len],
            });
        }
        for (self.aliases.items) |*a| {
            const target: Content = target: {
                for (contents.items) |c| {
                    if (std.mem.eql(u8, c.mime, a.target())) {
                        break :target c;
                    }
                }
                continue;
            };
            for (contents.items) |*c| {
                if (std.mem.eql(u8, c.mime, a.alias)) {
                    c.data = target.data;
                    break;
                }
            } else {
                contents.appendAssumeCapacity(.{
                    .mime = a.alias,
                    .data = target.data,
                });
            }
        }
        return .{
            .loc = self.loc,
            .id = self.id,
            .pw = self.pw,
            .name = self.name,
            .contents = try contents.toOwnedSlice(alloc),
        };
    }
};
test "write: basic transaction" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const begin_meta: Metadata = .{ .op = .write, .id = "42" };
    var state: WriteState = try .init(alloc, &begin_meta, .{});
    defer state.deinit(alloc);
    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "R2hvc3R0eQ==");
    const committed = try state.commit(alloc);
    defer committed.deinit(alloc);
    try testing.expectEqualStrings("42", committed.id);
    try testing.expect(committed.loc == .standard);
    try testing.expectEqual(@as(usize, 1), committed.contents.len);
    try testing.expectEqualStrings("text/plain", committed.contents[0].mime);
    try testing.expectEqualStrings("Wasp", committed.contents[0].data);
}
test "write: chunked data accumulates" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{});
    defer state.deinit(alloc);
    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "SGVsbG8=");
    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "V29ybGQ=");
    const committed = try state.commit(alloc);
    defer committed.deinit(alloc);
    try testing.expectEqualStrings("HelloWorld", committed.contents[0].data);
}
test "write: multiple mimes in order" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{});
    defer state.deinit(alloc);
    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "YQ==");
    try state.data(alloc, &.{ .op = .wdata, .mime = "text/html" }, "Yg==");
    const committed = try state.commit(alloc);
    defer committed.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), committed.contents.len);
    try testing.expectEqualStrings("text/plain", committed.contents[0].mime);
    try testing.expectEqualStrings("a", committed.contents[0].data);
    try testing.expectEqualStrings("text/html", committed.contents[1].mime);
    try testing.expectEqualStrings("b", committed.contents[1].data);
}
test "write: reused mime overwrites" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{});
    defer state.deinit(alloc);
    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "YQ==");
    try state.data(alloc, &.{ .op = .wdata, .mime = "text/html" }, "Yg==");
    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "Yw==");
    const committed = try state.commit(alloc);
    defer committed.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), committed.contents.len);
    try testing.expectEqualStrings("text/plain", committed.contents[0].mime);
    try testing.expectEqualStrings("c", committed.contents[0].data);
}
test "write: invalid base64 chunk aborts the transaction" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const invalid_payloads = [_][]const u8{
        "!!!",
        "SGVs!!!bG8=",
        "\nZGF0YSB3aXRoIGEgbmV3bGluZQ==",
    };
    for (invalid_payloads) |payload| {
        const begin_meta: Metadata = .{ .op = .write };
        var state: WriteState = try .init(alloc, &begin_meta, .{});
        defer state.deinit(alloc);
        try testing.expectError(error.Invalid, state.data(
            alloc,
            &.{ .op = .wdata, .mime = "text/plain" },
            payload,
        ));
    }
    {
        const begin_meta: Metadata = .{ .op = .write };
        var state: WriteState = try .init(alloc, &begin_meta, .{});
        defer state.deinit(alloc);
        try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "Z29vZA==");
        try testing.expectError(error.Invalid, state.data(
            alloc,
            &.{ .op = .wdata, .mime = "text/plain" },
            "SGVs!!!bG8=",
        ));
    }
}
test "write: chunks split one base64 stream at arbitrary boundaries" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const encoded = "c29tZSBkYXRh";
    const splits = [_][]const usize{
        &.{ 3, 7 },
        &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 },
    };
    for (splits) |split| {
        const begin_meta: Metadata = .{ .op = .write };
        var state: WriteState = try .init(alloc, &begin_meta, .{});
        defer state.deinit(alloc);
        var prev: usize = 0;
        for (split) |end| {
            try state.data(
                alloc,
                &.{ .op = .wdata, .mime = "text/plain" },
                encoded[prev..end],
            );
            prev = end;
        }
        try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, encoded[prev..]);
        const committed = try state.commit(alloc);
        defer committed.deinit(alloc);
        try testing.expectEqualStrings("some data", committed.contents[0].data);
    }
}
test "write: incorrectly padded stream aborts at commit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{});
    defer state.deinit(alloc);
    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "SGVsbG8");
    try testing.expectError(error.Invalid, state.commit(alloc));
}
test "write: incorrectly padded stream aborts at MIME switch" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{});
    defer state.deinit(alloc);
    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "SGVsbG8");
    try testing.expectError(error.Invalid, state.data(
        alloc,
        &.{ .op = .wdata, .mime = "text/html" },
        "PGI+aGk8L2I+",
    ));
}
test "write: independently padded chunks accumulate" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{});
    defer state.deinit(alloc);
    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "Z29vZA==");
    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "bW9yZQ==");
    const committed = try state.commit(alloc);
    defer committed.deinit(alloc);
    try testing.expectEqualStrings("goodmore", committed.contents[0].data);
}
test "write: data after padding within one chunk aborts" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{});
    defer state.deinit(alloc);
    try testing.expectError(error.Invalid, state.data(
        alloc,
        &.{ .op = .wdata, .mime = "text/plain" },
        "Z29vZA==bW9yZQ==",
    ));
}
test "write: aliases resolve at commit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{});
    defer state.deinit(alloc);
    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "R2hvc3R0eQ==");
    const alias_meta: Metadata = .{ .op = .walias, .mime = "text/plain" };
    try state.alias(alloc, &alias_meta, "VEVYVCBVVEY4X1NUUklORw==");
    const committed = try state.commit(alloc);
    defer committed.deinit(alloc);
    try testing.expectEqual(@as(usize, 3), committed.contents.len);
    try testing.expectEqualStrings("TEXT", committed.contents[1].mime);
    try testing.expectEqualStrings("Wasp", committed.contents[1].data);
    try testing.expectEqualStrings("UTF8_STRING", committed.contents[2].mime);
    try testing.expectEqualStrings("Wasp", committed.contents[2].data);
}
test "write: repeated alias updates do not grow memory" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{ .max_size = 0 });
    defer state.deinit(alloc);
    const target: [max_mime_len]u8 = @splat('x');
    const alias_meta: Metadata = .{ .op = .walias, .mime = &target };
    try state.alias(alloc, &alias_meta, "YQ==");
    const capacity = state.arena.queryCapacity();
    for (0..1000) |_| try state.alias(alloc, &alias_meta, "YQ==");
    try testing.expectEqual(capacity, state.arena.queryCapacity());
    try testing.expectEqual(@as(usize, 1), state.aliases.items.len);
    try testing.expectEqualStrings(&target, state.aliases.items[0].target());
}
test "write: alias payload must be valid utf8" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{});
    defer state.deinit(alloc);
    const alias_meta: Metadata = .{ .op = .walias, .mime = "text/plain" };
    try testing.expectError(
        error.Invalid,
        state.alias(alloc, &alias_meta, "/w=="),
    );
}
test "write: default limit when unset" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{});
    defer state.deinit(alloc);
    try testing.expectEqual(@as(usize, max_write_size), state.max_size);
}
test "write: text over limit rejects transaction" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{ .max_size = 8 });
    defer state.deinit(alloc);
    try testing.expectError(error.TooLarge, state.data(
        alloc,
        &.{ .op = .wdata, .mime = "text/plain" },
        "SGVsbG9Xb3JsZA==",
    ));
}
test "write: text crossing limit across chunks rejects transaction" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{ .max_size = 8 });
    defer state.deinit(alloc);
    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "SGVsbG8=");
    try testing.expectError(error.TooLarge, state.data(
        alloc,
        &.{ .op = .wdata, .mime = "text/plain" },
        "V29ybGQ=",
    ));
}
test "write: data exactly at limit is accepted" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{ .max_size = 5 });
    defer state.deinit(alloc);
    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "SGVsbG8=");
    const committed = try state.commit(alloc);
    defer committed.deinit(alloc);
    try testing.expectEqualStrings("Hello", committed.contents[0].data);
}
test "write: non-text under limit is unaffected" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{ .max_size = 8 });
    defer state.deinit(alloc);
    try state.data(alloc, &.{ .op = .wdata, .mime = "image/png" }, "iVBORw==");
    const committed = try state.commit(alloc);
    defer committed.deinit(alloc);
    try testing.expectEqualStrings("\x89PNG", committed.contents[0].data);
}
test "write: non-text over limit rejects transaction" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{ .max_size = 8 });
    defer state.deinit(alloc);
    try testing.expectError(error.TooLarge, state.data(
        alloc,
        &.{ .op = .wdata, .mime = "image/png" },
        "SGVsbG9Xb3JsZA==",
    ));
}
test "write: total data across MIME types is limited" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{ .max_size = 8 });
    defer state.deinit(alloc);
    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "SGVsbG8=");
    try testing.expectError(error.TooLarge, state.data(
        alloc,
        &.{ .op = .wdata, .mime = "image/png" },
        "V29ybGQ=",
    ));
}
test "write: alias without data target is dropped" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{});
    defer state.deinit(alloc);
    const alias_meta: Metadata = .{ .op = .walias, .mime = "text/plain" };
    try state.alias(alloc, &alias_meta, "VEVYVA==");
    const committed = try state.commit(alloc);
    defer committed.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), committed.contents.len);
}
