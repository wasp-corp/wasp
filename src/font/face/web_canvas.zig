const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const js = @import("zig-js");
const font = @import("../main.zig");
const log = std.log.scoped(.font_face);
pub const Face = struct {
    const grapheme_start: u32 = 0x10FFFF + 1;
    const grapheme_end: u32 = std.math.maxInt(u32);
    alloc: Allocator,
    font_str: []const u8,
    size: font.face.DesiredSize,
    presentation: font.Presentation,
    metrics: font.Metrics,
    canvas: js.Object,
    grapheme_to_glyph: std.StringHashMapUnmanaged(u32) = .{},
    glyph_to_grapheme: std.AutoHashMapUnmanaged(u32, []u8) = .{},
    grapheme_next: u32 = grapheme_start,
    pub fn initNamed(
        alloc: Allocator,
        raw: []const u8,
        size: font.face.DesiredSize,
        presentation: font.Presentation,
    ) !Face {
        const font_str = try alloc.dupe(u8, raw);
        errdefer alloc.free(font_str);
        const doc = try js.global.get(js.Object, "document");
        defer doc.deinit();
        const canvas = try doc.call(js.Object, "createElement", .{js.string("canvas")});
        errdefer canvas.deinit();
        var result = Face{
            .alloc = alloc,
            .font_str = font_str,
            .size = size,
            .presentation = presentation,
            .canvas = canvas,
            .metrics = undefined,
        };
        try result.calcMetrics();
        log.debug("face initialized: {s}", .{raw});
        return result;
    }
    pub fn deinit(self: *Face) void {
        self.alloc.free(self.font_str);
        self.grapheme_to_glyph.deinit(self.alloc);
        {
            var it = self.glyph_to_grapheme.valueIterator();
            while (it.next()) |value| self.alloc.free(value.*);
            self.glyph_to_grapheme.deinit(self.alloc);
        }
        self.canvas.deinit();
        self.* = undefined;
    }
    pub fn setSize(self: *Face, size: font.face.DesiredSize) !void {
        const old = self.size;
        self.size = size;
        errdefer self.size = old;
        try self.calcMetrics();
    }
    pub fn glyphIndex(self: Face, cp: u32) ?u32 {
        if (cp >= grapheme_start) {
            if (!self.glyph_to_grapheme.contains(cp)) return null;
        }
        const p: font.Presentation = if (cp <= 255) .text else p: {
            break :p self.glyphPresentation(cp) catch {
                return null;
            };
        };
        if (p != self.presentation) return null;
        return cp;
    }
    fn glyphPresentation(
        self: Face,
        cp: u32,
    ) !font.Presentation {
        var render = try self.renderGlyphInternal(self.alloc, cp);
        defer render.deinit();
        var i: usize = 0;
        while (i < render.bitmap.len) : (i += 4) {
            if (render.bitmap[i] > 0 or
                render.bitmap[i + 1] > 0 or
                render.bitmap[i + 2] > 0) return .emoji;
        }
        return .text;
    }
    pub fn graphemeGlyphIndex(self: *Face, cluster: []const u8) error{OutOfMemory}!u32 {
        const gop = try self.grapheme_to_glyph.getOrPut(self.alloc, cluster);
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer _ = self.grapheme_to_glyph.remove(cluster);
        if (self.grapheme_next == 0) return error.OutOfMemory;
        const copy = try self.alloc.dupe(u8, cluster);
        errdefer self.alloc.free(copy);
        try self.glyph_to_grapheme.ensureUnusedCapacity(self.alloc, 1);
        gop.value_ptr.* = self.grapheme_next;
        self.glyph_to_grapheme.putAssumeCapacity(self.grapheme_next, copy);
        self.grapheme_next +%= 1;
        return gop.value_ptr.*;
    }
    pub fn renderGlyph(
        self: Face,
        alloc: Allocator,
        atlas: *font.Atlas,
        glyph_index: u32,
        opts: font.Glyph.RenderOptions,
    ) !font.Glyph {
        _ = opts;
        var render = try self.renderGlyphInternal(alloc, glyph_index);
        defer render.deinit();
        const bitmap_formatted: []u8 = switch (atlas.format) {
            .rgba => render.bitmap,
            .grayscale => a8: {
                assert(@mod(render.bitmap.len, 4) == 0);
                var bitmap_a8 = try alloc.alloc(u8, render.bitmap.len / 4);
                errdefer alloc.free(bitmap_a8);
                var i: usize = 0;
                while (i < bitmap_a8.len) : (i += 1) {
                    bitmap_a8[i] = render.bitmap[(i * 4) + 3];
                }
                break :a8 bitmap_a8;
            },
            else => return error.UnsupportedAtlasFormat,
        };
        defer if (bitmap_formatted.ptr != render.bitmap.ptr) {
            alloc.free(bitmap_formatted);
        };
        const region = try atlas.reserve(alloc, render.width, render.height);
        if (region.width > 0 and region.height > 0) {
            atlas.set(region, bitmap_formatted);
        }
        return font.Glyph{
            .width = render.width,
            .height = render.height,
            .offset_x = 0,
            .offset_y = 0,
            .atlas_x = region.x,
            .atlas_y = region.y,
        };
    }
    fn calcMetrics(self: *Face) !void {
        const ctx = try self.context();
        defer ctx.deinit();
        const cell_width: f32 = cell_width: {
            const metrics = try ctx.call(js.Object, "measureText", .{js.string("M")});
            defer metrics.deinit();
            const bounding_right = try metrics.get(f32, "actualBoundingBoxRight");
            if (bounding_right > 0) break :cell_width bounding_right;
            break :cell_width try metrics.get(f32, "width");
        };
        const height_metrics = try ctx.call(js.Object, "measureText", .{js.string("M_")});
        defer height_metrics.deinit();
        const asc = try height_metrics.get(f32, "actualBoundingBoxAscent");
        const desc = try height_metrics.get(f32, "actualBoundingBoxDescent");
        const cell_height = asc + desc;
        const cell_baseline = desc;
        const underline_position = cell_height - 1;
        const underline_thickness: f32 = 1;
        const result = font.Metrics{
            .cell_width = @intFromFloat(cell_width),
            .cell_height = @intFromFloat(cell_height),
            .cell_baseline = @intFromFloat(cell_baseline),
            .underline_position = @intFromFloat(underline_position),
            .underline_thickness = @intFromFloat(underline_thickness),
            .strikethrough_position = @intFromFloat(underline_position),
            .strikethrough_thickness = @intFromFloat(underline_thickness),
        };
        self.metrics = result;
        log.debug("metrics font={s} value={}", .{ self.font_str, self.metrics });
    }
    fn context(self: Face) !js.Object {
        const ctx = try self.canvas.call(js.Object, "getContext", .{js.string("2d")});
        errdefer ctx.deinit();
        {
            const width = try self.canvas.get(f64, "width");
            const height = try self.canvas.get(f64, "height");
            try ctx.call(void, "clearRect", .{ 0, 0, width, height });
        }
        const font_val = try std.fmt.allocPrint(
            self.alloc,
            "{d}px {s}",
            .{ self.size.points, self.font_str },
        );
        defer self.alloc.free(font_val);
        try ctx.set("font", js.string(font_val));
        const check = try ctx.getAlloc(js.String, self.alloc, "font");
        defer self.alloc.free(check);
        if (!std.mem.eql(u8, font_val, check)) {
            log.warn("canvas font didn't set, fonts may be broken, expected={s} got={s}", .{
                font_val,
                check,
            });
        }
        return ctx;
    }
    const RenderedGlyph = struct {
        alloc: Allocator,
        metrics: js.Object,
        width: u32,
        height: u32,
        bitmap: []u8,
        pub fn deinit(self: *RenderedGlyph) void {
            self.metrics.deinit();
            self.alloc.free(self.bitmap);
            self.* = undefined;
        }
    };
    fn renderGlyphInternal(
        self: Face,
        alloc: Allocator,
        glyph_index: u32,
    ) !RenderedGlyph {
        var utf8: [4]u8 = undefined;
        const glyph_str = glyph_str: {
            if (glyph_index < grapheme_start) {
                const utf8_len = try std.unicode.utf8Encode(@intCast(glyph_index), &utf8);
                break :glyph_str js.string(utf8[0..utf8_len]);
            }
            const slice = self.glyph_to_grapheme.get(glyph_index) orelse
                return error.UnknownGraphemeCluster;
            break :glyph_str js.string(slice);
        };
        const measure_ctx = try self.context();
        defer measure_ctx.deinit();
        const metrics = try measure_ctx.call(js.Object, "measureText", .{glyph_str});
        errdefer metrics.deinit();
        const width: u32 = @as(u32, @intFromFloat(@ceil(width: {
            const bounding_right = try metrics.get(f32, "actualBoundingBoxRight");
            if (bounding_right > 0) break :width bounding_right;
            break :width try metrics.get(f32, "width");
        }))) + 1;
        const left = try metrics.get(f32, "actualBoundingBoxLeft");
        const asc = try metrics.get(f32, "actualBoundingBoxAscent");
        const desc = try metrics.get(f32, "actualBoundingBoxDescent");
        const broken_bbox = asc + desc < 0.001;
        const height = if (!broken_bbox) @as(u32, @intFromFloat(@ceil(asc + desc))) + 1 else width;
        {
            try self.canvas.set("width", width);
            try self.canvas.set("height", height);
            const width_str = try std.fmt.allocPrint(alloc, "{d}px", .{width});
            defer alloc.free(width_str);
            const height_str = try std.fmt.allocPrint(alloc, "{d}px", .{height});
            defer alloc.free(height_str);
            const style = try self.canvas.get(js.Object, "style");
            defer style.deinit();
            try style.set("width", js.string(width_str));
            try style.set("height", js.string(height_str));
        }
        const ctx = try self.context();
        defer ctx.deinit();
        if (broken_bbox) {
            try ctx.set("textBaseline", js.string("ideographic"));
        }
        try ctx.set("fillStyle", js.string("transparent"));
        try ctx.call(void, "fillRect", .{
            0,
            0,
            width,
            height,
        });
        try ctx.set("fillStyle", js.string("black"));
        try ctx.call(void, "fillText", .{
            glyph_str,
            left + 1,
            if (!broken_bbox) asc + 1 else @as(f32, @floatFromInt(height)),
        });
        const bitmap: []u8 = bitmap: {
            const data = try ctx.call(js.Object, "getImageData", .{ 0, 0, width, height });
            defer data.deinit();
            const src_array = try data.get(js.Object, "data");
            defer src_array.deinit();
            const len = try src_array.get(u32, "length");
            const bitmap = try alloc.alloc(u8, @intCast(len));
            errdefer alloc.free(bitmap);
            const mem_array = mem_array: {
                const mem = try js.runtime.get(js.Object, "memory");
                defer mem.deinit();
                const buf = try mem.get(js.Object, "buffer");
                defer buf.deinit();
                const Uint8Array = try js.global.get(js.Object, "Uint8Array");
                defer Uint8Array.deinit();
                const mem_array = try Uint8Array.new(.{ buf, bitmap.ptr });
                errdefer mem_array.deinit();
                break :mem_array mem_array;
            };
            defer mem_array.deinit();
            try mem_array.call(void, "set", .{src_array});
            break :bitmap bitmap;
        };
        errdefer alloc.free(bitmap);
        return RenderedGlyph{
            .alloc = alloc,
            .metrics = metrics,
            .width = width,
            .height = height,
            .bitmap = bitmap,
        };
    }
};
pub const Wasm = struct {
    const wasm = @import("../../os/wasm.zig");
    const alloc = wasm.alloc;
    export fn face_new(ptr: [*]const u8, len: usize, pts: u16, p: u16) ?*Face {
        return face_new_(ptr, len, pts, p) catch null;
    }
    fn face_new_(ptr: [*]const u8, len: usize, pts: f32, presentation: u16) !*Face {
        var face = try Face.initNamed(
            alloc,
            ptr[0..len],
            .{ .points = pts },
            @enumFromInt(presentation),
        );
        errdefer face.deinit();
        const result = try alloc.create(Face);
        errdefer alloc.destroy(result);
        result.* = face;
        return result;
    }
    export fn face_free(ptr: ?*Face) void {
        if (ptr) |v| {
            v.deinit();
            alloc.destroy(v);
        }
    }
    export fn face_render_glyph(
        face: *Face,
        atlas: *font.Atlas,
        codepoint: u32,
    ) ?*font.Glyph {
        return face_render_glyph_(face, atlas, codepoint) catch |err| {
            log.warn("error rendering glyph err={}", .{err});
            return null;
        };
    }
    export fn face_debug_canvas(face: *Face) void {
        face_debug_canvas_(face) catch |err| {
            log.warn("error adding debug canvas err={}", .{err});
        };
    }
    fn face_debug_canvas_(face: *Face) !void {
        const doc = try js.global.get(js.Object, "document");
        defer doc.deinit();
        const elem = try doc.call(
            ?js.Object,
            "getElementById",
            .{js.string("face-canvas")},
        ) orelse return error.CanvasContainerNotFound;
        defer elem.deinit();
        try elem.call(void, "append", .{face.canvas});
    }
    fn face_render_glyph_(face: *Face, atlas: *font.Atlas, codepoint: u32) !*font.Glyph {
        const glyph = try face.renderGlyph(alloc, atlas, codepoint, .{});
        const result = try alloc.create(font.Glyph);
        errdefer alloc.destroy(result);
        _ = try wasm.toHostOwned(result);
        result.* = glyph;
        return result;
    }
};
