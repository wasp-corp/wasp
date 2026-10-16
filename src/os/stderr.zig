const std = @import("std");
const builtin = @import("builtin");
pub fn write(bytes: []const u8) void {
    switch (builtin.os.tag) {
        .freestanding, .other => {},
        .windows => {
            const windows = std.os.windows;
            const handle = windows.peb().ProcessParameters.hStdError;
            var iosb: windows.IO_STATUS_BLOCK = undefined;
            _ = windows.ntdll.NtWriteFile(
                handle,
                null, 
                null, 
                null, 
                &iosb,
                bytes.ptr,
                @intCast(bytes.len),
                null, 
                null, 
            );
        },
        else => {
            const posix = std.posix;
            var i: usize = 0;
            while (i < bytes.len) {
                const rc = posix.system.write(
                    posix.STDERR_FILENO,
                    bytes[i..].ptr,
                    bytes.len - i,
                );
                switch (posix.errno(rc)) {
                    .SUCCESS => i += @as(usize, @intCast(rc)),
                    .INTR => continue,
                    else => return,
                }
            }
        },
    }
}
test write {
    write("");
}
