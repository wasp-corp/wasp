const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const global = @import("../../global.zig");
const Renderer = @import("../generic.zig").Renderer(OpenGL);
const OpenGL = @import("../OpenGL.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");
const Health = @import("../../renderer.zig").Health;
const log = std.log.scoped(.opengl);
pub const Options = struct {};
renderer: *Renderer,
target: *Target,
pub fn begin(
    opts: Options,
    renderer: *Renderer,
    target: *Target,
) !Self {
    _ = opts;
    return .{
        .renderer = renderer,
        .target = target,
    };
}
pub inline fn renderPass(
    self: *const Self,
    attachments: []const RenderPass.Options.Attachment,
) RenderPass {
    _ = self;
    return RenderPass.begin(.{ .attachments = attachments });
}
pub fn complete(self: *const Self, sync: bool) void {
    _ = sync;
    const health: Health = if (gl.errors.getError()) .healthy else |_| .unhealthy;
    const presented_frame: ?OpenGL.ExportedFrame = if (health == .healthy) frame: {
        const frame = self.renderer.api.present(
            self.target.*,
            self.renderer.presentationHealth(),
        ) catch |err| {
            log.warn("failed to present render target: err={}", .{err});
            break :frame null;
        };
        break :frame frame;
    } else null;
    gl.finish();
    if (presented_frame) |frame| {
        self.renderer.pushFrame(frame);
        _ = self.renderer.surface_mailbox.push(.redraw, .{ .forever = {} });
    }
    self.renderer.frameCompleted(health);
}
