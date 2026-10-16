const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
pub const LocalHostnameValidationError = error{
    PermissionDenied,
    Unexpected,
};
pub fn isLocal(hostname: []const u8) LocalHostnameValidationError!bool {
    if (std.mem.eql(u8, "localhost", hostname)) return true;
    switch (builtin.os.tag) {
        .windows => {
            const windows = @import("windows.zig");
            var buf: [256:0]u8 = undefined;
            var nSize: windows.DWORD = buf.len;
            if (windows.exp.kernel32.GetComputerNameA(&buf, &nSize) == windows.FALSE) return false;
            const ourHostname = buf[0..nSize];
            return std.mem.eql(u8, hostname, ourHostname);
        },
        else => {
            var buf: [posix.HOST_NAME_MAX]u8 = undefined;
            const ourHostname = try posix.gethostname(&buf);
            return std.mem.eql(u8, hostname, ourHostname);
        },
    }
}
test "isLocal returns true when provided hostname is localhost" {
    try std.testing.expect(try isLocal("localhost"));
}
test "isLocal returns true when hostname is local" {
    switch (builtin.os.tag) {
        .windows => {
            const windows = @import("windows.zig");
            var buf: [256:0]u8 = undefined;
            var nSize: windows.DWORD = buf.len;
            if (windows.exp.kernel32.GetComputerNameA(&buf, &nSize) == windows.FALSE)
                return error.GetComputerNameFailed;
            const localHostname = buf[0..nSize];
            try std.testing.expect(try isLocal(localHostname));
        },
        else => {
            var buf: [posix.HOST_NAME_MAX]u8 = undefined;
            const localHostname = try posix.gethostname(&buf);
            try std.testing.expect(try isLocal(localHostname));
        },
    }
}
test "isLocal returns false when hostname is not local" {
    try std.testing.expectEqual(
        false,
        try isLocal("not-the-local-hostname"),
    );
}
