const std = @import("std");
const Allocator = std.mem.Allocator;
const font = @import("../main.zig");
const Face = font.Face;
const Collection = font.Collection;
const DeferredFace = font.DeferredFace;
const Group = font.Group;
const GroupCache = font.GroupCache;
const Library = font.Library;
const SharedGrid = font.SharedGrid;
const Style = font.Style;
const Presentation = font.Presentation;
const terminal = @import("../../terminal/main.zig");
const log = std.log.scoped(.font_shaper);
pub const Shaper = struct {
    alloc: Allocator,
    run_state: RunState,
    cell_buf: CellBuf,
    const CellBuf = std.ArrayListUnmanaged(font.shape.Cell);
    const CodepointList = std.ArrayListUnmanaged(Codepoint);
    const Codepoint = struct {
        codepoint: u32,
        cluster: u32,
    };
    const RunState = struct {
        codepoints: CodepointList = .{},
        fn deinit(self: *RunState, alloc: Allocator) void {
            self.codepoints.deinit(alloc);
        }
        fn reset(self: *RunState) !void {
            self.codepoints.clearRetainingCapacity();
        }
    };
    pub fn init(alloc: Allocator, opts: font.shape.Options) !Shaper {
        _ = opts;
        return Shaper{
            .alloc = alloc,
            .cell_buf = .{},
            .run_state = .{},
        };
    }
    pub fn deinit(self: *Shaper) void {
        self.cell_buf.deinit(self.alloc);
        self.run_state.deinit(self.alloc);
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
    pub fn shape(self: *Shaper, run: font.shape.TextRun) ![]const font.shape.Cell {
        const state = &self.run_state;
        if (run.font_index.special() != null) {
            self.cell_buf.clearRetainingCapacity();
            try self.cell_buf.ensureTotalCapacity(self.alloc, state.codepoints.items.len);
            for (state.codepoints.items) |entry| {
                self.cell_buf.appendAssumeCapacity(.{
                    .x = @intCast(entry.cluster),
                    .glyph_index = @intCast(entry.codepoint),
                });
            }
            return self.cell_buf.items;
        }
        self.cell_buf.clearRetainingCapacity();
        const face = try run.grid.resolver.collection.getFace(run.font_index);
        for (state.codepoints.items) |entry| {
            const glyph_index = face.glyphIndex(entry.codepoint) orelse {
                unreachable;
            };
            try self.cell_buf.append(self.alloc, .{
                .x = @intCast(entry.cluster),
                .glyph_index = glyph_index,
            });
        }
        return self.cell_buf.items;
    }
    pub const RunIteratorHook = struct {
        shaper: *Shaper,
        pub fn prepare(self: *RunIteratorHook) !void {
            try self.shaper.run_state.reset();
        }
        pub fn addCodepoint(self: RunIteratorHook, cp: u32, cluster: u32) !void {
            try self.shaper.run_state.codepoints.append(self.shaper.alloc, .{
                .codepoint = cp,
                .cluster = cluster,
            });
        }
        pub fn finalize(self: RunIteratorHook) !void {
            _ = self;
        }
    };
};
test {
    @import("std").testing.refAllDecls(@This());
}
