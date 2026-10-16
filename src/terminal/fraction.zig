const std = @import("std");
const assert = std.debug.assert;
pub fn parse(value: []const u8) ?f64 {
    var v = value;
    var negative = false;
    if (v.len > 0) switch (v[0]) {
        '+' => v = v[1..],
        '-' => {
            negative = true;
            v = v[1..];
        },
        else => {},
    };
    var i: usize = 0;
    const int_part: f64 = int_part: {
        var int_part: f64 = 0;
        while (i < v.len and v[i] != '.') : (i += 1) {
            const d = v[i];
            if (d < '0' or d > '9') return null;
            int_part = int_part * 10 + @as(f64, @floatFromInt(d - '0'));
        }
        break :int_part int_part;
    };
    var digits: usize = i;
    var frac: u64 = 0;
    var scale: u64 = 1;
    if (i < v.len) {
        assert(v[i] == '.');
        i += 1;
        while (i < v.len) : (i += 1) {
            const d = v[i];
            if (d < '0' or d > '9') return null;
            if (scale < 1_000_000_000_000_000) {
                frac = frac * 10 + (d - '0');
                scale *= 10;
            }
            digits += 1;
        }
    }
    if (digits == 0) return null;
    const magnitude = int_part +
        @as(f64, @floatFromInt(frac)) / @as(f64, @floatFromInt(scale));
    const result = if (negative) -magnitude else magnitude;
    if (!(result >= 0 and result <= 1)) return null;
    return result;
}
test parse {
    const testing = std.testing;
    try testing.expectEqual(0, parse("0").?);
    try testing.expectEqual(1, parse("1").?);
    try testing.expectEqual(0.5, parse("0.5").?);
    try testing.expectEqual(0.25, parse("0.25").?);
    try testing.expectEqual(1, parse("1.0").?);
    try testing.expectEqual(1, parse("1.000000").?);
    try testing.expectEqual(0, parse("0.0").?);
    try testing.expectEqual(0.5, parse(".5").?);
    try testing.expectEqual(1, parse("1.").?);
    try testing.expectEqual(0, parse("00.00").?);
    try testing.expectEqual(0.5, parse("+0.5").?);
    try testing.expectEqual(0, parse("-0").?);
    try testing.expectEqual(0, parse("-0.000").?);
    try testing.expectEqual(null, parse("-0.5"));
    try testing.expectEqual(null, parse("-1"));
    try testing.expectEqual(
        std.fmt.parseFloat(f64, "0.3") catch unreachable,
        parse("0.3").?,
    );
    try testing.expectEqual(
        std.fmt.parseFloat(f64, "0.123456789012345") catch unreachable,
        parse("0.123456789012345").?,
    );
    try testing.expectEqual(
        parse("0.333333333333333").?,
        parse("0." ++ "3" ** 400).?,
    );
    try testing.expectEqual(null, parse("1.0000001"));
    try testing.expectEqual(null, parse("2"));
    try testing.expectEqual(null, parse("255"));
    try testing.expectEqual(null, parse("1" ** 400));
    try testing.expectEqual(null, parse(""));
    try testing.expectEqual(null, parse("."));
    try testing.expectEqual(null, parse("+"));
    try testing.expectEqual(null, parse("-"));
    try testing.expectEqual(null, parse("+."));
    try testing.expectEqual(null, parse("abc"));
    try testing.expectEqual(null, parse("0.5x"));
    try testing.expectEqual(null, parse("0x0.8"));
    try testing.expectEqual(null, parse("0..5"));
    try testing.expectEqual(null, parse("0.5.5"));
    try testing.expectEqual(null, parse(" 0.5"));
    try testing.expectEqual(null, parse("0.5 "));
    try testing.expectEqual(null, parse("1e-1"));
    try testing.expectEqual(null, parse("nan"));
    try testing.expectEqual(null, parse("inf"));
}
