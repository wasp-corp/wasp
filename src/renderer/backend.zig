const std = @import("std");
const WasmTarget = @import("../os/wasm/target.zig").Target;
pub const Backend = enum {
    opengl,
    metal,
    pub fn default(
        target: std.Target,
        wasm_target: WasmTarget,
    ) Backend {
        _ = wasm_target;
        if (target.os.tag.isDarwin()) return .metal;
        return .opengl;
    }
};
