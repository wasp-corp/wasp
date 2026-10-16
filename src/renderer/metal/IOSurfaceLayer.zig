const IOSurfaceLayer = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const macos = @import("macos");
const IOSurface = macos.iosurface.IOSurface;
const log = std.log.scoped(.IOSurfaceLayer);
var Subclass: ?objc.Class = null;
layer: objc.Object,
pub fn init() !IOSurfaceLayer {
    const layer = (try getSubclass()).msgSend(
        objc.Object,
        objc.sel("layer"),
        .{},
    ).retain();
    errdefer layer.release();
    layer.setProperty("contentsGravity", macos.animation.kCAGravityTopLeft);
    layer.setInstanceVariable("display_cb", .{ .value = null });
    layer.setInstanceVariable("display_ctx", .{ .value = null });
    return .{ .layer = layer };
}
pub fn release(self: *IOSurfaceLayer) void {
    self.setDisplayCallback(null, null);
    self.layer.release();
}
pub inline fn setSurface(self: *IOSurfaceLayer, surface: *IOSurface) !void {
    surface.retain();
    var block = SetSurfaceBlock.init(.{
        .layer = self.layer.value,
        .surface = surface,
    }, &setSurfaceCallback);
    const NSThread = objc.getClass("NSThread").?;
    if (NSThread.msgSend(bool, "isMainThread", .{})) {
        setSurfaceCallback(&block);
    } else {
        macos.dispatch.dispatch_async(
            @ptrCast(macos.dispatch.queue.getMain()),
            @ptrCast(&block),
        );
    }
}
pub inline fn setSurfaceSync(self: *IOSurfaceLayer, surface: *IOSurface) void {
    self.layer.setProperty("contents", surface);
}
const SetSurfaceBlock = objc.Block(struct {
    layer: objc.c.id,
    surface: *IOSurface,
}, .{}, void);
fn setSurfaceCallback(
    block: *const SetSurfaceBlock.Context,
) callconv(.c) void {
    const layer = objc.Object.fromId(block.layer);
    const surface: *IOSurface = block.surface;
    defer surface.release();
    const bounds = layer.getProperty(macos.graphics.Rect, "bounds");
    const scale = layer.getProperty(f64, "contentsScale");
    const width: usize = @intFromFloat(bounds.size.width * scale);
    const height: usize = @intFromFloat(bounds.size.height * scale);
    if (width != surface.getWidth() or height != surface.getHeight()) {
        log.debug(
            "setSurfaceCallback(): surface is wrong size for layer, discarding. surface = {d}x{d}, layer = {d}x{d}",
            .{ surface.getWidth(), surface.getHeight(), width, height },
        );
        return;
    }
    layer.setProperty("contents", surface);
}
pub const DisplayCallback = ?*align(8) const fn (?*anyopaque) void;
pub fn setDisplayCallback(
    self: *IOSurfaceLayer,
    display_cb: DisplayCallback,
    display_ctx: ?*anyopaque,
) void {
    self.layer.setInstanceVariable(
        "display_cb",
        objc.Object.fromId(@constCast(display_cb)),
    );
    self.layer.setInstanceVariable(
        "display_ctx",
        objc.Object.fromId(display_ctx),
    );
}
fn getSubclass() error{ObjCFailed}!objc.Class {
    if (Subclass) |c| return c;
    const CALayer =
        objc.getClass("CALayer") orelse return error.ObjCFailed;
    var subclass =
        objc.allocateClassPair(CALayer, "IOSurfaceLayer") orelse return error.ObjCFailed;
    errdefer objc.disposeClassPair(subclass);
    if (!subclass.addIvar("display_cb")) return error.ObjCFailed;
    if (!subclass.addIvar("display_ctx")) return error.ObjCFailed;
    subclass.replaceMethod("display", struct {
        fn display(target: objc.c.id, sel: objc.c.SEL) callconv(.c) void {
            _ = sel;
            const self = objc.Object.fromId(target);
            const display_cb: DisplayCallback = @ptrFromInt(@intFromPtr(
                self.getInstanceVariable("display_cb").value,
            ));
            if (display_cb) |cb| cb(
                @ptrCast(self.getInstanceVariable("display_ctx").value),
            );
        }
    }.display);
    subclass.replaceMethod("actionForKey:", struct {
        fn actionForKey(
            target: objc.c.id,
            sel: objc.c.SEL,
            key: objc.c.id,
        ) callconv(.c) objc.c.id {
            _ = target;
            _ = sel;
            _ = key;
            return objc.getClass("NSNull").?.msgSend(objc.c.id, "null", .{});
        }
    }.actionForKey);
    objc.registerClassPair(subclass);
    Subclass = subclass;
    return subclass;
}
