const std = @import("std");
const gtk_c = @import("gtk_c");
const gtk = @import("gtk");
const log = std.log.scoped(.gtk);
pub const comptime_version: std.SemanticVersion = .{
    .major = gtk_c.GTK_MAJOR_VERSION,
    .minor = gtk_c.GTK_MINOR_VERSION,
    .patch = gtk_c.GTK_MICRO_VERSION,
};
pub const minimum_version: std.SemanticVersion = .{
    .major = 4,
    .minor = 18,
    .patch = 0,
};
comptime {
    if (comptime_version.order(minimum_version) == .lt) @compileError(std.fmt.comptimePrint(
        "The minimum GTK version is {f}!",
        .{minimum_version},
    ));
}
pub fn getRuntimeVersion() std.SemanticVersion {
    return .{
        .major = gtk.getMajorVersion(),
        .minor = gtk.getMinorVersion(),
        .patch = gtk.getMicroVersion(),
    };
}
pub fn logVersion() error{GtkMinimumVersion}!void {
    const runtime_version = getRuntimeVersion();
    log.info("GTK version build={f} runtime={f}", .{
        comptime_version,
        runtime_version,
    });
    if (runtime_version.order(minimum_version) == .lt) return error.GtkMinimumVersion;
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
pub inline fn runtimeUntil(
    comptime major: u16,
    comptime minor: u16,
    comptime micro: u16,
) bool {
    const runtime_version = getRuntimeVersion();
    return runtime_version.order(.{
        .major = major,
        .minor = minor,
        .patch = micro,
    }) == .lt;
}
test "atLeast" {
    const testing = std.testing;
    const funs = &.{ atLeast, runtimeAtLeast };
    inline for (funs) |fun| {
        try testing.expect(fun(gtk_c.GTK_MAJOR_VERSION, gtk_c.GTK_MINOR_VERSION, gtk_c.GTK_MICRO_VERSION));
        try testing.expect(!fun(gtk_c.GTK_MAJOR_VERSION, gtk_c.GTK_MINOR_VERSION, gtk_c.GTK_MICRO_VERSION + 1));
        try testing.expect(!fun(gtk_c.GTK_MAJOR_VERSION, gtk_c.GTK_MINOR_VERSION + 1, gtk_c.GTK_MICRO_VERSION));
        try testing.expect(!fun(gtk_c.GTK_MAJOR_VERSION + 1, gtk_c.GTK_MINOR_VERSION, gtk_c.GTK_MICRO_VERSION));
        try testing.expect(fun(gtk_c.GTK_MAJOR_VERSION - 1, gtk_c.GTK_MINOR_VERSION, gtk_c.GTK_MICRO_VERSION));
        try testing.expect(fun(gtk_c.GTK_MAJOR_VERSION - 1, gtk_c.GTK_MINOR_VERSION + 1, gtk_c.GTK_MICRO_VERSION));
        try testing.expect(fun(gtk_c.GTK_MAJOR_VERSION - 1, gtk_c.GTK_MINOR_VERSION, gtk_c.GTK_MICRO_VERSION + 1));
        try testing.expect(fun(gtk_c.GTK_MAJOR_VERSION, gtk_c.GTK_MINOR_VERSION - 1, gtk_c.GTK_MICRO_VERSION + 1));
    }
}
test "runtimeUntil" {
    const testing = std.testing;
    const funs = &.{runtimeUntil};
    inline for (funs) |fun| {
        try testing.expect(!fun(gtk_c.GTK_MAJOR_VERSION, gtk_c.GTK_MINOR_VERSION, gtk_c.GTK_MICRO_VERSION));
        try testing.expect(fun(gtk_c.GTK_MAJOR_VERSION, gtk_c.GTK_MINOR_VERSION, gtk_c.GTK_MICRO_VERSION + 1));
        try testing.expect(fun(gtk_c.GTK_MAJOR_VERSION, gtk_c.GTK_MINOR_VERSION + 1, gtk_c.GTK_MICRO_VERSION));
        try testing.expect(fun(gtk_c.GTK_MAJOR_VERSION + 1, gtk_c.GTK_MINOR_VERSION, gtk_c.GTK_MICRO_VERSION));
        try testing.expect(!fun(gtk_c.GTK_MAJOR_VERSION - 1, gtk_c.GTK_MINOR_VERSION, gtk_c.GTK_MICRO_VERSION));
        try testing.expect(!fun(gtk_c.GTK_MAJOR_VERSION - 1, gtk_c.GTK_MINOR_VERSION + 1, gtk_c.GTK_MICRO_VERSION));
        try testing.expect(!fun(gtk_c.GTK_MAJOR_VERSION - 1, gtk_c.GTK_MINOR_VERSION, gtk_c.GTK_MICRO_VERSION + 1));
        try testing.expect(!fun(gtk_c.GTK_MAJOR_VERSION, gtk_c.GTK_MINOR_VERSION - 1, gtk_c.GTK_MICRO_VERSION + 1));
    }
}
