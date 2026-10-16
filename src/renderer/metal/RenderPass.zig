const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const mtl = @import("api.zig");
const Pipeline = @import("Pipeline.zig");
const Sampler = @import("Sampler.zig");
const Texture = @import("Texture.zig");
const Target = @import("Target.zig");
const log = std.log.scoped(.metal);
pub const Options = struct {
    command_buffer: objc.Object,
    attachments: []const Attachment,
    pub const Attachment = struct {
        target: union(enum) {
            texture: Texture,
            target: Target,
        },
        clear_color: ?[4]f64 = null,
    };
};
pub const Step = struct {
    pipeline: Pipeline,
    uniforms: ?objc.Object = null,
    buffers: []const ?objc.Object = &.{},
    textures: []const ?Texture = &.{},
    samplers: []const ?Sampler = &.{},
    draw: Draw,
    pub const Draw = struct {
        type: mtl.MTLPrimitiveType,
        vertex_count: usize,
        instance_count: usize = 1,
    };
};
encoder: objc.Object,
pub fn begin(
    opts: Options,
) Self {
    const desc = desc: {
        const MTLRenderPassDescriptor = objc.getClass("MTLRenderPassDescriptor").?;
        const desc = MTLRenderPassDescriptor.msgSend(
            objc.Object,
            objc.sel("renderPassDescriptor"),
            .{},
        );
        const attachments = objc.Object.fromId(
            desc.getProperty(?*anyopaque, "colorAttachments"),
        );
        for (opts.attachments, 0..) |at, i| {
            const attachment = attachments.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, i)},
            );
            attachment.setProperty(
                "loadAction",
                @intFromEnum(@as(
                    mtl.MTLLoadAction,
                    if (at.clear_color != null)
                        .clear
                    else
                        .load,
                )),
            );
            attachment.setProperty(
                "storeAction",
                @intFromEnum(mtl.MTLStoreAction.store),
            );
            attachment.setProperty("texture", switch (at.target) {
                .texture => |t| t.texture.value,
                .target => |t| t.texture.value,
            });
            if (at.clear_color) |c| attachment.setProperty(
                "clearColor",
                mtl.MTLClearColor{
                    .red = c[0],
                    .green = c[1],
                    .blue = c[2],
                    .alpha = c[3],
                },
            );
        }
        break :desc desc;
    };
    const encoder = opts.command_buffer.msgSend(
        objc.Object,
        objc.sel("renderCommandEncoderWithDescriptor:"),
        .{desc.value},
    );
    return .{ .encoder = encoder };
}
pub fn step(self: *const Self, s: Step) void {
    if (s.draw.instance_count == 0) return;
    self.encoder.msgSend(
        void,
        objc.sel("setRenderPipelineState:"),
        .{s.pipeline.state.value},
    );
    if (s.buffers.len > 0) {
        if (s.buffers[0]) |buf| {
            self.encoder.msgSend(
                void,
                objc.sel("setVertexBuffer:offset:atIndex:"),
                .{ buf.value, @as(c_ulong, 0), @as(c_ulong, 0) },
            );
            self.encoder.msgSend(
                void,
                objc.sel("setFragmentBuffer:offset:atIndex:"),
                .{ buf.value, @as(c_ulong, 0), @as(c_ulong, 0) },
            );
        }
        for (s.buffers[1..], 2..) |b, i| if (b) |buf| {
            self.encoder.msgSend(
                void,
                objc.sel("setVertexBuffer:offset:atIndex:"),
                .{ buf.value, @as(c_ulong, 0), @as(c_ulong, i) },
            );
            self.encoder.msgSend(
                void,
                objc.sel("setFragmentBuffer:offset:atIndex:"),
                .{ buf.value, @as(c_ulong, 0), @as(c_ulong, i) },
            );
        };
    }
    if (s.uniforms) |buf| {
        self.encoder.msgSend(
            void,
            objc.sel("setVertexBuffer:offset:atIndex:"),
            .{ buf.value, @as(c_ulong, 0), @as(c_ulong, 1) },
        );
        self.encoder.msgSend(
            void,
            objc.sel("setFragmentBuffer:offset:atIndex:"),
            .{ buf.value, @as(c_ulong, 0), @as(c_ulong, 1) },
        );
    }
    for (s.textures, 0..) |t, i| if (t) |tex| {
        self.encoder.msgSend(
            void,
            objc.sel("setVertexTexture:atIndex:"),
            .{ tex.texture.value, @as(c_ulong, i) },
        );
        self.encoder.msgSend(
            void,
            objc.sel("setFragmentTexture:atIndex:"),
            .{ tex.texture.value, @as(c_ulong, i) },
        );
    };
    for (s.samplers, 0..) |samp, i| if (samp) |sampler| {
        self.encoder.msgSend(
            void,
            objc.sel("setFragmentSamplerState:atIndex:"),
            .{ sampler.sampler.value, @as(c_ulong, i) },
        );
    };
    self.encoder.msgSend(
        void,
        objc.sel("drawPrimitives:vertexStart:vertexCount:instanceCount:"),
        .{
            @intFromEnum(s.draw.type),
            @as(c_ulong, 0),
            @as(c_ulong, s.draw.vertex_count),
            @as(c_ulong, s.draw.instance_count),
        },
    );
}
pub fn complete(self: *const Self) void {
    self.encoder.msgSend(void, objc.sel("endEncoding"), .{});
}
