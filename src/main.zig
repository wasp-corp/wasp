const std = @import("std");
const build_config = @import("build_config.zig");
const entrypoint = switch (build_config.exe_entrypoint) {
    .wasp => @import("main_wasp.zig"),
    .helpgen => @import("helpgen.zig"),
    .mdgen_wasp_1 => @import("build/mdgen/main_wasp_1.zig"),
    .mdgen_wasp_5 => @import("build/mdgen/main_wasp_5.zig"),
    .webgen_config => @import("build/webgen/main_config.zig"),
    .webgen_actions => @import("build/webgen/main_actions.zig"),
    .webgen_commands => @import("build/webgen/main_commands.zig"),
};
pub const main = entrypoint.main;
pub const std_options: std.Options = if (@hasDecl(entrypoint, "std_options"))
    entrypoint.std_options
else
    .{};
comptime {
    _ = @import("quirks_memset.zig");
}
test {
    std.testing.log_level = std.log.Level.err;
    _ = entrypoint;
    _ = @import("quirks_memset.zig");
}
