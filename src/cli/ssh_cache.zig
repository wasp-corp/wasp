const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const global = @import("../global.zig");
const Action = @import("wasp.zig").Action;
const Duration = @import("../config.zig").Config.Duration;
const terminfopkg = @import("../terminfo/root.zig");
pub const Entry = @import("ssh-cache/Entry.zig");
pub const DiskCache = @import("ssh-cache/DiskCache.zig");
pub const Options = struct {
    clear: bool = false,
    add: ?[]const u8 = null,
    remove: ?[]const u8 = null,
    prune: ?Duration = null,
    pub fn deinit(self: *Options) void {
        _ = self;
    }
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};
pub fn run(alloc_gpa: Allocator) !u8 {
    var arena = std.heap.ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    var opts: Options = .{};
    defer opts.deinit();
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file: std.Io.File = .stdout();
    var stdout_writer = stdout_file.writer(global.io(), &stdout_buffer);
    const stdout = &stdout_writer.interface;
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file: std.Io.File = .stderr();
    var stderr_writer = stderr_file.writer(global.io(), &stderr_buffer);
    const stderr = &stderr_writer.interface;
    var query: ?[]const u8 = null;
    var flags: std.ArrayList([]const u8) = .empty;
    {
        var iter = try args.argsIterator(alloc_gpa, global.args());
        defer iter.deinit();
        while (iter.next()) |arg| {
            const is_host_flag = std.mem.startsWith(u8, arg, "--host=");
            if (is_host_flag) {
                try stderr.print(
                    "Warning: --host is deprecated; pass the destination " ++
                        "directly, e.g. `wasp +ssh-cache {s}`.\n",
                    .{arg["--host=".len..]},
                );
            }
            const dest: ?[]const u8 = if (is_host_flag)
                arg["--host=".len..]
            else if (!std.mem.startsWith(u8, arg, "-"))
                arg
            else
                null;
            if (dest) |d| {
                if (query != null) {
                    try stderr.print(
                        "Error: only one destination may be specified.\n",
                        .{},
                    );
                    stderr.flush() catch {};
                    return 2;
                }
                query = try alloc.dupe(u8, d);
            } else {
                try flags.append(alloc, try alloc.dupe(u8, arg));
            }
        }
    }
    {
        var iter = args.sliceIterator(flags.items);
        args.parse(Options, alloc_gpa, &opts, &iter) catch |err| switch (err) {
            error.InvalidField => {
                try stderr.print("Error: unknown flag.\n", .{});
                stderr.flush() catch {};
                return 2;
            },
            error.InvalidValue, error.ValueRequired => {
                try stderr.print("Error: invalid flag value.\n", .{});
                stderr.flush() catch {};
                return 2;
            },
            else => return err,
        };
    }
    const cache_path = DiskCache.defaultPath(alloc, "wasp") catch |err| {
        try stderr.print(
            "Error: unable to determine the cache path: {t}\n",
            .{err},
        );
        stderr.flush() catch {};
        return 1;
    };
    const result = runInner(
        alloc,
        opts,
        query,
        .{ .path = cache_path },
        stdout,
        stderr,
    );
    stdout.flush() catch {};
    stderr.flush() catch {};
    return result;
}
pub fn runInner(
    alloc: Allocator,
    opts: Options,
    query: ?[]const u8,
    cache: DiskCache,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const action_count =
        @as(usize, @intFromBool(opts.clear)) +
        @intFromBool(opts.add != null) +
        @intFromBool(opts.remove != null) +
        @intFromBool(opts.prune != null) +
        @intFromBool(query != null);
    if (action_count > 1) {
        try stderr.print(
            "Error: only one of a destination, --clear, --add, --remove, " ++
                "or --prune may be specified.\n",
            .{},
        );
        return 2;
    }
    if (opts.clear) {
        cache.clear() catch |err| {
            try stderr.print(
                "Error: unable to clear cache '{s}': {t}\n",
                .{ cache.path, err },
            );
            return 1;
        };
        return 0;
    }
    if (opts.add) |dest| {
        cache.add(
            alloc,
            dest,
            terminfopkg.version,
            std.Io.Timestamp.now(global.io(), .real).toSeconds(),
        ) catch |err| switch (err) {
            error.InvalidCacheKey => {
                try stderr.print(
                    "Error: invalid destination '{s}' (expected [user@]hostname[:port])\n",
                    .{dest},
                );
                return 2;
            },
            else => {
                try stderr.print(
                    "Error: unable to add '{s}' to cache '{s}': {t}\n",
                    .{ dest, cache.path, err },
                );
                return 1;
            },
        };
        return 0;
    }
    if (opts.remove) |dest| {
        const removed = cache.remove(alloc, dest) catch |err| switch (err) {
            error.InvalidCacheKey => {
                try stderr.print(
                    "Error: invalid destination '{s}' (expected [user@]hostname[:port])\n",
                    .{dest},
                );
                return 2;
            },
            else => {
                try stderr.print(
                    "Error: unable to remove '{s}' from cache '{s}': {t}\n",
                    .{ dest, cache.path, err },
                );
                return 1;
            },
        };
        if (!removed) {
            try stderr.print("Error: '{s}' is not in the cache.\n", .{dest});
            return 1;
        }
        return 0;
    }
    if (opts.prune) |max_age| {
        const max_age_s = max_age.duration / std.time.ns_per_s;
        if (max_age_s == 0) {
            try stderr.print(
                "Error: --prune requires a duration of at least one second.\n",
                .{},
            );
            return 2;
        }
        const pruned = cache.prune(alloc, max_age_s) catch |err| {
            try stderr.print(
                "Error: unable to prune cache '{s}': {t}\n",
                .{ cache.path, err },
            );
            return 1;
        };
        try stdout.print("Pruned cache entries: {d}\n", .{pruned});
        return 0;
    }
    var entries = cache.list(alloc) catch |err| {
        try stderr.print(
            "Error: unable to read cache '{s}': {t}\n",
            .{ cache.path, err },
        );
        return 1;
    };
    defer DiskCache.deinitEntries(alloc, &entries);
    if (query) |q| {
        if (!DiskCache.isValidCacheKey(q)) {
            try stderr.print(
                "Error: invalid destination '{s}' (expected [user@]hostname[:port])\n",
                .{q},
            );
            return 2;
        }
        var matches: std.StringHashMap(Entry) = .init(alloc);
        defer matches.deinit();
        var iter = entries.iterator();
        while (iter.next()) |kv| {
            const key = kv.key_ptr.*;
            if (matchesQuery(key, q)) try matches.put(key, kv.value_ptr.*);
        }
        if (matches.count() == 0) return 1;
        try listEntries(alloc, &matches, stdout);
        return 0;
    }
    try listEntries(alloc, &entries, stdout);
    return 0;
}
fn listEntries(
    alloc: Allocator,
    entries: *const std.StringHashMap(Entry),
    writer: *std.Io.Writer,
) !void {
    if (entries.count() == 0) return;
    var items: std.ArrayList(Entry) = .empty;
    defer items.deinit(alloc);
    var iter = entries.iterator();
    while (iter.next()) |kv| {
        try items.append(alloc, kv.value_ptr.*);
    }
    std.mem.sort(Entry, items.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.hostname, b.hostname);
        }
    }.lessThan);
    var widest: usize = 0;
    for (items.items) |entry| {
        widest = @max(widest, entry.hostname.len);
    }
    const now = std.Io.Timestamp.now(global.io(), .real).toSeconds();
    for (items.items) |entry| {
        try writer.print("{s}", .{entry.hostname});
        try writer.splatByteAll(' ', widest - entry.hostname.len + 2);
        var iso_buf: [20]u8 = undefined;
        var age_buf: [32]u8 = undefined;
        try writer.print("{s} ({s})\n", .{
            formatTimestamp(&iso_buf, entry.timestamp),
            relativeAge(&age_buf, now, entry.timestamp),
        });
    }
}
fn matchesQuery(key: []const u8, query: []const u8) bool {
    const key_at = std.mem.indexOfScalar(u8, key, '@');
    const query_at = std.mem.indexOfScalar(u8, query, '@');
    if (query_at) |i| {
        const key_user = if (key_at) |j| key[0..j] else return false;
        if (!std.mem.eql(u8, key_user, query[0..i])) return false;
    }
    const key_hp = DiskCache.splitHostPort(if (key_at) |i| key[i + 1 ..] else key);
    const query_hp = DiskCache.splitHostPort(if (query_at) |i| query[i + 1 ..] else query);
    if (!std.mem.eql(u8, key_hp.host, query_hp.host)) return false;
    if (query_at == null and query_hp.port == null) return true;
    return std.mem.eql(u8, key_hp.port orelse "22", query_hp.port orelse "22");
}
test matchesQuery {
    const testing = std.testing;
    try testing.expect(matchesQuery("user@example.com", "user@example.com"));
    try testing.expect(!matchesQuery("root@example.com", "user@example.com"));
    try testing.expect(!matchesQuery("example.com", "user@example.com"));
    try testing.expect(matchesQuery("user@example.com", "example.com"));
    try testing.expect(matchesQuery("root@example.com", "example.com"));
    try testing.expect(matchesQuery("example.com", "example.com"));
    try testing.expect(!matchesQuery("user@other.com", "example.com"));
    try testing.expect(matchesQuery("user@example.com:2222", "example.com"));
    try testing.expect(matchesQuery("user@[::1]:2222", "::1"));
    try testing.expect(matchesQuery("user@::1", "::1"));
    try testing.expect(matchesQuery("user@example.com:2222", "example.com:2222"));
    try testing.expect(matchesQuery("root@example.com:2222", "example.com:2222"));
    try testing.expect(!matchesQuery("user@example.com", "example.com:2222"));
    try testing.expect(!matchesQuery("user@example.com:2223", "example.com:2222"));
    try testing.expect(matchesQuery("user@[::1]:2222", "[::1]:2222"));
    try testing.expect(matchesQuery("user@example.com:2222", "user@example.com:2222"));
    try testing.expect(!matchesQuery("user@example.com", "user@example.com:2222"));
    try testing.expect(!matchesQuery("user@example.com:2222", "user@example.com"));
    try testing.expect(matchesQuery("user@example.com", "example.com:22"));
    try testing.expect(matchesQuery("user@example.com", "user@example.com:22"));
    try testing.expect(matchesQuery("user@example.com:22", "user@example.com"));
    try testing.expect(matchesQuery("user@[::1]:22", "user@::1"));
    try testing.expect(!matchesQuery("user@example.com:2222", "example.com:22"));
}
fn formatTimestamp(buf: []u8, timestamp: i64) []const u8 {
    const secs: u64 = @intCast(std.math.clamp(timestamp, 0, 253402300799));
    const epoch = std.time.epoch;
    const epoch_secs: epoch.EpochSeconds = .{ .secs = secs };
    const day = epoch_secs.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const ds = epoch_secs.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch unreachable;
}
test formatTimestamp {
    const testing = std.testing;
    var buf: [20]u8 = undefined;
    try testing.expectEqualStrings(
        "2026-05-05T22:49:33Z",
        formatTimestamp(&buf, 1778021373),
    );
    try testing.expectEqualStrings(
        "1970-01-01T00:00:00Z",
        formatTimestamp(&buf, 0),
    );
    try testing.expectEqualStrings(
        "1970-01-01T00:00:00Z",
        formatTimestamp(&buf, -5),
    );
    try testing.expectEqualStrings(
        "9999-12-31T23:59:59Z",
        formatTimestamp(&buf, std.math.maxInt(i64)),
    );
}
fn relativeAge(buf: []u8, now: i64, timestamp: i64) []const u8 {
    const age: u64 = @intCast(@max(0, now -| timestamp));
    if (age == 0) return "now";
    const units = [_]u64{
        365 * std.time.s_per_day,
        std.time.s_per_week,
        std.time.s_per_day,
        std.time.s_per_hour,
        std.time.s_per_min,
        1,
    };
    const unit = for (units) |u| {
        if (age >= u) break u;
    } else 1;
    const max_age = std.math.maxInt(u64) / std.time.ns_per_s;
    const rounded = @min(age, max_age) / unit * unit;
    const d: Duration = .{ .duration = rounded * std.time.ns_per_s };
    return std.fmt.bufPrint(buf, "{f} ago", .{d}) catch unreachable;
}
test relativeAge {
    const testing = std.testing;
    var buf: [32]u8 = undefined;
    const now: i64 = 2_000_000_000;
    const min = std.time.s_per_min;
    const hour = std.time.s_per_hour;
    const day = std.time.s_per_day;
    try testing.expectEqualStrings("now", relativeAge(&buf, now, std.math.maxInt(i64)));
    try testing.expectEqualStrings("63y ago", relativeAge(&buf, now, -100));
    try testing.expect(std.mem.endsWith(u8, relativeAge(&buf, std.math.maxInt(i64), 0), " ago"));
    try testing.expectEqualStrings("now", relativeAge(&buf, now, now + 100));
    try testing.expectEqualStrings("now", relativeAge(&buf, now, now));
    try testing.expectEqualStrings("30s ago", relativeAge(&buf, now, now - 30));
    try testing.expectEqualStrings("1m ago", relativeAge(&buf, now, now - min));
    try testing.expectEqualStrings("1m ago", relativeAge(&buf, now, now - 90));
    try testing.expectEqualStrings("1h ago", relativeAge(&buf, now, now - hour));
    try testing.expectEqualStrings("1h ago", relativeAge(&buf, now, now - (hour + 30 * min)));
    try testing.expectEqualStrings("1d ago", relativeAge(&buf, now, now - day));
    try testing.expectEqualStrings("2w ago", relativeAge(&buf, now, now - 19 * day));
}
test {
    _ = DiskCache;
    _ = Entry;
}
test "runInner rejects multiple actions" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var stdout: std.Io.Writer.Allocating = .init(alloc);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(alloc);
    defer stderr.deinit();
    const cache: DiskCache = .{ .path = "/nonexistent/ssh_cache" };
    const code = try runInner(alloc, .{
        .add = "example.com",
        .remove = "other.com",
    }, null, cache, &stdout.writer, &stderr.writer);
    try testing.expectEqual(@as(u8, 2), code);
    try testing.expectEqualStrings("", stdout.written());
    try testing.expect(std.mem.indexOf(u8, stderr.written(), "only one") != null);
    stderr.clearRetainingCapacity();
    const code2 = try runInner(alloc, .{
        .clear = true,
    }, "example.com", cache, &stdout.writer, &stderr.writer);
    try testing.expectEqual(@as(u8, 2), code2);
    try testing.expect(std.mem.indexOf(u8, stderr.written(), "only one") != null);
}
test "runInner fails cleanly when the cache is unusable" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "ssh_cache");
    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(tmp_path);
    const cache_path = try std.fs.path.join(alloc, &.{ tmp_path, "ssh_cache" });
    defer alloc.free(cache_path);
    const cache: DiskCache = .{ .path = cache_path };
    var stdout: std.Io.Writer.Allocating = .init(alloc);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(alloc);
    defer stderr.deinit();
    const opts: []const Options = &.{
        .{},
        .{ .add = "example.com" },
        .{ .remove = "example.com" },
        .{ .prune = .{ .duration = std.time.ns_per_s } },
    };
    for (opts) |o| {
        const code = try runInner(alloc, o, null, cache, &stdout.writer, &stderr.writer);
        try testing.expectEqual(@as(u8, 1), code);
    }
}
