const std = @import("std");
const builtin = @import("builtin");
const options = @import("build_options");
pub const Target = enum {
    browser,
};
pub const target: ?Target = if (!builtin.target.cpu.arch.isWasm()) null else target: {
    const result = @as(Target, @enumFromInt(@intFromEnum(options.wasm_target)));
    std.debug.assert(std.mem.eql(u8, @tagName(result), @tagName(options.wasm_target)));
    break :target result;
};
