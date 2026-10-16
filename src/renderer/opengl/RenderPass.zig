const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const Sampler = @import("Sampler.zig");
const Target = @import("Target.zig");
const Texture = @import("Texture.zig");
const Pipeline = @import("Pipeline.zig");
const Buffer = @import("buffer.zig").Buffer;
pub const Options = struct {
    attachments: []const Attachment,
    pub const Attachment = struct {
        target: union(enum) {
            texture: Texture,
            target: Target,
        },
        clear_color: ?[4]f32 = null,
    };
};
pub const Step = struct {
    pipeline: Pipeline,
    uniforms: ?gl.Buffer = null,
    buffers: []const ?gl.Buffer = &.{},
    textures: []const ?Texture = &.{},
    samplers: []const ?Sampler = &.{},
    draw: Draw,
    pub const Draw = struct {
        type: gl.Primitive,
        vertex_count: usize,
        instance_count: usize = 1,
    };
};
attachments: []const Options.Attachment,
step_number: usize = 0,
pub fn begin(
    opts: Options,
) Self {
    return .{
        .attachments = opts.attachments,
    };
}
pub fn step(self: *Self, s: Step) void {
    if (s.draw.instance_count == 0) return;
    const pbind = s.pipeline.program.use() catch return;
    defer pbind.unbind();
    const vaobind = s.pipeline.vao.bind() catch return;
    defer vaobind.unbind();
    const fbobind = switch (self.attachments[0].target) {
        .target => |t| t.framebuffer.bind(.framebuffer) catch return,
        .texture => |t| bind: {
            const fbobind = s.pipeline.fbo.bind(.framebuffer) catch return;
            fbobind.texture2D(.color0, t.target, t.texture, 0) catch {
                fbobind.unbind();
                return;
            };
            break :bind fbobind;
        },
    };
    defer fbobind.unbind();
    defer self.step_number += 1;
    if (self.step_number == 0) if (self.attachments[0].clear_color) |c| {
        gl.clearColor(c[0], c[1], c[2], c[3]);
        gl.clear(gl.c.GL_COLOR_BUFFER_BIT);
    };
    if (s.uniforms) |ubo| {
        _ = ubo.bindBase(.uniform, 1) catch return;
    }
    for (s.textures, 0..) |t, i| if (t) |tex| {
        gl.Texture.active(@intCast(i)) catch return;
        _ = tex.texture.bind(tex.target) catch return;
    };
    for (s.samplers, 0..) |s_, i| if (s_) |sampler| {
        _ = sampler.sampler.bind(@intCast(i)) catch return;
    };
    if (s.buffers.len > 0) {
        if (s.buffers[0]) |vbo| vaobind.bindVertexBuffer(
            0,
            vbo.id,
            0,
            @intCast(s.pipeline.stride),
        ) catch return;
        for (s.buffers[1..], 1..) |b, i| if (b) |buf| {
            _ = buf.bindBase(.storage, @intCast(i)) catch return;
        };
    }
    if (s.pipeline.blending_enabled) {
        gl.enable(gl.c.GL_BLEND) catch return;
        gl.blendFunc(gl.c.GL_ONE, gl.c.GL_ONE_MINUS_SRC_ALPHA) catch return;
    } else {
        gl.disable(gl.c.GL_BLEND) catch return;
    }
    gl.drawArraysInstanced(
        s.draw.type,
        0,
        @intCast(s.draw.vertex_count),
        @intCast(s.draw.instance_count),
    ) catch return;
}
pub fn complete(self: *const Self) void {
    _ = self;
    gl.flush();
}
