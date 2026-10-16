pub const Metal = @This();
const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const objc = @import("objc");
const macos = @import("macos");
const graphics = macos.graphics;
const apprt = @import("../apprt.zig");
const font = @import("../font/root.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(Metal);
const shadertoy = @import("shadertoy.zig");
const mtl = @import("metal/api.zig");
const IOSurfaceLayer = @import("metal/IOSurfaceLayer.zig");
pub const Device = @import("metal/Device.zig");
pub const GraphicsAPI = Metal;
pub const Target = @import("metal/Target.zig");
pub const Frame = @import("metal/Frame.zig");
pub const RenderPass = @import("metal/RenderPass.zig");
pub const Pipeline = @import("metal/Pipeline.zig");
const bufferpkg = @import("metal/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("metal/Sampler.zig");
pub const Texture = @import("metal/Texture.zig");
pub const shaders = @import("metal/shaders.zig");
pub const custom_shader_target: shadertoy.Target = .msl;
pub const custom_shader_y_is_down = true;
pub const swap_chain_count = 3;
const log = std.log.scoped(.metal);
layer: IOSurfaceLayer,
device: *const Device,
queue: objc.Object,
blending: configpkg.Config.AlphaBlending,
autorelease_pool: ?*objc.AutoreleasePool = null,
pub fn init(
    alloc: Allocator,
    device: *const Device,
    opts: rendererpkg.Options,
) !Metal {
    comptime switch (builtin.os.tag) {
        .macos, .ios => {},
        else => @compileError("unsupported platform for Metal"),
    };
    _ = alloc;
    const mtl_device = device.device;
    const queue = mtl_device.msgSend(objc.Object, objc.sel("newCommandQueue"), .{});
    errdefer queue.release();
    const ViewInfo = struct {
        view: objc.Object,
        scaleFactor: f64,
    };
    const info: ViewInfo = switch (apprt.runtime) {
        apprt.embedded => .{
            .scaleFactor = @floatCast(opts.rt_surface.content_scale.x),
            .view = switch (opts.rt_surface.platform) {
                .macos => |v| v.nsview,
                .ios => |v| v.uiview,
            },
        },
        else => @compileError("unsupported apprt for metal"),
    };
    var layer = try IOSurfaceLayer.init();
    errdefer layer.release();
    switch (comptime builtin.os.tag) {
        .macos => {
            info.view.setProperty("layer", layer.layer.value);
            info.view.setProperty("wantsLayer", true);
        },
        .ios => {
            const view_layer = objc.Object.fromId(info.view.getProperty(?*anyopaque, "layer"));
            view_layer.msgSend(void, objc.sel("addSublayer:"), .{layer.layer.value});
        },
        else => @compileError("unsupported target for Metal"),
    }
    info.view.setProperty("clipsToBounds", true);
    layer.layer.setProperty("contentsScale", info.scaleFactor);
    layer.layer.setProperty("needsDisplayOnBoundsChange", true);
    return .{
        .layer = layer,
        .device = device,
        .queue = queue,
        .blending = opts.config.blending,
    };
}
pub fn deinit(self: *Metal) void {
    self.queue.release();
    self.layer.release();
}
pub fn loopEnter(self: *Metal) void {
    const renderer: *align(1) Renderer = @fieldParentPtr("api", self);
    self.layer.setDisplayCallback(
        @ptrCast(&displayCallback),
        @ptrCast(renderer),
    );
}
fn displayCallback(renderer: *Renderer) align(8) void {
    renderer.drawFrame(true) catch |err| {
        log.warn("Error drawing frame in display callback, err={}", .{err});
    };
}
pub fn drawFrameStart(self: *Metal) void {
    assert(self.autorelease_pool == null);
    self.autorelease_pool = .init();
}
pub fn drawFrameEnd(self: *Metal) void {
    assert(self.autorelease_pool != null);
    self.autorelease_pool.?.deinit();
    self.autorelease_pool = null;
}
pub fn initShaders(
    self: *const Metal,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    return try shaders.Shaders.init(
        alloc,
        self.device.device,
        custom_shaders,
        if (self.blending.isLinear())
            mtl.MTLPixelFormat.bgra8unorm_srgb
        else
            mtl.MTLPixelFormat.bgra8unorm,
    );
}
pub fn surfaceSize(self: *const Metal) !struct { width: u32, height: u32 } {
    const bounds = self.layer.layer.getProperty(graphics.Rect, "bounds");
    const scale = self.layer.layer.getProperty(f64, "contentsScale");
    return .{
        .width = @min(
            @as(u32, @intFromFloat(bounds.size.width * scale)),
            self.device.max_texture_size,
        ),
        .height = @min(
            @as(u32, @intFromFloat(bounds.size.height * scale)),
            self.device.max_texture_size,
        ),
    };
}
pub fn initTarget(self: *const Metal, width: usize, height: usize) !Target {
    return Target.init(.{
        .device = self.device.device,
        .pixel_format = if (self.blending.isLinear())
            .bgra8unorm_srgb
        else
            .bgra8unorm,
        .storage_mode = self.device.default_storage_mode,
        .width = width,
        .height = height,
    });
}
pub inline fn present(self: *Metal, target: Target, sync: bool) !void {
    if (sync) {
        self.layer.setSurfaceSync(target.surface);
    } else {
        try self.layer.setSurface(target.surface);
    }
}
pub inline fn bufferOptions(self: Metal) bufferpkg.Options {
    return .{
        .device = self.device.device,
        .resource_options = .{
            .cpu_cache_mode = .write_combined,
            .storage_mode = self.device.default_storage_mode,
        },
    };
}
pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;
pub inline fn textureOptions(self: Metal) Texture.Options {
    return .{
        .device = self.device.device,
        .pixel_format = if (self.blending.isLinear())
            .bgra8unorm_srgb
        else
            .bgra8unorm,
        .resource_options = .{
            .cpu_cache_mode = .write_combined,
            .storage_mode = self.device.default_storage_mode,
        },
        .usage = .{
            .shader_read = true,
            .render_target = true,
        },
    };
}
pub inline fn samplerOptions(self: Metal) Sampler.Options {
    return .{
        .device = self.device.device,
        .min_filter = .linear,
        .mag_filter = .linear,
        .s_address_mode = .clamp_to_edge,
        .t_address_mode = .clamp_to_edge,
    };
}
pub const ImageTextureFormat = enum {
    gray,
    rgba,
    bgra,
    fn toPixelFormat(
        self: ImageTextureFormat,
        srgb: bool,
    ) mtl.MTLPixelFormat {
        return switch (self) {
            .gray => if (srgb) .r8unorm_srgb else .r8unorm,
            .rgba => if (srgb) .rgba8unorm_srgb else .rgba8unorm,
            .bgra => if (srgb) .bgra8unorm_srgb else .bgra8unorm,
        };
    }
};
pub inline fn imageTextureOptions(
    self: Metal,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    return .{
        .device = self.device.device,
        .pixel_format = format.toPixelFormat(srgb),
        .resource_options = .{
            .cpu_cache_mode = .write_combined,
            .storage_mode = self.device.default_storage_mode,
        },
        .usage = .{
            .shader_read = true,
        },
    };
}
pub fn initAtlasTexture(
    self: *const Metal,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    const pixel_format: mtl.MTLPixelFormat = switch (atlas.format) {
        .grayscale => .r8unorm,
        .bgra => .bgra8unorm_srgb,
        else => @panic("unsupported atlas format for Metal texture"),
    };
    return try Texture.init(
        .{
            .device = self.device.device,
            .pixel_format = pixel_format,
            .resource_options = .{
                .cpu_cache_mode = .write_combined,
                .storage_mode = self.device.default_storage_mode,
            },
            .usage = .{
                .shader_read = true,
            },
        },
        atlas.size,
        atlas.size,
        null,
    );
}
pub inline fn beginFrame(
    self: *const Metal,
    renderer: *Renderer,
    target: *Target,
) !Frame {
    return try Frame.begin(.{ .queue = self.queue }, renderer, target);
}
