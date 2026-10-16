const std = @import("std");
const builtin = @import("builtin");
const wuffs = @import("wuffs");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const posix = std.posix;
const fastmem = @import("../../fastmem.zig");
const animation = @import("graphics_animation.zig");
const command = @import("graphics_command.zig");
const kitty_windows = @import("windows.zig");
const PageList = @import("../PageList.zig");
const sys = @import("../sys.zig");
const LimitedAllocator = @import("../../datastruct/root.zig").LimitedAllocator;
const log = std.log.scoped(.kitty_gfx);
const max_dimension = 10000;
const max_size = 400 * 1024 * 1024;
pub const LoadingImage = struct {
    image: Image,
    data: std.ArrayListUnmanaged(u8) = .empty,
    display: ?command.Display = null,
    frame: ?FrameContext = null,
    quiet: command.Command.Quiet,
    response: command.Response = .{},
    temporary_directory: ?[]const u8,
    pub const FrameContext = struct {
        cmd: command.AnimationFrameLoading,
        image_generation: u64,
    };
    pub const Limits = struct {
        file: bool,
        temporary_file: union(enum) {
            enabled: struct {
                directory: []const u8,
            },
            disabled: void,
        },
        shared_memory: bool,
        pub fn allWithTempDir(path: []const u8) Limits {
            return .{
                .file = true,
                .temporary_file = .{ .enabled = .{ .directory = path } },
                .shared_memory = true,
            };
        }
        pub const direct: Limits = .{
            .file = false,
            .temporary_file = .disabled,
            .shared_memory = false,
        };
    };
    pub fn init(
        io: std.Io,
        alloc: Allocator,
        cmd: *const command.Command,
        limits: Limits,
    ) !LoadingImage {
        const t = cmd.transmission().?;
        if (t.format_unknown) return error.UnsupportedFormat;
        var result: LoadingImage = .{
            .image = .{
                .id = t.image_id,
                .number = t.image_number,
                .width = t.width,
                .height = t.height,
                .compression = t.compression,
                .format = t.format,
                .metadata = .{ .transient = t.usage.transient },
            },
            .display = cmd.display(),
            .quiet = cmd.quiet,
            .response = .{
                .id = t.image_id,
                .image_number = t.image_number,
                .placement_id = t.placement_id,
            },
            .temporary_directory = switch (limits.temporary_file) {
                .enabled => |d| d.directory,
                .disabled => null,
            },
        };
        if (t.medium == .direct) {
            try result.addData(alloc, cmd.data);
            return result;
        }
        {
            if (t.format == .png and
                sys.decode_png == null)
            {
                return error.UnsupportedMedium;
            }
            switch (t.medium) {
                .direct => unreachable,
                .file => if (!limits.file) return error.UnsupportedMedium,
                .temporary_file => if (limits.temporary_file == .disabled) return error.UnsupportedMedium,
                .shared_memory => if (!limits.shared_memory) return error.UnsupportedMedium,
            }
        }
        if (comptime builtin.os.tag != .windows) {
            if (std.mem.indexOfScalar(u8, cmd.data, 0) != null) {
                log.warn("invalid image path: BadPathName", .{});
                return error.InvalidData;
            }
        }
        switch (t.medium) {
            .direct => unreachable,
            .file => try result.readFile(.file, io, alloc, t, cmd.data),
            .temporary_file => try result.readFile(.temporary_file, io, alloc, t, cmd.data),
            .shared_memory => try result.readSharedMemory(io, alloc, t, cmd.data),
        }
        return result;
    }
    fn readSharedMemory(
        self: *LoadingImage,
        io: std.Io,
        alloc: Allocator,
        t: command.Transmission,
        path: []const u8,
    ) !void {
        if (comptime builtin.abi.isAndroid() or builtin.target.os.tag == .windows) {
            return error.UnsupportedMedium;
        }
        if (comptime !builtin.link_libc) {
            return error.UnsupportedMedium;
        }
        if (!validSharedMemoryName(path, posix.NAME_MAX)) {
            log.warn("invalid shared memory name", .{});
            return error.InvalidData;
        }
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const pathz = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return error.InvalidData;
        const fd = std.c.shm_open(pathz, @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDONLY })), @as(u16, 0));
        switch (std.posix.errno(fd)) {
            .SUCCESS => {},
            else => |err| {
                log.warn("unable to open shared memory {s}: {}", .{ path, err });
                return error.InvalidData;
            },
        }
        const file: std.Io.File = .{
            .handle = fd,
            .flags = .{ .nonblocking = false },
        };
        defer file.close(io);
        defer _ = std.c.shm_unlink(pathz);
        const stat_size: usize = stat: {
            const stat = file.stat(io) catch |err| {
                log.warn("unable to fstat shared memory {s}: {}", .{ path, err });
                return error.InvalidData;
            };
            if (stat.size <= 0) return error.InvalidData;
            break :stat std.math.cast(usize, stat.size) orelse
                return error.InvalidData;
        };
        const range = try self.sharedMemoryRange(t, stat_size);
        const map = std.posix.mmap(
            null,
            stat_size,
            .{ .READ = true },
            std.c.MAP{ .TYPE = .SHARED },
            fd,
            0,
        ) catch |err| {
            log.warn("unable to mmap shared memory {s}: {}", .{ path, err });
            return error.InvalidData;
        };
        defer std.posix.munmap(map);
        assert(self.data.items.len == 0);
        try self.data.appendSlice(alloc, map[range.start..range.end]);
    }
    const SharedMemoryRange = struct {
        start: usize,
        end: usize,
    };
    fn sharedMemoryRange(
        self: *const LoadingImage,
        t: command.Transmission,
        stat_size: usize,
    ) error{
        InvalidData,
        DimensionsTooLarge,
    }!SharedMemoryRange {
        const expected_size: ?usize = switch (self.image.format) {
            .png => null,
            .gray, .gray_alpha, .rgb, .rgba => size: {
                if (self.image.width > max_dimension or
                    self.image.height > max_dimension)
                {
                    return error.DimensionsTooLarge;
                }
                const bpp: usize = command.Transmission.formatBpp(self.image.format);
                break :size @as(usize, self.image.width) *
                    @as(usize, self.image.height) * bpp;
            },
        };
        const start = std.math.cast(usize, t.offset) orelse
            return error.InvalidData;
        if (start > stat_size) return error.InvalidData;
        const available = stat_size - start;
        const data_size: usize = if (t.size > 0)
            std.math.cast(usize, t.size) orelse return error.InvalidData
        else if (self.image.compression == .none and expected_size != null)
            expected_size.?
        else
            available;
        if (data_size > max_size or data_size > available) {
            return error.InvalidData;
        }
        return .{ .start = start, .end = start + data_size };
    }
    fn readFile(
        self: *LoadingImage,
        comptime medium: command.Transmission.Medium,
        io: std.Io,
        alloc: Allocator,
        t: command.Transmission,
        path: []const u8,
    ) !void {
        switch (medium) {
            .file, .temporary_file => {},
            else => @compileError("readFile only supports file and temporary_file"),
        }
        if (comptime builtin.os.tag == .windows) {
            kitty_windows.checkPath(path) catch |err| {
                log.warn("invalid image path: {}", .{err});
                return error.InvalidData;
            };
        }
        const abs_buf = try alloc.alloc(u8, std.Io.Dir.max_path_bytes);
        defer alloc.free(abs_buf);
        var file = std.Io.Dir.cwd().openFile(
            io,
            path,
            .{},
        ) catch |err| {
            log.warn("failed to open image file: {}", .{err});
            return error.InvalidData;
        };
        var delete_path: ?[]const u8 = null;
        defer {
            file.close(io);
            if (delete_path) |p| {
                std.Io.Dir.cwd().deleteFile(io, p) catch |err| {
                    log.warn("failed to delete temporary file: {}", .{err});
                };
            }
        }
        const abs_path = validatedFilePath(
            io,
            file,
            abs_buf,
        ) catch |err| {
            log.warn("failed to validate image file path: {}", .{err});
            return error.InvalidData;
        };
        if (medium == .temporary_file) {
            assert(self.temporary_directory != null);
            if (!try isPathInTempDir(
                io,
                alloc,
                self.temporary_directory.?,
                abs_path,
            )) return error.TemporaryFileNotInTempDir;
            if (std.mem.indexOf(
                u8,
                abs_path,
                "tty-graphics-protocol",
            ) == null) return error.TemporaryFileNotNamedCorrectly;
            delete_path = abs_path;
        }
        if (file.stat(io)) |stat| {
            if (stat.kind != .file) {
                log.warn("file is not a regular file kind={}", .{stat.kind});
                return error.InvalidData;
            }
        } else |err| {
            log.warn("failed to stat file: {}", .{err});
            return error.InvalidData;
        }
        var buf: [4096]u8 = undefined;
        var buf_reader = file.reader(io, &buf);
        if (t.offset > 0) {
            buf_reader.seekTo(@intCast(t.offset)) catch |err| {
                log.warn("failed to seek to offset {}: {}", .{ t.offset, err });
                return error.InvalidData;
            };
        }
        const reader = &buf_reader.interface;
        var managed: std.ArrayList(u8) = .empty;
        errdefer managed.deinit(alloc);
        if (t.size > 0) {
            const size = std.math.cast(usize, t.size) orelse
                return error.InvalidData;
            if (size > max_size) return error.InvalidData;
            const data = reader.readAlloc(alloc, size) catch |err| {
                log.warn("failed to read image file: {}", .{err});
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.InvalidData,
                };
            };
            managed = .{ .items = data, .capacity = data.len };
        } else {
            reader.appendRemaining(alloc, &managed, .limited(max_size)) catch {
                log.warn("failed to read image file: {?}", .{buf_reader.err});
                return error.InvalidData;
            };
        }
        assert(self.data.items.len == 0);
        self.data = .{ .items = managed.items, .capacity = managed.capacity };
    }
    fn validatedFilePath(io: std.Io, file: std.Io.File, buf: []u8) ![]const u8 {
        const path = buf[0..try file.realPath(io, buf)];
        if (comptime builtin.os.tag == .windows) {
            try kitty_windows.checkCanonicalPath(path);
            return path;
        }
        if (std.mem.startsWith(u8, path, "/proc/") or
            std.mem.startsWith(u8, path, "/sys/") or
            (std.mem.startsWith(u8, path, "/dev/") and
                !std.mem.startsWith(u8, path, "/dev/shm/")))
        {
            return error.InvalidData;
        }
        return path;
    }
    fn isPathInTempDir(
        io: std.Io,
        alloc: Allocator,
        dir: []const u8,
        path: []const u8,
    ) Allocator.Error!bool {
        if (isPathInDir("/tmp", path)) return true;
        if (isPathInDir("/dev/shm", path)) return true;
        if (isPathInDir(dir, path)) return true;
        if (comptime builtin.os.tag.isDarwin()) {
            if (isPathInDir("/private/tmp", path)) return true;
        }
        const buf = try alloc.alloc(u8, std.Io.Dir.max_path_bytes);
        defer alloc.free(buf);
        const real_dir = buf[0 .. std.Io.Dir.cwd().realPathFile(
            io,
            dir,
            buf,
        ) catch return false];
        if (isPathInDir(real_dir, path)) return true;
        return false;
    }
    pub fn deinit(self: *LoadingImage, alloc: Allocator) void {
        self.image.deinit(alloc);
        self.data.deinit(alloc);
    }
    pub fn destroy(self: *LoadingImage, alloc: Allocator) void {
        self.deinit(alloc);
        alloc.destroy(self);
    }
    pub fn addData(self: *LoadingImage, alloc: Allocator, data: []const u8) !void {
        if (data.len == 0) return;
        if (self.data.items.len + data.len > max_size) {
            log.warn("image data too large max_size={}", .{max_size});
            return error.InvalidData;
        }
        try self.data.ensureUnusedCapacity(alloc, data.len);
        const start_i = self.data.items.len;
        self.data.items.len = start_i + data.len;
        fastmem.copy(u8, self.data.items[start_i..], data);
    }
    pub fn complete(self: *LoadingImage, alloc: Allocator) !Image {
        const img = &self.image;
        try self.decompress(alloc);
        if (img.format == .png) try self.decodePng(alloc);
        if (img.width == 0 or img.height == 0) return error.DimensionsRequired;
        if (img.width > max_dimension or img.height > max_dimension) return error.DimensionsTooLarge;
        const bpp = command.Transmission.formatBpp(img.format);
        const expected_len = img.width * img.height * bpp;
        const actual_len = self.data.items.len;
        if (self.frame != null) {
            if (actual_len < expected_len) {
                std.log.warn(
                    "insufficient frame data image id={} expected_len={} actual_len={}",
                    .{ img.id, expected_len, actual_len },
                );
                return error.InsufficientData;
            }
            self.data.items.len = expected_len;
        } else if (actual_len != expected_len) {
            std.log.warn(
                "unexpected length image id={} width={} height={} bpp={} expected_len={} actual_len={}",
                .{ img.id, img.width, img.height, bpp, expected_len, actual_len },
            );
            return error.InvalidData;
        }
        var result = self.image;
        result.data = .{ .complete = try self.data.toOwnedSlice(alloc) };
        errdefer result.deinit(alloc);
        self.image = .{};
        return result;
    }
    pub fn debugDump(io: std.Io, self: LoadingImage) !void {
        if (comptime builtin.mode != .Debug) @compileError("debugDump in non-debug");
        var buf: [1024]u8 = undefined;
        const filename = try std.fmt.bufPrint(
            &buf,
            "image-{s}-{s}-{d}x{d}-{}.data",
            .{
                @tagName(self.image.format),
                @tagName(self.image.compression),
                self.image.width,
                self.image.height,
                self.image.id,
            },
        );
        const cwd = std.Io.Dir.cwd();
        const f = try cwd.createFile(io, filename, .{});
        defer f.close(io);
        const writer = f.writer();
        try writer.writeAll(self.data.items);
    }
    fn decompress(self: *LoadingImage, alloc: Allocator) !void {
        return switch (self.image.compression) {
            .none => {},
            .zlib_deflate => self.decompressZlib(alloc),
        };
    }
    fn decompressZlib(self: *LoadingImage, alloc: Allocator) !void {
        const size_hint: ?usize = hint: {
            if (self.image.format == .png or
                self.image.width == 0 or self.image.height == 0 or
                self.image.width > max_dimension or self.image.height > max_dimension)
                break :hint null;
            const pixels = std.math.mul(
                usize,
                self.image.width,
                self.image.height,
            ) catch break :hint null;
            const bytes = std.math.mul(
                usize,
                pixels,
                command.Transmission.formatBpp(self.image.format),
            ) catch break :hint null;
            break :hint if (bytes <= max_size) bytes else null;
        };
        const decompressed = wuffs.zlib.decode(
            alloc,
            self.data.items,
            max_size,
            size_hint,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.WuffsError, error.Overflow => return error.DecompressionFailed,
        };
        self.data.deinit(alloc);
        self.data = .{ .items = decompressed, .capacity = decompressed.len };
        self.image.compression = .none;
    }
    fn decodePng(self: *LoadingImage, alloc: Allocator) !void {
        assert(self.image.format == .png);
        const decode_png_fn = sys.decode_png orelse
            return error.UnsupportedFormat;
        var limited: LimitedAllocator = .init(alloc, max_size);
        const decode_alloc = limited.allocator();
        const result = decode_png_fn(
            decode_alloc,
            self.data.items,
        ) catch |err| switch (err) {
            error.InvalidData => return error.InvalidData,
            error.OutOfMemory => if (limited.limit_exceeded)
                return error.InvalidData
            else
                return error.OutOfMemory,
        };
        defer decode_alloc.free(result.data);
        if (result.data.len > max_size) {
            log.warn("png image too large size={} max_size={}", .{ result.data.len, max_size });
            return error.InvalidData;
        }
        self.data.deinit(alloc);
        self.data = .empty;
        try self.data.ensureUnusedCapacity(alloc, result.data.len);
        try self.data.appendSlice(alloc, result.data[0..result.data.len]);
        self.image.width = result.width;
        self.image.height = result.height;
        self.image.format = .rgba;
    }
};
pub const Image = struct {
    id: u32 = 0,
    number: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    format: command.Transmission.Format = .rgb,
    compression: command.Transmission.Compression = .none,
    data: Data = .{ .complete = "" },
    metadata: packed struct(u32) {
        transient: bool = false,
        implicit_id: bool = false,
        placement_count: u30 = 0,
    } = .{},
    generation: u64 = 0,
    animation: ?*animation.Animation = null,
    pub const Error = error{
        InsufficientData,
        InvalidData,
        DecompressionFailed,
        DimensionsRequired,
        DimensionsTooLarge,
        FilePathTooLong,
        TemporaryFileNotInTempDir,
        TemporaryFileNotNamedCorrectly,
        UnsupportedFormat,
        UnsupportedMedium,
        UnsupportedDepth,
    };
    pub const Data = union(enum) {
        complete: []const u8,
        pending: usize,
        pub fn len(self: Data) usize {
            return switch (self) {
                .complete => |data| data.len,
                .pending => |expected_len| expected_len,
            };
        }
        pub fn bytes(self: Data) ?[]const u8 {
            return switch (self) {
                .complete => |data| data,
                .pending => null,
            };
        }
        pub fn isPending(self: Data) bool {
            return self == .pending;
        }
        pub fn deinit(self: *Data, alloc: Allocator) void {
            switch (self.*) {
                .complete => |data| if (data.len > 0) alloc.free(data),
                .pending => {},
            }
        }
    };
    pub fn deinit(self: *Image, alloc: Allocator) void {
        self.data.deinit(alloc);
        if (self.animation) |anim| {
            anim.deinit(alloc);
            alloc.destroy(anim);
            self.animation = null;
        }
    }
    pub fn renderData(self: *const Image) Data {
        if (self.animation) |anim| {
            if (anim.current_index > 0) {
                return .{ .complete = anim.frames.items[anim.current_index - 1].data };
            }
        }
        return self.data;
    }
    pub fn frameData(self: *const Image, number: u32) ?[]const u8 {
        switch (number) {
            0 => return null,
            1 => return self.data.bytes(),
            else => {
                const anim = self.animation orelse return null;
                const idx = number - 2;
                if (idx >= anim.frames.items.len) return null;
                return anim.frames.items[idx].data;
            },
        }
    }
    pub fn storageSize(self: *const Image) usize {
        var total: usize = self.data.len();
        if (self.animation) |anim| total += anim.frameBytes();
        return total;
    }
    pub fn withoutData(self: *const Image) Image {
        var copy = self.*;
        if (copy.data == .complete) copy.data = .{ .complete = "" };
        return copy;
    }
};
pub const Rect = struct {
    top_left: PageList.Pin,
    bottom_right: PageList.Pin,
    pub fn contains(self: Rect, cell: PageList.Pin) bool {
        if (cell.x < self.top_left.x or cell.x > self.bottom_right.x) return false;
        var row = cell;
        row.x = self.top_left.x;
        return row.isBetween(self.top_left, self.bottom_right);
    }
};
fn validSharedMemoryName(name: []const u8, name_max: usize) bool {
    if (name.len < 2 or name.len > name_max or name[0] != '/') return false;
    for (name[1..]) |c| {
        if (c == '/' or c == 0) return false;
    }
    return true;
}
fn isPathInDir(dir: []const u8, path: []const u8) bool {
    if (dir.len == 0 or !std.mem.startsWith(u8, path, dir)) return false;
    if (path.len == dir.len or std.fs.path.isSep(dir[dir.len - 1])) return true;
    return std.fs.path.isSep(path[dir.len]);
}
test {
    _ = kitty_windows;
}
test "temporary file path must be inside directory" {
    const testing = std.testing;
    try testing.expect(isPathInDir("/tmp", "/tmp/tty-graphics-protocol-image.data"));
    try testing.expect(isPathInDir("/tmp/", "/tmp/tty-graphics-protocol-image.data"));
    try testing.expect(isPathInDir("/tmp", "/tmp"));
    try testing.expect(!isPathInDir("", "/tmp/tty-graphics-protocol-image.data"));
    try testing.expect(!isPathInDir("/tmp", "/tmpX/tty-graphics-protocol-image.data"));
    try testing.expect(!isPathInDir("/dev/shm", "/dev/shm-evil/tty-graphics-protocol-image.data"));
    try testing.expect(!isPathInDir("/custom/tmp", "/custom/tmp-suffix/tty-graphics-protocol-image.data"));
}
test "shared memory names follow POSIX rules" {
    const testing = std.testing;
    try testing.expect(validSharedMemoryName("/kitty", 8));
    try testing.expect(validSharedMemoryName("/1234567", 8));
    try testing.expect(!validSharedMemoryName("", 8));
    try testing.expect(!validSharedMemoryName("/", 8));
    try testing.expect(!validSharedMemoryName("kitty", 8));
    try testing.expect(!validSharedMemoryName("/kitty/image", 16));
    try testing.expect(!validSharedMemoryName("/kitty\x00image", 16));
    try testing.expect(!validSharedMemoryName("/12345678", 8));
}
test "image load rejects invalid POSIX shared memory names" {
    if (comptime builtin.abi.isAndroid() or
        builtin.target.os.tag == .windows or
        !builtin.link_libc)
    {
        return error.SkipZigTest;
    }
    const testing = std.testing;
    const alloc = testing.allocator;
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .shared_memory,
            .width = 1,
            .height = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, "kitty-without-leading-slash"),
    };
    defer cmd.deinit(alloc);
    try testing.expectError(
        error.InvalidData,
        LoadingImage.init(testing.io, alloc, &cmd, .{
            .file = false,
            .temporary_file = .disabled,
            .shared_memory = true,
        }),
    );
}
test "shared memory range with offset and size" {
    const testing = std.testing;
    const loading: LoadingImage = .{
        .image = .{
            .width = 1,
            .height = 1,
            .format = .rgb,
        },
        .quiet = .no,
        .temporary_directory = null,
    };
    const explicit = try loading.sharedMemoryRange(.{
        .offset = 2,
        .size = 3,
    }, 5);
    try testing.expectEqual(@as(usize, 2), explicit.start);
    try testing.expectEqual(@as(usize, 5), explicit.end);
    const implicit = try loading.sharedMemoryRange(.{
        .offset = 2,
    }, 5);
    try testing.expectEqual(@as(usize, 2), implicit.start);
    try testing.expectEqual(@as(usize, 5), implicit.end);
}
test "shared memory range rejects out of bounds offset" {
    const loading: LoadingImage = .{
        .image = .{
            .width = 1,
            .height = 1,
            .format = .rgb,
        },
        .quiet = .no,
        .temporary_directory = null,
    };
    try std.testing.expectError(
        error.InvalidData,
        loading.sharedMemoryRange(.{ .offset = 4 }, 3),
    );
}
test "shared memory range validates dimensions before multiplication" {
    const loading: LoadingImage = .{
        .image = .{
            .width = std.math.maxInt(u32),
            .height = std.math.maxInt(u32),
            .format = .rgba,
        },
        .quiet = .no,
        .temporary_directory = null,
    };
    try std.testing.expectError(
        error.DimensionsTooLarge,
        loading.sharedMemoryRange(.{}, 1),
    );
}
test "image load with invalid RGB data" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .width = 1,
            .height = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, "AAAA"),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);
}
test "image load with image too wide" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .width = max_dimension + 1,
            .height = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, "AAAA"),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);
    try testing.expectError(error.DimensionsTooLarge, loading.complete(alloc));
}
test "image load with image too tall" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .height = max_dimension + 1,
            .width = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, "AAAA"),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);
    try testing.expectError(error.DimensionsTooLarge, loading.complete(alloc));
}
test "image load: rgb, zlib compressed, direct" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .direct,
            .compression = .zlib_deflate,
            .height = 96,
            .width = 128,
            .image_id = 31,
        } },
        .data = try alloc.dupe(
            u8,
            @embedFile("testdata/image-rgb-zlib_deflate-128x96-2147483647-raw.data"),
        ),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
}
test "image load: rgb, not compressed, direct" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .direct,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(
            u8,
            @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data"),
        ),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
}
test "image load: rgb, zlib compressed, direct, chunked" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    const data = @embedFile("testdata/image-rgb-zlib_deflate-128x96-2147483647-raw.data");
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .direct,
            .compression = .zlib_deflate,
            .height = 96,
            .width = 128,
            .image_id = 31,
            .more_chunks = true,
        } },
        .data = try alloc.dupe(u8, data[0..1024]),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);
    var fbs: std.Io.Reader = .fixed(data[1024..]);
    var buf: [1024]u8 = undefined;
    while (fbs.readSliceShort(&buf)) |size| {
        try loading.addData(alloc, buf[0..size]);
        if (size < buf.len) break;
    } else |err| return err;
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
}
test "image load: rgb, zlib compressed, direct, chunked with zero initial chunk" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    const data = @embedFile("testdata/image-rgb-zlib_deflate-128x96-2147483647-raw.data");
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .direct,
            .compression = .zlib_deflate,
            .height = 96,
            .width = 128,
            .image_id = 31,
            .more_chunks = true,
        } },
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);
    var fbs: std.Io.Reader = .fixed(data);
    var buf: [1024]u8 = undefined;
    while (fbs.readSliceShort(&buf)) |size| {
        try loading.addData(alloc, buf[0..size]);
        if (size < buf.len) break;
    } else |err| return err;
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
}
test "image load: temporary file without correct path" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "image.data",
        .data = data,
    });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp_dir.dir.realPathFile(testing.io, "image.data", &buf)];
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .temporary_file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    var dir_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try testing.expectError(error.TemporaryFileNotNamedCorrectly, LoadingImage.init(
        io,
        alloc,
        &cmd,
        .allWithTempDir(dir_path_buf[0..try tmp_dir.dir.realPath(testing.io, &dir_path_buf)]),
    ));
    try tmp_dir.dir.access(testing.io, path, .{});
}
test "image load: temporary file outside directory prefix is rejected" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDir(io, "temp", .default_dir);
    try tmp_dir.dir.createDir(io, "temp-suffix", .default_dir);
    var trusted_dir = try tmp_dir.dir.openDir(io, "temp", .{});
    defer trusted_dir.close(io);
    var outside_dir = try tmp_dir.dir.openDir(io, "temp-suffix", .{});
    defer outside_dir.close(io);
    const filename = "tty-graphics-protocol-image.data";
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try outside_dir.writeFile(io, .{
        .sub_path = filename,
        .data = data,
    });
    var trusted_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const trusted_path = trusted_path_buf[0..try trusted_dir.realPath(io, &trusted_path_buf)];
    var outside_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const outside_path = outside_path_buf[0..try outside_dir.realPathFile(io, filename, &outside_path_buf)];
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .temporary_file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, outside_path),
    };
    defer cmd.deinit(alloc);
    try testing.expectError(
        error.TemporaryFileNotInTempDir,
        LoadingImage.init(io, alloc, &cmd, .allWithTempDir(trusted_path)),
    );
    try outside_dir.access(io, filename, .{});
}
test "image load: temporary file in /tmp on macOS" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = dir_path_buf[0..try tmp_dir.dir.realPath(io, &dir_path_buf)];
    const path = try std.fmt.allocPrint(
        alloc,
        "/tmp/wasp-test-{s}-tty-graphics-protocol-image.data",
        .{tmp_dir.sub_path},
    );
    defer alloc.free(path);
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .temporary_file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(io, alloc, &cmd, .allWithTempDir(dir_path));
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(io, path, .{}),
    );
}
test "image load: rgb, not compressed, temporary file" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "tty-graphics-protocol-image.data",
        .data = data,
    });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp_dir.dir.realPathFile(testing.io, "tty-graphics-protocol-image.data", &buf)];
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .temporary_file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    var dir_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var loading = try LoadingImage.init(
        io,
        alloc,
        &cmd,
        .allWithTempDir(dir_path_buf[0..try tmp_dir.dir.realPath(testing.io, &dir_path_buf)]),
    );
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
    try testing.expectError(error.FileNotFound, tmp_dir.dir.access(testing.io, path, .{}));
}
test "image load: rgb, not compressed, regular file" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "image.data",
        .data = data,
    });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp_dir.dir.realPathFile(testing.io, "image.data", &buf)];
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    var dir_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var loading = try LoadingImage.init(
        io,
        alloc,
        &cmd,
        .allWithTempDir(dir_path_buf[0..try tmp_dir.dir.realPath(testing.io, &dir_path_buf)]),
    );
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
    try tmp_dir.dir.access(testing.io, path, .{});
}
test "image load: regular file size reads exactly requested bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(io, .{
        .sub_path = "image.data",
        .data = &.{ 1, 2, 3, 4, 5, 6 },
    });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try tmp_dir.dir.realPathFile(
        io,
        "image.data",
        &path_buf,
    )];
    const cases = [_]struct {
        offset: u32,
        expected: [3]u8,
    }{
        .{ .offset = 0, .expected = .{ 1, 2, 3 } },
        .{ .offset = 3, .expected = .{ 4, 5, 6 } },
    };
    for (cases) |case| {
        var cmd: command.Command = .{
            .control = .{ .transmit = .{
                .format = .rgb,
                .medium = .file,
                .width = 1,
                .height = 1,
                .size = 3,
                .offset = case.offset,
                .image_id = 31,
            } },
            .data = try alloc.dupe(u8, path),
        };
        defer cmd.deinit(alloc);
        var loading = try LoadingImage.init(io, alloc, &cmd, .{
            .file = true,
            .temporary_file = .disabled,
            .shared_memory = false,
        });
        defer loading.deinit(alloc);
        var img = try loading.complete(alloc);
        defer img.deinit(alloc);
        try testing.expectEqualSlices(u8, &case.expected, img.data.complete);
    }
}
test "image load: regular file size rejects short data" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(io, .{
        .sub_path = "image.data",
        .data = &.{ 1, 2 },
    });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try tmp_dir.dir.realPathFile(
        io,
        "image.data",
        &path_buf,
    )];
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .file,
            .width = 1,
            .height = 1,
            .size = 3,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    try testing.expectError(
        error.InvalidData,
        LoadingImage.init(io, alloc, &cmd, .{
            .file = true,
            .temporary_file = .disabled,
            .shared_memory = false,
        }),
    );
}
test "image load: rgb, not compressed, relative regular file" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "image.data",
        .data = data,
    });
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try std.fmt.allocPrint(
            alloc,
            ".zig-cache/tmp/{s}/image.data",
            .{tmp_dir.sub_path},
        ),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(io, alloc, &cmd, .{
        .file = true,
        .temporary_file = .disabled,
        .shared_memory = false,
    });
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
}
test "image load: blocklist applies to opened file after symlink swap" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(io, .{
        .sub_path = "safe.data",
        .data = "safe",
    });
    try tmp_dir.dir.symLink(io, "/dev/null", "image.data", .{});
    const blocked_file = try tmp_dir.dir.openFile(io, "image.data", .{});
    defer blocked_file.close(io);
    try tmp_dir.dir.symLinkAtomic(io, "safe.data", "image.data", .{});
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try testing.expectError(
        error.InvalidData,
        LoadingImage.validatedFilePath(io, blocked_file, &path_buf),
    );
    const safe_file = try tmp_dir.dir.openFile(io, "image.data", .{});
    defer safe_file.close(io);
    _ = try LoadingImage.validatedFilePath(io, safe_file, &path_buf);
}
test "image load: windows UNC path is rejected before open" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    const paths = [_][]const u8{
        "\\\\nonexistent-host.invalid\\share\\tty-graphics-protocol-image.data",
        "//nonexistent-host.invalid/share/tty-graphics-protocol-image.data",
        "\\\\?\\UNC\\nonexistent-host.invalid\\share\\image.data",
    };
    for (paths) |path| {
        var cmd: command.Command = .{
            .control = .{ .transmit = .{
                .format = .rgb,
                .medium = .file,
                .compression = .none,
                .width = 20,
                .height = 15,
                .image_id = 31,
            } },
            .data = try alloc.dupe(u8, path),
        };
        defer cmd.deinit(alloc);
        try testing.expectError(
            error.InvalidData,
            LoadingImage.init(io, alloc, &cmd, .{
                .file = true,
                .temporary_file = .disabled,
                .shared_memory = false,
            }),
        );
    }
}
test "image load: windows device namespace paths are rejected before open" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const filename = "tty-graphics-protocol-image.data";
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = filename, .data = data });
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = dir_buf[0..try tmp_dir.dir.realPath(io, &dir_buf)];
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_path = path_buf[0..try tmp_dir.dir.realPathFile(io, filename, &path_buf)];
    const prefixes = [_][]const u8{ "\\\\?\\", "\\\\.\\", "\\??\\" };
    for (prefixes) |prefix| {
        const path = try std.mem.concat(alloc, u8, &.{ prefix, real_path });
        defer alloc.free(path);
        const mediums = [_]command.Transmission.Medium{ .file, .temporary_file };
        for (mediums) |medium| {
            var cmd: command.Command = .{
                .control = .{ .transmit = .{
                    .format = .rgb,
                    .medium = medium,
                    .compression = .none,
                    .width = 20,
                    .height = 15,
                    .image_id = 31,
                } },
                .data = try alloc.dupe(u8, path),
            };
            defer cmd.deinit(alloc);
            try testing.expectError(
                error.InvalidData,
                LoadingImage.init(io, alloc, &cmd, .allWithTempDir(dir_path)),
            );
        }
    }
    {
        var cmd: command.Command = .{
            .control = .{ .transmit = .{
                .format = .rgb,
                .medium = .file,
                .compression = .none,
                .width = 20,
                .height = 15,
                .image_id = 31,
            } },
            .data = try alloc.dupe(u8, "\\\\.\\pipe\\wasp-kitty-graphics-test"),
        };
        defer cmd.deinit(alloc);
        try testing.expectError(
            error.InvalidData,
            LoadingImage.init(io, alloc, &cmd, .allWithTempDir(dir_path)),
        );
    }
    try tmp_dir.dir.access(io, filename, .{});
}
test "image load: windows reserved device names are rejected before open" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = dir_buf[0..try tmp_dir.dir.realPath(io, &dir_buf)];
    const names = [_][]const u8{ "CON", "NUL.data", "com1", "LPT9.png", "AUX", "PRN." };
    for (names) |name| {
        const path = try std.fs.path.join(alloc, &.{ dir_path, name });
        defer alloc.free(path);
        var cmd: command.Command = .{
            .control = .{ .transmit = .{
                .format = .rgb,
                .medium = .file,
                .compression = .none,
                .width = 20,
                .height = 15,
                .image_id = 31,
            } },
            .data = try alloc.dupe(u8, path),
        };
        defer cmd.deinit(alloc);
        try testing.expectError(
            error.InvalidData,
            LoadingImage.init(io, alloc, &cmd, .{
                .file = true,
                .temporary_file = .disabled,
                .shared_memory = false,
            }),
        );
    }
}
test "image load: windows local file accepted in forward slash and upper case spellings" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const filename = "image.data";
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = filename, .data = data });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_path = path_buf[0..try tmp_dir.dir.realPathFile(io, filename, &path_buf)];
    const forward = try alloc.dupe(u8, real_path);
    defer alloc.free(forward);
    std.mem.replaceScalar(u8, forward, '\\', '/');
    const upper = try alloc.dupe(u8, real_path);
    defer alloc.free(upper);
    _ = std.ascii.upperString(upper, real_path);
    const spellings = [_][]const u8{ forward, upper };
    for (spellings) |path| {
        var cmd: command.Command = .{
            .control = .{ .transmit = .{
                .format = .rgb,
                .medium = .file,
                .compression = .none,
                .width = 20,
                .height = 15,
                .image_id = 31,
            } },
            .data = try alloc.dupe(u8, path),
        };
        defer cmd.deinit(alloc);
        var loading = try LoadingImage.init(io, alloc, &cmd, .{
            .file = true,
            .temporary_file = .disabled,
            .shared_memory = false,
        });
        defer loading.deinit(alloc);
        var img = try loading.complete(alloc);
        defer img.deinit(alloc);
        try testing.expect(img.compression == .none);
    }
    try tmp_dir.dir.access(io, filename, .{});
}
test "image load: windows temporary file with differently spelled directory" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const filename = "tty-graphics-protocol-image.data";
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = filename, .data = data });
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = dir_buf[0..try tmp_dir.dir.realPath(io, &dir_buf)];
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_path = path_buf[0..try tmp_dir.dir.realPathFile(io, filename, &path_buf)];
    const dir_upper = try alloc.dupe(u8, dir_path);
    defer alloc.free(dir_upper);
    _ = std.ascii.upperString(dir_upper, dir_path);
    const path_upper = try alloc.dupe(u8, real_path);
    defer alloc.free(path_upper);
    _ = std.ascii.upperString(path_upper, real_path);
    try testing.expect(!isPathInDir(dir_upper, real_path) or
        std.mem.eql(u8, dir_upper, dir_path));
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .temporary_file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path_upper),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(io, alloc, &cmd, .allWithTempDir(dir_upper));
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
    try testing.expectError(error.FileNotFound, tmp_dir.dir.access(io, filename, .{}));
}
test "image load: windows canonical path check accepts a local file opened through a device spelling" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const filename = "image.data";
    try tmp_dir.dir.writeFile(io, .{ .sub_path = filename, .data = "safe" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_path = path_buf[0..try tmp_dir.dir.realPathFile(io, filename, &path_buf)];
    const device_path = try std.mem.concat(alloc, u8, &.{ "\\\\.\\", real_path });
    defer alloc.free(device_path);
    const file = try std.Io.Dir.cwd().openFile(io, device_path, .{});
    defer file.close(io);
    const canon_buf = try alloc.alloc(u8, std.Io.Dir.max_path_bytes);
    defer alloc.free(canon_buf);
    const canon = try LoadingImage.validatedFilePath(io, file, canon_buf);
    try testing.expectEqualStrings(real_path, canon);
}
test "image load: windows canonical path check rejects a file reached through a UNC share" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const filename = "image.data";
    try tmp_dir.dir.writeFile(io, .{ .sub_path = filename, .data = "safe" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_path = path_buf[0..try tmp_dir.dir.realPathFile(io, filename, &path_buf)];
    try testing.expect(kitty_windows.isDriveAbsolute(real_path));
    const unc_path = try std.fmt.allocPrint(
        alloc,
        "\\\\localhost\\{c}$\\{s}",
        .{ real_path[0], real_path[3..] },
    );
    defer alloc.free(unc_path);
    const file = std.Io.Dir.cwd().openFile(io, unc_path, .{}) catch
        return error.SkipZigTest;
    defer file.close(io);
    const canon_buf = try alloc.alloc(u8, std.Io.Dir.max_path_bytes);
    defer alloc.free(canon_buf);
    try testing.expectError(
        error.NotDriveAbsolute,
        LoadingImage.validatedFilePath(io, file, canon_buf),
    );
}
test "image load: png, not compressed, regular file" {
    if (sys.decode_png == null) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-png-none-50x76-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "tty-graphics-protocol-image.data",
        .data = data,
    });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp_dir.dir.realPathFile(testing.io, "tty-graphics-protocol-image.data", &buf)];
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .png,
            .medium = .file,
            .compression = .none,
            .width = 0,
            .height = 0,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    var dir_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var loading = try LoadingImage.init(
        io,
        alloc,
        &cmd,
        .allWithTempDir(dir_path_buf[0..try tmp_dir.dir.realPath(testing.io, &dir_path_buf)]),
    );
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expect(img.compression == .none);
    try testing.expect(img.format == .rgba);
    try tmp_dir.dir.access(testing.io, path, .{});
}
test "image load: png, zlib compressed, direct" {
    if (sys.decode_png == null) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    const data = @embedFile("testdata/image-png-zlib_deflate-50x76-2147483647-raw.data");
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .png,
            .medium = .direct,
            .compression = .zlib_deflate,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, data),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);
    var img = try loading.complete(alloc);
    defer img.deinit(alloc);
    try testing.expectEqual(command.Transmission.Compression.none, img.compression);
    try testing.expectEqual(command.Transmission.Format.rgba, img.format);
    try testing.expectEqual(@as(u32, 50), img.width);
    try testing.expectEqual(@as(u32, 76), img.height);
}
test "image load: png rejects oversized decoder allocation" {
    const testing = std.testing;
    const oversized_decoder = struct {
        fn decode(
            alloc: Allocator,
            _: []const u8,
        ) sys.DecodeError!sys.Image {
            const data = try alloc.alloc(u8, max_size + 1);
            return .{
                .width = 1,
                .height = 1,
                .data = data,
            };
        }
    }.decode;
    const original_decode_png = sys.decode_png;
    defer sys.decode_png = original_decode_png;
    sys.decode_png = &oversized_decoder;
    var failing = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });
    const alloc = failing.allocator();
    var loading: LoadingImage = .{
        .image = .{ .format = .png },
        .quiet = .no,
        .temporary_directory = null,
    };
    defer loading.deinit(alloc);
    try testing.expectError(error.InvalidData, loading.complete(alloc));
    try testing.expect(!failing.has_induced_failure);
}
test "image load: png rejects oversized Wuffs image before allocation" {
    if (sys.decode_png == null) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var data = @embedFile("testdata/image-png-none-50x76-2147483647-raw.data").*;
    std.mem.writeInt(u32, data[16..20], 32768, .big);
    std.mem.writeInt(u32, data[20..24], 32767, .big);
    std.mem.writeInt(u32, data[29..33], std.hash.Crc32.hash(data[12..29]), .big);
    const cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .png,
            .medium = .direct,
        } },
        .data = &data,
    };
    var loading = try LoadingImage.init(testing.io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);
    try testing.expectError(error.InvalidData, loading.complete(alloc));
}
test "limits: direct medium always allowed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .direct,
            .width = 1,
            .height = 1,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, "AAAA"),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(io, alloc, &cmd, .direct);
    defer loading.deinit(alloc);
}
test "limits: file medium blocked by limits" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "image.data",
        .data = data,
    });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp_dir.dir.realPathFile(testing.io, "image.data", &buf)];
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    try testing.expectError(error.UnsupportedMedium, LoadingImage.init(io, alloc, &cmd, .direct));
}
test "limits: file medium allowed by limits" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "image.data",
        .data = data,
    });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp_dir.dir.realPathFile(testing.io, "image.data", &buf)];
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    var loading = try LoadingImage.init(io, alloc, &cmd, .{
        .file = true,
        .temporary_file = .disabled,
        .shared_memory = false,
    });
    defer loading.deinit(alloc);
}
test "limits: temporary file medium blocked by limits" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "tty-graphics-protocol-image.data",
        .data = data,
    });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp_dir.dir.realPathFile(testing.io, "tty-graphics-protocol-image.data", &buf)];
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .temporary_file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    try testing.expectError(error.UnsupportedMedium, LoadingImage.init(io, alloc, &cmd, .{
        .file = true,
        .temporary_file = .disabled,
        .shared_memory = true,
    }));
    try tmp_dir.dir.access(testing.io, "tty-graphics-protocol-image.data", .{});
}
test "limits: temporary file medium allowed by limits" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const data = @embedFile("testdata/image-rgb-none-20x15-2147483647-raw.data");
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "tty-graphics-protocol-image.data",
        .data = data,
    });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = buf[0..try tmp_dir.dir.realPathFile(testing.io, "tty-graphics-protocol-image.data", &buf)];
    var cmd: command.Command = .{
        .control = .{ .transmit = .{
            .format = .rgb,
            .medium = .temporary_file,
            .compression = .none,
            .width = 20,
            .height = 15,
            .image_id = 31,
        } },
        .data = try alloc.dupe(u8, path),
    };
    defer cmd.deinit(alloc);
    var dir_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var loading = try LoadingImage.init(
        io,
        alloc,
        &cmd,
        .{
            .file = false,
            .temporary_file = .{
                .enabled = .{ .directory = dir_path_buf[0..try tmp_dir.dir.realPath(testing.io, &dir_path_buf)] },
            },
            .shared_memory = false,
        },
    );
    defer loading.deinit(alloc);
}
