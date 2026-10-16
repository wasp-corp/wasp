const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
pub const State = struct {
    theme: Theme = .light,
    os: std.Target.Os.Tag = builtin.target.os.tag,
    pub const Theme = enum { light, dark };
    pub fn match(self: State, cond: Conditional) bool {
        switch (cond.key) {
            inline else => |tag| {
                const raw = @field(self, @tagName(tag));
                const value: []const u8 = @tagName(raw);
                return switch (cond.op) {
                    .eq => std.mem.eql(u8, value, cond.value),
                    .ne => !std.mem.eql(u8, value, cond.value),
                };
            },
        }
    }
};
pub const Key = key: {
    const stateInfo = @typeInfo(State).@"struct";
    const TagInt = std.math.IntFittingRange(0, stateInfo.fields.len - 1);
    var names: [stateInfo.fields.len][]const u8 = undefined;
    var values: [stateInfo.fields.len]TagInt = undefined;
    for (stateInfo.fields, &names, &values, 0..) |field, *name, *v, i| {
        name.* = field.name;
        v.* = @intCast(i);
    }
    break :key @Enum(TagInt, .exhaustive, &names, &values);
};
pub const Conditional = struct {
    key: Key,
    op: Op,
    value: []const u8,
    pub const Op = enum { eq, ne };
    pub fn clone(
        self: Conditional,
        alloc: Allocator,
    ) Allocator.Error!Conditional {
        return .{
            .key = self.key,
            .op = self.op,
            .value = try alloc.dupe(u8, self.value),
        };
    }
};
test "conditional enum match" {
    const testing = std.testing;
    const state: State = .{ .theme = .dark };
    try testing.expect(state.match(.{
        .key = .theme,
        .op = .eq,
        .value = "dark",
    }));
    try testing.expect(!state.match(.{
        .key = .theme,
        .op = .ne,
        .value = "dark",
    }));
    try testing.expect(state.match(.{
        .key = .theme,
        .op = .ne,
        .value = "light",
    }));
}
