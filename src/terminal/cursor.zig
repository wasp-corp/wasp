const lib = @import("../lib/main.zig");
pub const Style = lib.Enum(.zig, &.{
    "bar",
    "block",
    "underline",
    "block_hollow",
});
