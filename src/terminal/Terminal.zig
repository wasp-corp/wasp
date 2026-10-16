const Terminal = @This();
const std = @import("std");
const build_options = @import("terminal_options");
const lib = @import("lib.zig");
const assert = @import("../quirks.zig").inlineAssert;
const tripwire = @import("../tripwire.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const simd = @import("../simd/root.zig");
const unicode = @import("../unicode/root.zig");
const uucode = @import("uucode");
const ansi = @import("ansi.zig");
const modespkg = @import("modes.zig");
const charsets = @import("charsets.zig");
const xt_checksum = @import("xt_checksum.zig");
const csi = @import("csi.zig");
const hyperlink = @import("hyperlink.zig");
const glyph = @import("apc/glyph.zig");
const kitty = @import("kitty.zig");
const osc = @import("osc.zig");
const point = @import("point.zig");
const sgr = @import("sgr.zig");
const Tabstops = @import("Tabstops.zig");
const color = @import("color.zig");
const mouse = @import("mouse.zig");
const Stream = @import("stream_terminal.zig").Stream;
const size = @import("size.zig");
const pagepkg = @import("page.zig");
const style = @import("style.zig");
const PageList = @import("PageList.zig");
const Screen = @import("Screen.zig");
const ScreenSet = @import("ScreenSet.zig");
const Page = pagepkg.Page;
const Cell = pagepkg.Cell;
const Row = pagepkg.Row;
const log = std.log.scoped(.terminal);
const TABSTOP_INTERVAL = 8;
screens: ScreenSet,
status_display: ansi.StatusDisplay = .main,
tabstops: Tabstops,
rows: size.CellCountInt,
cols: size.CellCountInt,
width_px: u32 = 0,
height_px: u32 = 0,
scrolling_region: ScrollingRegion,
pwd: std.ArrayList(u8),
title: std.ArrayList(u8),
colors: Colors,
previous_char: ?u21 = null,
modes: modespkg.ModeState = .{},
cursor: Cursor = .{},
default_xt_checksum: xt_checksum.Flags = .{},
mouse_shape: mouse.Shape = .text,
glyph_glossary: glyph.Glossary = .empty,
kitty_dnd: ?*kitty.dnd.State = null,
flags: packed struct {
    shell_redraws_prompt: osc.semantic_prompt.Redraw = .true,
    modify_other_keys_2: bool = false,
    mouse_event: mouse.Event = .none,
    mouse_format: mouse.Format = .x10,
    mouse_shift_capture: enum(u2) { null, false, true } = .null,
    xt_checksum: xt_checksum.Flags = .{},
    focused: bool = true,
    visible: bool = true,
    resize_pull_scrollback: bool = true,
    password_input: bool = false,
    selection_scroll: bool = false,
    search_viewport_dirty: bool = false,
    dirty: Dirty = .{},
} = .{},
pub const Colors = struct {
    background: color.DynamicRGB,
    foreground: color.DynamicRGB,
    cursor: color.DynamicRGB,
    palette: color.DynamicPalette,
    pub const default: Colors = .{
        .background = .unset,
        .foreground = .unset,
        .cursor = .unset,
        .palette = .default,
    };
};
pub fn colorForXterm(self: *const Terminal, target: osc.color.Target) ?color.RGB {
    return switch (target) {
        .palette => |i| self.colors.palette.current[i],
        .dynamic => |dynamic| switch (dynamic) {
            .foreground => self.colors.foreground.get(),
            .background => self.colors.background.get(),
            .cursor => self.colors.cursor.get() orelse
                self.colors.foreground.get(),
            .pointer_foreground,
            .pointer_background,
            .tektronix_foreground,
            .tektronix_background,
            .highlight_background,
            .tektronix_cursor,
            .highlight_foreground,
            => null,
        },
        .special => null,
    };
}
pub fn colorForKitty(self: *const Terminal, key: kitty.color.Kind) ?color.RGB {
    return switch (key) {
        .palette => |palette| self.colors.palette.current[palette],
        .special => |special| switch (special) {
            .foreground => self.colors.foreground.get(),
            .background => self.colors.background.get(),
            .cursor => self.colors.cursor.get(),
            else => null,
        },
    };
}
pub const Dirty = packed struct {
    palette: bool = false,
    reverse_colors: bool = false,
    clear: bool = false,
    preedit: bool = false,
    glyph_glossary: bool = false,
};
pub const ScrollingRegion = struct {
    top: size.CellCountInt,
    bottom: size.CellCountInt,
    left: size.CellCountInt,
    right: size.CellCountInt,
};
pub const Cursor = struct {
    is_default: bool = true,
    default_style: Screen.CursorStyle = .block,
    default_blink: ?bool = false,
};
pub const Options = struct {
    cols: size.CellCountInt,
    rows: size.CellCountInt,
    max_scrollback_bytes: ?usize = 10_000,
    max_scrollback_lines: ?usize = null,
    colors: Colors = .default,
    default_modes: modespkg.ModePacked = .{},
    default_cursor_style: Screen.CursorStyle = .block,
    default_cursor_blink: ?bool = false,
    default_xt_checksum: xt_checksum.Flags = .{},
    kitty_image_storage_limit: usize = switch (build_options.artifact) {
        .wasp => 320 * 1000 * 1000,
        .lib => 10 * 1000 * 1000,
    },
    kitty_image_loading_limits: if (build_options.kitty_graphics)
        kitty.graphics.LoadingImage.Limits
    else
        void = if (build_options.kitty_graphics) .direct else {},
};
pub fn init(
    io_impl: std.Io,
    alloc: Allocator,
    opts: Options,
) !Terminal {
    const cols = opts.cols;
    const rows = opts.rows;
    var screen_set: ScreenSet = try .init(io_impl, alloc, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback_bytes = opts.max_scrollback_bytes,
        .max_scrollback_lines = opts.max_scrollback_lines,
        .kitty_image_storage_limit = opts.kitty_image_storage_limit,
        .kitty_image_loading_limits = opts.kitty_image_loading_limits,
    });
    errdefer screen_set.deinit(alloc);
    var result: Terminal = .{
        .cols = cols,
        .rows = rows,
        .screens = screen_set,
        .tabstops = try .init(alloc, cols, TABSTOP_INTERVAL),
        .scrolling_region = .{
            .top = 0,
            .bottom = rows - 1,
            .left = 0,
            .right = cols - 1,
        },
        .pwd = .empty,
        .title = .empty,
        .colors = opts.colors,
        .modes = .{
            .values = opts.default_modes,
            .default = opts.default_modes,
        },
        .cursor = .{
            .default_style = opts.default_cursor_style,
            .default_blink = opts.default_cursor_blink,
        },
        .default_xt_checksum = opts.default_xt_checksum,
    };
    result.flags.xt_checksum = opts.default_xt_checksum;
    result.setCursorStyle(.default);
    return result;
}
pub fn deinit(self: *Terminal, alloc: Allocator) void {
    self.tabstops.deinit(alloc);
    self.screens.deinit(alloc);
    self.colors.palette.deinit(alloc);
    self.pwd.deinit(alloc);
    self.title.deinit(alloc);
    self.glyph_glossary.deinit(alloc);
    if (self.kitty_dnd) |dnd| dnd.destroy(alloc);
    self.* = undefined;
}
pub fn vtStream(self: *Terminal) Stream {
    return Stream.init(.{
        .allocator = self.gpa(),
        .handler = self.vtHandler(),
    });
}
pub fn vtHandler(self: *Terminal) Stream.Handler {
    return .init(self);
}
pub fn setDefaultXtChecksum(self: *Terminal, flags: xt_checksum.Flags) void {
    self.default_xt_checksum = flags;
    self.flags.xt_checksum = flags;
}
pub fn rectXtChecksum(self: *const Terminal, req: xt_checksum.Request) u16 {
    const origin: ?ScrollingRegion = if (self.modes.get(.origin))
        self.scrolling_region
    else
        null;
    const screen = self.screens.active;
    return xt_checksum.compute(
        screen,
        req.selection(&screen.pages, origin),
        self.flags.xt_checksum,
    );
}
pub fn setCursorStyle(self: *Terminal, value: ansi.CursorStyle) void {
    self.cursor.is_default = value == .default;
    self.modes.set(.cursor_blinking, switch (value) {
        .default => self.cursor.default_blink orelse true,
        .steady_block, .steady_bar, .steady_underline => false,
        .blinking_block, .blinking_bar, .blinking_underline => true,
    });
    self.screens.active.cursor.cursor_style = switch (value) {
        .default => self.cursor.default_style,
        .blinking_block, .steady_block => .block,
        .blinking_bar, .steady_bar => .bar,
        .blinking_underline, .steady_underline => .underline,
    };
}
pub fn setDefaultCursorStyle(
    self: *Terminal,
    configured_style: Screen.CursorStyle,
) void {
    self.cursor.default_style = configured_style;
    if (self.cursor.is_default) self.setCursorStyle(.default);
}
pub fn setDefaultCursorBlink(self: *Terminal, blink: ?bool) void {
    self.cursor.default_blink = blink;
    if (self.cursor.is_default) self.setCursorStyle(.default);
}
pub fn io(self: *Terminal) std.Io {
    return self.screens.active.io;
}
pub fn gpa(self: *Terminal) Allocator {
    return self.screens.active.alloc;
}
pub fn setScrollbackMaxBytes(self: *Terminal, max: ?usize) void {
    const primary = self.screens.get(.primary).?;
    primary.pages.setMaxBytes(max);
    primary.no_scrollback = max == 0;
    if (primary.no_scrollback) primary.eraseHistory(null);
}
pub fn setScrollbackMaxLines(self: *Terminal, max: ?usize) void {
    const primary = self.screens.get(.primary).?;
    primary.pages.setMaxLines(max);
}
pub fn printString(self: *Terminal, str: []const u8) !void {
    const view = try std.unicode.Utf8View.init(str);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        switch (cp) {
            '\n' => {
                self.carriageReturn();
                try self.linefeed();
            },
            else => try self.print(cp),
        }
    }
}
pub fn printRepeat(self: *Terminal, count_req: usize) !void {
    const c = self.previous_char orelse return;
    var remaining = @max(count_req, 1);
    var buf: [4096]u32 = undefined;
    for (buf[0..@min(remaining, buf.len)]) |*cp| cp.* = c;
    while (remaining > 0) {
        const n = @min(remaining, buf.len);
        try self.printSlice(buf[0..n]);
        remaining -= n;
    }
}
pub fn printSlice(self: *Terminal, cps: []const u32) !void {
    const fast = fast: {
        if (self.status_display != .main) break :fast false;
        if (self.modes.get(.insert)) break :fast false;
        if (!self.modes.get(.wraparound)) break :fast false;
        const screen: *Screen = self.screens.active;
        if (screen.charset.single_shift != null) break :fast false;
        if (screen.cursor.hyperlink_id != 0) break :fast false;
        break :fast true;
    };
    if (!fast) {
        for (cps) |cp| try self.print(@intCast(cp));
        return;
    }
    const grapheme_cluster = self.modes.get(.grapheme_cluster);
    const charset = self.screens.active.charset;
    const allow_unicode = switch (charset.charsets.get(charset.gl)) {
        .utf8, .ascii => !grapheme_cluster or self.scrolling_region.left == 0,
        else => false,
    };
    var i: usize = 0;
    while (i < cps.len) {
        const consumed = try self.printSliceFast(
            cps[i..],
            grapheme_cluster,
            allow_unicode,
        );
        if (consumed > 0) {
            i += consumed;
            continue;
        }
        try self.print(@intCast(cps[i]));
        i += 1;
    }
}
fn printSliceFast(
    self: *Terminal,
    cps: []const u32,
    grapheme_cluster: bool,
    allow_unicode: bool,
) !usize {
    const screen: *Screen = self.screens.active;
    const cp0 = cps[0];
    if (cp0 <= 0xFF) {
        if (cp0 < 0x10) return 0;
        return self.printSliceFill(
            .narrow,
            cps,
            grapheme_cluster,
            allow_unicode,
        );
    }
    if (!allow_unicode) return 0;
    if (comptime build_options.kitty_graphics) {
        if (cp0 == kitty.graphics.unicode.placeholder) return 0;
    }
    if (grapheme_cluster and screen.cursor.x != 0) gate: {
        if (screen.cursor.pending_wrap) return 0;
        const immediate = screen.cursorCellLeft(1);
        const prev: *Cell = switch (immediate.wide) {
            .spacer_tail => screen.cursorCellLeft(2),
            else => immediate,
        };
        if (prev.codepoint() == 0) break :gate;
        if (prev.hasGrapheme()) return 0;
        var state: uucode.grapheme.BreakState = .default;
        if (!unicode.graphemeBreak(
            prev.content.codepoint.data,
            @intCast(cp0),
            &state,
        )) return 0;
    } else if (grapheme_cluster) {
        if (screen.cursor.pending_wrap) return 0;
    }
    return switch (unicode.table.get(@intCast(cp0)).width) {
        1 => self.printSliceFill(
            .narrow,
            cps,
            grapheme_cluster,
            allow_unicode,
        ),
        2 => self.printSliceFill(
            .wide,
            cps,
            grapheme_cluster,
            allow_unicode,
        ),
        else => 0,
    };
}
const PrintSliceWidth = enum(u1) {
    narrow,
    wide,
    fn cellsPerCp(comptime self: PrintSliceWidth) usize {
        return switch (self) {
            .narrow => 1,
            .wide => 2,
        };
    }
};
inline fn printSliceEligible(cp: u32, comptime width: PrintSliceWidth) bool {
    assert(cp > 0xFF);
    if (comptime build_options.kitty_graphics) {
        if (cp == kitty.graphics.unicode.placeholder) return false;
    }
    return unicode.table.get(@intCast(cp)).width == comptime @as(u2, switch (width) {
        .narrow => 1,
        .wide => 2,
    });
}
inline fn printSliceStoreRun(
    cells: [*]Cell,
    cps: [*]const u32,
    from: usize,
    to: usize,
    template_bits: u64,
    charset_table: ?[]const u16,
) void {
    const cp_shift = @bitOffsetOf(Cell, "content");
    const content_mask: u64 = comptime mask: {
        const bits = @bitSizeOf(@FieldType(Cell, "content"));
        break :mask ((1 << bits) - 1) << cp_shift;
    };
    assert(template_bits & content_mask == 0);
    if (charset_table) |table| {
        for (from..to) |idx| {
            cells[idx] = @bitCast(template_bits | (@as(u64, table[cps[idx]]) << cp_shift));
        }
        return;
    }
    var idx = from;
    if (simd.lanes(u64)) |lanes| {
        const V = @Vector(lanes, u64);
        const template: V = @splat(template_bits);
        const shift: @Vector(
            lanes,
            std.math.Log2Int(u64),
        ) = @splat(cp_shift);
        while (idx + lanes <= to) : (idx += lanes) {
            const narrow: @Vector(lanes, u32) = cps[idx..][0..lanes].*;
            const wide: V = @intCast(narrow);
            const bits: [lanes]u64 = template | (wide << shift);
            cells[idx..][0..lanes].* = @bitCast(bits);
        }
    }
    while (idx < to) : (idx += 1) {
        cells[idx] = @bitCast(template_bits | (@as(u64, cps[idx]) << cp_shift));
    }
}
fn printSliceFill(
    self: *Terminal,
    comptime width: PrintSliceWidth,
    cps: []const u32,
    grapheme_cluster: bool,
    allow_unicode: bool,
) !usize {
    const screen: *Screen = self.screens.active;
    const charset_table: ?[]const u16 = switch (screen.charset.charsets.get(screen.charset.gl)) {
        .utf8, .ascii => null,
        else => |set| charsets.table(set),
    };
    assert(charset_table == null or !allow_unicode);
    const SimpleMask = pagepkg.Mask(Cell, &.{
        "content_tag",
        "style_id",
        "wide",
        "hyperlink",
    }, 4);
    const cp_shift = @bitOffsetOf(Cell, "content");
    const run_len: usize = run: {
        var idx: usize = 1;
        if (comptime width == .narrow) {
            if (simd.lanes(u32)) |lanes| {
                const V = @Vector(lanes, u32);
                const lo: V = @splat(0x10);
                const hi: V = @splat(0xFF);
                while (idx + lanes <= cps.len) {
                    const v: V = cps[idx..][0..lanes].*;
                    const in_range = (v >= lo) & (v <= hi);
                    if (!@reduce(.And, in_range)) {
                        const bits: std.meta.Int(.unsigned, lanes) = @bitCast(in_range);
                        idx += @ctz(~bits);
                        break;
                    }
                    idx += lanes;
                }
            }
        }
        while (idx < cps.len) : (idx += 1) {
            const cp = cps[idx];
            if (comptime width == .narrow) {
                if (cp >= 0x10 and cp <= 0xFF) continue;
            }
            if (cp > 0xFF and allow_unicode and printSliceEligible(cp, width)) {
                if (!grapheme_cluster) continue;
                var state: uucode.grapheme.BreakState = .default;
                if (unicode.graphemeBreak(@intCast(cps[idx - 1]), @intCast(cp), &state)) continue;
            }
            break :run idx;
        }
        break :run cps.len;
    };
    assert(run_len > 0);
    defer screen.assertIntegrity();
    const cells_per_cp: usize = comptime width.cellsPerCp();
    var printed: usize = 0;
    outer: while (printed < run_len) {
        if (screen.cursor.pending_wrap) try self.printWrap();
        const right_limit: usize = if (screen.cursor.x > self.scrolling_region.right)
            self.cols
        else
            self.scrolling_region.right + 1;
        if (comptime width == .wide) {
            if (right_limit - self.scrolling_region.left <= 1) break;
        }
        const cursor = &screen.cursor;
        const avail: usize = right_limit - cursor.x;
        assert(avail > 0);
        const page = cursor.page_pin.node.pageAssumeResident();
        const cells: [*]Cell = @ptrCast(cursor.page_cell);
        const style_id = cursor.style_id;
        const template: Cell = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 0 } },
            .style_id = style_id,
            .wide = .narrow,
            .protected = cursor.protected,
            .semantic_content = cursor.semantic_content,
        };
        const template_bits: u64 = @bitCast(template);
        const check_expected: u64 = printSliceCheckExpected(style_id);
        if (comptime width == .wide) {
            if (avail == 1) {
                if (!SimpleMask.eqlScalar(cells[0], check_expected)) break;
                var spacer = template;
                if (right_limit == self.cols) {
                    cursor.page_row.wrap = true;
                    spacer.wide = .spacer_head;
                }
                cursor.page_row.dirty = true;
                if (style_id != style.default_id) cursor.page_row.styled = true;
                cells[0] = spacer;
                try self.printWrap();
                continue :outer;
            }
        }
        const count = @min(avail / cells_per_cp, run_len - printed);
        assert(count > 0);
        const cell_count = count * cells_per_cp;
        const spacer_bits: u64 = if (comptime width == .wide) spacer: {
            var spacer = template;
            spacer.wide = .spacer_tail;
            break :spacer @bitCast(spacer);
        } else undefined;
        const wide_bits: u64 = if (comptime width == .wide) wb: {
            var w = template;
            w.wide = .wide;
            break :wb @bitCast(w);
        } else undefined;
        var k: usize = 0;
        fill: while (k < cell_count) {
            var simple = k;
            simple: {
                while (simple + SimpleMask.group_len <= cell_count) {
                    const p = SimpleMask.eqlPrefix(
                        cells[0..cell_count],
                        simple,
                        check_expected,
                    );
                    simple += p;
                    if (p != SimpleMask.group_len) break :simple;
                }
                while (simple < cell_count) : (simple += 1) {
                    if (!SimpleMask.eqlScalar(
                        cells[simple],
                        check_expected,
                    )) break;
                }
            }
            if (comptime width == .wide) {
                const pair_end = k + (simple - k) / 2 * 2;
                var idx = k;
                if (simd.lanes(u64)) |lanes| {
                    const pair_lanes = lanes / 2;
                    const Vp = @Vector(pair_lanes, u64);
                    const wide_v: Vp = @splat(wide_bits);
                    const spacer_v: Vp = @splat(spacer_bits);
                    const shift_v: @Vector(
                        pair_lanes,
                        std.math.Log2Int(u64),
                    ) = @splat(cp_shift);
                    while (idx + 2 * pair_lanes <= pair_end) : (idx += 2 * pair_lanes) {
                        const narrow: @Vector(pair_lanes, u32) =
                            cps[printed + idx / 2 ..][0..pair_lanes].*;
                        const wides: Vp = wide_v | (@as(Vp, @intCast(narrow)) << shift_v);
                        const inter: [2 * pair_lanes]u64 = std.simd.interlace(.{
                            wides,
                            spacer_v,
                        });
                        cells[idx..][0 .. 2 * pair_lanes].* = @bitCast(inter);
                    }
                }
                while (idx < pair_end) : (idx += 2) {
                    cells[idx] = @bitCast(
                        wide_bits | (@as(u64, cps[printed + idx / 2]) << cp_shift),
                    );
                    cells[idx + 1] = @bitCast(spacer_bits);
                }
                k = pair_end;
                if (simple != pair_end) {
                    simple = pair_end;
                }
            } else {
                printSliceStoreRun(
                    cells,
                    cps.ptr + printed,
                    k,
                    simple,
                    template_bits,
                    charset_table,
                );
                k = simple;
            }
            if (k >= cell_count) break;
            if (comptime width == .narrow) bulk: {
                const first = SimpleMask.pattern(cells[k]);
                const style_shift = @bitOffsetOf(Cell, "style_id");
                const old_style: style.Id = @truncate(first >> style_shift);
                if (first != printSliceCheckExpected(old_style)) break :bulk;
                assert(old_style != style_id);
                var m = k + 1;
                scan: {
                    while (m + SimpleMask.group_len <= cell_count) {
                        const p = SimpleMask.eqlPrefix(
                            cells[0..cell_count],
                            m,
                            first,
                        );
                        m += p;
                        if (p != SimpleMask.group_len) break :scan;
                    }
                    while (m < cell_count) : (m += 1) {
                        if (!SimpleMask.eqlScalar(cells[m], first)) break;
                    }
                }
                const n = m - k;
                if (old_style != style.default_id) {
                    page.styles.releaseMultiple(page.memory, old_style, @intCast(n));
                }
                if (style_id != style.default_id) {
                    page.styles.useMultiple(page.memory, style_id, @intCast(n));
                }
                printSliceStoreRun(
                    cells,
                    cps.ptr + printed,
                    k,
                    m,
                    template_bits,
                    charset_table,
                );
                k = m;
                continue :fill;
            }
            const general_count: usize = cells_per_cp;
            for (0..general_count) |offset| {
                const cell = &cells[k + offset];
                if (cell.wide != .narrow or
                    cell.hasGrapheme() or
                    cell.hyperlink) break :fill;
            }
            for (0..general_count) |offset| {
                const cell = &cells[k + offset];
                if (cell.style_id != style_id) {
                    if (cell.style_id != style.default_id) {
                        page.styles.release(page.memory, cell.style_id);
                    }
                    if (style_id != style.default_id) {
                        page.styles.use(page.memory, style_id);
                    }
                }
            }
            if (comptime width == .wide) {
                cells[k] = @bitCast(
                    wide_bits | (@as(u64, cps[printed + k / 2]) << cp_shift),
                );
                cells[k + 1] = @bitCast(spacer_bits);
            } else {
                const cp = if (charset_table) |table|
                    table[cps[printed + k]]
                else
                    cps[printed + k];
                cells[k] = @bitCast(
                    template_bits | (@as(u64, cp) << cp_shift),
                );
            }
            k += cells_per_cp;
        }
        if (k > 0) {
            assert(k % cells_per_cp == 0);
            cursor.page_row.dirty = true;
            if (style_id != style.default_id) cursor.page_row.styled = true;
            self.previous_char = @intCast(cps[printed + k / cells_per_cp - 1]);
            printed += k / cells_per_cp;
            if (cursor.x + k >= right_limit) {
                assert(cursor.x + k == right_limit);
                screen.cursorRight(@intCast(k - 1));
                cursor.pending_wrap = true;
            } else {
                screen.cursorRight(@intCast(k));
            }
        }
        if (k < cell_count) break;
    }
    return printed;
}
inline fn printSliceCheckExpected(style_id: style.Id) u64 {
    var e: Cell = @bitCast(@as(u64, 0));
    e.style_id = style_id;
    return @bitCast(e);
}
pub fn print(self: *Terminal, c: u21) !void {
    if (self.status_display != .main) {
        @branchHint(.cold);
        return;
    }
    defer self.screens.active.assertIntegrity();
    const charset: charsets.Charset = charset: {
        const state = &self.screens.active.charset;
        const key = state.single_shift orelse state.gl;
        state.single_shift = null;
        break :charset state.charsets.get(key);
    };
    const right_limit = if (self.screens.active.cursor.x > self.scrolling_region.right)
        self.cols
    else
        self.scrolling_region.right + 1;
    if (c > 255 and
        self.modes.get(.grapheme_cluster) and
        self.screens.active.cursor.x > 0)
    grapheme: {
        @branchHint(.unlikely);
        const Prev = struct { cell: *Cell, left: size.CellCountInt };
        var prev: Prev = prev: {
            const left: size.CellCountInt = left: {
                if (self.modes.get(.wraparound)) {
                    break :left @intFromBool(!self.screens.active.cursor.pending_wrap);
                }
                if (self.screens.active.cursor.x != right_limit - 1) break :left 1;
                break :left @intFromBool(self.screens.active.cursor.page_cell.codepoint() == 0);
            };
            const immediate = self.screens.active.cursorCellLeft(left);
            break :prev switch (immediate.wide) {
                else => .{ .cell = immediate, .left = left },
                .spacer_tail => .{
                    .cell = self.screens.active.cursorCellLeft(left + 1),
                    .left = left + 1,
                },
            };
        };
        if (prev.cell.codepoint() == 0) break :grapheme;
        var previous_codepoint: u21 = prev.cell.content.codepoint.data;
        const grapheme_break = brk: {
            var state: uucode.grapheme.BreakState = .default;
            if (prev.cell.hasGrapheme()) {
                const cps = self.screens.active.cursor.page_pin.node.page().lookupGrapheme(prev.cell).?;
                for (cps) |cp2| {
                    _ = unicode.graphemeBreak(previous_codepoint, cp2, &state);
                    previous_codepoint = cp2;
                }
            }
            break :brk unicode.graphemeBreak(previous_codepoint, c, &state);
        };
        if (!grapheme_break) {
            switch (unicode.graphemeWidthEffect(previous_codepoint, c)) {
                .ignore => return,
                .wide => wide: {
                    if (prev.cell.wide == .wide) break :wide;
                    self.screens.active.cursorLeft(prev.left);
                    if (self.screens.active.cursor.x == right_limit - 1) {
                        if (!self.modes.get(.wraparound)) return;
                        const row_wrap = right_limit == self.cols;
                        if (row_wrap) self.screens.active.cursor.page_row.wrap = true;
                        const prev_cp = prev.cell.content.codepoint.data;
                        var prev_grapheme_buf: [pagepkg.grapheme_max_len]u21 = undefined;
                        const prev_grapheme: []const u21 = prev_grapheme: {
                            if (!prev.cell.hasGrapheme()) break :prev_grapheme &.{};
                            const cps = self.screens.active.cursor.page_pin.grapheme(prev.cell).?;
                            const copy = prev_grapheme_buf[0..cps.len];
                            @memcpy(copy, cps);
                            break :prev_grapheme copy;
                        };
                        self.writeCell(0, if (row_wrap) .spacer_head else .narrow);
                        try self.printWrap();
                        self.writeCell(prev_cp, .wide);
                        if (prev_grapheme.len > 0) {
                            try self.screens.active.setGraphemes(
                                self.screens.active.cursor.page_cell,
                                prev_grapheme,
                            );
                        }
                        prev.cell = self.screens.active.cursor.page_cell;
                    } else {
                        prev.cell.wide = .wide;
                    }
                    self.screens.active.cursorRight(1);
                    const spacer_node = self.screens.active.cursor.page_pin.node;
                    const spacer_serial = spacer_node.serial;
                    self.writeCell(0, .spacer_tail);
                    if (self.screens.active.cursor.page_pin.node != spacer_node or
                        self.screens.active.cursor.page_pin.node.serial != spacer_serial)
                    {
                        @branchHint(.unlikely);
                        prev.cell = self.screens.active.cursorCellLeft(1);
                    }
                    if (self.screens.active.cursor.x == right_limit - 1) {
                        self.screens.active.cursor.pending_wrap = true;
                    } else {
                        self.screens.active.cursorRight(1);
                    }
                },
                .narrow => narrow: {
                    if (prev.cell.wide != .wide) break :narrow;
                    prev.cell.wide = .narrow;
                    const prev_x = self.screens.active.cursor.x - prev.left;
                    if (prev_x < self.cols - 1) {
                        const cells: [*]Cell = @ptrCast(prev.cell);
                        cells[1].wide = .narrow;
                    }
                    self.screens.active.cursor.pending_wrap = false;
                    self.screens.active.cursorHorizontalAbsolute(
                        @min(prev_x + 1, right_limit - 1),
                    );
                    break :narrow;
                },
                .no_change => {},
            }
            log.debug("c={X} grapheme attach to left={} primary_cp={X}", .{
                c,
                prev.left,
                prev.cell.codepoint(),
            });
            self.screens.active.cursorMarkDirty();
            try self.screens.active.appendGrapheme(prev.cell, c);
            return;
        }
    }
    const width: usize = if (c <= 0xFF) 1 else @intCast(unicode.table.get(c).width);
    assert(width <= 2);
    if (width == 0) {
        @branchHint(.unlikely);
        if (self.modes.get(.grapheme_cluster)) return;
        const left: size.CellCountInt = if (self.modes.get(.wraparound) and self.screens.active.cursor.pending_wrap) 0 else 1;
        if (self.screens.active.cursor.x == 0 and left == 1) {
            log.warn("zero-width character with no prior character, ignoring", .{});
            return;
        }
        const prev = prev: {
            const immediate = self.screens.active.cursorCellLeft(left);
            if (immediate.wide != .spacer_tail) break :prev immediate;
            break :prev self.screens.active.cursorCellLeft(left + 1);
        };
        if (!prev.hasText()) {
            log.warn("zero-width character with no prior character, ignoring", .{});
            return;
        }
        if (c == 0xFE0F or c == 0xFE0E) {
            const prev_props = unicode.table.get(prev.content.codepoint.data);
            const emoji = prev_props.grapheme_break == .extended_pictographic;
            if (!emoji) return;
        }
        try self.screens.active.appendGrapheme(prev, c);
        return;
    }
    self.previous_char = c;
    if (self.screens.active.cursor.pending_wrap) {
        if (self.modes.get(.wraparound)) {
            try self.printWrap();
        } else {
            self.screens.active.cursor.pending_wrap = false;
        }
    }
    if (self.modes.get(.insert) and
        self.screens.active.cursor.x + width < self.cols)
    {
        self.insertBlanks(width);
    }
    switch (width) {
        1 => {
            @branchHint(.likely);
            self.screens.active.cursorMarkDirty();
            @call(.always_inline, printCell, .{ self, c, .narrow, charset });
        },
        2 => if ((right_limit - self.scrolling_region.left) > 1) {
            if (self.screens.active.cursor.x == right_limit - 1) {
                if (!self.modes.get(.wraparound)) return;
                if (right_limit == self.cols) {
                    self.screens.active.cursor.page_row.wrap = true;
                    self.writeCell(0, .spacer_head);
                } else {
                    self.writeCell(0, .narrow);
                }
                try self.printWrap();
            }
            self.screens.active.cursorMarkDirty();
            self.printCell(c, .wide, charset);
            self.screens.active.cursorRight(1);
            self.writeCell(0, .spacer_tail);
        } else {
            self.screens.active.cursorMarkDirty();
            self.writeCell(0, .narrow);
        },
        else => unreachable,
    }
    if (self.screens.active.cursor.x == right_limit - 1) {
        self.screens.active.cursor.pending_wrap = true;
        return;
    }
    self.screens.active.cursorRight(1);
}
fn printCell(
    self: *Terminal,
    unmapped_c: u21,
    wide: Cell.Wide,
    set: charsets.Charset,
) void {
    const c: u21 = c: {
        if (set == .utf8 or set == .ascii) {
            @branchHint(.likely);
            break :c unmapped_c;
        }
        if (unmapped_c > std.math.maxInt(u8)) break :c unmapped_c;
        const table = charsets.table(set);
        break :c @intCast(table[@intCast(unmapped_c)]);
    };
    @call(.always_inline, writeCell, .{ self, c, wide });
}
fn writeCell(
    self: *Terminal,
    c: u21,
    wide: Cell.Wide,
) void {
    defer self.screens.active.assertIntegrity();
    const cell = self.screens.active.cursor.page_cell;
    if (cell.wide != wide) {
        switch (cell.wide) {
            .narrow => {},
            .wide => wide: {
                if (self.screens.active.cursor.x >= self.cols - 1) break :wide;
                const spacer_cell = self.screens.active.cursorCellRight(1);
                self.screens.active.clearCells(
                    self.screens.active.cursor.page_pin.node.page(),
                    self.screens.active.cursor.page_row,
                    spacer_cell[0..1],
                );
                if (self.screens.active.cursor.y > 0 and self.screens.active.cursor.x <= 1) {
                    const head_cell = self.screens.active.cursorCellEndOfPrev();
                    if (head_cell.wide == .spacer_head) head_cell.wide = .narrow;
                }
            },
            .spacer_tail => {
                assert(self.screens.active.cursor.x > 0);
                if (comptime build_options.slow_runtime_safety) {
                    cell.wide = .narrow;
                }
                const wide_cell = self.screens.active.cursorCellLeft(1);
                self.screens.active.clearCells(
                    self.screens.active.cursor.page_pin.node.page(),
                    self.screens.active.cursor.page_row,
                    wide_cell[0..1],
                );
                if (self.screens.active.cursor.y > 0 and self.screens.active.cursor.x <= 1) {
                    const head_cell = self.screens.active.cursorCellEndOfPrev();
                    if (head_cell.wide == .spacer_head) head_cell.wide = .narrow;
                }
            },
            .spacer_head => {},
        }
    }
    if (cell.hasGrapheme()) {
        const page = self.screens.active.cursor.page_pin.node.page();
        page.clearGrapheme(cell);
        page.updateRowGraphemeFlag(self.screens.active.cursor.page_row);
    }
    const style_changed = cell.style_id != self.screens.active.cursor.style_id;
    if (style_changed) {
        var page = self.screens.active.cursor.page_pin.node.page();
        if (cell.style_id != style.default_id) {
            assert(self.screens.active.cursor.page_row.styled);
            page.styles.release(page.memory, cell.style_id);
        }
    }
    const had_hyperlink = cell.hyperlink;
    cell.* = .{
        .content_tag = .codepoint,
        .content = .{ .codepoint = .{ .data = c } },
        .style_id = self.screens.active.cursor.style_id,
        .wide = wide,
        .protected = self.screens.active.cursor.protected,
        .semantic_content = self.screens.active.cursor.semantic_content,
    };
    if (style_changed) {
        var page = self.screens.active.cursor.page_pin.node.page();
        if (cell.style_id != style.default_id) {
            page.styles.use(page.memory, cell.style_id);
            self.screens.active.cursor.page_row.styled = true;
        }
    }
    if (comptime build_options.kitty_graphics) {
        if (c == kitty.graphics.unicode.placeholder) {
            @branchHint(.unlikely);
            self.screens.active.cursor.page_row.kitty_virtual_placeholder = true;
        }
    }
    if (self.screens.active.cursor.hyperlink_id > 0) {
        self.screens.active.cursorSetHyperlink() catch |err| {
            @branchHint(.unlikely);
            log.warn("error reallocating for more hyperlink space, ignoring hyperlink err={}", .{err});
            assert(!self.screens.active.cursor.page_cell.hyperlink);
        };
    } else if (had_hyperlink) {
        var page = self.screens.active.cursor.page_pin.node.page();
        page.clearHyperlink(cell);
        page.updateRowHyperlinkFlag(self.screens.active.cursor.page_row);
    }
}
fn printWrap(self: *Terminal) !void {
    const cursor: *Screen.Cursor = &self.screens.active.cursor;
    const mark_wrap = cursor.x == self.cols - 1;
    if (mark_wrap) cursor.page_row.wrap = true;
    const old_semantic = cursor.semantic_content;
    const old_semantic_clear = cursor.semantic_content_clear_eol;
    try self.index();
    self.screens.active.cursorHorizontalAbsolute(self.scrolling_region.left);
    assert(cursor == &self.screens.active.cursor);
    cursor.semantic_content = old_semantic;
    cursor.semantic_content_clear_eol = old_semantic_clear;
    switch (old_semantic) {
        .output, .input => {},
        .prompt => cursor.page_row.semantic_prompt = .prompt_continuation,
    }
    if (mark_wrap) {
        const row = self.screens.active.cursor.page_row;
        row.wrap_continuation = true;
    }
    self.screens.active.assertIntegrity();
}
pub fn configureCharset(self: *Terminal, slot: charsets.Slots, set: charsets.Charset) void {
    self.screens.active.charset.charsets.set(slot, set);
}
pub fn invokeCharset(
    self: *Terminal,
    active: charsets.ActiveSlot,
    slot: charsets.Slots,
    single: bool,
) void {
    if (single) {
        assert(active == .GL);
        self.screens.active.charset.single_shift = slot;
        return;
    }
    switch (active) {
        .GL => self.screens.active.charset.gl = slot,
        .GR => self.screens.active.charset.gr = slot,
    }
}
pub fn carriageReturn(self: *Terminal) void {
    self.screens.active.cursor.pending_wrap = false;
    self.screens.active.cursorHorizontalAbsolute(if (self.modes.get(.origin))
        self.scrolling_region.left
    else if (self.screens.active.cursor.x >= self.scrolling_region.left)
        self.scrolling_region.left
    else
        0);
}
pub fn linefeed(self: *Terminal) !void {
    try self.index();
    if (self.modes.get(.linefeed)) self.carriageReturn();
}
pub fn backspace(self: *Terminal) void {
    self.cursorLeft(1);
}
pub fn cursorUp(self: *Terminal, count_req: usize) void {
    self.screens.active.cursor.pending_wrap = false;
    const max = if (self.screens.active.cursor.y >= self.scrolling_region.top)
        self.screens.active.cursor.y - self.scrolling_region.top
    else
        self.screens.active.cursor.y;
    const count = @min(max, @max(count_req, 1));
    self.screens.active.cursorUp(@intCast(count));
}
pub fn cursorDown(self: *Terminal, count_req: usize) void {
    self.screens.active.cursor.pending_wrap = false;
    const max = if (self.screens.active.cursor.y <= self.scrolling_region.bottom)
        self.scrolling_region.bottom - self.screens.active.cursor.y
    else
        self.rows - self.screens.active.cursor.y - 1;
    const count = @min(max, @max(count_req, 1));
    self.screens.active.cursorDown(@intCast(count));
}
pub fn cursorRight(self: *Terminal, count_req: usize) void {
    self.screens.active.cursor.pending_wrap = false;
    const max = if (self.screens.active.cursor.x <= self.scrolling_region.right)
        self.scrolling_region.right - self.screens.active.cursor.x
    else
        self.cols - self.screens.active.cursor.x - 1;
    const count = @min(max, @max(count_req, 1));
    self.screens.active.cursorRight(@intCast(count));
}
pub fn cursorLeft(self: *Terminal, count_req: usize) void {
    const WrapMode = enum { none, reverse, reverse_extended };
    const wrap_mode: WrapMode = wrap_mode: {
        if (!self.modes.get(.wraparound)) break :wrap_mode .none;
        if (self.modes.get(.reverse_wrap_extended)) break :wrap_mode .reverse_extended;
        if (self.modes.get(.reverse_wrap)) break :wrap_mode .reverse;
        break :wrap_mode .none;
    };
    var count = @max(count_req, 1);
    if (wrap_mode == .none) {
        self.screens.active.cursorLeft(@min(count, self.screens.active.cursor.x));
        self.screens.active.cursor.pending_wrap = false;
        return;
    }
    if (self.screens.active.cursor.pending_wrap) {
        count -= 1;
        self.screens.active.cursor.pending_wrap = false;
        if (count == 0) return;
    }
    const top = self.scrolling_region.top;
    const bottom = self.scrolling_region.bottom;
    const right_margin = self.scrolling_region.right;
    const left_margin = if (self.screens.active.cursor.x < self.scrolling_region.left)
        0
    else
        self.scrolling_region.left;
    if (self.screens.active.cursor.x == left_margin) {
        switch (wrap_mode) {
            .reverse => if (self.screens.active.cursor.y <= top) {
                self.screens.active.cursorAbsolute(left_margin, top);
                return;
            },
            .reverse_extended => {},
            .none => unreachable,
        }
    }
    while (true) {
        const max = self.screens.active.cursor.x - left_margin;
        const amount = @min(max, count);
        count -= amount;
        self.screens.active.cursorLeft(amount);
        if (count == 0) break;
        if (self.screens.active.cursor.y == top) {
            if (wrap_mode != .reverse_extended) break;
            self.screens.active.cursorAbsolute(right_margin, bottom);
            count -= 1;
            continue;
        }
        if (self.screens.active.cursor.y == 0) {
            assert(self.screens.active.cursor.x == left_margin);
            break;
        }
        if (wrap_mode != .reverse_extended) {
            const prev_row = self.screens.active.cursorRowUp(1);
            if (!prev_row.wrap) break;
        }
        self.screens.active.cursorAbsolute(right_margin, self.screens.active.cursor.y - 1);
        count -= 1;
    }
}
pub fn saveCursor(self: *Terminal) void {
    self.screens.active.saved_cursor = .{
        .x = self.screens.active.cursor.x,
        .y = self.screens.active.cursor.y,
        .style = self.screens.active.cursor.style,
        .protected = self.screens.active.cursor.protected,
        .pending_wrap = self.screens.active.cursor.pending_wrap,
        .origin = self.modes.get(.origin),
        .charset = self.screens.active.charset,
    };
}
pub fn restoreCursor(self: *Terminal) void {
    const saved: Screen.SavedCursor = self.screens.active.saved_cursor orelse .{
        .x = 0,
        .y = 0,
        .style = .{},
        .protected = false,
        .pending_wrap = false,
        .origin = false,
        .charset = .{},
    };
    self.screens.active.cursor.style = saved.style;
    self.screens.active.manualStyleUpdate() catch |err| {
        log.warn("restoreCursor error updating style err={}", .{err});
        const screen: *Screen = self.screens.active;
        screen.cursor.style = .{};
        self.screens.active.manualStyleUpdate() catch unreachable;
    };
    self.screens.active.charset = saved.charset;
    self.modes.set(.origin, saved.origin);
    self.screens.active.cursor.pending_wrap = saved.pending_wrap;
    self.screens.active.cursor.protected = saved.protected;
    self.screens.active.cursorAbsolute(
        @min(saved.x, self.cols - 1),
        @min(saved.y, self.rows - 1),
    );
    self.screens.active.assertIntegrity();
}
pub fn setProtectedMode(self: *Terminal, mode: ansi.ProtectedMode) void {
    switch (mode) {
        .off => {
            self.screens.active.cursor.protected = false;
        },
        .iso => {
            self.screens.active.cursor.protected = true;
            self.screens.active.protected_mode = .iso;
        },
        .dec => {
            self.screens.active.cursor.protected = true;
            self.screens.active.protected_mode = .dec;
        },
    }
}
pub fn semanticPrompt(
    self: *Terminal,
    cmd: osc.Command.SemanticPrompt,
) !void {
    switch (cmd.action) {
        .fresh_line => try self.semanticPromptFreshLine(),
        .fresh_line_new_prompt => {
            try self.semanticPromptFreshLine();
            const screen: *Screen = self.screens.active;
            screen.cursorSetSemanticContent(.{
                .prompt = cmd.readOption(.prompt_kind) orelse .initial,
            });
            if (cmd.readOption(.redraw)) |v| {
                self.flags.shell_redraws_prompt = v;
            }
            click: {
                if (cmd.readOption(.click_events)) |v| {
                    screen.semantic_prompt.click = .{ .click_events = v };
                    break :click;
                }
                if (cmd.readOption(.cl)) |v| {
                    screen.semantic_prompt.click = .{ .cl = v };
                }
            }
        },
        .new_command => {
            try self.semanticPrompt(.{
                .action = .fresh_line_new_prompt,
                .options_unvalidated = cmd.options_unvalidated,
            });
        },
        .prompt_start => {
            self.screens.active.cursorSetSemanticContent(.{
                .prompt = cmd.readOption(.prompt_kind) orelse .initial,
            });
        },
        .end_prompt_start_input => {
            self.screens.active.cursorSetSemanticContent(.{
                .input = .clear_explicit,
            });
        },
        .end_prompt_start_input_terminate_eol => {
            self.screens.active.cursorSetSemanticContent(.{
                .input = .clear_eol,
            });
        },
        .end_input_start_output => {
            self.screens.active.cursorSetSemanticContent(.output);
            if (self.screens.active.cursor.page_row.semantic_prompt != .none and
                self.screens.active.cursor.x == 0)
            {
                self.screens.active.cursor.page_row.semantic_prompt = .none;
            }
        },
        .end_command => {
            self.screens.active.cursorSetSemanticContent(.output);
        },
    }
}
fn semanticPromptFreshLine(self: *Terminal) !void {
    const left_margin = if (self.screens.active.cursor.x < self.scrolling_region.left)
        0
    else
        self.scrolling_region.left;
    if (self.screens.active.cursor.x == left_margin) return;
    self.carriageReturn();
    try self.index();
}
pub const SemanticPrompt = enum {
    prompt,
    prompt_continuation,
    input,
    command,
};
pub fn cursorIsAtPrompt(self: *Terminal) bool {
    if (self.screens.active_key == .alternate) return false;
    const cursor: *const Screen.Cursor = &self.screens.active.cursor;
    if (cursor.page_row.semantic_prompt != .none) return true;
    return switch (cursor.semantic_content) {
        .input, .prompt => true,
        .output => false,
    };
}
pub fn horizontalTab(self: *Terminal) void {
    while (self.screens.active.cursor.x < self.scrolling_region.right) {
        self.screens.active.cursorRight(1);
        if (self.tabstops.get(self.screens.active.cursor.x)) return;
    }
}
pub fn horizontalTabBack(self: *Terminal) void {
    const left_limit = if (self.modes.get(.origin)) self.scrolling_region.left else 0;
    while (true) {
        if (self.screens.active.cursor.x <= left_limit) return;
        self.screens.active.cursorLeft(1);
        if (self.tabstops.get(self.screens.active.cursor.x)) return;
    }
}
pub fn tabClear(self: *Terminal, cmd: csi.TabClear) void {
    switch (cmd) {
        .current => self.tabstops.unset(self.screens.active.cursor.x),
        .all => self.tabstops.reset(0),
        else => log.warn("invalid or unknown tab clear setting: {}", .{cmd}),
    }
}
pub fn tabSet(self: *Terminal) void {
    self.tabstops.set(self.screens.active.cursor.x);
}
pub fn tabReset(self: *Terminal) void {
    self.tabstops.reset(TABSTOP_INTERVAL);
}
pub fn index(self: *Terminal) !void {
    const screen: *Screen = self.screens.active;
    screen.cursor.pending_wrap = false;
    defer if (screen.cursor.semantic_content != .output) {
        @branchHint(.unlikely);
        if (screen.cursor.semantic_content_clear_eol) {
            screen.cursor.semantic_content = .output;
            screen.cursor.semantic_content_clear_eol = false;
        } else {
            screen.cursor.page_row.semantic_prompt = .prompt_continuation;
        }
    } else {
        assert(!screen.cursor.semantic_content_clear_eol);
    };
    if (screen.cursor.y < self.scrolling_region.top or
        screen.cursor.y > self.scrolling_region.bottom)
    {
        if (screen.cursor.y < self.rows - 1) {
            screen.cursorDown(1);
        }
        return;
    }
    if (screen.cursor.y == self.scrolling_region.bottom and
        screen.cursor.x >= self.scrolling_region.left and
        screen.cursor.x <= self.scrolling_region.right)
    {
        if (comptime build_options.kitty_graphics) {
            screen.kitty_images.dirty = true;
        }
        if (self.scrolling_region.top == 0 and
            self.scrolling_region.left == 0 and
            self.scrolling_region.right == self.cols - 1 and
            (!screen.no_scrollback or
                self.scrolling_region.bottom == 0))
        {
            if (comptime build_options.kitty_graphics) {
                if (screen.kitty_images.placements.count() != 0) {
                    @branchHint(.unlikely);
                    try self.indexScrollWithImages(.window_shift);
                    return;
                }
            }
            try screen.cursorScrollAbove();
            return;
        }
        if (self.scrolling_region.left != 0 or
            self.scrolling_region.right != self.cols - 1)
        {
            try self.scrollUp(1);
            return;
        }
        if (comptime build_options.kitty_graphics) {
            if (screen.kitty_images.placements.count() != 0) {
                @branchHint(.unlikely);
                try self.indexScrollWithImages(.in_place);
                return;
            }
        }
        try screen.cursorScrollRegionUp(
            self.scrolling_region.bottom - self.scrolling_region.top,
        );
        return;
    }
    if (screen.cursor.y < self.scrolling_region.bottom) {
        screen.cursorDown(1);
    }
}
fn indexScrollWithImages(
    self: *Terminal,
    comptime op: kitty.graphics.ImageStorage.ScrollOp,
) !void {
    var kitty_scroll = self.kittyScrollMarginsBegin(-1, op);
    defer if (kitty_scroll) |*state| state.end();
    switch (op) {
        .window_shift => try self.screens.active.cursorScrollAbove(),
        .in_place => try self.screens.active.cursorScrollRegionUp(
            self.scrolling_region.bottom - self.scrolling_region.top,
        ),
    }
}
const KittyScrollMargins = if (build_options.kitty_graphics)
    kitty.graphics.ImageStorage.ScrollMargins
