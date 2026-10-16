const Glossary = @This();
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const CircBuf = @import("../../../datastruct/circ_buf.zig").CircBuf;
const FontGlyph = @import("../../../font/Glyph.zig");
const Glyf = @import("../../../font/opentype/glyf.zig").Glyf;
const request = @import("request.zig");
const RegisterReq = request.Request.Register;
const DesignMetrics = FontGlyph.DesignMetrics;
const Constraint = FontGlyph.RenderOptions.Constraint;
pub const max_entries = 1024;
pub const max_glyf_allocation = 64 * 1024; 
pub const empty: Glossary = .{ .entries = .empty };
pub const RegisterError = Allocator.Error || error{OutOfNamespace};
pub const ClearError = error{OutOfNamespace};
entries: std.AutoArrayHashMapUnmanaged(u21, Entry),
pub fn deinit(self: *Glossary, alloc: Allocator) void {
    for (self.entries.values()) |*entry| entry.deinit(alloc);
    self.entries.deinit(alloc);
    self.* = undefined;
}
pub fn register(
    self: *Glossary,
    alloc: Allocator,
    cp: u21,
    entry: Entry,
) RegisterError!void {
    if (!isPrivateUse(cp)) return error.OutOfNamespace;
    const gop = try self.entries.getOrPut(alloc, cp);
    if (gop.found_existing) {
        gop.value_ptr.*.deinit(alloc);
        assert(self.entries.orderedRemove(cp));
        self.entries.putAssumeCapacity(cp, entry);
        return;
    }
    gop.value_ptr.* = entry;
    if (self.entries.count() <= max_entries) return;
    self.entries.values()[0].deinit(alloc);
    self.entries.orderedRemoveAt(0);
}
pub fn delete(
    self: *Glossary,
    alloc: Allocator,
    cp: u21,
) ClearError!void {
    if (!isPrivateUse(cp)) return error.OutOfNamespace;
    const kv = self.entries.fetchOrderedRemove(cp) orelse return;
    var entry = kv.value;
    entry.deinit(alloc);
}
pub fn clearAndFree(self: *Glossary, alloc: Allocator) void {
    for (self.entries.values()) |*entry| entry.deinit(alloc);
    self.entries.deinit(alloc);
    self.entries = .empty;
}
pub fn contains(self: *Glossary, cp: u21) bool {
    return self.entries.contains(cp);
}
pub const Entry = struct {
    pub const Glyph = union(enum) {
        glyf: Glyf.Outline,
    };
    glyph: Glyph,
    design: DesignMetrics,
    width: request.Width,
    constraint: Constraint,
    pub const InitError = RegisterReq.DecodeError || error{
        InvalidOptions,
        UnsupportedFormat,
    };
    pub fn init(alloc: Allocator, req: RegisterReq) Entry.InitError!Entry {
        const fmt = req.get(.fmt) orelse return error.InvalidOptions;
        const design: DesignMetrics = .{
            .units_per_em = req.get(.upm) orelse return error.InvalidOptions,
            .advance_width = req.get(.aw) orelse return error.InvalidOptions,
            .line_height = req.get(.lh) orelse return error.InvalidOptions,
        };
        if (design.units_per_em == 0 or
            design.advance_width == 0 or
            design.line_height == 0) return error.InvalidOptions;
        const width = req.get(.width) orelse return error.InvalidOptions;
        const constraint = try constraintFromRegister(req);
        const glyph: Glyph = switch (fmt) {
            .glyf => .{ .glyf = try req.decodeGlyfPayload(alloc, max_glyf_allocation) },
            .colrv0, .colrv1 => return error.UnsupportedFormat,
        };
        errdefer comptime unreachable;
        return .{
            .glyph = glyph,
            .design = design,
            .width = width,
            .constraint = constraint,
        };
    }
    pub fn deinit(self: *Entry, alloc: Allocator) void {
        switch (self.glyph) {
            .glyf => |*outline| outline.deinit(alloc),
        }
        self.* = undefined;
    }
    fn constraintFromRegister(
        req: RegisterReq,
    ) error{InvalidOptions}!Constraint {
        const size = req.get(.size) orelse return error.InvalidOptions;
        const alignment = req.get(.@"align") orelse return error.InvalidOptions;
        const pad = req.get(.pad) orelse return error.InvalidOptions;
        return .{
            .size = switch (size) {
                .height => .none,
                .advance => .none,
                .contain => .cover,
                .cover => .cover,
                .stretch => .stretch,
            },
            .align_horizontal = switch (alignment.horizontal) {
                .start => .start,
                .center => .center,
                .end => .end,
            },
            .align_vertical = switch (alignment.vertical) {
                .start => .start,
                .center => .center,
                .end => .end,
                .baseline => .start,
            },
            .pad_top = pad.top,
            .pad_right = pad.right,
            .pad_bottom = pad.bottom,
            .pad_left = pad.left,
        };
    }
};
fn isPrivateUse(cp: u21) bool {
    return (cp >= 0xE000 and cp <= 0xF8FF) or
        (cp >= 0xF0000 and cp <= 0xFFFFD) or
        (cp >= 0x100000 and cp <= 0x10FFFD);
}
fn testParseRegister(alloc: Allocator, data: []const u8) !RegisterReq {
    const raw = try alloc.dupe(u8, data);
    errdefer alloc.free(raw);
    const req = try request.Request.parse(alloc, raw);
    switch (req) {
        .register => |reg| return reg,
        else => unreachable,
    }
}
const test_triangle_glyf_payload = "AAEAZABkA4QDhAACAAABAQEB9P5wAyADhPzgAAA=";
fn testRepeatedPointRegisterReq(
    alloc: Allocator,
    end_points: []const u16,
) !RegisterReq {
    assert(end_points.len > 0);
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(alloc);
    const contour_count: u16 = @intCast(end_points.len);
    try decoded.appendSlice(alloc, &.{ @truncate(contour_count >> 8), @truncate(contour_count) });
    try decoded.appendNTimes(alloc, 0, 8);
    for (end_points) |end_point| try decoded.appendSlice(
        alloc,
        &.{ @truncate(end_point >> 8), @truncate(end_point) },
    );
    try decoded.appendSlice(alloc, &.{ 0x00, 0x00 }); 
    var remaining: usize = @as(usize, end_points[end_points.len - 1]) + 1;
    while (remaining > 0) {
        const run = @min(remaining, 256);
        if (run == 1) {
            try decoded.append(alloc, 0x31);
        } else {
            try decoded.appendSlice(alloc, &.{ 0x39, @intCast(run - 1) });
        }
        remaining -= run;
    }
    const Encoder = std.base64.standard.Encoder;
    const payload = try alloc.alloc(u8, Encoder.calcSize(decoded.items.len));
    defer alloc.free(payload);
    const encoded = Encoder.encode(payload, decoded.items);
    const command = try std.fmt.allocPrint(alloc, "r;cp=e000;{s}", .{encoded});
    defer alloc.free(command);
    return try testParseRegister(alloc, command);
}
fn testRegisterReq(alloc: Allocator, cp: u21) !RegisterReq {
    const data = try std.fmt.allocPrint(
        alloc,
        "r;cp={x};upm=2048;aw=1024;lh=1536;width=2;size=stretch;align=end,start;pad=0.1,0.2,0.3,0.4;{s}",
        .{ cp, test_triangle_glyf_payload },
    );
    errdefer alloc.free(data);
    const req = try request.Request.parse(alloc, data);
    switch (req) {
        .register => |reg| return reg,
        else => unreachable,
    }
}
fn testRegisterEntry(alloc: Allocator, cp: u21) !Entry {
    const req = try testRegisterReq(alloc, cp);
    defer alloc.free(req.raw);
    return try Entry.init(alloc, req);
}
test "Entry init decodes glyf payload and applies register fields" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const req = try testRegisterReq(alloc, 0xE000);
    defer alloc.free(req.raw);
    var entry = try Entry.init(alloc, req);
    defer entry.deinit(alloc);
    try testing.expectEqual(@as(u32, 2048), entry.design.units_per_em);
    try testing.expectEqual(@as(u32, 1024), entry.design.advance_width);
    try testing.expectEqual(@as(u32, 1536), entry.design.line_height);
    try testing.expectEqual(request.Width.wide, entry.width);
    try testing.expectEqual(Constraint.Size.stretch, entry.constraint.size);
    try testing.expectEqual(Constraint.Align.end, entry.constraint.align_horizontal);
    try testing.expectEqual(Constraint.Align.start, entry.constraint.align_vertical);
    try testing.expectEqual(@as(f64, 0.1), entry.constraint.pad_top);
    try testing.expectEqual(@as(f64, 0.2), entry.constraint.pad_right);
    try testing.expectEqual(@as(f64, 0.3), entry.constraint.pad_bottom);
    try testing.expectEqual(@as(f64, 0.4), entry.constraint.pad_left);
    try testing.expectEqual(@as(usize, 3), entry.glyph.glyf.points.len);
    try testing.expectEqual(@as(usize, 1), entry.glyph.glyf.contours.len);
}
test "Entry init rejects invalid register payload" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const req = try testParseRegister(alloc, "r;cp=e000;%%%not-base64%%%");
    defer alloc.free(req.raw);
    try testing.expectError(error.MalformedPayload, Entry.init(alloc, req));
}
test "Entry init rejects glyf allocation over limit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const req = try testRepeatedPointRegisterReq(alloc, &.{5461});
    defer alloc.free(req.raw);
    try testing.expectError(error.PayloadTooLarge, Entry.init(alloc, req));
}
test "Entry init accepts largest glyf points allocation under limit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const req = try testRepeatedPointRegisterReq(alloc, &.{ 0, 5460 });
    defer alloc.free(req.raw);
    var entry = try Entry.init(alloc, req);
    defer entry.deinit(alloc);
    try testing.expectEqual(@as(usize, 5461), entry.glyph.glyf.points.len);
    try testing.expectEqual(@as(usize, 2), entry.glyph.glyf.contours.len);
}
test "Glossary register overwrites and moves entry to newest position" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);
    try glossary.register(alloc, 0xE000, try testRegisterEntry(alloc, 0xE000));
    try glossary.register(alloc, 0xE001, try testRegisterEntry(alloc, 0xE001));
    try glossary.register(alloc, 0xE000, try testRegisterEntry(alloc, 0xE000));
    try testing.expectEqual(@as(usize, 2), glossary.entries.count());
    try testing.expectEqual(@as(u21, 0xE001), glossary.entries.keys()[0]);
    try testing.expectEqual(@as(u21, 0xE000), glossary.entries.keys()[1]);
}
test "Glossary register evicts oldest entry" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);
    for (0..max_entries + 1) |i| {
        const cp: u21 = @intCast(0xE000 + i);
        try glossary.register(alloc, cp, try testRegisterEntry(alloc, cp));
    }
    try testing.expectEqual(@as(usize, max_entries), glossary.entries.count());
    try testing.expect(!glossary.entries.contains(0xE000));
    try testing.expect(glossary.entries.contains(0xE001));
    try testing.expect(glossary.entries.contains(0xE000 + max_entries));
}
test "Glossary register rejects non-PUA codepoint" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);
    var entry = try testRegisterEntry(alloc, 0xE000);
    defer entry.deinit(alloc);
    try testing.expectError(error.OutOfNamespace, glossary.register(alloc, 'A', entry));
}
test "Glossary delete removes one PUA slot and ignores empty PUA slot" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);
    try glossary.register(alloc, 0xE000, try testRegisterEntry(alloc, 0xE000));
    try glossary.register(alloc, 0xE001, try testRegisterEntry(alloc, 0xE001));
    try glossary.delete(alloc, 0xE000);
    try testing.expectEqual(@as(usize, 1), glossary.entries.count());
    try testing.expect(!glossary.contains(0xE000));
    try testing.expect(glossary.contains(0xE001));
    try glossary.delete(alloc, 0xE000);
    try testing.expectEqual(@as(usize, 1), glossary.entries.count());
    try testing.expect(glossary.contains(0xE001));
}
test "Glossary delete rejects non-PUA codepoint" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);
    try glossary.register(alloc, 0xE000, try testRegisterEntry(alloc, 0xE000));
    try testing.expectError(error.OutOfNamespace, glossary.delete(alloc, 'A'));
    try testing.expectEqual(@as(usize, 1), glossary.entries.count());
    try testing.expect(glossary.contains(0xE000));
}
test "Glossary clearAndFree removes all slots and remains reusable" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);
    try glossary.register(alloc, 0xE000, try testRegisterEntry(alloc, 0xE000));
    try glossary.register(alloc, 0xE001, try testRegisterEntry(alloc, 0xE001));
    glossary.clearAndFree(alloc);
    try testing.expectEqual(@as(usize, 0), glossary.entries.count());
    try testing.expect(!glossary.contains(0xE000));
    try testing.expect(!glossary.contains(0xE001));
    try glossary.register(alloc, 0xE002, try testRegisterEntry(alloc, 0xE002));
    try testing.expectEqual(@as(usize, 1), glossary.entries.count());
    try testing.expect(glossary.contains(0xE002));
}
test "Glossary contains reports registered slots" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);
    try testing.expect(!glossary.contains(0xE000));
    try glossary.register(alloc, 0xE000, try testRegisterEntry(alloc, 0xE000));
    try testing.expect(glossary.contains(0xE000));
    try testing.expect(!glossary.contains(0xE001));
}
