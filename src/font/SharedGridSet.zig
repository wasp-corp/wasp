const SharedGridSet = @This();
const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const font = @import("main.zig");
const CodepointResolver = font.CodepointResolver;
const Collection = font.Collection;
const Discover = font.Discover;
const Style = font.Style;
const Library = font.Library;
const Metrics = font.Metrics;
const CodepointMap = font.CodepointMap;
const DesiredSize = font.face.DesiredSize;
const Face = font.Face;
const SharedGrid = font.SharedGrid;
const discovery = @import("discovery.zig");
const configpkg = @import("../config.zig");
const Config = configpkg.Config;
const global = @import("../global.zig");
const log = std.log.scoped(.font_shared_grid_set);
alloc: Allocator,
map: Map = .{},
font_lib: Library,
font_discover: ?Discover = null,
lock: std.Io.Mutex = .init,
pub const InitError = Library.InitError;
pub fn init(alloc: Allocator) InitError!SharedGridSet {
    var font_lib = try Library.init(alloc);
    errdefer font_lib.deinit();
    return .{
        .alloc = alloc,
        .map = .{},
        .font_lib = font_lib,
    };
}
pub fn deinit(self: *SharedGridSet) void {
    var it = self.map.iterator();
    while (it.next()) |entry| {
        entry.key_ptr.deinit();
        const v = entry.value_ptr.*;
        v.grid.deinit(self.alloc);
        self.alloc.destroy(v.grid);
    }
    self.map.deinit(self.alloc);
    if (comptime Discover != void) {
        if (self.font_discover) |*v| v.deinit();
    }
    self.font_lib.deinit();
}
pub fn count(self: *SharedGridSet) usize {
    self.lock.lockUncancelable(global.io());
    defer self.lock.unlock(global.io());
    return self.map.count();
}
pub fn ref(
    self: *SharedGridSet,
    config: *const DerivedConfig,
    font_size: DesiredSize,
) !struct { Key, *SharedGrid } {
    var key = try Key.init(self.alloc, config, font_size);
    errdefer key.deinit();
    self.lock.lockUncancelable(global.io());
    defer self.lock.unlock(global.io());
    const gop = try self.map.getOrPut(self.alloc, key);
    if (gop.found_existing) {
        log.debug("found cached grid for font config", .{});
        key.deinit();
        gop.value_ptr.ref += 1;
        return .{ gop.key_ptr.*, gop.value_ptr.grid };
    }
    errdefer self.map.removeByPtr(gop.key_ptr);
    log.debug("initializing new grid for font config", .{});
    const grid = try self.alloc.create(SharedGrid);
    errdefer self.alloc.destroy(grid);
    gop.value_ptr.* = .{
        .grid = grid,
        .ref = 1,
    };
    grid.* = try .init(self.alloc, resolver: {
        var c = try self.collection(&key, font_size, config);
        errdefer c.deinit(self.alloc);
        var styles = CodepointResolver.StyleStatus.initFill(true);
        styles.set(.bold, config.@"font-style-bold" != .false);
        styles.set(.italic, config.@"font-style-italic" != .false);
        styles.set(.bold_italic, config.@"font-style-bold-italic" != .false);
        break :resolver .{
            .collection = c,
            .styles = styles,
            .discover = try self.discover(),
            .codepoint_map = key.codepoint_map,
        };
    });
    errdefer grid.deinit(self.alloc);
    return .{ gop.key_ptr.*, gop.value_ptr.grid };
}
fn collection(
    self: *SharedGridSet,
    key: *const Key,
    size: DesiredSize,
    config: *const DerivedConfig,
) !Collection {
    const load_options: Collection.LoadOptions = .{
        .library = self.font_lib,
        .size = size,
        .freetype_load_flags = key.freetype_load_flags,
    };
    var c = Collection.init();
    errdefer c.deinit(self.alloc);
    c.load_options = load_options;
    c.metric_modifiers = key.metric_modifiers;
    if (Discover != void) discover: {
        const disco = try self.discover() orelse {
            log.warn(
                "font discovery not available, cannot search for fonts",
                .{},
            );
            break :discover;
        };
        var name_buf: [256]u8 = undefined;
        inline for (@typeInfo(Style).@"enum".fields) |field| {
            const style = @field(Style, field.name);
            for (key.descriptorsForStyle(style)) |desc| {
                {
                    var disco_it = try disco.discover(self.alloc, desc);
                    defer disco_it.deinit();
                    if (try disco_it.next()) |face| {
                        log.info("font {s}: {s}", .{
                            field.name,
                            try face.name(&name_buf),
                        });
                        _ = try c.addDeferred(self.alloc, face, .{
                            .style = style,
                            .fallback = false,
                            .size_adjustment = .none,
                        });
                        continue;
                    }
                }
                if (style != .regular and desc.variations.len > 0) {
                    var disco_it = try disco.discover(self.alloc, desc: {
                        var copy = desc;
                        copy.bold = false;
                        copy.italic = false;
                        break :desc copy;
                    });
                    defer disco_it.deinit();
                    if (try disco_it.next()) |face| {
                        log.info("font {s}: {s}", .{
                            field.name,
                            try face.name(&name_buf),
                        });
                        _ = try c.addDeferred(self.alloc, face, .{
                            .style = style,
                            .fallback = false,
                            .size_adjustment = .none,
                        });
                        continue;
                    }
                }
                log.warn("font-family {s} not found: {s}", .{
                    field.name,
                    desc.family.?,
                });
            }
        }
    }
    try c.completeStyles(self.alloc, config.@"font-synthetic-style");
    _ = try c.add(
        self.alloc,
        try .init(
            self.font_lib,
            font.embedded.variable,
            load_options.faceOptions(),
        ),
        .{
            .style = .regular,
            .fallback = true,
            .size_adjustment = font.default_fallback_adjustment,
        },
    );
    try (try c.getFace(try c.add(
        self.alloc,
        try .init(
            self.font_lib,
            font.embedded.variable,
            load_options.faceOptions(),
        ),
        .{
            .style = .bold,
            .fallback = true,
            .size_adjustment = font.default_fallback_adjustment,
        },
    ))).setVariations(
        &.{.{ .id = .init("wght"), .value = 700 }},
        load_options.faceOptions(),
    );
    _ = try c.add(
        self.alloc,
        try .init(
            self.font_lib,
            font.embedded.variable_italic,
            load_options.faceOptions(),
        ),
        .{
            .style = .italic,
            .fallback = true,
            .size_adjustment = font.default_fallback_adjustment,
        },
    );
    try (try c.getFace(try c.add(
        self.alloc,
        try .init(
            self.font_lib,
            font.embedded.variable_italic,
            load_options.faceOptions(),
        ),
        .{
            .style = .bold_italic,
            .fallback = true,
            .size_adjustment = font.default_fallback_adjustment,
        },
    ))).setVariations(
        &.{.{ .id = .init("wght"), .value = 700 }},
        load_options.faceOptions(),
    );
    _ = try c.add(
        self.alloc,
        try .init(
            self.font_lib,
            font.embedded.symbols_nerd_font,
            load_options.faceOptions(),
        ),
        .{
            .style = .regular,
            .fallback = true,
            .size_adjustment = .none,
        },
    );
    if (comptime builtin.target.os.tag.isDarwin() and Discover != void) apple_emoji: {
        const disco = try self.discover() orelse break :apple_emoji;
        if (@hasDecl(Discover, "discoverExactFamily")) {
            if (try disco.discoverExactFamily(
                "Apple Color Emoji",
            )) |face| {
                _ = try c.addDeferred(self.alloc, face, .{
                    .style = .regular,
                    .fallback = true,
                    .size_adjustment = .none,
                });
                break :apple_emoji;
            }
        }
        var disco_it = try disco.discover(self.alloc, .{
            .family = "Apple Color Emoji",
        });
        defer disco_it.deinit();
        if (try disco_it.next()) |face| {
            _ = try c.addDeferred(self.alloc, face, .{
                .style = .regular,
                .fallback = true,
                .size_adjustment = .none,
            });
        }
    }
    if (comptime !builtin.target.os.tag.isDarwin() or Discover == void) {
        _ = try c.add(
            self.alloc,
            try .init(
                self.font_lib,
                font.embedded.emoji,
                load_options.faceOptions(),
            ),
            .{
                .style = .regular,
                .fallback = true,
                .size_adjustment = .none,
            },
        );
        _ = try c.add(
            self.alloc,
            try .init(
                self.font_lib,
                font.embedded.emoji_text,
                load_options.faceOptions(),
            ),
            .{
                .style = .regular,
                .fallback = true,
                .size_adjustment = .none,
            },
        );
    }
    return c;
}
pub fn deref(self: *SharedGridSet, key: Key) void {
    self.lock.lockUncancelable(global.io());
    defer self.lock.unlock(global.io());
    const entry = self.map.getEntry(key) orelse return;
    assert(entry.value_ptr.ref >= 1);
    if (entry.value_ptr.ref > 1) {
        entry.value_ptr.ref -= 1;
        return;
    }
    entry.key_ptr.deinit();
    entry.value_ptr.grid.deinit(self.alloc);
    self.alloc.destroy(entry.value_ptr.grid);
    self.map.removeByPtr(entry.key_ptr);
}
pub const Map = std.HashMapUnmanaged(
    Key,
    ReffedGrid,
    struct {
        const KeyType = Key;
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
fn discover(self: *SharedGridSet) !?*Discover {
    if (comptime Discover == void) return null;
    if (self.font_discover) |*v| return v;
    self.font_discover = .init(self.font_lib);
    return &self.font_discover.?;
}
const ReffedGrid = struct {
    grid: *SharedGrid,
    ref: u32 = 0,
};
pub const DerivedConfig = struct {
    arena: ArenaAllocator,
    @"font-family": configpkg.RepeatableString,
    @"font-family-bold": configpkg.RepeatableString,
    @"font-family-italic": configpkg.RepeatableString,
    @"font-family-bold-italic": configpkg.RepeatableString,
    @"font-style": configpkg.FontStyle,
    @"font-style-bold": configpkg.FontStyle,
    @"font-style-italic": configpkg.FontStyle,
    @"font-style-bold-italic": configpkg.FontStyle,
    @"font-variation": configpkg.RepeatableFontVariation,
    @"font-variation-bold": configpkg.RepeatableFontVariation,
    @"font-variation-italic": configpkg.RepeatableFontVariation,
    @"font-variation-bold-italic": configpkg.RepeatableFontVariation,
    @"font-codepoint-map": configpkg.RepeatableCodepointMap,
    @"font-synthetic-style": configpkg.FontSyntheticStyle,
    @"adjust-cell-width": ?Metrics.Modifier,
    @"adjust-cell-height": ?Metrics.Modifier,
    @"adjust-font-baseline": ?Metrics.Modifier,
    @"adjust-underline-position": ?Metrics.Modifier,
    @"adjust-underline-thickness": ?Metrics.Modifier,
    @"adjust-strikethrough-position": ?Metrics.Modifier,
    @"adjust-strikethrough-thickness": ?Metrics.Modifier,
    @"adjust-overline-position": ?Metrics.Modifier,
    @"adjust-overline-thickness": ?Metrics.Modifier,
    @"adjust-cursor-thickness": ?Metrics.Modifier,
    @"adjust-cursor-height": ?Metrics.Modifier,
    @"adjust-box-thickness": ?Metrics.Modifier,
    @"adjust-icon-height": ?Metrics.Modifier,
    @"freetype-load-flags": font.face.FreetypeLoadFlags,
    pub fn init(
        alloc_gpa: Allocator,
        config: anytype,
    ) Allocator.Error!DerivedConfig {
        var arena = ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        return .{
            .@"font-family" = try config.@"font-family".clone(alloc),
            .@"font-family-bold" = try config.@"font-family-bold".clone(alloc),
            .@"font-family-italic" = try config.@"font-family-italic".clone(alloc),
            .@"font-family-bold-italic" = try config.@"font-family-bold-italic".clone(alloc),
            .@"font-style" = try config.@"font-style".clone(alloc),
            .@"font-style-bold" = try config.@"font-style-bold".clone(alloc),
            .@"font-style-italic" = try config.@"font-style-italic".clone(alloc),
            .@"font-style-bold-italic" = try config.@"font-style-bold-italic".clone(alloc),
            .@"font-variation" = try config.@"font-variation".clone(alloc),
            .@"font-variation-bold" = try config.@"font-variation-bold".clone(alloc),
            .@"font-variation-italic" = try config.@"font-variation-italic".clone(alloc),
            .@"font-variation-bold-italic" = try config.@"font-variation-bold-italic".clone(alloc),
            .@"font-codepoint-map" = try config.@"font-codepoint-map".clone(alloc),
            .@"font-synthetic-style" = config.@"font-synthetic-style",
            .@"adjust-cell-width" = config.@"adjust-cell-width",
            .@"adjust-cell-height" = config.@"adjust-cell-height",
            .@"adjust-font-baseline" = config.@"adjust-font-baseline",
            .@"adjust-underline-position" = config.@"adjust-underline-position",
            .@"adjust-underline-thickness" = config.@"adjust-underline-thickness",
            .@"adjust-strikethrough-position" = config.@"adjust-strikethrough-position",
            .@"adjust-strikethrough-thickness" = config.@"adjust-strikethrough-thickness",
            .@"adjust-overline-position" = config.@"adjust-overline-position",
            .@"adjust-overline-thickness" = config.@"adjust-overline-thickness",
            .@"adjust-cursor-thickness" = config.@"adjust-cursor-thickness",
            .@"adjust-cursor-height" = config.@"adjust-cursor-height",
            .@"adjust-box-thickness" = config.@"adjust-box-thickness",
            .@"adjust-icon-height" = config.@"adjust-icon-height",
            .@"freetype-load-flags" = if (font.face.FreetypeLoadFlags != void) config.@"freetype-load-flags" else {},
            .arena = arena,
        };
    }
    pub fn deinit(self: *DerivedConfig) void {
        self.arena.deinit();
    }
};
pub const Key = struct {
    arena: ArenaAllocator,
    descriptors: []const discovery.Descriptor = &.{},
    style_offsets: StyleOffsets = @splat(0),
    codepoint_map: CodepointMap = .{},
    metric_modifiers: Metrics.ModifierSet = .{},
    font_size: DesiredSize = .{ .points = 12 },
    freetype_load_flags: font.face.FreetypeLoadFlags = font.face.freetype_load_flags_default,
    const style_offsets_len = std.enums.directEnumArrayLen(Style, 0);
    const StyleOffsets = [style_offsets_len]usize;
    comptime {
        assert(@intFromEnum(Style.regular) == 0);
        assert(@intFromEnum(Style.bold) == 1);
        assert(@intFromEnum(Style.italic) == 2);
        assert(@intFromEnum(Style.bold_italic) == 3);
    }
    pub fn init(
        alloc_gpa: Allocator,
        config_src: *const DerivedConfig,
        font_size: DesiredSize,
    ) Allocator.Error!Key {
        var arena = ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        var config = try DerivedConfig.init(alloc, config_src);
        var descriptors: std.ArrayList(discovery.Descriptor) = .empty;
        defer descriptors.deinit(alloc);
        for (config.@"font-family".list.items) |family| {
            try descriptors.append(alloc, .{
                .family = family,
                .style = config.@"font-style".nameValue(),
                .size = font_size.points,
                .variations = config.@"font-variation".list.items,
            });
        }
        for (config.@"font-family-bold".list.items) |family| {
            const style = config.@"font-style-bold".nameValue();
            try descriptors.append(alloc, .{
                .family = family,
                .style = style,
                .size = font_size.points,
                .bold = style == null,
                .variations = config.@"font-variation-bold".list.items,
            });
        }
        for (config.@"font-family-italic".list.items) |family| {
            const style = config.@"font-style-italic".nameValue();
            try descriptors.append(alloc, .{
                .family = family,
                .style = style,
                .size = font_size.points,
                .italic = style == null,
                .variations = config.@"font-variation-italic".list.items,
            });
        }
        for (config.@"font-family-bold-italic".list.items) |family| {
            const style = config.@"font-style-bold-italic".nameValue();
            try descriptors.append(alloc, .{
                .family = family,
                .style = style,
                .size = font_size.points,
                .bold = style == null,
                .italic = style == null,
                .variations = config.@"font-variation-bold-italic".list.items,
            });
        }
        const codepoint_map: CodepointMap = map: {
            const map = config.@"font-codepoint-map";
            if (map.map.list.len == 0) break :map .{};
            const clone = try config.@"font-codepoint-map".clone(alloc);
            break :map clone.map;
        };
        const metric_modifiers: Metrics.ModifierSet = set: {
            var set: Metrics.ModifierSet = .{};
            if (config.@"adjust-cell-width") |m| try set.put(alloc, .cell_width, m);
            if (config.@"adjust-cell-height") |m| try set.put(alloc, .cell_height, m);
            if (config.@"adjust-font-baseline") |m| try set.put(alloc, .cell_baseline, m);
            if (config.@"adjust-underline-position") |m| try set.put(alloc, .underline_position, m);
            if (config.@"adjust-underline-thickness") |m| try set.put(alloc, .underline_thickness, m);
            if (config.@"adjust-strikethrough-position") |m| try set.put(alloc, .strikethrough_position, m);
            if (config.@"adjust-strikethrough-thickness") |m| try set.put(alloc, .strikethrough_thickness, m);
            if (config.@"adjust-overline-position") |m| try set.put(alloc, .overline_position, m);
            if (config.@"adjust-overline-thickness") |m| try set.put(alloc, .overline_thickness, m);
            if (config.@"adjust-cursor-thickness") |m| try set.put(alloc, .cursor_thickness, m);
            if (config.@"adjust-cursor-height") |m| try set.put(alloc, .cursor_height, m);
            if (config.@"adjust-box-thickness") |m| try set.put(alloc, .box_thickness, m);
            if (config.@"adjust-icon-height") |m| try set.put(alloc, .icon_height, m);
            break :set set;
        };
        const regular_offset = config.@"font-family".list.items.len;
        const bold_offset = regular_offset + config.@"font-family-bold".list.items.len;
        const italic_offset = bold_offset + config.@"font-family-italic".list.items.len;
        const bold_italic_offset = italic_offset + config.@"font-family-bold-italic".list.items.len;
        return .{
            .arena = arena,
            .descriptors = try descriptors.toOwnedSlice(alloc),
            .style_offsets = .{
                regular_offset,
                bold_offset,
                italic_offset,
                bold_italic_offset,
            },
            .codepoint_map = codepoint_map,
            .metric_modifiers = metric_modifiers,
            .font_size = font_size,
            .freetype_load_flags = if (font.face.FreetypeLoadFlags != void)
                config.@"freetype-load-flags"
            else
                font.face.freetype_load_flags_default,
        };
    }
    pub fn deinit(self: *Key) void {
        self.arena.deinit();
    }
    pub fn descriptorsForStyle(
        self: Key,
        style: Style,
    ) []const discovery.Descriptor {
        const idx = @intFromEnum(style);
        const start: usize = if (idx == 0) 0 else self.style_offsets[idx - 1];
        const end = self.style_offsets[idx];
        return self.descriptors[start..end];
    }
    pub fn hash(self: Key, hasher: anytype) void {
        const autoHash = std.hash.autoHash;
        autoHash(hasher, @as(u32, @bitCast(self.font_size.points)));
        autoHash(hasher, self.font_size.xdpi);
        autoHash(hasher, self.font_size.ydpi);
        autoHash(hasher, self.descriptors.len);
        for (self.descriptors) |d| d.hash(hasher);
        self.codepoint_map.hash(hasher);
        autoHash(hasher, self.metric_modifiers.count());
        autoHash(hasher, self.freetype_load_flags);
        if (self.metric_modifiers.count() > 0) {
            inline for (@typeInfo(Metrics.Key).@"enum".fields) |field| {
                const key = @field(Metrics.Key, field.name);
                if (self.metric_modifiers.get(key)) |value| {
                    autoHash(hasher, key);
                    value.hash(hasher);
                }
            }
        }
    }
    pub fn hashcode(self: Key) u64 {
        var hasher = std.hash.Wyhash.init(0);
        self.hash(&hasher);
        return hasher.final();
    }
};
test "Key" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    var keycfg = try DerivedConfig.init(alloc, &cfg);
    defer keycfg.deinit();
    var k = try Key.init(alloc, &keycfg, .{ .points = 12 });
    defer k.deinit();
    var k2 = try Key.init(alloc, &keycfg, .{ .points = 12 });
    defer k2.deinit();
    try testing.expect(k.hashcode() > 0);
    try testing.expectEqual(k.hashcode(), k2.hashcode());
}
test "Key different font points" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    var keycfg = try DerivedConfig.init(alloc, &cfg);
    defer keycfg.deinit();
    var k = try Key.init(alloc, &keycfg, .{ .points = 12 });
    defer k.deinit();
    var k2 = try Key.init(alloc, &keycfg, .{ .points = 16 });
    defer k2.deinit();
    try testing.expect(k.hashcode() != k2.hashcode());
}
test "Key different font DPI" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    var keycfg = try DerivedConfig.init(alloc, &cfg);
    defer keycfg.deinit();
    var k = try Key.init(alloc, &keycfg, .{ .points = 12, .xdpi = 1 });
    defer k.deinit();
    var k2 = try Key.init(alloc, &keycfg, .{ .points = 12, .xdpi = 2 });
    defer k2.deinit();
    try testing.expect(k.hashcode() != k2.hashcode());
}
test SharedGridSet {
    const testing = std.testing;
    const alloc = testing.allocator;
    var set = try SharedGridSet.init(alloc);
    defer set.deinit();
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    var keycfg = try DerivedConfig.init(alloc, &cfg);
    defer keycfg.deinit();
    const key1, const grid1 = try set.ref(&keycfg, .{ .points = 12 });
    try testing.expectEqual(@as(usize, 1), set.count());
    const key2, const grid2 = try set.ref(&keycfg, .{ .points = 12 });
    try testing.expectEqual(@as(usize, 1), set.count());
    try testing.expectEqual(@intFromPtr(grid1), @intFromPtr(grid2));
    set.deref(key2);
    try testing.expectEqual(@as(usize, 1), set.count());
    set.deref(key1);
    try testing.expectEqual(@as(usize, 0), set.count());
}
