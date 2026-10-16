const Device = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const egl = gl.egl;
const log = std.log.scoped(.opengl);
pub const Options = struct {
    display: ?*egl.Display = null,
};
display: *egl.Display,
config: *egl.Config,
pub fn init(alloc: Allocator, options: Options) !*Device {
    const self = try alloc.create(Device);
    errdefer alloc.destroy(self);
    try egl.load();
    const display = options.display orelse egl.Display.initPlatform(
        egl.c.EGL_PLATFORM_SURFACELESS_MESA,
        egl.c.EGL_DEFAULT_DISPLAY,
        null,
    ) catch |err| {
        if (err == error.BadParameter) logUnsupportedPlatform();
        return err;
    };
    log.info("EGL vendor={s}", .{display.queryString(.vendor) orelse "(unknown)"});
    log.info("EGL extensions={s}", .{display.queryString(.extensions) orelse "(unknown)"});
    const config = egl.Config.choose(display, &.{
        egl.c.EGL_SURFACE_TYPE,    0,
        egl.c.EGL_RENDERABLE_TYPE, egl.c.EGL_OPENGL_BIT,
        egl.c.EGL_RED_SIZE,        8,
        egl.c.EGL_GREEN_SIZE,      8,
        egl.c.EGL_BLUE_SIZE,       8,
        egl.c.EGL_ALPHA_SIZE,      8,
    }) catch |err| {
        log.warn("failed to choose config err={}", .{err});
        return err;
    };
    self.* = .{
        .display = display,
        .config = config,
    };
    return self;
}
fn logUnsupportedPlatform() void {
    const exts = egl.queryClientExtensions() orelse "";
    if (exts.len == 0) {
        log.err("no EGL driver could be loaded; check that a GPU driver " ++
            "is installed and was built against a compatible libc " ++
            "(LD_DEBUG=libs shows why a driver failed to load)", .{});
        return;
    }
    if (!egl.hasExtension(exts, "EGL_MESA_platform_surfaceless")) {
        log.err("the EGL driver does not support EGL_MESA_platform_surfaceless " ++
            "client extensions={s}", .{exts});
        return;
    }
    log.err("the EGL driver rejected the surfaceless platform; " ++
        "client extensions={s}", .{exts});
}
pub fn deinit(self: *Device, alloc: std.mem.Allocator) void {
    alloc.destroy(self);
}
