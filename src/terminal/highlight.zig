const std = @import("std");
const Allocator = std.mem.Allocator;
const size = @import("size.zig");
const PageList = @import("PageList.zig");
const PageChunk = PageList.PageIterator.Chunk;
const Pin = PageList.Pin;
const Screen = @import("Screen.zig");
pub const Untracked = struct {
    start: Pin,
    end: Pin,
    pub fn track(
        self: *const Untracked,
        screen: *Screen,
    ) Allocator.Error!Tracked {
        return try .init(
            screen,
            self.start,
            self.end,
        );
    }
    pub fn eql(self: Untracked, other: Untracked) bool {
        return self.start.eql(other.start) and self.end.eql(other.end);
    }
};
pub const Tracked = struct {
    start: *Pin,
    end: *Pin,
    pub fn init(
        screen: *Screen,
        start: Pin,
        end: Pin,
    ) Allocator.Error!Tracked {
        const start_tracked = try screen.pages.trackPin(start);
        errdefer screen.pages.untrackPin(start_tracked);
        const end_tracked = try screen.pages.trackPin(end);
        errdefer screen.pages.untrackPin(end_tracked);
        return .{
            .start = start_tracked,
            .end = end_tracked,
        };
    }
    pub fn initAssume(
        start: *Pin,
        end: *Pin,
    ) Tracked {
        return .{
            .start = start,
            .end = end,
        };
    }
    pub fn deinit(
        self: Tracked,
        screen: *Screen,
    ) void {
        screen.pages.untrackPin(self.start);
        screen.pages.untrackPin(self.end);
    }
};
pub const Flattened = struct {
    chunks: std.MultiArrayList(Chunk),
    top_x: size.CellCountInt,
    bot_x: size.CellCountInt,
    pub const Chunk = struct {
        node: *PageList.List.Node,
        serial: u64,
        start: size.CellCountInt,
        end: size.CellCountInt,
    };
    pub const empty: Flattened = .{
        .chunks = .empty,
        .top_x = 0,
        .bot_x = 0,
    };
    pub fn init(
        alloc: Allocator,
        start: Pin,
        end: Pin,
    ) Allocator.Error!Flattened {
        var result: std.MultiArrayList(PageChunk) = .empty;
        errdefer result.deinit(alloc);
        var it = start.pageIterator(.right_down, end);
        while (it.next()) |chunk| try result.append(alloc, .{
            .node = chunk.node,
            .serial = chunk.node.serial,
            .start = chunk.start,
            .end = chunk.end,
        });
        return .{
            .chunks = result,
            .top_x = start.x,
            .end_x = end.x,
        };
    }
    pub fn deinit(self: *Flattened, alloc: Allocator) void {
        self.chunks.deinit(alloc);
    }
    pub fn clone(self: *const Flattened, alloc: Allocator) Allocator.Error!Flattened {
        return .{
            .chunks = try self.chunks.clone(alloc),
            .top_x = self.top_x,
            .bot_x = self.bot_x,
        };
    }
    pub fn startPin(self: Flattened) Pin {
        const slice = self.chunks.slice();
        return .{
            .node = slice.items(.node)[0],
            .x = self.top_x,
            .y = slice.items(.start)[0],
        };
    }
    pub fn endPin(self: Flattened) Pin {
        const slice = self.chunks.slice();
        return .{
            .node = slice.items(.node)[slice.len - 1],
            .x = self.bot_x,
            .y = slice.items(.end)[slice.len - 1] - 1,
        };
    }
    pub fn untracked(self: Flattened) Untracked {
        const slice = self.chunks.slice();
        const nodes = slice.items(.node);
        const starts = slice.items(.start);
        const ends = slice.items(.end);
        return .{
            .start = .{
                .node = nodes[0],
                .x = self.top_x,
                .y = starts[0],
            },
            .end = .{
                .node = nodes[nodes.len - 1],
                .x = self.bot_x,
                .y = ends[ends.len - 1] - 1,
            },
        };
    }
};