else
    struct {
        pub inline fn end(self: *@This()) void {
            _ = self;
        }
    };
fn kittyScrollMarginsBegin(
    self: *Terminal,
    delta: isize,
    op: kitty.graphics.ImageStorage.ScrollOp,
) ?kitty.graphics.ImageStorage.ScrollMargins {
    @branchHint(.cold);
    if (self.scrolling_region.top == 0 and
        self.scrolling_region.bottom == self.rows - 1 and
        self.scrolling_region.left == 0 and
        self.scrolling_region.right == self.cols - 1) return null;
    const screen: *Screen = self.screens.active;
    return screen.kitty_images.scrollMarginsBegin(
        self.io(),
        self,
        delta,
        op,
    );
}
pub fn reverseIndex(self: *Terminal) void {
    if (self.screens.active.cursor.y != self.scrolling_region.top or
        self.screens.active.cursor.x < self.scrolling_region.left or
        self.screens.active.cursor.x > self.scrolling_region.right)
    {
        self.cursorUp(1);
        return;
    }
    self.scrollDown(1);
}
pub fn setCursorPos(self: *Terminal, row_req: usize, col_req: usize) void {
    const params: struct {
        x_offset: size.CellCountInt = 0,
        y_offset: size.CellCountInt = 0,
        x_max: size.CellCountInt,
        y_max: size.CellCountInt,
    } = if (self.modes.get(.origin)) .{
        .x_offset = self.scrolling_region.left,
        .y_offset = self.scrolling_region.top,
        .x_max = self.scrolling_region.right + 1,
        .y_max = self.scrolling_region.bottom + 1,
    } else .{
        .x_max = self.cols,
        .y_max = self.rows,
    };
    self.screens.active.cursor.pending_wrap = false;
    const row = if (row_req == 0) 1 else row_req;
    const col = if (col_req == 0) 1 else col_req;
    const x = @min(params.x_max, col +| params.x_offset) -| 1;
    const y = @min(params.y_max, row +| params.y_offset) -| 1;
    if (y == self.screens.active.cursor.y) {
        if (x > self.screens.active.cursor.x) {
            self.screens.active.cursorRight(x - self.screens.active.cursor.x);
        } else {
            self.screens.active.cursorLeft(self.screens.active.cursor.x - x);
        }
        return;
    }
    self.screens.active.cursorAbsolute(x, y);
}
pub fn setTopAndBottomMargin(self: *Terminal, top_req: usize, bottom_req: usize) void {
    const top = @max(1, top_req);
    const bottom = @min(self.rows, if (bottom_req == 0) self.rows else bottom_req);
    if (top >= bottom) return;
    self.scrolling_region.top = @intCast(top - 1);
    self.scrolling_region.bottom = @intCast(bottom - 1);
    self.setCursorPos(1, 1);
}
pub fn setLeftAndRightMargin(self: *Terminal, left_req: usize, right_req: usize) void {
    if (!self.modes.get(.enable_left_and_right_margin)) return;
    const left = @max(1, left_req);
    const right = @min(self.cols, if (right_req == 0) self.cols else right_req);
    if (left >= right) return;
    self.scrolling_region.left = @intCast(left - 1);
    self.scrolling_region.right = @intCast(right - 1);
    self.setCursorPos(1, 1);
}
pub fn scrollDown(self: *Terminal, count: usize) void {
    const old_x = self.screens.active.cursor.x;
    const old_y = self.screens.active.cursor.y;
    const old_wrap = self.screens.active.cursor.pending_wrap;
    defer {
        self.screens.active.cursorAbsolute(old_x, old_y);
        self.screens.active.cursor.pending_wrap = old_wrap;
    }
    var kitty_scroll: ?KittyScrollMargins = null;
    defer if (kitty_scroll) |*state| state.end();
    if (comptime build_options.kitty_graphics) {
        if (self.screens.active.kitty_images.placements.count() != 0) {
            @branchHint(.unlikely);
            const region_height: usize =
                @as(usize, self.scrolling_region.bottom - self.scrolling_region.top) + 1;
            kitty_scroll = self.kittyScrollMarginsBegin(
                @intCast(@min(count, region_height)),
                .in_place,
            );
        }
    }
    self.screens.active.cursorAbsolute(self.scrolling_region.left, self.scrolling_region.top);
    self.insertLines(count);
}
pub fn scrollUp(self: *Terminal, count: usize) !void {
    const old_x = self.screens.active.cursor.x;
    const old_y = self.screens.active.cursor.y;
    const old_wrap = self.screens.active.cursor.pending_wrap;
    defer {
        self.screens.active.cursorAbsolute(old_x, old_y);
        self.screens.active.cursor.pending_wrap = old_wrap;
    }
    var kitty_scroll: ?KittyScrollMargins = null;
    defer if (kitty_scroll) |*state| state.end();
    if (comptime build_options.kitty_graphics) {
        if (self.screens.active.kitty_images.placements.count() != 0) {
            @branchHint(.unlikely);
            const region_height: usize =
                @as(usize, self.scrolling_region.bottom - self.scrolling_region.top) + 1;
            kitty_scroll = self.kittyScrollMarginsBegin(
                -@as(isize, @intCast(@min(count, region_height))),
                if (self.scrolling_region.top == 0 and
                    self.scrolling_region.left == 0 and
                    self.scrolling_region.right == self.cols - 1 and
                    (!self.screens.active.no_scrollback or
                        self.scrolling_region.bottom == self.rows - 1))
                    .window_shift
                else
                    .in_place,
            );
        }
    }
    if (self.scrolling_region.top == 0 and
        self.scrolling_region.left == 0 and
        self.scrolling_region.right == self.cols - 1 and
        (!self.screens.active.no_scrollback or
            self.scrolling_region.bottom == self.rows - 1))
    {
        if (comptime build_options.kitty_graphics) {
            self.screens.active.kitty_images.dirty = true;
        }
        const region_height = self.scrolling_region.bottom + 1;
        const adjusted_count = @min(count, region_height);
        self.screens.active.cursorAbsolute(0, self.scrolling_region.bottom);
        for (0..adjusted_count) |_| try self.screens.active.cursorScrollAbove();
        return;
    }
    self.screens.active.cursorAbsolute(self.scrolling_region.left, self.scrolling_region.top);
    self.deleteLines(count);
}
pub const ScrollViewport = union(Tag) {
    top,
    bottom,
    delta: isize,
    row: usize,
    delta_prompt: isize,
    pub const Tag = lib.Enum(lib.target, &.{
        "top",
        "bottom",
        "delta",
        "row",
        "delta_prompt",
    });
    const c_union = lib.TaggedUnion(
        lib.target,
        @This(),
        .{ .padding = [2]u64 },
    );
    pub const C = c_union.C;
    pub const CValue = c_union.CValue;
    pub const cval = c_union.cval;
};
pub fn scrollViewport(self: *Terminal, behavior: ScrollViewport) void {
    self.screens.active.scroll(switch (behavior) {
        .top => .{ .top = {} },
        .bottom => .{ .active = {} },
        .delta => |delta| .{ .delta_row = delta },
        .row => |row| .{ .row = row },
        .delta_prompt => |delta| .{ .delta_prompt = delta },
    });
}
pub fn compressionActivity(self: *const Terminal) u64 {
    const state = &self.screens.get(.primary).?.pages.page_compression;
    return @as(u64, state.activity_serial);
}
pub const CompressionMode = lib.Enum(lib.target, &.{
    "incremental",
    "full",
});
pub const CompressionResult = lib.Enum(lib.target, &.{
    "unsupported",
    "pending",
    "complete",
});
pub fn compress(
    self: *Terminal,
    mode: CompressionMode,
) CompressionResult {
    const pages = &self.screens.get(.primary).?.pages;
    const result = switch (mode) {
        .incremental => pages.compress(.incremental),
        .full => pages.compress(.full),
    };
    return switch (result) {
        .unsupported => .unsupported,
        .pending => .pending,
        .complete => .complete,
    };
}
fn rowWillBeShifted(
    self: *Terminal,
    page: *Page,
    row: *Row,
) void {
    const cells = row.cells.ptr(page.memory.ptr);
    if (self.scrolling_region.right == self.cols - 1 or
        self.scrolling_region.left < 2)
    {
        const end_cell: *Cell = &cells[page.size.cols - 1];
        if (end_cell.wide == .spacer_head) {
            end_cell.wide = .narrow;
        }
    }
    const left_cell: *Cell = &cells[self.scrolling_region.left];
    const right_cell: *Cell = &cells[self.scrolling_region.right];
    if (left_cell.wide == .spacer_tail) {
        const wide_cell: *Cell = &cells[self.scrolling_region.left - 1];
        if (wide_cell.hasGrapheme()) {
            page.clearGrapheme(wide_cell);
            page.updateRowGraphemeFlag(row);
        }
        wide_cell.content.codepoint = .{ .data = 0 };
        wide_cell.wide = .narrow;
        left_cell.wide = .narrow;
    }
    if (right_cell.wide == .wide) {
        const tail_cell: *Cell = &cells[self.scrolling_region.right + 1];
        if (right_cell.hasGrapheme()) {
            page.clearGrapheme(right_cell);
            page.updateRowGraphemeFlag(row);
        }
        right_cell.content.codepoint.data = 0;
        right_cell.wide = .narrow;
        tail_cell.wide = .narrow;
    }
}
fn invalidateFullWidthRowRange(
    self: *Terminal,
    first: *PageList.List.Node,
    last: *PageList.List.Node,
) void {
    var node = first;
    while (true) : (node = node.next.?) {
        self.screens.active.pages.invalidateNodeLayout(node);
        if (node == last) break;
    }
}
pub fn insertLines(self: *Terminal, count: usize) void {
    if (count == 0) return;
    if (self.screens.active.cursor.y < self.scrolling_region.top or
        self.screens.active.cursor.y > self.scrolling_region.bottom or
        self.screens.active.cursor.x < self.scrolling_region.left or
        self.screens.active.cursor.x > self.scrolling_region.right) return;
    if (comptime build_options.kitty_graphics) {
        self.screens.active.kitty_images.dirty = true;
    }
    const start_y = self.screens.active.cursor.y;
    defer {
        self.screens.active.cursorAbsolute(self.scrolling_region.left, start_y);
        self.screens.active.cursor.pending_wrap = false;
    }
    const left_right = self.scrolling_region.left > 0 or
        self.scrolling_region.right < self.cols - 1;
    const rem = self.scrolling_region.bottom - self.screens.active.cursor.y + 1;
    const adjusted_count = @min(count, rem);
    var cur_p = self.screens.active.pages.trackPin(
        self.screens.active.cursor.page_pin.down(rem - 1).?,
    ) catch |err| {
        comptime assert(@TypeOf(err) == error{OutOfMemory});
        log.err("insertLines trackPin error err={}", .{err});
        @panic("insertLines trackPin OOM");
    };
    defer self.screens.active.pages.untrackPin(cur_p);
    if (!left_right) self.invalidateFullWidthRowRange(
        self.screens.active.cursor.page_pin.node,
        cur_p.node,
    );
    var y: usize = rem;
    while (y > 0) {
        const cur_rac = cur_p.rowAndCell();
        const cur_row: *Row = cur_rac.row;
        if (y > adjusted_count) {
            const off_p = cur_p.up(adjusted_count).?;
            const off_rac = off_p.rowAndCell();
            const off_row: *Row = off_rac.row;
            self.rowWillBeShifted(cur_p.node.page(), cur_row);
            self.rowWillBeShifted(off_p.node.page(), off_row);
            if (!left_right) {
                off_row.wrap = false;
                cur_row.wrap = false;
                off_row.wrap_continuation = false;
                cur_row.wrap_continuation = false;
            }
            const src_p = off_p;
            const src_row = off_row;
            const dst_p = cur_p;
            const dst_row = cur_row;
            if (src_p.node != dst_p.node) {
                _ = self.screens.active.clonePartialRowGrowCapacity(
                    dst_p.node,
                    dst_p.y,
                    src_p.node.page(),
                    src_row,
                    self.scrolling_region.left,
                    self.scrolling_region.right + 1,
                );
            } else {
                if (!left_right) {
                    const dst = dst_row.*;
                    dst_row.* = src_row.*;
                    src_row.* = dst;
                    cur_p.node.page().assertIntegrity();
                } else {
                    const page = cur_p.node.page();
                    page.moveCells(
                        src_row,
                        self.scrolling_region.left,
                        dst_row,
                        self.scrolling_region.left,
                        (self.scrolling_region.right - self.scrolling_region.left) + 1,
                    );
                }
            }
        } else {
            self.rowWillBeShifted(cur_p.node.page(), cur_row);
            const page = cur_p.node.page();
            const cells = page.getCells(cur_row);
            self.screens.active.clearCells(
                page,
                cur_row,
                cells[self.scrolling_region.left .. self.scrolling_region.right + 1],
            );
            if (!left_right) cur_row.reset();
        }
        cur_p.markDirty();
        y -= 1;
        if (cur_p.up(1)) |p| cur_p.* = p;
    }
}
pub fn deleteLines(self: *Terminal, count: usize) void {
    if (count == 0) return;
    if (self.screens.active.cursor.y < self.scrolling_region.top or
        self.screens.active.cursor.y > self.scrolling_region.bottom or
        self.screens.active.cursor.x < self.scrolling_region.left or
        self.screens.active.cursor.x > self.scrolling_region.right) return;
    if (comptime build_options.kitty_graphics) {
        self.screens.active.kitty_images.dirty = true;
    }
    const start_y = self.screens.active.cursor.y;
    defer {
        self.screens.active.cursorAbsolute(self.scrolling_region.left, start_y);
        self.screens.active.cursor.pending_wrap = false;
    }
    const left_right = self.scrolling_region.left > 0 or
        self.scrolling_region.right < self.cols - 1;
    const rem = self.scrolling_region.bottom - self.screens.active.cursor.y + 1;
    const adjusted_count = @min(count, rem);
    var cur_p = self.screens.active.pages.trackPin(
        self.screens.active.cursor.page_pin.*,
    ) catch |err| {
        comptime assert(@TypeOf(err) == error{OutOfMemory});
        log.err("deleteLines trackPin error err={}", .{err});
        @panic("deleteLines trackPin OOM");
    };
    defer self.screens.active.pages.untrackPin(cur_p);
    if (!left_right) self.invalidateFullWidthRowRange(
        cur_p.node,
        cur_p.down(rem - 1).?.node,
    );
    var y: usize = 0;
    while (y < rem) {
        const cur_rac = cur_p.rowAndCell();
        const cur_row: *Row = cur_rac.row;
        if (y < rem - adjusted_count) {
            const off_p = cur_p.down(adjusted_count).?;
            const off_rac = off_p.rowAndCell();
            const off_row: *Row = off_rac.row;
            self.rowWillBeShifted(cur_p.node.page(), cur_row);
            self.rowWillBeShifted(off_p.node.page(), off_row);
            if (!left_right) {
                off_row.wrap = false;
                cur_row.wrap = false;
                off_row.wrap_continuation = false;
                cur_row.wrap_continuation = false;
            }
            const src_p = off_p;
            const src_row = off_row;
            const dst_p = cur_p;
            const dst_row = cur_row;
            if (src_p.node != dst_p.node) {
                _ = self.screens.active.clonePartialRowGrowCapacity(
                    dst_p.node,
                    dst_p.y,
                    src_p.node.page(),
                    src_row,
                    self.scrolling_region.left,
                    self.scrolling_region.right + 1,
                );
            } else {
                if (!left_right) {
                    const dst = dst_row.*;
                    dst_row.* = src_row.*;
                    src_row.* = dst;
                    cur_p.node.page().assertIntegrity();
                } else {
                    const page = cur_p.node.page();
                    page.moveCells(
                        src_row,
                        self.scrolling_region.left,
                        dst_row,
                        self.scrolling_region.left,
                        (self.scrolling_region.right - self.scrolling_region.left) + 1,
                    );
                }
            }
        } else {
            self.rowWillBeShifted(cur_p.node.page(), cur_row);
            const page = cur_p.node.page();
            const cells = page.getCells(cur_row);
            self.screens.active.clearCells(
                page,
                cur_row,
                cells[self.scrolling_region.left .. self.scrolling_region.right + 1],
            );
            if (!left_right) cur_row.reset();
        }
        cur_p.markDirty();
        y += 1;
        if (cur_p.down(1)) |p| cur_p.* = p;
    }
}
pub fn insertBlanks(self: *Terminal, count: usize) void {
    self.screens.active.cursor.pending_wrap = false;
    if (count == 0) return;
    if (self.screens.active.cursor.x < self.scrolling_region.left or
        self.screens.active.cursor.x > self.scrolling_region.right) return;
    const left: [*]Cell = @ptrCast(self.screens.active.cursor.page_cell);
    var page = self.screens.active.cursor.page_pin.node.page();
    if (self.screens.active.cursor.page_cell.wide == .spacer_tail) {
        assert(self.screens.active.cursor.x > 0);
        self.screens.active.clearCells(page, self.screens.active.cursor.page_row, (left - 1)[0..2]);
    }
    const rem = self.scrolling_region.right - self.screens.active.cursor.x + 1;
    {
        const right_cell: *Cell = @ptrCast(left + (rem - 1));
        if (right_cell.wide == .wide) self.screens.active.clearCells(
            page,
            self.screens.active.cursor.page_row,
            @as([*]Cell, @ptrCast(right_cell))[0..2],
        );
    }
    const adjusted_count = @min(count, rem);
    const scroll_amount = rem - adjusted_count;
    if (scroll_amount > 0) {
        page.pauseIntegrityChecks(true);
        defer page.pauseIntegrityChecks(false);
        var x: [*]Cell = left + (scroll_amount - 1);
        const end: *Cell = @ptrCast(x);
        if (end.wide == .wide) {
            const end_multi: [*]Cell = @ptrCast(end);
            assert(end_multi[1].wide == .spacer_tail);
            self.screens.active.clearCells(
                page,
                self.screens.active.cursor.page_row,
                end_multi[0..2],
            );
        }
        while (@intFromPtr(x) >= @intFromPtr(left)) : (x -= 1) {
            const src: *Cell = @ptrCast(x);
            const dst: *Cell = @ptrCast(x + adjusted_count);
            page.swapCells(src, dst);
        }
    }
    self.screens.active.clearCells(page, self.screens.active.cursor.page_row, left[0..adjusted_count]);
    self.screens.active.cursorMarkDirty();
}
pub fn deleteChars(self: *Terminal, count_req: usize) void {
    if (count_req == 0) return;
    if (self.screens.active.cursor.x < self.scrolling_region.left or
        self.screens.active.cursor.x > self.scrolling_region.right) return;
    const left: [*]Cell = @ptrCast(self.screens.active.cursor.page_cell);
    var page = self.screens.active.cursor.page_pin.node.page();
    const rem = self.scrolling_region.right - self.screens.active.cursor.x + 1;
    const count = @min(count_req, rem);
    self.screens.active.splitCellBoundary(self.screens.active.cursor.x);
    self.screens.active.splitCellBoundary(self.screens.active.cursor.x + count);
    self.screens.active.splitCellBoundary(self.scrolling_region.right + 1);
    const scroll_amount = rem - count;
    var x: [*]Cell = left;
    if (scroll_amount > 0) {
        page.pauseIntegrityChecks(true);
        defer page.pauseIntegrityChecks(false);
        const right: [*]Cell = left + (scroll_amount - 1);
        while (@intFromPtr(x) <= @intFromPtr(right)) : (x += 1) {
            const src: *Cell = @ptrCast(x + count);
            const dst: *Cell = @ptrCast(x);
            page.swapCells(src, dst);
        }
    }
    self.screens.active.clearCells(page, self.screens.active.cursor.page_row, x[0 .. rem - scroll_amount]);
    self.screens.active.cursorResetWrap();
    self.screens.active.cursorMarkDirty();
}
pub fn eraseChars(self: *Terminal, count_req: usize) void {
    const count = end: {
        const remaining = self.cols - self.screens.active.cursor.x;
        var end = @min(remaining, @max(count_req, 1));
        if (end != remaining) {
            const last = self.screens.active.cursorCellRight(end - 1);
            if (last.wide == .wide) end += 1;
        }
        break :end end;
    };
    self.screens.active.splitCellBoundary(self.screens.active.cursor.x);
    self.screens.active.splitCellBoundary(self.screens.active.cursor.x + count);
    self.screens.active.cursorResetWrap();
    self.screens.active.cursorMarkDirty();
    const cells: [*]Cell = @ptrCast(self.screens.active.cursor.page_cell);
    if (self.screens.active.protected_mode != .iso) {
        self.screens.active.clearCells(
            self.screens.active.cursor.page_pin.node.page(),
            self.screens.active.cursor.page_row,
            cells[0..count],
        );
        return;
    }
    self.screens.active.clearUnprotectedCells(
        self.screens.active.cursor.page_pin.node.page(),
        self.screens.active.cursor.page_row,
        cells[0..count],
    );
}
pub fn eraseLine(
    self: *Terminal,
    mode: csi.EraseLine,
    protected_req: bool,
) void {
    const start, const end = switch (mode) {
        .right => right: {
            var x = self.screens.active.cursor.x;
            if (x > 0 and self.screens.active.cursor.page_cell.wide == .spacer_tail) {
                x -= 1;
            }
            self.screens.active.cursorResetWrap();
            break :right .{ x, self.cols };
        },
        .left => left: {
            var x = self.screens.active.cursor.x;
            if (self.screens.active.cursor.page_cell.wide == .wide) {
                x += 1;
            }
            break :left .{ 0, x + 1 };
        },
        .complete => complete: {
            self.screens.active.cursorResetWrap();
            break :complete .{ 0, self.cols };
        },
        else => {
            log.err("unimplemented erase line mode: {}", .{mode});
            return;
        },
    };
    self.screens.active.cursor.pending_wrap = false;
    self.screens.active.cursorMarkDirty();
    const cells: [*]Cell = cells: {
        const cells: [*]Cell = @ptrCast(self.screens.active.cursor.page_cell);
        break :cells cells - self.screens.active.cursor.x;
    };
    const protected = self.screens.active.protected_mode == .iso or protected_req;
    if (!protected) {
        self.screens.active.clearCells(
            self.screens.active.cursor.page_pin.node.page(),
            self.screens.active.cursor.page_row,
            cells[start..end],
        );
        return;
    }
    self.screens.active.clearUnprotectedCells(
        self.screens.active.cursor.page_pin.node.page(),
        self.screens.active.cursor.page_row,
        cells[start..end],
    );
}
pub fn eraseDisplay(
    self: *Terminal,
    mode: csi.EraseDisplay,
    protected_req: bool,
) void {
    const protected = self.screens.active.protected_mode == .iso or protected_req;
    switch (mode) {
        .scroll_complete => {
            self.screens.active.scrollClear() catch |err| {
                log.warn("scroll clear failed, doing a normal clear err={}", .{err});
                self.eraseDisplay(.complete, protected_req);
                return;
            };
            self.screens.active.cursor.pending_wrap = false;
            if (comptime build_options.kitty_graphics) {
                self.screens.active.kitty_images.clearScreen(
                    self.io(),
                    self.screens.active.alloc,
                    self,
                );
            }
        },
        .complete => {
            if (self.screens.active_key == .primary) at_prompt: {
                const active_br = self.screens.active.pages.getBottomRight(
                    .active,
                ) orelse break :at_prompt;
                var it = active_br.rowIterator(
                    .left_up,
                    self.screens.active.pages.getTopLeft(.active),
                );
                while (it.next()) |p| {
                    const row = p.rowAndCell().row;
                    switch (row.semantic_prompt) {
                        .prompt,
                        .prompt_continuation,
                        => break,
                        .none => {
                            if (!Cell.hasTextAny(p.cells(.all))) continue;
                            break :at_prompt;
                        },
                    }
                } else break :at_prompt;
                self.screens.active.scrollClear() catch {};
            }
            self.screens.active.clearRows(
                .{ .active = .{} },
                null,
                protected,
            );
            self.screens.active.cursor.pending_wrap = false;
            if (comptime build_options.kitty_graphics) {
                self.screens.active.kitty_images.clearScreen(
                    self.io(),
                    self.screens.active.alloc,
                    self,
                );
            }
            self.flags.dirty.clear = true;
        },
        .below => {
            self.eraseLine(.right, protected_req);
            if (self.screens.active.cursor.y + 1 < self.rows) {
                self.screens.active.clearRows(
                    .{ .active = .{ .y = self.screens.active.cursor.y + 1 } },
                    null,
                    protected,
                );
            }
            assert(!self.screens.active.cursor.pending_wrap);
        },
        .above => {
            self.eraseLine(.left, protected_req);
            if (self.screens.active.cursor.y > 0) {
                self.screens.active.clearRows(
                    .{ .active = .{ .y = 0 } },
                    .{ .active = .{ .y = self.screens.active.cursor.y - 1 } },
                    protected,
                );
            }
            assert(!self.screens.active.cursor.pending_wrap);
        },
        .scrollback => self.screens.active.eraseHistory(null),
    }
}
pub fn decaln(self: *Terminal) !void {
    const old_style = self.screens.active.cursor.style;
    self.screens.active.cursor.style = .{
        .bg_color = self.screens.active.cursor.style.bg_color,
        .fg_color = self.screens.active.cursor.style.fg_color,
    };
    errdefer self.screens.active.cursor.style = old_style;
    try self.screens.active.manualStyleUpdate();
    self.scrolling_region = .{
        .top = 0,
        .bottom = self.rows - 1,
        .left = 0,
        .right = self.cols - 1,
    };
    self.modes.set(.origin, false);
    self.setCursorPos(1, 1);
    self.screens.active.clearRows(
        .{ .active = .{} },
        null,
        false,
    );
    while (true) {
        const page = self.screens.active.cursor.page_pin.node.page();
        const row = self.screens.active.cursor.page_row;
        const cells_multi: [*]Cell = row.cells.ptr(page.memory);
        const cells = cells_multi[0..page.size.cols];
        @memset(cells, .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = .{ .data = 'E' } },
            .style_id = self.screens.active.cursor.style_id,
            .protected = false,
        });
        if (self.screens.active.cursor.style_id != style.default_id) {
            page.styles.useMultiple(
                page.memory,
                self.screens.active.cursor.style_id,
                @intCast(cells.len),
            );
            row.styled = true;
        }
        page.assertIntegrity();
        self.screens.active.cursorMarkDirty();
        if (self.screens.active.cursor.y == self.rows - 1) break;
        self.screens.active.cursorDown(1);
    }
    self.setCursorPos(1, 1);
}
pub fn kittyGraphics(
    self: *Terminal,
    io_impl: std.Io,
    alloc: Allocator,
    cmd: *kitty.graphics.Command,
) ?kitty.graphics.Response {
    return kitty.graphics.execute(io_impl, alloc, self, cmd);
}
pub fn glyphProtocol(
    self: *Terminal,
    alloc: Allocator,
    req: *const glyph.Request,
) ?glyph.Response {
    const resp = glyph.execute(alloc, &self.glyph_glossary, req);
    switch (req.*) {
        .register, .clear => self.flags.dirty.glyph_glossary = true,
        .support, .query => {},
    }
    return resp;
}
pub fn setKittyGraphicsSizeLimit(
    self: *Terminal,
    alloc: Allocator,
    limit: usize,
) void {
    if (comptime !build_options.kitty_graphics) return;
    var it = self.screens.all.iterator();
    while (it.next()) |entry| {
        const screen: *Screen = entry.value.*;
        screen.kitty_images.setLimit(self.io(), alloc, screen, limit);
    }
}
pub fn setKittyGraphicsLoadingLimits(
    self: *Terminal,
    limits: kitty.graphics.LoadingImage.Limits,
) void {
    if (comptime !build_options.kitty_graphics) return;
    var it = self.screens.all.iterator();
    while (it.next()) |entry| {
        const screen: *Screen = entry.value.*;
        screen.kitty_images.image_limits = limits;
    }
}
pub fn setAttribute(self: *Terminal, attr: sgr.Attribute) !void {
    try self.screens.active.setAttribute(attr);
}
pub fn printAttributes(self: *Terminal, buf: []u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    try writer.writeByte('0');
    const pen = self.screens.active.cursor.style;
    var attrs: [9]u8 = @splat(0);
    var i: usize = 0;
    if (pen.flags.bold) {
        attrs[i] = 1;
        i += 1;
    }
    if (pen.flags.faint) {
        attrs[i] = 2;
        i += 1;
    }
    if (pen.flags.italic) {
        attrs[i] = 3;
        i += 1;
    }
    if (pen.flags.underline != .none) {
        attrs[i] = 4;
        i += 1;
    }
    if (pen.flags.overline) {
        attrs[i] = 53;
        i += 1;
    }
    if (pen.flags.blink) {
        attrs[i] = 5;
        i += 1;
    }
    if (pen.flags.inverse) {
        attrs[i] = 7;
        i += 1;
    }
    if (pen.flags.invisible) {
        attrs[i] = 8;
        i += 1;
    }
    if (pen.flags.strikethrough) {
        attrs[i] = 9;
        i += 1;
    }
    for (attrs[0..i]) |attr| {
        if (attr == 4 and pen.flags.underline != .single) {
            try writer.print(";4:{}", .{@intFromEnum(pen.flags.underline)});
            continue;
        }
        try writer.print(";{}", .{attr});
    }
    switch (pen.fg_color) {
        .none => {},
        .palette => |idx| if (idx >= 16)
            try writer.print(";38:5:{}", .{idx})
        else if (idx >= 8)
            try writer.print(";9{}", .{idx - 8})
        else
            try writer.print(";3{}", .{idx}),
        .rgb => |rgb| try writer.print(";38:2::{[r]}:{[g]}:{[b]}", rgb),
    }
    switch (pen.bg_color) {
        .none => {},
        .palette => |idx| if (idx >= 16)
            try writer.print(";48:5:{}", .{idx})
        else if (idx >= 8)
            try writer.print(";10{}", .{idx - 8})
        else
            try writer.print(";4{}", .{idx}),
        .rgb => |rgb| try writer.print(";48:2::{[r]}:{[g]}:{[b]}", rgb),
    }
    return writer.buffered();
}
pub const DeccolmMode = enum(u1) {
    @"80_cols" = 0,
    @"132_cols" = 1,
};
pub fn deccolm(self: *Terminal, alloc: Allocator, mode: DeccolmMode) !void {
    if (!self.modes.get(.enable_mode_3)) {
        self.modes.set(.@"132_column", false);
        return;
    }
    self.modes.set(.@"132_column", mode == .@"132_cols");
    try self.resize(alloc, .{
        .cols = switch (mode) {
            .@"132_cols" => 132,
            .@"80_cols" => 80,
        },
        .rows = self.rows,
    });
    self.eraseDisplay(.complete, false);
    self.setCursorPos(1, 1);
}
pub const Resize = struct {
    cols: size.CellCountInt,
    rows: size.CellCountInt,
    cell_size_px: ?struct {
        width: u32,
        height: u32,
    } = null,
};
pub const ResizeError = error{
    OutOfMemory,
    InvalidValue,
};
const resize_tw = tripwire.module(enum {
    tabstops,
    primary_screen,
    alternate_screen,
    alternate_screen_init,
}, resize);
pub fn resize(
    self: *Terminal,
    alloc: Allocator,
    opts: Resize,
) ResizeError!void {
    const tw = resize_tw;
    if (opts.cols == 0 or opts.rows == 0) return error.InvalidValue;
    const old_width_px = self.width_px;
    const old_height_px = self.height_px;
    const old_synchronized_output = self.modes.get(.synchronized_output);
    errdefer {
        self.width_px = old_width_px;
        self.height_px = old_height_px;
        self.modes.set(.synchronized_output, old_synchronized_output);
    }
    if (opts.cell_size_px) |cell_size| {
        self.width_px = std.math.mul(
            u32,
            opts.cols,
            cell_size.width,
        ) catch std.math.maxInt(u32);
        self.height_px = std.math.mul(
            u32,
            opts.rows,
            cell_size.height,
        ) catch std.math.maxInt(u32);
    }
    self.modes.set(.synchronized_output, false);
    if (self.cols == opts.cols and self.rows == opts.rows) return;
    var new_tabstops: ?Tabstops = null;
    errdefer if (new_tabstops) |*v| v.deinit(alloc);
    if (self.cols != opts.cols) {
        try tw.check(.tabstops);
        new_tabstops = try .init(
            alloc,
            opts.cols,
            TABSTOP_INTERVAL,
        );
    }
    try tw.check(.primary_screen);
    const primary = self.screens.get(.primary).?;
    try primary.resize(.{
        .cols = opts.cols,
        .rows = opts.rows,
        .reflow = self.modes.get(.wraparound),
        .prompt_redraw = self.flags.shell_redraws_prompt,
        .pull_scrollback = self.flags.resize_pull_scrollback,
    });
    if (self.screens.get(.alternate)) |alt| alt: {
        const err: ResizeError = resize: {
            tw.check(.alternate_screen) catch |err| break :resize err;
            alt.resize(.{
                .cols = opts.cols,
                .rows = opts.rows,
                .reflow = false,
                .pull_scrollback = self.flags.resize_pull_scrollback,
            }) catch |err| break :resize err;
            break :alt;
        };
        log.warn("alternate screen resize failed, replacing it err={}", .{err});
        if (self.screens.active_key != .alternate) {
            self.screens.remove(alloc, .alternate);
            break :alt;
        }
        const charset = alt.charset;
        self.screens.switchTo(.primary);
        self.screens.remove(alloc, .alternate);
        tw.check(.alternate_screen_init) catch break :alt;
        const replacement = self.screens.getInit(
            self.io(),
            alloc,
            .alternate,
            .{
                .cols = opts.cols,
                .rows = opts.rows,
                .max_scrollback_bytes = 0,
                .kitty_image_storage_limit = if (comptime build_options.kitty_graphics)
                    primary.kitty_images.total_limit
                else
                    0,
                .kitty_image_loading_limits = if (comptime build_options.kitty_graphics)
                    primary.kitty_images.image_limits
                else {},
            },
        ) catch |init_err| {
            log.warn(
                "alternate screen replacement failed, falling back to primary err={}",
                .{init_err},
            );
            break :alt;
        };
        replacement.charset = charset;
        self.screens.switchTo(.alternate);
    }
    errdefer comptime unreachable;
    if (new_tabstops) |v| {
        self.tabstops.deinit(alloc);
        self.tabstops = v;
        new_tabstops = null;
    }
    self.flags.dirty.clear = true;
    self.cols = opts.cols;
    self.rows = opts.rows;
    self.scrolling_region = .{
        .top = 0,
        .bottom = opts.rows - 1,
        .left = 0,
        .right = opts.cols - 1,
    };
}
test "Terminal forwards optional scrollback limits" {
    const max_lines: usize = 123;
    var t = try init(testing.io, testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_bytes = null,
        .max_scrollback_lines = max_lines,
    });
    defer t.deinit(testing.allocator);
    try testing.expectEqual(
        std.math.maxInt(usize),
        t.screens.active.pages.limits.bytes.explicit,
    );
    try testing.expectEqual(
        max_lines,
        t.screens.active.pages.limits.lines.explicit,
    );
}
test "Terminal setScrollbackMaxBytes" {
    var t = try init(testing.io, testing.allocator, .{
        .cols = 80,
        .rows = 3,
        .max_scrollback_bytes = null,
    });
    defer t.deinit(testing.allocator);
    const primary = t.screens.get(.primary).?;
    const page_rows: usize = primary.pages.pages.first.?.capacity().rows;
    for (0..4 * page_rows) |_| try t.linefeed();
    const old_page_size = primary.pages.page_size;
    t.setScrollbackMaxBytes(1);
    try testing.expectEqual(@as(usize, 1), primary.pages.limits.bytes.explicit);
    try testing.expect(primary.pages.page_size < old_page_size);
    try testing.expect(
        primary.pages.page_size <= primary.pages.limits.max(.bytes),
    );
    try testing.expect(!primary.no_scrollback);
    t.setScrollbackMaxBytes(0);
    try testing.expectEqual(@as(usize, 0), primary.pages.limits.bytes.explicit);
    try testing.expect(primary.no_scrollback);
    try testing.expectEqual(
        @as(usize, primary.pages.rows),
        primary.pages.total_rows,
    );
    try testing.expect(primary.pages.viewport == .active);
    for (0..page_rows) |_| try t.linefeed();
    try testing.expectEqual(
        @as(usize, primary.pages.rows),
        primary.pages.total_rows,
    );
    t.setScrollbackMaxBytes(null);
    try testing.expectEqual(
        std.math.maxInt(usize),
        primary.pages.limits.bytes.explicit,
    );
    try testing.expect(!primary.no_scrollback);
    for (0..page_rows) |_| try t.linefeed();
    try testing.expect(primary.pages.total_rows > primary.pages.rows);
}
test "Terminal setScrollbackMaxLines" {
    var t = try init(testing.io, testing.allocator, .{
        .cols = 80,
        .rows = 3,
        .max_scrollback_bytes = null,
        .max_scrollback_lines = null,
    });
    defer t.deinit(testing.allocator);
    const primary = t.screens.get(.primary).?;
    const page_rows: usize = primary.pages.pages.first.?.capacity().rows;
    for (0..4 * page_rows) |_| try t.linefeed();
    const old_total_rows = primary.pages.total_rows;
    t.setScrollbackMaxLines(page_rows);
    try testing.expectEqual(
        page_rows,
        primary.pages.limits.lines.explicit,
    );
    try testing.expect(primary.pages.total_rows < old_total_rows);
    try testing.expect(
        !primary.pages.limits.exceeded(&primary.pages, .lines),
    );
    const limited_total_rows = primary.pages.total_rows;
    t.setScrollbackMaxLines(null);
    try testing.expectEqual(
        std.math.maxInt(usize),
        primary.pages.limits.lines.explicit,
    );
    try testing.expectEqual(limited_total_rows, primary.pages.total_rows);
    for (0..3 * page_rows) |_| try t.linefeed();
    try testing.expect(
        primary.pages.total_rows - primary.pages.rows > page_rows,
    );
}
test "Terminal: linefeed on single row screen prunes cursor page" {
    const alloc = testing.allocator;
    var t = try init(testing.io, alloc, .{ .cols = 3, .rows = 1 });
    defer t.deinit(alloc);
    t.setScrollbackMaxLines(0);
    const s = t.screens.active;
    try t.setAttribute(.{ .bold = {} });
    try s.startHyperlink("http://example.com", null);
    for (0..103) |_| try t.print('a');
    try t.resize(alloc, .{ .cols = 80, .rows = 1 });
    const node = s.cursor.page_pin.node;
    try testing.expect(node == s.pages.pages.first.?);
    try testing.expect(node.capacity().rows > s.pages.limits.max(.lines));
    const x = s.cursor.x;
    const scrolls = node.capacity().rows - node.rows() + 1;
    for (0..scrolls) |_| try t.linefeed();
    try testing.expectEqual(@as(usize, 1), s.pages.total_rows);
    try testing.expectEqual(x, s.cursor.x);
    try testing.expect(!s.cursor.page_pin.garbage);
    try t.print('b');
    const list_cell = s.pages.getCell(.{ .active = .{ .x = x } }).?;
    const page: *Page = list_cell.node.page();
    const cell = list_cell.cell;
    try testing.expectEqual(@as(u21, 'b'), cell.content.codepoint.data);
    try testing.expect(page.styles.get(page.memory, cell.style_id).flags.bold);
    try testing.expect(cell.hyperlink);
    const link = page.hyperlink_set.get(page.memory, page.lookupHyperlink(cell).?);
    try testing.expectEqualStrings("http://example.com", link.uri.slice(page.memory));
}
test "Terminal setScrollback only affects primary screen" {
    var t = try init(testing.io, testing.allocator, .{
        .cols = 80,
        .rows = 3,
    });
    defer t.deinit(testing.allocator);
    _ = try t.switchScreen(.alternate);
    const primary = t.screens.get(.primary).?;
    const alternate = t.screens.get(.alternate).?;
    t.setScrollbackMaxBytes(123);
    t.setScrollbackMaxLines(456);
    try testing.expectEqual(
        @as(usize, 123),
        primary.pages.limits.bytes.explicit,
    );
    try testing.expectEqual(
        @as(usize, 456),
        primary.pages.limits.lines.explicit,
    );
    try testing.expect(!primary.no_scrollback);
    try testing.expectEqual(
        @as(usize, 0),
        alternate.pages.limits.bytes.explicit,
    );
    try testing.expectEqual(
        std.math.maxInt(usize),
        alternate.pages.limits.lines.explicit,
    );
    try testing.expect(alternate.no_scrollback);
    try testing.expectEqual(alternate, t.screens.active);
}
test "Terminal: resize resets synchronized output" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    t.modes.set(.synchronized_output, true);
    try t.resize(alloc, .{ .cols = 10, .rows = 5 });
    try testing.expect(!t.modes.get(.synchronized_output));
}
test "Terminal: resize rejects zero dimensions before mutation" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    t.flags.dirty.clear = false;
    try testing.expectError(error.InvalidValue, t.resize(alloc, .{
        .cols = 0,
        .rows = 5,
        .cell_size_px = .{ .width = 9, .height = 18 },
    }));
    try testing.expectError(error.InvalidValue, t.resize(alloc, .{
        .cols = 10,
        .rows = 0,
        .cell_size_px = .{ .width = 9, .height = 18 },
    }));
    try testing.expectEqual(@as(size.CellCountInt, 10), t.cols);
    try testing.expectEqual(@as(size.CellCountInt, 5), t.rows);
    try testing.expectEqual(@as(u32, 100), t.width_px);
    try testing.expectEqual(@as(u32, 100), t.height_px);
    try testing.expect(!t.flags.dirty.clear);
}
test "Terminal: resize preserves pixel dimensions when omitted" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    t.width_px = 90;
    t.height_px = 90;
    try t.resize(alloc, .{ .cols = 20, .rows = 10 });
    try testing.expectEqual(@as(u32, 90), t.width_px);
    try testing.expectEqual(@as(u32, 90), t.height_px);
}
test "Terminal: resize updates pixels without changing cell dimensions" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    try t.resize(alloc, .{
        .cols = 10,
        .rows = 5,
        .cell_size_px = .{ .width = 9, .height = 18 },
    });
    try testing.expectEqual(@as(u32, 90), t.width_px);
    try testing.expectEqual(@as(u32, 90), t.height_px);
}
test "Terminal: resize pixel dimensions saturate" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 3 });
    defer t.deinit(alloc);
    try t.resize(alloc, .{
        .cols = 2,
        .rows = 3,
        .cell_size_px = .{
            .width = std.math.maxInt(u32),
            .height = std.math.maxInt(u32),
        },
    });
    try testing.expectEqual(std.math.maxInt(u32), t.width_px);
    try testing.expectEqual(std.math.maxInt(u32), t.height_px);
}
test "Terminal: resize preserves tabstops on allocation failure" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing.allocator();
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, t.resize(alloc, .{
        .cols = 513,
        .rows = 1,
    }));
    try testing.expectEqual(@as(size.CellCountInt, 10), t.cols);
    try testing.expect(t.tabstops.get(8));
}
test "Terminal: resize failure paths preserve consistent state" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    for ([_]resize_tw.FailPoint{
        .tabstops,
        .primary_screen,
        .alternate_screen,
    }) |tag| {
        const tw = resize_tw;
        defer tw.end(.reset) catch unreachable;
        var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 3 });
        defer t.deinit(alloc);
        try t.printString("primary");
        _ = try t.switchScreen(.alternate);
        try t.printString("alternate");
        _ = try t.switchScreen(.primary);
        t.width_px = 100;
        t.height_px = 50;
        t.modes.set(.synchronized_output, true);
        t.flags.dirty.clear = false;
        t.scrolling_region = .{
            .top = 1,
            .bottom = 2,
            .left = 1,
            .right = 8,
        };
        t.tabstops.unset(8);
        t.tabstops.set(3);
        const primary = t.screens.get(.primary).?;
        const alternate = t.screens.get(.alternate).?;
        const alternate_generation = t.screens.generation(.alternate);
        try testing.expectEqual(primary.pages.pages.first, primary.pages.pages.last);
        try testing.expectEqual(alternate.pages.pages.first, alternate.pages.pages.last);
        const before = t;
        const before_primary = primary.*;
        const before_alternate = alternate.*;
        const before_primary_page = try alloc.dupe(
            u8,
            primary.pages.pages.first.?.page().memory,
        );
        defer alloc.free(before_primary_page);
        const before_alternate_page = try alloc.dupe(
            u8,
            alternate.pages.pages.first.?.page().memory,
        );
        defer alloc.free(before_alternate_page);
        tw.errorAlways(tag, error.OutOfMemory);
        if (tag == .alternate_screen) {
            try t.resize(alloc, .{
                .cols = 513,
                .rows = 4,
                .cell_size_px = .{ .width = 9, .height = 18 },
            });
            try testing.expectEqual(@as(size.CellCountInt, 513), t.cols);
            try testing.expectEqual(@as(size.CellCountInt, 4), t.rows);
            try testing.expectEqual(@as(u32, 4617), t.width_px);
            try testing.expectEqual(@as(u32, 72), t.height_px);
            try testing.expect(!t.modes.get(.synchronized_output));
            try testing.expect(t.flags.dirty.clear);
            try testing.expectEqual(@as(size.CellCountInt, 513), primary.pages.cols);
            try testing.expectEqual(@as(size.CellCountInt, 4), primary.pages.rows);
            try testing.expectEqual(@as(?*Screen, null), t.screens.get(.alternate));
            try testing.expectEqual(
                alternate_generation +% 1,
                t.screens.generation(.alternate),
            );
            try testing.expectEqual(.primary, t.screens.active_key);
            try testing.expectEqual(primary, t.screens.active);
            try testing.expect(t.tabstops.get(8));
            try testing.expect(!t.tabstops.get(3));
            _ = try t.switchScreen(.alternate);
            const replacement = t.screens.get(.alternate).?;
            try testing.expectEqual(@as(size.CellCountInt, 513), replacement.pages.cols);
            try testing.expectEqual(@as(size.CellCountInt, 4), replacement.pages.rows);
            try testing.expect(replacement.pages.getCell(.{ .active = .{} }).?.cell.isEmpty());
            continue;
        }
        try testing.expectError(error.OutOfMemory, t.resize(alloc, .{
            .cols = 513,
            .rows = 4,
            .cell_size_px = .{ .width = 9, .height = 18 },
        }));
        try testing.expectEqual(before.width_px, t.width_px);
        try testing.expectEqual(before.height_px, t.height_px);
        try testing.expect(std.meta.eql(before.modes, t.modes));
        try testing.expectEqual(before.cols, t.cols);
        try testing.expectEqual(before.rows, t.rows);
        try testing.expectEqual(before.scrolling_region, t.scrolling_region);
        try testing.expectEqual(before.flags, t.flags);
        try testing.expect(std.meta.eql(before.tabstops, t.tabstops));
        try testing.expectEqual(before.screens.active_key, t.screens.active_key);
        try testing.expectEqual(before.screens.active, t.screens.active);
        try testing.expectEqual(before_primary.pages.cols, primary.pages.cols);
        try testing.expectEqual(before_primary.pages.rows, primary.pages.rows);
        try testing.expectEqual(
            before_primary.pages.total_rows,
            primary.pages.total_rows,
        );
        try testing.expect(std.meta.eql(before_primary.cursor, primary.cursor));
        try testing.expectEqualSlices(
            u8,
            before_primary_page,
            primary.pages.pages.first.?.page().memory,
        );
        try testing.expectEqual(before_alternate.pages.cols, alternate.pages.cols);
        try testing.expectEqual(before_alternate.pages.rows, alternate.pages.rows);
        try testing.expectEqual(
            before_alternate.pages.total_rows,
            alternate.pages.total_rows,
        );
        try testing.expect(std.meta.eql(before_alternate.cursor, alternate.cursor));
        try testing.expectEqualSlices(
            u8,
            before_alternate_page,
            alternate.pages.pages.first.?.page().memory,
        );
    }
}
test "Terminal: alternate resize failure replaces active alternate screen" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    const tw = resize_tw;
    defer tw.end(.reset) catch unreachable;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    _ = try t.switchScreen(.alternate);
    try testing.expectEqual(.alternate, t.screens.active_key);
    t.screens.active.charset.gl = .G1;
    try t.printString("alternate");
    const generation = t.screens.generation(.alternate);
    tw.errorAlways(.alternate_screen, error.OutOfMemory);
    try t.resize(alloc, .{ .cols = 20, .rows = 4 });
    const alternate = t.screens.get(.alternate).?;
    try testing.expectEqual(.alternate, t.screens.active_key);
    try testing.expectEqual(alternate, t.screens.active);
    try testing.expectEqual(@as(size.CellCountInt, 20), alternate.pages.cols);
    try testing.expectEqual(@as(size.CellCountInt, 4), alternate.pages.rows);
    try testing.expect(alternate.pages.getCell(.{ .active = .{} }).?.cell.isEmpty());
    try testing.expectEqual(.G1, alternate.charset.gl);
    try testing.expectEqual(generation +% 1, t.screens.generation(.alternate));
}
test "Terminal: alternate resize replacement failure falls back to primary" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    const tw = resize_tw;
    defer tw.end(.reset) catch unreachable;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    _ = try t.switchScreen(.alternate);
    tw.errorAlways(.alternate_screen, error.OutOfMemory);
    tw.errorAlways(.alternate_screen_init, error.OutOfMemory);
    try t.resize(alloc, .{ .cols = 20, .rows = 4 });
    const primary = t.screens.get(.primary).?;
    try testing.expectEqual(@as(?*Screen, null), t.screens.get(.alternate));
    try testing.expectEqual(.primary, t.screens.active_key);
    try testing.expectEqual(primary, t.screens.active);
    try testing.expectEqual(@as(size.CellCountInt, 20), primary.pages.cols);
    try testing.expectEqual(@as(size.CellCountInt, 4), primary.pages.rows);
}
pub fn setPwd(self: *Terminal, pwd: []const u8) !void {
    if (pwd.len == 0) {
        self.pwd.clearRetainingCapacity();
        return;
    }
    const capacity = std.math.add(usize, pwd.len, 1) catch
        return error.OutOfMemory;
    try self.pwd.ensureTotalCapacity(self.gpa(), capacity);
    self.pwd.items.len = capacity;
    std.mem.copyForwards(u8, self.pwd.items[0..pwd.len], pwd);
    self.pwd.items[pwd.len] = 0;
}
pub fn getPwd(self: *const Terminal) ?[:0]const u8 {
    if (self.pwd.items.len == 0) return null;
    return self.pwd.items[0 .. self.pwd.items.len - 1 :0];
}
test "Terminal: setPwd preserves a sentinel on allocation failure" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing.allocator();
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 1 });
    defer t.deinit(alloc);
    try t.pwd.ensureTotalCapacityPrecise(alloc, 3);
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, t.setPwd("pwd"));
    try testing.expect(t.getPwd() == null);
}
test "Terminal: setPwd accepts its current value" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 5, .rows = 1 });
    defer t.deinit(testing.allocator);
    try t.setPwd("file:///tmp");
    try t.setPwd(t.getPwd().?);
    try testing.expectEqualStrings("file:///tmp", t.getPwd().?);
}
pub fn setTitle(self: *Terminal, t: []const u8) !void {
    if (t.len == 0) {
        self.title.clearRetainingCapacity();
        return;
    }
    const capacity = std.math.add(usize, t.len, 1) catch
        return error.OutOfMemory;
    try self.title.ensureTotalCapacity(self.gpa(), capacity);
    self.title.items.len = capacity;
    std.mem.copyForwards(u8, self.title.items[0..t.len], t);
    self.title.items[t.len] = 0;
}
pub fn getTitle(self: *const Terminal) ?[:0]const u8 {
    if (self.title.items.len == 0) return null;
    return self.title.items[0 .. self.title.items.len - 1 :0];
}
test "Terminal: setTitle preserves a sentinel on allocation failure" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing.allocator();
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 1 });
    defer t.deinit(alloc);
    try t.title.ensureTotalCapacityPrecise(alloc, 5);
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, t.setTitle("title"));
    try testing.expect(t.getTitle() == null);
}
test "Terminal: setTitle accepts its current value" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 5, .rows = 1 });
    defer t.deinit(testing.allocator);
    try t.setTitle("Wasp");
    try t.setTitle(t.getTitle().?);
    try testing.expectEqualStrings("Wasp", t.getTitle().?);
}
pub fn switchScreen(self: *Terminal, key: ScreenSet.Key) !?*Screen {
    if (self.screens.active_key == key) return null;
    const old = self.screens.active;
    old.endHyperlink();
    const new = self.screens.get(key) orelse new: {
        const primary = self.screens.get(.primary).?;
        break :new try self.screens.getInit(
            old.io,
            old.alloc,
            key,
            .{
                .cols = self.cols,
                .rows = self.rows,
                .max_scrollback_bytes = switch (key) {
                    .primary => primary.pages.limits.bytes.explicit,
                    .alternate => 0,
                },
                .kitty_image_storage_limit = if (comptime build_options.kitty_graphics)
                    primary.kitty_images.total_limit
                else
                    0,
                .kitty_image_loading_limits = if (comptime build_options.kitty_graphics)
                    primary.kitty_images.image_limits
                else {},
            },
        );
    };
    assert(new.cursor.hyperlink_id == 0);
    new.charset = old.charset;
    new.clearSelection();
    if (comptime build_options.kitty_graphics) {
        new.kitty_images.dirty = true;
    }
    self.flags.dirty.clear = true;
    self.screens.switchTo(key);
    return old;
}
pub fn switchScreenMode(
    self: *Terminal,
    mode: SwitchScreenMode,
    enabled: bool,
) !void {
    switch (mode) {
        .@"47" => {},
        .@"1047" => if (!enabled and self.screens.active_key == .alternate) {
            self.eraseDisplay(.complete, false);
        },
        .@"1049" => if (enabled) self.saveCursor(),
    }
    const to: ScreenSet.Key = if (enabled) .alternate else .primary;
    const old_ = try self.switchScreen(to);
    switch (mode) {
        .@"47", .@"1047" => if (old_) |old| {
            self.screens.active.cursorCopy(old.cursor, .{
                .hyperlink = false,
            }) catch |err| {
                log.warn(
                    "cursor copy failed entering alt screen err={}",
                    .{err},
                );
            };
        },
        .@"1049" => if (enabled) {
            assert(self.screens.active_key == .alternate);
            self.eraseDisplay(.complete, false);
            if (old_) |old| {
                self.screens.active.cursorCopy(old.cursor, .{
                    .hyperlink = false,
                }) catch |err| {
                    log.warn(
                        "cursor copy failed entering alt screen err={}",
                        .{err},
                    );
                };
            }
        } else {
            assert(self.screens.active_key == .primary);
            self.restoreCursor();
        },
    }
}
pub const SwitchScreenMode = enum {
    @"47",
    @"1047",
    @"1049",
};
pub fn plainString(self: *Terminal, alloc: Allocator) ![]const u8 {
    return try self.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
}
pub fn plainStringUnwrapped(self: *Terminal, alloc: Allocator) ![]const u8 {
    return try self.screens.active.dumpStringAllocUnwrapped(alloc, .{ .viewport = .{} });
}
pub fn fullReset(self: *Terminal) void {
    self.screens.switchTo(.primary);
    self.screens.remove(self.screens.active.alloc, .alternate);
    self.screens.active.reset();
    self.flags = .{
        .visible = self.flags.visible,
        .resize_pull_scrollback = self.flags.resize_pull_scrollback,
        .xt_checksum = self.default_xt_checksum,
    };
    self.modes.reset();
    self.tabstops.reset(TABSTOP_INTERVAL);
    self.previous_char = null;
    self.pwd.clearRetainingCapacity();
    self.title.clearRetainingCapacity();
    self.glyph_glossary.clearAndFree(self.gpa());
    if (self.kitty_dnd) |dnd| dnd.chunking = .{};
    self.status_display = .main;
    self.scrolling_region = .{
        .top = 0,
        .bottom = self.rows - 1,
        .left = 0,
        .right = self.cols - 1,
    };
    self.setCursorStyle(.default);
    self.colors.palette.resetAll();
    self.flags.dirty.clear = true;
}
pub fn softReset(self: *Terminal) void {
    const reset_modes = [_]modespkg.Mode{
        .cursor_visible,
        .insert,
        .origin,
        .wraparound,
        .reverse_wrap,
        .reverse_wrap_extended,
        .disable_keyboard,
        .cursor_keys,
        .keypad_keys,
        .enable_left_and_right_margin,
    };
    for (reset_modes) |mode| self.modes.set(mode, self.modes.getDefault(mode));
    self.scrolling_region = .{
        .top = 0,
        .bottom = self.rows - 1,
        .left = 0,
        .right = self.cols - 1,
    };
    const screen: *Screen = self.screens.active;
    screen.cursor.style = .{};
    screen.manualStyleUpdate() catch unreachable;
    screen.cursor.protected = false;
    screen.protected_mode = .off;
    screen.charset = .{};
    screen.saved_cursor = null;
    self.status_display = .main;
    self.flags.modify_other_keys_2 = false;
    self.flags.xt_checksum = self.default_xt_checksum;
    self.setCursorStyle(.default);
    if (self.colors.palette.mask.count() > 0) {
        self.colors.palette.resetAll();
        self.flags.dirty.palette = true;
    }
}
fn isDirty(t: *const Terminal, pt: point.Point) bool {
    return t.screens.active.pages.getCell(pt).?.isDirty();
}
fn clearDirty(t: *Terminal) void {
    t.screens.active.pages.clearDirty();
}
test "Terminal: setCursorPos saturates overflowing origin offsets" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    t.scrolling_region = .{
        .top = 2,
        .bottom = 7,
        .left = 3,
        .right = 8,
    };
    t.modes.set(.origin, true);
    t.setCursorPos(std.math.maxInt(usize), std.math.maxInt(usize));
    try testing.expectEqual(@as(size.CellCountInt, 8), t.screens.active.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 7), t.screens.active.cursor.y);
}
test "Terminal: input with no control characters" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 40, .rows = 40 });
    defer t.deinit(alloc);
    for ("hello") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.screens.active.cursor.x);
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("hello", str);
    }
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 5, .y = 0 } }));
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 5, .y = 1 } }));
}
test "Terminal: input with basic wraparound" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 40 });
    defer t.deinit(alloc);
    for ("helloworldabc12") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.x);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("hello\nworld\nabc12", str);
    }
}
test "Terminal: input with basic wraparound dirty" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 40 });
    defer t.deinit(alloc);
    for ("hello") |c| try t.print(c);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 4, .y = 0 } }));
    t.clearDirty();
    try t.print('w');
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 4, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 1 } }));
}
test "Terminal: input that forces scroll" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 1, .rows = 5 });
    defer t.deinit(alloc);
    for ("abcdef") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("b\nc\nd\ne\nf", str);
    }
}
test "Terminal: input unique style per cell" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 30, .rows = 30 });
    defer t.deinit(alloc);
    for (0..t.rows) |y| {
        for (0..t.cols) |x| {
            t.setCursorPos(y, x);
            try t.setAttribute(.{ .direct_color_bg = .{
                .r = @intCast(x),
                .g = @intCast(y),
                .b = 0,
            } });
            try t.print('x');
        }
    }
}
test "Terminal: input glitch text" {
    const glitch = @embedFile("res/glitch.txt");
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 30, .rows = 30 });
    defer t.deinit(alloc);
    const grapheme_cap = cap: {
        const page = t.screens.active.pages.pages.first.?;
        break :cap page.capacity().grapheme_bytes;
    };
    while (true) {
        const page = t.screens.active.pages.pages.first.?;
        if (page.capacity().grapheme_bytes != grapheme_cap) break;
        try t.printString(glitch);
    }
    const page = t.screens.active.pages.pages.first.?;
    try testing.expect(page.capacity().grapheme_bytes > grapheme_cap);
}
test "Terminal: zero-width character at start" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    try t.print(0x200D);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}
test "Terminal: zero-width character attaches to pending wrap cell" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 2, .rows = 2 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, false);
    try t.print('x');
    try t.print('å');
    try t.print(0x0332);
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("xå̲", str);
}
test "Terminal: caps zero-width codepoints attached to one cell" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 2, .rows = 2 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, false);
    try t.print('A');
    const initial_capacity = t.screens.active.cursor.page_pin.node.capacity().grapheme_bytes;
    for (0..pagepkg.grapheme_max_len * 4) |_| try t.print(0x0301);
    const list_cell = t.screens.active.pages.getCell(.{
        .screen = .{ .x = 0, .y = 0 },
    }).?;
    try testing.expectEqual(
        @as(usize, pagepkg.grapheme_max_len),
        list_cell.node.page().lookupGrapheme(list_cell.cell).?.len,
    );
    try testing.expectEqual(
        initial_capacity,
        list_cell.node.capacity().grapheme_bytes,
    );
}
test "Terminal: print single very long line" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);
    for (0..1000) |_| try t.print('x');
}
test "Terminal: print wide char" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    try t.print(0x1F600);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F600), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}
test "Terminal: print wide char at edge creates spacer head" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    t.setCursorPos(1, 10);
    try t.print(0x1F600);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 9, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F600), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 1 } }));
}
test "Terminal: print wide char with 1-column width" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 1, .rows = 2 });
    defer t.deinit(alloc);
    try t.print('😀');
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}
test "Terminal: print wide char in single-width terminal" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 1, .rows = 80 });
    defer t.deinit(testing.allocator);
    try t.print(0x1F600);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}
