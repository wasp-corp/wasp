const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gdk = @import("gdk");
const gtk = @import("gtk");
const global = @import("../../../global.zig");
const Application = @import("application.zig").Application;
const Common = @import("../class.zig").Common;
const scale_util = @import("../scale.zig");
const CoreSurface = @import("../../../Surface.zig");
const rendererpkg = @import("../../../renderer.zig");
const ExportedFrame = rendererpkg.Renderer.ExportedFrame;
const Dmabuf = @import("../../../renderer/Dmabuf.zig");
const Planes = Dmabuf.Planes;
const log = std.log.scoped(.gtk_render_surface);
pub const RenderSurface = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Widget;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WaspRenderSurface",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });
    const C = Common(Self, Private);
    pub const Private = struct {
        core_surface: ?*CoreSurface = null,
        texture: ?*gdk.Texture = null,
        scale_notify_id: c_ulong = 0,
        scale_surface: ?*gdk.Surface = null,
        scale_logged_size: bool = false,
        pub var offset: c_int = 0;
    };
    const private = C.private;
    pub const as = C.as;
    pub const signals = struct {
        pub const resize = struct {
            pub const name = "resize";
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{ c_int, c_int },
                void,
            );
        };
    };
    fn realize(self: *Self) callconv(.c) void {
        gtk.Widget.virtual_methods.realize.call(
            Class.parent,
            self.as(gtk.Widget),
        );
        self.connectScaleNotify();
        self.as(gtk.Widget).queueDraw();
    }
    fn unrealize(self: *Self) callconv(.c) void {
        const priv = self.private();
        self.disconnectScaleNotify();
        if (priv.texture) |tex| {
            tex.as(gobject.Object).unref();
            priv.texture = null;
        }
        gtk.Widget.virtual_methods.unrealize.call(
            Class.parent,
            self.as(gtk.Widget),
        );
    }
    fn sizeAllocate(
        self: *Self,
        width: c_int,
        height: c_int,
        baseline: c_int,
    ) callconv(.c) void {
        self.connectScaleNotify();
        self.emitDeviceResize(width, height);
        gtk.Widget.virtual_methods.size_allocate.call(
            Class.parent,
            self.as(gtk.Widget),
            width,
            height,
            baseline,
        );
        const priv = self.private();
        if (!priv.scale_logged_size and width > 0 and height > 0) {
            self.logScale("allocated", width, height);
            priv.scale_logged_size = true;
        }
    }
    fn snapshot(self: *Self, snap: *gtk.Snapshot) callconv(.c) void {
        const priv = self.private();
        if (priv.core_surface) |core| {
            if (core.renderer.takeFrame()) |frame| {
                self.rebuildTexture(frame) catch |err| switch (err) {
                    error.DmabufBuildFailed => {
                        log.warn(
                            "failed to import dmabuf, asking renderer for CPU presentation",
                            .{},
                        );
                        core.reportPresentationHealth(.unhealthy);
                    },
                    else => log.warn("error building texture from frame err={}", .{err}),
                };
            }
        }
        const texture = priv.texture orelse return;
        const widget = self.as(gtk.Widget);
        if (widget.getWidth() == 0 or widget.getHeight() == 0) return;
        const layout = scale_util.widgetLayout(widget);
        const origin = layout.snapOrigin();
        const scale: f32 = @floatCast(layout.scale);
        const css_w: f32 = @as(f32, @floatFromInt(texture.getWidth())) / scale;
        const css_h: f32 = @as(f32, @floatFromInt(texture.getHeight())) / scale;
        const flip = !rendererpkg.Renderer.custom_shader_y_is_down;
        if (flip) snap.save();
        defer if (flip) snap.restore();
        if (flip) {
            snap.translate(&.{ .f_x = 0, .f_y = css_h });
            snap.scale(1, -1);
        }
        snap.appendTexture(texture, &.{
            .f_origin = .{ .f_x = @floatCast(origin.x), .f_y = @floatCast(origin.y) },
            .f_size = .{ .f_width = css_w, .f_height = css_h },
        });
    }
    pub fn deviceSize(self: *Self) struct { width: u32, height: u32 } {
        const size = scale_util.widgetLayout(self.as(gtk.Widget)).size;
        return .{ .width = size.width, .height = size.height };
    }
    fn emitDeviceResize(self: *Self, css_w: c_int, css_h: c_int) void {
        const size = scale_util.widgetLayoutForSize(self.as(gtk.Widget), css_w, css_h).size;
        if (size.width == 0 or size.height == 0) return;
        signals.resize.impl.emit(
            self,
            null,
            .{ @intCast(size.width), @intCast(size.height) },
            null,
        );
    }
    fn connectScaleNotify(self: *Self) void {
        const native = self.as(gtk.Widget).getNative() orelse return;
        const surface = native.getSurface() orelse return;
        const priv = self.private();
        if (priv.scale_notify_id != 0) {
            if (priv.scale_surface == surface) return;
            self.disconnectScaleNotify();
        }
        _ = surface.as(gobject.Object).ref();
        priv.scale_surface = surface;
        priv.scale_logged_size = false;
        priv.scale_notify_id = gobject.Object.signals.notify.connect(
            surface,
            *Self,
            onScaleNotify,
            self,
            .{ .detail = "scale" },
        );
        const widget = self.as(gtk.Widget);
        self.logScale("connected", widget.getWidth(), widget.getHeight());
    }
    fn disconnectScaleNotify(self: *Self) void {
        const priv = self.private();
        if (priv.scale_notify_id == 0) return;
        if (priv.scale_surface) |surface| {
            gobject.signalHandlerDisconnect(
                surface.as(gobject.Object),
                priv.scale_notify_id,
            );
            surface.as(gobject.Object).unref();
        }
        priv.scale_notify_id = 0;
        priv.scale_surface = null;
    }
    fn onScaleNotify(
        _: *gdk.Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const widget = self.as(gtk.Widget);
        self.logScale("changed", widget.getWidth(), widget.getHeight());
        self.emitDeviceResize(widget.getWidth(), widget.getHeight());
        widget.queueDraw();
    }
    fn logScale(self: *Self, event: []const u8, css_width: c_int, css_height: c_int) void {
        const widget = self.as(gtk.Widget);
        const native = widget.getNative() orelse return;
        const surface = native.getSurface() orelse return;
        const layout = scale_util.widgetLayoutForSize(widget, css_width, css_height);
        log.debug(
            "surface scale {s}: css={}x{} device={}x{} surface={d} effective={d} surface_factor={} widget_factor={}",
            .{
                event,
                css_width,
                css_height,
                layout.size.width,
                layout.size.height,
                surface.getScale(),
                layout.scale,
                surface.getScaleFactor(),
                widget.getScaleFactor(),
            },
        );
    }
    pub fn setCoreSurface(self: *Self, core: ?*CoreSurface) void {
        self.private().core_surface = core;
    }
    fn rebuildTexture(self: *Self, frame: ExportedFrame) !void {
        switch (frame) {
            .dmabuf => |dmabuf| try self.rebuildDmabufTexture(dmabuf),
            .memory => |memory| try self.rebuildMemoryTexture(memory),
        }
    }
    fn rebuildDmabufTexture(self: *Self, frame: Dmabuf) !void {
        const priv = self.private();
        const widget = self.as(gtk.Widget);
        const display = widget.getDisplay();
        const builder = gdk.DmabufTextureBuilder.new();
        defer builder.unref();
        builder.setDisplay(display);
        builder.setWidth(frame.width);
        builder.setHeight(frame.height);
        builder.setFourcc(frame.fourcc);
        builder.setModifier(frame.modifier);
        builder.setPremultiplied(@intFromBool(frame.premultiplied));
        builder.setNPlanes(@intCast(frame.planes.count));
        for (0..frame.planes.count) |i| {
            builder.setFd(@intCast(i), frame.planes.fds[i]);
            builder.setOffset(@intCast(i), @intCast(frame.planes.offsets[i]));
            builder.setStride(@intCast(i), @intCast(frame.planes.strides[i]));
        }
        const app = Application.default();
        const alloc = app.allocator();
        const planes = try alloc.create(Planes);
        errdefer alloc.destroy(planes);
        planes.* = frame.planes;
        errdefer planes.deinit();
        var err_: ?*glib.Error = null;
        const texture = builder.build(
            dmabufDestroy,
            planes,
            &err_,
        ) orelse {
            if (err_) |err|
                log.warn("failed to build dmabuf err={s}", .{err.f_message orelse "(unknown)"});
            return error.DmabufBuildFailed;
        };
        if (priv.texture) |old| old.as(gobject.Object).unref();
        priv.texture = texture;
    }
    fn dmabufDestroy(data: ?*anyopaque) callconv(.c) void {
        const app = Application.default();
        const alloc = app.allocator();
        const planes: *Planes = @ptrCast(@alignCast(data orelse return));
        planes.deinit();
        alloc.destroy(planes);
    }
    const MemoryHolder = struct {
        alloc: std.mem.Allocator,
        pixels: []u8,
    };
    fn rebuildMemoryTexture(self: *Self, frame: ExportedFrame.Memory) !void {
        const priv = self.private();
        const app = Application.default();
        const alloc = app.allocator();
        const holder = alloc.create(MemoryHolder) catch |err| {
            frame.deinit();
            return err;
        };
        errdefer alloc.destroy(holder);
        holder.* = .{ .alloc = alloc, .pixels = frame.pixels };
        const bytes = glib.Bytes.newWithFreeFunc(
            holder.pixels.ptr,
            holder.pixels.len,
            &memoryDestroy,
            holder,
        );
        errdefer bytes.unref();
        const texture = gdk.MemoryTexture.new(
            @intCast(frame.width),
            @intCast(frame.height),
            .r8g8b8a8_premultiplied,
            bytes,
            frame.width * 4,
        );
        bytes.unref();
        if (priv.texture) |old| old.as(gobject.Object).unref();
        priv.texture = texture.as(gdk.Texture);
    }
    fn memoryDestroy(data: ?*anyopaque) callconv(.c) void {
        const holder: *MemoryHolder = @ptrCast(@alignCast(data orelse return));
        holder.alloc.free(holder.pixels);
        holder.alloc.destroy(holder);
    }
    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;
        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.virtual_methods.realize.implement(class, &realize);
            gtk.Widget.virtual_methods.unrealize.implement(class, &unrealize);
            gtk.Widget.virtual_methods.size_allocate.implement(class, &sizeAllocate);
            gtk.Widget.virtual_methods.snapshot.implement(class, &snapshot);
            signals.resize.impl.register(.{});
        }
        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
