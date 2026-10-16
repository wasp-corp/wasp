const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const macos = @import("macos");
const harfbuzz = @import("harfbuzz");
const font = @import("../main.zig");
const opentype = @import("../opentype.zig");
const quirks = @import("../../quirks.zig");
const log = std.log.scoped(.font_face);
pub const Face = struct {
    font: *macos.text.Font,
    hb_font: if (harfbuzz_shaper) harfbuzz.Font else void,
    quirks_disable_default_font_features: bool = false,
    synthetic_bold: ?f64 = null,
    color: ?ColorState = null,
    size: font.face.DesiredSize,
    const harfbuzz_shaper = font.options.backend.hasHarfbuzz();
    pub const italic_skew = macos.graphics.AffineTransform{
        .a = 1,
        .b = 0,
        .c = 0.267949, 
        .d = 1,
        .tx = 0,
        .ty = 0,
    };
    pub fn init(
        lib: font.Library,
        source: [:0]const u8,
        opts: font.face.Options,
    ) !Face {
        _ = lib;
        const data = try macos.foundation.Data.createWithBytesNoCopy(source);
        defer data.release();
        const desc = macos.text.createFontDescriptorFromData(data) orelse
            return error.FontInitFailure;
        defer desc.release();
        const ct_font = try macos.text.Font.createWithFontDescriptor(desc, 12);
        defer ct_font.release();
        return try initFontCopy(ct_font, opts);
    }
    pub fn initFontCopy(base: *macos.text.Font, opts: font.face.Options) !Face {
        const ct_font = try base.copyWithAttributes(
            opts.size.pixels(),
            null,
            null,
        );
        errdefer ct_font.release();
        return try initFont(ct_font, opts);
    }
    pub fn initFont(ct_font: *macos.text.Font, opts: font.face.Options) !Face {
        const traits = ct_font.getSymbolicTraits();
        var hb_font = if (comptime harfbuzz_shaper) font: {
            var hb_font = try harfbuzz.coretext.createFont(ct_font);
            const pixels: opentype.sfnt.F26Dot6 = .from(opts.size.pixels());
            hb_font.setScale(@bitCast(pixels), @bitCast(pixels));
            break :font hb_font;
        } else {};
        errdefer if (comptime harfbuzz_shaper) hb_font.destroy();
        const color: ?ColorState = if (traits.color_glyphs)
            try .init(ct_font)
        else
            null;
        errdefer if (color) |v| v.deinit();
        var result: Face = .{
            .font = ct_font,
            .hb_font = hb_font,
            .color = color,
            .size = opts.size,
        };
        result.quirks_disable_default_font_features = quirks.disableDefaultFontFeatures(&result);
        if (comptime builtin.mode == .Debug) {
            if (ct_font.copyAttribute(.variation_axes)) |axes| {
                defer axes.release();
                var buf: [1024]u8 = undefined;
                log.debug("variation axes font={s}", .{try result.name(&buf)});
                const len = axes.getCount();
                for (0..len) |i| {
                    const dict = axes.getValueAtIndex(macos.foundation.Dictionary, i);
                    const Key = macos.text.FontVariationAxisKey;
                    const cf_name = dict.getValue(Key.name.Value(), Key.name.key()).?;
                    const cf_id = dict.getValue(Key.identifier.Value(), Key.identifier.key()).?;
                    const cf_min = dict.getValue(Key.minimum_value.Value(), Key.minimum_value.key()).?;
                    const cf_max = dict.getValue(Key.maximum_value.Value(), Key.maximum_value.key()).?;
                    const cf_def = dict.getValue(Key.default_value.Value(), Key.default_value.key()).?;
                    const namestr = cf_name.cstring(&buf, .utf8) orelse "";
                    var id_raw: c_int = 0;
                    _ = cf_id.getValue(.int, &id_raw);
                    const id: font.face.Variation.Id = @bitCast(id_raw);
                    var min: f64 = 0;
                    _ = cf_min.getValue(.double, &min);
                    var max: f64 = 0;
                    _ = cf_max.getValue(.double, &max);
                    var def: f64 = 0;
                    _ = cf_def.getValue(.double, &def);
                    log.debug("variation axis: name={s} id={s} min={} max={} def={}", .{
                        namestr,
                        id.str(),
                        min,
                        max,
                        def,
                    });
                }
            }
        }
        return result;
    }
    pub fn deinit(self: *Face) void {
        self.font.release();
        if (comptime harfbuzz_shaper) self.hb_font.destroy();
        if (self.color) |v| v.deinit();
        self.* = undefined;
    }
    pub fn syntheticItalic(self: *const Face, opts: font.face.Options) !Face {
        const ct_font = try self.font.copyWithAttributes(0.0, &italic_skew, null);
        errdefer ct_font.release();
        return try initFont(ct_font, opts);
    }
    pub fn syntheticBold(self: *const Face, opts: font.face.Options) !Face {
        const ct_font = try self.font.copyWithAttributes(0.0, null, null);
        errdefer ct_font.release();
        var face = try initFont(ct_font, opts);
        const points_f64: f64 = @floatCast(opts.size.points);
        const line_width = @max(points_f64 / 14.0, 1);
        face.synthetic_bold = line_width;
        return face;
    }
    pub fn name(self: *const Face, buf: []u8) Allocator.Error![]const u8 {
        const family_name = self.font.copyFamilyName();
        if (family_name.cstringPtr(.utf8)) |str| return str;
        return family_name.cstring(buf, .utf8) orelse error.OutOfMemory;
    }
    pub fn setSize(self: *Face, opts: font.face.Options) !void {
        const face = try initFontCopy(self.font, opts);
        self.deinit();
        self.* = face;
    }
    pub fn setVariations(
        self: *Face,
        vs: []const font.face.Variation,
        opts: font.face.Options,
    ) !void {
        if (vs.len == 0) return;
        var desc = self.font.copyDescriptor();
        defer desc.release();
        for (vs) |v| {
            const id = try macos.foundation.Number.create(.int, @ptrCast(&v.id));
            defer id.release();
            const next = try desc.createCopyWithVariation(id, v.value);
            desc.release();
            desc = next;
        }
        var new_opts = opts;
        new_opts.size = self.size;
        const ct_font = try self.font.copyWithAttributes(0, null, desc);
        errdefer ct_font.release();
        const face = try initFont(ct_font, new_opts);
        self.deinit();
        self.* = face;
    }
    pub fn hasColor(self: *const Face) bool {
        return self.color != null;
    }
    pub fn isColorGlyph(self: *const Face, glyph_id: u32) bool {
        const c = self.color orelse return false;
        return c.isColorGlyph(glyph_id);
    }
    pub fn glyphIndex(self: Face, cp: u32) ?u32 {
        var unichars: [2]u16 = undefined;
        const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(cp, &unichars);
        const len: usize = if (pair) 2 else 1;
        var glyphs = [2]macos.graphics.Glyph{ 0, 0 };
        if (!self.font.getGlyphsForCharacters(unichars[0..len], glyphs[0..len]))
            return null;
        if (pair) assert(glyphs[1] == 0);
        return @intCast(glyphs[0]);
    }
    pub fn renderGlyph(
        self: Face,
        alloc: Allocator,
        atlas: *font.Atlas,
        glyph_index: u32,
        opts: font.Glyph.RenderOptions,
    ) !font.Glyph {
        var glyphs = [_]macos.graphics.Glyph{@intCast(glyph_index)};
        var rect = self.font.getBoundingRectsForGlyphs(.horizontal, &glyphs, null);
        const is_color = self.isColorGlyph(glyph_index);
        const sbix = is_color and self.color != null and self.color.?.sbix;
        if (!sbix) if (self.synthetic_bold) |line_width| {
            rect.size.width += line_width;
            rect.size.height += line_width;
            rect.origin.x -= line_width / 2;
            rect.origin.y -= line_width / 2;
        };
        if (rect.size.width < 0.25 or rect.size.height < 0.25)
            return font.Glyph{
                .width = 0,
                .height = 0,
                .offset_x = 0,
                .offset_y = 0,
                .atlas_x = 0,
                .atlas_y = 0,
            };
        const metrics = opts.grid_metrics;
        const cell_width: f64 = @floatFromInt(metrics.cell_width);
        const cell_height: f64 = @floatFromInt(metrics.cell_height);
        const constraint = opts.constraint;
        const cell_baseline: f64 = @floatFromInt(metrics.cell_baseline);
        const glyph_size = constraint.constrain(
            .{
                .width = rect.size.width,
                .height = rect.size.height,
                .x = rect.origin.x,
                .y = rect.origin.y + cell_baseline,
            },
            metrics,
            opts.constraint_width,
        );
        var x = glyph_size.x;
        var y = glyph_size.y;
        var width = glyph_size.width;
        var height = glyph_size.height;
        if (constraint.size != .stretch) {
            const dx = (cell_width - metrics.face_width) / 2;
            x += dx;
            if (dx < 0) {
                x -= @trunc(dx);
            }
        }
        if (sbix) {
            width = cell_width - @round(cell_width - width - x) - @round(x);
            height = cell_height - @round(cell_height - height - y) - @round(y);
            x = @round(x);
            y = @round(y);
        }
        const canvas_padding: u32 = if (opts.thicken and !sbix) 1 else 0;
        const px_x = @as(i32, @intFromFloat(@floor(x))) - @as(i32, @intCast(canvas_padding));
        const px_y = @as(i32, @intFromFloat(@floor(y))) - @as(i32, @intCast(canvas_padding));
        const frac_x = x - @floor(x);
        const frac_y = y - @floor(y);
        const px_width = @as(u32, @intFromFloat(@ceil(width + frac_x))) + (2 * canvas_padding);
        const px_height = @as(u32, @intFromFloat(@ceil(height + frac_y))) + (2 * canvas_padding);
        const color: struct {
            color: bool,
            depth: u32,
            space: *macos.graphics.ColorSpace,
            context_opts: c_uint,
        } = if (!is_color) .{
            .color = false,
            .depth = 1,
            .space = try macos.graphics.ColorSpace.createNamed(.linearGray),
            .context_opts = @intFromEnum(macos.graphics.ImageAlphaInfo.only),
        } else .{
            .color = true,
            .depth = 4,
            .space = try macos.graphics.ColorSpace.createNamed(.displayP3),
            .context_opts = @intFromEnum(macos.graphics.BitmapInfo.byte_order_32_little) |
                @intFromEnum(macos.graphics.ImageAlphaInfo.premultiplied_first),
        };
        defer color.space.release();
        if (atlas.format.depth() != color.depth) {
            log.warn("font atlas color depth doesn't equal font color depth atlas={} font={}", .{
                atlas.format.depth(),
                color.depth,
            });
            return error.InvalidAtlasFormat;
        }
        const buf = try alloc.alloc(u8, px_width * px_height * color.depth);
        defer alloc.free(buf);
        @memset(buf, 0);
        const context = macos.graphics.BitmapContext.context;
        const ctx = try macos.graphics.BitmapContext.create(
            buf,
            px_width,
            px_height,
            8,
            px_width * color.depth,
            color.space,
            color.context_opts,
        );
        defer context.release(ctx);
        if (color.color)
            context.setRGBFillColor(ctx, 0, 0, 0, 0)
        else
            context.setGrayFillColor(ctx, 0, 0);
        context.fillRect(ctx, .{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{
                .width = @floatFromInt(px_width),
                .height = @floatFromInt(px_height),
            },
        });
        context.setAllowsFontSmoothing(ctx, true);
        context.setShouldSmoothFonts(ctx, opts.thicken);
        context.setAllowsFontSubpixelPositioning(ctx, true);
        context.setShouldSubpixelPositionFonts(ctx, true);
        context.setAllowsFontSubpixelQuantization(ctx, false);
        context.setShouldSubpixelQuantizeFonts(ctx, false);
        context.setAllowsAntialiasing(ctx, true);
        context.setShouldAntialias(ctx, true);
        if (color.color) {
            context.setRGBFillColor(ctx, 1, 1, 1, 1);
            context.setRGBStrokeColor(ctx, 1, 1, 1, 1);
        } else {
            const strength: f64 = @floatFromInt(opts.thicken_strength);
            context.setGrayFillColor(ctx, strength / 255.0, 1);
            context.setGrayStrokeColor(ctx, strength / 255.0, 1);
        }
        if (self.synthetic_bold) |line_width| {
            context.setTextDrawingMode(ctx, .fill_stroke);
            context.setLineWidth(ctx, line_width);
        }
        context.translateCTM(
            ctx,
            frac_x + @as(f64, @floatFromInt(canvas_padding)),
            frac_y + @as(f64, @floatFromInt(canvas_padding)),
        );
        context.scaleCTM(
            ctx,
            width / rect.size.width,
            height / rect.size.height,
        );
        self.font.drawGlyphs(&glyphs, &.{.{
            .x = -rect.origin.x,
            .y = -rect.origin.y,
        }}, ctx);
        const region = try atlas.reserve(alloc, px_width, px_height);
        atlas.set(region, buf);
        const offset_y: i32 = px_y + @as(i32, @intCast(px_height));
        const offset_x: i32 = px_x;
        return .{
            .width = px_width,
            .height = px_height,
            .offset_x = offset_x,
            .offset_y = offset_y,
            .atlas_x = region.x,
            .atlas_y = region.y,
        };
    }
    pub fn getMetrics(self: *Face) font.Metrics.FaceMetrics {
        const ct_font = self.font;
        const head_: ?opentype.Head = head: {
            const head_tag = macos.text.FontTableTag.init("head");
            const bhed_tag = macos.text.FontTableTag.init("bhed");
            const data =
                ct_font.copyTable(head_tag) orelse
                ct_font.copyTable(bhed_tag) orelse
                break :head null;
            defer data.release();
            const ptr = data.getPointer();
            const len = data.getLength();
            break :head opentype.Head.init(ptr[0..len]) catch |err| {
                log.warn("error parsing head table: {}", .{err});
                break :head null;
            };
        };
        const post_: ?opentype.Post = post: {
            const tag = macos.text.FontTableTag.init("post");
            const data = ct_font.copyTable(tag) orelse break :post null;
            defer data.release();
            const ptr = data.getPointer();
            const len = data.getLength();
            break :post opentype.Post.init(ptr[0..len]) catch |err| {
                log.warn("error parsing post table: {}", .{err});
                break :post null;
            };
        };
        const os2_: ?opentype.OS2 = os2: {
            const tag = macos.text.FontTableTag.init("OS/2");
            const data = ct_font.copyTable(tag) orelse break :os2 null;
            defer data.release();
            const ptr = data.getPointer();
            const len = data.getLength();
            break :os2 opentype.OS2.init(ptr[0..len]) catch |err| {
                log.warn("error parsing OS/2 table: {}", .{err});
                break :os2 null;
            };
        };
        const hhea_: ?opentype.Hhea = hhea: {
            const tag = macos.text.FontTableTag.init("hhea");
            const data = ct_font.copyTable(tag) orelse break :hhea null;
            defer data.release();
            const ptr = data.getPointer();
            const len = data.getLength();
            break :hhea opentype.Hhea.init(ptr[0..len]) catch |err| {
                log.warn("error parsing hhea table: {}", .{err});
                break :hhea null;
            };
        };
        const units_per_em: f64 =
            if (head_) |head|
                @floatFromInt(head.unitsPerEm)
            else
                @floatFromInt(self.font.getUnitsPerEm());
        const px_per_em: f64 = ct_font.getSize();
        const px_per_unit: f64 = px_per_em / units_per_em;
        const ascent: f64, const descent: f64, const line_gap: f64 = vertical_metrics: {
            const hhea = hhea_ orelse break :vertical_metrics .{
                self.font.getAscent(),
                -self.font.getDescent(),
                self.font.getLeading(),
            };
            const hhea_ascent: f64 = @floatFromInt(hhea.ascender);
            const hhea_descent: f64 = @floatFromInt(hhea.descender);
            const hhea_line_gap: f64 = @floatFromInt(hhea.lineGap);
            const os2 = os2_ orelse break :vertical_metrics .{
                hhea_ascent * px_per_unit,
                hhea_descent * px_per_unit,
                hhea_line_gap * px_per_unit,
            };
            const os2_ascent: f64 = @floatFromInt(os2.sTypoAscender);
            const os2_descent: f64 = @floatFromInt(os2.sTypoDescender);
            const os2_line_gap: f64 = @floatFromInt(os2.sTypoLineGap);
            if (os2.fsSelection.use_typo_metrics) break :vertical_metrics .{
                os2_ascent * px_per_unit,
                os2_descent * px_per_unit,
                os2_line_gap * px_per_unit,
            };
            if (hhea.ascender != 0 or hhea.descender != 0) break :vertical_metrics .{
                hhea_ascent * px_per_unit,
                hhea_descent * px_per_unit,
                hhea_line_gap * px_per_unit,
            };
            if (os2_ascent != 0 or os2_descent != 0) break :vertical_metrics .{
                os2_ascent * px_per_unit,
                os2_descent * px_per_unit,
                os2_line_gap * px_per_unit,
            };
            const win_ascent: f64 = @floatFromInt(os2.usWinAscent);
            const win_descent: f64 = @floatFromInt(os2.usWinDescent);
            break :vertical_metrics .{
                win_ascent * px_per_unit,
                -win_descent * px_per_unit,
                0.0,
            };
        };
        const underline_position, const underline_thickness = ul: {
            const post = post_ orelse break :ul .{ null, null };
            const has_broken_underline = post.underlineThickness == 0;
            const pos: ?f64 = if (has_broken_underline and post.underlinePosition == 0)
                null
            else
                @as(f64, @floatFromInt(post.underlinePosition)) * px_per_unit;
            const thick: ?f64 = if (has_broken_underline)
                null
            else
                @as(f64, @floatFromInt(post.underlineThickness)) * px_per_unit;
            break :ul .{ pos, thick };
        };
        const strikethrough_position, const strikethrough_thickness = st: {
            const os2 = os2_ orelse break :st .{ null, null };
            const has_broken_strikethrough = os2.yStrikeoutSize == 0;
            const pos: ?f64 = if (has_broken_strikethrough and os2.yStrikeoutPosition == 0)
                null
            else
                @as(f64, @floatFromInt(os2.yStrikeoutPosition)) * px_per_unit;
            const thick: ?f64 = if (has_broken_strikethrough)
                null
            else
                @as(f64, @floatFromInt(os2.yStrikeoutSize)) * px_per_unit;
            break :st .{ pos, thick };
        };
        const cap_height: f64, const ex_height: f64 = heights: {
            const os2 = os2_ orelse break :heights .{
                ct_font.getCapHeight(),
                ct_font.getXHeight(),
            };
            break :heights .{
                if (os2.sCapHeight) |sCapHeight|
                    @as(f64, @floatFromInt(sCapHeight)) * px_per_unit
                else
                    ct_font.getCapHeight(),
                if (os2.sxHeight) |sxHeight|
                    @as(f64, @floatFromInt(sxHeight)) * px_per_unit
                else
                    ct_font.getXHeight(),
            };
        };
        const cell_width: f64, const ascii_height: f64 = measurements: {
            const unichars = comptime unichars: {
                const len = 127 - 32;
                var result: [len]u16 = undefined;
                var i: u16 = 32;
                while (i < 127) : (i += 1) {
                    result[i - 32] = i;
                }
                break :unichars result;
            };
            var glyphs: [unichars.len]macos.graphics.Glyph = undefined;
            _ = ct_font.getGlyphsForCharacters(&unichars, &glyphs);
            var advances: [unichars.len]macos.graphics.Size = undefined;
            _ = ct_font.getAdvancesForGlyphs(.horizontal, &glyphs, &advances);
            var max: f64 = 0;
            var i: usize = 0;
            while (i < advances.len) : (i += 1) {
                max = @max(advances[i].width, max);
            }
            const rect = ct_font.getBoundingRectsForGlyphs(.horizontal, &glyphs, null);
            break :measurements .{ max, rect.size.height };
        };
        const ic_width: ?f64 = ic_width: {
            const glyph = self.glyphIndex('水') orelse break :ic_width null;
            const advance = ct_font.getAdvancesForGlyphs(
                .horizontal,
                &.{@intCast(glyph)},
                null,
            );
            const bounds = ct_font.getBoundingRectsForGlyphs(
                .horizontal,
                &.{@intCast(glyph)},
                null,
            );
            if (bounds.size.width > advance) {
                var buf: [1024]u8 = undefined;
                const font_name = self.name(&buf) catch "<Error getting font name>";
                log.warn(
                    "(getMetrics) Width of glyph '水' for font \"{s}\" is greater than its advance ({d} > {d}), discarding ic_width metric.",
                    .{
                        font_name,
                        bounds.size.width,
                        advance,
                    },
                );
                break :ic_width null;
            }
            break :ic_width advance;
        };
        return .{
            .px_per_em = px_per_em,
            .cell_width = cell_width,
            .ascent = ascent,
            .descent = descent,
            .line_gap = line_gap,
            .underline_position = underline_position,
            .underline_thickness = underline_thickness,
            .strikethrough_position = strikethrough_position,
            .strikethrough_thickness = strikethrough_thickness,
            .cap_height = cap_height,
            .ex_height = ex_height,
            .ascii_height = ascii_height,
            .ic_width = ic_width,
        };
    }
    pub fn copyTable(
        self: Face,
        alloc: Allocator,
        tag: *const [4]u8,
    ) Allocator.Error!?[]u8 {
        const data = self.font.copyTable(macos.text.FontTableTag.init(tag)) orelse
            return null;
        defer data.release();
        const buf = try alloc.alloc(u8, data.getLength());
        errdefer alloc.free(buf);
        const ptr = data.getPointer();
        @memcpy(buf, ptr[0..buf.len]);
        return buf;
    }
};
const ColorState = struct {
    sbix: bool,
    svg: ?opentype.SVG,
    svg_data: ?*macos.foundation.Data,
    pub const Error = error{InvalidSVGTable};
    pub fn init(f: *macos.text.Font) Error!ColorState {
        const sbix: bool = sbix: {
            const tag = macos.text.FontTableTag.init("sbix");
            const data = f.copyTable(tag) orelse break :sbix false;
            data.release();
            break :sbix data.getLength() > 0;
        };
        const svg: ?struct {
            svg: opentype.SVG,
            data: *macos.foundation.Data,
        } = svg: {
            const tag = macos.text.FontTableTag.init("SVG ");
            const data = f.copyTable(tag) orelse break :svg null;
            errdefer data.release();
            const ptr = data.getPointer();
            const len = data.getLength();
            const svg = opentype.SVG.init(ptr[0..len]) catch |err| {
                return switch (err) {
                    error.EndOfStream,
                    error.ReadFailed,
                    error.SVGVersionNotSupported,
                    => error.InvalidSVGTable,
                };
            };
            break :svg .{
                .svg = svg,
                .data = data,
            };
        };
        return .{
            .sbix = sbix,
            .svg = if (svg) |v| v.svg else null,
            .svg_data = if (svg) |v| v.data else null,
        };
    }
    pub fn deinit(self: *const ColorState) void {
        if (self.svg_data) |v| v.release();
    }
    pub fn isColorGlyph(self: *const ColorState, glyph_id: u32) bool {
        const glyph_u16 = std.math.cast(u16, glyph_id) orelse return false;
        if (self.sbix) return true;
        if (self.svg) |svg| {
            if (svg.hasGlyph(glyph_u16)) return true;
        }
        return false;
    }
};
test {
    const testing = std.testing;
    const alloc = testing.allocator;
    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);
    const name = try macos.foundation.String.createWithBytes("Monaco", .utf8, false);
    defer name.release();
    const desc = try macos.text.FontDescriptor.createWithNameAndSize(name, 12);
    defer desc.release();
    const ct_font = try macos.text.Font.createWithFontDescriptor(desc, 12);
    defer ct_font.release();
    var face = try Face.initFontCopy(ct_font, .{ .size = .{ .points = 12 } });
    defer face.deinit();
    var i: u8 = 32;
    while (i < 127) : (i += 1) {
        try testing.expect(face.glyphIndex(i) != null);
        _ = try face.renderGlyph(
            alloc,
            &atlas,
            face.glyphIndex(i).?,
            .{ .grid_metrics = font.Metrics.calc(face.getMetrics()) },
        );
    }
}
test "name" {
    const testing = std.testing;
    const name = try macos.foundation.String.createWithBytes("Menlo", .utf8, false);
    defer name.release();
    const desc = try macos.text.FontDescriptor.createWithNameAndSize(name, 12);
    defer desc.release();
    const ct_font = try macos.text.Font.createWithFontDescriptor(desc, 12);
    defer ct_font.release();
    var face = try Face.initFontCopy(ct_font, .{ .size = .{ .points = 12 } });
    defer face.deinit();
    var buf: [1024]u8 = undefined;
    const font_name = try face.name(&buf);
    try testing.expectEqualStrings(font_name, "Menlo");
}
test "emoji" {
    const testing = std.testing;
    const name = try macos.foundation.String.createWithBytes("Apple Color Emoji", .utf8, false);
    defer name.release();
    const desc = try macos.text.FontDescriptor.createWithNameAndSize(name, 12);
    defer desc.release();
    const ct_font = try macos.text.Font.createWithFontDescriptor(desc, 12);
    defer ct_font.release();
    var face = try Face.initFontCopy(ct_font, .{ .size = .{ .points = 18 } });
    defer face.deinit();
    {
        const id = face.glyphIndex('🥸').?;
        try testing.expect(face.isColorGlyph(id));
    }
}
test "in-memory" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;
    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);
    var lib = try font.Library.init(alloc);
    defer lib.deinit();
    var face = try Face.init(lib, testFont, .{ .size = .{ .points = 12 } });
    defer face.deinit();
    var i: u8 = 32;
    while (i < 127) : (i += 1) {
        try testing.expect(face.glyphIndex(i) != null);
        _ = try face.renderGlyph(
            alloc,
            &atlas,
            face.glyphIndex(i).?,
            .{ .grid_metrics = font.Metrics.calc(face.getMetrics()) },
        );
    }
}
test "variable" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.variable;
    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);
    var lib = try font.Library.init(alloc);
    defer lib.deinit();
    var face = try Face.init(lib, testFont, .{ .size = .{ .points = 12 } });
    defer face.deinit();
    var i: u8 = 32;
    while (i < 127) : (i += 1) {
        try testing.expect(face.glyphIndex(i) != null);
        _ = try face.renderGlyph(
            alloc,
            &atlas,
            face.glyphIndex(i).?,
            .{ .grid_metrics = font.Metrics.calc(face.getMetrics()) },
        );
    }
}
test "variable set variation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.variable;
    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);
    var lib = try font.Library.init(alloc);
    defer lib.deinit();
    var face = try Face.init(lib, testFont, .{ .size = .{ .points = 12 } });
    defer face.deinit();
    try face.setVariations(&.{
        .{ .id = font.face.Variation.Id.init("wght"), .value = 400 },
    }, .{ .size = .{ .points = 12 } });
    var i: u8 = 32;
    while (i < 127) : (i += 1) {
        try testing.expect(face.glyphIndex(i) != null);
        _ = try face.renderGlyph(
            alloc,
            &atlas,
            face.glyphIndex(i).?,
            .{ .grid_metrics = font.Metrics.calc(face.getMetrics()) },
        );
    }
}
test "svg font table" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.julia_mono;
    var lib = try font.Library.init(alloc);
    defer lib.deinit();
    var face = try Face.init(lib, testFont, .{ .size = .{ .points = 12 } });
    defer face.deinit();
    const table = (try face.copyTable(alloc, "SVG ")).?;
    defer alloc.free(table);
    try testing.expect(table.len > 0);
}
test "glyphIndex colored vs text" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.julia_mono;
    var lib = try font.Library.init(alloc);
    defer lib.deinit();
    var face = try Face.init(lib, testFont, .{ .size = .{ .points = 12 } });
    defer face.deinit();
    {
        const glyph = face.glyphIndex('A').?;
        try testing.expectEqual(4, glyph);
        try testing.expect(!face.isColorGlyph(glyph));
    }
    {
        const glyph = face.glyphIndex(0xE800).?;
        try testing.expectEqual(11482, glyph);
        try testing.expect(face.isColorGlyph(glyph));
    }
}
