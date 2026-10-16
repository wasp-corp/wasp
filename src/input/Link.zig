const Link = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const oni = @import("oniguruma");
const Mods = @import("key.zig").Mods;
regex: []const u8,
action: Action,
highlight: Highlight,
pub const Action = union(enum) {
    open: void,
    _open_osc8: void,
};
pub const Highlight = union(enum) {
    always: void,
    hover: void,
    always_mods: Mods,
    hover_mods: Mods,
};
pub fn oniRegex(self: *const Link) !oni.Regex {
    return try oni.Regex.init(
        self.regex,
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
}
pub fn clone(self: *const Link, alloc: Allocator) Allocator.Error!Link {
    return .{
        .regex = try alloc.dupe(u8, self.regex),
        .action = self.action,
        .highlight = self.highlight,
    };
}
pub fn equal(self: *const Link, other: *const Link) bool {
    return std.meta.eql(self.action, other.action) and
        std.meta.eql(self.highlight, other.highlight) and
        std.mem.eql(u8, self.regex, other.regex);
}
