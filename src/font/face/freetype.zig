const std = @import("std");
const builtin = @import("builtin");
const freetype = @import("freetype");
const harfbuzz = @import("harfbuzz");
const stb = @import("../../stb/root.zig");
const assert = @import("../../quirks.zig").inlineAssert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const font = @import("../main.zig");
const Glyph = font.Glyph;
const Library = font.Library;
const opentype = @import("../opentype.zig");
const quirks = @import("../../quirks.zig");
const config = @import("../../config.zig");
const global = @import("../../global.zig");
const F26Dot6 = opentype.sfnt.F26Dot6;
const log = std.log.scoped(.font_face);
pub const Face = struct {
    comptime {
        assert(font.face.FreetypeLoadFlags != void);
    }
    lib: Library,
    face: freetype.Face,
    ft_mutex: *std.Io.Mutex,
    hb_font: harfbuzz.Font,
    load_flags: font.face.FreetypeLoadFlags,
    quirks_disable_default_font_features: bool = false,
    synthetic: packed struct {
        italic: bool = false,
        bold: bool = false,
    } = .{},
    size: font.face.DesiredSize,
    pub fn initFile(
        lib: Library,
        path: [:0]const u8,
        index: i32,
        opts: font.face.Options,
    ) !Face {
        lib.mutex.lockUncancelable(global.io());
        defer lib.mutex.unlock(global.io());
        const face = try lib.lib.initFace(path, index);
        errdefer face.deinit();
        return try initFace(lib, face, opts);
    }
    pub fn init(
        lib: Library,
        source: [:0]const u8,
        opts: font.face.Options,
    ) !Face {
        lib.mutex.lockUncancelable(global.io());
        defer lib.mutex.unlock(global.io());
        const face = try lib.lib.initMemoryFace(source, 0);
        errdefer face.deinit();
        return try initFace(lib, face, opts);
    }
    fn initFace(
        lib: Library,
        face: freetype.Face,
        opts: font.face.Options,
    ) !Face {
        try face.selectCharmap(.unicode);
        try setSize_(face, opts.size);
        var hb_font = try harfbuzz.freetype.createFont(face.handle);
        errdefer hb_font.destroy();
        const ft_mutex = try lib.alloc.create(std.Io.Mutex);
        errdefer lib.alloc.destroy(ft_mutex);
        ft_mutex.* = .init;
        var result: Face = .{
            .lib = lib,
            .face = face,
            .hb_font = hb_font,
            .ft_mutex = ft_mutex,
            .load_flags = opts.freetype_load_flags,
            .size = opts.size,
        };
        result.quirks_disable_default_font_features = quirks.disableDefaultFontFeatures(&result);
        if (comptime builtin.mode == .Debug) mm: {
            if (!face.hasMultipleMasters()) break :mm;
            var buf: [1024]u8 = undefined;
            log.debug("variation axes font={s}", .{try result.name(&buf)});
            const mm = try face.getMMVar();
            defer lib.lib.doneMMVar(mm);
            for (0..mm.num_axis) |i| {
                const axis = mm.axis[i];
                const id_raw = std.math.cast(c_int, axis.tag) orelse continue;
                const id: font.face.Variation.Id = @bitCast(id_raw);
                log.debug("variation axis: name={s} id={s} min={} max={} def={}", .{
                    std.mem.sliceTo(axis.name, 0),
                    id.str(),
                    axis.minimum >> 16,
                    axis.maximum >> 16,
                    axis.def >> 16,
                });
            }
        }
        return result;
    }
    pub fn deinit(self: *Face) void {
        self.lib.alloc.destroy(self.ft_mutex);
        {
            self.lib.mutex.lockUncancelable(global.io());
            defer self.lib.mutex.unlock(global.io());
            self.face.deinit();
        }
        self.hb_font.destroy();
        self.* = undefined;
    }
    pub fn name(self: *const Face, buf: []u8) Allocator.Error![]const u8 {
        const count = self.face.getSfntNameCount();
        for (0..count) |i| {
            const entry = self.face.getSfntName(i) catch continue;
            if (entry.name_id == freetype.c.TT_NAME_ID_FONT_FAMILY) {
                const string = entry.string[0..entry.string_len];
                if (entry.platform_id == freetype.c.TT_PLATFORM_MICROSOFT and entry.encoding_id == freetype.c.TT_MS_ID_UNICODE_CS) skip: {
                    if (string.len % 2 != 0) break :skip;
                    if (string.len > 1024) break :skip;
                    var tmp: [512]u16 = undefined;
                    const max = string.len / 2;
                    for (@as([]const u16, @ptrCast(@alignCast(string))), 0..) |c, j| tmp[j] = @byteSwap(c);
                    const len = std.unicode.utf16LeToUtf8(buf, tmp[0..max]) catch return string;
                    return buf[0..len];
                }
                return string;
            }
        }
        return "";
    }
    test "face name" {
        const embedded = @import("../embedded.zig");
        var lib: Library = try .init(testing.allocator);
        defer lib.deinit();
        {
            var face: Face = try .init(lib, embedded.variable, .{ .size = .{ .points = 14 } });
            defer face.deinit();
            var buf: [1024]u8 = undefined;
            const actual = try face.name(&buf);
            try testing.expectEqualStrings("JetBrains Mono", actual);
        }
        {
            var face: Face = try .init(lib, embedded.inconsolata, .{ .size = .{ .points = 14 } });
            defer face.deinit();
            var buf: [1024]u8 = undefined;
            const actual = try face.name(&buf);
            try testing.expectEqualStrings("Inconsolata", actual);
        }
    }
    pub fn syntheticBold(self: *const Face, opts: font.face.Options) !Face {
        self.face.ref();
        errdefer self.face.deinit();
        var f = try initFace(self.lib, self.face, opts);
        errdefer f.deinit();
        f.synthetic = self.synthetic;
        f.synthetic.bold = true;
        return f;
    }
    pub fn syntheticItalic(self: *const Face, opts: font.face.Options) !Face {
        self.face.ref();
        errdefer self.face.deinit();
        var f = try initFace(self.lib, self.face, opts);
        errdefer f.deinit();
        f.synthetic = self.synthetic;
        f.synthetic.italic = true;
        return f;
    }
    pub fn setSize(self: *Face, opts: font.face.Options) !void {
        try setSize_(self.face, opts.size);
        self.size = opts.size;
    }
    fn setSize_(face: freetype.Face, size: font.face.DesiredSize) !void {
        if (face.isScalable()) {
            const size_26dot6: i32 = @intFromFloat(@round(size.points * 64));
            try face.setCharSize(0, size_26dot6, size.xdpi, size.ydpi);
        } else try selectSizeNearest(face, @intFromFloat(@round(size.pixels())));
    }
    fn selectSizeNearest(face: freetype.Face, size: u32) !void {
        var i: i32 = 0;
        var best_i: i32 = 0;
        var best_diff: i32 = 0;
        while (i < face.handle.*.num_fixed_sizes) : (i += 1) {
            const width = face.handle.*.available_sizes[@intCast(i)].width;
            const diff = @as(i32, @intCast(size)) - @as(i32, @intCast(width));
            if (i == 0 or diff < best_diff) {
                best_diff = diff;
                best_i = i;
            }
        }
        try face.selectSize(best_i);
    }
    pub fn setVariations(
        self: *Face,
        vs: []const font.face.Variation,
        opts: font.face.Options,
    ) !void {
        _ = opts;
        if (!self.face.hasMultipleMasters() or vs.len == 0) return;
        const mm = try self.face.getMMVar();
        defer self.lib.lib.doneMMVar(mm);
        var coords_buf: [32]freetype.c.FT_Fixed = undefined;
        var coords = coords_buf[0..@min(coords_buf.len, mm.num_axis)];
        try self.face.getVarDesignCoordinates(coords);
        for (0..mm.num_axis) |i| {
            const axis = mm.axis[i];
            const id = std.math.cast(u32, axis.tag) orelse continue;
            for (vs) |v| {
                if (id == @as(u32, @bitCast(v.id))) {
                    coords[i] = @intFromFloat(v.value * 65536);
                    break;
                }
            }
        }
        try self.face.setVarDesignCoordinates(coords);
    }
    pub fn glyphIndex(self: Face, cp: u32) ?u32 {
        return self.face.getCharIndex(cp);
    }
    pub fn hasColor(self: Face) bool {
        return self.face.hasColor();
    }
    pub fn isColorGlyph(self: *const Face, glyph_id: u32) bool {
        self.ft_mutex.lockUncancelable(global.io());
        defer self.ft_mutex.unlock(global.io());
        self.face.loadGlyph(glyph_id, .{
            .render = true,
            .color = self.face.hasColor(),
            .no_svg = true,
        }) catch return false;
        const glyph = self.face.handle.*.glyph;
        return glyph.*.bitmap.pixel_mode == freetype.c.FT_PIXEL_MODE_BGRA;
    }
    fn glyphLoadFlags(self: Face, constrained: bool) freetype.LoadFlags {
        const do_hinting = self.load_flags.hinting and !constrained;
        return .{
            .color = self.face.hasColor(),
            .render = false,
            .no_hinting = !do_hinting,
            .force_autohint = self.load_flags.@"force-autohint",
            .no_autohint = !self.load_flags.autohint,
            .target = if (self.load_flags.monochrome)
                .mono
            else if (self.load_flags.light)
                .light
            else
                .normal,
            .no_svg = true,
        };
    }
    fn getGlyphSize(glyph: freetype.c.FT_GlyphSlot) font.Glyph.Size {
        if (glyph.*.format == freetype.c.FT_GLYPH_FORMAT_OUTLINE) {
            var bbox: freetype.c.FT_BBox = undefined;
            _ = freetype.c.FT_Outline_Get_BBox(&glyph.*.outline, &bbox);
            return .{
                .x = f26dot6ToF64(bbox.xMin),
                .y = f26dot6ToF64(bbox.yMin),
                .width = f26dot6ToF64(bbox.xMax - bbox.xMin),
                .height = f26dot6ToF64(bbox.yMax - bbox.yMin),
            };
        }
        return .{
            .x = f26dot6ToF64(glyph.*.metrics.horiBearingX),
            .y = f26dot6ToF64(glyph.*.metrics.horiBearingY - glyph.*.metrics.height),
            .width = f26dot6ToF64(glyph.*.metrics.width),
            .height = f26dot6ToF64(glyph.*.metrics.height),
        };
    }
    pub fn renderGlyph(
        self: Face,
        alloc: Allocator,
        atlas: *font.Atlas,
        glyph_index: u32,
        opts: font.Glyph.RenderOptions,
    ) !Glyph {
        self.ft_mutex.lockUncancelable(global.io());
        defer self.ft_mutex.unlock(global.io());
        try self.face.loadGlyph(glyph_index, self.glyphLoadFlags(opts.constraint.doesAnything()));
        const glyph = self.face.handle.*.glyph;
        if (self.synthetic.bold) {
            const font_height: f64 = @floatFromInt(self.face.handle.*.size.*.metrics.height);
            const ratio: f64 = 64.0 / 2048.0;
            const amount = @ceil(font_height * ratio);
            _ = freetype.c.FT_Outline_Embolden(&glyph.*.outline, @intFromFloat(amount));
        }
        const rect = getGlyphSize(glyph);
        if (rect.width < 0.25 or rect.height < 0.25)
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
                .width = rect.width,
                .height = rect.height,
                .x = rect.x,
                .y = rect.y + cell_baseline,
            },
            metrics,
            opts.constraint_width,
        );
        var width = glyph_size.width;
        var height = glyph_size.height;
        var x = glyph_size.x;
        var y = glyph_size.y;
        if ((constraint.size != .stretch) and (metrics.face_width < cell_width)) {
            x += @round((cell_width - metrics.face_width) / 2);
        }
        if (glyph.*.format == freetype.c.FT_GLYPH_FORMAT_BITMAP) {
            width = cell_width - @round(cell_width - width - x) - @round(x);
            height = cell_height - @round(cell_height - height - y) - @round(y);
            x = @round(x);
            y = @round(y);
        }
        var bitmap: freetype.c.FT_Bitmap = undefined;
        _ = freetype.c.FT_Bitmap_Init(&bitmap);
        defer _ = freetype.c.FT_Bitmap_Done(self.lib.lib.handle, &bitmap);
        switch (glyph.*.format) {
            freetype.c.FT_GLYPH_FORMAT_OUTLINE => {
                const scale_x = width / rect.width;
                const scale_y = height / rect.height;
                const skew: f64 =
                    if (self.synthetic.italic)
                        @tan(std.math.degreesToRadians(12))
                    else
                        0.0;
                const outline: *freetype.c.FT_Outline = &glyph.*.outline;
                for (outline.points[0..@intCast(outline.n_points)]) |*p| {
                    var px = f26dot6ToF64(p.x);
                    var py = f26dot6ToF64(p.y);
                    px -= rect.x;
                    py -= rect.y;
                    px *= scale_x;
                    py *= scale_y;
                    px += x;
                    py += y - cell_baseline;
                    px += py * skew;
                    p.x = @as(i32, @bitCast(F26Dot6.from(px)));
                    p.y = @as(i32, @bitCast(F26Dot6.from(py)));
                }
                try self.face.renderGlyph(
                    if (self.load_flags.monochrome)
                        .mono
                    else
                        .normal,
                );
                if (freetype.c.FT_Bitmap_Convert(
                    self.lib.lib.handle,
                    &glyph.*.bitmap,
                    &bitmap,
                    1,
                ) != 0) {
                    return error.BitmapHandlingError;
                }
            },
            freetype.c.FT_GLYPH_FORMAT_BITMAP => {
                switch (glyph.*.bitmap.pixel_mode) {
                    freetype.c.FT_PIXEL_MODE_BGRA,
                    freetype.c.FT_PIXEL_MODE_GRAY,
                    => {},
                    else => {
                        if (freetype.c.FT_GlyphSlot_Own_Bitmap(glyph) != 0) {
                            return error.BitmapHandlingError;
                        }
                        var converted: freetype.c.FT_Bitmap = undefined;
                        freetype.c.FT_Bitmap_Init(&converted);
                        if (freetype.c.FT_Bitmap_Convert(
                            self.lib.lib.handle,
                            &glyph.*.bitmap,
                            &converted,
                            1,
                        ) != 0) {
                            return error.BitmapHandlingError;
                        }
                        _ = freetype.c.FT_Bitmap_Done(
                            self.lib.lib.handle,
                            &glyph.*.bitmap,
                        );
                        glyph.*.bitmap = converted;
                    },
                }
                const glyph_bitmap = glyph.*.bitmap;
                const w: u32 = @intFromFloat(@round(width));
                const h: u32 = @intFromFloat(@round(height));
                const pitch = w * atlas.format.depth();
                const buf = try alloc.alloc(u8, pitch * h);
                defer alloc.free(buf);
                if (stb.stbir_resize_uint8(
                    glyph_bitmap.buffer,
                    @intCast(glyph_bitmap.width),
                    @intCast(glyph_bitmap.rows),
                    glyph_bitmap.pitch,
                    buf.ptr,
                    @intCast(w),
                    @intCast(h),
                    @intCast(pitch),
                    atlas.format.depth(),
                ) == 0) {
                    return error.GlyphResizeFailed;
                }
                const scaled_bitmap: freetype.c.FT_Bitmap = .{
                    .buffer = buf.ptr,
                    .width = @intCast(w),
                    .rows = @intCast(h),
                    .pitch = @intCast(pitch),
                    .pixel_mode = glyph_bitmap.pixel_mode,
                    .num_grays = glyph_bitmap.num_grays,
                };
                if (freetype.c.FT_Bitmap_Copy(
                    self.lib.lib.handle,
                    &scaled_bitmap,
                    &bitmap,
                ) != 0) {
                    return error.BitmapHandlingError;
                }
                glyph.*.bitmap_top = @intFromFloat(@floor(y - cell_baseline + height));
                glyph.*.bitmap_left = @intFromFloat(@floor(x));
            },
            else => |f| {
                const tag: u32 = @bitCast(f);
                log.err(
                    "Can't render glyph with unsupported glyph format \"{s}\"",
                    .{[4]u8{
                        @truncate(tag >> 24),
                        @truncate(tag >> 16),
                        @truncate(tag >> 8),
                        @truncate(tag >> 0),
                    }},
                );
                return error.UnsupportedGlyphFormat;
            },
        }
        switch (bitmap.pixel_mode) {
            freetype.c.FT_PIXEL_MODE_GRAY => if (atlas.format != .grayscale) {
                return error.WrongAtlas;
            },
            freetype.c.FT_PIXEL_MODE_BGRA => if (atlas.format != .bgra) {
                return error.WrongAtlas;
            },
            else => {
                log.warn("glyph={} pixel mode={}", .{ glyph_index, bitmap.pixel_mode });
                @panic("unsupported pixel mode");
            },
        }
        const px_x: i32 = glyph.*.bitmap_left;
        const px_y: i32 = glyph.*.bitmap_top +
            @as(i32, @intCast(metrics.cell_baseline)) -
            @as(i32, @intCast(bitmap.rows));
        const px_width = bitmap.width;
        const px_height = bitmap.rows;
        const len: usize = @intCast(
            @as(c_uint, @intCast(@abs(bitmap.pitch))) * bitmap.rows,
        );
        if (bitmap.pixel_mode == freetype.c.FT_PIXEL_MODE_GRAY and
            bitmap.num_grays < 256)
        {
            const factor: u8 = @intCast(255 / (bitmap.num_grays - 1));
            for (bitmap.buffer[0..len]) |*p| {
                p.* *= factor;
            }
            bitmap.num_grays = 256;
        }
        assert(px_width > 0 and px_height > 0);
        assert(px_width * atlas.format.depth() == bitmap.pitch);
        const region = try atlas.reserve(alloc, px_width, px_height);
        atlas.set(region, bitmap.buffer[0..len]);
        const offset_y: i32 = px_y + @as(i32, @intCast(px_height));
        const offset_x: i32 = px_x;
        return Glyph{
            .width = px_width,
            .height = px_height,
            .offset_x = offset_x,
            .offset_y = offset_y,
            .atlas_x = region.x,
            .atlas_y = region.y,
        };
    }
    fn unitsToPxY(self: Face, units: i32) i32 {
        return @intCast(freetype.mulFix(
            units,
            @intCast(self.face.handle.*.size.*.metrics.y_scale),
        ) >> 6);
    }
    fn f26dot6ToFloat(v: freetype.c.FT_F26Dot6) f32 {
        return @floatFromInt(v >> 6);
    }
    fn f26dot6ToF64(v: freetype.c.FT_F26Dot6) f64 {
        return @as(F26Dot6, @bitCast(@as(i32, @intCast(v)))).to(f64);
    }
    pub fn getMetrics(self: *Face) font.Metrics.FaceMetrics {
        const face = self.face;
        const size_metrics = face.handle.*.size.*.metrics;
        assert(size_metrics.x_ppem == size_metrics.y_ppem);
        const head_ = face.getSfntTable(.head);
        const post_ = face.getSfntTable(.post);
        const os2_: ?*freetype.c.TT_OS2 = os2: {
            const os2 = face.getSfntTable(.os2) orelse break :os2 null;
            if (os2.version == 0xFFFF) break :os2 null;
            break :os2 os2;
        };
        const hhea_ = face.getSfntTable(.hhea);
        const is_scalable = face.handle.*.face_flags & freetype.c.FT_FACE_FLAG_SCALABLE != 0;
        const units_per_em: freetype.c.FT_UShort =
            if (head_) |head|
                head.Units_Per_EM
            else if (is_scalable)
                face.handle.*.units_per_EM
            else
                size_metrics.y_ppem;
        const px_per_em: f64 = @floatFromInt(size_metrics.y_ppem);
        const px_per_unit = px_per_em / @as(f64, @floatFromInt(units_per_em));
        const ascent: f64, const descent: f64, const line_gap: f64 = vertical_metrics: {
            const hhea = hhea_ orelse {
                const ascender = f26dot6ToF64(size_metrics.ascender);
                const descender = f26dot6ToF64(size_metrics.descender);
                const height = f26dot6ToF64(size_metrics.height);
                break :vertical_metrics .{
                    ascender,
                    descender,
                    height + descender - ascender,
                };
            };
            const hhea_ascent: f64 = @floatFromInt(hhea.Ascender);
            const hhea_descent: f64 = @floatFromInt(hhea.Descender);
            const hhea_line_gap: f64 = @floatFromInt(hhea.Line_Gap);
            const os2 = os2_ orelse break :vertical_metrics .{
                hhea_ascent * px_per_unit,
                hhea_descent * px_per_unit,
                hhea_line_gap * px_per_unit,
            };
            const os2_ascent: f64 = @floatFromInt(os2.sTypoAscender);
            const os2_descent: f64 = @floatFromInt(os2.sTypoDescender);
            const os2_line_gap: f64 = @floatFromInt(os2.sTypoLineGap);
            if (os2.fsSelection & (1 << 7) != 0) {
                break :vertical_metrics .{
                    os2_ascent * px_per_unit,
                    os2_descent * px_per_unit,
                    os2_line_gap * px_per_unit,
                };
            }
            if (hhea.Ascender != 0 or hhea.Descender != 0) {
                break :vertical_metrics .{
                    hhea_ascent * px_per_unit,
                    hhea_descent * px_per_unit,
                    hhea_line_gap * px_per_unit,
                };
            }
            if (os2_ascent != 0 or os2_descent != 0) {
                break :vertical_metrics .{
                    os2_ascent * px_per_unit,
                    os2_descent * px_per_unit,
                    os2_line_gap * px_per_unit,
                };
            }
            const win_ascent: f64 = @floatFromInt(os2.usWinAscent);
            const win_descent: f64 = @floatFromInt(os2.usWinDescent);
            break :vertical_metrics .{
                win_ascent * px_per_unit,
                -win_descent * px_per_unit,
                0.0,
            };
        };
        const underline_position: ?f64, const underline_thickness: ?f64 = ul: {
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
        const cell_width: f64, const ascii_height: ?f64 = measurements: {
            self.ft_mutex.lockUncancelable(global.io());
            defer self.ft_mutex.unlock(global.io());
            var max: f64 = 0.0;
            var top: f64 = 0.0;
            var bottom: f64 = 0.0;
            var c: u8 = ' ';
            while (c < 127) : (c += 1) {
                if (face.getCharIndex(c)) |glyph_index| {
                    if (face.loadGlyph(glyph_index, self.glyphLoadFlags(false))) {
                        const glyph = face.handle.*.glyph;
                        max = @max(
                            f26dot6ToF64(glyph.*.advance.x),
                            max,
                        );
                        const rect = getGlyphSize(glyph);
                        top = @max(rect.y + rect.height, top);
                        bottom = @min(rect.y, bottom);
                    } else |_| {}
                }
            }
            if (max == 0.0) {
                max = f26dot6ToF64(size_metrics.max_advance);
            }
            const rect_height: ?f64 = rect_height: {
                const estimate = top - bottom;
                if (estimate <= 0.0) {
                    break :rect_height null;
                }
                break :rect_height estimate;
            };
            break :measurements .{ max, rect_height };
        };
        const cap_height: ?f64, const ex_height: ?f64 = heights: {
            if (os2_) |os2| {
                if (os2.version >= 2) {
                    break :heights .{
                        @as(f64, @floatFromInt(os2.sCapHeight)) * px_per_unit,
                        @as(f64, @floatFromInt(os2.sxHeight)) * px_per_unit,
                    };
                }
            }
            break :heights .{
                cap: {
                    self.ft_mutex.lockUncancelable(global.io());
                    defer self.ft_mutex.unlock(global.io());
                    if (face.getCharIndex('H')) |glyph_index| {
                        if (face.loadGlyph(glyph_index, self.glyphLoadFlags(false))) {
                            break :cap getGlyphSize(face.handle.*.glyph).height;
                        } else |_| {}
                    }
                    break :cap null;
                },
                ex: {
                    self.ft_mutex.lockUncancelable(global.io());
                    defer self.ft_mutex.unlock(global.io());
                    if (face.getCharIndex('x')) |glyph_index| {
                        if (face.loadGlyph(glyph_index, self.glyphLoadFlags(false))) {
                            break :ex getGlyphSize(face.handle.*.glyph).height;
                        } else |_| {}
                    }
                    break :ex null;
                },
            };
        };
        const ic_width: ?f64 = ic_width: {
            self.ft_mutex.lockUncancelable(global.io());
            defer self.ft_mutex.unlock(global.io());
            const glyph = face.getCharIndex('水') orelse break :ic_width null;
            face.loadGlyph(glyph, self.glyphLoadFlags(false)) catch break :ic_width null;
            const ft_glyph = face.handle.*.glyph;
            const ft_glyph_width = getGlyphSize(ft_glyph).width;
            const advance = f26dot6ToF64(ft_glyph.*.advance.x);
            if (ft_glyph_width > advance) {
                var buf: [1024]u8 = undefined;
                const font_name = self.name(&buf) catch "<Error getting font name>";
                log.warn(
                    "(getMetrics) Width of glyph '水' for font \"{s}\" is greater than its advance ({d} > {d}), discarding ic_width metric.",
                    .{ font_name, ft_glyph_width, advance },
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
    pub fn copyTable(self: Face, alloc: Allocator, tag: *const [4]u8) !?[]u8 {
        return try self.face.loadSfntTable(alloc, freetype.Tag.init(tag));
    }
};
test {
    const testFont = font.embedded.inconsolata;
    const alloc = testing.allocator;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);
    var ft_font = try Face.init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    );
    defer ft_font.deinit();
    var i: u8 = 32;
    while (i < 127) : (i += 1) {
        _ = try ft_font.renderGlyph(
            alloc,
            &atlas,
            ft_font.glyphIndex(i).?,
            .{ .grid_metrics = font.Metrics.calc(ft_font.getMetrics()) },
        );
    }
    {
        const g1 = try ft_font.renderGlyph(
            alloc,
            &atlas,
            ft_font.glyphIndex('A').?,
            .{ .grid_metrics = font.Metrics.calc(ft_font.getMetrics()) },
        );
        try testing.expectEqual(@as(u32, 11), g1.height);
        try ft_font.setSize(.{ .size = .{ .points = 24, .xdpi = 96, .ydpi = 96 } });
        const g2 = try ft_font.renderGlyph(
            alloc,
            &atlas,
            ft_font.glyphIndex('A').?,
            .{ .grid_metrics = font.Metrics.calc(ft_font.getMetrics()) },
        );
        try testing.expectEqual(@as(u32, 21), g2.height);
    }
}
test "color emoji" {
    const alloc = testing.allocator;
    const testFont = font.embedded.emoji;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var atlas = try font.Atlas.init(alloc, 512, .bgra);
    defer atlas.deinit(alloc);
    var ft_font = try Face.init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    );
    defer ft_font.deinit();
    _ = try ft_font.renderGlyph(
        alloc,
        &atlas,
        ft_font.glyphIndex('🥸').?,
        .{ .grid_metrics = font.Metrics.calc(ft_font.getMetrics()) },
    );
    {
        try testing.expect(ft_font.hasColor());
        const glyph_id = ft_font.glyphIndex('🥸').?;
        try testing.expect(ft_font.isColorGlyph(glyph_id));
    }
}
test "mono to bgra" {
    const alloc = testing.allocator;
    const testFont = font.embedded.emoji;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var atlas = try font.Atlas.init(alloc, 512, .bgra);
    defer atlas.deinit(alloc);
    var ft_font = try Face.init(lib, testFont, .{ .size = .{ .points = 12, .xdpi = 72, .ydpi = 72 } });
    defer ft_font.deinit();
    _ = try ft_font.renderGlyph(
        alloc,
        &atlas,
        3,
        .{ .grid_metrics = font.Metrics.calc(ft_font.getMetrics()) },
    );
}
test "svg font table" {
    const alloc = testing.allocator;
    const testFont = font.embedded.julia_mono;
    var lib = try font.Library.init(alloc);
    defer lib.deinit();
    var face = try Face.init(lib, testFont, .{ .size = .{ .points = 12, .xdpi = 72, .ydpi = 72 } });
    defer face.deinit();
    const table = (try face.copyTable(alloc, "SVG ")).?;
    defer alloc.free(table);
    try testing.expectEqual(430, table.len);
}
const terminus_i =
    \\........
    \\........
    \\...#....
    \\...#....
    \\........
    \\..##....
    \\...#....
    \\...#....
    \\...#....
    \\...#....
    \\...#....
    \\..###...
    \\........
    \\........
    \\........
    \\........
;
const terminus_i_pitch = 9;
test "bitmap glyph" {
    const alloc = testing.allocator;
    const testFont = font.embedded.terminus_ttf;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);
    var ft_font = try Face.init(lib, testFont, .{ .size = .{
        .points = 12,
        .xdpi = 96,
        .ydpi = 96,
    } });
    defer ft_font.deinit();
    const glyph = try ft_font.renderGlyph(
        alloc,
        &atlas,
        77,
        .{ .grid_metrics = font.Metrics.calc(ft_font.getMetrics()) },
    );
    try testing.expectEqual(8, glyph.width);
    try testing.expectEqual(16, glyph.height);
    for (0..glyph.height) |y| {
        for (0..glyph.width) |x| {
            const pixel = terminus_i[y * terminus_i_pitch + x];
            try testing.expectEqual(
                @as(u8, if (pixel == '#') 255 else 0),
                atlas.data[(glyph.atlas_y + y) * atlas.size + (glyph.atlas_x + x)],
            );
        }
    }
}
const spleen_A =
    \\........
    \\........
    \\.#####..
    \\##...##.
    \\##...##.
    \\##...##.
    \\#######.
    \\##...##.
    \\##...##.
    \\##...##.
    \\##...##.
    \\##...##.
    \\........
    \\........
    \\........
    \\........
