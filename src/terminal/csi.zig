const lib = @import("lib.zig");
pub const EraseDisplay = enum(u8) {
    below = 0,
    above = 1,
    complete = 2,
    scrollback = 3,
    scroll_complete = 22,
};
pub const EraseLine = enum(u8) {
    right = 0,
    left = 1,
    complete = 2,
    right_unless_pending_wrap = 4,
    _,
};
pub const TabClear = enum(u8) {
    current = 0,
    all = 3,
    _,
};
pub const SizeReportStyle = lib.Enum(
    lib.target,
    &.{
        "csi_14_t",
        "csi_16_t",
        "csi_18_t",
        "csi_19_t",
        "csi_21_t",
    },
);
pub const TitlePushPop = struct {
    op: Op,
    index: u16,
    pub const Op = enum { push, pop };
};
