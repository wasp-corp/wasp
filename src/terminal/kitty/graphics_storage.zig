const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const terminal = @import("../main.zig");
const point = @import("../point.zig");
const size = @import("../size.zig");
const animation = @import("graphics_animation.zig");
const pixel = @import("graphics_pixel.zig");
const command = @import("graphics_command.zig");
const PageList = @import("../PageList.zig");
const Screen = @import("../Screen.zig");
const LoadingImage = @import("graphics_image.zig").LoadingImage;
const Image = @import("graphics_image.zig").Image;
const Rect = @import("graphics_image.zig").Rect;
const Command = command.Command;
const log = std.log.scoped(.kitty_gfx);
var generation_counter: GenerationCounter = .{};
pub fn nextGeneration(io: std.Io) u64 {
    return generation_counter.next(io);
}
const GenerationCounter = if (@bitSizeOf(usize) >= 64) struct {
    value: std.atomic.Value(u64) = .init(0),
    fn next(self: *@This(), io: std.Io) u64 {
        _ = io;
        return self.value.fetchAdd(1, .monotonic) + 1;
    }
} else struct {
    mutex: std.Io.Mutex = .init,
    value: u64 = 0,
    fn next(self: *@This(), io: std.Io) u64 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.value += 1;
        return self.value;
    }
};
pub const ImageStorage = struct {
    const ImageMap = std.AutoHashMapUnmanaged(u32, Image);
    const PlacementMap = std.AutoHashMapUnmanaged(PlacementKey, Placement);
    dirty: bool = false,
    generation: u64 = 0,
    next_image_id: u32 = 2147483647,
    next_internal_placement_id: u32 = 0,
    images: ImageMap = .{},
    placements: PlacementMap = .{},
    loading: ?*LoadingImage = null,
    image_limits: LoadingImage.Limits = .direct,
    total_bytes: usize = 0,
    total_limit: usize = 320 * 1000 * 1000, 
    pub const PendingImage = struct {
        id: u32,
        generation: u64,
        pub fn complete(
            self: PendingImage,
            storage: *ImageStorage,
            io: std.Io,
            data: []const u8,
        ) bool {
            const img = storage.images.getPtr(self.id) orelse return false;
            if (img.generation != self.generation) return false;
            const expected_len = switch (img.data) {
                .complete => return false,
                .pending => |len| len,
            };
            if (data.len != expected_len) return false;
            img.data = .{ .complete = data };
            storage.markMutated(io);
            return true;
        }
    };
    pub fn deinit(
        self: *ImageStorage,
        alloc: Allocator,
        s: *terminal.Screen,
    ) void {
        if (self.loading) |loading| loading.destroy(alloc);
        self.clearPlacements(s);
        self.placements.deinit(alloc);
        var it = self.images.iterator();
        while (it.next()) |kv| kv.value_ptr.deinit(alloc);
        self.images.deinit(alloc);
    }
    pub fn enabled(self: *const ImageStorage) bool {
        return self.total_limit != 0;
    }
    pub fn markMutated(self: *ImageStorage, io: std.Io) void {
        self.dirty = true;
        self.generation = nextGeneration(io);
    }
    pub fn setLimit(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        s: *terminal.Screen,
        limit: usize,
    ) void {
        if (limit == 0) {
            const image_limits = self.image_limits;
            self.deinit(alloc, s);
            self.* = .{ .image_limits = image_limits };
            self.markMutated(io);
        }
        if (limit < self.total_bytes) {
            const req_bytes = self.total_bytes - limit;
            log.info("evicting images to lower limit, evicting={}", .{req_bytes});
            if (!self.evictImage(io, alloc, s, req_bytes)) {
                log.warn("failed to evict enough images for required bytes", .{});
            }
        }
        self.total_limit = limit;
    }
    pub fn nextImageId(
        self: *ImageStorage,
        mode: enum { explicit, implicit },
    ) u32 {
        var id: u32 = switch (mode) {
            .explicit => 1,
            .implicit => self.next_image_id,
        };
        const count: usize = self.images.count();
        for (0..count + 2) |_| {
            if (id != 0 and !self.images.contains(id)) break;
            id +%= 1;
        }
        if (id == 0) id = 1;
        if (mode == .implicit) self.next_image_id = id +% 1;
        return id;
    }
    pub fn addImage(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        s: *terminal.Screen,
        img: Image,
    ) Allocator.Error!void {
        const new_len = img.data.len();
        if (new_len > self.total_limit) return error.OutOfMemory;
        const old_len = if (self.images.get(img.id)) |old|
            old.storageSize()
        else
            0;
        assert(old_len <= self.total_bytes);
        if (!self.images.contains(img.id)) {
            try self.images.ensureUnusedCapacity(alloc, 1);
        }
        const total_bytes = self.total_bytes - old_len + new_len;
        if (total_bytes > self.total_limit) {
            const req_bytes = total_bytes - self.total_limit;
            log.info("evicting images to make space for {} bytes", .{req_bytes});
            if (!self.evictImageExcept(io, alloc, s, req_bytes, img.id)) {
                log.warn("failed to evict enough images for required bytes", .{});
                return error.OutOfMemory;
            }
        }
        const gop = self.images.getOrPutAssumeCapacity(img.id);
        log.debug("addImage image={}", .{img.withoutData()});
        if (gop.found_existing) {
            self.removePlacementsByImageId(s, img.id);
            _ = self.removeOrphans(s, null);
            self.total_bytes -= gop.value_ptr.storageSize();
            gop.value_ptr.deinit(alloc);
        }
        gop.value_ptr.* = img;
        gop.value_ptr.metadata.placement_count = 0;
        self.total_bytes += new_len;
        self.markMutated(io);
        gop.value_ptr.generation = self.generation;
    }
    pub fn addPendingImage(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        s: *terminal.Screen,
        img: Image,
    ) Allocator.Error!PendingImage {
        assert(img.data == .pending);
        try self.addImage(io, alloc, s, img);
        const stored = self.images.get(img.id).?;
        return .{ .id = stored.id, .generation = stored.generation };
    }
    pub fn addPlacement(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        s: *terminal.Screen,
        image_id: u32,
        placement_id: u32,
        p: Placement,
    ) !void {
        assert(self.images.get(image_id) != null);
        log.debug("placement image_id={} placement_id={} placement={}\n", .{
            image_id,
            placement_id,
            p,
        });
        self.reapGarbagePlacements(io, s);
        const key: PlacementKey = .{
            .image_id = image_id,
            .placement_id = if (placement_id == 0) .{
                .tag = .internal,
                .id = id: {
                    defer self.next_internal_placement_id +%= 1;
                    break :id self.next_internal_placement_id;
                },
            } else .{
                .tag = .external,
                .id = placement_id,
            },
        };
        const gop = try self.placements.getOrPut(alloc, key);
        if (gop.found_existing) {
            gop.value_ptr.deinit(s);
        } else {
            const img = self.images.getPtr(image_id).?;
            img.metadata.placement_count = std.math.add(
                @TypeOf(img.metadata.placement_count),
                img.metadata.placement_count,
                1,
            ) catch {
                self.placements.removeByPtr(gop.key_ptr);
                return error.OutOfMemory;
            };
        }
        gop.value_ptr.* = p;
        self.markMutated(io);
    }
    pub const ScrollOp = enum {
        window_shift,
        in_place,
    };
    pub fn scrollMarginsBegin(
        self: *ImageStorage,
        io: std.Io,
        t: *terminal.Terminal,
        delta: isize,
        op: ScrollOp,
    ) ScrollMargins {
        const s: *terminal.Screen = t.screens.active;
        assert(self == &s.kitty_images);
        var result: ScrollMargins = .{ .screen = s };
        const top: i64 = t.scrolling_region.top;
        const bottom: i64 = t.scrolling_region.bottom;
        var mutated = false;
        var it = self.placements.iterator();
        while (it.next()) |entry| {
            const p: *Placement = entry.value_ptr;
            const pin: *PageList.Pin = switch (p.location) {
                .pin => |pin| pin,
                .virtual, .relative => continue,
            };
            if (pin.garbage) continue;
            const coord = (s.pages.pointFromPin(
                .active,
                pin.*,
            ) orelse continue).coord();
            const y: i64 = coord.y;
            if (op == .in_place and (y < top or y > bottom)) continue;
            var final_y: i64 = y;
            inside: {
                const image = self.images.get(entry.key_ptr.image_id) orelse break :inside;
                const grid = p.gridSize(image, t);
                if (grid.rows == 0 or grid.cols == 0) break :inside;
                if (y < top or y + grid.rows - 1 > bottom) break :inside;
                const x: i64 = coord.x;
                if (x < t.scrolling_region.left or
                    @min(x + grid.cols - 1, @as(i64, t.cols) - 1) > t.scrolling_region.right) break :inside;
                const new_y: i64 = y + delta;
                const rows: i64 = grid.rows;
                const top_clip: i64 = @max(0, top - new_y);
                const bottom_clip: i64 = @max(0, new_y + rows - 1 - bottom);
                const visible: bool = clip: {
                    if (top_clip >= rows or bottom_clip >= rows) break :clip false;
                    if (top_clip > 0) {
                        if (!p.clipTop(
                            image,
                            t,
                            @intCast(top_clip),
                            grid.rows,
                        )) break :clip false;
                        mutated = true;
                        final_y = top;
                        break :clip true;
                    }
                    if (bottom_clip > 0) {
                        if (!p.clipBottom(
                            image,
                            t,
                            @intCast(bottom_clip),
                            grid.rows,
                        )) break :clip false;
                        mutated = true;
                    }
                    final_y = new_y;
                    break :clip true;
                };
                if (!visible) {
                    self.removePlacement(s, entry);
                    mutated = true;
                    continue;
                }
            }
            result.restores.append(s.alloc, .{
                .pin = pin,
                .x = pin.x,
                .y = @intCast(final_y),
            }) catch {
                log.warn("OOM adjusting image placement for scroll", .{});
                continue;
            };
        }
        if (mutated) {
            _ = self.removeOrphans(s, null);
            self.markMutated(io);
        }
        return result;
    }
    fn reapGarbagePlacements(
        self: *ImageStorage,
        io: std.Io,
        s: *terminal.Screen,
    ) void {
        var removed = false;
        var it = self.placements.iterator();
        while (it.next()) |entry| {
            const pin = switch (entry.value_ptr.location) {
                .pin => |pin| pin,
                .virtual, .relative => continue,
            };
            if (!pin.garbage) continue;
            self.removePlacement(s, entry);
            removed = true;
        }
        if (!removed) return;
        _ = self.removeOrphans(s, null);
        self.markMutated(io);
    }
    fn clearPlacements(self: *ImageStorage, s: *terminal.Screen) void {
        var it = self.placements.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(s);
        self.placements.clearRetainingCapacity();
    }
    fn removePlacementsByImageId(
        self: *ImageStorage,
        s: *terminal.Screen,
        image_id: u32,
    ) void {
        var it = self.placements.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.image_id != image_id) continue;
            self.removePlacement(s, entry);
        }
    }
    fn removePlacement(
        self: *ImageStorage,
        s: *terminal.Screen,
        entry: PlacementMap.Entry,
    ) void {
        entry.value_ptr.deinit(s);
        const img = self.images.getPtr(entry.key_ptr.image_id).?;
        assert(img.metadata.placement_count > 0);
        img.metadata.placement_count -= 1;
        self.placements.removeByPtr(entry.key_ptr);
    }
    fn removeOrphans(
        self: *ImageStorage,
        s: *terminal.Screen,
        delete_unused: ?Allocator,
    ) bool {
        var removed_any = false;
        var removed = true;
        while (removed) {
            removed = false;
            var it = self.placements.iterator();
            while (it.next()) |entry| {
                const rel = switch (entry.value_ptr.location) {
                    .relative => |rel| rel,
                    .pin, .virtual => continue,
                };
                if (self.placements.contains(rel.parent)) continue;
                const image_id = entry.key_ptr.image_id;
                self.removePlacement(s, entry);
                removed = true;
                removed_any = true;
                if (delete_unused) |alloc| self.deleteIfUnused(
                    alloc,
                    image_id,
                );
            }
        }
        return removed_any;
    }
    pub const parent_chain_limit = 8;
    pub const ParentError = error{
        ParentImageNotFound,
        ParentPlacementNotFound,
        SelfParent,
        Cycle,
        TooDeep,
        AncestorNotFound,
    };
    pub fn resolveParent(
        self: *ImageStorage,
        io: std.Io,
        s: *terminal.Screen,
        child: ?PlacementKey,
        parent_image_id: u32,
        parent_placement_id: u32,
    ) ParentError!PlacementKey {
        self.reapGarbagePlacements(io, s);
        if (!self.images.contains(parent_image_id)) {
            return error.ParentImageNotFound;
        }
        const parent: PlacementKey = parent: {
            if (parent_placement_id > 0) {
                const key: PlacementKey = .{
                    .image_id = parent_image_id,
                    .placement_id = .{
                        .tag = .external,
                        .id = parent_placement_id,
                    },
                };
                if (!self.placements.contains(key)) {
                    return error.ParentPlacementNotFound;
                }
                break :parent key;
            }
            const best: PlacementId = best: {
                var best: ?PlacementId = null;
                var it = self.placements.keyIterator();
                while (it.next()) |key| {
                    if (key.image_id != parent_image_id) continue;
                    const id = key.placement_id;
                    const b = best orelse {
                        best = id;
                        continue;
                    };
                    if (id.preferredOver(b)) best = id;
                }
                break :best best orelse return error.ParentPlacementNotFound;
            };
            break :parent .{
                .image_id = parent_image_id,
                .placement_id = best,
            };
        };
        if (child) |c| if (parent.eql(c)) return error.SelfParent;
        var depth: usize = 1;
        var key = parent;
        while (true) {
            if (child) |c| if (key.eql(c)) return error.Cycle;
            const p = self.placements.get(key) orelse return error.AncestorNotFound;
            const rel = switch (p.location) {
                .relative => |rel| rel,
                .pin, .virtual => break,
            };
            if (depth >= parent_chain_limit) return error.TooDeep;
            depth += 1;
            key = rel.parent;
        }
        return parent;
    }
    pub const ResolvedChain = struct {
        root_key: PlacementKey,
        root: Placement,
        horizontal_offset: i32,
        vertical_offset: i32,
    };
    pub fn resolveChain(
        self: *const ImageStorage,
        rel: Placement.Relative,
    ) ?ResolvedChain {
        var horizontal = rel.horizontal_offset;
        var vertical = rel.vertical_offset;
        var key = rel.parent;
        var depth: usize = 1;
        while (true) {
            const p = self.placements.get(key) orelse return null;
            switch (p.location) {
                .relative => |parent_rel| {
                    if (depth >= parent_chain_limit) return null;
                    depth += 1;
                    horizontal +|= parent_rel.horizontal_offset;
                    vertical +|= parent_rel.vertical_offset;
                    key = parent_rel.parent;
                },
                .pin, .virtual => return .{
                    .root_key = key,
                    .root = p,
                    .horizontal_offset = horizontal,
                    .vertical_offset = vertical,
                },
            }
        }
    }
    pub fn placeholderTarget(
        self: *const ImageStorage,
        image_id: u32,
        placement_id: u32,
    ) ?struct { key: PlacementKey, placement: Placement } {
        if (placement_id > 0) {
            const key: PlacementKey = .{
                .image_id = image_id,
                .placement_id = .{ .tag = .external, .id = placement_id },
            };
            const p = self.placements.get(key) orelse return null;
            return .{ .key = key, .placement = p };
        }
        var best: ?PlacementKey = null;
        var it = self.placements.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.image_id != image_id) continue;
            if (entry.value_ptr.location != .virtual) continue;
            const b = best orelse {
                best = entry.key_ptr.*;
                continue;
            };
            if (entry.key_ptr.placement_id.preferredOver(b.placement_id)) {
                best = entry.key_ptr.*;
            }
        }
        const key = best orelse return null;
        return .{ .key = key, .placement = self.placements.get(key).? };
    }
    pub fn imageById(self: *const ImageStorage, image_id: u32) ?Image {
        return self.images.get(image_id);
    }
    pub fn imageByNumber(self: *const ImageStorage, image_number: u32) ?Image {
        var newest: ?Image = null;
        var it = self.images.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.number == image_number) {
                if (newest == null or
                    kv.value_ptr.generation > newest.?.generation)
                {
                    newest = kv.value_ptr.*;
                }
            }
        }
        return newest;
    }
    pub fn imagePtrByIdOrNumber(
        self: *const ImageStorage,
        image_id: u32,
        image_number: u32,
    ) ?*Image {
        if (image_id != 0) return self.images.getPtr(image_id);
        var newest: ?*Image = null;
        var it = self.images.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.number != image_number) continue;
            if (newest == null or
                kv.value_ptr.generation > newest.?.generation)
            {
                newest = kv.value_ptr;
            }
        }
        return newest;
    }
    pub fn markImageContentChanged(
        self: *ImageStorage,
        io: std.Io,
        img: *Image,
    ) void {
        self.markMutated(io);
        img.generation = self.generation;
    }
    pub fn convertImageToRgba(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        img: *Image,
    ) Allocator.Error!void {
        if (img.format == .rgba) return;
        const old = img.data.bytes() orelse return;
        const rgba = try pixel.rgbaFromFormat(alloc, img.format, old);
        self.total_bytes -= old.len;
        self.total_bytes += rgba.len;
        img.data.deinit(alloc);
        img.data = .{ .complete = rgba };
        img.format = .rgba;
        self.markImageContentChanged(io, img);
    }
    pub fn reserveAnimationBytes(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        s: *terminal.Screen,
        image_id: u32,
        bytes: usize,
    ) Allocator.Error!void {
        if (bytes > self.total_limit) return error.OutOfMemory;
        const total_bytes = self.total_bytes + bytes;
        if (total_bytes > self.total_limit) {
            const req_bytes = total_bytes - self.total_limit;
            if (req_bytes > self.total_limit) return error.OutOfMemory;
            log.info("evicting images for animation frame, evicting={}", .{req_bytes});
            if (!self.evictImageExcept(
                io,
                alloc,
                s,
                req_bytes,
                image_id,
            )) {
                log.warn("failed to evict enough images for animation frame", .{});
                return error.OutOfMemory;
            }
        }
        self.total_bytes += bytes;
    }
    pub fn releaseAnimationBytes(self: *ImageStorage, bytes: usize) void {
        assert(bytes <= self.total_bytes);
        self.total_bytes -= bytes;
    }
    pub fn animationTick(self: *ImageStorage, io: std.Io, now_ms: u64) ?u64 {
        var min_delay: ?u64 = null;
        var it = self.images.iterator();
        while (it.next()) |entry| {
            const img: *Image = entry.value_ptr;
            const anim = img.animation orelse continue;
            if (anim.state == .stopped) continue;
            if (anim.frames.items.len == 0) continue;
            if (img.metadata.placement_count == 0) continue;
            if (img.data.isPending()) continue;
            if (anim.durationMs() == 0) continue;
            if (anim.max_loops > 0 and anim.current_loop >= anim.max_loops) continue;
            const shown_at: u64 = shown_at: {
                const at = anim.frame_shown_at_ms orelse break :shown_at now_ms;
                if (at > now_ms) break :shown_at now_ms;
                break :shown_at at;
            };
            anim.frame_shown_at_ms = shown_at;
            var next_at: u64 = shown_at +| anim.gapAt(anim.current_index);
            if (now_ms >= next_at) advance: {
                const count: u32 = anim.frameCount();
                var idx = anim.current_index;
                while (true) {
                    const next = (idx + 1) % count;
                    if (next == 0) {
                        if (anim.state == .loading) break :advance;
                        anim.current_loop += 1;
                        if (anim.max_loops > 0 and
                            anim.current_loop >= anim.max_loops) break :advance;
                    }
                    idx = next;
                    if (anim.gapAt(idx) != 0) break;
                }
                anim.current_index = idx;
                anim.frame_shown_at_ms = now_ms;
                self.markImageContentChanged(io, img);
                next_at = now_ms +| anim.gapAt(idx);
            }
            if (next_at > now_ms) {
                const delay = next_at - now_ms;
                min_delay = if (min_delay) |m| @min(m, delay) else delay;
            }
        }
        return min_delay;
    }
    pub fn clearScreen(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        t: *terminal.Terminal,
    ) void {
        const placements_before = self.placements.count();
        const images_before = self.images.count();
        self.deleteVisiblePlacements(alloc, t, true);
        _ = self.removeOrphans(t.screens.active, null);
        var image_it = self.images.iterator();
        while (image_it.next()) |entry| {
            self.deleteIfUnused(alloc, entry.key_ptr.*);
        }
        if (self.placements.count() != placements_before or
            self.images.count() != images_before) self.markMutated(io);
    }
    pub fn delete(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        t: *terminal.Terminal,
        cmd: command.Delete.Action,
    ) void {
        const placements_before = self.placements.count();
        const images_before = self.images.count();
        defer if (self.placements.count() != placements_before or
            self.images.count() != images_before) self.markMutated(io);
        switch (cmd) {
            .all => |delete_images| self.deleteVisiblePlacements(
                alloc,
                t,
                delete_images,
            ),
            .id => |v| self.deleteById(
                alloc,
                t.screens.active,
                v.image_id,
                v.placement_id,
                v.delete,
            ),
            .newest => |v| newest: {
                const img = self.imageByNumber(v.image_number) orelse break :newest;
                self.deleteById(
                    alloc,
                    t.screens.active,
                    img.id,
                    v.placement_id,
                    v.delete,
                );
            },
            .intersect_cursor => |delete_images| {
                self.deleteIntersecting(
                    alloc,
                    t,
                    .{ .active = .{
                        .x = t.screens.active.cursor.x,
                        .y = t.screens.active.cursor.y,
                    } },
                    delete_images,
                    {},
                    null,
                );
            },
            .intersect_cell => |v| intersect_cell: {
                if (v.x <= 0 or v.y <= 0) {
                    log.warn("delete intersect cell coords must be at least 1", .{});
                    break :intersect_cell;
                }
                self.deleteIntersecting(
                    alloc,
                    t,
                    .{ .active = .{
                        .x = std.math.cast(size.CellCountInt, v.x - 1) orelse break :intersect_cell,
                        .y = std.math.cast(size.CellCountInt, v.y - 1) orelse break :intersect_cell,
                    } },
                    v.delete,
                    {},
                    null,
                );
            },
            .intersect_cell_z => |v| intersect_cell_z: {
                if (v.x <= 0 or v.y <= 0) {
                    log.warn("delete intersect cell coords must be at least 1", .{});
                    break :intersect_cell_z;
                }
                self.deleteIntersecting(
                    alloc,
                    t,
                    .{ .active = .{
                        .x = std.math.cast(size.CellCountInt, v.x - 1) orelse break :intersect_cell_z,
                        .y = std.math.cast(size.CellCountInt, v.y - 1) orelse break :intersect_cell_z,
                    } },
                    v.delete,
                    v.z,
                    struct {
                        fn filter(ctx: i32, p: Placement) bool {
                            return p.z == ctx;
                        }
                    }.filter,
                );
            },
            .column => |v| column: {
                if (v.x <= 0) {
                    log.warn("delete column must be greater than zero", .{});
                    break :column;
                }
                const x = v.x - 1;
                var it = self.placements.iterator();
                while (it.next()) |entry| {
                    const img = self.imageById(entry.key_ptr.image_id) orelse continue;
                    const rect = entry.value_ptr.rect(img, t) orelse continue;
                    if (rect.top_left.x <= x and rect.bottom_right.x >= x) {
                        self.removePlacement(t.screens.active, entry);
                        if (v.delete) self.deleteIfUnused(alloc, img.id);
                    }
                }
            },
            .row => |v| row: {
                if (v.y <= 0) {
                    log.warn("delete row must be greater than zero", .{});
                    break :row;
                }
                const target_pin = t.screens.active.pages.pin(.{ .active = .{
                    .y = std.math.cast(size.CellCountInt, v.y - 1) orelse break :row,
                } }) orelse break :row;
                var it = self.placements.iterator();
                while (it.next()) |entry| {
                    const img = self.imageById(entry.key_ptr.image_id) orelse continue;
                    const rect = entry.value_ptr.rect(img, t) orelse continue;
                    var target_pin_copy = target_pin;
                    target_pin_copy.x = rect.top_left.x;
                    if (target_pin_copy.isBetween(rect.top_left, rect.bottom_right)) {
                        self.removePlacement(t.screens.active, entry);
                        if (v.delete) self.deleteIfUnused(alloc, img.id);
                    }
                }
            },
            .z => |v| {
                var it = self.placements.iterator();
                while (it.next()) |entry| {
                    switch (entry.value_ptr.location) {
                        .pin, .relative => {},
                        .virtual => continue,
                    }
                    if (entry.value_ptr.z == v.z) {
                        const image_id = entry.key_ptr.image_id;
                        self.removePlacement(t.screens.active, entry);
                        if (v.delete) self.deleteIfUnused(alloc, image_id);
                    }
                }
            },
            .range => |v| range: {
                if (v.last == 0 or v.first > v.last) break :range;
                var placement_it = self.placements.iterator();
                while (placement_it.next()) |entry| {
                    if (entry.key_ptr.image_id < v.first or
                        entry.key_ptr.image_id > v.last) continue;
                    self.removePlacement(t.screens.active, entry);
                }
                if (!v.delete) break :range;
                var image_it = self.images.iterator();
                while (image_it.next()) |entry| {
                    const image_id = entry.key_ptr.*;
                    if (image_id >= v.first and image_id <= v.last) {
                        self.deleteIfUnused(alloc, image_id);
                    }
                }
            },
            .animation_frames => |v| self.deleteAnimationFrame(
                io,
                alloc,
                t.screens.active,
                v,
            ),
        }
        const delete_unused: bool = switch (cmd) {
            .all, .intersect_cursor => |v| v,
            inline else => |v| v.delete,
        };
        _ = self.removeOrphans(
            t.screens.active,
            if (delete_unused) alloc else null,
        );
    }
    fn deleteVisiblePlacements(
        self: *ImageStorage,
        alloc: Allocator,
        t: *terminal.Terminal,
        delete_unused: bool,
    ) void {
        var it = self.placements.iterator();
        while (it.next()) |entry| {
            const pin = switch (entry.value_ptr.location) {
                .pin => |pin| pin,
                .virtual, .relative => continue,
            };
            if (pin.garbage) continue;
            if (t.screens.active.pages.pointFromPin(
                .active,
                pin.*,
            ) == null) {
                const image = self.imageById(entry.key_ptr.image_id) orelse continue;
                const rect = entry.value_ptr.rect(image, t) orelse continue;
                if (t.screens.active.pages.pointFromPin(.active, rect.bottom_right) == null) continue;
            }
            const image_id = entry.key_ptr.image_id;
            self.removePlacement(t.screens.active, entry);
            if (delete_unused) self.deleteIfUnused(alloc, image_id);
        }
    }
    fn deleteById(
        self: *ImageStorage,
        alloc: Allocator,
        s: *terminal.Screen,
        image_id: u32,
        placement_id: u32,
        delete_unused: bool,
    ) void {
        var matched = placement_id == 0;
        if (placement_id == 0) self.removePlacementsByImageId(
            s,
            image_id,
        ) else if (self.placements.getEntry(.{
            .image_id = image_id,
            .placement_id = .{
                .tag = .external,
                .id = placement_id,
            },
        })) |entry| {
            self.removePlacement(s, entry);
            matched = true;
        }
        if (delete_unused and matched) self.deleteIfUnused(alloc, image_id);
    }
    fn deleteAnimationFrame(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        s: *terminal.Screen,
        v: command.Delete.Action.AnimationFrames,
    ) void {
        if (v.image_id == 0 and v.image_number == 0) {
            log.warn("delete animation frames requires image id or number", .{});
            return;
        }
        const img = self.imagePtrByIdOrNumber(
            v.image_id,
            v.image_number,
        ) orelse {
            log.warn(
                "delete animation frames for unknown image id={} number={}",
                .{ v.image_id, v.image_number },
            );
            return;
        };
        const anim: *animation.Animation = anim: {
            if (img.animation) |anim| {
                if (anim.frames.items.len > 0) break :anim anim;
            }
            if (!v.delete) return;
            self.removePlacementsByImageId(s, img.id);
            const entry = self.images.getEntry(img.id).?;
            self.total_bytes -= entry.value_ptr.storageSize();
            entry.value_ptr.deinit(alloc);
            self.images.removeByPtr(entry.key_ptr);
            return;
        };
        const count: u32 = anim.frameCount();
        var number: u32 = @min(v.frame, count);
        if (number == 0) number = 1;
        if (number == 1) {
            self.releaseAnimationBytes(img.data.len());
            img.data.deinit(alloc);
            const promoted = anim.frames.orderedRemove(0);
            img.data = .{ .complete = promoted.data };
            anim.root_gap_ms = promoted.gap_ms;
        } else {
            const removed = anim.frames.orderedRemove(number - 2);
            self.releaseAnimationBytes(removed.data.len);
            alloc.free(removed.data);
        }
        const removed_idx: u32 = if (number == 1) 0 else number - 2;
        const remaining: u32 = @intCast(anim.frames.items.len);
        if (anim.current_index > remaining) {
            anim.current_index = remaining;
            anim.frame_shown_at_ms = null;
            self.markImageContentChanged(io, img);
            return;
        }
        if (removed_idx == anim.current_index) {
            anim.frame_shown_at_ms = null;
            self.markImageContentChanged(io, img);
        } else {
            if (removed_idx < anim.current_index) anim.current_index -= 1;
            self.markMutated(io);
        }
    }
    fn deleteIfUnused(self: *ImageStorage, alloc: Allocator, image_id: u32) void {
        const entry = self.images.getEntry(image_id) orelse return;
        if (entry.value_ptr.metadata.placement_count > 0) return;
        self.total_bytes -= entry.value_ptr.storageSize();
        entry.value_ptr.deinit(alloc);
        self.images.removeByPtr(entry.key_ptr);
    }
    fn deleteIntersecting(
        self: *ImageStorage,
        alloc: Allocator,
        t: *terminal.Terminal,
        p: point.Point,
        delete_unused: bool,
        filter_ctx: anytype,
        comptime filter: ?fn (@TypeOf(filter_ctx), Placement) bool,
    ) void {
        const target_pin = t.screens.active.pages.pin(p) orelse return;
        var it = self.placements.iterator();
        while (it.next()) |entry| {
            const img = self.imageById(entry.key_ptr.image_id) orelse continue;
            const rect = entry.value_ptr.rect(img, t) orelse continue;
            if (rect.contains(target_pin)) {
                if (filter) |f| if (!f(filter_ctx, entry.value_ptr.*)) continue;
                self.removePlacement(t.screens.active, entry);
                if (delete_unused) self.deleteIfUnused(alloc, img.id);
            }
        }
    }
    fn evictImage(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        s: *terminal.Screen,
        req: usize,
    ) bool {
        return self.evictImageExcept(io, alloc, s, req, null);
    }
    fn evictImageExcept(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        s: *terminal.Screen,
        req: usize,
        exclude_id: ?u32,
    ) bool {
        assert(req <= self.total_limit);
        const Candidate = struct {
            id: u32,
            generation: u64,
            priority: u2,
            fn init(img: *const Image) @This() {
                return .{
                    .id = img.id,
                    .generation = img.generation,
                    .priority = (if (img.metadata.transient) @as(u2, 0) else @as(u2, 1)) +
                        (if (img.metadata.placement_count > 0) @as(u2, 2) else @as(u2, 0)),
                };
            }
            fn lessThan(lhs: @This(), rhs: @This()) bool {
                if (lhs.priority != rhs.priority)
                    return lhs.priority < rhs.priority;
                if (lhs.generation != rhs.generation)
                    return lhs.generation < rhs.generation;
                return lhs.id < rhs.id;
            }
        };
        const images_before = self.images.count();
        defer if (self.images.count() != images_before) {
            _ = self.removeOrphans(s, null);
            self.markMutated(io);
        };
        var evicted: usize = 0;
        while (evicted < req) {
            const c = candidate: {
                var best: ?Candidate = null;
                var it = self.images.iterator();
                while (it.next()) |kv| {
                    const img = kv.value_ptr;
                    if (exclude_id != null and img.id == exclude_id.?) continue;
                    const current = Candidate.init(img);
                    if (best == null or current.lessThan(best.?)) best = current;
                }
                break :candidate best orelse return false;
            };
            var p_it = self.placements.iterator();
            while (p_it.next()) |entry| {
                if (entry.key_ptr.image_id == c.id) {
                    self.removePlacement(s, entry);
                }
            }
            const entry = self.images.getEntry(c.id).?;
            const image_len = entry.value_ptr.storageSize();
            log.info("evicting image id={} bytes={}", .{ c.id, image_len });
            evicted += image_len;
            self.total_bytes -= image_len;
            entry.value_ptr.deinit(alloc);
            self.images.removeByPtr(entry.key_ptr);
        }
        return true;
    }
    pub const ScrollMargins = struct {
        screen: *terminal.Screen,
        restores: std.ArrayListUnmanaged(Restore) = .empty,
        const Restore = struct {
            pin: *PageList.Pin,
            x: size.CellCountInt,
            y: u32,
        };
        pub fn end(self: *ScrollMargins) void {
            for (self.restores.items) |restore| {
                restore.pin.* = self.screen.pages.pin(.{ .active = .{
                    .x = restore.x,
                    .y = restore.y,
                } }) orelse continue;
            }
            self.restores.deinit(self.screen.alloc);
        }
    };
    pub const PlacementKey = struct {
        image_id: u32,
        placement_id: PlacementId,
        pub fn eql(self: PlacementKey, other: PlacementKey) bool {
            return std.meta.eql(self, other);
        }
    };
    pub const PlacementId = packed struct {
        tag: enum(u1) { internal, external },
        id: u32,
        pub fn preferredOver(self: PlacementId, other: PlacementId) bool {
            if (self.tag != other.tag) return self.tag == .external;
            return self.id < other.id;
        }
    };
    pub const Placement = struct {
        location: Location,
        x_offset: u32 = 0,
        y_offset: u32 = 0,
        source_x: u32 = 0,
        source_y: u32 = 0,
        source_width: u32 = 0,
        source_height: u32 = 0,
        columns: u32 = 0,
        rows: u32 = 0,
        z: i32 = 0,
        pub const Location = union(enum) {
            pin: *PageList.Pin,
            virtual,
            relative: Relative,
        };
        pub const Relative = struct {
            parent: PlacementKey,
            horizontal_offset: i32 = 0,
            vertical_offset: i32 = 0,
        };
        pub fn deinit(
            self: *const Placement,
            s: *terminal.Screen,
        ) void {
            switch (self.location) {
                .pin => |p| s.pages.untrackPin(p),
                .virtual, .relative => {},
            }
        }
        fn saturatingMul(lhs: u32, rhs: u32) u32 {
            return std.math.mul(u32, lhs, rhs) catch std.math.maxInt(u32);
        }
        fn scaleDimension(value: u32, numerator: u32, denominator: u32) u32 {
            if (denominator == 0) return 0;
            const rounded = (@as(u64, value) * @as(u64, numerator) +
                @as(u64, denominator) / 2) / @as(u64, denominator);
            return std.math.cast(u32, rounded) orelse std.math.maxInt(u32);
        }
        pub const SourceRect = struct {
            x: u32,
            y: u32,
            width: u32,
            height: u32,
        };
        pub fn sourceRect(self: Placement, image: Image) SourceRect {
            const x = @min(self.source_x, image.width);
            const y = @min(self.source_y, image.height);
            return .{
                .x = x,
                .y = y,
                .width = @min(
                    if (self.source_width > 0) self.source_width else image.width,
                    image.width - x,
                ),
                .height = @min(
                    if (self.source_height > 0) self.source_height else image.height,
                    image.height - y,
                ),
            };
        }
        pub fn cellOffset(
            self: Placement,
            t: *const terminal.Terminal,
        ) struct {
            x: u32,
            y: u32,
        } {
            const cell_width: u32 = t.width_px / t.cols;
            const cell_height: u32 = t.height_px / t.rows;
            return .{
                .x = if (cell_width > 0)
                    @min(self.x_offset, cell_width - 1)
                else
                    0,
                .y = if (cell_height > 0)
                    @min(self.y_offset, cell_height - 1)
                else
                    0,
            };
        }
        pub fn pixelSize(
            self: Placement,
            image: Image,
            t: *const terminal.Terminal,
        ) struct {
            width: u32,
            height: u32,
        } {
            const source = self.sourceRect(image);
            const width = source.width;
            const height = source.height;
            if (self.columns == 0 and self.rows == 0) return .{
                .width = width,
                .height = height,
            };
            const cell_width: u32 = t.width_px / t.cols;
            const cell_height: u32 = t.height_px / t.rows;
            const cell_offset = self.cellOffset(t);
            if (self.columns > 0 and self.rows > 0) {
                const calc_width = saturatingMul(cell_width, self.columns);
                const calc_height = saturatingMul(cell_height, self.rows);
                return .{
                    .width = calc_width -| cell_offset.x,
                    .height = calc_height -| cell_offset.y,
                };
            }
            if (self.columns > 0) {
                const calc_width = saturatingMul(
                    cell_width,
                    self.columns,
                ) -| cell_offset.x;
                const calc_height = scaleDimension(calc_width, height, width);
                return .{
                    .width = calc_width,
                    .height = calc_height,
                };
            }
            {
                const calc_height = saturatingMul(
                    cell_height,
                    self.rows,
                ) -| cell_offset.y;
                const calc_width = scaleDimension(calc_height, width, height);
                return .{
                    .width = calc_width,
                    .height = calc_height,
                };
            }
        }
        pub fn gridSize(
            self: Placement,
            image: Image,
            t: *const terminal.Terminal,
        ) struct {
            cols: u32,
            rows: u32,
        } {
            if (self.columns > 0 and self.rows > 0) return .{
                .cols = self.columns,
                .rows = self.rows,
            };
            const calc_size = self.pixelSize(image, t);
            const cell_offset = self.cellOffset(t);
            return .{
                .cols = std.math.divCeil(
                    u32,
                    calc_size.width +| cell_offset.x,
                    t.width_px / t.cols,
                ) catch 0,
                .rows = std.math.divCeil(
                    u32,
                    calc_size.height +| cell_offset.y,
                    t.height_px / t.rows,
                ) catch 0,
            };
        }
        fn clipTop(
            self: *Placement,
            image: Image,
            t: *const terminal.Terminal,
            count: u32,
            span: u32,
        ) bool {
            assert(count > 0 and count < span);
            const src = self.sourceRect(image);
            const crop: u32 = if (self.rows > 0)
                @intCast(@as(u64, src.height) * count / span)
            else
                saturatingMul(t.height_px / t.rows, count);
            if (crop >= src.height) return false;
            self.source_x = src.x;
            self.source_y = src.y + crop;
            self.source_width = src.width;
            self.source_height = src.height - crop;
            if (self.rows > 0) self.rows -= count;
            return true;
        }
        fn clipBottom(
            self: *Placement,
            image: Image,
            t: *const terminal.Terminal,
            count: u32,
            span: u32,
        ) bool {
            assert(count > 0 and count < span);
            const src = self.sourceRect(image);
            if (src.height == 0) return false;
            if (self.rows > 0) {
                const crop: u32 = @intCast(@as(u64, src.height) * count / span);
                if (crop >= src.height) return false;
                self.source_height = src.height - crop;
                self.rows -= count;
            } else {
                const visible = saturatingMul(t.height_px / t.rows, span - count);
                const offset = self.cellOffset(t).y;
                if (visible <= offset) return false;
                self.source_height = @min(src.height, visible - offset);
            }
            self.source_x = src.x;
            self.source_y = src.y;
            self.source_width = src.width;
            return true;
        }
        pub fn rect(
            self: Placement,
            image: Image,
            t: *const terminal.Terminal,
        ) ?Rect {
            const grid_size = self.gridSize(image, t);
            const pin = switch (self.location) {
                .pin => |p| p,
                .virtual, .relative => return null,
            };
            if (pin.garbage) return null;
            if (grid_size.cols == 0 or grid_size.rows == 0) return null;
            var br = switch (pin.downOverflow(grid_size.rows - 1)) {
                .offset => |v| v,
                .overflow => |v| v.end,
            };
            br.x = @intCast(@min(
                @as(u32, pin.x) +| (grid_size.cols - 1),
                @as(u32, t.cols) - 1,
            ));
            return .{
                .top_left = pin.*,
                .bottom_right = br,
            };
        }
    };
};
fn trackPin(
    t: *terminal.Terminal,
    pt: point.Coordinate,
) !*PageList.Pin {
    return try t.screens.active.pages.trackPin(t.screens.active.pages.pin(.{
        .active = pt,
    }).?);
}
test "storage: add placement with zero placement id" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 100, .rows = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 0, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 0, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .internal, .id = 0 },
    }) != null);
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .internal, .id = 1 },
    }) != null);
}
test "storage: replacing placement releases tracked pin" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    const tracked = t.screens.active.pages.countTrackedPins();
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) },
    });
    try testing.expectEqual(
        tracked + 1,
        t.screens.active.pages.countTrackedPins(),
    );
    const replacement_pin = try trackPin(&t, .{ .x = 2, .y = 2 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = replacement_pin },
    });
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(
        tracked + 1,
        t.screens.active.pages.countTrackedPins(),
    );
    try testing.expectEqual(
        replacement_pin,
        s.placements.get(.{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 1 },
        }).?.location.pin,
    );
}
test "storage: adding placement reclaims garbage placements" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    const tracked = t.screens.active.pages.countTrackedPins();
    const old_pin = try trackPin(&t, .{ .x = 0, .y = 0 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 0, .{
        .location = .{ .pin = old_pin },
    });
    old_pin.garbage = true;
    const new_pin = try trackPin(&t, .{ .x = 1, .y = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 0, .{
        .location = .{ .pin = new_pin },
    });
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(
        tracked + 1,
        t.screens.active.pages.countTrackedPins(),
    );
    try testing.expectEqual(
        new_pin,
        s.placements.get(.{
            .image_id = 1,
            .placement_id = .{ .tag = .internal, .id = 1 },
        }).?.location.pin,
    );
}
test "storage: placement count limit permits replacement" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .virtual = {} } });
    const img = s.images.getPtr(1).?;
    img.metadata.placement_count = std.math.maxInt(@TypeOf(img.metadata.placement_count));
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .virtual = {} } });
    try testing.expectError(
        error.OutOfMemory,
        s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .virtual = {} } }),
    );
    try testing.expectEqual(@as(usize, 1), s.placements.count());
}
test "storage: delete all visible placements and matching images" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    s.dirty = false;
    s.delete(io, alloc, &t, .{ .all = true });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.images.count());
    try testing.expect(s.images.contains(3));
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}
test "storage: delete all placements and images preserves limit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    s.total_limit = 5000;
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    s.dirty = false;
    s.delete(io, alloc, &t, .{ .all = true });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.images.count());
    try testing.expect(s.images.contains(3));
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(@as(usize, 5000), s.total_limit);
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}
test "storage: delete all visible placements preserves scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{
        .rows = 2,
        .cols = 2,
        .max_scrollback_bytes = 4096,
    });
    defer t.deinit(alloc);
    t.width_px = 2;
    t.height_px = 2;
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 1, .height = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .y = 0 }) },
    });
    try t.scrollUp(1);
    const history_key: ImageStorage.PlacementKey = .{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    };
    try testing.expect(t.screens.active.pages.pointFromPin(
        .active,
        s.placements.get(history_key).?.location.pin.*,
    ) == null);
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{
        .location = .{ .pin = try trackPin(&t, .{ .y = 0 }) },
    });
    s.delete(io, alloc, &t, .{ .all = true });
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expect(s.placements.contains(history_key));
    try testing.expectEqual(@as(usize, 1), s.images.count());
    try testing.expect(s.images.contains(1));
}
test "storage: delete all includes placements spanning into active area" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{
        .rows = 2,
        .cols = 2,
        .max_scrollback_bytes = 4096,
    });
    defer t.deinit(alloc);
    t.width_px = 2;
    t.height_px = 2;
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 2,
    });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .y = 0 }) },
    });
    try t.scrollUp(1);
    const placement = s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }).?;
    try testing.expect(t.screens.active.pages.pointFromPin(
        .active,
        placement.location.pin.*,
    ) == null);
    const rect = placement.rect(s.imageById(1).?, &t).?;
    try testing.expect(t.screens.active.pages.pointFromPin(
        .active,
        rect.bottom_right,
    ) != null);
    s.delete(io, alloc, &t, .{ .all = true });
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(@as(usize, 0), s.images.count());
}
test "storage: delete all placements" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    s.dirty = false;
    s.delete(io, alloc, &t, .{ .all = false });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}
