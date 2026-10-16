const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const macos = @import("macos");
const graphics = macos.graphics;
const IOSurface = macos.iosurface.IOSurface;
const mtl = @import("api.zig");
const log = std.log.scoped(.metal);
pub const Options = struct {
    device: objc.Object,
    width: usize,
    height: usize,
    pixel_format: mtl.MTLPixelFormat,
    storage_mode: mtl.MTLResourceOptions.StorageMode,
};
surface: *IOSurface,
texture: objc.Object,
width: usize,
height: usize,
pub fn init(opts: Options) !Self {
    const colorspace = try graphics.ColorSpace.createNamed(.displayP3);
    defer colorspace.release();
    const surface = try IOSurface.init(.{
        .width = @intCast(opts.width),
        .height = @intCast(opts.height),
        .pixel_format = .@"32BGRA",
        .bytes_per_element = 4,
        .colorspace = colorspace,
    });
    const desc = init: {
        const Class = objc.getClass("MTLTextureDescriptor").?;
        const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
        const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
        break :init id_init;
    };
    defer desc.release();
    desc.setProperty("width", @as(c_ulong, @intCast(opts.width)));
    desc.setProperty("height", @as(c_ulong, @intCast(opts.height)));
    desc.setProperty("pixelFormat", @intFromEnum(opts.pixel_format));
    desc.setProperty("usage", mtl.MTLTextureUsage{ .render_target = true });
    desc.setProperty(
        "resourceOptions",
        mtl.MTLResourceOptions{
            .cpu_cache_mode = .write_combined,
            .storage_mode = opts.storage_mode,
        },
    );
    const id = opts.device.msgSend(
        ?*anyopaque,
        objc.sel("newTextureWithDescriptor:iosurface:plane:"),
        .{
            desc,
            surface,
            @as(c_ulong, 0),
        },
    ) orelse return error.MetalFailed;
    const texture = objc.Object.fromId(id);
    return .{
        .surface = surface,
        .texture = texture,
        .width = opts.width,
        .height = opts.height,
    };
}
pub fn deinit(self: *Self) void {
    self.surface.deinit();
    self.texture.release();
}
