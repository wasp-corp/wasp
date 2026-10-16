pub const wasp = @import("wasp.zig").wasp;
pub const version = @import("wasp.zig").version;
pub const Source = @import("Source.zig");
test {
    @import("std").testing.refAllDecls(@This());
}