test "Terminal: print over wide char at 0,0" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    try t.print(0x1F600);
    t.setCursorPos(0, 0);
    try t.print('A');
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'A'), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 1 } }));
}
test "Terminal: print over wide char at col 0 corrupts previous row" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    for (0..10) |_| try t.print(0x4E2D);
    t.setCursorPos(2, 1);
    try t.print('A');
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        try testing.expectEqual(Cell.Wide.narrow, list_cell.cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 8, .y = 0 } }).?;
        try testing.expectEqual(Cell.Wide.wide, list_cell.cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 9, .y = 0 } }).?;
        try testing.expectEqual(Cell.Wide.spacer_tail, list_cell.cell.wide);
    }
}
test "Terminal: print over wide spacer tail" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);
    try t.print('橋');
    t.setCursorPos(1, 2);
    try t.print('X');
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'X'), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(" X", str);
    }
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}
test "Terminal: print over wide char with bold" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    try t.setAttribute(.{ .bold = {} });
    try t.print(0x1F600);
    {
        const page = t.screens.active.cursor.page_pin.node.page();
        try testing.expectEqual(@as(usize, 1), page.styles.count());
    }
    t.setCursorPos(0, 0);
    try t.setAttribute(.{ .unset = {} });
    try t.print('A');
    {
        const page = t.screens.active.cursor.page_pin.node.page();
        try testing.expectEqual(@as(usize, 0), page.styles.count());
    }
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}
test "Terminal: print over wide char with bg color" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    try t.print(0x1F600);
    {
        const page = t.screens.active.cursor.page_pin.node.page();
        try testing.expectEqual(@as(usize, 1), page.styles.count());
    }
    t.setCursorPos(0, 0);
    try t.setAttribute(.{ .unset = {} });
    try t.print('A');
    {
        const page = t.screens.active.cursor.page_pin.node.page();
        try testing.expectEqual(@as(usize, 0), page.styles.count());
    }
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}
test "Terminal: print multicodepoint grapheme, disabled mode 2027" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    try t.print(0x1F468);
    try t.print(0x200D);
    try t.print(0x1F469);
    try t.print(0x200D);
    try t.print(0x1F467);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 6), t.screens.active.cursor.x);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F468), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = list_cell.node.page().lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
        try testing.expect(list_cell.node.page().lookupGrapheme(cell) == null);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F469), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = list_cell.node.page().lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 3, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
        try testing.expect(list_cell.node.page().lookupGrapheme(cell) == null);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F467), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expect(list_cell.node.page().lookupGrapheme(cell) == null);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 5, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
        try testing.expect(list_cell.node.page().lookupGrapheme(cell) == null);
    }
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}
test "Terminal: enabling grapheme mode handles stored breaks" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 5, .rows = 1 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, false);
    try t.print('a');
    try t.print(0x200B);
    t.modes.set(.grapheme_cluster, true);
    try t.print(0x0301);
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("a\xE2\x80\x8B\xCC\x81", str);
}
fn expectGraphemeWidthParity(cps: []const u21) !void {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 5 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    var expected: usize = 0;
    var i: usize = 0;
    while (i < cps.len) {
        const result = unicode.graphemeWidth(u21, cps[i..]);
        try testing.expect(result.len > 0);
        i += result.len;
        expected += result.width;
    }
    for (cps) |cp| try t.print(cp);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(expected, t.screens.active.cursor.x);
}
test "Terminal: graphemeWidth parity" {
    try expectGraphemeWidthParity(&.{ 0x2764, 0xFE0F });
    try expectGraphemeWidthParity(&.{ 'x', 0xFE0F, 0xFE0F });
    try expectGraphemeWidthParity(&.{ 0x231A, 0xFE0E, 0xFE0F });
    try expectGraphemeWidthParity(&.{ 0x1F3F4, 0x200D, 0x2620, 0xFE0F });
    try expectGraphemeWidthParity(&.{ 0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467 });
    try expectGraphemeWidthParity(&.{ 0x23, 0xFE0F, 0x20E3 });
    try expectGraphemeWidthParity(&.{ '1', 0x20E3 });
    try expectGraphemeWidthParity(&.{ 0x1F44B, 0x1F3FF });
    try expectGraphemeWidthParity(&.{ 0x1F1E6, 0x1F1E7, 0x1F1E8 });
    try expectGraphemeWidthParity(&.{ 'a', 'b' });
    try expectGraphemeWidthParity(&.{ 0x0301, 0x0302 });
}
test "Terminal: VS16 doesn't make character with 2027 disabled" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, false);
    try t.print(0x2764);
    try t.print(0xFE0F);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("❤️", str);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x2764), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
        const cps = list_cell.node.page().lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
}
test "Terminal: ignored VS16 doesn't mark dirty" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, false);
    try t.print(0x2764);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();
    try t.print(0xFE0F);
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}
test "Terminal: print invalid VS16 non-grapheme" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    try t.print('x');
    try t.print(0xFE0F);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'x'), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
    }
}
test "Terminal: invalid VS16 doesn't mark dirty" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, false);
    try t.print('x');
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();
    try t.print(0xFE0F);
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}
test "Terminal: variation selectors apply to preceding codepoint" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 5, .rows = 5 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    try t.print(0x1F3F4);
    try t.print(0x200D);
    try t.print(0x2620);
    try t.print(0xFE0F);
    const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
    const cell = list_cell.cell;
    try testing.expectEqual(@as(u21, 0x1F3F4), cell.content.codepoint.data);
    try testing.expect(cell.hasGrapheme());
    try testing.expectEqualSlices(u21, &.{ 0x200D, 0x2620, 0xFE0F }, list_cell.node.page().lookupGrapheme(cell).?);
}
test "Terminal: print multicodepoint grapheme, mode 2027" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    try t.print(0x1F468);
    try t.print(0x200D);
    try t.print(0x1F469);
    try t.print(0x200D);
    try t.print(0x1F467);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F468), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = list_cell.node.page().lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 4), cps.len);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}
