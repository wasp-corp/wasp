const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const wuffs = @import("wuffs");
const terminal = @import("../terminal/main.zig");
const global = @import("../global.zig");
const Renderer = @import("../renderer.zig").Renderer;
const GraphicsAPI = Renderer.API;
const Texture = GraphicsAPI.Texture;
const CellSize = @import("size.zig").CellSize;
const Overlay = @import("Overlay.zig");
const log = std.log.scoped(.renderer_image);
pub const State = struct {
    images: ImageMap,
    kitty_placements: std.ArrayListUnmanaged(Placement),
    kitty_bg_end: u32,
    kitty_text_end: u32,
    kitty_virtual: bool,
    overlay_placements: std.ArrayListUnmanaged(Placement),
    pub const empty: State = .{
        .images = .empty,
        .kitty_placements = .empty,
        .kitty_bg_end = 0,
        .kitty_text_end = 0,
        .kitty_virtual = false,
        .overlay_placements = .empty,
    };
    pub fn deinit(self: *State, alloc: Allocator) void {
        {
            var it = self.images.iterator();
            while (it.next()) |kv| kv.value_ptr.image.deinit(alloc);
            self.images.deinit(alloc);
        }
        self.kitty_placements.deinit(alloc);
        self.overlay_placements.deinit(alloc);
    }
    pub fn upload(
        self: *State,
        alloc: Allocator,
        api: *GraphicsAPI,
    ) bool {
        var success: bool = true;
        var image_it = self.images.iterator();
        while (image_it.next()) |kv| {
            const img = &kv.value_ptr.image;
            if (img.isUnloading()) {
                img.deinit(alloc);
                self.images.removeByPtr(kv.key_ptr);
                continue;
            }
            if (img.isPending()) {
                img.upload(
                    alloc,
                    api,
                ) catch |err| {
                    log.warn("error uploading image to GPU err={}", .{err});
                    success = false;
                };
            }
        }
        return success;
    }
    pub const DrawPlacements = enum {
        kitty_below_bg,
        kitty_below_text,
        kitty_above_text,
        overlay,
    };
    pub fn draw(
        self: *State,
        api: *GraphicsAPI,
        pipeline: GraphicsAPI.Pipeline,
        pass: *GraphicsAPI.RenderPass,
        placement_type: DrawPlacements,
    ) void {
        const placements: []const Placement = switch (placement_type) {
            .kitty_below_bg => self.kitty_placements.items[0..self.kitty_bg_end],
            .kitty_below_text => self.kitty_placements.items[self.kitty_bg_end..self.kitty_text_end],
            .kitty_above_text => self.kitty_placements.items[self.kitty_text_end..],
            .overlay => self.overlay_placements.items,
        };
        for (placements) |p| {
            const image = self.images.get(p.image_id) orelse {
                log.warn("image not found for placement image_id={}", .{p.image_id});
                continue;
            };
            const texture = switch (image.image) {
                .ready,
                .unload_ready,
                => |t| t,
                else => {
                    log.warn("image not ready for placement image_id={}", .{p.image_id});
                    continue;
                },
            };
            var buf = GraphicsAPI.Buffer(GraphicsAPI.shaders.Image).initFill(
                api.imageBufferOptions(),
                &.{.{
                    .grid_pos = .{
                        @as(f32, @floatFromInt(p.x)),
                        @as(f32, @floatFromInt(p.y)),
                    },
                    .cell_offset = .{
                        @as(f32, @floatFromInt(p.cell_offset_x)),
                        @as(f32, @floatFromInt(p.cell_offset_y)),
                    },
                    .source_rect = .{
                        @as(f32, @floatFromInt(p.source_x)),
                        @as(f32, @floatFromInt(p.source_y)),
                        @as(f32, @floatFromInt(p.source_width)),
                        @as(f32, @floatFromInt(p.source_height)),
                    },
                    .dest_size = .{
                        @as(f32, @floatFromInt(p.width)),
                        @as(f32, @floatFromInt(p.height)),
                    },
                }},
            ) catch |err| {
                log.warn("error creating image vertex buffer err={}", .{err});
                continue;
            };
            defer buf.deinit();
            pass.step(.{
                .pipeline = pipeline,
                .buffers = &.{buf.buffer},
                .textures = &.{texture},
                .draw = .{
                    .type = .triangle_strip,
                    .vertex_count = 4,
                },
            });
        }
    }
    pub fn overlayUpdate(
        self: *State,
        alloc: Allocator,
        overlay_: ?Overlay,
    ) !void {
        const overlay = overlay_ orelse {
            if (self.images.getPtr(.overlay)) |data| {
                data.image.markForUnload();
            }
            return;
        };
        const generation = terminal.kitty.graphics.nextGeneration(global.io());
        self.overlay_placements.clearRetainingCapacity();
        try self.overlay_placements.ensureUnusedCapacity(alloc, 1);
        const pending = overlay.pendingImage();
        try self.prepImage(
            alloc,
            .overlay,
            generation,
            pending,
        );
        errdefer comptime unreachable;
        self.overlay_placements.appendAssumeCapacity(.{
            .image_id = .overlay,
            .x = 0,
            .y = 0,
            .z = 0,
            .width = pending.width,
            .height = pending.height,
            .cell_offset_x = 0,
            .cell_offset_y = 0,
            .source_x = 0,
            .source_y = 0,
            .source_width = pending.width,
            .source_height = pending.height,
        });
    }
    pub fn kittyRequiresUpdate(
        self: *const State,
        t: *const terminal.Terminal,
    ) bool {
        if (t.screens.active.kitty_images.dirty) return true;
        if (self.kitty_virtual) return true;
        return false;
    }
    pub fn kittyUpdate(
        self: *State,
        alloc: Allocator,
        t: *const terminal.Terminal,
        cell_size: CellSize,
    ) void {
        const storage = &t.screens.active.kitty_images;
        defer storage.dirty = false;
        self.kitty_placements.clearRetainingCapacity();
        self.kitty_virtual = false;
        {
            var it = self.images.iterator();
            while (it.next()) |kv| {
                switch (kv.key_ptr.*) {
                    .kitty => |id| if (storage.imageById(id)) |image| {
                        if (image.data.isPending()) {
                            kv.value_ptr.image.markForUnload();
                        }
                    } else {
                        kv.value_ptr.image.markForUnload();
                    },
                    .overlay => {},
                }
            }
        }
        const top = t.screens.active.pages.getTopLeft(.viewport);
        const bot = t.screens.active.pages.getBottomRight(.viewport).?;
        const top_y = t.screens.active.pages.pointFromPin(.screen, top).?.screen.y;
        const bot_y = t.screens.active.pages.pointFromPin(.screen, bot).?.screen.y;
        var pending_relative: std.ArrayListUnmanaged(struct {
            image_id: u32,
            p: terminal.kitty.graphics.ImageStorage.Placement,
            root_key: terminal.kitty.graphics.ImageStorage.PlacementKey,
            horizontal_offset: i32,
            vertical_offset: i32,
        }) = .empty;
        defer pending_relative.deinit(alloc);
        var it = storage.placements.iterator();
        while (it.next()) |kv| {
            const p = kv.value_ptr;
            const origin: Origin = switch (p.location) {
                .pin => |pin| .{ .pin = pin },
                .virtual => {
                    self.kitty_virtual = true;
                    continue;
                },
                .relative => |rel| origin: {
                    const chain = storage.resolveChain(rel) orelse continue;
                    switch (chain.root.location) {
                        .pin => |root_pin| break :origin .{
                            .pin = root_pin,
                            .horizontal_offset = chain.horizontal_offset,
                            .vertical_offset = chain.vertical_offset,
                        },
                        .virtual => {
                            self.kitty_virtual = true;
                            pending_relative.append(alloc, .{
                                .image_id = kv.key_ptr.image_id,
                                .p = p.*,
                                .root_key = chain.root_key,
                                .horizontal_offset = chain.horizontal_offset,
                                .vertical_offset = chain.vertical_offset,
                            }) catch |err| {
                                log.warn("error deferring relative placement err={}", .{err});
                            };
                            continue;
                        },
                        .relative => unreachable,
                    }
                },
            };
            const image = storage.imageById(kv.key_ptr.image_id) orelse {
                log.warn(
                    "missing image for placement, ignoring image_id={}",
                    .{kv.key_ptr.image_id},
                );
                continue;
            };
            self.prepKittyPlacement(
                alloc,
                t,
                top_y,
                bot_y,
                &image,
                p,
                origin,
            ) catch |err| {
                log.warn("error preparing kitty placement err={}", .{err});
            };
        }
        if (self.kitty_virtual) {
            var virtual_origins: std.AutoHashMapUnmanaged(
                terminal.kitty.graphics.ImageStorage.PlacementKey,
                struct { x: u32, y: u32 },
            ) = .empty;
            defer virtual_origins.deinit(alloc);
            var v_it = terminal.kitty.graphics.unicode.placementIterator(top, bot);
            while (v_it.next()) |virtual_p| {
                self.prepKittyVirtualPlacement(
                    alloc,
                    t,
                    &virtual_p,
                    cell_size,
                ) catch |err| {
                    log.warn("error preparing kitty placement err={}", .{err});
                };
                if (pending_relative.items.len > 0) fold: {
                    const target = storage.placeholderTarget(
                        virtual_p.image_id,
                        virtual_p.placement_id,
                    ) orelse break :fold;
                    const vp = t.screens.active.pages.pointFromPin(
                        .viewport,
                        virtual_p.pin,
                    ) orelse break :fold;
                    const gop = virtual_origins.getOrPut(
                        alloc,
                        target.key,
                    ) catch |err| {
                        log.warn("error tracking virtual origin err={}", .{err});
                        break :fold;
                    };
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .{ .x = vp.viewport.x, .y = vp.viewport.y };
                    } else {
                        gop.value_ptr.x = @min(gop.value_ptr.x, vp.viewport.x);
                        gop.value_ptr.y = @min(gop.value_ptr.y, vp.viewport.y);
                    }
                }
            }
            for (pending_relative.items) |pr| {
                const origin = virtual_origins.get(pr.root_key) orelse continue;
                const image = storage.imageById(pr.image_id) orelse continue;
                if (image.data.isPending()) continue;
                const grid = pr.p.gridSize(image, t);
                if (grid.cols == 0 or grid.rows == 0) continue;
                const x: i64 = @as(i64, origin.x) + pr.horizontal_offset;
                const y: i64 = @as(i64, origin.y) + pr.vertical_offset;
                if (y >= t.rows or y + grid.rows - 1 < 0) continue;
                if (x >= t.cols or x + grid.cols - 1 < 0) continue;
                self.appendKittyPlacement(
                    alloc,
                    t,
                    &image,
                    &pr.p,
                    std.math.cast(i32, x) orelse continue,
                    std.math.cast(i32, y) orelse continue,
                ) catch |err| {
                    log.warn("error preparing kitty placement err={}", .{err});
                };
            }
        }
        std.mem.sortUnstable(
            Placement,
            self.kitty_placements.items,
            {},
            struct {
                fn lessThan(
                    ctx: void,
                    lhs: Placement,
                    rhs: Placement,
                ) bool {
                    _ = ctx;
                    return lhs.z < rhs.z or
                        (lhs.z == rhs.z and lhs.image_id.zLessThan(rhs.image_id));
                }
            }.lessThan,
        );
        const bg_limit = std.math.minInt(i32) / 2;
        var bg_end: ?u32 = null;
        var text_end: ?u32 = null;
        for (self.kitty_placements.items, 0..) |p, i| {
            if (bg_end == null and p.z >= bg_limit) bg_end = @intCast(i);
            if (text_end == null and p.z >= 0) text_end = @intCast(i);
        }
        self.kitty_bg_end =
            bg_end orelse @intCast(self.kitty_placements.items.len);
        self.kitty_text_end =
            text_end orelse @intCast(self.kitty_placements.items.len);
    }
    const PrepImageError = error{
        OutOfMemory,
        ImageConversionError,
    };
    const Origin = struct {
        pin: *const terminal.Pin,
        horizontal_offset: i32 = 0,
        vertical_offset: i32 = 0,
    };
    fn prepKittyPlacement(
        self: *State,
        alloc: Allocator,
        t: *const terminal.Terminal,
        top_y: u32,
        bot_y: u32,
        image: *const terminal.kitty.graphics.Image,
        p: *const terminal.kitty.graphics.ImageStorage.Placement,
        origin: Origin,
    ) PrepImageError!void {
        if (image.data.isPending()) return;
        if (origin.pin.garbage) return;
        const grid = p.gridSize(image.*, t);
        if (grid.cols == 0 or grid.rows == 0) return;
        const origin_y = t.screens.active.pages.pointFromPin(
            .screen,
            origin.pin.*,
        ).?.screen.y;
        const img_top_y: i64 = @as(i64, origin_y) + origin.vertical_offset;
        const img_bot_y: i64 = img_top_y + grid.rows - 1;
        const img_left_x: i64 = @as(i64, origin.pin.x) + origin.horizontal_offset;
        const img_right_x: i64 = img_left_x + grid.cols - 1;
        if (img_top_y > bot_y or img_bot_y < top_y) return;
        if (img_left_x >= t.cols or img_right_x < 0) return;
        const y_pos = std.math.cast(i32, img_top_y - top_y) orelse return;
        const x_pos = std.math.cast(i32, img_left_x) orelse return;
        try self.appendKittyPlacement(alloc, t, image, p, x_pos, y_pos);
    }
    fn appendKittyPlacement(
        self: *State,
        alloc: Allocator,
        t: *const terminal.Terminal,
        image: *const terminal.kitty.graphics.Image,
        p: *const terminal.kitty.graphics.ImageStorage.Placement,
        x: i32,
        y: i32,
    ) PrepImageError!void {
        try self.prepKittyImage(alloc, image);
        const dest_size = p.pixelSize(image.*, t);
        const cell_offset = p.cellOffset(t);
        const source = p.sourceRect(image.*);
        if (dest_size.width > 0 and dest_size.height > 0) {
            try self.kitty_placements.append(alloc, .{
                .image_id = .{ .kitty = image.id },
                .x = x,
                .y = y,
                .z = p.z,
                .width = dest_size.width,
                .height = dest_size.height,
                .cell_offset_x = cell_offset.x,
                .cell_offset_y = cell_offset.y,
                .source_x = source.x,
                .source_y = source.y,
                .source_width = source.width,
                .source_height = source.height,
            });
        }
    }
    fn prepKittyVirtualPlacement(
        self: *State,
        alloc: Allocator,
        t: *const terminal.Terminal,
        p: *const terminal.kitty.graphics.unicode.Placement,
        cell_size: CellSize,
    ) PrepImageError!void {
        const storage = &t.screens.active.kitty_images;
        const image = storage.imageById(p.image_id) orelse {
            log.warn(
                "missing image for virtual placement, ignoring image_id={}",
                .{p.image_id},
            );
            return;
        };
        if (image.data.isPending()) return;
        const rp = p.renderPlacement(
            storage,
            &image,
            cell_size.width,
            cell_size.height,
        ) catch |err| {
            log.warn("error rendering virtual placement err={}", .{err});
            return;
        };
        if (rp.dest_width == 0 or rp.dest_height == 0) return;
        const viewport: terminal.point.Point = t.screens.active.pages.pointFromPin(
            .viewport,
            rp.top_left,
        ) orelse {
            unreachable;
        };
        try self.prepKittyImage(alloc, &image);
        try self.kitty_placements.append(alloc, .{
            .image_id = .{ .kitty = image.id },
            .x = @intCast(rp.top_left.x),
            .y = @intCast(viewport.viewport.y),
            .z = -1,
            .width = rp.dest_width,
            .height = rp.dest_height,
            .cell_offset_x = rp.offset_x,
            .cell_offset_y = rp.offset_y,
            .source_x = rp.source_x,
            .source_y = rp.source_y,
            .source_width = rp.source_width,
            .source_height = rp.source_height,
        });
    }
    fn prepImage(
        self: *State,
        alloc: Allocator,
        id: Id,
        generation: u64,
        pending: Image.Pending,
    ) PrepImageError!void {
        const gop = try self.images.getOrPut(alloc, id);
        if (gop.found_existing and
            gop.value_ptr.generation == generation)
        {
            return;
        }
        const new_image: Image = if (pending.convertCopy(alloc)) |v| v else |_| {
            if (!gop.found_existing) {
                _ = self.images.remove(id);
            } else {
                gop.value_ptr.image.markForUnload();
            }
            return error.OutOfMemory;
        };
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .image = new_image,
                .generation = 0,
            };
        } else {
            gop.value_ptr.image.markForReplace(
                alloc,
                new_image,
            );
        }
        errdefer gop.value_ptr.image.markForUnload();
        gop.value_ptr.image.getPendingPointer().?.prepForUpload(alloc) catch |err| {
            log.warn("error preparing image for upload err={}", .{err});
            return error.ImageConversionError;
        };
        gop.value_ptr.generation = generation;
    }
    fn prepKittyImage(
        self: *State,
        alloc: Allocator,
        image: *const terminal.kitty.graphics.Image,
    ) PrepImageError!void {
        const data = image.renderData().bytes() orelse unreachable;
        try self.prepImage(
            alloc,
            .{ .kitty = image.id },
            image.generation,
            .{
                .width = image.width,
                .height = image.height,
                .pixel_format = switch (image.format) {
                    .gray => .gray,
                    .gray_alpha => .gray_alpha,
                    .rgb => .rgb,
                    .rgba => .rgba,
                    .png => unreachable, 
                },
                .data = @constCast(data.ptr),
            },
        );
    }
};
pub const Placement = struct {
    image_id: Id,
    x: i32,
    y: i32,
    z: i32,
    width: u32,
    height: u32,
    cell_offset_x: u32,
    cell_offset_y: u32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
};
pub const Id = union(enum) {
    kitty: u32,
    overlay,
    pub fn zLessThan(lhs: Id, rhs: Id) bool {
        if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) {
            return switch (lhs) {
                .kitty => true,
                .overlay => false,
            };
        }
        switch (lhs) {
            .kitty => |lhs_id| {
                const rhs_id = rhs.kitty;
                return lhs_id < rhs_id;
            },
            .overlay => return false,
        }
    }
};
pub const ImageMap = std.AutoHashMapUnmanaged(Id, struct {
    image: Image,
    generation: u64,
});
pub const Image = union(enum) {
    pending: Pending,
    replace: Replace,
    ready: Texture,
    unload_pending: Pending,
    unload_ready: Texture,
    unload_replace: Replace,
    pub const Replace = struct {
        texture: Texture,
        pending: Pending,
    };
    pub const Pending = struct {
        height: u32,
        width: u32,
        pixel_format: PixelFormat,
        data: [*]u8,
        pub fn dataSlice(self: Pending) []u8 {
            return self.data[0..self.len()];
        }
        pub fn len(self: Pending) usize {
            return self.width * self.height * self.pixel_format.bpp();
        }
        pub const PixelFormat = enum {
            gray,
            gray_alpha,
            rgb,
            bgr,
            rgba,
            bgra,
            pub inline fn bpp(self: PixelFormat) usize {
                return switch (self) {
                    .gray => 1,
                    .gray_alpha => 2,
                    .rgb => 3,
                    .bgr => 3,
                    .rgba => 4,
                    .bgra => 4,
                };
            }
        };
        fn convertReplace(self: *Image.Pending, alloc: Allocator) wuffs.Error!void {
            if (self.pixel_format == .rgba) return;
            const data = self.dataSlice();
            const rgba = try switch (self.pixel_format) {
                .gray => wuffs.swizzle.gToRgba(alloc, data),
                .gray_alpha => wuffs.swizzle.gaToRgba(alloc, data),
                .rgb => wuffs.swizzle.rgbToRgba(alloc, data),
                .bgr => wuffs.swizzle.bgrToRgba(alloc, data),
                .rgba => unreachable,
                .bgra => wuffs.swizzle.bgraToRgba(alloc, data),
            };
            alloc.free(data);
            self.data = rgba.ptr;
            self.pixel_format = .rgba;
        }
        fn convertCopy(self: *const Image.Pending, alloc: Allocator) wuffs.Error!Image {
            const data = self.dataSlice();
            const rgba = try switch (self.pixel_format) {
                .gray => wuffs.swizzle.gToRgba(alloc, data),
                .gray_alpha => wuffs.swizzle.gaToRgba(alloc, data),
                .rgb => wuffs.swizzle.rgbToRgba(alloc, data),
                .bgr => wuffs.swizzle.bgrToRgba(alloc, data),
                .rgba => alloc.dupe(u8, data),
                .bgra => wuffs.swizzle.bgraToRgba(alloc, data),
            };
            const result: Image = .{ .pending = .{
                .height = self.height,
                .width = self.width,
                .pixel_format = .rgba,
                .data = rgba.ptr,
            } };
            return result;
        }
        fn prepForUpload(self: *Image.Pending, alloc: Allocator) wuffs.Error!void {
            try self.convertReplace(alloc);
        }
    };
    pub fn deinit(self: Image, alloc: Allocator) void {
        switch (self) {
            .pending,
            .unload_pending,
            => |p| alloc.free(p.dataSlice()),
            .replace, .unload_replace => |r| {
                alloc.free(r.pending.dataSlice());
                r.texture.deinit();
            },
            .ready,
            .unload_ready,
            => |t| t.deinit(),
        }
    }
    pub fn markForUnload(self: *Image) void {
        self.* = switch (self.*) {
            .unload_pending,
            .unload_replace,
            .unload_ready,
            => return,
            .ready => |t| .{ .unload_ready = t },
            .pending => |p| .{ .unload_pending = p },
            .replace => |r| .{ .unload_replace = r },
        };
    }
    pub fn markForReplace(self: *Image, alloc: Allocator, img: Image) void {
        assert(img.isPending());
        if (self.getPending()) |p| {
            alloc.free(p.dataSlice());
        }
        if (self.getTexture()) |t| {
            self.* = .{ .replace = .{
                .texture = t,
                .pending = img.getPending().?,
            } };
            return;
        }
        self.* = .{ .pending = img.getPending().? };
    }
    pub fn isPending(self: Image) bool {
        return self.getPending() != null;
    }
    pub fn hasTexture(self: Image) bool {
        return self.getTexture() != null;
    }
    pub fn isUnloading(self: Image) bool {
        return switch (self) {
            .unload_pending,
            .unload_replace,
            .unload_ready,
            => true,
            .pending,
            .replace,
            .ready,
            => false,
        };
    }
    pub fn upload(
        self: *Image,
        alloc: Allocator,
        api: *const GraphicsAPI,
    ) (wuffs.Error || error{
        UploadFailed,
    })!void {
        assert(self.isPending());
        const p = self.getPendingPointer().?;
        try p.prepForUpload(alloc);
        const texture = Texture.init(
            api.imageTextureOptions(.rgba, true),
            @intCast(p.width),
            @intCast(p.height),
            p.dataSlice(),
        ) catch return error.UploadFailed;
        errdefer comptime unreachable;
        self.deinit(alloc);
        self.* = .{ .ready = texture };
    }
    fn getPending(self: Image) ?Pending {
        return switch (self) {
            .pending,
            .unload_pending,
            => |p| p,
            .replace,
            .unload_replace,
            => |r| r.pending,
            else => null,
        };
    }
    fn getTexture(self: Image) ?Texture {
        return switch (self) {
            .ready,
            .unload_ready,
            => |t| t,
            .replace,
            .unload_replace,
            => |r| r.texture,
            else => null,
        };
    }
    fn getPendingPointer(self: *Image) ?*Pending {
        return switch (self.*) {
            .pending => return &self.pending,
            .unload_pending => return &self.unload_pending,
            .replace => return &self.replace.pending,
            .unload_replace => return &self.unload_replace.pending,
            else => null,
        };
    }
};
test "kitty renderer ignores pending payloads and removes replaced placements" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    t.width_px = 30;
    t.height_px = 30;
    var state: State = .empty;
    defer state.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    const tracked = t.screens.active.pages.countTrackedPins();
    const pending = try storage.addPendingImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = .{ .pending = 4 },
    });
    const pin = try t.screens.active.pages.trackPin(
        t.screens.active.cursor.page_pin.*,
    );
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = pin },
        .columns = 1,
        .rows = 1,
    });
    state.kittyUpdate(alloc, &t, .{ .width = 10, .height = 10 });
    try testing.expectEqual(@as(usize, 1), storage.placements.count());
    try testing.expectEqual(@as(usize, 0), state.kitty_placements.items.len);
    try testing.expect(state.images.get(.{ .kitty = 1 }) == null);
    const pixels = try alloc.dupe(u8, "rgba");
    try testing.expect(pending.complete(storage, io, pixels));
    state.kittyUpdate(alloc, &t, .{ .width = 10, .height = 10 });
    try testing.expectEqual(@as(usize, 1), state.kitty_placements.items.len);
    try testing.expectEqual(
        pending.generation,
        state.images.get(.{ .kitty = 1 }).?.generation,
    );
    _ = try storage.addPendingImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = .{ .pending = 4 },
    });
    state.kittyUpdate(alloc, &t, .{ .width = 10, .height = 10 });
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
    try testing.expectEqual(@as(usize, 0), state.kitty_placements.items.len);
    try testing.expect(state.images.get(.{ .kitty = 1 }).?.image.isUnloading());
}
test "kitty renderer uses the intersected source rectangle" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    t.width_px = 30;
    t.height_px = 30;
    var state: State = .empty;
    defer state.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    const pixels = try alloc.alloc(u8, 4 * 3 * 3);
    @memset(pixels, 0);
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 4,
        .height = 3,
        .format = .rgb,
        .data = .{ .complete = pixels },
    });
    const pin = try t.screens.active.pages.trackPin(
        t.screens.active.cursor.page_pin.*,
    );
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = pin },
        .source_x = 3,
        .source_y = 1,
    });
    state.kittyUpdate(alloc, &t, .{ .width = 10, .height = 10 });
    try testing.expectEqual(@as(usize, 1), state.kitty_placements.items.len);
    const placement = state.kitty_placements.items[0];
    try testing.expectEqual(@as(u32, 1), placement.width);
    try testing.expectEqual(@as(u32, 2), placement.height);
    try testing.expectEqual(@as(u32, 3), placement.source_x);
    try testing.expectEqual(@as(u32, 1), placement.source_y);
    try testing.expectEqual(@as(u32, 1), placement.source_width);
    try testing.expectEqual(@as(u32, 2), placement.source_height);
}
test "kitty renderer positions relative placements from the parent pin" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 10, .cols = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    var state: State = .empty;
    defer state.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    const pixels = try alloc.alloc(u8, 3);
    @memset(pixels, 0);
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgb,
        .data = .{ .complete = pixels },
    });
    const pin = try t.screens.active.pages.trackPin(
        t.screens.active.pages.pin(.{ .active = .{ .x = 2, .y = 1 } }).?,
    );
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = pin },
        .columns = 1,
        .rows = 1,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 2, .{
        .location = .{ .relative = .{
            .parent = .{
                .image_id = 1,
                .placement_id = .{ .tag = .external, .id = 1 },
            },
            .horizontal_offset = 3,
            .vertical_offset = 2,
        } },
        .columns = 1,
        .rows = 1,
        .z = 1,
    });
    state.kittyUpdate(alloc, &t, .{ .width = 10, .height = 10 });
    try testing.expectEqual(@as(usize, 2), state.kitty_placements.items.len);
    const parent = state.kitty_placements.items[0];
    try testing.expectEqual(@as(i32, 2), parent.x);
    try testing.expectEqual(@as(i32, 1), parent.y);
    const child = state.kitty_placements.items[1];
    try testing.expectEqual(@as(i32, 5), child.x);
    try testing.expectEqual(@as(i32, 3), child.y);
    try testing.expect(!state.kitty_virtual);
}
test "kitty renderer relative placement with negative offsets" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 10, .cols = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    var state: State = .empty;
    defer state.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    const pixels = try alloc.alloc(u8, 3);
    @memset(pixels, 0);
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgb,
        .data = .{ .complete = pixels },
    });
    const pin = try t.screens.active.pages.trackPin(
        t.screens.active.pages.pin(.{ .active = .{ .x = 2, .y = 2 } }).?,
    );
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = pin },
        .columns = 1,
        .rows = 1,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 2, .{
        .location = .{ .relative = .{
            .parent = .{
                .image_id = 1,
                .placement_id = .{ .tag = .external, .id = 1 },
            },
            .horizontal_offset = -3,
            .vertical_offset = -3,
        } },
        .columns = 2,
        .rows = 2,
        .z = 1,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 3, .{
        .location = .{ .relative = .{
            .parent = .{
                .image_id = 1,
                .placement_id = .{ .tag = .external, .id = 1 },
            },
            .horizontal_offset = -9,
        } },
        .columns = 2,
        .rows = 2,
        .z = 2,
    });
    state.kittyUpdate(alloc, &t, .{ .width = 10, .height = 10 });
    try testing.expectEqual(@as(usize, 2), state.kitty_placements.items.len);
    const child = state.kitty_placements.items[1];
    try testing.expectEqual(@as(i32, -1), child.x);
    try testing.expectEqual(@as(i32, -1), child.y);
}
test "kitty renderer positions relative placements from virtual parent placeholders" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.width_px = 50;
    t.height_px = 50;
    t.modes.set(.grapheme_cluster, true);
    var state: State = .empty;
    defer state.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    const pixels = try alloc.alloc(u8, 10 * 10 * 3);
    @memset(pixels, 0);
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
        .format = .rgb,
        .data = .{ .complete = pixels },
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .virtual = {} },
    });
    try t.setAttribute(.{ .@"256_fg" = 1 });
    try t.setAttribute(.{ .@"256_underline_color" = 1 });
    t.screens.active.cursorAbsolute(1, 1);
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");
    t.screens.active.cursorAbsolute(3, 2);
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");
    try storage.addPlacement(io, alloc, t.screens.active, 1, 2, .{
        .location = .{ .relative = .{
            .parent = .{
                .image_id = 1,
                .placement_id = .{ .tag = .external, .id = 1 },
            },
            .horizontal_offset = 1,
            .vertical_offset = 2,
        } },
        .columns = 1,
        .rows = 1,
        .z = 5,
    });
    state.kittyUpdate(alloc, &t, .{ .width = 10, .height = 10 });
    try testing.expect(state.kitty_virtual);
    try testing.expectEqual(@as(usize, 3), state.kitty_placements.items.len);
    const child = state.kitty_placements.items[2];
    try testing.expectEqual(@as(i32, 5), child.z);
    try testing.expectEqual(@as(i32, 2), child.x);
    try testing.expectEqual(@as(i32, 3), child.y);
}
test "kitty renderer uploads the current animation frame" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    t.width_px = 30;
    t.height_px = 30;
    var state: State = .empty;
    defer state.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = .{ .complete = try alloc.dupe(u8, &.{ 255, 0, 0, 255 }) },
    });
    const pin = try t.screens.active.pages.trackPin(
        t.screens.active.cursor.page_pin.*,
    );
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = pin },
        .columns = 1,
        .rows = 1,
    });
    state.kittyUpdate(alloc, &t, .{ .width = 10, .height = 10 });
    const gen1 = state.images.get(.{ .kitty = 1 }).?.generation;
    try testing.expectEqualSlices(
        u8,
        &.{ 255, 0, 0, 255 },
        state.images.get(.{ .kitty = 1 }).?.image.pending.dataSlice(),
    );
    const img = storage.images.getPtr(1).?;
    const anim = try alloc.create(terminal.kitty.graphics.Animation);
    anim.* = .{};
    img.animation = anim;
    try anim.frames.append(alloc, .{
        .data = try alloc.dupe(u8, &.{ 0, 0, 255, 255 }),
        .gap_ms = 40,
    });
    anim.current_index = 1;
    storage.markImageContentChanged(io, img);
    state.kittyUpdate(alloc, &t, .{ .width = 10, .height = 10 });
    const entry = state.images.get(.{ .kitty = 1 }).?;
    try testing.expect(entry.generation > gen1);
    try testing.expectEqualSlices(
        u8,
        &.{ 0, 0, 255, 255 },
        entry.image.pending.dataSlice(),
    );
}
