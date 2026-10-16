const DeferredFace = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const fontconfig = @import("fontconfig");
const macos = @import("macos");
const font = @import("main.zig");
const options = @import("main.zig").options;
const Library = @import("main.zig").Library;
const Face = @import("main.zig").Face;
const Presentation = @import("main.zig").Presentation;
const log = std.log.scoped(.deferred_face);
fc: if (options.backend == .fontconfig_freetype) ?Fontconfig else void =
    if (options.backend == .fontconfig_freetype) null else {},
ct: if (font.Discover == font.discovery.CoreText) ?CoreText else void =
    if (font.Discover == font.discovery.CoreText) null else {},
win: if (options.backend == .freetype_windows) ?Windows else void =
    if (options.backend == .freetype_windows) null else {},
wc: if (options.backend == .web_canvas) ?WebCanvas else void =
    if (options.backend == .web_canvas) null else {},
pub const Fontconfig = struct {
    pattern: *fontconfig.Pattern,
    charset: *const fontconfig.CharSet,
    langset: *const fontconfig.LangSet,
    variations: []const font.face.Variation,
    pub fn deinit(self: *Fontconfig) void {
        self.pattern.destroy();
        self.* = undefined;
    }
};
pub const Windows = struct {
    path: [:0]const u8,
    face_index: i32,
    variations: []const font.face.Variation,
    peek: Face,
    presentation: Presentation,
    alloc: Allocator,
    pub fn deinit(self: *Windows) void {
        self.peek.deinit();
        self.alloc.free(self.path);
        self.* = undefined;
    }
};
pub const CoreText = struct {
    font: *macos.text.Font,
    variations: []const font.face.Variation,
    pub fn deinit(self: *CoreText) void {
        self.font.release();
        self.* = undefined;
    }
};
pub const WebCanvas = struct {
    alloc: Allocator,
    font_str: [:0]const u8,
    presentation: Presentation,
    pub fn deinit(self: *WebCanvas) void {
        self.alloc.free(self.font_str);
        self.* = undefined;
    }
};
pub fn deinit(self: *DeferredFace) void {
    switch (options.backend) {
        .fontconfig_freetype => if (self.fc) |*fc| fc.deinit(),
        .freetype => {},
        .freetype_windows => if (self.win) |*w| w.deinit(),
        .web_canvas => if (self.wc) |*wc| wc.deinit(),
        .coretext,
        .coretext_freetype,
        .coretext_harfbuzz,
        .coretext_noshape,
        => if (self.ct) |*ct| ct.deinit(),
    }
    self.* = undefined;
}
pub fn familyName(self: DeferredFace, buf: []u8) ![]const u8 {
    switch (options.backend) {
        .freetype => {},
        .freetype_windows => if (self.win) |w| return try w.peek.name(buf),
        .fontconfig_freetype => if (self.fc) |fc|
            return (try fc.pattern.get(.family, 0)).string,
        .coretext,
        .coretext_freetype,
        .coretext_harfbuzz,
        .coretext_noshape,
        => if (self.ct) |ct| {
            const family_name = ct.font.copyAttribute(.family_name) orelse
                return "unknown";
            return family_name.cstringPtr(.utf8) orelse unsupported: {
                break :unsupported family_name.cstring(buf, .utf8) orelse
                    return error.OutOfMemory;
            };
        },
        .web_canvas => if (self.wc) |wc| return wc.font_str,
    }
    return "";
}
pub fn name(self: DeferredFace, buf: []u8) ![]const u8 {
    switch (options.backend) {
        .freetype => {},
        .freetype_windows => if (self.win) |w| return try w.peek.name(buf),
        .fontconfig_freetype => if (self.fc) |fc|
            return (try fc.pattern.get(.fullname, 0)).string,
        .coretext,
        .coretext_freetype,
        .coretext_harfbuzz,
        .coretext_noshape,
        => if (self.ct) |ct| {
            const display_name = ct.font.copyDisplayName() orelse
                return self.familyName(buf);
            return display_name.cstringPtr(.utf8) orelse unsupported: {
                break :unsupported display_name.cstring(buf, .utf8) orelse
                    return error.OutOfMemory;
            };
        },
        .web_canvas => if (self.wc) |wc| return wc.font_str,
    }
    return "";
}
pub fn load(
    self: *DeferredFace,
    lib: Library,
    opts: font.face.Options,
) !Face {
    return switch (options.backend) {
        .fontconfig_freetype => try self.loadFontconfig(lib, opts),
        .freetype_windows => try self.loadWindows(lib, opts),
        .coretext, .coretext_harfbuzz, .coretext_noshape => try self.loadCoreText(lib, opts),
        .coretext_freetype => try self.loadCoreTextFreetype(lib, opts),
        .web_canvas => try self.loadWebCanvas(opts),
        .freetype => unreachable,
    };
}
fn loadFontconfig(
    self: *DeferredFace,
    lib: Library,
    opts: font.face.Options,
) !Face {
    const fc = self.fc.?;
    const filename = (try fc.pattern.get(.file, 0)).string;
    const face_index = (try fc.pattern.get(.index, 0)).integer;
    var face = try Face.initFile(lib, filename, face_index, opts);
    errdefer face.deinit();
    try face.setVariations(fc.variations, opts);
    return face;
}
fn loadWindows(
    self: *DeferredFace,
    lib: Library,
    opts: font.face.Options,
) !Face {
    const w = self.win.?;
    var face = try Face.initFile(lib, w.path, w.face_index, opts);
    errdefer face.deinit();
    try face.setVariations(w.variations, opts);
    return face;
}
fn loadCoreText(
    self: *DeferredFace,
    lib: Library,
    opts: font.face.Options,
) !Face {
    _ = lib;
    const ct = self.ct.?;
    var face = try Face.initFontCopy(ct.font, opts);
    errdefer face.deinit();
    try face.setVariations(ct.variations, opts);
    return face;
}
fn loadCoreTextFreetype(
    self: *DeferredFace,
    lib: Library,
    opts: font.face.Options,
) !Face {
    const ct = self.ct.?;
    const url = ct.font.copyAttribute(.url) orelse
        return error.FontHasNoFile;
    defer url.release();
    const path = url.copyPath() orelse return error.FontHasNoFile;
    defer path.release();
    const blank = try macos.foundation.String.createWithBytes("", .utf8, false);
    defer blank.release();
    const decoded = try macos.foundation.URL.createStringByReplacingPercentEscapes(
        path,
        blank,
    );
    defer decoded.release();
    var buf: [1024]u8 = undefined;
    const path_slice = decoded.cstring(buf[0..1023], .utf8) orelse
        return error.FontPathCantDecode;
    buf[path_slice.len] = 0;
    var face = try Face.initFile(lib, buf[0..path_slice.len :0], 0, opts);
    errdefer face.deinit();
    try face.setVariations(ct.variations, opts);
    return face;
}
fn loadWebCanvas(
    self: *DeferredFace,
    opts: font.face.Options,
) !Face {
    const wc = self.wc.?;
    return try .initNamed(wc.alloc, wc.font_str, opts, wc.presentation);
}
pub fn hasCodepoint(self: DeferredFace, cp: u32, p: ?Presentation) bool {
    switch (options.backend) {
        .fontconfig_freetype => {
            if (self.fc) |fc| {
                if (!fc.charset.hasChar(cp)) return false;
                if (p) |desired| {
                    const emoji_lang = "und-zsye";
                    const actual: Presentation = if (fc.langset.hasLang(emoji_lang))
                        .emoji
                    else
                        .text;
                    return desired == actual;
                }
                return true;
            }
        },
        .freetype_windows => {
            if (self.win) |w| {
                if (p) |desired| if (w.presentation != desired) return false;
                return w.peek.glyphIndex(cp) != null;
            }
        },
        .coretext,
        .coretext_freetype,
        .coretext_harfbuzz,
        .coretext_noshape,
        => {
            if (self.ct) |ct| {
                if (p) |desired_p| {
                    const traits = ct.font.getSymbolicTraits();
                    const actual_p: Presentation = if (traits.color_glyphs) .emoji else .text;
                    if (actual_p != desired_p) return false;
                }
                var unichars: [2]u16 = undefined;
                const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(cp, &unichars);
                const len: usize = if (pair) 2 else 1;
                var glyphs = [2]macos.graphics.Glyph{ 0, 0 };
                return ct.font.getGlyphsForCharacters(unichars[0..len], glyphs[0..len]);
            }
        },
        .web_canvas => if (self.wc) |wc| {
            if (p) |desired| if (wc.presentation != desired) return false;
            var face = Face.initNamed(
                wc.alloc,
                wc.font_str,
                .{ .points = 12 },
                wc.presentation,
            ) catch |err| {
                log.warn("failed to init face for codepoint check " ++
                    "face={s} err={}", .{
                    wc.font_str,
                    err,
                });
                return false;
            };
            defer face.deinit();
            return face.glyphIndex(cp) != null;
        },
        .freetype => {},
    }
    unreachable;
}
pub const Wasm = struct {
    const wasm = @import("../os/wasm.zig");
    const alloc = wasm.alloc;
    export fn deferred_face_new(ptr: [*]const u8, len: usize, presentation: u16) ?*DeferredFace {
        return deferred_face_new_(ptr, len, presentation) catch |err| {
            log.warn("error creating deferred face err={}", .{err});
            return null;
        };
    }
    fn deferred_face_new_(ptr: [*]const u8, len: usize, presentation: u16) !*DeferredFace {
        const font_str = try alloc.dupeZ(u8, ptr[0..len]);
        errdefer alloc.free(font_str);
        var face: DeferredFace = .{
            .wc = .{
                .alloc = alloc,
                .font_str = font_str,
                .presentation = @enumFromInt(presentation),
            },
        };
        errdefer face.deinit();
        const result = try alloc.create(DeferredFace);
        errdefer alloc.destroy(result);
        result.* = face;
        return result;
    }
    export fn deferred_face_free(ptr: ?*DeferredFace) void {
        if (ptr) |v| {
            v.deinit();
            alloc.destroy(v);
        }
    }
    export fn deferred_face_load(self: *DeferredFace, pts: f32) void {
        self.load(.{}, .{ .points = pts }) catch |err| {
            log.warn("error loading deferred face err={}", .{err});
            return;
        };
    }
};
test "fontconfig" {
    if (options.backend != .fontconfig_freetype) return error.SkipZigTest;
    const discovery = @import("main.zig").discovery;
    const testing = std.testing;
    const alloc = testing.allocator;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var def = def: {
        var fc = discovery.Fontconfig.init(lib);
        defer fc.deinit();
        var it = try fc.discover(alloc, .{ .family = "monospace", .size = 12 });
        defer it.deinit();
        break :def (try it.next()).?;
    };
    defer def.deinit();
    var buf: [1024]u8 = undefined;
    const n = try def.name(&buf);
    try testing.expect(n.len > 0);
    var face = try def.load(lib, .{ .size = .{ .points = 12 } });
    defer face.deinit();
    try testing.expect(face.glyphIndex(' ') != null);
}
test "coretext" {
    if (options.backend != .coretext) return error.SkipZigTest;
    const discovery = @import("main.zig").discovery;
    const testing = std.testing;
    const alloc = testing.allocator;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var def = def: {
        var fc = discovery.CoreText.init(lib);
        var it = try fc.discover(alloc, .{ .family = "Monaco", .size = 12 });
        defer it.deinit();
        break :def (try it.next()).?;
    };
    defer def.deinit();
    try testing.expect(def.hasCodepoint(' ', null));
    var buf: [1024]u8 = undefined;
    const n = try def.name(&buf);
    try testing.expect(n.len > 0);
    var face = try def.load(lib, .{ .size = .{ .points = 12 } });
    defer face.deinit();
    try testing.expect(face.glyphIndex(' ') != null);
}