test "Terminal: keypad sequence VS15" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    try t.print(0x23);
    try t.print(0xFE0E);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x23), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}
test "Terminal: keypad sequence VS16" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    try t.print(0x23);
    try t.print(0xFE0F);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x23), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
}
test "Terminal: Fitzpatrick skin tone next valid base" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    try t.print(0x1F44B);
    try t.print(0x1F3FF);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F44B), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
}
test "Terminal: Fitzpatrick skin tone next to non-base" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    try t.print(0x22);
    try t.print(0x1F3FF);
    try t.print(0x22);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.x);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x22), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F3FF), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 3, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x22), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}
test "Terminal: multicodepoint grapheme marks dirty on every codepoint" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    try t.print(0x1F468);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();
    try t.print(0x200D);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();
    try t.print(0x1F469);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();
    try t.print(0x200D);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();
    try t.print(0x1F467);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
}
test "Terminal: VS15 to make narrow character" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    try t.print(0x2614);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try t.print(0xFE0E);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("☔︎", str);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x2614), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
        const cps = list_cell.node.page().lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
}
test "Terminal: VS15 on already narrow emoji" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    try t.print(0x26C8);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();
    try t.print(0xFE0E);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("⛈︎", str);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x26C8), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
        const cps = list_cell.node.page().lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
}
test "Terminal: print invalid VS15 following emoji is wide" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    try t.print('\u{1F9E0}');
    try t.print(0xFE0E);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '\u{1F9E0}'), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}
test "Terminal: print invalid VS15 in emoji ZWJ sequence" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    try t.print('\u{1F469}');
    try t.print(0xFE0E);
    try t.print('\u{200D}');
    try t.print('\u{1F466}');
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '\u{1F469}'), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{ '\u{200D}', '\u{1F466}' }, list_cell.node.page().lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}
test "Terminal: VS15 to make narrow character with pending wrap" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 4 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    try testing.expect(t.modes.get(.wraparound));
    try t.print(0x1F34B);
    try t.print(0x2614);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 3), t.screens.active.cursor.x);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    try t.print(0xFE0E);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 3), t.screens.active.cursor.x);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("🍋☔︎", str);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x2614), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
        const cps = list_cell.node.page().lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
    {
        const lemon_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?.cell;
        try testing.expectEqual(@as(u21, 0x1F34B), lemon_cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.wide, lemon_cell.wide);
        const spacer_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?.cell;
        try testing.expectEqual(@as(u21, 0), spacer_cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.spacer_tail, spacer_cell.wide);
    }
}
test "Terminal: VS15 narrows wide cell under cursor with wraparound disabled" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    t.modes.set(.wraparound, false);
    t.setCursorPos(1, 4);
    try t.print(0x2614);
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(1, 4);
    t.setCursorPos(1, 4);
    try t.print(0xFE0E);
    try testing.expectEqual(@as(usize, 3), t.screens.active.cursor.x);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    const base = t.screens.active.pages.getCell(.{ .screen = .{ .x = 3, .y = 0 } }).?.cell;
    try testing.expectEqual(Cell.Wide.narrow, base.wide);
    try testing.expect(base.hasGrapheme());
    const tail = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?.cell;
    try testing.expectEqual(Cell.Wide.narrow, tail.wide);
}
test "Terminal: VS15 narrows wide cell under restored pending cursor" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(1, 4);
    t.setCursorPos(1, 4);
    try t.print('X');
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.saveCursor();
    t.setLeftAndRightMargin(1, 5);
    t.setCursorPos(1, 4);
    try t.print(0x2614);
    t.restoreCursor();
    try testing.expect(t.screens.active.cursor.pending_wrap);
    try t.print(0xFE0E);
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.x);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    const base = t.screens.active.pages.getCell(.{ .screen = .{ .x = 3, .y = 0 } }).?.cell;
    try testing.expectEqual(Cell.Wide.narrow, base.wide);
    try testing.expect(base.hasGrapheme());
    const tail = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?.cell;
    try testing.expectEqual(Cell.Wide.narrow, tail.wide);
}
test "Terminal: VS16 to make wide character on next line" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 3 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    t.cursorRight(2);
    try t.print('#');
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 2, .y = 0 } }));
    t.clearDirty();
    try t.print(0xFE0F);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 2, .y = 0 } }));
    t.clearDirty();
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '#'), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{0xFE0F}, list_cell.node.page().lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}
test "Terminal: VS16 to make wide character on next line with hyperlink" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 3 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    try t.screens.active.startHyperlink("http://example.com", null);
    t.cursorRight(2);
    try t.print('#');
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    try t.print(0xFE0F);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
        try testing.expect(cell.hyperlink);
        try testing.expect(list_cell.row.wrap);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '#'), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{0xFE0F}, list_cell.node.page().lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expect(cell.hyperlink);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
        try testing.expect(cell.hyperlink);
    }
}
test "Terminal: VS16 widening when the spacer tail grows the page" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 10, .cols = 20 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    try t.screens.active.startHyperlink("http://example.com", null);
    while (true) {
        const page = t.screens.active.cursor.page_pin.node.page();
        const map = page.hyperlink_map.map(page.memory);
        if (map.maxLoad() - map.count() == 1) break;
        try t.print('x');
    }
    const x = t.screens.active.cursor.x;
    const y = t.screens.active.cursor.y;
    try t.print('#');
    try t.print(0xFE0F);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = x,
            .y = y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '#'), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(
            u21,
            &.{0xFE0F},
            list_cell.node.page().lookupGrapheme(cell).?,
        );
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = x + 1,
            .y = y,
        } }).?;
        try testing.expectEqual(Cell.Wide.spacer_tail, list_cell.cell.wide);
    }
}
test "Terminal: grapheme transfer when widening wraps to the next line" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 3 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    t.cursorRight(2);
    try t.print(0x263A);
    try t.print(0x200D);
    try t.print(0x2764);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = 2,
            .y = 0,
        } }).?;
        try testing.expectEqual(Cell.Wide.spacer_head, list_cell.cell.wide);
        try testing.expect(list_cell.row.wrap);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = 0,
            .y = 1,
        } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x263A), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expectEqualSlices(
            u21,
            &.{ 0x200D, 0x2764 },
            list_cell.node.page().lookupGrapheme(cell).?,
        );
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = 1,
            .y = 1,
        } }).?;
        try testing.expectEqual(Cell.Wide.spacer_tail, list_cell.cell.wide);
    }
}
test "Terminal: grapheme transfer when widening wraps below the scroll region" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 3, .cols = 3 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    t.setTopAndBottomMargin(1, 2);
    t.setCursorPos(3, 3);
    try t.print(0x2764);
    try t.print(0x200D);
    try t.print(0x1F44D);
    const base = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 2 } }).?;
    try testing.expectEqual(@as(u21, 0x2764), base.cell.codepoint());
    try testing.expectEqualSlices(
        u21,
        &.{ 0x200D, 0x1F44D },
        base.node.page().lookupGrapheme(base.cell).?,
    );
}
test "Terminal: grapheme transfer when widening scrolls a single row" {
    for ([_]bool{ false, true }) |alternate| {
        for ([_]bool{ false, true }) |margins| {
            var t = try init(testing.io, testing.allocator, .{ .rows = 1, .cols = 5 });
            defer t.deinit(testing.allocator);
            t.modes.set(.grapheme_cluster, true);
            if (alternate) _ = try t.switchScreen(.alternate);
            t.setCursorPos(1, 5);
            try t.print('a');
            try t.print(0x0301);
            try t.index();
            if (margins) {
                t.modes.set(.enable_left_and_right_margin, true);
                t.setLeftAndRightMargin(3, 0);
            }
            t.setCursorPos(1, 5);
            try t.print(0x2764);
            try t.print(0x200D);
            try t.print(0x1F44D);
            const x: size.CellCountInt = if (margins) 2 else 0;
            const base = t.screens.active.pages.getCell(.{ .active = .{ .x = x, .y = 0 } }).?;
            try testing.expectEqual(@as(u21, 0x2764), base.cell.codepoint());
            try testing.expectEqualSlices(
                u21,
                &.{ 0x200D, 0x1F44D },
                base.node.page().lookupGrapheme(base.cell).?,
            );
            if (!alternate) {
                const history = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
                try testing.expectEqual(@as(u21, 'a'), history.cell.codepoint());
                try testing.expectEqualSlices(u21, &.{0x0301}, history.node.page().lookupGrapheme(history.cell).?);
            }
        }
    }
}
test "Terminal: grapheme transfer when widening wraps to a page without grapheme capacity" {
    const rows = pagepkg.std_capacity.rows;
    const cols = pagepkg.std_capacity.cols;
    var t = try init(testing.io, testing.allocator, .{ .rows = rows, .cols = cols });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    t.cursorDown(rows - 1);
    for (rows..t.screens.active.pages.pages.first.?.capacity().rows + 1) |_| {
        try t.index();
    }
    const pages = &t.screens.active.pages;
    try testing.expect(pages.pages.first != pages.pages.last);
    try testing.expect(try pages.compact(pages.pages.last.?) != null);
    try testing.expectEqual(0, pages.pages.last.?.capacity().grapheme_bytes);
    t.setCursorPos(rows - 1, cols);
    try t.print(0x2764);
    try t.print(0x200D);
    try t.print(0x1F44D);
    try testing.expect(pages.pages.last.?.capacity().grapheme_bytes > 0);
    const base = pages.getCell(.{ .active = .{ .x = 0, .y = rows - 1 } }).?;
    try testing.expectEqual(pages.pages.last.?, base.node);
    try testing.expectEqual(Cell.Wide.wide, base.cell.wide);
    try testing.expectEqual(@as(u21, 0x2764), base.cell.codepoint());
    try testing.expectEqualSlices(
        u21,
        &.{ 0x200D, 0x1F44D },
        base.node.page().lookupGrapheme(base.cell).?,
    );
}
test "Terminal: VS16 to make wide character with pending wrap" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 3 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    t.cursorRight(1);
    try t.print('#');
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print(0xFE0F);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '#'), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{0xFE0F}, list_cell.node.page().lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}
test "Terminal: VS16 to make wide character with mode 2027" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    try t.print(0x2764);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();
    try t.print(0xFE0F);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("❤️", str);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x2764), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = list_cell.node.page().lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
}
test "Terminal: VS16 repeated with mode 2027" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    try t.print(0x2764);
    try t.print(0xFE0F);
    try t.print(0x2764);
    try t.print(0xFE0F);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("❤️❤️", str);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x2764), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = list_cell.node.page().lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x2764), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = list_cell.node.page().lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
}
test "Terminal: print invalid VS16 grapheme" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    try t.print('x');
    try t.print(0xFE0F);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'x'), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}
test "Terminal: print invalid VS16 with second char" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    try t.print('x');
    try t.print(0xFE0F);
    try t.print('y');
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'x'), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'y'), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}
test "Terminal: print grapheme ò (o with nonspacing mark) should be narrow" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    try t.print('o');
    try t.print(0x0300);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'o'), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{0x0300}, list_cell.node.page().lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}
test "Terminal: print Devanagari grapheme should be wide" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    try t.print(0x0915);
    try t.print(0x094D);
    try t.print(0x200D);
    try t.print(0x0937);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x0915), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{ 0x094D, 0x200D, 0x0937 }, list_cell.node.page().lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}
test "Terminal: print Devanagari grapheme should be wide on next line" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 3 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    t.cursorRight(2);
    try t.print(0x0915);
    try t.print(0x094D);
    try t.print(0x200D);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    try t.print(0x0937);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x0915), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{ 0x094D, 0x200D, 0x0937 }, list_cell.node.page().lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}
test "Terminal: print Devanagari grapheme should be wide on next page" {
    const rows = pagepkg.std_capacity.rows;
    const cols = pagepkg.std_capacity.cols;
    var t = try init(testing.io, testing.allocator, .{ .rows = rows, .cols = cols });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    t.cursorDown(rows - 1);
    for (rows..t.screens.active.pages.pages.first.?.capacity().rows) |_| {
        try t.index();
    }
    t.cursorRight(cols - 1);
    try testing.expectEqual(cols - 1, t.screens.active.cursor.x);
    try testing.expectEqual(rows - 1, t.screens.active.cursor.y);
    try t.print(0x0915);
    try t.print(0x094D);
    try t.print(0x200D);
    try testing.expectEqual(cols - 1, t.screens.active.cursor.x);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    try t.print(0x0937);
    try testing.expectEqual(rows - 1, t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = cols - 1, .y = rows - 2 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = rows - 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x0915), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{ 0x094D, 0x200D, 0x0937 }, list_cell.node.page().lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 1, .y = rows - 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}
test "Terminal: print invalid VS16 with second char (combining)" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    try t.print('n');
    try t.print(0xFE0F);
    try t.print(0x0303);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'n'), cell.content.codepoint.data);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{'\u{0303}'}, list_cell.node.page().lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}
test "Terminal: overwrite grapheme should clear grapheme data" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    try t.print(0x26C8);
    try t.print(0xFE0E);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();
    t.setCursorPos(1, 1);
    try t.print('A');
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'A'), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}
test "Terminal: overwrite multicodepoint grapheme clears grapheme data" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    try t.print(0x1F468);
    try t.print(0x200D);
    try t.print(0x1F469);
    try t.print(0x200D);
    try t.print(0x1F467);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    const page = t.screens.active.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 1), page.graphemeCount());
    t.setCursorPos(1, 1);
    t.clearDirty();
    try t.print('X');
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), page.graphemeCount());
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X", str);
    }
}
test "Terminal: overwrite multicodepoint grapheme tail clears grapheme data" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    try t.print(0x1F468);
    try t.print(0x200D);
    try t.print(0x1F469);
    try t.print(0x200D);
    try t.print(0x1F467);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    const page = t.screens.active.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 1), page.graphemeCount());
    t.setCursorPos(1, 2);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(" X", str);
    }
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), page.graphemeCount());
}
test "Terminal: print breaks valid grapheme cluster with Prepend + ASCII for speed" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, true);
    try t.print('_');
    try t.print(0x0600);
    try t.print('1');
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 3), t.screens.active.cursor.x);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x0600), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '1'), cell.content.codepoint.data);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}
test "Terminal: print writes to bottom if scrolled" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 5, .rows = 2 });
    defer t.deinit(testing.allocator);
    for ("hello") |c| try t.print(c);
    t.setCursorPos(0, 0);
    try t.index();
    try t.index();
    try t.index();
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
    t.screens.active.scroll(.{ .top = {} });
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello", str);
    }
    try t.print('A');
    t.screens.active.scroll(.{ .active = {} });
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nA", str);
    }
    try testing.expect(t.isDirty(.{ .active = .{
        .x = t.screens.active.cursor.x,
        .y = t.screens.active.cursor.y,
    } }));
}
test "Terminal: print charset" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    t.configureCharset(.G1, .dec_special);
    t.configureCharset(.G2, .dec_special);
    t.configureCharset(.G3, .dec_special);
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    try t.print('`');
    t.configureCharset(.G0, .utf8);
    try t.print('`');
    t.configureCharset(.G0, .ascii);
    try t.print('`');
    t.configureCharset(.G0, .dec_special);
    try t.print('`');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("```◆", str);
    }
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}
test "Terminal: print charset outside of ASCII" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    t.configureCharset(.G1, .dec_special);
    t.configureCharset(.G2, .dec_special);
    t.configureCharset(.G3, .dec_special);
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.configureCharset(.G0, .dec_special);
    try t.print('`');
    try t.print(0x1F600);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("◆😀", str);
    }
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}
test "Terminal: print wide codepoint in a charset prints it unmapped" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 2 });
    defer t.deinit(testing.allocator);
    t.configureCharset(.G0, .dec_special);
    try t.print('`');
    try t.print(0x1F600);
    try t.print('a');
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.x);
    const cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?.cell;
    try testing.expectEqual(@as(u21, 0x1F600), cell.codepoint());
    try testing.expectEqual(.wide, cell.wide);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("◆😀▒", str);
    }
}
test "Terminal: print single shift is used up by a combining character" {
    for ([_]bool{ false, true }) |cluster| {
        var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 2 });
        defer t.deinit(testing.allocator);
        t.modes.set(.grapheme_cluster, cluster);
        t.configureCharset(.G2, .british);
        try t.print('#');
        t.invokeCharset(.GL, .G2, true);
        try t.print(0x0301);
        try testing.expectEqual(null, t.screens.active.charset.single_shift);
        try t.print('#');
        try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
        const cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?.cell;
        try testing.expectEqual(@as(u21, '#'), cell.codepoint());
    }
}
test "Terminal: VS16 moving a character to the next line keeps it unmapped" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 3, .rows = 5 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    t.cursorRight(2);
    try t.print('#');
    t.configureCharset(.G0, .british);
    try t.print(0xFE0F);
    const cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?.cell;
    try testing.expectEqual(@as(u21, '#'), cell.codepoint());
    try testing.expectEqual(.wide, cell.wide);
}
test "Terminal: print invoke charset" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    t.configureCharset(.G1, .dec_special);
    try t.print('`');
    t.clearDirty();
    t.invokeCharset(.GL, .G1, false);
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    try t.print('`');
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    try t.print('`');
    t.invokeCharset(.GL, .G0, false);
    try t.print('`');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("`◆◆`", str);
    }
}
test "Terminal: print invoke charset single" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    t.configureCharset(.G1, .dec_special);
    try t.print('`');
    t.invokeCharset(.GL, .G1, true);
    try t.print('`');
    try t.print('`');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("`◆`", str);
    }
}
test "Terminal: print kitty unicode placeholder" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    try t.print(kitty.graphics.unicode.placeholder);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, kitty.graphics.unicode.placeholder), cell.content.codepoint.data);
        try testing.expect(list_cell.row.kitty_virtual_placeholder);
    }
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}
test "Terminal: soft wrap" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 3, .rows = 80 });
    defer t.deinit(testing.allocator);
    for ("hello") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hel\nlo", str);
    }
}
test "Terminal: soft wrap with semantic prompt" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 3, .rows = 80 });
    defer t.deinit(testing.allocator);
    try t.semanticPrompt(.init(.prompt_start));
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    for ("hello") |c| try t.print(c);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        try testing.expectEqual(.prompt, list_cell.row.semantic_prompt);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        try testing.expectEqual(.prompt_continuation, list_cell.row.semantic_prompt);
    }
}
test "Terminal: disabled wraparound with wide char and one space" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);
    t.modes.set(.wraparound, false);
    try t.printString("AAAA");
    t.clearDirty();
    try t.print(0x1F6A8);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.x);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AAAA", str);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}
test "Terminal: disabled wraparound with wide char and no space" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);
    t.modes.set(.wraparound, false);
    try t.printString("AAAAA");
    t.clearDirty();
    try t.print(0x1F6A8);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.x);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AAAAA", str);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'A'), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}
