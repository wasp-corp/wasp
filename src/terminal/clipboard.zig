const std = @import("std");
pub const Location = enum(c_int) {
    standard = 0,
    selection = 1,
    primary = 2,
    _,
};
pub fn isTextMime(mime: []const u8) bool {
    const names: []const []const u8 = &.{
        "text/plain",
        "text/plain;charset=utf-8",
        "UTF8_STRING",
        "TEXT",
        "STRING",
    };
    for (names) |n| if (std.mem.eql(u8, mime, n)) return true;
    return false;
}
pub const Content = struct {
    mime: []const u8,
    data: []const u8,
};
pub const MimeReader = struct {
    ctx: ?*anyopaque = null,
    read_fn: *const fn (
        ctx: ?*anyopaque,
        mime: []const u8,
        sink: *std.Io.Writer,
    ) Error!void,
    pub const Error = error{
        ReadFailed,
    } || std.Io.Writer.Error;
    pub fn read(
        self: MimeReader,
        mime: []const u8,
        sink: *std.Io.Writer,
    ) Error!void {
        return self.read_fn(self.ctx, mime, sink);
    }
};
pub const Write = struct {
    location: Location,
    contents: []const Content,
    name: []const u8,
    granted: bool,
    can_remember: bool,
    reply_ctx: *anyopaque,
    reply_fn: *const fn (*anyopaque, Result) void,
    pub fn reply(self: Write, result: Result) void {
        self.reply_fn(self.reply_ctx, result);
    }
    pub const Status = enum(c_int) {
        success = 0,
        denied = 1,
        unsupported = 2,
        busy = 3,
        invalid_data = 4,
        io_error = 5,
        _,
    };
    pub const Result = union(enum) {
        denied,
        unsupported,
        busy,
        invalid_data,
        io_error,
        success: Success,
        pub const Success = struct {
            remember: bool = false,
        };
    };
};
pub const Read = struct {
    location: Location,
    mimes: []const []const u8,
    list: bool,
    name: []const u8,
    granted: bool,
    can_remember: bool,
    reply_ctx: *anyopaque,
    reply_fn: *const fn (*anyopaque, Result) void,
    pub fn reply(self: Read, result: Result) void {
        self.reply_fn(self.reply_ctx, result);
    }
    pub const Status = enum(c_int) {
        success = 0,
        denied = 1,
        unsupported = 2,
        busy = 3,
        io_error = 4,
        _,
    };
    pub const Result = union(enum) {
        denied,
        unsupported,
        busy,
        io_error,
        success: Success,
        pub const Success = struct {
            contents: []const Content = &.{},
            available: []const []const u8 = &.{},
            remember: bool = false,
        };
    };
};
test isTextMime {
    const testing = std.testing;
    try testing.expect(isTextMime("text/plain"));
    try testing.expect(isTextMime("UTF8_STRING"));
    try testing.expect(!isTextMime("image/png"));
    try testing.expect(!isTextMime("."));
}
