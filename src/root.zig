const build_config = @import("build_config.zig");
const structs = @import("app/structs.zig");
pub const action = @import("app/action.zig");
pub const ipc = @import("app/ipc.zig");
pub const gtk = @import("app/gtk.zig");
pub const none = @import("app/none.zig");
pub const win32 = @import("app/win32.zig");
pub const browser = @import("app/browser.zig");
pub const embedded = @import("app/embedded.zig");
pub const surface = @import("app/surface.zig");
pub const Action = action.Action;
pub const Runtime = @import("app/rt.zig").Runtime;
pub const Target = action.Target;
pub const ContentScale = structs.ContentScale;
pub const Clipboard = structs.Clipboard;
pub const ClipboardContent = structs.ClipboardContent;
pub const ClipboardReadResult = structs.ClipboardReadResult;
pub const ClipboardRequest = structs.ClipboardRequest;
pub const ClipboardRequestType = structs.ClipboardRequestType;
pub const ColorScheme = structs.ColorScheme;
pub const CursorPos = structs.CursorPos;
pub const IMEPos = structs.IMEPos;
pub const Selection = structs.Selection;
pub const SurfaceSize = structs.SurfaceSize;
pub const runtime = switch (build_config.artifact) {
    .exe => switch (build_config.app_runtime) {
        .none => none,
        .gtk => gtk,
        .win32 => win32,
    },
    .lib => embedded,
    .wasm_module => browser,
};
pub const App = runtime.App;
pub const Surface = runtime.Surface;
test {
    _ = Runtime;
    _ = runtime;
    _ = action;
    _ = structs;
}
