const Device = @This();
const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc");
const mtl = @import("api.zig");
const shaders = @import("shaders.zig");
const log = std.log.scoped(.metal);
pub const Options = struct {};
device: objc.Object,
default_storage_mode: mtl.MTLResourceOptions.StorageMode,
max_texture_size: u32,
pub fn init(alloc: std.mem.Allocator, options: Options) !*Device {
    _ = options;
    const self = try alloc.create(Device);
    errdefer alloc.destroy(self);
    const device = try chooseDevice();
    errdefer device.release();
    const default_storage_mode: mtl.MTLResourceOptions.StorageMode = switch (comptime builtin.os.tag) {
        .ios => .shared,
        else => if (device.getProperty(bool, "hasUnifiedMemory")) .shared else .managed,
    };
    const max_texture_size = queryMaxTextureSize(device);
    log.debug(
        "device properties default_storage_mode={} max_texture_size={}",
        .{ default_storage_mode, max_texture_size },
    );
    self.* = .{
        .device = device,
        .default_storage_mode = default_storage_mode,
        .max_texture_size = max_texture_size,
    };
    return self;
}
pub fn deinit(self: *Device, alloc: std.mem.Allocator) void {
    self.device.release();
    alloc.destroy(self);
}
pub fn warmup() void {
    const device = chooseDevice() catch return;
    defer device.release();
    const queue = device.msgSend(objc.Object, objc.sel("newCommandQueue"), .{});
    queue.release();
    inline for (.{
        mtl.MTLPixelFormat.bgra8unorm_srgb,
        mtl.MTLPixelFormat.bgra8unorm,
    }) |format| {
        if (shaders.Shaders.init(
            std.heap.c_allocator,
            device,
            &.{},
            format,
        )) |s| {
            var s_mut = s;
            s_mut.deinit(std.heap.c_allocator);
        } else |err| {
            log.warn("metal warmup shader init failed err={}", .{err});
        }
    }
}
fn chooseDevice() error{NoMetalDevice}!objc.Object {
    var chosen_device: ?objc.Object = null;
    switch (comptime builtin.os.tag) {
        .macos => {
            const devices = objc.Object.fromId(mtl.MTLCopyAllDevices());
            defer devices.release();
            var iter = devices.iterate();
            while (iter.next()) |device| {
                if (device.getProperty(bool, "isHeadless")) continue;
                chosen_device = device;
                if (device.getProperty(bool, "isRemovable") or
                    device.getProperty(bool, "isLowPower")) break;
            }
        },
        .ios => {
            chosen_device = objc.Object.fromId(mtl.MTLCreateSystemDefaultDevice());
        },
        else => @compileError("unsupported target for Metal"),
    }
    const device = chosen_device orelse return error.NoMetalDevice;
    return device.retain();
}
fn queryMaxTextureSize(device: objc.Object) u32 {
    if (device.msgSend(
        bool,
        objc.sel("supportsFamily:"),
        .{mtl.MTLGPUFamily.apple10},
    )) return 32768;
    if (device.msgSend(
        bool,
        objc.sel("supportsFamily:"),
        .{mtl.MTLGPUFamily.apple3},
    )) return 16384;
    return 8192;
}
