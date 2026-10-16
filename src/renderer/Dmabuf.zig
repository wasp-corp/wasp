pub const Dmabuf = @This();
pub const std = @import("std");
pub const max_planes = 4;
width: u32,
height: u32,
fourcc: u32,
modifier: u64,
premultiplied: bool,
planes: Planes,
pub const Planes = struct {
    count: u8,
    fds: [max_planes]std.posix.fd_t = @splat(-1),
    offsets: [max_planes]c_int = @splat(0),
    strides: [max_planes]c_int = @splat(0),
    pub fn deinit(self: Planes) void {
        for (self.fds[0..self.count]) |fd| {
            if (fd >= 0) _ = std.posix.system.close(fd);
        }
    }
    pub fn validate(self: Planes) error{BadDmabuf}!void {
        var n_valid: usize = 0;
        while (n_valid < self.count) : (n_valid += 1) {
            if (self.fds[n_valid] < 0) {
                for (self.fds[0..n_valid]) |bad| _ = std.posix.system.close(bad);
                return error.BadDmabuf;
            }
        }
    }
};
pub fn deinit(self: Dmabuf) void {
    self.planes.deinit();
}
