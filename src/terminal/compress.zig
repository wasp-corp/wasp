pub const lz4 = @import("compress/lz4.zig");
pub const Page = @import("compress/Page.zig");
test {
    @import("std").testing.refAllDecls(@This());
}
