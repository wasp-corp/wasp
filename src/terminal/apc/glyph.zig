const std = @import("std");
pub const identifier = "25a1";
pub const request = @import("glyph/request.zig");
pub const response = @import("glyph/response.zig");
pub const execute = @import("glyph/execute.zig").execute;
pub const CommandParser = request.CommandParser;
pub const Request = request.Request;
pub const Response = response.Response;
pub const Glossary = @import("glyph/Glossary.zig");
test {
    std.testing.refAllDecls(@This());
}
