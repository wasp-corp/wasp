const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const font = @import("../main.zig");
const terminal = @import("../../terminal/main.zig");
const unicode = @import("../../unicode/root.zig");
const uucode = @import("uucode");
const log = std.log.scoped(.font_shaper);
pub const Shaper = struct {
    const RunBuf = std.MultiArrayList(struct {
        codepoint: u32,
        cluster: u32,
    });
    alloc: Allocator,
    cell_buf: []font.shape.Cell,
    run_buf: RunBuf,
    pub fn init(alloc: Allocator, opts: font.shape.Options) !Shaper {
        return Shaper{
            .alloc = alloc,
            .cell_buf = opts.cell_buf,
            .run_buf = .{},
        };
    }
    pub fn deinit(self: *Shaper) void {
        self.run_buf.deinit(self.alloc);
        self.* = undefined;
    }
    pub fn endFrame(self: *const Shaper) void {
        _ = self;
    }
    pub fn runIterator(
        self: *Shaper,
        opts: font.shape.RunOptions,
    ) font.shape.RunIterator {
        return .{
            .hooks = .{ .shaper = self },
            .opts = opts,
        };
    }
    pub fn shape(self: *Shaper, run: font.shape.TextRun) ![]font.shape.Cell {
        const codepoints = self.run_buf.items(.codepoint);
        const clusters = self.run_buf.items(.cluster);
        assert(codepoints.len == clusters.len);
        switch (codepoints.len) {
            0 => return self.cell_buf[0..0],
            1 => {
                self.cell_buf[0] = .{
                    .x = @intCast(clusters[0]),
                    .glyph_index = codepoints[0],
                };
                return self.cell_buf[0..1];
            },
            else => {},
        }
        var break_state: uucode.grapheme.BreakState = .default;
        var cp1: u21 = @intCast(codepoints[0]);
        var start: usize = 0;
        var i: usize = 1;
        var cur: usize = 0;
        while (i <= codepoints.len) : (i += 1) {
            const grapheme_break = i == codepoints.len or blk: {
                const cp2: u21 = @intCast(codepoints[i]);
                defer cp1 = cp2;
                break :blk unicode.graphemeBreak(
                    cp1,
                    cp2,
                    &break_state,
                );
            };
            if (!grapheme_break) continue;
            const len = i - start;
            assert(len > 0);
            switch (len) {
                1 => self.cell_buf[cur] = .{
                    .x = @intCast(clusters[start]),
                    .glyph_index = codepoints[start],
                },
                else => {
                    const cluster = cluster: {
                        const cluster_points = codepoints[start..i];
                        assert(cluster_points.len == len);
                        const buf_len = buf_len: {
                            var acc: usize = 0;
                            for (cluster_points) |cp| {
                                acc += try std.unicode.utf8CodepointSequenceLength(
                                    @intCast(cp),
                                );
                            }
                            break :buf_len acc;
                        };
                        var buf = try self.alloc.alloc(u8, buf_len);
                        errdefer self.alloc.free(buf);
                        var buf_i: usize = 0;
                        for (cluster_points) |cp| {
                            buf_i += try std.unicode.utf8Encode(
                                @intCast(cp),
                                buf[buf_i..],
                            );
                        }
                        break :cluster buf;
                    };
                    defer self.alloc.free(cluster);
                    var face = try run.group.group.faceFromIndex(run.font_index);
                    const index = try face.graphemeGlyphIndex(cluster);
                    self.cell_buf[cur] = .{
                        .x = @intCast(clusters[start]),
                        .glyph_index = index,
                    };
                },
            }
            start = i;
            cur += 1;
        }
        return self.cell_buf[0..cur];
    }
    pub const RunIteratorHook = struct {
        shaper: *Shaper,
        pub fn prepare(self: RunIteratorHook) !void {
            self.shaper.run_buf.shrinkRetainingCapacity(0);
        }
        pub fn addCodepoint(
            self: RunIteratorHook,
            cp: u32,
            cluster: u32,
        ) !void {
            try self.shaper.run_buf.append(self.shaper.alloc, .{
                .codepoint = cp,
                .cluster = cluster,
            });
        }
        pub fn finalize(self: RunIteratorHook) !void {
            _ = self;
        }
    };
};
pub const Wasm = struct {
    const wasm = @import("../../os/wasm.zig");
    const alloc = wasm.alloc;
    export fn shaper_new(cap: usize) ?*Shaper {
        return shaper_new_(cap) catch null;
    }
    fn shaper_new_(cap: usize) !*Shaper {
        const cell_buf = try alloc.alloc(font.shape.Cell, cap);
        errdefer alloc.free(cell_buf);
        var shaper = try Shaper.init(alloc, .{ .cell_buf = cell_buf });
        errdefer shaper.deinit();
        const result = try alloc.create(Shaper);
        errdefer alloc.destroy(result);
        result.* = shaper;
        return result;
    }
    export fn shaper_free(ptr: ?*Shaper) void {
        if (ptr) |v| {
            alloc.free(v.cell_buf);
            v.deinit();
            alloc.destroy(v);
        }
    }
    export fn shaper_test(
        self: *Shaper,
        group: *font.GroupCache,
        str: [*]const u8,
        len: usize,
    ) void {
        shaper_test_(self, group, str[0..len]) catch |err| {
            log.warn("error during shaper test err={}", .{err});
        };
    }
    fn shaper_test_(self: *Shaper, group: *font.GroupCache, str: []const u8) !void {
        var term = try terminal.Terminal.init(alloc, self.cell_buf.len, 80);
        defer term.deinit(alloc);
        {
            const view = try std.unicode.Utf8View.init(str);
            var iter = view.iterator();
            while (iter.nextCodepoint()) |c| {
                try term.print(c);
            }
        }
        var rowIter = term.screen.rowIterator(.viewport);
        var y: usize = 0;
        while (rowIter.next()) |row| {
            defer y += 1;
            var iter = self.runIterator(group, row, null, null);
            while (try iter.next(alloc)) |run| {
                const cells = try self.shape(run);
                log.info("y={} run={d} shape={any} idx={}", .{
                    y,
                    run.cells,
                    cells,
                    run.font_index,
                });
            }
        }
    }
};
