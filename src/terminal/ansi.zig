const lib = @import("lib.zig");
pub const C0 = enum(u7) {
    NUL = 0x00,
    SOH = 0x01,
    STX = 0x02,
    ENQ = 0x05,
    BEL = 0x07,
    BS = 0x08,
    HT = 0x09,
    LF = 0x0A,
    VT = 0x0B,
    FF = 0x0C,
    CR = 0x0D,
    SO = 0x0E,
    SI = 0x0F,
    _,
};
pub const RenditionAspect = enum(u16) {
    default = 0,
    bold = 1,
    default_fg = 39,
    default_bg = 49,
    _,
};
pub const CursorStyle = lib.Enum(
    lib.target,
    &.{
        "default",
        "blinking_block",
        "steady_block",
        "blinking_underline",
        "steady_underline",
        "blinking_bar",
        "steady_bar",
    },
);
pub const StatusLineType = enum(u16) {
    none = 0,
    indicator = 1,
    host_writable = 2,
    _,
};
pub const StatusDisplay = lib.Enum(
    lib.target,
    &.{
        "main",
        "status_line",
    },
);
pub const ModifyKeyFormat = lib.Enum(
    lib.target,
    &.{
        "legacy",
        "cursor_keys",
        "function_keys",
        "other_keys_none",
        "other_keys_numeric_except",
        "other_keys_numeric",
    },
);
pub const ProtectedMode = lib.Enum(
    lib.target,
    &.{
        "off",
        "iso", 
        "dec", 
    },
);
