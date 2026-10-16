const StdIo = @This();
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
pub const supported: bool = switch (builtin.os.tag) {
    .wasi, .freestanding, .other, .uefi => false,
    else => true,
};
pub const init: StdIo = .{};
pub fn io(self: StdIo) Io {
    _ = self;
    return .{
        .userdata = null,
        .vtable = &vtable,
    };
}
const vtable: Io.VTable = if (!supported) std.Io.failing.vtable.* else .{
    .crashHandler = Io.noCrashHandler,
    .async = Io.noAsync,
    .concurrent = Io.failingConcurrent,
    .await = Io.unreachableAwait,
    .cancel = Io.unreachableCancel,
    .groupAsync = Io.noGroupAsync,
    .groupConcurrent = Io.failingGroupConcurrent,
    .groupAwait = Io.unreachableGroupAwait,
    .groupCancel = Io.unreachableGroupCancel,
    .recancel = recancel,
    .swapCancelProtection = swapCancelProtection,
    .checkCancel = checkCancel,
    .futexWait = futexWait,
    .futexWaitUncancelable = futexWaitUncancelable,
    .futexWake = futexWake,
    .operate = operate,
    .batchAwaitAsync = Io.unreachableBatchAwaitAsync,
    .batchAwaitConcurrent = Io.unreachableBatchAwaitConcurrent,
    .batchCancel = Io.unreachableBatchCancel,
    .dirCreateDir = Io.failingDirCreateDir,
    .dirCreateDirPath = Io.failingDirCreateDirPath,
    .dirCreateDirPathOpen = Io.failingDirCreateDirPathOpen,
    .dirOpenDir = Io.failingDirOpenDir,
    .dirStat = Io.failingDirStat,
    .dirStatFile = Io.failingDirStatFile,
    .dirAccess = Io.failingDirAccess,
    .dirCreateFile = Io.failingDirCreateFile,
    .dirCreateFileAtomic = Io.failingDirCreateFileAtomic,
    .dirOpenFile = impl.dirOpenFile,
    .dirClose = impl.dirClose,
    .dirRead = Io.noDirRead,
    .dirRealPath = Io.failingDirRealPath,
    .dirRealPathFile = impl.dirRealPathFile,
    .dirDeleteFile = impl.dirDeleteFile,
    .dirDeleteDir = Io.failingDirDeleteDir,
    .dirRename = Io.failingDirRename,
    .dirRenamePreserve = Io.failingDirRenamePreserve,
    .dirSymLink = Io.failingDirSymLink,
    .dirReadLink = Io.failingDirReadLink,
    .dirSetOwner = Io.failingDirSetOwner,
    .dirSetFileOwner = Io.failingDirSetFileOwner,
    .dirSetPermissions = Io.failingDirSetPermissions,
    .dirSetFilePermissions = Io.failingDirSetFilePermissions,
    .dirSetTimestamps = Io.noDirSetTimestamps,
    .dirHardLink = Io.failingDirHardLink,
    .fileStat = impl.fileStat,
    .fileLength = impl.fileLength,
    .fileClose = impl.fileClose,
    .fileWritePositional = Io.failingFileWritePositional,
    .fileWriteFileStreaming = Io.noFileWriteFileStreaming,
    .fileWriteFilePositional = Io.noFileWriteFilePositional,
    .fileReadPositional = impl.fileReadPositional,
    .fileSeekBy = impl.fileSeekBy,
    .fileSeekTo = impl.fileSeekTo,
    .fileSync = Io.failingFileSync,
    .fileIsTty = Io.unreachableFileIsTty,
    .fileEnableAnsiEscapeCodes = Io.unreachableFileEnableAnsiEscapeCodes,
    .fileSupportsAnsiEscapeCodes = Io.unreachableFileSupportsAnsiEscapeCodes,
    .fileSetLength = Io.failingFileSetLength,
    .fileSetOwner = Io.failingFileSetOwner,
    .fileSetPermissions = Io.failingFileSetPermissions,
    .fileSetTimestamps = Io.noFileSetTimestamps,
    .fileLock = Io.failingFileLock,
    .fileTryLock = Io.failingFileTryLock,
    .fileUnlock = Io.unreachableFileUnlock,
    .fileDowngradeLock = Io.failingFileDowngradeLock,
    .fileRealPath = impl.fileRealPath,
    .fileHardLink = Io.failingFileHardLink,
    .fileMemoryMapCreate = Io.failingFileMemoryMapCreate,
    .fileMemoryMapDestroy = Io.unreachableFileMemoryMapDestroy,
    .fileMemoryMapSetLength = Io.unreachableFileMemoryMapSetLength,
    .fileMemoryMapRead = Io.unreachableFileMemoryMapRead,
    .fileMemoryMapWrite = Io.unreachableFileMemoryMapWrite,
    .processExecutableOpen = Io.failingProcessExecutableOpen,
    .processExecutablePath = Io.failingProcessExecutablePath,
    .lockStderr = Io.unreachableLockStderr,
    .tryLockStderr = Io.noTryLockStderr,
    .unlockStderr = Io.unreachableUnlockStderr,
    .processCurrentPath = Io.failingProcessCurrentPath,
    .processSetCurrentDir = Io.failingProcessSetCurrentDir,
    .processSetCurrentPath = Io.failingProcessSetCurrentPath,
    .processReplace = Io.failingProcessReplace,
    .processReplacePath = Io.failingProcessReplacePath,
    .processSpawn = Io.failingProcessSpawn,
    .processSpawnPath = Io.failingProcessSpawnPath,
    .childWait = Io.unreachableChildWait,
    .childKill = Io.unreachableChildKill,
    .progressParentFile = Io.failingProgressParentFile,
    .random = Io.noRandom,
    .randomSecure = randomSecure,
    .now = Io.noNow,
    .clockResolution = Io.failingClockResolution,
    .sleep = Io.noSleep,
    .netListenIp = Io.failingNetListenIp,
    .netAccept = Io.failingNetAccept,
    .netBindIp = Io.failingNetBindIp,
    .netConnectIp = Io.failingNetConnectIp,
    .netListenUnix = Io.failingNetListenUnix,
    .netConnectUnix = Io.failingNetConnectUnix,
    .netSocketCreatePair = Io.failingNetSocketCreatePair,
    .netSend = Io.failingNetSend,
    .netRead = Io.failingNetRead,
    .netWrite = Io.failingNetWrite,
    .netWriteFile = Io.failingNetWriteFile,
    .netClose = Io.unreachableNetClose,
    .netShutdown = Io.failingNetShutdown,
    .netInterfaceNameResolve = Io.failingNetInterfaceNameResolve,
    .netInterfaceName = Io.unreachableNetInterfaceName,
    .netLookup = Io.failingNetLookup,
};
const impl = switch (builtin.os.tag) {
    .windows => @import("stdio/windows.zig"),
    else => @import("stdio/posix.zig"),
};
fn recancel(_: ?*anyopaque) void {}
fn swapCancelProtection(
    _: ?*anyopaque,
    new: Io.CancelProtection,
) Io.CancelProtection {
    _ = new;
    return .blocked;
}
fn checkCancel(_: ?*anyopaque) Io.Cancelable!void {}
fn randomSecure(_: ?*anyopaque, buffer: []u8) Io.RandomSecureError!void {
    if (buffer.len == 0) return;
    return impl.randomSecure(buffer);
}
fn operate(
    userdata: ?*anyopaque,
    operation: Io.Operation,
) Io.Cancelable!Io.Operation.Result {
    switch (operation) {
        .file_read_streaming => |o| return .{
            .file_read_streaming = impl.fileReadStreaming(o.file, o.data),
        },
        else => return Io.failingOperate(userdata, operation),
    }
}
fn timeoutToNs(timeout: Io.Timeout) ?u64 {
    return switch (timeout) {
        .none => null,
        .duration => |d| @intCast(@max(0, d.raw.toNanoseconds())),
        .deadline => 10 * std.time.ns_per_ms,
    };
}
fn futexWait(
    userdata: ?*anyopaque,
    ptr: *const u32,
    expected: u32,
    timeout: Io.Timeout,
) Io.Cancelable!void {
    _ = userdata;
    impl.futexWaitInner(ptr, expected, timeoutToNs(timeout));
}
fn futexWaitUncancelable(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
    _ = userdata;
    impl.futexWaitInner(ptr, expected, null);
}
fn futexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
    return impl.futexWake(userdata, ptr, max_waiters);
}
test {
    _ = @import("stdio/test.zig");
}
