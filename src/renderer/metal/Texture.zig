const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../../quirks.zig").inlineAssert;
const objc = @import("objc");
const mtl = @import("api.zig");
const Metal = @import("../Metal.zig");
const log = std.log.scoped(.metal);
pub const Options = struct {
    device: objc.Object,
    pixel_format: mtl.MTLPixelFormat,
    resource_options: mtl.MTLResourceOptions,
    usage: mtl.MTLTextureUsage,
};
texture: objc.Object,
width: usize,
height: usize,
bpp: usize,
pub const Error = error{
    MetalFailed,
};
pub fn init(
    opts: Options,
    width: usize,
    height: usize,
    data: ?[]const u8,
) Error!Self {
    const desc = init: {
        const Class = objc.getClass("MTLTextureDescriptor").?;
        const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
        const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
        break :init id_init;
    };
    defer desc.release();
    desc.setProperty("pixelFormat", @intFromEnum(opts.pixel_format));
    desc.setProperty("width", @as(c_ulong, width));
    desc.setProperty("height", @as(c_ulong, height));
    desc.setProperty("resourceOptions", opts.resource_options);
    desc.setProperty("usage", opts.usage);
    const id = opts.device.msgSend(
        ?*anyopaque,
        objc.sel("newTextureWithDescriptor:"),
        .{desc},
    ) orelse return error.MetalFailed;
    const self: Self = .{
        .texture = objc.Object.fromId(id),
        .width = width,
        .height = height,
        .bpp = bppOf(opts.pixel_format),
    };
    if (data) |d| {
        assert(d.len == width * height * self.bpp);
        try self.replaceRegion(0, 0, width, height, d);
    }
    return self;
}
pub fn deinit(self: Self) void {
    self.texture.release();
}
pub fn replaceRegion(
    self: Self,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    data: []const u8,
) error{}!void {
    self.texture.msgSend(
        void,
        objc.sel("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"),
        .{
            mtl.MTLRegion{
                .origin = .{ .x = x, .y = y, .z = 0 },
                .size = .{
                    .width = @intCast(width),
                    .height = @intCast(height),
                    .depth = 1,
                },
            },
            @as(c_ulong, 0),
            @as(*const anyopaque, data.ptr),
            @as(c_ulong, self.bpp * width),
        },
    );
}
fn bppOf(pixel_format: mtl.MTLPixelFormat) usize {
    return switch (pixel_format) {
        .invalid => @panic("invalid pixel format"),
        else => @panic("pixel format size unknown (unlikely that this format was actually used, could be memory corruption)"),
        .a8unorm,
        .r8unorm,
        .r8unorm_srgb,
        .r8snorm,
        .r8uint,
        .r8sint,
        .rg8unorm,
        .rg8unorm_srgb,
        .rg8snorm,
        .rg8uint,
        .rg8sint,
        .stencil8,
        => 1,
        .r16unorm,
        .r16snorm,
        .r16uint,
        .r16sint,
        .r16float,
        .rg16unorm,
        .rg16snorm,
        .rg16uint,
        .rg16sint,
        .rg16float,
        .b5g6r5unorm,
        .a1bgr5unorm,
        .abgr4unorm,
        .bgr5a1unorm,
        .depth16unorm,
        => 2,
        .rgba8unorm,
        .rgba8unorm_srgb,
        .rgba8snorm,
        .rgba8uint,
        .rgba8sint,
        .bgra8unorm,
        .bgra8unorm_srgb,
        .rgb10a2unorm,
        .rgb10a2uint,
        .rg11b10float,
        .rgb9e5float,
        .bgr10a2unorm,
        .bgr10_xr,
        .bgr10_xr_srgb,
        .r32uint,
        .r32sint,
        .r32float,
        .depth32float,
        .depth24unorm_stencil8,
        => 4,
        .rg32uint,
        .rg32sint,
        .rg32float,
        .rgba16unorm,
        .rgba16snorm,
        .rgba16uint,
        .rgba16sint,
        .rgba16float,
        .bgra10_xr,
        .bgra10_xr_srgb,
        => 8,
        .rgba32uint,
        .rgba32sint,
        .rgba32float,
        => 128,
    };
}
