const Inspector = @This();
const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const cimgui = @import("dcimgui");
const Surface = @import("../Surface.zig");
const font = @import("../font/root.zig");
const terminal = @import("../terminal/main.zig");
const inspector = @import("main.zig");
const widgets = @import("widgets.zig");
mouse: widgets.surface.Mouse = .{},
gui: widgets.surface.Inspector,
pub fn setup() void {
    const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
    io.ConfigFlags |= cimgui.c.ImGuiConfigFlags_DockingEnable;
    io.ConfigFlags |= cimgui.c.ImGuiConfigFlags_IsSRGB;
    io.IniFilename = null;
    io.LogFilename = null;
    {
        const font_size = 16 * 2;
        var font_config: cimgui.c.ImFontConfig = undefined;
        cimgui.ext.ImFontConfig_ImFontConfig(&font_config);
        font_config.FontDataOwnedByAtlas = false;
        _ = cimgui.c.ImFontAtlas_AddFontFromMemoryTTF(
            io.Fonts,
            @ptrCast(@constCast(font.embedded.regular.ptr)),
            @intCast(font.embedded.regular.len),
            font_size,
            &font_config,
            null,
        );
    }
}
pub fn init(alloc: Allocator) !Inspector {
    var gui: widgets.surface.Inspector = try .init(alloc);
    errdefer gui.deinit(alloc);
    return .{ .gui = gui };
}
pub fn deinit(self: *Inspector, alloc: Allocator) void {
    self.gui.deinit(alloc);
}
pub fn rendererInfo(self: *Inspector) *widgets.renderer.Info {
    return &self.gui.renderer_info;
}
pub fn recordKeyEvent(
    self: *Inspector,
    alloc: Allocator,
    ev: inspector.KeyEvent,
) Allocator.Error!void {
    const max_capacity = 50;
    const events: *widgets.key.EventRing = &self.gui.key_stream.events;
    events.append(ev) catch |err| switch (err) {
        error.OutOfMemory => if (events.capacity() < max_capacity) {
            const new_capacity = @min(events.capacity() * 2, max_capacity);
            try events.resize(alloc, new_capacity);
            try events.append(ev);
        } else {
            var it = events.iterator(.forward);
            if (it.next()) |old_ev| old_ev.deinit(alloc);
            events.deleteOldest(1);
            try events.append(ev);
        },
    };
}
pub fn recordPtyRead(
    self: *Inspector,
    alloc: Allocator,
    t: *terminal.Terminal,
    data: []const u8,
) !void {
    try self.gui.vt_stream.recordPtyRead(
        alloc,
        t,
        data,
    );
}
pub fn render(
    self: *Inspector,
    surface: *Surface,
) void {
    self.gui.draw(
        surface,
        self.mouse,
    );
    surface.renderer_thread.wakeup.notify() catch {};
}
