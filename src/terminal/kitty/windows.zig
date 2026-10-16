const std = @import("std");
pub const Error = error{
    UncPath,
    DevicePath,
    ReservedDeviceName,
    NotDriveAbsolute,
};
pub fn checkPath(path: []const u8) Error!void {
    if (path.len >= 2 and isSep(path[0]) and isSep(path[1])) {
        if (path.len >= 4 and
            (path[2] == '?' or path[2] == '.') and
            isSep(path[3])) return error.DevicePath;
        return error.UncPath;
    }
    if (path.len >= 4 and
        isSep(path[0]) and
        path[1] == '?' and
        path[2] == '?' and
        isSep(path[3])) return error.DevicePath;
    var it = std.mem.splitAny(u8, path, "\\/");
    while (it.next()) |component| {
        if (isReservedDeviceName(component)) return error.ReservedDeviceName;
    }
}
pub fn checkCanonicalPath(path: []const u8) Error!void {
    if (!isDriveAbsolute(path)) return error.NotDriveAbsolute;
    try checkPath(path);
}
pub fn isDriveAbsolute(path: []const u8) bool {
    return path.len >= 3 and
        std.ascii.isAlphabetic(path[0]) and
        path[1] == ':' and
        path[2] == '\\';
}
fn isSep(c: u8) bool {
    return std.fs.path.PathType.windows.isSep(u8, c);
}
fn isReservedDeviceName(component: []const u8) bool {
    const end = std.mem.findAny(u8, component, ".:") orelse component.len;
    const stem = std.mem.trimEnd(u8, component[0..end], " ");
    if (stem.len < 3) return false;
    const base = stem[0..3];
    const rest = stem[3..];
    if (rest.len == 0) {
        return std.ascii.eqlIgnoreCase(base, "CON") or
            std.ascii.eqlIgnoreCase(base, "PRN") or
            std.ascii.eqlIgnoreCase(base, "AUX") or
            std.ascii.eqlIgnoreCase(base, "NUL");
    }
    if (!std.ascii.eqlIgnoreCase(base, "COM") and
        !std.ascii.eqlIgnoreCase(base, "LPT")) return false;
    return switch (rest.len) {
        1 => std.ascii.isDigit(rest[0]),
        2 => rest[0] == 0xC2 and
            (rest[1] == 0xB9 or rest[1] == 0xB2 or rest[1] == 0xB3),
        else => false,
    };
}
test "checkPath rejects UNC paths" {
    const testing = std.testing;
    const unc = [_][]const u8{
        "\\\\server\\share\\tty-graphics-protocol-image.data",
        "//server/share/tty-graphics-protocol-image.data",
        "\\/server/share/image.data",
        "/\\server\\share\\image.data",
        "\\\\.x\\share\\image.data",
        "\\\\",
    };
    for (unc) |path| {
        try testing.expectError(error.UncPath, checkPath(path));
    }
}
test "checkPath rejects device and NT namespaces" {
    const testing = std.testing;
    const device = [_][]const u8{
        "\\\\?\\UNC\\server\\share\\image.data",
        "\\\\?\\C:\\Windows\\Temp\\image.data",
        "//?/C:/Windows/Temp/image.data",
        "\\\\.\\C:\\Windows\\Temp\\image.data",
        "\\\\.\\pipe\\image",
        "\\\\.\\PhysicalDrive0",
        "\\\\?\\GLOBALROOT\\Device\\HarddiskVolume1\\image.data",
        "//?/GLOBALROOT/Device/HarddiskVolume1/image.data",
        "\\??\\C:\\Windows\\Temp\\image.data",
        "\\??\\Device\\HarddiskVolume1\\image.data",
        "\\??\\UNC\\server\\share\\image.data",
        "/??/C:/image.data",
    };
    for (device) |path| {
        try testing.expectError(error.DevicePath, checkPath(path));
    }
}
test "checkPath accepts plain local paths" {
    const accepted = [_][]const u8{
        "C:\\Windows\\Temp\\tty-graphics-protocol-image.data",
        "C:/Windows/Temp/tty-graphics-protocol-image.data",
        "c:\\image.data",
        "C:image.data",
        "\\Windows\\Temp\\image.data",
        "/Windows/Temp/image.data",
        "image.data",
        ".zig-cache\\tmp\\image.data",
        "C:\\Device\\HarddiskVolume1\\image.data",
        "C:\\GLOBALROOT\\image.data",
        "C:\\dir\\console.png",
        "\\?\\image.data",
        "",
    };
    for (accepted) |path| {
        try checkPath(path);
    }
}
test "checkPath rejects reserved device names in any component" {
    const testing = std.testing;
    const reserved = [_][]const u8{
        "CON",
        "con",
        "CON.png",
        "CON.tar.gz",
        "CON.",
        "CON  ",
        "CON .png",
        "NUL:stream",
        "PRN",
        "AUX",
        "nul",
        "COM1",
        "COM0",
        "COM9.rgba",
        "com5",
        "LPT1",
        "LPT9",
        "lpt0.png",
        "COM\xC2\xB9",
        "LPT\xC2\xB3.png",
        "C:\\Windows\\Temp\\NUL.rgba",
        "C:\\CON\\image.data",
        "dir/aux/image.data",
        "C:/Windows/Temp/com1",
        "..\\PRN",
    };
    for (reserved) |path| {
        try testing.expectError(error.ReservedDeviceName, checkPath(path));
    }
    const plain = [_][]const u8{
        "CONSOLE",
        "CON1",
        "xCON",
        " CON",
        "COM",
        "COM10",
        "COMA",
        "COM\xC2\xB9\xC2\xB9",
        "COM\xC2\xB0",
        "LPT",
        "LPT.png",
        "conx.png",
        "C:",
        "C:\\",
        "image.data",
        "C:\\Windows\\Temp\\tty-graphics-protocol-image.data",
        "C:\\Windows\\Temp\\console.png",
        "",
    };
    for (plain) |path| {
        try checkPath(path);
    }
}
test "checkCanonicalPath requires a drive-absolute local path" {
    const testing = std.testing;
    try checkCanonicalPath("C:\\Windows\\Temp\\image.data");
    try checkCanonicalPath("c:\\image.data");
    try testing.expectError(
        error.NotDriveAbsolute,
        checkCanonicalPath("\\\\server\\share\\image.data"),
    );
    try testing.expectError(
        error.NotDriveAbsolute,
        checkCanonicalPath("\\\\?\\UNC\\server\\share\\image.data"),
    );
    try testing.expectError(
        error.NotDriveAbsolute,
        checkCanonicalPath("\\\\?\\Volume{383da0b0-717f-41b6-8c36-00500992b58d}\\image.data"),
    );
    try testing.expectError(
        error.ReservedDeviceName,
        checkCanonicalPath("C:\\Windows\\Temp\\CON"),
    );
}
test isDriveAbsolute {
    const testing = std.testing;
    try testing.expect(isDriveAbsolute("C:\\Windows\\Temp\\image.data"));
    try testing.expect(isDriveAbsolute("c:\\image.data"));
    try testing.expect(isDriveAbsolute("Z:\\"));
    try testing.expect(!isDriveAbsolute("\\\\server\\share\\image.data"));
    try testing.expect(!isDriveAbsolute("UNC\\server\\share\\image.data"));
    try testing.expect(!isDriveAbsolute("C:/Windows/image.data"));
    try testing.expect(!isDriveAbsolute("C:image.data"));
    try testing.expect(!isDriveAbsolute("\\Windows\\image.data"));
    try testing.expect(!isDriveAbsolute("1:\\image.data"));
    try testing.expect(!isDriveAbsolute("C:"));
    try testing.expect(!isDriveAbsolute(""));
}
