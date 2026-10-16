const Generator = @This();
const std = @import("std");
const assert = std.debug.assert;
pub const Error = error{WriteFailed};
ptr: *anyopaque,
nextFn: *const fn (ptr: *anyopaque, *std.Io.Writer, usize) Error!void,
pub fn init(
    pointer: anytype,
    comptime nextFn: fn (ptr: @TypeOf(pointer), *std.Io.Writer, usize) Error!void,
) Generator {
    const Ptr = @TypeOf(pointer);
    assert(@typeInfo(Ptr) == .pointer); 
    assert(@typeInfo(Ptr).pointer.size == .one); 
    assert(@typeInfo(@typeInfo(Ptr).pointer.child) == .@"struct"); 
    const gen = struct {
        fn next(ptr: *anyopaque, writer: *std.Io.Writer, max_len: usize) Error!void {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            try nextFn(self, writer, max_len);
        }
    };
    return .{
        .ptr = pointer,
        .nextFn = gen.next,
    };
}
pub fn next(self: Generator, writer: *std.Io.Writer, max_size: usize) Error!void {
    try self.nextFn(self.ptr, writer, max_size);
}