test "storage: delete all placements by image id" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    s.dirty = false;
    s.delete(io, alloc, &t, .{ .id = .{ .image_id = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
}
test "storage: delete all placements by image id and unused images" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    s.dirty = false;
    s.delete(io, alloc, &t, .{ .id = .{ .delete = true, .image_id = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
}
test "storage: delete placement by specific id" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    s.dirty = false;
    s.delete(io, alloc, &t, .{ .id = .{
        .delete = true,
        .image_id = 1,
        .placement_id = 2,
    } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(tracked + 2, t.screens.active.pages.countTrackedPins());
}
test "storage: uppercase id delete preserves image when placement does not match" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    s.dirty = false;
    const generation = s.generation;
    s.delete(io, alloc, &t, .{ .id = .{
        .delete = true,
        .image_id = 1,
        .placement_id = 7,
    } });
    try testing.expect(s.imageById(1) != null);
    try testing.expect(!s.dirty);
    try testing.expectEqual(generation, s.generation);
}
test "storage: uppercase id delete frees image after placement matches" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 9, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) },
    });
    s.dirty = false;
    s.delete(io, alloc, &t, .{ .id = .{
        .delete = true,
        .image_id = 1,
        .placement_id = 9,
    } });
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(@as(usize, 0), s.images.count());
    try testing.expect(s.dirty);
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}
test "storage: uppercase id delete without placement frees unplaced image" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    s.dirty = false;
    s.delete(io, alloc, &t, .{ .id = .{
        .delete = true,
        .image_id = 1,
    } });
    try testing.expectEqual(@as(usize, 0), s.images.count());
    try testing.expect(s.dirty);
}
test "storage: delete intersecting cursor" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });
    t.screens.active.cursorAbsolute(12, 12);
    s.dirty = false;
    s.delete(io, alloc, &t, .{ .intersect_cursor = false });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 2 },
    }) != null);
}
test "storage: delete intersecting cursor checks interior row column" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 10, .height = 10 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 20, .y = 0 }) } });
    t.screens.active.cursorAbsolute(21, 5);
    s.delete(io, alloc, &t, .{ .intersect_cursor = false });
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
}
test "storage: delete intersecting cell checks interior row column" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 10, .height = 10 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 20, .y = 0 }) } });
    s.delete(io, alloc, &t, .{ .intersect_cell = .{
        .x = 22,
        .y = 6,
    } });
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
}
test "storage: delete intersecting cursor plus unused" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });
    t.screens.active.cursorAbsolute(12, 12);
    s.dirty = false;
    s.delete(io, alloc, &t, .{ .intersect_cursor = true });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 2 },
    }) != null);
}
test "storage: delete intersecting cursor hits multiple" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });
    t.screens.active.cursorAbsolute(26, 26);
    s.dirty = false;
    s.delete(io, alloc, &t, .{ .intersect_cursor = true });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(@as(usize, 1), s.images.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}
