const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").wasp.Action;
const apprt = @import("../apprt.zig");
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const homedir = @import("../os/homedir.zig");
const global = @import("../global.zig");
pub const Options = struct {
    _io: std.Io,
    _arena: ?ArenaAllocator = null,
    class: ?[:0]const u8 = null,
    _working_directory_seen: bool = false,
    _arguments: std.ArrayList([:0]const u8) = .empty,
    _diagnostics: diagnostics.DiagnosticList = .{},
    pub const ParseManuallyHookError = error{InvalidValue} ||
        homedir.ExpandError ||
        std.Io.Dir.RealPathFileAllocError ||
        Allocator.Error;
    pub fn parseManuallyHook(
        self: *Options,
        alloc: Allocator,
        arg: []const u8,
        iter: anytype,
    ) ParseManuallyHookError!bool {
        var e_seen: bool = std.mem.eql(u8, arg, "-e");
        if (try self.checkArg(alloc, arg)) |a| try self._arguments.append(alloc, a);
        while (iter.next()) |param| {
            if (e_seen) {
                try self._arguments.append(alloc, try alloc.dupeZ(u8, param));
                continue;
            }
            if (std.mem.eql(u8, param, "-e")) {
                e_seen = true;
                try self._arguments.append(alloc, try alloc.dupeZ(u8, param));
                continue;
            }
            if (try self.checkArg(alloc, param)) |a| try self._arguments.append(alloc, a);
        }
        return false;
    }
    const CheckArgError = error{InvalidValue} ||
        homedir.ExpandError ||
        std.Io.Dir.RealPathFileAllocError ||
        Allocator.Error;
    fn checkArg(self: *Options, alloc: Allocator, arg: []const u8) CheckArgError!?[:0]const u8 {
        if (std.mem.cutPrefix(u8, arg, "--class=")) |rest| {
            self.class = try alloc.dupeZ(u8, std.mem.trim(u8, rest, &std.ascii.whitespace));
            return null;
        }
        if (std.mem.cutPrefix(u8, arg, "--working-directory=")) |rest| {
            const stripped = std.mem.trim(u8, rest, &std.ascii.whitespace);
            if (std.mem.eql(u8, stripped, "home")) return try alloc.dupeZ(u8, arg);
            if (std.mem.eql(u8, stripped, "inherit")) return try alloc.dupeZ(u8, arg);
            const cwd: std.Io.Dir = .cwd();
            var expandhome_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const expanded = expanded: {
                var environ_map = try global.environMap();
                defer environ_map.deinit();
                break :expanded try homedir.expandHome(global.io(), &environ_map, stripped, &expandhome_buf);
            };
            var realpath_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const realpath = realpath_buf[0..try cwd.realPathFile(self._io, expanded, &realpath_buf)];
            self._working_directory_seen = true;
            return try std.fmt.allocPrintSentinel(alloc, "--working-directory={s}", .{realpath}, 0);
        }
        return try alloc.dupeZ(u8, arg);
    }
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
    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
    const stderr = &stderr_writer.interface;
    const result = runArgs(alloc, &iter, stderr);
    stderr.flush() catch {};
    return result;
}
fn runArgs(
    alloc_gpa: Allocator,
    argsIter: anytype,
    stderr: *std.Io.Writer,
) !u8 {
    var opts: Options = .{ ._io = global.io() };
    defer opts.deinit();
    args.parse(Options, alloc_gpa, &opts, argsIter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => {
            try stderr.print("Error parsing args: {}\n", .{err});
            return 1;
        },
    };
    if (!opts._diagnostics.empty()) {
        var exit: bool = false;
        outer: for (opts._diagnostics.items()) |diagnostic| {
            if (diagnostic.location != .cli) continue :outer;
            inner: inline for (@typeInfo(Options).@"struct".fields) |field| {
                if (field.name[0] == '_') continue :inner;
                if (std.mem.eql(u8, field.name, diagnostic.key)) {
                    try stderr.print("config error: {f}\n", .{diagnostic});
                    exit = true;
                }
            }
        }
        if (exit) return 1;
    }
    if (!opts._working_directory_seen) {
        const alloc = opts._arena.?.allocator();
        const cwd: std.Io.Dir = .cwd();
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const wd = buf[0..try cwd.realPathFile(global.io(), ".", &buf)];
        try opts._arguments.insert(alloc, 0, try std.fmt.allocPrintSentinel(
            alloc,
            "--working-directory={s}",
            .{wd},
            0,
        ));
    }
    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    if (apprt.App.performIpc(
        alloc,
        if (opts.class) |class| .{ .class = class } else .detect,
        .new_window,
        .{
            .arguments = if (opts._arguments.items.len == 0) null else opts._arguments.items,
        },
    ) catch |err| switch (err) {
        error.IPCFailed => {
            return 1;
        },
        else => {
            try stderr.print("Sending the IPC failed: {}", .{err});
            return 1;
        },
    }) return 0;
    try stderr.print("+new-window is not supported on this platform.\n", .{});
    return 1;
}
