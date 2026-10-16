const TerminalFormatter = @This();
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const terminalpkg = @import("../terminal/main.zig");
const formatterpkg = terminalpkg.formatter;
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const Terminal = terminalpkg.Terminal;
const Selection = terminalpkg.Selection;
const global = @import("../global.zig");
const log = std.log.scoped(.@"terminal-formatter-bench");
alloc: Allocator,
opts: Options,
terminal: ?Terminal = null,
output: std.Io.Writer.Allocating,
pins: formatterpkg.PinMap.Map = .empty,
pub const Options = struct {
    _arena: ?std.heap.ArenaAllocator = null,
    mode: Mode = .format,
    emit: Emit = .vt,
    formatter: Formatter = .screen,
    region: Region = .screen,
    unwrap: bool = false,
    @"pin-map": bool = false,
    loops: u32 = 25,
    @"terminal-rows": u16 = 24,
    @"terminal-cols": u16 = 80,
    data: ?[]const u8 = null,
    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }
};
pub const Mode = enum {
    noop,
    format,
    report,
    roundtrip,
};
pub const Emit = enum {
    plain,
    vt,
    html,
    fn format(self: Emit) formatterpkg.Format {
        return switch (self) {
            .plain => .plain,
            .vt => .vt,
            .html => .html,
        };
    }
};
pub const Formatter = enum {
    screen,
    terminal,
};
pub const Region = enum {
    screen,
    active,
    history,
};
pub fn create(
    alloc: Allocator,
    opts: Options,
) !*TerminalFormatter {
    const ptr = try alloc.create(TerminalFormatter);
    errdefer alloc.destroy(ptr);
    ptr.* = .{
        .alloc = alloc,
        .opts = opts,
        .output = .init(alloc),
    };
    return ptr;
}
pub fn destroy(self: *TerminalFormatter, alloc: Allocator) void {
    if (self.terminal) |*t| t.deinit(self.alloc);
    self.output.deinit();
    self.pins.deinit(self.alloc);
    alloc.destroy(self);
}
pub fn benchmark(self: *TerminalFormatter) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .noop => stepNoop,
            .format => stepFormat,
            .report => stepReport,
            .roundtrip => stepRoundtrip,
        },
        .setupFn = setup,
        .teardownFn = teardown,
    });
}
fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalFormatter = @ptrCast(@alignCast(ptr));
    self.setupImpl() catch |err| {
        log.warn("failed to prepare formatter benchmark err={}", .{err});
        return error.BenchmarkFailed;
    };
}
fn setupImpl(self: *TerminalFormatter) !void {
    if (self.terminal) |*t| t.deinit(self.alloc);
    self.terminal = null;
    self.terminal = try Terminal.init(global.io(), self.alloc, .{
        .cols = self.opts.@"terminal-cols",
        .rows = self.opts.@"terminal-rows",
        .max_scrollback_bytes = null,
        .max_scrollback_lines = null,
    });
    const terminal = &self.terminal.?;
    if (try options.dataFile(self.opts.data)) |data_f| {
        defer data_f.close(global.io());
        var stream = terminal.vtStream();
        defer stream.deinit();
        var read_buf: [4096]u8 align(std.atomic.cache_line) = undefined;
        var f_reader = data_f.reader(global.io(), &read_buf);
        const r = &f_reader.interface;
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = try r.readSliceShort(&buf);
            if (n == 0) break; 
            stream.nextSlice(buf[0..n]);
        }
    }
}
fn teardown(ptr: *anyopaque) void {
    const self: *TerminalFormatter = @ptrCast(@alignCast(ptr));
    if (self.terminal) |*t| t.deinit(self.alloc);
    self.terminal = null;
    self.output.shrinkRetainingCapacity(0);
    self.pins.clearRetainingCapacity();
}
const AnyFormatter = union(Formatter) {
    screen: formatterpkg.ScreenFormatter,
    terminal: formatterpkg.TerminalFormatter,
    fn setPinMap(self: *AnyFormatter, pin_map: formatterpkg.PinMap) void {
        switch (self.*) {
            inline else => |*f| f.pin_map = pin_map,
        }
    }
    fn format(self: AnyFormatter, writer: *std.Io.Writer) !void {
        switch (self) {
            inline else => |f| try f.format(writer),
        }
    }
};
fn formatter(
    self: *TerminalFormatter,
    t: *const Terminal,
    region: Region,
) ?AnyFormatter {
    const screen = t.screens.active;
    const opts: formatterpkg.Options = .{
        .emit = self.opts.emit.format(),
        .unwrap = self.opts.unwrap,
    };
    const content: formatterpkg.ScreenFormatter.Content = switch (region) {
        .screen => .{ .selection = null },
        inline .active, .history => |r| content: {
            const tag: terminalpkg.point.Tag = switch (r) {
                .active => .active,
                .history => .history,
                .screen => unreachable,
            };
            const tl = screen.pages.getTopLeft(tag);
            const br = screen.pages.getBottomRight(tag) orelse return null;
            break :content .{ .selection = Selection.init(tl, br, false) };
        },
    };
    switch (self.opts.formatter) {
        .screen => {
            var f: formatterpkg.ScreenFormatter = .init(screen, opts);
            f.content = content;
            return .{ .screen = f };
        },
        .terminal => {
            var f: formatterpkg.TerminalFormatter = .init(t, opts);
            f.content = content;
            f.extra = .all;
            return .{ .terminal = f };
        },
    }
}
fn stepNoop(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalFormatter = @ptrCast(@alignCast(ptr));
    for (0..self.opts.loops) |_| {
        std.mem.doNotOptimizeAway(self.output.written());
    }
}
fn stepFormat(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalFormatter = @ptrCast(@alignCast(ptr));
    for (0..self.opts.loops) |_| {
        self.output.shrinkRetainingCapacity(0);
        var f = self.formatter(&self.terminal.?, self.opts.region) orelse continue;
        if (self.opts.@"pin-map") {
            self.pins.clearRetainingCapacity();
            f.setPinMap(.{ .alloc = self.alloc, .map = &self.pins });
        }
        f.format(&self.output.writer) catch |err| {
            log.warn("formatting failed err={}", .{err});
            return error.BenchmarkFailed;
        };
        std.mem.doNotOptimizeAway(self.output.written());
    }
}
fn stepReport(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalFormatter = @ptrCast(@alignCast(ptr));
    self.output.shrinkRetainingCapacity(0);
    if (self.formatter(&self.terminal.?, self.opts.region)) |f_init| {
        var f = f_init;
        if (self.opts.@"pin-map") {
            self.pins.clearRetainingCapacity();
            f.setPinMap(.{ .alloc = self.alloc, .map = &self.pins });
        }
        f.format(&self.output.writer) catch |err| {
            log.warn("formatting failed err={}", .{err});
            return error.BenchmarkFailed;
        };
    }
    const screen = self.terminal.?.screens.active;
    var pages: usize = 0;
    var rows: usize = 0;
    {
        var node = screen.pages.pages.first;
        while (node) |n| : (node = n.next) {
            pages += 1;
            rows += n.page().size.rows;
        }
    }
    const out_hash = std.hash.Wyhash.hash(0, self.output.written());
    var pin_hasher = std.hash.Wyhash.init(0);
    for (self.pins.points.items) |coord| {
        const x: u16 = coord.x;
        const y: u16 = @intCast(coord.y);
        pin_hasher.update(std.mem.asBytes(&x));
        pin_hasher.update(std.mem.asBytes(&y));
    }
    log.debug(
        "terminal-formatter emit={s} formatter={s} region={s} pages={d} " ++
            "rows={d} cols={d} cells={d} out_bytes={d} pin_bytes={d} " ++
            "out_hash={x} pin_hash={x}\n",
        .{
            @tagName(self.opts.emit),
            @tagName(self.opts.formatter),
            @tagName(self.opts.region),
            pages,
            rows,
            self.opts.@"terminal-cols",
            rows * self.opts.@"terminal-cols",
            self.output.written().len,
            self.pins.count(),
            out_hash,
            pin_hasher.final(),
        },
    );
    if (self.opts.@"pin-map") {
        log.debug(
            "terminal-formatter-pins points={d} nodes={d}\n",
            .{ self.pins.points.items.len, self.pins.nodes.items.len },
        );
    }
}
fn stepRoundtrip(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalFormatter = @ptrCast(@alignCast(ptr));
    self.stepRoundtripImpl() catch |err| {
        log.warn("roundtrip failed err={}", .{err});
        return error.BenchmarkFailed;
    };
}
fn stepRoundtripImpl(self: *TerminalFormatter) !void {
    self.output.shrinkRetainingCapacity(0);
    if (self.formatter(&self.terminal.?, self.opts.region)) |f| {
        try f.format(&self.output.writer);
    }
    const first = self.output.written();
    var t2 = try Terminal.init(global.io(), self.alloc, .{
        .cols = self.opts.@"terminal-cols",
        .rows = self.opts.@"terminal-rows",
        .max_scrollback_bytes = null,
        .max_scrollback_lines = null,
    });
    defer t2.deinit(self.alloc);
    {
        var stream = t2.vtStream();
        defer stream.deinit();
        stream.nextSlice(first);
    }
    var out2: std.Io.Writer.Allocating = .init(self.alloc);
    defer out2.deinit();
    if (self.formatter(&t2, .screen)) |f2| {
        try f2.format(&out2.writer);
    }
    const second = out2.written();
    const equal = std.mem.eql(u8, first, second);
    log.debug(
        "terminal-formatter roundtrip emit={s} formatter={s} bytes={d} " ++
            "replay_bytes={d} equal={}\n",
        .{
            @tagName(self.opts.emit),
            @tagName(self.opts.formatter),
            first.len,
            second.len,
            equal,
        },
    );
    if (!equal) {
        const n = @min(first.len, second.len);
        var i: usize = 0;
        while (i < n and first[i] == second[i]) i += 1;
        log.debug(
            "terminal-formatter roundtrip mismatch offset={d} " ++
                "first={f} second={f}\n",
            .{
                i,
                std.zig.fmtString(first[i -| 32..@min(first.len, i + 32)]),
                std.zig.fmtString(second[i -| 32..@min(second.len, i + 32)]),
            },
        );
        return error.RoundtripMismatch;
    }
}
test TerminalFormatter {
    const testing = std.testing;
    const impl: *TerminalFormatter = try .create(testing.allocator, .{});
    defer impl.destroy(testing.allocator);
    const bench = impl.benchmark();
    _ = try bench.run(.once);
}
test "TerminalFormatter roundtrip" {
    const testing = std.testing;
    const impl: *TerminalFormatter = try .create(testing.allocator, .{
        .mode = .roundtrip,
        .@"terminal-rows" = 4,
        .@"terminal-cols" = 8,
    });
    defer impl.destroy(testing.allocator);
    const bench = impl.benchmark();
    _ = try bench.run(.once);
}
test "TerminalFormatter terminal roundtrip" {
    const testing = std.testing;
    const impl: *TerminalFormatter = try .create(testing.allocator, .{
        .mode = .roundtrip,
        .formatter = .terminal,
        .@"terminal-rows" = 4,
        .@"terminal-cols" = 8,
    });
    defer impl.destroy(testing.allocator);
    const bench = impl.benchmark();
    _ = try bench.run(.once);
}
test "TerminalFormatter formats all emit formats and regions" {
    const testing = std.testing;
    inline for (.{ Formatter.screen, Formatter.terminal }) |formatter_| {
        inline for (.{ Emit.plain, Emit.vt, Emit.html }) |emit| {
            inline for (.{ Region.screen, Region.active, Region.history }) |region| {
                const impl: *TerminalFormatter = try .create(testing.allocator, .{
                    .emit = emit,
                    .formatter = formatter_,
                    .region = region,
                    .loops = 1,
                    .@"terminal-rows" = 4,
                    .@"terminal-cols" = 8,
                });
                defer impl.destroy(testing.allocator);
                const bench = impl.benchmark();
                _ = try bench.run(.once);
            }
        }
    }
}
test "TerminalFormatter pin map" {
    const testing = std.testing;
    inline for (.{ Formatter.screen, Formatter.terminal }) |formatter_| {
        const impl: *TerminalFormatter = try .create(testing.allocator, .{
            .@"pin-map" = true,
            .formatter = formatter_,
            .loops = 1,
            .@"terminal-rows" = 4,
            .@"terminal-cols" = 8,
        });
        defer impl.destroy(testing.allocator);
        const bench = impl.benchmark();
        _ = try bench.run(.once);
    }
}
