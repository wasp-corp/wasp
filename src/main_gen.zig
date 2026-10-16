const synthetic = @import("synthetic/root.zig");
comptime {
    _ = @import("quirks_memset.zig");
}
pub const main = synthetic.cli.main;
