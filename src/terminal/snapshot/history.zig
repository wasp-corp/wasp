const std = @import("std");
const Allocator = std.mem.Allocator;
const test_fixture = @import("fixture.zig");
const io = @import("io.zig");
const page = @import("page.zig");
const record = @import("record.zig");
const screen = @import("screen.zig");
const TerminalPage = @import("../page.zig").Page;
const TerminalPageList = @import("../PageList.zig");
const TerminalScreen = @import("../Screen.zig");
const TerminalScreenKey = @import("../ScreenSet.zig").Key;
pub const Header = struct {
    pub const len = computeLen();
    comptime {
        std.debug.assert(len == 6);
    }
    key: TerminalScreenKey,
    page_count: u32,
    pub fn encode(
        self: Header,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try io.writeInt(writer, u16, @intCast(@intFromEnum(self.key)));
        try io.writeInt(writer, u32, self.page_count);
    }
    pub const DecodeError = std.Io.Reader.Error || error{InvalidKey};
    pub fn decode(reader: *std.Io.Reader) Header.DecodeError!Header {
        const raw = try io.readInt(reader, u16);
        const Tag = @typeInfo(TerminalScreenKey).@"enum".tag_type;
        const value = std.math.cast(Tag, raw) orelse
            return error.InvalidKey;
        const key = std.enums.fromInt(
            TerminalScreenKey,
            value,
        ) orelse return error.InvalidKey;
        return .{
            .key = key,
            .page_count = try io.readInt(reader, u32),
        };
    }
    fn computeLen() usize {
        comptime {
            var buf: [128]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buf);
            const value: Header = .{
                .key = .primary,
                .page_count = 0,
            };
            value.encode(&writer) catch unreachable;
            return writer.end;
        }
    }
};
pub const EncodeError = Allocator.Error ||
    page.EncodeError ||
    record.Writer.FinishError ||
    error{
        PageCountOverflow,
    };
pub fn encode(
    terminal_screen: *const TerminalScreen,
    key: TerminalScreenKey,
    destination: *record.Writer,
) EncodeError!void {
    const first = terminal_screen.pages.getTopLeft(.active).node.prev;
    const page_count: usize = count: {
        var page_count: usize = 0;
        var node = first;
        while (node) |current| : (node = current.prev) {
            page_count += 1;
        }
        break :count page_count;
    };
    const header: Header = .{
        .key = key,
        .page_count = std.math.cast(
            u32,
            page_count,
        ) orelse return error.PageCountOverflow,
    };
    {
        const payload = destination.begin(.history);
        errdefer destination.cancel();
        try header.encode(payload);
        try destination.finish();
    }
    var node = first;
    while (node) |current| : (node = current.prev) {
        var preserved = try current.pagePreservingState(terminal_screen.alloc);
        defer preserved.deinit();
        try page.encode(preserved.page(), destination);
    }
}
pub const DecodeError = Decoder.InitError ||
    Decoder.RestoreError ||
    error{
        UnexpectedScreenKey,
    };
pub const DecodeOptions = struct {
    compress: bool = false,
};
pub const DecodePageError = Allocator.Error ||
    page.DecodeError ||
    TerminalPageList.PageAllocation.FinalizeError;