;
const spleen_A_pitch = 9;
const spleen_test_point_size = 12;
const spleen_test_dpi = 96;
test "bitmap glyph BDF" {
    const alloc = testing.allocator;
    const testFont = font.embedded.spleen_bdf;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);
    var ft_font = try Face.init(lib, testFont, .{ .size = .{
        .points = spleen_test_point_size,
        .xdpi = spleen_test_dpi,
        .ydpi = spleen_test_dpi,
    } });
    defer ft_font.deinit();
    const glyph_index = ft_font.glyphIndex('A') orelse return error.GlyphNotFound;
    const glyph = try ft_font.renderGlyph(
        alloc,
        &atlas,
        glyph_index,
        .{ .grid_metrics = font.Metrics.calc(ft_font.getMetrics()) },
    );
    try testing.expectEqual(8, glyph.width);
    try testing.expectEqual(16, glyph.height);
    for (0..glyph.height) |y| {
        for (0..glyph.width) |x| {
            const pixel = spleen_A[y * spleen_A_pitch + x];
            try testing.expectEqual(
                @as(u8, if (pixel == '#') 255 else 0),
                atlas.data[(glyph.atlas_y + y) * atlas.size + (glyph.atlas_x + x)],
            );
        }
    }
}
test "bitmap glyph PCF" {
    const alloc = testing.allocator;
    const testFont = font.embedded.spleen_pcf;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);
    var ft_font = try Face.init(lib, testFont, .{ .size = .{
        .points = spleen_test_point_size,
        .xdpi = spleen_test_dpi,
        .ydpi = spleen_test_dpi,
    } });
    defer ft_font.deinit();
    const glyph_index = ft_font.glyphIndex('A') orelse return error.GlyphNotFound;
    const glyph = try ft_font.renderGlyph(
        alloc,
        &atlas,
        glyph_index,
        .{ .grid_metrics = font.Metrics.calc(ft_font.getMetrics()) },
    );
    try testing.expectEqual(8, glyph.width);
    try testing.expectEqual(16, glyph.height);
    for (0..glyph.height) |y| {
        for (0..glyph.width) |x| {
            const pixel = spleen_A[y * spleen_A_pitch + x];
            try testing.expectEqual(
                @as(u8, if (pixel == '#') 255 else 0),
                atlas.data[(glyph.atlas_y + y) * atlas.size + (glyph.atlas_x + x)],
            );
        }
    }
}
test "bitmap glyph OTB" {
    const alloc = testing.allocator;
    const testFont = font.embedded.spleen_otb;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);
    var ft_font = try Face.init(lib, testFont, .{ .size = .{
        .points = spleen_test_point_size,
        .xdpi = spleen_test_dpi,
        .ydpi = spleen_test_dpi,
    } });
    defer ft_font.deinit();
    const glyph_index = ft_font.glyphIndex('A') orelse return error.GlyphNotFound;
    const glyph = try ft_font.renderGlyph(
        alloc,
        &atlas,
        glyph_index,
        .{ .grid_metrics = font.Metrics.calc(ft_font.getMetrics()) },
    );
    try testing.expectEqual(8, glyph.width);
    try testing.expectEqual(16, glyph.height);
    for (0..glyph.height) |y| {
        for (0..glyph.width) |x| {
            const pixel = spleen_A[y * spleen_A_pitch + x];
            try testing.expectEqual(
                @as(u8, if (pixel == '#') 255 else 0),
                atlas.data[(glyph.atlas_y + y) * atlas.size + (glyph.atlas_x + x)],
            );
        }
    }
}
