const benchmark = @import("benchmark/main.zig");
comptime {
    _ = @import("quirks_memset.zig");
}
pub const main = benchmark.cli.main;
