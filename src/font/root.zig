const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const library = @import("library.zig");
pub const Atlas = @import("Atlas.zig");
pub const Backend = @import("backend.zig").Backend;
pub const discovery = @import("discovery.zig");
pub const embedded = @import("embedded.zig");
pub const face = @import("face.zig");
pub const CodepointMap = @import("CodepointMap.zig");
pub const CodepointResolver = @import("CodepointResolver.zig");
pub const Collection = @import("Collection.zig");
pub const DeferredFace = @import("DeferredFace.zig");
pub const Face = face.Face;
pub const Glyph = @import("Glyph.zig");
pub const glyf_rasterize = @import("glyf_rasterize.zig");
pub const Metrics = @import("Metrics.zig");
pub const opentype = @import("opentype.zig");
pub const shape = @import("shape.zig");
pub const Shaper = shape.Shaper;
pub const ShaperCache = shape.Cache;
pub const SharedGrid = @import("SharedGrid.zig");
pub const SharedGridSet = @import("SharedGridSet.zig");
pub const sprite = @import("sprite.zig");
pub const Sprite = sprite.Sprite;
pub const SpriteFace = sprite.Face;
pub const Descriptor = discovery.Descriptor;
pub const Discover = discovery.Discover;
pub const Library = library.Library;
comptime {
    if (builtin.target.cpu.arch.isWasm()) {
        _ = Atlas.Wasm;
        _ = DeferredFace.Wasm;
        _ = face.web_canvas.Wasm;
        _ = shape.web_canvas.Wasm;
    }
}
pub const options: struct {
    backend: Backend,
} = .{
    .backend = if (builtin.target.cpu.arch.isWasm()) .web_canvas else build_config.font_backend,
};
pub const Style = enum(u3) {
    regular = 0,
    bold = 1,
    italic = 2,
    bold_italic = 3,
};
pub const Presentation = enum(u1) {
    text = 0, 
    emoji = 1, 
};
pub const sprite_index = Collection.Index.initSpecial(.sprite);
pub const default_fallback_adjustment: Collection.SizeAdjustment = .ic_width;
test {
    if (!comptime builtin.target.cpu.arch.isWasm()) {
        @import("std").testing.refAllDecls(@This());
        return;
    }
    _ = Atlas;
}
