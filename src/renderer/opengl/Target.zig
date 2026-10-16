const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const egl = gl.egl;
const Dmabuf = @import("../Dmabuf.zig");
const log = std.log.scoped(.opengl);
pub const Options = struct {
    width: usize,
    height: usize,
};
framebuffer: gl.Framebuffer,
texture: gl.Texture,
export_texture: gl.Texture,
export_framebuffer: gl.Framebuffer,
width: usize,
height: usize,
pub fn init(opts: Options) !Self {
    const texture = try gl.Texture.create();
    errdefer texture.destroy();
    {
        const bound_tex = try texture.bind(.@"2d");
        defer bound_tex.unbind();
        try bound_tex.parameter(.min_filter, .nearest);
        try bound_tex.parameter(.mag_filter, .nearest);
        try bound_tex.parameter(.wrap_s, .clamp_to_edge);
        try bound_tex.parameter(.wrap_t, .clamp_to_edge);
        try bound_tex.image2D(
            0,
            .srgba,
            @intCast(opts.width),
            @intCast(opts.height),
            .rgba,
            .unsigned_byte,
            null,
        );
        try bound_tex.parameter(.base_level, 0);
        try bound_tex.parameter(.max_level, 0);
    }
    const fbo = try gl.Framebuffer.create();
    errdefer fbo.destroy();
    {
        const bound_fbo = try fbo.bind(.framebuffer);
        defer bound_fbo.unbind();
        try bound_fbo.texture2D(.color0, .@"2d", texture, 0);
        switch (bound_fbo.checkStatus()) {
            .complete => {},
            else => |status| {
                log.warn("render framebuffer incomplete status={}", .{status});
                return error.FramebufferIncomplete;
            },
        }
    }
    const export_texture = try gl.Texture.create();
    errdefer export_texture.destroy();
    {
        const bound_tex = try export_texture.bind(.@"2d");
        defer bound_tex.unbind();
        try bound_tex.parameter(.min_filter, .nearest);
        try bound_tex.parameter(.mag_filter, .nearest);
        try bound_tex.parameter(.wrap_s, .clamp_to_edge);
        try bound_tex.parameter(.wrap_t, .clamp_to_edge);
        try bound_tex.image2D(
            0,
            .rgba,
            @intCast(opts.width),
            @intCast(opts.height),
            .rgba,
            .unsigned_byte,
            null,
        );
        try bound_tex.parameter(.base_level, 0);
        try bound_tex.parameter(.max_level, 0);
    }
    const export_fbo = try gl.Framebuffer.create();
    errdefer export_fbo.destroy();
    {
        const bound_fbo = try export_fbo.bind(.framebuffer);
        defer bound_fbo.unbind();
        try bound_fbo.texture2D(.color0, .@"2d", export_texture, 0);
        switch (bound_fbo.checkStatus()) {
            .complete => {},
            else => |status| {
                log.warn("export framebuffer incomplete status={}", .{status});
                return error.FramebufferIncomplete;
            },
        }
    }
    return .{
        .framebuffer = fbo,
        .texture = texture,
        .export_framebuffer = export_fbo,
        .export_texture = export_texture,
        .width = opts.width,
        .height = opts.height,
    };
}
pub fn deinit(self: *Self) void {
    self.framebuffer.destroy();
    self.texture.destroy();
    self.export_framebuffer.destroy();
    self.export_texture.destroy();
}
pub fn exportDmabuf(
    self: *const Self,
    display: *egl.Display,
    context: *egl.Context,
) !Dmabuf {
    try gl.disable(gl.c.GL_FRAMEBUFFER_SRGB);
    defer gl.enable(gl.c.GL_FRAMEBUFFER_SRGB) catch |err| {
        log.err("Error re-enabling GL_FRAMEBUFFER_SRGB, err={}", .{err});
    };
    const read_bind = try self.framebuffer.bind(.read);
    defer read_bind.unbind();
    const draw_bind = try self.export_framebuffer.bind(.draw);
    defer draw_bind.unbind();
    try gl.blitFramebuffer(
        0,
        0,
        @intCast(self.width),
        @intCast(self.height),
        0,
        0,
        @intCast(self.width),
        @intCast(self.height),
        .{ .color_buffer_bit = true },
        .nearest,
    );
    const image: *egl.Image = try .create(
        display,
        context,
        .{ .texture_2d = self.export_texture.id },
        &.{},
    );
    defer image.destroy(display) catch {};
    const query = try image.exportDmabufQuery(display);
    if (query.num_planes < 1 or query.num_planes > Dmabuf.max_planes) {
        log.err("DMABUF has too many planes={}", .{query.num_planes});
        return error.DmabufTooManyPlanes;
    }
    var planes: Dmabuf.Planes = .{ .count = @intCast(query.num_planes) };
    try image.exportDmabuf(
        display,
        &planes.fds,
        &planes.strides,
        &planes.offsets,
    );
    try planes.validate();
    return .{
        .width = @intCast(self.width),
        .height = @intCast(self.height),
        .fourcc = @bitCast(query.fourcc),
        .modifier = query.modifier,
        .premultiplied = true,
        .planes = planes,
    };
}
pub fn readPixelsAlloc(self: *const Self, alloc: std.mem.Allocator) ![]u8 {
    const bind = try self.framebuffer.bind(.read);
    defer bind.unbind();
    const pixels = try alloc.alloc(u8, self.width * self.height * 4);
    errdefer alloc.free(pixels);
    try gl.readPixels(
        0,
        0,
        @intCast(self.width),
        @intCast(self.height),
        .rgba,
        .unsigned_byte,
        pixels.ptr,
    );
    return pixels;
}
