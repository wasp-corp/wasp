const std = @import("std");
pub const Backend = enum {
    const WasmTarget = @import("../os/wasm/target.zig").Target;
    freetype,
    freetype_windows,
    fontconfig_freetype,
    coretext,
    coretext_freetype,
    coretext_harfbuzz,
    coretext_noshape,
    web_canvas,
    pub fn default(
        target: std.Target,
        wasm_target: WasmTarget,
    ) Backend {
        if (target.cpu.arch == .wasm32) {
            return switch (wasm_target) {
                .browser => .web_canvas,
            };
        }
        if (target.os.tag == .windows) {
            return .freetype_windows;
        }
        return if (target.os.tag.isDarwin()) .coretext else .fontconfig_freetype;
    }
    pub fn hasFreetype(self: Backend) bool {
        return switch (self) {
            .freetype,
            .freetype_windows,
            .fontconfig_freetype,
            .coretext_freetype,
            => true,
            .coretext,
            .coretext_harfbuzz,
            .coretext_noshape,
            .web_canvas,
            => false,
        };
    }
    pub fn hasCoretext(self: Backend) bool {
        return switch (self) {
            .coretext,
            .coretext_freetype,
            .coretext_harfbuzz,
            .coretext_noshape,
            => true,
            .freetype,
            .freetype_windows,
            .fontconfig_freetype,
            .web_canvas,
            => false,
        };
    }
    pub fn hasFontconfig(self: Backend) bool {
        return switch (self) {
            .fontconfig_freetype => true,
            .freetype,
            .freetype_windows,
            .coretext,
            .coretext_freetype,
            .coretext_harfbuzz,
            .coretext_noshape,
            .web_canvas,
            => false,
        };
    }
    pub fn hasHarfbuzz(self: Backend) bool {
        return switch (self) {
            .freetype,
            .freetype_windows,
            .fontconfig_freetype,
            .coretext_freetype,
            .coretext_harfbuzz,
            => true,
            .coretext,
            .coretext_noshape,
            .web_canvas,
            => false,
        };
    }
};
