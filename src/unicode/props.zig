const std = @import("std");
const uucode = @import("uucode");
pub const Properties = packed struct(u16) {
    width: u2 = 0,
    width_zero_in_grapheme: bool = false,
    grapheme_break: uucode.types.GraphemeBreakNoControl = .other,
    emoji_vs_base: bool = false,
    _padding: u7 = 0,
    pub fn eql(a: Properties, b: Properties) bool {
        return a.width == b.width and
            a.width_zero_in_grapheme == b.width_zero_in_grapheme and
            a.grapheme_break == b.grapheme_break and
            a.emoji_vs_base == b.emoji_vs_base;
    }
    pub fn format(
        self: Properties,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print(
            \\.{{
            \\    .width= {},
            \\    .width_zero_in_grapheme= {},
            \\    .grapheme_break= .{s},
            \\    .emoji_vs_base= {},
            \\}}
        , .{
            self.width,
            self.width_zero_in_grapheme,
            @tagName(self.grapheme_break),
            self.emoji_vs_base,
        });
    }
};