pub fn decodePage(
    source: *std.Io.Reader,
    alloc: Allocator,
    terminal_screen: *TerminalScreen,
    options: DecodeOptions,
) DecodePageError!usize {
    var decoder: page.Decoder = undefined;
    try decoder.init(source);
    var allocation = try terminal_screen.pages.allocatePage(
        decoder.capacity(),
    );
    defer allocation.deinit();
    try decoder.decode(allocation.page(), alloc);
    const rows = allocation.page().size.rows;
    const contains_prompt = hasSemanticPrompt(allocation.page());
    try allocation.finalize(.prepend, .{ .compress = options.compress });
    if (contains_prompt) terminal_screen.semantic_prompt.seen = true;
    return rows;
}
pub const Decoder = struct {
    source: *std.Io.Reader,
    header: Header,
    pub const InitError = Header.DecodeError ||
        record.Reader.InitError ||
        record.Reader.FinishError ||
        error{
            UnexpectedRecordTag,
        };
    pub const RestoreError = DecodePageError || error{
        ExistingHistory,
    };
    pub fn init(self: *Decoder, source: *std.Io.Reader) InitError!void {
        var record_reader: record.Reader = undefined;
        try record_reader.init(source);
        if (record_reader.header.tag != .history) {
            return error.UnexpectedRecordTag;
        }
        const header = try Header.decode(record_reader.payloadReader());
        try record_reader.finish();
        self.* = .{ .source = source, .header = header };
    }
    pub fn decode(
        self: *Decoder,
        alloc: Allocator,
        terminal_screen: *TerminalScreen,
        options: DecodeOptions,
    ) RestoreError!void {
        const active_top = terminal_screen.pages.getTopLeft(.active);
        if (terminal_screen.pages.getTopLeft(.screen).node != active_top.node) {
            return error.ExistingHistory;
        }
        for (0..self.header.page_count) |_| {
            _ = try decodePage(
                self.source,
                alloc,
                terminal_screen,
                options,
            );
        }
        terminal_screen.pages.assertIntegrity();
        terminal_screen.assertIntegrity();
    }
};
pub fn decode(
    source: *std.Io.Reader,
    alloc: Allocator,
    expected_key: TerminalScreenKey,
    terminal_screen: *TerminalScreen,
    options: DecodeOptions,
) DecodeError!void {
    var decoder: Decoder = undefined;
    try decoder.init(source);
    if (decoder.header.key != expected_key) return error.UnexpectedScreenKey;
    try decoder.decode(alloc, terminal_screen, options);
}
fn hasSemanticPrompt(terminal_page: *const TerminalPage) bool {
    const rows = terminal_page.rows.ptr(terminal_page.memory)[0..terminal_page.size.rows];
    for (rows) |row| {
        if (row.semantic_prompt != .none) return true;
        const cells = row.cells.ptr(
            terminal_page.memory,
        )[0..terminal_page.size.cols];
        for (cells) |cell| {
            if (cell.semantic_content == .prompt) return true;
        }
    }
    return false;
}
const test_header_fixture = test_fixture.parse(@embedFile("testdata/history-header-v1.hex"));
test "HISTORY header golden encoding and decoding" {
    const expected: Header = .{
        .key = .alternate,
        .page_count = 0x01020304,
    };
    var encoded: [Header.len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try expected.encode(&writer);
    try test_fixture.expectEqual(
        .bytes,
        "src/terminal/snapshot/testdata/history-header-v1.hex",
        "snapshot_fixture-history-header-v1.hex",
        &test_header_fixture,
        writer.buffered(),
    );
    try std.testing.expectEqual(Header.len, test_header_fixture.len);
    var reader: std.Io.Reader = .fixed(&test_header_fixture);
    try std.testing.expectEqualDeep(expected, try Header.decode(&reader));
    for (0..Header.len) |fixture_len| {
        var truncated: std.Io.Reader = .fixed(
            test_header_fixture[0..fixture_len],
        );
        try std.testing.expectError(
            error.EndOfStream,
            Header.decode(&truncated),
        );
    }
    var invalid_key = test_header_fixture;
    invalid_key[0] = 2;
    var invalid_key_reader: std.Io.Reader = .fixed(&invalid_key);
    try std.testing.expectError(
        error.InvalidKey,
        Header.decode(&invalid_key_reader),
    );
}
test "HISTORY encodes newest first and restores complete history" {
    var probe = try TerminalScreen.init(
        std.testing.io,
        std.testing.allocator,
        .{ .cols = 80, .rows = 1, .max_scrollback_bytes = 0 },
    );
    const page_rows = probe.pages.getTopLeft(.screen).node.capacity().rows;
    probe.deinit();
    const screen_rows = page_rows + 1;
    var source_screen = try TerminalScreen.init(
        std.testing.io,
        std.testing.allocator,
        .{
            .cols = 80,
            .rows = screen_rows,
            .max_scrollback_bytes = null,
        },
    );
    defer source_screen.deinit();
    source_screen.cursorAbsolute(0, screen_rows - 1);
    while (source_screen.pages.totalPages() < 4) {
        try source_screen.testWriteString("\n");
    }
    const active_top = source_screen.pages.getTopLeft(.active);
    const newest_history = active_top.node.prev.?;
    const oldest_history = newest_history.prev.?;
    try std.testing.expectEqual(
        source_screen.pages.getTopLeft(.screen).node,
        oldest_history,
    );
    try std.testing.expectEqual(null, oldest_history.prev);
    oldest_history.page().getRowAndCell(0, 0).cell.* = .init('A');
    oldest_history.page().getRowAndCell(
        0,
        0,
    ).cell.semantic_content = .prompt;
    newest_history.page().getRowAndCell(0, 0).cell.* = .init('B');
    var destination: std.Io.Writer.Allocating = .init(
        std.testing.allocator,
    );
    defer destination.deinit();
    var stream: record.Writer = .init(
        std.testing.allocator,
        &destination.writer,
    );
    defer stream.deinit();
    try screen.encode(&source_screen, .primary, &stream);
    const history_offset = destination.written().len;
    _ = source_screen.pages.compress(.full);
    const oldest_storage = oldest_history.storage();
    const newest_storage = newest_history.storage();
    try encode(&source_screen, .primary, &stream);
    try std.testing.expectEqual(oldest_storage, oldest_history.storage());
    try std.testing.expectEqual(newest_storage, newest_history.storage());
    var history_source: std.Io.Reader = .fixed(
        destination.written()[history_offset..],
    );
    var history_record: record.Reader = undefined;
    try history_record.init(&history_source);
    try std.testing.expectEqual(record.Tag.history, history_record.header.tag);
    const header = try Header.decode(history_record.payloadReader());
    try history_record.finish();
    try std.testing.expectEqual(TerminalScreenKey.primary, header.key);
    try std.testing.expectEqual(@as(u32, 2), header.page_count);
    var decoded_newest = try page.decode(
        &history_source,
        std.testing.allocator,
    );
    defer decoded_newest.deinit();
    try std.testing.expectEqual(
        @as(u21, 'B'),
        decoded_newest.getRowAndCell(0, 0).cell.codepoint(),
    );
    var decoded_oldest = try page.decode(
        &history_source,
        std.testing.allocator,
    );
    defer decoded_oldest.deinit();
    try std.testing.expectEqual(
        @as(u21, 'A'),
        decoded_oldest.getRowAndCell(0, 0).cell.codepoint(),
    );
    try std.testing.expectError(error.EndOfStream, history_source.takeByte());
    var restore_source: std.Io.Reader = .fixed(destination.written());
    var decoded_screen = try screen.decode(
        &restore_source,
        std.testing.io,
        std.testing.allocator,
        .{
            .cols = 80,
            .rows = screen_rows,
            .max_scrollback_bytes = null,
        },
    );
    defer decoded_screen.deinit();
    try std.testing.expectEqual(
        TerminalScreenKey.primary,
        decoded_screen.key,
    );
    try std.testing.expectEqual(
        @as(u64, @intCast(source_screen.pages.total_rows - screen_rows)),
        decoded_screen.history_rows,
    );
    const restored = &decoded_screen.screen;
    try std.testing.expect(!restored.semantic_prompt.seen);
    try decode(
        &restore_source,
        std.testing.allocator,
        .primary,
        restored,
        .{},
    );
    try std.testing.expectEqual(
        source_screen.pages.totalPages(),
        restored.pages.totalPages(),
    );
    const restored_oldest = restored.pages.getTopLeft(.screen).node;
    try std.testing.expectEqual(
        @as(u21, 'A'),
        restored_oldest.page().getRowAndCell(0, 0).cell.codepoint(),
    );
    try std.testing.expectEqual(
        @as(u21, 'B'),
        restored_oldest.next.?
            .page().getRowAndCell(0, 0).cell.codepoint(),
    );
    try std.testing.expect(restored.semantic_prompt.seen);
    try std.testing.expectError(error.EndOfStream, restore_source.takeByte());
    const encoded = try std.testing.allocator.dupe(
        u8,
        destination.written(),
    );
    defer std.testing.allocator.free(encoded);
    const first_page_offset = history_offset + record.Header.len + Header.len;
    const first_payload_len = std.mem.readInt(
        u32,
        encoded[first_page_offset + 2 ..][0..4],
        .little,
    );
    const second_page_offset =
        first_page_offset + record.Header.len + first_payload_len;
    var truncated_source: std.Io.Reader = .fixed(
        encoded[0 .. second_page_offset - 1],
    );
    var decoded_truncated = try screen.decode(
        &truncated_source,
        std.testing.io,
        std.testing.allocator,
        .{
            .cols = 80,
            .rows = screen_rows,
            .max_scrollback_bytes = null,
        },
    );
    defer decoded_truncated.deinit();
    const truncated = &decoded_truncated.screen;
    const truncated_screen_first = truncated.pages.getTopLeft(.screen).node;
    const truncated_screen_page_count = truncated.pages.totalPages();
    try std.testing.expectError(
        error.EndOfStream,
        decode(
            &truncated_source,
            std.testing.allocator,
            .primary,
            truncated,
            .{},
        ),
    );
    try std.testing.expectEqual(
        truncated_screen_page_count,
        truncated.pages.totalPages(),
    );
    try std.testing.expectEqual(
        truncated_screen_first,
        truncated.pages.getTopLeft(.screen).node,
    );
    truncated.pages.assertIntegrity();
    truncated.assertIntegrity();
    std.mem.writeInt(
        u16,
        encoded[second_page_offset..][0..2],
        @intFromEnum(record.Tag.screen),
        .little,
    );
    var partial_source: std.Io.Reader = .fixed(encoded);
    var decoded_partial = try screen.decode(
        &partial_source,
        std.testing.io,
        std.testing.allocator,
        .{
            .cols = 80,
            .rows = screen_rows,
            .max_scrollback_bytes = null,
        },
    );
    defer decoded_partial.deinit();
    const partial = &decoded_partial.screen;
    const screen_page_count = partial.pages.totalPages();
    try std.testing.expectError(
        error.UnexpectedRecordTag,
        decode(
            &partial_source,
            std.testing.allocator,
            .primary,
            partial,
            .{},
        ),
    );
    try std.testing.expectEqual(
        screen_page_count + 1,
        partial.pages.totalPages(),
    );
    try std.testing.expectEqual(
        @as(u21, 'B'),
        partial.pages.getTopLeft(.screen).node
            .page().getRowAndCell(0, 0).cell.codepoint(),
    );
    try std.testing.expect(!partial.semantic_prompt.seen);
    partial.pages.assertIntegrity();
    partial.assertIntegrity();
}
test "HISTORY decode compresses history pages when requested" {
    const alloc = std.testing.allocator;
    const screen_options: TerminalScreen.Options = .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_bytes = null,
    };
    var source_screen = try TerminalScreen.init(
        std.testing.io,
        alloc,
        screen_options,
    );
    defer source_screen.deinit();
    var line: usize = 0;
    while (source_screen.pages.totalPages() < 5) : (line += 1) {
        var buf: [32]u8 = undefined;
        try source_screen.testWriteString(
            try std.fmt.bufPrint(&buf, "line {d}\n", .{line}),
        );
    }
    const expected = try source_screen.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(expected);
    var destination: std.Io.Writer.Allocating = .init(alloc);
    defer destination.deinit();
    var stream: record.Writer = .init(alloc, &destination.writer);
    defer stream.deinit();
    try screen.encode(&source_screen, .primary, &stream);
    try encode(&source_screen, .primary, &stream);
    for ([_]bool{ false, true }) |compress| {
        var restore_source: std.Io.Reader = .fixed(destination.written());
        var decoded_screen = try screen.decode(
            &restore_source,
            std.testing.io,
            alloc,
            screen_options,
        );
        defer decoded_screen.deinit();
        const restored = &decoded_screen.screen;
        try decode(
            &restore_source,
            alloc,
            .primary,
            restored,
            .{ .compress = compress },
        );
        try std.testing.expectEqual(
            source_screen.pages.totalPages(),
            restored.pages.totalPages(),
        );
        const active = restored.pages.getTopLeft(.active).node;
        var history_pages: usize = 0;
        var current = restored.pages.pages.first;
        while (current) |node| : (current = node.next) {
            if (node == active) break;
            history_pages += 1;
            const expected_storage: @TypeOf(node.storage()) =
                if (compress) .compressed else .resident;
            try std.testing.expectEqual(expected_storage, node.storage());
        }
        try std.testing.expect(history_pages >= 3);
        current = active;
        while (current) |node| : (current = node.next) {
            try std.testing.expectEqual(.resident, node.storage());
        }
        try std.testing.expectEqual(
            if (compress) history_pages else 0,
            restored.pages.memoryStats().compressed_pages,
        );
        const actual = try restored.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
}
test "HISTORY encodes and restores an empty sequence" {
    var terminal_screen = try TerminalScreen.init(
        std.testing.io,
        std.testing.allocator,
        .{
            .cols = 2,
            .rows = 2,
            .max_scrollback_bytes = null,
        },
    );
    defer terminal_screen.deinit();
    var destination: std.Io.Writer.Allocating = .init(
        std.testing.allocator,
    );
    defer destination.deinit();
    var stream: record.Writer = .init(
        std.testing.allocator,
        &destination.writer,
    );
    defer stream.deinit();
    try encode(&terminal_screen, .primary, &stream);
    var inspect_source: std.Io.Reader = .fixed(destination.written());
    var history_record: record.Reader = undefined;
    try history_record.init(&inspect_source);
    const header = try Header.decode(history_record.payloadReader());
    try history_record.finish();
    try std.testing.expectEqual(@as(u32, 0), header.page_count);
    try std.testing.expectError(error.EndOfStream, inspect_source.takeByte());
    var decode_source: std.Io.Reader = .fixed(destination.written());
    const initial_first = terminal_screen.pages.getTopLeft(.screen).node;
    try decode(
        &decode_source,
        std.testing.allocator,
        .primary,
        &terminal_screen,
        .{ .compress = true },
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        terminal_screen.pages.memoryStats().compressed_pages,
    );
    try std.testing.expectEqual(
        initial_first,
        terminal_screen.pages.getTopLeft(.screen).node,
    );
    try std.testing.expectError(error.EndOfStream, decode_source.takeByte());
}
test "HISTORY rejects invalid routing and incomplete sequences" {
    var terminal_screen = try TerminalScreen.init(
        std.testing.io,
        std.testing.allocator,
        .{
            .cols = 2,
            .rows = 2,
            .max_scrollback_bytes = null,
        },
    );
    defer terminal_screen.deinit();
    const Case = struct {
        header: Header,
        expected: anyerror,
    };
    const cases = [_]Case{
        .{
            .header = .{
                .key = .alternate,
                .page_count = 0,
            },
            .expected = error.UnexpectedScreenKey,
        },
        .{
            .header = .{
                .key = .primary,
                .page_count = 1,
            },
            .expected = error.EndOfStream,
        },
    };
    for (cases) |case| {
        var destination: std.Io.Writer.Allocating = .init(
            std.testing.allocator,
        );
        defer destination.deinit();
        var stream: record.Writer = .init(
            std.testing.allocator,
            &destination.writer,
        );
        defer stream.deinit();
        const payload = stream.begin(.history);
        errdefer stream.cancel();
        try case.header.encode(payload);
        try stream.finish();
        var source: std.Io.Reader = .fixed(destination.written());
        try std.testing.expectError(
            case.expected,
            decode(
                &source,
                std.testing.allocator,
                .primary,
                &terminal_screen,
                .{},
            ),
        );
        terminal_screen.pages.assertIntegrity();
        terminal_screen.assertIntegrity();
    }
}
