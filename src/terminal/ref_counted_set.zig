const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const testing = std.testing;
const size = @import("size.zig");
const Offset = size.Offset;
const OffsetBuf = size.OffsetBuf;
pub fn RefCountedSet(
    comptime T: type,
    comptime IdT: type,
    comptime RefCountInt: type,
    comptime ContextT: type,
) type {
    return struct {
        const Self = @This();
        pub const base_align: std.mem.Alignment = .fromByteUnits(@max(
            @alignOf(Context),
            @alignOf(Layout),
            @alignOf(Item),
            @alignOf(Id),
        ));
        pub const load_factor = 0.8125;
        pub fn capacityForCount(n: usize) usize {
            if (n == 0) return 0;
            return @intFromFloat(@ceil(@as(f64, @floatFromInt(n + 1)) / load_factor));
        }
        pub const Item = struct {
            value: T = undefined,
            meta: Metadata = .{},
            pub const Metadata = struct {
                bucket: Id = std.math.maxInt(Id),
                psl: Id = 0,
                ref: RefCountInt = 0,
            };
        };
        pub const Id = IdT;
        pub const Context = ContextT;
        table: Offset(Id),
        max_psl: Id = 0,
        psl_stats: [32]Id = @splat(0),
        items: Offset(Item),
        living: usize = 0,
        next_id: Id = 1,
        layout: Layout,
        context: Context,
        pub const Layout = struct {
            cap: usize,
            table_cap: usize,
            table_mask: Id,
            table_start: usize,
            items_start: usize,
            total_size: usize,
            pub fn init(cap: usize) Layout {
                assert(cap <= @as(usize, @intCast(std.math.maxInt(Id))) + 1);
                if (cap == 0) return .{
                    .cap = 0,
                    .table_cap = 0,
                    .table_mask = 0,
                    .table_start = 0,
                    .items_start = 0,
                    .total_size = 0,
                };
                const table_cap: usize = std.math.ceilPowerOfTwoAssert(usize, cap);
                const items_cap: usize = @intFromFloat(load_factor * @as(f64, @floatFromInt(table_cap)));
                const table_mask: Id = @intCast((@as(usize, 1) << std.math.log2_int(usize, table_cap)) - 1);
                const table_start = 0;
                const table_end = table_start + table_cap * @sizeOf(Id);
                const items_start = std.mem.alignForward(usize, table_end, @alignOf(Item));
                const items_end = items_start + items_cap * @sizeOf(Item);
                const total_size = items_end;
                return .{
                    .cap = items_cap,
                    .table_cap = table_cap,
                    .table_mask = table_mask,
                    .table_start = table_start,
                    .items_start = items_start,
                    .total_size = total_size,
                };
            }
        };
        pub fn init(base: OffsetBuf, l: Layout, context: Context) Self {
            const table = base.member(Id, l.table_start);
            const items = base.member(Item, l.items_start);
            @memset(table.ptr(base)[0..l.table_cap], 0);
            @memset(items.ptr(base)[0..l.cap], .{});
            return initFromParts(table, items, l, context);
        }
        pub fn initAssumeZeroed(base: OffsetBuf, l: Layout, context: Context) Self {
            return initFromParts(
                base.member(Id, l.table_start),
                base.member(Item, l.items_start),
                l,
                context,
            );
        }
        fn initFromParts(
            table: Offset(Id),
            items: Offset(Item),
            l: Layout,
            context: Context,
        ) Self {
            return .{
                .table = table,
                .items = items,
                .layout = l,
                .context = context,
            };
        }
        pub const AddError = error{
            OutOfMemory,
            NeedsRehash,
        };
        pub fn add(self: *Self, base: anytype, value: T) AddError!Id {
            return try self.addContext(base, value, self.context);
        }
        pub fn addContext(self: *Self, base: anytype, value: T, ctx: Context) AddError!Id {
            const items = self.items.ptr(base);
            while (self.next_id > 1 and items[self.next_id - 1].meta.ref == 0) {
                self.next_id -= 1;
                self.deleteItem(base, self.next_id, ctx);
            }
            if (self.lookupContext(base, value, ctx)) |id| {
                if (comptime @hasDecl(Context, "deleted")) ctx.deleted(value);
                items[id].meta.ref += 1;
                return id;
            }
            if (self.psl_stats[self.psl_stats.len - 1] > 0) {
                @branchHint(.cold);
                return AddError.OutOfMemory;
            }
            if (self.next_id >= self.layout.cap) {
                const rehash_threshold = 0.9;
                if (self.living < @as(Id, @intFromFloat(@as(f64, @floatFromInt(self.layout.cap)) * rehash_threshold))) {
                    return AddError.NeedsRehash;
                }
                return AddError.OutOfMemory;
            }
            const id = self.insert(base, value, self.next_id, ctx);
            items[id].meta.ref += 1;
            assert(items[id].meta.ref == 1);
            self.living += 1;
            if (id == self.next_id) self.next_id += 1;
            return id;
        }
        pub fn addWithId(self: *Self, base: anytype, value: T, id: Id) AddError!?Id {
            return try self.addWithIdContext(base, value, id, self.context);
        }
        pub fn addWithIdContext(self: *Self, base: anytype, value: T, id: Id, ctx: Context) AddError!?Id {
            const items = self.items.ptr(base);
            assert(id > 0);
            if (id < self.next_id) {
                if (items[id].meta.ref == 0) {
                    if (self.lookupContext(base, value, ctx)) |existing_id| {
                        if (comptime @hasDecl(Context, "deleted")) ctx.deleted(value);
                        items[existing_id].meta.ref += 1;
                        return existing_id;
                    }
                    if (self.psl_stats[self.psl_stats.len - 1] > 0) {
                        @branchHint(.cold);
                        return AddError.OutOfMemory;
                    }
                    self.deleteItem(base, id, ctx);
                    const added_id = self.insert(base, value, id, ctx);
                    items[added_id].meta.ref += 1;
                    self.living += 1;
                    return if (added_id == id) null else added_id;
                } else if (ctx.eql(value, items[id].value)) {
                    if (comptime @hasDecl(Context, "deleted")) ctx.deleted(value);
                    items[id].meta.ref += 1;
                    return null;
                }
            }
            return try self.addContext(base, value, ctx);
        }
        pub fn use(self: *const Self, base: anytype, id: Id) void {
            assert(id > 0);
            assert(id < self.layout.cap);
            const items = self.items.ptr(base);
            const item = &items[id];
            assert(item.meta.ref > 0);
            item.meta.ref += 1;
        }
        pub fn useMultiple(self: *const Self, base: anytype, id: Id, n: RefCountInt) void {
            assert(id > 0);
            assert(id < self.layout.cap);
            const items = self.items.ptr(base);
            const item = &items[id];
            assert(item.meta.ref > 0);
            item.meta.ref += n;
        }
        pub fn get(self: *const Self, base: anytype, id: Id) *T {
            assert(id > 0);
            assert(id < self.layout.cap);
            const items = self.items.ptr(base);
            const item = &items[id];
            assert(item.meta.ref > 0);
            return @ptrCast(&item.value);
        }
        pub fn release(self: *Self, base: anytype, id: Id) void {
            assert(id > 0);
            assert(id < self.layout.cap);
            const items = self.items.ptr(base);
            const item = &items[id];
            assert(item.meta.ref > 0);
            item.meta.ref -= 1;
            if (item.meta.ref == 0) self.living -= 1;
        }
        pub fn releaseMultiple(self: *Self, base: anytype, id: Id, n: Id) void {
            assert(id > 0);
            assert(id < self.layout.cap);
            const items = self.items.ptr(base);
            const item = &items[id];
            assert(item.meta.ref >= n);
            item.meta.ref -= n;
            if (item.meta.ref == 0) {
                self.living -= 1;
            }
        }
        pub fn refCount(self: *const Self, base: anytype, id: Id) RefCountInt {
            assert(id > 0);
            assert(id < self.layout.cap);
            const items = self.items.ptr(base);
            const item = &items[id];
            return item.meta.ref;
        }
        pub fn count(self: *const Self) usize {
            return self.living;
        }
        pub const Entry = struct {
            id: Id,
            value_ptr: *T,
        };
        pub const Iterator = struct {
            items: [*]Item,
            id: Id = 1,
            end: Id,
            pub fn next(self: *Iterator) ?Entry {
                while (self.id < self.end) {
                    const id = self.id;
                    self.id += 1;
                    const item = &self.items[id];
                    if (item.meta.ref == 0) continue;
                    return .{
                        .id = id,
                        .value_ptr = &item.value,
                    };
                }
                return null;
            }
        };
        pub fn iterator(self: *const Self, base: anytype) Iterator {
            return .{
                .items = self.items.ptr(base),
                .end = self.next_id,
            };
        }
        fn deleteItem(self: *Self, base: anytype, id: Id, ctx: Context) void {
            const table = self.table.ptr(base);
            const items = self.items.ptr(base);
            const item = items[id];
            if (item.meta.bucket > self.layout.table_cap) return;
            assert(table[item.meta.bucket] == id);
            if (comptime @hasDecl(Context, "deleted")) {
                ctx.deleted(item.value);
            }
            self.psl_stats[item.meta.psl] -= 1;
            table[item.meta.bucket] = 0;
            items[id] = .{};
            var p: Id = item.meta.bucket;
            var n: Id = (p +% 1) & self.layout.table_mask;
            while (table[n] != 0 and items[table[n]].meta.psl > 0) {
                items[table[n]].meta.bucket = p;
                self.psl_stats[items[table[n]].meta.psl] -= 1;
                items[table[n]].meta.psl -= 1;
                self.psl_stats[items[table[n]].meta.psl] += 1;
                table[p] = table[n];
                p = n;
                n = (p +% 1) & self.layout.table_mask;
            }
            while (self.max_psl > 0 and self.psl_stats[self.max_psl] == 0) {
                self.max_psl -= 1;
            }
            table[p] = 0;
            self.assertIntegrity(base, ctx);
        }
        pub fn lookup(self: *const Self, base: anytype, value: T) ?Id {
            return self.lookupContext(base, value, self.context);
        }
        pub fn lookupContext(self: *const Self, base: anytype, value: T, ctx: Context) ?Id {
            if (self.layout.table_cap == 0) {
                @branchHint(.cold);
                return null;
            }
            const table = self.table.ptr(base);
            const items = self.items.ptr(base);
            const hash: u64 = ctx.hash(value);
            for (0..self.max_psl + 1) |i| {
                const p: usize = @intCast((hash +% i) & self.layout.table_mask);
                const id = table[p];
                if (id == 0) {
                    return null;
                }
                const item = items[id];
                if (item.meta.psl < i) {
                    return null;
                }
                if (item.meta.psl == i and
                    item.meta.ref > 0 and
                    ctx.eql(value, item.value))
                {
                    return id;
                }
            }
            return null;
        }
        fn insert(self: *Self, base: anytype, value: T, new_id: Id, ctx: Context) Id {
            if (comptime std.debug.runtime_safety)
                assert(self.lookupContext(base, value, ctx) == null);
            const table = self.table.ptr(base);
            const items = self.items.ptr(base);
            var new_item: Item = .{
                .value = value,
                .meta = .{ .psl = 0, .ref = 0 },
            };
            const hash: u64 = ctx.hash(value);
            var held_id: Id = new_id;
            var held_item: *Item = &new_item;
            var chosen_id: Id = new_id;
            for (0..self.layout.table_cap - 1) |i| {
                const p: Id = @intCast((hash +% i) & self.layout.table_mask);
                const id = table[p];
                if (id == 0) {
                    table[p] = held_id;
                    held_item.meta.bucket = p;
                    self.psl_stats[held_item.meta.psl] += 1;
                    self.max_psl = @max(self.max_psl, held_item.meta.psl);
                    break;
                }
                const item = &items[id];
                if (item.meta.ref == 0) {
                    @branchHint(.unlikely);
                    if (comptime @hasDecl(Context, "deleted")) {
                        ctx.deleted(item.value);
                    }
                    self.psl_stats[item.meta.psl] -= 1;
                    item.* = .{};
                    if (id < new_id) chosen_id = id;
                    table[p] = held_id;
                    held_item.meta.bucket = p;
                    self.psl_stats[held_item.meta.psl] += 1;
                    self.max_psl = @max(self.max_psl, held_item.meta.psl);
                    break;
                }
                if (item.meta.psl < held_item.meta.psl or
                    item.meta.psl == held_item.meta.psl and
                        item.meta.ref < held_item.meta.ref)
                {
                    table[p] = held_id;
                    held_item.meta.bucket = p;
                    self.psl_stats[held_item.meta.psl] += 1;
                    self.max_psl = @max(self.max_psl, held_item.meta.psl);
                    held_id = id;
                    held_item = item;
                    self.psl_stats[item.meta.psl] -= 1;
                }
                held_item.meta.psl += 1;
            }
            table[new_item.meta.bucket] = chosen_id;
            items[chosen_id] = new_item;
            self.assertIntegrity(base, ctx);
            return chosen_id;
        }
        fn assertIntegrity(
            self: *const Self,
            base: anytype,
            ctx: Context,
        ) void {
            if (false and std.debug.runtime_safety) {
                const table = self.table.ptr(base);
                const items = self.items.ptr(base);
                var psl_stats: [32]Id = @splat(0);
                for (items[1..self.next_id], 1..) |item, id| {
                    if (item.meta.bucket < std.math.maxInt(Id)) {
                        assert(table[item.meta.bucket] == id);
                        psl_stats[item.meta.psl] += 1;
                    }
                }
                std.testing.expectEqualSlices(Id, &psl_stats, &self.psl_stats) catch assert(false);
                assert(std.mem.eql(Id, &psl_stats, &self.psl_stats));
                psl_stats = @splat(0);
                for (table[0..self.layout.table_cap], 0..) |id, bucket| {
                    if (id == 0) continue;
                    const item = items[id];
                    if (item.meta.bucket < std.math.maxInt(Id)) {
                        assert(item.meta.bucket == bucket);
                        const hash: u64 = ctx.hash(item.value);
                        const p: usize = @intCast((hash +% item.meta.psl) & self.layout.table_mask);
                        assert(p == bucket);
                        psl_stats[item.meta.psl] += 1;
                    }
                }
                std.testing.expectEqualSlices(Id, &psl_stats, &self.psl_stats) catch assert(false);
            }
        }
    };
}
test "addWithId dead id resolving to an existing value" {
    const alloc = testing.allocator;
    const TestSet = RefCountedSet(
        u32,
        u16,
        u16,
        struct {
            pub fn hash(_: *const @This(), value: u32) u64 {
                return std.hash.int(value);
            }
            pub fn eql(_: *const @This(), a: u32, b: u32) bool {
                return a == b;
            }
        },
    );
    const layout: TestSet.Layout = .init(8);
    const buf = try alloc.alignedAlloc(
        u8,
        TestSet.base_align,
        layout.total_size,
    );
    defer alloc.free(buf);
    var set: TestSet = .init(.init(buf), layout, .{});
    const live = try set.add(buf, 11);
    const released = try set.add(buf, 22);
    const last = try set.add(buf, 33);
    set.release(buf, released);
    try testing.expectEqual(@as(usize, 2), set.count());
    const resolved = (try set.addWithId(buf, 11, released)).?;
    try testing.expectEqual(live, resolved);
    try testing.expectEqual(@as(u16, 2), set.refCount(buf, live));
    try testing.expectEqual(@as(usize, 2), set.count());
    var it = set.iterator(buf);
    var iterated: usize = 0;
    while (it.next()) |_| iterated += 1;
    try testing.expectEqual(set.count(), iterated);
    try testing.expectEqual(@as(?u16, null), try set.addWithId(buf, 44, released));
    try testing.expectEqual(@as(u16, 1), set.refCount(buf, released));
    try testing.expectEqual(@as(usize, 3), set.count());
    _ = last;
}
test "iterator visits live entries in ID order" {
    const alloc = testing.allocator;
    const TestSet = RefCountedSet(
        u32,
        u16,
        u16,
        struct {
            pub fn hash(_: *const @This(), value: u32) u64 {
                return std.hash.int(value);
            }
            pub fn eql(_: *const @This(), a: u32, b: u32) bool {
                return a == b;
            }
        },
    );
    const layout: TestSet.Layout = .init(8);
    const buf = try alloc.alignedAlloc(
        u8,
        TestSet.base_align,
        layout.total_size,
    );
    defer alloc.free(buf);
    var set: TestSet = .init(.init(buf), layout, .{});
    const first = try set.add(buf, 11);
    const released = try set.add(buf, 22);
    const last = try set.add(buf, 33);
    _ = try set.add(buf, 11);
    set.release(buf, released);
    var it = set.iterator(buf);
    const first_entry = it.next().?;
    try testing.expectEqual(first, first_entry.id);
    try testing.expectEqual(@as(u32, 11), first_entry.value_ptr.*);
    const last_entry = it.next().?;
    try testing.expectEqual(last, last_entry.id);
    try testing.expectEqual(@as(u32, 33), last_entry.value_ptr.*);
    try testing.expect(it.next() == null);
}
