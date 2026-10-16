const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("wasp.zig").Action;
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const font = @import("../font/root.zig");
const configpkg = @import("../config.zig");
const Config = configpkg.Config;
const global = @import("../global.zig");
pub const Options = struct {
    _arena: ?ArenaAllocator = null,
    cp: ?u21 = null,
    string: ?[]const u8 = null,
    style: font.Style = .regular,
    presentation: ?font.Presentation = null,
    _diagnostics: diagnostics.DiagnosticList = .{},
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
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(global.io(), &stdout_buffer);
    const stdout = &stdout_writer.interface;
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stdout().writer(global.io(), &stderr_buffer);
    const stderr = &stderr_writer.interface;
    const result = runArgs(
        alloc,
        &iter,
        stdout,
        stderr,
    );
    stdout.flush() catch {};
    stderr.flush() catch {};
    return result;
}
fn runArgs(
    alloc_gpa: Allocator,
    argsIter: anytype,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (comptime font.Discover == void) {
        try stderr.print(
            \\Wasp was built without a font discovery mechanism. This is a compile-time
            \\option. Please review how Wasp was built from source, contact the
            \\maintainer to enable a font discovery mechanism, and try again.
        ,
            .{},
        );
        return 1;
    }
    var opts: Options = .{};
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
    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    if (opts.cp == null and opts.string == null) {
        try stderr.print("You must specify a codepoint with --cp or a string with --string\n", .{});
        return 1;
    }
    var config = Config.load(alloc) catch |err| {
        try stderr.print("Unable to load config: {}", .{err});
        return 1;
    };
    defer config.deinit();
    if (!config._diagnostics.empty()) {
        outer: for (config._diagnostics.items()) |diagnostic| {
            inner: inline for (@typeInfo(Options).@"struct".fields) |field| {
                if (field.name[0] == '_') continue :inner;
                if (std.mem.eql(u8, field.name, diagnostic.key) and (diagnostic.location == .none or diagnostic.location == .cli)) continue :outer;
            }
            try stderr.print("config error: {f}\n", .{diagnostic});
        }
    }
    var font_grid_set = font.SharedGridSet.init(alloc) catch |err| {
        try stderr.print("Unable to initialize font grid set: {}", .{err});
        return 1;
    };
    errdefer font_grid_set.deinit();
    const font_size: font.face.DesiredSize = .{
        .points = config.@"font-size",
        .xdpi = 96,
        .ydpi = 96,
    };
    var font_config = font.SharedGridSet.DerivedConfig.init(alloc, config) catch |err| {
        try stderr.print("Unable to initialize font config: {}", .{err});
        return 1;
    };
    const font_grid_key, const font_grid = font_grid_set.ref(
        &font_config,
        font_size,
    ) catch |err| {
        try stderr.print("Unable to get font grid: {}", .{err});
        return 1;
    };
    defer font_grid_set.deref(font_grid_key);
    if (opts.cp) |cp| {
        if (try lookup(alloc, stdout, stderr, font_grid, opts.style, opts.presentation, cp)) |rc| return rc;
    }
    if (opts.string) |string| {
        const view = std.unicode.Utf8View.init(string) catch |err| {
            try stderr.print("Unable to parse string as unicode: {}", .{err});
            return 1;
        };
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (try lookup(alloc, stdout, stderr, font_grid, opts.style, opts.presentation, cp)) |rc| return rc;
        }
    }
    return 0;
}
fn lookup(
    alloc: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    font_grid: *font.SharedGrid,
    style: font.Style,
    presentation: ?font.Presentation,
    cp: u21,
) !?u8 {
    const idx = font_grid.resolver.getIndex(alloc, cp, style, presentation) orelse {
        try stdout.print("U+{0X:0>2} « {0u} » not found.\n", .{cp});
        return null;
    };
    const face = font_grid.resolver.collection.getFace(idx) catch |err| switch (err) {
        error.SpecialHasNoFace => {
            try stdout.print("U+{0X:0>2} « {0u} » is handled by Wasp's internal sprites.\n", .{cp});
            return null;
        },
        else => {
            try stderr.print("Unable to get face: {}", .{err});
            return 1;
        },
    };
    var buf: [1024]u8 = undefined;
    const name = face.name(&buf) catch |err| {
        try stderr.print("Unable to get name of face: {}", .{err});
        return 1;
    };
    try stdout.print("U+{0X:0>2} « {0u} » found in face “{1s}”.\n", .{ cp, name });
    return null;
}
