const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const test_fixture = @import("fixture.zig");
const io = @import("io.zig");
const terminal_hyperlink = @import("../hyperlink.zig");
const terminal_page = @import("../page.zig");
const terminal_style = @import("../style.zig");
const kitty_virtual_placeholder: u21 = 0x10EEEE;
const TerminalCell = terminal_page.Cell;
const TerminalHyperlinkId = terminal_hyperlink.Id;
const TerminalPage = terminal_page.Page;
const TerminalRow = terminal_page.Row;
const TerminalStyleId = terminal_style.Id;
pub const Row = packed struct(u8) {
    wrap: bool = false,
    wrap_continuation: bool = false,
    semantic_prompt: u2 = 0,
    cell_width: Cell.EncodedWidth = .one,
    _padding: u2 = 0,
};
pub const Cell = packed struct(u64) {
    kind: u2 = @intFromEnum(Kind.codepoint),
    content: u24 = 0,
    style_id: u16 = 0,
    width: u2 = 0,
    protected: bool = false,
    hyperlink: bool = false,
    semantic_content: u2 = 0,
    hyperlink_id: u16 = 0,
    pub const Kind = enum(u2) {
        codepoint = 0,
        codepoint_grapheme = 1,
        bg_color_palette = 2,
        bg_color_rgb = 3,
    };
    pub const EncodedWidth = enum(u2) {
        one = 0,
        two = 1,
        four = 2,
        eight = 3,
        pub fn size(self: EncodedWidth) usize {
            return @as(usize, 1) << @intFromEnum(self);
        }
        pub fn Int(comptime self: EncodedWidth) type {
            return switch (self) {
                .one => u8,
                .two => u16,
                .four => u32,
                .eight => u64,
            };
        }
        pub fn truncate(comptime self: EncodedWidth, word: u64) self.Int() {
            return @truncate(switch (self) {
                .one, .two => @as(Cell, @bitCast(word)).content,
                .four, .eight => word,
            });
        }
        pub fn extend(comptime self: EncodedWidth, value: self.Int()) u64 {
            return switch (self) {
                .one, .two => @bitCast(Cell{ .content = value }),
                .four, .eight => value,
            };
        }
        pub fn mask(comptime self: EncodedWidth) u64 {
            return comptime self.extend(std.math.maxInt(self.Int()));
        }
        pub fn select(word: u64) EncodedWidth {
            inline for ([_]EncodedWidth{ .one, .two, .four }) |width| {
                if (word & ~width.mask() == 0) return width;
            }
            return .eight;
        }
    };
};
const native_matches_wire = native: {
    if (@bitSizeOf(TerminalCell) != 64) break :native false;
    const probes = [_]struct {
        native: TerminalCell,
        wire: Cell,
    }{
        .{
            .native = .{
                .content_tag = .codepoint_grapheme,
                .content = .{ .codepoint = .{ .data = 0x10FFFF } },
                .style_id = 0xBEEF,
                .wide = .spacer_tail,
                .protected = true,
                ._padding = 0x1D2C,
            },
            .wire = .{
                .kind = 1,
                .content = 0x10FFFF,
                .style_id = 0xBEEF,
                .width = 2,
                .protected = true,
                .hyperlink_id = 0x1D2C,
            },
        },
        .{
            .native = .{
                .content_tag = .bg_color_palette,
                .content = .{ .color_palette = .{ .data = 0xAB } },
                .wide = .spacer_head,
                .hyperlink = true,
                .semantic_content = .input,
            },
            .wire = .{
                .kind = 2,
                .content = 0xAB,
                .width = 3,
                .hyperlink = true,
                .semantic_content = 1,
            },
        },
        .{
            .native = .{
                .content_tag = .bg_color_rgb,
                .content = .{ .color_rgb = .{
                    .r = 0x12,
                    .g = 0x34,
                    .b = 0x56,
                } },
                .wide = .wide,
                .semantic_content = .prompt,
            },
            .wire = .{
                .kind = 3,
                .content = 0x563412,
                .width = 1,
                .semantic_content = 2,
            },
        },
    };
    for (probes) |probe| {
        const native_bits: u64 = @bitCast(probe.native);
        const wire_bits: u64 = @bitCast(probe.wire);
        if (native_bits != wire_bits) break :native false;
    }
    break :native true;
};
const bulk_codec = native_matches_wire and
    builtin.cpu.arch.endian() == .little;
