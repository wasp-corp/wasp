const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const string = @import("string.zig");
const formatterpkg = @import("formatter.zig");
const cli = @import("../cli.zig");
pub const ReadableIO = union(enum) {
    const Self = @This();
    raw: [:0]const u8,
    path: [:0]const u8,
    pub fn parseCLI(
        self: *Self,
        alloc: Allocator,
        input_: ?[]const u8,
    ) !void {
        const input = input_ orelse return error.ValueRequired;
        if (input.len == 0) return error.ValueRequired;
        {
            const buf = try alloc.alloc(u8, input.len);
            defer alloc.free(buf);
            _ = try string.parse(buf, input);
        }
        self.* = cli.args.parseTaggedUnion(
            Self,
            alloc,
            input,
        ) catch |err| switch (err) {
            error.InvalidValue => .{ .raw = try alloc.dupeZ(u8, input) },
            else => return err,
        };
    }
    pub fn clone(self: Self, alloc: Allocator) Allocator.Error!Self {
        return switch (self) {
            .raw => |v| .{ .raw = try alloc.dupeZ(u8, v) },
            .path => |v| .{ .path = try alloc.dupeZ(u8, v) },
        };
    }
    pub fn cloneParsed(
        self: Self,
        alloc: Allocator,
    ) Allocator.Error!Self {
        switch (self) {
            inline else => |v, tag| {
                const copied = try alloc.dupeZ(u8, v);
                const parsed = string.parse(copied, v) catch unreachable;
                assert(copied.ptr == parsed.ptr);
                if (parsed.len < copied.len) copied[parsed.len] = 0;
                return @unionInit(
                    Self,
                    @tagName(tag),
                    copied[0..parsed.len :0],
                );
            },
        }
    }
    pub fn equal(self: Self, other: Self) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) {
            return false;
        }
        return switch (self) {
            .raw => |v| std.mem.eql(u8, v, other.raw),
            .path => |v| std.mem.eql(u8, v, other.path),
        };
    }
    pub fn formatEntry(self: Self, formatter: formatterpkg.EntryFormatter) !void {
        var buf: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        switch (self) {
            inline else => |v, tag| {
                writer.writeAll(@tagName(tag)) catch return error.OutOfMemory;
                writer.writeByte(':') catch return error.OutOfMemory;
                writer.writeAll(v) catch return error.OutOfMemory;
            },
        }
        try formatter.formatEntry(
            []const u8,
            writer.buffered(),
        );
    }
    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        {
            var io: Self = undefined;
            try Self.parseCLI(&io, alloc, "foo");
            try testing.expect(io == .raw);
            try testing.expectEqualStrings("foo", io.raw);
        }
        {
            var io: Self = undefined;
            try Self.parseCLI(&io, alloc, "raw:foo");
            try testing.expect(io == .raw);
            try testing.expectEqualStrings("foo", io.raw);
        }
        {
            var io: Self = undefined;
            try Self.parseCLI(&io, alloc, "path:foo");
            try testing.expect(io == .path);
            try testing.expectEqualStrings("foo", io.path);
        }
    }
    test "formatEntry" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        var v: Self = undefined;
        try v.parseCLI(alloc, "raw:foo");
        try v.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = raw:foo\n", buf.written());
    }
};
pub const RepeatableReadableIO = struct {
    const Self = @This();
    list: std.ArrayList(ReadableIO) = .empty,
    pub fn parseCLI(
        self: *Self,
        alloc: Allocator,
        input: ?[]const u8,
    ) !void {
        const value = input orelse return error.ValueRequired;
        if (value.len == 0) {
            self.list.clearRetainingCapacity();
            return;
        }
        var io: ReadableIO = undefined;
        try ReadableIO.parseCLI(&io, alloc, value);
        try self.list.append(alloc, io);
    }
    pub fn clone(self: *const Self, alloc: Allocator) Allocator.Error!Self {
        var list = try std.ArrayListUnmanaged(ReadableIO).initCapacity(
            alloc,
            self.list.items.len,
        );
        for (self.list.items) |item| {
            const copy = try item.clone(alloc);
            list.appendAssumeCapacity(copy);
        }
        return .{ .list = list };
    }
    pub fn cloneParsed(
        self: *const Self,
        alloc: Allocator,
    ) Allocator.Error!Self {
        var list = try std.ArrayListUnmanaged(ReadableIO).initCapacity(
            alloc,
            self.list.items.len,
        );
        for (self.list.items) |item| {
            const copy = try item.cloneParsed(alloc);
            list.appendAssumeCapacity(copy);
        }
        return .{ .list = list };
    }
    pub fn equal(self: Self, other: Self) bool {
        const itemsA = self.list.items;
        const itemsB = other.list.items;
        if (itemsA.len != itemsB.len) return false;
        for (itemsA, itemsB) |a, b| {
            if (!a.equal(b)) return false;
        } else return true;
    }
    pub fn formatEntry(
        self: Self,
        formatter: formatterpkg.EntryFormatter,
    ) !void {
        if (self.list.items.len == 0) {
            try formatter.formatEntry(void, {});
            return;
        }
        for (self.list.items) |value| {
            try formatter.formatEntry(ReadableIO, value);
        }
    }
    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: Self = .{};
        try list.parseCLI(alloc, "raw:A");
        try list.parseCLI(alloc, "path:B");
        try testing.expectEqual(@as(usize, 2), list.list.items.len);
        try list.parseCLI(alloc, "");
        try testing.expectEqual(@as(usize, 0), list.list.items.len);
    }
};
test {
    _ = ReadableIO;
    _ = RepeatableReadableIO;
}
