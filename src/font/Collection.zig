const Collection = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("../config.zig");
const comparison = @import("../datastruct/comparison.zig");
const font = @import("main.zig");
const options = font.options;
const DeferredFace = font.DeferredFace;
const DesiredSize = font.face.DesiredSize;
const Face = font.Face;
const Library = font.Library;
const Metrics = font.Metrics;
const Presentation = font.Presentation;
const Style = font.Style;
const SegmentedList = @import("../datastruct/segmented_list.zig").SegmentedList;
const log = std.log.scoped(.font_collection);
faces: StyleArray,
metric_modifiers: Metrics.ModifierSet = .{},
metrics: ?Metrics = null,
primary_face_metrics: ?Metrics.FaceMetrics = null,
load_options: ?LoadOptions = null,
pub fn init() Collection {
    return .{ .faces = .initFill(.{}) };
}
pub fn deinit(self: *Collection, alloc: Allocator) void {
    var it = self.faces.iterator();
    while (it.next()) |array| {
        var entry_it = array.value.iterator(0);
        while (entry_it.next()) |entry_or_alias|
            switch (entry_or_alias.*) {
                .entry => |*entry| entry.deinit(),
                .alias => {},
            };
        array.value.deinit(alloc);
    }
    if (self.load_options) |*v| v.deinit(alloc);
}
pub const AddOptions = struct {
    style: Style,
    size_adjustment: SizeAdjustment,
    fallback: bool,
};
pub const AddError =
    Allocator.Error ||
    error{
        CollectionFull,
        SetSizeFailed,
    };
pub fn add(
    self: *Collection,
    alloc: Allocator,
    face: Face,
    opts: AddOptions,
) AddError!Index {
    const list = self.faces.getPtr(opts.style);
    const idx = list.count();
    if (idx >= Index.Special.start - 1)
        return error.CollectionFull;
    var owned_face = face;
    const scale_factor = self.scaleFactor(
        owned_face.getMetrics(),
        opts.size_adjustment,
    );
    if (self.load_options) |load_opts| {
        var new_opts = load_opts;
        new_opts.size.points *= @floatCast(scale_factor);
        owned_face.setSize(new_opts.faceOptions()) catch return error.SetSizeFailed;
    }
    try list.append(alloc, .{
        .entry = .{
            .face = .{ .loaded = owned_face },
            .fallback = opts.fallback,
            .scale_factor = .{ .scale = scale_factor },
        },
    });
    return .{ .style = opts.style, .idx = @intCast(idx) };
}
pub const AddDeferredError =
    Allocator.Error ||
    error{
        CollectionFull,
        DeferredLoadingUnavailable,
    };
