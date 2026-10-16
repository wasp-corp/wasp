const std = @import("std");
const OptionAsAlt = @import("config.zig").OptionAsAlt;
pub const Layout = enum {
    unknown,
    us_standard,
    us_international,
    pub fn mapAppleId(id: []const u8) ?Layout {
        if (std.mem.eql(u8, id, "com.apple.keylayout.US")) {
            return .us_standard;
        } else if (std.mem.eql(u8, id, "com.apple.keylayout.USInternational")) {
            return .us_international;
        }
        return null;
    }
    pub fn detectOptionAsAlt(self: Layout) OptionAsAlt {
        return switch (self) {
            .us_standard,
            .us_international,
            => .true,
            .unknown,
            => .false,
        };
    }
};
