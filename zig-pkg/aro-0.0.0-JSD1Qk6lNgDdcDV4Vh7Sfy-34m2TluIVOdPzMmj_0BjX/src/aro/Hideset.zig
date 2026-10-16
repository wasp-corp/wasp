const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Compilation = @import("Compilation.zig");
const Source = @import("Source.zig");
pub const Hideset = @This();
const Identifier = struct {
    id: Source.Id = .unused,
    byte_offset: u32 = 0,
    fn fromLocation(loc: Source.Location) Identifier {
        return .{
            .id = loc.id,
            .byte_offset = loc.byte_offset,
        };
    }
};
const Item = struct {
    identifier: Identifier = .{},
    len: u32 = 0,
    next: Index = .none,
    const List = std.MultiArrayList(Item);
};
pub const Index = enum(u32) {
    none = std.math.maxInt(u32),
    _,
};
map: std.AutoHashMapUnmanaged(Identifier, Index) = .{},
tmp_map: std.AutoHashMapUnmanaged(Identifier, void) = .{},
linked_list: Item.List = .{},
comp: *const Compilation,
const Iterator = struct {
    slice: Item.List.Slice,
    i: Index,
    fn next(self: *Iterator) ?Item {
        if (self.i == .none) return null;
        defer self.i = self.slice.items(.next)[@intFromEnum(self.i)];
        const identifier = self.slice.items(.identifier)[@intFromEnum(self.i)];
        const length = self.slice.items(.len)[@intFromEnum(self.i)];
        return .{
            .identifier = identifier,
            .len = length,
        };
    }
};
pub fn deinit(self: *Hideset) void {
    self.map.deinit(self.comp.gpa);
    self.tmp_map.deinit(self.comp.gpa);
    self.linked_list.deinit(self.comp.gpa);
}
pub fn clearRetainingCapacity(self: *Hideset) void {
    self.linked_list.shrinkRetainingCapacity(0);
    self.map.clearRetainingCapacity();
}
pub fn clearAndFree(self: *Hideset) void {
    self.map.clearAndFree(self.comp.gpa);
    self.tmp_map.clearAndFree(self.comp.gpa);
    self.linked_list.shrinkAndFree(self.comp.gpa, 0);
}
fn iterator(self: *const Hideset, idx: Index) Iterator {
    return Iterator{
        .slice = self.linked_list.slice(),
        .i = idx,
    };
}
pub fn get(self: *const Hideset, loc: Source.Location) Index {
    return self.map.get(Identifier.fromLocation(loc)) orelse .none;
}
pub fn put(self: *Hideset, loc: Source.Location, value: Index) !void {
    try self.map.put(self.comp.gpa, Identifier.fromLocation(loc), value);
}
fn ensureUnusedCapacity(self: *Hideset, new_size: usize) !void {
    try self.linked_list.ensureUnusedCapacity(self.comp.gpa, new_size);
}
fn createNodeAssumeCapacity(self: *Hideset, identifier: Identifier, length: u32) Index {
    return self.createNodeAssumeCapacityExtra(identifier, .none, length);
}
fn createNodeAssumeCapacityExtra(self: *Hideset, identifier: Identifier, next: Index, length: u32) Index {
    const next_idx = self.linked_list.len;
    self.linked_list.appendAssumeCapacity(.{ .identifier = identifier, .next = next, .len = length });
    return @enumFromInt(next_idx);
}
pub fn prepend(self: *Hideset, loc: Source.Location, length: u32, tail: Index) !Index {
    const new_idx = self.linked_list.len;
    try self.linked_list.append(self.comp.gpa, .{ .identifier = Identifier.fromLocation(loc), .next = tail, .len = length });
    return @enumFromInt(new_idx);
}
pub fn @"union"(self: *Hideset, a: Index, b: Index) !Index {
    if (a == .none) return b;
    if (b == .none) return a;
    self.tmp_map.clearRetainingCapacity();
    var it = self.iterator(b);
    while (it.next()) |item| {
        try self.tmp_map.put(self.comp.gpa, item.identifier, {});
    }
    var head: Index = b;
    try self.ensureUnusedCapacity(self.len(a));
    it = self.iterator(a);
    while (it.next()) |item| {
        if (!self.tmp_map.contains(item.identifier)) {
            head = self.createNodeAssumeCapacityExtra(item.identifier, head, item.len);
        }
    }
    return head;
}
pub fn contains(self: *const Hideset, list: Index, str: []const u8) bool {
    var it = self.iterator(list);
    while (it.next()) |item| {
        const start = item.identifier.byte_offset;
        const end = start + item.len;
        const slice = self.comp.getSource(item.identifier.id).buf[start..end];
        if (mem.eql(u8, str, slice)) return true;
    }
    return false;
}
fn len(self: *const Hideset, list: Index) usize {
    const nexts = self.linked_list.items(.next);
    var cur = list;
    var count: usize = 0;
    while (cur != .none) : (count += 1) {
        cur = nexts[@intFromEnum(cur)];
    }
    return count;
}
pub fn intersection(self: *Hideset, a: Index, b: Index) !Index {
    if (a == .none or b == .none) return .none;
    self.tmp_map.clearRetainingCapacity();
    var cur: Index = .none;
    var head: Index = .none;
    var it = self.iterator(a);
    var a_len: usize = 0;
    while (it.next()) |item| : (a_len += 1) {
        try self.tmp_map.put(self.comp.gpa, item.identifier, {});
    }
    try self.ensureUnusedCapacity(@min(a_len, self.len(b)));
    it = self.iterator(b);
    while (it.next()) |item| {
        if (self.tmp_map.contains(item.identifier)) {
            const new_idx = self.createNodeAssumeCapacity(item.identifier, item.len);
            if (head == .none) {
                head = new_idx;
            }
            if (cur != .none) {
                self.linked_list.items(.next)[@intFromEnum(cur)] = new_idx;
            }
            cur = new_idx;
        }
    }
    return head;
}
