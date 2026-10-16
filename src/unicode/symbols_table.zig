const lut = @import("lut.zig");
pub const table = table: {
    const generated = @import("symbols_tables").Tables(bool);
    const Tables = lut.Tables(bool);
    break :table Tables{
        .stage1 = &generated.stage1,
        .stage2 = &generated.stage2,
        .stage3 = &generated.stage3,
    };
};
