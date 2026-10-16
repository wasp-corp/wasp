const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const Terminal = @import("../Terminal.zig");
const command = @import("graphics_command.zig");
const image = @import("graphics_image.zig");
const animation = @import("graphics_animation.zig");
const pixel = @import("graphics_pixel.zig");
const Command = command.Command;
const Response = command.Response;
const LoadingImage = image.LoadingImage;
const Image = image.Image;
const ImageStorage = @import("graphics_storage.zig").ImageStorage;
const log = std.log.scoped(.kitty_gfx);
pub fn execute(
    io: std.Io,
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) ?Response {
    if (!terminal.screens.active.kitty_images.enabled()) {
        log.debug("kitty graphics requested but disabled", .{});
        return null;
    }
    log.debug("executing kitty graphics command: quiet={} control={}", .{
        cmd.quiet,
        cmd.control,
    });
    var quiet = cmd.quiet;
    const identifiers = cmd.control.identifiers();
    if (identifiers.image_id > 0 and identifiers.image_number > 0) {
        const resp: Response = .{
            .id = identifiers.image_id,
            .image_number = identifiers.image_number,
            .placement_id = identifiers.placement_id,
            .message = "EINVAL: image ID and number are mutually exclusive",
        };
        log.warn("erroneous kitty graphics response: {s}", .{resp.message});
        return switch (quiet) {
            .no => resp,
            .ok => resp,
            .failures => null,
        };
    }
    const resp_: ?Response = switch (cmd.control) {
        .query => query(io, alloc, terminal, cmd),
        .display => display(io, alloc, terminal, cmd),
        .delete => delete(io, alloc, terminal, cmd),
        .transmit, .transmit_and_display, .transmit_animation_frame => resp: {
            const storage = &terminal.screens.active.kitty_images;
            if (storage.loading) |loading| switch (cmd.quiet) {
                .no => quiet = loading.quiet,
                inline .ok, .failures => |tag| {
                    assert(quiet == tag);
                    loading.quiet = tag;
                },
            };
            break :resp switch (cmd.control) {
                .transmit_animation_frame => transmitAnimationFrame(
                    io,
                    alloc,
                    terminal,
                    cmd,
                ),
                else => transmit(
                    io,
                    alloc,
                    terminal,
                    cmd,
                ),
            };
        },
        .control_animation => controlAnimation(
            io,
            alloc,
            terminal,
            cmd,
        ),
        .compose_animation => composeAnimation(
            io,
            alloc,
            terminal,
            cmd,
        ),
    };
    if (resp_) |resp| {
        if (!resp.ok()) {
            log.warn("erroneous kitty graphics response: {s}", .{resp.message});
        }
        return switch (quiet) {
            .no => if (resp.empty()) null else resp,
            .ok => if (resp.ok()) null else resp,
            .failures => null,
        };
    }
    return null;
}
fn query(
    io: std.Io,
    alloc: Allocator,
    terminal: *const Terminal,
    cmd: *const Command,
) Response {
    const t = cmd.control.query;
    if (t.image_id == 0) {
        return .{ .message = "EINVAL: image ID required" };
    }
    var result: Response = .{
        .id = t.image_id,
        .image_number = t.image_number,
        .placement_id = t.placement_id,
    };
    const storage = &terminal.screens.active.kitty_images;
    var loading = LoadingImage.init(io, alloc, cmd, storage.image_limits) catch |err| {
        encodeError(&result, err);
        return result;
    };
    defer loading.deinit(alloc);
    var img = loading.complete(alloc) catch |err| {
        encodeError(&result, err);
        return result;
    };
    img.deinit(alloc);
    return result;
}
fn transmit(
    io: std.Io,
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) Response {
    const t = cmd.transmission().?;
    const storage = &terminal.screens.active.kitty_images;
    var result: Response = if (storage.loading) |loading| loading: {
        if (loading.frame != null) return transmitAnimationFrame(
            io,
            alloc,
            terminal,
            cmd,
        );
        break :loading loading.response;
    } else .{
        .id = t.image_id,
        .image_number = t.image_number,
        .placement_id = t.placement_id,
    };
    const load = loadAndAddImage(io, alloc, terminal, cmd) catch |err| {
        encodeError(&result, err);
        return result;
    };
    errdefer load.image.deinit(alloc);
    if (load.display) |d| {
        assert(!load.more);
        var d_copy = d;
        d_copy.image_id = load.image.id;
        result = display(io, alloc, terminal, &.{
            .control = .{ .display = d_copy },
            .quiet = cmd.quiet,
        });
    }
    if (load.more) return .{};
    if (load.image.metadata.implicit_id) return .{};
    result.id = load.image.id;
    return result;
}
fn display(
    io: std.Io,
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) Response {
    const d = cmd.display().?;
    if (d.image_id == 0 and d.image_number == 0) {
        return .{ .message = "EINVAL: image ID or number required" };
    }
    var result: Response = .{
        .id = d.image_id,
        .image_number = d.image_number,
        .placement_id = d.placement_id,
    };
    if (d.virtual_placement and d.parent_id > 0) {
        result.message = "EINVAL: virtual placement cannot refer to a parent";
        return result;
    }
    const storage = &terminal.screens.active.kitty_images;
    const img_: ?Image = if (d.image_id != 0)
        storage.imageById(d.image_id)
    else
        storage.imageByNumber(d.image_number);
    const img = img_ orelse {
        result.message = "ENOENT: image not found";
        return result;
    };
    result.id = img.id;
    const location: ImageStorage.Placement.Location = location: {
        if (d.virtual_placement) break :location .virtual;
        if (d.parent_id == 0) {
            const pin = terminal.screens.active.pages.trackPin(
                terminal.screens.active.cursor.page_pin.*,
            ) catch |err| {
                log.warn("failed to create pin for Kitty graphics err={}", .{err});
                result.message = "EINVAL: failed to prepare terminal state";
                return result;
            };
            break :location .{ .pin = pin };
        }
        const child: ?ImageStorage.PlacementKey = if (d.placement_id > 0) .{
            .image_id = img.id,
            .placement_id = .{ .tag = .external, .id = d.placement_id },
        } else null;
        const parent = storage.resolveParent(
            io,
            terminal.screens.active,
            child,
            d.parent_id,
            d.parent_placement_id,
        ) catch |err| {
            result.message = switch (err) {
                error.ParentImageNotFound => "ENOPARENT: parent image not found",
                error.ParentPlacementNotFound => "ENOPARENT: parent placement not found",
                error.SelfParent => "EINVAL: placement cannot be its own parent",
                error.Cycle => "ECYCLE: parent chain creates a cycle",
                error.TooDeep => "ETOODEEP: parent chain too deep",
                error.AncestorNotFound => "ENOENT: parent chain ancestor not found",
            };
            return result;
        };
        break :location .{ .relative = .{
            .parent = parent,
            .horizontal_offset = d.horizontal_offset,
            .vertical_offset = d.vertical_offset,
        } };
    };
    const p: ImageStorage.Placement = placement: {
        var p: ImageStorage.Placement = .{
            .location = location,
            .x_offset = d.x_offset,
            .y_offset = d.y_offset,
            .source_x = d.x,
            .source_y = d.y,
            .source_width = d.width,
            .source_height = d.height,
            .columns = d.columns,
            .rows = d.rows,
            .z = d.z,
        };
        const cell_offset = p.cellOffset(terminal);
        if (terminal.width_px / terminal.cols > 0) p.x_offset = cell_offset.x;
        if (terminal.height_px / terminal.rows > 0) p.y_offset = cell_offset.y;
        break :placement p;
    };
    storage.addPlacement(
        io,
        alloc,
        terminal.screens.active,
        img.id,
        result.placement_id,
        p,
    ) catch |err| {
        p.deinit(terminal.screens.active);
        encodeError(&result, err);
        return result;
    };
    switch (p.location) {
        .virtual, .relative => {},
        .pin => |pin| switch (d.cursor_movement) {
            .none => {},
            .after => {
                const screen = terminal.screens.active;
                const size = p.gridSize(img, terminal);
                const target_x = @as(usize, pin.x) +| @as(usize, size.cols);
                const wraps = target_x >= @as(usize, terminal.cols);
                const requested_rows =
                    (@as(usize, size.rows) -| 1) +| @intFromBool(wraps);
                const region = terminal.scrolling_region;
                const rows_before_scroll: usize = if (screen.cursor.y >= region.top and
                    screen.cursor.y <= region.bottom and
                    screen.cursor.x >= region.left and
                    screen.cursor.x <= region.right)
                    @as(usize, region.bottom - screen.cursor.y)
                else
                    0;
                const rows_to_move: usize = @min(
                    requested_rows,
                    rows_before_scroll +| @as(usize, terminal.rows),
                );
                for (0..rows_to_move) |_| terminal.index() catch |err| {
                    log.warn("failed to move cursor: {}", .{err});
                    break;
                };
                screen.cursor.pending_wrap = false;
                screen.cursorHorizontalAbsolute(
                    if (wraps) 0 else @intCast(target_x),
                );
            },
        },
    }
    return result;
}
fn transmitAnimationFrame(
    io: std.Io,
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) Response {
    const storage = &terminal.screens.active.kitty_images;
    if (storage.loading) |loading| {
        if (loading.frame == null) return transmit(
            io,
            alloc,
            terminal,
            cmd,
        );
        var result = loading.response;
        loading.addData(alloc, cmd.data) catch |err| {
            encodeError(&result, err);
            return result;
        };
        const t = cmd.transmission().?;
        if (t.more_chunks) return .{};
        var loading_copy = loading.*;
        alloc.destroy(loading);
        storage.loading = null;
        defer loading_copy.deinit(alloc);
        return completeAnimationFrame(
            io,
            alloc,
            terminal,
            &loading_copy,
        );
    }
    const f = cmd.control.transmit_animation_frame;
    const t = f.transmission;
    var result: Response = .{
        .id = t.image_id,
        .image_number = t.image_number,
        .placement_id = t.placement_id,
        .frame = f.edit_frame,
    };
    if (t.image_id == 0 and t.image_number == 0) {
        result.message = "EINVAL: image ID or number required";
        return result;
    }
    const img = storage.imagePtrByIdOrNumber(
        t.image_id,
        t.image_number,
    ) orelse {
        result.message = "ENOENT: image not found";
        return result;
    };
    result.id = img.id;
    var loading = LoadingImage.init(
        io,
        alloc,
        cmd,
        storage.image_limits,
    ) catch |err| {
        encodeError(&result, err);
        return result;
    };
    loading.frame = .{
        .cmd = f,
        .image_generation = img.generation,
    };
    loading.response.id = img.id;
    if (t.more_chunks) {
        const loading_ptr = alloc.create(LoadingImage) catch |err| {
            loading.deinit(alloc);
            encodeError(&result, err);
            return result;
        };
        loading_ptr.* = loading;
        storage.loading = loading_ptr;
        return .{};
    }
    defer loading.deinit(alloc);
    return completeAnimationFrame(
        io,
        alloc,
        terminal,
        &loading,
    );
}
fn completeAnimationFrame(
    io: std.Io,
    alloc: Allocator,
    terminal: *Terminal,
    loading: *LoadingImage,
) Response {
    const storage = &terminal.screens.active.kitty_images;
    var result = loading.response;
    const f = loading.frame.?.cmd;
    var img = storage.imagePtrByIdOrNumber(
        loading.image.id,
        loading.image.number,
    ) orelse {
        result.message = "ENOENT: image not found";
        return result;
    };
    if (img.generation != loading.frame.?.image_generation) {
        result.message = "ENOENT: image not found";
        return result;
    }
    if (img.data.bytes() == null) {
        result.message = "EINVAL: image data incomplete";
        return result;
    }
    var frame_img = loading.complete(alloc) catch |err| {
        encodeError(&result, err);
        return result;
    };
    defer frame_img.deinit(alloc);
    if (frame_img.width > img.width or frame_img.height > img.height) {
        result.message = "EINVAL: frame dimensions exceed image";
        return result;
    }
    if (frame_img.format != .rgba) {
        const rgba = pixel.rgbaFromFormat(
            alloc,
            frame_img.format,
            frame_img.data.bytes().?,
        ) catch |err| {
            encodeError(&result, err);
            return result;
        };
        frame_img.data.deinit(alloc);
        frame_img.data = .{ .complete = rgba };
        frame_img.format = .rgba;
    }
    storage.convertImageToRgba(io, alloc, img) catch |err| {
        encodeError(&result, err);
        return result;
    };
    const anim = ensureAnimation(alloc, img) catch |err| {
        encodeError(&result, err);
        return result;
    };
    const count: u32 = anim.frameCount();
    const number: u32 = number: {
        const r = f.edit_frame;
        if (r == 0 or r > count + 1) break :number count + 1;
        break :number r;
    };
    result.frame = number;
    const src = frame_img.data.bytes().?;
    if (number == count + 1) {
        const gap: u32 = if (f.gap_ms > 0)
            @intCast(f.gap_ms)
        else if (f.gap_ms < 0)
            0
        else
            animation.default_gap_ms;
        if (f.create_frame > 0 and img.frameData(f.create_frame) == null) {
            result.message = "EINVAL: base frame not found";
            return result;
        }
        const frame_len: usize = @as(usize, img.width) * img.height * 4;
        const image_id = img.id;
        storage.reserveAnimationBytes(
            io,
            alloc,
            terminal.screens.active,
            image_id,
            frame_len,
        ) catch {
            result.message = "ENOSPC: animation frame storage full";
            return result;
        };
        img = storage.imagePtrByIdOrNumber(image_id, 0).?;
        const canvas = alloc.alloc(u8, frame_len) catch {
            storage.releaseAnimationBytes(frame_len);
            result.message = "ENOMEM: out of memory";
            return result;
        };
        if (f.create_frame > 0) {
            @memcpy(canvas, img.frameData(f.create_frame).?);
        } else {
            pixel.fillBackground(canvas, f.background);
        }
        pixel.composeRect(
            canvas,
            img.width,
            img.height,
            src,
            frame_img.width,
            frame_img.height,
            f.x,
            f.y,
            f.composition_mode,
        );
        anim.frames.append(alloc, .{
            .data = canvas,
            .gap_ms = gap,
        }) catch {
            alloc.free(canvas);
            storage.releaseAnimationBytes(frame_len);
            result.message = "ENOMEM: out of memory";
            return result;
        };
        storage.markMutated(io);
    } else {
        if (f.gap_ms != 0) anim.setGapAt(
            number - 1,
            if (f.gap_ms > 0) @intCast(f.gap_ms) else 0,
        );
        const dst = @constCast(img.frameData(number).?);
        pixel.composeRect(
            dst,
            img.width,
            img.height,
            src,
            frame_img.width,
            frame_img.height,
            f.x,
            f.y,
            f.composition_mode,
        );
        if (number - 1 == anim.current_index) {
            anim.frame_shown_at_ms = null;
            storage.markImageContentChanged(io, img);
        } else {
            storage.markMutated(io);
        }
    }
    return result;
}
fn controlAnimation(
    io: std.Io,
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) Response {
    const a = cmd.control.control_animation;
    const storage = &terminal.screens.active.kitty_images;
    var result: Response = .{
        .id = a.image_id,
        .image_number = a.image_number,
        .placement_id = a.placement_id,
    };
    if (a.image_id == 0 and a.image_number == 0) {
        result.message = "EINVAL: image ID or number required";
        return result;
    }
    const img = storage.imagePtrByIdOrNumber(
        a.image_id,
        a.image_number,
    ) orelse {
        result.message = "ENOENT: image not found";
        return result;
    };
    const anim = ensureAnimation(alloc, img) catch |err| {
        encodeError(&result, err);
        return result;
    };
    if (a.frame != 0 and a.frame <= anim.frameCount() and a.gap_ms != 0) {
        anim.setGapAt(
            a.frame - 1,
            if (a.gap_ms > 0) @intCast(a.gap_ms) else 0,
        );
        storage.markMutated(io);
    }
    if (a.current_frame != 0 and a.current_frame <= anim.frameCount() and
        a.current_frame - 1 != anim.current_index)
    {
        anim.current_index = a.current_frame - 1;
        anim.frame_shown_at_ms = null;
        storage.markImageContentChanged(io, img);
    }
    if (a.action != .invalid) {
        const old = anim.state;
        anim.state = switch (a.action) {
            .invalid => unreachable,
            .stop => .stopped,
            .run_wait => .loading,
            .run => .running,
        };
        if (old == .stopped and anim.state != .stopped) {
            anim.frame_shown_at_ms = null;
        }
        anim.current_loop = 0;
        storage.markMutated(io);
    }
    if (a.loops != 0) {
        anim.max_loops = a.loops - 1;
        storage.markMutated(io);
    }
    return .{};
}
fn composeAnimation(
    io: std.Io,
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) Response {
    const c = cmd.control.compose_animation;
    const storage = &terminal.screens.active.kitty_images;
    var result: Response = .{
        .id = c.image_id,
        .image_number = c.image_number,
        .placement_id = c.placement_id,
    };
    if (c.image_id == 0 and c.image_number == 0) {
        result.message = "EINVAL: image ID or number required";
        return result;
    }
    const img = storage.imagePtrByIdOrNumber(
        c.image_id,
        c.image_number,
    ) orelse {
        result.message = "ENOENT: image not found";
        return result;
    };
    result.id = img.id;
    if (img.data.bytes() == null) {
        result.message = "EINVAL: image data incomplete";
        return result;
    }
    if (img.frameData(c.source_frame) == null) {
        result.message = "ENOENT: source frame not found";
        return result;
    }
    if (img.frameData(c.dest_frame) == null) {
        result.message = "ENOENT: destination frame not found";
        return result;
    }
    const width: u64 = if (c.width > 0) c.width else img.width;
    const height: u64 = if (c.height > 0) c.height else img.height;
    if (@as(u64, c.x) + width > img.width or
        @as(u64, c.y) + height > img.height)
    {
        result.message = "EINVAL: destination rectangle out of bounds";
        return result;
    }
    if (@as(u64, c.left_edge) + width > img.width or
        @as(u64, c.top_edge) + height > img.height)
    {
        result.message = "EINVAL: source rectangle out of bounds";
        return result;
    }
    if (c.source_frame == c.dest_frame) {
        const x_overlaps = @max(c.left_edge, c.x) < @min(c.left_edge, c.x) + width;
        const y_overlaps = @max(c.top_edge, c.y) < @min(c.top_edge, c.y) + height;
        if (x_overlaps and y_overlaps) {
            result.message = "EINVAL: source and destination rectangles overlap";
            return result;
        }
    }
    storage.convertImageToRgba(
        io,
        alloc,
        img,
    ) catch |err| {
        encodeError(&result, err);
        return result;
    };
    const src = img.frameData(c.source_frame).?;
    const dst = @constCast(img.frameData(c.dest_frame).?);
    pixel.composeCanvasRect(
        dst,
        src,
        img.width,
        @intCast(width),
        @intCast(height),
        c.left_edge,
        c.top_edge,
        c.x,
        c.y,
        c.composition_mode,
    );
    const current: u32 = if (img.animation) |anim| anim.current_index else 0;
    if (c.dest_frame - 1 == current) {
        storage.markImageContentChanged(io, img);
    } else {
        storage.markMutated(io);
    }
    return result;
}
fn ensureAnimation(
    alloc: Allocator,
    img: *Image,
) Allocator.Error!*animation.Animation {
    if (img.animation) |anim| return anim;
    const anim = try alloc.create(animation.Animation);
    anim.* = .{};
    img.animation = anim;
    return anim;
}
fn delete(
    io: std.Io,
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) Response {
    const storage = &terminal.screens.active.kitty_images;
    if (storage.loading) |loading| {
        loading.destroy(alloc);
        storage.loading = null;
    }
    storage.delete(
        io,
        alloc,
        terminal,
        cmd.control.delete.action,
    );
    return .{};
}
fn loadAndAddImage(
    io: std.Io,
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) !struct {
    image: Image,
    more: bool = false,
    display: ?command.Display = null,
} {
    const t = cmd.transmission().?;
    const storage = &terminal.screens.active.kitty_images;
    var loading: LoadingImage = if (storage.loading) |loading| loading: {
        try loading.addData(alloc, cmd.data);
        if (t.more_chunks) return .{ .image = loading.image, .more = true };
        defer {
            alloc.destroy(loading);
            storage.loading = null;
        }
        break :loading loading.*;
    } else loading: {
        if (t.image_id > 0) {
            storage.delete(io, alloc, terminal, .{ .id = .{
                .image_id = t.image_id,
                .delete = true,
            } });
        }
        break :loading try .init(io, alloc, cmd, storage.image_limits);
    };
    errdefer loading.deinit(alloc);
    if (loading.image.id == 0) {
        if (loading.image.number > 0) {
            loading.image.id = storage.nextImageId(.explicit);
        } else {
            loading.image.id = storage.nextImageId(.implicit);
            loading.image.metadata.implicit_id = true;
        }
    }
    if (t.more_chunks) {
        const loading_ptr = try alloc.create(LoadingImage);
        errdefer alloc.destroy(loading_ptr);
        loading_ptr.* = loading;
        storage.loading = loading_ptr;
        return .{ .image = loading.image, .more = true };
    }
    var img = try loading.complete(alloc);
    errdefer img.deinit(alloc);
    try storage.addImage(io, alloc, terminal.screens.active, img);
    const display_ = loading.display;
    loading.deinit(alloc);
    return .{ .image = img, .display = display_ };
}
const EncodeableError = Image.Error || Allocator.Error;
fn encodeError(r: *Response, err: EncodeableError) void {
    switch (err) {
        error.OutOfMemory => r.message = "ENOMEM: out of memory",
        error.InsufficientData => r.message = "ENODATA: insufficient data",
        error.InvalidData => r.message = "EINVAL: invalid data",
        error.DecompressionFailed => r.message = "EINVAL: decompression failed",
        error.FilePathTooLong => r.message = "EINVAL: file path too long",
        error.TemporaryFileNotInTempDir => r.message = "EINVAL: temporary file not in temp dir",
        error.TemporaryFileNotNamedCorrectly => r.message = "EINVAL: temporary file not named correctly",
        error.UnsupportedFormat => r.message = "EINVAL: unsupported format",
        error.UnsupportedMedium => r.message = "EINVAL: unsupported medium",
        error.UnsupportedDepth => r.message = "EINVAL: unsupported pixel depth",
        error.DimensionsRequired => r.message = "EINVAL: dimensions required",
        error.DimensionsTooLarge => r.message = "EINVAL: dimensions too large",
    }
}
test "kittygfx query validates image data" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var terminal = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer terminal.deinit(alloc);
    var cmd: Command = .{
        .control = .{ .query = .{
            .format = .rgb,
            .width = 1,
            .height = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, &.{ 0, 0 }),
    };
    defer cmd.deinit(alloc);
    const resp = execute(io, alloc, &terminal, &cmd).?;
    try testing.expect(!resp.ok());
    try testing.expectEqual(@as(u32, 31), resp.id);
    try testing.expectEqualStrings("EINVAL: invalid data", resp.message);
    try testing.expectEqual(
        @as(usize, 0),
        terminal.screens.active.kitty_images.images.count(),
    );
}
test "kittygfx valid query does not replace or store image" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var terminal = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer terminal.deinit(alloc);
    const storage = &terminal.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=31;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &terminal, &cmd).?.ok());
    }
    var cmd: Command = .{
        .control = .{ .query = .{
            .format = .rgb,
            .width = 1,
            .height = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, &.{ 0, 0, 0 }),
    };
    defer cmd.deinit(alloc);
    const resp = execute(io, alloc, &terminal, &cmd).?;
    try testing.expect(resp.ok());
    try testing.expectEqual(@as(usize, 1), storage.images.count());
    try testing.expectEqualSlices(
        u8,
        &.{ 255, 0, 0 },
        storage.imageById(31).?.data.bytes().?,
    );
}
test "kittygfx image id and number are mutually exclusive for every action" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const inputs = [_][]const u8{
        "a=q,f=24,s=1,v=1,i=1,I=2,p=3;AAAA",
        "a=t,f=24,s=1,v=1,i=1,I=2,p=3;AAAA",
        "a=T,f=24,s=1,v=1,i=1,I=2,p=3;AAAA",
        "a=p,i=1,I=2,p=3",
        "a=d,d=a,i=1,I=2,p=3",
        "a=f,i=1,I=2,p=3;AAAA",
        "a=a,i=1,I=2,p=3",
        "a=c,i=1,I=2,p=3",
    };
    for (inputs) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqual(@as(u32, 1), resp.id);
        try testing.expectEqual(@as(u32, 2), resp.image_number);
        try testing.expectEqual(@as(u32, 3), resp.placement_id);
        try testing.expectEqualStrings(
            "EINVAL: image ID and number are mutually exclusive",
            resp.message,
        );
        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try resp.encode(&writer);
        try testing.expectEqualStrings(
            "\x1b_Gi=1,I=2,p=3;EINVAL: image ID and number are mutually exclusive\x1b\\",
            writer.buffered(),
        );
    }
    try testing.expectEqual(@as(usize, 0), t.screens.active.kitty_images.images.count());
    try testing.expectEqual(@as(usize, 0), t.screens.active.kitty_images.placements.count());
}
test "kittygfx conflicting identifiers are rejected before mutation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd: Command = .{ .control = .{ .display = .{
            .image_id = 1,
            .image_number = 2,
            .placement_id = 7,
            .cursor_movement = .none,
        } } };
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqual(@as(u32, 1), resp.id);
        try testing.expectEqual(@as(u32, 2), resp.image_number);
        try testing.expectEqual(@as(u32, 7), resp.placement_id);
        try testing.expectEqual(@as(usize, 0), storage.placements.count());
    }
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=1,p=7,C=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
        try testing.expectEqual(@as(usize, 1), storage.placements.count());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=d,d=i,i=1,I=2,p=7",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqual(@as(usize, 1), storage.placements.count());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=d,d=i,i=1,I=2,p=7,q=2",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
        try testing.expectEqual(@as(usize, 1), storage.placements.count());
    }
}
test "kittygfx chunked success response uses initial identifiers" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=2,I=93,p=7,m=1;AAAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    {
        const cmd = try command.Parser.parseString(alloc, "m=0;AAAA");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
        try testing.expectEqual(@as(u32, 1), resp.id);
        try testing.expectEqual(@as(u32, 93), resp.image_number);
        try testing.expectEqual(@as(u32, 7), resp.placement_id);
        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try resp.encode(&writer);
        try testing.expectEqualStrings(
            "\x1b_Gi=1,I=93,p=7;OK\x1b\\",
            writer.buffered(),
        );
    }
}
test "kittygfx chunked error response uses initial identifiers" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=41,p=7,m=1;AA==",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    {
        const cmd = try command.Parser.parseString(alloc, "m=0;AA==");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqual(@as(u32, 41), resp.id);
        try testing.expectEqual(@as(u32, 7), resp.placement_id);
        try testing.expectEqualStrings("EINVAL: invalid data", resp.message);
    }
}
test "kittygfx more chunks with q=1" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,f=24,t=d,i=1,s=1,v=2,c=10,r=1,m=1,q=1;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd);
        try testing.expect(resp == null);
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "m=0;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd);
        try testing.expect(resp == null);
    }
}
test "kittygfx more chunks with q=0" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,t=d,s=1,v=2,c=10,r=1,m=1,i=1,q=0;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd);
        try testing.expect(resp == null);
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "m=0;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
}
test "kittygfx more chunks with chunk increasing q" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,t=d,s=1,v=2,c=10,r=1,m=1,i=1,q=0;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd);
        try testing.expect(resp == null);
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "m=0,q=1;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd);
        try testing.expect(resp == null);
    }
}
test "kittygfx delete aborts chunked image load" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=2,i=1,m=1;AAAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expect(storage.loading != null);
    {
        const cmd = try command.Parser.parseString(alloc, "a=d");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expect(storage.loading == null);
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=2,i=1,m=1;AAAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    {
        const cmd = try command.Parser.parseString(alloc, "m=0;AAAA");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expectEqual(@as(usize, 6), storage.imageById(1).?.data.len());
}
test "kittygfx uppercase id delete preserves image when placement does not match" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;AAAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=d,d=I,i=1,p=7",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expect(storage.imageById(1) != null);
}
test "kittygfx default format is rgba" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const cmd = try command.Parser.parseString(
        alloc,
        "a=t,t=d,i=1,s=1,v=2,c=10,r=1;///////////",
    );
    defer cmd.deinit(alloc);
    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(resp.ok());
    const storage = &t.screens.active.kitty_images;
    const img = storage.imageById(1).?;
    try testing.expectEqual(command.Transmission.Format.rgba, img.format);
}
test "kittygfx test valid u32 (expect invalid image ID)" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const cmd = try command.Parser.parseString(
        alloc,
        "a=p,i=4294967295",
    );
    defer cmd.deinit(alloc);
    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(!resp.ok());
    try testing.expectEqual(resp.message, "ENOENT: image not found");
}
test "kittygfx test valid i32 (expect invalid image ID)" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const cmd = try command.Parser.parseString(
        alloc,
        "a=p,i=1,z=-2147483648",
    );
    defer cmd.deinit(alloc);
    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(!resp.ok());
    try testing.expectEqual(resp.message, "ENOENT: image not found");
}
test "kittygfx no response with no image ID or number" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,t=d,s=1,v=2,c=10,r=1,i=0,I=0;////////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd);
        try testing.expect(resp == null);
    }
}
test "kittygfx no response with no image ID or number load and display" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,f=24,t=d,s=1,v=2,c=10,r=1,i=0,I=0;////////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd);
        try testing.expect(resp == null);
    }
}
test "kittygfx retransmit same id gets fresh image generation" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,t=d,f=24,i=1,s=1,v=2;////////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    const gen1 = storage.imageById(1).?.generation;
    try testing.expect(gen1 > 0);
    try testing.expectEqual(gen1, storage.generation);
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,t=d,f=24,i=1,s=1,v=2;AAAAAAAA",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    const gen2 = storage.imageById(1).?.generation;
    try testing.expect(gen2 > gen1);
    try testing.expectEqual(gen2, storage.generation);
}
test "kittygfx retransmit same id removes existing placements" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    const tracked = t.screens.active.pages.countTrackedPins();
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,t=d,f=24,i=1,s=1,v=2,C=1;////////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=1,C=1");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=1,p=7,C=1");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    try testing.expectEqual(@as(usize, 3), storage.placements.count());
    try testing.expectEqual(
        tracked + 3,
        t.screens.active.pages.countTrackedPins(),
    );
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,t=d,f=24,i=1,s=1,v=2;AAAAAAAA",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,t=d,f=24,i=1,s=1,v=2,C=1;////////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,t=d,f=24,i=1,s=1,v=2,C=1;AAAAAAAA",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    try testing.expectEqual(@as(usize, 1), storage.placements.count());
    try testing.expectEqual(
        tracked + 1,
        t.screens.active.pages.countTrackedPins(),
    );
}
test "kittygfx retransmit same id removes image on first chunk" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    const tracked = t.screens.active.pages.countTrackedPins();
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,t=d,f=24,i=1,s=1,v=2,C=1;////////",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expect(storage.imageById(1) != null);
    try testing.expectEqual(@as(usize, 1), storage.placements.count());
    try testing.expectEqual(
        tracked + 1,
        t.screens.active.pages.countTrackedPins(),
    );
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,t=d,f=24,i=1,s=1,v=2,m=1;AAAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expect(storage.loading != null);
    try testing.expect(storage.imageById(1) == null);
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}
test "kittygfx delete then retransmit same id gets fresh generation" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,t=d,f=24,i=1,s=1,v=2,c=1,r=1;////////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    const gen1 = storage.imageById(1).?.generation;
    {
        const cmd = try command.Parser.parseString(alloc, "a=d,d=A");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd);
        try testing.expect(resp == null);
    }
    try testing.expect(storage.imageById(1) == null);
    const gen_delete = storage.generation;
    try testing.expect(gen_delete > gen1);
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,t=d,f=24,i=1,s=1,v=2;////////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    const gen2 = storage.imageById(1).?.generation;
    try testing.expect(gen2 > gen1);
    try testing.expect(gen2 > gen_delete);
}
test "kittygfx display clamps cell offsets" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.width_px = 50; 
    t.height_px = 100; 
    const cmd = try command.Parser.parseString(
        alloc,
        "a=T,t=d,f=24,i=1,s=1,v=1,c=2,r=1,X=99,Y=99,C=1;AAAA",
    );
    defer cmd.deinit(alloc);
    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(resp.ok());
    const storage = &t.screens.active.kitty_images;
    var it = storage.placements.iterator();
    const placement = it.next().?.value_ptr;
    try testing.expectEqual(@as(u32, 9), placement.x_offset);
    try testing.expectEqual(@as(u32, 19), placement.y_offset);
    const actual = placement.pixelSize(storage.imageById(1).?, &t);
    try testing.expectEqual(@as(u32, 11), actual.width);
    try testing.expectEqual(@as(u32, 1), actual.height);
}
test "kittygfx placement bounds cursor movement for untrusted dimensions" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const cmd = try command.Parser.parseString(
        alloc,
        "a=T,t=d,f=24,i=1,s=1,v=1,c=4294967295,r=4294967295;////",
    );
    defer cmd.deinit(alloc);
    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(resp.ok());
    try testing.expectEqual(@as(usize, 1), t.screens.active.kitty_images.placements.count());
    try testing.expectEqual(@as(usize, 10), t.screens.active.pages.scrollbar().total);
}
test "kittygfx placement moves cursor past a tall image" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,t=d,f=24,i=1,s=1,v=1;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=p,i=1,p=1,c=5,r=8",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=p,i=1,p=2,C=1",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    const storage = &t.screens.active.kitty_images;
    const first = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }).?;
    const second = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 2 },
    }).?;
    const first_pin = switch (first.location) {
        .pin => |pin| pin,
        .virtual, .relative => unreachable,
    };
    const second_pin = switch (second.location) {
        .pin => |pin| pin,
        .virtual, .relative => unreachable,
    };
    const first_y = t.screens.active.pages.pointFromPin(
        .screen,
        first_pin.*,
    ).?.screen.y;
    const second_y = t.screens.active.pages.pointFromPin(
        .screen,
        second_pin.*,
    ).?.screen.y;
    try testing.expectEqual(first_y + 8, second_y);
}
test "kittygfx unknown format responds with EINVAL" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const cmd = try command.Parser.parseString(
        alloc,
        "a=t,f=42,t=d,i=31,s=1,v=1;AAAA",
    );
    defer cmd.deinit(alloc);
    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(!resp.ok());
    try testing.expectEqual(@as(u32, 31), resp.id);
    try testing.expectEqualStrings("EINVAL: unsupported format", resp.message);
    try testing.expectEqual(
        @as(usize, 0),
        t.screens.active.kitty_images.images.count(),
    );
}
test "kittygfx unknown format on query responds with EINVAL" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const cmd = try command.Parser.parseString(
        alloc,
        "a=q,f=42,t=d,i=31,s=1,v=1;AAAA",
    );
    defer cmd.deinit(alloc);
    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(!resp.ok());
    try testing.expectEqual(@as(u32, 31), resp.id);
    try testing.expectEqualStrings("EINVAL: unsupported format", resp.message);
}
test "kittygfx zero format is rgba" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const cmd = try command.Parser.parseString(
        alloc,
        "a=t,f=0,t=d,i=1,s=1,v=2,c=10,r=1;///////////",
    );
    defer cmd.deinit(alloc);
    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(resp.ok());
    const img = t.screens.active.kitty_images.imageById(1).?;
    try testing.expectEqual(command.Transmission.Format.rgba, img.format);
}
test "kittygfx unknown format with q=3 has no response" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const cmd = try command.Parser.parseString(
        alloc,
        "a=t,f=42,t=d,i=31,q=3,s=1,v=1;AAAA",
    );
    defer cmd.deinit(alloc);
    try testing.expect(execute(io, alloc, &t, &cmd) == null);
}
test "kittygfx out of range display keys are tolerated" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,f=24,t=d,i=31,s=1,v=1,C=2,U=2;AAAA",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
        try testing.expectEqual(@as(u32, 31), resp.id);
    }
    const storage = &t.screens.active.kitty_images;
    var it = storage.placements.iterator();
    const entry = it.next().?;
    try testing.expect(entry.value_ptr.location == .virtual);
}
test "kittygfx number-based transmission assigns smallest free id" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,I=42;/wAA",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
        try testing.expectEqual(@as(u32, 1), resp.id);
        try testing.expectEqual(@as(u32, 42), resp.image_number);
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=2;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,I=43;/wAA",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
        try testing.expectEqual(@as(u32, 3), resp.id);
    }
    {
        const cmd = try command.Parser.parseString(alloc, "a=d,d=I,i=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,I=44;/wAA",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
        try testing.expectEqual(@as(u32, 1), resp.id);
    }
    try testing.expectEqual(@as(usize, 3), storage.images.count());
    try testing.expectEqual(@as(u32, 44), storage.imageById(1).?.number);
    try testing.expectEqual(@as(u32, 0), storage.imageById(2).?.number);
    try testing.expectEqual(@as(u32, 43), storage.imageById(3).?.number);
}
test "kittygfx number-based id assignment does not replace client image" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=2147483647;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=2147483647,C=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,I=42;AAD/",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
        try testing.expectEqual(@as(u32, 1), resp.id);
    }
    try testing.expectEqual(@as(usize, 2), storage.images.count());
    try testing.expectEqual(@as(usize, 1), storage.placements.count());
    try testing.expectEqualSlices(
        u8,
        &.{ 255, 0, 0 },
        storage.imageById(2147483647).?.data.bytes().?,
    );
}
test "kittygfx implicit id assignment does not replace client image" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=2147483647;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=2147483647,C=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1;AAD/",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expectEqual(@as(usize, 2), storage.images.count());
    try testing.expectEqual(@as(usize, 1), storage.placements.count());
    try testing.expectEqualSlices(
        u8,
        &.{ 255, 0, 0 },
        storage.imageById(2147483647).?.data.bytes().?,
    );
    const implicit = storage.imageById(2147483648).?;
    try testing.expect(implicit.metadata.implicit_id);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255 }, implicit.data.bytes().?);
}
test "kittygfx relative placement with missing parent image" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;AAAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=p,i=1,p=1,P=42,Q=1,H=2,V=2",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqualStrings(
            "ENOPARENT: parent image not found",
            resp.message,
        );
    }
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expectEqual(0, t.screens.active.cursor.x);
    try testing.expectEqual(0, t.screens.active.cursor.y);
}
test "kittygfx relative placement with missing parent placement" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=t,f=24,s=1,v=1,i=2;AAAA",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=1,P=2");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqualStrings(
            "ENOPARENT: parent placement not found",
            resp.message,
        );
    }
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=2,p=1,C=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=1,P=2,Q=9");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqualStrings(
            "ENOPARENT: parent placement not found",
            resp.message,
        );
    }
    try testing.expectEqual(@as(usize, 1), storage.placements.count());
}
test "kittygfx relative placement cannot parent itself" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=p,i=1,p=1,C=1",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    for ([_][]const u8{
        "a=p,i=1,p=1,P=1,Q=1",
        "a=p,i=1,p=1,P=1",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqualStrings(
            "EINVAL: placement cannot be its own parent",
            resp.message,
        );
    }
    const storage = &t.screens.active.kitty_images;
    const p = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }).?;
    try testing.expect(p.location == .pin);
}
test "kittygfx relative placement cycle" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=p,i=1,p=1,C=1",
        "a=p,i=1,p=2,P=1,Q=1",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=1,p=1,P=1,Q=2");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqualStrings(
            "ECYCLE: parent chain creates a cycle",
            resp.message,
        );
    }
    const storage = &t.screens.active.kitty_images;
    const p = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }).?;
    try testing.expect(p.location == .pin);
}
test "kittygfx relative placement chain depth limit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=p,i=1,p=1,C=1",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    for (2..10) |id| {
        var buf: [64]u8 = undefined;
        const cmd = try command.Parser.parseString(
            alloc,
            try std.fmt.bufPrint(&buf, "a=p,i=1,p={},P=1,Q={}", .{ id, id - 1 }),
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=1,p=10,P=1,Q=9");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqualStrings(
            "ETOODEEP: parent chain too deep",
            resp.message,
        );
    }
    const storage = &t.screens.active.kitty_images;
    try testing.expectEqual(@as(usize, 9), storage.placements.count());
}
test "kittygfx relative placement does not move cursor" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=p,i=1,p=1,C=1",
        "a=p,i=1,p=2,P=1,Q=1,H=3,V=2,c=2,r=2",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expectEqual(0, t.screens.active.cursor.x);
    try testing.expectEqual(0, t.screens.active.cursor.y);
    const p = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 2 },
    }).?;
    const rel = p.location.relative;
    try testing.expect(rel.parent.eql(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }));
    try testing.expectEqual(@as(i32, 3), rel.horizontal_offset);
    try testing.expectEqual(@as(i32, 2), rel.vertical_offset);
}
test "kittygfx virtual placement with parent rejected before image lookup" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const cmd = try command.Parser.parseString(alloc, "a=p,i=42,U=1,P=1");
    defer cmd.deinit(alloc);
    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(!resp.ok());
    try testing.expectEqualStrings(
        "EINVAL: virtual placement cannot refer to a parent",
        resp.message,
    );
}
test "kittygfx deleting a parent deletes relative placements transitively" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=p,i=1,p=1,C=1",
        "a=p,i=1,p=2,P=1,Q=1",
        "a=p,i=1,p=3,P=1,Q=2",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expectEqual(@as(usize, 3), storage.placements.count());
    {
        const cmd = try command.Parser.parseString(alloc, "a=d,d=i,i=1,p=2");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expectEqual(@as(usize, 1), storage.placements.count());
    try testing.expect(storage.placements.contains(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }));
    {
        const cmd = try command.Parser.parseString(alloc, "a=d,d=i,i=1,p=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expect(storage.imageById(1) != null);
}
test "kittygfx retransmitting parent image deletes relative placements" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=t,f=24,s=1,v=1,i=2;AAAA",
        "a=p,i=1,p=1,C=1",
        "a=p,i=2,p=1,P=1,Q=1",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expectEqual(@as(usize, 2), storage.placements.count());
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;AAAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expect(storage.imageById(2) == null);
}
test "kittygfx relative placement parent fallback picks lowest external id" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=t,f=24,s=1,v=1,i=2;AAAA",
        "a=p,i=1,p=7,C=1",
        "a=p,i=1,p=3,C=1",
        "a=p,i=2,P=1",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    var it = storage.placements.iterator();
    const rel = while (it.next()) |entry| {
        if (entry.key_ptr.image_id == 2) break entry.value_ptr.location.relative;
    } else return error.PlacementNotFound;
    try testing.expect(rel.parent.eql(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 3 },
    }));
}
test "kittygfx placements created after a full reset are retained" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 24, .cols = 80 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    t.fullReset();
    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=p,i=1,p=1,C=1",
        "a=p,i=1,p=2,C=1",
        "a=p,i=1,p=3,P=1,Q=2",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expectEqual(@as(usize, 3), storage.placements.count());
}
test "kittygfx relative placement with pruned parent is ENOPARENT" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=p,i=1,p=1,C=1",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    const parent = storage.placements.getPtr(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }).?;
    parent.location.pin.garbage = true;
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=1,p=2,P=1,Q=1");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqualStrings(
            "ENOPARENT: parent placement not found",
            resp.message,
        );
    }
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
}
test "kittygfx uppercase delete frees image of cascaded placements" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    for ([_][]const u8{
        "a=t,f=24,s=1,v=1,i=1;AAAA",
        "a=p,i=1,p=1,C=1",
        "a=p,i=1,p=2,P=1,Q=1",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(alloc, "a=d,d=I,i=1,p=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expect(storage.imageById(1) == null);
}
test "kittygfx animation: new frame with default gap responds with frame number" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    const cmd = try command.Parser.parseString(
        alloc,
        "a=f,i=1,f=24,s=1,v=1;AAD/",
    );
    defer cmd.deinit(alloc);
    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(resp.ok());
    try testing.expectEqual(@as(u32, 1), resp.id);
    try testing.expectEqual(@as(u32, 2), resp.frame);
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try resp.encode(&writer);
    try testing.expectEqualStrings("\x1b_Gi=1,r=2;OK\x1b\\", writer.buffered());
    const img = storage.imagePtrByIdOrNumber(1, 0).?;
    try testing.expectEqual(command.Transmission.Format.rgba, img.format);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, img.data.bytes().?);
    const anim = img.animation.?;
    try testing.expectEqual(@as(u32, 2), anim.frameCount());
    try testing.expectEqual(@as(u32, 0), anim.root_gap_ms);
    try testing.expectEqual(@as(u32, 40), anim.frames.items[0].gap_ms);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, anim.frames.items[0].data);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, img.renderData().bytes().?);
    try testing.expectEqual(@as(usize, 8), storage.total_bytes);
}
test "kittygfx animation: frame gap normalization on create" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    for ([_][]const u8{
        "a=f,i=1,f=24,s=1,v=1,z=100;AAD/",
        "a=f,i=1,f=24,s=1,v=1,z=-5;AAD/",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    const anim = storage.imagePtrByIdOrNumber(1, 0).?.animation.?;
    try testing.expectEqual(@as(u32, 100), anim.frames.items[0].gap_ms);
    try testing.expectEqual(@as(u32, 0), anim.frames.items[1].gap_ms);
}
test "kittygfx animation: background fill and offset composition" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=2,v=1,i=1;////////",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=24,s=1,v=1,x=1,Y=4278190335;////",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    const anim = storage.imagePtrByIdOrNumber(1, 0).?.animation.?;
    try testing.expectEqualSlices(
        u8,
        &.{ 255, 0, 0, 255, 255, 255, 255, 255 },
        anim.frames.items[0].data,
    );
}
test "kittygfx animation: create from base frame with overwrite" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=32,s=1,v=1,c=1,X=1;AAD/gA==",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
    const anim = storage.imagePtrByIdOrNumber(1, 0).?.animation.?;
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 128 }, anim.frames.items[0].data);
}
test "kittygfx animation: alpha blend composes over base frame" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=32,s=1,v=1,c=1;AAD//w==",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=32,s=1,v=1,c=1;AAD/AA==",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    const anim = storage.imagePtrByIdOrNumber(1, 0).?.animation.?;
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, anim.frames.items[0].data);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, anim.frames.items[1].data);
}
test "kittygfx animation: edit root frame bumps generation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    const gen1 = storage.imagePtrByIdOrNumber(1, 0).?.generation;
    const cmd = try command.Parser.parseString(
        alloc,
        "a=f,i=1,f=24,s=1,v=1,r=1;AAD/",
    );
    defer cmd.deinit(alloc);
    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(resp.ok());
    try testing.expectEqual(@as(u32, 1), resp.frame);
    const img = storage.imagePtrByIdOrNumber(1, 0).?;
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, img.data.bytes().?);
    try testing.expect(img.generation > gen1);
}
test "kittygfx animation: edit frame gap without data change" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=24,s=1,v=1,z=77;AAD/",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=24,s=1,v=1,r=2;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    const anim = storage.imagePtrByIdOrNumber(1, 0).?.animation.?;
    try testing.expectEqual(@as(u32, 77), anim.frames.items[0].gap_ms);
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=24,s=1,v=1,r=2,z=-1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expectEqual(@as(u32, 0), anim.frames.items[0].gap_ms);
}
test "kittygfx animation: frame errors" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    const cases = [_]struct {
        input: []const u8,
        message: []const u8,
    }{
        .{
            .input = "a=f,i=9,f=24,s=1,v=1;AAD/",
            .message = "ENOENT: image not found",
        },
        .{
            .input = "a=f,i=1,f=24,s=2,v=1;////////",
            .message = "EINVAL: frame dimensions exceed image",
        },
        .{
            .input = "a=f,i=1,f=24,s=1,v=1,c=5;AAD/",
            .message = "EINVAL: base frame not found",
        },
        .{
            .input = "a=f,i=1,f=24,s=1,v=1;AA==",
            .message = "ENODATA: insufficient data",
        },
    };
    for (cases) |case| {
        const cmd = try command.Parser.parseString(alloc, case.input);
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqualStrings(case.message, resp.message);
    }
    const storage = &t.screens.active.kitty_images;
    const img = storage.imagePtrByIdOrNumber(1, 0).?;
    if (img.animation) |anim| {
        try testing.expectEqual(@as(usize, 0), anim.frames.items.len);
    }
}
test "kittygfx animation: excess frame data is truncated" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    const cmd = try command.Parser.parseString(
        alloc,
        "a=f,i=1,f=24,s=1,v=1;AAD/////",
    );
    defer cmd.deinit(alloc);
    try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    const anim = storage.imagePtrByIdOrNumber(1, 0).?.animation.?;
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, anim.frames.items[0].data);
}
test "kittygfx animation: chunked frame transmission" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=2,v=1,i=1;////////",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=24,s=2,v=1,z=60,m=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expect(storage.loading != null);
    {
        const cmd = try command.Parser.parseString(alloc, "a=f,m=0;AAD/");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
        try testing.expectEqual(@as(u32, 1), resp.id);
        try testing.expectEqual(@as(u32, 2), resp.frame);
    }
    try testing.expect(storage.loading == null);
    const anim = storage.imagePtrByIdOrNumber(1, 0).?.animation.?;
    try testing.expectEqual(@as(u32, 60), anim.frames.items[0].gap_ms);
    try testing.expectEqualSlices(
        u8,
        &.{ 255, 0, 0, 255, 0, 0, 255, 255 },
        anim.frames.items[0].data,
    );
}
test "kittygfx animation: chunked frame continuation without a=f" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=2,v=1,i=1;////////",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=24,s=2,v=1,m=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    {
        const cmd = try command.Parser.parseString(alloc, "m=0;AAD/");
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
        try testing.expectEqual(@as(u32, 2), resp.frame);
    }
    const anim = storage.imagePtrByIdOrNumber(1, 0).?.animation.?;
    try testing.expectEqual(@as(usize, 1), anim.frames.items.len);
}
test "kittygfx animation: control command sets gap current state and loops" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=24,s=1,v=1;AAD/",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    const img = storage.imagePtrByIdOrNumber(1, 0).?;
    const gen1 = img.generation;
    const cmd = try command.Parser.parseString(
        alloc,
        "a=a,i=1,r=1,z=50,c=2,s=3,v=3",
    );
    defer cmd.deinit(alloc);
    try testing.expect(execute(io, alloc, &t, &cmd) == null);
    const anim = img.animation.?;
    try testing.expectEqual(@as(u32, 50), anim.root_gap_ms);
    try testing.expectEqual(@as(u32, 1), anim.current_index);
    try testing.expectEqual(animation.Animation.State.running, anim.state);
    try testing.expectEqual(@as(u32, 2), anim.max_loops);
    try testing.expect(img.generation > gen1);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, img.renderData().bytes().?);
}
test "kittygfx animation: control command ignores invalid values" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    const cmd = try command.Parser.parseString(
        alloc,
        "a=a,i=1,r=9,z=50,c=9,s=7",
    );
    defer cmd.deinit(alloc);
    try testing.expect(execute(io, alloc, &t, &cmd) == null);
    const anim = storage.imagePtrByIdOrNumber(1, 0).?.animation.?;
    try testing.expectEqual(@as(u32, 0), anim.root_gap_ms);
    try testing.expectEqual(@as(u32, 0), anim.current_index);
    try testing.expectEqual(animation.Animation.State.stopped, anim.state);
}
test "kittygfx animation: control command missing image responds ENOENT" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const cmd = try command.Parser.parseString(alloc, "a=a,i=9,s=3");
    defer cmd.deinit(alloc);
    const resp = execute(io, alloc, &t, &cmd).?;
    try testing.expect(!resp.ok());
    try testing.expectEqualStrings("ENOENT: image not found", resp.message);
}
test "kittygfx animation: compose frames" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=2,v=1,i=1;/wAAAAD/",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=24,s=1,v=1;////",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=c,i=1,r=1,c=2,w=1,h=1,X=1,x=0",
        );
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
        try testing.expectEqual(@as(u32, 0), resp.frame);
    }
    const anim = storage.imagePtrByIdOrNumber(1, 0).?.animation.?;
    try testing.expectEqualSlices(
        u8,
        &.{ 0, 0, 255, 255, 0, 0, 0, 0 },
        anim.frames.items[0].data,
    );
}
test "kittygfx animation: compose current frame bumps generation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=2,v=1,i=1;////////",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    const img = storage.imagePtrByIdOrNumber(1, 0).?;
    const gen1 = img.generation;
    const cmd = try command.Parser.parseString(
        alloc,
        "a=c,i=1,r=1,c=1,w=1,h=1,x=1",
    );
    defer cmd.deinit(alloc);
    try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    try testing.expect(img.generation > gen1);
}
test "kittygfx animation: compose errors" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    const cases = [_]struct {
        input: []const u8,
        message: []const u8,
    }{
        .{
            .input = "a=c,i=9,r=1,c=1",
            .message = "ENOENT: image not found",
        },
        .{
            .input = "a=c,i=1,r=2,c=1",
            .message = "ENOENT: source frame not found",
        },
        .{
            .input = "a=c,i=1,r=1,c=2",
            .message = "ENOENT: destination frame not found",
        },
        .{
            .input = "a=c,i=1,r=1,c=1,x=1",
            .message = "EINVAL: destination rectangle out of bounds",
        },
        .{
            .input = "a=c,i=1,r=1,c=1,X=1",
            .message = "EINVAL: source rectangle out of bounds",
        },
        .{
            .input = "a=c,i=1,r=1,c=1",
            .message = "EINVAL: source and destination rectangles overlap",
        },
    };
    for (cases) |case| {
        const cmd = try command.Parser.parseString(alloc, case.input);
        defer cmd.deinit(alloc);
        const resp = execute(io, alloc, &t, &cmd).?;
        try testing.expect(!resp.ok());
        try testing.expectEqualStrings(case.message, resp.message);
    }
}
test "kittygfx animation: delete frame promotes root and fixes current" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    for ([_][]const u8{
        "a=f,i=1,f=24,s=1,v=1,z=10;AAD/",
        "a=f,i=1,f=24,s=1,v=1,z=20;////",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    const total_before = storage.total_bytes;
    {
        const cmd = try command.Parser.parseString(alloc, "a=d,d=f,i=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    const img = storage.imagePtrByIdOrNumber(1, 0).?;
    const anim = img.animation.?;
    try testing.expectEqual(@as(u32, 2), anim.frameCount());
    try testing.expectEqual(@as(u32, 10), anim.root_gap_ms);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, img.data.bytes().?);
    try testing.expectEqual(total_before - 4, storage.total_bytes);
    {
        const cmd = try command.Parser.parseString(alloc, "a=d,d=f,i=1,r=9");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expectEqual(@as(u32, 1), anim.frameCount());
    try testing.expectEqual(total_before - 8, storage.total_bytes);
    {
        const cmd = try command.Parser.parseString(alloc, "a=d,d=f,i=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expect(storage.imageById(1) != null);
}
test "kittygfx animation: uppercase frame delete removes non-animated image" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,f=24,s=1,v=1,i=1,C=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expectEqual(@as(usize, 1), storage.placements.count());
    {
        const cmd = try command.Parser.parseString(alloc, "a=d,d=F,i=1");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expect(storage.imageById(1) == null);
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expectEqual(@as(usize, 0), storage.total_bytes);
}
test "kittygfx animation: deleting current frame refreshes display" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    for ([_][]const u8{
        "a=f,i=1,f=24,s=1,v=1;AAD/",
        "a=f,i=1,f=24,s=1,v=1;////",
        "a=a,i=1,c=3",
    }) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);
        _ = execute(io, alloc, &t, &cmd);
    }
    const img = storage.imagePtrByIdOrNumber(1, 0).?;
    const anim = img.animation.?;
    try testing.expectEqual(@as(u32, 2), anim.current_index);
    const gen1 = img.generation;
    {
        const cmd = try command.Parser.parseString(alloc, "a=d,d=f,i=1,r=3");
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd) == null);
    }
    try testing.expectEqual(@as(u32, 1), anim.current_index);
    try testing.expect(img.generation > gen1);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, img.renderData().bytes().?);
}
test "kittygfx animation: retransmitting base image resets animation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=24,s=1,v=1;AAD/",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    try testing.expectEqual(@as(usize, 8), storage.total_bytes);
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    const img = storage.imagePtrByIdOrNumber(1, 0).?;
    try testing.expect(img.animation == null);
    try testing.expectEqual(@as(usize, 3), storage.total_bytes);
}
test "kittygfx animation: control negative gap makes frame gapless" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=f,i=1,f=24,s=1,v=1;AAD/",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(io, alloc, &t, &cmd).?.ok());
    }
    const cmd = try command.Parser.parseString(alloc, "a=a,i=1,r=2,z=-1");
    defer cmd.deinit(alloc);
    try testing.expect(execute(io, alloc, &t, &cmd) == null);
    const anim = storage.imagePtrByIdOrNumber(1, 0).?.animation.?;
    try testing.expectEqual(@as(u32, 0), anim.frames.items[0].gap_ms);
}
