const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const DLL_PROCESS_ATTACH: windows.DWORD = 1;
const Initializer = *const fn () callconv(.c) void;
export const wasp_crt_xc_a: ?Initializer linksection(".CRT$XCA") = null;
export const wasp_crt_xc_z: ?Initializer linksection(".CRT$XCZ") = null;
extern var __CTOR_LIST__: ?Initializer;
pub fn DllMain(
    hinstDLL: windows.HINSTANCE,
    fdwReason: windows.DWORD,
    lpReserved: windows.LPVOID,
) callconv(.winapi) windows.BOOL {
    _ = hinstDLL;
    _ = lpReserved;
    switch (fdwReason) {
        DLL_PROCESS_ATTACH => runGlobalConstructors(),
        else => {},
    }
    return .TRUE;
}
fn runGlobalConstructors() void {
    if (comptime builtin.abi != .msvc) {
        const list: [*]const ?Initializer = @ptrCast(&__CTOR_LIST__);
        var len: usize = 0;
        while (list[len + 1] != null) len += 1;
        var i: usize = len;
        while (i >= 1) : (i -= 1) list[i].?();
        return;
    }
    const start: [*]const ?Initializer = @ptrCast(&wasp_crt_xc_a);
    const end: [*]const ?Initializer = @ptrCast(&wasp_crt_xc_z);
    const len = (@intFromPtr(end) - @intFromPtr(start)) / @sizeOf(?Initializer);
    for (start[0..len]) |initializer| if (initializer) |f| f();
}