pub fn addDeferred(
    self: *Collection,
    alloc: Allocator,
    face: DeferredFace,
    opts: AddOptions,
) AddDeferredError!Index {
    const list = self.faces.getPtr(opts.style);
    if (self.load_options == null) return error.DeferredLoadingUnavailable;
    const idx = list.count();
    if (idx >= Index.Special.start - 1)
        return error.CollectionFull;
    try list.append(alloc, .{
        .entry = .{
            .face = .{ .deferred = face },
            .fallback = opts.fallback,
            .scale_factor = .{ .adjustment = opts.size_adjustment },
        },
    });
    return .{ .style = opts.style, .idx = @intCast(idx) };
}
pub fn getFace(self: *Collection, index: Index) !*Face {
    return try self.getFaceFromEntry(try self.getEntry(index));
}
pub const EntryError = error{
    SpecialHasNoFace,
    IndexOutOfBounds,
};
pub fn getEntry(self: *Collection, index: Index) EntryError!*Entry {
    if (index.special() != null) return error.SpecialHasNoFace;
    const list = self.faces.getPtr(index.style);
    if (index.idx >= list.len) return error.IndexOutOfBounds;
    return list.at(index.idx).getEntry();
}
fn getFaceFromEntry(
    self: *Collection,
    entry: *Entry,
) !*Face {
    return switch (entry.face) {
        .deferred => |*d| deferred: {
            var opts = self.load_options orelse
                return error.DeferredLoadingUnavailable;
            var face = try d.load(opts.library, opts.faceOptions());
            errdefer face.deinit();
            if (entry.scale_factor == .adjustment) {
                const factor = self.scaleFactor(
                    face.getMetrics(),
                    entry.scale_factor.adjustment,
                );
                entry.scale_factor = .{ .scale = factor };
            }
            if (entry.scale_factor.scale != 1.0) {
                opts.size.points *= @floatCast(entry.scale_factor.scale);
                try face.setSize(opts.faceOptions());
            }
            errdefer comptime unreachable;
            d.deinit();
            entry.face = .{ .loaded = face };
            break :deferred &entry.face.loaded;
        },
        .loaded => |*f| f,
    };
}
pub fn getIndex(
    self: *const Collection,
    cp: u32,
    style: Style,
    p_mode: PresentationMode,
) ?Index {
    var i: usize = 0;
    var it = self.faces.get(style).constIterator(0);
    while (it.next()) |entry_or_alias| {
        if (entry_or_alias.getConstEntry().hasCodepoint(cp, p_mode)) {
            return .{
                .style = style,
                .idx = @intCast(i),
            };
        }
        i += 1;
    }
    return null;
}
pub fn hasCodepoint(
    self: *const Collection,
    index: Index,
    cp: u32,
    p_mode: PresentationMode,
) bool {
    const list = self.faces.get(index.style);
    if (index.idx >= list.count()) return false;
    return list.at(index.idx).getConstEntry().hasCodepoint(cp, p_mode);
}
pub const CompleteError = Allocator.Error || error{
    DefaultUnavailable,
};
pub fn completeStyles(
    self: *Collection,
    alloc: Allocator,
    synthetic_config: config.FontSyntheticStyle,
) CompleteError!void {
    empty: {
        var it = self.faces.iterator();
        while (it.next()) |entry| {
            if (entry.value.count() == 0) break :empty;
        }
        return;
    }
    const regular_entry: *Entry = entry: {
        const list = self.faces.getPtr(.regular);
        if (list.count() == 0) return;
        var it = list.iterator(0);
        while (it.next()) |entry_or_alias| {
            const entry = entry_or_alias.getEntry();
            const face = self.getFaceFromEntry(entry) catch |err| {
                log.warn("error loading regular entry={d} err={}", .{
                    it.index - 1,
                    err,
                });
                continue;
            };
            if (!face.hasColor() or face.glyphIndex('A') != null) {
                break :entry entry;
            }
        }
        return error.DefaultUnavailable;
    };
    const italic_list = self.faces.getPtr(.italic);
    const have_italic = italic_list.count() > 0;
    if (!have_italic) italic: {
        if (!synthetic_config.italic) {
            log.info("italic style not available and synthetic italic disabled", .{});
            try italic_list.append(alloc, .{ .alias = regular_entry });
            break :italic;
        }
        const synthetic = self.syntheticItalic(regular_entry) catch |err| {
            log.warn("failed to create synthetic italic, italic style will not be available err={}", .{err});
            try italic_list.append(alloc, .{ .alias = regular_entry });
            break :italic;
        };
        const synthetic_entry: Entry = .{
            .face = .{ .loaded = synthetic },
            .fallback = false,
        };
        log.info("synthetic italic face created", .{});
        try italic_list.append(alloc, .{ .entry = synthetic_entry });
    }
    const bold_list = self.faces.getPtr(.bold);
    const have_bold = bold_list.count() > 0;
    if (!have_bold) bold: {
        if (!synthetic_config.bold) {
            log.info("bold style not available and synthetic bold disabled", .{});
            try bold_list.append(alloc, .{ .alias = regular_entry });
            break :bold;
        }
        const synthetic = self.syntheticBold(regular_entry) catch |err| {
            log.warn("failed to create synthetic bold, bold style will not be available err={}", .{err});
            try bold_list.append(alloc, .{ .alias = regular_entry });
            break :bold;
        };
        const synthetic_entry: Entry = .{
            .face = .{ .loaded = synthetic },
            .fallback = false,
        };
        log.info("synthetic bold face created", .{});
        try bold_list.append(alloc, .{ .entry = synthetic_entry });
    }
    const bold_italic_list = self.faces.getPtr(.bold_italic);
    if (bold_italic_list.count() == 0) bold_italic: {
        if (!synthetic_config.@"bold-italic") {
            log.info("bold italic style not available and synthetic bold italic disabled", .{});
            try bold_italic_list.append(alloc, .{ .alias = regular_entry });
            break :bold_italic;
        }
        if (have_bold) {
            const base_entry: *Entry = bold_list.at(0).getEntry();
            if (self.syntheticItalic(base_entry)) |synthetic| {
                log.info("synthetic bold italic face created from bold", .{});
                const synthetic_entry: Entry = .{
                    .face = .{ .loaded = synthetic },
                    .fallback = false,
                };
                try bold_italic_list.append(alloc, .{ .entry = synthetic_entry });
                break :bold_italic;
            } else |_| {}
        }
        const base_entry: *Entry = italic_list.at(0).getEntry();
        if (self.syntheticBold(base_entry)) |synthetic| {
            log.info("synthetic bold italic face created from italic", .{});
            const synthetic_entry: Entry = .{
                .face = .{ .loaded = synthetic },
                .fallback = false,
            };
            try bold_italic_list.append(alloc, .{ .entry = synthetic_entry });
            break :bold_italic;
        } else |_| {}
        log.warn("bold italic style not available, using italic font", .{});
        try bold_italic_list.append(alloc, .{ .alias = base_entry });
    }
}
fn syntheticBold(self: *Collection, entry: *Entry) !Face {
    if (comptime !@hasDecl(Face, "syntheticBold")) return error.SyntheticBoldUnavailable;
    const opts = self.load_options orelse return error.DeferredLoadingUnavailable;
    const regular = try self.getFaceFromEntry(entry);
    var face_opts = opts.faceOptions();
    face_opts.size = regular.size;
    const face = try regular.syntheticBold(opts.faceOptions());
    var buf: [256]u8 = undefined;
    if (face.name(&buf)) |name| {
        log.info("font synthetic bold created family={s}", .{name});
    } else |_| {}
    return face;
}
fn syntheticItalic(self: *Collection, entry: *Entry) !Face {
    if (comptime !@hasDecl(Face, "syntheticItalic")) return error.SyntheticItalicUnavailable;
    const opts = self.load_options orelse return error.DeferredLoadingUnavailable;
    const regular = try self.getFaceFromEntry(entry);
    var face_opts = opts.faceOptions();
    face_opts.size = regular.size;
    const face = try regular.syntheticItalic(opts.faceOptions());
    var buf: [256]u8 = undefined;
    if (face.name(&buf)) |name| {
        log.info("font synthetic italic created family={s}", .{name});
    } else |_| {}
    return face;
}
pub const SetSizeError =
    UpdateMetricsError ||
    error{
        DeferredLoadingUnavailable,
        SetSizeFailed,
    };
