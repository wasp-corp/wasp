const std = @import("std");
const Allocator = std.mem.Allocator;
const simd = @import("../../simd/root.zig");
const clipboard = @import("../clipboard.zig");
const protocol = @import("../osc/parsers/kitty_clipboard_protocol.zig");
const Operation = protocol.Operation;
pub const max_id_len = 512;
pub const max_pw_len = 128;
pub const max_mime_len = 256;
pub const max_name_len = 256;
pub const Metadata = struct {
    op: Operation,
    loc: clipboard.Location = .standard,
    id: []const u8 = "",
    mime: []const u8 = "",
    pw: []const u8 = "",
    name: []const u8 = "",
    pub fn parse(
        alloc: Allocator,
        raw: []const u8,
    ) error{ OutOfMemory, InvalidValue }!?Metadata {
        const fields = Raw.parse(raw) orelse return null;
        var result: Metadata = .{
            .op = Operation.init(fields.op orelse return null) orelse return null,
            .loc = if (std.mem.eql(u8, fields.loc, "primary"))
                .primary
            else
                .standard,
            .id = try sanitizeId(alloc, fields.id),
        };
        result.mime = decodeValue(
            alloc,
            fields.mime,
            max_mime_len,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Overflow,
            error.InvalidBase64,
            error.InvalidUtf8,
            => return error.InvalidValue,
        };
        result.pw = decodeValue(
            alloc,
            fields.pw,
            max_pw_len,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidBase64, error.InvalidUtf8 => return error.InvalidValue,
            error.Overflow => "",
        };
        result.name = decodeValue(
            alloc,
            fields.name,
            max_name_len,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Overflow,
            error.InvalidBase64,
            error.InvalidUtf8,
            => return error.InvalidValue,
        };
        return result;
    }
    pub fn operation(raw: []const u8) ?Operation {
        const fields = Raw.parse(raw) orelse return null;
        return Operation.init(fields.op orelse return null);
    }
    const Raw = struct {
        op: ?[]const u8 = null,
        loc: []const u8 = "",
        id: []const u8 = "",
        mime: []const u8 = "",
        pw: []const u8 = "",
        name: []const u8 = "",
        fn parse(raw: []const u8) ?Raw {
            var result: Raw = .{};
            var it = std.mem.splitScalar(u8, raw, ':');
            while (it.next()) |record| {
                const eql_idx = std.mem.indexOfScalar(u8, record, '=') orelse return null;
                const key = record[0..eql_idx];
                const value = record[eql_idx + 1 ..];
                if (std.mem.eql(u8, key, "type")) {
                    result.op = value;
                } else if (std.mem.eql(u8, key, "loc")) {
                    result.loc = value;
                } else if (std.mem.eql(u8, key, "id")) {
                    result.id = value;
                } else if (std.mem.eql(u8, key, "mime")) {
                    result.mime = value;
                } else if (std.mem.eql(u8, key, "pw")) {
                    result.pw = value;
                } else if (std.mem.eql(u8, key, "name")) {
                    result.name = value;
                }
            }
            return result;
        }
    };
    fn sanitizeId(alloc: Allocator, value: []const u8) Allocator.Error![]const u8 {
        var list: std.ArrayListUnmanaged(u8) = .empty;
        defer list.deinit(alloc);
        for (value) |c| {
            switch (c) {
                'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '+', '.' => {},
                else => continue,
            }
            if (list.items.len >= max_id_len) break;
            try list.append(alloc, c);
        }
        return try list.toOwnedSlice(alloc);
    }
    fn decodeValue(alloc: Allocator, value: []const u8, max_len: usize) error{
        OutOfMemory,
        Overflow,
        InvalidBase64,
        InvalidUtf8,
    }![]const u8 {
        const Encoder = std.base64.standard.Encoder;
        if (value.len > Encoder.calcSize(max_len)) return error.Overflow;
        const buf = try alloc.alloc(u8, simd.base64.maxLen(value));
        errdefer alloc.free(buf);
        const decoded = simd.base64.decodeStrict(
            value,
            buf,
            .required,
        ) catch return error.InvalidBase64;
        if (!std.unicode.utf8ValidateSlice(decoded)) return error.InvalidUtf8;
        if (decoded.len > max_len) return error.Overflow;
        return decoded;
    }
};
pub const Payload = struct {
    buf: []u8,
    data: []const u8,
    pub fn init(
        alloc: Allocator,
        payload: []const u8,
    ) error{ OutOfMemory, Invalid }!Payload {
        const buf = try alloc.alloc(u8, simd.base64.maxLen(payload));
        errdefer alloc.free(buf);
        const data = simd.base64.decodeStrict(
            payload,
            buf,
            .required,
        ) catch return error.Invalid;
        return .{ .buf = buf, .data = data };
    }
    pub fn deinit(self: *const Payload, alloc: Allocator) void {
        alloc.free(self.buf);
    }
    pub fn isValidUtf8(self: *const Payload) bool {
        return std.unicode.utf8ValidateSlice(self.data);
    }
    pub fn mimeIterator(self: *const Payload) std.mem.TokenIterator(u8, .any) {
        return std.mem.tokenizeAny(
            u8,
            self.data,
            &std.ascii.whitespace,
        );
    }
};
pub fn readPromptExempt(data_mimes: usize) bool {
    return data_mimes == 0;
}
test "metadata: empty is dropped" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try Metadata.parse(arena.allocator(), "")) == null);
}
test "metadata: record without = is dropped" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try Metadata.parse(arena.allocator(), "type=read:bare")) == null);
    try testing.expect((try Metadata.parse(arena.allocator(), "bare:type=read")) == null);
}
test "metadata: missing or unknown type is dropped" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try Metadata.parse(arena.allocator(), "loc=primary")) == null);
    try testing.expect((try Metadata.parse(arena.allocator(), "type=bobr")) == null);
    try testing.expect((try Metadata.parse(arena.allocator(), "type=")) == null);
}
test "metadata: duplicate keys keep the last occurrence" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(
        Operation.read,
        (try Metadata.parse(arena.allocator(), "type=bobr:type=read")).?.op,
    );
    try testing.expect((try Metadata.parse(arena.allocator(), "type=read:type=bobr")) == null);
}
test "metadata: basic read" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const meta = (try Metadata.parse(arena.allocator(), "type=read")).?;
    try testing.expectEqual(Operation.read, meta.op);
    try testing.expect(meta.loc == .standard);
    try testing.expectEqual(@as(usize, 0), meta.id.len);
}
test "metadata: unknown keys ignored" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const meta = (try Metadata.parse(arena.allocator(), "type=read:bobr=kurwa")).?;
    try testing.expectEqual(Operation.read, meta.op);
}
test "metadata: loc" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try Metadata.parse(arena.allocator(), "type=read:loc=primary")).?.loc == .primary);
    try testing.expect((try Metadata.parse(arena.allocator(), "type=read:loc=bobr")).?.loc == .standard);
}
test "metadata: id sanitized" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    {
        const meta = (try Metadata.parse(arena.allocator(), "type=read:id=abc-123_x.Y+z")).?;
        try testing.expectEqualStrings("abc-123_x.Y+z", meta.id);
    }
    {
        const meta = (try Metadata.parse(arena.allocator(), "type=read:id=*4 2*")).?;
        try testing.expectEqualStrings("42", meta.id);
    }
}
test "metadata: id truncated to max" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const raw = "type=read:id=" ++ "a" ** (max_id_len + 100);
    const meta = (try Metadata.parse(arena.allocator(), raw)).?;
    try testing.expectEqual(@as(usize, max_id_len), meta.id.len);
}
test "metadata: mime decoded" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const meta = (try Metadata.parse(arena.allocator(), "type=wdata:mime=dGV4dC9wbGFpbg==")).?;
    try testing.expectEqualStrings("text/plain", meta.mime);
}
test "metadata: invalid mime base64 reported" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cases = [_][]const u8{
        "type=wdata:mime=!!!",
        "type=wdata:mime=dGV4dC9wbGFpbg",
        "type=wdata:mime=dGV4dC9wbGFpbg=!",
        "type=wdata:mime=dGV4dC9w\nbGFpbg==",
    };
    for (cases) |case| {
        try testing.expectError(
            error.InvalidValue,
            Metadata.parse(arena.allocator(), case),
        );
        try testing.expectEqual(
            Operation.wdata,
            Metadata.operation(case).?,
        );
    }
}
test "metadata: invalid mime utf8 reported" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(
        error.InvalidValue,
        Metadata.parse(arena.allocator(), "type=wdata:mime=//4="),
    );
    try testing.expectEqual(
        Operation.wdata,
        Metadata.operation("type=wdata:mime=//4=").?,
    );
}
test "metadata: pw and name" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const meta = (try Metadata.parse(arena.allocator(), "type=read:pw=c2VjcmV0:name=YXBw")).?;
    try testing.expectEqualStrings("secret", meta.pw);
    try testing.expectEqualStrings("app", meta.name);
}
test "metadata: over-long name reported" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Encoder = std.base64.standard.Encoder;
    const long = "n" ** (max_name_len + 1);
    var buf: [Encoder.calcSize(long.len)]u8 = undefined;
    const raw = try std.mem.concat(arena.allocator(), u8, &.{
        "type=read:name=",
        Encoder.encode(&buf, long),
    });
    try testing.expectError(
        error.InvalidValue,
        Metadata.parse(arena.allocator(), raw),
    );
}
test "metadata: empty name" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const meta = (try Metadata.parse(arena.allocator(), "type=read:pw=c2VjcmV0:name=")).?;
    try testing.expectEqual(@as(usize, 0), meta.name.len);
}
test "read prompt exemption: only requests without data types" {
    const testing = std.testing;
    try testing.expect(readPromptExempt(0));
    try testing.expect(!readPromptExempt(1));
}
test "payload: mime iterator" {
    const testing = std.testing;
    const payload = try Payload.init(
        testing.allocator,
        "dGV4dC9wbGFpbiAgdGV4dC9odG1sCnRleHQvdXJpLWxpc3Q=",
    );
    defer payload.deinit(testing.allocator);
    var it = payload.mimeIterator();
    try testing.expectEqualStrings("text/plain", it.next().?);
    try testing.expectEqualStrings("text/html", it.next().?);
    try testing.expectEqualStrings("text/uri-list", it.next().?);
    try testing.expect(it.next() == null);
}
test "payload: invalid base64" {
    const testing = std.testing;
    const cases = [_][]const u8{
        "!!!",
        "dGV4dC9wbGFpbg",
        "dGV4dC9w\nbGFpbg==",
    };
    for (cases) |case| {
        try testing.expectError(
            error.Invalid,
            Payload.init(testing.allocator, case),
        );
    }
}
test "payload: decoded text must be valid utf8" {
    const testing = std.testing;
    const payload = try Payload.init(testing.allocator, "/w==");
    defer payload.deinit(testing.allocator);
    try testing.expect(!payload.isValidUtf8());
}
