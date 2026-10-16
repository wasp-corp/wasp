const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const font = @import("../main.zig");
const shape = @import("../shape.zig");
const terminal = @import("../../terminal/main.zig");
const autoHash = std.hash.autoHash;
const Hasher = std.hash.Wyhash;
pub const TextRun = struct {
    hash: u64,
    offset: u16,
    cells: u16,
    grid: *font.SharedGrid,
    font_index: font.Collection.Index,
};
pub const RunIterator = struct {
    hooks: font.Shaper.RunIteratorHook,
    opts: shape.RunOptions,
    i: usize = 0,
    pub fn next(self: *RunIterator, alloc: Allocator) !?TextRun {
        const slice = &self.opts.cells;
        const cells: []const terminal.page.Cell = slice.items(.raw);
        const graphemes: []const []const u21 = slice.items(.grapheme);
        const styles: []const terminal.Style = slice.items(.style);
        const max: usize = max: {
            for (0..cells.len) |i| {
                const rev_i = cells.len - i - 1;
                if (!cells[rev_i].isEmpty()) break :max rev_i + 1;
            }
            break :max 0;
        };
        while (self.i < max and
            (cells[self.i].hasStyling() and
                styles[self.i].flags.invisible)) self.i += 1;
        if (self.i >= max) return null;
        var current_font: font.Collection.Index = .{};
        self.hooks.prepare();
        var hasher = Hasher.init(0);
        const style: terminal.Style = if (cells[self.i].hasStyling()) styles[self.i] else .{};
        var j: usize = self.i;
        while (j < max) : (j += 1) {
            const cluster = j - self.i;
            const cell: *const terminal.page.Cell = &cells[j];
            if (self.opts.selection) |bounds| {
                if (j > self.i) {
                    if (bounds[0] > 0 and j == bounds[0]) break;
                    if (bounds[1] > 0 and j == bounds[1] + 1) break;
                }
            }
            switch (cell.wide) {
                .narrow, .wide => {},
                .spacer_head, .spacer_tail => continue,
            }
            if (j > self.i) style: {
                const prev_cell = cells[j - 1];
                if (prev_cell.content_tag == .codepoint and
                    cell.content_tag == .codepoint)
                {
                    const prev_cp = prev_cell.codepoint();
                    switch (prev_cp) {
                        'f' => {
                            const cp = cell.codepoint();
                            if (cp == 'l' or cp == 'i') break;
                        },
                        's' => {
                            const cp = cell.codepoint();
                            if (cp == 't') break;
                        },
                        else => {},
                    }
                }
                if (prev_cell.style_id == cell.style_id) break :style;
                const c1 = comparableStyle(style);
                const c2 = comparableStyle(if (cell.hasStyling()) styles[j] else .{});
                if (!c1.eql(c2)) break;
            }
            const font_style: font.Style = style: {
                if (style.flags.bold) {
                    if (style.flags.italic) break :style .bold_italic;
                    break :style .bold;
                }
                if (style.flags.italic) break :style .italic;
                break :style .regular;
            };
            const presentation: ?font.Presentation = if (cell.hasGrapheme()) p: {
                const cps = graphemes[j];
                assert(cps.len > 0);
                if (cps[0] == 0xFE0E) break :p .text;
                if (cps[0] == 0xFE0F) break :p .emoji;
                break :p null;
            } else emoji: {
                break :emoji null;
            };
            if (!cell.hasGrapheme()) {
                if (self.opts.cursor_x) |cursor_x| {
                    if (self.i == cursor_x and j == self.i + 1) break;
                    if (self.i < cursor_x and j == cursor_x) {
                        assert(j > 0);
                        break;
                    }
                }
            }
            const font_info: struct {
                idx: font.Collection.Index,
                fallback: ?u32 = null,
            } = font_info: {
                if (try self.indexForCell(
                    alloc,
                    cell,
                    graphemes[j],
                    font_style,
                    presentation,
                )) |idx| break :font_info .{ .idx = idx };
                if (try self.opts.grid.getIndex(
                    alloc,
                    0xFFFD, 
                    font_style,
                    presentation,
                )) |idx| break :font_info .{ .idx = idx, .fallback = 0xFFFD };
                if (try self.opts.grid.getIndex(
                    alloc,
                    ' ',
                    font_style,
                    presentation,
                )) |idx| break :font_info .{ .idx = idx, .fallback = ' ' };
                unreachable;
            };
            if (j == self.i) current_font = font_info.idx;
            if (font_info.idx != current_font) break;
            if (font_info.fallback) |cp| {
                try self.addCodepoint(&hasher, cp, @intCast(cluster));
                continue;
            }
            if (cell.codepoint() == terminal.kitty.graphics.unicode.placeholder) {
                try self.addCodepoint(&hasher, ' ', @intCast(cluster));
                continue;
            }
            try self.addCodepoint(
                &hasher,
                if (cell.codepoint() == 0) ' ' else cell.codepoint(),
                @intCast(cluster),
            );
            if (cell.hasGrapheme()) {
                for (graphemes[j]) |cp| {
                    if (cp == 0xFE0E or cp == 0xFE0F) continue;
                    try self.addCodepoint(&hasher, cp, @intCast(cluster));
                }
            }
        }
        self.hooks.finalize();
        autoHash(&hasher, j - self.i);
        autoHash(&hasher, current_font);
        defer self.i = j;
        return .{
            .hash = hasher.final(),
            .offset = @intCast(self.i),
            .cells = @intCast(j - self.i),
            .grid = self.opts.grid,
            .font_index = current_font,
        };
    }
    fn addCodepoint(self: *RunIterator, hasher: anytype, cp: u32, cluster: u32) !void {
        autoHash(hasher, cp);
        autoHash(hasher, cluster);
        try self.hooks.addCodepoint(cp, cluster);
    }
    fn indexForCell(
        self: *RunIterator,
        alloc: Allocator,
        cell: *const terminal.Cell,
        graphemes: []const u21,
        style: font.Style,
        presentation: ?font.Presentation,
    ) !?font.Collection.Index {
        if (cell.isEmpty() or
            cell.codepoint() == 0 or
            cell.codepoint() == terminal.kitty.graphics.unicode.placeholder)
        {
            return try self.opts.grid.getIndex(
                alloc,
                ' ',
                style,
                presentation,
            );
        }
        const primary_cp: u32 = cell.codepoint();
        const primary = try self.opts.grid.getIndex(
            alloc,
            primary_cp,
            style,
            presentation,
        ) orelse return null;
        if (!cell.hasGrapheme()) return primary;
        candidate: for (0..graphemes.len + 1) |i| {
            const idx = if (i == 0) primary else idx: {
                const cp = graphemes[i - 1];
                if (cp == 0xFE0E or cp == 0xFE0F or cp == 0x200D) continue :candidate;
                break :idx try self.opts.grid.getIndex(
                    alloc,
                    cp,
                    style,
                    null,
                ) orelse return null;
            };
            if (!self.opts.grid.hasCodepoint(idx, primary_cp, presentation)) continue;
            for (graphemes) |cp| {
                if (cp == 0xFE0E or cp == 0xFE0F or cp == 0x200D) continue;
                if (!self.opts.grid.hasCodepoint(idx, cp, null)) continue :candidate;
            }
            return idx;
        }
        return null;
    }
};
fn comparableStyle(style: terminal.Style) terminal.Style {
    var s = style;
    s.bg_color = .none;
    return s;
}
