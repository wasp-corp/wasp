const ScreenClone = @This();
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const terminalpkg = @import("../terminal/main.zig");
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const Terminal = terminalpkg.Terminal;
const global = @import("../global.zig");
const log = std.log.scoped(.@"terminal-stream-bench");
opts: Options,
terminal: Terminal,
pub const Options = struct {
    mode: Mode = .clone,
    loops: u32 = 1,
    @"terminal-rows": u16 = 80,
    @"terminal-cols": u16 = 120,
    data: ?[]const u8 = null,
};
pub const Mode = enum {
    noop,
    clone,
    render,
    @"render-locked",
    @"render-clean",
    @"render-partial",
    @"render-scroll",
    @"render-scroll-page",
    @"render-output",
    @"render-scroll-overscan",
    @"render-output-overscan",
    @"render-clean-overscan",
};
const bench_overscan: terminalpkg.RenderState.Overscan = .{ .above = 4, .below = 1 };
fn overscanRequest(mode: Mode) terminalpkg.RenderState.Overscan {
    return switch (mode) {
        .@"render-scroll-overscan",
        .@"render-output-overscan",
        .@"render-clean-overscan",
        => bench_overscan,
        else => .{},
    };
}
const scroll_setup_lines = 4000;
const scroll_reverse_interval = 2000;
const scroll_page_reverse_interval = 40;
pub fn create(
    alloc: Allocator,
    opts: Options,
) !*ScreenClone {
    const ptr = try alloc.create(ScreenClone);
    errdefer alloc.destroy(ptr);
    var terminal_opts: Terminal.Options = .{
        .rows = opts.@"terminal-rows",
        .cols = opts.@"terminal-cols",
    };
    switch (opts.mode) {
        .@"render-scroll",
        .@"render-scroll-page",
        .@"render-scroll-overscan",
        => terminal_opts.max_scrollback_bytes = 256 * 1024 * 1024,
        else => {},
    }
    ptr.* = .{
        .opts = opts,
        .terminal = try .init(global.io(), alloc, terminal_opts),
    };
    return ptr;
}
pub fn destroy(self: *ScreenClone, alloc: Allocator) void {
    self.terminal.deinit(alloc);
    alloc.destroy(self);
}
pub fn benchmark(self: *ScreenClone) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .noop => stepNoop,
            .clone => stepClone,
            .render => stepRender,
            .@"render-locked" => stepRenderLocked,
            .@"render-clean",
            .@"render-clean-overscan",
            => stepRenderClean,
            .@"render-partial" => stepRenderPartial,
            .@"render-scroll",
            .@"render-scroll-overscan",
            => stepRenderScroll,
            .@"render-scroll-page" => stepRenderScrollPage,
            .@"render-output",
            .@"render-output-overscan",
            => stepRenderOutput,
        },
        .setupFn = setup,
        .teardownFn = teardown,
    });
}
fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScreenClone = @ptrCast(@alignCast(ptr));
    self.terminal.fullReset();
    var s = self.terminal.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[48;2;20;40;60m");
    switch (self.opts.mode) {
        .@"render-scroll",
        .@"render-scroll-page",
        .@"render-scroll-overscan",
        => for (0..scroll_setup_lines) |_| s.nextSlice("hello\r\n"),
        else => {},
    }
    for (0..self.terminal.rows - 1) |_| s.nextSlice("hello\r\n");
    s.nextSlice("hello");
    const data_f: std.Io.File = (options.dataFile(
        self.opts.data,
    ) catch |err| {
        log.warn("error opening data file err={}", .{err});
        return error.BenchmarkFailed;
    }) orelse return;
    var stream = self.terminal.vtStream();
    defer stream.deinit();
    var read_buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    var f_reader = data_f.reader(global.io(), &read_buf);
    const r = &f_reader.interface;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = r.readSliceShort(&buf) catch {
            log.warn("error reading data file err={?}", .{f_reader.err});
            return error.BenchmarkFailed;
        };
        if (n == 0) break; 
        stream.nextSlice(buf[0..n]);
    }
}
fn teardown(ptr: *anyopaque) void {
    const self: *ScreenClone = @ptrCast(@alignCast(ptr));
    _ = self;
}
fn stepNoop(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScreenClone = @ptrCast(@alignCast(ptr));
    for (0..1000) |_| {
        const s: terminalpkg.Screen = self.terminal.screens.active.*;
        std.mem.doNotOptimizeAway(s);
    }
}
fn stepClone(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScreenClone = @ptrCast(@alignCast(ptr));
    for (0..1000) |_| {
        const s: *terminalpkg.Screen = self.terminal.screens.active;
        const copy = s.clone(
            s.io,
            s.alloc,
            .{ .viewport = .{} },
            null,
        ) catch |err| {
            log.warn("error cloning screen err={}", .{err});
            return error.BenchmarkFailed;
        };
        std.mem.doNotOptimizeAway(copy);
    }
}
fn stepRender(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScreenClone = @ptrCast(@alignCast(ptr));
    const alloc = self.terminal.screens.active.alloc;
    var state: terminalpkg.RenderState = .empty;
    state.update(alloc, &self.terminal) catch |err| {
        log.warn("error cloning screen err={}", .{err});
        return error.BenchmarkFailed;
    };
    for (0..50_000 * @as(u64, self.opts.loops)) |_| {
        state.screen = .alternate;
        state.update(alloc, &self.terminal) catch |err| {
            log.warn("error cloning screen err={}", .{err});
            return error.BenchmarkFailed;
        };
        std.mem.doNotOptimizeAway(&state);
    }
}
fn stepRenderLocked(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScreenClone = @ptrCast(@alignCast(ptr));
    const alloc = self.terminal.screens.active.alloc;
    var state: terminalpkg.RenderState = .empty;
    state.update(alloc, &self.terminal) catch |err| {
        log.warn("error cloning screen err={}", .{err});
        return error.BenchmarkFailed;
    };
    for (0..50_000 * @as(u64, self.opts.loops)) |_| {
        state.screen = .alternate;
        state.beginUpdate(alloc, &self.terminal) catch |err| {
            log.warn("error cloning screen err={}", .{err});
            return error.BenchmarkFailed;
        };
        std.mem.doNotOptimizeAway(&state);
    }
}
fn stepRenderClean(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScreenClone = @ptrCast(@alignCast(ptr));
    const alloc = self.terminal.screens.active.alloc;
    var state: terminalpkg.RenderState = .empty;
    state.overscan_request = overscanRequest(self.opts.mode);
    state.update(alloc, &self.terminal) catch |err| {
        log.warn("error cloning screen err={}", .{err});
        return error.BenchmarkFailed;
    };
    for (0..3_000_000 * @as(u64, self.opts.loops)) |_| {
        state.update(alloc, &self.terminal) catch |err| {
            log.warn("error cloning screen err={}", .{err});
            return error.BenchmarkFailed;
        };
        std.mem.doNotOptimizeAway(&state);
    }
}
fn stepRenderPartial(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScreenClone = @ptrCast(@alignCast(ptr));
    const alloc = self.terminal.screens.active.alloc;
    var state: terminalpkg.RenderState = .empty;
    state.update(alloc, &self.terminal) catch |err| {
        log.warn("error cloning screen err={}", .{err});
        return error.BenchmarkFailed;
    };
    const pages = &self.terminal.screens.active.pages;
    const pin = pages.pin(.{ .active = .{
        .x = 0,
        .y = self.terminal.rows / 2,
    } }).?;
    for (0..2_000_000 * @as(u64, self.opts.loops)) |_| {
        pin.markDirty();
        state.update(alloc, &self.terminal) catch |err| {
            log.warn("error cloning screen err={}", .{err});
            return error.BenchmarkFailed;
        };
        std.mem.doNotOptimizeAway(&state);
    }
}
fn stepRenderScroll(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScreenClone = @ptrCast(@alignCast(ptr));
    try renderScrollLoop(self, 1, scroll_reverse_interval);
}
fn stepRenderScrollPage(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScreenClone = @ptrCast(@alignCast(ptr));
    try renderScrollLoop(
        self,
        @intCast(@max(1, self.terminal.rows / 2)),
        scroll_page_reverse_interval,
    );
}
fn renderScrollLoop(
    self: *ScreenClone,
    step: isize,
    interval: usize,
) Benchmark.Error!void {
    const alloc = self.terminal.screens.active.alloc;
    var state: terminalpkg.RenderState = .empty;
    state.overscan_request = overscanRequest(self.opts.mode);
    state.update(alloc, &self.terminal) catch |err| {
        log.warn("error cloning screen err={}", .{err});
        return error.BenchmarkFailed;
    };
    var dir: isize = 1;
    for (0..50_000 * @as(u64, self.opts.loops)) |i| {
        if (i % interval == 0) dir = -dir;
        self.terminal.scrollViewport(.{ .delta = dir * step });
        state.update(alloc, &self.terminal) catch |err| {
            log.warn("error cloning screen err={}", .{err});
            return error.BenchmarkFailed;
        };
        std.mem.doNotOptimizeAway(&state);
    }
}
fn stepRenderOutput(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScreenClone = @ptrCast(@alignCast(ptr));
    const alloc = self.terminal.screens.active.alloc;
    var state: terminalpkg.RenderState = .empty;
    state.overscan_request = overscanRequest(self.opts.mode);
    state.update(alloc, &self.terminal) catch |err| {
        log.warn("error cloning screen err={}", .{err});
        return error.BenchmarkFailed;
    };
    self.terminal.scrollViewport(.bottom);
    var stream = self.terminal.vtStream();
    defer stream.deinit();
    for (0..50_000 * @as(u64, self.opts.loops)) |_| {
        stream.nextSlice("hello\r\n");
        state.update(alloc, &self.terminal) catch |err| {
            log.warn("error cloning screen err={}", .{err});
            return error.BenchmarkFailed;
        };
        std.mem.doNotOptimizeAway(&state);
    }
}
