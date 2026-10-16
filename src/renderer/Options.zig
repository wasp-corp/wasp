const apprt = @import("../apprt.zig");
const font = @import("../font/root.zig");
const renderer = @import("../renderer.zig");
device: *renderer.Device,
config: renderer.Renderer.DerivedConfig,
font_grid: *font.SharedGrid,
size: renderer.Size,
surface_mailbox: apprt.surface.Mailbox,
rt_surface: *apprt.Surface,
thread: *renderer.Thread,
