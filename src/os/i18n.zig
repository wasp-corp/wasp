const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const locales = @import("i18n_locales.zig");
const log = std.log.scoped(.i18n);
pub const locales_map = map: {
    var kvs: [locales.len]struct { []const u8 } = undefined;
    for (locales, 0..) |locale, i| kvs[i] = .{locale};
    break :map std.StaticStringMap(void).initComptime(kvs);
};
pub const InitError = error{
    InvalidResourcesDir,
    OutOfMemory,
};
pub fn init(resources_dir: []const u8) InitError!void {
    if (comptime !build_config.i18n) return;
    switch (builtin.os.tag) {
        .windows => return,
        else => {
            const share_dir = std.fs.path.dirname(resources_dir) orelse
                return error.InvalidResourcesDir;
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrintZ(&buf, "{s}/locale", .{share_dir}) catch
                return error.OutOfMemory;
            log.debug("binding domain={s} path={s}", .{ build_config.bundle_id, path });
            _ = bindtextdomain(build_config.bundle_id, path.ptr) orelse
                return error.OutOfMemory;
        },
    }
}
pub fn initGlobalDomain() error{OutOfMemory}!void {
    if (comptime !build_config.i18n) return;
    _ = textdomain(build_config.bundle_id) orelse return error.OutOfMemory;
}
pub fn _(msgid: [*:0]const u8) [*:0]const u8 {
    if (comptime !build_config.i18n) return msgid;
    if (@inComptime()) return msgid;
    return dgettext(build_config.bundle_id, msgid);
}
pub fn N_(msgid: [:0]const u8) [:0]const u8 {
    return msgid;
}
pub fn canonicalizeLocale(
    buf: []u8,
    locale: []const u8,
) error{NoSpaceLeft}![:0]const u8 {
    if (comptime !build_config.i18n) {
        if (buf.len < locale.len + 1) return error.NoSpaceLeft;
        @memcpy(buf[0..locale.len], locale);
        buf[locale.len] = 0;
        return buf[0..locale.len :0];
    }
    if (fixZhLocale(locale)) |fixed| {
        if (buf.len < fixed.len + 1) return error.NoSpaceLeft;
        @memcpy(buf[0..fixed.len], fixed);
        buf[fixed.len] = 0;
        return buf[0..fixed.len :0];
    }
    if (buf.len < @max(16, locale.len + 1)) return error.NoSpaceLeft;
    @memcpy(buf[0..locale.len], locale);
    buf[locale.len] = 0;
    _libintl_locale_name_canonicalize(buf[0..locale.len :0]);
    const slice = std.mem.sliceTo(buf, 0);
    return buf[0..slice.len :0];
}
fn fixZhLocale(locale: []const u8) ?[:0]const u8 {
    var it = std.mem.splitScalar(u8, locale, '-');
    const name = it.next() orelse return null;
    if (!std.mem.eql(u8, name, "zh")) return null;
    const script = it.next() orelse return null;
    const region = it.next() orelse return null;
    if (std.mem.eql(u8, script, "Hans")) {
        if (std.mem.eql(u8, region, "SG")) return "zh_SG";
        return "zh_CN";
    }
    if (std.mem.eql(u8, script, "Hant")) {
        if (std.mem.eql(u8, region, "MO")) return "zh_MO";
        if (std.mem.eql(u8, region, "HK")) return "zh_HK";
        return "zh_TW";
    }
    return null;
}
pub fn staticLocale(comptime v: [*:0]const u8) [*:0]const u8 {
    comptime {
        for (locales) |locale| {
            if (std.mem.eql(u8, locale, v)) {
                return locale;
            }
        }
        @compileError("unsupported locale");
    }
}
extern fn bindtextdomain(domainname: [*:0]const u8, dirname: [*:0]const u8) ?[*:0]const u8;
extern fn textdomain(domainname: [*:0]const u8) ?[*:0]const u8;
extern fn dgettext(domainname: [*:0]const u8, msgid: [*:0]const u8) [*:0]const u8;
extern fn _libintl_locale_name_canonicalize(name: [*:0]u8) void;
test "canonicalizeLocale darwin" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("en_US", try canonicalizeLocale(&buf, "en_US"));
    try testing.expectEqualStrings("zh_CN", try canonicalizeLocale(&buf, "zh-Hans"));
    try testing.expectEqualStrings("zh_TW", try canonicalizeLocale(&buf, "zh-Hant"));
    try testing.expectEqualStrings("zh_CN", try canonicalizeLocale(&buf, "zh-Hans-CN"));
    try testing.expectEqualStrings("zh_SG", try canonicalizeLocale(&buf, "zh-Hans-SG"));
    try testing.expectEqualStrings("zh_TW", try canonicalizeLocale(&buf, "zh-Hant-TW"));
    try testing.expectEqualStrings("zh_HK", try canonicalizeLocale(&buf, "zh-Hant-HK"));
    try testing.expectEqualStrings("zh_MO", try canonicalizeLocale(&buf, "zh-Hant-MO"));
    try testing.expectEqualStrings("en_US.UTF_8", try canonicalizeLocale(&buf, "en_US.UTF-8"));
}
test "_ returns msgid at comptime" {
    const testing = std.testing;
    const msgid = comptime @"_"("Wasp");
    try testing.expectEqualStrings("Wasp", std.mem.span(msgid));
}
