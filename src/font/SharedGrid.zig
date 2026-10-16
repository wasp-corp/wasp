const SharedGrid = @This();
const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const tripwire = @import("../tripwire.zig");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const font = @import("main.zig");
const Atlas = font.Atlas;
const CodepointResolver = font.CodepointResolver;
const Collection = font.Collection;
const Face = font.Face;
const Glyph = font.Glyph;
const Library = font.Library;
const Metrics = font.Metrics;
const Presentation = font.Presentation;
const Style = font.Style;
const RenderOptions = font.Glyph.RenderOptions;
const global = @import("../global.zig");
const log = std.log.scoped(.font_shared_grid);
codepoints: std.HashMapUnmanaged(CodepointKey, ?Collection.Index, CodepointKey.Context, 80) = .{},
glyphs: std.HashMapUnmanaged(GlyphKey, Render, GlyphKey.Context, 80) = .{},
atlas_grayscale: Atlas,
atlas_color: Atlas,
resolver: CodepointResolver,
metrics: Metrics,
lock: std.Io.RwLock,
pub const init_tw = tripwire.module(enum {
    codepoints_capacity,
    glyphs_capacity,
    reload_metrics,
}, init);
pub const InitError = std.mem.Allocator.Error || Collection.UpdateMetricsError;
pub fn init(
    alloc: Allocator,
    resolver: CodepointResolver,
) InitError!SharedGrid {
    const tw = init_tw;
    assert(resolver.collection.load_options != null);
    var atlas_grayscale = try Atlas.init(alloc, 512, .grayscale);
    errdefer atlas_grayscale.deinit(alloc);
    var atlas_color = try Atlas.init(alloc, 512, .bgra);
    errdefer atlas_color.deinit(alloc);
    var result: SharedGrid = .{
        .resolver = resolver,
        .atlas_grayscale = atlas_grayscale,
        .atlas_color = atlas_color,
        .lock = .init,
        .metrics = undefined, 
    };
    try tw.check(.codepoints_capacity);
    try result.codepoints.ensureTotalCapacity(alloc, 128);
    errdefer result.codepoints.deinit(alloc);
    try tw.check(.glyphs_capacity);
    try result.glyphs.ensureTotalCapacity(alloc, 128);
    errdefer result.glyphs.deinit(alloc);
    try tw.check(.reload_metrics);
    try result.reloadMetrics();
    return result;
}
pub fn deinit(self: *SharedGrid, alloc: Allocator) void {
    self.codepoints.deinit(alloc);
    self.glyphs.deinit(alloc);
    self.atlas_grayscale.deinit(alloc);
    self.atlas_color.deinit(alloc);
    self.resolver.deinit(alloc);
}
fn reloadMetrics(self: *SharedGrid) !void {
    const collection = &self.resolver.collection;
    try collection.updateMetrics();
    self.metrics = collection.metrics.?;
    self.resolver.sprite = .{ .metrics = self.metrics };
}
pub fn cellSize(self: *SharedGrid) renderer.CellSize {
    return .{
        .width = self.metrics.cell_width,
        .height = self.metrics.cell_height,
    };
}
pub fn getIndex(
    self: *SharedGrid,
    alloc: Allocator,
    cp: u32,
    style: Style,
    p: ?Presentation,
) !?Collection.Index {
    const key = CodepointKey.from(.{ .style = style, .codepoint = cp, .presentation = p });
    {
        self.lock.lockSharedUncancelable(global.io());
        defer self.lock.unlockShared(global.io());
        if (self.codepoints.get(key)) |v| return v;
    }
    self.lock.lockUncancelable(global.io());
    defer self.lock.unlock(global.io());
    const gop = try self.codepoints.getOrPut(alloc, key);
    if (gop.found_existing) return gop.value_ptr.*;
    errdefer self.codepoints.removeByPtr(gop.key_ptr);
    const value = self.resolver.getIndex(alloc, cp, style, p);
    gop.value_ptr.* = value;
    if (value) |idx| preload: {
        if (idx.special() != null) break :preload;
        _ = try self.resolver.collection.getFace(idx);
    }
    return value;
}
pub fn hasCodepoint(
    self: *SharedGrid,
    idx: Collection.Index,
    cp: u32,
    p: ?Presentation,
) bool {
    self.lock.lockSharedUncancelable(global.io());
    defer self.lock.unlockShared(global.io());
    return self.resolver.collection.hasCodepoint(
        idx,
        cp,
        if (p) |v| .{ .explicit = v } else .{ .any = {} },
    );
}
pub const Render = struct {
    glyph: Glyph,
    presentation: Presentation,
};
pub fn renderCodepoint(
    self: *SharedGrid,
    alloc: Allocator,
    cp: u32,
    style: Style,
    p: ?Presentation,
    opts: RenderOptions,
) !?Render {
    const index = try self.getIndex(alloc, cp, style, p) orelse return null;
    const glyph_index = glyph_index: {
        self.lock.lockSharedUncancelable(global.io());
        defer self.lock.unlockShared(global.io());
        const face = try self.resolver.collection.getFace(index);
        break :glyph_index face.glyphIndex(cp) orelse return null;
    };
    return try self.renderGlyph(alloc, index, glyph_index, opts);
}
pub const renderGlyph_tw = tripwire.module(enum {
    get_presentation,
}, renderGlyph);
pub const RenderGlyphError = error{
    ArrayTooLarge,
    AtlasFull,
    BadArgument,
    BbxTooBig,
    BitmapHandlingError,
    CMapTableMissing,
    CannotOpenResource,
    CannotOpenStream,
    CannotRenderGlyph,
    CodeOverflow,
    CorruptedFontGlyphs,
    CorruptedFontHeader,
    CouldNotFindContext,
    DebugOpCode,
    DeferredLoadingUnavailable,
    DivideByZero,
    ENDFInExecStream,
    ExecutionTooLong,
    FontHasNoFile,
    FontPathCantDecode,
    FontconfigFailed,
    FontconfigNoId,
    FontconfigNoMatch,
    FontconfigTypeMismatch,
    GlyphResizeFailed,
    HarfbuzzFailed,
    HmtxTableMissing,
    HorizHeaderMissing,
    Ignore,
    IndexOutOfBounds,
    InvalidArgument,
    InvalidAtlasFormat,
    InvalidCacheHandle,
    InvalidCharMapFormat,
    InvalidCharMapHandle,
    InvalidCharacterCode,
    InvalidCodeRange,
    InvalidComposite,
    InvalidDriverHandle,
    InvalidFaceHandle,
    InvalidFileFormat,
    InvalidFrameOperation,
    InvalidFrameRead,
    InvalidGlyphFormat,
    InvalidGlyphIndex,
    InvalidHandle,
    InvalidHeight,
    InvalidHorizMetrics,
    InvalidLibraryHandle,
    InvalidMatrix,
    InvalidOffset,
    InvalidOpcode,
    InvalidOutline,
    InvalidPPem,
    InvalidPixelSize,
    InvalidPostTable,
    InvalidPostTableFormat,
    InvalidReference,
    InvalidSVGTable,
    InvalidSizeHandle,
    InvalidSlotHandle,
    InvalidState,
    InvalidStreamHandle,
    InvalidStreamOperation,
    InvalidStreamRead,
    InvalidStreamSeek,
    InvalidStreamSkip,
    InvalidTable,
    InvalidVersion,
    InvalidVertMetrics,
    InvalidWidth,
    LocationsMissing,
    LowerModuleVersion,
    MathError,
    MissingBbxField,
    MissingCharsField,
    MissingEncodingField,
    MissingFontField,
    MissingFontboundingboxField,
    MissingModule,
    MissingProperty,
    MissingSizeField,
    MissingStartcharField,
    MissingStartfontField,
    NameTableMissing,
    NestedDEFS,
    NestedFrameAccess,
    NoCurrentPoint,
    NoUnicodeGlyphName,
    OutOfMemory,
    PathNotClosed,
    PixelSourceNotPreMultiplied,
    PostTableMissing,
    RasterCorrupted,
    RasterNegativeHeight,
    RasterOverflow,
    RasterUninitialized,
    SpecialHasNoFace,
    StackOverflow,
    StackUnderflow,
    Syntax,
    TableMissing,
    TooFewArguments,
    TooManyCaches,
    TooManyDrivers,
    TooManyExtensions,
    TooManyFunctionDefs,
    TooManyHints,
    TooManyInstructionDefs,
    UnimplementedFeature,
    UnknownFileFormat,
    UnknownFreetypeError,
    UnlistedObject,
    UnsupportedGlyphFormat,
    WrongAtlas,
};
pub fn renderGlyph(
    self: *SharedGrid,
    alloc: Allocator,
    index: Collection.Index,
    glyph_index: u32,
    opts: RenderOptions,
) RenderGlyphError!Render {
    const tw = renderGlyph_tw;
    const key = GlyphKey.from(.{ .index = index, .glyph = glyph_index, .opts = opts });
    {
        self.lock.lockSharedUncancelable(global.io());
        defer self.lock.unlockShared(global.io());
        if (self.glyphs.get(key)) |v| return v;
    }
    self.lock.lockUncancelable(global.io());
    defer self.lock.unlock(global.io());
    const gop = try self.glyphs.getOrPut(alloc, key);
    if (gop.found_existing) return gop.value_ptr.*;
    errdefer self.glyphs.removeByPtr(gop.key_ptr);
    try tw.check(.get_presentation);
    const p = try self.resolver.getPresentation(index, glyph_index);
    const atlas: *font.Atlas = switch (p) {
        .text => &self.atlas_grayscale,
        .emoji => &self.atlas_color,
    };
    var render_opts = opts;
    if (p == .emoji) {
        render_opts.constraint = .{
            .size = .cover,
            .align_horizontal = .center,
            .align_vertical = .center,
            .pad_left = 0.025,
            .pad_right = 0.025,
        };
    }
    const glyph = self.resolver.renderGlyph(
        alloc,
        atlas,
        index,
        glyph_index,
        render_opts,
    ) catch |err| switch (err) {
        error.AtlasFull => blk: {
            try atlas.grow(alloc, atlas.size * 2);
            break :blk try self.resolver.renderGlyph(
                alloc,
                atlas,
                index,
                glyph_index,
                render_opts,
            );
        },
        else => return err,
    };
    gop.value_ptr.* = .{
        .glyph = glyph,
        .presentation = p,
    };
    return gop.value_ptr.*;
}
const CodepointKey = packed struct(u64) {
    codepoint: u32,
    style: Style,
    has_presentation: bool,
    presentation: Presentation,
    _padding: u27 = 0,
    const Context = struct {
        pub fn hash(_: Context, key: CodepointKey) u64 {
            const x: u64 = @bitCast(key);
            return x ^ (x >> 32);
        }
        pub fn eql(_: Context, a: CodepointKey, b: CodepointKey) bool {
            return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
        }
    };
    inline fn from(k: struct {
        style: Style,
        codepoint: u32,
        presentation: ?Presentation,
    }) CodepointKey {
        return .{
            .codepoint = k.codepoint,
            .style = k.style,
            .has_presentation = k.presentation != null,
            .presentation = k.presentation orelse .text,
        };
    }
};
const GlyphKey = packed struct(u64) {
    glyph: u32,
    index: Collection.Index,
    opts: packed struct(u16) {
        cell_width: u2,
        thicken: bool,
        thicken_strength: u8,
        constraint_width: u2,
        _padding: u3 = 0,
    },
    const Context = struct {
        pub fn hash(_: Context, key: GlyphKey) u64 {
            const x: u64 = @bitCast(key);
            return x ^ (x >> 32);
        }
        pub fn eql(_: Context, a: GlyphKey, b: GlyphKey) bool {
            return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
        }
    };
    inline fn from(k: struct {
        index: Collection.Index,
        glyph: u32,
        opts: RenderOptions,
    }) GlyphKey {
        return .{
            .glyph = k.glyph,
            .index = k.index,
            .opts = .{
                .cell_width = k.opts.cell_width orelse 0,
                .thicken = k.opts.thicken,
                .thicken_strength = k.opts.thicken_strength,
                .constraint_width = k.opts.constraint_width,
            },
        };
    }
};
const TestMode = enum { normal };
fn testGrid(mode: TestMode, alloc: Allocator, lib: Library) !SharedGrid {
    const testFont = font.embedded.regular;
    var c = Collection.init();
    c.load_options = .{ .library = lib };
    switch (mode) {
        .normal => {
            _ = try c.add(alloc, try .init(
                lib,
                testFont,
                .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
            ), .{
                .style = .regular,
                .fallback = false,
                .size_adjustment = .none,
            });
        },
    }
    var r: CodepointResolver = .{ .collection = c };
    errdefer r.deinit(alloc);
    return try init(alloc, r);
}
test getIndex {
    const testing = std.testing;
    const alloc = testing.allocator;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var grid = try testGrid(.normal, alloc, lib);
    defer grid.deinit(alloc);
    for (32..127) |i| {
        const idx = (try grid.getIndex(alloc, @intCast(i), .regular, null)).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(Collection.Index.IndexInt, 0), idx.idx);
        try testing.expect(grid.hasCodepoint(idx, @intCast(i), null));
    }
    const old_resolver = grid.resolver;
    grid.resolver = undefined;
    defer grid.resolver = old_resolver;
    for (32..127) |i| {
        const idx = (try grid.getIndex(alloc, @intCast(i), .regular, null)).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(Collection.Index.IndexInt, 0), idx.idx);
    }
}
test "renderGlyph error after cache insert rolls back cache entry" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var grid = try testGrid(.normal, alloc, lib);
    defer grid.deinit(alloc);
    const idx = (try grid.getIndex(alloc, 'A', .regular, null)).?;
    const glyph_index = glyph_index: {
        grid.lock.lockSharedUncancelable(testing.io);
        defer grid.lock.unlockShared(testing.io);
        const face = try grid.resolver.collection.getFace(idx);
        break :glyph_index face.glyphIndex('A').?;
    };
    const render_opts: RenderOptions = .{ .grid_metrics = grid.metrics };
    const key = GlyphKey.from(.{ .index = idx, .glyph = glyph_index, .opts = render_opts });
    try testing.expect(grid.glyphs.get(key) == null);
    const tw = renderGlyph_tw;
    defer tw.end(.reset) catch {};
    tw.errorAlways(.get_presentation, error.OutOfMemory);
    try testing.expectError(
        error.OutOfMemory,
        grid.renderGlyph(alloc, idx, glyph_index, render_opts),
    );
    try testing.expect(grid.glyphs.get(key) == null);
}
test "init error" {
    const testing = std.testing;
    const alloc = testing.allocator;
    for (std.meta.tags(init_tw.FailPoint)) |tag| {
        const tw = init_tw;
        defer tw.end(.reset) catch unreachable;
        tw.errorAlways(tag, error.OutOfMemory);
        var lib = try Library.init(alloc);
        defer lib.deinit();
        var c = Collection.init();
        c.load_options = .{ .library = lib };
        _ = try c.add(alloc, try .init(
            lib,
            font.embedded.regular,
            .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
        ), .{
            .style = .regular,
            .fallback = false,
            .size_adjustment = .none,
        });
        var resolver: CodepointResolver = .{ .collection = c };
        defer resolver.deinit(alloc); 
        try testing.expectError(
            error.OutOfMemory,
            init(alloc, resolver),
        );
    }
}
