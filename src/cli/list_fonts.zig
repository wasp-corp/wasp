const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("wasp.zig").Action;
const args = @import("args.zig");
const font = @import("../font/root.zig");
const global = @import("../global.zig");
const log = std.log.scoped(.list_fonts);
pub const Options = struct {
    _arena: ?ArenaAllocator = null,
    family: ?[:0]const u8 = null,
    style: ?[:0]const u8 = null,
    bold: bool = false,
    italic: bool = false,
    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc, global.args());
    defer iter.deinit();
    return try runArgs(alloc, &iter);
}
fn runArgs(alloc_gpa: Allocator, argsIter: anytype) !u8 {
    var config: Options = .{};
    defer config.deinit();
    try args.parse(Options, alloc_gpa, &config, argsIter);
    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    if (comptime font.Discover == void) {
        var buffer: [1024]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
        const stderr = &stderr_writer.interface;
        try stderr.print(
            \\Wasp was built without a font discovery mechanism. This is a compile-time
            \\option. Please review how Wasp was built from source, contact the
            \\maintainer to enable a font discovery mechanism, and try again.
        ,
            .{},
        );
        try stderr.flush();
        return 1;
    }
    var buffer: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(global.io(), &buffer);
    const stdout = &stdout_writer.interface;
    var families: std.ArrayList([]const u8) = .empty;
    var map: std.StringHashMap(std.ArrayListUnmanaged([]const u8)) = .init(alloc);
    var font_lib = try font.Library.init(alloc);
    defer font_lib.deinit();
    var disco = font.Discover.init(font_lib);
    defer disco.deinit();
    var disco_it = try disco.discover(alloc, .{
        .family = config.family,
        .style = config.style,
        .bold = config.bold,
        .italic = config.italic,
        .monospace = config.family == null,
    });
    defer disco_it.deinit();
    while (try disco_it.next()) |face| {
        var buf: [1024]u8 = undefined;
        const family_buf = face.familyName(&buf) catch |err| {
            log.err("failed to get font family name: {}", .{err});
            continue;
        };
        const family = try alloc.dupe(u8, family_buf);
        const full_name_buf = face.name(&buf) catch |err| {
            log.err("failed to get font name: {}", .{err});
            continue;
        };
        const full_name = try alloc.dupe(u8, full_name_buf);
        const gop = try map.getOrPut(family);
        if (!gop.found_existing) {
            try families.append(alloc, family);
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(alloc, full_name);
    }
    if (config.family == null) {
        std.mem.sortUnstable([]const u8, families.items, {}, struct {
            fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.order(u8, lhs, rhs) == .lt;
            }
        }.lessThan);
    }
    for (families.items) |family| {
        const list = map.get(family) orelse continue;
        if (list.items.len == 0) continue;
        if (config.family == null) {
            std.mem.sortUnstable([]const u8, list.items, {}, struct {
                fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                    return std.mem.order(u8, lhs, rhs) == .lt;
                }
            }.lessThan);
        }
        try stdout.print("{s}\n", .{family});
        for (list.items) |item| try stdout.print("  {s}\n", .{item});
        try stdout.print("\n", .{});
    }
    try stdout.flush();
    return 0;
}
