const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const mtl = @import("api.zig");
const Metal = @import("../Metal.zig");
const log = std.log.scoped(.metal);
pub const Options = struct {
    device: objc.Object,
    min_filter: mtl.MTLSamplerMinMagFilter,
    mag_filter: mtl.MTLSamplerMinMagFilter,
    s_address_mode: mtl.MTLSamplerAddressMode,
    t_address_mode: mtl.MTLSamplerAddressMode,
};
sampler: objc.Object,
pub const Error = error{
    MetalFailed,
};
pub fn init(
    opts: Options,
) Error!Self {
    const desc = init: {
        const Class = objc.getClass("MTLSamplerDescriptor").?;
        const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
        const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
        break :init id_init;
    };
    defer desc.release();
    desc.setProperty("minFilter", opts.min_filter);
    desc.setProperty("magFilter", opts.mag_filter);
    desc.setProperty("sAddressMode", opts.s_address_mode);
    desc.setProperty("tAddressMode", opts.t_address_mode);
    const id = opts.device.msgSend(
        ?*anyopaque,
        objc.sel("newSamplerStateWithDescriptor:"),
        .{desc},
    ) orelse return error.MetalFailed;
    return .{
        .sampler = objc.Object.fromId(id),
    };
}
pub fn deinit(self: Self) void {
    self.sampler.release();
}
