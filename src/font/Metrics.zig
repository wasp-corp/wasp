const Metrics = @This();
const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
cell_width: u32,
cell_height: u32,
cell_baseline: u32,
underline_position: u32,
underline_thickness: u32,
strikethrough_position: u32,
strikethrough_thickness: u32,
overline_position: i32,
overline_thickness: u32,
box_thickness: u32,
cursor_thickness: u32 = 1,
cursor_height: u32,
icon_height: f64,
icon_height_single: f64,
face_width: f64,
face_height: f64,
face_y: f64,
const Minimums = struct {
    const cell_width = 1;
    const cell_height = 1;
    const underline_thickness = 1;
    const strikethrough_thickness = 1;
    const overline_thickness = 1;
    const box_thickness = 1;
    const cursor_thickness = 1;
    const cursor_height = 1;
    const icon_height = 1.0;
    const icon_height_single = 1.0;
    const face_height = 1.0;
    const face_width = 1.0;
};
pub const FaceMetrics = struct {
    px_per_em: f64,
    cell_width: f64,
    ascent: f64,
    descent: f64,
    line_gap: f64,
    underline_position: ?f64 = null,
    underline_thickness: ?f64 = null,
    strikethrough_position: ?f64 = null,
    strikethrough_thickness: ?f64 = null,
    cap_height: ?f64 = null,
    ex_height: ?f64 = null,
    ascii_height: ?f64 = null,
    ic_width: ?f64 = null,
    pub inline fn lineHeight(self: FaceMetrics) f64 {
        return self.ascent - self.descent + self.line_gap;
    }
    pub inline fn capHeight(self: FaceMetrics) f64 {
        if (self.cap_height) |value| if (value > 0) return value;
        return 0.75 * self.ascent;
    }
    pub inline fn exHeight(self: FaceMetrics) f64 {
        if (self.ex_height) |value| if (value > 0) return value;
        return 0.75 * self.capHeight();
    }
    pub inline fn asciiHeight(self: FaceMetrics) f64 {
        if (self.ascii_height) |value| if (value > 0) return value;
        return 1.5 * self.capHeight();
    }
    pub inline fn icWidth(self: FaceMetrics) f64 {
        if (self.ic_width) |value| if (value > 0) return value;
        return @min(self.asciiHeight(), 2 * self.cell_width);
    }
    pub inline fn underlineThickness(self: FaceMetrics) f64 {
        if (self.underline_thickness) |value| if (value > 0) return value;
        return 0.15 * self.exHeight();
    }
    pub inline fn strikethroughThickness(self: FaceMetrics) f64 {
        if (self.strikethrough_thickness) |value| if (value > 0) return value;
        return self.underlineThickness();
    }
    pub inline fn underlinePosition(self: FaceMetrics) f64 {
        return self.underline_position orelse -self.underlineThickness();
    }
    pub inline fn strikethroughPosition(self: FaceMetrics) f64 {
        return self.strikethrough_position orelse (self.exHeight() + self.strikethroughThickness()) * 0.5;
    }
};
pub fn calc(face: FaceMetrics) Metrics {
    const face_width = face.cell_width;
    const face_height = face.lineHeight();
    const cell_width = @round(face_width);
    const cell_height = @round(face_height);
    const half_line_gap = face.line_gap / 2;
    const face_baseline = half_line_gap - face.descent;
    const cell_baseline = @round(face_baseline - (cell_height - face_height) / 2);
    const face_y = cell_baseline - face_baseline;
    const top_to_baseline = cell_height - cell_baseline;
    const cap_height = face.capHeight();
    const underline_thickness = @max(1, @ceil(face.underlineThickness()));
    const strikethrough_thickness = @max(1, @ceil(face.strikethroughThickness()));
    const underline_position = @round(top_to_baseline - face.underlinePosition());
    const strikethrough_position = @round(top_to_baseline - face.strikethroughPosition());
    const icon_height = face_height;
    const icon_height_single = (2 * cap_height + face_height) / 3;
    var result: Metrics = .{
        .cell_width = @intFromFloat(cell_width),
        .cell_height = @intFromFloat(cell_height),
        .cell_baseline = @intFromFloat(cell_baseline),
        .underline_position = @intFromFloat(underline_position),
        .underline_thickness = @intFromFloat(underline_thickness),
        .strikethrough_position = @intFromFloat(strikethrough_position),
        .strikethrough_thickness = @intFromFloat(strikethrough_thickness),
        .overline_position = 0,
        .overline_thickness = @intFromFloat(underline_thickness),
        .box_thickness = @intFromFloat(underline_thickness),
        .cursor_height = @intFromFloat(cell_height),
        .icon_height = icon_height,
        .icon_height_single = icon_height_single,
        .face_width = face_width,
        .face_height = face_height,
        .face_y = face_y,
    };
    result.clamp();
    return result;
}
pub fn apply(self: *Metrics, mods: ModifierSet) void {
    var it = mods.iterator();
    while (it.next()) |entry| {
        switch (entry.key_ptr.*) {
            inline .cell_width,
            .cell_height,
            => |tag| {
                const original = @field(self, @tagName(tag));
                const new = @max(entry.value_ptr.apply(original), 1);
                if (new == original) continue;
                @field(self, @tagName(tag)) = new;
                if (comptime tag == .cell_height) {
                    const original_f64: f64 = @floatFromInt(original);
                    const new_f64: f64 = @floatFromInt(new);
                    const diff = new_f64 - original_f64;
                    const half_diff = diff / 2.0;
                    const position_with_respect_to_center =
                        self.face_y - (original_f64 - self.face_height) / 2;
                    const diff_top, const diff_bottom =
                        if (position_with_respect_to_center > 0)
                            .{ @ceil(half_diff), @floor(half_diff) }
                        else
                            .{ @floor(half_diff), @ceil(half_diff) };
                    addFloatToInt(&self.cell_baseline, diff_bottom);
                    self.face_y += diff_bottom;
                    addFloatToInt(&self.underline_position, diff_top);
                    addFloatToInt(&self.strikethrough_position, diff_top);
                    self.overline_position +|= @as(i32, @intFromFloat(diff_top));
                }
            },
            inline .icon_height => {
                self.icon_height = entry.value_ptr.apply(self.icon_height);
                self.icon_height_single = entry.value_ptr.apply(self.icon_height_single);
            },
            inline else => |tag| {
                @field(self, @tagName(tag)) = entry.value_ptr.apply(@field(self, @tagName(tag)));
            },
        }
    }
    self.clamp();
}
inline fn addFloatToInt(int: *u32, float: f64) void {
    assert(@floor(float) == float);
    int.* =
        if (float >= 0.0)
            int.* +| @as(u32, @intFromFloat(float))
        else
            int.* -| @as(u32, @intFromFloat(-float));
}
fn clamp(self: *Metrics) void {
    inline for (std.meta.fields(Metrics)) |field| {
        if (@hasDecl(Minimums, field.name)) {
            @field(self, field.name) = @max(
                @field(self, field.name),
                @field(Minimums, field.name),
            );
        }
    }
}
pub const ModifierSet = std.AutoHashMapUnmanaged(Key, Modifier);
pub const Modifier = union(enum) {
    percent: f64,
    absolute: i32,
    pub fn parse(input: []const u8) !Modifier {
        if (input.len == 0) return error.InvalidFormat;
        if (input[input.len - 1] == '%') {
            var percent = std.fmt.parseFloat(
                f64,
                input[0 .. input.len - 1],
            ) catch return error.InvalidFormat;
            percent /= 100;
            if (percent <= -1) return .{ .percent = 0 };
            if (percent < 0) return .{ .percent = 1 + percent };
            return .{ .percent = 1 + percent };
        }
        return .{
            .absolute = std.fmt.parseInt(i32, input, 10) catch
                return error.InvalidFormat,
        };
    }
    pub fn parseCLI(input: ?[]const u8) !Modifier {
        return try parse(input orelse return error.ValueRequired);
    }
    pub fn formatEntry(self: Modifier, formatter: anytype) !void {
        var buf: [1024]u8 = undefined;
        switch (self) {
            .percent => |v| {
                try formatter.formatEntry(
                    []const u8,
                    std.fmt.bufPrint(
                        &buf,
                        "{d}%",
                        .{(v - 1) * 100},
                    ) catch return error.OutOfMemory,
                );
            },
            .absolute => |v| {
                try formatter.formatEntry(
                    []const u8,
                    std.fmt.bufPrint(
                        &buf,
                        "{d}",
                        .{v},
                    ) catch return error.OutOfMemory,
                );
            },
        }
    }
    pub fn apply(self: Modifier, v: anytype) @TypeOf(v) {
        const T = @TypeOf(v);
        const Tinfo = @typeInfo(T);
        return switch (comptime Tinfo) {
            .int, .comptime_int => switch (self) {
                .percent => |p| percent: {
                    const p_clamped: f64 = @max(0, p);
                    const v_f64: f64 = @floatFromInt(v);
                    const applied_f64: f64 = @round(v_f64 * p_clamped);
                    const applied_T: T = @intFromFloat(applied_f64);
                    break :percent applied_T;
                },
                .absolute => |abs| absolute: {
                    const v_i64: i64 = @intCast(v);
                    const abs_i64: i64 = @intCast(abs);
                    const applied_i64: i64 = v_i64 +| abs_i64;
                    const clamped_i64: i64 = if (Tinfo.int.signedness == .signed)
                        applied_i64
                    else
                        @max(0, applied_i64);
                    const applied_T: T = std.math.cast(T, clamped_i64) orelse
                        std.math.maxInt(T) * @as(T, @intCast(std.math.sign(clamped_i64)));
                    break :absolute applied_T;
                },
            },
            .float, .comptime_float => return switch (self) {
                .percent => |p| v * @max(0, p),
                .absolute => |abs| v + @as(T, @floatFromInt(abs)),
            },
            else => {},
        };
    }
    pub fn hash(self: Modifier, hasher: anytype) void {
        const autoHash = std.hash.autoHash;
        autoHash(hasher, std.meta.activeTag(self));
        switch (self) {
            .percent => |v| autoHash(hasher, @as(i64, @bitCast(v))),
            .absolute => |v| autoHash(hasher, v),
        }
    }
    test "formatConfig percent" {
        if (comptime @import("terminal_options").artifact == .lib) return;
        const configpkg = @import("../config.zig");
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        const p = try parseCLI("24%");
        try p.formatEntry(configpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = 24%\n", buf.written());
    }
    test "formatConfig absolute" {
        if (comptime @import("terminal_options").artifact == .lib) return;
        const configpkg = @import("../config.zig");
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        const p = try parseCLI("-30");
        try p.formatEntry(configpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = -30\n", buf.written());
    }
};
pub const Key = key: {
    const field_infos = std.meta.fields(Metrics);
    var names: [field_infos.len][]const u8 = undefined;
    var raw_values: [field_infos.len]comptime_int = undefined;
    var count: usize = 0;
    for (field_infos, &names, &raw_values, 0..) |field, *name, *raw, i| {
        if (field.type != u32 and field.type != i32 and field.type != f64) continue;
        name.* = field.name;
        raw.* = i;
        count += 1;
    }
    const TagInt = std.math.IntFittingRange(0, count - 1);
    var values: [count]TagInt = undefined;
    for (raw_values, &values) |raw, *v| v.* = raw;
    break :key @Enum(TagInt, .exhaustive, names[0..count], &values);
};
fn init() Metrics {
    return .{
        .cell_width = 0,
        .cell_height = 0,
        .cell_baseline = 0,
        .underline_position = 0,
        .underline_thickness = 0,
        .strikethrough_position = 0,
        .strikethrough_thickness = 0,
        .overline_position = 0,
        .overline_thickness = 0,
        .box_thickness = 0,
        .cursor_height = 0,
        .icon_height = 0.0,
        .icon_height_single = 0.0,
        .face_width = 0.0,
        .face_height = 0.0,
        .face_y = 0.0,
    };
}
test "Metrics: apply modifiers" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var set: ModifierSet = .{};
    defer set.deinit(alloc);
    try set.put(alloc, .cell_width, .{ .percent = 1.2 });
    var m: Metrics = init();
    m.cell_width = 100;
    m.apply(set);
    try testing.expectEqual(@as(u32, 120), m.cell_width);
}
test "Metrics: adjust cell height smaller" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var set: ModifierSet = .{};
    defer set.deinit(alloc);
    try set.put(alloc, .cell_height, .{ .percent = 0.75 });
    var m: Metrics = init();
    m.face_y = 0.33;
    m.cell_baseline = 50;
    m.underline_position = 55;
    m.strikethrough_position = 30;
    m.overline_position = 0;
    m.cell_height = 100;
    m.face_height = 99.67;
    m.cursor_height = 100;
    m.apply(set);
    try testing.expectEqual(-12.67, m.face_y);
    try testing.expectEqual(@as(u32, 75), m.cell_height);
    try testing.expectEqual(@as(u32, 37), m.cell_baseline);
    try testing.expectEqual(@as(u32, 43), m.underline_position);
    try testing.expectEqual(@as(u32, 18), m.strikethrough_position);
    try testing.expectEqual(@as(i32, -12), m.overline_position);
    try testing.expectEqual(@as(u32, 100), m.cursor_height);
}
test "Metrics: adjust cell height larger" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var set: ModifierSet = .{};
    defer set.deinit(alloc);
    try set.put(alloc, .cell_height, .{ .percent = 1.75 });
    var m: Metrics = init();
    m.face_y = 0.33;
    m.cell_baseline = 50;
    m.underline_position = 55;
    m.strikethrough_position = 30;
    m.overline_position = 0;
    m.cell_height = 100;
    m.face_height = 99.67;
    m.cursor_height = 100;
    m.apply(set);
    try testing.expectEqual(37.33, m.face_y);
    try testing.expectEqual(@as(u32, 175), m.cell_height);
    try testing.expectEqual(@as(u32, 87), m.cell_baseline);
    try testing.expectEqual(@as(u32, 93), m.underline_position);
    try testing.expectEqual(@as(u32, 68), m.strikethrough_position);
    try testing.expectEqual(@as(i32, 38), m.overline_position);
    try testing.expectEqual(@as(u32, 100), m.cursor_height);
}
test "Metrics: adjust icon height by percentage" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var set: ModifierSet = .{};
    defer set.deinit(alloc);
    try set.put(alloc, .icon_height, .{ .percent = 0.75 });
    var m: Metrics = init();
    m.icon_height = 100.0;
    m.icon_height_single = 80.0;
    m.face_height = 100.0;
    m.face_y = 1.0;
    m.apply(set);
    try testing.expectEqual(75.0, m.icon_height);
    try testing.expectEqual(60.0, m.icon_height_single);
    try testing.expectEqual(100.0, m.face_height);
    try testing.expectEqual(1.0, m.face_y);
}
test "Metrics: adjust icon height by absolute pixels" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var set: ModifierSet = .{};
    defer set.deinit(alloc);
    try set.put(alloc, .icon_height, .{ .absolute = -5 });
    var m: Metrics = init();
    m.icon_height = 100.0;
    m.icon_height_single = 80.0;
    m.face_height = 100.0;
    m.face_y = 1.0;
    m.apply(set);
    try testing.expectEqual(95.0, m.icon_height);
    try testing.expectEqual(75.0, m.icon_height_single);
    try testing.expectEqual(100.0, m.face_height);
    try testing.expectEqual(1.0, m.face_y);
}
test "Modifier: parse absolute" {
    const testing = std.testing;
    {
        const m = try Modifier.parse("100");
        try testing.expectEqual(Modifier{ .absolute = 100 }, m);
    }
    {
        const m = try Modifier.parse("-100");
        try testing.expectEqual(Modifier{ .absolute = -100 }, m);
    }
}
test "Modifier: parse percent" {
    const testing = std.testing;
    {
        const m = try Modifier.parse("20%");
        try testing.expectEqual(Modifier{ .percent = 1.2 }, m);
    }
    {
        const m = try Modifier.parse("-20%");
        try testing.expectEqual(Modifier{ .percent = 0.8 }, m);
    }
    {
        const m = try Modifier.parse("0%");
        try testing.expectEqual(Modifier{ .percent = 1 }, m);
    }
}
test "Modifier: percent" {
    const testing = std.testing;
    {
        const m: Modifier = .{ .percent = 0.8 };
        const v: u32 = m.apply(@as(u32, 100));
        try testing.expectEqual(@as(u32, 80), v);
    }
    {
        const m: Modifier = .{ .percent = 1.8 };
        const v: u32 = m.apply(@as(u32, 100));
        try testing.expectEqual(@as(u32, 180), v);
    }
}
test "Modifier: absolute" {
    const testing = std.testing;
    {
        const m: Modifier = .{ .absolute = -100 };
        const v: u32 = m.apply(@as(u32, 100));
        try testing.expectEqual(@as(u32, 0), v);
    }
    {
        const m: Modifier = .{ .absolute = -120 };
        const v: u32 = m.apply(@as(u32, 100));
        try testing.expectEqual(@as(u32, 0), v);
    }
    {
        const m: Modifier = .{ .absolute = 100 };
        const v: u32 = m.apply(@as(u32, 100));
        try testing.expectEqual(@as(u32, 200), v);
    }
}
