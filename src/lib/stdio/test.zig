const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const Threaded = std.Io.Threaded;
const StdIo = @import("../StdIo.zig");
const supported = StdIo.supported;
const is_windows = builtin.os.tag == .windows;
const windows = std.os.windows;
const os_windows = @import("../../os/windows.zig");
const ntdll = os_windows.exp.ntdll;
const kernel32 = os_windows.exp.kernel32;
const HANDLE = windows.HANDLE;
fn readStreamingAll(file: File, io_: Io, buffers: []const []u8) !usize {
    var remaining: [8][]u8 = undefined;
    std.debug.assert(buffers.len <= remaining.len);
    @memcpy(remaining[0..buffers.len], buffers);
    var list: [][]u8 = remaining[0..buffers.len];
    var total: usize = 0;
    while (list.len > 0) {
        var n = file.readStreaming(io_, list) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        total += n;
        while (list.len > 0 and n >= list[0].len) {
            n -= list[0].len;
            list = list[1..];
        }
        if (list.len > 0) list[0] = list[0][n..];
    }
    return total;
}
test "read a file through File.Reader" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: StdIo = .init;
    const test_io = tio.io();
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const contents = "hello minimal test_io\n" ** 100;
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "test.txt",
        .data = contents,
    });
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    var file = try dir.openFile(test_io, "test.txt", .{});
    defer file.close(test_io);
    const stat = try file.stat(test_io);
    try testing.expectEqual(@as(u64, contents.len), stat.size);
    try testing.expectEqual(File.Kind.file, stat.kind);
    try testing.expectEqual(@as(u64, contents.len), try file.length(test_io));
    var buf: [64]u8 = undefined;
    var reader = file.reader(test_io, &buf);
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try reader.interface.appendRemaining(testing.allocator, &list, .unlimited);
    try testing.expectEqualStrings(contents, list.items);
}
test "seek" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: StdIo = .init;
    const test_io = tio.io();
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "seek.txt",
        .data = "0123456789",
    });
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    var file = try dir.openFile(test_io, "seek.txt", .{});
    defer file.close(test_io);
    var out: [4]u8 = undefined;
    var slices = [_][]u8{&out};
    try test_io.vtable.fileSeekTo(test_io.userdata, file, 6);
    var n = try file.readStreaming(test_io, &slices);
    try testing.expectEqualStrings("6789", out[0..n]);
    try test_io.vtable.fileSeekBy(test_io.userdata, file, -8);
    n = try file.readStreaming(test_io, &slices);
    try testing.expectEqualStrings("2345", out[0..n]);
    var pslices = [_][]u8{&out};
    n = try test_io.vtable.fileReadPositional(test_io.userdata, file, &pslices, 1);
    try testing.expectEqualStrings("1234", out[0..n]);
}
test "realPath and deleteFile" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: StdIo = .init;
    const test_io = tio.io();
    const testing = std.testing;
    switch (builtin.os.tag) {
        .macos, .ios, .linux, .freebsd, .windows => {},
        else => return error.SkipZigTest,
    }
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "real.txt",
        .data = "x",
    });
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    var file = try dir.openFile(test_io, "real.txt", .{});
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try file.realPath(test_io, &path_buf)];
    try testing.expect(std.mem.endsWith(u8, path, "real.txt"));
    file.close(test_io);
    var path_buf2: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path2 = path_buf2[0..try Dir.cwd().realPathFile(test_io, path, &path_buf2)];
    try testing.expectEqualStrings(path, path2);
    try dir.deleteFile(test_io, "real.txt");
    try testing.expectError(error.FileNotFound, dir.openFile(test_io, "real.txt", .{}));
}
test "openFile of a directory returns IsDir" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: StdIo = .init;
    const test_io = tio.io();
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDir(testing.io, "sub", .default_dir);
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    try testing.expectError(error.IsDir, dir.openFile(test_io, "sub", .{
        .allow_directory = false,
    }));
}
test "Io.Mutex through StdIo" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: StdIo = .init;
    const test_io = tio.io();
    var mutex: Io.Mutex = .init;
    mutex.lockUncancelable(test_io);
    mutex.unlock(test_io);
    var word: u32 = 0;
    test_io.vtable.futexWake(test_io.userdata, &word, 1);
    test_io.vtable.futexWaitUncancelable(test_io.userdata, &word, 1);
}
test "randomSecure fills with fresh entropy" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: StdIo = .init;
    const test_io = tio.io();
    const testing = std.testing;
    var a: [32]u8 = @splat(0);
    var b: [32]u8 = @splat(0);
    try test_io.randomSecure(&a);
    try test_io.randomSecure(&b);
    try testing.expect(!std.mem.allEqual(u8, &a, 0));
    try testing.expect(!std.mem.allEqual(u8, &b, 0));
    try testing.expect(!std.mem.eql(u8, &a, &b));
    try test_io.randomSecure(a[0..0]);
}
test "unused operations fail gracefully" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: StdIo = .init;
    const test_io = tio.io();
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    try testing.expectError(
        error.NoSpaceLeft,
        dir.createFile(test_io, "nope.txt", .{}),
    );
}
test "openFile edge cases" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: StdIo = .init;
    const test_io = tio.io();
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "edge.txt",
        .data = "edge",
    });
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    try testing.expectError(error.FileLocksUnsupported, dir.openFile(
        test_io,
        "edge.txt",
        .{ .lock = .shared },
    ));
    try testing.expectError(error.BadPathName, dir.openFile(
        test_io,
        "bad\x00path",
        .{},
    ));
    const long_name = "a" ** (std.Io.Dir.max_path_bytes + 1);
    try testing.expectError(error.NameTooLong, dir.openFile(
        test_io,
        long_name,
        .{},
    ));
    try testing.expectError(
        if (comptime is_windows) error.FileNotFound else error.NotDir,
        dir.openFile(test_io, "edge.txt/child", .{}),
    );
    try tmp_dir.dir.createDir(testing.io, "subdir", .default_dir);
    var dir_file = try dir.openFile(test_io, "subdir", .{});
    const dir_stat = try dir_file.stat(test_io);
    try testing.expectEqual(File.Kind.directory, dir_stat.kind);
    dir_file.close(test_io);
    var wfile = try dir.openFile(test_io, "edge.txt", .{ .mode = .write_only });
    wfile.close(test_io);
    var rwfile = try dir.openFile(test_io, "edge.txt", .{ .mode = .read_write });
    rwfile.close(test_io);
}
test "openFile symlink handling" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: StdIo = .init;
    const test_io = tio.io();
    const testing = std.testing;
    switch (builtin.os.tag) {
        .macos, .ios, .linux, .freebsd => {},
        else => return error.SkipZigTest,
    }
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "target.txt",
        .data = "target",
    });
    try tmp_dir.dir.symLink(testing.io, "target.txt", "link.txt", .{});
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    var file = try dir.openFile(test_io, "link.txt", .{});
    try testing.expectEqual(@as(u64, "target".len), try file.length(test_io));
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try file.realPath(test_io, &path_buf)];
    try testing.expect(std.mem.endsWith(u8, path, "target.txt"));
    file.close(test_io);
    try testing.expectError(error.SymLinkLoop, dir.openFile(
        test_io,
        "link.txt",
        .{ .follow_symlinks = false },
    ));
}
test "positional reads at and beyond EOF return zero" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: StdIo = .init;
    const test_io = tio.io();
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "eof.txt",
        .data = "0123456789",
    });
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    var file = try dir.openFile(test_io, "eof.txt", .{});
    defer file.close(test_io);
    var out: [4]u8 = undefined;
    var slices = [_][]u8{&out};
    try testing.expectEqual(@as(usize, 0), try test_io.vtable.fileReadPositional(
        test_io.userdata,
        file,
        &slices,
        10,
    ));
    try testing.expectEqual(@as(usize, 0), try test_io.vtable.fileReadPositional(
        test_io.userdata,
        file,
        &slices,
        9999,
    ));
    try testing.expectEqual(@as(usize, 0), try test_io.vtable.fileReadPositional(
        test_io.userdata,
        file,
        &.{},
        0,
    ));
    var empty = [_][]u8{ &.{}, &.{} };
    try testing.expectEqual(@as(usize, 0), try test_io.vtable.fileReadPositional(
        test_io.userdata,
        file,
        &empty,
        0,
    ));
}
test "vectored reads scatter across buffers" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: StdIo = .init;
    const test_io = tio.io();
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "vec.txt",
        .data = "0123456789abcdef",
    });
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    var file = try dir.openFile(test_io, "vec.txt", .{});
    defer file.close(test_io);
    var a: [4]u8 = undefined;
    var b: [2]u8 = undefined;
    var c: [6]u8 = undefined;
    var slices = [_][]u8{ &a, &.{}, &b, &c };
    const n = try test_io.vtable.fileReadPositional(
        test_io.userdata,
        file,
        &slices,
        0,
    );
    try testing.expectEqual(@as(usize, 12), n);
    try testing.expectEqualStrings("0123", &a);
    try testing.expectEqualStrings("45", &b);
    try testing.expectEqualStrings("6789ab", &c);
    comptime std.debug.assert(Threaded.max_iovecs_len < 16);
    var bytes: [16][1]u8 = undefined;
    var many: [16][]u8 = undefined;
    for (&many, &bytes) |*s, *byte| s.* = byte;
    const n2 = try test_io.vtable.fileReadPositional(
        test_io.userdata,
        file,
        &many,
        0,
    );
    try testing.expectEqual(@as(usize, Threaded.max_iovecs_len), n2);
    for (bytes[0..n2], "0123456789abcdef"[0..n2]) |got, want| {
        try testing.expectEqual(want, got[0]);
    }
}
test "streaming reads: EndOfStream and scatter" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: StdIo = .init;
    const test_io = tio.io();
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "stream.txt",
        .data = "streaming!",
    });
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    var file = try dir.openFile(test_io, "stream.txt", .{});
    defer file.close(test_io);
    var a: [6]u8 = undefined;
    var b: [4]u8 = undefined;
    var slices = [_][]u8{ &a, &b };
    try testing.expectEqual(@as(usize, 10), try readStreamingAll(file, test_io, &slices));
    try testing.expectEqualStrings("stream", &a);
    try testing.expectEqualStrings("ing!", &b);
    try testing.expectError(error.EndOfStream, file.readStreaming(test_io, &slices));
    try testing.expectEqual(@as(usize, 0), try file.readStreaming(test_io, &.{}));
    try test_io.vtable.fileSeekTo(test_io.userdata, file, 9999);
    try testing.expectError(error.EndOfStream, file.readStreaming(test_io, &slices));
    try test_io.vtable.fileSeekTo(test_io.userdata, file, 0);
    try testing.expectEqual(@as(usize, 10), try readStreamingAll(file, test_io, &slices));
    try testing.expectEqualStrings("stream", &a);
}
test "pipes: streaming works; positional and seek are Unseekable or ignored" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: StdIo = .init;
    const test_io = tio.io();
    const testing = std.testing;
    const msg = "through the pipe";
    const read_end: File = if (comptime is_windows) pipe: {
        var read_h: HANDLE = undefined;
        var write_h: HANDLE = undefined;
        if (!kernel32.CreatePipe(&read_h, &write_h, null, 0).toBool()) {
            return error.SkipZigTest;
        }
        defer _ = ntdll.NtClose(write_h);
        for (0..2) |_| {
            var iosb: os_windows.IO_STATUS_BLOCK = undefined;
            try testing.expectEqual(.SUCCESS, windows.ntdll.NtWriteFile(
                write_h,
                null,
                null,
                null,
                &iosb,
                msg.ptr,
                msg.len,
                null,
                null,
            ));
        }
        break :pipe .{ .handle = read_h, .flags = .{ .nonblocking = false } };
    } else pipe: {
        var fds: [2]posix.fd_t = undefined;
        switch (posix.errno(posix.system.pipe(&fds))) {
            .SUCCESS => {},
            else => return error.SkipZigTest,
        }
        defer _ = posix.system.close(fds[1]);
        try testing.expectEqual(
            @as(isize, msg.len),
            @as(isize, @intCast(posix.system.write(fds[1], msg, msg.len))),
        );
        break :pipe .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    };
    defer read_end.close(test_io);
    var buf: [msg.len]u8 = undefined;
    var slices = [_][]u8{&buf};
    try testing.expectEqual(@as(usize, msg.len), try read_end.readStreaming(test_io, &slices));
    try testing.expectEqualStrings(msg, &buf);
    if (comptime is_windows) {
        @memset(&buf, 0);
        try testing.expectEqual(@as(usize, msg.len), try test_io.vtable.fileReadPositional(
            test_io.userdata,
            read_end,
            &slices,
            8,
        ));
        try testing.expectEqualStrings(msg, &buf);
        try test_io.vtable.fileSeekTo(test_io.userdata, read_end, 0);
        try test_io.vtable.fileSeekBy(test_io.userdata, read_end, 1);
        try testing.expectError(error.EndOfStream, read_end.readStreaming(test_io, &slices));
        return;
    }
    try testing.expectError(error.Unseekable, test_io.vtable.fileReadPositional(
        test_io.userdata,
        read_end,
        &slices,
        0,
    ));
    try testing.expectError(error.Unseekable, test_io.vtable.fileSeekTo(
        test_io.userdata,
        read_end,
        0,
    ));
    try testing.expectError(error.Unseekable, test_io.vtable.fileSeekBy(
        test_io.userdata,
        read_end,
        1,
    ));
}
test "operate delegates non-read operations to failing stubs" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: StdIo = .init;
    const test_io = tio.io();
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "w.txt",
        .data = "x",
    });
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    var file = try dir.openFile(test_io, "w.txt", .{ .mode = .write_only });
    defer file.close(test_io);
    const result = try test_io.vtable.operate(test_io.userdata, .{
        .file_write_streaming = .{
            .file = file,
            .data = &.{"nope"},
        },
    });
    try testing.expectError(error.InputOutput, result.file_write_streaming);
}
test "dirRealPathFile edge cases" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: StdIo = .init;
    const test_io = tio.io();
    const testing = std.testing;
    switch (builtin.os.tag) {
        .macos, .ios, .linux, .freebsd, .windows => {},
        else => return error.SkipZigTest,
    }
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "real.txt",
        .data = "x",
    });
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    var file = try dir.openFile(test_io, "real.txt", .{});
    var want_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const want = want_buf[0..try file.realPath(test_io, &want_buf)];
    file.close(test_io);
    var got_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const got = got_buf[0..try test_io.vtable.dirRealPathFile(
        test_io.userdata,
        dir,
        "real.txt",
        &got_buf,
    )];
    try testing.expectEqualStrings(want, got);
    var missing_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const missing = std.fmt.bufPrint(&missing_buf, "{s}.missing", .{want}) catch
        return error.SkipZigTest;
    var out_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try testing.expectError(error.FileNotFound, Dir.cwd().realPathFile(
        test_io,
        missing,
        &out_buf,
    ));
    var small_buf: [8]u8 = undefined;
    try testing.expectError(error.NameTooLong, Dir.cwd().realPathFile(
        test_io,
        want,
        &small_buf,
    ));
}
test "deleteFile edge cases" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: StdIo = .init;
    const test_io = tio.io();
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir: Dir = .{ .handle = tmp_dir.dir.handle };
    try testing.expectError(error.FileNotFound, dir.deleteFile(test_io, "missing.txt"));
    try testing.expectError(error.BadPathName, dir.deleteFile(test_io, "bad\x00path"));
    try tmp_dir.dir.createDir(testing.io, "subdir", .default_dir);
    try testing.expectError(error.IsDir, dir.deleteFile(test_io, "subdir"));
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "target.txt",
        .data = "x",
    });
    tmp_dir.dir.symLink(testing.io, "target.txt", "link.txt", .{}) catch |err| switch (err) {
        error.AccessDenied => if (comptime is_windows) return error.SkipZigTest else return err,
        else => return err,
    };
    try dir.deleteFile(test_io, "link.txt");
    var file = try dir.openFile(test_io, "target.txt", .{});
    file.close(test_io);
    try testing.expectError(error.FileNotFound, dir.openFile(test_io, "link.txt", .{}));
}
test "dirClose closes the descriptor" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: StdIo = .init;
    const test_io = tio.io();
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDir(testing.io, "subdir", .default_dir);
    const opened = try tmp_dir.dir.openDir(testing.io, "subdir", .{});
    const dir: Dir = .{ .handle = opened.handle };
    test_io.vtable.dirClose(test_io.userdata, &.{dir});
    if (comptime is_windows) {
        var iosb: os_windows.IO_STATUS_BLOCK = undefined;
        var info: os_windows.FILE_STANDARD_INFORMATION = undefined;
        try testing.expectEqual(.INVALID_HANDLE, ntdll.NtQueryInformationFile(
            dir.handle,
            &iosb,
            &info,
            @sizeOf(os_windows.FILE_STANDARD_INFORMATION),
            .Standard,
        ));
        return;
    }
    try testing.expectEqual(posix.E.BADF, posix.errno(posix.system.dup(dir.handle)));
}
test "cancel protection operations are benign" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: StdIo = .init;
    const test_io = tio.io();
    const testing = std.testing;
    try test_io.vtable.checkCancel(test_io.userdata);
    const prev = test_io.vtable.swapCancelProtection(test_io.userdata, .blocked);
    _ = test_io.vtable.swapCancelProtection(test_io.userdata, prev);
    test_io.vtable.recancel(test_io.userdata);
    _ = testing;
}
test "async runs inline; concurrency is unavailable" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: StdIo = .init;
    const test_io = tio.io();
    const testing = std.testing;
    const S = struct {
        fn work(x: *u32) u32 {
            x.* += 1;
            return x.*;
        }
    };
    var state: u32 = 41;
    var future = test_io.async(S.work, .{&state});
    try testing.expectEqual(@as(u32, 42), state);
    try testing.expectEqual(@as(u32, 42), future.await(test_io));
    try testing.expectError(
        error.ConcurrencyUnavailable,
        test_io.concurrent(S.work, .{&state}),
    );
    try testing.expectEqual(@as(u32, 42), state);
}
test "futex timed waits return" {
    if (comptime !supported) return error.SkipZigTest;
    const tio: StdIo = .init;
    const test_io = tio.io();
    var word: u32 = 1;
    try test_io.vtable.futexWait(test_io.userdata, &word, 1, .{
        .duration = .{ .raw = .fromNanoseconds(5 * std.time.ns_per_ms), .clock = .awake },
    });
    try test_io.vtable.futexWait(test_io.userdata, &word, 1, .{
        .deadline = .{ .raw = .fromNanoseconds(1), .clock = .awake },
    });
    try test_io.vtable.futexWait(test_io.userdata, &word, 2, .none);
    test_io.vtable.futexWake(test_io.userdata, &word, 2);
    test_io.vtable.futexWake(test_io.userdata, &word, std.math.maxInt(u32));
}
test "Io.Mutex under real thread contention" {
    if (comptime !supported) return error.SkipZigTest;
    if (comptime builtin.single_threaded) return error.SkipZigTest;
    const tio: StdIo = .init;
    const test_io = tio.io();
    const testing = std.testing;
    const S = struct {
        const iterations = 10_000;
        fn worker(m: *Io.Mutex, io_: Io, counter: *u64) void {
            for (0..iterations) |_| {
                m.lockUncancelable(io_);
                defer m.unlock(io_);
                counter.* += 1;
            }
        }
    };
    var mutex: Io.Mutex = .init;
    var counter: u64 = 0;
    const thread_count = 4;
    var threads: [thread_count]std.Thread = undefined;
    var spawned: usize = 0;
    defer for (threads[0..spawned]) |t| t.join();
    for (&threads) |*t| {
        t.* = std.Thread.spawn(.{}, S.worker, .{ &mutex, test_io, &counter }) catch
            break;
        spawned += 1;
    }
    for (threads[0..spawned]) |t| t.join();
    spawned = 0;
    try testing.expectEqual(@as(u64, S.iterations * thread_count), counter);
}
