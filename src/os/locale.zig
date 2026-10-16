const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const macos = @import("macos");
const objc = @import("objc");
const internal_os = @import("main.zig");
const i18n = internal_os.i18n;
const log = std.log.scoped(.os_locale);
pub fn ensureLocale() !void {
    assert(!builtin.is_test);
    if (comptime builtin.target.os.tag.isDarwin()) {
        const lang = std.posix.system.getenv("LANG");
        if (lang == null or lang.?[0] == 0) {
            setLangFromCocoa();
        }
    }
    if (setlocale(LC_ALL, "")) |v| {
        log.info("setlocale from env result={s}", .{v});
        return;
    }
    if (builtin.os.tag == .windows) {
        log.info("TODO: setlocale failed on Windows, implement better fallbacks", .{});
        return;
    }
    if (std.posix.system.getenv("LANG")) |lang| {
        if (lang[0] != 0) {
            _ = setenv("LANG", "", 1);
            _ = unsetenv("LANG");
            if (setlocale(LC_ALL, "")) |v| {
                log.info("setlocale after unset lang result={s}", .{v});
                if (!std.mem.eql(u8, std.mem.sliceTo(v, 0), "C")) return;
            }
        }
    }
    log.warn("setlocale failed with LANG and system default. Falling back to en_US.UTF-8", .{});
    if (setlocale(LC_ALL, "en_US.UTF-8")) |v| {
        _ = setenv("LANG", "en_US.UTF-8", 1);
        log.info("setlocale default result={s}", .{v});
        return;
    } else log.warn("setlocale failed even with the fallback, uncertain results", .{});
}
fn setLangFromCocoa() void {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const NSLocale = objc.getClass("NSLocale") orelse {
        log.warn("NSLocale class not found. Locale may be incorrect.", .{});
        return;
    };
    const locale = NSLocale.msgSend(objc.Object, objc.sel("currentLocale"), .{});
    const lang = locale.getProperty(objc.Object, "languageCode");
    const country = locale.getProperty(objc.Object, "countryCode");
    if (lang.value == null or country.value == null) {
        log.warn("languageCode or countryCode not found. Locale may be incorrect.", .{});
        return;
    }
    const c_lang = lang.getProperty([*:0]const u8, "UTF8String");
    const c_country = country.getProperty([*:0]const u8, "UTF8String");
    const z_lang = std.mem.sliceTo(c_lang, 0);
    const z_country = std.mem.sliceTo(c_country, 0);
    {
        var buf: [128]u8 = undefined;
        const env_value = std.fmt.bufPrintZ(&buf, "{s}_{s}.UTF-8", .{ z_lang, z_country }) catch |err| {
            log.warn("error setting locale from system. err={}", .{err});
            return;
        };
        log.info("detected system locale={s}", .{env_value});
        if (setenv("LANG", @ptrCast(env_value), 1) < 0) {
            log.warn("error setting locale env var", .{});
            return;
        }
    }
    language: {
        var buf: [1024]u8 = undefined;
        const pref_ = preferredLanguageFromCocoa(
            &buf,
            NSLocale,
        ) catch |err| {
            log.warn("error getting preferred languages. err={}", .{err});
            break :language;
        };
        const pref = pref_ orelse break :language;
        log.debug(
            "setting LANGUAGE from preferred languages value={s}",
            .{pref},
        );
        _ = setenv("LANGUAGE", @ptrCast(pref), 1);
    }
}
fn preferredLanguageFromCocoa(
    buf: []u8,
    NSLocale: objc.Class,
) error{NoSpaceLeft}!?[:0]const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    const preferred: *macos.foundation.Array = array: {
        const ns = NSLocale.msgSend(
            objc.Object,
            objc.sel("preferredLanguages"),
            .{},
        );
        break :array @ptrCast(ns.value);
    };
    for (0..preferred.getCount()) |i| {
        var str_buf: [255:0]u8 = undefined;
        const str = preferred.getValueAtIndex(macos.foundation.String, i);
        const c_str = str.cstring(&str_buf, .utf8) orelse {
            log.warn("failed to convert a preferred language to UTF-8", .{});
            continue;
        };
        if (writer.end > 0) {
            _ = writer.writeByte(':') catch
                return error.NoSpaceLeft;
        }
        const canon = try i18n.canonicalizeLocale(
            writer.buffer[writer.end..],
            c_str,
        );
        writer.end += canon.len;
        _ = writer.writeAll(".UTF-8") catch return error.NoSpaceLeft;
    }
    if (writer.end == 0) return null;
    _ = writer.writeByte(0) catch return error.NoSpaceLeft;
    const slice = writer.buffered();
    return slice[0 .. slice.len - 1 :0];
}
const c = @import("locale-c");
const LC_ALL: c_int = c.LC_ALL;
const LC_ALL_MASK: c_int = c.LC_ALL_MASK;
const locale_t = c.locale_t;
const setlocale = c.setlocale;
const newlocale = c.newlocale;
const freelocale = c.freelocale;
extern "c" fn setenv(name: ?[*]const u8, value: ?[*]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: ?[*]const u8) c_int;
