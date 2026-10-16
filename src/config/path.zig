const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const cli = @import("../cli.zig");
const internal_os = @import("../os/root.zig");
const formatterpkg = @import("formatter.zig");
const global = @import("../global.zig");
const log = std.log.scoped(.config);
pub const ParseError = error{ValueRequired} || Allocator.Error;
pub const Path = union(enum) {
    optional: [:0]const u8,
    required: [:0]const u8,
    pub fn len(self: Path) usize {
        return switch (self) {
            inline else => |path| path.len,
        };
    }
    pub fn equal(self: Path, other: Path) bool {
        return std.meta.eql(self, other);
    }
    pub const C = extern struct {
        path: [*:0]const u8,
        optional: bool,
    };
    pub fn cval(self: Path) C {
        return switch (self) {
            .optional => |path| .{ .path = path.ptr, .optional = true },
            .required => |path| .{ .path = path.ptr, .optional = false },
        };
    }
    pub fn parse(
        arena_alloc: Allocator,
        input: ?[]const u8,
    ) ParseError!?Path {
        var value = input orelse return error.ValueRequired;
        if (value.len == 0) return null;
        const optional = if (value[0] == '?') opt: {
            value = value[1..];
            break :opt true;
        } else false;
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }
        if (optional)
            return .{ .optional = try arena_alloc.dupeZ(u8, value) }
        else
            return .{ .required = try arena_alloc.dupeZ(u8, value) };
    }
    pub fn parseCLI(
        self: *Path,
        arena_alloc: Allocator,
        input: ?[]const u8,
    ) ParseError!void {
        assert(input != null);
        const item = try parse(arena_alloc, input) orelse return;
        if (item.len() == 0) return;
        self.* = item;
    }
    pub fn formatEntry(self: *const Path, formatter: formatterpkg.EntryFormatter) !void {
        var buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
        const value = switch (self.*) {
            .optional => |path| std.fmt.bufPrint(
                &buf,
                "?{s}",
                .{path},
            ) catch |err| switch (err) {
                error.NoSpaceLeft => return error.OutOfMemory,
            },
            .required => |path| path,
        };
        try formatter.formatEntry([]const u8, value);
    }
    pub fn clone(
        self: Path,
        arena_alloc: Allocator,
    ) Allocator.Error!Path {
        return switch (self) {
            .optional => |path| .{
                .optional = try arena_alloc.dupeZ(u8, path),
            },
            .required => |path| .{
                .required = try arena_alloc.dupeZ(u8, path),
            },
        };
    }
    pub fn expand(
        self: *Path,
        arena_alloc: Allocator,
        base: []const u8,
        diags: *cli.DiagnosticList,
    ) !void {
        assert(std.fs.path.isAbsolute(base));
        const path = switch (self.*) {
            .optional, .required => |path| path,
        };
        if (path.len == 0 or std.fs.path.isAbsolute(path)) return;
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        if (std.mem.startsWith(u8, path, "~/")) expand: {
            if (comptime builtin.os.tag == .windows) break :expand;
            var environ_map = try global.environMap();
            defer environ_map.deinit();
            const expanded: []const u8 = internal_os.expandHome(
                global.io(),
                &environ_map,
                path,
                &buf,
            ) catch |err| {
                try diags.append(arena_alloc, .{
                    .message = try std.fmt.allocPrintSentinel(
                        arena_alloc,
                        "error expanding home directory for path {s}: {}",
                        .{ path, err },
                        0,
                    ),
                });
                self.* = .{ .required = "" };
                return;
            };
            log.debug(
                "expanding file path from home directory: path={s}",
                .{expanded},
            );
            switch (self.*) {
                .optional, .required => |*p| p.* = try arena_alloc.dupeZ(u8, expanded),
            }
            return;
        }
        var dir = try std.Io.Dir.openDirAbsolute(global.io(), base, .{});
        defer dir.close(global.io());
        const abs = abs: {
            const abs_len = dir.realPathFile(global.io(), path, &buf) catch |err| {
                if (err == error.FileNotFound) {
                    const resolved = try std.fs.path.resolve(arena_alloc, &.{ base, path });
                    defer arena_alloc.free(resolved);
                    @memcpy(buf[0..resolved.len], resolved);
                    break :abs buf[0..resolved.len];
                }
                try diags.append(arena_alloc, .{
                    .message = try std.fmt.allocPrintSentinel(
                        arena_alloc,
                        "error resolving file path {s}: {}",
                        .{ path, err },
                        0,
                    ),
                });
                self.* = .{ .required = "" };
                return;
            };
            break :abs buf[0..abs_len];
        };
        log.debug(
            "expanding file path relative={s} abs={s}",
            .{ path, abs },
        );
        switch (self.*) {
            .optional, .required => |*p| p.* = try arena_alloc.dupeZ(u8, abs),
        }
    }
    test "parse" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        const Tag = std.meta.Tag(Path);
        {
            const item = (try Path.parse(alloc, "config.1")).?;
            try testing.expectEqual(Tag.required, @as(Tag, item));
            try testing.expectEqualStrings("config.1", item.required);
        }
        {
            const item = (try Path.parse(alloc, "?config.2")).?;
            try testing.expectEqual(Tag.optional, @as(Tag, item));
            try testing.expectEqualStrings("config.2", item.optional);
        }
        {
            const item = (try Path.parse(alloc, "\"?config.3\"")).?;
            try testing.expectEqual(Tag.required, @as(Tag, item));
            try testing.expectEqualStrings("?config.3", item.required);
        }
        {
            const item = (try Path.parse(alloc, "?\"config.4\"")).?;
            try testing.expectEqual(Tag.optional, @as(Tag, item));
            try testing.expectEqualStrings("config.4", item.optional);
        }
        {
            const item = (try Path.parse(alloc, "?")).?;
            try testing.expectEqual(Tag.optional, @as(Tag, item));
            try testing.expectEqualStrings("", item.optional);
        }
        {
            const item = (try Path.parse(alloc, "\"\"")).?;
            try testing.expectEqual(Tag.required, @as(Tag, item));
            try testing.expectEqualStrings("", item.required);
        }
        {
            const item = (try Path.parse(alloc, "?\"\"")).?;
            try testing.expectEqual(Tag.optional, @as(Tag, item));
            try testing.expectEqualStrings("", item.optional);
        }
    }
    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        const Tag = std.meta.Tag(Path);
        var item: Path = undefined;
        try item.parseCLI(alloc, "config.1");
        try testing.expectEqual(Tag.required, @as(Tag, item));
        try testing.expectEqualStrings("config.1", item.required);
        try item.parseCLI(alloc, "?config.2");
        try testing.expectEqual(Tag.optional, @as(Tag, item));
        try testing.expectEqualStrings("config.2", item.optional);
        try item.parseCLI(alloc, "\"?config.3\"");
        try testing.expectEqual(Tag.required, @as(Tag, item));
        try testing.expectEqualStrings("?config.3", item.required);
        try item.parseCLI(alloc, "?");
        try testing.expectEqual(Tag.required, @as(Tag, item));
        try testing.expectEqualStrings("?config.3", item.required);
        try item.parseCLI(alloc, "\"\"");
        try testing.expectEqual(Tag.required, @as(Tag, item));
        try testing.expectEqualStrings("?config.3", item.required);
        try item.parseCLI(alloc, "?\"\"");
        try testing.expectEqual(Tag.required, @as(Tag, item));
        try testing.expectEqualStrings("?config.3", item.required);
    }
    test "formatConfig single item" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var item: Path = undefined;
        try item.parseCLI(alloc, "A");
        try item.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = A\n", buf.written());
    }
    test "formatConfig multiple items" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var item: Path = undefined;
        try item.parseCLI(alloc, "A");
        try item.parseCLI(alloc, "?B");
        try item.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = ?B\n", buf.written());
    }
};
pub const RepeatablePath = struct {
    value: std.ArrayList(Path) = .empty,
    pub fn parseCLI(self: *RepeatablePath, alloc: Allocator, input: ?[]const u8) ParseError!void {
        const item = try Path.parse(alloc, input) orelse {
            self.value.clearRetainingCapacity();
            return;
        };
        if (item.len() == 0) {
            return;
        }
        try self.value.append(alloc, item);
    }
    pub fn clone(self: *const RepeatablePath, alloc: Allocator) Allocator.Error!RepeatablePath {
        const value = try self.value.clone(alloc);
        for (value.items) |*item| {
            item.* = try item.clone(alloc);
        }
        return .{
            .value = value,
        };
    }
    pub fn equal(self: RepeatablePath, other: RepeatablePath) bool {
        if (self.value.items.len != other.value.items.len) return false;
        for (self.value.items, other.value.items) |a, b| {
            if (!a.equal(b)) return false;
        }
        return true;
    }
    pub fn formatEntry(self: RepeatablePath, formatter: formatterpkg.EntryFormatter) !void {
        if (self.value.items.len == 0) {
            try formatter.formatEntry(void, {});
            return;
        }
        var buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
        for (self.value.items) |item| {
            const value = switch (item) {
                .optional => |path| std.fmt.bufPrint(
                    &buf,
                    "?{s}",
                    .{path},
                ) catch |err| switch (err) {
                    error.NoSpaceLeft => return error.OutOfMemory,
                },
                .required => |path| path,
            };
            try formatter.formatEntry([]const u8, value);
        }
    }
    pub fn expand(
        self: *RepeatablePath,
        alloc: Allocator,
        base: []const u8,
        diags: *cli.DiagnosticList,
    ) !void {
        for (self.value.items) |*path| {
            try path.expand(alloc, base, diags);
        }
    }
    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: RepeatablePath = .{};
        try list.parseCLI(alloc, "config.1");
        try list.parseCLI(alloc, "?config.2");
        try list.parseCLI(alloc, "\"?config.3\"");
        try testing.expectEqual(@as(usize, 3), list.value.items.len);
        try list.parseCLI(alloc, "?");
        try list.parseCLI(alloc, "\"\"");
        try testing.expectEqual(@as(usize, 3), list.value.items.len);
        const Tag = std.meta.Tag(Path);
        try testing.expectEqual(Tag.required, @as(Tag, list.value.items[0]));
        try testing.expectEqualStrings("config.1", list.value.items[0].required);
        try testing.expectEqual(Tag.optional, @as(Tag, list.value.items[1]));
        try testing.expectEqualStrings("config.2", list.value.items[1].optional);
        try testing.expectEqual(Tag.required, @as(Tag, list.value.items[2]));
        try testing.expectEqualStrings("?config.3", list.value.items[2].required);
        try list.parseCLI(alloc, "");
        try testing.expectEqual(@as(usize, 0), list.value.items.len);
    }
    test "formatConfig empty" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var list: RepeatablePath = .{};
        try list.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = \n", buf.written());
    }
    test "formatConfig single item" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: RepeatablePath = .{};
        try list.parseCLI(alloc, "A");
        try list.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = A\n", buf.written());
    }
    test "formatConfig multiple items" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var list: RepeatablePath = .{};
        try list.parseCLI(alloc, "A");
        try list.parseCLI(alloc, "?B");
        try list.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = A\na = ?B\n", buf.written());
    }
};
