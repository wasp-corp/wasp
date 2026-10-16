const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const mem = std.mem;
const Allocator = mem.Allocator;
const Offset = @import("size.zig").Offset;
const OffsetBuf = @import("size.zig").OffsetBuf;
const getOffset = @import("size.zig").getOffset;
pub const default_max_load_percentage: u8 = 100;
pub fn AutoOffsetHashMap(
    comptime K: type,
    comptime V: type,
    comptime max_load_percentage: u8,
) type {
    return OffsetHashMap(K, V, AutoContext(K), max_load_percentage);
}
fn AutoHashMapUnmanaged(
    comptime K: type,
    comptime V: type,
    comptime max_load_percentage: u8,
) type {
    return HashMapUnmanaged(K, V, AutoContext(K), max_load_percentage);
}
fn AutoContext(comptime K: type) type {
    return struct {
        pub const eql = std.hash_map.getAutoEqlFn(K, @This());
        pub fn hash(_: @This(), key: K) u64 {
            if (comptime std.meta.hasUniqueRepresentation(K)) {
                if (comptime builtin.cpu.arch.isWasm() and @sizeOf(K) <= 8) {
                    var x: u64 = 0;
                    @memcpy(
                        std.mem.asBytes(&x)[0..@sizeOf(K)],
                        std.mem.asBytes(&key),
                    );
                    x ^= x >> 33;
                    x *%= 0xff51afd7ed558ccd;
                    x ^= x >> 33;
                    x *%= 0xc4ceb9fe1a85ec53;
                    x ^= x >> 33;
                    return x;
                }
                return @call(
                    .always_inline,
                    std.hash.Wyhash.hash,
                    .{ 0, std.mem.asBytes(&key) },
                );
            }
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHash(&hasher, key);
            return hasher.final();
        }
    };
}
pub fn OffsetHashMap(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
    comptime max_load_percentage: u8,
) type {
    return struct {
        const Self = @This();
        pub const Unmanaged = HashMapUnmanaged(
            K,
            V,
            Context,
            max_load_percentage,
        );
        pub const Layout = Unmanaged.Layout;
        pub const base_align = Unmanaged.base_align;
        metadata: Offset(Unmanaged.Metadata) = .{},
        keys: Offset(K) = .{},
        values: Offset(V) = .{},
        capacity: Unmanaged.Size = 0,
        pub fn layout(cap: Unmanaged.Size) Layout {
            return Unmanaged.layoutForSize(cap);
        }
        pub fn init(buf: OffsetBuf, l: Layout) Self {
            const self = initAssumeZeroed(buf, l);
            var m = self.map(buf);
            m.clearRetainingCapacity();
            return self;
        }
        pub fn initAssumeZeroed(buf: OffsetBuf, l: Layout) Self {
            assert(base_align.check(@intFromPtr(buf.start())));
            return .{
                .metadata = buf.member(Unmanaged.Metadata, l.metadata_start),
                .keys = buf.member(K, l.keys_start),
                .values = buf.member(V, l.vals_start),
                .capacity = l.capacity,
            };
        }
        pub fn map(self: Self, base: anytype) Unmanaged {
            return .{
                .metadata = self.metadata.ptr(base),
                .keys = self.keys.ptr(base),
                .values = self.values.ptr(base),
                .cap = self.capacity,
            };
        }
    };
}
fn HashMapUnmanaged(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
    comptime max_load_percentage: u8,
) type {
    return struct {
        const Self = @This();
        comptime {
            assert(@alignOf(Metadata) == 1);
            assert(max_load_percentage > 0);
            assert(max_load_percentage <= 100);
        }
        const header_align = @alignOf(Header);
        const key_align = if (@sizeOf(K) == 0) 1 else @alignOf(K);
        const val_align = if (@sizeOf(V) == 0) 1 else @alignOf(V);
        const base_align: mem.Alignment = .fromByteUnits(@max(
            header_align,
            key_align,
            val_align,
        ));
        metadata: [*]Metadata,
        keys: [*]K,
        values: [*]V,
        cap: Size,
        pub const Size = u32;
        pub const Hash = u64;
        pub const Entry = struct {
            key_ptr: *K,
            value_ptr: *V,
        };
        pub const KV = struct {
            key: K,
            value: V,
        };
        const Header = struct {
            size: Size,
        };
        const Metadata = packed struct(u8) {
            const FingerPrint = u7;
            fingerprint: FingerPrint = 0,
            used: u1 = 0,
            pub fn isUsed(self: Metadata) bool {
                return self.used == 1;
            }
            pub fn isFree(self: Metadata) bool {
                return @as(u8, @bitCast(self)) == 0;
            }
            pub fn takeFingerprint(hash: Hash) FingerPrint {
                const hash_bits = @typeInfo(Hash).int.bits;
                const fp_bits = @typeInfo(FingerPrint).int.bits;
                return @as(FingerPrint, @truncate(hash >> (hash_bits - fp_bits)));
            }
            pub fn fill(self: *Metadata, fp: FingerPrint) void {
                self.used = 1;
                self.fingerprint = fp;
            }
        };
        comptime {
            assert(@sizeOf(Metadata) == 1);
            assert(@alignOf(Metadata) == 1);
        }
        pub const Iterator = struct {
            hm: *const Self,
            index: Size = 0,
            pub fn next(it: *Iterator) ?Entry {
                assert(it.index <= it.hm.cap);
                if (it.hm.header().size == 0) return null;
                const cap = it.hm.cap;
                const end = it.hm.metadata + cap;
                var metadata = it.hm.metadata + it.index;
                while (metadata != end) : ({
                    metadata += 1;
                    it.index += 1;
                }) {
                    if (metadata[0].isUsed()) {
                        const key = &it.hm.keys[it.index];
                        const value = &it.hm.values[it.index];
                        it.index += 1;
                        return Entry{ .key_ptr = key, .value_ptr = value };
                    }
                }
                return null;
            }
        };
        pub const KeyIterator = FieldIterator(K);
        pub const ValueIterator = FieldIterator(V);
        fn FieldIterator(comptime T: type) type {
            return struct {
                len: usize,
                metadata: [*]const Metadata,
                items: [*]T,
                pub fn next(self: *@This()) ?*T {
                    while (self.len > 0) {
                        self.len -= 1;
                        const used = self.metadata[0].isUsed();
                        const item = &self.items[0];
                        self.metadata += 1;
                        self.items += 1;
                        if (used) {
                            return item;
                        }
                    }
                    return null;
                }
            };
        }
        pub const GetOrPutResult = struct {
            key_ptr: *K,
            value_ptr: *V,
            found_existing: bool,
        };
        pub fn init(buf: OffsetBuf, layout: Layout) Self {
            var map = initAssumeZeroed(buf, layout);
            map.clearRetainingCapacity();
            return map;
        }
        pub fn initAssumeZeroed(buf: OffsetBuf, layout: Layout) Self {
            assert(base_align.check(@intFromPtr(buf.start())));
            return .{
                .metadata = @ptrCast(buf.start() + layout.metadata_start),
                .keys = buf.member(K, layout.keys_start).ptr(buf),
                .values = buf.member(V, layout.vals_start).ptr(buf),
                .cap = layout.capacity,
            };
        }
        pub fn ensureTotalCapacity(self: *Self, new_size: Size) Allocator.Error!void {
            if (new_size > self.header().size) {
                try self.checkCapacity(new_size - self.header().size);
            }
        }
        pub fn ensureUnusedCapacity(self: *Self, additional_size: Size) Allocator.Error!void {
            return ensureTotalCapacity(self, self.count() + additional_size);
        }
        pub fn clearRetainingCapacity(self: *Self) void {
            self.initMetadatas();
            self.header().size = 0;
        }
        pub fn count(self: *const Self) Size {
            return self.header().size;
        }
        fn header(self: *const Self) *Header {
            return @ptrCast(@as([*]Header, @ptrCast(@alignCast(self.metadata))) - 1);
        }
        pub fn capacity(self: *const Self) Size {
            return self.cap;
        }
        pub fn maxLoad(self: *const Self) Size {
            return maxLoadForCapacity(self.cap);
        }
        pub fn iterator(self: *const Self) Iterator {
            return .{ .hm = self };
        }
        pub fn keyIterator(self: *const Self) KeyIterator {
            return .{
                .len = self.cap,
                .metadata = self.metadata,
                .items = self.keys,
            };
        }
        pub fn valueIterator(self: *const Self) ValueIterator {
            return .{
                .len = self.cap,
                .metadata = self.metadata,
                .items = self.values,
            };
        }
        pub fn putNoClobber(self: *Self, key: K, value: V) Allocator.Error!void {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call putNoClobberContext instead.");
            return self.putNoClobberContext(key, value, undefined);
        }
        pub fn putNoClobberContext(self: *Self, key: K, value: V, ctx: Context) Allocator.Error!void {
            assert(!self.containsContext(key, ctx));
            try self.checkCapacity(1);
            self.putAssumeCapacityNoClobberContext(key, value, ctx);
        }
        pub fn putAssumeCapacity(self: *Self, key: K, value: V) void {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call putAssumeCapacityContext instead.");
            return self.putAssumeCapacityContext(key, value, undefined);
        }
        pub fn putAssumeCapacityContext(self: *Self, key: K, value: V, ctx: Context) void {
            const gop = self.getOrPutAssumeCapacityContext(key, ctx);
            gop.value_ptr.* = value;
        }
        pub fn putAssumeCapacityNoClobber(self: *Self, key: K, value: V) void {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call putAssumeCapacityNoClobberContext instead.");
            return self.putAssumeCapacityNoClobberContext(key, value, undefined);
        }
        pub fn putAssumeCapacityNoClobberContext(self: *Self, key: K, value: V, ctx: Context) void {
            assert(!self.containsContext(key, ctx));
            assert(self.header().size < self.cap);
            const hash = ctx.hash(key);
            const mask = self.cap - 1;
            var idx = @as(usize, @truncate(hash & mask));
            var metadata = self.metadata + idx;
            while (metadata[0].isUsed()) {
                idx = (idx + 1) & mask;
                metadata = self.metadata + idx;
            }
            metadata[0].fill(Metadata.takeFingerprint(hash));
            self.keys[idx] = key;
            self.values[idx] = value;
            self.header().size += 1;
        }
        pub fn fetchPut(self: *Self, key: K, value: V) Allocator.Error!?KV {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call fetchPutContext instead.");
            return self.fetchPutContext(key, value, undefined);
        }
        pub fn fetchPutContext(self: *Self, key: K, value: V, ctx: Context) Allocator.Error!?KV {
            const gop = try self.getOrPutContext(key, ctx);
            var result: ?KV = null;
            if (gop.found_existing) {
                result = KV{
                    .key = gop.key_ptr.*,
                    .value = gop.value_ptr.*,
                };
            }
            gop.value_ptr.* = value;
            return result;
        }
        pub fn fetchPutAssumeCapacity(self: *Self, key: K, value: V) ?KV {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call fetchPutAssumeCapacityContext instead.");
            return self.fetchPutAssumeCapacityContext(key, value, undefined);
        }
        pub fn fetchPutAssumeCapacityContext(self: *Self, key: K, value: V, ctx: Context) ?KV {
            const gop = self.getOrPutAssumeCapacityContext(key, ctx);
            var result: ?KV = null;
            if (gop.found_existing) {
                result = KV{
                    .key = gop.key_ptr.*,
                    .value = gop.value_ptr.*,
                };
            }
            gop.value_ptr.* = value;
            return result;
        }
        pub fn fetchRemove(self: *Self, key: K) ?KV {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call fetchRemoveContext instead.");
            return self.fetchRemoveContext(key, undefined);
        }
        pub fn fetchRemoveContext(self: *Self, key: K, ctx: Context) ?KV {
            const idx = self.getIndex(key, ctx) orelse return null;
            const result = KV{
                .key = self.keys[idx],
                .value = self.values[idx],
            };
            self.removeByIndexContext(idx, ctx);
            return result;
        }
        inline fn getIndex(self: Self, key: anytype, ctx: anytype) ?usize {
            if (self.header().size == 0) {
                return null;
            }
            const hash = ctx.hash(key);
            if (@TypeOf(hash) != Hash) {
                @compileError("Context " ++ @typeName(@TypeOf(ctx)) ++ " has a generic hash function that returns the wrong type! " ++ @typeName(Hash) ++ " was expected, but found " ++ @typeName(@TypeOf(hash)));
            }
            const mask = self.cap - 1;
            const fingerprint = Metadata.takeFingerprint(hash);
            var limit = self.cap;
            var idx = @as(usize, @truncate(hash & mask));
            var metadata = self.metadata + idx;
            while (!metadata[0].isFree() and limit != 0) {
                if (metadata[0].isUsed() and metadata[0].fingerprint == fingerprint) {
                    const test_key = &self.keys[idx];
                    const eql = ctx.eql(key, test_key.*);
                    if (@TypeOf(eql) != bool) {
                        @compileError("Context " ++ @typeName(@TypeOf(ctx)) ++ " has a generic eql function that returns the wrong type! bool was expected, but found " ++ @typeName(@TypeOf(eql)));
                    }
                    if (eql) {
                        return idx;
                    }
                }
                limit -= 1;
                idx = (idx + 1) & mask;
                metadata = self.metadata + idx;
            }
            return null;
        }
        pub fn getEntry(self: Self, key: K) ?Entry {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call getEntryContext instead.");
            return self.getEntryContext(key, undefined);
        }
        pub fn getEntryContext(self: Self, key: K, ctx: Context) ?Entry {
            return self.getEntryAdapted(key, ctx);
        }
        pub fn getEntryAdapted(self: Self, key: anytype, ctx: anytype) ?Entry {
            if (self.getIndex(key, ctx)) |idx| {
                return Entry{
                    .key_ptr = &self.keys[idx],
                    .value_ptr = &self.values[idx],
                };
            }
            return null;
        }
        pub fn put(self: *Self, key: K, value: V) Allocator.Error!void {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call putContext instead.");
            return self.putContext(key, value, undefined);
        }
        pub fn putContext(self: *Self, key: K, value: V, ctx: Context) Allocator.Error!void {
            const result = try self.getOrPutContext(key, ctx);
            result.value_ptr.* = value;
        }
        pub fn getKeyPtr(self: Self, key: K) ?*K {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call getKeyPtrContext instead.");
            return self.getKeyPtrContext(key, undefined);
        }
        pub fn getKeyPtrContext(self: Self, key: K, ctx: Context) ?*K {
            return self.getKeyPtrAdapted(key, ctx);
        }
        pub fn getKeyPtrAdapted(self: Self, key: anytype, ctx: anytype) ?*K {
            if (self.getIndex(key, ctx)) |idx| {
                return &self.keys[idx];
            }
            return null;
        }
        pub fn getKey(self: Self, key: K) ?K {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call getKeyContext instead.");
            return self.getKeyContext(key, undefined);
        }
        pub fn getKeyContext(self: Self, key: K, ctx: Context) ?K {
            return self.getKeyAdapted(key, ctx);
        }
        pub fn getKeyAdapted(self: Self, key: anytype, ctx: anytype) ?K {
            if (self.getIndex(key, ctx)) |idx| {
                return self.keys[idx];
            }
            return null;
        }
        pub fn getPtr(self: Self, key: K) ?*V {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call getPtrContext instead.");
            return self.getPtrContext(key, undefined);
        }
        pub fn getPtrContext(self: Self, key: K, ctx: Context) ?*V {
            return self.getPtrAdapted(key, ctx);
        }
        pub fn getPtrAdapted(self: Self, key: anytype, ctx: anytype) ?*V {
            if (self.getIndex(key, ctx)) |idx| {
                return &self.values[idx];
            }
            return null;
        }
        pub fn get(self: Self, key: K) ?V {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call getContext instead.");
            return self.getContext(key, undefined);
        }
        pub fn getContext(self: Self, key: K, ctx: Context) ?V {
            return self.getAdapted(key, ctx);
        }
        pub fn getAdapted(self: Self, key: anytype, ctx: anytype) ?V {
            if (self.getIndex(key, ctx)) |idx| {
                return self.values[idx];
            }
            return null;
        }
        pub fn getOrPut(self: *Self, key: K) Allocator.Error!GetOrPutResult {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call getOrPutContext instead.");
            return self.getOrPutContext(key, undefined);
        }
        pub fn getOrPutContext(self: *Self, key: K, ctx: Context) Allocator.Error!GetOrPutResult {
            const gop = try self.getOrPutContextAdapted(key, ctx);
            if (!gop.found_existing) {
                gop.key_ptr.* = key;
            }
            return gop;
        }
        pub fn getOrPutAdapted(self: *Self, key: anytype, key_ctx: anytype) Allocator.Error!GetOrPutResult {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call getOrPutContextAdapted instead.");
            return self.getOrPutContextAdapted(key, key_ctx);
        }
        pub fn getOrPutContextAdapted(self: *Self, key: anytype, key_ctx: anytype) Allocator.Error!GetOrPutResult {
            self.checkCapacity(1) catch |err| {
                const index = self.getIndex(key, key_ctx) orelse return err;
                return GetOrPutResult{
                    .key_ptr = &self.keys[index],
                    .value_ptr = &self.values[index],
                    .found_existing = true,
                };
            };
            return self.getOrPutAssumeCapacityAdapted(key, key_ctx);
        }
        pub fn getOrPutAssumeCapacity(self: *Self, key: K) GetOrPutResult {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call getOrPutAssumeCapacityContext instead.");
            return self.getOrPutAssumeCapacityContext(key, undefined);
        }
        pub fn getOrPutAssumeCapacityContext(self: *Self, key: K, ctx: Context) GetOrPutResult {
            const result = self.getOrPutAssumeCapacityAdapted(key, ctx);
            if (!result.found_existing) {
                result.key_ptr.* = key;
            }
            return result;
        }
        pub fn getOrPutAssumeCapacityAdapted(self: *Self, key: anytype, ctx: anytype) GetOrPutResult {
            const hash = ctx.hash(key);
            if (@TypeOf(hash) != Hash) {
                @compileError("Context " ++ @typeName(@TypeOf(ctx)) ++ " has a generic hash function that returns the wrong type! " ++ @typeName(Hash) ++ " was expected, but found " ++ @typeName(@TypeOf(hash)));
            }
            const mask = self.cap - 1;
            const fingerprint = Metadata.takeFingerprint(hash);
            var limit = self.cap;
            var idx = @as(usize, @truncate(hash & mask));
            var metadata = self.metadata + idx;
            while (!metadata[0].isFree() and limit != 0) {
                if (metadata[0].isUsed() and metadata[0].fingerprint == fingerprint) {
                    const test_key = &self.keys[idx];
                    const eql = ctx.eql(key, test_key.*);
                    if (@TypeOf(eql) != bool) {
                        @compileError("Context " ++ @typeName(@TypeOf(ctx)) ++ " has a generic eql function that returns the wrong type! bool was expected, but found " ++ @typeName(@TypeOf(eql)));
                    }
                    if (eql) {
                        return GetOrPutResult{
                            .key_ptr = test_key,
                            .value_ptr = &self.values[idx],
                            .found_existing = true,
                        };
                    }
                }
                limit -= 1;
                idx = (idx + 1) & mask;
                metadata = self.metadata + idx;
            }
            assert(metadata[0].isFree());
            metadata[0].fill(fingerprint);
            const new_key = &self.keys[idx];
            const new_value = &self.values[idx];
            new_key.* = undefined;
            new_value.* = undefined;
            self.header().size += 1;
            return GetOrPutResult{
                .key_ptr = new_key,
                .value_ptr = new_value,
                .found_existing = false,
            };
        }
        pub fn getOrPutValue(self: *Self, key: K, value: V) Allocator.Error!Entry {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call getOrPutValueContext instead.");
            return self.getOrPutValueContext(key, value, undefined);
        }
        pub fn getOrPutValueContext(self: *Self, key: K, value: V, ctx: Context) Allocator.Error!Entry {
            const res = try self.getOrPutAdapted(key, ctx);
            if (!res.found_existing) {
                res.key_ptr.* = key;
                res.value_ptr.* = value;
            }
            return Entry{ .key_ptr = res.key_ptr, .value_ptr = res.value_ptr };
        }
        pub fn contains(self: *const Self, key: K) bool {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call containsContext instead.");
            return self.containsContext(key, undefined);
        }
        pub fn containsContext(self: *const Self, key: K, ctx: Context) bool {
            return self.containsAdapted(key, ctx);
        }
        pub fn containsAdapted(self: *const Self, key: anytype, ctx: anytype) bool {
            return self.getIndex(key, ctx) != null;
        }
        fn removeByIndexContext(self: *Self, idx: usize, ctx: Context) void {
            const mask: usize = self.cap - 1;
            const metadata = self.metadata;
            const keys_ptr = self.keys;
            const values_ptr = self.values;
            var hole = idx;
            var j = idx;
            var limit = self.cap - 1;
            while (limit != 0) : (limit -= 1) {
                j = (j + 1) & mask;
                if (metadata[j].isFree()) break;
                const home: usize = @truncate(ctx.hash(keys_ptr[j]) & mask);
                if (((hole -% home) & mask) < ((j -% home) & mask)) {
                    metadata[hole] = metadata[j];
                    keys_ptr[hole] = keys_ptr[j];
                    values_ptr[hole] = values_ptr[j];
                    hole = j;
                }
            }
            metadata[hole] = .{};
            keys_ptr[hole] = undefined;
            values_ptr[hole] = undefined;
            self.header().size -= 1;
        }
        pub fn remove(self: *Self, key: K) bool {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call removeContext instead.");
            return self.removeContext(key, undefined);
        }
        pub fn removeContext(self: *Self, key: K, ctx: Context) bool {
            const idx = self.getIndex(key, ctx) orelse return false;
            self.removeByIndexContext(idx, ctx);
            return true;
        }
        pub fn removeByPtr(self: *Self, key_ptr: *K) void {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call removeByPtrContext instead.");
            return self.removeByPtrContext(key_ptr, undefined);
        }
        pub fn removeByPtrContext(self: *Self, key_ptr: *K, ctx: Context) void {
            const idx = if (@sizeOf(K) > 0)
                (@intFromPtr(key_ptr) - @intFromPtr(self.keys)) / @sizeOf(K)
            else
                0;
            self.removeByIndexContext(idx, ctx);
        }
        fn initMetadatas(self: *Self) void {
            @memset(@as([*]u8, @ptrCast(self.metadata))[0 .. @sizeOf(Metadata) * self.cap], 0);
        }
        fn checkCapacity(self: *Self, new_count: Size) Allocator.Error!void {
            const available = self.maxLoad() - self.header().size;
            if (new_count > available) return error.OutOfMemory;
        }
        fn maxLoadForCapacity(cap: Size) Size {
            if (cap == 0) return 0;
            return @intCast(@divFloor(
                @as(u64, cap) * max_load_percentage,
                100,
            ));
        }
        const Layout = struct {
            total_size: usize,
            metadata_start: usize,
            keys_start: usize,
            vals_start: usize,
            capacity: Size,
        };
        pub fn layoutForCapacity(new_capacity: Size) Layout {
            assert(new_capacity == 0 or std.math.isPowerOfTwo(new_capacity));
            const cap: usize = new_capacity;
            const meta_start = @sizeOf(Header);
            const meta_end = meta_start + cap * @sizeOf(Metadata);
            const keys_start = std.mem.alignForward(usize, meta_end, key_align);
            const keys_end = keys_start + cap * @sizeOf(K);
            const vals_start = std.mem.alignForward(usize, keys_end, val_align);
            const vals_end = vals_start + cap * @sizeOf(V);
            const total_size = std.mem.alignForward(
                usize,
                vals_end,
                base_align.toByteUnits(),
            );
            return .{
                .total_size = total_size,
                .metadata_start = meta_start,
                .keys_start = keys_start,
                .vals_start = vals_start,
                .capacity = new_capacity,
            };
        }
        pub fn layoutForSize(new_size: Size) Layout {
            if (new_size == 0) return layoutForCapacity(0);
            const minimum_capacity = std.math.divCeil(
                u64,
                @as(u64, new_size) * 100,
                max_load_percentage,
            ) catch unreachable;
            const max_capacity = @as(u64, 1) <<
                (@typeInfo(Size).int.bits - 1);
            if (minimum_capacity > max_capacity) {
                return layoutForCapacity(@intCast(max_capacity));
            }
            const raw_capacity = std.math.ceilPowerOfTwo(
                u64,
                minimum_capacity,
            ) catch unreachable;
            return layoutForCapacity(@intCast(raw_capacity));
        }
    };
}
const testing = std.testing;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
fn expectCanonical(map: anytype, ctx: anytype) !void {
    const cap = map.capacity();
    const mask = cap - 1;
    var used: usize = 0;
    for (0..cap) |idx| {
        const metadata = map.metadata[idx];
        if (!metadata.isUsed()) continue;
        used += 1;
        var probe: usize = @truncate(ctx.hash(map.keys[idx]) & mask);
        while (probe != idx) : (probe = (probe + 1) & mask) {
            try expect(map.metadata[probe].isUsed());
        }
    }
    try expectEqual(map.count(), used);
}
test "HashMap basic usage" {
    const Map = AutoHashMapUnmanaged(u32, u32, default_max_load_percentage);
    const alloc = testing.allocator;
    const cap = 16;
    const layout = Map.layoutForCapacity(cap);
    const buf = try alloc.alignedAlloc(u8, Map.base_align, layout.total_size);
    defer alloc.free(buf);
    var map = Map.init(.init(buf), layout);
    const count = 5;
    var i: u32 = 0;
    var total: u32 = 0;
    while (i < count) : (i += 1) {
        try map.put(i, i);
        total += i;
    }
    var sum: u32 = 0;
    var it = map.iterator();
    while (it.next()) |kv| {
        sum += kv.key_ptr.*;
    }
    try expectEqual(total, sum);
    i = 0;
    sum = 0;
    while (i < count) : (i += 1) {
        try expectEqual(i, map.get(i).?);
        sum += map.get(i).?;
    }
    try expectEqual(total, sum);
}
test "HashMap ensureTotalCapacity" {
    const Map = AutoHashMapUnmanaged(i32, i32, default_max_load_percentage);
    const cap = 32;
    const alloc = testing.allocator;
    const layout = Map.layoutForCapacity(cap);
    const buf = try alloc.alignedAlloc(u8, Map.base_align, layout.total_size);
    defer alloc.free(buf);
    var map = Map.init(.init(buf), layout);
    const initial_capacity = map.capacity();
    try testing.expect(initial_capacity >= 20);
    var i: i32 = 0;
    while (i < 20) : (i += 1) {
        try testing.expect(map.fetchPutAssumeCapacity(i, i + 10) == null);
    }
    try testing.expect(initial_capacity == map.capacity());
}
test "HashMap ensureUnusedCapacity with removals" {
    const Map = AutoHashMapUnmanaged(i32, i32, default_max_load_percentage);
    const cap = 32;
    const alloc = testing.allocator;
    const layout = Map.layoutForCapacity(cap);
    const buf = try alloc.alignedAlloc(u8, Map.base_align, layout.total_size);
    defer alloc.free(buf);
    var map = Map.init(.init(buf), layout);
    var i: i32 = 0;
    while (i < 100) : (i += 1) {
        try map.ensureUnusedCapacity(1);
        map.putAssumeCapacity(i, i);
        _ = map.remove(i);
    }
}
test "HashMap clearRetainingCapacity" {
    const Map = AutoHashMapUnmanaged(u32, u32, default_max_load_percentage);
    const cap = 16;
    const alloc = testing.allocator;
    const layout = Map.layoutForCapacity(cap);
    const buf = try alloc.alignedAlloc(u8, Map.base_align, layout.total_size);
    defer alloc.free(buf);
    var map = Map.init(.init(buf), layout);
    map.clearRetainingCapacity();
    try map.put(1, 1);
    try expectEqual(map.get(1).?, 1);
    try expectEqual(map.count(), 1);
    map.clearRetainingCapacity();
    map.putAssumeCapacity(1, 1);
    try expectEqual(map.get(1).?, 1);
    try expectEqual(map.count(), 1);
    const actual_cap = map.capacity();
    try expect(actual_cap > 0);
    map.clearRetainingCapacity();
    map.clearRetainingCapacity();
    try expectEqual(map.count(), 0);
    try expectEqual(map.capacity(), actual_cap);
    try expect(!map.contains(1));
}
test "HashMap ensureTotalCapacity with existing elements" {
    const Map = AutoHashMapUnmanaged(u32, u32, default_max_load_percentage);
    const cap = 8;
    const alloc = testing.allocator;
    const layout = Map.layoutForCapacity(cap);
    const buf = try alloc.alignedAlloc(u8, Map.base_align, layout.total_size);
    defer alloc.free(buf);
    var map = Map.init(.init(buf), layout);
    try map.put(0, 0);
    try expectEqual(map.count(), 1);
    try expectEqual(map.capacity(), cap);
    try testing.expectError(error.OutOfMemory, map.ensureTotalCapacity(65));
    try expectEqual(map.count(), 1);
    try expectEqual(map.capacity(), cap);
}
test "HashMap remove" {
    const Map = AutoHashMapUnmanaged(u32, u32, default_max_load_percentage);
    const cap = 32;
    const alloc = testing.allocator;
    const layout = Map.layoutForCapacity(cap);
    const buf = try alloc.alignedAlloc(u8, Map.base_align, layout.total_size);
    defer alloc.free(buf);
    var map = Map.init(.init(buf), layout);
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        try map.put(i, i);
    }
    i = 0;
    while (i < 16) : (i += 1) {
        if (i % 3 == 0) {
            _ = map.remove(i);
        }
    }
    try expectEqual(map.count(), 10);
    var it = map.iterator();
    while (it.next()) |kv| {
        try expectEqual(kv.key_ptr.*, kv.value_ptr.*);
        try expect(kv.key_ptr.* % 3 != 0);
    }
    i = 0;
    while (i < 16) : (i += 1) {
        if (i % 3 == 0) {
            try expect(!map.contains(i));
        } else {
            try expectEqual(map.get(i).?, i);
        }
    }
}
test "HashMap reverse removes" {
    const Map = AutoHashMapUnmanaged(u32, u32, default_max_load_percentage);
    const cap = 32;
    const alloc = testing.allocator;
    const layout = Map.layoutForCapacity(cap);
    const buf = try alloc.alignedAlloc(u8, Map.base_align, layout.total_size);
    defer alloc.free(buf);
    var map = Map.init(.init(buf), layout);
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        try map.putNoClobber(i, i);
    }
    i = 16;
    while (i > 0) : (i -= 1) {
        _ = map.remove(i - 1);
        try expect(!map.contains(i - 1));
        var j: u32 = 0;
        while (j < i - 1) : (j += 1) {
            try expectEqual(map.get(j).?, j);
        }
    }
    try expectEqual(map.count(), 0);
}
test "HashMap multiple removes on same metadata" {
    const Map = AutoHashMapUnmanaged(u32, u32, default_max_load_percentage);
    const cap = 32;
    const alloc = testing.allocator;
    const layout = Map.layoutForCapacity(cap);
    const buf = try alloc.alignedAlloc(u8, Map.base_align, layout.total_size);
    defer alloc.free(buf);
    var map = Map.init(.init(buf), layout);
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        try map.put(i, i);
    }
    _ = map.remove(7);
    _ = map.remove(15);
    _ = map.remove(14);
    _ = map.remove(13);
    try expect(!map.contains(7));
    try expect(!map.contains(15));
    try expect(!map.contains(14));
    try expect(!map.contains(13));
    i = 0;
    while (i < 13) : (i += 1) {
        if (i == 7) {
            try expect(!map.contains(i));
        } else {
            try expectEqual(map.get(i).?, i);
        }
    }
    try map.put(15, 15);
    try map.put(13, 13);
    try map.put(14, 14);
    try map.put(7, 7);
    i = 0;
    while (i < 16) : (i += 1) {
        try expectEqual(map.get(i).?, i);
    }
}
test "HashMap put and remove loop in random order" {
    const Map = AutoHashMapUnmanaged(u32, u32, default_max_load_percentage);
    const cap = 64;
    const alloc = testing.allocator;
    const layout = Map.layoutForCapacity(cap);
    const buf = try alloc.alignedAlloc(u8, Map.base_align, layout.total_size);
    defer alloc.free(buf);
    var map = Map.init(.init(buf), layout);
    var keys: std.ArrayList(u32) = .empty;
    defer keys.deinit(alloc);
    const size = 32;
    const iterations = 100;
    var i: u32 = 0;
    while (i < size) : (i += 1) {
        try keys.append(alloc, i);
    }
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();
    while (i < iterations) : (i += 1) {
        random.shuffle(u32, keys.items);
        for (keys.items) |key| {
            try map.put(key, key);
        }
        try expectEqual(map.count(), size);
        for (keys.items) |key| {
            _ = map.remove(key);
        }
        try expectEqual(map.count(), 0);
    }
}
test "HashMap put" {
    const Map = AutoHashMapUnmanaged(u32, u32, default_max_load_percentage);
    const cap = 32;
    const alloc = testing.allocator;
    const layout = Map.layoutForCapacity(cap);
    const buf = try alloc.alignedAlloc(u8, Map.base_align, layout.total_size);
    defer alloc.free(buf);
    var map = Map.init(.init(buf), layout);
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        try map.put(i, i);
    }
    i = 0;
    while (i < 16) : (i += 1) {
        try expectEqual(map.get(i).?, i);
    }
    i = 0;
    while (i < 16) : (i += 1) {
        try map.put(i, i * 16 + 1);
    }
    i = 0;
    while (i < 16) : (i += 1) {
        try expectEqual(map.get(i).?, i * 16 + 1);
    }
}
test "HashMap put full load" {
    const Map = AutoHashMapUnmanaged(usize, usize, default_max_load_percentage);
    const cap = 16;
    const alloc = testing.allocator;
    const layout = Map.layoutForCapacity(cap);
    const buf = try alloc.alignedAlloc(u8, Map.base_align, layout.total_size);
    defer alloc.free(buf);
    var map = Map.init(.init(buf), layout);
    for (0..cap) |i| try map.put(i, i);
    for (0..cap) |i| try expectEqual(map.get(i).?, i);
    try testing.expectError(error.OutOfMemory, map.put(cap, cap));
}
test "HashMap putAssumeCapacity" {
    const Map = AutoHashMapUnmanaged(u32, u32, default_max_load_percentage);
    const cap = 32;
    const alloc = testing.allocator;
    const layout = Map.layoutForCapacity(cap);
    const buf = try alloc.alignedAlloc(u8, Map.base_align, layout.total_size);
    defer alloc.free(buf);
    var map = Map.init(.init(buf), layout);
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        map.putAssumeCapacityNoClobber(i, i);
    }
    i = 0;
    var sum = i;
    while (i < 20) : (i += 1) {
        sum += map.getPtr(i).?.*;
    }
    try expectEqual(sum, 190);
    i = 0;
    while (i < 20) : (i += 1) {
        map.putAssumeCapacity(i, 1);
    }
    i = 0;
    sum = i;
    while (i < 20) : (i += 1) {
        sum += map.get(i).?;
    }
    try expectEqual(sum, 20);
}
test "HashMap repeat putAssumeCapacity/remove" {
    const Map = AutoHashMapUnmanaged(u32, u32, default_max_load_percentage);
    const cap = 32;
    const alloc = testing.allocator;
    const layout = Map.layoutForCapacity(cap);
    const buf = try alloc.alignedAlloc(u8, Map.base_align, layout.total_size);
    defer alloc.free(buf);
    var map = Map.init(.init(buf), layout);
    const limit = cap;
    var i: u32 = 0;
    while (i < limit) : (i += 1) {
        map.putAssumeCapacityNoClobber(i, i);
    }
    i = 0;
    while (i < 10 * limit) : (i += 1) {
        try testing.expect(map.remove(i));
        if (i % 2 == 0) {
            map.putAssumeCapacityNoClobber(limit + i, i);
        } else {
            map.putAssumeCapacity(limit + i, i);
        }
    }
    i = 9 * limit;
    while (i < 10 * limit) : (i += 1) {
        try expectEqual(map.get(limit + i), i);
    }
    try expectEqual(map.count(), limit);
}
test "HashMap no-clobber move after remove at max load" {
    const Context = struct {
        pub fn hash(_: @This(), key: u32) u64 {
            return key;
        }
        pub fn eql(_: @This(), a: u32, b: u32) bool {
            return a == b;
        }
    };
    const Map = HashMapUnmanaged(u32, u32, Context, 80);
    const cap = 16;
    const alloc = testing.allocator;
    const layout = Map.layoutForCapacity(cap);
    const buf = try alloc.alignedAlloc(u8, Map.base_align, layout.total_size);
    defer alloc.free(buf);
    var map = Map.init(.init(buf), layout);
    const max_load = map.maxLoad();
    for (0..max_load) |i| {
        map.putAssumeCapacityNoClobberContext(
            @intCast(i),
            @intCast(i),
            .{},
        );
    }
    for (0..100) |i| {
        const src: u32 = @intCast(i);
        const dst: u32 = @intCast(i + max_load);
        try expect(map.removeContext(src, .{}));
        map.putAssumeCapacityNoClobberContext(dst, dst, .{});
        try expectEqual(max_load, map.count());
        try expectEqual(dst, map.getContext(dst, .{}).?);
        try expectCanonical(&map, Context{});
    }
}
test "HashMap removal keeps colliding clusters findable" {
    const Context = struct {
        pub fn hash(_: @This(), _: u32) u64 {
            return 14;
        }
        pub fn eql(_: @This(), a: u32, b: u32) bool {
            return a == b;
        }
    };
    const Map = HashMapUnmanaged(
        u32,
        u32,
        Context,
        default_max_load_percentage,
    );
    const cap = 16;
    const alloc = testing.allocator;
    const layout = Map.layoutForCapacity(cap);
    const buf = try alloc.alignedAlloc(u8, Map.base_align, layout.total_size);
    defer alloc.free(buf);
    var map = Map.init(.init(buf), layout);
    for (0..cap / 2) |i| {
        map.putAssumeCapacityNoClobberContext(@intCast(i), @intCast(i), .{});
    }
    var removed: usize = 0;
    for ([_]u32{ 3, 0, 7, 4, 1, 6, 2, 5 }) |key| {
        try expect(map.removeContext(key, .{}));
        removed += 1;
        for (0..cap / 2) |i| {
            const k: u32 = @intCast(i);
            const v = map.getContext(k, .{});
            if (map.containsContext(k, .{})) {
                try expectEqual(k, v.?);
            }
        }
        try expectEqual(cap / 2 - removed, map.count());
        try expectCanonical(&map, Context{});
    }
}
test "HashMap removal from a completely full table" {
    const Map = AutoHashMapUnmanaged(u32, u32, default_max_load_percentage);
    const cap = 64;
    const alloc = testing.allocator;
    const layout = Map.layoutForCapacity(cap);
    const buf = try alloc.alignedAlloc(u8, Map.base_align, layout.total_size);
    defer alloc.free(buf);
    var map = Map.init(.init(buf), layout);
    for (0..cap) |i| {
        map.putAssumeCapacityNoClobber(@intCast(i), @intCast(i));
    }
    try expectEqual(cap, map.count());
    var expected: usize = cap;
    for (0..cap) |i| {
        if (i % 2 != 0) continue;
        try expect(map.remove(@intCast(i)));
        expected -= 1;
        try expectEqual(expected, map.count());
    }
    for (0..cap) |i| {
        if (i % 2 == 0) {
            try expectEqual(null, map.get(@intCast(i)));
        } else {
            try expectEqual(i, map.get(@intCast(i)).?);
        }
    }
    try expectCanonical(&map, AutoContext(u32){});
}
test "HashMap random operations against an oracle" {
    const Map = AutoHashMapUnmanaged(u32, u32, default_max_load_percentage);
    const cap = 64;
    const alloc = testing.allocator;
    const layout = Map.layoutForCapacity(cap);
    const buf = try alloc.alignedAlloc(u8, Map.base_align, layout.total_size);
    defer alloc.free(buf);
    var map = Map.init(.init(buf), layout);
    var oracle: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer oracle.deinit(alloc);
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const random = prng.random();
    const key_space = cap + cap / 2;
    for (0..20_000) |_| {
        const key = random.uintLessThan(u32, key_space);
        switch (random.uintLessThan(u8, 4)) {
            0, 1 => {
                const value = random.int(u32);
                if (map.put(key, value)) {
                    try oracle.put(alloc, key, value);
                } else |_| {
                    try expect(!oracle.contains(key));
                    try expectEqual(map.count(), map.capacity());
                }
            },
            2 => try expectEqual(
                oracle.remove(key),
                map.remove(key),
            ),
            3 => try expectEqual(oracle.get(key), map.get(key)),
            else => unreachable,
        }
        try expectEqual(oracle.count(), map.count());
    }
    var it = oracle.iterator();
    while (it.next()) |entry| {
        try expectEqual(entry.value_ptr.*, map.get(entry.key_ptr.*).?);
    }
    try expectCanonical(&map, AutoContext(u32){});
}
test "HashMap getOrPut" {
    const Map = AutoHashMapUnmanaged(u32, u32, default_max_load_percentage);
    const cap = 32;
    const alloc = testing.allocator;
    const layout = Map.layoutForCapacity(cap);
    const buf = try alloc.alignedAlloc(u8, Map.base_align, layout.total_size);
    defer alloc.free(buf);
    var map = Map.init(.init(buf), layout);
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        try map.put(i * 2, 2);
    }
    i = 0;
    while (i < 20) : (i += 1) {
        _ = try map.getOrPutValue(i, 1);
    }
    i = 0;
    var sum = i;
    while (i < 20) : (i += 1) {
        sum += map.get(i).?;
    }
    try expectEqual(sum, 30);
}
test "HashMap basic hash map usage" {
    const Map = AutoHashMapUnmanaged(i32, i32, default_max_load_percentage);
    const cap = 32;
    const alloc = testing.allocator;
    const layout = Map.layoutForCapacity(cap);
    const buf = try alloc.alignedAlloc(u8, Map.base_align, layout.total_size);
    defer alloc.free(buf);
    var map = Map.init(.init(buf), layout);
    try testing.expect((try map.fetchPut(1, 11)) == null);
    try testing.expect((try map.fetchPut(2, 22)) == null);
    try testing.expect((try map.fetchPut(3, 33)) == null);
    try testing.expect((try map.fetchPut(4, 44)) == null);
    try map.putNoClobber(5, 55);
    try testing.expect((try map.fetchPut(5, 66)).?.value == 55);
    try testing.expect((try map.fetchPut(5, 55)).?.value == 66);
    const gop1 = try map.getOrPut(5);
    try testing.expect(gop1.found_existing == true);
    try testing.expect(gop1.value_ptr.* == 55);
    gop1.value_ptr.* = 77;
    try testing.expect(map.getEntry(5).?.value_ptr.* == 77);
    const gop2 = try map.getOrPut(99);
    try testing.expect(gop2.found_existing == false);
    gop2.value_ptr.* = 42;
    try testing.expect(map.getEntry(99).?.value_ptr.* == 42);
    const gop3 = try map.getOrPutValue(5, 5);
    try testing.expect(gop3.value_ptr.* == 77);
    const gop4 = try map.getOrPutValue(100, 41);
    try testing.expect(gop4.value_ptr.* == 41);
    try testing.expect(map.contains(2));
    try testing.expect(map.getEntry(2).?.value_ptr.* == 22);
    try testing.expect(map.get(2).? == 22);
    const rmv1 = map.fetchRemove(2);
    try testing.expect(rmv1.?.key == 2);
    try testing.expect(rmv1.?.value == 22);
    try testing.expect(map.fetchRemove(2) == null);
    try testing.expect(map.remove(2) == false);
    try testing.expect(map.getEntry(2) == null);
    try testing.expect(map.get(2) == null);
    try testing.expect(map.remove(3) == true);
}
test "HashMap ensureUnusedCapacity" {
    const Map = AutoHashMapUnmanaged(u64, u64, default_max_load_percentage);
    const cap = 64;
    const alloc = testing.allocator;
    const layout = Map.layoutForCapacity(cap);
    const buf = try alloc.alignedAlloc(u8, Map.base_align, layout.total_size);
    defer alloc.free(buf);
    var map = Map.init(.init(buf), layout);
    try map.ensureUnusedCapacity(32);
    try testing.expectError(error.OutOfMemory, map.ensureUnusedCapacity(cap + 1));
}
test "HashMap removeByPtr" {
    const Map = AutoHashMapUnmanaged(i32, u64, default_max_load_percentage);
    const cap = 64;
    const alloc = testing.allocator;
    const layout = Map.layoutForCapacity(cap);
    const buf = try alloc.alignedAlloc(u8, Map.base_align, layout.total_size);
    defer alloc.free(buf);
    var map = Map.init(.init(buf), layout);
    var i: i32 = undefined;
    i = 0;
    while (i < 10) : (i += 1) {
        try map.put(i, 0);
    }
    try testing.expect(map.count() == 10);
    i = 0;
    while (i < 10) : (i += 1) {
        const key_ptr = map.getKeyPtr(i);
        try testing.expect(key_ptr != null);
        if (key_ptr) |ptr| {
            map.removeByPtr(ptr);
        }
    }
    try testing.expect(map.count() == 0);
}
test "HashMap removeByPtr 0 sized key" {
    const Map = AutoHashMapUnmanaged(i32, u64, default_max_load_percentage);
    const cap = 64;
    const alloc = testing.allocator;
    const layout = Map.layoutForCapacity(cap);
    const buf = try alloc.alignedAlloc(u8, Map.base_align, layout.total_size);
    defer alloc.free(buf);
    var map = Map.init(.init(buf), layout);
    try map.put(0, 0);
    try testing.expect(map.count() == 1);
    const key_ptr = map.getKeyPtr(0);
    try testing.expect(key_ptr != null);
    if (key_ptr) |ptr| {
        map.removeByPtr(ptr);
    }
    try testing.expect(map.count() == 0);
}
test "HashMap repeat fetchRemove" {
    const Map = AutoHashMapUnmanaged(u64, void, default_max_load_percentage);
    const cap = 64;
    const alloc = testing.allocator;
    const layout = Map.layoutForCapacity(cap);
    const buf = try alloc.alignedAlloc(u8, Map.base_align, layout.total_size);
    defer alloc.free(buf);
    var map = Map.init(.init(buf), layout);
    map.putAssumeCapacity(0, {});
    map.putAssumeCapacity(1, {});
    map.putAssumeCapacity(2, {});
    map.putAssumeCapacity(3, {});
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try testing.expect(map.fetchRemove(3) != null);
        map.putAssumeCapacity(3, {});
    }
    try testing.expect(map.get(0) != null);
    try testing.expect(map.get(1) != null);
    try testing.expect(map.get(2) != null);
    try testing.expect(map.get(3) != null);
}
test "OffsetHashMap basic usage" {
    const OffsetMap = AutoOffsetHashMap(
        u32,
        u32,
        default_max_load_percentage,
    );
    const cap = 16;
    const alloc = testing.allocator;
    const layout = OffsetMap.layout(cap);
    const buf = try alloc.alignedAlloc(u8, OffsetMap.base_align, layout.total_size);
    defer alloc.free(buf);
    var offset_map = OffsetMap.init(.init(buf), layout);
    var map = offset_map.map(buf.ptr);
    const count = 5;
    var i: u32 = 0;
    var total: u32 = 0;
    while (i < count) : (i += 1) {
        try map.put(i, i);
        total += i;
    }
    var sum: u32 = 0;
    var it = map.iterator();
    while (it.next()) |kv| {
        sum += kv.key_ptr.*;
    }
    try expectEqual(total, sum);
    i = 0;
    sum = 0;
    while (i < count) : (i += 1) {
        try expectEqual(i, map.get(i).?);
        sum += map.get(i).?;
    }
    try expectEqual(total, sum);
}
test "OffsetHashMap remake map" {
    const OffsetMap = AutoOffsetHashMap(
        u32,
        u32,
        default_max_load_percentage,
    );
    const cap = 16;
    const alloc = testing.allocator;
    const layout = OffsetMap.layout(cap);
    const buf = try alloc.alignedAlloc(u8, OffsetMap.base_align, layout.total_size);
    defer alloc.free(buf);
    var offset_map = OffsetMap.init(.init(buf), layout);
    {
        var map = offset_map.map(buf.ptr);
        try map.put(5, 5);
    }
    {
        var map = offset_map.map(buf.ptr);
        try expectEqual(5, map.get(5).?);
    }
}
test "OffsetHashMap maximum load leaves probe headroom" {
    const OffsetMap = AutoOffsetHashMap(u32, u32, 80);
    const alloc = testing.allocator;
    const requested_size = 16;
    const layout = OffsetMap.layout(requested_size);
    const buf = try alloc.alignedAlloc(
        u8,
        OffsetMap.base_align,
        layout.total_size,
    );
    defer alloc.free(buf);
    const offset_map = OffsetMap.init(.init(buf), layout);
    var map = offset_map.map(buf);
    try testing.expect(map.capacity() > requested_size);
    try testing.expect(map.maxLoad() >= requested_size);
    try testing.expect(map.maxLoad() < map.capacity());
    for (0..requested_size) |i| try map.put(@intCast(i), @intCast(i));
    for (0..100) |_| {
        for (0..requested_size) |i| {
            try testing.expect(map.remove(@intCast(i)));
            try map.put(@intCast(i), @intCast(i));
        }
    }
    for (0..requested_size) |i| {
        try testing.expectEqual(@as(u32, @intCast(i)), map.get(@intCast(i)));
    }
}
test "layoutForCapacity no overflow for large capacity" {
    const Map = AutoHashMapUnmanaged(u64, u64, default_max_load_percentage);
    const large_cap: Map.Size = 1 << 30;
    const layout = Map.layoutForCapacity(large_cap);
    const min_expected: usize = @as(usize, large_cap) * (@sizeOf(u64) + @sizeOf(u64));
    try expect(layout.total_size >= min_expected);
    try expect(layout.keys_start > 0);
    try expect(layout.vals_start > layout.keys_start);
}
