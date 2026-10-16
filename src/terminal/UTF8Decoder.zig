const UTF8Decoder = @This();
const std = @import("std");
const testing = std.testing;
const log = std.log.scoped(.utf8decoder);
const char_classes = [_]u4{
   0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
   0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
   0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
   0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
   1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,  9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,
   7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,  7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
   8,8,2,2,2,2,2,2,2,2,2,2,2,2,2,2,  2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,
  10,3,3,3,3,3,3,3,3,3,3,3,3,4,3,3, 11,6,6,6,5,8,8,8,8,8,8,8,8,8,8,8,
};
const transitions = [_]u8 {
   0,12,24,36,60,96,84,12,12,12,48,72, 12,12,12,12,12,12,12,12,12,12,12,12,
  12, 0,12,12,12,12,12, 0,12, 0,12,12, 12,24,12,12,12,12,12,24,12,24,12,12,
  12,12,12,12,12,12,12,24,12,12,12,12, 12,24,12,12,12,12,12,12,12,24,12,12,
  12,12,12,12,12,12,12,36,12,36,12,12, 12,36,12,12,12,12,12,36,12,36,12,12,
  12,36,12,12,12,12,12,12,12,12,12,12,
};
const ACCEPT_STATE = 0;
const REJECT_STATE = 12;
accumulator: u21 = 0,
state: u8 = ACCEPT_STATE,
pub inline fn next(self: *UTF8Decoder, byte: u8) struct { ?u21, bool } {
    const char_class = char_classes[byte];
    const initial_state = self.state;
    if (self.state != ACCEPT_STATE) {
        self.accumulator <<= 6;
        self.accumulator |= (byte & 0x3F);
    } else {
        self.accumulator = (@as(u21, 0xFF) >> char_class) & (byte);
    }
    self.state = transitions[self.state + char_class];
    if (self.state == ACCEPT_STATE) {
        defer self.accumulator = 0;
        return .{ self.accumulator, true };
    } else if (self.state == REJECT_STATE) {
        self.accumulator = 0;
        self.state = ACCEPT_STATE;
        return .{ 0xFFFD, initial_state == ACCEPT_STATE };
    } else {
        return .{ null, true };
    }
}
test "ASCII" {
    var d: UTF8Decoder = .{};
    var out: [13]u8 = undefined;
    for ("Hello, World!", 0..) |byte, i| {
        const res = d.next(byte);
        try testing.expect(res[1]);
        if (res[0]) |codepoint| {
            out[i] = @intCast(codepoint);
        }
    }
    try testing.expectEqualStrings(&out, "Hello, World!");
}
test "Well formed utf-8" {
    var d: UTF8Decoder = .{};
    var out: [4]u21 = undefined;
    var i: usize = 0;
    for ("😄✤ÁA") |byte| {
        var consumed = false;
        while (!consumed) {
            const res = d.next(byte);
            consumed = res[1];
            try testing.expect(consumed == true);
            if (res[0]) |codepoint| {
                out[i] = codepoint;
                i += 1;
            }
        }
    }
    try testing.expect(std.mem.eql(u21, &out, &[_]u21{ 0x1F604, 0x2724, 0xC1, 0x41 }));
}
test "Partially invalid utf-8" {
    var d: UTF8Decoder = .{};
    var out: [5]u21 = undefined;
    var i: usize = 0;
    for ("\xF0\x9F😄\xED\xA0\x80") |byte| {
        var consumed = false;
        while (!consumed) {
            const res = d.next(byte);
            consumed = res[1];
            if (res[0]) |codepoint| {
                out[i] = codepoint;
                i += 1;
            }
        }
    }
    try testing.expect(std.mem.eql(u21, &out, &[_]u21{ 0xFFFD, 0x1F604, 0xFFFD, 0xFFFD, 0xFFFD }));
}
