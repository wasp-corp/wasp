const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const fontconfig = @import("fontconfig");
const macos = @import("macos");
const opentype = @import("opentype.zig");
const options = @import("main.zig").options;
const Collection = @import("main.zig").Collection;
const DeferredFace = @import("main.zig").DeferredFace;
const Face = @import("main.zig").Face;
const Library = @import("main.zig").Library;
const Presentation = @import("main.zig").Presentation;
const Variation = @import("main.zig").face.Variation;
const global = @import("../global.zig");
const log = std.log.scoped(.discovery);
pub const Discover = switch (options.backend) {
    .freetype => void, 
    .freetype_windows => Windows,
    .fontconfig_freetype => Fontconfig,
    .web_canvas => void, 
    .coretext,
    .coretext_freetype,
    .coretext_harfbuzz,
    .coretext_noshape,
    => CoreText,
};
pub const Descriptor = struct {
    family: ?[:0]const u8 = null,
    style: ?[:0]const u8 = null,
    codepoint: u32 = 0,
    size: f32 = 0,
    bold: bool = false,
    italic: bool = false,
    monospace: bool = false,
    variations: []const Variation = &.{},
    pub fn hash(self: Descriptor, hasher: anytype) void {
        const autoHash = std.hash.autoHash;
        const autoHashStrat = std.hash.autoHashStrat;
        autoHashStrat(hasher, self.family, .Deep);
        autoHashStrat(hasher, self.style, .Deep);
        autoHash(hasher, self.codepoint);
        autoHash(hasher, @as(u32, @bitCast(self.size)));
        autoHash(hasher, self.bold);
        autoHash(hasher, self.italic);
        autoHash(hasher, self.monospace);
        autoHash(hasher, self.variations.len);
        for (self.variations) |variation| {
            autoHash(hasher, variation.id);
            autoHash(hasher, @as(i64, @intFromFloat(variation.value)));
        }
    }
    pub fn hashcode(self: Descriptor) u64 {
        var hasher = std.hash.Wyhash.init(0);
        self.hash(&hasher);
        return hasher.final();
    }
    pub fn clone(self: *const Descriptor, alloc: Allocator) !Descriptor {
        var copy = self.*;
        copy.family = if (self.family) |src| try alloc.dupeZ(u8, src) else null;
        copy.style = if (self.style) |src| try alloc.dupeZ(u8, src) else null;
        copy.variations = try alloc.dupe(Variation, self.variations);
        return copy;
    }
    pub fn toFcPattern(self: Descriptor) *fontconfig.Pattern {
        const pat = fontconfig.Pattern.create();
        if (self.family) |family| {
            assert(pat.add(.family, .{ .string = family }, false));
        }
        if (self.style) |style| {
            assert(pat.add(.style, .{ .string = style }, false));
        }
        if (self.codepoint > 0) {
            const cs = fontconfig.CharSet.create();
            defer cs.destroy();
            assert(cs.addChar(self.codepoint));
            assert(pat.add(.charset, .{ .char_set = cs }, false));
        }
        if (self.size > 0) assert(pat.add(
            .size,
            .{ .integer = @intFromFloat(@round(self.size)) },
            false,
        ));
        if (self.bold) assert(pat.add(
            .weight,
            .{ .integer = @intFromEnum(fontconfig.Weight.bold) },
            false,
        ));
        if (self.italic) assert(pat.add(
            .slant,
            .{ .integer = @intFromEnum(fontconfig.Slant.italic) },
            false,
        ));
        assert(pat.add(
            .spacing,
            .{ .integer = @intFromEnum(fontconfig.Spacing.mono) },
            false,
        ));
        return pat;
    }
    pub fn toCoreTextDescriptor(self: Descriptor) !*macos.text.FontDescriptor {
        const attrs = try macos.foundation.MutableDictionary.create(0);
        defer attrs.release();
        if (self.family) |family_bytes| {
            const family = try macos.foundation.String.createWithBytes(family_bytes, .utf8, false);
            defer family.release();
            attrs.setValue(
                macos.text.FontAttribute.family_name.key(),
                family,
            );
        }
        if (self.style) |style_bytes| {
            const style = try macos.foundation.String.createWithBytes(style_bytes, .utf8, false);
            defer style.release();
            attrs.setValue(
                macos.text.FontAttribute.style_name.key(),
                style,
            );
        }
        if (self.codepoint > 0) {
            const cs = try macos.foundation.CharacterSet.createWithCharactersInRange(.{
                .location = self.codepoint,
                .length = 1,
            });
            defer cs.release();
            attrs.setValue(
                macos.text.FontAttribute.character_set.key(),
                cs,
            );
        }
        if (self.size > 0) {
            const size32: i32 = @intFromFloat(@round(self.size));
            const size = try macos.foundation.Number.create(
                .sint32,
                &size32,
            );
            defer size.release();
            attrs.setValue(
                macos.text.FontAttribute.size.key(),
                size,
            );
        }
        const traits: macos.text.FontSymbolicTraits = .{
            .bold = self.bold,
            .italic = self.italic,
            .monospace = self.monospace,
        };
        const traits_cval: u32 = @bitCast(traits);
        if (traits_cval > 0) {
            const traits_num = try macos.foundation.Number.create(
                .sint32,
                @as(*const i32, @ptrCast(&traits_cval)),
            );
            defer traits_num.release();
            const traits_dict = try macos.foundation.MutableDictionary.create(0);
            defer traits_dict.release();
            traits_dict.setValue(
                macos.text.FontTraitKey.symbolic.key(),
                traits_num,
            );
            attrs.setValue(
                macos.text.FontAttribute.traits.key(),
                traits_dict,
            );
        }
        return try macos.text.FontDescriptor.createWithAttributes(@ptrCast(attrs));
    }
};
pub const Fontconfig = struct {
    fc_config: *fontconfig.Config,
    pub fn init(lib: Library) Fontconfig {
        _ = lib;
        _ = fontconfig.init();
        return .{ .fc_config = fontconfig.initLoadConfigAndFonts() };
    }
    pub fn deinit(self: *Fontconfig) void {
        self.fc_config.destroy();
    }
    pub fn discover(
        self: *const Fontconfig,
        alloc: Allocator,
        desc: Descriptor,
    ) !DiscoverIterator {
        _ = alloc;
        const pat = desc.toFcPattern();
        errdefer pat.destroy();
        assert(self.fc_config.substituteWithPat(pat, .pattern));
        pat.defaultSubstitute();
        const res = self.fc_config.fontSort(pat, false, null);
        if (res.result != .match) return error.FontConfigFailed;
        errdefer res.fs.destroy();
        return .{
            .config = self.fc_config,
            .pattern = pat,
            .set = res.fs,
            .fonts = res.fs.fonts(),
            .variations = desc.variations,
            .i = 0,
        };
    }
    pub fn discoverFallback(
        self: *const Fontconfig,
        alloc: Allocator,
        collection: *Collection,
        desc: Descriptor,
    ) !DiscoverIterator {
        _ = collection;
        return try self.discover(alloc, desc);
    }
    pub const DiscoverIterator = struct {
        config: *fontconfig.Config,
        pattern: *fontconfig.Pattern,
        set: *fontconfig.FontSet,
        fonts: []*fontconfig.Pattern,
        variations: []const Variation,
        i: usize,
        pub fn deinit(self: *DiscoverIterator) void {
            self.set.destroy();
            self.pattern.destroy();
            self.* = undefined;
        }
        pub fn next(self: *DiscoverIterator) fontconfig.Error!?DeferredFace {
            if (self.i >= self.fonts.len) return null;
            const font_pattern = try self.config.fontRenderPrepare(
                self.pattern,
                self.fonts[self.i],
            );
            errdefer font_pattern.destroy();
            defer self.i += 1;
            return DeferredFace{
                .fc = .{
                    .pattern = font_pattern,
                    .charset = (try font_pattern.get(.charset, 0)).char_set,
                    .langset = (try font_pattern.get(.lang, 0)).lang_set,
                    .variations = self.variations,
                },
            };
        }
    };
};
pub const CoreText = struct {
    pub fn init(lib: Library) CoreText {
        _ = lib;
        return .{};
    }
    pub fn deinit(self: *CoreText) void {
        _ = self;
    }
    pub fn warmup() void {
        const name = macos.foundation.String.createWithBytes(
            "AppleColorEmoji",
            .utf8,
            false,
        ) catch return;
        defer name.release();
        const ct_font = macos.text.Font.createWithName(name, 12) catch return;
        ct_font.release();
    }
    pub fn discover(self: *const CoreText, alloc: Allocator, desc: Descriptor) !DiscoverIterator {
        _ = self;
        const ct_desc = try desc.toCoreTextDescriptor();
        defer ct_desc.release();
        var ct_desc_arr = [_]*const macos.text.FontDescriptor{ct_desc};
        const desc_arr = try macos.foundation.Array.create(macos.text.FontDescriptor, &ct_desc_arr);
        defer desc_arr.release();
        const set = try macos.text.FontCollection.createWithFontDescriptors(desc_arr);
        defer set.release();
        const list = set.createMatchingFontDescriptors();
        defer list.release();
        const zig_list = try copyMatchingDescriptors(alloc, list);
        errdefer alloc.free(zig_list);
        sortMatchingDescriptors(&desc, zig_list);
        return DiscoverIterator{
            .alloc = alloc,
            .list = zig_list,
            .variations = desc.variations,
            .i = 0,
        };
    }
    pub fn discoverExactFamily(
        self: *const CoreText,
        family: []const u8,
    ) !?DeferredFace {
        _ = self;
        const family_str = try macos.foundation.String.createWithBytes(
            family,
            .utf8,
            false,
        );
        defer family_str.release();
        const ct_font = try macos.text.Font.createWithName(family_str, 12);
        const found: bool = found: {
            const actual = ct_font.copyFamilyName();
            defer actual.release();
            var buf: [256]u8 = undefined;
            const actual_slice = actual.cstring(&buf, .utf8) orelse
                break :found false;
            break :found std.mem.eql(u8, actual_slice, family);
        };
        if (!found) {
            ct_font.release();
            return null;
        }
        return .{ .ct = .{
            .font = ct_font,
            .variations = &.{},
        } };
    }
    pub fn discoverFallback(
        self: *const CoreText,
        alloc: Allocator,
        collection: *Collection,
        desc: Descriptor,
    ) !DiscoverIterator {
        if (desc.codepoint >= 0x4E00 and
            desc.codepoint <= 0x9FFF)
        han: {
            const han = try self.discoverCodepoint(
                collection,
                desc,
            ) orelse break :han;
            const list = try alloc.alloc(*macos.text.FontDescriptor, 1);
            errdefer alloc.free(list);
            list[0] = han;
            return DiscoverIterator{
                .alloc = alloc,
                .list = list,
                .variations = desc.variations,
                .i = 0,
            };
        }
        const it = try self.discover(alloc, desc);
        if (it.list.len == 0 and desc.codepoint > 0) codepoint: {
            const ct_desc = try self.discoverCodepoint(
                collection,
                desc,
            ) orelse break :codepoint;
            const list = try alloc.alloc(*macos.text.FontDescriptor, 1);
            errdefer alloc.free(list);
            list[0] = ct_desc;
            return DiscoverIterator{
                .alloc = alloc,
                .list = list,
                .variations = desc.variations,
                .i = 0,
            };
        }
        return it;
    }
    fn discoverCodepoint(
        self: *const CoreText,
        collection: *Collection,
        desc: Descriptor,
    ) !?*macos.text.FontDescriptor {
        _ = self;
        if (comptime options.backend.hasFreetype()) {
            return null;
        }
        assert(desc.codepoint > 0);
        const original = original: {
            if (desc.bold and desc.italic) {
                const entries = collection.faces.get(.bold_italic);
                if (entries.count() > 0) {
                    break :original try collection.getFace(.{ .style = .bold_italic });
                }
            }
            if (desc.bold) {
                const entries = collection.faces.get(.bold);
                if (entries.count() > 0) {
                    break :original try collection.getFace(.{ .style = .bold });
                }
            }
            if (desc.italic) {
                const entries = collection.faces.get(.italic);
                if (entries.count() > 0) {
                    break :original try collection.getFace(.{ .style = .italic });
                }
            }
            break :original try collection.getFace(.{ .style = .regular });
        };
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(
            @intCast(desc.codepoint),
            &buf,
        );
        const str = try macos.foundation.String.createWithBytes(
            buf[0..len],
            .utf8,
            false,
        );
        defer str.release();
        const range_len: usize = range_len: {
            var unichars: [2]u16 = undefined;
            const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(
                desc.codepoint,
                &unichars,
            );
            break :range_len if (pair) 2 else 1;
        };
        const font = original.font.createForString(
            str,
            macos.foundation.Range.init(0, range_len),
        ) orelse return null;
        defer font.release();
        last_resort: {
            const name_str = font.copyPostScriptName();
            defer name_str.release();
            var name_buf: [64]u8 = undefined;
            const name: []const u8 = name_str.cstring(&name_buf, .utf8) orelse
                break :last_resort;
            if (std.mem.eql(u8, "LastResort", name)) return null;
        }
        return font.copyDescriptor();
    }
    fn copyMatchingDescriptors(
        alloc: Allocator,
        list: *macos.foundation.Array,
    ) ![]*macos.text.FontDescriptor {
        var result = try alloc.alloc(*macos.text.FontDescriptor, list.getCount());
        errdefer alloc.free(result);
        for (0..result.len) |i| {
            result[i] = list.getValueAtIndex(macos.text.FontDescriptor, i);
            result[i].retain();
        }
        return result;
    }
    fn sortMatchingDescriptors(
        desc: *const Descriptor,
        list: []*macos.text.FontDescriptor,
    ) void {
        std.mem.sortUnstable(*macos.text.FontDescriptor, list, desc, struct {
            fn lessThan(
                desc_inner: *const Descriptor,
                lhs: *macos.text.FontDescriptor,
                rhs: *macos.text.FontDescriptor,
            ) bool {
                const lhs_score: Score = .score(desc_inner, lhs);
                const rhs_score: Score = .score(desc_inner, rhs);
                return lhs_score.int() > rhs_score.int();
            }
        }.lessThan);
    }
    const Score = packed struct {
        const Backing = @typeInfo(@This()).@"struct".backing_integer.?;
        glyph_count: u16 = 0,
        fuzzy_style: u8 = 0,
        bold: bool = false,
        italic: bool = false,
        exact_style: bool = false,
        monospace: bool = false,
        codepoint: bool = false,
        pub fn int(self: Score) Backing {
            return @bitCast(self);
        }
        fn score(desc: *const Descriptor, ct_desc: *const macos.text.FontDescriptor) Score {
            var self: Score = .{};
            const font: *macos.text.Font = macos.text.Font.createWithFontDescriptor(
                ct_desc,
                12,
            ) catch return self;
            defer font.release();
            {
                const Type = @TypeOf(self.glyph_count);
                self.glyph_count = std.math.cast(
                    Type,
                    font.getGlyphCount(),
                ) orelse std.math.maxInt(Type);
            }
            if (desc.codepoint > 0) {
                var unichars: [2]u16 = undefined;
                const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(
                    desc.codepoint,
                    &unichars,
                );
                const len: usize = if (pair) 2 else 1;
                var glyphs = [2]macos.graphics.Glyph{ 0, 0 };
                self.codepoint = font.getGlyphsForCharacters(
                    unichars[0..len],
                    glyphs[0..len],
                );
            }
            const symbolic_traits: macos.text.FontSymbolicTraits = traits: {
                const traits = ct_desc.copyAttribute(.traits) orelse break :traits .{};
                defer traits.release();
                const key = macos.text.FontTraitKey.symbolic.key();
                const symbolic = traits.getValue(macos.foundation.Number, key) orelse
                    break :traits .{};
                break :traits macos.text.FontSymbolicTraits.init(symbolic);
            };
            self.monospace = symbolic_traits.monospace;
            const is_bold: bool, const is_italic: bool = derived: {
                var is_italic = symbolic_traits.italic;
                var is_bold = symbolic_traits.bold;
                if (head: {
                    const tag = macos.text.FontTableTag.init("head");
                    const data = font.copyTable(tag) orelse break :head null;
                    defer data.release();
                    const ptr = data.getPointer();
                    const len = data.getLength();
                    break :head opentype.Head.init(ptr[0..len]) catch |err| {
                        log.warn("error parsing head table: {}", .{err});
                        break :head null;
                    };
                }) |head_| {
                    const head: opentype.Head = head_;
                    is_bold = is_bold or (head.macStyle & 1 == 1);
                    is_italic = is_italic or (head.macStyle & 2 == 2);
                }
                if (os2: {
                    const tag = macos.text.FontTableTag.init("OS/2");
                    const data = font.copyTable(tag) orelse break :os2 null;
                    defer data.release();
                    const ptr = data.getPointer();
                    const len = data.getLength();
                    break :os2 opentype.OS2.init(ptr[0..len]) catch |err| {
                        log.warn("error parsing OS/2 table: {}", .{err});
                        break :os2 null;
                    };
                }) |os2| {
                    is_bold = is_bold or os2.fsSelection.bold;
                    is_italic = is_italic or os2.fsSelection.italic;
                }
                if (font.copyAttribute(.variation_axes)) |axes| variations: {
                    defer axes.release();
                    const values: *macos.foundation.Dictionary =
                        font.copyAttribute(.variation) orelse break :variations;
                    defer values.release();
                    var buf: [1024]u8 = undefined;
                    var ital_seen = false;
                    const len = axes.getCount();
                    for (0..len) |i| {
                        const dict = axes.getValueAtIndex(macos.foundation.Dictionary, i);
                        const Key = macos.text.FontVariationAxisKey;
                        const cf_id = dict.getValue(Key.identifier.Value(), Key.identifier.key()).?;
                        const cf_name = dict.getValue(Key.name.Value(), Key.name.key()).?;
                        const cf_def = dict.getValue(Key.default_value.Value(), Key.default_value.key()).?;
                        const name_str = cf_name.cstring(&buf, .utf8) orelse "";
                        var def: f64 = 0;
                        _ = cf_def.getValue(.double, &def);
                        var val: f64 = def;
                        if (values.getValue(
                            macos.foundation.Number,
                            cf_id,
                        )) |cf_val| _ = cf_val.getValue(.double, &val);
                        if (std.mem.eql(u8, "wght", name_str)) {
                            is_bold = val > 600;
                            continue;
                        }
                        if (std.mem.eql(u8, "ital", name_str)) {
                            is_italic = val > 0.5;
                            ital_seen = true;
                            continue;
                        }
                        if (!ital_seen and std.mem.eql(u8, "slnt", name_str)) {
                            is_italic = val <= -5.0;
                            continue;
                        }
                    }
                }
                break :derived .{ is_bold, is_italic };
            };
            self.bold = desc.bold == is_bold;
            self.italic = desc.italic == is_italic;
            var style_str_buf: [128]u8 = undefined;
            const style_str: []const u8 = style_str: {
                const style = ct_desc.copyAttribute(.style_name) orelse
                    break :style_str "";
                defer style.release();
                break :style_str style.cstring(&style_str_buf, .utf8) orelse "";
            };
            const desired_styles: []const [:0]const u8 = desired: {
                if (desc.style) |s| break :desired &.{s};
                if (desc.bold) {
                    if (desc.italic) break :desired &.{ "bold italic", "bold", "italic", "oblique" };
                    break :desired &.{ "bold", "upright" };
                } else if (desc.italic) {
                    break :desired &.{ "italic", "regular", "oblique" };
                }
                break :desired &.{ "regular", "upright" };
            };
            self.exact_style = std.ascii.eqlIgnoreCase(
                style_str,
                desired_styles[0],
            );
            const fuzzy_type = @TypeOf(self.fuzzy_style);
            self.fuzzy_style = @intCast(style_str.len);
            for (desired_styles) |s| {
                if (std.ascii.indexOfIgnoreCase(style_str, s) != null) {
                    self.fuzzy_style -|= @intCast(s.len);
                }
            }
            self.fuzzy_style = std.math.maxInt(fuzzy_type) -| self.fuzzy_style;
            return self;
        }
    };
    pub const DiscoverIterator = struct {
        alloc: Allocator,
        list: []const *macos.text.FontDescriptor,
        variations: []const Variation,
        i: usize,
        pub fn deinit(self: *DiscoverIterator) void {
            for (self.list) |desc| {
                desc.release();
            }
            self.alloc.free(self.list);
            self.* = undefined;
        }
        pub fn next(self: *DiscoverIterator) !?DeferredFace {
            if (self.i >= self.list.len) return null;
            const desc = desc: {
                const attrs = try macos.foundation.MutableDictionary.create(0);
                defer attrs.release();
                attrs.setValue(
                    macos.text.FontAttribute.character_set.key(),
                    macos.c.kCFNull,
                );
                break :desc try macos.text.FontDescriptor.createCopyWithAttributes(
                    self.list[self.i],
                    @ptrCast(attrs),
                );
            };
            defer desc.release();
            const font = try macos.text.Font.createWithFontDescriptor(desc, 12);
            errdefer font.release();
            defer self.i += 1;
            return DeferredFace{
                .ct = .{
                    .font = font,
                    .variations = self.variations,
                },
            };
        }
    };
};
pub const Windows = struct {
    lib: Library,
    pub fn init(lib: Library) Windows {
        return .{ .lib = lib };
    }
    pub fn deinit(self: *Windows) void {
        _ = self;
    }
    pub fn discover(
        self: *const Windows,
        alloc: Allocator,
        desc: Descriptor,
    ) !DiscoverIterator {
        return .{
            .alloc = alloc,
            .lib = self.lib,
            .desc = desc,
            .variations = desc.variations,
            .state = .system,
            .dir = null,
            .iter = null,
            .system_path = null,
            .user_path = null,
        };
    }
    pub fn discoverFallback(
        self: *const Windows,
        alloc: Allocator,
        collection: *Collection,
        desc: Descriptor,
    ) !DiscoverIterator {
        _ = collection;
        return self.discover(alloc, desc);
    }
    pub const DiscoverIterator = struct {
        alloc: Allocator,
        lib: Library,
        desc: Descriptor,
        variations: []const Variation,
        state: State,
        dir: ?std.Io.Dir,
        iter: ?std.Io.Dir.Iterator,
        system_path: ?[:0]const u8,
        user_path: ?[:0]const u8,
        const State = enum { system, user, done };
        pub fn deinit(self: *DiscoverIterator) void {
            if (self.dir) |*d| d.close(global.io());
            if (self.system_path) |p| self.alloc.free(p);
            if (self.user_path) |p| self.alloc.free(p);
            self.* = undefined;
        }
        pub fn next(self: *DiscoverIterator) !?DeferredFace {
            while (true) {
                if (self.iter == null) {
                    switch (self.state) {
                        .system => {
                            const path = self.systemFontsPath() orelse {
                                self.state = .user;
                                continue;
                            };
                            self.system_path = path;
                            self.dir = std.Io.Dir.openDirAbsolute(
                                global.io(),
                                path,
                                .{ .iterate = true },
                            ) catch {
                                self.state = .user;
                                continue;
                            };
                            self.iter = self.dir.?.iterate();
                        },
                        .user => {
                            const path = self.userFontsPath() orelse {
                                self.state = .done;
                                continue;
                            };
                            self.user_path = path;
                            self.dir = std.Io.Dir.openDirAbsolute(
                                global.io(),
                                path,
                                .{ .iterate = true },
                            ) catch {
                                self.state = .done;
                                continue;
                            };
                            self.iter = self.dir.?.iterate();
                        },
                        .done => return null,
                    }
                }
                const entry = (self.iter.?.next(global.io()) catch null) orelse {
                    if (self.dir) |*d| d.close(global.io());
                    self.dir = null;
                    self.iter = null;
                    self.state = switch (self.state) {
                        .system => .user,
                        .user => .done,
                        .done => .done,
                    };
                    continue;
                };
                if (entry.kind != .file) continue;
                if (!isFontFile(entry.name)) continue;
                if (try self.tryMatch(entry.name)) |face| return face;
            }
        }
        fn systemFontsPath(self: *DiscoverIterator) ?[:0]const u8 {
            const systemroot = global.environ().getAlloc(
                self.alloc,
                "SYSTEMROOT",
            ) catch return null;
            defer self.alloc.free(systemroot);
            return std.fmt.allocPrintSentinel(
                self.alloc,
                "{s}\\Fonts",
                .{systemroot},
                0,
            ) catch null;
        }
        fn userFontsPath(self: *DiscoverIterator) ?[:0]const u8 {
            const local_appdata = global.environ().getAlloc(
                self.alloc,
                "LOCALAPPDATA",
            ) catch return null;
            defer self.alloc.free(local_appdata);
            return std.fmt.allocPrintSentinel(
                self.alloc,
                "{s}\\Microsoft\\Windows\\Fonts",
                .{local_appdata},
                0,
            ) catch null;
        }
        fn tryMatch(
            self: *DiscoverIterator,
            name: []const u8,
        ) !?DeferredFace {
            const dir_path = switch (self.state) {
                .system => self.system_path.?,
                .user => self.user_path.?,
                .done => return null,
            };
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const full_path = std.fmt.bufPrintZ(
                &path_buf,
                "{s}\\{s}",
                .{ dir_path, name },
            ) catch return null;
            const is_ttc = std.ascii.endsWithIgnoreCase(name, ".ttc");
            const max_faces: i32 = if (is_ttc) 16 else 1;
            var face_index: i32 = 0;
            while (face_index < max_faces) : (face_index += 1) {
                var face = Face.initFile(
                    self.lib,
                    full_path,
                    face_index,
                    .{ .size = .{ .points = 12 } },
                ) catch break;
                if (self.matches(&face)) {
                    return try self.makeDeferred(face, full_path, face_index);
                }
                face.deinit();
            }
            return null;
        }
        fn matches(self: *const DiscoverIterator, face: *Face) bool {
            if (self.desc.family) |family| {
                if (!familyMatches(face, family)) return false;
            }
            if (self.desc.codepoint != 0) {
                if (face.glyphIndex(self.desc.codepoint) == null) return false;
            }
            return true;
        }
        fn makeDeferred(
            self: *DiscoverIterator,
            face: Face,
            full_path: []const u8,
            face_index: i32,
        ) !DeferredFace {
            const path_owned = try self.alloc.dupeZ(u8, full_path);
            errdefer self.alloc.free(path_owned);
            const presentation: Presentation =
                if (face.hasColor()) .emoji else .text;
            return DeferredFace{
                .win = .{
                    .path = path_owned,
                    .face_index = face_index,
                    .variations = self.variations,
                    .peek = face,
                    .presentation = presentation,
                    .alloc = self.alloc,
                },
            };
        }
    };
    fn isFontFile(name: []const u8) bool {
        return std.ascii.endsWithIgnoreCase(name, ".ttf") or
            std.ascii.endsWithIgnoreCase(name, ".ttc") or
            std.ascii.endsWithIgnoreCase(name, ".otf");
    }
    fn familyMatches(face: *Face, family: [:0]const u8) bool {
        const ft_family: ?[*:0]const u8 = face.face.handle.*.family_name;
        if (ft_family) |f| {
            if (std.ascii.eqlIgnoreCase(std.mem.span(f), family)) return true;
        }
        var buf: [256]u8 = undefined;
        const sfnt = face.name(&buf) catch "";
        return sfnt.len > 0 and std.ascii.eqlIgnoreCase(sfnt, family);
    }
};
test "descriptor hash" {
    const testing = std.testing;
    var d: Descriptor = .{};
    try testing.expect(d.hashcode() != 0);
}
test "descriptor hash family names" {
    const testing = std.testing;
    var d1: Descriptor = .{ .family = "A" };
    var d2: Descriptor = .{ .family = "B" };
    try testing.expect(d1.hashcode() != d2.hashcode());
}
test "fontconfig" {
    if (options.backend != .fontconfig_freetype) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var fc = Fontconfig.init(lib);
    defer fc.deinit();
    var it = try fc.discover(alloc, .{ .family = "monospace", .size = 12 });
    defer it.deinit();
}
test "fontconfig codepoint" {
    if (options.backend != .fontconfig_freetype) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var fc = Fontconfig.init(lib);
    defer fc.deinit();
    var it = try fc.discover(alloc, .{ .codepoint = 'A', .size = 12 });
    defer it.deinit();
    var face = (try it.next()).?;
    defer face.deinit();
    try testing.expect(face.hasCodepoint('A', null));
    try testing.expect(face.hasCodepoint('B', null));
}
test "coretext" {
    if (options.backend != .coretext and options.backend != .coretext_freetype)
        return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var ct = CoreText.init(lib);
    defer ct.deinit();
    var it = try ct.discover(alloc, .{ .family = "Monaco", .size = 12 });
    defer it.deinit();
    var count: usize = 0;
    while (try it.next()) |_| {
        count += 1;
    }
    try testing.expect(count > 0);
}
test "coretext codepoint" {
    if (options.backend != .coretext and options.backend != .coretext_freetype)
        return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var ct = CoreText.init(lib);
    defer ct.deinit();
    var it = try ct.discover(alloc, .{ .codepoint = 'A', .size = 12 });
    defer it.deinit();
    const face = (try it.next()).?;
    try testing.expect(face.hasCodepoint('A', null));
    try testing.expect(face.hasCodepoint('B', null));
}
test "coretext sorting" {
    if (options.backend != .coretext and options.backend != .coretext_freetype)
        return error.SkipZigTest;
    if (true) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var ct = CoreText.init(lib);
    defer ct.deinit();
    {
        var it = try ct.discover(alloc, .{
            .family = "SF Pro",
            .size = 12,
        });
        defer it.deinit();
        const res = (try it.next()).?;
        var buf: [1024]u8 = undefined;
        const name = try res.name(&buf);
        try testing.expectEqualStrings("SF Pro Regular", name);
    }
    {
        var it = try ct.discover(alloc, .{
            .family = "SF Pro",
            .size = 12,
            .italic = true,
        });
        defer it.deinit();
        const res = (try it.next()).?;
        var buf: [1024]u8 = undefined;
        const name = try res.name(&buf);
        try testing.expectEqualStrings("SF Pro Regular Italic", name);
    }
    {
        var it = try ct.discover(alloc, .{
            .family = "SF Pro",
            .size = 12,
            .bold = true,
        });
        defer it.deinit();
        const res = (try it.next()).?;
        var buf: [1024]u8 = undefined;
        const name = try res.name(&buf);
        try testing.expectEqualStrings("SF Pro Bold", name);
    }
    {
        var it = try ct.discover(alloc, .{
            .family = "SF Pro",
            .size = 12,
            .bold = true,
            .italic = true,
        });
        defer it.deinit();
        const res = (try it.next()).?;
        var buf: [1024]u8 = undefined;
        const name = try res.name(&buf);
        try testing.expectEqualStrings("SF Pro Bold Italic", name);
    }
}
test "windows" {
    if (options.backend != .freetype_windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var win = Windows.init(lib);
    defer win.deinit();
    var it = try win.discover(alloc, .{ .family = "Arial", .size = 12 });
    defer it.deinit();
    var face = (try it.next()) orelse return error.TestFontNotFound;
    defer face.deinit();
    try testing.expect(face.hasCodepoint('A', null));
}
