const xev = @import("../global.zig").xev;
const apprt = @import("../apprt.zig");
const renderer = @import("../renderer.zig");
const Config = @import("../config.zig").Config;
const termio = @import("../termio.zig");
size: renderer.Size,
full_config: *const Config,
config: termio.Termio.DerivedConfig,
backend: termio.Backend,
mailbox: termio.Mailbox,
renderer_state: *renderer.State,
renderer_wakeup: xev.Async,
renderer_mailbox: *renderer.Thread.Mailbox,
surface_mailbox: apprt.surface.Mailbox,
