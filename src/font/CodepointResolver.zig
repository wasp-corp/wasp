const CodepointResolver = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const uucode = @import("uucode");
const font = @import("main.zig");
const Atlas = font.Atlas;
const CodepointMap = font.CodepointMap;
const Collection = font.Collection;
const Discover = font.Discover;
const DiscoveryDescriptor = font.discovery.Descriptor;
const Face = font.Face;
const Glyph = font.Glyph;
const Library = font.Library;
const Presentation = font.Presentation;
const RenderOptions = font.Glyph.RenderOptions;
const SpriteFace = font.SpriteFace;
const Style = font.Style;
const log = std.log.scoped(.font_codepoint_resolver);
collection: Collection,
styles: StyleStatus = .initFill(true),
discover: ?*Discover = null,
codepoint_map: ?CodepointMap = null,
descriptor_cache: DescriptorCache = .{},
sprite: ?SpriteFace = null,
pub fn deinit(self: *CodepointResolver, alloc: Allocator) void {
    self.collection.deinit(alloc);
    self.descriptor_cache.deinit(alloc);
}
pub fn getIndex(
    self: *CodepointResolver,
    alloc: Allocator,
    cp: u32,
    style: Style,
    p: ?Presentation,
) ?Collection.Index {
    if (style != .regular and !self.styles.get(style)) {
        return self.getIndex(alloc, cp, .regular, p);
    }
    if (self.getIndexCodepointOverride(alloc, cp)) |idx_| {
        if (idx_) |idx| return idx;
    } else |err| {
        log.warn("codepoint override failed codepoint={} err={}", .{ cp, err });
    }
    if (self.sprite) |sprite| {
        if (sprite.hasCodepoint(cp, p)) {
            return .initSpecial(.sprite);
        }
    }
    const p_mode: Collection.PresentationMode = if (p) |v| .{ .explicit = v } else .{
        .default = if (uucode.get(.is_emoji_presentation, @intCast(cp)))
            .emoji
        else
            .text,
    };
    if (self.collection.getIndex(cp, style, p_mode)) |value| return value;
    if (style != .regular) {
        if (self.getIndex(alloc, cp, .regular, p)) |value| return value;
    }
    if (style == .regular and font.Discover != void) {
        log.debug("searching for a fallback font for cp={X}", .{cp});
        if (self.discover) |disco| discover: {
            const load_opts = self.collection.load_options orelse
                break :discover;
            var disco_it = disco.discoverFallback(alloc, &self.collection, .{
                .codepoint = cp,
                .size = load_opts.size.points,
                .bold = style == .bold or style == .bold_italic,
                .italic = style == .italic or style == .bold_italic,
                .monospace = false,
            }) catch break :discover;
            defer disco_it.deinit();
            while (true) {
                var deferred_face = (disco_it.next() catch |err| {
                    log.warn("fallback search failed with error err={}", .{err});
                    break;
                }) orelse break;
                const face: Collection.Entry = .{
                    .face = .{ .deferred = deferred_face },
                    .fallback = true,
                };
                if (!face.hasCodepoint(cp, p_mode)) {
                    deferred_face.deinit();
                    continue;
                }
                var buf: [256]u8 = undefined;
                log.info("found codepoint 0x{X} in fallback face={s}", .{
                    cp,
                    deferred_face.name(&buf) catch "<error>",
                });
                return self.collection.addDeferred(alloc, deferred_face, .{
                    .style = style,
                    .fallback = true,
                    .size_adjustment = font.default_fallback_adjustment,
                }) catch {
                    deferred_face.deinit();
                    break :discover;
                };
            }
            log.debug("no fallback face found for cp={X}", .{cp});
        }
    }
    if (style == .regular and p_mode == .any) return null;
    return self.collection.getIndex(cp, .regular, .{ .any = {} });
}
fn getIndexCodepointOverride(
    self: *CodepointResolver,
    alloc: Allocator,
    cp: u32,
) !?Collection.Index {
    if (comptime font.Discover == void) return null;
    const map = self.codepoint_map orelse return null;
    const cp_u21 = std.math.cast(u21, cp) orelse return null;
    const desc = map.get(cp_u21) orelse return null;
    const idx_: ?Collection.Index = self.descriptor_cache.get(desc) orelse idx: {
        const discover = self.discover orelse return null;
        var disco_it = try discover.discover(alloc, desc);
        defer disco_it.deinit();
        const face = (try disco_it.next()) orelse {
            log.warn(
                "font lookup for codepoint map failed codepoint={} err=FontNotFound",
                .{cp},
            );
            try self.descriptor_cache.put(alloc, desc, null);
            return null;
        };
        const idx = try self.collection.addDeferred(alloc, face, .{
            .style = .regular,
            .fallback = false,
            .size_adjustment = font.default_fallback_adjustment,
        });
        try self.descriptor_cache.put(alloc, desc, idx);
        break :idx idx;
    };
    const idx = idx_ orelse return null;
    if (self.collection.hasCodepoint(idx, cp, .{ .any = {} })) {
        log.debug("codepoint override based on config codepoint={} family={s}", .{
            cp,
            desc.family orelse "",
        });
        return idx;
    }
    return null;
}
pub fn getPresentation(
    self: *CodepointResolver,
    index: Collection.Index,
    glyph_index: u32,
) !Presentation {
    if (index.special()) |sp| return switch (sp) {
        .sprite => .text,
    };
    const face = try self.collection.getFace(index);
    return if (face.isColorGlyph(glyph_index)) .emoji else .text;
}
pub fn renderGlyph(
    self: *CodepointResolver,
    alloc: Allocator,
    atlas: *Atlas,
    index: Collection.Index,
    glyph_index: u32,
    opts: RenderOptions,
) !Glyph {
    if (index.special()) |sp| switch (sp) {
        .sprite => return try self.sprite.?.renderGlyph(
            alloc,
            atlas,
            glyph_index,
            opts,
        ),
    };
    const face = try self.collection.getFace(index);
    const glyph = try face.renderGlyph(alloc, atlas, glyph_index, opts);
    return glyph;
}
pub const StyleStatus = std.EnumArray(Style, bool);
const DescriptorCache = std.HashMapUnmanaged(
    DiscoveryDescriptor,
    ?Collection.Index,
    struct {
        const KeyType = DiscoveryDescriptor;
        pub fn hash(ctx: @This(), k: KeyType) u64 {
            _ = ctx;
            return k.hashcode();
        }
        pub fn eql(ctx: @This(), a: KeyType, b: KeyType) bool {
            return ctx.hash(a) == ctx.hash(b);
        }
    },
    std.hash_map.default_max_load_percentage,
);
test getIndex {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;
    const testEmoji = font.embedded.emoji;
    const testEmojiText = font.embedded.emoji_text;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var c = Collection.init();
    c.load_options = .{ .library = lib };
    {
        errdefer c.deinit(alloc);
        _ = try c.add(alloc, try .init(
            lib,
            testFont,
            .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
        ), .{
            .style = .regular,
            .fallback = false,
            .size_adjustment = .none,
        });
        if (comptime !font.options.backend.hasCoretext()) {
            _ = try c.add(alloc, try .init(
                lib,
                testEmoji,
                .{ .size = .{ .points = 12 } },
            ), .{
                .style = .regular,
                .fallback = false,
                .size_adjustment = .none,
            });
        }
        _ = try c.add(alloc, try .init(
            lib,
            testEmojiText,
            .{ .size = .{ .points = 12 } },
        ), .{
            .style = .regular,
            .fallback = false,
            .size_adjustment = .none,
        });
    }
    var r: CodepointResolver = .{ .collection = c };
    defer r.deinit(alloc);
    var i: u32 = 32;
    while (i < 127) : (i += 1) {
        const idx = r.getIndex(alloc, i, .regular, null).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(Collection.Index.IndexInt, 0), idx.idx);
    }
    {
        const idx = r.getIndex(alloc, '🥸', .regular, null).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(Collection.Index.IndexInt, 1), idx.idx);
    }
    {
        const idx = r.getIndex(alloc, 0x270C, .regular, .text).?;
        try testing.expectEqual(Style.regular, idx.style);
        const text_idx = if (comptime font.options.backend.hasCoretext()) 1 else 2;
        try testing.expectEqual(@as(Collection.Index.IndexInt, text_idx), idx.idx);
    }
    {
        const idx = r.getIndex(alloc, 0x270C, .regular, .emoji).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(Collection.Index.IndexInt, 1), idx.idx);
    }
    {
        try testing.expect(r.getIndex(alloc, 0x1FB00, .regular, null) == null);
    }
}
test "getIndex disabled font style" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;
    var atlas_grayscale = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas_grayscale.deinit(alloc);
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var c = Collection.init();
    c.load_options = .{ .library = lib };
    _ = try c.add(alloc, try .init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .none,
    });
    _ = try c.add(alloc, try .init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ), .{
        .style = .bold,
        .fallback = false,
        .size_adjustment = .none,
    });
    _ = try c.add(alloc, try .init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ), .{
        .style = .italic,
        .fallback = false,
        .size_adjustment = .none,
    });
    var r: CodepointResolver = .{ .collection = c };
    defer r.deinit(alloc);
    r.styles.set(.bold, false); 
    {
        const idx = r.getIndex(alloc, 'A', .regular, null).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(Collection.Index.IndexInt, 0), idx.idx);
    }
    {
        const idx = r.getIndex(alloc, 'A', .bold, null).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(Collection.Index.IndexInt, 0), idx.idx);
    }
    {
        const idx = r.getIndex(alloc, 'A', .italic, null).?;
        try testing.expectEqual(Style.italic, idx.style);
        try testing.expectEqual(@as(Collection.Index.IndexInt, 0), idx.idx);
    }
}
test "getIndex box glyph" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    const c = Collection.init();
    var r: CodepointResolver = .{
        .collection = c,
        .sprite = .{
            .metrics = font.Metrics.calc(.{
                .px_per_em = 30.0,
                .cell_width = 18.0,
                .ascent = 30.0,
                .descent = -6.0,
                .line_gap = 0.0,
            }),
        },
    };
    defer r.deinit(alloc);
    const idx = r.getIndex(alloc, 0x2500, .regular, null).?;
    try testing.expectEqual(Style.regular, idx.style);
    try testing.expectEqual(@intFromEnum(Collection.Index.Special.sprite), idx.idx);
}
