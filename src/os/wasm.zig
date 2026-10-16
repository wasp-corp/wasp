const std = @import("std");
const builtin = @import("builtin");
const options = @import("build_options");
comptime {
    if (!builtin.target.cpu.arch.isWasm()) {
        @compileError("wasm.zig should only be analyzed for wasm32 builds");
    }
}
pub const shared_mem = options.wasm_shared;
pub const alloc = if (builtin.is_test)
    std.testing.allocator
else
    std.heap.wasm_allocator;
