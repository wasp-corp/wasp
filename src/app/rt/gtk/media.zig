const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const log = std.log.scoped(.gtk_media);
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const global = @import("../../global.zig");
pub fn fromFilename(path: [:0]const u8) ?*gtk.MediaFile {
    assert(std.fs.path.isAbsolute(path));
    std.Io.Dir.accessAbsolute(
        global.io(),
        path,
        .{ .read = true },
    ) catch |err| {
        log.warn("unable to access {s}: {t}", .{ path, err });
        return null;
    };
    return gtk.MediaFile.newForFilename(path);
}
pub fn fromResource(path: [:0]const u8) ?*gtk.MediaFile {
    assert(std.fs.path.isAbsolute(path));
    var gerr: ?*glib.Error = null;
    const found = gio.resourcesGetInfo(path, .{}, null, null, &gerr);
    if (gerr) |err| {
        defer err.free();
        log.warn(
            "failed to find resource {s}: {s} {d} {s}",
            .{
                path,
                glib.quarkToString(err.f_domain),
                err.f_code,
                err.f_message orelse "(no message)",
            },
        );
        return null;
    }
    if (found == 0) {
        log.warn("failed to find resource {s}", .{path});
        return null;
    }
    return gtk.MediaFile.newForResource(path);
}
pub fn bellMediaFile(
    current: ?*gtk.MediaFile,
    path: [:0]const u8,
    required: bool,
) ?*gtk.MediaFile {
    if (current) |media_file| {
        if (isForPath(media_file, path)) return media_file;
        media_file.unref();
    }
    const media_file = fromFilename(path) orelse return null;
    if (required) {
        _ = gobject.Object.signals.notify.connect(
            media_file,
            ?*anyopaque,
            mediaFileError,
            null,
            .{ .detail = "error" },
        );
    }
    return media_file;
}
pub fn playBell(media_file: *gtk.MediaFile, volume: f64) void {
    const media_stream = media_file.as(gtk.MediaStream);
    media_stream.setVolume(volume);
    media_stream.seek(0);
    media_stream.play();
}
fn isForPath(media_file: *gtk.MediaFile, path: [:0]const u8) bool {
    const file = media_file.getFile() orelse return false;
    const cur = file.getPath() orelse return false;
    defer glib.free(cur);
    return std.mem.eql(u8, std.mem.span(cur), path);
}
fn mediaFileError(
    media_file: *gtk.MediaFile,
    _: *gobject.ParamSpec,
    _: ?*anyopaque,
) callconv(.c) void {
    const path = path: {
        const file = media_file.getFile() orelse break :path null;
        break :path file.getPath();
    };
    defer if (path) |p| glib.free(p);
    const media_stream = media_file.as(gtk.MediaStream);
    const err = media_stream.getError() orelse return;
    log.warn("error playing sound from {s}: {s} {d} {s}", .{
        path orelse "<<unknown>>",
        glib.quarkToString(err.f_domain),
        err.f_code,
        err.f_message orelse "",
    });
}
test "bellMediaFile reuses one MediaFile per path" {
    const testing = std.testing;
    const path_a: [:0]const u8 = "/tmp/wasp-bell-test-a.oga";
    const path_b: [:0]const u8 = "/tmp/wasp-bell-test-b.oga";
    var current = bellMediaFile(null, path_a, false) orelse return error.SkipZigTest;
    const first = current;
    try testing.expect(isForPath(current, path_a));
    current = bellMediaFile(current, path_a, false).?;
    try testing.expectEqual(first, current);
    current = bellMediaFile(current, path_b, false) orelse return error.SkipZigTest;
    try testing.expect(isForPath(current, path_b));
    try testing.expect(!isForPath(current, path_a));
    current.unref();
}
