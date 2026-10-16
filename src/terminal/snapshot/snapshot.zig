const std = @import("std");
const build_options = @import("terminal_options");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const checkpoint = @import("checkpoint.zig");
const continuation = @import("continuation.zig");
const envelope = @import("envelope.zig");
const test_fixture = @import("fixture.zig");
const history = @import("history.zig");
const page = @import("page.zig");
const record = @import("record.zig");
const screen = @import("screen.zig");
const size = @import("../size.zig");
const terminal = @import("terminal.zig");
const Terminal = @import("../Terminal.zig");
const TerminalStream = @import("../stream_terminal.zig").Stream;
const terminal_kitty = @import("../kitty.zig");
const TerminalPageList = @import("../PageList.zig");
const TerminalScreen = @import("../Screen.zig");
const TerminalScreenKey = @import("../ScreenSet.zig").Key;
pub const Continuation = continuation.Value;
pub const EncodeError = terminal.EncodeError ||
    screen.EncodeError ||
    history.EncodeError ||
    checkpoint.EncodeError ||
    continuation.EncodeError;
pub const EncodeOptions = struct {
    continuation: Continuation,
};
pub fn encode(
    alloc: Allocator,
    destination: *std.Io.Writer,
    t: *const Terminal,
    options: EncodeOptions,
) EncodeError!void {
    try continuation.validate(options.continuation);
    var stack_alloc = std.heap.stackFallback(512, alloc);
    var stream: record.Writer = .init(stack_alloc.get(), destination);
    defer stream.deinit();
    try envelope.encode(stream.writer());
    try terminal.encode(t, &stream);
    try screen.encode(
        t.screens.get(.primary).?,
        .primary,
        &stream,
    );
    if (t.screens.get(.alternate)) |alternate| try screen.encode(
        alternate,
        .alternate,
        &stream,
    );
    try continuation.encode(options.continuation, &stream);
    try checkpoint.encode(.ready, &stream);
    try history.encode(
        t.screens.get(.primary).?,
        .primary,
        &stream,
    );
    if (t.screens.get(.alternate)) |alternate| try history.encode(
        alternate,
        .alternate,
        &stream,
    );
    try checkpoint.encode(.finish, &stream);
}
pub const DecodeError = Decoder.ReadyError || Decoder.NextError;
pub const DecodeOptions = struct {
    max_continuation_bytes: usize,
    compress_history: bool = false,
};
pub const Decoded = struct {
    terminal: ?Terminal,
    continuation: Continuation,
    history_rows: std.EnumMap(TerminalScreenKey, u64),
    pub fn deinit(self: *Decoded, alloc: Allocator) void {
        if (self.terminal) |*value| value.deinit(alloc);
        switch (self.continuation) {
            .ground => {},
            .bytes => |bytes| alloc.free(bytes),
        }
        self.* = undefined;
    }
    pub fn toOwned(self: *Decoded) Terminal {
        const result = self.terminal.?;
        self.terminal = null;
        return result;
    }
};
pub const Decoder = struct {
    source: *std.Io.Reader,
    state: State,
    const State = union(enum) {
        start,
        history: History,
        finished,
        failed,
    };
    const History = struct {
        generations: std.EnumMap(TerminalScreenKey, usize),
        routed: std.EnumSet(TerminalScreenKey),
        pending: usize,
        current: ?Sequence,
        cols: size.CellCountInt,
        page_options: history.DecodeOptions,
    };
    const Sequence = struct {
        key: TerminalScreenKey,
        remaining: u32,
        apply: bool,
    };
    pub fn init(source: *std.Io.Reader) Decoder {
        return .{
            .source = source,
            .state = .start,
        };
    }
    pub const ReadyError = envelope.DecodeError ||
        terminal.DecodeError ||
        screen.DecodeError ||
        continuation.DecodeError ||
        checkpoint.DecodeError ||
        error{
            UnexpectedScreenKey,
            DuplicateScreen,
        };
    pub fn ready(
        self: *Decoder,
        alloc: Allocator,
        io_: std.Io,
        options: DecodeOptions,
    ) ReadyError!Decoded {
        assert(self.state == .start);
        errdefer self.state = .failed;
        const reader = self.source;
        try envelope.decode(reader);
        var result = try terminal.decode(reader, io_, alloc);
        errdefer result.deinit(alloc);
        const screen_count = result.screens.all.count();
        const screen_options: TerminalScreen.Options = options: {
            const primary = result.screens.get(.primary).?;
            const explicit_bytes = primary.pages.limits.bytes.explicit;
            const explicit_lines = primary.pages.limits.lines.explicit;
            break :options .{
                .cols = result.cols,
                .rows = result.rows,
                .max_scrollback_bytes = if (explicit_bytes == std.math.maxInt(usize))
                    null
                else
                    explicit_bytes,
                .max_scrollback_lines = if (explicit_lines == std.math.maxInt(usize))
                    null
                else
                    explicit_lines,
            };
        };
        var routed: std.EnumSet(TerminalScreenKey) = .initEmpty();
        var history_rows: std.EnumMap(TerminalScreenKey, u64) = .init(.{});
        for (0..screen_count) |_| {
            var decoded = try screen.decode(
                reader,
                io_,
                alloc,
                screen_options,
            );
            errdefer decoded.deinit();
            const slot = result.screens.get(decoded.key) orelse
                return error.UnexpectedScreenKey;
            if (routed.contains(decoded.key)) return error.DuplicateScreen;
            routed.insert(decoded.key);
            history_rows.put(decoded.key, decoded.history_rows);
            slot.deinit();
            slot.* = decoded.screen;
            decoded.screen = undefined;
        }
        const decoded_continuation = try continuation.decode(
            alloc,
            reader,
            options.max_continuation_bytes,
        );
        errdefer switch (decoded_continuation) {
            .ground => {},
            .bytes => |bytes| alloc.free(bytes),
        };
        try checkpoint.decode(.ready, self.source);
        var generations: std.EnumMap(TerminalScreenKey, usize) = .init(.{});
        var it = result.screens.all.iterator();
        while (it.next()) |entry| generations.put(
            entry.key,
            result.screens.generation(entry.key),
        );
        self.state = .{ .history = .{
            .generations = generations,
            .routed = .initEmpty(),
            .pending = screen_count,
            .current = null,
            .cols = result.cols,
            .page_options = .{ .compress = options.compress_history },
        } };
        return .{
            .terminal = result,
            .continuation = decoded_continuation,
            .history_rows = history_rows,
        };
    }
    pub const Progress = struct {
        key: TerminalScreenKey,
        rows: usize,
        remaining: u32,
    };
    pub const NextError = checkpoint.DecodeError ||
        history.Decoder.InitError ||
        page.DiscardError ||
        page.DecodeError ||
        Allocator.Error ||
        error{
            DecoderNotReady,
            DecoderFailed,
            UnexpectedHistoryKey,
            DuplicateHistory,
            InvalidPageDimensions,
            RowCountOverflow,
            PageSizeOverflow,
        };
    pub fn next(
        self: *Decoder,
        alloc: Allocator,
        t: *Terminal,
    ) NextError!?Progress {
        switch (self.state) {
            .start => return error.DecoderNotReady,
            .failed => return error.DecoderFailed,
            .finished => return null,
            .history => {},
        }
        errdefer self.state = .failed;
        const state = &self.state.history;
        while (true) {
            if (state.current) |*sequence| {
                if (sequence.remaining > 0) {
                    return try self.nextPage(alloc, t, sequence);
                }
                state.current = null;
            }
            if (state.pending == 0) {
                try checkpoint.decode(.finish, self.source);
                if (comptime build_options.slow_runtime_safety) {
                    var it = state.generations.iterator();
                    while (it.next()) |entry| {
                        const restored = t.screens.get(entry.key) orelse
                            continue;
                        restored.pages.assertIntegrity();
                        restored.assertIntegrity();
                    }
                }
                self.state = .finished;
                return null;
            }
            state.pending -= 1;
            var manifest: history.Decoder = undefined;
            try manifest.init(self.source);
            const key = manifest.header.key;
            if (state.generations.get(key) == null) {
                return error.UnexpectedHistoryKey;
            }
            if (state.routed.contains(key)) return error.DuplicateHistory;
            state.routed.insert(key);
            state.current = .{
                .key = key,
                .remaining = manifest.header.page_count,
                .apply = true,
            };
        }
    }
    fn nextPage(
        self: *Decoder,
        alloc: Allocator,
        t: *Terminal,
        sequence: *Sequence,
    ) NextError!Progress {
        const state = &self.state.history;
        const destination: ?*TerminalScreen = destination: {
            if (!sequence.apply) break :destination null;
            if (t.cols != state.cols) break :destination null;
            const restored = t.screens.get(sequence.key) orelse
                break :destination null;
            if (t.screens.generation(sequence.key) !=
                state.generations.get(sequence.key).?)
            {
                break :destination null;
            }
            break :destination restored;
        };
        sequence.remaining -= 1;
        const rows: usize = rows: {
            const restored = destination orelse {
                sequence.apply = false;
                try page.discard(self.source);
                break :rows 0;
            };
            break :rows history.decodePage(
                self.source,
                alloc,
                restored,
                state.page_options,
            ) catch |err| switch (err) {
                error.MaxSizeExceeded,
                error.MaxLinesExceeded,
                => drop: {
                    sequence.apply = false;
                    break :drop 0;
                },
                else => |other| return other,
            };
        };
        return .{
            .key = sequence.key,
            .rows = rows,
            .remaining = sequence.remaining,
        };
    }
};
pub fn decode(
    alloc: Allocator,
    io_: std.Io,
    source: *std.Io.Reader,
    options: DecodeOptions,
) DecodeError!Decoded {
    var decoder: Decoder = .init(source);
    var result = try decoder.ready(alloc, io_, options);
    errdefer result.deinit(alloc);
    const t = &result.terminal.?;
    while (try decoder.next(alloc, t)) |_| {}
    return result;
}
pub const DecodeExactError = DecodeError || std.Io.Reader.Error || error{
    TrailingData,
};
pub fn decodeExact(
    alloc: Allocator,
    io_: std.Io,
    source: *std.Io.Reader,
    options: DecodeOptions,
) DecodeExactError!Decoded {
    var result = try decode(alloc, io_, source, options);
    errdefer result.deinit(alloc);
    _ = source.peekByte() catch |err| switch (err) {
        error.EndOfStream => return result,
        else => return err,
    };
    return error.TrailingData;
}
const test_encode_options: EncodeOptions = .{ .continuation = .ground };
const test_decode_options: DecodeOptions = .{ .max_continuation_bytes = 1024 };
const test_complete_fixture = test_fixture.parse(@embedFile("testdata/complete-v1.hex"));
fn testHistoryTerminal(history_pages: u8) !Terminal {
    const testing = std.testing;
    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 3,
        .max_scrollback_bytes = null,
        .max_scrollback_lines = null,
    });
    errdefer t.deinit(testing.allocator);
    const primary = t.screens.get(.primary).?;
    var replacement: TerminalScreen = replacement: {
        var builder = try TerminalPageList.Builder.init(
            testing.allocator,
            .{
                .cols = t.cols,
                .rows = t.rows,
                .max_size = null,
                .max_lines = null,
            },
        );
        defer builder.deinit();
        for (0..history_pages) |index| {
            const built = try builder.allocatePage(.{ .cols = 2, .rows = 2 });
            built.size.rows = 2;
            built.getRowAndCell(0, 0).cell.* = .init(
                @intCast('A' + index),
            );
        }
        const active = try builder.allocatePage(.{ .cols = 2, .rows = 3 });
        active.size.rows = 3;
        active.getRowAndCell(0, 0).cell.* = .init(
            @intCast('A' + @as(usize, history_pages)),
        );
        var pages = try builder.finish();
        errdefer pages.deinit();
        const cursor_pin = try pages.trackPin(
            pages.pin(.{ .active = .{} }).?,
        );
        const cursor_rac = cursor_pin.rowAndCell();
        break :replacement .{
            .io = testing.io,
            .alloc = testing.allocator,
            .pages = pages,
            .cursor = .{
                .page_pin = cursor_pin,
                .page_row = cursor_rac.row,
                .page_cell = cursor_rac.cell,
            },
        };
    };
    primary.deinit();
    primary.* = replacement;
    replacement = undefined;
    return t;
}
fn testTopLeftCodepoint(terminal_screen: *const TerminalScreen) u21 {
    return terminal_screen.pages.getTopLeft(.screen).node
        .page().getRowAndCell(0, 0).cell.codepoint();
}
test "complete snapshot round trip with history and alternate screen" {
    const testing = std.testing;
    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 3,
        .max_scrollback_bytes = null,
        .max_scrollback_lines = null,
    });
    defer t.deinit(testing.allocator);
    t.width_px = 800;
    t.height_px = 600;
    t.colors.palette.set(7, .{ .r = 1, .g = 2, .b = 3 });
    t.modes.values.bracketed_paste = true;
    try t.setPwd("file:///tmp/snapshot");
    try t.setTitle("complete snapshot");
    const primary = t.screens.get(.primary).?;
    var replacement: TerminalScreen = replacement: {
        var builder = try TerminalPageList.Builder.init(
            testing.allocator,
            .{
                .cols = t.cols,
                .rows = t.rows,
                .max_size = null,
                .max_lines = null,
            },
        );
        defer builder.deinit();
        const oldest = try builder.allocatePage(.{ .cols = 2, .rows = 2 });
        oldest.size.rows = 2;
        oldest.getRowAndCell(0, 0).cell.* = .init('A');
        const recent = try builder.allocatePage(.{ .cols = 2, .rows = 2 });
        recent.size.rows = 2;
        recent.getRowAndCell(0, 0).cell.* = .init('B');
        const active = try builder.allocatePage(.{ .cols = 2, .rows = 3 });
        active.size.rows = 3;
        active.getRowAndCell(0, 0).cell.* = .init('C');
        active.getRowAndCell(0, 1).cell.* = .init('D');
        active.getRowAndCell(0, 2).cell.* = .init('E');
        var pages = try builder.finish();
        errdefer pages.deinit();
        const cursor_pin = try pages.trackPin(
            pages.pin(.{ .active = .{} }).?,
        );
        const cursor_rac = cursor_pin.rowAndCell();
        break :replacement .{
            .io = testing.io,
            .alloc = testing.allocator,
            .pages = pages,
            .cursor = .{
                .page_pin = cursor_pin,
                .page_row = cursor_rac.row,
                .page_cell = cursor_rac.cell,
            },
        };
    };
    primary.deinit();
    primary.* = replacement;
    replacement = undefined;
    try testing.expect(primary.pages.scrollbar().total > t.rows);
    _ = primary.pages.compress(.full);
    const source_memory = primary.pages.memoryStats();
    _ = try t.switchScreen(.alternate);
    try t.printString("alternate");
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, test_encode_options);
    try testing.expectEqualDeep(source_memory, primary.pages.memoryStats());
    try test_fixture.expectEqual(
        .snapshot,
        "src/terminal/snapshot/testdata/complete-v1.hex",
        "snapshot_fixture-complete-v1.hex",
        &test_complete_fixture,
        encoded.written(),
    );
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var hashing = discard.writer.hashed(record.Crc32c.init(), &.{});
    try encode(testing.allocator, &hashing.writer, &t, test_encode_options);
    try testing.expectEqual(
        @as(u64, test_complete_fixture.len),
        discard.fullCount(),
    );
    try testing.expectEqual(
        record.Crc32c.hash(&test_complete_fixture),
        hashing.hasher.final(),
    );
    var encoded_source: std.Io.Reader = .fixed(&test_complete_fixture);
    var source_buffer: [1]u8 = undefined;
    var limited = encoded_source.limited(.unlimited, &source_buffer);
    var restored = try decode(
        testing.allocator,
        testing.io,
        &limited.interface,
        test_decode_options,
    );
    defer restored.deinit(testing.allocator);
    const restored_terminal = &restored.terminal.?;
    try testing.expectEqual(
        TerminalScreenKey.alternate,
        restored_terminal.screens.active_key,
    );
    try testing.expectEqual(
        restored_terminal.screens.get(.alternate).?,
        restored_terminal.screens.active,
    );
    try testing.expectEqualStrings(
        "file:///tmp/snapshot",
        restored_terminal.getPwd().?,
    );
    try testing.expectEqualStrings(
        "complete snapshot",
        restored_terminal.getTitle().?,
    );
    try testing.expectEqual(
        primary.pages.scrollbar().total,
        restored_terminal.screens.get(.primary).?.pages.scrollbar().total,
    );
    var reencoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reencoded.deinit();
    try encode(
        testing.allocator,
        &reencoded.writer,
        restored_terminal,
        test_encode_options,
    );
    try testing.expectEqualStrings(
        &test_complete_fixture,
        reencoded.written(),
    );
    var reversed: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reversed.deinit();
    var reversed_stream: record.Writer = .init(
        testing.allocator,
        &reversed.writer,
    );
    defer reversed_stream.deinit();
    try envelope.encode(reversed_stream.writer());
    try terminal.encode(&t, &reversed_stream);
    try screen.encode(
        t.screens.get(.alternate).?,
        .alternate,
        &reversed_stream,
    );
    try screen.encode(primary, .primary, &reversed_stream);
    try continuation.encode(.ground, &reversed_stream);
    try checkpoint.encode(.ready, &reversed_stream);
    try history.encode(
        t.screens.get(.alternate).?,
        .alternate,
        &reversed_stream,
    );
    try history.encode(primary, .primary, &reversed_stream);
    try checkpoint.encode(.finish, &reversed_stream);
    var reversed_source: std.Io.Reader = .fixed(reversed.written());
    var reversed_restored = try decode(
        testing.allocator,
        testing.io,
        &reversed_source,
        test_decode_options,
    );
    defer reversed_restored.deinit(testing.allocator);
    const reversed_terminal = &reversed_restored.terminal.?;
    try testing.expectEqual(
        TerminalScreenKey.alternate,
        reversed_terminal.screens.active_key,
    );
    try testing.expectEqual(
        @as(usize, 0),
        reversed_terminal.screens.generation(.primary),
    );
    try testing.expectEqual(
        @as(usize, 0),
        reversed_terminal.screens.generation(.alternate),
    );
}
test "complete snapshot restores a canonical Stream continuation" {
    const testing = std.testing;
    var source_terminal = try Terminal.init(
        testing.io,
        testing.allocator,
        .{ .cols = 8, .rows = 2 },
    );
    defer source_terminal.deinit(testing.allocator);
    var source_stream = TerminalStream.init(.{
        .allocator = testing.allocator,
        .handler = .init(&source_terminal),
        .continuation_max_bytes = 1024,
    });
    defer source_stream.deinit();
    source_stream.nextSlice("A\x1b[31");
    var exported_bytes: [1024]u8 = undefined;
    var exported: std.Io.Writer = .fixed(&exported_bytes);
    try source_stream.writeContinuation(&exported);
    try testing.expectEqualStrings("\x1b[31", exported.buffered());
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &source_terminal, .{
        .continuation = .{ .bytes = exported.buffered() },
    });
    var encoded_source: std.Io.Reader = .fixed(encoded.written());
    var decoded = try decode(
        testing.allocator,
        testing.io,
        &encoded_source,
        .{ .max_continuation_bytes = 1024 },
    );
    defer decoded.deinit(testing.allocator);
    try testing.expectEqualStrings(
        exported.buffered(),
        decoded.continuation.bytes,
    );
    var restored_terminal = decoded.toOwned();
    defer restored_terminal.deinit(testing.allocator);
    try testing.expect(decoded.terminal == null);
    var restored_stream = TerminalStream.init(.{
        .allocator = testing.allocator,
        .handler = .init(&restored_terminal),
        .continuation_max_bytes = 1024,
    });
    defer restored_stream.deinit();
    restored_stream.nextSlice(decoded.continuation.bytes);
    var reexported_bytes: [1024]u8 = undefined;
    var reexported: std.Io.Writer = .fixed(&reexported_bytes);
    try restored_stream.writeContinuation(&reexported);
    try testing.expectEqualStrings(exported.buffered(), reexported.buffered());
    source_stream.nextSlice("mB");
    restored_stream.next('m');
    restored_stream.next('B');
    const source_text = try source_terminal.plainString(testing.allocator);
    defer testing.allocator.free(source_text);
    const restored_text = try restored_terminal.plainString(testing.allocator);
    defer testing.allocator.free(restored_text);
    try testing.expectEqualStrings(source_text, restored_text);
    try testing.expectEqual(
        source_terminal.screens.active.cursor.style_id,
        restored_terminal.screens.active.cursor.style_id,
    );
}
test "complete snapshot validates continuation before writing" {
    const testing = std.testing;
    var t = try Terminal.init(
        testing.io,
        testing.allocator,
        .{ .cols = 2, .rows = 1 },
    );
    defer t.deinit(testing.allocator);
    var destination: std.Io.Writer.Allocating = .init(testing.allocator);
    defer destination.deinit();
    try destination.writer.writeAll("prefix");
    try testing.expectError(
        error.NoPendingState,
        encode(testing.allocator, &destination.writer, &t, .{
            .continuation = .{ .bytes = "\x1b[31m" },
        }),
    );
    try testing.expectEqualStrings("prefix", destination.written());
    var tail = [_]u8{ 0x1b, '[', '3', '1' };
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, .{
        .continuation = .{ .bytes = &tail },
    });
    tail[2] = '4';
    var source: std.Io.Reader = .fixed(encoded.written());
    var decoded = try decode(
        testing.allocator,
        testing.io,
        &source,
        test_decode_options,
    );
    defer decoded.deinit(testing.allocator);
    try testing.expectEqualStrings("\x1b[31", decoded.continuation.bytes);
}
test "complete snapshot waits for continuation tracking recovery" {
    const testing = std.testing;
    var t = try Terminal.init(
        testing.io,
        testing.allocator,
        .{ .cols = 2, .rows = 1 },
    );
    defer t.deinit(testing.allocator);
    var stream = TerminalStream.init(.{
        .allocator = testing.allocator,
        .handler = .init(&t),
        .continuation_max_bytes = 4,
    });
    defer stream.deinit();
    stream.nextSlice("\x1b[123");
    var unavailable_bytes: [4]u8 = undefined;
    var unavailable: std.Io.Writer = .fixed(&unavailable_bytes);
    try testing.expectError(
        error.ContinuationUnavailable,
        stream.writeContinuation(&unavailable),
    );
    stream.nextSlice("\x1b[");
    var recovered_bytes: [4]u8 = undefined;
    var recovered: std.Io.Writer = .fixed(&recovered_bytes);
    try stream.writeContinuation(&recovered);
    try testing.expectEqualStrings("\x1b[", recovered.buffered());
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, .{
        .continuation = .{ .bytes = recovered.buffered() },
    });
}
test "complete snapshot preserves every supported continuation cut" {
    const testing = std.testing;
    const corpora = [_][]const u8{
        "plain \xF0\x9F\x98\x84 utf8",
        "bad \xE0\xA0\xF0\x9F\x98\x84 utf8",
        "\x1b[1\x07;2mstyled\x1b[0m",
        "\x1b]2;window title\x1b\\text",
        "\x1bP$qm\x1b\\text",
        "\x1b_Ga=q;payload\x1b\\text",
        "\x1b_25a1;s\x1b\\text",
        "\x1b]2;first\x1b\\\x1b_Gsecond",
        "\x1b[12\x9D2;title\x1b\\text",
        "\x1b[12\x18text\x1b[1\x1Atext",
    };
    for (corpora) |corpus| for (0..corpus.len + 1) |cut| {
        var source_terminal = try Terminal.init(
            testing.io,
            testing.allocator,
            .{ .cols = 20, .rows = 4 },
        );
        defer source_terminal.deinit(testing.allocator);
        var source_stream = TerminalStream.init(.{
            .allocator = testing.allocator,
            .handler = .init(&source_terminal),
            .continuation_max_bytes = 4096,
        });
        defer source_stream.deinit();
        source_stream.nextSlice(corpus[0..cut]);
        var cut_bytes: [4096]u8 = undefined;
        var cut_writer: std.Io.Writer = .fixed(&cut_bytes);
        try source_stream.writeContinuation(&cut_writer);
        const cut_continuation: Continuation = if (cut_writer.end == 0)
            .ground
        else
            .{ .bytes = cut_writer.buffered() };
        var snapshot_bytes: std.Io.Writer.Allocating = .init(testing.allocator);
        defer snapshot_bytes.deinit();
        try encode(
            testing.allocator,
            &snapshot_bytes.writer,
            &source_terminal,
            .{ .continuation = cut_continuation },
        );
        var snapshot_source: std.Io.Reader = .fixed(snapshot_bytes.written());
        var decoded = try decode(
            testing.allocator,
            testing.io,
            &snapshot_source,
            .{ .max_continuation_bytes = 4096 },
        );
        defer decoded.deinit(testing.allocator);
        var restored_terminal = decoded.toOwned();
        defer restored_terminal.deinit(testing.allocator);
        var restored_stream = TerminalStream.init(.{
            .allocator = testing.allocator,
            .handler = .init(&restored_terminal),
            .continuation_max_bytes = 4096,
        });
        defer restored_stream.deinit();
        switch (decoded.continuation) {
            .ground => {},
            .bytes => |bytes| restored_stream.nextSlice(bytes),
        }
        var reexport_bytes: [4096]u8 = undefined;
        var reexport_writer: std.Io.Writer = .fixed(&reexport_bytes);
        try restored_stream.writeContinuation(&reexport_writer);
        try testing.expectEqualStrings(
            cut_writer.buffered(),
            reexport_writer.buffered(),
        );
        source_stream.nextSlice(corpus[cut..]);
        var offset = cut;
        var partition = cut +% corpus.len +% 1;
        while (offset < corpus.len) {
            partition = partition *% 1664525 +% 1013904223;
            const len = @min(1 + partition % 7, corpus.len - offset);
            restored_stream.nextSlice(corpus[offset..][0..len]);
            offset += len;
        }
        var source_final_bytes: [4096]u8 = undefined;
        var source_final_writer: std.Io.Writer = .fixed(&source_final_bytes);
        try source_stream.writeContinuation(&source_final_writer);
        var restored_final_bytes: [4096]u8 = undefined;
        var restored_final_writer: std.Io.Writer = .fixed(&restored_final_bytes);
        try restored_stream.writeContinuation(&restored_final_writer);
        try testing.expectEqualStrings(
            source_final_writer.buffered(),
            restored_final_writer.buffered(),
        );
        const final_continuation: Continuation = if (source_final_writer.end == 0)
            .ground
        else
            .{ .bytes = source_final_writer.buffered() };
        var source_final_snapshot: std.Io.Writer.Allocating = .init(
            testing.allocator,
        );
        defer source_final_snapshot.deinit();
        try encode(
            testing.allocator,
            &source_final_snapshot.writer,
            &source_terminal,
            .{ .continuation = final_continuation },
        );
        var restored_final_snapshot: std.Io.Writer.Allocating = .init(
            testing.allocator,
        );
        defer restored_final_snapshot.deinit();
        try encode(
            testing.allocator,
            &restored_final_snapshot.writer,
            &restored_terminal,
            .{ .continuation = final_continuation },
        );
        try testing.expectEqualStrings(
            source_final_snapshot.written(),
            restored_final_snapshot.written(),
        );
    };
}
test "complete snapshot preserves Kitty virtual placeholders" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 1,
    });
    defer t.deinit(testing.allocator);
    try t.screens.active.kitty_images.addImage(
        testing.io,
        testing.allocator,
        t.screens.active,
        .{ .id = 1 },
    );
    try t.screens.active.kitty_images.addPlacement(
        testing.io,
        testing.allocator,
        t.screens.active,
        1,
        0,
        .{
            .location = .{ .virtual = {} },
            .columns = 1,
            .rows = 1,
        },
    );
    try t.setAttribute(.{ .@"256_fg" = 1 });
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");
    const source_cell = t.screens.active.pages.getCell(.{
        .screen = .{},
    }).?;
    try testing.expectEqual(
        terminal_kitty.graphics.unicode.placeholder,
        source_cell.cell.codepoint(),
    );
    try testing.expect(source_cell.row.kitty_virtual_placeholder);
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, test_encode_options);
    var encoded_source: std.Io.Reader = .fixed(encoded.written());
    var restored = try decode(
        testing.allocator,
        testing.io,
        &encoded_source,
        test_decode_options,
    );
    defer restored.deinit(testing.allocator);
    const restored_terminal = &restored.terminal.?;
    const restored_cell = restored_terminal.screens.active.pages.getCell(.{
        .screen = .{},
    }).?;
    try testing.expectEqual(
        terminal_kitty.graphics.unicode.placeholder,
        restored_cell.cell.codepoint(),
    );
    try testing.expect(restored_cell.cell.hasGrapheme());
    try testing.expect(restored_cell.row.kitty_virtual_placeholder);
    try testing.expectEqual(
        @as(usize, 0),
        restored_terminal.screens.active.kitty_images.images.count(),
    );
    try testing.expectEqual(
        @as(usize, 0),
        restored_terminal.screens.active.kitty_images.placements.count(),
    );
}
test "complete snapshot encoding streams from the current writer position" {
    const testing = std.testing;
    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 1,
    });
    defer t.deinit(testing.allocator);
    var nonempty: std.Io.Writer.Allocating = .init(testing.allocator);
    defer nonempty.deinit();
    try nonempty.writer.writeAll("prefix");
    const snapshot_offset = nonempty.written().len;
    try encode(testing.allocator, &nonempty.writer, &t, test_encode_options);
    try testing.expectEqualStrings(
        "prefix",
        nonempty.written()[0..snapshot_offset],
    );
    var appended_source: std.Io.Reader = .fixed(
        nonempty.written()[snapshot_offset..],
    );
    var appended = try decode(
        testing.allocator,
        testing.io,
        &appended_source,
        test_decode_options,
    );
    appended.deinit(testing.allocator);
    t.colors.palette.current[7] = .{ .r = 1, .g = 2, .b = 3 };
    var destination: std.Io.Writer.Allocating = .init(testing.allocator);
    defer destination.deinit();
    try destination.writer.writeAll("prefix");
    try testing.expectError(
        error.InvalidPalette,
        encode(
            testing.allocator,
            &destination.writer,
            &t,
            test_encode_options,
        ),
    );
    var expected_envelope: [envelope.encoded_len]u8 = undefined;
    var envelope_writer: std.Io.Writer = .fixed(&expected_envelope);
    try envelope.encode(&envelope_writer);
    try testing.expectEqualStrings(
        &expected_envelope,
        destination.written()["prefix".len..],
    );
}
test "complete snapshot rejects ordering and invalid markers" {
    const testing = std.testing;
    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 1,
    });
    defer t.deinit(testing.allocator);
    const primary = t.screens.get(.primary).?;
    var old_order: std.Io.Writer.Allocating = .init(testing.allocator);
    defer old_order.deinit();
    var old_order_stream: record.Writer = .init(
        testing.allocator,
        &old_order.writer,
    );
    defer old_order_stream.deinit();
    try envelope.encode(old_order_stream.writer());
    try terminal.encode(&t, &old_order_stream);
    try screen.encode(primary, .primary, &old_order_stream);
    try checkpoint.encode(.ready, &old_order_stream);
    var old_order_source: std.Io.Reader = .fixed(old_order.written());
    try testing.expectError(
        error.UnexpectedRecordTag,
        decode(
            testing.allocator,
            testing.io,
            &old_order_source,
            test_decode_options,
        ),
    );
    var duplicate_continuation: std.Io.Writer.Allocating = .init(
        testing.allocator,
    );
    defer duplicate_continuation.deinit();
    var duplicate_continuation_stream: record.Writer = .init(
        testing.allocator,
        &duplicate_continuation.writer,
    );
    defer duplicate_continuation_stream.deinit();
    try envelope.encode(duplicate_continuation_stream.writer());
    try terminal.encode(&t, &duplicate_continuation_stream);
    try screen.encode(primary, .primary, &duplicate_continuation_stream);
    try continuation.encode(.ground, &duplicate_continuation_stream);
    try continuation.encode(.ground, &duplicate_continuation_stream);
    var duplicate_continuation_source: std.Io.Reader = .fixed(
        duplicate_continuation.written(),
    );
    try testing.expectError(
        error.UnexpectedRecordTag,
        decode(
            testing.allocator,
            testing.io,
            &duplicate_continuation_source,
            test_decode_options,
        ),
    );
    var reordered: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reordered.deinit();
    var reordered_stream: record.Writer = .init(
        testing.allocator,
        &reordered.writer,
    );
    defer reordered_stream.deinit();
    try envelope.encode(reordered_stream.writer());
    try terminal.encode(&t, &reordered_stream);
    try history.encode(primary, .primary, &reordered_stream);
    var reordered_source: std.Io.Reader = .fixed(reordered.written());
    try testing.expectError(
        error.UnexpectedRecordTag,
        decode(
            testing.allocator,
            testing.io,
            &reordered_source,
            test_decode_options,
        ),
    );
    var invalid_ready: std.Io.Writer.Allocating = .init(testing.allocator);
    defer invalid_ready.deinit();
    var invalid_ready_stream: record.Writer = .init(
        testing.allocator,
        &invalid_ready.writer,
    );
    defer invalid_ready_stream.deinit();
    try envelope.encode(invalid_ready_stream.writer());
    try terminal.encode(&t, &invalid_ready_stream);
    try screen.encode(primary, .primary, &invalid_ready_stream);
    try continuation.encode(.ground, &invalid_ready_stream);
    const ready_payload = invalid_ready_stream.begin(.ready);
    errdefer invalid_ready_stream.cancel();
    try ready_payload.writeByte(0);
    try invalid_ready_stream.finish();
    var invalid_ready_source: std.Io.Reader = .fixed(
        invalid_ready.written(),
    );
    try testing.expectError(
        error.PayloadNotExhausted,
        decode(
            testing.allocator,
            testing.io,
            &invalid_ready_source,
            test_decode_options,
        ),
    );
    var undeclared: std.Io.Writer.Allocating = .init(testing.allocator);
    defer undeclared.deinit();
    var undeclared_stream: record.Writer = .init(
        testing.allocator,
        &undeclared.writer,
    );
    defer undeclared_stream.deinit();
    try envelope.encode(undeclared_stream.writer());
    try terminal.encode(&t, &undeclared_stream);
    try screen.encode(primary, .alternate, &undeclared_stream);
    var undeclared_source: std.Io.Reader = .fixed(undeclared.written());
    try testing.expectError(
        error.UnexpectedScreenKey,
        decode(
            testing.allocator,
            testing.io,
            &undeclared_source,
            test_decode_options,
        ),
    );
    var undeclared_history: std.Io.Writer.Allocating = .init(testing.allocator);
    defer undeclared_history.deinit();
    var undeclared_history_stream: record.Writer = .init(
        testing.allocator,
        &undeclared_history.writer,
    );
    defer undeclared_history_stream.deinit();
    try envelope.encode(undeclared_history_stream.writer());
    try terminal.encode(&t, &undeclared_history_stream);
    try screen.encode(primary, .primary, &undeclared_history_stream);
    try continuation.encode(.ground, &undeclared_history_stream);
    try checkpoint.encode(.ready, &undeclared_history_stream);
    try history.encode(primary, .alternate, &undeclared_history_stream);
    var undeclared_history_source: std.Io.Reader = .fixed(
        undeclared_history.written(),
    );
    try testing.expectError(
        error.UnexpectedHistoryKey,
        decode(
            testing.allocator,
            testing.io,
            &undeclared_history_source,
            test_decode_options,
        ),
    );
    _ = try t.switchScreen(.alternate);
    var duplicate: std.Io.Writer.Allocating = .init(testing.allocator);
    defer duplicate.deinit();
    var duplicate_stream: record.Writer = .init(
        testing.allocator,
        &duplicate.writer,
    );
    defer duplicate_stream.deinit();
    try envelope.encode(duplicate_stream.writer());
    try terminal.encode(&t, &duplicate_stream);
    try screen.encode(primary, .primary, &duplicate_stream);
    try screen.encode(primary, .primary, &duplicate_stream);
    var duplicate_source: std.Io.Reader = .fixed(duplicate.written());
    try testing.expectError(
        error.DuplicateScreen,
        decode(
            testing.allocator,
            testing.io,
            &duplicate_source,
            test_decode_options,
        ),
    );
    var duplicate_history: std.Io.Writer.Allocating = .init(testing.allocator);
    defer duplicate_history.deinit();
    var duplicate_history_stream: record.Writer = .init(
        testing.allocator,
        &duplicate_history.writer,
    );
    defer duplicate_history_stream.deinit();
    try envelope.encode(duplicate_history_stream.writer());
    try terminal.encode(&t, &duplicate_history_stream);
    try screen.encode(primary, .primary, &duplicate_history_stream);
    try screen.encode(
        t.screens.get(.alternate).?,
        .alternate,
        &duplicate_history_stream,
    );
    try continuation.encode(.ground, &duplicate_history_stream);
    try checkpoint.encode(.ready, &duplicate_history_stream);
    try history.encode(primary, .primary, &duplicate_history_stream);
    try history.encode(primary, .primary, &duplicate_history_stream);
    var duplicate_history_source: std.Io.Reader = .fixed(
        duplicate_history.written(),
    );
    try testing.expectError(
        error.DuplicateHistory,
        decode(
            testing.allocator,
            testing.io,
            &duplicate_history_source,
            test_decode_options,
        ),
    );
}
test "complete snapshot leaves continuation bytes unread" {
    const testing = std.testing;
    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 1,
    });
    defer t.deinit(testing.allocator);
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, test_encode_options);
    const snapshot_len = encoded.written().len;
    try encoded.writer.writeAll("pty");
    var source: std.Io.Reader = .fixed(encoded.written());
    var restored = try decode(
        testing.allocator,
        testing.io,
        &source,
        test_decode_options,
    );
    defer restored.deinit(testing.allocator);
    var trailing: [3]u8 = undefined;
    try source.readSliceAll(&trailing);
    try testing.expectEqualStrings("pty", &trailing);
    var exact_source: std.Io.Reader = .fixed(encoded.written());
    try testing.expectError(
        error.TrailingData,
        decodeExact(
            testing.allocator,
            testing.io,
            &exact_source,
            test_decode_options,
        ),
    );
    var bounded_source: std.Io.Reader = .fixed(
        encoded.written()[0..snapshot_len],
    );
    var bounded = try decodeExact(
        testing.allocator,
        testing.io,
        &bounded_source,
        test_decode_options,
    );
    defer bounded.deinit(testing.allocator);
}
test "complete snapshots decode sequentially from one reader" {
    const testing = std.testing;
    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 1,
    });
    defer t.deinit(testing.allocator);
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, test_encode_options);
    try encode(testing.allocator, &encoded.writer, &t, test_encode_options);
    var source: std.Io.Reader = .fixed(encoded.written());
    var first = try decode(
        testing.allocator,
        testing.io,
        &source,
        test_decode_options,
    );
    defer first.deinit(testing.allocator);
    var second = try decode(
        testing.allocator,
        testing.io,
        &source,
        test_decode_options,
    );
    defer second.deinit(testing.allocator);
    try testing.expectError(error.EndOfStream, source.takeByte());
}
test "complete snapshot decode allocation failures are transactional" {
    const testing = std.testing;
    const S = struct {
        fn exercise(bytes: []const u8) !void {
            var baseline = testing.FailingAllocator.init(testing.allocator, .{
                .fail_index = std.math.maxInt(usize),
            });
            var baseline_source: std.Io.Reader = .fixed(bytes);
            var baseline_decoded = try decode(
                baseline.allocator(),
                testing.io,
                &baseline_source,
                test_decode_options,
            );
            baseline_decoded.deinit(baseline.allocator());
            const allocation_count = baseline.alloc_index;
            try testing.expect(allocation_count > 0);
            var saw_out_of_memory = false;
            for (0..allocation_count) |fail_index| {
                var failing = testing.FailingAllocator.init(
                    testing.allocator,
                    .{ .fail_index = fail_index },
                );
                var source: std.Io.Reader = .fixed(bytes);
                var decoded = decode(
                    failing.allocator(),
                    testing.io,
                    &source,
                    test_decode_options,
                ) catch |err| switch (err) {
                    error.OutOfMemory => {
                        saw_out_of_memory = true;
                        continue;
                    },
                    else => return err,
                };
                decoded.deinit(failing.allocator());
            }
            try testing.expect(saw_out_of_memory);
        }
    };
    try S.exercise(&test_complete_fixture);
    var t = try Terminal.init(
        testing.io,
        testing.allocator,
        .{ .cols = 2, .rows = 1 },
    );
    defer t.deinit(testing.allocator);
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, .{
        .continuation = .{ .bytes = "\x1b[31" },
    });
    try S.exercise(encoded.written());
}
test "incremental decode restores a renderable terminal at READY" {
    const testing = std.testing;
    var transport: std.Io.Writer.Allocating = .init(testing.allocator);
    defer transport.deinit();
    try transport.writer.writeAll(&test_complete_fixture);
    try transport.writer.writeAll("pty");
    var source: std.Io.Reader = .fixed(transport.written());
    var decoder: Decoder = .init(&source);
    var decoded = try decoder.ready(
        testing.allocator,
        testing.io,
        test_decode_options,
    );
    defer decoded.deinit(testing.allocator);
    var restored = decoded.toOwned();
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(
        TerminalScreenKey.alternate,
        restored.screens.active_key,
    );
    try testing.expectEqualStrings(
        "complete snapshot",
        restored.getTitle().?,
    );
    const primary = restored.screens.get(.primary).?;
    const alternate = restored.screens.get(.alternate).?;
    try testing.expectEqual(3, primary.pages.scrollbar().total);
    try testing.expectEqual(4, decoded.history_rows.get(.primary).?);
    try testing.expectEqual(
        alternate.pages.scrollbar().total - restored.rows,
        decoded.history_rows.get(.alternate).?,
    );
    const first = (try decoder.next(testing.allocator, &restored)).?;
    try testing.expectEqualDeep(Decoder.Progress{
        .key = .primary,
        .rows = 2,
        .remaining = 1,
    }, first);
    try testing.expectEqual(5, primary.pages.scrollbar().total);
    try testing.expectEqual(@as(u21, 'B'), testTopLeftCodepoint(primary));
    const second = (try decoder.next(testing.allocator, &restored)).?;
    try testing.expectEqualDeep(Decoder.Progress{
        .key = .primary,
        .rows = 2,
        .remaining = 0,
    }, second);
    try testing.expectEqual(7, primary.pages.scrollbar().total);
    try testing.expectEqual(@as(u21, 'A'), testTopLeftCodepoint(primary));
    try testing.expect(try decoder.next(testing.allocator, &restored) == null);
    try testing.expect(try decoder.next(testing.allocator, &restored) == null);
    try testing.expectEqualStrings("pty", try source.take(3));
    var reencoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reencoded.deinit();
    try encode(
        testing.allocator,
        &reencoded.writer,
        &restored,
        test_encode_options,
    );
    try testing.expectEqualStrings(&test_complete_fixture, reencoded.written());
}
test "incremental next reports invalid decoder states" {
    const testing = std.testing;
    var source: std.Io.Reader = .fixed("");
    var decoder: Decoder = .init(&source);
    var terminal_value = try Terminal.init(
        testing.io,
        testing.allocator,
        .{ .cols = 1, .rows = 1 },
    );
    defer terminal_value.deinit(testing.allocator);
    try testing.expectError(
        error.DecoderNotReady,
        decoder.next(testing.allocator, &terminal_value),
    );
}
test "incremental decode applies history below live PTY output" {
    const testing = std.testing;
    var t = try testHistoryTerminal(2);
    defer t.deinit(testing.allocator);
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, test_encode_options);
    var source: std.Io.Reader = .fixed(encoded.written());
    var decoder: Decoder = .init(&source);
    var decoded = try decoder.ready(
        testing.allocator,
        testing.io,
        test_decode_options,
    );
    defer decoded.deinit(testing.allocator);
    var restored = decoded.toOwned();
    defer restored.deinit(testing.allocator);
    var live = restored.vtStream();
    defer live.deinit();
    live.nextSlice("1\r\n2\r\n3\r\n4\r\n5\r\n");
    const primary = restored.screens.get(.primary).?;
    const live_total = primary.pages.scrollbar().total;
    try testing.expect(live_total > 3);
    while (try decoder.next(testing.allocator, &restored)) |progress| {
        try testing.expectEqual(TerminalScreenKey.primary, progress.key);
        try testing.expectEqual(2, progress.rows);
    }
    try testing.expectEqual(live_total + 4, primary.pages.scrollbar().total);
    try testing.expectEqual(@as(u21, 'A'), testTopLeftCodepoint(primary));
    const newest_history = primary.pages.getTopLeft(.screen).node.next.?;
    try testing.expectEqual(
        @as(u21, 'B'),
        newest_history.page().getRowAndCell(0, 0).cell.codepoint(),
    );
    try testing.expectEqual(
        @as(u21, '1'),
        newest_history.next.?.page().getRowAndCell(0, 0).cell.codepoint(),
    );
}
test "incremental decode discards history for screens changed since READY" {
    const testing = std.testing;
    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 3,
    });
    defer t.deinit(testing.allocator);
    _ = try t.switchScreen(.alternate);
    try t.printString("alt");
    _ = try t.switchScreen(.primary);
    var crafted: std.Io.Writer.Allocating = .init(testing.allocator);
    defer crafted.deinit();
    var stream: record.Writer = .init(testing.allocator, &crafted.writer);
    defer stream.deinit();
    try envelope.encode(stream.writer());
    try terminal.encode(&t, &stream);
    try screen.encode(t.screens.get(.primary).?, .primary, &stream);
    try screen.encode(t.screens.get(.alternate).?, .alternate, &stream);
    try continuation.encode(.ground, &stream);
    try checkpoint.encode(.ready, &stream);
    {
        const payload = stream.begin(.history);
        errdefer stream.cancel();
        try (history.Header{ .key = .alternate, .page_count = 1 }).encode(
            payload,
        );
        try stream.finish();
    }
    try page.encode(
        t.screens.get(.alternate).?.pages
            .getTopLeft(.screen).node.pageAssumeResident(),
        &stream,
    );
    try history.encode(t.screens.get(.primary).?, .primary, &stream);
    try checkpoint.encode(.finish, &stream);
    {
        var source: std.Io.Reader = .fixed(crafted.written());
        var decoder: Decoder = .init(&source);
        var decoded = try decoder.ready(
            testing.allocator,
            testing.io,
            test_decode_options,
        );
        defer decoded.deinit(testing.allocator);
        const restored = &decoded.terminal.?;
        const progress = (try decoder.next(testing.allocator, restored)).?;
        try testing.expectEqual(TerminalScreenKey.alternate, progress.key);
        try testing.expect(progress.rows > 0);
        try testing.expect(try decoder.next(testing.allocator, restored) == null);
        try testing.expectEqual(
            @as(usize, 2),
            restored.screens.get(.alternate).?.pages.totalPages(),
        );
    }
    {
        var source: std.Io.Reader = .fixed(crafted.written());
        var decoder: Decoder = .init(&source);
        var decoded = try decoder.ready(
            testing.allocator,
            testing.io,
            test_decode_options,
        );
        defer decoded.deinit(testing.allocator);
        const restored = &decoded.terminal.?;
        restored.screens.remove(testing.allocator, .alternate);
        const progress = (try decoder.next(testing.allocator, restored)).?;
        try testing.expectEqualDeep(Decoder.Progress{
            .key = .alternate,
            .rows = 0,
            .remaining = 0,
        }, progress);
        try testing.expect(try decoder.next(testing.allocator, restored) == null);
    }
    {
        var source: std.Io.Reader = .fixed(crafted.written());
        var decoder: Decoder = .init(&source);
        var decoded = try decoder.ready(
            testing.allocator,
            testing.io,
            test_decode_options,
        );
        defer decoded.deinit(testing.allocator);
        const restored = &decoded.terminal.?;
        restored.screens.remove(testing.allocator, .alternate);
        _ = try restored.switchScreen(.alternate);
        const progress = (try decoder.next(testing.allocator, restored)).?;
        try testing.expectEqual(TerminalScreenKey.alternate, progress.key);
        try testing.expectEqual(0, progress.rows);
        try testing.expect(try decoder.next(testing.allocator, restored) == null);
        try testing.expectEqual(
            @as(usize, 1),
            restored.screens.get(.alternate).?.pages.totalPages(),
        );
    }
}
test "incremental decode discards history after a resize" {
    const testing = std.testing;
    var t = try testHistoryTerminal(2);
    defer t.deinit(testing.allocator);
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, test_encode_options);
    var source: std.Io.Reader = .fixed(encoded.written());
    var decoder: Decoder = .init(&source);
    var decoded = try decoder.ready(
        testing.allocator,
        testing.io,
        test_decode_options,
    );
    defer decoded.deinit(testing.allocator);
    var restored = decoded.toOwned();
    defer restored.deinit(testing.allocator);
    try restored.resize(testing.allocator, .{ .cols = 3, .rows = 3 });
    const primary = restored.screens.get(.primary).?;
    const resized_total = primary.pages.scrollbar().total;
    var pages: usize = 0;
    while (try decoder.next(testing.allocator, &restored)) |progress| {
        try testing.expectEqual(TerminalScreenKey.primary, progress.key);
        try testing.expectEqual(0, progress.rows);
        pages += 1;
    }
    try testing.expectEqual(2, pages);
    try testing.expectEqual(resized_total, primary.pages.scrollbar().total);
}
test "decode drops history beyond the declared scrollback limits" {
    const testing = std.testing;
    var t = try testHistoryTerminal(3);
    defer t.deinit(testing.allocator);
    t.screens.get(.primary).?.pages.limits.set(.bytes, 1);
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, test_encode_options);
    {
        var source: std.Io.Reader = .fixed(encoded.written());
        var decoder: Decoder = .init(&source);
        var decoded = try decoder.ready(
            testing.allocator,
            testing.io,
            test_decode_options,
        );
        defer decoded.deinit(testing.allocator);
        const restored = &decoded.terminal.?;
        var rows: [3]usize = undefined;
        var pages: usize = 0;
        while (try decoder.next(testing.allocator, restored)) |progress| {
            rows[pages] = progress.rows;
            pages += 1;
        }
        try testing.expectEqual(3, pages);
        try testing.expectEqualSlices(usize, &.{ 2, 0, 0 }, &rows);
        const primary = restored.screens.get(.primary).?;
        try testing.expectEqual(@as(usize, 2), primary.pages.totalPages());
        try testing.expectEqual(@as(u21, 'C'), testTopLeftCodepoint(primary));
    }
    {
        var source: std.Io.Reader = .fixed(encoded.written());
        var decoded = try decode(
            testing.allocator,
            testing.io,
            &source,
            test_decode_options,
        );
        defer decoded.deinit(testing.allocator);
        const primary = decoded.terminal.?.screens.get(.primary).?;
        try testing.expectEqual(@as(usize, 2), primary.pages.totalPages());
        try testing.expectEqual(@as(u21, 'C'), testTopLeftCodepoint(primary));
    }
}
test "incremental decode failure leaves applied history usable" {
    const testing = std.testing;
    var t = try testHistoryTerminal(2);
    defer t.deinit(testing.allocator);
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, test_encode_options);
    var source: std.Io.Reader = .fixed(
        encoded.written()[0 .. encoded.written().len - 1],
    );
    var decoder: Decoder = .init(&source);
    var decoded = try decoder.ready(
        testing.allocator,
        testing.io,
        test_decode_options,
    );
    defer decoded.deinit(testing.allocator);
    var restored = decoded.toOwned();
    defer restored.deinit(testing.allocator);
    for (0..2) |_| {
        const progress = (try decoder.next(testing.allocator, &restored)).?;
        try testing.expectEqual(2, progress.rows);
    }
    try testing.expectError(
        error.EndOfStream,
        decoder.next(testing.allocator, &restored),
    );
    try testing.expectError(
        error.DecoderFailed,
        decoder.next(testing.allocator, &restored),
    );
    const primary = restored.screens.get(.primary).?;
    try testing.expectEqual(@as(usize, 3), primary.pages.totalPages());
    try testing.expectEqual(@as(u21, 'A'), testTopLeftCodepoint(primary));
    primary.pages.assertIntegrity();
    primary.assertIntegrity();
}