test "Terminal: disabled wraparound with wide grapheme and half space" {
    var t = try init(testing.io, testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    t.modes.set(.wraparound, false);
    try t.printString("AAAA");
    try t.print(0x2764);
    t.clearDirty();
    try t.print(0xFE0F);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.x);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AAAA❤", str);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '❤'), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}
test "Terminal: print with wraparound disabled clears pending wrap after CBT" {
    for ([_]bool{ true, false }) |wrap_on_fill| {
        var t = try init(testing.io, testing.allocator, .{ .rows = 2, .cols = 6 });
        defer t.deinit(testing.allocator);
        t.modes.set(.wraparound, wrap_on_fill);
        try t.printString("abcdef");
        t.modes.set(.wraparound, false);
        t.horizontalTabBack();
        try testing.expect(t.screens.active.cursor.pending_wrap);
        try t.print('x');
        try testing.expect(!t.screens.active.cursor.pending_wrap);
        t.modes.set(.wraparound, true);
        try t.print('y');
        try testing.expectEqual(0, t.screens.active.cursor.y);
        try testing.expectEqual(2, t.screens.active.cursor.x);
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("xycdef", str);
    }
}
test "Terminal: print right margin wrap" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.printString("123456789");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(3, 5);
    t.setCursorPos(1, 5);
    try t.printString("XY");
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1234X6789\n  Y", str);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        const row = list_cell.row;
        try testing.expect(!row.wrap);
    }
}
test "Terminal: print right margin wrap dirty tracking" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.printString("123456789");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(3, 5);
    t.setCursorPos(1, 5);
    t.clearDirty();
    try t.print('X');
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 4, .y = 0 } }));
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 2, .y = 1 } }));
    t.clearDirty();
    try t.print('Y');
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 4, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 2, .y = 1 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1234X6789\n  Y", str);
    }
}
test "Terminal: print right margin outside" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.printString("123456789");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(3, 5);
    t.setCursorPos(1, 6);
    t.clearDirty();
    try t.printString("XY");
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("12345XY89", str);
    }
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 5, .y = 0 } }));
}
test "Terminal: print right margin outside wrap" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.printString("123456789");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(3, 5);
    t.setCursorPos(1, 10);
    try t.printString("XY");
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("123456789X\n  Y", str);
    }
}
test "Terminal: print wide char at right margin does not create spacer head" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(3, 5);
    t.setCursorPos(1, 5);
    try t.print(0x1F600);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.x);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 4, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 4, .y = 1 } }));
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
        const row = list_cell.row;
        try testing.expect(!row.wrap);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F600), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 3, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}
test "Terminal: print with hyperlink" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("123456");
    for (0..6) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
    }
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}
test "Terminal: print over cell with same hyperlink" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("123456");
    t.setCursorPos(1, 1);
    try t.printString("123456");
    for (0..6) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
    }
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}
test "Terminal: print and end hyperlink" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("123");
    t.screens.active.endHyperlink();
    try t.printString("456");
    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
    }
    for (3..6) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
    }
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}
test "Terminal: print and change hyperlink" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    try t.screens.active.startHyperlink("http://one.example.com", null);
    try t.printString("123");
    try t.screens.active.startHyperlink("http://two.example.com", null);
    try t.printString("456");
    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
    }
    for (3..6) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 2), id);
    }
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}
test "Terminal: overwrite hyperlink" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    try t.screens.active.startHyperlink("http://one.example.com", null);
    try t.printString("123");
    t.setCursorPos(1, 1);
    t.screens.active.endHyperlink();
    try t.printString("456");
    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const page = list_cell.node.page();
        const row = list_cell.row;
        try testing.expect(!row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
        try testing.expect(page.lookupHyperlink(cell) == null);
        try testing.expectEqual(0, page.hyperlink_set.count());
    }
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}
test "Terminal: print wide char at right edge with hyperlink" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.screens.active.startHyperlink("http://example.com", null);
    t.setCursorPos(1, 10);
    try t.print(0x4E2D);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 9, .y = 0 } }).?;
        try testing.expectEqual(Cell.Wide.spacer_head, list_cell.cell.wide);
        try testing.expect(list_cell.cell.hyperlink);
        try testing.expect(list_cell.row.wrap);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        try testing.expectEqual(@as(u21, 0x4E2D), list_cell.cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.wide, list_cell.cell.wide);
        try testing.expect(list_cell.cell.hyperlink);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 1 } }).?;
        try testing.expectEqual(Cell.Wide.spacer_tail, list_cell.cell.wide);
        try testing.expect(list_cell.cell.hyperlink);
    }
}
test "Terminal: scrollClear across pages keeps cursor hyperlink refs page-local" {
    const alloc = testing.allocator;
    const input = "A\x1b[48111b\x1b]8;;\x93\x1b[11A\x1b[22JB\x1b]8;;\x1b";
    var t = try init(testing.io, alloc, .{ .cols = 200, .rows = 50 });
    defer t.deinit(alloc);
    {
        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice(input);
    }
    var node_ = t.screens.active.pages.pages.first;
    while (node_) |node| : (node_ = node.next) {
        const page = node.page();
        const cap = page.hyperlink_set.layout.cap;
        if (cap == 0) continue;
        const holders = try alloc.alloc(u32, cap);
        defer alloc.free(holders);
        @memset(holders, 0);
        for (page.rows.ptr(page.memory)[0..page.size.rows]) |*row| {
            if (!row.hyperlink) continue;
            for (row.cells.ptr(page.memory)[0..page.size.cols]) |*cell| {
                if (!cell.hyperlink) continue;
                const id = page.lookupHyperlink(cell) orelse continue;
                if (id < cap) holders[id] += 1;
            }
        }
        for (holders, 0..) |held, id| {
            if (held == 0) continue;
            const refs = page.hyperlink_set.refCount(page.memory, @intCast(id));
            try testing.expect(refs >= held);
        }
    }
    const cursor = &t.screens.active.cursor;
    if (cursor.hyperlink_id != 0) {
        const page = cursor.page_pin.node.page();
        try testing.expect(
            page.hyperlink_set.refCount(page.memory, cursor.hyperlink_id) > 0,
        );
    }
}
test "Terminal: linefeed and carriage return" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    for ("hello") |c| try t.print(c);
    t.clearDirty();
    t.carriageReturn();
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    try t.linefeed();
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 1 } }));
    for ("world") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.screens.active.cursor.x);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello\nworld", str);
    }
}
test "Terminal: linefeed unsets pending wrap" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 5, .rows = 80 });
    defer t.deinit(testing.allocator);
    for ("hello") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap == true);
    t.clearDirty();
    try t.linefeed();
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.screens.active.cursor.pending_wrap == false);
}
test "Terminal: linefeed mode automatic carriage return" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    t.modes.set(.linefeed, true);
    try t.printString("123456");
    try t.linefeed();
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("123456\nX", str);
    }
}
test "Terminal: carriage return unsets pending wrap" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 5, .rows = 80 });
    defer t.deinit(testing.allocator);
    for ("hello") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap == true);
    t.carriageReturn();
    try testing.expect(t.screens.active.cursor.pending_wrap == false);
}
test "Terminal: carriage return origin mode moves to left margin" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 5, .rows = 80 });
    defer t.deinit(testing.allocator);
    t.modes.set(.origin, true);
    t.screens.active.cursor.x = 0;
    t.scrolling_region.left = 2;
    t.carriageReturn();
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
}
test "Terminal: carriage return left of left margin moves to zero" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 5, .rows = 80 });
    defer t.deinit(testing.allocator);
    t.screens.active.cursor.x = 1;
    t.scrolling_region.left = 2;
    t.carriageReturn();
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
}
test "Terminal: carriage return right of left margin moves to left margin" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 5, .rows = 80 });
    defer t.deinit(testing.allocator);
    t.screens.active.cursor.x = 3;
    t.scrolling_region.left = 2;
    t.carriageReturn();
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
}
test "Terminal: backspace" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    for ("hello") |c| try t.print(c);
    t.backspace();
    try t.print('y');
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.screens.active.cursor.x);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("helly", str);
    }
}
test "Terminal: horizontal tabs" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 20, .rows = 5 });
    defer t.deinit(alloc);
    try t.print('1');
    t.horizontalTab();
    try testing.expectEqual(@as(usize, 8), t.screens.active.cursor.x);
    t.horizontalTab();
    try testing.expectEqual(@as(usize, 16), t.screens.active.cursor.x);
    t.horizontalTab();
    try testing.expectEqual(@as(usize, 19), t.screens.active.cursor.x);
    t.horizontalTab();
    try testing.expectEqual(@as(usize, 19), t.screens.active.cursor.x);
}
test "Terminal: horizontal tabs starting on tabstop" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 20, .rows = 5 });
    defer t.deinit(alloc);
    t.setCursorPos(t.screens.active.cursor.y, 9);
    try t.print('X');
    t.setCursorPos(t.screens.active.cursor.y, 9);
    t.horizontalTab();
    try t.print('A');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("        X       A", str);
    }
}
test "Terminal: horizontal tabs with right margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 20, .rows = 5 });
    defer t.deinit(alloc);
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 5;
    t.setCursorPos(t.screens.active.cursor.y, 1);
    try t.print('X');
    t.horizontalTab();
    try t.print('A');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X    A", str);
    }
}
test "Terminal: horizontal tabs back" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 20, .rows = 5 });
    defer t.deinit(alloc);
    t.setCursorPos(t.screens.active.cursor.y, 20);
    t.horizontalTabBack();
    try testing.expectEqual(@as(usize, 16), t.screens.active.cursor.x);
    t.horizontalTabBack();
    try testing.expectEqual(@as(usize, 8), t.screens.active.cursor.x);
    t.horizontalTabBack();
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    t.horizontalTabBack();
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
}
test "Terminal: horizontal tabs back starting on tabstop" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 20, .rows = 5 });
    defer t.deinit(alloc);
    t.setCursorPos(t.screens.active.cursor.y, 9);
    try t.print('X');
    t.setCursorPos(t.screens.active.cursor.y, 9);
    t.horizontalTabBack();
    try t.print('A');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A       X", str);
    }
}
test "Terminal: horizontal tabs with left margin in origin mode" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 20, .rows = 5 });
    defer t.deinit(alloc);
    t.modes.set(.origin, true);
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 5;
    t.setCursorPos(1, 2);
    try t.print('X');
    t.horizontalTabBack();
    try t.print('A');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  AX", str);
    }
}
test "Terminal: horizontal tab back with cursor before left margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 20, .rows = 5 });
    defer t.deinit(alloc);
    t.modes.set(.origin, true);
    t.saveCursor();
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(5, 0);
    t.restoreCursor();
    t.horizontalTabBack();
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X", str);
    }
}
test "Terminal: cursorPos resets wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.setCursorPos(1, 1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("XBCDE", str);
    }
}
test "Terminal: cursorPos off the screen" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setCursorPos(500, 500);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\n\n    X", str);
    }
}
test "Terminal: cursorPos relative to origin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.scrolling_region.top = 2;
    t.scrolling_region.bottom = 3;
    t.modes.set(.origin, true);
    t.setCursorPos(1, 1);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\nX", str);
    }
}
test "Terminal: cursorPos relative to origin with left/right" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.scrolling_region.top = 2;
    t.scrolling_region.bottom = 3;
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    t.modes.set(.origin, true);
    t.setCursorPos(1, 1);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n  X", str);
    }
}
test "Terminal: cursorPos limits with full scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.scrolling_region.top = 2;
    t.scrolling_region.bottom = 3;
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    t.modes.set(.origin, true);
    t.setCursorPos(500, 500);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\n    X", str);
    }
}
test "Terminal: setCursorPos (original test)" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    t.setCursorPos(0, 0);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    t.setCursorPos(81, 81);
    try testing.expectEqual(@as(usize, 79), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 79), t.screens.active.cursor.y);
    t.setCursorPos(0, 80);
    try t.print('c');
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.setCursorPos(0, 80);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    t.modes.set(.origin, true);
    t.setCursorPos(81, 81);
    try testing.expectEqual(@as(usize, 79), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 79), t.screens.active.cursor.y);
    t.setTopAndBottomMargin(10, t.rows);
    t.setCursorPos(0, 0);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 9), t.screens.active.cursor.y);
    t.setCursorPos(1, 1);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 9), t.screens.active.cursor.y);
    t.setCursorPos(100, 0);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 79), t.screens.active.cursor.y);
    t.setTopAndBottomMargin(10, 11);
    t.setCursorPos(2, 0);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 10), t.screens.active.cursor.y);
}
test "Terminal: setTopAndBottomMargin simple" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setTopAndBottomMargin(0, 0);
    t.clearDirty();
    t.scrollDown(1);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }
}
test "Terminal: setTopAndBottomMargin top only" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setTopAndBottomMargin(2, 0);
    t.clearDirty();
    t.scrollDown(1);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\n\nDEF\nGHI", str);
    }
}
test "Terminal: setTopAndBottomMargin top and bottom" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setTopAndBottomMargin(1, 2);
    t.clearDirty();
    t.scrollDown(1);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nGHI", str);
    }
}
test "Terminal: setTopAndBottomMargin top equal to bottom" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setTopAndBottomMargin(2, 2);
    t.clearDirty();
    t.scrollDown(1);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }
}
test "Terminal: setLeftAndRightMargin simple" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(0, 0);
    t.clearDirty();
    t.eraseChars(1);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(" BC\nDEF\nGHI", str);
    }
}
test "Terminal: setLeftAndRightMargin left only" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(2, 0);
    try testing.expectEqual(@as(usize, 1), t.scrolling_region.left);
    try testing.expectEqual(@as(usize, t.cols - 1), t.scrolling_region.right);
    t.setCursorPos(1, 2);
    t.clearDirty();
    t.insertLines(1);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nDBC\nGEF\n HI", str);
    }
}
test "Terminal: setLeftAndRightMargin left and right" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(1, 2);
    t.setCursorPos(1, 2);
    t.clearDirty();
    t.insertLines(1);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C\nABF\nDEI\nGH", str);
    }
}
test "Terminal: setLeftAndRightMargin left equal right" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(2, 2);
    t.setCursorPos(1, 2);
    t.clearDirty();
    t.insertLines(1);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }
}
test "Terminal: setLeftAndRightMargin mode 69 unset" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.modes.set(.enable_left_and_right_margin, false);
    t.setLeftAndRightMargin(1, 2);
    t.setCursorPos(1, 2);
    t.clearDirty();
    t.insertLines(1);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }
}
test "Terminal: insertLines simple" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);
    const node = t.screens.active.cursor.page_pin.node;
    const serial = node.serial;
    t.clearDirty();
    t.insertLines(1);
    try testing.expect(!t.screens.active.pages.nodeIsValid(node, serial));
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\n\nDEF\nGHI", str);
    }
}
test "Terminal: insertLines colors with bg color" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.insertLines(1);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\n\nDEF\nGHI", str);
    }
    for (0..t.cols) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 1,
        } }).?;
        try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 0xFF,
            .g = 0,
            .b = 0,
        }, list_cell.cell.content.color_rgb);
    }
}
test "Terminal: insertLines handles style refs" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);
    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.setAttribute(.{ .bold = {} });
    try t.printString("GHI");
    try t.setAttribute(.{ .unset = {} });
    const page = t.screens.active.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 1), page.styles.count());
    t.setCursorPos(2, 2);
    t.insertLines(1);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\n\nDEF", str);
    }
    try testing.expectEqual(@as(usize, 0), page.styles.count());
}
test "Terminal: insertLines outside of scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setTopAndBottomMargin(3, 4);
    t.setCursorPos(2, 2);
    t.clearDirty();
    t.insertLines(1);
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}
test "Terminal: insertLines top/bottom scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("123");
    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(2, 2);
    t.clearDirty();
    t.insertLines(1);
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\n\nDEF\n123", str);
    }
}
test "Terminal: insertLines across page boundary marks all shifted rows dirty" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 10, .max_scrollback_bytes = 1024 });
    defer t.deinit(alloc);
    const first_page = t.screens.active.pages.pages.first.?;
    const first_page_nrows = first_page.capacity().rows;
    for (0..first_page_nrows - 3) |_| try t.linefeed();
    try t.printString("1AAAA");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("2BBBB");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("3CCCC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("4DDDD");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("5EEEE");
    const second_page = first_page.next.?;
    const first_serial = first_page.serial;
    const second_serial = second_page.serial;
    t.setCursorPos(1, 1);
    t.clearDirty();
    t.insertLines(1);
    try testing.expect(!t.screens.active.pages.nodeIsValid(first_page, first_serial));
    try testing.expect(!t.screens.active.pages.nodeIsValid(second_page, second_serial));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 4 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n1AAAA\n2BBBB\n3CCCC\n4DDDD", str);
    }
}
test "Terminal: insertLines hyperlink-dense row crosses page boundary" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 10, .max_scrollback_bytes = 1024 });
    defer t.deinit(alloc);
    const pages = &t.screens.active.pages;
    const first_page_rows = pages.pages.first.?.capacity().rows;
    for (0..first_page_rows + 1) |_| try t.linefeed();
    try testing.expect(pages.pages.first != pages.pages.last);
    try testing.expectEqual(@as(usize, 2), pages.pages.last.?.rows());
    t.setCursorPos(1, 1);
    try t.printString("0");
    t.setCursorPos(2, 1);
    try t.printString("1");
    t.setCursorPos(4, 1);
    try t.printString("3");
    t.setCursorPos(5, 1);
    try t.printString("4");
    t.setCursorPos(3, 1);
    for (0..10) |i| {
        var buf: [64]u8 = undefined;
        const uri = try std.fmt.bufPrint(&buf, "http://example.com/{d}", .{i});
        try t.screens.active.startHyperlink(uri, null);
        try t.print(@intCast('A' + i));
        t.screens.active.endHyperlink();
    }
    {
        const pin = pages.pin(.{ .active = .{ .y = 2 } }).?;
        try testing.expectEqual(pages.pages.first.?, pin.node);
        try testing.expectEqual(pin.node.rows() - 1, @as(usize, pin.y));
    }
    try testing.expect(pages.pages.last.?.page().hyperlink_set.layout.cap < 10);
    t.setCursorPos(1, 1);
    t.insertLines(1);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n0\n1\nABCDEFGHIJ\n3", str);
    }
    try testing.expect(pages.pages.last.?.page().hyperlink_set.layout.cap >= 10);
    for (0..10) |x| {
        const list_cell = pages.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 3,
        } }).?;
        try testing.expect(list_cell.cell.hyperlink);
        const page: *Page = list_cell.node.page();
        const id = page.lookupHyperlink(list_cell.cell).?;
        const link = page.hyperlink_set.get(page.memory, id);
        var buf: [64]u8 = undefined;
        const uri = try std.fmt.bufPrint(&buf, "http://example.com/{d}", .{x});
        try testing.expectEqualStrings(uri, link.uri.slice(page.memory));
    }
    var node_: ?*PageList.List.Node = pages.pages.first;
    while (node_) |node| : (node_ = node.next) node.page().assertIntegrity();
}
test "Terminal: insertLines (legacy test)" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');
    t.carriageReturn();
    try t.linefeed();
    try t.print('E');
    t.setCursorPos(2, 1);
    t.insertLines(2);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n\n\nB\nC", str);
    }
}
test "Terminal: insertLines zero" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);
    t.setCursorPos(1, 1);
    t.insertLines(0);
}
test "Terminal: insertLines with scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 6 });
    defer t.deinit(alloc);
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');
    t.carriageReturn();
    try t.linefeed();
    try t.print('E');
    t.setTopAndBottomMargin(1, 2);
    t.setCursorPos(1, 1);
    t.clearDirty();
    t.insertLines(1);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\nA\nC\nD\nE", str);
    }
}
test "Terminal: insertLines more than remaining" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');
    t.carriageReturn();
    try t.linefeed();
    try t.print('E');
    t.setCursorPos(2, 1);
    t.clearDirty();
    t.insertLines(20);
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }
}
test "Terminal: insertLines resets pending wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.insertLines(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('B');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B\nABCDE", str);
    }
}
test "Terminal: insertLines resets wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    try t.print('1');
    t.carriageReturn();
    try t.linefeed();
    for ("ABCDEF") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.insertLines(1);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\n1\nABC", str);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 2 } }).?;
        const row = list_cell.row;
        try testing.expect(!row.wrap);
    }
}
test "Terminal: insertLines multi-codepoint graphemes" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, true);
    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.print(0x1F468);
    try t.print(0x200D);
    try t.print(0x1F469);
    try t.print(0x200D);
    try t.print(0x1F467);
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);
    t.insertLines(1);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\n\n👨‍👩‍👧\nGHI", str);
    }
}
test "Terminal: insertLines left/right scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    try t.printString("ABC123");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF456");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(2, 2);
    t.clearDirty();
    t.insertLines(1);
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC123\nD   56\nGEF489\n HI7", str);
    }
}
test "Terminal: scrollUp simple" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);
    const cursor = t.screens.active.cursor;
    const viewport_before = t.screens.active.pages.getTopLeft(.viewport);
    try t.scrollUp(1);
    try testing.expectEqual(cursor.x, t.screens.active.cursor.x);
    try testing.expectEqual(cursor.y, t.screens.active.cursor.y);
    const viewport_after = t.screens.active.pages.getTopLeft(.viewport);
    try testing.expect(!viewport_before.eql(viewport_after));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("DEF\nGHI", str);
    }
}
test "Terminal: scrollUp moves hyperlink" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("DEF");
    t.screens.active.endHyperlink();
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);
    try t.scrollUp(1);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("DEF\nGHI", str);
    }
    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
        const page = list_cell.node.page();
        try testing.expectEqual(1, page.hyperlink_set.count());
    }
    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = @intCast(x),
            .y = 1,
        } }).?;
        const row = list_cell.row;
        try testing.expect(!row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell);
        try testing.expect(id == null);
    }
}
test "Terminal: scrollUp clears hyperlink" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("ABC");
    t.screens.active.endHyperlink();
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);
    try t.scrollUp(1);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("DEF\nGHI", str);
    }
    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(!row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell);
        try testing.expect(id == null);
    }
}
test "Terminal: scrollUp top/bottom scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setTopAndBottomMargin(2, 3);
    t.setCursorPos(1, 1);
    t.clearDirty();
    try t.scrollUp(1);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nGHI", str);
    }
}
test "Terminal: scrollUp left/right scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    try t.printString("ABC123");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF456");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(2, 2);
    const cursor = t.screens.active.cursor;
    t.clearDirty();
    try t.scrollUp(1);
    try testing.expectEqual(cursor.x, t.screens.active.cursor.x);
    try testing.expectEqual(cursor.y, t.screens.active.cursor.y);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AEF423\nDHI756\nG   89", str);
    }
}
test "Terminal: scrollUp left/right scroll region hyperlink" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    try t.printString("ABC123");
    t.carriageReturn();
    try t.linefeed();
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("DEF456");
    t.screens.active.endHyperlink();
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(2, 2);
    try t.scrollUp(1);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AEF423\nDHI756\nG   89", str);
    }
    {
        for (0..1) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            const cell = list_cell.cell;
            try testing.expect(!cell.hyperlink);
            const id = list_cell.node.page().lookupHyperlink(cell);
            try testing.expect(id == null);
        }
        for (1..4) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            const row = list_cell.row;
            try testing.expect(row.hyperlink);
            const cell = list_cell.cell;
            try testing.expect(cell.hyperlink);
            const id = list_cell.node.page().lookupHyperlink(cell).?;
            try testing.expectEqual(@as(hyperlink.Id, 1), id);
            const page = list_cell.node.page();
            try testing.expectEqual(1, page.hyperlink_set.count());
        }
        for (4..6) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            const cell = list_cell.cell;
            try testing.expect(!cell.hyperlink);
            const id = list_cell.node.page().lookupHyperlink(cell);
            try testing.expect(id == null);
        }
    }
    {
        for (0..1) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 1,
            } }).?;
            const row = list_cell.row;
            try testing.expect(row.hyperlink);
            const cell = list_cell.cell;
            try testing.expect(cell.hyperlink);
            const id = list_cell.node.page().lookupHyperlink(cell).?;
            try testing.expectEqual(@as(hyperlink.Id, 1), id);
            const page = list_cell.node.page();
            try testing.expectEqual(1, page.hyperlink_set.count());
        }
        for (1..4) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 1,
            } }).?;
            const cell = list_cell.cell;
            try testing.expect(!cell.hyperlink);
            const id = list_cell.node.page().lookupHyperlink(cell);
            try testing.expect(id == null);
        }
        for (4..6) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 1,
            } }).?;
            const row = list_cell.row;
            try testing.expect(row.hyperlink);
            const cell = list_cell.cell;
            try testing.expect(cell.hyperlink);
            const id = list_cell.node.page().lookupHyperlink(cell).?;
            try testing.expectEqual(@as(hyperlink.Id, 1), id);
            const page = list_cell.node.page();
            try testing.expectEqual(1, page.hyperlink_set.count());
        }
    }
}
test "Terminal: scrollUp preserves pending wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setCursorPos(1, 5);
    try t.print('A');
    t.setCursorPos(2, 5);
    try t.print('B');
    t.setCursorPos(3, 5);
    try t.print('C');
    try t.scrollUp(1);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    B\n    C\n\nX", str);
    }
}
test "Terminal: scrollUp full top/bottom region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("top");
    t.setCursorPos(5, 1);
    try t.printString("ABCDE");
    t.setTopAndBottomMargin(2, 5);
    t.clearDirty();
    try t.scrollUp(4);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("top", str);
    }
}
test "Terminal: scrollUp full top/bottomleft/right scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("top");
    t.setCursorPos(5, 1);
    try t.printString("ABCDE");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setTopAndBottomMargin(2, 5);
    t.setLeftAndRightMargin(2, 4);
    t.clearDirty();
    try t.scrollUp(4);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    for (1..5) |y| try testing.expect(t.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("top\n\n\n\nA   E", str);
    }
}
test "Terminal: scrollUp creates scrollback in primary screen" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5, .max_scrollback_bytes = 10 });
    defer t.deinit(alloc);
    try t.printString("AAAAA");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("BBBBB");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("CCCCC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DDDDD");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("EEEEE");
    t.clearDirty();
    try t.scrollUp(1);
    try testing.expect(t.screens.active.cursor.page_row.dirty);
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("BBBBB\nCCCCC\nDDDDD\nEEEEE", str);
    }
    t.screens.active.scroll(.{ .top = {} });
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("AAAAA\nBBBBB\nCCCCC\nDDDDD\nEEEEE", str);
    }
}
test "Terminal: scrollUp with max_scrollback_bytes zero" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5, .max_scrollback_bytes = 0 });
    defer t.deinit(alloc);
    try t.printString("AAAAA");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("BBBBB");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("CCCCC");
    try t.scrollUp(1);
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("BBBBB\nCCCCC", str);
    }
    t.screens.active.scroll(.{ .top = {} });
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("BBBBB\nCCCCC", str);
    }
}
test "Terminal: scrollUp with max_scrollback_bytes zero and top margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5, .max_scrollback_bytes = 0 });
    defer t.deinit(alloc);
    try t.printString("AAAAA");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("BBBBB");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("CCCCC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DDDDD");
    t.setTopAndBottomMargin(2, 5);
    try t.scrollUp(1);
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("AAAAA\nCCCCC\nDDDDD", str);
    }
}
test "Terminal: scrollUp with max_scrollback_bytes zero and left/right margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 10, .max_scrollback_bytes = 0 });
    defer t.deinit(alloc);
    try t.printString("AAAAABBBBB");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("CCCCCDDDDD");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("EEEEEFFFFF");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(2, 6);
    try t.scrollUp(1);
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("ACCCCDBBBB\nCEEEEFDDDD\nE     FFFF", str);
    }
}
test "Terminal: scrollDown simple" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);
    const cursor = t.screens.active.cursor;
    t.clearDirty();
    t.scrollDown(1);
    try testing.expectEqual(cursor.x, t.screens.active.cursor.x);
    try testing.expectEqual(cursor.y, t.screens.active.cursor.y);
    for (0..5) |y| try testing.expect(t.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }
}
test "Terminal: scrollDown hyperlink moves" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("ABC");
    t.screens.active.endHyperlink();
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);
    t.scrollDown(1);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }
    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = @intCast(x),
            .y = 1,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
        const page = list_cell.node.page();
        try testing.expectEqual(1, page.hyperlink_set.count());
    }
    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(!row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell);
        try testing.expect(id == null);
    }
}
test "Terminal: scrollDown outside of scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setTopAndBottomMargin(3, 4);
    t.setCursorPos(2, 2);
    const cursor = t.screens.active.cursor;
    t.clearDirty();
    t.scrollDown(1);
    try testing.expectEqual(cursor.x, t.screens.active.cursor.x);
    try testing.expectEqual(cursor.y, t.screens.active.cursor.y);
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\n\nGHI", str);
    }
}
test "Terminal: scrollDown left/right scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    try t.printString("ABC123");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF456");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(2, 2);
    const cursor = t.screens.active.cursor;
    t.clearDirty();
    t.scrollDown(1);
    try testing.expectEqual(cursor.x, t.screens.active.cursor.x);
    try testing.expectEqual(cursor.y, t.screens.active.cursor.y);
    for (0..4) |y| try testing.expect(t.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A   23\nDBC156\nGEF489\n HI7", str);
    }
}
test "Terminal: scrollDown left/right scroll region hyperlink" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("ABC123");
    t.screens.active.endHyperlink();
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF456");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(2, 2);
    t.scrollDown(1);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A   23\nDBC156\nGEF489\n HI7", str);
    }
    {
        for (0..1) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            const row = list_cell.row;
            try testing.expect(row.hyperlink);
            const cell = list_cell.cell;
            try testing.expect(cell.hyperlink);
            const id = list_cell.node.page().lookupHyperlink(cell).?;
            try testing.expectEqual(@as(hyperlink.Id, 1), id);
            const page = list_cell.node.page();
            try testing.expectEqual(1, page.hyperlink_set.count());
        }
        for (1..4) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            const cell = list_cell.cell;
            try testing.expect(!cell.hyperlink);
            const id = list_cell.node.page().lookupHyperlink(cell);
            try testing.expect(id == null);
        }
        for (4..6) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            const row = list_cell.row;
            try testing.expect(row.hyperlink);
            const cell = list_cell.cell;
            try testing.expect(cell.hyperlink);
            const id = list_cell.node.page().lookupHyperlink(cell).?;
            try testing.expectEqual(@as(hyperlink.Id, 1), id);
            const page = list_cell.node.page();
            try testing.expectEqual(1, page.hyperlink_set.count());
        }
    }
    {
        for (0..1) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 1,
            } }).?;
            const cell = list_cell.cell;
            try testing.expect(!cell.hyperlink);
            const id = list_cell.node.page().lookupHyperlink(cell);
            try testing.expect(id == null);
        }
        for (1..4) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 1,
            } }).?;
            const row = list_cell.row;
            try testing.expect(row.hyperlink);
            const cell = list_cell.cell;
            try testing.expect(cell.hyperlink);
            const id = list_cell.node.page().lookupHyperlink(cell).?;
            try testing.expectEqual(@as(hyperlink.Id, 1), id);
            const page = list_cell.node.page();
            try testing.expectEqual(1, page.hyperlink_set.count());
        }
        for (4..6) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 1,
            } }).?;
            const cell = list_cell.cell;
            try testing.expect(!cell.hyperlink);
            const id = list_cell.node.page().lookupHyperlink(cell);
            try testing.expect(id == null);
        }
    }
}
test "Terminal: scrollDown outside of left/right scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    try t.printString("ABC123");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF456");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(1, 1);
    const cursor = t.screens.active.cursor;
    t.clearDirty();
    t.scrollDown(1);
    try testing.expectEqual(cursor.x, t.screens.active.cursor.x);
    try testing.expectEqual(cursor.y, t.screens.active.cursor.y);
    for (0..4) |y| try testing.expect(t.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A   23\nDBC156\nGEF489\n HI7", str);
    }
}
test "Terminal: scrollDown preserves pending wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 10 });
    defer t.deinit(alloc);
    t.setCursorPos(1, 5);
    try t.print('A');
    t.setCursorPos(2, 5);
    try t.print('B');
    t.setCursorPos(3, 5);
    try t.print('C');
    t.scrollDown(1);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n    A\n    B\nX   C", str);
    }
}
test "Terminal: eraseChars simple operation" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.clearDirty();
    t.eraseChars(2);
    try t.print('X');
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X C", str);
    }
}
test "Terminal: eraseChars minimum one" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.clearDirty();
    t.eraseChars(0);
    try t.print('X');
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("XBC", str);
    }
}
test "Terminal: eraseChars beyond screen edge" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("  ABC") |c| try t.print(c);
    t.setCursorPos(1, 4);
    t.eraseChars(10);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  A", str);
    }
}
test "Terminal: eraseChars wide character" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.print('橋');
    for ("BC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.eraseChars(1);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X BC", str);
    }
}
test "Terminal: eraseChars resets pending wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.eraseChars(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}
test "Terminal: eraseChars resets wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE123") |c| try t.print(c);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        const row = list_cell.row;
        try testing.expect(row.wrap);
    }
    t.setCursorPos(1, 1);
    t.eraseChars(1);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        const row = list_cell.row;
        try testing.expect(!row.wrap);
    }
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("XBCDE\n123", str);
    }
}
test "Terminal: eraseChars preserves background sgr" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.eraseChars(2);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C", str);
        {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
            try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
            try testing.expectEqual(Cell.RGB{
                .r = 0xFF,
                .g = 0,
                .b = 0,
            }, list_cell.cell.content.color_rgb);
        }
        {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 1, .y = 0 } }).?;
            try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
            try testing.expectEqual(Cell.RGB{
                .r = 0xFF,
                .g = 0,
                .b = 0,
            }, list_cell.cell.content.color_rgb);
        }
    }
}
test "Terminal: eraseChars handles refcounted styles" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    try t.setAttribute(.{ .bold = {} });
    try t.print('A');
    try t.print('B');
    try t.setAttribute(.{ .unset = {} });
    try t.print('C');
    const page = t.screens.active.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 1), page.styles.count());
    t.setCursorPos(1, 1);
    t.eraseChars(2);
    try testing.expectEqual(@as(usize, 0), page.styles.count());
}
test "Terminal: eraseChars protected attributes respected with iso" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.eraseChars(2);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC", str);
    }
}
test "Terminal: eraseChars protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(1, 1);
    t.eraseChars(2);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C", str);
    }
}
test "Terminal: eraseChars protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.eraseChars(2);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C", str);
    }
}
test "Terminal: eraseChars wide char boundary conditions" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 1, .cols = 8 });
    defer t.deinit(alloc);
    try t.printString("😀a😀b😀");
    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("😀a😀b😀", str);
    }
    t.setCursorPos(1, 2);
    t.eraseChars(3);
    t.screens.active.cursor.page_pin.node.page().assertIntegrity();
    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("     b😀", str);
    }
}
test "Terminal: eraseChars wide char splits proper cell boundaries" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 1, .cols = 30 });
    defer t.deinit(alloc);
    try t.printString("x食べて下さい");
    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("x食べて下さい", str);
    }
    t.setCursorPos(1, 6);
    t.eraseChars(4);
    t.screens.active.cursor.page_pin.node.page().assertIntegrity();
    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("x食べ    さい", str);
    }
}
test "Terminal: eraseChars wide char wrap boundary conditions" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 3, .cols = 8 });
    defer t.deinit(alloc);
    try t.printString(".......😀abcde😀......");
    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(".......\n😀abcde\n😀......", str);
        const unwrapped = try t.plainStringUnwrapped(alloc);
        defer testing.allocator.free(unwrapped);
        try testing.expectEqualStrings(".......😀abcde😀......", unwrapped);
    }
    t.setCursorPos(2, 2);
    t.eraseChars(3);
    t.screens.active.cursor.page_pin.node.page().assertIntegrity();
    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(".......\n    cde\n😀......", str);
        const unwrapped = try t.plainStringUnwrapped(alloc);
        defer testing.allocator.free(unwrapped);
        try testing.expectEqualStrings(".......     cde\n😀......", unwrapped);
    }
}
test "Terminal: eraseChars clearing wrapped wide char marks spacer head row dirty" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 3, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("ABCD字");
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        try testing.expectEqual(Cell.Wide.spacer_head, list_cell.cell.wide);
        try testing.expect(list_cell.row.wrap);
    }
    t.setCursorPos(2, 1);
    t.clearDirty();
    t.eraseChars(1);
    t.screens.active.cursor.page_pin.node.page().assertIntegrity();
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 1 } }));
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 2 } }));
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        try testing.expectEqual(Cell.Wide.narrow, list_cell.cell.wide);
    }
}
test "Terminal: reverseIndex" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.reverseIndex();
    try t.print('D');
    t.carriageReturn();
    try t.linefeed();
    t.carriageReturn();
    try t.linefeed();
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nBD\nC", str);
    }
}
test "Terminal: reverseIndex from the top" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    t.carriageReturn();
    try t.linefeed();
    t.setCursorPos(1, 1);
    t.reverseIndex();
    try t.print('D');
    t.carriageReturn();
    try t.linefeed();
    t.setCursorPos(1, 1);
    t.reverseIndex();
    try t.print('E');
    t.carriageReturn();
    try t.linefeed();
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("E\nD\nA\nB", str);
    }
}
test "Terminal: reverseIndex top of scrolling region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 10 });
    defer t.deinit(alloc);
    t.setCursorPos(2, 1);
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');
    t.carriageReturn();
    try t.linefeed();
    t.setTopAndBottomMargin(2, 5);
    t.setCursorPos(2, 1);
    t.reverseIndex();
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nX\nA\nB\nC", str);
    }
}
test "Terminal: reverseIndex top of screen" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.print('A');
    t.setCursorPos(2, 1);
    try t.print('B');
    t.setCursorPos(3, 1);
    try t.print('C');
    t.setCursorPos(1, 1);
    t.reverseIndex();
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\nA\nB\nC", str);
    }
}
test "Terminal: reverseIndex not top of screen" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.print('A');
    t.setCursorPos(2, 1);
    try t.print('B');
    t.setCursorPos(3, 1);
    try t.print('C');
    t.setCursorPos(2, 1);
    t.reverseIndex();
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\nB\nC", str);
    }
}
test "Terminal: reverseIndex top/bottom margins" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.print('A');
    t.setCursorPos(2, 1);
    try t.print('B');
    t.setCursorPos(3, 1);
    try t.print('C');
    t.setTopAndBottomMargin(2, 3);
    t.setCursorPos(2, 1);
    t.reverseIndex();
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n\nB", str);
    }
}
test "Terminal: reverseIndex outside top/bottom margins" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.print('A');
    t.setCursorPos(2, 1);
    try t.print('B');
    t.setCursorPos(3, 1);
    try t.print('C');
    t.setTopAndBottomMargin(2, 3);
    t.setCursorPos(1, 1);
    t.reverseIndex();
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nB\nC", str);
    }
}
test "Terminal: reverseIndex left/right margins" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("ABC");
    t.setCursorPos(2, 1);
    try t.printString("DEF");
    t.setCursorPos(3, 1);
    try t.printString("GHI");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(2, 3);
    t.setCursorPos(1, 2);
    t.reverseIndex();
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nDBC\nGEF\n HI", str);
    }
}
test "Terminal: reverseIndex outside left/right margins" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("ABC");
    t.setCursorPos(2, 1);
    try t.printString("DEF");
    t.setCursorPos(3, 1);
    try t.printString("GHI");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(2, 3);
    t.setCursorPos(1, 1);
    t.reverseIndex();
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}
test "Terminal: index" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);
    try t.index();
    try t.print('A');
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nA", str);
    }
}
test "Terminal: index from the bottom" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);
    t.setCursorPos(5, 1);
    try t.print('A');
    t.cursorLeft(1);
    t.clearDirty();
    try t.index();
    try t.print('B');
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 4 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\nA\nB", str);
    }
}
test "Terminal: index scrolling with hyperlink" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);
    t.setCursorPos(5, 1);
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.print('A');
    t.screens.active.endHyperlink();
    t.cursorLeft(1);
    try t.index();
    try t.print('B');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\nA\nB", str);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = 0,
            .y = 3,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = 0,
            .y = 4,
        } }).?;
        const row = list_cell.row;
        try testing.expect(!row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell);
        try testing.expect(id == null);
    }
}
test "Terminal: index outside of scrolling region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    t.setTopAndBottomMargin(2, 5);
    try t.index();
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
}
test "Terminal: index from the bottom outside of scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);
    t.setTopAndBottomMargin(1, 2);
    t.setCursorPos(5, 1);
    try t.print('A');
    t.clearDirty();
    try t.index();
    try t.print('B');
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 4 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\n\nAB", str);
    }
}
test "Terminal: index no scroll region, top of screen" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.print('A');
    t.clearDirty();
    try t.index();
    try t.print('X');
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n X", str);
    }
}
test "Terminal: index bottom of primary screen" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setCursorPos(5, 1);
    try t.print('A');
    t.clearDirty();
    try t.index();
    try t.print('X');
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 4 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\nA\n X", str);
    }
}
test "Terminal: index bottom of primary screen background sgr" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setCursorPos(5, 1);
    try t.print('A');
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    try t.index();
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\nA", str);
        for (0..5) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{
                .x = @intCast(x),
                .y = 4,
            } }).?;
            try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
            try testing.expectEqual(Cell.RGB{
                .r = 0xFF,
                .g = 0,
                .b = 0,
            }, list_cell.cell.content.color_rgb);
        }
    }
}
test "Terminal: index inside scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setTopAndBottomMargin(1, 3);
    try t.print('A');
    t.clearDirty();
    try t.index();
    try t.print('X');
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n X", str);
    }
}
test "Terminal: index bottom of scroll region with hyperlinks" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setTopAndBottomMargin(1, 2);
    try t.print('A');
    try t.index();
    t.carriageReturn();
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.print('B');
    t.screens.active.endHyperlink();
    try t.index();
    t.carriageReturn();
    try t.print('C');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B\nC", str);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = 0,
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = 0,
            .y = 1,
        } }).?;
        const row = list_cell.row;
        try testing.expect(!row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell);
        try testing.expect(id == null);
    }
}
test "Terminal: index bottom of scroll region clear hyperlinks" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5, .max_scrollback_bytes = 0 });
    defer t.deinit(alloc);
    t.setTopAndBottomMargin(2, 3);
    t.setCursorPos(2, 1);
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.print('A');
    t.screens.active.endHyperlink();
    try t.index();
    t.carriageReturn();
    try t.print('B');
    try t.index();
    t.carriageReturn();
    try t.print('C');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nB\nC", str);
    }
    for (1..3) |y| {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = 0,
            .y = @intCast(y),
        } }).?;
        const row = list_cell.row;
        try testing.expect(!row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell);
        try testing.expect(id == null);
        const page = list_cell.node.page();
        try testing.expectEqual(0, page.hyperlink_set.count());
    }
}
test "Terminal: index bottom of scroll region with background SGR" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(4, 1);
    try t.print('B');
    t.setCursorPos(3, 1);
    try t.print('A');
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    try t.index();
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nA\n\nB", str);
    }
    for (0..t.cols) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 2,
        } }).?;
        try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 0xFF,
            .g = 0,
            .b = 0,
        }, list_cell.cell.content.color_rgb);
    }
}
test "Terminal: index bottom of primary screen with scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(3, 1);
    try t.print('A');
    t.setCursorPos(5, 1);
    t.clearDirty();
    try t.index();
    try t.index();
    try t.index();
    try t.print('X');
    for (0..4) |y| try testing.expect(!t.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 4 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\nA\n\nX", str);
    }
}
test "Terminal: index outside left/right margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    t.setTopAndBottomMargin(1, 3);
    t.scrolling_region.left = 3;
    t.scrolling_region.right = 5;
    t.setCursorPos(3, 3);
    try t.print('A');
    t.setCursorPos(3, 1);
    t.clearDirty();
    try t.index();
    try t.print('X');
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\nX A", str);
    }
}
test "Terminal: index inside left/right margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    try t.printString("AAAAAA");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("AAAAAA");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("AAAAAA");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setTopAndBottomMargin(1, 3);
    t.setLeftAndRightMargin(1, 3);
    t.setCursorPos(3, 1);
    t.clearDirty();
    try t.index();
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AAAAAA\nAAAAAA\n   AAA", str);
    }
}
test "Terminal: index bottom of scroll region creates scrollback" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setTopAndBottomMargin(1, 3);
    try t.printString("1\n2\n3");
    t.setCursorPos(4, 1);
    try t.print('X');
    t.setCursorPos(3, 1);
    try t.index();
    try t.print('Y');
    {
        const str = try t.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("2\n3\nY\nX", str);
    }
    {
        const str = try t.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1\n2\n3\nY\nX", str);
    }
}
test "Terminal: index bottom of scroll region no scrollback" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5, .max_scrollback_bytes = 0 });
    defer t.deinit(alloc);
    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(4, 1);
    try t.print('B');
    t.setCursorPos(3, 1);
    try t.print('A');
    t.clearDirty();
    try t.index();
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nA\n X\nB", str);
    }
}
test "Terminal: index bottom of scroll region blank line preserves SGR" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setTopAndBottomMargin(1, 3);
    try t.printString("1\n2\n3");
    t.setCursorPos(4, 1);
    try t.print('X');
    t.setCursorPos(3, 1);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    try t.index();
    {
        const str = try t.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("2\n3\n\nX", str);
    }
    {
        const str = try t.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1\n2\n3\n\nX", str);
    }
    for (0..t.cols) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 2,
        } }).?;
        try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 0xFF,
            .g = 0,
            .b = 0,
        }, list_cell.cell.content.color_rgb);
    }
}
test "Terminal: index bottom of scroll region with top margin and background SGR" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("1\n2\n3\n4\n5");
    t.setTopAndBottomMargin(2, 4);
    t.setCursorPos(4, 1);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    try t.index();
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1\n3\n4\n\n5", str);
    }
    try testing.expectEqual(@as(usize, 3), t.screens.active.cursor.y);
    for (0..t.cols) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 3,
        } }).?;
        try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 0xFF,
            .g = 0,
            .b = 0,
        }, list_cell.cell.content.color_rgb);
    }
}
test "Terminal: index bottom of alt screen full region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 3, .cols = 5 });
    defer t.deinit(alloc);
    try t.switchScreenMode(.@"1049", true);
    try t.printString("A\nB\nC");
    try t.index();
    t.carriageReturn();
    try t.print('D');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B\nC\nD", str);
    }
    {
        const str = try t.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B\nC\nD", str);
    }
    try t.switchScreenMode(.@"1049", false);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}