pub fn setSize(
    self: *Collection,
    size: DesiredSize,
) SetSizeError!void {
    const opts = &(self.load_options orelse return error.DeferredLoadingUnavailable);
    opts.size = size;
    const primary_entry = self.getEntry(.{ .idx = 0 }) catch null;
    var it = self.faces.iterator();
    while (it.next()) |array| {
        var entry_it = array.value.iterator(0);
        while (entry_it.next()) |entry_or_alias| {
            if (entry_or_alias.* == .alias) continue;
            const entry = entry_or_alias.getEntry();
            if (entry.getLoaded()) |face| {
                var new_opts = opts.*;
                if (primary_entry != null and entry != primary_entry) {
                    new_opts.size.points *= @floatCast(entry.scale_factor.scale);
                }
                face.setSize(new_opts.faceOptions()) catch return error.SetSizeFailed;
            }
        }
    }
    try self.updateMetrics();
}
pub const SizeAdjustment = enum {
    none,
    ic_width,
    ex_height,
    cap_height,
    line_height,
};
fn scaleFactor(
    self: *Collection,
    face_metrics: Metrics.FaceMetrics,
    adjustment: SizeAdjustment,
) f64 {
    if (adjustment == .none) return 1.0;
    if (self.primary_face_metrics == null) {
        @branchHint(.unlikely);
        const primary_face = self.getFace(.{ .idx = 0 }) catch return 1.0;
        self.primary_face_metrics = primary_face.getMetrics();
    }
    const primary_metrics = self.primary_face_metrics.?;
    const primary_scale = 1 / primary_metrics.px_per_em;
    const face_scale = 1 / face_metrics.px_per_em;
    const primary_metric: f64, const face_metric: f64 =
        normalize_by: switch (adjustment) {
            .ic_width => {
                if (face_metrics.ic_width != face_metrics.icWidth())
                    continue :normalize_by .ex_height;
                break :normalize_by .{
                    primary_metrics.icWidth() * primary_scale,
                    face_metrics.icWidth() * face_scale,
                };
            },
            .ex_height => {
                if (face_metrics.ex_height != face_metrics.exHeight())
                    continue :normalize_by .cap_height;
                break :normalize_by .{
                    primary_metrics.exHeight() * primary_scale,
                    face_metrics.exHeight() * face_scale,
                };
            },
            .cap_height => {
                if (face_metrics.cap_height != face_metrics.capHeight())
                    continue :normalize_by .line_height;
                break :normalize_by .{
                    primary_metrics.capHeight() * primary_scale,
                    face_metrics.capHeight() * face_scale,
                };
            },
            .line_height => .{
                primary_metrics.lineHeight() * primary_scale,
                face_metrics.lineHeight() * face_scale,
            },
            .none => unreachable,
        };
    return primary_metric / face_metric;
}
pub const UpdateMetricsError = error{
    CannotLoadPrimaryFont,
};
pub fn updateMetrics(self: *Collection) UpdateMetricsError!void {
    const primary_face = self.getFace(.{ .idx = 0 }) catch return error.CannotLoadPrimaryFont;
    self.primary_face_metrics = primary_face.getMetrics();
    var metrics = Metrics.calc(self.primary_face_metrics.?);
    metrics.apply(self.metric_modifiers);
    self.metrics = metrics;
}
const StyleArray = std.EnumArray(Style, SegmentedList(EntryOrAlias, 0));
pub const LoadOptions = struct {
    library: Library,
    size: DesiredSize = .{ .points = 12 },
    freetype_load_flags: font.face.FreetypeLoadFlags = font.face.freetype_load_flags_default,
    pub fn deinit(self: *LoadOptions, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
    pub fn faceOptions(self: *const LoadOptions) font.face.Options {
        return .{
            .size = self.size,
            .freetype_load_flags = self.freetype_load_flags,
        };
    }
};
pub const Entry = struct {
    const AnyFace = union(enum) {
        deferred: DeferredFace,
        loaded: Face,
    };
    face: AnyFace,
    fallback: bool,
    scale_factor: union(enum) {
        adjustment: SizeAdjustment,
        scale: f64,
    } = .{ .scale = 1.0 },
    pub fn deinit(self: *Entry) void {
        switch (self.face) {
            inline .deferred, .loaded => |*v| v.deinit(),
        }
    }
    pub fn getLoaded(self: *Entry) ?*Face {
        return switch (self.face) {
            .deferred => null,
            .loaded => |*face| face,
        };
    }
    fn isDeferred(self: Entry) bool {
        return switch (self.face) {
            .deferred => true,
            .loaded => false,
        };
    }
    pub fn hasCodepoint(
        self: Entry,
        cp: u32,
        p_mode: PresentationMode,
    ) bool {
        return mode: switch (p_mode) {
            .default => |p| if (self.fallback)
                continue :mode .{ .explicit = p }
            else
                continue :mode .any,
            .explicit => |p| switch (self.face) {
                .deferred => |v| v.hasCodepoint(cp, p),
                .loaded => |face| explicit: {
                    const index = face.glyphIndex(cp) orelse break :explicit false;
                    break :explicit switch (p) {
                        .text => !face.isColorGlyph(index),
                        .emoji => face.isColorGlyph(index),
                    };
                },
            },
            .any => switch (self.face) {
                .deferred => |v| v.hasCodepoint(cp, null),
                .loaded => |face| face.glyphIndex(cp) != null,
            },
        };
    }
};
pub const EntryOrAlias = union(enum) {
    entry: Entry,
    alias: *Entry,
    pub fn getEntry(self: *EntryOrAlias) *Entry {
        return switch (self.*) {
            .entry => |*v| v,
            .alias => |v| v,
        };
    }
    pub fn getConstEntry(self: *const EntryOrAlias) *const Entry {
        return switch (self.*) {
            .entry => |*v| v,
            .alias => |v| v,
        };
    }
};
pub const PresentationMode = union(enum) {
    explicit: Presentation,
    default: Presentation,
    any: void,
};
pub const Index = packed struct(Index.Backing) {
    const Backing = u16;
    const backing_bits = @typeInfo(Backing).int.bits;
    const idx_bits = backing_bits - @typeInfo(@typeInfo(Style).@"enum".tag_type).int.bits;
    pub const IndexInt = @Int(.unsigned, idx_bits);
    pub const Special = enum(IndexInt) {
        pub const start = std.math.maxInt(IndexInt);
        sprite = start,
    };
    style: Style = .regular,
    idx: IndexInt = 0,
    pub fn initSpecial(v: Special) Index {
        return .{ .style = .regular, .idx = @intFromEnum(v) };
    }
    pub fn int(self: Index) Backing {
        return @bitCast(self);
    }
    pub fn special(self: Index) ?Special {
        if (self.idx < Special.start) return null;
        return @enumFromInt(self.idx);
    }
    test {
        try std.testing.expectEqual(@sizeOf(Backing), @sizeOf(Index));
        try std.testing.expectEqual(13, idx_bits);
    }
};
test init {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c = init();
    defer c.deinit(alloc);
}
test "add full" {
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var c = init();
    defer c.deinit(alloc);
    for (0..Index.Special.start - 1) |_| {
        _ = try c.add(alloc, try .init(
            lib,
            testFont,
            .{ .size = .{ .points = 12 } },
        ), .{
            .style = .regular,
            .fallback = false,
            .size_adjustment = .none,
        });
    }
    var face = try Face.init(
        lib,
        testFont,
        .{ .size = .{ .points = 12 } },
    );
    defer face.deinit();
    try testing.expectError(
        error.CollectionFull,
        c.add(alloc, face, .{
            .style = .regular,
            .fallback = false,
            .size_adjustment = .none,
        }),
    );
}
test "add deferred without loading options" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var c = init();
    defer c.deinit(alloc);
    try testing.expectError(error.DeferredLoadingUnavailable, c.addDeferred(
        alloc,
        undefined,
        .{
            .style = .regular,
            .fallback = false,
            .size_adjustment = .none,
        },
    ));
}
test getFace {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var c = init();
    defer c.deinit(alloc);
    const idx = try c.add(alloc, try .init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .none,
    });
    {
        const face1 = try c.getFace(idx);
        const face2 = try c.getFace(idx);
        try testing.expectEqual(@intFromPtr(face1), @intFromPtr(face2));
    }
}
test getIndex {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var c = init();
    defer c.deinit(alloc);
    _ = try c.add(alloc, try .init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .none,
    });
    var i: u32 = 32;
    while (i < 127) : (i += 1) {
        const idx = c.getIndex(i, .regular, .{ .any = {} });
        try testing.expect(idx != null);
    }
    {
        const idx = c.getIndex('🥸', .regular, .{ .any = {} });
        try testing.expect(idx == null);
    }
}
test completeStyles {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var c = init();
    defer c.deinit(alloc);
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
    try testing.expect(c.getIndex('A', .bold, .{ .any = {} }) == null);
    try testing.expect(c.getIndex('A', .italic, .{ .any = {} }) == null);
    try testing.expect(c.getIndex('A', .bold_italic, .{ .any = {} }) == null);
    try c.completeStyles(alloc, .{});
    try testing.expect(c.getIndex('A', .bold, .{ .any = {} }) != null);
    try testing.expect(c.getIndex('A', .italic, .{ .any = {} }) != null);
    try testing.expect(c.getIndex('A', .bold_italic, .{ .any = {} }) != null);
}
test setSize {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var c = init();
    defer c.deinit(alloc);
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
    try testing.expectEqual(@as(u32, 12), c.load_options.?.size.points);
    try c.setSize(.{ .points = 24 });
    try testing.expectEqual(@as(u32, 24), c.load_options.?.size.points);
}
test hasCodepoint {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var c = init();
    defer c.deinit(alloc);
    c.load_options = .{ .library = lib };
    const idx = try c.add(alloc, try .init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .none,
    });
    try testing.expect(c.hasCodepoint(idx, 'A', .{ .any = {} }));
    try testing.expect(!c.hasCodepoint(idx, '🥸', .{ .any = {} }));
}
test "hasCodepoint emoji default graphical" {
    if (options.backend != .fontconfig_freetype) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const testEmoji = font.embedded.emoji;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var c = init();
    defer c.deinit(alloc);
    c.load_options = .{ .library = lib };
    const idx = try c.add(alloc, try .init(
        lib,
        testEmoji,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .none,
    });
    try testing.expect(!c.hasCodepoint(idx, 'A', .{ .any = {} }));
    try testing.expect(c.hasCodepoint(idx, '🥸', .{ .any = {} }));
}
test "metrics" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.inconsolata;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var c = init();
    defer c.deinit(alloc);
    const size: DesiredSize = .{ .points = 12, .xdpi = 96, .ydpi = 96 };
    c.load_options = .{ .library = lib, .size = size };
    _ = try c.add(alloc, try .init(
        lib,
        testFont,
        .{ .size = size },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .none,
    });
    try c.updateMetrics();
    try comparison.expectApproxEqual(font.Metrics{
        .cell_width = 8,
        .cell_height = 17,
        .cell_baseline = 3,
        .underline_position = 17,
        .underline_thickness = 1,
        .strikethrough_position = 10,
        .strikethrough_thickness = 1,
        .overline_position = 0,
        .overline_thickness = 1,
        .box_thickness = 1,
        .cursor_height = 17,
        .icon_height = 16.784,
        .icon_height_single = 12.24,
        .face_width = 8.0,
        .face_height = 16.784,
        .face_y = -0.04,
    }, c.metrics);
    try c.setSize(.{ .points = 24, .xdpi = 96, .ydpi = 96 });
    try comparison.expectApproxEqual(font.Metrics{
        .cell_width = 16,
        .cell_height = 34,
        .cell_baseline = 6,
        .underline_position = 34,
        .underline_thickness = 2,
        .strikethrough_position = 19,
        .strikethrough_thickness = 2,
        .overline_position = 0,
        .overline_thickness = 2,
        .box_thickness = 2,
        .cursor_height = 34,
        .icon_height = 33.568,
        .icon_height_single = 24.48,
        .face_width = 16.0,
        .face_height = 33.568,
        .face_y = -0.08,
    }, c.metrics);
}
test "adjusted sizes" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.inconsolata;
    const fallback = font.embedded.monaspace_neon;
    const symbol = font.embedded.symbols_nerd_font;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var c = init();
    defer c.deinit(alloc);
    const size: DesiredSize = .{ .points = 12, .xdpi = 96, .ydpi = 96 };
    c.load_options = .{ .library = lib, .size = size };
    _ = try c.add(alloc, try .init(
        lib,
        testFont,
        .{ .size = size },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .none,
    });
    try c.updateMetrics();
    inline for ([_][]const u8{ "ex_height", "cap_height" }) |metric| {
        const fallback_idx = try c.add(alloc, try .init(
            lib,
            fallback,
            .{ .size = size },
        ), .{
            .style = .regular,
            .fallback = false,
            .size_adjustment = @field(SizeAdjustment, metric),
        });
        {
            const primary_metrics = (try c.getFace(.{ .idx = 0 })).getMetrics();
            const fallback_metrics = (try c.getFace(fallback_idx)).getMetrics();
            try std.testing.expectApproxEqAbs(
                @field(primary_metrics, metric).?,
                @field(fallback_metrics, metric).?,
                0.5,
            );
        }
        try c.setSize(.{ .points = 37, .xdpi = 96, .ydpi = 96 });
        {
            const primary_metrics = (try c.getFace(.{ .idx = 0 })).getMetrics();
            const fallback_metrics = (try c.getFace(fallback_idx)).getMetrics();
            try std.testing.expectApproxEqAbs(
                @field(primary_metrics, metric).?,
                @field(fallback_metrics, metric).?,
                0.5,
            );
        }
        try c.setSize(size);
    }
    {
        const fallback_idx = try c.add(alloc, try .init(
            lib,
            fallback,
            .{ .size = size },
        ), .{
            .style = .regular,
            .fallback = false,
            .size_adjustment = .none,
        });
        try std.testing.expectEqual(
            (try c.getFace(.{ .idx = 0 })).size.points,
            (try c.getFace(fallback_idx)).size.points,
        );
        try c.setSize(.{ .points = 37, .xdpi = 96, .ydpi = 96 });
        try std.testing.expectEqual(
            (try c.getFace(.{ .idx = 0 })).size.points,
            (try c.getFace(fallback_idx)).size.points,
        );
        try c.setSize(size);
    }
    const symbol_idx = try c.add(alloc, try .init(
        lib,
        symbol,
        .{ .size = size },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .ex_height,
    });
    {
        const primary_metrics = (try c.getFace(.{ .idx = 0 })).getMetrics();
        const symbol_metrics = (try c.getFace(symbol_idx)).getMetrics();
        try std.testing.expectApproxEqAbs(
            primary_metrics.lineHeight(),
            symbol_metrics.lineHeight(),
            0.5,
        );
    }
}
test "face metrics" {
    if (options.backend != .web_canvas) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const narrowFont = font.embedded.cozette;
    const wideFont = font.embedded.geist_mono;
    var lib = try Library.init(alloc);
    defer lib.deinit();
    var c = init();
    defer c.deinit(alloc);
    const size: DesiredSize = .{ .points = 12, .xdpi = 96, .ydpi = 96 };
    c.load_options = .{ .library = lib, .size = size };
    const narrowIndex = try c.add(alloc, try .init(
        lib,
        narrowFont,
        .{ .size = size },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .none,
    });
    const wideIndex = try c.add(alloc, try .init(
        lib,
        wideFont,
        .{ .size = size },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .none,
    });
    const narrowMetrics: font.Metrics.FaceMetrics = (try c.getFace(narrowIndex)).getMetrics();
    const wideMetrics: font.Metrics.FaceMetrics = (try c.getFace(wideIndex)).getMetrics();
    const narrowMetricsExpected = font.Metrics.FaceMetrics{
        .px_per_em = 16.0,
        .cell_width = switch (options.backend) {
            .freetype,
            .fontconfig_freetype,
            .coretext_freetype,
            => 8.0,
            .coretext,
            .coretext_harfbuzz,
            .coretext_noshape,
            => 7.3828125,
            .web_canvas => unreachable,
        },
        .ascent = 12.3046875,
        .descent = -3.6953125,
        .line_gap = 0.0,
        .underline_position = -1.2265625,
        .underline_thickness = 1.2265625,
        .strikethrough_position = 6.15625,
        .strikethrough_thickness = 1.234375,
        .cap_height = 9.84375,
        .ex_height = 7.3828125,
        .ascii_height = switch (options.backend) {
            .freetype,
            .fontconfig_freetype,
            .coretext_freetype,
            => 18.0625,
            .coretext,
            .coretext_harfbuzz,
            .coretext_noshape,
            => 16.0,
            .web_canvas => unreachable,
        },
    };
    const wideMetricsExpected = font.Metrics.FaceMetrics{
        .px_per_em = 16.0,
        .cell_width = switch (options.backend) {
            .freetype,
            .fontconfig_freetype,
            .coretext_freetype,
            => 10.0,
            .coretext,
            .coretext_harfbuzz,
            .coretext_noshape,
            => 9.6,
            .web_canvas => unreachable,
        },
        .ascent = 14.72,
        .descent = -3.52,
        .line_gap = 1.6,
        .underline_position = -1.6,
        .underline_thickness = 0.8,
        .strikethrough_position = 4.24,
        .strikethrough_thickness = 0.8,
        .cap_height = 11.36,
        .ex_height = 8.48,
        .ascii_height = switch (options.backend) {
            .freetype,
            .fontconfig_freetype,
            .coretext_freetype,
            => 16.0,
            .coretext,
            .coretext_harfbuzz,
            .coretext_noshape,
            => 15.472000000000001,
            .web_canvas => unreachable,
        },
    };
    inline for (
        .{ narrowMetricsExpected, wideMetricsExpected },
        .{ narrowMetrics, wideMetrics },
    ) |metricsExpected, metricsActual| {
        try comparison.expectApproxEqual(metricsExpected, metricsActual);
    }
    try std.testing.expectEqual(
        2 * narrowMetrics.cell_width,
        narrowMetrics.icWidth(),
    );
    try std.testing.expectEqual(
        wideMetrics.ascii_height,
        wideMetrics.icWidth(),
    );
}
