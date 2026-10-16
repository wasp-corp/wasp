const std = @import("std");
const options = @import("main.zig").options;
const run = @import("shaper/run.zig");
const feature = @import("shaper/feature.zig");
const configpkg = @import("../config.zig");
const terminal = @import("../terminal/main.zig");
const SharedGrid = @import("main.zig").SharedGrid;
pub const noop = @import("shaper/noop.zig");
pub const harfbuzz = @import("shaper/harfbuzz.zig");
pub const coretext = @import("shaper/coretext.zig");
pub const web_canvas = @import("shaper/web_canvas.zig");
pub const Cache = @import("shaper/Cache.zig");
pub const TextRun = run.TextRun;
pub const RunIterator = run.RunIterator;
pub const Feature = feature.Feature;
pub const FeatureList = feature.FeatureList;
pub const default_features = feature.default_features;
pub const Shaper = switch (options.backend) {
    .freetype,
    .freetype_windows,
    .fontconfig_freetype,
    .coretext_freetype,
    .coretext_harfbuzz,
    => harfbuzz.Shaper,
    .coretext => coretext.Shaper,
    .coretext_noshape => noop.Shaper,
    .web_canvas => web_canvas.Shaper,
};
pub const Cell = struct {
    x: u16,
    x_offset: i16 = 0,
    y_offset: i16 = 0,
    glyph_index: u32,
};
pub const Options = struct {
    features: []const []const u8 = &.{},
};
pub const RunOptions = struct {
    grid: *SharedGrid,
    cells: std.MultiArrayList(terminal.RenderState.Cell).Slice = .empty,
    selection: ?[2]u16 = null,
    cursor_x: ?usize = null,
    pub fn applyBreakConfig(
        self: *RunOptions,
        config: configpkg.FontShapingBreak,
    ) void {
        if (!config.cursor) self.cursor_x = null;
    }
};
test {
    _ = Cache;
    _ = Shaper;
    _ = noop;
}
