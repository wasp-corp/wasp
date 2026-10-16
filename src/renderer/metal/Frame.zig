const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const mtl = @import("api.zig");
const Renderer = @import("../generic.zig").Renderer(Metal);
const Metal = @import("../Metal.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");
const Health = @import("../../renderer.zig").Health;
const log = std.log.scoped(.metal);
pub const Options = struct {
    queue: objc.Object,
};
buffer: objc.Object,
block: CompletionBlock.Context,
pub fn begin(
    opts: Options,
    renderer: *Renderer,
    target: *Target,
) !Self {
    const buffer = opts.queue.msgSend(
        objc.Object,
        objc.sel("commandBuffer"),
        .{},
    );
    const block = CompletionBlock.init(
        .{
            .renderer = renderer,
            .target = target,
            .sync = false,
        },
        &bufferCompleted,
    );
    return .{ .buffer = buffer, .block = block };
}
const CompletionBlock = objc.Block(struct {
    renderer: *Renderer,
    target: *Target,
    sync: bool,
}, .{
    objc.c.id, 
}, void);
fn bufferCompleted(
    block: *const CompletionBlock.Context,
    buffer_id: objc.c.id,
) callconv(.c) void {
    const buffer = objc.Object.fromId(buffer_id);
    const status = buffer.getProperty(mtl.MTLCommandBufferStatus, "status");
    const health: Health = switch (status) {
        .@"error" => .unhealthy,
        else => .healthy,
    };
    if (health == .healthy) {
        block.renderer.api.present(
            block.target.*,
            block.sync,
        ) catch |err| {
            log.err("Failed to present render target: err={}", .{err});
        };
    }
    block.renderer.frameCompleted(health);
}
pub inline fn renderPass(
    self: *const Self,
    attachments: []const RenderPass.Options.Attachment,
) RenderPass {
    return RenderPass.begin(.{
        .attachments = attachments,
        .command_buffer = self.buffer,
    });
}
pub inline fn complete(self: *Self, sync: bool) void {
    if (!sync) {
        self.buffer.msgSend(
            void,
            objc.sel("addCompletedHandler:"),
            .{&self.block},
        );
    }
    self.buffer.msgSend(void, objc.sel("commit"), .{});
    if (sync) {
        self.buffer.msgSend(void, "waitUntilCompleted", .{});
        self.block.sync = true;
        CompletionBlock.invoke(&self.block, .{self.buffer.value});
    }
}
