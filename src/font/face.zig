const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const options = @import("main.zig").options;
const config = @import("../config.zig");
const freetype = @import("face/freetype.zig");
const coretext = @import("face/coretext.zig");
pub const web_canvas = @import("face/web_canvas.zig");
pub const Face = switch (options.backend) {
    .freetype,
    .freetype_windows,
    .fontconfig_freetype,
    .coretext_freetype,
    => freetype.Face,
    .coretext,
    .coretext_harfbuzz,
    .coretext_noshape,
    => coretext.Face,
    .web_canvas => web_canvas.Face,
};
pub const default_dpi = if (builtin.os.tag == .macos) 72 else 96;
pub const FreetypeLoadFlags = if (options.backend.hasFreetype())
    config.FreetypeLoadFlags
else
    void;
pub const freetype_load_flags_default: FreetypeLoadFlags = if (FreetypeLoadFlags != void) .{} else {};
pub const Options = struct {
    size: DesiredSize,
    freetype_load_flags: FreetypeLoadFlags = freetype_load_flags_default,
};
pub const DesiredSize = struct {
    points: f32,
    xdpi: u16 = default_dpi,
    ydpi: u16 = default_dpi,
    pub fn pixels(self: DesiredSize) f32 {
        return (self.points * @as(f32, @floatFromInt(self.ydpi))) / 72;
    }
    pub const getGObjectType = switch (build_config.app_runtime) {
        .gtk => @import("gobject").ext.defineBoxed(
            DesiredSize,
            .{ .name = "WaspFontDesiredSize" },
        ),
        .none => void,
    };
};
pub const Variation = struct {
    id: Id,
    value: f64,
    pub const Id = packed struct(u32) {
        d: u8,
        c: u8,
        b: u8,
        a: u8,
        pub fn init(v: *const [4]u8) Id {
            return .{ .a = v[0], .b = v[1], .c = v[2], .d = v[3] };
        }
        pub fn str(self: Id) [4]u8 {
            return .{ self.a, self.b, self.c, self.d };
        }
    };
};
test {
    @import("std").testing.refAllDecls(@This());
}
test "Variation.Id: wght should be 2003265652" {
    const testing = std.testing;
    const id = Variation.Id.init("wght");
    try testing.expectEqual(@as(u32, 2003265652), @as(u32, @bitCast(id)));
    try testing.expectEqualStrings("wght", &(id.str()));
}
test "Variation.Id: slnt should be 1936486004" {
    const testing = std.testing;
    const id: Variation.Id = .{ .a = 's', .b = 'l', .c = 'n', .d = 't' };
    try testing.expectEqual(@as(u32, 1936486004), @as(u32, @bitCast(id)));
    try testing.expectEqualStrings("slnt", &(id.str()));
}