test "storage: delete by column" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });
    s.dirty = false;
    s.delete(io, alloc, &t, .{ .column = .{
        .delete = false,
        .x = 60,
    } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
}
test "storage: delete by column 1x1" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 1, .height = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 3, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 2, .y = 0 }) } });
    s.delete(io, alloc, &t, .{ .column = .{
        .delete = false,
        .x = 2,
    } });
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expectEqual(@as(usize, 1), s.images.count());
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 3 },
    }) != null);
}
test "storage: delete by row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });
    s.dirty = false;
    s.delete(io, alloc, &t, .{ .row = .{
        .delete = false,
        .y = 60,
    } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
}
test "storage: delete by row 1x1" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 1, .height = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 3, .{ .location = .{ .pin = try trackPin(&t, .{ .y = 2 }) } });
    s.delete(io, alloc, &t, .{ .row = .{
        .delete = false,
        .y = 2,
    } });
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expectEqual(@as(usize, 1), s.images.count());
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 3 },
    }) != null);
}
test "storage: delete images by range 1" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    s.dirty = false;
    s.delete(io, alloc, &t, .{ .range = .{ .delete = false, .first = 1, .last = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}
test "storage: delete images by range 2" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    s.dirty = false;
    s.delete(io, alloc, &t, .{ .range = .{ .delete = true, .first = 1, .last = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.images.count());
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}
test "storage: delete images by range 3" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 3, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 3), s.placements.count());
    s.dirty = false;
    s.delete(io, alloc, &t, .{ .range = .{ .delete = false, .first = 2, .last = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
    try testing.expect(s.placements.get(.{
        .image_id = 3,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
    try testing.expectEqual(tracked + 2, t.screens.active.pages.countTrackedPins());
}
test "storage: delete images by range 4" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 3, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 3), s.placements.count());
    s.dirty = false;
    s.delete(io, alloc, &t, .{ .range = .{ .delete = true, .first = 2, .last = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
    try testing.expect(s.placements.get(.{
        .image_id = 3,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
    try testing.expectEqual(tracked + 2, t.screens.active.pages.countTrackedPins());
}
test "storage: uppercase range deletes unplaced image data" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    s.delete(io, alloc, &t, .{
        .range = .{
            .delete = true,
            .first = 0,
            .last = 2,
        },
    });
    try testing.expectEqual(@as(usize, 1), s.images.count());
    try testing.expect(s.images.contains(3));
}
test "storage: delete images by empty range" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    s.delete(io, alloc, &t, .{ .range = .{ .delete = true, .first = 5, .last = 4 } });
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    s.delete(io, alloc, &t, .{ .range = .{ .delete = true, .first = 5, .last = 0 } });
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    s.delete(io, alloc, &t, .{ .range = .{ .delete = true, .first = 0, .last = 0 } });
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expectEqual(tracked + 2, t.screens.active.pages.countTrackedPins());
}
test "storage: erase display preserves scrollback and reclaims unplaced images" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{
        .rows = 2,
        .cols = 2,
        .max_scrollback_bytes = 4096,
    });
    defer t.deinit(alloc);
    t.width_px = 2;
    t.height_px = 2;
    const s = &t.screens.active.kitty_images;
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 1, .height = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .y = 0 }) },
    });
    try t.scrollUp(1);
    const history_key: ImageStorage.PlacementKey = .{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    };
    try testing.expect(t.screens.active.pages.pointFromPin(
        .active,
        s.placements.get(history_key).?.location.pin.*,
    ) == null);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .width = 1, .height = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .y = 0 }) },
    });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3, .width = 1, .height = 1 });
    t.eraseDisplay(.complete, false);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expect(s.placements.contains(history_key));
    try testing.expectEqual(@as(usize, 1), s.images.count());
    try testing.expect(s.images.contains(1));
    try testing.expect(!s.images.contains(2));
    try testing.expect(!s.images.contains(3));
}
test "storage: cell offsets stay within explicit destination rectangle" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 5, .rows = 5 });
    defer t.deinit(alloc);
    t.width_px = 50; 
    t.height_px = 100; 
    const placement: ImageStorage.Placement = .{
        .location = .{ .virtual = {} },
        .x_offset = 3,
        .y_offset = 4,
        .columns = 2,
        .rows = 1,
    };
    const actual = placement.pixelSize(.{ .width = 4, .height = 3 }, &t);
    try testing.expectEqual(@as(u32, 17), actual.width);
    try testing.expectEqual(@as(u32, 16), actual.height);
    try testing.expectEqual(@as(u32, 2), placement.gridSize(.{ .width = 4, .height = 3 }, &t).cols);
    try testing.expectEqual(@as(u32, 1), placement.gridSize(.{ .width = 4, .height = 3 }, &t).rows);
}
test "storage: cell offsets clamp to cell bounds" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 5, .rows = 5 });
    defer t.deinit(alloc);
    t.width_px = 50; 
    t.height_px = 100; 
    const placement: ImageStorage.Placement = .{
        .location = .{ .virtual = {} },
        .x_offset = std.math.maxInt(u32),
        .y_offset = std.math.maxInt(u32),
        .columns = 1,
        .rows = 1,
    };
    const offset = placement.cellOffset(&t);
    try testing.expectEqual(@as(u32, 9), offset.x);
    try testing.expectEqual(@as(u32, 19), offset.y);
    const actual = placement.pixelSize(.{ .width = 1, .height = 1 }, &t);
    try testing.expectEqual(@as(u32, 1), actual.width);
    try testing.expectEqual(@as(u32, 1), actual.height);
}
test "storage: aspect ratio calculation when only columns or rows specified" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 100, .rows = 100 });
    defer t.deinit(alloc);
    t.width_px = 1000; 
    t.height_px = 2000; 
    {
        const image = Image{ .id = 1, .width = 16, .height = 9 };
        var placement = ImageStorage.Placement{
            .location = .{ .virtual = {} },
            .columns = 10,
            .rows = 0,
        };
        const calc_size = placement.pixelSize(image, &t);
        try testing.expectEqual(@as(u32, 100), calc_size.width);
        try testing.expectEqual(@as(u32, 56), calc_size.height);
    }
    {
        const image = Image{ .id = 2, .width = 16, .height = 9 };
        var placement = ImageStorage.Placement{
            .location = .{ .virtual = {} },
            .columns = 0,
            .rows = 5,
        };
        const calc_size = placement.pixelSize(image, &t);
        try testing.expectEqual(@as(u32, 178), calc_size.width);
        try testing.expectEqual(@as(u32, 100), calc_size.height);
    }
}
test "storage: default source rectangle is intersected before sizing" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 5, .rows = 5 });
    defer t.deinit(alloc);
    const placement: ImageStorage.Placement = .{
        .location = .{ .virtual = {} },
        .source_x = 3,
        .source_y = 1,
    };
    const actual = placement.pixelSize(.{ .width = 4, .height = 3 }, &t);
    try testing.expectEqual(@as(u32, 1), actual.width);
    try testing.expectEqual(@as(u32, 2), actual.height);
}
test "storage: explicit source rectangle is intersected before sizing" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const placement: ImageStorage.Placement = .{
        .location = .{ .virtual = {} },
        .source_x = 8,
        .source_y = 7,
        .source_width = 8,
        .source_height = 8,
        .columns = 2,
    };
    const actual = placement.pixelSize(.{ .width = 10, .height = 10 }, &t);
    try testing.expectEqual(@as(u32, 20), actual.width);
    try testing.expectEqual(@as(u32, 30), actual.height);
}
test "storage: placement geometry handles untrusted dimensions" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    const max = std.math.maxInt(u32);
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 2, .rows = 2 });
    defer t.deinit(alloc);
    t.width_px = max;
    t.height_px = max;
    {
        const placement: ImageStorage.Placement = .{
            .location = .{ .virtual = {} },
            .columns = 3,
            .rows = 3,
        };
        const actual = placement.pixelSize(.{ .width = 1, .height = 1 }, &t);
        try testing.expectEqual(max, actual.width);
        try testing.expectEqual(max, actual.height);
    }
    {
        const placement: ImageStorage.Placement = .{
            .location = .{ .virtual = {} },
            .columns = 3,
            .source_height = max,
        };
        const actual = placement.pixelSize(.{ .width = 1, .height = 1 }, &t);
        try testing.expectEqual(max, actual.width);
        try testing.expectEqual(max, actual.height);
    }
    {
        const placement: ImageStorage.Placement = .{
            .location = .{ .virtual = {} },
            .rows = 3,
            .source_width = max,
        };
        const actual = placement.pixelSize(.{ .width = 1, .height = 1 }, &t);
        try testing.expectEqual(max, actual.width);
        try testing.expectEqual(max, actual.height);
    }
    t.width_px = 2;
    t.height_px = 2;
    {
        const placement: ImageStorage.Placement = .{
            .location = .{ .virtual = {} },
            .x_offset = max,
            .y_offset = max,
        };
        const actual = placement.gridSize(.{ .width = 1, .height = 1 }, &t);
        try testing.expectEqual(@as(u32, 1), actual.cols);
        try testing.expectEqual(@as(u32, 1), actual.rows);
    }
    const pin = try trackPin(&t, .{ .x = 0, .y = 0 });
    defer t.screens.active.pages.untrackPin(pin);
    {
        const placement: ImageStorage.Placement = .{
            .location = .{ .pin = pin },
            .columns = max,
            .rows = 1,
        };
        const rect = placement.rect(.{ .width = 1, .height = 1 }, &t).?;
        try testing.expectEqual(@as(size.CellCountInt, 1), rect.bottom_right.x);
    }
    pin.garbage = true;
    {
        const placement: ImageStorage.Placement = .{
            .location = .{ .pin = pin },
            .columns = 1,
            .rows = 1,
        };
        try testing.expect(placement.rect(.{ .width = 1, .height = 1 }, &t) == null);
    }
    pin.garbage = false;
    t.width_px = 0;
    t.height_px = 0;
    {
        const placement: ImageStorage.Placement = .{
            .location = .{ .pin = pin },
            .columns = 1,
        };
        const actual = placement.gridSize(.{ .width = 1, .height = 1 }, &t);
        try testing.expectEqual(@as(u32, 0), actual.cols);
        try testing.expectEqual(@as(u32, 0), actual.rows);
        try testing.expect(placement.rect(.{ .width = 1, .height = 1 }, &t) == null);
    }
}
test "storage: generation stamps on image add and replace" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try testing.expectEqual(@as(u64, 0), s.generation);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 1, .height = 1 });
    const gen1 = s.generation;
    try testing.expect(gen1 > 0);
    const img1 = s.imageById(1).?;
    try testing.expectEqual(gen1, img1.generation);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .width = 1, .height = 1 });
    const gen2 = s.generation;
    try testing.expect(gen2 > gen1);
    try testing.expectEqual(gen2, s.imageById(2).?.generation);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 1, .height = 1 });
    const gen3 = s.generation;
    try testing.expect(gen3 > gen2);
    try testing.expectEqual(gen3, s.imageById(1).?.generation);
    try testing.expectEqual(gen2, s.imageById(2).?.generation);
}
test "storage: generation bumps on placement and delete" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    const gen_add = s.generation;
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    const gen_place = s.generation;
    try testing.expect(gen_place > gen_add);
    _ = s.imageById(1);
    _ = s.imageByNumber(1);
    try testing.expectEqual(gen_place, s.generation);
    s.delete(io, alloc, &t, .{ .all = true });
    try testing.expect(s.generation > gen_place);
}
test "storage: generation bumps when setLimit evicts or disables" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    const data = try alloc.dupe(u8, "1234");
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .data = .{ .complete = data },
    });
    const gen_add = s.generation;
    s.dirty = false;
    s.setLimit(io, alloc, t.screens.active, 1);
    try testing.expect(s.dirty);
    try testing.expect(s.generation > gen_add);
    try testing.expectEqual(@as(usize, 0), s.images.count());
    const gen_evict = s.generation;
    s.dirty = false;
    s.setLimit(io, alloc, t.screens.active, 0);
    try testing.expect(s.dirty);
    try testing.expect(s.generation > gen_evict);
}
test "storage: imageByNumber returns most recently transmitted" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .number = 7 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .number = 7 });
    try testing.expectEqual(@as(u32, 2), s.imageByNumber(7).?.id);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .number = 7 });
    try testing.expectEqual(@as(u32, 1), s.imageByNumber(7).?.id);
}
test "storage: nextGeneration is unique and monotonic" {
    const testing = std.testing;
    const a = nextGeneration(testing.io);
    const b = nextGeneration(testing.io);
    try testing.expect(b > a);
    try testing.expect(a > 0);
}
test "storage: no-op delete does not mark a mutation" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    s.delete(io, alloc, &t, .{ .all = true });
    try testing.expect(!s.dirty);
    try testing.expectEqual(@as(u64, 0), s.generation);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    const gen = s.generation;
    s.dirty = false;
    s.delete(io, alloc, &t, .{ .id = .{ .image_id = 42 } });
    try testing.expect(!s.dirty);
    try testing.expectEqual(gen, s.generation);
    s.delete(io, alloc, &t, .{ .id = .{ .image_id = 1 } });
    try testing.expect(s.dirty);
    try testing.expect(s.generation > gen);
}
test "storage: evicts images in priority order" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{ .total_limit = 192 };
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .data = .{ .complete = try alloc.dupe(u8, "*" ** 64) },
        .metadata = .{ .transient = false },
    });
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 2,
        .data = .{ .complete = try alloc.dupe(u8, "*" ** 64) },
        .metadata = .{ .transient = true },
    });
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 3,
        .data = .{ .complete = try alloc.dupe(u8, "*" ** 64) },
        .metadata = .{ .transient = true },
    });
    try s.addPlacement(
        io,
        alloc,
        t.screens.active,
        2,
        1,
        .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } },
    );
    const gen = s.generation;
    const result = s.evictImage(io, alloc, t.screens.active, 96);
    try testing.expect(s.dirty);
    try testing.expect(s.generation > gen);
    try testing.expectEqual(true, result);
    try testing.expectEqual(1, s.images.count());
    try testing.expect(!s.images.contains(1));
    try testing.expect(s.images.contains(2));
    try testing.expect(!s.images.contains(3));
}
test "storage: eviction releases placement pins" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{ .total_limit = 128 };
    defer s.deinit(alloc, t.screens.active);
    const tracked = t.screens.active.pages.countTrackedPins();
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .data = .{ .complete = try alloc.dupe(u8, "*" ** 64) },
    });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) },
    });
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 2,
        .data = .{ .complete = try alloc.dupe(u8, "*" ** 64) },
    });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) },
    });
    try testing.expectEqual(tracked + 2, t.screens.active.pages.countTrackedPins());
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 3,
        .data = .{ .complete = try alloc.dupe(u8, "*" ** 64) },
    });
    try testing.expect(!s.images.contains(1));
    try testing.expect(s.images.contains(2));
    try testing.expect(s.images.contains(3));
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expect(s.placements.contains(.{
        .image_id = 2,
        .placement_id = .{ .tag = .external, .id = 1 },
    }));
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
}
test "storage: pending image completes once and preserves age" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{ .total_limit = 16 };
    defer s.deinit(alloc, t.screens.active);
    const pending = try s.addPendingImage(io, alloc, t.screens.active, .{
        .id = 1,
        .number = 7,
        .width = 2,
        .height = 2,
        .format = .rgba,
        .data = .{ .pending = 16 },
    });
    try testing.expectEqual(@as(usize, 16), s.total_bytes);
    try testing.expectEqual(@as(u32, 1), s.imageByNumber(7).?.id);
    try testing.expect(s.imageById(1).?.data.isPending());
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) },
    });
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    const wrong = try alloc.dupe(u8, "short");
    const wrong_completed = pending.complete(&s, io, wrong);
    try testing.expect(!wrong_completed);
    defer alloc.free(wrong);
    const storage_generation = s.generation;
    s.dirty = false;
    const pixels = try alloc.dupe(u8, "*" ** 16);
    try testing.expect(pending.complete(&s, io, pixels));
    try testing.expect(s.dirty);
    try testing.expect(s.generation > storage_generation);
    try testing.expectEqual(pending.generation, s.imageById(1).?.generation);
    try testing.expectEqual(@as(usize, 16), s.total_bytes);
    try testing.expectEqualSlices(u8, pixels, s.imageById(1).?.data.bytes().?);
    const duplicate = try alloc.dupe(u8, "!" ** 16);
    const duplicate_completed = pending.complete(&s, io, duplicate);
    try testing.expect(!duplicate_completed);
    defer alloc.free(duplicate);
}
test "storage: stale pending completion loses to delete replacement and eviction" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{ .total_limit = 8 };
    defer s.deinit(alloc, t.screens.active);
    const deleted = try s.addPendingImage(io, alloc, t.screens.active, .{
        .id = 1,
        .data = .{ .pending = 4 },
    });
    s.delete(io, alloc, &t, .{ .id = .{ .delete = true, .image_id = 1 } });
    const deleted_data = try alloc.dupe(u8, "gone");
    const deleted_completed = deleted.complete(&s, io, deleted_data);
    try testing.expect(!deleted_completed);
    defer alloc.free(deleted_data);
    const replaced = try s.addPendingImage(io, alloc, t.screens.active, .{
        .id = 2,
        .data = .{ .pending = 4 },
    });
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 2,
        .data = .{ .complete = try alloc.dupe(u8, "live") },
    });
    const replaced_data = try alloc.dupe(u8, "late");
    const replaced_completed = replaced.complete(&s, io, replaced_data);
    try testing.expect(!replaced_completed);
    defer alloc.free(replaced_data);
    try testing.expectEqualStrings("live", s.imageById(2).?.data.bytes().?);
    const evicted = try s.addPendingImage(io, alloc, t.screens.active, .{
        .id = 3,
        .data = .{ .pending = 4 },
    });
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 4,
        .data = .{ .complete = try alloc.dupe(u8, "12345678") },
    });
    try testing.expect(s.imageById(3) == null);
    const evicted_data = try alloc.dupe(u8, "late");
    const evicted_completed = evicted.complete(&s, io, evicted_data);
    try testing.expect(!evicted_completed);
    defer alloc.free(evicted_data);
}
test "storage: replacement reuses pending reservation and removes placements" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{ .total_limit = 12 };
    defer s.deinit(alloc, t.screens.active);
    const tracked = t.screens.active.pages.countTrackedPins();
    const pending = try s.addPendingImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 2,
        .height = 1,
        .format = .rgba,
        .data = .{ .pending = 8 },
    });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) },
    });
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 2,
        .data = .{ .complete = try alloc.dupe(u8, "keep") },
    });
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 2,
        .height = 1,
        .format = .rgba,
        .data = .{ .complete = try alloc.dupe(u8, "12345678") },
    });
    try testing.expect(s.images.contains(1));
    try testing.expect(s.images.contains(2));
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
    try testing.expectEqual(
        @as(u30, 0),
        s.imageById(1).?.metadata.placement_count,
    );
    try testing.expectEqual(@as(usize, 12), s.total_bytes);
    const stale = try alloc.dupe(u8, "snapshot");
    const stale_completed = pending.complete(&s, io, stale);
    try testing.expect(!stale_completed);
    defer alloc.free(stale);
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .data = .{ .complete = try alloc.dupe(u8, "1234567890") },
    });
    try testing.expect(s.images.contains(1));
    try testing.expect(!s.images.contains(2));
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(@as(usize, 10), s.total_bytes);
    s.delete(io, alloc, &t, .{ .id = .{ .delete = true, .image_id = 1 } });
    try testing.expectEqual(@as(usize, 0), s.images.count());
    try testing.expectEqual(@as(usize, 0), s.placements.count());
}
test "storage: pending images share exact eviction ordering" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{ .total_limit = 192 };
    defer s.deinit(alloc, t.screens.active);
    _ = try s.addPendingImage(io, alloc, t.screens.active, .{
        .id = 1,
        .data = .{ .pending = 64 },
        .metadata = .{ .transient = false },
    });
    _ = try s.addPendingImage(io, alloc, t.screens.active, .{
        .id = 2,
        .data = .{ .pending = 64 },
        .metadata = .{ .transient = true },
    });
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 3,
        .data = .{ .complete = try alloc.dupe(u8, "*" ** 64) },
        .metadata = .{ .transient = true },
    });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) },
    });
    try testing.expect(s.evictImage(io, alloc, t.screens.active, 64));
    try testing.expect(s.images.contains(1));
    try testing.expect(s.images.contains(2));
    try testing.expect(!s.images.contains(3));
    try testing.expectEqual(@as(usize, 128), s.total_bytes);
}
test "storage: nextImageId number matches Kitty get_free_client_id" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try testing.expectEqual(@as(u32, 1), s.nextImageId(.explicit));
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try testing.expectEqual(@as(u32, 4), s.nextImageId(.explicit));
    try s.addImage(io, alloc, t.screens.active, .{ .id = 100 });
    s.delete(io, alloc, &t, .{ .id = .{ .image_id = 2, .delete = true } });
    try testing.expectEqual(@as(u32, 2), s.nextImageId(.explicit));
    s.delete(io, alloc, &t, .{ .id = .{ .image_id = 1, .delete = true } });
    try testing.expectEqual(@as(u32, 1), s.nextImageId(.explicit));
}
test "storage: nextImageId implicit skips in-use ids and zero" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2147483647 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2147483648 });
    try testing.expectEqual(@as(u32, 2147483649), s.nextImageId(.implicit));
    try testing.expectEqual(@as(u32, 2147483650), s.nextImageId(.implicit));
    s.next_image_id = std.math.maxInt(u32);
    try testing.expectEqual(std.math.maxInt(u32), s.nextImageId(.implicit));
    try testing.expectEqual(@as(u32, 1), s.nextImageId(.implicit));
}
test "storage: scroll margins placement inside region scrolls and clips at top" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 20,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 2 }) },
    });
    t.setTopAndBottomMargin(2, 5);
    t.setCursorPos(5, 1);
    try t.index();
    {
        const p = storage.placements.get(.{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 1 },
        }).?;
        const pt = t.screens.active.pages.pointFromPin(.active, p.location.pin.*).?;
        try testing.expectEqual(point.Coordinate{ .x = 0, .y = 1 }, pt.coord());
    }
    try t.index();
    {
        const p = storage.placements.get(.{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 1 },
        }).?;
        const pt = t.screens.active.pages.pointFromPin(.active, p.location.pin.*).?;
        try testing.expectEqual(point.Coordinate{ .x = 0, .y = 1 }, pt.coord());
        try testing.expectEqual(@as(u32, 10), p.source_y);
        try testing.expectEqual(@as(u32, 10), p.source_height);
    }
    try t.index();
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expectEqual(@as(usize, 1), storage.images.count());
}
test "storage: scroll margins placement straddling region does not move" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 30,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) },
    });
    t.setTopAndBottomMargin(1, 2);
    t.setCursorPos(2, 1);
    try t.index();
    const p = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }).?;
    const pt = t.screens.active.pages.pointFromPin(.active, p.location.pin.*).?;
    try testing.expectEqual(point.Coordinate{ .x = 0, .y = 0 }, pt.coord());
    try testing.expectEqual(@as(u32, 0), p.source_y);
    try testing.expectEqual(@as(u32, 0), p.source_height);
}
test "storage: scroll margins placement below region does not move" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 5 }) },
    });
    t.setTopAndBottomMargin(1, 4);
    t.setCursorPos(4, 1);
    try t.index();
    try t.index();
    const p = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }).?;
    const pt = t.screens.active.pages.pointFromPin(.active, p.location.pin.*).?;
    try testing.expectEqual(point.Coordinate{ .x = 0, .y = 5 }, pt.coord());
}
test "storage: scroll margins reverse index clips at bottom" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 20,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 3 }) },
    });
    t.setTopAndBottomMargin(2, 5);
    t.setCursorPos(2, 1);
    t.reverseIndex();
    {
        const p = storage.placements.get(.{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 1 },
        }).?;
        const pt = t.screens.active.pages.pointFromPin(.active, p.location.pin.*).?;
        try testing.expectEqual(point.Coordinate{ .x = 0, .y = 4 }, pt.coord());
        try testing.expectEqual(@as(u32, 0), p.source_y);
        try testing.expectEqual(@as(u32, 10), p.source_height);
    }
    t.reverseIndex();
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
}
test "storage: scroll margins scaled placement clips proportionally" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 40,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 1 }) },
        .columns = 1,
        .rows = 2,
    });
    t.setTopAndBottomMargin(2, 3);
    t.setCursorPos(3, 1);
    try t.index();
    const p = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }).?;
    const pt = t.screens.active.pages.pointFromPin(.active, p.location.pin.*).?;
    try testing.expectEqual(point.Coordinate{ .x = 0, .y = 1 }, pt.coord());
    try testing.expectEqual(@as(u32, 20), p.source_y);
    try testing.expectEqual(@as(u32, 20), p.source_height);
    try testing.expectEqual(@as(u32, 1), p.rows);
    try testing.expectEqual(@as(u32, 1), p.columns);
}
test "storage: scroll margins left/right margins respect columns" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 2 }) },
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 2, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 2, .y = 2 }) },
    });
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(2, 8);
    try t.scrollUp(1);
    {
        const p = storage.placements.get(.{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 1 },
        }).?;
        const pt = t.screens.active.pages.pointFromPin(.active, p.location.pin.*).?;
        try testing.expectEqual(point.Coordinate{ .x = 0, .y = 2 }, pt.coord());
    }
    {
        const p = storage.placements.get(.{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 2 },
        }).?;
        const pt = t.screens.active.pages.pointFromPin(.active, p.location.pin.*).?;
        try testing.expectEqual(point.Coordinate{ .x = 2, .y = 1 }, pt.coord());
    }
}
test "storage: scroll margins insert/delete lines do not move placements" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 2 }) },
    });
    t.setTopAndBottomMargin(2, 5);
    t.setCursorPos(2, 1);
    t.deleteLines(1);
    {
        const p = storage.placements.get(.{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 1 },
        }).?;
        const pt = t.screens.active.pages.pointFromPin(.active, p.location.pin.*).?;
        try testing.expectEqual(point.Coordinate{ .x = 0, .y = 2 }, pt.coord());
    }
    t.insertLines(1);
    {
        const p = storage.placements.get(.{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 1 },
        }).?;
        const pt = t.screens.active.pages.pointFromPin(.active, p.location.pin.*).?;
        try testing.expectEqual(point.Coordinate{ .x = 0, .y = 2 }, pt.coord());
    }
}
test "storage: scroll without margins moves placement into scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 20,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) },
    });
    t.setCursorPos(6, 1);
    try t.index();
    const p = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }).?;
    try testing.expect(t.screens.active.pages.pointFromPin(
        .active,
        p.location.pin.*,
    ) == null);
    const pt = t.screens.active.pages.pointFromPin(.screen, p.location.pin.*).?;
    try testing.expectEqual(point.Coordinate{ .x = 0, .y = 0 }, pt.coord());
}
test "storage: scroll margins large scroll deletes inside placement" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 2 }) },
    });
    t.setTopAndBottomMargin(2, 5);
    try t.scrollUp(10);
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
}
test "storage: scroll margins straddling placement pin inside region restored" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 20,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 4 }) },
    });
    t.setTopAndBottomMargin(2, 5);
    t.setCursorPos(5, 1);
    try t.index();
    const p = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }).?;
    const pt = t.screens.active.pages.pointFromPin(.active, p.location.pin.*).?;
    try testing.expectEqual(point.Coordinate{ .x = 0, .y = 4 }, pt.coord());
    try testing.expectEqual(@as(u32, 0), p.source_y);
    try testing.expectEqual(@as(u32, 0), p.source_height);
}
test "storage: scroll margins multi-line scroll up with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 2 }) },
    });
    t.setTopAndBottomMargin(1, 4);
    try t.scrollUp(2);
    {
        const p = storage.placements.get(.{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 1 },
        }).?;
        const pt = t.screens.active.pages.pointFromPin(.active, p.location.pin.*).?;
        try testing.expectEqual(point.Coordinate{ .x = 0, .y = 0 }, pt.coord());
    }
    try t.scrollUp(2);
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
}
test "storage: resolveChain accumulates offsets to the pin root" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) },
    });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{
        .location = .{ .relative = .{
            .parent = .{
                .image_id = 1,
                .placement_id = .{ .tag = .external, .id = 1 },
            },
            .horizontal_offset = 2,
            .vertical_offset = 1,
        } },
    });
    try s.addPlacement(io, alloc, t.screens.active, 1, 3, .{
        .location = .{ .relative = .{
            .parent = .{
                .image_id = 1,
                .placement_id = .{ .tag = .external, .id = 2 },
            },
            .horizontal_offset = -1,
            .vertical_offset = 4,
        } },
    });
    const grandchild = s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 3 },
    }).?;
    const chain = s.resolveChain(grandchild.location.relative).?;
    try testing.expect(chain.root_key.eql(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }));
    try testing.expect(chain.root.location == .pin);
    try testing.expectEqual(@as(i32, 1), chain.horizontal_offset);
    try testing.expectEqual(@as(i32, 5), chain.vertical_offset);
}
test "storage: resolveChain finds virtual roots" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .virtual = {} },
    });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{
        .location = .{ .relative = .{
            .parent = .{
                .image_id = 1,
                .placement_id = .{ .tag = .external, .id = 1 },
            },
            .horizontal_offset = 1,
        } },
    });
    const child = s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 2 },
    }).?;
    const chain = s.resolveChain(child.location.relative).?;
    try testing.expect(chain.root.location == .virtual);
    try testing.expect(chain.root_key.eql(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }));
    try testing.expectEqual(@as(i32, 1), chain.horizontal_offset);
    try testing.expectEqual(@as(i32, 0), chain.vertical_offset);
}
test "storage: eviction removes orphaned relative placements" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    s.total_limit = 8;
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 2,
        .height = 1,
        .data = .{ .complete = try alloc.dupe(u8, &.{ 0, 0, 0, 0, 0, 0 }) },
    });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) },
    });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{
        .location = .{ .relative = .{ .parent = .{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 1 },
        } } },
    });
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 3,
        .width = 2,
        .height = 1,
        .data = .{ .complete = try alloc.dupe(u8, &.{ 0, 0, 0, 0, 0, 0 }) },
    });
    try testing.expect(s.imageById(1) == null);
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expect(s.imageById(2) != null);
}
test "storage: placeholderTarget lookup" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 5, .{
        .location = .{ .virtual = {} },
    });
    {
        const target = s.placeholderTarget(1, 5).?;
        const expected: ImageStorage.PlacementKey = .{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 5 },
        };
        try testing.expectEqual(expected, target.key);
        try testing.expect(target.placement.location == .virtual);
    }
    {
        const target = s.placeholderTarget(1, 0).?;
        const expected: ImageStorage.PlacementKey = .{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 5 },
        };
        try testing.expectEqual(expected, target.key);
    }
    try testing.expect(s.placeholderTarget(1, 9) == null);
    try testing.expect(s.placeholderTarget(2, 0) == null);
    try s.addPlacement(io, alloc, t.screens.active, 1, 3, .{
        .location = .{ .virtual = {} },
    });
    {
        const expected: ImageStorage.PlacementKey = .{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 3 },
        };
        try testing.expectEqual(expected, s.placeholderTarget(1, 0).?.key);
    }
}
test "storage: animation tick advances and schedules" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = .{ .complete = try alloc.dupe(u8, &.{ 255, 0, 0, 255 }) },
    });
    const img = s.images.getPtr(1).?;
    const anim = try alloc.create(animation.Animation);
    anim.* = .{ .state = .running };
    img.animation = anim;
    try anim.frames.append(alloc, .{
        .data = try alloc.dupe(u8, &.{ 0, 0, 255, 255 }),
        .gap_ms = 40,
    });
    try testing.expect(s.animationTick(io, 0) == null);
    try testing.expectEqual(@as(u32, 0), anim.current_index);
    try s.addPlacement(io, alloc, t.screens.active, 1, 0, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) },
    });
    const gen1 = img.generation;
    s.dirty = false;
    try testing.expectEqual(@as(?u64, 40), s.animationTick(io, 0));
    try testing.expectEqual(@as(u32, 1), anim.current_index);
    try testing.expect(img.generation > gen1);
    try testing.expect(s.dirty);
    const gen2 = img.generation;
    try testing.expectEqual(@as(?u64, 30), s.animationTick(io, 10));
    try testing.expectEqual(gen2, img.generation);
    try testing.expectEqual(@as(?u64, 40), s.animationTick(io, 40));
    try testing.expectEqual(@as(u32, 1), anim.current_index);
    try testing.expectEqual(@as(u32, 1), anim.current_loop);
}
test "storage: animation tick loading state parks on last frame" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = .{ .complete = try alloc.dupe(u8, &.{ 255, 0, 0, 255 }) },
    });
    const anim = try alloc.create(animation.Animation);
    anim.* = .{ .state = .loading };
    s.images.getPtr(1).?.animation = anim;
    try anim.frames.append(alloc, .{
        .data = try alloc.dupe(u8, &.{ 0, 0, 255, 255 }),
        .gap_ms = 40,
    });
    try s.addPlacement(io, alloc, t.screens.active, 1, 0, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) },
    });
    try testing.expectEqual(@as(?u64, 40), s.animationTick(io, 0));
    try testing.expectEqual(@as(u32, 1), anim.current_index);
    try testing.expect(s.animationTick(io, 100) == null);
    try testing.expectEqual(@as(u32, 1), anim.current_index);
    try testing.expectEqual(@as(u32, 0), anim.current_loop);
    try anim.frames.append(alloc, .{
        .data = try alloc.dupe(u8, &.{ 0, 255, 0, 255 }),
        .gap_ms = 25,
    });
    try testing.expectEqual(@as(?u64, 25), s.animationTick(io, 150));
    try testing.expectEqual(@as(u32, 2), anim.current_index);
}
test "storage: animation tick exhausts loop budget" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = .{ .complete = try alloc.dupe(u8, &.{ 255, 0, 0, 255 }) },
    });
    const anim = try alloc.create(animation.Animation);
    anim.* = .{
        .state = .running,
        .root_gap_ms = 10,
        .max_loops = 1,
    };
    s.images.getPtr(1).?.animation = anim;
    try anim.frames.append(alloc, .{
        .data = try alloc.dupe(u8, &.{ 0, 0, 255, 255 }),
        .gap_ms = 40,
    });
    try s.addPlacement(io, alloc, t.screens.active, 1, 0, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) },
    });
    try testing.expectEqual(@as(?u64, 10), s.animationTick(io, 0));
    try testing.expectEqual(@as(u32, 0), anim.current_index);
    try testing.expectEqual(@as(?u64, 40), s.animationTick(io, 10));
    try testing.expectEqual(@as(u32, 1), anim.current_index);
    try testing.expect(s.animationTick(io, 50) == null);
    try testing.expectEqual(@as(u32, 1), anim.current_index);
    try testing.expect(s.animationTick(io, 500) == null);
}
test "storage: animation tick ignores ineligible animations" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = .{ .complete = try alloc.dupe(u8, &.{ 255, 0, 0, 255 }) },
    });
    const anim = try alloc.create(animation.Animation);
    anim.* = .{};
    s.images.getPtr(1).?.animation = anim;
    try anim.frames.append(alloc, .{
        .data = try alloc.dupe(u8, &.{ 0, 0, 255, 255 }),
        .gap_ms = 40,
    });
    try s.addPlacement(io, alloc, t.screens.active, 1, 0, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) },
    });
    try testing.expect(s.animationTick(io, 0) == null);
    anim.state = .running;
    anim.frames.items[0].gap_ms = 0;
    try testing.expect(s.animationTick(io, 0) == null);
    try testing.expectEqual(@as(u32, 0), anim.current_index);
}
test "storage: animation tick re-anchors a restarted clock" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = .{ .complete = try alloc.dupe(u8, &.{ 255, 0, 0, 255 }) },
    });
    const anim = try alloc.create(animation.Animation);
    anim.* = .{
        .state = .running,
        .current_index = 1,
        .frame_shown_at_ms = 1000,
    };
    s.images.getPtr(1).?.animation = anim;
    try anim.frames.append(alloc, .{
        .data = try alloc.dupe(u8, &.{ 0, 0, 255, 255 }),
        .gap_ms = 40,
    });
    try s.addPlacement(io, alloc, t.screens.active, 1, 0, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) },
    });
    try testing.expectEqual(@as(?u64, 40), s.animationTick(io, 5));
    try testing.expectEqual(@as(?u64, 5), anim.frame_shown_at_ms);
}
