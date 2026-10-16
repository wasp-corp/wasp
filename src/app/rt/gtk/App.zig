const App = @This();
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const Application = @import("class/application.zig").Application;
const Surface = @import("Surface.zig");
const ipcNewWindow = @import("ipc/new_window.zig").newWindow;
const ipcNewTab = @import("ipc/new_tab.zig").newTab;
const ipcToggleQuickTerminal = @import("ipc/toggle_quick_terminal.zig").toggleQuickTerminal;
const log = std.log.scoped(.gtk);
pub const application_id = @import("build/info.zig").application_id;
pub const object_path = @import("build/info.zig").object_path;
app: *Application,
pub fn init(
    self: *App,
    core_app: *CoreApp,
    opts: struct {},
) !void {
    _ = opts;
    const app: *Application = try .new(self, core_app);
    errdefer app.unref();
    self.* = .{ .app = app };
    return;
}
pub fn run(self: *App) !void {
    try self.app.run();
}
pub fn terminate(self: *App) void {
    self.app.deinit();
}
pub fn wakeup(self: *App) void {
    self.app.wakeup();
}
pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    return try self.app.performAction(target, action, value);
}
pub fn performIpc(
    alloc: Allocator,
    target: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    value: apprt.ipc.Action.Value(action),
) !bool {
    switch (action) {
        .new_window => return try ipcNewWindow(alloc, target, value),
        .new_tab => return try ipcNewTab(alloc, target, value),
        .toggle_quick_terminal => return try ipcToggleQuickTerminal(alloc, target),
    }
}
pub fn redrawInspector(_: *App, surface: *Surface) void {
    surface.redrawInspector();
}