test "Terminal: index bottom of alt screen top region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.switchScreenMode(.@"1049", true);
    try t.printString("1\n2\n3\n4\n5");
    t.setTopAndBottomMargin(1, 4);
    t.setCursorPos(4, 1);
    try t.index();
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("2\n3\n4\nX\n5", str);
    }
    {
        const str = try t.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("2\n3\n4\nX\n5", str);
    }
}
test "Terminal: scrollUp top region no scrollback" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5, .max_scrollback_bytes = 0 });
    defer t.deinit(alloc);
    try t.printString("A\nB\nC\nD\nE");
    t.setTopAndBottomMargin(1, 3);
    try t.scrollUp(1);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B\nC\n\nD\nE", str);
    }
    {
        const str = try t.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B\nC\n\nD\nE", str);
    }
}
test "Terminal: cursorUp basic" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setCursorPos(3, 1);
    try t.print('A');
    t.cursorUp(10);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(" X\n\nA", str);
    }
}
test "Terminal: cursorUp below top scroll margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setTopAndBottomMargin(2, 4);
    t.setCursorPos(3, 1);
    try t.print('A');
    t.cursorUp(5);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n X\nA", str);
    }
}
test "Terminal: cursorUp above top scroll margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setTopAndBottomMargin(3, 5);
    t.setCursorPos(3, 1);
    try t.print('A');
    t.setCursorPos(2, 1);
    t.cursorUp(10);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\n\nA", str);
    }
}
test "Terminal: cursorUp resets wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.cursorUp(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}
test "Terminal: cursorLeft no wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.cursorLeft(10);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nB", str);
    }
}
test "Terminal: cursorLeft unsets pending wrap state" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.cursorLeft(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCXE", str);
    }
}
test "Terminal: cursorLeft unsets pending wrap state with longer jump" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.cursorLeft(3);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AXCDE", str);
    }
}
test "Terminal: cursorLeft reverse wrap with pending wrap state" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap, true);
    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.cursorLeft(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}
test "Terminal: cursorLeft reverse wrap with pending wrap above top margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap, true);
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(1, 2);
    for ("AB") |c| try t.print(c);
    t.saveCursor();
    t.setLeftAndRightMargin(2, 5);
    t.setTopAndBottomMargin(3, 5);
    t.restoreCursor();
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.cursorLeft(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try testing.expectEqual(1, t.screens.active.cursor.x);
    try testing.expectEqual(0, t.screens.active.cursor.y);
    try t.print('X');
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("AX", str);
    }
}
test "Terminal: cursorLeft reverse wrap extended with pending wrap state" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap_extended, true);
    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.cursorLeft(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}
test "Terminal: cursorLeft reverse wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap, true);
    for ("ABCDE1") |c| try t.print(c);
    t.cursorLeft(2);
    try t.print('X');
    try testing.expect(t.screens.active.cursor.pending_wrap);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX\n1", str);
    }
}
test "Terminal: cursorLeft reverse wrap with no soft wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap, true);
    for ("ABCDE") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    try t.print('1');
    t.cursorLeft(2);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDE\nX", str);
    }
}
test "Terminal: cursorLeft reverse wrap before left margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap, true);
    t.setTopAndBottomMargin(3, 0);
    t.cursorLeft(1);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\nX", str);
    }
}
test "Terminal: cursorLeft extended reverse wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap_extended, true);
    for ("ABCDE") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    try t.print('1');
    t.cursorLeft(2);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX\n1", str);
    }
}
test "Terminal: cursorLeft extended reverse wrap bottom wraparound" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);
    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap_extended, true);
    for ("ABCDE") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    try t.print('1');
    t.cursorLeft(1 + t.cols + 1);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDE\n1\n    X", str);
    }
}
test "Terminal: cursorLeft extended reverse wrap is priority if both set" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);
    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap, true);
    t.modes.set(.reverse_wrap_extended, true);
    for ("ABCDE") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    try t.print('1');
    t.cursorLeft(1 + t.cols + 1);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDE\n1\n    X", str);
    }
}
test "Terminal: cursorLeft extended reverse wrap above top scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap_extended, true);
    t.setTopAndBottomMargin(3, 0);
    t.setCursorPos(2, 1);
    t.cursorLeft(1000);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
}
test "Terminal: cursorLeft reverse wrap on first row" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap, true);
    t.setTopAndBottomMargin(3, 0);
    t.setCursorPos(1, 2);
    t.cursorLeft(1000);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
}
test "Terminal: cursorDown basic" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.print('A');
    t.cursorDown(10);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n\n\n\n X", str);
    }
}
test "Terminal: cursorDown above bottom scroll margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setTopAndBottomMargin(1, 3);
    try t.print('A');
    t.cursorDown(10);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n\n X", str);
    }
}
test "Terminal: cursorDown below bottom scroll margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setTopAndBottomMargin(1, 3);
    try t.print('A');
    t.setCursorPos(4, 1);
    t.cursorDown(10);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n\n\n\nX", str);
    }
}
test "Terminal: cursorDown resets wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.cursorDown(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDE\n    X", str);
    }
}
test "Terminal: cursorRight resets wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.cursorRight(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}
test "Terminal: cursorRight to the edge of screen" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.cursorRight(100);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    X", str);
    }
}
test "Terminal: cursorRight left of right margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.scrolling_region.right = 2;
    t.cursorRight(100);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  X", str);
    }
}
test "Terminal: cursorRight right of right margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.scrolling_region.right = 2;
    t.setCursorPos(1, 4);
    t.cursorRight(100);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    X", str);
    }
}
test "Terminal: deleteLines simple" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);
    const node = t.screens.active.cursor.page_pin.node;
    const serial = node.serial;
    t.clearDirty();
    t.deleteLines(1);
    try testing.expect(!t.screens.active.pages.nodeIsValid(node, serial));
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nGHI", str);
    }
}
test "Terminal: deleteLines colors with bg color" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.deleteLines(1);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nGHI", str);
    }
    for (0..t.cols) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 4,
        } }).?;
        try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 0xFF,
            .g = 0,
            .b = 0,
        }, list_cell.cell.content.color_rgb);
    }
}
test "Terminal: deleteLines across page boundary marks all shifted rows dirty" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 10, .max_scrollback_bytes = 1024 });
    defer t.deinit(alloc);
    const first_page = t.screens.active.pages.pages.first.?;
    const first_page_nrows = first_page.capacity().rows;
    for (0..first_page_nrows - 3) |_| try t.linefeed();
    try t.printString("1AAAA");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("2BBBB");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("3CCCC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("4DDDD");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("5EEEE");
    const second_page = first_page.next.?;
    const first_serial = first_page.serial;
    const second_serial = second_page.serial;
    t.setCursorPos(1, 1);
    t.clearDirty();
    t.deleteLines(1);
    try testing.expect(!t.screens.active.pages.nodeIsValid(first_page, first_serial));
    try testing.expect(!t.screens.active.pages.nodeIsValid(second_page, second_serial));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 4 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("2BBBB\n3CCCC\n4DDDD\n5EEEE", str);
    }
}
test "Terminal: deleteLines hyperlink-dense row crosses page boundary" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 10, .max_scrollback_bytes = 1024 });
    defer t.deinit(alloc);
    const pages = &t.screens.active.pages;
    const first_page_rows = pages.pages.first.?.capacity().rows;
    for (0..first_page_rows + 1) |_| try t.linefeed();
    try testing.expect(pages.pages.first != pages.pages.last);
    try testing.expectEqual(@as(usize, 2), pages.pages.last.?.rows());
    t.setCursorPos(1, 1);
    try t.printString("0");
    t.setCursorPos(2, 1);
    try t.printString("1");
    t.setCursorPos(3, 1);
    try t.printString("2");
    t.setCursorPos(5, 1);
    try t.printString("4");
    t.setCursorPos(4, 1);
    for (0..10) |i| {
        var buf: [64]u8 = undefined;
        const uri = try std.fmt.bufPrint(&buf, "http://example.com/{d}", .{i});
        try t.screens.active.startHyperlink(uri, null);
        try t.print(@intCast('A' + i));
        t.screens.active.endHyperlink();
    }
    {
        const pin = pages.pin(.{ .active = .{ .y = 3 } }).?;
        try testing.expectEqual(pages.pages.last.?, pin.node);
        try testing.expectEqual(@as(usize, 0), @as(usize, pin.y));
    }
    try testing.expect(pages.pages.first.?.page().hyperlink_set.layout.cap < 10);
    t.setCursorPos(1, 1);
    t.deleteLines(1);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1\n2\nABCDEFGHIJ\n4", str);
    }
    try testing.expect(pages.pages.first.?.page().hyperlink_set.layout.cap >= 10);
    for (0..10) |x| {
        const list_cell = pages.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 2,
        } }).?;
        try testing.expect(list_cell.cell.hyperlink);
        const page: *Page = list_cell.node.page();
        const id = page.lookupHyperlink(list_cell.cell).?;
        const link = page.hyperlink_set.get(page.memory, id);
        var buf: [64]u8 = undefined;
        const uri = try std.fmt.bufPrint(&buf, "http://example.com/{d}", .{x});
        try testing.expectEqualStrings(uri, link.uri.slice(page.memory));
    }
    var node_: ?*PageList.List.Node = pages.pages.first;
    while (node_) |node| : (node_ = node.next) node.page().assertIntegrity();
}
test "Terminal: deleteLines (legacy)" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 80, .rows = 80 });
    defer t.deinit(alloc);
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');
    t.cursorUp(2);
    t.deleteLines(1);
    try t.print('E');
    t.carriageReturn();
    try t.linefeed();
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.y);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nE\nD", str);
    }
}
test "Terminal: deleteLines with scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 80, .rows = 80 });
    defer t.deinit(alloc);
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');
    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(1, 1);
    t.clearDirty();
    t.deleteLines(1);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    try t.print('E');
    t.carriageReturn();
    try t.linefeed();
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("E\nC\n\nD", str);
    }
}
test "Terminal: deleteLines with scroll region, large count" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 80, .rows = 80 });
    defer t.deinit(alloc);
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');
    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(1, 1);
    t.clearDirty();
    t.deleteLines(5);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    try t.print('E');
    t.carriageReturn();
    try t.linefeed();
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("E\n\n\nD", str);
    }
}
test "Terminal: deleteLines with scroll region, cursor outside of region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 80, .rows = 80 });
    defer t.deinit(alloc);
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');
    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(4, 1);
    t.clearDirty();
    t.deleteLines(1);
    for (0..4) |y| try testing.expect(!t.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nB\nC\nD", str);
    }
}
test "Terminal: deleteLines resets pending wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.deleteLines(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('B');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B", str);
    }
}
test "Terminal: deleteLines resets wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    try t.print('1');
    t.carriageReturn();
    try t.linefeed();
    for ("ABCDEF") |c| try t.print(c);
    t.setTopAndBottomMargin(1, 2);
    t.setCursorPos(1, 1);
    t.deleteLines(1);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("XBC\n\nDEF", str);
    }
    for (0..t.rows) |y| {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = @intCast(y),
        } }).?;
        const row = list_cell.row;
        try testing.expect(!row.wrap);
    }
}
test "Terminal: deleteLines left/right scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    try t.printString("ABC123");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF456");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(2, 2);
    t.clearDirty();
    t.deleteLines(1);
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    for (1..3) |y| try testing.expect(t.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC123\nDHI756\nG   89", str);
    }
}
test "Terminal: deleteLines left/right scroll region from top" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    try t.printString("ABC123");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF456");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(1, 2);
    t.clearDirty();
    t.deleteLines(1);
    for (0..3) |y| try testing.expect(t.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AEF423\nDHI756\nG   89", str);
    }
}
test "Terminal: deleteLines left/right scroll region high count" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    try t.printString("ABC123");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF456");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(2, 2);
    t.clearDirty();
    t.deleteLines(100);
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    for (1..3) |y| try testing.expect(t.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC123\nD   56\nG   89", str);
    }
}
test "Terminal: deleteLines wide character spacer head" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);
    try t.printString("AAAAABBBB\u{1F600}CCC");
    t.setCursorPos(1, 1);
    t.deleteLines(1);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        const unwrapped_str = try t.plainStringUnwrapped(testing.allocator);
        defer testing.allocator.free(unwrapped_str);
        try testing.expectEqualStrings("BBBB\n\u{1F600}CCC", str);
        try testing.expectEqualStrings("BBBB\n\u{1F600}CCC", unwrapped_str);
    }
}
test "Terminal: deleteLines wide character spacer head left scroll margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);
    try t.printString("AAAAABBBB\u{1F600}CCC");
    t.scrolling_region.left = 2;
    t.setCursorPos(1, 3);
    t.deleteLines(1);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        const unwrapped_str = try t.plainStringUnwrapped(testing.allocator);
        defer testing.allocator.free(unwrapped_str);
        try testing.expectEqualStrings("AABB\nBBCCC\n\u{1F600}", str);
        try testing.expectEqualStrings("AABB BBCCC\u{1F600}", unwrapped_str);
    }
}
test "Terminal: deleteLines wide character spacer head right scroll margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);
    try t.printString("AAAAABBBB\u{1F600}CCC");
    t.scrolling_region.right = 3;
    t.setCursorPos(1, 1);
    t.deleteLines(1);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        const unwrapped_str = try t.plainStringUnwrapped(testing.allocator);
        defer testing.allocator.free(unwrapped_str);
        try testing.expectEqualStrings("BBBBA\n\u{1F600}CC\n    C", str);
        try testing.expectEqualStrings("BBBBA\u{1F600}CC     C", unwrapped_str);
    }
}
test "Terminal: deleteLines wide character spacer head left and right scroll margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);
    try t.printString("AAAAABBBB\u{1F600}CCC");
    t.scrolling_region.right = 3;
    t.scrolling_region.left = 2;
    t.setCursorPos(1, 3);
    t.deleteLines(1);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        const unwrapped_str = try t.plainStringUnwrapped(testing.allocator);
        defer testing.allocator.free(unwrapped_str);
        try testing.expectEqualStrings("AABBA\nBBCC\n\u{1F600}  C", str);
        try testing.expectEqualStrings("AABBABBCC\u{1F600}  C", unwrapped_str);
    }
}
test "Terminal: deleteLines wide character spacer head left (< 2) and right scroll margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);
    try t.printString("AAAAABBBB\u{1F600}CCC");
    t.scrolling_region.right = 3;
    t.scrolling_region.left = 1;
    t.setCursorPos(1, 2);
    t.deleteLines(1);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        const unwrapped_str = try t.plainStringUnwrapped(testing.allocator);
        defer testing.allocator.free(unwrapped_str);
        try testing.expectEqualStrings("ABBBA\nB CC\n    C", str);
        try testing.expectEqualStrings("ABBBAB CC     C", unwrapped_str);
    }
}
test "Terminal: deleteLines wide characters split by left/right scroll region boundaries" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);
    try t.printString("AAAAA\n\u{1F600}B\u{1F600}");
    t.scrolling_region.right = 3;
    t.scrolling_region.left = 1;
    t.setCursorPos(1, 2);
    t.deleteLines(1);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A B A", str);
    }
}
test "Terminal: deleteLines zero" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);
    t.setCursorPos(1, 1);
    t.deleteLines(0);
}
test "Terminal: default style is empty" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.print('A');
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'A'), cell.content.codepoint.data);
        try testing.expectEqual(@as(style.Id, 0), cell.style_id);
    }
}
test "Terminal: bold style" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.setAttribute(.{ .bold = {} });
    try t.print('A');
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'A'), cell.content.codepoint.data);
        try testing.expect(cell.style_id != 0);
        const page = t.screens.active.cursor.page_pin.node.page();
        try testing.expect(page.styles.refCount(page.memory, t.screens.active.cursor.style_id) > 1);
    }
}
test "Terminal: garbage collect overwritten" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.setAttribute(.{ .bold = {} });
    try t.print('A');
    t.setCursorPos(1, 1);
    try t.setAttribute(.{ .unset = {} });
    try t.print('B');
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'B'), cell.content.codepoint.data);
        try testing.expect(cell.style_id == 0);
    }
    const page = t.screens.active.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 0), page.styles.count());
}
test "Terminal: do not garbage collect old styles in use" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.setAttribute(.{ .bold = {} });
    try t.print('A');
    try t.setAttribute(.{ .unset = {} });
    try t.print('B');
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'B'), cell.content.codepoint.data);
        try testing.expect(cell.style_id == 0);
    }
    const page = t.screens.active.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 1), page.styles.count());
}
test "Terminal: print with style marks the row as styled" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.setAttribute(.{ .bold = {} });
    try t.print('A');
    try t.setAttribute(.{ .unset = {} });
    try t.print('B');
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(list_cell.row.styled);
    }
}
test "Terminal: DECALN" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 2 });
    defer t.deinit(alloc);
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    try t.decaln();
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    for (0..t.rows) |y| try testing.expect(t.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("EE\nEE", str);
    }
}
test "Terminal: decaln reset margins" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);
    t.modes.set(.origin, true);
    t.setTopAndBottomMargin(2, 3);
    try t.decaln();
    t.scrollDown(1);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nEEE\nEEE", str);
    }
}
test "Terminal: decaln preserves color" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);
    try t.setAttribute(.{ .direct_color_bg = .{ .r = 0xFF, .g = 0, .b = 0 } });
    t.modes.set(.origin, true);
    t.setTopAndBottomMargin(2, 3);
    try t.decaln();
    t.scrollDown(1);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nEEE\nEEE", str);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 0xFF,
            .g = 0,
            .b = 0,
        }, list_cell.cell.content.color_rgb);
    }
}
test "Terminal: DECALN resets graphemes with protected mode" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);
    t.setProtectedMode(.iso);
    t.modes.set(.grapheme_cluster, true);
    try t.print(0x1F468);
    try t.print(0x200D);
    try t.print(0x1F469);
    try t.print(0x200D);
    try t.print(0x1F467);
    try t.decaln();
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expect(t.screens.active.cursor.protected);
    try testing.expect(t.screens.active.protected_mode == .iso);
    for (0..t.rows) |y| try testing.expect(t.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("EEE\nEEE\nEEE", str);
    }
}
test "Terminal: insertBlanks zero" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);
    try t.print('A');
    try t.print('B');
    try t.print('C');
    t.setCursorPos(1, 1);
    t.insertBlanks(0);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC", str);
    }
}
test "Terminal: insertBlanks" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);
    try t.print('A');
    try t.print('B');
    try t.print('C');
    t.setCursorPos(1, 1);
    t.clearDirty();
    t.insertBlanks(2);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  ABC", str);
    }
}
test "Terminal: insertBlanks pushes off end" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 3, .rows = 2 });
    defer t.deinit(alloc);
    try t.print('A');
    try t.print('B');
    try t.print('C');
    t.setCursorPos(1, 1);
    t.clearDirty();
    t.insertBlanks(2);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  A", str);
    }
}
test "Terminal: insertBlanks more than size" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 3, .rows = 2 });
    defer t.deinit(alloc);
    try t.print('A');
    try t.print('B');
    try t.print('C');
    t.setCursorPos(1, 1);
    t.clearDirty();
    t.insertBlanks(5);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}
