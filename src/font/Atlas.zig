const Atlas = @This();
const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const fastmem = @import("../fastmem.zig");
const tripwire = @import("../tripwire.zig");
const log = std.log.scoped(.atlas);
data: []u8,
size: u32 = 0,
nodes: std.ArrayList(Node) = .empty,
format: Format = .grayscale,
modified: std.atomic.Value(usize) = .{ .raw = 0 },
resized: std.atomic.Value(usize) = .{ .raw = 0 },
pub const Format = enum(u8) {
    grayscale = 0,
    bgr = 1,
    bgra = 2,
    pub fn depth(self: Format) u8 {
        return switch (self) {
            .grayscale => 1,
            .bgr => 3,
            .bgra => 4,
        };
    }
};
const Node = struct {
    x: u32,
    y: u32,
    width: u32,
};
pub const Error = error{
    AtlasFull,
};
pub const Region = extern struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};
const node_prealloc: usize = 64;
pub const init_tw = tripwire.module(enum {
    alloc_data,
    alloc_nodes,
}, init);
pub fn init(alloc: Allocator, size: u32, format: Format) Allocator.Error!Atlas {
    const tw = init_tw;
    try tw.check(.alloc_data);
    var result = Atlas{
        .data = try alloc.alloc(u8, size * size * format.depth()),
        .size = size,
        .nodes = .empty,
        .format = format,
    };
    errdefer result.deinit(alloc);
    try tw.check(.alloc_nodes);
    result.nodes = try .initCapacity(alloc, node_prealloc);
    result.clear();
    return result;
}
pub fn deinit(self: *Atlas, alloc: Allocator) void {
    self.nodes.deinit(alloc);
    alloc.free(self.data);
    self.* = undefined;
}
pub const reserve_tw = tripwire.module(enum {
    insert_node,
}, reserve);
pub fn reserve(
    self: *Atlas,
    alloc: Allocator,
    width: u32,
    height: u32,
) (Allocator.Error || Error)!Region {
    const tw = reserve_tw;
    var region: Region = .{ .x = 0, .y = 0, .width = width, .height = height };
    if (width == 0 and height == 0) return region;
    const best_idx: usize = best_idx: {
        var best_height: u32 = std.math.maxInt(u32);
        var best_width: u32 = best_height;
        var chosen: ?usize = null;
        var i: usize = 0;
        while (i < self.nodes.items.len) : (i += 1) {
            const y = self.fit(i, width, height) orelse continue;
            const node = self.nodes.items[i];
            if ((y + height) < best_height or
                ((y + height) == best_height and
                    (node.width > 0 and node.width < best_width)))
            {
                chosen = i;
                best_width = node.width;
                best_height = y + height;
                region.x = node.x;
                region.y = y;
            }
        }
        break :best_idx chosen orelse return Error.AtlasFull;
    };
    try tw.check(.insert_node);
    try self.nodes.insert(alloc, best_idx, .{
        .x = region.x,
        .y = region.y + height,
        .width = width,
    });
    errdefer comptime unreachable;
    var i: usize = best_idx + 1;
    while (i < self.nodes.items.len) : (i += 1) {
        const node = &self.nodes.items[i];
        const prev = self.nodes.items[i - 1];
        if (node.x < (prev.x + prev.width)) {
            const shrink = prev.x + prev.width - node.x;
            node.x += shrink;
            node.width -|= shrink;
            if (node.width <= 0) {
                _ = self.nodes.orderedRemove(i);
                i -= 1;
                continue;
            }
        }
        break;
    }
    self.merge();
    return region;
}
fn fit(self: Atlas, idx: usize, width: u32, height: u32) ?u32 {
    const node = self.nodes.items[idx];
    if ((node.x + width) > (self.size - 1)) return null;
    var y = node.y;
    var i = idx;
    var width_left = width;
    while (width_left > 0) : (i += 1) {
        const n = self.nodes.items[i];
        if (n.y > y) y = n.y;
        if ((y + height) > (self.size - 1)) return null;
        width_left -|= n.width;
    }
    return y;
}
fn merge(self: *Atlas) void {
    var i: usize = 0;
    while (i < self.nodes.items.len - 1) {
        const node = &self.nodes.items[i];
        const next = self.nodes.items[i + 1];
        if (node.y == next.y) {
            node.width += next.width;
            _ = self.nodes.orderedRemove(i + 1);
            continue;
        }
        i += 1;
    }
}
pub fn set(self: *Atlas, reg: Region, data: []const u8) void {
    assert(reg.x < (self.size - 1));
    assert((reg.x + reg.width) <= (self.size - 1));
    assert(reg.y < (self.size - 1));
    assert((reg.y + reg.height) <= (self.size - 1));
    const depth = self.format.depth();
    var i: u32 = 0;
    while (i < reg.height) : (i += 1) {
        const tex_offset = (((reg.y + i) * self.size) + reg.x) * depth;
        const data_offset = i * reg.width * depth;
        fastmem.copy(
            u8,
            self.data[tex_offset..],
            data[data_offset .. data_offset + (reg.width * depth)],
        );
    }
    _ = self.modified.fetchAdd(1, .monotonic);
}
pub fn setFromLarger(
    self: *Atlas,
    reg: Region,
    src: []const u8,
    src_width: u32,
    src_x: u32,
    src_y: u32,
) void {
    assert(reg.x < (self.size - 1));
    assert((reg.x + reg.width) <= (self.size - 1));
    assert(reg.y < (self.size - 1));
    assert((reg.y + reg.height) <= (self.size - 1));
    const depth = self.format.depth();
    var i: u32 = 0;
    while (i < reg.height) : (i += 1) {
        const tex_offset = (((reg.y + i) * self.size) + reg.x) * depth;
        const src_offset = (((src_y + i) * src_width) + src_x) * depth;
        fastmem.copy(
            u8,
            self.data[tex_offset..],
            src[src_offset .. src_offset + (reg.width * depth)],
        );
    }
    _ = self.modified.fetchAdd(1, .monotonic);
}
pub const grow_tw = tripwire.module(enum {
    ensure_node_capacity,
    alloc_data,
}, grow);
pub fn grow(self: *Atlas, alloc: Allocator, size_new: u32) Allocator.Error!void {
    const tw = grow_tw;
    assert(size_new >= self.size);
    if (size_new == self.size) return;
    try tw.check(.ensure_node_capacity);
    try self.nodes.ensureUnusedCapacity(alloc, 1);
    try tw.check(.alloc_data);
    const data_new = try alloc.alloc(
        u8,
        size_new * size_new * self.format.depth(),
    );
    errdefer comptime unreachable;
    const data_old = self.data;
    const size_old = self.size;
    self.data = data_new;
    self.size = size_new;
    defer alloc.free(data_old);
    @memset(self.data, 0);
    self.set(.{
        .x = 0, 
        .y = 1, 
        .width = size_old,
        .height = size_old - 2, 
    }, data_old[size_old * self.format.depth() ..]);
    self.nodes.appendAssumeCapacity(.{
        .x = size_old - 1,
        .y = 1,
        .width = size_new - size_old,
    });
    _ = self.modified.fetchAdd(1, .monotonic);
    _ = self.resized.fetchAdd(1, .monotonic);
}
pub fn clear(self: *Atlas) void {
    _ = self.modified.fetchAdd(1, .monotonic);
    @memset(self.data, 0);
    self.nodes.clearRetainingCapacity();
    self.nodes.appendAssumeCapacity(.{ .x = 1, .y = 1, .width = self.size - 2 });
}
pub fn dump(self: Atlas, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print(
        \\P{c}
        \\{d} {d}
        \\255
        \\
    , .{
        @as(u8, switch (self.format) {
            .grayscale => '5',
            .bgr => '6',
            else => {
                log.err("Unsupported format for dump: {}", .{self.format});
                @panic("Cannot dump this atlas format.");
            },
        }),
        self.size,
        self.size,
    });
    try writer.writeAll(self.data);
}
pub const Wasm = struct {
    const wasm = @import("../os/wasm.zig");
    const alloc = wasm.alloc;
    const js = @import("zig-js");
    export fn atlas_new(size: u32, format: u8) ?*Atlas {
        const atlas = init(
            alloc,
            size,
            @enumFromInt(format),
        ) catch return null;
        const result = alloc.create(Atlas) catch return null;
        result.* = atlas;
        return result;
    }
    export fn atlas_free(ptr: ?*Atlas) void {
        if (ptr) |v| {
            v.deinit(alloc);
            alloc.destroy(v);
        }
    }
    export fn atlas_reserve(self: *Atlas, width: u32, height: u32) ?*Region {
        return atlas_reserve_(self, width, height) catch return null;
    }
    fn atlas_reserve_(self: *Atlas, width: u32, height: u32) !*Region {
        const reg = try self.reserve(alloc, width, height);
        const result = try alloc.create(Region);
        errdefer alloc.destroy(result);
        _ = try wasm.toHostOwned(result);
        result.* = reg;
        return result;
    }
    export fn atlas_set(self: *Atlas, reg: *Region, data: [*]const u8, len: usize) void {
        self.set(reg.*, data[0..len]);
    }
    export fn atlas_grow(self: *Atlas, size_new: u32) bool {
        self.grow(alloc, size_new) catch return false;
        return true;
    }
    export fn atlas_clear(self: *Atlas) void {
        self.clear();
    }
    export fn atlas_debug_canvas(self: *Atlas) u32 {
        return atlas_debug_canvas_(self) catch |err| {
            log.warn("error dumping atlas canvas err={}", .{err});
            return 0;
        };
    }
    fn atlas_debug_canvas_(self: *Atlas) !u32 {
        const doc = try js.global.get(js.Object, "document");
        defer doc.deinit();
        const canvas = try doc.call(js.Object, "createElement", .{js.string("canvas")});
        errdefer canvas.deinit();
        {
            try canvas.set("width", self.size);
            try canvas.set("height", self.size);
            const width_str = try std.fmt.allocPrint(alloc, "{d}px", .{self.size});
            defer alloc.free(width_str);
            const style = try canvas.get(js.Object, "style");
            defer style.deinit();
            try style.set("width", js.string(width_str));
            try style.set("height", js.string(width_str));
        }
        const ctx = try canvas.call(js.Object, "getContext", .{js.string("2d")});
        defer ctx.deinit();
        const buf: []u8 = switch (self.format) {
            .bgra => buf: {
                var buf: []u8 = try alloc.dupe(u8, self.data);
                errdefer alloc.free(buf);
                var i: usize = 0;
                while (i < self.data.len) : (i += 4) {
                    std.mem.swap(u8, &buf[i], &buf[i + 2]);
                }
                break :buf buf;
            },
            .grayscale => buf: {
                var buf: []u8 = try alloc.alloc(u8, self.data.len * 4);
                errdefer alloc.free(buf);
                @memset(buf, 0);
                for (self.data, 0..) |value, i| {
                    buf[(i * 4) + 3] = value;
                }
                break :buf buf;
            },
            else => return error.UnsupportedAtlasFormat,
        };
        defer if (buf.ptr != self.data.ptr) alloc.free(buf);
        const image_data: js.Object = data: {
            const mem = try js.runtime.get(js.Object, "memory");
            defer mem.deinit();
            const mem_buf = try mem.get(js.Object, "buffer");
            defer mem_buf.deinit();
            const arr = arr: {
                const Uint8ClampedArray = try js.global.get(js.Object, "Uint8ClampedArray");
                defer Uint8ClampedArray.deinit();
                const arr = try Uint8ClampedArray.new(.{ mem_buf, buf.ptr, buf.len });
                if (!wasm.shared_mem) break :arr arr;
                defer arr.deinit();
                break :arr try arr.call(js.Object, "slice", .{});
            };
            defer arr.deinit();
            const ImageData = try js.global.get(js.Object, "ImageData");
            defer ImageData.deinit();
            const data = try ImageData.new(.{ arr, self.size, self.size });
            errdefer data.deinit();
            break :data data;
        };
        defer image_data.deinit();
        try ctx.call(void, "putImageData", .{ image_data, 0, 0 });
        const id = @as(js.Ref, @bitCast(@intFromEnum(canvas.value))).id;
        return id;
    }
    test "happy path" {
        const atlas = atlas_new(512, @intFromEnum(Format.grayscale)).?;
        defer atlas_free(atlas);
        const reg = atlas_reserve(atlas, 2, 2).?;
        defer alloc.destroy(reg);
        try testing.expect(wasm.isHostOwned(reg));
        defer wasm.toModuleOwned(reg);
        try testing.expect(reg.width > 0);
        const data = &[_]u8{ 1, 2, 3, 4 };
        try testing.expect(!atlas.modified);
        atlas_set(atlas, reg, data, data.len);
        try testing.expect(atlas.modified);
    }
};
test "exact fit" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 34, .grayscale); 
    defer atlas.deinit(alloc);
    const modified = atlas.modified.load(.monotonic);
    _ = try atlas.reserve(alloc, 32, 32);
    try testing.expectEqual(modified, atlas.modified.load(.monotonic));
    try testing.expectError(Error.AtlasFull, atlas.reserve(alloc, 1, 1));
}
test "doesn't fit" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 32, .grayscale);
    defer atlas.deinit(alloc);
    try testing.expectError(Error.AtlasFull, atlas.reserve(alloc, 32, 32));
}
test "fit multiple" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 32, .grayscale);
    defer atlas.deinit(alloc);
    _ = try atlas.reserve(alloc, 15, 30);
    _ = try atlas.reserve(alloc, 15, 30);
    try testing.expectError(Error.AtlasFull, atlas.reserve(alloc, 1, 1));
}
test "writing data" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 32, .grayscale);
    defer atlas.deinit(alloc);
    const reg = try atlas.reserve(alloc, 2, 2);
    const old = atlas.modified.load(.monotonic);
    atlas.set(reg, &[_]u8{ 1, 2, 3, 4 });
    const new = atlas.modified.load(.monotonic);
    try testing.expect(new > old);
    try testing.expectEqual(@as(u8, 1), atlas.data[33]);
    try testing.expectEqual(@as(u8, 2), atlas.data[34]);
    try testing.expectEqual(@as(u8, 3), atlas.data[65]);
    try testing.expectEqual(@as(u8, 4), atlas.data[66]);
}
test "writing data from a larger source" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 32, .grayscale);
    defer atlas.deinit(alloc);
    const reg = try atlas.reserve(alloc, 2, 2);
    const old = atlas.modified.load(.monotonic);
    atlas.setFromLarger(reg, &[_]u8{
        8, 8, 8, 8, 8,
        8, 8, 1, 2, 8,
        8, 8, 3, 4, 8,
        8, 8, 8, 8, 8,
    }, 5, 2, 1);
    const new = atlas.modified.load(.monotonic);
    try testing.expect(new > old);
    try testing.expectEqual(@as(u8, 1), atlas.data[33]);
    try testing.expectEqual(@as(u8, 2), atlas.data[34]);
    try testing.expectEqual(@as(u8, 3), atlas.data[65]);
    try testing.expectEqual(@as(u8, 4), atlas.data[66]);
    try testing.expectEqual(null, std.mem.indexOfScalar(u8, atlas.data, 8));
}
test "grow" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 4, .grayscale); 
    defer atlas.deinit(alloc);
    const reg = try atlas.reserve(alloc, 2, 2);
    try testing.expectError(Error.AtlasFull, atlas.reserve(alloc, 1, 1));
    atlas.set(reg, &[_]u8{ 1, 2, 3, 4 });
    try testing.expectEqual(@as(u8, 1), atlas.data[5]);
    try testing.expectEqual(@as(u8, 2), atlas.data[6]);
    try testing.expectEqual(@as(u8, 3), atlas.data[9]);
    try testing.expectEqual(@as(u8, 4), atlas.data[10]);
    const old_modified = atlas.modified.load(.monotonic);
    const old_resized = atlas.resized.load(.monotonic);
    try atlas.grow(alloc, atlas.size + 1);
    const new_modified = atlas.modified.load(.monotonic);
    const new_resized = atlas.resized.load(.monotonic);
    try testing.expect(new_modified > old_modified);
    try testing.expect(new_resized > old_resized);
    _ = try atlas.reserve(alloc, 1, 1);
    try testing.expectEqual(@as(u8, 1), atlas.data[atlas.size + 1]);
    try testing.expectEqual(@as(u8, 2), atlas.data[atlas.size + 2]);
    try testing.expectEqual(@as(u8, 3), atlas.data[atlas.size * 2 + 1]);
    try testing.expectEqual(@as(u8, 4), atlas.data[atlas.size * 2 + 2]);
}
test "writing BGR data" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 32, .bgr);
    defer atlas.deinit(alloc);
    const reg = try atlas.reserve(alloc, 1, 2);
    atlas.set(reg, &[_]u8{
        1, 2, 3,
        4, 5, 6,
    });
    const depth = @as(usize, @intCast(atlas.format.depth()));
    try testing.expectEqual(@as(u8, 1), atlas.data[33 * depth]);
    try testing.expectEqual(@as(u8, 2), atlas.data[33 * depth + 1]);
    try testing.expectEqual(@as(u8, 3), atlas.data[33 * depth + 2]);
    try testing.expectEqual(@as(u8, 4), atlas.data[65 * depth]);
    try testing.expectEqual(@as(u8, 5), atlas.data[65 * depth + 1]);
    try testing.expectEqual(@as(u8, 6), atlas.data[65 * depth + 2]);
}
test "grow BGR" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 4, .bgr);
    defer atlas.deinit(alloc);
    const reg = try atlas.reserve(alloc, 2, 2);
    try testing.expectError(Error.AtlasFull, atlas.reserve(alloc, 1, 1));
    atlas.set(reg, &[_]u8{
        10, 11, 12, 
        13, 14, 15, 
        20, 21, 22, 
        23, 24, 25, 
    });
    const depth = @as(usize, @intCast(atlas.format.depth()));
    var tl = (atlas.size * depth) + depth;
    try testing.expectEqual(@as(u8, 10), atlas.data[tl]);
    try testing.expectEqual(@as(u8, 11), atlas.data[tl + 1]);
    try testing.expectEqual(@as(u8, 12), atlas.data[tl + 2]);
    try testing.expectEqual(@as(u8, 13), atlas.data[tl + 3]);
    try testing.expectEqual(@as(u8, 14), atlas.data[tl + 4]);
    try testing.expectEqual(@as(u8, 15), atlas.data[tl + 5]);
    try testing.expectEqual(@as(u8, 0), atlas.data[tl + 6]); 
    tl += (atlas.size * depth); 
    try testing.expectEqual(@as(u8, 20), atlas.data[tl]);
    try testing.expectEqual(@as(u8, 21), atlas.data[tl + 1]);
    try testing.expectEqual(@as(u8, 22), atlas.data[tl + 2]);
    try testing.expectEqual(@as(u8, 23), atlas.data[tl + 3]);
    try testing.expectEqual(@as(u8, 24), atlas.data[tl + 4]);
    try testing.expectEqual(@as(u8, 25), atlas.data[tl + 5]);
    try testing.expectEqual(@as(u8, 0), atlas.data[tl + 6]); 
    try atlas.grow(alloc, atlas.size + 1);
    tl = (atlas.size * depth) + depth;
    try testing.expectEqual(@as(u8, 10), atlas.data[tl]);
    try testing.expectEqual(@as(u8, 11), atlas.data[tl + 1]);
    try testing.expectEqual(@as(u8, 12), atlas.data[tl + 2]);
    try testing.expectEqual(@as(u8, 13), atlas.data[tl + 3]);
    try testing.expectEqual(@as(u8, 14), atlas.data[tl + 4]);
    try testing.expectEqual(@as(u8, 15), atlas.data[tl + 5]);
    try testing.expectEqual(@as(u8, 0), atlas.data[tl + 6]); 
    tl += (atlas.size * depth); 
    try testing.expectEqual(@as(u8, 20), atlas.data[tl]);
    try testing.expectEqual(@as(u8, 21), atlas.data[tl + 1]);
    try testing.expectEqual(@as(u8, 22), atlas.data[tl + 2]);
    try testing.expectEqual(@as(u8, 23), atlas.data[tl + 3]);
    try testing.expectEqual(@as(u8, 24), atlas.data[tl + 4]);
    try testing.expectEqual(@as(u8, 25), atlas.data[tl + 5]);
    try testing.expectEqual(@as(u8, 0), atlas.data[tl + 6]); 
    _ = try atlas.reserve(alloc, 1, 3);
    _ = try atlas.reserve(alloc, 2, 1);
    try testing.expectError(Error.AtlasFull, atlas.reserve(alloc, 1, 1));
}
test "grow OOM" {
    var buf: [
        4 * 4 * 1 
        + node_prealloc * @sizeOf(Node) 
    ]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const alloc = fba.allocator();
    var atlas = try init(alloc, 4, .grayscale); 
    defer atlas.deinit(alloc);
    const reg = try atlas.reserve(alloc, 2, 2);
    try testing.expectError(
        Error.AtlasFull,
        atlas.reserve(alloc, 1, 1),
    );
    atlas.set(reg, &[_]u8{ 1, 2, 3, 4 });
    try testing.expectEqual(@as(u8, 1), atlas.data[5]);
    try testing.expectEqual(@as(u8, 2), atlas.data[6]);
    try testing.expectEqual(@as(u8, 3), atlas.data[9]);
    try testing.expectEqual(@as(u8, 4), atlas.data[10]);
    const old_modified = atlas.modified.load(.monotonic);
    const old_resized = atlas.resized.load(.monotonic);
    try testing.expectError(
        Allocator.Error.OutOfMemory,
        atlas.grow(alloc, atlas.size + 1),
    );
    const new_modified = atlas.modified.load(.monotonic);
    const new_resized = atlas.resized.load(.monotonic);
    try testing.expectEqual(old_modified, new_modified);
    try testing.expectEqual(old_resized, new_resized);
    try testing.expectEqual(@as(u8, 1), atlas.data[5]);
    try testing.expectEqual(@as(u8, 2), atlas.data[6]);
    try testing.expectEqual(@as(u8, 3), atlas.data[9]);
    try testing.expectEqual(@as(u8, 4), atlas.data[10]);
}
test "init error" {
    for (std.meta.tags(init_tw.FailPoint)) |tag| {
        const tw = init_tw;
        defer tw.end(.reset) catch unreachable;
        tw.errorAlways(tag, error.OutOfMemory);
        try testing.expectError(
            error.OutOfMemory,
            init(testing.allocator, 32, .grayscale),
        );
    }
}
test "reserve error" {
    for (std.meta.tags(reserve_tw.FailPoint)) |tag| {
        const tw = reserve_tw;
        defer tw.end(.reset) catch unreachable;
        var atlas = try init(testing.allocator, 32, .grayscale);
        defer atlas.deinit(testing.allocator);
        tw.errorAlways(tag, error.OutOfMemory);
        try testing.expectError(
            error.OutOfMemory,
            atlas.reserve(testing.allocator, 2, 2),
        );
    }
}
test "grow error" {
    for (std.meta.tags(grow_tw.FailPoint)) |tag| {
        const tw = grow_tw;
        defer tw.end(.reset) catch unreachable;
        var atlas = try init(testing.allocator, 4, .grayscale);
        defer atlas.deinit(testing.allocator);
        const reg = try atlas.reserve(testing.allocator, 2, 2);
        atlas.set(reg, &[_]u8{ 1, 2, 3, 4 });
        const old_modified = atlas.modified.load(.monotonic);
        const old_resized = atlas.resized.load(.monotonic);
        tw.errorAlways(tag, error.OutOfMemory);
        try testing.expectError(
            error.OutOfMemory,
            atlas.grow(testing.allocator, atlas.size + 1),
        );
        try testing.expectEqual(old_modified, atlas.modified.load(.monotonic));
        try testing.expectEqual(old_resized, atlas.resized.load(.monotonic));
        try testing.expectEqual(@as(u8, 1), atlas.data[5]);
        try testing.expectEqual(@as(u8, 2), atlas.data[6]);
        try testing.expectEqual(@as(u8, 3), atlas.data[9]);
        try testing.expectEqual(@as(u8, 4), atlas.data[10]);
    }
}
