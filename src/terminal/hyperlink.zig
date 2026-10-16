const std = @import("std");
const Allocator = std.mem.Allocator;
const hash_map = @import("hash_map.zig");
const AutoOffsetHashMap = hash_map.AutoOffsetHashMap;
const pagepkg = @import("page.zig");
const size = @import("size.zig");
const Offset = size.Offset;
const Cell = pagepkg.Cell;
const Page = pagepkg.Page;
const RefCountedSet = @import("ref_counted_set.zig").RefCountedSet;
const Wyhash = std.hash.Wyhash;
const autoHash = std.hash.autoHash;
const autoHashStrat = std.hash.autoHashStrat;
pub const Id = size.HyperlinkCountInt;
pub const Map = AutoOffsetHashMap(Offset(Cell), Id, 80);
pub const Hyperlink = struct {
    id: Hyperlink.Id,
    uri: []const u8,
    pub const Id = union(enum) {
        explicit: []const u8,
        implicit: size.OffsetInt,
    };
    pub fn deinit(self: *const Hyperlink, alloc: Allocator) void {
        alloc.free(self.uri);
        switch (self.id) {
            .implicit => {},
            .explicit => |v| alloc.free(v),
        }
    }
    pub fn dupe(
        self: *const Hyperlink,
        alloc: Allocator,
    ) Allocator.Error!Hyperlink {
        const uri = try alloc.dupe(u8, self.uri);
        errdefer alloc.free(uri);
        const id: Hyperlink.Id = switch (self.id) {
            .implicit => self.id,
            .explicit => |v| .{ .explicit = try alloc.dupe(u8, v) },
        };
        errdefer switch (id) {
            .implicit => {},
            .explicit => |v| alloc.free(v),
        };
        return .{ .id = id, .uri = uri };
    }
};
pub const PageEntry = struct {
    id: PageEntry.Id,
    uri: Offset(u8).Slice,
    pub const Id = union(enum) {
        explicit: Offset(u8).Slice,
        implicit: size.OffsetInt,
    };
    pub fn dupe(
        self: *const PageEntry,
        self_page: *const Page,
        dst_page: *Page,
    ) error{OutOfMemory}!PageEntry {
        var copy = self.*;
        if (self_page == dst_page) return copy;
        {
            const uri = self.uri.slice(self_page.memory);
            const buf = try dst_page.string_alloc.alloc(u8, dst_page.memory, uri.len);
            @memcpy(buf, uri);
            copy.uri = .{
                .offset = size.getOffset(u8, dst_page.memory, &buf[0]),
                .len = uri.len,
            };
        }
        errdefer dst_page.string_alloc.free(
            dst_page.memory,
            copy.uri.slice(dst_page.memory),
        );
        switch (copy.id) {
            .implicit => {}, 
            .explicit => |slice| {
                const id = slice.slice(self_page.memory);
                const buf = try dst_page.string_alloc.alloc(u8, dst_page.memory, id.len);
                @memcpy(buf, id);
                copy.id = .{ .explicit = .{
                    .offset = size.getOffset(u8, dst_page.memory, &buf[0]),
                    .len = id.len,
                } };
            },
        }
        errdefer switch (copy.id) {
            .implicit => {},
            .explicit => |v| dst_page.string_alloc.free(
                dst_page.memory,
                v.slice(dst_page.memory),
            ),
        };
        return copy;
    }
    pub fn hash(self: *const PageEntry, base: anytype) u64 {
        var hasher = Wyhash.init(0);
        autoHash(&hasher, std.meta.activeTag(self.id));
        switch (self.id) {
            .implicit => |v| autoHash(&hasher, v),
            .explicit => |slice| autoHashStrat(
                &hasher,
                slice.slice(base),
                .Deep,
            ),
        }
        autoHashStrat(
            &hasher,
            self.uri.slice(base),
            .Deep,
        );
        return hasher.final();
    }
    pub fn eql(
        self: *const PageEntry,
        self_base: anytype,
        other: *const PageEntry,
        other_base: anytype,
    ) bool {
        if (std.meta.activeTag(self.id) != std.meta.activeTag(other.id)) return false;
        switch (self.id) {
            .implicit => if (self.id.implicit != other.id.implicit) return false,
            .explicit => {
                const self_ptr = self.id.explicit.offset.ptr(self_base);
                const other_ptr = other.id.explicit.offset.ptr(other_base);
                if (!std.mem.eql(
                    u8,
                    self_ptr[0..self.id.explicit.len],
                    other_ptr[0..other.id.explicit.len],
                )) return false;
            },
        }
        return std.mem.eql(
            u8,
            self.uri.slice(self_base),
            other.uri.slice(other_base),
        );
    }
    pub fn free(
        self: *const PageEntry,
        page: *Page,
    ) void {
        const alloc = &page.string_alloc;
        switch (self.id) {
            .implicit => {},
            .explicit => |v| if (v.len > 0) alloc.free(
                page.memory,
                v.slice(page.memory),
            ),
        }
        if (self.uri.len > 0) alloc.free(
            page.memory,
            self.uri.slice(page.memory),
        );
    }
};
pub const Set = RefCountedSet(
    PageEntry,
    Id,
    size.CellCountInt,
    struct {
        page: ?*Page = null,
        src_page: ?*const Page = null,
        pub fn hash(self: *const @This(), link: PageEntry) u64 {
            return link.hash((self.src_page orelse self.page.?).memory);
        }
        pub fn eql(self: *const @This(), a: PageEntry, b: PageEntry) bool {
            return a.eql(
                (self.src_page orelse self.page.?).memory,
                &b,
                self.page.?.memory,
            );
        }
        pub fn deleted(self: *const @This(), link: PageEntry) void {
            link.free(self.page.?);
        }
    },
);
