const std = @import("std");
const builtin = @import("builtin");
pub inline fn move(comptime T: type, dest: []T, source: []const T) void {
    if (builtin.link_libc) {
        _ = memmove(dest.ptr, source.ptr, source.len * @sizeOf(T));
    } else {
        @memmove(dest, source);
    }
}
pub inline fn copy(comptime T: type, dest: []T, source: []const T) void {
    if (builtin.link_libc) {
        _ = memcpy(dest.ptr, source.ptr, source.len * @sizeOf(T));
    } else {
        @memcpy(dest[0..source.len], source);
    }
}
pub inline fn rotateOnce(comptime T: type, items: []T) void {
    const tmp = items[0];
    move(T, items[0 .. items.len - 1], items[1..items.len]);
    items[items.len - 1] = tmp;
}
pub inline fn rotateOnceR(comptime T: type, items: []T) void {
    const tmp = items[items.len - 1];
    move(T, items[1..items.len], items[0 .. items.len - 1]);
    items[0] = tmp;
}
pub inline fn rotateIn(comptime T: type, items: []T, item: T) T {
    const removed = items[0];
    move(T, items[0 .. items.len - 1], items[1..items.len]);
    items[items.len - 1] = item;
    return removed;
}
pub inline fn rotateInR(comptime T: type, items: []T, item: T) T {
    const removed = items[items.len - 1];
    move(T, items[1..items.len], items[0 .. items.len - 1]);
    items[0] = item;
    return removed;
}
extern "c" fn memcpy(*anyopaque, *const anyopaque, usize) *anyopaque;
extern "c" fn memmove(*anyopaque, *const anyopaque, usize) *anyopaque;
