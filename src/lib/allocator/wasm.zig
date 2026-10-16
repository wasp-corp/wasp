const std = @import("std");
const c_abi = @import("../c_abi.zig");
const default = @import("../allocator.zig").default;
const alloc = default(null);
const wasm_alignment: std.mem.Alignment = .fromByteUnits(c_abi.max_alignment);
pub const Opaque = ?*anyopaque;
pub fn allocBytes(len: usize) callconv(.c) ?[*]u8 {
    if (len == 0) return null;
    return alloc.rawAlloc(len, wasm_alignment, @returnAddress());
}
pub fn freeBytes(ptr: ?[*]u8, len: usize) callconv(.c) void {
    const p = ptr orelse return;
    if (len == 0) return;
    alloc.rawFree(p[0..len], wasm_alignment, @returnAddress());
}
pub fn allocOpaque() callconv(.c) ?*Opaque {
    const ptr = allocBytes(@sizeOf(Opaque)) orelse return null;
    const result: *Opaque = @ptrCast(@alignCast(ptr));
    result.* = null;
    return result;
}
pub fn freeOpaque(ptr: ?*Opaque) callconv(.c) void {
    freeBytes(@ptrCast(ptr), @sizeOf(Opaque));
}
pub fn takeOpaque(ptr: ?*Opaque) callconv(.c) Opaque {
    const p = ptr orelse return null;
    const result = p.*;
    p.* = null;
    return result;
}
test "Wasm allocation" {
    const ptr = allocBytes(1) orelse return error.OutOfMemory;
    defer freeBytes(ptr, 1);
    try std.testing.expectEqual(
        @as(usize, 0),
        @intFromPtr(ptr) % c_abi.max_alignment,
    );
    ptr[0] = 42;
    try std.testing.expectEqual(@as(u8, 42), ptr[0]);
    try std.testing.expect(allocBytes(0) == null);
    freeBytes(null, 0);
}
test "opaque slots are initialized and reusable" {
    const slot = allocOpaque() orelse return error.OutOfMemory;
    defer freeOpaque(slot);
    try std.testing.expect(takeOpaque(slot) == null);
    var value: u8 = 42;
    slot.* = &value;
    try std.testing.expectEqual(@as(?*anyopaque, &value), takeOpaque(slot));
    try std.testing.expect(takeOpaque(slot) == null);
}
