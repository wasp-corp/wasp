const Properties = @import("props.zig").Properties;
const lut = @import("lut.zig");
pub const table = table: {
    const generated = @import("unicode_tables").Tables(Properties);
    const Tables = lut.Tables(Properties);
    break :table Tables{
        .stage1 = &generated.stage1,
        .stage2 = &generated.stage2,
        .stage3 = &generated.stage3,
    };
};
