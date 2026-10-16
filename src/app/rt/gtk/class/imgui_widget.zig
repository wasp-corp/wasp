const std = @import("std");
const assert = @import("../../../quirks.zig").inlineAssert;
const cimgui = @import("dcimgui");
const gl = @import("opengl");
const adw = @import("adw");
const gdk = @import("gdk");
const gobject = @import("gobject");
const gtk = @import("gtk");
const global = @import("../../../global.zig");
const input = @import("../../../input.zig");
const gresource = @import("../build/gresource.zig");
const key = @import("../key.zig");
const Common = @import("../class.zig").Common;
const log = std.log.scoped(.gtk_wasp_imgui_widget);
pub const ImguiWidget = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WaspImguiWidget",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });
    pub const properties = struct {};
    pub const signals = struct {};
    pub const virtual_methods = struct {
        pub const setup = C.defineVirtualMethod("setup");
        pub const render = C.defineVirtualMethod("render");
    };
    const Private = struct {
        gl_area: *gtk.GLArea,
        im_context: *gtk.IMMulticontext,
        ig_context: ?*cimgui.c.ImGuiContext = null,
        instant: ?std.Io.Timestamp = null,
        tick_callback_id: c_uint = 0,
        last_render_time: ?std.Io.Timestamp = null,
        pub var offset: c_int = 0;
    };
    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }
    fn dispose(self: *Self) callconv(.c) void {
        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );
        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }
    pub fn queueRender(self: *ImguiWidget) void {
        const priv = self.private();
        priv.gl_area.queueRender();
    }
    pub fn setup(self: *Self) callconv(.c) void {
        const class = self.getClass() orelse return;
        virtual_methods.setup.call(class, self, .{});
    }
    pub fn render(self: *Self) callconv(.c) void {
        const class = self.getClass() orelse return;
        virtual_methods.render.call(class, self, .{});
    }
    fn setCurrentContext(self: *Self) error{ContextNotInitialized}!void {
        const priv = self.private();
        const ig_context = priv.ig_context orelse {
            log.warn("Dear ImGui context not initialized", .{});
            return error.ContextNotInitialized;
        };
        cimgui.c.ImGui_SetCurrentContext(ig_context);
    }
    fn newFrame(self: *Self) void {
        const priv = self.private();
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        const now: std.Io.Timestamp = .now(global.io(), .awake);
        io.DeltaTime = if (priv.instant) |prev| delta: {
            const since_ns: f64 = @floatFromInt(prev.durationTo(now).nanoseconds);
            const ns_per_s: f64 = @floatFromInt(std.time.ns_per_s);
            const since_s: f32 = @floatCast(since_ns / ns_per_s);
            break :delta @max(0.00001, since_s);
        } else (1.0 / 60.0);
        priv.instant = now;
    }
    fn keyEvent(
        self: *ImguiWidget,
        action: input.Action,
        ec_key: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        gtk_mods: gdk.ModifierType,
    ) bool {
        self.queueRender();
        self.setCurrentContext() catch return false;
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        const mods = key.translateMods(gtk_mods);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftShift, mods.shift);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftCtrl, mods.ctrl);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftAlt, mods.alt);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftSuper, mods.super);
        if (key.keyFromKeyval(keyval)) |inputkey| {
            if (inputkey.imguiKey()) |imgui_key| {
                cimgui.c.ImGuiIO_AddKeyEvent(io, imgui_key, action == .press);
            }
        }
        if (ec_key.as(gtk.EventController).getCurrentEvent()) |event| {
            const priv = self.private();
            _ = priv.im_context.as(gtk.IMContext).filterKeypress(event);
        }
        return true;
    }
    fn translateMouseButton(button: c_uint) ?c_int {
        return switch (button) {
            1 => cimgui.c.ImGuiMouseButton_Left,
            2 => cimgui.c.ImGuiMouseButton_Middle,
            3 => cimgui.c.ImGuiMouseButton_Right,
            else => null,
        };
    }
    fn getScaleFactor(self: *Self) f64 {
        const priv = self.private();
        return @floatFromInt(priv.gl_area.as(gtk.Widget).getScaleFactor());
    }
    fn glAreaRealize(_: *gtk.GLArea, self: *Self) callconv(.c) void {
        const priv = self.private();
        assert(priv.ig_context == null);
        priv.gl_area.makeCurrent();
        if (priv.gl_area.getError()) |err| {
            log.warn("GLArea for Dear ImGui widget failed to realize: {s}", .{err.f_message orelse "(unknown)"});
            return;
        }
        priv.ig_context = cimgui.c.ImGui_CreateContext(null) orelse {
            log.warn("unable to initialize Dear ImGui context", .{});
            return;
        };
        self.setCurrentContext() catch return;
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        io.BackendPlatformName = "wasp_gtk";
        const context = priv.gl_area.getContext().?;
        const glsl_version: ?[*:0]const u8 = if (context.getUseEs() != 0)
            "#version 300 es"
        else
            null;
        if (!cimgui.ImGui_ImplOpenGL3_Init(glsl_version)) {
            log.warn("unable to initialize Dear ImGui OpenGL backend", .{});
            cimgui.c.ImGui_DestroyContext(priv.ig_context);
            priv.ig_context = null;
            return;
        }
        self.setup();
        priv.tick_callback_id = self.as(gtk.Widget).addTickCallback(
            tickCallback,
            null,
            null,
        );
    }
    fn glAreaUnrealize(_: *gtk.GLArea, self: *ImguiWidget) callconv(.c) void {
        const priv = self.private();
        assert(priv.ig_context != null);
        if (priv.tick_callback_id != 0) {
            self.as(gtk.Widget).removeTickCallback(priv.tick_callback_id);
            priv.tick_callback_id = 0;
        }
        priv.gl_area.makeCurrent();
        if (priv.gl_area.getError()) |err| {
            log.warn("GLArea for Dear ImGui widget failed to realize: {s}", .{err.f_message orelse "(unknown)"});
            return;
        }
        self.setCurrentContext() catch return;
        cimgui.ImGui_ImplOpenGL3_ShutdownWithLoaderCleanup();
        cimgui.c.ImGui_DestroyContext(priv.ig_context);
        priv.ig_context = null;
    }
    fn glAreaResize(area: *gtk.GLArea, width: c_int, height: c_int, self: *Self) callconv(.c) void {
        self.setCurrentContext() catch return;
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        const scale_factor = area.as(gtk.Widget).getScaleFactor();
        io.DisplaySize = .{ .x = @floatFromInt(width), .y = @floatFromInt(height) };
        io.DisplayFramebufferScale = .{ .x = 1, .y = 1 };
        var style: cimgui.c.ImGuiStyle = undefined;
        cimgui.ext.ImGuiStyle_ImGuiStyle(&style);
        cimgui.c.ImGuiStyle_ScaleAllSizes(&style, @floatFromInt(scale_factor));
        const active_style = cimgui.c.ImGui_GetStyle();
        active_style.* = style;
    }
    fn glAreaRender(_: *gtk.GLArea, _: *gdk.GLContext, self: *Self) callconv(.c) c_int {
        self.setCurrentContext() catch return @intFromBool(false);
        const priv = self.private();
        priv.last_render_time = .now(global.io(), .awake);
        for (0..2) |_| {
            cimgui.ImGui_ImplOpenGL3_NewFrame();
            self.newFrame();
            cimgui.c.ImGui_NewFrame();
            self.render();
            cimgui.c.ImGui_Render();
        }
        cimgui.ImGui_ImplOpenGL3_RenderDrawData(cimgui.c.ImGui_GetDrawData());
        return @intFromBool(true);
    }
    fn ecFocusEnter(_: *gtk.EventControllerFocus, self: *Self) callconv(.c) void {
        self.setCurrentContext() catch return;
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddFocusEvent(io, true);
        self.queueRender();
    }
    fn ecFocusLeave(_: *gtk.EventControllerFocus, self: *Self) callconv(.c) void {
        self.setCurrentContext() catch return;
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddFocusEvent(io, false);
        self.queueRender();
    }
    fn ecKeyPressed(
        ec_key: *gtk.EventControllerKey,
        keyval: c_uint,
        keycode: c_uint,
        gtk_mods: gdk.ModifierType,
        self: *ImguiWidget,
    ) callconv(.c) c_int {
        return @intFromBool(self.keyEvent(
            .press,
            ec_key,
            keyval,
            keycode,
            gtk_mods,
        ));
    }
    fn ecKeyReleased(
        ec_key: *gtk.EventControllerKey,
        keyval: c_uint,
        keycode: c_uint,
        gtk_mods: gdk.ModifierType,
        self: *ImguiWidget,
    ) callconv(.c) void {
        _ = self.keyEvent(
            .release,
            ec_key,
            keyval,
            keycode,
            gtk_mods,
        );
    }
    fn ecMousePressed(
        gesture: *gtk.GestureClick,
        _: c_int,
        _: f64,
        _: f64,
        self: *ImguiWidget,
    ) callconv(.c) void {
        self.queueRender();
        self.setCurrentContext() catch return;
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        const gdk_button = gesture.as(gtk.GestureSingle).getCurrentButton();
        if (translateMouseButton(gdk_button)) |button| {
            cimgui.c.ImGuiIO_AddMouseButtonEvent(io, button, true);
        }
    }
    fn ecMouseReleased(
        gesture: *gtk.GestureClick,
        _: c_int,
        _: f64,
        _: f64,
        self: *ImguiWidget,
    ) callconv(.c) void {
        self.queueRender();
        self.setCurrentContext() catch return;
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        const gdk_button = gesture.as(gtk.GestureSingle).getCurrentButton();
        if (translateMouseButton(gdk_button)) |button| {
            cimgui.c.ImGuiIO_AddMouseButtonEvent(io, button, false);
        }
    }
    fn ecMouseMotion(
        _: *gtk.EventControllerMotion,
        x: f64,
        y: f64,
        self: *ImguiWidget,
    ) callconv(.c) void {
        self.queueRender();
        self.setCurrentContext() catch return;
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        const scale_factor = self.getScaleFactor();
        cimgui.c.ImGuiIO_AddMousePosEvent(
            io,
            @floatCast(x * scale_factor),
            @floatCast(y * scale_factor),
        );
    }
    fn ecMouseScroll(
        _: *gtk.EventControllerScroll,
        x: f64,
        y: f64,
        self: *ImguiWidget,
    ) callconv(.c) c_int {
        self.queueRender();
        self.setCurrentContext() catch return @intFromBool(false);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddMouseWheelEvent(
            io,
            @floatCast(x),
            @floatCast(-y),
        );
        return @intFromBool(true);
    }
    fn imCommit(
        _: *gtk.IMMulticontext,
        bytes: [*:0]u8,
        self: *ImguiWidget,
    ) callconv(.c) void {
        self.queueRender();
        self.setCurrentContext() catch return;
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddInputCharactersUTF8(io, bytes);
    }
    fn tickCallback(
        widget: *gtk.Widget,
        _: *gdk.FrameClock,
        _: ?*anyopaque,
    ) callconv(.c) c_int {
        const self: *Self = gobject.ext.cast(Self, widget) orelse return 0;
        const priv = self.private();
        const frame_time_ns: u64 = std.time.ns_per_s / 30;
        const should_render = if (priv.last_render_time) |last|
            last.untilNow(global.io(), .awake).nanoseconds >= frame_time_ns
        else
            true;
        if (should_render) self.queueRender();
        return 1;
    }
    fn defaultSetup(_: *Self) callconv(.c) void {
        log.warn("default Dear ImGui setup called, this is a bug.", .{});
    }
    fn defaultRender(_: *Self) callconv(.c) void {
        log.warn("default Dear ImGui render called, this is a bug.", .{});
    }
    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const refSink = C.refSink;
    pub const unref = C.unref;
    pub const getClass = C.getClass;
    const private = C.private;
    pub const Class = extern struct {
        parent_class: Parent.Class,
        setup: ?*const fn (*Self) callconv(.c) void,
        render: ?*const fn (*Self) callconv(.c) void,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;
        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 0,
                    .name = "imgui-widget",
                }),
            );
            class.setup = defaultSetup;
            class.render = defaultRender;
            class.bindTemplateChildPrivate("gl_area", .{});
            class.bindTemplateChildPrivate("im_context", .{});
            class.bindTemplateCallback("realize", &glAreaRealize);
            class.bindTemplateCallback("unrealize", &glAreaUnrealize);
            class.bindTemplateCallback("resize", &glAreaResize);
            class.bindTemplateCallback("render", &glAreaRender);
            class.bindTemplateCallback("focus_enter", &ecFocusEnter);
            class.bindTemplateCallback("focus_leave", &ecFocusLeave);
            class.bindTemplateCallback("key_pressed", &ecKeyPressed);
            class.bindTemplateCallback("key_released", &ecKeyReleased);
            class.bindTemplateCallback("mouse_pressed", &ecMousePressed);
            class.bindTemplateCallback("mouse_released", &ecMouseReleased);
            class.bindTemplateCallback("mouse_motion", &ecMouseMotion);
            class.bindTemplateCallback("scroll", &ecMouseScroll);
            class.bindTemplateCallback("im_commit", &imCommit);
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }
        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
