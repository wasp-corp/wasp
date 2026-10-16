const std = @import("std");
const adw_c = @import("adw_c");
const adw = @import("adw");
const log = std.log.scoped(.gtk);
pub const comptime_version: std.SemanticVersion = .{
    .major = adw_c.ADW_MAJOR_VERSION,
    .minor = adw_c.ADW_MINOR_VERSION,
    .patch = adw_c.ADW_MICRO_VERSION,
};
pub const minimum_version: std.SemanticVersion = .{
    .major = 1,
    .minor = 7,
    .patch = 0,
};
comptime {
    if (comptime_version.order(minimum_version) == .lt) @compileError(std.fmt.comptimePrint(
        "The minimum version of libadwaita is {f}!",
        .{minimum_version},
    ));
}
pub fn getRuntimeVersion() std.SemanticVersion {
    return .{
        .major = adw.getMajorVersion(),
        .minor = adw.getMinorVersion(),
        .patch = adw.getMicroVersion(),
    };
}
pub fn logVersion() error{AdwaitaMinimumVersion}!void {
    const runtime_version = getRuntimeVersion();
    log.info("libadwaita version build={f} runtime={f}", .{
        comptime_version,
        runtime_version,
    });
    if (runtime_version.order(minimum_version) == .lt) return error.AdwaitaMinimumVersion;
}
pub inline fn atLeast(
    comptime major: u16,
    comptime minor: u16,
    comptime micro: u16,
) bool {
    if (comptime comptime_version.order(.{
        .major = major,
        .minor = minor,
        .patch = micro,
    }) == .lt) return false;
    if (@inComptime()) return true;
    return runtimeAtLeast(major, minor, micro);
}
pub inline fn runtimeAtLeast(
    comptime major: u16,
    comptime minor: u16,
    comptime micro: u16,
) bool {
    const runtime_version = getRuntimeVersion();
    return runtime_version.order(.{
        .major = major,
        .minor = minor,
        .patch = micro,
    }) != .lt;
}
test "versionAtLeast" {
    const testing = std.testing;
    const funs = &.{ atLeast, runtimeAtLeast };
    inline for (funs) |fun| {
        try testing.expect(fun(adw_c.ADW_MAJOR_VERSION, adw_c.ADW_MINOR_VERSION, adw_c.ADW_MICRO_VERSION));
        try testing.expect(!fun(adw_c.ADW_MAJOR_VERSION, adw_c.ADW_MINOR_VERSION, adw_c.ADW_MICRO_VERSION + 1));
        try testing.expect(!fun(adw_c.ADW_MAJOR_VERSION, adw_c.ADW_MINOR_VERSION + 1, adw_c.ADW_MICRO_VERSION));
        try testing.expect(!fun(adw_c.ADW_MAJOR_VERSION + 1, adw_c.ADW_MINOR_VERSION, adw_c.ADW_MICRO_VERSION));
        try testing.expect(fun(adw_c.ADW_MAJOR_VERSION - 1, adw_c.ADW_MINOR_VERSION, adw_c.ADW_MICRO_VERSION));
        try testing.expect(fun(adw_c.ADW_MAJOR_VERSION - 1, adw_c.ADW_MINOR_VERSION + 1, adw_c.ADW_MICRO_VERSION));
        try testing.expect(fun(adw_c.ADW_MAJOR_VERSION - 1, adw_c.ADW_MINOR_VERSION, adw_c.ADW_MICRO_VERSION + 1));
        try testing.expect(fun(adw_c.ADW_MAJOR_VERSION, adw_c.ADW_MINOR_VERSION - 1, adw_c.ADW_MICRO_VERSION + 1));
    }
}