test "Terminal: insertBlanks no scroll region, fits" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.clearDirty();
    t.insertBlanks(2);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  ABC", str);
    }
}
test "Terminal: insertBlanks preserves background sgr" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.insertBlanks(2);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  ABC", str);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 0xFF,
            .g = 0,
            .b = 0,
        }, list_cell.cell.content.color_rgb);
    }
}
test "Terminal: insertBlanks shift off screen" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 10 });
    defer t.deinit(alloc);
    for ("  ABC") |c| try t.print(c);
    t.setCursorPos(1, 3);
    t.clearDirty();
    t.insertBlanks(2);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  X A", str);
    }
}
test "Terminal: insertBlanks split multi-cell character" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 10 });
    defer t.deinit(alloc);
    for ("123") |c| try t.print(c);
    try t.print('橋');
    t.setCursorPos(1, 1);
    t.clearDirty();
    t.insertBlanks(1);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(" 123", str);
    }
}
test "Terminal: insertBlanks inside left/right scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    t.setCursorPos(1, 3);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 3);
    t.clearDirty();
    t.insertBlanks(2);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  X A", str);
    }
}
test "Terminal: insertBlanks outside left/right scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 6, .rows = 10 });
    defer t.deinit(alloc);
    t.setCursorPos(1, 4);
    for ("ABC") |c| try t.print(c);
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.clearDirty();
    t.insertBlanks(2);
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("   ABX", str);
    }
}
test "Terminal: insertBlanks left/right scroll region large count" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    t.modes.set(.origin, true);
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(3, 5);
    t.setCursorPos(1, 1);
    t.clearDirty();
    t.insertBlanks(140);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  X", str);
    }
}
test "Terminal: insertBlanks deleting graphemes" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, true);
    try t.printString("ABC");
    try t.print(0x1F468);
    try t.print(0x200D);
    try t.print(0x1F469);
    try t.print(0x200D);
    try t.print(0x1F467);
    const page = t.screens.active.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 1), page.graphemeCount());
    t.setCursorPos(1, 1);
    t.clearDirty();
    t.insertBlanks(4);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    A", str);
    }
    try testing.expectEqual(@as(usize, 0), page.graphemeCount());
}
test "Terminal: insertBlanks shift graphemes" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, true);
    try t.printString("A");
    try t.print(0x1F468);
    try t.print(0x200D);
    try t.print(0x1F469);
    try t.print(0x200D);
    try t.print(0x1F467);
    const page = t.screens.active.cursor.page_pin.node.page();
    try testing.expectEqual(@as(usize, 1), page.graphemeCount());
    t.setCursorPos(1, 1);
    t.clearDirty();
    t.insertBlanks(1);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(" A👨‍👩‍👧", str);
    }
    try testing.expectEqual(@as(usize, 1), page.graphemeCount());
}
test "Terminal: insertBlanks split multi-cell character from tail" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 10 });
    defer t.deinit(alloc);
    try t.printString("橋123");
    t.setCursorPos(1, 2);
    t.insertBlanks(1);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("   12", str);
    }
}
test "Terminal: insertBlanks shifts hyperlinks" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("ABC");
    t.setCursorPos(1, 1);
    t.insertBlanks(2);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  ABC", str);
    }
    for (2..5) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
    }
    for (0..2) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell);
        try testing.expect(id == null);
    }
}
test "Terminal: insertBlanks pushes hyperlink off end completely" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 3, .rows = 2 });
    defer t.deinit(alloc);
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("ABC");
    t.setCursorPos(1, 1);
    t.insertBlanks(3);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(!row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
        const id = list_cell.node.page().lookupHyperlink(cell);
        try testing.expect(id == null);
    }
}
test "Terminal: insertBlanks wide char straddling right margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    t.setCursorPos(1, 1);
    for ("ABCD") |c| try t.print(c);
    try t.print('橋');
    t.scrolling_region.right = 4;
    t.setCursorPos(1, 3);
    t.insertBlanks(1);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AB CD", str);
    }
}
test "Terminal: insertBlanks wide char spacer_tail orphaned beyond right margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    for (0..5) |_| try t.print(0x4E2D);
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(1, 9);
    try t.print('a');
    t.insertBlanks(8);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("a", str);
    }
}
test "Terminal: insert mode with space" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);
    for ("hello") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.modes.set(.insert, true);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hXello", str);
    }
}
test "Terminal: insert mode doesn't wrap pushed characters" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);
    for ("hello") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.modes.set(.insert, true);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hXell", str);
    }
}
test "Terminal: insert mode does nothing at the end of the line" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);
    for ("hello") |c| try t.print(c);
    t.modes.set(.insert, true);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello\nX", str);
    }
}
test "Terminal: insert mode with wide characters" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);
    for ("hello") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.modes.set(.insert, true);
    try t.print('😀');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("h😀el", str);
    }
}
test "Terminal: insert mode with wide characters at end" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);
    for ("well") |c| try t.print(c);
    t.modes.set(.insert, true);
    try t.print('😀');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("well\n😀", str);
    }
}
test "Terminal: insert mode pushing off wide character" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);
    for ("123") |c| try t.print(c);
    try t.print('😀');
    t.modes.set(.insert, true);
    t.setCursorPos(1, 1);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X123", str);
    }
}
test "Terminal: deleteChars" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.clearDirty();
    t.deleteChars(2);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ADE", str);
    }
}
test "Terminal: deleteChars zero count" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.clearDirty();
    t.deleteChars(0);
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDE", str);
    }
}
test "Terminal: deleteChars more than half" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.clearDirty();
    t.deleteChars(3);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AE", str);
    }
}
test "Terminal: deleteChars more than line width" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.clearDirty();
    t.deleteChars(10);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }
}
test "Terminal: deleteChars should shift left" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.clearDirty();
    t.deleteChars(1);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ACDE", str);
    }
}
test "Terminal: deleteChars resets pending wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.deleteChars(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}
test "Terminal: deleteChars resets wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE123") |c| try t.print(c);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        const row = list_cell.row;
        try testing.expect(row.wrap);
    }
    t.setCursorPos(1, 1);
    t.deleteChars(1);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        const row = list_cell.row;
        try testing.expect(!row.wrap);
    }
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("XCDE\n123", str);
    }
}
test "Terminal: deleteChars simple operation" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    try t.printString("ABC123");
    t.setCursorPos(1, 3);
    t.clearDirty();
    t.deleteChars(2);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AB23", str);
    }
}
test "Terminal: deleteChars preserves background sgr" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    for ("ABC123") |c| try t.print(c);
    t.setCursorPos(1, 3);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.deleteChars(2);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AB23", str);
    }
    for (t.cols - 2..t.cols) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 0xFF,
            .g = 0,
            .b = 0,
        }, list_cell.cell.content.color_rgb);
    }
}
test "Terminal: deleteChars outside scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 6, .rows = 10 });
    defer t.deinit(alloc);
    try t.printString("ABC123");
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.clearDirty();
    t.deleteChars(2);
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.screens.active.cursor.pending_wrap);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC123", str);
    }
}
test "Terminal: deleteChars inside scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 6, .rows = 10 });
    defer t.deinit(alloc);
    try t.printString("ABC123");
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    t.setCursorPos(1, 4);
    t.clearDirty();
    t.deleteChars(1);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC2 3", str);
    }
}
test "Terminal: deleteChars split wide character from spacer tail" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 6, .rows = 10 });
    defer t.deinit(alloc);
    try t.printString("A橋123");
    t.setCursorPos(1, 3);
    t.deleteChars(1);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A 123", str);
    }
}
test "Terminal: deleteChars split wide character from wide" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 6, .rows = 10 });
    defer t.deinit(alloc);
    try t.printString("橋123");
    t.setCursorPos(1, 1);
    t.deleteChars(1);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '1'), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}
test "Terminal: deleteChars split wide character from end" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 6, .rows = 10 });
    defer t.deinit(alloc);
    try t.printString("A橋123");
    t.setCursorPos(1, 1);
    t.deleteChars(1);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x6A4B), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}
test "Terminal: deleteChars with a spacer head at the end" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 10 });
    defer t.deinit(alloc);
    try t.printString("0123橋123");
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        const row = list_cell.row;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
        try testing.expect(row.wrap);
    }
    t.setCursorPos(1, 1);
    t.deleteChars(1);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 3, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint.data);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}
test "Terminal: deleteChars split wide character tail" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setCursorPos(1, t.cols - 1);
    try t.print(0x6A4B);
    t.carriageReturn();
    t.deleteChars(t.cols - 1);
    try t.print('0');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("0", str);
    }
}
test "Terminal: deleteChars wide char boundary conditions" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 1, .cols = 8 });
    defer t.deinit(alloc);
    try t.printString("😀a😀b😀");
    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("😀a😀b😀", str);
    }
    t.setCursorPos(1, 2);
    t.deleteChars(3);
    t.screens.active.cursor.page_pin.node.page().assertIntegrity();
    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  b😀", str);
    }
}
test "Terminal: deleteChars wide char wrap boundary conditions" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 3, .cols = 8 });
    defer t.deinit(alloc);
    try t.printString(".......😀abcde😀......");
    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(".......\n😀abcde\n😀......", str);
        const unwrapped = try t.plainStringUnwrapped(alloc);
        defer testing.allocator.free(unwrapped);
        try testing.expectEqualStrings(".......😀abcde😀......", unwrapped);
    }
    t.setCursorPos(2, 2);
    t.clearDirty();
    t.deleteChars(3);
    t.screens.active.cursor.page_pin.node.page().assertIntegrity();
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 1 } }));
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 2 } }));
    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(".......\n cde\n😀......", str);
        const unwrapped = try t.plainStringUnwrapped(alloc);
        defer testing.allocator.free(unwrapped);
        try testing.expectEqualStrings(".......  cde\n😀......", unwrapped);
    }
}
test "Terminal: deleteChars wide char across right margin" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 3, .cols = 8 });
    defer t.deinit(alloc);
    try t.printString("123456橋");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(2, 7);
    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("123456橋", str);
    }
    t.setCursorPos(1, 2);
    t.deleteChars(1);
    t.screens.active.cursor.page_pin.node.page().assertIntegrity();
    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("13456", str);
    }
}
test "Terminal: saveCursor" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);
    try t.setAttribute(.{ .bold = {} });
    t.screens.active.charset.gr = .G3;
    t.modes.set(.origin, true);
    t.saveCursor();
    t.screens.active.charset.gr = .G0;
    try t.setAttribute(.{ .unset = {} });
    t.modes.set(.origin, false);
    t.restoreCursor();
    try testing.expect(t.screens.active.cursor.style.flags.bold);
    try testing.expect(t.screens.active.charset.gr == .G3);
    try testing.expect(t.modes.get(.origin));
}
test "Terminal: saveCursor position" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    t.setCursorPos(1, 5);
    try t.print('A');
    t.saveCursor();
    t.setCursorPos(1, 1);
    try t.print('B');
    t.restoreCursor();
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B   AX", str);
    }
}
test "Terminal: saveCursor pending wrap state" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setCursorPos(1, 5);
    try t.print('A');
    t.saveCursor();
    t.setCursorPos(1, 1);
    try t.print('B');
    t.restoreCursor();
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B   A\nX", str);
    }
}
test "Terminal: saveCursor origin mode" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    t.modes.set(.origin, true);
    t.saveCursor();
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(3, 5);
    t.setTopAndBottomMargin(2, 4);
    t.restoreCursor();
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X", str);
    }
}
test "Terminal: saveCursor resize" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    t.setCursorPos(1, 10);
    t.saveCursor();
    try t.resize(alloc, .{ .cols = 5, .rows = 5 });
    t.restoreCursor();
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    X", str);
    }
}
test "Terminal: saveCursor protected pen" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    t.setProtectedMode(.iso);
    try testing.expect(t.screens.active.cursor.protected);
    t.setCursorPos(1, 10);
    t.saveCursor();
    t.setProtectedMode(.off);
    try testing.expect(!t.screens.active.cursor.protected);
    t.restoreCursor();
    try testing.expect(t.screens.active.cursor.protected);
}
test "Terminal: saveCursor doesn't modify hyperlink state" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);
    try t.screens.active.startHyperlink("http://example.com", null);
    const id = t.screens.active.cursor.hyperlink_id;
    t.saveCursor();
    try testing.expectEqual(id, t.screens.active.cursor.hyperlink_id);
    t.restoreCursor();
    try testing.expectEqual(id, t.screens.active.cursor.hyperlink_id);
}
test "Terminal: restoreCursor uses default style on OutOfSpace" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);
    try t.setAttribute(.{ .bold = {} });
    t.saveCursor();
    try t.setAttribute(.{ .unset = {} });
    try testing.expect(!t.screens.active.cursor.style.flags.bold);
    const max_styles = std.math.maxInt(size.CellCountInt);
    while (t.screens.active.cursor.page_pin.node.capacity().styles < max_styles) {
        _ = t.screens.active.increaseCapacity(
            t.screens.active.cursor.page_pin.node,
            .styles,
        ) catch break;
    }
    const page = t.screens.active.cursor.page_pin.node.page();
    try testing.expectEqual(max_styles, page.capacity.styles);
    {
        page.pauseIntegrityChecks(true);
        defer page.pauseIntegrityChecks(false);
        defer page.assertIntegrity();
        const max_items = page.styles.layout.cap;
        var n: usize = 1;
        while (n < max_items) : (n += 1) {
            _ = page.styles.add(
                page.memory,
                .{ .bg_color = .{ .rgb = @bitCast(@as(u24, @intCast(n))) } },
            ) catch break;
        }
    }
    t.restoreCursor();
    try testing.expect(!t.screens.active.cursor.style.flags.bold);
    try testing.expectEqual(style.default_id, t.screens.active.cursor.style_id);
}
test "Terminal: setProtectedMode" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);
    try testing.expect(!t.screens.active.cursor.protected);
    t.setProtectedMode(.off);
    try testing.expect(!t.screens.active.cursor.protected);
    t.setProtectedMode(.iso);
    try testing.expect(t.screens.active.cursor.protected);
    t.setProtectedMode(.dec);
    try testing.expect(t.screens.active.cursor.protected);
    t.setProtectedMode(.off);
    try testing.expect(!t.screens.active.cursor.protected);
}
test "Terminal: eraseLine simple erase right" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 3);
    t.clearDirty();
    t.eraseLine(.right, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AB", str);
    }
}
test "Terminal: eraseLine resets pending wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.eraseLine(.right, false);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('B');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDB", str);
    }
}
test "Terminal: eraseLine resets wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE123") |c| try t.print(c);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(list_cell.row.wrap);
    }
    t.setCursorPos(1, 1);
    t.eraseLine(.right, false);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(!list_cell.row.wrap);
    }
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\n123", str);
    }
}
test "Terminal: eraseLine right preserves background sgr" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.eraseLine(.right, false);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
        for (1..5) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
            try testing.expectEqual(Cell.RGB{
                .r = 0xFF,
                .g = 0,
                .b = 0,
            }, list_cell.cell.content.color_rgb);
        }
    }
}
test "Terminal: eraseLine right wide character" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    for ("AB") |c| try t.print(c);
    try t.print('橋');
    for ("DE") |c| try t.print(c);
    t.setCursorPos(1, 4);
    t.clearDirty();
    t.eraseLine(.right, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AB", str);
    }
}
test "Terminal: eraseLine right protected attributes respected with iso" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.clearDirty();
    t.eraseLine(.right, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC", str);
    }
}
test "Terminal: eraseLine right protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(1, 2);
    t.clearDirty();
    t.eraseLine(.right, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }
}
test "Terminal: eraseLine right protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.clearDirty();
    t.eraseLine(.right, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }
}
test "Terminal: eraseLine right protected requested" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    for ("12345678") |c| try t.print(c);
    t.setCursorPos(t.screens.active.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screens.active.cursor.y + 1, 4);
    t.clearDirty();
    t.eraseLine(.right, true);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("123  X", str);
    }
}
test "Terminal: eraseLine simple erase left" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 3);
    t.clearDirty();
    t.eraseLine(.left, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("   DE", str);
    }
}
test "Terminal: eraseLine left resets wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.clearDirty();
    t.eraseLine(.left, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('B');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    B", str);
    }
}
test "Terminal: eraseLine left preserves background sgr" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.eraseLine(.left, false);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  CDE", str);
        for (0..2) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
            try testing.expectEqual(Cell.RGB{
                .r = 0xFF,
                .g = 0,
                .b = 0,
            }, list_cell.cell.content.color_rgb);
        }
    }
}
test "Terminal: eraseLine left wide character" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    for ("AB") |c| try t.print(c);
    try t.print('橋');
    for ("DE") |c| try t.print(c);
    t.setCursorPos(1, 3);
    t.clearDirty();
    t.eraseLine(.left, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    DE", str);
    }
}
test "Terminal: eraseLine left protected attributes respected with iso" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.clearDirty();
    t.eraseLine(.left, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC", str);
    }
}
test "Terminal: eraseLine left protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(1, 2);
    t.clearDirty();
    t.eraseLine(.left, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C", str);
    }
}
test "Terminal: eraseLine left protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.clearDirty();
    t.eraseLine(.left, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C", str);
    }
}
test "Terminal: eraseLine left protected requested" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    for ("123456789") |c| try t.print(c);
    t.setCursorPos(t.screens.active.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screens.active.cursor.y + 1, 8);
    t.clearDirty();
    t.eraseLine(.left, true);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("     X  9", str);
    }
}
test "Terminal: eraseLine complete preserves background sgr" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.eraseLine(.complete, false);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
        for (0..5) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
            try testing.expectEqual(Cell.RGB{
                .r = 0xFF,
                .g = 0,
                .b = 0,
            }, list_cell.cell.content.color_rgb);
        }
    }
}
test "Terminal: eraseLine complete resets wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE123") |c| try t.print(c);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(list_cell.row.wrap);
    }
    t.setCursorPos(1, 1);
    t.eraseLine(.complete, false);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(!list_cell.row.wrap);
    }
    try t.print('X');
    try t.resize(alloc, .{ .rows = 5, .cols = 10 });
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\n123", str);
    }
}
test "Terminal: eraseLine complete clears kitty placeholder flag" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.print(kitty.graphics.unicode.placeholder);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(list_cell.row.kitty_virtual_placeholder);
    }
    t.eraseLine(.complete, false);
    const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
    try testing.expect(!list_cell.row.kitty_virtual_placeholder);
}
test "Terminal: eraseLine complete protected attributes respected with iso" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.clearDirty();
    t.eraseLine(.complete, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC", str);
    }
}
test "Terminal: eraseLine complete protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(1, 2);
    t.clearDirty();
    t.eraseLine(.complete, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}
test "Terminal: eraseLine complete protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.clearDirty();
    t.eraseLine(.complete, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}
test "Terminal: eraseLine complete protected requested" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    for ("123456789") |c| try t.print(c);
    t.setCursorPos(t.screens.active.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screens.active.cursor.y + 1, 8);
    t.clearDirty();
    t.eraseLine(.complete, true);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("     X", str);
    }
}
test "Terminal: tabClear single" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 30, .rows = 5 });
    defer t.deinit(alloc);
    t.horizontalTab();
    t.tabClear(.current);
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    t.setCursorPos(1, 1);
    t.horizontalTab();
    try testing.expectEqual(@as(usize, 16), t.screens.active.cursor.x);
}
test "Terminal: tabClear all" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 30, .rows = 5 });
    defer t.deinit(alloc);
    t.tabClear(.all);
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    t.setCursorPos(1, 1);
    t.horizontalTab();
    try testing.expectEqual(@as(usize, 29), t.screens.active.cursor.x);
}
test "Terminal: printRepeat simple" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("A");
    try t.printRepeat(1);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AA", str);
    }
}
test "Terminal: printRepeat wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("    A");
    try t.printRepeat(1);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    A\nA", str);
    }
}
test "Terminal: printRepeat no previous character" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printRepeat(1);
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}
test "Terminal: printSlice simple ascii" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    try t.printSlice(&.{ 'h', 'e', 'l', 'l', 'o' });
    try testing.expectEqual(@as(usize, 5), t.screens.active.cursor.x);
    try testing.expectEqual(@as(u21, 'o'), t.previous_char.?);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello", str);
    }
}
test "Terminal: printSlice charset batched fill" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);
    t.configureCharset(.G1, .dec_special);
    t.invokeCharset(.GL, .G1, false);
    t.modes.set(.grapheme_cluster, true);
    try t.setAttribute(.{ .@"8_bg" = .red });
    t.eraseDisplay(.complete, false);
    const cps = [_]u32{ 'l', 'q', 'q', 'q', 'k', 'm', 'q', 'q', 'q', 'j' };
    for ([_]sgr.Attribute{ .unset, .unset, .bold, .bold, .unset }) |attr| {
        t.setCursorPos(1, 1);
        try t.setAttribute(attr);
        try testing.expectEqual(cps.len, try t.printSliceFast(&cps, true, false));
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("┌───┐\n└───┘", str);
        try testing.expectEqual(@as(u21, 'j'), t.previous_char.?);
        try testing.expect(t.screens.active.cursor.pending_wrap);
        for (0..2) |y| {
            for (0..5) |x| {
                const cell = t.screens.active.pages.getCell(.{ .active = .{
                    .x = @intCast(x),
                    .y = @intCast(y),
                } }).?.cell;
                try testing.expectEqual(t.screens.active.cursor.style_id, cell.style_id);
            }
        }
        try t.screens.active.cursor.page_pin.node.page().verifyIntegrity(alloc);
    }
}
test "Terminal: printSlice charset matches scalar printing" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    for ([_]charsets.Charset{ .dec_special, .british }) |set| {
        for ([_]bool{ false, true }) |grapheme_cluster| {
            var scalar = try init(io_impl, alloc, .{ .cols = 17, .rows = 4 });
            defer scalar.deinit(alloc);
            var batched = try init(io_impl, alloc, .{ .cols = 17, .rows = 4 });
            defer batched.deinit(alloc);
            for ([_]*Terminal{ &scalar, &batched }) |t| {
                t.configureCharset(.G0, set);
                t.modes.set(.grapheme_cluster, grapheme_cluster);
            }
            var bytes: [240]u32 = undefined;
            for (&bytes, 0x10..) |*cp, value| cp.* = @intCast(value);
            const mixed = [_]u32{ 0x100, 'q', 0x301, 'x', 0x4E00, '#', 0xFE0F, 0x1F600, 'j' };
            for ([_][]const u32{ &bytes, &mixed }) |cps| {
                for (cps) |cp| try scalar.print(@intCast(cp));
                try batched.printSlice(cps);
                const expected = try scalar.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
                defer alloc.free(expected);
                const actual = try batched.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
                defer alloc.free(actual);
                try testing.expectEqualStrings(expected, actual);
                try testing.expectEqual(scalar.screens.active.cursor.x, batched.screens.active.cursor.x);
                try testing.expectEqual(scalar.screens.active.cursor.y, batched.screens.active.cursor.y);
                try testing.expectEqual(scalar.screens.active.cursor.pending_wrap, batched.screens.active.cursor.pending_wrap);
                try testing.expectEqual(scalar.previous_char, batched.previous_char);
            }
        }
    }
}
test "Terminal: printSlice charset single shift and repeat" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);
    t.configureCharset(.G0, .dec_special);
    t.configureCharset(.G2, .british);
    t.invokeCharset(.GL, .G2, true);
    try t.printSlice(&.{ '#', 'q' });
    try testing.expectEqual(null, t.screens.active.charset.single_shift);
    try t.printRepeat(2);
    t.configureCharset(.G0, .ascii);
    try t.printRepeat(2);
    const str = try t.plainString(alloc);
    defer alloc.free(str);
    try testing.expectEqualStrings("£───qq", str);
}
test "Terminal: printSlice wraps and scrolls" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);
    try t.printSlice(&.{ 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l' });
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("fghij\nkl", str);
    }
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
}
test "Terminal: printSlice pending wrap state" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);
    try t.printSlice(&.{ 'a', 'b', 'c', 'd', 'e' });
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.x);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("abcde", str);
    }
}
fn testPrintSliceDifferential(
    io_impl: std.Io,
    alloc: Allocator,
    rand: std.Random,
    ops: usize,
    cols: size.CellCountInt,
    rows: size.CellCountInt,
) !void {
    var t1 = try init(io_impl, alloc, .{
        .cols = cols,
        .rows = rows,
    });
    defer t1.deinit(alloc);
    var t2 = try init(io_impl, alloc, .{
        .cols = cols,
        .rows = rows,
    });
    defer t2.deinit(alloc);
    const alphabet = [_]u21{
        'a',     'b',     'Z',    '0',    ' ',     0x10,   0x1F,   0x7F,
        'é',
        0xFF,    0x301,   0x4E00, 0x4E01, 0x1F600, 0x200D, 0xFE0F, 'x',
        'y',     0x1F9D1, 0x0308, 0xAD,   0x3042,  0xAC00, 'q',    'r',
        's',     't',     'u',    'v',    'w',     '1',    '2',    0x1F1E6,
        0x1F1E7, 0x1100,  0x1161, 0x11A8, 0x200C,  0x0430, 0x03B1,
    };
    var cps_buf: [64]u32 = undefined;
    var last_n: usize = 0;
    for (0..ops) |_| {
        switch (rand.intRangeAtMost(u8, 0, 20)) {
            0...9 => {
                const n = rand.intRangeAtMost(usize, 1, cps_buf.len);
                last_n = n;
                for (cps_buf[0..n]) |*cp| {
                    cp.* = alphabet[rand.intRangeLessThan(usize, 0, alphabet.len)];
                }
                for (cps_buf[0..n]) |cp| try t1.print(@intCast(cp));
                var i: usize = 0;
                while (i < n) {
                    const chunk = rand.intRangeAtMost(usize, 1, n - i);
                    try t2.printSlice(cps_buf[i..][0..chunk]);
                    i += chunk;
                }
            },
            10 => {
                t1.carriageReturn();
                t2.carriageReturn();
                try t1.linefeed();
                try t2.linefeed();
            },
            11 => {
                const row = rand.intRangeAtMost(usize, 1, rows);
                const col = rand.intRangeAtMost(usize, 1, cols);
                t1.setCursorPos(row, col);
                t2.setCursorPos(row, col);
            },
            12 => {
                const attr: sgr.Attribute = switch (rand.intRangeAtMost(u8, 0, 3)) {
                    0 => .{ .unset = {} },
                    1 => .{ .bold = {} },
                    2 => .{ .direct_color_fg = .{
                        .r = rand.int(u8),
                        .g = rand.int(u8),
                        .b = rand.int(u8),
                    } },
                    3 => .{ .@"8_fg" = .red },
                    else => unreachable,
                };
                try t1.setAttribute(attr);
                try t2.setAttribute(attr);
            },
            13 => {
                const v = rand.boolean();
                t1.modes.set(.insert, v);
                t2.modes.set(.insert, v);
            },
            14 => {
                const v = rand.boolean();
                t1.modes.set(.wraparound, v);
                t2.modes.set(.wraparound, v);
            },
            15 => {
                const v = rand.boolean();
                t1.modes.set(.grapheme_cluster, v);
                t2.modes.set(.grapheme_cluster, v);
            },
            16 => {
                t1.modes.set(.enable_left_and_right_margin, true);
                t2.modes.set(.enable_left_and_right_margin, true);
                const left = rand.intRangeAtMost(usize, 1, cols / 2);
                const right = rand.intRangeAtMost(usize, cols / 2, cols);
                t1.setLeftAndRightMargin(left, right);
                t2.setLeftAndRightMargin(left, right);
            },
            17 => {
                t1.setLeftAndRightMargin(0, 0);
                t2.setLeftAndRightMargin(0, 0);
            },
            18 => {
                try t1.screens.active.startHyperlink("http://example.com", null);
                try t2.screens.active.startHyperlink("http://example.com", null);
            },
            19 => {
                t1.screens.active.endHyperlink();
                t2.screens.active.endHyperlink();
            },
            20 => {
                const set = rand.enumValue(charsets.Charset);
                t1.configureCharset(.G0, set);
                t2.configureCharset(.G0, set);
            },
            else => unreachable,
        }
        try testing.expectEqual(t1.screens.active.cursor.x, t2.screens.active.cursor.x);
        try testing.expectEqual(t1.screens.active.cursor.y, t2.screens.active.cursor.y);
        try testing.expectEqual(
            t1.screens.active.cursor.pending_wrap,
            t2.screens.active.cursor.pending_wrap,
        );
        {
            const str1 = try t1.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
            defer alloc.free(str1);
            const str2 = try t2.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
            defer alloc.free(str2);
            testing.expectEqualStrings(str1, str2) catch |err| {
                std.debug.print("last print cps: {any}\n", .{cps_buf[0..last_n]});
                std.debug.print("modes: 2027={} insert={} wrap={} sr.left={} sr.right={} cols={}\n", .{
                    t1.modes.get(.grapheme_cluster),
                    t1.modes.get(.insert),
                    t1.modes.get(.wraparound),
                    t1.scrolling_region.left,
                    t1.scrolling_region.right,
                    cols,
                });
                return err;
            };
        }
    }
    try t1.screens.active.cursor.page_pin.node.page().verifyIntegrity(alloc);
    try t2.screens.active.cursor.page_pin.node.page().verifyIntegrity(alloc);
}
test "Terminal: printSlice differential fuzz vs print" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();
    try testPrintSliceDifferential(io_impl, alloc, rand, 500, 80, 24);
    try testPrintSliceDifferential(io_impl, alloc, rand, 500, 10, 4);
    try testPrintSliceDifferential(io_impl, alloc, rand, 500, 5, 2);
    try testPrintSliceDifferential(io_impl, alloc, rand, 200, 2, 2);
}
test "Terminal: printAttributes" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    var storage: [64]u8 = undefined;
    {
        try t.setAttribute(.{ .direct_color_fg = .{ .r = 1, .g = 2, .b = 3 } });
        defer t.setAttribute(.unset) catch unreachable;
        const buf = try t.printAttributes(&storage);
        try testing.expectEqualStrings("0;38:2::1:2:3", buf);
    }
    {
        try t.setAttribute(.bold);
        try t.setAttribute(.{ .direct_color_bg = .{ .r = 1, .g = 2, .b = 3 } });
        defer t.setAttribute(.unset) catch unreachable;
        const buf = try t.printAttributes(&storage);
        try testing.expectEqualStrings("0;1;48:2::1:2:3", buf);
    }
    {
        try t.setAttribute(.bold);
        try t.setAttribute(.faint);
        try t.setAttribute(.italic);
        try t.setAttribute(.{ .underline = .single });
        try t.setAttribute(.blink);
        try t.setAttribute(.inverse);
        try t.setAttribute(.invisible);
        try t.setAttribute(.strikethrough);
        try t.setAttribute(.overline);
        try t.setAttribute(.{ .direct_color_fg = .{ .r = 100, .g = 200, .b = 255 } });
        try t.setAttribute(.{ .direct_color_bg = .{ .r = 101, .g = 102, .b = 103 } });
        defer t.setAttribute(.unset) catch unreachable;
        const buf = try t.printAttributes(&storage);
        try testing.expectEqualStrings("0;1;2;3;4;53;5;7;8;9;38:2::100:200:255;48:2::101:102:103", buf);
    }
    const Case = struct {
        underline: sgr.Attribute.Underline,
        expected: []const u8,
    };
    for ([_]Case{
        .{ .underline = .single, .expected = "0;4" },
        .{ .underline = .double, .expected = "0;4:2" },
        .{ .underline = .curly, .expected = "0;4:3" },
        .{ .underline = .dotted, .expected = "0;4:4" },
        .{ .underline = .dashed, .expected = "0;4:5" },
    }) |case| {
        try t.setAttribute(.{ .underline = case.underline });
        const buf = try t.printAttributes(&storage);
        try testing.expectEqualStrings(case.expected, buf);
    }
    try t.setAttribute(.unset);
    {
        const buf = try t.printAttributes(&storage);
        try testing.expectEqualStrings("0", buf);
    }
}
test "Terminal: eraseDisplay simple erase below" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.clearDirty();
    t.eraseDisplay(.below, false);
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nD", str);
    }
}
test "Terminal: eraseDisplay erase below preserves SGR bg" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.eraseDisplay(.below, false);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nD", str);
        for (1..5) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{
                .x = @intCast(x),
                .y = 1,
            } }).?;
            try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
            try testing.expectEqual(Cell.RGB{
                .r = 0xFF,
                .g = 0,
                .b = 0,
            }, list_cell.cell.content.color_rgb);
        }
    }
}
test "Terminal: eraseDisplay below split multi-cell" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("AB橋C");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DE橋F");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GH橋I");
    t.setCursorPos(2, 4);
    t.eraseDisplay(.below, false);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AB橋C\nDE", str);
    }
}
test "Terminal: eraseDisplay below protected attributes respected with iso" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(.below, false);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}
test "Terminal: eraseDisplay below protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(2, 2);
    t.eraseDisplay(.below, false);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nD", str);
    }
}
test "Terminal: eraseDisplay below protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(.below, false);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nD", str);
    }
}
test "Terminal: eraseDisplay below protected attributes respected with force" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(.below, true);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}
test "Terminal: eraseDisplay simple erase above" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.clearDirty();
    t.eraseDisplay(.above, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n  F\nGHI", str);
    }
}
test "Terminal: eraseDisplay erase above preserves SGR bg" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.eraseDisplay(.above, false);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n  F\nGHI", str);
        for (0..2) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{
                .x = @intCast(x),
                .y = 1,
            } }).?;
            try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
            try testing.expectEqual(Cell.RGB{
                .r = 0xFF,
                .g = 0,
                .b = 0,
            }, list_cell.cell.content.color_rgb);
        }
    }
}
test "Terminal: eraseDisplay above split multi-cell" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("AB橋C");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DE橋F");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GH橋I");
    t.setCursorPos(2, 3);
    t.eraseDisplay(.above, false);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n    F\nGH橋I", str);
    }
}
test "Terminal: eraseDisplay above protected attributes respected with iso" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(.above, false);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}
test "Terminal: eraseDisplay above protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(2, 2);
    t.eraseDisplay(.above, false);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n  F\nGHI", str);
    }
}
test "Terminal: eraseDisplay above protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(.above, false);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n  F\nGHI", str);
    }
}
test "Terminal: eraseDisplay above protected attributes respected with force" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(.above, true);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}
test "Terminal: eraseDisplay protected complete" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    for ("123456789") |c| try t.print(c);
    t.setCursorPos(t.screens.active.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screens.active.cursor.y + 1, 4);
    t.clearDirty();
    t.eraseDisplay(.complete, true);
    for (0..t.rows) |y| try testing.expect(t.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n     X", str);
    }
}
test "Terminal: eraseDisplay protected below" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    for ("123456789") |c| try t.print(c);
    t.setCursorPos(t.screens.active.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screens.active.cursor.y + 1, 4);
    t.eraseDisplay(.below, true);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n123  X", str);
    }
}
test "Terminal: eraseDisplay scroll complete" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    t.eraseDisplay(.scroll_complete, false);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}
test "Terminal: eraseDisplay protected above" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    for ("123456789") |c| try t.print(c);
    t.setCursorPos(t.screens.active.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screens.active.cursor.y + 1, 8);
    t.eraseDisplay(.above, true);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n     X  9", str);
    }
}
test "Terminal: eraseDisplay complete preserves cursor" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.setAttribute(.{ .bold = {} });
    try t.printString("AAAA");
    try testing.expect(t.screens.active.cursor.style_id != style.default_id);
    t.eraseDisplay(.complete, false);
    try testing.expect(t.screens.active.cursor.style_id != style.default_id);
}
test "Terminal: semantic prompt" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    for ("hello") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.screens.active.cursor.x);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x - 1,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(.prompt, cell.semantic_content);
        const row = list_cell.row;
        try testing.expectEqual(.prompt, row.semantic_prompt);
    }
    try t.semanticPrompt(.init(.end_prompt_start_input_terminate_eol));
    t.carriageReturn();
    try t.linefeed();
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    for ("world") |c| try t.print(c);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x - 1,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(.output, cell.semantic_content);
        const row = list_cell.row;
        try testing.expectEqual(.none, row.semantic_prompt);
    }
}
test "Terminal: semantic prompt continuations" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    for ("hello") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.screens.active.cursor.x);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x - 1,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(.prompt, cell.semantic_content);
        const row = list_cell.row;
        try testing.expectEqual(.prompt, row.semantic_prompt);
    }
    t.carriageReturn();
    try t.linefeed();
    try t.semanticPrompt(.{
        .action = .prompt_start,
        .options_unvalidated = "k=c",
    });
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    for ("world") |c| try t.print(c);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x - 1,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(.prompt, cell.semantic_content);
        const row = list_cell.row;
        try testing.expectEqual(.prompt_continuation, row.semantic_prompt);
    }
}
test "Terminal: index in prompt mode marks new row as prompt continuation" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    try t.semanticPrompt(.init(.prompt_start));
    for ("hello") |c| try t.print(c);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 0,
        } }).?;
        try testing.expectEqual(.prompt, list_cell.row.semantic_prompt);
    }
    t.carriageReturn();
    try t.linefeed();
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?;
        try testing.expectEqual(.prompt_continuation, list_cell.row.semantic_prompt);
    }
    try testing.expectEqual(.prompt, t.screens.active.cursor.semantic_content);
}
test "Terminal: index in input mode does not mark new row as prompt" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    try t.semanticPrompt(.init(.prompt_start));
    for ("$ ") |c| try t.print(c);
    try t.semanticPrompt(.init(.end_prompt_start_input));
    for ("echo \\") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?;
        try testing.expectEqual(.prompt_continuation, list_cell.row.semantic_prompt);
    }
    try testing.expectEqual(.input, t.screens.active.cursor.semantic_content);
}
test "Terminal: index in output mode does not mark new row as prompt" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    try t.semanticPrompt(.init(.prompt_start));
    for ("$ ") |c| try t.print(c);
    try t.semanticPrompt(.init(.end_prompt_start_input));
    for ("ls") |c| try t.print(c);
    try t.semanticPrompt(.init(.end_input_start_output));
    t.carriageReturn();
    try t.linefeed();
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?;
        try testing.expectEqual(.none, list_cell.row.semantic_prompt);
    }
}
test "Terminal: OSC133C at x=0 on prompt row clears prompt mark" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    try t.semanticPrompt(.init(.prompt_start));
    for ("$ echo \\") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?;
        try testing.expectEqual(.prompt_continuation, list_cell.row.semantic_prompt);
    }
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try t.semanticPrompt(.init(.end_input_start_output));
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?;
        try testing.expectEqual(.none, list_cell.row.semantic_prompt);
    }
}
test "Terminal: OSC133C at x>0 on prompt row does not clear prompt mark" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    try t.semanticPrompt(.init(.prompt_start));
    for ("$ ") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    try t.semanticPrompt(.{
        .action = .prompt_start,
        .options_unvalidated = "k=c",
    });
    for ("> ") |c| try t.print(c);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?;
        try testing.expectEqual(.prompt_continuation, list_cell.row.semantic_prompt);
    }
    try testing.expect(t.screens.active.cursor.x > 0);
    try t.semanticPrompt(.init(.end_input_start_output));
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?;
        try testing.expectEqual(.prompt_continuation, list_cell.row.semantic_prompt);
    }
}
test "Terminal: multiple newlines in prompt mode marks all rows" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    try t.semanticPrompt(.init(.prompt_start));
    for ("line1") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("line2") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("line3") |c| try t.print(c);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 0,
        } }).?;
        try testing.expectEqual(.prompt, list_cell.row.semantic_prompt);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?;
        try testing.expectEqual(.prompt_continuation, list_cell.row.semantic_prompt);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 2,
        } }).?;
        try testing.expectEqual(.prompt_continuation, list_cell.row.semantic_prompt);
    }
}
test "Terminal: OSC133A click_events=1 sets click to click_events" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    try testing.expectEqual(.none, t.screens.active.semantic_prompt.click);
    try t.semanticPrompt(.{
        .action = .fresh_line_new_prompt,
        .options_unvalidated = "click_events=1",
    });
    try testing.expectEqual(Screen.SemanticPrompt.SemanticClick{ .click_events = .absolute }, t.screens.active.semantic_prompt.click);
}
test "Terminal: OSC133A click_events=2 sets click to click_events (relative)" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    try testing.expectEqual(.none, t.screens.active.semantic_prompt.click);
    try t.semanticPrompt(.{
        .action = .fresh_line_new_prompt,
        .options_unvalidated = "click_events=2",
    });
    try testing.expectEqual(Screen.SemanticPrompt.SemanticClick{ .click_events = .relative }, t.screens.active.semantic_prompt.click);
}
test "Terminal: OSC133A click_events=0 does not set click_events" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    try t.semanticPrompt(.{
        .action = .fresh_line_new_prompt,
        .options_unvalidated = "click_events=0",
    });
    try testing.expectEqual(.none, t.screens.active.semantic_prompt.click);
}
test "Terminal: OSC133A cl option sets click to cl value" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    try t.semanticPrompt(.{
        .action = .fresh_line_new_prompt,
        .options_unvalidated = "cl=m",
    });
    try testing.expectEqual(Screen.SemanticPrompt.SemanticClick{ .cl = .multiple }, t.screens.active.semantic_prompt.click);
}
test "Terminal: OSC133A cl=line sets click to line" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    try t.semanticPrompt(.{
        .action = .fresh_line_new_prompt,
        .options_unvalidated = "cl=line",
    });
    try testing.expectEqual(Screen.SemanticPrompt.SemanticClick{ .cl = .line }, t.screens.active.semantic_prompt.click);
}
test "Terminal: OSC133A click_events=1 takes priority over cl" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    try t.semanticPrompt(.{
        .action = .fresh_line_new_prompt,
        .options_unvalidated = "click_events=1;cl=m",
    });
    try testing.expectEqual(Screen.SemanticPrompt.SemanticClick{ .click_events = .absolute }, t.screens.active.semantic_prompt.click);
}
test "Terminal: OSC133A click_events=0 falls back to cl" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    try t.semanticPrompt(.{
        .action = .fresh_line_new_prompt,
        .options_unvalidated = "click_events=0;cl=v",
    });
    try testing.expectEqual(Screen.SemanticPrompt.SemanticClick{ .cl = .conservative_vertical }, t.screens.active.semantic_prompt.click);
}
test "Terminal: OSC133A no click options leaves click as none" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    try t.semanticPrompt(.{
        .action = .fresh_line_new_prompt,
        .options_unvalidated = "aid=123",
    });
    try testing.expectEqual(.none, t.screens.active.semantic_prompt.click);
}
test "Terminal: cursorIsAtPrompt" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    try testing.expect(!t.cursorIsAtPrompt());
    try t.semanticPrompt(.init(.prompt_start));
    try testing.expect(t.cursorIsAtPrompt());
    for ("$ ") |c| try t.print(c);
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try testing.expect(t.cursorIsAtPrompt());
    for ("ls") |c| try t.print(c);
    try t.semanticPrompt(.init(.end_input_start_output));
    try testing.expect(t.cursorIsAtPrompt());
    try t.linefeed();
    try testing.expect(!t.cursorIsAtPrompt());
    try t.linefeed();
    try t.semanticPrompt(.init(.prompt_start));
    try testing.expect(t.cursorIsAtPrompt());
}
test "Terminal: cursorIsAtPrompt alternate screen" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 3, .rows = 2 });
    defer t.deinit(alloc);
    try testing.expect(!t.cursorIsAtPrompt());
    try t.semanticPrompt(.init(.prompt_start));
    try testing.expect(t.cursorIsAtPrompt());
    try t.switchScreenMode(.@"1049", true);
    try testing.expect(!t.cursorIsAtPrompt());
    try t.semanticPrompt(.init(.prompt_start));
    try testing.expect(!t.cursorIsAtPrompt());
}
test "Terminal: cursor defaults update current default cursor" {
    var t = try init(testing.io, testing.allocator, .{
        .cols = 10,
        .rows = 10,
        .default_cursor_style = .bar,
        .default_cursor_blink = true,
    });
    defer t.deinit(testing.allocator);
    try testing.expect(t.cursor.is_default);
    try testing.expectEqual(.bar, t.screens.active.cursor.cursor_style);
    try testing.expect(t.modes.get(.cursor_blinking));
    t.setDefaultCursorStyle(.underline);
    t.setDefaultCursorBlink(false);
    try testing.expect(t.cursor.is_default);
    try testing.expectEqual(.underline, t.screens.active.cursor.cursor_style);
    try testing.expect(!t.modes.get(.cursor_blinking));
    t.setDefaultCursorBlink(null);
    try testing.expect(t.modes.get(.cursor_blinking));
}
test "Terminal: cursor defaults do not override explicit cursor" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    t.setCursorStyle(.blinking_bar);
    try testing.expect(!t.cursor.is_default);
    try testing.expectEqual(.bar, t.screens.active.cursor.cursor_style);
    try testing.expect(t.modes.get(.cursor_blinking));
    t.setDefaultCursorStyle(.underline);
    t.setDefaultCursorBlink(false);
    try testing.expectEqual(.underline, t.cursor.default_style);
    try testing.expectEqual(false, t.cursor.default_blink);
    try testing.expectEqual(.bar, t.screens.active.cursor.cursor_style);
    try testing.expect(t.modes.get(.cursor_blinking));
    t.setCursorStyle(.default);
    try testing.expect(t.cursor.is_default);
    try testing.expectEqual(.underline, t.screens.active.cursor.cursor_style);
    try testing.expect(!t.modes.get(.cursor_blinking));
    t.setCursorStyle(.steady_block);
    t.fullReset();
    try testing.expect(t.cursor.is_default);
    try testing.expectEqual(.underline, t.screens.active.cursor.cursor_style);
    try testing.expect(!t.modes.get(.cursor_blinking));
}
test "Terminal: fullReset with a non-empty pen" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    try t.setAttribute(.{ .direct_color_fg = .{ .r = 0xFF, .g = 0, .b = 0x7F } });
    try t.setAttribute(.{ .direct_color_bg = .{ .r = 0xFF, .g = 0, .b = 0x7F } });
    t.screens.active.cursor.semantic_content = .input;
    t.fullReset();
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.style_id == 0);
    }
    try testing.expectEqual(@as(style.Id, 0), t.screens.active.cursor.style_id);
    try testing.expectEqual(.output, t.screens.active.cursor.semantic_content);
}
test "Terminal: fullReset hyperlink" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    try t.screens.active.startHyperlink("http://example.com", null);
    t.fullReset();
    try testing.expectEqual(0, t.screens.active.cursor.hyperlink_id);
}
test "Terminal: fullReset with a non-empty saved cursor" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    try t.setAttribute(.{ .direct_color_fg = .{ .r = 0xFF, .g = 0, .b = 0x7F } });
    try t.setAttribute(.{ .direct_color_bg = .{ .r = 0xFF, .g = 0, .b = 0x7F } });
    t.saveCursor();
    t.fullReset();
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.style_id == 0);
    }
    try testing.expectEqual(@as(style.Id, 0), t.screens.active.cursor.style_id);
}
test "Terminal: fullReset origin mode" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    t.setCursorPos(3, 5);
    t.modes.set(.origin, true);
    t.fullReset();
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expect(!t.modes.get(.origin));
}
test "Terminal: fullReset status display" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    t.status_display = .status_line;
    t.fullReset();
    try testing.expect(t.status_display == .main);
}
test "Terminal: fullReset preserves kitty graphics limits" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const alloc = testing.allocator;
    const temp_dir = "/tmp/wasp-kitty-images";
    var t = try init(testing.io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    t.setKittyGraphicsLoadingLimits(.allWithTempDir(temp_dir));
    for ([_]usize{ 1234, 0 }) |total_limit| {
        t.setKittyGraphicsSizeLimit(alloc, total_limit);
        t.fullReset();
        const storage = &t.screens.active.kitty_images;
        try testing.expectEqual(total_limit, storage.total_limit);
        try testing.expect(storage.image_limits.file);
        try testing.expect(storage.image_limits.shared_memory);
        switch (storage.image_limits.temporary_file) {
            .enabled => |value| try testing.expectEqualStrings(
                temp_dir,
                value.directory,
            ),
            .disabled => return error.TestUnexpectedResult,
        }
    }
}
test "Terminal: fullReset clears alt screen kitty keyboard state" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    try t.switchScreenMode(.@"1049", true);
    t.screens.active.kitty_keyboard.push(.{
        .disambiguate = true,
        .report_events = false,
        .report_alternates = true,
        .report_all = true,
        .report_associated = true,
    });
    try t.switchScreenMode(.@"1049", false);
    t.fullReset();
    try testing.expect(t.screens.get(.alternate) == null);
}
test "Terminal: fullReset default modes" {
    var t = try init(testing.io, testing.allocator, .{
        .cols = 10,
        .rows = 10,
        .default_modes = .{ .grapheme_cluster = true },
    });
    defer t.deinit(testing.allocator);
    try testing.expect(t.modes.get(.grapheme_cluster));
    t.fullReset();
    try testing.expect(t.modes.get(.grapheme_cluster));
}
test "Terminal: fullReset tracked pins" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);
    const p = try t.screens.active.pages.trackPin(t.screens.active.cursor.page_pin.*);
    t.fullReset();
    try testing.expect(t.screens.active.pages.pinIsValid(p.*));
}
test "Terminal: default xt checksum survives resets" {
    var t = try init(testing.io, testing.allocator, .{
        .cols = 10,
        .rows = 10,
        .default_xt_checksum = .{ .positive = true },
    });
    defer t.deinit(testing.allocator);
    try testing.expectEqual(xt_checksum.Flags{ .positive = true }, t.flags.xt_checksum);
    t.flags.xt_checksum = .{ .full = true };
    t.fullReset();
    try testing.expectEqual(xt_checksum.Flags{ .positive = true }, t.flags.xt_checksum);
    t.setDefaultXtChecksum(.{ .no_trim = true });
    try testing.expectEqual(xt_checksum.Flags{ .no_trim = true }, t.flags.xt_checksum);
    t.fullReset();
    try testing.expectEqual(xt_checksum.Flags{ .no_trim = true }, t.flags.xt_checksum);
    t.flags.xt_checksum = .{ .full = true };
    t.softReset();
    try testing.expectEqual(xt_checksum.Flags{ .no_trim = true }, t.flags.xt_checksum);
}
test "Terminal: softReset modes" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    t.modes.set(.insert, true);
    t.modes.set(.origin, true);
    t.modes.set(.wraparound, false);
    t.modes.set(.reverse_wrap, true);
    t.modes.set(.cursor_visible, false);
    t.modes.set(.cursor_keys, true);
    t.modes.set(.keypad_keys, true);
    t.modes.set(.bracketed_paste, true);
    t.softReset();
    try testing.expect(!t.modes.get(.insert));
    try testing.expect(!t.modes.get(.origin));
    try testing.expect(t.modes.get(.wraparound));
    try testing.expect(!t.modes.get(.reverse_wrap));
    try testing.expect(t.modes.get(.cursor_visible));
    try testing.expect(!t.modes.get(.cursor_keys));
    try testing.expect(!t.modes.get(.keypad_keys));
    try testing.expect(t.modes.get(.bracketed_paste));
}
test "Terminal: softReset margins" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    t.setTopAndBottomMargin(3, 4);
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(5, 6);
    t.softReset();
    try testing.expect(!t.modes.get(.enable_left_and_right_margin));
    try testing.expectEqual(ScrollingRegion{
        .top = 0,
        .bottom = 9,
        .left = 0,
        .right = 9,
    }, t.scrolling_region);
}
test "Terminal: softReset keeps the cursor and screen" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    try t.printString("hello");
    t.setCursorPos(6, 5);
    t.softReset();
    try testing.expectEqual(4, t.screens.active.cursor.x);
    try testing.expectEqual(5, t.screens.active.cursor.y);
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("hello", str);
}
test "Terminal: softReset saved cursor" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    t.setCursorPos(6, 5);
    try t.setAttribute(.bold);
    t.saveCursor();
    t.softReset();
    t.restoreCursor();
    try testing.expectEqual(0, t.screens.active.cursor.x);
    try testing.expectEqual(0, t.screens.active.cursor.y);
    try testing.expect(!t.screens.active.cursor.style.flags.bold);
}
test "Terminal: softReset pen, protection, and charsets" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    try t.setAttribute(.bold);
    t.setProtectedMode(.dec);
    t.configureCharset(.G0, .dec_special);
    t.softReset();
    try testing.expectEqual(@as(style.Id, 0), t.screens.active.cursor.style_id);
    try testing.expect(!t.screens.active.cursor.protected);
    try testing.expectEqual(charsets.Charset.utf8, t.screens.active.charset.charsets.get(.G0));
}
test "Terminal: softReset ends ISO protection for erase" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    t.setProtectedMode(.iso);
    try t.print('A');
    t.setProtectedMode(.off);
    t.softReset();
    t.eraseDisplay(.complete, false);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}
