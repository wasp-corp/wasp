const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const OpenGL = @import("../OpenGL.zig");
const log = std.log.scoped(.opengl);
pub const Options = struct {
    target: gl.Buffer.Target = .array,
    usage: gl.Buffer.Usage = .dynamic_draw,
};
pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();
        buffer: gl.Buffer,
        opts: Options,
        len: usize,
        pub fn init(opts: Options, len: usize) !Self {
            const buffer = try gl.Buffer.create();
            errdefer buffer.destroy();
            const binding = try buffer.bind(opts.target);
            defer binding.unbind();
            try binding.setDataNullManual(len * @sizeOf(T), opts.usage);
            return .{
                .buffer = buffer,
                .opts = opts,
                .len = len,
            };
        }
        pub fn initFill(opts: Options, data: []const T) !Self {
            const buffer = try gl.Buffer.create();
            errdefer buffer.destroy();
            const binding = try buffer.bind(opts.target);
            defer binding.unbind();
            try binding.setData(data, opts.usage);
            return .{
                .buffer = buffer,
                .opts = opts,
                .len = data.len * @sizeOf(T),
            };
        }
        pub fn deinit(self: Self) void {
            self.buffer.destroy();
        }
        pub fn sync(self: *Self, data: []const T) !void {
            const binding = try self.buffer.bind(self.opts.target);
            defer binding.unbind();
            if (data.len > self.len) {
                self.len = data.len * 2;
                try binding.setDataNullManual(
                    self.len * @sizeOf(T),
                    self.opts.usage,
                );
            }
            try binding.setSubData(0, data);
        }
        pub fn syncFromArrayLists(self: *Self, lists: []const std.ArrayListUnmanaged(T)) !usize {
            const binding = try self.buffer.bind(self.opts.target);
            defer binding.unbind();
            var total_len: usize = 0;
            for (lists) |list| {
                total_len += list.items.len;
            }
            if (total_len > self.len) {
                self.len = total_len * 2;
                try binding.setDataNullManual(
                    self.len * @sizeOf(T),
                    self.opts.usage,
                );
            }
            var i: usize = 0;
            for (lists) |list| {
                try binding.setSubData(i, list.items);
                i += list.items.len * @sizeOf(T);
            }
            return total_len;
        }
    };
}
