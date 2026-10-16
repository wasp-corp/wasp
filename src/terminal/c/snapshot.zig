const std = @import("std");
const testing = std.testing;
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
const io_c = @import("io.zig");
const Result = @import("result.zig").Result;
const snapshot_core = @import("../snapshot/main.zig");
const apc = @import("../apc.zig");
const default_max_continuation_bytes = apc.Protocol.maxDefaultBytes();
const terminal_c = @import("terminal.zig");
pub const DecoderOption = enum(c_int) {
    max_continuation_bytes = 0,
    retain_continuation = 1,
    compress_history = 2,
    _,
};
pub const DecoderData = enum(c_int) {
    invalid = 0,
    max_continuation_bytes = 1,
    source_offset = 2,
    history_rows_primary = 3,
    history_rows_alternate = 4,
    progress_screen = 5,
    progress_rows = 6,
    progress_remaining = 7,
    retain_continuation = 8,
    compress_history = 9,
    _,
    fn OutType(comptime self: DecoderData) type {
        return switch (self) {
            .invalid => void,
            .max_continuation_bytes, .source_offset => usize,
            .history_rows_primary, .history_rows_alternate => u64,
            .progress_screen => terminal_c.TerminalScreen,
            .progress_rows => usize,
            .progress_remaining => u32,
            .retain_continuation, .compress_history => bool,
            _ => void,
        };
    }
};
const DecoderWrapper = struct {
    const Source = union(enum) {
        callback: io_c.ReaderAdapter,
        buffer: std.Io.Reader,
        fn reader(self: *Source) *std.Io.Reader {
            return switch (self.*) {
                .callback => |*value| &value.interface,
                .buffer => |*value| value,
            };
        }
        fn offset(self: *const Source) usize {
            return switch (self.*) {
                .callback => |*value| value.offset,
                .buffer => |*value| value.seek,
            };
        }
    };
    const Metadata = struct {
        history_rows: std.EnumMap(terminal_c.TerminalScreen, u64),
    };
    const State = union(enum) {
        configuring,
        history: struct {
            terminal: terminal_c.Terminal,
            metadata: Metadata,
            progress: ?snapshot_core.Decoder.Progress = null,
        },
        finished: Metadata,
        failed: ?Metadata,
    };
    alloc: std.mem.Allocator,
    source: Source,
    decoder: snapshot_core.Decoder,
    state: State,
    max_continuation_bytes: usize,
    retain_continuation: bool,
    compress_history: bool,
};
pub const Decoder = ?*DecoderWrapper;
pub fn decoder_new(
    alloc_: ?*const CAllocator,
    out_: ?*Decoder,
    reader: io_c.Reader,
) callconv(lib.calling_conv) Result {
    const out = out_ orelse return .invalid_value;
    out.* = null;
    if (reader.read == null) return .invalid_value;
    return decoderNewSource(alloc_, out, .{
        .callback = io_c.ReaderAdapter.init(reader),
    });
}
pub fn decoder_new_buf(
    alloc_: ?*const CAllocator,
    out_: ?*Decoder,
    ptr: ?[*]const u8,
    len: usize,
) callconv(lib.calling_conv) Result {
    const out = out_ orelse return .invalid_value;
    out.* = null;
    const bytes: []const u8 = if (ptr) |value|
        value[0..len]
    else if (len == 0)
        &.{}
    else
        return .invalid_value;
    return decoderNewSource(alloc_, out, .{
        .buffer = .fixed(bytes),
    });
}
fn decoderNewSource(
    alloc_: ?*const CAllocator,
    out: *Decoder,
    source: DecoderWrapper.Source,
) Result {
    const alloc = lib.alloc.default(alloc_);
    const wrapper = alloc.create(DecoderWrapper) catch return .out_of_memory;
    errdefer alloc.destroy(wrapper);
    wrapper.* = undefined;
    wrapper.alloc = alloc;
    wrapper.source = source;
    wrapper.state = .configuring;
    wrapper.max_continuation_bytes = default_max_continuation_bytes;
    wrapper.retain_continuation = false;
    wrapper.compress_history = false;
    wrapper.decoder = .init(wrapper.source.reader());
    out.* = wrapper;
    return .success;
}
pub fn decoder_free(decoder_: Decoder) callconv(lib.calling_conv) void {
    const decoder = decoder_ orelse return;
    const alloc = decoder.alloc;
    alloc.destroy(decoder);
}
pub fn decoder_set(
    decoder_: Decoder,
    option: DecoderOption,
    value_: ?*const anyopaque,
) callconv(lib.calling_conv) Result {
    const decoder = decoder_ orelse return .invalid_value;
    switch (decoder.state) {
        .configuring => {},
        else => return .invalid_value,
    }
    const value = value_ orelse return .invalid_value;
    switch (option) {
        .max_continuation_bytes => decoder.max_continuation_bytes =
            @as(*const usize, @ptrCast(@alignCast(value))).*,
        .retain_continuation => decoder.retain_continuation =
            @as(*const bool, @ptrCast(@alignCast(value))).*,
        .compress_history => decoder.compress_history =
            @as(*const bool, @ptrCast(@alignCast(value))).*,
        _ => return .invalid_value,
    }
    return .success;
}
pub fn decoder_get(
    decoder_: Decoder,
    data: DecoderData,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    return switch (data) {
        inline .invalid,
        .max_continuation_bytes,
        .source_offset,
        .history_rows_primary,
        .history_rows_alternate,
        .progress_screen,
        .progress_rows,
        .progress_remaining,
        .retain_continuation,
        .compress_history,
        => |comptime_data| decoderGetTyped(
            decoder_,
            comptime_data,
            @ptrCast(@alignCast(out)),
        ),
        _ => .invalid_value,
    };
}
fn decoderGetTyped(
    decoder_: Decoder,
    comptime data: DecoderData,
    out: *data.OutType(),
) Result {
    const decoder = decoder_ orelse return .invalid_value;
    switch (data) {
        .invalid => return .invalid_value,
        .max_continuation_bytes => {
            if (decoderFailed(decoder)) return .no_value;
            out.* = decoder.max_continuation_bytes;
        },
        .source_offset => {
            if (decoderFailed(decoder)) return .no_value;
            out.* = decoder.source.offset();
        },
        .retain_continuation => {
            if (decoderFailed(decoder)) return .no_value;
            out.* = decoder.retain_continuation;
        },
        .compress_history => {
            if (decoderFailed(decoder)) return .no_value;
            out.* = decoder.compress_history;
        },
        .history_rows_primary => {
            const metadata = decoderMetadata(decoder) orelse return .no_value;
            out.* = metadata.history_rows.get(.primary) orelse return .no_value;
        },
        .history_rows_alternate => {
            const metadata = decoderMetadata(decoder) orelse return .no_value;
            out.* = metadata.history_rows.get(.alternate) orelse
                return .no_value;
        },
        .progress_screen => {
            const progress = decoderProgress(decoder) orelse return .no_value;
            out.* = progress.key;
        },
        .progress_rows => {
            const progress = decoderProgress(decoder) orelse return .no_value;
            out.* = progress.rows;
        },
        .progress_remaining => {
            const progress = decoderProgress(decoder) orelse return .no_value;
            out.* = progress.remaining;
        },
        else => return .invalid_value,
    }
    return .success;
}
fn decoderFailed(decoder: *const DecoderWrapper) bool {
    return switch (decoder.state) {
        .failed => true,
        else => false,
    };
}
fn decoderMetadata(
    decoder: *const DecoderWrapper,
) ?DecoderWrapper.Metadata {
    return switch (decoder.state) {
        .history => |value| value.metadata,
        .finished => |value| value,
        .failed => |value| value,
        .configuring => null,
    };
}
fn decoderProgress(
    decoder: *const DecoderWrapper,
) ?snapshot_core.Decoder.Progress {
    return switch (decoder.state) {
        .history => |value| value.progress,
        else => null,
    };
}
pub fn decoder_get_multi(
    decoder_: Decoder,
    count: usize,
    keys_: ?[*]const DecoderData,
    values_: ?[*]?*anyopaque,
    out_written: ?*usize,
) callconv(lib.calling_conv) Result {
    if (out_written) |written| written.* = 0;
    const keys = keys_ orelse return .invalid_value;
    const values = values_ orelse return .invalid_value;
    for (0..count) |i| {
        const result = decoder_get(decoder_, keys[i], values[i]);
        if (result != .success) {
            if (out_written) |written| written.* = i;
            return result;
        }
    }
    if (out_written) |written| written.* = count;
    return .success;
}
pub fn decoder_ready(
    decoder_: Decoder,
    out_: ?*terminal_c.Terminal,
) callconv(lib.calling_conv) Result {
    const out = out_ orelse return .invalid_value;
    out.* = null;
    const decoder = decoder_ orelse return .invalid_value;
    switch (decoder.state) {
        .configuring => {},
        else => return .invalid_value,
    }
    const ready = decoderReadyTerminal(decoder) catch |err| {
        decoder.state = .{ .failed = null };
        return decoderMapError(decoder, err);
    };
    decoder.state = .{ .history = .{
        .terminal = ready.terminal,
        .metadata = ready.metadata,
    } };
    out.* = ready.terminal;
    return .success;
}
pub fn decoder_next(
    decoder_: Decoder,
) callconv(lib.calling_conv) Result {
    const decoder = decoder_ orelse return .invalid_value;
    switch (decoder.state) {
        .finished => return .no_value,
        .history => {},
        else => return .invalid_value,
    }
    const history = &decoder.state.history;
    const terminal = history.terminal orelse return .invalid_value;
    const native = terminal_c.zigTerminal(terminal).?;
    history.progress = null;
    const progress = decoder.decoder.next(decoder.alloc, native) catch |err| {
        const metadata = history.metadata;
        decoder.state = .{ .failed = metadata };
        return decoderMapError(decoder, err);
    };
    if (progress) |value| {
        history.progress = value;
        return .success;
    }
    const metadata = history.metadata;
    decoder.state = .{ .finished = metadata };
    return .no_value;
}
pub fn decoder_decode(
    decoder_: Decoder,
    out_: ?*terminal_c.Terminal,
) callconv(lib.calling_conv) Result {
    const out = out_ orelse return .invalid_value;
    out.* = null;
    const decoder = decoder_ orelse return .invalid_value;
    switch (decoder.state) {
        .configuring => {},
        else => return .invalid_value,
    }
    const ready = decoderReadyTerminal(decoder) catch |err| {
        decoder.state = .{ .failed = null };
        return decoderMapError(decoder, err);
    };
    const native = terminal_c.zigTerminal(ready.terminal).?;
    while (true) {
        const progress = decoder.decoder.next(decoder.alloc, native) catch |err| {
            terminal_c.free(ready.terminal);
            decoder.state = .{ .failed = ready.metadata };
            return decoderMapError(decoder, err);
        };
        if (progress == null) break;
    }
    decoder.state = .{ .finished = ready.metadata };
    out.* = ready.terminal;
    return .success;
}
const ReadyTerminal = struct {
    terminal: terminal_c.Terminal,
    metadata: DecoderWrapper.Metadata,
};
fn decoderReadyTerminal(decoder: *DecoderWrapper) anyerror!ReadyTerminal {
    const io: terminal_c.Io = .init;
    var decoded = try decoder.decoder.ready(
        decoder.alloc,
        io.io(),
        .{
            .max_continuation_bytes = decoder.max_continuation_bytes,
            .compress_history = decoder.compress_history,
        },
    );
    defer decoded.deinit(decoder.alloc);
    const metadata: DecoderWrapper.Metadata = .{
        .history_rows = decoded.history_rows,
    };
    const terminal = try terminal_c.fromDecoded(
        decoder.alloc,
        io,
        &decoded,
        if (decoder.retain_continuation)
            decoder.max_continuation_bytes
        else
            0,
    );
    return .{ .terminal = terminal, .metadata = metadata };
}
fn decoderMapError(decoder: *DecoderWrapper, err: anyerror) Result {
    switch (decoder.source) {
        .callback => |adapter| {
            if (adapter.invalid_read) return .invalid_value;
            if (adapter.callback_failed) return .io_error;
        },
        .buffer => {},
    }
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.ContinuationLimitExceeded => .limit_exceeded,
        error.ContinuationDisabled,
        error.ContinuationUnavailable,
        error.DecoderNotReady,
        error.DecoderFailed,
        => .invalid_value,
        error.InvalidContinuation => .invalid_value,
        else => .invalid_value,
    };
}
fn continuationOwned(terminal: terminal_c.Terminal) struct {
    result: Result,
    bytes: []u8,
} {
    const native = terminal_c.zigTerminal(terminal) orelse return .{
        .result = .invalid_value,
        .bytes = &.{},
    };
    const alloc = native.gpa();
    const bytes = terminal_c.continuationAllocIo(
        terminal,
        alloc,
        true,
    ) catch |err| {
        return .{
            .result = switch (err) {
                error.InvalidValue => .invalid_value,
                error.OutOfMemory => .out_of_memory,
                error.ContinuationDisabled,
                error.ContinuationUnavailable,
                => .invalid_value,
            },
            .bytes = &.{},
        };
    };
    return .{ .result = .success, .bytes = bytes };
}
fn continuationValue(bytes: []const u8) snapshot_core.Continuation {
    return if (bytes.len == 0) .ground else .{ .bytes = bytes };
}
pub fn encode(
    terminal: terminal_c.Terminal,
    writer: io_c.Writer,
) callconv(lib.calling_conv) Result {
    const native = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    if (writer.write == null) return .invalid_value;
    const continuation = continuationOwned(terminal);
    if (continuation.result != .success) return continuation.result;
    defer native.gpa().free(continuation.bytes);
    var buffer: [io_c.WriterAdapter.recommended_buffer_len]u8 = undefined;
    var adapter: io_c.WriterAdapter = .initBuffered(writer, &buffer);
    snapshot_core.encode(
        native.gpa(),
        &adapter.interface,
        native,
        .{ .continuation = continuationValue(continuation.bytes) },
    ) catch |err| return mapEncodeError(err, &adapter);
    adapter.interface.flush() catch
        return mapEncodeError(error.WriteFailed, &adapter);
    return .success;
}
pub fn encode_buf(
    terminal: terminal_c.Terminal,
    buf: ?[*]u8,
    buf_len: usize,
    out_written_: ?*usize,
) callconv(lib.calling_conv) Result {
    const out_written = out_written_ orelse return .invalid_value;
    out_written.* = 0;
    if (buf == null and buf_len != 0) return .invalid_value;
    const native = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const continuation = continuationOwned(terminal);
    if (continuation.result != .success) return continuation.result;
    defer native.gpa().free(continuation.bytes);
    const destination: []u8 = if (buf) |ptr| ptr[0..buf_len] else &.{};
    var writer: std.Io.Writer = .fixed(destination);
    snapshot_core.encode(
        native.gpa(),
        &writer,
        native,
        .{ .continuation = continuationValue(continuation.bytes) },
    ) catch |err| switch (err) {
        error.WriteFailed => {
            var counter: std.Io.Writer.Discarding = .init(&.{});
            snapshot_core.encode(
                native.gpa(),
                &counter.writer,
                native,
                .{ .continuation = continuationValue(continuation.bytes) },
            ) catch |count_err| return mapEncodeError(count_err, null);
            out_written.* = std.math.cast(usize, counter.count) orelse
                return .limit_exceeded;
            return .out_of_space;
        },
        else => return mapEncodeError(err, null),
    };
    out_written.* = writer.end;
    return .success;
}
pub fn encode_alloc(
    terminal: terminal_c.Terminal,
    alloc_: ?*const CAllocator,
    out_ptr_: ?*?[*]u8,
    out_len_: ?*usize,
) callconv(lib.calling_conv) Result {
    const out_ptr = out_ptr_ orelse return .invalid_value;
    const out_len = out_len_ orelse return .invalid_value;
    out_ptr.* = null;
    out_len.* = 0;
    const native = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const continuation = continuationOwned(terminal);
    if (continuation.result != .success) return continuation.result;
    defer native.gpa().free(continuation.bytes);
    const alloc = lib.alloc.default(alloc_);
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    snapshot_core.encode(
        native.gpa(),
        &writer.writer,
        native,
        .{ .continuation = continuationValue(continuation.bytes) },
    ) catch |err| return mapEncodeError(err, null);
    const bytes = writer.toOwnedSlice() catch return .out_of_memory;
    out_ptr.* = bytes.ptr;
    out_len.* = bytes.len;
    return .success;
}
fn mapEncodeError(
    err: anyerror,
    adapter: ?*const io_c.WriterAdapter,
) Result {
    if (adapter) |value| {
        if (value.invalid_write) return .limit_exceeded;
        if (value.callback_failed) return .io_error;
    }
    return switch (err) {
        error.OutOfMemory, error.WriteFailed => .out_of_memory,
        error.Overflow,
        error.PayloadTooLarge,
        error.PageCountOverflow,
        error.ScrollbackLimitOverflow,
        error.StringTooLong,
        => .limit_exceeded,
        else => .invalid_value,
    };
}
fn testEnableContinuation(terminal: terminal_c.Terminal) !void {
    const limit: usize = default_max_continuation_bytes;
    try testing.expectEqual(Result.success, terminal_c.set(
        terminal,
        .continuation_max_bytes,
        &limit,
    ));
}
test "decoder option and empty source" {
    var decoder: Decoder = null;
    try testing.expectEqual(Result.success, decoder_new_buf(
        &lib.alloc.test_allocator,
        &decoder,
        null,
        0,
    ));
    defer decoder_free(decoder);
    var limit: usize = 0;
    try testing.expectEqual(Result.success, decoder_get(
        decoder,
        .max_continuation_bytes,
        &limit,
    ));
    try testing.expectEqual(default_max_continuation_bytes, limit);
    limit = 1234;
    try testing.expectEqual(Result.success, decoder_set(
        decoder,
        .max_continuation_bytes,
        &limit,
    ));
    limit = 0;
    try testing.expectEqual(Result.success, decoder_get(
        decoder,
        .max_continuation_bytes,
        &limit,
    ));
    try testing.expectEqual(1234, limit);
    var retain = true;
    try testing.expectEqual(Result.success, decoder_get(
        decoder,
        .retain_continuation,
        &retain,
    ));
    try testing.expect(!retain);
    retain = true;
    try testing.expectEqual(Result.success, decoder_set(
        decoder,
        .retain_continuation,
        &retain,
    ));
    retain = false;
    try testing.expectEqual(Result.success, decoder_get(
        decoder,
        .retain_continuation,
        &retain,
    ));
    try testing.expect(retain);
    var compress = true;
    try testing.expectEqual(Result.success, decoder_get(
        decoder,
        .compress_history,
        &compress,
    ));
    try testing.expect(!compress);
    compress = true;
    try testing.expectEqual(Result.success, decoder_set(
        decoder,
        .compress_history,
        &compress,
    ));
    compress = false;
    try testing.expectEqual(Result.success, decoder_get(
        decoder,
        .compress_history,
        &compress,
    ));
    try testing.expect(compress);
    var written: usize = 99;
    try testing.expectEqual(Result.invalid_value, decoder_get_multi(
        decoder,
        1,
        null,
        null,
        &written,
    ));
    try testing.expectEqual(@as(usize, 0), written);
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.invalid_value, decoder_decode(
        decoder,
        &terminal,
    ));
    try testing.expectEqual(null, terminal);
}
test "snapshot C API full round trip restores continuation" {
    var source: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &source,
        20,
        4,
    ));
    defer terminal_c.free(source);
    try testEnableContinuation(source);
    terminal_c.vt_write(source, "hello\x1b[31", "hello\x1b[31".len);
    var encoded_ptr: ?[*]u8 = null;
    var encoded_len: usize = 0;
    try testing.expectEqual(Result.success, encode_alloc(
        source,
        &lib.alloc.test_allocator,
        &encoded_ptr,
        &encoded_len,
    ));
    const encoded = encoded_ptr.?[0..encoded_len];
    defer lib.alloc.default(&lib.alloc.test_allocator).free(encoded);
    var decoder: Decoder = null;
    try testing.expectEqual(Result.success, decoder_new_buf(
        &lib.alloc.test_allocator,
        &decoder,
        encoded.ptr,
        encoded.len,
    ));
    defer decoder_free(decoder);
    var restored: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, decoder_decode(decoder, &restored));
    defer terminal_c.free(restored);
    const source_text = try terminal_c.zigTerminal(source).?.plainString(testing.allocator);
    defer testing.allocator.free(source_text);
    const restored_text = try terminal_c.zigTerminal(restored).?.plainString(testing.allocator);
    defer testing.allocator.free(restored_text);
    try testing.expectEqualStrings(source_text, restored_text);
    var restored_limit: usize = std.math.maxInt(usize);
    try testing.expectEqual(Result.success, terminal_c.get(
        restored,
        .continuation_max_bytes,
        &restored_limit,
    ));
    try testing.expectEqual(@as(usize, 0), restored_limit);
    var restored_required: usize = 0;
    try testing.expectEqual(Result.invalid_value, encode_buf(
        restored,
        null,
        0,
        &restored_required,
    ));
    terminal_c.vt_write(restored, "m", 1);
    try testing.expectEqual(Result.out_of_space, encode_buf(
        restored,
        null,
        0,
        &restored_required,
    ));
    try testing.expect(restored_required > 0);
    var offset: usize = 0;
    try testing.expectEqual(Result.success, decoder_get(
        decoder,
        .source_offset,
        &offset,
    ));
    try testing.expectEqual(encoded.len, offset);
    try testing.expectEqual(Result.no_value, decoder_next(decoder));
    var retained_decoder: Decoder = null;
    try testing.expectEqual(Result.success, decoder_new_buf(
        &lib.alloc.test_allocator,
        &retained_decoder,
        encoded.ptr,
        encoded.len,
    ));
    defer if (retained_decoder != null) decoder_free(retained_decoder);
    const retained_limit: usize = 1024;
    try testing.expectEqual(Result.success, decoder_set(
        retained_decoder,
        .max_continuation_bytes,
        &retained_limit,
    ));
    const retain = true;
    try testing.expectEqual(Result.success, decoder_set(
        retained_decoder,
        .retain_continuation,
        &retain,
    ));
    var retained: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, decoder_decode(
        retained_decoder,
        &retained,
    ));
    decoder_free(retained_decoder);
    retained_decoder = null;
    defer terminal_c.free(retained);
    var retained_terminal_limit: usize = 0;
    try testing.expectEqual(Result.success, terminal_c.get(
        retained,
        .continuation_max_bytes,
        &retained_terminal_limit,
    ));
    try testing.expectEqual(retained_limit, retained_terminal_limit);
    var continuation_buf: [16]u8 = undefined;
    var continuation_len: usize = 0;
    try testing.expectEqual(Result.success, terminal_c.continuation_buf(
        retained,
        &continuation_buf,
        continuation_buf.len,
        &continuation_len,
    ));
    try testing.expectEqualStrings(
        "\x1b[31",
        continuation_buf[0..continuation_len],
    );
    const disabled: usize = 0;
    try testing.expectEqual(Result.success, terminal_c.set(
        retained,
        .continuation_max_bytes,
        &disabled,
    ));
    try testing.expectEqual(Result.invalid_value, terminal_c.continuation_buf(
        retained,
        &continuation_buf,
        continuation_buf.len,
        &continuation_len,
    ));
    terminal_c.vt_write(retained, "m", 1);
    var retained_ground = false;
    try testing.expectEqual(Result.success, terminal_c.get(
        retained,
        .vt_ground,
        &retained_ground,
    ));
    try testing.expect(retained_ground);
    var limited: Decoder = null;
    try testing.expectEqual(Result.success, decoder_new_buf(
        &lib.alloc.test_allocator,
        &limited,
        encoded.ptr,
        encoded.len,
    ));
    defer decoder_free(limited);
    const limit: usize = 3;
    try testing.expectEqual(Result.success, decoder_set(
        limited,
        .max_continuation_bytes,
        &limit,
    ));
    var rejected: terminal_c.Terminal = null;
    try testing.expectEqual(Result.limit_exceeded, decoder_decode(
        limited,
        &rejected,
    ));
    try testing.expectEqual(null, rejected);
    try testing.expectEqual(Result.invalid_value, decoder_set(
        limited,
        .max_continuation_bytes,
        &limit,
    ));
    var failed_offset: usize = 0;
    try testing.expectEqual(Result.no_value, decoder_get(
        limited,
        .source_offset,
        &failed_offset,
    ));
    try testing.expectEqual(Result.success, terminal_c.set(
        source,
        .continuation_max_bytes,
        &disabled,
    ));
    var required: usize = 0;
    try testing.expectEqual(Result.invalid_value, encode_buf(
        source,
        null,
        0,
        &required,
    ));
}
test "snapshot decoder retains every supported continuation class" {
    const cases = [_]struct {
        name: []const u8,
        prefix: []const u8,
        suffix: []const u8,
    }{
        .{ .name = "ground", .prefix = "", .suffix = "X" },
        .{ .name = "CSI", .prefix = "\x1b[31", .suffix = "mX" },
        .{ .name = "OSC", .prefix = "\x1b]2;title", .suffix = "\x07" },
        .{ .name = "DCS", .prefix = "\x1bP$qm", .suffix = "\x1b\\" },
        .{ .name = "APC", .prefix = "\x1b_Ga=q;payload", .suffix = "\x1b\\" },
        .{ .name = "UTF-8", .prefix = "\xF0\x9F", .suffix = "\x98\x84" },
    };
    const limit: usize = 4096;
    const disabled: usize = 0;
    const retain = true;
    for (cases) |case| {
        errdefer std.log.err("retained continuation case failed: {s}", .{case.name});
        var source: terminal_c.Terminal = null;
        try testing.expectEqual(Result.success, terminal_c.new(
            &lib.alloc.test_allocator,
            &source,
            20,
            4,
        ));
        defer terminal_c.free(source);
        try testing.expectEqual(Result.success, terminal_c.set(
            source,
            .continuation_max_bytes,
            &limit,
        ));
        terminal_c.vt_write(source, case.prefix.ptr, case.prefix.len);
        var snapshot_ptr: ?[*]u8 = null;
        var snapshot_len: usize = 0;
        try testing.expectEqual(Result.success, encode_alloc(
            source,
            &lib.alloc.test_allocator,
            &snapshot_ptr,
            &snapshot_len,
        ));
        const snapshot = snapshot_ptr.?[0..snapshot_len];
        defer lib.alloc.default(&lib.alloc.test_allocator).free(snapshot);
        var decoder: Decoder = null;
        try testing.expectEqual(Result.success, decoder_new_buf(
            &lib.alloc.test_allocator,
            &decoder,
            snapshot.ptr,
            snapshot.len,
        ));
        defer if (decoder != null) decoder_free(decoder);
        try testing.expectEqual(Result.success, decoder_set(
            decoder,
            .max_continuation_bytes,
            &limit,
        ));
        try testing.expectEqual(Result.success, decoder_set(
            decoder,
            .retain_continuation,
            &retain,
        ));
        var restored: terminal_c.Terminal = null;
        try testing.expectEqual(Result.success, decoder_decode(
            decoder,
            &restored,
        ));
        defer terminal_c.free(restored);
        decoder_free(decoder);
        decoder = null;
        var restored_limit: usize = 0;
        try testing.expectEqual(Result.success, terminal_c.get(
            restored,
            .continuation_max_bytes,
            &restored_limit,
        ));
        try testing.expectEqual(limit, restored_limit);
        var continuation: [4096]u8 = undefined;
        var continuation_len: usize = 0;
        try testing.expectEqual(Result.success, terminal_c.continuation_buf(
            restored,
            &continuation,
            continuation.len,
            &continuation_len,
        ));
        try testing.expectEqualStrings(
            case.prefix,
            continuation[0..continuation_len],
        );
        try testing.expectEqual(Result.success, terminal_c.set(
            restored,
            .continuation_max_bytes,
            &disabled,
        ));
        try testing.expectEqual(Result.invalid_value, terminal_c.continuation_buf(
            restored,
            &continuation,
            continuation.len,
            &continuation_len,
        ));
        terminal_c.vt_write(source, case.suffix.ptr, case.suffix.len);
        terminal_c.vt_write(restored, case.suffix.ptr, case.suffix.len);
        var source_ground = false;
        var restored_ground = false;
        try testing.expectEqual(Result.success, terminal_c.get(
            source,
            .vt_ground,
            &source_ground,
        ));
        try testing.expectEqual(Result.success, terminal_c.get(
            restored,
            .vt_ground,
            &restored_ground,
        ));
        try testing.expect(source_ground);
        try testing.expect(restored_ground);
        var source_final_ptr: ?[*]u8 = null;
        var source_final_len: usize = 0;
        try testing.expectEqual(Result.success, encode_alloc(
            source,
            &lib.alloc.test_allocator,
            &source_final_ptr,
            &source_final_len,
        ));
        const source_final = source_final_ptr.?[0..source_final_len];
        defer lib.alloc.default(&lib.alloc.test_allocator).free(source_final);
        var restored_final_ptr: ?[*]u8 = null;
        var restored_final_len: usize = 0;
        try testing.expectEqual(Result.success, encode_alloc(
            restored,
            &lib.alloc.test_allocator,
            &restored_final_ptr,
            &restored_final_len,
        ));
        const restored_final = restored_final_ptr.?[0..restored_final_len];
        defer lib.alloc.default(&lib.alloc.test_allocator).free(restored_final);
        try testing.expectEqualSlices(u8, source_final, restored_final);
    }
}
test "snapshot encoding accepts an untracked ground terminal" {
    var source: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &source,
        10,
        3,
    ));
    defer terminal_c.free(source);
    var limit: usize = std.math.maxInt(usize);
    try testing.expectEqual(Result.success, terminal_c.get(
        source,
        .continuation_max_bytes,
        &limit,
    ));
    try testing.expectEqual(@as(usize, 0), limit);
    terminal_c.vt_write(source, "ground", "ground".len);
    var required: usize = 0;
    try testing.expectEqual(Result.out_of_space, encode_buf(
        source,
        null,
        0,
        &required,
    ));
    try testing.expect(required > 0);
    terminal_c.vt_write(source, "\x1b[31", "\x1b[31".len);
    try testing.expectEqual(Result.invalid_value, encode_buf(
        source,
        null,
        0,
        &required,
    ));
}
test "snapshot callbacks stop at FINISH and map I/O failures" {
    var source: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &source,
        10,
        3,
    ));
    defer terminal_c.free(source);
    try testEnableContinuation(source);
    terminal_c.vt_write(source, "callback", "callback".len);
    var required: usize = 0;
    try testing.expectEqual(Result.out_of_space, encode_buf(
        source,
        null,
        0,
        &required,
    ));
    const buffer_encoded = try testing.allocator.alloc(u8, required);
    defer testing.allocator.free(buffer_encoded);
    var buffer_written: usize = 0;
    try testing.expectEqual(Result.success, encode_buf(
        source,
        buffer_encoded.ptr,
        buffer_encoded.len,
        &buffer_written,
    ));
    try testing.expectEqual(required, buffer_written);
    var short: [10]u8 = @splat(0xAA);
    var short_required: usize = 0;
    try testing.expectEqual(Result.out_of_space, encode_buf(
        source,
        &short,
        short.len,
        &short_required,
    ));
    try testing.expectEqual(required, short_required);
    try testing.expectEqualStrings("GHOSTSNP", short[0..8]);
    const encoded = try testing.allocator.alloc(u8, required);
    defer testing.allocator.free(encoded);
    const WriteContext = struct {
        destination: []u8,
        offset: usize = 0,
        fn write(
            userdata: ?*anyopaque,
            data: [*]const u8,
            len: usize,
        ) callconv(lib.calling_conv) bool {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            if (len > self.destination.len - self.offset) return false;
            @memcpy(self.destination[self.offset..][0..len], data[0..len]);
            self.offset += len;
            return true;
        }
    };
    var write_context: WriteContext = .{ .destination = encoded };
    try testing.expectEqual(Result.success, encode(source, .{
        .write = &WriteContext.write,
        .userdata = &write_context,
    }));
    try testing.expectEqual(required, write_context.offset);
    try testing.expectEqualSlices(u8, buffer_encoded, encoded);
    var failing = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });
    const failing_zig = failing.allocator();
    const failing_c: CAllocator = .fromZig(&failing_zig);
    var failed_ptr: ?[*]u8 = null;
    var failed_len: usize = 99;
    try testing.expectEqual(Result.out_of_memory, encode_alloc(
        source,
        &failing_c,
        &failed_ptr,
        &failed_len,
    ));
    try testing.expectEqual(null, failed_ptr);
    try testing.expectEqual(@as(usize, 0), failed_len);
    const FailWriter = struct {
        fn write(_: ?*anyopaque, _: [*]const u8, _: usize) callconv(lib.calling_conv) bool {
            return false;
        }
    };
    try testing.expectEqual(Result.io_error, encode(source, .{
        .write = &FailWriter.write,
    }));
    const combined = try testing.allocator.alloc(u8, encoded.len + 4);
    defer testing.allocator.free(combined);
    @memcpy(combined[0..encoded.len], encoded);
    @memcpy(combined[encoded.len..], "tail");
    const ReadContext = struct {
        source: []const u8,
        offset: usize = 0,
        fn read(
            userdata: ?*anyopaque,
            destination: [*]u8,
            capacity: usize,
            out_read: *usize,
        ) callconv(lib.calling_conv) bool {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            const remaining = self.source[self.offset..];
            const len = @min(remaining.len, capacity, 3);
            @memcpy(destination[0..len], remaining[0..len]);
            self.offset += len;
            out_read.* = len;
            return true;
        }
    };
    var read_context: ReadContext = .{ .source = combined };
    var decoder: Decoder = null;
    try testing.expectEqual(Result.success, decoder_new(
        &lib.alloc.test_allocator,
        &decoder,
        .{ .read = &ReadContext.read, .userdata = &read_context },
    ));
    defer decoder_free(decoder);
    var restored: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, decoder_decode(decoder, &restored));
    defer terminal_c.free(restored);
    try testing.expectEqual(encoded.len, read_context.offset);
    try testing.expectEqualStrings("tail", read_context.source[read_context.offset..]);
    const FailReader = struct {
        fn read(
            _: ?*anyopaque,
            _: [*]u8,
            _: usize,
            _: *usize,
        ) callconv(lib.calling_conv) bool {
            return false;
        }
    };
    var failed_decoder: Decoder = null;
    try testing.expectEqual(Result.success, decoder_new(
        &lib.alloc.test_allocator,
        &failed_decoder,
        .{ .read = &FailReader.read },
    ));
    defer decoder_free(failed_decoder);
    var failed_terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.io_error, decoder_decode(
        failed_decoder,
        &failed_terminal,
    ));
    const EofReader = struct {
        fn read(
            _: ?*anyopaque,
            _: [*]u8,
            _: usize,
            out_read: *usize,
        ) callconv(lib.calling_conv) bool {
            out_read.* = 0;
            return true;
        }
    };
    var eof_decoder: Decoder = null;
    try testing.expectEqual(Result.success, decoder_new(
        &lib.alloc.test_allocator,
        &eof_decoder,
        .{ .read = &EofReader.read },
    ));
    defer decoder_free(eof_decoder);
    try testing.expectEqual(Result.invalid_value, decoder_decode(
        eof_decoder,
        &failed_terminal,
    ));
    const InvalidReader = struct {
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
    var invalid_decoder: Decoder = null;
    try testing.expectEqual(Result.success, decoder_new(
        &lib.alloc.test_allocator,
        &invalid_decoder,
        .{ .read = &InvalidReader.read },
    ));
    defer decoder_free(invalid_decoder);
    try testing.expectEqual(Result.invalid_value, decoder_decode(
        invalid_decoder,
        &failed_terminal,
    ));
}
test "snapshot decoder compresses history when requested" {
    var source: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &source,
        215,
        2,
    ));
    defer terminal_c.free(source);
    try testing.expectEqual(Result.success, terminal_c.set(
        source,
        .scrollback_max_bytes,
        null,
    ));
    const source_pages = &terminal_c.zigTerminal(source).?.screens
        .get(.primary).?.pages;
    const first_page_rows = source_pages.pages.first.?.capacity().rows;
    for (0..@as(usize, first_page_rows) * 3) |_|
        terminal_c.vt_write(source, "x\r\n", 3);
    var encoded_ptr: ?[*]u8 = null;
    var encoded_len: usize = 0;
    try testing.expectEqual(Result.success, encode_alloc(
        source,
        &lib.alloc.test_allocator,
        &encoded_ptr,
        &encoded_len,
    ));
    const encoded = encoded_ptr.?[0..encoded_len];
    defer lib.alloc.default(&lib.alloc.test_allocator).free(encoded);
    for ([_]bool{ false, true }) |compress| {
        var decoder: Decoder = null;
        try testing.expectEqual(Result.success, decoder_new_buf(
            &lib.alloc.test_allocator,
            &decoder,
            encoded.ptr,
            encoded.len,
        ));
        defer decoder_free(decoder);
        try testing.expectEqual(Result.success, decoder_set(
            decoder,
            .compress_history,
            &compress,
        ));
        var restored: terminal_c.Terminal = null;
        try testing.expectEqual(Result.success, decoder_decode(
            decoder,
            &restored,
        ));
        defer terminal_c.free(restored);
        try testing.expectEqual(Result.invalid_value, decoder_set(
            decoder,
            .compress_history,
            &compress,
        ));
        var actual = !compress;
        try testing.expectEqual(Result.success, decoder_get(
            decoder,
            .compress_history,
            &actual,
        ));
        try testing.expectEqual(compress, actual);
        const pages = &terminal_c.zigTerminal(restored).?.screens
            .get(.primary).?.pages;
        try testing.expectEqual(source_pages.total_rows, pages.total_rows);
        const active = pages.getTopLeft(.active).node;
        var history_pages: usize = 0;
        var current = pages.pages.first;
        while (current) |node| : (current = node.next) {
            if (node == active) break;
            history_pages += 1;
        }
        try testing.expect(history_pages > 0);
        try testing.expectEqual(
            if (compress) history_pages else 0,
            pages.memoryStats().compressed_pages,
        );
    }
}
test "snapshot incremental decoder exposes READY and page progress" {
    var source: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &source,
        215,
        2,
    ));
    defer terminal_c.free(source);
    try testEnableContinuation(source);
    try testing.expectEqual(Result.success, terminal_c.set(
        source,
        .scrollback_max_bytes,
        null,
    ));
    const first_page_rows = terminal_c.zigTerminal(source).?.screens
        .get(.primary).?.pages.pages.first.?.capacity().rows;
    for (0..@as(usize, first_page_rows) * 3) |_|
        terminal_c.vt_write(source, "x\r\n", 3);
    const ready_continuation = "\x1b]2;ready";
    terminal_c.vt_write(
        source,
        ready_continuation,
        ready_continuation.len,
    );
    var encoded_ptr: ?[*]u8 = null;
    var encoded_len: usize = 0;
    try testing.expectEqual(Result.success, encode_alloc(
        source,
        &lib.alloc.test_allocator,
        &encoded_ptr,
        &encoded_len,
    ));
    const encoded = encoded_ptr.?[0..encoded_len];
    defer lib.alloc.default(&lib.alloc.test_allocator).free(encoded);
    var decoder: Decoder = null;
    try testing.expectEqual(Result.success, decoder_new_buf(
        &lib.alloc.test_allocator,
        &decoder,
        encoded.ptr,
        encoded.len,
    ));
    defer decoder_free(decoder);
    const retained_limit: usize = 1024;
    try testing.expectEqual(Result.success, decoder_set(
        decoder,
        .max_continuation_bytes,
        &retained_limit,
    ));
    const retain = true;
    try testing.expectEqual(Result.success, decoder_set(
        decoder,
        .retain_continuation,
        &retain,
    ));
    var restored: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, decoder_ready(decoder, &restored));
    defer terminal_c.free(restored);
    var restored_limit: usize = 0;
    try testing.expectEqual(Result.success, terminal_c.get(
        restored,
        .continuation_max_bytes,
        &restored_limit,
    ));
    try testing.expectEqual(retained_limit, restored_limit);
    var ready_buf: [32]u8 = undefined;
    var ready_len: usize = 0;
    try testing.expectEqual(Result.success, terminal_c.continuation_buf(
        restored,
        &ready_buf,
        ready_buf.len,
        &ready_len,
    ));
    try testing.expectEqualStrings(
        ready_continuation,
        ready_buf[0..ready_len],
    );
    var history_rows: u64 = 0;
    try testing.expectEqual(Result.success, decoder_get(
        decoder,
        .history_rows_primary,
        &history_rows,
    ));
    try testing.expect(history_rows > 0);
    var page_count: usize = 0;
    while (true) {
        const result = decoder_next(decoder);
        if (result == .no_value) break;
        try testing.expectEqual(Result.success, result);
        page_count += 1;
        var screen: terminal_c.TerminalScreen = undefined;
        var rows: usize = 0;
        var remaining: u32 = 0;
        const keys = [_]DecoderData{
            .progress_screen,
            .progress_rows,
            .progress_remaining,
        };
        const values = [_]?*anyopaque{ &screen, &rows, &remaining };
        var written: usize = 0;
        try testing.expectEqual(Result.success, decoder_get_multi(
            decoder,
            keys.len,
            &keys,
            @constCast(&values),
            &written,
        ));
        try testing.expectEqual(keys.len, written);
        try testing.expectEqual(terminal_c.TerminalScreen.primary, screen);
        try testing.expect(rows > 0);
    }
    try testing.expect(page_count > 0);
    var rows: usize = 0;
    try testing.expectEqual(Result.no_value, decoder_get(
        decoder,
        .progress_rows,
        &rows,
    ));
    try testing.expectEqual(Result.no_value, decoder_next(decoder));
    var source_total: usize = 0;
    var restored_total: usize = 0;
    try testing.expectEqual(Result.success, terminal_c.get(
        source,
        .total_rows,
        &source_total,
    ));
    try testing.expectEqual(Result.success, terminal_c.get(
        restored,
        .total_rows,
        &restored_total,
    ));
    try testing.expectEqual(source_total, restored_total);
    var dropped_decoder: Decoder = null;
    try testing.expectEqual(Result.success, decoder_new_buf(
        &lib.alloc.test_allocator,
        &dropped_decoder,
        encoded.ptr,
        encoded.len,
    ));
    defer decoder_free(dropped_decoder);
    var dropped: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, decoder_ready(
        dropped_decoder,
        &dropped,
    ));
    defer terminal_c.free(dropped);
    try testing.expectEqual(Result.success, terminal_c.resize(
        dropped,
        214,
        2,
        0,
        0,
    ));
    try testing.expectEqual(Result.success, decoder_next(dropped_decoder));
    var dropped_rows: usize = 1;
    try testing.expectEqual(Result.success, decoder_get(
        dropped_decoder,
        .progress_rows,
        &dropped_rows,
    ));
    try testing.expectEqual(@as(usize, 0), dropped_rows);
    while (decoder_next(dropped_decoder) == .success) {}
    try testing.expectEqual(Result.no_value, decoder_next(dropped_decoder));
}
