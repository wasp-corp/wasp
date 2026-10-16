const std = @import("std");
const assert = std.debug.assert;
const lib = @import("../lib.zig");
pub const ReaderFn = *const fn (
    userdata: ?*anyopaque,
    buffer: [*]u8,
    capacity: usize,
    out_read: *usize,
) callconv(lib.calling_conv) bool;
pub const WriterFn = *const fn (
    userdata: ?*anyopaque,
    data: [*]const u8,
    len: usize,
) callconv(lib.calling_conv) bool;
pub const Reader = extern struct {
    read: ?ReaderFn = null,
    userdata: ?*anyopaque = null,
    pub fn valid(self: Reader) bool {
        return self.read != null;
    }
};
pub const Writer = extern struct {
    write: ?WriterFn = null,
    userdata: ?*anyopaque = null,
    pub fn valid(self: Writer) bool {
        return self.write != null;
    }
};
pub const MimeReaderFn = *const fn (
    userdata: ?*anyopaque,
    mime: lib.String,
    writer: Writer,
) callconv(lib.calling_conv) bool;
pub const MimeReader = extern struct {
    read: ?MimeReaderFn = null,
    userdata: ?*anyopaque = null,
    pub fn valid(self: MimeReader) bool {
        return self.read != null;
    }
};
pub const ReaderAdapter = struct {
    source: Reader,
    interface: std.Io.Reader,
    offset: usize = 0,
    callback_failed: bool = false,
    invalid_read: bool = false,
    eof: bool = false,
    peek_buffer: [1]u8 = undefined,
    transfer_buffer: [4096]u8 = undefined,
    pub fn init(source: Reader) ReaderAdapter {
        return .{
            .source = source,
            .interface = .{
                .vtable = &.{
                    .stream = stream,
                    .rebase = rebase,
                },
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },
        };
    }
    pub fn reader(self: *ReaderAdapter) *std.Io.Reader {
        return &self.interface;
    }
    fn readInto(self: *ReaderAdapter, destination: []u8) std.Io.Reader.Error!usize {
        assert(destination.len > 0);
        if (self.callback_failed or self.invalid_read) return error.ReadFailed;
        if (self.eof) return error.EndOfStream;
        const read_fn = self.source.read orelse {
            self.invalid_read = true;
            return error.ReadFailed;
        };
        var read_len: usize = 0;
        if (!read_fn(
            self.source.userdata,
            destination.ptr,
            destination.len,
            &read_len,
        )) {
            self.callback_failed = true;
            return error.ReadFailed;
        }
        if (read_len > destination.len) {
            self.invalid_read = true;
            return error.ReadFailed;
        }
        if (read_len == 0) {
            self.eof = true;
            return error.EndOfStream;
        }
        self.offset = std.math.add(usize, self.offset, read_len) catch {
            self.invalid_read = true;
            return error.ReadFailed;
        };
        return read_len;
    }
    fn stream(
        reader_: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        if (limit == .nothing) return 0;
        const self: *ReaderAdapter = @alignCast(@fieldParentPtr(
            "interface",
            reader_,
        ));
        const direct = limit.slice(writer.unusedCapacitySlice());
        if (direct.len > 0) {
            const read_len = try self.readInto(direct);
            writer.advance(read_len);
            return read_len;
        }
        const transfer = limit.slice(&self.transfer_buffer);
        assert(transfer.len > 0);
        const read_len = try self.readInto(transfer);
        try writer.writeAll(transfer[0..read_len]);
        return read_len;
    }
    fn rebase(
        reader_: *std.Io.Reader,
        capacity: usize,
    ) std.Io.Reader.RebaseError!void {
        const self: *ReaderAdapter = @alignCast(@fieldParentPtr(
            "interface",
            reader_,
        ));
        if (reader_.buffer.len == 0) {
            assert(reader_.seek == 0);
            assert(reader_.end == 0);
            reader_.buffer = &self.peek_buffer;
        }
        assert(capacity <= reader_.buffer.len);
        if (reader_.buffer.len - reader_.seek >= capacity) return;
        return std.Io.Reader.defaultRebase(reader_, capacity);
    }
};
pub const WriterAdapter = struct {
    destination: Writer,
    interface: std.Io.Writer,
    offset: usize = 0,
    callback_failed: bool = false,
    invalid_write: bool = false,
    pub const recommended_buffer_len = 4096;
    pub fn init(destination: Writer) WriterAdapter {
        return initBuffered(destination, &.{});
    }
    pub fn initBuffered(destination: Writer, buffer: []u8) WriterAdapter {
        return .{
            .destination = destination,
            .interface = .{
                .vtable = &.{ .drain = drain },
                .buffer = buffer,
                .end = 0,
            },
        };
    }
    pub fn writer(self: *WriterAdapter) *std.Io.Writer {
        return &self.interface;
    }
    fn writeAll(self: *WriterAdapter, data: []const u8) std.Io.Writer.Error!void {
        if (data.len == 0) return;
        if (self.callback_failed or self.invalid_write) return error.WriteFailed;
        const write_fn = self.destination.write orelse {
            self.invalid_write = true;
            return error.WriteFailed;
        };
        if (!write_fn(self.destination.userdata, data.ptr, data.len)) {
            self.callback_failed = true;
            return error.WriteFailed;
        }
        self.offset = std.math.add(usize, self.offset, data.len) catch {
            self.invalid_write = true;
            return error.WriteFailed;
        };
    }
    fn writeSlice(
        self: *WriterAdapter,
        writer_: *std.Io.Writer,
        slice: []const u8,
    ) std.Io.Writer.Error!void {
        const buffer = writer_.buffer;
        if (slice.len <= buffer.len - writer_.end) {
            @memcpy(buffer[writer_.end..][0..slice.len], slice);
            writer_.end += slice.len;
            return;
        }
        if (writer_.end > 0) {
            try self.writeAll(buffer[0..writer_.end]);
            writer_.end = 0;
        }
        if (slice.len <= buffer.len) {
            @memcpy(buffer[0..slice.len], slice);
            writer_.end = slice.len;
        } else {
            try self.writeAll(slice);
        }
    }
    fn drain(
        writer_: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        assert(data.len > 0); 
        const self: *WriterAdapter = @alignCast(@fieldParentPtr(
            "interface",
            writer_,
        ));
        if (writer_.end > 0) {
            try self.writeAll(writer_.buffer[0..writer_.end]);
            writer_.end = 0;
        }
        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            try self.writeSlice(writer_, slice);
            consumed = std.math.add(usize, consumed, slice.len) catch {
                self.invalid_write = true;
                return error.WriteFailed;
            };
        }
        const pattern = data[data.len - 1];
        if (pattern.len == 1 and writer_.buffer.len > 0) {
            const buffer = writer_.buffer;
            var remaining = splat;
            while (remaining > 0) {
                if (writer_.end == buffer.len) {
                    try self.writeAll(buffer);
                    writer_.end = 0;
                }
                const n = @min(remaining, buffer.len - writer_.end);
                @memset(buffer[writer_.end..][0..n], pattern[0]);
                writer_.end += n;
                remaining -= n;
            }
            consumed = std.math.add(usize, consumed, splat) catch {
                self.invalid_write = true;
                return error.WriteFailed;
            };
        } else for (0..splat) |_| {
            try self.writeSlice(writer_, pattern);
            consumed = std.math.add(usize, consumed, pattern.len) catch {
                self.invalid_write = true;
                return error.WriteFailed;
            };
        }
        return consumed;
    }
};
test "C reader and writer layouts keep callback first" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Reader, "read"));
    try std.testing.expectEqual(@sizeOf(?ReaderFn), @offsetOf(Reader, "userdata"));
    try std.testing.expectEqual(@sizeOf(?ReaderFn) + @sizeOf(?*anyopaque), @sizeOf(Reader));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Writer, "write"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(MimeReader, "read"));
    try std.testing.expectEqual(@sizeOf(?MimeReaderFn), @offsetOf(MimeReader, "userdata"));
    try std.testing.expectEqual(@sizeOf(?WriterFn), @offsetOf(Writer, "userdata"));
    try std.testing.expectEqual(@sizeOf(?WriterFn) + @sizeOf(?*anyopaque), @sizeOf(Writer));
}
test "ReaderAdapter supports short reads and permanent EOF" {
    const Context = struct {
        data: []const u8,
        offset: usize = 0,
        calls: usize = 0,
        fn read(
            userdata: ?*anyopaque,
            buffer: [*]u8,
            capacity: usize,
            out_read: *usize,
        ) callconv(lib.calling_conv) bool {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.calls += 1;
            const remaining = self.data[self.offset..];
            const len = @min(remaining.len, capacity, 2);
            @memcpy(buffer[0..len], remaining[0..len]);
            self.offset += len;
            out_read.* = len;
            return true;
        }
    };
    var context: Context = .{ .data = "abcdef" };
    var adapter: ReaderAdapter = .init(.{
        .read = &Context.read,
        .userdata = &context,
    });
    var actual: [6]u8 = undefined;
    try adapter.interface.readSliceAll(&actual);
    try std.testing.expectEqualStrings("abcdef", &actual);
    try std.testing.expectEqual(@as(usize, 6), adapter.offset);
    try std.testing.expect(!adapter.eof);
    try std.testing.expectError(error.EndOfStream, adapter.interface.takeByte());
    try std.testing.expect(adapter.eof);
    try std.testing.expect(!adapter.callback_failed);
    const calls_at_eof = context.calls;
    try std.testing.expectError(error.EndOfStream, adapter.interface.takeByte());
    try std.testing.expectEqual(calls_at_eof, context.calls);
}
test "ReaderAdapter peek reads only the requested byte" {
    const Context = struct {
        data: []const u8,
        offset: usize = 0,
        last_capacity: usize = 0,
        fn read(
            userdata: ?*anyopaque,
            buffer: [*]u8,
            capacity: usize,
            out_read: *usize,
        ) callconv(lib.calling_conv) bool {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.last_capacity = capacity;
            const remaining = self.data[self.offset..];
            const len = @min(remaining.len, capacity);
            @memcpy(buffer[0..len], remaining[0..len]);
            self.offset += len;
            out_read.* = len;
            return true;
        }
    };
    var context: Context = .{ .data = "ab" };
    var adapter: ReaderAdapter = .init(.{
        .read = &Context.read,
        .userdata = &context,
    });
    try std.testing.expectEqual(@as(u8, 'a'), try adapter.interface.peekByte());
    try std.testing.expectEqual(@as(usize, 1), context.last_capacity);
    try std.testing.expectEqual(@as(usize, 1), adapter.offset);
    try std.testing.expectEqual(@as(u8, 'a'), try adapter.interface.takeByte());
    try std.testing.expectEqual(@as(usize, 1), adapter.offset);
}
test "ReaderAdapter distinguishes callback failure and invalid length" {
    const Failing = struct {
        fn read(
            _: ?*anyopaque,
            _: [*]u8,
            _: usize,
            _: *usize,
        ) callconv(lib.calling_conv) bool {
            return false;
        }
    };
    var failing: ReaderAdapter = .init(.{ .read = &Failing.read });
    try std.testing.expectError(error.ReadFailed, failing.interface.takeByte());
    try std.testing.expect(failing.callback_failed);
    try std.testing.expect(!failing.eof);
    try std.testing.expect(!failing.invalid_read);
    const Oversized = struct {
        fn read(
            _: ?*anyopaque,
            _: [*]u8,
            capacity: usize,
            out_read: *usize,
        ) callconv(lib.calling_conv) bool {
            out_read.* = capacity + 1;
            return true;
        }
    };
    var oversized: ReaderAdapter = .init(.{ .read = &Oversized.read });
    try std.testing.expectError(error.ReadFailed, oversized.interface.takeByte());
    try std.testing.expect(!oversized.callback_failed);
    try std.testing.expect(!oversized.eof);
    try std.testing.expect(oversized.invalid_read);
}
test "ReaderAdapter rejects a null callback" {
    var adapter: ReaderAdapter = .init(.{});
    try std.testing.expectError(error.ReadFailed, adapter.interface.takeByte());
    try std.testing.expect(adapter.invalid_read);
    try std.testing.expect(!adapter.callback_failed);
}
test "WriterAdapter writes vectors and splats" {
    const Context = struct {
        data: [32]u8 = undefined,
        len: usize = 0,
        fn write(
            userdata: ?*anyopaque,
            data: [*]const u8,
            len: usize,
        ) callconv(lib.calling_conv) bool {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            @memcpy(self.data[self.len..][0..len], data[0..len]);
            self.len += len;
            return true;
        }
    };
    var context: Context = .{};
    var adapter: WriterAdapter = .init(.{
        .write = &Context.write,
        .userdata = &context,
    });
    var vectors: [2][]const u8 = .{ "ab", "cd" };
    try adapter.interface.writeVecAll(&vectors);
    var repeated: [1][]const u8 = .{"!"};
    try adapter.interface.writeSplatAll(&repeated, 2);
    try std.testing.expectEqualStrings("abcd!!", context.data[0..context.len]);
    try std.testing.expectEqual(@as(usize, 6), adapter.offset);
    try std.testing.expect(!adapter.callback_failed);
}
test "WriterAdapter buffered batches small writes" {
    const Context = struct {
        data: [256]u8 = undefined,
        len: usize = 0,
        calls: usize = 0,
        fn write(
            userdata: ?*anyopaque,
            data: [*]const u8,
            len: usize,
        ) callconv(lib.calling_conv) bool {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            @memcpy(self.data[self.len..][0..len], data[0..len]);
            self.len += len;
            self.calls += 1;
            return true;
        }
    };
    var context: Context = .{};
    var buffer: [64]u8 = undefined;
    var adapter: WriterAdapter = .initBuffered(.{
        .write = &Context.write,
        .userdata = &context,
    }, &buffer);
    for (0..16) |_| try adapter.interface.writeAll("ab");
    try std.testing.expectEqual(@as(usize, 0), context.calls);
    try adapter.interface.flush();
    try std.testing.expectEqual(@as(usize, 1), context.calls);
    try std.testing.expectEqualStrings(
        "ab" ** 16,
        context.data[0..context.len],
    );
    try std.testing.expectEqual(@as(usize, 32), adapter.offset);
}
test "WriterAdapter buffered splats and large writes" {
    const Context = struct {
        data: [256]u8 = undefined,
        len: usize = 0,
        calls: usize = 0,
        fn write(
            userdata: ?*anyopaque,
            data: [*]const u8,
            len: usize,
        ) callconv(lib.calling_conv) bool {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            @memcpy(self.data[self.len..][0..len], data[0..len]);
            self.len += len;
            self.calls += 1;
            return true;
        }
    };
    var context: Context = .{};
    var buffer: [16]u8 = undefined;
    var adapter: WriterAdapter = .initBuffered(.{
        .write = &Context.write,
        .userdata = &context,
    }, &buffer);
    try adapter.interface.splatByteAll(' ', 40);
    try adapter.interface.writeAll("0123456789abcdef0"); 
    try adapter.interface.writeAll("xy");
    try adapter.interface.flush();
    try std.testing.expectEqualStrings(
        " " ** 40 ++ "0123456789abcdef0" ++ "xy",
        context.data[0..context.len],
    );
    try std.testing.expectEqual(
        @as(usize, context.len),
        adapter.offset,
    );
    try std.testing.expect(context.calls <= 6);
}
test "WriterAdapter makes callback failure sticky" {
    const Context = struct {
        calls: usize = 0,
        fn write(
            userdata: ?*anyopaque,
            _: [*]const u8,
            _: usize,
        ) callconv(lib.calling_conv) bool {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.calls += 1;
            return false;
        }
    };
    var context: Context = .{};
    var adapter: WriterAdapter = .init(.{
        .write = &Context.write,
        .userdata = &context,
    });
    try std.testing.expectError(error.WriteFailed, adapter.interface.writeAll("x"));
    try std.testing.expect(adapter.callback_failed);
    try std.testing.expectEqual(@as(usize, 0), adapter.offset);
    try std.testing.expectError(error.WriteFailed, adapter.interface.writeAll("y"));
    try std.testing.expectEqual(@as(usize, 1), context.calls);
}
test "WriterAdapter rejects a null callback" {
    var adapter: WriterAdapter = .init(.{});
    try std.testing.expectError(error.WriteFailed, adapter.interface.writeAll("x"));
    try std.testing.expect(adapter.invalid_write);
    try std.testing.expect(!adapter.callback_failed);
}
test "ReaderAdapter streams into an unbuffered WriterAdapter" {
    const ReadContext = struct {
        data: []const u8,
        offset: usize = 0,
        fn read(
            userdata: ?*anyopaque,
            buffer: [*]u8,
            capacity: usize,
            out_read: *usize,
        ) callconv(lib.calling_conv) bool {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            const remaining = self.data[self.offset..];
            const len = @min(remaining.len, capacity);
            @memcpy(buffer[0..len], remaining[0..len]);
            self.offset += len;
            out_read.* = len;
            return true;
        }
    };
    const WriteContext = struct {
        data: [8]u8 = undefined,
        len: usize = 0,
        fn write(
            userdata: ?*anyopaque,
            data: [*]const u8,
            len: usize,
        ) callconv(lib.calling_conv) bool {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            @memcpy(self.data[self.len..][0..len], data[0..len]);
            self.len += len;
            return true;
        }
    };
    var read_context: ReadContext = .{ .data = "stream" };
    var reader: ReaderAdapter = .init(.{
        .read = &ReadContext.read,
        .userdata = &read_context,
    });
    var write_context: WriteContext = .{};
    var writer: WriterAdapter = .init(.{
        .write = &WriteContext.write,
        .userdata = &write_context,
    });
    try reader.interface.streamExact(&writer.interface, "stream".len);
    try std.testing.expectEqualStrings(
        "stream",
        write_context.data[0..write_context.len],
    );
    try std.testing.expectEqual(@as(usize, "stream".len), reader.offset);
    try std.testing.expectEqual(@as(usize, "stream".len), writer.offset);
}