test "Terminal: softReset status display and checksum" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    t.status_display = .status_line;
    t.flags.xt_checksum = .{ .positive = true };
    t.softReset();
    try testing.expectEqual(.main, t.status_display);
    try testing.expectEqual(xt_checksum.Flags{}, t.flags.xt_checksum);
}
test "Terminal: softReset palette" {
    var t = try init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);
    t.softReset();
    try testing.expect(!t.flags.dirty.palette);
    const red: color.RGB = .{ .r = 0xff, .g = 0, .b = 0 };
    t.colors.palette.set(1, red);
    t.colors.palette.set(200, red);
    t.softReset();
    try testing.expect(t.flags.dirty.palette);
    try testing.expectEqual(0, t.colors.palette.mask.count());
    try testing.expectEqual(color.default[1], t.colors.palette.current[1]);
    try testing.expectEqual(color.default[200], t.colors.palette.current[200]);
}
test "Terminal: resize less cols with wide char then print" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);
    try t.print('x');
    try t.print('😀');
    try t.resize(alloc, .{ .cols = 2, .rows = 3 });
    t.setCursorPos(1, 2);
    try t.print('😀');
}
test "Terminal: resize less cols without reflow cutting wide char tail" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 3, .rows = 1 });
    defer t.deinit(alloc);
    try t.print('a');
    try t.print('一');
    t.modes.set(.wraparound, false);
    try t.resize(alloc, .{ .cols = 2, .rows = 1 });
    try testing.expect(t.screens.active.pages.getCell(.{ .active = .{ .x = 1 } }).?.cell.isEmpty());
}
test "Terminal: resize with left and right margin set" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    const cols = 70;
    const rows = 23;
    var t = try init(io_impl, alloc, .{ .cols = cols, .rows = rows });
    defer t.deinit(alloc);
    t.modes.set(.enable_left_and_right_margin, true);
    try t.print('0');
    t.modes.set(.enable_mode_3, true);
    try t.resize(alloc, .{ .cols = cols, .rows = rows });
    t.setLeftAndRightMargin(2, 0);
    try t.printRepeat(1850);
    _ = t.modes.restore(.enable_mode_3);
    try t.resize(alloc, .{ .cols = cols, .rows = rows });
}
test "Terminal: resize without scrollback pull" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);
    t.flags.resize_pull_scrollback = false;
    t.fullReset();
    try testing.expect(!t.flags.resize_pull_scrollback);
    try t.printString("1\n2\n3\n4\n5");
    try t.resize(alloc, .{ .cols = 5, .rows = 5 });
    try testing.expectEqual(@as(size.CellCountInt, 2), t.screens.active.cursor.y);
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("3\n4\n5", str);
    }
}
test "Terminal: resize with wraparound off" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    const cols = 4;
    const rows = 2;
    var t = try init(io_impl, alloc, .{ .cols = cols, .rows = rows });
    defer t.deinit(alloc);
    t.modes.set(.wraparound, false);
    try t.print('0');
    try t.print('1');
    try t.print('2');
    try t.print('3');
    const new_cols = 2;
    try t.resize(alloc, .{ .cols = new_cols, .rows = rows });
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("01", str);
}
test "Terminal: resize with wraparound on" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    const cols = 4;
    const rows = 2;
    var t = try init(io_impl, alloc, .{ .cols = cols, .rows = rows });
    defer t.deinit(alloc);
    t.modes.set(.wraparound, true);
    try t.print('0');
    try t.print('1');
    try t.print('2');
    try t.print('3');
    const new_cols = 2;
    try t.resize(alloc, .{ .cols = new_cols, .rows = rows });
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("01\n23", str);
}
test "Terminal: resize with high unique style per cell" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 30, .rows = 30 });
    defer t.deinit(alloc);
    for (0..t.rows) |y| {
        for (0..t.cols) |x| {
            t.setCursorPos(y, x);
            try t.setAttribute(.{ .direct_color_bg = .{
                .r = @intCast(x),
                .g = @intCast(y),
                .b = 0,
            } });
            try t.print('x');
        }
    }
    try t.resize(alloc, .{ .cols = 60, .rows = 30 });
}
test "Terminal: resize with high unique style per cell with wrapping" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 30, .rows = 30 });
    defer t.deinit(alloc);
    const cell_count: u16 = @intCast(t.rows * t.cols);
    for (0..cell_count) |i| {
        const r: u8 = @intCast(i >> 8);
        const g: u8 = @intCast(i & 0xFF);
        try t.setAttribute(.{ .direct_color_bg = .{
            .r = r,
            .g = g,
            .b = 0,
        } });
        try t.print('x');
    }
    try t.resize(alloc, .{ .cols = 60, .rows = 30 });
}
test "Terminal: resize with reflow and saved cursor" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 3 });
    defer t.deinit(alloc);
    try t.printString("1A2B");
    t.setCursorPos(2, 2);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u32, 'B'), cell.content.codepoint.data);
    }
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1A\n2B", str);
    }
    t.saveCursor();
    try t.resize(alloc, .{ .cols = 5, .rows = 3 });
    t.restoreCursor();
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1A2B", str);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u32, 'B'), cell.content.codepoint.data);
    }
}
test "Terminal: resize with reflow and saved cursor pending wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 2, .rows = 3 });
    defer t.deinit(alloc);
    try t.printString("1A2B");
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u32, 'B'), cell.content.codepoint.data);
    }
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1A\n2B", str);
    }
    t.saveCursor();
    try t.resize(alloc, .{ .cols = 5, .rows = 3 });
    t.restoreCursor();
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1A2B", str);
    }
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1A2BX", str);
    }
}
test "Terminal: saved cursor survives repeated widening" {
    const alloc = testing.allocator;
    var t = try init(testing.io, alloc, .{ .cols = 4, .rows = 5 });
    defer t.deinit(alloc);
    try t.printString("abc\nAAA|");
    t.saveCursor();
    try t.resize(alloc, .{ .cols = 5, .rows = 5 });
    try t.resize(alloc, .{ .cols = 6, .rows = 5 });
    t.restoreCursor();
    try t.print('X');
    const str = try t.plainString(alloc);
    defer alloc.free(str);
    try testing.expectEqualStrings("abc\nAAA|X", str);
}
test "Terminal: resize pending wrap live and saved cursors" {
    const alloc = testing.allocator;
    const cases = [_]struct {
        text: []const u8,
        cols: size.CellCountInt,
        pending_wrap: bool,
        expected: []const u8,
    }{
        .{ .text = "ABCD", .cols = 6, .pending_wrap = false, .expected = "ABCDX" },
        .{ .text = "ABCD", .cols = 3, .pending_wrap = false, .expected = "ABC\nDX" },
        .{ .text = "ABCD", .cols = 2, .pending_wrap = true, .expected = "AB\nCD\nX" },
        .{ .text = "ABCD", .cols = 4, .pending_wrap = true, .expected = "ABCD\nX" },
        .{ .text = "ABCDEFGH", .cols = 6, .pending_wrap = false, .expected = "ABCDEF\nGHX" },
        .{ .text = "AB界", .cols = 6, .pending_wrap = false, .expected = "AB界X" },
        .{ .text = "ABC", .cols = 6, .pending_wrap = false, .expected = "ABCX" },
    };
    for (cases) |case| {
        for ([_]bool{ false, true }) |restore| {
            var t = try init(testing.io, alloc, .{ .cols = 4, .rows = 5 });
            defer t.deinit(alloc);
            try t.printString(case.text);
            if (restore) t.saveCursor();
            try t.resize(alloc, .{ .cols = case.cols, .rows = 6 });
            if (restore) t.restoreCursor();
            try testing.expectEqual(case.pending_wrap, t.screens.active.cursor.pending_wrap);
            try t.print('X');
            const str = try t.plainString(alloc);
            defer alloc.free(str);
            try testing.expectEqualStrings(case.expected, str);
        }
    }
}
test "Terminal: DECCOLM without DEC mode 40" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.@"132_column", true);
    try t.deccolm(alloc, .@"132_cols");
    try testing.expectEqual(@as(usize, 5), t.cols);
    try testing.expectEqual(@as(usize, 5), t.rows);
    try testing.expect(!t.modes.get(.@"132_column"));
}
test "Terminal: DECCOLM unset" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.enable_mode_3, true);
    try t.deccolm(alloc, .@"80_cols");
    try testing.expectEqual(@as(usize, 80), t.cols);
    try testing.expectEqual(@as(usize, 5), t.rows);
}
test "Terminal: DECCOLM resets pending wrap" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.modes.set(.enable_mode_3, true);
    try t.deccolm(alloc, .@"80_cols");
    try testing.expectEqual(@as(usize, 80), t.cols);
    try testing.expectEqual(@as(usize, 5), t.rows);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
}
test "Terminal: DECCOLM preserves SGR bg" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.modes.set(.enable_mode_3, true);
    try t.deccolm(alloc, .@"80_cols");
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 0xFF,
            .g = 0,
            .b = 0,
        }, list_cell.cell.content.color_rgb);
    }
}
test "Terminal: DECCOLM resets scroll region" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.enable_left_and_right_margin, true);
    t.setTopAndBottomMargin(2, 3);
    t.setLeftAndRightMargin(3, 5);
    t.modes.set(.enable_mode_3, true);
    try t.deccolm(alloc, .@"80_cols");
    try testing.expect(t.modes.get(.enable_left_and_right_margin));
    try testing.expectEqual(@as(usize, 0), t.scrolling_region.top);
    try testing.expectEqual(@as(usize, 4), t.scrolling_region.bottom);
    try testing.expectEqual(@as(usize, 0), t.scrolling_region.left);
    try testing.expectEqual(@as(usize, 79), t.scrolling_region.right);
}
test "Terminal: mode 47 alt screen plain" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("1A");
    try t.switchScreenMode(.@"47", true);
    try testing.expectEqual(.alternate, t.screens.active_key);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
    try t.printString("2B");
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  2B", str);
    }
    try t.switchScreenMode(.@"47", false);
    try testing.expectEqual(.primary, t.screens.active_key);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1A", str);
    }
    try t.switchScreenMode(.@"47", true);
    try testing.expectEqual(.alternate, t.screens.active_key);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  2B", str);
    }
}
test "Terminal: mode 47 copies cursor both directions" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.setAttribute(.{ .direct_color_fg = .{ .r = 0xFF, .g = 0, .b = 0x7F } });
    try t.switchScreenMode(.@"47", true);
    try testing.expectEqual(.alternate, t.screens.active_key);
    {
        try testing.expect(t.screens.active.cursor.style_id != style.default_id);
        const page = t.screens.active.cursor.page_pin.node.page();
        try testing.expectEqual(@as(usize, 1), page.styles.count());
        try testing.expect(page.styles.refCount(page.memory, t.screens.active.cursor.style_id) > 0);
    }
    try t.setAttribute(.{ .direct_color_fg = .{ .r = 0, .g = 0xFF, .b = 0 } });
    try t.switchScreenMode(.@"47", false);
    try testing.expectEqual(.primary, t.screens.active_key);
    {
        try testing.expect(t.screens.active.cursor.style_id != style.default_id);
        const page = t.screens.active.cursor.page_pin.node.page();
        try testing.expectEqual(@as(usize, 1), page.styles.count());
        try testing.expect(page.styles.refCount(page.memory, t.screens.active.cursor.style_id) > 0);
    }
}
test "Terminal: mode 1047 alt screen plain" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("1A");
    try t.switchScreenMode(.@"1047", true);
    try testing.expectEqual(.alternate, t.screens.active_key);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
    try t.printString("2B");
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  2B", str);
    }
    try t.switchScreenMode(.@"1047", false);
    try testing.expectEqual(.primary, t.screens.active_key);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1A", str);
    }
    try t.switchScreenMode(.@"1047", true);
    try testing.expectEqual(.alternate, t.screens.active_key);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}
test "Terminal: mode 1047 copies cursor both directions" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.setAttribute(.{ .direct_color_fg = .{ .r = 0xFF, .g = 0, .b = 0x7F } });
    try t.switchScreenMode(.@"1047", true);
    try testing.expectEqual(.alternate, t.screens.active_key);
    {
        try testing.expect(t.screens.active.cursor.style_id != style.default_id);
        const page = t.screens.active.cursor.page_pin.node.page();
        try testing.expectEqual(@as(usize, 1), page.styles.count());
        try testing.expect(page.styles.refCount(page.memory, t.screens.active.cursor.style_id) > 0);
    }
    try t.setAttribute(.{ .direct_color_fg = .{ .r = 0, .g = 0xFF, .b = 0 } });
    try t.switchScreenMode(.@"1047", false);
    try testing.expectEqual(.primary, t.screens.active_key);
    {
        try testing.expect(t.screens.active.cursor.style_id != style.default_id);
        const page = t.screens.active.cursor.page_pin.node.page();
        try testing.expectEqual(@as(usize, 1), page.styles.count());
        try testing.expect(page.styles.refCount(page.memory, t.screens.active.cursor.style_id) > 0);
    }
}
test "Terminal: mode 1049 alt screen plain" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    try t.printString("1A");
    try t.switchScreenMode(.@"1049", true);
    try testing.expectEqual(.alternate, t.screens.active_key);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
    try t.printString("2B");
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  2B", str);
    }
    try t.switchScreenMode(.@"1049", false);
    try testing.expectEqual(.primary, t.screens.active_key);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1A", str);
    }
    try t.printString("C");
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1AC", str);
    }
    try t.switchScreenMode(.@"1049", true);
    try testing.expectEqual(.alternate, t.screens.active_key);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}
test "Terminal: deleteLines wide char at right margin with full clear" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);
    t.setCursorPos(10, 39);
    try t.print(0x4E2D);
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(5, 39);
    try t.scrollUp(t.rows);
}
test "Terminal: glyph APC stores session glossary entries" {
    if (comptime !build_options.glyph_protocol) return error.SkipZigTest;
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);
    var register_parser = glyph.CommandParser.init(alloc, 1024 * 1024);
    defer register_parser.deinit();
    for ("r;cp=e0a0;AAAAAAAAAAAAAA==") |byte| try register_parser.feed(byte);
    var register_req = try register_parser.complete(alloc);
    defer register_req.deinit(alloc);
    try testing.expectEqual(glyph.Response{
        .register = .{ .cp = 0xE0A0 },
    }, t.glyphProtocol(alloc, &register_req).?);
    try testing.expect(t.glyph_glossary.contains(0xE0A0));
    try testing.expect(t.flags.dirty.glyph_glossary);
    var query_parser = glyph.CommandParser.init(alloc, 1024 * 1024);
    defer query_parser.deinit();
    for ("q;cp=e0a0") |byte| try query_parser.feed(byte);
    var query_req = try query_parser.complete(alloc);
    defer query_req.deinit(alloc);
    try testing.expectEqual(glyph.Response{ .query = .{
        .cp = 0xE0A0,
        .status = .{ .glossary = true },
    } }, t.glyphProtocol(alloc, &query_req).?);
    t.fullReset();
    try testing.expect(!t.glyph_glossary.contains(0xE0A0));
}
test "Terminal: scroll region linefeed recycled row has default metadata" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 5 });
    defer t.deinit(alloc);
    for (0..12) |_| try t.print('A');
    t.screens.active.pages.getCell(
        .{ .active = .{ .y = 1 } },
    ).?.row.semantic_prompt = .prompt;
    t.setTopAndBottomMargin(2, 4);
    t.setCursorPos(4, 1);
    try t.linefeed();
    {
        const rac = t.screens.active.pages.getCell(.{ .active = .{ .y = 3 } }).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
}
test "Terminal: alt screen scroll up recycled row has default metadata" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);
    try t.switchScreenMode(.@"1049", true);
    for (0..7) |_| try t.print('A');
    t.screens.active.pages.getCell(
        .{ .active = .{} },
    ).?.row.semantic_prompt = .prompt;
    try t.scrollUp(1);
    {
        const rac = t.screens.active.pages.getCell(.{ .active = .{ .y = 2 } }).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
}
test "Terminal: insertLines count over region blanks row metadata" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 5 });
    defer t.deinit(alloc);
    for (0..12) |_| try t.print('A');
    t.screens.active.pages.getCell(
        .{ .active = .{ .y = 1 } },
    ).?.row.semantic_prompt = .prompt;
    t.setCursorPos(2, 1);
    t.insertLines(10);
    for (1..5) |y| {
        const rac = t.screens.active.pages.getCell(
            .{ .active = .{ .y = @intCast(y) } },
        ).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
}
test "Terminal: deleteLines count over region blanks row metadata" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 5 });
    defer t.deinit(alloc);
    for (0..12) |_| try t.print('A');
    t.screens.active.pages.getCell(
        .{ .active = .{ .y = 1 } },
    ).?.row.semantic_prompt = .prompt;
    t.setCursorPos(2, 1);
    t.deleteLines(10);
    for (1..5) |y| {
        const rac = t.screens.active.pages.getCell(
            .{ .active = .{ .y = @intCast(y) } },
        ).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
}
test "Terminal: deleteLines blank row does not retain semantic prompt" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);
    try t.print('$');
    t.screens.active.pages.getCell(
        .{ .active = .{} },
    ).?.row.semantic_prompt = .prompt;
    t.setCursorPos(1, 1);
    t.deleteLines(1);
    {
        const rac = t.screens.active.pages.getCell(.{ .active = .{ .y = 2 } }).?;
        try testing.expect(!rac.row.wrap);
        try testing.expect(!rac.row.wrap_continuation);
        try testing.expectEqual(.none, rac.row.semantic_prompt);
    }
}
test "Terminal: eraseDisplay complete ignores stale prompt on recycled row" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    try t.printString("hello");
    t.screens.active.pages.getCell(
        .{ .active = .{ .y = 1 } },
    ).?.row.semantic_prompt = .prompt;
    t.setTopAndBottomMargin(2, 3);
    t.setCursorPos(3, 1);
    try t.linefeed();
    t.setTopAndBottomMargin(0, 0);
    t.eraseDisplay(.complete, false);
    try testing.expectEqual(t.screens.active.pages.rows, t.screens.active.pages.total_rows);
}
test "Terminal: eraseDisplay complete at prompt not on last row scrolls" {
    const alloc = testing.allocator;
    const io_impl = testing.io;
    var t = try init(io_impl, alloc, .{ .cols = 10, .rows = 15 });
    defer t.deinit(alloc);
    for (0..10) |_| {
        try t.printString("x");
        t.carriageReturn();
        try t.linefeed();
    }
    try t.semanticPrompt(.init(.prompt_start));
    try t.printString("$ ");
    try t.semanticPrompt(.init(.end_prompt_start_input));
    t.setCursorPos(1, 1);
    t.eraseDisplay(.complete, false);
    try testing.expect(t.screens.active.pages.total_rows > t.screens.active.pages.rows);
}
