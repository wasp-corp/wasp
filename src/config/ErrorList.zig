const ErrorList = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Error = struct {
    message: [:0]const u8,
};
list: std.ArrayListUnmanaged(Error) = .{},
pub fn empty(self: ErrorList) bool {
    return self.list.items.len == 0;
}
pub fn add(self: *ErrorList, alloc: Allocator, err: Error) !void {
    try self.list.append(alloc, err);
}
