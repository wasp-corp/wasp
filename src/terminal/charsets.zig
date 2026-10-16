const std = @import("std");
const build_options = @import("terminal_options");
const assert = @import("../quirks.zig").inlineAssert;
const LibEnum = @import("../lib/enum.zig").Enum;
pub const Slots = LibEnum(
    if (build_options.c_abi) .c else .zig,
    &.{ "G0", "G1", "G2", "G3" },
);
pub const ActiveSlot = LibEnum(
    if (build_options.c_abi) .c else .zig,
    &.{ "GL", "GR" },
);
pub const Charset = LibEnum(
    if (build_options.c_abi) .c else .zig,
    &.{ "utf8", "ascii", "british", "dec_special" },
);
pub inline fn table(set: Charset) []const u16 {
    return switch (set) {
        .british => &british,
        .dec_special => &dec_special,
        .utf8 => unreachable,
        .ascii => &ascii,
    };
}
const ascii = initTable();
const british = british: {
    var tbl = initTable();
    tbl[0x23] = 0x00a3;
    break :british tbl;
};
const dec_special = tech: {
    var tbl = initTable();
    tbl[0x60] = 0x25C6;
    tbl[0x61] = 0x2592;
    tbl[0x62] = 0x2409;
    tbl[0x63] = 0x240C;
    tbl[0x64] = 0x240D;
    tbl[0x65] = 0x240A;
    tbl[0x66] = 0x00B0;
    tbl[0x67] = 0x00B1;
    tbl[0x68] = 0x2424;
    tbl[0x69] = 0x240B;
    tbl[0x6a] = 0x2518;
    tbl[0x6b] = 0x2510;
    tbl[0x6c] = 0x250C;
    tbl[0x6d] = 0x2514;
    tbl[0x6e] = 0x253C;
    tbl[0x6f] = 0x23BA;
    tbl[0x70] = 0x23BB;
    tbl[0x71] = 0x2500;
    tbl[0x72] = 0x23BC;
    tbl[0x73] = 0x23BD;
    tbl[0x74] = 0x251C;
    tbl[0x75] = 0x2524;
    tbl[0x76] = 0x2534;
    tbl[0x77] = 0x252C;
    tbl[0x78] = 0x2502;
    tbl[0x79] = 0x2264;
    tbl[0x7a] = 0x2265;
    tbl[0x7b] = 0x03C0;
    tbl[0x7c] = 0x2260;
    tbl[0x7d] = 0x00A3;
    tbl[0x7e] = 0x00B7;
    break :tech tbl;
};
const table_len = std.math.maxInt(u8) + 1;
fn initTable() [table_len]u16 {
    var result: [table_len]u16 = undefined;
    var i: usize = 0;
    while (i < table_len) : (i += 1) result[i] = @intCast(i);
    assert(i == table_len);
    return result;
}
test {
    const testing = std.testing;
    const info = @typeInfo(Charset).@"enum";
    inline for (info.fields) |field| {
        if (@field(Charset, field.name) == .utf8) continue;
        const tbl = table(@field(Charset, field.name));
        try testing.expectEqual(@as(usize, 256), tbl.len);
    }
}
