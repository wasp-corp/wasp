const std = @import("std");
pub const Targets = packed struct {
    x11: bool = false,
    wayland: bool = false,
};
pub fn targets(b: *std.Build) Targets {
    var code: u8 = undefined;
    const output = b.runAllowFail(
        &.{ "pkg-config", "--variable=targets", "gtk4" },
        &code,
        .ignore,
    ) catch return .{};
    const x11 = std.mem.indexOf(u8, output, "x11") != null;
    const wayland = std.mem.indexOf(u8, output, "wayland") != null;
    return .{
        .x11 = x11,
        .wayland = wayland,
    };
}
