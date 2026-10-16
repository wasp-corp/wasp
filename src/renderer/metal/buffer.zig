const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const macos = @import("macos");
const mtl = @import("api.zig");
const Metal = @import("../Metal.zig");
const log = std.log.scoped(.metal);
pub const Options = struct {
    device: objc.Object,
    resource_options: mtl.MTLResourceOptions,
};
pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();
        opts: Options,
        buffer: objc.Object,
        len: usize,
        pub fn init(opts: Options, len: usize) !Self {
            const buffer = opts.device.msgSend(
                objc.Object,
                objc.sel("newBufferWithLength:options:"),
                .{
                    @as(c_ulong, @intCast(len * @sizeOf(T))),
                    opts.resource_options,
                },
            );
            return .{ .buffer = buffer, .opts = opts, .len = len };
        }
        pub fn initFill(opts: Options, data: []const T) !Self {
            const buffer = opts.device.msgSend(
                objc.Object,
                objc.sel("newBufferWithBytes:length:options:"),
                .{
                    @as(*const anyopaque, @ptrCast(data.ptr)),
                    @as(c_ulong, @intCast(data.len * @sizeOf(T))),
                    opts.resource_options,
                },
            );
            return .{ .buffer = buffer, .opts = opts, .len = data.len };
        }
        pub fn deinit(self: *const Self) void {
            self.buffer.msgSend(void, objc.sel("release"), .{});
        }
        pub fn sync(self: *Self, data: []const T) !void {
            const req_bytes = data.len * @sizeOf(T);
            const avail_bytes = self.buffer.getProperty(c_ulong, "length");
            if (req_bytes > avail_bytes) {
                self.buffer.msgSend(void, objc.sel("release"), .{});
                self.len = data.len * 2;
                self.buffer = self.opts.device.msgSend(
                    objc.Object,
                    objc.sel("newBufferWithLength:options:"),
                    .{
                        @as(c_ulong, @intCast(self.len * @sizeOf(T))),
                        self.opts.resource_options,
                    },
                );
            }
            const dst = dst: {
                const ptr = self.buffer.msgSend(?[*]u8, objc.sel("contents"), .{}) orelse {
                    log.warn("buffer contents ptr is null", .{});
                    return error.MetalFailed;
                };
                break :dst ptr[0..req_bytes];
            };
            const src = src: {
                const ptr = @as([*]const u8, @ptrCast(data.ptr));
                break :src ptr[0..req_bytes];
            };
            @memcpy(dst, src);
            if (self.opts.resource_options.storage_mode == .managed) {
                self.buffer.msgSend(
                    void,
                    "didModifyRange:",
                    .{macos.foundation.Range.init(0, req_bytes)},
                );
            }
        }
        pub fn syncFromArrayLists(self: *Self, lists: []const std.ArrayListUnmanaged(T)) !usize {
            var total_len: usize = 0;
            for (lists) |list| {
                total_len += list.items.len;
            }
            const req_bytes = total_len * @sizeOf(T);
            const avail_bytes = self.buffer.getProperty(c_ulong, "length");
            if (req_bytes > avail_bytes) {
                self.buffer.msgSend(void, objc.sel("release"), .{});
                self.len = total_len * 2;
                self.buffer = self.opts.device.msgSend(
                    objc.Object,
                    objc.sel("newBufferWithLength:options:"),
                    .{
                        @as(c_ulong, @intCast(self.len * @sizeOf(T))),
                        self.opts.resource_options,
                    },
                );
            }
            const dst = dst: {
                const ptr = self.buffer.msgSend(?[*]u8, objc.sel("contents"), .{}) orelse {
                    log.warn("buffer contents ptr is null", .{});
                    return error.MetalFailed;
                };
                break :dst ptr[0..req_bytes];
            };
            var i: usize = 0;
            for (lists) |list| {
                const ptr = @as([*]const u8, @ptrCast(list.items.ptr));
                @memcpy(dst[i..][0 .. list.items.len * @sizeOf(T)], ptr);
                i += list.items.len * @sizeOf(T);
            }
            if (self.opts.resource_options.storage_mode == .managed) {
                self.buffer.msgSend(
                    void,
                    "didModifyRange:",
                    .{macos.foundation.Range.init(0, req_bytes)},
                );
            }
            return total_len;
        }
    };
}
