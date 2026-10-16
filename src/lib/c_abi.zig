const std = @import("std");
const builtin = @import("builtin");
pub const max_alignment: u16 = max: {
    var result: u16 = @alignOf(*anyopaque);
    for (std.enums.values(std.Target.CType)) |c_type| {
        result = @max(result, builtin.target.cTypeAlignment(c_type));
    }
    break :max result;
};
