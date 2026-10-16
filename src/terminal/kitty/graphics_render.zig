const std = @import("std");
const testing = std.testing;
const terminal = @import("../main.zig");
pub const Placement = struct {
    top_left: terminal.Pin,
    offset_x: u32 = 0,
    offset_y: u32 = 0,
    source_x: u32 = 0,
    source_y: u32 = 0,
    source_width: u32 = 0,
    source_height: u32 = 0,
    dest_width: u32 = 0,
    dest_height: u32 = 0,
};