pub const EncodeError = std.Io.Writer.Error || error{
    InvalidWideCell,
    TooManyGraphemes,
};
pub fn encode(
    page: *const TerminalPage,
    writer: *std.Io.Writer,
) EncodeError!void {
    defer page.assertIntegrity();
    for (0..page.size.rows) |y| {
        const row = page.getRow(y);
        const cells = page.getCells(row);
        const count: usize, const word_or: u64 = scanRow(cells);
        const wide_mask: u64 = comptime @bitCast(Cell{ .width = 3 });
        if (word_or & wide_mask != 0) {
            for (cells[0..count], 0..) |*cell, x| switch (cell.wide) {
                .narrow => {},
                .wide => if (x + 1 == cells.len or
                    cells[x + 1].wide != .spacer_tail)
                {
                    return error.InvalidWideCell;
                },
                .spacer_tail => if (x == 0 or
                    cells[x - 1].wide != .wide)
                {
                    return error.InvalidWideCell;
                },
                .spacer_head => if (x + 1 != cells.len or !row.wrap) {
                    return error.InvalidWideCell;
                },
            };
        }
        const cell_width: Cell.EncodedWidth = .select(word_or);
        const row_header: Row = .{
            .wrap = row.wrap,
            .wrap_continuation = row.wrap_continuation,
            .semantic_prompt = @intFromEnum(row.semantic_prompt),
            .cell_width = cell_width,
        };
        if (comptime bulk_codec) emit: {
            const words: [*]const u64 = @ptrCast(cells.ptr);
            switch (cell_width) {
                inline .one, .two, .four => |width| {
                    const size = comptime width.size();
                    const needed = 3 + count * size;
                    if (writer.unusedCapacityLen() < needed) break :emit;
                    const out = writer.unusedCapacitySlice()[0..needed];
                    out[0] = @bitCast(row_header);
                    std.mem.writeInt(u16, out[1..3], @intCast(count), .little);
                    encodeNarrowInto(width, words, count, out[3..]);
                    writer.advance(needed);
                    continue;
                },
                .eight => {
                    const witness: Cell = @bitCast(word_or);
                    if (!witness.hyperlink and witness.hyperlink_id == 0) {
                        const needed = 3 + count * 8;
                        if (writer.unusedCapacityLen() < needed) break :emit;
                        const out = writer.unusedCapacitySlice()[0..needed];
                        out[0] = @bitCast(row_header);
                        std.mem.writeInt(
                            u16,
                            out[1..3],
                            @intCast(count),
                            .little,
                        );
                        @memcpy(
                            out[3..],
                            std.mem.sliceAsBytes(cells[0..count]),
                        );
                        writer.advance(needed);
                        continue;
                    }
                },
            }
        }
        {
            var header_bytes: [3]u8 = undefined;
            header_bytes[0] = @bitCast(row_header);
            std.mem.writeInt(u16, header_bytes[1..3], @intCast(count), .little);
            try writer.writeAll(&header_bytes);
        }
        switch (cell_width) {
            inline .one, .two, .four => |width| try encodeNarrowCells(
                width,
                cells[0..count],
                writer,
            ),
            .eight => {
                if (comptime bulk_codec) {
                    const witness: Cell = @bitCast(word_or);
                    if (!witness.hyperlink and witness.hyperlink_id == 0) {
                        try writer.writeAll(std.mem.sliceAsBytes(cells[0..count]));
                        continue;
                    }
                }
                for (cells[0..count]) |*cell| {
                    const link_id: TerminalHyperlinkId = if (cell.hyperlink)
                        page.lookupHyperlink(cell) orelse unreachable
                    else
                        0;
                    try io.writeInt(
                        writer,
                        u64,
                        cellBits(cell.*, link_id),
                    );
                }
            },
        }
    }
    try encodeGraphemes(page, writer);
}
fn scanRow(cells: []const TerminalCell) struct { usize, u64 } {
    if (comptime bulk_codec) {
        const words: [*]const u64 = @ptrCast(cells.ptr);
        const V = @Vector(4, u64);
        const VPtr = *align(@alignOf(u64)) const V;
        var count = cells.len;
        while (count >= 4) {
            const tail = @as(VPtr, @ptrCast(words + count - 4)).*;
            if (@reduce(.Or, tail) != 0) break;
            count -= 4;
        }
        while (count > 0 and words[count - 1] == 0) count -= 1;
        const word_or: u64 = word_or: {
            var acc: V = @splat(0);
            var i: usize = 0;
            while (i + 4 <= count) : (i += 4) {
                acc |= @as(VPtr, @ptrCast(words + i)).*;
            }
            var word_or: u64 = @reduce(.Or, acc);
            while (i < count) : (i += 1) word_or |= words[i];
            break :word_or word_or;
        };
        return .{ count, word_or };
    }
    var count: usize = cells.len;
    while (count > 0 and cells[count - 1].isZero()) count -= 1;
    var word_or: u64 = 0;
    for (cells[0..count]) |*cell| word_or |= classifyWord(cell);
    return .{ count, word_or };
}
inline fn classifyWord(cell: *const TerminalCell) u64 {
    if (comptime native_matches_wire) return @bitCast(cell.*);
    var wire: Cell = @bitCast(cellBits(cell.*, 0));
    wire.hyperlink = cell.hyperlink;
    return @bitCast(wire);
}
fn encodeNarrowCells(
    comptime width: Cell.EncodedWidth,
    cells: []const TerminalCell,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const size = comptime width.size();
    var chunk: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < cells.len) {
        const n = @min(cells.len - i, chunk.len / size);
        for (cells[i..][0..n], 0..) |*cell, j| {
            std.mem.writeInt(
                width.Int(),
                chunk[j * size ..][0..size],
                width.truncate(classifyWord(cell)),
                .little,
            );
        }
        try writer.writeAll(chunk[0 .. n * size]);
        i += n;
    }
}
fn encodeNarrowInto(
    comptime width: Cell.EncodedWidth,
    words: [*]const u64,
    count: usize,
    out: []u8,
) void {
    comptime assert(bulk_codec);
    const size = comptime width.size();
    const V = @Vector(2, u64);
    const shift: V = @splat(comptime switch (width) {
        .one, .two => @bitOffsetOf(Cell, "content"),
        .four => 0,
        .eight => unreachable,
    });
    const mask: @Vector(size * 4, i32) = comptime mask: {
        var mask: [size * 4]i32 = undefined;
        for (0..2) |lane| {
            for (0..size) |byte| {
                mask[lane * size + byte] = @intCast(lane * 8 + byte);
                mask[(lane + 2) * size + byte] =
                    ~@as(i32, @intCast(lane * 8 + byte));
            }
        }
        break :mask mask;
    };
    var j: usize = 0;
    while (j + 4 <= count) : (j += 4) encodeNarrowStep(
        width,
        words,
        j,
        out,
        shift,
        mask,
    );
    if (j < count) {
        if (count >= 4) {
            encodeNarrowStep(width, words, count - 4, out, shift, mask);
        } else {
            while (j < count) : (j += 1) {
                std.mem.writeInt(
                    width.Int(),
                    out[j * size ..][0..size],
                    width.truncate(words[j]),
                    .little,
                );
            }
        }
    }
}
inline fn encodeNarrowStep(
    comptime width: Cell.EncodedWidth,
    words: [*]const u64,
    j: usize,
    out: []u8,
    shift: @Vector(2, u64),
    mask: @Vector(width.size() * 4, i32),
) void {
    const size = comptime width.size();
    const VPtr = *align(@alignOf(u64)) const @Vector(2, u64);
    const lo: @Vector(16, u8) = @bitCast(@as(VPtr, @ptrCast(words + j)).* >> shift);
    const hi: @Vector(16, u8) = @bitCast(@as(VPtr, @ptrCast(words + j + 2)).* >> shift);
    @as(
        *align(1) @Vector(size * 4, u8),
        @ptrCast(out[j * size ..].ptr),
    ).* = @shuffle(u8, lo, hi, mask);
}
fn encodeGraphemes(
    page: *const TerminalPage,
    writer: *std.Io.Writer,
) EncodeError!void {
    const entries = page.graphemeCount();
    try io.writeInt(writer, u32, @intCast(entries));
    if (entries == 0) return;
    var buffer: [4096]u8 = undefined;
    var used: usize = 0;
    var emitted: usize = 0;
    for (0..page.size.rows) |y| {
        const row = page.getRow(y);
        if (!row.grapheme) continue;
        for (page.getCells(row), 0..) |*cell, x| {
            if (!cell.hasGrapheme()) continue;
            const cps = page.lookupGrapheme(cell) orelse unreachable;
            if (cps.len > std.math.maxInt(u16)) return error.TooManyGraphemes;
            emitted += 1;
            const needed = 6 + cps.len * 4;
            if (buffer.len - used < needed) {
                try writer.writeAll(buffer[0..used]);
                used = 0;
            }
            if (needed > buffer.len) {
                try io.writeInt(writer, u16, @intCast(y));
                try io.writeInt(writer, u16, @intCast(x));
                try io.writeInt(writer, u16, @intCast(cps.len));
                for (cps) |cp| try io.writeInt(writer, u32, cp);
                continue;
            }
            std.mem.writeInt(u16, buffer[used..][0..2], @intCast(y), .little);
            std.mem.writeInt(u16, buffer[used + 2 ..][0..2], @intCast(x), .little);
            std.mem.writeInt(u16, buffer[used + 4 ..][0..2], @intCast(cps.len), .little);
            used += 6;
            for (cps) |cp| {
                std.mem.writeInt(u32, buffer[used..][0..4], cp, .little);
                used += 4;
            }
        }
    }
    try writer.writeAll(buffer[0..used]);
    assert(emitted == entries);
}
pub const DecodeError = std.Io.Reader.Error || error{
    InvalidRowCellCount,
};
pub const StyleRemap = Remap(TerminalStyleId);
pub const HyperlinkRemap = Remap(TerminalHyperlinkId);
pub fn decode(
    page: *TerminalPage,
    reader: *std.Io.Reader,
    style_remap: *const StyleRemap,
    hyperlink_remap: *const HyperlinkRemap,
) DecodeError!void {
    for (0..page.size.rows) |y| {
        const row_header: Row, const count: u16 = header: {
            var row_header_bytes: [3]u8 = undefined;
            if (reader.bufferedLen() >= 3) {
                row_header_bytes = reader.buffered()[0..3].*;
                reader.toss(3);
            } else {
                try reader.readSliceAll(&row_header_bytes);
            }
            const row_header: Row = @bitCast(row_header_bytes[0]);
            const count = std.mem.readInt(u16, row_header_bytes[1..3], .little);
            break :header .{ row_header, count };
        };
        if (@as(u8, @bitCast(row_header)) == 0 and count == 0) continue;
        const row = page.getRow(y);
        var row_value = row.*;
        row_value.wrap = row_header.wrap;
        row_value.wrap_continuation = row_header.wrap_continuation;
        row_value.semantic_prompt = std.enums.fromInt(
            TerminalRow.SemanticPrompt,
            row_header.semantic_prompt,
        ) orelse .none;
        row.* = row_value;
        const cells = page.getCells(row);
        if (count > cells.len) return error.InvalidRowCellCount;
        if (count == 0) continue;
        switch (row_header.cell_width) {
            inline .one, .two => |width| try decodeNarrowCells(
                width,
                reader,
                cells[0..count],
            ),
            .four => _ = try decodeWordCells(
                .four,
                page,
                row,
                cells,
                count,
                reader,
                style_remap,
                hyperlink_remap,
            ),
            .eight => {
                if (comptime bulk_codec) {
                    const words: [*]u64 = @ptrCast(cells.ptr);
                    try reader.readSliceAll(
                        std.mem.sliceAsBytes(cells[0..count]),
                    );
                    var row_or: u64 = 0;
                    for (0..count) |x| {
                        row_or |= words[x];
                        applyCell(
                            page,
                            row,
                            cells,
                            x,
                            words[x],
                            style_remap,
                            hyperlink_remap,
                        );
                    }
                    normalizeWideRow(.eight, row, cells, count, row_or);
                } else {
                    _ = try decodeWordCells(
                        .eight,
                        page,
                        row,
                        cells,
                        count,
                        reader,
                        style_remap,
                        hyperlink_remap,
                    );
                }
                if (count < cells.len and cells[count - 1].wide == .wide) {
                    cells[count - 1].wide = .narrow;
                }
            },
        }
    }
    try decodeGraphemes(page, reader);
}
fn decodeNarrowCells(
    comptime width: Cell.EncodedWidth,
    reader: *std.Io.Reader,
    cells: []TerminalCell,
) DecodeError!void {
    const size = comptime width.size();
    const total = cells.len * size;
    if (reader.bufferedLen() >= total) {
        widenCells(width, reader.buffered()[0..total], cells);
        reader.toss(total);
        return;
    }
    var chunk: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < cells.len) {
        const n = @min(cells.len - i, chunk.len / size);
        try reader.readSliceAll(chunk[0 .. n * size]);
        widenCells(width, chunk[0 .. n * size], cells[i..][0..n]);
        i += n;
    }
}
fn widenCells(
    comptime width: Cell.EncodedWidth,
    bytes: []const u8,
    cells: []TerminalCell,
) void {
    const size = comptime width.size();
    if (comptime bulk_codec) {
        const words: [*]u64 = @ptrCast(cells.ptr);
        const step = 16 / size;
        var i: usize = 0;
        while (i + step <= cells.len) : (i += step) {
            widenStep(width, bytes, words, i);
        }
        if (i < cells.len) {
            if (cells.len >= step) {
                widenStep(width, bytes, words, cells.len - step);
            } else {
                while (i < cells.len) : (i += 1) {
                    words[i] = width.extend(widenValue(width, bytes[i * size ..]));
                }
            }
        }
        return;
    }
    if (comptime native_matches_wire) {
        const words: [*]u64 = @ptrCast(cells.ptr);
        for (0..cells.len) |i| {
            words[i] = width.extend(widenValue(width, bytes[i * size ..]));
        }
        return;
    }
    for (cells, 0..) |*cell, i| {
        storeCell(cell, width.extend(widenValue(width, bytes[i * size ..])));
    }
}
inline fn widenStep(
    comptime width: Cell.EncodedWidth,
    bytes: []const u8,
    words: [*]u64,
    i: usize,
) void {
    const size = comptime width.size();
    const step = 16 / size;
    var in: @Vector(16, u8) = @as(
        *align(1) const @Vector(16, u8),
        @ptrCast(bytes[i * size ..].ptr),
    ).*;
    if (comptime width == .two) {
        const values: @Vector(8, u16) = @bitCast(in);
        const invalid = (values & @as(@Vector(8, u16), @splat(0xF800))) ==
            @as(@Vector(8, u16), @splat(0xD800));
        in = @bitCast(@select(
            u16,
            invalid,
            @as(@Vector(8, u16), @splat(0xFFFD)),
            values,
        ));
    }
    const zero: @Vector(16, u8) = @splat(0);
    inline for (0..step / 2) |pair| {
        const mask: @Vector(16, i32) = comptime mask: {
            var mask: [16]i32 = @splat(~@as(i32, 0));
            for (0..size) |byte| {
                mask[byte] = @intCast((2 * pair) * size + byte);
                mask[8 + byte] = @intCast((2 * pair + 1) * size + byte);
            }
            break :mask mask;
        };
        const lanes: @Vector(2, u64) = @bitCast(
            @shuffle(u8, in, zero, mask),
        );
        @as(
            *align(@alignOf(u64)) @Vector(2, u64),
            @ptrCast(words + i + 2 * pair),
        ).* = lanes << @splat(@bitOffsetOf(Cell, "content"));
    }
}
inline fn widenValue(
    comptime width: Cell.EncodedWidth,
    bytes: []const u8,
) width.Int() {
    const size = comptime width.size();
    const value = std.mem.readInt(width.Int(), bytes[0..size], .little);
    if (comptime width != .one) {
        if (!validScalar(value)) return 0xFFFD;
    }
    return value;
}
fn decodeWordCells(
    comptime width: Cell.EncodedWidth,
    page: *TerminalPage,
    row: *TerminalRow,
    cells: []TerminalCell,
    count: usize,
    reader: *std.Io.Reader,
    style_remap: *const StyleRemap,
    hyperlink_remap: *const HyperlinkRemap,
) DecodeError!u64 {
    const size = comptime width.size();
    var row_or: u64 = 0;
    const total = count * size;
    if (reader.bufferedLen() >= total) {
        const bytes = reader.buffered()[0..total];
        for (0..count) |x| {
            const bits = width.extend(std.mem.readInt(
                width.Int(),
                bytes[x * size ..][0..size],
                .little,
            ));
            row_or |= bits;
            applyCell(
                page,
                row,
                cells,
                x,
                bits,
                style_remap,
                hyperlink_remap,
            );
        }
        reader.toss(total);
        normalizeWideRow(width, row, cells, count, row_or);
        return row_or;
    }
    for (0..count) |x| {
        const bits = width.extend(try io.readInt(reader, width.Int()));
        row_or |= bits;
        applyCell(
            page,
            row,
            cells,
            x,
            bits,
            style_remap,
            hyperlink_remap,
        );
    }
    normalizeWideRow(width, row, cells, count, row_or);
    return row_or;
}
inline fn normalizeWideRow(
    comptime width: Cell.EncodedWidth,
    row: *const TerminalRow,
    cells: []TerminalCell,
    count: usize,
    row_or: u64,
) void {
    if (comptime width != .eight) return;
    const wide_mask: u64 = comptime @bitCast(Cell{ .width = 3 });
    if (row_or & wide_mask == 0) return;
    for (0..count) |x| normalizeWide(row, cells, x);
}
inline fn validScalar(cp: u32) bool {
    return cp <= 0x10FFFF and (cp < 0xD800 or cp > 0xDFFF);
}
fn applyCell(
    page: *TerminalPage,
    row: *TerminalRow,
    cells: []TerminalCell,
    x: usize,
    bits_wire: u64,
    style_remap: *const StyleRemap,
    hyperlink_remap: *const HyperlinkRemap,
) void {
    const cell = &cells[x];
    if (bits_wire == 0) {
        storeCell(cell, 0);
        return;
    }
    var wire: Cell = @bitCast(bits_wire);
    const link_encoded = wire.hyperlink_id;
    wire.hyperlink_id = 0;
    wire.hyperlink = false;
    switch (@as(Cell.Kind, @enumFromInt(wire.kind))) {
        .codepoint, .codepoint_grapheme => {
            wire.kind = @intFromEnum(Cell.Kind.codepoint);
            if (!validScalar(wire.content)) wire.content = 0xFFFD;
            if (wire.content == kitty_virtual_placeholder) {
                row.kitty_virtual_placeholder = true;
            }
        },
        .bg_color_palette => wire.content = @as(u8, @truncate(wire.content)),
        .bg_color_rgb => {},
    }
    wire.semantic_content = @intFromEnum(std.enums.fromInt(
        TerminalCell.SemanticContent,
        wire.semantic_content,
    ) orelse .output);
    if (wire.style_id != 0) {
        wire.style_id = style_remap.get(wire.style_id);
        if (wire.style_id != 0) {
            page.styles.use(page.memory, wire.style_id);
            row.styled = true;
        }
    }
    storeCell(cell, @bitCast(wire));
    if (link_encoded != 0) link: {
        const link_native = hyperlink_remap.get(link_encoded);
        if (link_native == 0) break :link;
        page.hyperlink_set.use(page.memory, link_native);
        page.setHyperlink(row, cell, link_native) catch {
            page.hyperlink_set.release(page.memory, link_native);
        };
    }
}
fn normalizeWide(row: *const TerminalRow, cells: []TerminalCell, x: usize) void {
    if (x > 0 and
        cells[x - 1].wide == .wide and
        cells[x].wide != .spacer_tail)
    {
        cells[x - 1].wide = .narrow;
    }
    switch (cells[x].wide) {
        .narrow => {},
        .wide => if (x + 1 == cells.len) {
            cells[x].wide = .narrow;
        },
        .spacer_tail => if (x == 0 or
            cells[x - 1].wide != .wide)
        {
            cells[x].wide = .narrow;
        },
        .spacer_head => if (x + 1 != cells.len or !row.wrap) {
            cells[x].wide = .narrow;
        },
    }
}
fn decodeGraphemes(
    page: *TerminalPage,
    reader: *std.Io.Reader,
) DecodeError!void {
    const entries = try io.readInt(reader, u32);
    for (0..entries) |_| {
        const y: u16, const x: u16, const cp_count: u16 = header: {
            if (reader.bufferedLen() >= 6) {
                const bytes = reader.buffered()[0..6];
                defer reader.toss(6);
                break :header .{
                    std.mem.readInt(u16, bytes[0..2], .little),
                    std.mem.readInt(u16, bytes[2..4], .little),
                    std.mem.readInt(u16, bytes[4..6], .little),
                };
            }
            break :header .{
                try io.readInt(reader, u16),
                try io.readInt(reader, u16),
                try io.readInt(reader, u16),
            };
        };
        const target: ?struct {
            row: *TerminalRow,
            cell: *TerminalCell,
        } = target: {
            if (y >= page.size.rows or x >= page.size.cols) {
                break :target null;
            }
            const row = page.getRow(y);
            const cell = &page.getCells(row)[x];
            if (cell.content_tag != .codepoint) break :target null;
            if (cell.content.codepoint.data == 0) break :target null;
            break :target .{ .row = row, .cell = cell };
        };
        const resolved = target orelse {
            try reader.discardAll(@as(usize, cp_count) * 4);
            continue;
        };
        var accept = true;
        var index: usize = 0;
        while (index < cp_count) {
            const buffered = reader.buffered();
            if (buffered.len >= 4) {
                const n = @min(cp_count - index, buffered.len / 4);
                for (0..n) |i| applyGraphemeSuffix(
                    page,
                    resolved.row,
                    resolved.cell,
                    &accept,
                    std.mem.readInt(u32, buffered[i * 4 ..][0..4], .little),
                );
                reader.toss(n * 4);
                index += n;
            } else {
                applyGraphemeSuffix(
                    page,
                    resolved.row,
                    resolved.cell,
                    &accept,
                    try io.readInt(reader, u32),
                );
                index += 1;
            }
        }
    }
}
fn applyGraphemeSuffix(
    page: *TerminalPage,
    row: *TerminalRow,
    cell: *TerminalCell,
    accept: *bool,
    cp: u32,
) void {
    if (!accept.*) return;
    if (cp == 0 or !validScalar(cp)) return;
    page.appendGrapheme(row, cell, @intCast(cp)) catch {
        if (cell.hasGrapheme()) {
            page.clearGrapheme(cell);
            page.updateRowGraphemeFlag(row);
        }
        accept.* = false;
    };
}
fn cellBits(cell: TerminalCell, link_id: TerminalHyperlinkId) u64 {
    if (comptime native_matches_wire) {
        var wire: Cell = @bitCast(cell);
        wire.hyperlink = link_id != 0;
        wire.hyperlink_id = link_id;
        return @bitCast(wire);
    }
    const wire: Cell = .{
        .kind = @intFromEnum(cell.content_tag),
        .content = switch (cell.content_tag) {
            .codepoint,
            .codepoint_grapheme,
            => cell.content.codepoint.data,
            .bg_color_palette => cell.content.color_palette.data,
            .bg_color_rgb => @as(u24, cell.content.color_rgb.r) |
                (@as(u24, cell.content.color_rgb.g) << 8) |
                (@as(u24, cell.content.color_rgb.b) << 16),
        },
        .style_id = cell.style_id,
        .width = switch (cell.wide) {
            .narrow => 0,
            .wide => 1,
            .spacer_tail => 2,
            .spacer_head => 3,
        },
        .protected = cell.protected,
        .hyperlink = link_id != 0,
        .semantic_content = switch (cell.semantic_content) {
            .output => 0,
            .input => 1,
            .prompt => 2,
        },
        .hyperlink_id = link_id,
    };
    return @bitCast(wire);
}
fn storeCell(cell: *TerminalCell, bits: u64) void {
    if (comptime native_matches_wire) {
        const words: [*]u64 = @ptrCast(cell);
        words[0] = bits;
        return;
    }
    const wire: Cell = @bitCast(bits);
    var native: TerminalCell = .init(0);
    switch (@as(Cell.Kind, @enumFromInt(wire.kind))) {
        .codepoint, .codepoint_grapheme => native.content = .{
            .codepoint = .{ .data = @intCast(wire.content) },
        },
        .bg_color_palette => {
            native.content_tag = .bg_color_palette;
            native.content = .{
                .color_palette = .{ .data = @truncate(wire.content) },
            };
        },
        .bg_color_rgb => {
            native.content_tag = .bg_color_rgb;
            native.content = .{ .color_rgb = .{
                .r = @truncate(wire.content),
                .g = @truncate(wire.content >> 8),
                .b = @truncate(wire.content >> 16),
            } };
        },
    }
    native.style_id = wire.style_id;
    native.wide = @enumFromInt(wire.width);
    native.protected = wire.protected;
    native.semantic_content = @enumFromInt(wire.semantic_content);
    cell.* = native;
}
fn Remap(comptime Id: type) type {
    return struct {
        const Self = @This();
        pub const capacity = std.math.maxInt(Id) + 1;
        entries: []Id,
        seen: std.DynamicBitSetUnmanaged,
        pub const empty: Self = .{ .entries = &.{}, .seen = .{} };
        pub fn init(alloc: Allocator) Allocator.Error!Self {
            const entries = try alloc.alloc(Id, capacity);
            errdefer alloc.free(entries);
            @memset(entries, 0);
            const seen = try std.DynamicBitSetUnmanaged.initEmpty(
                alloc,
                capacity,
            );
            return .{ .entries = entries, .seen = seen };
        }
        pub fn deinit(self: *Self, alloc: Allocator) void {
            if (self.entries.len != 0) {
                alloc.free(self.entries);
                self.seen.deinit(alloc);
            }
            self.* = undefined;
        }
        pub fn put(self: *Self, encoded: Id, native: Id) void {
            assert(!self.seen.isSet(encoded));
            self.entries[encoded] = native;
            self.seen.set(encoded);
        }
        pub fn contains(self: *const Self, encoded: Id) bool {
            return self.seen.isSet(encoded);
        }
        pub inline fn get(self: *const Self, encoded: Id) Id {
            if (self.entries.len == 0) return 0;
            return self.entries[encoded];
        }
    };
}
const test_golden_fixture = test_fixture.parse(
    @embedFile("testdata/grid-v1.hex"),
);
test "cell wire layout registry" {
    const testing = std.testing;
    try testing.expectEqual(0, @bitOffsetOf(Cell, "kind"));
    try testing.expectEqual(2, @bitOffsetOf(Cell, "content"));
    try testing.expectEqual(26, @bitOffsetOf(Cell, "style_id"));
    try testing.expectEqual(42, @bitOffsetOf(Cell, "width"));
    try testing.expectEqual(44, @bitOffsetOf(Cell, "protected"));
    try testing.expectEqual(45, @bitOffsetOf(Cell, "hyperlink"));
    try testing.expectEqual(46, @bitOffsetOf(Cell, "semantic_content"));
    try testing.expectEqual(48, @bitOffsetOf(Cell, "hyperlink_id"));
    try testing.expect(native_matches_wire);
}
test "encoded cell width transport registry" {
    const testing = std.testing;
    const word: u64 = @bitCast(Cell{
        .kind = 1,
        .content = 0xABCDEF,
        .style_id = 0x1234,
        .hyperlink_id = 0x5678,
    });
    try testing.expectEqual(@as(u8, 0xEF), Cell.EncodedWidth.one.truncate(word));
    try testing.expectEqual(@as(u16, 0xCDEF), Cell.EncodedWidth.two.truncate(word));
    try testing.expectEqual(
        @as(u32, @truncate(word)),
        Cell.EncodedWidth.four.truncate(word),
    );
    try testing.expectEqual(word, Cell.EncodedWidth.eight.truncate(word));
    try testing.expectEqual(
        @as(u64, 0x0000_0000_0000_03FC),
        Cell.EncodedWidth.one.mask(),
    );
    try testing.expectEqual(
        @as(u64, 0x0000_0000_0003_FFFC),
        Cell.EncodedWidth.two.mask(),
    );
    try testing.expectEqual(
        @as(u64, 0x0000_0000_FFFF_FFFF),
        Cell.EncodedWidth.four.mask(),
    );
    try testing.expectEqual(
        @as(u64, 0xFFFF_FFFF_FFFF_FFFF),
        Cell.EncodedWidth.eight.mask(),
    );
    const cases = [_]struct { cell: Cell, width: Cell.EncodedWidth }{
        .{ .cell = .{}, .width = .one },
        .{ .cell = .{ .content = 0xFF }, .width = .one },
        .{ .cell = .{ .content = 0x100 }, .width = .two },
        .{ .cell = .{ .content = 0xFFFF }, .width = .two },
        .{ .cell = .{ .content = 0x10000 }, .width = .four },
        .{ .cell = .{ .kind = 2, .content = 7 }, .width = .four },
        .{ .cell = .{ .content = 'a', .style_id = 63 }, .width = .four },
        .{ .cell = .{ .content = 'a', .style_id = 64 }, .width = .eight },
        .{ .cell = .{ .width = 1, .content = 'a' }, .width = .eight },
        .{ .cell = .{ .protected = true }, .width = .eight },
        .{ .cell = .{ .semantic_content = 1 }, .width = .eight },
        .{ .cell = .{ .hyperlink = true, .hyperlink_id = 1 }, .width = .eight },
    };
    inline for (cases) |case| {
        const case_word: u64 = @bitCast(case.cell);
        try testing.expectEqual(
            case.width,
            Cell.EncodedWidth.select(case_word),
        );
        try testing.expectEqual(
            case_word,
            case.width.extend(case.width.truncate(case_word)),
        );
    }
}
test "grid golden encoding and decoding" {
    const capacity: terminal_page.Capacity = .{
        .cols = 3,
        .rows = 4,
        .styles = 0,
        .hyperlink_bytes = 0,
        .grapheme_bytes = 64,
        .string_bytes = 0,
    };
    var source = try TerminalPage.init(capacity);
    defer source.deinit();
    const wide = source.getRowAndCell(0, 0);
    wide.row.semantic_prompt = .prompt;
    wide.cell.* = .init('A');
    wide.cell.wide = .wide;
    wide.cell.protected = true;
    wide.cell.semantic_content = .prompt;
    const tail = source.getRowAndCell(1, 0);
    tail.cell.wide = .spacer_tail;
    tail.cell.semantic_content = .input;
    const grapheme = source.getRowAndCell(2, 0);
    grapheme.cell.* = .init('x');
    try source.setGraphemes(
        grapheme.row,
        grapheme.cell,
        &.{ 0x0301, 0x0302 },
    );
    const palette = source.getRowAndCell(0, 1);
    palette.cell.content_tag = .bg_color_palette;
    palette.cell.content = .{ .color_palette = .{ .data = 7 } };
    const rgb = source.getRowAndCell(1, 1);
    rgb.cell.content_tag = .bg_color_rgb;
    rgb.cell.content = .{ .color_rgb = .{
        .r = 0xaa,
        .g = 0xbb,
        .b = 0xcc,
    } };
    rgb.cell.protected = true;
    const head = source.getRowAndCell(2, 1);
    head.cell.wide = .spacer_head;
    head.row.wrap = true;
    head.row.wrap_continuation = true;
    head.row.semantic_prompt = .prompt_continuation;
    source.getRowAndCell(0, 2).cell.* = .init('h');
    source.getRowAndCell(2, 2).cell.* = .init('i');
    source.getRowAndCell(0, 3).cell.* = .init(0x0416); 
    source.getRowAndCell(1, 3).cell.* = .init('!');
    var encoded: [160]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try encode(&source, &writer);
    try test_fixture.expectEqual(
        .bytes,
        "src/terminal/snapshot/testdata/grid-v1.hex",
        "snapshot_fixture-grid-v1.hex",
        &test_golden_fixture,
        writer.buffered(),
    );
    var destination = try TerminalPage.init(capacity);
    defer destination.deinit();
    var style_remap = try StyleRemap.init(std.testing.allocator);
    defer style_remap.deinit(std.testing.allocator);
    var hyperlink_remap = try HyperlinkRemap.init(std.testing.allocator);
    defer hyperlink_remap.deinit(std.testing.allocator);
    var fixture_reader: std.Io.Reader = .fixed(&test_golden_fixture);
    var read_buffer: [1]u8 = undefined;
    var limited = fixture_reader.limited(.unlimited, &read_buffer);
    try decode(
        &destination,
        &limited.interface,
        &style_remap,
        &hyperlink_remap,
    );
    try destination.verifyIntegrity(std.testing.allocator);
    const decoded_wide = destination.getRowAndCell(0, 0);
    try std.testing.expectEqual(@as(u21, 'A'), decoded_wide.cell.codepoint());
    try std.testing.expectEqual(TerminalCell.Wide.wide, decoded_wide.cell.wide);
    try std.testing.expect(decoded_wide.cell.protected);
    try std.testing.expectEqual(
        TerminalCell.SemanticContent.prompt,
        decoded_wide.cell.semantic_content,
    );
    try std.testing.expectEqual(
        TerminalRow.SemanticPrompt.prompt,
        decoded_wide.row.semantic_prompt,
    );
    const decoded_tail = destination.getRowAndCell(1, 0);
    try std.testing.expectEqual(
        TerminalCell.Wide.spacer_tail,
        decoded_tail.cell.wide,
    );
    try std.testing.expectEqual(
        TerminalCell.SemanticContent.input,
        decoded_tail.cell.semantic_content,
    );
    const decoded_grapheme = destination.getRowAndCell(2, 0);
    try std.testing.expectEqualSlices(
        u21,
        &.{ 0x0301, 0x0302 },
        destination.lookupGrapheme(decoded_grapheme.cell).?,
    );
    const decoded_palette = destination.getRowAndCell(0, 1);
    try std.testing.expectEqual(
        TerminalCell.ContentTag.bg_color_palette,
        decoded_palette.cell.content_tag,
    );
    try std.testing.expectEqual(
        @as(u8, 7),
        decoded_palette.cell.content.color_palette.data,
    );
    const decoded_rgb = destination.getRowAndCell(1, 1);
    try std.testing.expectEqual(
        TerminalCell.ContentTag.bg_color_rgb,
        decoded_rgb.cell.content_tag,
    );
    try std.testing.expectEqual(
        TerminalCell.RGB{ .r = 0xaa, .g = 0xbb, .b = 0xcc },
        decoded_rgb.cell.content.color_rgb,
    );
    try std.testing.expect(decoded_rgb.cell.protected);
    const decoded_head = destination.getRowAndCell(2, 1);
    try std.testing.expectEqual(
        TerminalCell.Wide.spacer_head,
        decoded_head.cell.wide,
    );
    try std.testing.expect(decoded_head.row.wrap);
    try std.testing.expect(decoded_head.row.wrap_continuation);
    try std.testing.expectEqual(
        TerminalRow.SemanticPrompt.prompt_continuation,
        decoded_head.row.semantic_prompt,
    );
    try std.testing.expectEqual(
        @as(u21, 'h'),
        destination.getRowAndCell(0, 2).cell.codepoint(),
    );
    try std.testing.expect(destination.getRowAndCell(1, 2).cell.isZero());
    try std.testing.expectEqual(
        @as(u21, 'i'),
        destination.getRowAndCell(2, 2).cell.codepoint(),
    );
    try std.testing.expectEqual(
        @as(u21, 0x0416),
        destination.getRowAndCell(0, 3).cell.codepoint(),
    );
    try std.testing.expectEqual(
        @as(u21, '!'),
        destination.getRowAndCell(1, 3).cell.codepoint(),
    );
    var reencoded: [160]u8 = undefined;
    var rewriter: std.Io.Writer = .fixed(&reencoded);
    try encode(&destination, &rewriter);
    try std.testing.expectEqualStrings(
        &test_golden_fixture,
        rewriter.buffered(),
    );
}
test "grid elides trailing default cells" {
    const testing = std.testing;
    var page = try TerminalPage.init(.{ .cols = 80, .rows = 3 });
    defer page.deinit();
    const middle = page.getRowAndCell(2, 1);
    middle.cell.* = .init('b');
    page.getRowAndCell(0, 1).cell.* = .init('a');
    page.getRowAndCell(4, 2).cell.protected = true;
    var encoded: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try encode(&page, &writer);
    try testing.expectEqual(
        @as(usize, 3 + (3 + 3 * 1) + (3 + 5 * 8) + 4),
        writer.buffered().len,
    );
    var destination = try TerminalPage.init(.{ .cols = 80, .rows = 3 });
    defer destination.deinit();
    var style_remap = try StyleRemap.init(testing.allocator);
    defer style_remap.deinit(testing.allocator);
    var hyperlink_remap = try HyperlinkRemap.init(testing.allocator);
    defer hyperlink_remap.deinit(testing.allocator);
    var reader: std.Io.Reader = .fixed(writer.buffered());
    try decode(&destination, &reader, &style_remap, &hyperlink_remap);
    try destination.verifyIntegrity(testing.allocator);
    try testing.expectEqual(
        @as(u21, 'a'),
        destination.getRowAndCell(0, 1).cell.codepoint(),
    );
    try testing.expectEqual(
        @as(u21, 'b'),
        destination.getRowAndCell(2, 1).cell.codepoint(),
    );
    try testing.expect(destination.getRowAndCell(4, 2).cell.protected);
    try testing.expect(destination.getRowAndCell(79, 1).cell.isZero());
}
test "grid rejects a row cell count above the column count" {
    const testing = std.testing;
    var page = try TerminalPage.init(.{ .cols = 2, .rows = 1 });
    defer page.deinit();
    var style_remap = try StyleRemap.init(testing.allocator);
    defer style_remap.deinit(testing.allocator);
    var hyperlink_remap = try HyperlinkRemap.init(testing.allocator);
    defer hyperlink_remap.deinit(testing.allocator);
    var payload: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&payload);
    try writer.writeByte(@bitCast(Row{}));
    try io.writeInt(&writer, u16, 3);
    for (0..3) |_| try io.writeInt(&writer, u64, 0);
    try io.writeInt(&writer, u32, 0);
    var reader: std.Io.Reader = .fixed(writer.buffered());
    try testing.expectError(
        error.InvalidRowCellCount,
        decode(&page, &reader, &style_remap, &hyperlink_remap),
    );
}
test "grid normalizes incomplete wide cells" {
    const testing = std.testing;
    for ([_]u16{ 1, 2 }) |columns| {
        const capacity: terminal_page.Capacity = .{
            .cols = columns,
            .rows = 1,
        };
        var payload: [64]u8 = undefined;
        var payload_writer: std.Io.Writer = .fixed(&payload);
        try payload_writer.writeByte(@bitCast(Row{ .cell_width = .eight }));
        try io.writeInt(&payload_writer, u16, columns);
        try io.writeInt(&payload_writer, u64, @bitCast(Cell{
            .width = 1, 
            .content = 'A',
        }));
        if (columns > 1) try io.writeInt(&payload_writer, u64, @bitCast(Cell{
            .content = 'B',
        }));
        try io.writeInt(&payload_writer, u32, 0);
        var destination = try TerminalPage.init(capacity);
        defer destination.deinit();
        var style_remap = try StyleRemap.init(testing.allocator);
        defer style_remap.deinit(testing.allocator);
        var hyperlink_remap = try HyperlinkRemap.init(testing.allocator);
        defer hyperlink_remap.deinit(testing.allocator);
        var payload_reader: std.Io.Reader = .fixed(
            payload_writer.buffered(),
        );
        try decode(
            &destination,
            &payload_reader,
            &style_remap,
            &hyperlink_remap,
        );
        try destination.verifyIntegrity(testing.allocator);
        try testing.expectEqual(
            @as(u21, 'A'),
            destination.getRowAndCell(0, 0).cell.codepoint(),
        );
        try testing.expectEqual(
            TerminalCell.Wide.narrow,
            destination.getRowAndCell(0, 0).cell.wide,
        );
        if (columns > 1) {
            const second = destination.getRowAndCell(1, 0).cell;
            try testing.expectEqual(@as(u21, 'B'), second.codepoint());
            try testing.expectEqual(TerminalCell.Wide.narrow, second.wide);
        }
    }
    var page = try TerminalPage.init(.{ .cols = 4, .rows = 1 });
    defer page.deinit();
    var style_remap = try StyleRemap.init(testing.allocator);
    defer style_remap.deinit(testing.allocator);
    var hyperlink_remap = try HyperlinkRemap.init(testing.allocator);
    defer hyperlink_remap.deinit(testing.allocator);
    var payload: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&payload);
    try writer.writeByte(@bitCast(Row{ .cell_width = .eight }));
    try io.writeInt(&writer, u16, 1);
    try io.writeInt(&writer, u64, @bitCast(Cell{
        .width = 1, 
        .content = 'W',
    }));
    try io.writeInt(&writer, u32, 0);
    var reader: std.Io.Reader = .fixed(writer.buffered());
    try decode(&page, &reader, &style_remap, &hyperlink_remap);
    try page.verifyIntegrity(testing.allocator);
    try testing.expectEqual(
        TerminalCell.Wide.narrow,
        page.getRowAndCell(0, 0).cell.wide,
    );
    try testing.expect(page.getRowAndCell(1, 0).cell.isZero());
}
test "grid normalizes reserved cell values" {
    const testing = std.testing;
    var page = try TerminalPage.init(.{ .cols = 3, .rows = 1 });
    defer page.deinit();
    var style_remap = try StyleRemap.init(testing.allocator);
    defer style_remap.deinit(testing.allocator);
    var hyperlink_remap = try HyperlinkRemap.init(testing.allocator);
    defer hyperlink_remap.deinit(testing.allocator);
    var payload: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&payload);
    try writer.writeByte(0xFD);
    try io.writeInt(&writer, u16, 3);
    try io.writeInt(&writer, u64, @bitCast(Cell{
        .content = 0xD800,
        .semantic_content = 3,
    }));
    try io.writeInt(&writer, u64, @bitCast(Cell{
        .kind = 2,
        .content = 0xFFFF07,
    }));
    try io.writeInt(&writer, u64, @bitCast(Cell{
        .content = 'x',
        .style_id = 5,
        .hyperlink = true,
        .hyperlink_id = 9,
    }));
    try io.writeInt(&writer, u32, 0);
    var reader: std.Io.Reader = .fixed(writer.buffered());
    try decode(&page, &reader, &style_remap, &hyperlink_remap);
    try page.verifyIntegrity(testing.allocator);
    const first = page.getRowAndCell(0, 0);
    try testing.expect(first.row.wrap);
    try testing.expectEqual(
        TerminalRow.SemanticPrompt.none,
        first.row.semantic_prompt,
    );
    try testing.expectEqual(@as(u21, 0xFFFD), first.cell.codepoint());
    try testing.expectEqual(
        TerminalCell.SemanticContent.output,
        first.cell.semantic_content,
    );
    const second = page.getRowAndCell(1, 0).cell;
    try testing.expectEqual(
        TerminalCell.ContentTag.bg_color_palette,
        second.content_tag,
    );
    try testing.expectEqual(@as(u8, 7), second.content.color_palette.data);
    const third = page.getRowAndCell(2, 0).cell;
    try testing.expectEqual(@as(u21, 'x'), third.codepoint());
    try testing.expectEqual(@as(TerminalStyleId, 0), third.style_id);
    try testing.expect(!third.hyperlink);
    try testing.expectEqual(null, page.lookupHyperlink(third));
}
test "grid drops undeliverable grapheme entries" {
    const testing = std.testing;
    var page = try TerminalPage.init(.{
        .cols = 4,
        .rows = 1,
        .grapheme_bytes = 64,
    });
    defer page.deinit();
    var style_remap = try StyleRemap.init(testing.allocator);
    defer style_remap.deinit(testing.allocator);
    var hyperlink_remap = try HyperlinkRemap.init(testing.allocator);
    defer hyperlink_remap.deinit(testing.allocator);
    var payload: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&payload);
    try writer.writeByte(@bitCast(Row{ .cell_width = .eight }));
    try io.writeInt(&writer, u16, 4);
    try io.writeInt(&writer, u64, @bitCast(Cell{ .kind = 1, .content = 'x' }));
    try io.writeInt(&writer, u64, @bitCast(Cell{ .kind = 1, .content = 'y' }));
    try io.writeInt(&writer, u64, @bitCast(Cell{ .kind = 2, .content = 7 }));
    try io.writeInt(&writer, u64, @bitCast(Cell{}));
    try io.writeInt(&writer, u32, 5);
    try io.writeInt(&writer, u16, 0);
    try io.writeInt(&writer, u16, 0);
    try io.writeInt(&writer, u16, 4);
    try io.writeInt(&writer, u32, 0x0301);
    try io.writeInt(&writer, u32, 0);
    try io.writeInt(&writer, u32, 0xD800);
    try io.writeInt(&writer, u32, 0x0302);
    try io.writeInt(&writer, u16, 0);
    try io.writeInt(&writer, u16, 0);
    try io.writeInt(&writer, u16, 1);
    try io.writeInt(&writer, u32, 0x0303);
    try io.writeInt(&writer, u16, 0);
    try io.writeInt(&writer, u16, 2);
    try io.writeInt(&writer, u16, 1);
    try io.writeInt(&writer, u32, 0x0301);
    try io.writeInt(&writer, u16, 0);
    try io.writeInt(&writer, u16, 3);
    try io.writeInt(&writer, u16, 1);
    try io.writeInt(&writer, u32, 0x0301);
    try io.writeInt(&writer, u16, 7);
    try io.writeInt(&writer, u16, 0);
    try io.writeInt(&writer, u16, 1);
    try io.writeInt(&writer, u32, 0x0301);
    var reader: std.Io.Reader = .fixed(writer.buffered());
    try decode(&page, &reader, &style_remap, &hyperlink_remap);
    try page.verifyIntegrity(testing.allocator);
    const first = page.getRowAndCell(0, 0);
    try testing.expectEqualSlices(
        u21,
        &.{ 0x0301, 0x0302 },
        page.lookupGrapheme(first.cell).?,
    );
    const second = page.getRowAndCell(1, 0).cell;
    try testing.expectEqual(@as(u21, 'y'), second.codepoint());
    try testing.expect(!second.hasGrapheme());
    try testing.expect(!page.getRowAndCell(2, 0).cell.hasGrapheme());
    try testing.expect(!page.getRowAndCell(3, 0).cell.hasGrapheme());
}
test "grid drops a complete grapheme when capacity fails mid-cluster" {
    const testing = std.testing;
    var page = try TerminalPage.init(.{
        .cols = 4,
        .rows = 1,
        .grapheme_bytes = 512,
    });
    defer page.deinit();
    var style_remap = try StyleRemap.init(testing.allocator);
    defer style_remap.deinit(testing.allocator);
    var hyperlink_remap = try HyperlinkRemap.init(testing.allocator);
    defer hyperlink_remap.deinit(testing.allocator);
    var payload: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&payload);
    try writer.writeByte(@bitCast(Row{ .cell_width = .eight }));
    try io.writeInt(&writer, u16, 4);
    for (0..4) |i| try io.writeInt(
        &writer,
        u64,
        @bitCast(Cell{ .kind = 1, .content = @intCast('x' + i) }),
    );
    try io.writeInt(&writer, u32, 4);
    for ([_]u16{ 64, 64, 8, 61 }, 0..) |count, x| {
        try io.writeInt(&writer, u16, 0);
        try io.writeInt(&writer, u16, @intCast(x));
        try io.writeInt(&writer, u16, count);
        for (0..count) |i| try io.writeInt(
            &writer,
            u32,
            @intCast(0x0300 + i),
        );
    }
    var reader: std.Io.Reader = .fixed(writer.buffered());
    try decode(&page, &reader, &style_remap, &hyperlink_remap);
    try page.verifyIntegrity(testing.allocator);
    const cell = page.getRowAndCell(3, 0);
    try testing.expectEqual(@as(u21, @intCast('x' + 3)), cell.cell.codepoint());
    try testing.expect(!cell.cell.hasGrapheme());
    try testing.expect(cell.row.grapheme);
    try testing.expectEqual(@as(usize, 3), page.graphemeCount());
}
test "grid encodes rows at their narrowest width" {
    const testing = std.testing;
    var page = try TerminalPage.init(.{
        .cols = 2,
        .rows = 4,
        .styles = 8,
    });
    defer page.deinit();
    page.getRowAndCell(0, 0).cell.* = .init('A');
    page.getRowAndCell(1, 0).cell.* = .init(0xFF);
    page.getRowAndCell(0, 1).cell.* = .init(0x0100);
    const style_id = try page.styles.add(page.memory, .{
        .flags = .{ .bold = true },
    });
    try testing.expect(style_id <= 63);
    const styled = page.getRowAndCell(0, 2);
    styled.cell.* = .init('s');
    styled.cell.style_id = style_id;
    styled.row.styled = true;
    const bg = page.getRowAndCell(1, 2);
    bg.cell.content_tag = .bg_color_palette;
    bg.cell.content = .{ .color_palette = .{ .data = 7 } };
    page.getRowAndCell(0, 3).cell.protected = true;
    var encoded: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try encode(&page, &writer);
    const bytes = writer.buffered();
    try testing.expectEqual(
        @as(usize, (3 + 2 * 1) + (3 + 1 * 2) + (3 + 2 * 4) + (3 + 1 * 8) + 4),
        bytes.len,
    );
    try testing.expectEqual(@as(u8, 0 << 4), bytes[0] & 0x30);
    try testing.expectEqual(@as(u8, 1 << 4), bytes[5] & 0x30);
    try testing.expectEqual(@as(u8, 2 << 4), bytes[10] & 0x30);
    try testing.expectEqual(@as(u8, 3 << 4), bytes[21] & 0x30);
    var destination = try TerminalPage.init(.{
        .cols = 2,
        .rows = 4,
        .styles = 8,
    });
    defer destination.deinit();
    var style_remap = try StyleRemap.init(testing.allocator);
    defer style_remap.deinit(testing.allocator);
    var hyperlink_remap = try HyperlinkRemap.init(testing.allocator);
    defer hyperlink_remap.deinit(testing.allocator);
    const native_style = try destination.styles.add(destination.memory, .{
        .flags = .{ .bold = true },
    });
    style_remap.put(style_id, native_style);
    var reader: std.Io.Reader = .fixed(bytes);
    try decode(&destination, &reader, &style_remap, &hyperlink_remap);
    try destination.verifyIntegrity(testing.allocator);
    try testing.expectEqual(
        @as(u21, 'A'),
        destination.getRowAndCell(0, 0).cell.codepoint(),
    );
    try testing.expectEqual(
        @as(u21, 0xFF),
        destination.getRowAndCell(1, 0).cell.codepoint(),
    );
    try testing.expectEqual(
        @as(u21, 0x0100),
        destination.getRowAndCell(0, 1).cell.codepoint(),
    );
    const decoded_styled = destination.getRowAndCell(0, 2);
    try testing.expectEqual(@as(u21, 's'), decoded_styled.cell.codepoint());
    try testing.expectEqual(native_style, decoded_styled.cell.style_id);
    try testing.expect(decoded_styled.row.styled);
    try testing.expectEqual(
        @as(u8, 7),
        destination.getRowAndCell(1, 2).cell.content.color_palette.data,
    );
    try testing.expect(destination.getRowAndCell(0, 3).cell.protected);
}
test "grid decodes non-canonical cell widths" {
    const testing = std.testing;
    var page = try TerminalPage.init(.{ .cols = 2, .rows = 1 });
    defer page.deinit();
    var style_remap = try StyleRemap.init(testing.allocator);
    defer style_remap.deinit(testing.allocator);
    var hyperlink_remap = try HyperlinkRemap.init(testing.allocator);
    defer hyperlink_remap.deinit(testing.allocator);
    var payload: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&payload);
    try writer.writeByte(@bitCast(Row{ .cell_width = .eight }));
    try io.writeInt(&writer, u16, 2);
    try io.writeInt(&writer, u64, @bitCast(Cell{ .content = 'o' }));
    try io.writeInt(&writer, u64, @bitCast(Cell{ .content = 'k' }));
    try io.writeInt(&writer, u32, 0);
    var reader: std.Io.Reader = .fixed(writer.buffered());
    try decode(&page, &reader, &style_remap, &hyperlink_remap);
    try page.verifyIntegrity(testing.allocator);
    try testing.expectEqual(
        @as(u21, 'o'),
        page.getRowAndCell(0, 0).cell.codepoint(),
    );
    try testing.expectEqual(
        @as(u21, 'k'),
        page.getRowAndCell(1, 0).cell.codepoint(),
    );
    var reencoded: [16]u8 = undefined;
    var rewriter: std.Io.Writer = .fixed(&reencoded);
    try encode(&page, &rewriter);
    try testing.expectEqual(@as(usize, 3 + 2 + 4), rewriter.buffered().len);
}
test "grid normalizes surrogates in two-byte cells" {
    const testing = std.testing;
    var page = try TerminalPage.init(.{ .cols = 2, .rows = 1 });
    defer page.deinit();
    var style_remap = try StyleRemap.init(testing.allocator);
    defer style_remap.deinit(testing.allocator);
    var hyperlink_remap = try HyperlinkRemap.init(testing.allocator);
    defer hyperlink_remap.deinit(testing.allocator);
    var payload: [16]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&payload);
    try writer.writeByte(@bitCast(Row{ .cell_width = .two }));
    try io.writeInt(&writer, u16, 2);
    try io.writeInt(&writer, u16, 0xD800);
    try io.writeInt(&writer, u16, 0x0416);
    try io.writeInt(&writer, u32, 0);
    var reader: std.Io.Reader = .fixed(writer.buffered());
    try decode(&page, &reader, &style_remap, &hyperlink_remap);
    try page.verifyIntegrity(testing.allocator);
    try testing.expectEqual(
        @as(u21, 0xFFFD),
        page.getRowAndCell(0, 0).cell.codepoint(),
    );
    try testing.expectEqual(
        @as(u21, 0x0416),
        page.getRowAndCell(1, 0).cell.codepoint(),
    );
}
test "grid four-byte cells run full normalization" {
    const testing = std.testing;
    var page = try TerminalPage.init(.{
        .cols = 3,
        .rows = 1,
        .styles = 8,
    });
    defer page.deinit();
    var style_remap = try StyleRemap.init(testing.allocator);
    defer style_remap.deinit(testing.allocator);
    var hyperlink_remap = try HyperlinkRemap.init(testing.allocator);
    defer hyperlink_remap.deinit(testing.allocator);
    var payload: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&payload);
    try writer.writeByte(@bitCast(Row{ .cell_width = .four }));
    try io.writeInt(&writer, u16, 3);
    try io.writeInt(&writer, u32, @truncate(@as(u64, @bitCast(Cell{
        .content = kitty_virtual_placeholder,
    }))));
    try io.writeInt(&writer, u32, @truncate(@as(u64, @bitCast(Cell{
        .content = 'x',
        .style_id = 63,
    }))));
    try io.writeInt(&writer, u32, @truncate(@as(u64, @bitCast(Cell{
        .kind = 2,
        .content = 0xFFFF07,
    }))));
    try io.writeInt(&writer, u32, 0);
    var reader: std.Io.Reader = .fixed(writer.buffered());
    try decode(&page, &reader, &style_remap, &hyperlink_remap);
    try page.verifyIntegrity(testing.allocator);
    const first = page.getRowAndCell(0, 0);
    try testing.expectEqual(
        kitty_virtual_placeholder,
        first.cell.codepoint(),
    );
    try testing.expect(first.row.kitty_virtual_placeholder);
    const second = page.getRowAndCell(1, 0).cell;
    try testing.expectEqual(@as(u21, 'x'), second.codepoint());
    try testing.expectEqual(@as(TerminalStyleId, 0), second.style_id);
    const third = page.getRowAndCell(2, 0).cell;
    try testing.expectEqual(
        TerminalCell.ContentTag.bg_color_palette,
        third.content_tag,
    );
    try testing.expectEqual(@as(u8, 7), third.content.color_palette.data);
}
